module c3d::test::crowd_bench;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

alias WeightSpan = float[];

const uint WARMUPS = 30;
const uint SAMPLES = 120;
const uint REPETITIONS = 3;
const uint SCRIPT_SEED = 0x03512026;
const float FIXED_DT = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND = 1_000_000;
const uint[3] POPULATIONS = { 64, 512, 4096 };
const uint ACTION_CAPACITY = 4;
const uint EVENT_CAPACITY = anim::DEFAULT_CROWD_EVENT_CAPACITY;
const uint SCENE_CAPACITY = 64;
const float PLACEMENT_SPACING = 3;
const String HEX_DIGITS = "0123456789abcdef";

const Corpus[2] CORPUS = {
    {
        .label = "quaternius",
        .relative_path = "examples/assets/quaternius/AnimationLibrary_Godot.glb",
        .sha256 = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c",
        .bytes = 18_807_792,
        .bounds = { .min = { -4, -2, -4 }, .max = { 4, 5, 4 } },
        .quaternius = true,
    },
    {
        .label = "morph",
        .relative_path = "examples/assets/gltf/AnimatedMorphCube.glb",
        .sha256 = "214ee56160a50dbf22543a1d66dbf860986e87f0efac3d89feac1359d0e6aeab",
        .bytes = 6_752,
        .bounds = { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
    },
};

enum Script {
    BASE,
    LAYERED4,
    SPACE4,
}

struct Corpus {
    String label;
    String relative_path;
    String sha256;
    usz bytes;
    Aabb bounds;
    bool quaternius;
}

struct CounterAllocator (Allocator) {
    TrackingAllocator tracker;
    ulong acquire_calls;
    ulong resize_calls;
    ulong release_calls;
    ulong requested_bytes;
}

struct AllocationCounters {
    ulong acquire_calls;
    ulong resize_calls;
    ulong release_calls;
    ulong requested_bytes;
}

struct Storage {
    ulong fixed_playback;
    ulong actions;
    ulong masks;
    ulong order;
    ulong spaces;
    ulong cursors;
    ulong references;
    ulong crowd_events;
    ulong event_scratch;
    ulong fixed_per_instance;
    ulong fixed_global;
    ulong formula_total;
    ulong outputs;
    ulong parts;
    ulong scene_overhead;
    ulong total;
    ulong high_water;
}

struct Sample {
    ulong evaluate_ns;
    ulong publish_ns;
    AllocationCounters allocations;
    uint events;
    uint dropped;
}

struct Outputs {
    File raw;
    File summary;
    File storage;
    File failures;
    File metadata;
}

fn void*? CounterAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquire_calls++;
    self.requested_bytes += (ulong)size;
    return self.tracker.acquire(size, init_type, alignment);
}

fn void*? CounterAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resize_calls++;
    self.requested_bytes += (ulong)size;
    return self.tracker.resize(pointer, size, alignment);
}

fn void CounterAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.release_calls++;
    self.tracker.release(pointer, aligned);
}

fn AllocationCounters CounterAllocator.snapshot(&self) {
    return {
        .acquire_calls = self.acquire_calls,
        .resize_calls = self.resize_calls,
        .release_calls = self.release_calls,
        .requested_bytes = self.requested_bytes,
    };
}

fn AllocationCounters difference(AllocationCounters after, AllocationCounters before) {
    return {
        .acquire_calls = after.acquire_calls - before.acquire_calls,
        .resize_calls = after.resize_calls - before.resize_calls,
        .release_calls = after.release_calls - before.release_calls,
        .requested_bytes = after.requested_bytes - before.requested_bytes,
    };
}

fn String script_name(Script script) {
    switch (script) {
        case BASE: return "base";
        case LAYERED4: return "layered4";
        case SPACE4: return "space4";
    }
}

fn void? csv_string(File* output, String value, bool last = false) {
    io::write_all(output, (char[])value)!;
    output.write_byte(last ? '\n' : ',')!;
}

fn void? csv_uint(File* output, ulong value, bool last = false) {
    char[32] text;
    csv_string(output, (String)io::bprintf(text[..], "%d", value)!, last)!;
}

fn void? csv_float(File* output, double value, bool last = false) {
    char[64] text;
    csv_string(output, (String)io::bprintf(text[..], "%.9f", value)!, last)!;
}

