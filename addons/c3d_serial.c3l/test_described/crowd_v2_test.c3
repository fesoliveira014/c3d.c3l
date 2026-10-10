module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

const char[] CROWD_V1_BINARY @local = $embed("../../../test/fixtures/crowd_v1/crowd-v1.bin");
const char[] CROWD_V1_TEXT @local = $embed("../../../test/fixtures/crowd_v1/crowd-v1.jsonc");
const char[] CROWD_V1_MODEL @local = $embed("../../../test/fixtures/gltf/skin.gltf");

fn void test_crowd_v1_frozen_binary_and_jsonc_restore_actual_seed_starts() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: CROWD_V1_MODEL,
            base_dir: "",
            key: "crowd_codec_reference/model",
        )!!;

        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* root = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, CROWD_V1_BINARY)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)CROWD_V1_TEXT)!!;
            AnimatedCrowd* crowd = fixture.destination.get(root, AnimatedCrowd);
            assert(!crowd.is_prepared() && !crowd.authoring && root.first_child == null);
            assert(crowd.count == 3 && crowd.placements.len == 5);
            assert(crowd.actions_per_instance == 4 && crowd.event_capacity == 1024 && crowd.trace);
            assert(c3d::same_id(crowd.model, model_id));
            assert(root.local.position == (Vec3){ 4, 2, -8 } && root.layers == 9);
            assert(crowd.pose_bounds.min == (Vec3){ -3, -2, -1 });
            assert(crowd.pose_bounds.max == (Vec3){ 4, 6, 2 });
            assert(crowd.placements[0].scale == (Vec3){ -1, 1, 1 });
            assert(crowd.placements[1].scale == (Vec3){ 1, 2, 0.5f });
            assert(crowd.colors[0] == (Vec4){ 0.2f, 0.4f, 0.6f, 0.8f });
            float[3] starts = { 0.75f, 0.25f, 0.125f };
            float[3] speeds = { -0.5f, 0, 1 };
            bool[3] loops = { true, false, true };
            foreach (index, seed : crowd.seeds[:crowd.count]) {
                assert(seed.time == starts[index] && crowd.start_times[index] == starts[index]);
                assert(seed.speed == speeds[index] && seed.loop == loops[index]);
            }

            model::prepare_crowd(&fixture.assets, &fixture.destination, root)!!;
            foreach (index, slot : crowd.playback.slots[:crowd.count]) {
                Action* action = slot.actions.get(slot.base_action);
                assert(action.time == starts[index] && action.speed == speeds[index]);
                assert(action.loop == loops[index]);
            }

            assert(crowd.playback.slots[3].action_count == 0 && crowd.playback.slots[4].action_count == 0);
            anim::crowd_update(&fixture.assets, &fixture.destination, 0.25f);
            assert(crowd.playback.slots[0].actions.get(crowd.playback.slots[0].base_action).time == 0.625f);
            assert(crowd.playback.slots[1].actions.get(crowd.playback.slots[1].base_action).time == 0.25f);
            foreach (index, start : starts) assert(crowd.start_times[index] == start);
            fixture.destination.remove(root);
        }

        asset::destroy_asset_store(&fixture.assets);
        fixture.assets = asset::create_asset_store(mem, {
            .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8,
            .max_models = 1, .max_skeletons = 1, .max_clips = 1,
        });
        uint free_before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, CROWD_V1_BINARY)) == c3d::INVALID_ID);
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: (String)CROWD_V1_TEXT,
        )) == c3d::INVALID_ID);
        assert(fixture.destination.world.entities.free_count == free_before);
        assert(fixture.destination.root.first_child == null);
    };
}

