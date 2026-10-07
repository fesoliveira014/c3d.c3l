module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_triangulation_keeps_concavity_holes_islands_and_collinear_constraints() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 7; shape++) for (uint domain = 0; domain < 2; domain++) {
        for (uint transform = 0; transform < 6; transform++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            PlanarFixture fixture;
            triangulation_fixture(
                scratch: scratch.exact,
                fixture: &fixture,
                shape: shape,
                quantized: domain != 0,
            );
            transform_patch_fixture(scratch.exact, &fixture, transform);
            BoundaryPatch patch = preserved_fixture_patch(&scratch, &fixture, false);
            scratch.exact.peak = 0;
            PatchTriangles triangles = triangulate_boundary_patch(&scratch, &patch)!!;
            assert_patch_triangulation(scratch.exact, &patch, &triangles);
            uint[7] expected = { 6, 4, 8, 14, 10, 12, 17 };
            assert(triangles.triangles.len == expected[shape]);
            assert(scratch.exact.peak <= PROJECTED_ORIENTATION_TEMPORARIES && scratch.exact.count == 0);
        }
    }
}

fn void test_triangulation_reversed_contours_keep_canonical_triangles() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 7; shape++) for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        triangulation_fixture(
            scratch: scratch.exact,
            fixture: &fixture,
            shape: shape,
            quantized: domain != 0,
        );
        transform_patch_fixture(scratch.exact, &fixture, 1);
        BoundaryPatch first = preserved_fixture_patch(&scratch, &fixture, false);
        PatchTriangles first_triangles = triangulate_boundary_patch(&scratch, &first)!!;
        foreach (&segment : fixture.segments[:fixture.segment_count]) {
            PlaneTriple previous = segment.first;
            segment.first = segment.second;
            segment.second = previous;
        }
        BoundaryPatch second = preserved_fixture_patch(&scratch, &fixture, true);
        PatchTriangles second_triangles = triangulate_boundary_patch(&scratch, &second)!!;
        assert_same_patch_triangles(scratch.exact, &first_triangles, &second_triangles);
        assert_patch_triangulation(scratch.exact, &second, &second_triangles);
    }
}

fn void test_triangulation_shared_cut_reuses_one_surface_with_opposite_winding() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 7; shape++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        triangulation_fixture(
            scratch: scratch.exact,
            fixture: &fixture,
            shape: shape,
            quantized: false,
        );
        BoundaryPatch patch = preserved_fixture_patch(&scratch, &fixture, false);
        usz saved = scratch.used;
        PatchTriangles single = triangulate_boundary_patch(&scratch, &patch)!!;
        usz triangle_bytes = scratch.used - saved;
        scratch.used = saved;
        OrientedPatchTriangles[2] views = triangulate_shared_cut(&scratch, &patch)!!;
        assert(views[0].shared == views[1].shared && views[0].reversed != views[1].reversed);
        assert(views[0].shared.vertices.ptr == patch.boundary.vertices.ptr);
        assert(scratch.used - saved >= triangle_bytes + PatchTriangles::size);
        assert(scratch.used - saved < triangle_bytes + PatchTriangles::size + PatchTriangles::alignment);
        assert(views[0].shared.triangles.len == single.triangles.len);
        foreach (uint index, triangle : views[0].shared.triangles) {
            uint[3] first = oriented_patch_triangle(views[0], index);
            uint[3] second = oriented_patch_triangle(views[1], index);
            assert(first[0] == second[0] && first[1] == second[2] && first[2] == second[1]);
            assert(first == triangle.vertices);
        }
        assert_patch_triangulation(scratch.exact, &patch, views[0].shared);
    }
}

fn void test_triangulation_source_face_permutations_keep_original_and_cut_triangles() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 1; shape < 5; shape++) for (uint domain = 0; domain < 2; domain++) {
        for (uint clipped = 0; clipped < 2; clipped++) {
            ContainmentFixture[2] fixtures;
            SolidScratch scratch = begin_solid_scratch(&workspace);
            BoundaryPatch[][2] patches;
            ExactPlane plane;
            plane_from_integers(scratch.exact, &plane, { 1, -1, 1, 0 })!!;
            for (uint variant = 0; variant < 2; variant++) {
                ContainmentFixture* fixture = &fixtures[variant];
                partition_fixture(fixture, shape);
                if (variant) for (uint face = 0; face < fixture.triangle_count; face++) {
                    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                        fixture.indices[face * TRIANGLE_CORNERS + corner] = fixtures[0].indices[(fixture.triangle_count - face - 1) * TRIANGLE_CORNERS + corner];
                    }
                }
                SolidSurface surface = partition_surface(&scratch, fixture, domain != 0);
                SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
                SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
                if (clipped) for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
                    if (!cell.occupied) continue;
                    CellSplit split = split_convex_cell(&scratch, &cell.cell, &plane)!!;
                    cell.cell = split.negative;
                    cell.occupied = cell.cell.vertices.len != 0;
                }
                patches[variant] = source_boundary_patches(
                    scratch: &scratch,
                    surface: &surface,
                    source: &source,
                    partition: &partition,
                    cuts: { &plane },
                )!!;
            }
            assert(patches[0].len == patches[1].len);
            foreach (uint index, &patch : patches[0]) {
                BoundaryPatch* other = &patches[1][index];
                assert(patch.source_key == other.source_key && patch.source_corners == other.source_corners);
                PatchTriangles first = triangulate_boundary_patch(&scratch, patch)!!;
                PatchTriangles second = triangulate_boundary_patch(&scratch, other)!!;
                assert_same_patch_triangles(scratch.exact, &first, &second);
                assert_patch_triangulation(scratch.exact, patch, &first);
                if (!clipped) assert(first.triangles.len == 1 && patch.unchanged);
            }
        }
    }
}

