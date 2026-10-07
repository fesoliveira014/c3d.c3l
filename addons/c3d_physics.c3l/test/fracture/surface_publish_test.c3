module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

fn void test_surface_publish_preserves_all_authored_streams_with_actual_vertex_cap() @test {
    FractureLimits limits = publish_limits();
    limits.max_vertices = 4;
    limits.max_triangles = 4;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidFixture source;
    tetra_fixture(&source);
    Vec3[12] normals;
    Vec4[12] tangents;
    Vec2[12] uv0;
    Vec2[12] uv1;
    Vec4[12] colors;
    for (uint vertex = 0; vertex < 12; vertex++) {
        normals[vertex] = { 0, 0, 1 };
        tangents[vertex] = { 1, 0, 0, 1 };
        uv0[vertex] = { source.positions[vertex].x, source.positions[vertex].y };
        uv1[vertex] = { 2 * source.positions[vertex].x, 3 * source.positions[vertex].y };
        colors[vertex] = { source.positions[vertex].x, source.positions[vertex].y, source.positions[vertex].z, 1 };
        source.identities[vertex] = vertex;
    }
    uv1[0].x = bitcast((uint)0x80000000, float);
    source.mesh.geometry.positions = source.positions[..];
    source.mesh.topology_vertices = source.identities[..];
    source.mesh.geometry.normals = normals[..];
    source.mesh.geometry.tangents = tangents[..];
    source.mesh.geometry.uv0 = uv0[..];
    source.mesh.geometry.uv1 = uv1[..];
    source.mesh.geometry.colors = colors[..];
    foreach (uint face, &material : source.mesh.triangle_materials) *material = face + 10;
    SolidScratch scratch = begin_solid_scratch(&workspace);
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    prepare_uncut_publication(&scratch, &fixture);
    usz saved = scratch.used;
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureResult result = publish_fixture(scratch: &scratch, fixture: &fixture, limits: limits, allocator: &tracker);
    defer destroy_fracture_result(&result);
    assert(scratch.used == saved && scratch.exact.count == 0 && tracker.total_allocation_count() == 1);
    assert(result.pieces.len == 1);
    FracturePieceView piece = result.pieces[0];
    assert(piece.origin == (Vec3){ 0.25f, 0.25f, 0.25f });
    Geometry geometry = piece.mesh.geometry;
    assert(geometry.positions.len == 4 && geometry.indices.len == 12);
    foreach (uint vertex, position : geometry.positions) {
        uint original = NO_SOLID_INDEX;
        for (uint candidate = 0; candidate < 4; candidate++) if (position + piece.origin == source.positions[candidate]) original = candidate;
        assert(original != NO_SOLID_INDEX);
        assert(geometry.normals[vertex] == normals[original] && geometry.tangents[vertex] == tangents[original]);
        assert(geometry.uv0[vertex] == uv0[original] && geometry.uv1[vertex] == uv1[original]);
        assert(bitcast(geometry.uv1[vertex].x, uint) == bitcast(uv1[original].x, uint));
        assert(geometry.colors[vertex] == colors[original]);
    }
    foreach (uint face, material : piece.mesh.triangle_materials) {
        assert(material >= 10 && material < 14);
        uint original = material - 10;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            Vec3 position = geometry.positions[geometry.indices[face * TRIANGLE_CORNERS + corner]] + piece.origin;
            bool found;
            for (uint candidate = 0; candidate < TRIANGLE_CORNERS; candidate++) found |= position == source.positions[source.indices[original * TRIANGLE_CORNERS + candidate]];
            assert(found);
        }
    }
    assert_published_valid(&scratch, result);
}

