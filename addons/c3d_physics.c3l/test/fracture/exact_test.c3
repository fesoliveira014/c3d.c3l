module c3d::physics::fracture;

import c3d;
import std::math;

const uint SIGNED_SWEEP_COUNT @local = 512;
const uint HALF_EXACT_BITS @local = EXACT_LIMBS * INTEGER_LIMB_BITS / 2;
const usz SCRATCH_GUARD_BYTES @local = 32;

fn void test_fracture_workspace_bounds_one_allocation_and_failure_cleanup() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits limits = exact_limits();
    FractureWorkspace workspace = create_fracture_workspace(&tracker, limits)!!;
    assert(tracker.allocation_count() == 1 && tracker.total_allocation_count() == 1);
    assert(workspace.storage.len == MIN_FRACTURE_SCRATCH_BYTES);
    assert((uptr)workspace.storage.ptr % ExactScratch::alignment == 0);
    destroy_fracture_workspace(&workspace);
    assert(tracker.allocated() == 0 && workspace.storage.len == 0);
    limits.scratch_bytes--;
    assert(@catch(create_fracture_workspace(&tracker, limits)) == c3d::INVALID_ARGUMENT);
    limits.scratch_bytes = usz::max;
    assert(@catch(create_fracture_workspace(&tracker, limits)) == c3d::CAPACITY_EXCEEDED);
    limits = exact_limits();
    uint*[5] counts = { &limits.max_vertices, &limits.max_triangles, &limits.max_pieces, &limits.max_sites, &limits.max_hulls };
    foreach (count : counts) {
        uint saved = *count;
        *count = 0;
        assert(@catch(create_fracture_workspace(&tracker, limits)) == c3d::INVALID_ARGUMENT);
        *count = saved;
    }
    foreach (float resolution : { 0.0f, -1.0f, bitcast((uint)0x7f800000, float), bitcast((uint)0x7fc00000, float) }) {
        limits.resolution_m = resolution;
        assert(@catch(create_fracture_workspace(&tracker, limits)) == c3d::INVALID_ARGUMENT);
    }
    NullAllocator unavailable;
    assert(@catch(create_fracture_workspace(&unavailable, exact_limits())) == c3d::CAPACITY_EXCEEDED);
    assert(tracker.allocated() == 0 && tracker.total_allocation_count() == 1);
}

fn void test_exact_signed_operations_match_native_integer_arithmetic() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, exact_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* first = scratch.take()!!;
    WideInteger* second = scratch.take()!!;
    WideInteger* output = scratch.take()!!;
    WideInteger* quotient = scratch.take()!!;
    WideInteger* remainder = scratch.take()!!;
    ulong seed = 0xd9819af08241c373;
    for (uint sample = 0; sample < SIGNED_SWEEP_COUNT; sample++) {
        int128 left = signed_sample(&seed);
        int128 right = signed_sample(&seed);
        set_integer(first, left);
        set_integer(second, right);
        add_integer(output, first.view(), second.view())!!;
        assert_native_integer(output.view(), left + right);
        multiply_integer(output, first.view(), second.view())!!;
        assert_native_integer(output.view(), left * right);
        assert_native_integer(first.view(), left);
        assert_native_integer(second.view(), right);
        if (right) {
            divide_magnitude(
                scratch: scratch,
                quotient: quotient,
                remainder: remainder,
                numerator: first.view(),
                denominator: second.view(),
            )!!;
            int128 magnitude_left = left < 0 ? -left : left;
            int128 magnitude_right = right < 0 ? -right : right;
            assert_native_integer(quotient.view(), magnitude_left / magnitude_right);
            assert_native_integer(remainder.view(), magnitude_left % magnitude_right);
        }
        assert(scratch.count == 5);
    }
    foreach (int128 extreme : { int128::min, int128::max, (int128)ulong::max, 0 }) {
        set_integer(first, extreme);
        assert_native_integer(first.view(), extreme);
    }
    set_integer(first, int128::min);
    set_integer(second, int128::max);
    add_integer(output, first.view(), second.view())!!;
    assert_native_integer(output.view(), -1);
    assert(scratch.peak == 6);
}

