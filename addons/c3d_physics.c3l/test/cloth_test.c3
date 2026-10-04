module c3d_physics_cloth_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

const float POSITION_TOLERANCE @private = 1e-5f;
const float CONTACT_TOLERANCE @private = 1e-4f;
const float MAX_SETTLED_STRETCH @private = 0.05f;
const uint SETTLE_STEPS @private = 600;
const uint GRID_CELLS @private = 8;
const uint FIXTURE_GEOMETRIES @private = 16;
const float PROBE_THICKNESS @private = 0.02f;
const float PROBE_REACH @private = 4; // metres from the free vertex to each pinned corner, outside every probed shape
const uint CONTACT_UPDATES @private = 120;
const float BONE_RADIUS @private = 0.1f;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    MaterialId   material;
    bool         physics_alive;
}

fn PhysicsDesc weightless() @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    return desc;
}

fn void setup(
    Fixture* fixture,
    PhysicsDesc desc = physics::default_physics_desc(),
    Allocator allocator = mem,
    uint max_geometries = FIXTURE_GEOMETRIES,
) @private {
    AssetStoreDesc store = asset::default_asset_store_desc();
    store.max_geometries = max_geometries;
    fixture.assets = asset::create_asset_store(allocator, store);
    fixture.scene = scene::create_scene(allocator, { .max_nodes = 64 });
    physics::register_physics(&fixture.scene)!!;
    desc.tuning.interpolate = false;
    fixture.physics = physics::create_physics_world(
        allocator: allocator,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
    fixture.physics_alive = true;
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
}

fn void teardown(Fixture* fixture) @private {
    if (fixture.physics_alive) physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Geometry hanging_grid(Allocator allocator, uint cells, float size = 1) @private {
    uint side = cells + 1;
    Geometry grid = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * cells * cells)),
    };
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            grid.positions[row * side + column] = { (float)column / cells * size, -(float)row / cells * size, 0 };
        }
    }
    usz next;
    for (uint row = 0; row < cells; row++) {
        for (uint column = 0; column < cells; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    return grid;
}

fn GeometryId add_grid(Fixture* fixture, uint cells, float size = 1) @private {
    GeometryId id;
    @pool() {
        Geometry grid = hanging_grid(tmem, cells, size);
        id = fixture.assets.add_geometry(&grid)!!;
    };
    return id;
}

fn GeometryId add_triangle(Fixture* fixture, Vec3 offset = {}, float size = 1) @private {
    GeometryId id;
    @pool() {
        Geometry triangle = {
            .positions = alloc::new_array(tmem, Vec3, 3),
            .indices   = alloc::new_array(tmem, uint, 3),
        };
        triangle.positions[..] = ((Vec3[3]){ offset, offset + (Vec3){ size, 0, 0 }, offset + (Vec3){ 0, 0, size } })[..];
        triangle.indices[..] = { 0, 2, 1 }[..];
        triangle.finalize();
        id = fixture.assets.add_geometry(&triangle)!!;
    };
    return id;
}

fn Node* add_cloth_node(Fixture* fixture, GeometryId geometry) @private {
    Node* node = fixture.scene.add_mesh(geometry, fixture.material)!!;
    fixture.scene.update_world();
    return node;
}

fn uint[] top_row(uint cells) @private {
    uint[] pins = alloc::new_array(tmem, uint, (sz)(cells + 1));
    foreach (index, &pin : pins) *pin = (uint)index;
    return pins;
}

fn ClothDesc pinned_desc(uint[] pins) @private {
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins;
    return desc;
}

fn ClothState* state_of(Fixture* fixture, Node* node) @private => fixture.scene.get(node, Cloth).state;

fn GeometryAsset* geometry_of(Fixture* fixture, Node* node) @private {
    return fixture.assets.geometry(fixture.scene.get(node, scene::Mesh).geometry);
}

fn Vec3 published_world(Fixture* fixture, Node* node, uint vertex) @private {
    return maths::transform_point(node.world, geometry_of(fixture, node).data.positions[vertex]);
}

fn void step(Fixture* fixture, float dt) @private {
    fixture.physics.update(dt);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
}

fn bool near(Vec3 first, Vec3 second, float tolerance = POSITION_TOLERANCE) @private => (first - second).length() <= tolerance;

fn bool finite(Vec3 value) @private => math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);

fn void test_cloth_constraints_and_source_isolation() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId source = add_grid(&fixture, 1);
    Node* first = add_cloth_node(&fixture, source);
    Node* second = add_cloth_node(&fixture, source);
    uint[2] pins = { 0, 1 };
    fixture.scene.add_cloth(&fixture.assets, first, pinned_desc(pins[..]))!!;
    fixture.scene.add_cloth(&fixture.assets, second, pinned_desc(pins[..]))!!;
    pins[0] = 3;

    ClothState* state = state_of(&fixture, first);
    assert(state.edges.len == 5 && state.bends.len == 1);
    ClothConstraint bend = state.bends[0];
    assert((bend.first == 0 && bend.second == 3) || (bend.first == 3 && bend.second == 0));
    assert(state.pins.len == 2 && state.pins[0] == 0 && state.pins[1] == 1);
    GeometryId first_copy = fixture.scene.get(first, scene::Mesh).geometry;
    GeometryId second_copy = fixture.scene.get(second, scene::Mesh).geometry;
    assert(!c3d::same_id(first_copy, source) && !c3d::same_id(second_copy, source) && !c3d::same_id(first_copy, second_copy));
    assert(state.rest.ptr != fixture.assets.geometry(source).data.positions.ptr);

    Vec3[4] source_positions;
    Vec3[4] second_positions;
    source_positions[..] = fixture.assets.geometry(source).data.positions[..];
    second_positions[..] = fixture.assets.geometry(second_copy).data.positions[..];
    fixture.physics.update(0);
    first.local.position = { 0.5f, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(fixture.assets.geometry(first_copy).data.positions[0] != source_positions[0]
      || fixture.assets.geometry(first_copy).data.positions[2] != source_positions[2]);
    foreach (index, position : source_positions) {
        assert(fixture.assets.geometry(source).data.positions[index] == position);
        assert(fixture.assets.geometry(second_copy).data.positions[index] == second_positions[index]);
    }
}

