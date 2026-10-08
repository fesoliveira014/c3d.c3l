module c3d_audio_test;

import c3d;
import c3d::asset;
import c3d::audio;
import c3d::scene;
import std::math;

const uint MIX_FRAMES @local = 1024;
const uint DRAIN_FRAMES @local = 25000; // past the end of a 0.5 s clip
const uint STEADY_ITERATIONS @local = 100;
const uint STEADY_FRAMES @local = 256; // 100 iterations cover 0.53 s: several loops of a 0.1 s clip
const float AUDIBLE @local = 0.05f;
const float SILENT @local = 1e-6f;
const float REPLACED_PEAK @local = 0.25f;
const float RMS_RATIO_TOLERANCE @local = 0.1f;
const float NEAR_DISTANCE @local = 2;
const float FAR_DISTANCE @local = 4;
const float PEAK_TOLERANCE @local = 0.02f; // the first frames of a spatial voice ramp for SMOOTHING_FRAMES

fn Node* add_emitter(
    Scene* scene,
    AudioClipId clip,
    bool looping,
    bool playing = true,
) @local {
    Node* node = scene.add_node()!!;
    AudioEmitter emitter = audio::AUDIO_EMITTER_DEFAULT;
    emitter.clip = clip;
    emitter.looping = looping;
    emitter.playing = playing;
    scene.add(node, emitter);
    return node;
}

fn float mixed_peak(AudioSystem* system, uint frames = MIX_FRAMES, uint skip = 0) @local {
    float[] buffer = mix_frames(system, frames);
    defer alloc::free(mem, buffer.ptr);
    return math::max(peak(buffer, system.channels, 0, skip), peak(buffer, system.channels, 1, skip));
}

fn void test_emitter_start_stop_and_end() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    Node* node = add_emitter(&scene, clip, true);
    system.update(&scene);
    assert(mixed_peak(&system) > AUDIBLE);

    scene.get(node, AudioEmitter).playing = false;
    system.update(&scene);
    assert(system.stats().voices == 0);
    assert(mixed_peak(&system) < SILENT);

    AudioEmitter* emitter = scene.get(node, AudioEmitter);
    emitter.looping = false;
    emitter.playing = true;
    system.update(&scene);
    assert(mixed_peak(&system) > AUDIBLE);
    drain(&system, DRAIN_FRAMES);
    system.update(&scene);
    assert(!scene.get(node, AudioEmitter).playing);
    assert(system.stats().voices == 0);
}

fn void test_removing_emitter_stops_voice() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    Node* first = add_emitter(&scene, clip, true);
    Node* second = add_emitter(&scene, clip, true);
    system.update(&scene);
    assert(system.stats().voices == 2);

    scene.remove(first);
    assert(system.stats().voices == 1);
    scene.remove_component(second, AudioEmitter);
    assert(system.stats().voices == 0);
    assert(mixed_peak(&system) < SILENT);
}

fn void test_steady_state_allocates_nothing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = make_store(mem);
        defer asset::destroy_asset_store(&assets);
        AudioSystem system = make_system(&tracker, &assets);
        defer audio::destroy_audio_system(&system);
        Scene scene = make_scene(mem, &system);
        defer scene::destroy_scene(&scene);

        AudioClipId decoded = make_clip(&assets, seconds: 0.1, mode: AudioClipMode.DECODED);
        AudioClipId ogg = audio::add_audio_clip(&assets, $embed("fixtures/tone.ogg"), AudioClipMode.STREAMED)!!;
        AudioClipId mp3 = audio::add_audio_clip(&assets, $embed("fixtures/tone.mp3"), AudioClipMode.STREAMED)!!;
        add_emitter(&scene, decoded, true);
        add_emitter(&scene, ogg, true);
        add_emitter(&scene, mp3, true);
        system.update(&scene);
        assert(system.stats().voices == 3);

        sz allocations = tracker.total_allocation_count();
        for (uint iteration = 0; iteration < STEADY_ITERATIONS; iteration++) {
            system.update(&scene);
            float[STEADY_FRAMES * CHANNELS] frames;
            system.mix(frames[..]);
            assert(system.stats().voices == 3);
        }
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(tracker.allocated() == 0);
}