fn String? joined_path(String root, String relative) {
    return (String)path::tnew(root)!.tappend(relative)!;
}

fn void close_outputs(Outputs* outputs) {
    (void)outputs.raw.close();
    (void)outputs.summary.close();
    (void)outputs.storage.close();
    (void)outputs.failures.close();
    (void)outputs.metadata.close();
}

fn void? create_outputs(String directory, Outputs* outputs) {
    defer catch close_outputs(outputs);
    outputs.raw = file::open(joined_path(directory, "cpu-raw.csv")!, "wb")!;
    outputs.summary = file::open(joined_path(directory, "cpu-summary.csv")!, "wb")!;
    outputs.storage = file::open(joined_path(directory, "cpu-storage.csv")!, "wb")!;
    outputs.failures = file::open(joined_path(directory, "cpu-failures.csv")!, "wb")!;
    outputs.metadata = file::open(joined_path(directory, "cpu-metadata.csv")!, "wb")!;
    io::fprintn(
        out: &outputs.raw,
        x: "fixture,script,configured,live,repetition,sample,script_frame,submission_frame,seed,dt,evaluate_ms,publish_ms,total_ms,acquire_calls,resize_calls,release_calls,requested_bytes,events,dropped",
    )!;
    io::fprintn(
        out: &outputs.summary,
        x: "fixture,script,configured,live,repetition,metric,samples,median_ms,p95_ms,setup_acquire_calls,setup_resize_calls,setup_requested_bytes,play_acquire_calls,play_resize_calls,play_requested_bytes",
    )!;
    io::fprintn(
        out: &outputs.storage,
        x: "fixture,script,configured,live,repetition,category,bytes,nodes,meshes,joints,logical_weights,action_capacity,event_capacity",
    )!;
    io::fprintn(
        out: &outputs.failures,
        x: "fixture,script,configured,live,repetition,fault,seed,dt,action_capacity,event_capacity,scene_capacity",
    )!;
    io::fprintn(
        out: &outputs.metadata,
        x: "key,value",
    )!;
}

fn void? metadata(Outputs* outputs, String key, String value) {
    csv_string(&outputs.metadata, key)!;
    csv_string(&outputs.metadata, value, true)!;
}

fn void? metadata_uint(Outputs* outputs, String key, ulong value) {
    csv_string(&outputs.metadata, key)!;
    csv_uint(&outputs.metadata, value, true)!;
}

fn void? verify_input(char[] bytes, Corpus corpus) {
    if (bytes.len != corpus.bytes) return c3d::INVALID_ARGUMENT~;
    char[32] digest = sha256::hash(bytes);
    char[64] hexadecimal;
    foreach (index, value : digest) {
        hexadecimal[index * 2] = HEX_DIGITS[value >> 4];
        hexadecimal[index * 2 + 1] = HEX_DIGITS[value & 15];
    }
    if ((String)hexadecimal[..] != corpus.sha256) return c3d::INVALID_ARGUMENT~;
}

