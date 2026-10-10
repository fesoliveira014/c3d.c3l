module c3d::test::crowd_parity;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;
import std::io::path;

const uint PARITY_INSTANCES @local = 3;
const uint PARITY_NODES @local = animated_crowd_fixtures::PARTS_NODE_COUNT + 1;
const uint PARITY_CLIPS @local = 5;
const uint PARITY_LABELS @local = 64;
const uint PARITY_ROOT @local = animated_crowd_fixtures::PARTS_JOINT_ROOT + 1;
const uint PARITY_TIP @local = animated_crowd_fixtures::PARTS_JOINT_TIP + 1;
const uint PARITY_RIGID @local = animated_crowd_fixtures::PARTS_RIGID_NODE + 1;
const uint PARITY_MORPH_A @local = animated_crowd_fixtures::PARTS_MORPH_A + 1;
const uint PARITY_MORPH_B @local = animated_crowd_fixtures::PARTS_MORPH_B + 1;

struct ActionPair @local {
    AnimationActionId crowd;
    AnimationActionId ordinary;
    uint label;
}

struct SpacePair @local {
    BlendSpace1D* crowd;
    BlendSpace1D* ordinary;
}

struct ParityRig @local {
    AssetStore assets;
    Scene scene;
    ModelId model;
    ClipId[PARITY_CLIPS] clips;
    Node* crowd_node;
    Node*[PARITY_INSTANCES] ordinary;
    CrowdInstance[PARITY_INSTANCES] seeds;
    ActionPair[PARITY_LABELS][PARITY_INSTANCES] labels;
    uint[PARITY_INSTANCES] label_count;
}

fn void assert_float_bits(float actual, float expected) @local {
    assert(bitcast(actual, uint) == bitcast(expected, uint));
}

fn void assert_vector_bits(Vec3 actual, Vec3 expected) @local {
    for (uint component = 0; component < 3; component++) assert_float_bits(actual[component], expected[component]);
}

fn void assert_rotation_bits(Quat actual, Quat expected) @local {
    for (uint component = 0; component < 4; component++) assert_float_bits(actual.v[component], expected.v[component]);
}

fn void assert_transform_bits(Transform actual, Transform expected) @local {
    assert_vector_bits(actual.position, expected.position);
    assert_rotation_bits(actual.rotation, expected.rotation);
    assert_vector_bits(actual.scale, expected.scale);
}

fn Track parity_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    Interpolation interpolation,
    float[] times,
    float[] values,
) @local {
    return {
        .target = target,
        .path = path,
        .interpolation = interpolation,
        .times = alloc::clone_slice(allocator, times),
        .values = alloc::clone_slice(allocator, values),
    };
}

fn ClipId parity_clip(
    AssetStore* assets,
    Track[] tracks,
    uint[] targets,
    float duration,
) @local {
    AnimationClip clip = {
        .duration = duration,
        .tracks = alloc::clone_slice(assets.allocator, tracks),
        .targets = alloc::clone_slice(assets.allocator, targets),
    };
    return assets.add_clip_owned(&clip)!!;
}

fn ModelId parity_model(
    AssetStore* assets,
    ModelId source,
    bool tilted,
    uint extra_nodes,
) @local {
    ModelTemplate* original = &assets.model(source).data;
    Allocator allocator = assets.allocator;
    ModelTemplate template = {
        .nodes = alloc::new_array(allocator, NodeTemplate, (sz)PARITY_NODES + extra_nodes),
        .meshes = alloc::new_array(allocator, ModelMesh, original.meshes.len),
        .skins = alloc::new_array(allocator, ModelSkin, original.skins.len),
    };
    Transform ancestor = maths::TRANSFORM_IDENTITY;
    ancestor.position = { 0.25f, 0, -0.75f };
    ancestor.scale = { 1.5f, 1.5f, 1.5f };
    ancestor.rotation = quaternion::from_axis_angle{float}(tilted ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 }, 0.3f);
    template.nodes[0] = {
        .parent = -1,
        .name = "static_ancestor".copy(allocator),
        .local = ancestor,
        .layers = scene::DEFAULT_LAYERS,
        .visible = true,
    };
    foreach (usz index, node : original.nodes) {
        node.name = node.name.copy(allocator);
        node.parent = node.parent < 0 ? 0 : node.parent + 1;
        template.nodes[index + 1] = node;
    }
    template.nodes[PARITY_ROOT].local.position = { 2, 0.2f, -1 };
    template.nodes[PARITY_ROOT].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f);
    for (uint index = PARITY_NODES; index < template.nodes.len; index++) {
        template.nodes[index] = {
            .parent = 0,
            .name = "extra".copy(allocator),
            .local = maths::TRANSFORM_IDENTITY,
            .layers = scene::DEFAULT_LAYERS,
            .visible = true,
        };
    }
    foreach (index, mesh : original.meshes) {
        mesh.node++;
        mesh.default_morph_weights = alloc::clone_slice(allocator, mesh.default_morph_weights);
        template.meshes[index] = mesh;
    }
    foreach (index, skin : original.skins) {
        skin.mesh_node++;
        skin.joint_nodes = alloc::clone_slice(allocator, skin.joint_nodes);
        foreach (&joint : skin.joint_nodes) (*joint)++;
        template.skins[index] = skin;
    }
    return assets.add_model_owned(&template)!!;
}

