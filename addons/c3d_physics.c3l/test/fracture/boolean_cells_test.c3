module c3d::physics::fracture;

import c3d;
import std::math;

const BooleanOperation[3] BOOLEAN_TEST_OPERATIONS @local = {
    BooleanOperation.UNION, BooleanOperation.INTERSECTION, BooleanOperation.DIFFERENCE,
};
const int128 BOOLEAN_VOLUME_UNITS_PER_METRE_CUBED @local = 64;

enum BooleanShape @local {
    BOX,
    HOLLOW,
    CONCAVE,
}

struct BooleanInput @local {
    ContainmentFixture fixture;
    SolidSurface surface;
    SourceConstructions source;
    BooleanShape shape;
}

fn void test_boolean_cells_box_operations_match_exact_known_volumes_in_both_domains() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    long[3][6] volumes = {
        { 96, 32, 32 }, { 16, 0, 8 }, { 64, 64, 0 }, { 216, 8, 208 }, { 216, 8, 0 }, { 16, 0, 8 },
    };
    for (uint domain = 0; domain < 2; domain++) {
        for (uint variant = 0; variant < volumes.len; variant++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            BooleanInput first;
            BooleanInput second;
            boolean_box_pair(&first, &second, variant);
            build_boolean_input(&scratch, &first, domain != 0);
            build_boolean_input(&scratch, &second, domain != 0);
            usz retained = scratch.used;
            foreach (uint index, operation : BOOLEAN_TEST_OPERATIONS) {
                scratch.used = retained;
                SolidPartition partition = partition_boolean_cells(
                    scratch: &scratch,
                    first: &first.surface,
                    first_source: &first.source,
                    second: &second.surface,
                    second_source: &second.source,
                    operation: operation,
                )!!;
                assert_boolean_partition(
                    scratch: &scratch,
                    partition: &partition,
                    first: &first,
                    second: &second,
                    operation: operation,
                    quantized: domain != 0,
                    expected_volume: (int128)volumes[variant][index] * BOOLEAN_VOLUME_UNITS_PER_METRE_CUBED,
                );
                if (variant == 2) {
                    assert(partition.cell_count == 1);
                    assert(partition.face_tests == first.source.faces.len + second.source.faces.len);
                    ulong expected_ray_faces;
                    assert(cell_is_occupied(
                        surface: &first.surface,
                        source: &first.source,
                        cell: &partition.first.cell,
                        candidate_faces: &expected_ray_faces,
                    )!!);
                    assert(cell_is_occupied(
                        surface: &second.surface,
                        source: &second.source,
                        cell: &partition.first.cell,
                        candidate_faces: &expected_ray_faces,
                    )!!);
                    assert(partition.ray_faces == expected_ray_faces);
                }
            }
        }
    }
}

fn void test_boolean_cells_hollow_and_concave_combinations_keep_exact_material() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    long[3][2] volumes = { { 216 * 64, 56 * 64, 152 * 64 }, { 208, 48, 144 } };
    for (uint domain = 0; domain < 2; domain++) for (uint shape = 0; shape < 2; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        BooleanInput first;
        BooleanInput second;
        boolean_complex_pair(&first, &second, shape);
        build_boolean_input(&scratch, &first, domain != 0);
        build_boolean_input(&scratch, &second, domain != 0);
        usz retained = scratch.used;
        foreach (uint index, operation : BOOLEAN_TEST_OPERATIONS) {
            scratch.used = retained;
            SolidPartition partition = partition_boolean_cells(
                scratch: &scratch,
                first: &first.surface,
                first_source: &first.source,
                second: &second.surface,
                second_source: &second.source,
                operation: operation,
            )!!;
            assert_boolean_partition(
                scratch: &scratch,
                partition: &partition,
                first: &first,
                second: &second,
                operation: operation,
                quantized: domain != 0,
                expected_volume: volumes[shape][index],
            );
        }
    }
}

