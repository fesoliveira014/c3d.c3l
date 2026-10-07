module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_collision_retained_omits_generated_eleven_ulp_neighbor_with_final_witness() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    float upper = bitcast(bitcast(1.0f, uint) + 11, float);
    append_box_fixture(&source, { 1, -1, -1 }, { upper, 1, 1 });

    PublishFixture prepared;
    SurfacePointMap points;
    CollisionReferenceVertices vertices = retained_vertex_fixture(
        scratch: &scratch, source: &source, prepared: &prepared, points: &points,
    );
    Vec3 generated = { upper, -1, -1 };
    uint omitted = retained_vertex_index(vertices.positions, generated);
    assert(omitted != NO_SOLID_INDEX && bitcast(upper, uint) - bitcast(1.0f, uint) == 11);
    vertices.authored[omitted] = false;

    CollisionHullSurface hull = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    assert(hull.points.len == 7 && retained_vertex_index(hull.points, generated) == NO_SOLID_INDEX);
    foreach (uint index, position : vertices.positions) {
        if (vertices.authored[index]) assert(retained_vertex_index(hull.points, position) != NO_SOLID_INDEX);
    }
    certify_collision_reference_vertices(
        scratch: scratch.exact, points: &points, references: vertices.references, hull: &hull, resolution: 0.00001,
    )!!;

    CollisionHullSurface repeated = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    assert(hull.indices == repeated.indices && hull.points.len == repeated.points.len);
    foreach (uint index, position : hull.points) {
        assert(retained_vertex_index(repeated.points, position) == index);
    }
    assert(scratch.exact.count == 0);
}

fn void test_collision_retained_preserves_equally_near_authored_vertices_bitwise() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    float upper = bitcast(bitcast(1.0f, uint) + 11, float);
    append_box_fixture(&source, { 1, -1, -1 }, { upper, 1, 1 });

    PublishFixture prepared;
    SurfacePointMap points;
    CollisionReferenceVertices vertices = retained_vertex_fixture(
        scratch: &scratch, source: &source, prepared: &prepared, points: &points,
    );
    foreach (authored : vertices.authored) assert(authored);

    CollisionHullSurface hull = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    assert(hull.points.len == 8);
    foreach (position : vertices.positions) assert(retained_vertex_index(hull.points, position) != NO_SOLID_INDEX);
    assert(retained_vertex_index(hull.points, { 1, -1, -1 }) != NO_SOLID_INDEX);
    assert(retained_vertex_index(hull.points, { upper, -1, -1 }) != NO_SOLID_INDEX);
    assert(scratch.exact.count == 0);
}

fn void test_collision_retained_keeps_a_generated_vertex_without_an_omission_witness() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    append_box_fixture(&source, { -1, -1, -1 }, { 1, 1, 1 });

    PublishFixture prepared;
    SurfacePointMap points;
    CollisionReferenceVertices vertices = retained_vertex_fixture(
        scratch: &scratch, source: &source, prepared: &prepared, points: &points,
    );
    uint necessary = retained_vertex_index(vertices.positions, { 1, -1, -1 });
    vertices.authored[necessary] = false;

    CollisionHullSurface hull = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    assert(hull.points.len == 8);
    assert(retained_vertex_index(hull.points, vertices.positions[necessary]) != NO_SOLID_INDEX);
    assert(scratch.exact.count == 0);
}

fn void test_collision_retained_certificate_rejects_undercoverage_and_recovers() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    append_box_fixture(&source, { -1, -1, -1 }, { 1, 1, 1 });

    PublishFixture prepared;
    SurfacePointMap points;
    CollisionReferenceVertices vertices = retained_vertex_fixture(
        scratch: &scratch, source: &source, prepared: &prepared, points: &points,
    );
    uint missing = retained_vertex_index(vertices.positions, { 1, -1, -1 });
    Vec3[7] incomplete;
    uint count;
    foreach (uint index, position : vertices.positions) {
        if (index != missing) incomplete[count++] = position;
    }
    CollisionHullSurface candidate = build_collision_hull(&scratch, incomplete[..])!!;
    usz saved = scratch.used;

    assert(@catch(certify_collision_reference_vertices(
        scratch: scratch.exact, points: &points, references: vertices.references,
        hull: &candidate, resolution: 0.00001,
    )) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0);
    assert(candidate.points.len == 7 && retained_vertex_index(candidate.points, vertices.positions[missing]) == NO_SOLID_INDEX);

    CollisionHullSurface complete = build_collision_hull(&scratch, vertices.positions)!!;
    certify_collision_reference_vertices(
        scratch: scratch.exact, points: &points, references: vertices.references,
        hull: &complete, resolution: 0.00001,
    )!!;
    assert(scratch.exact.count == 0);
}

fn void test_collision_retained_capacity_failure_preserves_reference_inputs() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    append_box_fixture(&source, { -1, -1, -1 }, { 1, 1, 1 });

    PublishFixture prepared;
    SurfacePointMap points;
    CollisionReferenceVertices vertices = retained_vertex_fixture(
        scratch: &scratch, source: &source, prepared: &prepared, points: &points,
    );
    vertices.authored[0] = false;
    usz saved = scratch.used;
    scratch.peak = saved;
    CollisionHullSurface complete = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    usz required = scratch.peak;
    assert(complete.points.len == 8);

    foreach (usz capacity : { saved, saved + (required - saved) / 2, required - 1 }) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(retain_collision_hull(
            scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && !vertices.authored[0]);
        foreach (uint index, reference : vertices.references) {
            assert(vertices.positions[index] == points.positions[reference]);
            if (index) assert(vertices.authored[index]);
        }
    }

    scratch.storage = workspace.storage[:required];
    complete = retain_collision_hull(
        scratch: &scratch, points: &points, vertices: &vertices, resolution: 0.00001,
    )!!;
    assert(complete.points.len == 8 && scratch.exact.count == 0);
}

fn CollisionReferenceVertices retained_vertex_fixture(
    SolidScratch* scratch,
    ContainmentFixture* source,
    PublishFixture* prepared,
    SurfacePointMap* points,
) @local {
    prepare_publish_source(scratch: scratch, fixture: prepared, mesh: source.mesh);
    prepare_uncut_publication(scratch, prepared);
    BoundaryPatch[] patches = reserve_elements(scratch, BoundaryPatch, prepared.pieces[0].patches.len)!!;
    foreach (uint index, patch : prepared.pieces[0].patches) patches[index] = patch.boundary;
    *points = map_surface_points(scratch, patches)!!;

    return collision_reference_vertices(
        scratch: scratch, points: points, first_patch: 0, patch_count: (uint)patches.len, source: &prepared.surface,
    )!!;
}

fn uint retained_vertex_index(Vec3[] points, Vec3 target) @local {
    foreach (uint index, position : points) {
        bool equal = true;
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            equal &= bitcast(position[axis], uint) == bitcast(target[axis], uint);
        }
        if (equal) return index;
    }
    return NO_SOLID_INDEX;
}
