"""asr_azure.py (SPEC 18): the Azure fast-transcription adapter.

The engine runs through a REAL asr_router/asr_http/EgressGuard stack in front of an in-process Transport whose handler is ``FakeAzure``: a
small service written from the documentation (key header, api-version, a multipart body with an ``audio`` and a ``definition`` part, the
answer documents of tests/fixtures/azure). The fixtures are DOCUMENT-DERIVED until the first live call replaces them (their header says so
and a test pins it); nothing here proves what the service really does. No socket opens (NoNetworkCase), the Keychain is the fake
`security` of notes_cli_support, the relay's key file is a temp file, time is a FakeClock.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import hashlib
import io
import json
import logging
import math
import os
import re
import subprocess
import sys
import time
import types
import unittest
import wave
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import numpy as np

from asr_support import (AZURE_HOST, AZURE_KEY, CANARY_FRAGMENTS, CANARY_TEXT, MACHINE, TOKEN, AsrCase, ClosableGate, FakeLocalEngine,
                         FakeTransport, audio, consent_entry, json_response, make_decision, make_run, usage_lines)
from golden import make_golden as mg
from test_asr_remote import RemoteCase

from mcap import apikey, asr, asr_azure, asr_creds, asr_engines, asr_server as S, egress, policy, vad
from mcap.asr_azure import (API_VERSION, CHUNK_REFUSALS, ENDPOINT_REFUSALS, KEY_HEADER, REFUSAL_STREAK, REQUEST_TARGET, TRANSCRIBE_PATH, AzureFastEngine,
                            EndpointRefused, build_definition, definition_json, destination_residency, host_allowed, multipart_body, parse_fast_response,
                            parse_locales, phrase_terms)
from mcap.asr_engines import EngineAuthError, EngineCapReached, EngineCaps, EngineError, EnginePolicyDenied, EngineTransient, engine_caps
from mcap.asr_http import EngineHttpError, wav16
from mcap.asr_router import RoutedEngine, build_engine, build_member
from mcap.egress import EgressGuard, Response
from mcap.vocab import Vocab, parse_vocab_text

logging.getLogger("mcap").addHandler(logging.NullHandler())

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "azure"
REPO = Path(__file__).resolve().parents[2]
FIXTURE_NAMES = ("fast_ok_ko_en.json", "fast_ok_offset_variant.json", "fast_empty.json", "fast_error_429.json", "definition_expected.json")
VOCAB = parse_vocab_text("Acme\nAcmeScan-CXR\nAcme = 애크미 | 액미\n")          # the aliases are what the service gets wrong: never phrases
JAPAN = "japaneast"
JAPAN_HOST = f"{JAPAN}.api.cognitive.microsoft.com"
SOUTH = "koreasouth"                                                             # the second Korean region (still "kr")
SOUTH_HOST = f"{SOUTH}.api.cognitive.microsoft.com"
EAST = "eastus"
EAST_HOST = f"{EAST}.api.cognitive.microsoft.com"
CUSTOM_HOST = "acme-speech.cognitiveservices.azure.com"
LEAK_WORDS = CANARY_FRAGMENTS + (AZURE_KEY,)


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def fixture_response(name: str, **headers) -> Response:
    """The recorded-looking answer of a fixture as the guard would hand it over: UTF-8 body, lower-case header names."""
    doc = fixture(name)
    return json_response(doc["status"], raw=json.dumps(doc["body"], ensure_ascii=False).encode("utf-8"), headers={**doc.get("headers", {}), **headers})


def body_of(doc: dict) -> bytes:
    return json.dumps(doc, ensure_ascii=False).encode("utf-8")


def parse_multipart(call) -> dict:
    """The parts of a request body: ``{name: (headers, data)}``. Checks the framing on the way (opening delimiter, CRLF around every part,
    closing delimiter), so a body the service would not read fails here."""
    found = re.fullmatch(r"multipart/form-data; boundary=([A-Za-z0-9-]+)", call.header("Content-Type") or "")
    assert found, call.header("Content-Type")
    marker = b"--" + found.group(1).encode("ascii")
    pieces = call.body.split(marker)
    assert pieces[0] == b"" and pieces[-1] == b"--\r\n", (pieces[0][:20], pieces[-1][:20])
    parts = {}
    for raw in pieces[1:-1]:
        assert raw.startswith(b"\r\n") and raw.endswith(b"\r\n")
        head, sep, data = raw[2:-2].partition(b"\r\n\r\n")
        assert sep
        headers = dict(line.split(": ", 1) for line in head.decode("ascii").split("\r\n"))
        parts[re.search(r'name="([^"]+)"', headers["Content-Disposition"]).group(1)] = (headers, data)
    return parts


class Records(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage() + (self.format(record) if record.exc_info else ""))


# ======================================================================================================================
class FakeAzure:
    """The service as the documentation describes it, enough for the engine: ``fake(call) -> Response`` is the handler of a ``FakeTransport``.
    A request without the right key header is 401, a request to another path or api-version 404; otherwise the answer is the next of
    ``queued`` (a ``Response``, an exception, or a callable of the call) or, by default, one phrase over the middle of the chunk whose text
    names the number of samples that arrived. ``requests`` holds the parts of every accepted request."""

    def __init__(self):
        self.key = AZURE_KEY
        self.queued: list = []
        self.requests: list = []

    def __call__(self, call):
        if call.header(KEY_HEADER) != self.key:
            return json_response(401, {"error": {"code": "401", "message": "Access denied due to invalid subscription key."}})
        query = parse_qs(urlsplit(call.target).query)
        if call.method != "POST" or call.path != TRANSCRIBE_PATH or query != {"api-version": [API_VERSION]}:
            return json_response(404, {"error": {"code": "404", "message": "Resource not found"}})
        parts = parse_multipart(call)
        self.requests.append(parts)
        if self.queued:
            item = self.queued.pop(0)
            return item(call) if callable(item) and not isinstance(item, (Response, BaseException)) else item
        return self.answer(parts)

    @staticmethod
    def answer(parts) -> Response:
        samples = (len(parts["audio"][1]) - 44) // 2
        millis = samples * 1000 // 16000
        text = f"액미 chunk {samples} samples"
        doc = {"durationMilliseconds": millis, "combinedPhrases": [{"channel": 0, "text": text}],
               "phrases": [{"channel": 0, "offsetMilliseconds": 100, "durationMilliseconds": max(millis - 200, 1), "text": text,
                            "locale": "ko-KR", "confidence": 0.9}]}
        return json_response(200, raw=body_of(doc))


class AzureCase(AsrCase):
    """An ``AzureFastEngine`` over a real guard in front of ``FakeAzure``. The Azure key is stored in the fake Keychain for the Korea Central
    host; ``rand`` is 0.5 (no jitter: the waits are exactly the schedule)."""

    def setUp(self):
        super().setUp()
        self.gate = ClosableGate("asr_cloud")
        self.store_token(AZURE_KEY, "azure", AZURE_HOST)
        self.azure = FakeAzure()
        self.transport = FakeTransport(handler=self.azure, clock=self.clock)
        self.records = Records()
        mcap_log = logging.getLogger("mcap")
        mcap_log.addHandler(self.records)
        self.addCleanup(mcap_log.removeHandler, self.records)
        self.addCleanup(mcap_log.setLevel, mcap_log.level)
        mcap_log.setLevel(logging.DEBUG)                  # the pipeline log runs at INFO: a key logged at INFO or DEBUG must reach the leak checks too

    def decision(self, cfg=None, **kw):
        kw.setdefault("consents", ("azure",))
        return make_decision(cfg or self.cfg, "azure", **kw)

    def engine(self, vocab=None, *, cfg=None, decision=None, **kw):
        """An ``AzureFastEngine`` as ``asr_router.build_member`` makes one (guard with the one host of the decision, lane gate)."""
        cfg = cfg or self.cfg
        decision = decision or self.decision(cfg)
        host = decision.engine_hosts["azure"]
        guard = EgressGuard({host: decision.hosts[host]}, engine_id="azure", consent_id=decision.consent_ids["azure"], transport=self.transport,
                            clock=self.clock, pre_connect=self.gate)
        return AzureFastEngine(cfg, vocab, decision, guard, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock, **kw)

    def chunk(self, engine, seconds=3.0, language="en"):
        return engine.transcribe_chunk(audio(seconds, 0.25), language, None)

    def posts(self):
        return self.transport.requests(TRANSCRIBE_PATH)

    def definition_sent(self, index=-1) -> dict:
        return json.loads(self.azure.requests[index]["definition"][1].decode("ascii"))

    def everything_written(self):
        parts = [p.read_bytes().decode("utf-8", "replace") for p in sorted(self.root.rglob("*")) if p.is_file()]
        return "\n".join(parts + self.records.lines)

    def assertNothingLeaked(self, *extra):
        text = self.everything_written()
        for needle in LEAK_WORDS + tuple(extra):
            self.assertNotIn(needle, text)

    def usage(self):
        return usage_lines(self.cfg)


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

    def test_the_answers_have_the_shape_of_the_documented_documents(self):
        ok = fixture("fast_ok_ko_en.json")["body"]
        self.assertEqual({"durationMilliseconds", "combinedPhrases", "phrases"}, set(ok))
        self.assertEqual({"channel", "offsetMilliseconds", "durationMilliseconds", "text", "words", "locale", "confidence"}, set(ok["phrases"][0]))
        variant = fixture("fast_ok_offset_variant.json")["body"]
        self.assertTrue({"offset", "duration"} <= set(variant["phrases"][0]) and "offsetMilliseconds" not in variant["phrases"][0])
        self.assertEqual(fixture("fast_empty.json")["body"]["phrases"], [])
        throttled = fixture("fast_error_429.json")
        self.assertEqual((throttled["status"], throttled["headers"]["retry-after"]), (429, "3"))


# ======================================================================================================================
class DefinitionTests(AsrCase):
    def cfg_with(self, **over):
        return dataclasses.replace(self.cfg, **over)

    def test_the_documented_cases_build_the_expected_definition(self):
        expected = fixture("definition_expected.json")
        vocab = parse_vocab_text(expected["vocabulary_txt"])
        self.assertGreaterEqual(len(expected["cases"]), 5)
        for case in expected["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(build_definition(vocab, self.cfg_with(**case["config"])), case["definition"])

    def test_the_phrases_are_the_canonical_terms_never_the_aliases(self):
        definition = build_definition(VOCAB, self.cfg)
        self.assertEqual(definition["phraseList"]["phrases"], ["Acme", "AcmeScan-CXR"])
        self.assertNotIn("액미", json.dumps(definition, ensure_ascii=False))

    def test_the_repository_vocabulary_goes_in_file_order_without_its_aliases(self):
        vocab = parse_vocab_text((REPO / "config" / "vocabulary.txt").read_text(encoding="utf-8"))
        phrases = build_definition(vocab, self.cfg)["phraseList"]["phrases"]
        self.assertEqual(phrases, vocab.terms)
        self.assertEqual(phrases[0], vocab.terms[0])

    def test_nothing_is_sent_when_the_vocabulary_switch_is_off_or_there_is_no_vocabulary(self):
        self.assertNotIn("phraseList", build_definition(VOCAB, self.cfg_with(asr_send_vocab=False)))
        self.assertNotIn("phraseList", build_definition(None, self.cfg))
        self.assertNotIn("phraseList", build_definition(Vocab(), self.cfg))
        self.assertNotIn("phraseList", build_definition(types.SimpleNamespace(terms="Acme"), self.cfg))
        self.assertNotIn("phraseList", build_definition(Vocab(terms=[5, None, "", "   ", "\x07"]), self.cfg))
        self.assertNotIn("phraseList", build_definition(VOCAB, types.SimpleNamespace()))             # a config without the switch reads as off

    def test_the_locales_key_is_there_only_when_the_setting_names_some(self):
        self.assertNotIn("locales", build_definition(VOCAB, self.cfg_with(asr_azure_locales="")))
        self.assertNotIn("locales", build_definition(VOCAB, self.cfg_with(asr_azure_locales=" , ;")))
        self.assertEqual(build_definition(VOCAB, self.cfg_with(asr_azure_locales="ko-KR,en-US"))["locales"], ["ko-KR", "en-US"])
        self.assertEqual(list(build_definition(VOCAB, self.cfg_with(asr_azure_locales="ko-KR"))), ["profanityFilterMode", "locales", "phraseList"])

    def test_locale_spelling_is_normalised_and_junk_is_left_out(self):
        self.assertEqual(parse_locales("ko_kr, EN-us ko-KR zh-hans-cn"), ["ko-KR", "en-US", "zh-Hans-CN"])
        self.assertEqual(parse_locales(["ja-jp", "x", 5, "ja-JP"]), ["ja-JP"])
        self.assertEqual(parse_locales("korean"), [])                 # not a locale at all: dropped, never guessed
        self.assertEqual(parse_locales("ko-KR;;123, ko-KR"), ["ko-KR"])
        self.assertEqual((parse_locales(None), parse_locales(5), parse_locales("")), ([], [], []))

    def test_junk_locales_are_counted_in_one_warning_without_the_text(self):
        records = Records()
        logging.getLogger("mcap").addHandler(records)
        self.addCleanup(logging.getLogger("mcap").removeHandler, records)
        self.cfg.asr_azure_locales = "ko-KR, ZZ-CANARY-bad_text!, 12, en-US"
        self.engine_for_settings()
        warned = [line for line in records.lines if "ASR_AZURE_LOCALES" in line]
        self.assertEqual(len(warned), 1)
        self.assertIn("2 entries are not a locale", warned[0])
        self.assertNotIn("CANARY", warned[0])

    def engine_for_settings(self):
        decision = make_decision(self.cfg, "azure", consents=("azure",))
        guard = EgressGuard({AZURE_HOST: decision.hosts[AZURE_HOST]}, engine_id="azure", consent_id="c", transport=FakeTransport())
        return AzureFastEngine(self.cfg, VOCAB, decision, guard)

    def test_the_bias_is_the_setting_clamped_to_its_range(self):
        for given, sent in ((1.0, 1.0), (0.0, 0.0), (2.0, 2.0), (1.5, 1.5), (7, 2.0), (-3.0, 0.0), (float("nan"), 1.0), (True, 1.0), ("2", 1.0)):
            with self.subTest(given=given):
                self.assertEqual(build_definition(VOCAB, self.cfg_with(asr_azure_bias=given))["phraseList"]["biasingWeight"], sent)
        weight = build_definition(VOCAB, self.cfg)["phraseList"]["biasingWeight"]
        self.assertIsInstance(weight, float)

    def test_phrase_terms_filter_dedupe_and_cap(self):
        terms = ["B", "a  b", "A  B", "", "   ", "x" * 101, "x" * 100, "tab\there", "bell\x07", "한국어", "한국어", "A\ud800", "ok term", 5, None]
        self.assertEqual(phrase_terms(Vocab(terms=terms)), ["B", "a b", "x" * 100, "한국어", "ok term"])
        many = phrase_terms(Vocab(terms=[f"term{i}" for i in range(2000)]))
        self.assertEqual((len(many), many[0], many[-1]), (asr_azure.MAX_PHRASES, "term0", f"term{asr_azure.MAX_PHRASES - 1}"))
        self.assertEqual(phrase_terms(None), [])

    def test_the_definition_part_is_ascii_json_and_round_trips(self):
        definition = build_definition(parse_vocab_text("한국어 용어\n510(k)\n"), self.cfg_with(asr_azure_locales="ko-KR"))
        raw = definition_json(definition)
        self.assertTrue(raw.isascii())
        self.assertEqual(json.loads(raw), definition)
        self.assertEqual(raw.decode("ascii"), '{"profanityFilterMode":"None","locales":["ko-KR"],"phraseList":{"phrases":["\\ud55c\\uad6d\\uc5b4 \\uc6a9\\uc5b4",'
                                              '"510(k)"],"biasingWeight":1.0}}')


# ======================================================================================================================
class MultipartTests(unittest.TestCase):
    WAV = b"RIFF\x24\x00\x00\x00WAVEfmt " + bytes(range(40))

    def test_the_bytes_are_exactly_the_documented_framing(self):
        definition = {"profanityFilterMode": "None", "locales": ["ko-KR"]}
        body, content_type = multipart_body(self.WAV, definition)
        meta = b'{"profanityFilterMode":"None","locales":["ko-KR"]}'
        boundary = "mcap-" + hashlib.sha256(meta + b"\0" + self.WAV).hexdigest()[:32]
        self.assertEqual(content_type, f"multipart/form-data; boundary={boundary}")
        marker = b"--" + boundary.encode()
        self.assertEqual(body, marker + b'\r\nContent-Disposition: form-data; name="audio"; filename="chunk.wav"\r\nContent-Type: audio/wav\r\n\r\n'
                         + self.WAV + b"\r\n" + marker + b'\r\nContent-Disposition: form-data; name="definition"\r\nContent-Type: application/json\r\n\r\n'
                         + meta + b"\r\n" + marker + b"--\r\n")

    def test_the_same_content_gives_the_same_bytes_and_other_content_another_boundary(self):
        definition = {"profanityFilterMode": "None"}
        first, again = multipart_body(self.WAV, definition), multipart_body(self.WAV, dict(definition))
        self.assertEqual(first, again)
        self.assertNotEqual(first[1], multipart_body(self.WAV + b"x", definition)[1])
        self.assertNotEqual(first[1], multipart_body(self.WAV, {"profanityFilterMode": "Masked"})[1])

    def test_a_boundary_that_occurs_in_a_part_is_derived_again(self):
        digests = iter(["a" * 64, "b" * 64, "c" * 64])
        fake = types.SimpleNamespace(sha256=lambda data: types.SimpleNamespace(hexdigest=lambda: next(digests)))
        wav = self.WAV + b"\r\n--mcap-" + b"a" * 32 + b"\r\n"
        with mock.patch.object(asr_azure, "hashlib", fake):
            body, content_type = multipart_body(wav, {"profanityFilterMode": "None"})
        self.assertEqual(content_type, "multipart/form-data; boundary=mcap-" + "b" * 32)
        self.assertEqual(body.count(b"--mcap-" + b"b" * 32), 3)                # two openings and the closing delimiter
        self.assertEqual(body.count(b"--mcap-" + b"a" * 32), 1)                # only the one inside the audio


# ======================================================================================================================
class ParseTests(unittest.TestCase):
    def parse(self, name, **kw):
        doc = fixture(name)
        return parse_fast_response(body_of(doc["body"]), kw.get("chunk_s", doc["chunk_s"]))

    def test_the_current_field_names(self):
        result = self.parse("fast_ok_ko_en.json")
        first, second = result["segments"]
        self.assertAlmostEqual(first["start"], 0.24)
        self.assertAlmostEqual(first["end"], 5.36)
        self.assertEqual(first["text"], "안녕하세요 오늘은 액미 AcmeScan-CXR 510(k) 제출 일정을 논의하겠습니다.")
        self.assertAlmostEqual(second["start"], 6.0)
        self.assertAlmostEqual(second["end"], 11.8)
        self.assertEqual(second["text"], "Let's start with the FDA pre-submission timeline.")
        self.assertEqual(result["language"], "en")                      # 5.8 s of en-US against 5.12 s of ko-KR: the one with more speech
        self.assertEqual(result["text"], first["text"] + " " + second["text"])
        self.assertIs(result["truncated"], False)

    def test_the_other_field_names_give_the_same_kind_of_answer(self):
        result = self.parse("fast_ok_offset_variant.json")
        first, second = result["segments"]
        self.assertAlmostEqual(first["start"], 0.48)
        self.assertAlmostEqual(first["end"], 2.58)
        self.assertAlmostEqual(second["start"], 3.4)
        self.assertAlmostEqual(second["end"], 7.3)
        self.assertEqual((first["text"], second["text"]), ("네 그렇게 진행하죠.", "다음 주 화요일에 다시 확인하겠습니다."))
        self.assertEqual(result["language"], "ko")                       # a locale without a region is a language too

    def test_both_spellings_in_one_answer_prefer_the_long_names(self):
        body = body_of({"phrases": [{"offsetMilliseconds": 1000, "offset": 9000, "durationMilliseconds": 500, "duration": 9, "text": "x"}]})
        seg = parse_fast_response(body, 5.0)["segments"][0]
        self.assertEqual((seg["start"], seg["end"]), (1.0, 1.5))

    def test_no_log_probability_is_ever_made_up_from_the_confidence(self):
        for name in ("fast_ok_ko_en.json", "fast_ok_offset_variant.json"):
            result = self.parse(name)
            self.assertIsNone(result["avg_logprob"])
            for seg in result["segments"]:
                self.assertEqual((seg["avg_logprob"], seg["no_speech_prob"], seg["compression_ratio"], seg["temperature"]), (None, None, None, 0.0))
        confidences = [s["confidence"] for s in self.parse("fast_ok_ko_en.json")["segments"]] + [s["confidence"] for s in
                                                                                                self.parse("fast_ok_offset_variant.json")["segments"]]
        self.assertEqual(confidences, [0.91, 0.95, 0.88, None])         # kept as the opaque score it is, only where the service gave one

    def test_an_empty_answer_is_an_empty_result_not_an_error(self):
        result = self.parse("fast_empty.json")
        self.assertEqual((result["segments"], result["text"], result["language"], result["avg_logprob"]), ([], "", None, None))
        for body in ({"phrases": []}, {"combinedPhrases": []}, {"combinedPhrases": [{"text": "  "}], "phrases": [{"text": ""}, {"text": "   "}, 5]}):
            with self.subTest(body=body):
                self.assertEqual(parse_fast_response(body_of(body), 2.0)["segments"], [])

    def test_combined_phrases_alone_is_one_segment_over_the_whole_chunk(self):
        body = body_of({"durationMilliseconds": 2500, "combinedPhrases": [{"channel": 0, "text": "hello  there\nfriend"}]})
        result = parse_fast_response(body, 2.4)
        self.assertEqual(len(result["segments"]), 1)
        seg = result["segments"][0]
        self.assertEqual((seg["start"], seg["end"], seg["text"], seg["confidence"]), (0.0, 2.4, "hello there friend", None))
        self.assertEqual((result["text"], result["language"]), ("hello there friend", None))
        unknown_length = parse_fast_response(body, 0)                     # the chunk length not known: the answer's own duration
        self.assertEqual(unknown_length["segments"][0]["end"], 2.5)
        self.assertEqual(parse_fast_response(body_of({"combinedPhrases": [{"text": "x"}], "phrases": []}), 3.0)["segments"][0]["end"], 3.0)

    def test_combined_phrases_with_empty_first_entry_takes_the_first_text(self):
        body = body_of({"combinedPhrases": [{"channel": 0, "text": ""}, {"channel": 1, "text": "second"}]})
        self.assertEqual(parse_fast_response(body, 1.0)["segments"][0]["text"], "second")

    def test_a_phrase_without_a_usable_time_never_loses_the_text(self):
        for phrases in ([{"text": "a", "locale": "en-US"}, {"text": "b", "offsetMilliseconds": 1000}],
                        [{"text": "a", "offset": True, "duration": 5}, {"text": "b", "offset": "soon"}],
                        [{"text": "a", "offsetMilliseconds": None}, {"text": "b", "offsetMilliseconds": [1]}]):
            with self.subTest(phrases=phrases):
                with_combined = parse_fast_response(body_of({"phrases": phrases, "combinedPhrases": [{"text": "a b"}]}), 4.0)
                self.assertEqual([(s["start"], s["end"], s["text"]) for s in with_combined["segments"]], [(0.0, 4.0, "a b")])
                without = parse_fast_response(body_of({"phrases": phrases}), 4.0)
                self.assertEqual([(s["start"], s["end"], s["text"]) for s in without["segments"]], [(0.0, 4.0, "a b")])

    def test_non_finite_times_are_missing_times(self):
        raw = b'{"phrases":[{"offsetMilliseconds":NaN,"durationMilliseconds":Infinity,"text":"x"}],"combinedPhrases":[{"text":"x"}]}'
        self.assertEqual([(s["start"], s["end"]) for s in parse_fast_response(raw, 3.0)["segments"]], [(0.0, 3.0)])
        raw = b'{"phrases":[{"offset":1e999,"text":"x"}]}'
        self.assertEqual(parse_fast_response(raw, 3.0)["segments"][0]["text"], "x")

    def test_numeric_strings_are_milliseconds_too(self):
        seg = parse_fast_response(body_of({"phrases": [{"offset": "1500", "duration": "500.5", "text": "x"}]}), 5.0)["segments"][0]
        self.assertEqual(seg["start"], 1.5)
        self.assertAlmostEqual(seg["end"], 2.0005)

    def test_a_missing_duration_runs_to_the_next_phrase_and_the_last_to_the_chunk_end(self):
        body = body_of({"phrases": [{"offset": 3000, "text": "two"}, {"offset": 1000, "text": "one"}, {"offset": 4500, "duration": 200, "text": "three"}]})
        segs = parse_fast_response(body, 6.0)["segments"]
        self.assertEqual([(s["text"], s["start"], round(s["end"], 6)) for s in segs], [("one", 1.0, 3.0), ("two", 3.0, 4.5), ("three", 4.5, 4.7)])

    def test_phrases_come_out_in_time_order_and_a_negative_time_starts_at_zero(self):
        body = body_of({"phrases": [{"offset": 5000, "duration": 1000, "text": "late"}, {"offset": -500, "duration": 1000, "text": "early"}]})
        segs = parse_fast_response(body, 8.0)["segments"]
        self.assertEqual([(s["text"], s["start"], s["end"]) for s in segs], [("early", 0.0, 1.0), ("late", 5.0, 6.0)])

    def test_the_language_is_the_locale_with_the_most_speech(self):
        def lang(*rows):
            phrases = [{"offset": 1000 * i, "duration": d, "text": f"t{i}", **({"locale": loc} if loc is not None else {})}
                       for i, (d, loc) in enumerate(rows)]
            return parse_fast_response(body_of({"phrases": phrases}), 20.0)["language"]
        self.assertEqual(lang((900, "ko-KR"), (200, "en-US"), (200, "en-GB")), "ko")        # 900 ms of ko against 400 ms of en
        self.assertEqual(lang((500, "ko-KR"), (300, "en-US"), (300, "en-GB")), "en")        # two English locales add up: 600 ms against 500 ms
        self.assertEqual(lang((200, "ko-KR"), (900, "en-US")), "en")
        self.assertEqual(lang((1000, None), (100, "ko-KR")), "ko")
        self.assertEqual(lang((1000, "korean"), (100, "Zh-Hans-CN")), "zh")
        self.assertIsNone(lang((1000, None)))
        self.assertIsNone(lang((1000, "")))
        self.assertIsNone(lang((1000, "x")))

    def test_text_is_one_line_and_can_be_written_to_disk(self):
        body = b'{"phrases":[{"offset":0,"duration":1000,"text":"a\\ud800b \\n c"}]}'
        text = parse_fast_response(body, 2.0)["segments"][0]["text"]
        self.assertEqual(text, "a?b c")
        text.encode("utf-8")

    def test_an_answer_that_is_not_the_document_is_transient_with_a_fixed_message(self):
        hostile = CANARY_TEXT.encode("utf-8")
        for body in (b"", b"not json", hostile, b"\xff\xfe\x00", b"[]", b"null", b"{}", b'{"phrases":"x"}', b'{"error":{"code":"x"}}',
                     b'{"phrases":{"a":1},"combinedPhrases":3}', b"[" * 5000, b'{"a":' * 3000):
            with self.subTest(body=body[:20]):
                with self.assertRaises(EngineTransient) as caught:
                    parse_fast_response(body, 2.0)
                self.assertIn(str(caught.exception), ("the engine answer could not be read", "the engine answer could not be used"))
                self.assertTrue(caught.exception.retryable)
        for junk in (None, 5, "text", object()):
            with self.subTest(junk=junk), self.assertRaises(EngineTransient):
                parse_fast_response(junk, 2.0)

    def test_unknown_fields_and_other_types_are_ignored(self):
        body = body_of({"phrases": [{"offset": 0, "duration": 1000, "text": "x", "words": "not a list", "confidence": "high", "locale": 7,
                                     "channel": "left"}, "junk", None, {"text": 5}, {"offset": 0}], "unknownFutureField": [1, 2]})
        result = parse_fast_response(body, 2.0)
        self.assertEqual([(s["text"], s["confidence"]) for s in result["segments"]], [("x", None)])
        self.assertIsNone(result["language"])


# ======================================================================================================================
class DeclarationTests(AzureCase):
    def test_the_engine_declares_what_it_is(self):
        engine = self.engine()
        self.assertEqual((engine.engine_id, engine.kind, engine.residency, engine.uses_prompt, engine.confidence, engine.supports_lid),
                         ("azure", "cloud", "kr", False, "opaque", False))
        self.assertEqual(engine_caps(engine), EngineCaps(kind="cloud", uses_prompt=False, supports_lid=False, timing="segment", confidence="opaque",
                                                         max_chunk_s=28.0, residency="kr"))
        self.assertEqual(engine.chunk_params, {"max_inner_gap_s": 4.0})
        self.assertEqual(engine.model, "fast-transcription")
        self.assertEqual(engine.progress_tag(), "[cloud]")
        self.assertIsNone(engine.prompt_text_seen())

    def test_the_declarations_agree_with_the_policy_table_and_the_registry(self):
        meta = policy.ENGINE_META["azure"]
        self.assertEqual((meta["kind"], meta["residency"], meta["lane"], meta["backend_kind"], meta["protocol"], meta["model"]),
                         (AzureFastEngine.kind, AzureFastEngine.residency, "asr_cloud", "cloud", "azure-fast-transcription", "fast-transcription"))
        self.assertIs(asr_engines.engine_class("azure"), AzureFastEngine)
        self.assertEqual(asr_engines.REGISTRY["azure"], "mcap.asr_azure:AzureFastEngine")
        self.assertEqual(set(asr_engines.REGISTRY), set(policy.ENGINE_META))

    def test_a_wider_pause_merges_into_one_request(self):
        regions = [(1.0, 3.0), (6.5, 9.0)]                                    # a pause of 3.5 s
        whisper = vad.plan_chunks(regions, np.zeros(1000, np.float32), 12.0, labels=["", ""], **{})
        azure = vad.plan_chunks(regions, np.zeros(1000, np.float32), 12.0, labels=["", ""], **self.engine().chunk_params)
        self.assertEqual((len(whisper), len(azure)), (2, 1))

    def test_describe_and_provenance_name_a_label_never_the_host_or_the_key(self):
        engine = self.engine()
        self.assertEqual(engine.destination_label(), "azure/koreacentral")
        self.assertNotIn(AZURE_HOST, json.dumps(engine.describe()))
        self.assertEqual(engine.provenance()["privacy"], "local")             # nothing sent yet
        self.chunk(engine)
        block = engine.provenance()
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["region"], block["protocol"], block["model"]),
                         ("azure", "cloud", "cloud", "azure/koreacentral", "kr", "azure-fast-transcription", "fast-transcription"))
        self.assertEqual((block["consent_id"], block["chunks"], block["sent"]["requests"]), ("c-azure", {"azure": 1}, 1))
        text = json.dumps(block)
        for needle in (AZURE_HOST, AZURE_KEY):
            self.assertNotIn(needle, text)
        self.assertEqual(asr._clean_provenance(block), block)

    def test_load_checks_the_destination_without_touching_the_network_or_the_keychain(self):
        engine = self.engine()
        engine.load()
        engine.load()
        self.assertEqual((self.transport.calls, self.security.calls()), ([], []))
        self.assertIsNone(engine.health)

    def test_an_engine_without_a_destination_refuses_to_load(self):
        decision = dataclasses.replace(self.decision(), hosts={}, engine_hosts={})
        guard = EgressGuard({}, engine_id="azure", consent_id="c", transport=self.transport)
        engine = AzureFastEngine(self.cfg, None, decision, guard)
        with self.assertRaises(EnginePolicyDenied) as caught:
            engine.load()
        self.assertEqual(caught.exception.code, "no_host")
        with self.assertRaises(EnginePolicyDenied):
            engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(self.transport.calls, [])

    def test_build_member_builds_it_from_the_real_registry_with_a_guard_for_the_one_host(self):
        member = build_member(self.cfg, VOCAB, self.decision(), "azure", transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep,
                              rand=lambda: 0.5, clock=self.clock)
        self.assertIsInstance(member, AzureFastEngine)
        self.assertEqual(member.guard.hosts, (AZURE_HOST,))
        self.chunk(member)
        self.assertEqual(len(self.posts()), 1)

    def test_a_router_with_azure_first_and_whisper_second_reports_the_cloud_and_never_the_prompt_to_azure(self):
        local = FakeLocalEngine()
        cfg, _ = make_run(self.cfg, "azure", "whisper", consents=("azure",))
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            router = build_engine(cfg, VOCAB, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5,
                                  clock=self.clock)
        self.assertIsInstance(router, RoutedEngine)
        self.assertIsInstance(router.primary, AzureFastEngine)
        self.assertEqual((router.kind, router.supports_lid, router.chunk_params), ("cloud", False, {"max_inner_gap_s": 4.0}))
        router.load()
        router.transcribe_chunk(audio(2.0), "ko", "KO-FRAME: Acme")
        self.assertEqual(local.calls, [])                                       # azure answered; the prompt never went anywhere
        self.assertNotIn(b"KO-FRAME", self.posts()[0].body)

    def test_the_default_local_pipeline_never_imports_this_module(self):
        code = ("import sys; sys.path.insert(0, %r); import mcap.asr, mcap.asr_engines, mcap.lanes, mcap.pipeline, mcap.cli; "
                "print('mcap.asr_azure' in sys.modules)") % str(REPO / "pipeline")
        out = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True, text=True, timeout=120, check=True)
        self.assertEqual(out.stdout.strip(), "False")


# ======================================================================================================================
class WireTests(AzureCase):
    def test_a_chunk_is_one_multipart_post_to_the_consented_host(self):
        engine = self.engine(VOCAB)
        result = self.chunk(engine, 3.0, "ko")
        (call,) = self.posts()
        self.assertEqual((call.method, call.rule.host, call.rule.port, call.target), ("POST", AZURE_HOST, 443, REQUEST_TARGET))
        self.assertEqual(call.target, "/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
        self.assertEqual(call.header("Ocp-Apim-Subscription-Key"), AZURE_KEY)
        self.assertIsNone(call.header("Authorization"))
        self.assertEqual(call.header("Accept"), "application/json")
        parts = parse_multipart(call)
        self.assertEqual(set(parts), {"audio", "definition"})
        self.assertEqual(parts["audio"][0]["Content-Type"], "audio/wav")
        self.assertEqual(parts["definition"][0]["Content-Type"], "application/json")
        self.assertEqual(parts["audio"][1], wav16(audio(3.0, 0.25)))
        self.assertEqual(json.loads(parts["definition"][1]), {"profanityFilterMode": "None",
                                                              "phraseList": {"phrases": ["Acme", "AcmeScan-CXR"], "biasingWeight": 1.0}})
        self.assertEqual((result["text"], result["language"]), ("액미 chunk 48000 samples", "ko"))
        seg = result["segments"][0]
        self.assertEqual((seg["start"], seg["end"], seg["avg_logprob"], seg["no_speech_prob"], seg["compression_ratio"]), (0.1, 2.9, None, None, None))
        self.assertIsNone(result["avg_logprob"])

    def test_the_audio_part_is_a_wav_of_16_khz_mono_16_bit(self):
        self.chunk(self.engine(), 1.5)
        with wave.open(io.BytesIO(parse_multipart(self.posts()[0])["audio"][1])) as wav:
            self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()), (1, 2, 16000, 24000))

    def test_the_language_and_the_prompt_are_not_part_of_the_request(self):
        engine = self.engine(VOCAB)
        for language, prompt in (("ko", None), ("en", "EN-FRAME: Acme"), (None, "x"), ("", None)):
            engine.transcribe_chunk(audio(2.0, 0.25), language, prompt)
        bodies = {c.body for c in self.posts()}
        self.assertEqual(len(bodies), 1)
        self.assertNotIn(b"EN-FRAME", next(iter(bodies)))

    def test_a_retry_resends_exactly_the_same_bytes(self):
        self.azure.queued = [json_response(503, {"error": {"code": "unavailable"}})]
        self.chunk(self.engine(VOCAB))
        first, second = self.posts()
        self.assertEqual((first.body, first.header("Content-Type")), (second.body, second.header("Content-Type")))
        self.assertEqual(self.sleep.waits, [1.0])

    def test_empty_audio_sends_nothing_and_reads_no_key(self):
        result = self.engine().transcribe_chunk(np.zeros(0, np.float32), "en", None)
        self.assertEqual((result["segments"], result["text"]), ([], ""))
        self.assertEqual((self.transport.calls, self.security.reads(), self.usage()), ([], 0, []))

    def test_the_key_is_read_once_for_the_engine_and_again_after_a_release(self):
        engine = self.engine()
        self.chunk(engine)
        self.chunk(engine)
        self.assertEqual(self.security.reads(), 1)
        self.assertEqual(self.security.reads("MeetingCapture ASR azure"), 1)
        argv = self.security.argvs("find-generic-password")[0]
        self.assertEqual(argv[argv.index("-a") + 1], asr_creds.account_name(AZURE_HOST, 443))
        self.assertTrue(argv[argv.index("-a") + 1].endswith(f"@{AZURE_HOST}:443"))
        engine.release()
        self.chunk(engine)
        self.assertEqual(self.security.reads(), 2)

    def test_the_vocabulary_goes_out_only_when_both_the_setting_and_the_decision_allow_it(self):
        self.chunk(self.engine(VOCAB))
        self.assertIn("phraseList", self.definition_sent())
        org = dataclasses.replace(policy.absent_policy(), send_vocab={"server": True, "cloud": False})       # a company policy: cloud gets no terms
        decision = self.decision(org=org)
        self.assertFalse(decision.send_vocab)
        self.chunk(self.engine(VOCAB, decision=decision))
        self.assertNotIn("phraseList", self.definition_sent())
        self.cfg.asr_send_vocab = False                                       # the user's switch
        decision = self.decision()
        self.assertFalse(decision.send_vocab)
        self.chunk(self.engine(VOCAB, decision=decision))
        self.assertNotIn("phraseList", self.definition_sent())
        self.cfg.asr_send_vocab = True
        self.chunk(self.engine(None))
        self.assertNotIn("phraseList", self.definition_sent())                # no vocabulary at all

    def test_locales_and_bias_come_from_the_settings(self):
        self.cfg.asr_azure_locales, self.cfg.asr_azure_bias = "ko-KR,en-US", 1.5
        self.chunk(self.engine(VOCAB))
        self.assertEqual(self.definition_sent(), {"profanityFilterMode": "None", "locales": ["ko-KR", "en-US"],
                                                  "phraseList": {"phrases": ["Acme", "AcmeScan-CXR"], "biasingWeight": 1.5}})

    def test_hostile_answers_are_bounded_by_the_shared_cleaning(self):
        phrases = [{"offset": 100 * i, "duration": 50, "text": f"p{i}"} for i in range(500)]
        phrases.append({"offset": 1, "duration": 10 ** 12, "text": "x" * 100_000})
        self.azure.queued = [json_response(200, raw=body_of({"phrases": phrases[:150]})), json_response(200, raw=body_of({"phrases": phrases[-1:]}))]
        engine = self.engine()
        self.assertEqual(len(self.chunk(engine)["segments"]), 150)
        wide = self.chunk(engine)["segments"][0]
        self.assertLessEqual(wide["end"], 3.0 + 1.0)
        self.assertEqual(len(wide["text"]), 8000)

    def test_a_combined_text_alone_spans_the_chunk_that_was_sent(self):
        self.azure.queued = [json_response(200, raw=body_of({"combinedPhrases": [{"channel": 0, "text": "all of it"}], "phrases": []}))]
        seg = self.chunk(self.engine(), 3.0)["segments"][0]
        self.assertEqual((seg["start"], seg["end"], seg["text"]), (0.0, 3.0, "all of it"))

    def test_the_fixtures_go_through_the_whole_engine(self):
        for name, texts in (("fast_ok_ko_en.json", 2), ("fast_ok_offset_variant.json", 2), ("fast_empty.json", 0)):
            with self.subTest(name):
                self.azure.queued = [fixture_response(name)]
                self.assertEqual(len(self.chunk(self.engine(), fixture(name)["chunk_s"])["segments"]), texts)


# ======================================================================================================================
class ErrorMappingTests(AzureCase):
    def fails(self, exc_type, *answers, seconds=3.0):
        self.azure.queued = list(answers)
        with self.assertRaises(exc_type) as caught:
            self.chunk(self.engine(), seconds)
        for needle in LEAK_WORDS:
            self.assertNotIn(needle, str(caught.exception))
        return caught.exception

    def test_a_rejected_key_is_an_auth_error_and_is_not_retried(self):
        self.azure.key = "another-key"
        with self.assertRaises(EngineAuthError) as caught:
            self.chunk(self.engine())
        self.assertEqual((caught.exception.status, len(self.posts()), self.sleep.waits), (401, 1, []))
        self.assertEqual(str(caught.exception), "the server refused the credential (HTTP 401)")
        self.assertEqual(self.usage()[0]["outcome"], "http_401")

    def test_a_403_is_an_auth_error_too(self):
        exc = self.fails(EngineAuthError, json_response(403, {"error": {"code": "403", "message": CANARY_TEXT}}))
        self.assertEqual((exc.status, len(self.posts())), (403, 1))

    def test_a_429_waits_for_retry_after_and_goes_on(self):
        self.azure.queued = [fixture_response("fast_error_429.json")]
        result = self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [3.0])
        self.assertEqual(len(self.posts()), 2)
        self.assertEqual(len(result["segments"]), 1)
        self.assertEqual([u["outcome"] for u in self.usage()], ["http_429", "ok"])

    def test_a_429_that_does_not_stop_is_transient_after_the_attempts(self):
        exc = self.fails(EngineTransient, *[fixture_response("fast_error_429.json")] * 5)
        self.assertEqual((exc.status, len(self.posts()), self.sleep.waits), (429, 3, [3.0, 3.0]))
        self.assertEqual(str(exc), "the server answered HTTP 429 after 3 attempt(s)")
        self.assertTrue(exc.retryable)

    def test_a_retry_after_longer_than_the_time_limit_is_transient_at_once(self):
        self.cfg.asr_remote_max_wait_s = 30
        exc = self.fails(EngineTransient, fixture_response("fast_error_429.json", **{"Retry-After": "500"}))
        self.assertEqual((exc.status, len(self.posts()), self.sleep.waits), (429, 1, []))

    def test_a_retry_after_that_is_not_a_number_falls_back_to_the_schedule(self):
        self.azure.queued = [fixture_response("fast_error_429.json", **{"Retry-After": "Fri, 16 Oct 2026 09:00:00 GMT"})]
        self.chunk(self.engine())
        self.assertEqual(self.sleep.waits, [1.0])

    def test_a_503_without_retry_after_follows_the_schedule(self):
        exc = self.fails(EngineTransient, *[json_response(503, {"error": {"code": "x"}})] * 5)
        self.assertEqual((exc.status, len(self.posts()), self.sleep.waits), (503, 3, [1.0, 2.5]))

    def test_a_500_gets_one_retry(self):
        exc = self.fails(EngineTransient, json_response(500, {}), json_response(500, {}), json_response(500, {}))
        self.assertEqual((exc.status, len(self.posts()), self.sleep.waits), (500, 2, [1.0]))

    def test_a_400_is_a_refused_request_not_a_waiting_condition(self):
        exc = self.fails(EngineHttpError, json_response(400, {"code": "InvalidRequest", "message": CANARY_TEXT}))
        self.assertEqual((exc.status, exc.code, exc.retryable, len(self.posts()), self.sleep.waits), (400, None, False, 1, []))
        self.assertEqual(str(exc), "the server refused the request (HTTP 400)")
        self.assertNotIsInstance(exc, EngineTransient)

    def test_a_404_for_a_wrong_api_version_is_the_same(self):
        exc = self.fails(EngineHttpError, json_response(404, {"error": {"code": "404", "message": CANARY_TEXT}}))
        self.assertEqual((exc.status, len(self.posts())), (404, 1))

    def test_a_status_that_says_the_endpoint_does_not_take_the_request_is_a_denial_for_the_router_at_once(self):
        for status in ENDPOINT_REFUSALS:
            with self.subTest(status=status):
                exc = self.fails(EngineHttpError, json_response(status, {"error": {"code": "x", "message": CANARY_TEXT}}))
                self.assertIsInstance(exc, EndpointRefused)
                self.assertIsInstance(exc, EnginePolicyDenied)                      # what the router reads as a trigger: the fallback takes over
                self.assertNotIsInstance(exc, EngineTransient)
                self.assertEqual((exc.status, exc.retryable), (status, False))
                self.assertTrue(str(exc).startswith(f"the server refused the request (HTTP {status}"), str(exc))

    def test_one_refusal_that_may_be_about_the_chunk_alone_is_not_a_denial(self):
        self.assertEqual(ENDPOINT_REFUSALS + CHUNK_REFUSALS, (404, 405, 415, 400, 413, 422))
        for status in CHUNK_REFUSALS:
            with self.subTest(status=status):
                exc = self.fails(EngineHttpError, json_response(status, {"error": {"code": "x", "message": CANARY_TEXT}}))
                self.assertIs(type(exc), EngineHttpError)                           # a plain refusal of this chunk: the router does not see a trigger
                self.assertNotIsInstance(exc, EnginePolicyDenied)

    def test_the_refusals_of_a_streak_in_a_row_become_a_denial_and_a_good_answer_starts_the_count_again(self):
        engine = self.engine()
        refuse = json_response(422, {"error": {"code": "x", "message": CANARY_TEXT}})

        def refused(*answers):
            self.azure.queued = list(answers)
            with self.assertRaises(EngineHttpError) as caught:
                self.chunk(engine)
            return caught.exception
        for _ in range(REFUSAL_STREAK - 1):
            self.assertIs(type(refused(refuse)), EngineHttpError)
        self.chunk(engine)                                                          # answered well: the streak is gone
        for _ in range(REFUSAL_STREAK - 1):
            self.assertIs(type(refused(refuse)), EngineHttpError)
        self.assertIs(type(refused(json_response(400, {}))), EndpointRefused)       # the REFUSAL_STREAK-th in a row, whatever mix of 400/413/422
        self.assertIs(type(refused(json_response(413, {}))), EndpointRefused)       # and it stays one until a good answer
        self.chunk(engine)
        self.assertIs(type(refused(refuse)), EngineHttpError)

    def test_failures_that_are_not_refusals_neither_count_nor_end_a_streak(self):
        engine, seen = self.engine(), []
        for answers in ([json_response(422, {})], [json_response(409, {})], [json_response(429, {}, {"retry-after": "1"})] * 5, [json_response(400, {})]):
            self.azure.queued = list(answers)
            with self.assertRaises(EngineError) as caught:
                self.chunk(engine)
            seen.append(type(caught.exception))
        self.assertEqual(seen, [EngineHttpError, EngineHttpError, EngineTransient, EngineHttpError])           # 422, 400: two refusals so far
        self.azure.queued = [json_response(413, {})]
        with self.assertRaises(EndpointRefused):
            self.chunk(engine)

    def test_another_4xx_stays_a_refusal_of_this_chunk_only(self):
        exc = self.fails(EngineHttpError, json_response(409, {"error": {"code": "conflict"}}))
        self.assertIs(type(exc), EngineHttpError)
        self.assertNotIsInstance(exc, EnginePolicyDenied)

    def test_an_unreachable_service_is_transient_and_counts_no_audio(self):
        exc = self.fails(EngineTransient, *[ConnectionRefusedError("down: " + CANARY_TEXT)] * 3)
        self.assertEqual((exc.code, len(self.posts()), self.sleep.waits), ("connect", 3, [1.0, 2.5]))
        self.assertEqual([(u["requests"], u["audio_s"], u["outcome"]) for u in self.usage()], [(0, 0.0, "error:connect")] * 3)

    def test_a_redirect_is_never_followed(self):
        redirect = Response(302, {"location": "https://evil.example.com/steal"}, b"", 0, 0, 0)
        exc = self.fails(EnginePolicyDenied, redirect)
        self.assertEqual((exc.code, len(self.posts())), ("redirect", 1))

    def test_an_answer_that_is_not_the_document_is_transient_and_is_not_asked_again(self):
        exc = self.fails(EngineTransient, json_response(200, raw=CANARY_TEXT.encode()))
        self.assertEqual((str(exc), len(self.posts())), ("the engine answer could not be read", 1))
        exc = self.fails(EngineTransient, json_response(200, {"error": {"code": "InternalError", "message": CANARY_TEXT}}))
        self.assertEqual(str(exc), "the engine answer could not be used")

    def test_every_error_message_is_a_fixed_sentence(self):
        for answer in (json_response(429, {"error": {"message": CANARY_TEXT}}, {"x-canary": CANARY_TEXT, "retry-after": "0"}),
                       json_response(401, {"error": {"code": "CANARY", "message": CANARY_TEXT}}),
                       json_response(500, raw=CANARY_TEXT.encode()), json_response(418, raw=CANARY_TEXT.encode())):
            self.azure.queued = [answer] * 5
            with self.assertRaises(EngineError) as caught:
                self.chunk(self.engine())
            for needle in CANARY_FRAGMENTS:
                self.assertNotIn(needle, str(caught.exception))
                self.assertNotIn(needle, repr(caught.exception.__dict__))


# ======================================================================================================================
class GateAndCapTests(AzureCase):
    def test_a_closed_lane_sends_nothing_and_reads_no_key(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            self.chunk(self.engine())
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))

    def test_a_lane_that_closes_after_the_first_chunk_stops_the_second(self):
        engine = self.engine()
        self.chunk(engine)
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            self.chunk(engine)
        self.assertEqual(len(self.posts()), 1)

    def test_the_daily_cap_is_checked_before_the_key_and_the_socket(self):
        decision = self.decision()
        self.cfg.asr_cloud_daily_minutes = 0                                    # the engine reads the cap when it is built; the decision was made before
        with self.assertRaises(EngineCapReached):
            self.chunk(self.engine(decision=decision))
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))


# ======================================================================================================================
class KeyBindingAndHostTests(AzureCase):
    def doctored(self, host, port=443):
        """A decision nobody should be able to build (a host the policy table would never have produced), to see the engine's own last line."""
        real = self.decision()
        rule = dataclasses.replace(real.hosts[AZURE_HOST], host=host, port=port)
        return dataclasses.replace(real, hosts={host: rule}, engine_hosts={"azure": host})

    def test_the_key_is_bound_to_the_host_and_port_of_its_keychain_item(self):
        cfg = dataclasses.replace(self.cfg, asr_azure_region=SOUTH)
        decision = self.decision(cfg, consents=(consent_entry("azure", host=SOUTH_HOST, region=SOUTH),))
        self.assertEqual(decision.engine_hosts["azure"], SOUTH_HOST)
        engine = self.engine(cfg=cfg, decision=decision)
        with self.assertRaises(EngineAuthError) as caught:                      # the key was stored for Korea Central only
            self.chunk(engine)
        self.assertEqual((caught.exception.code, self.transport.calls), ("missing", []))
        argv = self.security.argvs("find-generic-password")[0]
        self.assertEqual(argv[argv.index("-a") + 1], asr_creds.account_name(SOUTH_HOST, 443))
        self.store_token(AZURE_KEY, "azure", SOUTH_HOST)
        self.chunk(engine)
        self.assertEqual({c.rule.host for c in self.posts()}, {SOUTH_HOST})
        self.assertEqual(asr_creds.secret_status("azure", AZURE_HOST, 8443)["present"], False)
        self.assertEqual(asr_creds.secret_status("azure", AZURE_HOST, 443)["present"], True)

    def test_a_host_outside_the_two_azure_suffixes_gets_neither_the_key_nor_a_byte(self):
        for host in ("evil.example.com", "api.cognitive.microsoft.com", "evilapi.cognitive.microsoft.com", "cognitiveservices.azure.com",
                     f"{AZURE_HOST}.evil.com", "x.cognitiveservices.azure.com.evil.net", "localhost", "10.0.0.1"):
            with self.subTest(host=host):
                engine = self.engine(decision=self.doctored(host))
                for call in (engine.load, lambda: self.chunk(engine)):
                    with self.assertRaises(EnginePolicyDenied) as caught:
                        call()
                    self.assertEqual(caught.exception.code, "host_not_allowed")
                    self.assertNotIn(host, str(caught.exception))
                self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))

    def test_a_port_other_than_443_is_refused_for_azure(self):
        engine = self.engine(decision=self.doctored(AZURE_HOST, 8443))
        with self.assertRaises(EnginePolicyDenied) as caught:
            self.chunk(engine)
        self.assertEqual((caught.exception.code, self.transport.calls, self.security.reads()), ("host_not_allowed", [], 0))

    def test_the_azure_suffix_rule(self):
        for host in (AZURE_HOST, "my-speech.cognitiveservices.azure.com", "KoreaCentral.API.cognitive.microsoft.com", " a.api.cognitive.microsoft.com "):
            self.assertTrue(host_allowed(host), host)
        for host in ("", None, 5, "api.cognitive.microsoft.com", ".api.cognitive.microsoft.com", "cognitiveservices.azure.com",
                     "azure.com", "a.cognitive.microsoft.com", "evilapi.cognitive.microsoft.com", f"{AZURE_HOST}.evil.com"):
            self.assertFalse(host_allowed(host), host)

    def test_an_azure_host_setting_outside_the_suffixes_makes_no_destination_at_all(self):
        for host in ("evil.example.com", "api.cognitive.microsoft.com", f"{AZURE_HOST}.evil.com", "10.0.0.1", "a b.cognitiveservices.azure.com"):
            with self.subTest(host=host):
                cfg = dataclasses.replace(self.cfg, asr_azure_host=host)
                self.assertEqual(policy.consent_binding(cfg, "azure"), (None, "bad-host"))
                decision = self.decision(cfg, consents=(consent_entry("azure", host=host),))
                self.assertEqual((decision.primary, decision.engine_hosts, decision.hosts, decision.allow_egress), ("whisper", {}, {}, False))
                with self.assertRaises(EnginePolicyDenied):
                    build_member(cfg, None, decision, "azure", transport_factory=lambda: self.transport)
        self.assertEqual(self.transport.calls, [])

    def test_the_host_comes_from_the_region_and_from_the_consent_binding(self):
        binding, why = policy.consent_binding(self.cfg, "azure")
        self.assertEqual((binding["host"], binding["port"], binding["kind"], binding["region"], binding["model"], why),
                         (AZURE_HOST, 443, "cloud", "koreacentral", "fast-transcription", None))
        self.assertEqual(self.decision().engine_hosts, {"azure": AZURE_HOST})
        cfg = dataclasses.replace(self.cfg, asr_azure_region=JAPAN)
        self.assertEqual(policy.consent_binding(cfg, "azure")[0]["host"], JAPAN_HOST)
        voided = self.decision(cfg)                                              # the consent was given for Korea Central: the region change voids it
        self.assertEqual((voided.primary, voided.reason, voided.engine_hosts), ("whisper", "consent-mismatch", {}))
        self.assertEqual(self.decision(cfg, consents=(consent_entry("azure", host=JAPAN_HOST, region=JAPAN),)).primary, "azure")

    def test_an_explicit_host_overrides_the_region_and_is_consent_bound_too(self):
        cfg = dataclasses.replace(self.cfg, asr_azure_host=CUSTOM_HOST.upper())
        self.assertEqual(policy.consent_binding(cfg, "azure")[0]["host"], CUSTOM_HOST)
        self.assertEqual(self.decision(cfg).primary, "whisper")                  # the consent names the region host, not this one
        decision = self.decision(cfg, consents=(consent_entry("azure", host=CUSTOM_HOST),))
        self.assertEqual((decision.primary, decision.engine_hosts), ("azure", {"azure": CUSTOM_HOST}))
        self.store_token(AZURE_KEY, "azure", CUSTOM_HOST)
        engine = self.engine(cfg=cfg, decision=decision)
        self.chunk(engine)
        self.assertEqual({c.rule.host for c in self.posts()}, {CUSTOM_HOST})
        self.assertEqual(self.posts()[0].header(KEY_HEADER), AZURE_KEY)

    def test_preflight_looks_without_reading_the_key(self):
        engine = self.engine()
        self.assertEqual(engine.preflight(), [])
        self.assertEqual(self.security.reads(), 0)
        self.security.remove()
        problems = engine.preflight()
        self.assertEqual(len(problems), 1)
        self.assertIn("no credential is stored", problems[0])
        foreign = self.engine(decision=self.doctored("evil.example.com"))
        self.assertEqual(foreign.preflight(), ["the destination is not an Azure Speech endpoint (the host must end in .api.cognitive.microsoft.com "
                                               "or .cognitiveservices.azure.com, port 443)"])


