module c3d::test::animation_reference;

import c3d;
import c3d::anim;
import c3d::scene;

fn void? capture_exact_controls(ReferenceCapture* capture) @private {
    ReferenceRig rig;
    create_exact_rig(&rig, mem)!;
    defer destroy_reference_rig(&rig);

    capture.snapshot(&rig, 1, CaptureOperation.BASELINE)!;
    AnimationActionId base = rig.play(0, 10)!;
    capture.snapshot(&rig, 1, CaptureOperation.PLAY)!;
    rig.playback().action(base).time = 0.8f;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0)!;
    capture.update(&rig, 1, 0.25f)!;

    rig.playback().action(base).playing = false;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0.5f)!;
    rig.playback().action(base).playing = true;
    rig.playback().action(base).speed = 0;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0.5f)!;

    rig.playback().action(base).speed = -1;
    rig.playback().action(base).time = 0.1f;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0.25f)!;
    rig.playback().action(base).loop = false;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 2)!;

    rig.playback().action(base).playing = true;
    rig.playback().action(base).speed = 1;
    rig.playback().action(base).time = 0.9f;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0.25f)!;

    rig.playback().action(base).loop = true;
    rig.playback().action(base).playing = true;
    rig.playback().action(base).speed = 5;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 1.5f)!;

    rig.playback().action(base).time = 0.2f;
    capture.snapshot(&rig, 1, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 1, 0)!;
    capture.update(&rig, 1, 0.125f)!;
    rig.playback().stop(base)!;
    capture.snapshot(&rig, 1, CaptureOperation.STOP)!;
    capture.update(&rig, 1, 0)!;
}

fn void? capture_exact_layers(ReferenceCapture* capture) @private {
    ReferenceRig rig;
    create_exact_rig(&rig, mem)!;
    defer destroy_reference_rig(&rig);

    capture.snapshot(&rig, 2, CaptureOperation.BASELINE)!;
    AnimationActionId base = rig.play(0, 10)!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;

    String[2] names = { "upper", "morph" };
    JointMask mask = anim::create_joint_mask(
        allocator: mem,
        template: &rig.assets.model(rig.model).data,
        names: names[..],
    )!;
    defer anim::destroy_joint_mask(&mask);
    AnimationActionId upper = rig.play(
        clip: 2,
        label: 20,
        desc: { .layer = 3, .mask = &mask },
    )!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;
    mask.nodes[..] = false;
    rig.playback().action(upper).weight = 2;
    capture.snapshot(&rig, 2, CaptureOperation.EDIT_ACTION)!;

    AnimationActionId additive = rig.play(
        clip: 3,
        label: 30,
        desc: { .layer = 2, .additive = true },
    )!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;
    rig.playback().action(additive).weight = 0.5f;
    capture.snapshot(&rig, 2, CaptureOperation.EDIT_ACTION)!;
    AnimationActionId step = rig.play(clip: 4, label: 40, desc: { .layer = 1 })!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;
    capture.update(&rig, 2, 0)!;
    capture.update(&rig, 2, 0.25f)!;
    capture.update(&rig, 2, 0.25f)!;

    AnimationActionId incoming = rig.play(clip: 1, label: 11, desc: { .fade_in = 0.5f })!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;
    rig.playback().cross_fade(base, incoming, 0.5f)!;
    capture.snapshot(&rig, 2, CaptureOperation.CROSS_FADE)!;
    capture.update(&rig, 2, 0.25f)!;
    capture.update(&rig, 2, 0.25f)!;
    rig.playback().stop(upper, 0.25f)!;
    capture.snapshot(&rig, 2, CaptureOperation.STOP)!;
    capture.update(&rig, 2, 0.25f)!;

    rig.playback().stop(incoming)!;
    capture.snapshot(&rig, 2, CaptureOperation.STOP)!;
    rig.playback().stop(additive)!;
    capture.snapshot(&rig, 2, CaptureOperation.STOP)!;
    rig.playback().stop(step)!;
    capture.snapshot(&rig, 2, CaptureOperation.STOP)!;
    capture.update(&rig, 2, 0)!;

    ModelInstance* instance = rig.scene.get(rig.root, ModelInstance);
    Node* removed = instance.present_node(4);
    rig.scene.remove(removed);
    capture.snapshot(&rig, 2, CaptureOperation.REMOVE_TARGET)!;
    rig.play(4, 41)!;
    capture.snapshot(&rig, 2, CaptureOperation.PLAY)!;
    capture.update(&rig, 2, 0.5f)!;
}

