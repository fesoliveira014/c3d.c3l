module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;
import std::core::mem::allocators;
import std::io::path;
import std::math;
import b3;

struct Rig @private {
    ModelId model;
    Node* root;
    Node* skin;
    Ragdoll* ragdoll;
}

fn ModelId rig_model(Fixture* fixture, bool optional_node = false) @private {
    serial::register_core_codecs()!!;
    Path source = path::tnew($$FILEPATH)!!;
    String filename = (String)source.parent()!!.tappend("../../../test/fixtures/gltf", "skin.gltf")!!;
    ModelId model = gltf::load_model(&fixture.assets, filename)!!;
    if (optional_node) {
        ModelTemplate* data = &fixture.assets.model(model).data;
        NodeTemplate[] nodes = alloc::new_array(mem, NodeTemplate, data.nodes.len + 1);
        nodes[:data.nodes.len] = data.nodes[..];
        nodes[data.nodes.len] = { .parent = -1, .name = "optional".copy(mem), .local = maths::TRANSFORM_IDENTITY, .layers = 1, .visible = true };
        alloc::free(mem, data.nodes.ptr);
        data.nodes = nodes;
    }
    return model;
}

fn Rig add_rig(Scene* scene, AssetStore* assets, ModelId model) @private {
    Node* root = model::instantiate(
        assets: assets,
        scene: scene,
        model: model,
        name: "rig",
    )!!;
    Node* skin = scene.get(root, ModelInstance).present_node(1);
    scene.update_world();
    RagdollBone[2] bones = { physics::default_ragdoll_bone(0), physics::default_ragdoll_bone(1) };
    bones[0].radius = 0.1f;
    bones[1].radius = 0.1f;
    bones[1].length = 1;
    bones[1].drive = { .enabled = true, .hertz = 3, .damping_ratio = 0.8f };
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = &bones;
    scene.build_ragdoll(assets: assets, skin_node: skin, desc: desc)!!;
    scene.update_world();
    return { .model = model, .root = root, .skin = skin, .ragdoll = scene.get(skin, Ragdoll) };
}

fn void configure_rig(PhysicsWorld* world, Rig* rig) @private {
    world.set_bone_mode(skin_node: rig.skin, bone: 1, mode: SIMULATED);
    rig.ragdoll.bone_weights[..] = ((float[2]){ 0.25f, 1.5f })[..];
    rig.ragdoll.weight = 1.75f;
    rig.ragdoll.drive_strength = 2.25f;
}

fn char[] ragdoll_payload(char[] bytes) @private {
    SubtreeHeader header = serial::read_header(bytes)!!;
    Reader types = serial::reader_over(serial::chunk_bytes(bytes, header.chunk_count, TYPES));
    uint count = types.read_uint()!!;
    uint ragdoll_type = serial::INDEX_NONE;
    for (uint index = 0; index < count; index++) {
        String name = types.read_string()!!;
        (void)types.read_uint()!!;
        if (name == "ragdoll") ragdoll_type = index;
    }
    assert(ragdoll_type != serial::INDEX_NONE);
    Reader groups = serial::reader_over(serial::chunk_bytes(bytes, header.chunk_count, COMPONENTS));
    uint group_count = groups.read_uint()!!;
    for (uint group = 0; group < group_count; group++) {
        uint type = groups.read_uint()!!;
        uint entries = groups.read_uint()!!;
        for (uint index = 0; index < entries; index++) {
            (void)groups.read_uint()!!;
            uint size = groups.read_uint()!!;
            char[] payload = groups.read_bytes(size)!!;
            if (type == ragdoll_type) return payload;
        }
    }
    unreachable();
}

fn uint ragdoll_value(TextDocument* document) @private {
    foreach (uint index, value : document.values) {
        if (value.name == "ragdoll") return serial::json_member(document, index, "value");
    }
    unreachable();
}

fn String replace_token(String text, TextValue token, String replacement) @private {
    char[] changed = alloc::new_array(tmem, char, text.len - token.length + replacement.len);
    changed[:token.offset] = ((char[])text[:token.offset])[..];
    changed[token.offset:replacement.len] = ((char[])replacement)[..];
    changed[token.offset + replacement.len..] = ((char[])text[token.offset + token.length..])[..];
    return (String)changed;
}

