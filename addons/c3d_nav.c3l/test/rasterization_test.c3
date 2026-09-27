module c3d_nav_test;

import std::math;
import c3d;
import c3d::maths;
import c3d::nav;

const char SPAN_AREA @private = 42;
const uint MERGE_THRESHOLD @private = 1;

fn Heightfield span_field() @private => heightfield(width: 4, height: 4, layers: 10, cell_size: 1, cell_height: 2);

fn Heightfield triangle_field() @private => heightfield(width: 10, height: 10, layers: 10, cell_size: 1, cell_height: 1);

fn void add(Heightfield* field, uint min, uint max, char area = SPAN_AREA) @private {
    field.add_span(
        x:               0,
        z:               0,
        min:             min,
        max:             max,
        area:            area,
        merge_threshold: MERGE_THRESHOLD,
    )!!;
}

fn void test_add_span_to_empty_column() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 1, SPAN_AREA)));
}

fn void test_add_zero_or_inverted_span_does_nothing() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 0);
    assert(is_empty(&field, { 0, 0 }));
    add(&field, 1, 0);
    assert(is_empty(&field, { 0, 0 }));
}

fn void test_disjoint_spans_are_not_merged() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1);
    add(&field, 2, 3);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.count == 2);
    assert(column.extents[0] == extent(0, 1, SPAN_AREA));
    assert(column.extents[1] == extent(2, 3, SPAN_AREA));
}

fn void test_merge_within_threshold_keeps_higher_area() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1, 42);
    add(&field, 1, 2, 24);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 2, 42)));
}

fn void test_merge_outside_threshold_keeps_last_area() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1, 42);
    add(&field, 1, 8, 24);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 8, 24)));
}

fn void test_touching_span_merges() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1);
    add(&field, 1, 2);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 2, SPAN_AREA)));
}

fn void test_span_between_two_merges_all_three() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 1);
    add(&field, 2, 3);
    add(&field, 1, 2);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 3, SPAN_AREA)));
}

fn void test_spans_insert_sorted_by_height() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 2, 3);
    add(&field, 0, 1);
    add(&field, 6, 7);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.count == 3);
    assert(column.extents[0] == extent(0, 1, SPAN_AREA));
    assert(column.extents[1] == extent(2, 3, SPAN_AREA));
    assert(column.extents[2] == extent(6, 7, SPAN_AREA));
}

fn void test_span_inside_span_merges() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 8);
    add(&field, 2, 3);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 8, SPAN_AREA)));
}

fn void test_overlapping_spans_merge() @test {
    Heightfield field = span_field();
    defer nav::destroy_heightfield(&field);

    add(&field, 0, 4);
    add(&field, 2, 6);

    assert(has_single_span(&field, { 0, 0 }, extent(0, 6, SPAN_AREA)));
}

fn void test_pool_grows_past_initial_capacity() @test {
    Heightfield field = heightfield(width: 100, height: 100, layers: 10, cell_size: 1, cell_height: 2, initial_spans: 4);
    defer nav::destroy_heightfield(&field);

    for (uint z = 0; z < field.height; z++) {
        for (uint x = 0; x < field.width; x++) {
            field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            SPAN_AREA,
                merge_threshold: MERGE_THRESHOLD,
            )!!;
        }
    }

    assert(field.walkable_span_count() == 10000);
}

fn void test_reset_empties_columns_and_keeps_capacity() @test {
    Heightfield field = heightfield(width: 100, height: 100, layers: 10, cell_size: 1, cell_height: 2, initial_spans: 4);
    defer nav::destroy_heightfield(&field);
    for (uint z = 0; z < field.height; z++) {
        for (uint x = 0; x < field.width; x++) {
            field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            SPAN_AREA,
                merge_threshold: MERGE_THRESHOLD,
            )!!;
        }
    }
    usz capacity = field.pool.spans.len;

    field.reset();

    assert(field.walkable_span_count() == 0);
    foreach (head : field.columns) assert(head == nav::NULL_SPAN);
    assert(field.pool.spans.len == capacity);
}

