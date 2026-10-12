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

const char[] MOTION_CODEC_LEGACY_MODEL @local = $embed("../../../test/fixtures/gltf/skin.gltf");
const char[] MOTION_CODEC_ANIMATOR_V1 @local
  = $embed("../../../test/fixtures/animation_legacy/animator-v1.bin");
const char[] MOTION_CODEC_ANIMATOR_V1_TEXT @local
  = $embed("../../../test/fixtures/animation_legacy/animator-v1.jsonc");
const char[] MOTION_CODEC_CROWD_V2 @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-pending.bin");
const char[] MOTION_CODEC_CROWD_V2_TEXT @local
  = $embed("../../../test/fixtures/animation_legacy/crowd-v2-pending.jsonc");

const char[] MOTION_CODEC_ANIMATOR_V2 @local
  = $embed("../../../test/fixtures/animation_authoring_legacy/animator-v2.bin");
const char[] MOTION_CODEC_ANIMATOR_V2_TEXT @local
  = $embed("../../../test/fixtures/animation_authoring_legacy/animator-v2.jsonc");
const char[] MOTION_CODEC_CROWD_V3_PENDING @local
  = $embed("../../../test/fixtures/animation_authoring_legacy/crowd-v3-pending.bin");
const char[] MOTION_CODEC_CROWD_V3_PENDING_TEXT @local
  = $embed("../../../test/fixtures/animation_authoring_legacy/crowd-v3-pending.jsonc");

fn RootExtractionDesc motion_codec_extraction() @local {
    return {
        .generalized = true,
        .translation_axes = { true, false, true },
        .up = { 0.6f, 0.8f, 0 },
        .twist = true,
    };
}

fn void assert_motion_codec_extraction(RootExtractionDesc actual, RootExtractionDesc expected) @local {
    assert(actual.generalized == expected.generalized);
    assert(actual.translation_axes == expected.translation_axes);
    assert(actual.up == expected.up && actual.twist == expected.twist);
}

fn void assert_motion_codec_empty_history(InertialStorage* storage, uint capacity) @local {
    assert(storage && storage.rows.len == capacity);
    foreach (row : storage.rows) {
        assert(!row.control.history_valid && !row.control.active && row.control.elapsed == 0);
        assert(!row.root.target_rate_pending && row.velocity[0].translation == (double[<3>]){});
    }
}

fn char[] motion_codec_history(InertialStorage* storage) @local {
    InertialRow* row = &storage.rows[0];
    usz bytes = anim::inertial_storage_bytes(row.previous_pose.len, row.previous_morph.len, storage.rows.len);
    return ((char*)storage)[:bytes];
}

fn Node* motion_codec_crowd(Fixture* fixture, ModelId model_id, bool prepared) @local {
    ClipId clip = fixture.assets.model(model_id).data.clips[0];
    bool[4] all = { true, true, true, true };
    CrowdActionAuthoring[1] actions = { {
        .clip = clip,
        .speed = 0.5f,
        .weight = 0.75f,
        .loop = true,
        .playing = true,
        .mask = all[..],
        .root_motion = EXTRACT,
        .extraction = motion_codec_extraction(),
    } };
    CrowdInstanceAuthoring[1] authoring = { {
        .configured = true,
        .root_node = 2,
        .base_action = 0,
        .actions = actions[..],
    } };
    Node* owner = fixture.source.add_node(name: "motion_codec_crowd")!!;
    model::attach_crowd(
        assets: &fixture.assets,
        scene: &fixture.source,
        node: owner,
        model: model_id,
        capacity: 3,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.125f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } },
        actions_per_instance: 4,
        authoring: authoring[..],
    )!!;
    fixture.source.get(owner, AnimatedCrowd).inertia_enabled = true;
    if (prepared) model::prepare_crowd(&fixture.assets, &fixture.source, owner)!!;
    return owner;
}

