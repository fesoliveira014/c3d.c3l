module c3d::physics::fracture;

import c3d;
import std::math;

fn FractureWorkspace collision_test_workspace() @private {
    FractureLimits limits = {
        .scratch_bytes = 8 * 1024 * 1024,
        .max_vertices = 4096,
        .max_triangles = 8192,
        .max_pieces = 8,
        .max_sites = 8,
        .max_hulls = 1024,
        .resolution_m = 0.0001f,
    };
    return create_fracture_workspace(mem, limits)!!;
}

fn void test_fracture_collision_convex_piece_has_one_local_hull_and_independent_owner() @test {
    FractureWorkspace workspace = collision_test_workspace();
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    FracturePieceView piece = { .mesh = fixture.mesh, .origin = { 100, -200, 300 } };
    FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureCollision collision = create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )!!;
    assert(collision.hulls.len == 1 && collision.hulls[0].piece_index == 0);
    assert(collision.hulls[0].points.len == 8);
    assert(tracker.allocation_count() == 1 && tracker.total_allocation_count() == 1);
    destroy_fracture_result(&fragments);
    workspace.storage[..] = 0x5a;
    destroy_fracture_workspace(&workspace);
    foreach (point : collision.hulls[0].points) {
        assert(math::abs(point.x) == 3 && math::abs(point.y) == 3 && math::abs(point.z) == 3);
    }
    destroy_fracture_collision(&collision);
    assert(!collision.storage.len && !collision.hulls.len && tracker.allocation_count() == 0);
    destroy_fracture_collision(&collision);
}

fn void test_fracture_collision_four_vertex_hulls_cover_concavity_cavities_and_islands() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    double[5] expected = { 216, 208, 160, 16, 3 };
    for (uint shape = 0; shape < expected.len; shape++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        FracturePieceView piece = { .mesh = fixture.mesh };
        FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
        defer destroy_fracture_result(&fragments);
        FractureCollision collision = create_fracture_collision(
            allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 4,
        )!!;
        defer destroy_fracture_collision(&collision);
        assert(collision.hulls.len && math::abs(collision_test_volume(&collision) - expected[shape]) < 1e-8);
        foreach (hull : collision.hulls) assert(hull.piece_index == 0 && hull.points.len == 4);
        assert(((ExactScratch*)workspace.storage.ptr).count == 0);
    }
}

fn void test_fracture_collision_oblique_cavity_preserves_volume_after_float_conversion() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 1);
    for (uint vertex = 8; vertex < fixture.vertex_count; vertex++) {
        Vec3 point = fixture.positions[vertex];
        fixture.positions[vertex] = {
            point.x + 0.5f * point.y, point.y + 0.5f * point.z, point.z + 0.5f * point.x,
        };
    }
    FracturePieceView piece = { .mesh = fixture.mesh };
    FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
    defer destroy_fracture_result(&fragments);
    FractureCollision collision = create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 4,
    )!!;
    defer destroy_fracture_collision(&collision);
    assert(collision.hulls.len && math::abs(collision_test_volume(&collision) - 207) < 0.001);
    foreach (hull : collision.hulls) {
        assert(hull.points.len == 4);
        foreach (point : hull.points) assert(finite_position(point));
    }
}

fn void test_fracture_collision_global_limits_fault_without_publishing_and_allow_reuse() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    FracturePieceView[2] pieces = { { .mesh = fixture.mesh }, { .mesh = fixture.mesh, .origin = { 10, 0, 0 } } };
    FractureResult fragments = copy_fracture_result(mem, pieces[..])!!;
    defer destroy_fracture_result(&fragments);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    assert(@catch(create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 3,
    )) == c3d::INVALID_ARGUMENT);
    workspace.limits.max_hulls = 1;
    assert(@catch(create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )) == c3d::CAPACITY_EXCEEDED);
    workspace.limits.max_hulls = 1024;
    workspace.limits.max_vertices = 15;
    assert(@catch(create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )) == c3d::CAPACITY_EXCEEDED);
    workspace.limits.max_vertices = 4096;
    workspace.limits.max_triangles = 23;
    assert(@catch(create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )) == c3d::CAPACITY_EXCEEDED);
    workspace.limits.max_triangles = 8192;
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
    FractureCollision recovered = create_fracture_collision(
        allocator: &tracker, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )!!;
    assert(recovered.hulls.len == 2 && recovered.hulls[0].piece_index == 0 && recovered.hulls[1].piece_index == 1);
    destroy_fracture_collision(&recovered);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 1);
}

fn void test_fracture_collision_empty_and_allocation_failure_preserve_inputs() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    FractureResult empty = copy_fracture_result(mem, {})!!;
    defer destroy_fracture_result(&empty);
    FractureCollision nothing = create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &empty, max_hull_vertices: 4,
    )!!;
    assert(nothing.storage.len == 1 && !nothing.hulls.len);
    destroy_fracture_collision(&nothing);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 0);
    FracturePieceView piece = { .mesh = fixture.mesh };
    FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
    defer destroy_fracture_result(&fragments);
    NullAllocator unavailable;
    assert(@catch(create_fracture_collision(
        allocator: &unavailable, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )) == c3d::CAPACITY_EXCEEDED);
    foreach (uint index, point : fragments.pieces[0].mesh.geometry.positions) {
        assert(same_position(point, fixture.positions[index]));
    }
    assert(((ExactScratch*)workspace.storage.ptr).count == 0);
    FractureCollision recovered = create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 8,
    )!!;
    destroy_fracture_collision(&recovered);
}

