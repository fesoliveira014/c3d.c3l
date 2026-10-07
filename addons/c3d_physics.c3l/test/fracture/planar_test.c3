module c3d::physics::fracture;

import c3d;
import std::math;

struct PlanarFixture @local {
    ExactPlane[64] planes;
    PlaneTriple[16] vertices;
    Vec3[16] positions;
    PlanarSegment[32] segments;
    uint plane_count;
    uint vertex_count;
    uint segment_count;
    bool quantized;
}

fn void test_planar_crossings_t_junctions_and_distinct_triples_share_points() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        init_planar_fixture(scratch.exact, &fixture, domain != 0);
        add_planar_vertex(scratch.exact, &fixture, { 0, 0, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 4, 4, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 0, 4, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 4, 0, 0 });
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 0,
            second: 1,
        );
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 2,
            second: 3,
        );
        scratch.exact.peak = 0;
        PlanarEdges crossed = normalize_planar_edges(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:fixture.segment_count],
        )!!;
        assert(crossed.vertices.len == 5 && crossed.edges.len == 4);
        assert_point_coordinates(
            scratch: scratch.exact,
            planes: crossed.vertices[2],
            raw: { 2, 2, 0 },
            grid: { 8, 8, 0 },
            quantized: domain != 0,
        );
        assert_planar_graph(scratch.exact, &crossed, 2);
        add_planar_vertex(scratch.exact, &fixture, { 2, 2, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 2, 5, 0 });
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 4,
            second: 5,
        );
        scratch.exact.peak = 0;
        PlanarEdges tee = normalize_planar_edges(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:fixture.segment_count],
        )!!;
        assert(tee.vertices.len == 6 && tee.edges.len == 5);
        assert(same_vertex(scratch.exact, crossed.vertices[2], tee.vertices[2])!!);
        assert_planar_graph(scratch.exact, &tee, 2);
        assert(scratch.exact.peak <= 16 && scratch.exact.count == 0);
    }
}

fn void test_planar_rational_intersection_uses_independent_edge_line_members() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        init_planar_fixture(scratch.exact, &fixture, domain != 0);
        add_planar_vertex(scratch.exact, &fixture, { 0, 0, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 3, 1, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 0, 1, 0 });
        add_planar_vertex(scratch.exact, &fixture, { 1, 0, 0 });
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 0,
            second: 1,
        );
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 2,
            second: 3,
        );
        ExactPlane* alternative = &fixture.planes[fixture.plane_count++];
        plane_from_integers(scratch.exact, alternative, { 1, -3, 1, 0 })!!;
        fixture.segments[0].line = { alternative, fixture.segments[0].line[1] };
        PlanarEdges graph = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:2])!!;
        assert(graph.vertices.len == 5 && graph.edges.len == 4);
        assert_point_coordinates(
            scratch: scratch.exact,
            planes: graph.vertices[2],
            raw: { 3, 1, 0 },
            grid: { 12, 4, 0 },
            quantized: domain != 0,
            denominator: 4,
        );
        assert_planar_graph(scratch.exact, &graph, 2);
    }
}

fn void test_planar_collinear_overlaps_keep_signed_multiplicity_and_cancel_opposites() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        init_planar_fixture(scratch.exact, &fixture, domain != 0);
        for (uint index = 0; index < 6; index++) add_planar_vertex(scratch.exact, &fixture, { (float)index, 0, 0 });
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 0,
            second: 4,
        );
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 3,
            second: 1,
        );
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 2,
            second: 5,
        );
        PlanarEdges graph = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:3])!!;
        assert(graph.vertices.len == 6 && graph.edges.len == 4);
        uint[2][4] endpoints = { { 0, 1 }, { 2, 3 }, { 3, 4 }, { 4, 5 } };
        long[4] weights = { 1, 1, 2, 1 };
        foreach (index, edge : graph.edges) {
            assert(edge.first == endpoints[index][0] && edge.second == endpoints[index][1]
                && edge.weight == weights[index]);
        }
        fixture.segment_count = 0;
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 0,
            second: 4,
        );
        append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: 4,
            second: 0,
        );
        usz saved = scratch.used;
        PlanarEdges empty = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:2])!!;
        assert(!empty.edges.len && !empty.vertices.len && scratch.used == saved);
        empty = normalize_planar_edges(&scratch, &fixture.planes[0], {})!!;
        assert(!empty.edges.len && !empty.vertices.len && scratch.used == saved && scratch.exact.count == 0);
    }
}

