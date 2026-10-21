# Audio add-on

`c3d_audio` plays sound over [miniaudio](https://miniaud.io) for c3d. Clips are asset-store kinds, emitters and a listener are scene components that follow their nodes, and buses are named linear gains. The `c3d::audio` module owns the `AudioSystem`, its voice table and per-clip mirrors, and the null-device `mix` path that tests use.

## Boundaries

`c3d::audio` imports the standard library, core (`c3d`) and `ma` (the `miniaudio.c3l` binding), and `c3d::serial` only under `C3D_AUDIO_SERIAL`. It never imports `gpu`, `sdl`, `imgui` or another add-on, and creates no GPU object. Core never imports it and has no audio flag. Every miniaudio allocation goes through the system allocator on the owner thread; the audio thread reads only system-owned mirrors.

## Select the package

List `c3d_audio` and `miniaudio` next to `c3d` and core's dependencies in `project.json`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names.

| Feature | Effect | Also select |
| --- | --- | --- |
| `C3D_AUDIO_SERIAL` | Registers `AudioEmitter` and `AudioListener` codecs | `c3d_serial` |

## Quick start

```c3
audio::register_audio_clips(&assets)!;
AudioSystem audio = audio::create_audio_system(mem, &assets, audio::default_audio_desc())!;
defer audio::destroy_audio_system(&audio);
audio::register_audio(&scene, &audio)!;     // destroy the scene before the system

AudioClipId clip = audio::load_audio_clip(&assets, "sounds/burst.wav")!;
audio.play(clip, audio::EFFECTS_BUS)!;

// every frame
scene.update_world();
audio.update(&scene);
```

`create_audio_system` opens the default output device; pass `null_device = true` in the desc to run without output and pull frames with `AudioSystem.mix`.

## Targets and examples

| Target | Kind |
| --- | --- |
| `audio_test` | CPU tests on a null device, no output |
| `audio_serial_test`, `audio_serial_policy_test` | Serialization adapter tests under `C3D_AUDIO_SERIAL` |
| `audio` | Example; `python3 scripts/build.py --example audio` |

```bash
c3c test audio_test --path addons/c3d_audio.c3l
```

## Guides

- [Audio](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/audio.md): setup, clips, emitters, buses, threading and limits.
- [Serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization_reference.md#audio).
