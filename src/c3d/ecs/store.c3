module c3d::ecs::store <Type>;

import c3d::ecs;

<*
 Process-wide slot of the type plus one; zero until first registered.
*>
uint slot;

<*
 Sparse set of one component type for one world.
*>
struct ComponentStore {
    Allocator allocator;
    Type[]    dense;
    Entity[]  owners;
    uint[]    sparse;
    uint      count;
    RemoveFn  on_remove;
    void*     user;
}

<*
 Append the value and return its short-lived address.
 @require self.sparse[entity.index] == 0
*>
fn Type* ComponentStore.add(&self, Entity entity, Type value) {
    uint position = self.count;
    self.dense[position] = value;
    self.owners[position] = entity;
    self.sparse[entity.index] = position + 1;
    self.count++;
    return &self.dense[position];
}

<*
 Short-lived address of the entity's component.
 @require self.sparse[entity.index] != 0
*>
fn Type* ComponentStore.get(&self, Entity entity) {
    return &self.dense[self.sparse[entity.index] - 1];
}

<*
 Run the hook on the departing value, then swap-remove it.
 Invalidates the address of the moved last component.
 @require self.sparse[entity.index] != 0
*>
fn void ComponentStore.remove(&self, Entity entity) {
    uint position = self.sparse[entity.index] - 1;
    uint last = self.count - 1;
    if (self.on_remove) self.on_remove(entity, &self.dense[position], self.user);
    if (position != last) {
        self.dense[position] = self.dense[last];
        self.owners[position] = self.owners[last];
        self.sparse[self.owners[position].index] = position + 1;
    }
    self.sparse[entity.index] = 0;
    self.count--;
}

<*
 Type-erased remove for the world's destruction tables.
 @param [&inout] raw : "A ComponentStore of this type."
*>
fn void erased_remove(void* raw, Entity entity) {
    ((ComponentStore*)raw).remove(entity);
}

<*
 Type-erased destroy for the world's destruction tables.
 @param [&inout] raw : "A ComponentStore of this type."
*>
fn void erased_destroy(void* raw) {
    destroy_store((ComponentStore*)raw);
}

<*
 Allocate an empty store whose arrays span the entity capacity.
 @require capacity > 0
*>
fn ComponentStore* create_store(Allocator allocator, uint capacity) {
    ComponentStore* component_store = alloc::new(allocator, ComponentStore);
    *component_store = {
        .allocator = allocator,
        .dense     = alloc::new_array(allocator, Type, capacity),
        .owners    = alloc::new_array(allocator, Entity, capacity),
        .sparse    = alloc::new_array(allocator, uint, capacity),
    };
    return component_store;
}

<*
 Free the store's arrays and the store.
 @param [&inout] component_store : "Dead afterwards."
*>
fn void destroy_store(ComponentStore* component_store) {
    Allocator allocator = component_store.allocator;
    alloc::free(allocator, component_store.dense.ptr);
    alloc::free(allocator, component_store.owners.ptr);
    alloc::free(allocator, component_store.sparse.ptr);
    alloc::free(allocator, component_store);
}
