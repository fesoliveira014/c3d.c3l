module c3d::physics::fracture;

import c3d;
import std::math;

const uint SEPARATE_TETRAHEDRA @local = 32;

struct TrianglePairFixture @local {
    Vec3[6] positions;
    uint[6] indices;
    uint[6] identities;
    SolidVertex[6] vertices;
    uint[2] materials;
    uint[2] projections;
    GridPoint[6] grid;
    SolidSurface surface;
}

fn void test_triangle_contacts_accept_only_shared_topological_edges_and_vertices() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, {}, {} },
        indices: { 0, 1, 2, 1, 0, 3 },
        conflict: false,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, {}, {} },
        indices: { 0, 1, 2, 1, 0, 3 },
        conflict: false,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }, { 0, -1, 1 }, {} },
        indices: { 0, 1, 2, 0, 3, 4 },
        conflict: false,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, {}, { -1, 0, 0 }, { 0, -1, 1 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 1 }, { 0, 1, 1 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: false,
    );
}

fn void test_triangle_contacts_reject_coplanar_overlap_piercing_and_unshared_face_touch() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 2, 0, 0 }, { 0, 2, 0 }, { 0.25, 0.25, 0 }, { 1, 0.25, 0 }, { 0.25, 1, 0 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { { -2, -1, 0 }, { 2, -1, 0 }, { 0, 2, 0 }, { -2, 1, 0 }, { 2, 1, 0 }, { 0, -2, 0 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 2, 0, 0 }, { 0, 2, 0 }, { 0.25, 0.25, -1 }, { 0.25, 0.25, 1 }, { 3, 0.25, 1 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 2, 0, 0 }, { 0, 2, 0 }, { 0.25, 0.25, 0 }, { 0.25, 0.25, 1 }, { 0.5, 0.25, 1 } },
        indices: { 0, 1, 2, 3, 4, 5 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 2, 0, 0 }, { 0, 2, 0 }, { 0.5, 0.5, 0 }, {}, {} },
        indices: { 0, 1, 2, 1, 0, 3 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 2, 0, 0 }, { 0, -1, 0 }, {} },
        indices: { 0, 1, 2, 0, 3, 4 },
        conflict: true,
    );
    assert_triangle_pair(
        workspace: &workspace,
        positions: { {}, { 1, 0, 0 }, { 0, 1, 0 }, {}, {}, {} },
        indices: { 0, 1, 2, 2, 1, 0 },
        conflict: true,
    );
}

fn void test_surface_validation_reports_first_bad_pair_and_degenerate_face() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    SolidDiagnostic diagnostic;
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface valid = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
    assert(valid.validated && valid.candidate_pairs == 6);
    assert(diagnostic.reason == SolidFailure.NONE && diagnostic.first_face == NO_SOLID_INDEX && diagnostic.second_face == NO_SOLID_INDEX);
    fixture.positions[2] = fixture.positions[1];
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(build_solid_surface(&scratch, fixture.mesh, &diagnostic)) == INVALID_SOLID);
    assert(diagnostic.reason == SolidFailure.DEGENERATE_TRIANGLE && diagnostic.first_face == 0 && diagnostic.second_face == 0);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == 0);
    tetra_fixture(&fixture);
    for (uint vertex = 0; vertex < 4; vertex++) {
        fixture.positions[vertex + 4] = fixture.positions[vertex];
        fixture.identities[vertex + 4] = vertex + 4;
    }
    for (uint corner = 0; corner < 12; corner++) fixture.indices[corner + 12] = fixture.indices[corner] + 4;
    fixture.mesh.geometry.positions = fixture.positions[:8];
    fixture.mesh.geometry.indices = fixture.indices[..];
    fixture.mesh.topology_vertices = fixture.identities[:8];
    fixture.mesh.triangle_materials = fixture.materials[..];
    uint first_pair = NO_SOLID_INDEX;
    for (uint repeat = 0; repeat < 4; repeat++) {
        scratch = begin_solid_scratch(&workspace);
        assert(@catch(build_solid_surface(&scratch, fixture.mesh, &diagnostic)) == INVALID_SOLID);
        assert(diagnostic.reason == SolidFailure.TRIANGLE_INTERSECTION && diagnostic.first_face == 0);
        assert(diagnostic.second_face == 6);
        if (repeat) assert(diagnostic.second_face == first_pair);
        first_pair = diagnostic.second_face;
        assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES && scratch.exact.count == 0);
    }
    for (uint vertex = 0; vertex < 4; vertex++) fixture.positions[vertex + 4] = fixture.positions[vertex] + (Vec3){ 0.25, 0.25, 0.25 };
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(build_solid_surface(&scratch, fixture.mesh, &diagnostic)) == INVALID_SOLID);
    assert(diagnostic.reason == SolidFailure.TRIANGLE_INTERSECTION);
    for (uint vertex = 0; vertex < 4; vertex++) fixture.positions[vertex + 4] = fixture.positions[vertex] + (Vec3){ 1, 0, 0 };
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(build_solid_surface(&scratch, fixture.mesh, &diagnostic)) == INVALID_SOLID);
    assert(diagnostic.reason == SolidFailure.TRIANGLE_INTERSECTION);
    for (uint vertex = 0; vertex < 4; vertex++) fixture.positions[vertex + 4] += (Vec3){ 2, 0, 0 };
    scratch = begin_solid_scratch(&workspace);
    assert(build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!.candidate_pairs == 12);
}

