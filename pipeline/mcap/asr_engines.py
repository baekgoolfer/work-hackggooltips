"""ASR engines behind one small interface (SPEC 13.2).

``Engine.transcribe_chunk(audio, language, prompt) -> {"text", "segments", "avg_logprob", ...}`` takes ONE chunk
(float32 mono 16 kHz, <= ~28 s) and returns segments whose times are relative to the chunk start::

    segments = [{"start", "end", "text", "avg_logprob", "no_speech_prob", "compression_ratio", "temperature"}]

* ``WhisperEngine`` - production (mlx-whisper, ``mlx-community/whisper-large-v3-mlx`` by default).
* ``QwenEngine`` - optional, benchmark only (``mlx-qwen3-asr``, imported lazily; selected when the model name contains
  ``qwen3_asr`` / ``Qwen3-ASR``). Never the default of the production path.

Engine seam (SPEC 18): besides ``transcribe_chunk`` an engine describes itself through class attributes
(``engine_id``, ``kind`` local|server|cloud, ``residency``, ``uses_prompt``, ``supports_lid``, ``timing``, ``confidence``) and a few
methods (``describe``, ``usage``, ``provenance``, ``prompt_text_seen``, ``progress_tag``). Every default reproduces what a local Whisper
engine does today, so the existing engines and the test doubles need no change; ``engine_caps`` reads them with ``getattr`` and also works
for an object that does not inherit from ``Engine``. ``REGISTRY`` names the engines by id (static, lazily imported, no plugin discovery);
the external ones (``remote``, ``azure`` and the providers of ``asr_providers``: ``clova``, ``openai-compat``) live in their own modules and raise
``EngineUnavailable`` when the module is missing. An engine that takes blocks of speech instead of 28 s chunks says so with ``accepts_blocks`` and
``max_block_s`` (``BlockUpload``, ``asr.py`` packs the chunks into blocks); ``Engine.set_track_context`` tells it which track it is working on.
``SERVER_BACKENDS`` names the engines that only the ASR server process builds (``faster-whisper``: CTranslate2 on a Linux host, module
``asr_faster_whisper``): ``engine_class`` finds them too, but no client setting, policy decision or router can name them.

Model files: ``resolve_model_path`` prefers a local directory, then the local Hugging Face cache
(``snapshot_download(local_files_only=True)``) and only downloads when the model is missing. The download is explicit and
logged at WARNING level; the large-v3 repo is pinned to a known revision.
"""
from __future__ import annotations

import importlib
import logging
import math
import numbers
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np

from .asr_providers import BLOCK_SECONDS_RANGE, PROVIDERS, block_seconds
from .asr_providers import target as provider_target

log = logging.getLogger("mcap.asr")

SR = 16000
MAX_CHUNK_S = 28.0                     # plan_chunks' own window (Whisper's 30 s minus margin): an engine may shorten it, never lengthen it
MIN_CHUNK_S = 1.0                      # below this a window cannot hold a word: the declaration is junk (and 0 would never make progress)
LID_CANDIDATES = ("ko", "en")          # default of ASR_LANGUAGES: the languages the per-region language ID may choose from
MIN_BLOCK_S, MAX_BLOCK_S = (float(v) for v in BLOCK_SECONDS_RANGE)   # the length of one upload block of an engine that takes blocks
BLOCK_TIMEOUT_BASE_S = 60.0            # a block request may take this much plus its own audio seconds (the guard caps one request at 600 s)

# Language codes Whisper (large-v3) knows (mlx_whisper.tokenizer.LANGUAGES). ASR_LANGUAGES entries are checked against this
# list so a typo fails with a clear message instead of an obscure decoder error halfway through a meeting.
WHISPER_LANGUAGE_CODES = frozenset(
    "en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa "
    "lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn "
    "mt sa lb my bo tl mg as tt haw ln ha ba jw su yue".split())

# Revisions the pipeline was verified against (SPEC 13.2). Other repos follow their default branch.
REVISION_PINS = {
    "mlx-community/whisper-large-v3-mlx": "49e6aa286ad60c14352c404340ded53710378a11",
}


class ModelNotAvailable(RuntimeError):
    """The model is neither a local directory, nor in the HF cache, nor downloadable."""


class EngineUnavailable(RuntimeError):
    """The runtime package for an engine is not installed."""