fn void test_boolean_cells_source_face_permutations_preserve_selected_region() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        BooleanInput first;
        BooleanInput second;
        BooleanInput permuted_first;
        BooleanInput permuted_second;
        boolean_complex_pair(&first, &second, 1);
        boolean_complex_pair(&permuted_first, &permuted_second, 1);
        reverse_boolean_faces(&permuted_first.fixture);
        reverse_boolean_faces(&permuted_second.fixture);
        build_boolean_input(&scratch, &first, domain != 0);
        build_boolean_input(&scratch, &second, domain != 0);
        build_boolean_input(&scratch, &permuted_first, domain != 0);
        build_boolean_input(&scratch, &permuted_second, domain != 0);
        usz retained = scratch.used;
        foreach (uint operation_index, operation : BOOLEAN_TEST_OPERATIONS) {
            scratch.used = retained;
            SolidPartition original = partition_boolean_cells(
                scratch: &scratch,
                first: &first.surface,
                first_source: &first.source,
                second: &second.surface,
                second_source: &second.source,
                operation: operation,
            )!!;
            SolidPartition permuted = partition_boolean_cells(
                scratch: &scratch,
                first: &permuted_first.surface,
                first_source: &permuted_first.source,
                second: &permuted_second.surface,
                second_source: &permuted_second.source,
                operation: operation,
            )!!;
            long[3] volumes = { 208, 48, 144 };
            assert_boolean_partition(
                scratch: &scratch,
                partition: &permuted,
                first: &permuted_first,
                second: &permuted_second,
                operation: operation,
                quantized: domain != 0,
                expected_volume: volumes[operation_index],
            );
            for (PartitionCell* left = original.first; left; left = left.next) {
                SolidBounds left_bounds = boolean_cell_bounds(scratch.exact, &left.cell, domain != 0);
                for (PartitionCell* right = permuted.first; right; right = right.next) {
                    if (left.occupied == right.occupied) continue;
                    SolidBounds right_bounds = boolean_cell_bounds(scratch.exact, &right.cell, domain != 0);
                    assert(!boolean_bounds_overlap(left_bounds, right_bounds));
                }
            }
            SolidPartition repeated = partition_boolean_cells(
                scratch: &scratch,
                first: &first.surface,
                first_source: &first.source,
                second: &second.surface,
                second_source: &second.source,
                operation: operation,
            )!!;
            assert(repeated.cell_count == original.cell_count && repeated.occupied_count == original.occupied_count);
            assert(repeated.face_tests == original.face_tests && repeated.ray_faces == original.ray_faces);
            PartitionCell* previous = original.first;
            for (PartitionCell* cell = repeated.first; cell; cell = cell.next) {
                assert(previous && previous.occupied == cell.occupied);
                assert_same_cell(scratch.exact, &previous.cell, &cell.cell);
                previous = previous.next;
            }
            assert(!previous && scratch.exact.count == 0);
        }
    }
}

