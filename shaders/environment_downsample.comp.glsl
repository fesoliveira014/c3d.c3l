#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Length of the overlap between the input texel and the output texel's footprint, in units of 1/output_size.
uint footprint_overlap(uint input_texel, uint output_texel, uint input_size, uint output_size) {
    uint low = max(input_texel * output_size, output_texel * input_size);
    uint high = min((input_texel + 1u) * output_size, (output_texel + 1u) * input_size);
    return high > low ? high - low : 0u;
}

void main() {
    EnvironmentDownsampleRoot root = EnvironmentDownsampleRoot(pc.root_gpu);
    uint output_size = max(root.size >> 1u, 1u);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= output_size || texel.y >= output_size) return;

    uvec2 first = texel * root.size / output_size;
    uvec2 last = min(((texel + 1u) * root.size + output_size - 1u) / output_size, uvec2(root.size));
    vec4 accumulated = vec4(0.0);
    for (uint y = first.y; y < last.y; y++) {
        uint weight_y = footprint_overlap(y, texel.y, root.size, output_size);
        for (uint x = first.x; x < last.x; x++) {
            uint weight_x = footprint_overlap(x, texel.x, root.size, output_size);
            accumulated += load_storage_texture(root.input_texture, ivec2(x, y)) * float(weight_x * weight_y);
        }
    }

    store_storage_texture(root.output_texture, ivec2(texel), accumulated / float(root.size * root.size));
}
