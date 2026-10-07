module c3d::physics::fracture;

import c3d;
import std::math;

fn void test_source_constructions_preserve_vertices_across_faces_and_flat_boundaries() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 65536;
    FractureWorkspace workspace = create_fracture_workspace(&tracker, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 3; variant++) {
        ContainmentFixture fixture;
        append_box_fixture(&fixture, { -2, -2, -2 }, { 2, 2, 2 });
        if (variant) subdivide_box_fixture(&fixture, variant == 1);
        for (uint domain = 0; domain < 2; domain++) {
            SolidScratch scratch = begin_solid_scratch(&workspace);
            SolidDiagnostic diagnostic;
            SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
            if (domain) {
                surface.grid = fixture.grid[:fixture.vertex_count];
                check_surface_geometry(&surface, &diagnostic)!!;
            }
            scratch.exact.peak = 0;
            SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
            assert(scratch.exact.peak == (domain ? 10 : 21) && scratch.exact.count == 0);
            foreach (uint face, &plane : source.faces) {
                uint axis;
                while (!plane.coefficients[axis].used) axis++;
                assert(source.reversed[face] == (surface_projection(&surface, surface_triangle(&surface, face), axis)!! < 0));
            }
            foreach (uint corner, twin : surface.topology.twins) {
                assert(source.corner_edges[corner] == source.corner_edges[twin]);
                assert(source.edges[source.corner_edges[corner]].owner_corner == math::min(corner, twin));
                SourceEdge* edge = &source.edges[source.corner_edges[corner]];
                ExactPlane* owner = &source.faces[edge.owner_corner / TRIANGLE_CORNERS];
                uint axis;
                while (!owner.coefficients[axis].used) axis++;
                assert(!edge.plane.coefficients[axis].used);
            }
            for (uint remaining = (uint)fixture.mesh.geometry.indices.len; remaining > 0; remaining--) {
                uint corner = remaining - 1;
                uint identity = fixture.identities[fixture.indices[corner]];
                PlaneTriple alternate = source_vertex_planes(
                    scratch: scratch.exact,
                    source: &source,
                    surface: &surface,
                    corner: corner,
                )!!;
                assert(same_vertex(scratch.exact, source.vertices[identity], alternate)!!);
                assert_point_coordinates(
                    scratch: scratch.exact,
                    planes: alternate,
                    raw: fixture.positions[identity],
                    grid: fixture.grid[identity],
                    quantized: domain != 0,
                );
                uint first_corner;
                while (fixture.identities[fixture.indices[first_corner]] != identity) first_corner++;
                PlaneTriple selected = source_vertex_planes(
                    scratch: scratch.exact,
                    source: &source,
                    surface: &surface,
                    corner: first_corner,
                )!!;
                foreach (index, plane : selected) assert(source.vertices[identity][index] == plane);
            }
            SourceConstructions repeated = build_source_constructions(&scratch, &surface)!!;
            foreach (uint index, &edge : source.edges) {
                assert(edge.owner_corner == repeated.edges[index].owner_corner);
                assert_plane_equal(&edge.plane, &repeated.edges[index].plane);
            }
            assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
        }
    }
    assert(tracker.total_allocation_count() == 1);
}

