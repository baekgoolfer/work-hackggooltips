"""Any server with an OpenAI-style ``POST <base>/audio/transcriptions`` as an ASR engine: a provider of ``asr_providers`` (SPEC 18).

``OpenAICompatEngine`` is an ``asr_http.HttpEngine`` (kind ``cloud``, engine id ``openai-compat``) that takes BLOCKS of speech
(``asr_engines.BlockUpload``, see ``asr_clova`` for why). It is only an API SHAPE: the user decides which vendor or self-hosted server sits
behind ``ASR_OPENAI_COMPAT_URL`` (OpenAI itself, a faster-whisper server, the project's own ASR server where it speaks this shape), so
``policy.ENGINE_META`` says "destination chosen by the user", the residency is ``foreign`` (nothing is known about where the audio is
processed: an organisation policy needs ``asr.allow_foreign``), and the typed consent names the configured host and port. The rule that this
project does not use the OpenAI or Anthropic APIs for transcription is the owner's to waive, and choosing this engine and typing the consent
is how a user does it for himself.

    POST https://<host>[:port]<base path>/audio/transcriptions
    Authorization: Bearer <key>        (only when a key is stored: ``mcap asr-engines secret set openai-compat``; a self-hosted server needs none)
    multipart/form-data:  file = block.wav (RIFF, 16 kHz mono 16-bit PCM),  model = <ASR_OPENAI_COMPAT_MODEL>,
        response_format = verbose_json,  timestamp_granularities[] = segment,  language = ko | en (only when ASR_LANGUAGE pins one)

The answer is the ``verbose_json`` document: ``segments[]`` with ``start`` / ``end`` in seconds, ``text`` and, when the server gives them, the
Whisper numbers (``avg_logprob``, ``no_speech_prob``, ``compression_ratio``, ``temperature``); ``language`` (an English name or a code). An
answer with neither ``segments`` nor ``text`` is ``EngineTransient``, never an empty transcript; ``text`` without segments is ONE segment over
the block. No vocabulary is sent (the request has no field for terms; a prompt would only bias a Whisper server toward the term list).
Nothing here opens a socket (only ``EgressGuard`` does), reads the Keychain except through ``asr_creds``, or puts server text into a message,
a log line, a state file or a usage record. The wire is document-derived until a first live call (tests/fixtures/openai_compat say so).
"""
from __future__ import annotations

import json
import math
import numbers
import re
import subprocess
import threading
from typing import Any, Mapping, Optional

from . import asr_providers
from .asr_engines import SR, BlockUpload, EngineAuthError, EnginePolicyDenied, EngineTransient
from .asr_http import MAX_SEGMENTS, HttpEngine, wav16
from .asr_providers import merge_segments, multipart_form

TRANSCRIBE_PATH = "/audio/transcriptions"
BLOCK_FILENAME = "block.wav"
LANGUAGE_NAMES = {"korean": "ko", "english": "en", "japanese": "ja", "chinese": "zh"}     # the English names a verbose_json answer uses
_CODE = re.compile(r"[a-z]{2,3}\Z")
_NUMBER = re.compile(r"[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\Z")
_MODEL = re.compile(r"[\x21-\x7e]{1,100}\Z")                  # one printable token: a model name never carries a space or a control character


def _error(cls, message: str, status: Optional[int] = None, code: Optional[str] = None):
    """An engine error with a FIXED message and the ``status`` / ``code`` attributes every error of the engines has: never a server's text."""
    exc = cls(message)
    exc.status = status
    exc.code = code
    return exc


def _number(value: Any) -> Optional[float]:
    """A finite number (or a numeric string) as a float; None for anything else."""
    if isinstance(value, bool):
        return None
    if isinstance(value, numbers.Real):
        number = value
    elif isinstance(value, str) and _NUMBER.fullmatch(value.strip()):
        number = value.strip()
    else:
        return None
    try:
        out = float(number)
    except (OverflowError, ValueError):
        return None
    return out if math.isfinite(out) else None


def _line(value: Any) -> str:
    """Service text on one line, as text that can be written to disk ('' for a non-string; a lone surrogate becomes ``?``)."""
    return " ".join(value.split()).encode("utf-8", "replace").decode("utf-8") if isinstance(value, str) else ""


def language_code(value: Any) -> Optional[str]:
    """``ko`` from ``korean`` or ``ko``; a name this module does not know is None (the language of the chunk stays what ASR_LANGUAGE says)."""
    word = value.strip().lower() if isinstance(value, str) else ""
    return LANGUAGE_NAMES.get(word) or (word if _CODE.fullmatch(word) else None)


def build_fields(model: str, language: Optional[str]) -> list:
    """The text fields of the request, in order (pure): ``model``, ``response_format`` verbose_json, segment timestamps, and ``language`` only
    when ``language`` is a two- or three-letter code (``ASR_LANGUAGE`` pinned one)."""
    fields = [("model", model), ("response_format", "verbose_json"), ("timestamp_granularities[]", "segment")]
    if isinstance(language, str) and _CODE.fullmatch(language.strip().lower()):
        fields.append(("language", language.strip().lower()))
    return fields