fn void check_rejected(Fixture* fixture, Node* node, ClothDesc desc, fault expected) @private {
    scene::Mesh* mesh = fixture.scene.get(node, scene::Mesh);
    GeometryId geometry = mesh ? mesh.geometry : (GeometryId){};
    bool motion = mesh ? mesh.vertex_motion : false;
    usz free_geometries = fixture.assets.geometries.free_count;
    usz cloths = fixture.scene.count(Cloth);
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, desc)) == expected);
    assert(fixture.assets.geometries.free_count == free_geometries && fixture.scene.count(Cloth) == cloths);
    if (mesh) assert(c3d::same_id(fixture.scene.get(node, scene::Mesh).geometry, geometry) && mesh.vertex_motion == motion);
}

fn void test_cloth_rejects_invalid_input_atomically() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ClothDesc desc = cloth::default_cloth_desc();

    Node* bare = fixture.scene.add_node(name: "bare")!!;
    check_rejected(&fixture, bare, desc, cloth::NO_MESH);

    Node* attached = add_cloth_node(&fixture, add_grid(&fixture, 1));
    fixture.scene.add_cloth(&fixture.assets, attached, desc)!!;
    check_rejected(&fixture, attached, desc, cloth::CLOTH_EXISTS);

    GeometryId stale_id = add_grid(&fixture, 1);
    Node* stale = add_cloth_node(&fixture, stale_id);
    fixture.assets.remove_geometry(stale_id);
    check_rejected(&fixture, stale, desc, c3d::INVALID_ID);

    GeometryId released_id = add_grid(&fixture, 1);
    Node* released = add_cloth_node(&fixture, released_id);
    fixture.assets.release_geometry_cpu(released_id);
    check_rejected(&fixture, released, desc, physics::SOURCE_UNAVAILABLE);

    GeometryId unindexed_id = add_grid(&fixture, 1);
    Node* unindexed = add_cloth_node(&fixture, unindexed_id);
    GeometryAsset* unindexed_record = fixture.assets.geometry(unindexed_id);
    uint[] kept_indices = unindexed_record.data.indices;
    unindexed_record.data.indices = {};
    check_rejected(&fixture, unindexed, desc, c3d::UNSUPPORTED);
    unindexed_record.data.indices = kept_indices;
    unindexed_record.data.topology = Topology.LINES;
    check_rejected(&fixture, unindexed, desc, c3d::UNSUPPORTED);
    unindexed_record.data.topology = Topology.TRIANGLES;

    GeometryId shared_id = add_grid(&fixture, 1);
    Node* skinned = add_cloth_node(&fixture, shared_id);
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 1);
    joints[0] = skinned;
    fixture.scene.add(skinned, (SkinBinding){ .joints = joints });
    check_rejected(&fixture, skinned, desc, c3d::UNSUPPORTED);

    Node* morphed = add_cloth_node(&fixture, shared_id);
    scene::Mesh* morphed_mesh = fixture.scene.get(morphed, scene::Mesh);
    morphed_mesh.morph_weights = alloc::new_array(fixture.scene.allocator, float, 1);
    check_rejected(&fixture, morphed, desc, c3d::UNSUPPORTED);

    Node* overridden = add_cloth_node(&fixture, shared_id);
    fixture.scene.get(overridden, scene::Mesh).has_bounds_override = true;
    check_rejected(&fixture, overridden, desc, c3d::UNSUPPORTED);

    GeometryId custom_id = add_grid(&fixture, 1);
    Node* custom = add_cloth_node(&fixture, custom_id);
    GeometryAsset* custom_record = fixture.assets.geometry(custom_id);
    char[4] custom_bytes;
    custom_record.data.custom_data = custom_bytes[..];
    check_rejected(&fixture, custom, desc, c3d::UNSUPPORTED);
    custom_record.data.custom_data = {};

    Node* plain = add_cloth_node(&fixture, shared_id);
    uint[1] bad_pin = { 4 };
    check_rejected(&fixture, plain, pinned_desc(bad_pin[..]), c3d::INVALID_ARGUMENT);
    ClothDesc[7] invalid;
    foreach (&entry : invalid) *entry = desc;
    invalid[0].substeps = 0;
    invalid[1].iterations = 0;
    invalid[2].stretch_stiffness = 1.5f;
    invalid[3].bend_stiffness = bitcast(0x7fc00000u, float);
    invalid[4].damping = -1;
    invalid[5].thickness = bitcast(0x7f800000u, float);
    invalid[6].gravity_scale = bitcast(0x7fc00000u, float);
    foreach (entry : invalid) check_rejected(&fixture, plain, entry, c3d::INVALID_ARGUMENT);

    GeometryId indexed_id = add_grid(&fixture, 1);
    Node* bad_index = add_cloth_node(&fixture, indexed_id);
    fixture.assets.geometry(indexed_id).data.indices[0] = 9;
    check_rejected(&fixture, bad_index, desc, c3d::INVALID_ARGUMENT);

    GeometryId degenerate_id = add_grid(&fixture, 1);
    Node* degenerate = add_cloth_node(&fixture, degenerate_id);
    GeometryAsset* degenerate_record = fixture.assets.geometry(degenerate_id);
    degenerate_record.data.positions[1] = degenerate_record.data.positions[0];
    check_rejected(&fixture, degenerate, desc, c3d::INVALID_ARGUMENT);

    GeometryId fan_id;
    @pool() {
        Geometry fan = {
            .positions = alloc::new_array(tmem, Vec3, 5),
            .indices   = alloc::new_array(tmem, uint, 9),
        };
        fan.positions[..] = { { 0, 0, 0 }, { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 } }[..];
        fan.indices[..] = { 0, 1, 2, 0, 1, 3, 0, 1, 4 }[..];
        fan.finalize();
        fan_id = fixture.assets.add_geometry(&fan)!!;
    };
    check_rejected(&fixture, add_cloth_node(&fixture, fan_id), desc, c3d::INVALID_ARGUMENT);

    while (fixture.assets.geometries.free_count) add_grid(&fixture, 1);
    check_rejected(&fixture, plain, desc, c3d::CAPACITY_EXCEEDED);
}

