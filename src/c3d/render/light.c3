module c3d::render;

import c3d::ecs;
import c3d::light;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import std::math;

<* View inclusion and budget results for punctual lights. *>
struct LightCounts {
    uint packed;
    uint culled;  // outside the frustum, or an atmosphere's sun below the horizon
    uint dropped;
}

<*
 Pack eligible lights in component order within the view budget.
 Only the atmosphere's sun is attenuated; a sun whose radiance is exactly zero packs nothing.
 @param allocator : "Owns both returned arrays."
 @param [&in] scene : "Current world transforms and valid light descriptions."
 @param [in] frustum : "Current view clipping planes; null keeps every light."
 @param view_layers : "Camera visibility mask."
 @param [&inout] counts : "Overwritten with this view's counts."
 @param [in] atmosphere : "Null or a zero entity attenuates no light."
 @param altitude : "Metres above world y = 0 the sun is seen from."
 @param ray_tracing : "Flagged lights trace instead of requesting atlas layers."
 @param trace_shadows : "Every shadowing light traces, whatever its own flag says."
 @require capacity > 0
*>
fn LightExtraction extract_lights(
    Allocator allocator,
    Scene* scene,
    Frustum* frustum,
    uint view_layers,
    uint capacity,
    LightCounts* counts,
    AtmosphereSelection* atmosphere,
    float altitude,
    RayTracingDesc ray_tracing = {},
    bool trace_shadows = false,
) {
    LightGpu[] packed = alloc::new_array(allocator, LightGpu, math::min(scene.count(Light), capacity));
    ShadowRequest[] requests = collect_shadow_requests(
        allocator: allocator,
        scene: scene,
        packed: packed,
        frustum: frustum,
        view_layers: view_layers,
        capacity: (uint)packed.len,
        counts: counts,
        atmosphere: atmosphere,
        altitude: altitude,
        ray_tracing: ray_tracing,
        trace_shadows: trace_shadows,
    );
    return { .lights = packed[:counts.packed], .shadows = requests };
}

fn ShadowRequest[] collect_shadow_requests(
    Allocator allocator,
    Scene* scene,
    LightGpu[] packed,
    Frustum* frustum,
    uint view_layers,
    uint capacity,
    LightCounts* counts,
    AtmosphereSelection* atmosphere = null,
    float altitude = 0,
    RayTracingDesc ray_tracing = {},
    bool trace_shadows = false,
) @private {
    *counts = {};
    ShadowRequest[] requests = alloc::new_array(allocator, ShadowRequest, capacity);
    uint request_count;

    scene.@each(Light; Entity entity, Light* light) {
        Node* node = scene.node(entity);
        bool eligible = node.visible_effective && (node.layers & view_layers)
          && light.layers != 0 && light.intensity > 0;
        Vec4 color_intensity = { light.color.r, light.color.g, light.color.b, light.intensity };
        if (eligible && atmosphere && atmosphere.atmosphere && c3d::same_id(entity, atmosphere.entity)) {
            Vec3 radiance = light::sun_radiance(
                atmosphere: atmosphere.atmosphere,
                sun:        light,
                to_sun:     sun_direction(node),
                altitude:   altitude,
            );
            color_intensity = { radiance.r, radiance.g, radiance.b, 1 };
            if (radiance == (Vec3){}) {
                eligible = false;
                counts.culled++;
            }
        }
        if (eligible) {
            uint packed_index = counts.packed;
            bool ray_traced = trace_shadows ? light.shadow.enabled : light_ray_traced(light, ray_tracing);
            include_light(
                packed: packed,
                node: node,
                light: light,
                color_intensity: color_intensity,
                frustum: frustum,
                capacity: capacity,
                counts: counts,
                ray_traced: ray_traced,
            );

            if (counts.packed != packed_index && light.shadow.enabled && !ray_traced) {
                light.validate_shadow();
                uint layer_count;
                switch (light.kind) {
                    case DIRECTIONAL: layer_count = light.shadow.cascades;
                    case SPOT: layer_count = 1;
                    case POINT: layer_count = shader::SHADOW_POINT_FACE_COUNT;
                }
                requests[request_count++] = {
                    .light = entity,
                    .light_index = packed_index,
                    .priority = light.shadow.priority,
                    .layer_count = layer_count,
                };
            }
        }
    };

    return requests[:request_count];
}

fn void include_light(
    LightGpu[] packed,
    Node* node,
    Light* light,
    Vec4 color_intensity,
    Frustum* frustum,
    uint capacity,
    LightCounts* counts,
    bool ray_traced,
) @local {
    Vec3 position = node.world_position();
    if (frustum && light.kind != DIRECTIONAL && light.range > 0
        && !maths::frustum_intersects_sphere(frustum, { .center = position, .radius = light.range })) {
        counts.culled++;
        return;
    }

    if (counts.packed == capacity) {
        counts.dropped++;
        return;
    }

    uint index = counts.packed++;
    if (!packed.len) return;

    Vec3 direction;
    if (light.kind != POINT) {
        direction = maths::transform_dir(node.world, { 0, 0, -1 }).normalize();
    }

    packed[index] = {
        .position_range = { position.x, position.y, position.z, light.range },
        .direction_cos_outer = { direction.x, direction.y, direction.z,
            light.kind == SPOT ? math::cos(light.outer_cone) : 0 },
        .color_intensity = color_intensity,
        .kind = (uint)light.kind.ordinal,
        .layers = light.layers,
        .cos_inner = light.kind == SPOT ? math::cos(light.inner_cone) : 0,
        .flags = ray_traced ? shader::LIGHT_RT_SHADOW : 0,
    };
}

fn bool light_ray_traced(Light* light, RayTracingDesc ray_tracing) @private {
    return light.shadow.enabled && light.shadow.ray_traced && ray_tracing.shadows;
}
