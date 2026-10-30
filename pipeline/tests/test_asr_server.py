"""asr_server.py (docs/ASR_PROTOCOL.md): the mcap-asr/1 server core, driven through
``handle_request`` with a FAKE backend and no socket (the HTTP front end is driven through a socketpair, which is AF_UNIX and carries no
network traffic; the one real loopback test is test_asr_server_socket.py and is off by default).

Covered: auth (valid, unknown, revoked, expired, disabled), the token file re-read, quotas (concurrency, requests per minute, audio seconds
per day, restored from the metadata log), 411/413/415/426, forbidden headers, 503 at once, the fair round-robin queue, idempotency (bound
to token and body hash, in-flight merging, 409), the vocabulary PUT and the 404 flow, enrollment, renewal, token sync, health, purge, the
content-free metadata log, the byte scan (no audio or text anywhere in the server's files and logs after a run), the startup self-checks,
the daily audit and the admin CLI."""
import collections
import contextlib
import hashlib
import importlib.util
import io
import json
import logging
import os
import socket
import stat
import subprocess
import sys
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from net_guard_support import NoNetworkCase

from mcap import apikey, asr_engines, asr_server as S
from mcap.asr_engines import Engine, WhisperEngine
from mcap.config import Config
from mcap.egress import EgressGuard, Response
from mcap.policy import HostRule

REPO = Path(__file__).resolve().parents[2]
TEXT_CANARY = "CANARY-TRANSCRIPT-액미-4f2a9c"                 # what the fake backend 'hears': must never reach a file or a log
TERM_CANARY = "CANARY-TERM-7b1d5e"                              # a vocabulary term
BASE = time.mktime((2026, 10, 15, 10, 0, 0, 0, 0, -1))          # 10:00 local: midnight is 14 h away whatever the time zone


class FakeClock:
    """Wall clock and monotonic clock that only move when a test says so."""

    def __init__(self):
        self.t, self.m = BASE, 1000.0

    def now(self) -> float:
        return self.t

    def mono(self) -> float:
        return self.m

    def advance(self, seconds: float) -> None:
        self.t += seconds
        self.m += seconds


