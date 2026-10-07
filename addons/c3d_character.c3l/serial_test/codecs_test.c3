module c3d_character_serial_test;

import c3d;
import c3d::asset;
import c3d::character @public;
import c3d::ecs;
import c3d::physics;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    Node* node;
    CharacterDesc desc;
}

struct RejectCopy (Allocator) @private {
    Allocator backing;
    bool enabled;
}

fn void*? RejectCopy.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.enabled && size > 64) return mem::OUT_OF_MEMORY~;
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? RejectCopy.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return self.backing.resize(pointer, size, alignment);
}

fn void RejectCopy.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
}

fn void register_scene(Scene* scene) @private {
    physics::register_physics(scene)!!;
    character::register_character(scene)!!;
}

fn void create_fixture(Fixture* fixture, bool push = true, Allocator allocator = mem) @private {
    character::register_serial_codecs()!!;
    fixture.assets = asset::create_asset_store(mem, { .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8 });
    fixture.source = scene::create_scene(mem, { .max_nodes = 8 });
    fixture.destination = scene::create_scene(allocator, { .max_nodes = 8 });
    register_scene(&fixture.source);
    register_scene(&fixture.destination);
    fixture.node = fixture.source.add_node(name: "character")!!;
    fixture.node.local.position = { 4, 2, -3 };
    fixture.source.update_world();
    fixture.desc = character::default_character_desc();
    fixture.desc.radius = 0.3f;
    fixture.desc.half_height = 0.7f;
    fixture.desc.step_height = 0.2f;
    fixture.desc.max_slope_degrees = 37;
    fixture.desc.skin = 0.003f;
    fixture.desc.push_bodies = push;
    fixture.desc.filter = { .category = 16, .mask = 31, .group = -5 };
    fixture.source.add_character(fixture.node, fixture.desc)!!;
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

fn PhysicsWorld create_world(Scene* scene, AssetStore* assets) @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    desc.tuning.interpolate = false;
    return physics::create_physics_world(
        allocator: mem,
        assets: assets,
        scene: scene,
        desc: desc,
    )!!;
}

fn void test_character_serial_registration() @test {
    character::register_serial_codecs()!!;
    assert(serial::described_type(CharacterDesc)!!.layout == 0x97ed00b8e41ba418);
}

fn void test_character_both_formats_restart_and_match_public_construction() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        foreach (push : (bool[2]){ false, true }) {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture, push);
                defer destroy_fixture(&fixture);
                Character* source = fixture.source.get(fixture.node, Character);
                source.velocity = { 1, 2, 3 };
                source.desired = { 4, 0, 5 };
                source.grounded = true;
                source.ground = fixture.source.root.id;
                source.ground_normal = { 0, 1, 0 };
                source.jump_requested = true;
                source.jump_speed = 6;
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.node,
                    text_mode: text_mode,
                )!!;
                PhysicsWorld source_world = create_world(&fixture.source, &fixture.assets);
                defer physics::destroy_physics_world(&source_world);
                source_world.update(0);
                assert(bytes == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.node,
                    text_mode: text_mode,
                )!!);
                Node* restored = decode(&fixture, bytes, text_mode)!!;
                Character* actual = fixture.destination.get(restored, Character);
                assert(actual.desc.radius == 0.3f && actual.desc.half_height == 0.7f && actual.desc.push_bodies == push);
                assert(actual.desc.max_slope_degrees == 37 && actual.desc.filter.group == -5);
                assert(actual.velocity == (Vec3){} && actual.desired == (Vec3){} && !actual.grounded && !actual.ground.generation);
                assert(!actual.jump_requested && !actual.plane_count && actual.jump_speed == 0);
                assert(actual.previous == restored.world_position() + (Vec3){ 0, 1, 0 } && actual.current == actual.previous);
                assert(fixture.destination.count(PhysicsBody) == (push ? 1 : 0) && fixture.destination.count(RigidBody) == 0);
                if (push) {
                    PhysicsBody* body = fixture.destination.get(restored, PhysicsBody);
                    assert(body.status == PENDING && body.body.kind == KINEMATIC && body.colliders.len == 1);
                    assert(body.colliders[0].filter.mask == ulong::max && body.colliders[0].radius == fixture.desc.radius);
                    assert(body.colliders.ptr != fixture.source.get(fixture.node, PhysicsBody).colliders.ptr);
                }
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
                Scene reference = scene::create_scene(mem, { .max_nodes = 8 });
                defer scene::destroy_scene(&reference);
                register_scene(&reference);
                Node* expected_node = reference.add_node(name: "character")!!;
                expected_node.local = restored.local;
                reference.update_world();
                reference.add_character(expected_node, fixture.desc)!!;
                PhysicsWorld expected_world = create_world(&reference, &fixture.assets);
                defer physics::destroy_physics_world(&expected_world);
                CharacterSystem expected_system = character::create_character_system(mem, &expected_world, &reference)!!;
                defer character::destroy_character_system(&expected_system);
                PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
                defer physics::destroy_physics_world(&world);
                CharacterSystem system = character::create_character_system(mem, &world, &fixture.destination)!!;
                defer character::destroy_character_system(&system);
                world.update(0);
                expected_world.update(0);
                assert(actual.current == reference.get(expected_node, Character).current);
                fixture.destination.move_character(restored, { 1, 0, 0.5f });
                reference.move_character(expected_node, { 1, 0, 0.5f });
                world.update(physics::DEFAULT_FIXED_DT);
                expected_world.update(physics::DEFAULT_FIXED_DT);
                fixture.destination.update_world();
                reference.update_world();
                assert((restored.world_position() - expected_node.world_position()).length() < 1e-4f);
                assert((actual.velocity - reference.get(expected_node, Character).velocity).length() < 1e-4f);
                assert(world.build_failures().len == 0 && expected_world.build_failures().len == 0);
            };
        }
    }
}

fn void test_character_rejects_changed_owned_body_and_invalid_input() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            PhysicsBody* body = fixture.source.get(fixture.node, PhysicsBody);
            body.colliders[0].density += 1;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.node,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            body.colliders[0].density -= 1;
            fixture.source.get(fixture.node, Character).desc.push_bodies = false;
            fixture.source.remove_component(fixture.node, PhysicsBody);
            char[] valid = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.node,
                text_mode: text_mode,
            )!!;
            fixture.source.get(fixture.node, Character).desc.half_height = 0;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.node,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.get(fixture.node, Character).desc.half_height = 0.7f;
            char[] invalid = invalid_character_height(valid, text_mode);
            uint before = fixture.destination.world.entities.free_count;
            assert(@catch(decode(&fixture, invalid, text_mode)) == c3d::INVALID_ARGUMENT);
            assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(Character) == 0);
        };
    }
}

fn void test_character_push_body_allocation_failure_rolls_back() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RejectCopy failure = { .backing = &tracker };
            Fixture fixture;
            create_fixture(fixture: &fixture, push: true, allocator: &failure);
            defer destroy_fixture(&fixture);
            @pool() {
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.node,
                    text_mode: text_mode,
                )!!;
                serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
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
                assert(fixture.destination.world.entities.free_count == before);
                assert(fixture.destination.count(Character) == 0 && fixture.destination.count(PhysicsBody) == 0);
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracker.has_leaks());
    }
}
