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
    MaterialId trail_material = fixture.assets.add_material(material::standard(), "trail")!!;
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
    desc.saturation = DROP_OLDEST;
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
    desc.collision = {
        .response = BOUNCE,
        .restitution = 0.3f,
        .friction = 0.2f,
        .radius_scale = 0.75f,
        .ground_plane = true,
        .ground_height = -2.5f,
        .max_queries = 9,
        .impact_speed = 2.5f,
    };
    if (mode != MESH) {
        desc.flipbook = {
            .columns = 4,
            .rows = 3,
            .frame_count = 11,
            .inset = { 0.001f, 0.002f },
            .mode = FPS,
            .fps = 12.5f,
            .random_start = true,
            .blend = true,
        };
    }
    desc.turbulence = {
        .strength = 1.5f,
        .frequency = 0.25f,
        .octaves = 2,
        .period = 12,
        .scroll = { 0.5f, -1, 0.25f },
    };
    desc.trail = {
        .max_points = 5,
        .point_interval = 0.02f,
        .lifetime = 0.75f,
        .width = 0.125f,
        .uv = TILE,
        .tile_length = 1.5f,
        .material = trail_material,
    };
    foreach (index, &width : desc.trail.width_over_trail.values) *width = 1 - (float)index / 8;
    foreach (index, &color : desc.trail.color_over_trail.values) *color = { 1, 0.5f, (float)index * 0.1f, 0.9f };
    if (mode == MESH) {
        desc.mesh_cast_shadow = true;
        desc.mesh_trace = true;
    }
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

fn Node* find_child(Node* parent, String name) @private {
    for (Node* child = parent.first_child; child; child = child.next_sibling) {
        if (child.name == name) return child;
    }
    return null;
}

