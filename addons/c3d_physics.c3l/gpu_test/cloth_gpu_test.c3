module c3d_physics_cloth_gpu_test;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;
import std::math;

const uint GRID_CELLS @local = 4;
const float REFERENCE_TOLERANCE @local = 1e-5f;

struct Fixture @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    MaterialId   material;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = 8 });
    physics::register_physics(&fixture.scene)!!;
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.interpolate = false;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
}

fn void teardown(Fixture* fixture) @local {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_hanging_sheet(Fixture* fixture, bool skinned = false) @local {
    uint side = GRID_CELLS + 1;
    Geometry grid = {
        .positions = alloc::new_array(tmem, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(tmem, uint, (sz)(6 * GRID_CELLS * GRID_CELLS)),
    };
    if (skinned) {
        grid.joints = alloc::new_array(tmem, ushort[<4>], (sz)(side * side));
        grid.weights = alloc::new_array(tmem, Vec4, (sz)(side * side));
    }
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            grid.positions[row * side + column] = { (float)column / GRID_CELLS, -(float)row / GRID_CELLS, 0 };
            if (skinned) {
                float tip_share = (float)row / GRID_CELLS;
                grid.joints[row * side + column] = { 0, 1, 0, 0 };
                grid.weights[row * side + column] = { 1 - tip_share, tip_share, 0, 0 };
            }
        }
    }
    usz next;
    for (uint row = 0; row < GRID_CELLS; row++) {
        for (uint column = 0; column < GRID_CELLS; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    GeometryId geometry = fixture.assets.add_geometry(&grid)!!;
    Node* node = fixture.scene.add_mesh(geometry, fixture.material)!!;
    fixture.scene.update_world();
    return node;
}

fn ClothDesc device_desc(float bend_stiffness) @local {
    uint[] pins = alloc::new_array(tmem, uint, (sz)(GRID_CELLS + 1));
    foreach (index, &pin : pins) *pin = (uint)index;
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins;
    desc.bend_stiffness = bend_stiffness;
    desc.execution = ClothExecution.GPU;
    return desc;
}

fn void test_gpu_cloth_prepares_a_bendless_sheet_and_keeps_its_edge_colors() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        fixture.scene.add_cloth(&fixture.assets, node, device_desc(0))!!;

        ClothState* state = fixture.scene.get(node, Cloth).state;
        assert(state.edge_colors > 1);
        assert(state.edge_color_starts[0] == 0 && state.edge_color_starts[state.edge_colors] == state.edges.len);
    };
}

fn void test_gpu_cloth_prepares_distance_bends_and_keeps_their_colors() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        fixture.scene.add_cloth(&fixture.assets, node, device_desc(cloth::DEFAULT_BEND_STIFFNESS))!!;

        ClothState* state = fixture.scene.get(node, Cloth).state;
        assert(state.bends.len > 0 && state.bend_colors > 1);
        assert(state.bend_color_starts[0] == 0 && state.bend_color_starts[state.bend_colors] == state.bends.len);
    };
}

fn void test_gpu_cloth_with_dihedral_bends_faults_unsupported_and_stays_unprepared() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        uint geometries = fixture.assets.geometries.free_count;
        ClothDesc desc = device_desc(cloth::DEFAULT_BEND_STIFFNESS);
        desc.bend_mode = ClothBendMode.DIHEDRAL;
        fixture.scene.attach_cloth(&fixture.assets, node, desc)!!;

        assert(@catch(cloth::prepare(&fixture.scene, &fixture.assets, node)) == c3d::UNSUPPORTED);
        assert(!fixture.scene.get(node, Cloth).is_prepared());
        assert(fixture.assets.geometries.free_count == geometries);
    };
}