# ======================================================================================================================
class ResidencyTests(AzureCase):
    """The table of the policy has one residency per engine (``kr`` for azure) and ``allow_foreign=false`` is checked against that word only:
    the engine states the residency of its own destination and refuses what is not shown to be in Korea."""

    NO_FOREIGN = dataclasses.replace(policy.absent_policy(), allow_foreign=False)

    def foreign(self, **kw):
        cfg = dataclasses.replace(self.cfg, asr_azure_region=EAST, **kw)
        return cfg, self.decision(cfg, consents=(consent_entry("azure", host=EAST_HOST, region=EAST),), org=self.NO_FOREIGN)

    def test_the_residency_of_a_destination(self):
        rows = [(AZURE_HOST, "koreacentral", "kr"), (SOUTH_HOST, "koreacentral", "kr"), (EAST_HOST, "koreacentral", "foreign"),
                (JAPAN_HOST, "koreacentral", "foreign"), ("KoreaCentral.API.cognitive.microsoft.com", "eastus", "kr"),
                ("a.koreacentral.api.cognitive.microsoft.com", "koreacentral", "foreign"), ("myres.api.cognitive.microsoft.com", "koreacentral", "foreign"),
                (CUSTOM_HOST, "koreacentral", "kr"), (CUSTOM_HOST, " KoreaSouth ", "kr"), (CUSTOM_HOST, "eastus", "foreign"),
                (CUSTOM_HOST, "", "foreign"), (None, "koreacentral", "kr"), (None, "westeurope", "foreign")]
        for host, region, expected in rows:
            with self.subTest(host=host, region=region):
                self.assertEqual(destination_residency(host, dataclasses.replace(self.cfg, asr_azure_region=region)), expected)

    def test_a_custom_host_counts_as_korean_only_when_its_region_is_stated(self):
        both = frozenset({"ASR_AZURE_HOST", "ASR_AZURE_REGION"})
        host_only = frozenset({"ASR_AZURE_HOST"})
        for explicit, expected in ((both, "kr"), (host_only, "foreign"), (frozenset(), "kr")):         # a Config made in code has no list: its word
            with self.subTest(explicit=sorted(explicit)):
                cfg = dataclasses.replace(self.cfg, asr_azure_host=CUSTOM_HOST, explicit_keys=explicit)
                self.assertEqual(destination_residency(CUSTOM_HOST, cfg), expected)
        self.store_token(AZURE_KEY, "azure", CUSTOM_HOST)
        engines = {}
        for name, explicit in (("stated", both), ("defaulted", host_only)):
            cfg = dataclasses.replace(self.cfg, asr_azure_host=CUSTOM_HOST, explicit_keys=explicit)
            engines[name] = self.engine(cfg=cfg, decision=self.decision(cfg, consents=(consent_entry("azure", host=CUSTOM_HOST),)))
        self.chunk(engines["stated"])
        reads = self.security.reads()
        with self.assertRaises(EnginePolicyDenied) as caught:
            self.chunk(engines["defaulted"])
        self.assertEqual((caught.exception.code, len(self.posts()), self.security.reads() - reads), ("region_not_allowed", 1, 0))
        self.assertEqual(engines["defaulted"].provenance()["region"], "foreign")

    def test_a_region_outside_korea_is_refused_by_the_engine_before_the_key_and_any_byte(self):
        cfg, decision = self.foreign()
        self.assertEqual(decision.engine_hosts.get("azure"), EAST_HOST)         # the table sees ``kr`` for the engine: the engine is the last line
        engine = self.engine(cfg=cfg, decision=decision)
        self.assertEqual((engine.residency, AzureFastEngine.residency, engine_caps(engine).residency), ("foreign", "kr", "foreign"))
        for call in (engine.load, lambda: self.chunk(engine)):
            with self.assertRaises(EnginePolicyDenied) as caught:
                call()
            self.assertEqual(caught.exception.code, "region_not_allowed")
            self.assertNotIn(EAST, str(caught.exception))
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        self.assertEqual(engine.provenance()["region"], "foreign")              # what the transcript would say: never ``kr`` for another region
        self.assertEqual(engine.destination_label(), f"azure/{EAST}")

    def test_the_korean_regions_pass_and_say_kr(self):
        for region in ("koreacentral", "koreasouth"):
            with self.subTest(region=region):
                host = f"{region}.api.cognitive.microsoft.com"
                cfg = dataclasses.replace(self.cfg, asr_azure_region=region)
                self.store_token(AZURE_KEY, "azure", host)
                engine = self.engine(cfg=cfg, decision=self.decision(cfg, consents=(consent_entry("azure", host=host, region=region),)))
                self.chunk(engine)
                self.assertEqual((engine.residency, engine.provenance()["region"]), ("kr", "kr"))

    def test_a_whisper_fallback_takes_the_chunks_of_a_foreign_region_without_a_request(self):
        cfg = dataclasses.replace(self.cfg, asr_azure_region=EAST)
        run_cfg, _ = make_run(cfg, "azure", "whisper", consents=(consent_entry("azure", host=EAST_HOST, region=EAST),), org=self.NO_FOREIGN)
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            router = build_engine(run_cfg, VOCAB, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5,
                                  clock=self.clock)
        router.load()
        router.transcribe_chunk(audio(2.0), "ko", None)
        self.assertEqual(len(local.calls), 1)
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        self.assertEqual(router.provenance()["privacy"], "local")

    def test_preflight_says_why_without_reading_the_key(self):
        cfg, decision = self.foreign()
        (problem,) = self.engine(cfg=cfg, decision=decision).preflight()
        self.assertIn("not shown to be in a Korean region", problem)
        self.assertNotIn(EAST, problem)
        self.assertEqual(self.security.reads(), 0)


