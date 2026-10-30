"""audioprep: alignment/padding math, missing tracks, resampling, m4a creation (afconvert), idempotency."""
import json
import logging
import math
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from mcap import audioprep, wavio  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())

try:
    import scipy  # noqa: F401
    HAVE_SCIPY = True
except ImportError:
    HAVE_SCIPY = False

HAVE_AFCONVERT = audioprep.afconvert_path() is not None
SR48 = 48000


def sine(freq, seconds, sr=SR48, amp=0.5):
    t = np.arange(int(round(seconds * sr))) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def dominant_freq(x, sr):
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float(np.argmax(spec) * sr / len(x))


def rms_db(x):
    return 10 * math.log10(float(np.mean(np.square(x, dtype=np.float64))) + 1e-20)


def afinfo_duration(path):
    out = subprocess.run(["afinfo", str(path)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("estimated duration"):
            return float(line.split(":")[1].split()[0])
    raise AssertionError(f"no duration in afinfo output for {path}:\n{out}")


class SessionDirCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def make_session(self, mic=None, remote=None, mic_off=0.0, remote_off=0.0, sr=SR48):
        """Write the given float arrays as mic.wav / remote.wav and return the session.json dict."""
        tracks = {}
        for name, x, off in (("mic", mic, mic_off), ("remote", remote, remote_off)):
            if x is None:
                continue
            wavio.write_wav_int16(self.dir / f"{name}.wav", x, sr)
            tracks[name] = {"file": f"{name}.wav", "sample_rate": sr, "channels": 1, "start_offset_sec": off}
        session = {"schema": 1, "session_id": "t", "tracks": tracks}
        (self.dir / "session.json").write_text(json.dumps(session))
        return session


class ResampleTest(unittest.TestCase):
    def test_output_length_is_ceil_n_over_3(self):
        for n in (0, 1, 2, 3, 4, 100, 47999, 48000, 48001):
            with self.subTest(n=n):
                self.assertEqual(len(audioprep.resample(np.zeros(n, np.float32), SR48)), -(-n // 3))

    def test_pitch_and_gain_preserved_in_the_passband(self):
        for f in (200.0, 1000.0, 3000.0, 6000.0):
            with self.subTest(f=f):
                y = audioprep.resample(sine(f, 4.0, amp=0.5), SR48)
                core = y[1600:-1600]
                self.assertAlmostEqual(dominant_freq(core, 16000), f, delta=2.0)
                self.assertAlmostEqual(rms_db(core), rms_db(sine(f, 1.0, amp=0.5)), delta=0.3)

    def test_aliasing_is_suppressed(self):
        """A 10 kHz tone at 48 kHz would fold to 6 kHz at 16 kHz without the anti-alias filter."""
        y = audioprep.resample(sine(10000.0, 4.0, amp=0.5), SR48)
        self.assertLess(rms_db(y[1600:-1600]), rms_db(sine(1000, 1.0, amp=0.5)) - 60)

    def test_zero_phase_no_time_shift(self):
        x = np.zeros(SR48 * 2, np.float32)
        positions = (30000, 61233, 90000)             # 61233 = 3 * 20411: lands exactly on an output sample
        for k in positions:
            x[k] = 1.0
        y = audioprep.resample(x, SR48)
        for k in positions:
            lo = k // 3 - 3
            self.assertLessEqual(abs(int(np.argmax(np.abs(y[lo: lo + 7]))) - 3), 1, f"impulse at {k} moved")

    def test_blocking_does_not_change_the_result_and_matches_a_direct_convolution(self):
        rng = np.random.default_rng(3)
        for n in (0, 1, 7, 100, 1001, 5000):
            x = rng.standard_normal(n).astype(np.float32)
            h = audioprep._lowpass_taps(3, SR48).astype(np.float64)
            centre = len(h) // 2
            padded = np.concatenate([np.zeros(centre), x.astype(np.float64), np.zeros(len(h))])
            direct = np.array([np.dot(h, padded[i * 3: i * 3 + len(h)]) for i in range(-(-n // 3))], np.float32)    # y[i] = sum h[k] x[3i + k - centre]
            for block in (1, 5, 64, 1 << 18):
                got = audioprep._decimate(x, 3, block=block)
                self.assertEqual(len(got), len(direct))
                if n:
                    self.assertLess(float(np.abs(got - direct).max()), 1e-5, (n, block))

    @unittest.skipUnless(HAVE_SCIPY, "scipy not installed")
    def test_matches_scipy_resample_poly_with_the_same_filter(self):
        from scipy.signal import resample_poly
        x = np.random.default_rng(4).standard_normal(30001).astype(np.float32)
        ref = resample_poly(x, 1, 3, window=audioprep._lowpass_taps(3, SR48)).astype(np.float32)
        got = audioprep.resample(x, SR48)
        self.assertEqual(len(got), len(ref))
        self.assertLess(float(np.abs(got - ref).max()), 1e-4)

    def test_other_rates(self):
        x16 = sine(1000, 1.0, sr=16000)
        np.testing.assert_array_equal(audioprep.resample(x16, 16000), x16)
        y = audioprep.resample(sine(1500, 3.0, sr=96000), 96000)         # integer ratio 6
        self.assertEqual(len(y), 48000)
        self.assertAlmostEqual(dominant_freq(y[800:-800], 16000), 1500, delta=2)
        y = audioprep.resample(sine(1500, 3.0, sr=32000), 32000)
        self.assertEqual(len(y), 48000)

    @unittest.skipUnless(HAVE_SCIPY, "scipy not installed")
    def test_non_integer_ratio_uses_scipy(self):
        y = audioprep.resample(sine(1000, 3.0, sr=44100), 44100)
        self.assertAlmostEqual(len(y), 48000, delta=1)
        self.assertAlmostEqual(dominant_freq(y[800:-800], 16000), 1000, delta=2)

    def test_mix_clipping_protection(self):
        a, b = sine(440, 1.0, amp=0.9), sine(440, 1.0, amp=0.9)
        mixed = audioprep.mix_tracks([a, b])
        self.assertAlmostEqual(float(np.abs(mixed).max()), audioprep.CLIP_CEILING, places=3)
        np.testing.assert_allclose(mixed / np.abs(mixed).max(), (a + b) / np.abs(a + b).max(), atol=1e-5)   # same shape, just scaled
        quiet = audioprep.mix_tracks([sine(440, 1.0, amp=0.2), sine(660, 1.0, amp=0.2)])
        self.assertLess(float(np.abs(quiet).max()), 0.45)                                                    # untouched
        np.testing.assert_allclose(quiet, sine(440, 1.0, amp=0.2) + sine(660, 1.0, amp=0.2), atol=1e-6)


class AlignmentTest(SessionDirCase):
    def test_offsets_pad_the_front_and_all_tracks_have_equal_length(self):
        mic = np.zeros(SR48 * 3, np.float32)
        mic[SR48] = 1.0                                       # 1.0 s into the mic file
        remote = np.zeros(SR48 * 2, np.float32)
        remote[SR48 // 2] = 1.0                               # 0.5 s into the remote file
        session = self.make_session(mic, remote, mic_off=0.25, remote_off=1.5)
        p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.sample_rate, 16000)
        self.assertEqual(set(p.tracks), {"mic", "remote"})
        self.assertEqual(len(p.tracks["mic"]), len(p.tracks["remote"]))
        # session length = max(0.25 + 3.0, 1.5 + 2.0) = 3.5 s
        self.assertAlmostEqual(p.duration_sec, 3.5, delta=1 / 16000)
        self.assertEqual(len(p.tracks["mic"]), 56000)
        self.assertEqual(p.tracks["mic"].dtype, np.float32)
        self.assertAlmostEqual(int(np.argmax(np.abs(p.tracks["mic"]))), int((0.25 + 1.0) * 16000), delta=1)
        self.assertAlmostEqual(int(np.argmax(np.abs(p.tracks["remote"]))), int((1.5 + 0.5) * 16000), delta=1)
        self.assertLess(float(np.abs(p.tracks["mic"][:int(0.25 * 16000) - 8]).max()), 1e-6)       # front padding is silence
        self.assertEqual(p.missing, [])

    def test_offsets_round_to_the_nearest_native_sample(self):
        x = sine(440, 1.0)
        session = self.make_session(x, x, mic_off=0.0, remote_off=0.0333333)
        p = audioprep.prepare_audio(self.dir, session)
        lead = int(np.argmax(np.abs(p.tracks["remote"]) > 0.05))
        self.assertAlmostEqual(lead / 16000, 0.0333, delta=0.003)

    def test_bad_offsets_fall_back_to_zero_with_a_warning(self):
        x = sine(440, 1.0)
        session = self.make_session(x, x)
        session["tracks"]["mic"]["start_offset_sec"] = -2.0
        session["tracks"]["remote"]["start_offset_sec"] = "abc"
        p = audioprep.prepare_audio(self.dir, session)
        self.assertAlmostEqual(p.duration_sec, 1.0, delta=0.001)
        self.assertEqual(sum("start_offset_sec" in w for w in p.warnings), 2)

    def test_absurd_offset_is_clamped(self):
        x = sine(440, 0.5)
        session = self.make_session(x, None)
        session["tracks"]["mic"]["start_offset_sec"] = 1e12
        with mock.patch.object(audioprep, "MAX_OFFSET_SEC", 2.0):
            p = audioprep.prepare_audio(self.dir, session)
        self.assertAlmostEqual(p.duration_sec, 2.5, delta=0.001)

    def test_16k_native_tracks_are_not_corrupted_by_the_mix(self):
        """A 16 kHz source passes through resample() unchanged; the archive mix must not add into the ASR array."""
        a, b = sine(440, 2.0, sr=16000, amp=0.3), sine(880, 2.0, sr=16000, amp=0.3)
        session = self.make_session(a, b, sr=16000)
        p = audioprep.prepare_audio(self.dir, session)
        np.testing.assert_allclose(p.tracks["mic"], np.round(a * 32768) / 32768, atol=1e-6)
        np.testing.assert_allclose(p.tracks["remote"], np.round(b * 32768) / 32768, atol=1e-6)

    def test_different_native_rates_still_work(self):
        session = self.make_session(sine(440, 2.0, sr=48000), None)
        wavio.write_wav_int16(self.dir / "remote.wav", sine(660, 2.0, sr=32000), 32000)
        session["tracks"]["remote"] = {"file": "remote.wav", "sample_rate": 32000, "start_offset_sec": 0.0}
        p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.missing, [])
        self.assertEqual(len(p.tracks["mic"]), len(p.tracks["remote"]))
        self.assertAlmostEqual(p.duration_sec, 2.0, delta=0.001)
        if HAVE_AFCONVERT:
            self.assertEqual(set(p.archive_files), {"audio", "mic", "remote"})

    def test_a_track_that_fails_while_being_read_is_treated_as_missing(self):
        session = self.make_session(sine(440, 1.0), sine(660, 1.0))
        real = wavio.read_wav_padded

        def flaky(path, *args, **kwargs):
            if Path(path).name == "mic.wav":
                raise OSError("disk error")
            return real(path, *args, **kwargs)
        with mock.patch.object(wavio, "read_wav_padded", flaky):
            p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.missing, ["mic"])
        self.assertEqual(float(np.abs(p.tracks["mic"]).max()), 0.0)

    def test_header_sample_rate_wins_over_session_json(self):
        session = self.make_session(sine(440, 1.0), sine(440, 1.0))
        session["tracks"]["mic"]["sample_rate"] = 44100
        p = audioprep.prepare_audio(self.dir, session)
        self.assertAlmostEqual(p.duration_sec, 1.0, delta=0.001)
        self.assertTrue(any("44100" in w for w in p.warnings))

    def test_a_sample_rate_in_session_json_that_is_not_a_number_does_not_lose_the_track(self):
        """review_transcribe: int(declared) raised and a perfectly good WAV counted as a missing track."""
        for bad in ("48k", [48000], {"rate": 48000}, "forty-eight"):
            with self.subTest(bad=bad):
                session = self.make_session(sine(440, 2.0), sine(660, 2.0))
                session["tracks"]["mic"]["sample_rate"] = bad
                p = audioprep.prepare_audio(self.dir, session, force=True)
                self.assertEqual(p.missing, [])
                self.assertAlmostEqual(p.duration_sec, 2.0, delta=0.01)
                self.assertTrue(any("not a number" in w for w in p.warnings), p.warnings)
                self.assertGreater(float(np.abs(p.tracks["mic"]).max()), 0.3)

    def test_stale_header_from_a_crashed_recording_is_recovered(self):
        x = sine(440, 4.0)
        session = self.make_session(x, None)
        raw = (self.dir / "mic.wav").read_bytes()
        stale = bytearray(raw[:-1])                                                          # all 4 s on disk, plus a torn byte
        stale[4:8] = (36 + 2 * SR48).to_bytes(4, "little")                                   # but the header still says 1 s
        stale[40:44] = (2 * SR48).to_bytes(4, "little")
        (self.dir / "mic.wav").write_bytes(bytes(stale))
        p = audioprep.prepare_audio(self.dir, session)
        self.assertAlmostEqual(p.duration_sec, 4.0, delta=0.01)
        self.assertGreater(rms_db(p.tracks["mic"][-8000:]), -12)                             # the tail is really there


class MissingTrackTest(SessionDirCase):
    def test_track_absent_from_session_json(self):
        session = self.make_session(sine(440, 2.0), None)
        p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.missing, ["remote"])
        self.assertEqual(len(p.tracks["remote"]), len(p.tracks["mic"]))
        self.assertEqual(float(np.abs(p.tracks["remote"]).max()), 0.0)
        self.assertIn("mic", p.archive_files if HAVE_AFCONVERT else {"mic": 1})
        self.assertNotIn("remote", p.archive_files)                       # no m4a for a track that does not exist
        self.assertTrue(any("remote" in w for w in p.warnings))

    def test_wav_file_listed_but_gone_empty_or_corrupt(self):
        for label, action in (("gone", lambda: (self.dir / "mic.wav").unlink()),
                              ("header only", lambda: wavio.write_wav_int16(self.dir / "mic.wav", np.zeros(0, np.float32), SR48)),
                              ("garbage", lambda: (self.dir / "mic.wav").write_bytes(b"not a wav at all")),
                              ("zero bytes", lambda: (self.dir / "mic.wav").write_bytes(b""))):
            with self.subTest(label):
                session = self.make_session(sine(440, 1.0), sine(660, 1.0))
                action()
                p = audioprep.prepare_audio(self.dir, session, force=True)
                self.assertEqual(p.missing, ["mic"])
                self.assertEqual(float(np.abs(p.tracks["mic"]).max()), 0.0)
                self.assertGreater(float(np.abs(p.tracks["remote"]).max()), 0.1)

    def test_both_tracks_missing_raises_no_audio(self):
        with self.assertRaisesRegex(audioprep.NoAudioError, "no audio"):
            audioprep.prepare_audio(self.dir, self.make_session(None, None))
        for session in ({}, {"tracks": None}, {"tracks": {"mic": "oops"}}):
            with self.assertRaises(audioprep.NoAudioError):
                audioprep.prepare_audio(self.dir, session)

    def test_unusable_header_rate_counts_as_missing(self):
        session = self.make_session(sine(440, 1.0, sr=SR48), None)
        wavio.write_wav_int16(self.dir / "mic.wav", np.zeros(100, np.float32), 1)       # 1 Hz is nonsense
        with self.assertRaises(audioprep.NoAudioError):
            audioprep.prepare_audio(self.dir, session)

    def test_path_traversal_in_file_name_is_ignored(self):
        session = self.make_session(sine(440, 1.0), sine(440, 1.0))
        session["tracks"]["mic"]["file"] = "../../etc/mic.wav"
        p = audioprep.prepare_audio(self.dir, session)                          # falls back to <session_dir>/mic.wav
        self.assertEqual(p.missing, [])


@unittest.skipUnless(HAVE_AFCONVERT, "afconvert not available")
class ArchiveTest(SessionDirCase):
    def test_the_archived_m4a_is_used_when_the_wav_is_gone(self):
        self.make_session(sine(440, 1.0), sine(660, 1.0))
        audioprep.prepare_audio(self.dir, json.loads((self.dir / "session.json").read_text()))
        (self.dir / "mic.wav").unlink()
        (self.dir / "remote.wav").unlink()
        session = {"tracks": {"mic": {"file": "mic.wav"}, "remote": {"file": "remote.wav"}}}
        p = audioprep.prepare_audio(self.dir, session, force=True)
        self.assertNotIn("mic", p.missing)
        self.assertGreater(float(np.abs(p.tracks["mic"]).max()), 0.1)

    def test_m4a_files_are_created_with_the_session_duration(self):
        mic = sine(440, 5.0, amp=0.3)
        remote = sine(660, 3.0, amp=0.3)
        session = self.make_session(mic, remote, mic_off=0.2, remote_off=1.0)
        p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(set(p.archive_files), {"audio", "mic", "remote"})
        for name, path in p.archive_files.items():
            self.assertEqual(path, self.dir / f"{name}.m4a")
            self.assertGreater(path.stat().st_size, 1000)
            self.assertAlmostEqual(afinfo_duration(path), 5.2, delta=0.05, msg=name)       # every file spans the whole session
        self.assertEqual(sorted(q.name for q in self.dir.iterdir()),
                         ["audio.m4a", "mic.m4a", "mic.wav", "remote.m4a", "remote.wav", "session.json"])   # no temp leftovers

    def test_audio_m4a_is_a_mono_mix_of_both_tracks_without_clipping(self):
        a, b = sine(440, 3.0, amp=0.9), sine(880, 3.0, amp=0.9)
        session = self.make_session(a, b)
        p = audioprep.prepare_audio(self.dir, session)
        wav = self.dir / "decoded.wav"
        audioprep.decode_to_wav(p.archive_files["audio"], wav)
        x, sr = wavio.read_wav_lenient(wav)
        self.assertEqual(sr, SR48)
        core = x[SR48 // 2: -SR48 // 2]
        self.assertLess(float(np.abs(x).max()), 0.99)                                  # no clipping after AAC
        spec = np.abs(np.fft.rfft(core * np.hanning(len(core))))
        freqs = np.fft.rfftfreq(len(core), 1 / SR48)
        top2 = sorted(freqs[np.argsort(spec)[-6:]].round(-1))
        self.assertTrue(any(abs(f - 440) < 30 for f in top2) and any(abs(f - 880) < 30 for f in top2), top2)

    def test_second_run_skips_encoding_and_force_redoes_it(self):
        session = self.make_session(sine(440, 2.0), sine(660, 2.0))
        p1 = audioprep.prepare_audio(self.dir, session)
        stamps = {k: v.stat().st_mtime_ns for k, v in p1.archive_files.items()}
        time.sleep(0.05)
        p2 = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(stamps, {k: v.stat().st_mtime_ns for k, v in p2.archive_files.items()})
        np.testing.assert_array_equal(p1.tracks["mic"], p2.tracks["mic"])          # arrays are still produced
        p3 = audioprep.prepare_audio(self.dir, session, force=True)
        for k, v in p3.archive_files.items():
            self.assertGreater(v.stat().st_mtime_ns, stamps[k], k)

    def test_newer_input_triggers_reencoding(self):
        session = self.make_session(sine(440, 2.0), sine(660, 2.0))
        p1 = audioprep.prepare_audio(self.dir, session)
        before = {k: v.stat().st_mtime_ns for k, v in p1.archive_files.items()}
        time.sleep(0.05)
        wavio.write_wav_int16(self.dir / "mic.wav", sine(550, 2.0), SR48)            # the mic input changed
        p2 = audioprep.prepare_audio(self.dir, session)
        after = {k: v.stat().st_mtime_ns for k, v in p2.archive_files.items()}
        self.assertGreater(after["mic"], before["mic"])
        self.assertGreater(after["audio"], before["audio"])                           # the mix depends on mic too
        self.assertEqual(after["remote"], before["remote"])                           # untouched input: skipped

    def test_after_publish_wavs_are_gone_and_m4a_is_used_without_reencoding(self):
        a, b = sine(440, 3.0, amp=0.4), sine(660, 3.0, amp=0.4)
        session = self.make_session(a, b, mic_off=0.1, remote_off=0.0)
        p1 = audioprep.prepare_audio(self.dir, session)
        stamps = {k: v.stat().st_mtime_ns for k, v in p1.archive_files.items()}
        (self.dir / "mic.wav").unlink()
        (self.dir / "remote.wav").unlink()
        p2 = audioprep.prepare_audio(self.dir, session, force=True)
        self.assertEqual(p2.missing, [])
        self.assertAlmostEqual(p2.duration_sec, p1.duration_sec, delta=0.05)
        n = min(len(p1.tracks["mic"]), len(p2.tracks["mic"]))
        corr = float(np.corrcoef(p1.tracks["mic"][:n], p2.tracks["mic"][:n])[0, 1])
        self.assertGreater(corr, 0.97)                                                # AAC is lossy but aligned
        self.assertEqual(stamps, {k: v.stat().st_mtime_ns for k, v in p2.archive_files.items()})   # never re-encoded from m4a

    def test_encoder_failure_is_not_fatal(self):
        session = self.make_session(sine(440, 1.0), sine(660, 1.0))
        with mock.patch.object(audioprep, "_run_afconvert", side_effect=audioprep.AfconvertError("boom")):
            p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.archive_files, {})
        self.assertTrue(any("encoding failed" in w for w in p.warnings))
        self.assertEqual(len(p.tracks["mic"]), 16000)
        self.assertEqual(sorted(q.name for q in self.dir.iterdir()), ["mic.wav", "remote.wav", "session.json"])

    def test_no_afconvert_binary(self):
        session = self.make_session(sine(440, 1.0), None)
        with mock.patch.object(audioprep, "afconvert_path", return_value=None):
            p = audioprep.prepare_audio(self.dir, session)
        self.assertEqual(p.archive_files, {})
        self.assertTrue(any("afconvert" in w for w in p.warnings))

    def test_encoder_retries_with_the_default_when_the_bitrate_is_refused(self):
        src = self.dir / "x16.wav"
        wavio.write_wav_int16(src, sine(440, 2.0, sr=16000), 16000)            # afconvert refuses 64 kbit/s for 16 kHz mono
        audioprep.encode_m4a(src, self.dir / "x16.m4a", 64000)
        self.assertAlmostEqual(afinfo_duration(self.dir / "x16.m4a"), 2.0, delta=0.05)
        self.assertFalse((self.dir / "x16.m4a.part").exists())
        with self.assertRaises(audioprep.AfconvertError):                       # a genuinely bad input still fails, and leaves nothing behind
            audioprep.encode_m4a(self.dir / "missing.wav", self.dir / "bad.m4a", 64000)
        self.assertEqual(sorted(q.name for q in self.dir.iterdir()), ["x16.m4a", "x16.wav"])

    def test_decode_to_wav_converts_rate_and_channels(self):
        src = self.dir / "t.wav"
        wavio.write_wav_int16(src, sine(1000, 2.0), SR48)
        out = self.dir / "o.wav"
        audioprep.decode_to_wav(src, out, sample_rate=16000, channels=1)
        x, sr = wavio.read_wav_lenient(out)
        self.assertEqual(sr, 16000)
        self.assertAlmostEqual(len(x) / sr, 2.0, delta=0.01)


if __name__ == "__main__":
    unittest.main()


class ScratchSpaceTest(SessionDirCase):
    """review_transcribe: the scratch directory was created INSIDE the session directory. For `reprocess --from asr` of a
    published meeting that is the Google Drive folder (hundreds of MB of decoded WAVs in the File Provider folder), and a killed run
    left `.prep-*` / `*.m4a.part` behind that the publisher then copied to Drive forever."""

    def setUp(self):
        super().setUp()
        self.tmp_root = Path(tempfile.mkdtemp(prefix="scratch-root-", dir=self.dir.parent))
        self._old_tempdir = tempfile.tempdir
        tempfile.tempdir = str(self.tmp_root)                         # prepare_audio's temp space for this test
        self.addCleanup(self.cleanup_root)

    def cleanup_root(self):
        tempfile.tempdir = self._old_tempdir
        import shutil
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def names(self, path):
        return sorted(q.name for q in Path(path).iterdir())

    @unittest.skipUnless(HAVE_AFCONVERT, "afconvert not available")
    def test_scratch_files_live_outside_the_session_directory_and_are_removed(self):
        session = self.make_session(sine(440, 2.0), sine(660, 2.0))
        seen = []
        real_encode = audioprep.encode_m4a

        def spy(src, dst, bps, *a, **kw):
            seen.append(Path(src))
            return real_encode(src, dst, bps, *a, **kw)
        with mock.patch.object(audioprep, "encode_m4a", side_effect=spy):
            audioprep.prepare_audio(self.dir, session)
        self.assertEqual(len(seen), 3)                                  # mic, remote, audio
        for src in seen:
            self.assertEqual(src.parent.parent, self.tmp_root, src)     # <temp>/mcap-prep-XXXX/<name>-enc.wav
            self.assertTrue(src.parent.name.startswith("mcap-prep-"))
            self.assertNotIn(self.dir, src.parents)
        self.assertEqual(self.names(self.dir), ["audio.m4a", "mic.m4a", "mic.wav", "remote.m4a", "remote.wav", "session.json"])
        self.assertEqual(self.names(self.tmp_root), [])                 # the scratch directory is gone again

    @unittest.skipUnless(HAVE_AFCONVERT, "afconvert not available")
    def test_reprocessing_a_published_folder_decodes_into_the_temp_directory_not_into_the_folder(self):
        """The archive-folder case: only m4a files + session.json in the directory (Google Drive in real life)."""
        session = self.make_session(sine(440, 3.0, amp=0.4), sine(660, 3.0, amp=0.4))
        audioprep.prepare_audio(self.dir, session)
        (self.dir / "mic.wav").unlink()
        (self.dir / "remote.wav").unlink()
        before = self.names(self.dir)
        written = []
        real_decode = audioprep.decode_to_wav

        def spy(src, dst, *a, **kw):
            written.append(Path(dst))
            return real_decode(src, dst, *a, **kw)
        with mock.patch.object(audioprep, "decode_to_wav", side_effect=spy):
            p = audioprep.prepare_audio(self.dir, session, force=True)
        self.assertEqual(p.missing, [])
        self.assertEqual(len(written), 2)
        for dst in written:
            self.assertNotIn(self.dir, dst.parents, dst)               # decoded WAVs never touch the archive folder
        self.assertEqual(self.names(self.dir), before)                  # not one new file in the folder
        self.assertEqual(self.names(self.tmp_root), [])

    def test_stale_scratch_of_a_killed_run_is_swept(self):
        (self.dir / ".prep-4x95smpf").mkdir()
        (self.dir / ".prep-4x95smpf" / "mic-enc.wav.tmp").write_bytes(b"x" * 100)
        (self.dir / "mic.m4a.part").write_bytes(b"half an m4a")
        (self.dir / "audio.m4a.PART").write_bytes(b"half an m4a")
        (self.dir / "notes.txt").write_text("keep me")
        (self.dir / ".hidden-other").mkdir()
        old = self.tmp_root / "mcap-prep-dead1"
        old.mkdir()
        (old / "remote-enc.wav").write_bytes(b"y" * 100)
        os.utime(old, (time.time() - 7 * 3600, time.time() - 7 * 3600))
        young = self.tmp_root / "mcap-prep-alive"                        # may belong to a live run: untouched
        young.mkdir()
        other = self.tmp_root / "somebody-else"
        other.mkdir()
        os.utime(other, (time.time() - 30 * 3600, time.time() - 30 * 3600))
        removed = audioprep.sweep_stale_scratch(self.dir)
        self.assertEqual(sorted(Path(r).name for r in removed), [".prep-4x95smpf", "audio.m4a.PART", "mcap-prep-dead1", "mic.m4a.part"])
        self.assertEqual(self.names(self.dir), [".hidden-other", "notes.txt"])
        self.assertEqual(self.names(self.tmp_root), ["mcap-prep-alive", "somebody-else"])
        self.assertEqual(audioprep.sweep_stale_scratch(self.dir), [])    # idempotent
        self.assertEqual(audioprep.sweep_stale_scratch(self.dir / "does-not-exist"), [])

    def test_prepare_audio_sweeps_before_it_starts(self):
        session = self.make_session(sine(440, 1.0), sine(660, 1.0))
        (self.dir / ".prep-old").mkdir()
        (self.dir / "remote.m4a.part").write_bytes(b"x")
        audioprep.prepare_audio(self.dir, session)
        self.assertFalse((self.dir / ".prep-old").exists())
        self.assertFalse((self.dir / "remote.m4a.part").exists())

    def test_a_temp_directory_that_cannot_be_created_falls_back_to_the_session_directory_and_still_cleans_up(self):
        session = self.make_session(sine(440, 1.0), sine(660, 1.0))
        real = tempfile.mkdtemp

        def mkdtemp(*a, **kw):
            if kw.get("prefix") == audioprep.SCRATCH_PREFIX:
                raise OSError("no space left on device")
            return real(*a, **kw)
        with mock.patch.object(audioprep.tempfile, "mkdtemp", side_effect=mkdtemp), self.assertLogs("mcap.audioprep", "WARNING") as logs:
            audioprep.prepare_audio(self.dir, session)
        self.assertTrue(any("cannot create a temp directory" in m for m in logs.output), logs.output)
        self.assertFalse([n for n in self.names(self.dir) if n.startswith(".prep-")])

    @unittest.skipUnless(HAVE_AFCONVERT, "afconvert not available")
    def test_sigkill_during_encoding_leaves_nothing_that_could_be_published(self):
        """The review's leftover.py: SIGKILL while the m4a is being encoded. Afterwards the session directory may hold a
        `*.m4a.part`; the next run removes it, finishes normally, and the folder to publish is clean."""
        session = self.make_session(sine(440, 2.0), sine(660, 2.0))
        code = textwrap.dedent(f"""
            import os, signal, sys
            sys.path.insert(0, {str(Path(audioprep.__file__).resolve().parents[1])!r})
            from pathlib import Path
            from mcap import audioprep
            real = audioprep._run_afconvert
            def killed(args, timeout):
                real(args, timeout)                         # the .part file now exists ...
                os.kill(os.getpid(), signal.SIGKILL)         # ... and the process dies before the rename
            audioprep._run_afconvert = killed
            audioprep.prepare_audio(Path({str(self.dir)!r}), {session!r})
        """)
        env = dict(os.environ, TMPDIR=str(self.tmp_root) + "/")
        proc = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, timeout=120)
        self.assertEqual(proc.returncode, -9, proc.stderr.decode()[-500:])
        self.assertTrue(any(n.endswith(".part") for n in self.names(self.dir)), self.names(self.dir))
        leftovers = [n for n in self.names(self.tmp_root) if n.startswith("mcap-prep-")]
        self.assertEqual(len(leftovers), 1)                              # scratch of the dead run: in the temp dir, not in the folder
        os.utime(self.tmp_root / leftovers[0], (time.time() - 8 * 3600, time.time() - 8 * 3600))
        p = audioprep.prepare_audio(self.dir, session)                   # the next run
        self.assertEqual(set(p.archive_files), {"audio", "mic", "remote"})
        self.assertEqual(self.names(self.dir), ["audio.m4a", "mic.m4a", "mic.wav", "remote.m4a", "remote.wav", "session.json"])
        self.assertEqual(self.names(self.tmp_root), [])

