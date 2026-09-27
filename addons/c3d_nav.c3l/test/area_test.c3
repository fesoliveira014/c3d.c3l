module c3d_nav_test;

import std::core::mem::allocator;
import std::math;
import c3d;
import c3d::maths;
import c3d::nav;

const usz  AREA_ARENA_BYTES @private = 64 * 1024;
const uint AREA_SQUARE @private = 20;
const char MARK_AREA @private = 7;

struct AreaFixture @private {
    Heightfield                field;
    char[AREA_ARENA_BYTES]     buffer;
    ArenaAllocator             arena;
    CompactHeightfield         compact;
}

fn void flat_square(AreaFixture* fixture, uint size = AREA_SQUARE) @private {
    fixture.field = heightfield(width: size, height: size, layers: 16, cell_size: 1, cell_height: 1);
    for (uint z = 0; z < size; z++) {
        for (uint x = 0; x < size; x++) {
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
        }
    }
    fixture.arena.init(fixture.buffer[..]);
    fixture.compact = nav::build_compact_heightfield(&fixture.arena, &fixture.field, 3, 1)!!;
}

fn void destroy_square(AreaFixture* fixture) @private => nav::destroy_heightfield(&fixture.field);

fn char area_at(CompactHeightfield* compact, uint x, uint z) @private {
    return compact.areas[compact.cells[x + z * compact.width].index];
}

fn uint ring(uint x, uint z, uint size) @private {
    return math::min(math::min(x, z), math::min(size - 1 - x, size - 1 - z));
}

fn bool inside_triangle(Vec3[] triangle, float x, float z) @private {
    int sign;
    for (usz edge = 0; edge < 3; edge++) {
        Vec3 from = triangle[edge];
        Vec3 to = triangle[(edge + 1) % 3];
        float side = (to.x - from.x) * (z - from.z) - (to.z - from.z) * (x - from.x);
        int current = side > 0 ? 1 : -1;
        if (sign != 0 && current != sign) return false;
        sign = current;
    }
    return true;
}

fn float line_distance(Vec3 from, Vec3 to, Vec3 point) @private {
    Vec3 direction = (Vec3){ to.x - from.x, 0, to.z - from.z }.normalize();
    Vec3 offset = { point.x - from.x, 0, point.z - from.z };
    return math::abs(offset.x * direction.z - offset.z * direction.x);
}

fn void test_erosion_removes_rings_by_radius() @test {
    foreach (radius : (uint[2]){ 1, 2 }) {
        AreaFixture* fixture = mem::new(AreaFixture);
        defer free(fixture);
        flat_square(fixture);
        defer destroy_square(fixture);

        fixture.compact.erode_walkable_area(&fixture.arena, radius)!!;

        for (uint z = 0; z < AREA_SQUARE; z++) {
            for (uint x = 0; x < AREA_SQUARE; x++) {
                bool eroded = ring(x, z, AREA_SQUARE) < radius;
                assert(area_at(&fixture.compact, x, z) == (eroded ? nav::NULL_AREA : nav::WALKABLE_AREA));
            }
        }
    }
}

fn void test_erosion_faults_when_scratch_is_too_small() @test {
    AreaFixture* fixture = mem::new(AreaFixture);
    defer free(fixture);
    flat_square(fixture);
    defer destroy_square(fixture);
    char[16] small;
    ArenaAllocator scratch;
    scratch.init(small[..]);

    if (catch excuse = fixture.compact.erode_walkable_area(&scratch, 1)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "sixteen bytes cannot hold a distance per span");
    }
    foreach (area : fixture.compact.areas) assert(area == nav::WALKABLE_AREA);
}

fn void test_median_filter_removes_an_isolated_cell() @test {
    AreaFixture* fixture = mem::new(AreaFixture);
    defer free(fixture);
    flat_square(fixture);
    defer destroy_square(fixture);
    CompactHeightfield* compact = &fixture.compact;
    compact.areas[compact.cells[3 + 3 * AREA_SQUARE].index] = MARK_AREA;
    for (uint z = 10; z < 13; z++) {
        for (uint x = 10; x < 13; x++) compact.areas[compact.cells[x + z * AREA_SQUARE].index] = MARK_AREA;
    }
    compact.areas[compact.cells[16 + 16 * AREA_SQUARE].index] = nav::NULL_AREA;

    compact.median_filter_walkable_area(&fixture.arena)!!;

    assert(area_at(compact, 3, 3) == nav::WALKABLE_AREA);
    assert(area_at(compact, 11, 11) == MARK_AREA);
    assert(area_at(compact, 16, 16) == nav::NULL_AREA);
}