fn ClipId parity_motion_clip(AssetStore* assets, ModelId model, bool alternate) @local {
    Transform reference = assets.model(model).data.nodes[PARITY_ROOT].local;
    float duration = alternate ? 2 : 1;
    float[2] times = { 0, duration };
    Vec3 end = reference.position + (alternate ? (Vec3){ -0.75f, 0.4f, 1.25f } : (Vec3){ 1.5f, 0.3f, -0.5f });
    Quat rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, alternate ? -1.2f : 1.5707963f)
      .mul(reference.rotation);
    float[6] positions = { reference.position.x, reference.position.y, reference.position.z, end.x, end.y, end.z };
    float[8] rotations = {
        reference.rotation.v.x, reference.rotation.v.y, reference.rotation.v.z, reference.rotation.v.w,
        rotation.v.x, rotation.v.y, rotation.v.z, rotation.v.w,
    };
    float[6] rigid = alternate ? (float[6]){ 1, 0, 0, -0.5f, 0.7f, 0.2f } : (float[6]){ 1, 0, 0, 3, 0.4f, -0.2f };
    float[2] morph_a = alternate ? (float[2]){ 0.25f, -0.4f } : (float[2]){ 0.25f, 0.8f };
    float[2] morph_b = alternate ? (float[2]){ 0.75f, 1.25f } : (float[2]){ 0.75f, 0.1f };
    Allocator allocator = assets.allocator;
    Track[5] tracks = {
        parity_track(
            allocator: allocator,
            target: 0,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
        ),
        parity_track(
            allocator: allocator,
            target: 0,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
        parity_track(
            allocator: allocator,
            target: 1,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rigid[..],
        ),
        parity_track(
            allocator: allocator,
            target: 2,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morph_a[..],
        ),
        parity_track(
            allocator: allocator,
            target: 3,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: morph_b[..],
        ),
    };
    uint[4] targets = { PARITY_ROOT, PARITY_RIGID, PARITY_MORPH_A, PARITY_MORPH_B };
    return parity_clip(
        assets: assets,
        tracks: tracks[..],
        targets: targets[..],
        duration: duration,
    );
}

