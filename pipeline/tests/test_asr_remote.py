"""asr_remote.py (docs/ASR_PROTOCOL.md): the client half of mcap-asr/1.

The engine runs through a REAL asr_router/asr_http/EgressGuard stack in front of an in-process Transport whose handler is ``FakeServer``: a
small server core written from docs/ASR_PROTOCOL.md (headers, lengths, bearer tokens, the canonical vocabulary digest, the idempotency cache,
enrollment codes, renewal, language ID). It is NOT asr_server: the two halves share the document, not code. No socket opens (NoNetworkCase),
the Keychain is the fake `security` of notes_cli_support (plus ``KeychainRun`` for the ``security -i`` write), time is a FakeClock.

Run: python -m unittest discover -s pipeline/tests
"""
import ast
import dataclasses
import hashlib
import json
import logging
import os
import re
import shlex
import stat
import subprocess
import sys
import unittest
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import numpy as np

from asr_support import (BUILD_SHA, CA_SHA, CANARY_FRAGMENTS, CANARY_TEXT, HOST, MACHINE, NOW, SR, TOKEN, AsrCase, FakeLocalEngine, FakeTransport, audio,
                         chunk_answer, consent_entry, error_answer, health_document, json_response, make_decision, make_run, usage_lines)
from golden import make_golden as mg

from mcap import apikey, asr, asr_creds, asr_engines, asr_remote, policy
from mcap import state as mcap_state
from mcap.asr_engines import EngineAuthError, EngineError, EnginePolicyDenied, EngineTransient, engine_caps
from mcap.asr_http import EngineHttpError, pcm16
from mcap.asr_remote import (ATTEST_FILE, TOKEN_SHAPE, RemoteEngine, attest_status, canonical_vocab, enroll, store_token, vocab_terms)
from mcap.asr_router import RoutedEngine, build_engine
from mcap.egress import EgressGuard, Response
from mcap.vocab import Vocab, parse_vocab_text

logging.getLogger("mcap").addHandler(logging.NullHandler())

CODE = "ABCD-EFGH-JKLM"                                   # the one-time enrollment code of FakeServer
NEW_TOKEN = "mcap1_11223344_" + "Wx7yZ" * 6 + "cd"        # a second token shaped like a real one (8 hex, 32 url-safe)
VOCAB = parse_vocab_text("Acme\nAcmeScan-CXR\n")
KO_TERMS = ["액미", "PACS"]
EXPIRES = (NOW + timedelta(days=90)).isoformat(timespec="seconds")      # what a token issued at NOW expires at (90 days)
IDEM = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")
FIXED_MESSAGE_WORDS = ("the server", "the engine", "the destination", "the request", "the health", "the language", "the renewal", "the enrollment",
                       "external ASR", "the time limit")


class Records(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage() + (self.format(record) if record.exc_info else ""))


