module c3d::render;

import c3d;
import c3d::asset;
import c3d::pool;
import gpu;
import std::collections::list;

struct PrepareUploadCheckpoint @private {
    usz head;
    usz demand;
    sz overflow;
    uint slot;
    bool active;
}

struct PrepareRetirement @private {
    Retired resource;
    gpu::CompletionPoint previous;
    uint previous_slot;
    bool recording;
}

fn void bind_prepare_record(Renderer* renderer, PrepareId id) @private {
    PrepareRecord* record = renderer.prepares.get(id);
    record.id = id;
    foreach (uint index, &unit : record.units) {
        unit.owner = id;
        unit.index = index;
    }
}

fn bool prepare_unit_gpu_data(PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE:
        case GEOMETRY:
        case MATERIAL: return true;
        case PIPELINES: return prepare_pipeline_has_gpu_data(unit);
        case SAMPLER:
        case TOON_SAMPLER:
        case SHADER:
        case FINISH: return false;
    }
}

fn void checkpoint_prepare_unit(Renderer* renderer, PrepareRecord* record, PrepareUnit* unit) @private {
    if (!prepare_unit_gpu_data(unit)) return;
    if (unit.checkpoint.active && unit.checkpoint.epoch == record.epoch
      && unit.checkpoint.frame == renderer.frame_index) return;
    unit.checkpoint = {
        .staged = unit.staged, .done = unit.done, .initialized = unit.initialized,
        .texture_state = unit.texture_candidate.state,
        .epoch = record.epoch, .frame = renderer.frame_index, .active = true,
    };
    if (unit.kind == PrepareUnitKind.PIPELINES) checkpoint_prepare_pipeline_unit(renderer, unit);
}

fn void install_prepare_texture(Renderer* renderer, PrepareRecord* record, PrepareUnit* unit) @private {
    TextureRes* mirror = &renderer.textures[unit.texture.index];
    unit.texture_candidate.binding_revision = mirror.binding_revision + 1;
    renderer.pending_prepare_installs.push({
        .record = record.id, .unit = unit.index, .epoch = record.epoch, .kind = unit.kind,
        .old_texture = *mirror, .new_texture = unit.texture_candidate,
        .old_residency = renderer.residencies[unit.texture.index], .new_residency = unit.residency_candidate,
        .last_submission = unit.last_submission, .last_submission_slot = unit.last_submission_slot,
    });
    *mirror = unit.texture_candidate;
    renderer.residencies[unit.texture.index] = unit.residency_candidate;
    unit.texture_candidate = {};
    unit.installed = true;
}

fn void install_prepare_geometry(Renderer* renderer, PrepareRecord* record, PrepareUnit* unit) @private {
    GpuGeometry* mirror = &renderer.geometries[unit.geometry.index];
    renderer.pending_prepare_installs.push({
        .record = record.id, .unit = unit.index, .epoch = record.epoch, .kind = unit.kind,
        .old_geometry = *mirror, .new_geometry = unit.geometry_candidate,
        .last_submission = unit.last_submission, .last_submission_slot = unit.last_submission_slot,
    });
    *mirror = unit.geometry_candidate;
    unit.geometry_candidate = {};
    unit.installed = true;
}

fn void install_prepare_material(Renderer* renderer, PrepareRecord* record, PrepareUnit* unit) @private {
    MaterialRes* mirror = &renderer.materials[unit.material.index];
    renderer.pending_prepare_installs.push({
        .record = record.id, .unit = unit.index, .epoch = record.epoch, .kind = unit.kind,
        .old_material = *mirror, .new_material = unit.material_candidate,
        .last_submission = unit.last_submission, .last_submission_slot = unit.last_submission_slot,
    });
    *mirror = unit.material_candidate;
    unit.material_candidate = {};
    unit.installed = true;
}