fn void test_animation_motion_codec_versions_keep_earlier_layouts_and_new_defaults() @test {
    serial::register_core_codecs()!!;
    assert(serial::description_layout(describe::get(CrowdActionAuthoringV2)!!)!! == 0x8360925cddcb7715);
    assert(serial::description_layout(describe::get(CrowdInstanceAuthoringV2)!!)!! == 0x7320dbe867e06499);
    assert(serial::description_layout(describe::get(AnimatorAuthoringV2)!!)!! == 0x11312a6330c08681);
    assert(serial::description_layout(describe::get(CrowdAuthoringV3)!!)!! == 0x5b096137b6e8478c);
    assert(serial::codecs[ecs::assigned_slot(Animator)!!].codec.version == 3);
    assert(serial::codecs[ecs::assigned_slot(AnimatedCrowd)!!].codec.version == 4);
    RootExtractionDesc extraction;
    serial::described_type(RootExtractionDesc)!!.defaults(&extraction);
    assert_motion_codec_extraction(extraction, {});
    AnimatorAuthoringV3 animator;
    serial::described_type(AnimatorAuthoringV3)!!.defaults(&animator);
    assert(!animator.inertia_enabled && animator.root_node == anim::NO_ROOT_NODE);
    CrowdAuthoringV4 crowd;
    serial::described_type(CrowdAuthoringV4)!!.defaults(&crowd);
    assert(!crowd.inertia_enabled && crowd.capacity == 1);
}

fn void test_animation_motion_codec_animator_active_and_interrupted_export_preserves_source_and_restarts() @test {
    foreach (interrupted : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 32);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            ClipId clip = fixture.assets.model(model_id).data.clips[0];
            Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
            Animator* original = anim::add_animator(&fixture.source, source, { .inertia_enabled = true });
            original.root_node = 2;
            original.play(&fixture.assets, clip, {
                .root_motion = EXTRACT,
                .extraction = motion_codec_extraction(),
            })!!;
            anim::update(&fixture.assets, &fixture.source, 0.2f);
            anim::update(&fixture.assets, &fixture.source, 0.2f);
            AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
            targets[0].clip = clip;
            targets[0].start_time = 0.75f;
            targets[0].speed = 0.5f;
            targets[0].weight = 0.75f;
            targets[0].play = { .root_motion = EXTRACT, .extraction = motion_codec_extraction() };
            original.inertialize(&fixture.assets, { .duration = 0.8f, .actions = targets[..] })!!;
            anim::update(&fixture.assets, &fixture.source, 0.125f);
            if (interrupted) {
                targets[0].start_time = 0.1f;
                original.inertialize(&fixture.assets, { .duration = 0.6f, .actions = targets[..] })!!;
                anim::update(&fixture.assets, &fixture.source, 0.0625f);
            }
            InertialStorage* storage = original.inertial_storage;
            assert(storage.rows[0].control.active && storage.rows[0].control.history_valid);
            char[] history = alloc::clone_slice(tmem, motion_codec_history(storage));
            Action before = *original.action(original.order[0]);
            Transform[] pose = alloc::clone_slice(tmem, original.pose_storage.destination.pose);
            float[] morph = alloc::new_array(tmem, float, storage.rows[0].previous_morph.len);
            anim::read_inertial_morphs(original.pose_storage.destination.morph_weights, morph);
            char[] bytes = fixture_bytes(&fixture, source);
            String text = fixture_text(&fixture, source);
            assert(mem::equals(motion_codec_history(storage), history));
            assert(mem::equals(&before, original.action(original.order[0]), Action::size));
            assert(mem::equals(original.pose_storage.destination.pose, pose));
            float[] morph_after = alloc::new_array(tmem, float, storage.rows[0].previous_morph.len);
            anim::read_inertial_morphs(original.pose_storage.destination.morph_weights, morph_after);
            assert(morph_after == morph);
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                Animator* loaded = fixture.destination.get(restored, Animator);
                assert_motion_codec_empty_history(loaded.inertial_storage, 1);
                assert(loaded.action_count == 1 && loaded.root_node == 2 && loaded.event_count == 0);
                Action* action = loaded.action(loaded.order[0]);
                assert_motion_codec_extraction(action.extraction, motion_codec_extraction());
                assert(action.root_motion == EXTRACT && action.time == 0 && action.speed == 0.5f);
                assert(action.weight == 0.75f && action.motion_chain);
                Node* reference = model::instantiate(&fixture.assets, &fixture.destination, model_id)!!;
                Animator* expected = anim::add_animator(
                    &fixture.destination, reference, { .inertia_enabled = true });
                expected.root_node = 2;
                AnimationActionId reference_id = expected.play(
                    assets: &fixture.assets,
                    clip: clip,
                    desc: {
                        .root_motion = EXTRACT,
                        .extraction = motion_codec_extraction(),
                    },
                )!!;
                expected.action(reference_id).speed = 0.5f;
                expected.action(reference_id).weight = 0.75f;
                foreach (float step : { 0.0f, 0.125f, 0.25f }) {
                    anim::update(&fixture.assets, &fixture.destination, step);
                    assert_model_pose(&fixture.destination, restored, reference);
                }
                fixture.destination.remove(reference);
                fixture.destination.remove(restored);
            }
        };
    }
}

