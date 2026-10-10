module c3d::test::animation_reference;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::model;
import c3d::scene;
import std::io::path;

fn String reference_asset_path(String repository, String relative) @private {
    Path root = path::tnew(repository)!!;
    return (String)root.tappend(relative)!!;
}

fn void? create_real_rig(
    Allocator allocator,
    ReferenceRig* rig,
    String model_path,
) @private {
    *rig = create_reference_rig(allocator);
    defer catch destroy_reference_rig(rig);

    rig.model = gltf::load_model(&rig.assets, model_path)!;
    rig.clips = rig.assets.model(rig.model).data.clips;
    rig.root = model::instantiate(&rig.assets, &rig.scene, rig.model)!;
    anim::add_animator(&rig.scene, rig.root);
}

fn uint? reference_clip_named(ReferenceRig* rig, String name) @private {
    foreach (index, clip : rig.clips) {
        if (rig.assets.clip(clip).data.name == name) return (uint)index;
    }

    return c3d::INVALID_ARGUMENT~;
}

fn void? capture_quaternius(ReferenceCapture* capture, String repository) @private {
    ReferenceRig rig;
    create_real_rig(
        allocator: mem,
        rig: &rig,
        model_path: reference_asset_path(repository, "examples/assets/quaternius/AnimationLibrary_Godot.glb"),
    )!;
    defer destroy_reference_rig(&rig);

    uint walk_clip = reference_clip_named(&rig, "Walk_Loop")!;
    uint jog_clip = reference_clip_named(&rig, "Jog_Fwd_Loop")!;
    uint idle_clip = reference_clip_named(&rig, "Idle_Loop")!;
    float walk_duration = rig.assets.clip(rig.clips[walk_clip]).data.duration;
    capture.snapshot(&rig, 5, CaptureOperation.BASELINE)!;

    AnimationActionId walk = rig.play(walk_clip, 10)!;
    capture.snapshot(&rig, 5, CaptureOperation.PLAY)!;
    rig.playback().action(walk).time = walk_duration * 0.25f;
    capture.snapshot(&rig, 5, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 5, 0)!;
    capture.update(&rig, 5, walk_duration * 0.125f)!;

    rig.playback().action(walk).time = walk_duration * 0.75f;
    rig.playback().action(walk).speed = -0.5f;
    capture.snapshot(&rig, 5, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 5, walk_duration * 0.5f)!;

    AnimationActionId jog = rig.play(clip: jog_clip, label: 20, desc: { .fade_in = 0.2f })!;
    capture.snapshot(&rig, 5, CaptureOperation.PLAY)!;
    rig.playback().cross_fade(walk, jog, 0.4f)!;
    capture.snapshot(&rig, 5, CaptureOperation.CROSS_FADE)!;
    capture.update(&rig, 5, 0.2f)!;
    capture.update(&rig, 5, 0.2f)!;
    rig.playback().stop(jog)!;
    capture.snapshot(&rig, 5, CaptureOperation.STOP)!;
    capture.update(&rig, 5, 0)!;

    AnimationActionId idle = rig.play(idle_clip, 30)!;
    capture.snapshot(&rig, 5, CaptureOperation.PLAY)!;
    rig.playback().action(idle).weight = 0.25f;
    capture.snapshot(&rig, 5, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 5, 0.125f)!;
    rig.playback().stop(idle)!;
    capture.snapshot(&rig, 5, CaptureOperation.STOP)!;
    capture.update(&rig, 5, 0)!;
}

fn void? capture_animated_morph_cube(ReferenceCapture* capture, String repository) @private {
    ReferenceRig rig;
    create_real_rig(
        allocator: mem,
        rig: &rig,
        model_path: reference_asset_path(repository, "examples/assets/gltf/AnimatedMorphCube.glb"),
    )!;
    defer destroy_reference_rig(&rig);

    if (rig.clips.len != 1) return c3d::INVALID_ARGUMENT~;

    float duration = rig.assets.clip(rig.clips[0]).data.duration;
    capture.snapshot(&rig, 6, CaptureOperation.BASELINE)!;
    AnimationActionId base = rig.play(0, 10)!;
    capture.snapshot(&rig, 6, CaptureOperation.PLAY)!;
    rig.playback().action(base).loop = false;
    rig.playback().action(base).speed = 0.75f;
    capture.snapshot(&rig, 6, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 6, 0)!;
    capture.update(&rig, 6, duration * 0.3f)!;

    rig.playback().action(base).time = duration * 0.5f;
    capture.snapshot(&rig, 6, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 6, 0)!;
    AnimationActionId additive = rig.play(
        clip: 0,
        label: 20,
        desc: { .layer = 1, .additive = true },
    )!;
    capture.snapshot(&rig, 6, CaptureOperation.PLAY)!;
    rig.playback().action(additive).weight = 0.5f;
    rig.playback().action(additive).time = duration * 0.5f;
    rig.playback().action(additive).speed = -0.25f;
    capture.snapshot(&rig, 6, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 6, duration * 0.1f)!;

    rig.playback().stop(additive, 0.2f)!;
    capture.snapshot(&rig, 6, CaptureOperation.STOP)!;
    capture.update(&rig, 6, 0.2f)!;
    rig.playback().stop(base)!;
    capture.snapshot(&rig, 6, CaptureOperation.STOP)!;
    capture.update(&rig, 6, 0)!;
}
