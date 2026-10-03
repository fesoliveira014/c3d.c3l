module c3d::test::view_history;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import gpu;
import std::math;

const uint NODE_CAPACITY @local = 8;
const Vec3 JOINT_OFFSET @local = { 10, 0, 0 };
const Mat4 SENTINEL @local = { .m00 = 7, .m11 = 7, .m22 = 7, .m33 = 7 };

struct BatchHistory @local {
    Scene        scene;
    AssetStore   assets;
    GeometryId   box;
    MaterialId   red;
    ViewHistory  history;
}

fn AssetStore create_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 1,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 2,
    });
}

fn SkeletonId add_identity_skeleton(AssetStore* assets, sz joints) @local {
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, joints),
        .parents      = alloc::new_array(mem, int, joints),
        .rest_pose    = alloc::new_array(mem, Transform, joints),
        .inverse_bind = alloc::new_array(mem, Mat4, joints),
    };
    for (sz index = 0; index < joints; index++) {
        skeleton.parents[index] = -1;
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[index] = matrix::IDENTITY4;
    }
    return assets.add_skeleton_owned(&skeleton)!!;
}

fn bool same_matrix(Mat4f stored, Mat4 expected) @local {
    return bitcast(stored, Mat4) == expected;
}

fn MeshCandidate[2] candidates_of(Node* first, Node* second) @local {
    return { { .node = first }, { .node = second } };
}

fn BatchHistory create_batch_history() @local {
    BatchHistory fixture = {
        .scene  = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY }),
        .assets = create_store(),
    };
    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&shape, "box")!!;
    };
    fixture.red = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "red")!!;
    return fixture;
}

fn void destroy_batch_history(BatchHistory* fixture) @local {
    render::free_view_history(mem, &fixture.history);
    asset::destroy_asset_store(&fixture.assets);
    scene::destroy_scene(&fixture.scene);
}

fn Node* add_pair_batch(BatchHistory* fixture, float spread) @local {
    Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[0].position = { -spread, 0, 0 };
    transforms[1].position = { spread, 0, 0 };
    Node* node = fixture.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.red,
        capacity:   2,
        transforms: transforms[..],
    )!!;
    node.local.position = { 3, 0, 0 };
    fixture.scene.update_world();
    return node;
}

fn void commit_batch(BatchHistory* fixture, Node* node, double time = 0) @local {
    MeshCandidate[1] candidates = { { .node = node, .batch = fixture.scene.get(node, InstancedMesh) } };
    fixture.history.commit(
        allocator:  mem,
        assets:     &fixture.assets,
        scene:      &fixture.scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       time,
    );
}

fn void test_view_history_reports_previous_model_only_for_matching_owner() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    first.local.position = { 1, 2, 3 };
    scene.update_world();
    Mat4 camera = matrix::IDENTITY4.translate({ 0, 0, -5 });

    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    assert(!history.has_previous(&scene, first));
    MeshCandidate[2] candidates = candidates_of(first, second);
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  camera,
        time:       0,
    );
    history.publish();
    assert(history.valid && history.view_proj == camera);
    assert(history.has_previous(&scene, first) && history.previous_model(&scene, first) == first.world);
    assert(history.has_previous(&scene, second));

    Entity old_id = first.id;
    scene.remove(first);
    Node* reused = scene.add_node(name: "reused")!!;
    assert(reused.id.index == old_id.index && reused.id.generation != old_id.generation);
    assert(!history.has_previous(&scene, reused));
    assert(history.has_previous(&scene, second));
}

fn void test_view_history_reset_forgets_everything() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    scene.update_world();

    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[2] candidates = candidates_of(first, second);
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    history.valid = false;
    assert(!history.has_previous(&scene, first) && !history.has_previous(&scene, second));

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.has_previous(&scene, first));
}

fn void test_view_history_membership_follows_the_last_published_rendering() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    Node* second = scene.add_node(name: "second")!!;
    scene.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);

    MeshCandidate[2] both = candidates_of(first, second);
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: both[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.has_previous(&scene, first) && history.has_previous(&scene, second));

    MeshCandidate[1] only_first = { { .node = first } };
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: only_first[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.has_previous(&scene, first));
    assert(!history.has_previous(&scene, second));

    second.local.position = { 4, 0, 0 };
    scene.update_world();
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: both[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.has_previous(&scene, second) && history.previous_model(&scene, second) == second.world);
}