fn void test_cloth_pins_follow_final_pose_without_steps() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId source = add_grid(&fixture, 2);
    Node* node = add_cloth_node(&fixture, source);
    uint[3] pins = { 0, 1, 2 };
    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(pins[..]))!!;
    ClothState* state = state_of(&fixture, node);
    Vec3[9] solved;
    solved[..] = state.positions[..];
    Vec3[9] source_positions;
    source_positions[..] = fixture.assets.geometry(source).data.positions[..];

    fixture.physics.update(0);
    node.local.position = { 1, 2, 3 };
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f);
    fixture.scene.update_world();
    uint revision = geometry_of(&fixture, node).header.revision;
    fixture.physics.update_cloths();
    assert(geometry_of(&fixture, node).header.revision == revision + 1);
    foreach (pin : pins) assert(near(published_world(&fixture, node, pin), maths::transform_point(node.world, state.rest[pin])));
    for (uint vertex = 3; vertex < 9; vertex++) {
        assert(near(published_world(&fixture, node, vertex), solved[vertex]));
        assert(state.positions[vertex] == solved[vertex]);
    }
    foreach (index, position : source_positions) assert(fixture.assets.geometry(source).data.positions[index] == position);

    fixture.physics.update(0);
    fixture.physics.update_cloths();
    assert(geometry_of(&fixture, node).header.revision == revision + 1);
}

fn void test_cloth_final_pose_after_multiple_steps() @test {
    Fixture batched;
    setup(&batched);
    defer teardown(&batched);
    Fixture stepped;
    setup(&stepped);
    defer teardown(&stepped);
    uint[3] pins = { 0, 1, 2 };
    Node* batched_node = add_cloth_node(&batched, add_grid(&batched, 2));
    Node* stepped_node = add_cloth_node(&stepped, add_grid(&stepped, 2));
    batched.scene.add_cloth(&batched.assets, batched_node, pinned_desc(pins[..]))!!;
    stepped.scene.add_cloth(&stepped.assets, stepped_node, pinned_desc(pins[..]))!!;

    batched.physics.update(3.5f * physics::DEFAULT_FIXED_DT);
    assert(batched.physics.steps_last_update == 3);
    batched.scene.update_world();
    batched.physics.update_cloths();
    for (uint update = 0; update < 3; update++) step(&stepped, physics::DEFAULT_FIXED_DT);
    ClothState* batched_state = state_of(&batched, batched_node);
    ClothState* stepped_state = state_of(&stepped, stepped_node);
    foreach (index, position : batched_state.positions) assert(near(position, stepped_state.positions[index]));

    batched.physics.update(3 * physics::DEFAULT_FIXED_DT);
    assert(batched.physics.steps_last_update == 3);
    batched_node.local.position = { 0, 0.5f, 0 };
    batched_node.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.25f);
    batched.scene.update_world();
    batched.physics.update_cloths();
    foreach (pin : pins) {
        assert(near(published_world(&batched, batched_node, pin), maths::transform_point(batched_node.world, batched_state.rest[pin])));
        assert(near(batched_state.positions[pin], maths::transform_point(batched_node.world, batched_state.rest[pin])));
    }
}

fn void test_cloth_zero_step_publication_preserves_simulation() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, 2));
    uint[3] pins = { 0, 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.collide_ground = true;
    desc.ground_height = -0.6f;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    Vec3[9] positions;
    Vec3[9] velocities;
    Vec3[3] anchors;
    positions[..] = state.positions[..];
    velocities[..] = state.velocities[..];
    anchors[..] = state.pin_anchors[..];

    state.desc.ground_height = 10;
    for (uint move = 1; move <= 3; move++) {
        fixture.physics.update(0);
        node.local.position = { 0.1f * move, 0, 0 };
        fixture.scene.update_world();
        fixture.physics.update_cloths();
        foreach (index, position : positions) {
            assert(state.positions[index] == position && state.velocities[index] == velocities[index]);
        }
        foreach (slot, anchor : anchors) assert(state.pin_anchors[slot] == anchor);
        foreach (pin : pins) assert(near(published_world(&fixture, node, pin), maths::transform_point(node.world, state.rest[pin])));
        for (uint vertex = 3; vertex < 9; vertex++) assert(published_world(&fixture, node, vertex).y >= 10 - CONTACT_TOLERANCE);
    }
    state.desc.ground_height = -0.6f;

    step(&fixture, physics::DEFAULT_FIXED_DT);
    foreach (slot, pin : pins) {
        Vec3 target = maths::transform_point(node.world, state.rest[pin]);
        assert(near(state.pin_anchors[slot], target) && near(state.positions[pin], target));
        Vec3 expected_velocity = (target - anchors[slot]) / physics::DEFAULT_FIXED_DT;
        assert(near(state.velocities[pin], expected_velocity, 1e-3f));
    }
}

