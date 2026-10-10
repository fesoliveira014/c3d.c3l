module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

fn void test_animation_analytic_composition_layers_masks_speed_and_paused_rates() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    fixture.scene.remove_component(fixture.root, Animator);
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
    float[2] times = { 0, 1 };
    float[6] values = { 0, 0, 0, 4, 8, -2 };
    Track[1] tracks = { make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationActionId regular = fixture.animator.play(&fixture.assets, clip)!!;
    Action* first = fixture.animator.action(regular);
    first.time = 0.25f;
    first.weight = 0.5f;
    first.speed = 2;
    AnimationActionId additive = fixture.animator.play(&fixture.assets, clip, { .layer = 1, .additive = true })!!;
    Action* second = fixture.animator.action(additive);
    second.time = 0.5f;
    second.weight = 0.25f;
    second.speed = -1;
    PlaybackView playback = fixture.animator.playback();
    PoseStorage* storage = fixture.animator.pose_storage;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    double[<3>] expected = { 3, 6, -1.5 };
    assert((storage.scratch.derivative.velocity[3].translation - expected).length() < 1e-12);
    first.playing = second.playing = false;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    assert(storage.scratch.derivative.velocity[3].translation == (double[<3>]){});
}

fn void test_animation_analytic_composition_rotation_rate_matches_independent_axis_angle() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    fixture.scene.remove_component(fixture.root, Animator);
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, 0, 1, 0, 0 };
    Track[1] tracks = { make_track(
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
    Action* action = fixture.animator.action(id);
    action.time = 0.25f;
    action.speed = -2;
    PlaybackView playback = fixture.animator.playback();
    PoseStorage* storage = fixture.animator.pose_storage;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    double[<3>] expected = { 0, -2 * math::PI, 0 };
    assert((storage.scratch.derivative.velocity[3].angular - expected).length() < 1e-7);
}