fn void test_planar_subdivided_opposite_faces_cancel_and_permutations_are_canonical() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    for (uint domain = 0; domain < 2; domain++) {
        SolidScratch scratch = begin_solid_scratch(&workspace);
        PlanarFixture fixture;
        init_planar_fixture(scratch.exact, &fixture, domain != 0);
        Vec3[6] positions = { { 0, 0, 0 }, { 2, 0, 0 }, { 4, 0, 0 }, { 4, 4, 0 }, { 2, 4, 0 }, { 0, 4, 0 } };
        foreach (position : positions) add_planar_vertex(scratch.exact, &fixture, position);
        uint[2][12] pairs = {
            { 0, 2 }, { 2, 3 }, { 3, 5 }, { 5, 0 },
            { 0, 5 }, { 5, 4 }, { 4, 1 }, { 1, 0 },
            { 1, 4 }, { 4, 3 }, { 3, 2 }, { 2, 1 },
        };
        foreach (pair : pairs) append_planar_segment(
            scratch: scratch.exact,
            fixture: &fixture,
            first: pair[0],
            second: pair[1],
        );
        usz saved = scratch.used;
        PlanarEdges empty = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:12])!!;
        assert(!empty.edges.len && !empty.vertices.len && scratch.used == saved);
        PlanarEdges half = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:8])!!;
        assert(half.edges.len == 4 && half.vertices.len == 4);
        for (uint repeat = 0; repeat < 8; repeat++) {
            PlanarSegment first = fixture.segments[0];
            for (uint index = 0; index < 7; index++) fixture.segments[index] = fixture.segments[index + 1];
            fixture.segments[7] = first;
            PlanarEdges reordered = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:8])!!;
            assert_same_planar_graph(scratch.exact, &half, &reordered);
        }
    }
}

fn void test_planar_projected_predicates_cover_raw_extremes_and_grid_limits() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    float tiny = bitcast((uint)1, float);
    Vec3[4] raw = {
        { float::max, tiny, 0 }, { 0, -float::max, tiny },
        { -float::max / 2, 0, float::max }, { tiny, float::max / 2, -float::max },
    };
    long limit = ((long)1 << 30) - 1;
    GridPoint[4] grid = { { -limit, -limit, 0 }, { limit, -limit + 1, 0 }, { limit - 1, limit, 0 }, { 0, 0, limit } };
    for (uint domain = 0; domain < 2; domain++) {
        ExactPlane[4] faces;
        PlaneTriple[4] vertices;
        for (uint face = 0; face < 4; face++) {
            Vec3[3] raw_triangle;
            GridPoint[3] grid_triangle;
            uint count;
            for (uint point = 0; point < 4; point++) if (point != face) {
                raw_triangle[count] = raw[point];
                grid_triangle[count++] = grid[point];
            }
            if (domain) {
                plane_from_grid(scratch, &faces[face], grid_triangle)!!;
            } else {
                plane_from_float(scratch, &faces[face], raw_triangle)!!;
            }
            count = 0;
            for (uint other = 0; other < 4; other++) if (other != face) vertices[face][count++] = &faces[other];
        }
        scratch.peak = 0;
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            int expected = domain ? projected_grid_orientation(scratch, { grid[0], grid[1], grid[2] }, axis)
                : exact_projected_orientation(scratch, { raw[0], raw[1], raw[2] }, axis)!!;
            PlaneTriple[3] triangle = { vertices[0], vertices[1], vertices[2] };
            assert(exact_planar_orientation(scratch, triangle, axis)!! == expected);
            assert(planar_orientation(scratch, triangle, axis)!! == expected);
            int filtered = filter_planar_orientation(triangle, axis);
            assert(filtered == FILTER_UNCERTAIN || filtered == expected);
            assert(compare_planar_points(
                scratch: scratch,
                first: vertices[0],
                second: vertices[0],
                dropped_axis: axis,
            )!! == 0);
        }
        assert(scratch.peak == PROJECTED_ORIENTATION_TEMPORARIES && scratch.count == 0);
    }
}