fn void test_cloth_gravity_and_rest_constraints() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* falling = add_cloth_node(&fixture, add_triangle(&fixture));
    ClothDesc loose = cloth::default_cloth_desc();
    loose.stretch_stiffness = 0;
    loose.bend_stiffness = 0;
    loose.damping = 0;
    fixture.scene.add_cloth(&fixture.assets, falling, loose)!!;
    ClothState* triangle = state_of(&fixture, falling);
    const uint FALL_STEPS = 10;
    for (uint update = 0; update < FALL_STEPS; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    float dt = physics::DEFAULT_FIXED_DT / (float)loose.substeps;
    uint substeps = FALL_STEPS * loose.substeps;
    float expected = fixture.physics.desc.tuning.gravity.y * dt * dt * (float)(substeps * (substeps + 1) / 2);
    assert(math::abs(triangle.positions[0].y - expected) < POSITION_TOLERANCE);

    Node* grid = add_cloth_node(&fixture, add_grid(&fixture, GRID_CELLS));
    fixture.scene.add_cloth(&fixture.assets, grid, pinned_desc(top_row(GRID_CELLS)))!!;
    ClothState* state = state_of(&fixture, grid);
    for (uint update = 0; update < SETTLE_STEPS; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    foreach (pin : state.pins) assert(state.positions[pin] == maths::transform_point(grid.world, state.rest[pin]));
    float worst;
    foreach (edge : state.edges) {
        float length = (state.positions[edge.second] - state.positions[edge.first]).length();
        worst = math::max(worst, length / edge.rest_length - 1);
    }
    foreach (position : state.positions) assert(finite(position));
    assert(worst <= MAX_SETTLED_STRETCH);
}

fn void test_cloth_wind_and_ground_projection() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* windy = add_cloth_node(&fixture, add_grid(&fixture, 4));
    Node* calm = add_cloth_node(&fixture, add_grid(&fixture, 4));
    calm.local.position = { 5, 0, 0 };
    fixture.scene.update_world();
    fixture.scene.add_cloth(&fixture.assets, windy, pinned_desc(top_row(4)))!!;
    fixture.scene.add_cloth(&fixture.assets, calm, pinned_desc(top_row(4)))!!;
    fixture.scene.add(windy, (Wind){ .velocity = { 0, 0, 10 }, .drag = 1 });
    fixture.scene.add(calm, (Wind){ .velocity = { 0, 0, 10 } });
    ClothState* windy_state = state_of(&fixture, windy);
    ClothState* calm_state = state_of(&fixture, calm);
    Vec3[25] calm_start;
    calm_start[..] = calm_state.positions[..];
    for (uint update = 0; update < 30; update++) step(&fixture, physics::DEFAULT_FIXED_DT);
    float displacement;
    foreach (position : windy_state.positions) displacement += position.z;
    assert(displacement > 0);
    foreach (index, position : calm_state.positions) assert(position == calm_start[index]);

    GeometryId below = add_triangle(&fixture, { 0, -1, 0 });
    Node* buried = add_cloth_node(&fixture, below);
    uint[1] pin = { 0 };
    ClothDesc grounded = pinned_desc(pin[..]);
    grounded.collide_ground = true;
    grounded.thickness = 0.02f;
    fixture.scene.add_cloth(&fixture.assets, buried, grounded)!!;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    ClothState* state = state_of(&fixture, buried);
    assert(state.positions[0] == (Vec3){ 0, -1, 0 });
    assert(state.positions[1].y >= grounded.thickness - CONTACT_TOLERANCE);
    assert(state.positions[2].y >= grounded.thickness - CONTACT_TOLERANCE);
}

fn void test_cloth_collapsed_constraints_remain_finite() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, 1));
    uint[2] pins = { 0, 1 };
    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(pins[..]))!!;
    ClothState* state = state_of(&fixture, node);
    state.positions[3] = state.positions[2];
    step(&fixture, physics::DEFAULT_FIXED_DT);
    foreach (position : state.positions) assert(finite(position));
    assert((state.positions[3] - state.positions[2]).length() > 0.1f);
    foreach (pin : pins) assert(state.positions[pin] == maths::transform_point(node.world, state.rest[pin]));
}

fn void test_cloth_publication_and_lifetime() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(&fixture, allocator: &tracker);
    GeometryId source = add_grid(&fixture, 2);
    Node* node = add_cloth_node(&fixture, source);
    uint[3] pins = { 0, 1, 2 };
    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(pins[..]))!!;
    GeometryId copy = fixture.scene.get(node, scene::Mesh).geometry;
    uint revision = fixture.assets.geometry(copy).header.revision;

    fixture.physics.update(3 * physics::DEFAULT_FIXED_DT);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(fixture.assets.geometry(copy).header.revision == revision + 1);
    fixture.physics.update(0);
    fixture.physics.update_cloths();
    assert(fixture.assets.geometry(copy).header.revision == revision + 1);
    fixture.physics.update(0);
    node.local.position.x += 0.25f;
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(fixture.assets.geometry(copy).header.revision == revision + 2);
    Geometry* data = &fixture.assets.geometry(copy).data;
    foreach (normal : data.normals) assert(finite(normal) && math::abs(normal.length() - 1) < 1e-4f);
    foreach (position : data.positions) {
        assert(position.x >= data.bounds.min.x && position.y >= data.bounds.min.y && position.z >= data.bounds.min.z);
        assert(position.x <= data.bounds.max.x && position.y <= data.bounds.max.y && position.z <= data.bounds.max.z);
    }

    fixture.scene.remove_cloth(node);
    scene::Mesh* mesh = fixture.scene.get(node, scene::Mesh);
    assert(c3d::same_id(mesh.geometry, source) && !mesh.vertex_motion);
    assert(!fixture.assets.geometries.is_live(copy) && !fixture.scene.has(node, Cloth));

    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(pins[..]))!!;
    copy = fixture.scene.get(node, scene::Mesh).geometry;
    ClothState* state = state_of(&fixture, node);
    physics::destroy_physics_world(&fixture.physics);
    fixture.physics_alive = false;
    assert(state.positions.len == 9 && fixture.assets.geometries.is_live(copy));
    fixture.scene.remove(node);
    assert(!fixture.assets.geometries.is_live(copy) && !fixture.scene.count(Cloth));
    teardown(&fixture);
    assert(!tracker.has_leaks());
}