class EngineError(RuntimeError):
    """Base of the errors an engine raises for ONE chunk (external engines; the local ones keep raising what they raise today).
    ``asr.transcribe_track`` treats any exception of a chunk as a failed chunk; the subclasses tell a router what to do next."""
    retryable = True


class EngineTransient(EngineError):
    """Connection, timeout, 5xx, rate limit: worth another attempt (the engine has already used its own retries)."""


class EngineAuthError(EngineError):
    """Credential missing, rejected, expired or bound to another destination."""


class EnginePolicyDenied(EngineError):
    """A gate closed (local-only, organization policy, consent, server attestation): nothing may be sent."""


class EngineCapReached(EngineError):
    """A daily or per-run limit of an external engine is used up."""


class EngineBlockDeclined(EngineError):
    """A call that carried a BLOCK (more audio than one chunk) was not answered, and no audio was lost: ``asr.transcribe_track`` takes the block
    apart and decodes its pieces again, as smaller blocks or as 28 s chunks. Raised by an engine that learned the size its service refuses
    (``BlockUpload``: a 413) and by ``RoutedEngine`` when the primary is bypassed and the fallback takes chunks only. Not a router trigger:
    the circuit is not touched."""
    retryable = False


def parse_languages(spec) -> tuple[str, ...]:
    """ASR_LANGUAGES ("ko,en", "ja, ko, en") -> ("ko", "en") / ("ja", "ko", "en"): lower-case Whisper codes, separated by
    commas / semicolons / spaces, duplicates dropped, order kept (the first entry is the tie-break language). Empty -> the
    default ("ko", "en"). A list or tuple is accepted too. An unknown code raises ``ValueError`` with a message that says
    what is wrong and what is allowed."""
    if spec is None:
        return LID_CANDIDATES
    parts = re.split(r"[,;\s]+", spec.strip()) if isinstance(spec, str) else [str(x).strip() for x in spec]
    out: list[str] = []
    for part in parts:
        code = part.strip().lower()
        if not code:
            continue
        if code not in WHISPER_LANGUAGE_CODES:
            raise ValueError(f"ASR_LANGUAGES: unknown language code {part.strip()!r} in {spec!r} "
                             f"(use Whisper language codes such as ko, en, ja, zh; default is ko,en)")
        if code not in out:
            out.append(code)
    return tuple(out) or LID_CANDIDATES


def restrict_lid(probs: dict, languages=LID_CANDIDATES) -> dict:
    """Language-ID probabilities restricted to ``languages`` and renormalised to sum to 1: ``{code: p, ..., "top": best code}``.
    Codes the model did not report count as 0; if the model gave the whole set no probability at all the result is uniform."""
    langs = tuple(languages) or LID_CANDIDATES
    raw = {c: max(0.0, float(probs.get(c, 0.0) or 0.0)) for c in langs}
    z = sum(raw.values())
    out = {c: (v / z if z > 1e-12 else 1.0 / len(langs)) for c, v in raw.items()}
    out["top"] = max(langs, key=lambda c: out[c])
    return out


# --------------------------------------------------------------------------------------
# model resolution
# --------------------------------------------------------------------------------------
def resolve_model_path(model: str, *, allow_download: bool = True, check: Callable[[Path], bool] | None = None) -> str:
    """Local directory -> returned as is. Hugging Face repo id -> snapshot directory from the local cache; downloaded
    (explicitly, with a WARNING in the log) only when it is not cached or ``check(path)`` says the cached copy is incomplete."""
    local = Path(model).expanduser()
    if local.is_dir():
        return str(local)
    from huggingface_hub import snapshot_download

    revision = REVISION_PINS.get(model)
    try:
        path = snapshot_download(model, revision=revision, local_files_only=True)
        if check is None or check(Path(path)):
            return path
        log.warning("cached copy of %s at %s is incomplete", model, path)
    except Exception as exc:                      # LocalEntryNotFoundError & friends: "not cached"
        log.info("%s is not in the local Hugging Face cache (%s)", model, type(exc).__name__)
    if not allow_download:
        raise ModelNotAvailable(f"ASR model {model} is not available locally and downloads are disabled")
    try:
        from huggingface_hub import constants
        cache = getattr(constants, "HF_HUB_CACHE", "~/.cache/huggingface/hub")
    except Exception:
        cache = "~/.cache/huggingface/hub"
    log.warning("DOWNLOADING ASR model %s%s from huggingface.co into %s (one-time; it was not found locally)",
                model, f" @ {revision[:10]}" if revision else "", cache)
    try:
        path = snapshot_download(model, revision=revision)
    except Exception as exc:
        raise ModelNotAvailable(f"cannot download ASR model {model}: {type(exc).__name__}: {exc}") from exc
    log.warning("download of %s finished: %s", model, path)
    return path


