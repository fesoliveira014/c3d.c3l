module c3d::serial::test_policy;

import c3d::anim;
import c3d::camera;
import c3d::describe;
import c3d::ecs @public;
import c3d::light;
import c3d::scene;
import c3d::serial @public;

const typeid[*] PENDING_CORE_POLICIES @private = {
    Animator::typeid, AnimatedCrowd::typeid,
};

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
    bool component_description;
    RestorePhase phase;
}

fn void test_every_registered_core_component_has_one_expected_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    ExpectedPolicy[16] expected = {
        { .slot = ecs::assigned_slot(Mesh)!!, .name = "c3d.Mesh",
            .identity = Mesh::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Camera)!!, .name = "c3d.Camera",
            .identity = Camera::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Light)!!, .name = "c3d.Light",
            .identity = Light::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(ProbeVolume)!!, .name = "c3d.ProbeVolume",
            .identity = ProbeVolume::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Atmosphere)!!, .name = "c3d.Atmosphere",
            .identity = Atmosphere::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(HeightFog)!!, .name = "c3d.HeightFog",
            .identity = HeightFog::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(ReflectionProbe)!!, .name = "c3d.ReflectionProbe",
            .identity = ReflectionProbe::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Decal)!!, .name = "c3d.Decal",
            .identity = Decal::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(InstancedMesh)!!, .name = "c3d.InstancedMesh",
            .identity = InstanceAuthoring::typeid },
        { .slot = ecs::assigned_slot(BillboardBatch)!!, .name = "c3d.BillboardBatch",
            .identity = BillboardAuthoring::typeid },
        { .slot = ecs::assigned_slot(LodGroup)!!, .name = "c3d.LodGroup", .identity = LodAuthoring::typeid },
        { .slot = ecs::assigned_slot(ModelInstance)!!, .name = "c3d.ModelInstance",
            .identity = ModelAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(SkinBinding)!!, .name = "c3d.SkinBinding",
            .identity = SkinAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(IkChain)!!, .name = "c3d.IkChain",
            .identity = IkAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(FootIk)!!, .name = "c3d.FootIk",
            .identity = FootAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(LookAt)!!, .name = "c3d.LookAt",
            .identity = LookAuthoring::typeid, .phase = REFERENCES },
    };
    assert(ecs::registered_type_count == expected.len);
    serial::register_core_codecs()!!;
    describe::register_core_components()!!;
    assert(ecs::registered_type_count == expected.len);
    assert_policy_inventory(expected[..], false);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    assert(ecs::registered_type_count == expected.len + PENDING_CORE_POLICIES.len);
    assert_policy_inventory(expected[..], true);
}

fn void assert_policy_inventory(ExpectedPolicy[] expected, bool include_pending) @private {
    for (uint slot = 0; slot < ecs::registered_type_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        uint pending;
        if (include_pending) {
            $foreach $identity : PENDING_CORE_POLICIES:
                pending += (uint)(slot == ecs::assigned_slot($Typefrom($identity))!!);
            $endforeach
        }
        uint matches;
        foreach (policy : expected) {
            if (policy.slot != slot) continue;
            matches++;
            assert(policies == 1);
            assert(entry.described && !entry.transient && entry.codec.name == policy.name);
            assert(entry.codec.phase == policy.phase && entry.codec.version == 1);
            assert(entry.described.type.descriptor.identity == policy.identity);
            if (policy.component_description) assert(describe::component(slot)!!.identity == policy.identity);
        }
        assert(matches + pending == 1);
        if (pending) assert(policies == 0);
    }
}
