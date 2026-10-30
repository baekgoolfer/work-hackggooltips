"""vad: Silero (onnxruntime) and energy detectors on the synthetic clips in benchmarks/tts, model discovery,
ASR_VAD selection and chunk-packing invariants.

Silero tests need onnxruntime plus the model (set MCAP_SILERO_MODEL=/path/to/silero_vad.onnx) and are skipped otherwise.
The clips live in benchmarks/tts (git-ignored, generated with macOS `say`); tests that need them are skipped when absent.
"""
import logging
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from mcap import vad, wavio  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())

TTS = Path(__file__).resolve().parents[2] / "benchmarks" / "tts"
_env_model = os.environ.get("MCAP_SILERO_MODEL")      # never look into the real SUPPORT_DIR from tests
SILERO = Path(_env_model) if _env_model and Path(_env_model).is_file() else None
try:
    import onnxruntime  # noqa: F401
    HAVE_ORT = True
except ImportError:
    HAVE_ORT = False
needs_silero = unittest.skipUnless(HAVE_ORT and SILERO is not None, "needs onnxruntime and MCAP_SILERO_MODEL")
needs_tts = unittest.skipUnless((TTS / "silence_30s.wav").exists(), "benchmarks/tts clips not generated")


def load(name):
    x, sr = wavio.read_wav_lenient(TTS / f"{name}.wav")
    assert sr == 16000
    return x


def covered(regions, a, b):
    """Seconds of [a, b] that lie inside the regions."""
    return sum(max(0.0, min(b, e) - max(a, s)) for s, e in regions)


@needs_tts
class EnergyVadTest(unittest.TestCase):
    def test_finds_speech_in_the_clips(self):
        for name, speech in (("ko_yuna_terms", 18.0), ("en_samantha_terms", 20.0), ("mix_ko_en_ko_codeswitch", 49.0)):
            with self.subTest(name):
                r = vad.detect_speech(load(name), "energy")
                self.assertEqual(r.backend, "energy")
                self.assertGreater(r.speech_seconds, 0.9 * speech)
                self.assertLessEqual(r.speech_seconds, len(load(name)) / 16000 + 0.01)

    def test_codeswitch_clip_pauses_are_found(self):
        r = vad.detect_speech(load("mix_ko_en_ko_codeswitch"), "energy")
        self.assertGreaterEqual(len(r.regions), 4)
        self.assertLess(covered(r.regions, 18.2, 18.5), 0.3)           # the 0.6 s pause between utterances

    def test_silence_and_noise_floor_give_no_regions(self):
        for name in ("silence_30s", "noise_floor_30s"):
            with self.subTest(name):
                self.assertEqual(vad.detect_speech(load(name), "energy").regions, [])

    def test_known_weakness_non_speech_sounds_are_reported_as_speech(self):
        """Documented limitation of the fallback: dings, a noise burst, a chord and keyboard clicks are loud, so the energy VAD
        calls them speech (Silero does not). The ASR post-filter has to deal with whatever Whisper hallucinates there."""
        r = vad.detect_speech(load("nonspeech_stress_25s"), "energy")
        self.assertGreater(len(r.regions), 0)
        print(f"\n  [energy VAD on nonspeech_stress_25s: {len(r.regions)} false regions, {r.speech_seconds:.1f}s]", end="")

    def test_long_gap_between_speech_is_kept(self):
        r = vad.detect_speech(load("speech_gap40_speech"), "energy")
        self.assertEqual(len(r.regions), 2)
        self.assertLess(covered(r.regions, 20.0, 56.0), 0.1)

    def test_a_dc_offset_is_not_speech(self):
        """review_transcribe: speech with a 0.1 DC offset (cheap audio interface) gave 0 s of speech with the energy VAD."""
        x = load("ko_yuna_terms")
        base = vad.detect_speech(x, "energy")
        for offset in (0.05, 0.1, -0.15, 0.3):
            with self.subTest(offset=offset):
                r = vad.detect_speech(np.clip(x + np.float32(offset), -1.0, 1.0).astype(np.float32), "energy")
                self.assertEqual(len(r.regions), len(base.regions))
                self.assertAlmostEqual(r.speech_seconds, base.speech_seconds, delta=0.05 * base.speech_seconds)
        self.assertEqual(vad.detect_speech(np.full(16000 * 10, 0.2, np.float32), "energy").regions, [])      # DC alone: silence
        self.assertEqual(float(vad.frame_db(np.full(3200, 0.5, np.float32)).max()), -120.0)

    def test_frame_db_is_block_independent(self):
        rng = np.random.default_rng(2)
        x = (rng.standard_normal(16000 * 40) * 0.05).astype(np.float32)
        full = vad.frame_db(x)
        self.assertEqual(len(full), 2000)
        ref = np.array([10 * np.log10(np.mean(np.square(x[i * 320:(i + 1) * 320] - x[i * 320:(i + 1) * 320].mean(), dtype=np.float64)) + 1e-12)
                        for i in range(0, 2000, 7)])
        np.testing.assert_allclose(full[::7], ref, atol=1e-3)

    def test_degenerate_input(self):
        for x in (np.zeros(0, np.float32), np.zeros(100, np.float32), np.zeros(16000, np.float32)):
            r = vad.detect_speech(x, "energy")
            self.assertEqual(r.regions, [])
        r = vad.detect_speech(np.ones(16000, np.float32) * 0.5, "energy")        # constant DC is "loud" but a single region
        self.assertLessEqual(len(r.regions), 1)


