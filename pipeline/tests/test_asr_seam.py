"""The engine seam (SPEC 18): what an ASR engine may declare about itself, and how
``asr`` / ``transcript`` / ``audioprep`` use it. Everything here is faked: scripted engines, no model, no socket, no Keychain, no
``claude``. The default path (a local Whisper-like engine) must behave exactly as before: ``test_default_unchanged.py`` freezes that
with golden files, this file tests each piece of the seam on its own.

Run: python -m unittest discover -s pipeline/tests
"""
import contextlib
import hashlib
import json
import logging
import os
import signal
import sys
import tempfile
import types
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from golden import make_golden as mg  # noqa: E402
from mcap import asr, asr_engines, audioprep, logsafe, pipeline, transcript as tr, vad  # noqa: E402
from mcap.asr_engines import (Engine, EngineAuthError, EngineCapReached, EngineCaps, EngineError, EnginePolicyDenied,  # noqa: E402
                              EngineTransient, EngineUnavailable, WhisperEngine, engine_caps)
from mcap.config import Config  # noqa: E402
from mcap.vocab import Vocab, parse_vocab_text  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())

SR = 16000
VOCAB = parse_vocab_text("Acme\nAcmeScan-CXR\nFDA\n510(k)\nPre-Sub\nHIPAA\nExample Radiology\nAcme = 애크미 | 액미\n")
REGIONS = [(1.0, 5.0), (6.0, 9.0), (40.0, 45.0), (80.0, 83.0)]       # three chunks of 28 s windows (like test_asr.TrackLoopTest)


def cfg(**kw):
    kw.setdefault("support_dir", Path(tempfile.gettempdir()) / "mcap-test-nonexistent")
    kw.setdefault("asr_strategy", "single")      # these tests count one decode per chunk; the built-in default is dual (test_asr_dual.py)
    return Config(**kw)


def vad_result(regions, total):
    return vad.VadResult(regions, "energy", np.full(int(total * 50), -50.0, np.float32), {})


def seg(start, end, text, lp=-0.3, ns=0.02, cr=1.1):
    return {"start": start, "end": end, "text": text, "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": cr, "temperature": 0.0}


def one_segment(audio, language, prompt, i):
    d = len(audio) / SR
    return {"text": f"chunk {i}", "language": language, "avg_logprob": -0.3, "segments": [seg(0.2, d - 0.2, f"chunk {i}")]}


class ScriptedEngine(Engine):
    """An engine whose seam attributes are constructor arguments; records every call. ``script(audio, language, prompt, i)``."""
    name = "scripted"

    def __init__(self, script=None, *, kind="local", uses_prompt=True, supports_lid=False, confidence="logprob", timing="segment",
                 tag="", provenance=None, seen=None, tokenizer_forbidden=False, **extra):
        super().__init__("scripted-model")
        self.kind, self.uses_prompt, self.supports_lid, self.confidence, self.timing = kind, uses_prompt, supports_lid, confidence, timing
        self.script = script or one_segment
        self.tag, self._provenance, self._seen = tag, provenance, seen
        self.tokenizer_forbidden = tokenizer_forbidden
        self.tokenizer_uses = 0
        self.calls = []                     # (n_samples, language, prompt)
        self.lid_calls = 0
        self.events = []                    # "provenance", "release": the order the stage used them in
        for key, value in extra.items():
            setattr(self, key, value)

    prompt_frames = WhisperEngine.prompt_frames

    def load(self):
        pass

    @property
    def tokenizer(self):
        self.tokenizer_uses += 1
        if self.tokenizer_forbidden:
            raise AssertionError("an engine with uses_prompt=False must never be asked for its tokenizer")
        return types.SimpleNamespace(encode=lambda text: text.split())

    def detect_languages(self, clips, languages=asr_engines.LID_CANDIDATES):
        self.lid_calls += 1
        return [asr_engines.restrict_lid({"ko": 0.1, "en": 0.9}, languages) for _ in clips]

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append((len(audio), language, prompt))
        return self.script(audio, language, prompt, len(self.calls) - 1)

    def progress_tag(self):
        if isinstance(self.tag, Exception):
            raise self.tag
        return self.tag(len(self.calls)) if callable(self.tag) else self.tag

    def provenance(self):
        self.events.append("provenance")
        if isinstance(self._provenance, Exception):
            raise self._provenance
        return self._provenance

    def prompt_text_seen(self):
        return self._seen

    def release(self):
        self.events.append("release")


class BareDouble:
    """Not an Engine at all: only what the chunk loop needs. engine_caps must still work."""
    model = "bare"
    prompt_frames = WhisperEngine.prompt_frames

    def __init__(self):
        self.calls = []

    def load(self):
        pass

    @property
    def tokenizer(self):
        return types.SimpleNamespace(encode=lambda text: text.split())

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append((len(audio), language, prompt))
        return one_segment(audio, language, prompt, len(self.calls) - 1)


def run_track(engine, regions=None, total=100.0, config=None, **kw):
    progress = []
    kw.setdefault("language", "en")
    res = asr.transcribe_track(np.zeros(int(total * SR), np.float32), engine, config or cfg(), VOCAB, track="remote",
                               vad=vad_result(REGIONS if regions is None else regions, total), progress=progress.append, **kw)
    return res, progress


@contextlib.contextmanager
def deadline(seconds=20):
    """A hang is a failure, not a stuck test run (the chunk planner looped for ever on a limit of 0)."""
    def expired(signum, frame):
        raise AssertionError(f"still running after {seconds} s: the chunk planner or the stage hangs")
    try:
        previous = signal.signal(signal.SIGALRM, expired)
    except ValueError:                                                      # not the main thread: no guard, the test still runs
        yield
        return
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def run_tracks(engine, **cfg_kw):
    """transcribe_tracks over the synthetic two-track audio of the golden fixtures (energy VAD, echo canceller off)."""
    with tempfile.TemporaryDirectory(prefix="mcap-seam-") as tmp:
        c = mg.golden_config(Path(tmp), asr_language=cfg_kw.pop("asr_language", "en"), **cfg_kw)
        progress = []
        with mg.fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
            out = asr.transcribe_tracks(mg.prepared_audio(), c, VOCAB, progress.append)
    return out, progress


