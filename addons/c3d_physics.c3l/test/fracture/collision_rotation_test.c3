module c3d::physics::fracture;

import c3d;
import std::math;
import std::io;

fn Quaternion collision_fixture_rotation(uint sample) @private {
    double[<3>] axis = { 1, 2 + (double)sample, 3 };
    return quaternion::from_axis_angle{double}(axis.normalize(), 0.1 + 0.37 * sample);
}

fn void rotate_collision_fixture(ContainmentFixture* fixture, uint shape, uint sample) @private {
    partition_fixture(fixture, shape);
    Quaternion rotation = collision_fixture_rotation(sample);

    foreach (&point : fixture.positions[:fixture.vertex_count]) {
        double[<3>] position = (double[<3>])*point;
        if (!shape) position /= 6.0;
        *point = (Vec3)(rotation * position);
    }
}

fn bool collision_position_bits_equal(Vec3 first, Vec3 second) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (bitcast(first[axis], uint) != bitcast(second[axis], uint)) return false;
    }

    return true;
}

fn void assert_collision_empty_region(
    FractureWorkspace* workspace,
    FractureCollision* collision,
    uint shape,
    uint sample,
) @local {
    if (!shape) return;

    double[<3>] source_probe;
    switch (shape) {
        case 4: source_probe = { 1.5, 1.5, 0.5 };
        case 1: source_probe = {};
        case 2: source_probe = { 1.5, 0, 0 };
    }
    Vec3 probe = (Vec3)(collision_fixture_rotation(sample) * source_probe);
    SolidScratch scratch = begin_solid_scratch(workspace);

    foreach (hull : collision.hulls) {
        usz retained = scratch.used;
        defer scratch.used = retained;

        CollisionHullSurface boundary = build_collision_hull(&scratch, hull.points)!!;
        bool outside;

        for (usz first = 0; first < boundary.indices.len; first += TRIANGLE_CORNERS) {
            int side = float_orientation(scratch.exact, {
                boundary.points[boundary.indices[first]],
                boundary.points[boundary.indices[first + 1]],
                boundary.points[boundary.indices[first + 2]],
                probe,
            })!!;
            outside |= side > 0;
        }

        assert(outside);
    }
}

fn void test_fracture_collision_rotated_surfaces_publish_at_both_hull_limits() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    workspace.limits.max_vertices = 65536;
    workspace.limits.max_hulls = 4096;

    uint passed;
    foreach (shape : (uint[4]){ 0, 4, 1, 2 }) {
        for (uint sample = 0; sample < 12; sample++) {
            ContainmentFixture fixture;
            rotate_collision_fixture(&fixture, shape, sample);

            FracturePieceView piece = { .mesh = fixture.mesh };
            FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
            defer destroy_fracture_result(&fragments);

            foreach (limit : (uint[2]){ 128, 4 }) {
                FractureCollision? collision = create_fracture_collision(
                    allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: limit,
                );
                if (catch failure = collision) {
                    io::printfn("rotation_failed shape=%d sample=%d limit=%d fault=%s", shape, sample, limit, failure);
                    continue;
                }

                defer destroy_fracture_collision(&collision);

                if (!shape && limit == 128) {
                    assert(collision.hulls.len == 1 && collision.hulls[0].points.len == 8);

                    foreach (point : collision.hulls[0].points) {
                        bool original;
                        foreach (source_point : fixture.mesh.geometry.positions) original |= collision_position_bits_equal(point, source_point);
                        assert(original);
                    }
                }

                foreach (hull : collision.hulls) assert(hull.points.len >= 4 && hull.points.len <= limit);

                foreach (source_point : fixture.mesh.geometry.positions) {
                    bool retained;
                    foreach (hull : collision.hulls) {
                        foreach (point : hull.points) retained |= collision_position_bits_equal(point, source_point);
                    }

                    assert(retained);
                }

                assert_collision_empty_region(workspace: &workspace, collision: &collision, shape: shape, sample: sample);
                passed++;
            }
        }
    }

    io::printfn("rotation_passed=%d total=96", passed);
    assert(passed == 96);
}

fn void test_fracture_collision_rotated_triangle_permutations_keep_hulls_identical() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    workspace.limits.max_vertices = 65536;
    workspace.limits.max_hulls = 4096;

    foreach (shape : (uint[4]){ 0, 4, 1, 2 }) {
        ContainmentFixture fixture;
        rotate_collision_fixture(&fixture, shape, 3);

        FracturePieceView piece = { .mesh = fixture.mesh };
        FractureResult original = copy_fracture_result(mem, (&piece)[:1])!!;
        defer destroy_fracture_result(&original);

        for (uint face = 0; face < fixture.triangle_count / 2; face++) {
            uint other = fixture.triangle_count - face - 1;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                uint saved = fixture.indices[face * TRIANGLE_CORNERS + corner];
                fixture.indices[face * TRIANGLE_CORNERS + corner] = fixture.indices[other * TRIANGLE_CORNERS + corner];
                fixture.indices[other * TRIANGLE_CORNERS + corner] = saved;
            }
        }

        piece.mesh = fixture.mesh;
        FractureResult permuted = copy_fracture_result(mem, (&piece)[:1])!!;
        defer destroy_fracture_result(&permuted);

        foreach (limit : (uint[2]){ 128, 4 }) {
            FractureCollision first = create_fracture_collision(
                allocator: mem, workspace: &workspace, fragments: &original, max_hull_vertices: limit,
            )!!;
            defer destroy_fracture_collision(&first);

            FractureCollision second = create_fracture_collision(
                allocator: mem, workspace: &workspace, fragments: &permuted, max_hull_vertices: limit,
            )!!;
            defer destroy_fracture_collision(&second);

            assert(first.hulls.len == second.hulls.len);
            foreach (uint index, hull : first.hulls) {
                FractureHullView other = second.hulls[index];
                assert(hull.piece_index == other.piece_index && hull.points.len == other.points.len);

                foreach (uint point, position : hull.points) {
                    assert(collision_position_bits_equal(position, other.points[point]));
                }
            }
        }
    }
}