@needs_tts
@needs_silero
class SileroVadTest(unittest.TestCase):
    def test_speech_clips(self):
        for name, speech in (("ko_yuna_terms", 18.0), ("en_samantha_terms", 20.0), ("ko_eddy_terms", 25.5),
                             ("mix_ko_en_ko_codeswitch", 49.0), ("mix_ko_en_ko_fan_noise", 49.0), ("meeting_like_184s", 150.0)):
            with self.subTest(name):
                r = vad.detect_speech(load(name), "silero")
                self.assertEqual(r.backend, "silero")
                self.assertGreater(r.speech_seconds, 0.9 * speech)
                self.assertGreaterEqual(len(r.regions), 1)

    def test_a_dc_offset_does_not_matter(self):
        x = load("ko_yuna_terms")
        base = vad.detect_speech(x, "silero")
        for offset in (0.1, -0.15, 0.3):
            with self.subTest(offset=offset):
                r = vad.detect_speech(np.clip(x + np.float32(offset), -1.0, 1.0).astype(np.float32), "silero")
                self.assertAlmostEqual(r.speech_seconds, base.speech_seconds, delta=0.1 * base.speech_seconds)

    def test_no_false_regions_on_silence_noise_and_non_speech_sounds(self):
        for name in ("silence_30s", "noise_floor_30s", "nonspeech_stress_25s"):
            with self.subTest(name):
                self.assertEqual(vad.detect_speech(load(name), "silero").regions, [], name)

    def test_speech_over_steady_noise(self):
        clean = vad.detect_speech(load("mix_ko_en_ko_codeswitch"), "silero")
        noisy = vad.detect_speech(load("mix_ko_en_ko_fan_noise"), "silero")
        self.assertEqual(len(clean.regions), len(noisy.regions))
        self.assertAlmostEqual(clean.speech_seconds, noisy.speech_seconds, delta=2.0)

    def test_gap_is_not_speech(self):
        r = vad.detect_speech(load("speech_gap40_speech"), "silero")
        self.assertEqual(len(r.regions), 2)
        self.assertLess(covered(r.regions, 19.0, 57.0), 0.05)

    def test_region_edges_are_sorted_ordered_and_within_the_audio(self):
        x = load("meeting_like_184s")
        r = vad.detect_speech(x, "silero")
        total = len(x) / 16000
        prev_end = 0.0
        for s, e in r.regions:
            self.assertGreaterEqual(s, prev_end)
            self.assertGreaterEqual(e - s, 0.25)
            self.assertLessEqual(e, total + 0.05)
            prev_end = e

    def test_short_input(self):
        self.assertEqual(vad.detect_speech(np.zeros(100, np.float32), "silero").regions, [])


