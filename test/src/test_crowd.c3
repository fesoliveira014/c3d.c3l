module c3d::test::crowd;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::math::quaternion;

const float TOLERANCE @local = 1e-4f;
const uint NODE_CAPACITY @local = 32;
const Vec2 VIEWPORT @local = { 1600, 900 };
const Vec3 BONE1_OFFSET @local = { 0, 1, 0 };

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    ModelId    model;
    ClipId     swing;
    MaterialId material;
}

fn Geometry skinned_box(Allocator allocator, ushort joint) @local {
    Geometry box = geometry::box(allocator, 0.2f, 0.2f, 0.2f);
    box.joints = alloc::new_array(allocator, ushort[<4>], box.positions.len);
    box.weights = alloc::new_array(allocator, Vec4, box.positions.len);
    foreach (index, &weights : box.weights) {
        box.joints[index] = { joint, 0, 0, 0 };
        *weights = { 1, 0, 0, 0 };
    }
    return box;
}

fn NodeTemplate template_node(String name, int parent, Vec3 position) @local {
    return {
        .parent  = parent,
        .name    = name.copy(mem),
        .local   = { .position = position, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 1, 1, 1 } },
        .layers  = scene::DEFAULT_LAYERS,
        .visible = true,
    };
}

fn Fixture make_fixture(bool with_rigid = false, bool second_skeleton = false, bool without_skins = false) @local {
    Fixture fixture = {
        .assets = asset::create_asset_store(mem, {
            .max_geometries = 4,
            .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
            .max_materials  = 2,
            .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
            .max_models     = 2,
            .max_skeletons  = 2,
            .max_clips      = 2,
        }),
        .scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY }),
    };
    AssetStore* assets = &fixture.assets;
    fixture.material = assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
    GeometryId part_a;
    GeometryId part_b;
    GeometryId prop;
    @pool() {
        Geometry first = skinned_box(tmem, 0);
        part_a = assets.add_geometry(&first)!!;
        Geometry second = skinned_box(tmem, 1);
        part_b = assets.add_geometry(&second)!!;
        Geometry rigid = geometry::box(tmem, 0.1f, 0.1f, 0.1f);
        prop = assets.add_geometry(&rigid)!!;
    };

    SkeletonId[2] skeletons;
    foreach (&id : skeletons) {
        Skeleton skeleton = {
            .joint_names  = alloc::new_array(mem, String, 2),
            .parents      = alloc::new_array(mem, int, 2),
            .rest_pose    = alloc::new_array(mem, Transform, 2),
            .inverse_bind = alloc::new_array(mem, Mat4, 2),
        };
        skeleton.parents[0] = -1;
        skeleton.parents[1] = 0;
        skeleton.rest_pose[..] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[0] = matrix::IDENTITY4;
        skeleton.inverse_bind[1] = matrix::IDENTITY4.translate(-BONE1_OFFSET);
        *id = assets.add_skeleton_owned(&skeleton)!!;
    }

    float[2] times = { 0, 1 };
    Quat bent = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    float[8] values = { 0, 0, 0, 1, bent.i, bent.j, bent.k, bent.l };
    AnimationClip clip = {
        .name     = "swing".copy(mem),
        .duration = 1,
        .tracks   = alloc::new_array(mem, Track, 1),
        .targets  = alloc::new_array(mem, uint, 1),
    };
    clip.targets[0] = 2;
    clip.tracks[0] = {
        .target        = 0,
        .path          = TargetPath.ROTATION,
        .interpolation = Interpolation.LINEAR,
        .times         = alloc::new_array(mem, float, 2),
        .values        = alloc::new_array(mem, float, 8),
    };
    clip.tracks[0].times[..] = times[..];
    clip.tracks[0].values[..] = values[..];
    fixture.swing = assets.add_clip_owned(&clip)!!;

    sz node_count = with_rigid ? 6 : 5;
    ModelTemplate template = {
        .nodes  = alloc::new_array(mem, NodeTemplate, node_count),
        .meshes = alloc::new_array(mem, ModelMesh, with_rigid ? 3 : 2),
        .skins  = alloc::new_array(mem, ModelSkin, without_skins ? 0 : 2),
        .clips  = alloc::new_array(mem, ClipId, 1),
    };
    template.nodes[0] = template_node("root", -1, { 0, 0, 0 });
    template.nodes[1] = template_node("bone0", 0, { 0, 0, 0 });
    template.nodes[2] = template_node("bone1", 1, BONE1_OFFSET);
    template.nodes[3] = template_node("part_a", 0, { 0.5f, 0, 0 });
    template.nodes[4] = template_node("part_b", 1, { 0, 0, 0.5f });
    template.meshes[0] = { .node = 3, .geometry = part_a, .material = fixture.material };
    template.meshes[1] = { .node = 4, .geometry = part_b, .material = fixture.material };
    if (with_rigid) {
        template.nodes[5] = template_node("prop", 2, { 0, 0.2f, 0 });
        template.meshes[2] = { .node = 5, .geometry = prop, .material = fixture.material };
    }
    if (!without_skins) {
        foreach (index, &skin : template.skins) {
            skin.mesh_node = index == 0 ? 3 : 4;
            skin.skeleton = second_skeleton && index == 1 ? skeletons[1] : skeletons[0];
            skin.joint_nodes = alloc::new_array(mem, uint, 2);
            skin.joint_nodes[0] = 1;
            skin.joint_nodes[1] = 2;
        }
    }
    template.clips[0] = fixture.swing;
    fixture.model = assets.add_model_owned(&template)!!;
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Transform placed(Vec3 position, float yaw_degrees = 0, Vec3 scale = { 1, 1, 1 }) @local {
    return {
        .position = position,
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(yaw_degrees)),
        .scale    = scale,
    };
}