fn void test_triangulation_capacity_restores_cursor_and_arithmetic_for_reuse() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    PlanarFixture fixture;
    triangulation_fixture(
        scratch: scratch.exact,
        fixture: &fixture,
        shape: 6,
        quantized: true,
    );
    BoundaryPatch patch = preserved_fixture_patch(&scratch, &fixture, false);
    usz saved = scratch.used;
    OrientedPatchTriangles[2] complete = triangulate_shared_cut(&scratch, &patch)!!;
    usz required = scratch.peak;
    assert(complete[0].shared.triangles.len == 17);
    for (usz capacity = saved; capacity < required; capacity += 17) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(triangulate_shared_cut(&scratch, &patch)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && patch.corners.len == 13);
    }
    scratch.used = saved;
    scratch.storage = workspace.storage[:required];
    uint held = EXACT_TEMPORARIES - PROJECTED_ORIENTATION_TEMPORARIES + 1;
    for (uint index = 0; index < held; index++) (void)scratch.exact.take()!!;
    assert(@catch(triangulate_shared_cut(&scratch, &patch)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == held);
    scratch.exact.count = 0;
    complete = triangulate_shared_cut(&scratch, &patch)!!;
    assert_patch_triangulation(scratch.exact, &patch, complete[0].shared);
}

fn void triangulation_fixture(
    ExactScratch* scratch,
    PlanarFixture* fixture,
    uint shape,
    bool quantized,
) @local {
    init_planar_fixture(scratch, fixture, quantized);
    Vec3[16] points;
    uint[4] counts;
    switch (shape) {
        case 0:
            points = { { 0, 0, 0 }, { 2, 0, 0 }, { 4, 0, 0 }, { 4, 2, 0 }, { 4, 4, 0 }, { 2, 4, 0 }, { 0, 4, 0 }, { 0, 2, 0 },
                {}, {}, {}, {}, {}, {}, {}, {},
            };
            counts = { 8, 0, 0, 0 };
        case 1:
            points = { { 0, 0, 0 }, { 4, 0, 0 }, { 4, 2, 0 }, { 2, 2, 0 }, { 2, 4, 0 }, { 0, 4, 0 },
                {}, {}, {}, {}, {}, {}, {}, {}, {}, {},
            };
            counts = { 6, 0, 0, 0 };
        case 2:
            points = { { 0, 0, 0 }, { 8, 0, 0 }, { 8, 8, 0 }, { 0, 8, 0 }, { 2, 2, 0 }, { 2, 6, 0 }, { 6, 6, 0 }, { 6, 2, 0 },
                {}, {}, {}, {}, {}, {}, {}, {},
            };
            counts = { 4, 4, 0, 0 };
        case 3:
            points = {
                { 0, 0, 0 }, { 12, 0, 0 }, { 12, 8, 0 }, { 0, 8, 0 },
                { 1, 1, 0 }, { 1, 3, 0 }, { 4, 3, 0 }, { 4, 1, 0 },
                { 6, 2, 0 }, { 6, 7, 0 }, { 10, 7, 0 }, { 10, 2, 0 },
                {}, {}, {}, {},
            };
            counts = { 4, 4, 4, 0 };
        case 4:
            points = {
                { 0, 0, 0 }, { 12, 0, 0 }, { 12, 12, 0 }, { 0, 12, 0 },
                { 2, 2, 0 }, { 2, 10, 0 }, { 10, 10, 0 }, { 10, 2, 0 },
                { 4, 4, 0 }, { 8, 4, 0 }, { 8, 8, 0 }, { 4, 8, 0 },
                {}, {}, {}, {},
            };
            counts = { 4, 4, 4, 0 };
        case 5:
            points = {
                { 0, 0, 0 }, { 10, 0, 0 }, { 10, 10, 0 }, { 7, 10, 0 },
                { 7, 3, 0 }, { 3, 3, 0 }, { 3, 10, 0 }, { 0, 10, 0 },
                { 8, 4, 0 }, { 8, 6, 0 }, { 9, 6, 0 }, { 9, 4, 0 },
                {}, {}, {}, {},
            };
            counts = { 8, 4, 0, 0 };
        case 6:
            points = {
                { 0, 0, 0 }, { 12, 0, 0 }, { 12, 12, 0 }, { 0, 12, 0 },
                { 2, 2, 0 }, { 2, 4, 0 }, { 4, 3, 0 },
                { 5, 2, 0 }, { 5, 4, 0 }, { 7, 3, 0 },
                { 8, 2, 0 }, { 8, 4, 0 }, { 10, 3, 0 },
                {}, {}, {},
            };
            counts = { 4, 3, 3, 3 };
        default: unreachable();
    }
    uint count;
    foreach (length : counts) count += length;
    foreach (point : points[:count]) add_planar_vertex(scratch, fixture, point);
    uint first;
    foreach (length : counts) {
        for (uint index = 0; index < length; index++) append_planar_segment(
            scratch: scratch,
            fixture: fixture,
            first: first + index,
            second: first + (index + 1) % length,
        );
        first += length;
    }
}

