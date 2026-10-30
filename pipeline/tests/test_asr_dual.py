"""ASR_STRATEGY=dual in the stage: the config key, the chunk loop with a fake engine (single is byte-identical to before, dual calls the
engine twice per chunk and the second call has no prompt), the provenance, the gates that keep dual local, and the benchmark mode of
scripts/bench_asr.py. Everything is faked: no model, no audio file of a meeting, no network.

Run: python -m unittest discover -s pipeline/tests
"""
import contextlib
import importlib.util
import io
import json
import logging
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from golden import make_golden as mg  # noqa: E402
from mcap import asr, asr_engines, config, transcript as tr, vad, wavio  # noqa: E402
from mcap.asr_engines import Engine, WhisperEngine  # noqa: E402
from mcap.config import Config, load_config, parse_env_text  # noqa: E402
from mcap.vocab import Vocab, parse_vocab_text  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())

ROOT = Path(__file__).resolve().parents[2]
SR = 16000
VOCAB = parse_vocab_text("Acme\nFDA\n510(k)\nAcme = 애크미\n")
REGIONS = [(1.0, 5.0), (6.0, 9.0), (40.0, 45.0), (80.0, 83.0)]       # three chunks (a 28 s window each)
DEFAULT_KEYS = ["schema", "asr_model", "languages", "segments", "dropped", "dropped_reasons", "echo_suppressed", "echo_suppressed_reasons",
                "aec", "speech_seconds", "missing_tracks", "stats"]


def seg(start, end, text, lp=-0.3, ns=0.02, cr=1.1):
    return {"start": start, "end": end, "text": text, "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": cr, "temperature": 0.0}


def answer(language, *segments, lp=-0.3):
    return {"text": " ".join(s["text"] for s in segments), "language": language, "avg_logprob": lp, "segments": list(segments)}


def two_passes(audio, language, prompt, i):
    """The prompt bends a figure and misses a short utterance that the plain decode keeps (later in the chunk, where P has nothing)."""
    d, part = len(audio) / SR, round(len(audio) / SR)
    if prompt is not None:
        return answer(language, seg(0.1 * d, 0.5 * d, f"Acme sales were 80,000억 and 400,000억 in part {part}"))
    return answer(language, seg(0.1 * d, 0.5 * d, f"ackme sales were 400억 and 83억 in part {part}"), seg(0.7 * d, 0.9 * d, "아 이해했습니다"))


class ScriptedEngine(Engine):
    """A local Whisper-like engine with scripted answers (``script(audio, language, prompt, call_index)``) that records every call."""
    name = "scripted"
    prompt_frames = WhisperEngine.prompt_frames

    def __init__(self, script, *, kind="local", uses_prompt=True, supports_lid=False, confidence="logprob"):
        super().__init__("scripted-model")
        self.script, self.kind, self.uses_prompt, self.supports_lid, self.confidence = script, kind, uses_prompt, supports_lid, confidence
        self.calls = []                       # (n_samples, language, prompt)

    def load(self):
        pass

    @property
    def tokenizer(self):
        return types.SimpleNamespace(encode=lambda text: text.split())

    def detect_languages(self, clips, languages=asr_engines.LID_CANDIDATES):
        return [asr_engines.restrict_lid({"ko": 0.1, "en": 0.9}, languages) for _ in clips]

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append((len(audio), language, prompt))
        return self.script(audio, language, prompt, len(self.calls) - 1)

    def provenance(self):
        return {"schema": 1, "engine": "scripted", "kind": self.kind, "privacy": self.kind, "chunks": {"scripted": len(self.calls)}} \
            if self.kind != "local" else None


def run_track(engine, *, strategy="single", vocab=VOCAB, **kw):
    kw.setdefault("language", "en")
    total = 100.0
    result_vad = vad.VadResult(REGIONS, "energy", np.full(int(total * 50), -50.0, np.float32), {})
    c = Config(support_dir=Path(tempfile.gettempdir()) / "mcap-test-nonexistent", asr_strategy=strategy)
    return asr.transcribe_track(np.zeros(int(total * SR), np.float32), engine, c, vocab, track="remote", vad=result_vad, **kw)


