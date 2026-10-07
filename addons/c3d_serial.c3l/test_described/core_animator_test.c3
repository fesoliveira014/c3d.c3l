module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

enum FadeCase @private {
    FADE_IN,
    CROSS_FADE,
    FADE_OUT,
    SPACE_FADE,
    ZERO_WEIGHT,
    SPACE_FADE_OUT,
}

fn Animator* configure_fade_case(
    Scene* scene,
    AssetStore* assets,
    Node* root,
    FadeCase kind,
    bool settled,
) @private {
    ModelInstance* instance = scene.get(root, ModelInstance);
    instance.base_pose[2].position.x = 0.125f;
    instance.base_morph_weights[0][0] = 0.2f;
    ClipId clip = instance.clips[0];
    Animator* animator = anim::add_animator(scene, root);
    switch (kind) {
        case FADE_IN:
            AnimationActionId id = animator.play(assets, clip, { .fade_in = settled ? 0 : 2 })!!;
            animator.action(id).speed = 0.5f;
        case CROSS_FADE:
            if (!settled) {
                AnimationActionId outgoing = animator.play(assets, clip)!!;
                animator.action(outgoing).speed = 0.25f;
                AnimationActionId incoming = animator.play(assets, clip, { .layer = 1 })!!;
                animator.action(incoming).speed = 1.5f;
                animator.action(incoming).weight = 0;
                animator.cross_fade(from: outgoing, to: incoming, duration: 2)!!;
            } else {
                AnimationActionId id = animator.play(assets, clip, { .layer = 1 })!!;
                animator.action(id).speed = 1.5f;
            }
        case FADE_OUT:
            if (!settled) {
                AnimationActionId id = animator.play(assets, clip)!!;
                animator.stop(id, 2)!!;
            }
        case SPACE_FADE:
            BlendSpace1D* space = animator.add_blend_space(assets, { clip, clip }, { 0, 1 })!!;
            space.parameter = 0.25f;
            space.speed = 0.5f;
            if (settled) {
                space.weight = 0.4f;
            } else {
                animator.fade_blend_space(space, 0.4f, 2)!!;
            }
        case ZERO_WEIGHT:
            AnimationActionId id = animator.play(assets, clip)!!;
            animator.action(id).weight = 0;
        case SPACE_FADE_OUT:
            if (!settled) {
                BlendSpace1D* space = animator.add_blend_space(assets, { clip, clip }, { 0, 1 })!!;
                animator.stop_blend_space(space, 2)!!;
            }
    }
    return animator;
}

fn void assert_model_pose(Scene* scene, Node* actual_root, Node* expected_root) @private {
    ModelInstance* actual = scene.get(actual_root, ModelInstance);
    ModelInstance* expected = scene.get(expected_root, ModelInstance);
    assert(actual.nodes.len == expected.nodes.len);
    foreach (usz index, pose : actual.base_pose) {
        assert(pose.position == expected.base_pose[index].position);
        Node* first = actual.present_node(index);
        Node* second = expected.present_node(index);
        assert((first == null) == (second == null));
        if (!first) continue;
        assert(first.local.position.distance(second.local.position) < 1e-5f);
        assert((first.local.rotation.v - second.local.rotation.v).length() < 1e-5f);
        assert(first.local.scale.distance(second.local.scale) < 1e-5f);
        Mesh* mesh = scene.get(first, Mesh);
        if (!mesh) continue;
        Mesh* other = scene.get(second, Mesh);
        assert(other && mesh.morph_weights.len == other.morph_weights.len);
        foreach (weight_index, weight : mesh.morph_weights) {
            assert(math::abs(weight - other.morph_weights[weight_index]) < 1e-5f);
        }
    }
}

fn void test_animator_fades_settle_without_mutating_source_and_match_public_setup() @test {
    foreach (kind : FadeCase::values) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            serial::register_core_codecs()!!;
            ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
            Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
            Animator* original = configure_fade_case(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
                kind: kind,
                settled: false,
            );
            anim::update(&fixture.assets, &fixture.source, 0.25f);
            uint source_count = original.action_count;
            Action[anim::MAX_ACTIONS] snapshot;
            foreach (index, id : original.order[:source_count]) snapshot[index] = *original.action(id);
            double phase = original.blend_spaces[0].phase;
            ModelInstance* source_instance = fixture.source.get(source, ModelInstance);
            Vec3 position = source_instance.present_node(2).local.position;
            float morph = fixture.source.get(source_instance.present_node(1), Mesh).morph_weights[0];
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
            assert(original.action_count == source_count && original.blend_spaces[0].phase == phase);
            foreach (index, id : original.order[:source_count]) {
                Action* action = original.action(id);
                assert(action.time == snapshot[index].time && action.weight == snapshot[index].weight);
                assert(action.fade_rate == snapshot[index].fade_rate && action.fade_target == snapshot[index].fade_target);
            }
            assert(source_instance.present_node(2).local.position == position);
            assert(fixture.source.get(source_instance.present_node(1), Mesh).morph_weights[0] == morph);
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                Node* reference = model::instantiate(&fixture.assets, &fixture.destination, model_id)!!;
                configure_fade_case(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: reference,
                    kind: kind,
                    settled: true,
                );
                Animator* loaded = fixture.destination.get(restored, Animator);
                Animator* expected = fixture.destination.get(reference, Animator);
                assert(loaded.action_count == expected.action_count && loaded.event_count == 0);
                foreach (id : loaded.order[:loaded.action_count]) {
                    Action* action = loaded.action(id);
                    assert(action.time == 0 && action.fade_rate == 0);
                }
                assert(loaded.blend_spaces[0].phase == 0 && loaded.blend_spaces[0].fade_rate == 0);
                assert(bytes == serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                )!!);
                foreach (float step : { 0.1f, 0.125f, 0.25f }) {
                    anim::update(&fixture.assets, &fixture.destination, step);
                    assert_model_pose(&fixture.destination, restored, reference);
                }
                if (kind == ZERO_WEIGHT) assert(loaded.action_count == 1 && loaded.action(loaded.order[0]).weight == 0);
                fixture.destination.remove(reference);
                fixture.destination.remove(restored);
            }
        };
    }
}

