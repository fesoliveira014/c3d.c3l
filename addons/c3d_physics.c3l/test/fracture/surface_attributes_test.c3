module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

struct SurfaceAttributeFixture @local {
    SolidFixture solid;
    Vec3[12] normals;
    Vec2[12] uv0;
    Vec2[12] uv1;
    Vec4[12] colors;
}

fn void test_surface_attributes_copy_corners_and_interpolate_exact_raw_grid_weights() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SurfaceAttributeFixture fixture;
        fill_attribute_fixture(&fixture);
        fixture.uv1[0].x = bitcast((uint)0x80000000, float);
        fixture.colors[0].z = bitcast((uint)1, float);
        GridPoint[4] grid = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.solid.mesh, &diagnostic)!!;
        if (domain) {
            surface.grid = grid[..];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        scratch.exact.peak = 0;
        SurfaceAttributes corner = source_surface_attributes(
            surface: &surface,
            face: 0,
            vertex: source.vertices[0],
            plane: &source.faces[0],
            reversed: source.reversed[0],
        )!!;
        assert(corner.corner == 0 && corner.edge[0] == NO_SOLID_INDEX && corner.edge[1] == NO_SOLID_INDEX);
        assert(corner.normal == fixture.normals[0] && corner.uv0 == fixture.uv0[0] && corner.color == fixture.colors[0]);
        assert(bitcast(corner.uv1.x, uint) == 0x80000000 && bitcast(corner.color.z, uint) == 1);
        fixture.colors[0].z = 0;
        ExactPlane[2] cuts;
        (void)plane_from_integers(scratch.exact, &cuts[0], { 1, -1, 0, 0 })!!;
        for (uint interior = 0; interior < 2; interior++) {
            if (domain) {
                (void)plane_from_integers(scratch.exact, &cuts[1], { 1, interior ? 2 : 1, 0, -1 })!!;
            } else {
                (void)plane_from_float(scratch.exact, &cuts[1], { { 1, 0, 0 }, { 0, interior ? 0.5f : 1.0f, 0 }, { 1, 0, 1 } })!!;
            }
            SurfaceAttributes attributes = source_surface_attributes(
                surface: &surface,
                face: 0,
                vertex: { &source.faces[0], &cuts[0], &cuts[1] },
                plane: &source.faces[0],
                reversed: source.reversed[0],
            )!!;
            assert(attributes.corner == NO_SOLID_INDEX);
            if (interior) {
                assert(attributes.edge[0] == NO_SOLID_INDEX && attributes.edge[1] == NO_SOLID_INDEX);
                assert(bitcast(attributes.uv0.x, uint) == 0x3eaaaaab && bitcast(attributes.uv0.y, uint) == 0x3eaaaaab);
                assert(bitcast(attributes.uv1.x, uint) == 0x3f2aaaab && attributes.uv1.y == 1);
                assert(bitcast(attributes.normal.x, uint) == 0x3f2aaaab && bitcast(attributes.normal.y, uint) == 0x3faaaaab);
                assert(attributes.normal.z == 2 && attributes.color.z == 0 && attributes.color.w == 1);
            } else {
                assert(attributes.edge[0] == 1 && attributes.edge[1] == 2);
                assert(attributes.uv0 == (Vec2){ 0.5f, 0.5f } && attributes.uv1 == (Vec2){ 1, 1.5f });
                assert(attributes.normal == (Vec3){ 0, 2, 3 });
                assert(attributes.color == (Vec4){ 0.5f, 0.5f, 0, 1 });
            }
        }
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_surface_attributes_keep_render_seams_at_shared_corners_and_edges() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SurfaceAttributeFixture fixture;
    fill_attribute_fixture(&fixture);
    Vec3[4] original;
    original[..] = fixture.solid.positions[:4];
    for (uint corner = 0; corner < 12; corner++) {
        uint identity = fixture.solid.indices[corner];
        fixture.solid.positions[corner] = original[identity];
        fixture.solid.identities[corner] = identity;
        fixture.solid.indices[corner] = corner;
        fixture.normals[corner] = corner < 3 ? (Vec3){ 0, 0, -2 } : (Vec3){ 0, -3, 0 };
        Vec3 point = original[identity];
        fixture.uv0[corner] = corner < 3 ? (Vec2){ point.x, point.y } : (Vec2){ 10 + point.x, 10 + point.z };
    }
    fixture.solid.mesh.geometry.positions = fixture.solid.positions[..];
    fixture.solid.mesh.topology_vertices = fixture.solid.identities[..];
    fixture.solid.mesh.geometry.normals = fixture.normals[..];
    fixture.solid.mesh.geometry.uv0 = fixture.uv0[..];
    fixture.solid.mesh.geometry.uv1 = {};
    fixture.solid.mesh.geometry.colors = {};
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(&scratch, fixture.solid.mesh, &diagnostic)!!;
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    ExactPlane cut;
    (void)plane_from_float(scratch.exact, &cut, { { 0.5f, 0, 0 }, { 0.5f, 1, 0 }, { 0.5f, 0, 1 } })!!;
    for (uint face = 0; face < 2; face++) {
        SurfaceAttributes corner = source_surface_attributes(
            surface: &surface,
            face: face,
            vertex: source.vertices[0],
            plane: &source.faces[face],
            reversed: source.reversed[face],
        )!!;
        assert(corner.corner == face * 3 && corner.normal == fixture.normals[face * 3]);
        SurfaceAttributes edge = source_surface_attributes(
            surface: &surface,
            face: face,
            vertex: { &source.faces[0], &source.faces[1], &cut },
            plane: &source.faces[face],
            reversed: source.reversed[face],
        )!!;
        assert(edge.edge[0] == (face ? 3 : 0) && edge.edge[1] == (face ? 4 : 2));
        assert(edge.normal == fixture.normals[face * 3]);
        assert(edge.uv0 == (face ? (Vec2){ 10.5f, 10 } : (Vec2){ 0.5f, 0 }));
        assert(edge.uv1 == (Vec2){} && edge.color == (Vec4){ 1, 1, 1, 1 });
    }
    assert(scratch.exact.count == 0);
}