fn void test_animation_motion_codec_pending_and_prepared_crowd_restart_enabled_storage_and_authored_start() @test {
    foreach (prepared : (bool[2]){ false, true }) {
        foreach (interrupted : (bool[2]){ false, true }) {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture, 32);
                defer destroy_fixture(&fixture);
                serial::register_core_codecs()!!;
                ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
                Node* source = motion_codec_crowd(&fixture, model_id, prepared);
                AnimatedCrowd* original = fixture.source.get(source, AnimatedCrowd);
                Action before;
                char[] history;
                Transform[] poses;
                if (prepared) {
                    anim::crowd_update(&fixture.assets, &fixture.source, 0.2f);
                    anim::crowd_update(&fixture.assets, &fixture.source, 0.2f);
                    CrowdPlayer player = original.playback.player(original.playback.instance_id(0)!!)!!;
                    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
                    targets[0].clip = fixture.assets.model(model_id).data.clips[0];
                    targets[0].start_time = 0.75f;
                    targets[0].speed = 0.5f;
                    targets[0].weight = 0.75f;
                    targets[0].play = { .root_motion = EXTRACT, .extraction = motion_codec_extraction() };
                    player.inertialize(&fixture.assets, { .duration = 0.8f, .actions = targets[..] })!!;
                    anim::crowd_update(&fixture.assets, &fixture.source, 0.125f);
                    if (interrupted) {
                        targets[0].start_time = 0.1f;
                        player.inertialize(&fixture.assets, { .duration = 0.6f, .actions = targets[..] })!!;
                        anim::crowd_update(&fixture.assets, &fixture.source, 0.0625f);
                    }
                    InertialStorage* storage = original.playback.inertial_storage;
                    assert(storage.rows[0].control.active && storage.rows[0].control.history_valid);
                    history = alloc::clone_slice(tmem, motion_codec_history(storage));
                    poses = alloc::clone_slice(tmem, original.playback.poses);
                    before = *original.playback.slots[0].actions.get(original.playback.slots[0].base_action);
                }
                char[] bytes = fixture_bytes(&fixture, source);
                String text = fixture_text(&fixture, source);
                if (prepared) {
                    InertialStorage* storage = original.playback.inertial_storage;
                    assert(mem::equals(motion_codec_history(storage), history));
                    assert(mem::equals(original.playback.poses, poses));
                    Action* action = original.playback.slots[0].actions.get(original.playback.slots[0].base_action);
                    assert(mem::equals(&before, action, Action::size));
                } else {
                    assert(original.authoring && !original.is_prepared());
                    assert_motion_codec_extraction(
                        actual: original.authoring.instances[0].actions[0].extraction,
                        expected: motion_codec_extraction(),
                    );
                }
                for (uint encoding = 0; encoding < 2; encoding++) {
                    Node* restored = encoding == 0
                      ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                      : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                    AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
                    assert(loaded.inertia_enabled && !loaded.is_prepared() && loaded.authoring);
                    CrowdInstanceAuthoring authored = loaded.authoring.instances[0];
                    assert(authored.actions.len == 1 && authored.base_action == 0 && authored.root_node == 2);
                    assert_motion_codec_extraction(authored.actions[0].extraction, motion_codec_extraction());
                    model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
                    assert_motion_codec_empty_history(loaded.playback.inertial_storage, 3);
                    Action* action = loaded.playback.slots[0].actions.get(loaded.playback.slots[0].base_action);
                    assert(action.time == 0.125f && action.speed == 0.5f && action.weight == 0.75f);
                    assert_motion_codec_extraction(action.extraction, motion_codec_extraction());
                    assert(action.motion_chain && loaded.playback.event_count == 0);
                    fixture.destination.remove(restored);
                }
            };
        }
    }
}