fn void test_ragdoll_both_formats_preserve_configuration_and_match_public_restart() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Rig original = add_rig(&fixture.source, &fixture.assets, rig_model(&fixture));
            PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&source_world);
            configure_rig(&source_world, &original);
            Node* independent = add_sphere(
                scene: &fixture.source,
                parent: original.root,
                name: "independent",
                kind: DYNAMIC,
            );
            independent.local.position = { 50, 50, 50 };
            PhysicsBody* independent_body = fixture.source.get(independent, PhysicsBody);
            independent_body.body.linear_velocity = { 4, 5, 6 };
            independent_body.body.angular_velocity = { -1, -2, -3 };
            original.ragdoll.bone_nodes[1].local.position.x += 0.2f;
            fixture.source.update_world();
            PhysicsBody* original_body = fixture.source.get(original.ragdoll.bone_nodes[1], PhysicsBody);
            original_body.body.linear_velocity = { 7, 8, 9 };
            original_body.body.angular_velocity = { 1, 2, 3 };
            source_world.update(0);
            original.ragdoll.recoveries = 7;
            original.ragdoll.last_facing = FACE_DOWN;
            original.ragdoll.frozen[0].position = { 99, 98, 97 };
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: original.root,
                text_mode: text_mode,
            )!!;
            assert(original_body.body.linear_velocity == (Vec3){ 7, 8, 9 });
            assert(original_body.body.angular_velocity == (Vec3){ 1, 2, 3 });
            assert(independent_body.body.linear_velocity == (Vec3){ 4, 5, 6 });
            assert(independent_body.body.angular_velocity == (Vec3){ -1, -2, -3 });
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            PhysicsBody* independent_copy = fixture.destination.get(child_named(restored, "independent"), PhysicsBody);
            assert(independent_copy.body.linear_velocity == independent_body.body.linear_velocity);
            assert(independent_copy.body.angular_velocity == independent_body.body.angular_velocity);
            Node* skin = fixture.destination.get(restored, ModelInstance).present_node(1);
            Ragdoll* actual = fixture.destination.get(skin, Ragdoll);
            assert(actual.bone_weights == original.ragdoll.bone_weights && actual.bone_modes == original.ragdoll.bone_modes);
            assert(actual.weight == 1.75f && actual.drive_strength == 2.25f && actual.bone_drives[1].hertz == 3);
            assert(actual.parents == original.ragdoll.parents && actual.bone_joints == original.ragdoll.bone_joints);
            assert(actual.joint_bone == original.ragdoll.joint_bone && actual.joint_order == original.ragdoll.joint_order);
            assert(actual.joint_owner == original.ragdoll.joint_owner && actual.bone_parents == original.ragdoll.bone_parents);
            assert(actual.bone_nodes.ptr != original.ragdoll.bone_nodes.ptr && actual.parents.ptr != original.ragdoll.parents.ptr);
            assert(actual.recoveries == 0 && actual.last_facing == FACE_UP);
            assert(actual.frozen[0].position == fixture.destination.get(skin, SkinBinding).joints[0].local.position);
            assert(fixture.destination.count(RigidBody) == 0 && fixture.destination.count(Joint) == 0);
            foreach (node : actual.bone_nodes) {
                PhysicsBody* body = fixture.destination.get(node, PhysicsBody);
                assert(body.status == PENDING && body.body.linear_velocity == (Vec3){} && body.body.angular_velocity == (Vec3){});
            }
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            Scene reference = scene::create_scene(mem, { .max_nodes = 32 });
            defer scene::destroy_scene(&reference);
            physics::register_physics(&reference)!!;
            Rig expected = add_rig(&reference, &fixture.assets, original.model);
            PhysicsWorld expected_world = create_world(&reference, &fixture.assets);
            defer physics::destroy_physics_world(&expected_world);
            configure_rig(&expected_world, &expected);
            foreach (index, node : expected.ragdoll.bone_nodes) node.local = actual.bone_nodes[index].local;
            reference.update_world();
            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.update(0);
            expected_world.update(0);
            foreach (index, node : actual.bone_nodes) {
                RigidBody* body = fixture.destination.get(node, RigidBody);
                RigidBody* expected_body = reference.get(expected.ragdoll.bone_nodes[index], RigidBody);
                assert(body.kind == expected_body.kind);
                assert((body.current.position - expected_body.current.position).length() < 1e-4f);
                assert(body.body.linear_velocity() == (Vec3){} && body.body.angular_velocity() == (Vec3){});
            }
            world.update(physics::DEFAULT_FIXED_DT);
            expected_world.update(physics::DEFAULT_FIXED_DT);
            world.update_ragdolls();
            expected_world.update_ragdolls();
            fixture.destination.update_world();
            reference.update_world();
            foreach (index, node : actual.bone_nodes) {
                Node* expected_node = expected.ragdoll.bone_nodes[index];
                assert((node.world_position() - expected_node.world_position()).length() < 1e-3f);
            }
            assert(world.build_failures().len == 0 && expected_world.build_failures().len == 0);
        };
    }
}

