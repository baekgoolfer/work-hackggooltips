"""Test support for the external ASR engines (SPEC 18). Used by this package's tests and meant
for the tests of the later ones (the relay client, the Azure adapter, the pipeline lanes): everything here is a fake, nothing opens a
socket, reads the real Keychain or starts a process.

  * ``FakeTransport``: an in-process ``egress.Transport``. Scripted answers (a ``Response``, an exception, or a callable that gets the
    ``Call``), a handler for server logic, a default answer, every call recorded (``Call``: rule, method, target, headers, body, timeout).
    A real ``EgressGuard`` sits in front of it, so the host, port, header and size rules are the real ones.
  * ``FakeCloudEngine`` / ``FakeLocalEngine``: scriptable ``Engine`` doubles (an external engine and a Whisper-like local one) with the seam
    attributes of SPEC 18; behaviours are chunk results, exceptions or callables.
  * ``MiniRemoteEngine`` / ``MiniCloudEngine``: the smallest real ``HttpEngine`` adapters (a Bearer-token server engine ``remote``, a
    key-header cloud engine ``azure``); ``fake_registry()`` makes ``asr_engines.engine_class`` find them, so ``asr_router.build_engine`` can
    be tested before (or without) the real adapters.
  * ``make_decision`` / ``make_run``: an ``AsrDecision`` made by the real ``policy.decide_asr`` (so ``policy.is_issued`` holds) from a config,
    consents and a hardware verdict; ``consent_entry`` builds the consent of an engine.
  * ``FakeClock``, ``FakeSleep``, ``ClosableGate`` (a lane gate a test closes, also after N calls), ``json_response``, ``chunk_answer``,
    ``error_answer``, ``health_document``, ``usage_lines``, ``audio`` (a new array per call), ``AsrCase`` (a ``NoNetworkCase`` with a config,
    a clock, a transport, a gate and a stored token ready).
"""
from __future__ import annotations

import dataclasses
import json
import sys
import types
import unittest.mock as mock
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # pipeline/ on sys.path when run via discover

import numpy as np  # noqa: E402

from mcap import asr_creds, asr_engines, policy  # noqa: E402
from mcap.asr_engines import LID_CANDIDATES, Engine, restrict_lid  # noqa: E402
from mcap.asr_http import HttpEngine, pcm16, wav16  # noqa: E402
from mcap.egress import Response  # noqa: E402
from net_guard_support import NoNetworkCase  # noqa: E402
from notes_cli_support import make_cfg  # noqa: E402

HOST = "asr.example.internal"
AZURE_HOST = "koreacentral.api.cognitive.microsoft.com"
CA_SHA = "a" * 64
BUILD_SHA = "b" * 64
MACHINE = "m" * 64
NOW = datetime(2026, 10, 14, 12, 0, 0).astimezone()
TOKEN = "mcap1_0a1b2c3d_" + "Zq9xK" * 6 + "ab"                       # relay-token shaped
AZURE_KEY = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
# A hostile "server text" (CR/LF, a token shape, a transcript-like sentence): no state, log, usage line or error message may carry any of it.
CANARY_TEXT = "ZZCANARY-the patient Kim Minsu has chest pain\r\nX-Injected: 1\r\nmcap1_deadbeef_" + "Q" * 32
CANARY_FRAGMENTS = ("ZZCANARY", "Kim Minsu", "chest pain", "X-Injected", "mcap1_deadbeef")
SR = 16000


# ---------------------------------------------------------------------------------------------- time
class FakeClock:
    """``clock()`` -> seconds; ``advance(s)`` moves it. A ``FakeSleep`` bound to it advances it by what it is asked to sleep."""

    def __init__(self, start: float = 1000.0):
        self.now = float(start)

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += float(seconds)


