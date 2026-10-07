module c3d::serial::test_policy;

import c3d::camera;
import c3d::describe;
import c3d::ecs @public;
import c3d::light;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
}

fn void test_every_registered_core_component_has_one_expected_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    ExpectedPolicy[8] expected = {
        { .slot = ecs::assigned_slot(Mesh)!!, .name = "c3d.Mesh", .identity = Mesh::typeid },
        { .slot = ecs::assigned_slot(Camera)!!, .name = "c3d.Camera", .identity = Camera::typeid },
        { .slot = ecs::assigned_slot(Light)!!, .name = "c3d.Light", .identity = Light::typeid },
        { .slot = ecs::assigned_slot(ProbeVolume)!!, .name = "c3d.ProbeVolume", .identity = ProbeVolume::typeid },
        { .slot = ecs::assigned_slot(Atmosphere)!!, .name = "c3d.Atmosphere", .identity = Atmosphere::typeid },
        { .slot = ecs::assigned_slot(HeightFog)!!, .name = "c3d.HeightFog", .identity = HeightFog::typeid },
        { .slot = ecs::assigned_slot(ReflectionProbe)!!, .name = "c3d.ReflectionProbe", .identity = ReflectionProbe::typeid },
        { .slot = ecs::assigned_slot(Decal)!!, .name = "c3d.Decal", .identity = Decal::typeid },
    };
    assert(ecs::registered_type_count == expected.len);
    serial::register_core_codecs()!!;
    describe::register_core_components()!!;
    assert(ecs::registered_type_count == expected.len);
    for (uint slot = 0; slot < ecs::registered_type_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        assert(policies == 1);
        uint matches;
        foreach (policy : expected) {
            if (policy.slot != slot) continue;
            matches++;
            assert(entry.described && !entry.transient && entry.codec.name == policy.name);
            assert(entry.codec.phase == VALUE && entry.codec.version == 1);
            assert(entry.described.type.descriptor.identity == policy.identity);
            assert(describe::component(slot)!!.identity == policy.identity);
        }
        assert(matches == 1);
    }
}
