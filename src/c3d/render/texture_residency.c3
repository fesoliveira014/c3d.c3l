module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::material;
import gpu;
import std::math;

<*
 Device footprint of every mip of one texture, all layers.
*>
alias TextureLevelBytes = usz[material::TEXTURE_MIP_CAPACITY];

<*
 Largest extent of the mips every streamed texture keeps resident.
*>
const uint TEXTURE_TAIL_EXTENT = 64; // about 21 KiB of RGBA8 per texture; a full 4096-slot store idles under 90 MiB

<*
 Raise bytes admitted per frame after the first raise.
*>
const usz TEXTURE_STREAM_FRAME_BYTES = 8 << 20; // matches OVERSIZED_UPLOAD_BYTES, so paced raises stay inside the ring

<*
 Mip-zero texels a frame may regenerate; the first raise is always admitted and counts.
*>
const ulong TEXTURE_REGENERATION_FRAME_TEXELS = 1 << 20; // one 1024² MIP_ZERO raise per frame; supplied mips cost nothing

<*
 Budget fraction the drawn set must fit before the bias relaxes.
*>
const float TEXTURE_BIAS_RELEASE_FRACTION = 0.9f; // one level of headroom against oscillation

const uint NO_RECORD @local = uint::max;
const usz EVICTION_BATCH @local = 128; // records ranked per scan, so a large eviction costs a few passes

<*
 Resident mip range of one store texture and the demand that drives it.
*>
struct TextureResidency {
    uint                  chain_mips;      // zero until this renderer resolved the texture
    uint                  chain_width;
    uint                  chain_height;
    material::PixelFormat format;          // store format; the chain-change comparison reads it
    TextureLevelBytes     level_bytes;     // block aligned, all layers
    uint                  tail_base;       // first mip of the tail; zero for unstreamed records
    uint                  resident_base;   // most detailed resident mip
    uint                  required_base;   // demanded by the last frame; chain_mips when undrawn
    float                 demand_pixels;   // largest biased projected extent in the last frame
    ulong                 last_used_frame; // frame_index of the last resolve that read it
    bool                  eligible;        // the shape streams: 2D, one layer, mipped, sampled only, with a source
    bool                  full_reader;     // read outside material slots; stays set across replaces
    bool                  streamed;        // eligible && !full_reader
    bool                  raisable;        // the store source is present; false pins the record
    bool                  regenerates;     // a raise rebuilds the chain from mip zero
}

<*
 Budget and pacing one planning step works under.
*>
struct TextureBudget {
    usz   budget_bytes; // zero disables evictions and the bias
    usz   frame_bytes;  // raise bytes admitted after the first raise
    ulong frame;        // frame_index the step runs in
    ulong frame_texels; // regeneration texels per frame; the first raise is admitted regardless
}

<*
 One planned change of a texture's resident base.
*>
struct TextureResidencyChange {
    uint index; // slot in the renderer's mirrors
    uint new_base;
}

<*
 Plan totals the step reports.
*>
struct TextureResidencyPlan {
    usz  change_count;
    uint evictions;
    uint raises;
    uint starved;     // drawn, streamed records still less detailed than their biased target
    usz  total_bytes; // resident bytes once every change applies
}

struct EvictionPick @local {
    ulong frame;
    uint  index;
}

struct TexturePlanState @local {
    TextureResidency[]       textures;
    TextureResidencyChange[] changes;
    usz                      budget;
    usz                      held_bytes; // non-drawn records, full readers at base zero
    usz                      total;
    usz                      change_count;
    uint                     evictions;
    uint                     raises;
}

fn bool EvictionPick.after(self, EvictionPick other) {
    return self.frame > other.frame || (self.frame == other.frame && self.index > other.index);
}

fn void TexturePlanState.measure(&self) {
    foreach (&record : self.textures) {
        if (!record.chain_mips) continue;

        uint settled = !record.streamed && record.raisable ? 0 : record.resident_base;
        usz bytes = texture_range_bytes(record, settled);
        self.total += bytes;

        if (!texture_plan_drawn(record)) self.held_bytes += bytes;
    }
}

