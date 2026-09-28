module c3d::render;

import c3d;
import c3d::light;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const float PROBE_RESTART_SPACING @private = 0.5f; // of the smallest spacing; a larger jump between updates restarts the atlas
const float PROBE_RAY_FAR @private = 1e4f;          // world units; a miss must read the sky, not a clamp inside a long hall
const uint PROBE_TRACE_GROUP_SIZE @local = 64;      // mirrored as local_size_x in probe_trace.comp.glsl
const uint PROBE_UPDATE_DISPATCHES @local = 5;      // trace, two blends, two borders

struct ProbeWindow @private {
    uint first;
    uint count;
    uint next;
}

struct ProbeScenePlan @private {
    bool  clear;
    uint  first;
    uint  count;
    float hysteresis;
}

struct ProbeUpdateState @private {
    gpu::GpuAllocation  rays;
    gpu::GpuAddress     rays_address;
    usz                 ray_capacity;
    gpu::PipelineHandle trace;
    gpu::PipelineHandle blend;
}

<*
 @require count > 0 && cursor < count
*>
fn ProbeWindow probe_update_window(uint cursor, uint count, uint probes_per_frame) @private {
    uint remaining = count - cursor;
    if (probes_per_frame == 0 || probes_per_frame >= remaining) return { .first = cursor, .count = remaining };
    return { .first = cursor, .count = probes_per_frame, .next = cursor + probes_per_frame };
}

<*
 @require probe_count > 0 && smallest_spacing > 0
*>
fn ProbeScenePlan plan_probe_scene(
    ProbeFillState* state,
    Vec3 origin,
    float smallest_spacing,
    uint probe_count,
    ProbeUpdateDesc desc,
) @private {
    ProbeScenePlan plan;
    if (state.filled() && !state.scene_defined) {
        state.scene_defined = true;
        state.scene_swept = true;
        state.cursor = 0;
    } else if (!state.scene_defined
        || (origin - state.traced_origin).length() > PROBE_RESTART_SPACING * smallest_spacing) {
        plan.clear = true;
        state.scene_defined = true;
        state.scene_swept = false;
        state.cursor = 0;
    }
    state.irradiance = {};
    state.visibility_filled = false;
    state.traced_origin = origin;

    ProbeWindow window = probe_update_window(state.cursor, probe_count, desc.probes_per_frame);
    plan.first = window.first;
    plan.count = window.count;
    plan.hysteresis = state.scene_swept ? desc.hysteresis : 0;
    state.cursor = window.next;
    if (!state.scene_swept && window.next == 0) state.scene_swept = true;
    return plan;
}

fn bool probe_scene_due(Renderer* renderer, Scene* scene, Entity entity) @private {
    if (!scene.node(entity).visible_effective) return false;
    ProbeVolumeRes* mirror = find_probe_volume(renderer, scene.identity, entity);
    return !mirror || mirror.updated_frame != renderer.frame_index + 1;
}

<*
 Software trace for this frame's scene updates; zero when none is due.
 @require renderer.frame_open
*>
fn gpu::GpuAddress? prepare_probe_updates(Renderer* renderer, Scene* scene) @private {
    bool due;
    scene.@each(ProbeVolume; Entity entity, ProbeVolume* volume) {
        due |= volume.fill == ProbeFill.SCENE && probe_scene_due(renderer, scene, entity);
    };
    if (!due) return (gpu::GpuAddress)0;
    return renderer.prepare_scene_trace(scene, TraceKind.SOFTWARE);
}

fn void write_probe_frame_root(
    FrameRoot* root,
    gpu::GpuAddress lights,
    uint light_count,
    gpu::GpuAddress trace,
    gpu::GpuAddress environment,
    Vec4 ambient,
    gpu::GpuAddress probe_volumes,
    ulong frame_index,
) @private {
    Mat4 identity_matrix = matrix::IDENTITY4;
    Mat4f identity = bitcast(identity_matrix, Mat4f);
    *root = {
        .view            = identity,
        .proj            = identity,
        .view_proj       = identity,
        .inv_view_proj   = identity,
        .prev_view_proj  = identity,
        .lights          = lights,
        .light_count     = light_count,
        .trace           = trace,
        .environment     = environment,
        .ambient         = ambient,
        .probe_volumes   = probe_volumes,
        .frame_index     = (uint)frame_index,
        .flags           = shader::FRAME_TRACE_PRESENT,
    };
}