# ======================================================================================================================
class UsageTests(AzureCase):
    def test_the_line_of_a_chunk_carries_the_numbers_and_the_exact_host(self):
        self.chunk(self.engine(), 3.0)
        (line,) = self.usage()
        self.assertEqual((line["engine"], line["kind"], line["host"], line["op"], line["status"], line["outcome"]),
                         ("azure", "cloud", AZURE_HOST, "chunk", 200, "ok"))
        self.assertEqual((line["audio_s"], line["requests"], line["attempt"], line["circuit"]), (3.0, 1, 1, "closed"))
        self.assertEqual(line["bytes_out"], len(self.posts()[0].body))
        self.assertGreater(line["bytes_in"], 0)
        self.assertIsNone(line["est_usd"])                                      # ASR_AZURE_USD_PER_HOUR is 0: unknown, never 0.0
        self.assertNotIn(AZURE_KEY, json.dumps(line))

    def test_the_estimate_follows_the_price_setting(self):
        self.cfg.asr_azure_usd_per_hour = 3.6
        self.chunk(self.engine(), 10.0)
        self.assertEqual(self.usage()[0]["est_usd"], 0.01)
        self.cfg.asr_azure_usd_per_hour = 0.0
        self.chunk(self.engine(), 10.0)
        self.assertIsNone(self.usage()[1]["est_usd"])

    def test_each_attempt_has_its_own_line_and_a_failed_connection_counts_nothing(self):
        self.azure.queued = [ConnectionResetError(), json_response(503, {}), fixture_response("fast_ok_ko_en.json")]
        engine = self.engine()
        self.chunk(engine, 2.0)
        lines = self.usage()
        self.assertEqual([(u["attempt"], u["outcome"], u["requests"], u["audio_s"]) for u in lines],
                         [(1, "error:connect", 0, 0.0), (2, "http_503", 1, 2.0), (3, "ok", 1, 2.0)])
        self.assertEqual(engine.usage(), {"requests": 2, "lid_requests": 0, "audio_s": 4.0, "bytes": 2 * len(self.posts()[0].body)})
        self.assertTrue(engine.sent_anything())

    def test_the_cap_counts_audio_plus_one_second_per_request_over_the_cloud_lines(self):
        from mcap import asr_usage
        self.chunk(self.engine(), 29.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 30.0 / 60.0)


