module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_voronoi_cells_one_site_borrows_unchanged_occupied_geometry() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    foreach (uint shape : { 0, 2 }) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture fixture;
        SolidPartition source = voronoi_source(&scratch, &fixture, shape);
        GridPoint[1] sites = { { (long)(GRID_COORDINATE_LIMIT - 1), 0, 0 } };
        scratch.exact.peak = 0;
        scratch.exact.predicate_count = 0;
        VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[..])!!;
        assert(result.sites.len == 1 && !result.bisectors.len);
        assert(result.sites[0].occupied_count == source.occupied_count);
        assert(scratch.exact.count == 0 && scratch.exact.peak == 0 && !scratch.exact.predicate_count);
        PartitionCell* copied = result.sites[0].first;
        for (PartitionCell* cell = source.first; cell; cell = cell.next) {
            if (!cell.occupied) continue;
            assert(copied && copied != cell && copied.occupied);
            assert(copied.cell.vertices.ptr == cell.cell.vertices.ptr);
            assert(copied.cell.faces.ptr == cell.cell.faces.ptr && copied.cell.corners.ptr == cell.cell.corners.ptr);
            copied = copied.next;
        }
        assert(!copied);
    }
}

fn void test_voronoi_cells_two_sites_share_one_plane_with_opposite_sides() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint reversed = 0; reversed < 2; reversed++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture fixture;
        SolidPartition source = voronoi_source(&scratch, &fixture, 0);
        GridPoint[2] sites = { { -4, 0, 0 }, { 4, 0, 0 } };
        if (reversed) sites = { { 4, 0, 0 }, { -4, 0, 0 } };
        VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[..])!!;
        assert(result.bisectors.len == 1 && result.sites.len == 2);
        SiteBisector* bisector = &result.bisectors[0];
        assert(bisector.first == 0 && bisector.second == 1 && bisector.first_reversed == (reversed != 0));
        foreach (uint site, partition : result.sites) {
            assert(partition.cell_count == 1 && partition.occupied_count == 1);
            uint shared;
            foreach (face : partition.first.cell.faces) if (face.plane == &bisector.plane) {
                assert(face.reversed == (site == 0 ? bisector.first_reversed : !bisector.first_reversed));
                shared++;
            }
            assert(shared == 1);
            GridPoint lower = { -12, -12, -12 };
            GridPoint upper = { 12, 12, 12 };
            if (sites[site][0] < 0) {
                upper[0] = 0;
            } else {
                lower[0] = 0;
            }
            ConvexCell expected = voronoi_grid_box(&scratch, lower, upper);
            assert_voronoi_same_region(scratch.exact, &partition.first.cell, &expected);
        }
        assert_voronoi_coverage(
            scratch: &scratch,
            source: &source,
            result: &result,
            boxes: true,
        );
    }
}

fn void test_voronoi_cells_four_and_eight_sites_cover_exact_grid_regions_in_order() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint dimensions = 2; dimensions <= 3; dimensions++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture fixture;
        SolidPartition source = voronoi_source(&scratch, &fixture, 0);
        uint count = (uint)1 << dimensions;
        GridPoint[8] sites;
        for (uint site = 0; site < count; site++) {
            for (uint axis = 0; axis < dimensions; axis++) sites[site][axis] = (site & ((uint)1 << axis)) ? 4 : -4;
        }
        VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[:count])!!;
        assert(result.sites.len == count && result.bisectors.len == (usz)(count * (count - 1) / 2));
        uint pair;
        for (uint first = 0; first < count; first++) for (uint second = first + 1; second < count; second++) {
            assert(result.bisectors[pair].first == first && result.bisectors[pair].second == second);
            pair++;
        }
        foreach (uint site, partition : result.sites) {
            assert(partition.occupied_count == 1);
            GridPoint lower = { -12, -12, -12 };
            GridPoint upper = { 12, 12, 12 };
            for (uint axis = 0; axis < dimensions; axis++) {
                if (sites[site][axis] < 0) {
                    upper[axis] = 0;
                } else {
                    lower[axis] = 0;
                }
            }
            ConvexCell expected = voronoi_grid_box(&scratch, lower, upper);
            assert_voronoi_same_region(scratch.exact, &partition.first.cell, &expected);
        }
        assert_voronoi_coverage(
            scratch: &scratch,
            source: &source,
            result: &result,
            boxes: false,
        );
        VoronoiPartition repeated = partition_voronoi_cells(&scratch, &source, sites[:count])!!;
        foreach (uint site, partition : repeated.sites) {
            assert(partition.cell_count == result.sites[site].cell_count);
            assert_same_cell(scratch.exact, &partition.first.cell, &result.sites[site].first.cell);
        }
        for (uint site = 0; site < count / 2; site++) {
            GridPoint saved = sites[site];
            sites[site] = sites[count - site - 1];
            sites[count - site - 1] = saved;
        }
        VoronoiPartition permuted = partition_voronoi_cells(&scratch, &source, sites[:count])!!;
        foreach (uint site, partition : permuted.sites) {
            assert(partition.occupied_count == 1);
            assert_voronoi_same_region(
                scratch.exact, &partition.first.cell, &result.sites[count - site - 1].first.cell,
            );
        }
    }
}

