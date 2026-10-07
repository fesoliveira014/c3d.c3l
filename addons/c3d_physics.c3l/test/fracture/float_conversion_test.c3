module c3d::physics::fracture;

import c3d;

fn void test_float_ratio_round_trips_finite_bit_patterns() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* numerator = scratch.take()!!;
    WideInteger* denominator = scratch.take()!!;
    set_integer(denominator, 1);
    uint seed = 0x913756ad;
    for (uint sample = 0; sample < 4096; sample++) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        uint bits = seed;
        if (((bits >> FLOAT_FRACTION_BITS) & FLOAT_EXPONENT_MASK) == FLOAT_EXPONENT_MASK) continue;
        integer_from_float(numerator, bitcast(bits, float));
        check_rounded_ratio(
            scratch: scratch,
            numerator: numerator.view(),
            denominator: denominator.view(),
            exponent: FLOAT_UNIT_EXPONENT,
            expected: bits,
        );
    }
    foreach (uint bits : { 0, 1, 0x007fffff, 0x00800000, 0x3f800000, 0x7f7fffff, 0x80000000, 0x80000001, 0xff7fffff }) {
        integer_from_float(numerator, bitcast(bits, float));
        numerator.negative = (bits >> FLOAT_SIGN_BIT) != 0;
        check_rounded_ratio(
            scratch: scratch,
            numerator: numerator.view(),
            denominator: denominator.view(),
            exponent: FLOAT_UNIT_EXPONENT,
            expected: bits,
        );
    }
    assert(scratch.count == 2 && scratch.peak <= 2 + FLOAT_ROUND_TEMPORARIES);
}

fn void test_float_ratio_midpoints_near_ties_and_normal_carries() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* numerator = scratch.take()!!;
    WideInteger* denominator = scratch.take()!!;
    WideInteger* base = scratch.take()!!;
    WideInteger* adjustment = scratch.take()!!;
    set_integer(adjustment, 1);
    shift_integer(denominator, adjustment.view(), 100)!!;
    foreach (int exponent : { -126, -1, 0, 127 }) {
        foreach (uint lower : { 0x800000, 0x800001, 0xfffffe, 0xffffff }) {
            set_integer(adjustment, (int128)(2 * lower + 1));
            shift_integer(base, adjustment.view(), 100)!!;
            for (int offset = -1; offset <= 1; offset++) {
                set_integer(adjustment, offset);
                add_integer(numerator, base.view(), adjustment.view())!!;
                uint rounded = lower + (offset > 0 || (offset == 0 && (lower & 1)) ? 1 : 0);
                int rounded_exponent = exponent;
                if (rounded == 0x1000000) {
                    rounded >>= 1;
                    rounded_exponent++;
                }
                for (uint negative = 0; negative < 2; negative++) {
                    numerator.negative = negative != 0;
                    if (rounded_exponent > 127) {
                        assert(@catch(round_float_ratio(
                            scratch: scratch,
                            numerator: numerator.view(),
                            denominator: denominator.view(),
                            unit_exponent: exponent - 24,
                        )) == NUMERICAL_FAILURE);
                        assert(scratch.count == 4);
                    } else {
                        uint bits = (negative << FLOAT_SIGN_BIT)
                          | ((uint)(rounded_exponent + FLOAT_EXPONENT_BIAS) << FLOAT_FRACTION_BITS)
                          | (rounded & FLOAT_FRACTION_MASK);
                        check_rounded_ratio(
                            scratch: scratch,
                            numerator: numerator.view(),
                            denominator: denominator.view(),
                            exponent: exponent - 24,
                            expected: bits,
                        );
                    }
                }
            }
        }
    }
}

