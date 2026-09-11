#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "brdf.glsl"
#include "irradiance.glsl"

layout(local_size_x = ENVIRONMENT_SH_GROUP_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared vec3 coefficient_sums[9][ENVIRONMENT_SH_GROUP_SIZE];

float environment_cosine_factor(uint coefficient) {
    if (coefficient == 0u) return BRDF_PI;
    if (coefficient <= 3u) return 2.0 * BRDF_PI / 3.0;
    return BRDF_PI / 4.0;
}

void main() {
    IrradianceReduceRoot root = IrradianceReduceRoot(pc.root_gpu);
    uint lane = gl_LocalInvocationIndex;
    for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
        vec3 sum = vec3(0.0);
        for (uint partial = lane; partial < root.partial_count;
            partial += ENVIRONMENT_SH_GROUP_SIZE) {
            sum += IrradianceReadonlyArray(root.partials).values[partial]
                .coefficients[coefficient].rgb;
        }
        coefficient_sums[coefficient][lane] = sum;
    }
    barrier();

    for (uint width = ENVIRONMENT_SH_GROUP_SIZE / 2u; width > 0u; width >>= 1u) {
        if (lane < width) {
            for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
                coefficient_sums[coefficient][lane]
                    += coefficient_sums[coefficient][lane + width];
            }
        }
        barrier();
    }

    if (lane == 0u) {
        for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
            IrradianceWriteonly(root.output_coefficients).value.coefficients[coefficient]
                = vec4(coefficient_sums[coefficient][0]
                    * environment_cosine_factor(coefficient), 0.0);
        }
    }
}