# ======================================================================================================================
class FakeServer:
    """The server core of docs/ASR_PROTOCOL.md, enough for the client: ``server(call) -> Response`` is the handler of a ``FakeTransport``.
    ``fail(prefix, *answers)`` queues answers (a ``Response`` or an exception) that the next requests under that path get instead of the
    normal handling (after the protocol and token checks). Everything the tests look at is on the object: ``vocabs``, ``computed``,
    ``tokens`` (token -> days left), ``codes``, ``minted``."""

    def __init__(self, *, supports_lid=True, confidence="logprob", kind="server", days=71):
        self.tokens = {TOKEN: days}
        self.health = health_document(kind=kind, supports_lid=supports_lid, confidence=confidence)
        self.lid_supported = supports_lid
        self.confidence = confidence
        self.vocabs: dict = {}
        self.idem: dict = {}
        self.codes = {"ABCDEFGHJKLM": "mic"}
        self.minted: list = []
        self.computed = 0
        self.queued: list = []
        self.lid_override = None
        self.chunk_override = None
        self.enroll_throttled = False

    # ------------------------------------------------------------------------------------------ helpers
    def fail(self, prefix: str, *answers) -> None:
        self.queued.extend((prefix, a) for a in answers)

    def forget_vocabularies(self) -> None:
        self.vocabs.clear()

    @staticmethod
    def error(status, code, **kw):
        return error_answer(status, code, **kw)

    def _bearer(self, headers):
        match = re.fullmatch(r"Bearer (mcap1_[0-9a-f]{8}_[A-Za-z0-9_-]{32})", headers.get("authorization", ""))
        return match.group(1) if match and match.group(1) in self.tokens else None

    # ------------------------------------------------------------------------------------------ the core
    def __call__(self, call):
        headers = {k.lower(): v for k, v in call.headers.items()}
        path = call.path
        if headers.get("x-mcap-proto") != "mcap-asr/1":
            return json_response(426, {"error": {"code": "proto_mismatch", "message": "m"}, "supported": ["mcap-asr/1"]})
        token = self._bearer(headers)
        detail = parse_qs(urlsplit(call.target).query).get("detail") == ["1"]
        open_route = path == "/v1/enroll" or (path == "/v1/health" and not detail)
        if token is None and not open_route:
            return self.error(401, "unauthorized")
        for index, (prefix, answer) in enumerate(self.queued):
            if path.startswith(prefix):
                del self.queued[index]
                return answer
        if path == "/v1/health":
            doc = {"proto": "mcap-asr/1", "ok": True} if not detail else {**self.health, "token": {"expires_in_days": self.tokens[token]}}
            return json_response(200, doc)
        if path == "/v1/enroll":
            return self._enroll(call)
        if path == "/v1/token/renew":
            return self._renew(token)
        if path == "/v1/purge":
            count = len(self.vocabs) + len(self.idem)
            self.vocabs.clear()
            self.idem.clear()
            return json_response(200, {"purged": count})
        if path.startswith("/v1/vocab/"):
            return self._vocab(call, path.rsplit("/", 1)[1])
        if path == "/v1/chunk":
            return self._chunk(call, headers, token)
        if path == "/v1/lid":
            return self._lid(call, headers)
        return self.error(404, "not_found")

    def _enroll(self, call):
        if self.enroll_throttled:
            return self.error(429, "enroll_throttled", retry_after=30)
        try:
            body = json.loads(call.body.decode("utf-8"))
            code = re.sub(r"[\s-]+", "", body["code"]).upper()
        except (ValueError, KeyError, TypeError):
            return self.error(400, "bad_request")
        user = self.codes.pop(code, None)
        if user is None:
            return self.error(401, "enroll_invalid", message=CANARY_TEXT)
        token = f"mcap1_{len(self.minted) + 1:08x}_" + "Ab3dE" * 6 + "fg"
        self.minted.append(token)
        self.tokens[token] = 90
        return json_response(200, {"token": token, "expires": EXPIRES, "user": user})

    def _renew(self, token):
        if self.tokens[token] > 14:
            return self.error(400, "bad_request")
        new = f"mcap1_{0x2000 + len(self.minted):08x}_" + "Qw9eR" * 6 + "ty"
        self.minted.append(new)
        self.tokens[new] = 90
        return json_response(200, {"token": new, "expires": EXPIRES})

    def _vocab(self, call, digest):
        try:
            terms = json.loads(call.body.decode("utf-8"))["terms"]
        except (ValueError, KeyError, TypeError):
            return self.error(400, "bad_request")
        canonical = json.dumps({"terms": terms}, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        if hashlib.sha256(canonical).hexdigest() != digest or call.body != canonical:
            return self.error(400, "bad_request")
        self.vocabs[digest] = terms
        return Response(204, {}, b"", 0, 0, 0)

    def _chunk(self, call, headers, token):
        samples = int(headers.get("x-mcap-samples", "0"))
        if samples < 1 or len(call.body) != 2 * samples or headers.get("content-type") != "application/octet-stream":
            return self.error(400, "bad_request")
        if samples > 496000:
            return self.error(413, "payload_too_large")
        vocab = headers.get("x-mcap-vocab")
        if vocab and vocab not in self.vocabs:
            return self.error(404, "vocab_unknown")
        key = (token, headers.get("x-mcap-idem"))
        digest = hashlib.sha256(call.body).hexdigest()
        if key in self.idem:
            if self.idem[key][0] != digest:
                return self.error(409, "idem_conflict")
            return self.idem[key][1]
        lang = headers.get("x-mcap-lang", "auto")
        terms = self.vocabs.get(vocab, [])
        style = headers.get("x-mcap-prompt", "none")
        prompt = ""
        if style != "none" and terms:
            frame = {"ko": "다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: ", "en": "A medical AI meeting. Terms: "}.get(lang, "A medical AI meeting. Terms: ")
            prompt = (frame if style == "frame+list" else "") + ", ".join(terms)
        opaque = self.confidence != "logprob"
        doc = chunk_answer(f"chunk {samples} samples", language="en" if lang == "auto" else lang, duration=samples / SR, prompt_text=prompt,
                           numbers=not opaque)
        if self.chunk_override is not None:
            doc = self.chunk_override(doc)
        response = json_response(200, doc)
        self.idem[key] = (digest, response)
        self.computed += 1
        return response

    def _lid(self, call, headers):
        if not self.lid_supported:
            return self.error(400, "bad_request")
        try:
            counts = [int(x) for x in headers["x-mcap-clips"].split(",")]
        except (KeyError, ValueError):
            return self.error(400, "bad_request")
        if len(counts) > 12 or any(not 0 < n <= 96000 for n in counts):
            return self.error(413, "payload_too_large")
        if len(call.body) != 2 * sum(counts):
            return self.error(400, "bad_request")
        langs = headers.get("x-mcap-langs", "ko,en").split(",")
        if self.lid_override is not None:
            return json_response(200, {"proto": "mcap-asr/1", "op": "lid", "results": self.lid_override(counts, langs)})
        pcm = np.frombuffer(call.body, dtype="<i2").astype(np.float32) / 32768.0
        results, offset = [], 0
        for n in counts:
            korean = float(np.mean(pcm[offset:offset + n])) > 0.15                # a loud clip is Korean, a quiet one English
            offset += n
            probs = {code: 0.05 for code in langs}
            probs["ko" if korean else "en"] = 0.95
            results.append({**probs, "top": "ko" if korean else "en"})
        return json_response(200, {"proto": "mcap-asr/1", "op": "lid", "results": results})


class KeychainRun:
    """``subprocess.run`` for the `security` tool: ``security -i`` (the command on stdin, how the token is written) is carried out against
    the fake Keychain; every other call (the read-back) runs the fake shim. ``rc`` != 0 simulates a failing tool, ``stored=False`` a tool
    that exits 0 and keeps nothing. ``calls`` records argv, stdin and the environment of every call."""

    def __init__(self, case, rc=0, stored=True):
        self.case, self.rc, self.stored, self.calls = case, rc, stored, []

    def __call__(self, argv, **kw):
        self.calls.append({"argv": list(argv), "input": kw.get("input"), "env": dict(kw.get("env") or {})})
        if len(argv) >= 2 and argv[1] == "-i":
            if self.rc == 0 and self.stored:
                words = shlex.split(kw["input"].decode("utf-8"))
                self.case.security.store_item(words[words.index("-w") + 1], words[words.index("-s") + 1], words[words.index("-a") + 1])
            return subprocess.CompletedProcess(argv, self.rc, stdout=b"", stderr=b"")
        return subprocess.run(argv, **kw)

    def writes(self):
        return [c for c in self.calls if len(c["argv"]) >= 2 and c["argv"][1] == "-i"]


def org_consent(*builds, use="both", expires="2027-10-14"):
    """One organisation consent for the relay (always the same binding, so every one of them has the same id) with this allow list of builds."""
    return policy.OrgConsent(engine="remote", host=HOST, port=443, protocol="mcap-asr/1", backend_kind="server", use=use, expires=expires,
                             ca_sha256=CA_SHA, attest_build_sha256=tuple(builds))


def org_policy(*, builds=(BUILD_SHA,), hosts=(HOST,), lanes=None, engines=("remote",), valid=True, send_vocab=True, consents=None):
    """A valid company policy with one organisation consent for the relay (what policy.load_org_policy would have made of policy.json), or
    exactly the ``consents`` given (duplicates of one binding, as the policy parser accepts them)."""
    consent = org_consent(*builds)
    return dataclasses.replace(policy.absent_policy(), present=True, valid=valid, profile="company",
                               org_consents=tuple(consents) if consents is not None else (consent,),
                               allowed_hosts=hosts, allowed_engines=engines, lanes=lanes or {lane: "allow" for lane in policy.LANES},
                               send_vocab={"server": send_vocab, "cloud": False})


# ======================================================================================================================
class RemoteCase(AsrCase):
    """An engine over a real guard in front of ``FakeServer``. ``rand`` is 0.5 (no jitter: the waits are exactly the schedule)."""

    def setUp(self):
        super().setUp()
        self.server = FakeServer()
        self.transport = FakeTransport(handler=self.server, clock=self.clock)
        self.keychain = KeychainRun(self)
        self.records = Records()
        logging.getLogger("mcap").addHandler(self.records)
        self.addCleanup(logging.getLogger("mcap").removeHandler, self.records)
        self.idems = 0

    def idem(self):
        self.idems += 1
        return f"00000000-0000-4000-8000-{self.idems:012d}"

    def decision(self, **kw):
        return make_decision(kw.pop("cfg", self.cfg), "remote", **kw)

    def engine(self, vocab=None, *, decision=None, org=None, uuid_idem=False, **kw):
        """A ``RemoteEngine`` as ``asr_router.build_member`` makes one (guard, gate), with the fixtures of this case injected: the machine id, a
        counting idempotency key (``uuid_idem=True``: the real uuid4 default), the organisation policy ``org`` (default: none), the Keychain tool."""
        decision = decision or self.decision()
        guard = EgressGuard({HOST: decision.hosts[HOST]}, engine_id="remote", consent_id=decision.consent_ids["remote"], transport=self.transport,
                            clock=self.clock, pre_connect=self.gate, trust="private")
        kw.setdefault("machine_id_fn", lambda: "machine-x")
        kw.setdefault("now_fn", lambda: NOW)                    # the date a consent's expiry is held against: the same NOW the decisions are made at
        if not uuid_idem:
            kw.setdefault("idem_fn", self.idem)
        return RemoteEngine(self.cfg, vocab, decision, guard, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock,
                            run_id="0123456789abcdef", policy_fn=(lambda: org if org is not None else policy.absent_policy()),
                            security_run=self.keychain, **kw)

    def loaded(self, vocab=None, **kw):
        engine = self.engine(vocab, **kw)
        engine.load()
        return engine

    def paths(self, *prefixes):
        return [f"{c.method} {c.path}" for c in self.transport.calls if not prefixes or c.path.startswith(prefixes)]

    def chunks(self):
        return self.transport.requests("/v1/chunk")

    def everything_written(self):
        parts = [p.read_bytes().decode("utf-8", "replace") for p in sorted(self.root.rglob("*")) if p.is_file()]
        return "\n".join(parts + self.records.lines)

    def assertNothingLeaked(self, *extra):
        text = self.everything_written()
        for needle in CANARY_FRAGMENTS + (TOKEN,) + tuple(extra):
            self.assertNotIn(needle, text)

    def keychain_token(self, host=HOST, port=443):
        with asr_creds.secret("remote", host, port) as value:
            return value


# ======================================================================================================================
class VocabularyHelperTests(unittest.TestCase):
    def test_the_canonical_form_matches_the_vectors_of_the_protocol(self):
        # docs/ASR_PROTOCOL.md 12.1: compact, keys sorted, non-ASCII kept, the order of the terms kept
        body, digest = canonical_vocab(["Acme", "AcmeScan-CXR"])
        self.assertEqual((body, digest), (b'{"terms":["Acme","AcmeScan-CXR"]}',
                                          "87ed861a28a3224008a330d64606c77606bc4c71f41b3c7d92a359ac0bb69070"))
        body, digest = canonical_vocab(KO_TERMS)
        self.assertEqual(body.decode("utf-8"), '{"terms":["액미","PACS"]}')
        self.assertEqual(digest, "5be960d3f9c4edcc23a746cdae69aad23fec5bd27566ea6635b52606bd95d012")

    def test_terms_the_server_would_refuse_are_left_out_and_the_order_is_kept(self):
        long_term = "x" * 201
        terms = vocab_terms(Vocab(terms=["B", "", "  ", "a\nb", long_term, "tab\there", "ok term", "bell\x07", "한국어", "A\ud800"]))
        self.assertEqual(terms, ["B", "ok term", "한국어"])
        self.assertEqual(vocab_terms(None), [])
        self.assertEqual(vocab_terms(SimpleNamespace(terms="Acme")), [])
        self.assertEqual(vocab_terms(Vocab(terms=[5, None, "x"])), ["x"])

    def test_the_list_is_cut_at_2000_terms_and_64_kib(self):
        many = Vocab(terms=[f"term{i}" for i in range(5000)])
        self.assertEqual(len(vocab_terms(many)), 2000)
        wide = Vocab(terms=[("w" * 190) + f"{i:03d}" for i in range(1000)])
        kept = vocab_terms(wide)
        body, _ = canonical_vocab(kept)
        self.assertLessEqual(len(body), 64 * 1024)
        self.assertGreater(len(kept), 300)
        self.assertEqual(kept, [t for t in wide.terms[:len(kept)]])              # a prefix: file order is priority order


# ======================================================================================================================
class ChunkWireTests(RemoteCase):
    def test_a_chunk_request_has_the_wire_format_of_the_protocol(self):
        engine = self.loaded(VOCAB)
        result = engine.transcribe_chunk(audio(2.0, 0.25), "ko", None)
        call = self.chunks()[0]
        self.assertEqual((call.method, call.target), ("POST", "/v1/chunk"))
        _, digest = canonical_vocab(["Acme", "AcmeScan-CXR"])
        expected = {"X-MCAP-Proto": "mcap-asr/1", "X-MCAP-Client": asr_remote.CLIENT, "X-MCAP-Run": "0123456789abcdef",
                    "X-MCAP-Machine": hashlib.sha256(b"machine-x").hexdigest()[:16], "Content-Type": "application/octet-stream",
                    "X-MCAP-Samples": "32000", "X-MCAP-Lang": "ko", "X-MCAP-Langs": "ko,en", "X-MCAP-Prompt": "frame+list",
                    "X-MCAP-Vocab": digest, "Authorization": f"Bearer {TOKEN}"}
        for name, value in expected.items():
            self.assertEqual(call.header(name), value, name)
        self.assertTrue(call.header("X-MCAP-Idem"))
        self.assertEqual(call.body, pcm16(audio(2.0, 0.25)))
        self.assertEqual(len(call.body), 2 * 32000)
        self.assertEqual((result["text"], result["language"]), ("chunk 32000 samples", "ko"))
        self.assertEqual(result["segments"][0]["avg_logprob"], -0.2)

    def test_a_real_uuid4_is_the_default_idempotency_key_and_changes_per_request(self):
        engine = self.loaded(None, uuid_idem=True)
        engine.transcribe_chunk(audio(), "en", None)
        engine.transcribe_chunk(audio(), "en", None)
        keys = [c.header("X-MCAP-Idem") for c in self.transport.calls]
        self.assertTrue(all(IDEM.fullmatch(k) for k in keys), keys)
        self.assertEqual(len(set(keys)), len(keys))                              # health, chunk, chunk: three logical requests

    def test_the_language_header_is_a_code_or_auto(self):
        engine = self.loaded()
        for given, sent in ((None, "auto"), ("", "auto"), ("auto", "auto"), ("ko", "ko"), ("EN", "en"), ("korean", "auto"), (" ja ", "ja"),
                            (7, "auto"), ("k", "auto"), ("ko\r\nX-A: 1", "auto")):
            with self.subTest(given=given):
                engine.transcribe_chunk(audio(), given, None)
                self.assertEqual(self.chunks()[-1].header("X-MCAP-Lang"), sent)

    def test_the_restriction_set_of_auto_comes_from_asr_languages(self):
        self.cfg.asr_languages = "ja, ko ,en"
        engine = self.loaded()
        engine.transcribe_chunk(audio(), None, None)
        self.assertEqual(self.chunks()[-1].header("X-MCAP-Langs"), "ja,ko,en")

    def test_the_prompt_text_of_the_server_feeds_the_echo_guard(self):
        engine = self.loaded(VOCAB)
        self.assertIsNone(engine.prompt_text_seen())
        engine.transcribe_chunk(audio(), "en", None)
        engine.transcribe_chunk(audio(), "ko", None)
        seen = engine.prompt_text_seen()
        self.assertIn("A medical AI meeting. Terms: Acme, AcmeScan-CXR", seen)
        self.assertIn("용어: Acme, AcmeScan-CXR", seen)

    def test_an_opaque_backend_has_no_numbers_even_when_the_server_sends_some(self):
        self.server.health["confidence"] = "opaque"
        self.server.chunk_override = lambda doc: dict(doc, avg_logprob=-0.2, segments=[dict(s, avg_logprob=-0.2, no_speech_prob=0.1, compression_ratio=1.5)
                                                                                         for s in doc["segments"]])
        engine = self.loaded()
        self.assertEqual(engine_caps(engine).confidence, "opaque")
        result = engine.transcribe_chunk(audio(), "en", None)
        seg = result["segments"][0]
        self.assertEqual((result["avg_logprob"], seg["avg_logprob"], seg["no_speech_prob"], seg["compression_ratio"]), (None, None, None, None))

    def test_segment_times_are_clamped_and_hostile_segments_are_dropped(self):
        def hostile(doc):
            good = {"start": 0.5, "end": 99.0, "text": "late", "avg_logprob": -0.1}
            return dict(doc, segments=[good, {"start": "x", "end": 1, "text": "bad times"}, {"start": 0, "end": 1, "text": 5}, "junk", None,
                                       {"start": float("nan"), "end": 1.0, "text": "nan"}, {"start": -3.0, "end": 0.5, "text": "early"},
                                       {"start": 1.0, "end": 0.2, "text": "backwards"}])
        self.server.chunk_override = hostile
        engine = self.loaded()
        segs = engine.transcribe_chunk(audio(2.0), "en", None)["segments"]
        self.assertEqual([s["text"] for s in segs], ["late", "early", "backwards"])
        self.assertTrue(all(0.0 <= s["start"] <= s["end"] <= 3.0 for s in segs), segs)        # never past the chunk (plus the 1 s slack)

    def test_a_lone_surrogate_in_an_answer_is_made_writable(self):
        """JSON ``"\\ud800"`` is valid to json.loads and not to str.encode('utf-8'): the transcript writer would fail after the whole run."""
        def hostile(doc):
            seg = dict(doc["segments"][0], text="seg\ud800 ment")
            return dict(doc, text="hi\ud800 there \udfff", language="e\udfffn", prompt_text="prompt\ud83d", segments=[seg, {**seg, "text": "ok 안녕"}])
        self.server.chunk_override = hostile
        engine = self.loaded()
        result = engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((result["text"], result["language"]), ("hi? there ?", "e?n"))
        self.assertEqual([s["text"] for s in result["segments"]], ["seg? ment", "ok 안녕"])
        self.assertEqual(engine.prompt_text_seen(), "prompt?")                                          # it feeds the echo guard and the transcript
        json.dumps(result, ensure_ascii=False).encode("utf-8")                                         # what state.atomic_write_json does
        engine.prompt_text_seen().encode("utf-8")

    def test_a_server_text_that_is_fine_is_left_exactly_as_it_is(self):
        self.server.chunk_override = lambda doc: dict(doc, text="안녕 hello 😀", prompt_text="용어: Acme",
                                                      segments=[dict(doc["segments"][0], text="안녕 hello 😀")])
        engine = self.loaded()
        result = engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((result["text"], result["segments"][0]["text"], engine.prompt_text_seen()), ("안녕 hello 😀", "안녕 hello 😀", "용어: Acme"))

    def test_an_answer_that_cannot_be_used_is_transient_with_a_fixed_sentence(self):
        engine = self.loaded()
        cases = [json_response(200, raw=b"not json"), json_response(200, ["a"]), json_response(200, {"proto": "mcap-asr/2", "segments": []}),
                 json_response(200, {"proto": "mcap-asr/1", "op": "lid", "segments": []}), json_response(200, {"proto": "mcap-asr/1", "text": "x"}),
                 json_response(200, {"proto": "mcap-asr/1", "segments": "x"}), json_response(200, raw=b"\xff\xfe"), json_response(200, raw=b"[" * 5000)]
        for answer in cases:
            with self.subTest(body=answer.body[:20]):
                self.transport.script = [answer]
                with self.assertRaises(EngineTransient) as cm:
                    engine.transcribe_chunk(audio(), "en", None)
                self.assertIn(str(cm.exception), ("the engine answer could not be used", "the engine answer could not be read"))

    def test_a_chunk_over_the_server_limit_is_refused_without_a_request(self):
        engine = self.loaded()
        before = len(self.transport.calls)
        with self.assertRaises(EngineHttpError) as cm:
            engine.transcribe_chunk(audio(31.5), "en", None)
        self.assertEqual((cm.exception.status, cm.exception.code), (413, "payload_too_large"))
        self.assertEqual(len(self.transport.calls), before)

    def test_an_empty_chunk_sends_nothing(self):
        engine = self.loaded()
        before = len(self.transport.calls)
        result = engine.transcribe_chunk(np.zeros(0, np.float32), "ko", None)
        self.assertEqual((result["segments"], result["text"], len(self.transport.calls)), ([], "", before))

    def test_build_request_is_pure(self):
        engine = self.loaded(VOCAB)
        a = engine.build_request(audio(1.0), "ko")
        self.assertEqual(a, engine.build_request(audio(1.0), "ko"))
        self.assertEqual(a[:2], ("POST", "/v1/chunk"))
        self.assertEqual(len(self.transport.calls), 1)                                               # only the health request of load()


# ======================================================================================================================
class HealthTests(RemoteCase):
    def test_load_reads_the_detailed_health_once_within_five_seconds(self):
        engine = self.engine()
        engine.load()
        engine.load()
        calls = self.transport.calls
        self.assertEqual([(c.method, c.target) for c in calls], [("GET", "/v1/health?detail=1")])
        self.assertEqual((calls[0].timeout, calls[0].header("Authorization"), calls[0].header("X-MCAP-Proto")), (5.0, f"Bearer {TOKEN}", "mcap-asr/1"))
        self.assertEqual(self.security.reads(), 1)

    def test_a_server_that_keeps_data_is_refused(self):
        for patch in ({"retention": {"mode": "disk", "audio_disk": False, "text_disk": False}},
                      {"retention": {"mode": "none", "audio_disk": True, "text_disk": False}},
                      {"retention": {"mode": "none", "audio_disk": False, "text_disk": True}}, {"retention": {}}, {"retention": None}):
            with self.subTest(patch=patch):
                self.server.health.update(patch)
                engine = self.engine()
                with self.assertRaises(EnginePolicyDenied) as cm:
                    engine.load()
                self.assertEqual(cm.exception.code, "retention")
                self.assertEqual(self.chunks(), [])

    def test_the_other_refusals(self):
        for patch, code in (({"kind": "cloud"}, "kind"), ({"kind": None}, "kind"), ({"proto": "mcap-asr/2"}, "proto"), ({"ok": False}, "not-ok")):
            with self.subTest(patch=patch):
                self.server.health = health_document(**patch)
                with self.assertRaises(EnginePolicyDenied) as cm:
                    self.engine().load()
                self.assertEqual(cm.exception.code, code)

    def test_http_statuses_of_the_health_request(self):
        for status, cls in ((401, EngineAuthError), (403, EngineAuthError), (426, EnginePolicyDenied), (404, EnginePolicyDenied),
                            (500, EngineTransient), (503, EngineTransient), (429, EngineTransient)):
            with self.subTest(status=status):
                self.server.fail("/v1/health", error_answer(status, "x"))
                with self.assertRaises(cls) as cm:
                    self.engine().load()
                self.assertEqual(cm.exception.status, status)

    def test_an_unreachable_or_unreadable_server_is_transient_after_one_request(self):
        for answer in (ConnectionRefusedError("down"), json_response(200, raw=b"<html>captive portal</html>"), json_response(200, ["x"])):
            with self.subTest(answer=repr(answer)[:40]):
                before = len(self.transport.calls)
                self.transport.script = [answer]
                with self.assertRaises(EngineTransient):
                    self.engine().load()
                self.assertEqual(len(self.transport.calls) - before, 1)                              # the health check never retries

    def test_a_failed_load_is_tried_again_on_the_next_call(self):
        engine = self.engine()
        self.transport.script = [ConnectionRefusedError("down")]
        with self.assertRaises(EngineTransient):
            engine.load()
        engine.load()
        self.assertEqual(self.paths(), ["GET /v1/health", "GET /v1/health"])

    def test_the_health_answer_shortens_or_switches_off_never_lengthens(self):
        health = self.server.health
        health["limits"] = dict(health["limits"], max_chunk_samples=300000)
        engine = self.loaded()
        self.assertAlmostEqual(engine_caps(engine).max_chunk_s, 18.75)
        for junk in (496000, 0, -5, "x", None, 1e12, float("nan"), True, 8000, 448001):           # 31 s, nothing, junk, 0.5 s, just over 28 s
            with self.subTest(junk=junk):
                self.server.health = health_document()
                self.server.health["limits"]["max_chunk_samples"] = junk
                self.assertEqual(engine_caps(self.loaded()).max_chunk_s, 28.0)
        self.server.health = health_document()
        self.server.health["limits"]["max_chunk_samples"] = 24000                                        # 1.5 s: usable
        self.assertEqual(engine_caps(self.loaded()).max_chunk_s, 1.5)

    def test_supports_lid_and_confidence_come_from_the_server(self):
        self.server.health = health_document(supports_lid=False, confidence="opaque")
        engine = self.loaded()
        caps = engine_caps(engine)
        self.assertEqual((caps.supports_lid, caps.confidence, caps.kind, caps.uses_prompt), (False, "opaque", "server", False))
        self.assertIsNone(engine.detect_languages([audio(2.0)]))
        self.assertEqual(self.transport.requests("/v1/lid"), [])
        self.server.health = health_document(supports_lid="yes", confidence="strange")                  # junk keeps the declared defaults
        caps = engine_caps(self.loaded())
        self.assertEqual((caps.supports_lid, caps.confidence), (True, "logprob"))

    def test_the_model_label_is_the_server_model_only_when_it_looks_like_a_model_id(self):
        engine = self.loaded()
        self.assertEqual(engine.model, "mlx-community/whisper-large-v3-mlx@49e6aa28")
        self.assertEqual(engine.provenance()["model"], "mlx-community/whisper-large-v3-mlx@49e6aa28")
        for model in ("x\nPrivacy: local-only (note, calendar, Drive skipped)", "has space", "", None, CANARY_TEXT, "a" * 200, "../etc"):
            with self.subTest(model=repr(model)[:30]):
                self.server.health = health_document(model=model, revision="zzzz")
                self.assertEqual(self.loaded().model, "")                                                       # nothing of it reaches the transcript header
        self.server.health = health_document(model="vendor/m-1.5", revision="nothex!")
        self.assertEqual(self.loaded().model, "vendor/m-1.5")                                            # a bad revision is left off

    def test_the_credential_is_read_after_the_lane_gate_and_never_when_it_is_closed(self):
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            self.engine().load()
        self.assertEqual((self.security.reads(), self.transport.calls), (0, []))

    def test_without_a_stored_token_the_run_is_an_auth_failure_before_any_request(self):
        self.security.remove()
        with self.assertRaises(EngineAuthError):
            self.engine().load()
        self.assertEqual(self.transport.calls, [])


class AttestTests(RemoteCase):
    def test_the_organisation_allow_list_decides_which_build_is_accepted(self):
        org = org_policy(builds=(BUILD_SHA, "d" * 64))
        decision = make_decision(self.cfg, "remote", consents=(), org=org)
        self.assertTrue(decision.consent_ids["remote"].startswith("org:"))
        self.engine(decision=decision, org=org).load()                                                    # listed
        self.server.health["attest"]["build_sha256"] = "e" * 64
        for allow in ((BUILD_SHA,), (), ("D" * 64,)):
            with self.subTest(allow=allow):
                org = org_policy(builds=allow)
                decision = make_decision(self.cfg, "remote", consents=(), org=org)
                with self.assertRaises(EnginePolicyDenied) as cm:
                    self.engine(decision=decision, org=org).load()
                self.assertEqual(cm.exception.code, "attest")
                self.assertIn("attest", str(cm.exception))
        self.server.health["attest"]["build_sha256"] = "d" * 64                                           # a list is compared in lower case
        org = org_policy(builds=("D" * 64,))
        self.engine(decision=make_decision(self.cfg, "remote", consents=(), org=org), org=org).load()

    def test_a_server_that_reports_no_build_is_not_on_an_allow_list(self):
        self.server.health["attest"]["build_sha256"] = None
        org = org_policy()
        with self.assertRaises(EnginePolicyDenied):
            self.engine(decision=make_decision(self.cfg, "remote", consents=(), org=org), org=org).load()

    def test_a_user_consent_without_any_organisation_list_accepts_any_build(self):
        self.server.health["attest"]["build_sha256"] = "9" * 64
        self.engine().load()                                                                              # the TTY consent has no allow list

    def test_a_run_that_rests_on_an_organisation_consent_that_vanished_is_refused(self):
        org = org_policy()
        decision = make_decision(self.cfg, "remote", consents=(), org=org)
        for gone in (policy.absent_policy(), org_policy(valid=False), dataclasses.replace(org, org_consents=())):
            with self.subTest(valid=gone.valid, consents=len(gone.org_consents)):
                with self.assertRaises(EnginePolicyDenied) as cm:
                    self.engine(decision=decision, org=gone).load()
                self.assertEqual(cm.exception.code, "org_consent_missing")
        self.assertEqual(self.transport.calls, [])

    def test_the_list_of_any_organisation_consent_for_this_host_binds_a_user_consent_too(self):
        org = org_policy(builds=("d" * 64,))
        user_decision = make_decision(self.cfg, "remote", consents=("remote",))                           # decided without the org consent
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.engine(decision=user_decision, org=org).load()
        self.assertEqual(cm.exception.code, "attest")

    def attest_engine(self, org, *, primary="remote", fallback="none", user_consent=False):
        """An engine whose run was decided with the organisation policy ``org`` (an ``org:`` consent), or, with ``user_consent``, with the
        user's own consent and without the policy (the engine is still handed ``org`` when it asks for the organisation's list)."""
        decision = make_decision(self.cfg, primary, fallback, consents=("remote",) if user_consent else (), org=None if user_consent else org)
        return self.engine(decision=decision, org=org)

    def test_an_expired_duplicate_of_the_consent_does_not_widen_the_allow_list(self):
        """A build is retired by letting its entry expire: the retired build must not be accepted under the entry that is in force. The policy
        parser accepts duplicates of one binding and a date in the past, and every one of them has the same id."""
        retired, current = org_consent("d" * 64, expires="2020-01-01"), org_consent(BUILD_SHA)
        self.assertEqual(retired.id, current.id)
        for order in ((retired, current), (current, retired)):
            org = org_policy(consents=order)
            self.server.health["attest"]["build_sha256"] = "d" * 64
            with self.assertRaises(EnginePolicyDenied) as cm:
                self.attest_engine(org).load()
            self.assertEqual(cm.exception.code, "attest")
            self.server.health["attest"]["build_sha256"] = BUILD_SHA
            self.attest_engine(org).load()                                                              # the entry in force still works

    def test_a_duplicate_meant_for_the_other_role_does_not_widen_the_allow_list(self):
        fallback_only = org_consent("d" * 64, use="fallback")
        primary_only = org_consent(BUILD_SHA, use="primary")
        org = org_policy(consents=(fallback_only, primary_only))
        self.server.health["attest"]["build_sha256"] = "d" * 64
        with self.assertRaises(EnginePolicyDenied) as cm:                                               # a primary run: the fallback list is not its list
            self.attest_engine(org).load()
        self.assertEqual(cm.exception.code, "attest")
        self.server.health["attest"]["build_sha256"] = BUILD_SHA
        self.attest_engine(org).load()
        # the same two entries for a run that uses the server as the FALLBACK: now the other list is the one that counts
        org = org_policy(consents=(primary_only, fallback_only))
        self.server.health["attest"]["build_sha256"] = BUILD_SHA
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.attest_engine(org, primary="whisper", fallback="remote").load()
        self.assertEqual(cm.exception.code, "attest")
        self.server.health["attest"]["build_sha256"] = "d" * 64
        self.attest_engine(org, primary="whisper", fallback="remote").load()

    def test_a_run_whose_only_entry_has_expired_since_it_started_is_refused(self):
        org = org_policy(builds=(BUILD_SHA,))
        decision = make_decision(self.cfg, "remote", consents=(), org=org)
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.engine(decision=decision, org=org, now_fn=lambda: NOW + timedelta(days=400)).load()    # 2027-10-14 has gone by
        self.assertEqual(cm.exception.code, "org_consent_missing")
        self.assertEqual(self.transport.calls, [])

    def test_the_list_of_a_user_consent_run_is_the_union_of_the_entries_in_force_only(self):
        org = org_policy(consents=(org_consent("d" * 64, expires="2020-01-01"), org_consent(BUILD_SHA), org_consent("e" * 64, use="fallback")))
        for build, accepted in ((BUILD_SHA, True), ("e" * 64, True), ("d" * 64, False)):
            with self.subTest(build=build[:4]):
                self.server.health["attest"]["build_sha256"] = build
                engine = self.attest_engine(org, user_consent=True)                                     # decided with the user's consent: not an org: id
                self.assertFalse(engine.consent_id.startswith("org:"))
                if accepted:
                    engine.load()
                else:
                    with self.assertRaises(EnginePolicyDenied) as cm:
                        engine.load()
                    self.assertEqual(cm.exception.code, "attest")

    def test_an_expired_entry_has_no_force_even_for_a_user_consent_run(self):
        org = org_policy(consents=(org_consent("d" * 64, expires="2020-01-01"),))
        self.server.health["attest"]["build_sha256"] = "9" * 64
        self.attest_engine(org, user_consent=True).load()                                               # nothing in force: no list, as without a policy

    def test_a_changed_build_is_a_warning_and_a_counter_not_a_refusal(self):
        first = self.loaded()
        self.assertFalse(first.attest_changed)
        self.assertEqual(attest_status(self.cfg), {"host": HOST, "port": 443, "build_sha256_8": BUILD_SHA[:8], "changes": 0, "changed_at": None})
        self.loaded()                                                                                      # same hashes: nothing changes
        self.assertEqual(attest_status(self.cfg)["changes"], 0)
        self.assertFalse([l for l in self.records.lines if "attestation" in l])
        self.server.health["attest"]["build_sha256"] = "f" * 64
        second = self.loaded()                                                                             # accepted
        self.assertTrue(second.attest_changed)
        status = attest_status(self.cfg)
        self.assertEqual((status["changes"], status["build_sha256_8"]), (1, "f" * 8))
        self.assertIsNotNone(status["changed_at"])
        self.assertEqual(len([l for l in self.records.lines if "attestation" in l]), 1)
        self.server.health["attest"]["config_sha256"] = "1" * 64
        self.loaded()
        self.assertEqual(attest_status(self.cfg)["changes"], 2)
        path = Path(self.cfg.support_dir) / ATTEST_FILE
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(set(json.loads(path.read_text())), {"schema", "host", "port", "build_sha256", "config_sha256", "changes", "changed_at"})

    def test_a_different_server_starts_a_new_record(self):
        self.loaded()
        path = Path(self.cfg.support_dir) / ATTEST_FILE
        doc = json.loads(path.read_text())
        doc.update(host="other.example.internal", changes=5)
        path.write_text(json.dumps(doc))
        self.loaded()
        self.assertEqual(attest_status(self.cfg)["changes"], 0)
        self.assertEqual(attest_status(self.cfg)["host"], HOST)

    def test_a_damaged_record_is_replaced_and_status_never_raises(self):
        path = Path(self.cfg.support_dir) / ATTEST_FILE
        for junk in ("{not json", "[1]", "null", '{"changes": "many", "host": 5, "port": "x", "build_sha256": 3}'):
            with self.subTest(junk=junk):
                path.write_text(junk)
                status = attest_status(self.cfg)
                self.assertEqual(set(status), {"host", "port", "build_sha256_8", "changes", "changed_at"} if status else set())
                self.loaded()
                self.assertEqual(attest_status(self.cfg)["changes"], 0)
        self.assertEqual(attest_status(SimpleNamespace(support_dir=self.root / "nowhere")), {})

    def test_the_record_holds_nothing_but_hashes(self):
        self.server.health["attest"]["build_sha256"] = CANARY_TEXT
        self.loaded()
        self.assertNothingLeaked()


# ======================================================================================================================
class VocabularyTests(RemoteCase):
    def test_the_vocabulary_is_put_once_before_the_first_chunk(self):
        engine = self.loaded(VOCAB)
        body, digest = canonical_vocab(["Acme", "AcmeScan-CXR"])
        engine.transcribe_chunk(audio(), "en", None)
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(self.paths("/v1/vocab", "/v1/chunk"), [f"PUT /v1/vocab/{digest}", "POST /v1/chunk", "POST /v1/chunk"])
        put = self.transport.requests("/v1/vocab")[0]
        self.assertEqual((put.body, put.header("Content-Type"), put.header("Authorization")), (body, "application/json", f"Bearer {TOKEN}"))
        self.assertEqual(self.server.vocabs, {digest: ["Acme", "AcmeScan-CXR"]})
        self.assertTrue(all(c.header("X-MCAP-Vocab") == digest for c in self.chunks()))
        self.assertEqual([l["op"] for l in usage_lines(self.cfg)], ["health", "vocab", "chunk", "chunk"])

    def test_a_korean_vocabulary_is_sent_as_utf8_with_the_digest_of_those_bytes(self):
        engine = self.loaded(Vocab(terms=KO_TERMS))
        engine.transcribe_chunk(audio(), "ko", None)
        put = self.transport.requests("/v1/vocab")[0]
        self.assertEqual(put.target, "/v1/vocab/5be960d3f9c4edcc23a746cdae69aad23fec5bd27566ea6635b52606bd95d012")
        self.assertEqual(put.body.decode("utf-8"), '{"terms":["액미","PACS"]}')

    def test_a_server_that_lost_the_vocabulary_gets_it_again_and_the_same_request_is_repeated(self):
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        self.server.forget_vocabularies()                                                              # a restart, the LRU of 16
        before = len(self.transport.calls)
        result = engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(result["text"], "chunk 32000 samples")
        later = self.transport.calls[before:]
        self.assertEqual([f"{c.method} {c.path.split('/v1/')[1].split('/')[0]}" for c in later], ["POST chunk", "PUT vocab", "POST chunk"])
        first, _, again = later
        self.assertEqual((first.header("X-MCAP-Idem"), first.body, first.headers), (again.header("X-MCAP-Idem"), again.body, again.headers))
        self.assertEqual(len(self.server.vocabs), 1)
        self.assertEqual(self.server.computed, 2)

    def test_the_404_retry_happens_once_and_a_server_that_keeps_saying_404_fails_the_chunk(self):
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        self.server.fail("/v1/chunk", error_answer(404, "vocab_unknown"), error_answer(404, "vocab_unknown"))
        before = len(self.transport.calls)
        with self.assertRaises(EngineHttpError) as cm:
            engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((cm.exception.status, cm.exception.code), (404, "vocab_unknown"))
        self.assertEqual([c.method for c in self.transport.calls[before:]], ["POST", "PUT", "POST"])

    def test_a_put_that_is_itself_answered_vocab_unknown_does_not_loop(self):
        self.server.fail("/v1/vocab", *[error_answer(404, "vocab_unknown")] * 5)
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(self.paths("/v1/vocab"), ["PUT /v1/vocab/" + canonical_vocab(["Acme", "AcmeScan-CXR"])[1]])
        self.assertIsNone(self.chunks()[0].header("X-MCAP-Vocab"))
        self.assertEqual(self.chunks()[0].header("X-MCAP-Prompt"), "none")

    def test_a_refused_vocabulary_costs_the_vocabulary_not_the_transcript(self):
        self.server.fail("/v1/vocab", error_answer(400, "bad_request"))
        engine = self.loaded(VOCAB)
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "chunk 32000 samples")
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(len(self.transport.requests("/v1/vocab")), 1)                                  # not asked again
        for call in self.chunks():
            self.assertEqual((call.header("X-MCAP-Vocab"), call.header("X-MCAP-Prompt")), (None, "none"))
        self.assertTrue([l for l in self.records.lines if "refused the vocabulary" in l])

    def test_a_vocabulary_the_server_refuses_when_it_is_sent_again_costs_the_vocabulary_for_the_rest_of_the_run(self):
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        self.server.forget_vocabularies()
        self.server.fail("/v1/vocab", error_answer(400, "bad_request"))
        with self.assertRaises(EngineHttpError) as cm:                                                     # this chunk: 404, the PUT is refused
            engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((cm.exception.status, cm.exception.code), (404, "vocab_unknown"))
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "chunk 32000 samples")     # the next ones go without it
        self.assertEqual((self.chunks()[-1].header("X-MCAP-Vocab"), self.chunks()[-1].header("X-MCAP-Prompt")), (None, "none"))

    def test_other_failures_of_the_put_are_the_chunks_failure(self):
        for answer, cls in ((error_answer(401, "unauthorized"), EngineAuthError), (error_answer(503, "busy", retry_after=1), EngineTransient)):
            with self.subTest(status=answer.status):
                self.server.queued.clear()
                self.server.fail("/v1/vocab", *[answer] * 4)
                engine = self.loaded(VOCAB)
                with self.assertRaises(cls):
                    engine.transcribe_chunk(audio(), "en", None)
                self.assertEqual(self.chunks(), [])                                                       # no audio left before the vocabulary was in

    def test_send_vocab_off_sends_no_term_and_no_vocabulary_header(self):
        for label, decision in (("config", make_decision(dataclasses.replace(self.cfg, asr_send_vocab=False), "remote")),
                                ("policy", make_decision(self.cfg, "remote", consents=(), org=org_policy(send_vocab=False)))):
            with self.subTest(via=label):
                self.assertFalse(decision.send_vocab)
                self.transport.calls.clear()
                engine = self.engine(VOCAB, decision=decision, org=org_policy())
                engine.load()
                engine.transcribe_chunk(audio(), "en", None)
                self.assertEqual(self.paths("/v1/vocab"), [])
                call = self.chunks()[0]
                self.assertEqual((call.header("X-MCAP-Vocab"), call.header("X-MCAP-Prompt")), (None, "none"))
                everything = b"".join(c.body + repr(c.headers).encode() for c in self.transport.calls)
                self.assertNotIn(b"Acme", everything)
                self.assertNotIn(b"AcmeScan", everything)
        self.cfg.asr_send_vocab = False                                                                    # the decision allows it, the config does not
        engine = self.engine(VOCAB, decision=self.decision(cfg=dataclasses.replace(self.cfg, asr_send_vocab=True)))
        self.assertIsNone(engine._vocab_sha)

    def test_no_vocabulary_no_terms_no_header(self):
        for vocab in (None, Vocab(), Vocab(terms=["", "  "])):
            with self.subTest(vocab=vocab):
                self.transport.calls.clear()
                engine = self.loaded(vocab)
                engine.transcribe_chunk(audio(), "en", None)
                self.assertEqual(self.paths("/v1/vocab"), [])
                self.assertEqual((self.chunks()[0].header("X-MCAP-Vocab"), self.chunks()[0].header("X-MCAP-Prompt")), (None, "none"))

    def test_purge_makes_the_next_chunk_send_the_vocabulary_again(self):
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(engine.purge(), 2)                                                               # one vocabulary, one cached answer
        self.assertEqual(self.server.vocabs, {})
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(len(self.transport.requests("/v1/vocab")), 2)
        self.assertEqual(self.transport.requests("/v1/purge")[0].method, "POST")

    def test_purge_answers_are_validated(self):
        engine = self.loaded()
        for answer, count in ((json_response(200, {"purged": 3}), 3), (json_response(200, {"purged": -1}), 0), (json_response(200, {"purged": "x"}), 0),
                              (json_response(200, {"purged": True}), 0), (json_response(200, {}), 0)):
            self.transport.script = [answer]
            self.assertEqual(engine.purge(), count)
        self.transport.script = [json_response(200, raw=b"zzz")]
        with self.assertRaises(EngineTransient):
            engine.purge()


