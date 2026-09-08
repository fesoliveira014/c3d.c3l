module ecs_example;

import std::io;
import c3d;
import c3d::ecs;

const uint ENTITY_CAPACITY @local = 16;

struct Health @local {
    float value;
    float maximum;
}

struct Inventory @local {
    String[] items;
}

fn void free_inventory(Entity entity, void* component, void* user) @local {
    Inventory* inventory = (Inventory*)component;
    io::printfn("  freeing inventory of entity %d (%d items)", entity.index, inventory.items.len);
    alloc::free(*(Allocator*)user, inventory.items.ptr);
}

fn Inventory make_inventory(Allocator allocator, String[] names) @local {
    String[] items = alloc::new_array(allocator, String, names.len);
    items[..] = names[..];
    return { .items = items };
}

fn void populate(World* world, String label) @local {
    world.set_remove_hook(Inventory, &free_inventory, &world.allocator);

    Entity knight = world.create_entity()!!;
    Entity archer = world.create_entity()!!;
    Entity ghost = world.create_entity()!!;

    world.add(knight, (Health){ .value = 80, .maximum = 100 });
    world.add(archer, (Health){ .value = 45, .maximum = 60 });
    world.add(knight, make_inventory(world.allocator, { "sword", "shield" }));
    world.add(archer, make_inventory(world.allocator, { "bow" }));
    world.add(ghost, make_inventory(world.allocator, { "chain" }));

    io::printfn("%s: health", label);
    world.@each(Health; Entity entity, Health* health) {
        io::printfn("  entity %d: %.0f / %.0f", entity.index, health.value, health.maximum);
    };
    io::printfn("%s: health with inventory", label);
    world.@each2(Health, Inventory; Entity entity, Health* health, Inventory* inventory) {
        io::printfn("  entity %d: %.0f health, %d items", entity.index, health.value, inventory.items.len);
    };

    io::printfn("%s: archer drops inventory", label);
    world.remove(archer, Inventory);
    io::printfn("%s: ghost destroyed", label);
    world.destroy_entity(ghost);
    io::printfn("%s: %d health, %d inventories, ghost alive %s",
        label, world.count(Health), world.count(Inventory), world.is_alive(ghost));
}

fn int main() {
    World first = ecs::create_world(mem, ENTITY_CAPACITY);
    World second = ecs::create_world(mem, ENTITY_CAPACITY);

    first.register(Health)!!;
    first.register(Inventory)!!;
    second.register(Inventory)!!;
    second.register(Health)!!;

    populate(&first, "first");
    populate(&second, "second");

    io::printfn("destroying first");
    ecs::destroy_world(&first);
    io::printfn("destroying second");
    ecs::destroy_world(&second);
    return 0;
}
