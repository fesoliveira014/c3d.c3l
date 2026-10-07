module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_boundary_uncut_sources_retain_original_triangles_and_provenance() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        foreach (uint index, &material : fixture.materials[:fixture.triangle_count]) *material = index + 7;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        scratch.exact.peak = 0;
        BoundaryPatch[] patches = source_boundary_patches(
            scratch: &scratch,
            surface: &surface,
            source: &source,
            partition: &partition,
        )!!;
        assert(patches.len == fixture.triangle_count);
        foreach (patch : patches) {
            assert(patch.unchanged && patch.corners.len == TRIANGLE_CORNERS && patch.contours.len == 1);
            assert(patch.reversed == source.reversed[patch.source_face]);
            assert(surface.source.triangle_materials[patch.source_face] == patch.source_face + 7);
            uint[3] triangle = surface_triangle(&surface, patch.source_face);
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                uint render = surface.source.geometry.indices[patch.source_face * TRIANGLE_CORNERS + corner];
                assert(patch.source_corners[corner] == render);
                assert(surface.source.topology_vertices[render] == triangle[corner]);
                bool present;
                foreach (point : patch.boundary.vertices) present |= same_vertex(
                    scratch: scratch.exact,
                    first: point,
                    second: source.vertices[triangle[corner]],
                )!!;
                assert(present);
            }
        }
        assert_boundary_coverage(&scratch, patches, &partition);
        assert(scratch.exact.peak <= PROJECTED_ORIENTATION_TEMPORARIES && scratch.exact.count == 0);
    }
}

fn void test_boundary_cuts_form_concave_contours_holes_and_nested_islands() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, shape);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        ExactPlane plane;
        float height = shape == 4 ? 0.5 : 0;
        bounds_axis_plane(
            scratch: scratch.exact,
            plane: &plane,
            axis: 2,
            bound: domain ? (long)(height * 4) : (long)bitcast(height, uint),
            quantized: domain != 0,
        )!!;
        clip_partition(&scratch, &partition, &plane);
        PlanarSegment[] segments = collect_boundary_segments(&scratch, &partition, &plane)!!;
        BoundaryPatch patch = create_boundary_patch(
            scratch: &scratch,
            plane: &plane,
            segments: segments,
            reversed: false,
        )!!;
        uint[5] contours = { 1, 2, 3, 2, 1 };
        uint[5] corners = { 4, 8, 12, 8, 6 };
        assert(patch.contours.len == contours[shape] && patch.corners.len == corners[shape]);
        uint holes;
        uint nested;
        foreach (contour : patch.contours) {
            holes += contour.hole ? 1 : 0;
            if (contour.parent != NO_SOLID_INDEX && patch.contours[contour.parent].parent != NO_SOLID_INDEX) nested++;
        }
        assert(holes == ((shape == 1 || shape == 2) ? 1 : 0) && nested == (shape == 2 ? 1 : 0));
        BoundaryPatch[] source_patches = source_boundary_patches(
            scratch: &scratch,
            surface: &surface,
            source: &source,
            partition: &partition,
            cuts: { &plane },
        )!!;
        BoundaryPatch[] all = reserve_elements(&scratch, BoundaryPatch, source_patches.len + 1)!!;
        all[:source_patches.len] = source_patches[..];
        all[^1] = patch;
        reconcile_patch_boundaries(&scratch, all)!!;
        assert_boundary_coverage(&scratch, all, &partition);
        assert_conforming_patches(scratch.exact, all);
        assert(scratch.exact.count == 0);
    }
}

fn void test_boundary_cross_plane_constraints_keep_source_edge_intersections() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture fixture;
        partition_fixture(&fixture, 0);
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface surface = partition_surface(&scratch, &fixture, domain != 0);
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
        ExactPlane plane;
        plane_from_integers(scratch.exact, &plane, { 1, 0, 0, 0 })!!;
        clip_partition(&scratch, &partition, &plane);
        PlanarSegment[] segments = collect_boundary_segments(&scratch, &partition, &plane)!!;
        BoundaryPatch cap = create_boundary_patch(
            scratch: &scratch,
            plane: &plane,
            segments: segments,
            reversed: false,
        )!!;
        assert(cap.corners.len == 4);
        BoundaryPatch[] patches = source_boundary_patches(
            scratch: &scratch,
            surface: &surface,
            source: &source,
            partition: &partition,
            cuts: { &plane },
        )!!;
        BoundaryPatch[] combined = reserve_elements(&scratch, BoundaryPatch, patches.len + 1)!!;
        combined[:patches.len] = patches[..];
        combined[^1] = cap;
        reconcile_patch_boundaries(&scratch, combined)!!;
        assert(combined[^1].corners.len == 8);
        assert_conforming_patches(scratch.exact, combined);
        assert_boundary_coverage(&scratch, combined, &partition);
    }
}

