module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

<*
 Items an overlay list holds by default.
*>
const uint OVERLAY_LIST_DEFAULT_ITEMS = 4096; // 384 KiB of instances per prepared list, about 1% of the upload ring

<*
 Nested clip regions an overlay list tracks by default.
*>
const uint OVERLAY_LIST_DEFAULT_CLIPS = 16; // UI nesting of panels and scroll areas stays well below this

<*
 Glyph placements an overlay list holds by default.
*>
const uint OVERLAY_LIST_DEFAULT_GLYPHS = 16384; // 1.5 MiB of instances per prepared list, under 5% of the ring

<*
 White, unbordered rectangle sampling the whole texture region.
*>
const OverlayRect OVERLAY_RECT_DEFAULT = {
    .fill    = { 1, 1, 1, 1 },
    .uv_rect = { 0, 0, 1, 1 },
};

const float HALF_MAX @local = 65504; // largest finite f16; radii, borders and slice pixels clamp to it
const float UNORM16_MAX @local = 65535;
const Vec4 UNBOUNDED_CLIP @local = { -float::max, -float::max, float::max, float::max };

enum OverlayEntryKind @private {
    RECT,
    GLYPHS,
}

<*
 Capacities of an overlay list.
*>
struct OverlayListDesc {
    uint max_items;
    uint max_clips;
    uint max_glyphs; // zero holds no text
}

<*
 Rounded, bordered and optionally textured rectangle in output pixels.
*>
struct OverlayRect {
    Vec2       min;
    Vec2       max;
    Vec4       corner_radii;  // pixels: top left, top right, bottom right, bottom left
    Vec4       fill;          // sRGB, straight alpha; multiplies the texture when one is set
    Vec4       border_widths; // pixels: left, top, right, bottom
    Vec4       border_color;  // sRGB, straight alpha
    TextureRef texture;       // an ASSET reference with a zero id fills with color only
    SamplerId  sampler;       // zero selects the linear clamp sampler
    Vec4       uv_rect;       // u0, v0, u1, v1 of the sampled region
    Vec4       slice_uv;      // nine-slice margins as fractions of uv_rect: left, top, right, bottom
    Vec4       slice_pixels;  // the same margins on screen; all zero disables nine-slice
}

<*
 Glyphs of one font drawn at one pixel size.
*>
struct OverlayGlyphRun {
    FontId           font;
    GlyphPlacement[] glyphs;      // copied into the list
    Vec2             origin;      // output pixels of the baseline start
    float            size_pixels; // em size on screen
    Vec4             color;       // sRGB, straight alpha
}

struct OverlayText @private {
    FontId font;
    uint   first;       // index of the run's first placement in OverlayList.glyphs
    uint   count;
    Vec2   origin;
    float  size_pixels;
    Vec4   color;
}

struct OverlayEntry @private {
    OverlayEntryKind kind;
    Vec4             clip; // min x, min y, max x, max y
    union {
        OverlayRect rect;
        OverlayText text;
    }
}

struct OverlayBinding @private {
    gpu::TextureIndex texture; // rect texture or glyph curves
    gpu::SamplerIndex sampler;
    gpu::TextureIndex bands;   // glyph bands
}

struct OverlayRun @private {
    uint             first; // index of the run's first packed item
    uint             count;
    gpu::ScissorRect scissor;
}

struct OverlayPrepared @private {
    gpu::GpuAddress items;
    uint            run_count;
    ulong           frame; // renderer frame index plus one; zero before the first preparation
}

struct OverlayPacker @local {
    OverlayList*     list;
    OverlayItemGpu[] destination;
    uint             emitted;
    uint             run_count;
}

<*
 Application-owned 2D items for one overlay, in drawing order.
*>
struct OverlayList {
    Allocator        allocator;
    char[]           storage;     // one allocation behind every slice below
    OverlayEntry[]   entries;     // rects and glyph runs with their clips
    GlyphPlacement[] glyphs;      // placements of every glyph run
    OverlayBinding[] bindings;    // per entry
    Vec4[]           clips;       // the clip stack
    OverlayRun[]     runs;
    uint             item_count;  // entries in use
    uint             glyph_count;
    uint             clip_depth;
    OverlayPrepared  prepared;
}

