"""Azure AI Speech fast transcription as an ASR engine: the first cloud adapter (SPEC 18).

``AzureFastEngine`` is an ``asr_http.HttpEngine`` (kind ``cloud``, engine id ``azure``, residency ``kr``). The base class owns everything every
external engine does the same way (the URL of the consented host, the per-attempt lane gate, the Keychain read, retry and ``Retry-After``,
the usage line with ``est_usd``, the daily cap, fixed error messages); this module adds what is specific to Azure and nothing else: the
request (a ``multipart/form-data`` POST with the chunk as a WAV and a ``definition`` part), the answer parser and the key header. It opens
no socket (only ``EgressGuard`` does), reads no Keychain item except through ``asr_creds`` and never puts server text into a message, a log
line, a state file or a usage record. It is imported only when ``ASR_ENGINE`` / ``ASR_FALLBACK`` name ``azure`` (``asr_engines.engine_class``)
or when the ASR server's ``backend`` is ``azure``; the default local pipeline never loads it.

    POST https://<region>.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15
    Ocp-Apim-Subscription-Key: <the key: Keychain on a laptop, a 0600 file on the relay; bound to host and port>
    multipart/form-data:  audio = chunk.wav (RIFF, 16 kHz mono 16-bit PCM),  definition = {"profanityFilterMode":"None", ...}

``build_definition`` is a pure function of the vocabulary and the config: ``locales`` (``ASR_AZURE_LOCALES``; the key is left out when the
list is empty, so the multilingual model decides) and ``phraseList`` (the canonical terms of vocabulary.txt, never the aliases, with
``ASR_AZURE_BIAS`` as ``biasingWeight``) only when ``ASR_SEND_VOCAB`` and the policy decision (``decision.send_vocab``: company cloud
default false) both say so. ``parse_fast_response`` takes both spellings of the time fields (``offsetMilliseconds`` | ``offset``,
``durationMilliseconds`` | ``duration``, milliseconds), gives one segment per phrase, never invents a log-probability (``confidence`` of
the service is an opaque score: ``avg_logprob`` / ``no_speech_prob`` / ``compression_ratio`` stay None), takes the language from the
``locale`` of the phrases (the one with the most speech wins), and falls back to ONE segment for the whole chunk when only
``combinedPhrases`` carries text or a phrase has no usable time (the text is never dropped for a missing time). An answer that has neither
``phrases`` nor ``combinedPhrases`` is not the document this parser knows: ``EngineTransient``, never an empty transcript.

The destination: the host comes from the policy decision only (``ASR_AZURE_REGION`` or ``ASR_AZURE_HOST``, bound into the consent); on top
of that the engine refuses, before the key is read and before any byte is sent, a host outside the two fixed Azure suffixes
(``policy.AZURE_HOST_SUFFIXES``) or a port other than 443 (``EnginePolicyDenied``): a hand-made decision cannot send the key elsewhere.
``asr_creds`` binds the key to ``<user>@<host>:<port>`` as well, so changing the host finds no key.

Residency (policy.ENGINE_META says ``kr`` for the engine, and the policy table gates on that one word): the engine states the residency of
ITS destination (``destination_residency``: a regional host names its region, a custom host takes the region setting, which must then be
stated, not defaulted) and refuses, like a foreign host, a destination that is not in a Korean region (``koreacentral``, ``koreasouth``):
``EnginePolicyDenied`` ``region_not_allowed`` before the key is read. ``policy.evaluate`` cannot see the difference (it has one residency
per engine), so this refusal is what keeps ``allow_foreign=false`` true for Azure; ``provenance()["region"]`` is therefore ``kr`` whenever
audio was sent. A region outside Korea needs a registry entry of its own or a per-binding residency in the policy table.

Two things the service can do to a whole run: reject every request (a wrong path, method or media type: 404, 405, 415; a wrong
``api-version`` or definition: probably 400, [unverified] until the first live call) and change the key of the relay. A 404/405/415 is an ``EndpointRefused`` at once, and so is
the ``REFUSAL_STREAK``-th 400/413/422 in a row (a 2xx answer starts the count again): ``EngineHttpError`` for the callers that know it,
and ``EnginePolicyDenied`` for the router, exactly like a 426 protocol mismatch, so the configured fallback takes the chunk and the
circuit stays open for the run (without a fallback the chunk fails as before). A single 400/413/422 may be this chunk's own problem (a
snippet the service cannot decode): it is a plain ``EngineHttpError``, only that chunk is lost and the circuit is not touched. The price
of that rule is that the first ``REFUSAL_STREAK - 1`` chunks of a run against a really wrong definition are lost before the fallback
takes over (``mcap asr-engines check azure --live`` finds a wrong definition before a meeting). The relay forgets its key on a 401/403
and reads the file again: a rotated ``azure.key`` is used from the next request on without a restart, a revoked one fails once per chunk
and nothing loops.

The relay (``mcap.asr_server`` with ``"backend": "azure"``): ``for_server`` builds the engine with the host of its options, the key from
``<secrets_dir>/azure.key`` (a 0600 ``asr_creds.FileSource`` bound to engine, host and port), its own ``EgressGuard`` with exactly that one
host and no daily cap (the relay's per-token quotas are authoritative). ``set_request_terms`` receives the vocabulary of the request
(the phraseList of the next chunk), ``vendor_info`` fills ``health.vendor``. Its usage lines (content-free, est_usd for the operator's
reconciliation with Azure Cost Management) go to ``<secrets_dir>/azure-usage/asr-usage.jsonl`` unless ``usage_dir`` says otherwise.

Everything about the wire is document-derived until the first live call (SPEC 18: api-version, locale handling, time fields and
units, the accepted range of ``biasingWeight``, the limits of ``phraseList``, billing rounding, 429 behaviour); the fixtures of
tests/fixtures/azure say so in their header and are to be replaced by recorded answers then.
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import numbers
import os
import re
import subprocess
import threading
import types
from collections import Counter
from pathlib import Path
from typing import Any, Mapping, Optional

from . import policy
from .asr_engines import SR, EngineAuthError, EnginePolicyDenied, EngineTransient
from .asr_http import EngineHttpError, HttpEngine, wav16
from .egress import EgressGuard
from .policy import AZURE_HOST_SUFFIXES, HostRule
from .vocab import Vocab

log = logging.getLogger("mcap.asr")

API_VERSION = "2025-10-15"                                  # [unverified] accepted by the service: checked at the first live call
TRANSCRIBE_PATH = "/speechtotext/transcriptions:transcribe"
REQUEST_TARGET = f"{TRANSCRIBE_PATH}?api-version={API_VERSION}"
KEY_HEADER = "Ocp-Apim-Subscription-Key"
AZURE_PORT = 443
VENDOR_NAME = "azure-speech"                                # health.vendor.name of a relay with this backend
DEFAULT_REGION = "koreacentral"
KOREAN_REGIONS = ("koreacentral", "koreasouth")             # the regions whose audio stays in Korea: the residency "kr" of policy.ENGINE_META
REGIONAL_SUFFIX = AZURE_HOST_SUFFIXES[0]                    # <region>.api.cognitive.microsoft.com: the host names its region
ENDPOINT_REFUSALS = (404, 405, 415)                         # path, method, media type: the same for every chunk, so ONE answer says "this endpoint does not take my request"
CHUNK_REFUSALS = (400, 413, 422)                            # may be about this chunk alone (audio it cannot read, a body over its limit): see REFUSAL_STREAK
REFUSAL_STREAK = 3                                          # CHUNK_REFUSALS in a row, none answered well in between, are about the endpoint (the breaker's 3)
MAX_PHRASES = 500                                           # [unverified] a conservative bound: a huge vocabulary file must not make every request fail
MAX_PHRASE_CHARS = 100                                      # a longer entry is not a term (it is left out, never cut)
DEFAULT_BIAS = 1.0
BIAS_RANGE = (0.0, 2.0)                                     # ASR_AZURE_BIAS; the service's own range is checked live
# Options of asr-server.json ``backend_options`` for ``"backend": "azure"`` (strict: an unknown key refuses to start, like the rest of that file).
SERVER_OPTIONS = ("region", "host", "locales", "bias", "usd_per_hour", "request_timeout_s", "retry_max", "retry_budget_s", "usage_dir")
SERVER_TIMEOUT_S = 30                                       # relay defaults: the whole chunk must be answered inside the client's 90 s request
SERVER_RETRY_MAX = 2                                        # timeout, which already includes up to 45 s of queueing (asr-server.json max_wait_s)
SERVER_RETRY_BUDGET_S = 40
USAGE_SUBDIR = "azure-usage"

_DNS_NAME = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\Z")
_LOCALE = re.compile(r"[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8}){0,3}\Z")
_LANG = re.compile(r"[A-Za-z]{2,3}(?![A-Za-z])")
_NUMBER = re.compile(r"[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\Z")


def _error(cls, message: str, status: Optional[int] = None, code: Optional[str] = None):
    """An engine error with a FIXED message and the ``status`` / ``code`` attributes every error of the engines has (the same shape as
    ``asr_http``'s): never a server's text."""
    exc = cls(message)
    exc.status = status
    exc.code = code
    return exc


def host_allowed(host: Any) -> bool:
    """Is ``host`` a plain DNS name under one of the two fixed Azure suffixes (the suffix alone, a leading dot or an empty label are not
    a host)? The one rule the engine applies before it reads the key; ``policy.consent_binding`` and ``asr_creds`` apply the same rule to
    the settings and to the stored key."""
    name = host.strip().lower() if isinstance(host, str) else ""
    return any(name.endswith(suffix) and len(name) > len(suffix) for suffix in AZURE_HOST_SUFFIXES) and bool(_DNS_NAME.fullmatch(name))


def destination_residency(host: Any, cfg: Any) -> str:
    """``kr`` when audio sent to ``host`` is processed in a Korean region, else ``foreign`` (also when that cannot be shown). A regional
    host (``<region>.api.cognitive.microsoft.com``) names its region itself. Any other Azure host (a custom subdomain) does not: the region
    is then the operator's statement, ``ASR_AZURE_REGION`` (bound into the consent), and it counts only when it is STATED: the default
    region of the settings says nothing about a host the operator chose (``cfg.explicit_keys`` knows what config.env really set; a Config
    made in code has no such list and is taken at its word)."""
    name = host.strip().lower() if isinstance(host, str) else ""
    if name.endswith(REGIONAL_SUFFIX):
        return "kr" if name[:-len(REGIONAL_SUFFIX)] in KOREAN_REGIONS else "foreign"
    if str(getattr(cfg, "asr_azure_region", "") or "").strip().lower() not in KOREAN_REGIONS:
        return "foreign"
    stated = getattr(cfg, "explicit_keys", None) or ()
    return "foreign" if name and "ASR_AZURE_HOST" in stated and "ASR_AZURE_REGION" not in stated else "kr"


class EndpointRefused(EngineHttpError, EnginePolicyDenied):
    """The service refused the request in a way that says the ENDPOINT does not take it (``ENDPOINT_REFUSALS``: a path that is not there,
    a method or media type it does not read; or ``REFUSAL_STREAK`` ``CHUNK_REFUSALS`` in a row: a wrong api-version or definition): the
    same request is refused for every chunk. It is an ``EngineHttpError`` (status, code, the fixed sentence of the base class) and, for
    the router, an ``EnginePolicyDenied`` like a 426 protocol mismatch: the fallback takes the chunk and the circuit is open for the rest
    of the run instead of failing every chunk. One refused chunk among good ones is never this: it stays a plain ``EngineHttpError``
    (SPEC 18: a problem of the content is not a trigger)."""


# ---------------------------------------------------------------------------------- the definition part
def _locales(spec: Any) -> tuple:
    """``(locales, dropped)`` of an ASR_AZURE_LOCALES value: BCP-47 tags separated by comma, semicolon or space, in the spelling the
    service uses (``ko_kr`` -> ``ko-KR``, ``zh-hans-cn`` -> ``zh-Hans-CN``), duplicates dropped, order kept; ``dropped`` counts the entries
    that are not locales at all (they are left out, never guessed)."""
    if isinstance(spec, str):
        parts = re.split(r"[,;\s]+", spec.strip())
    elif isinstance(spec, (list, tuple)):
        parts = [x.strip() for x in spec if isinstance(x, str)]
    else:
        parts = []
    out: list = []
    dropped = 0
    for part in parts:
        if not part:
            continue
        if not _LOCALE.fullmatch(part):
            dropped += 1
            continue
        tags = re.split(r"[-_]", part)
        tag = "-".join([tags[0].lower()] + [t.title() if len(t) == 4 and t.isalpha() else t.upper() for t in tags[1:]])
        if tag not in out:
            out.append(tag)
    return out, dropped


def parse_locales(spec: Any) -> list:
    """The locale candidates of ``ASR_AZURE_LOCALES`` (``_locales`` without the count): [] when the setting is empty."""
    return _locales(spec)[0]


def phrase_terms(vocab: Any) -> list:
    """The canonical terms of ``vocab`` as the service's phrase list, in file order (priority order): one line, at most 100 characters,
    no control characters, encodable as UTF-8 (a lone surrogate cannot be sent), duplicates (case-folded) dropped, at most 500. The
    aliases of vocabulary.txt are NOT phrases: they are the spellings the service gets wrong, replaced afterwards by the client."""
    raw = getattr(vocab, "terms", None)
    if not isinstance(raw, (list, tuple)):
        return []
    out: list = []
    seen: set = set()
    for term in raw:
        if not isinstance(term, str) or any(ord(ch) < 32 or ord(ch) == 127 for ch in term):
            continue
        text = " ".join(term.split())
        if not text or len(text) > MAX_PHRASE_CHARS:
            continue
        try:
            text.encode("utf-8")
        except UnicodeEncodeError:
            continue
        key = text.casefold()
        if key in seen:
            continue
        seen.add(key)
        out.append(text)
        if len(out) >= MAX_PHRASES:
            break
    return out


def _bias(cfg: Any) -> float:
    value = getattr(cfg, "asr_azure_bias", DEFAULT_BIAS)
    if isinstance(value, bool) or not isinstance(value, numbers.Real) or not math.isfinite(float(value)):
        return DEFAULT_BIAS
    return min(max(float(value), BIAS_RANGE[0]), BIAS_RANGE[1])


def build_definition(vocab: Any, cfg: Any) -> dict:
    """The ``definition`` part of the request (pure). ``profanityFilterMode`` is always ``None`` (a verbatim transcript); ``locales`` only
    when ``ASR_AZURE_LOCALES`` names some; ``phraseList`` (``phrases`` + ``biasingWeight`` = ``ASR_AZURE_BIAS``) only when
    ``ASR_SEND_VOCAB`` is on and ``vocab`` has usable terms. ``vocab`` None means 'send nothing' (the engine passes None when the policy
    decision forbids the vocabulary for a cloud engine)."""
    definition: dict = {"profanityFilterMode": "None"}
    locales = parse_locales(getattr(cfg, "asr_azure_locales", ""))
    if locales:
        definition["locales"] = locales
    if bool(getattr(cfg, "asr_send_vocab", False)):
        phrases = phrase_terms(vocab)
        if phrases:
            definition["phraseList"] = {"phrases": phrases, "biasingWeight": _bias(cfg)}
    return definition


def definition_json(definition: Mapping) -> bytes:
    """The definition as ASCII JSON (non-ASCII text as \\u escapes: no charset question for a part without one), compact."""
    return json.dumps(definition, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def multipart_body(wav: bytes, definition: Mapping) -> tuple:
    """``(body, content_type)`` of the request: the ``audio`` part (``chunk.wav``, audio/wav) then the ``definition`` part
    (application/json), CRLF line ends, closing delimiter. The boundary is derived from the content (sha256 of definition and audio) so
    the same chunk gives the same bytes on every attempt, and it is re-derived in the (practically impossible) case it occurs in a part."""
    meta = definition_json(definition)
    seed = hashlib.sha256(meta + b"\0" + wav).hexdigest()
    while True:
        boundary = "mcap-" + seed[:32]
        marker = b"--" + boundary.encode("ascii")
        if marker not in meta and marker not in wav:
            break
        seed = hashlib.sha256(seed.encode("ascii")).hexdigest()
    opening = marker + b"\r\n"
    body = (opening + b'Content-Disposition: form-data; name="audio"; filename="chunk.wav"\r\nContent-Type: audio/wav\r\n\r\n' + wav + b"\r\n"
            + opening + b'Content-Disposition: form-data; name="definition"\r\nContent-Type: application/json\r\n\r\n' + meta + b"\r\n"
            + marker + b"--\r\n")
    return body, f"multipart/form-data; boundary={boundary}"


# ---------------------------------------------------------------------------------- the answer
def _wellformed(value: str) -> str:
    """A server string as text that can be written to disk: a lone surrogate (JSON ``"\\ud800"``) is valid to ``json.loads`` but not to
    ``str.encode('utf-8')``, which is what the transcript writer does after the whole ASR run; it becomes ``?``."""
    return value.encode("utf-8", "replace").decode("utf-8")


def _seconds(value: Any) -> Optional[float]:
    """A time the service gave in milliseconds (a number or a numeric string) as seconds; None for anything else or a non-finite number."""
    if isinstance(value, bool):
        return None
    if isinstance(value, numbers.Real):
        number = value
    elif isinstance(value, str) and _NUMBER.fullmatch(value.strip()):
        number = value.strip()
    else:
        return None
    try:
        millis = float(number)
    except (OverflowError, ValueError):
        return None
    return millis / 1000.0 if math.isfinite(millis) else None


def _first_time(raw: Mapping, *names: str) -> Optional[float]:
    for name in names:
        seconds = _seconds(raw.get(name))
        if seconds is not None:
            return seconds
    return None


def _confidence(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return None
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _line(value: Any) -> str:
    """Service text on one line, as text that can be written to disk ('' for a non-string)."""
    return _wellformed(" ".join(value.split())) if isinstance(value, str) else ""


def _language(locale: Any) -> Optional[str]:
    """The language part of a locale (``ko-KR`` -> ``ko``, ``zh-Hans-CN`` -> ``zh``); None for anything that does not start like one."""
    found = _LANG.match(locale.strip()) if isinstance(locale, str) else None
    return found.group(0).lower() if found else None


def _segment(start: float, end: float, text: str, confidence: Optional[float]) -> dict:
    return {"start": start, "end": end, "text": text, "avg_logprob": None, "no_speech_prob": None, "compression_ratio": None,
            "temperature": 0.0, "confidence": confidence}


def _answer(segments: list, language: Optional[str]) -> dict:
    return {"text": " ".join(s["text"] for s in segments), "segments": segments, "language": language, "avg_logprob": None,
            "truncated": False}


def parse_fast_response(body: Any, chunk_s: float) -> dict:
    """The engine result of a 2xx answer of the service (pure): ``{"text", "segments", "language", "avg_logprob", "truncated"}``, times in
    seconds relative to the chunk (see the module docstring for the shape rules). ``chunk_s`` is the length of the chunk that was sent: the
    span of the one-segment fallback (the answer's own ``durationMilliseconds`` when it is not given). ``EngineTransient`` with a fixed
    message for JSON that cannot be read or is not an answer document; nothing the service said is in it."""
    try:
        doc = json.loads(bytes(body).decode("utf-8"))
    except (ValueError, TypeError, RecursionError):
        raise _error(EngineTransient, "the engine answer could not be read") from None
    phrases, combined = (doc.get("phrases"), doc.get("combinedPhrases")) if isinstance(doc, dict) else (None, None)
    if not isinstance(phrases, list) and not isinstance(combined, list):
        raise _error(EngineTransient, "the engine answer could not be used")
    span = float(chunk_s) if isinstance(chunk_s, numbers.Real) and not isinstance(chunk_s, bool) and math.isfinite(float(chunk_s)) else 0.0
    if span <= 0.0:
        span = _first_time(doc, "durationMilliseconds", "duration") or 0.0
    span = max(span, 0.0)

    rows: list = []                     # (start | None, duration | None, text, locale | None, confidence | None)
    for raw in phrases if isinstance(phrases, list) else []:
        text = _line(raw.get("text")) if isinstance(raw, dict) else ""
        if text:
            locale = raw.get("locale")
            rows.append((_first_time(raw, "offsetMilliseconds", "offset"), _first_time(raw, "durationMilliseconds", "duration"), text,
                         locale if isinstance(locale, str) else None, _confidence(raw.get("confidence"))))
    overall = ""
    for entry in combined if isinstance(combined, list) else []:
        overall = _line(entry.get("text")) if isinstance(entry, dict) else ""
        if overall:
            break

    if rows and all(row[0] is not None for row in rows):
        rows.sort(key=lambda row: row[0])
        segments, weights = [], Counter()
        for index, (start, duration, text, locale, confidence) in enumerate(rows):
            start = max(start, 0.0)
            if duration is not None:
                end = start + max(duration, 0.0)
            else:                                           # no duration: up to the next phrase, the last one up to the end of the chunk
                end = rows[index + 1][0] if index + 1 < len(rows) else span
            segments.append(_segment(start, max(end, start), text, confidence))
            lang = _language(locale)
            if lang:
                weights[lang] += max(end - start, 0.01)
        return _answer(segments, weights.most_common(1)[0][0] if weights else None)

    text = overall or " ".join(row[2] for row in rows)       # no phrases, or one without a usable time: the whole chunk is one segment
    if not text:
        return _answer([], None)
    return _answer([_segment(0.0, span, text, None)], next((lang for lang in (_language(row[3]) for row in rows) if lang), None))


# ---------------------------------------------------------------------------------- the engine
class AzureFastEngine(HttpEngine):
    """See the module docstring. Built by ``asr_router.build_member`` (guard, gate, clocks), or by ``for_server`` (the relay). The
    destination, the credential, the retries, the cap and the usage lines are ``HttpEngine``'s; ``relay`` is set only by ``for_server``
    (the vocabulary then comes with each request: ``set_request_terms``)."""

    engine_id = "azure"
    kind = "cloud"
    residency = "kr"
    uses_prompt = False                  # no prompt: the vocabulary goes as a phraseList (asr.py builds no tokenizer and never retries without a prompt)
    supports_lid = False                 # the service identifies the language itself: asr.py sends language=None (or the forced language, ignored here)
    confidence = "opaque"
    timing = "segment"
    chunk_params = {"max_inner_gap_s": 4.0}      # a request has a fixed overhead: merge regions across longer pauses than Whisper's 2.5 s

    def __init__(self, cfg, vocab, decision, guard, *, relay: bool = False, **kw):
        super().__init__(cfg, vocab, decision, guard, **kw)
        self.residency = destination_residency(self.host, cfg)        # of THIS destination (the class says what the table assumes: kr)
        self.relay = bool(relay)
        self._send_vocab = bool(getattr(decision, "send_vocab", False)) and bool(getattr(cfg, "asr_send_vocab", False))
        self._request_vocab = vocab if self._send_vocab else None      # what goes into the phraseList (the relay replaces it per request)
        self._local = threading.local()                                # the length of the chunk under way: parse_response is not told
        self._refusals, self._refusals_lock = 0, threading.Lock()      # CHUNK_REFUSALS in a row (a good answer resets it)
        self._note_settings()

    def _note_settings(self) -> None:
        """Say once, with numbers only, what the settings lost on the way to the service (never a term or a locale)."""
        _, dropped = _locales(getattr(self.cfg, "asr_azure_locales", ""))
        if dropped:
            log.warning("ASR_AZURE_LOCALES: %d entr%s not a locale and left out", dropped, "y is" if dropped == 1 else "ies are")
        if self._send_vocab and not self.relay:
            terms = getattr(self._request_vocab, "terms", None)
            sent = len(phrase_terms(self._request_vocab))
            if isinstance(terms, (list, tuple)) and sent < len(terms):
                log.info("azure phraseList: %d of %d vocabulary terms are sent (the rest are empty, duplicates, over %d characters or past the first %d)",
                         sent, len(terms), MAX_PHRASE_CHARS, MAX_PHRASES)

    # ------------------------------------------------------------------------------------------ destination and key
    def _require_destination(self) -> None:
        """The last line before the key is read or a byte is sent: an Azure host (the two fixed suffixes) on port 443, in a Korean region
        (the table of the policy has one residency for the engine, so this is where ``allow_foreign=false`` holds for Azure). A destination
        that is missing altogether is the base class's business (``no_host``)."""
        if self.host is None:
            return
        if not host_allowed(self.host) or self.port != AZURE_PORT:
            raise _error(EnginePolicyDenied, "the destination is not an Azure Speech endpoint: nothing is sent and the key is not read", None,
                         "host_not_allowed")
        if self.residency != "kr":
            raise _error(EnginePolicyDenied, "the Azure endpoint is not shown to be in a Korean region: nothing is sent and the key is not read",
                         None, "region_not_allowed")

    def load(self) -> None:
        """No model, no health endpoint: the destination is checked (policy decision and Azure suffix pin). The first request is the first
        contact; ``mcap asr-engines check azure --live`` sends one synthetic tone."""
        self._require_destination()
        super().load()

    def preflight(self, *, run=subprocess.run) -> list:
        if self.host is not None and (not host_allowed(self.host) or self.port != AZURE_PORT):
            return ["the destination is not an Azure Speech endpoint (the host must end in .api.cognitive.microsoft.com or "
                    ".cognitiveservices.azure.com, port 443)"]
        if self.host is not None and self.residency != "kr":
            return [f"the Azure endpoint is not shown to be in a Korean region ({', '.join(KOREAN_REGIONS)}; a custom host needs ASR_AZURE_REGION "
                    "stated too)"]
        return super().preflight(run=run)

    def auth_headers(self) -> dict:
        """``Ocp-Apim-Subscription-Key``: the key of the Keychain item bound to this engine, host and port (or the relay's key file),
        read on first use and kept in memory until ``release()``. ``EngineAuthError`` when there is none for THIS destination."""
        self._require_destination()
        return {KEY_HEADER: self.secret()}

    # ------------------------------------------------------------------------------------------ the request and the answer
    def set_request_terms(self, terms) -> None:
        """Relay only (called by ``asr_server`` before each chunk, with the terms the request named: ``()`` when it named none): the
        phraseList of the next request. A client engine takes its vocabulary from the constructor and never gets this call."""
        usable = [t for t in terms if isinstance(t, str)] if isinstance(terms, (list, tuple)) else []
        self._request_vocab = Vocab(terms=usable) if self._send_vocab and usable else None

    def build_request(self, chunk, language) -> tuple:
        """The multipart POST of one chunk. ``language`` is not used: the service identifies it (``ASR_AZURE_LOCALES`` narrows the
        candidates; a forced ``ASR_LANGUAGE`` is not turned into a locale, SPEC 18 names that setting as the only source)."""
        body, content_type = multipart_body(wav16(chunk), build_definition(self._request_vocab, self.cfg))
        return "POST", REQUEST_TARGET, {"Content-Type": content_type, "Accept": "application/json"}, body

    def transcribe_chunk(self, audio, language, prompt) -> dict:
        if len(audio) == 0:                                            # nothing to send
            return {"text": "", "segments": [], "language": None, "avg_logprob": None, "truncated": False}
        self._local.chunk_s = len(audio) / SR
        try:
            return self._send_chunk(audio, language, prompt)
        except EngineAuthError as exc:
            if not self.relay or getattr(exc, "status", None) not in (401, 403):
                raise
            stale = self._token                                        # the relay's key file may have been rotated: read it again
            self.reset_secret()
            if self.secret() == stale:                                 # (a missing or insecure file raises its own error here)
                raise exc from None
        return self._send_chunk(audio, language, prompt)               # once, with the new key: a second 401 is the answer

    def _send_chunk(self, audio, language, prompt) -> dict:
        try:
            result = super().transcribe_chunk(audio, language, prompt)
        except EngineHttpError as exc:
            if type(exc) is EngineHttpError and self._endpoint_refused(exc.status):
                raise EndpointRefused(exc.status, exc.code) from None
            raise
        with self._refusals_lock:
            self._refusals = 0
        return result

    def _endpoint_refused(self, status) -> bool:
        """Does this refusal say the ENDPOINT does not take the requests (``EndpointRefused``) rather than this chunk? 404/405/415 do at once;
        400/413/422 only as the ``REFUSAL_STREAK``-th in a row."""
        if status in ENDPOINT_REFUSALS:
            return True
        if status not in CHUNK_REFUSALS:
            return False
        with self._refusals_lock:
            self._refusals += 1
            return self._refusals >= REFUSAL_STREAK

    def parse_response(self, status: int, body: bytes) -> dict:
        return parse_fast_response(body, getattr(self._local, "chunk_s", 0.0))

    # ------------------------------------------------------------------------------------------ the relay
    def vendor_info(self) -> dict:
        """``health.vendor`` of a relay with this backend (the vendor's retention claim is the vendor's: ``verified`` stays false)."""
        region = str(getattr(self.cfg, "asr_azure_region", "") or "").strip().lower()
        return {"name": VENDOR_NAME, "region": region, "claim_url": "", "verified": False}

    @classmethod
    def for_server(cls, options, *, model: str, secrets_dir) -> "AzureFastEngine":
        """What ``asr_server.default_backend_factory`` calls for ``"backend": "azure"``: ``options`` are the ``backend_options`` of
        asr-server.json (strict, see ``SERVER_OPTIONS``; ``region`` or ``host`` name the destination, which must be an Azure host in a Korean
        region: a ``host`` outside the regional ``<region>.api.cognitive.microsoft.com`` form needs its ``region`` stated too),
        ``model`` is ignored (the service has one). The key is read from ``<secrets_dir>/azure.key`` (0600, owned by the service user,
        bound to engine, host and port: ``asr_server.install_vendor_key_source``). The engine has its own ``EgressGuard`` with exactly
        that host, no lane gate (the relay has no meeting), no daily cap (the per-token quotas of the relay are authoritative) and short
        retries: the whole chunk has to be answered inside the client's request timeout."""
        opts = dict(options or {})
        unknown = sorted(set(opts) - set(SERVER_OPTIONS))
        if unknown:
            raise ValueError(f"unknown backend_options key {unknown[0]!r} (allowed: {', '.join(SERVER_OPTIONS)})")
        locales = opts.get("locales", "")
        if isinstance(locales, (list, tuple)) and all(isinstance(x, str) for x in locales):
            locales = ",".join(locales)
        if not isinstance(locales, str):
            raise ValueError("locales must be a comma-separated string or a list of strings")
        usage_dir = _option_text(opts, "usage_dir", os.path.join(os.fspath(secrets_dir), USAGE_SUBDIR))
        if not os.path.isabs(usage_dir):
            raise ValueError("usage_dir must be an absolute path")
        from .config import Config                                      # lazy: nothing of the client pipeline is needed to import this module
        cfg = Config(
            support_dir=Path(usage_dir),
            explicit_keys=frozenset(key for key, name in (("ASR_AZURE_REGION", "region"), ("ASR_AZURE_HOST", "host")) if opts.get(name)),
            asr_azure_region=_option_text(opts, "region", DEFAULT_REGION).lower(), asr_azure_host=_option_text(opts, "host", "").lower(),
            asr_azure_locales=locales, asr_azure_bias=_option_number(opts, "bias", DEFAULT_BIAS, float, *BIAS_RANGE),
            asr_azure_usd_per_hour=_option_number(opts, "usd_per_hour", 0.0, float, 0.0, None),
            asr_request_timeout_s=_option_number(opts, "request_timeout_s", SERVER_TIMEOUT_S, int, 1, 600),
            asr_retry_max=_option_number(opts, "retry_max", SERVER_RETRY_MAX, int, 1, 10),
            asr_remote_max_wait_s=_option_number(opts, "retry_budget_s", SERVER_RETRY_BUDGET_S, int, 1, 600), asr_send_vocab=True)
        binding, why = policy.consent_binding(cfg, cls.engine_id)
        if binding is None or not host_allowed(binding["host"]):
            raise ValueError(f"the Azure destination of backend_options is not usable ({why or 'bad-host'}): region must be a plain region name "
                             f"and host must end in {' or '.join(AZURE_HOST_SUFFIXES)}")
        host, port = binding["host"], binding["port"]
        if destination_residency(host, cfg) != "kr":
            raise ValueError(f"the Azure destination of backend_options is not shown to be in Korea: region must be one of "
                             f"{' or '.join(KOREAN_REGIONS)}, and a host needs its region stated too")
        from . import asr_server                                        # the caller: the file source and the path of the key are its own
        asr_server.install_vendor_key_source(secrets_dir, cls.engine_id, host, port)
        rule = HostRule(host=host, port=port)
        decision = types.SimpleNamespace(primary=cls.engine_id, fallback=None, engine_hosts={cls.engine_id: host}, hosts={host: rule},
                                         consent_ids={cls.engine_id: "relay"}, send_vocab=True)
        guard = EgressGuard({host: rule}, engine_id=cls.engine_id, consent_id="relay", trust="system")
        return cls(cfg, None, decision, guard, cap_minutes=float("inf"), relay=True)


def _option_text(opts: Mapping, key: str, default: str) -> str:
    value = opts.get(key, default)
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string")
    return value.strip()


def _option_number(opts: Mapping, key: str, default, kind, low, high=None):
    value = opts.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or (kind is int and not isinstance(value, int)):
        raise ValueError(f"{key} must be {'an integer' if kind is int else 'a number'}")
    number = kind(value)
    if not math.isfinite(number) or number < low or (high is not None and number > high):
        raise ValueError(f"{key} must be from {low} to {high}" if high is not None else f"{key} must be at least {low}")
    return number