fn void test_surface_publish_preserves_concavity_cavities_islands_and_input_order() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    uint[5] expected = { 1, 1, 2, 2, 1 };
    for (uint shape = 0; shape < expected.len; shape++) for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture source;
        partition_fixture(&source, shape);
        PublishFixture fixture;
        prepare_publish_source(
            scratch: &scratch, fixture: &fixture, mesh: source.mesh,
            grid: domain ? source.grid[:source.vertex_count] : (GridPoint[]){},
        );
        prepare_uncut_publication(&scratch, &fixture, shape);
        QuantizationGrid grid = { .step_exponent = -2 };
        FractureResult first = publish_fixture(scratch: &scratch, fixture: &fixture, limits: limits, grid: domain ? &grid : null);
        defer destroy_fracture_result(&first);
        assert(first.pieces.len == expected[shape]);
        usz triangles;
        foreach (piece : first.pieces) {
            Geometry geometry = piece.mesh.geometry;
            triangles += geometry.indices.len / TRIANGLE_CORNERS;
            assert(geometry.normals.len == geometry.positions.len);
            assert(!geometry.uv0.len && !geometry.uv1.len && !geometry.colors.len && !geometry.tangents.len);
        }
        assert(triangles == source.triangle_count);
        assert_published_valid(&scratch, first);
        foreach (&piece : fixture.pieces) {
            for (usz index = 0; index < piece.patches.len / 2; index++) {
                SurfacePatch saved = piece.patches[index];
                piece.patches[index] = piece.patches[piece.patches.len - index - 1];
                piece.patches[piece.patches.len - index - 1] = saved;
            }
        }
        if (fixture.pieces.len == 2) {
            SurfacePiece saved = fixture.pieces[0];
            fixture.pieces[0] = fixture.pieces[1];
            fixture.pieces[1] = saved;
        }
        FractureResult repeated = publish_fixture(scratch: &scratch, fixture: &fixture, limits: limits, grid: domain ? &grid : null);
        defer destroy_fracture_result(&repeated);
        assert_same_publication(first, repeated);
        assert(scratch.exact.count == 0);
    }
}

fn void test_surface_publish_shared_caps_keep_opposite_winding_and_explicit_attributes() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    partition_fixture(&source, 0);
    Vec2[24] uv1;
    Vec4[24] colors;
    uv1[..] = { 4, 7 };
    colors[..] = { 0.25f, 0.5f, 0.75f, 1 };
    source.mesh.geometry.uv1 = uv1[:source.vertex_count];
    source.mesh.geometry.colors = colors[:source.vertex_count];
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    ExactPlane cut;
    plane_from_integers(scratch.exact, &cut, { 1, 0, 0, 0 })!!;
    prepare_cut_publication(scratch: &scratch, fixture: &fixture, cut: &cut);
    FractureResult result = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&result);
    assert(result.pieces.len == 2);
    assert_published_valid(&scratch, result);
    uint[2] caps;
    foreach (uint owner, piece : result.pieces) {
        Geometry geometry = piece.mesh.geometry;
        assert(geometry.uv0.len == geometry.positions.len && geometry.uv1.len == geometry.positions.len);
        assert(geometry.colors.len == geometry.positions.len && geometry.tangents.len == geometry.positions.len);
        foreach (uint face, material : piece.mesh.triangle_materials) {
            if (material != 17) continue;
            caps[owner]++;
            Vec3[3] triangle;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                uint vertex = geometry.indices[face * TRIANGLE_CORNERS + corner];
                Vec3 point = geometry.positions[vertex] + piece.origin;
                triangle[corner] = point;
                assert(point.x == 0);
                assert(geometry.normals[vertex] == (Vec3){ owner ? -1 : 1, 0, 0 });
                assert(geometry.uv0[vertex] == (Vec2){ -2 * point.z, 2 * point.y });
                assert(geometry.uv1[vertex] == geometry.uv0[vertex]);
                assert(geometry.colors[vertex] == (Vec4){ 1, 1, 1, 1 });
                assert(finite_position(geometry.tangents[vertex].xyz));
            }
            Vec3 normal = (triangle[1] - triangle[0]).cross(triangle[2] - triangle[0]);
            assert(owner ? normal.x < 0 : normal.x > 0);
        }
    }
    assert(caps[0] && caps[0] == caps[1]);
    SurfacePatch* positive = &fixture.pieces[1].patches[^1];
    positive.selection = reserve_elements(&scratch, uint, positive.triangulation.shared.triangles.len)!!;
    foreach (uint index, &selection : positive.selection) *selection = (uint)positive.selection.len - index - 1;
    FractureResult permuted = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&permuted);
    assert_same_publication(result, permuted);
    PatchTriangles copied_record = *positive.triangulation.shared;
    PatchTriangles* shared = positive.triangulation.shared;
    positive.triangulation.shared = &copied_record;
    assert(@catch(publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 },
    )) == NON_MANIFOLD_RESULT);
    positive.triangulation.shared = shared;
    positive.shared_cut = false;
    assert(@catch(publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 },
    )) == NON_MANIFOLD_RESULT);
}

