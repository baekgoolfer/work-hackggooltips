"""The shared half of every external ASR engine: requests, retries, the credential, the daily cap, usage records and the health check
(docs/ASR_PROTOCOL.md 5.1, 6, 7; SPEC 18).

``HttpEngine`` is the base class of ``asr_remote.RemoteEngine`` (the company relay, kind ``server``) and ``asr_azure.AzureFastEngine`` (kind
``cloud``). An adapter declares what it is (``engine_id``, ``kind``, ``residency``, ``uses_prompt`` ...) and writes two PURE functions::

    build_request(chunk, language) -> (method, path, headers, body)    # chunk: float32 mono 16 kHz; body from pcm16() / wav16(); path starts with "/"
    parse_response(status, body) -> {"text", "segments", "language", "avg_logprob", ...}   # only called for a 2xx answer

Everything else is here, once: the URL (``https://<host of the decision>[:port]`` + path; the adapter never names a host), the per-attempt lane
gate, the credential, the retry policy, the usage line, the cap, the clean-up of what a server answered. An adapter must not open a socket
(only ``EgressGuard`` does), must not read the Keychain (``auth_headers`` does) and must not write a file. Optional hooks: ``common_headers``
(once per logical request: the place for ``X-MCAP-Idem``, so every retry of one request carries the same key), ``auth_headers`` (Bearer by
default; Azure sends ``Ocp-Apim-Subscription-Key``), ``recover`` (a 4xx the adapter can fix, e.g. 404 vocab_unknown: PUT the vocabulary and the
same request is sent once more), ``price_per_hour``, ``destination_label``.

Retry policy of ``exchange`` (docs/ASR_PROTOCOL.md 6 and 7, SPEC 18 ASR_RETRY_MAX): at most ``ASR_RETRY_MAX`` attempts. A connection
error, TLS error or timeout is retried after 1.0 s, then 2.5 s (each +-20% jitter). 429 and 503 wait ``Retry-After`` (each wait at most 60 s;
without the header the same 1.0 / 2.5 s). 408 and the other 5xx get ONE retry. Any other 4xx is not retried (``EngineHttpError``), except what
``recover`` fixes. The total time of one request (answers and waits) is bounded by ``ASR_REMOTE_MAX_WAIT_S``. 401/403 are
``EngineAuthError``, 426 and every ``EgressDenied`` (host, port, redirect, an oversized answer, a closed gate) are ``EnginePolicyDenied``,
whatever else ends a request is ``EngineTransient`` once the attempts are used. BEFORE every attempt, also after a sleep, the lane gate is read
again (``gate``, and the guard's ``pre_connect`` right before the socket): a meeting switched to local-only while the engine waits sends
nothing more. The Keychain is read only after that gate said yes (SPEC 18), lazily, once per engine lifetime, and the value lives in
memory only until ``release()``.

What an error carries: a fixed sentence and, as attributes, ``status`` (HTTP status or None) and ``code`` (a short word the server gave in its
error body, only if it looks like one, else None). Never the server's text, a header value, the URL or the credential.

Usage lines (``asr_usage.record``) are written HERE, one per attempt; build the guard of an ``HttpEngine`` without its own ``usage`` callback
(``asr_router.build_engine`` does) or every attempt is counted twice.

``fetch_health`` / ``HttpEngine.check_health`` implement the health check of docs/ASR_PROTOCOL.md 5.1 and the refusals of SPEC 18.
"""
from __future__ import annotations

import json
import logging
import math
import numbers
import random
import re
import struct
import subprocess
import threading
import time
from typing import Any, Callable, Mapping, Optional

import numpy as np

from . import asr_creds, asr_usage, wavio
from . import usage as claude_usage
from .asr_engines import (SR, Engine, EngineAuthError, EngineCapReached, EngineError, EnginePolicyDenied, EngineTransient)
from .egress import EgressDenied, EgressError, EgressViolation, Response, ca_bound
from .policy import ENGINE_META, HostRule

log = logging.getLogger("mcap.asr")

PROTOCOL = "mcap-asr/1"
RETRY_DELAYS = (1.0, 2.5)           # seconds before the 2nd and the 3rd attempt (docs/ASR_PROTOCOL.md 7), +-JITTER
JITTER = 0.2
RETRY_AFTER_CAP_S = 60.0            # one Retry-After wait is never longer than this
SERVER_ERROR_RETRIES = 1            # 408 and 5xx other than 503: one retry
HEALTH_TIMEOUT_S = 5.0              # the health check must answer within this (a black-holed host cannot burn minutes)
DATA_OPS = ("chunk", "lid", "vocab")   # requests that carry meeting data (audio, vocabulary): what makes a destination "touched"
PROMPT_TEXTS_MAX = 4                # distinct prompt texts kept for the echo guard (one per language frame)
PROMPT_TEXT_CHARS = 4000
MAX_SEGMENTS = 200                  # of one chunk answer
MAX_SEGMENT_CHARS = 8000
TEXT_CHARS = 120

