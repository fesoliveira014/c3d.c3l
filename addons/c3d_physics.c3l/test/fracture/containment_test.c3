module c3d::physics::fracture;

import std::math;

const uint[36] CONTAINMENT_BOX_CORNERS @local = {
    0, 6, 4, 0, 2, 6, 1, 7, 3, 1, 5, 7,
    0, 5, 1, 0, 4, 5, 2, 7, 6, 2, 3, 7,
    0, 3, 2, 0, 1, 3, 4, 7, 5, 4, 6, 7,
};
const uint[24] CONTAINMENT_OCTAHEDRON_CORNERS @local = {
    0, 2, 4, 0, 5, 2, 0, 4, 3, 0, 3, 5,
    1, 4, 2, 1, 2, 5, 1, 3, 4, 1, 5, 3,
};
const uint[12] CONTAINMENT_TETRAHEDRON_CORNERS @local = { 0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3 };

struct ContainmentFixture @private {
    Vec3[24] positions;
    uint[108] indices;
    uint[24] identities;
    uint[36] materials;
    GridPoint[24] grid;
    uint vertex_count;
    uint triangle_count;
    SolidMeshView mesh;
}

fn void test_containment_closed_box_validates_raw_and_grid_coplanar_faces() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    foreach (reversed : (bool[2]){ false, true }) {
        ContainmentFixture fixture;
        append_box_fixture(
            fixture: &fixture,
            lower: { -2, -2, -2 },
            upper: { 2, 2, 2 },
            reversed: reversed,
        );
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        assert(surface.validated && surface.topology.shell_count == 1 && surface.projections.len == 12);
        assert(diagnostic.reason == SolidFailure.NONE);
        surface.grid = fixture.grid[:fixture.vertex_count];
        check_surface_geometry(&surface, &diagnostic)!!;
        assert(surface.validated && diagnostic.reason == SolidFailure.NONE);
        assert(scratch.exact.count == 0 && scratch.peak <= workspace.storage.len);
    }
}

fn void test_containment_symbolic_ray_resolves_projection_degeneracies() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureWorkspace workspace = create_fracture_workspace(&tracker, solid_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    foreach (reversed : (bool[2]){ false, true }) {
        ContainmentFixture fixture;
        uint target = append_box_fixture(
            fixture: &fixture,
            lower: { -2, -2, -2 },
            upper: { 2, 2, 2 },
            reversed: reversed,
        );
        uint source = append_tetrahedron_fixture(&fixture, {});
        check_containment_fixture(
            workspace: &workspace,
            fixture: &fixture,
            source_root: source,
            target_root: target,
            expected: true,
            expected_candidates: 2,
        );
        fixture = {};
        source = append_tetrahedron_fixture(&fixture, {});
        target = append_octahedron_fixture(
            fixture: &fixture,
            center: {},
            radius: 1,
            reversed: reversed,
        );
        check_containment_fixture(
            workspace: &workspace,
            fixture: &fixture,
            source_root: source,
            target_root: target,
            expected: true,
            expected_candidates: 8,
        );
        fixture = {};
        target = append_box_fixture(
            fixture: &fixture,
            lower: { -2, -2, -2 },
            upper: { 2, 2, 2 },
            reversed: reversed,
        );
        source = append_tetrahedron_fixture(&fixture, { 2, 0, -3 });
        check_containment_fixture(
            workspace: &workspace,
            fixture: &fixture,
            source_root: source,
            target_root: target,
            expected: false,
            expected_candidates: 6,
        );
        fixture = {};
        source = append_tetrahedron_fixture(&fixture, { 0.75f, 0.75f, -0.5f });
        target = append_octahedron_fixture(
            fixture: &fixture,
            center: {},
            radius: 1,
            reversed: reversed,
        );
        check_containment_fixture(
            workspace: &workspace,
            fixture: &fixture,
            source_root: source,
            target_root: target,
            expected: false,
            expected_candidates: 2,
        );
    }
    assert(tracker.total_allocation_count() == 1);
}

