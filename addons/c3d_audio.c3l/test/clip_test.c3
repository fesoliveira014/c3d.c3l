module c3d_audio_test;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::audio;
import std::math;

const uint FORMAT_FRAMES @local = 24000;
const char NOISE_BYTE @local = 0x55;
const usz NOISE_BYTES @local = 64;
const uint CLIP_CAPACITY @local = 4;
const sz PATH_BYTES @local = 32;

struct MemorySource @local {
    String path;
    char[] bytes;
    char[PATH_BYTES] requested;
    sz requested_length;
}

fn char[]? read_memory(void* user, Allocator allocator, String path) @local {
    MemorySource* source = user;
    source.requested_length = math::min(path.len, PATH_BYTES);
    mem::copy(&source.requested, path.ptr, source.requested_length);
    if (path != source.path) return c3d::ASSET_IO_ERROR~;
    char[] copy = alloc::new_array(allocator, char, (sz)source.bytes.len);
    mem::copy(copy.ptr, source.bytes.ptr, source.bytes.len);
    return copy;
}

fn void test_clip_probes_format() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = make_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[] wav = make_wav(
            allocator: mem,
            frequency: 440,
            amplitude: 0.5f,
            seconds: 0.5,
        );
        defer alloc::free(mem, wav.ptr);
        AudioClipId id = audio::add_audio_clip(&assets, wav)!!;
        AudioClipAsset* clip = assets.pool(AudioClip).get(id);
        assert(assets.pool(AudioClip).is_live(id));
        assert(clip.data.frame_count == FORMAT_FRAMES);
        assert(clip.data.channels == 1);
        assert(clip.data.sample_rate == SAMPLE_RATE);

        char[] original = alloc::new_array(mem, char, (sz)wav.len);
        defer alloc::free(mem, original.ptr);
        mem::copy(original.ptr, wav.ptr, wav.len);
        wav[..] = 0;
        assert(clip.data.bytes.ptr != wav.ptr);
        assert(clip.data.bytes == original);
    }
    assert(tracker.allocated() == 0);
}

fn void test_clip_rejects_bad_bytes() @test {
    AssetStore assets = make_store(mem, CLIP_CAPACITY);
    defer asset::destroy_asset_store(&assets);

    if (catch excuse = audio::add_audio_clip(&assets, {})) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        unreachable("empty bytes were accepted");
    }
    char[NOISE_BYTES] noise = { [0..NOISE_BYTES - 1] = NOISE_BYTE };
    if (catch excuse = audio::add_audio_clip(&assets, noise[..])) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
    } else {
        unreachable("noise was accepted");
    }
    assert(assets.pool(AudioClip).free_count == CLIP_CAPACITY);
}

fn void test_clip_loads_through_file_source() @test {
    char[] wav = make_wav(
        allocator: mem,
        frequency: 440,
        amplitude: 0.5f,
        seconds: 0.1,
    );
    defer alloc::free(mem, wav.ptr);
    MemorySource source = { .path = "sfx/tone.wav", .bytes = wav };
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.file_source = { .read = &read_memory, .user = &source };
    AssetStore assets = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&assets);
    audio::register_audio_clips(&assets, CLIP_CAPACITY)!!;

    AudioClipId id = audio::load_audio_clip(&assets, "sfx/tone.wav", key: "tone")!!;
    assert((String)source.requested[:source.requested_length] == "sfx/tone.wav");
    assert(assets.pool(AudioClip).is_live(id));
    assert(c3d::same_id(asset::custom_id(AudioClip, assets.find("tone")!!)!!, id));
}