fn ClipId? clip_named(AssetStore* assets, ModelTemplate* template, String name) {
    foreach (clip : template.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn float initial_fraction(uint index) {
    uint state = SCRIPT_SEED ^ (index + 1);
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return (float)(state & 0xffff) / 65536;
}

fn void? configure_script(
    AssetStore* assets,
    AnimatedCrowd* crowd,
    Script script,
    ClipId base_clip,
    ClipId moving_clip,
    ClipId idle_clip,
) {
    if (script == BASE) return;
    @pool() {
        bool[] members = alloc::new_array(tmem, bool, crowd.playback.base_pose.len);
        foreach (index, &member : members) *member = (index & 1) != 0;
        JointMask mask = { .nodes = members };
        for (uint index = 0; index < crowd.count; index++) {
            CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(index)!)!;
            player.base_action()!.weight = 0.8f;
            if (script == LAYERED4) {
                AnimationActionId overlay = player.play(assets, moving_clip, { .layer = 1, .mask = &mask })!;
                Action* action = player.action(overlay);
                action.speed = 0.75f;
                action.weight = 0.25f;
                action.fade_target = 0.65f;
                action.fade_rate = 0.2f;
                AnimationActionId additive = player.play(assets, moving_clip, {
                    .layer = 2, .additive = true, .mask = &mask,
                })!;
                player.action(additive).speed = -0.5f;
                player.action(additive).weight = 0.25f;
                AnimationActionId upper = player.play(assets, idle_clip, { .layer = 3 })!;
                player.action(upper).speed = 1.25f;
                player.action(upper).weight = 0.4f;
            } else {
                ClipId[2] clips = { base_clip, moving_clip };
                float[2] positions = { 0, 1 };
                BlendSpace1D* space = player.add_blend_space(
                    assets: assets,
                    clips: clips[..],
                    positions: positions[..],
                    desc: { .layer = 1, .mask = &mask },
                )!;
                space.parameter = 0.5f;
                space.weight = 0.75f;
                space.speed = 0.5f;
                AnimationActionId additive = player.play(assets, idle_clip, {
                    .layer = 2, .additive = true, .mask = &mask,
                })!;
                player.action(additive).weight = 0.25f;
            }
        }
    };
}

fn void script_controls(AnimatedCrowd* crowd, Script script, uint frame) {
    if (script == BASE) return;
    for (uint index = 0; index < crowd.count; index++) {
        CrowdPlaybackSlot* slot = &crowd.playback.slots[index];
        if (script == LAYERED4) {
            if (frame % 60 == 0) {
                Action* overlay = slot.actions.get(slot.order[1]);
                overlay.fade_target = frame % 120 == 0 ? 0.65f : 0.25f;
                overlay.fade_rate = 0.2f;
            }
        } else {
            BlendSpace1D* space = &slot.spaces[0];
            uint position = frame % 120;
            space.parameter = (float)(position <= 60 ? position : 120 - position) / 60;
            if (frame % 60 == 0) {
                space.fade_target = frame % 120 == 0 ? 0.75f : 0.25f;
                space.fade_rate = 0.2f;
            }
        }
    }
}

fn ulong? tracked_bytes(TrackingAllocator* tracker, void* pointer, usz expected) {
    if (!pointer) {
        if (expected) return c3d::INVALID_ARGUMENT~;
        return 0;
    }
    Allocation allocation = tracker.map[(uptr)pointer]!;
    if ((usz)allocation.size != expected) return c3d::INVALID_ARGUMENT~;
    return (ulong)allocation.size;
}

fn Storage? storage_inventory(CounterAllocator* counter, Scene* scene, AnimatedCrowd* crowd) {
    TrackingAllocator* tracker = &counter.tracker;
    CrowdPlaybackState* state = crowd.playback;
    Storage result;
    result.fixed_playback = tracked_bytes(
        tracker: tracker,
        pointer: state,
        expected: CrowdPlaybackState::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: state.slots.ptr,
        expected: state.slots.len * CrowdPlaybackSlot::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: state.base_pose.ptr,
        expected: state.base_pose.len * Transform::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: state.parents.ptr,
        expected: state.parents.len * int::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: state.mesh_nodes.ptr,
        expected: state.mesh_nodes.len * uint::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: state.base_morph_weights.ptr,
        expected: state.base_morph_weights.len * WeightSpan::size,
    )!;
    foreach (weights : state.base_morph_weights) {
        result.fixed_playback += tracked_bytes(
            tracker: tracker,
            pointer: weights.ptr,
            expected: weights.len * float::size,
        )!;
    }
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: crowd.placements.ptr,
        expected: crowd.placements.len * Transform::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: crowd.seeds.ptr,
        expected: crowd.seeds.len * CrowdPose::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: crowd.start_times.ptr,
        expected: crowd.start_times.len * float::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: crowd.colors.ptr,
        expected: crowd.colors.len * Vec4::size,
    )!;

    foreach (&slot : state.slots) {
        result.actions += tracked_bytes(
            tracker: tracker,
            pointer: slot.actions.items.ptr,
            expected: slot.actions.items.len * Action::size,
        )!;
        result.fixed_playback += tracked_bytes(
            tracker: tracker,
            pointer: slot.actions.generations.ptr,
            expected: slot.actions.generations.len * uint::size,
        )!;
        result.fixed_playback += tracked_bytes(
            tracker: tracker,
            pointer: slot.actions.free.ptr,
            expected: slot.actions.free.len * uint::size,
        )!;
        result.masks += tracked_bytes(
            tracker: tracker,
            pointer: slot.masks.ptr,
            expected: slot.masks.len * bool::size,
        )!;
        result.order += tracked_bytes(
            tracker: tracker,
            pointer: slot.order.ptr,
            expected: slot.order.len * AnimationActionId::size,
        )!;
        result.spaces += tracked_bytes(
            tracker: tracker,
            pointer: slot.spaces.ptr,
            expected: slot.spaces.len * BlendSpace1D::size,
        )!;
        foreach (id : slot.order[:slot.action_count]) {
            Action* action = slot.actions.get(id);
            result.cursors += tracked_bytes(
                tracker: tracker,
                pointer: action.cursors.ptr,
                expected: action.cursors.len * uint::size,
            )!;
            result.references += tracked_bytes(
                tracker: tracker,
                pointer: action.reference.ptr,
                expected: action.reference.len * float::size,
            )!;
        }
    }

    PoseStorage* storage = state.pose_storage;
    PoseDestination destination = storage.destination;
    PoseScratch scratch = storage.scratch;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: storage,
        expected: PoseStorage::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: destination.present.ptr,
        expected: destination.present.len * bool::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: destination.mesh_present.ptr,
        expected: destination.mesh_present.len * bool::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: destination.mesh_indices.ptr,
        expected: destination.mesh_indices.len * uint::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: destination.mesh_widths.ptr,
        expected: destination.mesh_widths.len * uint::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: scratch.channels.ptr,
        expected: scratch.channels.len * ChannelSums::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: scratch.morph_sums.ptr,
        expected: scratch.morph_sums.len * WeightSpan::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: scratch.morph_weights.ptr,
        expected: scratch.morph_weights.len * float::size,
    )!;
    result.fixed_playback += tracked_bytes(
        tracker: tracker,
        pointer: scratch.sample.ptr,
        expected: scratch.sample.len * float::size,
    )!;
    foreach (weights : scratch.morph_sums) {
        result.fixed_playback += tracked_bytes(
            tracker: tracker,
            pointer: weights.ptr,
            expected: weights.len * float::size,
        )!;
    }

    result.crowd_events = tracked_bytes(
        tracker: tracker,
        pointer: state.events.ptr,
        expected: state.events.len * CrowdEvent::size,
    )!;
    result.event_scratch = tracked_bytes(
        tracker: tracker,
        pointer: scratch.event_bookmarks.ptr,
        expected: scratch.event_bookmarks.len * EventBookmark::size,
    )!;
    result.outputs = tracked_bytes(
        tracker: tracker,
        pointer: state.poses.ptr,
        expected: state.poses.len * Transform::size,
    )!;
    result.outputs += tracked_bytes(
        tracker: tracker,
        pointer: state.weight_values.ptr,
        expected: state.weight_values.len * float::size,
    )!;
    result.outputs += tracked_bytes(
        tracker: tracker,
        pointer: state.logical_weights.ptr,
        expected: state.logical_weights.len * WeightSpan::size,
    )!;
    result.outputs += tracked_bytes(
        tracker: tracker,
        pointer: destination.pose.ptr,
        expected: destination.pose.len * Transform::size,
    )!;
    result.outputs += tracked_bytes(
        tracker: tracker,
        pointer: destination.morph_weights.ptr,
        expected: destination.morph_weights.len * WeightSpan::size,
    )!;
    foreach (weights : destination.morph_weights) {
        result.outputs += tracked_bytes(
            tracker: tracker,
            pointer: weights.ptr,
            expected: weights.len * float::size,
        )!;
    }
    result.outputs += tracked_bytes(
        tracker: tracker,
        pointer: crowd.palettes.ptr,
        expected: crowd.palettes.len * Mat4::size,
    )!;
    result.parts = tracked_bytes(
        tracker: tracker,
        pointer: crowd.parts.ptr,
        expected: crowd.parts.len * CrowdPart::size,
    )!;
    result.parts += tracked_bytes(
        tracker: tracker,
        pointer: crowd.scratch_worlds.ptr,
        expected: crowd.scratch_worlds.len * Mat4::size,
    )!;
    foreach (part : crowd.parts) {
        InstancedMesh* batch = scene.world.get(part.batch, InstancedMesh);
        result.parts += tracked_bytes(
            tracker: tracker,
            pointer: batch.transforms.ptr,
            expected: batch.transforms.len * Transform::size,
        )!;
        result.parts += tracked_bytes(
            tracker: tracker,
            pointer: batch.colors.ptr,
            expected: batch.colors.len * Vec4::size,
        )!;
    }
    result.total = (ulong)tracker.usage;
    ulong classified = result.fixed_playback + result.actions + result.masks + result.order + result.spaces
      + result.cursors + result.references + result.crowd_events + result.event_scratch + result.outputs + result.parts;
    if (classified > result.total) return c3d::INVALID_ARGUMENT~;
    result.scene_overhead = result.total - classified;
    usz nodes = state.base_pose.len;
    usz meshes = state.mesh_nodes.len;
    usz weights = crowd.morph_stride;
    usz actions = crowd.actions_per_instance;
    usz sample_width = 4;
    foreach (values : state.base_morph_weights) sample_width = math::max(sample_width, (usz)values.len);
    result.fixed_per_instance = CrowdPlaybackSlot::size
      + actions * (Action::size + 2 * uint::size + AnimationActionId::size + nodes * bool::size)
      + anim::MAX_BLEND_SPACES * BlendSpace1D::size
      + Transform::size + CrowdPose::size + float::size + Vec4::size
      + nodes * Transform::size + weights * float::size + meshes * WeightSpan::size
      + crowd.joint_count * Mat4::size + meshes * (Transform::size + Vec4::size);
    result.fixed_global = CrowdPlaybackState::size
      + nodes * (Transform::size + int::size) + meshes * (uint::size + WeightSpan::size)
      + weights * float::size + PoseStorage::size
      + nodes * (2 * bool::size + uint::size + ChannelSums::size)
      + meshes * (uint::size + WeightSpan::size + float::size)
      + weights * float::size + sample_width * float::size
      + nodes * Transform::size + meshes * WeightSpan::size + weights * float::size
      + meshes * CrowdPart::size + nodes * Mat4::size;
    ulong fixed_observed = result.fixed_playback + result.actions + result.masks + result.order
      + result.spaces + result.outputs + result.parts;
    if (fixed_observed != crowd.placements.len * result.fixed_per_instance + result.fixed_global) {
        return c3d::INVALID_ARGUMENT~;
    }
    result.formula_total = crowd.placements.len * result.fixed_per_instance + result.fixed_global
      + result.crowd_events + result.event_scratch + result.cursors + result.references + result.scene_overhead;
    if (result.formula_total != result.total) return c3d::INVALID_ARGUMENT~;
    result.high_water = (ulong)tracker.max_usage;
    return result;
}