# ---------------------------------------------------------------------------------------
# capabilities
# ---------------------------------------------------------------------------------------
class CapsTest(unittest.TestCase):
    def test_default_caps_are_a_local_whisper(self):
        self.assertEqual(EngineCaps(), EngineCaps(kind="local", uses_prompt=True, supports_lid=False, timing="segment",
                                                  confidence="logprob", max_chunk_s=28.0, residency="device"))
        with self.assertRaises(Exception):
            EngineCaps().kind = "cloud"                                     # frozen

    def test_engine_defaults_and_the_derived_caps(self):
        e = ScriptedEngine()
        self.assertEqual(e.caps, EngineCaps())
        self.assertEqual((e.kind, e.residency, e.uses_prompt, e.timing, e.confidence), ("local", "device", True, "segment", "logprob"))
        self.assertEqual((e.usage(), e.provenance(), e.prompt_text_seen(), e.progress_tag()), ({}, None, None, ""))
        plain = Engine("m")
        self.assertEqual((plain.usage(), plain.provenance(), plain.prompt_text_seen(), plain.progress_tag()), ({}, None, None, ""))
        self.assertEqual(plain.caps, EngineCaps())
        self.assertEqual(plain.describe(), {"engine": "engine", "model": "m", "kind": "local", "residency": "device", "uses_prompt": True,
                                            "supports_lid": False, "timing": "segment", "confidence": "logprob"})

    def test_caps_follow_the_instance_and_the_class(self):
        e = ScriptedEngine(kind="server", uses_prompt=False, supports_lid=True, confidence="opaque", timing="chunk", residency="kr")
        self.assertEqual(e.caps, EngineCaps(kind="server", uses_prompt=False, supports_lid=True, timing="chunk", confidence="opaque",
                                            max_chunk_s=28.0, residency="kr"))
        self.assertEqual(e.describe()["kind"], "server")
        self.assertEqual(engine_caps(asr_engines.WhisperEngine("x")).supports_lid, True)           # a class attribute counts
        self.assertEqual(engine_caps(asr_engines.QwenEngine("x")), EngineCaps())
        self.assertEqual(engine_caps(types.SimpleNamespace(chunk_params={"max_chunk_s": 20, "max_inner_gap_s": 4.0})).max_chunk_s, 20.0)

    def test_the_unchanged_fake_engine_of_test_asr_gets_the_defaults(self):
        from test_asr import FakeEngine                                     # the double the whole existing suite runs on, untouched
        e = FakeEngine()
        self.assertEqual(e.caps, EngineCaps(supports_lid=True))              # it declares language ID and nothing else
        self.assertEqual((e.usage(), e.provenance(), e.prompt_text_seen(), e.progress_tag()), ({}, None, None, ""))
        self.assertEqual(engine_caps(FakeEngine(supports_lid=False)), EngineCaps())
        self.assertEqual(e.describe()["engine"], "fake")

    def test_an_engine_limit_on_the_chunk_length_reaches_the_chunk_planner(self):
        long_region = [(10.0, 40.0)]
        engine = ScriptedEngine(max_chunk_s=12.0)
        self.assertEqual(engine.caps.max_chunk_s, 12.0)
        run_track(engine, regions=long_region)
        self.assertGreater(len(engine.calls), 2)
        self.assertTrue(all(n / SR <= 12.0 + 1e-6 for n, _, _ in engine.calls), [n / SR for n, _, _ in engine.calls])
        via_params = ScriptedEngine(chunk_params={"max_chunk_s": 12.0, "max_inner_gap_s": 4.0})      # the older way to say it
        self.assertEqual(via_params.caps.max_chunk_s, 12.0)
        run_track(via_params, regions=long_region)
        self.assertEqual([n for n, _, _ in via_params.calls], [n for n, _, _ in engine.calls])
        default = ScriptedEngine()
        run_track(default, regions=long_region)
        self.assertGreater(max(n for n, _, _ in default.calls) / SR, 12.0)                               # the default window is 28 s
        self.assertLess(len(default.calls), len(engine.calls))

    UNUSABLE_LIMITS = (0, -5, -0.0, 0.001, 0.999, float("nan"), float("inf"), float("-inf"), 1e9, 300, 28.01, True, False, "12", None,
                       [12.0], object(), 10 ** 400)

    def test_an_unusable_chunk_limit_is_ignored(self):
        for value in self.UNUSABLE_LIMITS:
            with self.subTest(repr(value)[:30]):
                self.assertEqual(engine_caps(ScriptedEngine(max_chunk_s=value)).max_chunk_s, 28.0)
                self.assertEqual(engine_caps(ScriptedEngine(chunk_params={"max_chunk_s": value})).max_chunk_s, 28.0)
                self.assertIsNone(asr_engines.chunk_limit(value))

    def test_a_usable_chunk_limit_is_kept(self):
        for value, expected in ((1, 1.0), (1.0, 1.0), (12, 12.0), (28, 28.0), (28.0, 28.0), (np.float32(12.5), 12.5), (np.int64(20), 20.0)):
            with self.subTest(repr(value)):
                self.assertEqual(engine_caps(ScriptedEngine(max_chunk_s=value)).max_chunk_s, expected)
                self.assertEqual(asr_engines.chunk_limit(value), expected)

    def test_an_unusable_chunk_limit_neither_hangs_nor_unbounds_the_chunks(self):
        default = ScriptedEngine()
        run_track(default, regions=[(10.0, 40.0)])
        for value in (0, -5, 0.001, float("nan"), float("inf"), 1e9, 300):
            for how, engine in (("attribute", ScriptedEngine(max_chunk_s=value)),
                                ("chunk_params", ScriptedEngine(chunk_params={"max_chunk_s": value}))):
                with self.subTest(f"{how} {value}"), deadline():
                    run_track(engine, regions=[(10.0, 40.0)])
                    self.assertEqual([n for n, _, _ in engine.calls], [n for n, _, _ in default.calls])        # the 28 s window of today
                    self.assertTrue(all(n / SR <= 28.0 + 1e-6 for n, _, _ in engine.calls))

    def test_one_rule_for_conflicting_limits_in_the_caps_and_in_the_planner(self):
        for name, attrs, expected in (
                ("attribute shorter", dict(max_chunk_s=12.0, chunk_params={"max_chunk_s": 28.0}), 12.0),
                ("chunk_params shorter", dict(max_chunk_s=28.0, chunk_params={"max_chunk_s": 12.0}), 12.0),
                ("attribute unusable", dict(max_chunk_s=0, chunk_params={"max_chunk_s": 12.0}), 12.0),
                ("chunk_params unusable", dict(max_chunk_s=12.0, chunk_params={"max_chunk_s": float("nan")}), 12.0),
                ("both unusable", dict(max_chunk_s=-1, chunk_params={"max_chunk_s": 0}), 28.0),
                ("chunk_params is not a dict", dict(max_chunk_s=12.0, chunk_params=[("max_chunk_s", 5)]), 12.0)):
            with self.subTest(name), deadline():
                engine = ScriptedEngine(**attrs)
                self.assertEqual(engine.caps.max_chunk_s, expected)
                with mock.patch.object(vad, "plan_chunks", wraps=vad.plan_chunks) as plan:
                    run_track(engine, regions=[(10.0, 40.0)])
                self.assertEqual(plan.call_args.kwargs["max_chunk_s"], expected)                               # what caps says is what is planned
                self.assertTrue(all(n / SR <= expected + 1e-6 for n, _, _ in engine.calls), [n / SR for n, _, _ in engine.calls])
        engine = ScriptedEngine(chunk_params={"max_inner_gap_s": 4.0})                                         # the other planner options pass through
        with mock.patch.object(vad, "plan_chunks", wraps=vad.plan_chunks) as plan:
            run_track(engine)
        self.assertEqual((plan.call_args.kwargs["max_inner_gap_s"], plan.call_args.kwargs["max_chunk_s"]), (4.0, 28.0))

    def test_a_double_that_is_not_an_engine_gets_the_defaults(self):
        self.assertEqual(engine_caps(BareDouble()), EngineCaps())
        self.assertEqual(engine_caps(object()), EngineCaps())
        double = types.SimpleNamespace(kind="cloud", confidence="none", uses_prompt=0, supports_lid=1)
        self.assertEqual(engine_caps(double), EngineCaps(kind="cloud", confidence="none", uses_prompt=False, supports_lid=True))

    def test_the_shipped_engines_name_themselves(self):
        self.assertEqual((WhisperEngine("x").engine_id, asr_engines.QwenEngine("x").engine_id), ("whisper", "qwen3-asr"))
        self.assertEqual(WhisperEngine("x").describe()["engine"], "whisper")
        self.assertEqual(ScriptedEngine().describe()["engine"], "scripted")                         # no engine_id: the name is used

    def test_engine_error_hierarchy(self):
        for cls in (EngineTransient, EngineAuthError, EnginePolicyDenied, EngineCapReached):
            self.assertTrue(issubclass(cls, EngineError), cls)
            self.assertTrue(issubclass(cls, RuntimeError), cls)
            self.assertTrue(cls("x").retryable)
        self.assertFalse(issubclass(EngineUnavailable, EngineError))                                # a missing package is not a chunk error
        self.assertTrue(issubclass(asr.AsrUnreachable, RuntimeError))
        self.assertFalse(issubclass(asr.AsrUnreachable, EngineError))


class RegistryTest(unittest.TestCase):
    def test_registry_is_static_and_lazy(self):
        self.assertEqual(set(asr_engines.REGISTRY), {"whisper", "qwen3-asr", "remote", "azure", "google", "clova", "openai-compat"})
        for target in asr_engines.REGISTRY.values():
            module, _, attr = target.partition(":")
            self.assertTrue(module and attr, target)                                                # "module:Class", nothing imported yet
        self.assertIs(asr_engines.engine_class("whisper"), WhisperEngine)
        self.assertIs(asr_engines.engine_class("qwen3-asr"), asr_engines.QwenEngine)

    def test_unknown_missing_and_broken_entries_raise_engine_unavailable(self):
        with self.assertRaisesRegex(EngineUnavailable, "unknown ASR engine 'nope'"):
            asr_engines.engine_class("nope")
        fake = types.ModuleType("mcap_seam_test_adapter")
        fake.Adapter = ScriptedEngine
        with mock.patch.dict(sys.modules, {"mcap_seam_test_adapter": fake}), mock.patch.dict(
                asr_engines.REGISTRY, {"t-ok": "mcap_seam_test_adapter:Adapter", "t-attr": "mcap_seam_test_adapter:Missing",
                                       "t-mod": "mcap_seam_test_no_such_module:Adapter"}):
            self.assertIs(asr_engines.engine_class("t-ok"), ScriptedEngine)
            for engine_id in ("t-attr", "t-mod"):
                with self.subTest(engine_id), self.assertRaisesRegex(EngineUnavailable, "is not available"):
                    asr_engines.engine_class(engine_id)