fn CrowdInstance walker(Fixture* fixture, Transform placement, float time = 0) @local {
    return {
        .placement = placement,
        .pose      = { .clip = fixture.swing, .time = time, .speed = 1, .loop = true },
        .color     = { 1, 1, 1, 1 },
    };
}

fn Aabb unit_bounds() @local => { .min = { -1, -1, -1 }, .max = { 1, 2, 1 } };

fn Node* add_crowd(Fixture* fixture, CrowdInstance[] instances, uint capacity = 4, Node* parent = null) @local {
    return model::add_crowd(
        assets:      &fixture.assets,
        scene:       &fixture.scene,
        model:       fixture.model,
        capacity:    capacity,
        pose_bounds: unit_bounds(),
        instances:   instances,
        parent:      parent,
    )!!;
}

fn InstancedMesh* part_batch(Fixture* fixture, AnimatedCrowd* crowd, usz part) @local {
    return fixture.scene.world.get(crowd.parts[part].batch, InstancedMesh);
}

fn uint live_nodes(Scene* scene) @local {
    uint count;
    foreach (&node : scene.nodes) {
        if (scene.world.is_alive(node.id)) count++;
    }
    return count;
}

fn bool near(Vec3 first, Vec3 second) @local => (first - second).length() <= TOLERANCE;

fn void test_add_crowd_creates_one_batch_per_skinned_part() @test {
    foreach (with_rigid : (bool[2]){ false, true }) {
        Fixture fixture = make_fixture(with_rigid: with_rigid);
        defer destroy_fixture(&fixture);
        Node* node = add_crowd(&fixture, {}, capacity: 4);
        AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);

        assert(crowd.parts.len == 2);
        assert(fixture.assets.model(fixture.model).data.meshes.len == (with_rigid ? 3 : 2));
        assert(crowd.palettes.len == 2 * 4);
        assert(crowd.max_tracks == 1 && crowd.cursors.len == 4);
        foreach (usz part : (usz[2]){ 0, 1 }) {
            InstancedMesh* batch = part_batch(&fixture, crowd, part);
            assert(batch.transforms.len == 4 && batch.has_bounds_override && !batch.trace);
            assert(fixture.scene.node(crowd.parts[part].batch).parent == node);
        }
    }
}