fn void? row_key(
    File* output,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
) {
    csv_string(output, corpus.label)!;
    csv_string(output, script_name(script))!;
    csv_uint(output, live)!;
    csv_uint(output, live)!;
    csv_uint(output, repetition)!;
}

fn void? write_storage(
    Outputs* outputs,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    Storage storage,
    AnimatedCrowd* crowd,
) {
    String[17] categories = {
        "fixed_playback", "actions", "masks", "order", "spaces", "cursors", "references",
        "crowd_events", "event_scratch", "outputs", "parts", "scene_overhead", "total_tracked", "tracked_high_water",
        "fixed_per_instance", "fixed_global", "formula_total",
    };
    ulong[17] values = {
        storage.fixed_playback, storage.actions, storage.masks, storage.order, storage.spaces,
        storage.cursors, storage.references, storage.crowd_events, storage.event_scratch, storage.outputs, storage.parts,
        storage.scene_overhead, storage.total, storage.high_water,
        storage.fixed_per_instance, storage.fixed_global, storage.formula_total,
    };
    foreach (index, category : categories) {
        row_key(
            output: &outputs.storage,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
        )!;
        csv_string(&outputs.storage, category)!;
        csv_uint(&outputs.storage, values[index])!;
        csv_uint(&outputs.storage, crowd.playback.base_pose.len)!;
        csv_uint(&outputs.storage, crowd.parts.len)!;
        csv_uint(&outputs.storage, crowd.joint_count)!;
        csv_uint(&outputs.storage, crowd.morph_stride)!;
        csv_uint(&outputs.storage, ACTION_CAPACITY)!;
        csv_uint(&outputs.storage, EVENT_CAPACITY, true)!;
    }
}