fn usz motion_codec_word_offset(char[] bytes, uint word) @local {
    usz found;
    uint count;
    for (usz offset = 0; offset + uint::size <= bytes.len; offset++) {
        Reader reader = serial::reader_over(bytes[offset:uint::size]);
        if (reader.read_uint()!! != word) continue;
        found = offset;
        count++;
    }
    assert(count == 1);
    return found;
}

fn void test_animation_motion_codec_malformed_up_binary_and_text_fail_atomically_for_both_owners() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 32);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            Node* source;
            if (crowded) {
                source = motion_codec_crowd(&fixture, model_id, false);
            } else {
                source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
                Animator* animator = anim::add_animator(&fixture.source, source, { .inertia_enabled = true });
                animator.root_node = 2;
                animator.play(
                    assets: &fixture.assets,
                    clip: fixture.assets.model(model_id).data.clips[0],
                    desc: {
                        .root_motion = EXTRACT,
                        .extraction = motion_codec_extraction(),
                    },
                )!!;
            }
            char[] bytes = fixture_bytes(&fixture, source);
            String text = fixture_text(&fixture, source);
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
            String type_name = crowded ? "c3d.AnimatedCrowd" : "c3d.Animator";
            uint saved = member(&document, components, type_name);
            uint value = member(&document, saved, "value");
            uint owner = crowded ? member(&document, value, "playback") + 1 : value;
            uint actions = member(&document, owner, "actions");
            uint extraction = member(&document, actions + 1, "extraction");
            uint up = member(&document, extraction, "up");
            usz offset = motion_codec_word_offset(bytes, bitcast(0.6f, uint));
            ReadOptions options = serial::READ_OPTIONS_DEFAULT;
            options.diagnostic = &diagnostic;
            uint free_before = fixture.destination.world.entities.free_count;
            char[] malformed = alloc::clone_slice(tmem, bytes);
            Writer patch = serial::writer_over(malformed[offset:uint::size]);
            patch.write_uint(bitcast(2.0f, uint));
            String malformed_text = replace_token(text, document.values[up], "[2,0.8,0]");
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node*? result = encoding == 0
                  ? serial::read_subtree(
                        scene: &fixture.destination,
                        assets: &fixture.assets,
                        bytes: malformed,
                        options: options,
                    )
                  : serial::read_subtree_text(
                        scene: &fixture.destination,
                        assets: &fixture.assets,
                        text: malformed_text,
                        options: options,
                    );
                assert(@catch(result) == c3d::INVALID_ARGUMENT);
                assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == type_name);
                assert(fixture.destination.world.entities.free_count == free_before);
                assert(fixture.destination.root.first_child == null);
                assert(fixture.destination.count(Animator) == 0 && fixture.destination.count(AnimatedCrowd) == 0);
            }
        };
    }
}

