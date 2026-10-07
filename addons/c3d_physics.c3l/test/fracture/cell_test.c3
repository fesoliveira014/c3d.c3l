module c3d::physics::fracture;

import c3d;
import std::math;

const double CELL_VOLUME_LIMB_SCALE @local = 18446744073709551616.0;
$assert INTEGER_LIMB_BITS == 64;

fn void test_cell_bounds_preserve_raw_extremes_and_actual_grid_coordinates() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 3; variant++) {
        ContainmentFixture fixture;
        append_box_fixture(&fixture, { -2, -3, -4 }, { 5, 6, 7 });
        if (variant == 1) {
            foreach (&point : fixture.positions[:fixture.vertex_count]) {
                point.x = point.x < 0 ? -float::max : float::max;
                point.y = point.y < 0 ? -bitcast((uint)1, float) : bitcast((uint)2, float);
            }
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        if (variant == 2) {
            surface.grid = fixture.grid[:fixture.vertex_count];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        usz saved = scratch.used;
        scratch.peak = saved;
        ConvexCell cell = create_bounds_cell(&scratch, &surface)!!;
        usz required = scratch.peak;
        if (!variant) {
            for (usz capacity = saved; capacity < required; capacity += 67) {
                scratch.used = saved;
                scratch.storage = workspace.storage[:capacity];
                assert(@catch(create_bounds_cell(&scratch, &surface)) == c3d::CAPACITY_EXCEEDED);
                assert(scratch.used == saved && scratch.exact.count == 0);
            }
            scratch.storage = workspace.storage;
            cell = create_bounds_cell(&scratch, &surface)!!;
        }
        assert_cell(&scratch, &cell);
        foreach (uint index, point : cell.vertices) {
            uint fixture_index = ((index & 1) << 2) | (index & 2) | ((index & 4) >> 2);
            assert_point_coordinates(
                scratch: scratch.exact, planes: point, raw: fixture.positions[fixture_index],
                grid: fixture.grid[fixture_index], quantized: variant == 2,
            );
        }
    }
}

fn void test_cell_split_closes_opposite_caps_and_preserves_parent() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        ConvexCell parent = box_cell(&scratch, &fixture, domain != 0);
        ExactPlane cut;
        plane_from_integers(scratch.exact, &cut, { 3, 1, 0, 0 })!!;
        scratch.exact.peak = 0;
        CellSplit split = split_convex_cell(&scratch, &parent, &cut)!!;
        assert(scratch.exact.peak <= 7);
        assert(split.negative.vertices.len == 8 && split.positive.vertices.len == 8);
        assert_cell_split(&scratch, &parent, &split, &cut);
        assert(parent.vertices.len == 8 && parent.faces.len == 6 && parent.corners.len == 24);
        assert_cell(&scratch, &parent);
        double before = cell_volume(scratch.exact, &parent);
        double after = cell_volume(scratch.exact, &split.negative) + cell_volume(scratch.exact, &split.positive);
        assert(math::abs(before - after) <= before * 1e-12);
    }
}

fn void test_cell_split_reuses_vertices_and_edges_on_the_cut() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    for (uint domain = 0; domain < 2; domain++) {
        for (uint variant = 0; variant < 2; variant++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            ConvexCell parent = box_cell(&scratch, &fixture, domain != 0);
            ExactPlane cut;
            if (variant) {
                plane_from_integers(scratch.exact, &cut, { 1, 1, 0, 0 })!!;
            } else {
                bounds_axis_plane(
                    scratch: scratch.exact, plane: &cut, axis: 0,
                    bound: domain ? -8 : -(long)bitcast(2.0f, uint), quantized: domain != 0,
                )!!;
                cut.coefficients[1] = cut.coefficients[0];
                cut.coefficients[2] = cut.coefficients[0];
            }
            CellSplit split = split_convex_cell(&scratch, &parent, &cut)!!;
            assert_cell_split(&scratch, &parent, &split, &cut);
            assert(split.negative.vertices.len == (variant ? 6 : 4));
            assert(split.positive.vertices.len == (variant ? 6 : 7));
            foreach (child : ((ConvexCell[2]){ split.negative, split.positive })) {
                foreach (point : child.vertices) {
                    bool found;
                    foreach (original : parent.vertices) {
                        if (!same_vertex(scratch.exact, point, original)!!) continue;
                        foreach (axis, plane : point) assert(plane == original[axis]);
                        found = true;
                    }
                    assert(found);
                }
            }
        }
    }
}