fn void test_surface_publish_shared_triangle_subsets_allow_two_positive_components() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    publish_u_fixture(&source);
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    ExactPlane cut;
    bounds_axis_plane(scratch: scratch.exact, plane: &cut, axis: 1, bound: (long)bitcast(2.0f, uint), quantized: false)!!;
    prepare_cut_publication(scratch: &scratch, fixture: &fixture, cut: &cut, separated: true);
    FractureResult result = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&result);
    assert(result.pieces.len == 3);
    assert_published_valid(&scratch, result);
    SurfacePatch negative = fixture.pieces[0].patches[^1];
    SurfacePatch left = fixture.pieces[1].patches[^1];
    SurfacePatch right = fixture.pieces[2].patches[^1];
    assert(!negative.selection.len && left.selection.len && right.selection.len);
    assert(left.selection.len + right.selection.len == negative.triangulation.shared.triangles.len);
    assert(left.triangulation.shared == negative.triangulation.shared && right.triangulation.shared == negative.triangulation.shared);
    SurfacePiece saved = fixture.pieces[0];
    fixture.pieces[0] = fixture.pieces[2];
    fixture.pieces[2] = saved;
    FractureResult repeated = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&repeated);
    assert_same_publication(result, repeated);
}


fn void test_surface_publish_distinguishes_topology_failures_and_float_failures() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    for (uint variant = 0; variant < 3; variant++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidFixture source;
        tetra_fixture(&source);
        if (variant == 1) {
            float magnitude = bitcast((uint)0x7f7fffff, float);
            Vec3[4] extreme = {
                { -magnitude, -magnitude, -magnitude }, { magnitude, -magnitude, -magnitude },
                { -magnitude, magnitude, -magnitude }, { -magnitude, -magnitude, magnitude },
            };
            source.positions[:4] = extreme[..];
        } else if (variant == 2) {
            float next = bitcast((uint)0x3f800001, float);
            Vec3[4] tiny = { { 1, 1, 1 }, { next, 1, 1 }, { 1, next, 1 }, { 1, 1, next } };
            source.positions[:4] = tiny[..];
            limits.resolution_m = bitcast((uint)0x335db3d7, float);
        }
        PublishFixture fixture;
        prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
        prepare_uncut_publication(&scratch, &fixture);
        if (!variant) fixture.pieces[0].patches = fixture.pieces[0].patches[:3];
        usz saved = scratch.used;
        fault expected = variant ? NUMERICAL_FAILURE : NON_MANIFOLD_RESULT;
        assert(@catch(publish_surface_pieces(
            allocator: &tracker, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
            cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
        )) == expected);
        assert(scratch.used == saved && scratch.exact.count == 0 && tracker.total_allocation_count() == 0);
        if (variant == 2) {
            limits.resolution_m = bitcast((uint)0x335db3d8, float);
            FractureResult recovered = publish_fixture(&scratch, &fixture, limits);
            defer destroy_fracture_result(&recovered);
            assert_published_valid(&scratch, recovered);
        }
    }
}

fn void test_surface_publish_rejects_exact_distinct_vertices_collapsed_by_float_conversion() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    append_box_fixture(&source, { 1, -1, -1 }, { 2, 1, 1 });
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    ExactPlane cut;
    {
        uint saved = scratch.exact.count;
        defer scratch.exact.count = saved;
        WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
        foreach (&value : coefficients) *value = scratch.exact.take()!!;
        set_integer(coefficients[0], 33554432);
        set_integer(coefficients[1], 0);
        set_integer(coefficients[2], 0);
        WideInteger* offset = scratch.exact.take()!!;
        set_integer(offset, -33554433);
        shift_integer(coefficients[3], offset.view(), (uint)-FLOAT_UNIT_EXPONENT)!!;
        (void)normalize_plane(scratch.exact, &cut, coefficients)!!;
    }
    prepare_cut_publication(scratch: &scratch, fixture: &fixture, cut: &cut);
    usz saved = scratch.used;
    assert(@catch(publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0);
}