fn ClipId parity_additive_clip(AssetStore* assets, bool alternate) @local {
    float[2] times = { 0, 1 };
    float[18] translation = {
        0, 0, 0, 1, 0, 0, 2, -0.5f, 0.3f,
        -0.2f, 0.4f, 0, 2, 0.5f, -0.3f, 0, 0, 0,
    };
    Quat turn = quaternion::from_axis_angle{float}(alternate ? (Vec3){ 0, 0, 1 } : (Vec3){ 1, 0, 0 }, 0.45f);
    float[8] rotations = { 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w };
    float[6] scale = { 1, 1, 1, 1.4f, 0.8f, 1.2f };
    float[2] morph_a = { 0.25f, -0.5f };
    float[2] morph_b = { 0.75f, 1.5f };
    Allocator allocator = assets.allocator;
    Track[5] tracks = {
        parity_track(
            allocator: allocator,
            target: 0,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.CUBIC_SPLINE,
            times: times[..],
            values: translation[..],
        ),
        parity_track(
            allocator: allocator,
            target: 1,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
        parity_track(
            allocator: allocator,
            target: 0,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: scale[..],
        ),
        parity_track(
            allocator: allocator,
            target: 2,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morph_a[..],
        ),
        parity_track(
            allocator: allocator,
            target: 3,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morph_b[..],
        ),
    };
    uint[4] targets = { PARITY_RIGID, PARITY_TIP, PARITY_MORPH_A, PARITY_MORPH_B };
    return parity_clip(
        assets: assets,
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn ClipId parity_overlay_clip(AssetStore* assets) @local {
    float[3] times = { 0, 0.5f, 1 };
    Quat turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.6f);
    float[12] rotation = { 0, 0, 0, 1, -turn.v.x, -turn.v.y, -turn.v.z, -turn.v.w, 0, 0, 0, -1 };
    float[3] weights = { 0.25f, 0.9f, -0.25f };
    Allocator allocator = assets.allocator;
    Track[2] tracks = {
        parity_track(
            allocator: allocator,
            target: 0,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotation[..],
        ),
        parity_track(
            allocator: allocator,
            target: 1,
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: weights[..],
        ),
    };
    uint[2] targets = { PARITY_TIP, PARITY_MORPH_A };
    return parity_clip(
        assets: assets,
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void create_parity_rig(
    ParityRig* rig,
    Allocator allocator,
    uint event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    bool tilted = false,
    uint extra_nodes = 0,
) @local {
    rig.assets = asset::create_asset_store(allocator, {
        .max_geometries = 4, .max_materials = 1, .max_models = 8, .max_skeletons = 3, .max_clips = 32,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT, .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_environments = 1, .max_shaders = 1, .max_compute_shaders = 1, .max_fonts = 1,
    });
    rig.scene = scene::create_scene(allocator, { .max_nodes = 256 + PARITY_INSTANCES * extra_nodes });
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&rig.assets)!!;
    rig.model = parity_model(
        assets: &rig.assets,
        source: parts.mixed,
        tilted: tilted,
        extra_nodes: extra_nodes,
    );
    rig.clips[0] = parity_motion_clip(&rig.assets, rig.model, false);
    rig.clips[1] = parity_motion_clip(&rig.assets, rig.model, true);
    rig.clips[2] = parity_additive_clip(&rig.assets, false);
    rig.clips[3] = parity_additive_clip(&rig.assets, true);
    rig.clips[4] = parity_overlay_clip(&rig.assets);
    ClipEvent[2] events = { { .time = 0.25f, .id = 7 }, { .time = 0.75f, .id = 9 } };
    foreach (clip : rig.clips) rig.assets.set_clip_events(clip, events[..])!!;
    foreach (uint index, &seed : rig.seeds) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { (float)index * 3, 0, -(float)index };
        placement.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.2f * (float)index);
        placement.scale = { 2, 2, 2 };
        *seed = {
            .placement = placement,
            .pose = { .clip = rig.clips[0], .speed = 1, .loop = true },
            .color = { 0.25f * (float)(index + 1), 0.4f, 0.6f, 1 },
        };
        rig.ordinary[index] = model::instantiate(&rig.assets, &rig.scene, rig.model)!!;
        rig.ordinary[index].local = placement;
        anim::add_animator(&rig.scene, rig.ordinary[index]);
    }
    rig.crowd_node = model::add_crowd(
        assets: &rig.assets,
        scene: &rig.scene,
        model: rig.model,
        capacity: PARITY_INSTANCES,
        pose_bounds: { .min = { -100, -100, -100 }, .max = { 100, 100, 100 } },
        instances: rig.seeds[..],
        actions_per_instance: anim::MAX_ACTIONS,
        event_capacity: event_capacity,
    )!!;
    foreach (uint index, root : rig.ordinary) {
        Animator* animator = rig.scene.get(root, Animator);
        AnimationActionId ordinary = animator.play(&rig.assets, rig.clips[0])!!;
        CrowdPlayer player = parity_player(rig, index);
        rig.labels[index][0] = {
            .crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback.slots[index].base_action,
            .ordinary = ordinary,
            .label = 1,
        };
        rig.label_count[index] = 1;
    }
    anim::update(&rig.assets, &rig.scene, 0);
}

fn void destroy_parity_rig(ParityRig* rig) @local {
    scene::destroy_scene(&rig.scene);
    asset::destroy_asset_store(&rig.assets);
}

fn CrowdPlayer parity_player(ParityRig* rig, uint instance) @local {
    CrowdPlaybackState* state = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback;
    return state.player(state.instance_id(instance)!!)!!;
}

fn ActionPair parity_play(
    ParityRig* rig,
    uint instance,
    uint clip,
    uint label,
    PlayDesc desc = anim::PLAY_DESC_DEFAULT,
) @local {
    CrowdPlayer player = parity_player(rig, instance);
    Animator* animator = rig.scene.get(rig.ordinary[instance], Animator);
    ActionPair pair = {
        .crowd = player.play(&rig.assets, rig.clips[clip], desc)!!,
        .ordinary = animator.play(&rig.assets, rig.clips[clip], desc)!!,
        .label = label,
    };
    rig.labels[instance][rig.label_count[instance]++] = pair;
    return pair;
}

fn uint parity_label(ParityRig* rig, uint instance, AnimationActionId action, bool crowd) @local {
    foreach (pair : rig.labels[instance][:rig.label_count[instance]]) {
        if (c3d::same_id(crowd ? pair.crowd : pair.ordinary, action)) return pair.label;
    }
    unreachable();
}

fn void assert_action_bits(Action* actual, Action* expected) @local {
    assert(c3d::same_id(actual.clip, expected.clip));
    assert_float_bits(actual.time, expected.time);
    assert_float_bits(actual.speed, expected.speed);
    assert_float_bits(actual.weight, expected.weight);
    assert_float_bits(actual.fade_target, expected.fade_target);
    assert_float_bits(actual.fade_rate, expected.fade_rate);
    assert_float_bits(actual.published_time, expected.published_time);
    assert(bitcast(actual.previous_time, ulong) == bitcast(expected.previous_time, ulong));
    assert(bitcast(actual.clock_delta, ulong) == bitcast(expected.clock_delta, ulong));
    assert(bitcast(actual.clock_time, ulong) == bitcast(expected.clock_time, ulong));
    assert(actual.layer == expected.layer && actual.additive == expected.additive && actual.loop == expected.loop);
    assert(actual.playing == expected.playing && actual.root_motion == expected.root_motion
      && actual.root_yaw == expected.root_yaw);
    assert(actual.blend_space == expected.blend_space && actual.mask == expected.mask);
    assert(actual.reference.len == expected.reference.len && actual.cursors == expected.cursors);
    foreach (index, value : actual.reference) assert_float_bits(value, expected.reference[index]);
    assert_vector_bits(actual.root_position, expected.root_position);
    assert_rotation_bits(actual.root_rotation, expected.root_rotation);
    assert_vector_bits(actual.cycle_translation, expected.cycle_translation);
    assert_float_bits(actual.cycle_yaw, expected.cycle_yaw);
    for (uint index = 0; index < 16; index++) {
        assert_float_bits(actual.motion_basis.m[index], expected.motion_basis.m[index]);
    }
}

fn void assert_parity(ParityRig* rig, bool compare_events = true) @local {
    AnimatedCrowd* crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd);
    CrowdPlaybackState* state = crowd.playback;
    uint event_index;
    uint dropped;
    foreach (uint instance, root : rig.ordinary) {
        Animator* animator = rig.scene.get(root, Animator);
        ModelInstance* model = rig.scene.get(root, ModelInstance);
        Transform[] poses = state.poses[(usz)instance * model.nodes.len:model.nodes.len];
        foreach (usz index, actual : poses) assert_transform_bits(actual, model.present_node(index).local);
        foreach (usz mesh, node : model.mesh_nodes) {
            Mesh* component = rig.scene.get(model.present_node(node), Mesh);
            float[] actual = state.logical_weights[(usz)instance * model.mesh_nodes.len + mesh];
            assert(actual.len == component.morph_weights.len);
            foreach (index, value : actual) assert_float_bits(value, component.morph_weights[index]);
        }
        assert_vector_bits(state.slots[instance].root_motion.translation, animator.root_motion.translation);
        assert_rotation_bits(state.slots[instance].root_motion.rotation, animator.root_motion.rotation);
        assert_transform_bits(crowd.placements[instance], root.local);
        CrowdPlaybackSlot* slot = &state.slots[instance];
        assert(slot.action_count == animator.action_count && slot.root_node == animator.root_node);
        foreach (index, actual_id : slot.order[:slot.action_count]) {
            AnimationActionId expected_id = animator.order[index];
            assert(parity_label(rig, instance, actual_id, true) == parity_label(rig, instance, expected_id, false));
            assert_action_bits(slot.actions.get(actual_id), animator.action(expected_id));
        }
        foreach (space_index, actual : slot.spaces) {
            BlendSpace1D expected = animator.blend_spaces[space_index];
            assert(actual.count == expected.count);
            if (!actual.count) continue;
            assert_float_bits(actual.parameter, expected.parameter);
            assert_float_bits(actual.weight, expected.weight);
            assert_float_bits(actual.fade_target, expected.fade_target);
            assert_float_bits(actual.fade_rate, expected.fade_rate);
            assert_float_bits(actual.speed, expected.speed);
            assert(bitcast(actual.phase, ulong) == bitcast(expected.phase, ulong)
              && actual.playing == expected.playing);
            for (uint member = 0; member < actual.count; member++) {
                assert_float_bits(actual.positions[member], expected.positions[member]);
                assert(parity_label(rig, instance, actual.actions[member], true)
                  == parity_label(rig, instance, expected.actions[member], false));
            }
        }
        if (!compare_events) continue;
        assert(animator.events_dropped == 0);
        foreach (expected : animator.events[:animator.event_count]) {
            assert(event_index < state.event_count);
            CrowdEvent actual = state.events[event_index++];
            assert(actual.instance.index == instance && actual.instance.generation == slot.generation);
            assert(actual.event.id == expected.id && c3d::same_id(actual.event.clip, expected.clip));
            assert_float_bits(actual.event.time, expected.time);
            assert(parity_label(rig, instance, actual.event.action, true)
              == parity_label(rig, instance, expected.action, false));
        }
        dropped += animator.events_dropped;
    }
    if (compare_events) assert(state.event_count == event_index && state.events_dropped == dropped);
}

