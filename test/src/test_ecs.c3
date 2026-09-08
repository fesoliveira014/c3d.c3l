module c3d::test::ecs;

import c3d;
import c3d::ecs;
import c3d::ecs::store;

struct Health @local {
    float value;
}

struct Tag @local {
    int label;
}

struct HookRecord @local {
    Entity entity;
    void*  component;
    void*  user;
    uint   calls;
}

fn void record_removal(Entity entity, void* component, void* user) @local {
    HookRecord* record = (HookRecord*)user;
    *record = { .entity = entity, .component = component, .user = user, .calls = record.calls + 1 };
}

fn bool same_entity(Entity left, Entity right) @local {
    return left.index == right.index && left.generation == right.generation;
}

fn World make_world(uint capacity) @local {
    World world = ecs::create_world(mem, capacity);
    world.register(Health)!!;
    world.register(Tag)!!;
    return world;
}

fn void test_add_then_get_returns_the_value() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    Entity entity = world.create_entity()!!;
    Health* added = world.add(entity, (Health){ .value = 7 });

    assert(added.value == 7);
    assert(world.get(entity, Health) == added);
    assert(world.has(entity, Health));
}

fn void test_get_on_absent_component_is_null() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    Entity entity = world.create_entity()!!;
    world.add(entity, (Health){ .value = 1 });

    assert(world.get(entity, Tag) == null);
    assert(!world.has(entity, Tag));
    assert(world.count(Tag) == 0);
}

fn void test_remove_clears_the_mask_bit() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    Entity entity = world.create_entity()!!;
    world.add(entity, (Health){ .value = 1 });
    world.add(entity, (Tag){ .label = 2 });
    world.remove(entity, Health);

    assert(!world.has(entity, Health));
    assert(world.get(entity, Health) == null);
    assert(world.count(Health) == 0);
    assert((world.entities.items[entity.index] & (1ul << (store::slot{Health} - 1))) == 0);
    assert(world.has(entity, Tag));
}

fn void test_swap_remove_keeps_the_moved_component_addressable() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    Entity first = world.create_entity()!!;
    Entity second = world.create_entity()!!;
    Entity third = world.create_entity()!!;
    world.add(first, (Health){ .value = 1 });
    world.add(second, (Health){ .value = 2 });
    world.add(third, (Health){ .value = 3 });
    world.remove(first, Health);

    assert(world.count(Health) == 2);
    assert(world.get(third, Health).value == 3);
    assert(world.get(second, Health).value == 2);
}

fn void test_each_visits_every_component_once() @test {
    World world = make_world(8);
    defer ecs::destroy_world(&world);

    float expected_sum;
    for (uint index = 0; index < 5; index++) {
        Entity entity = world.create_entity()!!;
        world.add(entity, (Health){ .value = (float)(index + 1) });
        expected_sum += (float)(index + 1);
    }

    float sum;
    uint visits;
    world.@each(Health; Entity entity, Health* health) {
        sum += health.value;
        visits++;
    };

    assert(visits == 5);
    assert(sum == expected_sum);
}

fn void test_each2_visits_only_entities_with_both_types() @test {
    World world = make_world(8);
    defer ecs::destroy_world(&world);

    Entity[4] entities;
    for (uint index = 0; index < 4; index++) {
        entities[index] = world.create_entity()!!;
        world.add(entities[index], (Health){ .value = (float)index });
    }
    world.add(entities[1], (Tag){ .label = 1 });
    world.add(entities[3], (Tag){ .label = 3 });

    uint visits;
    world.@each2(Health, Tag; Entity entity, Health* health, Tag* tag) {
        assert(same_entity(entity, entities[1]) || same_entity(entity, entities[3]));
        assert(health == world.get(entity, Health));
        assert(tag == world.get(entity, Tag));
        assert((float)tag.label == health.value);
        visits++;
    };
    assert(visits == 2);

    visits = 0;
    world.@each2(Tag, Health; Entity entity, Tag* tag, Health* health) {
        assert(tag == world.get(entity, Tag));
        assert(health == world.get(entity, Health));
        visits++;
    };
    assert(visits == 2);
}

