#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "brdf.glsl"
#include "custom_material.glsl"
#include "lights.glsl"
#include "shadows.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PulseParams {
    vec4 color;
    vec4 motion;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    PulseParams params = PulseParams(material.parameters);

    vec4 base_color = params.color;
    if (custom_slot_present(material, 0u)) base_color *= sample_custom_map(material, 0u, v_uv0, v_uv1);
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && base_color.a < material.alpha_cutoff) discard;

    vec3 normal = normalize(v_normal);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) normal = -normal;

    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    vec3 color = frame.ambient.rgb * base_color.rgb;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;
        LightSample light_sample = sample_light(light, v_world_pos);
        float visibility = 1.0;
        if ((draw.flags & DRAW_RECEIVE_SHADOW) != 0u && light.shadow_count != 0u) {
            visibility = shadow_visibility(frame, light, v_world_pos, normal, view_depth);
        }
        float diffuse = max(dot(normal, light_sample.direction), 0.0);
        color += base_color.rgb / PI * diffuse * light_sample.radiance * visibility;
    }
    out_color = material_output(color, base_color.a, material.flags);
}