fn void test_surface_attributes_resolve_near_ties_without_rounded_weights() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SurfaceAttributeFixture fixture;
        fill_attribute_fixture(&fixture);
        fixture.uv0[1].x = 1;
        fixture.uv0[2].x = bitcast((uint)0x3f800001, float);
        fixture.uv1[1].x = float::max;
        fixture.uv1[2].x = -float::max;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.solid.mesh, &diagnostic)!!;
        GridPoint[4] grid = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
        if (domain) {
            surface.grid = grid[..];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        ExactPlane sum;
        if (domain) {
            (void)plane_from_integers(scratch.exact, &sum, { 1, 1, 0, -1 })!!;
        } else {
            (void)plane_from_float(scratch.exact, &sum, { { 1, 0, 0 }, { 0, 1, 0 }, { 1, 0, 1 } })!!;
        }
        for (int offset = -1; offset <= 1; offset++) {
            ExactPlane cut;
            attribute_fraction_plane(
                scratch: scratch.exact,
                plane: &cut,
                numerator: ((int128)1 << 99) + offset,
                denominator: (int128)1 << 100,
                raw: domain == 0,
            );
            SurfaceAttributes attributes = source_surface_attributes(
                surface: &surface,
                face: 0,
                vertex: { &source.faces[0], &sum, &cut },
                plane: &source.faces[0],
                reversed: source.reversed[0],
            )!!;
            assert(bitcast(attributes.uv0.x, uint) == (offset < 0 ? 0x3f800001 : 0x3f800000));
            uint expected = offset == 0 ? 0 : (offset < 0 ? 0x80000000 : 0) | 0x4dffffff;
            assert(bitcast(attributes.uv1.x, uint) == expected);
            assert(attributes.edge[0] == 1 && attributes.edge[1] == 2 && scratch.exact.count == 0);
        }
    }
}

fn void test_surface_attributes_preserve_face_order_and_supply_missing_fields() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SurfaceAttributeFixture fixture;
    fill_attribute_fixture(&fixture);
    fixture.solid.mesh.geometry.normals = {};
    fixture.solid.mesh.geometry.uv0 = {};
    fixture.solid.mesh.geometry.uv1 = {};
    fixture.solid.mesh.geometry.colors = {};
    for (uint repeat = 0; repeat < 4; repeat++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.solid.mesh, &diagnostic)!!;
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        uint face = (4 - repeat) % 4;
        SurfaceAttributes attributes = source_surface_attributes(
            surface: &surface,
            face: face,
            vertex: source.vertices[0],
            plane: &source.faces[face],
            reversed: source.reversed[face],
        )!!;
        assert(attributes.corner == 0 && attributes.normal == (Vec3){ 0, 0, -1 });
        assert(attributes.uv0 == (Vec2){} && attributes.uv1 == (Vec2){} && attributes.color == (Vec4){ 1, 1, 1, 1 });
        uint[3] first;
        first[..] = fixture.solid.indices[:3];
        for (uint corner = 3; corner < 12; corner++) fixture.solid.indices[corner - 3] = fixture.solid.indices[corner];
        fixture.solid.indices[9:3] = first[..];
    }
}