# ======================================================================================================================
class LeakTests(AzureCase):
    def test_no_key_and_no_server_text_in_any_file_log_message_or_provenance(self):
        hostile = json_response(200, raw=body_of({"phrases": [{"offset": 0, "duration": 1000, "text": "fine"}], "message": CANARY_TEXT}),
                                headers={"x-canary": CANARY_TEXT})
        engine = self.engine(VOCAB)
        self.azure.queued = [json_response(429, {"error": {"code": "429", "message": CANARY_TEXT}}, {"retry-after": "1"}), hostile,
                             json_response(500, raw=CANARY_TEXT.encode()), json_response(500, raw=CANARY_TEXT.encode()),
                             json_response(200, raw=CANARY_TEXT.encode())]
        messages = []
        for _ in range(3):
            try:
                self.chunk(engine)
            except EngineError as exc:
                messages.append(f"{exc} {exc.__dict__}")
        self.azure.key = "rotated"
        try:
            self.chunk(engine)
        except EngineError as exc:
            messages.append(f"{exc} {exc.__dict__}")
        engine.release()
        text = "\n".join(messages + [json.dumps(engine.provenance()), json.dumps(engine.describe()), json.dumps(engine.usage())])
        for needle in LEAK_WORDS:
            self.assertNotIn(needle, text)
        self.assertNothingLeaked()
        self.assertTrue(self.usage())
        self.assertEqual(apikey.redact(f"{KEY_HEADER}: {AZURE_KEY}"), f"{KEY_HEADER}: ***")
        self.assertNotIn(AZURE_KEY, apikey.redact(f"the key {AZURE_KEY} was refused"))          # remembered by the credential read: exact-match masking

    def test_the_info_line_about_the_phrase_list_has_counts_only(self):
        self.engine(Vocab(terms=["Acme", "acme", "CANARY-TERM-" + "x" * 100, "PACS"]))
        (line,) = [x for x in self.records.lines if "phraseList" in x]
        self.assertEqual(line, "azure phraseList: 2 of 4 vocabulary terms are sent (the rest are empty, duplicates, over 100 characters or past the first 500)")
        self.assertNothingLeaked()

    def test_the_key_is_only_ever_in_the_header_of_a_request_to_the_azure_host(self):
        engine = self.engine(VOCAB)
        self.chunk(engine)
        for call in self.transport.calls:
            self.assertEqual(call.rule.host, AZURE_HOST)
            self.assertNotIn(AZURE_KEY.encode(), call.body)
            self.assertNotIn(AZURE_KEY, call.target)
            self.assertEqual([k for k, v in call.headers.items() if AZURE_KEY in v], [KEY_HEADER])
        self.assertEqual(self.security.reads(), 1)
        self.assertNotIn(TOKEN, self.everything_written())


