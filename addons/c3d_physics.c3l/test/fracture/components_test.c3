module c3d::physics::fracture;

import c3d;
import std::io;
import std::math;

fn void test_material_components_keep_cavities_islands_and_concavity() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    uint[5] expected = { 1, 1, 2, 2, 1 };
    for (uint shape = 0; shape < expected.len; shape++) {
        for (uint domain = 0; domain < 2; domain++) {
            ContainmentFixture fixture;
            partition_fixture(&fixture, shape);
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
            SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
            SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
            usz saved = scratch.used;
            char[] preserved = mem::new_array(char, (sz)(saved - MIN_FRACTURE_SCRATCH_BYTES));
            defer mem::free(preserved);
            preserved[..] = scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len];
            scratch.peak = saved;
            scratch.exact.peak = 0;
            SolidPartition[] components = partition_material_components(&scratch, &partition)!!;
            assert(components.len == expected[shape]);
            assert_material_components(&partition, components);
            if (shape == 2) {
                assert(components[0].cell_count == 6 && components[1].cell_count == 1);
                double outer_volume;
                for (PartitionCell* cell = components[0].first; cell; cell = cell.next) outer_volume += cell_volume(scratch.exact, &cell.cell);
                double island_volume = cell_volume(scratch.exact, &components[1].first.cell);
                assert(math::abs(outer_volume / island_volume - 19) < 1e-12);
            }
            foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
            assert(scratch.exact.count == 0 && scratch.exact.peak <= PROJECTED_ORIENTATION_TEMPORARIES);
            io::printfn("components shape=%s domain=%s cells=%s components=%s scratch=%s added=%s wide=%s",
                shape, domain, partition.occupied_count, components.len, scratch.peak, scratch.peak - saved, scratch.exact.peak);
            usz retained = scratch.used;
            SolidPartition[] repeated = partition_material_components(&scratch, &partition)!!;
            assert(repeated.len == components.len);
            foreach (usz index, component : repeated) {
                PartitionCell* original = components[index].first;
                for (PartitionCell* cell = component.first; cell; cell = cell.next) {
                    assert(cell.cell.vertices.ptr == original.cell.vertices.ptr);
                    original = original.next;
                }
                assert(!original);
            }
            scratch.used = retained;
        }
    }
}

fn void test_material_components_join_partial_faces_but_not_edges_or_points() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    Vec3[5] lower = { { 0, -1, -1 }, { 0, 0, 0 }, { 0, 1, -1 }, { 0, 1, 1 }, { 0, 2, 0 } };
    uint[5] expected = { 1, 1, 2, 2, 2 };
    for (uint domain = 0; domain < 2; domain++) {
        foreach (uint variant, origin : lower) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            PartitionCell[2] cells = {
                { .cell = material_box(
                    scratch: &scratch,
                    lower: { -2, -1, -1 },
                    upper: { 0, 1, 1 },
                    quantized: domain != 0,
                ), .occupied = true },
                { .cell = material_box(
                    scratch: &scratch,
                    lower: origin,
                    upper: origin + (Vec3){ 2, 2, 2 },
                    quantized: domain != 0,
                ), .occupied = true },
            };
            cells[0].next = &cells[1];
            SolidPartition partition = { .first = &cells[0], .cell_count = 2, .occupied_count = 2 };
            SolidPartition[] components = partition_material_components(&scratch, &partition)!!;
            assert(components.len == expected[variant]);
            assert_material_components(&partition, components);
            cells[0].next = null;
            cells[1].next = &cells[0];
            partition.first = &cells[1];
            components = partition_material_components(&scratch, &partition)!!;
            assert(components.len == expected[variant]);
            assert_material_components(&partition, components);
        }
    }
}

fn void test_material_components_join_unequal_subdivisions_and_transitive_neighbors() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell right = material_box(
            scratch: &scratch,
            lower: { 0, -1, -1 },
            upper: { 2, 1, 1 },
            quantized: domain != 0,
        );
        ExactPlane middle;
        plane_from_integers(scratch.exact, &middle, { 0, 1, 0, 0 })!!;
        CellSplit split = split_convex_cell(&scratch, &right, &middle)!!;
        PartitionCell[3] cells = {
            { .cell = split.positive, .occupied = true },
            { .cell = material_box(
                scratch: &scratch,
                lower: { -2, -1, -1 },
                upper: { 0, 1, 1 },
                quantized: domain != 0,
            ), .occupied = true },
            { .cell = split.negative, .occupied = true },
        };
        cells[0].next = &cells[1];
        cells[1].next = &cells[2];
        SolidPartition partition = { .first = &cells[0], .cell_count = 3, .occupied_count = 3 };
        SolidPartition[] components = partition_material_components(&scratch, &partition)!!;
        assert(components.len == 1 && components[0].cell_count == 3);
        assert_material_components(&partition, components);
        cells[0].cell = material_box(
            scratch: &scratch,
            lower: { -3, -1, -1 },
            upper: { -1, 1, 1 },
            quantized: domain != 0,
        );
        cells[1].cell = material_box(
            scratch: &scratch,
            lower: { 1, -1, -1 },
            upper: { 3, 1, 1 },
            quantized: domain != 0,
        );
        cells[2].cell = material_box(
            scratch: &scratch,
            lower: { -1, -1, -1 },
            upper: { 1, 1, 1 },
            quantized: domain != 0,
        );
        cells[2].occupied = false;
        partition.occupied_count = 2;
        components = partition_material_components(&scratch, &partition)!!;
        assert(components.len == 2);
        assert_material_components(&partition, components);
        cells[2].occupied = true;
        partition.occupied_count = 3;
        components = partition_material_components(&scratch, &partition)!!;
        assert(components.len == 1 && components[0].cell_count == 3);
        assert_material_components(&partition, components);
    }
}

