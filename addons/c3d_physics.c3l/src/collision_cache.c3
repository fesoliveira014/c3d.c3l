module c3d::physics;

import c3d;
import c3d::asset;

<* Capacity and wireframe policy of shared collision cooking. *>
struct CollisionCacheDesc {
    uint snapshot_capacity;
    bool cache_wireframes;
}

<* Own immutable collision data bound to one borrowed asset store. *>
struct CollisionCache {
    SnapshotTable* state;
}

<* Default collision cooking capacity and wireframe policy. *>
fn CollisionCacheDesc default_collision_cache_desc() {
    return { .snapshot_capacity = DEFAULT_SNAPSHOT_CAPACITY, .cache_wireframes = true };
}

<*
 Create a world-free collision cache.
 @param [&in] assets : "Borrowed; outlives the cache."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn CollisionCache? create_collision_cache(Allocator allocator, AssetStore* assets, CollisionCacheDesc desc) {
    return { .state = create_snapshot_table(allocator, assets, desc)! };
}

<*
 Free unused cooked entries and the cache.
 @param [&inout] cache : "Zeroed on success; unchanged while borrowed."
 @return? c3d::RESOURCE_IN_USE
*>
fn void? destroy_collision_cache(CollisionCache* cache) {
    if (!cache.state) return;
    SnapshotTable* table = cache.state;
    if (table.borrowers) return c3d::RESOURCE_IN_USE~;
    foreach (slot : table.slots) if (slot.holders) return c3d::RESOURCE_IN_USE~;
    destroy_snapshot_table(table);
    *cache = {};
}