fn void test_cloth_step_has_no_allocations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(&fixture, allocator: &tracker);
    defer teardown(&fixture);
    GeometryId grid = add_grid(&fixture, GRID_CELLS);
    sz before = tracker.allocation_count();
    Node* node = add_cloth_node(&fixture, grid);
    fixture.scene.add(node, (Wind){ .velocity = { 0, 0, 4 }, .drag = 0.5f });
    fixture.scene.add_cloth(&fixture.assets, node, pinned_desc(top_row(GRID_CELLS)))!!;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    sz allocations = tracker.total_allocation_count();
    for (uint update = 0; update < 120; update++) {
        node.local.position.x = math::sin((float)update * 0.1f);
        float dt = update % 3 == 0 ? 0 : (update % 3 == 1 ? physics::DEFAULT_FIXED_DT : 2 * physics::DEFAULT_FIXED_DT);
        step(&fixture, dt);
    }
    assert(tracker.total_allocation_count() == allocations);
    fixture.scene.remove(node);
    assert(tracker.allocation_count() == before);
}

fn void test_cloth_color_pins() @test {
    @pool() {
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, 4),
            .colors    = alloc::new_array(tmem, Vec4, 4),
        };
        geometry.colors[..] = { { 0.25f, 0, 0, 1 }, { 0.5f, 0, 0, 1 }, { 0.75f, 0, 0, 1 }, { 0.49f, 1, 1, 1 } }[..];
        uint[] pins = cloth::pins_from_colors(tmem, &geometry);
        assert(pins.len == 2 && pins[0] == 1 && pins[1] == 2);
        Geometry empty;
        assert(cloth::pins_from_colors(tmem, &empty).len == 0);
    };
}

struct CapeRig @private {
    Node*    skin;
    Node*[]  joints;
    Node*    cape;
    Ragdoll* ragdoll;
}

fn Node* add_body_node(
    Fixture* fixture,
    ColliderDesc[] colliders,
    Vec3 position = {},
    BodyKind kind = KINEMATIC,
) @private {
    Node* node = fixture.scene.add_node(name: "body")!!;
    node.local.position = position;
    fixture.scene.update_world();
    fixture.physics.add_body(node, physics::default_body_desc(kind), colliders)!!;
    return node;
}

fn ColliderDesc sphere(float radius, Vec3 centre = {}) @private {
    ColliderDesc desc = physics::default_collider_desc(SPHERE);
    desc.radius = radius;
    desc.local.position = centre;
    return desc;
}

fn ColliderDesc capsule(float radius, float half_height, maths::Transform local = maths::TRANSFORM_IDENTITY) @private {
    ColliderDesc desc = physics::default_collider_desc(CAPSULE);
    desc.radius = radius;
    desc.half_height = half_height;
    desc.local = local;
    return desc;
}

