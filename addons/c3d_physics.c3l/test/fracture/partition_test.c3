module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_partition_preserves_concavity_cavities_islands_and_disconnected_material() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    uint[5] cells = { 1, 7, 13, 3, 3 };
    uint[5] occupied = { 1, 6, 7, 2, 2 };
    double[5] fractions = { 1, 208.0 / 216, 160.0 / 216, 2.0 / 3, 0.75 };
    for (uint shape = 0; shape < cells.len; shape++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        for (uint domain = 0; domain < 2; domain++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
            SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
            scratch.exact.peak = 0;
            SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
            assert(partition.cell_count == cells[shape] && partition.occupied_count == occupied[shape]);
            assert(scratch.exact.peak == 23 && scratch.exact.count == 0);
            assert_partition(&scratch, &partition, &surface, &source, fractions[shape]);
        }
    }
}

fn void test_partition_source_face_permutations_preserve_occupied_region() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 1; shape < 5; shape++) {
        for (uint domain = 0; domain < 2; domain++) {
            ContainmentFixture first_fixture;
            ContainmentFixture second_fixture;
            partition_fixture(&first_fixture, shape);
            partition_fixture(&second_fixture, shape);
            for (uint face = 0; face < second_fixture.triangle_count / 2; face++) {
                uint other = second_fixture.triangle_count - face - 1;
                for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                    uint saved = second_fixture.indices[face * TRIANGLE_CORNERS + corner];
                    second_fixture.indices[face * TRIANGLE_CORNERS + corner] = second_fixture.indices[other * TRIANGLE_CORNERS + corner];
                    second_fixture.indices[other * TRIANGLE_CORNERS + corner] = saved;
                }
            }
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidSurface first_surface = partition_surface(&scratch, &first_fixture, domain != 0);
            SourceConstructions first_source = build_source_constructions(&scratch, &first_surface)!!;
            SolidPartition first = partition_solid(&scratch, &first_surface, &first_source)!!;
            SolidSurface second_surface = partition_surface(&scratch, &second_fixture, domain != 0);
            SourceConstructions second_source = build_source_constructions(&scratch, &second_surface)!!;
            SolidPartition second = partition_solid(&scratch, &second_surface, &second_source)!!;
            assert_same_partition_region(scratch.exact, &first, &second);
            assert_same_partition_region(scratch.exact, &second, &first);
            assert_partition_intersections(&scratch, &first, &second);
            SolidPartition repeated = partition_solid(&scratch, &second_surface, &second_source)!!;
            assert(second.cell_count == repeated.cell_count && second.occupied_count == repeated.occupied_count);
            PartitionCell* original = second.first;
            for (PartitionCell* cell = repeated.first; cell; cell = cell.next) {
                assert(original && original.occupied == cell.occupied);
                assert_same_cell(scratch.exact, &original.cell, &cell.cell);
                original = original.next;
            }
            assert(!original && scratch.exact.count == 0);
        }
    }
}

fn void test_partition_face_overlap_rejects_support_extensions_points_and_edges() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        ContainmentFixture surrounding;
        append_box_fixture(&surrounding, { -2, -2, -2 }, { 2, 2, 2 });
        SolidSurface bounds = partition_surface(&scratch, &surrounding, domain != 0);
        ConvexCell cell = create_bounds_cell(&scratch, &bounds)!!;
        assert(source_face_crosses_cell(
            scratch: &scratch, surface: &surface, source: &source, face: 0, cell: &cell,
        )!!);
        ExactPlane middle;
        plane_from_integers(scratch.exact, &middle, { 1, 0, 0, 0 })!!;
        CellSplit crease = split_convex_cell(&scratch, &cell, &middle)!!;
        assert(source_face_crosses_cell(
            scratch: &scratch, surface: &surface, source: &source, face: 5, cell: &crease.positive,
        )!!);
        ExactPlane[2] cuts;
        for (uint axis = 0; axis < 2; axis++) {
            bounds_axis_plane(
                scratch: scratch.exact, plane: &cuts[axis], axis: axis,
                bound: domain ? 4 : (long)bitcast(1.0f, uint), quantized: domain != 0,
            )!!;
            CellSplit split = split_convex_cell(&scratch, &cell, &cuts[axis])!!;
            cell = split.positive;
            usz saved = scratch.used;
            assert(!source_face_crosses_cell(
                scratch: &scratch, surface: &surface, source: &source, face: 0, cell: &cell,
            )!!);
            assert(scratch.used == saved && scratch.exact.count == 0);
        }
        bounds_axis_plane(
            scratch: scratch.exact, plane: &cuts[0], axis: 0,
            bound: domain ? 6 : (long)bitcast(1.5f, uint), quantized: domain != 0,
        )!!;
        cell = create_bounds_cell(&scratch, &bounds)!!;
        CellSplit split = split_convex_cell(&scratch, &cell, &cuts[0])!!;
        assert(!source_face_crosses_cell(
            scratch: &scratch, surface: &surface, source: &source, face: 0, cell: &split.positive,
        )!!);
    }
}

