"""NAVER CLOVA Speech (long-sentence recognition, local file upload) as an ASR engine: a provider of ``asr_providers`` (SPEC 18).

``ClovaEngine`` is an ``asr_http.HttpEngine`` (kind ``cloud``, engine id ``clova``, residency ``kr``) that takes BLOCKS of speech
(``asr_engines.BlockUpload``): the pipeline concatenates the VAD chunks of a track into blocks of up to ``ASR_CLOUD_BLOCK_SECONDS`` (default
900 s, silence between chunks is already cut out), because the service bills every request in 15 s steps and a sync call is limited to 2 hours
and 2 GB. The base class owns what every external engine does the same way (the consented host, the per-attempt lane gate, the Keychain read,
retry and ``Retry-After``, the usage line, the daily cap, fixed error messages); this module adds the request, the answer parser and the key
header. It opens no socket (only ``EgressGuard`` does), reads no Keychain item except through ``asr_creds`` and never puts server text into a
message, a log line, a state file or a usage record.

    POST https://<gateway>/<invoke path>/recognizer/upload
    X-CLOVASPEECH-API-KEY: <the secret key of the domain: Keychain, bound to host and port>
    multipart/form-data:  media = block.wav (RIFF, 16 kHz mono 16-bit PCM),  params = {"language": "enko", "completion": "sync",
        "wordAlignment": true, "fullText": true, "noiseFiltering": true, "diarization": {"enable": false}, "boostings": [{"words": "Acme"}]}

The destination is ``ASR_CLOVA_INVOKE_URL`` (the invoke URL of the user's own domain: ``https://clovaspeech-gw.ncloud.com/external/v1/<id>/<key>``);
its host and port are bound into the typed consent and the Keychain item, its path is the user's domain and is neither logged nor stored. The
host must end in a NAVER Cloud gateway suffix (``asr_providers.CLOVA_HOST_SUFFIXES``): the key is never sent anywhere else.

Settings: ``ASR_CLOVA_LANGUAGE`` (``ko-KR`` | ``en-US`` | ``enko`` ...; ``ASR_LANGUAGE`` is not used), ``ASR_CLOVA_DIARIZATION``
(``auto`` | ``on`` | ``off``; ``auto`` = on for the only track of a meeting and for the remote track of an online meeting, off for the microphone
track of an online meeting: ``diarization_enabled``, fed by ``asr.transcribe_track`` through ``set_track_context``), and the vocabulary:
``boosting_terms`` (terms only, never aliases; at most 1000; a one-character term, a term of another script or a duplicate is left out) goes as
``boostings`` only when ``ASR_SEND_VOCAB`` and the policy decision (``decision.send_vocab``) both say so.

The answer parser reads the documented fields of a segment defensively (``start`` / ``end`` in milliseconds, ``text``, ``confidence`` 0..1,
``diarization.label`` | ``speaker.label``) and ignores the rest (words, events, the echoed params). The speaker label is parsed but the
engine contract (``asr_http.clean_result``) carries no speaker field, so it is not used downstream yet. [UNVERIFIED] The response of a SYNC call
is not described by the documentation the fixtures of tests/fixtures/clova were derived from (they say so in their header): the first live
call of the owner confirms the shape; until then an answer that has neither ``segments`` nor ``text`` is ``EngineTransient``, never an empty
transcript, and ``result`` other than COMPLETED / SUCCEEDED is ``EngineTransient`` too.
"""
from __future__ import annotations

import json
import logging
import math
import numbers
import re
import subprocess
import threading
from collections import Counter
from typing import Any, Mapping, Optional

from . import asr_providers
from .asr_engines import SR, BlockUpload, EnginePolicyDenied, EngineTransient
from .asr_http import MAX_SEGMENTS, HttpEngine, wav16
from .asr_providers import CLOVA_HOST_SUFFIXES, HANGUL, guess_language, merge_segments, multipart_form

log = logging.getLogger("mcap.asr")

UPLOAD_PATH = "/recognizer/upload"
KEY_HEADER = "X-CLOVASPEECH-API-KEY"
CLOVA_PORT = 443
BLOCK_FILENAME = "block.wav"                                # the part carries a name; nothing about the meeting is in it
BOOSTINGS_MAX = 1000                                        # documented: up to 1000 keywords
BOOST_TERM_CHARS = 100                                      # a longer entry is not a term (it is left out, never cut)
OK_RESULTS = ("COMPLETED", "SUCCEEDED", "SUCCESS")
DIARIZATION_CHOICES = ("auto", "on", "off")
_NUMBER = re.compile(r"[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\Z")
_LABEL = re.compile(r"[A-Za-z0-9_-]{1,16}\Z")
_FIXED_LANGUAGE = {"ko-KR": "ko", "en-US": "en", "ja": "ja", "zh-cn": "zh", "zh-tw": "zh"}      # ``enko`` is not one language: guess per segment


