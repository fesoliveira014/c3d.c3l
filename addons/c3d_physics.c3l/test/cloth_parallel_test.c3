module c3d_physics_cloth_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

const uint PARALLEL_UPDATES @private = 60;
const uint PARALLEL_ALLOCATION_UPDATES @private = 6;
const uint PARALLEL_CUT_UPDATE @private = 10;
const uint PARALLEL_CUT_PATH @private = 20;
const float PARALLEL_BALL_RADIUS @private = 0.35f;
const Vec3 PARALLEL_BALL_POSITION @private = { 0.5f, -0.5f, 0.1f };
const Vec3 PARALLEL_WIND @private = { 0, 0, 4 };

struct ReverseOrder @private {
    uint runs;
}

struct ParallelScene @private {
    Node*    draped;
    Node*    torn;
    CrowdRig crowd;
}

fn void run_in_reverse(
    void* context,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) @private {
    ReverseOrder* order = context;
    order.runs++;

    uint ranges = (count + batch - 1) / batch;
    for (uint range_index = ranges; range_index > 0; range_index--) {
        uint first = (range_index - 1) * batch;
        range(data, first, math::min(batch, count - first));
    }
}

fn ParallelScene build_parallel_scene(Fixture* fixture) @private {
    ColliderDesc ball = sphere(PARALLEL_BALL_RADIUS);
    Node* body = add_body_node(fixture, (&ball)[:1], PARALLEL_BALL_POSITION);

    Node* draped = add_cloth_node(fixture, add_grid(fixture, GRID_CELLS));
    fixture.scene.add(draped, (Wind){ .velocity = PARALLEL_WIND });
    Entity[1] colliders = { body.id };
    ClothDesc draped_desc = pinned_desc(top_row(GRID_CELLS));
    draped_desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, draped, draped_desc)!!;

    Node* torn = add_cloth_node(fixture, add_grid(fixture, 2, 2));
    torn.local.position = { 3, 0, 0 };
    fixture.scene.update_world();
    uint[2] cut_vertices = { 4, 7 };
    ClothCutPath[1] cuts = { { .id = PARALLEL_CUT_PATH, .vertices = cut_vertices[..] } };
    ClothDesc torn_desc = pinned_desc(top_row(2));
    torn_desc.cuts = cuts[..];
    fixture.scene.add_cloth(&fixture.assets, torn, torn_desc)!!;

    CrowdRig crowd = add_cloth_crowd(fixture);
    return { .draped = draped, .torn = torn, .crowd = crowd };
}

macro bool same_bits(first, second) @local {
    if (first.len != second.len) return false;

    foreach (index, value : first) {
        for (usz axis = 0; axis < value.len; axis++) {
            if (bitcast(value[axis], uint) != bitcast(second[index][axis], uint)) return false;
        }
    }
    return true;
}

fn bool same_cloth(
    Fixture* first_fixture,
    ClothState* first,
    Fixture* second_fixture,
    ClothState* second,
) @private {
    Geometry* first_geometry = &first_fixture.assets.geometry(first.geometry).data;
    Geometry* second_geometry = &second_fixture.assets.geometry(second.geometry).data;
    return same_bits(first.positions, second.positions)
        && same_bits(first.velocities, second.velocities)
        && same_bits(first_geometry.positions, second_geometry.positions)
        && same_bits(first_geometry.normals, second_geometry.normals)
        && same_bits(first_geometry.colors, second_geometry.colors);
}

fn bool same_scene(
    Fixture* first,
    ParallelScene* first_scene,
    Fixture* second,
    ParallelScene* second_scene,
) @private {
    if (!same_cloth(
        first_fixture:  first,
        first:          state_of(first, first_scene.draped),
        second_fixture: second,
        second:         state_of(second, second_scene.draped),
    )) {
        return false;
    }
    if (!same_cloth(
        first_fixture:  first,
        first:          state_of(first, first_scene.torn),
        second_fixture: second,
        second:         state_of(second, second_scene.torn),
    )) {
        return false;
    }

    CrowdClothPart* first_part = first.scene.get(first_scene.crowd.node, CrowdCloth).find_part(0)!!;
    CrowdClothPart* second_part = second.scene.get(second_scene.crowd.node, CrowdCloth).find_part(0)!!;
    foreach (slot, state : first_part.states) {
        if (!same_cloth(
            first_fixture:  first,
            first:          state,
            second_fixture: second,
            second:         second_part.states[slot],
        )) {
            return false;
        }
    }

    return true;
}

fn void test_cloth_staging_order_does_not_change_results() @test {
    Fixture serial;
    setup(&serial);
    defer teardown(&serial);
    ParallelScene serial_scene = build_parallel_scene(&serial);

    Fixture reversed;
    setup(&reversed);
    defer teardown(&reversed);
    ParallelScene reversed_scene = build_parallel_scene(&reversed);
    ReverseOrder order;
    reversed.physics.set_parallel({ .run = &run_in_reverse, .context = &order });

    uint contacts;
    for (uint update = 0; update < PARALLEL_UPDATES; update++) {
        if (update == PARALLEL_CUT_UPDATE) {
            serial.scene.get(serial_scene.torn, Cloth).request_cut(PARALLEL_CUT_PATH)!!;
            reversed.scene.get(reversed_scene.torn, Cloth).request_cut(PARALLEL_CUT_PATH)!!;
        }

        float dt = update % 3 == 0 ? 0 : (update % 3 == 1 ? physics::DEFAULT_FIXED_DT : 2 * physics::DEFAULT_FIXED_DT);
        step(&serial, dt);
        step(&reversed, dt);
        contacts += serial.physics.cloth_stats.contacts;
        assert(serial.physics.cloth_stats.failed == 0 && reversed.physics.cloth_stats.failed == 0);
        assert(same_scene(
            first:        &serial,
            first_scene:  &serial_scene,
            second:       &reversed,
            second_scene: &reversed_scene,
        ));
    }

    assert(order.runs == PARALLEL_UPDATES);
    assert(contacts > 0);
    assert(serial.scene.get(serial_scene.torn, Cloth).cut_result(PARALLEL_CUT_PATH)!!.is_cut);
}

fn void test_cloth_is_refused_on_a_node_that_carries_an_output_marker() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* marked = add_cloth_node(&fixture, add_grid(&fixture, 1));
    fixture.scene.add(marked, (ClothOutput){ .owner = marked.id, .crowd = true });
    assert(rejected_atomically(&fixture, marked, cloth::default_cloth_desc()) == c3d::INVALID_ARGUMENT);

    Node* attached = add_cloth_node(&fixture, add_grid(&fixture, 1));
    fixture.scene.attach_cloth(&fixture.assets, attached, cloth::default_cloth_desc())!!;
    fixture.scene.add(attached, (ClothOutput){ .owner = attached.id });
    assert(@catch(cloth::prepare(&fixture.scene, &fixture.assets, attached)) == c3d::INVALID_ARGUMENT);
    assert(!fixture.scene.get(attached, Cloth).is_prepared());
}
