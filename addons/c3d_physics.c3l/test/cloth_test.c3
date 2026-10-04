module c3d_physics_cloth_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
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

fn GeometryId add_triangle(Fixture* fixture, Vec3 offset = {}) @private {
    GeometryId id;
    @pool() {
        Geometry triangle = {
            .positions = alloc::new_array(tmem, Vec3, 3),
            .indices   = alloc::new_array(tmem, uint, 3),
        };
        triangle.positions[..] = ((Vec3[3]){ offset, offset + (Vec3){ 1, 0, 0 }, offset + (Vec3){ 0, 0, 1 } })[..];
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
