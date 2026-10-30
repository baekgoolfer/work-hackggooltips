"""aec: the offline echo canceller (SPEC 14.2) on synthetic speaker leakage.

Everything here is synthetic (no real speaker / microphone recording exists yet): remote = macOS `say` clips from benchmarks/tts
(pseudo-speech when they are absent, the assertions hold for both), echo path = direct path + decaying reverberation + loudspeaker
band limit, "Me" = other speech placed at known times, then the things a real chain adds to the sum: clock drift, loudspeaker
non-linearity, slow microphone gain changes (AGC), soft and hard clipping, an output-device switch.

The scenarios and the scoring come from scripts/aec_eval.py:
  ERLE        energy of the mic / energy of the output on frames with echo only (ground truth, dB)
  single talk the user alone (the remote is silent): the output must be the mic, energy ratio ~1 and correlation ~1
  double talk the user's true signal inside the output (gain 1.0 = untouched) and SDR of the user vs the output, compared with the untouched mic
Inputs WITHOUT leakage (headphones, hardware echo cancellation, noise, silence) must never be touched: bit for bit the same mic.

Run: python -m unittest discover -s pipeline/tests    (about 40 s of the whole suite; numpy only)
"""
import logging
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "pipeline"))
sys.path.insert(0, str(ROOT / "scripts"))

import numpy as np  # noqa: E402

import aec_eval as ev  # noqa: E402
from mcap import aec, wavio  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())
SR = 16000


def small(name: str, seed: int, **kw) -> "ev.Scenario":
    """A 98 s version of the eval scenarios: remote silent for 22 s (the user alone), 70 s of remote speech with two double-talk stretches."""
    base = dict(remote_len_s=70.0, pre_s=22.0, post_s=6.0, single_clips=(("en_samantha_names", 2.0),),
                dt_clips=(("ko_flo_terms", 30.0), ("en_samantha_terms", 60.0)))
    base.update(kw)
    return ev.Scenario(name, seed, **base)


_cache: dict = {}


def run(scn: "ev.Scenario"):
    """(sim, output, stats, scores of the output, scores of the untouched mic); simulated and processed once per scenario."""
    key = repr(scn)
    if key not in _cache:
        sim = ev.simulate(scn)
        out, stats = aec.cancel_echo(sim.mic, sim.ref, SR, "auto")
        _cache[key] = (sim, out, stats, ev.score_audio(sim, out), ev.score_audio(sim, sim.mic))
    return _cache[key]