class GetEngineCacheTest(unittest.TestCase):
    def test_cache_key_is_model_and_allow_download(self):
        with mock.patch.dict(asr_engines._engines, clear=True):
            a = asr_engines.get_engine("x/whisper-a")
            self.assertIs(a, asr_engines.get_engine("x/whisper-a"))
            self.assertIs(a, asr_engines.get_engine("x/whisper-a", allow_download=True))            # True is the default
            offline = asr_engines.get_engine("x/whisper-a", allow_download=False)
            self.assertIsNot(a, offline)                                                            # a local-only run never reuses it
            self.assertIs(offline, asr_engines.get_engine("x/whisper-a", allow_download=False))
            self.assertEqual((a.allow_download, offline.allow_download), (True, False))
            self.assertIsNot(a, asr_engines.get_engine("x/whisper-b"))
            self.assertEqual(set(asr_engines._engines), {("x/whisper-a", True), ("x/whisper-a", False), ("x/whisper-b", True)})


# ---------------------------------------------------------------------------------------
# _engine_for
# ---------------------------------------------------------------------------------------
class EngineForTest(unittest.TestCase):
    def test_default_path_still_calls_get_engine_with_the_model_only(self):
        sentinel = ScriptedEngine()
        for config in (cfg(), types.SimpleNamespace(asr_model="some/model")):                       # a config without asr_decision at all
            with self.subTest(type(config).__name__), mock.patch.object(asr, "get_engine", return_value=sentinel) as ge:
                self.assertIs(asr._engine_for(config, VOCAB), sentinel)
                ge.assert_called_once_with(config.asr_model)                                        # no keyword: exactly as before

    def test_a_decision_goes_to_the_router_and_never_to_get_engine(self):
        built = ScriptedEngine()
        router = types.SimpleNamespace(build_engine=mock.Mock(return_value=built))
        config = cfg()
        config.asr_decision = object()
        progress = lambda msg: None  # noqa: E731
        with mock.patch.dict(sys.modules, {"mcap.asr_router": router}), mock.patch.object(asr, "get_engine") as ge:
            self.assertIs(asr._engine_for(config, VOCAB, progress), built)
        router.build_engine.assert_called_once_with(config, VOCAB, progress=progress)
        ge.assert_not_called()

    def test_a_decision_without_a_router_is_an_error_not_a_silent_local_engine(self):
        config = cfg()
        config.asr_decision = object()
        with mock.patch.dict(sys.modules, {"mcap.asr_router": None}), mock.patch.object(asr, "get_engine") as ge:
            with self.assertRaisesRegex(EngineUnavailable, "router"):
                asr._engine_for(config, VOCAB)
        ge.assert_not_called()

    def test_transcribe_array_and_tracks_use_the_same_seam(self):
        engine = ScriptedEngine()
        with mock.patch.object(asr, "get_engine", return_value=engine) as ge, \
                mock.patch.object(vad, "detect_speech", return_value=vad_result([(1.0, 6.0)], 20.0)):
            segs = asr.transcribe_array(np.zeros(20 * SR, np.float32), cfg(), VOCAB, language="en")
        ge.assert_called_once_with(cfg().asr_model)
        self.assertEqual(len(segs), 1)
        built = ScriptedEngine()
        router = types.SimpleNamespace(build_engine=mock.Mock(return_value=built))
        config = cfg(asr_vad="energy", mic_aec="0", asr_language="en")
        config.asr_decision = object()
        prepared = audioprep.PreparedAudio({t: np.zeros(10 * SR, np.float32) for t in ("mic", "remote")}, SR, 10.0, {})
        with mock.patch.dict(sys.modules, {"mcap.asr_router": router}), mock.patch.object(asr, "get_engine") as ge:
            out = asr.transcribe_tracks(prepared, config, VOCAB)
        self.assertEqual(router.build_engine.call_count, 1)
        ge.assert_not_called()
        self.assertEqual(tr.validate_transcript(out), [])


# ---------------------------------------------------------------------------------------
# decode_chunk == the old inline loop body
# ---------------------------------------------------------------------------------------
def legacy_chunk(engine, audio, lab, prompt, prompt_words, stats, log, track, i, a, b):
    """The 8 lines of transcribe_track's chunk loop as they were before decode_chunk existed (copied from the unmodified asr.py)."""
    res = engine.transcribe_chunk(audio, lab or None, prompt)
    if prompt and asr._suspicious(res, prompt_words):
        stats["prompt_retries"] += 1
        alt = engine.transcribe_chunk(audio, lab or None, None)
        if asr._better(alt, res):
            stats["retries_accepted"] += 1
            log.info("%s chunk %d (%.1f-%.1fs): retry without prompt accepted", track, i + 1, a, b)
            res = alt
    return res


class DecodeChunkTest(unittest.TestCase):
    PROMPT = "A medical AI meeting. Terms: Acme, FDA"
    WORDS = set(asr._norm(PROMPT).split())

    @staticmethod
    def scripted(first, retry):
        def script(audio, language, prompt, i):
            return first if prompt else retry
        return script

    def cases(self):
        good = {"text": "", "avg_logprob": -0.3, "segments": [seg(0, 3, "fine", -0.3)]}
        loops = {"text": "", "avg_logprob": -0.4, "segments": [seg(0, 3, "foo foo foo foo", -0.4, cr=3.5)]}
        clean = {"text": "", "avg_logprob": -0.2, "segments": [seg(0, 3, "a clean retry", -0.2)]}
        poor = {"text": "", "avg_logprob": -1.2, "segments": [seg(0, 3, "mumbled words", -1.2)]}
        poorer = {"text": "", "avg_logprob": -1.25, "segments": [seg(0, 3, "mumbled words again", -1.25)]}
        echoed = {"text": "", "avg_logprob": -0.5, "segments": [seg(0, 3, "Acme FDA Acme FDA Acme FDA", -0.5)]}
        looping_retry = {"text": "", "avg_logprob": -0.1, "segments": [seg(0, 3, "loop loop loop", -0.1, cr=2.9)]}
        truncated = dict(good, truncated=True)
        return [("good first pass: no retry", good, clean, self.PROMPT), ("loop, clean retry accepted", loops, clean, self.PROMPT),
                ("poor, retry not better", poor, poorer, self.PROMPT), ("prompt echo, looping retry refused", echoed, looping_retry, self.PROMPT),
                ("truncated, clean retry accepted", truncated, clean, self.PROMPT), ("no prompt: never a retry", loops, clean, None),
                ("empty prompt: never a retry", loops, clean, "")]

    def test_decode_chunk_equals_the_old_inline_behaviour(self):
        audio = np.zeros(4 * SR, np.float32)
        for name, first, retry, prompt in self.cases():
            with self.subTest(name):
                old_engine, new_engine = ScriptedEngine(self.scripted(first, retry)), ScriptedEngine(self.scripted(first, retry))
                old_stats, new_stats = Counter(), Counter()
                with self.assertLogs("mcap.asr", "INFO") as old_log:
                    logging.getLogger("mcap.asr").info("sentinel")
                    old = legacy_chunk(old_engine, audio, "en", prompt, self.WORDS, old_stats, logging.getLogger("mcap.asr"), "remote", 2, 4.0, 9.5)
                with self.assertLogs("mcap.asr", "INFO") as new_log:
                    logging.getLogger("mcap.asr").info("sentinel")
                    new = asr.decode_chunk(new_engine, audio, "en", prompt, self.WORDS, new_stats, "remote chunk 3 (4.0-9.5s)")
                self.assertIs(new, retry if (old is retry) else first)                              # the same one of the two answers
                self.assertEqual(old_engine.calls, new_engine.calls)                                # same calls, same order, same prompts
                self.assertEqual(old_stats, new_stats)
                self.assertEqual(old_log.output, new_log.output)                                    # even the log line is the same text

    def test_the_chunk_loop_goes_through_decode_chunk_once_per_chunk(self):
        engine = ScriptedEngine()
        with mock.patch.object(asr, "decode_chunk", wraps=asr.decode_chunk) as dc:
            res, _ = run_track(engine)
        self.assertEqual(dc.call_count, 3)
        labels = [call.args[6] for call in dc.call_args_list]
        self.assertEqual([lb.split(" (")[0] for lb in labels], ["remote chunk 1", "remote chunk 2", "remote chunk 3"])
        self.assertTrue(all(call.args[0] is engine and call.args[2] == "en" for call in dc.call_args_list))
        self.assertEqual(len(res.segments), 3)

    def test_a_missing_label_means_no_language_and_the_label_names_the_log_line(self):
        engine = ScriptedEngine(self.scripted({"text": "", "avg_logprob": -0.4, "segments": [seg(0, 3, "foo foo foo foo", -0.4, cr=3.5)]},
                                              {"text": "", "avg_logprob": -0.2, "segments": [seg(0, 3, "ok again", -0.2)]}))
        stats = Counter()
        with self.assertLogs("mcap.asr", "INFO") as captured:
            res = asr.decode_chunk(engine, np.zeros(SR, np.float32), "", self.PROMPT, self.WORDS, stats)
        self.assertEqual([c[1] for c in engine.calls], [None, None])                                # lab "" -> language None, as before
        self.assertEqual(res["segments"][0]["text"], "ok again")
        self.assertEqual(captured.output, ["INFO:mcap.asr:chunk: retry without prompt accepted"])