class _Tok:
    def encode(self, text):
        return [0] * max(1, len(text) // 2)


class FakeBackend(Engine):
    """A Whisper-shaped engine without a model. ``gate`` (an Event) holds ``transcribe_chunk`` until a test releases it; ``script`` is a
    list of results or exceptions for the next calls; ``entered`` counts the calls that have started."""
    name = engine_id = "whisper"
    kind = "local"
    model = "fake/whisper-test"
    supports_lid = True
    uses_prompt = True
    confidence = "logprob"
    prompt_frames = {"ko": "KO-FRAME: ", "en": "EN-FRAME: "}

    def __init__(self, text=TEXT_CANARY):
        super().__init__("fake/whisper-test", allow_download=False)
        self.text = text
        self.calls, self.lid_calls, self.terms_seen = [], [], []
        self.loaded = self.released = 0
        self.gate = None
        self.entered = threading.Semaphore(0)
        self.script = []
        self.on_call = None
        self._lock = threading.Lock()

    def load(self):
        self.loaded += 1

    def release(self):
        self.released += 1

    @property
    def tokenizer(self):
        return _Tok()

    def set_request_terms(self, terms):
        self.terms_seen.append(tuple(terms))

    def detect_languages(self, clips, languages=("ko", "en")):
        self.lid_calls.append((len(clips), tuple(languages)))
        rest = 0.1 / max(1, len(languages) - 1)
        return [{**{c: (0.9 if c == languages[0] else rest) for c in languages}, "top": languages[0]} for _ in clips]

    def transcribe_chunk(self, audio, language, prompt):
        marker = int(round(float(audio[0]) * 32768)) if len(audio) else 0
        with self._lock:
            self.calls.append({"language": language, "prompt": prompt, "samples": len(audio), "marker": marker})
        self.entered.release()
        if self.on_call:
            self.on_call()
        if self.gate is not None:
            assert self.gate.wait(15), "the test never released the backend"
        if self.script:
            item = self.script.pop(0)
            if isinstance(item, BaseException):
                raise item
            return item
        return {"text": self.text, "language": language or "ko", "avg_logprob": -0.2,
                "segments": [{"start": 0.0, "end": 1.0, "text": self.text, "avg_logprob": -0.2, "no_speech_prob": 0.01,
                              "compression_ratio": 1.2, "temperature": 0.0}]}


class Reply:
    def __init__(self, triple):
        self.status, self.headers, self.raw = triple

    @property
    def json(self):
        return json.loads(self.raw.decode("utf-8")) if self.raw else None

    @property
    def code(self):
        return (self.json or {}).get("error", {}).get("code")


def pcm(n=16000, marker=7):
    return np.full(n, marker, dtype="<i2").tobytes()


def md5ish(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ServerCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.secrets, self.logs = self.root / "secrets", self.root / "logs"
        for directory in (self.secrets, self.logs):
            directory.mkdir()
            os.chmod(directory, 0o700)
        self.clock = FakeClock()
        self.backend = FakeBackend()
        quiet = logging.NullHandler()                          # the server logs its errors: keep them out of the test run's stderr
        logging.getLogger("mcap.asr_server").addHandler(quiet)
        self.addCleanup(logging.getLogger("mcap.asr_server").removeHandler, quiet)
        self.state = self.make_state()

    def config(self, **over) -> S.ServerConfig:
        values = {"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}
        values.update(over)
        return S.config_from_dict(values)

    def make_state(self, backend=None, **over) -> S.ServerState:
        state = S.ServerState(self.config(**over), backend or self.backend, now_fn=self.clock.now, clock=self.clock.mono)
        state.request_deadline_s = 20.0                       # a test that hangs fails in 20 s, not in 120
        state.start()
        self.addCleanup(state.close)
        return state

    def release_at_end(self, gate):
        self.addCleanup(gate.set)                             # runs before state.close (cleanups are last in, first out)

    def tearDown(self):
        if self.backend.gate is not None:                     # a test that failed while the engine was held must not wait for its threads
            self.backend.gate.set()
        super().tearDown()

    def token(self, user="alice", state=None, **kw):
        state = state or self.state
        token, row = state.tokens.issue(user, kw.pop("now", self.clock.t), kw.pop("ttl_days", 90), **kw)
        return token

    def call(self, method, path, *, token=None, body=b"", headers=None, now=None, peer=None, state=None, proto=True):
        h = {}
        if proto:
            h["X-MCAP-Proto"] = S.PROTO
        if token:
            h["Authorization"] = f"Bearer {token}"
        if method in ("POST", "PUT"):
            h["Content-Length"] = str(len(body))
        h.update(headers or {})
        return Reply(S.handle_request(state or self.state, method, path, h, body, self.clock.t if now is None else now, peer=peer))

    def chunk(self, token, n=16000, marker=7, lang="auto", extra=None, body=None, **kw):
        body = pcm(n, marker) if body is None else body
        h = {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(n), "X-MCAP-Lang": lang}
        h.update(extra or {})
        return self.call("POST", "/v1/chunk", token=token, body=body, headers=h, **kw)

    def lid(self, token, counts, langs="ko,en", body=None, **kw):
        body = pcm(sum(counts)) if body is None else body
        h = {"Content-Type": "application/octet-stream", "X-MCAP-Clips": ",".join(str(c) for c in counts), "X-MCAP-Langs": langs}
        return self.call("POST", "/v1/lid", token=token, body=body, headers=h, **kw)

    def put_vocab(self, token, terms, **kw):
        obj = {"terms": terms}
        body = S._dumps(obj)
        headers = {"Content-Type": "application/json", **kw.pop("headers", {})}
        return self.call("PUT", "/v1/vocab/" + S.canonical_vocab_digest(obj), token=token, body=body, headers=headers, **kw)

    def records(self):
        out = []
        for name in sorted(os.listdir(self.logs)):
            if name.startswith("meta-"):
                with open(self.logs / name, encoding="ascii") as fh:
                    out.extend(json.loads(line) for line in fh if line.strip())
        return out

    def spawn(self, fn, *args, **kwargs):
        box = {}

        def run():
            box["r"] = fn(*args, **kwargs)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 15)
        return box

    def wait_for(self, predicate, what="condition", timeout=10.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.005)
        self.fail(f"timed out waiting for {what}")


# ======================================================================================================================
class ConfigTests(NoNetworkCase):
    def test_defaults_are_the_documented_ones(self):
        cfg = S.config_from_dict({})
        self.assertEqual((cfg.listen, cfg.tls_cert, cfg.tls_key, cfg.secrets_dir, cfg.backend), ("127.0.0.1:8443", "", "", S.DEFAULT_SECRETS_DIR, "whisper"))
        self.assertEqual((cfg.max_queue, cfg.max_wait_s, cfg.per_token_concurrency, cfg.per_token_audio_s_per_day, cfg.per_token_rpm),
                         (64, 45, 2, 43200, 120))
        self.assertEqual((cfg.token_ttl_days, cfg.enroll_code_ttl_s, cfg.metadata_log_days), (90, 600, 400))
        self.assertEqual(S.DEFAULT_SECRETS_DIR, "/Library/Application Support/MeetingCapture-asr")

    def test_default_model_is_the_client_default(self):
        self.assertEqual(S.DEFAULT_MODEL, Config().asr_model)

    def test_example_file_loads_and_documents_every_key(self):
        path = REPO / "scripts" / "asr_server" / "asr-server.example.json"
        raw = json.loads(path.read_text(encoding="utf-8"))
        cfg = S.load_server_config(path)
        self.assertEqual(set(raw), set(S.ServerConfig.__dataclass_fields__))
        self.assertEqual((cfg.max_queue, cfg.max_wait_s, cfg.per_token_concurrency, cfg.per_token_audio_s_per_day, cfg.per_token_rpm),
                         (64, 45, 2, 43200, 120))
        self.assertEqual((cfg.token_ttl_days, cfg.enroll_code_ttl_s, cfg.metadata_log_days, cfg.backend), (90, 600, 400, "whisper"))
        self.assertTrue(cfg.listen.startswith("127.0.0.1:"))

    def test_strict_rejections(self):
        bad = [{"nope": 1}, {"max_queue": 0}, {"max_queue": True}, {"max_queue": "64"}, {"max_wait_s": 111}, {"per_token_rpm": 6001},
               {"listen": "asr.example.test:443"}, {"listen": "127.0.0.1"}, {"listen": "127.0.0.1:99999"}, {"tls_cert": "/c.pem"},
               {"tls_key": "/k.pem"}, {"secrets_dir": "relative"}, {"log_dir": 7}, {"backend": "Whisper!"}, {"backend_options": []},
               {"initial_service_s": 0}, {"model": 5}, {"secrets_dir": ""}]
        for obj in bad:
            with self.subTest(obj=obj), self.assertRaises(S.ConfigError):
                S.config_from_dict(obj)
        with self.assertRaises(S.ConfigError):
            S.config_from_dict([])

    def test_ext_is_free_form_and_a_duplicate_key_is_refused(self):
        self.assertEqual(S.config_from_dict({"ext": {"notes": "anything", "n": [1]}}).ext["n"], [1])
        path = self.root / "dup.json"
        path.write_text('{"max_queue": 3, "max_queue": 4}', encoding="utf-8")
        with self.assertRaises(S.ConfigError):
            S.load_server_config(path)
        path.write_bytes(b"\xef\xbb\xbf{}")
        with self.assertRaises(S.ConfigError):
            S.load_server_config(path)
        path.write_text("x" * 70000, encoding="utf-8")
        with self.assertRaises(S.ConfigError):
            S.load_server_config(path)
        with self.assertRaises(S.ConfigError):
            S.load_server_config(self.root / "missing.json")

    def test_listen_forms_and_loopback(self):
        self.assertEqual(S.parse_listen("[::1]:8443"), ("::1", 8443))
        self.assertEqual(S.parse_listen("localhost:0"), ("localhost", 0))
        for host, loop in (("127.0.0.1", True), ("::1", True), ("localhost", True), ("0.0.0.0", False), ("::", False), ("10.0.0.5", False),
                           ("::ffff:127.0.0.1", True), ("asr.example.test", False)):
            self.assertEqual(S.is_loopback_host(host), loop, host)

    def test_effective_hash_follows_the_settings(self):
        a, b = S.config_from_dict({}), S.config_from_dict({"max_queue": 5})
        self.assertEqual(a.effective_sha256(), S.config_from_dict({}).effective_sha256())
        self.assertNotEqual(a.effective_sha256(), b.effective_sha256())


# ======================================================================================================================
class AuthTests(ServerCase):
    def test_valid_token_and_the_minimal_health_without_one(self):
        token = self.token()
        self.assertEqual(self.call("GET", "/v1/health").json, {"proto": S.PROTO, "ok": True})
        self.assertEqual(self.call("GET", "/v1/health", token=token).json, {"proto": S.PROTO, "ok": True})       # detail needs ?detail=1
        full = self.call("GET", "/v1/health?detail=1", token=token)
        self.assertEqual(full.status, 200)
        self.assertEqual(full.json["engine"], "whisper")

    def test_every_refusal_is_the_same_401_except_a_disabled_row(self):
        good = self.token("alice")
        other = self.token("sam")
        row_id = other.split("_")[1]
        self.state.tokens.update(lambda rows: (None, [r.update({"revoked": S._iso(self.clock.t)}) for r in rows if r["id"] == row_id] and True))
        expired = self.token("old", now=self.clock.t - 100 * 86400, ttl_days=90)
        wrong_secret = good[:-1] + ("A" if good[-1] != "A" else "B")
        unknown_id = "mcap1_" + "0" * 8 + "_" + "A" * 32
        cases = {"no header": None, "malformed": "Bearer nope", "wrong scheme": "Basic abc", "unknown id": unknown_id,
                 "wrong secret": wrong_secret, "revoked": other, "expired": expired}
        answers = set()
        for name, value in cases.items():
            headers = {"Authorization": value if value is None or " " in value else f"Bearer {value}"} if value else {}
            if value and value.startswith(("Bearer ", "Basic ")):
                headers = {"Authorization": value}
            reply = self.call("POST", "/v1/purge", headers=headers)
            with self.subTest(case=name):
                self.assertEqual((reply.status, reply.code), (401, "unauthorized"))
                self.assertEqual(reply.headers["WWW-Authenticate"], "Bearer")
            answers.add(reply.raw)
        self.assertEqual(len(answers), 1)                     # nothing tells a revoked token from an unknown one
        self.assertEqual(self.call("POST", "/v1/purge", token=good).status, 200)

    def test_expiry_is_judged_by_the_request_time(self):
        token = self.token(ttl_days=1)
        self.assertEqual(self.call("POST", "/v1/purge", token=token, now=self.clock.t + 86399).status, 200)
        self.assertEqual(self.call("POST", "/v1/purge", token=token, now=self.clock.t + 86400).code, "unauthorized")

    def test_disabled_row_is_403(self):
        token = self.token("leaver")
        S.TokenTable(self.state.cfg.tokens_path).update(lambda rows: (None, [r.update({"disabled": "offboarded"}) for r in rows] and True))
        reply = self.call("POST", "/v1/purge", token=token)
        self.assertEqual((reply.status, reply.code), (403, "forbidden"))

    def test_the_secret_is_stored_only_as_a_digest(self):
        token = self.token("alice")
        secret = token.split("_", 2)[2]
        text = Path(self.state.cfg.tokens_path).read_text(encoding="utf-8")
        self.assertNotIn(secret, text)
        self.assertIn(hashlib.sha256(secret.encode()).hexdigest(), text)
        self.assertEqual(stat.S_IMODE(os.stat(self.state.cfg.tokens_path).st_mode), 0o600)
        self.assertTrue(S._TOKEN_ID.fullmatch(token.split("_")[1]) and len(secret) == 32)

    def test_token_file_is_reread_when_it_changes(self):
        token = self.token("alice")
        self.assertEqual(self.call("POST", "/v1/purge", token=token).status, 200)
        admin = S.TokenTable(self.state.cfg.tokens_path)                       # what `token revoke` in another process does
        admin.update(lambda rows: (None, [r.update({"revoked": S._iso(self.clock.t)}) for r in rows] and True))
        self.assertEqual(self.call("POST", "/v1/purge", token=token).code, "unauthorized")     # effective at the next request
        fresh = self.token("sam")
        self.assertEqual(self.call("POST", "/v1/purge", token=fresh).status, 200)

    def test_an_unsafe_token_file_means_nobody_gets_in(self):
        token = self.token("alice")
        path = self.state.cfg.tokens_path
        os.chmod(path, 0o644)
        self.assertEqual(self.call("POST", "/v1/purge", token=token).code, "unauthorized")
        self.assertIn("0600", self.state.tokens.problem)
        os.chmod(path, 0o600)
        self.assertEqual(self.call("POST", "/v1/purge", token=token).status, 200)
        Path(path).write_text("{not json", encoding="utf-8")
        self.assertEqual(self.call("POST", "/v1/purge", token=token).code, "unauthorized")

    def test_soft_binding_records_machine_and_network_and_never_rejects(self):
        token = self.token("alice")
        first = {"X-MCAP-Machine": "a" * 16}
        self.assertEqual(self.call("POST", "/v1/purge", token=token, headers=first, peer="203.0.113.77").status, 200)
        changed = self.call("POST", "/v1/purge", token=token, headers={"X-MCAP-Machine": "b" * 16}, peer="198.51.100.9")
        self.assertEqual(changed.status, 200)
        recs = [r for r in self.records() if r["op"] == "purge"]
        self.assertEqual([r["machine_changed"] for r in recs], [False, True])
        self.assertEqual([r["src_net"] for r in recs], ["203.0.113.0/24", "198.51.100.0/24"])
        row = S.TokenTable(self.state.cfg.tokens_path)
        row.rows()
        stored = next(iter(row.rows().values()))
        self.assertEqual((stored.machine, stored.net), ("b" * 16, "198.51.100.0/24"))       # a changed machine is written at once
        self.assertEqual(self.call("POST", "/v1/purge", token=token, headers={"X-MCAP-Machine": "not-hex"}).status, 200)

    def test_last_use_is_written_at_most_once_a_minute(self):
        token = self.token("alice")
        self.call("POST", "/v1/purge", token=token)
        path = self.state.cfg.tokens_path
        first = os.stat(path)
        for _ in range(5):
            self.clock.advance(5)
            self.call("POST", "/v1/purge", token=token)
        self.assertEqual(os.stat(path).st_ino, first.st_ino)                    # no rewrite inside the minute
        self.clock.advance(60)
        self.call("POST", "/v1/purge", token=token)
        self.assertNotEqual(os.stat(path).st_ino, first.st_ino)
        self.assertIsNotNone(next(iter(self.state.tokens.rows().values())).last_used)


# ======================================================================================================================
class HeaderTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_forbidden_headers_are_400(self):
        base = [("X-MCAP-Proto", S.PROTO), ("Authorization", f"Bearer {self.tok}"), ("Content-Type", "application/octet-stream"),
                ("X-MCAP-Samples", "16000")]
        body = pcm()
        cases = {"transfer-encoding": base + [("Content-Length", str(len(body))), ("Transfer-Encoding", "chunked")],
                 "duplicate content-length": base + [("Content-Length", str(len(body))), ("Content-Length", str(len(body)))],
                 "list content-length": base + [("Content-Length", f"{len(body)}, {len(body)}")],
                 "expect": base + [("Content-Length", str(len(body))), ("Expect", "100-continue")],
                 "upgrade": base + [("Content-Length", str(len(body))), ("Upgrade", "websocket")],
                 "duplicate authorization": base + [("Content-Length", str(len(body))), ("Authorization", f"Bearer {self.tok}")],
                 "duplicate x-mcap": base + [("Content-Length", str(len(body))), ("X-MCAP-Samples", "16000")]}
        for name, pairs in cases.items():
            with self.subTest(case=name):
                reply = Reply(S.handle_request(self.state, "POST", "/v1/chunk", pairs, body, self.clock.t))
                self.assertEqual((reply.status, reply.code), (400, "bad_request"))
        self.assertEqual(self.backend.calls, [])

    def test_case_insensitive_names_and_pair_lists_work(self):
        body = pcm()
        pairs = [("x-mcap-proto", S.PROTO), ("AUTHORIZATION", f"Bearer {self.tok}"), ("content-type", "application/octet-stream"),
                 ("X-Mcap-Samples", "16000"), ("Content-LENGTH", str(len(body)))]
        self.assertEqual(S.handle_request(self.state, "POST", "/v1/chunk", pairs, body, self.clock.t)[0], 200)

    def test_411_413_415_426(self):
        body = pcm()
        no_length = Reply(S.handle_request(self.state, "POST", "/v1/chunk", {"X-MCAP-Proto": S.PROTO, "Authorization": f"Bearer {self.tok}",
                                                                           "Content-Type": "application/octet-stream", "X-MCAP-Samples": "16000"},
                                            body, self.clock.t))
        self.assertEqual((no_length.status, no_length.code), (411, "length_required"))
        big = Reply(S.handle_request(self.state, "POST", "/v1/chunk", {"X-MCAP-Proto": S.PROTO, "Authorization": f"Bearer {self.tok}",
                                                                     "Content-Type": "application/octet-stream", "X-MCAP-Samples": "496001",
                                                                     "Content-Length": "992002"}, b"", self.clock.t))
        self.assertEqual((big.status, big.code), (413, "payload_too_large"))
        n = S.MAX_CHUNK_SAMPLES
        self.assertEqual(self.chunk(self.tok, n=n).status, 200)                  # exactly the limit is fine
        self.assertEqual(self.chunk(self.tok, n=n + 1).code, "payload_too_large")  # one sample more is not (header and length agree)
        wrong_type = self.chunk(self.tok, extra={"Content-Type": "audio/wav"})
        self.assertEqual((wrong_type.status, wrong_type.code), (415, "unsupported_media_type"))
        self.assertEqual(self.chunk(self.tok, extra={"Content-Encoding": "gzip"}).status, 415)
        self.assertEqual(self.put_vocab(self.tok, ["x"], headers={"Content-Type": "text/plain"}).status, 415)
        for headers in ({}, {"X-MCAP-Proto": "mcap-asr/2"}):
            reply = Reply(S.handle_request(self.state, "GET", "/v1/health", headers, b"", self.clock.t))
            self.assertEqual((reply.status, reply.code), (426, "proto_mismatch"))
            self.assertEqual(reply.json["supported"], ["mcap-asr/1"])

    def test_length_mismatches_are_400(self):
        self.assertEqual(self.chunk(self.tok, body=pcm(100), extra={"X-MCAP-Samples": "16000"}).code, "bad_request")
        self.assertEqual(self.chunk(self.tok, extra={"Content-Length": "5"}).code, "bad_request")          # body is longer than it says
        for samples in ("0", "-1", "abc", "", "1.5"):
            self.assertEqual(self.chunk(self.tok, extra={"X-MCAP-Samples": samples}).status, 400, samples)

    def test_routes_methods_and_query(self):
        self.assertEqual(self.call("GET", "/v1/nothing", token=self.tok).code, "not_found")
        self.assertEqual(self.call("GET", "/v1/chunk", token=self.tok).code, "method_not_allowed")
        self.assertEqual(self.call("POST", "/v1/health").code, "method_not_allowed")
        self.assertEqual(self.call("PUT", "/v1/vocab/zz", token=self.tok).code, "bad_request")
        self.assertEqual(self.call("POST", "/v1/purge?x=1", token=self.tok).code, "bad_request")
        self.assertEqual(self.call("GET", "/v1/health", headers={"Content-Length": "5"}).code, "bad_request")
        self.assertEqual(self.call("DELETE", "/v1/purge", token=self.tok).code, "method_not_allowed")

    def test_endpoint_header_validation(self):
        for extra in ({"X-MCAP-Lang": "zz"}, {"X-MCAP-Lang": "k o"}, {"X-MCAP-Prompt": "all"}, {"X-MCAP-Vocab": "abc"},
                      {"X-MCAP-Idem": "bad idem!"}, {"X-MCAP-Idem": "x" * 65}, {"X-MCAP-Langs": "ko,xx"}):
            with self.subTest(extra=extra):
                self.assertEqual(self.chunk(self.tok, extra=extra).code, "bad_request")
        self.assertEqual(self.chunk(self.tok, lang="ja", extra={"X-MCAP-Langs": "ja,ko,en"}).status, 200)

    def test_body_length_must_match_content_length_in_process(self):
        reply = self.call("POST", "/v1/purge", token=self.tok, body=b"xx", headers={"Content-Length": "0"})
        self.assertEqual(reply.code, "bad_request")

    def test_errors_never_echo_what_the_client_sent(self):
        canary = "CANARY-HEADER-VALUE-91"
        for reply in (self.call("GET", "/v1/" + canary, token=self.tok), self.chunk(self.tok, extra={"X-MCAP-Lang": canary}),
                      self.call("POST", "/v1/purge", headers={"Authorization": "Bearer " + canary})):
            self.assertNotIn(canary.encode(), reply.raw)
            self.assertNotIn(canary, " ".join(reply.headers.values()))


# ======================================================================================================================
class ChunkTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_answer_shape(self):
        reply = self.chunk(self.tok, lang="ko")
        self.assertEqual(reply.status, 200)
        body = reply.json
        self.assertEqual(body["proto"], S.PROTO)
        self.assertEqual((body["op"], body["engine"], body["model"], body["language"]), ("transcribe", "whisper", "fake/whisper-test", "ko"))
        self.assertEqual((body["text"], body["truncated"], body["prompt_text"]), (TEXT_CANARY, False, ""))
        self.assertEqual(body["segments"][0]["end"], 1.0)
        self.assertEqual(set(body["segments"][0]), {"start", "end", "text", "avg_logprob", "no_speech_prob", "compression_ratio", "temperature"})
        self.assertEqual(reply.headers["Content-Type"], "application/json")
        self.assertEqual(reply.headers["Cache-Control"], "no-store")
        self.assertEqual(self.backend.calls[0]["samples"], 16000)

    def test_pcm_is_scaled_like_the_local_reader(self):
        seen = []
        self.backend.on_call = None
        original = self.backend.transcribe_chunk

        def spy(audio, language, prompt):
            seen.append(audio.copy())
            return original(audio, language, prompt)

        self.backend.transcribe_chunk = spy
        samples = np.array([0, 1, -1, 32767, -32768, 16384], dtype="<i2")
        self.chunk(self.tok, n=6, body=samples.tobytes())
        self.assertEqual(seen[0].dtype, np.float32)
        np.testing.assert_allclose(seen[0], samples.astype(np.float32) / 32768.0, rtol=0, atol=0)

    def test_forced_language_skips_language_id_and_auto_uses_it(self):
        self.chunk(self.tok, lang="en")
        self.assertEqual((self.backend.calls[-1]["language"], self.backend.lid_calls), ("en", []))
        self.chunk(self.tok, lang="auto", marker=8, extra={"X-MCAP-Langs": "ja,ko,en"})
        self.assertEqual(self.backend.lid_calls, [(1, ("ja", "ko", "en"))])
        self.assertEqual(self.backend.calls[-1]["language"], "ja")                 # the restricted language ID's top, passed on
        self.backend.supports_lid = False
        self.chunk(self.tok, lang="auto", marker=9)
        self.assertIsNone(self.backend.calls[-1]["language"])                      # the engine decides on its own

    def test_prompt_styles_and_the_vocabulary(self):
        self.assertEqual(self.put_vocab(self.tok, [TERM_CANARY, "PACS"]).status, 204)
        digest = S.canonical_vocab_digest({"terms": [TERM_CANARY, "PACS"]})
        for style, lang, expect in (("frame+list", "ko", "KO-FRAME: PACS, " + TERM_CANARY), ("frame+list", "auto", "KO-FRAME: PACS, " + TERM_CANARY),
                                    ("list", "ko", "PACS, " + TERM_CANARY), ("none", "ko", None)):
            with self.subTest(style=style, lang=lang):
                reply = self.chunk(self.tok, lang=lang, marker=len(self.backend.calls) + 20,
                                   extra={"X-MCAP-Prompt": style, "X-MCAP-Vocab": digest})
                self.assertEqual(self.backend.calls[-1]["prompt"], expect)
                self.assertEqual(reply.json["prompt_text"], expect or "")         # the client's echo guard needs the text that was used
        self.chunk(self.tok, marker=99, extra={"X-MCAP-Prompt": "frame+list"})        # a prompt style without a vocabulary: no prompt
        self.assertIsNone(self.backend.calls[-1]["prompt"])

    def test_engine_without_prompt_gets_the_terms_through_the_hook_instead(self):
        self.backend.uses_prompt = False
        self.put_vocab(self.tok, ["PACS", "DICOM"])
        digest = S.canonical_vocab_digest({"terms": ["PACS", "DICOM"]})
        reply = self.chunk(self.tok, extra={"X-MCAP-Prompt": "frame+list", "X-MCAP-Vocab": digest})
        self.assertIsNone(self.backend.calls[-1]["prompt"])
        self.assertEqual(self.backend.terms_seen[-1], ("PACS", "DICOM"))
        self.assertEqual(reply.json["prompt_text"], "")
        self.chunk(self.tok, marker=2)
        self.assertEqual(self.backend.terms_seen[-1], ())

    def test_the_prompt_retry_is_the_local_decode_chunk(self):
        self.put_vocab(self.tok, ["Acme", "PACS", "DICOM", "FHIR", "RSNA"])
        digest = S.canonical_vocab_digest({"terms": ["Acme", "PACS", "DICOM", "FHIR", "RSNA"]})
        parrot = {"text": "PACS DICOM FHIR RSNA Acme", "language": "ko", "avg_logprob": -0.6, "truncated": False,
                  "segments": [{"start": 0, "end": 2, "text": "PACS DICOM FHIR RSNA Acme", "avg_logprob": -0.6, "no_speech_prob": 0.0,
                                "compression_ratio": 1.0, "temperature": 0.0}]}
        self.backend.script = [parrot]                         # the first answer repeats the prompt: asr.decode_chunk retries without it
        reply = self.chunk(self.tok, lang="ko", extra={"X-MCAP-Prompt": "frame+list", "X-MCAP-Vocab": digest})
        self.assertEqual(len(self.backend.calls), 2)
        self.assertIsNotNone(self.backend.calls[0]["prompt"])
        self.assertIsNone(self.backend.calls[1]["prompt"])
        self.assertEqual(reply.json["segments"][0]["text"], TEXT_CANARY)           # the retry was clearly better and replaced the parrot
        self.assertIn("Acme", reply.json["prompt_text"])

    def test_opaque_backend_has_null_confidence_numbers(self):
        self.backend.confidence = "opaque"
        self.backend.script = [{"text": "t", "language": "ko", "avg_logprob": -0.1, "segments": [
            {"start": 0, "end": 1, "text": "t", "avg_logprob": -0.1, "no_speech_prob": 0.2, "compression_ratio": 1.0, "temperature": 0.0}]}]
        body = self.chunk(self.tok).json
        self.assertIsNone(body["avg_logprob"])
        self.assertEqual([body["segments"][0][k] for k in ("avg_logprob", "no_speech_prob", "compression_ratio")], [None] * 3)

    def test_segments_are_sanitised_not_trusted(self):
        nan, inf = float("nan"), float("inf")
        self.backend.script = [{"text": "x", "language": 7, "avg_logprob": nan, "truncated": 1, "segments": [
            {"start": -3, "end": -5, "text": "kept", "avg_logprob": nan, "no_speech_prob": True, "compression_ratio": inf, "temperature": "hot"},
            {"start": 0, "end": 1, "text": "   "}, {"start": 0, "end": 1, "text": None}, {"start": 1, "end": 2}]}]
        body = self.chunk(self.tok, lang="ko").json
        self.assertEqual(len(body["segments"]), 1)
        seg = body["segments"][0]
        self.assertEqual((seg["start"], seg["end"], seg["text"]), (0.0, 0.0, "kept"))
        self.assertEqual([seg[k] for k in ("avg_logprob", "no_speech_prob", "compression_ratio", "temperature")], [None] * 4)
        self.assertEqual((body["language"], body["avg_logprob"], body["truncated"]), ("ko", None, True))

    def test_engine_failures_are_fixed_errors_and_never_cached(self):
        self.backend.script = [RuntimeError("boom " + TEXT_CANARY)]
        failed = self.chunk(self.tok, extra={"X-MCAP-Idem": "retry-1"})
        self.assertEqual((failed.status, failed.code), (500, "engine_error"))
        self.assertNotIn(TEXT_CANARY.encode(), failed.raw)
        again = self.chunk(self.tok, extra={"X-MCAP-Idem": "retry-1"})                # the same key computes again: failures are not cached
        self.assertEqual(again.status, 200)
        self.assertEqual(len(self.backend.calls), 2)
        self.assertEqual(self.state.quotas.inflight[self.tok.split("_")[1]], 0)
        self.backend.script = [ValueError("bad audio"), TimeoutError()]
        self.assertEqual(self.chunk(self.tok, marker=3).code, "unprocessable_audio")
        self.assertEqual(self.chunk(self.tok, marker=4).code, "engine_timeout")

    def test_an_answer_over_the_client_limit_is_an_error_not_a_cut_text(self):
        self.backend.script = [{"text": "x" * 300_000, "language": "ko", "segments": []}]
        self.assertEqual(self.chunk(self.tok).code, "engine_error")

    def test_a_request_that_waits_longer_than_the_deadline_gets_504(self):
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        self.state.request_deadline_s = 0.3
        started = time.monotonic()
        reply = self.chunk(self.tok)
        self.assertEqual((reply.status, reply.code), (504, "engine_timeout"))
        self.assertLess(time.monotonic() - started, 5)

    def test_queued_work_nobody_waits_for_is_dropped(self):
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        first = self.spawn(self.chunk, self.tok, marker=1)
        self.assertTrue(self.backend.entered.acquire(timeout=10))
        self.state.request_deadline_s = 0.2
        second = self.chunk(self.tok, marker=2)                                      # queued behind the first, gives up
        self.assertEqual(second.code, "engine_timeout")
        gate.set()
        self.wait_for(lambda: "r" in first)
        self.wait_for(lambda: self.state.queue.depth() == 0, "an empty queue")
        self.assertEqual([c["marker"] for c in self.backend.calls], [1])             # the abandoned job never ran
        self.assertEqual(self.state.quotas.inflight[self.tok.split("_")[1]], 0)


class LidTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_batch_answer(self):
        reply = self.lid(self.tok, [16000, 32000, 96000], langs="ko,en")
        self.assertEqual(reply.status, 200)
        body = reply.json
        self.assertEqual((body["proto"], body["op"], len(body["results"])), (S.PROTO, "lid", 3))
        self.assertEqual(body["results"][0], {"ko": 0.9, "en": 0.1, "top": "ko"})
        self.assertEqual(self.backend.lid_calls, [(3, ("ko", "en"))])

    def test_limits(self):
        self.assertEqual(self.lid(self.tok, [16000] * 12).status, 200)
        self.assertEqual(self.lid(self.tok, [16000] * 13).code, "payload_too_large")
        self.assertEqual(self.lid(self.tok, [96001]).code, "payload_too_large")
        self.assertEqual(self.lid(self.tok, [16000, 16000], body=pcm(16000)).code, "bad_request")
        for header in ("", "a,b", "0", "-5", "1,,2", "1.5"):
            self.assertEqual(self.call("POST", "/v1/lid", token=self.tok, body=pcm(100), headers={
                "Content-Type": "application/octet-stream", "X-MCAP-Clips": header}).status, 400, header)

    def test_backend_without_language_id_is_400(self):
        self.backend.supports_lid = False
        self.assertEqual(self.lid(self.tok, [16000]).code, "bad_request")

    def test_clip_seconds_count_against_the_audio_quota(self):
        state = self.make_state(per_token_audio_s_per_day=5)
        tok = self.token("sam", state=state)
        self.assertEqual(self.lid(tok, [48000], state=state).status, 200)             # 3 s
        self.assertEqual(self.lid(tok, [48000], state=state).code, "quota_exceeded")  # 3 s more is over 5 s


# ======================================================================================================================
class QuotaTests(ServerCase):
    def test_concurrency_limit_is_two_requests_in_flight(self):
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        tok = self.token()
        tid = tok.split("_")[1]
        first = self.spawn(self.chunk, tok, marker=1)
        second = self.spawn(self.chunk, tok, marker=2)
        self.wait_for(lambda: self.state.quotas.inflight[tid] == 2, "two requests in flight")
        third = self.chunk(tok, marker=3)
        self.assertEqual((third.status, third.code), (429, "quota_exceeded"))
        self.assertEqual(third.headers["Retry-After"], "1")
        self.assertEqual(third.json["error"]["retry_after_s"], 1)
        other = self.token("sam")
        self.assertEqual(self.spawn(self.chunk, other, marker=4) is not None, True)       # another token has its own two
        gate.set()
        self.wait_for(lambda: "r" in first and "r" in second, "both answers")
        self.assertEqual(self.chunk(tok, marker=5).status, 200)

    def test_requests_per_minute(self):
        state = self.make_state(per_token_rpm=3)
        tok = self.token(state=state)
        for i in range(3):
            self.assertEqual(self.chunk(tok, n=1600, marker=i + 1, state=state).status, 200)
            self.clock.advance(1)
        blocked = self.chunk(tok, n=1600, marker=9, state=state)
        self.assertEqual((blocked.status, blocked.code), (429, "quota_exceeded"))
        self.assertEqual(blocked.json["error"]["retry_after_s"], 57)                  # the first of the three leaves the window in 57 s
        self.clock.advance(57)
        self.assertEqual(self.chunk(tok, n=1600, marker=10, state=state).status, 200)

    def test_rejected_requests_do_not_use_the_minute(self):
        state = self.make_state(per_token_rpm=2)
        tok = self.token(state=state)
        self.assertEqual(self.call("POST", "/v1/chunk", token=tok, body=b"", headers={"Content-Type": "x"}, state=state).status, 415)
        for i in range(2):
            self.assertEqual(self.chunk(tok, n=800, marker=i + 1, state=state).status, 200)

    def test_audio_seconds_per_day(self):
        state = self.make_state(per_token_audio_s_per_day=3)
        tok = self.token(state=state)
        for i in range(3):
            self.assertEqual(self.chunk(tok, marker=i + 1, state=state).status, 200)
        blocked = self.chunk(tok, marker=9, state=state)
        self.assertEqual((blocked.status, blocked.code), (429, "quota_exceeded"))
        self.assertEqual(blocked.json["error"]["retry_after_s"], 14 * 3600)           # until local midnight (it is 10:00)
        self.assertEqual(self.chunk(self.token("sam", state=state), state=state).status, 200)   # the quota is per token
        self.clock.advance(15 * 3600)                                                 # tomorrow
        self.assertEqual(self.chunk(tok, marker=10, state=state).status, 200)

    def test_counters_are_restored_from_the_metadata_log(self):
        state = self.make_state(per_token_audio_s_per_day=2, per_token_rpm=2)
        tok = self.token(state=state)
        self.chunk(tok, marker=1, state=state)
        self.chunk(tok, marker=2, state=state)
        state.close()
        self.clock.advance(5)
        restarted = self.make_state(per_token_audio_s_per_day=2, per_token_rpm=2)     # a new process on the same directories
        self.assertEqual(self.chunk(tok, marker=3, state=restarted).code, "quota_exceeded")
        self.assertAlmostEqual(restarted.quotas.used[tok.split("_")[1]], 2.0)
        self.assertEqual(len(restarted.quotas.recent[tok.split("_")[1]]), 2)
        generous = self.make_state(per_token_audio_s_per_day=10, per_token_rpm=2)
        self.assertEqual(self.chunk(tok, marker=4, state=generous).code, "quota_exceeded")      # the minute was restored too

    def test_replays_do_not_charge_and_rejections_cost_nothing(self):
        state = self.make_state(per_token_audio_s_per_day=1)
        tok = self.token(state=state)
        self.assertEqual(self.chunk(tok, state=state, extra={"X-MCAP-Idem": "k1"}).status, 200)
        self.assertEqual(self.chunk(tok, state=state, extra={"X-MCAP-Idem": "k1"}).status, 200)       # the cache answers: free
        self.assertEqual(self.chunk(tok, marker=2, state=state).code, "quota_exceeded")
        self.assertAlmostEqual(state.quotas.used[tok.split("_")[1]], 1.0)


class QueueTests(ServerCase):
    def test_fair_queue_serves_the_tokens_in_turn(self):
        queue = S.FairQueue(threading.RLock())

        def job(token, n):
            return S.Job("transcribe", token, b"", {"n": f"{token}{n}"}, 1.0, 0.0)

        for item in (job("A", 1), job("A", 2), job("A", 3), job("B", 1), job("C", 1), job("C", 2)):
            queue.put(item)
        order = []
        while queue.queued():
            order.append(queue.take().params["n"])
            queue.finish()
        self.assertEqual(order, ["A1", "B1", "C1", "A2", "C2", "A3"])
        self.assertEqual(queue.depth(), 0)

    def test_fair_queue_close_returns_the_waiting_jobs(self):
        queue = S.FairQueue(threading.RLock())
        queue.put(S.Job("transcribe", "A", b"", {}, 1.0, 0.0))
        self.assertEqual(len(queue.close()), 1)
        self.assertIsNone(queue.take())

    def test_the_engine_worker_follows_the_round_robin(self):
        state = self.make_state(per_token_concurrency=8)
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        toks = {name: self.token(name, state=state) for name in "ABC"}
        order = [("A", 1), ("A", 2), ("A", 3), ("B", 4), ("C", 5), ("C", 6)]
        boxes = []
        for index, (name, marker) in enumerate(order):
            boxes.append(self.spawn(self.chunk, toks[name], marker=marker, state=state))
            if index == 0:
                self.assertTrue(self.backend.entered.acquire(timeout=10))             # A1 is on the engine
            else:
                self.wait_for(lambda i=index: state.queue.queued() == i, f"{index} queued")
        gate.set()
        self.wait_for(lambda: all("r" in b for b in boxes), "all answers")
        self.assertEqual([c["marker"] for c in self.backend.calls], [1, 2, 4, 5, 3, 6])      # A1, then A2 B1 C1 A3 C2

    def test_503_at_once_when_the_predicted_wait_is_over_max_wait(self):
        state = self.make_state(initial_service_s=10.0, per_token_concurrency=4)
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        toks = [self.token(f"u{i}", state=state) for i in range(6)]
        boxes = []
        for index in range(5):
            boxes.append(self.spawn(self.chunk, toks[index], marker=index + 1, state=state))
            self.wait_for(lambda i=index: state.queue.depth() == i + 1, f"depth {index + 1}")
        started = time.monotonic()
        busy = self.chunk(toks[5], marker=9, state=state)                              # ahead = 5 x 10 s = 50 s > 45 s
        self.assertLess(time.monotonic() - started, 2)                                  # answered at once: the connection is not held
        self.assertEqual((busy.status, busy.code), (503, "busy"))
        self.assertEqual(busy.headers["Retry-After"], "50")
        self.assertEqual(busy.json["error"]["retry_after_s"], 50)
        self.assertEqual(state.quotas.inflight[toks[5].split("_")[1]], 0)              # nothing was reserved
        gate.set()
        self.wait_for(lambda: all("r" in b for b in boxes))
        self.assertEqual(self.chunk(toks[5], marker=10, state=state).status, 200)

    def test_503_when_the_queue_is_full(self):
        state = self.make_state(max_queue=2, initial_service_s=0.1, per_token_concurrency=8)
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        tok = self.token(state=state)
        boxes = [self.spawn(self.chunk, tok, marker=1, state=state)]
        self.assertTrue(self.backend.entered.acquire(timeout=10))
        for index in (2, 3):
            boxes.append(self.spawn(self.chunk, tok, marker=index, state=state))
            self.wait_for(lambda i=index: state.queue.queued() == i - 1)
        self.assertEqual(self.chunk(tok, marker=4, state=state).code, "busy")
        gate.set()
        self.wait_for(lambda: all("r" in b for b in boxes))

    def test_service_time_average_follows_the_engine(self):
        state = self.make_state(initial_service_s=4.0)
        self.backend.on_call = lambda: self.clock.advance(14.0)
        tok = self.token(state=state)
        self.chunk(tok, state=state)
        self.assertAlmostEqual(state.avg_service_s, 0.8 * 4.0 + 0.2 * 14.0)
        health = self.call("GET", "/v1/health?detail=1", token=tok, state=state).json
        self.assertEqual(health["queue"], {"depth": 0, "avg_service_s": 6.0})


# ======================================================================================================================
class IdempotencyTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_a_retry_with_the_same_key_and_body_is_answered_from_memory(self):
        first = self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        second = self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual((first.status, second.status, first.raw), (200, 200, second.raw))
        self.assertEqual(len(self.backend.calls), 1)
        recs = [r for r in self.records() if r["op"] == "transcribe"]
        self.assertEqual([r["audio_s"] for r in recs], [1.0, 0.0])                 # a replay is not charged and says so in the log

    def test_the_key_is_bound_to_the_token_and_to_the_body(self):
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        other = self.token("sam")
        self.chunk(other, extra={"X-MCAP-Idem": "k1"})                              # same text, another token: computed
        self.assertEqual(len(self.backend.calls), 2)
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k2"})                           # same body, another key: computed
        self.assertEqual(len(self.backend.calls), 3)
        self.chunk(self.tok)                                                        # no key: never cached
        self.chunk(self.tok)
        self.assertEqual(len(self.backend.calls), 5)

    def test_409_for_the_same_key_with_another_body(self):
        self.chunk(self.tok, marker=1, extra={"X-MCAP-Idem": "k1"})
        reply = self.chunk(self.tok, marker=2, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual((reply.status, reply.code), (409, "idem_conflict"))
        self.assertEqual(len(self.backend.calls), 1)
        self.assertEqual(self.chunk(self.tok, marker=1, extra={"X-MCAP-Idem": "k1"}).status, 200)

    def test_the_cache_lives_120_seconds(self):
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        self.clock.advance(119)
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual(len(self.backend.calls), 1)
        self.clock.advance(2)
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual(len(self.backend.calls), 2)

    def test_a_running_request_is_merged_with_its_retry(self):
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        first = self.spawn(self.chunk, self.tok, extra={"X-MCAP-Idem": "k1"})
        self.assertTrue(self.backend.entered.acquire(timeout=10))
        second = self.spawn(self.chunk, self.tok, extra={"X-MCAP-Idem": "k1"})
        self.wait_for(lambda: self.state._idem[self.tok.split("_")[1]]["k1"].job.waiters == 2, "the retry attached")
        conflict = self.chunk(self.tok, marker=5, extra={"X-MCAP-Idem": "k1"})       # a different body while it runs: 409 too
        self.assertEqual(conflict.code, "idem_conflict")
        gate.set()
        self.wait_for(lambda: "r" in first and "r" in second, "both answers")
        self.assertEqual((first["r"].status, second["r"].status, first["r"].raw), (200, 200, second["r"].raw))
        self.assertEqual(len(self.backend.calls), 1)
        self.assertAlmostEqual(self.state.quotas.used[self.tok.split("_")[1]], 1.0)  # charged once
        self.assertEqual(self.state.quotas.inflight[self.tok.split("_")[1]], 0)

    def test_the_cache_is_bounded_per_token(self):
        with mock.patch.object(S, "IDEM_PER_TOKEN", 3):
            for i in range(5):
                self.chunk(self.tok, marker=i + 1, extra={"X-MCAP-Idem": f"k{i}"})
            self.assertEqual(len(self.backend.calls), 5)
            self.chunk(self.tok, marker=5, extra={"X-MCAP-Idem": "k4"})                  # the newest is still there
            self.assertEqual(len(self.backend.calls), 5)
            self.chunk(self.tok, marker=1, extra={"X-MCAP-Idem": "k0"})                  # the oldest was dropped
            self.assertEqual(len(self.backend.calls), 6)

    def test_purge_empties_the_cache_and_the_vocabularies(self):
        self.put_vocab(self.tok, ["PACS"])
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        reply = self.call("POST", "/v1/purge", token=self.tok)
        self.assertEqual((reply.status, reply.json), (200, {"purged": 2}))
        self.chunk(self.tok, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual(len(self.backend.calls), 2)
        digest = S.canonical_vocab_digest({"terms": ["PACS"]})
        self.assertEqual(self.chunk(self.tok, extra={"X-MCAP-Vocab": digest, "X-MCAP-Prompt": "list"}).code, "vocab_unknown")
        other = self.token("sam")
        self.chunk(other, extra={"X-MCAP-Idem": "k1"})
        self.call("POST", "/v1/purge", token=self.tok)                                  # purge is per calling token
        self.chunk(other, extra={"X-MCAP-Idem": "k1"})
        self.assertEqual(len(self.backend.calls), 3)                                    # the other token's cache entry is still there


class CacheLifetimeTests(ServerCase):
    def test_a_quiet_token_does_not_keep_its_answers_past_120_seconds(self):
        quiet, busy = self.token("quiet"), self.token("busy")
        self.chunk(quiet, extra={"X-MCAP-Idem": "k1"})
        self.clock.advance(100)
        self.chunk(busy, extra={"X-MCAP-Idem": "k2"})
        self.assertEqual(self.state.sweep(), 0)
        self.clock.advance(30)                                           # 'quiet' is 130 s old, 'busy' 30 s
        self.assertEqual(self.state.sweep(), 1)
        self.assertEqual(list(self.state._idem), [busy.split("_")[1]])
        self.clock.advance(100)
        self.assertEqual(self.state.sweep(), 1)
        self.assertEqual(self.state._idem, {})                            # nothing of the transcript text is left in memory

    def test_a_request_of_another_token_sweeps_too(self):
        quiet, busy = self.token("quiet"), self.token("busy")
        self.chunk(quiet, extra={"X-MCAP-Idem": "k1"})
        self.clock.advance(200)
        self.chunk(busy, marker=2)
        self.assertNotIn(quiet.split("_")[1], {k for k, v in self.state._idem.items() if v})

    def test_the_background_sweeper_runs_and_stops_with_the_server(self):
        state = self.make_state()
        self.assertTrue(state._sweeper.is_alive())
        tok = self.token("alice", state=state)
        self.chunk(tok, state=state, extra={"X-MCAP-Idem": "k1"})
        self.assertTrue(state._idem)
        state.close()
        self.assertFalse(state._sweeper.is_alive())
        self.assertFalse(state._worker.is_alive())
        self.assertEqual((state._idem, state._vocab), ({}, {}))           # closing empties the caches too
        self.assertEqual(self.backend.released, 1 if self.backend is not None else 0)

    def test_unfinished_work_is_answered_busy_when_the_server_closes(self):
        state = self.make_state(per_token_concurrency=8)
        gate = threading.Event()
        self.backend.gate = gate
        tok = self.token("alice", state=state)
        first = self.spawn(self.chunk, tok, marker=1, state=state)
        self.assertTrue(self.backend.entered.acquire(timeout=10))
        second = self.spawn(self.chunk, tok, marker=2, state=state)
        self.wait_for(lambda: state.queue.queued() == 1)
        closer = threading.Thread(target=state.close, daemon=True)
        closer.start()
        self.wait_for(lambda: "r" in second, "the queued request to be answered")
        self.assertEqual((second["r"].status, second["r"].code), (503, "busy"))
        gate.set()
        closer.join(15)
        self.wait_for(lambda: "r" in first)
        self.assertEqual(first["r"].status, 200)


class HardeningTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_odd_request_targets_are_400(self):
        for path in ("//evil.test/v1/health", "/v1/health#x", "/v1/héalth", "v1/health", "/" + "a" * 3000):
            with self.subTest(path=path[:30]):
                self.assertEqual(self.call("GET", path).status, 400)
        self.assertEqual(self.call("GET", "/v1/%63hunk", token=self.tok).code, "not_found")          # nothing is percent-decoded

    def test_authentication_failures_are_counted_in_one_line_a_minute(self):
        with self.assertLogs("mcap.asr_server", "WARNING") as logged:
            for _ in range(5):
                self.call("POST", "/v1/purge", headers={"Authorization": "Bearer nope"})
            self.clock.advance(61)
            self.call("POST", "/v1/purge", headers={"Authorization": "Bearer " + "mcap1_00000000_" + "A" * 32})
        self.assertEqual(len(logged.records), 2)                              # the first failure is reported, then one line a minute
        self.assertIn("1 time(s)", logged.output[0])
        self.assertIn("5 time(s)", logged.output[1])                           # the four in between and the one after the minute
        self.assertNotIn("nope", " ".join(logged.output))

    def test_a_backend_that_cannot_start_refuses_the_start_with_a_reason(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}))

        class Broken(FakeBackend):
            def load(self):
                raise asr_engines.ModelNotAvailable("ASR model x is not available locally and downloads are disabled")

        with mock.patch.object(S, "harden_process"), mock.patch.object(S, "core_dumps_disabled", return_value=True):
            with self.assertRaises(S.StartupRefused) as raised:
                S.serve(config, backend_factory=lambda cfg: Broken())
        self.assertEqual(raised.exception.checks[0].name, "backend")
        self.assertIn("ModelNotAvailable", raised.exception.checks[0].detail)


class VocabularyTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_digest_vectors_of_the_protocol(self):
        self.assertEqual(S.canonical_vocab_digest({"terms": ["Acme", "AcmeScan-CXR"]}),
                         "87ed861a28a3224008a330d64606c77606bc4c71f41b3c7d92a359ac0bb69070")
        self.assertEqual(S.canonical_vocab_digest({"terms": ["액미", "PACS"]}),
                         "5be960d3f9c4edcc23a746cdae69aad23fec5bd27566ea6635b52606bd95d012")

    def test_put_checks_the_digest_of_the_canonical_form(self):
        reply = self.put_vocab(self.tok, ["Acme", "AcmeScan-CXR"])
        self.assertEqual((reply.status, reply.raw), (204, b""))
        self.assertNotIn("Content-Length", reply.headers)
        wrong = self.call("PUT", "/v1/vocab/" + "0" * 64, token=self.tok, body=S._dumps({"terms": ["a"]}))
        self.assertEqual((wrong.status, wrong.code), (400, "bad_request"))
        pretty = json.dumps({"terms": ["Acme", "AcmeScan-CXR"]}, indent=2).encode()          # not the canonical bytes, same object: accepted
        ok = self.call("PUT", "/v1/vocab/87ed861a28a3224008a330d64606c77606bc4c71f41b3c7d92a359ac0bb69070", token=self.tok, body=pretty)
        self.assertEqual(ok.status, 204)

    def test_put_rejects_bad_bodies(self):
        for obj in ({"terms": "x"}, {"terms": [1]}, {"terms": ["a"], "extra": 1}, {"terms": [""]}, {"terms": ["a\x00b"]}, {"terms": ["x" * 201]},
                    {"nope": []}, ["terms"]):
            body = json.dumps(obj, ensure_ascii=False).encode()
            digest = S.canonical_vocab_digest(obj)
            with self.subTest(obj=str(obj)[:30]):
                self.assertEqual(self.call("PUT", "/v1/vocab/" + digest, token=self.tok, body=body).status, 400)
        self.assertEqual(self.call("PUT", "/v1/vocab/" + "a" * 64, token=self.tok, body=b"not json").status, 400)
        self.assertEqual(self.call("PUT", "/v1/vocab/" + "a" * 64, token=self.tok, body=b'{"terms": NaN}').status, 400)
        self.assertEqual(self.call("PUT", "/v1/vocab/" + "a" * 64, token=self.tok, body=b'{"terms": ["\\ud800"]}').status, 400)
        too_big = b'{"terms":["' + b"x" * 70000 + b'"]}'
        self.assertEqual(self.call("PUT", "/v1/vocab/" + "a" * 64, token=self.tok, body=too_big).code, "payload_too_large")

    def test_unknown_vocabulary_is_404_then_put_then_retry(self):
        digest = S.canonical_vocab_digest({"terms": [TERM_CANARY]})
        headers = {"X-MCAP-Vocab": digest, "X-MCAP-Prompt": "list"}
        miss = self.chunk(self.tok, extra=headers)
        self.assertEqual((miss.status, miss.code), (404, "vocab_unknown"))
        self.assertEqual(self.backend.calls, [])                                        # nothing was computed or charged
        self.assertEqual(self.state.quotas.used[self.tok.split("_")[1]], 0)
        self.assertEqual(self.put_vocab(self.tok, [TERM_CANARY]).status, 204)
        hit = self.chunk(self.tok, extra=headers)
        self.assertEqual(hit.status, 200)
        self.assertEqual(self.backend.calls[0]["prompt"], TERM_CANARY)

    def test_vocabulary_belongs_to_its_token_and_is_a_small_lru(self):
        self.put_vocab(self.tok, ["PACS"])
        digest = S.canonical_vocab_digest({"terms": ["PACS"]})
        other = self.token("sam")
        self.assertEqual(self.chunk(other, extra={"X-MCAP-Vocab": digest, "X-MCAP-Prompt": "list"}).code, "vocab_unknown")
        for i in range(S.VOCAB_PER_TOKEN):                                              # 16 more push the first one out
            self.put_vocab(self.tok, [f"term{i}"])
        self.assertEqual(self.chunk(self.tok, extra={"X-MCAP-Vocab": digest, "X-MCAP-Prompt": "list"}).code, "vocab_unknown")
        newest = S.canonical_vocab_digest({"terms": [f"term{S.VOCAB_PER_TOKEN - 1}"]})
        self.assertEqual(self.chunk(self.tok, extra={"X-MCAP-Vocab": newest, "X-MCAP-Prompt": "list"}).status, 200)

    def test_vocabulary_is_in_memory_only(self):
        self.put_vocab(self.tok, [TERM_CANARY])
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(TERM_CANARY.encode(), path.read_bytes(), str(path))


# ======================================================================================================================
class EnrollTests(ServerCase):
    def enroll(self, code, machine=None, **kw):
        body = {"code": code}
        if machine:
            body["machine"] = machine
        return self.call("POST", "/v1/enroll", body=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, **kw)

    def new_code(self, user="alice"):
        return self.state.codes.issue(user, self.clock.t, self.state.cfg.enroll_code_ttl_s)

    def test_a_code_is_exchanged_once_for_a_working_token(self):
        code = self.new_code("alice.kim")
        reply = self.enroll(code, machine="c" * 16)
        self.assertEqual(reply.status, 200)
        body = reply.json
        self.assertEqual(set(body), {"token", "expires", "user"})
        self.assertEqual(body["user"], "alice.kim")
        self.assertRegex(body["token"], r"^mcap1_[0-9a-f]{8}_[A-Za-z0-9_-]{32}$")
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=body["token"]).json["token"]["expires_in_days"], 90)
        again = self.enroll(code)
        self.assertEqual((again.status, again.code), (401, "enroll_invalid"))
        stored = next(iter(self.state.tokens.rows().values()))
        self.assertEqual((stored.issuer, stored.machine), ("enroll", "c" * 16))

    def test_codes_are_typed_by_people(self):
        code = self.new_code()
        self.assertRegex(code, r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")
        self.assertEqual(self.enroll(code.lower().replace("-", " ")).status, 200)

    def test_ten_minute_expiry(self):
        code = self.new_code()
        self.assertEqual(self.enroll(code, now=self.clock.t + 601).code, "enroll_invalid")
        fresh = self.new_code()
        self.assertEqual(self.enroll(fresh, now=self.clock.t + 599).status, 200)

    def test_wrong_used_and_expired_codes_get_the_same_answer(self):
        used = self.new_code()
        self.enroll(used)
        expired = self.new_code()
        answers = {self.enroll("AAAA-AAAA-AAAA").raw, self.enroll(used).raw, self.enroll(expired, now=self.clock.t + 700).raw,
                   self.enroll("").raw, self.enroll("x" * 100).raw}
        self.assertEqual(len(answers), 1)

    def test_throttling_per_source_and_globally(self):
        good = self.new_code()
        for _ in range(S.ENROLL_FAILS_PER_SOURCE):
            self.assertEqual(self.enroll("BBBB-BBBB-BBBB", peer="203.0.113.5").code, "enroll_invalid")
        blocked = self.enroll(good, peer="203.0.113.5")                                  # even the right code waits now
        self.assertEqual((blocked.status, blocked.code), (429, "enroll_throttled"))
        self.assertEqual(blocked.headers["Retry-After"], "600")
        self.assertEqual(self.enroll(good, peer="198.51.100.5").status, 200)              # another network is not blocked
        self.assertEqual(self.enroll(self.new_code(), peer="203.0.113.9").code, "enroll_throttled")     # same /24
        fresh = self.state.codes.issue("alice", self.clock.t + 601, 600)
        self.assertEqual(self.enroll(fresh, peer="203.0.113.5", now=self.clock.t + 601).status, 200)

    def test_global_failure_cap(self):
        for i in range(S.ENROLL_FAILS_GLOBAL):
            self.enroll("CCCC-CCCC-CCCC", peer=f"10.{i}.0.1")
        self.assertEqual(self.enroll(self.new_code(), peer="192.0.2.1").code, "enroll_throttled")

    def test_enroll_needs_no_token_and_checks_its_body(self):
        self.assertEqual(self.call("POST", "/v1/enroll", body=b"nope").code, "bad_request")
        self.assertEqual(self.call("POST", "/v1/enroll", body=b"[]").code, "bad_request")
        self.assertEqual(self.call("POST", "/v1/enroll", body=b"x" * 2000).code, "payload_too_large")
        self.assertEqual(self.enroll(self.new_code(), machine="zz").code, "bad_request")
        self.assertEqual(self.call("POST", "/v1/enroll", body=b'{"code": 5}').code, "enroll_invalid")

    def test_nothing_in_the_files_is_a_plaintext_code_or_token(self):
        code = self.new_code("alice")
        token = self.enroll(code).json["token"]
        raw = code.replace("-", "")
        for path in (self.state.cfg.codes_path, self.state.cfg.tokens_path):
            text = Path(path).read_text(encoding="utf-8")
            self.assertNotIn(raw, text)
            self.assertNotIn(code, text)
            self.assertNotIn(token.split("_", 2)[2], text)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(json.loads(Path(self.state.cfg.codes_path).read_text())["codes"], [])         # single use: the row is gone

    def test_attempts_are_logged_without_the_code(self):
        code = self.new_code("alice")
        self.enroll("AAAA-AAAA-AAAA", peer="203.0.113.5")
        self.enroll(code, peer="203.0.113.5")
        recs = [r for r in self.records() if r["op"] == "enroll"]
        self.assertEqual([(r["status"], r["user"]) for r in recs], [(401, None), (200, "alice")])
        self.assertEqual(recs[1]["src_net"], "203.0.113.0/24")
        self.assertRegex(recs[1]["token_id"], r"^[0-9a-f]{8}$")
        self.assertNotIn(code.replace("-", ""), json.dumps(recs))


class LifetimeSettingTests(ServerCase):
    def test_token_and_code_lifetimes_and_log_retention_follow_the_config(self):
        state = self.make_state(token_ttl_days=7, enroll_code_ttl_s=60, metadata_log_days=10)
        code = state.codes.issue("alice", self.clock.t, state.cfg.enroll_code_ttl_s)
        body = json.dumps({"code": code}).encode()
        late = Reply(S.handle_request(state, "POST", "/v1/enroll", {"X-MCAP-Proto": S.PROTO, "Content-Length": str(len(body))}, body,
                                      self.clock.t + 61))
        self.assertEqual(late.code, "enroll_invalid")                                  # 60 s, not 600
        code = state.codes.issue("alice", self.clock.t, 60)
        reply = Reply(S.handle_request(state, "POST", "/v1/enroll", {"X-MCAP-Proto": S.PROTO, "Content-Length": str(len(json.dumps({"code": code})))},
                                       json.dumps({"code": code}).encode(), self.clock.t + 59))
        token = reply.json["token"]
        health = self.call("GET", "/v1/health?detail=1", token=token, state=state, now=self.clock.t + 59).json
        self.assertEqual(health["token"]["expires_in_days"], 7)                        # 7 days from the exchange, not 90
        renewed = self.call("POST", "/v1/token/renew", token=token, state=state, now=self.clock.t + 60).json["token"]
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=renewed, state=state, now=self.clock.t + 60).json["token"]["expires_in_days"], 7)
        old = S._day(self.clock.t - 11 * 86400)
        (self.logs / f"meta-{old}.jsonl").write_text("")
        self.assertEqual(state.metalog.prune(self.clock.t), 1)                         # 10 days, not 400