// Vertex 0 is the only free particle; loose constraints leave it to the contacts.
fn Node* add_probe(Fixture* fixture, Vec3 point, Entity[] colliders) @private {
    Node* node = add_cloth_node(fixture, add_triangle(fixture, point, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.thickness = PROBE_THICKNESS;
    desc.colliders = colliders;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn void publish(Fixture* fixture) @private {
    fixture.physics.update(0);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
}

fn Vec3 closest_on_segment(Vec3 point, Vec3 start, Vec3 end) @private {
    Vec3 axis = end - start;
    float length_squared = axis.dot(axis);
    if (length_squared == 0) return start;
    return start + axis * math::clamp((point - start).dot(axis) / length_squared, 0.0f, 1.0f);
}

fn float segment_distance(Vec3 point, Vec3 start, Vec3 end) @private => (point - closest_on_segment(point, start, end)).length();

fn void check_projection(
    ColliderDesc collider,
    Vec3 start,
    Vec3 end,
    Vec3[] points,
) @private {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* body = add_body_node(&fixture, (&collider)[:1], kind: STATIC);
    Entity[1] colliders = { body.id };
    float expanded = collider.radius + PROBE_THICKNESS;
    Node*[8] probes;
    foreach (index, point : points) probes[index] = add_probe(&fixture, point, colliders[..]);

    publish(&fixture);
    foreach (index, point : points) {
        Vec3 published = published_world(&fixture, probes[index], 0);
        Vec3 closest = closest_on_segment(point, start, end);
        float distance = (point - closest).length();
        assert(finite(published));
        if (distance >= expanded) {
            assert(near(published, point));
        } else if (distance > CONTACT_TOLERANCE) {
            assert(near(published, closest + (point - closest) / distance * expanded, CONTACT_TOLERANCE));
        } else {
            assert(near(closest_on_segment(published, start, end), closest, CONTACT_TOLERANCE));
            assert(math::abs(segment_distance(published, start, end) - expanded) <= CONTACT_TOLERANCE);
        }
    }

    step(&fixture, physics::DEFAULT_FIXED_DT);
    foreach (index, point : points) {
        ClothState* state = state_of(&fixture, probes[index]);
        assert(finite(state.positions[0]));
        if (segment_distance(point, start, end) >= expanded) {
            assert(state.positions[0] == point);
        } else {
            assert(segment_distance(state.positions[0], start, end) >= expanded - CONTACT_TOLERANCE);
        }
        foreach (pin : state.pins) assert(state.positions[pin] == maths::transform_point(probes[index].world, state.rest[pin]));
    }
}

fn void test_cloth_sphere_and_capsule_projection() @test {
    Vec3[4] sphere_points = { { 0.3f, 0.4f, 0 }, { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 2 } };
    check_projection(
        collider: sphere(1),
        start:    { 0, 0, 0 },
        end:      { 0, 0, 0 },
        points:   sphere_points[..],
    );
    Vec3[5] capsule_points = { { 0.2f, 0.5f, 0.1f }, { 0, 0.3f, 0 }, { 0.1f, 1.2f, 0.1f }, { 0.5f, 0, 0 }, { 2, 0, 0 } };
    check_projection(
        collider: capsule(0.5f, 1),
        start:    { 0, -1, 0 },
        end:      { 0, 1, 0 },
        points:   capsule_points[..],
    );
}

fn void test_cloth_contact_uses_final_body_pose() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc collider = capsule(0.5f, 1);
    Node* body = add_body_node(&fixture, (&collider)[:1]);
    Entity[1] colliders = { body.id };
    Node* probe = add_probe(&fixture, { 1, 0, 0 }, colliders[..]);
    ClothState* state = state_of(&fixture, probe);
    float expanded = collider.radius + PROBE_THICKNESS;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(state.positions[0] == (Vec3){ 1, 0, 0 });

    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    body.local.position = { 0.9f, 0, 0 };
    body.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI / 2);
    fixture.scene.update_world();
    cloth::sample_bodies(&fixture.scene, state);
    for (float progress = 0.25f; progress < 1; progress += 0.25f) {
        cloth::place_shapes(state, progress);
        float length = (state.shape_ends[0] - state.shape_starts[0]).length();
        assert(math::abs(length - 2 * collider.half_height) <= POSITION_TOLERANCE);
    }
    fixture.physics.update_cloths();
    Vec3 start = maths::transform_point(body.world, { 0, -1, 0 });
    Vec3 end = maths::transform_point(body.world, { 0, 1, 0 });
    assert(near(state.shape_starts[0], start) && near(state.shape_ends[0], end));
    assert(segment_distance(state.positions[0], start, end) >= expanded - CONTACT_TOLERANCE);
    assert(segment_distance(published_world(&fixture, probe, 0), start, end) >= expanded - CONTACT_TOLERANCE);

    Vec3 position = state.positions[0];
    Vec3 velocity = state.velocities[0];
    maths::Transform solved = state.bodies[0].solved;
    uint revision = geometry_of(&fixture, probe).header.revision;
    fixture.physics.update(0);
    body.local.position = position - (Vec3){ 0.2f, 0, 0 };
    fixture.scene.update_world();
    start = maths::transform_point(body.world, { 0, -1, 0 });
    end = maths::transform_point(body.world, { 0, 1, 0 });
    assert(segment_distance(position, start, end) < expanded);
    fixture.physics.update_cloths();
    assert(segment_distance(published_world(&fixture, probe, 0), start, end) >= expanded - CONTACT_TOLERANCE);
    assert(geometry_of(&fixture, probe).header.revision == revision + 1);
    assert(state.positions[0] == position && state.velocities[0] == velocity);
    assert(state.bodies[0].solved.position == solved.position && state.bodies[0].solved.rotation.v == solved.rotation.v);
}

fn void test_cloth_collider_scale_applied_once() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    maths::Transform offset_left = maths::TRANSFORM_IDENTITY;
    offset_left.position = { -0.5f, 0, 0 };
    ColliderDesc[2] shapes = { sphere(0.25f, { 0.5f, 0, 0 }), capsule(0.25f, 0.5f, offset_left) };
    Node* body = fixture.scene.add_node(name: "scaled")!!;
    body.local = {
        .position = { 0, 1, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f),
        .scale    = { 2, 2, 2 },
    };
    fixture.scene.update_world();
    fixture.physics.add_body(body, physics::default_body_desc(KINEMATIC), shapes[..])!!;
    RigidBody* rigid = fixture.scene.get(body, RigidBody);
    maths::Transform pose = rigid.current;
    Entity[1] colliders = { body.id };

    Vec3 centre = pose.position + pose.rotation.rotate_vec3(rigid.colliders[0].local.position);
    Vec3 half = pose.rotation.rotate_vec3({ 0, rigid.colliders[1].half_height, 0 });
    Vec3 middle = pose.position + pose.rotation.rotate_vec3(rigid.colliders[1].local.position);
    Vec3 above = { 0, 0.1f, 0 };
    Vec3 side = pose.rotation.rotate_vec3({ 0, 0, 0.1f });
    Node* sphere_probe = add_probe(&fixture, centre + above, colliders[..]);
    Node* capsule_probe = add_probe(&fixture, middle + side, colliders[..]);
    publish(&fixture);

    float sphere_reach = rigid.colliders[0].radius + PROBE_THICKNESS;
    float capsule_reach = rigid.colliders[1].radius + PROBE_THICKNESS;
    assert(near(published_world(&fixture, sphere_probe, 0), centre + above.normalize() * sphere_reach, CONTACT_TOLERANCE));
    assert(near(published_world(&fixture, capsule_probe, 0), middle + side.normalize() * capsule_reach, CONTACT_TOLERANCE));
    ClothState* state = state_of(&fixture, capsule_probe);
    assert(near(state.shape_starts[0], centre) && near(state.shape_ends[0], centre));
    assert(near(state.shape_starts[1], middle - half) && near(state.shape_ends[1], middle + half));
}

fn void test_cloth_collider_capacity_is_shape_count() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc[cloth::MAX_CLOTH_COLLIDERS + 1] spheres;
    foreach (index, &shape : spheres) *shape = sphere(0.1f, { (float)index, 0, 0 });
    ColliderDesc block = physics::default_collider_desc(BOX);
    block.half_extents = { 0.1f, 0.1f, 0.1f };
    ColliderDesc[cloth::MAX_CLOTH_COLLIDERS + 1] mixed;
    mixed[:cloth::MAX_CLOTH_COLLIDERS] = spheres[:cloth::MAX_CLOTH_COLLIDERS];
    mixed[cloth::MAX_CLOTH_COLLIDERS] = block;
    Node* full = add_body_node(&fixture, mixed[..]);
    Node* over = add_body_node(&fixture, spheres[..]);
    ColliderDesc single = capsule(0.1f, 0.2f);
    Node* extra = add_body_node(&fixture, (&single)[:1]);
    Entity[cloth::MAX_CLOTH_COLLIDERS + 1] boxes;
    foreach (&entry : boxes) *entry = add_body_node(&fixture, (&block)[:1]).id;
    GeometryId source = add_grid(&fixture, 1);

    ClothDesc desc = cloth::default_cloth_desc();
    Entity[1] listed = { full.id };
    desc.colliders = listed[..];
    Node* accepted = add_cloth_node(&fixture, source);
    fixture.scene.add_cloth(&fixture.assets, accepted, desc)!!;
    assert(state_of(&fixture, accepted).shapes.len == cloth::MAX_CLOTH_COLLIDERS);

    Node* plain = add_cloth_node(&fixture, source);
    listed[0] = over.id;
    check_rejected(&fixture, plain, desc, c3d::CAPACITY_EXCEEDED);
    Entity[2] pair = { full.id, extra.id };
    desc.colliders = pair[..];
    check_rejected(&fixture, plain, desc, c3d::CAPACITY_EXCEEDED);
    desc.colliders = boxes[..];
    check_rejected(&fixture, plain, desc, c3d::CAPACITY_EXCEEDED);
    boxes[cloth::MAX_CLOTH_COLLIDERS - 1] = extra.id;
    desc.colliders = boxes[:cloth::MAX_CLOTH_COLLIDERS];
    fixture.scene.add_cloth(&fixture.assets, plain, desc)!!;
    ClothState* state = state_of(&fixture, plain);
    assert(state.bodies.len == cloth::MAX_CLOTH_COLLIDERS && state.shapes.len == 1);
}

