"""asr_clova.py (SPEC 18): the NAVER CLOVA Speech provider.

The engine runs through a REAL asr_router / asr_http / EgressGuard stack in front of an in-process Transport whose handler is ``FakeClova``: a
small service written from the documentation (the key header, ``POST <invoke path>/recognizer/upload``, the parts ``media`` and ``params``). The
fixtures of tests/fixtures/clova are DOCUMENT-DERIVED until the first live call by the owner replaces them (their header says so and a test pins
it): the documentation does not describe the answer of a sync call, so nothing here proves what the service really sends. No socket opens
(NoNetworkCase), the Keychain is the fake `security`, time is a FakeClock.

Pinned: the request (multipart bytes, the params JSON, headers, the boostings of a vocabulary and every rule that keeps a term or a whole
vocabulary at home), the answer parser (documented fields, defensive variants, empty / failed / malformed answers, a block with more segments than
``clean_result`` keeps), the diarization ``auto`` truth table, the error mapping (401/403 auth, 429/5xx transient with Retry-After, other 4xx a
chunk-local error, a failed job transient), the destination (https only, a NAVER Cloud gateway only, no redirects, host and port bound to the
consent, a settings file edited after the decision), the secret and the invoke path never in a log, a state file, a usage line or the transcript
(canary), the usage line and the provenance of a block, and the whole path through the router and ``transcribe_tracks``.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import json
import logging
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from asr_support import audio, json_response, make_decision, make_run, usage_lines
from provider_support import (CLOVA_HOST, CLOVA_ID_PATH, CLOVA_KEY, CLOVA_URL, SR, VOCAB_TEXT, ProviderCase, clova_consent, parse_multipart, speech_track,
                              wav_samples)

from mcap import asr, asr_clova, asr_creds, asr_providers, asr_router, audioprep, egress, policy
from mcap.asr_clova import BOOSTINGS_MAX, KEY_HEADER, UPLOAD_PATH, boosting_terms, build_params, diarization_enabled, host_allowed, params_json, parse_response
from mcap.asr_engines import EngineAuthError, EngineCapReached, EngineError, EnginePolicyDenied, EngineTransient, engine_caps
from mcap.asr_http import MAX_SEGMENTS, EngineHttpError
from mcap.config import Config
from mcap.egress import Response
from mcap.vocab import Vocab, parse_vocab_text

logging.getLogger("mcap").addHandler(logging.NullHandler())

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "clova"
FIXTURE_NAMES = ("sync_ok_ko_en.json", "sync_ok_variant.json", "sync_empty.json", "sync_text_only.json", "sync_failed.json", "error_429.json",
                 "error_401.json", "params_expected.json")
VOCAB = parse_vocab_text(VOCAB_TEXT)


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def fixture_response(name: str, **headers) -> Response:
    """The recorded-looking answer of a fixture as the guard hands it over: UTF-8 body, lower-case header names."""
    doc = fixture(name)
    return json_response(doc["status"], raw=json.dumps(doc["body"], ensure_ascii=False).encode("utf-8"), headers={**doc.get("headers", {}), **headers})


def body_of(name: str) -> bytes:
    return json.dumps(fixture(name)["body"], ensure_ascii=False).encode("utf-8")


def answer(doc) -> bytes:
    return json.dumps(doc, ensure_ascii=False).encode("utf-8")


# ======================================================================================================================
class FixtureTests(unittest.TestCase):
    def test_every_fixture_says_it_is_document_derived_and_unverified(self):
        for name in FIXTURE_NAMES:
            with self.subTest(name):
                header = fixture(name)["_fixture"]
                self.assertEqual(header["origin"], "document-derived")
                self.assertIs(header["verified"], False)
                self.assertIn("first live call", header["note"])
        self.assertEqual(sorted(p.name for p in FIXTURES.glob("*.json")), sorted(FIXTURE_NAMES))

    def test_the_module_says_the_shape_of_a_sync_answer_is_unverified(self):
        self.assertIn("UNVERIFIED", asr_clova.__doc__)


# ======================================================================================================================
class ParamsTests(unittest.TestCase):
    def test_the_params_part_of_the_fixture_cases(self):
        doc = fixture("params_expected.json")
        terms = boosting_terms(parse_vocab_text(doc["vocabulary_txt"]))
        self.assertEqual(terms, doc["terms"])
        for case in doc["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(build_params(case["language"], [] if case.get("no_terms") else terms, case["diarization"]), case["params"])

    def test_params_are_compact_ascii_json(self):
        raw = params_json(build_params("enko", ["한국어 용어"], True))
        raw.decode("ascii")
        self.assertTrue(b": " not in raw and b", " not in raw)                                      # compact separators
        self.assertEqual(json.loads(raw)["boostings"], [{"words": "한국어 용어"}])

    def test_the_documented_switches_are_always_sent(self):
        params = build_params("ko-KR", [], False)
        self.assertEqual((params["completion"], params["wordAlignment"], params["fullText"], params["noiseFiltering"]), ("sync", True, True, True))
        self.assertEqual(params["diarization"], {"enable": False})                     # explicit: the default differs between the documentation pages
        self.assertNotIn("boostings", params)

    def test_a_term_that_cannot_help_stays_home(self):
        vocab = Vocab(terms=["네", "A", " B ", "no", "ok", "日本語", "한국어 용어", "Acme", "ACME", "acme", "Foo,Bar", "Foo, Bar", "x" * 101, "a\nb", "\x00Acme2",
                             "ab\ud800", "Pre-Sub", "510(k)", 7, None, "ㅋㅋ"])
        self.assertEqual(boosting_terms(vocab), ["no", "ok", "한국어 용어", "Acme", "Foo Bar", "Pre-Sub", "510(k)", "ㅋㅋ"])

    def test_the_aliases_of_the_vocabulary_are_not_terms(self):
        terms = boosting_terms(VOCAB)
        self.assertEqual(terms, ["Acme", "AcmeScan-CXR"])
        self.assertNotIn("애크미", terms)

    def test_at_most_a_thousand_terms_in_file_order(self):
        terms = boosting_terms(Vocab(terms=[f"term{i:04d}" for i in range(BOOSTINGS_MAX + 500)]))
        self.assertEqual((len(terms), terms[0], terms[-1]), (BOOSTINGS_MAX, "term0000", f"term{BOOSTINGS_MAX - 1:04d}"))

    def test_no_vocabulary_no_terms(self):
        for value in (None, types.SimpleNamespace(terms="not a list"), Vocab()):
            self.assertEqual(boosting_terms(value), [])


# ======================================================================================================================
class DiarizationTests(unittest.TestCase):
    TABLE = [                                   # setting, track, solo, platform -> speaker separation
        ("auto", "mic", False, "", False),      # the microphone of an online meeting: one person
        ("auto", "remote", False, "", True),    # the remote side of an online meeting: several people behind one stream
        ("auto", "mic", False, "zoom", False),
        ("auto", "remote", False, "teams", True),
        ("auto", "mic", True, "", True),        # the only track of a meeting (an offline one: one recording of a room)
        ("auto", "remote", True, "", True),
        ("auto", "audio", True, "", True),      # transcribe-file
        ("auto", "mic", False, "manual", True),  # a manual session: every track
        ("auto", "remote", False, "manual", True),
        ("auto", "mic", False, "Manual", True),
        ("on", "mic", False, "zoom", True),
        ("on", "remote", False, "", True),
        ("off", "remote", False, "", False),
        ("off", "mic", True, "manual", False),
        ("ON", "mic", False, "", True),
        ("banana", "mic", False, "", False),    # an unknown word reads as auto
        ("banana", "remote", False, "", True),
        ("", "mic", True, "", True),
        (None, "mic", False, "", False),
    ]

    def test_the_truth_table(self):
        for setting, track, solo, platform, expected in self.TABLE:
            with self.subTest(setting=setting, track=track, solo=solo, platform=platform):
                self.assertIs(diarization_enabled(setting, track, solo, platform), expected)

    def test_the_setting_defaults_to_auto(self):
        self.assertEqual(Config().asr_clova_diarization, "auto")                      # reading on / off / auto from config.env: test_asr_providers.ConfigTests


# ======================================================================================================================
class ParseTests(unittest.TestCase):
    def test_the_documented_fields(self):
        doc = fixture("sync_ok_ko_en.json")
        out = parse_response(body_of("sync_ok_ko_en.json"), doc["block_s"])
        self.assertEqual([(s["start"], s["end"]) for s in out["segments"]], [(0.6, 5.4), (6.1, 13.25), (14.0, 21.4), (22.0, 40.3)])
        self.assertEqual([s["text"] for s in out["segments"]][1], "Let's start with the pre-submission timeline for the review.")
        self.assertEqual([s["confidence"] for s in out["segments"]], [0.93, 0.88, 0.91, 0.86])
        self.assertEqual([s["speaker"] for s in out["segments"]], ["1", "2", "1", "2"])
        self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None and s["compression_ratio"] is None for s in out["segments"]))
        self.assertEqual(out["language"], "en")                                      # enko: the language with the most speech time (25.4 s of 37.7)
        self.assertEqual((out["avg_logprob"], out["truncated"]), (None, False))
        self.assertEqual(out["text"], " ".join(s["text"] for s in out["segments"]))

    def test_a_language_setting_that_names_one_language_is_the_language(self):
        body = body_of("sync_ok_ko_en.json")
        for setting, expected in (("ko-KR", "ko"), ("en-US", "en"), ("ja", "ja"), ("zh-cn", "zh"), ("enko", "en")):
            self.assertEqual(parse_response(body, 41.0, setting)["language"], expected, setting)

    def test_defensive_variants(self):
        doc = fixture("sync_ok_variant.json")
        out = parse_response(body_of("sync_ok_variant.json"), doc["block_s"])
        self.assertEqual([(s["start"], s["end"], s["text"], s["confidence"], s["speaker"]) for s in out["segments"]],
                         [(1.0, 6.0, "first sentence of the block", None, None),      # confidence 1.7 and a label that is not a token are dropped
                          (8.0, 12.5, "second sentence of the block", 0.7, "2"),      # numeric strings, white space folded, speaker.label
                          (12.5, 12.5, "a sentence without any time", None, None),     # follows the one before it (in the order of the answer)
                          (20.0, 20.0, "an end before its start", None, None)])       # the end is not before the start
        self.assertEqual(out["language"], "en")

    def test_an_empty_answer_is_an_empty_transcript(self):
        out = parse_response(body_of("sync_empty.json"), 12.0)
        self.assertEqual((out["segments"], out["text"], out["language"]), ([], "", None))

    def test_text_without_segments_is_one_segment_over_the_block(self):
        out = parse_response(body_of("sync_text_only.json"), 20.0)
        self.assertEqual([(s["start"], s["end"]) for s in out["segments"]], [(0.0, 20.0)])
        self.assertEqual((out["segments"][0]["text"], out["language"]), ("회의를 시작하겠습니다 and the first item is the budget.", "ko"))
        self.assertEqual(parse_response(body_of("sync_text_only.json"), 20.0, "en-US")["language"], "en")

    def test_a_job_that_did_not_complete_is_transient_and_says_nothing_the_service_said(self):
        with self.assertRaises(EngineTransient) as ctx:
            parse_response(body_of("sync_failed.json"), 20.0)
        self.assertEqual(str(ctx.exception), "the service did not complete the recognition")
        self.assertNotIn("ZZCANARY", str(ctx.exception))
        for result in ("COMPLETED", "SUCCEEDED", "success", " completed "):
            parse_response(answer({"result": result, "segments": []}), 5.0)
        for result in ("FAILED", "RUNNING", "", "ok"):
            with self.assertRaises(EngineTransient):
                parse_response(answer({"result": result, "segments": []}), 5.0)

    def test_an_answer_that_is_not_the_document_is_never_an_empty_transcript(self):
        for raw in (b"", b"not json", b"\xff\xfe", b"[]", b"{}", b'{"result": "COMPLETED"}', b'{"segments": "x"}', b"null", b"7",
                    b"[" * 100000 + b"]" * 100000):
            with self.subTest(raw=raw[:20]), self.assertRaises(EngineTransient) as ctx:
                parse_response(raw, 5.0)
            self.assertIn("engine answer could not be", str(ctx.exception))

    def test_numbers_that_are_not_numbers_are_not_times(self):
        out = parse_response(b'{"segments": [{"start": NaN, "end": Infinity, "text": "one"}, {"start": true, "end": false, "text": "two"}, '
                             b'{"start": null, "end": [], "text": "three"}]}', 30.0)
        self.assertEqual([(s["start"], s["end"]) for s in out["segments"]], [(0.0, 0.0)] * 3)

    def test_times_past_the_block_are_clamped_to_it(self):
        out = parse_response(answer({"segments": [{"start": 50000, "end": 90000, "text": "late"}, {"start": -4000, "end": 2000, "text": "early"}]}), 30.0)
        self.assertEqual([(s["start"], s["end"]) for s in out["segments"]], [(0.0, 2.0), (30.0, 30.0)])

    def test_a_lone_surrogate_becomes_a_question_mark(self):
        out = parse_response(b'{"segments": [{"start": 0, "end": 1000, "text": "ab\\ud800cd"}]}', 5.0)
        self.assertEqual(out["segments"][0]["text"], "ab?cd")
        out["segments"][0]["text"].encode("utf-8")

    def test_more_segments_than_clean_result_keeps_are_merged_not_dropped(self):
        rows = [{"start": i * 1000, "end": i * 1000 + 900, "text": f"sentence {i}", "confidence": 0.9 - (i % 3) * 0.1} for i in range(MAX_SEGMENTS * 2 + 50)]
        out = parse_response(answer({"segments": rows}), 1000.0)
        self.assertLessEqual(len(out["segments"]), MAX_SEGMENTS)
        joined = " ".join(s["text"] for s in out["segments"])
        self.assertEqual(joined, " ".join(r["text"] for r in rows))                  # every sentence is still there, in order
        self.assertEqual((out["segments"][0]["start"], out["segments"][-1]["end"]), (0.0, rows[-1]["end"] / 1000.0))
        self.assertEqual(len(parse_response(answer({"segments": rows[:MAX_SEGMENTS]}), 1000.0)["segments"]), MAX_SEGMENTS)   # at the limit: untouched


# ======================================================================================================================
class RequestTests(ProviderCase):
    def chunk(self, engine, seconds=3.0, language=None):
        return engine.transcribe_chunk(audio(seconds, 0.25), language, None)

    def test_the_request_as_the_documentation_describes_it(self):
        engine = self.engine("clova", VOCAB)
        engine.set_track_context("remote", False, "")
        self.chunk(engine, 3.0)
        call, = self.transport.calls
        self.assertEqual((call.method, call.target), ("POST", CLOVA_ID_PATH + UPLOAD_PATH))
        self.assertEqual(call.header(KEY_HEADER), CLOVA_KEY)
        self.assertEqual(call.header("Accept"), "application/json")
        self.assertIsNone(call.header("Authorization"))
        self.assertTrue(call.header("Content-Type").startswith("multipart/form-data; boundary=mcap-"))
        parts = parse_multipart(call)
        self.assertEqual(list(parts), ["media", "params"])
        head, data = parts["media"]
        self.assertEqual((head["Content-Type"], 'filename="block.wav"' in head["Content-Disposition"]), ("audio/wav", True))
        self.assertEqual(wav_samples(data), 3 * SR)
        head, data = parts["params"]
        self.assertEqual(head["Content-Type"], "application/json")
        self.assertNotIn("filename", head["Content-Disposition"])
        self.assertEqual(json.loads(data), {"language": "enko", "completion": "sync", "wordAlignment": True, "fullText": True, "noiseFiltering": True,
                                            "diarization": {"enable": True}, "boostings": [{"words": "Acme"}, {"words": "AcmeScan-CXR"}]})

    def test_the_language_setting_is_sent_and_asr_language_is_not_used(self):
        self.cfg.asr_clova_language = "ko-KR"
        engine = self.engine("clova")
        self.chunk(engine, language="en")
        self.assertEqual(json.loads(parse_multipart(self.transport.calls[-1])["params"][1])["language"], "ko-KR")

    def test_the_vocabulary_goes_only_when_the_setting_and_the_decision_both_allow_it(self):
        def boostings(engine):
            self.chunk(engine)
            return json.loads(parse_multipart(self.transport.calls[-1])["params"][1]).get("boostings")

        self.assertEqual(boostings(self.engine("clova", VOCAB)), [{"words": "Acme"}, {"words": "AcmeScan-CXR"}])
        self.assertIsNone(boostings(self.engine("clova", VOCAB, cfg=dataclasses.replace(self.cfg, asr_send_vocab=False))))      # ASR_SEND_VOCAB=0
        decision = dataclasses.replace(self.decision("clova"), send_vocab=False)                                                  # a policy: no vocabulary to the cloud
        self.assertIsNone(boostings(self.engine("clova", VOCAB, decision=decision)))
        self.assertIsNone(boostings(self.engine("clova", None)))                                                                  # no vocabulary at all

    def test_the_path_is_the_invoke_path_of_the_setting(self):
        self.clova.path = "/external/v1/9/aa"
        self.cfg.asr_clova_invoke_url = f"https://{CLOVA_HOST}/external/v1/9/aa/"                    # a trailing slash is not part of the path
        self.chunk(self.engine("clova"))
        self.assertEqual(self.transport.calls[-1].target, "/external/v1/9/aa/recognizer/upload")
        self.clova.path = ""
        self.cfg.asr_clova_invoke_url = f"https://{CLOVA_HOST}"
        self.chunk(self.engine("clova"))
        self.assertEqual(self.transport.calls[-1].target, "/recognizer/upload")

    def test_nothing_is_sent_for_an_empty_block(self):
        out = self.engine("clova").transcribe_chunk(np.zeros(0, np.float32), None, None)
        self.assertEqual((out["segments"], self.transport.calls), ([], []))

    def test_the_key_is_in_the_header_only(self):
        self.chunk(self.engine("clova", VOCAB))
        call = self.transport.calls[0]
        self.assertNotIn(CLOVA_KEY.encode(), call.body)
        self.assertNotIn(CLOVA_KEY, call.target)

    def test_a_retry_sends_the_same_bytes(self):
        self.clova.queued = [fixture_response("error_429.json")]
        self.chunk(self.engine("clova"))
        first, second = self.transport.calls
        self.assertEqual((first.body, first.headers), (second.body, second.headers))

    def test_a_block_gets_a_long_time_limit_and_a_chunk_the_default_one(self):
        engine = self.engine("clova")
        self.chunk(engine, 900.0)
        self.assertEqual(self.transport.calls[-1].timeout, 600.0)                                   # 60 s + 900 s of audio, capped at 600 s
        self.chunk(engine, 28.0)
        self.assertEqual(self.transport.calls[-1].timeout, 90.0)                                    # ASR_REQUEST_TIMEOUT_S is the floor
        self.chunk(self.engine("clova", cfg=dataclasses.replace(self.cfg, asr_request_timeout_s=200)), 28.0)
        self.assertEqual(self.transport.calls[-1].timeout, 200.0)
        self.chunk(engine, 120.0)
        self.assertEqual(self.transport.calls[-1].timeout, 180.0)

    def test_the_engine_declares_blocks_and_nothing_else_surprising(self):
        engine = self.engine("clova")
        caps = engine_caps(engine)
        self.assertEqual((caps.kind, caps.accepts_blocks, caps.max_block_s, caps.uses_prompt, caps.supports_lid, caps.confidence, caps.residency),
                         ("cloud", True, 900.0, False, False, "opaque", "kr"))
        self.assertEqual(engine_caps(self.engine("clova", cfg=dataclasses.replace(self.cfg, asr_cloud_block_seconds=300))).max_block_s, 300.0)
        for value in (5, 5000, None):                                                               # a setting outside the range never reaches the planner
            clamped = engine_caps(self.engine("clova", cfg=dataclasses.replace(self.cfg, asr_cloud_block_seconds=value))).max_block_s
            self.assertIn(clamped, (30.0, 1800.0, 900.0))
        self.assertEqual(engine.describe()["destination"], "clova")

    def test_the_block_limit_fits_the_request_limit_of_the_policy_table(self):
        biggest = 44 + 2 * SR * asr_providers.BLOCK_SECONDS_RANGE[1] + 200_000                       # a WAV of the longest block, the params and the framing
        self.assertLess(biggest, policy.ENGINE_META["clova"]["max_request_bytes"])
        rule = self.decision("clova").hosts[CLOVA_HOST]
        self.assertEqual((rule.max_request_bytes, rule.max_response_bytes), (64 << 20, 16 << 20))

    def test_a_long_answer_with_every_word_is_accepted(self):
        words = [[i, i + 100, "word"] for i in range(0, 1_500_000, 100)]
        big = {"result": "COMPLETED", "segments": [{"start": 0, "end": 1_500_000, "text": "long sentence", "confidence": 0.9, "words": words}]}
        self.assertGreater(len(answer(big)), 262_144)                                                # the default HostRule would have refused this
        self.clova.queued = [json_response(200, big)]
        self.assertEqual(self.chunk(self.engine("clova"))["segments"][0]["text"], "long sentence")


# ======================================================================================================================
class TrackContextTests(ProviderCase):
    def diarization_sent(self, track, solo, platform=""):
        engine = self.engine("clova")
        engine.set_track_context(track, solo, platform)
        engine.transcribe_chunk(audio(2.0, 0.25), None, None)
        return json.loads(parse_multipart(self.transport.calls[-1])["params"][1])["diarization"]["enable"]

    def test_auto_follows_the_track_the_engine_was_told(self):
        self.assertIs(self.diarization_sent("mic", False), False)
        self.assertIs(self.diarization_sent("remote", False), True)
        self.assertIs(self.diarization_sent("mic", True), True)
        self.assertIs(self.diarization_sent("mic", False, "manual"), True)

    def test_a_setting_overrides_the_track(self):
        self.cfg.asr_clova_diarization = "off"
        self.assertIs(self.diarization_sent("remote", True), False)
        self.cfg.asr_clova_diarization = "on"
        self.assertIs(self.diarization_sent("mic", False), True)

    def test_an_engine_that_was_told_nothing_is_a_single_track(self):
        engine = self.engine("clova")
        engine.transcribe_chunk(audio(2.0, 0.25), None, None)
        self.assertIs(json.loads(parse_multipart(self.transport.calls[-1])["params"][1])["diarization"]["enable"], True)


# ======================================================================================================================
class ErrorMappingTests(ProviderCase):
    def chunk(self, engine=None, seconds=3.0):
        return (engine or self.engine("clova")).transcribe_chunk(audio(seconds, 0.25), None, None)

    def attempts(self):
        return len(self.transport.calls)

    def test_a_good_answer_of_the_fixture(self):
        self.clova.queued = [json_response(200, fixture("sync_ok_ko_en.json")["body"])]
        out = self.chunk(seconds=41.0)
        self.assertEqual(len(out["segments"]), 4)
        self.assertEqual(self.attempts(), 1)

    def test_401_and_403_are_authentication_errors_and_are_not_retried(self):
        for status in (401, 403):
            with self.subTest(status):
                self.transport.calls.clear()
                self.clova.queued = [json_response(status, {"status": status, "message": "ZZCANARY-the patient Kim Minsu has chest pain"})]
                with self.assertRaises(EngineAuthError) as ctx:
                    self.chunk()
                self.assertEqual((ctx.exception.status, self.attempts()), (status, 1))
                self.assertNotIn("ZZCANARY", str(ctx.exception))
        self.assertNotIn("ZZCANARY", self.everything_written())

    def test_a_wrong_key_is_a_401_of_the_service(self):
        self.store_token("a-different-key-0123456789", "clova", CLOVA_HOST)
        with self.assertRaises(EngineAuthError):
            self.chunk()
        self.assertNothingLeaked("a-different-key-0123456789")

    def test_429_waits_the_retry_after_and_tries_again(self):
        self.clova.queued = [fixture_response("error_429.json")]
        out = self.chunk()
        self.assertEqual(out["segments"][0]["text"][:6], "액미 blo")
        self.assertEqual((self.sleep.waits, self.attempts()), ([4.0], 2))

    def test_429_that_never_ends_is_transient_after_the_attempts_with_the_status(self):
        self.clova.queued = [fixture_response("error_429.json")] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.status, self.attempts(), self.sleep.waits), (429, 3, [4.0, 4.0]))
        self.assertNotIn("ZZCANARY", str(ctx.exception))
        self.assertNothingLeaked()

    def test_503_without_a_header_backs_off_and_500_gets_one_retry(self):
        self.clova.queued = [json_response(503, {})] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.status, self.attempts(), self.sleep.waits), (503, 3, [1.0, 2.5]))
        self.transport.calls.clear()
        self.sleep.waits.clear()
        self.clova.queued = [json_response(500, {})] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.status, self.attempts(), self.sleep.waits), (500, 2, [1.0]))

    def test_another_4xx_is_a_chunk_local_error_that_is_not_retried(self):
        for status in (400, 404, 413, 422):
            with self.subTest(status):
                self.transport.calls.clear()
                self.clova.queued = [json_response(status, {"message": "ZZCANARY-the patient Kim Minsu has chest pain"})]
                with self.assertRaises(EngineHttpError) as ctx:
                    self.chunk()
                self.assertNotIsInstance(ctx.exception, EngineTransient)
                self.assertFalse(ctx.exception.retryable)
                self.assertEqual((ctx.exception.status, self.attempts()), (status, 1))
        self.assertNotIn("ZZCANARY", self.everything_written())

    def test_a_200_that_says_failed_is_transient_and_the_text_of_the_service_stays_out(self):
        self.clova.queued = [fixture_response("sync_failed.json")]
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual(self.attempts(), 1)
        self.assertNothingLeaked()
        self.assertNotIn("ZZCANARY", str(ctx.exception))

    def test_an_answer_that_cannot_be_read_is_transient(self):
        self.clova.queued = [json_response(200, raw=b"<html>gateway</html>")]
        with self.assertRaises(EngineTransient):
            self.chunk()

    def test_a_network_failure_is_transient_after_the_attempts(self):
        self.clova.queued = [egress.EgressError("connect")] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((self.attempts(), ctx.exception.code), (3, "connect"))

    def test_a_redirect_is_never_followed_and_closes_the_destination(self):
        self.clova.queued = [Response(302, {"location": "https://elsewhere.example.com/"}, b"", 0, 0, 0)]
        with self.assertRaises(EnginePolicyDenied) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.code, self.attempts()), ("redirect", 1))

    def test_a_missing_key_says_how_to_store_one_and_sends_nothing(self):
        self.security.remove()
        with self.assertRaises(EngineAuthError) as ctx:
            self.chunk()
        self.assertEqual(ctx.exception.code, "missing")
        self.assertIn("mcap asr-engines secret set clova", str(ctx.exception))
        self.assertEqual(self.attempts(), 0)

    def test_the_key_is_read_once_per_run_and_forgotten_on_release(self):
        engine = self.engine("clova")
        for _ in range(3):
            self.chunk(engine)
        self.assertEqual(self.security.reads("MeetingCapture ASR clova"), 1)
        engine.release()
        self.chunk(engine)
        self.assertEqual(self.security.reads("MeetingCapture ASR clova"), 2)

    def test_the_daily_cap_stops_a_block_before_anything_is_sent(self):
        self.cfg.asr_cloud_daily_minutes = 1
        engine = self.engine("clova", cap_minutes=1.0)
        with self.assertRaises(EngineCapReached):
            self.chunk(engine, 120.0)
        self.assertEqual(self.attempts(), 0)

    def test_a_closed_lane_sends_nothing(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.code, self.attempts()), ("local_only", 0))
        self.assertEqual(self.security.reads("MeetingCapture ASR clova"), 0)                        # the key is not even read


# ======================================================================================================================
class DestinationTests(ProviderCase):
    def binding(self, url):
        cfg = dataclasses.replace(self.cfg, asr_clova_invoke_url=url)
        return policy.consent_binding(cfg, "clova")

    def test_the_binding_of_the_invoke_url(self):
        binding, why = self.binding(CLOVA_URL)
        self.assertEqual((why, binding["host"], binding["port"], binding["region"], binding["model"], binding["protocol"], binding["backend_kind"]),
                         (None, CLOVA_HOST, 443, "", "clova-speech-long", "clova-speech-upload", "cloud"))
        self.assertNotIn(CLOVA_ID_PATH, json.dumps(binding))                                         # the domain id is not part of what a consent says

    def test_only_https_naver_cloud_gateways_are_destinations(self):
        for url in (f"http://{CLOVA_HOST}/external/v1/1/a", "ftp://clovaspeech-gw.ncloud.com/x", "clovaspeech-gw.ncloud.com/external/v1/1/a",
                    "https://evil.example.com/external/v1/1/a", "https://ncloud.com/x", "https://.ncloud.com/x", "https://notncloud.com/x",
                    "https://clovaspeech-gw.ncloud.com.evil.example.com/x", "https://127.0.0.1/x", "https://[::1]/x", "https://10.0.0.1:8443/x",
                    f"https://user:pw@{CLOVA_HOST}/x", f"https://{CLOVA_HOST}/x?key=1", f"https://{CLOVA_HOST}/x#frag", f"https://{CLOVA_HOST}./x",
                    f"https://{CLOVA_HOST}/a//b", f"https://{CLOVA_HOST}/a/../b", f"https://{CLOVA_HOST}/a b", f"https://{CLOVA_HOST}/a;b",
                    "https://클로바.ncloud.com/x", f"https://{CLOVA_HOST}:99999/x", f"https://{CLOVA_HOST}:0/x", f"https://{CLOVA_HOST}/" + "a" * 300):
            with self.subTest(url=url):
                self.assertEqual(self.binding(url), (None, "bad-host"))
        self.assertEqual(self.binding("")[1], "not-configured")
        self.assertEqual(self.binding("   ")[1], "not-configured")

    def test_the_gateways_of_the_finance_and_government_clouds_are_gateways_too(self):
        for host in ("clovaspeech-gw.fin-ncloud.com", "clovaspeech-gw.gov-ncloud.com", "CLOVASPEECH-GW.NCLOUD.COM"):
            with self.subTest(host):
                binding, why = self.binding(f"https://{host}/external/v1/1/ab")
                self.assertEqual((why, binding["host"]), (None, host.lower()))
                self.assertTrue(host_allowed(host))
        for host in ("ncloud.com", ".ncloud.com", "evil.com", "", None, 7):
            self.assertFalse(host_allowed(host), host)

    def test_a_destination_that_is_not_usable_means_local_whisper_and_no_engine(self):
        cfg = dataclasses.replace(self.cfg, asr_clova_invoke_url="http://clovaspeech-gw.ncloud.com/x")
        decision = make_decision(cfg, "clova", consents=(clova_consent(),))
        self.assertEqual((decision.primary, decision.allow_egress, decision.engine_hosts), ("whisper", False, {}))
        self.assertIn("bad-host", " ".join(decision.notes))

    def test_a_consent_for_another_host_or_port_does_not_cover_it(self):
        for kw in ({"host": "other-gw.ncloud.com"}, {"port": 8443}, {"region": "koreacentral"}, {"model": "other"}, {"protocol": "other"}):
            with self.subTest(kw):
                entry = clova_consent(**{k: v for k, v in kw.items() if k != "host"}, **({"host": kw["host"]} if "host" in kw else {}))
                decision = make_decision(self.cfg, "clova", consents=(entry,))
                self.assertEqual(decision.primary, "whisper")
                self.assertIn("consent-mismatch", " ".join(decision.notes))
        self.assertEqual(self.decision("clova").primary, "clova")

    def test_the_decision_carries_one_host_only_and_the_guard_knows_just_that_one(self):
        decision = self.decision("clova")
        self.assertEqual((decision.engine_hosts, set(decision.hosts)), ({"clova": CLOVA_HOST}, {CLOVA_HOST}))
        self.assertEqual(self.engine("clova").guard.hosts, (CLOVA_HOST,))

    def test_a_settings_file_edited_after_the_decision_sends_nothing_and_reads_no_key(self):
        decision = self.decision("clova")
        edited = dataclasses.replace(self.cfg, asr_clova_invoke_url="https://clovaspeech-gw.fin-ncloud.com/external/v1/1/ab")
        engine = self.engine("clova", cfg=edited, decision=decision)
        for call in (engine.load, lambda: engine.transcribe_chunk(audio(2.0, 0.25), None, None)):
            with self.assertRaises(EnginePolicyDenied) as ctx:
                call()
            self.assertEqual(ctx.exception.code, "host_not_consented")
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        unusable = dataclasses.replace(self.cfg, asr_clova_invoke_url="")
        with self.assertRaises(EnginePolicyDenied):
            self.engine("clova", cfg=unusable, decision=decision).load()

    def test_a_decision_for_a_host_outside_the_gateways_is_refused_before_the_key_is_read(self):
        decision = self.decision("clova")
        host = "evil.example.com"
        rule = dataclasses.replace(decision.hosts[CLOVA_HOST], host=host)
        hand_made = dataclasses.replace(decision, engine_hosts={"clova": host}, hosts={host: rule})
        cfg = dataclasses.replace(self.cfg, asr_clova_invoke_url=f"https://{host}/x")
        engine = self.engine("clova", cfg=cfg, decision=hand_made)
        with self.assertRaises(EnginePolicyDenied) as ctx:
            engine.transcribe_chunk(audio(2.0, 0.25), None, None)
        self.assertEqual(ctx.exception.code, "host_not_allowed")
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        self.assertTrue(engine.preflight()[0].startswith("the destination is not a CLOVA Speech gateway"))

    def test_a_port_other_than_443_is_refused(self):
        cfg = dataclasses.replace(self.cfg, asr_clova_invoke_url=f"https://{CLOVA_HOST}:8443/x")
        decision = make_decision(cfg, "clova", consents=(clova_consent(port=8443),))
        engine = self.engine("clova", cfg=cfg, decision=decision)
        with self.assertRaises(EnginePolicyDenied) as ctx:
            engine.transcribe_chunk(audio(2.0, 0.25), None, None)
        self.assertEqual((ctx.exception.code, self.transport.calls), ("host_not_allowed", []))

    def test_the_credential_is_bound_to_host_and_port(self):
        self.assertEqual(asr_creds.service_name("clova"), "MeetingCapture ASR clova")
        self.assertTrue(asr_creds.account_name(CLOVA_HOST, 443).endswith(f"@{CLOVA_HOST}:443"))
        self.store_token("other-key-0123456789", "clova", "clovaspeech-gw.fin-ncloud.com")      # a key for another gateway is not this one's
        self.engine("clova").transcribe_chunk(audio(2.0, 0.25), None, None)
        self.assertEqual(self.transport.calls[0].header(KEY_HEADER), CLOVA_KEY)

    def test_preflight_says_whether_a_key_is_stored_without_reading_it(self):
        engine = self.engine("clova")
        self.assertEqual(engine.preflight(), [])
        self.assertEqual(self.security.reads(), 0)
        self.security.remove()
        self.assertTrue(engine.preflight()[0].startswith("no credential is stored for this destination"))


# ======================================================================================================================
class ProvenanceAndLeakTests(ProviderCase):
    def test_the_usage_line_of_a_block(self):
        engine = self.engine("clova")
        engine.transcribe_chunk(audio(40.0, 0.25), None, None)
        line, = usage_lines(self.cfg)
        self.assertEqual((line["engine"], line["kind"], line["host"], line["op"], line["status"], line["outcome"], line["attempt"], line["requests"]),
                         ("clova", "cloud", CLOVA_HOST, "chunk", 200, "ok", 1, 1))
        self.assertEqual((line["audio_s"], line["est_usd"]), (40.0, None))
        self.assertGreater(line["bytes_out"], 1_280_000)
        self.assertEqual(engine.usage(), {"requests": 1, "lid_requests": 0, "audio_s": 40.0, "bytes": line["bytes_out"]})

    def test_a_retried_block_is_counted_per_attempt(self):
        self.clova.queued = [fixture_response("error_429.json")]
        self.engine("clova").transcribe_chunk(audio(20.0, 0.25), None, None)
        lines = usage_lines(self.cfg)
        self.assertEqual([(l["outcome"], l["attempt"], l["audio_s"]) for l in lines], [("http_429", 1, 20.0), ("ok", 2, 20.0)])

    def test_the_provenance_names_the_engine_the_blocks_and_the_seconds_and_no_host(self):
        engine = self.engine("clova")
        engine.transcribe_chunk(audio(40.0, 0.25), None, None)
        engine.transcribe_chunk(audio(30.0, 0.25), None, None)
        block = engine.provenance()
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["region"], block["protocol"]),
                         ("clova", "cloud", "cloud", "clova", "kr", "clova-speech-upload"))
        self.assertEqual((block["chunks"], block["sent"]["requests"], block["sent"]["audio_s"]), ({"clova": 2}, 2, 70.0))
        text = json.dumps(block)
        for needle in (CLOVA_HOST, CLOVA_ID_PATH, CLOVA_KEY, "ncloud"):
            self.assertNotIn(needle, text)

    def test_nothing_secret_or_foreign_reaches_a_log_a_state_file_a_usage_line_or_an_error(self):
        engine = self.engine("clova", VOCAB)
        self.clova.queued = [fixture_response("error_401.json")]
        with self.assertRaises(EngineAuthError):
            engine.transcribe_chunk(audio(3.0, 0.25), None, None)
        engine.reset_secret()
        self.clova.queued = [fixture_response("sync_failed.json"), fixture_response("error_429.json"), fixture_response("sync_ok_ko_en.json")]
        for _ in range(2):
            try:
                engine.transcribe_chunk(audio(3.0, 0.25), None, None)
            except EngineError:
                pass
        engine.preflight()
        engine.describe()
        self.assertNothingLeaked()
        # the host is in the usage line (the one place that names it) and nowhere else the shared drive could see
        self.assertIn(CLOVA_HOST, (self.cfg.asr_usage_path).read_text(encoding="utf-8"))
        self.assertNotIn(CLOVA_HOST, json.dumps(engine.provenance()))
        self.assertNotIn(CLOVA_HOST, json.dumps(engine.describe()))


# ======================================================================================================================
def tone_prepared(seconds=60.0):
    """Two tracks that are not copies of each other (the echo check would drop the microphone's words): different regions and pitch."""
    mic = speech_track(seconds, ((2.0, 14.0), (30.0, 41.0)), 220.0)
    remote = speech_track(seconds, ((8.0, 20.0), (44.0, 56.0)), 330.0)
    return audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, seconds, {})


