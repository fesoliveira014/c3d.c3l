module c3d_particle_serial_test;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::particle @public;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    Node* root;
}

struct Extra @private {
    uint value;
}

fn void create_fixture(Fixture* fixture, ParticleRenderMode mode, uint capacity = 8) @private {
    particle::register_serial_codecs()!!;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_textures = 8,
        .max_materials = 2,
        .max_samplers = 8,
    });
    fixture.source = scene::create_scene(mem, { .max_nodes = 8 });
    fixture.destination = scene::create_scene(mem, { .max_nodes = capacity });
    particle::register_particles(&fixture.source)!!;
    particle::register_particles(&fixture.destination)!!;
    fixture.source.register(Extra)!!;
    MaterialId material = fixture.assets.add_material(material::standard(), "effect")!!;
    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        geometry = fixture.assets.add_geometry(&box, "particle-mesh")!!;
    };
    fixture.root = fixture.source.add_node(name: "emitter")!!;
    fixture.source.add_node(fixture.root, "authored-child")!!;
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 7;
    desc.seed = 12345;
    desc.render_mode = mode;
    desc.material = material;
    desc.geometry = geometry;
    desc.shape = CONE;
    desc.radius = 2;
    desc.half_extents = { 1, 2, 3 };
    desc.cone_angle = 0.4f;
    desc.rate = 7;
    desc.lifetime = { .min = 2, .max = 3 };
    desc.speed = { .min = 1, .max = 4 };
    desc.size = { .min = 0.2f, .max = 0.7f };
    desc.rotation = { .min = -1, .max = 2 };
    desc.spin = { .min = -3, .max = 3 };
    desc.color_min = { 0.1f, 0.2f, 0.3f, 0.4f };
    desc.color_max = { 2, 1, 0.5f, 0.9f };
    foreach (index, &value : desc.size_over_life.values) *value = (float)index * 0.2f;
    foreach (index, &value : desc.color_over_life.values) *value = { (float)index * 0.1f, 0.4f, 0.6f, 0.8f };
    desc.gravity_scale = -0.5f;
    desc.drag = 0.8f;
    desc.stretch = 2;
    fixture.source.attach_particle_system(fixture.root, desc)!!;
    fixture.source.get(fixture.root, ParticleSystem).emitting = false;
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn char[]? encode(
    Scene* scene,
    AssetStore* assets,
    Node* root,
    bool text_mode,
) @private {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    );
}

fn Node*? decode(
    Fixture* fixture,
    char[] bytes,
    bool text_mode,
    serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT,
) @private {
    if (text_mode) return serial::read_subtree_text(
        scene: &fixture.destination,
        assets: &fixture.assets,
        text: (String)bytes,
        options: options,
    );
    return serial::read_subtree(
        scene: &fixture.destination,
        assets: &fixture.assets,
        bytes: bytes,
        options: options,
    );
}

fn void test_serial_layout_registration() @test {
    particle::register_serial_codecs()!!;
    assert(serial::described_type(ParticleRange)!!.version == 1);
    assert(serial::described_type(ParticleRange)!!.layout == 0xaf1f0c33b5e51627);
    assert(serial::described_type(LifetimeTable)!!.layout == 0xe4c18077262a7a22);
    assert(serial::described_type(LifetimeColorTable)!!.layout == 0x4eacd1a988dfc1b2);
    assert(serial::described_type(ParticleSystemDesc)!!.layout == 0x1a366da2bd207420);
    assert(serial::described_type(particle::ParticleAuthoring)!!.layout == 0xea58cb75a4a73416);
    @pool() {
        String schema = serial::write_schema(tmem)!!;
        assert(schema.contains("particle_system") && schema.contains("emitting"));
        assert(schema.contains("color_over_life") && schema.contains("BILLBOARD"));
    };
}

fn void test_particles_both_encodings_restore_pending_inputs_and_emitting() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        foreach (mode : (ParticleRenderMode[2]){ STRETCHED, MESH }) {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture, mode);
                defer destroy_fixture(&fixture);
                ParticleSystem* source = fixture.source.get(fixture.root, ParticleSystem);
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                assert(bytes == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!);
                particle::prepare(&fixture.source, fixture.root)!!;
                source.emit_burst(3);
                fixture.source.update_world();
                particle::update(&fixture.source, 0.1f);
                assert(source.alive == 3);
                assert(bytes == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!);
                uint free_geometry = fixture.assets.geometries.free_count;
                uint free_materials = fixture.assets.materials.free_count;
                Node* restored = decode(&fixture, bytes, text_mode)!!;
                ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
                assert(!system.is_prepared() && !system.emitting && system.alive == 0);
                assert(system.pending_burst == 0 && system.dropped == 0 && system.emit_accumulator == 0);
                assert(system.desc.capacity == 7 && system.desc.seed == 12345 && system.desc.render_mode == mode);
                assert(system.desc.color_over_life.values[7] == source.desc.color_over_life.values[7]);
                assert(restored.first_child && restored.first_child.name == "authored-child");
                assert(fixture.destination.count(BillboardBatch) == 0 && fixture.destination.count(InstancedMesh) == 0);
                assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.materials.free_count == free_materials);
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
                particle::prepare_subtree(&fixture.destination, restored)!!;
                Entity draw = system.draw_node;
                particle::prepare(&fixture.destination, restored)!!;
                assert(c3d::same_id(system.draw_node, draw) && !system.emitting);
                system.emit_burst(2);
                fixture.destination.update_world();
                particle::update(&fixture.destination, 0.1f);
                assert(system.alive == 2);
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
            };
        }
    }
}

fn void test_particle_draw_roots_and_authored_additions_are_rejected() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, BILLBOARD);
            defer destroy_fixture(&fixture);
            particle::prepare(&fixture.source, fixture.root)!!;
            Node* draw = fixture.source.node(fixture.source.get(fixture.root, ParticleSystem).draw_node);
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: draw,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            Node* child = fixture.source.add_node(draw, "application")!!;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.remove(child);
            fixture.source.add(draw, (Extra){ .value = 9 });
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}

fn void test_particle_read_and_prepare_failures_preserve_authoring() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, BILLBOARD, 2);
            defer destroy_fixture(&fixture);
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            uint free_nodes = fixture.destination.world.entities.free_count;
            uint free_materials = fixture.assets.materials.free_count;
            serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
            options.allocator = &allocators::NULL_ALLOCATOR;
            assert(@catch(decode(
                fixture: &fixture,
                bytes: bytes,
                text_mode: text_mode,
                options: options,
            )) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.world.entities.free_count == free_nodes && fixture.destination.count(ParticleSystem) == 0);
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(@catch(particle::prepare(&fixture.destination, restored)) == c3d::CAPACITY_EXCEEDED);
            assert(!system.is_prepared() && !system.emitting && system.desc.capacity == 7);
            assert(fixture.assets.materials.free_count == free_materials);
            fixture.destination.remove(restored.first_child);
            particle::prepare(&fixture.destination, restored)!!;
            assert(system.is_prepared() && !system.emitting);
            fixture.destination.remove(restored);
            Node* occupied = fixture.destination.add_node()!!;
            assert(@catch(decode(&fixture, bytes, text_mode)) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.root.first_child == occupied && fixture.destination.count(ParticleSystem) == 0);
        };
    }
}

fn void test_particle_writers_reject_invalid_authored_descriptors() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, BILLBOARD);
            defer destroy_fixture(&fixture);
            fixture.source.get(fixture.root, ParticleSystem).desc.rate = -1;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}