fn void test_rasterize_triangle_on_xz_plane() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 2 }, nav::WALKABLE_AREA)!!;

    uint[<2>][3] cells = { { 0, 0 }, { 0, 1 }, { 1, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 1, nav::WALKABLE_AREA)));
}

fn void test_rasterize_triangle_inside_one_voxel() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 }, nav::WALKABLE_AREA)!!;

    uint[<2>][1] cells = { { 0, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 1, nav::WALKABLE_AREA)));
}

fn void test_rasterize_clips_to_the_bounds() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ -2, 0, -2 }, { 4, 0, -2 }, { -2, 0, 4 }, nav::WALKABLE_AREA)!!;

    uint[<2>][3] cells = { { 0, 0 }, { 0, 1 }, { 1, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 1, nav::WALKABLE_AREA)));
}

fn void test_triangle_outside_the_bounds_rasterizes_nothing() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ -5, 0, -5 }, { -5, 0, 5 }, { 5, 0, -5 }, nav::WALKABLE_AREA)!!;
    assert(only_cells_hold(&field, {}, {}), "outside the XZ bounds");
    field.rasterize_triangle({ 0, -1, 0 }, { 5, -1, 5 }, { 5, -1, 0 }, nav::WALKABLE_AREA)!!;
    assert(only_cells_hold(&field, {}, {}), "below the Y bounds");
    field.rasterize_triangle({ 0, 40, 0 }, { 5, 40, 5 }, { 5, 40, 0 }, nav::WALKABLE_AREA)!!;
    assert(only_cells_hold(&field, {}, {}), "above the Y bounds");
}

fn void test_partly_covered_voxel_is_rasterized() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ -1, 0, -1 }, { 1.01f, 0, -1 }, { -1, 0, 1.01f }, nav::WALKABLE_AREA)!!;

    uint[<2>][1] cells = { { 0, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 1, nav::WALKABLE_AREA)));
}

fn void test_vertical_span_covers_every_touched_voxel() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ 0, 0, 0 }, { 0.5f, 0, 0.5f }, { 0.5f, 2.01f, 0.5f }, nav::WALKABLE_AREA)!!;

    uint[<2>][1] cells = { { 0, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 3, nav::WALKABLE_AREA)));
}

fn void test_sloped_triangle_varies_span_heights() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ 0, 0, 0.5f }, { 4, 0, 0.5f }, { 2, 2, 0.5f }, nav::WALKABLE_AREA)!!;

    for (uint z = 0; z < field.height; z++) {
        for (uint x = 0; x < field.width; x++) {
            if (z == 0 && (x == 0 || x == 3)) {
                assert(has_single_span(&field, { x, z }, extent(0, 1, nav::WALKABLE_AREA)));
            } else if (z == 0 && (x == 1 || x == 2)) {
                assert(has_single_span(&field, { x, z }, extent(0, 2, nav::WALKABLE_AREA)));
            } else {
                assert(is_empty(&field, { x, z }));
            }
        }
    }
}

fn void test_triangle_crossing_y_bounds_is_clamped() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ 0, -5, 0 }, { 1, -5, 1 }, { 0.5f, 15, 0.5f }, nav::WALKABLE_AREA)!!;

    uint[<2>][1] cells = { { 0, 0 } };
    assert(only_cells_hold(&field, cells[..], extent(0, 10, nav::WALKABLE_AREA)));
}

fn void test_outside_triangle_with_overlapping_bounds_rasterizes_nothing() @test {
    Heightfield field = triangle_field();
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangle({ -10, 5.5f, -10 }, { -10, 5.5f, 3 }, { 3, 5.5f, -10 }, nav::WALKABLE_AREA)!!;

    assert(only_cells_hold(&field, {}, {}));
}