fn void test_view_history_ignores_a_scene_with_matching_ids() @test {
    Scene first_scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&first_scene);
    Scene second_scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&second_scene);
    assert(first_scene.identity != 0 && second_scene.identity != 0);
    assert(first_scene.identity != second_scene.identity);
    Node* first = first_scene.add_node(name: "mesh")!!;
    Node* second = second_scene.add_node(name: "mesh")!!;
    assert(first.id.index == second.id.index && first.id.generation == second.id.generation);
    first_scene.update_world();
    second_scene.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);

    MeshCandidate[1] candidates = { { .node = first } };
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &first_scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.has_previous(&first_scene, first));
    assert(!history.has_previous(&second_scene, second));
}

fn void test_view_history_pending_rendering_is_not_previous_until_published() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node(name: "first")!!;
    scene.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = first } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    assert(history.pending && !history.valid && !history.has_previous(&scene, first));
    history.publish();
    assert(history.valid && !history.pending && history.has_previous(&scene, first));

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.discard();
    assert(!history.valid && !history.pending && !history.has_previous(&scene, first));

    history.publish();
    assert(!history.valid);
}

fn void test_view_history_advances_sample_and_slot_only_on_publish() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* node = scene.add_node(name: "mesh")!!;
    scene.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = node } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.discard();
    assert(history.sample_index == 0 && history.slot == 0);

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    assert(history.sample_index == 1 && history.slot == 1);

    for (uint rendering = 0; rendering < post::TAA_SAMPLE_COUNT; rendering++) {
        history.commit(
            allocator:  mem,
            assets:     &assets,
            scene:      &scene,
            candidates: candidates[..],
            view_proj:  matrix::IDENTITY4,
            time:       0,
        );
        history.publish();
    }
    assert(history.sample_index == 1);
    assert(history.slot == (1 + post::TAA_SAMPLE_COUNT) % 2);
}

fn void test_view_history_keeps_the_palette_of_the_last_commit() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    SkeletonId skeleton = add_identity_skeleton(&assets, 2);
    Node*[] joints = alloc::new_array(scene.allocator, Node*, 2);
    foreach (&joint : joints) *joint = scene.add_node(name: "joint")!!;
    joints[1].local.position = JOINT_OFFSET;
    Node* mesh = scene.add_node(name: "skinned")!!;
    mesh.local.position = { 0, 3, 0 };
    scene.add(mesh, (SkinBinding){ .skeleton = skeleton, .joints = joints });
    scene.update_world();
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = mesh, .skin = scene.get(mesh, SkinBinding) } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, mesh);
    assert(pose.palette.len == 2);
    Mat4 committed = maths::inverse_affine(mesh.world).mul(joints[1].world);
    assert(same_matrix(pose.palette[1], committed));

    joints[1].local.position = { 0, 0, 7 };
    scene.update_world();
    assert(same_matrix(history.previous_pose(&scene, mesh).palette[1], committed));
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    Mat4 moved = maths::inverse_affine(mesh.world).mul(joints[1].world);
    assert(same_matrix(history.previous_pose(&scene, mesh).palette[1], moved));
}