# ======================================================================================================================
class LanguageIdTests(RemoteCase):
    def test_a_batch_is_one_request_with_the_clip_lengths_and_the_languages(self):
        engine = self.loaded()
        clips = [audio(2.0, 0.5), audio(3.0, 0.05), audio(1.5, 0.5)]
        out = engine.detect_languages(clips, ("ko", "en"))
        call = self.transport.requests("/v1/lid")[0]
        self.assertEqual((call.method, call.target), ("POST", "/v1/lid"))
        self.assertEqual((call.header("X-MCAP-Clips"), call.header("X-MCAP-Langs"), call.header("Content-Type")), ("32000,48000,24000", "ko,en",
                                                                                                                     "application/octet-stream"))
        self.assertEqual(call.body, b"".join(pcm16(c) for c in clips))
        self.assertEqual([r["top"] for r in out], ["ko", "en", "ko"])
        self.assertAlmostEqual(out[0]["ko"] + out[0]["en"], 1.0)
        self.assertEqual(set(out[0]), {"ko", "en", "top"})

    def test_twelve_clips_are_one_request_thirty_are_three(self):
        engine = self.loaded()
        engine.detect_languages([audio(1.0, 0.5)] * 12)
        self.assertEqual(len(self.transport.requests("/v1/lid")), 1)
        self.transport.calls.clear()
        clips = [audio(1.0 + 0.1 * (i % 5), 0.5 if i % 2 == 0 else 0.05) for i in range(30)]
        out = engine.detect_languages(clips)
        lid = self.transport.requests("/v1/lid")
        self.assertEqual([len(c.header("X-MCAP-Clips").split(",")) for c in lid], [12, 12, 6])
        self.assertEqual([r["top"] for r in out], ["ko" if i % 2 == 0 else "en" for i in range(30)])        # the order of the answer is the order of the clips
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in lid}), 3)

    def test_a_long_clip_is_trimmed_to_its_centre_six_seconds(self):
        engine = self.loaded()
        loud, quiet = np.full(2 * SR, 0.5, np.float32), np.full(6 * SR, 0.05, np.float32)
        clip = np.concatenate([loud, quiet, loud])                                                        # 10 s: the middle 6 s are quiet
        out = engine.detect_languages([clip])
        call = self.transport.requests("/v1/lid")[0]
        self.assertEqual((call.header("X-MCAP-Clips"), len(call.body)), ("96000", 2 * 96000))
        self.assertEqual(call.body, pcm16(quiet))
        self.assertEqual(out[0]["top"], "en")                                                              # the loud edges were not sent
        short = np.full(5 * SR, 0.05, np.float32)
        engine.detect_languages([short])
        self.assertEqual(self.transport.requests("/v1/lid")[-1].header("X-MCAP-Clips"), "80000")          # a shorter clip is untouched

    def test_the_servers_smaller_limits_win_a_larger_one_changes_nothing(self):
        self.server.health["limits"].update(max_lid_clips=5, max_lid_clip_samples=48000)
        engine = self.loaded()
        engine.detect_languages([audio(4.0, 0.5)] * 11)
        lid = self.transport.requests("/v1/lid")
        self.assertEqual([len(c.header("X-MCAP-Clips").split(",")) for c in lid], [5, 5, 1])
        self.assertEqual(lid[0].header("X-MCAP-Clips").split(",")[0], "48000")
        self.transport.calls.clear()
        self.server.health = health_document()
        self.server.health["limits"].update(max_lid_clips=99, max_lid_clip_samples=10 ** 9)
        engine = self.loaded()
        engine.detect_languages([audio(8.0, 0.5)] * 13)
        lid = self.transport.requests("/v1/lid")
        self.assertEqual([len(c.header("X-MCAP-Clips").split(",")) for c in lid], [12, 1])
        self.assertEqual(lid[0].header("X-MCAP-Clips").split(",")[0], "96000")
        for junk in (0, -3, "x", None, 100, float("nan")):
            self.server.health = health_document()
            self.server.health["limits"].update(max_lid_clips=junk)
            self.assertLessEqual(self.loaded()._max_lid_clips, 12)

    def test_an_empty_clip_is_not_sent_and_gets_the_uniform_answer(self):
        engine = self.loaded()
        out = engine.detect_languages([np.zeros(0, np.float32), audio(1.0, 0.5), np.zeros(0, np.float32)], ("ko", "en"))
        self.assertEqual([r["top"] for r in out], ["ko", "ko", "ko"])
        self.assertEqual((out[0]["ko"], out[0]["en"], out[1]["ko"] > 0.9), (0.5, 0.5, True))
        self.assertEqual(self.transport.requests("/v1/lid")[0].header("X-MCAP-Clips"), "16000")
        self.transport.calls.clear()
        self.assertEqual(len(engine.detect_languages([np.zeros(0, np.float32)])), 1)
        self.assertEqual(engine.detect_languages([]), [])
        self.assertEqual(self.transport.requests("/v1/lid"), [])

    def test_the_answer_is_restricted_and_renormalised_whatever_the_server_sends(self):
        self.server.lid_override = lambda counts, langs: [{"ko": 0.2, "en": 0.2, "ja": 0.6, "top": "ja"}, {"ko": 3, "en": 1, "top": "en"},
                                                         {"ko": "x", "en": None}, {"ko": float("nan"), "en": -1}, "junk"][:len(counts)]
        engine = self.loaded()
        out = engine.detect_languages([audio(1.0)] * 5, ("ko", "en"))
        self.assertEqual((out[0]["ko"], out[0]["en"], out[0]["top"]), (0.5, 0.5, "ko"))                    # ja is not asked for
        self.assertEqual((out[1]["ko"], out[1]["en"], out[1]["top"]), (0.5, 0.5, "ko"))                    # probabilities are clamped to [0, 1] first
        for item in out[2:]:
            self.assertEqual((item["ko"], item["en"]), (0.5, 0.5))                                         # nothing usable: uniform, like restrict_lid
        ja = engine.detect_languages([audio(1.0)], ("ko", "en", "ja"))
        self.assertEqual(set(ja[0]), {"ko", "en", "ja", "top"})

    def test_the_answer_must_have_one_entry_per_clip(self):
        engine = self.loaded()
        for results in (lambda c, l: [], lambda c, l: [{"ko": 1, "en": 0}] * (len(c) + 1), lambda c, l: "x", lambda c, l: None):
            self.server.lid_override = results
            with self.assertRaises(EngineTransient) as cm:
                engine.detect_languages([audio(1.0)] * 2)
            self.assertEqual(str(cm.exception), "the language-ID answer could not be used")
        self.server.lid_override = None
        self.transport.script = [json_response(200, {"proto": "mcap-asr/2", "results": [{}]})]
        with self.assertRaises(EngineTransient):
            engine.detect_languages([audio(1.0)])

    def test_a_server_that_has_no_language_id_after_all_switches_it_off_and_answers_uniformly(self):
        self.server.lid_supported = False                                                                  # the health answer said True
        engine = self.loaded()
        with self.assertLogs("mcap.asr", "WARNING") as logs:
            out = engine.detect_languages([audio(1.0), audio(2.0)], ("ko", "en"))                           # docs/ASR_PROTOCOL.md 12.3: not an exception
        self.assertEqual([(r["ko"], r["en"], r["top"]) for r in out], [(0.5, 0.5, "ko")] * 2)
        self.assertEqual(len(self.transport.requests("/v1/lid")), 1)                                       # no retry of a 400
        self.assertFalse(engine_caps(engine).supports_lid)                                                 # asr.py does not ask again (the next track)
        self.assertTrue(any("refused language ID (HTTP 400)" in line for line in logs.output))
        again = engine.detect_languages([audio(1.0)] * 3, ("ko", "en"))                                    # a call that was already on its way: uniform, nothing sent
        self.assertEqual([r["top"] for r in again], ["ko"] * 3)
        self.assertEqual(len(self.transport.requests("/v1/lid")), 1)

    def test_any_refusal_of_a_language_id_batch_degrades_it_does_not_raise(self):
        for status, code in ((400, "bad_request"), (413, "payload_too_large"), (415, "unsupported_media_type"), (422, "unprocessable_audio"),
                             (404, "not_found"), (409, "idem_conflict")):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.server.queued.clear()
                self.server.fail("/v1/lid", error_answer(status, code))
                engine = self.loaded()
                out = engine.detect_languages([audio(1.0, 0.5) for _ in range(30)], ("ko", "en"))             # three batches of 12, 12 and 6
                self.assertEqual(len(out), 30)
                self.assertTrue(all((r["ko"], r["en"]) == (0.5, 0.5) for r in out), status)
                self.assertEqual(len(self.transport.requests("/v1/lid")), 1)                                 # the first refusal ends language ID for the run
                self.assertFalse(engine_caps(engine).supports_lid)

    def test_a_refusal_is_not_what_a_lost_credential_or_a_busy_server_is(self):
        engine = self.loaded()
        self.server.fail("/v1/lid", error_answer(401, "unauthorized"))
        with self.assertRaises(EngineAuthError):
            engine.detect_languages([audio(1.0)])
        self.assertTrue(engine_caps(engine).supports_lid)
        self.server.fail("/v1/lid", *[error_answer(503, "busy", retry_after=1)] * 3)
        with self.assertRaises(EngineTransient):
            engine.detect_languages([audio(1.0)])
        self.assertTrue(engine_caps(engine).supports_lid)                                                  # a server that is not well has not lost the feature
        self.assertEqual(engine.detect_languages([audio(1.0, 0.5)], ("ko", "en"))[0]["ko"], 0.95)         # and it still asks, and gets a real answer

    def test_the_chunks_after_a_refused_language_id_ask_the_server_to_decide(self):
        self.server.lid_supported = False
        engine = self.loaded()
        engine.transcribe_chunk(audio(), "ko", None)                                                       # before: the label is the label
        engine.detect_languages([audio(1.0)], ("ko", "en"))
        for label in ("ko", "en", "", None):
            engine.transcribe_chunk(audio(), label, None)
        self.assertEqual([c.header("X-MCAP-Lang") for c in self.chunks()], ["ko"] + ["auto"] * 4)         # whatever label uniform answers made up
        self.assertEqual({c.header("X-MCAP-Langs") for c in self.chunks()}, {"ko,en"})                     # the choice stays restricted to the asked languages

    def test_language_id_is_a_request_to_the_server_like_any_other(self):
        engine = self.loaded()
        self.server.fail("/v1/lid", error_answer(503, "busy", retry_after=2), error_answer(503, "busy", retry_after=2))
        engine.detect_languages([audio(2.0, 0.5)])
        lid = self.transport.requests("/v1/lid")
        self.assertEqual(len(lid), 3)
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in lid}), 1)                                   # the retries share the key
        self.assertEqual(self.sleep.waits, [2.0, 2.0])
        self.assertEqual(engine.usage()["lid_requests"], 3)
        self.assertTrue(engine.sent_anything())

    def test_a_closed_lane_sends_no_clip(self):
        engine = self.loaded()
        self.gate.close("local_only")
        with self.assertRaises(EnginePolicyDenied):
            engine.detect_languages([audio(1.0)])
        self.assertEqual(self.transport.requests("/v1/lid"), [])


