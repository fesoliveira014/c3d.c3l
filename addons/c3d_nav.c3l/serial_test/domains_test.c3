module c3d_nav_serial_test;

import c3d;
import c3d::nav;
import c3d::scene;
import c3d::serial @public;
import c3d_nav_domains_test @public;
import std::math;

fn void test_nav_volume_serial_rejects_nonfinite_active_fields() @test => check_serial_domain(VOLUME);
fn void test_nav_link_serial_rejects_nonfinite_active_fields() @test => check_serial_domain(LINK);
fn void test_nav_obstacle_serial_rejects_nonfinite_active_fields() @test => check_serial_domain(OBSTACLE);
fn void test_nav_agent_serial_rejects_nonfinite_params_and_position() @test => check_serial_domain(AGENT);

fn char[] changed_scalar(
    char[] bytes,
    bool text_mode,
    uint original,
    uint replacement,
) @local {
    if (text_mode) {
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(tmem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem, source: (String)bytes, limits: serial::TEXT_LIMITS_DEFAULT, diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        char[serial::TEXT_NUMBER_FORMAT_BYTES] original_storage;
        String original_text = serial::text_format_f32(original, original_storage[..])!!;
        char[serial::TEXT_NUMBER_FORMAT_BYTES] replacement_storage;
        String replacement_text = serial::text_format_f32(replacement, replacement_storage[..])!!;
        TextValue selected;
        uint matches;
        foreach (token : document.values) {
            if ((String)bytes[token.offset:token.length] != original_text) continue;
            selected = token;
            matches++;
        }
        assert(matches == 1);
        char[] changed = alloc::new_array(tmem, char, bytes.len - selected.length + replacement_text.len);
        changed[:selected.offset] = bytes[:selected.offset];
        changed[selected.offset:replacement_text.len] = ((char[])replacement_text)[..];
        changed[selected.offset + replacement_text.len..] = bytes[selected.offset + selected.length..];
        return changed;
    }
    char[] changed = alloc::clone_slice(tmem, bytes);
    uint matches;
    for (usz offset = 0; offset + uint::size <= bytes.len; offset++) {
        Reader reader = serial::reader_over(bytes[offset:uint::size]);
        if (reader.read_uint()!! != original) continue;
        Writer writer = serial::writer_over(changed[offset:uint::size]);
        writer.write_uint(replacement);
        matches++;
    }
    assert(matches == 1);
    return changed;
}

fn void check_serial_domain(DomainOwner owner) @local {
    for (uint variant = 0; variant < c3d_nav_domains_test::domain_variants(owner); variant++) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            fixture.source.remove(fixture.root);
            fixture.root = fixture.source.add_node(name: "numeric")!!;
            DomainFixture values;
            c3d_nav_domains_test::setup_domain(&values, owner, variant);
            c3d_nav_domains_test::add_domain(&fixture.source, fixture.root, &values)!!;
            c3d_nav_domains_test::replace_domain(&fixture.source, fixture.root, &values);
            SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
            defer serial::destroy_serial_diagnostic(&diagnostic);
            ReadOptions reading = serial::READ_OPTIONS_DEFAULT;
            reading.diagnostic = &diagnostic;
            Node* existing = fixture.destination.add_node(name: "existing")!!;
            existing.local.position = { 3, 5, 7 };
            uint free_before = fixture.destination.world.entities.free_count;
            foreach (text_mode : (bool[2]){ false, true }) {
                char[] valid = encode(
                    scene: &fixture.source, assets: &fixture.assets, root: fixture.root, text_mode: text_mode,
                )!!;
                Node* restored = decode(&fixture, valid, text_mode)!!;
                assert(valid == encode(
                    scene: &fixture.destination, assets: &fixture.assets, root: restored, text_mode: text_mode,
                )!!);
                fixture.destination.remove(restored);
                foreach (field : values.fields[:values.count]) {
                    uint original = bitcast(*field, uint);
                    foreach (bits : (uint[3]){ 0x7fc01234, 0x7f800000, 0xff800000 }) {
                        char[] changed = changed_scalar(
                            bytes: valid, text_mode: text_mode, original: original, replacement: bits,
                        );
                        assert(@catch(decode(
                            fixture: &fixture, bytes: changed, text_mode: text_mode, options: reading,
                        )) == c3d::INVALID_ARGUMENT);
                        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == values.name);
                        assert(diagnostic.node_path == "/nodes/0" && diagnostic.has_text_position == text_mode);
                        assert(fixture.destination.world.entities.free_count == free_before);
                        assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
                        assert(existing.local.position == (Vec3){ 3, 5, 7 });
                        *field = bitcast(bits, float);
                        c3d_nav_domains_test::replace_domain(&fixture.source, fixture.root, &values);
                        assert(@catch(encode(
                            scene: &fixture.source,
                            assets: &fixture.assets,
                            root: fixture.root,
                            text_mode: text_mode,
                            diagnostic: &diagnostic,
                        )) == c3d::INVALID_ARGUMENT);
                        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == values.name);
                        assert(diagnostic.node_path == "/nodes/0");
                        *field = bitcast(original, float);
                        c3d_nav_domains_test::replace_domain(&fixture.source, fixture.root, &values);
                    }
                }
                assert(valid == encode(
                    scene: &fixture.source, assets: &fixture.assets, root: fixture.root, text_mode: text_mode,
                )!!);
            }
        };
    }
}

fn void test_nav_inactive_and_velocity_targets_preserve_ieee_bits() @test {
    foreach (kind : (AgentTargetKind[2]){ NONE, VELOCITY }) {
        foreach (text_mode : (bool[2]){ false, true }) {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture);
                defer destroy_fixture(&fixture);
                fixture.source.remove(fixture.root);
                fixture.root = fixture.source.add_node(name: "target")!!;
                fixture.source.add_nav_agent(fixture.root, nav::default_nav_agent_params())!!;
                NavAgent* agent = fixture.source.get(fixture.root, NavAgent);
                agent.target_kind = kind;
                agent.target = {
                    bitcast(0x7fc01234u, float), bitcast(0x7f800000u, float), bitcast(0xff800000u, float),
                };
                char[] valid = encode(
                    scene: &fixture.source, assets: &fixture.assets, root: fixture.root, text_mode: text_mode,
                )!!;
                Node* restored = decode(&fixture, valid, text_mode)!!;
                assert(valid == encode(
                    scene: &fixture.destination, assets: &fixture.assets, root: restored, text_mode: text_mode,
                )!!);
            };
        }
    }
}