fn void test_view_history_instances_follow_draw_order_and_keep_capacity() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    GeometryId box;
    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&shape, "box")!!;
    };
    MaterialId red = assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "red")!!;
    Transform[3] transforms = {
        { .position = { 1, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
        { .position = { 2, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { -1, 1, 1 } },
        { .position = { 3, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
    };
    Node* node = scene.add_instanced_mesh(
        geometry:   box,
        material:   red,
        capacity:   4,
        transforms: transforms[..],
    )!!;
    node.local.position = { 0, 5, 0 };
    scene.update_world();
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = node, .batch = batch } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, node);
    assert(pose.instance_count == 3 && pose.instances.len == 4);
    assert(same_matrix(pose.instances[0], transforms[0].to_mat4()));
    assert(same_matrix(pose.instances[1], transforms[2].to_mat4()));
    assert(same_matrix(pose.instances[2], transforms[1].to_mat4()));

    Mat4f* storage = pose.instances.ptr;
    scene.resize_instances(node, 4)!!;
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    pose = history.previous_pose(&scene, node);
    assert(pose.instances.ptr == storage && pose.instance_count == 4);
}

fn void test_view_history_records_the_selected_morph_block() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    Node* morphed = scene.add_node(name: "morphed")!!;
    Node* plain = scene.add_node(name: "plain")!!;
    scene.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    float[3] weights = { 0.25f, 0, -0.75f };
    MeshCandidate[2] candidates = { { .node = morphed, .morph_weights = weights[..] }, { .node = plain } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, morphed);
    assert(pose.morphed && pose.morph.count == 2);
    assert(pose.morph.indices[0] == 2 && pose.morph.weights[0] == -0.75f);
    assert(pose.morph.indices[1] == 0 && pose.morph.weights[1] == 0.25f);
    assert(!history.previous_pose(&scene, plain).morphed);
}

fn void test_view_history_keeps_sample_and_slot_when_the_tables_grow() @test {
    Scene small = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&small);
    Scene large = scene::create_scene(mem, { .max_nodes = 2 * NODE_CAPACITY });
    defer scene::destroy_scene(&large);
    Node* first = small.add_node(name: "first")!!;
    Node* second = large.add_node(name: "second")!!;
    small.update_world();
    large.update_world();
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] small_candidates = { { .node = first } };
    MeshCandidate[1] large_candidates = { { .node = second } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &small,
        candidates: small_candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    history.publish();
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &large,
        candidates: large_candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    assert(history.models.len == large.nodes.len);
    assert(history.sample_index == 1 && history.slot == 1);
    history.publish();
    assert(history.sample_index == 2 && history.slot == 0);
}

fn void test_view_history_resizes_the_palette_with_the_binding() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    SkeletonId two = add_identity_skeleton(&assets, 2);
    SkeletonId three = add_identity_skeleton(&assets, 3);
    Node*[] joints = alloc::new_array(scene.allocator, Node*, 3);
    foreach (&joint : joints) *joint = scene.add_node(name: "joint")!!;
    Node* mesh = scene.add_node(name: "skinned")!!;
    scene.add(mesh, (SkinBinding){ .skeleton = two, .joints = joints[:2] });
    scene.update_world();
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = mesh, .skin = scene.get(mesh, SkinBinding) } };

    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    assert(history.poses[mesh.id.index].palette.len == 2);

    SkinBinding* binding = scene.get(mesh, SkinBinding);
    binding.skeleton = three;
    binding.joints = joints;
    history.commit(
        allocator:  mem,
        assets:     &assets,
        scene:      &scene,
        candidates: candidates[..],
        view_proj:  matrix::IDENTITY4,
        time:       0,
    );
    assert(history.poses[mesh.id.index].palette.len == 3);
}

fn void test_history_rewrites_only_on_a_new_revision() @test {
    BatchHistory fixture = create_batch_history();
    defer destroy_batch_history(&fixture);
    Node* node = add_pair_batch(&fixture, 1);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);

    commit_batch(&fixture, node);
    PoseRecord* pose = &fixture.history.poses[node.id.index];
    assert(pose.instance_revision == batch.revision);
    assert(same_matrix(pose.instances[0], batch.transforms[0].to_mat4()));
    assert(same_matrix(pose.instances[1], batch.transforms[1].to_mat4()));

    pose.instances[0] = bitcast(SENTINEL, Mat4f);
    commit_batch(&fixture, node);
    assert(same_matrix(pose.instances[0], SENTINEL));

    fixture.scene.mark_instances_dirty(node);
    commit_batch(&fixture, node);
    assert(same_matrix(pose.instances[0], batch.transforms[0].to_mat4()));
    assert(pose.instance_revision == batch.revision);
}

fn void test_history_stamp_survives_discard() @test {
    BatchHistory fixture = create_batch_history();
    defer destroy_batch_history(&fixture);
    Node* node = add_pair_batch(&fixture, 1);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);

    commit_batch(&fixture, node);
    PoseRecord* pose = &fixture.history.poses[node.id.index];
    pose.instances[1] = bitcast(SENTINEL, Mat4f);
    fixture.history.discard();
    commit_batch(&fixture, node);
    assert(pose.instance_revision == batch.revision && same_matrix(pose.instances[1], SENTINEL));

    fixture.history.discard();
    fixture.scene.mark_instances_dirty(node);
    commit_batch(&fixture, node);
    assert(pose.instance_revision == batch.revision);
    assert(same_matrix(pose.instances[1], batch.transforms[1].to_mat4()));
}