def _error(cls, message: str, status: Optional[int] = None, code: Optional[str] = None):
    """An engine error with a FIXED message and the ``status`` / ``code`` attributes every error of the engines has: never a server's text."""
    exc = cls(message)
    exc.status = status
    exc.code = code
    return exc


# ---------------------------------------------------------------------------------- the request
def host_allowed(host: Any) -> bool:
    """Is ``host`` a plain name under one of the NAVER Cloud gateway suffixes (the suffix alone is not a host)? The rule the engine applies before
    it reads the key."""
    name = host.strip().lower() if isinstance(host, str) else ""
    return any(name.endswith(suffix) and len(name) > len(suffix) for suffix in CLOVA_HOST_SUFFIXES)


def diarization_enabled(setting: str, track: str, solo: bool, platform: str = "") -> bool:
    """Speaker separation for one track. ``on`` / ``off`` are what they say. ``auto``: ON for a track that is the only one of its meeting
    (``solo``: an offline meeting, one recording of a whole room) and for every track of a manual session (``platform`` ``manual``), ON for the
    ``remote`` track of an online meeting (several people behind one stream), OFF for its ``mic`` track (one person). An unknown ``setting`` reads as ``auto``."""
    word = str(setting or "").strip().lower()
    if word == "on":
        return True
    if word == "off":
        return False
    return bool(solo) or str(platform or "").lower() == "manual" or track == "remote"


def boosting_terms(vocab: Any) -> list:
    """The vocabulary terms as ``boostings``, in file order (priority order): terms only (the aliases of vocabulary.txt are the spellings the
    service gets wrong: replaced afterwards by the client), at most ``BOOSTINGS_MAX``. Left out: a one-character term (the service does not
    support single-syllable words), a term with a letter that is neither Hangul nor ASCII Latin (the service boosts Korean and English only), a
    term over ``BOOST_TERM_CHARS``, control characters, a lone surrogate, duplicates (case-folded). A comma is a space: it may separate keywords."""
    raw = getattr(vocab, "terms", None)
    if not isinstance(raw, (list, tuple)):
        return []
    out: list = []
    seen: set = set()
    for term in raw:
        if not isinstance(term, str) or any(ord(ch) < 32 or ord(ch) == 127 for ch in term):
            continue
        text = " ".join(term.replace(",", " ").split())
        if len(text.replace(" ", "")) < 2 or len(text) > BOOST_TERM_CHARS:
            continue
        if any(ch.isalpha() and not (ch.isascii() or HANGUL.match(ch)) for ch in text):
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
        if len(out) >= BOOSTINGS_MAX:
            break
    return out


def build_params(language: str, terms: list, diarization: bool) -> dict:
    """The ``params`` part (pure): the sync call with word alignment, the full text and noise filtering of the documentation; ``boostings`` only
    when there are ``terms`` (one entry per term, so a term is never split); ``diarization.enable`` always explicit (its default differs between
    the documentation pages)."""
    params: dict = {"language": language, "completion": "sync", "wordAlignment": True, "fullText": True, "noiseFiltering": True,
                    "diarization": {"enable": bool(diarization)}}
    if terms:
        params["boostings"] = [{"words": term} for term in terms]
    return params


def params_json(params: Mapping) -> bytes:
    """The params as ASCII JSON (non-ASCII text as \\u escapes: no charset question for a part without one), compact."""
    return json.dumps(params, ensure_ascii=True, separators=(",", ":")).encode("ascii")


# ---------------------------------------------------------------------------------- the answer
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


def _unit(value: Any) -> Optional[float]:
    """A confidence in [0, 1]; None for anything else."""
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return None
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return None
    return number if math.isfinite(number) and 0.0 <= number <= 1.0 else None


def _line(value: Any) -> str:
    """Service text on one line, as text that can be written to disk ('' for a non-string): a lone surrogate (JSON ``"\\ud800"``) is valid to
    ``json.loads`` but not to the UTF-8 writer of the transcript, it becomes ``?``."""
    return " ".join(value.split()).encode("utf-8", "replace").decode("utf-8") if isinstance(value, str) else ""


