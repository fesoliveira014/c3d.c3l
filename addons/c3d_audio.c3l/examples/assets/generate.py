#!/usr/bin/env python3
"""Write the example sounds as mono 48 kHz 16-bit PCM WAV files (standard library only).

loop.wav      one second of a 440 Hz sine, an integer number of cycles so it loops without a click
burst.wav     a quarter second of decaying noise, fixed seed
arpeggio.wav  four notes of a C major arpeggio, a quarter second each
"""

import math
import random
import struct
import wave

SAMPLE_RATE = 48000
PEAK = 32767
NOISE_SEED = 7


def write(path, samples):
    with wave.open(path, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(b"".join(struct.pack("<h", round(PEAK * sample)) for sample in samples))


def sine(frequency, seconds, amplitude):
    count = round(SAMPLE_RATE * seconds)
    return [amplitude * math.sin(2 * math.pi * frequency * index / SAMPLE_RATE) for index in range(count)]


def envelope(samples, attack, release):
    count = len(samples)
    attack_frames = round(SAMPLE_RATE * attack)
    release_frames = round(SAMPLE_RATE * release)
    shaped = []
    for index, sample in enumerate(samples):
        gain = min(1.0, index / attack_frames if attack_frames else 1.0)
        gain = min(gain, (count - index) / release_frames if release_frames else 1.0)
        shaped.append(sample * gain)
    return shaped


def noise_burst(seconds, amplitude):
    generator = random.Random(NOISE_SEED)
    count = round(SAMPLE_RATE * seconds)
    return [amplitude * generator.uniform(-1, 1) * math.exp(-6 * index / count) for index in range(count)]


write("loop.wav", sine(440, 1.0, 0.5))
write("burst.wav", noise_burst(0.25, 0.8))
notes = [261.63, 329.63, 392.0, 523.25]
arpeggio = []
for note in notes:
    arpeggio += envelope(sine(note, 0.25, 0.5), 0.005, 0.1)
write("arpeggio.wav", arpeggio)
