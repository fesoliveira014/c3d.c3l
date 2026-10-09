module c3d::serial::test_described;

import c3d;
import c3d::anim::ik;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;
import std::collections::object;
import std::encoding::json;
import std::math;

fn void? write_foot_authoring_v1(void* raw, serial::Writer* writer, serial::WriteContext* context) @private {
    FootIk* foot = raw;
    serial::FootAuthoringV1 value = {
        .foot_height = foot.foot_height,
        .lift_fade = foot.lift_fade,
        .ray_height = foot.ray_height,
        .ray_length = foot.ray_length,
    };
    foreach (index, joint : foot.leg.joints) {
        value.leg.joints[index] = context.make_node_reference(joint, true, c3d::INVALID_ARGUMENT)!;
    }
    value.leg.target = context.make_node_reference(foot.leg.target, true, c3d::INVALID_ARGUMENT)!;
    value.leg.pole = context.make_node_reference(foot.leg.pole)!;
    value.leg.weight = foot.leg.weight;
    value.leg.limits = foot.leg.limits;
    serial::write_described_value(
        type: serial::described_type(serial::FootAuthoringV1)!,
        writer: writer,
        context: context,
        value: &value,
    )!;
}

fn Node* create_serial_foot_tree(Fixture* fixture) @private {
    Node* root = fixture.source.add_node(name: "foot")!!;
    Node* hip = fixture.source.add_node(root, "hip")!!;
    Node* knee = fixture.source.add_node(hip, "knee")!!;
    Node* ankle = fixture.source.add_node(knee, "ankle")!!;
    Node* target = fixture.source.add_node(root, "target")!!;
    knee.local.position = { 0, -1, 0 };
    ankle.local.position = { 0, -1, 0 };
    target.local.position = { 0, -2, 0 };
    FootIk foot = ik::foot_ik(hip: hip, knee: knee, ankle: ankle, target: target);
    foot.foot_height = 0.13f;
    foot.lift_fade = 0.15f;
    foot.plant.acquire_seconds = 0.3f;
    foot.contact.phase = FootContactPhase.RELEASING;
    fixture.source.add(root, foot);
    fixture.source.update_world();
    return root;
}

fn void test_foot_version_one_binary_defaults_and_corrupt_layout_rollback() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* root = create_serial_foot_tree(&fixture);
        uint slot = ecs::slot_of(FootIk)!!;
        serial::ReadFn read = serial::codecs[slot].codec.read;
        serial::register_codec(FootIk, {
            .name = "c3d.FootIk",
            .version = 1,
            .phase = REFERENCES,
            .write = &write_foot_authoring_v1,
            .read = read,
        })!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        serial::register_core_codecs()!!;
        assert(serial::codecs[slot].codec.version == 2);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        FootIk* foot = fixture.destination.get(restored, FootIk);
        assert(foot.foot_height == 0.13f && foot.lift_fade == 0.15f);
        assert(foot.plant.acquire_seconds == ik::FOOT_PLANT_DEFAULT.acquire_seconds);
        assert(foot.plant.release_seconds == ik::FOOT_PLANT_DEFAULT.release_seconds);
        assert(foot.plant.sole_up == ik::FOOT_PLANT_DEFAULT.sole_up);
        assert(foot.plant.sole_forward == ik::FOOT_PLANT_DEFAULT.sole_forward);
        assert(foot.contact.phase == FootContactPhase.INACTIVE && !foot.grounded);
        assert(foot.leg.joints[1] == child_named(child_named(restored, "hip"), "knee"));
        fixture.destination.remove(restored);

        char[] corrupt = alloc::clone_slice(tmem, bytes);
        char[8] layout = { 0x1f, 0x12, 0xdb, 0xde, 0x49, 0x5a, 0x93, 0x4c };
        usz layout_offset = usz::max;
        for (usz index = 0; index + layout.len <= corrupt.len; index++) {
            if (corrupt[index:layout.len] == layout[..]) {
                assert(layout_offset == usz::max);
                layout_offset = index;
            }
        }
        assert(layout_offset != usz::max);
        corrupt[layout_offset] ^= 1;
        uint free_before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, corrupt)) == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.world.entities.free_count == free_before);
    };
}

