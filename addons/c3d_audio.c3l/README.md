# c3d_audio

Audio for c3d. Module `c3d::audio`, package `c3d_audio`, built on [miniaudio](https://miniaud.io) through
`lib/miniaudio.c3l` (module `ma`). Clips are asset-store kinds; emitters and a listener are scene components; buses
are named linear gains. See [Audio](../../docs/audio.md) for setup, threading and limits.

## Package and boundaries

- `c3d::audio` imports the standard library, `c3d` and `ma`. It never imports `gpu`, `sdl`, `imgui` or another
  add-on, and creates no GPU object.
- Core never imports it. Select it with the `c3d_audio` and `miniaudio` dependencies.
- Targets: `audio_test` (CPU, null device, no output) and the `audio` example.

## Tests

```bash
c3c test audio_test --path addons/c3d_audio.c3l
```

The tests use a null device and `mix`, so they assert levels numerically: bus gain, inverse distance attenuation,
streamed against decoded output, emitter start, stop and end, removal through either hook path, clip replacement and
removal, listener selection, voice capacity, and that a steady state of looping decoded, Ogg Vorbis and MP3 voices
allocates nothing. Fixtures under `test/fixtures` come from `generate.py` and the ffmpeg commands in its README.

## Example and acceptance

```bash
python3 scripts/build.py --example audio                 # interactive, default output device
addons/c3d_audio.c3l/build/audio --null-device --frames 120
addons/c3d_audio.c3l/build/audio --headless --frames 120  # audio loop only, no window
```

The example sounds come from `examples/assets/generate.py` and the ffmpeg command in that directory's README. Audible
acceptance (the orbiter pans around the listener, the music bus and effects bus volumes follow `M` and `N`) needs a
real output device and is checked by running the example on one.