_CODE = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
_REASON = re.compile(r"[a-z0-9][a-z0-9_:\-]{0,39}\Z")
_HEX_RUN = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{16,}(?![0-9A-Za-z])")


# ---------------------------------------------------------------------------------- errors
class EngineHttpError(EngineError):
    """The server answered with a status that is neither a success nor worth another attempt (a 4xx other than 401/403/426/408/429, or one
    the adapter could not fix). ``status`` is the HTTP status, ``code`` the short word of the server's error body (or None). It is NOT a
    router trigger: the chunk fails, the circuit is not touched (a content or client problem, not an unreachable engine)."""
    retryable = False

    def __init__(self, status: int, code: Optional[str] = None):
        self.status = status
        self.code = code
        super().__init__(f"the server refused the request (HTTP {int(status)}" + (f", {code}" if code else "") + ")")


def _fail(cls, message: str, status: Optional[int] = None, code: Optional[str] = None):
    """An engine error with the fixed ``message`` and the ``status`` / ``code`` attributes every error of this module has."""
    exc = cls(message)
    exc.status = status
    exc.code = code
    return exc


# ---------------------------------------------------------------------------------- audio
def pcm16(audio) -> bytes:
    """Mono audio (float32 in [-1, 1], clipped; or int16) as raw little-endian int16 bytes: the body of ``POST /v1/chunk``. The conversion
    is ``wavio.to_int16`` (the one the pipeline writes its own WAV files with): NaN is 0, +-1.0 clips to 32767 / -32768."""
    x = np.asarray(audio)
    if x.ndim != 1:
        raise ValueError("pcm16 expects a 1-D (mono) array")
    return wavio.to_int16(x).tobytes()


def wav16(audio, sample_rate: int = SR) -> bytes:
    """Mono audio as a complete RIFF/WAVE file, 16-bit PCM (the ``audio`` part of Azure's multipart request). 44-byte canonical header."""
    data = pcm16(audio)
    rate = int(sample_rate)
    if not 1000 <= rate <= 192000:
        raise ValueError("unusable sample rate")
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(data), b"WAVE", b"fmt ", 16, 1, 1, rate, rate * 2, 2, 16, b"data", len(data))
    return header + data


# ---------------------------------------------------------------------------------- what a server said (never copied as text)
def _clean_text(value: Any, limit: int = TEXT_CHARS) -> Optional[str]:
    """A string on one line, capped; None for a non-string. Server text only ever gets here to be shown as a model name or a status."""
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:limit]


def _finite(value: Any, *, minimum: Optional[float] = None) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return None
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return None
    if not math.isfinite(number) or (minimum is not None and number < minimum):
        return None
    return number


def error_info(body: Any) -> tuple:
    """``(code, retry_after_s)`` from an error body ``{"error": {"code": "busy", "retry_after_s": 3}}``: the code only when it is a short
    lower-case word, the number only when finite and non-negative; (None, None) for anything else. The ``message`` is never read."""
    try:
        doc = json.loads(bytes(body)[:8192].decode("utf-8"))
    except (ValueError, TypeError):
        return None, None
    err = doc.get("error") if isinstance(doc, dict) else None
    if not isinstance(err, dict):
        return None, None
    code = err.get("code")
    return (code if isinstance(code, str) and _CODE.fullmatch(code) else None), _finite(err.get("retry_after_s"), minimum=0.0)


def retry_after_seconds(headers: Mapping, body_hint: Optional[float] = None) -> Optional[float]:
    """The ``Retry-After`` header in seconds (names are lower case, as ``EgressGuard`` returns them); an HTTP-date or garbage is ignored and
    ``body_hint`` (``retry_after_s`` of the error body) is used instead. Never negative."""
    raw = headers.get("retry-after") if isinstance(headers, Mapping) else None
    if raw is not None:
        try:
            value = float(str(raw).strip())
        except ValueError:
            value = None
        if value is not None and math.isfinite(value):
            return max(0.0, value)
    return body_hint


def path_label(path: str) -> str:
    """A content-free label of a request path for the guard's usage hook: no query, long hex runs (a vocabulary digest) replaced."""
    base = str(path).split("?", 1)[0]
    return _HEX_RUN.sub("{id}", base)[:40] or "-"


