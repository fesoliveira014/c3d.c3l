module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_voronoi_generation_one_site_preserves_components_and_independent_ownership() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    uint[5] counts = { 1, 1, 2, 2, 1 };
    for (uint shape = 0; shape < counts.len; shape++) {
        ContainmentFixture source;
        partition_fixture(&source, shape);
        FractureResult result = create_voronoi_fracture(
            allocator: &tracker, workspace: &workspace, source: source.mesh,
            sites: { { float::max, -float::max, float::max } },
            cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
        )!!;
        assert(result.pieces.len == counts[shape] && tracker.allocation_count() == 1);
        FractureResult repeated = create_voronoi_fracture(
            allocator: &tracker, workspace: &workspace, source: source.mesh, sites: { {} },
            cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
        )!!;
        assert_same_publication(result, repeated);
        source = {};
        workspace.storage[..] = 0x5a;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        assert_published_valid(&scratch, result);
        assert_same_publication(result, repeated);
        destroy_fracture_result(&repeated);
        destroy_fracture_result(&result);
        assert(tracker.allocation_count() == 0);
    }
}

fn void test_voronoi_generation_public_sites_cover_box_with_cut_material_and_volume() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint dimensions = 1; dimensions <= 3; dimensions++) {
        ContainmentFixture source;
        partition_fixture(&source, 0);
        Vec3[8] sites;
        uint count = (uint)1 << dimensions;
        for (uint site = 0; site < count; site++) for (uint axis = 0; axis < dimensions; axis++) {
            sites[site][axis] = (site & ((uint)1 << axis)) ? 1 : -1;
        }
        FractureResult result = create_voronoi_fracture(
            allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[:count],
            cut: { .material_slot = 77, .uv_repeats_per_meter = 2 },
        )!!;
        defer destroy_fracture_result(&result);
        assert(result.pieces.len == count);
        ExactScratch* measured = (ExactScratch*)workspace.storage.ptr;
        assert(measured.statistics.final_leaf_count == count && measured.statistics.occupied_leaf_count == count);
        assert(measured.statistics.scratch_peak > MIN_FRACTURE_SCRATCH_BYTES && measured.count == 0);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        assert_published_valid(&scratch, result);
        double volume;
        foreach (uint owner, piece : result.pieces) {
            volume += generated_piece_volume(piece);
            assert(math::abs(generated_piece_volume(piece) - 216.0 / count) < 1e-9);
            uint cuts;
            foreach (material : piece.mesh.triangle_materials) cuts += material == 77 ? 1 : 0;
            assert(cuts && piece.mesh.geometry.uv0.len && piece.mesh.geometry.tangents.len);
            for (uint axis = 0; axis < dimensions; axis++) {
                assert(math::abs(piece.origin[axis] - (sites[owner][axis] > 0 ? 1.5 : -1.5)) < 1e-6);
            }
        }
        assert(math::abs(volume - 216) < 1e-9);
    }
}

fn void test_voronoi_generation_oblique_sites_and_disconnected_cell_are_repeatable() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        ContainmentFixture source;
        Vec3[4] sites = { { -1, -0.5, 0 }, { 1, 0.25, 0 }, { 0, 1, 0.75 }, { 100, 100, 100 } };
        uint expected;
        if (variant) {
            publish_u_fixture(&source);
            sites = { { 1.5, 0.5, 0.5 }, { 1.5, 2.5, 0.5 }, {}, {} };
            expected = 3;
        } else {
            partition_fixture(&source, 0);
            expected = 3;
        }
        FractureResult first = create_voronoi_fracture(
            allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[:variant ? 2 : 4],
            cut: { .material_slot = 77, .uv_repeats_per_meter = 3 },
        )!!;
        defer destroy_fracture_result(&first);
        assert(first.pieces.len == expected);
        FractureResult second = create_voronoi_fracture(
            allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[:variant ? 2 : 4],
            cut: { .material_slot = 77, .uv_repeats_per_meter = 3 },
        )!!;
        defer destroy_fracture_result(&second);
        assert_same_publication(first, second);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        assert_published_valid(&scratch, first);
        double volume;
        foreach (piece : first.pieces) volume += generated_piece_volume(piece);
        assert(math::abs(volume - (variant ? 7 : 216)) < 0.0001);
    }
}

