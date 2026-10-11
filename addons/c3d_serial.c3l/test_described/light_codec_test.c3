module c3d::serial::test_described;

import c3d::describe;
import c3d;
import c3d::ecs;
import c3d::light;
import c3d::scene;
import c3d::serial @public;
import std::collections::object;
import std::encoding::json;
import std::hash::sha256;

const char[*] LIGHT_CODEC_V1_BINARY @private = $embed("../../../test/fixtures/light_v1/light-v1.bin");
const char[*] LIGHT_CODEC_V1_TEXT @private = $embed("../../../test/fixtures/light_v1/light-v1.jsonc");
const String LIGHT_CODEC_V1_BINARY_HASH @private = "96c290b5267c3798e27aeb7fb4ece28439ad61c23deabadcb131e296cee3a96c";
const String LIGHT_CODEC_V1_TEXT_HASH @private = "f5ac4114d3ebc8ac1a030f160d24c1b15c436cb4c7283e865ab9954cae012c03";
const String LIGHT_CODEC_HEX @private = "0123456789abcdef";

fn void test_light_codec_layouts_preserve_version_one_and_describe_colored_transmission() @test {
    describe::register_core_components()!!;
    describe::register_reflected(ShadowSettingsV1)!!;
    describe::register_reflected(LightV1)!!;
    ulong shadow = serial::description_layout(describe::get(ShadowSettings)!!)!!;
    ulong light = serial::description_layout(describe::get(Light)!!)!!;
    ulong shadow_v1 = serial::description_layout(describe::get(ShadowSettingsV1)!!)!!;
    ulong light_v1 = serial::description_layout(describe::get(LightV1)!!)!!;
    assert(shadow_v1 == 0x79ccc384defd9804 && light_v1 == 0xa41c0d2284b8d046);
    assert(shadow == 0x5b9670e585ad3d26 && light == 0x5884c8dac168c2c8);
    serial::register_core_codecs()!!;
    uint slot = ecs::assigned_slot(Light)!!;
    serial::register_core_codecs()!!;
    assert(ecs::assigned_slot(Light)!! == slot && serial::codecs[slot].codec.version == 2);
    assert(serial::described_type(ShadowSettings)!!.version == 2);
    assert(serial::described_type(Light)!!.version == 2);
}

fn Light light_codec_seed(bool colored = false) @private {
    return {
        .kind = SPOT,
        .color = { 0.25f, 0.5f, 1 },
        .intensity = 2.5f,
        .range = 15,
        .inner_cone = 0.125f,
        .outer_cone = 0.5f,
        .layers = 0x80000001,
        .shadow = {
            .enabled = true,
            .priority = -7,
            .bias = 0.003f,
            .directional_normal_bias_texels = 3.5f,
            .punctual_normal_bias = 0.02f,
            .cascades = 3,
            .cascade_lambda = 0.6f,
            .cascade_blend = 0.125f,
            .max_distance = 23.5f,
            .ray_traced = true,
            .colored_transmission = colored,
        },
    };
}

fn void assert_light_codec_value(Light* actual, Light expected) @private {
    assert(actual.kind == expected.kind && actual.color == expected.color);
    assert(actual.intensity == expected.intensity && actual.range == expected.range);
    assert(actual.inner_cone == expected.inner_cone && actual.outer_cone == expected.outer_cone);
    assert(actual.layers == expected.layers && actual.shadow.enabled == expected.shadow.enabled);
    assert(actual.shadow.priority == expected.shadow.priority && actual.shadow.bias == expected.shadow.bias);
    assert(actual.shadow.directional_normal_bias_texels == expected.shadow.directional_normal_bias_texels);
    assert(actual.shadow.punctual_normal_bias == expected.shadow.punctual_normal_bias);
    assert(actual.shadow.cascades == expected.shadow.cascades);
    assert(actual.shadow.cascade_lambda == expected.shadow.cascade_lambda);
    assert(actual.shadow.cascade_blend == expected.shadow.cascade_blend);
    assert(actual.shadow.max_distance == expected.shadow.max_distance);
    assert(actual.shadow.ray_traced == expected.shadow.ray_traced);
    assert(actual.shadow.colored_transmission == expected.shadow.colored_transmission);
}

fn void assert_light_codec_hash(char[] bytes, String expected) @private {
    char[32] digest = sha256::hash(bytes);
    char[64] hexadecimal;
    foreach (index, value : digest) {
        hexadecimal[index * 2] = LIGHT_CODEC_HEX[value >> 4];
        hexadecimal[index * 2 + 1] = LIGHT_CODEC_HEX[value & 15];
    }
    assert((String)hexadecimal[..] == expected);
}

fn char[] light_codec_payload(char[] bytes) @private {
    SubtreeHeader header = serial::read_header(bytes)!!;
    Reader reader = serial::reader_over(serial::chunk_bytes(bytes, header.chunk_count, COMPONENTS));
    assert(reader.read_uint()!! == 1);
    assert(reader.read_uint()!! == 0);
    assert(reader.read_uint()!! == 1);
    assert(reader.read_uint()!! == 0);
    uint length = reader.read_uint()!!;
    char[] payload = reader.read_bytes(length)!!;
    assert(reader.remaining() == 0);
    return payload;
}