# ======================================================================================================================
class RelayBackendTests(AsrCase):
    """``for_server``: the engine the ASR server builds for ``"backend": "azure"`` (the relay), reading its key from a 0600 file."""

    def setUp(self):
        super().setUp()
        self.vault, self.logs = self.root / "vault", self.root / "logs"
        for directory in (self.vault, self.logs):
            directory.mkdir()
            os.chmod(directory, 0o700)
        self.keyfile = self.vault / "azure.key"
        self.keyfile.write_text(AZURE_KEY + "\n")
        os.chmod(self.keyfile, 0o600)
        self.azure = FakeAzure()
        self.transport = FakeTransport(handler=self.azure, clock=self.clock)
        patcher = mock.patch.object(egress, "HttpsTransport", lambda *a, **k: self.transport)       # the engine's own guard makes its transport lazily
        patcher.start()
        self.addCleanup(patcher.stop)

    def server_config(self, **options):
        return S.config_from_dict({"secrets_dir": str(self.vault), "log_dir": str(self.logs), "backend": "azure", "backend_options": options})

    def backend(self, **options):
        return S.default_backend_factory(self.server_config(**options))

    def test_the_server_factory_builds_the_engine_for_the_region_of_its_options(self):
        engine = self.backend()
        self.assertIsInstance(engine, AzureFastEngine)
        self.assertEqual((engine.relay, engine.kind, engine.engine_id, engine.model, engine.host, engine.port),
                         (True, "cloud", "azure", "fast-transcription", AZURE_HOST, 443))
        self.assertEqual((engine.supports_lid, engine.uses_prompt, engine.confidence), (False, False, "opaque"))
        self.assertEqual(engine.guard.hosts, (AZURE_HOST,))
        self.assertEqual(engine.vendor_info(), {"name": "azure-speech", "region": "koreacentral", "claim_url": "", "verified": False})
        self.assertEqual(self.backend(region="koreasouth").host, SOUTH_HOST)
        self.assertEqual(self.backend(host=CUSTOM_HOST.upper(), region="koreacentral").host, CUSTOM_HOST)      # a custom host states its region
        engine.load()                                                            # no destination problem, no network, no key read
        self.assertEqual((self.transport.calls, self.security.calls()), ([], []))

    def test_the_key_comes_from_the_file_bound_to_engine_host_and_port_and_never_from_the_keychain(self):
        engine = self.backend()
        result = engine.transcribe_chunk(audio(2.0, 0.25), "ko", None)
        self.assertEqual(result["segments"][0]["text"], "액미 chunk 32000 samples")
        (call,) = self.transport.calls
        self.assertEqual((call.rule.host, call.header(KEY_HEADER)), (AZURE_HOST, AZURE_KEY))
        self.assertEqual(self.security.calls(), [])
        self.assertEqual(S.vendor_key_path(self.vault, "azure"), str(self.keyfile))
        for host, port in (("other.api.cognitive.microsoft.com", 443), (AZURE_HOST, 8443)):
            with self.assertRaises(asr_creds.CredentialUnavailable) as caught, asr_creds.secret("azure", host, port):
                pass
            self.assertEqual(caught.exception.reason, "unbound")

    def test_a_key_file_that_is_not_private_is_refused(self):
        engine = self.backend()
        os.chmod(self.keyfile, 0o644)
        with self.assertRaises(EngineAuthError) as caught:
            engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((caught.exception.code, self.transport.calls), ("insecure", []))
        os.chmod(self.keyfile, 0o600)
        self.keyfile.unlink()
        with self.assertRaises(EngineAuthError) as missing:
            self.backend().transcribe_chunk(audio(), "en", None)
        self.assertEqual(missing.exception.code, "missing")

    def test_the_options_are_strict(self):
        bad = [({"nope": 1}, "unknown backend_options key 'nope'"), ({"host": "evil.example.com"}, "not usable"),
               ({"region": "a.b"}, "not usable"), ({"region": 5}, "region must be a string"), ({"host": 5}, "host must be a string"),
               ({"bias": 3.0}, "bias must be from"), ({"bias": "1"}, "bias must be a number"), ({"bias": True}, "bias must be a number"),
               ({"bias": float("nan")}, "bias must be from"), ({"usd_per_hour": -1}, "usd_per_hour must be at least"),
               ({"retry_max": 0}, "retry_max must be from"), ({"retry_max": 2.5}, "retry_max must be an integer"),
               ({"retry_max": True}, "retry_max must be an integer"), ({"request_timeout_s": 0}, "request_timeout_s must be from"),
               ({"retry_budget_s": 601}, "retry_budget_s must be from"), ({"locales": 5}, "locales must be"), ({"locales": ["ko-KR", 5]}, "locales must be"),
               ({"usage_dir": "relative/dir"}, "usage_dir must be an absolute path"), ({"usage_dir": 5}, "usage_dir must be a string")]
        for options, message in bad:
            with self.subTest(options=options), self.assertRaisesRegex(ValueError, re.escape(message)):
                self.backend(**options)
        engine = self.backend(region="KoreaCentral", locales=["ko-KR", "en-US"], bias=1.5, usd_per_hour=1.0, retry_max=1, request_timeout_s=10,
                              retry_budget_s=5, usage_dir=str(self.root / "u"))
        cfg = engine.cfg
        self.assertEqual((engine.host, cfg.asr_azure_locales, cfg.asr_azure_bias, cfg.asr_azure_usd_per_hour, cfg.asr_retry_max,
                          cfg.asr_request_timeout_s, cfg.asr_remote_max_wait_s, cfg.support_dir), (AZURE_HOST, "ko-KR,en-US", 1.5, 1.0, 1, 10, 5, self.root / "u"))

    def test_a_refused_option_installs_no_key_source_and_the_model_is_ignored(self):
        with self.assertRaises(ValueError):
            self.backend(host="evil.example.com")
        self.assertEqual(asr_creds.install_source(), ())                          # nothing was installed by the failed attempt
        engine = S.default_backend_factory(S.config_from_dict({"secrets_dir": str(self.vault), "log_dir": str(self.logs), "backend": "azure",
                                                                 "model": "mlx-community/whisper-large-v3-mlx"}))
        self.assertEqual(engine.model, "fast-transcription")

    def test_the_relay_defaults_fit_inside_the_clients_request_timeout_and_no_client_cap_applies(self):
        engine = self.backend()
        cfg = engine.cfg
        self.assertEqual((cfg.asr_request_timeout_s, cfg.asr_retry_max, cfg.asr_remote_max_wait_s), (30, 2, 40))
        self.assertLess(cfg.asr_request_timeout_s + 45, 90)
        self.assertTrue(math.isinf(engine._cap))
        self.assertIsNone(engine._gate)

    def test_the_vocabulary_of_each_request_becomes_the_phrase_list_of_the_next_chunk(self):
        engine = self.backend(locales="ko-KR,en-US", bias=1.5)
        engine.set_request_terms(("Acme", "PACS", 5, None))
        engine.transcribe_chunk(audio(), "ko", None)
        self.assertEqual(json.loads(self.azure.requests[-1]["definition"][1]),
                         {"profanityFilterMode": "None", "locales": ["ko-KR", "en-US"], "phraseList": {"phrases": ["Acme", "PACS"], "biasingWeight": 1.5}})
        engine.set_request_terms(())                                              # the next request named none
        engine.transcribe_chunk(audio(), "ko", None)
        self.assertEqual(json.loads(self.azure.requests[-1]["definition"][1]), {"profanityFilterMode": "None", "locales": ["ko-KR", "en-US"]})
        engine.set_request_terms("not a list")
        engine.transcribe_chunk(audio(), "ko", None)
        self.assertNotIn("phraseList", json.loads(self.azure.requests[-1]["definition"][1]))

    def test_its_usage_lines_are_content_free_and_go_to_the_secrets_directory_unless_told_otherwise(self):
        engine = self.backend(usd_per_hour=3.6)
        engine.transcribe_chunk(audio(10.0), "ko", None)
        path = self.vault / "azure-usage" / "asr-usage.jsonl"
        (line,) = [json.loads(x) for x in path.read_text().splitlines()]
        self.assertEqual((line["engine"], line["kind"], line["host"], line["audio_s"], line["requests"], line["est_usd"]),
                         ("azure", "cloud", AZURE_HOST, 10.0, 1, 0.01))
        self.assertNotIn(AZURE_KEY, path.read_text())
        self.assertEqual(S.scan_for_audio(self.vault), [])
        self.assertEqual(S.scan_log_dir(self.vault / "azure-usage"), [])         # what the quarterly audit would say about this directory
        elsewhere = self.backend(usage_dir=str(self.root / "elsewhere"))
        elsewhere.transcribe_chunk(audio(1.0), "ko", None)
        self.assertTrue((self.root / "elsewhere" / "asr-usage.jsonl").exists())

    def test_a_destination_outside_korea_is_refused_at_startup_and_installs_no_key_source(self):
        for options in ({"region": EAST}, {"region": "japaneast"}, {"host": CUSTOM_HOST}, {"host": JAPAN_HOST}, {"host": CUSTOM_HOST, "region": EAST}):
            with self.subTest(options=options), self.assertRaisesRegex(ValueError, "not shown to be in Korea"):
                self.backend(**options)
        self.assertEqual(asr_creds.install_source(), ())
        engine = self.backend(host=CUSTOM_HOST, region="koreasouth")             # a custom host that states its region is the operator's word
        self.assertEqual((engine.host, engine.residency, engine.vendor_info()["region"]), (CUSTOM_HOST, "kr", "koreasouth"))

    def rotate(self, key):
        """The operator writes a new key into azure.key (and, on the service side, the key is changed)."""
        self.keyfile.write_text(key + "\n")
        os.chmod(self.keyfile, 0o600)
        self.azure.key = key

    def test_a_rotated_key_file_is_read_again_after_a_401_and_the_chunk_goes_through(self):
        engine = self.backend()
        engine.transcribe_chunk(audio(1.0, 0.25), "ko", None)
        self.rotate("rotated-azure-key")
        result = engine.transcribe_chunk(audio(1.0, 0.25), "ko", None)         # the cached key is refused, the file is read again, once more
        self.assertEqual(len(result["segments"]), 1)
        engine.transcribe_chunk(audio(1.0, 0.25), "ko", None)                  # and the next chunk has no failure at all
        self.assertEqual([c.header(KEY_HEADER) for c in self.transport.calls], [AZURE_KEY, AZURE_KEY, "rotated-azure-key", "rotated-azure-key"])
        self.assertEqual([u["outcome"] for u in usage_lines(engine.cfg)], ["ok", "http_401", "ok", "ok"])
        self.assertEqual(self.security.calls(), [])

    def test_a_key_the_service_still_refuses_fails_once_per_chunk_and_the_file_is_read_again_for_the_next(self):
        engine = self.backend()
        self.azure.key = "changed-on-the-service-side"                           # the file still holds the old key
        for _ in range(2):
            with self.assertRaises(EngineAuthError) as caught:
                engine.transcribe_chunk(audio(), "ko", None)
            self.assertEqual(caught.exception.status, 401)
        self.assertEqual(len(self.transport.calls), 2)                           # one request per chunk: the same key is not sent twice
        self.rotate("changed-on-the-service-side")                               # the operator fixes the file: no restart needed
        engine.transcribe_chunk(audio(), "ko", None)
        self.assertEqual(self.transport.calls[-1].header(KEY_HEADER), "changed-on-the-service-side")

    def test_a_new_key_that_is_refused_too_is_tried_once_and_the_answer_is_the_401(self):
        engine = self.backend()
        engine.transcribe_chunk(audio(), "ko", None)
        self.keyfile.write_text("second-wrong-key\n")
        os.chmod(self.keyfile, 0o600)
        self.azure.key = "the-real-key"
        with self.assertRaises(EngineAuthError) as caught:
            engine.transcribe_chunk(audio(), "ko", None)
        self.assertEqual((caught.exception.status, [c.header(KEY_HEADER) for c in self.transport.calls]), (401, [AZURE_KEY, AZURE_KEY, "second-wrong-key"]))

    def test_a_key_file_that_vanished_after_a_401_is_the_error_of_the_file(self):
        engine = self.backend()
        engine.transcribe_chunk(audio(), "ko", None)
        self.azure.key = "rotated"
        self.keyfile.unlink()
        with self.assertRaises(EngineAuthError) as caught:
            engine.transcribe_chunk(audio(), "ko", None)
        self.assertEqual((caught.exception.code, len(self.transport.calls)), ("missing", 2))

    def test_the_startup_self_check_of_the_server_finds_the_key_file(self):
        checks = {c.name: c for c in S.run_selfchecks(self.server_config())}
        self.assertTrue(checks["vendor_key"].ok, checks["vendor_key"].detail)
        os.chmod(self.keyfile, 0o644)
        self.assertFalse({c.name: c for c in S.run_selfchecks(self.server_config())}["vendor_key"].ok)

    def test_a_chunk_through_the_server_core_reaches_azure_and_the_health_says_cloud(self):
        cfg = self.server_config(locales="ko-KR,en-US")
        state = S.ServerState(cfg, S.default_backend_factory(cfg))
        state.start()
        self.addCleanup(state.close)
        token, _row = state.tokens.issue("mic", time.time(), 90)

        def call(method, path, body=b"", **headers):
            sent = {"X-MCAP-Proto": S.PROTO, "Authorization": f"Bearer {token}", **headers}
            if method in ("POST", "PUT"):
                sent["Content-Length"] = str(len(body))
            status, _out, data = S.handle_request(state, method, path, sent, body, time.time())
            return status, (json.loads(data.decode("utf-8")) if data else None)

        status, health = call("GET", "/v1/health?detail=1")
        self.assertEqual(status, 200)
        self.assertEqual((health["kind"], health["supports_lid"], health["confidence"], health["engine"], health["model"]),
                         ("cloud", False, "opaque", "azure", "fast-transcription"))
        self.assertEqual((health["vendor"]["name"], health["vendor"]["region"], health["vendor"]["verified"]), ("azure-speech", "koreacentral", False))
        terms = {"terms": ["Acme", "AcmeScan-CXR"]}
        status, _ = call("PUT", "/v1/vocab/" + S.canonical_vocab_digest(terms), S._dumps(terms), **{"Content-Type": "application/json"})
        self.assertEqual(status, 204)
        pcm = np.full(32000, 5, dtype="<i2").tobytes()
        status, answer = call("POST", "/v1/chunk", pcm, **{"Content-Type": "application/octet-stream", "X-MCAP-Samples": "32000",
                                                          "X-MCAP-Lang": "auto", "X-MCAP-Prompt": "frame+list", "X-MCAP-Vocab": S.canonical_vocab_digest(terms)})
        self.assertEqual(status, 200)
        self.assertEqual((answer["engine"], answer["language"], answer["prompt_text"]), ("azure", "ko", ""))     # no prompt is built for this backend
        self.assertEqual([s["text"] for s in answer["segments"]], ["액미 chunk 32000 samples"])
        self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None for s in answer["segments"]))
        self.assertEqual(json.loads(self.azure.requests[0]["definition"][1]),
                         {"profanityFilterMode": "None", "locales": ["ko-KR", "en-US"], "phraseList": {"phrases": ["Acme", "AcmeScan-CXR"], "biasingWeight": 1.0}})
        self.assertEqual(self.transport.calls[0].header(KEY_HEADER), AZURE_KEY)
        self.assertEqual(self.security.calls(), [])