fn void test_surface_hierarchy_prunes_disjoint_shells_and_restores_capacity_failures() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidFixture tetra;
    tetra_fixture(&tetra);
    Vec3[4 * SEPARATE_TETRAHEDRA] positions;
    uint[12 * SEPARATE_TETRAHEDRA] indices;
    uint[4 * SEPARATE_TETRAHEDRA] identities;
    uint[4 * SEPARATE_TETRAHEDRA] materials;
    for (uint part = 0; part < SEPARATE_TETRAHEDRA; part++) {
        for (uint vertex = 0; vertex < 4; vertex++) {
            positions[part * 4 + vertex] = tetra.positions[vertex] + (Vec3){ (float)(part * 3), 0, 0 };
            identities[part * 4 + vertex] = part * 4 + vertex;
        }
        for (uint corner = 0; corner < 12; corner++) indices[part * 12 + corner] = tetra.indices[corner] + part * 4;
    }
    SolidMeshView mesh = {
        .geometry = { .positions = positions[..], .indices = indices[..] },
        .topology_vertices = identities[..],
        .triangle_materials = materials[..],
    };
    SolidDiagnostic diagnostic;
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface surface = build_solid_surface(&scratch, mesh, &diagnostic)!!;
    assert(surface.topology.shell_count == SEPARATE_TETRAHEDRA);
    assert(surface.candidate_pairs == 6 * SEPARATE_TETRAHEDRA);
    uint[4 * SEPARATE_TETRAHEDRA] first_order;
    first_order[..] = surface.order[..];
    usz required = scratch.peak;
    for (uint repeat = 0; repeat < 3; repeat++) {
        scratch = begin_solid_scratch(&workspace);
        surface = build_solid_surface(&scratch, mesh, &diagnostic)!!;
        assert(surface.candidate_pairs == 6 * SEPARATE_TETRAHEDRA);
        foreach (index, face : surface.order) assert(face == first_order[index]);
        assert(scratch.peak == required);
    }
    scratch = begin_solid_scratch(&workspace);
    scratch.storage = scratch.storage[:required - 1];
    diagnostic = { .reason = SolidFailure.TRIANGLE_INTERSECTION, .first_face = 3, .second_face = 4 };
    assert(@catch(build_solid_surface(&scratch, mesh, &diagnostic)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
    assert(diagnostic.first_face == NO_SOLID_INDEX && diagnostic.second_face == NO_SOLID_INDEX);
}

fn void test_projected_predicates_and_raw_bounds_preserve_extreme_float_values() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    foreach (float scale : { float::max, bitcast((uint)1, float) }) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            Vec3[SPACE_AXES] points;
            points[1][(axis + 1) % SPACE_AXES] = scale;
            points[2][(axis + 2) % SPACE_AXES] = scale;
            assert(exact_projected_orientation(scratch, points, axis)!! == 1);
            assert(projected_orientation(scratch, points, axis)!! == 1);
            points[2] = points[1];
            assert(projected_orientation(scratch, points, axis)!! == 0);
        }
    }
    assert(scratch.count == 0 && scratch.peak == 11);
    ulong filtered = scratch.filtered_count;
    Vec3[SPACE_AXES] collinear = {
        { -float::max, -float::max, 0 },
        { float::max, float::max, 0 },
        { bitcast((uint)1, float), bitcast((uint)1, float), 0 },
    };
    assert(projected_orientation(scratch, collinear, 2)!! == 0 && scratch.filtered_count == filtered);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    float tiny = bitcast((uint)1, float);
    fixture.positions[1].x = tiny;
    fixture.positions[2].y = tiny;
    fixture.positions[3].z = tiny;
    SolidScratch arena = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(&arena, fixture.mesh, &diagnostic)!!;
    assert(surface.validated && surface_coordinate_key(&surface, 1, 0) == 1);
    fixture.positions[1].x = -tiny;
    assert(surface_coordinate_key(&surface, 1, 0) == -1);
    fixture.positions[1].x = bitcast((uint)0x80000000, float);
    assert(surface_coordinate_key(&surface, 1, 0) == 0);
    fixture.positions[1].x = -float::max;
    fixture.positions[2].y = float::max;
    fixture.positions[3].z = float::max;
    arena = begin_solid_scratch(&workspace);
    assert(build_solid_surface(&arena, fixture.mesh, &diagnostic)!!.validated);
}