fn void test_cell_tangent_and_disjoint_cuts_borrow_unchanged_cell() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell parent = box_cell(&scratch, &fixture, true);
    int128[4][5] coefficients = { { 1, 0, 0, -8 }, { 1, 1, 0, -16 }, { 1, 1, 1, -24 }, { 1, 0, 0, -9 }, { 1, 0, 0, 9 } };
    foreach (index, values : coefficients) {
        ExactPlane cut;
        plane_from_integers(scratch.exact, &cut, values)!!;
        usz saved = scratch.used;
        CellSplit split = split_convex_cell(&scratch, &parent, &cut)!!;
        ConvexCell kept = index == 4 ? split.positive : split.negative;
        ConvexCell empty = index == 4 ? split.negative : split.positive;
        assert(kept.vertices.ptr == parent.vertices.ptr && kept.faces.ptr == parent.faces.ptr && kept.corners.ptr == parent.corners.ptr);
        assert(!empty.vertices.len && !empty.faces.len && !empty.corners.len && scratch.used == saved);
    }
}

fn void test_cell_subsequent_split_handles_more_than_three_incident_planes() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell cell = box_cell(&scratch, &fixture, true);
    ExactPlane[9] cuts;
    for (uint index = 0; index < 8; index++) {
        int128[4] values = { (index & 1) ? -1 : 1, (index & 2) ? -1 : 1, (index & 4) ? -1 : 1, -8 };
        bool reversed = plane_from_integers(scratch.exact, &cuts[index], values)!!;
        CellSplit split = split_convex_cell(&scratch, &cell, &cuts[index])!!;
        cell = reversed ? split.positive : split.negative;
        assert_cell(&scratch, &cell);
    }
    assert(cell.vertices.len == 6 && cell.faces.len == 8 && cell.corners.len == 24);
    foreach (uint vertex, point : cell.vertices) {
        uint incidence;
        foreach (face : cell.faces) if (!plane_side(scratch.exact, face.plane, point)!!) incidence++;
        assert(incidence == 4);
    }
    plane_from_integers(scratch.exact, &cuts[8], { 2, 3, 5, -1 })!!;
    CellSplit split = split_convex_cell(&scratch, &cell, &cuts[8])!!;
    assert_cell_split(&scratch, &cell, &split, &cuts[8]);
    double before = cell_volume(scratch.exact, &cell);
    double after = cell_volume(scratch.exact, &split.negative) + cell_volume(scratch.exact, &split.positive);
    assert(math::abs(before - after) < before * 1e-12);
}

