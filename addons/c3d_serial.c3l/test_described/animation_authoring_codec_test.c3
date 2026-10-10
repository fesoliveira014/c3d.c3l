module c3d::serial::test_described;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::asset::gltf;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

const char[] LEGACY_ANIMATOR_BINARY @local = $embed("../../../test/fixtures/animation_legacy/animator-v1.bin");
const char[] LEGACY_ANIMATOR_TEXT @local = $embed("../../../test/fixtures/animation_legacy/animator-v1.jsonc");
const char[] LEGACY_CROWD_PENDING_BINARY @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-pending.bin");
const char[] LEGACY_CROWD_PENDING_TEXT @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-pending.jsonc");
const char[] LEGACY_CROWD_PREPARED_BINARY @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-prepared.bin");
const char[] LEGACY_CROWD_PREPARED_TEXT @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-prepared.jsonc");
const char[] LEGACY_SKIN_MODEL @local = $embed("../../../test/fixtures/gltf/skin.gltf");

struct CodecBlendGrid @local {
    ClipId[anim::MAX_ACTIONS] clips;
    Vec2[anim::MAX_ACTIONS] points;
    BlendTriangle[2 * anim::MAX_ACTIONS - 5] triangles;
    uint count;
    uint triangle_count;
}

fn CodecBlendGrid codec_blend_grid(ClipId clip, uint side) @local {
    CodecBlendGrid grid = { .count = side * side };
    grid.clips[:grid.count] = clip;
    for (uint y = 0; y < side; y++) {
        for (uint x = 0; x < side; x++) grid.points[y * side + x] = { (float)x, (float)y };
    }
    for (uint y = 0; y + 1 < side; y++) {
        for (uint x = 0; x + 1 < side; x++) {
            uint first = y * side + x;
            grid.triangles[grid.triangle_count++] = { .indices = { first, first + 1, first + side } };
            grid.triangles[grid.triangle_count++] = {
                .indices = { first + 1, first + side, first + side + 1 },
            };
        }
    }
    return grid;
}

fn WeightedJointMask codec_feathered_mask(AssetStore* assets, ModelId model) @local {
    return anim::create_feathered_joint_mask(
        allocator: tmem,
        assets: assets,
        model: model,
        names: { "joint_root", "mesh" },
        weights: { 0.8f, 0.25f },
        depths: { 1, 0 },
    )!!;
}

fn void test_animation_authoring_codec_layouts_preserve_exact_legacy_shapes() @test {
    describe::register_core_values()!!;
    describe::register_reflected(ActionAuthoring)!!;
    describe::register_reflected(SpaceAuthoring)!!;
    describe::register_reflected(AnimatorAuthoring)!!;
    describe::register_reflected(CrowdInstanceAuthoringV1)!!;
    describe::register_reflected(CrowdPose)!!;
    describe::register_reflected(CrowdInstance)!!;
    describe::register_reflected(CrowdAuthoringV2)!!;
    describe::register_reflected(BlendTriangle)!!;
    describe::register_reflected(CrowdActionAuthoring)!!;
    describe::register_reflected(CrowdSpaceAuthoring)!!;
    describe::register_reflected(CrowdInstanceAuthoring)!!;
    describe::register_reflected(AnimatorAuthoringV2)!!;
    describe::register_reflected(CrowdAuthoringV3)!!;
    assert(serial::description_layout(describe::get(ActionAuthoring)!!)!! == 0xaafb7d37846979a1);
    assert(serial::description_layout(describe::get(SpaceAuthoring)!!)!! == 0x89bbbea9c64ba2b7);
    assert(serial::description_layout(describe::get(AnimatorAuthoring)!!)!! == 0xa4a3c2515a5669b4);
    assert(serial::description_layout(describe::get(CrowdInstanceAuthoringV1)!!)!! == 0xd968ade9d5937c0c);
    assert(serial::description_layout(describe::get(CrowdAuthoringV2)!!)!! == 0x73da7a68102f5e2b);
    assert(serial::description_layout(describe::get(BlendTriangle)!!)!! == 0x484666f6dc6513d7);
    assert(serial::description_layout(describe::get(CrowdActionAuthoring)!!)!! == 0x8360925cddcb7715);
    assert(serial::description_layout(describe::get(CrowdSpaceAuthoring)!!)!! == 0x4d5777ab1cce4ecc);
    assert(serial::description_layout(describe::get(CrowdInstanceAuthoring)!!)!! == 0x7320dbe867e06499);
    assert(serial::description_layout(describe::get(AnimatorAuthoringV2)!!)!! == 0x11312a6330c08681);
    assert(serial::description_layout(describe::get(CrowdAuthoringV3)!!)!! == 0x5b096137b6e8478c);
}