fn void test_voronoi_generation_faults_distinguish_inputs_topology_and_quantization() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture source;
    partition_fixture(&source, 0);
    Vec3[2] sites = { {}, { 1, 0, 0 } };
    CutSurface cut = { .material_slot = 7, .uv_repeats_per_meter = 1 };
    assert(@catch(create_voronoi_fracture(
        allocator: mem, workspace: &workspace, source: source.mesh, sites: {}, cut: cut,
    )) == c3d::INVALID_ARGUMENT);
    foreach (float density : { 0.0f, -1.0f, bitcast((uint)0x7f800000, float), bitcast((uint)0x7fc00001, float) }) {
        cut.uv_repeats_per_meter = density;
        assert(@catch(create_voronoi_fracture(
            allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
        )) == c3d::INVALID_ARGUMENT);
    }
    cut.uv_repeats_per_meter = 1;
    foreach (Vec3 second : { (Vec3){ -0.0, 0, 0 }, { bitcast((uint)0x7f800000, float), 0, 0 } }) {
        sites[1] = second;
        assert(@catch(create_voronoi_fracture(
            allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
        )) == c3d::INVALID_ARGUMENT);
    }
    sites[1] = { 0.00000001, 0, 0 };
    assert(@catch(create_voronoi_fracture(
        allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
    )) == NUMERICAL_FAILURE);
    sites[1] = { 1, 0, 0 };
    source.mesh.geometry.topology = Topology.LINES;
    assert(@catch(create_voronoi_fracture(
        allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
    )) == c3d::UNSUPPORTED);
    source.mesh.geometry.topology = Topology.TRIANGLES;
    source.positions[0] = source.positions[1];
    assert(@catch(create_voronoi_fracture(
        allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
    )) == INVALID_SOLID);
    source = {};
    partition_fixture(&source, 0);
    FractureResult recovered = create_voronoi_fracture(
        allocator: mem, workspace: &workspace, source: source.mesh, sites: sites[..], cut: cut,
    )!!;
    defer destroy_fracture_result(&recovered);
    assert(recovered.pieces.len == 2 && ((ExactScratch*)workspace.storage.ptr).count == 0);
}

fn void test_voronoi_generation_output_and_scratch_caps_fail_without_result_allocation() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture source;
    partition_fixture(&source, 0);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits original = workspace.limits;
    char[] storage = workspace.storage;
    for (uint limit = 0; limit < 5; limit++) {
        workspace.limits = original;
        workspace.storage = storage;
        switch (limit) {
            case 0: workspace.limits.max_pieces = 1;
            case 1: workspace.limits.max_sites = 1;
            case 2: workspace.limits.max_vertices = 1;
            case 3: workspace.limits.max_triangles = 1;
            case 4: workspace.storage = storage[:MIN_FRACTURE_SCRATCH_BYTES];
        }
        assert(@catch(create_voronoi_fracture(
            allocator: &tracker, workspace: &workspace, source: source.mesh, sites: { { -1, 0, 0 }, { 1, 0, 0 } },
            cut: { .material_slot = 7, .uv_repeats_per_meter = 1 },
        )) == c3d::CAPACITY_EXCEEDED);
        assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
        assert(((ExactScratch*)storage.ptr).count == 0);
    }
    workspace.limits = original;
    workspace.storage = storage;
    NullAllocator unavailable;
    tracker.inner_allocator = &unavailable;
    assert(@catch(create_voronoi_fracture(
        allocator: &tracker, workspace: &workspace, source: source.mesh, sites: { { -1, 0, 0 }, { 1, 0, 0 } },
        cut: { .material_slot = 7, .uv_repeats_per_meter = 1 },
    )) == c3d::CAPACITY_EXCEEDED);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
    tracker.inner_allocator = mem;
    FractureResult recovered = create_voronoi_fracture(
        allocator: &tracker, workspace: &workspace, source: source.mesh, sites: { { -1, 0, 0 }, { 1, 0, 0 } },
        cut: { .material_slot = 7, .uv_repeats_per_meter = 1 },
    )!!;
    assert(recovered.pieces.len == 2 && tracker.allocation_count() == 1);
    destroy_fracture_result(&recovered);
    assert(tracker.allocation_count() == 0);
}

fn double generated_piece_volume(FracturePieceView piece) @private {
    double volume;
    Vec3[] positions = piece.mesh.geometry.positions;
    uint[] indices = piece.mesh.geometry.indices;
    for (uint triangle = 0; triangle < indices.len / TRIANGLE_CORNERS; triangle++) {
        Vec3 a = positions[indices[triangle * TRIANGLE_CORNERS]];
        Vec3 b = positions[indices[triangle * TRIANGLE_CORNERS + 1]];
        Vec3 c = positions[indices[triangle * TRIANGLE_CORNERS + 2]];
        volume += (double)a.x * ((double)b.y * c.z - (double)b.z * c.y)
            + (double)a.y * ((double)b.z * c.x - (double)b.x * c.z)
            + (double)a.z * ((double)b.x * c.y - (double)b.y * c.x);
    }
    return volume / 6;
}