fn void parity_step(
    ParityRig* rig,
    TrackingAllocator* tracking,
    float dt,
    bool compare_events = true,
) @local {
    sz allocations = tracking.total_allocation_count();
    anim::update(&rig.assets, &rig.scene, dt);
    anim::crowd_update(&rig.assets, &rig.scene, dt);
    assert(tracking.total_allocation_count() == allocations);
    assert_parity(rig, compare_events);
}

fn void parity_edit(
    ParityRig* rig,
    uint instance,
    ActionPair pair,
    float time,
    float speed,
    bool loop,
    bool playing,
) @local {
    CrowdPlayer player = parity_player(rig, instance);
    Animator* animator = rig.scene.get(rig.ordinary[instance], Animator);
    Action* crowd = player.action(pair.crowd);
    Action* ordinary = animator.action(pair.ordinary);
    crowd.time = ordinary.time = time;
    crowd.speed = ordinary.speed = speed;
    crowd.loop = ordinary.loop = loop;
    crowd.playing = ordinary.playing = playing;
}

fn void parity_stop(ParityRig* rig, uint instance, ActionPair pair, float fade = 0) @local {
    CrowdPlayer player = parity_player(rig, instance);
    player.stop(pair.crowd, fade)!!;
    rig.scene.get(rig.ordinary[instance], Animator).stop(pair.ordinary, fade)!!;
}

fn void test_crowd_parity_independent_controls_clamps_reseeks_and_defaults() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_parity_rig(&rig, &tracking);
        defer destroy_parity_rig(&rig);
        assert_parity(&rig);
        ActionPair[PARITY_INSTANCES] base;
        foreach (uint instance, &pair : base) {
            *pair = rig.labels[instance][0];
            CrowdPlayer player = parity_player(&rig, instance);
            assert(player.base_action()!! == player.action(pair.crowd));
        }
        parity_edit(
            rig: &rig,
            instance: 0,
            pair: base[0],
            time: 0.125f,
            speed: 0.5f,
            loop: true,
            playing: true,
        );
        parity_edit(
            rig: &rig,
            instance: 1,
            pair: base[1],
            time: 0.6f,
            speed: 0,
            loop: true,
            playing: true,
        );
        parity_edit(
            rig: &rig,
            instance: 2,
            pair: base[2],
            time: 0.9f,
            speed: -1.25f,
            loop: false,
            playing: true,
        );
        parity_step(&rig, &tracking, 0);
        foreach (dt : (float[5]){ 0.125f, 0.375f, 0.5f, 0.25f, 0 }) parity_step(&rig, &tracking, dt);
        CrowdPlayer third = parity_player(&rig, 2);
        assert(!third.action(base[2].crowd).playing);
        parity_edit(
            rig: &rig,
            instance: 0,
            pair: base[0],
            time: 0.8f,
            speed: 1,
            loop: false,
            playing: true,
        );
        parity_edit(
            rig: &rig,
            instance: 1,
            pair: base[1],
            time: 0.45f,
            speed: -1,
            loop: true,
            playing: true,
        );
        parity_edit(
            rig: &rig,
            instance: 2,
            pair: base[2],
            time: 0.3f,
            speed: 1,
            loop: true,
            playing: false,
        );
        parity_step(&rig, &tracking, 0.5f);
        parity_edit(
            rig: &rig,
            instance: 0,
            pair: base[0],
            time: 0.1f,
            speed: 1,
            loop: true,
            playing: true,
        );
        parity_step(&rig, &tracking, 0);
        parity_step(&rig, &tracking, 3);
        parity_stop(&rig, 0, base[0]);
        parity_step(&rig, &tracking, 0);
        AnimatedCrowd* crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd);
        assert_float_bits(crowd.playback.logical_weights[2][0], 0.25f);
        assert_float_bits(crowd.playback.logical_weights[3][0], 0.75f);
    }
    assert(!tracking.has_leaks());
}

