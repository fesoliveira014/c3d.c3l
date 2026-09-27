module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::maths;
import c3d::nav @public;

const float CONTOUR_MAX_ERROR @private = 1.3f;
const uint  LONG_EDGE_LIMIT @private = 4;
const int   SHARED_COLUMN @private = 6;
const char  SECOND_AREA @private = 5;
const uint  CONTOUR_BORDER @private = 2;
const int   HOLED_SIZE @private = 12;
const int   HOLE_MIN @private = 4;
const int   HOLE_MAX @private = 8;
const usz   TINY_OUTPUT_BYTES @private = 64;
const usz   INT_LIST_ARENA_BYTES @private = 128;
const sz    INT_LIST_INITIAL_CAPACITY @private = 2;
const int   INT_LIST_FITTING_VALUES @private = 16; // 64 bytes fit the arena; the next doubling to 128 cannot

const String[] LONG_STRIP_FLOOR @private = {
    "####################",
    "####################",
};

const String[] TWO_AREA_FLOOR @private = {
    "######555555",
    "######555555",
    "######555555",
    "######555555",
    "######555555",
    "######555555",
};

const String[] HOLED_FLOOR @private = {
    "############",
    "############",
    "############",
    "############",
    "####....####",
    "####....####",
    "####....####",
    "####....####",
    "############",
    "############",
    "############",
    "############",
};

fn void assign_region(CompactHeightfield* compact, ushort region) @private {
    foreach (&span : compact.spans) span.region = region;
    compact.max_regions = region;
}

fn ContourSet contours_of(CompactFixture* fixture, uint max_edge_length = 0) @private {
    return nav::build_contours(
        allocator:       &fixture.arena,
        scratch:         &fixture.arena,
        compact:         &fixture.compact,
        max_error:       CONTOUR_MAX_ERROR,
        max_edge_length: max_edge_length,
    )!!;
}

fn int[4][] vertices_of(int[] values) @private => ((int[4]*)values.ptr)[:values.len / 4];

fn bool has_vertex(int[4][] vertices, int x, int z) @private {
    foreach (vertex : vertices) {
        if (vertex[0] == x && vertex[2] == z) return true;
    }
    return false;
}

fn usz vertices_on_row(int[4][] vertices, int z) @private {
    usz count;
    foreach (vertex : vertices) {
        if (vertex[2] == z) count++;
    }
    return count;
}

// The strips are painted in the order build_regions_monotone paints them, so each side has its own id.
fn ushort bordered_region(uint x, uint z, uint size) @private {
    if (z >= size - CONTOUR_BORDER) return nav::BORDER_REGION | 4;
    if (z < CONTOUR_BORDER) return nav::BORDER_REGION | 3;
    if (x >= size - CONTOUR_BORDER) return nav::BORDER_REGION | 2;
    if (x < CONTOUR_BORDER) return nav::BORDER_REGION | 1;
    return 1;
}

fn int twice_signed_area(int[4][] vertices) @private {
    int area;
    sz previous = vertices.len - 1;
    for (sz current = 0; current < vertices.len; previous = current++) {
        area += vertices[current][0] * vertices[previous][2] - vertices[previous][0] * vertices[current][2];
    }
    return area;
}

fn void test_rectangle_yields_one_four_vertex_contour() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);

    ContourSet set = contours_of(fixture);

    int width = (int)RECTANGLE_FLOOR[0].len;
    int depth = (int)RECTANGLE_FLOOR.len;
    assert(set.contours.len == 1);
    Contour contour = set.contours[0];
    assert(contour.region == 1 && contour.area == nav::WALKABLE_AREA);
    assert(vertices_of(contour.raw_verts).len == (sz)(2 * (width + depth)));
    int[4][] vertices = vertices_of(contour.verts);
    assert(vertices.len == 4);
    assert(has_vertex(vertices, 0, 0) && has_vertex(vertices, width, 0));
    assert(has_vertex(vertices, width, depth) && has_vertex(vertices, 0, depth));
}

fn void test_simplified_vertices_come_from_the_raw_outline() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, L_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);

    ContourSet set = contours_of(fixture);

    assert(set.contours.len == 1);
    int[4][] vertices = vertices_of(set.contours[0].verts);
    int[4][] raw = vertices_of(set.contours[0].raw_verts);
    assert(vertices.len == 6);
    foreach (vertex : vertices) assert(has_vertex(raw, vertex[0], vertex[2]));
}

fn void test_long_edges_are_split() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, LONG_STRIP_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);

    ContourSet split = contours_of(fixture, LONG_EDGE_LIMIT);
    ContourSet whole = contours_of(fixture, 0);

    assert(split.contours.len == 1 && whole.contours.len == 1);
    assert(vertices_on_row(vertices_of(split.contours[0].verts), 0) >= 5);
    assert(vertices_on_row(vertices_of(whole.contours[0].verts), 0) == 2);
}