fn void test_boundary_source_face_order_keeps_canonical_patches() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint shape = 0; shape < 5; shape++) for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture first_fixture;
        ContainmentFixture second_fixture;
        partition_fixture(&first_fixture, shape);
        partition_fixture(&second_fixture, shape);
        for (uint face = 0; face < second_fixture.triangle_count; face++) {
            uint other = second_fixture.triangle_count - face - 1;
            for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                second_fixture.indices[face * TRIANGLE_CORNERS + corner] = first_fixture.indices[other * TRIANGLE_CORNERS + corner];
            }
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidSurface first_surface = partition_surface(&scratch, &first_fixture, domain != 0);
        SolidSurface second_surface = partition_surface(&scratch, &second_fixture, domain != 0);
        SourceConstructions first_source = build_source_constructions(&scratch, &first_surface)!!;
        SourceConstructions second_source = build_source_constructions(&scratch, &second_surface)!!;
        SolidPartition first = partition_solid(&scratch, &first_surface, &first_source)!!;
        SolidPartition second = partition_solid(&scratch, &second_surface, &second_source)!!;
        BoundaryPatch[] first_patches = source_boundary_patches(
            scratch: &scratch,
            surface: &first_surface,
            source: &first_source,
            partition: &first,
        )!!;
        BoundaryPatch[] second_patches = source_boundary_patches(
            scratch: &scratch,
            surface: &second_surface,
            source: &second_source,
            partition: &second,
        )!!;
        assert(first_patches.len == second_patches.len);
        foreach (index, patch : first_patches) {
            BoundaryPatch other = second_patches[index];
            assert(patch.source_key == other.source_key && patch.unchanged && other.unchanged);
            assert(patch.source_corners == other.source_corners);
            assert(patch.source_face + other.source_face + 1 == first_fixture.triangle_count);
            assert_same_patch(scratch.exact, &patch, &other);
        }
    }
}

fn void test_boundary_internal_faces_cancel_across_unequal_subdivisions() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 2);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface surface = partition_surface(&scratch, &fixture, false);
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
    ExactPlane middle;
    plane_from_integers(scratch.exact, &middle, { 1, 0, 0, 0 })!!;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        CellSplit split = split_convex_cell(&scratch, &cell.cell, &middle)!!;
        if (!split.negative.vertices.len || !split.positive.vertices.len) continue;
        PartitionCell* extra = &reserve_elements(&scratch, PartitionCell, 1)!![0];
        *extra = { .cell = split.positive, .occupied = true, .next = cell.next };
        cell.cell = split.negative;
        cell.next = extra;
        break;
    }
    PlanarSegment[] segments = collect_boundary_segments(&scratch, &partition, &middle)!!;
    assert(segments.len != 0);
    BoundaryPatch patch = create_boundary_patch(
        scratch: &scratch,
        plane: &middle,
        segments: segments,
        reversed: false,
    )!!;
    assert(!patch.boundary.edges.len && !patch.contours.len);
    BoundaryPatch[] patches = source_boundary_patches(
        scratch: &scratch,
        surface: &surface,
        source: &source,
        partition: &partition,
    )!!;
    foreach (result : patches) assert(result.unchanged);
    assert_boundary_coverage(&scratch, patches, &partition);
    ContainmentFixture larger;
    append_box_fixture(&larger, { -4, -4, -4 }, { 4, 4, 4 });
    SolidSurface bounds = partition_surface(&scratch, &larger, false);
    ConvexCell whole = create_bounds_cell(&scratch, &bounds)!!;
    CellSplit split = split_convex_cell(&scratch, &whole, &source.faces[0])!!;
    PartitionCell[2] cells = {
        { .cell = split.negative, .occupied = true }, { .cell = split.positive, .occupied = true },
    };
    cells[0].next = &cells[1];
    SolidPartition filled = { .first = &cells[0], .cell_count = 2, .occupied_count = 2 };
    segments = collect_boundary_segments(
        scratch: &scratch,
        partition: &filled,
        plane: &source.faces[0],
        surface: &surface,
        source: &source,
        source_face: 0,
    )!!;
    assert(segments.len == 6);
    PlanarEdges hidden = normalize_planar_edges(&scratch, &source.faces[0], segments)!!;
    assert(!hidden.edges.len);
}

