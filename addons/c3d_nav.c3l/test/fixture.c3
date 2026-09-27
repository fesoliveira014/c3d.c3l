module c3d_nav_test;

import std::math;
import c3d::maths;
import c3d::nav;

const uint MAX_COLUMN_SPANS @private = 16;

struct ColumnSpans @private {
    SpanExtent[MAX_COLUMN_SPANS] extents;
    usz                          count;
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