class RegionsFromProbsTest(unittest.TestCase):
    def test_hysteresis_and_minimum_lengths(self):
        w = 512 / 16000
        p = np.zeros(200, np.float32)
        p[10:30] = 0.9                    # 0.64 s speech
        p[30:33] = 0.4                    # fades out above the 0.35 stay threshold
        p[50:52] = 0.9                    # 64 ms blip: dropped (< 0.25 s)
        p[100:140] = 0.6                  # second region
        p[140:146] = 0.1                  # 0.19 s dip < 0.30 s: bridged
        p[146:160] = 0.8
        p[160:] = 0.0
        regs = vad.regions_from_probs(p)
        self.assertEqual(len(regs), 2)
        self.assertAlmostEqual(regs[0][0], 10 * w)
        self.assertAlmostEqual(regs[0][1], 33 * w)
        self.assertAlmostEqual(regs[1][0], 100 * w)
        self.assertAlmostEqual(regs[1][1], 160 * w)

    def test_enter_threshold_needs_0_5(self):
        self.assertEqual(vad.regions_from_probs(np.full(100, 0.45, np.float32)), [])
        self.assertEqual(len(vad.regions_from_probs(np.full(100, 0.55, np.float32))), 1)

    def test_region_open_at_the_end(self):
        p = np.zeros(100, np.float32)
        p[60:] = 0.9
        regs = vad.regions_from_probs(p)
        self.assertEqual(len(regs), 1)
        self.assertAlmostEqual(regs[0][1], 100 * 512 / 16000)


class ModelDiscoveryAndSelectionTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self._env = mock.patch.dict(os.environ)
        self._env.start()
        os.environ.pop("MCAP_SILERO_MODEL", None)

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def test_discovery_order(self):
        support = self.dir / "support"
        (support / "models").mkdir(parents=True)
        self.assertIsNone(vad.find_silero_model(support))
        env_model = self.dir / "env.onnx"
        env_model.write_bytes(b"x")
        support_model = support / "models" / "silero_vad.onnx"
        support_model.write_bytes(b"y")
        self.assertEqual(vad.find_silero_model(support), support_model)
        os.environ["MCAP_SILERO_MODEL"] = str(env_model)
        self.assertEqual(vad.find_silero_model(support), env_model)                       # env wins
        os.environ["MCAP_SILERO_MODEL"] = str(self.dir / "does-not-exist.onnx")
        self.assertIsNone(vad.find_silero_model(support))                                # an explicit override is never replaced silently

    def test_silero_model_path_hook_for_doctor(self):
        class FakeCfg:
            support_dir = self.dir
        self.assertIsNone(vad.silero_model_path(FakeCfg()))
        (self.dir / "models").mkdir()
        (self.dir / "models" / "silero_vad.onnx").write_bytes(b"x")
        self.assertEqual(vad.silero_model_path(FakeCfg()), self.dir / "models" / "silero_vad.onnx")
        (self.dir / "elsewhere.onnx").write_bytes(b"y")
        os.environ["MCAP_SILERO_MODEL"] = str(self.dir / "elsewhere.onnx")                  # same lookup as the VAD itself
        self.assertEqual(vad.silero_model_path(FakeCfg()), self.dir / "elsewhere.onnx")

    def test_package_data_location_is_the_last_resort(self):
        pkg_model = Path(vad.__file__).resolve().parent / "data" / "silero_vad.onnx"
        with mock.patch.object(Path, "is_file", autospec=True, side_effect=lambda self: self == pkg_model):
            self.assertEqual(vad.find_silero_model(self.dir / "empty-support"), pkg_model)

    def test_auto_falls_back_to_energy_without_model(self):
        x = np.zeros(16000, np.float32)
        r = vad.detect_speech(x, "auto", support_dir=self.dir)
        self.assertEqual(r.backend, "energy")

    def test_silero_mode_without_model_raises(self):
        with self.assertRaises(vad.VadUnavailable):
            vad.detect_speech(np.zeros(16000, np.float32), "silero", support_dir=self.dir)

    def test_energy_mode_never_touches_silero(self):
        with mock.patch.object(vad, "find_silero_model", side_effect=AssertionError("must not be called")):
            self.assertEqual(vad.detect_speech(np.zeros(16000, np.float32), "energy").backend, "energy")

    def test_auto_survives_a_broken_model_file(self):
        bad = self.dir / "bad.onnx"
        bad.write_bytes(b"this is not an onnx model")
        os.environ["MCAP_SILERO_MODEL"] = str(bad)
        if HAVE_ORT:
            self.assertEqual(vad.detect_speech(np.zeros(16000, np.float32), "auto").backend, "energy")
            with self.assertRaises(vad.VadUnavailable):
                vad.detect_speech(np.zeros(16000, np.float32), "silero")

    def test_unknown_mode_is_treated_as_auto(self):
        self.assertEqual(vad.detect_speech(np.zeros(16000, np.float32), "bogus", support_dir=self.dir).backend, "energy")

    @needs_silero
    def test_auto_prefers_silero_when_available(self):
        os.environ["MCAP_SILERO_MODEL"] = str(SILERO)
        self.assertEqual(vad.detect_speech(np.zeros(16000, np.float32), "auto").backend, "silero")