class RenewTests(ServerCase):
    def test_renewal_keeps_the_old_token_for_24_hours(self):
        old = self.token("alice", ttl_days=80)
        self.clock.advance(70 * 86400)                                                   # 10 days left: the client renews at run start
        reply = self.call("POST", "/v1/token/renew", token=old)
        self.assertEqual(reply.status, 200)
        new = reply.json["token"]
        self.assertEqual(set(reply.json), {"token", "expires"})
        self.assertNotEqual(new, old)
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=new).json["token"]["expires_in_days"], 90)
        self.assertEqual(self.call("POST", "/v1/purge", token=old, now=self.clock.t + 23 * 3600 + 3000).status, 200)    # inside 24 h
        stale = self.call("POST", "/v1/purge", token=old, now=self.clock.t + 24 * 3600 + 1)
        self.assertEqual((stale.status, stale.code), (401, "unauthorized"))
        self.assertEqual(self.call("POST", "/v1/purge", token=new, now=self.clock.t + 24 * 3600 + 1).status, 200)
        rows = {r.id: r for r in self.state.tokens.rows().values()}
        old_row, new_row = rows[old.split("_")[1]], rows[new.split("_")[1]]
        self.assertEqual((old_row.superseded_by, new_row.user, new_row.issuer), (new_row.id, "alice", "renew"))

    def test_a_second_renewal_never_extends_the_old_token(self):
        old = self.token("alice", ttl_days=10)
        self.assertEqual(self.call("POST", "/v1/token/renew", token=old).status, 200)
        first_limit = self.state.tokens.rows()[old.split("_")[1]].expires
        self.clock.advance(3600)
        again = self.call("POST", "/v1/token/renew", token=old)                          # the old token is superseded: it renews nothing more
        self.assertEqual((again.status, again.code), (401, "unauthorized"))
        self.assertEqual(self.state.tokens.rows()[old.split("_")[1]].expires, first_limit)

    def test_revoking_the_user_ends_the_whole_chain(self):
        old = self.token("alice", ttl_days=10)
        new = self.call("POST", "/v1/token/renew", token=old).json["token"]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(S.main(["--config", self._config_file(), "token", "revoke", "--user", "ALICE"]), 0)
        self.assertEqual(self.call("POST", "/v1/purge", token=old).code, "unauthorized")
        self.assertEqual(self.call("POST", "/v1/purge", token=new).code, "unauthorized")

    def _config_file(self):
        path = self.root / "asr-server.json"
        path.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}), encoding="utf-8")
        return str(path)