fn SpacePair parity_space(
    ParityRig* rig,
    uint instance,
    uint first_clip,
    uint second_clip,
    uint first_label,
    PlayDesc desc = anim::PLAY_DESC_DEFAULT,
) @local {
    ClipId[2] clips = { rig.clips[first_clip], rig.clips[second_clip] };
    float[2] positions = { -1, 1 };
    CrowdPlayer player = parity_player(rig, instance);
    Animator* animator = rig.scene.get(rig.ordinary[instance], Animator);
    SpacePair pair = {
        .crowd = player.add_blend_space(
            assets: &rig.assets,
            clips: clips[..],
            positions: positions[..],
            desc: desc,
        )!!,
        .ordinary = animator.add_blend_space(
            assets: &rig.assets,
            clips: clips[..],
            positions: positions[..],
            desc: desc,
        )!!,
    };
    for (uint member = 0; member < 2; member++) {
        rig.labels[instance][rig.label_count[instance]++] = {
            .crowd = pair.crowd.actions[member],
            .ordinary = pair.ordinary.actions[member],
            .label = first_label + member,
        };
    }
    positions[..] = 77;
    assert(pair.crowd.positions[0] == -1 && pair.crowd.positions[1] == 1);
    return pair;
}

fn void test_crowd_parity_four_layers_copied_masks_fades_and_additive_spaces() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_parity_rig(&rig, &tracking);
        defer destroy_parity_rig(&rig);
        ActionPair[PARITY_INSTANCES] secondary;
        ActionPair[PARITY_INSTANCES] empty;
        SpacePair[PARITY_INSTANCES] regular;
        SpacePair[PARITY_INSTANCES] additive;
        foreach (uint instance, root : rig.ordinary) {
            CrowdPlayer player = parity_player(&rig, instance);
            Animator* animator = rig.scene.get(root, Animator);
            player.base_action()!!.weight = animator.action(rig.labels[instance][0].ordinary).weight = 0.25f;
            secondary[instance] = parity_play(
                rig: &rig,
                instance: instance,
                clip: 1,
                label: 10,
            );
            player.action(secondary[instance].crowd).weight = 1.75f;
            animator.action(secondary[instance].ordinary).weight = 1.75f;
            String[4] names = { "joint_tip", "rigid_parent", "morph_a", "joint_tip" };
            JointMask mask = anim::create_joint_mask(
                allocator: mem,
                template: &rig.assets.model(rig.model).data,
                names: names[..],
                include_descendants: true,
            )!!;
            ActionPair overlay = parity_play(
                rig: &rig,
                instance: instance,
                clip: 4,
                label: 20,
                desc: { .layer = 1, .mask = &mask },
            );
            assert(player.action(overlay.crowd).mask[PARITY_TIP] && player.action(overlay.crowd).mask[PARITY_MORPH_B]);
            mask.nodes[..] = false;
            anim::destroy_joint_mask(&mask);
            assert(player.action(overlay.crowd).mask[PARITY_TIP]);
            ActionPair first_additive = parity_play(
                rig: &rig,
                instance: instance,
                clip: 2,
                label: 30,
                desc: { .layer = 2, .additive = true, .fade_in = 0.2f },
            );
            assert(player.action(first_additive.crowd).reference[0] == 1);
            ActionPair second_additive = parity_play(
                rig: &rig,
                instance: instance,
                clip: 3,
                label: 31,
                desc: { .layer = 2, .additive = true },
            );
            player.action(second_additive.crowd).weight = animator.action(second_additive.ordinary).weight = 0.35f;
            JointMask none = anim::create_joint_mask(
                allocator: mem,
                template: &rig.assets.model(rig.model).data,
                names: {},
                include_descendants: false,
            )!!;
            empty[instance] = parity_play(
                rig: &rig,
                instance: instance,
                clip: 1,
                label: 40,
                desc: { .layer = 3, .mask = &none },
            );
            anim::destroy_joint_mask(&none);
            regular[instance] = parity_space(
                rig: &rig,
                instance: instance,
                first_clip: 0,
                second_clip: 1,
                first_label: 50,
                desc: { .layer = 0 },
            );
            additive[instance] = parity_space(
                rig: &rig,
                instance: instance,
                first_clip: 2,
                second_clip: 3,
                first_label: 60,
                desc: { .layer = 3, .additive = true, .fade_in = 0.15f },
            );
            regular[instance].crowd.parameter = regular[instance].ordinary.parameter = (float)instance - 1;
            additive[instance].crowd.parameter = additive[instance].ordinary.parameter = 0.25f;
            regular[instance].crowd.speed = regular[instance].ordinary.speed = instance == 2 ? -0.75f : 1;
            additive[instance].crowd.speed = additive[instance].ordinary.speed = instance == 1 ? 0 : 0.5f;
        }
        parity_step(&rig, &tracking, 0);
        foreach (dt : (float[4]){ 0.05f, 0.1f, 0.15f, 0.2f }) parity_step(&rig, &tracking, dt);
        foreach (uint instance, root : rig.ordinary) {
            CrowdPlayer player = parity_player(&rig, instance);
            Animator* animator = rig.scene.get(root, Animator);
            ActionPair incoming = parity_play(
                rig: &rig,
                instance: instance,
                clip: 0,
                label: 70,
                desc: { .fade_in = 0.25f },
            );
            player.cross_fade(secondary[instance].crowd, incoming.crowd, 0.25f)!!;
            animator.cross_fade(secondary[instance].ordinary, incoming.ordinary, 0.25f)!!;
            parity_stop(&rig, instance, empty[instance]);
            ActionPair replacement = parity_play(
                rig: &rig,
                instance: instance,
                clip: 4,
                label: 41,
                desc: { .layer = 3, .fade_in = 0.3f },
            );
            assert(replacement.crowd.index == empty[instance].crowd.index);
            assert(player.action(replacement.crowd).weight == 0);
            regular[instance].crowd.phase = regular[instance].ordinary.phase = 0.6;
            regular[instance].crowd.parameter = regular[instance].ordinary.parameter = instance == 0 ? -5 : 5;
            regular[instance].crowd.playing = regular[instance].ordinary.playing = false;
        }
        parity_step(&rig, &tracking, 0);
        foreach (dt : (float[3]){ 0.05f, 0.1f, 0.15f }) parity_step(&rig, &tracking, dt);
        foreach (uint instance, root : rig.ordinary) {
            CrowdPlayer player = parity_player(&rig, instance);
            player.stop_blend_space(additive[instance].crowd, 0.1f)!!;
            rig.scene.get(root, Animator).stop_blend_space(additive[instance].ordinary, 0.1f)!!;
        }
        parity_step(&rig, &tracking, 0.15f);
        foreach (uint instance, root : rig.ordinary) {
            CrowdPlayer player = parity_player(&rig, instance);
            bool[1] wrong_membership = { true };
            JointMask wrong = { .nodes = wrong_membership[..] };
            uint before = rig.scene.get(root, Animator).action_count;
            assert(@catch(player.play(&rig.assets, rig.clips[4], { .mask = &wrong })) == c3d::INVALID_ARGUMENT);
            assert(@catch(rig.scene.get(root, Animator).play(&rig.assets, rig.clips[4], { .mask = &wrong }))
              == c3d::INVALID_ARGUMENT);
            assert(rig.scene.get(root, Animator).action_count == before);
        }
        String[1] missing = { "absent_joint" };
        assert(@catch(anim::create_joint_mask(
            allocator: mem,
            template: &rig.assets.model(rig.model).data,
            names: missing[..],
            include_descendants: true,
        )) == NOT_FOUND);
        parity_step(&rig, &tracking, 0);
    }
    assert(!tracking.has_leaks());
}