fn void test_material_components_handle_oblique_rational_faces_and_raw_extremes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell whole = material_box(
            scratch: &scratch,
            lower: { -2, -2, -2 },
            upper: { 2, 2, 2 },
            quantized: domain != 0,
        );
        ExactPlane diagonal;
        plane_from_integers(scratch.exact, &diagonal, { 3, 5, 7, -1 })!!;
        CellSplit split = split_convex_cell(&scratch, &whole, &diagonal)!!;
        PartitionCell[2] cells = {
            { .cell = split.negative, .occupied = true }, { .cell = split.positive, .occupied = true },
        };
        cells[0].next = &cells[1];
        SolidPartition partition = { .first = &cells[0], .cell_count = 2, .occupied_count = 2 };
        scratch.exact.peak = 0;
        SolidPartition[] components = partition_material_components(&scratch, &partition)!!;
        assert(components.len == 1);
        assert_material_components(&partition, components);
        assert(scratch.exact.peak <= PROJECTED_ORIENTATION_TEMPORARIES && scratch.exact.count == 0);
    }
    SolidScratch scratch = begin_solid_scratch(&workspace);
    float tiny = bitcast((uint)1, float);
    PartitionCell[2] cells = {
        { .cell = material_box(
            scratch: &scratch,
            lower: { -float::max, -tiny, -tiny },
            upper: { 0, tiny, tiny },
            quantized: false,
        ), .occupied = true },
        { .cell = material_box(
            scratch: &scratch,
            lower: { 0, -tiny, -tiny },
            upper: { float::max, tiny, tiny },
            quantized: false,
        ), .occupied = true },
    };
    cells[0].next = &cells[1];
    SolidPartition partition = { .first = &cells[0], .cell_count = 2, .occupied_count = 2 };
    scratch.exact.peak = 0;
    SolidPartition[] components = partition_material_components(&scratch, &partition)!!;
    assert(components.len == 1);
    assert_material_components(&partition, components);
    assert(scratch.exact.peak <= PROJECTED_ORIENTATION_TEMPORARIES && scratch.exact.count == 0);
}

fn void test_material_components_empty_material_uses_no_scratch() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidPartition empty;
    usz saved = scratch.used;
    assert(partition_material_components(&scratch, &empty)!!.len == 0);
    assert(scratch.used == saved && scratch.exact.count == 0);
    PartitionCell cell = { .cell = material_box(
        scratch: &scratch,
        lower: { -1, -1, -1 },
        upper: { 1, 1, 1 },
        quantized: true,
    ) };
    empty = { .first = &cell, .cell_count = 1 };
    saved = scratch.used;
    scratch.storage = workspace.storage[:saved];
    assert(partition_material_components(&scratch, &empty)!!.len == 0);
    assert(scratch.used == saved && !cell.next && !cell.occupied);
}

fn void test_material_components_capacity_restores_input_and_reuses_workspace() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 1);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface surface = partition_surface(&scratch, &fixture, true);
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
    usz saved = scratch.used;
    char[] preserved = mem::new_array(char, (sz)(saved - MIN_FRACTURE_SCRATCH_BYTES));
    defer mem::free(preserved);
    preserved[..] = scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len];
    scratch.peak = saved;
    SolidPartition[] complete = partition_material_components(&scratch, &partition)!!;
    usz required = scratch.peak;
    assert(complete.len == 1 && scratch.used < required);
    for (usz capacity = saved; capacity < required; capacity += 31) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(partition_material_components(&scratch, &partition)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required - 1];
    assert(@catch(partition_material_components(&scratch, &partition)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    scratch.storage = workspace.storage[:required];
    uint held = EXACT_TEMPORARIES;
    for (uint index = 0; index < held; index++) (void)scratch.exact.take()!!;
    assert(@catch(partition_material_components(&scratch, &partition)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == held);
    scratch.exact.count = 0;
    complete = partition_material_components(&scratch, &partition)!!;
    assert(complete.len == 1);
    assert_material_components(&partition, complete);
    foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
}

fn ConvexCell material_box(
    SolidScratch* scratch,
    Vec3 lower,
    Vec3 upper,
    bool quantized,
) @local {
    ContainmentFixture fixture;
    append_box_fixture(&fixture, lower, upper);
    SolidSurface surface = partition_surface(scratch, &fixture, quantized);
    return create_bounds_cell(scratch, &surface)!!;
}

fn void assert_material_components(SolidPartition* source, SolidPartition[] components) @local {
    uint total;
    uint previous_first;
    foreach (usz component_index, component : components) {
        assert(component.first && component.cell_count == component.occupied_count);
        uint count;
        uint previous;
        for (PartitionCell* cell = component.first; cell; cell = cell.next) {
            assert(cell.occupied);
            uint index;
            PartitionCell* original = source.first;
            while (original && original.cell.vertices.ptr != cell.cell.vertices.ptr) {
                original = original.next;
                index++;
            }
            assert(original && original.occupied && original != cell);
            assert(cell.cell.faces.ptr == original.cell.faces.ptr && cell.cell.corners.ptr == original.cell.corners.ptr);
            if (count) assert(index > previous);
            if (!count) {
                if (component_index) assert(index > previous_first);
                previous_first = index;
            }
            previous = index;
            count++;
        }
        assert(count == component.cell_count);
        total += count;
    }
    assert(total == source.occupied_count);
    for (PartitionCell* original = source.first; original; original = original.next) {
        uint occurrences;
        foreach (component : components) for (PartitionCell* cell = component.first; cell; cell = cell.next) {
            occurrences += cell.cell.vertices.ptr == original.cell.vertices.ptr ? 1 : 0;
        }
        assert(occurrences == (original.occupied ? 1 : 0));
    }
}