fn void test_add_crowd_rejects_invalid_models() @test {
    CrowdInstance[1] one;
    Fixture no_skin = make_fixture(without_skins: true);
    defer destroy_fixture(&no_skin);
    if (catch excuse = model::add_crowd(&no_skin.assets, &no_skin.scene, no_skin.model, 4, unit_bounds())) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    Fixture split = make_fixture(second_skeleton: true);
    defer destroy_fixture(&split);
    if (catch excuse = model::add_crowd(&split.assets, &split.scene, split.model, 4, unit_bounds())) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance foreign = walker(&fixture, maths::TRANSFORM_IDENTITY);
    foreign.pose.clip = { .index = 7, .generation = 3 };
    one[0] = foreign;
    if (catch excuse = model::add_crowd(&fixture.assets, &fixture.scene, fixture.model, 4, unit_bounds(), one[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    CrowdInstance[2] two = { walker(&fixture, maths::TRANSFORM_IDENTITY), walker(&fixture, maths::TRANSFORM_IDENTITY) };
    if (catch excuse = model::add_crowd(&fixture.assets, &fixture.scene, fixture.model, 1, unit_bounds(), two[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    fixture.assets.model(fixture.model).data.skins[1].mesh_node = 2;
    if (catch excuse = model::add_crowd(&fixture.assets, &fixture.scene, fixture.model, 4, unit_bounds())) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    fixture.assets.remove_model(fixture.model);
    if (catch excuse = model::add_crowd(&fixture.assets, &fixture.scene, fixture.model, 4, unit_bounds())) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
}

fn void test_add_crowd_undoes_a_full_node_pool() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    scene::destroy_scene(&fixture.scene);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 2 });
    uint before = live_nodes(&fixture.scene);

    if (catch excuse = model::add_crowd(&fixture.assets, &fixture.scene, fixture.model, 4, unit_bounds())) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(live_nodes(&fixture.scene) == before);
    assert(fixture.scene.count(AnimatedCrowd) == 0 && fixture.scene.count(InstancedMesh) == 0);
}

fn void test_crowd_update_matches_animator_for_every_part() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* holder = scene.add_node(name: "holder")!!;
    holder.local = placed({ 1, 0, 3 }, 45);
    Transform[2] placements = { placed({ 2, 0, 0 }, 30), placed({ -2, 0, 0 }, 30) };
    float[2] times = { 0.25f, 0.75f };
    CrowdInstance[2] instances = {
        walker(&fixture, placements[0], times[0]),
        walker(&fixture, placements[1], times[1]),
    };
    Node* node = add_crowd(&fixture, instances[..], parent: holder);
    anim::crowd_update(&fixture.assets, scene, 0);
    scene.update_world();
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);

    foreach (instance, placement : placements) {
        Node* animated = model::instantiate(&fixture.assets, scene, fixture.model, parent: holder)!!;
        animated.local = placement;
        Animator* animator = anim::add_animator(scene, animated);
        AnimationActionId action = animator.play(&fixture.assets, fixture.swing)!!;
        animator.action(action).time = times[instance];
        anim::update(&fixture.assets, scene, 0);
        scene.update_world();

        ModelInstance* reference = scene.get(animated, ModelInstance);
        foreach (usz part, mesh_node : (uint[2]){ 3, 4 }) {
            usz joint = part;
            SkinBinding* binding = scene.get(reference.nodes[mesh_node], SkinBinding);
            Mat4 inverse_bind = fixture.assets.skeleton(binding.skeleton).data.inverse_bind[joint];
            Mat4 expected = binding.joints[joint].world.mul(inverse_bind);
            Mat4 batch_world = scene.node(crowd.parts[part].batch).world;
            Mat4 crowd_world = batch_world.mul(placement.to_mat4())
                .mul(crowd.palettes[(usz)instance * crowd.joint_count + joint]);
            foreach (corner : (Vec3[2]){ { 0.1f, 0.1f, 0.1f }, { -0.1f, 0.1f, -0.1f } }) {
                assert(near(maths::transform_point(crowd_world, corner), maths::transform_point(expected, corner)));
            }
        }
    }
}

fn void test_crowd_update_wraps_looping_clip_and_holds_speed_zero() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[3] instances = {
        walker(&fixture, placed({ 0, 0, 0 }), 0.9f),
        walker(&fixture, placed({ 3, 0, 0 }), 0.5f),
        walker(&fixture, placed({ 6, 0, 0 }), 0.9f),
    };
    instances[1].pose.speed = 0;
    instances[2].pose.loop = false;
    Node* node = add_crowd(&fixture, instances[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    Mat4 frozen = crowd.palettes[crowd.joint_count + 1];

    anim::crowd_update(&fixture.assets, &fixture.scene, 0.2f);
    assert(math::abs(crowd.poses[0].time - 0.1f) <= TOLERANCE);
    assert(crowd.poses[1].time == 0.5f && crowd.palettes[crowd.joint_count + 1] == frozen);
    assert(crowd.poses[2].time == 1);
}

fn void test_set_crowd_updates_every_part() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[3] three = {
        walker(&fixture, placed({ 0, 0, 0 })),
        walker(&fixture, placed({ 3, 0, 0 })),
        walker(&fixture, placed({ 6, 0, 0 })),
    };
    Node* node = add_crowd(&fixture, three[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    CrowdInstance[1] one = { walker(&fixture, placed({ 9, 0, 0 })) };
    one[0].color = { 0, 1, 0, 1 };

    model::set_crowd(&fixture.assets, &fixture.scene, node, one[..])!!;

    assert(crowd.count == 1);
    foreach (usz part : (usz[2]){ 0, 1 }) {
        InstancedMesh* batch = part_batch(&fixture, crowd, part);
        assert(batch.count == 1 && batch.colors[0] == (Vec4){ 0, 1, 0, 1 });
        assert(batch.transforms[0].position == (Vec3){ 9, 0, 0 });
    }
}

fn void test_crowd_bounds_cover_every_placement() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[2] instances = { walker(&fixture, placed({ -5, 0, 0 })), walker(&fixture, placed({ 5, 0, 0 })) };
    Node* node = add_crowd(&fixture, instances[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);

    foreach (usz part : (usz[2]){ 0, 1 }) {
        Aabb bounds = part_batch(&fixture, crowd, part).local_bounds;
        assert(bounds.min.x <= -6 && bounds.max.x >= 6 && bounds.max.y >= 2);
    }
    crowd.placements[1].position = { 20, 0, 0 };
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    assert(part_batch(&fixture, crowd, 0).local_bounds.max.x >= 21);
}

fn MeshCandidate[] extract(Fixture* fixture, render::ExtractCounts* counts) @local {
    Node* camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera_node.local.position = { 0, 1, 20 };
    fixture.scene.update_world();
    Camera* camera = fixture.scene.get(camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, VIEWPORT);
    return render::extract_candidates(
        allocator: tmem,
        scene:     &fixture.scene,
        assets:    &fixture.assets,
        camera:    &matrices,
        layers:    scene::DEFAULT_LAYERS,
        counts:    counts,
    );
}

fn void test_crowd_candidate_variant_bits() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[1] one = { walker(&fixture, placed({ 0, 0, 0 })) };
    add_crowd(&fixture, one[..]);
    Node* plain = fixture.scene.add_instanced_mesh(
        geometry: fixture.assets.model(fixture.model).data.meshes[0].geometry,
        material: fixture.material,
        capacity: 1,
    )!!;
    fixture.scene.resize_instances(plain, 1)!!;
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);

    @pool() {
        render::ExtractCounts counts;
        MeshCandidate[] candidates = extract(&fixture, &counts);
        uint crowds;
        foreach (&candidate : candidates) {
            GeometryFlags flags = { .skinned = true };
            ShaderVariant shaded = render::candidate_vertex_variant(flags, candidate);
            ShaderVariant depth = render::candidate_vertex_variant(flags, candidate, shader::SHADER_FLAG_DEPTH_ONLY);
            ShaderVariant velocity = render::candidate_vertex_variant(flags, candidate, shader::SHADER_FLAG_VELOCITY);
            if (candidate.crowd) {
                crowds++;
                assert(shaded.flags == (shader::SHADER_FLAG_INSTANCED | shader::SHADER_FLAG_SKINNED));
                assert(depth.flags == (shaded.flags | shader::SHADER_FLAG_DEPTH_ONLY));
                assert(velocity.flags == (shaded.flags | shader::SHADER_FLAG_VELOCITY));
                GeometryFlags wide = { .skinned = true, .joints_u16 = true, .has_morphs = true };
                assert(render::candidate_vertex_variant(wide, candidate).flags & shader::SHADER_FLAG_SKINNED_U16);
            } else {
                assert(shaded.flags == shader::SHADER_FLAG_INSTANCED);
            }
        }
        assert(crowds == 2);
    };
}

fn void test_crowd_palette_pack_orders_by_parity() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[3] instances = {
        walker(&fixture, placed({ 0, 0, 0 }), 0.1f),
        walker(&fixture, placed({ 3, 0, 0 }, 0, { -1, 1, 1 }), 0.5f),
        walker(&fixture, placed({ 6, 0, 0 }), 0.9f),
    };
    Node* node = add_crowd(&fixture, instances[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    Mat4f[6] packed;
    render::pack_crowd_palettes(packed[..], crowd);

    uint[3] source_of_slot = { 0, 2, 1 };
    foreach (usz slot, source : source_of_slot) {
        for (usz joint = 0; joint < 2; joint++) {
            assert(packed[slot * 2 + joint] == bitcast(crowd.palettes[(usz)source * 2 + joint], Mat4f));
        }
    }
    assert(part_batch(&fixture, crowd, 0).mirrored_count() == 1);
}

fn void test_view_history_keeps_crowd_palettes_per_instance() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[3] instances = {
        walker(&fixture, placed({ 0, 0, 0 })),
        walker(&fixture, placed({ 3, 0, 0 })),
        walker(&fixture, placed({ 6, 0, 0 })),
    };
    Node* node = add_crowd(&fixture, instances[..], capacity: 4);
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    ViewHistory history;
    defer render::free_view_history(mem, &history);

    @pool() {
        render::ExtractCounts counts;
        MeshCandidate[] candidates = extract(&fixture, &counts);
        history.commit(
            allocator:  mem,
            assets:     &fixture.assets,
            scene:      &fixture.scene,
            candidates: candidates,
            view_proj:  matrix::IDENTITY4,
            time:       0,
        );
    };
    history.publish();

    assert(history.has_previous(&fixture.scene, node));
    PoseRecord* pose = history.previous_pose(&fixture.scene, node);
    assert(pose.palette.len == 2 * 4 && pose.instance_count == 3);
    model::set_crowd(&fixture.assets, &fixture.scene, node, instances[:2])!!;
    assert(pose.instance_count != fixture.scene.get(node, AnimatedCrowd).count);
}

fn void test_crowd_batches_never_reach_trace_instances() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[2] instances = { walker(&fixture, placed({ 0, 0, 0 })), walker(&fixture, placed({ 3, 0, 0 })) };
    Node* node = add_crowd(&fixture, instances[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    foreach (usz part : (usz[2]){ 0, 1 }) part_batch(&fixture, crowd, part).trace = true;
    Node* plain = fixture.scene.add_instanced_mesh(
        geometry: fixture.assets.model(fixture.model).data.meshes[0].geometry,
        material: fixture.material,
        capacity: 3,
    )!!;
    fixture.scene.resize_instances(plain, 3)!!;
    fixture.scene.update_world();

    @pool() {
        uint dangling;
        render::TraceInstance[] records = render::collect_trace_instances(
            allocator: tmem,
            scene:     &fixture.scene,
            assets:    &fixture.assets,
            dangling:  &dangling,
        );
        foreach (&record : records) assert(!c3d::same_id(record.entity, crowd.parts[0].batch));
        foreach (&record : records) assert(!c3d::same_id(record.entity, crowd.parts[1].batch));
    };
}

fn void test_removing_the_crowd_node_removes_its_parts() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* node = add_crowd(&fixture, {});
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    Entity[2] parts = { crowd.parts[0].batch, crowd.parts[1].batch };

    fixture.scene.remove(node);

    foreach (part : parts) assert(!fixture.scene.world.is_alive(part));
    assert(fixture.scene.count(AnimatedCrowd) == 0 && fixture.scene.count(InstancedMesh) == 0);
}

fn void test_crowd_update_marks_every_part_dirty() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CrowdInstance[2] instances = { walker(&fixture, placed({ 0, 0, 0 })), walker(&fixture, placed({ 3, 0, 0 })) };
    Node* node = add_crowd(&fixture, instances[..]);
    AnimatedCrowd* crowd = fixture.scene.get(node, AnimatedCrowd);
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    uint[2] recorded;
    foreach (usz part, &revision : recorded) *revision = part_batch(&fixture, crowd, part).revision;

    crowd.placements[1].position = { 5, 0, 0 };
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);

    foreach (usz part, revision : recorded) {
        InstancedMesh* batch = part_batch(&fixture, crowd, part);
        assert(batch.revision != revision);
        assert(batch.transforms[1].position == (Vec3){ 5, 0, 0 });
    }
}