fn void test_rasterize_indexed_triangles() @test {
    Vec3[4] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 } };
    uint[6] indices = { 0, 1, 2, 0, 3, 1 };
    char[2] areas = { 1, 2 };
    Aabb bounds = { .min = { 0, 0, -1 }, .max = { 1, 0, 1 } };
    uint[<2>] size = nav::grid_size(bounds, 0.5f);
    Heightfield field = nav::create_heightfield(mem, size.x, size.y, bounds, 0.5f, 0.5f)!!;
    defer nav::destroy_heightfield(&field);

    field.rasterize_triangles(positions[..], indices[..], areas[..])!!;

    assert(has_single_span(&field, { 0, 0 }, extent(0, 1, 1)));
    assert(has_single_span(&field, { 0, 1 }, extent(0, 1, 1)));
    assert(has_single_span(&field, { 0, 2 }, extent(0, 1, 2)));
    assert(has_single_span(&field, { 0, 3 }, extent(0, 1, 2)));
    assert(is_empty(&field, { 1, 0 }));
    assert(has_single_span(&field, { 1, 1 }, extent(0, 1, 1)));
    assert(has_single_span(&field, { 1, 2 }, extent(0, 1, 2)));
    assert(is_empty(&field, { 1, 3 }));
}

fn void test_grid_size_rounds_to_the_nearest_cell() @test {
    Aabb bounds = { .min = { 0, 2, 3 }, .max = { 1, 2, 6 } };

    assert(nav::grid_size(bounds, 1.5f) == { 1, 2 });
}

fn void test_create_heightfield_rejects_an_empty_grid() @test {
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } };

    if (catch excuse = nav::create_heightfield(mem, 0, 4, bounds, 1, 1)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty grid faults");
    }
}

fn void test_mark_walkable_triangles() @test {
    Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 } };
    uint[3] up = { 0, 1, 2 };
    uint[3] down = { 0, 2, 1 };
    char[1] areas = { nav::NULL_AREA };

    nav::mark_walkable_triangles(45, positions[..], up[..], areas[..]);
    assert(areas[0] == nav::WALKABLE_AREA);
    areas[0] = nav::NULL_AREA;
    nav::mark_walkable_triangles(45, positions[..], down[..], areas[..]);
    assert(areas[0] == nav::NULL_AREA);
    areas[0] = 42;
    nav::mark_walkable_triangles(45, positions[..], down[..], areas[..]);
    assert(areas[0] == 42);
}

fn void test_clear_unwalkable_triangles() @test {
    Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 } };
    uint[3] up = { 0, 1, 2 };
    uint[3] down = { 0, 2, 1 };
    char[1] areas = { 42 };

    nav::clear_unwalkable_triangles(45, positions[..], down[..], areas[..]);
    assert(areas[0] == nav::NULL_AREA);
    areas[0] = 42;
    nav::clear_unwalkable_triangles(45, positions[..], up[..], areas[..]);
    assert(areas[0] == 42);
}

fn void test_slope_at_the_limit_is_unwalkable() @test {
    Vec3[3] flat = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 } };
    uint[3] up = { 0, 1, 2 };
    char[1] areas = { nav::NULL_AREA };

    nav::mark_walkable_triangles(0, flat[..], up[..], areas[..]);
    assert(areas[0] == nav::NULL_AREA);
    areas[0] = 42;
    nav::clear_unwalkable_triangles(0, flat[..], up[..], areas[..]);
    assert(areas[0] == nav::NULL_AREA);

    foreach (degrees : (float[2]){ 44.9f, 45.1f }) {
        float radians = (float)math::deg_to_rad(degrees);
        Vec3[3] tilted = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, math::sin(radians), -math::cos(radians) } };
        areas[0] = nav::NULL_AREA;
        nav::mark_walkable_triangles(45, tilted[..], up[..], areas[..]);
        assert(areas[0] == (degrees < 45 ? nav::WALKABLE_AREA : nav::NULL_AREA));
    }
}

fn void test_grid_size_of_inverted_bounds_is_empty() @test {
    Aabb inverted = { .min = { 4, 0, 4 }, .max = { 1, 0, 1 } };

    assert(nav::grid_size(inverted, 1) == { 0, 0 });
}