fn void test_voronoi_cells_keep_empty_outside_site_slots() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    SolidPartition source = voronoi_source(&scratch, &fixture, 0);
    GridPoint[3] sites = { { 100, 0, 0 }, {}, { -100, 0, 0 } };
    VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[..])!!;
    assert(result.sites.len == 3 && result.bisectors.len == 3);
    assert(!result.sites[0].first && !result.sites[0].cell_count && !result.sites[0].occupied_count);
    assert(!result.sites[2].first && !result.sites[2].cell_count && !result.sites[2].occupied_count);
    assert(result.sites[1].occupied_count == 1);
    assert(result.sites[1].first.cell.vertices.ptr == source.first.cell.vertices.ptr);
    assert_voronoi_coverage(
        scratch: &scratch,
        source: &source,
        result: &result,
        boxes: true,
    );
}

fn void test_voronoi_cells_preserve_concavity_cavities_islands_and_disconnected_coverage() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 1; shape <= 4; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ContainmentFixture fixture;
        SolidPartition source = voronoi_source(&scratch, &fixture, shape);
        GridPoint[2] sites = { { -4, 0, 0 }, { 4, 0, 0 } };
        if (shape == 4) sites = { { 0, 0, 0 }, { 8, 0, 0 } };
        VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[..])!!;
        assert_voronoi_coverage(
            scratch: &scratch,
            source: &source,
            result: &result,
            boxes: true,
        );
    }
}

fn void test_voronoi_cells_quantized_duplicates_restore_source_and_allow_reuse() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    SolidPartition source = voronoi_source(&scratch, &fixture, 0);
    usz saved = scratch.used;
    GridPoint[3] sites = { { -4, 0, 0 }, { 4, 0, 0 }, { -4, 0, 0 } };
    assert(@catch(partition_voronoi_cells(&scratch, &source, sites[..])) == NUMERICAL_FAILURE);
    assert(scratch.used == saved && scratch.exact.count == 0 && source.occupied_count == 1);
    assert(@catch(partition_voronoi_cells(&scratch, &source, (&sites[0])[:(usz)sz::max])) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    sites[2] = { 0, 4, 0 };
    VoronoiPartition result = partition_voronoi_cells(&scratch, &source, sites[..])!!;
    assert(result.sites.len == 3 && result.bisectors.len == 3);
    assert_voronoi_coverage(
        scratch: &scratch,
        source: &source,
        result: &result,
        boxes: false,
    );
}