class RenewRulesTests(ServerCase):
    """A renewal is only for a token that has 14 days or less left and has not been renewed yet. Without that one token holder could
    append a row per request until the token table is full (and nobody, the admin tools included, could use it any more)."""

    def table_bytes(self):
        return os.stat(self.state.cfg.tokens_path).st_size

    def test_a_token_with_more_than_14_days_left_cannot_renew(self):
        tok = self.token("alice")                                                          # 90 days left
        self.call("POST", "/v1/purge", token=tok)                                        # (the first request writes the last-use time)
        before = self.table_bytes()
        reply = self.call("POST", "/v1/token/renew", token=tok)
        self.assertEqual((reply.status, reply.code), (429, "quota_exceeded"))
        self.assertEqual(int(reply.headers["Retry-After"]), (90 - 15) * 86400 + 1)       # when expires_in_days reaches 14: the window opens
        self.assertEqual(self.table_bytes(), before)                                     # not a byte was added
        self.assertEqual(len(self.state.tokens.rows()), 1)

    def test_the_window_is_the_one_the_client_sees_in_health(self):
        # The client renews when health says expires_in_days <= 14 (whole days, rounded down), so the server opens at exactly that moment:
        # not a day later (a client that was told 14 would be refused for up to a day), not earlier.
        tok = self.token("alice", ttl_days=16)
        self.clock.advance(86400)                                                        # exactly 15 days left: health says 15
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=tok).json["token"]["expires_in_days"], 15)
        again = self.call("POST", "/v1/token/renew", token=tok)
        self.assertEqual((again.status, again.code, again.headers["Retry-After"]), (429, "quota_exceeded", "1"))
        self.clock.advance(1)                                                            # 14 days 23 h 59 min 59 s left: health says 14
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=tok).json["token"]["expires_in_days"], 14)
        self.assertEqual(self.call("POST", "/v1/token/renew", token=tok).status, 200)

    def test_renewal_is_allowed_exactly_when_health_says_14_or_less(self):
        for hours in (400, 361, 360, 359, 340, 336, 100, 24, 2):                         # hours left on a token
            with self.subTest(hours_left=hours):
                tok = self.token(f"user{hours}", ttl_days=1000)
                self.state.tokens.update(lambda rows, h=hours, t=tok: (None, [r.update({"expires": S._iso(self.clock.t + h * 3600)}) for r in rows if r["id"] == t.split("_")[1]] and True))
                days = self.call("GET", "/v1/health?detail=1", token=tok).json["token"]["expires_in_days"]
                status = self.call("POST", "/v1/token/renew", token=tok).status
                self.assertEqual(status == 200, days <= 14, f"{hours} h left: health says {days} days, renew answered {status}")

    def test_hundreds_of_renewals_add_one_row_at_most(self):
        old = self.token("alice", ttl_days=10)
        statuses = []
        for _ in range(400):
            statuses.append(self.call("POST", "/v1/token/renew", token=old).status)
        self.assertEqual(statuses.count(200), 1)                                         # the first one; the old token is superseded after it
        self.assertEqual(set(statuses) - {200}, {401})
        self.assertEqual(len(self.state.tokens.rows()), 2)
        new = next(r for r in self.state.tokens.rows().values() if r.issuer == "renew")
        self.assertEqual(self.state.tokens.rows()[old.split("_")[1]].superseded_by, new.id)

    def test_the_new_token_cannot_renew_again_until_its_own_window(self):
        old = self.token("alice", ttl_days=10)
        new = self.call("POST", "/v1/token/renew", token=old).json["token"]
        size = self.table_bytes()
        for _ in range(50):
            self.assertEqual(self.call("POST", "/v1/token/renew", token=new).code, "quota_exceeded")
        self.assertEqual(self.table_bytes(), size)
        self.clock.advance(76 * 86400)                                                   # 14 days left on the new one
        self.assertEqual(self.call("POST", "/v1/token/renew", token=new).status, 200)

    def test_a_superseded_token_is_refused_inside_its_24_hour_overlap_too(self):
        old = self.token("alice", ttl_days=10)
        self.assertEqual(self.call("POST", "/v1/token/renew", token=old).status, 200)
        self.clock.advance(3600)
        self.assertEqual(self.call("POST", "/v1/purge", token=old).status, 200)           # still valid for everything else
        again = self.call("POST", "/v1/token/renew", token=old)
        self.assertEqual((again.status, again.code), (401, "unauthorized"))

    def test_the_rules_are_checked_against_the_file_under_its_lock(self):
        table = S.TokenTable(self.state.cfg.tokens_path)
        token, row = table.issue("alice", self.clock.t, 10)
        table.update(lambda rows: (None, [r.update({"revoked": S._iso(self.clock.t)}) for r in rows] and True))     # revoked after authentication
        with self.assertRaises(S.RenewRefused) as cm:
            table.renew(row.id, self.clock.t, 90)
        self.assertEqual(cm.exception.reason, "unusable")
        with self.assertRaises(S.RenewRefused) as cm:
            table.renew("0" * 8, self.clock.t, 90)                                       # an id that is not there
        self.assertEqual(cm.exception.reason, "unusable")

    def test_two_renewals_at_the_same_moment_make_one_row(self):
        table = S.TokenTable(self.state.cfg.tokens_path)
        token, row = table.issue("alice", self.clock.t, 10)
        gate, outcomes = threading.Barrier(2), []

        def attempt():
            gate.wait(5)
            try:
                outcomes.append(table.renew(row.id, self.clock.t, 90)[1].id)
            except S.RenewRefused as refused:
                outcomes.append(refused.reason)

        threads = [threading.Thread(target=attempt) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertEqual(sorted(o for o in outcomes if o in ("superseded", "unusable")), ["superseded"])
        self.assertEqual(len([o for o in outcomes if S._TOKEN_ID.fullmatch(o)]), 1)
        self.assertEqual(len(table.rows()), 2)


def padded_rows(count, expires, start=0):
    """``count`` live-looking token rows (each ~370 bytes as the table writes them) that nobody holds a secret for."""
    return [{"id": f"{start + i:08x}", "user": f"pad{start + i}", "sha256": hashlib.sha256(str(start + i).encode()).hexdigest(),
             "issued": S._iso(BASE), "expires": S._iso(expires), "issuer": "renew", "revoked": None, "disabled": None, "last_used": None,
             "machine": None, "net": None, "superseded_by": None} for i in range(count)]


class TokenTableSizeTests(ServerCase):
    """A big token table must never lock everybody out (the reviewer's flood did: past 4 MiB nobody authenticated and the admin tools failed
    too). Reading goes on; only a write that would GROW the table past 4 MiB fails, and dead rows are dropped when the table is written."""

    def fill(self, rows):
        self.state.tokens.update(lambda current: (None, current.extend(rows) or True))

    def test_a_table_past_the_write_limit_is_still_served_and_administered(self):
        good = self.token("alice", ttl_days=10)
        self.fill(padded_rows(12000, BASE + 90 * 86400))
        self.assertGreater(os.stat(self.state.cfg.tokens_path).st_size, S.MAX_TABLE_BYTES)
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=good).status, 200)         # authentication goes on
        self.assertIsNone(self.state.tokens.problem)
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}), encoding="utf-8")
        for argv in (["token", "list"], ["token", "revoke", "--user", "alice"]):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(S.main(["--config", str(config), *argv]), 0, err.getvalue())    # the admin can still list and revoke
        self.assertEqual(self.call("POST", "/v1/purge", token=good).code, "unauthorized")

    def test_a_write_that_would_grow_the_table_past_the_limit_fails_cleanly(self):
        near = self.token("alice", ttl_days=10)
        self.fill(padded_rows(12000, BASE + 90 * 86400))
        code = self.state.codes.issue("sam", self.clock.t, 600)
        body = json.dumps({"code": code}).encode()
        enrolled = self.call("POST", "/v1/enroll", body=body, headers={"Content-Type": "application/json"})
        self.assertEqual((enrolled.status, enrolled.code), (503, "busy"))                # no row was added (the single-use code is spent: issue a new one)
        renewed = self.call("POST", "/v1/token/renew", token=near)
        self.assertEqual((renewed.status, renewed.code), (503, "busy"))
        self.assertEqual(self.call("POST", "/v1/purge", token=near).status, 200)         # the token itself is untouched
        with self.assertRaises(S.TableError):
            self.state.tokens.issue("x", self.clock.t, 90)
        self.assertEqual(len(self.state.tokens.rows()), 12001)

    def test_dead_rows_are_dropped_when_the_table_is_written_and_nothing_becomes_valid(self):
        t = self.clock.t
        gone = padded_rows(1, t - 31 * 86400, start=100)[0]                              # expired 31 days ago: dropped
        revoked = padded_rows(1, t + 60 * 86400, start=101)[0]
        revoked["revoked"] = S._iso(t - 31 * 86400)                                     # revoked 31 days ago: dropped
        recent_expired = padded_rows(1, t - 29 * 86400, start=102)[0]                    # expired 29 days ago: kept (evidence for a month)
        recent_revoked = padded_rows(1, t + 60 * 86400, start=103)[0]
        recent_revoked["revoked"] = S._iso(t - 3600)                                     # revoked an hour ago: kept
        odd = padded_rows(1, t - 400 * 86400, start=104)[0]
        odd["expires"] = "never"                                                         # unreadable: kept, never authenticates
        stuck = padded_rows(1, t - 400 * 86400, start=105)[0]
        stuck["revoked"] = True                                                          # revoked at an unknown time, long expired: dropped by its expiry
        self.fill([gone, revoked, recent_expired, recent_revoked, odd, stuck])
        live = self.token("alice")
        ids = {r["id"] for r in json.loads(Path(self.state.cfg.tokens_path).read_text())["tokens"]}
        self.assertEqual(ids, {f"{n:08x}" for n in (102, 103, 104)} | {live.split("_")[1]})

    def test_pruning_makes_room_in_a_full_table(self):
        self.fill(padded_rows(12000, BASE - 40 * 86400))                                 # 12000 rows, all expired 40 days ago
        self.assertGreater(os.stat(self.state.cfg.tokens_path).st_size, S.MAX_TABLE_BYTES)
        token, row = self.state.tokens.issue("alice", self.clock.t, 90)                    # the write drops them first: it fits
        self.assertEqual(list(self.state.tokens.rows()), [row.id])
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=token).status, 200)

    def test_a_table_over_the_read_limit_is_refused_as_before(self):
        self.token("alice")
        self.fill(padded_rows(10, BASE + 86400))
        with mock.patch.object(S, "MAX_READ_BYTES", 2000):
            with self.assertRaisesRegex(S.TableError, "too large"):
                S.TokenTable(self.state.cfg.tokens_path).read_raw()


class MalformedRowTests(ServerCase):
    """Revocation never fails open: a revoked or disabled mark of ANY kind locks the row (somebody editing tokens.json in a hurry writes
    ``true``, a bad merge leaves a broken timestamp). A malformed ``expires`` already dropped the row."""

    def mark(self, token, **fields):
        row_id = token.split("_")[1]
        self.state.tokens.update(lambda rows: (None, [r.update(fields) for r in rows if r["id"] == row_id] and True))

    def test_any_revoked_mark_but_null_and_false_refuses_the_token(self):
        for index, value in enumerate((True, 1, 0, "yes", "", "2026-13-45T99:00:00", "not a time", [], {}, ["x"])):
            tok = self.token(f"user{index}")
            self.mark(tok, revoked=value)
            with self.subTest(revoked=value):
                reply = self.call("POST", "/v1/purge", token=tok)
                self.assertEqual((reply.status, reply.code), (401, "unauthorized"))

    def test_any_disabled_mark_but_null_and_false_disables_the_token(self):
        for index, value in enumerate((True, 1, "", "x", "offboarded", [], {})):
            tok = self.token(f"user{index}")
            self.mark(tok, disabled=value)
            with self.subTest(disabled=value):
                reply = self.call("POST", "/v1/purge", token=tok)
                self.assertEqual((reply.status, reply.code), (403, "forbidden"))

    def test_null_false_and_missing_marks_leave_the_token_usable(self):
        plain = self.token("a")                                                          # the table writes null for both marks
        falsy = self.token("b")
        self.mark(falsy, revoked=False, disabled=False)
        bare = self.token("c")
        bare_id = bare.split("_")[1]

        def drop(rows):
            for row in rows:
                if row["id"] == bare_id:
                    row.pop("revoked", None)
                    row.pop("disabled", None)
            return None, True

        self.state.tokens.update(drop)
        for name, tok in (("null", plain), ("false", falsy), ("absent", bare)):
            with self.subTest(marks=name):
                self.assertEqual(self.call("POST", "/v1/purge", token=tok).status, 200)

    def test_the_listing_agrees_with_the_loader(self):
        a, b, c = self.token("a"), self.token("b"), self.token("c")
        self.mark(a, revoked=True)
        self.mark(b, disabled=1)
        rows = {r.user: r.status(self.clock.t) for r in self.state.tokens.rows().values()}
        self.assertEqual(rows, {"a": "revoked", "b": "disabled", "c": "active"})

    def test_two_rows_with_one_id_are_both_refused(self):
        tok = self.token("alice")
        row_id = tok.split("_")[1]
        self.state.tokens.update(lambda rows: (None, rows.append(dict(rows[0], user="copy", revoked=S._iso(self.clock.t))) or True))
        with self.assertLogs("mcap.asr_server", "ERROR"):
            reply = self.call("POST", "/v1/purge", token=tok)
        self.assertEqual((reply.status, reply.code), (401, "unauthorized"))
        self.assertNotIn(row_id, self.state.tokens.rows())

    def test_a_malformed_expires_still_drops_the_row(self):
        tok = self.token("alice")
        self.mark(tok, expires="never")
        self.assertEqual(self.call("POST", "/v1/purge", token=tok).code, "unauthorized")


