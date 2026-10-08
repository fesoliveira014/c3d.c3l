module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

<*
 Largest extent of the mips every streamed texture keeps resident.
*>
const uint TEXTURE_TAIL_EXTENT = 64; // about 21 KiB of RGBA8 per texture; a full 4096-slot store idles under 90 MiB

<*
 Raise bytes admitted per frame after the first raise.
*>
const usz TEXTURE_STREAM_FRAME_BYTES = 8 << 20; // matches OVERSIZED_UPLOAD_BYTES, so paced raises stay inside the ring

<*
 Budget fraction the drawn set must fit before the bias relaxes.
*>
const float TEXTURE_BIAS_RELEASE_FRACTION = 0.9f; // one level of headroom against oscillation

const uint NO_RECORD @local = uint::max;

<*
 Device footprint of every mip of one texture, all layers.
*>
alias TextureLevelBytes = usz[material::TEXTURE_MIP_CAPACITY];

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
}

<*
 Budget and pacing one planning step works under.
*>
struct TextureBudget {
    usz   budget_bytes; // zero disables evictions and the bias
    usz   frame_bytes;  // raise bytes admitted after the first raise
    ulong frame;        // frame_index the step runs in
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
    uint starved = state.raise(limited, *bias, budget.frame_bytes);

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
    bool has_cursor;
    ulong cursor_frame;
    uint cursor_index;

    while (self.total > self.budget
      || self.held_bytes + drawn_zero > self.budget
      || (bias > 0 && (double)(self.held_bytes + drawn_relax) > release)) {
        uint pick = NO_RECORD;
        foreach (index, &record : self.textures) {
            if (!texture_plan_candidate(record) || texture_plan_drawn(record)) continue;
            if (record.resident_base >= record.tail_base) continue;

            bool after = !has_cursor || record.last_used_frame > cursor_frame
              || (record.last_used_frame == cursor_frame && index > cursor_index);
            if (!after) continue;
            if (pick == NO_RECORD || record.last_used_frame < self.textures[pick].last_used_frame) pick = (uint)index;
        }
        if (pick == NO_RECORD) break;

        has_cursor = true;
        cursor_frame = self.textures[pick].last_used_frame;
        cursor_index = pick;
        self.evict(pick, self.textures[pick].tail_base);
    }
}

fn uint TexturePlanState.settle_bias(&self, uint bias) {
    uint ceiling;
    foreach (&record : self.textures) {
        if (texture_plan_drawn(record) && record.tail_base > record.required_base) {
            ceiling = math::max(ceiling, record.tail_base - record.required_base);
        }
    }

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

fn uint TexturePlanState.raise(&self, bool limited, uint bias, usz frame_bytes) {
    uint starved;
    uint admitted_count;
    usz admitted_bytes;
    for (uint deficit = material::TEXTURE_MIP_CAPACITY; deficit > 0; deficit--) {
        foreach (index, &record : self.textures) {
            if (!texture_plan_candidate(record)) continue;
            if (limited && !texture_plan_drawn(record)) continue;

            uint target = limited ? texture_plan_target(record, bias) : 0;
            if (record.resident_base <= target || record.resident_base - target != deficit) continue;

            usz delta = texture_range_bytes(record, target) - texture_range_bytes(record, record.resident_base);
            bool fits = !limited || self.total + delta <= self.budget;
            bool paced = admitted_count == 0 || admitted_bytes + delta <= frame_bytes;
            if (!fits || !paced) {
                if (texture_plan_drawn(record)) starved++;
                continue;
            }

            if (admitted_count > 0) admitted_bytes += delta;
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

    return self.residencies[texture.index];
}

fn void? step_texture_residency(Renderer* renderer) @private {
    usz bytes;
    foreach (&record : renderer.residencies) {
        if (record.chain_mips) bytes += texture_range_bytes(record, record.resident_base);
    }
    renderer.stats.texture_bytes = bytes;
}
