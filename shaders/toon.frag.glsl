#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "material_alpha.glsl"
#include "material_maps.glsl"
#include "shadows.glsl"
#include "toon.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    ToonMaterialGpu material = ToonMaterialGpu(draw.material);
    vec4 base_color = material.color;
    if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        base_color *= sample_map(material.map, material.map_flags, MATERIAL_MAP_BASE_COLOR, v_uv0, v_uv1);
    }

    vec3 normal = normalize(v_normal);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) normal = -normal;

    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && base_color.a < material.alpha_cutoff) discard;

    vec3 view_direction = standard_view_direction(frame, v_world_pos);
    vec3 color = frame.ambient.rgb * base_color.rgb;
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        vec3 irradiance = environment_irradiance(
            environment.sh,
            environment_rotate(environment.rotation, normal)
        );
        color += base_color.rgb / PI * irradiance * environment.intensity;
    }

    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;

        LightSample light_sample = sample_light(light, v_world_pos);
        float response = toon_response(material, dot(normal, light_sample.direction));
        float visibility = 1.0;
        if ((draw.flags & DRAW_RECEIVE_SHADOW) != 0u && light.shadow_count != 0u) {
            visibility = shadow_visibility(frame, light, v_world_pos, normal, view_depth);
        }
        color += base_color.rgb / PI * response * light_sample.radiance * visibility;
    }
    color += toon_rim(material, normal, view_direction);
    out_color = material_output(color, base_color.a, material.flags);
}
