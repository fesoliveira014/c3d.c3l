module c3d_nav_serial_policy_test;

import c3d::ecs @public;
import c3d::nav @public;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
    bool transient;
}

fn void test_every_navigation_component_has_one_expected_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    uint core_count = ecs::registered_type_count;
    nav::register_nav(&scene)!!;
    uint registered_count = ecs::registered_type_count;
    nav::register_serial_codecs()!!;
    ExpectedPolicy[10] expected = {
        { .slot = ecs::assigned_slot(NavSource)!!, .name = "nav_source", .identity = NavSourceAuthoring::typeid },
        { .slot = ecs::assigned_slot(NavVolume)!!, .name = "nav_volume", .identity = NavVolumeAuthoring::typeid },
        { .slot = ecs::assigned_slot(NavLink)!!, .name = "nav_link", .identity = NavLinkAuthoring::typeid },
        { .slot = ecs::assigned_slot(NavObstacle)!!, .name = "nav_obstacle", .identity = NavObstacleAuthoring::typeid },
        { .slot = ecs::assigned_slot(NavAgent)!!, .name = "nav_agent", .identity = NavAgentAuthoring::typeid },
        { .slot = ecs::assigned_slot(NavSourceRuntime)!!, .transient = true },
        { .slot = ecs::assigned_slot(NavVolumeRuntime)!!, .transient = true },
        { .slot = ecs::assigned_slot(NavLinkRuntime)!!, .transient = true },
        { .slot = ecs::assigned_slot(NavObstacleRuntime)!!, .transient = true },
        { .slot = ecs::assigned_slot(CrowdAgentRuntime)!!, .transient = true },
    };
    assert(registered_count == core_count + expected.len && ecs::registered_type_count == registered_count);
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
                assert(entry.codec.phase == REFERENCES && entry.codec.version == 1);
                assert(entry.described.type.descriptor.identity == policy.identity);
            }
        }
        assert(matches == 1);
    }
    nav::register_serial_codecs()!!;
    nav::register_nav(&scene)!!;
    serial::register_core_codecs()!!;
    assert(ecs::registered_type_count == registered_count);
}
