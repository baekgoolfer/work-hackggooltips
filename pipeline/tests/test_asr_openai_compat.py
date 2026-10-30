"""asr_openai_compat.py (SPEC 18): the provider for any server with an OpenAI-style ``POST <base>/audio/transcriptions``.

Same stack as test_asr_clova.py: a REAL asr_router / asr_http / EgressGuard in front of an in-process Transport whose handler is ``FakeOpenAI``
(the optional bearer key, the path, the multipart parts). The fixtures of tests/fixtures/openai_compat are DOCUMENT-DERIVED (the API reference of
the endpoint): servers that copy the shape differ in details, so the parser takes every optional field defensively. No socket opens, the Keychain is
the fake `security`.

Pinned: the request (the parts and fields of the documentation, the language only when ``ASR_LANGUAGE`` pins one, the model), the optional key (sent
when stored, nothing when there is none, an unreadable key is never replaced by an anonymous request), the answer parser (verbose_json, sparse
servers, text without segments, empty and malformed answers), the error mapping, the policy metadata ("destination chosen by the user", residency
foreign: an organisation policy needs allow_foreign), the consent text that names the configured host, and the canary checks.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import json
import logging
import unittest
from pathlib import Path

import numpy as np

from asr_support import audio, json_response, make_decision, usage_lines
from provider_support import OAI_HOST, OAI_KEY, OAI_URL, SR, ProviderCase, oai_consent, parse_multipart, region_vad, wav_samples
from test_status import company_doc, company_org

from mcap import asr, egress, policy
from mcap import vad as vadmod
from mcap.asr_engines import EngineAuthError, EngineBlockDeclined, EngineError, EnginePolicyDenied, EngineTransient, engine_caps
from mcap.asr_http import MAX_SEGMENTS, EngineHttpError
from mcap.asr_openai_compat import TRANSCRIBE_PATH, build_fields, language_code, parse_response
from mcap.egress import Response
from mcap.vocab import Vocab

logging.getLogger("mcap").addHandler(logging.NullHandler())

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "openai_compat"
FIXTURE_NAMES = ("verbose_json_ok.json", "verbose_json_sparse.json", "verbose_json_empty.json", "text_only.json", "error_401.json", "error_429.json")


LONG_REGIONS = [(1.0, 25.0), (30.0, 55.0), (60.0, 85.0), (90.0, 115.0)]     # four chunks of about 25 s: one block of 100 s
LONG_TOTAL = 120.0


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def fixture_response(name: str) -> Response:
    doc = fixture(name)
    return json_response(doc["status"], raw=json.dumps(doc["body"], ensure_ascii=False).encode("utf-8"), headers=doc.get("headers", {}))


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


# ======================================================================================================================
class ParseTests(unittest.TestCase):
    def test_verbose_json_with_the_whisper_numbers(self):
        out = parse_response(body_of("verbose_json_ok.json"), 30.0)
        self.assertEqual([(s["start"], s["end"]) for s in out["segments"]], [(0.4, 6.2), (7.0, 14.8)])
        self.assertEqual([s["text"] for s in out["segments"]], ["안녕하세요 오늘은 액미스캔 일정을 논의하겠습니다.", "다음은 예산입니다."])
        self.assertEqual([(s["avg_logprob"], s["no_speech_prob"], s["compression_ratio"], s["temperature"]) for s in out["segments"]],
                         [(-0.21, 0.02, 1.3, 0.0), (-0.35, 0.05, 1.1, 0.2)])
        self.assertEqual((out["language"], out["truncated"]), ("ko", False))                    # "korean" is read as the code

    def test_a_server_that_gives_less(self):
        out = parse_response(body_of("verbose_json_sparse.json"), 20.0)
        self.assertEqual([(s["start"], s["end"], s["text"]) for s in out["segments"]],
                         [(1.5, 4.0, "the first item"), (4.0, 4.0, "no time at all")])         # numeric strings; the empty segment is dropped; no time follows the one before
        self.assertTrue(all(s["avg_logprob"] is None and s["no_speech_prob"] is None and s["compression_ratio"] is None for s in out["segments"]))
        self.assertEqual(out["language"], "en")

    def test_silence_is_an_empty_transcript(self):
        out = parse_response(body_of("verbose_json_empty.json"), 10.0)
        self.assertEqual((out["segments"], out["text"], out["language"]), ([], "", "en"))

    def test_text_without_segments_is_one_segment_over_the_block(self):
        out = parse_response(body_of("text_only.json"), 15.0)
        self.assertEqual([(s["start"], s["end"], s["text"]) for s in out["segments"]], [(0.0, 15.0, "This server only gives the text of the block.")])
        self.assertIsNone(out["language"])
        self.assertEqual(parse_response(answer({"text": "x y"}), 0.0)["segments"][0]["end"], 0.0)
        self.assertEqual(parse_response(answer({"text": "x y", "duration": 9.5}), 0.0)["segments"][0]["end"], 9.5)       # the answer's own duration when the block's is unknown

    def test_an_answer_that_is_not_the_document_is_never_an_empty_transcript(self):
        for raw in (b"", b"not json", b"\xff\xfe", b"[]", b"{}", b'{"language": "ko"}', b'{"segments": "x"}', b"null",
                    b"[" * 100000 + b"]" * 100000):
            with self.subTest(raw=raw[:20]), self.assertRaises(EngineTransient) as ctx:
                parse_response(raw, 5.0)
            self.assertIn("engine answer could not be", str(ctx.exception))

    def test_numbers_and_text_are_taken_defensively(self):
        out = parse_response(b'{"segments": [{"start": NaN, "end": Infinity, "text": "one"}, {"start": true, "end": 2, "text": "two"}, '
                             b'{"start": -3, "end": 1, "text": "ab\\ud800"}, "x", {"start": 1, "end": 2}]}', 5.0)
        self.assertEqual([(s["start"], s["end"], s["text"]) for s in out["segments"]], [(0.0, 0.0, "one"), (0.0, 2.0, "two"), (0.0, 1.0, "ab?")])
        out["segments"][2]["text"].encode("utf-8")

    def test_more_segments_than_clean_result_keeps_are_merged_not_dropped(self):
        rows = [{"start": i, "end": i + 0.9, "text": f"sentence {i}"} for i in range(MAX_SEGMENTS * 3)]
        out = parse_response(answer({"segments": rows}), 1000.0)
        self.assertLessEqual(len(out["segments"]), MAX_SEGMENTS)
        self.assertEqual(" ".join(s["text"] for s in out["segments"]), " ".join(r["text"] for r in rows))

    def test_language_names_and_codes(self):
        for value, expected in (("korean", "ko"), ("English", "en"), (" ko ", "ko"), ("ja", "ja"), ("japanese", "ja"), ("yue", "yue"), ("klingon", None),
                                ("", None), (None, None), (7, None)):
            self.assertEqual(language_code(value), expected, value)

    def test_the_fields_of_the_request(self):
        self.assertEqual(build_fields("whisper-1", None), [("model", "whisper-1"), ("response_format", "verbose_json"), ("timestamp_granularities[]", "segment")])
        self.assertEqual(build_fields("m", " KO ")[-1], ("language", "ko"))
        for language in ("", "korean", "k", "ko-KR", None, 7):
            self.assertEqual(len(build_fields("m", language)), 3, language)


# ======================================================================================================================
class RequestTests(ProviderCase):
    def setUp(self):
        super().setUp()
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)

    def chunk(self, engine=None, seconds=3.0, language=None):
        return (engine or self.engine("openai-compat")).transcribe_chunk(audio(seconds, 0.25), language, None)

    def test_the_request_as_the_api_reference_describes_it(self):
        self.chunk(language="ko")
        call, = self.transport.calls
        self.assertEqual((call.method, call.target), ("POST", "/v1" + TRANSCRIBE_PATH))
        self.assertEqual(call.header("Authorization"), f"Bearer {OAI_KEY}")
        self.assertEqual(call.header("Accept"), "application/json")
        parts = parse_multipart(call)
        self.assertEqual(list(parts), ["file", "model", "response_format", "timestamp_granularities[]", "language"])
        head, data = parts["file"]
        self.assertEqual((head["Content-Type"], 'filename="block.wav"' in head["Content-Disposition"], wav_samples(data)), ("audio/wav", True, 3 * SR))
        self.assertEqual({k: v[1] for k, v in parts.items() if k != "file"},
                         {"model": b"whisper-1", "response_format": b"verbose_json", "timestamp_granularities[]": b"segment", "language": b"ko"})
        self.assertTrue(all("filename" not in v[0]["Content-Disposition"] for k, v in parts.items() if k != "file"))

    def test_no_language_field_unless_asr_language_pins_one(self):
        self.chunk(language=None)
        self.assertNotIn("language", parse_multipart(self.transport.calls[-1]))
        self.chunk(language="")
        self.assertNotIn("language", parse_multipart(self.transport.calls[-1]))

    def test_the_model_and_the_base_path_are_the_settings(self):
        self.cfg.asr_openai_compat_model = "Systran/faster-whisper-large-v3"
        self.cfg.asr_openai_compat_url = f"https://{OAI_HOST}/api/audio/"
        self.oai.base = "/api/audio"
        self.chunk()
        call = self.transport.calls[-1]
        self.assertEqual(call.target, "/api/audio/audio/transcriptions")                       # <base>/audio/transcriptions, the base as written
        self.assertEqual(parse_multipart(call)["model"][1], b"Systran/faster-whisper-large-v3")
        self.cfg.asr_openai_compat_url = f"https://{OAI_HOST}"
        self.oai.base = ""
        self.chunk()
        self.assertEqual(self.transport.calls[-1].target, "/audio/transcriptions")

    def test_an_empty_or_odd_model_is_refused_before_anything_is_sent(self):
        for model in ("", "   ", "two words", "a\nb", "x" * 101):
            with self.subTest(model=model):
                engine = self.engine("openai-compat", cfg=dataclasses.replace(self.cfg, asr_openai_compat_model=model))
                with self.assertRaises(EnginePolicyDenied) as ctx:
                    engine.load()
                self.assertEqual(ctx.exception.code, "no_model")
                self.assertTrue(engine.preflight()[0].startswith("ASR_OPENAI_COMPAT_MODEL"))
        self.assertEqual(self.transport.calls, [])

    def test_the_model_shows_in_the_provenance_as_the_one_the_user_chose(self):
        engine = self.engine("openai-compat")
        self.chunk(engine)
        self.assertEqual(engine.provenance()["model"], "whisper-1")

    def test_nothing_is_sent_for_an_empty_block(self):
        out = self.engine("openai-compat").transcribe_chunk(np.zeros(0, np.float32), "ko", None)
        self.assertEqual((out["segments"], self.transport.calls), ([], []))

    def test_the_engine_declares_blocks_and_the_destination_is_foreign(self):
        engine = self.engine("openai-compat")
        caps = engine_caps(engine)
        self.assertEqual((caps.kind, caps.accepts_blocks, caps.max_block_s, caps.uses_prompt, caps.supports_lid, caps.confidence, caps.residency),
                         ("cloud", True, 720.0, False, False, "logprob", "foreign"))      # 900 s is the setting, 720 s (23 MB of WAV) what OpenAI takes
        self.assertEqual(engine.describe()["destination"], "openai-compat")

    def test_the_block_length_follows_the_setting_but_never_goes_past_what_the_service_takes(self):
        for setting, expected in ((1800, 720.0), (720, 720.0), (600, 600.0), (30, 30.0), (5, 30.0)):
            with self.subTest(setting):
                self.assertEqual(self.engine("openai-compat", cfg=dataclasses.replace(self.cfg, asr_cloud_block_seconds=setting)).max_block_s, expected)

    def test_a_block_gets_a_long_time_limit(self):
        self.chunk(seconds=900.0)
        self.assertEqual(self.transport.calls[-1].timeout, 600.0)
        self.chunk(seconds=28.0)
        self.assertEqual(self.transport.calls[-1].timeout, 90.0)

    def test_no_vocabulary_is_sent(self):
        from provider_support import VOCAB_TEXT
        from mcap.vocab import parse_vocab_text
        self.chunk(self.engine("openai-compat", parse_vocab_text(VOCAB_TEXT)))
        self.assertNotIn(b"Acme", self.transport.calls[-1].body)
        self.assertNotIn("prompt", parse_multipart(self.transport.calls[-1]))


# ======================================================================================================================
class KeyTests(ProviderCase):
    """The key is optional: sent when one is stored for this host and port, nothing when there is none."""

    def chunk(self, engine=None):
        return (engine or self.engine("openai-compat")).transcribe_chunk(audio(3.0, 0.25), None, None)

    def test_a_server_without_a_key_gets_no_authorization_header(self):
        out = self.chunk()
        self.assertEqual(out["segments"][0]["text"][:8], "block of")
        self.assertIsNone(self.transport.calls[0].header("Authorization"))
        self.assertEqual(self.security.reads("MeetingCapture ASR openai-compat"), 1)             # it asked once and found none

    def test_a_stored_key_is_sent_as_a_bearer_token_and_read_once(self):
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        self.oai.key = OAI_KEY
        engine = self.engine("openai-compat")
        for _ in range(3):
            self.chunk(engine)
        self.assertTrue(all(c.header("Authorization") == f"Bearer {OAI_KEY}" for c in self.transport.calls))
        self.assertEqual(self.security.reads("MeetingCapture ASR openai-compat"), 1)

    def test_a_server_that_wants_a_key_says_401_and_that_is_an_authentication_error(self):
        self.oai.key = OAI_KEY
        with self.assertRaises(EngineAuthError) as ctx:
            self.chunk()
        self.assertEqual(ctx.exception.status, 401)
        self.assertEqual(len(self.transport.calls), 1)

    def test_a_key_that_cannot_be_read_is_never_replaced_by_an_anonymous_request(self):
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        self.security.set_mode("timeout")
        with self.assertRaises(EngineAuthError) as ctx:
            self.chunk()
        self.assertEqual(ctx.exception.code, "timeout")
        self.assertEqual(self.transport.calls, [])

    def test_a_malformed_key_is_refused(self):
        self.store_token("has a space", "openai-compat", OAI_HOST)
        with self.assertRaises(EngineAuthError) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.code, self.transport.calls), ("malformed", []))

    def test_the_key_is_bound_to_host_and_port(self):
        self.store_token(OAI_KEY, "openai-compat", "other.example.org")
        self.chunk()
        self.assertIsNone(self.transport.calls[0].header("Authorization"))                       # a key stored for another host is not this one's

    def test_preflight_does_not_ask_for_a_key(self):
        engine = self.engine("openai-compat")
        self.assertEqual(engine.preflight(), [])
        self.assertEqual(self.security.reads(), 0)


# ======================================================================================================================
class ErrorMappingTests(ProviderCase):
    def chunk(self, seconds=3.0):
        return self.engine("openai-compat").transcribe_chunk(audio(seconds, 0.25), None, None)

    def test_a_good_answer_of_the_fixture(self):
        self.oai.queued = [json_response(200, fixture("verbose_json_ok.json")["body"])]
        out = self.chunk(30.0)
        self.assertEqual((len(out["segments"]), out["language"], out["segments"][0]["avg_logprob"]), (2, "ko", -0.21))

    def test_401_and_403_are_authentication_errors_and_are_not_retried(self):
        for status in (401, 403):
            with self.subTest(status):
                self.transport.calls.clear()
                self.oai.queued = [json_response(status, {"error": {"message": "ZZCANARY-the patient Kim Minsu has chest pain", "code": "invalid_api_key"}})]
                with self.assertRaises(EngineAuthError) as ctx:
                    self.chunk()
                self.assertEqual((ctx.exception.status, len(self.transport.calls)), (status, 1))
                self.assertNotIn("ZZCANARY", str(ctx.exception))
        self.assertNothingLeaked()

    def test_429_waits_the_retry_after_and_tries_again_then_gives_up_as_transient(self):
        self.oai.queued = [fixture_response("error_429.json")]
        self.chunk()
        self.assertEqual((self.sleep.waits, len(self.transport.calls)), ([2.0], 2))
        self.transport.calls.clear()
        self.sleep.waits.clear()
        self.oai.queued = [fixture_response("error_429.json")] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.status, len(self.transport.calls), self.sleep.waits), (429, 3, [2.0, 2.0]))
        self.assertNothingLeaked()

    def test_5xx_is_transient_with_the_documented_retries(self):
        self.oai.queued = [json_response(503, {})] * 5
        with self.assertRaises(EngineTransient) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.status, len(self.transport.calls), self.sleep.waits), (503, 3, [1.0, 2.5]))
        self.transport.calls.clear()
        self.oai.queued = [json_response(502, {})] * 5
        with self.assertRaises(EngineTransient):
            self.chunk()
        self.assertEqual(len(self.transport.calls), 2)

    def test_another_4xx_is_a_chunk_local_error_that_is_not_retried(self):
        for status in (400, 404, 413, 422):
            with self.subTest(status):
                self.transport.calls.clear()
                self.oai.queued = [json_response(status, {"error": {"message": "ZZCANARY-the patient Kim Minsu has chest pain"}})]
                with self.assertRaises(EngineHttpError) as ctx:
                    self.chunk()
                self.assertNotIsInstance(ctx.exception, EngineTransient)
                self.assertEqual((ctx.exception.status, len(self.transport.calls)), (status, 1))
        self.assertNothingLeaked()

    def test_an_unreadable_answer_is_transient(self):
        self.oai.queued = [json_response(200, raw=b"<html>gateway</html>")]
        with self.assertRaises(EngineTransient):
            self.chunk()

    def test_a_redirect_is_never_followed(self):
        self.oai.queued = [Response(301, {"location": "https://elsewhere.example.com/"}, b"", 0, 0, 0)]
        with self.assertRaises(EnginePolicyDenied) as ctx:
            self.chunk()
        self.assertEqual((ctx.exception.code, len(self.transport.calls)), ("redirect", 1))

    def test_a_network_failure_is_transient(self):
        self.oai.queued = [egress.EgressError("timeout")] * 5
        with self.assertRaises(EngineTransient):
            self.chunk()
        self.assertEqual(len(self.transport.calls), 3)

    def test_a_closed_lane_sends_nothing(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            self.chunk()
        self.assertEqual(self.transport.calls, [])


# ======================================================================================================================
class DestinationAndPolicyTests(ProviderCase):
    def binding(self, url):
        return policy.consent_binding(dataclasses.replace(self.cfg, asr_openai_compat_url=url), "openai-compat")

    def test_any_https_dns_name_is_a_destination_the_user_may_choose(self):
        for url, host, port in ((OAI_URL, OAI_HOST, 443), ("https://api.openai.com/v1", "api.openai.com", 443), ("https://stt.example.org:8443", "stt.example.org", 8443),
                                ("HTTPS://STT.Example.org/v1/", "stt.example.org", 443)):
            with self.subTest(url):
                binding, why = self.binding(url)
                self.assertEqual((why, binding["host"], binding["port"], binding["region"], binding["protocol"], binding["backend_kind"], binding["model"]),
                                 (None, host, port, "", "openai-audio-transcriptions", "cloud", ""))

    def test_but_never_plain_http_an_ip_address_credentials_or_a_query(self):
        for url in ("http://stt.example.org/v1", "https://127.0.0.1/v1", "https://192.168.1.5:8000/v1", "https://[::1]/v1", "https://localhost/v1", "https://user:pw@stt.example.org/v1",
                    f"https://{OAI_HOST}/v1?api_key=1", f"https://{OAI_HOST}/v1#x", f"https://{OAI_HOST}./v1", "https://stt/v1", f"https://{OAI_HOST}/v1/../x"):
            with self.subTest(url):
                self.assertEqual(self.binding(url), (None, "bad-host"))
        self.assertEqual(self.binding("")[1], "not-configured")

    def test_the_policy_row_says_the_destination_is_chosen_by_the_user(self):
        meta = policy.ENGINE_META["openai-compat"]
        self.assertEqual(meta["destination"], "destination chosen by the user")
        self.assertEqual((meta["kind"], meta["residency"], meta["lane"], meta["status"], meta["backend_kind"]), ("cloud", "foreign", "asr_cloud", "ready", "cloud"))
        self.assertNotIn("destination", policy.ENGINE_META["clova"])

    def test_a_consent_for_another_host_does_not_cover_it_and_the_host_is_all_that_binds(self):
        decision = make_decision(self.cfg, "openai-compat", consents=(oai_consent(host="other.example.org"),))
        self.assertEqual(decision.primary, "whisper")
        self.assertIn("consent-mismatch", " ".join(decision.notes))
        other_model = dataclasses.replace(self.cfg, asr_openai_compat_model="another-model", asr_openai_compat_url=f"https://{OAI_HOST}/other/base")
        self.assertEqual(make_decision(other_model, "openai-compat", consents=(oai_consent(),)).primary, "openai-compat")

    def test_a_settings_file_edited_after_the_decision_sends_nothing(self):
        decision = self.decision("openai-compat")
        edited = dataclasses.replace(self.cfg, asr_openai_compat_url="https://elsewhere.example.org/v1")
        engine = self.engine("openai-compat", cfg=edited, decision=decision)
        with self.assertRaises(EnginePolicyDenied) as ctx:
            engine.transcribe_chunk(audio(2.0, 0.25), None, None)
        self.assertEqual((ctx.exception.code, self.transport.calls, self.security.reads()), ("host_not_consented", [], 0))

    def policy_for(self, **asr):
        doc = company_doc(lanes={"asr_cloud": "allow"}, approvals={"asr_cloud": "TICKET-9"},
                          asr={"allowed_engines": ["whisper", "clova", "openai-compat"], "allowed_hosts": [OAI_HOST, "clovaspeech-gw.ncloud.com"], **asr})
        return company_org(self.root, doc)

    def test_a_company_policy_needs_allow_foreign_for_a_destination_the_user_chose(self):
        org = self.policy_for(allow_foreign=False)
        decision = make_decision(self.cfg, "openai-compat", consents=(oai_consent(),), org=org)
        self.assertEqual((decision.primary, decision.reason), ("whisper", "policy-foreign"))
        org = self.policy_for(allow_foreign=True)
        self.assertEqual(make_decision(self.cfg, "openai-compat", consents=(oai_consent(),), org=org).primary, "openai-compat")

    def test_the_lane_the_engine_list_and_the_host_list_of_a_policy_apply_like_for_azure(self):
        cases = ((self.policy_for(allow_foreign=True, allowed_engines=["whisper"]), "policy-engine"),
                 (self.policy_for(allow_foreign=True, allowed_hosts=["asr.example.internal"]), "policy-host"),
                 (company_org(self.root, company_doc(asr={"allowed_engines": ["whisper", "openai-compat"], "allow_foreign": True,
                                                         "allowed_hosts": [OAI_HOST]})), "policy-lane"),                    # asr_cloud is denied in the corpus policy
                 (company_org(self.root, company_doc(lanes={"asr_cloud": "allow"}, asr={"allowed_engines": ["whisper", "openai-compat"],
                                                                                         "allow_foreign": True, "allowed_hosts": [OAI_HOST]})), "policy-unapproved"))
        for org, reason in cases:
            with self.subTest(reason):
                decision = make_decision(self.cfg, "openai-compat", consents=(oai_consent(),), org=org)
                self.assertEqual((decision.primary, decision.reason), ("whisper", reason))

    def test_a_local_only_meeting_never_sends_anything(self):
        decision = make_decision(self.cfg, "openai-compat", consents=(oai_consent(),), local_only=True)
        self.assertEqual((decision.primary, decision.allow_egress, decision.reason), ("whisper", False, "local_only"))
        self.assertEqual(self.transport.calls, [])

    def test_nothing_is_selected_without_the_setting_and_the_consent(self):
        for kw in ({"consents": ()}, {"consents": (oai_consent(),)}):
            decision = make_decision(dataclasses.replace(self.cfg, asr_openai_compat_url=""), "openai-compat", **kw)
            self.assertEqual((decision.primary, decision.allow_egress), ("whisper", False))
        self.assertEqual(make_decision(self.cfg, "openai-compat", consents=()).primary, "whisper")


# ======================================================================================================================
class SizeLimitTests(ProviderCase):
    """A service that refuses a long upload (OpenAI: 25 MB per file) answers a block with HTTP 413. Nothing is lost: the engine remembers the size it
    was refused, the track goes on in shorter blocks, and the same request is not sent twice."""
    LIMIT = 70 * SR * 2                         # 70 s of 16 kHz mono WAV (a hair more: the header and the form fields are in the request)

    def setUp(self):
        super().setUp()
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        self.cfg.asr_language = "en"
        accepts = self.transport.handler
        self.refused = []

        def limited(call):
            if len(call.body) > self.LIMIT + 2000:
                self.refused.append(len(call.body))
                return json_response(413, {"error": {"message": "ZZCANARY-the patient Kim Minsu has chest pain", "code": "request_too_large"}})
            return accepts(call)

        self.transport.handler = limited

    def test_the_engine_remembers_what_the_service_refused_and_sends_nothing_that_long_again(self):
        engine = self.engine("openai-compat")
        with self.assertRaises(EngineBlockDeclined) as ctx:
            engine.transcribe_chunk(audio(100.0, 0.25), None, None)
        self.assertEqual((ctx.exception.status, ctx.exception.code, len(self.refused), len(self.transport.calls)), (413, "block_too_large", 1, 1))
        self.assertEqual(engine.max_block_s, 50.0)                              # the next blocks are packed at half of the refused one
        with self.assertRaises(EngineBlockDeclined):
            engine.transcribe_chunk(audio(60.0, 0.25), None, None)
        self.assertEqual(len(self.transport.calls), 1)                          # refused locally: no request, nothing billed
        engine.transcribe_chunk(audio(40.0, 0.25), None, None)                  # shorter than that is sent as before
        self.assertEqual(len(self.transport.calls), 2)
        self.assertNothingLeaked()

    def test_a_413_for_a_chunk_is_that_chunks_own_error_and_teaches_nothing(self):
        self.LIMIT = 10 * SR * 2
        engine = self.engine("openai-compat")
        with self.assertRaises(EngineHttpError) as ctx:
            engine.transcribe_chunk(audio(20.0, 0.25), None, None)             # 20 s: a chunk, not a block
        self.assertNotIsInstance(ctx.exception, EngineBlockDeclined)
        self.assertEqual((ctx.exception.status, engine.max_block_s), (413, 720.0))

    def test_the_provider_ceiling_keeps_a_default_block_under_the_25_mb_of_openai(self):
        self.assertEqual(self.engine("openai-compat").max_block_s, 720.0)
        self.assertLess(720 * SR * 2 + 44, 25 * 1000 * 1000)

    def test_a_track_is_decoded_in_shorter_blocks_after_the_first_413_and_every_second_of_speech_is_sent_once_more(self):
        run_cfg, router = self.routed(self.cfg, "openai-compat")
        chunks = vadmod.plan_chunks(LONG_REGIONS, region_vad(LONG_REGIONS, LONG_TOTAL).db, LONG_TOTAL)
        res = asr.transcribe_track(np.zeros(int(LONG_TOTAL * SR), np.float32), router, run_cfg, Vocab(), track="remote", language="en",
                                   vad=region_vad(LONG_REGIONS, LONG_TOTAL))
        self.assertEqual(len(self.refused), 1)                                  # one refused request, then the engine knew
        self.assertEqual(len(self.posts(TRANSCRIBE_PATH)), 4)                   # that one + three blocks of at most 50 s (two chunks, one, one)
        self.assertEqual((res.info["blocks"], res.info["split_blocks"], res.info.get("failed_chunks", 0)), (1, 1, 0))
        self.assertEqual(len(res.segments), 3)
        sent = sum(int(text.split()[2]) for text in (s["text"] for s in res.segments))
        self.assertEqual(sent, sum(int(b * SR) - int(a * SR) for a, b, _ in chunks))     # every chunk of speech was transcribed exactly once
        self.assertNothingLeaked()


class ProvenanceAndLeakTests(ProviderCase):
    def test_the_usage_line_and_the_provenance_of_a_block(self):
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        engine = self.engine("openai-compat")
        engine.transcribe_chunk(audio(25.0, 0.25), None, None)
        line, = usage_lines(self.cfg)
        self.assertEqual((line["engine"], line["kind"], line["host"], line["op"], line["outcome"], line["requests"], line["audio_s"]),
                         ("openai-compat", "cloud", OAI_HOST, "chunk", "ok", 1, 25.0))
        block = engine.provenance()
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["region"], block["protocol"], block["chunks"]),
                         ("openai-compat", "cloud", "cloud", "openai-compat", "foreign", "openai-audio-transcriptions", {"openai-compat": 1}))
        self.assertNotIn(OAI_HOST, json.dumps(block))
        self.assertNotIn(OAI_KEY, json.dumps(block) + json.dumps(line))

    def test_nothing_secret_or_foreign_reaches_a_log_a_state_file_a_usage_line_or_an_error(self):
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        engine = self.engine("openai-compat")
        self.oai.key = "a-different-key"
        for queued in ([json_response(401, {"error": {"message": "ZZCANARY-the patient Kim Minsu has chest pain"}})],
                       [fixture_response("error_429.json")] * 5, [json_response(422, {"detail": "ZZCANARY-the patient Kim Minsu has chest pain"})]):
            self.oai.queued = list(queued)
            with self.assertRaises(EngineError):
                engine.transcribe_chunk(audio(3.0, 0.25), None, None)
        engine.preflight()
        engine.describe()
        self.assertNothingLeaked()


if __name__ == "__main__":
    unittest.main()