def clean_result(result: Any, chunk_s: float) -> dict:
    """What an adapter's ``parse_response`` returned, made safe for the chunk loop of ``asr.py`` (which indexes ``start`` / ``end`` /
    ``text`` of every segment): segments that are not dicts with a finite start and end and a string text are dropped, times are clamped to
    the chunk (a negative one becomes 0), the text is bounded, numbers that are not finite become None, the language is a short word. ``EngineTransient`` when the
    answer is not a dict with a ``segments`` list. A hostile or broken server therefore cannot crash a track or inject a huge string."""
    if not isinstance(result, dict) or not isinstance(result.get("segments"), list):
        raise _fail(EngineTransient, "the engine answer could not be used")
    limit = max(float(chunk_s), 0.0) + 1.0
    segments = []
    for raw in result["segments"][:MAX_SEGMENTS]:
        if not isinstance(raw, dict) or not isinstance(raw.get("text"), str):
            continue
        start, end = _finite(raw.get("start")), _finite(raw.get("end"))
        if start is None or end is None:
            continue
        start = min(max(start, 0.0), limit)                   # a slightly negative time is clamped, not a reason to lose the text
        end = max(end, 0.0)
        segments.append({
            "start": start, "end": min(max(end, start), limit), "text": raw["text"][:MAX_SEGMENT_CHARS],
            "avg_logprob": _finite(raw.get("avg_logprob")), "no_speech_prob": _finite(raw.get("no_speech_prob")),
            "compression_ratio": _finite(raw.get("compression_ratio")), "temperature": _finite(raw.get("temperature")) or 0.0,
        })
    language = _clean_text(result.get("language"), 16)
    text = result.get("text")
    out = {"text": text[:MAX_SEGMENT_CHARS * 4] if isinstance(text, str) else " ".join(s["text"] for s in segments),
           "segments": segments, "language": language or None, "avg_logprob": _finite(result.get("avg_logprob")),
           "truncated": bool(result.get("truncated", False))}
    seen = result.get("prompt_text")
    if isinstance(seen, str) and seen.strip():
        out["prompt_text"] = seen[:PROMPT_TEXT_CHARS]
    return out


# ---------------------------------------------------------------------------------- health (docs/ASR_PROTOCOL.md 5.1)
def _health_url(rule: HostRule, path: str) -> str:
    return f"https://{rule.host}" + ("" if int(rule.port) == 443 else f":{int(rule.port)}") + path


def parse_health(body: Any) -> dict:
    """The health answer reduced to the fields the client uses, each checked (strings one line and capped, numbers finite, booleans real
    booleans); a field of the wrong type is dropped, never coerced. ``EngineTransient`` when the answer is not a JSON object with a string
    ``proto``: an unreadable answer is a server that is not well right now, not a verdict about it."""
    try:
        doc = json.loads(bytes(body).decode("utf-8"))
    except (ValueError, TypeError):
        raise _fail(EngineTransient, "the health answer is not valid JSON") from None
    if not isinstance(doc, dict) or not isinstance(doc.get("proto"), str):
        raise _fail(EngineTransient, "the health answer is not a health document")

    def sub(name: str) -> dict:
        value = doc.get(name)
        return value if isinstance(value, dict) else {}

    def flag(source: dict, key: str) -> Optional[bool]:
        return source[key] if isinstance(source.get(key), bool) else None

    limits = {k: n for k, v in sub("limits").items() if isinstance(k, str) and _CODE.fullmatch(k) and (n := _finite(v, minimum=0.0)) is not None}
    retention, attest, vendor = sub("retention"), sub("attest"), doc.get("vendor")
    out = {
        "proto": _clean_text(doc["proto"], 32), "ok": doc.get("ok") is True,
        "engine": _clean_text(doc.get("engine")), "model": _clean_text(doc.get("model")), "revision": _clean_text(doc.get("revision")),
        "kind": _clean_text(doc.get("kind"), 16), "supports_lid": flag(doc, "supports_lid"), "confidence": _clean_text(doc.get("confidence"), 16),
        "limits": limits,
        "retention": {"mode": _clean_text(retention.get("mode"), 16), "audio_disk": flag(retention, "audio_disk"),
                      "text_disk": flag(retention, "text_disk"), "memory_cache_s": _finite(retention.get("memory_cache_s"), minimum=0.0),
                      "log_content": flag(retention, "log_content")},
        "attest": {"build_sha256": (_clean_text(attest.get("build_sha256"), 64) or "").lower() or None,
                   "config_sha256": (_clean_text(attest.get("config_sha256"), 64) or "").lower() or None,
                   "started": _clean_text(attest.get("started"), 40), "hf_offline": flag(attest, "hf_offline"),
                   "core_dumps_disabled": flag(attest, "core_dumps_disabled")},
        "vendor": ({"name": _clean_text(vendor.get("name"), 40), "region": _clean_text(vendor.get("region"), 40),
                    "verified": vendor.get("verified") is True} if isinstance(vendor, dict) else None),
        "token": {"expires_in_days": _finite(sub("token").get("expires_in_days"))},
        "queue": {k: n for k in ("depth", "avg_service_s") if (n := _finite(sub("queue").get(k), minimum=0.0)) is not None},
    }
    return out


