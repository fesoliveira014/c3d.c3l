#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "cube_direction.glsl"
#include "irradiance.glsl"

layout(local_size_x = ENVIRONMENT_SH_GROUP_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared vec3 group_sums[9][ENVIRONMENT_SH_GROUP_SIZE];

float environment_cube_area(float s, float t) {
    return atan(s * t, sqrt(1.0 + s * s + t * t));
}

float environment_texel_solid_angle(uvec2 texel, uint size) {
    vec2 minimum = vec2(texel) * (2.0 / float(size)) - 1.0;
    vec2 maximum = vec2(texel + 1u) * (2.0 / float(size)) - 1.0;
    return environment_cube_area(maximum.x, maximum.y)
        - environment_cube_area(minimum.x, maximum.y)
        - environment_cube_area(maximum.x, minimum.y)
        + environment_cube_area(minimum.x, minimum.y);
}

void main() {
    IrradianceProjectRoot root = IrradianceProjectRoot(pc.root_gpu);
    uint lane = gl_LocalInvocationIndex;
    vec3 sums[9];
    for (uint coefficient = 0u; coefficient < 9u; coefficient++) sums[coefficient] = vec3(0.0);

    for (uint face = 0u; face < ENVIRONMENT_FACE_COUNT; face++) {
        for (uint row = gl_WorkGroupID.x; row < root.source_size; row += root.partial_count) {
            for (uint column = lane; column < root.source_size; column += ENVIRONMENT_SH_GROUP_SIZE) {
                uvec2 texel = uvec2(column, row);
                vec2 uv = (vec2(texel) + 0.5) / float(root.source_size);
                vec3 direction = environment_cube_direction(face, uv);
                vec3 radiance = sample_texture_cube_lod(
                    root.source_cube,
                    root.sampler_index,
                    direction,
                    0.0
                ).rgb;
                float solid_angle = environment_texel_solid_angle(texel, root.source_size);
                for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
                    sums[coefficient] += radiance
                        * (environment_sh_basis(coefficient, direction) * solid_angle);
                }
            }
        }
    }

    for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
        group_sums[coefficient][lane] = sums[coefficient];
    }
    barrier();
    for (uint width = ENVIRONMENT_SH_GROUP_SIZE / 2u; width > 0u; width >>= 1u) {
        if (lane < width) {
            for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
                group_sums[coefficient][lane] += group_sums[coefficient][lane + width];
            }
        }
        barrier();
    }

    if (lane == 0u) {
        for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
            IrradianceWriteonlyArray(root.partials).values[gl_WorkGroupID.x]
                .coefficients[coefficient] = vec4(group_sums[coefficient][0], 0.0);
        }
    }
}