# ======================================================================================================================
class TokenRenewalTests(RemoteCase):
    def with_days(self, days):
        self.server.tokens[TOKEN] = days

    def test_a_token_with_14_days_or_fewer_is_renewed_at_the_start_of_the_run(self):
        for days in (14, 13, 1, 0):
            with self.subTest(days=days):
                self.store_token()
                self.server.tokens[TOKEN] = days
                self.transport.calls.clear()
                self.keychain.calls.clear()
                engine = self.loaded()
                self.assertEqual(self.paths("/v1/health", "/v1/token"), ["GET /v1/health", "POST /v1/token/renew"])
                new = self.server.minted[-1]
                self.assertEqual(self.keychain_token(), new)                                                 # the Keychain item was overwritten
                self.assertEqual(engine.secret(), new)

    def test_a_token_with_more_days_left_is_not_renewed(self):
        for days in (15, 71, 90, None):
            with self.subTest(days=days):
                self.server.tokens[TOKEN] = days
                self.server.health["token"] = {"expires_in_days": days}
                self.transport.calls.clear()
                self.loaded()
                self.assertEqual(self.paths("/v1/token"), [])
                self.assertEqual(self.keychain.writes(), [])

    def test_the_renewal_request_and_the_keychain_write_never_show_the_token(self):
        self.with_days(10)
        self.loaded()
        call = self.transport.requests("/v1/token/renew")[0]
        self.assertEqual((call.method, call.body, call.header("Authorization")), ("POST", b"", f"Bearer {TOKEN}"))     # the OLD token asks for the new one
        write = self.keychain.writes()[0]
        new = self.server.minted[-1]
        self.assertEqual(write["argv"], [apikey.security_bin(), "-i"])                                           # argv: the tool and -i, nothing else
        self.assertNotIn(new, " ".join(write["argv"]) + repr(write["env"]))
        words = shlex.split(write["input"].decode("utf-8"))
        self.assertEqual(words[0], "add-generic-password")
        self.assertEqual((words[words.index("-s") + 1], words[words.index("-a") + 1], words[words.index("-w") + 1]),
                         ("MeetingCapture ASR remote", asr_creds.account_name(HOST, 443), new))                 # the host-bound account
        self.assertIn("-U", words)

    def test_the_new_token_is_used_for_the_rest_of_the_run_and_the_old_one_is_not_read_again(self):
        self.with_days(10)
        engine = self.loaded()
        engine.transcribe_chunk(audio(), "en", None)
        new = self.server.minted[-1]
        self.assertEqual(self.chunks()[0].header("Authorization"), f"Bearer {new}")
        self.assertEqual(self.security.reads(), 2)                                                           # the old token once, the read-back once

    def test_a_renewal_that_fails_never_fails_the_run(self):
        for answer in (error_answer(429, "quota_exceeded", retry_after=1), error_answer(500, "engine_error"), error_answer(401, "unauthorized"),
                       error_answer(403, "forbidden"), ConnectionRefusedError("down"), json_response(200, raw=b"zzz"),
                       json_response(200, {"token": "not-a-token", "expires": "x"}), json_response(200, {"expires": "2027-01-01T00:00:00+09:00"})):
            with self.subTest(answer=repr(answer)[:50]):
                self.with_days(5)
                self.records.lines.clear()
                self.server.queued.clear()
                self.server.fail("/v1/token", *[answer] * 4)
                engine = self.loaded()
                self.assertEqual(self.keychain.writes(), [])
                self.assertEqual(engine.secret(), TOKEN)                                                      # the old token goes on
                self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "chunk 32000 samples")
                self.assertEqual(self.chunks()[-1].header("Authorization"), f"Bearer {TOKEN}")
                self.assertTrue([l for l in self.records.lines if "could not be renewed" in l])
                self.assertEqual(self.keychain_token(), TOKEN)

    def test_a_closed_gate_during_the_renewal_is_not_swallowed(self):
        self.with_days(3)
        self.transport.on_send = lambda call: self.gate.close("local_only") if call.path == "/v1/health" else None     # closed right after the health answer
        engine = self.engine()
        with self.assertRaises(EnginePolicyDenied):
            engine.load()
        self.assertEqual(self.paths("/v1/token"), [])
        with self.assertRaises(EnginePolicyDenied):                                                           # a load that raised did not load: asked again, still closed
            engine.load()

    def test_a_keychain_that_refuses_the_write_keeps_the_token_in_memory_and_says_so(self):
        for run in (KeychainRun(self, rc=1), KeychainRun(self, stored=False)):
            with self.subTest(rc=run.rc, stored=run.stored):
                self.with_days(2)
                self.keychain = run
                self.records.lines.clear()
                engine = self.loaded()
                new = self.server.minted[-1]
                self.assertEqual(self.keychain_token(), TOKEN)                                                # the Keychain item was not changed
                self.assertEqual(engine.secret(), new)                                                        # this run uses the new token
                self.assertTrue([l for l in self.records.lines if "could not be stored in the Keychain" in l])
                self.assertNothingLeaked(new)

    def test_renew_returns_a_content_free_summary(self):
        engine = self.loaded()
        self.with_days(1)
        summary = engine.renew()
        self.assertEqual(summary, {"renewed": True, "stored": True, "expires": EXPIRES})
        self.assertNotIn(self.server.minted[-1], repr(summary))

    def test_a_refusal_of_the_health_check_comes_before_any_renewal(self):
        self.with_days(1)
        self.server.health["retention"]["mode"] = "disk"
        with self.assertRaises(EnginePolicyDenied):
            self.engine().load()
        self.assertEqual(self.paths("/v1/token"), [])


