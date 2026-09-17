#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FogRoot {
    vec4 color;
    float proj_22;
    float proj_23;
    uint orthographic;
    float density;
    uint width;
    uint height;
    uint _pad0;
    uint _pad1;
};

const float BACKGROUND_DEPTH = 1.0e6;

float view_depth(float depth, FogRoot fog) {
    if (fog.orthographic != 0u) return (fog.proj_23 - depth) / fog.proj_22;
    float denominator = depth + fog.proj_22;
    return denominator > 0.0 ? fog.proj_23 / denominator : BACKGROUND_DEPTH;
}

void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    FogRoot fog = FogRoot(root.parameters);
    uvec2 coord = gl_GlobalInvocationID.xy;
    if (coord.x >= fog.width || coord.y >= fog.height) return;

    vec2 uv = (vec2(coord) + 0.5) / vec2(fog.width, fog.height);
    float depth = sample_texture_2d(textures.slots[0].texture_index, textures.slots[0].sampler_index, uv).r;
    float distance = view_depth(depth, fog);
    float amount = 1.0 - exp(-fog.density * distance);
    vec4 color = load_storage_texture(textures.slots[1].texture_index, ivec2(coord));
    store_storage_texture(textures.slots[1].texture_index, ivec2(coord), vec4(mix(color.rgb, fog.color.rgb, amount), color.a));
}