# ======================================================================================================================
class RemoteClientOfAzureRelayTests(RemoteCase):
    """The only client of a relay, ``RemoteEngine``, in front of the real server core (``handle_request``) with ``"backend": "azure"`` in front of
    ``FakeAzure``. OPEN ISSUE (stage 7 review; the fix is in asr_remote / policy / cli, not here): the relay says ``kind: cloud`` but
    every consent of the engine ``remote`` is bound to ENGINE_META["remote"]["backend_kind"] = ``server`` (``asr_remote._consent_terms``,
    ``policy.consent_binding``), so the client refuses the relay and the Azure half of the company profile cannot be used end to end. The first
    test pins what happens today (closed, before any audio or key is sent); the second is the intended outcome and is an expected failure: when
    the consent can carry ``backend_kind`` ``cloud`` it passes unexpectedly, which fails the suite on purpose: drop the first test and the
    decorator then."""

    def setUp(self):
        super().setUp()
        vault, logs = self.root / "vault", self.root / "logs"
        for directory in (vault, logs):
            directory.mkdir()
            os.chmod(directory, 0o700)
        (vault / "azure.key").write_text(AZURE_KEY + "\n")
        os.chmod(vault / "azure.key", 0o600)
        self.azure = FakeAzure()
        azure_transport = FakeTransport(handler=self.azure, clock=self.clock)
        patcher = mock.patch.object(egress, "HttpsTransport", lambda *a, **k: azure_transport)       # the relay engine's own guard
        patcher.start()
        self.addCleanup(patcher.stop)
        cfg = S.config_from_dict({"secrets_dir": str(vault), "log_dir": str(logs), "backend": "azure"})
        state = S.ServerState(cfg, S.default_backend_factory(cfg))
        state.start()
        self.addCleanup(state.close)
        token, _row = state.tokens.issue("mic", time.time(), 90)
        asr_creds.install_source()                      # the relay is its own process in life; here the fake Keychain serves both keys
        self.store_token(AZURE_KEY, "azure", AZURE_HOST)
        self.store_token(token)

        def relay(call):
            status, headers, data = S.handle_request(state, call.method, call.target, dict(call.headers), call.body, time.time())
            return Response(status, {k.lower(): v for k, v in dict(headers).items()}, data, 0, 0, 0)
        self.transport.handler = relay

    def test_today_the_client_refuses_the_cloud_relay_before_any_audio_or_key_is_sent(self):
        engine = self.engine()
        with self.assertRaises(EnginePolicyDenied) as caught:
            engine.load()
        self.assertEqual((caught.exception.code, str(caught.exception)), ("kind", "the server was refused: kind"))
        self.assertEqual(self.paths(), ["GET /v1/health"])
        self.assertEqual(self.azure.requests, [])

    @unittest.expectedFailure
    def test_intended_the_client_transcribes_through_the_azure_relay(self):
        engine = self.loaded()
        result = engine.transcribe_chunk(audio(2.0, 0.25), "ko", None)
        self.assertEqual([s["text"] for s in result["segments"]], ["액미 chunk 32000 samples"])
        self.assertEqual(len(self.azure.requests), 1)