# ======================================================================================================================
class HealthTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def health(self, **kw):
        return self.call("GET", "/v1/health?detail=1", token=self.tok, **kw).json

    def test_the_documented_fields(self):
        h = self.health()
        self.assertEqual(h["proto"], S.PROTO)
        self.assertTrue(h["ok"])
        self.assertEqual((h["engine"], h["model"], h["kind"], h["supports_lid"], h["confidence"], h["vendor"]),
                         ("whisper", "fake/whisper-test", "server", True, "logprob", None))
        self.assertEqual(h["limits"], {"sample_rate": 16000, "max_chunk_samples": 496000, "max_lid_clips": 12, "max_lid_clip_samples": 96000,
                                       "max_wait_s": 45, "concurrency_per_token": 2})
        self.assertEqual(h["retention"], {"mode": "none", "audio_disk": False, "text_disk": False, "memory_cache_s": 120, "log_content": False})
        self.assertEqual(set(h["attest"]), {"build_sha256", "config_sha256", "started", "hf_offline", "core_dumps_disabled"})
        self.assertEqual(h["queue"], {"depth": 0, "avg_service_s": 4.0})
        self.assertEqual(h["token"], {"expires_in_days": 90})

    def test_attest_is_the_truth(self):
        self.assertEqual(self.health()["attest"]["build_sha256"], S.build_sha256())
        self.assertRegex(self.health()["attest"]["build_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.health()["attest"]["config_sha256"], self.state.cfg.effective_sha256())
        with mock.patch.object(S, "core_dumps_disabled", return_value=False):
            self.assertFalse(self.health()["attest"]["core_dumps_disabled"])
        with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "1"}):
            self.assertTrue(self.health()["attest"]["hf_offline"])
        with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "0"}):
            self.assertFalse(self.health()["attest"]["hf_offline"])
        self.assertRegex(self.health()["attest"]["started"], r"^\d{4}-\d{2}-\d{2}T")

    def test_build_hash_follows_the_sources(self):
        package = self.root / "pkg"
        package.mkdir()
        (package / "a.py").write_text("x = 1\n")
        first = S.build_sha256(package)
        self.assertEqual(S.build_sha256(package), first)
        (package / "a.py").write_text("x = 2\n")
        self.assertNotEqual(S.build_sha256(package), first)
        (package / "b.py").write_text("")
        self.assertNotEqual(S.build_sha256(package), S.build_sha256(self.root / "empty"))

    def test_a_cloud_backend_reports_kind_cloud_and_its_vendor(self):
        backend = FakeBackend()
        backend.kind, backend.confidence, backend.supports_lid = "cloud", "opaque", False
        backend.vendor_info = lambda: {"name": "azure-speech", "region": "koreacentral", "claim_url": "https://example.test/claim", "verified": False}
        state = self.make_state(backend=backend)
        tok = self.token("sam", state=state)
        h = self.call("GET", "/v1/health?detail=1", token=tok, state=state).json
        self.assertEqual((h["kind"], h["confidence"], h["supports_lid"]), ("cloud", "opaque", False))
        self.assertEqual(h["vendor"]["name"], "azure-speech")
        backend.vendor_info = None
        del backend.vendor_info
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=tok, state=state).json["vendor"]["verified"], False)

    def test_pinned_model_reports_its_revision(self):
        backend = FakeBackend()
        backend.model = "mlx-community/whisper-large-v3-mlx"
        state = self.make_state(backend=backend)
        tok = self.token("sam", state=state)
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=tok, state=state).json["revision"], "49e6aa28")
        self.assertEqual(self.chunk(tok, state=state).json["model"], "mlx-community/whisper-large-v3-mlx@49e6aa28")

    def test_health_is_not_ok_without_a_worker(self):
        state = S.ServerState(self.config(), FakeBackend(), now_fn=self.clock.now, clock=self.clock.mono)       # never started
        tok = self.token("sam", state=state)
        self.assertEqual(self.call("GET", "/v1/health", state=state).json["ok"], False)

    def test_days_left_round_down(self):
        tok = self.token("short", ttl_days=14)
        self.clock.advance(3600)
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=tok).json["token"]["expires_in_days"], 13)    # 13.96 days: renew now


class MetaLogTests(ServerCase):
    def test_records_have_exactly_the_documented_keys_and_no_content(self):
        tok = self.token("alice", ttl_days=10)                                             # inside the renewal window, so the renewal really happens
        self.put_vocab(tok, [TERM_CANARY])
        self.chunk(tok, extra={"X-MCAP-Chunk": "mic:3"}, peer="203.0.113.77")
        self.lid(tok, [16000])
        self.call("POST", "/v1/token/renew", token=tok)
        self.call("POST", "/v1/purge", token=tok)
        recs = self.records()
        self.assertEqual([r["op"] for r in recs], ["vocab", "transcribe", "lid", "renew", "purge"])
        for rec in recs:
            self.assertEqual(tuple(rec), S.META_KEYS)
            self.assertEqual((rec["user"], rec["engine"]), ("alice", "whisper"))
        transcribe = recs[1]
        self.assertEqual((transcribe["samples"], transcribe["audio_s"], transcribe["status"], transcribe["bytes_in"]), (16000, 1.0, 200, 32000))
        self.assertEqual(transcribe["src_net"], "203.0.113.0/24")
        text = (self.logs / os.listdir(self.logs)[0]).read_text()
        for secret in (TERM_CANARY, TEXT_CANARY, "mic:3", "203.0.113.77", tok.split("_", 2)[2]):
            self.assertNotIn(secret, text)
        self.assertTrue(text.isascii())

    def test_failures_are_logged_with_their_status_and_no_audio(self):
        tok = self.token("alice")
        self.chunk(tok, extra={"Content-Type": "audio/wav"})
        self.chunk(tok, n=S.MAX_CHUNK_SAMPLES + 5)
        recs = self.records()
        self.assertEqual([(r["op"], r["status"], r["audio_s"]) for r in recs], [("transcribe", 415, 0.0), ("transcribe", 413, 0.0)])
        self.call("GET", "/v1/health")                                                 # health and unauthenticated attempts are not logged
        self.call("POST", "/v1/purge", headers={"Authorization": "Bearer x"})
        self.assertEqual(len(self.records()), 2)

    def test_src_net_is_coarse(self):
        self.assertEqual(S.src_net("203.0.113.77"), "203.0.113.0/24")
        self.assertEqual(S.src_net("2001:db8:1:2:3:4:5:6"), "2001:db8:1::/48")
        self.assertEqual(S.src_net("::ffff:198.51.100.9"), "198.51.100.0/24")
        self.assertIsNone(S.src_net(None))
        self.assertIsNone(S.src_net("not an address"))

    def test_old_day_files_are_pruned_at_start(self):
        log = S.MetaLog(self.logs, 400)
        for days_ago in (1, 399, 401, 800):
            day = S._day(self.clock.t - days_ago * 86400)
            (self.logs / f"meta-{day}.jsonl").write_text("")
        (self.logs / "server.log").write_text("keep\n")
        state = self.make_state()
        remaining = log.days()
        self.assertEqual(len(remaining), 2)
        self.assertTrue((self.logs / "server.log").exists())
        self.assertEqual(state.metalog.prune(self.clock.t), 0)

    def test_restore_reads_only_todays_clean_lines(self):
        log = S.MetaLog(self.logs, 400)
        today, yesterday = S._day(self.clock.t), S._day(self.clock.t - 86400)
        rec = lambda tid, audio, ts: {"ts": S._iso(ts), "user": "x", "token_id": tid, "op": "transcribe", "samples": 1, "audio_s": audio,
                                      "status": 200, "queue_ms": 0, "dur_ms": 1, "engine": "whisper", "bytes_in": 1, "src_net": None,
                                      "machine_changed": False}
        log.append(rec("aaaaaaaa", 5.0, self.clock.t - 30), self.clock.t)
        log.append(rec("aaaaaaaa", 7.0, self.clock.t - 600), self.clock.t)
        log.append(rec("bbbbbbbb", 2.0, self.clock.t - 10), self.clock.t)
        log.append(rec("aaaaaaaa", 50.0, self.clock.t - 86400), self.clock.t - 86400)         # yesterday's file
        with open(log.path_for(today), "a", encoding="ascii") as fh:
            fh.write("not json\n[1, 2]\n" + json.dumps({"token_id": "aaaaaaaa", "audio_s": "lots"}) + "\n" + json.dumps({"audio_s": 3}) + "\n")
        quotas = S.Quotas(self.config())
        quotas.restore(log, self.clock.t)
        self.assertEqual((quotas.used["aaaaaaaa"], quotas.used["bbbbbbbb"]), (12.0, 2.0))
        self.assertEqual((len(quotas.recent["aaaaaaaa"]), len(quotas.recent["bbbbbbbb"])), (1, 1))     # only the last minute counts for the rate
        self.assertEqual(log.days(), sorted([today, yesterday]))

    def test_a_record_with_other_keys_is_refused(self):
        with self.assertRaises(ValueError):
            S.MetaLog(self.logs, 400).append({"ts": "x", "text": "no"}, self.clock.t)

    def test_unwritable_log_never_fails_the_request(self):
        tok = self.token("alice")
        os.chmod(self.logs, 0o500)
        self.addCleanup(os.chmod, self.logs, 0o700)
        with self.assertLogs("mcap.asr_server", "ERROR"):
            self.assertEqual(self.chunk(tok).status, 200)


class LogFloodTests(ServerCase):
    """Requests that cost the server almost nothing must not fill the log volume (the audit trail and the token writes live there): their
    lines are written within a budget and only counted beyond it. Work that was accepted is always written."""

    WAV = {"Content-Type": "audio/wav"}                                                  # a chunk with the wrong media type: a 415, no work

    def enroll(self, code, peer="203.0.113.5", **kw):
        body = json.dumps({"code": code}).encode()
        return self.call("POST", "/v1/enroll", body=body, headers={"Content-Type": "application/json"}, peer=peer, **kw)

    def log_bytes(self):
        return sum(os.path.getsize(self.logs / name) for name in os.listdir(self.logs))

    def test_a_flood_of_failed_enrollments_writes_a_bounded_number_of_lines(self):
        with self.assertLogs("mcap.asr_server", "WARNING") as logged:
            codes = [self.enroll("AAAA-AAAA-AAAA").code for _ in range(3000)]
        self.assertEqual(codes.count("enroll_invalid"), S.ENROLL_FAILS_PER_SOURCE)
        self.assertEqual(codes.count("enroll_throttled"), 3000 - S.ENROLL_FAILS_PER_SOURCE)         # every answer is as before
        lines = [r for r in self.records() if r["op"] == "enroll"]
        self.assertEqual(len(lines), S.LOG_ENROLL_FAILS_PER_SOURCE)
        self.assertLess(self.log_bytes(), 10 * 300)
        reported = [r.getMessage() for r in logged.records if "counted but not written" in r.getMessage()]
        self.assertEqual(len(reported), 1)                                               # one line, not 2990
        for text in reported:
            self.assertNotIn("203.0.113", text)

    def test_the_rest_is_counted_and_reported_once_a_minute(self):
        with self.assertLogs("mcap.asr_server", "WARNING") as logged:
            for _ in range(200):
                self.enroll("AAAA-AAAA-AAAA")
            self.clock.advance(61)
            self.assertEqual(self.enroll("AAAA-AAAA-AAAA", now=self.clock.t).code, "enroll_throttled")      # the 61 s are not the 10 minutes
        counts = [int(r.getMessage().split()[0]) for r in logged.records if "counted but not written" in r.getMessage()]
        self.assertEqual(len(counts), 2)
        self.assertEqual(counts[0], 1)                                                   # the first line over the budget reports at once
        self.assertEqual(counts[1], 190)                                                 # then the other 189 of that minute, and the one 61 s later

    def test_a_successful_enrollment_is_logged_whatever_the_flood_before_it(self):
        for _ in range(100):
            self.enroll("AAAA-AAAA-AAAA", peer="203.0.113.5")
        code = self.state.codes.issue("sam", self.clock.t, 600)
        self.assertEqual(self.enroll(code, peer="198.51.100.7").status, 200)
        later = self.state.codes.issue("kim", self.clock.t + 700, 600)
        self.assertEqual(self.enroll(later, peer="203.0.113.5", now=self.clock.t + 700).status, 200)    # the flooded network, after the window
        wins = [(r["status"], r["user"]) for r in self.records() if r["op"] == "enroll" and r["status"] == 200]
        self.assertEqual(wins, [(200, "sam"), (200, "kim")])

    def test_failed_enrollments_from_many_networks_share_a_global_budget(self):
        for i in range(200):
            self.enroll("AAAA-AAAA-AAAA", peer=f"10.0.{i}.1")
        self.assertEqual(len([r for r in self.records() if r["op"] == "enroll"]), S.LOG_ENROLL_FAILS_GLOBAL)

    def test_a_token_holders_refusals_are_logged_within_a_budget_of_their_own(self):
        alice, sam = self.token("alice"), self.token("sam")
        answers = {self.chunk(alice, extra=self.WAV).status for _ in range(500)}
        self.assertEqual(answers, {415})
        mine = lambda who: [r for r in self.records() if r["user"] == who]
        self.assertEqual(len(mine("alice")), S.LOG_REJECTS_PER_TOKEN)
        for _ in range(5):
            self.chunk(sam, extra=self.WAV)
        self.assertEqual(len(mine("sam")), 5)                                            # another token is not held back by alice's flood
        self.clock.advance(S.LOG_REJECT_WINDOW_S + 1)
        self.chunk(alice, extra=self.WAV)
        self.assertEqual(len(mine("alice")), S.LOG_REJECTS_PER_TOKEN + 1)                  # and the window rolls on

    def test_cheap_successes_are_budgeted_too(self):
        tok = self.token("alice")
        for _ in range(300):
            self.assertEqual(self.call("POST", "/v1/purge", token=tok).status, 200)
        for i in range(100):
            self.assertEqual(self.put_vocab(tok, [f"term{i}"]).status, 204)
        self.assertEqual(len([r for r in self.records() if r["user"] == "alice"]), S.LOG_REJECTS_PER_TOKEN)

    def test_accepted_work_is_always_logged_and_the_daily_quota_survives_a_restart(self):
        tok = self.token("alice")
        for _ in range(100):
            self.chunk(tok, extra=self.WAV)                                              # the refusal budget is used up
        for _ in range(40):
            self.assertEqual(self.chunk(tok, n=1600).status, 200)
        done = [r for r in self.records() if r["op"] == "transcribe" and r["status"] == 200]
        self.assertEqual(len(done), 40)                                                  # none of them was dropped
        restarted = self.make_state()
        self.assertAlmostEqual(restarted.quotas.used[tok.split("_")[1]], 4.0)

    def test_the_budget_table_cannot_grow_without_bound(self):
        budget = S._LogBudget(2, 60.0, max_keys=4)
        for key in "abcd":
            self.assertTrue(budget.take(key, 0.0))
        self.assertTrue(budget.take("e", 0.0))                                           # no room for a fifth key: it shares one
        self.assertTrue(budget.take("f", 0.0))
        self.assertFalse(budget.take("g", 0.0))                                          # ... whose budget is then used up by all of them
        self.assertLessEqual(len(budget._by_key), 5)
        self.assertTrue(budget.take("h", 120.0))                                         # stale keys are forgotten once the window is over
        self.assertEqual(sorted(budget._by_key), ["h"])