fn void test_serial_layout_registration() @test {
    particle::register_serial_codecs()!!;
    assert(serial::described_type(ParticleRange)!!.version == 1);
    assert(serial::described_type(ParticleRange)!!.layout == 0xaf1f0c33b5e51627);
    assert(serial::described_type(LifetimeTable)!!.layout == 0xe4c18077262a7a22);
    assert(serial::described_type(LifetimeColorTable)!!.layout == 0x4eacd1a988dfc1b2);
    assert(serial::described_type(particle::ParticleSystemDescV1)!!.version == 1);
    assert(serial::described_type(particle::ParticleSystemDescV1)!!.layout == 0x1a366da2bd207420);
    assert(serial::described_type(particle::ParticleAuthoringV1)!!.version == 1);
    assert(serial::described_type(particle::ParticleAuthoringV1)!!.layout == 0xea58cb75a4a73416);
    assert(serial::described_type(particle::ParticleSystemDescV2)!!.version == 2);
    assert(serial::described_type(particle::ParticleSystemDescV2)!!.layout == 0x63291d71ce5d82d3);
    assert(serial::described_type(particle::ParticleAuthoringV2)!!.version == 2);
    assert(serial::described_type(particle::ParticleAuthoringV2)!!.layout == 0x2bb779bddc9e4271);
    assert(serial::described_type(SubEmitter)!!.version == 1);
    assert(serial::described_type(SubEmitter)!!.layout == 0xbc17df2b03f79e67);
    assert(serial::described_type(particle::ParticleSystemDescV3)!!.version == 3);
    assert(serial::described_type(particle::ParticleSystemDescV3)!!.layout == 0x09ff25e64a1b07c9);
    assert(serial::described_type(particle::ParticleAuthoringV3)!!.version == 3);
    assert(serial::described_type(particle::ParticleAuthoringV3)!!.layout == 0xfce463fdcc2f5ec7);
    assert(serial::described_type(ParticleCollision)!!.version == 1);
    assert(serial::described_type(ParticleCollision)!!.layout == 0xb3c1e7574d47f9eb);
    assert(serial::described_type(particle::ParticleSystemDescV4)!!.version == 4);
    assert(serial::described_type(particle::ParticleSystemDescV4)!!.layout == 0x2bcd644f0dae365e);
    assert(serial::described_type(particle::ParticleAuthoringV4)!!.version == 4);
    assert(serial::described_type(particle::ParticleAuthoringV4)!!.layout == 0xbc9869b807205e38);
    assert(serial::described_type(ParticleFlipbook)!!.version == 1);
    assert(serial::described_type(ParticleFlipbook)!!.layout == 0x3ff56ab69bece737);
    assert(serial::described_type(particle::ParticleSystemDescV5)!!.version == 5);
    assert(serial::described_type(particle::ParticleSystemDescV5)!!.layout == 0x9112174200c2df34);
    assert(serial::described_type(particle::ParticleAuthoringV5)!!.version == 5);
    assert(serial::described_type(particle::ParticleAuthoringV5)!!.layout == 0x35b8ed9f357f1cbe);
    assert(serial::described_type(ParticleTurbulence)!!.version == 1);
    assert(serial::described_type(ParticleTurbulence)!!.layout == 0x3a1f2d4e38ebc210);
    assert(serial::described_type(particle::ParticleSystemDescV6)!!.version == 6);
    assert(serial::described_type(particle::ParticleSystemDescV6)!!.layout == 0x07763ae500c62112);
    assert(serial::described_type(particle::ParticleAuthoringV6)!!.version == 6);
    assert(serial::described_type(particle::ParticleAuthoringV6)!!.layout == 0x5cdb9677e6a87b8c);
    assert(serial::described_type(ParticleTrail)!!.version == 1);
    assert(serial::described_type(ParticleTrail)!!.layout == 0x8ca2db8e1e495b9f);
    assert(serial::described_type(particle::ParticleSystemDescV7)!!.version == 7);
    assert(serial::described_type(particle::ParticleSystemDescV7)!!.layout == 0x4c53c2a840dc4b22);
    assert(serial::described_type(particle::ParticleAuthoringV7)!!.version == 7);
    assert(serial::described_type(particle::ParticleAuthoringV7)!!.layout == 0xa19169c0d642b947);
    assert(serial::described_type(particle::ParticleSystemDescV8)!!.version == 8);
    assert(serial::described_type(particle::ParticleSystemDescV8)!!.layout == 0xf4e634d538fb6561);
    assert(serial::described_type(particle::ParticleAuthoringV8)!!.version == 8);
    assert(serial::described_type(particle::ParticleAuthoringV8)!!.layout == 0x80aadf92bb6def28);
    assert(serial::described_type(ParticleSystemDesc)!!.version == 9);
    assert(serial::described_type(ParticleSystemDesc)!!.layout == 0xac2f8cc71b7487d9);
    assert(serial::described_type(particle::ParticleAuthoring)!!.version == 9);
    assert(serial::described_type(particle::ParticleAuthoring)!!.layout == 0xc05a0e8dbcf9506c);
    @pool() {
        String schema = serial::write_schema(tmem)!!;
        assert(schema.contains("particle_system") && schema.contains("emitting"));
        assert(schema.contains("color_over_life") && schema.contains("BILLBOARD"));
        assert(schema.contains("saturation") && schema.contains("DROP_OLDEST"));
        assert(schema.contains("sub_emitters") && schema.contains("inherit_velocity") && schema.contains("max_events"));
        assert(schema.contains("collision") && schema.contains("ground_height") && schema.contains("BOUNCE"));
        assert(schema.contains("flipbook") && schema.contains("random_start") && schema.contains("OVER_LIFE"));
        assert(schema.contains("turbulence") && schema.contains("octaves") && schema.contains("scroll"));
        assert(schema.contains("trail") && schema.contains("width_over_trail") && schema.contains("TILE"));
        assert(schema.contains("mesh_cast_shadow") && schema.contains("mesh_trace"));
        assert(schema.contains("execution") && schema.contains("GPU"));
    };
}

fn void test_particle_execution_round_trips_in_both_encodings() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, STRETCHED);
            defer destroy_fixture(&fixture);
            fixture.source.get(fixture.root, ParticleSystem).desc.execution = ParticleExecution.GPU;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            assert(fixture.destination.get(restored, ParticleSystem).desc.execution == ParticleExecution.GPU);
        };
    }
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
                assert(system.desc.saturation == DROP_OLDEST && system.evicted == 0 && system.next_spawn == 0);
                assert(system.desc.sub_emitter_count == 0 && system.desc.max_events == 0);
                assert(system.desc.collision.response == BOUNCE && system.desc.collision.ground_plane);
                assert(system.desc.collision.restitution == 0.3f && system.desc.collision.friction == 0.2f);
                assert(system.desc.collision.radius_scale == 0.75f && system.desc.collision.max_queries == 9);
                assert(system.desc.collision.ground_height == -2.5f);
                assert(system.desc.collision.impact_speed == 2.5f);
                ParticleFlipbook flipbook = system.desc.flipbook;
                if (mode == MESH) {
                    assert(flipbook.columns == 0);
                } else {
                    assert(flipbook.columns == 4 && flipbook.rows == 3 && flipbook.frame_count == 11);
                    assert(flipbook.inset == (Vec2){ 0.001f, 0.002f } && flipbook.mode == FPS);
                    assert(flipbook.fps == 12.5f && flipbook.random_start && flipbook.blend);
                }
                ParticleTurbulence turbulence = system.desc.turbulence;
                assert(turbulence.strength == 1.5f && turbulence.frequency == 0.25f);
                assert(turbulence.octaves == 2 && turbulence.period == 12);
                assert(turbulence.scroll == (Vec3){ 0.5f, -1, 0.25f });
                ParticleTrail trail = system.desc.trail;
                assert(trail.max_points == 5 && trail.point_interval == 0.02f && trail.lifetime == 0.75f);
                assert(trail.width == 0.125f && trail.uv == TILE && trail.tile_length == 1.5f);
                assert(trail.width_over_trail.values == source.desc.trail.width_over_trail.values);
                assert(trail.color_over_trail.values == source.desc.trail.color_over_trail.values);
                assert(fixture.assets.materials.is_live(trail.material));
                assert(!c3d::same_id(trail.material, system.desc.material));
                assert(system.desc.mesh_cast_shadow == (mode == MESH) && system.desc.mesh_trace == (mode == MESH));
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