fn void? capture_exact_spaces(ReferenceCapture* capture) @private {
    ReferenceRig rig;
    create_exact_rig(&rig, mem)!;
    defer destroy_reference_rig(&rig);

    capture.snapshot(&rig, 3, CaptureOperation.BASELINE)!;
    float[2] positions = { 0, 1 };
    BlendSpace1D* space = rig.playback().add_blend_space(
        assets: &rig.assets,
        clips: rig.clips[:2],
        positions: positions[..],
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true, .fade_in = 0.25f },
    )!;
    rig.label_space(space, 50);
    capture.snapshot(&rig, 3, CaptureOperation.ADD_SPACE)!;
    capture.update(&rig, 3, 0)!;

    space.parameter = 0.25f;
    capture.snapshot(&rig, 3, CaptureOperation.EDIT_SPACE)!;
    capture.update(&rig, 3, 0.25f)!;
    space.parameter = 2;
    space.phase = 0.9;
    space.speed = -1;
    capture.snapshot(&rig, 3, CaptureOperation.EDIT_SPACE)!;
    capture.update(&rig, 3, 0.5f)!;

    space.playing = false;
    space.parameter = -1;
    capture.snapshot(&rig, 3, CaptureOperation.EDIT_SPACE)!;
    capture.update(&rig, 3, 0.25f)!;
    rig.playback().fade_blend_space(space, 0.25f, 0.5f)!;
    capture.snapshot(&rig, 3, CaptureOperation.EDIT_SPACE)!;
    capture.update(&rig, 3, 0.25f)!;

    ClipId[2] upper_clips = { rig.clips[2], rig.clips[3] };
    BlendSpace1D* upper = rig.playback().add_blend_space(
        assets: &rig.assets,
        clips: upper_clips[..],
        positions: positions[..],
        desc: { .layer = 2, .additive = true },
    )!;
    rig.label_space(upper, 60);
    capture.snapshot(&rig, 3, CaptureOperation.ADD_SPACE)!;
    upper.parameter = 0.5f;
    capture.snapshot(&rig, 3, CaptureOperation.EDIT_SPACE)!;
    capture.update(&rig, 3, 0.5f)!;

    rig.playback().stop_blend_space(space, 0.25f)!;
    capture.snapshot(&rig, 3, CaptureOperation.STOP_SPACE)!;
    capture.update(&rig, 3, 0.25f)!;
    rig.playback().stop_blend_space(upper)!;
    capture.snapshot(&rig, 3, CaptureOperation.STOP_SPACE)!;
    capture.update(&rig, 3, 0)!;
}

fn void? capture_exact_motion(ReferenceCapture* capture) @private {
    ReferenceRig rig;
    create_exact_rig(&rig, mem)!;
    defer destroy_reference_rig(&rig);

    capture.snapshot(&rig, 4, CaptureOperation.BASELINE)!;
    AnimationActionId base = rig.play(
        clip: 0,
        label: 10,
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true },
    )!;
    capture.snapshot(&rig, 4, CaptureOperation.PLAY)!;
    rig.playback().action(base).weight = 0.6f;
    capture.snapshot(&rig, 4, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 4, 0)!;
    capture.update(&rig, 4, 0.25f)!;

    AnimationActionId upper = rig.play(
        clip: 1,
        label: 20,
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true, .layer = 1 },
    )!;
    capture.snapshot(&rig, 4, CaptureOperation.PLAY)!;
    rig.playback().action(upper).weight = 0.35f;
    capture.snapshot(&rig, 4, CaptureOperation.EDIT_ACTION)!;
    AnimationActionId kept = rig.play(clip: 0, label: 30, desc: { .layer = 2 })!;
    capture.snapshot(&rig, 4, CaptureOperation.PLAY)!;
    rig.playback().action(kept).weight = 0.5f;
    capture.snapshot(&rig, 4, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 4, 0.2f)!;

    anim::apply_root_motion(rig.root, rig.playback().root_motion);
    rig.scene.update_world();
    capture.snapshot(&rig, 4, CaptureOperation.APPLY_MOTION)!;

    rig.playback().action(base).speed = -1;
    rig.playback().action(base).time = 0.1f;
    rig.playback().action(upper).speed = -0.5f;
    rig.playback().action(upper).time = 0.2f;
    rig.playback().action(kept).playing = false;
    capture.snapshot(&rig, 4, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 4, 2.25f)!;

    rig.playback().action(base).time = 0.8f;
    capture.snapshot(&rig, 4, CaptureOperation.EDIT_ACTION)!;
    capture.update(&rig, 4, 0)!;
    capture.update(&rig, 4, 0.125f)!;
}
