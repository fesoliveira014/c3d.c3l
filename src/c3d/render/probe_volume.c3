module c3d::render;

import c3d;
import c3d::ecs;
import c3d::light;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert ProbeVolumeSetGpu::size == 16 + ProbeVolumeGpu::size * shader::PROBE_VOLUME_CAPACITY;

const ulong PROBE_MIRROR_ABSENCE_FRAMES @private = FRAMES_IN_FLIGHT + 1; // longer holds idle atlases longer
const gpu::Format PROBE_IRRADIANCE_FORMAT @local = gpu::Format.RGBA16_FLOAT;
const gpu::Format PROBE_VISIBILITY_FORMAT @local = gpu::Format.RG16_FLOAT;

bitstruct ProbeFillWork : char @private {
    bool irradiance : 0;
    bool visibility : 1;
}

struct ProbeFillIdentity @private {
    EnvironmentId environment;
    Entity        atmosphere;          // the lighting source when the scene has an atmosphere
    uint          lighting_revision;
    float         intensity;
    Quat          rotation;
}

struct ProbeFillState @private {
    ProbeFillIdentity irradiance;          // zero environment and atmosphere ids: no irradiance fill
    float             visibility_distance;
    bool              visibility_filled;
    bool              scene_defined;       // texels hold defined values for scene updates
    bool              scene_swept;         // every probe holds at least one scene estimate
    uint              cursor;              // next probe the scene round-robin visits
    Vec3              traced_origin;       // grid origin of the last scene update
}

<*
 Renderer-owned atlases of one ProbeVolume component of one scene.
*>
struct ProbeVolumeRes {
    ulong             scene;
    Entity            entity;              // a zero generation marks a free slot
    ulong             last_frame;          // last frame the scene was rendered with the component alive
    uint[<3>]         counts;
    uint              slices_per_row;
    Target            irradiance;
    Target            visibility;
    ProbeFillState    fill;
    ProbeFillState    frame_fill;          // fill at begin_frame; a discarded frame restores it
    bool              fill_recorded;
    ulong             updated_frame;       // frame_index + 1 of the last scene update
    gpu::TextureState frame_irradiance_state;
    gpu::TextureState frame_visibility_state;
}

struct ProbeVolumePipelines @private {
    gpu::PipelineHandle fill;
    gpu::PipelineHandle border;
}

struct ProbeSceneUpdate @private {
    usz            slot;
    ProbeScenePlan plan;
}

struct ProbeFillRecording @private {
    Scene*            scene;
    ViewEnvironments* environments;
    EnvironmentRes*   lighting;
    gpu::GpuAddress   environment;
    bool              environment_ready;
    ProbeSceneUpdate[shader::PROBE_VOLUME_CAPACITY] updates;
    usz               update_count;
}

fn bool ProbeFillState.filled(&self) {
    bool lit = self.irradiance.environment.generation != 0 || self.irradiance.atmosphere.generation != 0;
    return lit && self.visibility_filled;
}

fn bool ProbeFillState.in_hit_set(&self) {
    return self.filled() || self.scene_defined;
}

fn bool ProbeFillState.in_view_set(&self) {
    return self.filled() || self.scene_swept;
}

fn bool probe_fill_identity_equals(ProbeFillIdentity* first, ProbeFillIdentity* second) @private {
    return c3d::same_id(first.environment, second.environment)
        && c3d::same_id(first.atmosphere, second.atmosphere)
        && first.lighting_revision == second.lighting_revision
        && first.intensity == second.intensity
        && first.rotation.v == second.rotation.v;
}

fn ProbeFillWork plan_probe_fill(
    ProbeFillState* state,
    ProbeFill fill,
    ProbeFillIdentity* current,
    float max_distance,
) @private {
    switch (fill) {
        case NONE:
        case SCENE:
            return {};
        case ENVIRONMENT:
            state.scene_defined = false;
            state.scene_swept = false;
            state.cursor = 0;
            if (!current) {
                state.irradiance = {};
                return {};
            }
            ProbeFillWork work = {
                .irradiance = !probe_fill_identity_equals(&state.irradiance, current),
                .visibility = !state.visibility_filled || state.visibility_distance != max_distance,
            };
            state.irradiance = *current;
            state.visibility_distance = max_distance;
            state.visibility_filled = true;
            return work;
    }
}