<*
 Remove every item and clip; capacity is kept.
*>
fn void OverlayList.clear(&self) {
    self.item_count = 0;
    self.glyph_count = 0;
    self.clip_depth = 0;
}

<*
 Append a rectangle under the current clip.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_rect(&self, OverlayRect rect) {
    if (self.item_count == self.entries.len) return c3d::CAPACITY_EXCEEDED~;
    if (!overlay_rect_valid(&rect)) return c3d::INVALID_ARGUMENT~;

    self.entries[self.item_count] = { .kind = RECT, .clip = current_overlay_clip(self), .rect = rect };
    self.item_count++;
}

<*
 Append a glyph run under the current clip.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_glyphs(&self, OverlayGlyphRun run) {
    if (self.item_count == self.entries.len) return c3d::CAPACITY_EXCEEDED~;
    if (run.glyphs.len > self.glyphs.len - self.glyph_count) return c3d::CAPACITY_EXCEEDED~;
    if (!finite_vec2(run.origin) || !finite_vec4(run.color)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(run.size_pixels) || run.size_pixels <= 0) return c3d::INVALID_ARGUMENT~;
    foreach (placement : run.glyphs) {
        if (!finite_vec2(placement.position)) return c3d::INVALID_ARGUMENT~;
    }

    self.glyphs[self.glyph_count : run.glyphs.len] = run.glyphs[..];
    self.entries[self.item_count] = {
        .kind = GLYPHS,
        .clip = current_overlay_clip(self),
        .text = {
            .font        = run.font,
            .first       = self.glyph_count,
            .count       = (uint)run.glyphs.len,
            .origin      = run.origin,
            .size_pixels = run.size_pixels,
            .color       = run.color,
        },
    };
    self.glyph_count += (uint)run.glyphs.len;
    self.item_count++;
}

<*
 Intersect the current clip with a box in output pixels.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.push_clip(&self, Vec2 min, Vec2 max) {
    if (self.clip_depth == self.clips.len) return c3d::CAPACITY_EXCEEDED~;
    if (!finite_vec2(min) || !finite_vec2(max) || max.x < min.x || max.y < min.y) return c3d::INVALID_ARGUMENT~;

    Vec4 current = current_overlay_clip(self);
    self.clips[self.clip_depth] = {
        math::max(current.x, min.x),
        math::max(current.y, min.y),
        math::min(current.z, max.x),
        math::min(current.w, max.y),
    };
    self.clip_depth++;
}

<*
 Restore the clip active before the matching push.
 @require self.clip_depth > 0
*>
fn void OverlayList.pop_clip(&self) {
    self.clip_depth--;
}

<*
 Default overlay list capacities.
*>
fn OverlayListDesc default_overlay_list_desc() {
    return {
        .max_items  = OVERLAY_LIST_DEFAULT_ITEMS,
        .max_clips  = OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs = OVERLAY_LIST_DEFAULT_GLYPHS,
    };
}

<*
 Allocate a list's fixed item, clip and run storage.
 @require desc.max_items > 0, desc.max_clips > 0
*>
fn OverlayList create_overlay_list(Allocator allocator, OverlayListDesc desc) {
    usz glyphs_offset = (usz)desc.max_items * OverlayEntry::size;
    usz bindings_offset = glyphs_offset + (usz)desc.max_glyphs * GlyphPlacement::size;
    usz clips_offset = align_up(bindings_offset + (usz)desc.max_items * OverlayBinding::size, Vec4::size);
    usz runs_offset = clips_offset + (usz)desc.max_clips * Vec4::size;
    usz total_bytes = align_up(runs_offset + (usz)desc.max_items * OverlayRun::size, Vec4::size);

    // Allocated as Vec4 so every allocator aligns the block for the Vec4 members of the carved slices.
    Vec4[] block = alloc::new_array(allocator, Vec4, (sz)(total_bytes / Vec4::size));
    char[] storage = ((char*)block.ptr)[:total_bytes];

    return {
        .allocator  = allocator,
        .storage    = storage,
        .entries    = ((OverlayEntry*)storage.ptr)[:desc.max_items],
        .glyphs     = ((GlyphPlacement*)&storage[glyphs_offset])[:desc.max_glyphs],
        .bindings   = ((OverlayBinding*)&storage[bindings_offset])[:desc.max_items],
        .clips      = ((Vec4*)&storage[clips_offset])[:desc.max_clips],
        .runs       = ((OverlayRun*)&storage[runs_offset])[:desc.max_items],
    };
}