# ======================================================================================================================
class EnrollTests(RemoteCase):
    def setUp(self):
        super().setUp()
        self.security.remove()                                                                                # nothing is enrolled yet
        policy.write_consent(self.cfg.consent_path, consent_entry("remote"), machine_id=MACHINE)
        patcher = mock.patch.object(policy, "machine_id", return_value=MACHINE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def enroll(self, code=CODE, **kw):
        kw.setdefault("transport", self.transport)
        kw.setdefault("run", self.keychain)
        kw.setdefault("machine", MACHINE)
        kw.setdefault("now", NOW)
        return enroll(self.cfg, code, **kw)

    def test_the_code_becomes_a_token_in_the_host_bound_keychain_item(self):
        summary = self.enroll()
        token = self.server.minted[0]
        self.assertTrue(TOKEN_SHAPE.fullmatch(token))
        self.assertEqual(self.keychain_token(), token)
        write = self.keychain.writes()[0]
        words = shlex.split(write["input"].decode("utf-8"))
        self.assertEqual((words[words.index("-s") + 1], words[words.index("-a") + 1]), ("MeetingCapture ASR remote", asr_creds.account_name(HOST, 443)))
        self.assertEqual(write["argv"], [apikey.security_bin(), "-i"])
        everywhere = " ".join(write["argv"]) + repr(write["env"])
        self.assertNotIn(token, everywhere)
        self.assertNotIn("ABCD", everywhere)
        self.assertEqual(summary, {"engine": "remote", "host": HOST, "port": 443, "stored": True, "expires": EXPIRES,
                                   "expires_in_days": 90})

    def test_the_summary_has_neither_the_token_nor_the_code_nor_the_users_label(self):
        text = json.dumps(self.enroll())
        for needle in (self.server.minted[0], "ABCD", "EFGH", "mic", "Bearer"):
            self.assertNotIn(needle, text)

    def test_the_enrollment_request_is_the_one_of_the_protocol(self):
        self.enroll(code="  abcd-efgh-jklm \n")
        calls = self.transport.calls
        self.assertEqual([(c.method, c.target) for c in calls], [("POST", "/v1/enroll")])
        call = calls[0]
        self.assertEqual(call.json(), {"code": "abcd-efgh-jklm", "machine": hashlib.sha256(MACHINE.encode()).hexdigest()[:16]})
        self.assertEqual((call.header("Content-Type"), call.header("X-MCAP-Proto"), call.header("Authorization")), ("application/json", "mcap-asr/1", None))
        self.assertEqual(self.security.reads(), 1)                                                            # no token to send: the only read is the read-back after the write
        self.assertEqual([l["op"] for l in usage_lines(self.cfg)], ["enroll"])

    def test_the_new_token_works_for_a_run_and_a_second_use_of_the_code_does_not(self):
        self.enroll()
        engine = self.loaded(VOCAB)
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "chunk 32000 samples")
        self.assertEqual(self.chunks()[0].header("Authorization"), f"Bearer {self.server.minted[0]}")
        with self.assertRaises(EngineAuthError):
            self.enroll()

    def test_a_refused_code_is_an_auth_error_with_a_fixed_sentence_and_nothing_is_stored(self):
        for code in ("WRONG-CODE-0000", CODE.lower().replace("a", "z")):
            with self.subTest(code=code):
                with self.assertRaises(EngineAuthError) as cm:
                    self.enroll(code)
                text = str(cm.exception)
                self.assertTrue(text.startswith("the enrollment code was refused"), text)
                self.assertEqual((cm.exception.status, cm.exception.code), (401, "enroll_invalid"))
                for fragment in CANARY_FRAGMENTS + (code,):
                    self.assertNotIn(fragment, text)                                                          # the server's message (a canary) is not copied
        self.assertEqual(self.keychain.writes(), [])
        self.assertEqual(len(self.transport.calls), 2)                                                        # one attempt each
        self.assertNothingLeaked("WRONG-CODE-0000")

    def test_a_throttled_server_is_transient_with_one_attempt_and_no_sleep(self):
        self.server.enroll_throttled = True
        with self.assertRaises(EngineTransient) as cm:
            self.enroll()
        self.assertEqual((cm.exception.status, cm.exception.code), (429, "enroll_throttled"))
        self.assertIn("too many enrollment attempts", str(cm.exception))
        self.assertEqual((len(self.transport.calls), self.sleep.waits), (1, []))
        self.assertEqual(self.server.codes, {"ABCDEFGHJKLM": "mic"})                                          # the throttle did not eat the code

    def test_an_unreachable_server_is_transient_and_the_code_is_tried_once(self):
        for answer in (ConnectionRefusedError("down"), error_answer(500, "engine_error"), error_answer(503, "busy", retry_after=1)):
            with self.subTest(answer=repr(answer)[:30]):
                self.transport.calls.clear()
                self.transport.script = [answer, answer]
                with self.assertRaises(EngineTransient) as cm:
                    self.enroll()
                self.assertEqual(len(self.transport.calls), 1)
                self.assertIn("could not be reached for enrollment", str(cm.exception))
        self.assertEqual(self.keychain.writes(), [])

    def test_an_answer_without_a_usable_token_stores_nothing(self):
        for doc in ({}, {"token": 5}, {"token": "mcap1_zz"}, {"token": TOKEN + "x"}, {"token": "mcap1_0a1b2c3d_" + "A" * 31}, [1]):
            with self.subTest(doc=doc):
                self.transport.script = [json_response(200, doc)]
                with self.assertRaises(EngineTransient) as cm:
                    self.enroll()
                self.assertTrue(str(cm.exception).startswith("the enrollment answer could not be used") or "could not be read" in str(cm.exception))
        self.transport.script = [json_response(200, raw=b"not json")]
        with self.assertRaises(EngineTransient):
            self.enroll()
        self.assertEqual(self.keychain.writes(), [])

    def test_a_failing_keychain_is_an_auth_error_that_names_no_secret(self):
        for run in (KeychainRun(self, rc=1), KeychainRun(self, stored=False)):
            with self.subTest(rc=run.rc, stored=run.stored):
                self.server.codes["ABCDEFGHJKLM"] = "mic"
                with self.assertRaises(EngineAuthError) as cm:
                    self.enroll(run=run)
                self.assertEqual(cm.exception.code, "store_failed")
                self.assertNotIn(self.server.minted[-1], str(cm.exception))
        self.assertNothingLeaked(self.server.minted[-1], self.server.minted[0])

    def test_a_tool_that_exits_zero_but_keeps_nothing_does_not_leave_a_stale_token_looking_enrolled(self):
        self.store_token("mcap1_99999999_" + "S" * 32)                                                        # an old token of an earlier enrollment
        with self.assertRaises(EngineAuthError):
            self.enroll(run=KeychainRun(self, stored=False))
        self.assertEqual(self.keychain_token(), "mcap1_99999999_" + "S" * 32)

    def test_a_missing_tool_or_a_timeout_is_a_store_failure_too(self):
        for exc in (FileNotFoundError("no security"), subprocess.TimeoutExpired("security", 10)):
            def run(argv, **kw):
                raise exc
            with self.subTest(exc=type(exc).__name__):
                self.server.codes["ABCDEFGHJKLM"] = "mic"
                with self.assertRaises(EngineAuthError) as cm:
                    self.enroll(run=run)
                self.assertEqual(cm.exception.code, "store_failed")

    def test_nothing_is_sent_where_a_run_would_not_be_allowed_to_send(self):
        cases = {
            "no consent": dict(prepare=lambda: self.cfg.consent_path.unlink(), reason="no-consent"),
            "not configured": dict(prepare=lambda: setattr(self.cfg, "asr_remote_url", ""), reason="not-configured"),
            "an IP literal": dict(prepare=lambda: setattr(self.cfg, "asr_remote_url", "https://10.0.0.5"), reason="bad-host"),
            "plain http": dict(prepare=lambda: setattr(self.cfg, "asr_remote_url", f"http://{HOST}"), reason="bad-host"),
            "another host than the consent": dict(prepare=lambda: setattr(self.cfg, "asr_remote_url", "https://evil.example.test"),
                                                  reason="consent-mismatch"),
            "another port than the consent": dict(prepare=lambda: setattr(self.cfg, "asr_remote_url", f"https://{HOST}:8443"),
                                                  reason="consent-mismatch"),
        }
        for label, case in cases.items():
            with self.subTest(case=label):
                policy.write_consent(self.cfg.consent_path, consent_entry("remote"), machine_id=MACHINE)
                self.cfg.asr_remote_url = f"https://{HOST}"
                case["prepare"]()
                with self.assertRaises(EnginePolicyDenied) as cm:
                    self.enroll()
                self.assertIn(f"({case['reason']})", str(cm.exception))
                self.assertEqual((self.transport.calls, self.keychain.calls), ([], []))

    def test_the_organisation_policy_applies_to_enrollment_too(self):
        cases = {"locked": (org_policy(valid=False), "policy-locked"), "lane denied": (org_policy(lanes={"asr_remote": "deny"}), "policy-lane"),
                 "host not listed": (org_policy(hosts=("other.example.internal",)), "policy-host"),
                 "engine not listed": (org_policy(engines=("whisper",)), "policy-engine")}
        self.cfg.consent_path.unlink()
        for label, (org, reason) in cases.items():
            with self.subTest(case=label), mock.patch.object(policy, "load_org_policy", return_value=org):
                with self.assertRaises(EnginePolicyDenied) as cm:
                    self.enroll()
                self.assertIn(f"({reason})", str(cm.exception))
        self.assertEqual(self.transport.calls, [])
        with mock.patch.object(policy, "load_org_policy", return_value=org_policy()):                         # an organisation consent needs no user consent
            summary = self.enroll()
        self.assertEqual(summary["host"], HOST)
        self.assertEqual(self.transport.calls[0].method, "POST")

    def test_an_unbound_private_ca_stops_the_enrollment_before_any_request(self):
        decision = self.decision()
        rule = dataclasses.replace(decision.hosts[HOST], ca_file=None)
        unbound = dataclasses.replace(decision, hosts={HOST: rule})
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.enroll(decision=unbound)
        self.assertEqual(cm.exception.code, "ca_unbound")
        self.assertEqual(self.transport.calls, [])

    def test_a_zero_daily_cap_does_not_stop_an_enrollment(self):
        self.cfg.asr_cloud_daily_minutes = 0                                                                  # no external AUDIO; enrollment sends none
        self.assertEqual(self.enroll()["stored"], True)

    def test_an_unreadable_machine_id_only_leaves_the_soft_binding_out(self):
        with mock.patch.object(policy, "machine_id", side_effect=OSError("no ioreg")):
            self.enroll(decision=self.decision(), machine=None)
        self.assertEqual(self.transport.calls[0].json(), {"code": CODE})
        self.assertIsNone(self.transport.calls[0].header("X-MCAP-Machine"))

    def test_a_malformed_code_never_leaves_the_machine(self):
        for code in ("", "   ", None, 5, "x" * 65, "ab\ncd", "tab\tcode", "\x00", "ünï-code"):
            with self.subTest(code=repr(code)[:20]):
                with self.assertRaises(ValueError) as cm:
                    self.enroll(code)
                self.assertNotIn("code", str(cm.exception).replace("the enrollment code is empty or malformed", ""))
        self.assertEqual(self.transport.calls, [])

    def test_the_code_is_masked_in_everything_that_redacts(self):
        self.addCleanup(apikey._known.clear)
        self.enroll()
        self.assertEqual(apikey.redact(f"the code {CODE} was used"), "the code sk-ant-*** was used")
        self.assertEqual(apikey.redact(f"token {self.server.minted[0]}"), "token sk-ant-***")
        self.assertNothingLeaked(CODE, self.server.minted[0])

    def test_enrollment_leaves_no_engine_state_behind(self):
        engine_secret_reads = self.security.reads()
        self.enroll()
        self.assertEqual(self.security.reads() - engine_secret_reads, 1)                                      # only the read-back after the write
        self.assertEqual(attest_status(self.cfg), {})                                                         # no health check, no attestation record

    def test_the_real_tool_receives_the_token_on_stdin_and_not_in_argv(self):
        """store_token with a REAL child process (a shim for `security -i`): what the operating system shows of the call has no token."""
        shim_dir = self.root / "sec-i"
        shim_dir.mkdir()
        script = shim_dir / "fake_sec.py"
        script.write_text('''import json, os, shlex, sys
here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]
data = sys.stdin.read() if argv[:1] == ["-i"] else ""
with open(os.path.join(here, "log.jsonl"), "a") as fh:
    fh.write(json.dumps({"argv": argv, "stdin": data, "tty": sys.stdin.isatty()}) + "\\n")
store = os.path.join(here, "items.json")
items = json.load(open(store)) if os.path.exists(store) else {}
def opt(words, flag):
    return words[words.index(flag) + 1] if flag in words else None
if argv[:1] == ["-i"]:
    for line in data.splitlines():
        words = shlex.split(line)
        if words and words[0] == "add-generic-password":
            items[opt(words, "-s") + "|" + opt(words, "-a")] = opt(words, "-w")
    json.dump(items, open(store, "w"))
    sys.exit(0)
if argv[:1] == ["find-generic-password"]:
    key = opt(argv, "-s") + "|" + opt(argv, "-a")
    if key in items:
        sys.stdout.write(items[key] + "\\n")
        sys.exit(0)
    sys.exit(44)
sys.exit(2)
''', encoding="utf-8")
        tool = shim_dir / "security"
        tool.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        tool.chmod(0o755)
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(tool)}):
            store_token(HOST, 443, NEW_TOKEN)
            with asr_creds.secret("remote", HOST, 443) as read_back:
                self.assertEqual(read_back, NEW_TOKEN)
        log = [json.loads(line) for line in (shim_dir / "log.jsonl").read_text().splitlines()]
        write = log[0]
        self.assertEqual(write["argv"], ["-i"])
        self.assertIn(NEW_TOKEN, write["stdin"])
        self.assertFalse(write["tty"])
        self.assertTrue(all(NEW_TOKEN not in " ".join(entry["argv"]) for entry in log))

    def test_store_token_refuses_what_cannot_be_a_token_or_an_item(self):
        for token in ("", "mcap1_x", NEW_TOKEN + "\n", 'mcap1_11223344_"' + "a" * 31, "x" * 400):
            with self.subTest(token=token[:20]):
                run = KeychainRun(self)
                with self.assertRaises(EngineAuthError) as cm:
                    store_token(HOST, 443, token, run=run)
                self.assertEqual(cm.exception.code, "store_failed")
                self.assertEqual(run.calls, [])
        for host, port in (("127.0.0.1", 443), ("", 443), (HOST, 0), (HOST, "443")):
            with self.subTest(host=host, port=port), self.assertRaises(EngineAuthError):
                store_token(host, port, NEW_TOKEN, run=KeychainRun(self))
        with mock.patch.object(apikey, "keychain_account", return_value='mic"; delete-generic-password -a "x'):
            with self.assertRaises(EngineAuthError):
                store_token(HOST, 443, NEW_TOKEN, run=KeychainRun(self))                                      # an account that could end the quoted string


