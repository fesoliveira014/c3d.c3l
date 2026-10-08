module c3d::asset;

import c3d;
import c3d::anim;
import c3d::pool;
import std::math;

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
    check_clip_events(clip)!;
    ClipId id = self.clips.add({})!;
    *self.clips.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data   = *clip,
    };
    register_key(self, key, typed_ref(AssetKind.CLIP, id));
    return id;
}

<*
 Replace the clip, taking its arrays on success.
 @param [&in] source : "Arrays and the name were allocated with the store allocator."
 @return? c3d::INVALID_ARGUMENT, c3d::INCOMPATIBLE_STRUCTURE
 @require self.clips.is_live(clip)
*>
fn void? AssetStore.replace_clip_owned(&self, ClipId clip, AnimationClip* source) {
    ClipAsset* record = self.clips.get(clip);
    check_clip_events(source)!;
    check_clip_structure(&record.data, source)!;
    free_clip(self.allocator, &record.data);
    record.data = *source;
    mark_replaced(&record.header);
    return;
}

<*
 Record of the clip; a borrow into the pool.
 @require self.clips.is_live(clip)
*>
fn ClipAsset* AssetStore.clip(&self, ClipId clip) {
    return self.clips.get(clip);
}

<*
 Replace authored events with a stable time-sorted copy.
 @param events : "Copied before replacing the previous table."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? AssetStore.set_clip_events(&self, ClipId clip, ClipEvent[] events) {
    ClipAsset* record = self.clips.try_get(clip)!;
    validate_clip_events(record.data.duration, events)!;
    ClipEvent[] copy = alloc::new_array(self.allocator, ClipEvent, events.len);
    copy[..] = events[..];

    for (usz index = 1; index < copy.len; index++) {
        ClipEvent value = copy[index];
        usz position = index;
        while (position && copy[position - 1].time > value.time) {
            copy[position] = copy[position - 1];
            position--;
        }
        copy[position] = value;
    }

    alloc::free(self.allocator, record.data.events.ptr);
    record.data.events = copy;
    record.header.revision++;
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
    alloc::free(allocator, clip.events.ptr);
    alloc::free(allocator, clip.name.ptr);
    *clip = {};
}

fn void? validate_clip_events(float duration, ClipEvent[] events) @private {
    foreach (event : events) {
        if (!math::is_finite(event.time) || !math::is_finite(duration)
            || event.time < 0 || event.time > duration) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_clip_events(AnimationClip* clip) @private {
    validate_clip_events(clip.duration, clip.events)!;
    for (usz index = 1; index < clip.events.len; index++) {
        if (clip.events[index].time < clip.events[index - 1].time) return c3d::INVALID_ARGUMENT~;
    }
    return;
}

fn void? check_clip_structure(AnimationClip* current, AnimationClip* next) @private {
    if (current.targets.len != next.targets.len
        || current.tracks.len != next.tracks.len
        || (current.duration > 0) != (next.duration > 0)) {
        return c3d::INCOMPATIBLE_STRUCTURE~;
    }
    foreach (index, target : next.targets) {
        if (current.targets[index] != target) return c3d::INCOMPATIBLE_STRUCTURE~;
    }
    foreach (index, &track : next.tracks) {
        Track* existing = &current.tracks[index];
        if (existing.target != track.target
            || existing.path != track.path
            || track_stride(existing) != track_stride(track)) {
            return c3d::INCOMPATIBLE_STRUCTURE~;
        }
    }
    return;
}

// Track.stride divides a morph track's values by its key count.
fn uint track_stride(Track* track) @local {
    return track.times.len ? track.stride() : 0;
}