fn void test_crowd_v2_pending_copies_masks_spaces_root_and_capacities() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        CrowdInstance[2] seeds = {
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = clip, .time = 0.125f, .speed = 1, .loop = true }, .color = { 1, 0, 0, 1 } },
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true }, .color = { 0, 1, 0, 1 } },
        };
        bool[4] all = { true, true, true, true };
        bool[4] upper = { false, true, true, false };
        CrowdActionAuthoring[4] actions = {
            { .clip = clip, .speed = -0.5f, .weight = 0.6f, .loop = false, .playing = false, .mask = all[..], .root_motion = EXTRACT, .root_yaw = true },
            { .clip = clip, .speed = 0.75f, .weight = 0, .layer = 1, .additive = true, .loop = true, .playing = true, .mask = upper[..] },
            { .clip = clip, .speed = 1, .weight = 0, .loop = true, .mask = all[..] },
            { .clip = clip, .speed = 1.25f, .weight = 0, .layer = 2, .additive = true, .loop = false, .mask = upper[..] },
        };
        uint[2] members = { 2, 3 };
        float[2] positions = { -1, 2 };
        CrowdSpaceAuthoring[1] spaces = { {
            .actions = members[..], .positions = positions[..], .parameter = 0.5f,
            .weight = 0.75f, .speed = -0.25f, .playing = false,
        } };
        CrowdInstanceAuthoring[2] descriptions = {
            { .configured = true, .root_node = 2, .base_action = 0, .actions = actions[..], .spaces = spaces[..] },
            { .configured = true, .root_node = anim::NO_ROOT_NODE, .base_action = uint::max },
        };
        Node* source = fixture.source.add_node(name: "rich_pending")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            node: source,
            model: model_id,
            capacity: 4,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: seeds[..],
            trace: true,
            actions_per_instance: 6,
            event_capacity: 0,
            authoring: descriptions[..],
        )!!;
        AnimatedCrowd* original = fixture.source.get(source, AnimatedCrowd);
        all[0] = false;
        members[0] = 3;
        positions[0] = -7;
        actions[0].speed = 8;
        assert(original.authoring.instances[0].actions[0].mask[0]);
        assert(original.authoring.instances[0].actions[0].speed == -0.5f);
        assert(original.authoring.instances[0].spaces[0].actions[0] == 2);
        assert(original.authoring.instances[0].spaces[0].positions[0] == -1);

        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
            assert(!loaded.is_prepared() && loaded.authoring);
            assert(loaded.actions_per_instance == 6 && loaded.event_capacity == 0);
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            assert(!loaded.authoring && loaded.playback.events.len == 0);
            CrowdPlaybackSlot* slot = &loaded.playback.slots[0];
            assert(slot.action_count == 4 && slot.actions.items.len == 6 && slot.root_node == 2);
            Action* base = slot.actions.get(slot.base_action);
            assert(base.time == 0.125f && base.speed == -0.5f && base.weight == 0.6f);
            assert(!base.loop && !base.playing && base.root_motion == EXTRACT && base.root_yaw);
            assert(base.fade_rate == 0 && base.mask[0]);
            Action* additive = slot.actions.get(slot.order[1]);
            assert(additive.time == 0 && additive.additive && additive.layer == 1 && additive.weight == 0);
            assert(additive.reference.len > 0 && !additive.mask[0] && additive.mask[2]);
            BlendSpace1D* space = &slot.spaces[0];
            assert(space.count == 2 && space.phase == 0 && space.fade_rate == 0);
            assert(space.parameter == 0.5f && space.weight == 0.75f && space.speed == -0.25f && !space.playing);
            assert(space.positions[0] == -1 && space.positions[1] == 2);
            assert(c3d::same_id(space.actions[0], slot.order[2]) && c3d::same_id(space.actions[1], slot.order[3]));
            assert(slot.actions.get(slot.order[3]).additive && slot.actions.get(slot.order[3]).layer == 2);
            assert(loaded.playback.slots[1].action_count == 0);
            assert(loaded.playback.event_count == 0 && loaded.playback.events_dropped == 0);
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_crowd_v2_prepared_fades_project_without_changing_live_state() @test {
    foreach (FadeCase kind : { FADE_IN, CROSS_FADE, FADE_OUT, SPACE_FADE, ZERO_WEIGHT, SPACE_FADE_OUT }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 32);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            ClipId clip = fixture.assets.model(model_id).data.clips[0];
            ClipEvent[6] crossings = {
                { .time = 0.0625f, .id = 1 }, { .time = 0.1f, .id = 2 },
                { .time = 0.1875f, .id = 3 }, { .time = 0.25f, .id = 4 },
                { .time = 0.3f, .id = 5 }, { .time = 0.35f, .id = 6 },
            };
            fixture.assets.set_clip_events(clip, crossings[..])!!;
            CrowdInstance[1] seed = { {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = clip, .time = 0.125f, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            } };
            Node* source = model::add_crowd(
                assets: &fixture.assets,
                scene: &fixture.source,
                model: model_id,
                capacity: 2,
                pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
                instances: seed[..],
                actions_per_instance: 6,
                event_capacity: 3,
            )!!;
            AnimatedCrowd* original = fixture.source.get(source, AnimatedCrowd);
            CrowdPlayer player = original.playback.player(original.playback.instance_id(0)!!)!!;
            CrowdPlaybackSlot* slot = &original.playback.slots[0];
            switch (kind) {
                case FADE_IN:
                    player.base_action()!!.weight = 0;
                    player.base_action()!!.fade_rate = 0.5f;
                case CROSS_FADE:
                    AnimationActionId incoming = player.play(&fixture.assets, clip, { .layer = 1 })!!;
                    player.action(incoming).speed = 1.5f;
                    player.action(incoming).weight = 0;
                    player.cross_fade(slot.base_action, incoming, 2)!!;
                case FADE_OUT:
                    player.stop(slot.base_action, 2)!!;
                case SPACE_FADE:
                    player.stop(slot.base_action)!!;
                    BlendSpace1D* space = player.add_blend_space(&fixture.assets, { clip, clip }, { 0, 1 })!!;
                    space.parameter = 0.25f;
                    space.speed = 0.5f;
                    player.fade_blend_space(space, 0.4f, 2)!!;
                case ZERO_WEIGHT:
                    player.base_action()!!.weight = 0;
                case SPACE_FADE_OUT:
                    player.stop(slot.base_action)!!;
                    BlendSpace1D* space = player.add_blend_space(&fixture.assets, { clip, clip }, { 0, 1 })!!;
                    player.stop_blend_space(space, 2)!!;
            }

            anim::crowd_update(&fixture.assets, &fixture.source, 0.25f);
            uint count = slot.action_count;
            uint generation = slot.generation;
            Action[anim::MAX_ACTIONS] action_snapshot;
            foreach (index, id : slot.order[:count]) action_snapshot[index] = *slot.actions.get(id);
            BlendSpace1D[anim::MAX_BLEND_SPACES] space_snapshot;
            space_snapshot[..] = slot.spaces[..];
            Transform[] poses = alloc::clone_slice(tmem, original.playback.poses);
            float[] weights = alloc::clone_slice(tmem, original.morph_weights);
            Mat4[] palettes = alloc::clone_slice(tmem, original.palettes);
            uint events = original.playback.event_count;
            uint dropped = original.playback.events_dropped;
            assert(events > 0 && dropped > 0);
            CrowdEvent[] event_snapshot = alloc::clone_slice(tmem, original.playback.events[:events]);
            RootMotionDelta motion = slot.root_motion;
            char[] bytes = serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
            String text = serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
            assert(slot.action_count == count && slot.generation == generation);
            foreach (index, id : slot.order[:count]) {
                assert(mem::equals(&action_snapshot[index], slot.actions.get(id), Action::size));
            }
            assert(mem::equals(&space_snapshot[0], slot.spaces.ptr, (sz)(slot.spaces.len * BlendSpace1D::size)));
            assert(mem::equals(poses.ptr, original.playback.poses.ptr, (sz)(poses.len * Transform::size)));
            assert(weights == original.morph_weights);
            assert(mem::equals(palettes.ptr, original.palettes.ptr, (sz)(palettes.len * Mat4::size)));
            assert(original.playback.event_count == events && original.playback.events_dropped == dropped);
            assert(mem::equals(&motion, &slot.root_motion, RootMotionDelta::size));
            assert(mem::equals(event_snapshot.ptr, original.playback.events.ptr, (sz)(events * CrowdEvent::size)));

            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
                assert(loaded.authoring && loaded.authoring.instances[0].configured);
                model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
                CrowdPlaybackSlot* restarted = &loaded.playback.slots[0];
                uint expected_count = kind == FADE_OUT || kind == SPACE_FADE_OUT ? 0 : (kind == SPACE_FADE ? 2 : 1);
                assert(restarted.action_count == expected_count);
                assert(loaded.start_times[0] == 0.125f);
                assert(loaded.playback.event_count == 0 && loaded.playback.events_dropped == 0);
                assert(restarted.root_motion.translation == (Vec3){ 0, 0, 0 });
                foreach (id : restarted.order[:expected_count]) {
                    Action* action = restarted.actions.get(id);
                    assert(action.fade_rate == 0 && action.clock_delta == 0);
                    float expected_start = kind == FADE_IN || kind == ZERO_WEIGHT ? 0.125f : 0;
                    assert(action.time == expected_start);
                    if (kind == ZERO_WEIGHT) assert(action.weight == 0);
                    if (kind == CROSS_FADE) assert(action.weight == 1 && action.layer == 1 && action.speed == 1.5f);
                }
                if (kind == SPACE_FADE) {
                    assert(restarted.spaces[0].count == 2 && restarted.spaces[0].phase == 0);
                    assert(restarted.spaces[0].weight == 0.4f && restarted.spaces[0].fade_rate == 0);
                }
                if (kind == CROSS_FADE || kind == SPACE_FADE || !expected_count) {
                    assert(!restarted.actions.is_live(restarted.base_action));
                }
                assert(bytes == serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                )!!);
                fixture.destination.remove(restored);
            }
        };
    }
}

