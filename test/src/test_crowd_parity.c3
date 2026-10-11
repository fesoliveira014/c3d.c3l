module c3d::test::crowd_parity;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;

const uint PARITY_INSTANCES @local = 3;
const uint PARITY_NODES @local = animated_crowd_fixtures::PARTS_NODE_COUNT + 1;
const uint PARITY_CLIPS @local = 2;
const uint PARITY_LABELS @local = 64;
const uint PARITY_EVENT_CAPACITY @local = 2048; // retains the first instance's 1600 crossings and part of the second's
const uint PARITY_ROOT @local = animated_crowd_fixtures::PARTS_JOINT_ROOT + 1;
const uint PARITY_RIGID @local = animated_crowd_fixtures::PARTS_RIGID_NODE + 1;
const uint PARITY_MORPH_A @local = animated_crowd_fixtures::PARTS_MORPH_A + 1;
const uint PARITY_MORPH_B @local = animated_crowd_fixtures::PARTS_MORPH_B + 1;

struct ActionPair @local {
    AnimationActionId crowd;
    AnimationActionId ordinary;
    uint label;
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

fn ModelId parity_model(AssetStore* assets, ModelId source) @local {
    ModelTemplate* original = &assets.model(source).data;
    Allocator allocator = assets.allocator;
    ModelTemplate template = {
        .nodes = alloc::new_array(allocator, NodeTemplate, PARITY_NODES),
        .meshes = alloc::new_array(allocator, ModelMesh, original.meshes.len),
        .skins = alloc::new_array(allocator, ModelSkin, original.skins.len),
    };
    Transform ancestor = maths::TRANSFORM_IDENTITY;
    ancestor.position = { 0.25f, 0, -0.75f };
    ancestor.scale = { 1.5f, 1.5f, 1.5f };
    ancestor.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f);
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

fn void create_parity_rig(
    ParityRig* rig,
    Allocator allocator,
    uint event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
) @local {
    rig.assets = asset::create_asset_store(allocator, {
        .max_geometries = 4, .max_materials = 1, .max_models = 8, .max_skeletons = 3, .max_clips = 32,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT, .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_environments = 1, .max_shaders = 1, .max_compute_shaders = 1, .max_fonts = 1,
    });
    rig.scene = scene::create_scene(allocator, { .max_nodes = 64 });
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&rig.assets)!!;
    rig.model = parity_model(&rig.assets, parts.mixed);
    rig.clips[0] = parity_motion_clip(&rig.assets, rig.model, false);
    rig.clips[1] = parity_motion_clip(&rig.assets, rig.model, true);
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
            assert(parity_label(
                rig: rig,
                instance: instance,
                action: actual_id,
                crowd: true,
            ) == parity_label(
                rig: rig,
                instance: instance,
                action: expected_id,
                crowd: false,
            ));
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
                assert(parity_label(
                    rig: rig,
                    instance: instance,
                    action: actual.actions[member],
                    crowd: true,
                )
                  == parity_label(
                      rig: rig,
                      instance: instance,
                      action: expected.actions[member],
                      crowd: false,
                  ));
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
            assert(parity_label(
                rig: rig,
                instance: instance,
                action: actual.event.action,
                crowd: true,
            )
              == parity_label(
                  rig: rig,
                  instance: instance,
                  action: expected.action,
                  crowd: false,
              ));
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

fn void test_crowd_parity_root_modes_and_weighted_yaw() @test {
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
        foreach (dt : (float[6]){ 0.125f, 0.375f, 0.5f, 0.25f, 2.25f, 0 }) {
            parity_step(&rig, &tracking, dt);
            AnimatedCrowd* crowd = rig.scene.get(rig.crowd_node, AnimatedCrowd);
            rig.scene.apply_crowd_root_motion(crowd);
            foreach (root : rig.ordinary) {
                Animator* animator = rig.scene.get(root, Animator);
                anim::apply_root_motion(root, animator.root_motion);
            }
            assert_parity(&rig);
        }
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
        assert(parity_label(
            rig: rig,
            instance: instance,
            action: event.event.action,
            crowd: true,
        ) == 1);
    }
    foreach (uint instance, root : rig.ordinary) {
        Animator* animator = rig.scene.get(root, Animator);
        uint count = math::min(per_instance, anim::MAX_FIRED_EVENTS);
        assert(animator.event_count == count && animator.events_dropped == per_instance - count);
        foreach (uint index, event : animator.events[:count]) {
            uint marker = reverse ? 3 - index % 4 : index % 4;
            assert(event.id == marker + 10);
            assert_float_bits(event.time, times[marker]);
            assert(parity_label(
                rig: rig,
                instance: instance,
                action: event.action,
                crowd: false,
            ) == 1);
        }
    }
}

fn void test_crowd_parity_events_global_prefix_reset_and_saturation() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    {
        ParityRig rig;
        create_parity_rig(rig: &rig, allocator: &tracking, event_capacity: PARITY_EVENT_CAPACITY);
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
        assert(state.event_count == PARITY_EVENT_CAPACITY && state.events_dropped == uint::max);
        foreach (root : rig.ordinary) assert(rig.scene.get(root, Animator).events_dropped == uint::max);
        parity_step(
            rig: &rig,
            tracking: &tracking,
            dt: 0,
            compare_events: false,
        );
        assert(state.event_count == 0 && state.events_dropped == 0);
        CrowdInstanceId old = state.instance_id(0)!!;
        model::set_crowd(
            assets: &rig.assets,
            scene: &rig.scene,
            node: rig.crowd_node,
            instances: rig.seeds[..],
        )!!;
        anim::crowd_update(&rig.assets, &rig.scene, 0.25f);
        assert(state.event_count == PARITY_INSTANCES && state.events_dropped == 0);
        assert(state.events[0].event.id == 10 && state.events[0].instance.generation != old.generation);
        assert(state.events[0].instance.generation == state.instance_id(0)!!.generation);
    }
    assert(!tracking.has_leaks());
}