fn void assert_triangle_pair(
    FractureWorkspace* workspace,
    Vec3[6] positions,
    uint[6] indices,
    bool conflict,
) @local {
    check_triangle_pair_domains(
        workspace: workspace,
        positions: positions,
        indices: indices,
        conflict: conflict,
    );
    for (uint transform = 0; transform < SPACE_AXES; transform++) {
        Vec3[6] transformed;
        foreach (uint index, point : positions) {
            Vec3 sheared = { point.x + 2 * point.y - point.z, point.y + point.z, point.z };
            for (uint axis = 0; axis < SPACE_AXES; axis++) transformed[index][axis] = sheared[(axis + transform) % SPACE_AXES];
            if (transform == 2) transformed[index].x = -transformed[index].x;
        }
        check_triangle_pair_domains(
            workspace: workspace,
            positions: transformed,
            indices: indices,
            conflict: conflict,
        );
    }
}

fn void check_triangle_pair_domains(
    FractureWorkspace* workspace,
    Vec3[6] positions,
    uint[6] indices,
    bool conflict,
) @local {
    TrianglePairFixture fixture = { .positions = positions, .indices = indices };
    SolidScratch scratch = begin_solid_scratch(workspace);
    for (uint vertex = 0; vertex < 6; vertex++) {
        fixture.identities[vertex] = vertex;
        fixture.vertices[vertex].representative = vertex;
        for (uint axis = 0; axis < SPACE_AXES; axis++) fixture.grid[vertex][axis] = (long)(positions[vertex][axis] * 4);
    }
    fixture.surface = {
        .source = {
            .geometry = { .positions = fixture.positions[..], .indices = fixture.indices[..] },
            .topology_vertices = fixture.identities[..],
            .triangle_materials = fixture.materials[..],
        },
        .topology = { .vertices = fixture.vertices[..] },
        .exact = scratch.exact,
        .projections = fixture.projections[..],
    };
    foreach (uint face, &projection : fixture.projections) {
        while (surface_projection(&fixture.surface, surface_triangle(&fixture.surface, face), *projection)!! == 0) (*projection)++;
        assert(*projection < SPACE_AXES);
    }
    assert(triangles_conflict(&fixture.surface, 0, 1)!! == conflict);
    assert(triangles_conflict(&fixture.surface, 1, 0)!! == conflict);
    fixture.surface.grid = fixture.grid[..];
    assert(triangles_conflict(&fixture.surface, 0, 1)!! == conflict);
    assert(triangles_conflict(&fixture.surface, 1, 0)!! == conflict);
    assert(scratch.exact.count == 0);
}
