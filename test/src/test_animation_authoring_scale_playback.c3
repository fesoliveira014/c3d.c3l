module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

struct ScalePlaybackFixture @local {
    LayerFixture ordinary;
    Transform[1] placements;
    CrowdPlaybackState* crowd;
    CrowdPlayer player;
}

struct ScalePlaybackSnapshot @local {
    char[] actions;
    uint[] generations;
    uint[] free;
    AnimationActionId[] order;
    bool[] masks;
    uint action_count;
    uint free_count;
}

struct ScalePlaybackAllocator (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz acquisitions;
    sz outstanding;
}

fn void*? ScalePlaybackAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.acquisitions++;
    self.outstanding++;
    return pointer;
}

fn void*? ScalePlaybackAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    self.acquisitions++;
    return self.backing.resize(pointer, size, alignment);
}

fn void ScalePlaybackAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn void create_scale_playback_fixture(
    ScalePlaybackFixture* fixture,
    Vec3 below,
    Allocator allocator = mem,
) @local {
    create_layer_fixture(&fixture.ordinary, allocator);
    ModelInstance* instance = fixture.ordinary.scene.get(fixture.ordinary.root, ModelInstance);
    assert(instance.base_pose.len == 4);
    instance.base_pose[3].scale = below;
    fixture.placements[0] = maths::TRANSFORM_IDENTITY;
    fixture.crowd = anim::create_crowd_playback(
        allocator: allocator,
        template: &fixture.ordinary.assets.model(fixture.ordinary.model).data,
        placements: fixture.placements[..],
        actions_per_instance: 4,
        event_capacity: 0,
    )!!;
    fixture.crowd.model = fixture.ordinary.model;
    fixture.crowd.count = 1;
    fixture.crowd.base_pose[3].scale = below;
    fixture.player = fixture.crowd.player(fixture.crowd.instance_id(0)!!)!!;
}

fn void destroy_scale_playback_fixture(ScalePlaybackFixture* fixture) @local {
    anim::destroy_crowd_playback(fixture.crowd);
    destroy_layer_fixture(&fixture.ordinary);
}

fn ClipId scale_playback_clip(
    ScalePlaybackFixture* fixture,
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
        assets: &fixture.ordinary.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn AnimationActionId[2] play_scale_playback_pair(
    ScalePlaybackFixture* fixture,
    ClipId clip,
    PlayDesc desc,
    float weight,
    float time,
) @local {
    AnimationActionId[2] actions = {
        fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, desc)!!,
        fixture.player.play(&fixture.ordinary.assets, clip, desc)!!,
    };
    Action*[2] controls = { fixture.ordinary.animator.action(actions[0]), fixture.player.action(actions[1]) };
    foreach (control : controls) {
        control.weight = weight;
        control.time = time;
        control.speed = 0;
        control.loop = false;
    }
    return actions;
}

fn void update_scale_playback_pair(ScalePlaybackFixture* fixture, Vec3 expected) @local {
    anim::update(&fixture.ordinary.assets, &fixture.ordinary.scene, 0);
    fixture.crowd.update(&fixture.ordinary.assets, 0);
    ModelInstance* instance = fixture.ordinary.scene.get(fixture.ordinary.root, ModelInstance);
    Vec3 ordinary = instance.present_node(3).local.scale;
    Vec3 crowd = fixture.crowd.poses[3].scale;
    assert(ordinary == expected && crowd == expected);
    assert(mem::equals(&ordinary, &crowd, Vec3::size));
}

fn WeightedJointMask scale_playback_weighted_mask(ScalePlaybackFixture* fixture, float weight) @local {
    String[1] names = { fixture.ordinary.assets.model(fixture.ordinary.model).data.nodes[3].name };
    float[1] weights = { weight };
    return anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.ordinary.assets,
        model: fixture.ordinary.model,
        names: names[..],
        weights: weights[..],
    )!!;
}

