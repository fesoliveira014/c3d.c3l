module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn void test_json_reader_reports_unknown_fields_and_child_hook_faults() @test {
    initialize_json_descriptions();
    Acquisitions owned = { .allocator = mem };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    JsonDefaults value;
    if (catch excuse = decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: `{"child":{"a/b~":true}}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR && diagnostic.cause == excuse);
        assert(diagnostic.has_text_position && diagnostic.pointer == "/child/a~1b~0");
    } else {
        assert(false);
    }
    assert(!json_hook_count);
    owned.release();
    decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: `{"child":{"a/b~":true}}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
        skip_unknown: true,
    )!!;
    assert(json_hook_count == 2 && json_hook_order[0] == 1 && json_hook_order[1] == 2);
    assert(!diagnostic.cause && !diagnostic.pointer.len);
    owned.release();
    json_hook_count = 0;
    if (catch excuse = decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: `{"child":{"amount":13}}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT && diagnostic.cause == excuse);
        assert(diagnostic.has_text_position && diagnostic.pointer == "/child");
    } else {
        assert(false);
    }
    assert(!json_hook_count);
}

fn void test_json_reader_requires_exact_fixed_array_and_lane_lengths() @test {
    initialize_json_descriptions();
    register_described_codecs();
    Acquisitions owned = { .allocator = mem };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String[3] fixed = { `{"fixed":[]}`, `{"fixed":[{}]}`, `{"fixed":[{},{},{}]}` };
    foreach (source : fixed) {
        JsonDefaults value;
        if (catch excuse = decode_json_value(
            type: serial::described_type(JsonDefaults)!!,
            source: source,
            owned: &owned,
            diagnostic: &diagnostic,
            value: &value,
        )) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR && diagnostic.pointer == "/fixed");
        } else {
            assert(false);
        }
        owned.release();
    }
    String[4] lanes = {
        `{"cells":[1,2]}`,
        `{"cells":[1,2,3,4]}`,
        `{"basis":[1,2,3]}`,
        `{"basis":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]}`,
    };
    foreach (index, source : lanes) {
        Owner value;
        if (catch excuse = decode_json_value(
            type: serial::described_type(Owner)!!,
            source: source,
            owned: &owned,
            diagnostic: &diagnostic,
            value: &value,
        )) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
            assert(diagnostic.pointer == (index < 2 ? "/cells" : "/basis"));
        } else {
            assert(false);
        }
        owned.release();
    }
}

fn void test_json_reader_resolves_live_node_and_asset_references() @test {
    initialize_json_descriptions();
    Fixture fixture;
    create_fixture(&fixture);
    defer destroy_fixture(&fixture);
    Node* node = fixture.destination.add_node(name: "existing")!!;
    Node*[1] nodes = { node };
    MaterialId material = fixture.assets.add_material({}, "material-key")!!;
    Geometry geometry;
    GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "geometry-key")!!;
    ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .nodes = nodes[..] };
    Acquisitions owned = { .allocator = mem };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    context.diagnostic = &diagnostic;
    JsonReferences value;
    decode_json_value(
        type: serial::described_type(JsonReferences)!!,
        source: `{"target":0,"material":"material-key","geometry":"geometry-key"}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
        context: &context,
    )!!;
    assert(c3d::same_id(value.target, node.id));
    assert(c3d::same_id(value.material, material) && c3d::same_id(value.geometry, geometry_id));
    owned.release();
    decode_json_value(
        type: serial::described_type(JsonReferences)!!,
        source: `{"target":null,"material":null,"geometry":null}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
        context: &context,
    )!!;
    assert(!value.target.index && !value.material.index && !value.geometry.index);
    owned.release();
    String[3] invalid = { `{"target":1}`, `{"material":"missing"}`, `{"material":"geometry-key"}` };
    foreach (index, source : invalid) {
        if (catch excuse = decode_json_value(
            type: serial::described_type(JsonReferences)!!,
            source: source,
            owned: &owned,
            diagnostic: &diagnostic,
            value: &value,
            context: &context,
        )) {
            assert(excuse == (index == 0 ? c3d::ASSET_FORMAT_ERROR : c3d::INVALID_ID));
            assert(diagnostic.pointer == (index == 0 ? "/target" : "/material"));
            if (index) assert(diagnostic.asset_key == (index == 1 ? "missing" : "geometry-key"));
        } else {
            assert(false);
        }
        owned.release();
    }
    assert(fixture.destination.world.is_alive(node.id) && node.name == "existing");
    assert(c3d::same_id(fixture.assets.find_material("material-key")!!, material));
    assert(c3d::same_id(fixture.assets.find_geometry("geometry-key")!!, geometry_id));
}

fn void test_json_reader_maps_primitive_kinds_and_rejects_invalid_representations() @test {
    initialize_json_descriptions();
    Acquisitions owned = { .allocator = mem };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    JsonScalars value;
    decode_json_value(
        type: serial::described_type(JsonScalars)!!,
        source: `{
            "enabled":true,"signed_byte":-128,"byte":255,"small":-32768,"positive":65535,
            "count":-2147483648,"unsigned_count":4294967295,
            "large":"-9223372036854775808","huge":"18446744073709551615",
            "single":"f32:7f800001","wide":"f64:7ff0000000000001",
            "pair":[-0.0,1.25],"triple":[-1,2,3],"lanes":[0,1,2,3],"rotation":[0,0,0,1],
            "mode":"SECOND","numbers":[-1,0,2147483647]
        }`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )!!;
    assert(value.enabled && value.signed_byte == ichar::min && value.byte == char::max);
    assert(value.small == short::min && value.positive == ushort::max);
    assert(value.count == int::min && value.unsigned_count == uint::max);
    assert(value.large == long::min && value.huge == ulong::max);
    assert(bitcast(value.single, uint) == 0x7f800001U && bitcast(value.wide, ulong) == 0x7ff0000000000001UL);
    assert(bitcast(value.pair.x, uint) == 0x80000000U && value.pair.y == 1.25f);
    assert(value.triple == (Vec3){ -1, 2, 3 } && value.lanes == (Vec4){ 0, 1, 2, 3 });
    assert(value.rotation.v == (Vec4){ 0, 0, 0, 1 } && value.mode == SECOND);
    assert(value.numbers.len == 3 && value.numbers[0] == -1 && value.numbers[2] == int::max);
    owned.release();
    String[10] invalid = {
        `{"enabled":1}`,
        `{"signed_byte":128}`,
        `{"byte":-1}`,
        `{"positive":65536}`,
        `{"count":1e0}`,
        `{"large":1}`,
        `{"single":"f32:3f800000"}`,
        `{"mode":"second"}`,
        `{"numbers":[0,1.5]}`,
        `{"pair":[0,{}]}`,
    };
    String[10] pointers = {
        "/enabled", "/signed_byte", "/byte", "/positive", "/count",
        "/large", "/single", "/mode", "/numbers/1", "/pair/1",
    };
    foreach (index, source : invalid) {
        if (catch excuse = decode_json_value(
            type: serial::described_type(JsonScalars)!!,
            source: source,
            owned: &owned,
            diagnostic: &diagnostic,
            value: &value,
        )) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR && diagnostic.pointer == pointers[index]);
        } else {
            assert(false);
        }
        owned.release();
    }
}
