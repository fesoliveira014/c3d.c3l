module c3d::test::ecs_cap;

import c3d;
import c3d::ecs;

struct Filler <INDEX> @local {
    int value;
}

fn void test_type_cap_faults() @test {
    World world = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&world);

    uint faults;
    $for var $index = 0; $index < ecs::MAX_COMPONENT_TYPES + 1; $index++:
        if (catch excuse = world.register(Filler{$index})) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
            faults++;
        }
    $endfor

    assert(faults >= 1);
    assert(!world.is_registered(Filler{ecs::MAX_COMPONENT_TYPES}));
}
