"""Test support for the provider engines (asr_providers: clova, openai-compat). Fakes only: nothing opens a socket, reads the real Keychain or starts
a process. Built on ``asr_support`` (``AsrCase``, ``FakeTransport``, ``make_decision`` ...).

  * ``parse_multipart(call)``: the parts of a ``multipart/form-data`` request ``{name: (headers, data)}``, with the framing checked on the way.
  * ``FakeClova`` / ``FakeOpenAI``: small services written from the documentation (``fake(call) -> Response`` is the handler of a ``FakeTransport``);
    they check the key header, the path and the parts, record what arrived and answer from a queue or by default with one segment over the middle
    of the block whose text names the number of samples that arrived.
  * ``clova_consent`` / ``oai_consent``: the consent entry of an engine as ``mcap asr-engines consent`` would write it.
  * ``ProviderCase``: an ``AsrCase`` whose config names both providers, with a key stored for CLOVA, a log collector, ``engine()`` builders that
    make an engine exactly as ``asr_router.build_member`` does and ``everything_written()`` / ``assertNothingLeaked`` for the canary checks.
  * ``speech_track`` / ``region_vad``: a synthetic track with known speech regions for the block seam.
"""
from __future__ import annotations

import logging
import re
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # pipeline/ on sys.path when run via discover

import numpy as np  # noqa: E402

from asr_support import AsrCase, ClosableGate, FakeTransport, consent_entry, json_response, make_decision  # noqa: E402

from mcap import asr_clova, asr_openai_compat, vad  # noqa: E402
from mcap.asr_router import build_member  # noqa: E402
from mcap.egress import EgressGuard, Response  # noqa: E402

SR = 16000
CLOVA_HOST = "clovaspeech-gw.ncloud.com"
CLOVA_ID_PATH = "/external/v1/1234/" + "9f8e7d6c5b4a39281706f5e4d3c2b1a0" * 2                  # the user's domain: an id and a 64-hex invoke key
CLOVA_URL = f"https://{CLOVA_HOST}{CLOVA_ID_PATH}"
CLOVA_KEY = "0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3"
OAI_HOST = "stt.example.org"
OAI_URL = f"https://{OAI_HOST}/v1"
OAI_KEY = "sk-test-0123456789abcdefghijklmnop"
VOCAB_TEXT = "Acme\nAcmeScan-CXR\nAcme = 애크미 | 액미\n"


def parse_multipart(call) -> dict:
    """The parts of a request body: ``{name: (headers, data)}``. Checks the framing on the way (opening delimiter, CRLF around every part, closing
    delimiter), so a body a service would not read fails here."""
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


def wav_samples(data: bytes) -> int:
    """The number of samples of a canonical 44-byte-header 16-bit mono WAV (the header is checked)."""
    assert data[:4] == b"RIFF" and data[8:16] == b"WAVEfmt " and data[36:40] == b"data", data[:44]
    assert int.from_bytes(data[24:28], "little") == SR and int.from_bytes(data[22:24], "little") == 1
    return (len(data) - 44) // 2


class _Fake:
    """The shared half of the two fakes: a queue of scripted answers (a ``Response``, an exception, or a callable of the call), ``requests`` (the
    parts of every accepted request) and the default answer."""

    def __init__(self):
        self.queued: list = []
        self.requests: list = []

    def next(self, call, parts):
        self.requests.append(parts)
        if self.queued:
            item = self.queued.pop(0)
            return item(call) if callable(item) and not isinstance(item, (Response, BaseException)) else item
        return self.answer(parts)


class FakeClova(_Fake):
    """NAVER CLOVA Speech as the documentation describes it: ``POST <invoke path>/recognizer/upload`` with the key header and the parts ``media`` and
    ``params``. A wrong key is 401, another path 404."""

    def __init__(self, key: str = CLOVA_KEY, path: str = CLOVA_ID_PATH):
        super().__init__()
        self.key, self.path = key, path

    def __call__(self, call):
        if call.header(asr_clova.KEY_HEADER) != self.key:
            return json_response(401, {"status": 401, "errorCode": "Unauthorized"})
        if call.method != "POST" or call.target != self.path + asr_clova.UPLOAD_PATH:
            return json_response(404, {"status": 404, "errorCode": "Not Found"})
        return self.next(call, parse_multipart(call))

    @staticmethod
    def answer(parts) -> Response:
        samples = wav_samples(parts["media"][1])
        millis = samples * 1000 // SR
        text = f"액미 block {samples} samples"
        return json_response(200, {"result": "COMPLETED", "message": "Succeeded", "text": text, "confidence": 0.9,
                                   "segments": [{"start": 100, "end": max(millis - 200, 101), "text": text, "confidence": 0.9,
                                                 "diarization": {"label": "1"}, "speaker": {"label": "1"}, "words": []}]})


class FakeOpenAI(_Fake):
    """An OpenAI-style server: ``POST <base>/audio/transcriptions`` with ``file`` and the text fields. ``key`` None = a server that needs none; a
    key = ``Authorization: Bearer <key>`` is required (else 401)."""

    def __init__(self, key: Optional[str] = None, base: str = "/v1"):
        super().__init__()
        self.key, self.base = key, base

    def __call__(self, call):
        if self.key is not None and call.header("Authorization") != f"Bearer {self.key}":
            return json_response(401, {"error": {"message": "invalid key", "code": "invalid_api_key"}})
        if call.method != "POST" or call.target != self.base + asr_openai_compat.TRANSCRIBE_PATH:
            return json_response(404, {"error": {"message": "not found"}})
        return self.next(call, parse_multipart(call))

    @staticmethod
    def answer(parts) -> Response:
        samples = wav_samples(parts["file"][1])
        seconds = samples / SR
        text = f"block of {samples} samples"
        return json_response(200, {"task": "transcribe", "language": "english", "duration": seconds, "text": text,
                                   "segments": [{"id": 0, "start": 0.1, "end": max(seconds - 0.2, 0.2), "text": text, "avg_logprob": -0.2,
                                                 "compression_ratio": 1.1, "no_speech_prob": 0.01, "temperature": 0.0}]})