class EchoCancellationCase(unittest.TestCase):
    def check_mic_is_safe(self, scn, sdr_gain_db=4.0, gain_slack=0.03):
        """The absolute rule of SPEC 14.2: real user speech is never erased."""
        sim, out, stats, sc, base = run(scn)
        self.assertTrue(stats["applied"], stats)
        self.assertEqual(len(out), len(sim.mic))
        self.assertEqual(out.dtype, np.float32)
        self.assertTrue(np.isfinite(out).all())
        self.assertGreater(sc["single_energy_ratio"], 0.99, "single talk lost energy")                 # the user alone: the mic, unchanged
        self.assertLess(sc["single_energy_ratio"], 1.01)
        self.assertGreater(sc["single_corr"], base["single_corr"] - 0.005)
        self.assertGreater(sc["dt_voice_gain"], base["dt_voice_gain"] - gain_slack, "double talk: the user got quieter")
        self.assertGreater(sc["dt_sdr_db"], base["dt_sdr_db"] + sdr_gain_db, "double talk: the user is not cleaner than in the raw mic")
        self.assertGreater(sc["dt_corr"], base["dt_corr"])
        return sim, out, stats, sc, base

    def test_baseline_echo_is_cancelled_and_delay_found(self):
        scn = small("baseline", 1)
        sim, out, stats, sc, base = self.check_mic_is_safe(scn, sdr_gain_db=10.0)
        self.assertGreater(sc["erle_db"], 20.0)
        self.assertGreater(stats["coherence"], 0.3)
        self.assertAlmostEqual(stats["delay_ms"], scn.delay_ms + 4.0, delta=1.0)      # 4 ms of band-limiting filter delay
        self.assertLess(abs(stats["drift_ppm"]), 15)
        self.assertGreater(sc["dt_voice_gain"], 0.97)
        self.assertGreater(sc["dt_corr"], 0.99)
        self.assertLess(abs(base["erle_db"]), 0.01)                                    # the untouched mic has no ERLE: the metric is honest

    def test_the_canceller_reports_its_own_numbers(self):
        sim, out, stats, sc, base = run(small("baseline", 1))
        for key in ("applied", "coherence", "delay_ms", "drift_ppm", "erle_db", "erle_linear_db", "preserved_ratio", "echo_only_s",
                    "double_talk_s", "runtime_s", "realtime_factor", "mode", "delay_track"):
            self.assertIn(key, stats)
        self.assertGreater(stats["erle_db"], 8.0)                                       # in-situ estimate: conservative (truth is higher)
        self.assertGreater(stats["preserved_ratio"], 0.85)
        self.assertGreater(stats["realtime_factor"], 15.0)

    def test_clock_drift_of_100_ppm_either_way(self):
        for ppm in (100, -100):
            with self.subTest(ppm=ppm):
                scn = small(f"drift {ppm:+d} ppm", 6 if ppm > 0 else 7, ppm=ppm)
                sim, out, stats, sc, base = self.check_mic_is_safe(scn, sdr_gain_db=8.0)
                self.assertGreater(sc["erle_db"], 12.0)
                self.assertAlmostEqual(stats["drift_ppm"], -ppm, delta=25)             # sign convention: the lag shrinks when the mic runs fast

    def test_mild_and_strong_loudspeaker_nonlinearity(self):
        for drive, erle in ((1.0, 20.0), (3.0, 14.0)):
            with self.subTest(drive=drive):
                sim, out, stats, sc, base = self.check_mic_is_safe(small(f"tanh drive {drive}", 16 if drive == 1.0 else 9, drive=drive), sdr_gain_db=8.0)
                self.assertGreater(sc["erle_db"], erle)

    def test_slow_mic_gain_changes_agc(self):
        """+-6 dB over 40 s: tracked by the adaptive filter. Faster and larger changes are cancelled less (documented limit) but
        The user is never touched."""
        sim, out, stats, sc, base = self.check_mic_is_safe(small("wobble +-6 dB / 40 s", 17, gain_wobble=(6.0, 40.0)), sdr_gain_db=8.0)
        self.assertGreater(sc["erle_db"], 10.0)
        sim, out, stats, sc, base = self.check_mic_is_safe(small("wobble +-9 dB / 15 s", 18, gain_wobble=(9.0, 15.0)))
        self.assertGreater(sc["erle_db"], 4.0)
        sim, out, stats, sc, base = self.check_mic_is_safe(small("level-following AGC", 19, agc=(-28.0, 15.0)))
        self.assertGreater(sc["erle_db"], 1.0)                      # a fast +-15 dB AGC defeats most of the cancellation ...
        self.assertGreater(sc["dt_sdr_db"], base["dt_sdr_db"] + 5)  # ... but the output is still far cleaner than the raw mic

    def test_microphone_clipping_and_soft_clipping(self):
        for name, seed, kw, erle in (("clip at 50 % of the peak", 20, dict(clip=0.5), 20.0), ("clip at 25 % of the peak", 21, dict(clip=0.25), 12.0),
                                     ("mic preamp soft clip", 22, dict(mic_drive=2.0), 20.0)):
            with self.subTest(name):
                # the non-linearity is in the mic itself (also in what "Me" looks like in the mic): compare with the untouched mic
                sim, out, stats, sc, base = self.check_mic_is_safe(small(name, seed, **kw), sdr_gain_db=3.0, gain_slack=0.02)
                self.assertGreater(sc["erle_db"], erle)

    def test_everything_at_once(self):
        """AGC + clipping + 100 ppm drift + non-linear speaker together: little echo is removed, but nothing of the user."""
        sim, out, stats, sc, base = self.check_mic_is_safe(small("combo", 23, agc=(-28.0, 12.0), clip=0.5, ppm=100, drive=1.5))
        self.assertGreater(sc["erle_db"], 1.5)
        self.assertGreater(stats["coherence"], 0.1)

    def test_heavy_double_talk(self):
        sim, out, stats, sc, base = self.check_mic_is_safe(small("heavy double talk", 11, voice_vs_echo_db=-3.0), sdr_gain_db=10.0)
        self.assertGreater(sc["erle_db"], 20.0)
        self.assertGreater(sc["dt_voice_gain"], 0.97)

    def test_output_device_switch_changes_the_delay_for_good(self):
        scn = small("device switch", 13, delay_jump=(50.0, 100.0))
        sim, out, stats, sc, base = self.check_mic_is_safe(scn, sdr_gain_db=8.0)
        self.assertGreater(sc["erle_db"], 9.0)
        delays = {round(d) for _, d in stats["delay_track"]}
        self.assertTrue(any(abs(d - 64) <= 2 for d in delays) and any(abs(d - 104) <= 2 for d in delays), delays)

    def test_changed_speaker_volume(self):
        sim, out, stats, sc, base = self.check_mic_is_safe(small("volume drop", 14, gain_change=(50.0, 0.2)), sdr_gain_db=8.0)
        self.assertGreater(sc["erle_db"], 14.0)

    def test_weak_and_reverberant_echo_paths(self):
        for name, seed, kw in (("RT60 0.5 gain 0.8", 4, dict(rt60=0.5, gain=0.8)), ("RT60 0.2 gain 0.2", 5, dict(rt60=0.2, gain=0.2)),
                               ("delay 120 ms", 3, dict(delay_ms=120)), ("delay 20 ms", 2, dict(delay_ms=20))):
            with self.subTest(name):
                sim, out, stats, sc, base = self.check_mic_is_safe(small(name, seed, **kw), sdr_gain_db=8.0)
                self.assertGreater(sc["erle_db"], 18.0)
                self.assertAlmostEqual(stats["delay_ms"], kw.get("delay_ms", 60.0) + 4.0, delta=1.5)

    def test_the_cleaned_track_has_far_fewer_false_speech_regions(self):
        """What the ASR sees: the echo-only stretches stop looking like speech (the energy VAD adapts its threshold to the
        quieter track, so it keeps some; Silero, when the model is available, keeps almost none)."""
        sim, out, stats, sc, base = run(small("baseline", 1))
        before = ev.false_regions(sim.mic, sim.masks["voice"], "energy", None)
        after = ev.false_regions(out, sim.masks["voice"], "energy", None)
        self.assertLess(after[1], 0.7 * before[1], (before, after))                    # false speech seconds
        if ev.silero_available(None):
            before = ev.false_regions(sim.mic, sim.masks["voice"], "silero", None)
            after = ev.false_regions(out, sim.masks["voice"], "silero", None)
            self.assertLess(after[1], 0.2 * before[1] + 0.5, (before, after))