fn void install_prepare_sbt(
    Renderer* renderer,
    PrepareUnit* unit,
    gpu::GpuAllocation allocation,
    gpu::RayTracingShaderBindingTable regions,
) @private {
    PrepareRecord* record = renderer.prepares.get(unit.owner);
    PathTracer candidate = renderer.path_tracer;
    candidate.sbt = allocation;
    candidate.regions = regions;
    renderer.pending_prepare_installs.push({
        .record = record.id, .unit = unit.index, .epoch = record.epoch, .kind = PrepareUnitKind.PIPELINES,
        .old_path_tracer = renderer.path_tracer, .new_path_tracer = candidate,
        .last_submission = unit.last_submission, .last_submission_slot = unit.last_submission_slot,
    });
    renderer.path_tracer = candidate;
    unit.installed = true;
    unit.referenced_this_frame = true;
    record.pending_gpu = true;
    renderer.work_recorded = true;
}

fn void retire_prepare_resource(Renderer* renderer, PrepareUnit* unit, Retired resource) @private {
    gpu::CompletionPoint previous = unit ? unit.last_submission : renderer.last_submission;
    uint previous_slot = unit ? unit.last_submission_slot : renderer.last_submitted_slot;
    bool recording = renderer.frame_open && (!unit || unit.referenced_this_frame);
    if (recording) {
        renderer.pending_prepare_retire.push({ .resource = resource, .previous = previous,
            .previous_slot = previous_slot, .recording = true });
    } else if (previous.is_valid()) {
        renderer.frames[previous_slot].retire.push(resource);
    } else {
        RetireList immediate;
        immediate.init(renderer.allocator, 1);
        immediate.push(resource);
        drain_retired(&renderer.device, &immediate);
        immediate.free();
    }
}

fn void retire_prepare_allocation(Renderer* renderer, PrepareUnit* unit, gpu::GpuAllocation allocation) @private {
    if (allocation.is_valid()) retire_prepare_resource(
        renderer: renderer,
        unit: unit,
        resource: { .kind = RetiredKind.ALLOCATION, .allocation = allocation },
    );
}

fn void retire_prepare_pipeline(Renderer* renderer, gpu::PipelineHandle pipeline) @private {
    if (pipeline.is_valid()) retire_prepare_resource(
        renderer: renderer,
        unit: null,
        resource: { .kind = RetiredKind.PIPELINE, .pipeline = pipeline },
    );
}

fn void retire_prepare_texture(Renderer* renderer, PrepareUnit* unit, TextureRes* texture) @private {
    foreach (view : texture.storage_views) {
        if (view.is_valid()) retire_prepare_resource(
            renderer: renderer,
            unit: unit,
            resource: { .kind = RetiredKind.TEXTURE_VIEW, .texture_view = view },
        );
    }
    alloc::free(renderer.allocator, texture.storage_views.ptr);
    if (texture.view.is_valid()) retire_prepare_resource(
        renderer: renderer,
        unit: unit,
        resource: { .kind = RetiredKind.TEXTURE_VIEW, .texture_view = texture.view },
    );
    if (texture.texture.is_valid()) retire_prepare_resource(
        renderer: renderer,
        unit: unit,
        resource: { .kind = RetiredKind.TEXTURE, .texture = texture.texture },
    );
    *texture = {};
}

fn void retire_prepare_geometry(Renderer* renderer, PrepareUnit* unit, GpuGeometry* geometry) @private {
    retire_prepare_allocation(renderer, unit, geometry.allocation);
    retire_prepare_allocation(renderer, unit, geometry.trace.allocation);
    if (geometry.blas.handle.is_valid()) retire_prepare_resource(
        renderer: renderer,
        unit: unit,
        resource: { .kind = RetiredKind.ACCELERATION_STRUCTURE, .acceleration_structure = geometry.blas.handle },
    );
    *geometry = {};
}

