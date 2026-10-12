module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::model;
import c3d::scene;
import std::math;

fn void create_scale_playback_fixture(LayerFixture* fixture, Vec3 below, Allocator allocator = mem) @local {
    create_layer_fixture(fixture, allocator);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    assert(instance.base_pose.len == 4);
    instance.base_pose[3].scale = below;
}

fn ClipId scale_playback_clip(
    LayerFixture* fixture,
    Interpolation interpolation,
    float[] times,
    float[] values,
) @local {
    Track[1] tracks = {
        make_track(
            path: TargetPath.SCALE,
            interpolation: interpolation,
            times: times,
            values: values,
        ),
    };
    uint[1] targets = { 3 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn AnimationActionId play_scale_playback(
    LayerFixture* fixture,
    ClipId clip,
    PlayDesc desc,
    float weight,
    float time,
) @local {
    AnimationActionId action = fixture.animator.play(&fixture.assets, clip, desc)!!;
    Action* control = fixture.animator.action(action);
    control.weight = weight;
    control.time = time;
    control.speed = 0;
    control.loop = false;
    return action;
}

fn void update_scale_playback(LayerFixture* fixture, Vec3 expected) @local {
    anim::update(&fixture.assets, &fixture.scene, 0);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    assert(instance.present_node(3).local.scale == expected);
}

fn WeightedJointMask scale_playback_weighted_mask(LayerFixture* fixture, float weight) @local {
    String[1] names = { fixture.assets.model(fixture.model).data.nodes[3].name };
    float[1] weights = { weight };
    return anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: fixture.model,
        names: names[..],
        weights: weights[..],
    )!!;
}

fn void expect_scale_play_fault(
    LayerFixture* fixture,
    TrackingAllocator* tracker,
    ClipId clip,
    fault expected,
) @local {
    PlaybackView owner = fixture.animator.playback();
    AuthoringPoolSnapshot snapshot = snapshot_authoring_pool(&owner);
    defer destroy_authoring_pool_snapshot(&snapshot);
    sz acquisitions = tracker.total_allocation_count();
    PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
    assert(@catch(fixture.animator.play(&fixture.assets, clip, desc)) == expected);
    assert_authoring_pool_unchanged(&owner, &snapshot);
    assert(tracker.total_allocation_count() == acquisitions);
}

fn void test_animation_scale_playback_ratio_and_default_difference_use_literal_oracles() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 2, 4, 8, 8, 1, 32 };
    float[3] weights = { 0, 0.5f, 1 };
    Vec3[3] ratio_expected = { { 2, 3, 4 }, { 4, 1.5f, 8 }, { 8, 0.75f, 16 } };
    Vec3[3] difference_expected = { { 2, 3, 4 }, { 5, 1.5f, 16 }, { 8, 0, 28 } };
    foreach (bool ratio : { false, true }) {
        foreach (index, weight : weights) {
            LayerFixture fixture;
            create_scale_playback_fixture(&fixture, { 2, 3, 4 });
            defer destroy_layer_fixture(&fixture);
            ClipId clip = scale_playback_clip(
                fixture: &fixture,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: values[..],
            );
            PlayDesc desc = { .additive = true };
            if (ratio) desc.additive_scale = AdditiveScaleMode.MULTIPLICATIVE;
            AnimationActionId action = play_scale_playback(
                fixture: &fixture,
                clip: clip,
                desc: desc,
                weight: weight,
                time: 1,
            );
            Action* control = fixture.animator.action(action);
            float[3] reference_expected = { 2, 4, 8 };
            assert(control.reference == reference_expected[..]);
            update_scale_playback(&fixture, ratio ? ratio_expected[index] : difference_expected[index]);
            control.time = 0;
            update_scale_playback(&fixture, { 2, 3, 4 });
        }
    }

    float[2] straddling_times = { -1, 1 };
    float[6] straddling_values = { 2, 4, 8, 4, 8, 16 };
    LayerFixture fixture;
    create_scale_playback_fixture(&fixture, { 3, 6, 12 });
    defer destroy_layer_fixture(&fixture);
    ClipId clip = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: straddling_times[..],
        values: straddling_values[..],
    );
    AnimationActionId action = play_scale_playback(
        fixture: &fixture,
        clip: clip,
        desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 1,
        time: 1,
    );
    float[3] straddling_reference = { 3, 6, 12 };
    assert(fixture.animator.action(action).reference == straddling_reference[..]);
}

