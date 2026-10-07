module c3d::serial::test_described;

import c3d;
import c3d::anim::ik;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

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
