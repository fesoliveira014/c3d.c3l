module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import gpu;
import std::collections::list;
import std::math;

<*
 Pool of open model preparations addressed by PrepareId.
*>
alias PreparePool = Pool{PrepareRecord, PrepareId};

<*
 Staged bytes one advance_prepares call spends when no budget is given.
*>
const usz PREPARE_FRAME_BUDGET_BYTES = 1 << 20; // under OVERSIZED_UPLOAD_BYTES; 4.3 ms CPU -O3, 9.7 ms default (WSL)

<*
 Model preparations that can be open at once.
*>
const uint PREPARE_CAPACITY = 4; // one unit list per record (Sponza: 376 units); bounds waiting models, not frame cost

<*
 Stage of a budgeted model preparation.
*>
enum PrepareState {
    PENDING,
    SUBMITTED,
    <* Every unit whose asset was live is uploaded and its frame completed. *>
    READY,
    FAILED,
}

enum PrepareUnitKind @private {
    TEXTURE,
    GEOMETRY,
    MATERIAL,
    PIPELINES,
    FINISH,
}

enum PrepareAction @private {
    DEAD,
    CURRENT,
    STAGE,
}

<*
 Progress of a budgeted model preparation.
*>
struct PrepareProgress {
    PrepareState state;
    usz          bytes_total; // staged size, recorded at begin, of the listed units
    usz          bytes_done;  // recorded sizes of the units done, staged or skipped; reaches bytes_total
    uint         units_total;
    uint         units_done;
    fault        failure;
}

struct PrepareUnit @private {
    PrepareUnitKind kind;
    TextureId       texture;
    GeometryId      geometry;
    MaterialId      material;
    bool            morphed;
    usz             bytes;
    bool            done;
}

struct PrepareRecord @private {
    PrepareUnit[] units;
    uint          next;
    ulong         sequence;
    ulong         done_frame;
    PrepareState  state;
    fault         failure;
    usz           bytes_total;
    usz           bytes_done;
    uint          units_done;
    bool          transmission;
    bool          open;
}

struct PrepareMark @private {
    PrepareId record;
    uint      unit;
}

struct PrepareBudget @private {
    usz budget;
    usz spent;
}

struct PrepareCheck @private {
    bool live;
    bool current;
    usz  size;
}

<*
 Open a budgeted preparation of a published model.
 @return? c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn PrepareId? Renderer.begin_prepare_model(&self, ModelId model) {
    ModelAsset* asset = self.assets.models.try_get(model)!;
    if (!self.prepares.free_count) return c3d::CAPACITY_EXCEEDED~;
    PrepareRecord record = {
        .units    = enumerate_prepare_units(self, &asset.data),
        .sequence = ++self.next_prepare_sequence,
        .state    = PrepareState.PENDING,
        .open     = true,
    };
    foreach (unit : record.units) record.bytes_total += unit.bytes;
    return self.prepares.add(record);
}

<*
 Stage the next units of open preparations within a byte budget.
 Does not abort the frame on a fault; the caller's abort returns the call's units to not done.
 @param budget_bytes : "Staged bytes this call may spend; a unit runs over it only when first."
 @return? gpu::SLOT_TABLE_FULL, gpu::DEVICE_BUSY, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::UNSUPPORTED_FEATURE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::INVALID_RESOURCE_STATE, gpu::RESOURCE_IN_USE, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::WAIT_TIMEOUT
 @require self.frame_open
*>
fn void? Renderer.advance_prepares(&self, usz budget_bytes = PREPARE_FRAME_BUDGET_BYTES) {
    promote_ready_prepares(self);
    begin_material_scope(self);
    defer end_material_scope(self);
    PrepareId[PREPARE_CAPACITY] order;
    uint count = prepare_order(self, order[..]);
    PrepareBudget budget = { .budget = budget_bytes };
    foreach (id : order[:count]) {
        bool stopped;
        @pool() {
            stopped = advance_record(self, id, &budget)!;
        };
        if (stopped) return;
    }
}