<*
 Release the list's storage.
 @param [&inout] list : "Left zeroed."
*>
fn void destroy_overlay_list(OverlayList* list) {
    alloc::free(list.allocator, list.storage.ptr);
    *list = {};
}

fn bool finite_vec2(Vec2 value) @local {
    return math::is_finite(value.x) && math::is_finite(value.y);
}

fn bool finite_vec4(Vec4 value) @local {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z) && math::is_finite(value.w);
}

fn bool non_negative_vec4(Vec4 value) @local {
    return value.x >= 0 && value.y >= 0 && value.z >= 0 && value.w >= 0;
}

fn bool any_positive_vec4(Vec4 value) @local {
    return value.x > 0 || value.y > 0 || value.z > 0 || value.w > 0;
}

fn bool overlay_rect_valid(OverlayRect* rect) @private {
    if (!finite_vec2(rect.min) || !finite_vec2(rect.max)) return false;

    Vec4[7] values = {
        rect.corner_radii,
        rect.fill,
        rect.border_widths,
        rect.border_color,
        rect.uv_rect,
        rect.slice_uv,
        rect.slice_pixels,
    };
    foreach (value : values) {
        if (!finite_vec4(value)) return false;
    }

    if (rect.max.x < rect.min.x || rect.max.y < rect.min.y) return false;
    if (!non_negative_vec4(rect.corner_radii) || !non_negative_vec4(rect.border_widths)) return false;
    if (!non_negative_vec4(rect.slice_uv) || !non_negative_vec4(rect.slice_pixels)) return false;
    if (rect.slice_pixels.x + rect.slice_pixels.z > rect.max.x - rect.min.x) return false;
    if (rect.slice_pixels.y + rect.slice_pixels.w > rect.max.y - rect.min.y) return false;
    return rect.slice_uv.x + rect.slice_uv.z <= 1 && rect.slice_uv.y + rect.slice_uv.w <= 1;
}

fn Vec4 current_overlay_clip(OverlayList* list) @private {
    return list.clip_depth ? list.clips[list.clip_depth - 1] : UNBOUNDED_CLIP;
}

fn bool overlay_ref_solid(TextureRef texture) @private {
    return texture.kind == TextureRefKind.ASSET && c3d::same_id(texture.asset, (TextureId){});
}

fn void? check_overlay_refs(AssetStore* assets, TargetPool* targets, OverlayList* list) @private {
    foreach (&entry : list.entries[:list.item_count]) {
        switch (entry.kind) {
            case RECT: check_rect_refs(assets, targets, &entry.rect)!;
            case GLYPHS: check_text_refs(assets, list, &entry.text)!;
        }
    }
}

fn void? check_rect_refs(AssetStore* assets, TargetPool* targets, OverlayRect* rect) @local {
    if (!c3d::same_id(rect.sampler, (SamplerId){})) {
        if (!assets.samplers.is_live(rect.sampler)) return c3d::INVALID_ID~;
        if (assets.sampler(rect.sampler).desc.compare_enable) return c3d::INVALID_ARGUMENT~;
    }

    if (overlay_ref_solid(rect.texture)) return;

    switch (rect.texture.kind) {
        case ASSET:
            if (!assets.textures.is_live(rect.texture.asset)) return c3d::INVALID_ID~;
            material::TextureDesc desc = assets.texture(rect.texture.asset).desc;
            if (desc.is_cube || desc.depth != 0 || desc.layers != 1 || desc.format == R16_UINT) {
                return c3d::UNSUPPORTED~;
            }
        case RENDER_TARGET:
            if (!targets.is_live(rect.texture.target)) return c3d::INVALID_ID~;
    }
}

