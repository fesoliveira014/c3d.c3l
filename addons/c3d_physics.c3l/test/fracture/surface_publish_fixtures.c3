module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

struct PublishFixture @private {
    SolidSurface surface;
    SourceConstructions source;
    SurfacePiece[] pieces;
    SurfaceVolumeReference reference;
}

fn FractureLimits publish_limits() @private {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes = 4194304;
    limits.max_vertices = 512;
    limits.max_triangles = 512;
    return limits;
}

fn void prepare_publish_source(
    SolidScratch* scratch,
    PublishFixture* fixture,
    SolidMeshView mesh,
    GridPoint[] grid = {},
) @private {
    SolidDiagnostic diagnostic;
    fixture.surface = build_solid_surface(scratch, mesh, &diagnostic)!!;
    if (grid.len) {
        fixture.surface.grid = grid;
        check_surface_geometry(&fixture.surface, &diagnostic)!!;
    }
    SolidNesting nesting = build_solid_nesting(scratch, &fixture.surface, &diagnostic)!!;
    fixture.reference.coordinate_exponent = grid.len ? -2 : FLOAT_UNIT_EXPONENT;
    foreach (&shell : nesting.shells) accumulate_surface_volume(scratch.exact, &fixture.reference.six_volume, shell.six_volume.view())!!;
    fixture.source = build_source_constructions(scratch, &fixture.surface)!!;
}

fn void prepare_uncut_publication(SolidScratch* scratch, PublishFixture* fixture, uint shape = 0) @private {
    SourceConstructions* source = &fixture.source;
    uint piece_count = shape == 2 || shape == 3 ? 2 : 1;
    fixture.pieces = reserve_elements(scratch, SurfacePiece, piece_count)!!;
    for (uint piece = 0; piece < piece_count; piece++) {
        fixture.pieces[piece] = { .patches = reserve_elements(scratch, SurfacePatch, source.faces.len)!! };
    }
    uint[2] counts;
    foreach (uint face, &plane : source.faces) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(&fixture.surface, face);
        PlanarSegment[TRIANGLE_CORNERS] segments;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            SourceEdge* edge = &source.edges[source.corner_edges[face * TRIANGLE_CORNERS + corner]];
            segments[corner] = {
                .first = source.vertices[triangle[corner]],
                .second = source.vertices[triangle[(corner + 1) % TRIANGLE_CORNERS]],
                .line = { &source.faces[edge.owner_corner / TRIANGLE_CORNERS], &edge.plane },
            };
        }
        BoundaryPatch boundary = create_boundary_patch(
            scratch: scratch, plane: plane, segments: segments[..], reversed: source.reversed[face],
        )!!;
        boundary.source_face = face;
        boundary.source_corners[..] = fixture.surface.source.geometry.indices[face * TRIANGLE_CORNERS:TRIANGLE_CORNERS];
        boundary.source_key = canonical_surface_triangle(triangle);
        boundary.unchanged = true;
        PatchTriangles* triangles = &reserve_elements(scratch, PatchTriangles, 1)!![0];
        *triangles = triangulate_boundary_patch(scratch, &boundary)!!;
        uint owner = shape == 2 ? (triangle[0] >= 16 ? 1 : 0) : shape == 3 ? (triangle[0] >= 8 ? 1 : 0) : 0;
        fixture.pieces[owner].patches[counts[owner]++] = {
            .boundary = boundary,
            .triangulation = { .shared = triangles, .reversed = boundary.reversed },
            .source = &fixture.surface,
        };
    }
    foreach (uint piece, &value : fixture.pieces) value.patches = value.patches[:counts[piece]];
}

fn FractureResult publish_fixture(
    SolidScratch* scratch,
    PublishFixture* fixture,
    FractureLimits limits,
    QuantizationGrid* grid = null,
    Allocator allocator = mem,
) @private {
    return publish_surface_pieces(
        allocator: allocator, scratch: scratch, limits: limits, pieces: fixture.pieces,
        grid: grid, cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )!!;
}