fn void test_boundary_capacity_failure_restores_cursor_and_input_patches() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    partition_fixture(&fixture, 4);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidSurface surface = partition_surface(&scratch, &fixture, true);
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
    usz saved = scratch.used;
    BoundaryPatch[] patches = source_boundary_patches(
        scratch: &scratch,
        surface: &surface,
        source: &source,
        partition: &partition,
    )!!;
    usz required = scratch.peak;
    assert(patches.len == fixture.triangle_count);
    for (usz capacity = saved; capacity < required; capacity += 773) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(source_boundary_patches(
            scratch: &scratch,
            surface: &surface,
            source: &source,
            partition: &partition,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0 && surface.validated);
    }
    scratch.storage = workspace.storage[:required];
    patches = source_boundary_patches(
        scratch: &scratch,
        surface: &surface,
        source: &source,
        partition: &partition,
    )!!;
    saved = scratch.used;
    BoundaryPatch original = patches[0];
    assert(@catch(reconcile_patch_boundaries(&scratch, patches)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && patches[0].boundary.vertices.ptr == original.boundary.vertices.ptr);
    assert(patches[0].corners.ptr == original.corners.ptr && scratch.exact.count == 0);
}

fn void test_boundary_rejects_open_branched_repeated_and_wrongly_nested_edges() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        init_planar_fixture(scratch.exact, &fixture, domain != 0);
        Vec3[8] positions = {
            { 0, 0, 0 }, { 4, 0, 0 }, { 4, 4, 0 }, { 0, 4, 0 },
            { 1, 1, 0 }, { 1, 3, 0 }, { 3, 3, 0 }, { 3, 1, 0 },
        };
        foreach (point : positions) add_planar_vertex(scratch.exact, &fixture, point);
        for (uint index = 0; index < 8; index++) append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: index,
            second: index / 4 * 4 + (index + 1) % 4,
        );
        usz saved = scratch.used;
        BoundaryPatch patch = create_boundary_patch(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:8],
            reversed: false,
        )!!;
        assert(patch.contours.len == 2 && patch.contours[1].hole && patch.contours[1].parent == 0);
        scratch.used = saved;
        assert(@catch(create_boundary_patch(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:7],
            reversed: false,
        )) == NON_MANIFOLD_RESULT);
        assert(scratch.used == saved && scratch.exact.count == 0);
        fixture.segments[8] = fixture.segments[0];
        assert(@catch(create_boundary_patch(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:9],
            reversed: false,
        )) == NON_MANIFOLD_RESULT);
        for (uint index = 4; index < 8; index++) {
            PlaneTriple point = fixture.segments[index].first;
            fixture.segments[index].first = fixture.segments[index].second;
            fixture.segments[index].second = point;
        }
        assert(@catch(create_boundary_patch(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:8],
            reversed: false,
        )) == NON_MANIFOLD_RESULT);
        fixture.segment_count = 4;
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 0,
            second: 2,
        );
        assert(@catch(create_boundary_patch(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:5],
            reversed: false,
        )) == NON_MANIFOLD_RESULT);
        assert(scratch.used == saved && scratch.exact.count == 0);
    }
}