fn void test_source_edge_cut_reuses_original_vertices_and_handles_crease_planes() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
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
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        uint edge_index;
        while (!((source.edges[edge_index].vertices[0] == 0 && source.edges[edge_index].vertices[1] == 4)
            || (source.edges[edge_index].vertices[0] == 4 && source.edges[edge_index].vertices[1] == 0))) edge_index++;
        SourceEdge* edge = &source.edges[edge_index];
        uint neighbor = surface.topology.twins[edge.owner_corner] / TRIANGLE_CORNERS;
        assert(edge.owner_corner / TRIANGLE_CORNERS == 0 && neighbor == 5);
        assert_plane_equal(&edge.plane, &source.faces[neighbor]);
        ExactPlane cut;
        plane_from_integers(scratch.exact, &cut, { 1, 0, 0, 0 })!!;
        SourceEdgeCut intersection = intersect_source_edge(
            scratch: scratch.exact,
            source: &source,
            edge_index: edge_index,
            cut: &cut,
        )!!;
        assert(intersection.kind == SourceEdgeCutKind.CROSSING && intersection.vertex == NO_SOLID_INDEX);
        assert_point_coordinates(
            scratch: scratch.exact,
            planes: intersection.point,
            raw: { 0, -2, -2 },
            grid: { 0, -8, -8 },
            quantized: domain != 0,
        );
        plane_from_integers(scratch.exact, &cut, { 3, 1, 0, 0 })!!;
        intersection = intersect_source_edge(
            scratch: scratch.exact,
            source: &source,
            edge_index: edge_index,
            cut: &cut,
        )!!;
        assert(intersection.kind == SourceEdgeCutKind.CROSSING);
        assert_point_coordinates(
            scratch: scratch.exact,
            planes: intersection.point,
            raw: { 2, -6, -6 },
            grid: { 8, -24, -24 },
            quantized: domain != 0,
            denominator: 3,
        );
        intersection = intersect_source_edge(
            scratch: scratch.exact,
            source: &source,
            edge_index: edge_index,
            cut: &source.faces[8],
        )!!;
        assert(intersection.kind == SourceEdgeCutKind.VERTEX && intersection.vertex == 0);
        foreach (index, plane : intersection.point) assert(plane == source.vertices[0][index]);
        intersection = intersect_source_edge(
            scratch: scratch.exact,
            source: &source,
            edge_index: edge_index,
            cut: &edge.plane,
        )!!;
        assert(intersection.kind == SourceEdgeCutKind.COPLANAR && intersection.vertex == NO_SOLID_INDEX);
        foreach (plane : intersection.point) assert(!plane);
        intersection = intersect_source_edge(
            scratch: scratch.exact,
            source: &source,
            edge_index: edge_index,
            cut: &source.faces[2],
        )!!;
        assert(intersection.kind == SourceEdgeCutKind.NONE && intersection.vertex == NO_SOLID_INDEX);
        foreach (plane : intersection.point) assert(!plane);
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_source_edge_plane_bounds_cover_extremes_subnormals_and_grid_limits() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    for (uint variant = 0; variant < 3; variant++) {
        SolidFixture fixture;
        tetra_fixture(&fixture);
        float smallest = bitcast((uint)1, float);
        if (variant == 0) {
            fixture.positions[1] = { float::max, smallest, 0 };
            fixture.positions[2] = { bitcast((uint)2, float), bitcast((uint)0x7f7ffffd, float), 0 };
        } else if (variant == 1) {
            fixture.positions[0] = { -smallest, 0, 0 };
            fixture.positions[1] = { smallest, smallest, 0 };
            fixture.positions[2] = { 0, -smallest, 0 };
            fixture.positions[3] = { 0, 0, smallest };
        }
        SolidScratch scratch = begin_solid_scratch(&workspace);
        SolidDiagnostic diagnostic;
        SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
        GridPoint[4] grid;
        if (variant == 2) {
            long limit = (long)GRID_COORDINATE_LIMIT - 1;
            grid = { { -limit, -limit, 0 }, { limit, -limit + 1, 0 }, { limit - 1, limit, 0 }, { 0, 0, limit } };
            surface.grid = grid[..];
            check_surface_geometry(&surface, &diagnostic)!!;
        }
        SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
        uint largest_offset;
        foreach (&edge : source.edges) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) {
                assert(integer_bits(edge.plane.coefficients[axis].view()) <= (variant == 2 ? GRID_EDGE_NORMAL_BITS : RAW_EDGE_NORMAL_BITS));
            }
            uint bits = integer_bits(edge.plane.coefficients[SPACE_AXES].view());
            assert(bits <= (variant == 2 ? GRID_EDGE_OFFSET_BITS : RAW_EDGE_OFFSET_BITS));
            largest_offset = math::max(largest_offset, bits);
        }
        if (variant == 0) assert(largest_offset > 500);
        uint identity = surface_triangle(&surface, 3)[0];
        for (int delta = -1; delta <= 1; delta++) {
            ExactPlane near = source.faces[3];
            uint saved = scratch.exact.count;
            WideInteger* change = scratch.exact.take()!!;
            WideInteger* value = scratch.exact.take()!!;
            set_integer(change, delta);
            add_integer(value, near.coefficients[SPACE_AXES].view(), change.view())!!;
            near.coefficients[SPACE_AXES].used = value.used;
            near.coefficients[SPACE_AXES].negative = value.negative;
            near.coefficients[SPACE_AXES].limbs[:value.used] = value.limbs[:value.used];
            scratch.exact.count = saved;
            int exact = exact_plane_side(scratch.exact, &near, source.vertices[identity])!!;
            assert(exact == delta && plane_side(scratch.exact, &near, source.vertices[identity])!! == delta);
            int filtered = filter_plane_side(&near, source.vertices[identity]);
            assert(filtered == FILTER_UNCERTAIN || filtered == exact);
            if (variant == 0 && delta) assert(filtered == FILTER_UNCERTAIN);
        }
        assert(scratch.exact.count == 0 && scratch.exact.peak <= EXACT_TEMPORARIES);
    }
}