fn Animator* edit_animated_model(Scene* scene, AssetStore* assets, Node* root) @private {
    ModelInstance* instance = scene.get(root, ModelInstance);
    scene.remove_component(instance.present_node(1), SkinBinding);
    Node* removed = instance.present_node(2);
    scene.add_node(instance.present_node(3), "removed_application_child")!!;
    scene.remove(removed);
    Node* replacement = scene.add_node(root, "replacement")!!;
    assert(replacement == removed && instance.present_node(2) == null && instance.present_node(3) == null);
    replacement.local.position = { 40, 50, 60 };
    instance.base_pose[1].position = { 4, 5, 6 };
    instance.present_node(1).local = instance.base_pose[1];
    instance.base_morph_weights[0][0] = 0.2f;
    scene.add_node(instance.present_node(1), "kept_application_child")!!;
    Animator* animator = anim::add_animator(scene, root);
    animator.root_node = 2;
    bool[4] membership = { false, true, true, true };
    JointMask mask = { .nodes = membership[..] };
    AnimationActionId id = animator.play(assets, instance.clips[0], {
        .mask = &mask, .root_motion = EXTRACT, .root_yaw = true,
    })!!;
    animator.action(id).speed = 0.75f;
    animator.action(id).loop = false;
    return animator;
}

fn void test_edited_model_animation_matches_eager_construction_with_absent_root_motion() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        Animator* original = edit_animated_model(&fixture.source, &fixture.assets, source);
        anim::update(&fixture.assets, &fixture.source, 0.25f);
        float time = original.action(original.order[0]).time;
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
        assert(original.action(original.order[0]).time == time && original.action(original.order[0]).root_motion == EXTRACT);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            Node* reference = model::instantiate(&fixture.assets, &fixture.destination, model_id)!!;
            edit_animated_model(&fixture.destination, &fixture.assets, reference);
            ModelInstance* instance = fixture.destination.get(restored, ModelInstance);
            Animator* loaded = fixture.destination.get(restored, Animator);
            assert(instance.nodes.len == 4 && instance.base_pose.len == 4 && instance.node_entities.len == 4);
            assert(instance.present_node(2) == null && instance.present_node(3) == null);
            assert(!fixture.destination.has(instance.present_node(1), SkinBinding));
            assert(instance.base_morph_weights[0][0] == 0.2f && loaded.root_node == 2);
            Action* action = loaded.action(loaded.order[0]);
            assert(action.root_motion == EXTRACT && action.root_yaw && action.time == 0 && !action.loop);
            assert(action.speed == 0.75f && !action.mask[0] && action.mask[1]);
            assert(child_named(instance.present_node(1), "kept_application_child").parent == instance.present_node(1));
            foreach (float step : { 0.1f, 0.125f, 0.25f }) {
                anim::update(&fixture.assets, &fixture.destination, step);
                assert_model_pose(&fixture.destination, restored, reference);
                assert(loaded.root_motion.translation == (Vec3){});
                assert(loaded.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
                assert(child_named(restored, "replacement").local.position == (Vec3){ 40, 50, 60 });
            }
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(reference);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_animator_preflight_rejects_invalid_configuration_before_attachment() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        Animator* animator = configure_fade_case(
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            kind: SPACE_FADE,
            settled: true,
        );
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
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
        uint saved = member(&document, components, "c3d.Animator");
        uint value = member(&document, saved, "value");
        uint actions = member(&document, value, "actions");
        uint spaces = member(&document, value, "spaces");
        uint[4] tokens = {
            member(&document, value, "root_node"), member(&document, actions + 1, "mask"),
            member(&document, spaces + 1, "positions"), member(&document, spaces + 1, "actions"),
        };
        String[4] replacements = { "99", "[]", "[0,0]", "[0,0]" };
        uint before = fixture.destination.world.entities.free_count;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        foreach (index, token : tokens) {
            String edited = replace_token(text, document.values[token], replacements[index]);
            assert(@catch(serial::read_subtree_text(
                scene: &fixture.destination,
                assets: &fixture.assets,
                text: edited,
                options: options,
            )) == c3d::INVALID_ARGUMENT);
            assert(diagnostic.type_name == "c3d.Animator" && diagnostic.node_path == "/nodes/0");
            assert(diagnostic.has_text_position && fixture.destination.world.entities.free_count == before);
            assert(fixture.destination.root.first_child == null && fixture.destination.count(ModelInstance) == 0);
            assert(fixture.destination.count(Animator) == 0 && fixture.destination.count(SkinBinding) == 0);
        }
        assert(animator.action_count == 2 && animator.blend_spaces[0].positions[1] == 1);
    };
}