fn usz TexturePlanState.drawn_need(&self, uint bias) {
    usz bytes;

    foreach (&record : self.textures) {
        if (texture_plan_drawn(record)) bytes += texture_range_bytes(record, texture_plan_target(record, bias));
    }

    return bytes;
}

fn void TexturePlanState.push(&self, uint index, uint new_base) {
    self.changes[self.change_count] = { .index = index, .new_base = new_base };
    self.change_count++;
}

fn void TexturePlanState.evict(&self, uint index, uint new_base) {
    TextureResidency* record = &self.textures[index];
    usz freed = texture_range_bytes(record, record.resident_base) - texture_range_bytes(record, new_base);
    self.total -= freed;

    if (!texture_plan_drawn(record)) self.held_bytes -= freed;
    self.push(index, new_base);
    self.evictions++;
}

fn void TexturePlanState.evict_undrawn(&self, uint bias) {
    usz drawn_zero = self.drawn_need(0);
    usz drawn_relax = bias > 0 ? self.drawn_need(bias - 1) : 0;
    double release = (double)TEXTURE_BIAS_RELEASE_FRACTION * (double)self.budget;
    EvictionPick cursor;
    bool has_cursor;
    EvictionPick[EVICTION_BATCH] batch;

    while (self.total > self.budget
      || self.held_bytes + drawn_zero > self.budget
      || (bias > 0 && (double)(self.held_bytes + drawn_relax) > release)) {
        usz found = self.collect_evictions(batch[..], has_cursor, cursor);

        if (!found) break;

        foreach (pick : batch[:found]) {
            if (self.total <= self.budget && self.held_bytes + drawn_zero <= self.budget
              && !(bias > 0 && (double)(self.held_bytes + drawn_relax) > release)) return;

            has_cursor = true;
            cursor = pick;
            self.evict(pick.index, self.textures[pick.index].tail_base);
        }
    }
}

fn usz TexturePlanState.collect_evictions(&self, EvictionPick[] picks, bool has_cursor, EvictionPick cursor) {
    usz found;

    foreach (index, &record : self.textures) {
        if (!texture_plan_candidate(record) || texture_plan_drawn(record)) continue;
        if (record.resident_base >= record.tail_base) continue;

        EvictionPick pick = { .frame = record.last_used_frame, .index = (uint)index };

        if (has_cursor && !pick.after(cursor)) continue;
        if (found == picks.len && !picks[found - 1].after(pick)) continue;

        usz slot = found < picks.len ? found++ : found - 1;

        while (slot > 0 && picks[slot - 1].after(pick)) {
            picks[slot] = picks[slot - 1];
            slot--;
        }

        picks[slot] = pick;
    }

    return found;
}

fn uint TexturePlanState.settle_bias(&self, uint bias) {
    uint ceiling;

    foreach (&record : self.textures) {
        if (texture_plan_drawn(record) && record.tail_base > record.required_base) {
            ceiling = math::max(ceiling, record.tail_base - record.required_base);
        }
    }

    bias = math::min(bias, ceiling);

    if (self.held_bytes + self.drawn_need(bias) > self.budget) {
        while (bias < ceiling && self.held_bytes + self.drawn_need(bias) > self.budget) bias++;

        return bias;
    }

    double release = (double)TEXTURE_BIAS_RELEASE_FRACTION * (double)self.budget;

    while (bias > 0 && (double)(self.held_bytes + self.drawn_need(bias - 1)) <= release) bias--;

    return bias;
}

fn void TexturePlanState.evict_drawn(&self, uint bias) {
    if (self.total <= self.budget) return;

    foreach (index, &record : self.textures) {
        if (!texture_plan_drawn(record)) continue;

        uint target = texture_plan_target(record, bias);

        if (record.resident_base < target) self.evict((uint)index, target);
    }
}

fn void TexturePlanState.push_full_raises(&self) {
    foreach (index, &record : self.textures) {
        if (!record.chain_mips || record.streamed || !record.raisable || record.resident_base == 0) continue;

        self.push((uint)index, 0);
        self.raises++;
    }
}

