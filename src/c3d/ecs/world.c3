module c3d::ecs;

import c3d;
import c3d::pool;

<*
 Generational entity handle. The zero value is never live.
*>
typedef Entity = Id;

<*
 Called with the departing component before its storage is reused.
*>
alias RemoveFn = fn void (Entity entity, void* component, void* user);

alias ErasedRemove @local  = fn void (void* store, Entity entity);
alias ErasedDestroy @local = fn void (void* store);

<*
 Entity pool whose item is the entity's component mask.
*>
alias EntityPool = Pool{ulong, Entity};

<*
 Registered component types one process supports.
*>
const uint MAX_COMPONENT_TYPES = 64; // one ulong mask per entity; one and-test per @each2 candidate

uint registered_type_count @local;

<*
 Entities and one component store per registered type.
*>
struct World {
    Allocator                          allocator;
    uint                               capacity;
    EntityPool                         entities;
    void*[MAX_COMPONENT_TYPES]         stores;
    ErasedRemove[MAX_COMPONENT_TYPES]  removers;
    ErasedDestroy[MAX_COMPONENT_TYPES] destroyers;
}

<*
 Whether the entity still addresses the slot it was issued for.
*>
fn bool World.is_alive(&self, Entity entity) {
    return self.entities.is_live(entity);
}

<*
 Allocate an entity with no components.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn Entity? World.create_entity(&self) {
    return self.entities.add(0);
}

<*
 Remove every component through its hook, then retire the entity.
 Invalidates component pointers of every store the entity used.
 @require self.is_alive(entity)
*>
fn void World.destroy_entity(&self, Entity entity) {
    remove_all(self, entity);
    self.entities.remove(entity);
}

<*
 Give the type a process-wide slot and this world a store for it.
 @return? c3d::CAPACITY_EXCEEDED
*>
macro void? World.register(&self, $Type) {
    if (!store::slot{$Type}) {
        if (registered_type_count == MAX_COMPONENT_TYPES) return c3d::CAPACITY_EXCEEDED~;
        registered_type_count++;
        store::slot{$Type} = registered_type_count;
    }
    uint index = store::slot{$Type} - 1;
    if (self.stores[index]) return;
    self.stores[index] = store::create_store{$Type}(self.allocator, self.capacity);
    self.removers[index] = &store::erased_remove{$Type};
    self.destroyers[index] = &store::erased_destroy{$Type};
    return;
}

<*
 Whether this world has a store for the type.
*>
macro bool World.is_registered(&self, $Type) {
    return store::slot{$Type} != 0 && self.stores[store::slot{$Type} - 1] != null;
}

<*
 Attach a component and return its short-lived address.
 @require self.is_alive(entity), self.is_registered($Typeof(value)), !self.has(entity, $Typeof(value))
*>
macro World.add(&self, Entity entity, value) {
    var $Type = $Typeof(value);
    self.entities.items[entity.index] |= bit_of($Type);
    return store_of(self, $Type).add(entity, value);
}

<*
 Short-lived address of the entity's component, null when absent.
 Invalidated by a remove on the same store.
 @require self.is_alive(entity)
*>
macro World.get(&self, Entity entity, $Type) {
    if (!self.has(entity, $Type)) return ($Type*)null;
    return store_of(self, $Type).get(entity);
}

<*
 Whether the entity carries the type.
 @require self.is_alive(entity)
*>
macro bool World.has(&self, Entity entity, $Type) {
    return store::slot{$Type} != 0 && (self.entities.items[entity.index] & bit_of($Type)) != 0;
}

<*
 Detach the component through its hook.
 Invalidates component pointers of the same store.
 @require self.has(entity, $Type)
*>
macro void World.remove(&self, Entity entity, $Type) {
    store_of(self, $Type).remove(entity);
    self.entities.items[entity.index] &= ~bit_of($Type);
}

<*
 Install the hook every later removal of the type runs.
 @param [in] user : "Passed to the hook unchanged."
 @require self.is_registered($Type)
*>
macro void World.set_remove_hook(&self, $Type, RemoveFn on_remove, void* user) {
    store::ComponentStore{$Type}* component_store = store_of(self, $Type);
    component_store.on_remove = on_remove;
    component_store.user = user;
}

<*
 Components of the type in this world.
*>
macro uint World.count(&self, $Type) {
    if (!self.is_registered($Type)) return 0;
    return store_of(self, $Type).count;
}

<*
 Visit every component of the type once, in dense order.
 The body must not add or remove components of the same type.
*>
macro World.@each(&self, $Type; @body(entity, component)) {
    if (self.is_registered($Type)) {
        store::ComponentStore{$Type}* component_store = store_of(self, $Type);
        for (uint position = 0; position < component_store.count; position++) {
            @body(component_store.owners[position], &component_store.dense[position]);
        }
    }
}

<*
 Visit every entity carrying both types once.
 The body must not add or remove components of either type.
*>
macro World.@each2(&self, $TypeA, $TypeB; @body(entity, a, b)) {
    if (self.is_registered($TypeA) && self.is_registered($TypeB)) {
        store::ComponentStore{$TypeA}* store_a = store_of(self, $TypeA);
        store::ComponentStore{$TypeB}* store_b = store_of(self, $TypeB);
        if (store_a.count <= store_b.count) {
            ulong bit = bit_of($TypeB);
            for (uint position = 0; position < store_a.count; position++) {
                Entity entity = store_a.owners[position];
                if (self.entities.items[entity.index] & bit) {
                    @body(entity, &store_a.dense[position], store_b.get(entity));
                }
            }
        } else {
            ulong bit = bit_of($TypeA);
            for (uint position = 0; position < store_b.count; position++) {
                Entity entity = store_b.owners[position];
                if (self.entities.items[entity.index] & bit) {
                    @body(entity, store_a.get(entity), &store_b.dense[position]);
                }
            }
        }
    }
}

<*
 Create a world with a fixed entity capacity and no registered types.
 @require capacity > 0
*>
fn World create_world(Allocator allocator, uint capacity) {
    return {
        .allocator = allocator,
        .capacity  = capacity,
        .entities  = pool::create_pool{ulong, Entity}(allocator, capacity),
    };
}

<*
 Run every remaining component's hook, then free the stores and entities.
 @param [&inout] world : "Left zeroed; every entity of it is dead."
*>
fn void destroy_world(World* world) {
    foreach (index, mask : world.entities.items) {
        if (!mask) continue;
        Entity entity = { .index = (uint)index, .generation = world.entities.generations[index] };
        remove_all(world, entity);
    }
    foreach (slot, store : world.stores) {
        if (store) world.destroyers[slot](store);
    }
    pool::destroy_pool{ulong, Entity}(&world.entities);
    *world = {};
}

fn void remove_all(World* world, Entity entity) @local {
    ulong mask = world.entities.items[entity.index];
    while (mask) {
        uint slot = (uint)mask.ctz();
        world.removers[slot](world.stores[slot], entity);
        mask &= mask - 1;
    }
    world.entities.items[entity.index] = 0;
}

macro store_of(World* world, $Type) @local {
    return (store::ComponentStore{$Type}*)world.stores[store::slot{$Type} - 1];
}

macro ulong bit_of($Type) @local {
    return 1ul << (store::slot{$Type} - 1);
}