fn void test_animation_scale_playback_ratio_above_unit_weight_keeps_scale_positive() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 4, 2, 8, 1, 4, 2 };
    LayerFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 });
    defer destroy_layer_fixture(&fixture);
    ClipId clip = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    );
    (void)play_scale_playback(
        fixture: &fixture,
        clip: clip,
        desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 2,
        time: 1,
    );
    update_scale_playback(&fixture, { 0.125f, 12, 0.25f });
}

fn void test_animation_scale_playback_weighted_and_boolean_masks_are_copied() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 2, 4, 8, 8, 1, 32 };
    foreach (uint kind : { 0u, 1u, 2u }) {
        LayerFixture fixture;
        create_scale_playback_fixture(&fixture, { 2, 3, 4 });
        defer destroy_layer_fixture(&fixture);
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: values[..],
        );
        WeightedJointMask weighted = scale_playback_weighted_mask(&fixture, 0.25f);
        defer anim::destroy_weighted_joint_mask(&weighted);
        bool[4] included;
        included[3] = kind == 2;
        JointMask boolean = { .nodes = included[..] };
        PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
        if (kind == 0) {
            desc.weighted_mask = &weighted;
        } else {
            desc.mask = &boolean;
        }
        AnimationActionId action = play_scale_playback(
            fixture: &fixture,
            clip: clip,
            desc: desc,
            weight: kind == 0 ? 2 : 0.5f,
            time: 1,
        );
        weighted.nodes[..] = 0;
        included[..] = false;
        if (kind == 0) assert(fixture.animator.action(action).weighted_mask[3] == 0.25f);
        update_scale_playback(&fixture, kind == 1 ? (Vec3){ 2, 3, 4 } : (Vec3){ 4, 1.5f, 8 });
    }
}

fn void test_animation_scale_playback_multiple_additives_preserve_authored_order() @test {
    float[2] times = { 0, 1 };
    float[6] ratio_values = { 2, 4, 8, 8, 1, 32 };
    float[6] difference_values = { 1, 1, 1, 4, 9, 16 };
    uint[2][3] clip_order = { { 0, 1 }, { 1, 0 }, { 0, 1 } };
    AdditiveScaleMode[2][3] modes = {
        { MULTIPLICATIVE, DIFFERENCE },
        { DIFFERENCE, MULTIPLICATIVE },
        { MULTIPLICATIVE, MULTIPLICATIVE },
    };
    Vec3[3] expected = { { 5.5f, 5.5f, 15.5f }, { 7, 3.5f, 23 }, { 8, 4.5f, 32 } };
    for (uint arrangement = 0; arrangement < 3; arrangement++) {
        LayerFixture fixture;
        create_scale_playback_fixture(&fixture, { 2, 3, 4 });
        defer destroy_layer_fixture(&fixture);
        ClipId[2] clips = {
            scale_playback_clip(
                fixture: &fixture,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: ratio_values[..],
            ),
            scale_playback_clip(
                fixture: &fixture,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: difference_values[..],
            ),
        };
        for (uint index = 0; index < 2; index++) {
            (void)play_scale_playback(
                fixture: &fixture,
                clip: clips[clip_order[arrangement][index]],
                desc: { .additive = true, .additive_scale = modes[arrangement][index] },
                weight: 0.5f,
                time: 1,
            );
        }
        update_scale_playback(&fixture, expected[arrangement]);
    }
}