# ======================================================================================================================
class EndToEndTests(AzureCase):
    """The real asr.transcribe_tracks over the synthetic two-track audio of the golden fixtures, through build_engine (the real registry entry
    of ``azure``), a real RoutedEngine, EgressGuard and AzureFastEngine, in front of FakeAzure. The only fakes: the transport, the clock, the gate."""

    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(policy, "machine_id", return_value=MACHINE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_asr(self, fallback="none", **cfg_kw):
        cfg, _decision = make_run(self.cfg, "azure", fallback, consents=("azure",))
        values = dict(asr_vad="energy", mic_aec="0", asr_language="auto", self_name="Me")
        values.update(cfg_kw)
        cfg = dataclasses.replace(cfg, **values)

        def engine_for(c, vocab, progress=None):
            return build_engine(c, vocab, progress=progress, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep,
                                rand=lambda: 0.5, clock=self.clock)
        with mock.patch.object(asr, "_engine_for", engine_for):
            return asr.transcribe_tracks(mg.prepared_audio(), cfg, VOCAB)

    def test_both_tracks_are_transcribed_by_azure_with_the_phrase_list_and_the_aliases_are_applied_afterwards(self):
        out = self.run_asr()
        block = out["asr"]
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["model"]),
                         ("azure", "cloud", "cloud", "azure/koreacentral", "fast-transcription"))
        self.assertGreaterEqual(block["chunks"]["azure"], 2)
        self.assertEqual((block["sent"]["requests"], block["sent"]["lid_requests"]), (block["chunks"]["azure"], 0))
        self.assertEqual({s["speaker"] for s in out["segments"]}, {"Me", "Remote"})
        self.assertTrue(all(s["text"].startswith("Acme chunk ") for s in out["segments"]), [s["text"] for s in out["segments"]])   # 액미 -> Acme
        self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None for s in out["segments"]))
        self.assertEqual(len(self.azure.requests), block["chunks"]["azure"])
        for index in range(len(self.azure.requests)):
            self.assertEqual(self.definition_sent(index), {"profanityFilterMode": "None", "phraseList": {"phrases": ["Acme", "AcmeScan-CXR"],
                                                                                                        "biasingWeight": 1.0}})
        self.assertEqual({c.header(KEY_HEADER) for c in self.transport.calls}, {AZURE_KEY})
        self.assertEqual({c.path for c in self.transport.calls}, {TRANSCRIBE_PATH})
        self.assertEqual(self.security.reads(), 1)
        lines = self.usage()
        self.assertEqual((len(lines), {u["engine"] for u in lines}, {u["kind"] for u in lines}), (block["chunks"]["azure"], {"azure"}, {"cloud"}))
        text = json.dumps(out, ensure_ascii=False)
        for needle in (AZURE_HOST, AZURE_KEY):
            self.assertNotIn(needle, text)
        self.assertNothingLeaked()

    def test_no_language_id_request_and_no_tokenizer_for_an_engine_that_has_neither(self):
        with mock.patch.object(RoutedEngine, "tokenizer", new_callable=mock.PropertyMock, side_effect=AssertionError("tokenizer")):
            out = self.run_asr()
        self.assertTrue(out["segments"])
        self.assertEqual([c.path for c in self.transport.calls if c.path != TRANSCRIBE_PATH], [])

    def test_a_forced_language_is_not_turned_into_a_locale(self):
        out = self.run_asr(asr_language="en")
        self.assertTrue(out["segments"])
        self.assertEqual([self.definition_sent(i) for i in range(len(self.azure.requests))],
                         [{"profanityFilterMode": "None", "phraseList": {"phrases": ["Acme", "AcmeScan-CXR"], "biasingWeight": 1.0}}] * len(self.azure.requests))

    def test_a_throttled_azure_falls_back_to_the_local_engine_chunk_by_chunk(self):
        self.azure.queued = [fixture_response("fast_error_429.json")] * 60
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            out = self.run_asr("whisper")
        block = out["asr"]
        self.assertGreaterEqual(block["fallbacks"], 1)
        self.assertGreaterEqual(block["chunks"].get("whisper", 0), 1)
        self.assertEqual(block["privacy"], "mixed")                              # azure saw (and refused) audio, the local engine transcribed it
        self.assertTrue(out["segments"])
        self.assertTrue(all(u["outcome"] == "http_429" for u in self.usage()))
        self.assertEqual(block["engine"], "azure")

    def test_an_endpoint_that_does_not_know_the_path_hands_the_run_to_the_fallback_after_one_request(self):
        self.azure.queued = [json_response(404, {"error": {"code": "404", "message": CANARY_TEXT}})] * 60
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            out = self.run_asr("whisper")
        block = out["asr"]
        self.assertTrue(out["segments"])
        self.assertEqual(len(self.posts()), 1)                                   # the first refusal opens the circuit for the run: nothing more is sent
        self.assertEqual([u["outcome"] for u in self.usage()], ["http_404"])
        self.assertGreaterEqual(block["fallbacks"], 1)
        self.assertEqual((block["chunks"].get("azure", 0), block["circuit_opened"], block["privacy"]), (0, 1, "mixed"))
        self.assertGreaterEqual(len(local.calls), 2)
        self.assertNothingLeaked()

    def test_a_definition_the_service_refuses_every_time_hands_the_run_to_the_fallback_after_the_streak(self):
        self.azure.queued = [json_response(400, {"error": {"code": "InvalidRequest", "message": CANARY_TEXT}})] * 60
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            out = self.run_asr("whisper")
        block = out["asr"]
        self.assertTrue(out["segments"])
        self.assertEqual(len(self.posts()), REFUSAL_STREAK)                      # REFUSAL_STREAK refused chunks (the first ones lost), then nothing more is sent
        self.assertEqual([u["outcome"] for u in self.usage()], ["http_400"] * REFUSAL_STREAK)
        self.assertEqual((block["chunks"].get("azure", 0), block["circuit_opened"], block["privacy"]), (0, 1, "mixed"))
        self.assertGreaterEqual(len(local.calls), 2)
        self.assertNothingLeaked()

    def test_the_same_without_a_fallback_fails_the_meeting_as_it_always_did(self):
        for status, posts in ((404, 1), (400, REFUSAL_STREAK)):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.azure.queued = [json_response(status, {"error": {"code": str(status), "message": CANARY_TEXT}})] * 60
                with self.assertRaisesRegex(RuntimeError, "ASR failed for every chunk"):
                    self.run_asr()
                self.assertEqual(len(self.posts()), posts)

    @staticmethod
    def good(call):
        return FakeAzure.answer(parse_multipart(call))

    def test_one_refused_chunk_among_good_ones_costs_only_that_chunk_without_a_fallback(self):
        self.azure.queued = [self.good, json_response(422, {"error": {"code": "x", "message": CANARY_TEXT}})]
        out = self.run_asr()
        block = out["asr"]
        outcomes = [u["outcome"] for u in self.usage()]
        self.assertEqual(outcomes.count("http_422"), 1)
        self.assertEqual((block["circuit_opened"], block["fallbacks"]), (0, 0))
        self.assertEqual(block["chunks"]["azure"], len(outcomes) - 1)            # every other chunk went to azure, the refused one is the only loss
        self.assertGreaterEqual(block["chunks"]["azure"], 3)
        self.assertEqual(len(self.posts()), len(outcomes))
        self.assertNothingLeaked()

    def test_one_refused_chunk_among_good_ones_keeps_azure_for_the_rest_of_the_run_with_a_fallback_too(self):
        self.azure.queued = [self.good, json_response(400, {"error": {"code": "x", "message": CANARY_TEXT}})]
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            out = self.run_asr("whisper")
        block = out["asr"]
        self.assertEqual(local.calls, [])                                        # the local engine was never needed
        self.assertEqual((block["circuit_opened"], block["fallbacks"], block["chunks"].get("whisper", 0), block["privacy"]), (0, 0, 0, "cloud"))
        self.assertGreaterEqual(block["chunks"]["azure"], 3)
        self.assertEqual([u["outcome"] for u in self.usage()].count("http_400"), 1)

    def test_a_meeting_switched_to_local_only_after_the_first_chunk_sends_nothing_more_to_azure(self):
        self.transport.on_send = lambda call: self.gate.close("local_only") if call.path == TRANSCRIBE_PATH else None
        with self.assertRaisesRegex(RuntimeError, "EnginePolicyDenied"):           # no fallback: the second chunk of the track onward has nowhere to go
            self.run_asr()
        self.assertEqual(len(self.posts()), 1)

    def test_azure_that_cannot_be_reached_is_a_waiting_condition_not_a_failed_meeting(self):
        self.azure.queued = [ConnectionRefusedError("down")] * 60
        with self.assertRaises(asr.AsrUnreachable):
            self.run_asr()


if __name__ == "__main__":
    unittest.main()
