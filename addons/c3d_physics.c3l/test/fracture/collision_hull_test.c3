module c3d::physics::fracture;

import c3d;
import std::math;

const uint HULL_WIDE_TEMPORARIES @local = 17;
const usz HULL_GRID_ADDITIONAL_BYTES @local = 14388;

fn void test_collision_hull_rotated_box_concave_and_nested_point_clouds() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    uint[4] shapes = { 0, 4, 1, 2 };
    foreach (shape : shapes) {
        for (uint rotation = 0; rotation < 12; rotation++) {
            ContainmentFixture fixture;
            partition_fixture(&fixture, shape);
            foreach (&point : fixture.mesh.geometry.positions) *point = rotate_hull_test_point(*point, rotation);

            Vec3[24] original;
            original[:fixture.vertex_count] = fixture.mesh.geometry.positions[..];

            SolidScratch scratch = begin_solid_scratch(&workspace);
            CollisionHullSurface hull = build_collision_hull(&scratch, fixture.mesh.geometry.positions)!!;
            assert(hull.points.len == fixture.vertex_count);
            assert(scratch.exact.peak <= HULL_WIDE_TEMPORARIES);
            uint exterior = assert_hull_surface(&scratch, &hull, fixture.mesh.geometry.positions);
            assert(shape == 4 ? exterior >= 10 && exterior <= 12 : exterior == 8);
            assert(mem::equals((char*)&fixture.positions[0], (char*)&original[0], fixture.vertex_count * Vec3::size));

            Vec3[24] reordered;
            for (uint index = 0; index < fixture.vertex_count; index++) {
                reordered[index] = fixture.positions[fixture.vertex_count - 1 - index];
            }
            CollisionHullSurface reversed = build_collision_hull(&scratch, reordered[:fixture.vertex_count])!!;
            assert_same_hull(&hull, &reversed);
            for (uint index = 0; index < fixture.vertex_count; index++) {
                reordered[index] = fixture.positions[(index + rotation + 1) % fixture.vertex_count];
            }
            CollisionHullSurface shifted = build_collision_hull(&scratch, reordered[:fixture.vertex_count])!!;
            assert_same_hull(&hull, &shifted);
            assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
        }
    }
}

fn void test_collision_hull_coplanar_faces_collinear_extensions_and_signed_zero_duplicates() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);

    Vec3[133] points;

    uint count;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            for (int z = -2; z <= 2; z++) points[count++] = { (float)x, (float)y, (float)z };
        }
    }
    for (uint zero = 0; zero < 8; zero++) {
        points[count++] = {
            bitcast((zero & 1) << 31, float),
            bitcast(((zero >> 1) & 1) << 31, float),
            bitcast(((zero >> 2) & 1) << 31, float),
        };
    }

    SolidScratch scratch = begin_solid_scratch(&workspace);

    CollisionHullSurface hull = build_collision_hull(&scratch, points[..])!!;
    assert(hull.points.len == 125 && hull.indices.len == 36);
    assert(scratch.peak == MIN_FRACTURE_SCRATCH_BYTES + HULL_GRID_ADDITIONAL_BYTES);
    assert(scratch.exact.peak <= HULL_WIDE_TEMPORARIES);
    assert(assert_hull_surface(&scratch, &hull, points[..]) == 8);
    foreach (point : hull.points) {
        if (same_position(point, {})) {
            assert(bitcast(point.x, uint) == 0 && bitcast(point.y, uint) == 0 && bitcast(point.z, uint) == 0);
        }
    }
    foreach (index : hull.indices) {
        foreach (coordinate : hull.points[index]) assert(coordinate == -2 || coordinate == 2);
    }
    for (uint index = 0; index < points.len / 2; index++) {
        Vec3 saved = points[index];
        points[index] = points[points.len - 1 - index];
        points[points.len - 1 - index] = saved;
    }
    CollisionHullSurface reversed = build_collision_hull(&scratch, points[..])!!;
    assert_same_hull(&hull, &reversed);

    Vec3[6] tied = {
        { -0.0f, 0, 0 }, { 0, -0.0f, 0 }, { 0, 0, -0.0f },
        { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 },
    };
    CollisionHullSurface tetrahedron = build_collision_hull(&scratch, tied[..])!!;
    assert(tetrahedron.points.len == 4 && tetrahedron.indices.len == 12);
    assert(bitcast(tetrahedron.points[0].x, uint) == 0 && bitcast(tetrahedron.points[0].y, uint) == 0);
    assert(bitcast(tetrahedron.points[0].z, uint) == 0x80000000);
    assert(assert_hull_surface(&scratch, &tetrahedron, tied[..]) == 4);
}