fn void test_cell_partition_ignores_source_construction_planes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits limits = solid_limits();
    limits.scratch_bytes = 1048576;
    FractureWorkspace workspace = create_fracture_workspace(&tracker, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        if (domain) {
            surface.grid = fixture.grid[:fixture.vertex_count];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        ExactPlane[3] cuts;
        for (uint axis = 0; axis < 3; axis++) {
            int128[4] values;
            values[axis] = 1;
            plane_from_integers(scratch.exact, &cuts[axis], values)!!;
        }
        ConvexCell[8] without_edges;
        partition_box(&scratch, &surface, cuts[..], without_edges[..]);
        SourceConstructions constructions = build_source_constructions(&scratch, &surface)!!;
        ConvexCell[8] with_edges;
        partition_box(&scratch, &surface, cuts[..], with_edges[..]);
        foreach (index, &cell : with_edges) {
            assert_same_cell(scratch.exact, &without_edges[index], cell);
            foreach (&plane : constructions.faces) {
                CellSplit split = split_convex_cell(&scratch, cell, plane)!!;
                ConvexCell kept = split.negative.vertices.len ? split.negative : split.positive;
                assert_same_cell(scratch.exact, cell, &kept);
            }
            foreach (face : cell.faces) foreach (&edge : constructions.edges) assert(face.plane != &edge.plane);
        }
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
    assert(tracker.total_allocation_count() == 1);
}

fn void test_cell_capacity_failures_restore_cursor_and_input() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ContainmentFixture fixture;
    append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ConvexCell parent = box_cell(&scratch, &fixture, true);
    ExactPlane cut;
    plane_from_integers(scratch.exact, &cut, { 1, 1, 1, 0 })!!;
    usz saved = scratch.used;
    scratch.peak = saved;
    (void)split_convex_cell(&scratch, &parent, &cut)!!;
    usz required = scratch.peak;
    for (usz capacity = saved; capacity < required; capacity += 29) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(split_convex_cell(&scratch, &parent, &cut)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        assert(parent.vertices.len == 8 && parent.faces.len == 6 && parent.corners.len == 24);
    }
    scratch.storage = workspace.storage[:required];
    CellSplit recovered = split_convex_cell(&scratch, &parent, &cut)!!;
    assert_cell_split(&scratch, &parent, &recovered, &cut);
}

fn FractureWorkspace cell_workspace() @local {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes = 1048576;
    return create_fracture_workspace(mem, limits)!!;
}

fn ConvexCell box_cell(SolidScratch* scratch, ContainmentFixture* fixture, bool quantized) @local {
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(scratch, fixture.mesh, &diagnostic)!!;
    if (quantized) {
        surface.grid = fixture.grid[:fixture.vertex_count];
        check_surface_geometry(&surface, &diagnostic)!!;
    }
    return create_bounds_cell(scratch, &surface)!!;
}

fn void assert_cell(SolidScratch* scratch, ConvexCell* cell) @local {
    assert(cell.vertices.len >= 4 && cell.faces.len >= 4);
    assert(cell.vertices.len + cell.faces.len == cell.corners.len / 2 + 2);
    foreach (uint vertex, point : cell.vertices) {
        uint incident;
        foreach (corner : cell.corners) if (corner.vertex == vertex) incident++;
        assert(incident >= 3);
        for (usz other = (usz)vertex + 1; other < cell.vertices.len; other++) assert(!same_vertex(scratch.exact, point, cell.vertices[other])!!);
    }
    foreach (uint face_index, face : cell.faces) {
        assert(face.count >= 3);
        bool volume;
        foreach (point : cell.vertices) {
            int side = plane_side(scratch.exact, face.plane, point)!!;
            assert(face.reversed ? side >= 0 : side <= 0);
            volume |= side != 0;
        }
        assert(volume);
        PlaneTriple first = cell.vertices[cell.corners[face.first].vertex];
        for (uint index = face.first; index < face.first + face.count; index++) {
            CellCorner corner = cell.corners[index];
            CellCorner twin = cell.corners[corner.twin];
            uint next = next_cell_corner(cell, index);
            assert(corner.face == face_index && twin.twin == index && twin.face != face_index);
            assert(twin.vertex == cell.corners[next].vertex && cell.corners[next_cell_corner(cell, corner.twin)].vertex == corner.vertex);
            assert(corner.vertex != twin.vertex && !plane_side(scratch.exact, face.plane, cell.vertices[corner.vertex])!!);
            if (index == face.first || next == face.first) continue;
            foreach (point : cell.vertices) {
                PlaneTriple[4] tetrahedron = { first, cell.vertices[corner.vertex], cell.vertices[cell.corners[next].vertex], point };
                assert(exact_vertex_orientation(scratch.exact, tetrahedron)!! <= 0);
            }
        }
    }
    assert(scratch.exact.count == 0);
}

