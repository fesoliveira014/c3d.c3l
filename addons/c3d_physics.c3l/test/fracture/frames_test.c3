module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_frames_raw_and_grid_positions_use_exact_affine_conversion() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    Vec3[3] positions = {
        { 0.1, -0.7, 1.3 }, { -float::max, float::max, 0 },
        { bitcast((uint)1, float), -bitcast((uint)3, float), bitcast((uint)0x800000, float) },
    };
    foreach (position : positions) {
        ExactPlane[3] planes;
        PlaneTriple point = frame_float_point(scratch.exact, &planes, position);
        scratch.exact.peak = 0;
        Vec3 rounded = rounded_source_position(scratch.exact, point)!!;
        assert_float_bits(rounded, position);
        check_frame_point_error(
            scratch: scratch.exact,
            vertex: point,
            grid: null,
            origin: {},
            local: rounded,
            resolution: bitcast((uint)1, float),
        )!!;
        assert(scratch.exact.count == 0 && scratch.exact.peak <= FRAME_CONVERSION_TEMPORARIES);
    }
    ExactPlane[3] planes;
    PlaneTriple point = frame_ratio_point(
        scratch: scratch.exact,
        planes: &planes,
        numerators: { 1, -2, 5 },
        denominator: 3,
    );
    QuantizationGrid grid = { .anchor = { 0.125, -0.25, 0.5 }, .center = { 2, -3, 1 }, .step_exponent = -2 };
    Vec3 rounded = rounded_source_position(scratch.exact, point, &grid)!!;
    assert_float_bits(
        first: rounded,
        second: { bitcast((uint)0x3f355555, float), bitcast((uint)0xbf955555, float), bitcast((uint)0x3f955555, float) },
    );
    check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: &grid,
        origin: {},
        local: rounded,
        resolution: 0.000001,
    )!!;
    assert(@catch(check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: &grid,
        origin: {},
        local: rounded,
        resolution: 0.000000001,
    )) == NUMERICAL_FAILURE);
    assert(scratch.exact.count == 0);
}

fn void test_frames_subnormal_grid_ties_and_near_ties_round_once() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    float minimum = bitcast((uint)1, float);
    QuantizationGrid grid = { .anchor = { minimum, minimum, minimum }, .step_exponent = -153 };
    for (int128 numerator = 23; numerator <= 25; numerator++) {
        ExactPlane[3] planes;
        PlaneTriple point = frame_ratio_point(
            scratch: scratch.exact,
            planes: &planes,
            numerators: { numerator, numerator, numerator },
            denominator: 3,
        );
        Vec3 rounded = rounded_source_position(scratch.exact, point, &grid)!!;
        uint expected = numerator == 23 ? 1 : 2;
        for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(rounded[axis], uint) == expected);
        check_frame_point_error(
            scratch: scratch.exact,
            vertex: point,
            grid: &grid,
            origin: {},
            local: rounded,
            resolution: minimum,
        )!!;
    }
    ExactPlane[3] planes;
    PlaneTriple point = frame_ratio_point(
        scratch: scratch.exact,
        planes: &planes,
        numerators: { 8, 8, 8 },
        denominator: 1,
    );
    grid.anchor = {};
    Vec3 rounded = rounded_source_position(scratch.exact, point, &grid)!!;
    assert_float_bits(rounded, {});
    check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: &grid,
        origin: {},
        local: rounded,
        resolution: minimum,
    )!!;
}

fn void test_frames_centroid_local_seams_check_exact_resolution_boundaries() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ExactPlane[3] planes;
    Vec3 shared = { 0.1, 0, 0 };
    PlaneTriple point = frame_float_point(scratch.exact, &planes, shared);
    Vec3 first_origin = { bitcast((uint)0xbe999999, float), 0, 0 };
    Vec3 second_origin = { bitcast((uint)0x3f333333, float), 0, 0 };
    Vec3 first = rounded_local_position(scratch.exact, shared, first_origin)!!;
    Vec3 second = rounded_local_position(scratch.exact, shared, second_origin)!!;
    assert_float_bits(first, { bitcast((uint)0x3ecccccc, float), 0, 0 });
    assert_float_bits(second, { bitcast((uint)0xbf199999, float), 0, 0 });
    float resolution = bitcast((uint)0x33000000, float);
    check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: null,
        origin: first_origin,
        local: first,
        resolution: resolution,
    )!!;
    check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: null,
        origin: second_origin,
        local: second,
        resolution: resolution,
    )!!;
    check_shared_point_error(
        scratch: scratch.exact,
        first_origin: first_origin,
        first_local: first,
        second_origin: second_origin,
        second_local: second,
        resolution: resolution,
    )!!;
    assert(@catch(check_shared_point_error(
        scratch: scratch.exact,
        first_origin: first_origin,
        first_local: first,
        second_origin: second_origin,
        second_local: second,
        resolution: bitcast((uint)0x32ffffff, float),
    )) == NUMERICAL_FAILURE);
    check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: null,
        origin: second_origin,
        local: second,
        resolution: bitcast((uint)0x32c00000, float),
    )!!;
    assert(@catch(check_frame_point_error(
        scratch: scratch.exact,
        vertex: point,
        grid: null,
        origin: second_origin,
        local: second,
        resolution: bitcast((uint)0x32bfffff, float),
    )) == NUMERICAL_FAILURE);
    check_shared_point_error(
        scratch: scratch.exact,
        first_origin: {},
        first_local: {},
        second_origin: {},
        second_local: { 1, 1, 0 },
        resolution: 1.5,
    )!!;
    assert(@catch(check_shared_point_error(
        scratch: scratch.exact,
        first_origin: {},
        first_local: {},
        second_origin: {},
        second_local: { 1, 1, 0 },
        resolution: 1.25,
    )) == NUMERICAL_FAILURE);
    assert(scratch.exact.count == 0);
}