fn void test_area_border_vertices_are_flagged() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, TWO_AREA_FLOOR);
    defer destroy_compact_fixture(fixture);
    CompactHeightfield* compact = &fixture.compact;
    for (uint z = 0; z < compact.height; z++) {
        for (uint x = 0; x < compact.width; x++) first_span(compact, x, z).region = x < SHARED_COLUMN ? 1 : 2;
    }
    compact.max_regions = 2;

    ContourSet set = contours_of(fixture);

    assert(set.contours.len == 2);
    Contour first = set.contours[0].region == 1 ? set.contours[0] : set.contours[1];
    assert(first.region == 1 && first.area == nav::WALKABLE_AREA);
    int[4][] vertices = vertices_of(first.verts);
    usz on_shared_line;
    foreach (vertex : vertices) {
        if (vertex[0] == SHARED_COLUMN) on_shared_line++;
    }
    assert(on_shared_line == 2);
    bool found_shared_edge;
    foreach (index, vertex : vertices) {
        int[4] next = vertices[(index + 1) % vertices.len];
        if (vertex[0] != SHARED_COLUMN || next[0] != SHARED_COLUMN) continue;
        found_shared_edge = true;
        assert(vertex[3] == (2 | nav::AREA_BORDER));
        assert(next[3] == 0, "the edge leaving the second vertex borders empty space");
    }
    assert(found_shared_edge);
}

fn void test_border_is_removed_from_contour_coordinates() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, SQUARE_FLOOR);
    defer destroy_compact_fixture(fixture);
    CompactHeightfield* compact = &fixture.compact;
    uint size = SQUARE_FLOOR.len;
    for (uint z = 0; z < size; z++) {
        for (uint x = 0; x < size; x++) first_span(compact, x, z).region = bordered_region(x, z, size);
    }
    compact.max_regions = 1;
    compact.border_size = CONTOUR_BORDER;

    ContourSet set = contours_of(fixture);

    int interior = (int)(size - 2 * CONTOUR_BORDER);
    float pad = CONTOUR_BORDER * compact.cell_size;
    assert(set.width == (uint)interior && set.height == (uint)interior);
    assert(set.bounds.min.x == compact.bounds.min.x + pad && set.bounds.min.z == compact.bounds.min.z + pad);
    assert(set.bounds.max.x == compact.bounds.max.x - pad && set.bounds.max.z == compact.bounds.max.z - pad);
    assert(set.contours.len == 1);
    foreach (vertices : (int[][2]){ set.contours[0].verts, set.contours[0].raw_verts }) {
        foreach (vertex : vertices_of(vertices)) {
            assert(vertex[0] >= 0 && vertex[0] <= interior && vertex[2] >= 0 && vertex[2] <= interior);
        }
    }
}

fn void test_hole_is_merged_into_the_outline() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, HOLED_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);

    ContourSet set = contours_of(fixture);

    assert(set.contours.len == 2);
    Contour outline = set.contours[0].verts.len > 0 ? set.contours[0] : set.contours[1];
    Contour hole = set.contours[0].verts.len > 0 ? set.contours[1] : set.contours[0];
    assert(hole.verts.len == 0);
    int[4][] vertices = vertices_of(outline.verts);
    assert(vertices.len == 10, "four outline corners, four hole corners and the two bridge duplicates");
    int[2][4] outline_corners = { { 0, 0 }, { HOLED_SIZE, 0 }, { HOLED_SIZE, HOLED_SIZE }, { 0, HOLED_SIZE } };
    int[2][4] hole_corners = {
        { HOLE_MIN, HOLE_MIN },
        { HOLE_MAX, HOLE_MIN },
        { HOLE_MAX, HOLE_MAX },
        { HOLE_MIN, HOLE_MAX },
    };
    foreach (corner : outline_corners) assert(has_vertex(vertices, corner[0], corner[1]));
    foreach (corner : hole_corners) assert(has_vertex(vertices, corner[0], corner[1]));
    int hole_size = HOLE_MAX - HOLE_MIN;
    assert(twice_signed_area(vertices) == 2 * (HOLED_SIZE * HOLED_SIZE - hole_size * hole_size));
}

fn void test_contours_fault_when_the_allocator_is_too_small() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    assign_region(&fixture.compact, 1);
    char[TINY_OUTPUT_BYTES] small;
    ArenaAllocator output;
    output.init(small[..]);

    if (catch excuse = nav::build_contours(
        allocator:       &output,
        scratch:         &fixture.arena,
        compact:         &fixture.compact,
        max_error:       CONTOUR_MAX_ERROR,
        max_edge_length: 0,
    )) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "sixty-four bytes cannot hold the contour array");
    }
}

fn void test_int_list_grows_and_faults() @test {
    char[INT_LIST_ARENA_BYTES] buffer;
    ArenaAllocator arena;
    arena.init(buffer[..]);
    IntList list = nav::create_int_list(&arena, INT_LIST_INITIAL_CAPACITY)!!;
    defer nav::destroy_int_list(&list);

    for (int value = 0; value < INT_LIST_FITTING_VALUES; value++) list.push(value)!!;
    foreach (index, value : list.view()) assert(value == index);

    if (catch excuse = list.push(INT_LIST_FITTING_VALUES)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "the arena cannot hold the next doubling");
    }
    assert(list.count == INT_LIST_FITTING_VALUES);
    foreach (index, value : list.view()) assert(value == index);
}
