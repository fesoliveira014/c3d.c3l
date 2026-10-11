#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"
#include "c3d_abi.glsl"
#include "scene_snapshot.glsl"
#include "fog.glsl"

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
    uint reader;
    vec4 plane;
    uint range;
    uint padding0;
    uint padding1;
    uint padding2;
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
    uint opaque_depth;
    uint64_t transport;
};
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
#ifdef MESH_VERTEX_PATH
layout(location = 0) in vec3 mesh_world;
layout(location = 1) in vec3 mesh_normal;
layout(location = 2) in vec4 mesh_tangent;
layout(location = 3) in vec2 mesh_uv0;
layout(location = 4) in vec2 mesh_uv1;
layout(location = 5) in vec4 mesh_color;
layout(location = 6) in vec4 mesh_clip;
layout(location = 8) flat in uint surface_index;
#else
layout(location = 0) flat in uint surface_index;
#endif
layout(location = 0) out vec4 radiance;
layout(location = 1) out float shade_depth;

float fetch_depth(uint image, ivec2 pixel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(image))], pixel, 0).x;
}

#include "transparency_peel.participation.glsl"
#include "transparency_peel_fog.glsl"

void main() {
    Draw root = Draw(pc.fragment_root);
    if (root.transport != 0ul && root.mode >= 4u) {
        transparency_fog_phase(root);
        return;
    }
    Surface surface = Surfaces(root.surfaces).values[surface_index];
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = gl_FragCoord.z;
    float opaque_depth = fetch_depth(root.opaque_depth, pixel);
#ifdef MESH_VERTEX_PATH
    if (any(isnan(mesh_world)) || any(isnan(mesh_normal)) || any(isnan(mesh_tangent))
        || any(isnan(mesh_uv0)) || any(isnan(mesh_uv1)) || any(isnan(mesh_color)) || any(isnan(mesh_clip))) discard;
#endif
    bool fallback = surface.kind >= 2u;
    bool all_sorted = root.transport != 0ul && root.mode == 3u && (PeelTransport(root.transport).flags & 1u) != 0u;
    if (!all_sorted && root.mode != 3u && fallback) discard;
    if (!all_sorted && root.mode == 3u && !fallback) discard;
    if (surface.kind != 3u && depth <= opaque_depth) discard;
    if (!peel_transparency_accept(depth)) discard;
    if (root.mode == 0u) {
        radiance = vec4(depth, 0, 0, 1);
    } else {
        vec3 color = surface.color.rgb;
        if (root.transport != 0ul) {
            color = transparency_fog_surface(root, surface, depth);
            radiance = vec4(color * surface.coverage, surface.padding0 == 2u ? 0.0 : surface.coverage);
            shade_depth = depth;
            return;
        }
        if (surface.kind == 1u || surface.kind == 2u) {
            vec3 behind = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.scene))], pixel, 0).rgb;
            if (surface.reader == 2u) color *= opaque_depth;
            else if (surface.reader == 3u) color = 0.5 * color + 0.5 * behind + color * opaque_depth;
            else color = 0.5 * color + 0.5 * behind;
        }
        radiance = vec4(color * surface.coverage, surface.coverage);
    }
    shade_depth = depth;
}