fn usz light_codec_layout_offset(char[] payload, ulong layout) @private {
    usz found = usz::max;
    for (usz offset = 0; offset + ulong::size <= payload.len; offset++) {
        Reader reader = { .bytes = payload, .offset = offset };
        if (reader.read_ulong()!! != layout) continue;
        assert(found == usz::max);
        found = offset;
    }
    assert(found != usz::max && found >= uint::size);
    return found;
}

fn void test_light_codec_colored_transmission_round_trips_false_and_true_with_existing_fields() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* source = fixture.source.add_node(name: "light")!!;
        fixture.source.add(source, light_codec_seed());
        foreach (colored : (bool[2]){ false, true }) {
            *fixture.source.get(source, Light) = light_codec_seed(colored);
            char[] bytes = fixture_bytes(&fixture, source);
            String text = fixture_text(&fixture, source);
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                assert_light_codec_value(fixture.destination.get(restored, Light), light_codec_seed(colored));
                assert(bytes == fixture_bytes(&fixture, source));
                assert(text == fixture_text(&fixture, source));
                fixture.destination.remove(restored);
            }
        }
    };
}

fn void test_light_codec_reads_frozen_version_one_binary_and_text_with_color_disabled() @test {
    @pool() {
        assert(LIGHT_CODEC_V1_BINARY.len == 297 && LIGHT_CODEC_V1_TEXT.len == 1249);
        assert_light_codec_hash(LIGHT_CODEC_V1_BINARY[..], LIGHT_CODEC_V1_BINARY_HASH);
        assert_light_codec_hash(LIGHT_CODEC_V1_TEXT[..], LIGHT_CODEC_V1_TEXT_HASH);
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, LIGHT_CODEC_V1_BINARY[..])!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)LIGHT_CODEC_V1_TEXT[..])!!;
            assert(restored.name == "light");
            assert_light_codec_value(fixture.destination.get(restored, Light), light_codec_seed());
            char[] current = serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!;
            char[] payload = light_codec_payload(current);
            Reader reader = serial::reader_over(payload);
            assert(reader.read_uint()!! == 2 && reader.read_ulong()!! == 0x5884c8dac168c2c8);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_light_codec_rejects_unknown_binary_versions_layouts_and_nonboolean_flags_atomically() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* source = fixture.source.add_node(name: "light")!!;
        fixture.source.add(source, light_codec_seed(true));
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        fixture.destination.add(existing, light_codec_seed(true));
        uint free_before = fixture.destination.world.entities.free_count;
        char[] bytes = fixture_bytes(&fixture, source);
        for (uint fault_case = 0; fault_case < 5; fault_case++) {
            char[] corrupt = alloc::clone_slice(tmem, bytes);
            char[] payload = light_codec_payload(corrupt);
            ulong layout = fault_case < 2 ? 0x5884c8dac168c2c8 : 0x5b9670e585ad3d26;
            usz offset = light_codec_layout_offset(payload, layout);
            fault expected = c3d::UNSUPPORTED;
            switch (fault_case) {
                case 0:
                case 2:
                    Writer patch = serial::writer_over(payload[offset - uint::size:uint::size]);
                    patch.write_uint(3);
                    patch.finish()!!;
                case 1:
                case 3:
                    payload[offset] ^= 1;
                    expected = c3d::ASSET_FORMAT_ERROR;
                case 4:
                    assert(payload[payload.len - 1] == 1);
                    payload[payload.len - 1] = 2;
                    expected = c3d::ASSET_FORMAT_ERROR;
            }
            assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, corrupt)) == expected);
            assert(fixture.destination.world.entities.free_count == free_before && fixture.destination.count(Light) == 1);
            assert_light_codec_value(fixture.destination.get(existing, Light), light_codec_seed(true));
        }
    };
}

fn void test_light_codec_missing_text_flag_defaults_off_and_version_or_flag_faults_roll_back() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* source = fixture.source.add_node(name: "light")!!;
        fixture.source.add(source, light_codec_seed(true));
        String text = fixture_text(&fixture, source);
        Object* document = json::tparse(text)!!;
        Object* component = document.get("nodes")!!.get_at(0).get("components")!!.get("c3d.Light")!!;
        Object* shadow = component.get("value")!!.get("shadow")!!;
        shadow.map.remove("colored_transmission")!!;
        for (uint version = 1; version <= 2; version++) {
            component.set("version", version);
            String missing = json::marshal(tmem, document);
            Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, missing)!!;
            assert_light_codec_value(fixture.destination.get(restored, Light), light_codec_seed());
            fixture.destination.remove(restored);
        }
        uint free_before = fixture.destination.world.entities.free_count;
        component.set("version", 3);
        String unsupported = json::marshal(tmem, document);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, unsupported)) == c3d::UNSUPPORTED);
        assert(fixture.destination.world.entities.free_count == free_before);
        component.set("version", 2);
        shadow.set("colored_transmission", "not_boolean");
        String malformed = json::marshal(tmem, document);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, malformed)) == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.world.entities.free_count == free_before && fixture.destination.root.first_child == null);
    };
}