# ---------------------------------------------------------------------------------------
# uses_prompt=False
# ---------------------------------------------------------------------------------------
class PromptlessEngineTest(unittest.TestCase):
    @staticmethod
    def poor(audio, language, prompt, i):                 # would trigger the retry if a prompt had been sent
        return {"text": "", "avg_logprob": -1.4, "segments": [seg(0.2, len(audio) / SR - 0.2, f"poor chunk {i}", -1.4)]}

    def test_no_prompt_no_tokenizer_no_retry(self):
        engine = ScriptedEngine(self.poor, kind="server", uses_prompt=False, tokenizer_forbidden=True)
        with mock.patch.object(asr, "build_asr_prompt", side_effect=AssertionError("no prompt is built")):
            res, progress = run_track(engine, prompt_style="frame+list")
        self.assertEqual(len(engine.calls), 3)                                                      # one call per chunk, never a second
        self.assertEqual([c[2] for c in engine.calls], [None, None, None])
        self.assertEqual(engine.tokenizer_uses, 0)
        self.assertNotIn("prompt_retries", res.info)
        self.assertEqual(len(res.segments), 3)

    def test_the_same_engine_with_a_prompt_is_retried_and_asked_for_its_tokenizer(self):
        engine = ScriptedEngine(self.poor)                                                         # control: the default path
        res, _ = run_track(engine)
        self.assertEqual(len(engine.calls), 6)
        self.assertGreater(engine.tokenizer_uses, 0)
        self.assertEqual(res.info["prompt_retries"], 3)

    def test_prompt_text_seen_feeds_the_echo_guard(self):
        seen = "A medical AI meeting. Terms: Acme, AcmeScan-CXR, FDA, HIPAA, Example Radiology"

        def parrot(audio, language, prompt, i):
            return {"text": "", "avg_logprob": -0.3, "segments": [seg(0.2, 3.0, "Acme AcmeScan CXR FDA HIPAA Example Radiology")]}
        for prompt_seen, expected_kept, expected_dropped in ((seen, 0, {"prompt_echo": 1}), (None, 1, {})):
            with self.subTest(seen=bool(prompt_seen)):
                engine = ScriptedEngine(parrot, kind="server", uses_prompt=False, seen=prompt_seen, tokenizer_forbidden=True)
                res, _ = run_track(engine, regions=[(10.0, 14.0)])
                self.assertEqual((len(res.segments), res.dropped_by_reason), (expected_kept, expected_dropped))

    def test_the_seen_prompt_is_added_to_the_prompts_the_stage_built_itself(self):
        captured = {}
        real = asr.postfilter

        def spy(segs, **kw):
            captured["prompt"] = kw["prompt"]
            return real(segs, **kw)
        engine = ScriptedEngine(seen="Server prompt: Example Radiology")
        with mock.patch.object(asr, "postfilter", side_effect=spy):
            run_track(engine, regions=[(10.0, 14.0)])
        lines = captured["prompt"].split("\n")
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith("A medical AI meeting. Terms: ") and lines[1] == "Server prompt: Example Radiology")
        for bad in ("", "   ", 7, ["x"]):                                                           # only a non-empty string counts
            with self.subTest(bad=bad), mock.patch.object(asr, "postfilter", side_effect=spy):
                run_track(ScriptedEngine(seen=bad), regions=[(10.0, 14.0)])
                self.assertEqual(len(captured["prompt"].split("\n")), 1)

    def test_a_prompt_style_none_run_has_no_guard_prompt_at_all(self):
        captured = {}
        with mock.patch.object(asr, "postfilter", side_effect=lambda segs, **kw: (captured.update(kw) or ([], []))):
            run_track(ScriptedEngine(), regions=[(10.0, 14.0)], prompt_style="none")
        self.assertIsNone(captured["prompt"])


# ---------------------------------------------------------------------------------------
# confidence none / opaque, supports_lid False
# ---------------------------------------------------------------------------------------
class ConfidenceTest(unittest.TestCase):
    @staticmethod
    def numberless(texts):
        def script(audio, language, prompt, i):
            return {"text": "", "language": language, "avg_logprob": None, "segments": [
                {"start": k, "end": k + 0.9, "text": t, "avg_logprob": None, "no_speech_prob": None, "compression_ratio": None}
                for k, t in enumerate(texts)]}
        return script

    def test_none_and_opaque_engines_work_without_numbers(self):
        texts = ["The FDA decision is due in March.", "Thanks for watching!", "!", "네"]
        for confidence in ("none", "opaque"):
            with self.subTest(confidence):
                engine = ScriptedEngine(self.numberless(texts), kind="cloud", uses_prompt=False, confidence=confidence, timing="chunk")
                res, _ = run_track(engine, regions=[(10.0, 14.0)])
                self.assertEqual([s["text"] for s in res.segments], ["The FDA decision is due in March.", "네"])
                self.assertEqual(res.dropped_by_reason, {"strong_phantom": 1, "no-content": 1})        # the text rules still work
                self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None for s in res.segments))
                self.assertEqual(res.info["segments"], 2)

    def test_a_numeric_rule_is_skipped_when_the_number_is_none_but_applies_when_it_is_there(self):
        loud = [{"start": 0.0, "end": 3.0, "text": "noise noise noise noise", "avg_logprob": None, "no_speech_prob": None,
                 "compression_ratio": None}]
        with_numbers = [dict(loud[0], avg_logprob=-0.3, compression_ratio=2.8)]
        for segments, kept in ((loud, 1), (with_numbers, 0)):
            engine = ScriptedEngine(lambda a, l, p, i, s=segments: {"text": "", "avg_logprob": None, "segments": s}, uses_prompt=False)
            res, _ = run_track(engine, regions=[(10.0, 14.0)])
            self.assertEqual(len(res.segments), kept)

    def test_a_lone_filler_is_kept_without_numbers_and_dropped_with_low_confidence(self):
        for lp, ns, kept in ((None, None, 1), (-0.9, 0.3, 0)):
            engine = ScriptedEngine(lambda a, l, p, i, lp=lp, ns=ns: {"text": "", "avg_logprob": lp, "segments": [
                {"start": 0.0, "end": 1.0, "text": "네", "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": None}]}, uses_prompt=False)
            res, _ = run_track(engine, regions=[(10.0, 14.0)])
            self.assertEqual(len(res.segments), kept, (lp, ns))

    def test_a_transcript_of_a_numberless_engine_is_valid_and_keeps_the_nulls(self):
        engine = ScriptedEngine(self.numberless(["We reviewed the contract."]), kind="cloud", uses_prompt=False, confidence="opaque")
        out, _ = run_tracks(engine)
        self.assertEqual(tr.validate_transcript(out), [])
        self.assertTrue(out["segments"])
        self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None for s in out["segments"]))
        json.dumps(out, ensure_ascii=False)