fn void test_crowd_parity_repeated_name_masks_reach_nodes_past_512() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_parity_rig(rig: &rig, allocator: &tracking, extra_nodes: 600);
        defer destroy_parity_rig(&rig);
        float[2] times = { 0, 1 };
        float[6] values = { 0, 0, 0, 3, 2, 1 };
        uint[1] targets = { PARITY_NODES + 599 };
        Track[1] tracks = { parity_track(
            allocator: rig.assets.allocator,
            target: 0,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[..],
        ) };
        rig.clips[4] = parity_clip(
            assets: &rig.assets,
            tracks: tracks[..],
            targets: targets[..],
            duration: 1,
        );
        String[2] names = { "extra", "extra" };
        JointMask mask = anim::create_joint_mask(
            allocator: mem,
            template: &rig.assets.model(rig.model).data,
            names: names[..],
            include_descendants: false,
        )!!;
        assert(mask.nodes.len == PARITY_NODES + 600 && mask.nodes[PARITY_NODES] && mask.nodes[targets[0]]);
        parity_play(
            rig: &rig,
            instance: 1,
            clip: 4,
            label: 99,
            desc: { .layer = 3, .mask = &mask },
        );
        anim::destroy_joint_mask(&mask);
        parity_step(&rig, &tracking, 0.5f);
        Animator* animator = rig.scene.get(rig.ordinary[1], Animator);
        ModelInstance* model = rig.scene.get(rig.ordinary[1], ModelInstance);
        assert(model.present_node(targets[0]).local.position == (Vec3){ 1.5f, 1, 0.5f });
        assert(animator.action_count == 2);
    }
    assert(!tracking.has_leaks());
}

