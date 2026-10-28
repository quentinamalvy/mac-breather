"""Synthesizes Mac Breather's notification sound: three soft ascending plucks (original, no samples).

Usage: python3 make_sounds.py   (writes notify.wav next to this script; needs numpy)
"""
import os
import wave
import numpy as np

RATE = 44100


def pluck(freq, dur=0.6):
    n = int(dur * RATE)
    t = np.arange(n) / RATE
    s = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-t * m * 0.6) for m, a in ((1, 1.0), (4, 0.25), (10, 0.05)))
    return s * np.clip(t / 0.004, 0, 1) * np.exp(-t / 0.18)


out = np.zeros(int(0.9 * RATE))
for freq, at in ((1047, 0), (1319, 0.09), (1568, 0.18)):   # C6, E6, G6
    p = pluck(freq)
    i = int(at * RATE)
    out[i:i + len(p)] += p[: len(out) - i]
out = out / np.max(np.abs(out)) * 0.7

with wave.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "notify.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes((out * 32767).astype("<i2").tobytes())
