module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset::gltf;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn void test_animator_scalars_reject_nonfinite_and_negative_weights_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ClipId clip = fixture.source.get(source, ModelInstance).clips[0];
        Animator* animator = anim::add_animator(&fixture.source, source);
        AnimationActionId action_id = animator.play(&fixture.assets, clip)!!;
        BlendSpace1D* space = animator.add_blend_space(&fixture.assets, { clip, clip }, { 0, 1 })!!;
        Action* action = animator.action(action_id);
        float*[5] fields = { &action.speed, &action.weight, &space.parameter, &space.speed, &space.weight };
        uint[5] finite_bits = { 0x3f912345, 0x3fa23456, 0x3e123456, 0x3f923456, 0x3e923456 };
        foreach (index, field : fields) *field = bitcast(finite_bits[index], float);
        char[] bytes = serial::write_subtree(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        usz[5] offsets;
        foreach (index, bits : finite_bits) {
            uint matches;
            for (usz offset = 0; offset + uint::size <= bytes.len; offset++) {
                Reader reader = serial::reader_over(bytes[offset:uint::size]);
                if (reader.read_uint()!! != bits) continue;
                offsets[index] = offset;
                matches++;
            }
            assert(matches == 1);
        }
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem, source: text, limits: serial::TEXT_LIMITS_DEFAULT, diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint nodes = member(&document, 0, "nodes");
        uint components = member(&document, nodes + 1, "components");
        uint saved = member(&document, components, "c3d.Animator");
        uint value = member(&document, saved, "value");
        uint actions = member(&document, value, "actions");
        uint spaces = member(&document, value, "spaces");
        uint[5] tokens = {
            member(&document, actions + 1, "speed"), member(&document, actions + 1, "weight"),
            member(&document, spaces + 1, "parameter"), member(&document, spaces + 1, "speed"),
            member(&document, spaces + 1, "weight"),
        };
        uint[4] rejected_bits = { 0x7fc00001, 0x7f800000, 0xff800000, 0xbf800000 };
        String[4] rejected_text = { `"f32:7fc00001"`, `"f32:7f800000"`, `"f32:ff800000"`, "-1" };
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        existing.local.position = { 3, 5, 7 };
        uint free_before = fixture.destination.world.entities.free_count;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        foreach (index, field : fields) {
            foreach (invalid, bits : rejected_bits) {
                if (invalid == 3 && index != 1 && index != 4) continue;
                char[] edited_bytes = alloc::clone_slice(tmem, bytes);
                Writer patch = serial::writer_over(edited_bytes[offsets[index]:uint::size]);
                patch.write_uint(bits);
                String edited_text = replace_token(text, document.values[tokens[index]], rejected_text[invalid]);
                for (uint encoding = 0; encoding < 2; encoding++) {
                    Node*? result = encoding == 0
                      ? serial::read_subtree(
                          scene: &fixture.destination, assets: &fixture.assets, bytes: edited_bytes, options: options,
                      )
                      : serial::read_subtree_text(
                          scene: &fixture.destination, assets: &fixture.assets, text: edited_text, options: options,
                      );
                    assert(@catch(result) == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.type_name == "c3d.Animator" && diagnostic.node_path == "/nodes/0");
                    assert(diagnostic.has_text_position == (encoding == 1));
                    assert(fixture.destination.world.entities.free_count == free_before);
                    assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
                    assert(existing.local.position == (Vec3){ 3, 5, 7 });
                    assert(fixture.destination.count(Animator) == 0 && fixture.destination.count(ModelInstance) == 0);
                }
                *field = bitcast(bits, float);
                assert(@catch(serial::write_subtree(
                    allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
                )) == c3d::INVALID_ARGUMENT);
                assert(@catch(serial::write_subtree_text(
                    allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
                )) == c3d::INVALID_ARGUMENT);
                *field = bitcast(finite_bits[index], float);
            }
        }
        assert(text == serial::write_subtree_text(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!);
    };
}