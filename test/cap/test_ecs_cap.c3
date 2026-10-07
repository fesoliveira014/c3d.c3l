module c3d::test::ecs_cap;

import c3d;
import c3d::ecs;
import c3d::describe;

struct Filler <INDEX> @local {
    int value;
}

struct BoundaryView @local {
    World* world;
    void*  component;
    uint   calls;
    bool   boundary_present;
    bool   boundary_found;
    bool   boundary_in_mask;
}

struct ExistingDescription @local {
    int value;
}

struct UnpublishedDescription @local {
    int value;
}

fn void record_boundary(Entity entity, void* component, void* user) @local {
    BoundaryView* view = (BoundaryView*)user;
    World* world = view.world;
    view.component = component;
    view.calls++;
    view.boundary_present = world.has(entity, Filler{64});
    view.boundary_found = world.get(entity, Filler{64}) != null;
    view.boundary_in_mask = (world.mask(entity) & ecs::slot_bit(64)) != 0;
}

fn World filled_world(uint capacity) @local {
    World world = ecs::create_world(mem, capacity);
    // In-order registration puts Filler{i} at slot i; a registered type keeps its slot, so test order is free.
    $for var $index = 0; $index < ecs::MAX_COMPONENT_TYPES; $index++:
        world.register(Filler{$index})!!;
    $endfor
    return world;
}

macro void check_each2_pair($Larger, $Smaller) @local {
    World world = filled_world(4);
    defer ecs::destroy_world(&world);
    Entity[4] entities;
    foreach (&entity : entities) *entity = world.create_entity()!!;
    for (uint index = 0; index < 3; index++) world.add(entities[index], ($Larger){ .value = (int)index });
    world.add(entities[1], ($Smaller){ .value = 10 });
    world.add(entities[3], ($Smaller){ .value = 30 });

    uint visits;
    world.@each2($Larger, $Smaller; Entity entity, larger, smaller) {
        assert(c3d::same_id(entity, entities[1]));
        assert(larger == world.get(entity, $Larger) && smaller == world.get(entity, $Smaller));
        visits++;
    };
    world.@each2($Smaller, $Larger; Entity entity, smaller, larger) {
        assert(c3d::same_id(entity, entities[1]));
        assert(larger == world.get(entity, $Larger) && smaller == world.get(entity, $Smaller));
        visits++;
    };
    assert(visits == 2);
}

fn void test_type_cap_faults() @test {
    World world = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&world);

    assert(@catch(ecs::assigned_slot(Filler{ecs::MAX_COMPONENT_TYPES})) == NOT_FOUND);
    uint faults;
    $for var $index = 0; $index < ecs::MAX_COMPONENT_TYPES + 1; $index++:
        if (catch excuse = world.register(Filler{$index})) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
            faults++;
        }
    $endfor

    assert(faults == 1);
    assert(!world.is_registered(Filler{ecs::MAX_COMPONENT_TYPES}));
    assert(@catch(ecs::assigned_slot(Filler{ecs::MAX_COMPONENT_TYPES})) == NOT_FOUND);
    assert(ecs::assigned_slot(Filler{0})!! == 0);
    assert(ecs::assigned_slot(Filler{ecs::MAX_COMPONENT_TYPES - 1})!! == ecs::MAX_COMPONENT_TYPES - 1);
}

fn void test_components_in_both_mask_words_keep_store_contracts() @test {
    World world = filled_world(4);
    defer ecs::destroy_world(&world);
    assert(ecs::assigned_slot(Filler{64})!! == 64);

    Entity entity = world.create_entity()!!;
    Filler{3}* low = world.add(entity, (Filler{3}){ .value = 3 });
    Filler{64}* boundary = world.add(entity, (Filler{64}){ .value = 64 });
    Filler{127}* last = world.add(entity, (Filler{127}){ .value = 127 });

    assert(world.has(entity, Filler{3}) && world.has(entity, Filler{64}) && world.has(entity, Filler{127}));
    assert(!world.has(entity, Filler{63}) && !world.has(entity, Filler{65}));
    assert(world.get(entity, Filler{64}) == boundary && world.get(entity, Filler{64}).value == 64);
    assert(world.get(entity, Filler{127}) == last && world.get(entity, Filler{127}).value == 127);
    assert(world.get(entity, Filler{65}) == null);
    assert(world.mask(entity) == (ecs::slot_bit(3) | ecs::slot_bit(64) | ecs::slot_bit(127)));
    assert(world.component(entity, 3) == low);
    assert(world.component(entity, 64) == boundary);
    assert(world.component(entity, 127) == last);

    world.remove(entity, Filler{64});
    assert(!world.has(entity, Filler{64}) && world.get(entity, Filler{64}) == null);
    assert(world.count(Filler{64}) == 0);
    assert(world.mask(entity) == (ecs::slot_bit(3) | ecs::slot_bit(127)));
    assert(world.get(entity, Filler{127}).value == 127 && world.get(entity, Filler{3}).value == 3);
}