fn usz? choose_probe_slot(ProbeVolumeRes[] mirrors, ulong scene, ulong frame_index) @private {
    foreach (usz index, &mirror : mirrors) {
        if (mirror.entity.generation == 0) return index;
    }
    usz chosen = mirrors.len;
    foreach (usz index, &mirror : mirrors) {
        if (mirror.scene == scene || frame_index - mirror.last_frame <= PROBE_MIRROR_ABSENCE_FRAMES) continue;
        if (chosen == mirrors.len || mirror.last_frame < mirrors[chosen].last_frame) chosen = index;
    }
    if (chosen == mirrors.len) return NO_PROBE_SLOT~;
    return chosen;
}

<*
 @require order.len >= shader::PROBE_VOLUME_CAPACITY
*>
fn usz order_view_probe_volumes(
    ProbeVolumeRes[] mirrors,
    Scene* scene,
    uint view_layers,
    usz[] order,
) @private {
    return order_probe_volumes(mirrors, scene, view_layers, false, order);
}

<*
 @require order.len >= shader::PROBE_VOLUME_CAPACITY
*>
fn usz order_hit_probe_volumes(ProbeVolumeRes[] mirrors, Scene* scene, usz[] order) @private {
    return order_probe_volumes(mirrors, scene, 0, true, order);
}

fn usz order_probe_volumes(
    ProbeVolumeRes[] mirrors,
    Scene* scene,
    uint layers,
    bool hit_set,
    usz[] order,
) @local {
    float[shader::PROBE_VOLUME_CAPACITY] box_volumes;
    usz count;
    foreach (usz index, &mirror : mirrors) {
        if (mirror.scene != scene.identity) continue;
        if (!(hit_set ? mirror.fill.in_hit_set() : mirror.fill.in_view_set())) continue;
        ProbeVolume* volume = scene.world.get(mirror.entity, ProbeVolume);
        Node* node = scene.node(mirror.entity);
        // Probe hits see every volume, whatever the layers.
        if (!node.visible_effective || (!hit_set && !(node.layers & layers))) continue;

        float box_volume = volume.half_extents.x * volume.half_extents.y * volume.half_extents.z;
        usz position = count;
        while (position > 0 && box_volume < box_volumes[position - 1]) {
            order[position] = order[position - 1];
            box_volumes[position] = box_volumes[position - 1];
            position--;
        }
        order[position] = index;
        box_volumes[position] = box_volume;
        count++;
    }
    return count;
}

// Mirrored as probe_volume_select in probe_volume.glsl.
fn usz? probe_volume_at(ProbeVolumeSetGpu* set, Vec3 position) @private {
    for (usz index = 0; index < set.count; index++) {
        ProbeVolumeGpu* volume = &set.volumes[index];
        Vec3 origin = volume.origin_energy.xyz;
        Vec3 last = { (float)(volume.count_x - 1), (float)(volume.count_y - 1), (float)(volume.count_z - 1) };
        Vec3 far = origin + volume.spacing_max_distance.xyz * last;
        if (position.x >= origin.x && position.y >= origin.y && position.z >= origin.z
            && position.x <= far.x && position.y <= far.y && position.z <= far.z) {
            return index;
        }
    }
    return NO_PROBE_VOLUME~;
}

fn void? acquire_probe_pipelines(Renderer* renderer) @private {
    ProbeVolumePipelines* pipelines = &renderer.probe_pipelines;
    acquire_compute_pipeline(renderer, &pipelines.fill, PROBE_FILL_ENVIRONMENT, "probe_fill_environment")!;
    acquire_compute_pipeline(renderer, &pipelines.border, PROBE_BORDER, "probe_border")!;
}