fn void test_frames_volume_bound_includes_first_second_and_third_order_terms() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
    SolidSurface surface = partition_surface(&scratch, &fixture, false);
    scratch.exact.peak = 0;
    PlaneInteger bound = float_rounding_volume_bound(&surface, 0.125)!!;
    assert(scratch.exact.peak <= ROUNDING_VOLUME_TEMPORARIES && scratch.exact.count == 0);
    WideInteger* expected = scratch.exact.take()!!;
    WideInteger* scaled = scratch.exact.take()!!;
    integer_from_float(expected, 21.46875);
    shift_integer(scaled, expected.view(), 298)!!;
    assert(compare_integers(bound.view(), scaled.view()) == 0);
    scratch.exact.count = 0;
    foreach (&point : fixture.positions[:fixture.vertex_count]) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) (*point)[axis] = (*point)[axis] < 0 ? -float::max : float::max;
    }
    surface = partition_surface(&scratch, &fixture, false);
    bound = float_rounding_volume_bound(&surface, float::max)!!;
    assert(integer_bits(bound.view()) <= ROUNDING_VOLUME_BITS && bound.used != 0 && scratch.exact.count == 0);
}

fn void test_frames_exact_volume_changes_stay_inside_coordinate_error_bound() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) for (uint variant = 0; variant < 8; variant++) {
        ContainmentFixture original;
        ContainmentFixture rounded;
        partition_fixture(&original, shape);
        partition_fixture(&rounded, shape);
        float resolution = 0.125;
        foreach (uint index, &point : rounded.positions[:rounded.vertex_count]) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                int direction = (int)((index * 7 + axis * 13 + variant * 5) % 3) - 1;
                (*point)[axis] += (float)direction * resolution * 0.5f;
            }
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface first = partition_surface(&scratch, &original, false);
        SolidSurface second = partition_surface(&scratch, &rounded, false);
        PlaneInteger first_volume = frame_surface_volume(&first);
        PlaneInteger second_volume = frame_surface_volume(&second);
        PlaneInteger bound = float_rounding_volume_bound(&second, resolution)!!;
        WideInteger* difference = scratch.exact.take()!!;
        add_integer(difference, first_volume.view(), negate_integer(second_volume.view()))!!;
        assert(compare_magnitude(difference.view(), bound.view()) <= 0);
        scratch.exact.count = 0;
    }
}

fn void test_frames_arithmetic_exhaustion_restores_caller_values() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ExactPlane[3] planes;
    Vec3 position = { 0.1, -0.7, 1.3 };
    PlaneTriple point = frame_float_point(scratch.exact, &planes, position);
    uint held = EXACT_TEMPORARIES - FRAME_CONVERSION_TEMPORARIES + 1;
    for (uint index = 0; index < held; index++) set_integer(scratch.exact.take()!!, (int128)index + 1);
    assert(@catch(rounded_source_position(scratch.exact, point)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.exact.count == held);
    for (uint index = 0; index < held; index++) assert(scratch.exact.values[index].limbs[0] == (ulong)index + 1);
    scratch.exact.count = 0;
    assert_float_bits(rounded_source_position(scratch.exact, point)!!, position);
    Vec3 zero = rounded_local_position(scratch.exact, position, position)!!;
    assert_float_bits(zero, {});
    assert(scratch.exact.count == 0);
}

fn PlaneTriple frame_float_point(ExactScratch* scratch, ExactPlane[3]* planes, Vec3 position) @local {
    PlaneTriple result;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint bits = bitcast(position[axis], uint);
        long key = bits & ~((uint)1 << FLOAT_SIGN_BIT);
        if (bits >> FLOAT_SIGN_BIT) key = -key;
        bounds_axis_plane(
            scratch: scratch,
            plane: &(*planes)[axis],
            axis: axis,
            bound: key,
            quantized: false,
        )!!;
        result[axis] = &(*planes)[axis];
    }
    return result;
}

fn PlaneTriple frame_ratio_point(
    ExactScratch* scratch,
    ExactPlane[3]* planes,
    int128[3] numerators,
    int128 denominator,
) @local {
    PlaneTriple result;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        int128[4] coefficients;
        coefficients[axis] = denominator;
        coefficients[SPACE_AXES] = -numerators[axis];
        plane_from_integers(scratch, &(*planes)[axis], coefficients)!!;
        result[axis] = &(*planes)[axis];
    }
    return result;
}

fn void assert_float_bits(Vec3 first, Vec3 second) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(first[axis], uint) == bitcast(second[axis], uint));
}

fn PlaneInteger frame_surface_volume(SolidSurface* surface) @local {
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;
    WideInteger* sum = surface.exact.take()!!;
    WideInteger* term = surface.exact.take()!!;
    for (uint face = 0; face < surface.topology.shell_roots.len; face++) {
        triangle_volume(surface, term, face)!!;
        add_integer(sum, sum.view(), term.view())!!;
    }
    PlaneInteger result = { .used = sum.used, .negative = sum.negative };
    result.limbs[:sum.used] = sum.limbs[:sum.used];
    return result;
}
