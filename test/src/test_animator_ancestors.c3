module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::io;
import std::math;

fn sz animator_allocation_bytes(uint max_nodes) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    sz bytes;
    {
        AssetStore assets = create_store();
        defer asset::destroy_asset_store(&assets);

        Scene scene = scene::create_scene(&tracker, { .max_nodes = max_nodes });
        defer scene::destroy_scene(&scene);

        ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
        Node* root = model::instantiate(&assets, &scene, model)!!;
        anim::add_animator(&scene, root);
        scene.remove_component(root, Animator);

        sz before = tracker.total_allocated();
        anim::add_animator(&scene, root);
        bytes = tracker.total_allocated() - before;

        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 4; frame++) anim::update(&assets, &scene, 0.25f);
        assert(tracker.total_allocation_count() == allocations);
    }

    assert(!tracker.has_leaks());
    return bytes;
}

fn ClipId ancestor_turn_clip(LayerFixture* fixture, uint root_node = 2) @local {
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    Quat reference = instance.base_pose[root_node].rotation;
    Quat turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 1.0f).mul(reference);
    float[2] times = { 0, 1 };
    float[8] rotations = {
        reference.v.x, reference.v.y, reference.v.z, reference.v.w,
        turn.v.x, turn.v.y, turn.v.z, turn.v.w,
    };
    Track[1] tracks = {
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };
    uint[1] targets = { root_node };

    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void advance_ancestor_turn(LayerFixture* fixture, float dt = 0.25f) @local {
    anim::update(&fixture.assets, &fixture.scene, dt);
    fixture.scene.update_world();

    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    Node* root = instance.present_node(fixture.animator.root_node);
    Vec3 pivot = root.world_position();
    assert(math::abs(fixture.animator.root_motion.rotation.v.y) > 1e-5f);

    anim::apply_root_motion(fixture.root, fixture.animator.root_motion);
    fixture.scene.update_world();
    assert((root.world_position() - pivot).length() < 1e-3f);
}

fn void test_animator_allocation_is_independent_of_scene_capacity() @test {
    sz small = animator_allocation_bytes(16);
    sz large = animator_allocation_bytes(16384);
    io::printfn("Animator storage: %s bytes at capacity 16; %s bytes at capacity 16384.", small, large);
    assert(small == large);
}

fn void test_animator_pivot_accepts_external_chain_deeper_than_model() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        LayerFixture fixture;
        fixture.assets = create_store();
        fixture.scene = scene::create_scene(&tracker, { .max_nodes = 32 });
        fixture.model = gltf::load_model(&fixture.assets, fixture_path("skin.gltf"))!!;
        fixture.root = model::instantiate(&fixture.assets, &fixture.scene, fixture.model)!!;
        fixture.animator = anim::add_animator(&fixture.scene, fixture.root);
        defer destroy_layer_fixture(&fixture);

        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        instance.base_pose[2].position = { 1.25f, 0, -2.5f };
        Node* parent = fixture.root;
        for (uint index = 0; index < 12; index++) {
            parent = fixture.scene.add_node(parent)!!;
            parent.local = {
                .position = { 0.25f, 0, -0.5f },
                .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.1f),
                .scale = { 1.1f, 1.1f, 1.1f },
            };
        }
        assert(12 > instance.nodes.len);
        fixture.scene.reparent(instance.present_node(2), parent);

        ClipId clip = ancestor_turn_clip(&fixture);
        fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT, .root_yaw = true })!!;
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 4; frame++) advance_ancestor_turn(&fixture);
        assert(tracker.total_allocation_count() == allocations);
    }

    assert(!tracker.has_leaks());
}

fn void test_animator_pivot_uses_same_instance_evaluated_ancestor() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    instance.base_pose[3].position = { 2, 0, 3 };
    fixture.animator.root_node = 3;
    ClipId turn = ancestor_turn_clip(&fixture, 3);
    fixture.animator.play(&fixture.assets, layer_translation(&fixture, { 7, 0, -4 }, 2))!!;
    fixture.animator.play(&fixture.assets, turn, { .root_motion = RootMotion.EXTRACT, .root_yaw = true })!!;

    advance_ancestor_turn(&fixture);
    assert(instance.present_node(2).local.position == (Vec3){ 7, 0, -4 });
}

fn void test_animator_pivot_uses_previously_updated_foreign_animator() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    fixture.scene.remove_component(fixture.root, Animator);

    Node* foreign_root = model::instantiate(
        assets: &fixture.assets,
        scene: &fixture.scene,
        model: fixture.model,
        parent: fixture.root,
    )!!;
    Animator* foreign = anim::add_animator(&fixture.scene, foreign_root);
    foreign.play(&fixture.assets, layer_translation(&fixture, { 8, 0, -4 }))!!;
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root);

    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    ModelInstance* other = fixture.scene.get(foreign_root, ModelInstance);
    instance.base_pose[2].position = { 2, 0, 3 };
    fixture.scene.reparent(instance.present_node(2), other.present_node(3));
    ClipId turn = ancestor_turn_clip(&fixture);
    fixture.animator.play(&fixture.assets, turn, { .root_motion = RootMotion.EXTRACT, .root_yaw = true })!!;

    advance_ancestor_turn(&fixture);
    assert(other.present_node(3).local.position == (Vec3){ 8, 0, -4 });
}

fn void test_animator_pivot_refreshes_reparented_selected_root_and_removed_ancestor() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    instance.base_pose[3].position = { 2, 0, 3 };
    fixture.animator.root_node = 3;
    ClipId turn = ancestor_turn_clip(&fixture, 3);
    fixture.animator.play(&fixture.assets, turn, { .root_motion = RootMotion.EXTRACT, .root_yaw = true })!!;
    advance_ancestor_turn(&fixture);

    Node* parent = fixture.scene.add_node(fixture.root)!!;
    parent.local.position = { 5, 0, -6 };
    fixture.scene.reparent(instance.present_node(3), parent);
    fixture.scene.remove(instance.present_node(2));
    fixture.animator = fixture.scene.get(fixture.root, Animator);
    assert(instance.present_node(2) == null);
    advance_ancestor_turn(&fixture);

    fixture.scene.reparent(instance.present_node(3), fixture.root);
    fixture.scene.remove(parent);
    fixture.animator = fixture.scene.get(fixture.root, Animator);
    advance_ancestor_turn(&fixture);

    fixture.animator.root_node = anim::NO_ROOT_NODE;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(fixture.animator.root_motion.translation == (Vec3){});
    assert(fixture.animator.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
}
