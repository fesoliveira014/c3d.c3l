module c3d::physics::fracture;

import c3d;
import std::math;

struct CollisionSurfaceFixture @local {
    Vec3[256] positions;
    uint[1536] indices;
    uint[256] identities;
    uint[512] materials;
    PlaneTriple[256] points;
    uint vertex_count;
    uint triangle_count;
    SolidMeshView mesh;
}

fn void test_collision_surface_shares_each_contact_triangle_with_opposite_winding() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell first = collision_test_box(
        scratch: &scratch, lower: { -2, -1, -1 }, upper: { 0, 1, 1 }, quantized: false,
    );
    ConvexCell second = collision_test_box(
        scratch: &scratch, lower: { 0, -1, -1 }, upper: { 2, 1, 1 }, quantized: false,
    );
    CollisionSurfaceSet set = build_collision_surfaces(&scratch, { &first, &second })!!;
    assert(set.patches.len == 11 && set.cells.len == 2);
    assert(assert_collision_surface_set(&scratch, &set) == 1);
    foreach (surface : set.cells) assert(surface.faces.len == 6);
    assert(first.faces.len == 6 && second.faces.len == 6 && scratch.exact.count == 0);
}

fn void test_collision_surface_reconciles_interior_and_edge_partial_face_contacts() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell first = collision_test_box(
            scratch: &scratch, lower: { -2, -2, -2 }, upper: { 0, 2, 2 }, quantized: false,
        );
        ConvexCell second = collision_test_box(
            scratch: &scratch,
            lower: variant ? (Vec3){ 0, 0, -2 } : (Vec3){ 0, -1, -1 },
            upper: variant ? (Vec3){ 2, 2, 0 } : (Vec3){ 2, 1, 1 },
            quantized: false,
        );
        CollisionSurfaceSet set = build_collision_surfaces(&scratch, { &first, &second })!!;
        assert(assert_collision_surface_set(&scratch, &set) == 1);
        assert(set.cells[0].faces.len > first.faces.len && set.cells[1].faces.len == second.faces.len);
        assert(scratch.exact.count == 0);
    }
}

fn void test_collision_surface_reconciles_crossed_subdivisions_without_overlapping_cones() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell[4] cells;
    cells[0] = collision_test_box(scratch: &scratch, lower: { -2, -2, -2 }, upper: { 0, 0, 2 }, quantized: false);
    cells[1] = collision_test_box(scratch: &scratch, lower: { -2, 0, -2 }, upper: { 0, 2, 2 }, quantized: false);
    cells[2] = collision_test_box(scratch: &scratch, lower: { 0, -2, -2 }, upper: { 2, 2, 0 }, quantized: false);
    cells[3] = collision_test_box(scratch: &scratch, lower: { 0, -2, 0 }, upper: { 2, 2, 2 }, quantized: false);
    CollisionSurfaceSet set = build_collision_surfaces(&scratch, { &cells[0], &cells[1], &cells[2], &cells[3] })!!;
    assert(assert_collision_surface_set(&scratch, &set) == 6);
    foreach (surface : set.cells) assert(surface.faces.len == 7);
    assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
}

fn void test_collision_surface_ignores_edge_and_point_only_contacts() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell first = collision_test_box(
            scratch: &scratch, lower: { -2, -1, -1 }, upper: { 0, 1, 1 }, quantized: false,
        );
        Vec3 lower = variant ? (Vec3){ 0, 1, 1 } : (Vec3){ 0, 1, -1 };
        ConvexCell second = collision_test_box(
            scratch: &scratch, lower: lower, upper: lower + (Vec3){ 2, 2, 2 }, quantized: false,
        );
        CollisionSurfaceSet set = build_collision_surfaces(&scratch, { &first, &second })!!;
        assert(set.patches.len == 12 && assert_collision_surface_set(&scratch, &set) == 0);
    }
}

fn void test_collision_surface_tetrahedra_keep_a_canonical_existing_anchor_and_zero_cones() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell cell = collision_test_box(
        scratch: &scratch, lower: { -2, -1, -1 }, upper: { 2, 1, 1 }, quantized: false,
    );
    CollisionSurfaceSet set = build_collision_surfaces(&scratch, { &cell })!!;
    CollisionSurface* surface = &set.cells[0];
    CollisionTetrahedra first = tetrahedralize_collision_surface(&scratch, surface)!!;
    assert(first.tetrahedra.len == 6);
    assert(rounded_source_position(scratch.exact, first.anchor)!! == (Vec3){ -2, -1, -1 });
    uint zeros;
    foreach (face : surface.faces) foreach (uint index, unused : face.shared.triangles) {
        uint[TRIANGLE_CORNERS] triangle = oriented_patch_triangle(face, index);
        CollisionTet cone = { .vertices = {
            first.anchor, face.shared.vertices[triangle[0]], face.shared.vertices[triangle[1]], face.shared.vertices[triangle[2]],
        } };
        if (!exact_vertex_orientation(scratch.exact, cone.vertices)!!) {
            zeros++;
            assert(collision_tet_volume(scratch.exact, cone) == 0);
        }
    }
    assert(zeros == 6);
    for (usz index = 0; index < surface.faces.len / 2; index++) {
        OrientedPatchTriangles swap = surface.faces[index];
        surface.faces[index] = surface.faces[surface.faces.len - index - 1];
        surface.faces[surface.faces.len - index - 1] = swap;
    }
    CollisionTetrahedra repeated = tetrahedralize_collision_surface(&scratch, surface)!!;
    assert(same_vertex(scratch.exact, first.anchor, repeated.anchor)!!);
    assert(first.tetrahedra.len == repeated.tetrahedra.len);
    assert_collision_surface_set(&scratch, &set);
}