fn void test_removal_hook_receives_the_departing_component() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    HookRecord record;
    world.set_remove_hook(Tag, &record_removal, &record);
    Entity entity = world.create_entity()!!;
    Tag* tag = world.add(entity, (Tag){ .label = 9 });
    world.remove(entity, Tag);

    assert(record.calls == 1);
    assert(same_entity(record.entity, entity));
    assert(record.component == tag);
    assert(record.user == &record);
}

fn void test_moved_component_does_not_run_the_hook() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    HookRecord record;
    world.set_remove_hook(Tag, &record_removal, &record);
    Entity first = world.create_entity()!!;
    Entity second = world.create_entity()!!;
    world.add(first, (Tag){ .label = 1 });
    world.add(second, (Tag){ .label = 2 });
    world.remove(first, Tag);

    assert(record.calls == 1);
    assert(same_entity(record.entity, first));
    assert(world.get(second, Tag).label == 2);
}

fn void test_destroy_entity_removes_every_component() @test {
    World world = make_world(4);
    defer ecs::destroy_world(&world);

    HookRecord health_record;
    HookRecord tag_record;
    world.set_remove_hook(Health, &record_removal, &health_record);
    world.set_remove_hook(Tag, &record_removal, &tag_record);
    Entity keeper = world.create_entity()!!;
    Entity entity = world.create_entity()!!;
    world.add(keeper, (Health){ .value = 1 });
    world.add(keeper, (Tag){ .label = 1 });
    world.add(entity, (Health){ .value = 2 });
    world.add(entity, (Tag){ .label = 2 });
    world.destroy_entity(entity);

    assert(!world.is_alive(entity));
    assert(health_record.calls == 1 && same_entity(health_record.entity, entity));
    assert(tag_record.calls == 1 && same_entity(tag_record.entity, entity));
    assert(world.count(Health) == 1);
    assert(world.count(Tag) == 1);
    assert(world.get(keeper, Health).value == 1);
}

fn void test_stale_entity_is_not_alive_after_reuse() @test {
    World world = make_world(1);
    defer ecs::destroy_world(&world);

    Entity first = world.create_entity()!!;
    world.destroy_entity(first);
    Entity second = world.create_entity()!!;

    assert(second.index == first.index);
    assert(second.generation > first.generation);
    assert(!world.is_alive(first));
    assert(world.is_alive(second));
}

fn void test_full_world_faults() @test {
    World world = make_world(2);
    defer ecs::destroy_world(&world);

    world.create_entity()!!;
    world.create_entity()!!;
    if (catch excuse = world.create_entity()) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full world created an entity");
    }
}

fn void test_unregistered_type_reads_as_absent() @test {
    World world = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&world);
    world.register(Health)!!;

    Entity entity = world.create_entity()!!;
    world.add(entity, (Health){ .value = 1 });

    uint visits;
    world.@each(Tag; Entity owner, Tag* tag) {
        visits++;
    };

    assert(!world.is_registered(Tag));
    assert(world.count(Tag) == 0);
    assert(!world.has(entity, Tag));
    assert(world.get(entity, Tag) == null);
    assert(visits == 0);
}

fn void test_two_worlds_share_slots_in_any_order() @test {
    World first = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&first);
    World second = ecs::create_world(mem, 4);
    defer ecs::destroy_world(&second);
    first.register(Health)!!;
    first.register(Tag)!!;
    second.register(Tag)!!;
    second.register(Health)!!;

    Entity entity = first.create_entity()!!;
    first.add(entity, (Health){ .value = 1 });
    Entity other = second.create_entity()!!;
    second.add(other, (Tag){ .label = 1 });

    assert(first.stores[store::slot{Health} - 1] != second.stores[store::slot{Health} - 1]);
    assert(first.count(Health) == 1 && first.count(Tag) == 0);
    assert(second.count(Health) == 0 && second.count(Tag) == 1);
    assert(first.get(entity, Health).value == 1);
    assert(second.get(other, Tag).label == 1);
}

fn void test_destroy_world_runs_remaining_hooks() @test {
    World world = make_world(4);

    HookRecord record;
    world.set_remove_hook(Tag, &record_removal, &record);
    for (uint index = 0; index < 3; index++) {
        Entity entity = world.create_entity()!!;
        world.add(entity, (Tag){ .label = (int)index });
    }
    ecs::destroy_world(&world);

    assert(record.calls == 3);
    assert(world.entities.items.len == 0);
}