fn void test_each2_pairs_types_across_mask_words() @test {
    check_each2_pair(Filler{3}, Filler{63});
    check_each2_pair(Filler{64}, Filler{127});
    check_each2_pair(Filler{3}, Filler{64});
    check_each2_pair(Filler{64}, Filler{3});
}

fn void test_destroy_entity_runs_hooks_across_mask_words() @test {
    World world = filled_world(4);
    defer ecs::destroy_world(&world);

    BoundaryView below = { .world = &world };
    BoundaryView boundary = { .world = &world };
    BoundaryView above = { .world = &world };
    world.set_remove_hook(Filler{63}, &record_boundary, &below);
    world.set_remove_hook(Filler{64}, &record_boundary, &boundary);
    world.set_remove_hook(Filler{127}, &record_boundary, &above);
    Entity keeper = world.create_entity()!!;
    Entity entity = world.create_entity()!!;
    world.add(keeper, (Filler{64}){ .value = 1 });
    world.add(entity, (Filler{3}){ .value = 3 });
    Filler{63}* below_component = world.add(entity, (Filler{63}){ .value = 63 });
    Filler{64}* boundary_component = world.add(entity, (Filler{64}){ .value = 64 });
    Filler{127}* above_component = world.add(entity, (Filler{127}){ .value = 127 });
    world.destroy_entity(entity);

    assert(!world.is_alive(entity));
    assert(world.entities.items[entity.index] == 0);
    assert(below.calls == 1 && below.component == below_component);
    assert(boundary.calls == 1 && boundary.component == boundary_component);
    assert(above.calls == 1 && above.component == above_component);
    assert(below.boundary_present && below.boundary_found && below.boundary_in_mask);
    assert(boundary.boundary_present && boundary.boundary_found && boundary.boundary_in_mask);
    assert(!above.boundary_present && !above.boundary_found && !above.boundary_in_mask);
    assert(world.count(Filler{3}) == 0 && world.count(Filler{64}) == 1);
    assert(world.get(keeper, Filler{64}).value == 1);
}

fn void test_each_slot_visits_set_slots_in_ascending_order() @test {
    World world = filled_world(4);
    defer ecs::destroy_world(&world);

    Entity entity = world.create_entity()!!;
    world.add(entity, (Filler{127}){});
    world.add(entity, (Filler{0}){});
    world.add(entity, (Filler{64}){});
    world.add(entity, (Filler{3}){});
    world.add(entity, (Filler{65}){});
    world.add(entity, (Filler{63}){});
    uint[6] expected = { 0, 3, 63, 64, 65, 127 };
    uint visits;
    world.@each_slot(entity; uint slot) {
        assert(visits < expected.len && slot == expected[visits]);
        visits++;
    };
    assert(visits == expected.len);

    Entity empty = world.create_entity()!!;
    world.@each_slot(empty; uint slot) {
        visits++;
    };
    assert(visits == expected.len);
}

fn bool? empty_description(Visitor* visitor, void* value) @local {
    return false;
}

fn bool? other_description(Visitor* visitor, void* value) @local {
    return false;
}

fn void test_description_capacity_failure_does_not_publish_or_assign_a_slot() @test {
    describe::register_type(ExistingDescription, &empty_description)!!;
    if (catch excuse = ecs::assigned_slot(ExistingDescription)) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }
    World world = filled_world(1);
    defer ecs::destroy_world(&world);

    if (catch excuse = describe::register_component(ExistingDescription, &other_description)) {
        assert(excuse == describe::DESCRIPTION_CONFLICT);
    } else {
        assert(false);
    }
    assert((describe::get(ExistingDescription)!!).fields == &empty_description);
    if (catch excuse = describe::register_component(UnpublishedDescription, &empty_description)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    if (catch excuse = describe::get(UnpublishedDescription)) {
        assert(excuse == describe::MISSING_DESCRIPTION);
    } else {
        assert(false);
    }
    if (catch excuse = ecs::assigned_slot(UnpublishedDescription)) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }

    describe::register_type(UnpublishedDescription, &empty_description)!!;
    String missing;
    describe::validate_descriptions(&missing)!!;
    assert(missing == "");
}