# --------------------------------------------------------------------------------------
# interface
# --------------------------------------------------------------------------------------
@dataclass(frozen=True)
class EngineCaps:
    """What the ASR stage needs to know about an engine. The defaults describe a local Whisper engine (today's behaviour)."""
    kind: str = "local"            # local | server | cloud
    uses_prompt: bool = True       # False: the engine (or its server) builds its own prompt; no tokenizer call, no retry without prompt
    supports_lid: bool = False
    timing: str = "segment"        # segment: times of the decoder's segments | chunk: one segment per chunk (coarse times)
    confidence: str = "logprob"    # logprob | opaque (some score, not a log-prob) | none: avg_logprob / no_speech_prob / compression_ratio are None
    max_chunk_s: float = MAX_CHUNK_S
    residency: str = "device"      # where the audio is processed: device | a country code | foreign
    accepts_blocks: bool = False   # True: asr.py sends blocks of up to ``max_block_s`` seconds of speech (silence between chunks cut out), not 28 s chunks
    max_block_s: float = 0.0       # the block length of such an engine (0.0 = it takes none)


def chunk_limit(value) -> float | None:
    """``value`` as a chunk length in seconds when it is a real, finite number within ``MIN_CHUNK_S``..``MAX_CHUNK_S``, else None. What an
    engine declares may come from a server (health ``limits``): zero, negative, NaN, infinite, tiny, oversized or non-numeric values
    never reach the chunk planner (0 would loop for ever, 1e9 would send one unbounded chunk)."""
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return seconds if math.isfinite(seconds) and MIN_CHUNK_S <= seconds <= MAX_CHUNK_S else None


def block_limit(value) -> float:
    """``value`` as a block length in seconds when it is a real, finite number within ``MIN_BLOCK_S``..``MAX_BLOCK_S``, else 0.0 (no blocks): a
    setting or a declaration outside the range never reaches the block planner."""
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return 0.0
    try:
        seconds = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return seconds if math.isfinite(seconds) and MIN_BLOCK_S <= seconds <= MAX_BLOCK_S else 0.0


def engine_caps(engine) -> EngineCaps:
    """The capabilities of ``engine`` read with ``getattr`` and the defaults of ``EngineCaps``: an object that does not inherit from
    ``Engine`` (a test double) works too. ``max_chunk_s`` has ONE rule, used by the chunk planner as well: the shortest usable limit among
    ``engine.max_chunk_s`` and ``engine.chunk_params["max_chunk_s"]`` (see ``chunk_limit``), ``MAX_CHUNK_S`` when there is none."""
    params = getattr(engine, "chunk_params", None)
    params = params if isinstance(params, dict) else {}
    limits = [v for v in (chunk_limit(getattr(engine, "max_chunk_s", None)), chunk_limit(params.get("max_chunk_s"))) if v is not None]
    return EngineCaps(
        kind=getattr(engine, "kind", "local"), uses_prompt=bool(getattr(engine, "uses_prompt", True)),
        supports_lid=bool(getattr(engine, "supports_lid", False)), timing=getattr(engine, "timing", "segment"),
        confidence=getattr(engine, "confidence", "logprob"), max_chunk_s=min(limits, default=MAX_CHUNK_S),
        residency=getattr(engine, "residency", "device"), accepts_blocks=getattr(engine, "accepts_blocks", False) is True,
        max_block_s=block_limit(getattr(engine, "max_block_s", None)))


