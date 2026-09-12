#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "cube_direction.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    EnvironmentSourceRoot root = EnvironmentSourceRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.size || texel.y >= root.size) return;

    vec4 radiance = root.solid_color;
    if (root.source_kind == ENVIRONMENT_SOURCE_EQUIRECTANGULAR) {
        vec2 uv = (vec2(texel) + 0.5) / float(root.size);
        vec3 direction = environment_cube_direction(root.face, uv);
        // Longitude is undefined at a cube pole, so pin its azimuth to zero.
        float longitude = direction.x == 0.0 && direction.z == 0.0
            ? 0.5
            : atan(direction.z, direction.x) / (2.0 * BRDF_PI) + 0.5;
        vec2 source_uv = vec2(
            longitude,
            acos(clamp(direction.y, -1.0, 1.0)) / BRDF_PI
        );
        radiance = sample_texture_2d(root.source_texture, root.sampler_index, source_uv);
    }
    store_storage_texture(root.output_texture, ivec2(texel), vec4(radiance.rgb, 1.0));
}