fn double collision_test_volume(FractureCollision* collision) @private {
    double volume;
    foreach (hull : collision.hulls) {
        assert(hull.points.len == 4);
        double[3][3] edges;
        for (uint index = 0; index < SPACE_AXES; index++) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                edges[index][axis] = (double)hull.points[index][axis] - (double)hull.points[3][axis];
            }
        }
        double determinant = edges[0][0] * (edges[1][1] * edges[2][2] - edges[1][2] * edges[2][1])
          - edges[0][1] * (edges[1][0] * edges[2][2] - edges[1][2] * edges[2][0])
          + edges[0][2] * (edges[1][0] * edges[2][1] - edges[1][1] * edges[2][0]);
        assert(determinant != 0);
        volume += math::abs(determinant) / 6.0;
    }
    return volume;
}

fn void test_fracture_collision_repeated_output_is_identical_after_capacity_failure() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 4);
    FracturePieceView piece = { .mesh = fixture.mesh };
    FractureResult fragments = copy_fracture_result(mem, (&piece)[:1])!!;
    defer destroy_fracture_result(&fragments);
    FractureCollision first = create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 4,
    )!!;
    defer destroy_fracture_collision(&first);
    char[] full_storage = workspace.storage;
    workspace.storage = full_storage[:MIN_FRACTURE_SCRATCH_BYTES + 64];
    assert(@catch(create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 4,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(((ExactScratch*)workspace.storage.ptr).count == 0);
    workspace.storage = full_storage;
    FractureCollision second = create_fracture_collision(
        allocator: mem, workspace: &workspace, fragments: &fragments, max_hull_vertices: 4,
    )!!;
    defer destroy_fracture_collision(&second);
    assert(first.hulls.len == second.hulls.len);
    foreach (uint index, hull : first.hulls) {
        FractureHullView repeated = second.hulls[index];
        assert(hull.piece_index == repeated.piece_index && hull.points.len == repeated.points.len);
        foreach (uint vertex, point : hull.points) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                assert(bitcast(point[axis], uint) == bitcast(repeated.points[vertex][axis], uint));
            }
        }
    }
}

fn void test_fracture_collision_uses_interior_cones_when_a_rounded_face_warps() @test {
    FractureWorkspace workspace = collision_test_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell cell = collision_test_box(
        scratch: &scratch, lower: { -3, -3, -3 }, upper: { 3, 3, 3 }, quantized: false,
    );
    ConvexCell*[1] inputs = { &cell };
    CollisionSurfaceSet surfaces = build_collision_surfaces(&scratch, inputs[..])!!;
    SurfacePointMap points = map_surface_points(&scratch, surfaces.patches)!!;
    uint[] indices = collision_surface_indices(
        scratch: &scratch, surfaces: &surfaces, points: &points, faces: surfaces.cells[0].faces,
    )!!;
    bool changed;
    for (usz first = 0; first < indices.len; first += TRIANGLE_CORNERS) {
        if (!indices[first] || !indices[first + 1] || !indices[first + 2]) continue;
        if (vertex_orientation(scratch.exact, {
            points.exact[indices[first]], points.exact[indices[first + 1]],
            points.exact[indices[first + 2]], points.exact[0],
        })!!) continue;
        Vec3 first_edge = points.positions[indices[first + 1]] - points.positions[indices[first]];
        Vec3 second_edge = points.positions[indices[first + 2]] - points.positions[indices[first]];
        Vec3 normal = first_edge.cross(second_edge);
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            if (normal[axis] == 0) continue;
            points.positions[indices[first]][axis] += workspace.limits.resolution_m / 16;
            break;
        }
        changed = true;
        break;
    }
    assert(changed && !collision_existing_cones(
        scratch: scratch.exact, points: &points, indices: indices, anchor: 0,
    )!!);
    SolidMeshView mesh = collision_indexed_mesh(&scratch, points.positions, indices)!!;
    CollisionMeshValidation checked = validate_collision_mesh(
        scratch: &scratch, mesh: mesh, single_shell: true, resolution: workspace.limits.resolution_m,
    )!!;
    CollisionBuild build = { .limits = workspace.limits };
    publish_collision_cell(
        scratch: &scratch, build: &build, piece: 0, surface: &surfaces.cells[0],
        points: &points, indices: indices, checked: checked, max_hull_vertices: 4,
    )!!;
    FractureCollision collision = copy_collision_hulls(mem, &build)!!;
    defer destroy_fracture_collision(&collision);
    assert(collision.hulls.len == indices.len / TRIANGLE_CORNERS);
    assert(math::abs(collision_test_volume(&collision) - 216) < 0.001);
    foreach (hull : collision.hulls) {
        bool contains_centroid;
        foreach (point : hull.points) contains_centroid |= same_position(point, checked.centroid);
        assert(contains_centroid);
    }
}