fn void test_exact_full_width_products_division_and_overflow_recovery() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, exact_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* one = scratch.take()!!;
    WideInteger* power = scratch.take()!!;
    WideInteger* first = scratch.take()!!;
    WideInteger* second = scratch.take()!!;
    WideInteger* product = scratch.take()!!;
    WideInteger* quotient = scratch.take()!!;
    WideInteger* remainder = scratch.take()!!;
    set_integer(one, 1);
    shift_integer(power, one.view(), HALF_EXACT_BITS)!!;
    IntegerView minus_one = one.view();
    minus_one.negative = true;
    add_integer(first, power.view(), minus_one)!!;
    add_integer(second, power.view(), one.view())!!;
    multiply_integer(product, first.view(), second.view())!!;
    assert(product.used == EXACT_LIMBS && integer_bits(product.view()) == EXACT_LIMBS * INTEGER_LIMB_BITS);
    foreach (limb : product.view().limbs) assert(limb == ulong::max);
    divide_magnitude(
        scratch: scratch,
        quotient: quotient,
        remainder: remainder,
        numerator: product.view(),
        denominator: first.view(),
    )!!;
    assert(compare_magnitude(quotient.view(), second.view()) == 0 && remainder.used == 0);
    gcd_integer(
        scratch: scratch,
        output: quotient,
        first: product.view(),
        second: first.view(),
    )!!;
    assert(compare_magnitude(quotient.view(), first.view()) == 0);
    assert(@catch(add_integer(quotient, product.view(), one.view())) == NUMERICAL_FAILURE);
    assert(@catch(shift_integer(quotient, product.view(), 1)) == NUMERICAL_FAILURE);
    set_integer(one, 2);
    assert(@catch(multiply_integer(quotient, product.view(), one.view())) == NUMERICAL_FAILURE);
    set_integer(one, 0);
    multiply_integer(quotient, product.view(), one.view())!!;
    assert(quotient.used == 0 && !quotient.negative);
    set_integer(first, -123);
    set_integer(second, 456);
    add_integer(quotient, first.view(), second.view())!!;
    assert_native_integer(quotient.view(), 333);
    assert(scratch.count == 7 && scratch.peak <= EXACT_TEMPORARIES);
}

fn void test_exact_float_encoding_preserves_extremes_subnormals_and_cancellation() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, exact_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    WideInteger* positive = scratch.take()!!;
    WideInteger* negative = scratch.take()!!;
    WideInteger* output = scratch.take()!!;
    integer_from_float(positive, float::max);
    assert(integer_bits(positive.view()) == 277 && !positive.negative);
    assert(positive.limbs[3] == 0xe000000000000000 && positive.limbs[4] == 0x1fffff);
    integer_from_float(negative, -float::max);
    add_integer(output, positive.view(), negative.view())!!;
    assert(output.used == 0 && !output.negative);
    integer_from_float(negative, bitcast((uint)1, float));
    assert_native_integer(negative.view(), 1);
    add_integer(output, positive.view(), negative.view())!!;
    assert(output.limbs[0] == 1 && output.limbs[4] == positive.limbs[4]);
    integer_from_float(negative, bitcast((uint)0x80000001, float));
    assert_native_integer(negative.view(), -1);
    integer_from_float(output, bitcast((uint)0x80000000, float));
    assert(output.used == 0 && !output.negative);
    integer_from_float(output, 1.0f);
    assert(integer_bits(output.view()) == 150 && output.limbs[2] == ((ulong)1 << 21));
    integer_from_float(output, bitcast((uint)0x00800000, float));
    assert_native_integer(output.view(), (int128)1 << FLOAT_FRACTION_BITS);
}