fn void test_sub_emitter_targets_round_trip_inside_the_subtree() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, BILLBOARD);
            defer destroy_fixture(&fixture);
            Node* target = fixture.source.add_node(fixture.root, "target")!!;
            fixture.source.attach_particle_system(target, particle::default_particle_system_desc())!!;
            Node* removed = fixture.source.add_node()!!;
            Entity stale = removed.id;
            fixture.source.remove(removed);
            ParticleSystem* source = fixture.source.get(fixture.root, ParticleSystem);
            source.desc.max_events = 6;
            source.desc.sub_emitter_count = 2;
            source.desc.sub_emitters[0] = {
                .trigger = BIRTH,
                .target = target.id,
                .count = 3,
                .inherit_velocity = 0.25f,
            };
            source.desc.sub_emitters[1] = {
                .trigger = DEATH,
                .target = target.id,
                .count = 2,
                .inherit_velocity = 1,
                .on_evict = true,
            };
            source.desc.sub_emitters[2] = { .target = stale };
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;

            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Node* restored_target = find_child(restored, "target");
            ParticleSystemDesc desc = fixture.destination.get(restored, ParticleSystem).desc;
            assert(restored_target.name == "target" && desc.max_events == 6 && desc.sub_emitter_count == 2);
            assert(desc.sub_emitters[0].trigger == BIRTH && desc.sub_emitters[0].count == 3);
            assert(desc.sub_emitters[0].inherit_velocity == 0.25f && !desc.sub_emitters[0].on_evict);
            assert(desc.sub_emitters[1].trigger == DEATH && desc.sub_emitters[1].on_evict);
            assert(c3d::same_id(desc.sub_emitters[0].target, restored_target.id));
            assert(c3d::same_id(desc.sub_emitters[1].target, restored_target.id));
            assert(!desc.sub_emitters[2].target.generation);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_sub_emitter_target_outside_the_subtree_is_rejected() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, BILLBOARD);
            defer destroy_fixture(&fixture);
            Node* outside = fixture.source.add_node(name: "outside")!!;
            fixture.source.attach_particle_system(outside, particle::default_particle_system_desc())!!;
            ParticleSystem* source = fixture.source.get(fixture.root, ParticleSystem);
            source.desc.max_events = 2;
            source.desc.sub_emitter_count = 1;
            source.desc.sub_emitters[0] = { .trigger = DEATH, .target = outside.id, .count = 1 };
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
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
            fixture.source.remove_component(draw, Extra);

            Node* trail = fixture.source.node(fixture.source.get(fixture.root, ParticleSystem).trail_node);
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: trail,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.add(trail, (Extra){ .value = 9 });
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
            create_fixture(&fixture, BILLBOARD, 3);
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
            free_nodes = fixture.destination.world.entities.free_count;
            assert(@catch(particle::prepare(&fixture.destination, restored)) == c3d::CAPACITY_EXCEEDED);
            assert(!system.is_prepared() && !system.emitting && system.desc.capacity == 7);
            assert(fixture.assets.materials.free_count == free_materials);
            assert(fixture.destination.world.entities.free_count == free_nodes);
            assert(fixture.destination.count(BillboardBatch) == 0);
            fixture.destination.remove(restored.first_child);
            particle::prepare(&fixture.destination, restored)!!;
            assert(system.is_prepared() && !system.emitting);
            fixture.destination.remove(restored);
            fixture.destination.add_node()!!;
            fixture.destination.add_node()!!;
            free_nodes = fixture.destination.world.entities.free_count;
            assert(@catch(decode(&fixture, bytes, text_mode)) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.world.entities.free_count == free_nodes);
            assert(fixture.destination.count(ParticleSystem) == 0);
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
