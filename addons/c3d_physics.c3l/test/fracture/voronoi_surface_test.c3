module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_voronoi_surface_one_site_preserves_authored_triangles_and_components() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    uint[5] counts = { 1, 1, 2, 2, 1 };
    for (uint shape = 0; shape < counts.len; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture mesh;
        partition_fixture(&mesh, shape);
        PublishFixture fixture;
        PreparedSource source;
        prepare_voronoi_surface_fixture(
            scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source, sites: { {} },
        );
        assert(fixture.pieces.len == counts[shape]);
        uint triangles;
        foreach (piece : fixture.pieces) foreach (patch : piece.patches) {
            assert(!patch.cut && !patch.shared_cut && patch.boundary.unchanged);
            assert(patch.triangulation.shared.triangles.len == 1 && !patch.selection.len);
            triangles++;
        }
        assert(triangles == mesh.mesh.geometry.indices.len / TRIANGLE_CORNERS);
        QuantizationGrid grid = { .step_exponent = -2 };
        FractureResult result = publish_fixture(
            scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
        );
        defer destroy_fracture_result(&result);
        assert_published_valid(&scratch, result);
    }
}

fn void test_voronoi_surface_two_four_eight_sites_share_each_cut_triangle_twice() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint dimensions = 1; dimensions <= 3; dimensions++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture mesh;
        partition_fixture(&mesh, 0);
        GridPoint[8] sites;
        uint count = (uint)1 << dimensions;
        for (uint site = 0; site < count; site++) for (uint axis = 0; axis < dimensions; axis++) {
            sites[site][axis] = (site & ((uint)1 << axis)) ? 4 : -4;
        }
        PublishFixture fixture;
        PreparedSource source;
        prepare_voronoi_surface_fixture(
            scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source, sites: sites[:count],
        );
        assert(fixture.pieces.len == count);
        assert_voronoi_shared_triangles(fixture.pieces);
        QuantizationGrid grid = { .step_exponent = -2 };
        FractureResult result = publish_fixture(
            scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
        );
        defer destroy_fracture_result(&result);
        assert_published_valid(&scratch, result);
        foreach (uint index, piece : fixture.pieces) assert(piece.site_index == index);
        assert(scratch.exact.count == 0);
    }
}

fn void test_voronoi_surface_preserves_cavities_islands_concavity_and_disconnected_parts() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    uint[5] counts = { 2, 2, 4, 2, 2 };
    for (uint shape = 1; shape < counts.len; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture mesh;
        partition_fixture(&mesh, shape);
        GridPoint[2] sites = { { -4, 0, 0 }, { 4, 0, 0 } };
        if (shape == 4) sites = { {}, { 8, 0, 0 } };
        PublishFixture fixture;
        PreparedSource source;
        prepare_voronoi_surface_fixture(
            scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source, sites: sites[..],
        );
        assert(fixture.pieces.len == counts[shape]);
        assert_voronoi_shared_triangles(fixture.pieces);
        QuantizationGrid grid = { .step_exponent = -2 };
        FractureResult result = publish_fixture(
            scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
        );
        defer destroy_fracture_result(&result);
        assert_published_valid(&scratch, result);
    }
}

fn void test_voronoi_surface_one_cap_has_disjoint_opposite_component_selections() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture mesh;
    publish_u_fixture(&mesh);
    PublishFixture fixture;
    PreparedSource source;
    prepare_voronoi_surface_fixture(
        scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source,
        sites: { { 6, 2, 2 }, { 6, 10, 2 } },
    );
    assert(fixture.pieces.len == 3);
    uint[2] site_counts;
    uint selected_count;
    PatchTriangles* shared;
    foreach (piece : fixture.pieces) {
        site_counts[piece.site_index]++;
        foreach (patch : piece.patches) if (patch.shared_cut) {
            if (!shared) shared = patch.triangulation.shared;
            assert(shared == patch.triangulation.shared);
            if (piece.site_index == 0) {
                assert(!patch.selection.len);
            } else {
                assert(patch.selection.len && patch.selection.len < shared.triangles.len);
                selected_count += (uint)patch.selection.len;
            }
        }
    }
    assert(site_counts == (uint[2]){ 1, 2 } && selected_count == shared.triangles.len);
    assert_voronoi_shared_triangles(fixture.pieces);
    QuantizationGrid grid = { .step_exponent = -2 };
    FractureResult result = publish_fixture(
        scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
    );
    defer destroy_fracture_result(&result);
    assert_published_valid(&scratch, result);
}

fn void test_voronoi_surface_exterior_coincident_bisector_has_no_generated_cap() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture mesh;
    partition_fixture(&mesh, 0);
    PublishFixture fixture;
    PreparedSource source;
    prepare_voronoi_surface_fixture(
        scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source,
        sites: { {}, { 24, 0, 0 } },
    );
    assert(fixture.pieces.len == 1 && fixture.pieces[0].site_index == 0);
    foreach (patch : fixture.pieces[0].patches) assert(!patch.cut && !patch.shared_cut);
    QuantizationGrid grid = { .step_exponent = -2 };
    FractureResult result = publish_fixture(
        scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
    );
    defer destroy_fracture_result(&result);
    assert_published_valid(&scratch, result);
}

