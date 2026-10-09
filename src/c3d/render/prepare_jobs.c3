module c3d::render;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import gpu;
import std::collections::list;
import std::collections::map;
import std::math;
import std::time;
import std::time::clock;

struct PrepareIndex @local {
    HashMap{ulong, uint} textures;
    HashMap{ulong, bool} geometries;
    HashMap{ulong, bool} materials;
    HashMap{ulong, bool} samplers;
    HashMap{ulong, bool} shaders;
}

macro ulong prepare_identity(id) @local => ((ulong)id.generation << 32) | id.index;

fn void enumerate_prepare_record(Renderer* renderer, PrepareRecord* record) @private {
    @pool() {
        List{PrepareUnit} listed;
        listed.init(tmem);
        PrepareIndex index;
        index.textures.init(tmem);
        index.geometries.init(tmem);
        index.materials.init(tmem);
        index.samplers.init(tmem);
        index.shaders.init(tmem);
        ModelTemplate* template = &renderer.assets.model(record.model).data;
        foreach (mesh : template.meshes) append_prepare_mesh(
            renderer: renderer,
            listed: &listed,
            index: &index,
            geometry: mesh.geometry,
            material: mesh.material,
            morphed: mesh.default_morph_weights.len > 0,
        );
        foreach (group : template.lod_groups) {
            foreach (part : group.desc.parts) append_prepare_mesh(
                renderer: renderer,
                listed: &listed,
                index: &index,
                geometry: part.geometry,
                material: part.material,
                morphed: false,
            );
        }
        append_prepare_finish(renderer, &listed);
        deduplicate_prepare_pipeline_units(&listed);
        foreach (&unit : listed) {
            if (unit.kind == PrepareUnitKind.TEXTURE && renderer.assets.textures.is_live(unit.texture)) {
                unit.texture_base = preparation_texture_base(renderer, unit.texture, unit.full_reader);
                unit.staged.mip = unit.texture_base;
                unit.bytes = prepare_texture_bytes(renderer, unit.texture, unit.full_reader);
                TextureAsset* source = renderer.assets.texture(unit.texture);
                if (source.source_kind == MIP_ZERO && source.desc.generate_mips
                  && !(prepare_unit_current(renderer, unit) ?? false)) {
                    unit.texels = (ulong)source.desc.width * source.desc.height * source.desc.layers;
                }
            }
            record.bytes_total = (usz)prepare_add(record.bytes_total, unit.bytes);
            record.texels_total = prepare_add(record.texels_total, unit.texels);
        }
        record.units = alloc::new_array(renderer.allocator, PrepareUnit, (sz)listed.len());
        record.units[..] = listed.array_view()[..];
    };
}

fn void append_prepare_mesh(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PrepareIndex* index,
    GeometryId geometry,
    MaterialId material,
    bool morphed,
) @local {
    AssetStore* assets = renderer.assets;
    if (!assets.geometries.is_live(geometry) || !assets.materials.is_live(material)) {
        renderer.stats.dangling_refs++;
        return;
    }
    append_prepare_material(renderer, listed, index, material);
    if (!index.geometries.has_key(prepare_identity(geometry))) {
        index.geometries.set(prepare_identity(geometry), true);
        GeometryAsset* source = assets.geometry(geometry);
        usz bytes = geometry_current(renderer, geometry) && !source.data.positions.len
            ? renderer.geometries[geometry.index].layout.total_bytes
            : geometry_layout_from_width(&source.data, source.joints_u16).total_bytes;
        listed.push({
            .kind = PrepareUnitKind.GEOMETRY,
            .geometry = geometry,
            .revision = source.header.revision,
            .bytes = bytes,
        });
    }
    append_prepare_pipelines(
        renderer: renderer,
        geometry: geometry,
        material: material,
        morphed: morphed,
        listed: listed,
    );
}

