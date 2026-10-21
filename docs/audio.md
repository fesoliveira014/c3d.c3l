# Audio

The `c3d_audio` add-on (module `c3d::audio`) plays sound through [miniaudio](https://miniaud.io), bound by `miniaudio.c3l` (module `ma`). Clips are asset-store kinds. Emitters and a listener are scene components that follow their nodes. Buses are named linear gains. Core never imports the package; select `c3d_audio` and `miniaudio` to use it. The `C3D_AUDIO_SERIAL` feature adds scene serialization ([Serialization](#serialization)).

Out of scope: pause tied to a game clock, voice priority and stealing, effects, reverb, occlusion, doppler, music sequencing, capture and miniaudio's resource manager.

## Quick start

```c3
AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
audio::register_audio_clips(&assets)!;

AudioSystem audio = audio::create_audio_system(mem, &assets, audio::default_audio_desc())!;
defer audio::destroy_audio_system(&audio);

Scene scene = scene::create_scene(mem, scene::default_scene_desc());
defer scene::destroy_scene(&scene);           // destroy the scene before the system
audio::register_audio(&scene, &audio)!;

AudioClipId clip = audio::load_audio_clip(&assets, "sounds/burst.wav")!;
audio.play(clip, audio::EFFECTS_BUS);

// every frame
scene.update_world();
audio.update(&scene);
```

- `AudioSystem` is held by value and may be moved: everything miniaudio or a scene hook points to lives in heap storage behind it. The `AssetStore` passed to `create_audio_system` is held by pointer and must not move or die before the system.
- `create_audio_system` opens the default output device. A device or engine failure faults `UNSUPPORTED`; an application can retry with `null_device = true`. Duplicate or empty bus names fault `INVALID_ARGUMENT`.
- Call `scene.update_world()` and then `audio.update(&scene)` once per frame.
- One scene per system: `register_audio` records the scene, and `update` takes that scene. The system outlives its scene, because the scene's remove hooks call into the system. Destroy the scene first.

## Concepts

- **Clips** are encoded WAV, FLAC, MP3 or Ogg Vorbis bytes in the asset store with a probed format (frames, channels, rate).
- **Mirrors.** Each system keeps a mirror per clip, keyed by id and revision: decoded PCM or a copy of the encoded bytes. The audio thread reads only system-owned mirrors, so a clip may be replaced or removed at any time.
- **Voices.** A voice is one playing sound. `max_voices` slots exist per system.
- **Buses** are named linear gains; [Use buses](#use-buses).
- **Threads.** The device runs the mixer and decoders on its own thread; the application thread owns every other call ([Threads and allocation](#threads-and-allocation)).

## Add and replace clips

`add_audio_clip` copies bytes into the store and probes the format. `load_audio_clip` reads a path through the store's file source (`ASSET_IO_ERROR` on a read failure). `replace_audio_clip` probes first, then swaps the bytes and advances `header.revision` and `replaced_revision`. `remove_audio_clip` frees the clip and makes its id stale.

| Mode | Behavior |
| --- | --- |
| `DECODED` | Decoded once into f32 PCM at the clip's channels and rate; voices play it without copying |
| `STREAMED` | Decoded while playing from a copy of the encoded bytes |
| `AUTO` | `STREAMED` at or above `AudioDesc.stream_threshold_bytes` (`DEFAULT_STREAM_THRESHOLD_BYTES`, 1 MiB), otherwise `DECODED` |

`prepare(clip)` builds a clip's mirror ahead of time. The first play of an unprepared clip builds it on the calling thread, a decode hitch proportional to the clip length. A replaced or removed clip frees its mirror at the next `update`: voices on the old content stop, a looping emitter restarts on the new content and a one-shot emitter ends. A removed clip's voices keep playing from the mirror until that update. Clip capacity is `DEFAULT_MAX_CLIPS` (256) unless `register_audio_clips` says otherwise.

## Play with emitters

- `AudioEmitter` holds `clip`, `bus`, linear `volume`, `pitch`, `min_distance`, `max_distance`, `looping` and `playing`. `AUDIO_EMITTER_DEFAULT` is on the effects bus with distances 1 and 100.
  - `playing` becoming true starts a voice; becoming false stops it.
  - A change of clip or bus restarts the voice.
  - Volume, pitch, position, distances and looping are copied every frame.
  - The system clears `playing` when a non-looping sound ends.
- `AudioListener` has `active`, which marks the node the mixer hears from. The first active listener in component order is used and `AudioStats.listeners` counts the active ones. With none, the listener sits at the origin facing −Z. Forward is the node's −Z axis, the world up is +Y, and roll is ignored.

Removing an emitter component or its node stops its voice immediately. Attenuation is miniaudio's inverse model with rolloff 1, clamped between `min_distance` and `max_distance`: gain = `min / (min + (d − min))`, so doubling the distance from `min_distance` halves the gain. Doppler is off. The first few milliseconds of a spatial voice ramp the gain.

## Play one-shots

`play(clip, bus, volume)` plays a clip once without position. `play_at(clip, bus, position, volume, min_distance, max_distance)` plays it at a world position. Both fault `CAPACITY_EXCEEDED` when no voice is free, `INVALID_ID` for a dead clip and `ASSET_FORMAT_ERROR` when the mirror cannot be built. A finished one-shot frees its voice at the next `update`.

## Use buses

`AudioDesc.buses` names the buses. Index zero is the master (the engine endpoint) and the others are sound groups directly under it, so buses do not nest. `default_audio_desc()` names `master`, `music`, `effects`, `ambience` and `ui` (`MASTER_BUS`, `MUSIC_BUS`, `EFFECTS_BUS`, `AMBIENCE_BUS`, `UI_BUS`). `set_bus_volume(bus, volume)` takes a linear gain.

## Use the null device

With `null_device = true` no output is opened and nothing plays by itself. `mix(float[] frames)` pulls interleaved f32 frames on the calling thread (48000 Hz and 2 channels unless the desc says otherwise). Tests assert levels with it, and offline rendering uses it. A null-device application that wants sound to advance calls `mix` itself.

## Rebase the origin

After an origin rebase, call `AudioSystem.shift_origin(offset)` with `offset.y == 0`. It subtracts the offset from every playing positioned one-shot and re-applies its position to the voice. Emitter voices are not touched: they follow their nodes and are re-applied at each `update`. The listener is a scene node and moves with the scene shift.

## Serialization

Under `C3D_AUDIO_SERIAL`, `audio::register_serial_codecs()` makes `AudioEmitter` and `AudioListener` saveable with `c3d_serial`; `AudioVoiceLink` is never written. The emitter's clip saves by its asset key, so the reading store must register the clip kind and hold a clip under that key. The bus index is meaningful only against the reading system's `AudioDesc.buses`; an index past the table fails the voice start and counts in `AudioStats.start_failures`. Playback position is not saved: a loaded playing emitter starts from the beginning at the next `update`. See [serialization](serialization.md#landscape-particle-and-audio-adapters).

## Threads and allocation

- A device runs miniaudio's mixer and decoders on its own thread. The add-on installs no callbacks into application code.
- The audio thread reads only system-owned memory: mirrors and voice sources. The store's bytes are never read by it.
- Every allocation happens on the owner thread, through the system allocator: engine, buses, voice and mirror tables at create; mirrors at `prepare` or first play; two blocks per started voice (plus a decoder's blocks for a streamed one). Mixing, decoding and looping allocate nothing. The exception is stb_vorbis, which allocates its decoder state with C `malloc` when an Ogg Vorbis decoder opens (at the clip probe, a decoded mirror build and a streamed start), outside the system allocator.
- Retiring a voice (`update` for finished or stale voices, the remove hook, `destroy_audio_system`) calls `ma_sound_uninit`, which waits until the audio thread leaves the sound. `update` and the remove hooks may block briefly for each voice retired, in proportion to the voices that end in a frame.

## Limits

- `max_voices` (`DEFAULT_MAX_VOICES`, 64) slots are allocated at create. There is no priority and no stealing: a start without a free voice faults, and an emitter start is counted in `AudioStats.voices_refused`.
- An emitter start that fails for another reason (dead clip, mirror build failure) is counted in `AudioStats.start_failures`. Neither kind is retried until `playing` goes false and true again or the clip changes.
- The mirror table has one slot per clip slot.

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

## See also

- [Audio package](../addons/c3d_audio.c3l/README.md), [serialization](serialization.md), [large worlds](large_world.md).
- The `audio` example (`python3 scripts/build.py --example audio`) circles a looping emitter around the camera, streams music and plays one-shots; `--null-device` and `--headless` run without output or a window.
