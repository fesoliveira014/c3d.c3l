module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::physics @public;
import c3d::physics::cloth;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::math;

fn Node* add_cloth_fixture(Fixture* fixture, uint candidate_capacity = 2048) @private {
    serial::register_core_codecs()!!;
    Node* contact = add_sphere(
        scene: &fixture.source,
        parent: fixture.root,
        name: "contact",
        kind: STATIC,
    );
    Node* node = fixture.source.add_mesh(
        geometry: fixture.geometry,
        material: {},
        parent: fixture.root,
        name: "fabric",
    )!!;
    contact.local.position = fixture.assets.geometry(fixture.geometry).data.positions[0];
    fixture.source.get(node, Mesh).cast_shadow = false;
    fixture.source.get(node, Mesh).trace = false;
    ClothDesc desc = cloth::default_cloth_desc();
    uint[4] pins = { 3, 1, 1, 0 };
    ClothSeam[4] seams = {
        { .first = 3, .second = 0 },
        { .first = 0, .second = 1 },
        { .first = 3, .second = 0 },
        { .first = 1, .second = 1 },
    };
    desc.pins = &pins;
    desc.seams = &seams;
    desc.colliders = (&contact.id)[:1];
    desc.substeps = 2;
    desc.iterations = 3;
    desc.stretch_stiffness = 0.75f;
    desc.bend_stiffness = 0.25f;
    desc.damping = 0.3f;
    desc.thickness = 0.04f;
    desc.gravity_scale = 0.2f;
    desc.collide_ground = true;
    desc.ground_height = -3;
    desc.collisions = {
        .contact_tolerance = 0.0002f,
        .contact_iterations = 12,
        .max_shapes = 64,
        .max_candidates = candidate_capacity,
        .max_contacts = 1024,
        .self_collision = true,
    };
    fixture.source.update_world();
    fixture.source.attach_cloth(assets: &fixture.assets, node: node, desc: desc)!!;
    return node;
}

fn Node* child_named(Node* parent, String name) @private {
    for (Node* node = parent.first_child; node; node = node.next_sibling) if (node.name == name) return node;
    return null;
}

fn void check_authored_seams(Cloth* owner) @private {
    ClothSeam[] seams = owner.authoring.desc.seams;
    assert(seams.len == 4);
    assert(seams[0].first == 3 && seams[0].second == 0);
    assert(seams[1].first == 0 && seams[1].second == 1);
    assert(seams[2].first == 3 && seams[2].second == 0);
    assert(seams[3].first == 1 && seams[3].second == 1);
}

fn char[] prior_cloth_text(String text, uint version) @private {
    String first_field = version == 1 ? "\"contact_tolerance\"" : "\"self_collision\"";
    sz field_start = text.index_of(first_field)!!;
    sz fields_start = text[:field_start].rindex_of_char(',')!!;
    sz seams_start = text.index_of("\"seams\"")!!;
    sz fields_end = seams_start + text[seams_start..].index_of_char(']')!! + 1;
    char[] legacy = alloc::new_array(tmem, char, text.len - (fields_end - fields_start));
    legacy[:fields_start] = ((char[])text[:fields_start])[..];
    legacy[fields_start..] = ((char[])text[fields_end..])[..];

    sz cloth_start = ((String)legacy).index_of("\"cloth\"")!!;
    sz version_start = cloth_start + ((String)legacy[cloth_start..]).index_of("\"version\"")!!;
    sz version_value = version_start + ((String)legacy[version_start..]).index_of_char(':')!! + 1;
    while (legacy[version_value] == ' ') version_value++;
    assert(legacy[version_value] == '3');
    legacy[version_value] = (char)('0' + version);
    return legacy;
}

