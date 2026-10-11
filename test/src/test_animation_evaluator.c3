module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::scene;

struct TaggedEvent @local {
    uint prefix;
    FiredEvent event;
    uint suffix;
}

fn ClipId evaluator_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] values = { 0, 0, 0, 1, 0, 0 };
    Track[1] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[..],
        ),
    };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void test_evaluator_event_growth_uses_strided_retained_capacity_and_zero_drops() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = evaluator_clip(&fixture);
        ClipEvent[1] initial = { { .time = 0.25f, .id = 1 } };
        fixture.assets.set_clip_events(clip, initial[..])!!;
        fixture.animator.play(&fixture.assets, clip)!!;
        ClipEvent[40] expanded;
        foreach (uint index, &event : expanded) *event = { .time = 0.25f, .id = index + 1 };
        fixture.assets.set_clip_events(clip, expanded[..])!!;

        TaggedEvent[16] output;
        foreach (&entry : output) {
            entry.prefix = 0x12345678;
            entry.suffix = 0x87654321;
        }
        PlaybackView playback = fixture.animator.playback();
        sz allocations = tracker.total_allocation_count();
        PoseReport report = anim::evaluate_pose(
            playback: &playback,
            assets: &fixture.assets,
            destination: fixture.animator.pose_storage.destination,
            scratch: fixture.animator.pose_storage.scratch,
            dt: 3.25f,
            events: { .first = &output[0].event, .stride = TaggedEvent::size, .capacity = output.len },
        );
        assert(report.events.count == 16 && report.events.dropped == 104);
        foreach (uint index, entry : output) {
            assert(entry.prefix == 0x12345678 && entry.suffix == 0x87654321);
            assert(entry.event.id == index + 1 && entry.event.time == 0.25f);
        }
        assert(tracker.total_allocation_count() == allocations);

        report = anim::evaluate_pose(
            playback: &playback,
            assets: &fixture.assets,
            destination: fixture.animator.pose_storage.destination,
            scratch: fixture.animator.pose_storage.scratch,
            dt: 3,
            events: {},
        );
        assert(report.events.count == 0 && report.events.dropped == 120);
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(!tracker.has_leaks());
}

fn void test_evaluator_absent_wide_morph_tracks_skip_before_sample_slicing() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    fixture.scene.remove(instance.present_node(1));
    float[2] times = { 0, 1 };
    float[16] weights;
    weights[..] = 0.5f;
    float[6] positions = { 0, 0, 0, 2, 0, 0 };
    Track[2] tracks = {
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: weights[..],
        ),
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
            target: 1,
        ),
    };
    uint[2] targets = { 1, 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.play(&fixture.assets, clip, { .additive = true })!!;
    assert(fixture.animator.pose_storage.scratch.sample.len == 4);
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(instance.present_node(3).local.position.x == 2);
}