fn void test_collision_hull_exact_extremes_keep_subnormals_and_source_bits() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 3; variant++) {
        ContainmentFixture fixture;
        append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
        foreach (&point : fixture.mesh.geometry.positions) {
            if (variant == 0) {
                point.x = point.x < 0 ? -float::max : float::max;
                point.y = point.y < 0 ? bitcast((uint)0x80000001, float) : bitcast((uint)2, float);
            } else if (variant == 1) {
                foreach (&coordinate : *point) {
                    *coordinate = *coordinate < 0 ? bitcast((uint)0x80000001, float) : bitcast((uint)1, float);
                }
            } else {
                point.x = point.x < 0 ? bitcast((uint)0x7f7ffffe, float) : float::max;
                point.y = point.y < 0 ? -float::max : bitcast((uint)0xff7ffffe, float);
            }
        }

        SolidScratch scratch = begin_solid_scratch(&workspace);

        CollisionHullSurface hull = build_collision_hull(&scratch, fixture.mesh.geometry.positions)!!;
        assert(hull.points.len == 8 && hull.indices.len == 36);
        assert(scratch.exact.peak <= HULL_WIDE_TEMPORARIES);
        assert(assert_hull_surface(&scratch, &hull, fixture.mesh.geometry.positions) == 8);
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_collision_hull_generated_integer_clouds_have_exact_supporting_manifold_faces() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    uint state = 0x16dbf841;
    for (uint cloud = 0; cloud < 32; cloud++) {
        Vec3[48] points;
        points[0] = { -4, 0, 0 };
        points[1] = { 4, 0, 0 };
        points[2] = { 0, -4, 0 };
        points[3] = { 0, 0, 4 };
        foreach (&point : points[4..]) {
            foreach (&coordinate : *point) {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *coordinate = (float)((int)(state % 9) - 4);
            }
        }

        SolidScratch scratch = begin_solid_scratch(&workspace);

        CollisionHullSurface hull = build_collision_hull(&scratch, points[..])!!;
        assert(assert_hull_surface(&scratch, &hull, points[..]) >= 4);
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_collision_hull_degeneracy_and_scratch_failures_restore_inputs_and_allow_reuse() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3[5] degenerate = { { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 3, 3 }, { 4, 4, 4 } };

    SolidScratch scratch = begin_solid_scratch(&workspace);
    char[] previous = reserve_elements(&scratch, char, 71)!!;
    previous[..] = 0x6d;
    usz saved = scratch.used;
    assert(@catch(build_collision_hull(&scratch, {})) == NUMERICAL_FAILURE);
    assert(@catch(build_collision_hull(&scratch, degenerate[:3])) == NUMERICAL_FAILURE);
    assert(@catch(build_collision_hull(&scratch, degenerate[..])) == NUMERICAL_FAILURE);
    degenerate[..] = {};
    assert(@catch(build_collision_hull(&scratch, degenerate[..])) == NUMERICAL_FAILURE);
    degenerate = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 2, 2, 0 } };
    assert(@catch(build_collision_hull(&scratch, degenerate[..])) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);

    Vec3[24] original = fixture.positions;

    CollisionHullSurface hull = build_collision_hull(&scratch, fixture.mesh.geometry.positions)!!;
    usz required = scratch.peak;
    assert(hull.points.len == 8 && hull.indices.len == 36);
        assert(scratch.exact.peak <= HULL_WIDE_TEMPORARIES);
    for (usz capacity = saved; capacity < required; capacity += 17) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(build_collision_hull(&scratch, fixture.mesh.geometry.positions)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (byte : previous) assert(byte == 0x6d);
    }
    scratch.storage = workspace.storage[:required - 1];
    assert(@catch(build_collision_hull(&scratch, fixture.mesh.geometry.positions)) == c3d::CAPACITY_EXCEEDED);
    scratch.storage = workspace.storage;

    Vec3[5] cancellation = { { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 4, 5 }, { 4, 5, 7 } };

    scratch.exact.count = EXACT_TEMPORARIES;
    assert(@catch(build_collision_hull(&scratch, cancellation[..])) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == EXACT_TEMPORARIES);
    scratch.exact.count = 0;
    hull = build_collision_hull(&scratch, cancellation[..])!!;
    assert(assert_hull_surface(&scratch, &hull, cancellation[..]) == 4);
    hull = build_collision_hull(&scratch, fixture.mesh.geometry.positions)!!;
    assert(assert_hull_surface(&scratch, &hull, fixture.mesh.geometry.positions) == 8);
    assert(mem::equals((char*)&fixture.positions[0], (char*)&original[0], Vec3[24]::size));
    foreach (byte : previous) assert(byte == 0x6d);
    Vec3[] oversized = (&fixture.positions[0])[:(usz)uint::max + 1];
    usz completed = scratch.used;
    assert(@catch(build_collision_hull(&scratch, oversized)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == completed && scratch.exact.count == 0);
}