fn void test_crowd_v2_owned_nested_allocations_and_failed_pending_retry_are_atomic() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        bool[4] mask = { true, true, true, true };
        CrowdActionAuthoring[2] actions = {
            { .clip = clip, .speed = 1, .weight = 0, .loop = true, .mask = mask[..] },
            { .clip = clip, .speed = 1, .weight = 0, .loop = true, .additive = true, .mask = mask[..] },
        };
        uint[2] members = { 0, 1 };
        float[2] positions = { 0, 1 };
        CrowdSpaceAuthoring[1] spaces = { {
            .actions = members[..], .positions = positions[..], .weight = 1, .speed = 1, .playing = true,
        } };
        CrowdInstanceAuthoring[1] descriptions = { {
            .configured = true, .root_node = 2, .base_action = uint::max,
            .actions = actions[..], .spaces = spaces[..],
        } };
        CrowdAuthoringV4 authoring = {
            .model = model_id, .capacity = 2,
            .pose_bounds = { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            .instances = seeds[..], .actions_per_instance = 4, .event_capacity = 0,
            .playback = descriptions[..],
        };
        Node* node = fixture.destination.add_node(name: "existing")!!;
        node.local.position = { 3, 5, 7 };
        Entity identity = node.id;
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = node };
        uint slot = ecs::assigned_slot(AnimatedCrowd)!!;
        FailingAllocator probe;
        fixture.destination.allocator = &probe;
        serial::codecs[slot].described.codec.attach(&authoring, &context)!!;
        uint allocations = probe.attempts;
        *fixture.destination.hook_allocator = &probe;
        fixture.destination.remove_component(node, AnimatedCrowd);
        *fixture.destination.hook_allocator = mem;
        assert(probe.outstanding == 0);
        fixture.destination.allocator = mem;
        for (uint failure = 1; failure <= allocations; failure++) {
            FailingAllocator failing = { .failure = failure };
            fixture.destination.allocator = &failing;
            assert(@catch(serial::codecs[slot].described.codec.attach(&authoring, &context)) == c3d::CAPACITY_EXCEEDED);
            assert(failing.outstanding == 0 && failing.attempts == failure);
            assert(!fixture.destination.has(node, AnimatedCrowd) && node.first_child == null);
            assert(c3d::same_id(node.id, identity) && node.local.position == (Vec3){ 3, 5, 7 });
            fixture.destination.allocator = mem;
        }

        serial::codecs[slot].described.codec.attach(&authoring, &context)!!;
        AnimatedCrowd* crowd = fixture.destination.get(node, AnimatedCrowd);
        CrowdAuthoringState* pending = crowd.authoring;
        FailingAllocator failing = { .failure = 1 };
        fixture.destination.allocator = &failing;
        assert(@catch(model::prepare_crowd(&fixture.assets, &fixture.destination, node)) == c3d::CAPACITY_EXCEEDED);
        fixture.destination.allocator = mem;
        assert(crowd.authoring == pending && !crowd.playback && node.first_child == null);
        assert(failing.outstanding == 0);
        assert(crowd.authoring.instances[0].actions.len == 2);
        model::prepare_crowd(&fixture.assets, &fixture.destination, node)!!;
        assert(crowd.is_prepared() && !crowd.authoring && crowd.playback.slots[0].action_count == 2);
    };
}

