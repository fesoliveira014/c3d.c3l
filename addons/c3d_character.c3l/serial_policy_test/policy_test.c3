module c3d_character_policy_test;

import c3d::character @public;
import c3d::ecs @public;
import c3d::physics;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
    RestorePhase phase;
}

fn void test_every_character_component_has_one_expected_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    physics::register_serial_codecs()!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    $if $feat(C3D_CHARACTER_NAV):
        register_nav_dependencies(&scene);
    $endif
    uint dependency_count = ecs::registered_type_count;
    character::register_character(&scene)!!;
    $if $feat(C3D_CHARACTER_NAV):
        character::register_nav_driven(&scene)!!;
    $endif
    uint registered_count = ecs::registered_type_count;
    character::register_serial_codecs()!!;
    ExpectedPolicy[2] expected = {
        { .slot = ecs::assigned_slot(Character)!!, .name = "character", .identity = CharacterDesc::typeid, .phase = REFERENCES },
        {},
    };
    uint count = 1;
    $if $feat(C3D_CHARACTER_NAV):
        expected[count++] = { .slot = ecs::assigned_slot(NavDriven)!!, .name = "nav_driven", .identity = NavDrivenAuthoring::typeid, .phase = OWNER };
    $endif
    assert(registered_count == dependency_count + count && ecs::registered_type_count == registered_count);
    for (uint slot = dependency_count; slot < registered_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        uint matches;
        foreach (policy : expected[:count]) {
            if (policy.slot != slot) continue;
            matches++;
            assert(policies == 1 && entry.described && !entry.transient);
            assert(entry.codec.name == policy.name && entry.codec.phase == policy.phase && entry.codec.version == 1);
            assert(entry.described.type.descriptor.identity == policy.identity);
        }
        assert(matches == 1);
    }
    character::register_serial_codecs()!!;
    character::register_character(&scene)!!;
    $if $feat(C3D_CHARACTER_NAV):
        character::register_nav_driven(&scene)!!;
    $endif
    assert(ecs::registered_type_count == registered_count);
}
