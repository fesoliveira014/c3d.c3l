module c3d::serial::test_described;

import c3d;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn void test_crowd_serialization_rejects_nonfinite_authored_clocks_only() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        uint[2] finite_bits = { 0xbf912345, 0xbe123456 };
        CrowdInstance[1] instances = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = {
                .clip = fixture.assets.model(model_id).data.clips[0],
                .time = bitcast(finite_bits[1], float),
                .speed = bitcast(finite_bits[0], float),
                .loop = true,
            },
            .color = { 0.2f, 0.4f, 0.6f, 0.8f },
        } };
        Node* source = fixture.source.add_node(name: "crowd")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            node: source,
            model: model_id,
            capacity: 3,
            pose_bounds: { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } },
            instances: instances[..],
        )!!;
        AnimatedCrowd* crowd = fixture.source.get(source, AnimatedCrowd);
        float*[2] fields = { &crowd.seeds[0].speed, &crowd.start_times[0] };
        char[] bytes = encode_crowd_scalars(&fixture, source, false)!!;
        String text = (String)encode_crowd_scalars(&fixture, source, true)!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
            assert(!loaded.is_prepared() && loaded.count == 1);
            assert(bitcast(loaded.seeds[0].speed, uint) == finite_bits[0]);
            assert(bitcast(loaded.start_times[0], uint) == finite_bits[1]);
            assert(bitcast(loaded.seeds[0].time, uint) == finite_bits[1]);
            fixture.destination.remove(restored);
        }
        usz[2] offsets;
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
        uint saved_instances = member(&document, value, "instances");
        uint pose = member(&document, saved_instances + 1, "pose");
        uint[2] tokens = { member(&document, pose, "speed"), member(&document, pose, "time") };
        uint[3] rejected_bits = { 0x7fc00001, 0x7f800000, 0xff800000 };
        String[3] rejected_text = { `"f32:7fc00001"`, `"f32:7f800000"`, `"f32:ff800000"` };
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        existing.local.position = { 3, 5, 7 };
        uint free_before = fixture.destination.world.entities.free_count;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        foreach (index, field : fields) {
            foreach (invalid, bits : rejected_bits) {
                char[] edited_bytes = alloc::clone_slice(tmem, bytes);
                Writer patch = serial::writer_over(edited_bytes[offsets[index]:uint::size]);
                patch.write_uint(bits);
                String edited_text = replace_token(text, document.values[tokens[index]], rejected_text[invalid]);
                for (uint encoding = 0; encoding < 2; encoding++) {
                    Node*? result = encoding == 0
                      ? serial::read_subtree(
                          scene: &fixture.destination,
                          assets: &fixture.assets,
                          bytes: edited_bytes,
                          options: options,
                      )
                      : serial::read_subtree_text(
                          scene: &fixture.destination,
                          assets: &fixture.assets,
                          text: edited_text,
                          options: options,
                      );
                    assert(@catch(result) == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.cause == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.type_name == "c3d.AnimatedCrowd" && diagnostic.node_path == "/nodes/0");
                    assert(diagnostic.has_text_position == (encoding == 1));
                    assert(fixture.destination.world.entities.free_count == free_before);
                    assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
                    assert(existing.local.position == (Vec3){ 3, 5, 7 }
                      && fixture.destination.count(AnimatedCrowd) == 0);
                    *field = bitcast(bits, float);
                    assert(@catch(encode_crowd_scalars(
                        fixture: &fixture,
                        source: source,
                        text_mode: encoding == 1,
                        diagnostic: &diagnostic,
                    )) == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.cause == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.type_name == "c3d.AnimatedCrowd" && diagnostic.node_path == "/nodes/0");
                    *field = bitcast(finite_bits[index], float);
                }
            }
        }
        crowd.seeds[1].speed = bitcast(rejected_bits[0], float);
        crowd.start_times[1] = bitcast(rejected_bits[1], float);
        foreach (bits : rejected_bits) {
            crowd.seeds[0].time = bitcast(bits, float);
            assert(bytes == encode_crowd_scalars(&fixture, source, false)!!);
            assert(text == (String)encode_crowd_scalars(&fixture, source, true)!!);
            assert(bitcast(crowd.seeds[0].time, uint) == bits);
        }
    };
}

fn char[]? encode_crowd_scalars(
    Fixture* fixture,
    Node* source,
    bool text_mode,
    SerialDiagnostic* diagnostic = null,
) @local {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: source,
        options: { .limits = serial::TEXT_LIMITS_DEFAULT, .diagnostic = diagnostic },
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: source,
        options: { .diagnostic = diagnostic },
    );
}