fn void test_crowd_v2_malformed_configuration_rejects_before_attachment() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        bool[4] mask = { true, true, true, true };
        CrowdActionAuthoring[2] actions;
        uint[2] members;
        float[2] positions;
        CrowdSpaceAuthoring[1] spaces;
        CrowdInstanceAuthoring[1] descriptions;
        Node* node = fixture.destination.add_node(name: "unchanged")!!;
        node.local.position = { 3, 5, 7 };
        uint free_before = fixture.destination.world.entities.free_count;
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = node };
        uint slot = ecs::assigned_slot(AnimatedCrowd)!!;

        for (uint malformed = 0; malformed < 18; malformed++) {
            actions[..] = {
                .clip = clip, .speed = 1, .weight = 0, .loop = true, .mask = mask[..],
            };
            members[0] = 0;
            members[1] = 1;
            positions[0] = 0;
            positions[1] = 1;
            spaces[0] = { .actions = members[..], .positions = positions[..], .weight = 1, .speed = 1 };
            descriptions[0] = {
                .configured = true, .root_node = 2, .base_action = uint::max,
                .actions = actions[..], .spaces = spaces[..],
            };
            CrowdAuthoringV4 source = {
                .model = model_id, .capacity = 2,
                .pose_bounds = { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
                .instances = seeds[..], .actions_per_instance = 4, .event_capacity = 0,
                .playback = descriptions[..],
            };
            fault expected = c3d::INVALID_ARGUMENT;
            switch (malformed) {
                case 0: actions[0].speed = bitcast(0x7f800000u, float);
                case 1: actions[0].weight = -1;
                case 2: actions[0].mask = mask[:3];
                case 3: actions[0].layer = anim::MAX_ANIMATION_LAYERS;
                case 4: actions[0].root_yaw = true;
                case 5:
                    actions[0].additive = true;
                    actions[0].root_motion = EXTRACT;
                case 6: descriptions[0].root_node = 4;
                case 7: descriptions[0].base_action = 2;
                case 8: descriptions[0].base_action = 0;
                case 9: members[1] = 0;
                case 10: members[1] = 2;
                case 11: positions[1] = 0;
                case 12: spaces[0].positions = positions[:1];
                case 13: spaces[0].weight = -1;
                case 14: spaces[0].parameter = bitcast(0x7fc00001u, float);
                case 15:
                    actions[0].clip = { .index = uint::max, .generation = 1 };
                    expected = c3d::INVALID_ID;
                case 16: descriptions[0].configured = false;
                case 17:
                    source.actions_per_instance = 1;
                    expected = c3d::CAPACITY_EXCEEDED;
            }

            assert(@catch(serial::codecs[slot].described.codec.attach(&source, &context)) == expected);
            assert(!fixture.destination.has(node, AnimatedCrowd) && node.first_child == null);
            assert(fixture.destination.world.entities.free_count == free_before);
            assert(node.local.position == (Vec3){ 3, 5, 7 } && node.name == "unchanged");
        }
    };
}