def parse_response(body: Any, block_s: float) -> dict:
    """The engine result of a 2xx answer (pure): ``{"text", "segments", "language", "avg_logprob", "truncated"}``, times in seconds relative to
    the block. ``text`` without a usable segment is one segment over the block (``block_s``, or the answer's ``duration``); more segments than
    ``asr_http.MAX_SEGMENTS`` are merged, never dropped. ``EngineTransient`` with a fixed message for JSON that cannot be read or a document
    with neither ``segments`` nor ``text``; nothing the service said is in it."""
    try:
        doc = json.loads(bytes(body).decode("utf-8"))
    except (ValueError, TypeError, RecursionError):
        raise _error(EngineTransient, "the engine answer could not be read") from None
    if not isinstance(doc, dict) or not (isinstance(doc.get("segments"), list) or isinstance(doc.get("text"), str)):
        raise _error(EngineTransient, "the engine answer could not be used")
    span = _number(block_s) or _number(doc.get("duration")) or 0.0
    segments = []
    for raw in doc["segments"] if isinstance(doc.get("segments"), list) else []:
        text = _line(raw.get("text")) if isinstance(raw, Mapping) else ""
        if not text:
            continue
        start, end = _number(raw.get("start")), _number(raw.get("end"))
        start = max(start, 0.0) if start is not None else (segments[-1]["end"] if segments else 0.0)
        end = end if end is not None and end >= start else start
        segments.append({"start": start, "end": end, "text": text, "avg_logprob": _number(raw.get("avg_logprob")),
                         "no_speech_prob": _number(raw.get("no_speech_prob")), "compression_ratio": _number(raw.get("compression_ratio")),
                         "temperature": _number(raw.get("temperature")) or 0.0, "confidence": None})
    if not segments:
        text = _line(doc.get("text"))
        if text:
            segments = [{"start": 0.0, "end": span, "text": text, "avg_logprob": None, "no_speech_prob": None, "compression_ratio": None,
                         "temperature": 0.0, "confidence": None}]
    segments.sort(key=lambda s: s["start"])
    segments = merge_segments(segments, MAX_SEGMENTS)
    return {"text": " ".join(s["text"] for s in segments), "segments": segments, "language": language_code(doc.get("language")),
            "avg_logprob": None, "truncated": False}


class OpenAICompatEngine(BlockUpload, HttpEngine):
    """See the module docstring. Built by ``asr_router.build_member`` (guard, gate, clocks). The destination, the retries, the cap and the usage
    lines are ``HttpEngine``'s; the block length and the long timeout are ``BlockUpload``'s."""

    engine_id = "openai-compat"
    kind = "cloud"
    residency = "foreign"                # the destination is the user's choice: nothing says where the audio is processed
    uses_prompt = False                  # no vocabulary is sent
    supports_lid = False                 # the server identifies the language (or ASR_LANGUAGE pins it)
    confidence = "logprob"               # verbose_json carries the Whisper numbers when the server has them (None when it does not)
    timing = "segment"
    needs_secret = False                 # the key is optional: a self-hosted server needs none

    def __init__(self, cfg, vocab, decision, guard, **kw):
        super().__init__(cfg, vocab, decision, guard, **kw)
        model = str(getattr(cfg, "asr_openai_compat_model", "") or "").strip()
        self.model = model if _MODEL.fullmatch(model) else ""
        self._base = asr_providers.base_path(cfg, self.engine_id)
        self._local = threading.local()                                 # the length of the block under way: parse_response is not told

    # ------------------------------------------------------------------------------------------ destination and key
    def load(self) -> None:
        """No model, no health endpoint: the destination is checked (the host of the settings is the consented one) and a model name must be set.
        The first request is the first contact; ``mcap asr-engines check openai-compat --live`` sends one synthetic tone."""
        self._require_consented_destination()
        if not self.model:
            raise _error(EnginePolicyDenied, "ASR_OPENAI_COMPAT_MODEL is empty or not a single token: nothing is sent", None, "no_model")
        super().load()

    def preflight(self, *, run=subprocess.run) -> list:
        problems = [] if self.model else ["ASR_OPENAI_COMPAT_MODEL is empty or not a single token (no spaces)"]
        return problems + super().preflight(run=run)

    def auth_headers(self) -> dict:
        """``Authorization: Bearer <key>`` when a key is stored for this engine, host and port (read on first use, kept in memory until
        ``release()``); no header when there is none (a self-hosted server without a key). A key that is stored but cannot be read (the Keychain
        did not answer, the value is malformed) is an ``EngineAuthError``: it is never silently replaced by an anonymous request."""
        self._require_consented_destination()
        try:
            return {"Authorization": f"Bearer {self.secret()}"}
        except EngineAuthError as exc:
            if getattr(exc, "code", None) == "missing":
                return {}
            raise

    # ------------------------------------------------------------------------------------------ the request and the answer
    def build_request(self, chunk, language) -> tuple:
        """The multipart POST of one block (``language``: ``ko`` / ``en`` when ``ASR_LANGUAGE`` pinned one, else the server decides)."""
        fields = [(name, None, None, value.encode("utf-8")) for name, value in build_fields(self.model, language)]
        body, content_type = multipart_form([("file", BLOCK_FILENAME, "audio/wav", wav16(chunk))] + fields)
        return "POST", self._base + TRANSCRIBE_PATH, {"Content-Type": content_type, "Accept": "application/json"}, body

    def transcribe_chunk(self, audio, language, prompt) -> dict:
        if len(audio) == 0:                                              # nothing to send, nothing to bill
            return {"text": "", "segments": [], "language": None, "avg_logprob": None, "truncated": False}
        self._local.block_s = len(audio) / SR
        return super().transcribe_chunk(audio, language, prompt)

    def parse_response(self, status: int, body: bytes) -> dict:
        return parse_response(body, getattr(self._local, "block_s", 0.0))