fn void append_prepare_material(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PrepareIndex* index,
    MaterialId material,
) @local {
    if (index.materials.has_key(prepare_identity(material))) return;
    index.materials.set(prepare_identity(material), true);
    if (!renderer.assets.materials.is_live(material)) {
        listed.push({ .kind = PrepareUnitKind.MATERIAL, .material = material });
        return;
    }
    MaterialAsset* source = renderer.assets.material(material);
    Material* data = &source.data;
    switch (data.kind) {
        case BASIC:
            append_prepare_slot(renderer, listed, index, data.basic.map, false);
        case STANDARD:
            append_prepare_standard(renderer, listed, index, &data.standard);
        case PHYSICAL:
            PhysicalParams* params = &data.physical;
            append_prepare_standard(renderer, listed, index, &params.standard);
            append_prepare_slot(renderer, listed, index, params.clearcoat_map, false);
            append_prepare_slot(renderer, listed, index, params.clearcoat_roughness_map, false);
            append_prepare_slot(renderer, listed, index, params.clearcoat_normal_map, false);
            append_prepare_slot(renderer, listed, index, params.sheen_color_map, false);
            append_prepare_slot(renderer, listed, index, params.sheen_roughness_map, false);
            append_prepare_slot(renderer, listed, index, params.specular_map, false);
            append_prepare_slot(renderer, listed, index, params.specular_color_map, false);
            append_prepare_slot(renderer, listed, index, params.anisotropy_map, false);
            append_prepare_slot(renderer, listed, index, params.transmission_map, false);
            append_prepare_slot(renderer, listed, index, params.thickness_map, false);
        case TOON:
            append_prepare_slot(renderer, listed, index, data.toon.map, false);
            if (renderer.assets.textures.is_live(data.toon.gradient_map)) {
                append_prepare_texture(renderer, listed, index, data.toon.gradient_map, true);
                listed.push({ .kind = PrepareUnitKind.TOON_SAMPLER });
            }
        case CUSTOM:
            foreach (slot_index, slot : data.custom.slots) append_prepare_slot(
                renderer: renderer,
                listed: listed,
                index: index,
                slot: slot,
                full_reader: slot_index != 0 || data.common.alpha_mode != AlphaMode.MASK,
            );
            foreach (reference : data.custom.references) {
                if (reference.generation) append_prepare_material(renderer, listed, index, reference);
            }
            ShaderId shader = data.custom.shader;
            if (!index.shaders.has_key(prepare_identity(shader))) {
                index.shaders.set(prepare_identity(shader), true);
                listed.push({
                    .kind = PrepareUnitKind.SHADER,
                    .shader = shader,
                    .revision = renderer.assets.shaders.is_live(shader) ? renderer.assets.shader(shader).header.revision : 0,
                });
            }
    }
    append_prepare_material_pipelines(renderer, material, listed);
    listed.push({
        .kind = PrepareUnitKind.MATERIAL,
        .material = material,
        .revision = source.header.revision,
        .bytes = material_prepare_bytes(renderer, material),
    });
}

fn void append_prepare_standard(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PrepareIndex* index,
    StandardParams* params,
) @local {
    append_prepare_slot(renderer, listed, index, params.base_color_map, false);
    append_prepare_slot(renderer, listed, index, params.metallic_roughness_map, false);
    append_prepare_slot(renderer, listed, index, params.normal_map, false);
    append_prepare_slot(renderer, listed, index, params.occlusion_map, false);
    append_prepare_slot(renderer, listed, index, params.emissive_map, false);
}

fn void append_prepare_slot(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PrepareIndex* index,
    TextureSlot slot,
    bool full_reader,
) @local {
    SamplerId sampler = renderer.assets.samplers.is_live(slot.sampler) ? slot.sampler : asset::SAMPLER_LINEAR_REPEAT;
    if (!index.samplers.has_key(prepare_identity(sampler))) {
        index.samplers.set(prepare_identity(sampler), true);
        listed.push({ .kind = PrepareUnitKind.SAMPLER, .sampler = sampler,
            .revision = renderer.assets.sampler(sampler).header.revision });
    }
    if (slot.texture.kind == TextureRefKind.RENDER_TARGET && renderer.targets.is_live(slot.texture.target)) return;
    TextureId texture = slot.texture.kind == TextureRefKind.ASSET && renderer.assets.textures.is_live(slot.texture.asset)
        ? slot.texture.asset : asset::TEXTURE_WHITE;
    append_prepare_texture(renderer, listed, index, texture, full_reader);
}