fn void? acquire_probe_update_pipelines(Renderer* renderer) @private {
    ProbeUpdateState* state = &renderer.probe_update;
    acquire_compute_pipeline(renderer, &state.trace, PROBE_TRACE, "probe_trace")!;
    acquire_compute_pipeline(renderer, &state.blend, PROBE_BLEND, "probe_blend")!;
}

fn void? acquire_probe_rays(Renderer* renderer, usz rays) @private {
    ProbeUpdateState* state = &renderer.probe_update;
    if (rays <= state.ray_capacity) return;

    gpu::AllocationDesc desc = {
        .size         = rays * RayResultGpu::size,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "probe_rays",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
    defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(&renderer.device, span)!;
    if (state.rays.is_valid()) {
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = state.rays });
    }
    state.rays = allocation;
    state.rays_address = address;
    state.ray_capacity = rays;
}

<*
 @require recording.update_count > 0
*>
fn void? record_probe_updates(Renderer* renderer, ProbeFillRecording* recording, gpu::GpuAddress trace) @private {
    Scene* scene = recording.scene;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    acquire_probe_update_pipelines(renderer)!;

    LightCounts light_counts;
    LightExtraction extraction = extract_lights(
        allocator:     tmem,
        scene:         scene,
        frustum:       null,
        view_layers:   uint::max,
        capacity:      renderer.max_lights,
        counts:        &light_counts,
        trace_shadows: true,
    );
    renderer.stats.lights_dropped += light_counts.dropped;
    gpu::GpuAddress lights = upload_lights(renderer, extraction.lights)!;

    if (recording.lighting && !recording.environment_ready) {
        recording.environment = pack_lighting_environment(
            renderer:    renderer,
            environment: recording.lighting,
            intensity:   scene.environment_intensity,
            rotation:    scene.environment_rotation,
            sheen:       false,
        )!;
        recording.environment_ready = true;
    }
    Vec3 ambient = recording.lighting && !scene.ambient_add
      ? (Vec3){} : scene.ambient_color * scene.ambient_intensity;

    usz[shader::PROBE_VOLUME_CAPACITY] order;
    usz count = order_hit_probe_volumes(&renderer.probe_volumes, scene, &order);
    // Views see energy; the feedback of the bounce stays at unit gain per albedo, or it can diverge.
    gpu::GpuAddress hit_set = pack_probe_set(renderer, scene, order[:count], unit_energy: true)!;
    gpu::MappedGpuSpan frame_span = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
    write_probe_frame_root(
        root:          (FrameRoot*)frame_span.bytes.ptr,
        lights:        lights,
        light_count:   (uint)extraction.lights.len,
        trace:         trace,
        environment:   recording.environment,
        ambient:       { ambient.r, ambient.g, ambient.b, 0 },
        probe_volumes: hit_set,
        frame_index:   renderer.frame_index,
    );

    Quat rotation = maths::random_rotation({
        maths::halton((uint)renderer.frame_index, 2),
        maths::halton((uint)renderer.frame_index, 3),
        maths::halton((uint)renderer.frame_index, 5),
    });
    foreach (&update : recording.updates[:recording.update_count]) {
        usz set_index;
        while (order[set_index] != update.slot) set_index++;
        record_probe_update(
            renderer:  renderer,
            mirror:    &renderer.probe_volumes[update.slot],
            volume:    scene.world.get(renderer.probe_volumes[update.slot].entity, ProbeVolume),
            plan:      &update.plan,
            frame:     frame_span.address,
            set_index: (uint)set_index,
            rotation:  rotation,
        )!;
    }
}