fn void test_planar_filters_defer_nearly_collinear_constructed_points() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    ExactPlane[7] planes;
    plane_from_integers(scratch, &planes[0], { 0, 0, 1, 0 })!!;
    uint uncertain;
    for (uint sample = 0; sample < 32; sample++) {
        int128 magnitude = ((int128)1 << 30) - sample - 2;
        int128 delta = sample % 3;
        int128[2][3] positions = { { 0, 0 }, { magnitude, magnitude - 1 }, { magnitude - 1, magnitude - 2 + delta } };
        PlaneTriple[3] vertices;
        foreach (uint vertex, point : positions) {
            plane_from_integers(scratch, &planes[vertex * 2 + 1], { 1, 0, 0, -point[0] })!!;
            plane_from_integers(scratch, &planes[vertex * 2 + 2], { 0, 1, 0, -point[1] })!!;
            vertices[vertex] = { &planes[0], &planes[vertex * 2 + 1], &planes[vertex * 2 + 2] };
        }
        int expected = delta ? 1 : -1;
        assert(exact_planar_orientation(scratch, vertices, 2)!! == expected);
        assert(planar_orientation(scratch, vertices, 2)!! == expected);
        int filtered = filter_planar_orientation(vertices, 2);
        if (filtered == FILTER_UNCERTAIN) {
            uncertain++;
        } else {
            assert(filtered == expected);
        }
    }
    assert(uncertain > 0 && scratch.count == 0);
}

fn void test_planar_capacity_failure_preserves_inputs_and_workspace_prefix() @test {
    FractureWorkspace workspace = cell_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    PlanarFixture fixture;
    init_planar_fixture(scratch.exact, &fixture, false);
    foreach (point : ((Vec3[4]){ { 0, 0, 0 }, { 4, 4, 0 }, { 0, 4, 0 }, { 4, 0, 0 } })) {
        add_planar_vertex(scratch.exact, &fixture, point);
    }
    append_planar_segment(
        scratch: scratch.exact,
        fixture: &fixture,
        first: 0,
        second: 1,
    );
    append_planar_segment(
        scratch: scratch.exact,
        fixture: &fixture,
        first: 2,
        second: 3,
    );
    char[] prefix = reserve_elements(&scratch, char, 16)!!;
    foreach (index, &value : prefix) *value = (char)index;
    usz saved = scratch.used;
    PlanarEdges graph = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:2])!!;
    usz required = scratch.peak;
    assert(graph.vertices.len == 5 && graph.edges.len == 4);
    for (usz capacity = saved; capacity < required; capacity += 17) {
        scratch.used = saved;
        scratch.storage = workspace.storage[:capacity];
        assert(@catch(normalize_planar_edges(
            scratch: &scratch,
            plane: &fixture.planes[0],
            segments: fixture.segments[:2],
        )) == c3d::CAPACITY_EXCEEDED);
        assert(scratch.used == saved && scratch.exact.count == 0);
        foreach (index, value : prefix) assert(value == (char)index);
        assert(same_vertex(scratch.exact, fixture.vertices[0], fixture.segments[0].first)!!);
    }
    scratch.storage = workspace.storage[:required];
    uint held = EXACT_TEMPORARIES - PROJECTED_ORIENTATION_TEMPORARIES + 1;
    for (uint index = 0; index < held; index++) (void)scratch.exact.take()!!;
    assert(@catch(normalize_planar_edges(
        scratch: &scratch,
        plane: &fixture.planes[0],
        segments: fixture.segments[:2],
    )) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == saved && scratch.exact.count == held);
    scratch.exact.count = 0;
    graph = normalize_planar_edges(&scratch, &fixture.planes[0], fixture.segments[:2])!!;
    assert(graph.vertices.len == 5 && graph.edges.len == 4 && scratch.exact.count == 0);
}