fn void append_prepare_texture(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PrepareIndex* index,
    TextureId texture,
    bool full_reader,
) @local {
    if (try previous = index.textures.get(prepare_identity(texture))) {
        listed.get_ref((sz)previous).full_reader |= full_reader;
        return;
    }
    index.textures.set(prepare_identity(texture), (uint)listed.len());
    listed.push({ .kind = PrepareUnitKind.TEXTURE, .texture = texture,
        .revision = renderer.assets.texture(texture).header.revision, .full_reader = full_reader });
}

fn uint preparation_texture_base(Renderer* renderer, TextureId texture, bool full_reader) @private {
    TextureAsset* source = renderer.assets.texture(texture);
    uint chain_mips = texture_chain_mips(source);
    if (!renderer.texture_budget_bytes || full_reader || !texture_eligible(source.desc, source.source_kind, chain_mips)) return 0;
    TextureResidency* residency = &renderer.residencies[texture.index];
    if (residency.full_reader) return 0;
    if (c3d::same_id(renderer.textures[texture.index].asset, texture) && residency.chain_mips == chain_mips) {
        return residency.resident_base;
    }
    return texture_tail_base(math::max(source.desc.width, source.desc.height), chain_mips);
}

fn usz prepare_texture_bytes(Renderer* renderer, TextureId texture, bool full_reader = false) @private {
    TextureAsset* source = renderer.assets.texture(texture);
    if (source.source_kind == TextureSourceKind.EMPTY) return 0;
    uint chain_mips = texture_chain_mips(source);
    uint base = preparation_texture_base(renderer, texture, full_reader);
    if (try levels = texture_level_bytes(source.desc, chain_mips)) {
        usz total;
        for (uint mip = base; mip < chain_mips; mip++) total += levels[mip];
        return total;
    }
    return 0;
}

fn usz prepare_source_bytes(TextureAsset* source) @private {
    if (source.source_kind == TextureSourceKind.EMPTY) return 0;
    if (try levels = texture_level_bytes(source.desc, texture_chain_mips(source))) {
        usz total;
        foreach (bytes : levels) total += bytes;
        return total;
    }
    return 0;
}

fn uint prepare_unit_revision(Renderer* renderer, PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE: return renderer.assets.textures.is_live(unit.texture) ? renderer.assets.texture(unit.texture).header.revision : 0;
        case GEOMETRY: return renderer.assets.geometries.is_live(unit.geometry) ? renderer.assets.geometry(unit.geometry).header.revision : 0;
        case MATERIAL: return renderer.assets.materials.is_live(unit.material) ? renderer.assets.material(unit.material).header.revision : 0;
        case SAMPLER: return renderer.assets.samplers.is_live(unit.sampler) ? renderer.assets.sampler(unit.sampler).header.revision : 0;
        case SHADER: return renderer.assets.shaders.is_live(unit.shader) ? renderer.assets.shader(unit.shader).header.revision : 0;
        case TOON_SAMPLER:
        case PIPELINES:
        case FINISH: return unit.revision;
    }
}

fn bool prepare_dependencies_changed(Renderer* renderer, PrepareRecord* record) @private {
    if (renderer.assets.model(record.model).header.revision != record.model_revision) return true;
    foreach (&unit : record.units) {
        if (unit.force_restart) return true;
        uint revision = prepare_unit_revision(renderer, unit);
        if (revision && revision != unit.revision) return true;
    }
    return false;
}

fn void check_prepare_model(Renderer* renderer, PrepareRecord* record) @private {
    if (!record.open || record.state == PrepareState.FAILED) return;
    if (!renderer.assets.models.is_live(record.model)) {
        record.state = PrepareState.FAILED;
        record.failure = c3d::INVALID_ID;
    }
}

fn bool prepare_unit_live(Renderer* renderer, PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE: return renderer.assets.textures.is_live(unit.texture);
        case GEOMETRY: return renderer.assets.geometries.is_live(unit.geometry);
        case MATERIAL: return renderer.assets.materials.is_live(unit.material);
        case SAMPLER: return renderer.assets.samplers.is_live(unit.sampler);
        case SHADER: return renderer.assets.shaders.is_live(unit.shader);
        case PIPELINES:
            return (!unit.geometry.generation || renderer.assets.geometries.is_live(unit.geometry))
                && (!unit.material.generation || renderer.assets.materials.is_live(unit.material));
        case TOON_SAMPLER:
        case FINISH: return true;
    }
}

