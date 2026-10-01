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

const uint BENCHMARK_WARMUP @local = 300; // five seconds of playback before measuring
const uint BENCHMARK_FRAMES @local = 5000; // repeatable mean without renderer or window work
const float BENCHMARK_STEP @local = 1.0f / 60;
const String[3] CASE_NAMES @local = { "single", "masked", "layered_additive" };

fn void? run_animation_benchmark(String model_path, String walk_path) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1024 });
    defer scene::destroy_scene(&scene);
    ModelId model = fbx::load_model(&assets, model_path)!;
    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.root_motion = RootMotion.STRIP_XZ;
    ClipId[] clips = fbx::load_animations(
        allocator: mem,
        assets: &assets,
        path: walk_path,
        target: model,
        options: options,
    )!;
    defer free(clips);
    if (!clips.len) return c3d::INVALID_ARGUMENT~;

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
        while (animator.action_count) animator.stop(animator.order[0])!;
        animator.play(&assets, clips[0])!;
        uint tracks = (uint)assets.clip(clips[0]).data.tracks.len;
        if (variant > 0) {
            animator.play(&assets, wave.clip, { .layer = 1, .mask = &mask })!;
            tracks += (uint)assets.clip(wave.clip).data.tracks.len;
        }
        if (variant > 1) {
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
}
