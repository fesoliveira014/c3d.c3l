module c3d::physics::fracture;

import c3d;
import std::math;

struct WitnessReference @local {
    ExactPlane[SPACE_AXES] planes;
}

struct WitnessCase @local {
    Vec3 point;
    float resolution;
    bool expected;
    uint peak;
}

fn void test_collision_witness_points_edges_faces_and_inside_have_exact_distance_bounds() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture box;
    append_box_fixture(&box, {}, { 1, 1, 1 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    CollisionHullSurface hull = build_collision_hull(&scratch, box.mesh.geometry.positions)!!;
    Vec3[8] saved_points;
    uint[36] saved_indices;
    saved_points[..] = hull.points[..];
    saved_indices[..] = hull.indices[..];
    usz saved = scratch.used;
    float smallest = bitcast((uint)1, float);

    WitnessCase[8] cases = {
        { .point = {}, .resolution = smallest, .expected = true, .peak = 8 },
        { .point = { 0.5f, 0.5f, 0.5f }, .resolution = smallest, .expected = true, .peak = 21 },
        { .point = { 0, 0.25f, 0.5f }, .resolution = smallest, .expected = true, .peak = 24 },
        { .point = { -0.125f, 0, 0.5f }, .resolution = 0.125f, .expected = true, .peak = 16 },
        { .point = { -0.125f, 0.25f, 0.5f }, .resolution = 0.125f, .expected = true, .peak = 24 },
        { .point = { -0.125f, -0.125f, 0.5f }, .resolution = 0.125f, .expected = false },
        { .point = { -0.25f, 0, 1.5f }, .resolution = 0.25f, .expected = false },
        { .point = { -0.125f, 0.25f, 0.5f }, .resolution = bitcast((uint)0x3dffffff, float), .expected = false },
    };
    foreach (current : cases) {
        WitnessReference reference;
        PlaneTriple vertex = witness_reference(&scratch, &reference, current.point);
        ExactPlane[SPACE_AXES] original_planes = reference.planes;
        scratch.exact.peak = 0;

        assert(collision_vertex_has_witness(
            scratch: scratch.exact,
            vertex: vertex,
            hull: &hull,
            resolution: current.resolution,
        )!! == current.expected);
        if (current.peak) assert(scratch.exact.peak == current.peak);
        assert(scratch.exact.count == 0 && scratch.used == saved);
        assert(scratch.exact.peak <= COLLISION_WITNESS_TEMPORARIES);
        assert(mem::equals(&reference.planes, &original_planes, ExactPlane[SPACE_AXES]::size));
    }
    assert(mem::equals(hull.points.ptr, &saved_points[0], Vec3[8]::size));
    assert(mem::equals(hull.indices.ptr, &saved_indices[0], uint[36]::size));
}

fn void test_collision_witness_eleven_ulp_generated_point_matches_retained_source_vertex() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3 original = {
        bitcast((uint)1029633514, float), bitcast((uint)3167291705, float), bitcast((uint)1065323282, float),
    };
    Vec3 generated = {
        bitcast((uint)1029633525, float), bitcast((uint)3167291703, float), bitcast((uint)1065323282, float),
    };
    assert(bitcast(generated.x, uint) - bitcast(original.x, uint) == 11);
    assert(bitcast(original.y, uint) - bitcast(generated.y, uint) == 2);
    Vec3[4] points = { original, { -1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } };
    SolidScratch scratch = begin_solid_scratch(&workspace);
    CollisionHullSurface hull = build_collision_hull(&scratch, points[..])!!;
    WitnessReference reference;
    PlaneTriple vertex = witness_reference(&scratch, &reference, generated);

    assert(collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: vertex,
        hull: &hull,
        resolution: 0x1p-24f,
    )!!);
    assert(!collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: vertex,
        hull: &hull,
        resolution: 0x1p-25f,
    )!!);
    assert(scratch.exact.count == 0);
}

fn void test_collision_witness_rational_face_projection_compares_unrounded_reference() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture box;
    append_box_fixture(&box, {}, { 1, 1, 1 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    CollisionHullSurface hull = build_collision_hull(&scratch, box.mesh.geometry.positions)!!;
    WitnessReference reference;
    PlaneTriple vertex = witness_reference(&scratch, &reference, { 0, 0.25f, 0.5f });
    plane_from_float(scratch.exact, &reference.planes[0], {
        { 0, 0.5f, 0 }, { 4, 3.5f, 0 }, { 0, 0.5f, 1 },
    })!!;
    scratch.exact.peak = 0;

    assert(collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: vertex,
        hull: &hull,
        resolution: bitcast((uint)0x3eaaaaab, float),
    )!!);
    assert(scratch.exact.peak == COLLISION_WITNESS_TEMPORARIES);
    assert(!collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: vertex,
        hull: &hull,
        resolution: bitcast((uint)0x3eaaaaaa, float),
    )!!);
    assert(scratch.exact.count == 0);
}

