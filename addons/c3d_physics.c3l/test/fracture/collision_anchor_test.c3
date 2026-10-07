module c3d::physics::fracture;

import c3d;
import std::math;

const uint ANCHOR_WIDE_TEMPORARIES @local = 19;

fn void test_collision_anchor_rotated_boxes_and_material_chunks_have_strict_interior_centroids() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 4; shape++) {
        for (uint rotation = 0; rotation < 12; rotation++) {
            ContainmentFixture fixture;
            ContainmentFixture chunk;
            if (!shape) {
                append_box_fixture(&fixture, { -0.5f, -0.5f, -0.5f }, { 0.5f, 0.5f, 0.5f });
                append_box_fixture(&chunk, { -0.5f, -0.5f, -0.5f }, { 0.5f, 0.5f, 0.5f });
            } else if (shape == 1) {
                partition_fixture(&fixture, 4);
                append_box_fixture(&chunk, { 0.2f, 0.2f, 0.2f }, { 0.8f, 1.8f, 0.8f });
            } else if (shape == 2) {
                partition_fixture(&fixture, 1);
                append_box_fixture(&chunk, { 1.5f, -0.5f, -0.5f }, { 2.5f, 0.5f, 0.5f });
            } else {
                partition_fixture(&fixture, 2);
                append_box_fixture(&chunk, { -0.5f, -0.5f, -0.5f }, { 0.5f, 0.5f, 0.5f });
            }
            foreach (&point : fixture.mesh.geometry.positions) *point = rotate_anchor_point(*point, rotation);
            foreach (&point : chunk.mesh.geometry.positions) *point = rotate_anchor_point(*point, rotation);

            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidSurface original = anchor_raw_surface(&scratch, fixture.mesh);
            SourceConstructions source = build_source_constructions(&scratch, &original)!!;
            SolidSurface hull = anchor_convex_surface(&scratch, chunk.mesh.geometry.positions);
            scratch.exact.peak = 0;
            usz saved = scratch.used;
            Vec3 anchor = collision_hull_anchor(
                hull: &hull,
                original: &original,
                source: &source,
                resolution: 0.0001f,
            )!!;
            assert(scratch.used == saved && scratch.exact.count == 0 && scratch.exact.peak <= ANCHOR_WIDE_TEMPORARIES);

            if (!shape || shape == 3) assert(anchor == (Vec3){});
            assert_anchor_inside(&hull, anchor);

            Vec3 repeated = collision_hull_anchor(
                hull: &hull,
                original: &original,
                source: &source,
                resolution: 0.0001f,
            )!!;
            for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(anchor[axis], uint) == bitcast(repeated[axis], uint));
        }
    }
}

fn void test_collision_anchor_rejects_centroids_inside_cavities_and_reflex_notches() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 3; shape++) {
        ContainmentFixture fixture;
        ContainmentFixture chunk;
        if (!shape) {
            partition_fixture(&fixture, 1);
            append_box_fixture(&chunk, { -0.5f, -0.5f, -0.5f }, { 0.5f, 0.5f, 0.5f });
        } else if (shape == 1) {
            partition_fixture(&fixture, 4);
            append_box_fixture(&chunk, { 1.2f, 1.2f, 0.2f }, { 1.8f, 1.8f, 0.8f });
        } else {
            partition_fixture(&fixture, 2);
            append_box_fixture(&chunk, { 1.25f, -0.25f, -0.25f }, { 1.75f, 0.25f, 0.25f });
        }

        SolidScratch scratch = begin_solid_scratch(&workspace);

        SolidSurface original = anchor_raw_surface(&scratch, fixture.mesh);
        SourceConstructions source = build_source_constructions(&scratch, &original)!!;
        SolidSurface hull = anchor_convex_surface(&scratch, chunk.mesh.geometry.positions);
        Vec3 centroid = rounded_surface_centroid(&hull, 0.0001f)!!;
        assert_anchor_inside(&hull, centroid);
        usz saved = scratch.used;
        assert(@catch(collision_hull_anchor(
            hull: &hull,
            original: &original,
            source: &source,
            resolution: 0.0001f,
        )) == NUMERICAL_FAILURE);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
}