fn void test_animation_motion_codec_frozen_original_readers_default_to_planar_and_disabled_history() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: MOTION_CODEC_LEGACY_MODEL,
            base_dir: "",
            key: "animation_legacy/model",
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, MOTION_CODEC_ANIMATOR_V1)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)MOTION_CODEC_ANIMATOR_V1_TEXT,
                )!!;
            Animator* animator = fixture.destination.get(restored, Animator);
            assert(!animator.inertial_storage && animator.action_count == 4);
            foreach (id : animator.order[:animator.action_count]) {
                assert_motion_codec_extraction(animator.action(id).extraction, {});
            }
            fixture.destination.remove(restored);
            restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, MOTION_CODEC_CROWD_V2)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)MOTION_CODEC_CROWD_V2_TEXT,
                )!!;
            AnimatedCrowd* crowd = fixture.destination.get(restored, AnimatedCrowd);
            assert(!crowd.inertia_enabled && !crowd.is_prepared());
            foreach (instance : crowd.authoring.instances) {
                foreach (action : instance.actions) assert_motion_codec_extraction(action.extraction, {});
            }
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            assert(!crowd.playback.inertial_storage);
            fixture.destination.remove(restored);
        }
    };
}

fn void assert_motion_codec_legacy_planar(PlaybackView* playback, ClipId clip) @local {
    bool[4] all = { true, true, true, true };
    float[4] weights = { 0.25f, 0, 0.5f, 0.75f };
    assert(*playback.action_count == 4 && playback.root_node == 2);
    Action* base = playback.actions.get(playback.order[0]);
    assert(c3d::same_id(base.clip, clip) && base.root_motion == EXTRACT && base.root_yaw);
    assert(base.speed == -0.5f && base.weight == 0.6f && !base.loop && !base.playing);
    assert(base.mask == all[..]);
    assert(base.weighted_mask.len == 0 && base.motion_chain == null);
    assert_motion_codec_extraction(base.extraction, {});
    BlendSpace2D* planar = &playback.blend_spaces_2d[0];
    assert(planar.count == 3 && planar.triangle_count == 1 && planar.phase == 0);
    assert(planar.parameter == (Vec2){ 0.5f, 0.25f } && planar.weight == 0.75f);
    assert(planar.speed == -0.25f && !planar.playing);
    assert(planar.points[0] == (Vec2){ -1, -1 });
    assert(planar.points[1] == (Vec2){ 2, -1 } && planar.points[2] == (Vec2){ -1, 2 });
    assert(planar.triangles[0].indices[0] == 2);
    assert(planar.triangles[0].indices[1] == 1 && planar.triangles[0].indices[2] == 0);
    foreach (member, id : planar.actions[:planar.count]) {
        assert(c3d::same_id(id, playback.order[member + 1]));
        Action* action = playback.actions.get(id);
        assert(c3d::same_id(action.clip, clip) && action.additive && action.layer == 1);
        assert(action.weighted_mask == weights[..]);
        assert(action.additive_scale == MULTIPLICATIVE && action.time == 0);
        assert(action.mask == all[..]);
        assert_motion_codec_extraction(action.extraction, {});
    }
}