fn void test_collision_surface_closes_all_merged_raw_partition_shapes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, false);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        CollisionCell[] merged = merge_collision_cells(&scratch, &partition, 64)!!;
        ConvexCell*[] cells = reserve_elements(&scratch, ConvexCell*, merged.len)!!;
        foreach (index, &cell : merged) cells[index] = &cell.cell;
        CollisionSurfaceSet set = build_collision_surfaces(&scratch, cells)!!;
        assert_collision_surface_set(&scratch, &set);
        assert(set.cells.len == merged.len && scratch.exact.count == 0);
    }
}

fn void test_collision_surface_capacity_failures_restore_cursors_and_allow_reuse() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell first = collision_test_box(
        scratch: &scratch, lower: { -2, -2, -2 }, upper: { 0, 2, 2 }, quantized: false,
    );
    ConvexCell second = collision_test_box(
        scratch: &scratch, lower: { 0, -1, -1 }, upper: { 2, 1, 1 }, quantized: false,
    );
    usz saved = scratch.used;
    scratch.peak = saved;
    CollisionSurfaceSet complete = build_collision_surfaces(&scratch, { &first, &second })!!;
    usz required = scratch.peak;
    for (usz capacity = saved; capacity < required; capacity += 8191) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(build_collision_surfaces(&scratch, { &first, &second })) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage;
    scratch.exact.count = EXACT_TEMPORARIES;
    set_integer(&scratch.exact.values[EXACT_TEMPORARIES - 1], 913);
    assert(@catch(build_collision_surfaces(&scratch, { &first, &second })) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == EXACT_TEMPORARIES);
    assert(scratch.exact.values[EXACT_TEMPORARIES - 1].limbs[0] == 913);
    scratch.exact.count = 0;
    complete = build_collision_surfaces(&scratch, { &first, &second })!!;
    assert(assert_collision_surface_set(&scratch, &complete) == 1);
    saved = scratch.used;
    CollisionTetrahedra tets = tetrahedralize_collision_surface(&scratch, &complete.cells[0])!!;
    usz retained = scratch.used;
    scratch.used = saved;
    scratch.storage = workspace.storage[:retained - 1];
    assert(@catch(tetrahedralize_collision_surface(&scratch, &complete.cells[0])) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    scratch.storage = workspace.storage;
    scratch.exact.count = 5;
    set_integer(&scratch.exact.values[4], 913);
    assert(@catch(tetrahedralize_collision_surface(&scratch, &complete.cells[0])) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 5 && scratch.exact.values[4].limbs[0] == 913);
    scratch.exact.count = 0;
    CollisionTetrahedra repeated = tetrahedralize_collision_surface(&scratch, &complete.cells[0])!!;
    assert(repeated.tetrahedra.len == tets.tetrahedra.len && same_vertex(scratch.exact, repeated.anchor, tets.anchor)!!);
}

fn uint assert_collision_surface_set(SolidScratch* scratch, CollisionSurfaceSet* set) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    assert(set.patches.len == set.triangles.len);
    uint shared_count;
    foreach (uint index, &triangles : set.triangles) {
        assert(triangles.vertices.ptr == set.patches[index].boundary.vertices.ptr && triangles.triangles.len > 0);
        uint uses;
        bool reversed;
        foreach (surface : set.cells) foreach (face : surface.faces) {
            if (face.shared != triangles) continue;
            if (uses) assert(face.reversed != reversed);
            reversed = face.reversed;
            uses++;
        }
        assert(uses == 1 || uses == 2);
        if (uses == 2) shared_count++;
    }
    foreach (&surface : set.cells) {
        usz retained = scratch.used;
        defer scratch.used = retained;
        CollisionSurfaceFixture fixture;
        fill_collision_surface_fixture(scratch.exact, surface, &fixture);
        SolidDiagnostic diagnostic;
        ValidatedSolid validated = validate_solid(
            scratch: scratch, source: fixture.mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        assert(validated.nesting.shells.len == 1 && validated.nesting.shells[0].depth == 0);
        CollisionTetrahedra tetrahedra = tetrahedralize_collision_surface(scratch, surface)!!;
        double volume;
        foreach (tetrahedron : tetrahedra.tetrahedra) {
            assert(exact_vertex_orientation(scratch.exact, tetrahedron.vertices)!! > 0);
            foreach (point : tetrahedron.vertices) foreach (face : surface.cell.faces) {
                int side = plane_side(scratch.exact, face.plane, point)!!;
                assert(face.reversed ? side >= 0 : side <= 0);
            }
            volume += collision_tet_volume(scratch.exact, tetrahedron);
        }
        double expected = math::scalbn(cell_volume(scratch.exact, surface.cell), (int)SPACE_AXES * FLOAT_UNIT_EXPONENT);
        assert(math::abs(volume - expected) < expected * 1e-12 && scratch.exact.count == 0);
    }
    return shared_count;
}

