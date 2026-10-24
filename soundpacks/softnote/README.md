# Softnote

Softnote is a synthesized key-down cue for laptop typing, by Ganesh
Gunasegaran. It is one short tonal sound, not a switch recording.

## Sound design

- Every key plays the same cue: A5 (880 Hz) with its 2nd, 3rd and 4th
  harmonics over a short filtered-noise onset. The upper harmonics decay
  first. Takes carry no key identity, and there are no release sounds.
- The eight takes are one note struck with different force. Velocity moves
  the level over about 3 dB and lifts the upper harmonics and the noise onset
  with it; decay varies by up to 8 percent on its own. The pitch never moves,
  so no take reads as a different note.
- Takes are 30 ms, 44.1 kHz mono, 16-bit PCM. At 100% volume they peak
  between about 6,400 and 10,500 (-14 to -10 dBFS).
- By K-weighted energy at the same volume setting, Softnote sits at the quiet
  end of the bundled packs, about 2.5 dB below Holy Panda.
- `python3 generate.py` regenerates the WAVs and config deterministically.

## Why these choices

The fundamental sits above the range small laptop speakers lose. One
calibrated measurement of a Framework laptop fell off quickly below 400 Hz
([Framework community](https://community.frame.work/t/speakers-sound-quality/1078/34)),
so a cue built on low-frequency body would lose most of it there.

Variation comes from level and brightness because pitch is a poor place for
it. For a tone whose envelope is above half amplitude for about 8 ms, the
pure-tone fit of [Micheyl, Xiao and Oxenham (2012)](https://doi.org/10.1016/j.heares.2012.07.004)
puts the pitch threshold near 35 to 40 cents. Pitch steps small enough to keep
one note would barely be heard; steps large enough to hear would start to
sound like a melody, or a code.

The short percussive envelope follows [Foley et al. (2022)](https://doi.org/10.1121/10.0010447),
who found percussive tones less annoying than flat ones, and shorter harmonics
less annoying without a matching loss in detection. Their tones were 360 to
600 ms alarm sounds, not keystrokes.

No listening, preference, speaker-response or typing test has been run.
Treat Softnote as an optional confirmation sound, not a speed or accuracy aid.