fn ScalePlaybackSnapshot snapshot_scale_playback(PlaybackView* playback) @local {
    char[] action_bytes = ((char*)playback.actions.items.ptr)[:playback.actions.items.len * Action::size];
    return {
        .actions = alloc::clone_slice(mem, action_bytes),
        .generations = alloc::clone_slice(mem, playback.actions.generations),
        .free = alloc::clone_slice(mem, playback.actions.free),
        .order = alloc::clone_slice(mem, playback.order),
        .masks = alloc::clone_slice(mem, playback.mask_storage),
        .action_count = *playback.action_count,
        .free_count = playback.actions.free_count,
    };
}

fn void destroy_scale_playback_snapshot(ScalePlaybackSnapshot* snapshot) @local {
    alloc::free(mem, snapshot.actions.ptr);
    alloc::free(mem, snapshot.generations.ptr);
    alloc::free(mem, snapshot.free.ptr);
    alloc::free(mem, snapshot.order.ptr);
    alloc::free(mem, snapshot.masks.ptr);
}

fn void assert_scale_playback_unchanged(PlaybackView* playback, ScalePlaybackSnapshot* snapshot) @local {
    assert(*playback.action_count == snapshot.action_count && playback.actions.free_count == snapshot.free_count);
    assert(mem::equals((char*)playback.actions.items.ptr, snapshot.actions.ptr, snapshot.actions.len));
    assert(mem::equals(
        a: playback.actions.generations.ptr,
        b: snapshot.generations.ptr,
        len: snapshot.generations.len * uint::size,
    ));
    assert(mem::equals(playback.actions.free.ptr, snapshot.free.ptr, snapshot.free.len * uint::size));
    assert(mem::equals(playback.order.ptr, snapshot.order.ptr, snapshot.order.len * AnimationActionId::size));
    assert(mem::equals(playback.mask_storage.ptr, snapshot.masks.ptr, snapshot.masks.len * bool::size));
}

fn void test_animation_scale_playback_ratio_and_default_difference_use_literal_oracles() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 2, 4, 8, 4, 2, 16 };
    float[3] weights = { 0, 0.5f, 1 };
    Vec3[3] ratio_expected = { { 2, 3, 4 }, { 3, 2.25f, 6 }, { 4, 1.5f, 8 } };
    Vec3[3] difference_expected = { { 2, 3, 4 }, { 3, 2, 8 }, { 4, 1, 12 } };
    foreach (bool ratio : { false, true }) {
        foreach (index, weight : weights) {
            ScalePlaybackFixture fixture;
            create_scale_playback_fixture(&fixture, { 2, 3, 4 });
            defer destroy_scale_playback_fixture(&fixture);
            ClipId clip = scale_playback_clip(
                fixture: &fixture,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: values[..],
            );
            PlayDesc desc = { .additive = true };
            if (ratio) desc.additive_scale = AdditiveScaleMode.MULTIPLICATIVE;
            AnimationActionId[2] actions = play_scale_playback_pair(
                fixture: &fixture,
                clip: clip,
                desc: desc,
                weight: weight,
                time: 1,
            );
            Action* ordinary = fixture.ordinary.animator.action(actions[0]);
            Action* crowd = fixture.player.action(actions[1]);
            float[3] reference_expected = { 2, 4, 8 };
            assert(ordinary.reference == reference_expected[..]);
            assert(crowd.reference == ordinary.reference && crowd.reference.ptr != ordinary.reference.ptr);
            update_scale_playback_pair(&fixture, ratio ? ratio_expected[index] : difference_expected[index]);
            ordinary.time = 0;
            crowd.time = 0;
            update_scale_playback_pair(&fixture, { 2, 3, 4 });
        }
    }
}

fn void test_animation_scale_playback_weighted_and_boolean_masks_are_copied() @test {
    float[2] times = { 0, 1 };
    float[6] values = { 2, 4, 8, 4, 2, 16 };
    foreach (uint kind : { 0u, 1u, 2u }) {
        ScalePlaybackFixture fixture;
        create_scale_playback_fixture(&fixture, { 2, 3, 4 });
        defer destroy_scale_playback_fixture(&fixture);
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
        AnimationActionId[2] actions = play_scale_playback_pair(
            fixture: &fixture,
            clip: clip,
            desc: desc,
            weight: kind == 0 ? 2 : 0.5f,
            time: 1,
        );
        weighted.nodes[..] = 0;
        included[..] = false;
        if (kind == 0) {
            assert(fixture.ordinary.animator.action(actions[0]).weighted_mask[3] == 0.25f);
            assert(fixture.player.action(actions[1]).weighted_mask[3] == 0.25f);
        }
        update_scale_playback_pair(&fixture, kind == 1 ? (Vec3){ 2, 3, 4 } : (Vec3){ 3, 2.25f, 6 });
    }
}