class NoLeakageCase(unittest.TestCase):
    """Auto mode on inputs without speaker leakage: not applied, mic returned bit for bit (headphones, hardware AEC, noise, silence)."""

    def test_inputs_without_leakage_are_never_touched(self):
        rows = [ev.run_null(name, mic, ref, "auto") for name, mic, ref in ev.null_cases(0, 0)]
        self.assertGreaterEqual(len(rows), 11)
        for r in rows:
            with self.subTest(r["name"]):
                self.assertFalse(r["applied"], r)
                self.assertTrue(r["bit_exact"], r)
                self.assertLess(r["coherence"], aec.AecParams().coherence_threshold)

    def test_decide_applicable(self):
        sim, out, stats, sc, base = run(small("baseline", 1))
        applicable, coherence = aec.decide_applicable(sim.mic, sim.ref, SR)
        self.assertTrue(applicable)
        self.assertGreater(coherence, 0.3)
        rng = np.random.default_rng(3)
        headphones = ev.pink_noise(rng, len(sim.ref)) * 0.01
        applicable, coherence = aec.decide_applicable(headphones, sim.ref, SR)
        self.assertFalse(applicable)
        self.assertLess(coherence, 0.05)

    def test_always_mode_is_harmless_without_leakage(self):
        """Forcing the canceller on a mic that holds only the user must leave the user as they are (energy ~1, correlation ~1)."""
        sim, out, stats, sc, base = run(small("baseline", 1))
        rng = np.random.default_rng(4)
        voice_only = sim.voice + ev.pink_noise(rng, len(sim.voice)) * 1e-3
        keep = voice_only.copy()
        cleaned, st = aec.cancel_echo(voice_only, sim.ref, SR, "always")
        np.testing.assert_array_equal(voice_only, keep)                                   # input untouched
        self.assertEqual(len(cleaned), len(keep))
        self.assertGreater(float(np.sum(cleaned ** 2) / np.sum(keep ** 2)), 0.95)
        self.assertGreater(float(np.corrcoef(cleaned, keep)[0, 1]), 0.99)