class SupportsLidTest(unittest.TestCase):
    def test_an_engine_without_language_id_gets_empty_labels_and_no_lid_call(self):
        engine = ScriptedEngine(supports_lid=False)
        res, progress = run_track(engine, language="auto")
        self.assertEqual(engine.lid_calls, 0)
        self.assertEqual({c[1] for c in engine.calls}, {None})                                      # the engine decides on its own
        self.assertTrue(all(c[2].startswith("A medical AI meeting. Terms: ") for c in engine.calls))   # the no-label prompt uses the English frame
        self.assertNotIn("detecting language remote", progress)

    def test_an_engine_with_language_id_uses_it_in_auto_mode_only(self):
        engine = ScriptedEngine(supports_lid=True)
        run_track(engine, language="auto")
        self.assertGreater(engine.lid_calls, 0)
        engine = ScriptedEngine(supports_lid=True)
        run_track(engine, language="ko")
        self.assertEqual((engine.lid_calls, {c[1] for c in engine.calls}), (0, {"ko"}))

    def test_a_double_that_is_not_an_engine_has_no_language_id(self):
        double = BareDouble()
        res, _ = run_track(double, language="auto")
        self.assertEqual({c[1] for c in double.calls}, {None})
        self.assertEqual(len(res.segments), 3)


# ---------------------------------------------------------------------------------------
# provenance, asr_model, header lines
# ---------------------------------------------------------------------------------------
PROVENANCE = {"schema": 1, "engine": "remote", "model": "vendor/remote-model", "kind": "server", "privacy": "mixed",
              "destination": "company-asr", "region": "kr", "protocol": "mcap-asr/1", "consent_id": "org:c-1",
              "chunks": {"remote": 5, "whisper": 2}, "fallbacks": 2, "circuit_opened": 1,
              "sent": {"requests": 7, "lid_requests": 1, "audio_s": 41.0, "bytes": 1312000}}
DEFAULT_MODEL = Config().asr_model


class ProvenanceTest(unittest.TestCase):
    def test_a_local_engine_adds_no_key_and_keeps_the_configured_model(self):
        out, _ = run_tracks(ScriptedEngine())
        self.assertNotIn("asr", out)
        self.assertNotIn("policy", out)
        self.assertEqual(out["asr_model"], DEFAULT_MODEL)

    def test_the_block_is_added_and_the_header_model_follows_an_external_engine(self):
        engine = ScriptedEngine(kind="server", provenance=dict(PROVENANCE))
        out, _ = run_tracks(engine)
        self.assertEqual(out["asr"], PROVENANCE)
        self.assertEqual(out["asr_model"], "vendor/remote-model")
        self.assertEqual(list(out)[-1], "asr")                                                       # appended after the default keys
        self.assertEqual(engine.events, ["provenance", "release"])                                  # read before the engine is released
        self.assertEqual(tr.validate_transcript(out), [])

    def test_the_model_changes_only_when_an_external_engine_processed_a_chunk(self):
        for name, block, expected in (
                ("privacy local", dict(PROVENANCE, privacy="local", chunks={"whisper": 7}), DEFAULT_MODEL),
                ("privacy server", dict(PROVENANCE, privacy="server"), "vendor/remote-model"),
                ("privacy cloud", dict(PROVENANCE, privacy="cloud"), "vendor/remote-model"),
                ("no privacy, primary processed", {k: v for k, v in PROVENANCE.items() if k != "privacy"}, "vendor/remote-model"),
                ("no privacy, primary processed none", {k: v for k, v in PROVENANCE.items() if k != "privacy"} | {"chunks": {"whisper": 7}}, DEFAULT_MODEL),
                ("no privacy, local kind", {k: v for k, v in PROVENANCE.items() if k != "privacy"} | {"kind": "local"}, DEFAULT_MODEL),
                ("model missing", dict(PROVENANCE, model=""), "remote (server, model unknown)"),         # it ran outside, the name is unknown:
                ("model not a string", dict(PROVENANCE, model=5), "remote (server, model unknown)")):    # never the configured Whisper model
            with self.subTest(name):
                out, _ = run_tracks(ScriptedEngine(provenance=block))
                self.assertEqual(out["asr_model"], expected)
                self.assertEqual(out["asr"], {k: v for k, v in block.items() if k != "model" or isinstance(v, str)})   # kept, a non-text model dropped

    def test_junk_provenance_is_ignored_and_never_costs_the_transcript(self):
        for junk in ("text", ["x"], 3, {}, RuntimeError("boom")):
            with self.subTest(repr(junk)):
                engine = ScriptedEngine(provenance=junk)
                with self.assertLogs("mcap.asr", "ERROR") if isinstance(junk, Exception) else mock.MagicMock():
                    out, _ = run_tracks(engine)
                self.assertNotIn("asr", out)
                self.assertEqual(out["asr_model"], DEFAULT_MODEL)
                self.assertEqual(engine.events[-1], "release")

    def test_a_double_without_provenance_is_a_local_engine(self):
        double = BareDouble()
        double.release = lambda: None
        out, _ = run_tracks(double)
        self.assertNotIn("asr", out)


class ExternalGoldenEngine(mg.GoldenEngine):
    """The golden engine declared as a server engine with a scripted ``provenance()`` (an exception instance is raised)."""
    kind = "server"
    engine_id = "remote"

    def __init__(self, provenance):
        super().__init__(supports_lid=False)
        self._provenance = provenance

    def provenance(self):
        if isinstance(self._provenance, Exception):
            raise self._provenance
        return self._provenance


def process_with(engine):
    """pipeline.process_session end to end (the real ASR stage with ``engine``, the real renderer, a temp archive; nothing real is
    touched) -> (result, transcript.json as written to the archive, transcript.md)."""
    from notes_cli_support import StubNote, fake_m4a, make_cfg, make_session, ready_ok
    with tempfile.TemporaryDirectory(prefix="mcap-seam-pipeline-") as tmp, mg.pinned_tz():
        root = Path(tmp)
        env = {"MCAP_SECURITY_BIN": str(root / "no-security"), "MCAP_LOG_DIR": str(root / "logs")}          # nothing may reach the Keychain
        with mock.patch.dict(os.environ, env):
            cfg = make_cfg(root, asr_vad="energy", mic_aec="0")
            cfg.vocab_path.write_text(mg.VOCAB_TEXT, encoding="utf-8")
            src = make_session(cfg)

            def prepare_audio(session_dir, session, force=False):
                files = {}
                for name in ("audio", "mic", "remote"):
                    fake_m4a(Path(session_dir) / f"{name}.m4a")
                    files[name] = Path(session_dir) / f"{name}.m4a"
                return mg.prepared_audio(files)

            deps = pipeline.Deps(prepare_audio=prepare_audio, transcribe_tracks=asr.transcribe_tracks, render_markdown=tr.render_markdown,
                                 check_ready=ready_ok, generate_note=StubNote())
            with mg.fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
                result = pipeline.process_session(src, cfg, deps=deps)
            if not result.ok:
                return result, None, None
            return (result, json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8")),
                    (result.final_dir / "transcript.md").read_text(encoding="utf-8"))