fn void test_cloth_collider_bindings_are_owned_and_generational() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc collider = sphere(0.5f);
    Node* body = add_body_node(&fixture, (&collider)[:1]);
    Entity owner = body.id;
    Entity[1] colliders = { owner };
    Vec3 inside = { 0.1f, 0.2f, 0 };
    Node* probe = add_probe(&fixture, inside, colliders[..]);
    colliders[0] = {};
    float expanded = collider.radius + PROBE_THICKNESS;
    publish(&fixture);
    assert(math::abs(published_world(&fixture, probe, 0).length() - expanded) <= CONTACT_TOLERANCE);

    fixture.physics.remove_body(body);
    publish(&fixture);
    assert(near(published_world(&fixture, probe, 0), inside));

    fixture.physics.add_body(body, physics::default_body_desc(KINEMATIC), (&collider)[:1])!!;
    body.local.position = { 0.2f, 0, 0 };
    publish(&fixture);
    assert(math::abs((published_world(&fixture, probe, 0) - body.local.position).length() - expanded) <= CONTACT_TOLERANCE);

    fixture.scene.remove(body);
    Node* replacement = add_body_node(&fixture, (&collider)[:1]);
    assert(replacement.id.index == owner.index && replacement.id.generation != owner.generation);
    publish(&fixture);
    assert(near(published_world(&fixture, probe, 0), inside));

    Node* plain = add_cloth_node(&fixture, add_grid(&fixture, 1));
    ClothDesc desc = cloth::default_cloth_desc();
    Entity[1] dead = { owner };
    desc.colliders = dead[..];
    check_rejected(&fixture, plain, desc, c3d::INVALID_ID);
    Node* unbuilt = fixture.scene.add_node(name: "unbuilt")!!;
    fixture.scene.add_physics_body(unbuilt, physics::default_body_desc(KINEMATIC), (&collider)[:1])!!;
    Entity[1] missing = { unbuilt.id };
    desc.colliders = missing[..];
    check_rejected(&fixture, plain, desc, physics::NO_BODY);
    Entity[2] twice = { replacement.id, replacement.id };
    desc.colliders = twice[..];
    check_rejected(&fixture, plain, desc, c3d::INVALID_ARGUMENT);
}

fn void test_cloth_contacts_preserve_allocation_and_pins() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(&fixture, allocator: &tracker);
    defer teardown(&fixture);
    maths::Transform across = maths::TRANSFORM_IDENTITY;
    across.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    ColliderDesc bar = capsule(0.15f, 0.3f, across);
    Node* sweeping = add_body_node(&fixture, (&bar)[:1], { 0.5f, -0.5f, 0 });
    Node* crossing = add_body_node(&fixture, (&bar)[:1], { 0.5f, -0.8f, 0 });
    ColliderDesc ball = sphere(0.3f);
    Node* lone = add_body_node(&fixture, (&ball)[:1], { 5.5f, -0.5f, 0.1f });

    Node* draped = add_cloth_node(&fixture, add_grid(&fixture, GRID_CELLS));
    Entity[2] pair = { sweeping.id, crossing.id };
    ClothDesc desc = pinned_desc(top_row(GRID_CELLS));
    desc.colliders = pair[..];
    desc.collide_ground = true;
    desc.ground_height = -0.9f;
    fixture.scene.add_cloth(&fixture.assets, draped, desc)!!;
    Node* isolated = add_cloth_node(&fixture, add_grid(&fixture, GRID_CELLS));
    isolated.local.position = { 5, 0, 0 };
    fixture.scene.update_world();
    Entity[1] single = { lone.id };
    ClothDesc isolated_desc = pinned_desc(top_row(GRID_CELLS));
    isolated_desc.colliders = single[..];
    fixture.scene.add_cloth(&fixture.assets, isolated, isolated_desc)!!;
    float reach = ball.radius + isolated_desc.thickness;
    Node*[2] cloths = { draped, isolated };

    for (uint update = 0; update < CONTACT_UPDATES; update++) {
        float phase = (float)update * 0.1f;
        sweeping.local.position.z = 0.3f * math::sin(phase);
        crossing.local.position.x = 0.5f + 0.4f * math::cos(phase);
        lone.local.position.z = 0.2f * math::sin(phase);
        float dt = update % 3 == 0 ? 0 : (update % 3 == 1 ? physics::DEFAULT_FIXED_DT : 2 * physics::DEFAULT_FIXED_DT);
        fixture.physics.update(dt);
        fixture.scene.update_world();
        sz allocations = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(tracker.total_allocation_count() == allocations);
        bool stepped = fixture.physics.steps_last_update > 0;
        foreach (node : cloths) {
            ClothState* state = state_of(&fixture, node);
            foreach (pin : state.pins) {
                Vec3 target = maths::transform_point(node.world, state.rest[pin]);
                assert(near(published_world(&fixture, node, pin), target));
                if (stepped) assert(state.positions[pin] == target);
            }
            foreach (position : state.positions) assert(finite(position));
        }
        ClothState* state = state_of(&fixture, isolated);
        Vec3 centre = maths::translation(lone.world);
        foreach (index, position : state.positions) {
            if (state.inverse_masses[index] == 0) continue;
            if (stepped) assert((position - centre).length() >= reach - CONTACT_TOLERANCE);
            assert((published_world(&fixture, isolated, (uint)index) - centre).length() >= reach - CONTACT_TOLERANCE);
        }
    }
}

