module c3d::physics::fracture;

import c3d;
import std::math;

fn ConvexCell collision_test_box(
    SolidScratch* scratch,
    Vec3 lower,
    Vec3 upper,
    bool quantized,
) @private {
    ContainmentFixture fixture;
    append_box_fixture(&fixture, lower, upper);
    SolidSurface surface = partition_surface(scratch, &fixture, quantized);
    return create_bounds_cell(scratch, &surface)!!;
}

fn void test_collision_cells_merge_convex_neighbors_with_vertex_limit() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell first = collision_test_box(
            scratch: &scratch, lower: { -2, -1, -1 }, upper: { 0, 1, 1 }, quantized: domain != 0,
        );
        ConvexCell second = collision_test_box(
            scratch: &scratch, lower: { 0, -1, -1 }, upper: { 2, 1, 1 }, quantized: domain != 0,
        );
        usz saved = scratch.used;
        CollisionCellMerge limited = merge_collision_pair(
            scratch: &scratch, first: &first, second: &second, max_vertices: 7,
        )!!;
        assert(!limited.joined && scratch.used == saved);
        CollisionCellMerge joined = merge_collision_pair(
            scratch: &scratch, first: &first, second: &second, max_vertices: 8,
        )!!;
        assert(joined.joined && joined.cell.vertices.len == 8 && joined.cell.faces.len == 6);
        assert_cell(&scratch, &joined.cell);
        double expected = cell_volume(scratch.exact, &first) + cell_volume(scratch.exact, &second);
        assert(math::abs(cell_volume(scratch.exact, &joined.cell) - expected) < expected * 1e-12);
        assert(first.vertices.len == 8 && second.vertices.len == 8);
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_collision_cells_reject_concave_edge_and_point_joins() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3[4] starts = { { 0, 0, 0 }, { 0, 1, -1 }, { 0, 1, 1 }, { 1, -1, -1 } };
    for (uint domain = 0; domain < 2; domain++) {
        foreach (start : starts) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            ConvexCell first = collision_test_box(
                scratch: &scratch, lower: { -2, -1, -1 }, upper: { 0, 1, 1 }, quantized: domain != 0,
            );
            ConvexCell second = collision_test_box(
                scratch: &scratch, lower: start, upper: start + (Vec3){ 2, 2, 2 }, quantized: domain != 0,
            );
            usz saved = scratch.used;
            CollisionCellMerge joined = merge_collision_pair(
                scratch: &scratch, first: &first, second: &second, max_vertices: 32,
            )!!;
            assert(!joined.joined && scratch.used == saved && scratch.exact.count == 0);
        }
    }
}

fn void test_collision_cells_merge_unequal_subdivisions_deterministically() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell right = collision_test_box(
            scratch: &scratch, lower: { 0, -1, -1 }, upper: { 2, 1, 1 }, quantized: domain != 0,
        );
        ExactPlane middle;
        plane_from_integers(scratch.exact, &middle, { 0, 1, 0, 0 })!!;
        CellSplit split = split_convex_cell(&scratch, &right, &middle)!!;
        PartitionCell[3] parts = {
            { .cell = split.positive, .occupied = true },
            { .cell = collision_test_box(
                scratch: &scratch, lower: { -2, -1, -1 }, upper: { 0, 1, 1 }, quantized: domain != 0,
            ), .occupied = true },
            { .cell = split.negative, .occupied = true },
        };
        parts[0].next = &parts[1];
        parts[1].next = &parts[2];
        SolidPartition partition = { .first = &parts[0], .cell_count = 3, .occupied_count = 3 };
        CollisionCell[] first = merge_collision_cells(&scratch, &partition, 8)!!;
        assert(first.len == 1 && first[0].cell.vertices.len == 8);
        assert_cell(&scratch, &first[0].cell);
        parts[2].next = &parts[1];
        parts[1].next = &parts[0];
        parts[0].next = null;
        partition.first = &parts[2];
        CollisionCell[] repeated = merge_collision_cells(&scratch, &partition, 8)!!;
        assert(repeated.len == 1 && compare_collision_cells(scratch.exact, first[0], repeated[0])!! == 0);
        assert(scratch.exact.count == 0);
    }
}

fn void test_collision_cells_keep_raw_partition_volume_and_reuse_after_capacity() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, false);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        double expected;
        for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
            if (cell.occupied) expected += cell_volume(scratch.exact, &cell.cell);
        }
        usz saved = scratch.used;
        scratch.peak = saved;
        CollisionCell[] cells = merge_collision_cells(&scratch, &partition, 64)!!;
        usz required = scratch.peak;
        double volume;
        foreach (&cell : cells) {
            assert_cell(&scratch, &cell.cell);
            volume += cell_volume(scratch.exact, &cell.cell);
        }
        assert(math::abs(volume - expected) < expected * 1e-12);
        if (!shape) assert(cells.len == 1);
        for (usz capacity = saved; capacity < required; capacity += 4093) {
            scratch.used = saved;
            scratch.storage = workspace.storage[:capacity];
            assert(@catch(merge_collision_cells(&scratch, &partition, 64)) == c3d::CAPACITY_EXCEEDED);
            assert(scratch.used == saved && scratch.exact.count == 0);
        }
        scratch.storage = workspace.storage;
        scratch.used = saved;
        CollisionCell[] repeated = merge_collision_cells(&scratch, &partition, 64)!!;
        assert(repeated.len == cells.len && scratch.exact.count == 0);
    }
}
