module c3d::physics::fracture;

import std::math;

const uint SURFACE_DOUBLE_FRACTION_BITS @local = 52;
const ulong SURFACE_DOUBLE_EXPONENT_MASK @local = 0x7ff;
const ulong SURFACE_DOUBLE_FRACTION_MASK @local = 0xfffffffffffff;
const int SURFACE_DOUBLE_EXPONENT_BIAS @local = 1023;
const int SURFACE_DOUBLE_UNIT_EXPONENT @local = -1074;

fn double decoded_surface_float(float value) @private {
    // Bit decoding preserves subnormal inputs when floating-point denormals are flushed.
    uint bits = bitcast(value, uint);
    uint exponent = (bits >> FLOAT_FRACTION_BITS) & FLOAT_EXPONENT_MASK;
    uint significand = bits & FLOAT_FRACTION_MASK;
    if (exponent) significand |= (uint)1 << FLOAT_FRACTION_BITS;
    double magnitude = math::scalbn((double)significand, exponent ? (int)exponent - FLOAT_EXPONENT_BIAS - (int)FLOAT_FRACTION_BITS : FLOAT_UNIT_EXPONENT);
    return (bits >> FLOAT_SIGN_BIT) ? -magnitude : magnitude;
}

fn double[<3>] decoded_surface_vector(Vec3 value) @private {
    return { decoded_surface_float(value.x), decoded_surface_float(value.y), decoded_surface_float(value.z) };
}

fn float? rounded_surface_float(ExactScratch* scratch, double value) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    ulong bits = bitcast(value, ulong);
    ulong exponent = (bits >> SURFACE_DOUBLE_FRACTION_BITS) & SURFACE_DOUBLE_EXPONENT_MASK;
    ulong significand = bits & SURFACE_DOUBLE_FRACTION_MASK;
    if (exponent) significand |= (ulong)1 << SURFACE_DOUBLE_FRACTION_BITS;
    WideInteger* numerator = scratch.take()!;
    WideInteger* denominator = scratch.take()!;
    set_integer(numerator, (int128)significand);
    numerator.negative = (bits & DOUBLE_SIGN_MASK) != 0;
    set_integer(denominator, 1);
    return round_float_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        unit_exponent: exponent ? (int)exponent - SURFACE_DOUBLE_EXPONENT_BIAS - (int)SURFACE_DOUBLE_FRACTION_BITS : SURFACE_DOUBLE_UNIT_EXPONENT,
    );
}

fn Vec3? rounded_surface_direction(ExactScratch* scratch, double[<3>] value) @private {
    Vec3 result;
    for (uint axis = 0; axis < SPACE_AXES; axis++) result[axis] = rounded_surface_float(scratch, value[axis])!;
    return result;
}

fn double[<3>] normalized_surface_vector(double[<3>] value) @private {
    double largest = math::max(math::abs(value.x), math::max(math::abs(value.y), math::abs(value.z)));
    if (largest == 0) return {};
    value /= largest;
    return value / math::sqrt(value.dot(value));
}

fn double[<3>] canonical_surface_normal(ExactPlane* plane) @private {
    uint scale;
    for (uint axis = 0; axis < SPACE_AXES; axis++) scale = math::max(scale, integer_bits(plane.coefficients[axis].view()));
    double[<3>] direction;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        foreach (uint index, limb : plane.coefficients[axis].view().limbs) {
            direction[axis] += math::scalbn((double)limb, (int)(index * INTEGER_LIMB_BITS) - (int)scale);
        }
        if (plane.coefficients[axis].negative) direction[axis] = -direction[axis];
    }
    return normalized_surface_vector(direction);
}