fn void test_exact_workspaces_remain_independent_without_operation_allocations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureWorkspace first = create_fracture_workspace(&tracker, exact_limits())!!;
    FractureWorkspace second = create_fracture_workspace(&tracker, exact_limits())!!;
    ExactScratch* first_scratch = (ExactScratch*)first.storage.ptr;
    ExactScratch* second_scratch = (ExactScratch*)second.storage.ptr;
    WideInteger* first_value = first_scratch.take()!!;
    WideInteger* second_value = second_scratch.take()!!;
    set_integer(first_value, 67);
    set_integer(second_value, -89);
    WideInteger* product = first_scratch.take()!!;
    WideInteger* quotient = first_scratch.take()!!;
    WideInteger* remainder = first_scratch.take()!!;
    multiply_integer(product, first_value.view(), second_value.view())!!;
    divide_magnitude(
        scratch: first_scratch,
        quotient: quotient,
        remainder: remainder,
        numerator: product.view(),
        denominator: second_value.view(),
    )!!;
    assert_native_integer(quotient.view(), 67);
    assert(remainder.used == 0);
    assert_native_integer(first_value.view(), 67);
    assert_native_integer(second_value.view(), -89);
    destroy_fracture_workspace(&first);
    assert_native_integer(second_value.view(), -89);
    assert(tracker.total_allocation_count() == 2);
    destroy_fracture_workspace(&second);
    assert(tracker.allocated() == 0);
}

fn void test_exact_temporary_exhaustion_preserves_bounds_and_reuses_storage() @test {
    FractureLimits limits = exact_limits();
    limits.scratch_bytes += SCRATCH_GUARD_BYTES;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    char[] guard = workspace.storage[MIN_FRACTURE_SCRATCH_BYTES..];
    guard[..] = 0xa5;
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    for (uint index = 0; index < EXACT_TEMPORARIES; index++) scratch.take()!!;
    assert(@catch(scratch.take()) == c3d::CAPACITY_EXCEEDED);
    WideInteger* first = &scratch.values[0];
    WideInteger* second = &scratch.values[1];
    WideInteger* quotient = &scratch.values[2];
    WideInteger* remainder = &scratch.values[3];
    set_integer(first, 100);
    set_integer(second, 3);
    assert(@catch(divide_magnitude(
        scratch: scratch,
        quotient: quotient,
        remainder: remainder,
        numerator: first.view(),
        denominator: second.view(),
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.count == EXACT_TEMPORARIES && scratch.peak == EXACT_TEMPORARIES);
    foreach (byte : guard) assert(byte == 0xa5);
    scratch.count = 4;
    divide_magnitude(
        scratch: scratch,
        quotient: quotient,
        remainder: remainder,
        numerator: first.view(),
        denominator: second.view(),
    )!!;
    assert_native_integer(quotient.view(), 33);
    assert_native_integer(remainder.view(), 1);
    assert(scratch.count == 4);
}

fn FractureLimits exact_limits() @local {
    return {
        .scratch_bytes = MIN_FRACTURE_SCRATCH_BYTES,
        .max_vertices = 32,
        .max_triangles = 32,
        .max_pieces = 8,
        .max_sites = 8,
        .max_hulls = 8,
        .resolution_m = 0.0001f,
    };
}

fn int128 signed_sample(ulong* seed) @local {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    int128 value = (int128)(*seed >> 1);
    return (*seed & 1) ? -value : value;
}

fn void assert_native_integer(IntegerView value, int128 expected) @local {
    uint128 magnitude = expected < 0 ? (uint128)(-(expected + 1)) + 1 : (uint128)expected;
    uint count = (magnitude >> INTEGER_LIMB_BITS) ? 2 : magnitude ? 1 : 0;
    assert(value.limbs.len == count && value.negative == (expected < 0));
    if (count) assert(value.limbs[0] == (ulong)magnitude);
    if (count == 2) assert(value.limbs[1] == (ulong)(magnitude >> INTEGER_LIMB_BITS));
}