fn void test_foot_version_one_text_defaults_and_future_version_rollback() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* root = create_serial_foot_tree(&fixture);
        String current = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        Object* document = json::tparse(current)!!;
        Object* nodes = document.get("nodes")!!;
        Object* components = nodes.get_at(0).get("components")!!;
        Object* component = components.get("c3d.FootIk")!!;
        component.set("version", 1);
        Object* value = component.get("value")!!;
        value.map.remove("plant")!!;
        String old = json::marshal(tmem, document);
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, old)!!;
        FootIk* foot = fixture.destination.get(restored, FootIk);
        assert(foot.foot_height == 0.13f && foot.lift_fade == 0.15f);
        assert(foot.plant.acquire_seconds == ik::FOOT_PLANT_DEFAULT.acquire_seconds);
        assert(foot.plant.release_seconds == ik::FOOT_PLANT_DEFAULT.release_seconds);
        assert(foot.plant.sole_up == ik::FOOT_PLANT_DEFAULT.sole_up);
        assert(foot.plant.sole_forward == ik::FOOT_PLANT_DEFAULT.sole_forward);
        assert(foot.contact.phase == FootContactPhase.INACTIVE);
        fixture.destination.remove(restored);

        uint free_before = fixture.destination.world.entities.free_count;
        component.set("version", 3);
        String future = json::marshal(tmem, document);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, future)) == c3d::UNSUPPORTED);
        assert(fixture.destination.world.entities.free_count == free_before);
        Object* leg = value.get("leg")!!;
        leg.set("target", object::new_obj(tmem));
        for (uint version = 1; version <= 2; version++) {
            component.set("version", version);
            String missing = json::marshal(tmem, document);
            assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, missing)) == c3d::INVALID_ARGUMENT);
            assert(fixture.destination.world.entities.free_count == free_before);
        }
    };
}