fn void test_ragdoll_mode_body_mismatch_is_rejected_before_attachment() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Rig original = add_rig(&fixture.source, &fixture.assets, rig_model(&fixture));
        PhysicsWorld world = create_world(&fixture.source, &fixture.assets);
        defer physics::destroy_physics_world(&world);
        configure_rig(&world, &original);
        String text = (String)encode(
            scene: &fixture.source,
            assets: &fixture.assets,
            root: original.root,
            text_mode: true,
        )!!;
        String invalid = text.treplace("SIMULATED", "ANIMATED");
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(decode(
            fixture: &fixture,
            bytes: (char[])invalid,
            text_mode: true,
            options: options,
        )) == c3d::INVALID_ARGUMENT);
        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.type_name == "ragdoll");
        assert(diagnostic.node_path.len && diagnostic.has_bone_index && diagnostic.bone_index == 1);
        assert(fixture.destination.world.entities.free_count == before);
        assert(fixture.destination.count(ModelInstance) == 0 && fixture.destination.count(PhysicsBody) == 0);
    };
}

fn void test_ragdoll_absent_model_bone_reference_reports_full_details_in_both_formats() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Rig original = add_rig(&fixture.source, &fixture.assets, rig_model(&fixture, true));
            ModelInstance* instance = fixture.source.get(original.root, ModelInstance);
            fixture.source.remove(instance.present_node(4));
            Node* replacement = fixture.source.add_node(original.root, "replacement")!!;
            assert(instance.present_node(4) == null && replacement.id.index == instance.node_entities[4].index);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: original.root,
                text_mode: text_mode,
            )!!;
            SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
            defer serial::destroy_serial_diagnostic(&diagnostic);
            if (text_mode) {
                String text = (String)bytes;
                TextDocument document = serial::parse_text(
                    allocator: tmem,
                    source: text,
                    limits: serial::TEXT_LIMITS_DEFAULT,
                    diagnostic: &diagnostic,
                )!!;
                defer serial::destroy_text_document(&document);
                uint bones = serial::json_member(&document, ragdoll_value(&document), "bone_nodes");
                uint second = document.values[bones + 1].end;
                bytes = (char[])replace_token(text, document.values[second], "{\"node\":null,\"model\":0,\"template_index\":4}");
            } else {
                char[] payload = ragdoll_payload(bytes);
                Reader reader = serial::reader_over(payload);
                (void)reader.read_uint()!!;
                (void)reader.read_ulong()!!;
                (void)reader.read_uint()!!;
                assert(reader.read_uint()!! == 2);
                (void)reader.read_uint()!!;
                for (uint index = 0; index < 2; index++) {
                    (void)reader.read_uint()!!;
                    (void)reader.read_ulong()!!;
                    char[] reference = reader.read_bytes(reader.read_uint()!!)!!;
                    if (index == 0) continue;
                    assert(reference.len == 3 * uint::size);
                    Writer writer = serial::writer_over(reference);
                    writer.write_uint(serial::INDEX_NONE);
                    writer.write_uint(0);
                    writer.write_uint(4);
                }
            }
            ReadOptions options = serial::READ_OPTIONS_DEFAULT;
            options.diagnostic = &diagnostic;
            uint before = fixture.destination.world.entities.free_count;
            fault failure = @catch(decode(
                fixture: &fixture,
                bytes: bytes,
                text_mode: text_mode,
                options: options,
            ));
            assert(failure == physics::NO_BODY, "text=%s fault=%s type=%s model=%s", text_mode, failure, diagnostic.type_name, diagnostic.model_key);
            assert(diagnostic.cause == physics::NO_BODY && diagnostic.type_name == "ragdoll");
            assert(diagnostic.node_path.len && diagnostic.has_bone_index && diagnostic.bone_index == 1);
            assert(diagnostic.has_template_index && diagnostic.template_index == 4);
            assert(diagnostic.model_key == fixture.assets.model(original.model).header.key);
            assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(Ragdoll) == 0);
        };
    }
}