# ======================================================================================================================
class TokenAdminTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.config_file = self.root / "asr-server.json"
        self.config_file.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}), encoding="utf-8")

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = S.main(["--config", str(self.config_file), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_issue_prints_the_token_once_and_stores_a_digest(self):
        code, out, err = self.run_main("token", "issue", "--user", "alice", "--ttl-days", "30")
        self.assertEqual(code, 0)
        token = out.strip()
        self.assertRegex(token, r"^mcap1_[0-9a-f]{8}_[A-Za-z0-9_-]{32}$")
        self.assertNotIn(token, err)
        self.assertNotIn(token.split("_", 2)[2], Path(self.state.cfg.tokens_path).read_text())
        self.assertEqual(self.call("GET", "/v1/health?detail=1", token=token, now=time.time()).json["token"]["expires_in_days"], 29)

    def test_list_never_shows_secrets_or_digests(self):
        token = self.run_main("token", "issue", "--user", "alice")[1].strip()
        code, out, _ = self.run_main("token", "list")
        self.assertEqual(code, 0)
        self.assertIn("alice", out)
        self.assertIn("active", out)
        self.assertNotIn(token.split("_", 2)[2], out)
        self.assertNotIn(hashlib.sha256(token.split("_", 2)[2].encode()).hexdigest(), out)
        listed = json.loads(self.run_main("token", "list", "--json")[1])
        self.assertEqual((listed[0]["user"], listed[0]["status"]), ("alice", "active"))
        self.assertNotIn("sha256", listed[0])

    def test_revoke_by_id_and_by_user(self):
        a = self.run_main("token", "issue", "--user", "alice")[1].strip()
        b = self.run_main("token", "issue", "--user", "sam")[1].strip()
        self.assertEqual(self.run_main("token", "revoke", "--id", a.split("_")[1])[0], 0)
        self.assertEqual(self.call("POST", "/v1/purge", token=a, now=time.time()).code, "unauthorized")
        self.assertEqual(self.call("POST", "/v1/purge", token=b, now=time.time()).status, 200)
        self.assertEqual(self.run_main("token", "revoke", "--user", "nobody")[0], 1)
        self.assertEqual(self.run_main("token", "revoke", "--id", a.split("_")[1])[0], 1)               # already revoked: nothing to do
        self.assertEqual(self.run_main("token", "revoke", "--user", "SAM")[0], 0)
        self.assertEqual(self.call("POST", "/v1/purge", token=b, now=time.time()).code, "unauthorized")
        _, out, _ = self.run_main("token", "list")
        self.assertEqual(out.count("revoked"), 2)

    def test_sync_disables_everyone_who_is_not_on_the_allow_list(self):
        tokens = {u: self.run_main("token", "issue", "--user", u)[1].strip() for u in ("alice", "sam", "leaver", "gone")}
        self.run_main("token", "revoke", "--user", "gone")
        allow = self.root / "staff.txt"
        allow.write_text("# exported from Workspace\nALICE\n\nsam   # Sam\n", encoding="utf-8")
        code, out, _ = self.run_main("token", "sync", "--allow-list", str(allow), "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("would disable", out)
        self.assertIn("leaver", out)
        self.assertNotIn("gone", out)                                                    # an already revoked token is not touched
        self.assertEqual(self.call("POST", "/v1/purge", token=tokens["leaver"], now=time.time()).status, 200)       # dry run changed nothing
        code, out, _ = self.run_main("token", "sync", "--allow-list", str(allow))
        self.assertEqual(code, 0)
        self.assertEqual(self.call("POST", "/v1/purge", token=tokens["leaver"], now=time.time()).code, "forbidden")
        self.assertEqual(self.call("POST", "/v1/purge", token=tokens["alice"], now=time.time()).status, 200)
        self.assertEqual(self.call("POST", "/v1/purge", token=tokens["sam"], now=time.time()).status, 200)
        self.assertEqual(self.call("POST", "/v1/purge", token=tokens["gone"], now=time.time()).code, "unauthorized")

    def test_sync_refuses_an_empty_list(self):
        self.run_main("token", "issue", "--user", "alice")
        empty = self.root / "empty.txt"
        empty.write_text("# nobody\n\n", encoding="utf-8")
        code, _, err = self.run_main("token", "sync", "--allow-list", str(empty))
        self.assertEqual(code, 2)
        self.assertIn("empty", err)
        self.assertEqual(self.run_main("token", "list")[1].count("active"), 1)

    def test_enroll_code_issue(self):
        code, out, err = self.run_main("enroll-code", "issue", "--user", "alice")
        self.assertEqual(code, 0)
        self.assertRegex(out.strip(), r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")
        self.assertEqual(S.CodeTable(self.state.cfg.codes_path).consume(out.strip(), time.time()), "alice")
        self.assertIsNone(S.CodeTable(self.state.cfg.codes_path).consume(out.strip(), time.time()))

    def test_admin_commands_report_a_bad_setup(self):
        os.chmod(self.secrets, 0o755)
        code, _, err = self.run_main("token", "issue", "--user", "alice")
        self.assertEqual(code, 1)
        self.assertIn("0700", err)
        os.chmod(self.secrets, 0o700)
        bad = self.root / "bad.json"
        bad.write_text('{"nope": 1}')
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(S.main(["--config", str(bad), "token", "list"]), 2)
        self.assertIn("unknown key", err.getvalue())

    def test_two_writers_never_lose_each_others_rows(self):
        table = S.TokenTable(self.state.cfg.tokens_path)
        errors = []

        def issue(user):
            try:
                for i in range(8):
                    S.TokenTable(self.state.cfg.tokens_path).issue(f"{user}{i}", time.time(), 90)
            except Exception as exc:                                                     # pragma: no cover - the assertion below reports it
                errors.append(exc)

        threads = [threading.Thread(target=issue, args=(f"u{n}-",)) for n in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(errors, [])
        self.assertEqual(len(table.rows()), 32)

    def test_root_adopts_files_for_the_service_user(self):
        calls = []
        with mock.patch.object(os, "geteuid", return_value=0), mock.patch.object(os, "fchown", lambda fd, uid, gid: calls.append(("fd", uid))), \
                mock.patch.object(os, "chown", lambda path, uid, gid: calls.append(("path", uid))):
            S.TokenTable(self.state.cfg.tokens_path).issue("root-made", time.time(), 90)
        self.assertEqual({kind for kind, _ in calls}, {"fd"})
        self.assertEqual({uid for _, uid in calls}, {os.stat(self.secrets).st_uid})


# ======================================================================================================================
class ContentScanTests(ServerCase):
    """The byte scan: after a run that carried audio, text, a vocabulary, tokens and codes, none of it is in any file or log."""

    def test_no_audio_and_no_text_in_any_file_or_log_after_a_run(self):
        audio = bytes((i * 7 + 13) % 251 + 1 for i in range(64)) * 400                  # 25.6 kB of a recognisable non-silent pattern
        samples = len(audio) // 2
        audio_probe = audio[:96]
        enrolled = self.state.codes.issue("alice", self.clock.t, 600)
        records = []

        class Capture(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage() + (record.exc_text or ""))

        handler = Capture(level=logging.DEBUG)
        logging.getLogger().addHandler(handler)
        previous = logging.getLogger().level
        logging.getLogger().setLevel(logging.DEBUG)
        self.addCleanup(logging.getLogger().removeHandler, handler)
        self.addCleanup(logging.getLogger().setLevel, previous)

        token = Reply(S.handle_request(self.state, "POST", "/v1/enroll", {"X-MCAP-Proto": S.PROTO, "Content-Length": str(len(json.dumps({"code": enrolled}))),
                                                                          "Content-Type": "application/json"},
                                       json.dumps({"code": enrolled}).encode(), self.clock.t, peer="203.0.113.50")).json["token"]
        self.put_vocab(token, [TERM_CANARY, "액미"])
        digest = S.canonical_vocab_digest({"terms": [TERM_CANARY, "액미"]})
        for i in range(3):
            self.assertEqual(self.chunk(token, n=samples, body=audio, lang="ko", peer="203.0.113.50",
                                        extra={"X-MCAP-Vocab": digest, "X-MCAP-Prompt": "frame+list", "X-MCAP-Idem": f"i{i}"}).status, 200)
        self.assertEqual(self.lid(token, [samples // 2, samples // 2], body=audio).status, 200)
        self.backend.script = [RuntimeError(TEXT_CANARY)]
        self.chunk(token, n=samples, body=audio, lang="ko", marker=1)
        self.clock.advance(80 * 86400)                                                   # 10 of its 90 days left: renewal is possible now
        renewed = self.call("POST", "/v1/token/renew", token=token).json["token"]
        self.call("POST", "/v1/purge", token=renewed)
        self.state.close()

        wanted = {"audio": audio_probe, "transcript": TEXT_CANARY.encode(), "term": TERM_CANARY.encode(), "korean term": "액미".encode(),
                  "token secret": token.split("_", 2)[2].encode(), "renewed secret": renewed.split("_", 2)[2].encode(),
                  "code": enrolled.replace("-", "").encode()}
        scanned = 0
        for path in self.root.rglob("*"):
            if path.is_file() and not path.name.endswith(".lock"):
                data = path.read_bytes()
                scanned += 1
                for what, needle in wanted.items():
                    self.assertNotIn(needle, data, f"{what} found in {path.name}")
        self.assertGreaterEqual(scanned, 3)
        joined = "\n".join(records)
        for what, needle in wanted.items():
            self.assertNotIn(needle.decode("latin-1"), joined, f"{what} found in a log record")
        for secret in (TEXT_CANARY, TERM_CANARY, token.split("_", 2)[2]):
            self.assertNotIn(secret, joined)
        (self.root / "home").mkdir()                                                     # (a home that is not there is a finding, not a clean result)
        self.assertEqual(S.audit_home(self.root / "home", self.secrets, self.logs), [])

    def test_the_audit_finds_planted_audio_and_text(self):
        home = self.root / "home"
        home.mkdir()
        self.assertEqual(S.audit_home(home, self.secrets, self.logs), [])
        (home / "a.wav").write_bytes(b"x")
        (home / "cache.bin").write_bytes(b"RIFF\x24\x00\x00\x00WAVEfmt ")
        (home / "clip").write_bytes(b"\x00\x00\x00\x20ftypM4A ")
        (home / "tune").write_bytes(b"ID3\x03\x00\x00")
        (home / "ok.json").write_text('{"fine": true}')
        (self.logs / "server.log").write_text("2026-10-15 INFO mcap.asr_server: listening\n안녕하세요 회의 내용\n", encoding="utf-8")
        found = {(f.kind, os.path.basename(f.path)) for f in S.audit_home(home, self.secrets, self.logs)}
        self.assertEqual(found, {("audio-extension", "a.wav"), ("audio-signature", "cache.bin"), ("audio-signature", "clip"),
                                 ("audio-signature", "tune"), ("log-content", "server.log")})

    def test_the_audit_checks_every_metadata_line_and_binary_log_files(self):
        day = S._day(self.clock.t)
        good = {k: None for k in S.META_KEYS}
        (self.logs / f"meta-{day}.jsonl").write_text(json.dumps(good) + "\n" + json.dumps({**good, "text": "hello"}) + "\n")
        (self.logs / "dump.bin").write_bytes(b"\x00\x01\x02" * 100)
        (self.logs / "api.log").write_text('{"segments": [], "text": "x"}\n')
        (self.logs / "long.log").write_text("x" * 2000 + "\n")
        kinds = {(f.kind, os.path.basename(f.path)) for f in S.scan_log_dir(self.logs)}
        self.assertEqual(kinds, {("log-content", f"meta-{day}.jsonl"), ("binary-content", "dump.bin"), ("log-content", "api.log"),
                                 ("log-content", "long.log")})

    def test_cli_audit_exit_codes(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}))
        home = self.root / "home"
        home.mkdir()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "audit", "--home", str(home)]), 0)
        self.assertIn("0 finding", out.getvalue())
        (home / "x.m4a").write_bytes(b"")
        with contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "audit", "--home", str(home)]), 1)
        self.assertIn("FINDING audio-extension", out.getvalue())


class AuditCoverageTests(ServerCase):
    """The quarterly audit is the only proof that no audio is on disk. A result of '0 findings' must mean it looked at everything:
    every gap in its coverage is a finding of its own (and so a non-zero exit), never a silent skip."""

    def make_home(self):
        home = self.root / "home"
        home.mkdir()
        return home

    def kinds(self, findings):
        return sorted((f.kind, os.path.basename(f.path)) for f in findings)

    def config_file(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}), encoding="utf-8")
        return str(config)

    def audit(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = S.main(["--config", self.config_file(), "audit", *argv])
        return code, out.getvalue(), err.getvalue()

    def test_a_flood_of_junk_files_does_not_hide_audio_behind_the_limit(self):
        home = self.make_home()
        (home / "a").mkdir()
        (home / "z").mkdir()
        for i in range(20010):                                                           # the reviewer's case: more files than the old limit of 20000
            (home / "a" / f"f{i:05d}").write_bytes(b"")
        (home / "z" / "meeting").write_bytes(b"RIFF\x24\x00\x00\x00WAVEfmt ")
        found = S.audit_home(home, self.secrets, self.logs)
        self.assertEqual(self.kinds(found), [("audio-signature", "meeting")])

    def test_a_scan_that_hits_its_limit_says_so(self):
        home = self.make_home()
        for i in range(30):
            (home / f"f{i:02d}").write_bytes(b"")
        (home / "zz.wav").write_bytes(b"x")                                              # sorts last: beyond the limit
        found = S.scan_for_audio(home, limit=10)
        self.assertEqual([f.kind for f in found], ["scan-incomplete"])
        self.assertIn("10", found[0].detail)
        with mock.patch.object(S, "SCAN_FILE_LIMIT", 10):                                # the constant is what the audit and the self-check use
            code, out, _ = self.audit("--home", str(home))
        self.assertEqual(code, 1)
        self.assertIn("FINDING scan-incomplete", out)

    @unittest.skipIf(os.geteuid() == 0, "root can read a directory with mode 000")
    def test_a_directory_that_cannot_be_listed_is_a_finding(self):
        home = self.make_home()
        (home / "private").mkdir()
        (home / "private" / "meeting.wav").write_bytes(b"x")
        os.chmod(home / "private", 0)
        self.addCleanup(os.chmod, home / "private", 0o700)
        self.assertEqual(self.kinds(S.audit_home(home, self.secrets, self.logs)), [("scan-unreadable", "private")])
        code, out, _ = self.audit("--home", str(home))
        self.assertEqual(code, 1)
        self.assertIn("FINDING scan-unreadable", out)

    @unittest.skipIf(os.geteuid() == 0, "root can read a file with mode 000")
    def test_a_file_that_cannot_be_read_is_a_finding(self):
        home = self.make_home()
        secret = home / "blob"
        secret.write_bytes(b"RIFF\x24\x00\x00\x00WAVE")
        os.chmod(secret, 0)
        self.addCleanup(os.chmod, secret, 0o600)
        self.assertEqual(self.kinds(S.audit_home(home, self.secrets, self.logs)), [("scan-unreadable", "blob")])

    def test_a_home_that_is_not_there_is_an_error_not_a_clean_result(self):
        code, out, err = self.audit("--home", str(self.root / "no" / "such" / "dir"))
        self.assertEqual(code, 2)
        self.assertNotIn("0 finding", out)
        self.assertIn("does not exist", err)
        self.assertEqual(self.kinds(S.audit_home(self.root / "no-home", self.secrets, self.logs)), [("scan-root", "no-home")])

    def test_the_default_home_is_the_service_users_not_the_callers(self):
        code, out, err = self.audit()                                                    # <secrets_dir>/home does not exist yet
        self.assertEqual(code, 2)
        self.assertIn(str(self.secrets / "home"), err)
        home = self.secrets / "home"
        home.mkdir()
        os.chmod(home, 0o700)
        self.assertEqual(self.audit()[0], 0)
        (home / "leftover.wav").write_bytes(b"x")                                        # found without --home: the default is scanned
        code, out, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertIn("leftover.wav", out)
        with mock.patch.dict(os.environ, {"HOME": str(self.root / "callers-home")}):     # the caller's own home plays no part
            (self.root / "callers-home").mkdir()
            (self.root / "callers-home" / "x.wav").write_bytes(b"x")
            (home / "leftover.wav").unlink()
            self.assertEqual(self.audit()[0], 0)

    def test_a_missing_service_directory_is_a_finding(self):
        home = self.make_home()
        found = S.audit_home(home, self.root / "no-secrets", self.root / "no-logs")
        self.assertEqual(self.kinds(found), [("scan-root", "no-logs"), ("scan-root", "no-secrets")])      # reported once each
        self.assertEqual(self.audit("--home", str(home))[0], 0)                          # (the real ones exist)

    @unittest.skipIf(os.geteuid() == 0, "root can read a directory with mode 000")
    def test_an_unreadable_log_directory_is_a_finding(self):
        os.chmod(self.logs, 0)
        self.addCleanup(os.chmod, self.logs, 0o700)
        self.assertEqual([f.kind for f in S.scan_log_dir(self.logs)], ["scan-root"])

    def test_log_files_that_were_not_fully_scanned_are_findings(self):
        (self.logs / "big.log").write_text("fine\n" * 400)
        with mock.patch.object(S, "SCAN_LOG_BYTES", 1000):
            self.assertEqual(self.kinds(S.scan_log_dir(self.logs)), [("scan-incomplete", "big.log")])
        (self.root / "elsewhere.log").write_text("x\n")
        os.symlink(self.root / "elsewhere.log", self.logs / "link.log")
        self.assertEqual(self.kinds(S.scan_log_dir(self.logs)), [("scan-unreadable", "link.log")])      # a link: its target was not looked at
        os.unlink(self.logs / "link.log")
        os.mkdir(self.logs / "sub")                                                      # a directory is walked by scan_for_audio, not a log file
        self.assertEqual(S.scan_log_dir(self.logs), [])

    @unittest.skipIf(os.geteuid() == 0, "root can read a file with mode 000")
    def test_an_unreadable_log_file_is_a_finding(self):
        path = self.logs / "server.log"
        path.write_text("ok\n")
        os.chmod(path, 0)
        self.addCleanup(os.chmod, path, 0o600)
        self.assertEqual(self.kinds(S.scan_log_dir(self.logs)), [("scan-unreadable", "server.log")])

    def test_the_startup_self_check_does_not_pass_on_an_incomplete_scan(self):
        for i in range(12):
            (self.logs / f"x{i}.log").write_text("ok\n")
        cfg = S.config_from_dict({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)})
        with mock.patch.object(S, "SCAN_FILE_LIMIT", 5), mock.patch.object(S, "core_dumps_disabled", return_value=True):
            checks = {c.name: c for c in S.run_selfchecks(cfg)}
        self.assertFalse(checks["no_audio_on_disk"].ok)
        self.assertIn("scan-incomplete", checks["no_audio_on_disk"].detail)
        self.assertIn("cannot say there is no audio", checks["no_audio_on_disk"].detail)
        with mock.patch.object(S, "core_dumps_disabled", return_value=True):
            self.assertTrue({c.name: c for c in S.run_selfchecks(cfg)}["no_audio_on_disk"].ok)


# ======================================================================================================================
class SelfCheckTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.secrets, self.logs = self.root / "secrets", self.root / "logs"
        for directory in (self.secrets, self.logs):
            directory.mkdir()
            os.chmod(directory, 0o700)

    def cfg(self, **over):
        return S.config_from_dict({"secrets_dir": str(self.secrets), "log_dir": str(self.logs), **over})

    def checks(self, cfg=None, **kw):
        with mock.patch.object(S, "core_dumps_disabled", return_value=True):
            return {c.name: c for c in S.run_selfchecks(cfg or self.cfg(), **kw)}

    def test_a_good_setup_passes(self):
        checks = self.checks()
        self.assertTrue(all(c.ok for c in checks.values()), {n: c.detail for n, c in checks.items() if not c.ok})
        self.assertEqual(set(checks), {"bind", "core_dumps", "secrets_dir", "log_dir", "tokens", "enroll_codes", "no_audio_on_disk"})

    def test_non_loopback_plaintext_bind_is_refused(self):
        for listen in ("0.0.0.0:8443", "10.1.2.3:8443", "[::]:8443"):
            with self.subTest(listen=listen):
                cfg = self.cfg(listen=listen)
                self.assertFalse(S.check_bind(cfg).ok)
                self.assertFalse(self.checks(cfg)["bind"].ok)
                with self.assertRaises(S.StartupRefused):
                    S.make_server(S.ServerState(cfg, FakeBackend()))
        for listen in ("127.0.0.1:8443", "[::1]:8443", "localhost:8443"):
            self.assertTrue(S.check_bind(self.cfg(listen=listen)).ok, listen)
        tls = self.cfg(listen="0.0.0.0:8443", tls_cert=str(self.secrets / "tls.crt"), tls_key=str(self.secrets / "tls.key"))
        self.assertTrue(S.check_bind(tls).ok)

    def test_core_dump_limit(self):
        self.assertFalse(S.check_core_limit().ok if not S.core_dumps_disabled() else False)
        with mock.patch.object(resource_module(), "getrlimit", return_value=(0, 0)):
            self.assertTrue(S.core_dumps_disabled())
            self.assertTrue(S.check_core_limit().ok)
        with mock.patch.object(resource_module(), "getrlimit", return_value=(0, resource_module().RLIM_INFINITY)):
            self.assertFalse(S.core_dumps_disabled())                                   # the soft limit alone can be raised again
        with mock.patch.object(resource_module(), "getrlimit", return_value=(1 << 20, 1 << 20)):
            self.assertFalse(S.check_core_limit().ok)
        failed = self.checks_with_limit(False)
        self.assertFalse(failed["core_dumps"].ok)

    def checks_with_limit(self, ok):
        with mock.patch.object(S, "core_dumps_disabled", return_value=ok):
            return {c.name: c for c in S.run_selfchecks(self.cfg())}

    def test_harden_process_sets_the_limits_in_a_child_process(self):
        code = ("import os, resource; from mcap import asr_server as S; S.harden_process(); "
                "print(resource.getrlimit(resource.RLIMIT_CORE)); print(oct(os.umask(0))); print(os.environ['HF_HUB_OFFLINE']); "
                "print(S.core_dumps_disabled())")
        env = {**os.environ, "PYTHONPATH": str(REPO / "pipeline"), "PYTHONDONTWRITEBYTECODE": "1"}
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env, timeout=60, check=True).stdout.split("\n")
        self.assertEqual(out[:4], ["(0, 0)", "0o77", "1", "True"])

    def test_directory_and_file_modes(self):
        os.chmod(self.secrets, 0o755)
        self.assertIn("0700", self.checks()["secrets_dir"].detail)
        self.assertFalse(self.checks()["secrets_dir"].ok)
        os.chmod(self.secrets, 0o700)
        os.chmod(self.logs, 0o770)
        self.assertFalse(self.checks()["log_dir"].ok)
        os.chmod(self.logs, 0o700)
        (self.secrets / "tokens.json").write_text('{"schema":1,"tokens":[]}')
        os.chmod(self.secrets / "tokens.json", 0o644)
        self.assertEqual((self.checks()["tokens"].ok, "0600" in self.checks()["tokens"].detail), (False, True))
        os.chmod(self.secrets / "tokens.json", 0o600)
        self.assertTrue(self.checks()["tokens"].ok)
        shutil_rmtree(self.logs)
        self.assertFalse(self.checks()["log_dir"].ok)
        self.assertIn("does not exist", self.checks()["log_dir"].detail)

    def test_symlinked_directory_and_foreign_owner_are_refused(self):
        real = self.root / "real"
        real.mkdir()
        os.chmod(real, 0o700)
        link = self.root / "link"
        link.symlink_to(real)
        self.assertIn("plain directory", S.private_dir_problem(link))
        (real / "f").write_text("x")
        os.chmod(real / "f", 0o600)
        self.assertIsNone(S.private_file_problem(real / "f", owner_uid=os.geteuid()))
        self.assertIn("another user", S.private_file_problem(real / "f", owner_uid=os.geteuid() + 1))
        self.assertIn("another user", S.private_dir_problem(real, euid=os.geteuid() + 1))
        self.assertIsNone(S.private_dir_problem(real, euid=0))                          # root may administer
        (real / "g").symlink_to(real / "f")
        self.assertIn("regular", S.private_file_problem(real / "g", owner_uid=os.geteuid()))

    def test_tls_key_and_config_file_checks(self):
        cert, key = self.secrets / "tls.crt", self.secrets / "tls.key"
        cert.write_text("c")
        key.write_text("k")
        os.chmod(key, 0o644)
        cfg = self.cfg(listen="0.0.0.0:8443", tls_cert=str(cert), tls_key=str(key))
        self.assertFalse(self.checks(cfg)["tls_key"].ok)
        os.chmod(key, 0o600)
        checks = self.checks(cfg)
        self.assertTrue(checks["tls_key"].ok and checks["tls_cert"].ok and checks["bind"].ok)
        config = self.root / "asr-server.json"
        config.write_text("{}")
        os.chmod(config, 0o666)
        self.assertFalse(self.checks(cfg, config_path=config)["config_file"].ok)
        os.chmod(config, 0o644)
        self.assertTrue(self.checks(cfg, config_path=config)["config_file"].ok)

    def test_a_relay_backend_vendor_key_must_be_private_when_it_exists(self):
        cfg = self.cfg(backend="azure")
        self.assertTrue(self.checks(cfg)["vendor_key"].ok)                                  # a backend that needs no key has none
        key = self.secrets / "azure.key"
        key.write_text("k")
        os.chmod(key, 0o644)
        self.assertFalse(self.checks(cfg)["vendor_key"].ok)
        os.chmod(key, 0o600)
        self.assertTrue(self.checks(cfg)["vendor_key"].ok)
        self.assertNotIn("vendor_key", self.checks())                                       # the default whisper backend has no vendor key

    def test_audio_in_the_service_directories_fails_the_check(self):
        (self.logs / "debug.wav").write_bytes(b"RIFF....WAVE")
        check = self.checks()["no_audio_on_disk"]
        self.assertFalse(check.ok)
        self.assertIn("debug.wav", check.detail)

    def test_serve_refuses_to_start_when_a_check_fails(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}))
        os.chmod(self.secrets, 0o755)
        built = []
        with mock.patch.object(S, "harden_process"), mock.patch.object(S, "core_dumps_disabled", return_value=True):
            with self.assertRaises(S.StartupRefused) as raised:
                S.serve(config, backend_factory=lambda cfg: built.append(cfg) or FakeBackend())
        self.assertEqual([c.name for c in raised.exception.checks], ["secrets_dir"])
        self.assertEqual(built, [])                                                       # no model was loaded, no socket was opened

    def test_module_entry_point_and_usage(self):
        env = {**os.environ, "PYTHONPATH": str(REPO / "pipeline"), "PYTHONDONTWRITEBYTECODE": "1"}
        done = subprocess.run([sys.executable, "-m", "mcap.asr_server", "--help"], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 0)
        for word in ("serve", "token", "enroll-code", "audit", "selfcheck"):
            self.assertIn(word, done.stdout)
        missing = subprocess.run([sys.executable, "-m", "mcap.asr_server", "--config", str(self.root / "nope.json"), "selfcheck"],
                                 capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("cannot read the config file", missing.stderr)

    def test_cli_selfcheck_prints_checks_and_the_attest_hashes(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}))
        os.chmod(config, 0o644)
        out = io.StringIO()
        with mock.patch.object(S, "harden_process"), mock.patch.object(S, "core_dumps_disabled", return_value=True), contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "selfcheck"]), 0)
        self.assertIn("PASS bind", out.getvalue())
        self.assertIn(f"build_sha256 {S.build_sha256()}", out.getvalue())
        os.chmod(self.secrets, 0o755)
        out = io.StringIO()
        with mock.patch.object(S, "harden_process"), mock.patch.object(S, "core_dumps_disabled", return_value=True), contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "selfcheck", "--json"]), 1)
        self.assertFalse(next(c for c in json.loads(out.getvalue())["checks"] if c["name"] == "secrets_dir")["ok"])