fn void test_collision_anchor_raw_point_membership_handles_vertex_rays_and_nested_material() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 4; shape++) {
        ContainmentFixture fixture;

        Vec3[5] points;
        bool[5] expected;
        if (!shape) {
            append_octahedron_fixture(&fixture, {}, 2);
            points = { {}, { 0, 0, -1 }, { 0, 0, -3 }, { 3, 0, 0 }, { 0.5f, 0.5f, 0 } };
            expected = { true, true, false, false, true };
        } else if (shape == 1) {
            partition_fixture(&fixture, 1);
            points = { {}, { 2, 0, 0 }, { 0, 0, -2 }, { 0, 0, -4 }, { 0.5f, 0.5f, 0.5f } };
            expected = { false, true, true, false, false };
        } else if (shape == 2) {
            partition_fixture(&fixture, 2);
            points = { {}, { 1.5f, 0, 0 }, { 2.5f, 0, 0 }, { 0, 0, -4 }, { 0.5f, 0.5f, 0.5f } };
            expected = { true, false, true, false, true };
        } else {
            partition_fixture(&fixture, 4);
            points = { { 0.5f, 0.5f, 0.5f }, { 1.5f, 0.5f, 0.5f }, { 0.5f, 1.5f, 0.5f }, { 1.5f, 1.5f, 0.5f }, { 0.5f, 0.5f, -1 } };
            expected = { true, true, true, false, false };
        }

        SolidScratch scratch = begin_solid_scratch(&workspace);

        SolidSurface original = anchor_raw_surface(&scratch, fixture.mesh);
        SourceConstructions source = build_source_constructions(&scratch, &original)!!;
        usz saved = scratch.used;
        foreach (uint index, point : points) assert(raw_point_is_occupied(&original, &source, point)!! == expected[index]);
        assert(scratch.used == saved && scratch.exact.count == 0);
        for (uint face = 0; face < fixture.triangle_count / 2; face++) {
            uint other = fixture.triangle_count - 1 - face;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                uint prior = fixture.indices[face * TRIANGLE_CORNERS + corner];
                fixture.indices[face * TRIANGLE_CORNERS + corner] = fixture.indices[other * TRIANGLE_CORNERS + corner];
                fixture.indices[other * TRIANGLE_CORNERS + corner] = prior;
            }
        }
        original = anchor_raw_surface(&scratch, fixture.mesh);
        source = build_source_constructions(&scratch, &original)!!;
        foreach (uint index, point : points) assert(raw_point_is_occupied(&original, &source, point)!! == expected[index]);
    }
}

fn void test_collision_anchor_rejects_boundary_rounding_and_restores_arithmetic_after_faults() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture thin;
    append_box_fixture(&thin, { -1, -1, -1 }, { 1, 1, 1 });
    float lower = 0x1p100f;
    float upper = bitcast(bitcast(lower, uint) + 1, float);
    foreach (&point : thin.mesh.geometry.positions) point.x = point.x < 0 ? lower : upper;

    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface hull = anchor_raw_surface(&scratch, thin.mesh);
    SourceConstructions source = build_source_constructions(&scratch, &hull)!!;
    Vec3 rounded = rounded_surface_centroid(&hull, 0x1p78f)!!;
    assert(bitcast(rounded.x, uint) == bitcast(lower, uint));
    usz saved = scratch.used;
    assert(@catch(collision_hull_anchor(
        hull: &hull,
        original: &hull,
        source: &source,
        resolution: 0x1p78f,
    )) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0);
    ContainmentFixture ordinary;
    append_box_fixture(&ordinary, { -1, -1, -1 }, { 1, 1, 1 });
    hull = anchor_raw_surface(&scratch, ordinary.mesh);
    source = build_source_constructions(&scratch, &hull)!!;
    saved = scratch.used;

    scratch.exact.count = EXACT_TEMPORARIES;
    assert(@catch(collision_hull_anchor(
        hull: &hull,
        original: &hull,
        source: &source,
        resolution: 0.0001f,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.exact.count == EXACT_TEMPORARIES && !scratch.exact.measurement_depth);
    for (uint held = EXACT_TEMPORARIES - 4; held < EXACT_TEMPORARIES; held++) {
        scratch.exact.count = held;
        assert(@catch(raw_point_is_occupied(&hull, &source, {})) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.exact.count == held && !scratch.exact.measurement_depth && scratch.used == saved);
    }
    scratch.exact.count = 0;
    Vec3 anchor = collision_hull_anchor(
        hull: &hull,
        original: &hull,
        source: &source,
        resolution: 0.0001f,
    )!!;
    assert(anchor == (Vec3){} && scratch.used == saved && scratch.exact.count == 0);
}

fn SolidSurface anchor_raw_surface(SolidScratch* scratch, SolidMeshView mesh) @local {
    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: scratch,
        source: mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!!;
    return solid.surface;
}

fn SolidSurface anchor_convex_surface(SolidScratch* scratch, Vec3[] positions) @local {
    CollisionHullSurface hull = build_collision_hull(scratch, positions)!!;

    SolidMeshView mesh = collision_indexed_mesh(scratch, hull.points, hull.indices)!!;
    return anchor_raw_surface(scratch, mesh);
}

fn void assert_anchor_inside(SolidSurface* hull, Vec3 anchor) @local {
    foreach (uint face, unused : hull.topology.shell_roots) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(hull, face);
        assert(exact_float_orientation(hull.exact, {
            surface_position(hull, triangle[0]), surface_position(hull, triangle[1]),
            surface_position(hull, triangle[2]), anchor,
        })!! < 0);
    }
}

fn Vec3 rotate_anchor_point(Vec3 point, uint index) @local {
    double[SPACE_AXES] axis = { 1, 2.0 + index, 3 };
    double length = math::sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    foreach (&value : axis) *value /= length;

    double angle = 0.1 + 0.37 * index;
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    double dot;
    for (uint component = 0; component < SPACE_AXES; component++) dot += axis[component] * (double)point[component];

    Vec3 result;
    for (uint component = 0; component < SPACE_AXES; component++) {
        uint first = (component + 1) % SPACE_AXES;
        uint second = (component + 2) % SPACE_AXES;
        double cross = axis[first] * (double)point[second] - axis[second] * (double)point[first];
        result[component] = (float)((double)point[component] * cosine + cross * sine + axis[component] * dot * (1 - cosine));
    }

    return result;
}