fn uint TexturePlanState.raise(
    &self,
    bool limited,
    uint bias,
    usz frame_bytes,
    ulong frame_texels,
) {
    uint starved;
    uint admitted_count;
    usz admitted_bytes;
    ulong admitted_texels;
    uint widest;

    foreach (&record : self.textures) {
        if (!texture_plan_candidate(record) || (limited && !texture_plan_drawn(record))) continue;

        uint target = limited ? texture_plan_target(record, bias) : 0;

        if (record.resident_base > target) widest = math::max(widest, record.resident_base - target);
    }

    for (uint deficit = widest; deficit > 0; deficit--) {
        foreach (index, &record : self.textures) {
            if (!texture_plan_candidate(record)) continue;
            if (limited && !texture_plan_drawn(record)) continue;

            uint target = limited ? texture_plan_target(record, bias) : 0;

            if (record.resident_base <= target || record.resident_base - target != deficit) continue;

            usz delta = texture_range_bytes(record, target) - texture_range_bytes(record, record.resident_base);
            bool fits = !limited || self.total + delta <= self.budget;
            ulong texels = record.regenerates ? (ulong)record.chain_width * record.chain_height : 0;
            bool paced = admitted_count == 0
              || (admitted_bytes + delta <= frame_bytes && admitted_texels + texels <= frame_texels);

            if (!fits || !paced) {
                if (texture_plan_drawn(record)) starved++;
                continue;
            }

            if (admitted_count > 0) admitted_bytes += delta;
            admitted_texels += texels;
            admitted_count++;
            self.total += delta;
            self.push((uint)index, target);
            self.raises++;
        }
    }

    return starved;
}

<*
 Residency of a store texture as this renderer holds it.
 @return? c3d::INVALID_ID
*>
fn TextureResidency? Renderer.texture_residency(&self, TextureId texture) {
    if (!self.assets.textures.is_live(texture)) return c3d::INVALID_ID~;
    if (!c3d::same_id(self.textures[texture.index].asset, texture)) return {};

    return self.residencies[texture.index];
}

<*
 Replace the resident-byte budget; the next frame's step applies it.
 @param bytes : "Zero lifts the budget; streamed textures drain to full residency."
*>
fn void Renderer.set_texture_budget(&self, usz bytes) {
    self.texture_budget_bytes = bytes;
}

<*
 Whether a texture of this shape and source streams.
 @pure
*>
fn bool texture_eligible(material::TextureDesc desc, TextureSourceKind source, uint chain_mips) {
    if (desc.depth || desc.is_cube || desc.layers != 1 || desc.storage || chain_mips < 2) return false;

    switch (source) {
        case MIP_ZERO: return desc.generate_mips;
        case SUPPLIED_MIPS: return true;
        case EMPTY: return false;
    }
}

<*
 Footprint of every mip of a chain from its description.
 @param chain_mips : "Levels of the full chain."
 @return? c3d::INVALID_ARGUMENT
 @require chain_mips > 0 && chain_mips <= material::TEXTURE_MIP_CAPACITY
*>
fn TextureLevelBytes? texture_level_bytes(material::TextureDesc desc, uint chain_mips) {
    TextureLevelBytes bytes;
    usz layers = desc.layers > 0 ? desc.layers : 1;

    for (uint mip = 0; mip < chain_mips; mip++) {
        usz layer_bytes = material::texture_mip_bytes(desc, mip)!;

        if (layer_bytes > (usz)sz::max / layers) return c3d::INVALID_ARGUMENT~;

        bytes[mip] = layer_bytes * layers;
    }

    return bytes;
}

<*
 Bytes of the mips from base to the end of the chain.
 @param [&in] residency : "Filled record."
 @require base <= residency.chain_mips
 @pure
*>
fn usz texture_range_bytes(TextureResidency* residency, uint base) {
    usz bytes;

    for (uint mip = base; mip < residency.chain_mips; mip++) bytes += residency.level_bytes[mip];

    return bytes;
}

