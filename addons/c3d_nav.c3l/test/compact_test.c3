module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::nav;

const uint COMPACT_HEIGHT @private = 4;
const uint COMPACT_CLIMB @private = 2;
const usz  COMPACT_ARENA_BYTES @private = 64 * 1024;

fn void add_column(
    Heightfield* field,
    uint x,
    uint top,
    char area = nav::WALKABLE_AREA,
) @private {
    field.add_span(
        x:               x,
        z:               0,
        min:             0,
        max:             top,
        area:            area,
        merge_threshold: 0,
    )!!;
}

fn void test_compact_counts_only_walkable_spans() @test {
    Heightfield field = heightfield(width: 1, height: 1, layers: 64, cell_size: 1, cell_height: 1);
    defer nav::destroy_heightfield(&field);
    add_column(&field, 0, 2);
    field.add_span(
        x:               0,
        z:               0,
        min:             20,
        max:             22,
        area:            nav::NULL_AREA,
        merge_threshold: 0,
    )!!;
    char[COMPACT_ARENA_BYTES] buffer;
    ArenaAllocator arena;
    arena.init(buffer[..]);

    CompactHeightfield compact = nav::build_compact_heightfield(&arena, &field, COMPACT_HEIGHT, COMPACT_CLIMB)!!;

    assert(compact.span_count == 1);
    assert(compact.cells[0].count == 1);
    assert(compact.spans[0].y == 2);
    assert(compact.spans[0].links.height == 18);
    assert(compact.areas[0] == nav::WALKABLE_AREA);
}

fn void test_compact_links_neighbours_within_climb() @test {
    Heightfield field = heightfield(width: 3, height: 1, layers: 64, cell_size: 1, cell_height: 1);
    defer nav::destroy_heightfield(&field);
    add_column(&field, 0, 1);
    add_column(&field, 1, 1 + COMPACT_CLIMB);
    add_column(&field, 2, 2 + 2 * COMPACT_CLIMB);
    char[COMPACT_ARENA_BYTES] buffer;
    ArenaAllocator arena;
    arena.init(buffer[..]);

    CompactHeightfield compact = nav::build_compact_heightfield(&arena, &field, COMPACT_HEIGHT, COMPACT_CLIMB)!!;

    uint east = nav::dir_for_offset(1, 0);
    uint west = nav::dir_for_offset(-1, 0);
    foreach (x, cell : compact.cells) {
        assert(cell.count == 1);
        assert(cell.index == x);
    }
    assert(compact.spans[0].y == 1 && compact.spans[1].y == 1 + COMPACT_CLIMB && compact.spans[2].y == 2 + 2 * COMPACT_CLIMB);
    assert(compact.spans[0].connection(east) == 0);
    assert(compact.spans[1].connection(west) == 0);
    assert(compact.spans[1].connection(east) == nav::NOT_CONNECTED);
    assert(compact.spans[2].connection(west) == nav::NOT_CONNECTED);
    assert(compact.spans[0].connection(west) == nav::NOT_CONNECTED, "the field edge links nothing");
}

fn void test_compact_clearance_limits_links() @test {
    Heightfield field = heightfield(width: 2, height: 1, layers: 64, cell_size: 1, cell_height: 1);
    defer nav::destroy_heightfield(&field);
    add_column(&field, 0, 1);
    add_column(&field, 1, 1);
    field.add_span(
        x:               1,
        z:               0,
        min:             1 + COMPACT_HEIGHT - 1,
        max:             10,
        area:            nav::NULL_AREA,
        merge_threshold: 0,
    )!!;
    char[COMPACT_ARENA_BYTES] buffer;
    ArenaAllocator arena;
    arena.init(buffer[..]);

    CompactHeightfield compact = nav::build_compact_heightfield(&arena, &field, COMPACT_HEIGHT, COMPACT_CLIMB)!!;

    assert(compact.spans[0].connection(nav::dir_for_offset(1, 0)) == nav::NOT_CONNECTED);
    assert(compact.spans[1].connection(nav::dir_for_offset(-1, 0)) == nav::NOT_CONNECTED);
}

fn void test_compact_faults_when_the_arena_is_too_small() @test {
    Heightfield field = heightfield(width: 20, height: 20, layers: 16, cell_size: 1, cell_height: 1);
    defer nav::destroy_heightfield(&field);
    add_column(&field, 0, 1);
    char[64] buffer;
    ArenaAllocator arena;
    arena.init(buffer[..]);

    if (catch excuse = nav::build_compact_heightfield(&arena, &field, COMPACT_HEIGHT, COMPACT_CLIMB)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a 64-byte arena cannot hold 400 cells");
    }
}

fn void test_direction_offsets_round_trip() @test {
    for (uint direction = 0; direction < 4; direction++) {
        assert(nav::dir_for_offset(nav::dir_offset_x(direction), nav::dir_offset_z(direction)) == direction);
    }
}
