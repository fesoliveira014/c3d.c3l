module c3d::asset::custom <Type>;

import c3d::asset;
import c3d::pool;

<*
 Process-wide slot of the kind plus one; zero until first registered.
*>
uint slot;

<*
 Generational handle of one registered kind. The zero value is never live.
*>
struct CustomId {
    uint index;
    uint generation;
}

<*
 Address of the kind's process-wide slot.
*>
fn uint* CustomId.slot_address(self) => &slot;

<*
 Record of one registered kind.
*>
struct CustomAsset {
    AssetHeader header;
    Type        data;
}

<*
 Pool of records addressed by CustomId.
*>
alias CustomPool = Pool{CustomAsset, CustomId};

<*
 Heap pool of the kind for one store.
 @require capacity > 0
*>
fn CustomPool* create_erased(Allocator allocator, uint capacity) {
    CustomPool* pool = alloc::new(allocator, CustomPool);
    *pool = pool::create_pool{CustomAsset, CustomId}(allocator, capacity);
    return pool;
}

<*
 Key of a live record.
 @param [&in] erased : "A CustomPool from create_erased."
 @return? c3d::INVALID_ID
*>
fn String? key_erased(void* erased, Id id) {
    CustomPool* pool = (CustomPool*)erased;
    return pool.try_get({ .index = id.index, .generation = id.generation })!.header.key;
}

<*
 Free every live record's key and payload, then the pool.
 @param [&inout] erased : "A CustomPool from create_erased; dead afterwards."
 @param on_destroy : "Runs on each live payload; null skips."
 @param [in] user : "Pointer given to register."
*>
fn void destroy_erased(
    void* erased,
    Allocator allocator,
    CustomFreeFn on_destroy,
    void* user,
) {
    CustomPool* pool = (CustomPool*)erased;
    foreach (&record : pool.items) {
        if (!record.header.revision) continue;
        asset::free_string(allocator, record.header.key);
        if (on_destroy) on_destroy(allocator, &record.data, user);
    }
    pool::destroy_pool{CustomAsset, CustomId}(pool);
    alloc::free(allocator, pool);
}
