#ifndef C3D_IRRADIANCE_GLSL
#define C3D_IRRADIANCE_GLSL

#include "buffer_reference.glsl"

GPU_DECLARE_READONLY_REF(IrradianceReadonly, IrradianceGpu);
GPU_DECLARE_WRITEONLY_REF(IrradianceWriteonly, IrradianceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(IrradianceReadonlyArray, IrradianceGpu);
GPU_DECLARE_WRITEONLY_ARRAY_REF(IrradianceWriteonlyArray, IrradianceGpu);

float environment_sh_basis(uint coefficient, vec3 direction) {
    switch (coefficient) {
        case 0u: return 0.2820947918;
        case 1u: return 0.4886025119 * direction.y;
        case 2u: return 0.4886025119 * direction.z;
        case 3u: return 0.4886025119 * direction.x;
        case 4u: return 1.0925484306 * direction.x * direction.y;
        case 5u: return 1.0925484306 * direction.y * direction.z;
        case 6u: return 0.3153915653 * (3.0 * direction.z * direction.z - 1.0);
        case 7u: return 1.0925484306 * direction.x * direction.z;
        case 8u: return 0.5462742153 * (direction.x * direction.x - direction.y * direction.y);
    }
}

vec3 environment_irradiance(uint64_t address, vec3 direction) {
    IrradianceGpu irradiance = IrradianceReadonly(address).value;
    vec3 result = vec3(0.0);
    for (uint coefficient = 0u; coefficient < 9u; coefficient++) {
        result += irradiance.coefficients[coefficient].rgb
            * environment_sh_basis(coefficient, direction);
    }
    // Coefficients include cosine convolution, so evaluation yields E rather than E/pi.
    return max(result, vec3(0.0));
}

#endif
