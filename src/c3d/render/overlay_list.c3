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
 Transforms and transformed clips an overlay list holds by default.
*>
const uint OVERLAY_LIST_DEFAULT_TRANSFORMS = 256; // 20 KiB of table per prepared list, 0.06% of the ring

<*
 Largest blur radius of a backdrop item, in pixels.
*>
const uint MAX_BACKDROP_RADIUS = 32; // 65 taps in each of two passes: 130 texel reads for every blurred pixel

<*
 Backdrop items one overlay list holds.
*>
const uint MAX_BACKDROP_ITEMS = 8; // each costs a pass break, two blur dispatches and, on the window, a copy

<*
 White, unbordered rectangle sampling the whole texture region.
*>
const OverlayRect OVERLAY_RECT_DEFAULT = {
    .fill    = { 1, 1, 1, 1 },
    .uv_rect = { 0, 0, 1, 1 },
};

<*
 Transform that leaves every position unchanged.
*>
const OverlayTransform OVERLAY_TRANSFORM_IDENTITY = {
    .x_axis = { 1, 0 },
    .y_axis = { 0, 1 },
};

const float HALF_MAX @local = 65504; // largest finite f16; radii, borders and slice pixels clamp to it
const float BACKDROP_PADDING @local = 2 * shader::OVERLAY_EDGE_PIXELS; // a rotated quad's margin reaches 1.5 pixels
const float UNORM16_MAX @local = 65535;
const Vec4 UNBOUNDED_CLIP @local = { -float::max, -float::max, float::max, float::max };
const shader::OverlayTransformGpu IDENTITY_TABLE_ENTRY @local = {
    .x_axis         = { 1, 0 },
    .y_axis         = { 0, 1 },
    .inverse_x_axis = { 1, 0 },
    .inverse_y_axis = { 0, 1 },
};

enum OverlayEntryKind @private {
    RECT,
    GLYPHS,
    TRIANGLE,
    SEGMENT,
}

<*
 Direction in which a gradient changes color.
*>
enum OverlayGradientKind {
    NONE,
    LINEAR,
    RADIAL,
}

<*
 Capacities of an overlay list.
*>
struct OverlayListDesc {
    uint max_items;
    uint max_clips;
    uint max_glyphs;     // zero holds no text
    uint max_transforms; // zero holds no transforms
}

<*
 Affine map from local pixels to output pixels.
*>
struct OverlayTransform {
    Vec2 x_axis;
    Vec2 y_axis;
    Vec2 offset;
}

<*
 Two-color ramp from a rectangle's fill to an end color.
*>
struct OverlayGradient {
    OverlayGradientKind kind;
    Vec2                from;  // start point, or the centre of a radial gradient
    Vec2                to;    // end point, or a point on the radius of a radial gradient
    Vec4                color; // end color; sRGB, straight alpha
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
    OverlayGradient gradient; // NONE keeps fill alone; otherwise fill is the start color
    float      backdrop_radius; // pixels blurred under the rect; zero is off, clamped to MAX_BACKDROP_RADIUS
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

struct OverlayTriangle @private {
    Vec2 first;
    Vec2 second;
    Vec2 third;
    Vec4 color;
}

struct OverlaySegment @private {
    Vec2  from;
    Vec2  to;
    float half_width;
    Vec4  color;
}

struct OverlayEntry @private {
    OverlayEntryKind kind;
    uint             transform;  // table entry the item's coordinates pass through; zero is the identity
    uint             clip_entry; // table entry of the innermost transformed clip; zero for none
    Vec4             clip;       // output-pixel bounds of the clip: min x, min y, max x, max y
    union {
        OverlayRect     rect;
        OverlayText     text;
        OverlayTriangle triangle;
        OverlaySegment  segment;
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

struct OverlayBackdropRun @private {
    uint             run;    // index of the one-item run that draws the backdrop item
    gpu::ScissorRect box;    // output pixels the blurred image covers before the radius is added
    uint             radius; // whole pixels, at most MAX_BACKDROP_RADIUS
}

struct OverlayPrepared @private {
    gpu::GpuAddress items;
    gpu::GpuAddress transforms; // zero when no emitted item has a transform or a transformed clip
    bool            transformed; // some emitted item has one: the list draws with the transformed shaders
    uint            run_count;
    uint            backdrop_count; // emitted backdrop items, the first entries of OverlayList.backdrops
    RenderTargetId  target; // the output the instances were fitted to; zero for the window
    ulong           frame;  // renderer frame index plus one; zero before the first preparation
}

struct OverlayPacker @local {
    OverlayList*     list;
    OverlayItemGpu[] destination;
    uint             emitted;
    uint             run_count;
    bool             transformed;
    uint             backdrop_count;
    bool             run_isolated; // the last run holds one backdrop item, so the next item opens a run
}

<*
 Application-owned 2D items for one overlay, in drawing order.
*>
struct OverlayList {
    Allocator        allocator;
    char[]           storage;     // one allocation behind every slice below
    OverlayEntry[]   entries;     // rects, glyph runs, triangles and segments with their clips
    GlyphPlacement[] glyphs;      // placements of every glyph run
    OverlayBinding[] bindings;    // per entry
    Vec4[]           clips;       // the clip stack
    OverlayRun[]     runs;
    uint             item_count;  // entries in use
    uint             glyph_count;
    uint             clip_depth;
    OverlayPrepared  prepared;

