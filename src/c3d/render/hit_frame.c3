module c3d::render;

import c3d;
import c3d::scene;
import c3d::shader;
import gpu;

fn bool trace_uses_sheen(Renderer* renderer) @private {
    foreach (record : renderer.scene_trace.baseline[:renderer.scene_trace.baseline_count]) {
        if (material_uses_sheen(&renderer.assets.material(record.material).data)) return true;
    }
    return false;
}

fn bool? prepare_hit_environment(Renderer* renderer, Scene* scene, ViewEnvironments* environments) @private {
    if (!trace_uses_sheen(renderer)) return false;

    acquire_sheen_lut(renderer)!;
    if (environments.atmosphere) {
        environments.atmosphere = resolve_atmosphere(
            renderer: renderer,
            scene: scene,
            selection: &environments.atmosphere_selection,
            sheen: true,
        )!;
        environments.lighting = &environments.atmosphere.lighting;
    } else if (environments.lighting) {
        environments.lighting = resolve_environment(
            renderer: renderer,
            environment: environments.lighting.asset,
            lighting: true,
            sheen: true,
        )!;
    }
    return true;
}

fn gpu::GpuAddress? pack_reflection_frame(
    Renderer* renderer,
    Scene* scene,
    ViewRecord* record,
    uint view_layers,
    float altitude,
    ViewEnvironments* environments,
    FrameRoot* source,
) @private {
    LightCounts counts;
    LightExtraction lights = extract_lights(
        allocator: tmem,
        scene: scene,
        frustum: null,
        view_layers: view_layers,
        capacity: renderer.max_lights,
        counts: &counts,
        atmosphere: &environments.atmosphere_selection,
        altitude: altitude,
        trace_shadows: true,
        origin: renderer.frame_origin,
    );
    renderer.stats.trace_lights += counts.packed;
    renderer.stats.trace_lights_dropped += counts.dropped;
    record.stats.trace_lights = counts.packed;
    record.stats.trace_lights_dropped = counts.dropped;

    bool sheen = prepare_hit_environment(renderer, scene, environments)!;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, FrameRoot::size, STREAM_ALIGNMENT)!;
    FrameRoot* root = (FrameRoot*)span.bytes.ptr;
    *root = *source;
    root.lights = upload_lights(renderer, lights.lights)!;
    root.light_count = counts.packed;
    if (sheen) {
        root.sheen_lut = renderer.environment_state.sheen_lut.view.index;
        root.sheen_sampler = renderer.environment_state.sheen_sampler;
        if (environments.lighting) {
            root.environment = pack_lighting_environment(
                renderer: renderer,
                environment: environments.lighting,
                intensity: environments.lighting_intensity,
                rotation: environments.lighting_rotation,
                sheen: true,
            )!;
        }
    }

    return span.address;
}
