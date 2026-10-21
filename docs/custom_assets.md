# Custom asset kinds

`AssetStore` holds 11 built-in kinds (geometry, texture, sampler, material, model, clip, skeleton, shader, compute shader,
environment and font). An add-on or application adds its own kind by registering a record type: the store then owns a
pool for it, keys and `find` cover it, and `destroy_asset_store` releases it. Core provides the mechanism; the kind's
owner writes the typed functions. The `c3d_audio` add-on's `AudioClip` is the worked example throughout. The store is
described in [Asset store](assets.md).

## Quick start

Register the kind once per store, add a record and find it by key.

```c3
import c3d::asset;
import c3d::audio;

AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
defer asset::destroy_asset_store(&assets);

audio::register_audio_clips(&assets, 256)!;
AudioClipId id = audio::add_audio_clip(&assets, encoded_sound, key: "sfx/door")!;

AssetRef ref = assets.find("sfx/door")!;
AudioClipId found = asset::custom_id(AudioClip, ref)!;
```

`encoded_sound` holds the bytes of a WAV, FLAC, MP3 or Ogg Vorbis file. Applications call the owner's typed functions
instead of using the pool directly. The next sections show how an owner writes them.

## Concepts

- **Process slot.** `register($Type, capacity, on_destroy = null, user = null)` gives the type a process-wide slot the
  first time any store registers it, then allocates this store's pool of `capacity` records, which must be positive. A
  second call on the same store changes nothing; the first capacity and hook stand.
- **Per-store pool.** Each store holds its own `CustomPool{T}`, reached with `pool($Type)`, which requires the type to be
  registered. `is_registered($Type)` reports whether this store has a pool.
- **Ids.** `CustomId{T}` is a distinct struct per kind: an ID of one kind cannot be cast into an ID of another. A record is
  a `CustomAsset{T}` with a `header` and a `data` payload.
- **Destroy hook.** `on_destroy(allocator, data, user)` runs from `destroy_asset_store` on every live record's payload.
  Core frees `header.key` before the call, so the hook frees the payload only. Pass `null` when the payload owns no
  memory. `CustomFreeFn` is the hook type.
- **Capacity.** A process registers at most `asset::MAX_CUSTOM_ASSET_TYPES` (16) distinct types; the next one faults
  `CAPACITY_EXCEEDED`.
- **Thread.** The slot counter and each type's slot are unsynchronized process globals. Call `register` during setup on one
  thread.

## Define the owner API

The owner declares the typed functions of its kind. A builtin kind has `add_clip_owned`, `clip`, `remove_clip` and
`find_clip` as `AssetStore` methods; the audio add-on uses free functions that take the store, and either shape is valid.
This excerpt simplifies `register_audio_clips`, `add_audio_clip` and `remove_audio_clip` of the add-on, which also probe
the encoded format, take a playback mode before the key and reject empty bytes.

```c3
module c3d::audio;

import c3d;
import c3d::asset;
import c3d::asset::custom;

alias AudioClipId = CustomId{AudioClip};
alias AudioClipAsset = CustomAsset{AudioClip};

fn void free_audio_clip_payload(Allocator allocator, void* data, void* user) {
    alloc::free(allocator, ((AudioClip*)data).bytes.ptr);
}

<*
 Register the clip kind with the store.
 @return? c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn void? register_audio_clips(AssetStore* assets, uint capacity) {
    assets.register(AudioClip, capacity, &free_audio_clip_payload)!;
}

<*
 Add a clip, copying the encoded bytes.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn AudioClipId? add_audio_clip(AssetStore* assets, char[] bytes, String key = "") {
    asset::check_key(assets, key)!;
    CustomPool{AudioClip}* pool = assets.pool(AudioClip);
    AudioClipId id = pool.add({})!;
    char[] copy = alloc::new_array(assets.allocator, char, bytes.len);
    copy[..] = bytes[..];
    *pool.get(id) = {
        .header = { .key = asset::copy_string(assets.allocator, key), .revision = 1 },
        .data   = { .bytes = copy },
    };
    asset::register_key(assets, key, asset::custom_ref(AudioClip, id));
    return id;
}

<*
 Free the clip and make its id stale.
 @require assets.pool(AudioClip).is_live(clip)
*>
fn void remove_audio_clip(AssetStore* assets, AudioClipId clip) {
    CustomPool{AudioClip}* pool = assets.pool(AudioClip);
    AudioClipAsset* record = pool.get(clip);
    asset::forget_key(assets, record.header.key);
    asset::free_string(assets.allocator, record.header.key);
    alloc::free(assets.allocator, record.data.bytes.ptr);
    *record = {};
    pool.remove(clip);
}
```

`check_key` runs before a pool slot is taken, so a duplicate key faults `INVALID_ARGUMENT` without consuming capacity.
`check_key`, `register_key`, `forget_key`, `copy_string` and `free_string` are the public key helpers. `custom_ref($Type,
id)` builds the `AssetRef` a key maps to and requires the type to be registered. The `remove` function frees the key
itself, as above, whereas the destroy hook must not.

## Keys and find

`assets.find(key)` returns an `AssetRef` with `kind == AssetKind.CUSTOM` and `slot` set to the type's process slot, or
faults `NOT_FOUND` for an unknown or removed key.
`asset::custom_id($Type, ref)` turns it into a typed ID and faults `INVALID_ARGUMENT` for a built-in reference or a
reference of another custom kind. `find_texture` and the other built-in adapters fault `INVALID_ARGUMENT` on a custom key.
An owner that wants lookup by key wraps these two calls in a function of its own.

## Lifetime and revisions

- A record with `header.revision == 0` is an empty slot. The owner's `add` function sets revision 1, because the pool
  leaves it zero and `destroy_asset_store` skips zero-revision records, leaking their key and payload. The owner's
  `remove` zeroes the record before `pool.remove`.
- An owner that edits a payload in place advances `header.revision`, as `mark_material_dirty` does for materials, so
  consumers keyed on the revision see the change.
- An owner that replaces a whole payload also sets `header.replaced_revision` to the new revision, so consumers that
  refresh incrementally do not patch replaced content as an edit. An in-place edit leaves it unchanged.
- `remove` frees the payload itself; `on_destroy` covers only records still live when the store is destroyed.
- `destroy_asset_store` releases custom pools after the built-in records and before the key map.

## Serialization and descriptions

A custom kind is saved by key through its process-wide slot ([Serialization](serialization.md)), and a described field
reports `CUSTOM` and the slot address ([Type descriptions](type_descriptions.md#fields-and-metadata)).

## Limits

- At most `MAX_CUSTOM_ASSET_TYPES` kinds per process.
- The renderer never sees custom kinds; there is no GPU mirror for them. An owner that needs one mirrors the record itself,
  as the audio add-on does for its clips.
- Built-in kinds keep their typed pools and loaders.

## See also

- [Asset store](assets.md) for ids, keys and capacities.
- [Audio](audio.md) for the add-on that uses this mechanism.
- [Serialization](serialization.md) for references to custom kinds.