fn void? check_text_refs(AssetStore* assets, OverlayList* list, OverlayText* text) @local {
    if (!assets.fonts.is_live(text.font)) return c3d::INVALID_ID~;

    FontAsset* font = assets.font(text.font);
    foreach (placement : list.glyphs[text.first : text.count]) {
        if (placement.glyph >= font.glyph_slots.len) return c3d::INVALID_ARGUMENT~;
        uint slot = font.glyph_slots[placement.glyph];
        if (!slot || slot == asset::FONT_GLYPH_EMPTY) return c3d::INVALID_ARGUMENT~;
    }
}

fn gpu::ScissorRect overlay_scissor(Vec4 clip, uint width, uint height) @private {
    float left = math::clamp(clip.x, 0.0f, (float)width);
    float top = math::clamp(clip.y, 0.0f, (float)height);
    float right = math::clamp(clip.z, 0.0f, (float)width);
    float bottom = math::clamp(clip.w, 0.0f, (float)height);

    if (right <= left || bottom <= top) return {};

    int x = (int)math::floor(left);
    int y = (int)math::floor(top);
    return {
        .x      = x,
        .y      = y,
        .width  = (int)math::ceil(right) - x,
        .height = (int)math::ceil(bottom) - y,
    };
}

fn bool same_scissor(gpu::ScissorRect first, gpu::ScissorRect second) @local {
    return first.x == second.x && first.y == second.y && first.width == second.width && first.height == second.height;
}

fn bool overlay_bounds_reach(Vec4 bounds, gpu::ScissorRect scissor) @local {
    if (!scissor.width || bounds.z <= bounds.x || bounds.w <= bounds.y) return false;

    float edge = shader::OVERLAY_EDGE_PIXELS;
    return bounds.x - edge < (float)(scissor.x + scissor.width)
        && bounds.z + edge > (float)scissor.x
        && bounds.y - edge < (float)(scissor.y + scissor.height)
        && bounds.w + edge > (float)scissor.y;
}

fn uint pack_half2(float low, float high) @local {
    return (uint)float_to_half(math::min(low, HALF_MAX)) | (uint)float_to_half(math::min(high, HALF_MAX)) << 16;
}

fn uint pack_unorm16x2(float low, float high) @local {
    uint low_bits = (uint)math::round(math::clamp(low, 0.0f, 1.0f) * UNORM16_MAX);
    uint high_bits = (uint)math::round(math::clamp(high, 0.0f, 1.0f) * UNORM16_MAX);
    return low_bits | high_bits << 16;
}

fn uint pack_rgba8(Vec4 color) @local {
    return debug::rgba(
        red:   color.x,
        green: color.y,
        blue:  color.z,
        alpha: color.w,
    );
}

// SamplerIndex holds the heap slot plus one, so the mask must hold the heap capacity itself.
$assert(gpu::DEFAULT_SAMPLER_HEAP_CAPACITY <= shader::OVERLAY_SAMPLER_MASK);

