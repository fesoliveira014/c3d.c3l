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

fn Node* add_cloth_fixture(Fixture* fixture) @private {
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
    fixture.source.get(node, Mesh).cast_shadow = false;
    fixture.source.get(node, Mesh).trace = false;
    ClothDesc desc = cloth::default_cloth_desc();
    uint[4] pins = { 3, 1, 1, 0 };
    desc.pins = &pins;
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
    fixture.source.update_world();
    fixture.source.attach_cloth(assets: &fixture.assets, node: node, desc: desc)!!;
    return node;
}

fn Node* child_named(Node* parent, String name) @private {
    for (Node* node = parent.first_child; node; node = node.next_sibling) if (node.name == name) return node;
    return null;
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
            assert(owner.authoring.desc.colliders.len == 1);
            assert(fixture.destination.node(owner.authoring.desc.colliders[0]).name == "contact");
            assert(owner.authoring.desc.gravity_scale == 0.2f && owner.authoring.desc.ground_height == -3);
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
