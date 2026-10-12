module job_bench;

import std::io;
import std::io::path;
import std::math;
import std::time;
import std::time::clock;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::job;
import c3d::maths;
import c3d::model;
import c3d::scene;

const String CROWD_CHARACTER @local = "../../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String[6] CROWD_CLIP_NAMES @local = {
    "Walk_Loop", "Jog_Fwd_Loop", "Idle_Loop", "Sprint_Loop", "Walk_Formal_Loop", "Dance_Loop",
};
const float CROWD_SPACING @local = 1.5f;
const float CROWD_POSE_MARGIN @local = 1; // metres around the rest bounds; limbs of the chosen clips stay inside
const float CROWD_SPEED_MIN @local = 0.8f;
const float CROWD_SPEED_MAX @local = 1.2f;
const uint CROWD_SEED @local = 20261011;
const uint CROWD_BATCH @local = 16; // about 30 us of sampling a range, so scheduling stays a small share
const uint CROWD_WARMUP_FRAMES @local = 3; // wakes the workers and faults the crowd's pages before timing
const uint CROWD_TIMED_FRAMES @local = 15; // the median of fifteen timed frames
const uint CROWD_FRAMES @local = CROWD_WARMUP_FRAMES + CROWD_TIMED_FRAMES;
const float CROWD_STEP_SECONDS @local = 1.0f / 60;
const uint CROWD_SCENE_NODES @local = 64; // the crowd node and one batch per template mesh
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;
const ulong DIGEST_OFFSET @local = 0xcbf29ce484222325;
const ulong DIGEST_PRIME @local = 0x100000001b3;

enum CrowdPath @local {
    UPDATE,
    POOL,
}

struct CrowdRandom @local {
    uint state;
}

struct CrowdSetup @local {
    AssetStore* assets;
    ModelId model;
    ClipId[CROWD_CLIP_NAMES.len] clips;
    Aabb pose_bounds;
    uint count;
}

struct CrowdTimes @local {
    double advance_ms;
    double sample_ms;
    double publish_ms;
    double frame_ms;
    uint ranges;
}

struct SampleRun @local {
    CrowdPlaybackState* state;
    AssetStore* assets;
    PoseScratch[] scratches;
}

struct Digest @local {
    ulong state;
}

fn float CrowdRandom.next(&self) {
    self.state = self.state * 1664525 + 1013904223;
    return (float)(self.state >> 8) / (float)(1 << 24);
}

fn void Digest.add(&self, uint bits) {
    self.state = (self.state ^ bits) * DIGEST_PRIME;
}

fn void Digest.add_float(&self, float value) {
    self.add(bitcast(value, uint));
}

fn void sample_crowd_range(void* data, uint first, uint count) @local {
    SampleRun* run = data;
    run.state.sample_range(
        assets: run.assets,
        first: first,
        count: count,
        scratch: &run.scratches[first / CROWD_BATCH],
    );
}

fn ulong crowd_digest(CrowdPlaybackState* state) @local {
    Digest digest = { .state = DIGEST_OFFSET };

    foreach (pose : state.poses[:(usz)state.count * state.base_pose.len]) {
        digest.add_float(pose.position.x);
        digest.add_float(pose.position.y);
        digest.add_float(pose.position.z);
        for (uint lane = 0; lane < 4; lane++) digest.add_float(pose.rotation.v[lane]);
        digest.add_float(pose.scale.x);
        digest.add_float(pose.scale.y);
        digest.add_float(pose.scale.z);
    }
    foreach (weight : state.weight_values) digest.add_float(weight);

    for (uint index = 0; index < state.count; index++) {
        RootMotionDelta motion = state.slots[index].root_motion;
        digest.add_float(motion.translation.x);
        digest.add_float(motion.translation.y);
        digest.add_float(motion.translation.z);
        for (uint lane = 0; lane < 4; lane++) digest.add_float(motion.rotation.v[lane]);
    }

    digest.add(state.event_count);
    digest.add(state.events_dropped);
    foreach (&entry : state.events[:state.event_count]) {
        digest.add(entry.instance.index);
        digest.add(entry.instance.generation);
        digest.add(entry.event.action.index);
        digest.add(entry.event.action.generation);
        digest.add(entry.event.id);
        digest.add_float(entry.event.time);
    }

    return digest.state;
}