class FakeSleep:
    """``sleep(seconds)`` that records the wait (``waits``), advances ``clock`` and runs ``on_sleep(seconds)`` (a test closes a gate there)."""

    def __init__(self, clock: Optional[FakeClock] = None, on_sleep: Optional[Callable[[float], None]] = None):
        self.waits: list[float] = []
        self.clock, self.on_sleep = clock, on_sleep

    def __call__(self, seconds: float) -> None:
        self.waits.append(float(seconds))
        if self.clock is not None:
            self.clock.advance(seconds)
        if self.on_sleep is not None:
            self.on_sleep(seconds)


# ---------------------------------------------------------------------------------------------- answers
def json_response(status: int = 200, doc: Any = None, headers: Optional[dict] = None, *, raw: Optional[bytes] = None) -> Response:
    """A ``Response`` with a JSON body (``doc``) or the exact bytes ``raw``."""
    body = raw if raw is not None else json.dumps({} if doc is None else doc).encode("utf-8")
    return Response(status, {"content-type": "application/json", **{k.lower(): v for k, v in (headers or {}).items()}}, body, 0, 0, 0)


def chunk_answer(text: str = "hello world", *, language: str = "en", duration: float = 2.0, prompt_text: Optional[str] = None,
                 numbers: bool = True, **extra) -> dict:
    """A ``POST /v1/chunk`` answer (docs/ASR_PROTOCOL.md 5.5): one segment; ``numbers=False`` gives the opaque-backend nulls."""
    seg = {"start": 0.0, "end": duration, "text": text, "avg_logprob": -0.2 if numbers else None,
           "no_speech_prob": 0.01 if numbers else None, "compression_ratio": 1.2 if numbers else None, "temperature": 0.0}
    doc = {"proto": "mcap-asr/1", "op": "transcribe", "engine": "whisper", "model": "mlx-community/whisper-large-v3-mlx@49e6aa28",
           "language": language, "text": text, "avg_logprob": -0.2 if numbers else None, "truncated": False, "segments": [seg]}
    if prompt_text is not None:
        doc["prompt_text"] = prompt_text
    doc.update(extra)
    return doc


def error_answer(status: int, code: str = "engine_error", *, retry_after: Optional[float] = None, message: str = "fixed text") -> Response:
    """An error answer (docs/ASR_PROTOCOL.md 6); ``retry_after`` goes into the header AND the body, ``message`` is the server's own text."""
    body: dict = {"error": {"code": code, "message": message}}
    headers = {}
    if retry_after is not None:
        body["error"]["retry_after_s"] = retry_after
        headers["Retry-After"] = str(retry_after)
    return json_response(status, body, headers)


def health_document(**override) -> dict:
    """A healthy ``GET /v1/health?detail=1`` answer of a whisper server; ``override`` replaces top-level keys."""
    doc = {"proto": "mcap-asr/1", "ok": True, "engine": "whisper", "model": "mlx-community/whisper-large-v3-mlx", "revision": "49e6aa28",
           "kind": "server", "supports_lid": True, "confidence": "logprob",
           "limits": {"sample_rate": 16000, "max_chunk_samples": 496000, "max_lid_clips": 12, "max_lid_clip_samples": 96000, "max_wait_s": 45,
                      "concurrency_per_token": 2},
           "retention": {"mode": "none", "audio_disk": False, "text_disk": False, "memory_cache_s": 120, "log_content": False},
           "attest": {"build_sha256": BUILD_SHA, "config_sha256": "c" * 64, "started": "2026-10-14T09:00:00+09:00", "hf_offline": True,
                      "core_dumps_disabled": True},
           "vendor": None, "token": {"expires_in_days": 71}, "queue": {"depth": 2, "avg_service_s": 4.1}}
    doc.update(override)
    return doc


# ---------------------------------------------------------------------------------------------- the transport
@dataclasses.dataclass
class Call:
    """What the guard handed to the transport (``rule`` is the ``HostRule``)."""
    rule: Any
    method: str
    target: str
    headers: dict
    body: bytes
    timeout: float

    @property
    def path(self) -> str:
        return self.target.split("?", 1)[0]

    def header(self, name: str) -> Optional[str]:
        low = name.lower()
        return next((v for k, v in self.headers.items() if k.lower() == low), None)

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


