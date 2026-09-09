#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// Mirrored from material::CubeFace.
const uint CUBE_POSITIVE_X = 0u;
const uint CUBE_NEGATIVE_X = 1u;
const uint CUBE_POSITIVE_Y = 2u;
const uint CUBE_NEGATIVE_Y = 3u;
const uint CUBE_POSITIVE_Z = 4u;
const uint CUBE_NEGATIVE_Z = 5u;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

vec3 cube_face_direction(uint face, vec2 coordinates) {
    switch (face) {
        case CUBE_POSITIVE_X: return vec3(1.0, -coordinates.y, -coordinates.x);
        case CUBE_NEGATIVE_X: return vec3(-1.0, -coordinates.y, coordinates.x);
        case CUBE_POSITIVE_Y: return vec3(coordinates.x, 1.0, coordinates.y);
        case CUBE_NEGATIVE_Y: return vec3(coordinates.x, -1.0, -coordinates.y);
        case CUBE_POSITIVE_Z: return vec3(coordinates.x, -coordinates.y, 1.0);
        case CUBE_NEGATIVE_Z: return vec3(-coordinates.x, -coordinates.y, -1.0);
    }
    return vec3(0.0, 0.0, 1.0);
}

void main() {
    CubePreviewRoot root = CubePreviewRoot(pc.fragment_root_gpu);
    vec3 direction = cube_face_direction(root.face, v_uv * 2.0 - 1.0);
    out_color = root.explicit_lod != 0u
        ? sample_texture_cube_lod(root.source_texture, root.source_sampler, direction, root.lod)
        : sample_texture_cube_implicit(root.source_texture, root.source_sampler, direction);
}