fn bool? prepare_unit_current(Renderer* renderer, PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE:
            return texture_current(renderer, unit.texture)
                && (!unit.full_reader || !renderer.texture_budget_bytes || renderer.residencies[unit.texture.index].resident_base == 0);
        case GEOMETRY: return geometry_current(renderer, unit.geometry);
        case SAMPLER:
            SamplerRes* mirror = &renderer.samplers[unit.sampler.index];
            return c3d::same_id(mirror.asset, unit.sampler) && mirror.revision == unit.revision;
        case TOON_SAMPLER: return renderer.toon_gradient_sampler.is_valid();
        case MATERIAL: return material_prepare_current(renderer, unit.material);
        case SHADER: return prepare_shader_current(renderer, unit);
        case PIPELINES:
        case FINISH: return false;
    }
}

fn void restart_prepare_record(Renderer* renderer, PrepareRecord* record, PrepareReport* report) @private {
    PrepareId id = record.id;
    ModelId model = record.model;
    ulong sequence = record.sequence;
    ulong epoch = record.epoch + 1;
    uint restarts = record.restarts + 1;
    release_prepare_record(renderer, record);
    *record = { .id = id, .model = model, .model_revision = renderer.assets.model(model).header.revision,
        .sequence = sequence, .epoch = epoch, .restarts = restarts, .last_submission = renderer.last_submission,
        .open = true, .state = PrepareState.PENDING };
    enumerate_prepare_record(renderer, record);
    bind_prepare_record(renderer, id);
    report.restarts++;
}

fn PrepareReport? advance_prepare_engine(Renderer* renderer, PrepareLimits limits, bool legacy) @private {
    PrepareBudget budget = { .limits = limits, .legacy = legacy, .started = clock::now() };
    defer catch {
        finish_prepare_report(&budget);
        account_prepare_report(renderer, budget.report);
    }
    checkpoint_prepare_uploads(renderer);
    begin_material_scope(renderer);
    defer end_material_scope(renderer);
    PrepareId[PREPARE_CAPACITY] order;
    uint count = prepare_order(renderer, order[..]);
    foreach (id : order[:count]) {
        PrepareRecord* record = renderer.prepares.get(id);
        check_prepare_model(renderer, record);
        if (record.state == PrepareState.FAILED) continue;
        if (prepare_dependencies_changed(renderer, record)) restart_prepare_record(renderer, record, &budget.report);
        while (record.units_done < record.units.len) {
            uint unit_index = record.next;
            if (record.chain_active && !record.units[record.chain_unit].done) unit_index = record.chain_unit;
            PrepareUnit* unit = &record.units[unit_index];
            if (unit.done) { refresh_prepare_progress(record); continue; }
            if (!prepare_unit_live(renderer, unit)) {
                retire_prepare_candidate(renderer, unit);
                if (record.chain_active && record.chain_unit == unit_index) clear_prepare_chain(record);
                renderer.stats.dangling_refs++;
                finish_prepare_unit(record, unit);
                continue;
            }
            bool? current = prepare_unit_current(renderer, unit);
            if (catch excuse = current) {
                if (!fails_record(excuse)) return excuse~;
                record.state = PrepareState.FAILED;
                record.failure = excuse;
                break;
            }
            if (current) {
                bool abandoned = prepare_unit_has_candidate(unit);
                bool pending = prepare_unit_gpu_data(unit) && (renderer.uploads_recorded || renderer.pending_copies.len()
                    || renderer.pending_texture_uploads.len() || renderer.pending_geometry_uploads.len()
                    || renderer.pending_prepare_installs.len());
                if (pending) {
                    checkpoint_prepare_unit(renderer, record, unit);
                    unit.referenced_this_frame = true;
                    record.pending_gpu = true;
                }
                retire_prepare_candidate(renderer, unit);
                if (record.chain_active && record.chain_unit == unit_index) clear_prepare_chain(record);
                unit.abandoned_candidate |= abandoned;
                record.last_submission = renderer.last_submission;
                finish_prepare_unit(record, unit);
                continue;
            }
            if (unit.kind == PrepareUnitKind.PIPELINES && !prepare_pipeline_dependencies_current(renderer, unit)) {
                restart_prepare_record(renderer, record, &budget.report);
                continue;
            }
            bool done;
            @pool() {
                PrepareStepPlan? planned = plan_prepare_step(renderer, record, unit, &budget);
                if (catch excuse = planned) {
                    if (!fails_record(excuse)) return excuse~;
                    record.state = PrepareState.FAILED;
                    record.failure = excuse;
                    break;
                }
                PrepareStepPlan plan = planned;
                PrepareStopReason stopped = prepare_step_stop(&budget, plan.cost, (ulong)budget.started.to_now());
                if (stopped != PrepareStopReason.NONE) {
                    budget.report.reason = stopped;
                    budget.report.required = plan.cost;
                    finish_prepare_report(&budget);
                    account_prepare_report(renderer, budget.report);
                    return budget.report;
                }
                checkpoint_prepare_unit(renderer, record, unit);
                bool? result = run_prepare_step(renderer, record, unit, &plan, &budget.report);
                if (catch excuse = result) {
                    if (!fails_record(excuse)) return excuse~;
                    record.state = PrepareState.FAILED;
                    record.failure = excuse;
                    break;
                }
                done = result;
                if (budget.legacy && (limits.staged_bytes == 0 || budget.report.staged_bytes > limits.staged_bytes)) budget.legacy_step = true;
            };
            if (record.state == PrepareState.FAILED) break;
            if (done) {
                finish_prepare_unit(record, unit);
                renderer.stats.prepare_units++;
            }
            if (budget.legacy_step) {
                finish_prepare_report(&budget);
                account_prepare_report(renderer, budget.report);
                return budget.report;
            }
        }
        if (record.state != PrepareState.FAILED) promote_prepare_record(renderer, record);
    }
    finish_prepare_report(&budget);
    account_prepare_report(renderer, budget.report);
    return budget.report;
}

