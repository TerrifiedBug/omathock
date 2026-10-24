# Softnote

Softnote is a synthesized key-down sound for laptop typing, by Ganesh
Gunasegaran. It is one short note, not a switch recording.

## Sound design

- Every key plays A5 (880 Hz) with its 2nd, 3rd and 4th harmonics over a
  short filtered-noise onset; the upper harmonics decay first. There are no
  release sounds.
- Letters and most other keys share eight 30 ms takes. Space, Enter and
  Backspace (and Delete, which OmaThock maps to Backspace) get their own
  strikes of the same note. Space and Enter are bigger keys, so they ring
  longer (40 and 45 ms) and darker, Space the darker of the two. Backspace is
  damped: 24 ms, darker and about 3 dB quieter.
- Each key's takes are its note struck with different force. Velocity moves
  the level over up to 3 dB and lifts the upper harmonics and the noise onset
  with it; decay varies by up to 8 percent on its own. The pitch never moves.
- 44.1 kHz mono, 16-bit PCM. At 100% volume the takes peak between about
  5,200 and 10,500 (-16 to -10 dBFS).
- By K-weighted energy at the same volume setting, the letter takes sit at
  the quiet end of the bundled packs, about 2.5 dB below Holy Panda; Space
  and Enter are within 1 dB of the letters.
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

Space, Enter and Backspace do different jobs, and Android's audio API makes
the same split, with separate keypress sounds for standard, spacebar, delete
and return keys ([AudioManager](https://developer.android.com/reference/android/media/AudioManager)).
They differ in weight rather than pitch for the reason above: typing should
never turn into a melody.

The short percussive envelope follows [Foley et al. (2022)](https://doi.org/10.1121/10.0010447),
who found percussive tones less annoying than flat ones, and shorter harmonics
less annoying without a matching loss in detection. Their tones were 360 to
600 ms alarm sounds, not keystrokes.

No listening, preference, speaker-response or typing test has been run.
Treat Softnote as an optional confirmation sound, not a speed or accuracy aid.