fn void? write_samples(
    Outputs* outputs,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    Sample[] samples,
    AllocationCounters setup,
    AllocationCounters play,
) {
    foreach (index, sample : samples) {
        row_key(
            output: &outputs.raw,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
        )!;
        csv_uint(&outputs.raw, (ulong)index)!;
        csv_uint(&outputs.raw, (ulong)(WARMUPS + index))!;
        csv_string(&outputs.raw, "NA")!;
        csv_uint(&outputs.raw, SCRIPT_SEED)!;
        csv_float(&outputs.raw, FIXED_DT)!;
        csv_float(&outputs.raw, (double)sample.evaluate_ns / NANOSECONDS_PER_MILLISECOND)!;
        csv_float(&outputs.raw, (double)sample.publish_ns / NANOSECONDS_PER_MILLISECOND)!;
        csv_float(&outputs.raw, (double)(sample.evaluate_ns + sample.publish_ns) / NANOSECONDS_PER_MILLISECOND)!;
        csv_uint(&outputs.raw, sample.allocations.acquire_calls)!;
        csv_uint(&outputs.raw, sample.allocations.resize_calls)!;
        csv_uint(&outputs.raw, sample.allocations.release_calls)!;
        csv_uint(&outputs.raw, sample.allocations.requested_bytes)!;
        csv_uint(&outputs.raw, sample.events)!;
        csv_uint(&outputs.raw, sample.dropped, true)!;
    }
    foreach (uint metric : { 0u, 1u, 2u }) {
        ulong[SAMPLES] sorted;
        foreach (index, sample : samples) {
            sorted[index] = metric == 0 ? sample.evaluate_ns
              : (metric == 1 ? sample.publish_ns : sample.evaluate_ns + sample.publish_ns);
        }
        sort::quicksort(sorted[..]);
        row_key(
            output: &outputs.summary,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
        )!;
        csv_string(&outputs.summary, metric == 0 ? "evaluate" : (metric == 1 ? "publish" : "evaluate_publish"))!;
        csv_uint(&outputs.summary, samples.len)!;
        csv_float(&outputs.summary, (double)sorted[(SAMPLES * 50 + 99) / 100 - 1] / NANOSECONDS_PER_MILLISECOND)!;
        csv_float(&outputs.summary, (double)sorted[(SAMPLES * 95 + 99) / 100 - 1] / NANOSECONDS_PER_MILLISECOND)!;
        csv_uint(&outputs.summary, setup.acquire_calls)!;
        csv_uint(&outputs.summary, setup.resize_calls)!;
        csv_uint(&outputs.summary, setup.requested_bytes)!;
        csv_uint(&outputs.summary, play.acquire_calls)!;
        csv_uint(&outputs.summary, play.resize_calls)!;
        csv_uint(&outputs.summary, play.requested_bytes, true)!;
    }
}