def health_problems(health: Mapping, *, backend_kind: Optional[str] = None, attest_allow=None, protocol: str = PROTOCOL) -> list:
    """Why a parsed health document must be refused, as short codes (empty list: accepted): ``proto`` (not the protocol this client
    speaks), ``not-ok``, ``retention`` (mode is not "none", or the server says audio or text is kept on disk), ``kind`` (the server's
    backend kind is not the one the consent was given for; only when ``backend_kind`` is given), ``attest`` (the build hash is not in the
    organisation's allow list; only when ``attest_allow`` is given: an EMPTY list allows no build). The server's own words never enter a code."""
    problems = []
    if health.get("proto") != protocol:
        problems.append("proto")
    if health.get("ok") is not True:
        problems.append("not-ok")
    retention = health.get("retention") if isinstance(health.get("retention"), Mapping) else {}
    if retention.get("mode") != "none" or retention.get("audio_disk") is True or retention.get("text_disk") is True:
        problems.append("retention")
    if backend_kind is not None and health.get("kind") != backend_kind:
        problems.append("kind")
    if attest_allow is not None:
        attest = health.get("attest") if isinstance(health.get("attest"), Mapping) else {}
        allowed = {str(x).strip().lower() for x in attest_allow}
        if attest.get("build_sha256") not in allowed:
            problems.append("attest")
    return problems


def _health_error(status: int) -> EngineError:
    """The exception for a health answer that is not a 200: auth, a protocol mismatch, an unwell server, or a host that is not an mcap-asr
    server at all."""
    if status in (401, 403):
        return _fail(EngineAuthError, f"the server refused the credential (HTTP {status})", status)
    if status == 426:
        return _fail(EnginePolicyDenied, "the server does not speak this protocol (HTTP 426)", status, "proto_mismatch")
    if status in (408, 429) or status >= 500:
        return _fail(EngineTransient, f"the server is not available (HTTP {status})", status)
    return _fail(EnginePolicyDenied, f"the host does not answer like an mcap-asr server (HTTP {status})", status)


def _map_egress(exc: EgressError) -> EngineError:
    """EgressDenied / EgressViolation -> this destination is not permitted; any other EgressError -> try again or fall back."""
    if isinstance(exc, (EgressDenied, EgressViolation)):
        return _fail(EnginePolicyDenied, f"the destination is not permitted ({exc.code})", exc.status, exc.code)
    return _fail(EngineTransient, f"the server could not be reached ({exc.code})", exc.status, exc.code)


def _health_request(guard, rule: HostRule, headers: Mapping, *, timeout: float, path: str) -> Response:
    try:
        response = guard.request("GET", _health_url(rule, path), headers=dict(headers or {}), timeout=timeout, path_label="health")
    except EgressError as exc:
        raise _map_egress(exc) from None
    if response.status != 200:
        raise _health_error(response.status)
    return response


def fetch_health(guard, rule: HostRule, headers: Mapping, *, backend_kind: Optional[str] = None, attest_allow=None,
                 timeout: float = HEALTH_TIMEOUT_S, path: str = "/v1/health?detail=1") -> dict:
    """``GET /v1/health?detail=1`` through ``guard`` (so the host, the CA, the lane gate and the size limits apply) within ``timeout``
    seconds, no retry. Returns ``parse_health``'s dict; raises ``EnginePolicyDenied`` for a refusal (``health_problems``: protocol,
    retention, backend kind, attest; the message lists the codes), ``EngineAuthError`` for 401/403, ``EngineTransient`` for an unreachable
    or unwell server or an unreadable answer. Shared by ``RemoteEngine.load``, ``mcap asr-engines check`` and ``mcap doctor``; ``headers``
    carry the credential (``HttpEngine.auth_headers``) and the protocol headers."""
    health = parse_health(_health_request(guard, rule, headers, timeout=timeout, path=path).body)
    problems = health_problems(health, backend_kind=backend_kind, attest_allow=attest_allow)
    if problems:
        raise _fail(EnginePolicyDenied, "the server was refused: " + ", ".join(problems), None, problems[0])
    return health


