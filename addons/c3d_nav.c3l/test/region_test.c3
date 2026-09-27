module c3d_nav_test;

import std::core::mem::allocator;
import c3d;
import c3d::nav;

const uint  U_BASE_ROWS @private = 4;
const uint  U_PRONG_WIDTH @private = 3;
const char  STRIP_AREA @private = 5;
const uint  BORDER_RING @private = 2;
const uint  ISLAND_MIN_AREA @private = 8;
const uint  ISLAND_FIRST_COLUMN @private = 11;
const uint  U_MERGE_AREA @private = 100;
const uint  ALTERNATING_WIDTH @private = 8;
const uint  ALTERNATING_DEPTH @private = 4;
const uint  LOW_FLOOR @private = 1;
const uint  HIGH_FLOOR @private = 3; // two voxels above LOW_FLOOR, past the fixture's climb of one
const usz   TINY_SCRATCH_BYTES @private = 64;

const String[] U_FLOOR @private = {
    "##########",
    "##########",
    "##########",
    "##########",
    "###....###",
    "###....###",
    "###....###",
    "###....###",
    "###....###",
    "###....###",
};

const String[] AREA_STRIP_FLOOR @private = {
    "#####55#####",
    "#####55#####",
    "#####55#####",
    "#####55#####",
    "#####55#####",
    "#####55#####",
};

const String[] ISLAND_FLOOR @private = {
    "##########.##",
    "##########.##",
    "##########...",
    "##########...",
    "##########...",
    "##########...",
    "##########...",
    "##########...",
    "##########...",
    "##########...",
};

fn void build_regions(
    CompactFixture* fixture,
    uint border_size = 0,
    uint min_region_area = 0,
    uint merge_region_area = 0,
) @private {
    fixture.compact.build_regions_monotone(
        scratch:           &fixture.arena,
        border_size:       border_size,
        min_region_area:   min_region_area,
        merge_region_area: merge_region_area,
    )!!;
}

fn ushort region_at(CompactFixture* fixture, uint x, uint z) @private => first_span(&fixture.compact, x, z).region;

fn usz distinct_regions(CompactHeightfield* compact) @private {
    usz count;
    for (uint region = 1; region <= compact.max_regions; region++) {
        foreach (span : compact.spans) {
            if (span.region != region) continue;
            count++;
            break;
        }
    }
    return count;
}

fn void test_rectangle_is_one_region() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture);

    foreach (span : fixture.compact.spans) assert(span.region == 1);
    assert(fixture.compact.max_regions == 2, "the unused id after the last region is counted, as upstream counts it");
}

fn void test_l_shaped_floor_is_one_region() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, L_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture);

    foreach (span : fixture.compact.spans) assert(span.region == 1);
}

fn void test_split_rows_start_new_regions() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, U_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture);

    ushort base = region_at(fixture, 0, 0);
    ushort left_prong = region_at(fixture, 0, U_FLOOR.len - 1);
    ushort right_prong = region_at(fixture, U_FLOOR[0].len - 1, U_FLOOR.len - 1);
    assert(base != 0 && left_prong != 0 && right_prong != 0);
    assert(base != left_prong && base != right_prong && left_prong != right_prong);
    assert(fixture.compact.max_regions == 4, "three regions and the unused id after them");
    foreach (z, row : U_FLOOR) {
        foreach (x, cell : row) {
            if (cell == '.') continue;
            ushort expected = z < U_BASE_ROWS ? base : x < U_PRONG_WIDTH ? left_prong : right_prong;
            assert(region_at(fixture, (uint)x, (uint)z) == expected);
        }
    }
}

fn void test_area_change_starts_a_new_region() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, AREA_STRIP_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture);

    assert(distinct_regions(&fixture.compact) == 3);
    ushort strip = region_at(fixture, 5, 0);
    foreach (index, span : fixture.compact.spans) {
        assert((span.region == strip) == (fixture.compact.areas[index] == STRIP_AREA));
    }
}

fn void test_border_spans_get_the_border_region() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, SQUARE_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture, border_size: BORDER_RING);

    uint size = SQUARE_FLOOR.len;
    assert(fixture.compact.border_size == BORDER_RING);
    for (uint z = 0; z < size; z++) {
        for (uint x = 0; x < size; x++) {
            bool in_ring = x < BORDER_RING || z < BORDER_RING || x >= size - BORDER_RING || z >= size - BORDER_RING;
            assert(((region_at(fixture, x, z) & nav::BORDER_REGION) != 0) == in_ring);
        }
    }
}

fn void test_small_islands_are_removed() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, ISLAND_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture, min_region_area: ISLAND_MIN_AREA);

    foreach (z, row : ISLAND_FLOOR) {
        foreach (x, cell : row) {
            if (cell == '.') continue;
            bool island = x >= ISLAND_FIRST_COLUMN;
            assert((region_at(fixture, (uint)x, (uint)z) == 0) == island);
        }
    }
}

fn void test_small_regions_merge() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, U_FLOOR);
    defer destroy_compact_fixture(fixture);

    build_regions(fixture, merge_region_area: U_MERGE_AREA);

    ushort merged = region_at(fixture, 0, 0);
    assert(merged != 0);
    foreach (span : fixture.compact.spans) assert(span.region == merged);
}

fn void test_disconnected_row_does_not_overrun() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    fixture.field = heightfield(
        width:       ALTERNATING_WIDTH,
        height:      ALTERNATING_DEPTH,
        layers:      COMPACT_FIXTURE_LAYERS,
        cell_size:   1,
        cell_height: 1,
    );
    defer destroy_compact_fixture(fixture);
    for (uint z = 0; z < ALTERNATING_DEPTH; z++) {
        for (uint x = 0; x < ALTERNATING_WIDTH; x++) {
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             x % 2 == 0 ? LOW_FLOOR : HIGH_FLOOR,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
        }
    }
    compact_fixture_field(fixture);

    build_regions(fixture);

    for (uint z = 0; z < ALTERNATING_DEPTH; z++) {
        for (uint x = 0; x < ALTERNATING_WIDTH; x++) assert(region_at(fixture, x, z) == x + 1);
    }
}

fn void test_regions_fault_when_scratch_is_too_small() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    compact_from(fixture, RECTANGLE_FLOOR);
    defer destroy_compact_fixture(fixture);
    char[TINY_SCRATCH_BYTES] small;
    ArenaAllocator scratch;
    scratch.init(small[..]);

    if (catch excuse = fixture.compact.build_regions_monotone(
        scratch:           &scratch,
        border_size:       0,
        min_region_area:   0,
        merge_region_area: 0,
    )) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "sixty-four bytes cannot hold a region per span");
    }
    foreach (span : fixture.compact.spans) assert(span.region == 0);
}