def _speaker(raw: Mapping) -> Optional[str]:
    """``diarization.label`` or ``speaker.label`` of a segment when it is a short word (the label is the service's own text: only a plain token passes)."""
    for key in ("diarization", "speaker"):
        node = raw.get(key)
        label = node.get("label") if isinstance(node, Mapping) else None
        if isinstance(label, (str, int)) and not isinstance(label, bool) and _LABEL.fullmatch(str(label)):
            return str(label)
    return None


def _segment(start: float, end: float, text: str, confidence: Optional[float], speaker: Optional[str]) -> dict:
    return {"start": start, "end": end, "text": text, "avg_logprob": None, "no_speech_prob": None, "compression_ratio": None,
            "temperature": 0.0, "confidence": confidence, "speaker": speaker}


def parse_response(body: Any, block_s: float, language: str = "enko") -> dict:
    """The engine result of a 2xx answer (pure): ``{"text", "segments", "language", "avg_logprob", "truncated"}``, times in seconds relative to
    the block. ``block_s`` (the length of the audio that was sent) is the span of the one-segment fallback: the answer has ``text`` but no
    usable segment time, and the text is never dropped for a missing time. The language is the setting's when it names one language, else the
    one (``ko`` | ``en``) with the most speech time among the segments. More segments than ``asr_http.MAX_SEGMENTS`` are merged, never dropped.
    ``EngineTransient`` with a fixed message for JSON that cannot be read, a document with neither ``segments`` nor ``text``, or a ``result``
    that is not a completion; nothing the service said is in it."""
    try:
        doc = json.loads(bytes(body).decode("utf-8"))
    except (ValueError, TypeError, RecursionError):
        raise _error(EngineTransient, "the engine answer could not be read") from None
    if not isinstance(doc, dict):
        raise _error(EngineTransient, "the engine answer could not be used")
    verdict = doc.get("result")
    if isinstance(verdict, str) and verdict.strip().upper() not in OK_RESULTS:      # a failed job has neither segments nor text: say so first
        raise _error(EngineTransient, "the service did not complete the recognition")
    if not (isinstance(doc.get("segments"), list) or isinstance(doc.get("text"), str)):
        raise _error(EngineTransient, "the engine answer could not be used")
    span = float(block_s) if isinstance(block_s, numbers.Real) and not isinstance(block_s, bool) and math.isfinite(float(block_s)) else 0.0
    span = max(span, 0.0)

    rows: list = []                    # (start | None, end | None, text, confidence | None, speaker | None)
    for raw in doc["segments"] if isinstance(doc.get("segments"), list) else []:
        text = _line(raw.get("text")) if isinstance(raw, Mapping) else ""
        if text:
            rows.append((_seconds(raw.get("start")), _seconds(raw.get("end")), text, _unit(raw.get("confidence")), _speaker(raw)))
    fixed = _FIXED_LANGUAGE.get(language)
    if not rows:
        text = _line(doc.get("text"))
        if not text:
            return _answer([], None)
        return _answer([_segment(0.0, span, text, None, None)], fixed or guess_language(text))

    segments, weights = [], Counter()
    cursor = 0.0
    for start, end, text, confidence, speaker in rows:
        start = max(start if start is not None else cursor, 0.0)           # a segment without a time follows the one before it
        end = end if end is not None and end >= start else start
        if span:                                                            # decoders can emit times past the real end of the audio
            start, end = min(start, span), min(end, span)
        cursor = max(cursor, end)
        segments.append(_segment(start, end, text, confidence, speaker))
        lang = guess_language(text)
        if lang:
            weights[lang] += max(end - start, 0.01)
    segments.sort(key=lambda s: s["start"])
    return _answer(merge_segments(segments, MAX_SEGMENTS), fixed or (weights.most_common(1)[0][0] if weights else None))


def _answer(segments: list, language: Optional[str]) -> dict:
    return {"text": " ".join(s["text"] for s in segments), "segments": segments, "language": language, "avg_logprob": None, "truncated": False}