fn void? create_probe_atlases(Renderer* renderer, ProbeVolumeRes* mirror, uint[<3>] counts) @private {
    uint[<2>] irradiance_extent = probe_atlas_extent(counts, shader::PROBE_IRRADIANCE_CELL);
    uint[<2>] visibility_extent = probe_atlas_extent(counts, shader::PROBE_VISIBILITY_CELL);
    mirror.irradiance = allocate_storage_target(
        device:     &renderer.device,
        width:      irradiance_extent.x,
        height:     irradiance_extent.y,
        format:     PROBE_IRRADIANCE_FORMAT,
        debug_name: "probe_irradiance",
    )!;
    defer catch release_storage_target(&renderer.device, &mirror.irradiance);
    mirror.visibility = allocate_storage_target(
        device:     &renderer.device,
        width:      visibility_extent.x,
        height:     visibility_extent.y,
        format:     PROBE_VISIBILITY_FORMAT,
        debug_name: "probe_visibility",
    )!;
    mirror.counts = counts;
    mirror.slices_per_row = probe_slices_per_row(counts);
    mirror.fill = {};
    mirror.frame_fill = {};
    mirror.frame_irradiance_state = mirror.irradiance.state;
    mirror.frame_visibility_state = mirror.visibility.state;
}

fn void retire_probe_atlases(Renderer* renderer, ProbeVolumeRes* mirror) @private {
    retire_storage_target(&renderer.pending_upload_retire, &mirror.irradiance);
    retire_storage_target(&renderer.pending_upload_retire, &mirror.visibility);
}

fn void sweep_probe_volumes(Renderer* renderer, Scene* scene) @private {
    foreach (&mirror : renderer.probe_volumes) {
        if (mirror.entity.generation == 0 || mirror.scene != scene.identity) continue;
        if (scene.world.is_alive(mirror.entity) && scene.world.has(mirror.entity, ProbeVolume)) continue;
        retire_probe_atlases(renderer, mirror);
        *mirror = {};
    }
}

fn ProbeVolumeRes* find_probe_volume(Renderer* renderer, ulong scene, Entity entity) @private {
    foreach (&mirror : renderer.probe_volumes) {
        if (mirror.scene == scene && c3d::same_id(mirror.entity, entity)) return mirror;
    }
    return null;
}

fn void? record_probe_volumes(
    Renderer* renderer,
    Scene* scene,
    ViewEnvironments* environments,
    gpu::GpuAddress trace_root,
) @private {
    sweep_probe_volumes(renderer, scene);
    if (!scene.count(ProbeVolume)) return;

    EnvironmentRes* lighting = environments.lighting;
    ProbeFillIdentity identity;
    if (lighting) {
        identity = {
            .environment       = lighting.asset,
            .atmosphere        = environments.atmosphere ? environments.atmosphere.entity : (Entity){},
            .lighting_revision = lighting.lighting_revision,
            .intensity         = environments.lighting_intensity,
            .rotation          = environments.lighting_rotation,
        };
    }
    ProbeFillRecording recording = { .scene = scene, .environments = environments, .lighting = lighting };
    scene.@each(ProbeVolume; Entity entity, ProbeVolume* volume) {
        resolve_probe_volume(
            renderer:  renderer,
            recording: &recording,
            entity:    entity,
            volume:    volume,
            current:   lighting ? &identity : null,
        )!;
    };
    if (recording.update_count) record_probe_updates(renderer, &recording, trace_root)!;
}

<*
 @require light::probe_volume_valid(volume)
