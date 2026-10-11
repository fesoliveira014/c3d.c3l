#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "descriptor_heap.glsl"
#include "optical_throughput.surface.glsl"

layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
layout(location = 0) flat in uint surface_index;
layout(location = 1) in vec2 surface_uv;
layout(location = 0) out vec4 throughput;
#ifdef OPTICAL_GROUP_OUTPUTS
layout(location = 1) out float shade_depth;
layout(location = 2) out vec4 order_signature;
#endif

OpticalSurface optical_mapped_surface(OpticalDraw root, OpticalSurface surface) {
    if (surface.map != 0u) {
        vec4 mapped = sample_texture_2d(surface.map, root.sampler_index, surface_uv);
        surface.factors.x *= mapped.r;
        surface.normal_thickness.w *= mapped.g;
        surface.base_coverage.a *= mapped.a;
    }
    return surface;
}

void main() {
    OpticalDraw root = OpticalDraw(pc.fragment_root);
    OpticalSurface surface = optical_mapped_surface(root, OpticalSurfaces(root.surfaces).values[surface_index]);
    ivec2 pixel = ivec2(gl_FragCoord.xy);
#ifdef OPTICAL_GROUP_OUTPUTS
    shade_depth = gl_FragCoord.z;
    order_signature = vec4(0.0);
#endif
    if (root.phase == OPTICAL_PHASE_SURFACE) {
        throughput = vec4(optical_surface_throughput(surface), 1.0);
        return;
    }
    if (root.phase == OPTICAL_PHASE_STORE) {
        throughput = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.source))], pixel, 0);
        return;
    }
    bool front = gl_FrontFacing != ((surface.flags & OPTICAL_MIRRORED) != 0u);
    if ((surface.flags & OPTICAL_FACE_POLICY) != 0u && (surface.flags & OPTICAL_DOUBLE_SIDED) == 0u && !front) discard;
    if (!optical_surface_survives(surface) || gl_FragCoord.z <= root.receiver_depth) discard;
    if (root.phase == OPTICAL_PHASE_OPAQUE) {
        if (!optical_surface_blocks(surface)) discard;
        throughput = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0);
        return;
    }
    if (root.phase == OPTICAL_PHASE_LEGACY) {
        if ((surface.flags & OPTICAL_ALPHA_BLEND) != 0u) discard;
        throughput = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0);
        return;
    }
    if (!optical_surface_participates(surface)) discard;
    if (root.phase == OPTICAL_PHASE_CAPTURE) {
        if (root.previous != 0u && gl_FragCoord.z >= texelFetch(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.previous))], pixel, 0).r) discard;
        throughput = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0);
        return;
    }
    float selected = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.selected))], pixel, 0).r;
    if (gl_FragCoord.z != selected) discard;
    throughput = vec4(optical_surface_throughput(surface), 1.0);
#ifdef OPTICAL_GROUP_OUTPUTS
    vec3 token = vec3(surface.node_index + 1u, surface.instance_index + 1u, surface.primitive_index + 1u) / 32.0;
    order_signature = vec4(token * 0.5, 0.5);
#endif
}