fn void test_partition_sample_is_exact_and_strictly_interior_after_rational_cuts() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        ConvexCell cell = create_bounds_cell(&scratch, &surface)!!;
        ExactPlane[3] cuts;
        int128[4][3] coefficients = { { 3, 1, 0, -1 }, { 1, -5, 2, -1 }, { 2, 3, 7, -1 } };
        foreach (uint index, values : coefficients) {
            plane_from_integers(scratch.exact, &cuts[index], values)!!;
            CellSplit split = split_convex_cell(&scratch, &cell, &cuts[index])!!;
            cell = split.negative;
        }
        assert_cell(&scratch, &cell);
        assert_interior_sample(scratch.exact, &cell);
        uint saved = scratch.exact.count;
        HomogeneousPoint sample = sample_cell_interior(scratch.exact, &cell)!!;
        assert(sample[3].used && !sample[3].negative);
        scratch.exact.count = saved;
        assert(scratch.exact.peak == 23);
    }
}

fn void test_partition_occupancy_keeps_subnormal_and_extreme_raw_coordinates() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 2; variant++) {
        ContainmentFixture fixture;
        append_box_fixture(&fixture, { -1, -1, -1 }, { 1, 1, 1 });
        foreach (&point : fixture.positions[:fixture.vertex_count]) {
            point.x = point.x < 0 ? -float::max : float::max;
            point.y = point.y < 0 ? -bitcast((uint)1, float) : bitcast((uint)2, float);
            if (variant) point.z = point.z < 0 ? -bitcast((uint)3, float) : bitcast((uint)5, float);
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, false);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        assert(partition.cell_count == 1 && partition.occupied_count == 1);
        assert_interior_sample(scratch.exact, &partition.first.cell);
        assert(scratch.exact.peak == 23 && scratch.exact.count == 0);
    }
}

fn void test_partition_capacity_failure_restores_workspace_and_reuses_source() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 4);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface surface = partition_surface(&scratch, &fixture, false);
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    usz saved = scratch.used;
    SolidPartition complete = partition_solid(&scratch, &surface, &source)!!;
    usz required = scratch.peak;
    assert(complete.cell_count == 3 && complete.occupied_count == 2);
    for (usz capacity = saved; capacity < required; capacity += 211) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(partition_solid(&scratch, &surface, &source)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && surface.validated);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required];
    complete = partition_solid(&scratch, &surface, &source)!!;
    assert(complete.cell_count == 3 && complete.occupied_count == 2 && scratch.exact.count == 0);
}

fn void test_partition_oblique_shells_match_exact_inverse_transformed_occupancy() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, 2);
        foreach (uint index, &point : fixture.positions[:fixture.vertex_count]) {
            *point = { point.x + 2 * point.y + point.z, point.y + point.z, point.z };
            for (uint axis = 0; axis < SPACE_AXES; axis++) fixture.grid[index][axis] = (long)((*point)[axis] * 4);
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        assert(partition.cell_count > 13 && partition.occupied_count >= 7 && scratch.exact.peak == 23);
        ExactPlane[18] boundaries;
        int128[4][3] normals = { { 1, -2, 1, 0 }, { 0, 1, -1, 0 }, { 0, 0, 1, 0 } };
        for (uint shell = 0; shell < 3; shell++) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                for (uint end = 0; end < 2; end++) {
                    float bound = (end ? 1 : -1) * (float)(3 - shell);
                    ExactPlane offset;
                    bounds_axis_plane(
                        scratch: scratch.exact, plane: &offset, axis: axis,
                        bound: domain ? (long)(bound * 4) : (bound < 0 ? -(long)bitcast(-bound, uint) : (long)bitcast(bound, uint)),
                        quantized: domain != 0,
                    )!!;
                    ExactPlane* boundary = &boundaries[shell * BOX_PLANES + axis * 2 + end];
                    plane_from_integers(scratch.exact, boundary, normals[axis])!!;
                    boundary.coefficients[SPACE_AXES] = offset.coefficients[SPACE_AXES];
                }
            }
        }
        for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
            assert_cell(&scratch, &cell.cell);
            uint saved = scratch.exact.count;
            HomogeneousPoint sample = sample_cell_interior(scratch.exact, &cell.cell)!!;
            bool expected;
            for (uint shell = 0; shell < 3; shell++) {
                bool contained = true;
                for (uint boundary = 0; boundary < BOX_PLANES; boundary++) {
                    int side = homogeneous_plane_side(scratch.exact, &boundaries[shell * BOX_PLANES + boundary], sample)!!;
                    if ((boundary & 1) ? side >= 0 : side <= 0) contained = false;
                }
                expected ^= contained;
            }
            assert(cell.occupied == expected);
            scratch.exact.count = saved;
        }
    }
}

fn SolidSurface partition_surface(SolidScratch* scratch, ContainmentFixture* fixture, bool quantized) @local {
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(scratch, fixture.mesh, &diagnostic)!!;
    if (quantized) {
        surface.grid = fixture.grid[:fixture.vertex_count];
        check_surface_geometry(&surface, &diagnostic)!!;
    }
    (void)build_solid_nesting(scratch, &surface, &diagnostic)!!;
    return surface;
}