fn Vec3 rotate_hull_test_point(Vec3 point, uint index) @local {
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

fn uint assert_hull_surface(SolidScratch* scratch, CollisionHullSurface* hull, Vec3[] source) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    bool[] used = reserve_elements(scratch, bool, hull.points.len)!!;
    used[..] = false;
    uint[] identities = reserve_elements(scratch, uint, hull.points.len)!!;
    uint[] materials = reserve_elements(scratch, uint, hull.indices.len / TRIANGLE_CORNERS)!!;
    materials[..] = 0;
    foreach (uint index, point : hull.points) {
        identities[index] = index;
        bool found;
        foreach (candidate : source) {
            bool identical = true;
            for (uint axis = 0; axis < SPACE_AXES; axis++) identical &= bitcast(point[axis], uint) == bitcast(candidate[axis], uint);
            found |= identical;
        }
        assert(found);
    }
    foreach (point : source) {
        bool found;
        foreach (candidate : hull.points) found |= same_position(point, candidate);
        assert(found);
    }
    foreach (index : hull.indices) {
        assert(index < hull.points.len);
        used[index] = true;
    }

    uint vertices;
    foreach (value : used) vertices += value ? 1 : 0;
    assert(hull.indices.len / TRIANGLE_CORNERS == 2 * (usz)vertices - 4);
    for (usz face = 0; face < hull.indices.len; face += TRIANGLE_CORNERS) {
        uint[] triangle = hull.indices[face:TRIANGLE_CORNERS];
        assert(triangle[0] < triangle[1] && triangle[0] < triangle[2]);
        if (face) {
            uint[] prior = hull.indices[face - TRIANGLE_CORNERS:TRIANGLE_CORNERS];
            bool ordered;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                if (prior[corner] != triangle[corner]) {
                    ordered = prior[corner] < triangle[corner];
                    break;
                }
            }
            assert(ordered);
        }
        foreach (point : source) {
            assert(exact_float_orientation(scratch.exact, {
                hull.points[triangle[0]], hull.points[triangle[1]], hull.points[triangle[2]], point,
            })!! <= 0);
        }
    }

    SolidMeshView mesh = {
        .geometry = { .positions = hull.points, .indices = hull.indices },
        .topology_vertices = identities, .triangle_materials = materials,
    };

    SolidDiagnostic diagnostic;
    ValidatedSolid solid = validate_solid(
        scratch: scratch,
        source: mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!!;
    assert(solid.nesting.shells.len == 1 && solid.nesting.shells[0].six_volume.used);
    assert(!solid.nesting.shells[0].six_volume.negative && diagnostic.reason == SolidFailure.NONE);
    return vertices;
}

fn void assert_same_hull(CollisionHullSurface* first, CollisionHullSurface* second) @local {
    assert(first.points.len == second.points.len && first.indices.len == second.indices.len);
    assert(mem::equals((char*)first.points.ptr, (char*)second.points.ptr, first.points.len * Vec3::size));
    assert(mem::equals((char*)first.indices.ptr, (char*)second.indices.ptr, first.indices.len * uint::size));
}