# ======================================================================================================================
class ErrorMappingTests(RemoteCase):
    def setUp(self):
        super().setUp()
        self.engine_ = self.loaded()
        self.transport.calls.clear()
        self.sleep.waits.clear()

    def attempt(self, *answers):
        self.server.queued.clear()
        self.transport.calls.clear()
        self.sleep.waits.clear()
        self.server.fail("/v1/chunk", *answers)
        return self.engine_.transcribe_chunk(audio(), "en", None)

    def test_a_refused_credential_is_an_auth_error_after_one_attempt(self):
        for status, code in ((401, "unauthorized"), (403, "forbidden")):
            with self.subTest(status=status), self.assertRaises(EngineAuthError) as cm:
                self.attempt(*[error_answer(status, code)] * 3)
            self.assertEqual((cm.exception.status, cm.exception.code, len(self.chunks())), (status, code, 1))

    def test_a_protocol_mismatch_is_a_policy_denial(self):
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.attempt(json_response(426, {"error": {"code": "proto_mismatch", "message": "m"}, "supported": ["mcap-asr/9"]}))
        self.assertEqual((cm.exception.status, len(self.chunks())), (426, 1))

    def test_a_redirect_is_a_policy_denial_never_followed(self):
        with self.assertRaises(EnginePolicyDenied) as cm:
            self.attempt(Response(307, {"location": "https://evil.example.test/v1/chunk"}, b"", 0, 0, 0))
        self.assertEqual(cm.exception.code, "redirect")
        self.assertEqual((len(self.chunks()), self.paths()), (1, ["POST /v1/chunk"]))
        self.assertNotIn("evil", str(cm.exception))

    def test_rate_limits_and_a_busy_server_wait_retry_after_then_are_transient(self):
        for status, code in ((429, "quota_exceeded"), (503, "busy")):
            with self.subTest(status=status), self.assertRaises(EngineTransient) as cm:
                self.attempt(*[error_answer(status, code, retry_after=7)] * 3)
            self.assertEqual((cm.exception.status, cm.exception.code), (status, code))
            self.assertEqual((len(self.chunks()), self.sleep.waits), (3, [7.0, 7.0]))

    def test_one_retry_for_a_server_error_then_it_is_transient(self):
        for status, code in ((500, "engine_error"), (504, "engine_timeout"), (408, "request_timeout"), (502, "x")):
            with self.subTest(status=status), self.assertRaises(EngineTransient) as cm:
                self.attempt(*[error_answer(status, code)] * 3)
            self.assertEqual((cm.exception.status, len(self.chunks()), self.sleep.waits), (status, 2, [1.0]))

    def test_a_server_error_that_clears_on_the_retry_succeeds(self):
        self.assertEqual(self.attempt(error_answer(500, "engine_error"))["text"], "chunk 32000 samples")
        self.assertEqual((len(self.chunks()), self.sleep.waits), (2, [1.0]))

    def test_a_client_error_is_the_chunks_failure_without_a_retry(self):
        for status, code in ((400, "bad_request"), (409, "idem_conflict"), (411, "length_required"), (413, "payload_too_large"),
                             (415, "unsupported_media_type"), (422, "unprocessable_audio"), (418, "teapot")):
            with self.subTest(status=status), self.assertRaises(EngineHttpError) as cm:
                self.attempt(*[error_answer(status, code)] * 3)
            self.assertEqual((cm.exception.status, cm.exception.code, len(self.chunks()), self.sleep.waits), (status, code, 1, []))
            self.assertFalse(cm.exception.retryable)
            self.assertNotIsInstance(cm.exception, (EngineTransient, EngineAuthError, EnginePolicyDenied))

    def test_a_connection_that_fails_is_retried_on_the_schedule_then_transient(self):
        self.transport.script = []
        original = self.transport.handler
        self.transport.handler = lambda call: ConnectionResetError("reset")
        self.addCleanup(setattr, self.transport, "handler", original)
        with self.assertRaises(EngineTransient) as cm:
            self.engine_.transcribe_chunk(audio(), "en", None)
        self.assertEqual((len(self.chunks()), self.sleep.waits), (3, [1.0, 2.5]))
        self.assertEqual(cm.exception.code, "connect")

    def test_what_a_server_says_never_enters_an_error_message_a_log_a_usage_record_or_a_file(self):
        hostile = [error_answer(s, c, message=CANARY_TEXT) for s, c in ((400, "bad_request"), (401, "unauthorized"), (429, "quota_exceeded"),
                                                                          (500, "engine_error"), (503, "busy"), (404, "vocab_unknown"))]
        hostile.append(json_response(500, {"error": {"code": CANARY_TEXT, "message": CANARY_TEXT, "retry_after_s": CANARY_TEXT}}))
        hostile.append(json_response(400, {"error": CANARY_TEXT}))
        hostile.append(Response(500, {"retry-after": CANARY_TEXT, "x-note": CANARY_TEXT}, CANARY_TEXT.encode(), 0, 0, 0))
        for answer in hostile:
            with self.subTest(status=answer.status):
                try:
                    self.attempt(*[answer] * 3)
                except EngineError as exc:
                    text = str(exc) + repr(exc) + repr(vars(exc))
                    for fragment in CANARY_FRAGMENTS:
                        self.assertNotIn(fragment, text)
                    self.assertTrue(any(w in str(exc) for w in FIXED_MESSAGE_WORDS), str(exc))
        self.assertNothingLeaked()

    def test_the_messages_are_fixed_sentences(self):
        seen = set()
        for status, code in ((401, "unauthorized"), (426, "proto_mismatch"), (429, "quota_exceeded"), (400, "bad_request"), (500, "x")):
            try:
                self.attempt(*[error_answer(status, code, message="the sky is falling")] * 3)
            except EngineError as exc:
                seen.add(str(exc))
                self.assertNotIn("sky", str(exc))
        self.assertEqual(len(seen), 5)