fn void test_source_construction_capacity_rollback_preserves_input_and_reuses_scratch() @test {
    FractureLimits limits = solid_limits();
    limits.scratch_bytes += 32768;
    FractureWorkspace workspace = create_fracture_workspace(mem, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    fixture.positions[4] = { float::max, 0, 0 };
    fixture.identities[4] = 4;
    fixture.mesh.geometry.positions = fixture.positions[:5];
    fixture.mesh.topology_vertices = fixture.identities[:5];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidDiagnostic diagnostic;
    SolidSurface surface = build_solid_surface(&scratch, fixture.mesh, &diagnostic)!!;
    usz start = scratch.used;
    SourceConstructions source = build_source_constructions(&scratch, &surface)!!;
    foreach (plane : source.vertices[4]) assert(!plane);
    usz end = scratch.used;
    for (usz capacity = start; capacity < end; capacity += 97) {
        scratch.used = start;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(build_source_constructions(&scratch, &surface)) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == start && scratch.exact.count == 0);
    }
    scratch.storage = workspace.storage[:end];
    source = build_source_constructions(&scratch, &surface)!!;
    assert(scratch.used == end);
    assert(fixture.positions[4].x == float::max && fixture.mesh.geometry.indices.len == 12);
}

fn void assert_plane_equal(ExactPlane* first, ExactPlane* second) @private {
    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        IntegerView left = first.coefficients[axis].view();
        IntegerView right = second.coefficients[axis].view();
        assert(left.negative == right.negative && compare_magnitude(left, right) == 0);
    }
}

fn void assert_point_coordinates(
    ExactScratch* scratch,
    PlaneTriple planes,
    Vec3 raw,
    GridPoint grid,
    bool quantized,
    uint denominator = 1,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] point;
    foreach (&coordinate : point) *coordinate = scratch.take()!!;
    construct_point(scratch, point, planes)!!;
    WideInteger* coordinate = scratch.take()!!;
    WideInteger* product = scratch.take()!!;
    WideInteger* divisor = scratch.take()!!;
    WideInteger* scaled = scratch.take()!!;
    set_integer(divisor, denominator);
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (quantized) {
            set_integer(coordinate, grid[axis]);
        } else {
            integer_from_float(coordinate, raw[axis]);
        }
        multiply_integer(product, coordinate.view(), point[SPACE_AXES].view())!!;
        multiply_integer(scaled, point[axis].view(), divisor.view())!!;
        assert(product.negative == scaled.negative && compare_magnitude(product.view(), scaled.view()) == 0);
    }
}

fn void subdivide_box_fixture(ContainmentFixture* fixture, bool face_center) @local {
    fixture.identities[8] = 8;
    fixture.vertex_count = 9;
    fixture.triangle_count = 14;
    if (face_center) {
        fixture.positions[8] = { 2, 0, 0 };
        fixture.grid[8] = { 8, 0, 0 };
        uint[12] triangles = { 4, 8, 5, 5, 8, 7, 7, 8, 6, 6, 8, 4 };
        fixture.indices[30:12] = triangles[..];
    } else {
        fixture.positions[8] = { 0, -2, -2 };
        fixture.grid[8] = { 0, -8, -8 };
        uint[3] first = { 0, 6, 8 };
        uint[3] second = { 0, 8, 5 };
        uint[6] appended = { 8, 6, 4, 8, 4, 5 };
        fixture.indices[:3] = first[..];
        fixture.indices[15:3] = second[..];
        fixture.indices[36:6] = appended[..];
    }
    fixture.mesh.geometry.positions = fixture.positions[:fixture.vertex_count];
    fixture.mesh.geometry.indices = fixture.indices[:fixture.triangle_count * TRIANGLE_CORNERS];
    fixture.mesh.topology_vertices = fixture.identities[:fixture.vertex_count];
    fixture.mesh.triangle_materials = fixture.materials[:fixture.triangle_count];
}
