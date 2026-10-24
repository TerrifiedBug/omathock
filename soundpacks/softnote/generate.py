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
PEAK_TARGET = 8_000  # Peak of the reference strike (velocity 0 dB).
FUNDAMENTAL = 880.0  # A5; all other oscillators are integer harmonics.
DURATION_MS = 30

# Partial number, relative amplitude, decay time constant (s), phase (rad).
PARTIALS = (
    (1, 0.52, 0.0085, 0.24),
    (2, 0.30, 0.0045, 0.60),
    (3, 0.16, 0.0028, 0.90),
    (4, 0.08, 0.0017, 0.20),
)

# One note struck eight ways. Velocity (dB) moves the level and, as on a struck
# object, the brightness with it: a harder strike lifts the upper partials and
# the noise onset more than the fundamental. Decay varies a little on its own.
# The pitch never moves, so no take can be heard as a different note.
SAMPLES = (
    ("1.wav", -1.5, 0.94, 101),
    ("2.wav", 0.6, 1.06, 202),
    ("3.wav", -0.4, 1.00, 303),
    ("4.wav", 1.5, 0.96, 404),
    ("5.wav", -1.0, 1.04, 505),
    ("6.wav", 1.0, 0.98, 606),
    ("7.wav", 0.0, 1.08, 707),
    ("8.wav", -0.7, 0.92, 808),
)


def filtered_attack(seed: int, frames: int, lp_beta: float) -> list[float]:
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
    for sample in highpassed:
        prior += (1.0 - lp_beta) * (sample - prior)
        bandlimited.append(prior)
    return bandlimited


def strike(velocity_db: float, decay: float, seed: int) -> list[float]:
    """One unscaled strike; velocity 0 dB with decay 1.0 is the reference."""
    frames = round(RATE * DURATION_MS / 1000)
    level = 10 ** (velocity_db / 20)
    # Each partial above the fundamental gains another half of the velocity.
    weights = [
        amplitude * 10 ** ((number - 1) * 0.5 * velocity_db / 20)
        for number, amplitude, _, _ in PARTIALS
    ]
    # Harder strikes give a louder and slightly brighter noise onset.
    attack = filtered_attack(seed, frames, lp_beta=0.60 - 0.05 * velocity_db)
    noise_gain = 0.18 * 10 ** (1.5 * velocity_db / 20)
    fade_start = frames - round(RATE * 0.002)
    values: list[float] = []

    for index in range(frames):
        t = index / RATE
        onset = 1.0 - math.exp(-t / 0.00075)
        # Upper harmonics decay first to shorten the tonal tail.
        tone = onset * sum(
            weight
            * math.sin(2 * math.pi * FUNDAMENTAL * number * t + phase)
            * math.exp(-t / (tau * decay))
            for weight, (number, _, tau, phase) in zip(weights, PARTIALS)
        )
        transient = attack[index] * noise_gain * math.exp(-t / 0.0017) * onset
        fade = 1.0 if index < fade_start else max(
            0.0, (frames - index) / max(1, frames - fade_start)
        )
        values.append(level * (tone + transient) * fade)
    return values


def render(gain: float, sample: tuple[str, float, float, int]) -> dict[str, float | int | str]:
    filename, velocity_db, decay, seed = sample
    pcm = [max(-32767, min(32767, round(value * gain))) for value in strike(velocity_db, decay, seed)]
    with wave.open(str(ROOT / filename), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(struct.pack("<" + "h" * len(pcm), *pcm))

    peak = max(abs(value) for value in pcm)
    rms = math.sqrt(sum(value * value for value in pcm) / len(pcm))
    return {
        "file": filename,
        "velocity_db": velocity_db,
        "peak": peak,
        "rms": round(rms),
        "crest_db": round(20 * math.log10(peak / rms), 1),
    }


def write_config() -> None:
    config = {
        "metadata": {
            "name": "Softnote",
            "brand": "Original",
            "author": "Ganesh Gunasegaran",
            "supportsKeyUp": False,
            "category": "keyboard",
        },
        "license": {"type": "MIT"},
        "sounds": {"default": {"down": [name for name, *_ in SAMPLES], "up": []}},
        "id": "0b38c794-22e0-4ad8-8b74-93d07c95d9ce",
    }
    (ROOT / "config.json").write_text(json.dumps(config, indent=2) + "\n")


def main() -> None:
    write_config()
    reference = strike(0.0, 1.0, 0)
    gain = PEAK_TARGET / max(abs(value) for value in reference)
    for sample in SAMPLES:
        print(json.dumps(render(gain, sample)))


if __name__ == "__main__":
    main()
