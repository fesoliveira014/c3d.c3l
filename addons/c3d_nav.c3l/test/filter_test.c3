module c3d_nav_test;

import c3d::nav;

const uint FILTER_HEIGHT @private = 5;

fn Heightfield single_column() @private => heightfield(width: 1, height: 1, layers: 64, cell_size: 1, cell_height: 1);

fn void stack(Heightfield* field, uint min, uint max, char area) @private {
    field.add_span(
        x:               0,
        z:               0,
        min:             min,
        max:             max,
        area:            area,
        merge_threshold: 0,
    )!!;
}

fn void test_span_without_spans_above_stays_walkable() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);

    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);

    assert(column_spans(&field, { 0, 0 }).extents[0].area == 1);
}

fn void test_span_with_high_span_above_is_unchanged() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);
    stack(&field, 1 + FILTER_HEIGHT, 2 + FILTER_HEIGHT, nav::NULL_AREA);

    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);
    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == 1 && column.extents[1].area == nav::NULL_AREA);

    field.span(field.span(field.span_at(0, 0)).next).extent = extent(11 + FILTER_HEIGHT, 12 + FILTER_HEIGHT, nav::NULL_AREA);
    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);
    column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == 1 && column.extents[1].area == nav::NULL_AREA);
}

fn void test_low_obstacle_within_climb_becomes_walkable() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);
    stack(&field, FILTER_HEIGHT, FILTER_HEIGHT + 1, nav::NULL_AREA);

    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == 1 && column.extents[1].area == 1);
}

fn void test_low_obstacle_past_climb_is_unchanged() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);
    stack(&field, FILTER_HEIGHT + 1, FILTER_HEIGHT + 2, nav::NULL_AREA);

    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == 1 && column.extents[1].area == nav::NULL_AREA);
}

fn void test_only_the_first_stacked_low_obstacle_becomes_walkable() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);
    uint top = 1;
    for (uint obstacle = 0; obstacle < 9; obstacle++) {
        uint bottom = top + FILTER_HEIGHT - 1;
        stack(&field, bottom, bottom + 1, nav::NULL_AREA);
        top = bottom + 1;
    }

    field.filter_low_hanging_walkable_obstacles(FILTER_HEIGHT);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.count == 10);
    foreach (index, span : column.extents[:column.count]) {
        assert(span.area == (index <= 1 ? 1 : nav::NULL_AREA));
    }
}

fn void test_ledge_spans_are_marked_unwalkable() @test {
    Heightfield field = heightfield(width: 10, height: 10, layers: 1, cell_size: 1, cell_height: 1);
    defer nav::destroy_heightfield(&field);
    for (uint z = 0; z < field.height; z++) {
        for (uint x = 0; x < field.width; x++) {
            field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            1,
                merge_threshold: 0,
            )!!;
        }
    }

    field.filter_ledge_spans(walkable_height: 10, walkable_climb: 5);

    for (uint z = 0; z < field.height; z++) {
        for (uint x = 0; x < field.width; x++) {
            bool border = x == 0 || z == 0 || x == 9 || z == 9;
            assert(has_single_span(&field, { x, z }, extent(0, 1, border ? nav::NULL_AREA : 1)));
        }
    }
}

fn void test_low_height_filter_keeps_open_spans() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);

    field.filter_walkable_low_height_spans(FILTER_HEIGHT);
    assert(column_spans(&field, { 0, 0 }).extents[0].area == 1);

    stack(&field, 10, 11, nav::NULL_AREA);
    field.filter_walkable_low_height_spans(FILTER_HEIGHT);
    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == 1 && column.extents[1].area == nav::NULL_AREA);
}

fn void test_low_height_filter_clears_a_low_ceiling() @test {
    Heightfield field = single_column();
    defer nav::destroy_heightfield(&field);
    stack(&field, 0, 1, 1);
    stack(&field, 3, 4, nav::NULL_AREA);

    field.filter_walkable_low_height_spans(FILTER_HEIGHT);

    ColumnSpans column = column_spans(&field, { 0, 0 });
    assert(column.extents[0].area == nav::NULL_AREA && column.extents[1].area == nav::NULL_AREA);
}