fn void init_planar_fixture(ExactScratch* scratch, PlanarFixture* fixture, bool quantized) @local {
    fixture.quantized = quantized;
    fixture.plane_count = 1;
    plane_from_integers(scratch, &fixture.planes[0], { 0, 0, 1, 0 })!!;
}

fn void add_planar_vertex(ExactScratch* scratch, PlanarFixture* fixture, Vec3 position) @local {
    uint index = fixture.vertex_count++;
    fixture.positions[index] = position;
    fixture.vertices[index][2] = &fixture.planes[0];
    for (uint axis = 0; axis < 2; axis++) {
        ExactPlane* plane = &fixture.planes[fixture.plane_count++];
        fixture.vertices[index][axis] = plane;
        float coordinate = position[axis];
        long bound = coordinate < 0 ? -(long)bitcast(-coordinate, uint) : (long)bitcast(coordinate, uint);
        bounds_axis_plane(
            scratch: scratch,
            plane: plane,
            axis: axis,
            bound: fixture.quantized ? (long)(coordinate * 4) : bound,
            quantized: fixture.quantized,
        )!!;
    }
}

fn void append_planar_segment(
    ExactScratch* scratch,
    PlanarFixture* fixture,
    uint first,
    uint second,
) @local {
    ExactPlane* line = &fixture.planes[fixture.plane_count++];
    Vec3[3] triangle = {
        fixture.positions[first], fixture.positions[second], fixture.positions[first] + (Vec3){ 0, 0, 1 },
    };
    if (fixture.quantized) {
        GridPoint[3] grid;
        foreach (uint vertex, point : triangle) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) grid[vertex][axis] = (long)(point[axis] * 4);
        }
        plane_from_grid(scratch, line, grid)!!;
    } else {
        plane_from_float(scratch, line, triangle)!!;
    }
    fixture.segments[fixture.segment_count++] = {
        .first = fixture.vertices[first], .second = fixture.vertices[second], .line = { &fixture.planes[0], line },
    };
}

fn void assert_planar_graph(ExactScratch* scratch, PlanarEdges* graph, uint dropped_axis) @local {
    foreach (uint index, vertex : graph.vertices) {
        if (index) assert(compare_planar_points(
            scratch: scratch,
            first: graph.vertices[index - 1],
            second: vertex,
            dropped_axis: dropped_axis,
        )!! < 0);
    }
    foreach (uint index, edge : graph.edges) {
        assert(edge.first < edge.second && edge.second < graph.vertices.len && edge.weight);
        if (index) assert(graph.edges[index - 1].first < edge.first
            || (graph.edges[index - 1].first == edge.first && graph.edges[index - 1].second < edge.second));
        for (uint point = edge.first + 1; point < edge.second; point++) {
            assert(planar_orientation(
                scratch: scratch,
                vertices: { graph.vertices[edge.first], graph.vertices[edge.second], graph.vertices[point] },
                dropped_axis: dropped_axis,
            )!! != 0);
        }
    }
}

fn void assert_same_planar_graph(ExactScratch* scratch, PlanarEdges* first, PlanarEdges* second) @local {
    assert(first.vertices.len == second.vertices.len && first.edges.len == second.edges.len);
    foreach (index, vertex : first.vertices) assert(same_vertex(scratch, vertex, second.vertices[index])!!);
    foreach (index, edge : first.edges) {
        PlanarEdge other = second.edges[index];
        assert(edge.first == other.first && edge.second == other.second && edge.weight == other.weight);
        assert_plane_equal(edge.line[0], other.line[0]);
        assert_plane_equal(edge.line[1], other.line[1]);
    }
}