fn void? record_probe_update(
    Renderer* renderer,
    ProbeVolumeRes* mirror,
    ProbeVolume* volume,
    ProbeScenePlan* plan,
    gpu::GpuAddress frame,
    uint set_index,
    Quat rotation,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    uint rays_per_probe = volume.update.rays_per_probe;
    uint ray_count = plan.count * rays_per_probe;
    acquire_probe_rays(renderer, ray_count)!;
    ProbeUpdateState* state = &renderer.probe_update;
    Vec4f quaternion = bitcast(rotation.v, Vec4f);

    @profile_pass(renderer, Pass.PROBE_UPDATE) {
        // The ray buffer was read by the previous update's blend, and a clear wrote this volume's atlases.
        gpu::Barrier previous_work = { .before = { .compute }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &previous_work)!;
        gpu::MappedGpuSpan trace_root = slot.upload.take(&renderer.device, ProbeTraceRoot::size, STREAM_ALIGNMENT)!;
        *(ProbeTraceRoot*)trace_root.bytes.ptr = {
            .frame          = frame,
            .rays           = state.rays_address,
            .rotation       = quaternion,
            .volume         = set_index,
            .first_probe    = plan.first,
            .probe_count    = plan.count,
            .rays_per_probe = rays_per_probe,
            .ray_far        = PROBE_RAY_FAR,
            .cone_spread    = math::sqrt(4 * (float)math::PI / (float)rays_per_probe),
        };
        gpu::cmd_bind_pipeline(&renderer.commands, state.trace)!;
        uint groups = (ray_count + PROBE_TRACE_GROUP_SIZE - 1) / PROBE_TRACE_GROUP_SIZE;
        gpu::cmd_dispatch(&renderer.commands, trace_root.address, { groups, 1, 1 })!;

        gpu::Barrier rays_written = { .before = { .compute }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &rays_written)!;
        record_probe_blend(renderer, mirror, &mirror.irradiance, plan, frame, set_index, quaternion, rays_per_probe)!;
        record_probe_blend(renderer, mirror, &mirror.visibility, plan, frame, set_index, quaternion, rays_per_probe)!;
    }!;

    renderer.stats.probe_rays += ray_count;
    renderer.stats.probe_updates++;
    renderer.stats.post_dispatches += PROBE_UPDATE_DISPATCHES;
    renderer.work_recorded = true;
}

fn void? record_probe_blend(
    Renderer* renderer,
    ProbeVolumeRes* mirror,
    Target* atlas,
    ProbeScenePlan* plan,
    gpu::GpuAddress frame,
    uint set_index,
    Vec4f rotation,
    uint rays_per_probe,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    bool irradiance = atlas == &mirror.irradiance;
    uint cell_edge = irradiance ? shader::PROBE_IRRADIANCE_CELL : shader::PROBE_VISIBILITY_CELL;
    uint interior = cell_edge - 2;

    atlas.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read, .write }))!;
    gpu::MappedGpuSpan blend_root = slot.upload.take(&renderer.device, ProbeBlendRoot::size, STREAM_ALIGNMENT)!;
    *(ProbeBlendRoot*)blend_root.bytes.ptr = {
        .frame          = frame,
        .rays           = renderer.probe_update.rays_address,
        .rotation       = rotation,
        .volume         = set_index,
        .first_probe    = plan.first,
        .probe_count    = plan.count,
        .rays_per_probe = rays_per_probe,
        .kind           = irradiance ? shader::PROBE_ATLAS_IRRADIANCE : shader::PROBE_ATLAS_VISIBILITY,
        .hysteresis     = plan.hysteresis,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.probe_update.blend)!;
    dispatch_extent(renderer, blend_root.address, plan.count * interior, interior)!;

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
    atlas.transition(&renderer.commands, renderer.sampled_state)!;
}

fn void free_probe_update(Renderer* renderer) @private {
    ProbeUpdateState* state = &renderer.probe_update;
    if (state.rays.is_valid()) (void)gpu::free_allocation(&renderer.device, &state.rays);
    if (state.trace.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, state.trace);
    if (state.blend.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, state.blend);
    *state = {};
}