fn void test_voice_cap_refuses() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets, 2);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    system.play(clip, audio::EFFECTS_BUS)!!;
    system.play(clip, audio::EFFECTS_BUS)!!;
    if (catch excuse = system.play(clip, audio::EFFECTS_BUS)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        unreachable("a third voice started");
    }

    add_emitter(&scene, clip, false);
    system.update(&scene);
    assert(system.stats().voices_refused == 1);

    drain(&system, DRAIN_FRAMES);
    system.update(&scene);
    assert(system.stats().voices == 0);

    AudioClipId removed = make_clip(&assets, 220);
    add_emitter(&scene, removed, false);
    audio::remove_audio_clip(&assets, removed);
    system.update(&scene);
    assert(system.stats().voices_refused == 1);
    assert(system.stats().start_failures == 1);
}

fn void test_replaced_clip_restarts_looping_emitter() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets, 440, 0.5f);

    add_emitter(&scene, clip, true);
    system.update(&scene);
    system.play(clip, audio::EFFECTS_BUS)!!;
    assert(system.stats().voices == 2);
    assert(mixed_peak(&system) > AUDIBLE);

    char[] replacement = make_wav(
        allocator: mem,
        frequency: 330,
        amplitude: 0.25f,
        seconds: 0.5,
    );
    defer alloc::free(mem, replacement.ptr);
    audio::replace_audio_clip(&assets, clip, replacement)!!;
    system.update(&scene);
    assert(system.stats().voices == 1);
    assert(system.stats().mirrors == 1);
    assert(math::abs(mixed_peak(&system, MIX_FRAMES, SMOOTHING_FRAMES) - REPLACED_PEAK) <= PEAK_TOLERANCE);
}

fn void test_removed_clip_is_safe() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    system.play(clip, audio::EFFECTS_BUS)!!;
    audio::remove_audio_clip(&assets, clip);
    assert(mixed_peak(&system) > AUDIBLE);

    system.update(&scene);
    assert(system.stats().voices == 0);
    assert(system.stats().mirrors == 0);
}

fn void test_listener_selection() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    system.update(&scene);
    assert(system.stats().listeners == 0);
    system.play_at(clip, audio::EFFECTS_BUS, { 0, 0, -2 })!!;
    assert(mixed_peak(&system) > AUDIBLE);

    Node* first = scene.add_node()!!;
    Node* second = scene.add_node()!!;
    scene.add(first, (AudioListener){ .active = true });
    scene.add(second, (AudioListener){ .active = true });
    system.update(&scene);
    assert(system.stats().listeners == 2);
}

fn float one_shot_rms(float distance, float shift) @local {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    AudioClipId clip = make_clip(&assets);

    system.play_at(clip, audio::EFFECTS_BUS, { 0, 0, -distance })!!;
    system.shift_origin({ 0, 0, -shift });
    float[] frames = mix_frames(&system, MIX_FRAMES);
    defer alloc::free(mem, frames.ptr);
    return mono_rms(frames, system.channels);
}

fn float shifted_emitter_rms(float distance, float shift) @local {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    AudioClipId clip = make_clip(&assets);

    Node* node = add_emitter(&scene, clip, true);
    node.local.position = { 0, 0, -distance };
    scene.update_world();
    system.update(&scene);
    scene.shift_origin({ 0, 0, -shift });
    system.shift_origin({ 0, 0, -shift });
    scene.update_world();
    system.update(&scene);
    float[] frames = mix_frames(&system, MIX_FRAMES);
    defer alloc::free(mem, frames.ptr);
    return mono_rms(frames, system.channels);
}

fn void test_shift_origin_moves_positioned_one_shots() @test {
    float near = one_shot_rms(NEAR_DISTANCE, 0);
    float far = one_shot_rms(FAR_DISTANCE, 0);
    float shifted = one_shot_rms(FAR_DISTANCE, FAR_DISTANCE - NEAR_DISTANCE);
    assert(far > 0);
    assert(math::abs(near / far - 2.0f) <= RMS_RATIO_TOLERANCE);
    assert(math::abs(shifted / near - 1.0f) <= RMS_RATIO_TOLERANCE);

    float emitter = shifted_emitter_rms(FAR_DISTANCE, FAR_DISTANCE - NEAR_DISTANCE);
    assert(math::abs(emitter / near - 1.0f) <= RMS_RATIO_TOLERANCE);
}