fn void test_collision_witness_checks_final_hull_without_accumulating_omission_distance() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture box;
    append_box_fixture(&box, {}, { 1, 1, 1 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    CollisionHullSurface hull = build_collision_hull(&scratch, box.mesh.geometry.positions)!!;
    WitnessReference near_reference;
    WitnessReference far_reference;
    PlaneTriple near_vertex = witness_reference(&scratch, &near_reference, { -0.0625f, 0.25f, 0.5f });
    PlaneTriple far_vertex = witness_reference(&scratch, &far_reference, { -0.125f, 0.25f, 0.5f });

    assert(collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: near_vertex,
        hull: &hull,
        resolution: 0.0625f,
    )!!);
    assert(!collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: far_vertex,
        hull: &hull,
        resolution: 0.0625f,
    )!!);
    assert(scratch.exact.count == 0);
}

fn void test_collision_witness_subnormal_and_largest_float_distances_remain_exact() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    float smallest = bitcast((uint)1, float);

    for (uint variant = 0; variant < 2; variant++) {
        ContainmentFixture box;
        float maximum = variant ? float::max : bitcast((uint)4, float);
        Vec3 lower = variant ? (Vec3){ -maximum, -maximum, -maximum } : (Vec3){};
        append_box_fixture(&box, lower, { maximum, maximum, maximum });
        SolidScratch scratch = begin_solid_scratch(&workspace);
        CollisionHullSurface hull = build_collision_hull(&scratch, box.mesh.geometry.positions)!!;
        WitnessReference reference;
        Vec3 point = variant ? (Vec3){ maximum, 0, 0 }
            : (Vec3){ bitcast((uint)0x80000001, float), smallest, bitcast((uint)2, float) };
        PlaneTriple vertex = witness_reference(&scratch, &reference, point);
        if (variant) witness_axis_unit_offset(
            scratch: scratch.exact,
            plane: &reference.planes[0],
            coordinate: maximum,
            offset: 1,
        );

        scratch.exact.peak = 0;
        assert(collision_vertex_has_witness(
            scratch: scratch.exact,
            vertex: vertex,
            hull: &hull,
            resolution: smallest,
        )!!);
        assert(scratch.exact.peak <= COLLISION_WITNESS_TEMPORARIES);
        if (variant) {
            witness_axis_unit_offset(
                scratch: scratch.exact,
                plane: &reference.planes[0],
                coordinate: maximum,
                offset: 2,
            );
        } else {
            point.x = bitcast((uint)0x80000002, float);
            vertex = witness_reference(&scratch, &reference, point);
        }
        assert(!collision_vertex_has_witness(
            scratch: scratch.exact,
            vertex: vertex,
            hull: &hull,
            resolution: smallest,
        )!!);
        assert(scratch.exact.count == 0);
    }
}

fn void test_collision_witness_arithmetic_exhaustion_preserves_held_values_and_allows_reuse() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture box;
    append_box_fixture(&box, {}, { 1, 1, 1 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    CollisionHullSurface hull = build_collision_hull(&scratch, box.mesh.geometry.positions)!!;
    WitnessReference reference;
    PlaneTriple vertex = witness_reference(&scratch, &reference, { -0.125f, 0.25f, 0.5f });
    usz saved = scratch.used;

    for (uint held = 1; held <= EXACT_TEMPORARIES; held++) {
        scratch.exact.count = held;
        for (uint index = 0; index < held; index++) set_integer(&scratch.exact.values[index], (int128)index + 71);
        assert(@catch(collision_vertex_has_witness(
            scratch: scratch.exact,
            vertex: vertex,
            hull: &hull,
            resolution: 0.125f,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.exact.count == held && !scratch.exact.measurement_depth && scratch.used == saved);
        for (uint index = 0; index < held; index++) {
            assert(scratch.exact.values[index].used == 1 && !scratch.exact.values[index].negative);
            assert(scratch.exact.values[index].limbs[0] == (ulong)index + 71);
        }
    }

    scratch.exact.count = 0;
    scratch.exact.peak = 0;
    assert(collision_vertex_has_witness(
        scratch: scratch.exact,
        vertex: vertex,
        hull: &hull,
        resolution: 0.125f,
    )!!);
    assert(scratch.exact.count == 0 && scratch.exact.peak == COLLISION_WITNESS_TEMPORARIES);
    assert(scratch.used == saved && !scratch.exact.measurement_depth);
}

fn PlaneTriple witness_reference(SolidScratch* scratch, WitnessReference* reference, Vec3 position) @local {
    uint saved = scratch.exact.count;
    defer scratch.exact.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = scratch.exact.take()!!;

    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        foreach (coefficient : coefficients) set_integer(coefficient, 0);
        set_integer(coefficients[axis], 1);
        integer_from_float(coefficients[SPACE_AXES], position[axis]);
        if (coefficients[SPACE_AXES].used) coefficients[SPACE_AXES].negative = !coefficients[SPACE_AXES].negative;
        normalize_plane(scratch.exact, &reference.planes[axis], coefficients)!!;
    }
    return { &reference.planes[0], &reference.planes[1], &reference.planes[2] };
}

fn void witness_axis_unit_offset(
    ExactScratch* scratch,
    ExactPlane* plane,
    float coordinate,
    uint offset,
) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* value = scratch.take()!!;
    WideInteger* amount = scratch.take()!!;
    integer_from_float(value, coordinate);
    set_integer(amount, offset);
    add_integer(value, value.view(), amount.view())!!;

    PlaneInteger* target = &plane.coefficients[SPACE_AXES];
    target.used = value.used;
    target.negative = true;
    target.limbs[:target.used] = value.limbs[:value.used];
}