fn void test_cloth_both_formats_preserve_source_authoring_and_restore_pending() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node* node = add_cloth_fixture(&fixture);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;

            PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&source_world);
            assert(@catch(cloth::prepare(&fixture.source, &fixture.assets, node)) == physics::NO_BODY);
            source_world.update(0);
            cloth::prepare(&fixture.source, &fixture.assets, node)!!;
            assert(fixture.source.get(node, Cloth).is_prepared());
            assert(!c3d::same_id(fixture.source.get(node, Mesh).geometry, fixture.geometry));
            assert(bytes == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!);

            source_world.update(physics::DEFAULT_FIXED_DT);
            source_world.update_cloths();
            assert(fixture.source.get(node, Cloth).state.contact_result.candidates > 0);
            assert(bytes == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!);

            uint free_geometry = fixture.assets.geometries.free_count;
            uint source_revision = fixture.assets.geometry(fixture.geometry).header.revision;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Node* restored_cloth = child_named(restored, "fabric");
            Cloth* owner = fixture.destination.get(restored_cloth, Cloth);
            Mesh* mesh = fixture.destination.get(restored_cloth, Mesh);
            assert(owner && !owner.is_prepared() && owner.state == null);
            assert(c3d::same_id(mesh.geometry, fixture.geometry) && !mesh.vertex_motion && !mesh.cast_shadow && !mesh.trace);
            assert(owner.authoring.desc.pins == (uint[4]){ 3, 1, 1, 0 }[..]);
            check_authored_seams(owner);
            assert(owner.authoring.desc.colliders.len == 1);
            assert(fixture.destination.node(owner.authoring.desc.colliders[0]).name == "contact");
            assert(owner.authoring.desc.gravity_scale == 0.2f && owner.authoring.desc.ground_height == -3);
            ClothCollisionDesc collisions = owner.authoring.desc.collisions;
            assert(collisions.self_collision);
            assert(collisions.contact_tolerance == 0.0002f && collisions.contact_iterations == 12);
            assert(collisions.max_shapes == 64 && collisions.max_candidates == 2048 && collisions.max_contacts == 1024);
            assert(fixture.assets.geometries.free_count == free_geometry);
            assert(fixture.assets.geometry(fixture.geometry).header.revision == source_revision);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);

            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            assert(@catch(cloth::prepare_subtree(&fixture.destination, &fixture.assets, restored)) == physics::NO_BODY);
            world.update(0);
            cloth::prepare_subtree(&fixture.destination, &fixture.assets, restored)!!;
            GeometryId generated = fixture.destination.get(restored_cloth, Mesh).geometry;
            assert(owner.is_prepared() && !c3d::same_id(generated, fixture.geometry));
            cloth::prepare_subtree(&fixture.destination, &fixture.assets, restored)!!;
            assert(c3d::same_id(generated, fixture.destination.get(restored_cloth, Mesh).geometry));
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_cloth_contact_failure_keeps_serialized_self_authoring() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node* node = add_cloth_fixture(&fixture, 1);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            PhysicsWorld world = create_world(&fixture.source, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.update(0);
            cloth::prepare(&fixture.source, &fixture.assets, node)!!;
            world.update_cloths();

            Cloth* owner = fixture.source.get(node, Cloth);
            assert(owner.state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
            assert(owner.state.contact_result.stage == cloth::ClothContactStage.CANDIDATES);
            assert(owner.authoring.desc.collisions.self_collision);
            check_authored_seams(owner);
            assert(bytes == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_cloth_late_authoring_copy_failure_rolls_back_body_and_mesh() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            CopyFailure failure = { .backing = &tracker };
            Fixture fixture;
            create_fixture(&fixture, &failure);
            defer destroy_fixture(&fixture);
            add_cloth_fixture(&fixture);
            @pool() {
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                uint before = fixture.destination.world.entities.free_count;
                uint geometries = fixture.assets.geometries.free_count;
                serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
                options.allocator = mem;
                failure.enabled = true;
                assert(@catch(decode(
                    fixture: &fixture,
                    bytes: bytes,
                    text_mode: text_mode,
                    options: options,
                )) == c3d::CAPACITY_EXCEEDED);
                failure.enabled = false;
                assert(failure.copies == 2);
                assert(fixture.destination.world.entities.free_count == before);
                assert(fixture.destination.count(Cloth) == 0 && fixture.destination.count(Mesh) == 0);
                assert(fixture.destination.count(PhysicsBody) == 0 && fixture.assets.geometries.free_count == geometries);
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_cloth_prior_text_defaults_contacts_and_prior_binary_is_unsupported() @test {
    foreach (version : (uint[2]){ 1, 2 }) @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        add_cloth_fixture(&fixture);

        String text = (String)encode(
            scene: &fixture.source,
            assets: &fixture.assets,
            root: fixture.root,
            text_mode: true,
        )!!;
        Node* restored = decode(&fixture, prior_cloth_text(text, version), true)!!;
        Cloth* owner = fixture.destination.get(child_named(restored, "fabric"), Cloth);
        ClothCollisionDesc collisions = owner.authoring.desc.collisions;
        ClothCollisionDesc defaults = cloth::default_cloth_collision_desc();
        assert(!owner.is_prepared() && owner.state == null);
        assert(!collisions.self_collision && !owner.authoring.desc.seams.len);
        if (version == 1) {
            assert(collisions.contact_tolerance == defaults.contact_tolerance);
            assert(collisions.contact_iterations == defaults.contact_iterations);
            assert(collisions.max_shapes == defaults.max_shapes);
            assert(collisions.max_candidates == defaults.max_candidates);
            assert(collisions.max_contacts == defaults.max_contacts);
        } else {
            assert(collisions.contact_tolerance == 0.0002f && collisions.contact_iterations == 12);
            assert(collisions.max_shapes == 64 && collisions.max_candidates == 2048 && collisions.max_contacts == 1024);
        }
        assert(owner.authoring.desc.pins == (uint[4]){ 3, 1, 1, 0 }[..]);
        assert(owner.authoring.desc.gravity_scale == 0.2f && owner.authoring.desc.ground_height == -3);

        char[] binary = encode(
            scene: &fixture.source,
            assets: &fixture.assets,
            root: fixture.root,
            text_mode: false,
        )!!;
        sz type_version = ((String)binary).index_of("cloth")!! + "cloth".len;
        assert(binary[type_version] == 3);
        binary[type_version] = (char)version;
        uint before = fixture.destination.world.entities.free_count;
        uint geometries = fixture.assets.geometries.free_count;
        uint cloths = fixture.destination.count(Cloth);
        assert(@catch(decode(&fixture, binary, false)) == c3d::UNSUPPORTED);
        assert(fixture.destination.world.entities.free_count == before);
        assert(fixture.assets.geometries.free_count == geometries);
        assert(fixture.destination.count(Cloth) == cloths);
    };
}