fn void test_crowd_v2_rich_preparation_retries_every_allocation_and_pending_set_replaces_config() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        bool[4] mask = { true, true, true, true };
        CrowdActionAuthoring[1] actions = { {
            .clip = clip, .speed = 1, .weight = 1, .loop = true, .playing = true,
            .additive = true, .mask = mask[..],
        } };
        CrowdInstanceAuthoring[1] descriptions = { {
            .configured = true, .root_node = 2, .base_action = uint::max, .actions = actions[..],
        } };
        FailingAllocator retry_allocator;
        Scene retry = scene::create_scene(&retry_allocator, { .max_nodes = 32 });
        Node* root = retry.add_node(name: "retry")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &retry,
            node: root,
            model: model_id,
            capacity: 3,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: seeds[..],
            authoring: descriptions[..],
        )!!;
        AnimatedCrowd* crowd = retry.get(root, AnimatedCrowd);
        CrowdAuthoringState* pending = crowd.authoring;
        uint outstanding = retry_allocator.outstanding;
        uint free_before = retry.world.entities.free_count;
        bool succeeded;
        uint failure_count;
        for (uint allowance = 1; allowance <= 160; allowance++) {
            retry_allocator.failure = retry_allocator.attempts + allowance;
            if (catch excuse = model::prepare_crowd(&fixture.assets, &retry, root)) {
                retry_allocator.failure = 0;
                assert(excuse == c3d::CAPACITY_EXCEEDED);
                assert(retry_allocator.outstanding == outstanding);
                assert(crowd.authoring == pending && !crowd.playback && !crowd.parts.len && root.first_child == null);
                assert(retry.world.entities.free_count == free_before && crowd.start_times[0] == 0.25f);
                failure_count++;
            } else {
                retry_allocator.failure = 0;
                succeeded = true;
                break;
            }
        }
        assert(succeeded && failure_count > 10 && !crowd.authoring);
        assert(crowd.playback.slots[0].action_count == 1);
        assert(crowd.playback.slots[0].actions.get(crowd.playback.slots[0].order[0]).additive);
        scene::destroy_scene(&retry);
        assert(retry_allocator.outstanding == 0);

        root = fixture.destination.add_node(name: "pending_replace")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.destination,
            node: root,
            model: model_id,
            capacity: 3,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: seeds[..],
            authoring: descriptions[..],
        )!!;
        crowd = fixture.destination.get(root, AnimatedCrowd);
        pending = crowd.authoring;
        ClipId saved = seeds[0].pose.clip;
        seeds[0].pose.clip = { .index = uint::max, .generation = 1 };
        assert(@catch(model::set_crowd(
            assets: &fixture.assets,
            scene: &fixture.destination,
            node: root,
            instances: seeds[..],
        )) == c3d::INVALID_ID);
        assert(crowd.authoring == pending && crowd.start_times[0] == 0.25f);
        seeds[0].pose.clip = saved;
        seeds[0].pose.time = 0.5f;
        model::set_crowd(
            assets: &fixture.assets,
            scene: &fixture.destination,
            node: root,
            instances: seeds[..],
        )!!;
        assert(!crowd.authoring && crowd.start_times[0] == 0.5f);
        model::prepare_crowd(&fixture.assets, &fixture.destination, root)!!;
        Action* base = crowd.playback.slots[0].actions.get(crowd.playback.slots[0].base_action);
        assert(!base.additive && base.time == 0.5f);
    };
}