class FakeTransport:
    """An in-process ``Transport``. ``script`` items are consumed in order: a ``Response``, an exception (raised), or a callable that
    receives the ``Call`` and returns one of those. When the script is empty ``handler(call)`` answers, else ``default``. ``latency`` seconds
    are added to ``clock`` per call. ``calls`` records everything; ``on_send(call)`` runs before the answer (a test flips a gate in it)."""

    def __init__(self, *script, handler: Optional[Callable[[Call], Any]] = None, default: Optional[Response] = None,
                 clock: Optional[FakeClock] = None, latency: float = 0.0, on_send: Optional[Callable[[Call], None]] = None):
        self.script = list(script)
        self.handler = handler
        self.default = default if default is not None else json_response(200, chunk_answer())
        self.clock, self.latency, self.on_send = clock, latency, on_send
        self.calls: list[Call] = []

    def send(self, rule, method, target, headers, body, timeout):
        call = Call(rule, method, target, dict(headers), bytes(body), timeout)
        self.calls.append(call)
        if self.on_send is not None:
            self.on_send(call)
        if self.clock is not None and self.latency:
            self.clock.advance(self.latency)
        item = self.script.pop(0) if self.script else (self.handler if self.handler is not None else self.default)
        if callable(item) and not isinstance(item, Response):
            item = item(call)
        if isinstance(item, BaseException):
            raise item
        return dataclasses.replace(item) if isinstance(item, Response) else item

    def requests(self, prefix: Optional[str] = None) -> list[Call]:
        return [c for c in self.calls if prefix is None or c.path.startswith(prefix)]

    def paths(self) -> list[str]:
        return [c.path for c in self.calls]


# ---------------------------------------------------------------------------------------------- the lane gate
class ClosableGate:
    """A lane gate a test controls. Works as ``gate()`` (RoutedEngine, HttpEngine, the guard's pre_connect) and as ``gate(lane)``
    (``build_engine``): both answer None while open and a ``LaneBlock`` once closed. ``close()`` now, ``close_after(n)`` after n calls,
    ``open()`` again (the router's ratchet ignores that, as the real gate does within a run). ``calls`` counts every question."""

    def __init__(self, lane: str = "asr_remote"):
        self.lane = lane
        self.reason: Optional[str] = None
        self.calls = 0
        self._after: Optional[int] = None
        self._reason_after = "local_only"

    def close(self, reason: str = "local_only") -> None:
        self.reason = reason

    def open(self) -> None:
        self.reason, self._after = None, None

    def close_after(self, calls: int, reason: str = "local_only") -> None:
        """Answer open to the next ``calls`` questions, then closed."""
        self._after, self._reason_after = self.calls + calls, reason

    def __call__(self, *lane) -> Optional[policy.LaneBlock]:
        self.calls += 1
        if self._after is not None and self.calls > self._after:
            self.reason, self._after = self._reason_after, None
        if self.reason is None:
            return None
        name = lane[0] if lane and isinstance(lane[0], str) else self.lane
        return policy.LaneBlock(name, "lane_denied", self.reason, f"lane '{name}' is not allowed: {self.reason}")


# ---------------------------------------------------------------------------------------------- engine doubles
def result_for(text: str = "chunk text", *, language: str = "en", duration: float = 2.0, numbers: bool = True) -> dict:
    """What an engine returns for one chunk."""
    seg = {"start": 0.0, "end": duration, "text": text, "avg_logprob": -0.2 if numbers else None,
           "no_speech_prob": 0.01 if numbers else None, "compression_ratio": 1.2 if numbers else None, "temperature": 0.0}
    return {"text": text, "segments": [seg], "language": language, "avg_logprob": -0.2 if numbers else None}


