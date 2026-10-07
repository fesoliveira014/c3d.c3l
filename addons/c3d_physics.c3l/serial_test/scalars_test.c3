module c3d_physics_serial_test;

import c3d;
import c3d::physics;
import c3d::scene;
import c3d::serial @public;
import std::math;

struct ScalarOwner @private {
    String name;
    float*[] fields;
}

fn usz scalar_byte_offset(char[] bytes, uint bits) @private {
    usz result;
    uint matches;
    for (usz offset = 0; offset + uint::size <= bytes.len; offset++) {
        Reader reader = serial::reader_over(bytes[offset:uint::size]);
        if (reader.read_uint()!! != bits) continue;
        result = offset;
        matches++;
    }
    assert(matches == 1);
    return result;
}

fn TextValue scalar_text_token(TextDocument* document, String text, uint bits) @private {
    char[serial::TEXT_NUMBER_FORMAT_BYTES] storage;
    String expected = serial::text_format_f32(bits, storage[..])!!;
    TextValue result;
    uint matches;
    foreach (token : document.values) {
        if (text[token.offset:token.length] != expected) continue;
        result = token;
        matches++;
    }
    assert(matches == 1);
    return result;
}

fn void test_physics_owner_scalars_share_finite_domains_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        ColliderDesc collider = physics::default_collider_desc(SPHERE);
        fixture.source.add_physics_body(fixture.root, physics::default_body_desc(), (&collider)[:1])!!;
        Wind* wind = fixture.source.add(fixture.root, (Wind){});
        Force* force = fixture.source.add(fixture.root, (Force){});
        Buoyancy* buoyancy = fixture.source.add(fixture.root, (Buoyancy){});
        BodyDesc* body = &fixture.source.get(fixture.root, PhysicsBody).body;
        float*[6] wind_fields = {
            &wind.velocity.x, &wind.velocity.y, &wind.velocity.z, &wind.drag, &wind.lift, &wind.max_speed,
        };
        float*[6] force_fields = {
            &force.force.x, &force.force.y, &force.force.z, &force.local_point.x, &force.local_point.y, &force.local_point.z,
        };
        float*[2] buoyancy_fields = { &buoyancy.fluid_density, &buoyancy.linear_drag };
        float*[9] body_fields = {
            &body.linear_velocity.x, &body.linear_velocity.y, &body.linear_velocity.z,
            &body.angular_velocity.x, &body.angular_velocity.y, &body.angular_velocity.z,
            &body.linear_damping, &body.angular_damping, &body.gravity_scale,
        };
        ScalarOwner[4] owners = {
            { .name = "wind", .fields = wind_fields[..] },
            { .name = "force", .fields = force_fields[..] },
            { .name = "buoyancy", .fields = buoyancy_fields[..] },
            { .name = "physics_body", .fields = body_fields[..] },
        };
        uint next_bits = 0xbf912301;
        foreach (owner : owners) foreach (field : owner.fields) {
            *field = bitcast(next_bits, float);
            next_bits += 0x1234;
        }
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        WriteOptions writing = { .diagnostic = &diagnostic };
        ReadOptions reading = serial::READ_OPTIONS_DEFAULT;
        reading.diagnostic = &diagnostic;
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        existing.local.position = { 3, 5, 7 };
        uint free_before = fixture.destination.world.entities.free_count;
        uint[3] rejected = { 0x7fc01234, 0x7f800000, 0xff800000 };
        String[3] replacements = { `"f32:7fc01234"`, `"f32:7f800000"`, `"f32:ff800000"` };
        foreach (text_mode : (bool[2]){ false, true }) {
            char[] valid = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, valid, text_mode)!!;
            assert(valid == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            fixture.destination.remove(restored);
            TextDocument document;
            if (text_mode) document = serial::parse_text(
                allocator: tmem,
                source: (String)valid,
                limits: serial::TEXT_LIMITS_DEFAULT,
                diagnostic: &diagnostic,
            )!!;
            defer if (text_mode) serial::destroy_text_document(&document);
            foreach (owner : owners) {
                foreach (field : owner.fields) {
                    uint original = bitcast(*field, uint);
                    usz offset;
                    TextValue token;
                    if (text_mode) {
                        token = scalar_text_token(&document, (String)valid, original);
                    } else {
                        offset = scalar_byte_offset(valid, original);
                    }
                    foreach (invalid, bits : rejected) {
                        char[] changed;
                        if (text_mode) {
                            changed = (char[])replace_token((String)valid, token, replacements[invalid]);
                        } else {
                            changed = alloc::clone_slice(tmem, valid);
                            Writer patch = serial::writer_over(changed[offset:uint::size]);
                            patch.write_uint(bits);
                        }
                        assert(@catch(decode(
                            fixture: &fixture,
                            bytes: changed,
                            text_mode: text_mode,
                            options: reading,
                        )) == c3d::INVALID_ARGUMENT);
                        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == owner.name);
                        assert(diagnostic.node_path == "/nodes/0" && diagnostic.has_text_position == text_mode);
                        assert(fixture.destination.world.entities.free_count == free_before);
                        assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
                        assert(existing.local.position == (Vec3){ 3, 5, 7 });
                        *field = bitcast(bits, float);
                        assert(@catch(encode(
                            scene: &fixture.source,
                            assets: &fixture.assets,
                            root: fixture.root,
                            text_mode: text_mode,
                            options: writing,
                        )) == c3d::INVALID_ARGUMENT);
                        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == owner.name);
                        assert(diagnostic.node_path == "/nodes/0");
                        *field = bitcast(original, float);
                    }
                }
            }
            assert(valid == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!);
        }
    };
}

fn void test_node_transform_nan_preserves_bytes_in_both_encodings() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            fixture.root.local.position.x = bitcast(0x7fc01234u, float);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            assert(bitcast(restored.local.position.x, uint) == 0x7fc01234);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}