fn void? measure_row(
    AssetStore* assets,
    ModelId model_id,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    Outputs* outputs,
) {
    CounterAllocator counter;
    counter.tracker.init(mem);
    defer counter.tracker.free();
    Scene scene = scene::create_scene(&counter, { .max_nodes = SCENE_CAPACITY });
    defer scene::destroy_scene(&scene);
    ModelTemplate* template = &assets.model(model_id).data;
    ClipId base_clip = corpus.quaternius ? clip_named(assets, template, "Walk_Loop")! : template.clips[0];
    ClipId moving_clip = corpus.quaternius ? clip_named(assets, template, "Jog_Fwd_Loop")! : base_clip;
    ClipId idle_clip = corpus.quaternius ? clip_named(assets, template, "Idle_Loop")! : base_clip;
    float duration = assets.clip(base_clip).data.duration;
    @pool() {
        CrowdInstance[] instances = alloc::new_array(tmem, CrowdInstance, live);
        uint columns = (uint)math::ceil(math::sqrt((float)live));
        foreach (uint index, &instance : instances) {
            *instance = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = {
                    .clip = base_clip,
                    .time = initial_fraction(index) * duration,
                    .speed = 1,
                    .loop = true,
                },
                .color = { 1, 1, 1, 1 },
            };
            instance.placement.position = {
                (float)(index % columns) * PLACEMENT_SPACING,
                0,
                -(float)(index / columns) * PLACEMENT_SPACING,
            };
        }
        AllocationCounters setup_started = counter.snapshot();
        Node* root = model::add_crowd(
            assets: assets,
            scene: &scene,
            model: model_id,
            capacity: live,
            pose_bounds: corpus.bounds,
            instances: instances,
            name: "crowd_bench",
            trace: false,
            actions_per_instance: ACTION_CAPACITY,
            event_capacity: EVENT_CAPACITY,
        )!;
        AnimatedCrowd* crowd = scene.get(root, AnimatedCrowd);
        AllocationCounters setup = difference(counter.snapshot(), setup_started);
        AllocationCounters play_started = counter.snapshot();
        configure_script(
            assets: assets,
            crowd: crowd,
            script: script,
            base_clip: base_clip,
            moving_clip: moving_clip,
            idle_clip: idle_clip,
        )!;
        AllocationCounters play = difference(counter.snapshot(), play_started);
        foreach (slot : crowd.playback.slots[:crowd.count]) {
            if (slot.action_count != (script == BASE ? 1u : 4u)) return c3d::INVALID_ARGUMENT~;
        }
        Storage storage = storage_inventory(&counter, &scene, crowd)!;
        Sample[SAMPLES] samples;
        for (uint frame = 0; frame < WARMUPS + SAMPLES; frame++) {
            script_controls(crowd, script, frame);
            AllocationCounters started = counter.snapshot();
            time::Clock evaluated = clock::now();
            crowd.playback.update(assets, FIXED_DT);
            ulong evaluate_ns = (ulong)evaluated.to_now();
            time::Clock published = clock::now();
            anim::publish_crowd_pose(assets, &scene, crowd);
            ulong publish_ns = (ulong)published.to_now();
            if (frame >= WARMUPS) {
                samples[frame - WARMUPS] = {
                    .evaluate_ns = evaluate_ns,
                    .publish_ns = publish_ns,
                    .allocations = difference(counter.snapshot(), started),
                    .events = crowd.playback.event_count,
                    .dropped = crowd.playback.events_dropped,
                };
            }
        }
        write_storage(
            outputs: outputs,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            storage: storage,
            crowd: crowd,
        )!;
        write_samples(
            outputs: outputs,
            corpus: corpus,
            script: script,
            live: live,
            repetition: repetition,
            samples: samples[..],
            setup: setup,
            play: play,
        )!;
    };
}

