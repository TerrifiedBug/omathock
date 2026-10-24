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

# Partial number, relative amplitude, decay time constant (s), phase (rad).
PARTIALS = (
    (1, 0.52, 0.0085, 0.24),
    (2, 0.30, 0.0045, 0.60),
    (3, 0.16, 0.0028, 0.90),
    (4, 0.08, 0.0017, 0.20),
)

# How each key is built: duration (ms), decay scale, tilt (dB per partial above
# the fundamental), noise onset (dB) and level (dB). Space and Enter are bigger
# keys, so they ring longer, Space the darker of the two; Backspace is damped:
# short, dark and quieter. Every key keeps the same note, so the keys differ in
# weight, never in pitch.
VOICES = {
    "default": (30, 1.00, 0.0, 0.0, 0.0),
    "space": (40, 1.35, -4.0, -4.0, -0.5),
    "enter": (45, 1.55, 0.0, -2.0, -1.5),
    "backspace": (24, 0.65, -6.0, -8.0, 0.0),
}

# Each key struck several ways. Velocity (dB) moves the level and, as on a
# struck object, the brightness with it: a harder strike lifts the upper
# partials and the noise onset more than the fundamental. Decay varies a little
# on its own. File names follow the bundled packs: 2xx Space, 3xx Enter, 4xx
# Backspace.
SAMPLES = (
    ("1.wav", "default", -1.5, 0.94, 101),
    ("2.wav", "default", 0.6, 1.06, 202),
    ("3.wav", "default", -0.4, 1.00, 303),
    ("4.wav", "default", 1.5, 0.96, 404),
    ("5.wav", "default", -1.0, 1.04, 505),
    ("6.wav", "default", 1.0, 0.98, 606),
    ("7.wav", "default", 0.0, 1.08, 707),
    ("8.wav", "default", -0.7, 0.92, 808),
    ("201.wav", "space", -0.8, 0.97, 2101),
    ("202.wav", "space", 0.0, 1.03, 2202),
    ("203.wav", "space", 0.8, 1.00, 2303),
    ("301.wav", "enter", -0.4, 1.02, 3101),
    ("302.wav", "enter", 0.4, 0.98, 3202),
    ("401.wav", "backspace", -0.8, 1.03, 4101),
    ("402.wav", "backspace", 0.0, 0.97, 4202),
    ("403.wav", "backspace", 0.8, 1.00, 4303),
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


def strike(key: str, velocity_db: float, decay: float, seed: int) -> list[float]:
    """One unscaled strike; the default key at velocity 0 dB and decay 1.0 is the reference."""
    duration_ms, key_decay, tilt_db, noise_db, level_db = VOICES[key]
    frames = round(RATE * duration_ms / 1000)
    level = 10 ** ((velocity_db + level_db) / 20)
    decay *= key_decay
    # Each partial above the fundamental gains another half of the velocity.
    weights = [
        amplitude * 10 ** ((number - 1) * (0.5 * velocity_db + tilt_db) / 20)
        for number, amplitude, _, _ in PARTIALS
    ]
    # Harder strikes give a louder and slightly brighter noise onset.
    attack = filtered_attack(seed, frames, lp_beta=0.60 - 0.05 * velocity_db)
    noise_gain = 0.18 * 10 ** ((1.5 * velocity_db + noise_db) / 20)
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


def render(gain: float, sample: tuple[str, str, float, float, int]) -> dict[str, float | int | str]:
    filename, key, velocity_db, decay, seed = sample
    pcm = [max(-32767, min(32767, round(value * gain))) for value in strike(key, velocity_db, decay, seed)]
    with wave.open(str(ROOT / filename), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(struct.pack("<" + "h" * len(pcm), *pcm))

    peak = max(abs(value) for value in pcm)
    rms = math.sqrt(sum(value * value for value in pcm) / len(pcm))
    return {
        "file": filename,
        "key": key,
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
        "sounds": {
            key: {"down": [name for name, owner, *_ in SAMPLES if owner == key], "up": []}
            for key in VOICES
        },
        "id": "0b38c794-22e0-4ad8-8b74-93d07c95d9ce",
    }
    (ROOT / "config.json").write_text(json.dumps(config, indent=2) + "\n")


def main() -> None:
    write_config()
    reference = strike("default", 0.0, 1.0, 0)
    gain = PEAK_TARGET / max(abs(value) for value in reference)
    for sample in SAMPLES:
        print(json.dumps(render(gain, sample)))


if __name__ == "__main__":
    main()
