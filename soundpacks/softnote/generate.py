#!/usr/bin/env python3
"""Generate the original Softnote soundpack using Python standard library."""

from __future__ import annotations

import json
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RATE = 44_100
PEAK_TARGET = 8_000
FUNDAMENTAL = 880.0  # A5; all other oscillators are integer harmonics.

# Tiny texture/envelope variations around one stable note, not a scale.
SAMPLES = (
    ("1.wav", 29, 0.96, 0.99, 101),
    ("2.wav", 30, 1.03, 1.00, 202),
    ("3.wav", 28, 1.07, 1.02, 303),
    ("4.wav", 29, 0.93, 0.98, 404),
    ("5.wav", 30, 1.00, 1.01, 505),
)


def filtered_attack(seed: int, frames: int) -> list[float]:
    """Create a quiet, band-limited noise onset."""
    rng = random.Random(seed)
    white = [rng.uniform(-1.0, 1.0) for _ in range(frames)]

    highpassed: list[float] = []
    prior_x = prior_y = 0.0
    hp_alpha = 0.90
    for sample in white:
        value = hp_alpha * (prior_y + sample - prior_x)
        highpassed.append(value)
        prior_x, prior_y = sample, value

    bandlimited: list[float] = []
    prior = 0.0
    lp_beta = 0.60
    for sample in highpassed:
        prior += (1.0 - lp_beta) * (sample - prior)
        bandlimited.append(prior)
    return bandlimited


def render(sample: tuple[str, int, float, float, int]) -> dict[str, float | int | str]:
    filename, duration_ms, brightness, body, seed = sample
    frames = round(RATE * duration_ms / 1000)
    attack = filtered_attack(seed, frames)
    values: list[float] = []

    for index in range(frames):
        t = index / RATE
        onset = 1.0 - math.exp(-t / 0.00075)
        # A5 root and its 2nd, 3rd, and 4th harmonics form one stable timbre.
        # Upper harmonics decay first to shorten the tonal tail.
        tone = body * onset * (
            0.52 * math.sin(2 * math.pi * FUNDAMENTAL * t + 0.24) * math.exp(-t / 0.0085)
            + 0.30 * math.sin(2 * math.pi * FUNDAMENTAL * 2 * t + 0.60) * math.exp(-t / 0.0045)
            + 0.16 * math.sin(2 * math.pi * FUNDAMENTAL * 3 * t + 0.90) * math.exp(-t / 0.0028)
            + 0.08 * math.sin(2 * math.pi * FUNDAMENTAL * 4 * t + 0.20) * math.exp(-t / 0.0017)
        )
        transient = attack[index] * 0.18 * brightness * math.exp(-t / 0.0017) * onset
        fade_start = frames - round(RATE * 0.002)
        fade = 1.0 if index < fade_start else max(
            0.0, (frames - index) / max(1, frames - fade_start)
        )
        values.append((tone + transient) * fade)

    peak = max(abs(value) for value in values)
    gain = PEAK_TARGET / peak if peak else 0.0
    pcm = [max(-32767, min(32767, round(value * gain))) for value in values]
    with wave.open(str(ROOT / filename), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(struct.pack("<" + "h" * len(pcm), *pcm))

    rms = math.sqrt(sum(value * value for value in pcm) / len(pcm))
    return {
        "file": filename,
        "duration_ms": round(1000 * frames / RATE, 1),
        "peak": max(abs(value) for value in pcm),
        "rms": round(rms),
        "crest_db": round(20 * math.log10(PEAK_TARGET / rms), 1),
    }


def write_config() -> None:
    config = {
        "metadata": {
            "name": "Softnote",
            "brand": "Original",
            "author": "OmaThock contributors",
            "supportsKeyUp": False,
            "category": "keyboard",
        },
        "license": {"type": "MIT"},
        "sounds": {"default": {"down": [f"{n}.wav" for n in range(1, 6)], "up": []}},
        "id": "0b38c794-22e0-4ad8-8b74-93d07c95d9ce",
    }
    (ROOT / "config.json").write_text(json.dumps(config, indent=2) + "\n")


def main() -> None:
    write_config()
    for stale in ("201.wav", "202.wav", "301.wav", "401.wav"):
        (ROOT / stale).unlink(missing_ok=True)
    for sample in SAMPLES:
        print(json.dumps(render(sample)))


if __name__ == "__main__":
    main()
