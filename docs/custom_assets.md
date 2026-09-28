# Custom asset kinds

`AssetStore` holds ten builtin kinds. An add-on or application adds its own
kind by registering a record type: the store then owns a pool for it, keys and
`find` cover it, and `destroy_asset_store` releases it. Core provides the
mechanism; the kind's owner writes the typed methods.

## Registering a kind

```c3
AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
defer asset::destroy_asset_store(&assets);

assets.register(AudioClip, 256, &free_audio_clip_payload)!;
```

- `register($Type, capacity, on_destroy, user)` gives the type a process-wide
  slot the first time any store registers it, then allocates this store's pool
  of `capacity` records. A second call on the same store changes nothing; the
  first capacity and hook stand.
- `on_destroy(allocator, data, user)` runs from `destroy_asset_store` on every
  live record's payload. Pass `null` when the payload owns no memory.
- A process registers at most `asset::MAX_CUSTOM_ASSET_TYPES` (16) distinct
  types; the next one faults `CAPACITY_EXCEEDED`.
- The slot counter and each type's slot are unsynchronized process globals.
  Call `register` during setup, on one thread.
- `is_registered($Type)` reports whether this store has a pool; `pool($Type)`
  returns it as `custom::CustomPool{$Type}*`.

## The owner layer

The owner declares the same four methods a builtin kind has, as extension
methods on `AssetStore`. Users of the kind call them exactly like
`add_clip_owned`, `clip`, `remove_clip` and `find_clip`.

```c3
module c3d::audio;

import c3d;
import c3d::asset;
import c3d::asset::custom;

alias AudioClipId = CustomId{AudioClip};
alias AudioClipAsset = CustomAsset{AudioClip};

<*
 Add an audio clip, taking ownership of its arrays.
 @param [&in] clip : "Arrays must come from the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn AudioClipId? AssetStore.add_audio_clip_owned(&self, AudioClip* clip, String key = "") {
    asset::check_key(self, key)!;
    CustomPool{AudioClip}* pool = self.pool(AudioClip);
    AudioClipId id = pool.add({})!;
    *pool.get(id) = {
        .header = { .key = asset::copy_string(self.allocator, key), .revision = 1 },
        .data   = *clip,
    };
    asset::register_key(self, key, asset::custom_ref(AudioClip, id));
    return id;
}

<*
 Borrow an audio clip record.
 @require self.pool(AudioClip).is_live(id)
*>
fn AudioClipAsset* AssetStore.audio_clip(&self, AudioClipId id) => self.pool(AudioClip).get(id);

<*
 Remove an audio clip and free its arrays.
 @require self.pool(AudioClip).is_live(id)
*>
fn void AssetStore.remove_audio_clip(&self, AudioClipId id) {
    CustomPool{AudioClip}* pool = self.pool(AudioClip);
    AudioClipAsset* record = pool.get(id);
    asset::forget_key(self, record.header.key);
    asset::free_string(self.allocator, record.header.key);
    free_audio_clip(self.allocator, &record.data);
    *record = {};
    pool.remove(id);
}

<*
 Audio clip registered under the key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn AudioClipId? AssetStore.find_audio_clip(&self, String key) => asset::custom_id(AudioClip, self.find(key)!);
```

`check_key` runs before a pool slot is taken, so a duplicate key faults
`INVALID_ARGUMENT` without consuming capacity. `CustomFreeFn` is the hook type;
it is not named `FreeFn` because box3d, cgltf and ufbx each declare one.

## Keys and find

`assets.find(key)` returns an `AssetRef` with `kind == AssetKind.CUSTOM` and
`slot` set to the type's process slot. `asset::custom_id($Type, ref)` turns it
into a typed id and faults `INVALID_ARGUMENT` for a builtin reference or a
reference of another custom kind. `find_texture` and the other builtin
adapters fault `INVALID_ARGUMENT` on a custom key.

`CustomId{T}` is a distinct struct per kind: an id of one kind cannot be cast
into an id of another.

## Lifetime

- A record with `header.revision == 0` is an empty slot. `add_*_owned` sets
  revision 1; `remove_*` zeroes the record before `pool.remove`.
- `remove_*` frees the payload itself; `on_destroy` covers only records still
  live when the store is destroyed.
- `destroy_asset_store` releases custom pools after the builtin records and
  before the key map.

## Limits

- `MAX_CUSTOM_ASSET_TYPES` kinds per process.
- The renderer never sees custom kinds; there is no GPU mirror for them.
- Builtin kinds keep their typed pools and loaders; nothing migrates.