def clova_consent(**kw):
    return consent_entry("clova", **{"host": CLOVA_HOST, "region": "", "model": "clova-speech-long", "protocol": "clova-speech-upload", **kw})


def oai_consent(**kw):
    return consent_entry("openai-compat", **{"host": OAI_HOST, "region": "", "model": "", "protocol": "openai-audio-transcriptions", **kw})


class Records(logging.Handler):
    """Every log record of the ``mcap`` loggers (message and traceback text) for the leak checks."""

    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines: list = []

    def emit(self, record):
        self.lines.append(record.getMessage() + (self.format(record) if record.exc_info else ""))


class ProviderCase(AsrCase):
    """An ``AsrCase`` for the providers: ``self.cfg`` names CLOVA and the OpenAI-style server, the CLOVA key is in the fake Keychain, ``self.clova``
    and ``self.oai`` are the fake services (one transport answers for both: ``self.transport``), ``self.records`` collects the log at DEBUG."""

    def setUp(self):
        super().setUp()
        self.gate = ClosableGate("asr_cloud")
        self.cfg.asr_clova_invoke_url = CLOVA_URL
        self.cfg.asr_openai_compat_url = OAI_URL
        self.store_token(CLOVA_KEY, "clova", CLOVA_HOST)
        self.clova, self.oai = FakeClova(), FakeOpenAI()

        def route(call):
            return self.clova(call) if call.rule.host == CLOVA_HOST else self.oai(call)

        self.transport = FakeTransport(handler=route, clock=self.clock)
        self.records = Records()
        mcap_log = logging.getLogger("mcap")
        mcap_log.addHandler(self.records)
        self.addCleanup(mcap_log.removeHandler, self.records)
        self.addCleanup(mcap_log.setLevel, mcap_log.level)
        mcap_log.setLevel(logging.DEBUG)

    # ------------------------------------------------------------------------------------------ engines
    def decision(self, engine="clova", cfg=None, **kw):
        kw.setdefault("consents", (clova_consent() if engine == "clova" else oai_consent(),))
        return make_decision(cfg or self.cfg, engine, **kw)

    def engine(self, engine="clova", vocab=None, *, cfg=None, decision=None, gate=None, **kw):
        """The engine as ``asr_router.build_member`` builds it (a guard with the one host of the decision, the lane gate of ``asr_cloud``)."""
        cfg = cfg or self.cfg
        decision = decision or self.decision(engine, cfg)
        host = decision.engine_hosts[engine]
        guard = EgressGuard({host: decision.hosts[host]}, engine_id=engine, consent_id=decision.consent_ids[engine], transport=self.transport,
                            clock=self.clock, pre_connect=gate or self.gate)
        cls = asr_clova.ClovaEngine if engine == "clova" else asr_openai_compat.OpenAICompatEngine
        return cls(cfg, vocab, decision, guard, gate=gate or self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock, **kw)

    def routed(self, cfg, engine="clova", fallback="none", vocab=None, **kw):
        """``(run_cfg, RoutedEngine)`` as a pipeline run builds them: the decision of ``policy.decide_asr``, ``asr_router.build_engine``."""
        from asr_support import make_run
        from mcap.asr_router import build_engine
        consents = kw.pop("consents", (clova_consent() if engine == "clova" else oai_consent(),))
        run_cfg, decision = make_run(cfg, engine, fallback, consents=consents, **kw)
        return run_cfg, build_engine(run_cfg, vocab, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep, clock=self.clock)

    def member(self, cfg, engine="clova"):
        decision = self.decision(engine, cfg)
        return build_member(cfg, None, decision, engine, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep, clock=self.clock)

    # ------------------------------------------------------------------------------------------ what was written
    def everything_written(self) -> str:
        parts = [p.read_bytes().decode("utf-8", "replace") for p in sorted(self.root.rglob("*")) if p.is_file()]
        return "\n".join(parts + self.records.lines)

    def assertNothingLeaked(self, *extra):
        text = self.everything_written()
        for needle in (CLOVA_KEY, OAI_KEY, CLOVA_ID_PATH, "ZZCANARY", "Kim Minsu", "chest pain", *extra):
            self.assertNotIn(needle, text)

    def posts(self, suffix):
        return [c for c in self.transport.calls if c.path.endswith(suffix)]


# ---------------------------------------------------------------------------------------------- synthetic tracks
def speech_track(total_s: float, regions, hz: float = 220.0) -> np.ndarray:
    """A float32 track of ``total_s`` seconds with a tone of ``hz`` in each ``(start, end)`` region and digital silence elsewhere."""
    x = np.zeros(int(total_s * SR), dtype=np.float32)
    for a, b in regions:
        n = int(b * SR) - int(a * SR)
        x[int(a * SR): int(b * SR)] = 0.2 * np.sin(2 * np.pi * hz * np.arange(n) / SR).astype(np.float32)
    return x


def region_vad(regions, total_s: float) -> "vad.VadResult":
    """A ``VadResult`` that names ``regions`` as the speech of a track of ``total_s`` seconds (the frame levels are flat)."""
    db = np.full(int(total_s * SR / vad.FRAME), -40.0, dtype=np.float32)
    return vad.VadResult(list(regions), "silero", db, {})