class Engine:
    name = "engine"
    supports_lid = False                 # True: detect_languages() works; False: language=None goes to the model
    prompt_frames: dict[str, str] = {}   # language -> text that precedes the vocabulary list in the prompt
    chunk_params: dict = {}              # overrides for vad.plan_chunks
    # --- engine seam: every default is what a local Whisper engine does
    engine_id = ""                       # key in REGISTRY ("" = not registered: describe() falls back to ``name``)
    kind = "local"                       # local | server | cloud
    residency = "device"                 # device | a country code | foreign (policy.ENGINE_META is the single source for the policy)
    uses_prompt = True                   # False: asr skips build_asr_prompt, the tokenizer and the retry without prompt
    timing = "segment"                   # segment | chunk
    confidence = "logprob"               # logprob | opaque | none
    accepts_blocks = False               # True (with a ``max_block_s`` of 30 to 1800): the chunk is a block of speech, see ``BlockUpload``
    max_block_s = 0.0

    def __init__(self, model: str, *, allow_download: bool = True):
        self.model = model
        self.allow_download = allow_download
        self.path: str | None = None

    @property
    def caps(self) -> EngineCaps:
        return engine_caps(self)

    def describe(self) -> dict:
        """Content-free description for logs and status (no host, no secret)."""
        c = self.caps
        return {"engine": self.engine_id or self.name, "model": self.model, "kind": c.kind, "residency": c.residency,
                "uses_prompt": c.uses_prompt, "supports_lid": c.supports_lid, "timing": c.timing, "confidence": c.confidence}

    def usage(self) -> dict:
        """What this engine sent so far (requests, audio seconds, bytes) for an external engine; nothing leaves the Mac for a local one."""
        return {}

    def provenance(self) -> dict | None:
        """The ``transcript.json["asr"]`` block of an external or routed engine; None for a local engine (no key is added)."""
        return None

    def prompt_text_seen(self) -> str | None:
        """The prompt text an engine that builds its own prompt (``uses_prompt`` False) actually used, for the echo guard of the post-filter."""
        return None

    def progress_tag(self) -> str:
        """Appended to the progress message ("transcribing remote 12/48 [server]"); empty for a local engine."""
        return ""

    def set_track_context(self, track: str, solo: bool, platform: str = "") -> None:
        """Told by ``asr.transcribe_track`` before the chunks of a track: ``track`` (mic | remote | audio), ``solo`` (it is the only track of the
        meeting) and the session's ``platform`` (zoom | teams | meet | manual, "" when unknown). An engine that decides something per track (CLOVA's
        speaker separation) overrides this; every other engine ignores it."""

    def load(self) -> None:
        raise NotImplementedError

    @property
    def tokenizer(self):
        """Object with ``encode(str) -> list[int]`` used to budget the prompt."""
        raise NotImplementedError

    def detect_languages(self, clips: list[np.ndarray], languages=LID_CANDIDATES) -> list[dict] | None:
        """Per clip ``{code: p for code in languages} | {"top": best}`` (restricted and renormalised, see ``restrict_lid``) or None
        when the engine has no language ID."""
        return None

    def transcribe_chunk(self, audio: np.ndarray, language: str | None, prompt: str | None) -> dict:
        raise NotImplementedError

    def release(self) -> None:
        pass


