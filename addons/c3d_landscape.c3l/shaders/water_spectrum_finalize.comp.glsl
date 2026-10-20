#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors SpectrumFinalizeRoot in water_gpu/spectral.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FinalizeRoot {
    uint first_frame;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

// Splits the transformed complex fields into the real images the vertex stage samples, and keeps the displacement of
// the frame before in the previous image.
void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    FinalizeRoot finalize = FinalizeRoot(root.parameters);

    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    vec4 first = fetch_texture_2d(textures.slots[0].texture_index, texel);
    vec4 second = fetch_texture_2d(textures.slots[1].texture_index, texel);
    vec4 earlier = load_storage_texture(textures.slots[2].texture_index, texel);

    vec4 displacement = vec4(first.y, first.x, first.z, 0.0);
    store_storage_texture(textures.slots[2].texture_index, texel, displacement);
    store_storage_texture(textures.slots[3].texture_index, texel, finalize.first_frame != 0u ? displacement : earlier);
    store_storage_texture(textures.slots[4].texture_index, texel, vec4(first.w, second.x, 0.0, 0.0));
}