# ---------------------------------------------------------------------------------- the engine
class ClovaEngine(BlockUpload, HttpEngine):
    """See the module docstring. Built by ``asr_router.build_member`` (guard, gate, clocks). The destination, the credential, the retries, the cap and
    the usage lines are ``HttpEngine``'s; the block length, the track context and the long timeout are ``BlockUpload``'s."""

    engine_id = "clova"
    kind = "cloud"
    residency = "kr"
    uses_prompt = False                  # no prompt: the vocabulary goes as boostings (asr.py builds no tokenizer and never retries without a prompt)
    supports_lid = False                 # ``enko`` recognises both languages in one request; ASR_LANGUAGE is not used
    confidence = "opaque"
    timing = "segment"

    def __init__(self, cfg, vocab, decision, guard, **kw):
        super().__init__(cfg, vocab, decision, guard, **kw)
        self.language = str(getattr(cfg, "asr_clova_language", "enko") or "enko")
        self.diarization_setting = str(getattr(cfg, "asr_clova_diarization", "auto") or "auto")
        self._send_vocab = bool(getattr(decision, "send_vocab", False)) and bool(getattr(cfg, "asr_send_vocab", False))
        self._terms = boosting_terms(vocab) if self._send_vocab else []
        self._base = asr_providers.base_path(cfg, self.engine_id)
        self._local = threading.local()                                 # the length of the block under way: parse_response is not told
        if self._send_vocab:
            terms = getattr(vocab, "terms", None)
            if isinstance(terms, (list, tuple)) and len(self._terms) < len(terms):
                log.info("clova boostings: %d of %d vocabulary terms are sent (the rest are one character, another script, duplicates, over %d "
                         "characters or past the first %d)", len(self._terms), len(terms), BOOST_TERM_CHARS, BOOSTINGS_MAX)

    # ------------------------------------------------------------------------------------------ destination and key
    def _require_destination(self) -> None:
        """The last line before the key is read or a byte is sent: a NAVER Cloud gateway on port 443, and the host of the settings is the consented
        one (``BlockUpload._require_consented_destination``). A destination that is missing altogether is the base class's business (``no_host``)."""
        if self.host is None:
            return
        if not host_allowed(self.host) or self.port != CLOVA_PORT:
            raise _error(EnginePolicyDenied, "the destination is not a CLOVA Speech gateway: nothing is sent and the key is not read", None,
                         "host_not_allowed")
        self._require_consented_destination()

    def load(self) -> None:
        """No model, no health endpoint: the destination is checked. The first request is the first contact; ``mcap asr-engines check clova
        --live`` sends one synthetic tone."""
        self._require_destination()
        super().load()

    def preflight(self, *, run=subprocess.run) -> list:
        if self.host is not None and (not host_allowed(self.host) or self.port != CLOVA_PORT):
            return [f"the destination is not a CLOVA Speech gateway (the host must end in {', '.join(CLOVA_HOST_SUFFIXES)}, port 443)"]
        return super().preflight(run=run)

    def auth_headers(self) -> dict:
        """``X-CLOVASPEECH-API-KEY``: the secret key of the Keychain item bound to this engine, host and port, read on first use and kept in
        memory until ``release()``. ``EngineAuthError`` when there is none for THIS destination."""
        self._require_destination()
        return {KEY_HEADER: self.secret()}

    # ------------------------------------------------------------------------------------------ the request and the answer
    def diarization(self) -> bool:
        """Speaker separation for the track ``asr.py`` told this engine about (``set_track_context``); a call without a context is a single track."""
        context = self.track_context or {"track": "audio", "solo": True, "platform": ""}
        return diarization_enabled(self.diarization_setting, context["track"], context["solo"], context["platform"])

    def build_request(self, chunk, language) -> tuple:
        """The multipart POST of one block. ``language`` is not used: ``ASR_CLOVA_LANGUAGE`` decides (``enko`` by default)."""
        params = params_json(build_params(self.language, self._terms, self.diarization()))
        body, content_type = multipart_form([("media", BLOCK_FILENAME, "audio/wav", wav16(chunk)), ("params", None, "application/json", params)])
        return "POST", self._base + UPLOAD_PATH, {"Content-Type": content_type, "Accept": "application/json"}, body

    def transcribe_chunk(self, audio, language, prompt) -> dict:
        if len(audio) == 0:                                              # nothing to send, nothing to bill
            return {"text": "", "segments": [], "language": None, "avg_logprob": None, "truncated": False}
        self._local.block_s = len(audio) / SR
        return super().transcribe_chunk(audio, language, prompt)

    def parse_response(self, status: int, body: bytes) -> dict:
        return parse_response(body, getattr(self._local, "block_s", 0.0), self.language)