fn void test_crowd_parity_root_modes_weighted_yaw_pivot_helper_and_reverse_loops() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_parity_rig(&rig, &tracking);
        defer destroy_parity_rig(&rig);
        ActionPair[PARITY_INSTANCES] primary;
        ActionPair[PARITY_INSTANCES] secondary;
        RootMotion[PARITY_INSTANCES] modes = { RootMotion.EXTRACT, RootMotion.STRIP_XZ, RootMotion.KEEP };
        foreach (uint instance, root : rig.ordinary) {
            parity_stop(&rig, instance, rig.labels[instance][0]);
            PlayDesc desc = { .root_motion = modes[instance], .root_yaw = instance != 2 };
            primary[instance] = parity_play(
                rig: &rig,
                instance: instance,
                clip: 0,
                label: 10,
                desc: desc,
            );
            secondary[instance] = parity_play(
                rig: &rig,
                instance: instance,
                clip: 1,
                label: 11,
                desc: desc,
            );
            CrowdPlayer player = parity_player(&rig, instance);
            Animator* animator = rig.scene.get(root, Animator);
            player.action(primary[instance].crowd).weight = animator.action(primary[instance].ordinary).weight = 0.35f;
            player.action(secondary[instance].crowd).weight = 0.8f;
            animator.action(secondary[instance].ordinary).weight = 0.8f;
            ActionPair upper = parity_play(
                rig: &rig,
                instance: instance,
                clip: 0,
                label: 20,
                desc: { .layer = 1 },
            );
            player.action(upper.crowd).weight = animator.action(upper.ordinary).weight = 0.2f;
        }
        parity_step(&rig, &tracking, 0);
        CrowdInstanceId[PARITY_INSTANCES] identities;
        foreach (uint instance, &identity : identities) {
            *identity = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback.instance_id(instance)!!;
        }
        foreach (dt : (float[6]){ 0.125f, 0.375f, 0.5f, 0.25f, 2.25f, 0 }) {
            parity_step(&rig, &tracking, dt);
            AnimatedCrowd* crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd);
            rig.scene.apply_crowd_root_motion(crowd);
            foreach (root : rig.ordinary) {
                Animator* animator = rig.scene.get(root, Animator);
                anim::apply_root_motion(root, animator.root_motion);
            }
            assert_parity(&rig);
            foreach (uint instance, identity : identities) {
                CrowdInstanceId current = crowd.playback.instance_id(instance)!!;
                assert(current.index == identity.index && current.generation == identity.generation);
            }
        }
        foreach (uint instance, root : rig.ordinary) {
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: primary[instance],
                time: 0.75f,
                speed: -1,
                loop: true,
                playing: true,
            );
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: secondary[instance],
                time: 1.25f,
                speed: -0.5f,
                loop: true,
                playing: true,
            );
        }
        parity_step(&rig, &tracking, 0);
        foreach (dt : (float[3]){ 0.125f, 0.5f, 2 }) {
            parity_step(&rig, &tracking, dt);
            rig.scene.apply_crowd_root_motion(rig.scene.get(rig.crowd_node, AnimatedCrowd));
            foreach (root : rig.ordinary) anim::apply_root_motion(root, rig.scene.get(root, Animator).root_motion);
            assert_parity(&rig);
        }
        parity_stop(&rig, 1, primary[1]);
        parity_stop(&rig, 1, secondary[1]);
        primary[1] = parity_play(
            rig: &rig,
            instance: 1,
            clip: 0,
            label: 30,
            desc: { .root_motion = RootMotion.EXTRACT },
        );
        parity_step(&rig, &tracking, 0);
        parity_step(&rig, &tracking, 0.25f);
        CrowdPlaybackState* yaw_off = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback;
        assert_rotation_bits(yaw_off.slots[1].root_motion.rotation, quaternion::IDENTITY);
        assert(yaw_off.slots[1].root_motion.translation.length() > 0);
        assert(yaw_off.poses[PARITY_NODES + PARITY_ROOT].rotation.v
          != yaw_off.base_pose[PARITY_ROOT].rotation.v);
        CrowdPlayer player = parity_player(&rig, 0);
        Animator* animator = rig.scene.get(rig.ordinary[0], Animator);
        assert(@catch(player.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.KEEP, .root_yaw = true }))
          == c3d::INVALID_ARGUMENT);
        assert(@catch(animator.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.KEEP, .root_yaw = true }))
          == c3d::INVALID_ARGUMENT);
        assert(@catch(player.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.EXTRACT, .additive = true }))
          == c3d::INVALID_ARGUMENT);
        assert(@catch(animator.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.EXTRACT, .additive = true }))
          == c3d::INVALID_ARGUMENT);
        parity_step(&rig, &tracking, 0);
    }
    {
        ParityRig rig;
        create_parity_rig(rig: &rig, allocator: &tracking, tilted: true);
        defer destroy_parity_rig(&rig);
        CrowdPlayer player = parity_player(&rig, 0);
        Animator* animator = rig.scene.get(rig.ordinary[0], Animator);
        assert(@catch(player.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.EXTRACT, .root_yaw = true }))
          == c3d::INVALID_ARGUMENT);
        assert(@catch(animator.play(&rig.assets, rig.clips[0], { .root_motion = RootMotion.EXTRACT, .root_yaw = true }))
          == c3d::INVALID_ARGUMENT);
        parity_step(&rig, &tracking, 0);
    }
    assert(!tracking.has_leaks());
}

fn void assert_event_prefix(ParityRig* rig, uint per_instance, bool reverse) @local {
    CrowdPlaybackState* state = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback;
    uint total = per_instance * PARITY_INSTANCES;
    uint retained = math::min((uint)state.events.len, total);
    assert(state.event_count == retained && state.events_dropped == total - retained);
    float[4] times = { 0, 0.25f, 0.5f, 1 };
    foreach (uint index, event : state.events[:retained]) {
        uint instance = index / per_instance;
        uint marker = index % 4;
        if (reverse) marker = 3 - marker;
        assert(event.instance.index == instance && event.instance.generation == state.slots[instance].generation);
        assert(event.event.id == marker + 10 && c3d::same_id(event.event.clip, rig.clips[0]));
        assert_float_bits(event.event.time, times[marker]);
        assert(parity_label(rig, instance, event.event.action, true) == 1);
    }
    foreach (uint instance, root : rig.ordinary) {
        Animator* animator = rig.scene.get(root, Animator);
        uint count = math::min(per_instance, anim::MAX_FIRED_EVENTS);
        assert(animator.event_count == count && animator.events_dropped == per_instance - count);
        foreach (uint index, event : animator.events[:count]) {
            uint marker = reverse ? 3 - index % 4 : index % 4;
            assert(event.id == marker + 10);
            assert_float_bits(event.time, times[marker]);
            assert(parity_label(rig, instance, event.action, false) == 1);
        }
    }
}