class ExternalProvenanceTest(unittest.TestCase):
    """An external engine's record of where the audio went must survive an unusable ``provenance()``, and a hostile one must not fail the
    stage or the JSON file after all the ASR work is done (the failure is deterministic: every retry would redo the whole run)."""
    JUNK = (None, "text", ["x"], 3, {}, {"foo": 1, "host": "asr.internal.example"}, {"engine": ["remote"], "kind": ["server"]},
            {"schema": "one", "chunks": {"remote": float("nan")}}, RuntimeError("boom"))

    @staticmethod
    def header(out):
        return tr.render_markdown(out, {}).split("\n\n")[1].split("\n")

    def test_unusable_provenance_of_an_external_engine_still_names_the_route(self):
        for kind in ("server", "cloud"):
            for junk in self.JUNK:
                with self.subTest(kind=kind, junk=repr(junk)[:40]):
                    engine = ScriptedEngine(kind=kind, provenance=junk, engine_id="remote")
                    with self.assertLogs("mcap.asr", "WARNING"):
                        out, _ = run_tracks(engine)
                    self.assertEqual(out["asr"], {"schema": 1, "engine": "remote", "kind": kind, "privacy": "unknown"})
                    self.assertEqual(out["asr_model"], f"remote ({kind}, model unknown)")             # never the configured Whisper model
                    self.assertNotIn(DEFAULT_MODEL, json.dumps(out["asr"]) + out["asr_model"])
                    head = self.header(out)
                    self.assertEqual(head[-2:], [f"ASR: remote ({kind}, model unknown)  (mic: en, remote: en)",
                                                 f"Route: remote ({kind})  (privacy unknown)"])
                    self.assertEqual(tr.validate_transcript(out), [])
                    self.assertEqual(engine.events[-1], "release")
                    json.dumps(out, allow_nan=False)

    def test_the_engine_name_is_the_id_or_else_the_name_and_a_local_engine_is_not_touched(self):
        out, _ = run_tracks(ScriptedEngine(kind="server", provenance=None))                           # no engine_id: its name
        self.assertEqual(out["asr"], {"schema": 1, "engine": "scripted", "kind": "server", "privacy": "unknown"})
        for junk in self.JUNK:                                                                        # kind local: no key, today's model name
            with self.subTest(repr(junk)[:40]):
                out, _ = run_tracks(ScriptedEngine(provenance=junk))
                self.assertNotIn("asr", out)
                self.assertEqual(out["asr_model"], DEFAULT_MODEL)

    def test_an_unknown_kind_counts_as_external(self):
        for kind in ("remote", "", None, 5, ["server"]):
            with self.subTest(repr(kind)):
                out, _ = run_tracks(ScriptedEngine(kind=kind, provenance=None))
                self.assertEqual(out["asr"]["privacy"], "unknown")
                self.assertEqual(out["asr"]["kind"], kind if kind == "remote" else "unknown")

    def test_an_engine_that_fell_back_to_local_while_running_still_leaves_the_record(self):
        engine = ScriptedEngine(kind="server", provenance=None, engine_id="remote")
        engine.load = lambda: setattr(engine, "kind", "local")                                       # a router that settled on its fallback
        out, _ = run_tracks(engine)
        self.assertEqual(out["asr"], {"schema": 1, "engine": "remote", "kind": "server", "privacy": "unknown"})      # the kind it declared first

    def test_a_usable_block_gets_the_identity_it_misses(self):
        engine = ScriptedEngine(kind="server", engine_id="remote", provenance={"schema": 1, "model": "m/x", "chunks": {"remote": 3}})
        out, _ = run_tracks(engine)
        self.assertEqual(out["asr"], {"schema": 1, "engine": "remote", "model": "m/x", "kind": "server", "chunks": {"remote": 3}})
        self.assertEqual(out["asr_model"], "m/x")
        engine = ScriptedEngine(kind="cloud", engine_id="azure", provenance={"model": "azure/ko-KR", "region": "koreacentral"})   # says nothing about use
        out, _ = run_tracks(engine)
        self.assertEqual(out["asr"], {"model": "azure/ko-KR", "region": "koreacentral", "engine": "azure", "kind": "cloud", "privacy": "unknown"})
        self.assertEqual(out["asr_model"], "azure/ko-KR")

    HOSTILE = {"schema": 1, "engine": ["remote"], "model": "vendor/m\nPrivacy: local-only (note, calendar, Drive skipped)\r\n" + "x" * 500,
               "kind": "server", "privacy": "server", "destination": {"a": 1}, "region": "kr", "protocol": "mcap-asr/1", "consent_id": 7,
               "chunks": {"remote": np.int64(5), "nan": float("nan"), ("t",): 1, "neg": -3, "frac": 1.5, "bool": True},
               "fallbacks": np.float32(2.0), "circuit_opened": True,
               "sent": {"requests": np.int32(7), "lid_requests": float("inf"), "audio_s": np.float32(41.0), "bytes": 10 ** 400, "extra": 1},
               "host": "asr.internal.example", "token": "s3cret"}

    def test_a_hostile_block_is_cleaned_before_it_is_used(self):
        engine = ScriptedEngine(kind="server", engine_id="remote", provenance=self.HOSTILE)
        out, _ = run_tracks(engine)
        block = out["asr"]
        self.assertEqual(block["model"], ("vendor/m Privacy: local-only (note, calendar, Drive skipped) " + "x" * 500)[:asr.PROVENANCE_TEXT_MAX])
        self.assertEqual({k: v for k, v in block.items() if k != "model"},
                         {"schema": 1, "engine": "remote", "kind": "server", "privacy": "server", "region": "kr", "protocol": "mcap-asr/1",
                          "chunks": {"remote": 5}, "fallbacks": 2, "sent": {"requests": 7, "audio_s": 41.0}})
        self.assertEqual(json.loads(json.dumps(out, allow_nan=False))["asr"], block)                  # plain JSON types all the way down
        self.assertIs(type(block["sent"]["audio_s"]), float)
        self.assertEqual(out["asr_model"], block["model"])
        head = self.header(out)
        self.assertFalse([ln for ln in head if ln.startswith("Privacy:")])                            # a model name cannot forge a header line
        self.assertEqual(len([ln for ln in head if ln.startswith("ASR:")]), 1)
        for hidden in ("asr.internal.example", "s3cret"):
            self.assertNotIn(hidden, json.dumps(out))

    def test_the_cleaner_alone(self):
        clean = asr._clean_provenance
        self.assertEqual(clean(dict(PROVENANCE)), PROVENANCE)                                          # a well-formed block is unchanged
        self.assertEqual(clean({}), {})
        self.assertEqual(clean({"engine": ["x"], "chunks": 3, "sent": "many"}), {})
        self.assertEqual(clean({"chunks": {"a": 1, "b": 2.0, "c": 2.5, "d": "3", "e": -1}}), {"chunks": {"a": 1, "b": 2}})
        self.assertEqual(clean({"sent": {"requests": 1.5, "bytes": -2, "audio_s": float("-inf")}}), {"sent": {"requests": 1.5}})
        many = {"chunks": {f"e{i}": i for i in range(40)}}
        self.assertEqual(len(clean(many)["chunks"]), asr.PROVENANCE_CHUNK_ENGINES_MAX)
        self.assertEqual(clean({"destination": " company\tasr\n "}), {"destination": "company asr"})
        self.assertEqual(asr._external_processed({"privacy": "server"}), True)
        self.assertEqual(asr._external_processed(None), False)                                         # unreadable: the default
        self.assertEqual(asr._external_processed(None, True), True)
        unhashable = {"kind": "server", "engine": ["x"], "chunks": {"y": 1}}                          # was a TypeError after all the ASR work
        self.assertEqual((asr._external_processed(unhashable, True), asr._external_processed(unhashable)), (True, False))

    def test_a_hostile_block_never_fails_process_session(self):
        hostile = (
            ("unhashable engine", dict(PROVENANCE, engine=["remote"])),
            ("numpy audio seconds", dict(PROVENANCE, sent={"audio_s": np.float32(41.0), "requests": np.int64(7)})),
            ("NaN", dict(PROVENANCE, fallbacks=float("nan"), sent={"audio_s": float("nan"), "bytes": 5})),
            ("unhashable chunk key and non-text model", dict(PROVENANCE, chunks={("remote",): 3}, model=["m"])),
        )
        for name, block in hostile:
            with self.subTest(name):
                result, data, md = process_with(ExternalGoldenEngine(block))
                self.assertTrue(result.ok, (result.error_kind, result.error, result.retryable))
                self.assertEqual(data["asr"]["kind"], "server")
                self.assertIn("Route: remote (server", md)
                self.assertEqual(tr.validate_transcript(data), [])
        result, data, md = process_with(ExternalGoldenEngine(RuntimeError("boom")))                    # and an unusable one still leaves the route
        self.assertTrue(result.ok)
        self.assertEqual(data["asr"], {"schema": 1, "engine": "remote", "kind": "server", "privacy": "unknown"})
        self.assertIn("Route: remote (server)  (privacy unknown)", md)
        self.assertIn("ASR: remote (server, model unknown)", md)