*>
fn void? resolve_probe_volume(
    Renderer* renderer,
    ProbeFillRecording* recording,
    Entity entity,
    ProbeVolume* volume,
    ProbeFillIdentity* current,
) @private {
    ulong scene = recording.scene.identity;
    Node* node = recording.scene.node(entity);
    bool scene_due = volume.fill == ProbeFill.SCENE && probe_scene_due(renderer, recording.scene, entity);
    ProbeVolumeRes* mirror = find_probe_volume(renderer, scene, entity);
    if (mirror) {
        mirror.last_frame = renderer.frame_index;
        if (mirror.counts != volume.counts) {
            defer catch *mirror = {};
            retire_probe_atlases(renderer, mirror);
            create_probe_atlases(renderer, mirror, volume.counts)!;
        }
    }

    ProbeFillState state = mirror ? mirror.fill : {};
    ProbeFillWork work = plan_probe_fill(&state, volume.fill, current, volume.max_distance);
    if (!mirror) {
        if (work == (ProbeFillWork){} && !scene_due) return;
        usz? slot = choose_probe_slot(&renderer.probe_volumes, scene, renderer.frame_index);
        if (catch slot) {
            renderer.stats.probe_volumes_dropped++;
            return;
        }
        mirror = &renderer.probe_volumes[slot];
        if (mirror.entity.generation) retire_probe_atlases(renderer, mirror);
        *mirror = { .scene = scene, .entity = entity, .last_frame = renderer.frame_index };
        defer catch *mirror = {};
        create_probe_atlases(renderer, mirror, volume.counts)!;
    }

    ProbeScenePlan plan;
    if (scene_due) {
        Vec3 spacing = volume.spacing();
        plan = plan_probe_scene(
            state:            &state,
            origin:           node.world_position() - volume.half_extents,
            smallest_spacing: math::min(spacing.x, spacing.y, spacing.z),
            probe_count:      volume.probe_count(),
            desc:             volume.update,
        );
    }
    mirror.fill = state;
    if (work == (ProbeFillWork){} && !scene_due) return;

    mirror.fill_recorded = true;
    if (work.irradiance || plan.clear) {
        record_probe_atlas_fill(
            renderer:     renderer,
            recording:    recording,
            atlas:        &mirror.irradiance,
            cell_edge:    shader::PROBE_IRRADIANCE_CELL,
            kind:         shader::PROBE_ATLAS_IRRADIANCE,
            max_distance: volume.max_distance,
            clear:        plan.clear,
        )!;
    }
    if (work.visibility || plan.clear) {
        record_probe_atlas_fill(
            renderer:     renderer,
            recording:    recording,
            atlas:        &mirror.visibility,
            cell_edge:    shader::PROBE_VISIBILITY_CELL,
            kind:         shader::PROBE_ATLAS_VISIBILITY,
            max_distance: volume.max_distance,
            clear:        plan.clear,
        )!;
    }
    if (scene_due) {
        mirror.updated_frame = renderer.frame_index + 1;
        usz slot = (usz)(mirror - &renderer.probe_volumes[0]);
        recording.updates[recording.update_count++] = { .slot = slot, .plan = plan };
    }
}

fn void? record_probe_atlas_fill(
    Renderer* renderer,
    ProbeFillRecording* recording,
    Target* atlas,
    uint cell_edge,
    uint kind,
    float max_distance,
    bool clear,
) @private {
    acquire_probe_pipelines(renderer)!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    if (!recording.environment_ready) {
        // The fill reads the SH buffer an environment preparation may have written this frame.
        gpu::Barrier environment_written = { .before = { .compute }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &environment_written)!;
        if (recording.lighting) {
            recording.environment = pack_lighting_environment(
                renderer:    renderer,
                environment: recording.lighting,
                intensity:   recording.environments.lighting_intensity,
                rotation:    recording.environments.lighting_rotation,
                sheen:       false,
            )!;
        }
        recording.environment_ready = true;
    }

    @profile_pass(renderer, Pass.PROBE_UPDATE) {
        atlas.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
        gpu::MappedGpuSpan fill_root = slot.upload.take(&renderer.device, ProbeFillRoot::size, STREAM_ALIGNMENT)!;
        *(ProbeFillRoot*)fill_root.bytes.ptr = {
            .environment  = clear ? (gpu::GpuAddress)0 : recording.environment,
            .atlas        = atlas.view.index,
            .width        = atlas.width,
            .height       = atlas.height,
            .cell_edge    = cell_edge,
            .kind         = kind,
            .max_distance = max_distance,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.probe_pipelines.fill)!;
        dispatch_over(renderer, fill_root.address, atlas)!;

        atlas.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
        gpu::MappedGpuSpan border_root = slot.upload.take(&renderer.device, ProbeBorderRoot::size, STREAM_ALIGNMENT)!;
        *(ProbeBorderRoot*)border_root.bytes.ptr = {
            .atlas     = atlas.view.index,
            .cell_edge = cell_edge,
            .width     = atlas.width,
            .height    = atlas.height,
        };
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.probe_pipelines.border)!;
        dispatch_over(renderer, border_root.address, atlas)!;
    }!;

    atlas.transition(&renderer.commands, renderer.sampled_state)!;
    renderer.stats.post_dispatches += 2;
    renderer.work_recorded = true;
}