fn void test_surface_publish_volume_bound_is_inclusive_without_extra_tolerance() @test {
    FractureLimits limits = publish_limits();
    limits.resolution_m = 0.125f;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    partition_fixture(&source, 0);
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    prepare_uncut_publication(&scratch, &fixture);
    FractureResult baseline = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&baseline);
    {
        usz saved = scratch.used;
        defer scratch.used = saved;
        SolidDiagnostic diagnostic;
        ValidatedSolid published = validate_solid(
            scratch: &scratch, source: baseline.pieces[0].mesh, grid: null, diagnostic: &diagnostic,
        )!!;
        fixture.reference.six_volume = {};
        foreach (&shell : published.nesting.shells) accumulate_surface_volume(scratch.exact, &fixture.reference.six_volume, shell.six_volume.view())!!;
        PlaneInteger bound = float_rounding_volume_bound(&published.surface, limits.resolution_m)!!;
        accumulate_surface_volume(scratch.exact, &fixture.reference.six_volume, bound.view())!!;
    }
    FractureResult at_bound = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&at_bound);
    assert_same_publication(baseline, at_bound);
    assert(fixture.reference.six_volume.limbs[0] != ulong::max);
    fixture.reference.six_volume.limbs[0]++;
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    usz saved = scratch.used;
    assert(@catch(publish_surface_pieces(
        allocator: &tracker, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0 && tracker.total_allocation_count() == 0);
}

fn void test_surface_publish_shared_copy_checks_compare_exact_frame_sums() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    Vec3[2] positions = { { 0x1p-25f, 0, 0 }, { -0x1p-25f, 0, 0 } };
    SurfacePreparedPiece[2] pieces;
    foreach (uint index, &piece : pieces) {
        piece.output.origin = { 1, 0, 0 };
        piece.local.geometry.positions = (&positions[index])[:1];
    }
    SurfacePointUse[2] uses = { { .point = 3, .piece = 1 }, { .point = 3, .piece = 0 } };
    assert(@catch(check_surface_point_copies(
        scratch: scratch.exact, pieces: pieces[..], uses: uses[..], resolution: 0x1p-25f,
    )) == NUMERICAL_FAILURE);
    check_surface_point_copies(scratch: scratch.exact, pieces: pieces[..], uses: uses[..], resolution: 0x1p-24f)!!;
    uses[1].point = 4;
    check_surface_point_copies(scratch: scratch.exact, pieces: pieces[..], uses: uses[..], resolution: 0x1p-25f)!!;
    assert(scratch.exact.count == 0);
}