// Two ragdoll bones along +Y with an unskinned cape parented to the spine joint.
fn CapeRig add_cape_rig(Fixture* fixture) @private {
    Vec3[3] positions = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
    int[3] parents = { -1, 0, 1 };
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 3),
        .parents      = alloc::new_array(mem, int, 3),
        .rest_pose    = alloc::new_array(mem, maths::Transform, 3),
        .inverse_bind = alloc::new_array(mem, Mat4, 3),
    };
    skeleton.parents[..] = parents[..];
    foreach (index, position : positions) {
        maths::Transform unbind = maths::TRANSFORM_IDENTITY;
        unbind.position = -position;
        skeleton.inverse_bind[index] = unbind.to_mat4();
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
    }
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;

    CapeRig rig = { .joints = alloc::new_array(fixture.scene.allocator, Node*, 3) };
    Node* character = fixture.scene.add_node(name: "character")!!;
    rig.skin = fixture.scene.add_node(character, "skin")!!;
    foreach (index, position : positions) {
        int parent = parents[index];
        Node* joint = fixture.scene.add_node(parent < 0 ? character : rig.joints[parent], "joint")!!;
        joint.local.position = parent < 0 ? position : position - positions[parent];
        rig.joints[index] = joint;
    }
    fixture.scene.add(rig.skin, (SkinBinding){ .skeleton = skeleton_id, .joints = rig.joints });
    fixture.scene.update_world();

    RagdollBone[2] bones = { physics::default_ragdoll_bone(0), physics::default_ragdoll_bone(1) };
    foreach (&bone : bones) bone.radius = BONE_RADIUS;
    bones[1].length = 1;
    RagdollDesc ragdoll = physics::default_ragdoll_desc();
    ragdoll.bones = bones[..];
    fixture.scene.build_ragdoll(&fixture.assets, rig.skin, ragdoll)!!;
    rig.ragdoll = fixture.scene.get(rig.skin, Ragdoll);
    fixture.physics.update(0);

    rig.cape = fixture.scene.add_mesh(
        geometry: add_grid(fixture, 2, 0.6f),
        material: fixture.material,
        parent:   rig.joints[1],
        name:     "cape",
    )!!;
    rig.cape.local.position = { -0.3f, 0.5f, -0.2f };
    fixture.scene.update_world();
    Entity[2] colliders = { rig.ragdoll.bone_nodes[0].id, rig.ragdoll.bone_nodes[1].id };
    ClothDesc desc = pinned_desc(top_row(2));
    desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, rig.cape, desc)!!;
    return rig;
}

fn void late_update(Fixture* fixture, float dt) @private {
    fixture.physics.update(dt);
    fixture.physics.update_ragdolls();
    fixture.scene.update_world();
    fixture.physics.update_cloths();
}

fn void check_cape(Fixture* fixture, CapeRig* rig) @private {
    ClothState* state = state_of(fixture, rig.cape);
    Mat4 final_world = rig.joints[1].world.mul(rig.cape.local.to_mat4());
    foreach (pin : state.pins) {
        Vec3 target = maths::transform_point(final_world, state.rest[pin]);
        assert(near(published_world(fixture, rig.cape, pin), target));
        if (fixture.physics.steps_last_update) assert(near(state.positions[pin], target));
    }
    foreach (index, shape : state.shapes) {
        Node* bone = rig.ragdoll.bone_nodes[shape.body];
        Collider* collider = &fixture.scene.get(bone, RigidBody).colliders[0];
        Vec3 half = collider.local.rotation.rotate_vec3({ 0, collider.half_height, 0 });
        Vec3 start = maths::transform_point(bone.world, collider.local.position - half);
        Vec3 end = maths::transform_point(bone.world, collider.local.position + half);
        assert(near(state.shape_starts[index], start, CONTACT_TOLERANCE));
        assert(near(state.shape_ends[index], end, CONTACT_TOLERANCE));
    }
}

fn void test_cloth_cape_uses_final_joint_pose() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    CapeRig rig = add_cape_rig(&fixture);
    ClothState* state = state_of(&fixture, rig.cape);
    assert(state.bodies.len == 2 && state.shapes.len == 2);

    fixture.physics.update(0);
    fixture.physics.update_cloths();
    rig.joints[0].local.position = { 0.5f, 0, 0 };
    rig.joints[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.3f);
    fixture.scene.update_world();
    late_update(&fixture, physics::DEFAULT_FIXED_DT);
    check_cape(&fixture, &rig);

    fixture.physics.set_ragdoll_mode(rig.skin, SIMULATED);
    rig.ragdoll.weight = 1;
    Node* spine = rig.ragdoll.bone_nodes[1];
    RigidBody* spine_body = fixture.scene.get(spine, RigidBody);
    fixture.physics.teleport(spine, spine_body.current.position + (Vec3){ 0, 0, 1 }, spine_body.current.rotation);
    Vec3 animated = maths::transform_point(rig.cape.world, state.rest[0]);
    late_update(&fixture, physics::DEFAULT_FIXED_DT);
    check_cape(&fixture, &rig);
    assert((maths::transform_point(rig.cape.world, state.rest[0]) - animated).length() > 0.5f);

    rig.ragdoll.weight = 0.5f;
    late_update(&fixture, physics::DEFAULT_FIXED_DT);
    check_cape(&fixture, &rig);

    Vec3[9] solved;
    solved[..] = state.positions[..];
    rig.joints[0].local.position = { -0.5f, 0, 0 };
    late_update(&fixture, 0);
    assert(fixture.physics.steps_last_update == 0);
    check_cape(&fixture, &rig);
    foreach (index, position : solved) assert(state.positions[index] == position);
}