fn void test_animation_scale_playback_multiple_additives_preserve_authored_order() @test {
    float[2] times = { 0, 1 };
    float[6] ratio_values = { 2, 4, 8, 4, 2, 16 };
    float[6] difference_values = { 1, 1, 1, 2, 3, 4 };
    Vec3[2] expected = { { 3.5f, 3.25f, 7.5f }, { 3.75f, 3, 8.25f } };
    for (uint reverse = 0; reverse < 2; reverse++) {
        ScalePlaybackFixture fixture;
        create_scale_playback_fixture(&fixture, { 2, 3, 4 });
        defer destroy_scale_playback_fixture(&fixture);
        ClipId ratio = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: ratio_values[..],
        );
        ClipId difference = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: difference_values[..],
        );
        for (uint index = 0; index < 2; index++) {
            bool multiplicative = (index == 0) != (reverse != 0);
            (void)play_scale_playback_pair(
                fixture: &fixture,
                clip: multiplicative ? ratio : difference,
                desc: {
                    .additive = true,
                    .additive_scale = multiplicative ? AdditiveScaleMode.MULTIPLICATIVE : AdditiveScaleMode.DIFFERENCE,
                },
                weight: 0.5f,
                time: 1,
            );
        }
        update_scale_playback_pair(&fixture, expected[reverse]);
    }
}

fn void test_animation_scale_playback_two_ratio_actions_have_identical_literal_outputs_in_both_orders() @test {
    float[2] times = { 0, 1 };
    float[6][2] values = { { 2, 4, 8, 4, 2, 16 }, { 1, 1, 1, 2, 3, 4 } };
    for (uint reverse = 0; reverse < 2; reverse++) {
        ScalePlaybackFixture fixture;
        create_scale_playback_fixture(&fixture, { 2, 3, 4 });
        defer destroy_scale_playback_fixture(&fixture);
        ClipId[2] clips;
        for (uint clip = 0; clip < 2; clip++) {
            clips[clip] = scale_playback_clip(
                fixture: &fixture,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: values[clip][..],
            );
        }
        for (uint action = 0; action < 2; action++) {
            (void)play_scale_playback_pair(
                fixture: &fixture,
                clip: clips[reverse ? 1 - action : action],
                desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
                weight: 0.5f,
                time: 1,
            );
        }
        update_scale_playback_pair(&fixture, { 4.5f, 4.5f, 15 });
    }
}

fn void test_animation_scale_playback_reference_uses_time_zero_between_authored_keys() @test {
    float[2] times = { -1, 1 };
    float[6] values = { 2, 4, 8, 4, 8, 16 };
    float[18] cubic = { 0, 0, 0, 2, 4, 8, 1, 2, 4, 1, 2, 4, 4, 8, 16, 0, 0, 0 };
    foreach (Interpolation mode : { Interpolation.LINEAR, Interpolation.CUBIC_SPLINE }) {
        ScalePlaybackFixture fixture;
        create_scale_playback_fixture(&fixture, { 3, 6, 12 });
        defer destroy_scale_playback_fixture(&fixture);
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: mode,
            times: times[..],
            values: mode == Interpolation.CUBIC_SPLINE ? cubic[..] : values[..],
        );
        AnimationActionId[2] actions = play_scale_playback_pair(
            fixture: &fixture,
            clip: clip,
            desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
            weight: 1,
            time: 1,
        );
        float[3] reference_expected = { 3, 6, 12 };
        assert(fixture.ordinary.animator.action(actions[0]).reference == reference_expected[..]);
        assert(fixture.player.action(actions[1]).reference == reference_expected[..]);
        update_scale_playback_pair(&fixture, { 4, 8, 16 });
        fixture.ordinary.animator.action(actions[0]).time = 0;
        fixture.player.action(actions[1]).time = 0;
        update_scale_playback_pair(&fixture, { 3, 6, 12 });
    }
}