class _Scripted(Engine):
    """Shared behaviour of the two doubles. ``behaviors`` (per ``transcribe_chunk`` call, in order; the last one repeats): a string (the
    text), a dict (the result), an exception instance or class (raised), a callable ``(audio, language, prompt) -> any of those``. Any
    further keyword argument becomes an attribute (``max_chunk_s=20.0``, ``chunk_params={...}``)."""

    def __init__(self, behaviors=("chunk text",), *, model: str = "fake-model", load_error: Any = None, release_error: Any = None, **attrs):
        super().__init__(model, allow_download=False)
        for name, value in attrs.items():         # any other keyword is an attribute of the double: max_chunk_s, chunk_params, progress_tag ...
            setattr(self, name, value)
        self.behaviors = list(behaviors) if isinstance(behaviors, (list, tuple)) else [behaviors]
        self.load_error, self.release_error = load_error, release_error
        self.calls: list[tuple] = []             # (n_samples, language, prompt)
        self.lid_calls = 0
        self.load_calls = 0
        self.release_calls = 0
        self.events: list[str] = []

    def load(self) -> None:
        self.load_calls += 1
        self.events.append("load")
        if self.load_error is not None:
            raise self.load_error() if isinstance(self.load_error, type) else self.load_error

    def _next(self, audio, language, prompt):
        index = len(self.calls) - 1
        item = self.behaviors[min(index, len(self.behaviors) - 1)]
        if callable(item) and not isinstance(item, type) and not isinstance(item, BaseException):
            item = item(audio, language, prompt)
        if isinstance(item, type) and issubclass(item, BaseException):
            item = item()
        if isinstance(item, BaseException):
            raise item
        return result_for(item) if isinstance(item, str) else item

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append((len(audio), language, prompt))
        self.events.append("chunk")
        return self._next(audio, language, prompt)

    def release(self) -> None:
        self.release_calls += 1
        self.events.append("release")
        if self.release_error is not None:
            raise self.release_error


class FakeLocalEngine(_Scripted):
    """A Whisper-like local engine: uses the prompt, has a tokenizer and prompt frames, supports language ID, sends nothing."""
    name = "fake-local"
    engine_id = "whisper"
    kind = "local"
    supports_lid = True
    uses_prompt = True
    prompt_frames = {"ko": "KO-FRAME: ", "en": "EN-FRAME: "}

    def __init__(self, behaviors=("local text",), **kw):
        kw.setdefault("model", "fake-whisper")
        super().__init__(behaviors, **kw)

    @property
    def tokenizer(self):
        return types.SimpleNamespace(encode=lambda text: text.split())

    def detect_languages(self, clips, languages=LID_CANDIDATES):
        self.lid_calls += 1
        return [restrict_lid({"ko": 0.2, "en": 0.8}, languages) for _ in clips]


class FakeCloudEngine(_Scripted):
    """An external engine (server or cloud): no prompt, opaque or logprob confidence, optional language ID. Counts what it 'sent' like an
    ``HttpEngine`` does (``usage()``), never opens a socket. ``bind_breaker`` records the breaker the router gave it."""
    name = "fake-cloud"
    engine_id = "fake-cloud"
    uses_prompt = False
    confidence = "opaque"

    def __init__(self, behaviors=("cloud text",), *, kind: str = "cloud", engine_id: Optional[str] = None, supports_lid: bool = False,
                 residency: str = "kr", label: Optional[str] = None, consent_id: str = "c-fake", seconds: float = 2.0, **kw):
        kw.setdefault("model", "fake-cloud-model")
        super().__init__(behaviors, **kw)
        self.kind, self.supports_lid, self.residency = kind, supports_lid, residency
        if engine_id:
            self.engine_id = engine_id
        self.label = label or ("company-asr" if kind == "server" else f"{self.engine_id}/kr")
        self.consent_id = consent_id
        self.seconds = seconds
        self.breaker = None
        self._requests = 0
        self._lid = 0

    def bind_breaker(self, breaker) -> None:
        self.breaker = breaker

    def transcribe_chunk(self, audio, language, prompt):
        self._requests += 1                      # a request that was attempted may have reached the server, answered or not
        return super().transcribe_chunk(audio, language, prompt)

    def detect_languages(self, clips, languages=LID_CANDIDATES):
        self._lid += 1
        self.lid_calls += 1
        return [restrict_lid({"ko": 0.9, "en": 0.1}, languages) for _ in clips]

    def usage(self) -> dict:
        return {"requests": self._requests, "lid_requests": self._lid, "audio_s": round(self._requests * self.seconds, 1),
                "bytes": self._requests * int(self.seconds * 32000)}

    def sent_anything(self) -> bool:
        return bool(self._requests or self._lid)

    def destination_label(self) -> str:
        return self.label

    def provenance(self) -> dict:
        return {"schema": 1, "engine": self.engine_id, "model": self.model, "kind": self.kind, "privacy": self.kind if self.sent_anything() else "local",
                "destination": self.label, "chunks": {self.engine_id: len(self.calls)}, "sent": self.usage()}