def resource_module():
    import resource
    return resource


def shutil_rmtree(path):
    import shutil
    shutil.rmtree(path)


# ======================================================================================================================
class DailyAuditTests(ServerCase):
    def add(self, day, token_id, user, net, audio_s, machine_changed=False, status=200):
        ts = time.mktime((int(day[:4]), int(day[5:7]), int(day[8:10]), 12, 0, 0, 0, 0, -1))
        self.state.metalog.append({"ts": S._iso(ts), "user": user, "token_id": token_id, "op": "transcribe", "samples": int(audio_s * 16000),
                                   "audio_s": audio_s, "status": status, "queue_ms": 0, "dur_ms": 5, "engine": "whisper", "bytes_in": 10,
                                   "src_net": net, "machine_changed": machine_changed}, ts)

    def test_new_networks_spikes_machine_changes_and_first_use(self):
        for back in range(1, 6):                                                          # five quiet days of 'alice' from one network
            self.add(f"2026-10-{14 - back:02d}", "aaaaaaaa", "alice", "203.0.113.0/24", 1800.0)
        self.add("2026-10-14", "aaaaaaaa", "alice", "203.0.113.0/24", 1800.0)               # as usual
        self.add("2026-10-14", "aaaaaaaa", "alice", "198.51.100.0/24", 3 * 3600.0, machine_changed=True)     # new network, 3.5 h = 7x the baseline
        self.add("2026-10-14", "bbbbbbbb", "newbie", "192.0.2.0/24", 600.0)               # no history at all
        self.add("2026-10-14", "bbbbbbbb", "newbie", "192.0.2.0/24", 600.0, status=429)
        summary = S.daily_summary(self.state.metalog, "2026-10-14")
        self.assertEqual((summary["requests"], summary["audio_hours"]), (4, 3.83))
        self.assertEqual(summary["statuses"], {"200": 3, "429": 1})
        self.assertEqual(summary["new_networks"], [{"token_id": "aaaaaaaa", "user": "alice", "net": "198.51.100.0/24", "kind": "new-network"},
                                                   {"token_id": "bbbbbbbb", "user": "newbie", "net": "192.0.2.0/24", "kind": "first-use"}])
        self.assertEqual([(s["user"], s["hours"]) for s in summary["spikes"]], [("alice", 3.5)])
        self.assertEqual(summary["machine_changes"], [{"token_id": "aaaaaaaa", "user": "alice", "requests": 1}])
        text = S.render_daily(summary)
        self.assertIn("mcap-asr daily audit 2026-10-14", text)
        self.assertIn("NEW-NET aaaaaaaa alice 198.51.100.0/24", text)
        self.assertIn("FIRST-USE bbbbbbbb newbie 192.0.2.0/24", text)
        self.assertIn("SPIKE aaaaaaaa alice audio_h=3.50", text)
        self.assertIn("MACHINE aaaaaaaa alice requests=1", text)
        self.assertTrue(text.endswith("ALERTS 3"))                                         # first use is information, not an alert

    def test_a_token_without_history_spikes_only_at_six_hours(self):
        self.add("2026-10-14", "cccccccc", "heavy", "192.0.2.0/24", 7 * 3600.0)
        self.add("2026-10-14", "dddddddd", "light", "192.0.2.0/24", 3 * 3600.0)
        self.assertEqual([s["user"] for s in S.daily_summary(self.state.metalog, "2026-10-14")["spikes"]], ["heavy"])

    def test_cli_daily_default_day_json_and_bad_day(self):
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(self.secrets), "log_dir": str(self.logs)}))
        yesterday = S._day(time.time() - 86400)
        self.add(yesterday, "aaaaaaaa", "alice", "203.0.113.0/24", 3600.0)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "audit", "--daily"]), 0)
        self.assertIn(f"daily audit {yesterday}", out.getvalue())
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(S.main(["--config", str(config), "audit", "--daily", "--day", yesterday, "--json"]), 0)
        self.assertEqual(json.loads(out.getvalue())["requests"], 1)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(S.main(["--config", str(config), "audit", "--daily", "--day", "yesterday"]), 2)

    def test_an_empty_day_is_a_valid_summary(self):
        summary = S.daily_summary(self.state.metalog, "2026-01-01")
        self.assertEqual((summary["requests"], summary["users"], summary["spikes"]), (0, [], []))
        self.assertTrue(S.render_daily(summary).endswith("ALERTS 0"))


