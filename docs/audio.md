# Audio

Add-on `addons/c3d_audio.c3l`, module `c3d::audio`, built on [miniaudio](https://miniaud.io) through `lib/miniaudio.c3l`
(module `ma`). Clips are asset-store kinds. Emitters and a listener are scene components that follow their nodes.
Buses are named linear gains. Core never imports the add-on; select `c3d_audio` and `miniaudio` to use it.

Out of scope: pause tied to a game clock, voice priority and stealing, effects, reverb, occlusion, doppler, music
sequencing, capture and miniaudio's resource manager.

## Setup

```c3
AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
audio::register_audio_clips(&assets)!;

AudioSystem audio = audio::create_audio_system(mem, &assets, audio::default_audio_desc())!;
defer audio::destroy_audio_system(&audio);

Scene scene = scene::create_scene(mem, scene::default_scene_desc());
defer scene::destroy_scene(&scene);           // destroy the scene before the system
audio::register_audio(&scene, &audio)!;
```

- `AudioSystem` is held by value and may be moved: everything miniaudio or a scene hook points to lives in heap
  storage behind it. The `AssetStore` passed to `create_audio_system` is held by pointer and must not move or die
  before the system.
- `create_audio_system` opens the default output device. A device or engine failure faults `UNSUPPORTED`; an
  application can retry with `null_device = true`. Duplicate or empty bus names fault `INVALID_ARGUMENT`.
- Call `scene.update_world()` and then `audio.update(&scene)` once per frame.
- Destroy every scene registered with a system before the system: the scene's remove hooks call into it.

## Clips and modes

`add_audio_clip` copies WAV, FLAC, MP3 or Ogg Vorbis bytes into the store and probes the format (frames, channels,
rate). `load_audio_clip` reads a path through the store's file source (`ASSET_IO_ERROR` on a read failure).
`replace_audio_clip` probes first, then swaps the bytes and advances `header.revision` and `replaced_revision`.
`remove_audio_clip` frees the clip and makes its id stale.

| Mode | Behavior |
| --- | --- |
| `DECODED` | decoded once into f32 PCM at the clip's channels and rate; voices play it without copying |
| `STREAMED` | decoded while playing from a copy of the encoded bytes |
| `AUTO` | `STREAMED` at or above `AudioDesc.stream_threshold_bytes` (1 MiB by default), otherwise `DECODED` |

Each system keeps a mirror per clip, keyed by id and revision: the PCM or the byte copy. `prepare(clip)` builds it
ahead of time. The first play of an unprepared clip builds the mirror on the calling thread, which is a decode hitch
proportional to the clip length. A replaced or removed clip frees its mirror at the next `update`: voices on the
old content stop, a looping emitter restarts on the new content and a one-shot emitter ends. A removed clip's voices
keep playing from the mirror until that update.

## Components

- `AudioEmitter`: clip, bus, linear `volume`, `pitch`, `min_distance`, `max_distance`, `looping` and `playing`.
  `AUDIO_EMITTER_DEFAULT` is on the effects bus with distances 1 and 100.
  - `playing` becoming true starts a voice; becoming false stops it.
  - A change of clip or bus restarts the voice.
  - Volume, pitch, position, distances and looping are copied every frame.
  - The system clears `playing` when a non-looping sound ends.
- `AudioListener`: `active` marks the node the mixer hears from. The first active listener in component order is
  used and `AudioStats.listeners` counts the active ones. With none, the listener sits at the origin facing -Z.
  Forward is the node's -Z axis and the world up is +Y; roll is ignored.

Removing an emitter component or its node stops its voice immediately. The remove hook scans the voice table for
voices owned by the entity.

Attenuation is miniaudio's inverse model with rolloff 1, clamped between `min_distance` and `max_distance`: gain =
min / (min + (d - min)), so doubling the distance from `min_distance` halves the gain. Doppler is off. The first few milliseconds of a spatial voice ramp the gain.

## One-shots

`play(clip, bus, volume)` plays a clip once without position. `play_at(clip, bus, position, volume, min_distance,
max_distance)` plays it at a world position. Both fault `CAPACITY_EXCEEDED` when no voice is free, `INVALID_ID` for
a dead clip and `ASSET_FORMAT_ERROR` when the mirror cannot be built. A finished one-shot frees its voice at the
next `update`.

## Buses

`AudioDesc.buses` names the buses; index zero is the master (the engine endpoint) and the others are sound groups
directly under it, so buses do not nest. `default_audio_desc()` names `master`, `music`, `effects`, `ambience` and
`ui` (`MASTER_BUS`, `MUSIC_BUS`, `EFFECTS_BUS`, `AMBIENCE_BUS`, `UI_BUS`). `set_bus_volume` takes a linear gain.

## Null device and `mix`

With `null_device = true` no output is opened and nothing plays by itself. `mix(float[] frames)` pulls interleaved
f32 frames on the calling thread (48000 Hz and 2 channels unless the desc says otherwise). Tests assert levels with
it, and offline rendering uses it. A null-device application that wants sound to advance calls `mix` itself.

## Voices and limits

- `max_voices` slots are allocated at create (two miniaudio heap blocks per started voice, through the system
  allocator). There is no priority and no stealing: a start without a free voice faults, and an emitter start is
  counted in `AudioStats.voices_refused`.
- An emitter start that fails for another reason (dead clip, mirror build failure) is counted in
  `AudioStats.start_failures`. Neither kind is retried until `playing` goes false and true again or the clip changes.
- Clip capacity is `DEFAULT_MAX_CLIPS` (256) unless `register_audio_clips` says otherwise; the mirror table has one
  slot per clip slot.

## Threads and allocation

- A device runs miniaudio's mixer and decoders on its own thread. The add-on installs no callbacks into application
  code, and the application thread owns every other call.
- The audio thread reads only system-owned memory: mirrors and voice sources. The store's bytes are never read by
  it, so a clip may be replaced or removed at any time.
- Every allocation happens on the owner thread, through the system allocator: engine, buses, voice and mirror
  tables at create; mirrors at `prepare` or first play; two blocks per started voice (plus a decoder's blocks for a
  streamed one). Mixing, decoding and looping allocate nothing. The exception is stb_vorbis, which allocates its
  decoder state with C `malloc` when an Ogg Vorbis decoder opens (at the clip probe, a decoded mirror build and a
  streamed start), outside the system allocator.
- Retiring a voice (`update` for finished or stale voices, the remove hook, `destroy_audio_system`) calls
  `ma_sound_uninit`, which waits until the audio thread leaves the sound. `update` and the remove hooks may block
  briefly for each voice retired; the cost scales with the voices that end in a frame.

## Faults

| Call | Faults |
| --- | --- |
| `register_audio_clips` | `CAPACITY_EXCEEDED` |
| `add_audio_clip` | `INVALID_ARGUMENT` (empty bytes, duplicate key), `ASSET_FORMAT_ERROR`, `CAPACITY_EXCEEDED` |
| `load_audio_clip` | the above and `ASSET_IO_ERROR` |
| `replace_audio_clip` | `INVALID_ARGUMENT`, `ASSET_FORMAT_ERROR` |
| `create_audio_system` | `UNSUPPORTED`, `INVALID_ARGUMENT` |
| `register_audio` | `CAPACITY_EXCEEDED` |
| `prepare` | `INVALID_ID`, `ASSET_FORMAT_ERROR` |
| `play`, `play_at` | `INVALID_ID`, `ASSET_FORMAT_ERROR`, `CAPACITY_EXCEEDED` |

## Example

`addons/c3d_audio.c3l/examples/audio.c3` (`python3 scripts/build.py --example audio`): a looping emitter that circles
the camera, a streamed music emitter, keys `1` and `2` for flat and positioned one-shots, `M` and `N` for the music
and effects volumes, `S` to start or stop the orbiter, and `AudioStats` printed once a second. `--null-device` runs
without output and pumps `mix`; `--headless --frames N` runs the audio loop without a window; `--frames N` ends the
interactive run after N frames.