fn void test_animation_motion_codec_frozen_weighted_planar_versions_default_disabled_inertia_and_preserve_authoring() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model_memory(
            assets: &fixture.assets,
            bytes: MOTION_CODEC_LEGACY_MODEL,
            base_dir: "",
            key: "animation_authoring_legacy/model",
        )!!;
        ClipId clip = fixture.assets.model(model_id).data.clips[0];
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, MOTION_CODEC_ANIMATOR_V2)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)MOTION_CODEC_ANIMATOR_V2_TEXT,
                )!!;
            Animator* animator = fixture.destination.get(restored, Animator);
            assert(!animator.inertial_storage && restored.layers == 5);
            assert(restored.local.position == (Vec3){ -4, 1, 6 });
            PlaybackView playback = animator.playback();
            assert_motion_codec_legacy_planar(&playback, clip);
            assert(animator.action(animator.order[0]).time == 0 && animator.event_count == 0);
            fixture.destination.remove(restored);
        }
        char[] binary = MOTION_CODEC_CROWD_V3_PENDING;
        String text = (String)MOTION_CODEC_CROWD_V3_PENDING_TEXT;
        uint[3] members = { 1, 2, 3 };
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, binary)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            AnimatedCrowd* crowd = fixture.destination.get(restored, AnimatedCrowd);
            assert(!crowd.inertia_enabled && !crowd.is_prepared() && crowd.authoring);
            assert(crowd.count == 2 && crowd.placements.len == 3 && crowd.actions_per_instance == 4);
            assert(crowd.event_capacity == 17 && crowd.trace && restored.layers == 9);
            assert(restored.local.position == (Vec3){ 4, 2, -8 });
            assert(crowd.placements[0].scale == (Vec3){ 2, 2, 2 });
            assert(crowd.placements[1].scale == (Vec3){ -1, 2, 0.5f });
            assert(crowd.authoring.instances[0].base_action == 0);
            assert(crowd.authoring.instances[1].configured && !crowd.authoring.instances[1].actions.len);
            foreach (action : crowd.authoring.instances[0].actions) {
                assert_motion_codec_extraction(action.extraction, {});
            }
            CrowdSpaceAuthoring planar = crowd.authoring.instances[0].spaces[0];
            assert(planar.kind == TWO_DIMENSIONAL && planar.actions == members[..]);
            assert(planar.triangles[0].indices == (uint[3]){ 2, 1, 0 });
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            assert(!crowd.playback.inertial_storage && crowd.playback.slots[1].action_count == 0);
            PlaybackView playback = anim::crowd_playback_view(crowd.playback, &crowd.playback.slots[0]);
            assert_motion_codec_legacy_planar(&playback, clip);
            Action* base = crowd.playback.slots[0].actions.get(crowd.playback.slots[0].base_action);
            assert(base.time == 0.125f && crowd.playback.event_count == 0);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_animation_motion_codec_planar_extract_yaw_mix_restores_both_owners() @test {
    foreach (crowded : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, 32);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            ClipId clip = fixture.assets.model(model_id).data.clips[0];
            Node* source;
            if (crowded) {
                bool[4] all = { true, true, true, true };
                CrowdActionAuthoring[2] actions;
                foreach (index, &action : actions) {
                    *action = {
                        .clip = clip,
                        .speed = 1,
                        .weight = 0.5f,
                        .loop = true,
                        .playing = true,
                        .mask = all[..],
                        .root_motion = EXTRACT,
                        .root_yaw = index == 0,
                    };
                }
                CrowdInstanceAuthoring[1] authoring = { {
                    .configured = true,
                    .root_node = 2,
                    .base_action = 0,
                    .actions = actions[..],
                } };
                source = fixture.source.add_node(name: "planar_mix")!!;
                model::attach_crowd(
                    assets: &fixture.assets,
                    scene: &fixture.source,
                    node: source,
                    model: model_id,
                    capacity: 1,
                    pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
                    instances: { {
                        .placement = maths::TRANSFORM_IDENTITY,
                        .pose = { .clip = clip, .speed = 1, .loop = true },
                        .color = { 1, 1, 1, 1 },
                    } },
                    actions_per_instance: 4,
                    authoring: authoring[..],
                )!!;
                model::prepare_crowd(&fixture.assets, &fixture.source, source)!!;
            } else {
                source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
                Animator* animator = anim::add_animator(&fixture.source, source);
                animator.root_node = 2;
                animator.play(&fixture.assets, clip, { .root_motion = EXTRACT, .root_yaw = true })!!;
                animator.play(&fixture.assets, clip, { .root_motion = EXTRACT })!!;
            }
            char[] bytes = fixture_bytes(&fixture, source);
            String text = fixture_text(&fixture, source);
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                PlaybackView playback;
                if (crowded) {
                    model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
                    AnimatedCrowd* crowd = fixture.destination.get(restored, AnimatedCrowd);
                    playback = anim::crowd_playback_view(crowd.playback, &crowd.playback.slots[0]);
                } else {
                    playback = fixture.destination.get(restored, Animator).playback();
                }
                assert(*playback.action_count == 2);
                foreach (index, id : playback.order[:2]) {
                    Action* action = playback.actions.get(id);
                    assert(action.root_motion == EXTRACT && action.root_yaw == (index == 0));
                    assert(!action.extraction.generalized && !action.motion_chain);
                }
                fixture.destination.remove(restored);
            }
        };
    }
}