# ---------------------------------------------------------------------------------------------- minimal real HttpEngine adapters
class MiniRemoteEngine(HttpEngine):
    """The smallest ``remote`` adapter: ``POST /v1/chunk`` with the raw PCM, a fresh ``X-MCAP-Idem`` per logical request, Bearer token."""
    engine_id = "remote"

    def __init__(self, *args, **kw):
        super().__init__(*args, **kw)
        self.built = 0
        self.idems: list[str] = []
        self.recovered = 0
        self.recover_with = False

    def common_headers(self) -> dict:
        idem = str(uuid.uuid4())
        self.idems.append(idem)
        return {"X-MCAP-Proto": "mcap-asr/1", "X-MCAP-Idem": idem}

    def build_request(self, chunk, language) -> tuple:
        self.built += 1
        return ("POST", "/v1/chunk", {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(len(chunk)),
                                      "X-MCAP-Lang": language or "auto"}, pcm16(chunk))

    def parse_response(self, status, body) -> dict:
        return json.loads(body.decode("utf-8"))

    def recover(self, status, code) -> bool:
        self.recovered += 1
        return self.recover_with and code == "vocab_unknown"


class MiniCloudEngine(HttpEngine):
    """The smallest ``azure`` adapter: the WAV in the body, the key in ``Ocp-Apim-Subscription-Key``."""
    engine_id = "azure"

    def build_request(self, chunk, language) -> tuple:
        return ("POST", "/speechtotext/transcriptions:transcribe?api-version=2025-10-15", {"Content-Type": "audio/wav"}, wav16(chunk))

    def parse_response(self, status, body) -> dict:
        return json.loads(body.decode("utf-8"))

    def auth_headers(self) -> dict:
        return {"Ocp-Apim-Subscription-Key": self.secret()}


def fake_registry():
    """``with fake_registry():`` -> ``asr_engines.engine_class("remote")`` is ``MiniRemoteEngine`` and ``("azure")`` ``MiniCloudEngine``."""
    return mock.patch.dict(asr_engines.REGISTRY, {"remote": f"{__name__}:MiniRemoteEngine", "azure": f"{__name__}:MiniCloudEngine"})


# ---------------------------------------------------------------------------------------------- consents and decisions
def consent_entry(engine: str = "remote", **kw) -> policy.ConsentEntry:
    """The consent of ``engine`` as ``mcap asr-engines consent`` would have written it (use both, valid, this fake machine)."""
    base = dict(id=f"c-{engine}", engine=engine, kind="server" if engine == "remote" else "cloud", host=HOST if engine == "remote" else AZURE_HOST,
                port=443, region="" if engine == "remote" else "koreacentral", model="" if engine == "remote" else "fast-transcription",
                protocol="mcap-asr/1" if engine == "remote" else "azure-fast-transcription",
                backend_kind="server" if engine == "remote" else "cloud", use="both", machine=MACHINE,
                granted_at="2026-10-01T09:00:00+09:00", granted_by="tty", expires="2027-10-14", ca_sha256=CA_SHA if engine == "remote" else None)
    base.update(kw)
    return policy.ConsentEntry(**base)