fn void test_boundary_oblique_cut_source_permutations_keep_patches_and_holes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        ContainmentFixture[2] fixtures;
        SolidScratch scratch = begin_solid_scratch(&workspace);
        BoundaryPatch[][2] results;
        BoundaryPatch[2] caps;
        ExactPlane cut;
        plane_from_integers(scratch.exact, &cut, { 1, -2, 1, 0 })!!;
        for (uint variant = 0; variant < 2; variant++) {
            ContainmentFixture* fixture = &fixtures[variant];
            partition_fixture(fixture, 2);
            foreach (uint index, &point : fixture.positions[:fixture.vertex_count]) {
                *point = { point.x + 2 * point.y + point.z, point.y + point.z, point.z };
                for (uint axis = 0; axis < SPACE_AXES; axis++) fixture.grid[index][axis] = (long)((*point)[axis] * 4);
            }
            if (variant) for (uint face = 0; face < fixture.triangle_count; face++) {
                for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
                    fixture.indices[face * TRIANGLE_CORNERS + corner] = fixtures[0].indices[(fixture.triangle_count - face - 1) * TRIANGLE_CORNERS + corner];
                }
            }
            SolidSurface surface = partition_surface(&scratch, fixture, domain != 0);
            SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
            SolidPartition partition = partition_solid(&scratch, &surface, &source)!!;
            clip_partition(&scratch, &partition, &cut);
            results[variant] = source_boundary_patches(
                scratch: &scratch,
                surface: &surface,
                source: &source,
                partition: &partition,
                cuts: { &cut },
            )!!;
            PlanarSegment[] segments = collect_boundary_segments(&scratch, &partition, &cut)!!;
            caps[variant] = create_boundary_patch(
                scratch: &scratch,
                plane: &cut,
                segments: segments,
                reversed: false,
            )!!;
        }
        assert(results[0].len == results[1].len && caps[0].contours.len == 3);
        assert_same_patch(scratch.exact, &caps[0], &caps[1]);
        foreach (index, patch : results[0]) {
            BoundaryPatch other = results[1][index];
            assert(patch.source_key == other.source_key && patch.source_corners == other.source_corners);
            assert_same_patch(scratch.exact, &patch, &other);
        }
    }
}

fn void clip_partition(SolidScratch* scratch, SolidPartition* partition, ExactPlane* plane) @local {
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        CellSplit split = split_convex_cell(scratch, &cell.cell, plane)!!;
        cell.cell = split.negative;
        cell.occupied = cell.cell.vertices.len != 0;
    }
}

fn void assert_same_patch(ExactScratch* scratch, BoundaryPatch* first, BoundaryPatch* second) @local {
    assert(!compare_exact_planes(first.plane, second.plane) && first.reversed == second.reversed);
    assert(first.boundary.vertices.len == second.boundary.vertices.len && first.contours.len == second.contours.len);
    foreach (index, point : first.boundary.vertices) assert(same_vertex(scratch, point, second.boundary.vertices[index])!!);
    foreach (index, corner : first.corners) assert(corner == second.corners[index]);
    foreach (index, contour : first.contours) {
        PlanarContour other = second.contours[index];
        assert(contour.first == other.first && contour.count == other.count && contour.parent == other.parent && contour.hole == other.hole);
    }
}

fn void assert_conforming_patches(ExactScratch* scratch, BoundaryPatch[] patches) @local {
    foreach (patch : patches) foreach (other : patches) foreach (point : other.boundary.vertices) {
        if (plane_side(scratch, patch.plane, point)!!) continue;
        foreach (edge : patch.boundary.edges) {
            PlaneTriple first = patch.boundary.vertices[edge.first];
            PlaneTriple second = patch.boundary.vertices[edge.second];
            uint axis = patch_projection(patch.plane);
            if (planar_orientation(scratch, { first, second, point }, axis)!!) continue;
            int start = compare_planar_points(
                scratch: scratch,
                first: first,
                second: point,
                dropped_axis: axis,
            )!!;
            int end = compare_planar_points(
                scratch: scratch,
                first: second,
                second: point,
                dropped_axis: axis,
            )!!;
            assert(start != -1 || end != 1);
        }
    }
}

fn void assert_boundary_coverage(SolidScratch* scratch, BoundaryPatch[] patches, SolidPartition* partition) @local {
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        foreach (face : cell.cell.faces) {
            usz saved = scratch.used;
            PlanarSegment[] native = collect_boundary_segments(scratch, partition, face.plane)!!;
            usz count = native.len;
            foreach (patch : patches) if (!compare_exact_planes(patch.plane, face.plane)) count += patch.boundary.edges.len;
            PlanarSegment[] combined = reserve_elements(scratch, PlanarSegment, count)!!;
            combined[:native.len] = native[..];
            count = native.len;
            foreach (patch : patches) {
                if (compare_exact_planes(patch.plane, face.plane)) continue;
                foreach (edge : patch.boundary.edges) combined[count++] = {
                    .first = patch.boundary.vertices[edge.weight > 0 ? edge.second : edge.first],
                    .second = patch.boundary.vertices[edge.weight > 0 ? edge.first : edge.second],
                    .line = edge.line,
                };
            }
            PlanarEdges difference = normalize_planar_edges(scratch, face.plane, combined)!!;
            assert(!difference.edges.len);
            scratch.used = saved;
        }
    }
}
