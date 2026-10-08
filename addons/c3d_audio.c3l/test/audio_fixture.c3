module c3d_audio_test;

import c3d;
import c3d::asset;
import c3d::audio;
import c3d::scene;
import std::math;

const uint SAMPLE_RATE = 48000;
const uint CHANNELS = 2;
const usz WAV_HEADER_BYTES = 44;
const uint WAV_FORMAT_PCM = 1;
const uint WAV_FORMAT_BYTES = 16;
const uint WAV_BITS = 16;
const float PCM16_SCALE = 32767;
const uint SMOOTHING_FRAMES = 512; // gain smoothing runs for 384 frames after a start or a spatial change

fn void put_u16(char[] bytes, usz offset, uint value) {
    bytes[offset] = (char)(value & 0xff);
    bytes[offset + 1] = (char)((value >> 8) & 0xff);
}

fn void put_u32(char[] bytes, usz offset, uint value) {
    put_u16(bytes, offset, value & 0xffff);
    put_u16(bytes, offset + 2, value >> 16);
}

fn void put_tag(char[] bytes, usz offset, String tag) {
    mem::copy(&bytes[offset], tag.ptr, tag.len);
}

<*
 Mono 16-bit PCM WAV of a sine, 48 kHz.
*>
fn char[] make_wav(
    Allocator allocator,
    float frequency,
    float amplitude,
    double seconds,
) {
    uint frames = (uint)(SAMPLE_RATE * seconds);
    uint data_bytes = frames * 2;
    char[] bytes = alloc::new_array(allocator, char, (sz)(WAV_HEADER_BYTES + data_bytes));
    put_tag(bytes, 0, "RIFF");
    put_u32(bytes, 4, (uint)WAV_HEADER_BYTES - 8 + data_bytes);
    put_tag(bytes, 8, "WAVEfmt ");
    put_u32(bytes, 16, WAV_FORMAT_BYTES);
    put_u16(bytes, 20, WAV_FORMAT_PCM);
    put_u16(bytes, 22, 1);
    put_u32(bytes, 24, SAMPLE_RATE);
    put_u32(bytes, 28, SAMPLE_RATE * 2);
    put_u16(bytes, 32, 2);
    put_u16(bytes, 34, WAV_BITS);
    put_tag(bytes, 36, "data");
    put_u32(bytes, 40, data_bytes);
    for (uint frame = 0; frame < frames; frame++) {
        float phase = 2 * (float)math::PI * frequency * frame / SAMPLE_RATE;
        short sample = (short)(amplitude * PCM16_SCALE * math::sin(phase));
        put_u16(bytes, WAV_HEADER_BYTES + (usz)frame * 2, (uint)(ushort)sample);
    }
    return bytes;
}

fn AssetStore make_store(Allocator allocator, uint clip_capacity = 8) {
    AssetStore assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    audio::register_audio_clips(&assets, clip_capacity)!!;
    return assets;
}

fn AudioSystem make_system(Allocator allocator, AssetStore* assets, uint max_voices = 16) {
    AudioDesc desc = audio::default_audio_desc();
    desc.null_device = true;
    desc.max_voices = max_voices;
    return audio::create_audio_system(allocator, assets, desc)!!;
}

<*
 Add a sine clip; the WAV is freed after the copy.
*>
fn AudioClipId make_clip(
    AssetStore* assets,
    float frequency = 440,
    float amplitude = 0.5f,
    double seconds = 0.5,
    AudioClipMode mode = AudioClipMode.AUTO,
) {
    char[] wav = make_wav(
        allocator: mem,
        frequency: frequency,
        amplitude: amplitude,
        seconds: seconds,
    );
    defer alloc::free(mem, wav.ptr);
    return audio::add_audio_clip(assets, wav, mode)!!;
}

fn Scene make_scene(Allocator allocator, AudioSystem* system, uint nodes = 8) {
    Scene scene = scene::create_scene(allocator, { .max_nodes = nodes });
    audio::register_audio(&scene, system)!!;
    scene.update_world();
    return scene;
}

fn float[] mix_frames(AudioSystem* system, uint frames) {
    float[] buffer = alloc::new_array(mem, float, (sz)(frames * system.channels));
    system.mix(buffer);
    return buffer;
}

fn void drain(AudioSystem* system, uint frames) {
    float[] buffer = mix_frames(system, frames);
    alloc::free(mem, buffer.ptr);
}

fn float peak(
    float[] frames,
    uint channels,
    uint channel,
    uint skip = 0,
) {
    float result;
    for (usz index = skip; index < frames.len / channels; index++) {
        result = math::max(result, math::abs(frames[index * channels + channel]));
    }
    return result;
}

fn float mono_rms(float[] frames, uint channels, uint skip = SMOOTHING_FRAMES) {
    double sum;
    usz count = frames.len / channels - skip;
    for (usz index = skip; index < frames.len / channels; index++) {
        float mono;
        for (uint channel = 0; channel < channels; channel++) mono += frames[index * channels + channel];
        sum += (double)(mono * mono);
    }
    return (float)math::sqrt(sum / count);
}