fn void test_update_cloths_stores_device_inputs_and_never_solves() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        fixture.scene.add_cloth(&fixture.assets, node, device_desc(0))!!;
        ClothState* state = fixture.scene.get(node, Cloth).state;
        Vec3[] initial = alloc::new_array(tmem, Vec3, state.positions.len);
        initial[..] = state.positions[..];
        Mat4 start = node.world;

        node.local.position = { 1, 0, 0 };
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(state.device.steps == 1 && state.device.anchor == start && state.device.target == node.world);
        assert(state.device.gravity == physics::DEFAULT_GRAVITY);
        assert(state.positions == initial[..] && state.velocities[1] == (Vec3){});

        fixture.physics.update(0);
        fixture.physics.update_cloths();
        assert(state.device.steps == 0 && state.device.anchor == start && state.device.target == node.world);
    };
}

fn void test_held_device_cloth_stores_no_step_until_it_wakes() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        fixture.scene.add_cloth(&fixture.assets, node, device_desc(0))!!;
        Cloth* cloth = fixture.scene.get(node, Cloth);

        cloth.sleep();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(cloth.state.device.steps == 0);

        cloth.wake();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(cloth.state.device.steps == 1);
    };
}

fn void test_update_cloths_stores_the_wind_of_the_owner_each_update() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* node = add_hanging_sheet(&fixture);
        fixture.scene.add_cloth(&fixture.assets, node, device_desc(0))!!;
        ClothState* state = fixture.scene.get(node, Cloth).state;

        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(!state.device.wind_present);

        Wind breeze = { .velocity = { 0, 0, 2 }, .max_speed = 1.5f };
        fixture.scene.add(node, breeze);
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(state.device.wind_present && state.device.wind.velocity == breeze.velocity);
        assert(state.device.wind.max_speed == breeze.max_speed);

        fixture.scene.remove_component(node, Wind);
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(!state.device.wind_present);
    };
}

fn void test_update_cloths_samples_the_reference_of_a_skinned_device_cloth() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        int[] parents = alloc::new_array(mem, int, 2);
        parents[0] = -1;
        parents[1] = 0;
        Mat4[] inverse_bind = alloc::new_array(mem, Mat4, 2);
        foreach (&bind : inverse_bind) *bind = matrix::IDENTITY4;
        Skeleton skeleton = { .parents = parents, .inverse_bind = inverse_bind };
        SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;
        Node* root = fixture.scene.add_node(name: "root_joint")!!;
        Node* tip = fixture.scene.add_node(root, "tip_joint")!!;
        Node* owner = add_hanging_sheet(&fixture, skinned: true);
        Node*[] joints = alloc::new_array(mem, Node*, 2);
        joints[0] = root;
        joints[1] = tip;
        fixture.scene.add(owner, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
        fixture.scene.update_world();
        fixture.scene.add_cloth(&fixture.assets, owner, device_desc(0), &fixture.physics)!!;

        ClothState* state = fixture.scene.get(owner, Cloth).state;
        usz last = state.positions.len - 1;
        Vec3 first_position = state.current_reference[last];
        tip.local.position = { 0, 0.5f, 0 };
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert(state.device.steps == 1);
        assert(state.solved_reference[last] == first_position);
        assert((state.current_reference[last] - first_position - (Vec3){ 0, 0.5f, 0 }).length() < REFERENCE_TOLERANCE);

        tip.local.position = { 0, 0.75f, 0 };
        fixture.scene.update_world();
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.physics.update_cloths();
        assert((state.solved_reference[last] - first_position - (Vec3){ 0, 0.5f, 0 }).length() < REFERENCE_TOLERANCE);
        assert((state.current_reference[last] - first_position - (Vec3){ 0, 0.75f, 0 }).length() < REFERENCE_TOLERANCE);
        assert(state.positions[last] == first_position);

        fixture.physics.update(0);
        fixture.physics.update_cloths();
        assert(state.device.steps == 0);
        assert((state.solved_reference[last] - first_position - (Vec3){ 0, 0.5f, 0 }).length() < REFERENCE_TOLERANCE);
    };
}
