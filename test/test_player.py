"""player.py without a sound card: libpulse is faked, WAVs are generated.

    python3 -m unittest discover -s test -p 'test_*.py'

OMATHOCK_TEST_AUDIO=1 adds one real run of player.py against PipeWire.
"""
import array
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location("player", os.path.join(ROOT, "player.py"))
player = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(player)


def write_wav(path, rate, channels, frames, value=1000):
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(array.array("h", [value] * (frames * channels)).tobytes())


def take(file, start=0, end=0):
    return {"file": file, "start": start, "end": end}


class FakePulse:
    """Enough of libpulse-simple for the mixer: records every write."""

    def __init__(self):
        self.written = []
        self.streams = 0

    def pa_simple_new(self, *args):
        self.streams += 1
        return 1

    def pa_simple_write(self, handle, data, size, err):
        self.written.append(bytes(data[:size]))
        return 0

    def pa_simple_free(self, handle):
        self.streams -= 1

    def pa_strerror(self, code):
        return b"fake"


class PackTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="omathock-test-")
        self.addCleanup(shutil.rmtree, self.dir)
        write_wav(os.path.join(self.dir, "stereo.wav"), 44100, 2, 4410)
        write_wav(os.path.join(self.dir, "mono.wav"), 44100, 1, 2205)
        write_wav(os.path.join(self.dir, "other.wav"), 48000, 2, 480)
        self.takes = [take("stereo.wav"), take("mono.wav"), take("other.wav")]

    def test_rate_election_picks_the_most_common_wav_rate(self):
        self.assertEqual(player.elect_rate(self.dir, self.takes), 44100)
        self.assertEqual(player.elect_rate(self.dir, [take("missing.ogg")]), 48000)

    def test_mono_decodes_to_interleaved_stereo(self):
        out = player.decode_file(os.path.join(self.dir, "mono.wav"), 44100)
        self.assertEqual(len(out), 2205 * 2)
        self.assertEqual(out[0::2], out[1::2])
        self.assertEqual(out[0], 1000)

    def test_sprite_slice_is_exactly_the_window(self):
        samples = player.decode_file(os.path.join(self.dir, "stereo.wav"), 44100)
        piece = player.slice_take(samples, 44100, 20, 60)
        self.assertEqual(len(piece) // 2, 40 * 44100 // 1000)
        self.assertEqual(len(player.slice_take(samples, 44100, 50, 0)) // 2, 4410 - 2205)

    def test_decode_pack_reports_failures_and_keeps_going(self):
        bank, failed = player.decode_pack(self.dir, self.takes + [take("nope.wav"), take("../x.wav"), take("x..y.wav")], 44100)
        self.assertEqual(sorted(bank), ["mono.wav@0-0", "other.wav@0-0", "stereo.wav@0-0"])
        self.assertEqual(failed, ["nope.wav: no such file", "../x.wav: outside the pack", "x..y.wav: outside the pack"])
        # The 48 kHz file was resampled to the pack rate by ffmpeg.
        self.assertAlmostEqual(len(bank["other.wav@0-0"]) // 2, 441, delta=20)


class MixerTests(unittest.TestCase):
    def setUp(self):
        self.lib = FakePulse()
        self.events = []
        self.mixer = player.Mixer(self.lib, self.events.append)
        self.mixer.rate = self.mixer.want_rate = 44100
        self.mixer._resize()
        n = self.mixer.chunk_samples
        self.loud = array.array("h", [32767] * (n * 2))
        self.quiet = array.array("h", [100] * (n // 2))
        self.mixer.bank = {"loud@0-0": self.loud, "quiet@0-0": self.quiet}

    def chunk(self):
        return array.array("h", self.mixer.mix())

    def test_two_full_scale_voices_clamp(self):
        self.mixer.play(take("loud"))
        self.mixer.play(take("loud"))
        out = self.chunk()
        self.assertEqual(len(out), self.mixer.chunk_samples)
        self.assertEqual(max(out), 32767)
        self.assertEqual(min(out), 32767)

    def test_seventeenth_voice_evicts_the_oldest(self):
        self.mixer.play(take("quiet"))
        for _ in range(16):
            self.mixer.play(take("loud"))
        self.assertEqual(len(self.mixer.voices), 16)
        self.assertTrue(all(v.samples is self.loud for v in self.mixer.voices))

    def test_volume_zero_is_silence_and_gain_scales(self):
        self.mixer.set_volume(0)
        self.mixer.play(take("quiet"))
        self.assertEqual(self.mixer.mix(), self.mixer.silence)
        self.mixer.set_volume(50)
        self.mixer.play(take("quiet"))
        self.assertEqual(self.chunk()[0], 50)

    def test_finished_voices_leave_and_the_tail_is_padded(self):
        self.mixer.play(take("quiet"))
        first = self.chunk()
        self.assertEqual(first[-1], 0)
        self.assertEqual(len(self.mixer.voices), 0)
        self.assertEqual(self.mixer.mix(), self.mixer.silence)

    def test_unknown_take_is_refused(self):
        self.assertFalse(self.mixer.play(take("nope")))
        self.assertTrue(self.mixer.play(take("quiet")))


class ProtocolTests(unittest.TestCase):
    def test_bad_line_reports_and_continues(self):
        lib = FakePulse()
        events = []
        mixer = player.Mixer(lib, events.append)
        player.serve(["garbage\n", '{"cmd":"nope"}\n', '{"cmd":"volume","value":25}\n', '{"cmd":"play","take":{"file":"x","start":0,"end":0}}\n'],
                     mixer, events.append)
        self.assertEqual(events, [
            {"evt": "error", "msg": "bad command"},
            {"evt": "error", "msg": "bad command"},
            {"evt": "error", "msg": "unknown take x@0-0"}
        ])
        self.assertEqual(mixer.gain, 0.25)

    def test_thread_plays_through_the_fake_stream_and_stops(self):
        lib = FakePulse()
        events = []
        mixer = player.Mixer(lib, events.append)
        mixer.rate = mixer.want_rate = 44100
        mixer._resize()
        mixer.bank = {"q@0-0": array.array("h", [7] * mixer.chunk_samples * 3)}
        mixer.start()
        mixer.play(take("q"))
        deadline = time.monotonic() + 2
        while len(lib.written) < 4 and time.monotonic() < deadline:
            time.sleep(0.01)
        mixer.stop()
        mixer.thread.join(1)
        self.assertFalse(mixer.thread.is_alive())
        self.assertEqual(lib.streams, 0)
        self.assertEqual([len(w) for w in lib.written], [mixer.chunk_samples * 2] * 4)
        self.assertEqual(lib.written[3], mixer.silence)


@unittest.skipUnless(os.environ.get("OMATHOCK_TEST_AUDIO") == "1", "set OMATHOCK_TEST_AUDIO=1 for a real PipeWire run")
class RealAudioTest(unittest.TestCase):
    def test_subprocess_plays_ticks_and_exits(self):
        pack = os.path.join(ROOT, "soundpacks", "cherry-mx-blue")
        lines = [
            {"cmd": "load", "dir": pack, "takes": [take("1.wav")], "volume": 60},
            {"cmd": "play", "take": take("1.wav")}
        ]
        proc = subprocess.Popen([sys.executable, "-u", os.path.join(ROOT, "player.py")],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc.stdin.write("".join(json.dumps(l) + "\n" for l in lines).encode())
        proc.stdin.flush()
        time.sleep(2.3)
        started = time.monotonic()
        out, err = proc.communicate(timeout=3)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(proc.returncode, 0, err)
        events = [json.loads(l) for l in out.decode().splitlines()]
        self.assertEqual(events[0], {"evt": "ready"})
        loaded = [e for e in events if e["evt"] == "loaded"]
        self.assertEqual(loaded[0]["failed"], [])
        self.assertEqual(loaded[0]["takes"], 1)
        self.assertIn({"evt": "tick"}, events)


if __name__ == "__main__":
    unittest.main()