fn void? write_failure(
    Outputs* outputs,
    Corpus corpus,
    Script script,
    uint live,
    uint repetition,
    fault excuse,
) {
    row_key(
        output: &outputs.failures,
        corpus: corpus,
        script: script,
        live: live,
        repetition: repetition,
    )!;
    char[128] text;
    csv_string(&outputs.failures, (String)io::bprintf(text[..], "%s", excuse)!)!;
    csv_uint(&outputs.failures, SCRIPT_SEED)!;
    csv_float(&outputs.failures, FIXED_DT)!;
    csv_uint(&outputs.failures, ACTION_CAPACITY)!;
    csv_uint(&outputs.failures, EVENT_CAPACITY)!;
    csv_uint(&outputs.failures, SCENE_CAPACITY, true)!;
}

fn void? run(String[] args) {
    if (args.len < 2 || args.len > 6) return c3d::INVALID_ARGUMENT~;
    @pool() {
        String repository = args.len > 2 ? args[2] : ".";
        uint selected_population = args.len > 3 ? args[3].to_uint()! : 0;
        if (selected_population && selected_population != 64 && selected_population != 512
          && selected_population != 4096) return c3d::INVALID_ARGUMENT~;
        String selected_fixture = args.len > 4 ? args[4] : "all";
        String selected_script = args.len > 5 ? args[5] : "all";
        if (selected_fixture != "all" && selected_fixture != "quaternius" && selected_fixture != "morph") {
            return c3d::INVALID_ARGUMENT~;
        }
        if (selected_script != "all" && selected_script != "base" && selected_script != "layered4"
          && selected_script != "space4") return c3d::INVALID_ARGUMENT~;
        Outputs outputs;
        create_outputs(args[1], &outputs)!;
        defer close_outputs(&outputs);
        metadata(&outputs, "domain", "cpu_only_no_native_submission")!;
        metadata(&outputs, "compiler", "C3_0.8.3")!;
        char[64] text;
        metadata(&outputs, "compiler_optimization", (String)io::bprintf(text[..], "%s", env::COMPILER_OPT_LEVEL)!)!;
        metadata(&outputs, "compiler_safe", (String)io::bprintf(text[..], "%s", env::COMPILER_SAFE_MODE)!)!;
        metadata(&outputs, "percentiles", "nearest_rank_per_repetition")!;
        metadata(&outputs, "timed_scope", "shared_evaluate_and_publish_separate_controls_io_load_setup_excluded")!;
        metadata(
            outputs: &outputs,
            key: "tracking_scope",
            value: "scene_and_crowd_requested_bytes_excludes_tracker_map_backtraces_assets_process_driver",
        )!;
        metadata(&outputs, "native_measurements", "unmeasured_upload_history_two_view_cull_gpu_trace")!;
        metadata(&outputs, "trace", "off")!;
        metadata(&outputs, "repository", repository)!;
        metadata_uint(&outputs, "seed", SCRIPT_SEED)!;
        metadata_uint(&outputs, "dt_bits", bitcast(FIXED_DT, uint))!;
        metadata_uint(&outputs, "warmups", WARMUPS)!;
        metadata_uint(&outputs, "samples", SAMPLES)!;
        metadata_uint(&outputs, "repetitions", REPETITIONS)!;
        metadata_uint(&outputs, "action_capacity", ACTION_CAPACITY)!;
        metadata_uint(&outputs, "event_capacity", EVENT_CAPACITY)!;
        metadata_uint(&outputs, "scene_capacity", SCENE_CAPACITY)!;
        metadata_uint(&outputs, "Action_size", Action::size)!;
        metadata_uint(&outputs, "CrowdPlaybackSlot_size", CrowdPlaybackSlot::size)!;
        metadata_uint(&outputs, "CrowdEvent_size", CrowdEvent::size)!;
        metadata_uint(&outputs, "EventBookmark_size", EventBookmark::size)!;
        metadata_uint(&outputs, "Transform_size", Transform::size)!;
        metadata_uint(&outputs, "Mat4_size", Mat4::size)!;
        metadata_uint(&outputs, "BlendSpace1D_size", BlendSpace1D::size)!;
        metadata(&outputs, "script_version", "1")!;
        metadata(&outputs, "placement", "ceil_sqrt_grid_spacing3_positive_x_negative_z_identity_scale_rotation")!;
        bool failed;
        foreach (corpus : CORPUS) {
            if (selected_fixture != "all" && selected_fixture != corpus.label) continue;
            char[] bytes = file::load(mem, joined_path(repository, corpus.relative_path)!)!;
            defer alloc::free(mem, bytes.ptr);
            verify_input(bytes, corpus)!;
            metadata(&outputs, corpus.label, corpus.sha256)!;
            AssetStore assets = asset::create_asset_store(mem, {
                .max_geometries = 16, .max_textures = 32, .max_materials = 16, .max_samplers = 16,
                .max_models = 1, .max_skeletons = 8, .max_clips = 256,
            });
            defer asset::destroy_asset_store(&assets);
            ModelId model_id = gltf::load_model_memory(
                assets: &assets,
                bytes: bytes,
                base_dir: "",
                key: corpus.relative_path,
            )!;
            foreach (live : POPULATIONS) {
                if (selected_population && selected_population != live) continue;
                foreach (Script script : { BASE, LAYERED4, SPACE4 }) {
                    if (selected_script != "all" && selected_script != script_name(script)) continue;
                    for (uint repetition = 0; repetition < REPETITIONS; repetition++) {
                        if (catch excuse = measure_row(
                            assets: &assets,
                            model_id: model_id,
                            corpus: corpus,
                            script: script,
                            live: live,
                            repetition: repetition,
                            outputs: &outputs,
                        )) {
                            write_failure(
                                outputs: &outputs,
                                corpus: corpus,
                                script: script,
                                live: live,
                                repetition: repetition,
                                excuse: excuse,
                            )!;
                            failed = true;
                        }
                    }
                }
            }
        }
        if (failed) return c3d::INVALID_ARGUMENT~;
    };
}

fn int main(String[] args) @feat(!C3D_CROWD_BENCH_NATIVE) {
    if (catch excuse = run(args)) {
        io::eprintfn("crowd_bench: %s", excuse);
        io::eprintn("usage: crowd_bench OUTPUT_DIRECTORY [REPOSITORY_ROOT] [0|64|512|4096] "
          "[all|quaternius|morph] [all|base|layered4|space4]");
        return 1;
    }
    return 0;
}