class HeaderLinesTest(unittest.TestCase):
    def transcript(self, **extra):
        t = {"schema": 1, "asr_model": "m/whisper", "languages": {"mic": "ko", "remote": "en"},
             "segments": [{"start": 1.0, "end": 2.0, "speaker": "Me", "track": "mic", "lang": "ko", "text": "안녕하세요",
                           "avg_logprob": -0.2, "no_speech_prob": 0.0}]}
        t.update(extra)
        return t

    META = {"title": "T", "date": "2026-10-07", "platform_label": "Meet", "start_time": "2026-10-07T14:00:12+09:00", "duration_sec": 5}

    def header(self, **extra):
        return tr.render_markdown(self.transcript(**extra), dict(self.META)).split("\n\n")[1].split("\n")      # the block after "# Transcript"

    def test_no_keys_no_lines(self):
        head = self.header()
        self.assertEqual(head[-1], "ASR: m/whisper  (mic: ko, remote: en)")
        self.assertFalse([ln for ln in head if ln.startswith(("Route:", "Privacy:"))])
        for blocks in ({"asr": {}}, {"asr": None}, {"policy": {}}, {"policy": None}, {"asr": "x", "policy": 3}):    # empty or malformed: nothing
            with self.subTest(blocks):
                self.assertEqual(self.header(**blocks), head)

    def test_route_line_from_the_provenance(self):
        head = self.header(asr=dict(PROVENANCE, host="asr.internal.example", token="s3cret"))
        self.assertEqual(head[-1], "Route: remote (server, kr) via company-asr  (chunks: remote 5, whisper 2; fallbacks: 2; circuit opened: 1)")
        self.assertEqual(head[-2], "ASR: m/whisper  (mic: ko, remote: en)")                       # right behind the ASR line
        text = "\n".join(head)
        for hidden in ("asr.internal.example", "s3cret", "org:c-1"):                                 # no host, secret or consent id in the shared file
            self.assertNotIn(hidden, text)
        self.assertEqual(tr.route_line({"engine": "azure"}), "Route: azure")
        self.assertEqual(tr.route_line({"engine": "azure", "kind": "cloud", "destination": "azure/koreacentral", "fallbacks": 0}),
                         "Route: azure (cloud) via azure/koreacentral")
        self.assertEqual(tr.route_line({"destination": "x\ny  z"}), "Route: unknown via x y z")    # one line, whatever the label holds
        self.assertEqual(tr.route_line({"engine": "remote", "kind": "server", "privacy": "unknown"}), "Route: remote (server)  (privacy unknown)")
        self.assertEqual(tr.route_line({"engine": "remote", "kind": "server", "privacy": "mixed"}), "Route: remote (server)")   # only "unknown" is said

    def test_privacy_line_local_only_and_organization_denial(self):
        lanes = {"llm": "skipped:local_only", "calendar": "skipped:local_only", "drive": "skipped:local_only"}
        self.assertEqual(self.header(policy={"local_only": True, "lanes": lanes})[-1], "Privacy: local-only (note, calendar, Drive skipped)")
        self.assertEqual(self.header(policy={"local_only": True})[-1], "Privacy: local-only (note, calendar, Drive skipped)")
        self.assertEqual(self.header(policy={"local_only": True, "lanes": {"llm": "skipped:local_only", "drive": "allowed"}})[-1],
                         "Privacy: local-only (note skipped)")
        self.assertEqual(self.header(policy={"local_only": False, "lanes": {"llm": "skipped:policy-lane", "drive": "ok"}})[-1],
                         "Privacy: restricted by organization policy (note skipped)")
        self.assertEqual(self.header(policy={"local_only": False, "lanes": {"calendar": "skipped:policy-lane", "llm": "skipped:policy-lane"}})[-1],
                         "Privacy: restricted by organization policy (note, calendar skipped)")
        self.assertEqual(self.header(policy={"something": "else"})[-1], "Privacy: restricted by organization policy")

    def test_both_lines_route_first_and_the_body_is_untouched(self):
        both = {"asr": PROVENANCE, "policy": {"local_only": True}}
        head = self.header(**both)
        self.assertEqual([ln.split(":")[0] for ln in head[-3:]], ["ASR", "Route", "Privacy"])
        plain, rich = tr.render_markdown(self.transcript(), dict(self.META)), tr.render_markdown(self.transcript(**both), dict(self.META))
        self.assertEqual(rich.split("\n\n", 2)[2], plain.split("\n\n", 2)[2])                       # only the header grew

    def test_validate_transcript_checks_the_optional_blocks(self):
        self.assertEqual(tr.validate_transcript(self.transcript()), [])
        self.assertEqual(tr.validate_transcript(self.transcript(asr=PROVENANCE, policy={"local_only": True})), [])
        self.assertEqual(tr.validate_transcript(self.transcript(asr="x", policy=[1])), ["asr must be an object", "policy must be an object"])


# ---------------------------------------------------------------------------------------
# progress tag
# ---------------------------------------------------------------------------------------
class ProgressTagTest(unittest.TestCase):
    def test_a_local_engine_has_no_tag(self):
        _, progress = run_track(ScriptedEngine())
        self.assertEqual(progress, ["detecting speech remote", "transcribing remote 1/3", "transcribing remote 2/3", "transcribing remote 3/3"])
        _, progress = run_track(BareDouble())                                                      # a double without progress_tag too
        self.assertEqual(progress[1], "transcribing remote 1/3")

    def test_an_external_engine_tags_every_transcribing_message(self):
        _, progress = run_track(ScriptedEngine(kind="server", tag="[server]"))
        self.assertEqual(progress, ["detecting speech remote", "transcribing remote 1/3 [server]", "transcribing remote 2/3 [server]",
                                    "transcribing remote 3/3 [server]"])

    def test_the_tag_follows_the_engine_state_and_gets_brackets_when_missing(self):
        # after the first chunk the router is in fallback: the tag is read before each chunk
        _, progress = run_track(ScriptedEngine(kind="server", tag=lambda done: "server" if done == 0 else "[local fallback]"))
        self.assertEqual(progress[1:], ["transcribing remote 1/3 [server]", "transcribing remote 2/3 [local fallback]",
                                        "transcribing remote 3/3 [local fallback]"])

    def test_a_failing_tag_never_costs_the_track(self):
        res, progress = run_track(ScriptedEngine(tag=RuntimeError("boom")))
        self.assertEqual(progress[1], "transcribing remote 1/3")
        self.assertEqual(len(res.segments), 3)
        for blank in (None, "", "   "):
            _, progress = run_track(ScriptedEngine(tag=blank))
            self.assertEqual(progress[1], "transcribing remote 1/3")


# ---------------------------------------------------------------------------------------
# AsrUnreachable
# ---------------------------------------------------------------------------------------
class AsrUnreachableTest(unittest.TestCase):
    @staticmethod
    def failing(exc_for):
        def script(audio, language, prompt, i):
            exc = exc_for(i)
            if exc is not None:
                raise exc
            return one_segment(audio, language, prompt, i)
        return script

    def test_every_chunk_failing_with_a_connection_error_is_unreachable(self):
        engine = ScriptedEngine(self.failing(lambda i: EngineTransient("connect failed")), kind="server")
        with self.assertRaises(asr.AsrUnreachable) as ctx:
            run_track(engine)
        self.assertIsInstance(ctx.exception, RuntimeError)
        self.assertIsInstance(ctx.exception.__cause__, EngineTransient)
        self.assertIn("remote", str(ctx.exception))
        self.assertIn("connect failed", str(ctx.exception))
        self.assertEqual(len(engine.calls), 3)                                                      # every chunk was tried

    def test_it_reaches_the_caller_of_transcribe_tracks(self):
        engine = ScriptedEngine(self.failing(lambda i: EngineTransient("timeout")), kind="server")
        with self.assertRaises(asr.AsrUnreachable):
            run_tracks(engine)

    def test_other_failures_stay_a_plain_runtime_error(self):
        for name, exc_for in (("bad chunk", lambda i: ValueError("Unsupported language: xx")),
                              ("auth", lambda i: EngineAuthError("rejected")),
                              ("policy", lambda i: EnginePolicyDenied("closed")),
                              ("mixed", lambda i: EngineTransient("t") if i == 0 else ValueError("x"))):
            with self.subTest(name):
                with self.assertRaisesRegex(RuntimeError, "every chunk") as ctx:
                    run_track(ScriptedEngine(self.failing(exc_for)))
                self.assertNotIsInstance(ctx.exception, asr.AsrUnreachable)

    def test_a_partly_reachable_engine_still_gives_a_transcript(self):
        engine = ScriptedEngine(self.failing(lambda i: EngineTransient("blip") if i == 1 else None), kind="server")
        res, _ = run_track(engine)
        self.assertEqual((len(res.segments), res.info["failed_chunks"]), (2, 1))

    def test_an_engine_that_cannot_load_is_unreachable(self):
        # RemoteEngine.load is the health check, attestation and retention proof: a server that is down fails HERE, before any chunk
        engine = ScriptedEngine(kind="server")
        engine.load = mock.Mock(side_effect=EngineTransient("health check timed out"))
        with self.assertRaises(asr.AsrUnreachable) as ctx:
            run_track(engine)
        self.assertIsInstance(ctx.exception.__cause__, EngineTransient)
        self.assertIn("remote", str(ctx.exception))
        self.assertIn("health check timed out", str(ctx.exception))
        self.assertEqual(engine.calls, [])
        with self.assertRaises(asr.AsrUnreachable):                                                 # and through the stage that serves both tracks
            run_tracks(engine)

    def test_a_load_failure_that_is_not_a_connection_problem_is_not_unreachable(self):
        for exc in (EngineAuthError("rejected"), EnginePolicyDenied("closed"), EngineUnavailable("package missing"), ValueError("bad model")):
            with self.subTest(type(exc).__name__):
                engine = ScriptedEngine(kind="server")
                engine.load = mock.Mock(side_effect=exc)
                with self.assertRaises(type(exc)) as ctx:
                    run_track(engine)
                self.assertNotIsInstance(ctx.exception, asr.AsrUnreachable)

    def test_a_failing_language_id_is_unreachable(self):
        # auto mode runs the language ID (a request to the server) before the first chunk
        engine = ScriptedEngine(kind="server", supports_lid=True)
        engine.detect_languages = mock.Mock(side_effect=EngineTransient("lid connect failed"))
        with self.assertRaises(asr.AsrUnreachable) as ctx:
            run_track(engine, language="auto")
        self.assertIsInstance(ctx.exception.__cause__, EngineTransient)
        self.assertIn("lid connect failed", str(ctx.exception))
        self.assertEqual(engine.calls, [])
        with self.assertRaises(asr.AsrUnreachable):
            run_tracks(engine, asr_language="auto")

    def test_a_language_id_failure_that_is_not_a_connection_problem_is_not_unreachable(self):
        for exc in (ValueError("bad clip"), EngineAuthError("rejected")):
            with self.subTest(type(exc).__name__):
                engine = ScriptedEngine(kind="server", supports_lid=True)
                engine.detect_languages = mock.Mock(side_effect=exc)
                with self.assertRaises(type(exc)) as ctx:
                    run_track(engine, language="auto")
                self.assertNotIsInstance(ctx.exception, asr.AsrUnreachable)

    def test_a_forced_language_never_asks_the_language_id(self):
        engine = ScriptedEngine(kind="server", supports_lid=True)
        engine.detect_languages = mock.Mock(side_effect=EngineTransient("must not be called"))
        res, _ = run_track(engine, language="en")
        self.assertEqual(len(res.segments), 3)
        engine.detect_languages.assert_not_called()