fn void test_ik_authoring_rebinds_joints_and_resets_foot_contacts_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* root = fixture.source.add_node(name: "constraints")!!;
        Node* hip = fixture.source.add_node(root, "hip")!!;
        Node* knee = fixture.source.add_node(hip, "knee")!!;
        Node* ankle = fixture.source.add_node(knee, "ankle")!!;
        knee.local.position = { 0, -1, 0 };
        ankle.local.position = { 0, -1, 0 };
        Node* target = fixture.source.add_node(root, "target")!!;
        target.local.position = { 1, -1, 0 };
        IkChain chain = ik::ik_chain(root: hip, middle: knee, end: ankle, target: target);
        chain.weight = 0.6f;
        chain.limits[0] = ik::hinge_limit(
            reference: maths::TRANSFORM_IDENTITY.rotation, axis: { 0, 0, 1 }, min_angle: -0.2f, max_angle: 0.3f,
        );
        fixture.source.add(root, chain);
        FootIk foot = ik::foot_ik(hip: hip, knee: knee, ankle: ankle, target: target);
        foot.foot_height = 0.12f;
        foot.grounded = true;
        foot.ground_offset = 0.25f;
        foot.align_weight = 0.75f;
        foot.plant = {
            .acquire_seconds = 0.17f,
            .release_seconds = 0.31f,
            .sole_up = { 0, 0, 1 },
            .sole_forward = { 0, 1, 0 },
        };
        foot.contact = {
            .phase = FootContactPhase.PLANTED,
            .support_identity = 73,
            .elapsed = 0.17f,
            .local_point = { 1, 2, 3 },
            .requested = maths::TRANSFORM_IDENTITY,
        };
        fixture.source.add(root, foot);
        LookAt look = ik::look_at({ hip, knee, ankle }, target, { 0, -1, 0 });
        look.max_angle = 0.5f;
        fixture.source.add(root, look);
        fixture.source.update_world();
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            Node* loaded_hip = child_named(restored, "hip");
            Node* loaded_knee = child_named(loaded_hip, "knee");
            Node* loaded_ankle = child_named(loaded_knee, "ankle");
            IkChain* loaded = fixture.destination.get(restored, IkChain);
            assert(loaded.joints[0] == loaded_hip && loaded.joints[1] == loaded_knee && loaded.joints[2] == loaded_ankle);
            assert(loaded.target == child_named(restored, "target") && loaded.pole == null);
            assert(loaded.weight == 0.6f && loaded.limits[0].kind == HINGE && loaded.limits[0].max_angle == 0.3f);
            FootIk* loaded_foot = fixture.destination.get(restored, FootIk);
            assert(loaded_foot.leg.joints[1] == loaded_knee && loaded_foot.foot_height == 0.12f);
            assert(!loaded_foot.grounded && loaded_foot.ground_offset == 0 && loaded_foot.align_weight == 0);
            assert(loaded_foot.plant.acquire_seconds == foot.plant.acquire_seconds);
            assert(loaded_foot.plant.release_seconds == foot.plant.release_seconds);
            assert(loaded_foot.plant.sole_up == foot.plant.sole_up && loaded_foot.plant.sole_forward == foot.plant.sole_forward);
            assert(loaded_foot.contact.phase == FootContactPhase.INACTIVE);
            assert(loaded_foot.contact.support_identity == 0 && loaded_foot.contact.elapsed == 0);
            assert(loaded_foot.contact.local_point == (double[<3>]){});
            LookAt* loaded_look = fixture.destination.get(restored, LookAt);
            assert(loaded_look.joint_count == 3 && loaded_look.joints[2] == loaded_ankle);
            assert(loaded_look.max_angle == 0.5f && loaded_look.weights[2] == look.weights[2]);
            assert(ik::ik_chain_valid(loaded) && ik::look_at_valid(loaded_look));
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
        fixture.source.get(root, IkChain).target = fixture.source.root;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        for (uint encoding = 0; encoding < 2; encoding++) {
            TextWriteOptions text_options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
            text_options.diagnostic = &diagnostic;
            char[]? rejected = encoding == 0
              ? serial::write_subtree(
                  allocator: tmem,
                  scene: &fixture.source,
                  assets: &fixture.assets,
                  root: root,
                  options: { .diagnostic = &diagnostic },
              )
              : (char[])serial::write_subtree_text(
                  allocator: tmem,
                  scene: &fixture.source,
                  assets: &fixture.assets,
                  root: root,
                  options: text_options,
              );
            if (catch excuse = rejected) {
                assert(excuse == c3d::INVALID_ARGUMENT);
            } else {
                assert(false);
            }
            assert(diagnostic.node_path == "/nodes/0" && diagnostic.type_name == "c3d.IkChain");
        }
    };
}

fn void test_retargeted_look_and_ik_pole_preserve_live_nodes_in_reused_model_slots() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = graph_model(&fixture);
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        Node* hip = instance.present_node(0);
        Node* knee = instance.present_node(2);
        Node* ankle = instance.present_node(3);
        knee.local.position = { 0, -1, 0 };
        ankle.local.position = { 0, -1, 0 };
        Node* removed = instance.present_node(1);
        LookAt* look = fixture.source.add(source, ik::look_at({ hip }, removed, { 0, -1, 0 }));
        IkChain* chain = fixture.source.add(source, ik::ik_chain(
            root: hip, middle: knee, end: ankle, target: instance.present_node(5), pole: removed,
        ));
        fixture.source.remove(removed);
        Node* replacement = fixture.source.add_node(source, "replacement")!!;
        assert(replacement == removed && instance.present_node(1) == null);
        replacement.local.position = { 1, -1, 1 };
        look.target = replacement;
        chain.pole = replacement;
        fixture.source.update_world();
        char[] bytes = serial::write_subtree(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            Node* loaded_replacement = child_named(restored, "replacement");
            assert(fixture.destination.get(restored, ModelInstance).present_node(1) == null);
            assert(fixture.destination.get(restored, LookAt).target == loaded_replacement);
            assert(fixture.destination.get(restored, IkChain).pole == loaded_replacement);
            fixture.destination.remove(restored);
        }
        assert(look.target == replacement && chain.pole == replacement && instance.present_node(1) == null);
    };
}
