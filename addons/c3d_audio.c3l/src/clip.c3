module c3d::audio;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import ma;

<*
 Clip kind capacity and mirror slots per system.
*>
const uint DEFAULT_MAX_CLIPS = 256; // one pool record and one mirror slot each

<*
 Encoded size at which AUTO clips stream instead of decoding.
*>
const usz DEFAULT_STREAM_THRESHOLD_BYTES = 1024 * 1024; // music, not effects

<*
 How a clip plays: decoded once into PCM, or decoded while playing.
*>
enum AudioClipMode {
    AUTO,
    DECODED,
    STREAMED,
}

<*
 Encoded sound; the format is probed when added.
*>
struct AudioClip {
    char[]        bytes; // store allocator
    AudioClipMode mode;
    ulong         frame_count;
    uint          channels;
    uint          sample_rate;
}

<*
 Clip handle in the asset store.
*>
alias AudioClipId = CustomId{AudioClip};

<*
 Clip record in the asset store.
*>
alias AudioClipAsset = CustomAsset{AudioClip};

struct ClipFormat @private {
    ulong frame_count;
    uint  channels;
    uint  sample_rate;
}

<*
 Register the clip kind with the store.
 @param [&inout] assets : "No clip registration has occurred in this store."
 @return? c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn void? register_audio_clips(AssetStore* assets, uint capacity = DEFAULT_MAX_CLIPS) {
    assets.register(AudioClip, capacity, &free_audio_clip_payload)!;
}

<*
 Add a clip, copying the encoded bytes and probing the format.
 @param [&inout] assets : "Clip kind registered."
 @param bytes : "WAV, FLAC, MP3 or Ogg Vorbis; copied."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
*>
fn AudioClipId? add_audio_clip(
    AssetStore* assets,
    char[] bytes,
    AudioClipMode mode = AUTO,
    String key = "",
) {
    if (!bytes.len) return c3d::INVALID_ARGUMENT~;
    ClipFormat format = probe_clip(assets.allocator, bytes)!;
    asset::check_key(assets, key)!;
    CustomPool{AudioClip}* pool = assets.pool(AudioClip);
    AudioClipId id = pool.add({})!;
    *pool.get(id) = {
        .header = { .key = asset::copy_string(assets.allocator, key), .revision = 1 },
        .data   = clip_payload(assets.allocator, bytes, mode, format),
    };
    asset::register_key(assets, key, asset::custom_ref(AudioClip, id));
    return id;
}

<*
 Read a clip through the store's file source.
 @param [&inout] assets : "Clip kind registered."
 @return? c3d::ASSET_IO_ERROR, c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
*>
fn AudioClipId? load_audio_clip(
    AssetStore* assets,
    String path,
    AudioClipMode mode = AUTO,
    String key = "",
) {
    char[] bytes = assets.read_file(assets.allocator, path)!;
    defer alloc::free(assets.allocator, bytes.ptr);
    return add_audio_clip(assets, bytes, mode, key);
}

<*
 Replace the encoded bytes and advance the revision.
 @param [&inout] assets : "Clip kind registered."
 @param bytes : "WAV, FLAC, MP3 or Ogg Vorbis; copied."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR
 @require assets.pool(AudioClip).is_live(clip)
*>
fn void? replace_audio_clip(
    AssetStore* assets,
    AudioClipId clip,
    char[] bytes,
    AudioClipMode mode = AUTO,
) {
    if (!bytes.len) return c3d::INVALID_ARGUMENT~;
    ClipFormat format = probe_clip(assets.allocator, bytes)!;
    AudioClipAsset* record = assets.pool(AudioClip).get(clip);
    alloc::free(assets.allocator, record.data.bytes.ptr);
    record.data = clip_payload(assets.allocator, bytes, mode, format);
    record.header.revision++;
    record.header.replaced_revision = record.header.revision;
}

<*
 Free the clip and make its id stale; systems drop their mirror at the next update.
 @param [&inout] assets : "Clip kind registered."
 @require assets.pool(AudioClip).is_live(clip)
*>
fn void remove_audio_clip(AssetStore* assets, AudioClipId clip) {
    CustomPool{AudioClip}* pool = assets.pool(AudioClip);
    AudioClipAsset* record = pool.get(clip);
    asset::forget_key(assets, record.header.key);
    asset::free_string(assets.allocator, record.header.key);
    alloc::free(assets.allocator, record.data.bytes.ptr);
    *record = {};
    pool.remove(clip);
}

fn void free_audio_clip_payload(Allocator allocator, void* data, void* user) @private {
    alloc::free(allocator, ((AudioClip*)data).bytes.ptr);
}

fn AudioClip clip_payload(
    Allocator allocator,
    char[] bytes,
    AudioClipMode mode,
    ClipFormat format,
) @private {
    char[] copy = alloc::new_array(allocator, char, (sz)bytes.len);
    mem::copy(copy.ptr, bytes.ptr, bytes.len);
    return {
        .bytes       = copy,
        .mode        = mode,
        .frame_count = format.frame_count,
        .channels    = format.channels,
        .sample_rate = format.sample_rate,
    };
}

fn ClipFormat? probe_clip(Allocator allocator, char[] bytes) @private {
    ma::Decoder* decoder = (ma::Decoder*)alloc::malloc(allocator, (sz)ma::decoder_size());
    defer alloc::free(allocator, decoder);
    ma::Result opened = ma::decoder_init_memory(
        bytes: bytes.ptr,
        length: bytes.len,
        callbacks: null,
        decoder: decoder,
    );
    if (opened != ma::SUCCESS) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    defer (void)ma::decoder_uninit(decoder);
    ClipFormat format;
    ma::Format sample_format;
    ulong length;
    ma::Result result = ma::decoder_get_data_format(
        decoder: decoder,
        format: &sample_format,
        channels: &format.channels,
        sample_rate: &format.sample_rate,
        channel_map: null,
        channel_map_capacity: 0,
    );
    if (result != ma::SUCCESS
        || ma::decoder_get_length_in_pcm_frames(decoder, &length) != ma::SUCCESS
        || !length
        || !format.channels
        || !format.sample_rate) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    format.frame_count = length;
    return format;
}
