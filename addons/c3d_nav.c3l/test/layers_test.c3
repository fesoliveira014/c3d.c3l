module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const uint  LAYER_FLOOR_SIDE @private = 12;
const uint  BRIDGE_MIN_X @private = 3;
const uint  BRIDGE_MAX_X @private = 8;
const uint  BRIDGE_MIN_Z @private = 5;
const uint  BRIDGE_MAX_Z @private = 6;
const uint  BRIDGE_BOTTOM @private = 9; // voxels; eight above the floor, clear of the three-voxel agent

// A 12 by 12 floor one voxel thick; with a bridge, a walkable deck crosses it at BRIDGE_BOTTOM.
fn void layer_floor(CompactFixture* fixture, bool bridge) @private {
    fixture.field = heightfield(
        width:       LAYER_FLOOR_SIDE,
        height:      LAYER_FLOOR_SIDE,
        layers:      COMPACT_FIXTURE_LAYERS,
        cell_size:   1,
        cell_height: 1,
    );
    for (uint z = 0; z < LAYER_FLOOR_SIDE; z++) {
        for (uint x = 0; x < LAYER_FLOOR_SIDE; x++) {
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             0,
                max:             1,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
            if (!bridge || x < BRIDGE_MIN_X || x > BRIDGE_MAX_X || z < BRIDGE_MIN_Z || z > BRIDGE_MAX_Z) continue;
            fixture.field.add_span(
                x:               x,
                z:               z,
                min:             BRIDGE_BOTTOM,
                max:             BRIDGE_BOTTOM + 1,
                area:            nav::WALKABLE_AREA,
                merge_threshold: 0,
            )!!;
        }
    }
    compact_fixture_field(fixture);
}

fn HeightfieldLayer[] fixture_layers(CompactFixture* fixture) @private {
    return nav::build_heightfield_layers(
        allocator:       &fixture.arena,
        scratch:         &fixture.arena,
        compact:         &fixture.compact,
        border_size:     0,
        walkable_height: FIXTURE_WALKABLE_HEIGHT,
    )!!;
}

fn void test_layers_split_an_overpass_into_two() @test {
    CompactFixture* fixture = mem::new(CompactFixture);
    defer free(fixture);
    layer_floor(fixture, bridge: false);
    defer destroy_compact_fixture(fixture);
    assert(fixture_layers(fixture).len == 1, "a flat floor is one layer");

    destroy_compact_fixture(fixture);
    layer_floor(fixture, bridge: true);
    HeightfieldLayer[] layers = fixture_layers(fixture);

    assert(layers.len == 2);
    HeightfieldLayer* low = layers[0].hmin < layers[1].hmin ? &layers[0] : &layers[1];
    HeightfieldLayer* high = low == &layers[0] ? &layers[1] : &layers[0];
    assert(low.hmax < high.hmin, "the height ranges do not overlap");
    for (uint z = BRIDGE_MIN_Z; z <= BRIDGE_MAX_Z; z++) {
        for (uint x = BRIDGE_MIN_X; x <= BRIDGE_MAX_X; x++) {
            usz cell = (usz)(x + z * low.width);
            assert(low.heights[cell] != 0xff && high.heights[cell] != 0xff, "cell %d %d is in both layers", x, z);
            assert(low.hmin + low.heights[cell] < high.hmin + high.heights[cell]);
        }
    }
    assert(high.min_x == BRIDGE_MIN_X && high.max_x == BRIDGE_MAX_X);
    assert(high.min_z == BRIDGE_MIN_Z && high.max_z == BRIDGE_MAX_Z);
}