# ---------------------------------------------------------------------------------- the engine
class HttpEngine(Engine):
    """Base class of the external engines (see the module docstring). ``decision`` is the ``AsrDecision`` of the run (it names this engine's
    host in ``engine_hosts`` and the rule in ``hosts``), ``guard`` an ``EgressGuard`` built for that one host. ``gate`` is called before every
    attempt (``lane`` check: returns None to go on, a ``LaneBlock`` to stop; never cached). ``sleep``, ``rand`` and ``clock`` are injected by
    tests. ``cap_minutes`` is the daily cap of external audio (None: ``ASR_CLOUD_DAILY_MINUTES``; ``float('inf')``: none)."""

    kind = "server"                  # adapters: "server" | "cloud"
    uses_prompt = False              # an external engine builds its own prompt (or has none): asr.py skips the tokenizer and the retry
    needs_secret = True              # False for an engine that needs no credential
    health: Optional[dict] = None    # the last accepted health document (adapters that have one)

    def __init__(self, cfg, vocab, decision, guard, *, gate: Optional[Callable[[], Any]] = None, sleep: Callable[[float], None] = time.sleep,
                 rand: Callable[[], float] = random.random, clock: Callable[[], float] = time.monotonic,
                 cap_minutes: Optional[float] = None):
        meta = ENGINE_META.get(self.engine_id, {})
        super().__init__(meta.get("model", ""), allow_download=False)
        if meta:                                 # policy.ENGINE_META is the single truth of kind and residency
            self.kind, self.residency = meta["kind"], meta["residency"]
        self.cfg, self.vocab, self.decision, self.guard = cfg, vocab, decision, guard
        self._gate, self._sleep, self._rand, self._clock = gate, sleep, rand, clock
        engine_hosts = getattr(decision, "engine_hosts", None) or {}
        self.host: Optional[str] = engine_hosts.get(self.engine_id)
        self.rule: Optional[HostRule] = (getattr(decision, "hosts", None) or {}).get(self.host) if self.host else None
        self.consent_id: str = str((getattr(decision, "consent_ids", None) or {}).get(self.engine_id, ""))
        self.port: int = int(self.rule.port) if self.rule is not None else 443
        self._token: Optional[str] = None
        self._breaker = None
        self._stats = threading.Lock()
        self._counts = {"requests": 0, "lid_requests": 0, "audio_s": 0.0, "bytes": 0}
        self._chunks = 0
        self._data_sent = False
        self._prompts: list = []
        self._cap = float(cfg.asr_cloud_daily_minutes) if cap_minutes is None else float(cap_minutes)
        self._base_minutes, self._base_date, self._own_minutes = 0.0, None, 0.0

    # ------------------------------------------------------------------------------------------ adapter surface
    def build_request(self, chunk, language) -> tuple:
        """ADAPTER: ``(method, path, headers, body)`` of the request that transcribes ``chunk`` (float32 mono 16 kHz, <= 28 s). Pure."""
        raise NotImplementedError

    def parse_response(self, status: int, body: bytes) -> dict:
        """ADAPTER: the engine result (``text``, ``segments`` with times relative to the chunk, ``language``, ``avg_logprob`` ...) of a 2xx
        answer. Pure. Raises ``EngineTransient`` for an answer that cannot be read. The result goes through ``clean_result`` afterwards."""
        raise NotImplementedError

    def common_headers(self) -> dict:
        """ADAPTER (optional): headers of every request, computed ONCE per logical request, so a retry carries the same ``X-MCAP-Idem``."""
        return {}

    def auth_headers(self) -> dict:
        """The credential as headers (``Authorization: Bearer <secret>`` unless the adapter overrides this). Reads the Keychain item bound to
        this engine, host and port on the first call (``EngineAuthError`` when there is none) and keeps the value in memory only."""
        return {"Authorization": f"Bearer {self.secret()}"} if self.needs_secret else {}

    def recover(self, status: int, code: Optional[str]) -> bool:
        """ADAPTER (optional): called ONCE per request for a 4xx that would end it. Return True after fixing the cause (e.g. a PUT of the
        vocabulary for 404 ``vocab_unknown``): the same request (same headers, same idempotency key) is sent again without using an attempt."""
        return False

    def price_per_hour(self) -> float:
        """US dollars per audio hour for the ``est_usd`` of the usage line: ``ASR_<ENGINE>_USD_PER_HOUR`` of the config (azure has one), else 0."""
        return float(getattr(self.cfg, f"asr_{self.engine_id}_usd_per_hour", 0.0) or 0.0)

    def destination_label(self) -> str:
        """A label for ``transcript.json["asr"]["destination"]``: never the host (a transcript folder goes to a shared drive). A server is
        ``company-asr``, a cloud engine ``<engine>/<region>``."""
        if self.kind == "server":
            return "company-asr"
        region = str(getattr(self.cfg, f"asr_{self.engine_id}_region", "") or "").strip().lower()
        return f"{self.engine_id}/{region}" if region else self.engine_id

    # ------------------------------------------------------------------------------------------ Engine interface
    def load(self) -> None:
        """No model to load. An adapter with a health check extends this (``check_health``). Refuses an engine without a destination."""
        if self.rule is None:
            raise _fail(EnginePolicyDenied, "no destination is allowed for this engine", None, "no_host")

    def transcribe_chunk(self, audio, language, prompt) -> dict:
        """One chunk to the server. ``prompt`` is ignored: an external engine builds its own (``uses_prompt`` False)."""
        chunk = np.ascontiguousarray(audio, dtype=np.float32)
        seconds = len(chunk) / SR
        method, path, headers, body = self.build_request(chunk, language)
        response = self.exchange("chunk", method, path, headers, body, audio_s=seconds)
        try:
            parsed = self.parse_response(response.status, response.body)
        except EngineError:
            raise
        except Exception:                        # a parser that chokes on what a server sent: the answer is unusable, the parser's message is not shown
            raise _fail(EngineTransient, "the engine answer could not be read") from None
        result = clean_result(parsed, seconds)
        self._chunks += 1
        seen = result.pop("prompt_text", None)
        if seen:
            with self._stats:
                if seen not in self._prompts and len(self._prompts) < PROMPT_TEXTS_MAX:
                    self._prompts.append(seen)
        return result

    def prompt_text_seen(self) -> Optional[str]:
        with self._stats:
            return "\n".join(self._prompts) or None

    def progress_tag(self) -> str:
        return f"[{self.kind}]"

    def describe(self) -> dict:
        info = super().describe()
        info.update({"destination": self.destination_label(), "protocol": ENGINE_META.get(self.engine_id, {}).get("protocol", "")})
        return info

    def usage(self) -> dict:
        """What this engine sent so far: ``requests`` (chunk requests that may have reached the server, retries included), ``lid_requests``,
        ``audio_s`` and ``bytes`` (all payload sent). The ``sent`` block of the provenance."""
        with self._stats:
            return {"requests": self._counts["requests"], "lid_requests": self._counts["lid_requests"],
                    "audio_s": round(self._counts["audio_s"], 1), "bytes": self._counts["bytes"]}

    def sent_anything(self) -> bool:
        """Did meeting data (audio, language-ID clips, vocabulary) possibly leave this Mac through this engine?"""
        with self._stats:
            return self._data_sent

    def provenance(self) -> dict:
        """The ``transcript.json["asr"]`` block of this engine on its own; ``RoutedEngine.provenance`` builds the run's block."""
        touched = self.sent_anything()
        return {"schema": 1, "engine": self.engine_id, "model": self.model or "", "kind": self.kind,
                "privacy": self.kind if touched else "local", "destination": self.destination_label(),
                "region": self.residency, "protocol": ENGINE_META.get(self.engine_id, {}).get("protocol", ""),
                "consent_id": self.consent_id, "chunks": {self.engine_id: self._chunks}, "fallbacks": 0, "circuit_opened": 0, "sent": self.usage()}

    def release(self) -> None:
        self._token = None                       # the credential lives for one run

    def bind_breaker(self, breaker) -> None:
        """The router tells the engine which circuit breaker it runs under: its state goes into every usage line."""
        self._breaker = breaker

    @property
    def circuit(self) -> str:
        return getattr(self._breaker, "state", "closed") if self._breaker is not None else "closed"

    def preflight(self, *, run=subprocess.run) -> list:
        """Static problems (no request is made): a list of fixed sentences, empty when nothing is wrong. Used by ``mcap asr-engines check``
        and doctor. Looks at the destination, the private CA of a server and whether a credential is STORED (the Keychain is asked whether
        the item exists, the secret is not read)."""
        problems: list = []
        if self.rule is None:
            return ["no destination is allowed for this engine (policy, consent or settings)"]
        if self.kind == "server" and not ca_bound(self.rule):
            problems.append("the private CA of the server is not bound (ASR_REMOTE_CA_FILE and the consent's ca_sha256)")
        if self.needs_secret:
            status = asr_creds.secret_status(self.engine_id, self.host, self.port, run=run)
            if not status["present"]:
                problems.append(f"no credential is stored for this destination ({status['reason']})")
        return problems

    # ------------------------------------------------------------------------------------------ credential
    def secret(self) -> str:
        """The credential: read from the Keychain (``asr_creds.secret``: bound to this engine, host and port) on first use, then kept in
        memory until ``release()``; ``reset_secret()`` forgets it earlier (after a token renewal). ``EngineAuthError`` when unavailable."""
        if self._token is None:
            if self.host is None:
                raise _fail(EngineAuthError, "no destination for a credential", None, "no_host")
            try:
                with asr_creds.secret(self.engine_id, self.host, self.port) as value:
                    self._token = value
            except asr_creds.CredentialUnavailable as exc:
                raise _fail(EngineAuthError, str(exc), None, exc.reason) from None
        return self._token

    def reset_secret(self) -> None:
        self._token = None

    # ------------------------------------------------------------------------------------------ the gate and the cap
    def _check_gate(self, op: str, attempt: int, audio_s: float = 0.0) -> None:
        if self._gate is None:
            return
        try:
            block = self._gate()
        except Exception:
            block = "gate-failed"
        if block is None:
            return
        reason = block if isinstance(block, str) else getattr(block, "reason", "")
        reason = reason if isinstance(reason, str) and _REASON.fullmatch(reason) else "closed"
        self._note(op, attempt, self._clock(), status=0, outcome="denied:gate", bytes_out=0, bytes_in=0, audio_s=0.0)
        raise _fail(EnginePolicyDenied, f"external ASR is not allowed now ({reason})", None, reason)

    def _minutes_used(self) -> float:
        """External audio used today, in the minutes the cap counts: the usage file is read once per local date, our own attempts since are
        added in memory (reading a file of thousands of lines for every chunk would be wasteful)."""
        today = claude_usage.clock().date()
        if self._base_date != today:
            self._base_minutes, self._base_date, self._own_minutes = asr_usage.minutes_today(self.cfg), today, 0.0
        return self._base_minutes + self._own_minutes

    def _check_cap(self, seconds: float) -> None:
        if not math.isfinite(self._cap):
            return
        if self._minutes_used() + (seconds + asr_usage.REQUEST_SECONDS) / 60.0 > self._cap:
            raise _fail(EngineCapReached, "the daily limit for external audio is reached (ASR_CLOUD_DAILY_MINUTES or the policy cap)",
                        None, "cap")

    # ------------------------------------------------------------------------------------------ usage
    def _note(self, op: str, attempt: int, started: float, *, status: int, outcome: str, bytes_out: int, bytes_in: int,
              audio_s: float) -> None:
        sent = asr_usage.request_was_sent(status, outcome)
        if sent:
            with self._stats:
                if op == "chunk":
                    self._counts["requests"] += 1
                elif op == "lid":
                    self._counts["lid_requests"] += 1
                self._counts["audio_s"] += audio_s
                self._counts["bytes"] += bytes_out
                self._data_sent = self._data_sent or op in DATA_OPS
                self._own_minutes += (audio_s + asr_usage.REQUEST_SECONDS) / 60.0
        price = self.price_per_hour()
        asr_usage.record(self.cfg, engine=self.engine_id, kind=self.kind, host=self.host or "", op=op, status=status, audio_s=audio_s,
                         bytes_out=bytes_out, bytes_in=bytes_in, dur_ms=int(max(0.0, self._clock() - started) * 1000), outcome=outcome,
                         attempt=attempt, est_usd=(audio_s / 3600.0 * price) if (sent and price > 0) else None, circuit=self.circuit)

    # ------------------------------------------------------------------------------------------ the request
    def _url(self, path: str) -> str:
        if self.rule is None:
            raise _fail(EnginePolicyDenied, "no destination is allowed for this engine", None, "no_host")
        return _health_url(self.rule, path)

    def exchange(self, op: str, method: str, path: str, headers: Optional[Mapping], body: bytes, *, audio_s: float = 0.0,
                 timeout: Optional[float] = None) -> Response:
        """ONE logical request with the retry policy of the module docstring: the ``Response`` of the first 2xx attempt, or an engine error.
        ``op`` names the request in the usage line (chunk | lid | health | vocab | ...), ``audio_s`` is the audio it carries (cap and usage).
        The headers are ``common_headers()`` (once) + ``headers`` + ``auth_headers()``; ``body`` is bytes."""
        url = self._url(path)
        label = path_label(path)
        payload = bytes(body or b"")
        base = {**self.common_headers(), **dict(headers or {})}
        seconds = float(timeout) if timeout is not None else float(self.cfg.asr_request_timeout_s)
        max_attempts = max(1, int(self.cfg.asr_retry_max))
        budget = float(self.cfg.asr_remote_max_wait_s)
        spent = 0.0                                   # seconds this request has used so far: answers and waits
        attempt = 0
        recovered = False
        while True:
            attempt += 1
            self._check_gate(op, attempt)             # the lane gate first: it comes before the cap, the Keychain read and the socket
            if attempt == 1 and audio_s > 0:
                self._check_cap(audio_s)              # (SPEC 18: lane, then budget) once per request: an advisory limit, not per retry
            started = self._clock()
            wait_hint: Optional[float] = None
            limit = max_attempts
            try:
                credential = self.auth_headers()      # the Keychain is read here, once: after the gate, before the socket
            except EngineAuthError:
                self._note(op, attempt, started, status=0, outcome="denied:credential", bytes_out=0, bytes_in=0, audio_s=0.0)
                raise
            try:
                response = self.guard.request(method, url, headers={**base, **credential}, body=payload, timeout=seconds, path_label=label)
            except EngineError:                       # the guard's pre_connect (the lane gate) refused with an engine error: as it is
                self._note(op, attempt, started, status=0, outcome="denied:pre_connect", bytes_out=0, bytes_in=0, audio_s=0.0)
                raise
            except (EgressDenied, EgressViolation) as exc:
                self._note(op, attempt, started, status=exc.status or 0, outcome=f"denied:{exc.code}", bytes_out=len(payload), bytes_in=0,
                           audio_s=audio_s)
                raise _map_egress(exc) from None
            except EgressError as exc:
                self._note(op, attempt, started, status=0, outcome=f"error:{exc.code}", bytes_out=len(payload), bytes_in=0, audio_s=audio_s)
                if exc.code == "bad_request":         # a retry cannot change a malformed request: fail now, the router decides what next
                    raise _fail(EngineTransient, "the request could not be sent (bad_request)", None, exc.code) from None
                failure = _fail(EngineTransient, f"the server could not be reached ({exc.code}) after {attempt} attempt(s)", None, exc.code)
            except Exception:                         # the gate callback of the guard raised something else: closed, never open
                self._note(op, attempt, started, status=0, outcome="denied:pre_connect", bytes_out=0, bytes_in=0, audio_s=0.0)
                raise _fail(EnginePolicyDenied, "the lane gate failed", None, "gate_failed") from None
            else:
                status = response.status
                self._note(op, attempt, started, status=status, outcome="ok" if 200 <= status < 300 else f"http_{status}",
                           bytes_out=len(payload), bytes_in=len(response.body), audio_s=audio_s)
                if 200 <= status < 300:
                    return response
                code, body_hint = error_info(response.body)
                if status in (401, 403):
                    raise _fail(EngineAuthError, f"the server refused the credential (HTTP {status})", status, code)
                if status == 426:
                    raise _fail(EnginePolicyDenied, "the server does not speak this protocol (HTTP 426)", status, code or "proto_mismatch")
                if status in (429, 503):
                    wait_hint = retry_after_seconds(response.headers, body_hint)
                elif status == 408 or status >= 500:
                    limit = min(max_attempts, 1 + SERVER_ERROR_RETRIES)
                else:
                    if not recovered and self.recover(status, code):
                        recovered = True
                        attempt -= 1                  # fixing the cause is not an attempt
                        spent += max(0.0, self._clock() - started)
                        continue
                    raise EngineHttpError(status, code)
                failure = _fail(EngineTransient, f"the server answered HTTP {status} after {attempt} attempt(s)", status, code)
            spent += max(0.0, self._clock() - started)
            if attempt >= limit:
                raise failure
            if wait_hint is not None:
                delay = min(wait_hint, RETRY_AFTER_CAP_S)
            else:
                delay = RETRY_DELAYS[min(attempt - 1, len(RETRY_DELAYS) - 1)] * (1.0 + (self._rand() * 2.0 - 1.0) * JITTER)
            if spent + delay > budget:
                raise _fail(EngineTransient, f"the time limit for one request is used up (ASR_REMOTE_MAX_WAIT_S) after {attempt} attempt(s)",
                            failure.status, failure.code)
            self._sleep(delay)
            spent += delay

    def check_health(self, *, backend_kind: Optional[str] = None, attest_allow=None) -> dict:
        """The health check of this engine: gate, credential, ``GET /v1/health?detail=1`` within 5 s, refusals as in ``fetch_health``; one
        usage line (op ``health``). Stores and returns the accepted document (``self.health``). Raises as ``fetch_health`` does."""
        self._check_gate("health", 1)
        rule = self.rule
        if rule is None:
            raise _fail(EnginePolicyDenied, "no destination is allowed for this engine", None, "no_host")
        headers = {**self.common_headers(), **self.auth_headers()}
        started = self._clock()
        try:
            response = _health_request(self.guard, rule, headers, timeout=HEALTH_TIMEOUT_S, path="/v1/health?detail=1")
        except EngineError as exc:
            status = getattr(exc, "status", None) or 0
            code = getattr(exc, "code", None)
            if isinstance(exc, EnginePolicyDenied) and code:
                outcome = f"denied:{code}"
            else:
                outcome = f"http_{status}" if status else f"error:{code or 'other'}"
            self._note("health", 1, started, status=status, outcome=outcome, bytes_out=0, bytes_in=0, audio_s=0.0)
            raise
        self._note("health", 1, started, status=200, outcome="ok", bytes_out=0, bytes_in=len(response.body), audio_s=0.0)
        health = parse_health(response.body)
        problems = health_problems(health, backend_kind=backend_kind, attest_allow=attest_allow)
        if problems:
            raise _fail(EnginePolicyDenied, "the server was refused: " + ", ".join(problems), None, problems[0])
        self.health = health
        return health