fn void test_surface_publish_capacity_failures_restore_scratch_and_preserve_owned_results() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture source;
    partition_fixture(&source, 3);
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    prepare_uncut_publication(&scratch, &fixture, 3);
    usz saved = scratch.used;
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    for (uint variant = 0; variant < 3; variant++) {
        FractureLimits limited = limits;
        if (!variant) limited.max_vertices = 24;
        if (variant == 1) limited.max_triangles = 12;
        if (variant == 2) limited.max_pieces = 1;
        assert(@catch(publish_surface_pieces(
            allocator: &tracker, scratch: &scratch, limits: limited, pieces: fixture.pieces, grid: null,
            cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && tracker.total_allocation_count() == 0);
    }
    FractureResult retained = publish_fixture(scratch: &scratch, fixture: &fixture, limits: limits, allocator: &tracker);
    defer destroy_fracture_result(&retained);
    usz required = scratch.peak;
    for (usz capacity = saved; capacity < required; capacity += 8191) {
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(publish_surface_pieces(
            allocator: &tracker, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
            cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && tracker.total_allocation_count() == 1);
    }
    scratch.storage = workspace.storage;
    scratch.exact.count = EXACT_TEMPORARIES;
    set_integer(&scratch.exact.values[EXACT_TEMPORARIES - 1], 913);
    assert(@catch(publish_surface_pieces(
        allocator: &tracker, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == EXACT_TEMPORARIES);
    assert(scratch.exact.values[EXACT_TEMPORARIES - 1].limbs[0] == 913);
    scratch.exact.count = 0;
    NullAllocator unavailable;
    assert(@catch(publish_surface_pieces(
        allocator: &unavailable, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    FractureResult recovered = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&recovered);
    assert_same_publication(retained, recovered);
    workspace.storage[..] = 0x5a;
    destroy_fracture_workspace(&workspace);
    assert_same_publication(retained, recovered);
    assert(retained.pieces.len == 2 && tracker.total_allocation_count() == 1);
}

fn void test_surface_publish_empty_success_owns_minimal_storage() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    usz saved = scratch.used;
    FractureResult result = publish_surface_pieces(
        allocator: &tracker, scratch: &scratch, limits: limits, pieces: {}, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 },
    )!!;
    defer destroy_fracture_result(&result);
    assert(!result.pieces.len && result.storage.len == 1 && tracker.total_allocation_count() == 1);
    assert(scratch.used == saved && scratch.exact.count == 0);
}

fn void test_surface_publish_source_face_permutations_and_site_indices_define_order() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 2; shape < 4; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture original;
        ContainmentFixture permuted;
        partition_fixture(&original, shape);
        partition_fixture(&permuted, shape);
        for (uint face = 0; face < original.triangle_count; face++) {
            uint other = original.triangle_count - face - 1;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                permuted.indices[face * TRIANGLE_CORNERS + corner] = original.indices[other * TRIANGLE_CORNERS + (corner + 1) % TRIANGLE_CORNERS];
            }
            original.materials[other] = other + 1;
            permuted.materials[face] = other + 1;
        }
        PublishFixture first_fixture;
        PublishFixture second_fixture;
        prepare_publish_source(scratch: &scratch, fixture: &first_fixture, mesh: original.mesh);
        prepare_publish_source(scratch: &scratch, fixture: &second_fixture, mesh: permuted.mesh);
        prepare_uncut_publication(&scratch, &first_fixture, shape);
        prepare_uncut_publication(&scratch, &second_fixture, shape);
        FractureResult first = publish_fixture(&scratch, &first_fixture, limits);
        defer destroy_fracture_result(&first);
        FractureResult second = publish_fixture(&scratch, &second_fixture, limits);
        defer destroy_fracture_result(&second);
        assert_same_publication(first, second);
        if (shape == 3) {
            first_fixture.pieces[0].site_index = 7;
            first_fixture.pieces[1].site_index = 3;
            FractureResult indexed = publish_fixture(&scratch, &first_fixture, limits);
            defer destroy_fracture_result(&indexed);
            assert(first.pieces[0].origin.x == -2 && first.pieces[1].origin.x == 2);
            assert(indexed.pieces[0].origin.x == 2 && indexed.pieces[1].origin.x == -2);
        }
    }
}

fn void test_surface_publish_retains_authored_seams_with_dense_shared_topology() @test {
    FractureLimits limits = publish_limits();
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidFixture source;
    tetra_fixture(&source);
    Vec3[4] positions;
    positions[..] = source.positions[:4];
    uint[12] corners;
    corners[..] = source.indices[:12];
    Vec3[12] normals;
    Vec2[12] uv0;
    for (uint index = 0; index < corners.len; index++) {
        source.positions[index] = positions[corners[index]];
        source.identities[index] = corners[index];
        source.indices[index] = index;
        normals[index] = { 0, 0, 1 };
        uv0[index] = { (float)index, (float)(index + 1) };
    }
    source.mesh.geometry.positions = source.positions[..];
    source.mesh.geometry.normals = normals[..];
    source.mesh.geometry.uv0 = uv0[..];
    source.mesh.topology_vertices = source.identities[..];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    PublishFixture fixture;
    prepare_publish_source(scratch: &scratch, fixture: &fixture, mesh: source.mesh);
    prepare_uncut_publication(&scratch, &fixture);
    limits.max_vertices = 12;
    FractureResult result = publish_fixture(&scratch, &fixture, limits);
    defer destroy_fracture_result(&result);
    SolidMeshView mesh = result.pieces[0].mesh;
    assert(mesh.geometry.positions.len == 12 && mesh.geometry.uv0.len == 12);
    uint[4] uses;
    foreach (uint index, identity : mesh.topology_vertices) {
        uses[identity]++;
        uint original = (uint)mesh.geometry.uv0[index].x;
        assert(original < 12 && mesh.geometry.uv0[index] == uv0[original]);
        assert(mesh.geometry.positions[index] + result.pieces[0].origin == source.positions[original]);
    }
    foreach (count : uses) assert(count == 3);
    assert_published_valid(&scratch, result);
    limits.max_vertices = 11;
    assert(@catch(publish_surface_pieces(
        allocator: mem, scratch: &scratch, limits: limits, pieces: fixture.pieces, grid: null,
        cut: { .material_slot = 17, .uv_repeats_per_meter = 2 }, reference: &fixture.reference,
    )) == c3d::CAPACITY_EXCEEDED);
}
