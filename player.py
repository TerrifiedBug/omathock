#!/usr/bin/env python3
"""OmaThock's sound player: mixes key sounds into one PipeWire stream.

Service.qml starts this as a child, feeds it one JSON object per line on stdin
and reads JSON events back on stdout. Audio lives here and not in the shell
because Qt 6.11's PipeWire backend can wedge the shell process after a
WirePlumber restart; a helper that dies is a helper the shell restarts.

Standard library only: libpulse-simple over ctypes, `wave` for 16-bit WAV,
`ffmpeg` (shipped with Omarchy through mpv) for everything else.

stdin:   {"cmd":"load","dir":<pack dir>,"takes":[take...],"volume":0-100}
         {"cmd":"play","take":take}
         {"cmd":"volume","value":0-100}
stdout:  {"evt":"ready"}  {"evt":"loaded","dir":..,"takes":n,"failed":[..]}
         {"evt":"tick"}  {"evt":"error","msg":..}  {"evt":"trace","onset_ms":..}
A take is {"file": <relative path>, "start": <ms>, "end": <ms, 0 = end of file>}.
EOF on stdin ends the process once the current voices have played (1 s cap).
"""
import array
import collections
import ctypes
import json
import os
import subprocess
import sys
import threading
import time
import wave
from itertools import repeat
from operator import add, mul

CHUNK_MS = 10
MAX_VOICES = 16
IDLE_FREE_S = 30
TICK_S = 2
RETRY_S = 1
DEFAULT_RATE = 48000

PA_STREAM_PLAYBACK = 1
PA_SAMPLE_S16LE = 3
PA_NEG1 = 0xFFFFFFFF

TRACE = os.environ.get("OMATHOCK_TRACE") == "1"


class SampleSpec(ctypes.Structure):
    _fields_ = [("format", ctypes.c_int), ("rate", ctypes.c_uint32), ("channels", ctypes.c_uint8)]


class BufAttr(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ("maxlength", "tlength", "prebuf", "minreq", "fragsize")]


def load_pulse():
    """The libpulse-simple handle with its prototypes set. OSError when absent."""
    lib = ctypes.CDLL("libpulse-simple.so.0")
    lib.pa_simple_new.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
                                  ctypes.POINTER(SampleSpec), ctypes.c_void_p, ctypes.POINTER(BufAttr),
                                  ctypes.POINTER(ctypes.c_int)]
    lib.pa_simple_new.restype = ctypes.c_void_p
    lib.pa_simple_write.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
    lib.pa_simple_write.restype = ctypes.c_int
    lib.pa_simple_free.argtypes = [ctypes.c_void_p]
    lib.pa_simple_free.restype = None
    lib.pa_strerror.argtypes = [ctypes.c_int]
    lib.pa_strerror.restype = ctypes.c_char_p
    return lib


class PulseError(RuntimeError):
    pass


class Stream:
    """One playback stream at a fixed rate, stereo s16le, 20 ms of buffer."""

    def __init__(self, lib, rate):
        self.lib = lib
        self.rate = rate
        spec = SampleSpec(PA_SAMPLE_S16LE, rate, 2)
        frame = 4
        ms = rate * frame // 1000
        attr = BufAttr(PA_NEG1, 20 * ms, 10 * ms, 10 * ms, PA_NEG1)
        err = ctypes.c_int()
        self.handle = lib.pa_simple_new(None, b"OmaThock", PA_STREAM_PLAYBACK, None, b"keys",
                                        ctypes.byref(spec), None, ctypes.byref(attr), ctypes.byref(err))
        if not self.handle:
            raise PulseError("pulse: " + self._strerror(err.value))

    def _strerror(self, code):
        text = self.lib.pa_strerror(code)
        return text.decode("utf-8", "replace") if text else "error %d" % code

    def write(self, data):
        err = ctypes.c_int()
        if self.lib.pa_simple_write(self.handle, data, len(data), ctypes.byref(err)) < 0:
            raise PulseError("pulse: " + self._strerror(err.value))

    def close(self):
        if self.handle:
            self.lib.pa_simple_free(self.handle)
            self.handle = None


class DecodeError(Exception):
    pass


def take_key(take):
    return "%s@%s-%s" % (take["file"], take["start"], take["end"])


def safe_file(name):
    """Relative and without "..": inside the pack directory. Model.js checks the same."""
    return isinstance(name, str) and name != "" and not name.startswith("/") and ".." not in name


def wav_rate(path):
    try:
        with wave.open(path, "rb") as w:
            return w.getframerate()
    except (wave.Error, EOFError, OSError):
        return None


def elect_rate(directory, takes):
    """The most common frame rate among the pack's WAV files, else 48000.
    Every bundled pack is uniform, so this is the rate nothing gets resampled to."""
    rates = collections.Counter()
    seen = set()
    for take in takes:
        name = take.get("file")
        if not safe_file(name) or name in seen or not name.lower().endswith(".wav"):
            continue
        seen.add(name)
        rate = wav_rate(os.path.join(directory, name))
        if rate:
            rates[rate] += 1
    return rates.most_common(1)[0][0] if rates else DEFAULT_RATE