fn void test_animation_scale_playback_subnormal_huge_and_adjacent_ratios_match_exact_endpoints() @test {
    float[2] times = { 0, 1 };
    float adjacent = bitcast(0x3f800001u, float);
    float[6][3] values = {
        { 0x1p-149, 0x1p-149, 0x1p-149, 0x1p-148, 0x1p-148, 0x1p-148 },
        { 0x1p126, 0x1p126, 0x1p126, 0x1p127, 0x1p127, 0x1p127 },
        { 1, 1, 1, adjacent, adjacent, adjacent },
    };
    for (uint sample = 0; sample < 3; sample++) {
        LayerFixture fixture;
        create_scale_playback_fixture(&fixture, { 1, 1, 1 });
        defer destroy_layer_fixture(&fixture);
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[sample][..],
        );
        (void)play_scale_playback(
            fixture: &fixture,
            clip: clip,
            desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
            weight: 1,
            time: 1,
        );
        update_scale_playback(&fixture, sample == 2 ? (Vec3){ adjacent, adjacent, adjacent } : (Vec3){ 2, 2, 2 });
    }
}

fn void test_animation_scale_playback_invalid_domains_reject_before_pool_or_allocation_changes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 }, &tracker);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] valid_values = { 2, 4, 8, 8, 1, 32 };
    ClipId valid = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: valid_values[..],
    );
    (void)play_scale_playback(
        fixture: &fixture,
        clip: valid,
        desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 0.5f,
        time: 1,
    );
    update_scale_playback(&fixture, { 4, 1.5f, 8 });
    for (uint invalid = 0; invalid < 6; invalid++) {
        float[6] ordinary = { 1, 1, 1, 1, 1, 1 };
        float[18] cubic = { 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        switch (invalid) {
            case 0: ordinary[0] = 0;
            case 1: ordinary[3] = -1;
            case 2: ordinary[0] = float::nan;
            case 3: ordinary[3] = float::inf;
            case 4: ordinary[3] = -1;
            case 5:
        }
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: invalid == 5 ? Interpolation.CUBIC_SPLINE
              : (invalid == 4 ? Interpolation.LINEAR : Interpolation.STEP),
            times: times[..],
            values: invalid == 5 ? cubic[..] : ordinary[..],
        );
        expect_scale_play_fault(
            fixture: &fixture,
            tracker: &tracker,
            clip: clip,
            expected: c3d::INVALID_ARGUMENT,
        );
        update_scale_playback(&fixture, { 4, 1.5f, 8 });
        fixture.assets.remove_clip(clip);
    }
}

fn void test_animation_scale_playback_cubic_multiplicative_scale_is_unsupported_after_invalid_faults() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 }, &tracker);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 2, 2, 2, 0, 0, 0, 0, 0, 0, 2, 2, 2, 0, 0, 0 };
    ClipId clip = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.CUBIC_SPLINE,
        times: times[..],
        values: values[..],
    );
    expect_scale_play_fault(
        fixture: &fixture,
        tracker: &tracker,
        clip: clip,
        expected: c3d::UNSUPPORTED,
    );
    update_scale_playback(&fixture, { 2, 3, 4 });

    float[6] nonpositive = { 1, 1, 1, 0, 1, 1 };
    Track[2] tracks = {
        make_track(
            path: TargetPath.SCALE,
            interpolation: Interpolation.CUBIC_SPLINE,
            times: times[..],
            values: values[..],
        ),
        make_track(
            path: TargetPath.SCALE,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: nonpositive[..],
        ),
    };
    uint[2] targets = { 3, 2 };
    ClipId mixed = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    expect_scale_play_fault(
        fixture: &fixture,
        tracker: &tracker,
        clip: mixed,
        expected: c3d::INVALID_ARGUMENT,
    );
    update_scale_playback(&fixture, { 2, 3, 4 });
}
