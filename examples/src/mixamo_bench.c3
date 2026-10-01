module mixamo_example @feat(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL);

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
import c3d::model;
import c3d::profile;
import c3d::scene;
import std::io;
import std::math;

const uint BENCHMARK_WARMUP @local = 300; // five seconds of playback before measuring
const uint BENCHMARK_FRAMES @local = 5000; // repeatable mean without renderer or window work
const float BENCHMARK_STEP @local = 1.0f / 60;
const uint DRIFT_CYCLES @local = 10;
const String[5] CASE_NAMES @local = { "single", "masked", "layered_additive", "motion_space", "motion_space_masked" };

fn void? run_animation_benchmark(String model_path, String walk_path, String run_path) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1024 });
    defer scene::destroy_scene(&scene);
    ModelId model = fbx::load_model(&assets, model_path)!;
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.KEEP;
    ClipId[] clips = fbx::load_animations(
        allocator: mem,
        assets: &assets,
        path: walk_path,
        target: model,
        options: options,
    )!;
    defer free(clips);
    if (!clips.len) return c3d::INVALID_ARGUMENT~;

    ClipId[] running = fbx::load_animations(
        allocator: mem,
        assets: &assets,
        path: run_path,
        target: model,
        options: options,
    )!;
    defer free(running);
    if (!running.len) return c3d::INVALID_ARGUMENT~;

    Node* root = model::instantiate(&assets, &scene, model)!;
    Animator* animator = anim::add_animator(&scene, root);
    Wave wave = create_wave(&assets, model)!;
    String[1] names = { wave.mask_node };
    JointMask mask = anim::create_joint_mask(mem, &assets.model(model).data, names[..])!;
    defer anim::destroy_joint_mask(&mask);
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 1,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .label_bytes_per_frame = 256,
    })!;
    defer profile::destroy_recorder(&recorder);

    foreach (variant, name : CASE_NAMES) {
        foreach (&space : animator.blend_spaces) {
            if (space.count) animator.stop_blend_space(space)!;
        }
        while (animator.action_count) animator.stop(animator.order[0])!;
        uint tracks = (uint)assets.clip(clips[0]).data.tracks.len;
        if (variant >= 3) {
            ClipId[3] locomotion = { clips[0], running[0], clips[0] };
            float[3] positions = { 0, 1, 2 };
            usz member_count = variant == 3 ? 2 : 3;
            BlendSpace1D* space = animator.add_blend_space(
                assets: &assets,
                clips: locomotion[:member_count],
                positions: positions[:member_count],
                desc: { .root_motion = RootMotion.EXTRACT },
            )!;
            space.parameter = 0.5f;
            tracks += (uint)assets.clip(running[0]).data.tracks.len;
            if (variant == 4) tracks += (uint)assets.clip(clips[0]).data.tracks.len;
        } else {
            animator.play(&assets, clips[0])!;
        }
        if ((variant > 0 && variant < 3) || variant == 4) {
            animator.play(&assets, wave.clip, { .layer = 1, .mask = &mask })!;
            tracks += (uint)assets.clip(wave.clip).data.tracks.len;
        }
        if (variant == 2) {
            AnimationActionId overlay = animator.play(
                assets: &assets,
                clip: wave.clip,
                desc: { .layer = 2, .additive = true, .mask = &mask },
            )!;
            animator.action(overlay).weight = 0.5f;
            tracks += (uint)assets.clip(wave.clip).data.tracks.len;
        }

        double nanoseconds;
        for (ulong frame = 0; frame < BENCHMARK_WARMUP + BENCHMARK_FRAMES; frame++) {
            profile::@capture(&recorder, frame) {
                anim::update(&assets, &scene, BENCHMARK_STEP);
            };
            if (frame < BENCHMARK_WARMUP) continue;
            foreach (sample : recorder.frame(frame)!.cpu) {
                if (sample.label == "anim.update") nanoseconds += (double)sample.duration_ns;
            }
        }
        io::printfn("%s,nodes,%d", name, animator.nodes.len);
        io::printfn("%s,tracks,%d", name, tracks);
        io::printfn("%s,actions,%d", name, animator.action_count);
        io::printfn("%s,frames,%d", name, BENCHMARK_FRAMES);
        io::printfn("%s,anim_update_ms,%.6f", name, nanoseconds / BENCHMARK_FRAMES / 1_000_000);
    }

    foreach (&space : animator.blend_spaces) {
        if (space.count) animator.stop_blend_space(space)!;
    }
    while (animator.action_count) animator.stop(animator.order[0])!;
    AnimationActionId walking = animator.play(&assets, clips[0], { .root_motion = RootMotion.EXTRACT })!;
    Vec3 expected = animator.action(walking).cycle_translation * DRIFT_CYCLES;
    double remaining = (double)assets.clip(clips[0]).data.duration * DRIFT_CYCLES;
    while (remaining > 0) {
        float step = (float)math::min(remaining, (double)BENCHMARK_STEP);
        anim::update(&assets, &scene, step);
        anim::apply_root_motion(root, animator.root_motion);
        remaining -= step;
    }
    float drift = (root.local.position - expected).length();
    io::printfn("root_motion,cycles,%d", DRIFT_CYCLES);
    io::printfn("root_motion,distance_m,%.6f", expected.length());
    io::printfn("root_motion,drift_m,%.9f", drift);
    io::printfn("animator,component_bytes,%d", Animator::size);
    if (drift >= 0.001f) return c3d::INVALID_ARGUMENT~;

}