fn void finish_prepare_report(PrepareBudget* budget) @private {
    budget.report.elapsed_ns = (ulong)budget.started.to_now();
    if (budget.limits.time_ns && budget.report.elapsed_ns > budget.limits.time_ns) {
        budget.report.overrun_ns = budget.report.elapsed_ns - budget.limits.time_ns;
    }
}

fn void finish_prepare_unit(PrepareRecord* record, PrepareUnit* unit) @private {
    unit.done = true;
    refresh_prepare_progress(record);
}

fn void refresh_prepare_progress(PrepareRecord* record) @private {
    record.bytes_done = 0;
    record.units_done = 0;
    record.next = (uint)record.units.len;
    foreach (uint index, &unit : record.units) {
        record.bytes_done += unit.done ? unit.bytes : unit.staged.bytes;
        if (unit.done) {
            record.units_done++;
        } else if (record.next == record.units.len) {
            record.next = index;
        }
    }
    if (record.state == PrepareState.FAILED) return;
    if (record.units_done == record.units.len) {
        record.state = record.pending_gpu ? PrepareState.PENDING
            : (record.last_submission.is_valid() ? PrepareState.SUBMITTED : PrepareState.READY);
        record.phase = PreparePhase.COMPLETE;
    } else if (record.state != PrepareState.FAILED) {
        record.state = PrepareState.PENDING;
    }
}

fn void promote_prepare_record(Renderer* renderer, PrepareRecord* record) @private {
    if (record.state != PrepareState.SUBMITTED || record.units_done != record.units.len || record.pending_gpu) return;
    if (record.last_submission.is_valid()) {
        if (try ready = gpu::poll_completion(record.last_submission)) {
            if (ready) record.state = PrepareState.READY;
        }
    }
}

fn uint prepare_order(Renderer* renderer, PrepareId[] order) @private {
    uint count;
    foreach (uint index, &record : renderer.prepares.items) {
        if (!record.open) continue;
        uint position = count++;
        while (position && renderer.prepares.items[order[position - 1].index].sequence > record.sequence) {
            order[position] = order[position - 1];
            position--;
        }
        order[position] = { .index = index, .generation = renderer.prepares.generations[index] };
    }
    return count;
}

fn bool fails_record(fault excuse) @private {
    return excuse == c3d::INVALID_ID || excuse == c3d::SHADER_NOT_FOUND || excuse == c3d::INVALID_ARGUMENT
        || excuse == c3d::UNSUPPORTED || excuse == c3d::ASSET_DATA_UNAVAILABLE || excuse == gpu::SHADER_INVALID
        || excuse == gpu::PIPELINE_CREATE_FAILED;
}
