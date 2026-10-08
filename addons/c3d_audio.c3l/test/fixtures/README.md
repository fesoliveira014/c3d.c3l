# Fixtures

`tone.ogg` and `tone.mp3` are 0.1 s, 440 Hz, mono, 48 kHz sines at half amplitude, the encoded forms the steady
state test streams. They are encoded from a WAV that `generate.py` writes with the Python standard library only,
using ffmpeg 4.4 or later with bitexact flags so the encode is repeatable:

```sh
python3 generate.py
common="-v error -y -i tone.wav -map_metadata -1 -fflags +bitexact -flags:a +bitexact"
ffmpeg $common -c:a libvorbis -q:a 4 tone.ogg
ffmpeg $common -c:a libmp3lame -b:a 128k tone.mp3
rm tone.wav
```

The tests embed the files at compile time.