<*
 First mip whose larger extent is at most the tail extent, clamped to the last mip.
 @require chain_extent > 0, chain_mips > 0
 @pure
*>
fn uint texture_tail_base(uint chain_extent, uint chain_mips) {
    uint base;

    while (base < chain_mips - 1 && (chain_extent >> base) > TEXTURE_TAIL_EXTENT) base++;

    return base;
}

<*
 Most detailed mip a screen footprint needs, before the budget bias.
 @param screen_pixels : "Biased projected extent; infinity needs mip zero."
 @param bias : "Levels added to the requirement."
 @require chain_extent > 0, chain_mips > 0
 @pure
*>
fn uint texture_required_base(
    uint chain_extent,
    uint chain_mips,
    float screen_pixels,
    uint bias,
) {
    uint last = chain_mips - 1;
    uint level;

    if (screen_pixels < (float)chain_extent) {
        double pixels = screen_pixels >= 1.0f ? (double)screen_pixels : 1.0;
        level = (uint)math::floor(math::log2((double)chain_extent / pixels));
    }

    return math::min(math::min(level, last) + bias, last);
}

<*
 Plan the evictions and raises that keep resident bytes under the budget.
 @param [in] textures : "One record per mirror slot; unresolved records are skipped."
 @param [&inout] bias : "Global level bias, raised or relaxed by the plan."
 @param [out] changes : "Evictions first, then full raises, then raises."
 @require changes.len >= textures.len
*>
fn TextureResidencyPlan plan_texture_residency(
    TextureResidency[] textures,
    TextureBudget budget,
    uint* bias,
    TextureResidencyChange[] changes,
) {
    TexturePlanState state = {
        .textures = textures,
        .changes = changes,
        .budget = budget.budget_bytes,
    };
    state.measure();
    bool limited = budget.budget_bytes > 0;

    if (limited) {
        state.evict_undrawn(*bias);
        *bias = state.settle_bias(*bias);
        state.evict_drawn(*bias);
    } else {
        *bias = 0;
    }

    state.push_full_raises();
    uint starved = state.raise(
        limited: limited,
        bias: *bias,
        frame_bytes: budget.frame_bytes,
        frame_texels: budget.frame_texels,
    );

    return {
        .change_count = state.change_count,
        .evictions = state.evictions,
        .raises = state.raises,
        .starved = starved,
        .total_bytes = state.total,
    };
}

fn bool texture_plan_candidate(TextureResidency* record) @local {
    return record.chain_mips > 0 && record.streamed && record.raisable;
}

fn bool texture_plan_drawn(TextureResidency* record) @local {
    return texture_plan_candidate(record) && record.required_base < record.chain_mips;
}

fn uint texture_plan_target(TextureResidency* record, uint bias) @local {
    return math::min(record.tail_base, record.required_base + bias);
}

fn void? step_texture_residency(Renderer* renderer) @private {
    @pool() {
        expand_material_demand(renderer);

        foreach (index, &record : renderer.residencies) {
            if (!record.chain_mips) continue;

            TextureId asset = renderer.textures[index].asset;
            record.raisable = texture_source_present(renderer.assets.texture(asset))
              && texture_current(renderer, asset);
            uint chain_extent = math::max(record.chain_width, record.chain_height);
            record.required_base = record.demand_pixels > 0
              ? texture_required_base(chain_extent, record.chain_mips, record.demand_pixels, 0)
              : record.chain_mips;
        }

        TextureBudget budget = {
            .budget_bytes = renderer.texture_budget_bytes,
            .frame_bytes = TEXTURE_STREAM_FRAME_BYTES,
            .frame_texels = TEXTURE_REGENERATION_FRAME_TEXELS,
            .frame = renderer.frame_index,
        };
        TextureResidencyPlan plan = plan_texture_residency(
            textures: renderer.residencies,
            budget: budget,
            bias: &renderer.texture_bias,
            changes: renderer.residency_changes,
        );
        uint deferred;

        foreach (change : renderer.residency_changes[:plan.change_count]) {
            if (catch excuse = apply_texture_residency(renderer, change)) {
                if (excuse != gpu::SLOT_TABLE_FULL && excuse != gpu::DESCRIPTOR_HEAP_FULL
                  && excuse != gpu::OUT_OF_DEVICE_MEMORY) return excuse~;

                deferred++;
            }
        }

        usz bytes;

        foreach (&record : renderer.residencies) {
            if (record.chain_mips) bytes += texture_range_bytes(record, record.resident_base);
        }

        renderer.stats.texture_bytes = bytes;
        renderer.stats.texture_raises = plan.raises;
        renderer.stats.texture_evictions = plan.evictions;
        renderer.stats.texture_bias = renderer.texture_bias;
        renderer.stats.textures_starved = plan.starved;
        renderer.stats.texture_changes_deferred = deferred;
    };
}