fn void test_voronoi_cells_capacity_faults_preserve_source_bytes_and_restore_arena() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ContainmentFixture fixture;
    SolidPartition source = voronoi_source(&scratch, &fixture, 1);
    GridPoint[2] sites = { { -4, 0, 0 }, { 4, 0, 0 } };
    usz saved = scratch.used;
    char[] preserved = mem::new_array(char, (sz)(saved - MIN_FRACTURE_SCRATCH_BYTES));
    defer mem::free(preserved);
    preserved[..] = scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len];
    scratch.peak = saved;
    VoronoiPartition complete = partition_voronoi_cells(&scratch, &source, sites[..])!!;
    usz required = scratch.peak;
    assert(complete.sites.len == 2 && scratch.exact.count == 0);
    foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
    for (usz capacity = saved; capacity < required; capacity += 211) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(partition_voronoi_cells(&scratch, &source, sites[..])) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required - 1];
    assert(@catch(partition_voronoi_cells(&scratch, &source, sites[..])) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    scratch.storage = workspace.storage[:required];
    complete = partition_voronoi_cells(&scratch, &source, sites[..])!!;
    assert(complete.sites.len == 2 && scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
}

fn SolidPartition voronoi_source(SolidScratch* scratch, ContainmentFixture* fixture, uint shape) @local {
    partition_fixture(fixture, shape);
    SolidSurface surface = partition_surface(scratch, fixture, true);
    SourceConstructions constructions = build_source_constructions(scratch, &surface)!!;
    return partition_solid(scratch, &surface, &constructions)!!;
}

fn ConvexCell voronoi_grid_box(SolidScratch* scratch, GridPoint lower, GridPoint upper) @local {
    SolidBvhNode[1] nodes = { { .bounds = { .lower = lower, .upper = upper } } };
    GridPoint[1] grid;
    SolidSurface surface = { .nodes = nodes[..], .grid = grid[..] };
    return create_bounds_cell(scratch, &surface)!!;
}

fn bool voronoi_cell_contains(ExactScratch* scratch, ConvexCell* outer, ConvexCell* inner) @local {
    foreach (point : inner.vertices) foreach (face : outer.faces) {
        int side = plane_side(scratch, face.plane, point)!!;
        if (face.reversed ? side < 0 : side > 0) return false;
    }
    return true;
}

fn void assert_voronoi_same_region(ExactScratch* scratch, ConvexCell* first, ConvexCell* second) @local {
    assert(voronoi_cell_contains(scratch, first, second));
    assert(voronoi_cell_contains(scratch, second, first));
}

fn int128 voronoi_box_volume(ExactScratch* scratch, ConvexCell* cell) @local {
    assert(cell.vertices.len == BOX_VERTICES);
    GridPoint[BOX_VERTICES] positions;
    GridPoint lower;
    GridPoint upper;
    foreach (uint index, vertex : cell.vertices) {
        uint saved = scratch.count;
        defer scratch.count = saved;
        HomogeneousPoint point;
        foreach (&coordinate : point) *coordinate = scratch.take()!!;
        construct_point(scratch, point, vertex)!!;
        assert(point[SPACE_AXES].used == 1 && point[SPACE_AXES].limbs[0] == 1 && !point[SPACE_AXES].negative);
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            assert(point[axis].used <= 1);
            long coordinate = point[axis].used ? (long)point[axis].limbs[0] : 0;
            positions[index][axis] = point[axis].negative ? -coordinate : coordinate;
        }
        if (!index) lower = upper = positions[index];
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            lower[axis] = math::min(lower[axis], positions[index][axis]);
            upper[axis] = math::max(upper[axis], positions[index][axis]);
        }
    }
    int128 volume = 1;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        assert(upper[axis] > lower[axis]);
        foreach (position : positions) assert(position[axis] == lower[axis] || position[axis] == upper[axis]);
        volume *= (int128)(upper[axis] - lower[axis]);
    }
    return volume;
}

fn void assert_voronoi_coverage(
    SolidScratch* scratch,
    SolidPartition* source,
    VoronoiPartition* result,
    bool boxes,
) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    usz count;
    int128 source_volume;
    int128 result_volume;
    for (PartitionCell* cell = source.first; cell; cell = cell.next) {
        if (boxes && cell.occupied) source_volume += voronoi_box_volume(scratch.exact, &cell.cell);
    }
    foreach (partition : result.sites) count += partition.occupied_count;
    ConvexCell*[] cells = reserve_elements(scratch, ConvexCell*, count)!!;
    count = 0;
    foreach (uint site, partition : result.sites) {
        uint retained;
        for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
            assert(cell.occupied);
            assert_cell(scratch, &cell.cell);
            if (boxes) result_volume += voronoi_box_volume(scratch.exact, &cell.cell);
            bool contained;
            for (PartitionCell* original = source.first; original; original = original.next) {
                if (original.occupied && voronoi_cell_contains(scratch.exact, &original.cell, &cell.cell)) {
                    contained = true;
                }
            }
            assert(contained);
            foreach (&bisector : result.bisectors) {
                if (bisector.first != site && bisector.second != site) continue;
                bool positive = bisector.first == site ? bisector.first_reversed : !bisector.first_reversed;
                foreach (point : cell.cell.vertices) {
                    int side = plane_side(scratch.exact, &bisector.plane, point)!!;
                    assert(positive ? side >= 0 : side <= 0);
                }
            }
            cells[count++] = &cell.cell;
            retained++;
        }
        assert(retained == partition.cell_count && retained == partition.occupied_count);
    }
    if (boxes) assert(source_volume == result_volume);
    for (usz first = 0; first < cells.len; first++) for (usz second = first + 1; second < cells.len; second++) {
        usz retained = scratch.used;
        defer scratch.used = retained;
        ConvexCell intersection = *cells[first];
        foreach (face : cells[second].faces) {
            CellSplit split = split_convex_cell(scratch, &intersection, face.plane)!!;
            intersection = face.reversed ? split.positive : split.negative;
            if (!intersection.vertices.len) break;
        }
        assert(!intersection.vertices.len);
    }
    assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
}