fn void transform_patch_fixture(ExactScratch* scratch, PlanarFixture* fixture, uint variant) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = scratch.take()!!;
    WideInteger* scale = scratch.take()!!;
    foreach (&plane : fixture.planes[:fixture.plane_count]) {
        for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
            uint destination = axis < SPACE_AXES ? (axis + variant / 2) % SPACE_AXES : axis;
            set_integer(scale, (variant & 1) ? (axis == 0 ? 3 : axis == 1 ? 5 : 1) : 1);
            multiply_integer(coefficients[destination], plane.coefficients[axis].view(), scale.view())!!;
        }
        normalize_plane(scratch, plane, coefficients)!!;
    }
}

fn BoundaryPatch preserved_fixture_patch(SolidScratch* scratch, PlanarFixture* fixture, bool reversed) @local {
    BoundaryPatch patch = {
        .plane = &fixture.planes[0], .reversed = reversed,
        .boundary = normalize_planar_edges(scratch, &fixture.planes[0], fixture.segments[:fixture.segment_count])!!,
    };
    trace_patch_contours(scratch, &patch)!!;
    return patch;
}

fn void assert_patch_triangulation(ExactScratch* scratch, BoundaryPatch* patch, PatchTriangles* triangles) @local {
    assert(triangles.vertices.ptr == patch.boundary.vertices.ptr && triangles.vertices.len == patch.boundary.vertices.len);
    foreach (uint index, triangle : triangles.triangles) {
        uint[3] vertices = triangle.vertices;
        foreach (vertex : vertices) assert(vertex < triangles.vertices.len);
        assert(vertices[0] < vertices[1] && vertices[0] < vertices[2]);
        assert(planar_orientation(
            scratch: scratch,
            vertices: { triangles.vertices[vertices[0]], triangles.vertices[vertices[1]], triangles.vertices[vertices[2]] },
            dropped_axis: patch_projection(patch.plane),
        )!! > 0);
        if (index) {
            uint[3] previous = triangles.triangles[index - 1].vertices;
            assert(previous[0] < vertices[0] || (previous[0] == vertices[0] && previous[1] < vertices[1])
                || (previous[0] == vertices[0] && previous[1] == vertices[1] && previous[2] < vertices[2]));
        }
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint first = vertices[corner];
            uint second = vertices[(corner + 1) % TRIANGLE_CORNERS];
            bool boundary;
            foreach (edge : patch.boundary.edges) {
                if (math::min(first, second) != edge.first || math::max(first, second) != edge.second) continue;
                boundary = true;
                assert((first < second) == ((edge.weight > 0) != patch.reversed));
            }
            uint forward;
            uint reverse;
            foreach (other : triangles.triangles) for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
                uint start = other.vertices[side];
                uint end = other.vertices[(side + 1) % TRIANGLE_CORNERS];
                forward += start == first && end == second ? 1 : 0;
                reverse += start == second && end == first ? 1 : 0;
            }
            assert(forward == 1 && reverse == (boundary ? 0 : 1));
        }
    }
    foreach (edge : patch.boundary.edges) {
        uint count;
        foreach (triangle : triangles.triangles) for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint first = triangle.vertices[corner];
            uint second = triangle.vertices[(corner + 1) % TRIANGLE_CORNERS];
            count += math::min(first, second) == edge.first && math::max(first, second) == edge.second ? 1 : 0;
        }
        assert(count == 1);
    }
}

fn void assert_same_patch_triangles(ExactScratch* scratch, PatchTriangles* first, PatchTriangles* second) @local {
    assert(first.vertices.len == second.vertices.len && first.triangles.len == second.triangles.len);
    foreach (index, point : first.vertices) assert(same_vertex(scratch, point, second.vertices[index])!!);
    foreach (index, triangle : first.triangles) assert(triangle.vertices == second.triangles[index].vertices);
}