fn void test_ragdoll_owned_block_failure_rolls_back_earlier_components() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RejectSize failure = { .backing = &tracker };
            Fixture fixture;
            create_fixture(&fixture, &failure);
            defer destroy_fixture(&fixture);
            Rig original = add_rig(&fixture.source, &fixture.assets, rig_model(&fixture));
            Ragdoll* source = original.ragdoll;
            failure.size = (char*)(source.joint_worlds.ptr + source.joint_worlds.len) - (char*)source.bone_nodes.ptr;
            Node* existing = fixture.destination.add_node(name: "untouched")!!;
            existing.local.position = { 4, 5, 6 };
            existing.visible = false;
            @pool() {
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: original.root,
                    text_mode: text_mode,
                )!!;
                ReadOptions options = serial::READ_OPTIONS_DEFAULT;
                options.allocator = mem;
                uint before = fixture.destination.world.entities.free_count;
                failure.enabled = true;
                assert(@catch(decode(
                    fixture: &fixture,
                    bytes: bytes,
                    text_mode: text_mode,
                    options: options,
                )) == c3d::CAPACITY_EXCEEDED);
                failure.enabled = false;
                assert(failure.failures == 1 && fixture.destination.world.entities.free_count == before);
                assert(fixture.destination.count(ModelInstance) == 0 && fixture.destination.count(SkinBinding) == 0);
                assert(fixture.destination.count(Ragdoll) == 0 && fixture.destination.count(PhysicsBody) == 0);
                assert(existing.name == "untouched" && !existing.visible && existing.local.position == (Vec3){ 4, 5, 6 });
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn char[] edited_ragdoll_control(
    char[] bytes,
    bool text_mode,
    uint control,
    float invalid,
) @private {
    if (text_mode) {
        String text = (String)bytes;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(tmem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        String[3] names = { "weight", "bone_weights", "drive_strength" };
        uint token = serial::json_member(&document, ragdoll_value(&document), names[control]);
        if (control == 1) token += 2;
        char[serial::TEXT_NUMBER_FORMAT_BYTES] storage;
        String replacement = serial::text_format_f32(bitcast(invalid, uint), storage[..])!!;
        return (char[])replace_token(text, document.values[token], replacement);
    }
    char[] changed = alloc::new_array(tmem, char, bytes.len);
    changed[..] = bytes[..];
    char[] payload = ragdoll_payload(changed);
    usz offset = control == 0 ? payload.len - 2 * float::size : payload.len - float::size;
    if (control == 1) {
        char[float::size] expected;
        Writer reference = serial::writer_over(&expected);
        reference.write_float(1.5f);
        uint found;
        for (usz index = 0; index + float::size <= payload.len; index++) {
            if (payload[index:float::size] != expected[..]) continue;
            offset = index;
            found++;
        }
        assert(found == 1);
    }
    Writer writer = serial::writer_over(payload[offset:float::size]);
    writer.write_float(invalid);
    return changed;
}

fn void test_ragdoll_control_domain_is_identical_for_readers_and_writers() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Rig rig = add_rig(&fixture.source, &fixture.assets, rig_model(&fixture));
            PhysicsWorld world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            configure_rig(&world, &rig);
            char[] valid = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: rig.root,
                text_mode: text_mode,
            )!!;
            float*[3] controls = { &rig.ragdoll.weight, &rig.ragdoll.bone_weights[1], &rig.ragdoll.drive_strength };
            float[3] original = { 1.75f, 1.5f, 2.25f };
            float[4] rejected = { -1, bitcast(0x7fc00000u, float), bitcast(0x7f800000u, float), bitcast(0xff800000u, float) };
            SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
            defer serial::destroy_serial_diagnostic(&diagnostic);
            WriteOptions writing = { .diagnostic = &diagnostic };
            ReadOptions reading = serial::READ_OPTIONS_DEFAULT;
            reading.diagnostic = &diagnostic;
            uint before = fixture.destination.world.entities.free_count;
            foreach (uint control, pointer : controls) {
                foreach (invalid : rejected) {
                    *pointer = invalid;
                    assert(@catch(encode(
                        scene: &fixture.source,
                        assets: &fixture.assets,
                        root: rig.root,
                        text_mode: text_mode,
                        options: writing,
                    )) == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.node_path.len && diagnostic.type_name == "ragdoll");
                    assert(diagnostic.has_bone_index == (control == 1));
                    if (control == 1) assert(diagnostic.bone_index == 1);
                }
                *pointer = original[control];
                foreach (invalid : rejected) {
                    char[] edited = edited_ragdoll_control(
                        bytes: valid,
                        text_mode: text_mode,
                        control: control,
                        invalid: invalid,
                    );
                    assert(@catch(decode(
                        fixture: &fixture,
                        bytes: edited,
                        text_mode: text_mode,
                        options: reading,
                    )) == c3d::INVALID_ARGUMENT);
                    assert(diagnostic.node_path.len && diagnostic.type_name == "ragdoll");
                    assert(diagnostic.has_bone_index == (control == 1));
                    if (control == 1) assert(diagnostic.bone_index == 1);
                    assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(Ragdoll) == 0);
                }
            }
            foreach (pointer : controls) *pointer = 0;
            char[] zero = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: rig.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, zero, text_mode)!!;
            Node* skin = fixture.destination.get(restored, ModelInstance).present_node(1);
            Ragdoll* actual = fixture.destination.get(skin, Ragdoll);
            assert(actual.weight == 0 && actual.bone_weights[1] == 0 && actual.drive_strength == 0);
        };
    }
}
