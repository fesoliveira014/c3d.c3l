module c3d::anim;

import c3d;

<*
 Entries one scratch holds to share raw track samples between actions within a frame.
*>
const uint POSE_CACHE_CAPACITY = 64; // Per scratch; an entry costs 64 B per model node, so 3.6 KiB and 231 KiB a scratch at 57 nodes

const uint POSE_CACHE_PROBES @private = 4; // Slots one lookup tries; bounds a lookup that misses to four key compares
const uint POSE_CACHE_TRACKS_PER_NODE @private = 3; // Translation, rotation and scale; 8 B a recorded track
const uint POSE_CACHE_FLOATS_PER_NODE @private = 10; // The strides of those tracks, 3 + 4 + 3; 4 B a float

struct PoseCacheTrack @private {
    uint track;
    uint offset;
}

struct PoseCacheEntry @private {
    ClipId clip;
    uint revision;
    uint time_bits;
    uint tracks;
    uint floats;
    bool live;
}

<*
 Raw track samples of clips at exact times, shared by the actions of one scratch.
 An entry records tracks in ascending order; every recorded value is what sample_track returns for it.
*>
struct PoseCache {
    PoseCacheEntry[] entries;
    PoseCacheTrack[] tracks;
    float[] samples;
    uint track_capacity;
    uint float_capacity;
    uint generation;
    <* Actions that consulted the cache. *>
    ulong lookups;
    <* Actions that found samples recorded by an earlier action. *>
    ulong hits;
}

struct PoseCacheWalk @private {
    PoseCacheEntry* entry;
    PoseCacheTrack[] records;
    float[] values;
    uint next;
}

fn PoseCache*? create_pose_cache(
    Allocator allocator,
    usz node_count,
    float[][] base_morph_weights,
) @private {
    usz morph_floats;
    foreach (base : base_morph_weights) morph_floats += base.len;

    PoseCache* cache = alloc::new_try(allocator, PoseCache) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_pose_cache(allocator, cache);

    cache.track_capacity = (uint)(node_count * POSE_CACHE_TRACKS_PER_NODE + base_morph_weights.len);
    cache.float_capacity = (uint)(node_count * POSE_CACHE_FLOATS_PER_NODE + morph_floats);
    cache.entries = alloc::new_array_try(allocator, PoseCacheEntry, POSE_CACHE_CAPACITY) ?? c3d::CAPACITY_EXCEEDED~!;
    cache.tracks = alloc::new_array_try(allocator, PoseCacheTrack, (sz)POSE_CACHE_CAPACITY * cache.track_capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    cache.samples = alloc::new_array_try(allocator, float, (sz)POSE_CACHE_CAPACITY * cache.float_capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;

    return cache;
}

fn void destroy_pose_cache(Allocator allocator, PoseCache* cache) @private {
    alloc::free(allocator, cache.entries.ptr);
    alloc::free(allocator, cache.tracks.ptr);
    alloc::free(allocator, cache.samples.ptr);
    alloc::free(allocator, cache);
}

<*
 Empty the table when the crowd has advanced since the scratch last sampled.
 @param generation : "The crowd's sample generation."
*>
fn void PoseCache.begin_generation(&self, uint generation) {
    if (self.generation == generation) return;

    self.entries[..] = (PoseCacheEntry){};
    self.generation = generation;
}

// The first sighting of a key only claims its slot, so a frame without repeats records nothing.
// A null cache or a full probe window leaves the walk without an entry; the action then samples uncached.
fn PoseCacheWalk begin_pose_cache_walk(
    PoseCache* cache,
    ClipId clip,
    uint revision,
    float time,
) @private @inline {
    PoseCacheWalk walk;
    if (!cache) return walk;

    cache.lookups++;
    uint time_bits = bitcast(time, uint);
    uint mixed = time_bits ^ (clip.index * 0x9E3779B1) ^ (clip.generation * 0xC2B2AE35) ^ (revision * 0x85EBCA6B);
    mixed ^= mixed >> 16;
    mixed *= 0x85EBCA6B;
    mixed ^= mixed >> 13;
    mixed *= 0xC2B2AE35;
    mixed ^= mixed >> 16;

    for (uint probe = 0; probe < POSE_CACHE_PROBES; probe++) {
        uint index = (mixed + probe) % POSE_CACHE_CAPACITY;
        PoseCacheEntry* entry = &cache.entries[index];
        if (!entry.live) {
            *entry = { .clip = clip, .revision = revision, .time_bits = time_bits, .live = true };
            break;
        }
        if (entry.time_bits != time_bits || entry.revision != revision || !c3d::same_id(entry.clip, clip)) continue;

        cache.hits += entry.tracks ? 1 : 0;
        walk.entry = entry;
        walk.records = cache.tracks[(usz)index * cache.track_capacity:cache.track_capacity];
        walk.values = cache.samples[(usz)index * cache.float_capacity:cache.float_capacity];
        break;
    }

    return walk;
}

// Tracks arrive in ascending order, so a merge against the entry's records serves, skips or appends each one.
fn void PoseCacheWalk.sample(
    &self,
    Track* track,
    uint track_index,
    float time,
    uint* cursor,
    float[] out,
) @inline {
    PoseCacheEntry* entry = self.entry;
    while (self.next < entry.tracks && self.records[self.next].track < track_index) self.next++;

    if (self.next < entry.tracks && self.records[self.next].track == track_index) {
        float[] source = self.values[self.records[self.next].offset:out.len];
        foreach (index, &value : out) *value = source[index];
        self.next++;
        return;
    }

    sample_track(
        track: track,
        time: time,
        cursor: cursor,
        out: out,
    );
    if (self.next < entry.tracks) return;
    if (entry.tracks == self.records.len || entry.floats + out.len > self.values.len) return;

    self.records[entry.tracks] = { .track = track_index, .offset = entry.floats };
    float[] target = self.values[entry.floats:out.len];
    foreach (index, value : out) target[index] = value;
    entry.floats += (uint)out.len;
    entry.tracks++;
    self.next = entry.tracks;
}
