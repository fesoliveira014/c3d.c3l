#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "clusters.glsl"
#include "gbuffer.glsl"

layout(local_size_x = POST_GROUP_SIZE, local_size_y = POST_GROUP_SIZE, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float PREVIEW_BACKGROUND_DEPTH = 1e30;

// Forward distance from reverse-Z depth; no geometry (depth 0) reads as infinitely far.
float preview_view_distance(float depth, PreviewRoot root) {
    if (root.orthographic != 0u) return (root.proj_23 - depth) / root.proj_22;
    float denominator = depth + root.proj_22;
    return denominator > 0.0 ? root.proj_23 / denominator : PREVIEW_BACKGROUND_DEPTH;
}

// Mirrored as preview_face_direction in preview.c3; faces follow CubeFace order.
vec3 preview_face_direction(uint face, vec2 uv) {
    float u = uv.x * 2.0 - 1.0;
    float v = uv.y * 2.0 - 1.0;
    switch (face) {
        case 0u: return vec3(1.0, -v, -u);
        case 1u: return vec3(-1.0, -v, u);
        case 2u: return vec3(u, 1.0, v);
        case 3u: return vec3(u, -1.0, -v);
        case 4u: return vec3(u, -v, 1.0);
        default: return vec3(-u, -v, -1.0);
    }
}

void main() {
    PreviewRoot root = PreviewRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec3 result = vec3(0.0);
    switch (root.mode) {
        case PREVIEW_MODE_COLOR:
            vec3 color = sample_texture_2d(root.input_texture, root.input_sampler, uv).rgb;
            result = 1.0 - exp(-max(color, vec3(0.0)) * root.exposure);
            break;
        case PREVIEW_MODE_DEPTH_VIEW:
            float depth = sample_texture_2d(root.input_texture, root.input_sampler, uv).r;
            result = vec3(clamp(preview_view_distance(depth, root) / root.range, 0.0, 1.0));
            break;
        case PREVIEW_MODE_DEPTH_RAW:
            result = vec3(1.0 - sample_texture_2d(root.input_texture, root.input_sampler, uv).r);
            break;
        case PREVIEW_MODE_VELOCITY:
            vec2 velocity = sample_texture_2d(root.input_texture, root.input_sampler, uv).rg
                * vec2(root.width, root.height);
            result = vec3(clamp(length(velocity) / root.range, 0.0, 1.0));
            break;
        case PREVIEW_MODE_CUBE_FACE:
            vec3 direction = preview_face_direction(root.face, uv);
            vec3 radiance = sample_texture_cube(root.input_texture, root.input_sampler, direction).rgb;
            result = 1.0 - exp(-max(radiance, vec3(0.0)) * root.exposure);
            break;
        case PREVIEW_MODE_RAW:
            result = sample_texture_2d(root.input_texture, root.input_sampler, uv).rgb;
            break;
        case PREVIEW_MODE_GRAY:
            result = vec3(sample_texture_2d(root.input_texture, root.input_sampler, uv).r);
            break;
        case PREVIEW_MODE_OCTAHEDRAL_NORMAL:
            vec2 encoded = sample_texture_2d(root.input_texture, root.input_sampler, uv).rg;
            result = decode_octahedral(encoded) * 0.5 + 0.5;
            break;
        case PREVIEW_MODE_BITS:
            ivec2 source_size = textureSize(gpu_utexture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.input_texture))], 0);
            uint bits = gpu_fetch_uint(root.input_texture, ivec2(uv * vec2(source_size)), 0);
            result = vec3(float(bits & 1u), float((bits >> 1u) & 1u), float((bits >> 2u) & 1u));
            if ((bits >> 3u) != 0u) result += 0.25;
            break;
        case PREVIEW_MODE_CLUSTERS:
            ClusterGpu clusters = ClusterGpu(root.clusters);
            uvec2 tile = min(uvec2(uv * vec2(clusters.tiles_x, clusters.tiles_y)),
                uvec2(clusters.tiles_x - 1u, clusters.tiles_y - 1u));
            ClusterRange range = ClusterRanges(clusters.ranges).values[
                cluster_index(clusters, uvec3(tile, root.cluster_slice))];
            float occupancy = float(range.count) / float(clusters.lights_per_cluster);
            result = range.overflow != 0u
                ? vec3(1.0, 0.0, 1.0)
                : vec3(occupancy, 4.0 * occupancy * (1.0 - occupancy), 1.0 - occupancy);
            break;
        default:
            break;
    }
    store_storage_texture(root.output_texture, ivec2(texel), vec4(result, 1.0));
}
