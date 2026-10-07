module c3d_particle_serial_policy_test;

import c3d::ecs @public;
import c3d::particle @public;
import c3d::scene;
import c3d::serial @public;

fn void test_every_particle_component_has_one_expected_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    uint core_count = ecs::registered_type_count;
    particle::register_particles(&scene)!!;
    uint registered_count = ecs::registered_type_count;
    particle::register_serial_codecs()!!;
    assert(registered_count == core_count + 2 && ecs::registered_type_count == registered_count);
    uint authoring = ecs::assigned_slot(ParticleSystem)!!;
    uint runtime = ecs::assigned_slot(ParticleDrawOwner)!!;
    assert(authoring != runtime && authoring >= core_count && runtime >= core_count);
    for (uint slot = core_count; slot < registered_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        assert(policies == 1);
        if (slot == authoring) {
            assert(entry.described && !entry.transient && entry.codec.name == "particle_system");
            assert(entry.codec.phase == VALUE && entry.codec.version == 1);
            assert(entry.described.type.descriptor.identity == ParticleAuthoring::typeid);
        } else {
            assert(slot == runtime && entry.transient && !entry.described && !entry.codec.name.len);
            assert(entry.codec.collect != null);
        }
    }
    particle::register_serial_codecs()!!;
    particle::register_particles(&scene)!!;
    serial::register_core_codecs()!!;
    assert(ecs::registered_type_count == registered_count);
    assert(ecs::assigned_slot(ParticleSystem)!! == authoring && ecs::assigned_slot(ParticleDrawOwner)!! == runtime);
}