fn void test_voronoi_surface_source_triangle_permutations_publish_identical_bytes() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    FractureResult[2] results;
    defer foreach (&result : results) destroy_fracture_result(result);
    for (uint variant = 0; variant < 2; variant++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture mesh;
        partition_fixture(&mesh, 1);
        if (variant) {
            uint[] indices = mesh.mesh.geometry.indices;
            for (usz triangle = 0; triangle < indices.len / 6; triangle++) {
                for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                    usz first = triangle * TRIANGLE_CORNERS + corner;
                    usz second = indices.len - (triangle + 1) * TRIANGLE_CORNERS + corner;
                    uint saved = indices[first]; indices[first] = indices[second]; indices[second] = saved;
                }
            }
        }
        PublishFixture fixture;
        PreparedSource source;
        prepare_voronoi_surface_fixture(
            scratch: &scratch, mesh: &mesh, fixture: &fixture, source: &source,
            sites: { { -4, 0, 0 }, { 4, 0, 0 } },
        );
        QuantizationGrid grid = { .step_exponent = -2 };
        results[variant] = publish_fixture(
            scratch: &scratch, fixture: &fixture, limits: workspace.limits, grid: &grid,
        );
    }
    assert_same_publication(results[0], results[1]);
}

fn void test_voronoi_surface_capacity_rolls_back_and_preserves_source_partition() @test {
    FractureWorkspace workspace = create_fracture_workspace(mem, publish_limits())!!;
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture mesh;
    partition_fixture(&mesh, 0);
    PreparedSource source;
    source.solid.surface = partition_surface(&scratch, &mesh, true);
    source.constructions = build_source_constructions(&scratch, &source.solid.surface)!!;
    SolidPartition cells = partition_solid(&scratch, &source.solid.surface, &source.constructions)!!;
    VoronoiPartition partition = partition_voronoi_cells(&scratch, &cells, { { -4, 0, 0 }, { 4, 0, 0 } })!!;
    usz saved = scratch.used;
    char[] preserved = mem::new_array(char, (sz)(saved - MIN_FRACTURE_SCRATCH_BYTES));
    defer mem::free(preserved);
    preserved[..] = scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len];
    scratch.peak = saved;
    SurfacePiece[] pieces = build_voronoi_surface_pieces(
        scratch: &scratch, source: &source, partition: &partition, max_pieces: 2,
    )!!;
    usz required = scratch.peak;
    assert(pieces.len == 2 && scratch.exact.count == 0);
    foreach (usz capacity : { saved, saved + (required - saved) / 2, required - 1 }) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(build_voronoi_surface_pieces(
            scratch: &scratch, source: &source, partition: &partition, max_pieces: 2,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        assert(preserved == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len]);
    }
    scratch.storage = workspace.storage[:required];
    assert(@catch(build_voronoi_surface_pieces(
        scratch: &scratch, source: &source, partition: &partition, max_pieces: 1,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    pieces = build_voronoi_surface_pieces(
        scratch: &scratch, source: &source, partition: &partition, max_pieces: 2,
    )!!;
    assert(pieces.len == 2 && scratch.exact.count == 0);
    assert(preserved == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len]);
}

fn void prepare_voronoi_surface_fixture(
    SolidScratch* scratch,
    ContainmentFixture* mesh,
    PublishFixture* fixture,
    PreparedSource* source,
    GridPoint[] sites,
) @local {
    prepare_publish_source(
        scratch: scratch, fixture: fixture, mesh: mesh.mesh, grid: mesh.grid[:mesh.vertex_count],
    );
    source.solid.surface = fixture.surface;
    source.constructions = fixture.source;
    SolidPartition cells = partition_solid(scratch, &source.solid.surface, &source.constructions)!!;
    VoronoiPartition partition = partition_voronoi_cells(scratch, &cells, sites)!!;
    fixture.pieces = build_voronoi_surface_pieces(
        scratch: scratch, source: source, partition: &partition, max_pieces: 16,
    )!!;
}

fn void assert_voronoi_shared_triangles(SurfacePiece[] pieces) @local {
    foreach (uint owner, piece : pieces) foreach (patch : piece.patches) {
        if (!patch.shared_cut || patch.selection.len) continue;
        foreach (uint triangle, value : patch.triangulation.shared.triangles) {
            uint uses;
            foreach (uint other, candidate : pieces) foreach (surface : candidate.patches) {
                if (!surface.shared_cut || surface.triangulation.shared != patch.triangulation.shared) continue;
                bool selected = !surface.selection.len;
                foreach (index : surface.selection) selected |= index == triangle;
                if (!selected) continue;
                assert((other == owner) == (surface.triangulation.reversed == patch.triangulation.reversed));
                uses++;
            }
            assert(uses == 2);
        }
    }
}