fn void test_boolean_cells_failures_restore_both_sources_and_allow_arithmetic_reuse() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    BooleanInput first;
    BooleanInput second;
    boolean_box_pair(&first, &second, 0);
    build_boolean_input(&scratch, &first, true);
    build_boolean_input(&scratch, &second, true);
    usz saved = scratch.used;
    char[] preserved = mem::new_array(char, (sz)(saved - MIN_FRACTURE_SCRATCH_BYTES));
    defer mem::free(preserved);
    preserved[..] = scratch.storage[MIN_FRACTURE_SCRATCH_BYTES:preserved.len];
    scratch.peak = saved;
    SolidPartition complete = partition_boolean_cells(
        scratch: &scratch,
        first: &first.surface,
        first_source: &first.source,
        second: &second.surface,
        second_source: &second.source,
        operation: BooleanOperation.UNION,
    )!!;
    usz required = scratch.peak;
    assert(complete.occupied_count > 0);
    foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
    for (usz capacity = saved; capacity < required; capacity += 173) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(partition_boolean_cells(
            scratch: &scratch,
            first: &first.surface,
            first_source: &first.source,
            second: &second.surface,
            second_source: &second.source,
            operation: BooleanOperation.UNION,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required - 1];
    assert(@catch(partition_boolean_cells(
        scratch: &scratch,
        first: &first.surface,
        first_source: &first.source,
        second: &second.surface,
        second_source: &second.source,
        operation: BooleanOperation.UNION,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == 0);
    scratch.storage = workspace.storage[:required];
    uint held = 2;
    for (uint index = 0; index < held; index++) (void)scratch.exact.take()!!;
    assert(@catch(partition_boolean_cells(
        scratch: &scratch,
        first: &first.surface,
        first_source: &first.source,
        second: &second.surface,
        second_source: &second.source,
        operation: BooleanOperation.UNION,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == held);
    scratch.exact.count = 0;
    complete = partition_boolean_cells(
        scratch: &scratch,
        first: &first.surface,
        first_source: &first.source,
        second: &second.surface,
        second_source: &second.source,
        operation: BooleanOperation.UNION,
    )!!;
    assert(complete.occupied_count > 0 && scratch.exact.count == 0);
    foreach (usz index, byte : preserved) assert(byte == scratch.storage[MIN_FRACTURE_SCRATCH_BYTES + index]);
}

fn void build_boolean_input(SolidScratch* scratch, BooleanInput* input, bool quantized) @local {
    input.surface = partition_surface(scratch, &input.fixture, quantized);
    input.source = build_source_constructions(scratch, &input.surface)!!;
}

fn void boolean_box_pair(BooleanInput* first, BooleanInput* second, uint variant) @local {
    Vec3[2][6] first_bounds = {
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -3, -1, -1 }, { -1, 1, 1 } },
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -3, -3, -3 }, { 3, 3, 3 } },
        { { -1, -1, -1 }, { 1, 1, 1 } }, { { -2, -1, -1 }, { 0, 1, 1 } },
    };
    Vec3[2][6] second_bounds = {
        { { 0, -2, -2 }, { 4, 2, 2 } }, { { 1, -1, -1 }, { 3, 1, 1 } },
        { { -2, -2, -2 }, { 2, 2, 2 } }, { { -1, -1, -1 }, { 1, 1, 1 } },
        { { -3, -3, -3 }, { 3, 3, 3 } }, { { 0, -1, -1 }, { 2, 1, 1 } },
    };
    append_box_fixture(&first.fixture, first_bounds[variant][0], first_bounds[variant][1]);
    append_box_fixture(&second.fixture, second_bounds[variant][0], second_bounds[variant][1]);
}

fn void boolean_complex_pair(BooleanInput* first, BooleanInput* second, uint shape) @local {
    first.shape = shape ? BooleanShape.CONCAVE : BooleanShape.HOLLOW;
    partition_fixture(&first.fixture, shape ? 4 : 1);
    if (shape) {
        append_box_fixture(&second.fixture, { 0.5, 0.5, 0 }, { 1.5, 1.5, 1 });
    } else {
        append_box_fixture(&second.fixture, { -2, -2, -2 }, { 2, 2, 2 });
    }
}

fn void reverse_boolean_faces(ContainmentFixture* fixture) @local {
    for (uint face = 0; face < fixture.triangle_count / 2; face++) {
        uint other = fixture.triangle_count - face - 1;
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint saved = fixture.indices[face * TRIANGLE_CORNERS + corner];
            fixture.indices[face * TRIANGLE_CORNERS + corner] = fixture.indices[other * TRIANGLE_CORNERS + corner];
            fixture.indices[other * TRIANGLE_CORNERS + corner] = saved;
        }
    }
}

fn SolidBounds boolean_fixture_bounds(ContainmentFixture* fixture) @local {
    SolidBounds bounds = { .lower = fixture.grid[0], .upper = fixture.grid[0] };
    foreach (point : fixture.grid[:fixture.vertex_count]) for (uint axis = 0; axis < SPACE_AXES; axis++) {
        bounds.lower[axis] = math::min(bounds.lower[axis], point[axis]);
        bounds.upper[axis] = math::max(bounds.upper[axis], point[axis]);
    }
    return bounds;
}

fn bool boolean_point_in_box(GridPoint point, GridPoint lower, GridPoint upper) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (point[axis] <= lower[axis] * 2 || point[axis] >= upper[axis] * 2) return false;
    }
    return true;
}

fn bool boolean_fixture_contains(BooleanInput* input, GridPoint twice_point) @local {
    SolidBounds bounds = boolean_fixture_bounds(&input.fixture);
    if (!boolean_point_in_box(twice_point, bounds.lower, bounds.upper)) return false;
    switch (input.shape) {
        case BooleanShape.BOX: return true;
        case BooleanShape.HOLLOW:
            return !boolean_point_in_box(twice_point, input.fixture.grid[8], input.fixture.grid[15]);
        case BooleanShape.CONCAVE:
            return twice_point[0] < input.fixture.grid[3][0] * 2 || twice_point[1] < input.fixture.grid[3][1] * 2;
    }
}

