#!/usr/bin/env python3
"""Write tone.wav: 0.1 s, 440 Hz, mono, 48 kHz, 16-bit PCM sine at half amplitude (standard library only)."""

import math
import struct
import wave

SAMPLE_RATE = 48000
FREQUENCY = 440
AMPLITUDE = 0.5
FRAMES = SAMPLE_RATE // 10

with wave.open("tone.wav", "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(SAMPLE_RATE)
    samples = (
        round(AMPLITUDE * 32767 * math.sin(2 * math.pi * FREQUENCY * index / SAMPLE_RATE))
        for index in range(FRAMES)
    )
    output.writeframes(b"".join(struct.pack("<h", sample) for sample in samples))