fn void test_animation_scale_playback_constant_magnitude_sampling_respects_the_cubic_band() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ScalePlaybackFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 }, &tracker);
    defer destroy_scale_playback_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[3] magnitudes = { 0x1p-149, 0x1.fffffep127, bitcast(0x3f800001u, float) };
    Interpolation[3] modes = { Interpolation.STEP, Interpolation.LINEAR, Interpolation.CUBIC_SPLINE };
    foreach (mode : modes) {
        foreach (magnitude : magnitudes) {
            float[18] cubic = { 0, 0, 0, magnitude, magnitude, magnitude, 0, 0, 0,
                0, 0, 0, magnitude, magnitude, magnitude, 0, 0, 0 };
            float[6] ordinary = { magnitude, magnitude, magnitude, magnitude, magnitude, magnitude };
            ClipId clip = scale_playback_clip(
                fixture: &fixture,
                interpolation: mode,
                times: times[..],
                values: mode == Interpolation.CUBIC_SPLINE ? cubic[..] : ordinary[..],
            );
            if (mode == Interpolation.CUBIC_SPLINE && magnitude == 0x1p-149f) {
                PlaybackView[2] owners = {
                    fixture.ordinary.animator.playback(),
                    anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0]),
                };
                foreach (index, &owner : owners) {
                    ScalePlaybackSnapshot snapshot = snapshot_scale_playback(owner);
                    defer destroy_scale_playback_snapshot(&snapshot);
                    sz acquisitions = tracker.total_allocation_count();
                    PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
                    AnimationActionId? attempt;
                    if (index == 0) {
                        attempt = fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, desc);
                    } else {
                        attempt = fixture.player.play(&fixture.ordinary.assets, clip, desc);
                    }
                    bool rejected;
                    if (catch excuse = attempt) {
                        assert(excuse == c3d::UNSUPPORTED);
                        rejected = true;
                    }
                    assert(rejected && tracker.total_allocation_count() == acquisitions);
                    assert_scale_playback_unchanged(owner, &snapshot);
                }
                fixture.ordinary.assets.remove_clip(clip);
                continue;
            }
            AnimationActionId[2] actions = play_scale_playback_pair(
                fixture: &fixture,
                clip: clip,
                desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
                weight: 0.5f,
                time: 0.5f,
            );
            assert(fixture.ordinary.animator.action(actions[0]).reference[0] == magnitude);
            assert(fixture.player.action(actions[1]).reference[0] == magnitude);
            sz acquisitions = tracker.total_allocation_count();
            update_scale_playback_pair(&fixture, { 2, 3, 4 });
            assert(tracker.total_allocation_count() == acquisitions);
            fixture.ordinary.animator.stop(actions[0])!!;
            fixture.player.stop(actions[1])!!;
            fixture.ordinary.assets.remove_clip(clip);
        }
    }
}