fn OverlayItemGpu pack_overlay_rect(OverlayRect* rect, OverlayBinding binding) @private {
    Vec2 size = rect.max - rect.min;
    float radius_limit = math::min(size.x, size.y) * 0.5f;
    Vec4 radii = math::min(rect.corner_radii, (Vec4){ radius_limit, radius_limit, radius_limit, radius_limit });
    Vec4 borders = math::min(rect.border_widths, (Vec4){ size.x, size.y, size.x, size.y });
    bool textured = !overlay_ref_solid(rect.texture);

    uint flags;
    if (textured) flags |= shader::OVERLAY_FLAG_TEXTURED;
    if (textured && any_positive_vec4(rect.slice_pixels)) flags |= shader::OVERLAY_FLAG_NINE_SLICE;
    if (any_positive_vec4(borders)) flags |= shader::OVERLAY_FLAG_BORDER;
    uint kind = shader::OVERLAY_KIND_RECT << shader::OVERLAY_KIND_SHIFT;
    uint kind_flags = kind | (flags << shader::OVERLAY_FLAGS_SHIFT);

    return {
        .bounds                    = { rect.min.x, rect.min.y, rect.max.x, rect.max.y },
        .uv_rect                   = rect.uv_rect,
        .radii_top                 = pack_half2(radii.x, radii.y),
        .radii_bottom              = pack_half2(radii.z, radii.w),
        .borders_left_top          = pack_half2(borders.x, borders.y),
        .borders_right_bottom      = pack_half2(borders.z, borders.w),
        .slice_uv_left_top         = pack_unorm16x2(rect.slice_uv.x, rect.slice_uv.y),
        .slice_uv_right_bottom     = pack_unorm16x2(rect.slice_uv.z, rect.slice_uv.w),
        .slice_pixels_left_top     = pack_half2(rect.slice_pixels.x, rect.slice_pixels.y),
        .slice_pixels_right_bottom = pack_half2(rect.slice_pixels.z, rect.slice_pixels.w),
        .fill                      = pack_rgba8(rect.fill),
        .border_color              = pack_rgba8(rect.border_color),
        .texture                   = binding.texture,
        .sampler_kind_flags        = ((uint)binding.sampler & shader::OVERLAY_SAMPLER_MASK) | kind_flags,
    };
}

fn OverlayItemGpu pack_overlay_glyph(
    OverlayText* text,
    GlyphPlacement placement,
    FontGlyph* glyph,
    OverlayBinding binding,
) @private {
    Vec2 pen = text.origin + placement.position * text.size_pixels;
    Vec4 em = glyph.bounds;
    float size = text.size_pixels;
    return {
        .bounds             = { pen.x + em.x * size, pen.y - em.w * size, pen.x + em.z * size, pen.y - em.y * size },
        .uv_rect            = { em.x, em.w, em.z, em.y },
        .fill               = pack_rgba8(text.color),
        .texture            = binding.texture,
        .sampler_kind_flags = shader::OVERLAY_KIND_GLYPH << shader::OVERLAY_KIND_SHIFT,
        .glyph_location     = glyph.band_location,
        .glyph_band_max     = glyph.band_max,
        .band_texture       = binding.bands,
    };
}

fn void emit_overlay_item(OverlayPacker* packer, gpu::ScissorRect scissor, OverlayItemGpu item) @local {
    OverlayRun[] runs = packer.list.runs;
    if (!packer.run_count || !same_scissor(runs[packer.run_count - 1].scissor, scissor)) {
        runs[packer.run_count] = { .first = packer.emitted, .scissor = scissor };
        packer.run_count++;
    }
    runs[packer.run_count - 1].count++;
    packer.destination[packer.emitted] = item;
    packer.emitted++;
}

// Every emitted item stays in submission order; a run splits only where the scissor changes, whatever the kinds.
fn uint pack_overlay_items(
    OverlayList* list,
    AssetStore* assets,
    uint width,
    uint height,
    OverlayItemGpu[] destination,
) @private {
    OverlayPacker packer = { .list = list, .destination = destination };

    foreach (index, &entry : list.entries[:list.item_count]) {
        gpu::ScissorRect scissor = overlay_scissor(entry.clip, width, height);
        switch (entry.kind) {
            case RECT:
                OverlayRect* rect = &entry.rect;
                if (!overlay_bounds_reach({ rect.min.x, rect.min.y, rect.max.x, rect.max.y }, scissor)) continue;
                emit_overlay_item(&packer, scissor, pack_overlay_rect(rect, list.bindings[index]));
            case GLYPHS:
                OverlayText* text = &entry.text;
                FontAsset* font = assets.font(text.font);
                foreach (placement : list.glyphs[text.first : text.count]) {
                    FontGlyph* glyph = &font.glyphs[font.glyph_slots[placement.glyph] - 1];
                    OverlayItemGpu item = pack_overlay_glyph(
                        text:      text,
                        placement: placement,
                        glyph:     glyph,
                        binding:   list.bindings[index],
                    );
                    if (!overlay_bounds_reach(item.bounds, scissor)) continue;
                    emit_overlay_item(&packer, scissor, item);
                }
        }
    }

    list.prepared.run_count = packer.run_count;
    return packer.emitted;
}