class PipelineTests(ProviderCase):
    """CLOVA through the whole stage: the policy decision, the router, ``transcribe_tracks`` with real VAD (energy) over synthetic tone tracks."""

    def setUp(self):
        super().setUp()
        self.cfg.asr_vad = "energy"
        self.cfg.mic_aec = "0"
        self.cfg.asr_language = "en"
        run_cfg, decision = make_run(self.cfg, "clova", consents=(clova_consent(),))
        self.run_cfg = run_cfg
        real = asr_router.build_engine
        patcher = mock.patch.object(asr_router, "build_engine", lambda cfg, vocab, progress=None: real(
            cfg, vocab, progress=progress, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep, clock=self.clock))
        patcher.start()
        self.addCleanup(patcher.stop)

    def params_of(self, call):
        return json.loads(parse_multipart(call)["params"][1])

    def test_a_meeting_goes_out_as_one_block_per_track_with_the_right_speaker_setting(self):
        out = asr.transcribe_tracks(tone_prepared(), self.run_cfg, VOCAB)
        posts = self.posts(UPLOAD_PATH)
        self.assertEqual(len(posts), 2)                                                              # one request per track, not one per 28 s chunk
        by_track = {}
        for call in posts:
            by_track["mic" if not by_track else "remote"] = self.params_of(call)["diarization"]["enable"]
        self.assertEqual(by_track, {"mic": False, "remote": True})
        self.assertEqual(out["stats"]["mic"]["blocks"], 1)
        self.assertEqual((out["stats"]["mic"]["chunks"], out["stats"]["remote"]["blocks"]), (2, 1))
        self.assertEqual(out["asr"]["engine"], "clova")
        self.assertEqual((out["asr"]["kind"], out["asr"]["privacy"], out["asr"]["chunks"], out["asr"]["destination"]), ("cloud", "cloud", {"clova": 2}, "clova"))
        self.assertGreater(out["asr"]["sent"]["audio_s"], 40.0)
        self.assertIn("clova", out["asr_model"])
        self.assertNotIn("ZZCANARY", json.dumps(out))

    def test_the_segments_of_a_block_land_where_the_speech_was(self):
        out = asr.transcribe_tracks(tone_prepared(), self.run_cfg, VOCAB)
        mic = [s for s in out["segments"] if s["track"] == "mic"]
        self.assertEqual(len(mic), 1)
        self.assertAlmostEqual(mic[0]["start"], 1.7 + 0.1, places=1)                                  # the first chunk starts 0.3 s before the region (energy VAD: about)
        self.assertGreaterEqual(mic[0]["start"], 1.0)
        self.assertLess(mic[0]["end"], 15.0)                                                          # cut at the end of the first chunk: the answer ran over the gap

    def test_only_one_track_means_that_track_is_solo(self):
        prepared = tone_prepared()
        prepared.missing = ["remote"]
        asr.transcribe_tracks(prepared, self.run_cfg, VOCAB)
        call, = self.posts(UPLOAD_PATH)
        self.assertIs(self.params_of(call)["diarization"]["enable"], True)

    def test_a_manual_session_separates_speakers_on_both_tracks(self):
        prepared = tone_prepared()
        prepared.platform = "manual"
        asr.transcribe_tracks(prepared, self.run_cfg, VOCAB)
        self.assertEqual([self.params_of(c)["diarization"]["enable"] for c in self.posts(UPLOAD_PATH)], [True, True])

    def test_dual_is_ignored_and_the_vocabulary_goes_as_boostings(self):
        cfg = dataclasses.replace(self.run_cfg, asr_strategy="dual")
        out = asr.transcribe_tracks(tone_prepared(), cfg, VOCAB)
        self.assertEqual(len(self.posts(UPLOAD_PATH)), 2)
        self.assertNotIn("strategy", out["stats"]["mic"])
        self.assertNotIn("dual", out["asr"])
        self.assertEqual(self.params_of(self.posts(UPLOAD_PATH)[0])["boostings"], [{"words": "Acme"}, {"words": "AcmeScan-CXR"}])

    def test_nothing_secret_is_in_the_transcript_the_log_or_the_usage_file(self):
        out = asr.transcribe_tracks(tone_prepared(), self.run_cfg, VOCAB)
        text = json.dumps(out, ensure_ascii=False)
        for needle in (CLOVA_KEY, CLOVA_ID_PATH, CLOVA_HOST):
            self.assertNotIn(needle, text)
        self.assertNothingLeaked()

    def test_an_unreachable_service_with_a_whisper_fallback_hands_the_block_to_whisper(self):
        from asr_support import FakeLocalEngine
        run_cfg, _ = make_run(self.cfg, "clova", "whisper", consents=(clova_consent(),))
        run_cfg = dataclasses.replace(run_cfg, asr_vad="energy", mic_aec="0", asr_language="en")
        self.clova.queued = [egress.EgressError("connect")] * 12
        local = FakeLocalEngine(lambda a, language, prompt: {"text": "x", "language": "en", "avg_logprob": -0.2,
                                                           "segments": [{"start": 0.5, "end": 3.0, "text": "local words", "avg_logprob": -0.2, "no_speech_prob": 0.01,
                                                                         "compression_ratio": 1.1, "temperature": 0.0}]})
        with mock.patch.object(asr_router.asr_engines, "get_engine", return_value=local):
            out = asr.transcribe_tracks(tone_prepared(), run_cfg, VOCAB)
        self.assertEqual(out["asr"]["fallbacks"], 2)
        self.assertEqual(len(local.calls), 2)                                                         # one whole block per track
        self.assertEqual(sorted({s["text"] for s in out["segments"]}), ["local words"])

    def test_a_meeting_that_is_local_only_never_builds_the_engine(self):
        run_cfg, decision = make_run(self.cfg, "clova", consents=(clova_consent(),), local_only=True)
        self.assertEqual((decision.primary, decision.allow_egress, decision.local_only), ("whisper", False, True))
        self.assertEqual(self.transport.calls, [])

    def test_a_meeting_switched_to_local_only_while_it_runs_sends_no_more_blocks(self):
        self.gate.close_after(3)                                                  # the first block gets through (router, engine and guard each ask), the second does not
        with self.assertRaisesRegex(RuntimeError, "ASR failed for every chunk of the remote track: EnginePolicyDenied"):
            asr.transcribe_tracks(tone_prepared(), self.run_cfg, VOCAB)
        self.assertEqual(len(self.posts(UPLOAD_PATH)), 1)


if __name__ == "__main__":
    unittest.main()