fn void test_animation_scale_playback_both_cubic_zero_samples_are_unsupported_before_mutation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ScalePlaybackFixture fixture;
    create_scale_playback_fixture(&fixture, { 1, 1, 1 }, &tracker);
    defer destroy_scale_playback_fixture(&fixture);
    float[2] constant_times = { 0, 1 };
    float[6] constant_values = { 1, 1, 1, 1, 1, 1 };
    ClipId constant = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: constant_times[..],
        values: constant_values[..],
    );
    (void)play_scale_playback_pair(
        fixture: &fixture,
        clip: constant,
        desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 1,
        time: 0.5f,
    );
    update_scale_playback_pair(&fixture, { 1, 1, 1 });
    for (uint shape = 0; shape < 2; shape++) {
        float[2] times = { 0, 1 };
        if (shape == 0) times[0] = 0x1p-149;
        float value = shape == 0 ? 1.0f : 0x1p-126f;
        float outgoing = shape == 0 ? -4.0f : -bitcast(0x017fffffu, float);
        float incoming = shape == 0 ? 4.0f : 0x1p-124f;
        float[18] values = { 0, 0, 0, value, value, value, outgoing, outgoing, outgoing,
            incoming, incoming, incoming, value, value, value, 0, 0, 0 };
        ClipId unsafe = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.CUBIC_SPLINE,
            times: times[..],
            values: values[..],
        );
        AnimationClip* data = &fixture.ordinary.assets.clip(unsafe).data;
        uint cursor;
        assert(anim::sample_multiplicative_scale(&data.tracks[0], 0.5f, &cursor).x == 0);
        PlaybackView[2] owners = {
            fixture.ordinary.animator.playback(),
            anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0]),
        };
        foreach (index, &owner : owners) {
            ScalePlaybackSnapshot snapshot = snapshot_scale_playback(owner);
            defer destroy_scale_playback_snapshot(&snapshot);
            sz acquisitions = tracker.total_allocation_count();
            bool rejected;
            AnimationActionId? attempt;
            PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
            if (index == 0) {
                attempt = fixture.ordinary.animator.play(&fixture.ordinary.assets, unsafe, desc);
            } else {
                attempt = fixture.player.play(&fixture.ordinary.assets, unsafe, desc);
            }
            if (catch excuse = attempt) {
                assert(excuse == c3d::UNSUPPORTED);
                rejected = true;
            }
            assert(rejected && tracker.total_allocation_count() == acquisitions);
            assert_scale_playback_unchanged(owner, &snapshot);
            update_scale_playback_pair(&fixture, { 1, 1, 1 });
        }
        fixture.ordinary.assets.remove_clip(unsafe);
        for (uint component = 0; component < 3; component++) {
            values[3 + component] = value * 2;
            values[12 + component] = value * 2;
        }
        ClipId supported = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.CUBIC_SPLINE,
            times: times[..],
            values: values[..],
        );
        AnimationActionId[2] actions = play_scale_playback_pair(
            fixture: &fixture,
            clip: supported,
            desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
            weight: 1,
            time: 0.5f,
        );
        data = &fixture.ordinary.assets.clip(supported).data;
        assert(anim::sample_multiplicative_scale(&data.tracks[0], 0.5f, &cursor).x > 0);
        update_scale_playback_pair(&fixture, { 0.5f, 0.5f, 0.5f });
        fixture.ordinary.animator.stop(actions[0])!!;
        fixture.player.stop(actions[1])!!;
        fixture.ordinary.assets.remove_clip(supported);
        update_scale_playback_pair(&fixture, { 1, 1, 1 });
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
        ScalePlaybackFixture fixture;
        create_scale_playback_fixture(&fixture, { 1, 1, 1 });
        defer destroy_scale_playback_fixture(&fixture);
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[sample][..],
        );
        (void)play_scale_playback_pair(
            fixture: &fixture,
            clip: clip,
            desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
            weight: 1,
            time: 1,
        );
        update_scale_playback_pair(&fixture, sample == 2 ? (Vec3){ adjacent, adjacent, adjacent } : (Vec3){ 2, 2, 2 });
    }
}

