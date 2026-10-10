module c3d::serial::test_policy;

import c3d::anim;
import c3d::camera;
import c3d::describe;
import c3d::ecs @public;
import c3d::light;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    uint version;
    String name;
    typeid identity;
    bool component_description;
    RestorePhase phase;
}

fn void test_every_registered_core_component_has_one_expected_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    ExpectedPolicy[18] expected = {
        { .slot = ecs::assigned_slot(Mesh)!!, .version = 1, .name = "c3d.Mesh",
            .identity = Mesh::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Camera)!!, .version = 1, .name = "c3d.Camera",
            .identity = Camera::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Light)!!, .version = 1, .name = "c3d.Light",
            .identity = Light::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(ProbeVolume)!!, .version = 1, .name = "c3d.ProbeVolume",
            .identity = ProbeVolume::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Atmosphere)!!, .version = 1, .name = "c3d.Atmosphere",
            .identity = Atmosphere::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(HeightFog)!!, .version = 1, .name = "c3d.HeightFog",
            .identity = HeightFog::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(ReflectionProbe)!!, .version = 1, .name = "c3d.ReflectionProbe",
            .identity = ReflectionProbe::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(Decal)!!, .version = 1, .name = "c3d.Decal",
            .identity = Decal::typeid, .component_description = true },
        { .slot = ecs::assigned_slot(InstancedMesh)!!, .version = 1, .name = "c3d.InstancedMesh",
            .identity = InstanceAuthoring::typeid },
        { .slot = ecs::assigned_slot(BillboardBatch)!!, .version = 1, .name = "c3d.BillboardBatch",
            .identity = BillboardAuthoring::typeid },
        { .slot = ecs::assigned_slot(LodGroup)!!, .version = 2, .name = "c3d.LodGroup", .identity = LodAuthoring::typeid },
        { .slot = ecs::assigned_slot(ModelInstance)!!, .version = 1, .name = "c3d.ModelInstance",
            .identity = ModelAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(SkinBinding)!!, .version = 1, .name = "c3d.SkinBinding",
            .identity = SkinAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(IkChain)!!, .version = 1, .name = "c3d.IkChain",
            .identity = IkAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(FootIk)!!, .version = 2, .name = "c3d.FootIk",
            .identity = FootAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(LookAt)!!, .version = 1, .name = "c3d.LookAt",
            .identity = LookAuthoring::typeid, .phase = REFERENCES },
        { .slot = ecs::assigned_slot(Animator)!!, .version = 1, .name = "c3d.Animator",
            .identity = AnimatorAuthoring::typeid, .phase = OWNER },
        { .slot = ecs::assigned_slot(AnimatedCrowd)!!, .version = 2, .name = "c3d.AnimatedCrowd",
            .identity = CrowdAuthoringV2::typeid, .phase = OWNER },
    };
    assert(ecs::registered_type_count == expected.len);
    serial::register_core_codecs()!!;
    describe::register_core_components()!!;
    assert(ecs::registered_type_count == expected.len);
    assert_policy_inventory(expected[..]);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    assert(ecs::registered_type_count == expected.len);
    assert_policy_inventory(expected[..]);
}

fn void assert_policy_inventory(ExpectedPolicy[] expected) @private {
    for (uint slot = 0; slot < ecs::registered_type_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        uint matches;
        foreach (policy : expected) {
            if (policy.slot != slot) continue;
            matches++;
            assert(policies == 1);
            assert(entry.described && !entry.transient && entry.codec.name == policy.name);
            assert(entry.codec.phase == policy.phase && entry.codec.version == policy.version);
            assert(entry.described.type.descriptor.identity == policy.identity);
            if (policy.component_description) assert(describe::component(slot)!!.identity == policy.identity);
        }
        assert(matches == 1);
    }
}
