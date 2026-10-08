module c3d_audio_test;

import c3d;
import c3d::asset;
import c3d::audio;
import c3d::scene;
import std::math;

const uint MIX_FRAMES @local = 1024;
const uint DRAIN_FRAMES @local = 25000; // past the end of a 0.5 s clip
const float FLAT_PEAK @local = 0.5f;
const float PEAK_TOLERANCE @local = 0.02f;
const float RMS_RATIO_TOLERANCE @local = 0.1f;
const float STREAM_TOLERANCE @local = 1e-4f;
const float NEAR_DISTANCE @local = 2;
const float FAR_DISTANCE @local = 4;

fn float distance_rms(float distance) @local {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    Scene scene = make_scene(mem, &system);
    defer scene::destroy_scene(&scene);

    Node* listener = scene.add_node()!!;
    scene.add(listener, (AudioListener){ .active = true });
    scene.update_world();
    system.update(&scene);

    AudioClipId clip = make_clip(&assets);
    system.play_at(clip, audio::EFFECTS_BUS, { 0, 0, -distance })!!;
    float[] frames = mix_frames(&system, MIX_FRAMES);
    defer alloc::free(mem, frames.ptr);
    return mono_rms(frames, system.channels);
}

fn void test_flat_play_mixes_at_bus_gain() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    AudioClipId clip = make_clip(&assets);

    system.play(clip, audio::EFFECTS_BUS)!!;
    float[] first = mix_frames(&system, MIX_FRAMES);
    defer alloc::free(mem, first.ptr);
    for (uint channel = 0; channel < system.channels; channel++) {
        assert(math::abs(peak(first, system.channels, channel) - FLAT_PEAK) <= PEAK_TOLERANCE);
    }

    // The first voice plays out so the second measurement hears one voice.
    drain(&system, DRAIN_FRAMES);
    system.set_bus_volume(audio::EFFECTS_BUS, 0.5f);
    system.play(clip, audio::EFFECTS_BUS)!!;
    float[] second = mix_frames(&system, MIX_FRAMES);
    defer alloc::free(mem, second.ptr);
    for (uint channel = 0; channel < system.channels; channel++) {
        assert(math::abs(peak(second, system.channels, channel) - FLAT_PEAK * 0.5f) <= PEAK_TOLERANCE);
    }
}

fn void test_distance_attenuates_inverse() @test {
    float near = distance_rms(NEAR_DISTANCE);
    float far = distance_rms(FAR_DISTANCE);
    assert(far > 0);
    assert(math::abs(near / far - 2.0f) <= RMS_RATIO_TOLERANCE);
}

fn void test_streamed_matches_decoded() @test {
    AssetStore assets = make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioClipId decoded = make_clip(&assets, mode: AudioClipMode.DECODED);
    AudioClipId streamed = make_clip(&assets, mode: AudioClipMode.STREAMED);

    AudioSystem decoded_system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&decoded_system);
    AudioSystem streamed_system = make_system(mem, &assets);
    defer audio::destroy_audio_system(&streamed_system);
    decoded_system.play(decoded, audio::EFFECTS_BUS)!!;
    streamed_system.play(streamed, audio::EFFECTS_BUS)!!;

    float[] first = mix_frames(&decoded_system, 512);
    defer alloc::free(mem, first.ptr);
    float[] second = mix_frames(&streamed_system, 512);
    defer alloc::free(mem, second.ptr);
    assert(peak(first, decoded_system.channels, 0) > 0);
    foreach (index, sample : first) {
        assert(math::abs(sample - second[index]) <= STREAM_TOLERANCE);
    }
}

fn void test_destroy_releases_everything() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = make_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        AudioSystem system = make_system(&tracker, &assets);
        AudioClipId played = make_clip(&assets, mode: AudioClipMode.DECODED);
        AudioClipId prepared = make_clip(&assets, 880, mode: AudioClipMode.STREAMED);
        system.play(played, audio::EFFECTS_BUS)!!;
        system.prepare(prepared)!!;
        assert(system.stats().voices == 1);
        assert(system.stats().mirrors == 2);
        audio::destroy_audio_system(&system);
        assert(system.state == null);
    }
    assert(tracker.allocated() == 0);
}