fn void test_float_ratio_subnormal_ties_signed_underflow_and_exponent_extremes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* numerator = scratch.take()!!;
    WideInteger* denominator = scratch.take()!!;
    WideInteger* base = scratch.take()!!;
    WideInteger* adjustment = scratch.take()!!;
    set_integer(adjustment, 1);
    shift_integer(denominator, adjustment.view(), 100)!!;
    foreach (uint lower : { 0, 1, 2, 0x7ffffe, 0x7fffff }) {
        set_integer(adjustment, (int128)(2 * lower + 1));
        shift_integer(base, adjustment.view(), 100)!!;
        for (int offset = -1; offset <= 1; offset++) {
            set_integer(adjustment, offset);
            add_integer(numerator, base.view(), adjustment.view())!!;
            uint rounded = lower + (offset > 0 || (offset == 0 && (lower & 1)) ? 1 : 0);
            for (uint negative = 0; negative < 2; negative++) {
                numerator.negative = negative != 0;
                check_rounded_ratio(
                    scratch: scratch,
                    numerator: numerator.view(),
                    denominator: denominator.view(),
                    exponent: -150,
                    expected: (negative << FLOAT_SIGN_BIT) | rounded,
                );
            }
        }
    }
    set_integer(numerator, -1);
    set_integer(denominator, 1);
    check_rounded_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        exponent: int::min,
        expected: 0x80000000,
    );
    assert(@catch(round_float_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        unit_exponent: int::max,
    )) == NUMERICAL_FAILURE);
    assert(scratch.count == 4);
}

fn void test_float_ratio_full_width_division_avoids_intermediate_overflow() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* numerator = scratch.take()!!;
    WideInteger* denominator = scratch.take()!!;
    WideInteger* one = scratch.take()!!;
    set_integer(one, 1);
    shift_integer(denominator, one.view(), EXACT_LIMBS * INTEGER_LIMB_BITS - 1)!!;
    add_integer(numerator, denominator.view(), one.view())!!;
    check_rounded_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        exponent: 0,
        expected: 0x3f800000,
    );
    copy_integer(numerator, denominator.view());
    denominator.limbs[..] = ulong::max;
    check_rounded_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        exponent: 0,
        expected: 0x3f000000,
    );
    check_rounded_ratio(
        scratch: scratch,
        numerator: one.view(),
        denominator: denominator.view(),
        exponent: (int)(EXACT_LIMBS * INTEGER_LIMB_BITS),
        expected: 0x3f800000,
    );
    check_rounded_ratio(
        scratch: scratch,
        numerator: denominator.view(),
        denominator: one.view(),
        exponent: -(int)(EXACT_LIMBS * INTEGER_LIMB_BITS),
        expected: 0x3f800000,
    );
    assert(scratch.peak == 3 + FLOAT_ROUND_TEMPORARIES);
}

fn void test_float_ratio_capacity_failure_restores_held_temporaries() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* numerator = scratch.take()!!;
    WideInteger* denominator = scratch.take()!!;
    set_integer(numerator, 1);
    set_integer(denominator, 3);
    for (uint available = 0; available < FLOAT_ROUND_TEMPORARIES; available++) {
        scratch.count = EXACT_TEMPORARIES - available;
        uint held = scratch.count;
        assert(@catch(round_float_ratio(
            scratch: scratch,
            numerator: numerator.view(),
            denominator: denominator.view(),
            unit_exponent: 0,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.count == held && numerator.limbs[0] == 1 && denominator.limbs[0] == 3);
    }
    scratch.count = EXACT_TEMPORARIES - FLOAT_ROUND_TEMPORARIES;
    check_rounded_ratio(
        scratch: scratch,
        numerator: numerator.view(),
        denominator: denominator.view(),
        exponent: 0,
        expected: 0x3eaaaaab,
    );
}

fn void check_rounded_ratio(
    ExactScratch* scratch,
    IntegerView numerator,
    IntegerView denominator,
    int exponent,
    uint expected,
) @local {
    uint saved = scratch.count;
    float result = round_float_ratio(
        scratch: scratch,
        numerator: numerator,
        denominator: denominator,
        unit_exponent: exponent,
    )!!;
    assert(bitcast(result, uint) == expected);
    assert(scratch.count == saved);
}