fn void test_animation_authoring_codec_frozen_animator_v1_restores_masks_difference_and_planar_defaults() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: LEGACY_SKIN_MODEL,
            base_dir: "",
            key: "animation_legacy/model",
        )!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        bool[4] all = { true, true, true, true };
        bool[4] upper = { false, true, true, false };
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, LEGACY_ANIMATOR_BINARY)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)LEGACY_ANIMATOR_TEXT,
                )!!;
            Animator* animator = fixture.destination.get(restored, Animator);
            assert(restored.local.position == (Vec3){ -4, 1, 6 } && restored.layers == 5);
            assert(animator.action_count == 4 && animator.root_node == 2);
            foreach (id : animator.order[:animator.action_count]) {
                Action* action = animator.action(id);
                assert(c3d::same_id(action.clip, clip) && action.weighted_mask.len == 0);
                assert(action.additive_scale == DIFFERENCE && action.time == 0);
            }
            Action* base = animator.action(animator.order[0]);
            assert(base.mask == all[..] && base.speed == -0.5f && base.weight == 0.6f);
            assert(base.root_motion == EXTRACT && base.root_yaw && !base.loop && !base.playing);
            Action* overlay = animator.action(animator.order[1]);
            assert(overlay.mask == upper[..] && overlay.additive && overlay.root_motion == KEEP);
            assert(overlay.layer == 1 && overlay.speed == 0.75f && overlay.weight == 0.25f && overlay.loop);
            BlendSpace1D* group = &animator.blend_spaces[0];
            assert(group.count == 2 && group.positions[0] == -1 && group.positions[1] == 2);
            assert(group.parameter == 0.5f && group.weight == 0.75f && group.speed == -0.25f);
            assert(group.phase == 0 && !group.playing);
            assert(c3d::same_id(group.actions[0], animator.order[2]));
            assert(c3d::same_id(group.actions[1], animator.order[3]));
            foreach (space : animator.blend_spaces_2d) assert(space.count == 0);
            assert(animator.event_count == 0 && animator.root_motion.translation == (Vec3){});
            anim::update(&fixture.assets, &fixture.destination, 0);
            assert(base.time == 0 && group.phase == 0 && animator.event_count == 0);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_animation_authoring_codec_frozen_crowd_v2_pending_and_prepared_restart_authoring() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: LEGACY_SKIN_MODEL,
            base_dir: "",
            key: "animation_legacy/model",
        )!!;
        char[][2] binaries = { LEGACY_CROWD_PENDING_BINARY, LEGACY_CROWD_PREPARED_BINARY };
        String[2] texts = { (String)LEGACY_CROWD_PENDING_TEXT, (String)LEGACY_CROWD_PREPARED_TEXT };
        assert(binaries[0] == binaries[1] && texts[0] == texts[1]);
        bool[4] all = { true, true, true, true };
        bool[4] upper = { false, true, true, false };
        foreach (variant, bytes : binaries) {
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, texts[variant])!!;
                AnimatedCrowd* crowd = fixture.destination.get(restored, AnimatedCrowd);
                assert(c3d::same_id(crowd.model, model_id) && !crowd.is_prepared() && crowd.authoring);
                assert(crowd.count == 2 && crowd.placements.len == 4);
                assert(crowd.actions_per_instance == 6 && crowd.event_capacity == 0 && crowd.trace);
                assert(restored.local.position == (Vec3){ 4, 2, -8 } && restored.layers == 9);
                assert(crowd.placements[0].scale == (Vec3){ 2, 2, 2 });
                assert(crowd.placements[1].scale == (Vec3){ -1, 2, 0.5f });
                assert(crowd.start_times[0] == 0.125f && crowd.start_times[1] == 0.25f);
                CrowdInstanceAuthoring source = crowd.authoring.instances[0];
                assert(source.configured && source.root_node == 2 && source.base_action == 0);
                assert(source.actions.len == 4 && source.spaces.len == 1);
                assert(source.actions[0].mask == all[..] && source.actions[1].mask == upper[..]);
                foreach (action : source.actions) {
                    assert(action.weighted_mask.len == 0 && action.additive_scale == DIFFERENCE);
                }
                assert(source.spaces[0].kind == ONE_DIMENSIONAL && source.spaces[0].points.len == 0);
                assert(source.spaces[0].triangles.len == 0 && source.spaces[0].parameter_2d == (Vec2){});
                assert(crowd.authoring.instances[1].configured && crowd.authoring.instances[1].actions.len == 0);
                model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
                assert(!crowd.authoring && crowd.playback.slots[0].action_count == 4);
                assert(crowd.playback.slots[1].action_count == 0);
                CrowdPlaybackSlot* slot = &crowd.playback.slots[0];
                Action* base = slot.actions.get(slot.base_action);
                assert(base.time == 0.125f && base.speed == -0.5f && base.weight == 0.6f);
                assert(base.root_motion == EXTRACT && base.root_yaw && !base.playing && !base.loop);
                assert(slot.spaces[0].count == 2 && slot.spaces[0].phase == 0);
                assert(slot.spaces[0].parameter == 0.5f && slot.spaces[0].weight == 0.75f);
                assert(slot.spaces[0].speed == -0.25f && !slot.spaces[0].playing);
                foreach (space : slot.spaces_2d) assert(space.count == 0);
                foreach (id : slot.order[:slot.action_count]) {
                    Action* action = slot.actions.get(id);
                    assert(action.weighted_mask.len == 0 && action.additive_scale == DIFFERENCE);
                }
                anim::crowd_update(&fixture.assets, &fixture.destination, 0);
                assert(base.time == 0.125f && slot.spaces[0].phase == 0);
                assert(crowd.playback.event_count == 0);
                fixture.destination.remove(restored);
            }
        }
    };
}

