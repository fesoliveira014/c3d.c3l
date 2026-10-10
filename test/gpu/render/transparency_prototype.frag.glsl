#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"

struct Surface {
    vec4 bounds;
    vec4 color;
    float depth;
    float coverage;
    uint kind;
    uint node;
    uint part;
    uint instance;
    uint primitive;
    uint padding;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Surfaces {
    Surface values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Draw {
    uint64_t surfaces;
    uint first;
    uint entries_per_instance;
    uint previous;
    uint selected;
    uint scene;
    uint mode;
    uint has_previous;
    uint unused0;
    uint unused1;
    uint unused2;
};
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
#ifdef MESH_VERTEX_PATH
layout(location = 8) flat in uint surface_index;
#else
layout(location = 0) flat in uint surface_index;
#endif
layout(location = 0) out vec4 radiance;
layout(location = 1) out float shade_depth;

float fetch_depth(uint image, ivec2 pixel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(image))], pixel, 0).x;
}

void main() {
    Draw root = Draw(pc.fragment_root);
    Surface surface = Surfaces(root.surfaces).values[surface_index];
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = gl_FragCoord.z;
    float opaque_depth = pixel.x >= 64 ? 0.3125 : 0.0;
    bool fallback = surface.kind >= 2u;
    if (root.mode != 3u && fallback) discard;
    if (root.mode == 3u && !fallback) discard;
    if (surface.kind != 3u && depth <= opaque_depth) discard;
    if (root.mode == 0u) {
        if (root.has_previous != 0u && depth >= fetch_depth(root.previous, pixel)) discard;
        radiance = vec4(depth, 0, 0, 1);
    } else {
        if (root.mode == 1u && depth != fetch_depth(root.selected, pixel)) discard;
        if (root.mode == 2u && depth >= fetch_depth(root.selected, pixel)) discard;
        vec3 color = surface.color.rgb;
        if (surface.kind == 1u || surface.kind == 2u) {
            vec3 behind = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.scene))], pixel, 0).rgb;
            color = 0.5 * color + 0.5 * behind;
        }
        radiance = vec4(color * surface.coverage, surface.coverage);
    }
    shade_depth = depth;
}
