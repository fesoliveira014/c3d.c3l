module c3d_physics_serial_policy_test;

import c3d::asset;
import c3d::ecs @public;
import c3d::physics @public;
import c3d::physics::cloth;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
    RestorePhase phase;
    bool transient;
}

fn void test_every_physics_component_has_an_explicit_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    uint core_count = ecs::registered_type_count;
    physics::register_physics(&scene)!!;
    AssetStore assets = asset::create_asset_store(mem, { .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8 });
    defer asset::destroy_asset_store(&assets);
    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
    )!!;
    defer physics::destroy_physics_world(&world);
    uint registered_count = ecs::registered_type_count;
    physics::register_serial_codecs()!!;
    ExpectedPolicy[8] expected = {
        { .slot = ecs::assigned_slot(PhysicsBody)!!, .name = "physics_body", .identity = BodyAuthoring::typeid },
        { .slot = ecs::assigned_slot(PhysicsJoint)!!, .name = "physics_joint", .identity = JointAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(Buoyancy)!!, .name = "buoyancy", .identity = BuoyancyAuthoring::typeid },
        { .slot = ecs::assigned_slot(Wind)!!, .name = "wind", .identity = Wind::typeid },
        { .slot = ecs::assigned_slot(Force)!!, .name = "force", .identity = Force::typeid },
        { .slot = ecs::assigned_slot(Cloth)!!, .name = "cloth", .identity = ClothSavedAuthoring::typeid, .phase = OWNER },
        { .slot = ecs::assigned_slot(RigidBody)!!, .transient = true },
        { .slot = ecs::assigned_slot(Joint)!!, .transient = true },
    };
    uint[2] pending = { ecs::assigned_slot(Ragdoll)!!, ecs::assigned_slot(Breakable)!! };
    assert(registered_count == core_count + expected.len + pending.len);
    assert(ecs::registered_type_count == registered_count);
    for (uint slot = core_count; slot < registered_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        uint matches;
        foreach (policy : expected) {
            if (policy.slot != slot) continue;
            matches++;
            assert(policies == 1 && entry.transient == policy.transient);
            if (policy.transient) {
                assert(!entry.described && !entry.codec.name.len);
            } else {
                assert(entry.described && entry.codec.name == policy.name);
                assert(entry.codec.phase == policy.phase && entry.codec.version == 1);
                assert(entry.described.type.descriptor.identity == policy.identity);
            }
        }
        foreach (pending_slot : pending) {
            if (pending_slot != slot) continue;
            matches++;
            assert(policies == 0);
        }
        assert(matches == 1);
    }
    physics::register_serial_codecs()!!;
    physics::register_physics(&scene)!!;
    serial::register_core_codecs()!!;
    assert(ecs::registered_type_count == registered_count);
}