    shader::OverlayTransformGpu[] transforms; // composed transforms and transformed clips; entry zero is the identity
    uint[]                        transform_stack; // table entry of each transform pushed and not yet popped
    uint[]                        clip_entries;    // per clip stack level: its innermost transformed clip entry
    uint                          transform_count; // table entries in use, the identity included
    uint                          transform_depth;
    OverlayBackdropRun[]          backdrops;       // MAX_BACKDROP_ITEMS entries, filled by preparation
    uint                          backdrop_count;  // backdrop items added since clear()
}

<*
 Remove every item, clip and transform; capacity is kept.
*>
fn void OverlayList.clear(&self) {
    self.item_count = 0;
    self.backdrop_count = 0;
    self.glyph_count = 0;
    self.clip_depth = 0;
    self.transform_count = 1;
    self.transform_depth = 0;
}

<*
 Append a rectangle under the current clip and transform.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_rect(&self, OverlayRect rect) {
    if (self.item_count == self.entries.len) return c3d::CAPACITY_EXCEEDED~;
    if (!overlay_rect_valid(&rect)) return c3d::INVALID_ARGUMENT~;

    bool backdrop = rect.backdrop_radius > 0;
    if (backdrop && self.backdrop_count == MAX_BACKDROP_ITEMS) return c3d::CAPACITY_EXCEEDED~;

    self.entries[self.item_count] = {
        .kind       = RECT,
        .transform  = current_overlay_transform(self),
        .clip_entry = current_overlay_clip_entry(self),
        .clip       = current_overlay_clip(self),
        .rect       = rect,
    };
    self.item_count++;
    if (backdrop) self.backdrop_count++;
}

<*
 Append a glyph run under the current clip and transform.
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
        .kind       = GLYPHS,
        .transform  = current_overlay_transform(self),
        .clip_entry = current_overlay_clip_entry(self),
        .clip       = current_overlay_clip(self),
        .text       = {
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
 Append a filled triangle of either winding under the current clip and transform.
 @param color : "sRGB, straight alpha."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_triangle(
    &self,
    Vec2 first,
    Vec2 second,
    Vec2 third,
    Vec4 color,
) {
    if (self.item_count == self.entries.len) return c3d::CAPACITY_EXCEEDED~;
    if (!finite_vec2(first) || !finite_vec2(second) || !finite_vec2(third) || !finite_vec4(color)) {
        return c3d::INVALID_ARGUMENT~;
    }

    OverlayEntry entry = new_overlay_entry(self, TRIANGLE);
    entry.triangle = { .first = first, .second = second, .third = third, .color = color };
    self.entries[self.item_count] = entry;
    self.item_count++;
}

<*
 Append a line with round caps under the current clip and transform.
 @param width : "Pixels across the line; above zero."
 @param color : "sRGB, straight alpha."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_line(
    &self,
    Vec2 from,
    Vec2 to,
    float width,
    Vec4 color,
) {
    if (self.item_count == self.entries.len) return c3d::CAPACITY_EXCEEDED~;
    if (!finite_vec2(from) || !finite_vec2(to) || !overlay_stroke_valid(width, color)) {
        return c3d::INVALID_ARGUMENT~;
    }

    append_overlay_segment(
        list:       self,
        from:       from,
        to:         to,
        half_width: width * 0.5f,
        color:      color,
    );
}

<*
 Append a polyline with round joins and caps, one item per edge.
 Edges overlap at joins, so a translucent path draws those areas twice.
 @param width : "Pixels across the path; above zero."
 @param color : "sRGB, straight alpha."
 @param closed : "Adds the edge from the last point back to the first."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.add_path(
    &self,
    Vec2[] points,
    float width,
    Vec4 color,
    bool closed = false,
) {
    if (points.len < 2) return c3d::INVALID_ARGUMENT~;

    bool closing_edge = closed && points.len > 2;
    usz edges = closing_edge ? points.len : points.len - 1;
    if (edges > self.entries.len - self.item_count) return c3d::CAPACITY_EXCEEDED~;
    if (!overlay_stroke_valid(width, color)) return c3d::INVALID_ARGUMENT~;
    foreach (point : points) {
        if (!finite_vec2(point)) return c3d::INVALID_ARGUMENT~;
    }

    float half_width = width * 0.5f;
    for (usz index = 1; index < points.len; index++) {
        append_overlay_segment(
            list:       self,
            from:       points[index - 1],
            to:         points[index],
            half_width: half_width,
            color:      color,
        );
    }
    if (closing_edge) {
        append_overlay_segment(
            list:       self,
            from:       points[^1],
            to:         points[0],
            half_width: half_width,
            color:      color,
        );
    }
}

<*
 Intersect the current clip with a box in the current transform's local space.
 A box under a transform takes one transform table entry.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.push_clip(&self, Vec2 min, Vec2 max) {
    if (self.clip_depth == self.clips.len) return c3d::CAPACITY_EXCEEDED~;
    if (!finite_vec2(min) || !finite_vec2(max) || max.x < min.x || max.y < min.y) return c3d::INVALID_ARGUMENT~;

    uint transform_entry = current_overlay_transform(self);
    if (transform_entry && self.transform_count == self.transforms.len) return c3d::CAPACITY_EXCEEDED~;

    Vec4 box = { min.x, min.y, max.x, max.y };
    uint clip_entry = current_overlay_clip_entry(self);
    if (transform_entry) {
        shader::OverlayTransformGpu* entry = &self.transforms[self.transform_count];
        *entry = self.transforms[transform_entry];
        entry.clip_box = box;
        entry.clip_parent = clip_entry;
        clip_entry = self.transform_count;
        self.transform_count++;
        box = overlay_output_bounds(box, entry);
    }

    Vec4 current = current_overlay_clip(self);
    self.clips[self.clip_depth] = {
        math::max(current.x, box.x),
        math::max(current.y, box.y),
        math::min(current.z, box.z),
        math::min(current.w, box.w),
    };
    self.clip_entries[self.clip_depth] = clip_entry;
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
 Apply a transform, ahead of the enclosing ones, until the matching pop.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? OverlayList.push_transform(&self, OverlayTransform transform) {
    if (self.transform_count == self.transforms.len) return c3d::CAPACITY_EXCEEDED~;

    shader::OverlayTransformGpu parent = self.transforms[current_overlay_transform(self)];
    self.transforms[self.transform_count] = compose_overlay_transform(&parent, transform)!;
    self.transform_stack[self.transform_depth] = self.transform_count;
    self.transform_count++;
    self.transform_depth++;
}

<*
 Restore the transform active before the matching push.
 @require self.transform_depth > 0
*>
fn void OverlayList.pop_transform(&self) {
    self.transform_depth--;
}

<*
 Default overlay list capacities.
*>
fn OverlayListDesc default_overlay_list_desc() {
    return {
        .max_items      = OVERLAY_LIST_DEFAULT_ITEMS,
        .max_clips      = OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs     = OVERLAY_LIST_DEFAULT_GLYPHS,
        .max_transforms = OVERLAY_LIST_DEFAULT_TRANSFORMS,
    };
}

<*
 Allocate a list's fixed item, clip, transform and run storage.
 @require desc.max_items > 0, desc.max_clips > 0
 @require desc.max_transforms <= shader::OVERLAY_TRANSFORM_MASK
*>
fn OverlayList create_overlay_list(Allocator allocator, OverlayListDesc desc) {
    usz glyphs_offset = (usz)desc.max_items * OverlayEntry::size;
    usz bindings_offset = glyphs_offset + (usz)desc.max_glyphs * GlyphPlacement::size;
    usz clips_offset = align_up(bindings_offset + (usz)desc.max_items * OverlayBinding::size, Vec4::size);
    usz runs_offset = clips_offset + (usz)desc.max_clips * Vec4::size;
    usz transforms_offset = align_up(runs_offset + (usz)desc.max_items * OverlayRun::size, Vec4::size);
    usz transform_stack_offset = transforms_offset + ((usz)desc.max_transforms + 1) * shader::OverlayTransformGpu::size;
    usz clip_entries_offset = transform_stack_offset + (usz)desc.max_transforms * uint::size;
    usz backdrops_offset = clip_entries_offset + (usz)desc.max_clips * uint::size;
    usz total_bytes = align_up(backdrops_offset + (usz)MAX_BACKDROP_ITEMS * OverlayBackdropRun::size, Vec4::size);

    // Allocated as Vec4 so every allocator aligns the block for the Vec4 members of the carved slices.
    Vec4[] block = alloc::new_array(allocator, Vec4, (sz)(total_bytes / Vec4::size));
    char[] storage = ((char*)block.ptr)[:total_bytes];

    OverlayList list = {
        .allocator       = allocator,
        .storage         = storage,
        .entries         = ((OverlayEntry*)storage.ptr)[:desc.max_items],
        .glyphs          = ((GlyphPlacement*)&storage[glyphs_offset])[:desc.max_glyphs],
        .bindings        = ((OverlayBinding*)&storage[bindings_offset])[:desc.max_items],
        .clips           = ((Vec4*)&storage[clips_offset])[:desc.max_clips],
        .runs            = ((OverlayRun*)&storage[runs_offset])[:desc.max_items],
        .transforms      = ((shader::OverlayTransformGpu*)&storage[transforms_offset])[:desc.max_transforms + 1],
        .transform_stack = ((uint*)&storage[transform_stack_offset])[:desc.max_transforms],
        .clip_entries    = ((uint*)&storage[clip_entries_offset])[:desc.max_clips],
        .backdrops       = ((OverlayBackdropRun*)&storage[backdrops_offset])[:MAX_BACKDROP_ITEMS],
        .transform_count = 1,
    };
    list.transforms[0] = IDENTITY_TABLE_ENTRY;
    return list;
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

fn bool overlay_stroke_valid(float width, Vec4 color) @local {
    return math::is_finite(width) && width > 0 && finite_vec4(color);
}

fn OverlayEntry new_overlay_entry(OverlayList* list, OverlayEntryKind kind) @local {
    return {
        .kind       = kind,
        .transform  = current_overlay_transform(list),
        .clip_entry = current_overlay_clip_entry(list),
        .clip       = current_overlay_clip(list),
    };
}

fn void append_overlay_segment(
    OverlayList* list,
    Vec2 from,
    Vec2 to,
    float half_width,
    Vec4 color,
) @local {
    OverlayEntry entry = new_overlay_entry(list, SEGMENT);
    entry.segment = { .from = from, .to = to, .half_width = half_width, .color = color };
    list.entries[list.item_count] = entry;
    list.item_count++;
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
    if (rect.slice_uv.x + rect.slice_uv.z > 1 || rect.slice_uv.y + rect.slice_uv.w > 1) return false;
    if (!math::is_finite(rect.backdrop_radius) || rect.backdrop_radius < 0) return false;
    return overlay_gradient_valid(rect);
}

// Both points are stored as half-precision offsets from the rectangle's top left, so they must fit that range.
fn bool overlay_gradient_valid(OverlayRect* rect) @local {
    OverlayGradient* gradient = &rect.gradient;
    if (gradient.kind == NONE) return true;
    if (!finite_vec2(gradient.from) || !finite_vec2(gradient.to) || !finite_vec4(gradient.color)) return false;
    if ((gradient.to - gradient.from).length() <= 0) return false;

    Vec2 from = gradient.from - rect.min;
    Vec2 to = gradient.to - rect.min;
    return math::abs(from.x) <= HALF_MAX
        && math::abs(from.y) <= HALF_MAX
        && math::abs(to.x) <= HALF_MAX
        && math::abs(to.y) <= HALF_MAX;
}

fn Vec4 current_overlay_clip(OverlayList* list) @private {
    return list.clip_depth ? list.clips[list.clip_depth - 1] : UNBOUNDED_CLIP;
}

fn uint current_overlay_clip_entry(OverlayList* list) @local {
    return list.clip_depth ? list.clip_entries[list.clip_depth - 1] : 0;
}

fn uint current_overlay_transform(OverlayList* list) @local {
    return list.transform_depth ? list.transform_stack[list.transform_depth - 1] : 0;
}

fn Vec2 map_overlay_point(shader::OverlayTransformGpu* transform, Vec2 point) @local {
    return transform.x_axis * point.x + transform.y_axis * point.y + transform.offset;
}

fn Vec4 overlay_output_bounds(Vec4 bounds, shader::OverlayTransformGpu* transform) @local {
    Vec2 top_left = map_overlay_point(transform, { bounds.x, bounds.y });
    Vec2 top_right = map_overlay_point(transform, { bounds.z, bounds.y });
    Vec2 bottom_left = map_overlay_point(transform, { bounds.x, bounds.w });
    Vec2 bottom_right = map_overlay_point(transform, { bounds.z, bounds.w });
    Vec2 low = math::min(math::min(top_left, top_right), math::min(bottom_left, bottom_right));
    Vec2 high = math::max(math::max(top_left, top_right), math::max(bottom_left, bottom_right));
    return { low.x, low.y, high.x, high.y };
}

// The fragment shader reads the inverse, so a transform without a finite one is rejected.
fn shader::OverlayTransformGpu? compose_overlay_transform(
    shader::OverlayTransformGpu* parent,
    OverlayTransform child,
) @local {
    Vec2 x_axis = parent.x_axis * child.x_axis.x + parent.y_axis * child.x_axis.y;
    Vec2 y_axis = parent.x_axis * child.y_axis.x + parent.y_axis * child.y_axis.y;
    Vec2 offset = parent.x_axis * child.offset.x + parent.y_axis * child.offset.y + parent.offset;

    float determinant = x_axis.x * y_axis.y - y_axis.x * x_axis.y;
    if (!math::is_finite(determinant) || determinant == 0) return c3d::INVALID_ARGUMENT~;

    Vec2 inverse_x_axis = (Vec2){ y_axis.y, -x_axis.y } / determinant;
    Vec2 inverse_y_axis = (Vec2){ -y_axis.x, x_axis.x } / determinant;
    Vec2 inverse_offset = -(inverse_x_axis * offset.x + inverse_y_axis * offset.y);
    Vec2[6] values = { x_axis, y_axis, offset, inverse_x_axis, inverse_y_axis, inverse_offset };
    foreach (value : values) {
        if (!finite_vec2(value)) return c3d::INVALID_ARGUMENT~;
    }

    return {
        .x_axis         = x_axis,
        .y_axis         = y_axis,
        .offset         = offset,
        .inverse_x_axis = inverse_x_axis,
        .inverse_y_axis = inverse_y_axis,
        .inverse_offset = inverse_offset,
    };
}

fn bool overlay_ref_solid(TextureRef texture) @private {
    return texture.kind == TextureRefKind.ASSET && c3d::same_id(texture.asset, (TextureId){});
}

fn void? check_overlay_refs(
    AssetStore* assets,
    TargetPool* targets,
    OverlayList* list,
    RenderTargetId output = {},
) @private {
    if (!c3d::same_id(output, (RenderTargetId){}) && !targets.is_live(output)) return c3d::INVALID_ID~;

    foreach (&entry : list.entries[:list.item_count]) {
        switch (entry.kind) {
            case RECT: check_rect_refs(assets, targets, &entry.rect, output)!;
            case GLYPHS: check_text_refs(assets, list, &entry.text)!;
            case TRIANGLE:
            case SEGMENT:
        }
    }
}

fn void? check_rect_refs(
    AssetStore* assets,
    TargetPool* targets,
    OverlayRect* rect,
    RenderTargetId output,
) @local {
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
            if (c3d::same_id(rect.texture.target, output)) return c3d::INVALID_ARGUMENT~;
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

fn Vec4 item_output_bounds(OverlayList* list, uint transform_entry, Vec4 bounds) @local {
    return transform_entry ? overlay_output_bounds(bounds, &list.transforms[transform_entry]) : bounds;
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

    OverlayItemGpu item = {
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

    if (rect.gradient.kind != NONE) pack_overlay_gradient(&item, rect);

    return item;
}

// The glyph words are free in a rect item.
fn void pack_overlay_gradient(OverlayItemGpu* item, OverlayRect* rect) @local {
    OverlayGradient* gradient = &rect.gradient;
    Vec2 from = gradient.from - rect.min;
    Vec2 to = gradient.to - rect.min;
    uint flags = shader::OVERLAY_FLAG_GRADIENT;
    if (gradient.kind == RADIAL) flags |= shader::OVERLAY_FLAG_GRADIENT_RADIAL;

    item.sampler_kind_flags |= flags << shader::OVERLAY_FLAGS_SHIFT;
    item.glyph_location = pack_rgba8(gradient.color);
    item.glyph_band_max = pack_half2(from.x, from.y);
    item.band_texture = (gpu::TextureIndex)pack_half2(to.x, to.y);
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

// The bounds are the shape's own box, so the quad and the culling work as they do for rects.
fn OverlayItemGpu pack_overlay_triangle(OverlayTriangle* triangle) @local {
    Vec2 low = math::min(math::min(triangle.first, triangle.second), triangle.third);
    Vec2 high = math::max(math::max(triangle.first, triangle.second), triangle.third);
    return {
        .bounds             = { low.x, low.y, high.x, high.y },
        .uv_rect            = { triangle.first.x, triangle.first.y, triangle.second.x, triangle.second.y },
        .radii_top          = bitcast(triangle.third.x, uint),
        .radii_bottom       = bitcast(triangle.third.y, uint),
        .fill               = pack_rgba8(triangle.color),
        .sampler_kind_flags = shader::OVERLAY_KIND_TRIANGLE << shader::OVERLAY_KIND_SHIFT,
    };
}

fn OverlayItemGpu pack_overlay_segment(OverlaySegment* segment) @local {
    Vec2 low = math::min(segment.from, segment.to) - segment.half_width;
    Vec2 high = math::max(segment.from, segment.to) + segment.half_width;
    return {
        .bounds             = { low.x, low.y, high.x, high.y },
        .uv_rect            = { segment.from.x, segment.from.y, segment.to.x, segment.to.y },
        .radii_top          = bitcast(segment.half_width, uint),
        .fill               = pack_rgba8(segment.color),
        .sampler_kind_flags = shader::OVERLAY_KIND_SEGMENT << shader::OVERLAY_KIND_SHIFT,
    };
}

fn void emit_overlay_item(
    OverlayPacker* packer,
    gpu::ScissorRect scissor,
    OverlayItemGpu item,
    bool backdrop = false,
) @local {
    packer.transformed = packer.transformed || item.transform_clip != 0;
    OverlayRun[] runs = packer.list.runs;
    bool continues = packer.run_count
        && !packer.run_isolated
        && !backdrop
        && same_scissor(runs[packer.run_count - 1].scissor, scissor);
    if (!continues) {
        runs[packer.run_count] = { .first = packer.emitted, .scissor = scissor };
        packer.run_count++;
    }
    runs[packer.run_count - 1].count++;
    packer.run_isolated = backdrop;
    packer.destination[packer.emitted] = item;
    packer.emitted++;
}

// The blurred image must cover every pixel the item's quad can reach inside its scissor.
fn void add_overlay_backdrop(
    OverlayPacker* packer,
    float radius,
    Vec4 output_bounds,
    gpu::ScissorRect scissor,
    uint width,
    uint height,
) @local {
    Vec4 reach = {
        math::max(output_bounds.x - BACKDROP_PADDING, (float)scissor.x),
        math::max(output_bounds.y - BACKDROP_PADDING, (float)scissor.y),
        math::min(output_bounds.z + BACKDROP_PADDING, (float)(scissor.x + scissor.width)),
        math::min(output_bounds.w + BACKDROP_PADDING, (float)(scissor.y + scissor.height)),
    };
    packer.list.backdrops[packer.backdrop_count] = {
        .run    = packer.run_count,
        .box    = overlay_scissor(reach, width, height),
        .radius = (uint)math::ceil(math::min(radius, (float)MAX_BACKDROP_RADIUS)),
    };
    packer.backdrop_count++;
}

// Every emitted item stays in submission order; a run splits where the scissor changes, whatever the kinds, and
// around a backdrop item, which draws alone.
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
        uint transform_clip = entry.transform | entry.clip_entry << shader::OVERLAY_CLIP_SHIFT;
        switch (entry.kind) {
            case RECT:
                OverlayRect* rect = &entry.rect;
                Vec4 rect_bounds = { rect.min.x, rect.min.y, rect.max.x, rect.max.y };
                Vec4 output_bounds = item_output_bounds(list, entry.transform, rect_bounds);
                if (!overlay_bounds_reach(output_bounds, scissor)) continue;
                OverlayItemGpu item = pack_overlay_rect(rect, list.bindings[index]);
                item.transform_clip = transform_clip;
                if (rect.backdrop_radius > 0) {
                    add_overlay_backdrop(
                        packer:        &packer,
                        radius:        rect.backdrop_radius,
                        output_bounds: output_bounds,
                        scissor:       scissor,
                        width:         width,
                        height:        height,
                    );
                    emit_overlay_item(
                        packer:   &packer,
                        scissor:  scissor,
                        item:     item,
                        backdrop: true,
                    );
                } else {
                    emit_overlay_item(&packer, scissor, item);
                }
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
                    Vec4 glyph_bounds = item_output_bounds(list, entry.transform, item.bounds);
                    if (!overlay_bounds_reach(glyph_bounds, scissor)) continue;
                    item.transform_clip = transform_clip;
                    emit_overlay_item(&packer, scissor, item);
                }
            case TRIANGLE:
            case SEGMENT:
                OverlayItemGpu item = entry.kind == TRIANGLE
                    ? pack_overlay_triangle(&entry.triangle)
                    : pack_overlay_segment(&entry.segment);
                if (!overlay_bounds_reach(item_output_bounds(list, entry.transform, item.bounds), scissor)) continue;
                item.transform_clip = transform_clip;
                emit_overlay_item(&packer, scissor, item);
        }
    }

    list.prepared.run_count = packer.run_count;
    list.prepared.backdrop_count = packer.backdrop_count;
    list.prepared.transformed = packer.transformed;
    return packer.emitted;
}
