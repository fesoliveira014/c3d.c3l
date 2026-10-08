module c3d::audio;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;
import ma;
import std::math;

<*
 Index of a bus named at creation; zero is the master.
*>
typedef BusId = inline uint;

<*
 Master bus; the engine endpoint.
*>
const BusId MASTER_BUS = (BusId)0;

<*
 Music bus of default_audio_desc.
*>
const BusId MUSIC_BUS = (BusId)1;

<*
 Effects bus of default_audio_desc.
*>
const BusId EFFECTS_BUS = (BusId)2;

<*
 Ambience bus of default_audio_desc.
*>
const BusId AMBIENCE_BUS = (BusId)3;

<*
 Interface bus of default_audio_desc.
*>
const BusId UI_BUS = (BusId)4;

<*
 Voice slots per system.
*>
const uint DEFAULT_MAX_VOICES = 64; // two miniaudio heap blocks per playing voice; the mixer's cost lever

const uint NULL_DEVICE_SAMPLE_RATE @private = 48000;
const uint DEFAULT_CHANNELS @private = 2;
const uint NO_VOICE @private = uint::max;
const float ROLLOFF @private = 1;
const float NO_DOPPLER @private = 0;

<*
 Device, buses and capacities of an audio system.
*>
struct AudioDesc {
    bool     null_device;            // no output; mix pulls frames on the owner thread
    uint     sample_rate;            // zero takes the device rate (48000 with no device)
    uint     channels;               // zero means 2
    String[] buses;                  // names; index zero is the master
    uint     max_voices;
    usz      stream_threshold_bytes; // AUTO clips at or above this encoded size stream
}

<*
 Counters of the last update.
*>
struct AudioStats {
    uint voices;         // playing
    uint voices_refused; // emitter starts without a free voice, since creation
    uint start_failures; // emitter starts that failed for another reason, since creation
    uint listeners;      // active listeners seen; the first in component order is used
    uint mirrors;        // clips with a decoded or copied mirror
}

<*
 Running audio system, held by value.
 Everything miniaudio or a scene hook points to lives in heap storage behind state.
*>
struct AudioSystem {
    AudioState* state;
    uint        channels;
    uint        sample_rate;
    uint        bus_count;
    bool        null_device;
}

struct Voice @private {
    ma::Sound* sound;
    void*      source;
    uint       mirror;
    Entity     owner;    // zero for a one-shot
    Vec3       position; // world position at start, moved by shift_origin
    bool       positioned;
    bool       active;
    bool       decoded;
}

struct Mirror @private {
    AudioClipId clip;
    uint        revision;
    bool        built;
    bool        streamed;
    float[]     pcm;   // decoded: interleaved f32 at the clip's channels and rate
    char[]      bytes; // streamed: copy of the encoded bytes
    ulong       frame_count;
    uint        channels;
    uint        sample_rate;
}

struct AudioState @private {
    Allocator               allocator; // callbacks.user points here
    ma::AllocationCallbacks callbacks;
    AssetStore*             assets;
    ulong                   scene_identity; // Scene.identity of the one registered scene; survives moving the scene
    usz                     stream_threshold_bytes;
    char[]                  storage;
    ma::Engine*             engine;
    char*                   groups;
    usz                     group_stride;
    Voice[]                 voices;
    Mirror[]                mirrors;
    uint                    bus_count;
    uint                    voice_count;
    uint                    mirror_count;
    uint                    listeners;
    uint                    voices_refused;
    uint                    start_failures;
}

struct StartParams @private {
    BusId  bus;
    float  volume;
    float  pitch;
    bool   positioned;
    Vec3   position;
    float  min_distance;
    float  max_distance;
    bool   looping;
    Entity owner;
}

<*
 Default buses and capacities with a real device.
*>
fn AudioDesc default_audio_desc() {
    static String[5] names = { "master", "music", "effects", "ambience", "ui" };
    return {
        .buses                  = names[..],
        .max_voices             = DEFAULT_MAX_VOICES,
        .stream_threshold_bytes = DEFAULT_STREAM_THRESHOLD_BYTES,
    };
}