fn SolidBounds boolean_cell_bounds(ExactScratch* scratch, ConvexCell* cell, bool quantized) @local {
    assert(cell.vertices.len == BOX_VERTICES);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* unit = scratch.take()!!;
    WideInteger* quotient = scratch.take()!!;
    WideInteger* remainder = scratch.take()!!;
    if (quantized) {
        set_integer(unit, 1);
    } else {
        integer_from_float(unit, 0.25f);
    }
    GridPoint[BOX_VERTICES] positions;
    SolidBounds bounds;
    foreach (uint index, vertex : cell.vertices) {
        uint held = scratch.count;
        defer scratch.count = held;
        HomogeneousPoint point;
        foreach (&coordinate : point) *coordinate = scratch.take()!!;
        construct_point(scratch, point, vertex)!!;
        assert(point[SPACE_AXES].used == 1 && point[SPACE_AXES].limbs[0] == 1 && !point[SPACE_AXES].negative);
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            divide_magnitude(
                scratch: scratch,
                quotient: quotient,
                remainder: remainder,
                numerator: point[axis].view(),
                denominator: unit.view(),
            )!!;
            assert(!remainder.used && quotient.used <= 1);
            long magnitude = quotient.used ? (long)quotient.limbs[0] : 0;
            positions[index][axis] = point[axis].negative ? -magnitude : magnitude;
        }
        if (!index) bounds = { .lower = positions[index], .upper = positions[index] };
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            bounds.lower[axis] = math::min(bounds.lower[axis], positions[index][axis]);
            bounds.upper[axis] = math::max(bounds.upper[axis], positions[index][axis]);
        }
    }
    for (uint axis = 0; axis < SPACE_AXES; axis++) foreach (point : positions) {
        assert(point[axis] == bounds.lower[axis] || point[axis] == bounds.upper[axis]);
    }
    return bounds;
}

fn int128 boolean_bounds_volume(SolidBounds bounds) @local {
    int128 volume = 1;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        assert(bounds.upper[axis] > bounds.lower[axis]);
        volume *= (int128)(bounds.upper[axis] - bounds.lower[axis]);
    }
    return volume;
}

fn bool boolean_bounds_overlap(SolidBounds first, SolidBounds second) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (first.upper[axis] <= second.lower[axis] || second.upper[axis] <= first.lower[axis]) return false;
    }
    return true;
}

fn void assert_boolean_partition(
    SolidScratch* scratch,
    SolidPartition* partition,
    BooleanInput* first,
    BooleanInput* second,
    BooleanOperation operation,
    bool quantized,
    int128 expected_volume,
) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    SolidBounds[] bounds = reserve_elements(scratch, SolidBounds, partition.cell_count)!!;
    uint count;
    uint occupied;
    int128 selected_volume;
    int128 full_volume;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        assert_cell(scratch, &cell.cell);
        bounds[count] = boolean_cell_bounds(scratch.exact, &cell.cell, quantized);
        int128 volume = boolean_bounds_volume(bounds[count]);
        full_volume += volume;
        GridPoint twice_point;
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            twice_point[axis] = bounds[count].lower[axis] + bounds[count].upper[axis];
        }
        bool first_inside = boolean_fixture_contains(first, twice_point);
        bool second_inside = boolean_fixture_contains(second, twice_point);
        bool expected;
        switch (operation) {
            case BooleanOperation.UNION: expected = first_inside || second_inside;
            case BooleanOperation.INTERSECTION: expected = first_inside && second_inside;
            case BooleanOperation.DIFFERENCE: expected = first_inside && !second_inside;
        }
        assert(cell.occupied == expected);
        if (cell.occupied) {
            selected_volume += volume;
            occupied++;
        }
        count++;
    }
    assert(count == partition.cell_count && occupied == partition.occupied_count);
    assert(selected_volume == expected_volume);
    SolidBounds combined = joined_solid_bounds(
        boolean_fixture_bounds(&first.fixture), boolean_fixture_bounds(&second.fixture),
    );
    assert(full_volume == boolean_bounds_volume(combined));
    for (uint left = 0; left < count; left++) for (uint right = left + 1; right < count; right++) {
        assert(!boolean_bounds_overlap(bounds[left], bounds[right]));
    }
    assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
}