fn uint append_box_fixture(
    ContainmentFixture* fixture,
    Vec3 lower,
    Vec3 upper,
    bool reversed = false,
) @private {
    Vec3[8] points;
    for (uint vertex = 0; vertex < points.len; vertex++) {
        points[vertex] = {
            (vertex & 4) ? upper.x : lower.x,
            (vertex & 2) ? upper.y : lower.y,
            (vertex & 1) ? upper.z : lower.z,
        };
    }
    return append_shell_fixture(
        fixture: fixture,
        positions: points[..],
        indices: CONTAINMENT_BOX_CORNERS[..],
        reversed: reversed,
    );
}

fn uint append_octahedron_fixture(
    ContainmentFixture* fixture,
    Vec3 center,
    float radius = 1,
    bool reversed = false,
) @private {
    Vec3[6] points = {
        { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
    };
    foreach (&point : points) *point = center + *point * radius;
    return append_shell_fixture(
        fixture: fixture,
        positions: points[..],
        indices: CONTAINMENT_OCTAHEDRON_CORNERS[..],
        reversed: reversed,
    );
}

fn uint append_tetrahedron_fixture(ContainmentFixture* fixture, Vec3 origin, float extent = 0.25f) @private {
    Vec3[4] points = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    foreach (&point : points) *point = origin + *point * extent;
    return append_shell_fixture(
        fixture: fixture,
        positions: points[..],
        indices: CONTAINMENT_TETRAHEDRON_CORNERS[..],
        reversed: false,
    );
}

fn uint append_shell_fixture(
    ContainmentFixture* fixture,
    Vec3[] positions,
    uint[] indices,
    bool reversed,
) @local {
    uint first_vertex = fixture.vertex_count;
    uint first_face = fixture.triangle_count;
    foreach (uint index, point : positions) {
        uint vertex = first_vertex + index;
        fixture.positions[vertex] = point;
        fixture.identities[vertex] = vertex;
        for (uint axis = 0; axis < SPACE_AXES; axis++) fixture.grid[vertex][axis] = (long)(point[axis] * 4);
    }
    foreach (uint corner, vertex : indices) fixture.indices[first_face * TRIANGLE_CORNERS + corner] = first_vertex + vertex;
    fixture.vertex_count += (uint)positions.len;
    fixture.triangle_count += (uint)indices.len / TRIANGLE_CORNERS;
    if (reversed) {
        for (uint face = first_face; face < fixture.triangle_count; face++) {
            uint corner = face * TRIANGLE_CORNERS;
            uint saved = fixture.indices[corner + 1];
            fixture.indices[corner + 1] = fixture.indices[corner + 2];
            fixture.indices[corner + 2] = saved;
        }
    }
    fixture.mesh = {
        .geometry = {
            .positions = fixture.positions[:fixture.vertex_count],
            .indices = fixture.indices[:fixture.triangle_count * TRIANGLE_CORNERS],
        },
        .topology_vertices = fixture.identities[:fixture.vertex_count],
        .triangle_materials = fixture.materials[:fixture.triangle_count],
    };
    return first_face;
}

fn void check_containment_fixture(
    FractureWorkspace* workspace,
    ContainmentFixture* fixture,
    uint source_root,
    uint target_root,
    bool expected,
    ulong expected_candidates,
) @local {
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        assert(surface.validated && surface.topology.shell_count == 2);
        if (domain) {
            surface.grid = fixture.grid[:fixture.vertex_count];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        ulong candidates = 5;
        for (uint repeat = 1; repeat <= 2; repeat++) {
            assert(shell_contains(
                surface: &surface,
                source_root: source_root,
                target_root: target_root,
                candidate_faces: &candidates,
            )!! == expected);
            assert(candidates == 5 + repeat * expected_candidates);
            assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
            $if env::COMPILER_OPT_LEVEL == O3:
                assert(scratch.exact.filtered_count == 0);
            $endif
        }
    }
}
