module c3d::pool <Type, IdType>;

import c3d;

<*
 Fixed-capacity table of values addressed by generational ids.
*>
struct Pool {
    Allocator allocator;
    Type[]    items;
    uint[]    generations;
    uint[]    free;
    uint      free_count;
}

<*
 Whether the id still addresses the value it was issued for.
*>
fn bool Pool.is_live(&self, IdType id) {
    return id.index < self.items.len && self.generations[id.index] == id.generation;
}

<*
 Store a value in a free slot and return its id.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn IdType? Pool.add(&self, Type value) {
    if (!self.free_count) return c3d::CAPACITY_EXCEEDED~;
    self.free_count--;
    uint slot = self.free[self.free_count];
    self.items[slot] = value;
    return (IdType){ .index = slot, .generation = self.generations[slot] };
}

<*
 Address of the value the id was issued for.
 Invalidated by a later add or remove on the same pool.
 @require self.is_live(id)
*>
fn Type* Pool.get(&self, IdType id) {
    return &self.items[id.index];
}

<*
 Address of the value, for entry points that must reject a stale id.
 Invalidated by a later add or remove on the same pool.
 @return? c3d::INVALID_ID
*>
fn Type*? Pool.try_get(&self, IdType id) {
    if (!self.is_live(id)) return c3d::INVALID_ID~;
    return &self.items[id.index];
}

<*
 Release the slot and make every id to it stale.
 @require self.is_live(id)
*>
fn void Pool.remove(&self, IdType id) {
    uint slot = id.index;
    self.generations[slot]++;
    // Generation 0 belongs to a zero-initialized Id, so a wrapped counter skips it.
    if (!self.generations[slot]) self.generations[slot] = 1;
    self.free[self.free_count] = slot;
    self.free_count++;
}

<*
 Create a pool with a fixed slot capacity.
 @require capacity > 0
*>
fn Pool create_pool(Allocator allocator, uint capacity) {
    Pool pool = {
        .allocator   = allocator,
        .items       = alloc::new_array(allocator, Type, capacity),
        .generations = alloc::new_array(allocator, uint, capacity),
        .free        = alloc::new_array(allocator, uint, capacity),
        .free_count  = capacity,
    };
    for (uint slot = 0; slot < capacity; slot++) {
        pool.generations[slot] = 1;
        pool.free[slot] = capacity - 1 - slot;
    }
    return pool;
}

<*
 Free the pool's storage.
 @param [&inout] pool : "Left zeroed; every id to it is dead."
*>
fn void destroy_pool(Pool* pool) {
    alloc::free(pool.allocator, pool.items.ptr);
    alloc::free(pool.allocator, pool.generations.ptr);
    alloc::free(pool.allocator, pool.free.ptr);
    *pool = {};
}