fn void assert_cell_split(SolidScratch* scratch, ConvexCell* parent, CellSplit* split, ExactPlane* cut) @local {
    assert_cell(scratch, &split.negative);
    assert_cell(scratch, &split.positive);
    CellFace negative = split.negative.faces[split.negative.faces.len - 1];
    CellFace positive = split.positive.faces[split.positive.faces.len - 1];
    assert(negative.plane == cut && positive.plane == cut && !negative.reversed && positive.reversed);
    assert(negative.count == positive.count);
    for (uint index = 0; index < negative.count; index++) {
        PlaneTriple left = split.negative.vertices[split.negative.corners[negative.first + index].vertex];
        PlaneTriple right = split.positive.vertices[split.positive.corners[positive.first + positive.count - index - 1].vertex];
        foreach (axis, plane : left) assert(plane == right[axis]);
    }
    foreach (child : ((ConvexCell[2]){ split.negative, split.positive })) {
        foreach (point : child.vertices) foreach (face : parent.faces) {
            int side = plane_side(scratch.exact, face.plane, point)!!;
            assert(face.reversed ? side >= 0 : side <= 0);
        }
    }
}

fn double cell_volume(ExactScratch* scratch, ConvexCell* cell) @local {
    double volume;
    foreach (face : cell.faces) {
        for (uint index = face.first + 1; index + 1 < face.first + face.count; index++) {
            double[3][3] points;
            uint[3] corners = { face.first, index, index + 1 };
            foreach (point_index, corner : corners) {
                uint saved = scratch.count;
                WideInteger*[4] point;
                foreach (&coordinate : point) *coordinate = scratch.take()!!;
                construct_point(scratch, point, cell.vertices[cell.corners[corner].vertex])!!;
                double[4] values;
                foreach (axis, coordinate : point) {
                    for (uint limb = coordinate.used; limb > 0; limb--) values[axis] = values[axis] * CELL_VOLUME_LIMB_SCALE + coordinate.limbs[limb - 1];
                    if (coordinate.negative) values[axis] = -values[axis];
                }
                for (uint axis = 0; axis < 3; axis++) points[point_index][axis] = values[axis] / values[3];
                scratch.count = saved;
            }
            volume += points[0][0] * (points[1][1] * points[2][2] - points[1][2] * points[2][1])
                + points[0][1] * (points[1][2] * points[2][0] - points[1][0] * points[2][2])
                + points[0][2] * (points[1][0] * points[2][1] - points[1][1] * points[2][0]);
        }
    }
    assert(volume > 0);
    return volume / 6;
}

fn void partition_box(SolidScratch* scratch, SolidSurface* surface, ExactPlane[] cuts, ConvexCell[] cells) @local {
    cells[0] = create_bounds_cell(scratch, surface)!!;
    uint count = 1;
    foreach (&cut : cuts) {
        for (uint index = count; index > 0; index--) {
            CellSplit split = split_convex_cell(scratch, &cells[index - 1], cut)!!;
            cells[(index - 1) * 2] = split.negative;
            cells[(index - 1) * 2 + 1] = split.positive;
        }
        count *= 2;
    }
    assert(count == cells.len);
}

fn void assert_same_cell(ExactScratch* scratch, ConvexCell* first, ConvexCell* second) @local {
    assert(first.vertices.len == second.vertices.len && first.faces.len == second.faces.len && first.corners.len == second.corners.len);
    foreach (index, point : first.vertices) assert(same_vertex(scratch, point, second.vertices[index])!!);
    foreach (index, face : first.faces) {
        CellFace other = second.faces[index];
        assert(face.first == other.first && face.count == other.count && face.reversed == other.reversed);
        assert_plane_equal(face.plane, other.plane);
    }
    foreach (index, corner : first.corners) {
        CellCorner other = second.corners[index];
        assert(corner.vertex == other.vertex && corner.face == other.face && corner.twin == other.twin);
    }
}