fn void retire_prepare_candidate(Renderer* renderer, PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE: retire_prepare_texture(renderer, unit, &unit.texture_candidate);
        case GEOMETRY: retire_prepare_geometry(renderer, unit, &unit.geometry_candidate);
        case MATERIAL:
            retire_prepare_allocation(renderer, unit, unit.material_candidate.payload);
            unit.material_candidate = {};
        case PIPELINES: free_prepare_pipeline_unit(renderer, unit);
        case SHADER: free_prepare_shader_unit(renderer, unit);
        case SAMPLER:
        case TOON_SAMPLER:
        case FINISH:
    }
}

fn void release_prepare_record(Renderer* renderer, PrepareRecord* record) @private {
    clear_prepare_chain(record);
    foreach (&unit : record.units) retire_prepare_candidate(renderer, unit);
    alloc::free(renderer.allocator, record.units.ptr);
    record.units = {};
}

fn PrepareUnit*? pending_install_unit(Renderer* renderer, PrepareInstall* install) @local {
    if (try record = renderer.prepares.try_get(install.record)) {
        if (record.epoch == install.epoch && install.unit < record.units.len) return &record.units[install.unit];
    }
    return NOT_FOUND~;
}

fn void commit_prepare_jobs(Renderer* renderer, Frame* slot) @private {
    renderer.last_submission = slot.done;
    for (uint index = 0; index < FRAMES_IN_FLIGHT; index++) {
        if (&renderer.frames[index] == slot) renderer.last_submitted_slot = index;
    }
    foreach (&install : renderer.pending_prepare_installs) {
        PrepareUnit retired_unit = { .last_submission = slot.done, .last_submission_slot = renderer.last_submitted_slot };
        switch (install.kind) {
            case TEXTURE: retire_prepare_texture(renderer, &retired_unit, &install.old_texture);
            case GEOMETRY: retire_prepare_geometry(renderer, &retired_unit, &install.old_geometry);
            case MATERIAL: retire_prepare_allocation(renderer, &retired_unit, install.old_material.payload);
            case PIPELINES: retire_prepare_allocation(renderer, &retired_unit, install.old_path_tracer.sbt);
            case SAMPLER:
            case TOON_SAMPLER:
            case SHADER:
            case FINISH:
        }
    }
    renderer.pending_prepare_installs.clear();
    foreach (&record : renderer.prepares.items) {
        if (!record.open) continue;
        bool submitted;
        foreach (&unit : record.units) {
            if (unit.referenced_this_frame) {
                unit.last_submission = slot.done;
                unit.last_submission_slot = renderer.last_submitted_slot;
                submitted = true;
            }
            unit.referenced_this_frame = false;
            unit.checkpoint.active = false;
            unit.abandoned_candidate = false;
        }
        if (submitted) record.last_submission = slot.done;
        record.pending_gpu = false;
        refresh_prepare_progress(record);
    }
    foreach (&pending : renderer.pending_prepare_retire) slot.retire.push(pending.resource);
    renderer.pending_prepare_retire.clear();
    renderer.prepare_upload_checkpoint.active = false;
}

fn bool retired_matches_texture(Retired retired, TextureRes* texture) @local {
    switch (retired.kind) {
        case TEXTURE: return retired.texture == texture.texture;
        case TEXTURE_VIEW:
            if (retired.texture_view == texture.view) return true;
            foreach (view : texture.storage_views) {
                if (retired.texture_view == view) return true;
            }
            return false;
        case ALLOCATION:
        case ATTACHMENT_VIEW:
        case PIPELINE:
        case ACCELERATION_STRUCTURE:
        case ACCELERATION_STRUCTURE_VIEW: return false;
    }
}