fn void test_crowd_v2_compatible_external_clip_keys_restore_and_malformed_reads_roll_back() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32, 2);
        defer destroy_fixture(&fixture);
        asset::destroy_asset_store(&fixture.assets);
        fixture.assets = asset::create_asset_store(mem, {
            .max_geometries = 4, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
            .max_models = 2, .max_skeletons = 2, .max_clips = 2,
        });
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: CROWD_V1_MODEL,
            base_dir: "",
            key: "crowd_codec/owner",
        )!!;
        ModelId external_model = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: CROWD_V1_MODEL,
            base_dir: "",
            key: "crowd_codec/external",
        )!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        ClipId external = fixture.assets.model(external_model).data.clips[0];
        assert(!c3d::same_id(clip, external));
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        bool[4] mask = { true, true, true, true };
        uint speed_bits = 0xbf912345;
        CrowdActionAuthoring[1] actions = { {
            .clip = external, .speed = bitcast(speed_bits, float), .weight = 0.6f,
            .loop = true, .playing = true, .mask = mask[..],
        } };
        CrowdInstanceAuthoring[1] descriptions = { {
            .configured = true, .root_node = 2, .base_action = uint::max, .actions = actions[..],
        } };
        Node* source = fixture.source.add_node(name: "external")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            node: source,
            model: model_id,
            capacity: 2,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: seeds[..],
            authoring: descriptions[..],
        )!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
            assert(c3d::same_id(loaded.authoring.instances[0].actions[0].clip, external));
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            CrowdPlaybackSlot* slot = &loaded.playback.slots[0];
            Action* action = slot.actions.get(slot.order[0]);
            assert(c3d::same_id(action.clip, external) && bitcast(action.speed, uint) == speed_bits);
            assert(action.time == 0 && !slot.actions.is_live(slot.base_action));
            fixture.destination.remove(restored);
        }

        usz offset;
        uint matches;
        for (usz index = 0; index + uint::size <= bytes.len; index++) {
            Reader reader = serial::reader_over(bytes[index:uint::size]);
            if (reader.read_uint()!! == speed_bits) {
                offset = index;
                matches++;
            }
        }
        assert(matches == 1);
        char[] corrupted = alloc::clone_slice(tmem, bytes);
        Writer patch = serial::writer_over(corrupted[offset:uint::size]);
        patch.write_uint(0x7f800000);
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint nodes = member(&document, 0, "nodes");
        uint components = member(&document, nodes + 1, "components");
        uint saved = member(&document, components, "c3d.AnimatedCrowd");
        uint value = member(&document, saved, "value");
        uint playback = member(&document, value, "playback");
        uint serialized_actions = member(&document, playback + 1, "actions");
        uint speed = member(&document, serialized_actions + 1, "speed");
        String corrupted_text = replace_token(text, document.values[speed], `"f32:7f800000"`);
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        existing.local.position = { 3, 5, 7 };
        uint free_before = fixture.destination.world.entities.free_count;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node*? result = encoding == 0
              ? serial::read_subtree(
                  scene: &fixture.destination,
                  assets: &fixture.assets,
                  bytes: corrupted,
                  options: options,
              )
              : serial::read_subtree_text(
                  scene: &fixture.destination,
                  assets: &fixture.assets,
                  text: corrupted_text,
                  options: options,
              );
            assert(@catch(result) == c3d::INVALID_ARGUMENT);
            assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == "c3d.AnimatedCrowd");
            assert(fixture.destination.world.entities.free_count == free_before);
            assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
            assert(existing.local.position == (Vec3){ 3, 5, 7 });
        }

        uint serialized_clip = member(&document, serialized_actions + 1, "clip");
        String missing_text = replace_token(text, document.values[serialized_clip], `"crowd_codec/missing"`);
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: missing_text,
        )) == c3d::INVALID_ID);
        assert(fixture.destination.world.entities.free_count == free_before);
    };
}