fn String crowd_asset_path() @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(CROWD_CHARACTER)!!;
}

fn ClipId? crowd_clip_named(AssetStore* assets, ModelTemplate* template, String name) @local {
    foreach (clip : template.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Aabb crowd_rest_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Aabb bounds = assets.geometry(template.meshes[0].geometry).data.bounds;
    foreach (&mesh : template.meshes) bounds = maths::aabb_merge(bounds, assets.geometry(mesh.geometry).data.bounds);
    Vec3 margin = { CROWD_POSE_MARGIN, CROWD_POSE_MARGIN, CROWD_POSE_MARGIN };
    return { .min = bounds.min - margin, .max = bounds.max + margin };
}

fn Node*? add_bench_crowd(CrowdSetup* setup, Scene* scene) @local {
    CrowdInstance[] instances = alloc::new_array(mem, CrowdInstance, setup.count);
    defer free(instances);

    CrowdRandom random = { .state = CROWD_SEED };
    uint columns = (uint)math::ceil(math::sqrt((float)setup.count));
    foreach (uint index, &instance : instances) {
        ClipId clip = setup.clips[index % CROWD_CLIP_NAMES.len];
        float duration = setup.assets.clip(clip).data.duration;
        *instance = {
            .placement = {
                .position = { (float)(index % columns) * CROWD_SPACING, 0, (float)(index / columns) * CROWD_SPACING },
                .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, random.next() * (float)math::PI * 2),
                .scale = { 1, 1, 1 },
            },
            .pose = {
                .clip = clip,
                .time = random.next() * duration,
                .speed = CROWD_SPEED_MIN + (CROWD_SPEED_MAX - CROWD_SPEED_MIN) * random.next(),
                .loop = true,
            },
            .color = { 1, 1, 1, 1 },
        };
    }

    return model::add_crowd(
        assets: setup.assets,
        scene: scene,
        model: setup.model,
        capacity: setup.count,
        pose_bounds: setup.pose_bounds,
        instances: instances,
        name: "crowd",
    );
}

fn double crowd_milliseconds(time::Clock started) @local {
    return (double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND;
}

fn void? time_crowd(
    CrowdSetup* setup,
    CrowdPath mode,
    uint workers,
    ulong[] digests,
    CrowdTimes* times,
) @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = CROWD_SCENE_NODES });
    defer scene::destroy_scene(&scene);

    AnimatedCrowd* crowd = scene.get(add_bench_crowd(setup, &scene)!, AnimatedCrowd);
    CrowdPlaybackState* state = crowd.playback;

    JobPool pool = create_bench_pool(workers);
    defer job::destroy_job_pool(&pool);

    uint ranges = (setup.count + CROWD_BATCH - 1) / CROWD_BATCH;
    PoseScratch[] scratches = alloc::new_array(mem, PoseScratch, ranges);
    defer free(scratches);
    foreach (&scratch : scratches) *scratch = anim::create_crowd_pose_scratch(state)!!;
    defer {
        foreach (&scratch : scratches) anim::destroy_crowd_pose_scratch(state, scratch);
    }

    SampleRun run = { .state = state, .assets = setup.assets, .scratches = scratches };

    double[CROWD_TIMED_FRAMES] advance_samples;
    double[CROWD_TIMED_FRAMES] sample_samples;
    double[CROWD_TIMED_FRAMES] publish_samples;
    double[CROWD_TIMED_FRAMES] frame_samples;

    for (uint frame = 0; frame < CROWD_FRAMES; frame++) {
        double advance_ms;
        double sample_ms;
        time::Clock frame_started = clock::now();

        if (mode == CrowdPath.UPDATE) {
            time::Clock started = clock::now();
            state.update(setup.assets, CROWD_STEP_SECONDS);
            sample_ms = crowd_milliseconds(started);
        } else {
            time::Clock started = clock::now();
            state.advance(setup.assets, CROWD_STEP_SECONDS);
            advance_ms = crowd_milliseconds(started);

            started = clock::now();
            pool.wait(pool.run(
                range: &sample_crowd_range,
                data:  &run,
                count: setup.count,
                batch: CROWD_BATCH,
            ));
            sample_ms = crowd_milliseconds(started);
        }

        time::Clock publish_started = clock::now();
        anim::publish_crowd_pose(setup.assets, &scene, crowd);
        double publish_ms = crowd_milliseconds(publish_started);
        double frame_ms = crowd_milliseconds(frame_started);

        digests[frame] = crowd_digest(state);
        if (frame < CROWD_WARMUP_FRAMES) continue;

        uint slot = frame - CROWD_WARMUP_FRAMES;
        advance_samples[slot] = advance_ms;
        sample_samples[slot] = sample_ms;
        publish_samples[slot] = publish_ms;
        frame_samples[slot] = frame_ms;
    }

    *times = {
        .advance_ms = median(&advance_samples),
        .sample_ms = median(&sample_samples),
        .publish_ms = median(&publish_samples),
        .frame_ms = median(&frame_samples),
        .ranges = ranges,
    };
}