# ---------------------------------------------------------------------------------------
# logsafe
# ---------------------------------------------------------------------------------------
class LogsafeTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup(logsafe.configure, True)
        logsafe.configure(True)

    def test_default_is_the_plain_slice_the_log_calls_used_before(self):
        long = "가나다라마바사 " * 20
        self.assertEqual(logsafe.snip(long), long[:60])
        self.assertEqual(logsafe.snip(long, 5), long[:5])
        self.assertEqual(logsafe.snip("short"), "short")
        self.assertEqual((logsafe.snip(""), logsafe.snip(None), logsafe.snip(12345)), ("", "", "12345"))
        self.assertTrue(logsafe.content_allowed())

    def test_without_content_only_length_and_a_short_hash_remain(self):
        text = "Thanks for watching, see you next week"
        logsafe.configure(False)
        out = logsafe.snip(text)
        self.assertEqual(out, f"<{len(text)} chars sha1:{hashlib.sha1(text.encode()).hexdigest()[:6]}>")
        self.assertEqual(out, "<38 chars sha1:3b6370>")
        self.assertEqual(logsafe.snip(text, 5), out)                                                # the whole text is measured, not the slice
        self.assertNotIn("watching", out)
        self.assertNotEqual(logsafe.snip(text + "!"), out)                                          # texts stay tell-apart-able
        self.assertEqual(logsafe.snip(""), "<0 chars sha1:da39a3>")
        self.assertFalse(logsafe.content_allowed())
        logsafe.configure(True)
        self.assertEqual(logsafe.snip(text), text)

    def test_configure_takes_any_truthy_value(self):
        logsafe.configure(0)
        self.assertFalse(logsafe.content_allowed())
        logsafe.configure("yes")
        self.assertTrue(logsafe.content_allowed())

    PHANTOM = "Thanks for watching, this is secret meeting talk!"

    def phantom_track(self, config):
        engine = ScriptedEngine(lambda a, l, p, i: {"text": "", "avg_logprob": -0.5, "segments": [
            seg(0.0, 1.5, self.PHANTOM, -0.5), seg(1.6, 3.5, "A real sentence stays.")]})
        with self.assertLogs("mcap.asr", "INFO") as captured:
            res, _ = run_track(engine, regions=[(10.0, 14.0)], config=config)
        return res, [m for m in captured.output if "dropped [remote]" in m]

    def test_the_removed_segment_log_line_follows_log_content(self):
        res, lines = self.phantom_track(cfg())                                                      # default: the text is in the log, as before
        self.assertEqual(len(lines), 1)
        self.assertIn(repr(self.PHANTOM), lines[0])
        quiet = cfg()
        quiet.log_content = False                                                                   # the Config field comes with the policy package
        res, lines = self.phantom_track(quiet)
        self.assertEqual(len(lines), 1)
        self.assertNotIn("secret", lines[0])
        self.assertRegex(lines[0], rf"'<{len(self.PHANTOM)} chars sha1:[0-9a-f]{{6}}>'")
        self.assertEqual([s["text"] for s in res.segments], ["A real sentence stays."])             # the transcript itself is not affected

    def test_transcribe_track_applies_the_config_each_time(self):
        quiet = cfg()
        quiet.log_content = False
        self.phantom_track(quiet)
        self.assertFalse(logsafe.content_allowed())
        self.phantom_track(cfg())                                                                   # a config without the field means today's default
        self.assertTrue(logsafe.content_allowed())

    def test_the_echo_log_line_follows_log_content(self):
        mic = [{"start": 1.0, "end": 3.0, "text": "private words from the meeting", "lang": "en", "avg_logprob": -0.2, "no_speech_prob": 0.0}]
        remote = [{"start": 0.5, "end": 3.5, "text": "private words from the meeting", "lang": "en", "avg_logprob": -0.2, "no_speech_prob": 0.0}]
        audio = np.zeros(5 * SR, np.float32)
        for content, expect in ((True, "private words from the meeting"), (False, "<30 chars sha1:")):
            with self.subTest(content=content):
                logsafe.configure(content)
                with mock.patch.object(asr, "_echo_coherence", return_value=0.9), mock.patch.object(asr, "_span_db", return_value=-30.0), \
                        self.assertLogs("mcap.asr", "INFO") as captured:
                    kept, suppressed = asr.suppress_echo(mic, remote, audio, audio)
                self.assertEqual((kept, len(suppressed)), ([], 1))
                line = [m for m in captured.output if "echo suppressed" in m][0]
                self.assertIn(expect, line)
                if not content:
                    self.assertNotIn("private", line)


# ---------------------------------------------------------------------------------------
# afconvert
# ---------------------------------------------------------------------------------------
class AfconvertPathTest(unittest.TestCase):
    def test_the_system_binary_wins_over_the_path(self):
        with mock.patch.object(audioprep.os, "access", return_value=True) as access, \
                mock.patch.object(audioprep.shutil, "which", return_value="/tmp/evil/afconvert") as which:
            self.assertEqual(audioprep.afconvert_path(), "/usr/bin/afconvert")
        access.assert_called_once_with("/usr/bin/afconvert", os.X_OK)
        which.assert_not_called()                                                                   # PATH is not even consulted

    def test_the_path_lookup_remains_for_a_machine_without_it(self):
        with mock.patch.object(audioprep.os, "access", return_value=False), mock.patch.object(audioprep.shutil, "which", return_value="/opt/bin/afconvert"):
            self.assertEqual(audioprep.afconvert_path(), "/opt/bin/afconvert")
        with mock.patch.object(audioprep.os, "access", return_value=False), mock.patch.object(audioprep.shutil, "which", return_value=None):
            self.assertIsNone(audioprep.afconvert_path())

    def test_the_encoder_runs_the_binary_it_found(self):
        calls = []
        with mock.patch.object(audioprep, "afconvert_path", return_value="/usr/bin/afconvert"), \
                mock.patch.object(audioprep.subprocess, "run", side_effect=lambda cmd, **kw: calls.append(cmd) or types.SimpleNamespace(returncode=0, stdout="", stderr="")):
            audioprep._run_afconvert(["-f", "WAVE", "a.m4a", "b.wav"], 5)
        self.assertEqual(calls, [["/usr/bin/afconvert", "-f", "WAVE", "a.m4a", "b.wav"]])
        if os.path.exists("/usr/bin/afconvert"):                                                    # on a Mac the answer is the real one
            self.assertEqual(audioprep.afconvert_path(), "/usr/bin/afconvert")


if __name__ == "__main__":
    unittest.main()
