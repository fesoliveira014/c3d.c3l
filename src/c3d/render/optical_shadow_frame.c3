module c3d::render;

import c3d;
import c3d::light;
import c3d::scene;
import c3d::shader;
import gpu;

fn bool scene_has_colored_shadows(Scene* scene) @private {
    scene.@each(Light; Entity entity, Light* light) {
        Node* node = scene.node(entity);
        if (node.visible_effective && node.layers && light.layers && light.intensity > 0
          && light.shadow.enabled && light.shadow.colored_transmission) return true;
    };

    return false;
}

fn gpu::GpuAddress? pack_optical_shadows(
    Renderer* renderer,
    Scene* scene,
    LightGpu[] lights,
    gpu::GpuAddress layers = (gpu::GpuAddress)0,
) @private {
    if (!scene_has_colored_shadows(scene)) {
        retire_optical_scene_trace(renderer);
        retire_optical_shadow_atlas(&renderer.pending_upload_retire, &renderer.optical_shadow_atlas);
        renderer.optical_shadow_preparation = false;
        renderer.stats.optical_shadow_payload_bytes = 0;
        renderer.stats.optical_shadow_scratch_bytes = 0;
        return (gpu::GpuAddress)0;
    }

    renderer.optical_shadow_preparation = true;
    bool enabled;
    bool traced;
    foreach (light : lights) {
        bool colored = (light.flags & shader::LIGHT_COLORED_TRANSMISSION) != 0;
        enabled |= colored;
        traced |= colored && (light.flags & shader::LIGHT_RT_SHADOW) != 0;
    }
    if (!enabled) return (gpu::GpuAddress)0;

    gpu::GpuAddress trace;
    if (traced) trace = record_optical_scene_trace(renderer, scene)!;
    OpticalShadowsGpu optical = {
        .layers = layers,
        .trace = trace,
        .capacity = renderer.transmission_shadow_layers,
    };

    return upload_bytes(renderer, &optical, OpticalShadowsGpu::size);
}