fn void protect_prepare_restored(Renderer* renderer, PrepareInstall* install) @local {
    for (sz index = renderer.pending_upload_retire.len(); index > 0; index--) {
        Retired* retired = renderer.pending_upload_retire.get_ref(index - 1);
        bool remove;
        switch (install.kind) {
            case TEXTURE: remove = retired_matches_texture(*retired, &install.old_texture);
            case GEOMETRY:
                remove = (retired.kind == RetiredKind.ALLOCATION && (retired.allocation == install.old_geometry.allocation
                    || retired.allocation == install.old_geometry.trace.allocation))
                    || (retired.kind == RetiredKind.ACCELERATION_STRUCTURE && retired.acceleration_structure == install.old_geometry.blas.handle);
            case MATERIAL: remove = retired.kind == RetiredKind.ALLOCATION && retired.allocation == install.old_material.payload;
            case PIPELINES: remove = retired.kind == RetiredKind.ALLOCATION && retired.allocation == install.old_path_tracer.sbt;
            case SAMPLER:
            case TOON_SAMPLER:
            case SHADER:
            case FINISH:
        }
        if (remove) renderer.pending_upload_retire.remove_at(index - 1);
    }
}

fn void rollback_prepare_jobs(Renderer* renderer) @private {
    while (try install = renderer.pending_prepare_installs.pop()) {
        PrepareUnit* unit = pending_install_unit(renderer, &install) ?? null;
        protect_prepare_restored(renderer, &install);
        PrepareUnit retired_unit = { .last_submission = install.last_submission,
            .last_submission_slot = install.last_submission_slot };
        switch (install.kind) {
            case TEXTURE:
                TextureRes* mirror = &renderer.textures[install.new_texture.asset.index];
                bool superseded = mirror.texture != install.new_texture.texture;
                TextureRes candidate = superseded ? (TextureRes){} : *mirror;
                if (superseded) {
                    PrepareUnit unused;
                    retire_prepare_texture(renderer, &unused, mirror);
                    if (unit) unit.force_restart = true;
                }
                *mirror = install.old_texture;
                renderer.residencies[install.new_texture.asset.index] = install.old_residency;
                if (unit) {
                    unit.texture_candidate = candidate;
                } else {
                    retire_prepare_texture(renderer, &retired_unit, &candidate);
                }
            case GEOMETRY:
                GpuGeometry* mirror = &renderer.geometries[install.new_geometry.asset.index];
                bool superseded = mirror.allocation != install.new_geometry.allocation;
                GpuGeometry candidate = superseded ? (GpuGeometry){} : *mirror;
                if (superseded) {
                    PrepareUnit unused;
                    retire_prepare_geometry(renderer, &unused, mirror);
                    if (unit) unit.force_restart = true;
                }
                *mirror = install.old_geometry;
                if (unit) {
                    unit.geometry_candidate = candidate;
                } else {
                    retire_prepare_geometry(renderer, &retired_unit, &candidate);
                }
            case MATERIAL:
                MaterialRes* mirror = &renderer.materials[install.new_material.asset.index];
                bool superseded = mirror.payload != install.new_material.payload;
                if (superseded && mirror.payload.is_valid()) {
                    PrepareUnit unused;
                    retire_prepare_allocation(renderer, &unused, mirror.payload);
                    if (unit) unit.force_restart = true;
                }
                *mirror = install.old_material;
                if (unit) {
                    unit.material_candidate = superseded ? (MaterialRes){} : install.new_material;
                } else if (!superseded) {
                    retire_prepare_allocation(renderer, &retired_unit, install.new_material.payload);
                }
            case PIPELINES:
                renderer.path_tracer.sbt = install.old_path_tracer.sbt;
                renderer.path_tracer.regions = install.old_path_tracer.regions;
                if (unit) {
                    unit.pipeline.candidate = install.new_path_tracer.sbt;
                } else {
                    retire_prepare_allocation(renderer, &retired_unit, install.new_path_tracer.sbt);
                }
            case SAMPLER:
            case TOON_SAMPLER:
            case SHADER:
            case FINISH:
        }
        if (unit) unit.installed = false;
    }
    foreach (&record : renderer.prepares.items) {
        if (record.open) rollback_prepare_cursors(renderer, record);
    }
    foreach (&pending : renderer.pending_prepare_retire) {
        PrepareUnit retired_unit = { .last_submission = pending.previous, .last_submission_slot = pending.previous_slot };
        retire_prepare_resource(renderer, &retired_unit, pending.resource);
    }
    renderer.pending_prepare_retire.clear();
    foreach (retired : renderer.pending_upload_retire) retire_prepare_resource(renderer, null, retired);
    renderer.pending_upload_retire.clear();
    if (renderer.prepare_upload_checkpoint.active) {
        PrepareUploadCheckpoint checkpoint = renderer.prepare_upload_checkpoint;
        UploadRing* ring = &renderer.frames[checkpoint.slot].upload;
        while (ring.overflow.len() > checkpoint.overflow) {
            gpu::GpuAllocation allocation = ring.overflow.pop()!!;
            (void)gpu::free_allocation(&renderer.device, &allocation);
        }
        ring.head = checkpoint.head;
        ring.demand = checkpoint.demand;
        renderer.prepare_upload_checkpoint.active = false;
    }
}