class BlockUpload:
    """Mixin of an ``asr_http.HttpEngine`` adapter that takes blocks of speech (``class MyEngine(BlockUpload, HttpEngine)``): billing rounds up
    per request, so ``asr.py`` concatenates the VAD chunks of a track into blocks of up to ``ASR_CLOUD_BLOCK_SECONDS`` (silence between them is
    already cut out) and sends one request per block. The engine only says so (``accepts_blocks``, ``max_block_s``); ``asr.py`` packs, calls
    ``transcribe_chunk`` with a block and maps the segment times back to the original timeline. The mixin adds what a long request needs:
    its own time limit (the default ``ASR_REQUEST_TIMEOUT_S`` of 90 s is sized for a 28 s chunk), the track context the engine was told, the block
    length its provider takes at most (``Provider.max_block_s``) and what to do when a service answers a block with 413: the engine remembers half
    of that length, raises ``EngineBlockDeclined`` for it and for every block that long after it (nothing is sent again), and ``asr.py`` goes on
    with shorter blocks (``split_block``)."""
    accepts_blocks = True
    track_context: dict = {}
    _learned_block_s: float | None = None             # half of the longest block the service refused (HTTP 413) during this run

    @property
    def max_block_s(self) -> float:                                  # type: ignore[override]
        """``ASR_CLOUD_BLOCK_SECONDS`` within the range and the provider's own ceiling (``asr_providers.block_seconds``), and not above what
        the service accepted after it refused a block (``_learned_block_s``)."""
        seconds = block_seconds(getattr(self, "cfg", None), self.engine_id)
        if self._learned_block_s is not None:
            seconds = min(seconds, self._learned_block_s)
        return max(seconds, MIN_BLOCK_S)

    def set_track_context(self, track: str, solo: bool, platform: str = "") -> None:
        self.track_context = {"track": str(track), "solo": bool(solo), "platform": str(platform or "")}

    def _require_consented_destination(self) -> None:
        """The host and port of this engine's URL setting are the ones the decision (the consent) was made for: a settings file edited after the
        decision sends nothing and reads no key (``EnginePolicyDenied``, code ``host_not_consented``). A missing destination is ``HttpEngine``'s
        business (``no_host``)."""
        if self.host is not None and provider_target(self.cfg, self.engine_id)[0] != (self.host, self.port):
            exc = EnginePolicyDenied("the destination of the settings is not the consented one: nothing is sent and the key is not read")
            exc.status, exc.code = None, "host_not_consented"
            raise exc

    def exchange(self, op, method, path, headers, body, *, audio_s: float = 0.0, timeout=None):
        learned = self._learned_block_s
        if audio_s > MAX_CHUNK_S and learned is not None and audio_s > learned:      # the service refused a block this long: nothing is sent
            raise self._declined()
        if timeout is None:                                          # a request of a quarter of an hour of speech is not a 90 s request
            timeout = min(max(float(self.cfg.asr_request_timeout_s), BLOCK_TIMEOUT_BASE_S + float(audio_s)), 600.0)
        try:
            return super().exchange(op, method, path, headers, body, audio_s=audio_s, timeout=timeout)
        except EngineError as exc:
            if getattr(exc, "status", None) != 413 or audio_s <= MAX_CHUNK_S:         # a 413 for a chunk is that chunk's own business
                raise
            half = audio_s / 2.0                                                      # the next blocks are shorter than this one was
            self._learned_block_s = half if learned is None else min(learned, half)
            raise self._declined() from None

    @staticmethod
    def _declined() -> EngineBlockDeclined:
        exc = EngineBlockDeclined("the service refused a block of this length (HTTP 413): it is sent in smaller pieces")
        exc.status, exc.code = 413, "block_too_large"
        return exc


# --------------------------------------------------------------------------------------
# Whisper (mlx-whisper)
# --------------------------------------------------------------------------------------
def _whisper_files_present(p: Path) -> bool:
    return (p / "config.json").exists() and ((p / "weights.safetensors").exists() or (p / "weights.npz").exists())