# ======================================================================================================================
class IdempotencyTests(RemoteCase):
    def test_every_attempt_of_one_request_carries_the_same_key_and_the_same_body(self):
        engine = self.loaded()
        self.server.fail("/v1/chunk", error_answer(503, "busy", retry_after=1), error_answer(429, "quota_exceeded", retry_after=1))
        engine.transcribe_chunk(audio(), "en", None)
        calls = self.chunks()
        self.assertEqual(len(calls), 3)
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in calls}), 1)
        self.assertEqual(len({c.body for c in calls}), 1)
        engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in self.chunks()}), 2)                          # the next request is a new one

    def test_a_retry_after_a_lost_answer_meets_the_cached_computation_not_a_second_one(self):
        engine = self.loaded()
        lost = []
        original = self.transport.handler

        def answer_is_lost(call):
            response = original(call)
            if call.path == "/v1/chunk" and not lost:
                lost.append(1)
                raise ConnectionResetError("reset after the server had computed")
            return response
        self.transport.handler = answer_is_lost
        result = engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual((result["text"], self.server.computed, len(self.chunks())), ("chunk 32000 samples", 1, 2))

    def test_the_same_key_with_another_body_is_a_conflict_that_is_not_retried(self):
        engine = self.loaded(None, idem_fn=lambda: "00000000-0000-4000-8000-000000000001")
        engine.transcribe_chunk(audio(1.0), "en", None)
        with self.assertRaises(EngineHttpError) as cm:
            engine.transcribe_chunk(audio(2.0), "en", None)
        self.assertEqual((cm.exception.status, cm.exception.code), (409, "idem_conflict"))
        self.assertEqual(len(self.chunks()), 2)

    def test_the_lane_gate_is_read_before_every_attempt_also_after_a_retry_after_sleep(self):
        engine = self.loaded()
        self.sleep.on_sleep = lambda seconds: self.gate.close("local_only")
        self.server.fail("/v1/chunk", *[error_answer(503, "busy", retry_after=5)] * 3)
        with self.assertRaises(EnginePolicyDenied) as cm:
            engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(cm.exception.code, "local_only")
        self.assertEqual((len(self.chunks()), self.sleep.waits), (1, [5.0]))                                 # nothing was sent after the switch