fn gpu::GpuAddress? pack_probe_volumes(Renderer* renderer, Scene* scene, uint view_layers) @private {
    usz[shader::PROBE_VOLUME_CAPACITY] order;
    usz count = order_view_probe_volumes(&renderer.probe_volumes, scene, view_layers, &order);
    if (!count) return (gpu::GpuAddress)0;
    return pack_probe_set(renderer, scene, order[:count]);
}

fn gpu::GpuAddress? pack_probe_set(
    Renderer* renderer,
    Scene* scene,
    usz[] order,
    bool unit_energy = false,
) @private {
    usz count = order.len;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, ProbeVolumeSetGpu::size, STREAM_ALIGNMENT)!;
    ProbeVolumeSetGpu* set = (ProbeVolumeSetGpu*)span.bytes.ptr;
    *set = { .count = (uint)count };
    foreach (index, slot_index : order[:count]) {
        ProbeVolumeRes* mirror = &renderer.probe_volumes[slot_index];
        ProbeVolume* volume = scene.world.get(mirror.entity, ProbeVolume);
        Vec3 origin = scene.node(mirror.entity).world_position() - volume.half_extents;
        Vec3 spacing = volume.spacing();
        set.volumes[index] = {
            .origin_energy        = { origin.x, origin.y, origin.z, unit_energy ? 1 : volume.energy },
            .spacing_max_distance = { spacing.x, spacing.y, spacing.z, volume.max_distance },
            .biases               = { volume.normal_bias, volume.view_bias, 0, 0 },
            .count_x              = mirror.counts.x,
            .count_y              = mirror.counts.y,
            .count_z              = mirror.counts.z,
            .irradiance           = mirror.irradiance.view.index,
            .visibility           = mirror.visibility.view.index,
            .sampler_index        = renderer.linear_clamp_sampler,
            .slices_per_row       = mirror.slices_per_row,
        };
    }
    return span.address;
}

fn void snapshot_probe_states(Renderer* renderer) @private {
    foreach (&mirror : renderer.probe_volumes) {
        mirror.frame_irradiance_state = mirror.irradiance.state;
        mirror.frame_visibility_state = mirror.visibility.state;
        mirror.frame_fill = mirror.fill;
        mirror.fill_recorded = false;
    }
}

fn void restore_probe_states(Renderer* renderer) @private {
    foreach (&mirror : renderer.probe_volumes) {
        mirror.irradiance.state = mirror.frame_irradiance_state;
        mirror.visibility.state = mirror.frame_visibility_state;
    }
}

fn void discard_probe_fills(Renderer* renderer) @private {
    foreach (&mirror : renderer.probe_volumes) {
        if (!mirror.fill_recorded) continue;
        mirror.fill = mirror.frame_fill;
        mirror.fill_recorded = false;
        mirror.updated_frame = 0;
    }
}

fn void commit_probe_fills(Renderer* renderer) @private {
    foreach (&mirror : renderer.probe_volumes) mirror.fill_recorded = false;
}

fn void free_probe_volumes(Renderer* renderer) @private {
    foreach (&mirror : renderer.probe_volumes) {
        if (mirror.irradiance.texture.is_valid()) release_storage_target(&renderer.device, &mirror.irradiance);
        if (mirror.visibility.texture.is_valid()) release_storage_target(&renderer.device, &mirror.visibility);
        *mirror = {};
    }
    ProbeVolumePipelines* pipelines = &renderer.probe_pipelines;
    if (pipelines.fill.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, pipelines.fill);
    if (pipelines.border.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, pipelines.border);
    *pipelines = {};
}
