# Softnote

Softnote is an original synthesized key-down cue designed for laptop typing. It is a short tonal sound rather than a mechanical-switch recording.

## Sound design

- Every key uses the same A5-centered cue, with five small envelope and texture variations. They do not encode key identity, and there are no release sounds.
- The sound combines an 880 Hz fundamental with its 2nd, 3rd, and 4th harmonics. A short filtered-noise transient adds an onset; the upper harmonics decay faster than the fundamental.
- Samples are 28–30 ms, 44.1 kHz mono, 16-bit PCM. At the default 100% player volume, each sample peaks at 8,000 PCM (about -12.2 dBFS) before other sounds are mixed. The player clamps mixed output to the 16-bit range.
- The laptop speaker response and audibility over fan noise have not been measured.
- Regenerate the WAVs and config with `python3 generate.py`.

## Research and limits

Foley et al. found that percussive envelopes and shorter harmonic durations reduced annoyance in controlled auditory-interface tones. Those experiments did not test rapidly repeated keyboard clicks, so they motivate the envelope but do not establish Softnote's comfort or detectability: [Foley et al., JASA (2022)](https://maplelab.net/wp-content/uploads/2022/05/22-JASA-More-detectable-less-annoying.pdf). Lei et al. found that identifying learned earcon warnings interfered with working-memory tasks in some conditions. Their warning sounds were about 0.9–1.1 seconds long and had to be identified; Softnote is a 28–30 ms cue with no assigned meaning, so the result is not directly transferable: [Lei et al., Frontiers in Psychology (2022)](https://doi.org/10.3389/fpsyg.2022.780657).

Kim and Tan reported that auditory keyclick feedback improved typing performance over no feedback on their zero-travel keyboard, but they did not test a laptop with physical keys or this sound: [Kim and Tan (2014)](https://engineering.purdue.edu/~hongtan/pubs/PDFfiles/C63_JRKimTan_HS2014.pdf). No human preference, speaker-response, or typing-performance test has been run for Softnote. Treat it as an optional confirmation sound, not a proven speed or accuracy aid.