# ======================================================================================================================
class DeclarationTests(RemoteCase):
    def test_the_engine_is_what_the_registry_and_the_policy_say_it_is(self):
        self.assertIs(asr_engines.engine_class("remote"), RemoteEngine)
        meta = policy.ENGINE_META["remote"]
        engine = self.engine()
        caps = engine_caps(engine)
        self.assertEqual((engine.engine_id, caps.kind, caps.residency, caps.uses_prompt, caps.supports_lid, caps.confidence, caps.timing),
                         ("remote", meta["kind"], meta["residency"], False, True, "logprob", "segment"))
        self.assertEqual(engine.destination_label(), "company-asr")
        self.assertEqual(engine.progress_tag(), "[server]")
        self.assertEqual(engine.describe()["protocol"], "mcap-asr/1")
        self.assertEqual((engine.host, engine.port, engine.model), (HOST, 443, ""))

    def test_constructing_an_engine_reads_nothing_and_asks_nobody(self):
        with mock.patch.object(policy, "machine_id", side_effect=AssertionError("ioreg")), mock.patch.object(
                policy, "load_org_policy", side_effect=AssertionError("policy")):
            self.engine(VOCAB)
        self.assertEqual((self.transport.calls, self.security.calls()), ([], []))

    def test_the_machine_header_is_optional(self):
        def broken():
            raise OSError("no ioreg")
        engine = self.loaded(None, machine_id_fn=broken)
        engine.transcribe_chunk(audio(), "en", None)
        self.assertIsNone(self.chunks()[0].header("X-MCAP-Machine"))
        self.assertEqual(self.chunks()[0].header("X-MCAP-Proto"), "mcap-asr/1")

    def test_the_run_id_is_16_hex_and_random_per_engine(self):
        decision = self.decision()
        guard = EgressGuard({HOST: decision.hosts[HOST]}, engine_id="remote", consent_id="c", transport=self.transport, trust="private")
        ids = {RemoteEngine(self.cfg, None, decision, guard).run_id for _ in range(5)}
        self.assertEqual(len(ids), 5)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{16}", i) for i in ids))

    def test_provenance_counts_what_was_sent(self):
        engine = self.loaded(VOCAB)
        self.assertFalse(engine.sent_anything())
        self.assertEqual(engine.provenance()["privacy"], "local")
        engine.transcribe_chunk(audio(2.0), "en", None)
        engine.detect_languages([audio(1.0)])
        block = engine.provenance()
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"], block["protocol"]),
                         ("remote", "server", "server", "company-asr", "mcap-asr/1"))
        self.assertEqual(block["chunks"], {"remote": 1})
        self.assertEqual((block["sent"]["requests"], block["sent"]["lid_requests"], block["sent"]["audio_s"]), (1, 1, 3.0))   # 2 s chunk + 1 s clip
        self.assertNotIn(HOST, json.dumps(block))
        self.assertNotIn(TOKEN, json.dumps(block))

    def test_a_vocabulary_alone_makes_the_destination_touched(self):
        engine = self.loaded(VOCAB)
        self.assertFalse(engine.sent_anything())                                                           # a health check carries no meeting data
        engine._ensure_vocab()
        self.assertEqual((engine.sent_anything(), engine.usage()["requests"], engine.provenance()["privacy"]), (True, 0, "server"))

    def test_the_usage_lines_carry_no_content(self):
        engine = self.loaded(VOCAB)
        engine.transcribe_chunk(audio(), "en", None)
        engine.detect_languages([audio(1.0)])
        lines = usage_lines(self.cfg)
        self.assertEqual([l["op"] for l in lines], ["health", "vocab", "chunk", "lid"])
        self.assertTrue(all(l["host"] == HOST and l["engine"] == "remote" and l["kind"] == "server" for l in lines))
        text = json.dumps(lines)
        for needle in ("Acme", "chunk 32000", TOKEN, "Bearer"):
            self.assertNotIn(needle, text)

    def test_the_module_opens_no_socket_of_its_own(self):
        tree = ast.parse(Path(asr_remote.__file__).read_text(encoding="utf-8"))
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
                imported.add(node.module.split(".")[0])
        self.assertFalse(imported & {"socket", "ssl", "http", "urllib", "requests", "httpx", "urllib3", "asyncio", "selectors"}, imported)

    def test_the_default_path_does_not_import_the_remote_client(self):
        code = ("import sys, mcap.asr, mcap.asr_engines, mcap.transcript; "
                "print(','.join(m for m in ('mcap.asr_remote', 'mcap.asr_router', 'mcap.asr_http') if m in sys.modules))")
        done = subprocess.run([sys.executable, "-c", code], cwd=str(Path(__file__).resolve().parents[1]), capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, ""), done.stderr)


# ======================================================================================================================
class EndToEndTests(RemoteCase):
    """The real asr.transcribe_tracks over the synthetic two-track audio of the golden fixtures, through build_engine (the real registry entry
    of ``remote``), a real RoutedEngine, EgressGuard and RemoteEngine, in front of FakeServer. The only fakes: the transport, the clock, the gate."""

    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(policy, "machine_id", return_value=MACHINE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_asr(self, **cfg_kw):
        cfg, decision = make_run(self.cfg, "remote", "none")
        cfg = dataclasses.replace(cfg, asr_vad="energy", mic_aec="0", asr_language="auto", self_name="Me", **cfg_kw)

        def engine_for(c, vocab, progress=None):
            return build_engine(c, vocab, progress=progress, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep,
                                rand=lambda: 0.5, clock=self.clock)
        with mock.patch.object(asr, "_engine_for", engine_for):
            return asr.transcribe_tracks(mg.prepared_audio(), cfg, VOCAB)

    def test_both_tracks_are_transcribed_by_the_server_with_language_id_and_a_vocabulary(self):
        out = self.run_asr()
        block = out["asr"]
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"]), ("remote", "server", "server", "company-asr"))
        self.assertEqual(block["model"], "mlx-community/whisper-large-v3-mlx@49e6aa28")
        self.assertEqual(out["asr_model"] if "asr_model" in out else block["model"], block["model"])
        self.assertGreaterEqual(block["chunks"]["remote"], 2)
        self.assertGreaterEqual(block["sent"]["lid_requests"], 1)
        self.assertGreater(len(out["segments"]), 0)
        self.assertTrue(all(s["text"].startswith("chunk ") for s in out["segments"]))
        paths = self.paths()
        self.assertEqual(paths[0], "GET /v1/health")
        self.assertEqual(len([p for p in paths if p.startswith("PUT /v1/vocab/")]), 1)                    # once per run, not per track
        self.assertEqual(len([p for p in paths if p == "GET /v1/health"]), 1)
        calls = self.transport.calls
        self.assertEqual({c.header("X-MCAP-Run") for c in calls}, {c.header("X-MCAP-Run") for c in calls[:1]})
        self.assertEqual(len({c.header("X-MCAP-Idem") for c in calls}), len(calls))                         # one key per logical request
        self.assertTrue(all(c.header("Authorization") == f"Bearer {TOKEN}" for c in calls))
        text = json.dumps(out)
        for needle in (HOST, TOKEN, "Acme, AcmeScan"):
            self.assertNotIn(needle, text)
        self.assertEqual(self.security.reads(), 1)
        self.assertEqual(self.server.computed, block["chunks"]["remote"])

    def test_an_opaque_backend_without_language_id_takes_the_single_label_path(self):
        self.server.health = health_document(supports_lid=False, confidence="opaque")
        self.server.confidence = "opaque"
        out = self.run_asr()
        self.assertEqual(self.transport.requests("/v1/lid"), [])
        self.assertEqual(out["asr"]["sent"]["lid_requests"], 0)
        self.assertTrue(all(c.header("X-MCAP-Lang") == "auto" for c in self.chunks()))
        self.assertTrue(all(s["avg_logprob"] is None for s in out["segments"]))

    def assert_transcribed_without_language_id(self):
        """The run of a server whose first /v1/lid request is refused: both tracks are still transcribed (docs/ASR_PROTOCOL.md 12.3: the
        client then uses its single-label path), nothing raised, language ID asked for once, every chunk sent as ``auto``."""
        out = self.run_asr()
        self.assertEqual(len(self.transport.requests("/v1/lid")), 1)
        self.assertEqual(out["asr"]["sent"]["lid_requests"], 1)
        self.assertGreaterEqual(out["asr"]["chunks"]["remote"], 2)
        self.assertEqual({s["speaker"] for s in out["segments"]}, {"Me", "Remote"})                       # both tracks have text
        self.assertTrue(all(s["text"].startswith("chunk ") for s in out["segments"]))
        self.assertTrue(self.chunks() and all(c.header("X-MCAP-Lang") == "auto" for c in self.chunks()), [c.header("X-MCAP-Lang") for c in self.chunks()])
        self.assertEqual({c.header("X-MCAP-Langs") for c in self.chunks()}, {"ko,en"})
        self.assertEqual(self.paths("/v1/lid")[0], "POST /v1/lid")
        self.assertLess(self.paths().index("POST /v1/lid"), self.paths().index("POST /v1/chunk"))        # it was asked before the first chunk, and not again
        json.dumps(out, ensure_ascii=False).encode("utf-8")
        return out

    def test_a_server_that_answers_400_to_language_id_after_all_still_transcribes_with_auto(self):
        self.server.lid_supported = False                                                                  # health said supports_lid true
        self.assert_transcribed_without_language_id()

    def test_a_413_or_a_422_on_a_language_id_batch_does_not_fail_the_meetings_asr_stage(self):
        for status, code in ((413, "payload_too_large"), (422, "unprocessable_audio")):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.server.queued.clear()
                self.server.fail("/v1/lid", error_answer(status, code))
                self.assert_transcribed_without_language_id()

    def test_a_refused_language_id_batch_does_not_trip_the_router_nor_wake_the_local_fallback(self):
        local = FakeLocalEngine()
        with mock.patch.object(asr_engines, "get_engine", return_value=local):
            cfg, _decision = make_run(self.cfg, "remote", "whisper")
            for status, code in ((400, "bad_request"), (413, "payload_too_large"), (422, "unprocessable_audio")):
                with self.subTest(status=status):
                    router = build_engine(cfg, VOCAB, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep,
                                          rand=lambda: 0.5, clock=self.clock)
                    self.server.queued.clear()
                    self.server.fail("/v1/lid", error_answer(status, code))
                    router.load()
                    out = router.detect_languages([audio(1.0, 0.5)] * 3, ("ko", "en"))                      # docs/ASR_PROTOCOL.md 12.3: no exception
                    self.assertEqual([(r["ko"], r["en"]) for r in out], [(0.5, 0.5)] * 3)
                    self.assertEqual((local.lid_calls, router.breaker.opened), (0, 0))                     # not a router trigger, the fallback stays asleep
                    self.assertFalse(router.primary.supports_lid)
                    router.release()

    def test_a_lone_surrogate_in_a_server_answer_does_not_break_the_transcript_files(self):
        def hostile(doc):
            return dict(doc, text="hi\ud800", language="en", segments=[dict(doc["segments"][0], text="chunk \ud800 text")])
        self.server.chunk_override = hostile
        out = self.run_asr()
        self.assertTrue(out["segments"] and all("\ud800" not in s["text"] for s in out["segments"]))
        mcap_state.atomic_write_json(Path(self.root) / "transcript.json", out)                           # what pipeline.py does after the ASR stage
        self.assertTrue((Path(self.root) / "transcript.json").read_bytes().decode("utf-8").startswith("{"))

    def test_the_servers_prompt_feeds_the_echo_guard_of_the_postfilter(self):
        def parrot(doc):
            said = doc["prompt_text"] or "Acme Acme Acme AcmeScan-CXR AcmeScan-CXR AcmeScan-CXR"            # a decoder that reads the prompt back
            return dict(doc, text=said, segments=[dict(doc["segments"][0], text=said)])
        self.server.chunk_override = parrot
        out = self.run_asr()
        self.assertEqual([s for s in out["segments"] if "Acme" in s["text"]], [])                        # the echo of the prompt the server used is dropped
        self.assertGreater(sum(out["stats"][t]["dropped"] for t in ("mic", "remote") if out["stats"][t]), 0)
        kept_without_the_prompt = lambda doc: dict(parrot(doc), prompt_text="")        # noqa: E731  the same words, no prompt reported to the client
        self.server.chunk_override = kept_without_the_prompt
        again = self.run_asr()
        self.assertGreater(len(again["segments"]), len(out["segments"]))                                   # without prompt_text nothing marks them as an echo

    def test_a_server_that_is_down_is_unreachable_not_a_failed_meeting(self):
        self.transport.handler = lambda call: ConnectionRefusedError("down")
        with self.assertRaises(asr.AsrUnreachable):
            self.run_asr()
        self.assertEqual(len(self.transport.calls), 1)                                                        # one health request, nothing else

    def test_a_refused_server_is_a_policy_error_not_a_waiting_condition(self):
        self.server.health["retention"]["mode"] = "disk"
        with self.assertRaises(EnginePolicyDenied):
            self.run_asr()
        self.assertEqual([c.path for c in self.transport.calls], ["/v1/health"])

    def test_a_meeting_switched_to_local_only_after_the_first_chunk_sends_nothing_more(self):
        self.transport.on_send = lambda call: self.gate.close("local_only") if call.path == "/v1/chunk" else None
        with self.assertRaises(EnginePolicyDenied):                                                           # no fallback: the stage has nowhere to go
            self.run_asr()
        self.assertEqual(self.paths()[-1], "POST /v1/chunk")                                                  # the request that was on its way; none after it
        self.assertEqual(len(self.chunks()), 1)

    def test_the_stage_never_asks_the_remote_engine_for_a_tokenizer(self):
        with mock.patch.object(RoutedEngine, "tokenizer", new_callable=mock.PropertyMock, side_effect=AssertionError("tokenizer")):
            self.run_asr()


if __name__ == "__main__":
    unittest.main()
