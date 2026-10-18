module c3d_physics_breakable_test;

import std::math;
import c3d;
import c3d::maths;
import c3d::geometry;
import c3d::physics;
import c3d::scene;

const uint  GRAPH_SIDE @private = 6;
const uint  GRAPH_PIECES @private = GRAPH_SIDE * GRAPH_SIDE;
const float GRAPH_PITCH @private = 1.05f; // face gaps of 5 cm and diagonal gaps of 7 cm
const float GRAPH_HULL_OFFSET @private = 0.6f; // two cubes per piece, 20 cm apart in z
const float GRAPH_CONTACT_DISTANCE @private = 0.1f;
const uint  GRAPH_WELDS @private = 2 * GRAPH_SIDE * (GRAPH_SIDE - 1) + 2 * (GRAPH_SIDE - 1) * (GRAPH_SIDE - 1);

struct ForkCount @private {
    uint forks;
    uint ranges;
}

fn void run_one_pair_per_range_in_reverse(
    void* context,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) @private {
    ForkCount* counts = context;
    counts.forks++;

    for (uint index = count; index > 0; index--) {
        counts.ranges++;
        range(data, index - 1, 1);
    }
}

fn Node* add_tied_grid(Fixture* fixture, GeometryId[] hulls) @private {
    Node* root = fixture.scene.add_node(null, "grid")!!;
    BreakablePieceDesc[GRAPH_PIECES] pieces;
    for (uint row = 0; row < GRAPH_SIDE; row++) {
        for (uint column = 0; column < GRAPH_SIDE; column++) {
            Node* piece = fixture.scene.add_node(root, "piece")!!;
            piece.local.position = { (float)column * GRAPH_PITCH, (float)row * GRAPH_PITCH, 0 };
            pieces[row * GRAPH_SIDE + column] = { .node = piece.id, .hulls = hulls };
        }
    }
    fixture.scene.update_world();

    BreakableDesc desc = physics::default_breakable_desc();
    desc.contact_distance = GRAPH_CONTACT_DISTANCE;
    fixture.physics.add_breakable_pieces(root, &pieces, desc)!!;
    return root;
}

fn bool same_bits(Vec3 first, Vec3 second) @private {
    for (usz axis = 0; axis < 3; axis++) {
        if (bitcast(first[axis], uint) != bitcast(second[axis], uint)) return false;
    }
    return true;
}

fn bool same_frame_bits(maths::Transform first, maths::Transform second) @private {
    for (usz lane = 0; lane < 4; lane++) {
        if (bitcast(first.rotation.v[lane], uint) != bitcast(second.rotation.v[lane], uint)) return false;
    }
    return same_bits(first.position, second.position) && same_bits(first.scale, second.scale);
}

fn bool same_weld_bits(BreakableWeldView first, BreakableWeldView second) @private {
    return first.piece_a == second.piece_a
        && first.piece_b == second.piece_b
        && same_bits(first.anchor, second.anchor)
        && same_frame_bits(first.frame_a, second.frame_a)
        && same_frame_bits(first.frame_b, second.frame_b)
        && same_bits(first.moment_axis, second.moment_axis);
}

fn void test_parallel_hull_graph_equals_serial() @test {
    Fixture serial;
    setup(&serial, weightless_desc());
    defer teardown(&serial);
    GeometryId[2] serial_hulls = {
        offset_cube(&serial, { 0, 0, -GRAPH_HULL_OFFSET }),
        offset_cube(&serial, { 0, 0, GRAPH_HULL_OFFSET }),
    };
    Node* serial_root = add_tied_grid(&serial, &serial_hulls);

    Fixture parallel;
    setup(&parallel, weightless_desc());
    defer teardown(&parallel);
    ForkCount counts;
    parallel.physics.set_parallel({ .run = &run_one_pair_per_range_in_reverse, .context = &counts });
    GeometryId[2] parallel_hulls = {
        offset_cube(&parallel, { 0, 0, -GRAPH_HULL_OFFSET }),
        offset_cube(&parallel, { 0, 0, GRAPH_HULL_OFFSET }),
    };
    Node* parallel_root = add_tied_grid(&parallel, &parallel_hulls);

    BreakableState* expected = serial.scene.get(serial_root, Breakable).state;
    BreakableState* actual = parallel.scene.get(parallel_root, Breakable).state;
    assert(expected.welds.len == GRAPH_WELDS && actual.welds.len == GRAPH_WELDS);
    assert(counts.forks == 1 && counts.ranges == GRAPH_PIECES * (GRAPH_PIECES - 1) / 2);
    foreach (index, weld : expected.welds) {
        assert(same_weld_bits(expected.weld_view((uint)index), actual.weld_view((uint)index)));
    }
}
