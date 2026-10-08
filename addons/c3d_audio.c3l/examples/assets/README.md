# Example assets

The WAV files come from `generate.py` (Python standard library only, fixed noise seed):

```sh
python3 generate.py
```

`music.ogg` is the arpeggio encoded with ffmpeg 4.4 or later:

```sh
ffmpeg -v error -y -i arpeggio.wav -map_metadata -1 -fflags +bitexact -flags:a +bitexact -c:a libvorbis -q:a 4 music.ogg
```

| File | Content |
| --- | --- |
| `loop.wav` | 440 Hz sine, one second, loops without a click |
| `burst.wav` | decaying noise, a quarter second |
| `arpeggio.wav` | C major arpeggio, one second |
| `music.ogg` | the arpeggio as Ogg Vorbis, streamed on the music bus |