fn void? apply_texture_residency(Renderer* renderer, TextureResidencyChange change) @private {
    TextureRes* mirror = &renderer.textures[change.index];
    TextureResidency* residency = &renderer.residencies[change.index];
    TextureAsset* record = renderer.assets.texture(mirror.asset);
    uint old_base = residency.resident_base;
    uint new_base = change.new_base;
    gpu::TextureDesc description = texture_gpu_description(
        desc: record.desc,
        format: mirror.format,
        chain_mips: residency.chain_mips,
        base: new_base,
        copy_source: true,
    );
    gpu::TextureHandle image = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, image);

    gpu::TextureViewDesc view_desc;
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, image, &view_desc)!;
    defer catch (void)gpu::destroy_texture_view(&renderer.device, view);

    PendingTextureUpload pending = {
        .asset = mirror.asset,
        .revision = record.header.revision,
        .texture = image,
        .semantic = mirror.semantic,
        .survivor_source = mirror.texture,
        .survivor_before = mirror.state,
    };

    for (uint level = math::max(old_base, new_base); level < residency.chain_mips; level++) {
        pending.survivor_copies[pending.survivor_count] = {
            .src = mirror.texture,
            .src_mip = level - old_base,
            .dst = image,
            .dst_mip = level - new_base,
        };
        pending.survivor_count++;
    }

    if (new_base < old_base) {
        stage_texture_levels(
            renderer: renderer,
            record: record,
            pending: &pending,
            description: &description,
            first_level: new_base,
            level_count: old_base - new_base,
        )!;
    }

    TextureCoverageResource* coverage_resource = mirror.coverage_resource;
    TextureSemantic semantic = mirror.semantic;
    mirror.coverage_resource = null;

    retire_texture(renderer, mirror);

    *mirror = {
        .asset = pending.asset,
        .revision = pending.revision,
        .semantic = semantic,
        .coverage_resource = coverage_resource,
        .binding_revision = mirror.binding_revision + 1,
        .texture = image,
        .view = view,
        .width = description.width,
        .height = description.height,
        .mip_count = description.mip_levels,
        .layers = 1,
        .copy_source = true,
        .format = description.format,
    };
    remember_texture_state(&renderer.texture_state_undo, mirror);
    renderer.pending_texture_uploads.push(pending);
    renderer.stats.uploads++;
    residency.resident_base = new_base;
}

