#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    TransparencyMipRoot root = TransparencyMipRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    vec2 scale = vec2(root.source_width, root.source_height) / vec2(root.width, root.height);
    vec2 low = vec2(pixel) * scale;
    vec2 high = vec2(pixel + 1u) * scale;
    ivec2 begin = ivec2(floor(low));
    ivec2 end = min(ivec2(ceil(high)), ivec2(root.source_width, root.source_height));
    vec4 sum = vec4(0.0);

    for (int y = begin.y; y < end.y; y++) {
        float vertical = min(high.y, float(y + 1)) - max(low.y, float(y));
        for (int x = begin.x; x < end.x; x++) {
            float horizontal = min(high.x, float(x + 1)) - max(low.x, float(x));
            vec4 value = root.source_storage != 0u
                ? load_storage_texture(root.source, ivec2(x, y))
                : texelFetch(
                    gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.source))],
                    ivec2(x, y),
                    int(root.source_mip)
                );
            sum += value * (horizontal * vertical);
        }
    }

    store_storage_texture(root.destination, ivec2(pixel), sum / (scale.x * scale.y));
}