fn void partition_fixture(ContainmentFixture* fixture, uint shape) @local {
    if (shape == 4) {
        Vec3[12] positions = {
            { 0, 0, 0 }, { 2, 0, 0 }, { 2, 1, 0 }, { 1, 1, 0 }, { 1, 2, 0 }, { 0, 2, 0 },
            { 0, 0, 1 }, { 2, 0, 1 }, { 2, 1, 1 }, { 1, 1, 1 }, { 1, 2, 1 }, { 0, 2, 1 },
        };
        uint[60] indices;
        uint count;
        for (uint index = 1; index < 5; index++) {
            indices[count++] = 0; indices[count++] = index + 1; indices[count++] = index;
            indices[count++] = 6; indices[count++] = index + 6; indices[count++] = index + 7;
        }
        for (uint index = 0; index < 6; index++) {
            uint next = (index + 1) % 6;
            indices[count++] = index; indices[count++] = next; indices[count++] = next + 6;
            indices[count++] = index; indices[count++] = next + 6; indices[count++] = index + 6;
        }
        append_shell_fixture(
            fixture: fixture, positions: positions[..], indices: indices[..], reversed: false,
        );
        return;
    }
    if (shape == 3) {
        append_box_fixture(fixture, { -3, -1, -1 }, { -1, 1, 1 });
        append_box_fixture(fixture, { 1, -1, -1 }, { 3, 1, 1 });
        return;
    }
    append_box_fixture(fixture, { -3, -3, -3 }, { 3, 3, 3 });
    if (!shape) return;
    float extent = shape == 1 ? 1 : 2;
    append_box_fixture(
        fixture: fixture, lower: { -extent, -extent, -extent }, upper: { extent, extent, extent }, reversed: true,
    );
    if (shape == 2) append_box_fixture(fixture, { -1, -1, -1 }, { 1, 1, 1 });
}

fn void assert_interior_sample(ExactScratch* scratch, ConvexCell* cell) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint sample = sample_cell_interior(scratch, cell)!!;
    foreach (face : cell.faces) {
        int side = homogeneous_plane_side(scratch, face.plane, sample)!!;
        assert(face.reversed ? side > 0 : side < 0);
    }
}

fn void assert_partition(
    SolidScratch* scratch,
    SolidPartition* partition,
    SolidSurface* surface,
    SourceConstructions* source,
    double expected_fraction,
) @local {
    uint count;
    uint occupied;
    double full_volume;
    double material_volume;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        count++;
        occupied += cell.occupied ? 1 : 0;
        assert_cell(scratch, &cell.cell);
        assert_interior_sample(scratch.exact, &cell.cell);
        foreach (face : cell.cell.faces) foreach (&edge : source.edges) assert(face.plane != &edge.plane);
        for (uint face = 0; face < source.faces.len; face++) {
            assert(!source_face_crosses_cell(
                scratch: scratch, surface: surface, source: source, face: face, cell: &cell.cell,
            )!!);
        }
        double volume = cell_volume(scratch.exact, &cell.cell);
        full_volume += volume;
        if (cell.occupied) material_volume += volume;
    }
    ConvexCell bounds = create_bounds_cell(scratch, surface)!!;
    double bounds_volume = cell_volume(scratch.exact, &bounds);
    assert(count == partition.cell_count && occupied == partition.occupied_count);
    assert(math::abs(full_volume / bounds_volume - 1) < 1e-12);
    assert(math::abs(material_volume / bounds_volume - expected_fraction) < 1e-12);
}

fn void assert_same_partition_region(ExactScratch* scratch, SolidPartition* first, SolidPartition* second) @local {
    for (PartitionCell* cell = first.first; cell; cell = cell.next) {
        uint saved = scratch.count;
        HomogeneousPoint sample = sample_cell_interior(scratch, &cell.cell)!!;
        bool found;
        for (PartitionCell* other = second.first; other; other = other.next) {
            bool contained = true;
            foreach (face : other.cell.faces) {
                int side = homogeneous_plane_side(scratch, face.plane, sample)!!;
                if (face.reversed ? side < 0 : side > 0) {
                    contained = false;
                    break;
                }
            }
            if (contained) {
                found = true;
                assert(cell.occupied == other.occupied);
            }
        }
        assert(found);
        scratch.count = saved;
    }
}

fn void assert_partition_intersections(SolidScratch* scratch, SolidPartition* first, SolidPartition* second) @local {
    for (PartitionCell* left = first.first; left; left = left.next) {
        for (PartitionCell* right = second.first; right; right = right.next) {
            if (left.occupied == right.occupied) continue;
            usz saved = scratch.used;
            ConvexCell intersection = left.cell;
            foreach (face : right.cell.faces) {
                CellSplit split = split_convex_cell(scratch, &intersection, face.plane)!!;
                intersection = face.reversed ? split.positive : split.negative;
                if (!intersection.vertices.len) break;
            }
            assert(!intersection.vertices.len);
            scratch.used = saved;
        }
    }
}