def asr_cfg(root, **overrides):
    """A config whose every path is under ``root`` (``notes_cli_support.make_cfg``) set up for the relay: the URL, a CA file name, short
    waits, the cap high. ``overrides`` win."""
    values = dict(asr_remote_url=f"https://{HOST}", asr_remote_ca_file=Path(root) / "relay-ca.pem", asr_cloud_daily_minutes=240,
                  asr_retry_max=3, asr_request_timeout_s=90, asr_remote_max_wait_s=120, asr_circuit_fails=3, asr_circuit_cooldown_s=120)
    values.update(overrides)
    return make_cfg(root, **values)


def make_decision(cfg, primary: str = "remote", fallback: str = "none", *, consents=("remote",), capable: Optional[bool] = True,
                  local_only: bool = False, org=None, used_minutes: float = 0.0) -> policy.AsrDecision:
    """The decision ``policy.decide_asr`` makes for ``cfg`` with ``ASR_ENGINE=primary``, ``ASR_FALLBACK=fallback`` and a valid consent for each
    engine in ``consents`` (an engine id, built by ``consent_entry``, or a ready ``ConsentEntry``), on a Mac whose local capability is
    ``capable``. ``org`` is an ``OrgPolicy`` (default: none)."""
    run_cfg = dataclasses.replace(cfg, asr_engine=primary, asr_fallback=fallback)
    entries = tuple(c if isinstance(c, policy.ConsentEntry) else consent_entry(c) for c in consents)
    return policy.decide_asr(run_cfg, org if org is not None else policy.absent_policy(), policy.LocalOnly(local_only, "session"),
                             policy.ConsentSet(entries=entries, machine=MACHINE), types.SimpleNamespace(capable=capable), now=NOW,
                             used_minutes_today=used_minutes)


def make_run(cfg, primary: str = "remote", fallback: str = "none", **kw):
    """``(run_cfg, decision)``: the config with ``asr_decision`` set, as ``RunPrivacy.cfg_for_asr`` would hand it to ``asr.py``."""
    decision = make_decision(cfg, primary, fallback, **kw)
    return dataclasses.replace(cfg, asr_engine=primary, asr_fallback=fallback, asr_decision=decision), decision


def usage_lines(cfg) -> list:
    """The lines of ``asr-usage.jsonl`` as dicts (empty when there is no file)."""
    path = cfg.asr_usage_path
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()] if path.exists() else []


def audio(seconds: float = 2.0, value: float = 0.1) -> np.ndarray:
    """A new float32 mono 16 kHz array each call (the router recognises a retry of a chunk by the identity of the array)."""
    return np.full(int(seconds * SR), value, dtype=np.float32)


# ---------------------------------------------------------------------------------------------- the base case
class AsrCase(NoNetworkCase):
    """``NoNetworkCase`` plus what an engine test needs: ``self.cfg`` (``asr_cfg``), ``self.clock``, ``self.sleep`` (bound to the clock),
    ``self.transport`` (a ``FakeTransport`` with the clock), ``self.gate`` (a ``ClosableGate``, open), the relay token stored in the fake
    Keychain (``self.store_token``) and ``apikey``'s remembered secrets cleared afterwards."""

    def setUp(self) -> None:
        super().setUp()
        from mcap import apikey
        self.addCleanup(apikey._known.clear)
        self.addCleanup(asr_creds.install_source)
        self.cfg = asr_cfg(self.root)
        self.clock = FakeClock()
        self.sleep = FakeSleep(self.clock)
        self.transport = FakeTransport(clock=self.clock)
        self.gate = ClosableGate()
        self.store_token()

    def store_token(self, value: str = TOKEN, engine: str = "remote", host: str = HOST, port: int = 443) -> None:
        self.security.store_item(value, asr_creds.service_name(engine), asr_creds.account_name(host, port))

    def run_cfg(self, primary: str = "remote", fallback: str = "none", **kw):
        return make_run(self.cfg, primary, fallback, **kw)
