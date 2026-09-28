module c3d::maths;

import std::math;

const float GOLDEN_RATIO_CONJUGATE @local = 0.618034f; // mirrored as GOLDEN_RATIO_CONJUGATE in sampling.glsl

<*
 Radical inverse of the index in the base; a low-discrepancy sequence in [0, 1).
 @require base >= 2
 @pure
*>
fn float halton(uint index, uint base) {
    float fraction = 1;
    float result = 0;
    while (index > 0) {
        fraction /= (float)base;
        result += fraction * (float)(index % base);
        index /= base;
    }
    return result;
}

<*
 Unit direction of an index in an evenly spread set of count; mirrored in sampling.glsl.
 @require index < count
 @pure
*>
fn Vec3 spherical_fibonacci(uint index, uint count) {
    float z = 1 - (2 * (float)index + 1) / (float)count;
    float radius = math::sqrt(math::max(1 - z * z, 0.0f));
    float turns = (float)index * GOLDEN_RATIO_CONJUGATE;
    float phi = 2 * (float)math::PI * (turns - math::floor(turns));
    return { radius * math::cos(phi), radius * math::sin(phi), z };
}

<*
 Uniformly distributed unit quaternion from three numbers in [0, 1).
 @pure
*>
fn Quat random_rotation(Vec3 uniform) {
    float first = math::sqrt(1 - uniform.x);
    float second = math::sqrt(uniform.x);
    float yaw = 2 * (float)math::PI * uniform.y;
    float pitch = 2 * (float)math::PI * uniform.z;
    return { .v = {
        first * math::sin(yaw),
        first * math::cos(yaw),
        second * math::sin(pitch),
        second * math::cos(pitch),
    } };
}