class WhisperEngine(Engine):
    name = "whisper"
    engine_id = "whisper"
    supports_lid = True
    prompt_frames = {
        "ko": "다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: ",
        "en": "A medical AI meeting. Terms: ",
    }
    # SPEC 13.2 decode settings. language=None, beam_size, initial_prompt='' and verbose=False are never passed.
    DECODE_KW = dict(
        condition_on_previous_text=False,
        temperature=(0.0, 0.2, 0.4, 0.6),
        compression_ratio_threshold=2.4,
        logprob_threshold=-1.0,
        no_speech_threshold=0.6,
        word_timestamps=False,
        fp16=True,
        verbose=None,
    )

    def __init__(self, model: str, *, allow_download: bool = True):
        super().__init__(model, allow_download=allow_download)
        self._tokenizer = None

    def load(self) -> None:
        if self.path is not None:
            return
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        self.path = resolve_model_path(self.model, allow_download=self.allow_download, check=_whisper_files_present)
        ModelHolder.get_model(self.path, mx.float16)          # same cache key transcribe() uses, so it is loaded once

    @property
    def tokenizer(self):
        if self._tokenizer is None:
            from mlx_whisper.tokenizer import get_tokenizer

            self._tokenizer = get_tokenizer(True, num_languages=100, language="ko", task="transcribe")
        return self._tokenizer

    def detect_languages(self, clips: list[np.ndarray], languages=LID_CANDIDATES, batch: int = 4) -> list[dict]:
        """Language probabilities for each clip (<= 30 s each), restricted to ``languages`` (ASR_LANGUAGES) and renormalised:
        ``{"ko": p, "en": p, "top": code}``. The mel is computed like Whisper's own detection does (audio followed by 30 s of
        zeros, first 3000 frames)."""
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.transcribe import ModelHolder

        self.load()
        model = ModelHolder.get_model(self.path, mx.float16)
        out: list[dict] = []
        try:
            for i in range(0, len(clips), batch):
                mels = []
                for a in clips[i: i + batch]:
                    mel = log_mel_spectrogram(np.ascontiguousarray(a[:N_SAMPLES], dtype=np.float32),
                                              n_mels=model.dims.n_mels, padding=N_SAMPLES)
                    mels.append(pad_or_trim(mel[:N_FRAMES], N_FRAMES, axis=-2))
                _, probs = model.detect_language(mx.stack(mels).astype(mx.float16))
                for p in probs:
                    out.append(restrict_lid(p, languages))
        finally:
            mx.clear_cache()
        return out

    def transcribe_chunk(self, audio: np.ndarray, language: str | None, prompt: str | None) -> dict:
        import mlx.core as mx
        import mlx_whisper

        self.load()
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        if language is None:                                   # never let mlx-whisper auto-detect on its own
            language = self.detect_languages([audio])[0]["top"] if len(audio) else "en"
        try:
            r = mlx_whisper.transcribe(audio, path_or_hf_repo=self.path, language=language,
                                       initial_prompt=prompt or None, **self.DECODE_KW)
        finally:
            mx.clear_cache()                                   # do not let the MLX buffer cache hoard RAM between chunks
        segments = [{
            "start": float(s["start"]), "end": float(s["end"]), "text": s["text"].strip(),
            "avg_logprob": float(s["avg_logprob"]), "no_speech_prob": float(s["no_speech_prob"]),
            "compression_ratio": float(s["compression_ratio"]), "temperature": float(s.get("temperature", 0.0)),
        } for s in r.get("segments", [])]
        lps = [s["avg_logprob"] for s in segments]
        return {"text": r.get("text", "").strip(), "segments": segments, "language": language,
                "avg_logprob": float(np.mean(lps)) if lps else None}

    def release(self) -> None:
        try:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
            mx.clear_cache()
        except Exception:
            pass


# --------------------------------------------------------------------------------------
# Qwen3-ASR (benchmark only)
# --------------------------------------------------------------------------------------
class _ApproxTokenizer:
    """Conservative token estimate for prompt budgeting when there is no real tokenizer (about 1 token per 1.5 chars)."""

    def encode(self, text: str) -> list[int]:
        return [0] * int(len(text) / 1.5 + 1)


class QwenEngine(Engine):
    """mlx-qwen3-asr (https://github.com/moona3k/mlx-qwen3-asr). BENCHMARK ONLY and not exercised against real weights here:
    the wiring follows the package's documented ``transcribe(audio, model=, language=, context=)`` API. Notes from the
    research (docs/research/asr-landscape.md): no 4-bit/5-bit checkpoints (they destroy Korean), language auto-detection
    collapses on mixed ko/en audio, the ``context`` string can leak into the output, and long chunks beat small VAD pieces."""

    name = "qwen3-asr"
    engine_id = "qwen3-asr"
    supports_lid = False
    prompt_frames = {"ko": "Technical terms: ", "en": "Technical terms: "}
    chunk_params = {"max_inner_gap_s": 4.0}                    # prefer fewer, longer chunks
    LANGUAGE_NAMES = {"ko": "Korean", "en": "English"}

    def __init__(self, model: str, *, allow_download: bool = True):
        if re.search(r"(?<![0-9])[345]\s*-?\s*bit", model, re.IGNORECASE):
            raise ValueError("Qwen3-ASR with <= 5-bit quantization is not allowed (SPEC 13.2): use bf16 or 8-bit")
        super().__init__(model, allow_download=allow_download)
        self._mod = None

    def load(self) -> None:
        if self._mod is not None:
            return
        try:
            import mlx_qwen3_asr
        except ImportError as exc:
            raise EngineUnavailable("Qwen3-ASR needs the 'mlx-qwen3-asr' package (benchmark venv only): "
                                    f"pip install mlx-qwen3-asr  [{exc}]") from exc
        self._mod = mlx_qwen3_asr
        self.path = resolve_model_path(self.model, allow_download=self.allow_download)

    @property
    def tokenizer(self):
        return _ApproxTokenizer()

    def transcribe_chunk(self, audio: np.ndarray, language: str | None, prompt: str | None) -> dict:
        self.load()
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        r = self._mod.transcribe(audio, model=self.model, language=self.LANGUAGE_NAMES.get(language) if language else None,
                                 context=prompt or "")
        text = (getattr(r, "text", "") or "").strip()
        truncated = bool(getattr(r, "truncated", False))
        finish = getattr(r, "finish_reason", None)
        seg = {"start": 0.0, "end": len(audio) / SR, "text": text, "avg_logprob": None, "no_speech_prob": None,
               "compression_ratio": None, "temperature": 0.0}
        return {"text": text, "segments": [seg] if text else [], "language": getattr(r, "language", language),
                "avg_logprob": None, "finish_reason": finish, "truncated": truncated or (finish not in (None, "eos"))}

    def release(self) -> None:
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:
            pass