fn void fill_collision_surface_fixture(
    ExactScratch* scratch,
    CollisionSurface* surface,
    CollisionSurfaceFixture* fixture,
) @local {
    *fixture = {};
    foreach (face : surface.faces) foreach (uint index, unused : face.shared.triangles) {
        uint[TRIANGLE_CORNERS] triangle = oriented_patch_triangle(face, index);
        foreach (uint corner, vertex : triangle) {
            PlaneTriple point = face.shared.vertices[vertex];
            uint identity;
            while (identity < fixture.vertex_count && !same_vertex(scratch, point, fixture.points[identity])!!) identity++;
            if (identity == fixture.vertex_count) {
                fixture.points[identity] = point;
                fixture.positions[identity] = rounded_source_position(scratch, point)!!;
                fixture.identities[identity] = identity;
                fixture.vertex_count++;
            }
            fixture.indices[fixture.triangle_count * TRIANGLE_CORNERS + corner] = identity;
        }
        fixture.triangle_count++;
    }
    fixture.mesh = {
        .geometry = { .positions = fixture.positions[:fixture.vertex_count], .indices = fixture.indices[:fixture.triangle_count * TRIANGLE_CORNERS] },
        .topology_vertices = fixture.identities[:fixture.vertex_count],
        .triangle_materials = fixture.materials[:fixture.triangle_count],
    };
}

fn double collision_tet_volume(ExactScratch* scratch, CollisionTet tetrahedron) @local {
    double[<3>][HOMOGENEOUS_COMPONENTS] positions;
    foreach (uint index, vertex : tetrahedron.vertices) {
        Vec3 point = rounded_source_position(scratch, vertex)!!;
        positions[index] = { point.x, point.y, point.z };
    }
    double[<3>] first = positions[1] - positions[0];
    double[<3>] second = positions[2] - positions[0];
    double[<3>] third = positions[3] - positions[0];
    return first.dot(second.cross(third)) / 6;
}


fn void test_collision_surface_face_order_keeps_partial_contact_triangulation_identical() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell[2] cells = {
        collision_test_box(scratch: &scratch, lower: { -2, -2, -2 }, upper: { 0, 2, 2 }, quantized: false),
        collision_test_box(scratch: &scratch, lower: { 0, -1, -1 }, upper: { 2, 1, 1 }, quantized: false),
    };
    CollisionSurfaceSet first = build_collision_surfaces(&scratch, { &cells[0], &cells[1] })!!;
    ConvexCell[2] permuted;
    foreach (uint index, cell : cells) {
        permuted[index] = {
            .vertices = cell.vertices,
            .faces = reserve_elements(&scratch, CellFace, cell.faces.len)!!,
            .corners = reserve_elements(&scratch, CellCorner, cell.corners.len)!!,
        };
        for (uint face = 0; face < cell.faces.len; face++) {
            permuted[index].faces[face] = cell.faces[cell.faces.len - face - 1];
        }
        foreach (uint corner, value : cell.corners) {
            permuted[index].corners[corner] = value;
            permuted[index].corners[corner].face = (uint)cell.faces.len - value.face - 1;
        }
    }
    CollisionSurfaceSet repeated = build_collision_surfaces(&scratch, { &permuted[0], &permuted[1] })!!;
    assert(first.patches.len == repeated.patches.len);
    foreach (uint index, &patch : first.patches) {
        assert(!compare_exact_planes(patch.plane, repeated.patches[index].plane));
        PatchTriangles* left = &first.triangles[index];
        PatchTriangles* right = &repeated.triangles[index];
        assert(left.vertices.len == right.vertices.len && left.triangles.len == right.triangles.len);
        foreach (uint vertex, point : left.vertices) assert(same_vertex(scratch.exact, point, right.vertices[vertex])!!);
        foreach (uint triangle, value : left.triangles) assert(value.vertices == right.triangles[triangle].vertices);
    }
    assert_collision_surface_set(&scratch, &first);
    assert_collision_surface_set(&scratch, &repeated);
}