fn void? stage_texture_levels(
    Renderer* renderer,
    TextureAsset* record,
    PendingTextureUpload* pending,
    gpu::TextureDesc* description,
    uint first_level,
    uint level_count,
) @local {
    TextureMipChain chain;
    TextureMipLayout layout;

    switch (record.source_kind) {
        case MIP_ZERO:
            chain = create_texture_mips(allocator: tmem, desc: record.desc, pixels: record.pixels,
                first_mip: first_level, statistics: &record.coverage_statistics)!;
            layout = { .total_bytes = chain.pixels.len, .mip_count = chain.mip_count, .offsets = chain.offsets };

        case SUPPLIED_MIPS:
            layout = supplied_texture_mip_layout(record.desc, record.supplied_mips, first_mip: first_level)!;

        case EMPTY:
            unreachable();
    }

    usz staged_bytes = level_count < layout.mip_count ? layout.offsets[level_count] : layout.total_bytes;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, staged_bytes, UPLOAD_RING_ALIGNMENT)!;

    switch (record.source_kind) {
        case MIP_ZERO:
            mem::copy(staging.bytes.ptr, chain.pixels.ptr, (sz)staged_bytes);

        case SUPPLIED_MIPS:
            usz offset;

            foreach (level : record.supplied_mips) {
                if (level.mip < first_level || level.mip >= first_level + level_count) continue;

                mem::copy(staging.bytes.ptr + offset, level.bytes.ptr, level.bytes.len);
                offset += level.bytes.len;
            }

        case EMPTY:
            unreachable();
    }

    pending.mip_count = level_count;

    for (uint mip = 0; mip < level_count; mip++) {
        usz bytes = gpu::texture_mip_bytes(description, mip)!;
        pending.copies[mip] = {
            .src = staging.span.checked_subspan(layout.offsets[mip], bytes)!,
            .texture = pending.texture,
            .mip = mip,
            .layer_count = 1,
        };
    }

    renderer.stats.upload_bytes += (uint)staged_bytes;
}

fn void expand_material_demand(Renderer* renderer) @private {
    foreach (&record : renderer.residencies) record.demand_pixels = 0;

    if (!renderer.frame_index) return;

    ulong previous = renderer.frame_index - 1;

    foreach (&mirror : renderer.materials) {
        if (mirror.demand_frame != previous || mirror.demand_pixels <= 0) continue;
        if (!renderer.assets.materials.is_live(mirror.asset)) continue;

        raise_bindings_demand(renderer, &mirror.bindings, mirror.demand_pixels);
        MaterialAsset* asset = renderer.assets.material(mirror.asset);

        if (asset.data.kind != MaterialKind.CUSTOM) continue;

        foreach (reference : asset.data.custom.references) {
            if (!reference.generation || !renderer.assets.materials.is_live(reference)) continue;

            MaterialRes* referenced = &renderer.materials[reference.index];

            if (c3d::same_id(referenced.asset, reference)) {
                raise_bindings_demand(renderer, &referenced.bindings, mirror.demand_pixels);
            }
        }
    }
}

fn void raise_bindings_demand(Renderer* renderer, MaterialBindings* bindings, float pixels) @local {
    TextureBinding*[*] fixed = {
        &bindings.base_color, &bindings.metallic_roughness, &bindings.normal, &bindings.occlusion,
        &bindings.emissive, &bindings.gradient, &bindings.clearcoat, &bindings.clearcoat_roughness,
        &bindings.clearcoat_normal, &bindings.sheen_color, &bindings.sheen_roughness, &bindings.specular,
        &bindings.specular_color, &bindings.anisotropy, &bindings.transmission, &bindings.thickness,
    };

    foreach (binding : fixed) raise_binding_demand(renderer, binding, pixels);

    foreach (&binding : bindings.custom) raise_binding_demand(renderer, binding, pixels);
}

fn void raise_binding_demand(Renderer* renderer, TextureBinding* binding, float pixels) @local {
    if (!binding.present || !renderer.assets.textures.is_live(binding.texture)) return;

    TextureResidency* record = &renderer.residencies[binding.texture.index];
    record.demand_pixels = math::max(record.demand_pixels, pixels);
}

fn void note_material_demand(
    Renderer* renderer,
    MaterialRes* material,
    Camera camera,
    Vec3 camera_position,
    Aabb bounds,
    float viewport_height,
    float mip_bias,
) @private {
    float pixels = camera::projected_size(camera, camera_position, maths::aabb_sphere(bounds), viewport_height)
      * math::exp2(-mip_bias);

    if (!(pixels > 0)) return;

    if (material.demand_frame != renderer.frame_index) {
        material.demand_frame = renderer.frame_index;
        material.demand_pixels = 0;
    }

    material.demand_pixels = math::max(material.demand_pixels, pixels);
}