fn void test_surface_attributes_cut_basis_matches_opposite_sides_and_plane_offsets() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    for (uint offset = 0; offset < 2; offset++) {
        ExactPlane plane;
        (void)plane_from_integers(scratch, &plane, { 0, 0, 1, offset ? -4 : 0 })!!;
        for (uint reversed = 0; reversed < 2; reversed++) {
            SurfaceAttributes attributes = cut_surface_attributes(
                scratch: scratch,
                plane: &plane,
                reversed: reversed != 0,
                position: { 2, 3, offset ? 4.0f : 0.0f },
                uv_density: 0.5f,
            )!!;
            assert(attributes.normal == (reversed ? (Vec3){ 0, 0, -1 } : (Vec3){ 0, 0, 1 }));
            assert(attributes.uv0 == (Vec2){ -1.5f, 1 } && attributes.uv1 == attributes.uv0);
            assert(attributes.color == (Vec4){ 1, 1, 1, 1 } && attributes.corner == NO_SOLID_INDEX);
        }
        SurfaceAttributes subnormal = cut_surface_attributes(
            scratch: scratch,
            plane: &plane,
            reversed: false,
            position: { 1, 0, offset ? 4.0f : 0.0f },
            uv_density: bitcast((uint)1, float),
        )!!;
        assert(bitcast(subnormal.uv0.y, uint) == 1);
        assert(@catch(cut_surface_attributes(
            scratch: scratch,
            plane: &plane,
            reversed: false,
            position: { float::max, float::max, offset ? 4.0f : 0.0f },
            uv_density: float::max,
        )) == NUMERICAL_FAILURE);
        assert(scratch.count == 0);
    }
}

fn void test_surface_attributes_capacity_failure_restores_held_values() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SurfaceAttributeFixture fixture;
    fill_attribute_fixture(&fixture);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(&scratch, fixture.solid.mesh, &diagnostic)!!;
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    for (uint available = 0; available < SURFACE_ATTRIBUTE_TEMPORARIES; available++) {
        uint held = EXACT_TEMPORARIES - available;
        scratch.exact.count = held;
        set_integer(&scratch.exact.values[held - 1], 913);
        assert(@catch(source_surface_attributes(
            surface: &surface,
            face: 0,
            vertex: source.vertices[0],
            plane: &source.faces[0],
            reversed: source.reversed[0],
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.exact.count == held && scratch.exact.values[held - 1].limbs[0] == 913);
    }
    scratch.exact.count = EXACT_TEMPORARIES - SURFACE_ATTRIBUTE_TEMPORARIES;
    SurfaceAttributes attributes = source_surface_attributes(
        surface: &surface,
        face: 0,
        vertex: source.vertices[0],
        plane: &source.faces[0],
        reversed: source.reversed[0],
    )!!;
    assert(attributes.corner == 0 && scratch.exact.count == EXACT_TEMPORARIES - SURFACE_ATTRIBUTE_TEMPORARIES);
    scratch.exact.count = 0;
}

fn void fill_attribute_fixture(SurfaceAttributeFixture* fixture) @local {
    *fixture = {};
    tetra_fixture(&fixture.solid);
    Vec3[4] normals = { { 2, 0, 0 }, { 0, 4, 0 }, { 0, 0, 6 }, { 2, 4, 6 } };
    fixture.normals[:4] = normals[..];
    for (uint index = 0; index < 4; index++) {
        Vec3 point = fixture.solid.positions[index];
        fixture.uv0[index] = { point.x, point.y };
        fixture.uv1[index] = { 2 * point.x, 3 * point.y };
        fixture.colors[index] = { point.x, point.y, point.z, 1 };
    }
    fixture.solid.mesh.geometry.normals = fixture.normals[:4];
    fixture.solid.mesh.geometry.uv0 = fixture.uv0[:4];
    fixture.solid.mesh.geometry.uv1 = fixture.uv1[:4];
    fixture.solid.mesh.geometry.colors = fixture.colors[:4];
}

fn void attribute_fraction_plane(
    ExactScratch* scratch,
    ExactPlane* plane,
    int128 numerator,
    int128 denominator,
    bool raw,
) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = scratch.take()!!;
    set_integer(coefficients[0], denominator);
    if (raw) {
        WideInteger* value = scratch.take()!!;
        set_integer(value, -numerator);
        shift_integer(coefficients[SPACE_AXES], value.view(), (uint)-FLOAT_UNIT_EXPONENT)!!;
        scratch.count--;
    } else {
        set_integer(coefficients[SPACE_AXES], -numerator);
    }
    (void)normalize_plane(scratch, plane, coefficients)!!;
}