<*
 Progress of a preparation.
 @return "FAILED with c3d::INVALID_ID for a released or stale id."
*>
fn PrepareProgress Renderer.prepare_progress(&self, PrepareId id) {
    PrepareRecord*? record = self.prepares.try_get(id);
    if (catch record) return { .state = PrepareState.FAILED, .failure = c3d::INVALID_ID };
    return {
        .state       = record.state,
        .bytes_total = record.bytes_total,
        .bytes_done  = record.bytes_done,
        .units_total = (uint)record.units.len,
        .units_done  = record.units_done,
        .failure     = record.failure,
    };
}

<*
 Release a preparation in any state; called outside a frame.
 @return? c3d::INVALID_ID
 @require !self.frame_open
*>
fn void? Renderer.end_prepare(&self, PrepareId id) {
    PrepareRecord* record = self.prepares.try_get(id)!;
    alloc::free(self.allocator, record.units.ptr);
    *record = {};
    self.prepares.remove(id);
}

fn PrepareUnit[] enumerate_prepare_units(Renderer* renderer, ModelTemplate* template) @private {
    AssetStore* assets = renderer.assets;
    PrepareUnit[] units;
    @pool() {
        List{PrepareUnit} listed;
        listed.init(tmem);
        foreach (&mesh : template.meshes) {
            bool geometry_live = assets.geometries.is_live(mesh.geometry);
            bool material_live = assets.materials.is_live(mesh.material);
            if (!geometry_live || !material_live) {
                renderer.stats.dangling_refs++;
                continue;
            }
            Material* data = &assets.material(mesh.material).data;
            material::@each_texture_reference(data; TextureId* texture, SamplerId* sampler) {
                if (texture_needed(renderer, listed.array_view(), *texture)) {
                    listed.push({
                        .kind    = PrepareUnitKind.TEXTURE,
                        .texture = *texture,
                        .bytes   = prepare_texture_bytes(assets.texture(*texture)),
                    });
                }
            };
            if (geometry_needed(renderer, listed.array_view(), mesh.geometry)) {
                listed.push({
                    .kind     = PrepareUnitKind.GEOMETRY,
                    .geometry = mesh.geometry,
                    .bytes    = geometry_layout(&assets.geometry(mesh.geometry).data).total_bytes,
                });
            }
            if (!lists_unit(listed.array_view(), PrepareUnitKind.MATERIAL, (Id)mesh.material)) {
                listed.push({ .kind = PrepareUnitKind.MATERIAL, .material = mesh.material, .bytes = MATERIAL_STRIDE });
            }
            listed.push({
                .kind     = PrepareUnitKind.PIPELINES,
                .geometry = mesh.geometry,
                .material = mesh.material,
                .morphed  = mesh.default_morph_weights.len > 0,
            });
        }
        listed.push({ .kind = PrepareUnitKind.FINISH });
        units = alloc::new_array(renderer.allocator, PrepareUnit, (sz)listed.len());
        units[..] = listed.array_view()[..];
    };
    return units;
}

fn bool texture_needed(Renderer* renderer, PrepareUnit[] listed, TextureId texture) @private {
    if (!renderer.assets.textures.is_live(texture) || texture_current(renderer, texture)) return false;
    return !lists_unit(listed, PrepareUnitKind.TEXTURE, (Id)texture);
}

fn bool geometry_needed(Renderer* renderer, PrepareUnit[] listed, GeometryId geometry) @private {
    return !geometry_current(renderer, geometry) && !lists_unit(listed, PrepareUnitKind.GEOMETRY, (Id)geometry);
}

fn bool lists_unit(PrepareUnit[] units, PrepareUnitKind kind, Id asset) @private {
    foreach (&unit : units) {
        if (unit.kind != kind) continue;
        Id id;
        switch (kind) {
            case TEXTURE: id = (Id)unit.texture;
            case GEOMETRY: id = (Id)unit.geometry;
            case MATERIAL: id = (Id)unit.material;
            case PIPELINES:
            case FINISH: continue;
        }
        if (c3d::same_id(id, asset)) return true;
    }
    return false;
}