class RobustnessCase(unittest.TestCase):
    """cancel_echo never raises and always hands back something usable: an unattended pipeline must keep a transcript."""

    @classmethod
    def setUpClass(cls):
        cls.sim, *_ = run(small("baseline", 1))

    def test_bad_arguments_return_the_mic_with_an_error(self):
        mic, ref = self.sim.mic, self.sim.ref
        out, st = aec.cancel_echo(mic, ref, SR, mode="zzz")
        self.assertFalse(st["applied"])
        self.assertIn("mode", st["error"])
        np.testing.assert_array_equal(out, mic)
        out, st = aec.cancel_echo(mic, ref, 48000)
        self.assertFalse(st["applied"])
        self.assertIn("16000", st["error"])
        out, st = aec.cancel_echo(mic.reshape(1, -1), ref)
        self.assertFalse(st["applied"])
        self.assertIn("1-D", st["error"])

    def test_empty_short_and_silent_inputs(self):
        out, st = aec.cancel_echo(np.zeros(0, np.float32), np.zeros(0, np.float32))
        self.assertEqual((len(out), st["applied"]), (0, False))
        out, st = aec.cancel_echo(self.sim.mic[:8000], self.sim.ref[:8000])
        self.assertEqual((len(out), st["applied"]), (8000, False))
        self.assertTrue(st["reason"])
        out, st = aec.cancel_echo(self.sim.mic, np.zeros_like(self.sim.ref), mode="always")
        self.assertFalse(st["applied"])
        self.assertIn("speech-level", st["reason"])
        np.testing.assert_array_equal(out, self.sim.mic)

    def test_reference_of_a_different_length_is_padded_or_cut(self):
        for ref in (self.sim.ref[: len(self.sim.ref) // 2], np.concatenate([self.sim.ref, self.sim.ref[:50000]])):
            out, st = aec.cancel_echo(self.sim.mic, ref)
            self.assertEqual(len(out), len(self.sim.mic))
            self.assertTrue(np.isfinite(out).all())
        out, st = aec.cancel_echo(self.sim.mic[: len(self.sim.mic) // 2], self.sim.ref)
        self.assertEqual(len(out), len(self.sim.mic) // 2)

    def test_non_finite_samples_do_not_poison_the_filter(self):
        mic = self.sim.mic.copy()
        mic[1000:1010] = np.nan
        ref = self.sim.ref.copy()
        ref[5000] = np.inf
        keep_mic, keep_ref = mic.copy(), ref.copy()
        out, st = aec.cancel_echo(mic, ref)
        self.assertTrue(np.isfinite(out).all())
        self.assertTrue(st["applied"], st)
        np.testing.assert_array_equal(np.isnan(mic), np.isnan(keep_mic))                # the caller's arrays are not modified
        self.assertEqual(float(ref[5000]), float("inf"))
        clean, _ = aec.cancel_echo(self.sim.mic, self.sim.ref)
        # the rest of the file is cleaned as well as without the glitch (it used to turn into "no cancellation" after the first NaN)
        a, b = int(30 * SR), int(60 * SR)
        e_clean = float(np.sum(clean[a:b] ** 2))
        e_glitch = float(np.sum(out[a:b] ** 2))
        self.assertLess(e_glitch, 1.5 * e_clean)

    def test_float64_and_other_scales_and_inputs_are_not_modified(self):
        mic64, ref64 = self.sim.mic.astype(np.float64), self.sim.ref.astype(np.float64)
        keep = mic64.copy()
        out, st = aec.cancel_echo(mic64, ref64)
        self.assertEqual(out.dtype, np.float32)
        np.testing.assert_array_equal(mic64, keep)
        self.assertTrue(st["applied"])
        loud, st2 = aec.cancel_echo(self.sim.mic * 20000.0, self.sim.ref * 20000.0)         # int16-scale floats
        self.assertTrue(np.isfinite(loud).all())
        self.assertTrue(st2["applied"])

    def test_deterministic(self):
        a, _ = aec.cancel_echo(self.sim.mic, self.sim.ref)
        b, _ = aec.cancel_echo(self.sim.mic, self.sim.ref)
        np.testing.assert_array_equal(a, b)

    def test_progress_callback_gets_text(self):
        seen = []
        aec.cancel_echo(self.sim.mic, self.sim.ref, progress=seen.append)
        self.assertTrue(seen and all(isinstance(m, str) and m.startswith("echo cancellation") for m in seen))
        self.assertTrue(any("estimating delay" in m for m in seen))

    def test_stats_are_json_friendly_after_the_asr_wrapper(self):
        import json
        from mcap import asr
        stats = asr._jsonable(aec.cancel_echo(self.sim.mic, self.sim.ref)[1])
        json.dumps(stats)


class ExplainedFractionCase(unittest.TestCase):
    """aec.explained_fraction: the energy share of a stretch of the mic that is the (filtered, reverberant) reference."""

    @classmethod
    def setUpClass(cls):
        cls.sim, *_ = run(small("baseline", 1))

    def span(self, x, a, b):
        return x[int(a * SR): int(b * SR)]

    def aligned(self, a, b, lag_ms):
        """The reference as the canceller aligns it (shifted by the delay of the echo path)."""
        lag = int(round(lag_ms * SR / 1000.0))
        return aec._slice_pad(self.sim.ref, int(a * SR) - lag + 320, int(b * SR) - lag + 320)

    def test_pure_echo_scores_high_and_voice_over_echo_scores_low(self):
        a, b = 40.0, 52.0
        echo_only = self.sim.echo
        pure = aec.explained_fraction(self.span(echo_only, a, b), self.aligned(a, b, 64.0))
        self.assertGreater(pure, 0.75)
        mixed = self.sim.echo + 3.0 * self.sim.voice
        share = aec.explained_fraction(self.span(mixed, a, b), self.aligned(a, b, 64.0))
        self.assertLess(share, pure)
        voice_alone = aec.explained_fraction(self.span(self.sim.voice + self.sim.noise, 3.0, 14.0), self.aligned(3.0, 14.0, 64.0))
        self.assertTrue(voice_alone is None or voice_alone < 0.1)                           # nothing to explain while the reference is silent / unrelated
        independent = aec.explained_fraction(self.span(self.sim.voice + self.sim.noise, 30.0, 42.0), self.aligned(30.0, 42.0, 64.0))
        self.assertLess(independent, 0.15)

    def test_short_or_silent_input_gives_none(self):
        x = self.aligned(40.0, 40.5, 64.0)
        self.assertIsNone(aec.explained_fraction(self.span(self.sim.echo, 40.0, 40.5), x))
        z = np.zeros(10 * SR, np.float32)
        self.assertIsNone(aec.explained_fraction(z, z))
        with self.assertRaises(ValueError):
            aec.explained_fraction(np.zeros(100, np.float32), np.zeros(200, np.float32))


class SessionReportCase(unittest.TestCase):
    """`scripts/aec_eval.py --session DIR`: how to judge the canceller on a real recording. Read-only unless --write-cleaned."""

    def make_session(self, d: Path, seconds=60.0):
        scn = small("baseline", 1, remote_len_s=seconds - 10.0, pre_s=6.0, post_s=4.0, single_clips=(("en_samantha_names", 0.5),),
                    dt_clips=(("ko_flo_terms", 20.0), ("en_samantha_terms", 38.0)))
        sim = ev.simulate(scn)
        wavio.write_wav_int16(d / "mic.wav", np.repeat(sim.mic, 3), 48000)               # crude 3x upsampling: only the 16 kHz band matters
        wavio.write_wav_int16(d / "remote.wav", np.repeat(sim.ref, 3), 48000)
        (d / "session.json").write_text('{"schema": 1, "tracks": {"mic": {"file": "mic.wav", "sample_rate": 48000, "start_offset_sec": 0.0},'
                                        ' "remote": {"file": "remote.wav", "sample_rate": 48000, "start_offset_sec": 0.0}}}')
        return sim

    def run_script(self, *args):
        env = dict(os.environ, MCAP_SILERO_MODEL="")
        env.pop("MCAP_SILERO_MODEL")
        return subprocess.run([sys.executable, str(ROOT / "scripts" / "aec_eval.py"), *args], capture_output=True, text=True, timeout=240, env=env)

    def test_report_is_read_only_and_says_what_it_found(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self.make_session(d)
            before = sorted(p.name for p in d.iterdir())
            proc = self.run_script("--session", str(d), "--vad", "energy", "--support-dir", str(d / "no-support"))
            self.assertEqual(proc.returncode, 0, proc.stderr[-800:])
            out = proc.stdout
            self.assertIn("decide_applicable: True", out)
            for key in ("applied", "coherence", "delay_ms", "erle_db", "preserved_ratio"):
                self.assertIn(key, out)
            self.assertIn("VAD energy on the mic track", out)
            self.assertIn("regions that disappeared", out)
            self.assertEqual(sorted(p.name for p in d.iterdir()), before)                  # nothing written

    def test_write_cleaned_adds_exactly_one_file(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self.make_session(d)
            proc = self.run_script("--session", str(d), "--vad", "energy", "--write-cleaned", "--support-dir", str(d / "no-support"))
            self.assertEqual(proc.returncode, 0, proc.stderr[-800:])
            self.assertTrue((d / "mic.aec.wav").exists())
            x, sr = wavio.read_wav_lenient(d / "mic.aec.wav")
            self.assertEqual(sr, SR)
            self.assertEqual(sorted(p.name for p in d.iterdir()), ["mic.aec.wav", "mic.wav", "remote.wav", "session.json"])

    def test_missing_track_is_reported(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self.make_session(d)
            (d / "remote.wav").unlink()
            proc = self.run_script("--session", str(d), "--vad", "energy")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("need both mic and remote", proc.stderr + proc.stdout)


class EvalScriptCase(unittest.TestCase):
    def test_scenario_list_contains_the_review_cases(self):
        names = [s.name for s in ev.echo_scenarios(False, 0)]
        for needle in ("AGC", "clipping", "nonlinearity", "drift +100", "drift -100", "device switch", "volume drop"):
            self.assertTrue(any(needle.lower() in n.lower() for n in names), (needle, names))
        quick = [s.name for s in ev.echo_scenarios(True, 0)]
        self.assertTrue(any("AGC" in n for n in quick) and any("clipping" in n for n in quick))

    def test_agc_gain_follows_the_level_within_its_range(self):
        rng = np.random.default_rng(1)
        x = rng.standard_normal(SR * 20).astype(np.float32) * 0.01
        x[SR * 8: SR * 12] *= 30.0                                      # a loud passage in the middle
        g = ev.agc_gain(x, -30.0, 12.0)
        gdb = 20 * np.log10(g)
        self.assertLessEqual(float(gdb.max()), 12.0 + 1e-3)
        self.assertGreaterEqual(float(gdb.min()), -12.0 - 1e-3)
        self.assertLess(float(gdb[SR * 10]), float(gdb[SR * 2]) - 6.0)       # turned down during the loud part
        self.assertGreater(float(gdb[SR * 19]), float(gdb[SR * 10]))         # creeping back afterwards


if __name__ == "__main__":
    unittest.main()