# --------------------------------------------------------------------------------------
# registry and factory
# --------------------------------------------------------------------------------------
# Engine id -> "module:Class". Static (no plugin discovery) and imported lazily, so naming an engine costs nothing until it is used.
# policy.ENGINE_META holds kind/residency/status of the same ids and a test pins that the keys match. ``google`` is a
# stub without an adapter: engine_class raises EngineUnavailable for it.
REGISTRY: dict[str, str] = {
    "whisper": f"{__name__}:WhisperEngine",
    "qwen3-asr": f"{__name__}:QwenEngine",
    "remote": "mcap.asr_remote:RemoteEngine",
    "azure": "mcap.asr_azure:AzureFastEngine",
    "google": "mcap.asr_google:GoogleEngine",
}
REGISTRY.update({name: provider.adapter for name, provider in PROVIDERS.items()})       # clova, openai-compat: one entry in asr_providers.PROVIDERS

# Engines that only the ASR server builds from ``backend`` of asr-server.json (``asr_server.default_backend_factory`` -> ``engine_class``),
# with the same "module:Class" form and lazy import. Kept out of REGISTRY on purpose: REGISTRY is what a CLIENT can be configured with
# (``policy.ENGINE_META`` has the same keys and a test pins it), while these have no ENGINE_META row, so no policy decision names them,
# ``asr_router.build_member`` refuses them and ``ASR_ENGINE`` can not select them. Importing this module never imports them.
SERVER_BACKENDS: dict[str, str] = {
    "faster-whisper": "mcap.asr_faster_whisper:FasterWhisperEngine",
}


def engine_class(engine_id: str) -> type:
    """The class registered under ``engine_id`` (imported on first use; ``REGISTRY`` first, then ``SERVER_BACKENDS``). ``EngineUnavailable``
    for an unknown id, a module that is not installed (an optional adapter, a stub) or a class that is missing from its module."""
    target = REGISTRY.get(engine_id) or SERVER_BACKENDS.get(engine_id)
    if target is None:
        raise EngineUnavailable(f"unknown ASR engine {engine_id!r} (known: {', '.join(sorted({*REGISTRY, *SERVER_BACKENDS}))})")
    module_name, _, attr = target.partition(":")
    try:
        module = sys.modules[__name__] if module_name == __name__ else importlib.import_module(module_name)
        return getattr(module, attr)
    except (ImportError, AttributeError) as exc:
        raise EngineUnavailable(f"ASR engine {engine_id!r} is not available ({type(exc).__name__}: {exc})") from exc


_engines: dict[tuple[str, bool], Engine] = {}


def is_qwen_model(model: str) -> bool:
    low = model.lower()
    return "qwen3_asr" in low or "qwen3-asr" in low


def create_engine(model: str, *, allow_download: bool = True) -> Engine:
    """New engine instance for a model name (nothing is loaded until ``load()``)."""
    return QwenEngine(model, allow_download=allow_download) if is_qwen_model(model) else WhisperEngine(model, allow_download=allow_download)


def get_engine(model: str, *, allow_download: bool = True) -> Engine:
    """Process-wide engine per (model name, allow_download) (a loaded large-v3 is 3 GB; mic and remote tracks share it). The download
    flag is part of the key: a local-only run (downloads off) must never reuse the engine an earlier run created with downloads on."""
    key = (model, bool(allow_download))
    if key not in _engines:
        _engines[key] = create_engine(model, allow_download=allow_download)
    return _engines[key]