# ======================================================================================================================
class BackendFactoryTests(NoNetworkCase):
    def cfg(self, **over):
        return S.config_from_dict({"secrets_dir": str(self.root), "log_dir": str(self.root), **over})

    def register(self, name, cls):
        module = types.ModuleType(f"mcap_test_backend_{name}")
        module.Backend = cls
        sys.modules[module.__name__] = module
        self.addCleanup(sys.modules.pop, module.__name__, None)
        patcher = mock.patch.dict(asr_engines.REGISTRY, {name: f"{module.__name__}:Backend"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_default_backend_is_the_local_whisper_engine_not_loaded_and_never_downloading(self):
        engine = S.default_backend_factory(self.cfg())
        self.assertIsInstance(engine, WhisperEngine)
        self.assertEqual((engine.model, engine.allow_download, engine.path), (S.DEFAULT_MODEL, False, None))
        self.assertEqual(S.default_backend_factory(self.cfg(model="/models/large-v3")).model, "/models/large-v3")

    def test_unknown_backend_is_engine_unavailable(self):
        with self.assertRaises(asr_engines.EngineUnavailable):
            S.default_backend_factory(self.cfg(backend="nope"))
        with self.assertRaises(asr_engines.EngineUnavailable):
            S.default_backend_factory(self.cfg(backend="google"))          # a stub engine without an adapter

    def test_options_reach_a_plain_engine_class(self):
        seen = {}

        class Backend(Engine):
            def __init__(self, model, *, allow_download=True, device="auto", compute_type="float16"):
                seen.update(model=model, allow_download=allow_download, device=device, compute_type=compute_type)

        self.register("fastw", Backend)
        S.default_backend_factory(self.cfg(backend="fastw", model="large-v3", backend_options={"device": "cpu", "compute_type": "int8"}))
        self.assertEqual(seen, {"model": "large-v3", "allow_download": False, "device": "cpu", "compute_type": "int8"})

    def test_for_server_hook_builds_a_relay_backend(self):
        seen = {}

        class Backend(Engine):
            @classmethod
            def for_server(cls, options, *, model, secrets_dir):
                seen.update(options=options, model=model, secrets_dir=secrets_dir)
                return "built"

        self.register("relay", Backend)
        self.assertEqual(S.default_backend_factory(self.cfg(backend="relay", backend_options={"host": "x"})), "built")
        self.assertEqual(seen, {"options": {"host": "x"}, "model": "", "secrets_dir": str(self.root)})

    def test_vendor_key_comes_from_a_private_file_bound_to_host_and_port(self):
        from mcap import asr_creds
        self.addCleanup(asr_creds.install_source)
        secrets = self.root / "vault"
        secrets.mkdir()
        os.chmod(secrets, 0o700)
        host = "koreacentral.api.cognitive.microsoft.com"
        self.assertEqual(S.vendor_key_path(secrets, "azure"), str(secrets / "azure.key"))
        key = secrets / "azure.key"
        key.write_text("9f8e7d6c5b4a39281706f5e4d3c2b1a0\n")
        os.chmod(key, 0o600)
        source = S.install_vendor_key_source(secrets, "azure", host)
        with asr_creds.secret("azure", host, 443) as value:
            self.assertEqual(value, "9f8e7d6c5b4a39281706f5e4d3c2b1a0")
        with self.assertRaises(asr_creds.CredentialUnavailable) as other_host:
            with asr_creds.secret("azure", "evil.api.cognitive.microsoft.com", 443):
                pass
        self.assertEqual(other_host.exception.reason, "unbound")                           # the key can only go to its own host
        os.chmod(key, 0o644)
        with self.assertRaises(asr_creds.CredentialUnavailable) as loose:
            with asr_creds.secret("azure", host, 443):
                pass
        self.assertEqual(loose.exception.reason, "insecure")
        self.assertIsInstance(source, asr_creds.FileSource)

    def test_serve_runs_the_backend_through_its_life_cycle(self):
        secrets, logs = self.root / "s", self.root / "l"
        for d in (secrets, logs):
            d.mkdir()
            os.chmod(d, 0o700)
        config = self.root / "asr-server.json"
        config.write_text(json.dumps({"secrets_dir": str(secrets), "log_dir": str(logs), "listen": "127.0.0.1:0"}))
        backend = FakeBackend()
        served = []

        class Stub:
            server_address = ("127.0.0.1", 1234)

            def serve_forever(self):
                served.append("serving")

            def shutdown(self):
                pass

            def server_close(self):
                served.append("closed")

        with mock.patch.object(S, "harden_process"), mock.patch.object(S, "core_dumps_disabled", return_value=True), \
                mock.patch.object(S, "make_server", lambda state: Stub()), mock.patch.object(S.signal, "signal"), \
                mock.patch.object(apikey, "install_log_redaction"):
            S.serve(config, backend_factory=lambda cfg: backend)
        self.assertEqual((backend.loaded, backend.released, served), (1, 1, ["serving", "closed"]))


# ======================================================================================================================
class ServerTransport:
    """The in-process egress Transport: an EgressGuard request goes straight into handle_request, like http.client would put it on the wire."""

    def __init__(self, state, clock):
        self.state, self.clock, self.seen = state, clock, []

    def send(self, rule, method, target, headers, body, timeout):
        sent = dict(headers)
        if method in ("POST", "PUT"):
            sent["Content-Length"] = str(len(body))
        self.seen.append((method, target))
        status, out, data = S.handle_request(self.state, method, target, sent, body, self.clock.t)
        return Response(status=status, headers={k.lower(): v for k, v in out.items()}, body=data)


class EgressGuardIntegrationTests(ServerCase):
    """The real EgressGuard (W3) in front of the server core: what the client side validates and cleans is what the server accepts."""

    def setUp(self):
        super().setUp()
        self.tok = self.token("alice", ttl_days=10)                     # 10 days left: the window in which the client renews (14 days or less)
        self.transport = ServerTransport(self.state, self.clock)
        rule = HostRule(host="asr.example.internal", port=443, ca_pem_sha256="0" * 64, ca_file="/nonexistent-ca.pem")
        self.guard = EgressGuard({"asr.example.internal": rule}, engine_id="remote", consent_id="org:test", transport=self.transport,
                                 secrets=lambda: (self.tok,), trust="private")
        self.base = "https://asr.example.internal"

    def headers(self, **extra):
        self.sent = getattr(self, "sent", 0) + 1
        return {"Authorization": f"Bearer {self.tok}", "X-MCAP-Proto": S.PROTO, "X-MCAP-Idem": f"11111111-2222-4333-8444-{self.sent:012d}", **extra}

    def test_health_chunk_lid_vocab_and_renew_through_the_guard(self):
        health = self.guard.request("GET", self.base + "/v1/health?detail=1", headers=self.headers(), path_label="health")
        self.assertEqual(json.loads(health.body)["kind"], "server")
        vocab = {"terms": ["PACS"]}
        put = self.guard.request("PUT", f"{self.base}/v1/vocab/{S.canonical_vocab_digest(vocab)}", headers=self.headers(), body=S._dumps(vocab),
                                 path_label="vocab")
        self.assertEqual(put.status, 204)
        chunk = self.guard.request("POST", self.base + "/v1/chunk", body=pcm(8000), path_label="chunk", headers=self.headers(**{
            "Content-Type": "application/octet-stream", "X-MCAP-Samples": "8000", "X-MCAP-Lang": "ko", "X-MCAP-Prompt": "list",
            "X-MCAP-Vocab": S.canonical_vocab_digest(vocab), "X-MCAP-Chunk": "mic:0", "X-MCAP-Run": "0123456789abcdef",
            "X-MCAP-Client": "mcap/0.2.0", "X-MCAP-Machine": "d" * 16}))
        self.assertEqual(chunk.status, 200)
        self.assertEqual(json.loads(chunk.body)["text"], TEXT_CANARY)
        lid = self.guard.request("POST", self.base + "/v1/lid", body=pcm(16000), path_label="lid", headers=self.headers(**{
            "Content-Type": "application/octet-stream", "X-MCAP-Clips": "16000", "X-MCAP-Langs": "ko,en"}))
        self.assertEqual(json.loads(lid.body)["results"][0]["top"], "ko")
        renew = self.guard.request("POST", self.base + "/v1/token/renew", headers=self.headers(), body=b"", path_label="renew")
        self.assertEqual(renew.status, 200)
        self.assertEqual(len(self.transport.seen), 5)

    def test_the_guard_never_lets_the_error_text_through_as_its_own(self):
        bad = self.guard.request("POST", self.base + "/v1/purge", headers={**self.headers(), "Authorization": "Bearer mcap1_00000000_" + "A" * 32},
                                 body=b"", path_label="purge")
        self.assertEqual(bad.status, 401)


# ======================================================================================================================
class StubServer:
    """What the connection handler needs from its server."""

    def __init__(self, state):
        self.state, self.authenticated, self.left = state, 0, 0

    def mark_authenticated(self, handler):
        if handler.unauthenticated:
            handler.unauthenticated = False
            self.authenticated += 1
        return True                                           # (the real server says False when the token holds all the connections it may)

    def leave(self, handler):
        self.left += 1


class CountingServer(StubServer):
    """The connection handler's server with the REAL counters of ``_Server`` (total, unauthenticated, per token): what the sockets would
    count, without a socket."""

    def __init__(self, state):
        super().__init__(state)
        self._count_lock = threading.Lock()
        self.total = self.unauth = 0
        self.by_token = collections.Counter()

    token_connection_limit = S._Server.token_connection_limit
    mark_authenticated = S._Server.mark_authenticated
    leave = S._Server.leave


def read_to_eof(sock, timeout=10.0):
    sock.settimeout(timeout)
    data = b""
    while True:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            raise AssertionError("the server did not finish the answer")
        if not chunk:
            return data
        data += chunk


def split_answer(data):
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("ascii").split("\r\n")
    headers = dict(line.split(": ", 1) for line in lines[1:])
    return int(lines[0].split(" ")[1]), headers, body


class HandlerCase(ServerCase):
    """The HTTP front end through a socketpair (AF_UNIX: no network): framing, deadlines and the early answers."""

    def exchange(self, parts, *, finish=True):
        """Send each of ``parts`` (bytes, or a float for a pause), read the answer to EOF. Returns (status, headers, body, server)."""
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        server = StubServer(self.state)
        thread = threading.Thread(target=lambda: S._Handler(a, ("203.0.113.9", 4711), server), daemon=True)
        thread.start()
        for part in parts:
            if isinstance(part, float):
                time.sleep(part)
            else:
                b.sendall(part)
        data = read_to_eof(b)
        b.close()
        thread.join(15)
        self.assertFalse(thread.is_alive())
        status, headers, body = split_answer(data)
        return status, headers, body, server

    def head(self, method, path, token=None, **headers):
        pairs = {"X-MCAP-Proto": S.PROTO, **headers}
        if token:
            pairs["Authorization"] = f"Bearer {token}"
        return (f"{method} {path} HTTP/1.1\r\nHost: asr.test\r\n" + "".join(f"{k}: {v}\r\n" for k, v in pairs.items()) + "\r\n").encode()


class FrontEndTests(HandlerCase):
    def setUp(self):
        super().setUp()
        self.tok = self.token()

    def test_a_chunk_over_the_wire_format(self):
        body = pcm(8000)
        head = self.head("POST", "/v1/chunk", self.tok, **{"Content-Length": len(body), "Content-Type": "application/octet-stream",
                                                          "X-MCAP-Samples": 8000, "X-MCAP-Lang": "ko"})
        status, headers, answer, server = self.exchange([head + body[:100], 0.05, body[100:]])
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(answer)["text"], TEXT_CANARY)
        self.assertEqual((headers["Connection"], headers["Content-Type"], int(headers["Content-Length"])), ("close", "application/json", len(answer)))
        self.assertEqual((server.authenticated, server.left), (1, 1))

    def test_health_without_a_token_stays_unauthenticated_until_it_ends(self):
        status, _, answer, server = self.exchange([self.head("GET", "/v1/health")])
        self.assertEqual((status, json.loads(answer)["ok"], server.authenticated, server.left), (200, True, 0, 1))

    def test_204_has_no_body_and_no_length(self):
        obj = {"terms": ["PACS"]}
        body = S._dumps(obj)
        status, headers, answer, _ = self.exchange([self.head("PUT", "/v1/vocab/" + S.canonical_vocab_digest(obj), self.tok,
                                                              **{"Content-Length": len(body), "Content-Type": "application/json"}) + body])
        self.assertEqual((status, answer, "Content-Length" in headers), (204, b"", False))

    def test_smuggling_attempts_are_400_before_anything_is_computed(self):
        body = pcm(100)
        common = {"Content-Type": "application/octet-stream", "X-MCAP-Samples": 100}
        bad = {
            "transfer-encoding": self.head("POST", "/v1/chunk", self.tok, **common, **{"Transfer-Encoding": "chunked"}) + b"0\r\n\r\n",
            "two content-lengths": (self.head("POST", "/v1/chunk", self.tok, **common, **{"Content-Length": 200}).rstrip(b"\r\n")
                                    + b"\r\nContent-Length: 200\r\n\r\n" + body),
            "expect": self.head("POST", "/v1/chunk", self.tok, **common, **{"Content-Length": 200, "Expect": "100-continue"}),
            "upgrade": self.head("GET", "/v1/health", Upgrade="websocket"),
            "http/1.0": b"GET /v1/health HTTP/1.0\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n",
            "bare LF": b"GET /v1/health HTTP/1.1\nX-MCAP-Proto: mcap-asr/1\n\n\r\n\r\n",
            "folded header": b"GET /v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap-asr/1\r\n  folded\r\n\r\n",
            "space before colon": b"GET /v1/health HTTP/1.1\r\nX-MCAP-Proto : mcap-asr/1\r\n\r\n",
            "absolute target": b"GET http://evil.test/v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n",
            "lower-case method": b"get /v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n",
            "non-ascii": "GET /v1/health HTTP/1.1\r\nX-Note: 액미\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n".encode(),
            "control char": b"GET /v1/health HTTP/1.1\r\nX-Note: a\x01b\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n",
        }
        for name, raw in bad.items():
            with self.subTest(case=name):
                status, _, answer, _ = self.exchange([raw])
                self.assertEqual((status, json.loads(answer)["error"]["code"]), (400, "bad_request"))
        self.assertEqual(self.backend.calls, [])

    def test_headers_too_large_are_400(self):
        status, _, answer, _ = self.exchange([b"GET /v1/health HTTP/1.1\r\n" + b"X-Long: " + b"a" * 20000 + b"\r\n"])
        self.assertEqual(status, 400)
        many = b"GET /v1/health HTTP/1.1\r\n" + b"".join(b"X-H%d: 1\r\n" % i for i in range(70)) + b"\r\n"
        self.assertEqual(self.exchange([many])[0], 400)

    def test_413_and_401_are_answered_before_the_body_is_sent(self):
        huge = self.head("POST", "/v1/chunk", self.tok, **{"Content-Length": 5_000_000, "Content-Type": "application/octet-stream",
                                                          "X-MCAP-Samples": 2_500_000})
        status, _, answer, server = self.exchange([huge])                              # the client never sends the body
        self.assertEqual((status, json.loads(answer)["error"]["code"]), (413, "payload_too_large"))
        self.assertEqual(server.authenticated, 1)
        anonymous = self.head("POST", "/v1/chunk", None, **{"Content-Length": 32000, "Content-Type": "application/octet-stream",
                                                            "X-MCAP-Samples": 16000})
        status, headers, answer, server = self.exchange([anonymous])
        self.assertEqual((status, json.loads(answer)["error"]["code"], headers["WWW-Authenticate"], server.authenticated), (401, "unauthorized", "Bearer", 0))
        self.assertEqual(self.backend.calls, [])

    def test_busy_server_answers_at_once_without_reading_the_body(self):
        state = self.make_state(initial_service_s=600.0)
        tok = self.token("sam", state=state)
        gate = threading.Event()
        self.backend.gate = gate
        self.release_at_end(gate)
        self.spawn(self.chunk, tok, marker=1, state=state)
        self.assertTrue(self.backend.entered.acquire(timeout=10))
        self.state = state
        head = self.head("POST", "/v1/chunk", tok, **{"Content-Length": 32000, "Content-Type": "application/octet-stream", "X-MCAP-Samples": 16000})
        status, headers, answer, _ = self.exchange([head])
        self.assertEqual((status, json.loads(answer)["error"]["code"], headers["Retry-After"]), (503, "busy", "600"))

    def test_slow_headers_get_408(self):
        with mock.patch.object(S, "HEADER_DEADLINE_S", 0.3):
            status, _, answer, server = self.exchange([b"GET /v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap", 1.0])
        self.assertEqual((status, json.loads(answer)["error"]["code"]), (408, "request_timeout"))
        self.assertEqual(server.authenticated, 0)

    def test_slow_body_gets_408_and_nothing_is_computed(self):
        head = self.head("POST", "/v1/chunk", self.tok, **{"Content-Length": 32000, "Content-Type": "application/octet-stream", "X-MCAP-Samples": 16000})
        with mock.patch.object(S, "BODY_DEADLINE_S", 0.3):
            status, _, answer, _ = self.exchange([head + b"\x01" * 10, 1.0])
        self.assertEqual((status, json.loads(answer)["error"]["code"]), (408, "request_timeout"))
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(self.state.quotas.inflight[self.tok.split("_")[1]], 0)

    def test_a_connection_that_closes_without_a_request_is_quietly_dropped(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        server = StubServer(self.state)
        thread = threading.Thread(target=lambda: S._Handler(a, ("203.0.113.9", 4711), server), daemon=True)
        thread.start()
        b.close()
        thread.join(10)
        self.assertFalse(thread.is_alive())
        self.assertEqual(server.left, 1)

    def test_a_body_shorter_than_it_says_is_400_when_the_peer_hangs_up(self):
        head = self.head("POST", "/v1/chunk", self.tok, **{"Content-Length": 32000, "Content-Type": "application/octet-stream", "X-MCAP-Samples": 16000})
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        server = StubServer(self.state)
        thread = threading.Thread(target=lambda: S._Handler(a, ("203.0.113.9", 4711), server), daemon=True)
        thread.start()
        b.sendall(head + b"\x01" * 10)
        b.shutdown(socket.SHUT_WR)
        data = read_to_eof(b)
        b.close()
        thread.join(10)
        self.assertEqual(split_answer(data)[0], 400)


class ConnectionCapTests(HandlerCase):
    """One token holder must not be able to park the whole server on connections that sent a valid head and withhold the body: the
    unauthenticated-connection cap stops counting a connection once its token is accepted, so the token's own limit takes over."""

    def open_connection(self, server, head):
        """A connection whose peer sent ``head`` (a request head with a valid token) and nothing else. Returns (peer socket, thread)."""
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        thread = threading.Thread(target=lambda: S._Handler(a, ("203.0.113.9", 4711), server), daemon=True)
        thread.start()
        b.sendall(head)
        return b, thread

    def refused(self, server, head):
        """Send ``head`` on a new connection, read the answer, hang up. Returns (status, headers, body)."""
        server.total += 1
        server.unauth += 1
        peer, thread = self.open_connection(server, head)
        answer = split_answer(read_to_eof(peer))
        peer.close()                                                                     # the server lingers until the peer is gone
        thread.join(10)
        return answer

    def chunk_head(self, token, n=16000):
        return self.head("POST", "/v1/chunk", token, **{"Content-Length": 2 * n, "Content-Type": "application/octet-stream", "X-MCAP-Samples": n,
                                                       "X-MCAP-Lang": "ko"})

    def test_header_only_connections_of_one_token_stop_at_its_limit(self):
        tok = self.token("alice")
        other = self.token("sam")
        server = CountingServer(self.state)
        limit = self.state.cfg.per_token_concurrency + S.CONNECTION_MARGIN
        held = []
        for _ in range(limit):
            server.total += 1
            server.unauth += 1
            held.append(self.open_connection(server, self.chunk_head(tok)))
        self.wait_for(lambda: server.by_token[tok.split("_")[1]] == limit, "the held connections to be counted")
        self.assertEqual(server.unauth, 0)                                               # they no longer count as unauthenticated ...
        status, headers, body = self.refused(server, self.chunk_head(tok))              # ... so the next one is stopped by the TOKEN's limit
        self.assertEqual((status, json.loads(body)["error"]["code"], headers["Retry-After"]), (429, "quota_exceeded", "1"))
        self.assertEqual(server.by_token[tok.split("_")[1]], limit)                      # the refused one was never counted for the token
        self.assertEqual(self.refused(server, self.head("POST", "/v1/purge", other, **{"Content-Length": 0}))[0], 200)       # (answered, not refused)
        self.assertEqual(self.backend.calls, [])                                         # nothing was computed for any of it
        for sock, thread in held:                                                        # the holder gives up: the counters come back to zero
            sock.close()
            thread.join(15)
            self.assertFalse(thread.is_alive())
        self.assertEqual((server.by_token[tok.split("_")[1]], server.total, server.unauth), (0, 0, 0))
        self.assertNotIn(tok.split("_")[1], server.by_token)

    def test_a_refused_connection_is_logged_within_the_refusal_budget_and_never_read(self):
        tok = self.token("alice")
        server = CountingServer(self.state)
        server.by_token[tok.split("_")[1]] = self.state.cfg.per_token_concurrency + S.CONNECTION_MARGIN        # the token already holds them all
        statuses = []
        for _ in range(40):
            statuses.append(self.refused(server, self.chunk_head(tok))[0])
        self.assertEqual(set(statuses), {429})
        self.assertEqual(len([r for r in self.records() if r["user"] == "alice"]), S.LOG_REJECTS_PER_TOKEN)

    def test_the_limit_follows_the_concurrency_setting(self):
        state = self.make_state(per_token_concurrency=5)
        tok = self.token("alice", state=state)
        server = CountingServer(state)
        self.assertEqual(server.token_connection_limit(), 5 + S.CONNECTION_MARGIN)
        handlers = [types.SimpleNamespace(unauthenticated=True, token_id=tok.split("_")[1], counted_token=None) for _ in range(8)]
        accepted = [server.mark_authenticated(h) for h in handlers]
        self.assertEqual(accepted, [True] * 7 + [False])
        server.mark_authenticated(handlers[0])                                           # asking again for a counted connection changes nothing
        self.assertEqual(server.by_token[tok.split("_")[1]], 7)
        for h in handlers:
            server.leave(h)
        self.assertEqual((dict(server.by_token), server.unauth), ({}, 0))


class FrameUnitTests(NoNetworkCase):
    def test_parse_request_head(self):
        method, target, pairs = S.parse_request_head(b"POST /v1/chunk?a=1 HTTP/1.1\r\nHost: x\r\nX-A:  b c \r\nX-A: d")
        self.assertEqual((method, target, pairs), ("POST", "/v1/chunk?a=1", [("Host", "x"), ("X-A", "b c"), ("X-A", "d")]))     # a duplicate stays visible
        for raw in (b"GET / HTTP/1.1 extra", b"GET  / HTTP/1.1", b"GET / HTTP/2", b"GET v1 HTTP/1.1", b"G / HTTP/1.1", b"GET / HTTP/1.1\r\n:novalue",
                    b"GET / HTTP/1.1\r\nnocolon", b"GET / HTTP/1.1\r\n\r\nX: 1", b"A" * (S.MAX_HEAD_BYTES + 1)):
            with self.assertRaises(S.ApiError, msg=raw[:30]):
                S.parse_request_head(raw)

    def test_serialize_response(self):
        raw = S.serialize_response(429, {"Retry-After": "3", "Content-Length": "2"}, b"{}")
        self.assertEqual(raw, b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        self.assertTrue(S.serialize_response(599, {}, b"").startswith(b"HTTP/1.1 599 Status"))

    def test_read_helpers_honour_deadlines_and_eof(self):
        class Scripted:
            def __init__(self, items):
                self.items = list(items)

            def settimeout(self, value):
                self.timeout = value

            def recv(self, n):
                item = self.items.pop(0)
                if isinstance(item, BaseException):
                    raise item
                return item

        buf = bytearray()
        self.assertTrue(S._read_until(Scripted([b"GET / HT", b"TP/1.1\r\n\r\nrest"]), buf, b"\r\n\r\n", 1000, time.monotonic() + 5))
        self.assertTrue(bytes(buf).endswith(b"rest"))
        with self.assertRaises(S._Timeout):
            S._read_until(Scripted([socket.timeout()]), bytearray(), b"\r\n\r\n", 1000, time.monotonic() + 5)
        with self.assertRaises(S._Timeout):
            S._read_until(Scripted([]), bytearray(), b"\r\n\r\n", 1000, time.monotonic() - 1)
        self.assertFalse(S._read_until(Scripted([b""]), bytearray(), b"\r\n\r\n", 1000, time.monotonic() + 5))
        with self.assertRaises(S.ApiError):
            S._read_until(Scripted([b"x" * 600]), bytearray(), b"\r\n\r\n", 500, time.monotonic() + 5)
        self.assertEqual(S._read_exact(Scripted([b"ab", b"cd"]), bytearray(b"X"), 5, time.monotonic() + 5), b"Xabcd")
        with self.assertRaises(S.ApiError):
            S._read_exact(Scripted([b"ab", b""]), bytearray(), 5, time.monotonic() + 5)
        with self.assertRaises(S._Timeout):
            S._read_exact(Scripted([socket.timeout()]), bytearray(), 5, time.monotonic() + 5)

    def test_connection_counters_cap_unauthenticated_connections(self):
        server = object.__new__(S._Server)
        server._count_lock = threading.Lock()
        server.total = server.unauth = 0
        handlers = [types.SimpleNamespace(unauthenticated=True) for _ in range(S.MAX_UNAUTH_CONNECTIONS)]
        for _ in handlers:
            self.assertTrue(server.verify_request(None, None))
        self.assertFalse(server.verify_request(None, None))                          # the 17th unauthenticated connection is closed at once
        server.mark_authenticated(handlers[0])
        self.assertTrue(server.verify_request(None, None))                          # one authenticated: a slot is free again
        server.mark_authenticated(handlers[0])                                       # idempotent
        self.assertEqual(server.unauth, S.MAX_UNAUTH_CONNECTIONS)
        for handler in handlers:
            server.leave(handler)
        self.assertEqual((server.total, server.unauth), (1, 1))
        server.total = S.MAX_CONNECTIONS
        server.unauth = 0
        self.assertFalse(server.verify_request(None, None))


@unittest.skipUnless(importlib.util.find_spec("mcap.asr_http") is not None, "mcap.asr_http is not installed")
class ClientContractTests(ServerCase):
    """The health answer against the REAL client parser of W4 (asr_http.fetch_health, through EgressGuard and the in-process transport):
    what the server reports is what the client accepts, and each refusal of the protocol is one the client really makes."""

    def setUp(self):
        super().setUp()
        from mcap import asr_http
        self.asr_http = asr_http
        self.tok = self.token("alice")
        self.rule = HostRule(host="asr.example.internal", port=443, ca_pem_sha256="0" * 64, ca_file="/nonexistent-ca.pem")
        self.guard = EgressGuard({"asr.example.internal": self.rule}, engine_id="remote", consent_id="org:test", trust="private",
                                 transport=ServerTransport(self.state, self.clock))

    def headers(self, token=None):
        return {"Authorization": f"Bearer {token or self.tok}", "X-MCAP-Proto": S.PROTO, "X-MCAP-Idem": "00000000-0000-4000-8000-000000000001"}

    def test_health_is_accepted_for_the_matching_kind_and_attest(self):
        health = self.asr_http.fetch_health(self.guard, self.rule, self.headers(), backend_kind="server",
                                            attest_allow=[S.build_sha256()])
        self.assertTrue(health["ok"])
        self.assertEqual((health["proto"], health["kind"], health["supports_lid"], health["engine"]), (S.PROTO, "server", True, "whisper"))
        self.assertEqual((health["retention"]["mode"], health["retention"]["audio_disk"], health["retention"]["text_disk"]), ("none", False, False))
        self.assertEqual(health["limits"]["max_chunk_samples"], 496000)
        self.assertEqual(health["attest"]["build_sha256"], S.build_sha256())
        self.assertEqual(health["token"]["expires_in_days"], 90)

    def test_the_clients_refusals_are_real_ones(self):
        denied = asr_engines.EnginePolicyDenied
        with self.assertRaises(denied) as kind:
            self.asr_http.fetch_health(self.guard, self.rule, self.headers(), backend_kind="cloud")
        self.assertEqual(kind.exception.code, "kind")
        with self.assertRaises(denied) as attest:
            self.asr_http.fetch_health(self.guard, self.rule, self.headers(), attest_allow=["0" * 64])
        self.assertEqual(attest.exception.code, "attest")
        with self.assertRaises(denied) as empty:                                             # an empty allow list allows no build
            self.asr_http.fetch_health(self.guard, self.rule, self.headers(), attest_allow=[])
        self.assertEqual(empty.exception.code, "attest")
        with self.assertRaises(asr_engines.EngineAuthError):
            self.asr_http.fetch_health(self.guard, self.rule, self.headers("mcap1_00000000_" + "A" * 32))
        revoked = self.token("sam")
        self.state.tokens.update(lambda rows: (None, [r.update({"revoked": S._iso(self.clock.t)}) for r in rows if r["user"] == "sam"] and True))
        with self.assertRaises(asr_engines.EngineAuthError):
            self.asr_http.fetch_health(self.guard, self.rule, self.headers(revoked))
        wrong_proto = {**self.headers(), "X-MCAP-Proto": "mcap-asr/2"}
        with self.assertRaises(denied) as proto:
            self.asr_http.fetch_health(self.guard, self.rule, wrong_proto)
        self.assertEqual(proto.exception.code, "proto_mismatch")

    def test_a_cloud_backend_is_seen_as_cloud_and_a_retention_claim_is_a_refusal(self):
        backend = FakeBackend()
        backend.kind = "cloud"
        state = self.make_state(backend=backend)
        guard = EgressGuard({"asr.example.internal": self.rule}, engine_id="remote", consent_id="org:test", trust="private",
                            transport=ServerTransport(state, self.clock))
        tok = self.token("sam", state=state)
        self.assertEqual(self.asr_http.fetch_health(guard, self.rule, self.headers(tok), backend_kind="cloud")["kind"], "cloud")
        with self.assertRaises(asr_engines.EnginePolicyDenied):
            self.asr_http.fetch_health(guard, self.rule, self.headers(tok), backend_kind="server")
        self.assertEqual(self.asr_http.health_problems({"proto": S.PROTO, "ok": True, "retention": {"mode": "none"}, "kind": "server"}), [])
        problems = self.asr_http.health_problems({"proto": S.PROTO, "ok": True, "retention": {"mode": "ttl", "audio_disk": True}})
        self.assertIn("retention", problems)

    def test_error_answers_are_read_by_the_clients_parsers(self):
        busy = self.state.handle("POST", "/v1/chunk", {"X-MCAP-Proto": S.PROTO, "Authorization": f"Bearer {self.tok}",
                                                        "Content-Type": "audio/wav", "Content-Length": "0", "X-MCAP-Samples": "1"}, b"", self.clock.t)
        self.assertEqual(busy[0], 415)
        self.assertEqual(self.asr_http.error_info(busy[2]), ("unsupported_media_type", None))
        self.state.avg_service_s = 100.0
        self.state.queue.running = S.Job("transcribe", "x", b"", {}, 1.0, 0.0)           # an engine that has been busy: the next one waits 100 s
        answer = self.chunk(self.tok)
        self.state.queue.running = None
        headers = {k.lower(): v for k, v in answer.headers.items()}
        self.assertEqual(self.asr_http.error_info(answer.raw), ("busy", 100.0))
        self.assertEqual(self.asr_http.retry_after_seconds(headers, 100.0), 100.0)

    def test_a_successful_answer_survives_the_clients_cleaning_untouched(self):
        body = self.chunk(self.tok, lang="ko").json
        cleaned = self.asr_http.clean_result(body, 1.0)
        self.assertEqual((cleaned["text"], cleaned["language"], cleaned["truncated"], cleaned["avg_logprob"]), (TEXT_CANARY, "ko", False, -0.2))
        self.assertEqual(cleaned["segments"][0]["text"], TEXT_CANARY)
        self.assertEqual(cleaned["segments"][0]["compression_ratio"], 1.2)


if __name__ == "__main__":
    unittest.main()
