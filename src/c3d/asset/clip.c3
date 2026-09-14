module c3d::asset;

import c3d;
import c3d::anim;
import c3d::pool;

<*
 Animation clip record.
*>
struct ClipAsset {
    AssetHeader   header;
    AnimationClip data;
}

<*
 Pool of clip records addressed by ClipId.
*>
alias ClipPool = Pool{ClipAsset, ClipId};

<*
 Add a clip whose arrays the store takes over on success.
 @param [&in] clip : "Arrays and the name were allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ClipId? AssetStore.add_clip_owned(&self, AnimationClip* clip, String key = "") {
    check_key(self, key)!;
    ClipId id = self.clips.add({})!;
    *self.clips.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data   = *clip,
    };
    register_key(self, key, typed_ref(AssetKind.CLIP, id));
    return id;
}

<*
 Record of the clip; a borrow into the pool.
 @require self.clips.is_live(clip)
*>
fn ClipAsset* AssetStore.clip(&self, ClipId clip) {
    return self.clips.get(clip);
}

<*
 Free the record and make its id stale.
 @require self.clips.is_live(clip)
*>
fn void AssetStore.remove_clip(&self, ClipId clip) {
    ClipAsset* record = self.clips.get(clip);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_clip(self.allocator, &record.data);
    *record = {};
    self.clips.remove(clip);
}

<*
 Clip id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn ClipId? AssetStore.find_clip(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.CLIP) return c3d::INVALID_ARGUMENT~;
    return (ClipId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Free every track array and the name of a clip allocated with the allocator.
 @param [&inout] clip : "Left zeroed."
*>
fn void free_clip(Allocator allocator, AnimationClip* clip) {
    foreach (&track : clip.tracks) {
        alloc::free(allocator, track.times.ptr);
        alloc::free(allocator, track.values.ptr);
    }
    alloc::free(allocator, clip.tracks.ptr);
    alloc::free(allocator, clip.targets.ptr);
    alloc::free(allocator, clip.name.ptr);
    *clip = {};
}