fn bool texture_current(Renderer* renderer, TextureId texture) @private {
    TextureAsset* record = renderer.assets.texture(texture);
    TextureRes* mirror = &renderer.textures[texture.index];
    if (c3d::same_id(mirror.asset, texture) && mirror.revision == record.header.revision) return true;
    foreach (&pending : renderer.pending_texture_uploads) {
        if (c3d::same_id(pending.asset, texture) && pending.revision == record.header.revision) return true;
    }
    return false;
}

fn bool geometry_current(Renderer* renderer, GeometryId geometry) @private {
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    GeometryAsset* record = renderer.assets.geometry(geometry);
    return c3d::same_id(mirror.asset, geometry) && mirror.revision == record.header.revision;
}

fn usz prepare_texture_bytes(TextureAsset* record) @private {
    switch (record.source_kind) {
        case MIP_ZERO:
            return mip_chain_bytes(record.desc, record.pixels.len);
        case SUPPLIED_MIPS:
            if (try layout = supplied_texture_mip_layout(record.desc, record.supplied_mips)) return layout.total_bytes;
            return 0;
        case EMPTY:
            return 0;
    }
}

fn usz mip_chain_bytes(material::TextureDesc desc, usz base_bytes) @private {
    if (desc.depth || !desc.generate_mips) return base_bytes;
    usz texel_bytes = base_bytes / ((usz)desc.width * desc.height * desc.layers);
    usz total;
    for (uint mip = 0; mip < texture_mip_count(desc.width, desc.height); mip++) {
        total += (usz)math::max(1u, desc.width >> mip) * math::max(1u, desc.height >> mip) * texel_bytes * desc.layers;
    }
    return total;
}

fn PrepareCheck check_unit(Renderer* renderer, PrepareUnit* unit) @private {
    AssetStore* assets = renderer.assets;
    switch (unit.kind) {
        case TEXTURE:
            if (!assets.textures.is_live(unit.texture)) return { .live = false };
            if (texture_current(renderer, unit.texture)) return { .live = true, .current = true };
            return { .live = true, .size = prepare_texture_bytes(assets.texture(unit.texture)) };
        case GEOMETRY:
            if (!assets.geometries.is_live(unit.geometry)) return { .live = false };
            if (geometry_current(renderer, unit.geometry)) return { .live = true, .current = true };
            return { .live = true, .size = geometry_layout(&assets.geometry(unit.geometry).data).total_bytes };
        case MATERIAL:
            return { .live = assets.materials.is_live(unit.material), .size = MATERIAL_STRIDE };
        case PIPELINES:
            return { .live = assets.geometries.is_live(unit.geometry) && assets.materials.is_live(unit.material) };
        case FINISH:
            return { .live = true };
    }
}

fn uint plan_prepare_units(PrepareBudget* budget, PrepareCheck[] checks, PrepareAction[] actions) @private {
    foreach (uint index, check : checks) {
        if (!check.live) {
            actions[index] = PrepareAction.DEAD;
            continue;
        }
        if (check.current) {
            actions[index] = PrepareAction.CURRENT;
            continue;
        }
        if (budget.spent > 0 && budget.spent + check.size > budget.budget) return index;
        budget.spent += check.size;
        actions[index] = PrepareAction.STAGE;
    }
    return (uint)checks.len;
}

fn bool? advance_record(Renderer* renderer, PrepareId id, PrepareBudget* budget) @private {
    PrepareRecord* record = renderer.prepares.get(id);
    PrepareUnit[] remaining = record.units[record.next..];
    PrepareCheck[] checks = alloc::new_array(tmem, PrepareCheck, (sz)remaining.len);
    foreach (index, &unit : remaining) checks[index] = check_unit(renderer, unit);
    PrepareAction[] actions = alloc::new_array(tmem, PrepareAction, (sz)remaining.len);
    uint taken = plan_prepare_units(budget, checks, actions);
    foreach (action : actions[:taken]) {
        uint index = record.next;
        PrepareUnit* unit = &record.units[index];
        switch (action) {
            case DEAD:
                if (unit.kind != PrepareUnitKind.PIPELINES) renderer.stats.dangling_refs++;
            case CURRENT:
                break;
            case STAGE:
                uint staged_before = renderer.stats.upload_bytes;
                if (catch excuse = run_prepare_unit(renderer, record, unit)) {
                    if (!fails_record(excuse)) return excuse~;
                    record.state = PrepareState.FAILED;
                    record.failure = excuse;
                    return false;
                }
                renderer.stats.prepare_units++;
                renderer.stats.prepare_bytes += (usz)(renderer.stats.upload_bytes - staged_before);
        }
        mark_unit_done(renderer, id, index);
    }
    return taken < remaining.len;
}