fn void free_prepares(Renderer* renderer) @private {
    foreach (&record : renderer.prepares.items) {
        if (record.open) release_prepare_record(renderer, record);
    }
    pool::destroy_pool{PrepareRecord, PrepareId}(&renderer.prepares);
    renderer.pending_prepare_installs.free();
    foreach (&pending : renderer.pending_prepare_retire) {
        RetireList immediate;
        immediate.init(renderer.allocator, 1);
        immediate.push(pending.resource);
        drain_retired(&renderer.device, &immediate);
        immediate.free();
    }
    renderer.pending_prepare_retire.free();
}

fn void checkpoint_prepare_uploads(Renderer* renderer) @private {
    if (renderer.prepare_upload_checkpoint.active) return;
    UploadRing* ring = &renderer.frames[renderer.recording_slot].upload;
    renderer.prepare_upload_checkpoint = { .head = ring.head, .demand = ring.demand,
        .overflow = ring.overflow.len(), .slot = renderer.recording_slot, .active = true };
}

fn void rollback_prepare_cursors(Renderer* renderer, PrepareRecord* record) @private {
    foreach (&unit : record.units) {
        if (!unit.checkpoint.active || unit.checkpoint.epoch != record.epoch) continue;
        if (unit.kind == PrepareUnitKind.TEXTURE && unit.done
          && !(record.chain_active && record.chain_unit == unit.index)) unit.generated_done = 0;
        if (unit.abandoned_candidate) unit.force_restart = true;
        unit.abandoned_candidate = false;
        unit.staged = unit.checkpoint.staged;
        unit.done = unit.checkpoint.done;
        unit.texture_candidate.state = unit.checkpoint.texture_state;
        if (unit.kind == PrepareUnitKind.PIPELINES) rollback_prepare_pipeline_unit(renderer, unit);
        unit.checkpoint.active = false;
        unit.referenced_this_frame = false;
    }
    record.pending_gpu = false;
    record.texels_done = 0;
    foreach (unit : record.units) record.texels_done = prepare_add(record.texels_done, unit.generated_done);
    refresh_prepare_progress(record);
}

fn void commit_prepare_cursors(PrepareRecord* record) @private {
    foreach (&unit : record.units) {
        unit.checkpoint.active = false;
        unit.referenced_this_frame = false;
    }
    record.pending_gpu = false;
    refresh_prepare_progress(record);
}

fn bool prepare_unit_has_candidate(PrepareUnit* unit) @private {
    switch (unit.kind) {
        case TEXTURE: return unit.texture_candidate.texture.is_valid();
        case GEOMETRY: return unit.geometry_candidate.allocation.is_valid();
        case MATERIAL: return unit.material_candidate.payload.is_valid();
        case PIPELINES: return unit.pipeline.candidate.is_valid();
        case SAMPLER:
        case TOON_SAMPLER:
        case SHADER:
        case FINISH: return false;
    }
}