def run_tracks(engine, **cfg_kw):
    with tempfile.TemporaryDirectory(prefix="mcap-dual-") as tmp:
        c = mg.golden_config(Path(tmp), asr_language=cfg_kw.pop("asr_language", "en"), **cfg_kw)
        with mg.fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
            return asr.transcribe_tracks(mg.prepared_audio(), c, VOCAB, lambda message: None)


# ---------------------------------------------------------------------------------------------- the key
class ConfigKeyTest(unittest.TestCase):
    def load(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.env"
            path.write_text(text, encoding="utf-8")
            return load_config(path)

    def test_the_key_is_parsed_into_the_field(self):
        self.assertEqual(config._KEYS["ASR_STRATEGY"][0], "asr_strategy")
        self.assertEqual(parse_env_text("ASR_STRATEGY=dual  # two passes\n"), {"ASR_STRATEGY": "dual"})

    def test_words_are_trimmed_and_case_folded(self):
        for text, expected in (("dual", "dual"), ("DUAL", "dual"), ("  Dual ", "dual"), ("single", "single"), ("Single", "single")):
            with self.subTest(text):
                cfg = self.load(f"ASR_STRATEGY={text}\n")
                self.assertEqual(cfg.asr_strategy, expected)
                self.assertEqual([w for w in cfg.config_warnings if "ASR_STRATEGY" in w], [])

    def test_an_unknown_word_reads_as_single_and_is_reported_not_raised(self):
        cfg = self.load("ASR_STRATEGY=duel\n")
        self.assertEqual(cfg.asr_strategy, "single")
        self.assertTrue([w for w in cfg.config_warnings if w.startswith("ASR_STRATEGY: unrecognised value 'duel'")])

    def test_an_empty_value_and_a_missing_key_are_the_default(self):
        self.assertEqual(self.load("ASR_STRATEGY=\n").asr_strategy, Config().asr_strategy)
        self.assertEqual(self.load("").asr_strategy, Config().asr_strategy)

    def test_the_example_file_and_the_built_in_default_agree(self):
        example = ROOT / "config" / "config.env.example"
        self.assertEqual(parse_env_text(example.read_text(encoding="utf-8")).get("ASR_STRATEGY"), Config().asr_strategy)
        self.assertEqual(load_config(example).asr_strategy, Config().asr_strategy)

    def test_the_documents_name_the_same_default(self):
        # CONFIGURATION.md <-> config.env.example is also pinned by scripts/test_scripts.sh; the README rows are only pinned here
        for doc in ("README.md", "README.ko.md", "docs/CONFIGURATION.md"):
            row = re.search(r"^\| `ASR_STRATEGY` \| `(\w+)`", (ROOT / doc).read_text(encoding="utf-8"), re.M)
            self.assertIsNotNone(row, doc)
            self.assertEqual(row.group(1), Config().asr_strategy, doc)

    def test_the_built_in_default_is_dual(self):
        # dual is the default because it passed the bench gate (docs/CONFIGURATION.md); going back to single is a deliberate edit of this test too
        self.assertEqual(Config().asr_strategy, "dual")
        self.assertEqual(self.load("").asr_strategy, "dual")
        self.assertEqual(self.load("ASR_STRATEGY=single\n").asr_strategy, "single")                # an explicit single (an older config.env) stays single
        self.assertEqual(asr.asr_strategy(Config()), "dual")

    def test_the_stage_reads_anything_but_dual_as_single(self):
        for value, expected in (("dual", "dual"), (" DUAL ", "dual"), ("single", "single"), ("", "single"), (None, "single"), ("duel", "single"), (3, "single")):
            self.assertEqual(asr.asr_strategy(types.SimpleNamespace(asr_strategy=value)), expected, repr(value))
        self.assertEqual(asr.asr_strategy(types.SimpleNamespace()), "single")                      # a config object without the field


# ---------------------------------------------------------------------------------------------- single is what it was
class SingleUnchangedTest(unittest.TestCase):
    def test_single_decodes_each_chunk_once_and_writes_no_strategy_key(self):
        engine = ScriptedEngine(two_passes)
        res = run_track(engine, strategy="single")
        self.assertEqual(len(engine.calls), res.info["chunks"])
        self.assertTrue(all(prompt for _, _, prompt in engine.calls))
        self.assertNotIn("strategy", res.info)
        self.assertNotIn("dual", res.info)
        self.assertTrue(all("80,000억" in s["text"] for s in res.segments))                        # the prompted answers, as before

    def test_a_config_without_the_key_is_single(self):
        engine = ScriptedEngine(two_passes)
        total = 100.0
        old_style = types.SimpleNamespace(**{k: v for k, v in vars(Config()).items() if k != "asr_strategy"})   # a config built before the key existed
        asr.transcribe_track(np.zeros(int(total * SR), np.float32), engine, old_style, VOCAB, track="remote", language="en",
                             vad=vad.VadResult(REGIONS, "energy", np.full(int(total * 50), -50.0, np.float32), {}))
        self.assertEqual(len(engine.calls), 3)

    def test_the_frozen_golden_run_is_byte_identical_with_single(self):
        expected = json.loads((Path(mg.__file__).resolve().parent / "default_transcribe_tracks.json").read_text(encoding="utf-8"))["lid_auto"]
        with tempfile.TemporaryDirectory() as tmp, mg.pinned_tz():
            run = mg.run_transcribe_tracks(Path(tmp), asr_language="auto", asr_strategy="single")
        self.assertEqual(json.loads(json.dumps(run)), expected)
        self.assertEqual(list(run["transcript"]), DEFAULT_KEYS)

    def test_single_with_an_external_engine_is_the_external_record_and_nothing_else(self):
        for kind in ("server", "cloud"):
            with self.subTest(kind):
                engine = ScriptedEngine(two_passes, kind=kind, uses_prompt=False)
                out = run_tracks(engine, asr_strategy="single")
                self.assertEqual(out["asr"], {"schema": 1, "engine": "scripted", "kind": kind, "privacy": kind, "chunks": {"scripted": len(engine.calls)}})
                self.assertNotIn("strategy", json.dumps(out))


# ---------------------------------------------------------------------------------------------- dual
class DualChunkLoopTest(unittest.TestCase):
    def test_dual_decodes_every_chunk_twice_and_the_second_pass_has_no_prompt(self):
        engine = ScriptedEngine(two_passes)
        res = run_track(engine, strategy="dual")
        n = res.info["chunks"]
        self.assertEqual((n, len(engine.calls)), (3, 6))
        for i in range(n):
            (len_p, lang_p, prompt_p), (len_n, lang_n, prompt_n) = engine.calls[2 * i], engine.calls[2 * i + 1]
            self.assertTrue(prompt_p and "Acme" in prompt_p, "pass P keeps the vocabulary prompt")
            self.assertIsNone(prompt_n)
            self.assertEqual((len_p, lang_p), (len_n, lang_n))                                   # the same chunk, the same language

    def test_a_config_without_the_key_decodes_every_chunk_twice(self):
        engine = ScriptedEngine(two_passes)
        total = 100.0
        res = asr.transcribe_track(np.zeros(int(total * SR), np.float32), engine, Config(support_dir=Path(tempfile.gettempdir()) / "mcap-test-nonexistent"),
                                   VOCAB, track="remote", language="en", vad=vad.VadResult(REGIONS, "energy", np.full(int(total * 50), -50.0, np.float32), {}))
        self.assertEqual((res.info["chunks"], len(engine.calls)), (3, 6))
        self.assertEqual(res.info["strategy"], "dual")
        self.assertTrue(engine.calls[0][2] and engine.calls[1][2] is None)

    def test_pass_n_gets_the_language_of_pass_p_with_language_id_and_without(self):
        engine = ScriptedEngine(two_passes, supports_lid=True)
        run_track(engine, strategy="dual", language="auto")
        self.assertEqual({lang for _, lang, _ in engine.calls}, {"en"})
        engine = ScriptedEngine(two_passes, supports_lid=False)                                 # the engine decides: both passes get None
        run_track(engine, strategy="dual", language="auto")
        self.assertEqual({lang for _, lang, _ in engine.calls}, {None})

    def test_the_reconciled_segments_reach_the_postfilter_and_the_transcript(self):
        res = run_track(ScriptedEngine(two_passes), strategy="dual")
        texts = [s["text"] for s in res.segments]
        self.assertEqual(len(texts), 6)
        self.assertEqual([t for t in texts if t == "아 이해했습니다"], ["아 이해했습니다"] * 3)             # restored
        self.assertTrue(all("400억" in t for t in texts if t != "아 이해했습니다"))                          # N won the figure
        self.assertFalse([t for t in texts if "80,000억" in t])
        self.assertEqual(res.info["strategy"], "dual")
        self.assertEqual(res.info["dual"], {"chunks": 3, "conflicts": 3, "plain_chosen": 3, "restored": 3})
        self.assertEqual(res.info["segments"], 6)
        self.assertEqual(res.dropped, [])

    def test_the_postfilter_still_judges_what_the_reconcile_restored(self):
        def script(audio, language, prompt, i):
            d = len(audio) / SR
            text = f"We reviewed the Acme pilot part {round(d)}"
            if prompt is not None:
                return answer(language, seg(0.1 * d, 0.5 * d, text))
            return answer(language, seg(0.1 * d, 0.5 * d, text), seg(0.7 * d, 0.9 * d, "Thanks for watching!"))
        res = run_track(ScriptedEngine(script), strategy="dual")
        self.assertEqual(res.info["dual"]["restored"], 3)
        self.assertEqual(res.dropped_by_reason, {"strong_phantom": 3})
        self.assertFalse([s for s in res.segments if "watching" in s["text"]])

    def test_each_segment_keeps_the_language_of_the_pass_it_came_from(self):
        def script(audio, language, prompt, i):
            d = len(audio) / SR
            if prompt is not None:
                return answer("ko", seg(0.1 * d, 0.9 * d, "sales 80,000억"))
            return answer("en", seg(0.1 * d, 0.9 * d, "sales 400억"))
        res = run_track(ScriptedEngine(script), strategy="dual", language="auto")
        self.assertEqual({s["lang"] for s in res.segments}, {"en"})
        self.assertEqual(res.language, "en")

    def test_a_failing_plain_pass_never_loses_the_chunk(self):
        def script(audio, language, prompt, i):
            if prompt is None:
                raise RuntimeError("boom")
            return two_passes(audio, language, prompt, i)
        single = run_track(ScriptedEngine(two_passes), strategy="single")
        with self.assertLogs("mcap.asr", "WARNING") as logged:
            res = run_track(ScriptedEngine(script), strategy="dual")
        self.assertEqual(res.segments, single.segments)
        self.assertEqual(len([m for m in logged.output if "plain pass failed" in m]), 3)
        self.assertNotIn("dual", res.info)                                                       # nothing was reconciled: nothing is claimed
        self.assertEqual(res.info.get("failed_chunks", 0), 0)

    def test_a_failing_prompted_pass_is_a_failed_chunk_as_before_and_pass_n_is_not_run(self):
        calls = []

        def script(audio, language, prompt, i):
            calls.append(prompt)
            if prompt is not None and len(calls) == 1:
                raise RuntimeError("boom")
            return two_passes(audio, language, prompt, i)
        with self.assertLogs("mcap.asr", "ERROR"):
            res = run_track(ScriptedEngine(script), strategy="dual")
        self.assertEqual(res.info["failed_chunks"], 1)
        self.assertEqual(len(calls), 5)                                                          # chunk 1: one call, chunks 2 and 3: two each

    def test_an_accepted_retry_is_pass_n_and_costs_no_third_call(self):
        def script(audio, language, prompt, i):
            d = len(audio) / SR
            if prompt is not None:                                                               # a poor prompted decode: retried without the prompt
                return answer(language, seg(0.1 * d, 0.9 * d, "uncertain words from the prompt", lp=-1.4), lp=-1.4)
            return answer(language, seg(0.1 * d, 0.9 * d, "a clean sentence without the prompt", lp=-0.2), lp=-0.2)
        engine = ScriptedEngine(script)
        res = run_track(engine, strategy="dual")
        self.assertEqual(len(engine.calls), 6)                                                   # P and the retry per chunk, no third decode
        self.assertEqual(res.info["retries_accepted"], 3)
        self.assertEqual({s["text"] for s in res.segments}, {"a clean sentence without the prompt"})
        self.assertEqual(res.info["dual"], {"chunks": 3, "conflicts": 0, "plain_chosen": 0, "restored": 0})

    def test_a_retry_that_is_not_accepted_still_gets_its_plain_pass(self):
        def script(audio, language, prompt, i):
            d = len(audio) / SR
            return answer(language, seg(0.1 * d, 0.9 * d, "the same poor words", lp=-1.4), lp=-1.4)
        engine = ScriptedEngine(script)
        res = run_track(engine, strategy="dual")
        self.assertEqual((res.info["prompt_retries"], res.info.get("retries_accepted", 0), len(engine.calls)), (3, 0, 9))   # P, retry, plain per chunk


class DualGateTest(unittest.TestCase):
    """Dual only runs where its rules make sense: a local engine that takes a prompt and reports log-probs."""

    def assert_single(self, engine, **kw):
        res = run_track(engine, strategy="dual", **kw)
        self.assertEqual(len(engine.calls), res.info["chunks"], "one decode per chunk")
        self.assertNotIn("strategy", res.info)
        self.assertNotIn("dual", res.info)

    def test_an_external_engine_is_always_single(self):
        for kind in ("server", "cloud", "unknown", None):
            with self.subTest(kind):
                self.assert_single(ScriptedEngine(two_passes, kind=kind))

    def test_an_engine_that_builds_its_own_prompt_is_single(self):
        self.assert_single(ScriptedEngine(two_passes, uses_prompt=False))

    def test_an_engine_without_log_probs_is_single(self):
        for confidence in ("opaque", "none"):
            with self.subTest(confidence):
                self.assert_single(ScriptedEngine(two_passes, confidence=confidence))

    def test_prompt_style_none_and_an_empty_vocabulary_decode_once(self):
        self.assert_single(ScriptedEngine(two_passes), prompt_style="none")
        engine = ScriptedEngine(two_passes)
        res = run_track(engine, strategy="dual", vocab=Vocab())
        self.assertEqual(len(engine.calls), 3)
        self.assertNotIn("dual", res.info)

    def test_an_external_engine_in_a_full_run_ignores_dual_and_says_nothing_about_it(self):
        engine = ScriptedEngine(two_passes, kind="server", uses_prompt=False)
        out = run_tracks(engine, asr_strategy="dual")
        self.assertNotIn("strategy", json.dumps(out))
        self.assertNotIn("dual", json.dumps(out))
        self.assertEqual(out["asr"]["kind"], "server")

    def test_the_built_in_default_never_sends_audio_twice_to_an_external_engine(self):
        for kind in ("server", "cloud"):
            with self.subTest(kind):
                engine = ScriptedEngine(two_passes, kind=kind, uses_prompt=False)
                out = run_tracks(engine, asr_strategy=Config().asr_strategy)                        # what a config.env without the key reads as
                self.assertEqual(out["asr"], {"schema": 1, "engine": "scripted", "kind": kind, "privacy": kind, "chunks": {"scripted": len(engine.calls)}})
                self.assertEqual(len(engine.calls), sum(out["stats"][t]["chunks"] for t in ("mic", "remote")))


class DualProvenanceTest(unittest.TestCase):
    def test_the_transcript_records_the_strategy_additively(self):
        engine = ScriptedEngine(two_passes)
        out = run_tracks(engine, asr_strategy="dual")
        stats = {t: out["stats"][t]["dual"] for t in ("mic", "remote")}
        for t in ("mic", "remote"):
            self.assertEqual(out["stats"][t]["strategy"], "dual")
            self.assertEqual(set(stats[t]), {"chunks", "conflicts", "plain_chosen", "restored"})
            self.assertGreater(stats[t]["chunks"], 0)
        totals = {k: sum(stats[t][k] for t in stats) for k in ("chunks", "conflicts", "plain_chosen", "restored")}
        self.assertEqual(out["asr"], {"schema": 1, "engine": "scripted", "kind": "local", "strategy": "dual", "dual": totals})
        self.assertEqual(len(engine.calls), 2 * totals["chunks"])
        self.assertEqual(list(out)[:len(DEFAULT_KEYS)], DEFAULT_KEYS)                           # the default keys keep their place, "asr" is appended
        self.assertEqual(list(out)[-1], "asr")
        self.assertEqual(out["asr_model"], Config().asr_model)                                   # a local run never renames the model
        self.assertEqual(tr.validate_transcript(out), [])
        json.dumps(out, allow_nan=False)

    def test_single_adds_not_one_key(self):
        single = run_tracks(ScriptedEngine(two_passes), asr_strategy="single")
        self.assertEqual(list(single), DEFAULT_KEYS)
        for track in ("mic", "remote"):
            self.assertFalse({"strategy", "dual"} & set(single["stats"][track]))

    def test_the_markdown_header_of_a_dual_transcript_is_the_header_of_a_single_one(self):
        meta = dict(mg.META)
        dual = tr.render_markdown(run_tracks(ScriptedEngine(two_passes), asr_strategy="dual"), meta).split("\n\n")[1]
        single = tr.render_markdown(run_tracks(ScriptedEngine(two_passes), asr_strategy="single"), meta).split("\n\n")[1]
        self.assertEqual(dual, single)
        self.assertNotIn("Route:", dual)

    def test_only_the_strategy_record_has_no_route_line(self):
        self.assertEqual(tr.route_line({"schema": 1, "engine": "scripted", "kind": "local", "strategy": "dual", "dual": {"chunks": 1}}), "")
        self.assertEqual(tr.route_line({"engine": "remote", "kind": "local", "privacy": "server"}), "Route: remote (local)")        # a record with a route says so
        self.assertEqual(tr.route_line({"engine": "remote", "kind": "server", "strategy": "dual"}), "Route: remote (server)")

    def test_a_dual_run_without_any_chunk_decoded_twice_leaves_no_trace(self):
        with tempfile.TemporaryDirectory() as tmp:
            c = mg.golden_config(Path(tmp), asr_language="en", asr_strategy="dual")
            with mg.fake_clock(), mock.patch.object(asr, "get_engine", return_value=ScriptedEngine(two_passes)):
                empty = asr.transcribe_tracks(mg.prepared_audio(), c, Vocab(), lambda message: None)      # no vocabulary: no prompt: one decode
        self.assertNotIn("asr", empty)


# ---------------------------------------------------------------------------------------------- the benchmark mode
def load_bench():
    spec = importlib.util.spec_from_file_location("bench_asr_dual_under_test", ROOT / "scripts" / "bench_asr.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def metrics(**kw):
    base = {"segments": 100, "words": 900, "english_words": 20, "digit_tokens": 10, "implausible_numbers": 2, "loops4": 0, "asr_s": 100.0, "wall_s": 104.0}
    base.update(kw)
    return base


class BenchMetricsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bench = load_bench()

    def test_the_metrics_are_counts_of_the_segments(self):
        segments = [{"text": "We submit the FDA 510(k) in 2026, it is 80,000억 or 400억"}, {"text": "네"}, {"text": "state-of-the-art didn't"}]
        m = self.bench.strategy_metrics(segments, 12.5, 14.0)
        self.assertEqual((m["segments"], m["words"]), (3, 15))
        self.assertEqual(m["english_words"], 10)                     # We submit the FDA in it is or, state-of-the-art, didn't ("k" is one letter)
        self.assertEqual(m["digit_tokens"], 4)                       # 510, 2026, 80,000, 400
        self.assertEqual(m["implausible_numbers"], 1)
        self.assertEqual((m["asr_s"], m["wall_s"]), (12.5, 14.0))

    def test_loops_are_runs_of_an_immediately_repeated_four_word_sequence(self):
        loops = self.bench.loops4
        self.assertEqual(loops(["no repeat in this text at all"]), 0)
        self.assertEqual(loops(["a b c d a b c d"]), 1)
        self.assertEqual(loops(["a b c d a b c d a b c d a b c d"]), 1)                        # one long run is one loop
        self.assertEqual(loops(["a b c d a b c d", "x y z w", "p q r s p q r s"]), 2)
        self.assertEqual(loops(["아 아 아 아 아 아 아 아 아"]), 1)
        self.assertEqual(loops(["a b c d", "a b c d"]), 1)                                      # across segments
        self.assertEqual(loops(["a b c", "d e f"]), 0)
        self.assertEqual(loops([]), 0)

    def test_the_gate_needs_every_rule_on_every_slice(self):
        gate = self.bench.strategy_gate
        good = {"slice": "a", "single": metrics(), "dual": metrics(implausible_numbers=1, english_words=19, segments=120, asr_s=240.0,
                                                                    words=882, digit_tokens=9)}                    # every limit exactly met
        verdict = gate([good, good])
        self.assertTrue(verdict["default_dual"], verdict)
        self.assertEqual(verdict["ratios"], [2.4, 2.4])
        for name, dual in (("implausible", metrics(implausible_numbers=3)), ("english", metrics(english_words=18, segments=120)),
                           ("segments", metrics(segments=99)), ("loops", metrics(loops4=1, segments=120)), ("time", metrics(asr_s=240.1, segments=120)),
                           ("words", metrics(words=881, segments=120)), ("digits", metrics(digit_tokens=8, segments=120))):
            with self.subTest(name):
                verdict = gate([good, {"slice": "b", "single": metrics(), "dual": dual}])
                self.assertFalse(verdict["default_dual"])
                self.assertEqual(sum(1 for ok in verdict["checks"].values() if not ok), 1, verdict["checks"])
        self.assertFalse(gate([])["default_dual"])
        self.assertFalse(gate([{"slice": "z", "single": metrics(asr_s=0.0), "dual": metrics(asr_s=1.0, segments=100)}])["default_dual"])   # no time to compare

    def write_run(self, root, name, single, dual, extra=()):
        d = root / name
        d.mkdir()
        rows = [{"model": "m__single", "strategy": "single", **single}, {"model": "m__dual", "strategy": "dual", **dual}, *extra]
        (d / "summary.json").write_text(json.dumps({"models": rows}), encoding="utf-8")
        return str(d)

    def test_the_gate_reads_the_summaries_and_the_exit_code_follows_the_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dual_ok = metrics(segments=120, asr_s=200.0)
            good = [self.write_run(root, f"s{i}", metrics(), dual_ok) for i in range(3)]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(self.bench.main(["--gate-from", *good]), 0)
            self.assertIn("verdict: dual MAY be the default", out.getvalue())
            self.assertIn("PASS  implausible numbers not higher", out.getvalue())
            bad = good[:2] + [self.write_run(root, "slow", metrics(), metrics(segments=120, asr_s=300.0))]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(self.bench.main(["--gate-from", *bad]), 1)
            self.assertIn("FAIL  time <= 2.4x single", out.getvalue())
            self.assertIn("stays opt-in", out.getvalue())

    def test_the_gate_needs_both_rows_of_a_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "half"
            d.mkdir()
            (d / "summary.json").write_text(json.dumps({"models": [{"model": "m", "strategy": "single", **metrics()}]}), encoding="utf-8")
            with self.assertRaises(SystemExit) as raised:
                self.bench.gate_slices([str(d)])
            self.assertIn("single and one successful dual", str(raised.exception))
            with self.assertRaises(SystemExit):
                self.bench.gate_slices([str(Path(tmp) / "missing")])

    def test_the_arguments(self):
        b = self.bench
        self.assertEqual(b.parse_args(["--audio", "x.wav", "--models", "m"]).strategy, Config().asr_strategy)
        self.assertEqual(b.parse_args(["--audio", "x.wav", "--models", "m", "--strategy", "both"]).strategy, "both")
        self.assertEqual(b.parse_args(["--gate-from", "a", "b"]).gate_from, ["a", "b"])                     # no model, no audio needed
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                b.parse_args(["--audio", "x.wav"])                                                           # a run still needs --models


class BenchStrategyRunTest(unittest.TestCase):
    """``--strategy both`` end to end with a scripted local engine: both rows, the metrics, the report files, the gate."""

    @classmethod
    def setUpClass(cls):
        cls.bench = load_bench()

    def test_both_runs_every_local_model_once_per_strategy_and_the_gate_reads_the_result(self):
        b = self.bench
        engines = []

        def make_engine(model, allow_download):
            engines.append(ScriptedEngine(two_passes))
            return engines[-1]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wav = root / "slice.wav"
            wavio.write_wav_int16(wav, mg.synth_track([(2, 6, 0.2), (8, 12, 0.2), (30, 36, 0.2)], 40.0), SR)
            out_dirs = []
            for name in ("one", "two"):
                out_dirs.append(root / name)
                out, err = io.StringIO(), io.StringIO()
                with mock.patch.object(b, "make_engine", make_engine), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = b.main(["--audio", str(wav), "--models", "scripted-model", "--strategy", "both", "--language-mode", "forced-en", "--vad", "energy",
                                   "--out", str(out_dirs[-1]), "--no-download", "-q"])
                self.assertEqual(code, 0, err.getvalue())
            self.assertEqual(len(engines), 4)                                                     # two runs of single and dual each
            single, dual = engines[0], engines[1]
            self.assertEqual((len(dual.calls), len(single.calls)), (2 * len(single.calls), len(single.calls)))
            summary = json.loads((out_dirs[0] / "summary.json").read_text(encoding="utf-8"))
            rows = {r["strategy"]: r for r in summary["models"]}
            self.assertEqual({r["model"] for r in summary["models"]}, {"scripted-model__single", "scripted-model__dual"})
            for key in ("segments", "words", "english_words", "digit_tokens", "implausible_numbers", "loops4", "asr_s", "wall_s"):
                self.assertIn(key, rows["single"], key)
            self.assertGreater(rows["single"]["implausible_numbers"], 0)                         # the prompted answers carry 80,000억
            self.assertEqual(rows["dual"]["implausible_numbers"], 0)                             # the plain ones do not
            self.assertGreater(rows["dual"]["segments"], rows["single"]["segments"])
            for slug in ("scripted-model__single", "scripted-model__dual"):
                self.assertTrue((out_dirs[0] / slug / "transcript.md").is_file(), slug)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = b.main(["--gate-from", *map(str, out_dirs)])
            self.assertIn("PASS  implausible numbers not higher", out.getvalue())
            self.assertIn("PASS  segments >= single", out.getvalue())
            self.assertEqual(code, 0 if "MAY be" in out.getvalue() else 1)                         # the time rule depends on the clock of a fake engine

    def test_an_external_engine_runs_once_and_single_even_with_both(self):
        b = self.bench
        engines = []

        def make_engine(model, allow_download):
            engines.append(ScriptedEngine(two_passes, kind="server", uses_prompt=False))
            return engines[-1]
        with tempfile.TemporaryDirectory() as tmp:
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(b, "make_engine", make_engine), mock.patch.object(b, "external_engine_ids", lambda models: list(models)), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(sys, "stdin", io.StringIO()):
                code = b.main(["--models", "remote", "--strategy", "both", "--vad", "energy", "--synthetic-seconds", "6", "--out", str(Path(tmp) / "o"), "-q"])
            self.assertEqual(code, 0, err.getvalue())
            self.assertEqual(len(engines), 1)
            rows = json.loads((Path(tmp) / "o" / "summary.json").read_text(encoding="utf-8"))["models"]
            self.assertEqual([(r["model"], r["strategy"]) for r in rows], [("remote", "single")])


if __name__ == "__main__":
    unittest.main()