fn void? run_prepare_unit(Renderer* renderer, PrepareRecord* record, PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE:
            resolve_texture(renderer, unit.texture)!;
        case GEOMETRY:
            resolve_geometry(renderer, unit.geometry)!;
        case MATERIAL:
            resolve_material(renderer, unit.material)!;
        case PIPELINES:
            MeshPreparation prepared = prepare_mesh(
                renderer:    renderer,
                geometry_id: unit.geometry,
                material_id: unit.material,
                morphed:     unit.morphed,
                depth:       true,
                gbuffer:     renderer.has_deferred_view(),
            )!;
            record.transmission |= prepared.transmission;
        case FINISH:
            prepare_finish(renderer, record.transmission)!;
    }
}

fn bool fails_record(fault excuse) @private {
    return excuse == c3d::INVALID_ID || excuse == c3d::SHADER_NOT_FOUND || excuse == c3d::INVALID_ARGUMENT
        || excuse == c3d::UNSUPPORTED || excuse == c3d::ASSET_DATA_UNAVAILABLE || excuse == gpu::SHADER_INVALID
        || excuse == gpu::PIPELINE_CREATE_FAILED;
}

fn void mark_unit_done(Renderer* renderer, PrepareId id, uint index) @private {
    PrepareRecord* record = renderer.prepares.get(id);
    PrepareUnit* unit = &record.units[index];
    unit.done = true;
    record.bytes_done += unit.bytes;
    record.units_done++;
    record.next = index + 1;
    renderer.pending_prepare_marks.push({ .record = id, .unit = index });
    if (record.next == record.units.len) {
        record.state = PrepareState.SUBMITTED;
        record.done_frame = renderer.frame_index;
    }
}

fn void rollback_prepare_marks(Renderer* renderer) @private {
    while (try mark = renderer.pending_prepare_marks.pop()) {
        PrepareRecord* record = renderer.prepares.get(mark.record);
        PrepareUnit* unit = &record.units[mark.unit];
        unit.done = false;
        record.bytes_done -= unit.bytes;
        record.units_done--;
        record.next = mark.unit;
        if (record.state == PrepareState.SUBMITTED) record.state = PrepareState.PENDING;
    }
}

fn void promote_ready_prepares(Renderer* renderer) @private {
    foreach (&record : renderer.prepares.items) {
        if (!record.open || record.state != PrepareState.SUBMITTED) continue;
        if (renderer.frame_index >= record.done_frame + FRAMES_IN_FLIGHT) record.state = PrepareState.READY;
    }
}

fn uint prepare_order(Renderer* renderer, PrepareId[] order) @private {
    uint count;
    foreach (uint index, &record : renderer.prepares.items) {
        if (!record.open || record.state != PrepareState.PENDING) continue;
        uint position = count++;
        while (position > 0 && renderer.prepares.items[order[position - 1].index].sequence > record.sequence) {
            order[position] = order[position - 1];
            position--;
        }
        order[position] = { .index = index, .generation = renderer.prepares.generations[index] };
    }
    return count;
}

fn void free_prepares(Renderer* renderer) @private {
    foreach (&record : renderer.prepares.items) {
        if (record.open) alloc::free(renderer.allocator, record.units.ptr);
    }
    pool::destroy_pool{PrepareRecord, PrepareId}(&renderer.prepares);
    renderer.pending_prepare_marks.free();
}
