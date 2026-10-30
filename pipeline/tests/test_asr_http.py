"""asr_http.py (docs/ASR_PROTOCOL.md 5.1, 6, 7): the shared half of the
external engines. Everything runs through a REAL EgressGuard in front of an in-process FakeTransport: the host, port, header and size rules
are the real ones, no socket opens (NoNetworkCase), the Keychain is the fake `security` of notes_cli_support, time is a FakeClock.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import io
import json
import logging
import math
import unittest
import wave
from types import SimpleNamespace
from unittest import mock

import numpy as np

from asr_support import (AZURE_HOST, AZURE_KEY, BUILD_SHA, CANARY_FRAGMENTS, CANARY_TEXT, CA_SHA, HOST, TOKEN, AsrCase, FakeTransport, MiniCloudEngine,
                         MiniRemoteEngine, audio, chunk_answer, error_answer, health_document, json_response, make_decision)

from mcap import asr, asr_http, asr_usage, apikey
from mcap import usage as claude_usage
from mcap.asr_engines import EngineAuthError, EngineCapReached, EngineError, EnginePolicyDenied, EngineTransient
from mcap.asr_http import EngineHttpError, clean_result, fetch_health, health_problems, parse_health, pcm16, wav16
from mcap.egress import EgressGuard, Response
from mcap.policy import HostRule


class Records(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage() + (self.format(record) if record.exc_info else ""))


class HttpCase(AsrCase):
    """An engine over a real guard. ``rand`` is 0.5: no jitter, so the waits are exactly the schedule."""

    def setUp(self):
        super().setUp()
        self.decision = make_decision(self.cfg, "remote")
        self.rule = self.decision.hosts[HOST]
        self.records = Records()
        logging.getLogger("mcap").addHandler(self.records)
        self.addCleanup(logging.getLogger("mcap").removeHandler, self.records)

    def guard(self, rule=None, *, pre_connect="gate", trust="private"):
        rule = rule or self.rule
        return EgressGuard({rule.host: rule}, engine_id="remote", consent_id="c-remote", transport=self.transport, clock=self.clock,
                           pre_connect=self.gate if pre_connect == "gate" else pre_connect, trust=trust)

    def engine(self, cls=MiniRemoteEngine, *, decision=None, gate="gate", guard=None, rand=lambda: 0.5, **kw):
        return cls(self.cfg, None, decision or self.decision, guard or self.guard(), gate=self.gate if gate == "gate" else gate,
                   sleep=self.sleep, rand=rand, clock=self.clock, **kw)

    def usage_lines(self):
        path = self.cfg.asr_usage_path
        return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    def chunk(self, engine, seconds=2.0):
        return engine.transcribe_chunk(audio(seconds), "en", None)

    def everything_written(self):
        """Text of every file under the temp root (the SUPPORT_DIR, the usage file ...) plus every log line."""
        parts = [p.read_bytes().decode("utf-8", "replace") for p in sorted(self.root.rglob("*")) if p.is_file()]
        return "\n".join(parts + self.records.lines)

    def assertNothingLeaked(self, *extra):
        text = self.everything_written()
        for needle in CANARY_FRAGMENTS + (TOKEN,) + tuple(extra):
            self.assertNotIn(needle, text)


# ======================================================================================================================
class AudioTests(unittest.TestCase):
    def test_pcm16_values(self):
        x = np.array([0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -3.0, np.nan, np.inf], dtype=np.float32)
        got = np.frombuffer(pcm16(x), dtype="<i2")
        self.assertEqual(list(got), [0, 16384, -16384, 32767, -32768, 32767, -32768, 0, 32767])

    def test_round_trip_is_within_one_step(self):
        rng = np.random.default_rng(7)
        x = np.clip(rng.normal(0, 0.3, 16000), -1, 1).astype(np.float32)
        back = np.frombuffer(pcm16(x), dtype="<i2").astype(np.float32) / 32768.0
        self.assertEqual(len(back), len(x))
        self.assertLessEqual(float(np.max(np.abs(back - x))), 1.0 / 32768.0 + 1e-6)

    def test_pcm16_of_int16_is_the_same_samples(self):
        x = np.array([-5, 0, 7, 32767], dtype=np.int16)
        self.assertEqual(pcm16(x), x.astype("<i2").tobytes())

    def test_pcm16_wants_mono(self):
        with self.assertRaises(ValueError):
            pcm16(np.zeros((2, 10), dtype=np.float32))

    def test_wav16_is_a_valid_16_bit_mono_wav(self):
        x = (np.sin(np.linspace(0, 40, 8000)) * 0.4).astype(np.float32)
        data = wav16(x)
        self.assertEqual(len(data), 44 + 2 * len(x))
        self.assertEqual(data[:4], b"RIFF")
        self.assertEqual(data[8:16], b"WAVEfmt ")
        with wave.open(io.BytesIO(data)) as w:
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (1, 2, 16000, len(x)))
            self.assertEqual(w.readframes(len(x)), pcm16(x))

    def test_wav16_other_rate_and_empty_audio(self):
        with wave.open(io.BytesIO(wav16(np.zeros(0, np.float32), 8000))) as w:
            self.assertEqual((w.getframerate(), w.getnframes()), (8000, 0))
        for rate in (0, 999, 10 ** 6):
            with self.assertRaises(ValueError):
                wav16(np.zeros(4, np.float32), rate)


class HelperTests(unittest.TestCase):
    def test_path_label_has_no_query_and_no_digest(self):
        self.assertEqual(asr_http.path_label("/v1/chunk"), "/v1/chunk")
        self.assertEqual(asr_http.path_label("/speechtotext/transcriptions:transcribe?api-version=2025-10-15&x=secret"),
                         "/speechtotext/transcriptions:transcribe")
        self.assertEqual(asr_http.path_label("/v1/vocab/" + "ab12" * 16), "/v1/vocab/{id}")
        self.assertEqual(asr_http.path_label(""), "-")
        self.assertLessEqual(len(asr_http.path_label("/" + "a" * 200)), 40)

    def test_error_info_takes_a_word_and_a_number_never_the_message(self):
        body = json.dumps({"error": {"code": "busy", "message": CANARY_TEXT, "retry_after_s": 3}}).encode()
        self.assertEqual(asr_http.error_info(body), ("busy", 3.0))
        for bad in (b"", b"not json", b"[]", b'{"error": 5}', b'{"error": {"code": "Has Space"}}', b'{"error": {"code": 7}}',
                    b'{"error": {"code": "ok", "retry_after_s": -1}}', b'{"error": {"code": "ok", "retry_after_s": "soon"}}'):
            code, wait = asr_http.error_info(bad)
            self.assertTrue(code in (None, "ok"))
            self.assertIsNone(wait)
        self.assertEqual(asr_http.error_info(None), (None, None))

    def test_retry_after_seconds(self):
        f = asr_http.retry_after_seconds
        self.assertEqual(f({"retry-after": "7"}), 7.0)
        self.assertEqual(f({"retry-after": " 2.5 "}), 2.5)
        self.assertEqual(f({"retry-after": "-4"}), 0.0)
        self.assertEqual(f({"retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"}, 9.0), 9.0)
        self.assertEqual(f({"retry-after": "nan"}, 1.0), 1.0)
        self.assertEqual(f({"retry-after": "inf"}), None)
        self.assertEqual(f({}, 3.0), 3.0)
        self.assertIsNone(f({}))
        self.assertIsNone(f(None))


class CleanResultTests(unittest.TestCase):
    def good(self, **kw):
        base = {"text": "hello", "segments": [{"start": 0.0, "end": 1.5, "text": "hello", "avg_logprob": -0.3, "no_speech_prob": 0.01,
                                              "compression_ratio": 1.1, "temperature": 0.0}], "language": "en", "avg_logprob": -0.3}
        base.update(kw)
        return base

    def test_a_good_answer_passes_unchanged_in_substance(self):
        out = clean_result(self.good(), 4.0)
        self.assertEqual(out["segments"][0], {"start": 0.0, "end": 1.5, "text": "hello", "avg_logprob": -0.3, "no_speech_prob": 0.01,
                                              "compression_ratio": 1.1, "temperature": 0.0})
        self.assertEqual((out["text"], out["language"], out["avg_logprob"], out["truncated"]), ("hello", "en", -0.3, False))

    def test_opaque_numbers_stay_none(self):
        seg = {"start": 0, "end": 2, "text": "x", "avg_logprob": None, "no_speech_prob": None, "compression_ratio": None}
        out = clean_result({"segments": [seg]}, 2.0)
        self.assertEqual([out["segments"][0][k] for k in ("avg_logprob", "no_speech_prob", "compression_ratio")], [None, None, None])
        self.assertEqual(out["text"], "x")

    def test_a_server_cannot_crash_the_chunk_loop(self):
        segs = [{"start": "0", "end": 1, "text": "string time"}, {"start": 0, "end": float("nan"), "text": "nan"},
                {"start": -1, "end": 1, "text": "negative start"}, {"start": 0, "end": 1, "text": 5}, "not a dict", None,
                {"start": 0, "end": 1}, {"start": True, "end": 1, "text": "bool"}, {"start": 0.5, "end": 0.2, "text": "end before start"},
                {"start": 0, "end": 99999, "text": "far end"}, {"start": 9999, "end": 99999, "text": "far start"}]
        out = clean_result({"segments": segs}, 3.0)
        got = {s["text"]: (s["start"], s["end"]) for s in out["segments"]}
        self.assertEqual(sorted(got), ["end before start", "far end", "far start", "negative start"])
        self.assertNotIn("string time", got)
        self.assertNotIn("nan", got)
        self.assertNotIn("bool", got)
        self.assertEqual(got["negative start"], (0.0, 1.0))
        self.assertEqual(got["end before start"], (0.5, 0.5))
        self.assertEqual(got["far end"], (0.0, 4.0))                # clamped to chunk + 1 s
        self.assertEqual(got["far start"], (4.0, 4.0))
        for s in out["segments"]:
            self.assertTrue(isinstance(s["text"], str) and math.isfinite(s["start"]) and math.isfinite(s["end"]) and s["start"] <= s["end"])

    def test_sizes_are_bounded(self):
        many = [{"start": 0, "end": 1, "text": "t"}] * 1000
        self.assertEqual(len(clean_result({"segments": many}, 3.0)["segments"]), asr_http.MAX_SEGMENTS)
        huge = clean_result({"segments": [{"start": 0, "end": 1, "text": "x" * 10 ** 6}], "text": "y" * 10 ** 6, "language": "z" * 100}, 3.0)
        self.assertLessEqual(len(huge["segments"][0]["text"]), asr_http.MAX_SEGMENT_CHARS)
        self.assertLessEqual(len(huge["text"]), asr_http.MAX_SEGMENT_CHARS * 4)
        self.assertLessEqual(len(huge["language"]), 16)

    def test_an_answer_that_is_not_one_is_a_transient_failure(self):
        for bad in (None, [], "text", {"text": "no segments"}, {"segments": "nope"}, {"segments": {"a": 1}}):
            with self.assertRaises(EngineTransient):
                clean_result(bad, 2.0)

    def test_the_prompt_text_is_passed_on_for_the_echo_guard(self):
        self.assertEqual(clean_result(self.good(prompt_text="Terms: A, B"), 2.0)["prompt_text"], "Terms: A, B")
        self.assertNotIn("prompt_text", clean_result(self.good(prompt_text="  "), 2.0))
        self.assertNotIn("prompt_text", clean_result(self.good(prompt_text=7), 2.0))

    def test_text_is_rebuilt_from_the_segments_when_the_answer_has_none(self):
        out = clean_result({"segments": [{"start": 0, "end": 1, "text": "a"}, {"start": 1, "end": 2, "text": "b"}]}, 3.0)
        self.assertEqual(out["text"], "a b")


# ======================================================================================================================
class RequestTests(HttpCase):
    def test_a_chunk_is_one_post_with_the_audio_the_credential_and_the_protocol_headers(self):
        engine = self.engine()
        result = self.chunk(engine, 2.0)
        self.assertEqual(len(self.transport.calls), 1)
        call = self.transport.calls[0]
        self.assertEqual((call.method, call.target, call.rule.host, call.rule.port), ("POST", "/v1/chunk", HOST, 443))
        self.assertEqual(call.header("Authorization"), f"Bearer {TOKEN}")
        self.assertEqual((call.header("X-MCAP-Proto"), call.header("X-MCAP-Samples"), call.header("X-MCAP-Lang")), ("mcap-asr/1", "32000", "en"))
        self.assertEqual(len(call.body), 64000)
        self.assertEqual(call.timeout, 90.0)
        self.assertEqual(result["segments"][0]["text"], "hello world")
        self.assertEqual(result["language"], "en")

    def test_the_prompt_is_never_sent(self):
        engine = self.engine()
        engine.transcribe_chunk(audio(1.0), "ko", "Terms: Acme, AcmeScan-CXR")
        call = self.transport.calls[0]
        self.assertNotIn(b"Acme", call.body)
        self.assertNotIn("Acme", json.dumps(call.headers))

    def test_the_engine_declares_what_policy_says_it_is(self):
        engine = self.engine()
        self.assertEqual((engine.kind, engine.residency, engine.uses_prompt, engine.progress_tag()), ("server", "kr", False, "[server]"))
        cloud = self.engine(MiniCloudEngine, decision=make_decision(self.cfg, "azure", consents=("azure",)))
        self.assertEqual((cloud.kind, cloud.residency, cloud.uses_prompt, cloud.progress_tag()), ("cloud", "kr", False, "[cloud]"))

    def test_the_request_timeout_is_the_setting_and_can_be_overridden(self):
        self.cfg.asr_request_timeout_s = 33
        engine = self.engine()
        self.chunk(engine)
        engine.exchange("x", "POST", "/v1/chunk", {}, b"zz", timeout=7)
        self.assertEqual([c.timeout for c in self.transport.calls], [33.0, 7.0])

    def test_an_engine_without_a_destination_sends_nothing(self):
        bare = make_decision(self.cfg, "whisper")
        engine = self.engine(decision=bare)
        with self.assertRaises(EnginePolicyDenied):
            engine.load()
        with self.assertRaises(EnginePolicyDenied):
            self.chunk(engine)
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.security.reads(), 0)

    def test_a_hostile_answer_cannot_crash_the_chunk(self):
        self.transport.default = json_response(200, {"segments": [{"start": "x", "end": [], "text": CANARY_TEXT}, 5, {"start": 0, "end": 1, "text": "ok"}]})
        result = self.chunk(self.engine())
        self.assertEqual([s["text"] for s in result["segments"]], ["ok"])

    def test_an_answer_that_is_not_json_is_transient_not_a_crash(self):
        self.transport.default = json_response(200, raw=b"<html>captive portal " + CANARY_TEXT.encode() + b"</html>")
        with self.assertRaises(EngineTransient) as cm:                  # the adapter's json.loads raises ValueError: made transient, its text not shown
            self.chunk(self.engine())
        self.assertEqual(str(cm.exception), "the engine answer could not be read")
        self.assertIsNone(cm.exception.__cause__)
        self.assertNothingLeaked()

    def test_the_prompt_the_server_used_is_kept_for_the_echo_guard(self):
        engine = self.engine()
        self.assertIsNone(engine.prompt_text_seen())
        self.transport.default = json_response(200, chunk_answer("a", prompt_text="KO frame. Terms: A, B"))
        result = self.chunk(engine)
        self.assertNotIn("prompt_text", result)
        self.chunk(engine)                                           # the same text again is kept once
        self.transport.default = json_response(200, chunk_answer("b", prompt_text="EN frame. Terms: A, B"))
        self.chunk(engine)
        self.assertEqual(engine.prompt_text_seen(), "KO frame. Terms: A, B\nEN frame. Terms: A, B")
        for n in range(10):
            self.transport.default = json_response(200, chunk_answer("c", prompt_text=f"frame {n}"))
            self.chunk(engine)
        self.assertLessEqual(len(engine.prompt_text_seen().splitlines()), asr_http.PROMPT_TEXTS_MAX)


class RetryTests(HttpCase):
    def test_connection_errors_are_retried_after_1_and_2_5_seconds_with_one_idempotency_key(self):
        self.transport.script = [ConnectionRefusedError("down"), TimeoutError("slow")]
        engine = self.engine()
        self.chunk(engine)
        self.assertEqual(len(self.transport.calls), 3)
        self.assertEqual(self.sleep.waits, [1.0, 2.5])
        keys = {c.header("X-MCAP-Idem") for c in self.transport.calls}
        self.assertEqual(len(keys), 1)
        self.assertEqual(engine.idems, [keys.pop()])
        self.assertEqual([c.body for c in self.transport.calls][0], [c.body for c in self.transport.calls][2])

    def test_a_new_request_gets_a_new_idempotency_key(self):
        engine = self.engine()
        self.chunk(engine)
        self.chunk(engine)
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in self.transport.calls}), 2)

    def test_jitter_is_plus_minus_20_percent(self):
        for rand, expected in ((lambda: 0.0, [0.8, 2.0]), (lambda: 1.0, [1.2, 3.0]), (lambda: 0.5, [1.0, 2.5])):
            with self.subTest(expected=expected):
                self.sleep.waits.clear()
                self.transport.calls.clear()
                self.transport.script = [ConnectionRefusedError(), ConnectionRefusedError()]
                self.chunk(self.engine(rand=rand))
                self.assertEqual([round(w, 6) for w in self.sleep.waits], expected)

    def test_when_every_attempt_fails_the_error_is_transient_and_says_only_what_happened(self):
        self.transport.script = [ConnectionRefusedError(CANARY_TEXT)] * 3
        with self.assertRaises(EngineTransient) as cm:
            self.chunk(self.engine())
        self.assertEqual(len(self.transport.calls), 3)
        self.assertEqual(self.sleep.waits, [1.0, 2.5])              # no wait after the last attempt
        self.assertEqual((cm.exception.code, cm.exception.status), ("connect", None))
        self.assertEqual(str(cm.exception), "the server could not be reached (connect) after 3 attempt(s)")
        self.assertNothingLeaked()

    def test_retry_max_sets_the_attempts(self):
        for retry_max, calls, waits in ((1, 1, []), (2, 2, [1.0]), (5, 5, [1.0, 2.5, 2.5, 2.5])):
            with self.subTest(retry_max=retry_max):
                self.cfg.asr_retry_max = retry_max
                self.transport.calls.clear()
                self.sleep.waits.clear()
                self.transport.script = [ConnectionRefusedError()] * 9
                with self.assertRaises(EngineTransient):
                    self.chunk(self.engine())
                self.assertEqual((len(self.transport.calls), self.sleep.waits), (calls, waits))

    def test_a_malformed_request_is_not_retried(self):
        self.transport.script = [ValueError("Invalid header value " + CANARY_TEXT)]
        with self.assertRaises(EngineTransient) as cm:
            self.chunk(self.engine())
        self.assertEqual((len(self.transport.calls), self.sleep.waits), (1, []))
        self.assertEqual(cm.exception.code, "bad_request")
        self.assertNothingLeaked()

    def test_a_5xx_gets_one_retry_only(self):
        for status in (500, 502, 504, 408, 599):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.sleep.waits.clear()
                self.transport.script = [error_answer(status), error_answer(status), error_answer(status)]
                with self.assertRaises(EngineTransient) as cm:
                    self.chunk(self.engine())
                self.assertEqual((len(self.transport.calls), self.sleep.waits), (2, [1.0]))
                self.assertEqual(cm.exception.status, status)

    def test_a_5xx_followed_by_success(self):
        self.transport.script = [error_answer(500)]
        self.chunk(self.engine())
        self.assertEqual((len(self.transport.calls), self.sleep.waits), (2, [1.0]))

    def test_429_and_503_wait_exactly_retry_after(self):
        for status in (429, 503):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.sleep.waits.clear()
                self.transport.script = [error_answer(status, "busy", retry_after=7), error_answer(status, "busy", retry_after=3)]
                self.chunk(self.engine())
                self.assertEqual((len(self.transport.calls), self.sleep.waits), (3, [7.0, 3.0]))

    def test_retry_after_is_capped_at_60_seconds(self):
        self.cfg.asr_remote_max_wait_s = 600
        self.transport.script = [error_answer(503, "busy", retry_after=500)]
        self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [60.0])

    def test_retry_after_from_the_body_alone_and_a_garbage_header(self):
        body = json.dumps({"error": {"code": "busy", "retry_after_s": 4}})
        self.transport.script = [json_response(503, raw=body.encode()), json_response(503, raw=body.encode(), headers={"Retry-After": "tomorrow"})]
        self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [4.0, 4.0])

    def test_without_retry_after_a_503_uses_the_schedule(self):
        self.transport.script = [json_response(503, raw=b"busy"), json_response(429, raw=b"slow")]
        self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [1.0, 2.5])

    def test_a_busy_server_ends_transient_after_the_attempts(self):
        self.transport.script = [error_answer(503, "busy", retry_after=2)] * 3
        with self.assertRaises(EngineTransient) as cm:
            self.chunk(self.engine())
        self.assertEqual((len(self.transport.calls), self.sleep.waits), (3, [2.0, 2.0]))
        self.assertEqual((cm.exception.status, cm.exception.code), (503, "busy"))
        self.assertEqual(str(cm.exception), "the server answered HTTP 503 after 3 attempt(s)")

    def test_the_total_time_of_one_request_is_bounded(self):
        self.cfg.asr_remote_max_wait_s = 10
        self.transport.script = [error_answer(503, "busy", retry_after=6), error_answer(503, "busy", retry_after=6)]
        with self.assertRaises(EngineTransient) as cm:
            self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [6.0])                     # the second wait would pass 10 s
        self.assertIn("time limit", str(cm.exception))
        self.assertEqual(len(self.transport.calls), 2)

    def test_the_time_the_answers_take_counts_too(self):
        self.cfg.asr_remote_max_wait_s = 12
        self.transport.latency = 5.0
        self.transport.script = [ConnectionRefusedError(), ConnectionRefusedError(), ConnectionRefusedError()]
        with self.assertRaises(EngineTransient):
            self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [1.0])                     # 5 + 1 + 5 = 11, the next wait (2.5) would pass 12

    def test_401_and_403_are_authentication_errors_and_not_retried(self):
        for status in (401, 403):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.transport.script = [error_answer(status, "unauthorized", message=CANARY_TEXT)]
                with self.assertRaises(EngineAuthError) as cm:
                    self.chunk(self.engine())
                self.assertEqual((len(self.transport.calls), self.sleep.waits), (1, []))
                self.assertEqual((cm.exception.status, cm.exception.code), (status, "unauthorized"))
                self.assertEqual(str(cm.exception), f"the server refused the credential (HTTP {status})")
        self.assertNothingLeaked()

    def test_426_is_a_policy_error(self):
        self.transport.script = [error_answer(426, "proto_mismatch")]
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(self.engine())
        self.assertEqual((len(self.transport.calls), cm.exception.status, cm.exception.code), (1, 426, "proto_mismatch"))

    def test_the_other_4xx_are_not_retried_and_are_not_transient(self):
        for status, code in ((400, "bad_request"), (404, "vocab_unknown"), (409, "idem_conflict"), (411, None), (413, "payload_too_large"),
                             (415, None), (422, "unprocessable_audio")):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.transport.script = [error_answer(status, code or "x_code", message=CANARY_TEXT)]
                with self.assertRaises(EngineHttpError) as cm:
                    self.chunk(self.engine())
                self.assertEqual((len(self.transport.calls), self.sleep.waits), (1, []))
                self.assertEqual((cm.exception.status, cm.exception.code, cm.exception.retryable), (status, code or "x_code", False))
                self.assertIsInstance(cm.exception, EngineError)
                self.assertNotIsInstance(cm.exception, (EngineTransient, EngineAuthError, EnginePolicyDenied))
        self.assertNothingLeaked()

    def test_recover_fixes_a_4xx_and_the_same_request_goes_again_once(self):
        engine = self.engine()
        engine.recover_with = True
        self.transport.script = [error_answer(404, "vocab_unknown")]
        self.chunk(engine)
        self.assertEqual(len(self.transport.calls), 2)
        self.assertEqual(engine.recovered, 1)
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in self.transport.calls}), 1)
        self.assertEqual(self.transport.calls[0].body, self.transport.calls[1].body)
        self.assertEqual(self.sleep.waits, [])

    def test_recover_is_tried_once_per_request(self):
        engine = self.engine()
        engine.recover_with = True
        self.transport.script = [error_answer(404, "vocab_unknown"), error_answer(404, "vocab_unknown")]
        with self.assertRaises(EngineHttpError):
            self.chunk(engine)
        self.assertEqual((len(self.transport.calls), engine.recovered), (2, 1))

    def test_recover_that_declines_raises_at_once(self):
        engine = self.engine()
        self.transport.script = [error_answer(404, "vocab_unknown")]
        with self.assertRaises(EngineHttpError):
            self.chunk(engine)
        self.assertEqual((len(self.transport.calls), engine.recovered), (1, 1))

    def test_a_redirect_is_a_policy_error_and_the_answer_is_never_followed(self):
        self.transport.script = [json_response(302, {}, {"Location": "https://evil.example/steal"})]
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(self.engine())
        self.assertEqual((cm.exception.code, cm.exception.status, len(self.transport.calls), self.sleep.waits), ("redirect", 302, 1, []))
        (line,) = self.usage_lines()
        self.assertEqual((line["outcome"], line["status"], line["requests"]), ("denied:redirect", 302, 1))
        self.assertNothingLeaked("evil.example")

    def test_an_oversized_answer_is_a_policy_error(self):
        self.transport.script = [Response(200, {}, b"x" * (262144 + 1), 0, 0, 0)]
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(self.engine())
        self.assertEqual(cm.exception.code, "response_too_large")
        self.assertEqual(self.usage_lines()[0]["outcome"], "denied:response_too_large")

    def test_a_host_the_guard_does_not_allow_is_a_policy_error_and_nothing_is_sent(self):
        other = HostRule("other.example", 443, CA_SHA, "ca.pem")
        engine = self.engine(guard=self.guard(other))
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(engine)
        self.assertEqual((cm.exception.code, self.transport.calls), ("host_not_allowed", []))
        (line,) = self.usage_lines()
        self.assertEqual((line["outcome"], line["requests"], line["audio_s"], line["bytes_out"]), ("denied:host_not_allowed", 0, 0.0, 0))

    def test_a_server_never_gets_its_words_into_an_error_a_log_or_a_file(self):
        evil = Response(500, {"x-evil": CANARY_TEXT.replace("\r\n", " "), "retry-after": "1"},
                        json.dumps({"error": {"code": "engine_error", "message": CANARY_TEXT}}).encode(), 0, 0, 0)
        self.transport.script = [evil, evil]
        with self.assertRaises(EngineTransient) as cm:
            self.chunk(self.engine())
        for text in (str(cm.exception), repr(cm.exception), repr(cm.exception.__context__), repr(cm.exception.__cause__)):
            for fragment in CANARY_FRAGMENTS:
                self.assertNotIn(fragment, text)
        self.assertNothingLeaked()


class UsageRecordTests(HttpCase):
    def test_one_line_per_attempt_with_the_attempt_number(self):
        self.transport.script = [ConnectionRefusedError(), TimeoutError(), error_answer(503, "busy", retry_after=1)]
        with self.assertRaises(EngineTransient):
            self.chunk(self.engine(), 2.0)
        self.assertEqual([(x["attempt"], x["outcome"], x["status"], x["requests"]) for x in self.usage_lines()],
                         [(1, "error:connect", 0, 0), (2, "error:timeout", 0, 1), (3, "http_503", 503, 1)])

    def test_a_successful_retry_is_one_more_line(self):
        self.transport.script = [ConnectionRefusedError(), error_answer(503, "busy", retry_after=1)]
        self.cfg.asr_retry_max = 4
        self.chunk(self.engine(), 2.0)
        self.assertEqual([(x["attempt"], x["outcome"]) for x in self.usage_lines()],
                         [(1, "error:connect"), (2, "http_503"), (3, "ok")])

    def test_the_line_carries_the_numbers_and_the_exact_host(self):
        self.transport.default = json_response(200, chunk_answer())
        self.chunk(self.engine(), 3.0)
        (line,) = self.usage_lines()
        self.assertEqual((line["engine"], line["kind"], line["host"], line["op"]), ("remote", "server", HOST, "chunk"))
        self.assertEqual((line["audio_s"], line["bytes_out"], line["requests"]), (3.0, 96000, 1))
        self.assertGreater(line["bytes_in"], 0)
        self.assertEqual((line["circuit"], line["est_usd"]), ("closed", None))
        self.assertNotIn(TOKEN, json.dumps(line))

    def test_the_circuit_state_of_the_router_goes_into_the_line(self):
        engine = self.engine()
        engine.bind_breaker(SimpleNamespace(state="half-open"))
        self.chunk(engine)
        self.assertEqual(self.usage_lines()[0]["circuit"], "half-open")

    def test_a_guard_without_a_usage_callback_means_no_double_count(self):
        self.chunk(self.engine())
        self.chunk(self.engine())
        self.assertEqual(len(self.usage_lines()), 2)

    def test_the_cloud_estimate_follows_the_price_setting(self):
        decision = make_decision(self.cfg, "azure", consents=("azure",))
        rule = decision.hosts[AZURE_HOST]
        self.store_token(AZURE_KEY, "azure", AZURE_HOST)
        self.cfg.asr_azure_usd_per_hour = 3.6
        guard = EgressGuard({AZURE_HOST: rule}, engine_id="azure", consent_id="c-azure", transport=self.transport, clock=self.clock,
                            pre_connect=self.gate)
        engine = MiniCloudEngine(self.cfg, None, decision, guard, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock)
        engine.transcribe_chunk(audio(10.0), "en", None)
        (line,) = self.usage_lines()
        self.assertEqual((line["engine"], line["kind"], line["est_usd"]), ("azure", "cloud", 0.01))
        self.assertEqual(self.transport.calls[0].header("Ocp-Apim-Subscription-Key"), AZURE_KEY)
        self.assertIsNone(self.transport.calls[0].header("Authorization"))
        self.assertEqual(self.transport.calls[0].path, "/speechtotext/transcriptions:transcribe")
        self.assertNothingLeaked(AZURE_KEY)

    def test_a_free_price_is_null_not_zero(self):
        self.cfg.asr_azure_usd_per_hour = 0.0
        self.chunk(self.engine())
        self.assertIsNone(self.usage_lines()[0]["est_usd"])

    def test_counters_and_the_sent_flag(self):
        engine = self.engine()
        self.assertEqual(engine.usage(), {"requests": 0, "lid_requests": 0, "audio_s": 0.0, "bytes": 0})
        self.assertFalse(engine.sent_anything())
        self.transport.script = [ConnectionRefusedError()]
        self.chunk(engine, 2.0)                                       # the refused connection sent nothing, the retry did
        self.assertEqual(engine.usage(), {"requests": 1, "lid_requests": 0, "audio_s": 2.0, "bytes": 64000})
        engine.exchange("lid", "POST", "/v1/lid", {}, b"\x00" * 1000, audio_s=0.5)
        self.assertEqual(engine.usage(), {"requests": 1, "lid_requests": 1, "audio_s": 2.5, "bytes": 65000})
        self.assertTrue(engine.sent_anything())

    def test_a_health_check_alone_is_not_meeting_data(self):
        self.transport.default = json_response(200, health_document())
        engine = self.engine()
        engine.check_health(backend_kind="server")
        self.assertFalse(engine.sent_anything())
        self.assertEqual(engine.usage()["requests"], 0)
        engine.exchange("vocab", "PUT", "/v1/vocab/" + "ab" * 32, {}, b'{"terms":["x"]}')
        self.assertTrue(engine.sent_anything())                       # the vocabulary left the Mac

    def test_the_provenance_names_a_label_and_never_the_host_or_the_credential(self):
        engine = self.engine()
        self.assertEqual(engine.provenance()["privacy"], "local")     # nothing sent yet
        self.chunk(engine)
        block = engine.provenance()
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["region"]),
                         ("remote", "server", "server", "company-asr", "kr"))
        self.assertEqual((block["protocol"], block["consent_id"], block["chunks"], block["schema"]), ("mcap-asr/1", "c-remote", {"remote": 1}, 1))
        self.assertEqual(block["sent"]["requests"], 1)
        text = json.dumps(block)
        self.assertNotIn(HOST, text)
        self.assertNotIn(TOKEN, text)
        self.assertEqual(asr._clean_provenance(block), block)         # asr.py keeps every key of it: nothing is cut or reshaped

    def test_the_cloud_destination_is_vendor_and_region(self):
        decision = make_decision(self.cfg, "azure", consents=("azure",))
        guard = EgressGuard({AZURE_HOST: decision.hosts[AZURE_HOST]}, engine_id="azure", consent_id="c", transport=self.transport, clock=self.clock)
        engine = MiniCloudEngine(self.cfg, None, decision, guard, gate=self.gate, sleep=self.sleep, clock=self.clock)
        self.assertEqual(engine.destination_label(), "azure/koreacentral")
        self.assertNotIn(AZURE_HOST, json.dumps(engine.describe()))

    def test_describe_has_no_host_and_no_secret(self):
        engine = self.engine()
        self.chunk(engine)
        text = json.dumps(engine.describe())
        self.assertNotIn(HOST, text)
        self.assertNotIn(TOKEN, text)
        self.assertEqual(engine.describe()["destination"], "company-asr")


class GateTests(HttpCase):
    def test_a_closed_gate_sends_nothing_reads_no_keychain_and_asks_no_cap(self):
        self.gate.close("local_only")
        engine = self.engine(cap_minutes=0)                            # the cap would refuse too: the gate comes first
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(engine)
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        self.assertEqual(cm.exception.code, "local_only")
        self.assertEqual(str(cm.exception), "external ASR is not allowed now (local_only)")
        (line,) = self.usage_lines()
        self.assertEqual((line["outcome"], line["requests"], line["audio_s"]), ("denied:gate", 0, 0.0))

    def test_the_gate_is_read_before_every_attempt(self):
        engine = self.engine(guard=self.guard(pre_connect=None))
        self.transport.script = [ConnectionRefusedError(), ConnectionRefusedError()]
        self.chunk(engine)
        self.assertEqual(self.gate.calls, 3)

    def test_a_gate_that_closes_during_a_retry_after_sleep_stops_the_next_attempt(self):
        self.sleep.on_sleep = lambda seconds: self.gate.close("local_only")
        self.transport.script = [error_answer(503, "busy", retry_after=30)]
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(self.engine())
        self.assertEqual((len(self.transport.calls), self.sleep.waits), (1, [30.0]))
        self.assertEqual(cm.exception.code, "local_only")
        self.assertEqual([x["outcome"] for x in self.usage_lines()], ["http_503", "denied:gate"])

    def test_a_gate_that_closes_after_the_first_attempt_ends_a_connection_retry_too(self):
        self.transport.on_send = lambda call: self.gate.close("policy-lane")
        self.transport.script = [ConnectionRefusedError()]
        with self.assertRaises(EnginePolicyDenied):
            self.chunk(self.engine())
        self.assertEqual(len(self.transport.calls), 1)

    def test_the_guards_pre_connect_is_the_last_line_before_the_socket(self):
        engine = self.engine(gate=None, guard=self.guard(pre_connect=self.gate))
        self.sleep.on_sleep = lambda seconds: self.gate.close("local_only")
        self.transport.script = [error_answer(503, "busy", retry_after=5)]
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(engine)
        self.assertEqual((len(self.transport.calls), cm.exception.code), (1, "pre_connect"))
        self.assertEqual([x["outcome"] for x in self.usage_lines()], ["http_503", "denied:pre_connect"])

    def test_a_pre_connect_that_raises_closes_the_request(self):
        def broken():
            raise RuntimeError("gate bug " + CANARY_TEXT)
        engine = self.engine(gate=None, guard=self.guard(pre_connect=broken))
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(engine)
        self.assertEqual((cm.exception.code, self.transport.calls), ("gate_failed", []))
        self.assertNothingLeaked()

    def test_a_gate_that_raises_is_a_closed_gate(self):
        def broken():
            raise RuntimeError("gate bug")
        with self.assertRaises(EnginePolicyDenied):
            self.chunk(self.engine(gate=broken))
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))

    def test_an_engine_error_from_the_gate_passes_through(self):
        def gate_raises():
            raise EnginePolicyDenied("the lane closed")
        engine = self.engine(gate=None, guard=self.guard(pre_connect=gate_raises))
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.chunk(engine)
        self.assertEqual(str(cm.exception), "the lane closed")
        self.assertEqual(self.usage_lines()[0]["outcome"], "denied:pre_connect")


class SecretTests(HttpCase):
    def test_nothing_is_read_until_the_first_request(self):
        engine = self.engine()
        engine.describe()
        engine.preflight()
        engine.usage()
        engine.provenance()
        self.assertEqual(self.security.reads(), 0)
        self.chunk(engine)
        self.assertEqual(self.security.reads(), 1)

    def test_it_is_read_once_per_engine_lifetime_even_with_retries(self):
        self.transport.script = [ConnectionRefusedError(), error_answer(503, "busy", retry_after=1)]
        engine = self.engine()
        self.chunk(engine)
        self.chunk(engine)
        self.chunk(engine)
        self.assertEqual(len(self.transport.calls), 5)
        self.assertEqual(self.security.reads(), 1)
        self.assertTrue(all(c.header("Authorization") == f"Bearer {TOKEN}" for c in self.transport.calls))

    def test_it_is_asked_for_the_item_of_this_engine_host_and_port(self):
        self.chunk(self.engine())
        (argv,) = [a for a in self.security.argvs("find-generic-password") if "-w" in a]
        self.assertEqual(argv[argv.index("-s") + 1], "MeetingCapture ASR remote")
        self.assertEqual(argv[argv.index("-a") + 1], f"{apikey.keychain_account()}@{HOST}:443")

    def test_a_missing_credential_is_an_authentication_error_and_nothing_is_sent(self):
        self.security.remove()
        engine = self.engine()
        with self.assertRaises(EngineAuthError) as cm:
            self.chunk(engine)
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(cm.exception.code, "missing")
        self.assertIn("credential unavailable (missing)", str(cm.exception))
        self.assertIn("mcap asr-engines enroll remote", str(cm.exception))
        self.assertNotIn(HOST, str(cm.exception))
        self.assertNotIn(apikey.keychain_account() + "@", str(cm.exception))
        self.assertEqual(self.usage_lines()[0]["outcome"], "denied:credential")

    def test_a_secret_stored_for_another_port_or_host_is_not_found(self):
        self.security.remove()
        self.store_token(TOKEN, port=8443)
        self.store_token(TOKEN, host="other.example.internal")
        with self.assertRaises(EngineAuthError) as cm:
            self.chunk(self.engine())
        self.assertEqual(cm.exception.code, "missing")
        self.assertEqual(self.transport.calls, [])

    def test_the_token_is_never_persisted_or_logged(self):
        self.transport.script = [ConnectionRefusedError(CANARY_TEXT), error_answer(503, "busy", retry_after=1, message=CANARY_TEXT)]
        engine = self.engine()
        self.chunk(engine)
        engine.release()
        self.assertNothingLeaked()

    def test_the_token_is_registered_for_masking(self):
        self.chunk(self.engine())
        self.assertNotIn(TOKEN, apikey.redact(f"x {TOKEN} y"))

    def test_release_forgets_the_token_and_the_next_use_reads_again(self):
        engine = self.engine()
        self.chunk(engine)
        engine.release()
        self.assertIsNone(engine._token)
        self.chunk(engine)
        self.assertEqual(self.security.reads(), 2)
        engine.reset_secret()
        self.chunk(engine)
        self.assertEqual(self.security.reads(), 3)

    def test_an_engine_that_needs_no_credential_reads_none(self):
        class Open(MiniRemoteEngine):
            needs_secret = False
        self.security.remove()
        self.chunk(self.engine(Open))
        self.assertEqual(self.security.reads(), 0)
        self.assertIsNone(self.transport.calls[0].header("Authorization"))

    def test_the_keychain_tool_that_does_not_answer_is_an_authentication_error(self):
        self.security.set_mode("deny")
        with self.assertRaises(EngineAuthError) as cm:
            self.chunk(self.engine())
        self.assertEqual((cm.exception.code, self.transport.calls), ("error", []))

    def test_the_exception_of_a_credential_failure_carries_no_tool_output(self):
        self.security.set_mode("deny")
        with self.assertRaises(EngineAuthError) as cm:
            self.chunk(self.engine())
        self.assertNotIn("User interaction", str(cm.exception))
        self.assertNothingLeaked()


class CapTests(HttpCase):
    def preload(self, seconds):
        asr_usage.record(self.cfg, engine="remote", kind="server", host=HOST, op="chunk", status=200, audio_s=seconds - 1.0, bytes_out=1,
                         bytes_in=1, dur_ms=1, outcome="ok")

    def test_the_chunk_that_would_pass_the_cap_is_refused_before_anything_is_sent(self):
        self.preload(55.0)                                              # 55 s of the minute are used
        engine = self.engine(cap_minutes=1.0)
        self.chunk(engine, 2.0)                                         # +3 s (2 s of audio and the request): 58 s, fine
        with self.assertRaises(EngineCapReached) as cm:
            self.chunk(engine, 2.0)                                     # 58 s + 3 s would pass the minute
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(cm.exception.code, "cap")
        self.assertIn("daily limit", str(cm.exception))
        self.assertEqual(len(self.usage_lines()), 2)                    # the preload and the one sent chunk: no line for the refusal

    def test_zero_means_no_external_audio(self):
        self.cfg.asr_cloud_daily_minutes = 0
        with self.assertRaises(EngineCapReached):
            self.chunk(self.engine())
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))

    def test_the_default_cap_is_the_setting(self):
        self.cfg.asr_cloud_daily_minutes = 1
        engine = self.engine()
        self.preload(30.0)
        self.chunk(engine, 20.0)
        with self.assertRaises(EngineCapReached):
            self.chunk(engine, 20.0)

    def test_an_infinite_cap_is_no_cap(self):
        self.preload(10 ** 6)
        self.chunk(self.engine(cap_minutes=float("inf")))
        self.assertEqual(len(self.transport.calls), 1)

    def test_the_usage_file_is_read_once_per_day_not_once_per_chunk(self):
        engine = self.engine(cap_minutes=100.0)
        with mock.patch.object(asr_usage, "minutes_today", wraps=asr_usage.minutes_today) as spy:
            for _ in range(5):
                self.chunk(engine)
        self.assertEqual(spy.call_count, 1)

    def test_a_new_day_reads_the_file_again(self):
        engine = self.engine(cap_minutes=100.0)
        with mock.patch.object(asr_usage, "minutes_today", wraps=asr_usage.minutes_today) as spy:
            self.chunk(engine)
            real_clock = claude_usage.clock
            with mock.patch.object(claude_usage, "clock", lambda: real_clock().replace(year=2030)):
                self.chunk(engine)
        self.assertEqual(spy.call_count, 2)

    def test_the_check_is_per_request_not_per_attempt(self):
        engine = self.engine(cap_minutes=0.06)                          # 3.6 s: one 2 s chunk (3 s) fits, its second attempt would not
        self.transport.script = [TimeoutError()]                        # a timeout may have sent the body: 3 s are used
        self.chunk(engine, 2.0)
        self.assertEqual(len(self.transport.calls), 2)

    def test_requests_that_were_never_sent_do_not_use_the_cap(self):
        engine = self.engine(cap_minutes=0.06)
        self.transport.script = [ConnectionRefusedError()] * 3
        with self.assertRaises(EngineTransient):
            self.chunk(engine, 2.0)
        self.assertEqual(asr_usage.minutes_today(self.cfg), 0.0)
        self.transport.script = []
        self.chunk(engine, 2.0)                                         # the cap is still whole

    def test_a_health_check_is_not_capped(self):
        self.transport.default = json_response(200, health_document())
        self.engine(cap_minutes=0).check_health(backend_kind="server")
        self.assertEqual(len(self.transport.calls), 1)

    def test_a_language_id_request_counts_its_clips(self):
        engine = self.engine(cap_minutes=0.1)
        engine.exchange("lid", "POST", "/v1/lid", {}, b"\x00" * 100, audio_s=4.0)
        with self.assertRaises(EngineCapReached):
            engine.exchange("lid", "POST", "/v1/lid", {}, b"\x00" * 100, audio_s=4.0)


class PreflightTests(HttpCase):
    def test_nothing_is_wrong(self):
        self.assertEqual(self.engine().preflight(), [])
        self.assertEqual(self.security.reads(), 0)                       # the Keychain was asked whether the item exists, not for its value

    def test_a_missing_credential_is_reported(self):
        self.security.remove()
        (problem,) = self.engine().preflight()
        self.assertIn("no credential is stored", problem)
        self.assertIn("missing", problem)
        self.assertNotIn(HOST, problem)

    def test_a_server_without_a_bound_private_ca_is_reported(self):
        loose = HostRule(HOST, 443)
        decision = dataclasses.replace(make_decision(self.cfg, "remote"), hosts={HOST: loose})
        (problem,) = self.engine(decision=decision, guard=self.guard(loose, trust="system")).preflight()
        self.assertIn("private CA", problem)

    def test_no_destination(self):
        (problem,) = self.engine(decision=make_decision(self.cfg, "whisper")).preflight()
        self.assertIn("no destination", problem)


# ======================================================================================================================
class ParseHealthTests(unittest.TestCase):
    def test_a_healthy_document_is_reduced_to_what_the_client_uses(self):
        h = parse_health(json.dumps(health_document()).encode())
        self.assertEqual((h["proto"], h["ok"], h["engine"], h["kind"], h["supports_lid"], h["confidence"]),
                         ("mcap-asr/1", True, "whisper", "server", True, "logprob"))
        self.assertEqual(h["limits"]["max_chunk_samples"], 496000)
        self.assertEqual(h["retention"], {"mode": "none", "audio_disk": False, "text_disk": False, "memory_cache_s": 120.0, "log_content": False})
        self.assertEqual((h["attest"]["build_sha256"], h["attest"]["core_dumps_disabled"]), (BUILD_SHA, True))
        self.assertEqual((h["token"]["expires_in_days"], h["queue"]), (71.0, {"depth": 2.0, "avg_service_s": 4.1}))
        self.assertIsNone(h["vendor"])

    def test_a_relay_backend_discloses_the_vendor(self):
        doc = health_document(kind="cloud", confidence="opaque", supports_lid=False,
                              vendor={"name": "azure-speech", "region": "koreacentral", "claim_url": "https://x.example/claim", "verified": False})
        h = parse_health(json.dumps(doc).encode())
        self.assertEqual(h["vendor"], {"name": "azure-speech", "region": "koreacentral", "verified": False})
        self.assertNotIn("claim_url", json.dumps(h))

    def test_wrong_types_are_dropped_and_text_is_one_line_and_short(self):
        doc = health_document(supports_lid="yes", model="line one\nline two " + "x" * 400, evil=CANARY_TEXT)
        doc["limits"] = {"max_chunk_samples": "many", "max_lid_clips": 12, "Bad Key": 1, "negative": -4, "nan": float("nan")}
        doc["retention"]["audio_disk"] = "no"
        h = parse_health(json.dumps(doc).replace("NaN", "null").encode())
        self.assertIsNone(h["supports_lid"])
        self.assertNotIn("\n", h["model"])
        self.assertLessEqual(len(h["model"]), 120)
        self.assertEqual(h["limits"], {"max_lid_clips": 12.0})
        self.assertIsNone(h["retention"]["audio_disk"])
        self.assertNotIn("ZZCANARY", json.dumps(h))

    def test_an_answer_that_is_not_a_health_document_is_transient(self):
        for bad in (b"", b"<html>", b"[]", b'"mcap-asr/1"', b"{}", b'{"proto": 1}', b'{"ok": true}'):
            with self.subTest(bad=bad), self.assertRaises(EngineTransient):
                parse_health(bad)
        with self.assertRaises(EngineTransient):
            parse_health(None)


class HealthProblemTests(unittest.TestCase):
    def problems(self, doc=None, **kw):
        return health_problems(parse_health(json.dumps(doc or health_document()).encode()), **kw)

    def test_a_good_server_has_no_problem(self):
        self.assertEqual(self.problems(), [])
        self.assertEqual(self.problems(backend_kind="server", attest_allow=(BUILD_SHA,)), [])

    def test_the_protocol_must_be_ours(self):
        self.assertEqual(self.problems(health_document(proto="mcap-asr/2")), ["proto"])

    def test_the_server_must_say_it_is_ok(self):
        self.assertEqual(self.problems(health_document(ok=False)), ["not-ok"])
        self.assertEqual(self.problems(health_document(ok="true")), ["not-ok"])

    def test_retention_must_be_none_and_nothing_on_disk(self):
        for change in ({"mode": "ttl"}, {"mode": "disk"}, {"mode": None}, {"audio_disk": True}, {"text_disk": True}):
            with self.subTest(change=change):
                doc = health_document()
                doc["retention"] = {**doc["retention"], **change}
                self.assertEqual(self.problems(doc), ["retention"])
        doc = health_document()
        del doc["retention"]
        self.assertEqual(self.problems(doc), ["retention"])

    def test_the_backend_kind_must_be_the_one_consented_to(self):
        self.assertEqual(self.problems(health_document(kind="cloud"), backend_kind="server"), ["kind"])
        self.assertEqual(self.problems(health_document(kind="cloud")), [])          # no consent given: not compared

    def test_the_build_must_be_on_the_organisations_list(self):
        self.assertEqual(self.problems(attest_allow=("c" * 64,)), ["attest"])
        self.assertEqual(self.problems(attest_allow=(BUILD_SHA.upper(),)), [])      # hex case does not matter
        self.assertEqual(self.problems(attest_allow=()), ["attest"])                # an empty list allows no build
        self.assertEqual(self.problems(attest_allow=None), [])                      # no list: a changed build is only a warning
        doc = health_document()
        del doc["attest"]
        self.assertEqual(self.problems(doc, attest_allow=(BUILD_SHA,)), ["attest"])

    def test_several_problems_are_all_named(self):
        doc = health_document(proto="x", kind="cloud")
        doc["retention"]["mode"] = "disk"
        self.assertEqual(self.problems(doc, backend_kind="server", attest_allow=("c" * 64,)), ["proto", "retention", "kind", "attest"])


class FetchHealthTests(HttpCase):
    def fetch(self, **kw):
        return fetch_health(self.guard(), self.rule, {"Authorization": f"Bearer {TOKEN}", "X-MCAP-Proto": "mcap-asr/1"}, **kw)

    def test_the_request_and_the_answer(self):
        self.transport.default = json_response(200, health_document())
        health = self.fetch(backend_kind="server", attest_allow=(BUILD_SHA,))
        (call,) = self.transport.calls
        self.assertEqual((call.method, call.target, call.timeout, call.body), ("GET", "/v1/health?detail=1", 5.0, b""))
        self.assertEqual(call.header("Authorization"), f"Bearer {TOKEN}")
        self.assertEqual(health["model"], "mlx-community/whisper-large-v3-mlx")

    def test_a_port_other_than_443_is_in_the_url(self):
        rule = HostRule(HOST, 8443, CA_SHA, "ca.pem")
        self.transport.default = json_response(200, health_document())
        fetch_health(self.guard(rule), rule, {})
        self.assertEqual(self.transport.calls[0].rule.port, 8443)

    def test_a_refusal_is_a_policy_error_that_lists_codes_only(self):
        doc = health_document()
        doc["retention"]["mode"] = CANARY_TEXT
        self.transport.default = json_response(200, doc)
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.fetch(backend_kind="cloud")
        self.assertEqual(str(cm.exception), "the server was refused: retention, kind")
        self.assertEqual(cm.exception.code, "retention")
        self.assertNothingLeaked()

    def test_status_mapping(self):
        cases = [(401, EngineAuthError), (403, EngineAuthError), (426, EnginePolicyDenied), (404, EnginePolicyDenied),
                 (400, EnginePolicyDenied), (408, EngineTransient), (429, EngineTransient), (500, EngineTransient), (503, EngineTransient)]
        for status, exc_type in cases:
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.transport.default = json_response(status, {"error": {"code": "x_y", "message": CANARY_TEXT}})
                with self.assertRaises(exc_type) as cm:
                    self.fetch()
                self.assertEqual((type(cm.exception), cm.exception.status), (exc_type, status))
                self.assertEqual(len(self.transport.calls), 1)                # a health check is not retried
        self.assertNothingLeaked()

    def test_an_unreachable_server_is_transient_and_a_forbidden_destination_is_not(self):
        self.transport.script = [TimeoutError(CANARY_TEXT)]
        with self.assertRaises(EngineTransient) as cm:
            self.fetch()
        self.assertEqual(cm.exception.code, "timeout")
        redirect = json_response(302, {}, {"Location": "https://evil.example/"})
        self.transport.script = [redirect]
        with self.assertRaises(EnginePolicyDenied) as cm2:
            self.fetch()
        self.assertEqual(cm2.exception.code, "redirect")
        other = HostRule("other.example", 443, CA_SHA, "ca.pem")
        with self.assertRaises(EnginePolicyDenied) as cm3:
            fetch_health(self.guard(other), self.rule, {})
        self.assertEqual(cm3.exception.code, "host_not_allowed")
        self.assertNothingLeaked("evil.example")

    def test_an_unreadable_answer_is_transient(self):
        self.transport.default = json_response(200, raw=b"<html>login</html>")
        with self.assertRaises(EngineTransient):
            self.fetch()

    def test_the_closed_gate_of_the_guard_stops_it_before_the_socket(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.fetch()
        self.assertEqual((cm.exception.code, self.transport.calls), ("pre_connect", []))


class CheckHealthTests(HttpCase):
    def test_check_health_stores_the_document_and_writes_one_usage_line(self):
        self.transport.default = json_response(200, health_document())
        engine = self.engine()
        health = engine.check_health(backend_kind="server", attest_allow=(BUILD_SHA,))
        self.assertIs(engine.health, health)
        self.assertEqual(self.transport.calls[0].header("Authorization"), f"Bearer {TOKEN}")
        self.assertEqual(self.transport.calls[0].header("X-MCAP-Proto"), "mcap-asr/1")
        self.assertEqual(self.transport.calls[0].timeout, 5.0)
        (line,) = self.usage_lines()
        self.assertEqual((line["op"], line["status"], line["outcome"], line["requests"], line["audio_s"], line["bytes_out"]),
                         ("health", 200, "ok", 1, 0.0, 0))
        self.assertGreater(line["bytes_in"], 0)

    def test_the_gate_comes_first_and_the_keychain_is_not_read(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            self.engine().check_health()
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))

    def test_a_refusal_keeps_the_old_health_and_is_recorded(self):
        engine = self.engine()
        self.transport.default = json_response(200, health_document(kind="cloud"))
        with self.assertRaises(EnginePolicyDenied):
            engine.check_health(backend_kind="server")
        self.assertIsNone(engine.health)
        self.assertEqual(self.usage_lines()[0]["outcome"], "ok")                  # the exchange itself worked: the document was refused

    def test_failures_are_recorded_with_their_word(self):
        engine = self.engine()
        for answer in (error_answer(401, "unauthorized"), TimeoutError(), json_response(302, {}, {"Location": "https://x.example/"})):
            self.transport.script = [answer]
            with self.assertRaises(EngineError):
                engine.check_health()
        self.assertEqual([x["outcome"] for x in self.usage_lines()], ["http_401", "error:timeout", "denied:redirect"])


class FakeTransportTests(HttpCase):
    """The support double itself: later packages rely on its behaviour."""

    def test_script_then_handler_then_default(self):
        t = FakeTransport(json_response(201, {"a": 1}), handler=lambda call: json_response(202, {"path": call.path}), default=json_response(203, {}))
        rule = self.rule
        self.assertEqual(t.send(rule, "GET", "/x?y=1", {"A": "b"}, b"", 1.0).status, 201)
        self.assertEqual(t.send(rule, "GET", "/x?y=1", {}, b"", 1.0).status, 202)
        self.assertEqual((t.calls[1].path, t.calls[0].header("a"), t.paths()), ("/x", "b", ["/x", "/x"]))
        t2 = FakeTransport(default=json_response(203, {}))
        self.assertEqual(t2.send(rule, "GET", "/", {}, b"", 1.0).status, 203)

    def test_callables_and_exceptions_in_the_script(self):
        t = FakeTransport(lambda call: ConnectionError("x"), lambda call: json_response(200, {"n": len(call.body)}))
        with self.assertRaises(ConnectionError):
            t.send(self.rule, "POST", "/", {}, b"abc", 1.0)
        self.assertEqual(json.loads(t.send(self.rule, "POST", "/", {}, b"abc", 1.0).body), {"n": 3})

    def test_latency_advances_the_clock(self):
        t = FakeTransport(clock=self.clock, latency=2.5)
        before = self.clock()
        t.send(self.rule, "GET", "/", {}, b"", 1.0)
        self.assertEqual(self.clock() - before, 2.5)


if __name__ == "__main__":
    unittest.main()