<*
 Create the device, buses, voice table and mirror table.
 @param [&in] assets : "Clip kind registered; outlives the system."
 @return? c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require desc.buses.len > 0, desc.max_voices > 0
*>
fn AudioSystem? create_audio_system(Allocator allocator, AssetStore* assets, AudioDesc desc) {
    check_bus_names(desc.buses)!;
    if (ma::object_alignment() > mem::DEFAULT_MEM_ALIGNMENT) return c3d::UNSUPPORTED~;

    uint bus_count = (uint)desc.buses.len;
    usz sound_stride = ma::stride(ma::sound_size());
    usz source_stride = ma::stride(max(ma::decoder_size(), ma::audio_buffer_size()));
    usz engine_bytes = ma::stride(ma::engine_size());
    usz group_bytes = sound_stride * ((usz)bus_count - 1);
    usz voice_bytes = (sound_stride + source_stride) * desc.max_voices;

    AudioState* state = alloc::new(allocator, AudioState);
    defer catch alloc::free(allocator, state);
    state.allocator = allocator;
    state.callbacks = {
        .user       = &state.allocator,
        .on_malloc  = &allocate_block,
        .on_realloc = &reallocate_block,
        .on_free    = &free_block,
    };
    state.assets = assets;
    state.stream_threshold_bytes = desc.stream_threshold_bytes;
    state.bus_count = bus_count;
    state.group_stride = sound_stride;
    state.storage = alloc::new_array(allocator, char, (sz)(engine_bytes + group_bytes + voice_bytes));
    defer catch alloc::free(allocator, state.storage.ptr);
    state.engine = (ma::Engine*)state.storage.ptr;
    state.groups = state.storage.ptr + engine_bytes;
    state.voices = alloc::new_array(allocator, Voice, desc.max_voices);
    defer catch alloc::free(allocator, state.voices.ptr);
    state.mirrors = alloc::new_array(allocator, Mirror, (sz)assets.pool(AudioClip).items.len);
    defer catch alloc::free(allocator, state.mirrors.ptr);

    char* sounds = state.groups + group_bytes;
    char* sources = sounds + sound_stride * desc.max_voices;
    foreach (index, &voice : state.voices) {
        voice.sound = (ma::Sound*)(sounds + sound_stride * (usz)index);
        voice.source = sources + source_stride * (usz)index;
    }

    uint channels = desc.channels ?: DEFAULT_CHANNELS;
    uint sample_rate = desc.sample_rate;
    if (desc.null_device && !sample_rate) sample_rate = NULL_DEVICE_SAMPLE_RATE;
    ma::Result engine_result = ma::engine_init(
        engine: state.engine,
        channels: channels,
        sample_rate: sample_rate,
        no_device: desc.null_device,
        callbacks: &state.callbacks,
    );
    if (engine_result != ma::SUCCESS) return c3d::UNSUPPORTED~;
    defer catch ma::engine_uninit(state.engine);
    ma::engine_listener_set_world_up(
        engine: state.engine,
        listener_index: 0,
        x: 0,
        y: 1,
        z: 0,
    );

    uint groups_made;
    defer catch {
        for (uint index = 0; index < groups_made; index++) ma::sound_group_uninit(state.group(index + 1));
    }
    for (uint bus = 1; bus < bus_count; bus++) {
        ma::Result result = ma::sound_group_init(
            engine: state.engine,
            flags: ma::SOUND_FLAG_NO_SPATIALIZATION,
            parent: null,
            group: state.group(bus),
        );
        if (result != ma::SUCCESS) return c3d::UNSUPPORTED~;
        groups_made++;
    }

    return {
        .state       = state,
        .channels    = ma::engine_get_channels(state.engine),
        .sample_rate = ma::engine_get_sample_rate(state.engine),
        .bus_count   = bus_count,
        .null_device = desc.null_device,
    };
}

<*
 Stop every sound and release the device; destroy after every scene registered with it.
 @param [&inout] system : "Left zeroed."