class _Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append(record)


class VadDegradationTest(unittest.TestCase):
    """SPEC 15 / review_transcribe: ASR_VAD=auto falling back to the energy VAD must not be silent."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self._env = mock.patch.dict(os.environ)
        self._env.start()
        os.environ.pop("MCAP_SILERO_MODEL", None)
        self.handler = _Capture()
        logging.getLogger("mcap.vad").addHandler(self.handler)
        self.x = np.zeros(16000, np.float32)

    def tearDown(self):
        logging.getLogger("mcap.vad").removeHandler(self.handler)
        self._env.stop()
        self._tmp.cleanup()

    def warnings(self):
        return [r for r in self.handler.records if r.levelno >= logging.WARNING]

    def test_missing_model_is_a_warning_and_is_recorded(self):
        r = vad.detect_speech(self.x, "auto", support_dir=self.dir)
        self.assertEqual(r.backend, "energy")
        self.assertIn("Silero model not found", r.degraded)
        self.assertEqual(r.label, f"energy (silero unavailable: {r.degraded})")
        self.assertTrue(r.label.startswith("energy (silero unavailable: Silero model not found"))
        self.assertEqual(r.info["silero_unavailable"], r.degraded)
        warnings = self.warnings()
        self.assertEqual(len(warnings), 1)
        self.assertIn("DEGRADED", warnings[0].getMessage())
        self.assertIn("Silero model not found", warnings[0].getMessage())

    def test_missing_onnxruntime_is_recorded(self):
        model = self.dir / "m.onnx"
        model.write_bytes(b"x")
        os.environ["MCAP_SILERO_MODEL"] = str(model)
        with mock.patch.object(vad, "_get_silero", side_effect=ImportError("No module named 'onnxruntime'")):
            r = vad.detect_speech(self.x, "auto")
        self.assertEqual(r.backend, "energy")
        self.assertIn("onnxruntime is not installed", r.degraded)
        self.assertIn("onnxruntime", r.label)
        self.assertEqual(len(self.warnings()), 1)

    def test_a_broken_model_is_recorded(self):
        model = self.dir / "bad.onnx"
        model.write_bytes(b"this is not an onnx model")
        os.environ["MCAP_SILERO_MODEL"] = str(model)
        with mock.patch.object(vad, "_get_silero", side_effect=RuntimeError("INVALID_PROTOBUF")):
            r = vad.detect_speech(self.x, "auto")
        self.assertEqual(r.backend, "energy")
        self.assertIn("Silero VAD failed: INVALID_PROTOBUF", r.degraded)
        self.assertTrue(r.label.startswith("energy (silero unavailable: Silero VAD failed"))
        self.assertEqual(len(self.warnings()), 1)

    def test_explicit_energy_is_not_a_degradation(self):
        r = vad.detect_speech(self.x, "energy")
        self.assertEqual((r.backend, r.degraded, r.label), ("energy", "", "energy"))
        self.assertNotIn("silero_unavailable", r.info)
        self.assertEqual(self.warnings(), [])

    def test_explicit_silero_still_raises_instead_of_degrading(self):
        with self.assertRaises(vad.VadUnavailable):
            vad.detect_speech(self.x, "silero", support_dir=self.dir)
        self.assertEqual(self.warnings(), [])

    @needs_silero
    def test_working_silero_has_no_degradation(self):
        os.environ["MCAP_SILERO_MODEL"] = str(SILERO)
        r = vad.detect_speech(self.x, "auto")
        self.assertEqual((r.backend, r.degraded, r.label), ("silero", "", "silero"))
        self.assertEqual(r.region_probs, [])
        self.assertEqual(self.warnings(), [])

    @needs_silero
    @needs_tts
    def test_silero_reports_a_mean_probability_per_region(self):
        os.environ["MCAP_SILERO_MODEL"] = str(SILERO)
        r = vad.detect_speech(load("mix_ko_en_ko_codeswitch"), "auto")
        self.assertEqual(r.backend, "silero")
        self.assertEqual(len(r.region_probs), len(r.regions))
        self.assertGreater(len(r.regions), 2)
        self.assertTrue(all(0.0 <= p <= 1.0 for p in r.region_probs))
        self.assertGreater(float(np.mean(r.region_probs)), 0.8)


class RegionMeanProbsTest(unittest.TestCase):
    def test_mean_over_the_windows_of_each_region(self):
        w = vad.SILERO_WINDOW / vad.SR
        p = np.zeros(200, np.float32)
        p[10:20] = 0.9
        p[40:60] = [0.5] * 10 + [0.7] * 10
        regions = [(10 * w, 20 * w), (40 * w, 60 * w), (100 * w, 100 * w + 0.001)]
        probs = vad.region_mean_probs(p, regions)
        self.assertAlmostEqual(probs[0], 0.9, places=5)
        self.assertAlmostEqual(probs[1], 0.6, places=5)
        self.assertEqual(len(probs), 3)                      # a degenerate region still gets one window
        self.assertEqual(vad.region_mean_probs(p, []), [])
        self.assertEqual(vad.region_mean_probs(np.zeros(0, np.float32), [(0.0, 1.0)]), [0.0])


class OnnxTelemetryTest(unittest.TestCase):
    """SPEC 14.4 (integration fix: it was never done, and onnxruntime 1.30 wrote ~/Library/Application Support/Microsoft/
    DeveloperTools/.onnxruntime): ORT_DISABLE_TELEMETRY=1 is set before onnxruntime can be imported, and
    onnxruntime.disable_telemetry_events() runs before the first InferenceSession."""

    def test_env_switch_is_set_when_the_module_is_imported(self):
        # in a fresh interpreter (reloading the module here would swap the classes other test modules hold on to)
        code = ("import os, sys; sys.path.insert(0, %r); import mcap.vad; print(os.environ.get('ORT_DISABLE_TELEMETRY'))"
                % str(Path(__file__).resolve().parents[1]))
        for given, expected in ((None, "1"), ("0", "0")):         # an explicit user value is respected
            env = {k: v for k, v in os.environ.items() if k != "ORT_DISABLE_TELEMETRY"}
            if given is not None:
                env["ORT_DISABLE_TELEMETRY"] = given
            out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(out.stdout.strip(), expected)

    def fake_ort(self, events, disable_raises=None, have_disable=True):
        class FakeSession:
            def __init__(self, path, providers=None, sess_options=None):
                events.append("session")

        fake = mock.MagicMock()
        fake.SessionOptions = mock.MagicMock
        fake.InferenceSession = FakeSession
        if have_disable:
            def disable():
                events.append("disable")
                if disable_raises:
                    raise disable_raises
            fake.disable_telemetry_events = disable
        else:
            del fake.disable_telemetry_events
        return fake

    def test_telemetry_is_disabled_before_the_session_is_created(self):
        events = []
        with mock.patch.dict(sys.modules, {"onnxruntime": self.fake_ort(events)}):
            vad.SileroVAD(Path("/nonexistent/silero_vad.onnx"))
        self.assertEqual(events, ["disable", "session"])

    def test_a_failing_or_missing_disable_call_never_breaks_the_vad(self):
        for kwargs in ({"disable_raises": RuntimeError("boom")}, {"have_disable": False}):
            with self.subTest(kwargs):
                events = []
                with mock.patch.dict(sys.modules, {"onnxruntime": self.fake_ort(events, **kwargs)}):
                    vad.SileroVAD(Path("/nonexistent/silero_vad.onnx"))
                self.assertEqual(events[-1], "session")


# ---------------------------------------------------------------------------------------
# chunk packing
# ---------------------------------------------------------------------------------------
class PlanChunksTest(unittest.TestCase):
    def check_invariants(self, chunks, regions, total, max_chunk_s=28.0, labels=None):
        prev_end = 0.0
        for a, b, lab in chunks:
            self.assertGreaterEqual(a, 0.0)
            self.assertLessEqual(b, total + 1e-9)
            self.assertGreater(b, a)
            self.assertLessEqual(b - a, max_chunk_s + 1e-6, "chunk longer than the window")
            self.assertGreaterEqual(a, prev_end - 1e-9, "chunks overlap or are out of order")
            prev_end = b
        if labels is not None:
            # a chunk never contains speech of a different label than its own
            for (s, e), lab in zip(regions, labels):
                if e - s < 0.4:
                    continue
                mid = (s + e) / 2
                owners = [c for c in chunks if c[0] <= mid <= c[1]]
                self.assertTrue(owners, f"speech at {mid:.2f}s is in no chunk")
                self.assertEqual({o[2] for o in owners}, {lab})

    def db(self, total):
        return np.full(int(total * 50), -50.0, np.float32)

    def test_adjacent_regions_are_merged_and_padded(self):
        regions = [(1.0, 3.0), (4.0, 6.0), (20.0, 22.0)]
        chunks = vad.plan_chunks(regions, self.db(30), 30.0)
        self.assertEqual(len(chunks), 2)
        self.assertAlmostEqual(chunks[0][0], 0.7)
        self.assertAlmostEqual(chunks[0][1], 6.3)
        self.assertAlmostEqual(chunks[1][0], 19.7)
        self.check_invariants(chunks, regions, 30.0)

    def test_language_change_forces_a_chunk_boundary(self):
        regions = [(1.0, 3.0), (3.5, 5.0), (5.5, 7.0)]
        labels = ["ko", "en", "en"]
        chunks = vad.plan_chunks(regions, self.db(10), 10.0, labels=labels)
        self.assertEqual([c[2] for c in chunks], ["ko", "en"])
        self.check_invariants(chunks, regions, 10.0, labels=labels)
        self.assertLessEqual(chunks[0][1], chunks[1][0] + 1e-9)

    def test_window_limit_starts_a_new_chunk(self):
        regions = [(i * 10.0, i * 10.0 + 8.0) for i in range(6)]           # 8 s speech every 10 s, gaps of 2 s
        chunks = vad.plan_chunks(regions, self.db(70), 70.0)
        self.assertGreater(len(chunks), 1)
        self.check_invariants(chunks, regions, 70.0)

    def test_long_continuous_region_is_cut_at_the_quietest_point(self):
        db = np.full(100 * 50, -30.0, np.float32)
        db[int(20.0 * 50): int(20.1 * 50)] = -70.0                          # a quiet 100 ms at 20.0 s
        chunks = vad.plan_chunks([(0.0, 60.0)], db, 60.0)
        self.assertGreaterEqual(len(chunks), 3)
        self.check_invariants(chunks, [(0.0, 60.0)], 60.0)
        boundaries = [c[1] for c in chunks[:-1]]
        self.assertTrue(any(abs(b - 20.05) < 0.2 for b in boundaries), boundaries)
        covered_s = sum(b - a for a, b, _ in chunks)
        self.assertGreaterEqual(covered_s, 60.0 - 1e-6)

    def test_tiny_chunks_are_skipped(self):
        chunks = vad.plan_chunks([(5.0, 5.3), (10.0, 12.0)], self.db(20), 20.0)
        self.assertEqual(len(chunks), 1)
        self.assertAlmostEqual(chunks[0][0], 9.7)

    def test_a_lone_short_region_is_kept_when_silero_is_sure(self):
        """A real one-word answer ("네") is 0.25-0.4 s of speech: kept (with the usual padding) only when the detector is sure."""
        regions = [(5.0, 5.3), (10.0, 12.0), (20.0, 20.35)]
        sure = vad.plan_chunks(regions, self.db(30), 30.0, region_probs=[0.95, 0.9, 0.85])
        self.assertEqual([(round(a, 2), round(b, 2)) for a, b, _ in sure], [(4.7, 5.6), (9.7, 12.3), (19.7, 20.65)])
        self.check_invariants(sure, regions, 30.0)
        unsure = vad.plan_chunks(regions, self.db(30), 30.0, region_probs=[0.6, 0.9, 0.79])
        self.assertEqual(len(unsure), 1)                                        # mean probability below 0.80: dropped as before
        self.assertAlmostEqual(unsure[0][0], 9.7)
        self.assertEqual(len(vad.plan_chunks(regions, self.db(30), 30.0)), 1)   # energy VAD / no probabilities: dropped as before

    def test_short_region_rules(self):
        db = self.db(30)
        self.assertEqual(vad.plan_chunks([(5.0, 5.2)], db, 30.0, region_probs=[0.99]), [])           # below the 0.25 s floor
        merged = vad.plan_chunks([(5.0, 5.3), (6.0, 8.0)], db, 30.0, region_probs=[0.99, 0.2])
        self.assertEqual(len(merged), 1)                                                              # not alone: part of the neighbour's chunk
        self.assertEqual(vad.plan_chunks([(5.0, 5.3)], db, 30.0, labels=["ko"], region_probs=[0.9])[0][2], "ko")
        with self.assertRaises(ValueError):
            vad.plan_chunks([(1.0, 2.0)], db, 30.0, region_probs=[0.9, 0.9])
        near_start = vad.plan_chunks([(0.0, 0.3)], db, 30.0, region_probs=[0.9])
        self.assertEqual((near_start[0][0], round(near_start[0][1], 2)), (0.0, 0.6))                  # clipped to the audio start

    def test_a_short_region_next_to_a_different_language_is_its_own_chunk(self):
        chunks = vad.plan_chunks([(5.0, 7.0), (7.4, 7.7)], self.db(30), 30.0, labels=["ko", "en"], region_probs=[0.9, 0.95])
        self.assertEqual([c[2] for c in chunks], ["ko", "en"])
        self.check_invariants(chunks, [(5.0, 7.0), (7.4, 7.7)], 30.0)

    def test_edges_are_clipped_to_the_audio(self):
        chunks = vad.plan_chunks([(0.0, 2.0), (28.0, 30.0)], self.db(30), 30.0)
        self.assertEqual(chunks[0][0], 0.0)
        self.assertEqual(chunks[-1][1], 30.0)

    def test_empty_and_label_length_mismatch(self):
        self.assertEqual(vad.plan_chunks([], self.db(10), 10.0), [])
        with self.assertRaises(ValueError):
            vad.plan_chunks([(1.0, 2.0)], self.db(10), 10.0, labels=["ko", "en"])

    def test_degenerate_db_array(self):
        chunks = vad.plan_chunks([(0.0, 70.0)], np.zeros(0, np.float32), 70.0)    # no frame levels: cut in the middle of the range
        self.check_invariants(chunks, [(0.0, 70.0)], 70.0)

    def test_random_regions_keep_all_invariants(self):
        rng = np.random.default_rng(42)
        for trial in range(300):
            total = float(rng.uniform(5, 400))
            regions, t = [], 0.0
            while True:
                t += float(rng.choice([0.05, 0.3, 1.0, 2.4, 2.6, 6.0]) * rng.uniform(0.5, 1.5))
                length = float(rng.choice([0.2, 0.5, 2.0, 8.0, 20.0, 45.0]) * rng.uniform(0.5, 1.5))
                if t + length > total:
                    break
                regions.append((t, t + length))
                t += length
            labels = [str(rng.choice(["ko", "en"])) for _ in regions] if trial % 2 else None
            db = rng.uniform(-70, -20, int(total * 50) + 3).astype(np.float32)
            chunks = vad.plan_chunks(regions, db, total, labels=labels)
            self.check_invariants(chunks, regions, total, labels=labels)
            # all speech of regions >= 0.4 s is inside some chunk (so nothing audible is skipped)
            for s, e in regions:
                if e - s >= 0.45:
                    got = sum(max(0.0, min(e, b) - max(s, a)) for a, b, _ in chunks)
                    self.assertAlmostEqual(got, e - s, delta=0.35 if labels else 0.05, msg=f"trial {trial} region {(s, e)}")

    def test_unsorted_regions_are_handled(self):
        chunks = vad.plan_chunks([(20.0, 22.0), (1.0, 3.0)], self.db(30), 30.0)
        self.assertEqual(len(chunks), 2)
        self.assertLess(chunks[0][0], chunks[1][0])


if __name__ == "__main__":
    unittest.main()