fn bool? crowd_bench(uint count) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    CrowdSetup setup = { .assets = &assets, .count = count };
    setup.model = gltf::load_model(&assets, crowd_asset_path())!;
    ModelTemplate* template = &assets.model(setup.model).data;
    foreach (index, name : CROWD_CLIP_NAMES) setup.clips[index] = crowd_clip_named(&assets, template, name)!;
    setup.pose_bounds = crowd_rest_bounds(&assets, template);

    io::printfn(
        "# crowd_bench count=%d clips=%d batch=%d warmup_frames=%d timed_frames=%d step_s=%.5f",
        count,
        CROWD_CLIP_NAMES.len,
        CROWD_BATCH,
        CROWD_WARMUP_FRAMES,
        CROWD_TIMED_FRAMES,
        CROWD_STEP_SECONDS,
    );
    io::printn("# crowd,count,path,ranges,advance_ms,sample_ms,publish_ms,frame_ms,sample_speedup,frame_speedup,equal");

    ulong[CROWD_FRAMES] reference;
    CrowdTimes update_times;
    time_crowd(
        setup: &setup,
        mode: CrowdPath.UPDATE,
        workers: 0,
        digests: reference[..],
        times: &update_times,
    )!;
    io::printfn(
        "crowd,%d,update,0,-,%.3f,%.3f,%.3f,-,-,1",
        count,
        update_times.sample_ms,
        update_times.publish_ms,
        update_times.frame_ms,
    );

    CrowdTimes serial_times;
    bool all_equal = true;
    foreach (workers : FIXED_WORKER_COUNTS) {
        ulong[CROWD_FRAMES] digests;
        CrowdTimes times;
        time_crowd(
            setup: &setup,
            mode: CrowdPath.POOL,
            workers: workers,
            digests: digests[..],
            times: &times,
        )!;
        if (!workers) serial_times = times;
        all_equal = all_equal && digests == reference;

        io::printfn(
            "crowd,%d,workers=%d,%d,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%d",
            count,
            workers,
            times.ranges,
            times.advance_ms,
            times.sample_ms,
            times.publish_ms,
            times.frame_ms,
            serial_times.sample_ms / times.sample_ms,
            serial_times.frame_ms / times.frame_ms,
            digests == reference ? 1 : 0,
        );
    }

    return all_equal;
}

fn int run_crowd_bench(String[] args) @private {
    if (args.len != 3 || args[1] != "--crowd") {
        io::eprintfn("usage: job_bench [--crowd COUNT]");
        return 1;
    }
    uint? parsed = args[2].to_uint();
    if (catch excuse = parsed) {
        io::eprintfn("crowd count must be a positive integer: %s", args[2]);
        return 1;
    }
    uint count = parsed;
    if (!count) {
        io::eprintfn("crowd count must be a positive integer: %s", args[2]);
        return 1;
    }

    bool? all_equal = crowd_bench(count);
    if (catch excuse = all_equal) {
        io::eprintfn("crowd bench failed: %s", excuse);
        return 1;
    }

    return all_equal ? 0 : 1;
}