fn void test_history_slot_reuse_clears_the_stamp() @test {
    BatchHistory fixture = create_batch_history();
    defer destroy_batch_history(&fixture);
    Node* first = add_pair_batch(&fixture, 1);
    usz slot = first.id.index;
    commit_batch(&fixture, first);
    fixture.history.publish();
    fixture.scene.remove(first);

    Node* second = add_pair_batch(&fixture, 4);
    assert(second.id.index == slot);
    InstancedMesh* batch = fixture.scene.get(second, InstancedMesh);
    PoseRecord* pose = &fixture.history.poses[slot];
    assert(pose.instance_revision == batch.revision);
    assert(!fixture.history.has_previous(&fixture.scene, second));

    pose.instances[0] = bitcast(SENTINEL, Mat4f);
    commit_batch(&fixture, second);
    assert(same_matrix(pose.instances[0], batch.transforms[0].to_mat4()));
}

fn void test_view_history_keeps_the_sway_of_the_last_commit() @test {
    BatchHistory fixture = create_batch_history();
    defer destroy_batch_history(&fixture);
    Node* node = add_pair_batch(&fixture, 1);
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    batch.sway = { .direction = { 1, 0, 0 }, .amplitude = 0.2f };

    commit_batch(&fixture, node, 1.5);
    fixture.history.publish();
    assert(fixture.history.has_previous(&fixture.scene, node));
    assert(fixture.history.previous_pose(&fixture.scene, node).sway.amplitude == 0.2f);
    assert(fixture.history.time == 1.5);

    batch.sway.amplitude = 0.5f;
    commit_batch(&fixture, node, 2.0);
    fixture.history.publish();
    assert(fixture.history.previous_pose(&fixture.scene, node).sway.amplitude == 0.5f);
    assert(fixture.history.time == 2.0);

    batch.sway.amplitude = 0.7f;
    commit_batch(&fixture, node, 2.5);
    fixture.history.discard();
    assert(!fixture.history.valid && !fixture.history.has_previous(&fixture.scene, node));

    MeshCandidate[1] plain = { { .node = node } };
    fixture.history.commit(
        allocator:  mem,
        assets:     &fixture.assets,
        scene:      &fixture.scene,
        candidates: plain[..],
        view_proj:  matrix::IDENTITY4,
        time:       3.0,
    );
    fixture.history.publish();
    assert(fixture.history.previous_pose(&fixture.scene, node).sway.amplitude == 0);
}

fn void test_view_history_publishes_origin_with_the_pose_and_matrix() @test {
    BatchHistory fixture = create_batch_history();
    defer destroy_batch_history(&fixture);
    Node* node = add_pair_batch(&fixture, 0.125f);
    node.local.position = { 50000, 0, 50000 };
    fixture.scene.update_world();
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    MeshCandidate[1] candidates = { { .node = node, .batch = batch } };
    Vec3[3] origins = { { 49920, 0, 49920 }, { 50176, 0, 49920 }, { 49920, 0, 50176 } };
    Mat4f* storage;
    foreach (index, origin : origins) {
        Mat4 projection = matrix::IDENTITY4.translate(-origin);
        fixture.history.commit(
            allocator: mem,
            assets: &fixture.assets,
            scene: &fixture.scene,
            candidates: candidates[..],
            view_proj: projection,
            time: (double)index,
            origin: origin,
        );
        assert(fixture.history.pending && fixture.history.origin == origin);
        if (index == 1) {
            fixture.history.discard();
            assert(!fixture.history.valid && !fixture.history.pending);
            assert(!fixture.history.has_previous(&fixture.scene, node));
            continue;
        }
        fixture.history.publish();
        assert(fixture.history.valid && fixture.history.origin == origin);
        assert(fixture.history.view_proj == projection);
        assert(fixture.history.previous_model(&fixture.scene, node) == node.world);
        PoseRecord* pose = fixture.history.previous_pose(&fixture.scene, node);
        assert(same_matrix(pose.instances[0], batch.transforms[0].to_mat4()));
        assert(same_matrix(pose.instances[1], batch.transforms[1].to_mat4()));
        if (index == 0) {
            storage = pose.instances.ptr;
        } else {
            assert(pose.instances.ptr == storage);
        }
    }
}