fn void test_crowd_parity_events_global_prefix_capacities_reset_and_saturation() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    foreach (capacity : (uint[4]){ 0, 1, anim::DEFAULT_CROWD_EVENT_CAPACITY, 2048 }) {
        ParityRig rig;
        create_parity_rig(rig: &rig, allocator: &tracking, event_capacity: capacity);
        defer destroy_parity_rig(&rig);
        ClipEvent[4] events = {
            { .time = 0, .id = 10 }, { .time = 0.25f, .id = 11 },
            { .time = 0.5f, .id = 12 }, { .time = 1, .id = 13 },
        };
        rig.assets.set_clip_events(rig.clips[0], events[..])!!;
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 400,
            compare_events: false,
        );
        assert_event_prefix(&rig, 1600, false);
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 0,
            compare_events: false,
        );
        CrowdPlaybackState* state = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback;
        assert(state.event_count == 0 && state.events_dropped == 0);
        foreach (uint instance, root : rig.ordinary) {
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: rig.labels[instance][0],
                time: 0,
                speed: -1,
                loop: true,
                playing: true,
            );
        }
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 400,
            compare_events: false,
        );
        assert_event_prefix(&rig, 1600, true);
        foreach (uint instance, root : rig.ordinary) {
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: rig.labels[instance][0],
                time: 0,
                speed: 1,
                loop: true,
                playing: false,
            );
        }
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 1,
            compare_events: false,
        );
        assert(state.event_count == 0 && state.events_dropped == 0);
        foreach (uint instance, root : rig.ordinary) {
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: rig.labels[instance][0],
                time: 0,
                speed: 1,
                loop: true,
                playing: true,
            );
        }
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 2e9f,
            compare_events: false,
        );
        assert(state.event_count == capacity && state.events_dropped == uint::max);
        foreach (root : rig.ordinary) assert(rig.scene.get(root, Animator).events_dropped == uint::max);
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 0,
            compare_events: false,
        );
        assert(state.event_count == 0 && state.events_dropped == 0);
        if (capacity == 1) {
            CrowdInstanceId old = state.instance_id(0)!!;
            model::set_crowd(
                assets: &rig.assets,
                scene: &rig.scene,
                node: rig.crowd_node,
                instances: rig.seeds[..],
            )!!;
            anim::crowd_update(&rig.assets, &rig.scene, 0.25f);
            assert(state.event_count == 1 && state.events[0].event.id == 10);
            assert(state.events_dropped == 2);
            assert(state.events[0].instance.generation != old.generation);
            assert(state.events[0].instance.generation == state.instance_id(0)!!.generation);
            assert(@catch(state.player(old)) == c3d::INVALID_ID);
        }
    }
    assert(!tracking.has_leaks());
}

fn ClipId parity_named_clip(AssetStore* assets, ModelId model, String name) @local {
    foreach (clip : assets.model(model).data.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    unreachable();
}

fn void create_quaternius_parity_rig(ParityRig* rig, Allocator allocator) @local {
    rig.assets = asset::create_asset_store(allocator, {
        .max_geometries = 8,
        .max_materials = 16,
        .max_models = 2,
        .max_skeletons = 4,
        .max_clips = 160,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT + 32,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT + 16,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
    rig.scene = scene::create_scene(allocator, { .max_nodes = 256 });
    Path source = path::tnew($$FILEPATH)!!;
    String input = (String)source.parent()!!.tappend("../../examples/assets/quaternius/AnimationLibrary_Godot.glb")!!;
    rig.model = gltf::load_model(&rig.assets, input)!!;
    rig.clips[0] = parity_named_clip(&rig.assets, rig.model, "Walk_Loop");
    rig.clips[1] = parity_named_clip(&rig.assets, rig.model, "Jog_Fwd_Loop");
    rig.clips[2] = parity_named_clip(&rig.assets, rig.model, "Idle_Loop");
    foreach (uint index, &seed : rig.seeds) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { (float)index * 3, 0, -(float)index };
        *seed = {
            .placement = placement,
            .pose = { .clip = rig.clips[0], .speed = 1, .loop = true },
            .color = { 0.3f, 0.5f, 0.7f, 1 },
        };
        rig.ordinary[index] = model::instantiate(&rig.assets, &rig.scene, rig.model)!!;
        rig.ordinary[index].local = placement;
        anim::add_animator(&rig.scene, rig.ordinary[index]);
    }
    rig.crowd_node = model::add_crowd(
        assets: &rig.assets,
        scene: &rig.scene,
        model: rig.model,
        capacity: PARITY_INSTANCES,
        pose_bounds: { .min = { -100, -100, -100 }, .max = { 100, 100, 100 } },
        instances: rig.seeds[..],
        actions_per_instance: anim::MAX_ACTIONS,
    )!!;
    foreach (uint index, root : rig.ordinary) {
        Animator* animator = rig.scene.get(root, Animator);
        AnimationActionId ordinary = animator.play(&rig.assets, rig.clips[0])!!;
        rig.labels[index][0] = {
            .crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd).playback.slots[index].base_action,
            .ordinary = ordinary,
            .label = 1,
        };
        rig.label_count[index] = 1;
    }
    anim::update(&rig.assets, &rig.scene, 0);
}

fn void test_crowd_parity_quaternius_locomotion_crossfade_and_independent_phases() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_quaternius_parity_rig(&rig, &tracking);
        defer destroy_parity_rig(&rig);
        assert_parity(&rig);
        foreach (uint instance, root : rig.ordinary) {
            ActionPair pair = rig.labels[instance][0];
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: pair,
                time: 0.15f * (float)instance,
                speed: instance == 1 ? -0.75f : instance == 2 ? 0 : 1.25f,
                loop: true,
                playing: true,
            );
        }
        parity_step(&rig, &tracking, 0);
        foreach (dt : (float[5]){ 0.125f, 0.375f, 0.5f, 0.25f, 1.75f }) parity_step(&rig, &tracking, dt);
        foreach (uint instance, root : rig.ordinary) {
            ActionPair incoming = parity_play(
                rig: &rig,
                instance: instance,
                clip: instance == 2 ? 2 : 1,
                label: 10,
                desc: { .fade_in = 0.3f },
            );
            ActionPair outgoing = rig.labels[instance][0];
            CrowdPlayer player = parity_player(&rig, instance);
            player.cross_fade(outgoing.crowd, incoming.crowd, 0.3f)!!;
            rig.scene.get(root, Animator).cross_fade(outgoing.ordinary, incoming.ordinary, 0.3f)!!;
        }
        foreach (dt : (float[4]){ 0, 0.075f, 0.125f, 0.2f }) parity_step(&rig, &tracking, dt);
        foreach (uint instance, root : rig.ordinary) {
            ActionPair current = rig.labels[instance][1];
            parity_edit(
                rig: &rig,
                instance: instance,
                pair: current,
                time: 0.1f,
                speed: -1,
                loop: true,
                playing: true,
            );
        }
        parity_step(&rig, &tracking, 0);
        parity_step(&rig, &tracking, 1.25f);
    }
    assert(!tracking.has_leaks());
}
