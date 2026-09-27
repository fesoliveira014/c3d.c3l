module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d::maths;
import c3d::nav;

const uint MAX_COLUMN_SPANS @private = 16;
const usz  COMPACT_FIXTURE_BYTES @private = 64 * 1024;
const uint COMPACT_FIXTURE_LAYERS @private = 16;
const uint FIXTURE_WALKABLE_HEIGHT @private = 3;
const uint FIXTURE_WALKABLE_CLIMB @private = 1;

const String[] RECTANGLE_FLOOR @private = {
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
};

const String[] L_FLOOR @private = {
    "##########",
    "##########",
    "##########",
    "##########",
    "####......",
    "####......",
    "####......",
    "####......",
    "####......",
    "####......",
};

const String[] SQUARE_FLOOR @private = {
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
    "############",
};

struct ColumnSpans @private {
    SpanExtent[MAX_COLUMN_SPANS] extents;
    usz                          count;
}

// The arena backs the compact field and serves as scratch and output for the builds under test.
struct CompactFixture @private {
    Heightfield                 field;
    char[COMPACT_FIXTURE_BYTES] buffer;
    ArenaAllocator              arena;
    CompactHeightfield          compact;
}

fn Heightfield heightfield(
    uint width,
    uint height,
    uint layers,
    float cell_size,
    float cell_height,
    uint initial_spans = nav::SPAN_POOL_GROWTH,
) @private {
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { width * cell_size, layers * cell_height, height * cell_size } };
    return nav::create_heightfield(
        allocator:     mem,
        width:         width,
        height:        height,
        bounds:        bounds,
        cell_size:     cell_size,
        cell_height:   cell_height,
        initial_spans: initial_spans,
    )!!;
}

fn SpanExtent extent(uint min, uint max, uint area) @private => { .min = min, .max = max, .area = area };

fn ColumnSpans column_spans(Heightfield* heightfield, uint[<2>] cell) @private {
    ColumnSpans column;
    for (uint index = heightfield.span_at(cell.x, cell.y); index != nav::NULL_SPAN; index = heightfield.span(index).next) {
        column.extents[column.count++] = heightfield.span(index).extent;
    }
    return column;
}

fn bool has_single_span(Heightfield* heightfield, uint[<2>] cell, SpanExtent expected) @private {
    ColumnSpans column = column_spans(heightfield, cell);
    return column.count == 1 && column.extents[0] == expected;
}

fn bool is_empty(Heightfield* heightfield, uint[<2>] cell) @private => heightfield.span_at(cell.x, cell.y) == nav::NULL_SPAN;

fn bool only_cells_hold(Heightfield* heightfield, uint[<2>][] cells, SpanExtent expected) @private {
    for (uint z = 0; z < heightfield.height; z++) {
        for (uint x = 0; x < heightfield.width; x++) {
            bool listed;
            foreach (cell : cells) {
                if (cell.x == x && cell.y == z) listed = true;
            }
            if (listed && !has_single_span(heightfield, { x, z }, expected)) return false;
            if (!listed && !is_empty(heightfield, { x, z })) return false;
        }
    }
    return true;
}

// '#' is a walkable floor cell, a digit a floor cell of that area, '.' empty; one string per row of z.
fn void compact_from(CompactFixture* fixture, String[] mask) @private {
    fixture.field = heightfield(
        width:       (uint)mask[0].len,
        height:      (uint)mask.len,
        layers:      COMPACT_FIXTURE_LAYERS,
        cell_size:   1,
        cell_height: 1,
    );
    fill_from_mask(&fixture.field, mask);
    compact_fixture_field(fixture);
}

fn void fill_from_mask(Heightfield* field, String[] mask) @private {
    foreach (z, row : mask) {
        foreach (x, cell : row) {
            if (cell == '.') continue;
            field.add_span(
                x:               (uint)x,
                z:               (uint)z,
                min:             0,
                max:             1,
                area:            cell == '#' ? nav::WALKABLE_AREA : cell - '0',
                merge_threshold: 0,
            )!!;
        }
    }
}

fn void compact_fixture_field(CompactFixture* fixture) @private {
    fixture.arena.init(fixture.buffer[..]);
    fixture.compact = nav::build_compact_heightfield(
        allocator:       &fixture.arena,
        heightfield:     &fixture.field,
        walkable_height: FIXTURE_WALKABLE_HEIGHT,
        walkable_climb:  FIXTURE_WALKABLE_CLIMB,
    )!!;
}

fn void destroy_compact_fixture(CompactFixture* fixture) @private => nav::destroy_heightfield(&fixture.field);

fn CompactSpan* first_span(CompactHeightfield* compact, uint x, uint z) @private {
    return &compact.spans[compact.cells[x + z * compact.width].index];
}