fn void assert_published_valid(SolidScratch* scratch, FractureResult result) @private {
    foreach (piece : result.pieces) {
        usz saved = scratch.used;
        defer scratch.used = saved;
        SolidDiagnostic diagnostic;
        ValidatedSolid validated = validate_solid(
            scratch: scratch, source: piece.mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        assert(validated.surface.validated && finite_position(piece.origin));
        foreach (uint index, identity : piece.mesh.topology_vertices) {
            assert(identity < validated.surface.topology.vertices.len);
            assert(finite_position(piece.mesh.geometry.normals[index]));
        }
    }
}

fn void assert_same_publication(FractureResult first, FractureResult second) @private {
    assert(first.pieces.len == second.pieces.len);
    foreach (uint index, left : first.pieces) {
        FracturePieceView right = second.pieces[index];
        for (uint axis = 0; axis < SPACE_AXES; axis++) assert(bitcast(left.origin[axis], uint) == bitcast(right.origin[axis], uint));
        SolidMeshView a = left.mesh;
        SolidMeshView b = right.mesh;
        assert_publish_bytes(a.geometry.positions, b.geometry.positions);
        assert_publish_bytes(a.geometry.normals, b.geometry.normals);
        assert_publish_bytes(a.geometry.uv0, b.geometry.uv0);
        assert_publish_bytes(a.geometry.uv1, b.geometry.uv1);
        assert_publish_bytes(a.geometry.colors, b.geometry.colors);
        assert_publish_bytes(a.geometry.tangents, b.geometry.tangents);
        assert(a.geometry.indices == b.geometry.indices && a.triangle_materials == b.triangle_materials);
        assert(a.topology_vertices == b.topology_vertices);
    }
}

fn void append_publish_cell(SolidScratch* scratch, SolidPartition* partition, ConvexCell cell) @local {
    if (!cell.vertices.len) return;
    PartitionCell* entry = &reserve_elements(scratch, PartitionCell, 1)!![0];
    *entry = { .cell = cell, .next = partition.first, .occupied = true };
    partition.first = entry;
    partition.cell_count++;
    partition.occupied_count++;
}

fn void prepare_cut_publication(
    SolidScratch* scratch,
    PublishFixture* fixture,
    ExactPlane* cut,
    bool separated = false,
) @private {
    SolidPartition partition = partition_solid(scratch, &fixture.surface, &fixture.source)!!;
    SolidPartition[2] sides;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        CellSplit split = split_convex_cell(scratch, &cell.cell, cut)!!;
        append_publish_cell(scratch, &sides[0], split.negative);
        append_publish_cell(scratch, &sides[1], split.positive);
    }
    BoundaryPatch[][2] source_patches;
    foreach (uint side, &value : sides) source_patches[side] = source_boundary_patches(
        scratch: scratch, surface: &fixture.surface, source: &fixture.source,
        partition: value, cuts: { cut },
    )!!;
    BoundaryPatch[] boundaries = reserve_elements(scratch, BoundaryPatch, source_patches[0].len + source_patches[1].len + 1)!!;
    boundaries[:source_patches[0].len] = source_patches[0][..];
    boundaries[source_patches[0].len:source_patches[1].len] = source_patches[1][..];
    boundaries[^1] = create_boundary_patch(
        scratch: scratch, plane: cut, segments: collect_boundary_segments(scratch, &sides[0], cut)!!, reversed: false,
    )!!;
    reconcile_patch_boundaries(scratch, boundaries)!!;
    fixture.pieces = reserve_elements(scratch, SurfacePiece, separated ? 3 : 2)!!;
    foreach (&piece : fixture.pieces) *piece = { .patches = reserve_elements(scratch, SurfacePatch, boundaries.len)!! };
    uint[3] counts;
    foreach (uint index, boundary : boundaries[:boundaries.len - 1]) {
        PatchTriangles* triangles = &reserve_elements(scratch, PatchTriangles, 1)!![0];
        *triangles = triangulate_boundary_patch(scratch, &boundary)!!;
        uint owner = index < source_patches[0].len ? 0 : 1;
        if (separated && owner) {
            Vec3 point = rounded_source_position(scratch.exact, boundary.boundary.vertices[0])!!;
            if (point.x > 1.5f) owner = 2;
        }
        fixture.pieces[owner].patches[counts[owner]++] = {
            .boundary = boundary, .triangulation = { .shared = triangles, .reversed = boundary.reversed },
            .source = &fixture.surface,
        };
    }
    OrientedPatchTriangles[2] common = triangulate_shared_cut(scratch, &boundaries[^1])!!;
    foreach (uint owner, &piece : fixture.pieces) {
        SurfacePatch cap = {
            .boundary = boundaries[^1], .triangulation = common[owner ? 1 : 0],
            .source = &fixture.surface, .cut = true, .shared_cut = true,
        };
        if (separated && owner) {
            uint[] selection = reserve_elements(scratch, uint, common[0].shared.triangles.len)!!;
            uint selected;
            foreach (uint index, triangle : common[0].shared.triangles) {
                Vec3 point = rounded_source_position(scratch.exact, common[0].shared.vertices[triangle.vertices[0]])!!;
                if ((point.x > 1.5f ? 2 : 1) == owner) selection[selected++] = index;
            }
            cap.selection = selection[:selected];
            assert(selected);
        }
        piece.patches[counts[owner]++] = cap;
        piece.patches = piece.patches[:counts[owner]];
    }
}

fn void publish_u_fixture(ContainmentFixture* fixture) @private {
    Vec3[16] positions = {
        { 0, 0, 0 }, { 3, 0, 0 }, { 3, 3, 0 }, { 2, 3, 0 },
        { 2, 1, 0 }, { 1, 1, 0 }, { 1, 3, 0 }, { 0, 3, 0 },
        { 0, 0, 1 }, { 3, 0, 1 }, { 3, 3, 1 }, { 2, 3, 1 },
        { 2, 1, 1 }, { 1, 1, 1 }, { 1, 3, 1 }, { 0, 3, 1 },
    };
    uint[18] top = { 1, 2, 3, 1, 3, 4, 0, 1, 4, 0, 4, 5, 7, 0, 5, 5, 6, 7 };
    uint[84] indices;
    uint count;
    for (uint triangle = 0; triangle < 6; triangle++) {
        uint first = top[triangle * 3];
        uint second = top[triangle * 3 + 1];
        uint third = top[triangle * 3 + 2];
        indices[count++] = first; indices[count++] = third; indices[count++] = second;
        indices[count++] = first + 8; indices[count++] = second + 8; indices[count++] = third + 8;
    }
    for (uint first = 0; first < 8; first++) {
        uint second = (first + 1) % 8;
        indices[count++] = first; indices[count++] = second; indices[count++] = second + 8;
        indices[count++] = first; indices[count++] = second + 8; indices[count++] = first + 8;
    }
    append_shell_fixture(fixture: fixture, positions: positions[..], indices: indices[..], reversed: false);
}


macro assert_publish_bytes(actual, expected) @local {
    assert(actual.len == expected.len);
    char[] first = ((char*)actual.ptr)[:actual.len * @sizeof(actual[0])];
    char[] second = ((char*)expected.ptr)[:expected.len * @sizeof(expected[0])];
    assert(first == second);
}