def _to_stereo(samples, channels):
    if channels == 2:
        return samples
    out = array.array("h", bytes(len(samples) * 4))
    out[0::2] = samples
    out[1::2] = samples
    return out


def _decode_wav(path, rate):
    """Interleaved stereo s16 at `rate`, or None when the file needs ffmpeg."""
    try:
        with wave.open(path, "rb") as w:
            if w.getsampwidth() != 2 or w.getframerate() != rate or w.getnchannels() not in (1, 2):
                return None
            samples = array.array("h", w.readframes(w.getnframes()))
            if sys.byteorder != "little":
                samples.byteswap()
            return _to_stereo(samples, w.getnchannels())
    except (wave.Error, EOFError):
        return None


def _decode_ffmpeg(path, rate):
    cmd = ["ffmpeg", "-v", "error", "-nostdin", "-i", path, "-f", "s16le", "-ac", "2", "-ar", str(rate), "-"]
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, check=False)
    except FileNotFoundError:
        raise DecodeError("ffmpeg not installed")
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise DecodeError(detail[-1] if detail else "ffmpeg exit %d" % proc.returncode)
    samples = array.array("h", proc.stdout[: len(proc.stdout) // 2 * 2])
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def decode_file(path, rate):
    """One file as interleaved stereo s16 at `rate`. DecodeError with a reason."""
    if not os.path.isfile(path):
        raise DecodeError("no such file")
    samples = _decode_wav(path, rate) if path.lower().endswith(".wav") else None
    if samples is None:
        samples = _decode_ffmpeg(path, rate)
    if len(samples) == 0:
        raise DecodeError("empty")
    return samples


def slice_take(samples, rate, start_ms, end_ms):
    """The [start, end) millisecond window of a decoded file; end 0 is the end."""
    frames = len(samples) // 2
    start = max(0, min(frames, round(start_ms * rate / 1000)))
    end = frames if end_ms <= 0 else max(start, min(frames, round(end_ms * rate / 1000)))
    return samples[start * 2:end * 2]


def decode_pack(directory, takes, rate):
    """{take key: samples} for every take, plus "<file>: <reason>" per failure.
    A file is decoded once however many takes slice it."""
    bank = {}
    failed = []
    files = {}
    for take in takes:
        name = take.get("file")
        key = take_key(take)
        if not safe_file(name):
            failed.append("%s: outside the pack" % name)
            continue
        if name not in files:
            try:
                files[name] = decode_file(os.path.join(directory, name), rate)
            except DecodeError as e:
                files[name] = None
                failed.append("%s: %s" % (name, e))
        samples = files[name]
        if samples is None:
            continue
        piece = slice_take(samples, rate, float(take.get("start", 0)), float(take.get("end", 0)))
        if len(piece) == 0:
            failed.append("%s: empty slice" % key)
            continue
        bank[key] = piece
    return bank, failed


class Voice:
    __slots__ = ("samples", "pos", "started")

    def __init__(self, samples, started):
        self.samples = samples
        self.pos = 0
        self.started = started


class Mixer:
    """Voices summed into 10 ms chunks on its own thread; every public method
    is safe to call from the stdin thread. The stream is only ever touched by
    the mixer thread, so nothing can free it under a write."""

    def __init__(self, lib, emit):
        self.lib = lib
        self.emit = emit
        self.cond = threading.Condition()
        self.voices = collections.deque()
        self.bank = {}
        self.rate = DEFAULT_RATE
        self.want_rate = DEFAULT_RATE
        self.gain = 1.0
        self.stream = None
        self.last_play = 0.0
        self.last_fail = -RETRY_S
        self.stopping = False
        self.thread = threading.Thread(target=self.run, name="mixer", daemon=True)
        self._resize()

    def _resize(self):
        self.chunk_samples = self.rate * CHUNK_MS // 1000 * 2
        self.silence = bytes(self.chunk_samples * 2)

    def start(self):
        self.thread.start()

    def load(self, directory, takes, volume):
        """Decode outside the lock, then swap the whole bank in one go. A rate
        change is applied by the mixer thread."""
        rate = elect_rate(directory, takes)
        bank, failed = decode_pack(directory, takes, rate)
        with self.cond:
            if rate != self.want_rate:
                self.want_rate = rate
                self.voices.clear()
            self.bank = bank
            self.set_volume(volume)
            self.cond.notify()
        return len(bank), failed

    def set_volume(self, value):
        try:
            value = float(value)
        except (TypeError, ValueError):
            return
        if value != value:
            return
        self.gain = max(0.0, min(100.0, value)) / 100.0

    def play(self, take):
        """True when the take is known and queued."""
        try:
            samples = self.bank.get(take_key(take))
        except (KeyError, TypeError):
            samples = None
        if samples is None:
            return False
        now = time.monotonic()
        with self.cond:
            if self.stream is None and now - self.last_fail < RETRY_S:
                return True
            if len(self.voices) >= MAX_VOICES:
                self.voices.popleft()
            self.voices.append(Voice(samples, now if TRACE else None))
            self.last_play = now
            self.cond.notify()
        return True

    def stop(self):
        with self.cond:
            self.stopping = True
            self.cond.notify()

    def mix(self):
        """One chunk of the current voices as s16le bytes, advancing them.
        Caller holds the lock."""
        n = self.chunk_samples
        acc = None
        for voice in self.voices:
            seg = voice.samples[voice.pos:voice.pos + n]
            voice.pos += n
            if len(seg) < n:
                seg = seg + array.array("h", bytes((n - len(seg)) * 2))
            acc = seg if acc is None else array.array("i", map(add, acc, seg))
        while self.voices and self.voices[0].pos >= len(self.voices[0].samples):
            self.voices.popleft()
        if acc is None or self.gain == 0.0:
            return self.silence
        if self.gain != 1.0:
            acc = map(int, map(mul, acc, repeat(self.gain)))
        elif acc.typecode == "h" and sys.byteorder == "little":
            # One voice at unity: already in range, nothing to sum or clamp.
            return acc.tobytes()
        out = array.array("h", map(min, map(max, acc, repeat(-32768)), repeat(32767)))
        if sys.byteorder != "little":
            out.byteswap()
        return out.tobytes()

    def _close_stream(self):
        if self.stream is not None:
            self.stream.close()
            self.stream = None

    def _fail(self, error):
        self._close_stream()
        self.voices.clear()
        self.last_fail = time.monotonic()
        self.emit({"evt": "error", "msg": str(error)})

    def _apply_rate(self):
        if self.want_rate != self.rate:
            self._close_stream()
            self.rate = self.want_rate
            self._resize()

    def run(self):
        next_tick = time.monotonic() + TICK_S
        while True:
            with self.cond:
                while not self.voices and not self.stopping:
                    now = time.monotonic()
                    if now >= next_tick:
                        self.emit({"evt": "tick"})
                        next_tick = now + TICK_S
                    if self.stream is not None and now - self.last_play >= IDLE_FREE_S:
                        self._close_stream()
                    self._apply_rate()
                    self.cond.wait(next_tick - now)
                if self.stopping and not self.voices:
                    self._close_stream()
                    return
                self._apply_rate()
                if self.stream is None:
                    try:
                        self.stream = Stream(self.lib, self.rate)
                    except PulseError as e:
                        self._fail(e)
                        continue
                started = [v for v in self.voices if v.started is not None]
                chunk = self.mix()
                tail = not self.voices
                stream = self.stream
                silence = self.silence
            try:
                stream.write(chunk)
                if tail:
                    stream.write(silence)
            except PulseError as e:
                with self.cond:
                    if self.stream is stream:
                        self._fail(e)
                continue
            for voice in started:
                self.emit({"evt": "trace", "onset_ms": round((time.monotonic() - voice.started) * 1000, 2)})
                voice.started = None
            now = time.monotonic()
            if now >= next_tick:
                self.emit({"evt": "tick"})
                next_tick = now + TICK_S


def serve(lines, mixer, emit):
    """The stdin loop: one command per line until EOF."""
    for line in lines:
        try:
            msg = json.loads(line)
            cmd = msg["cmd"]
        except (ValueError, TypeError, KeyError):
            emit({"evt": "error", "msg": "bad command"})
            continue
        if cmd == "load" and isinstance(msg.get("takes"), list) and isinstance(msg.get("dir"), str):
            count, failed = mixer.load(msg["dir"], [t for t in msg["takes"] if isinstance(t, dict)], msg.get("volume", 100))
            emit({"evt": "loaded", "dir": msg["dir"], "takes": count, "failed": failed})
        elif cmd == "play" and isinstance(msg.get("take"), dict):
            if not mixer.play(msg["take"]):
                emit({"evt": "error", "msg": "unknown take %s" % take_key(msg["take"])})
        elif cmd == "volume":
            mixer.set_volume(msg.get("value"))
        else:
            emit({"evt": "error", "msg": "bad command"})


def main():
    try:
        lib = load_pulse()
    except OSError as e:
        sys.stderr.write("libpulse-simple.so.0 unavailable: %s\n" % e)
        sys.stderr.flush()
        return 3
    out_lock = threading.Lock()

    def emit(event):
        with out_lock:
            sys.stdout.write(json.dumps(event) + "\n")
            sys.stdout.flush()

    mixer = Mixer(lib, emit)
    mixer.start()
    emit({"evt": "ready"})
    try:
        serve(iter(sys.stdin.readline, ""), mixer, emit)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    mixer.stop()
    mixer.thread.join(1.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