*>
fn void destroy_audio_system(AudioSystem* system) {
    AudioState* state = system.state;
    Allocator allocator = state.allocator;
    for (uint index = 0; index < state.voices.len; index++) {
        if (state.voices[index].active) state.retire(index);
    }
    for (uint bus = 1; bus < state.bus_count; bus++) ma::sound_group_uninit(state.group(bus));
    ma::engine_uninit(state.engine);
    foreach (&mirror : state.mirrors) state.free_mirror_data(mirror);
    alloc::free(allocator, state.mirrors.ptr);
    alloc::free(allocator, state.voices.ptr);
    alloc::free(allocator, state.storage.ptr);
    alloc::free(allocator, state);
    *system = {};
}

<*
 Build the clip's mirror now instead of at first play.
 @return? c3d::INVALID_ID, c3d::ASSET_FORMAT_ERROR
*>
fn void? AudioSystem.prepare(&self, AudioClipId clip) {
    self.state.ensure_mirror(clip)!;
}

<*
 Play a clip once without position.
 @return? c3d::INVALID_ID, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
 @require bus < self.bus_count
*>
fn void? AudioSystem.play(&self, AudioClipId clip, BusId bus, float volume = 1) {
    self.state.start({ .bus = bus, .volume = volume, .pitch = 1 }, clip)!;
}

<*
 Play a clip once at a world position.
 @return? c3d::INVALID_ID, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
 @require bus < self.bus_count
*>
fn void? AudioSystem.play_at(
    &self,
    AudioClipId clip,
    BusId bus,
    Vec3 position,
    float volume = 1,
    float min_distance = AUDIO_EMITTER_DEFAULT.min_distance,
    float max_distance = AUDIO_EMITTER_DEFAULT.max_distance,
) {
    StartParams params = {
        .bus          = bus,
        .volume       = volume,
        .pitch        = 1,
        .positioned   = true,
        .position     = position,
        .min_distance = min_distance,
        .max_distance = max_distance,
    };
    self.state.start(params, clip)!;
}

<*
 Set the linear gain of a bus; the master is the engine volume.
 @require bus < self.bus_count
*>
fn void AudioSystem.set_bus_volume(&self, BusId bus, float volume) {
    if (bus == MASTER_BUS) {
        (void)ma::engine_set_volume(self.state.engine, volume);
    } else {
        ma::sound_group_set_volume(self.state.group(bus), volume);
    }
}

<*
 Move every positioned one-shot by the negated offset; emitters follow their nodes.
 @require offset.y == 0
*>
fn void AudioSystem.shift_origin(&self, Vec3 offset) {
    foreach (&voice : self.state.voices) {
        if (!voice.active || voice.owner.generation || !voice.positioned) continue;
        voice.position -= offset;
        ma::sound_set_position(
            sound: voice.sound,
            x: voice.position.x,
            y: voice.position.y,
            z: voice.position.z,
        );
    }
}

<*
 Counters of the last update.
*>
fn AudioStats AudioSystem.stats(&self) {
    AudioState* state = self.state;
    return {
        .voices         = state.voice_count,
        .voices_refused = state.voices_refused,
        .start_failures = state.start_failures,
        .listeners      = state.listeners,
        .mirrors        = state.mirror_count,
    };
}

<*
 Pull mixed interleaved frames on the owner thread.
 @require self.null_device, frames.len % self.channels == 0
*>
fn void AudioSystem.mix(&self, float[] frames) {
    ulong frames_read;
    (void)ma::engine_read_pcm_frames(
        engine: self.state.engine,
        frames_out: frames.ptr,
        frame_count: frames.len / self.channels,
        frames_read: &frames_read,
    );
}

fn void? check_bus_names(String[] names) @private {
    foreach (index, name : names) {
        if (!name.len) return c3d::INVALID_ARGUMENT~;
        for (sz other = 0; other < index; other++) {
            if (names[other] == name) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn ma::SoundGroup* AudioState.group(&self, uint bus) {
    return (ma::SoundGroup*)(self.groups + self.group_stride * ((usz)bus - 1));
}

fn void* allocate_block(usz size, void* user) @private {
    return alloc::malloc(*(Allocator*)user, (sz)size);
}

fn void* reallocate_block(void* block, usz size, void* user) @private {
    return alloc::realloc(*(Allocator*)user, block, (sz)size);
}

fn void free_block(void* block, void* user) @private {
    alloc::free(*(Allocator*)user, block);
}
