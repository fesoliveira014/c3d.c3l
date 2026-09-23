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

fn AssetStore create_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 1,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 1,
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
    history.commit(mem, &assets, &scene, candidates[..], camera);
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
    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    history.valid = false;
    assert(!history.has_previous(&scene, first) && !history.has_previous(&scene, second));

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
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
    history.commit(mem, &assets, &scene, both[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, first) && history.has_previous(&scene, second));

    MeshCandidate[1] only_first = { { .node = first } };
    history.commit(mem, &assets, &scene, only_first[..], matrix::IDENTITY4);
    history.publish();
    assert(history.has_previous(&scene, first));
    assert(!history.has_previous(&scene, second));

    second.local.position = { 4, 0, 0 };
    scene.update_world();
    history.commit(mem, &assets, &scene, both[..], matrix::IDENTITY4);
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
    history.commit(mem, &assets, &first_scene, candidates[..], matrix::IDENTITY4);
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

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    assert(history.pending && !history.valid && !history.has_previous(&scene, first));
    history.publish();
    assert(history.valid && !history.pending && history.has_previous(&scene, first));

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
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

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.discard();
    assert(history.sample_index == 0 && history.slot == 0);

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    assert(history.sample_index == 1 && history.slot == 1);

    for (uint rendering = 0; rendering < post::TAA_SAMPLE_COUNT; rendering++) {
        history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
        history.publish();
    }
    assert(history.sample_index == 1);
    assert(history.slot == (1 + post::TAA_SAMPLE_COUNT) % 2);

    uint slot = history.slot;
    history.valid = false;
    assert(history.sample_index == 1 && history.slot == slot);
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

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, mesh);
    assert(pose.palette.len == 2);
    Mat4 committed = maths::inverse_affine(mesh.world).mul(joints[1].world);
    assert(same_matrix(pose.palette[1], committed));

    joints[1].local.position = { 0, 0, 7 };
    scene.update_world();
    assert(same_matrix(history.previous_pose(&scene, mesh).palette[1], committed));
    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    Mat4 moved = maths::inverse_affine(mesh.world).mul(joints[1].world);
    assert(same_matrix(history.previous_pose(&scene, mesh).palette[1], moved));

    scene.remove(mesh);
    Node* reused = scene.add_node(name: "reused")!!;
    assert(!history.has_previous(&scene, reused));
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
    Node* node = scene.add_instanced_mesh(box, red, 4, transforms[..])!!;
    node.local.position = { 0, 5, 0 };
    scene.update_world();
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    ViewHistory history;
    defer render::free_view_history(mem, &history);
    MeshCandidate[1] candidates = { { .node = node, .batch = batch } };

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, node);
    assert(pose.instance_count == 3 && pose.instances.len == 4);
    assert(same_matrix(pose.instances[0], node.world.mul(transforms[0].to_mat4())));
    assert(same_matrix(pose.instances[1], node.world.mul(transforms[2].to_mat4())));
    assert(same_matrix(pose.instances[2], node.world.mul(transforms[1].to_mat4())));

    Mat4f* storage = pose.instances.ptr;
    scene.resize_instances(node, 4)!!;
    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
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

    history.commit(mem, &assets, &scene, candidates[..], matrix::IDENTITY4);
    history.publish();
    PoseRecord* pose = history.previous_pose(&scene, morphed);
    assert(pose.morphed && pose.morph.count == 2);
    assert(pose.morph.indices[0] == 2 && pose.morph.weights[0] == -0.75f);
    assert(pose.morph.indices[1] == 0 && pose.morph.weights[1] == 0.25f);
    assert(!history.previous_pose(&scene, plain).morphed);
}