fn void test_animation_authoring_codec_animator_planar_groups_masks_modes_restart_and_source_purity() @test {
    foreach (side : (uint[2]){ 3, 4 }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 32);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
            Animator* animator = anim::add_animator(&fixture.source, source);
            ClipId clip = fixture.source.get(source, ModelInstance).clips[0];
            CodecBlendGrid grid = codec_blend_grid(clip, side);
            WeightedJointMask mask = codec_feathered_mask(&fixture.assets, model_id);
            BlendSpace2D* space = animator.add_blend_space_2d(
                assets: &fixture.assets,
                clips: grid.clips[:grid.count],
                coordinates: grid.points[:grid.count],
                triangles: grid.triangles[:grid.triangle_count],
                desc: { .weighted_mask = &mask, .additive = true, .additive_scale = MULTIPLICATIVE },
            )!!;
            space.parameter = { 1.25f, 1.5f };
            space.speed = -0.5f;
            if (side == 3) {
                animator.add_blend_space(&fixture.assets, { clip, clip }, { -1, 2 }, {
                    .layer = 1, .weighted_mask = &mask,
                })!!;
            }
            anim::update(&fixture.assets, &fixture.source, 0.375f);
            Action[anim::MAX_ACTIONS] before;
            foreach (index, id : animator.order[:animator.action_count]) before[index] = *animator.action(id);
            BlendSpace2D control = *space;
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
            foreach (index, id : animator.order[:animator.action_count]) {
                assert(mem::equals(&before[index], animator.action(id), Action::size));
            }
            assert(mem::equals(&control, space, BlendSpace2D::size));
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                Animator* loaded = fixture.destination.get(restored, Animator);
                assert(loaded.action_count == grid.count + (side == 3 ? 2u : 0u));
                BlendSpace2D* planar = &loaded.blend_spaces_2d[0];
                assert(planar.count == grid.count && planar.parameter == control.parameter);
                assert(planar.speed == -0.5f && planar.phase == 0 && planar.fade_rate == 0);
                assert(planar.reversed == control.reversed && planar.triangle_count == grid.triangle_count);
                assert(planar.points[:grid.count] == grid.points[:grid.count]);
                foreach (index, triangle : grid.triangles[:grid.triangle_count]) {
                    bool reversed = (planar.reversed & (1u << index)) != 0;
                    assert(planar.triangles[index].indices[0] == triangle.indices[0]);
                    assert(planar.triangles[index].indices[reversed ? 2 : 1] == triangle.indices[1]);
                    assert(planar.triangles[index].indices[reversed ? 1 : 2] == triangle.indices[2]);
                }
                foreach (id : planar.actions[:planar.count]) {
                    Action* action = loaded.action(id);
                    assert(action.weighted_mask == mask.nodes && action.weighted_mask.ptr != mask.nodes.ptr);
                    assert(action.additive_scale == MULTIPLICATIVE && action.time == 0);
                }
                if (side == 3) assert(loaded.blend_spaces[1].count == 2);
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

fn void test_animation_authoring_codec_crowd_pending_planar_and_weighted_rows_prepare_on_restore() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        CodecBlendGrid grid = codec_blend_grid(clip, 3);
        WeightedJointMask mask = codec_feathered_mask(&fixture.assets, model_id);
        CrowdActionAuthoring[9] actions;
        uint[9] members;
        foreach (uint index, &action : actions) {
            *action = {
                .clip = clip, .speed = 1, .loop = true, .additive = true,
                .weighted_mask = mask.nodes, .additive_scale = MULTIPLICATIVE,
            };
            members[index] = index;
        }
        CrowdSpaceAuthoring[1] spaces = { {
            .actions = members[..], .weight = 0.7f, .speed = -0.5f, .playing = true,
            .kind = TWO_DIMENSIONAL, .points = grid.points[:grid.count],
            .triangles = grid.triangles[:grid.triangle_count], .parameter_2d = { 1.25f, 1.5f },
        } };
        CrowdInstanceAuthoring[1] authoring = { {
            .configured = true, .root_node = 2, .base_action = uint::max,
            .actions = actions[..], .spaces = spaces[..],
        } };
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        Node* source = fixture.source.add_node(name: "planar_crowd")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            node: source,
            model: model_id,
            capacity: 2,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: seeds[..],
            actions_per_instance: 9,
            authoring: authoring[..],
        )!!;
        AnimatedCrowd* original = fixture.source.get(source, AnimatedCrowd);
        assert(!original.is_prepared());
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
            CrowdSpaceAuthoring captured = loaded.authoring.instances[0].spaces[0];
            assert(captured.kind == TWO_DIMENSIONAL && captured.points == grid.points[:grid.count]);
            assert(mem::equals(
                a: captured.triangles.ptr,
                b: grid.triangles[..].ptr,
                len: captured.triangles.len * BlendTriangle::size,
            ));
            assert(loaded.authoring.instances[0].actions[0].weighted_mask == mask.nodes);
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            assert(!loaded.authoring && loaded.playback.slots[0].action_count == 9);
            BlendSpace2D* planar = &loaded.playback.slots[0].spaces_2d[0];
            assert(planar.count == 9 && planar.parameter == (Vec2){ 1.25f, 1.5f });
            assert(planar.phase == 0 && planar.speed == -0.5f);
            foreach (id : planar.actions[:planar.count]) {
                Action* action = loaded.playback.slots[0].actions.get(id);
                assert(action.weighted_mask == mask.nodes && action.additive_scale == MULTIPLICATIVE);
            }
            fixture.destination.remove(restored);
        }
        assert(!original.is_prepared()
          && original.authoring.instances[0].spaces[0].parameter_2d == spaces[0].parameter_2d);
    };
}