fn void test_box_marks_exactly_its_cells() @test {
    AreaFixture* fixture = mem::new(AreaFixture);
    defer free(fixture);
    flat_square(fixture);
    defer destroy_square(fixture);

    fixture.compact.mark_box_area({ .min = { 5, 0, 5 }, .max = { 9.99f, 2, 9.99f } }, MARK_AREA);
    fixture.compact.mark_box_area({ .min = { 0, 3, 0 }, .max = { 20, 5, 20 } }, 3);

    for (uint z = 0; z < AREA_SQUARE; z++) {
        for (uint x = 0; x < AREA_SQUARE; x++) {
            bool inside = x >= 5 && x <= 9 && z >= 5 && z <= 9;
            assert(area_at(&fixture.compact, x, z) == (inside ? MARK_AREA : nav::WALKABLE_AREA));
        }
    }
}

fn void test_convex_polygon_marks_its_projection() @test {
    Vec3[3] forward = { { 2, 0, 2 }, { 12.25f, 0, 2 }, { 2, 0, 12.25f } };
    Vec3[3] backward = { { 2, 0, 12.25f }, { 12.25f, 0, 2 }, { 2, 0, 2 } };
    foreach (triangle : (Vec3[3][2]){ forward, backward }) {
        AreaFixture* fixture = mem::new(AreaFixture);
        defer free(fixture);
        flat_square(fixture);
        defer destroy_square(fixture);

        fixture.compact.mark_convex_poly_area(triangle[..], 0, 2, 5);
        fixture.compact.mark_convex_poly_area(triangle[..], 3, 5, 9);

        for (uint z = 0; z < AREA_SQUARE; z++) {
            for (uint x = 0; x < AREA_SQUARE; x++) {
                bool inside = inside_triangle(triangle[..], x + 0.5f, z + 0.5f);
                assert(area_at(&fixture.compact, x, z) == (inside ? 5 : nav::WALKABLE_AREA));
            }
        }
    }
}

fn void test_cylinder_marks_a_disc() @test {
    AreaFixture* fixture = mem::new(AreaFixture);
    defer free(fixture);
    flat_square(fixture);
    defer destroy_square(fixture);

    fixture.compact.mark_cylinder_area({ 10, 0, 10 }, 3, 2, MARK_AREA);

    for (uint z = 0; z < AREA_SQUARE; z++) {
        for (uint x = 0; x < AREA_SQUARE; x++) {
            float delta_x = x + 0.5f - 10;
            float delta_z = z + 0.5f - 10;
            bool inside = delta_x * delta_x + delta_z * delta_z < 9;
            assert(area_at(&fixture.compact, x, z) == (inside ? MARK_AREA : nav::WALKABLE_AREA));
        }
    }
    assert(area_at(&fixture.compact, 7, 7) == nav::WALKABLE_AREA, "a corner of the disc's bounding square");
    assert(area_at(&fixture.compact, 13, 13) == nav::WALKABLE_AREA, "a corner of the disc's bounding square");
}

fn void test_mark_skips_null_area_spans() @test {
    AreaFixture* fixture = mem::new(AreaFixture);
    defer free(fixture);
    flat_square(fixture);
    defer destroy_square(fixture);
    fixture.compact.erode_walkable_area(&fixture.arena, 1)!!;

    fixture.compact.mark_box_area({ .min = { 0, 0, 0 }, .max = { 20, 2, 20 } }, MARK_AREA);

    for (uint z = 0; z < AREA_SQUARE; z++) {
        for (uint x = 0; x < AREA_SQUARE; x++) {
            assert(area_at(&fixture.compact, x, z) == (ring(x, z, AREA_SQUARE) == 0 ? nav::NULL_AREA : MARK_AREA));
        }
    }
}

fn void test_offset_poly_bevels_square_corners() @test {
    Vec3[4] square = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 1 }, { 0, 0, 1 } };
    Vec3[8] grown;

    usz count = nav::offset_poly(square[..], 0.5f, grown[..]);

    assert(count == 8);
    for (usz corner = 0; corner < 4; corner++) {
        Vec3 previous = square[(corner + 3) % 4];
        Vec3 vertex = square[corner];
        Vec3 next = square[(corner + 1) % 4];
        assert(math::abs(line_distance(previous, vertex, grown[corner * 2]) - 0.5f) < 1e-5);
        assert(math::abs(line_distance(vertex, next, grown[corner * 2 + 1]) - 0.5f) < 1e-5);
    }
    foreach (vertex : grown) {
        bool inside = vertex.x > 0 && vertex.x < 1 && vertex.z > 0 && vertex.z < 1;
        assert(!inside, "a clockwise square grows");
    }

    Vec3[4] reversed = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 0 } };
    Vec3[8] shrunk;
    assert(nav::offset_poly(reversed[..], 0.5f, shrunk[..]) == 4);
    foreach (vertex : shrunk[:4]) {
        assert(vertex.x >= 0 && vertex.x <= 1 && vertex.z >= 0 && vertex.z <= 1, "the opposite winding shrinks");
    }

    Vec3[7] too_small;
    assert(nav::offset_poly(square[..], 0.5f, too_small[..]) == 0);
}