fn void test_animation_scale_playback_invalid_domains_reject_before_pool_or_allocation_changes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ScalePlaybackFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 }, &tracker);
    defer destroy_scale_playback_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] valid_values = { 2, 4, 8, 4, 2, 16 };
    ClipId valid = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: valid_values[..],
    );
    (void)play_scale_playback_pair(
        fixture: &fixture,
        clip: valid,
        desc: { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 0.5f,
        time: 1,
    );
    update_scale_playback_pair(&fixture, { 3, 2.25f, 6 });
    PlaybackView[2] owners = {
        fixture.ordinary.animator.playback(),
        anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0]),
    };
    for (uint invalid = 0; invalid < 7; invalid++) {
        float[6] ordinary = { 1, 1, 1, 1, 1, 1 };
        float tangent = invalid == 5 ? -4 : -8;
        float[18] cubic = { 0, 0, 0, 1, 1, 1, tangent, tangent, tangent,
            -tangent, -tangent, -tangent, 1, 1, 1, 0, 0, 0 };
        switch (invalid) {
            case 0: ordinary[0] = 0;
            case 1: ordinary[3] = -1;
            case 2: ordinary[0] = float::nan;
            case 3: ordinary[3] = float::inf;
            case 4: ordinary[3] = -1;
            case 5:
            case 6:
        }
        ClipId clip = scale_playback_clip(
            fixture: &fixture,
            interpolation: invalid >= 5 ? Interpolation.CUBIC_SPLINE
              : (invalid == 4 ? Interpolation.LINEAR : Interpolation.STEP),
            times: times[..],
            values: invalid >= 5 ? cubic[..] : ordinary[..],
        );
        foreach (index, &owner : owners) {
            ScalePlaybackSnapshot snapshot = snapshot_scale_playback(owner);
            defer destroy_scale_playback_snapshot(&snapshot);
            sz acquisitions = tracker.total_allocation_count();
            bool rejected;
            AnimationActionId? attempt;
            PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
            if (index == 0) {
                attempt = fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, desc);
            } else {
                attempt = fixture.player.play(&fixture.ordinary.assets, clip, desc);
            }
            if (catch excuse = attempt) {
                assert(excuse == c3d::INVALID_ARGUMENT);
                rejected = true;
            }
            assert(rejected);
            assert_scale_playback_unchanged(owner, &snapshot);
            assert(tracker.total_allocation_count() == acquisitions);
            update_scale_playback_pair(&fixture, { 3, 2.25f, 6 });
        }
        fixture.ordinary.assets.remove_clip(clip);
    }
}

fn void test_animation_scale_playback_target_allocation_failures_restore_both_owners() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ScalePlaybackAllocator allocator = { .backing = &tracker, .remaining = sz::max };
    ScalePlaybackFixture fixture;
    create_scale_playback_fixture(&fixture, { 2, 3, 4 }, &allocator);
    defer destroy_scale_playback_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] values = { 2, 4, 8, 4, 2, 16 };
    ClipId clip = scale_playback_clip(
        fixture: &fixture,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    );
    WeightedJointMask mask = scale_playback_weighted_mask(&fixture, 0.5f);
    defer anim::destroy_weighted_joint_mask(&mask);
    PlaybackView[2] owners = {
        fixture.ordinary.animator.playback(),
        anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0]),
    };
    foreach (index, &owner : owners) {
        ScalePlaybackSnapshot snapshot = snapshot_scale_playback(owner);
        defer destroy_scale_playback_snapshot(&snapshot);
        for (sz allowance = 0; allowance < 3; allowance++) {
            allocator.remaining = allowance;
            sz outstanding = allocator.outstanding;
            AnimationActionId? attempt;
            PlayDesc desc = {
                .additive = true,
                .weighted_mask = &mask,
                .additive_scale = AdditiveScaleMode.MULTIPLICATIVE,
            };
            if (index == 0) {
                attempt = fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, desc);
            } else {
                attempt = fixture.player.play(&fixture.ordinary.assets, clip, desc);
            }
            bool rejected;
            if (catch excuse = attempt) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
                rejected = true;
            }
            assert(rejected && allocator.outstanding == outstanding);
            assert_scale_playback_unchanged(owner, &snapshot);
        }
    }
    allocator.remaining = sz::max;
    sz before = tracker.allocated();
    AnimationActionId[2] actions = play_scale_playback_pair(
        fixture: &fixture,
        clip: clip,
        desc: { .additive = true, .weighted_mask = &mask, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE },
        weight: 1,
        time: 1,
    );
    sz retained_each = (sz)(uint::size + 3 * float::size + mask.nodes.len * float::size);
    assert(tracker.allocated() == before + 2 * retained_each);
    sz acquisitions = allocator.acquisitions;
    update_scale_playback_pair(&fixture, { 3, 2.25f, 6 });
    assert(allocator.acquisitions == acquisitions);
    fixture.ordinary.animator.stop(actions[0])!!;
    fixture.player.stop(actions[1])!!;
    assert(tracker.allocated() == before);
}
