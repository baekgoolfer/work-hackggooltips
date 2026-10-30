"""faster-whisper (CTranslate2) backend of the mcap-asr/1 server, for a Linux host with an NVIDIA GPU or, slowly, a CPU
(docs/ASR_SERVER_LINUX.md). Selected by ``"backend": "faster-whisper"`` in asr-server.json; the client never selects,
configures or imports it (it is in ``asr_engines.SERVER_BACKENDS``, not in ``REGISTRY``, and has no ``policy.ENGINE_META`` row).

Importing this module imports neither ``faster_whisper`` nor ``ctranslate2``, opens no socket and reads no file: both packages are
imported inside ``load()``, so a machine without them (every laptop, the client venv) can import, test and describe the class, and a server
without them fails at start with an error that says what to install. Nothing is downloaded unless ``allow_download`` is true AND
``HF_HUB_OFFLINE`` is not set; the server builds the engine with downloads off (``for_server``) and sets ``HF_HUB_OFFLINE=1`` itself.

The contract is the one of ``WhisperEngine``: ``transcribe_chunk(audio, language, prompt) -> {"text", "segments", "language", "avg_logprob"}``
with segment times relative to the chunk and ``avg_logprob`` / ``no_speech_prob`` / ``compression_ratio`` straight from the decoder, so the
post-filters (``asr._suspicious``, ``asr.postfilter``) and the prompt retry of ``asr.decode_chunk`` apply unchanged. Decode settings mirror
SPEC 13.2 (temperature fallback 0 / .2 / .4 / .6, compression ratio 2.4, log-prob -1.0, no-speech 0.6, no conditioning on previous text,
no word timestamps) plus the two that faster-whisper adds: its own VAD stays OFF (the client already cut the speech) and a beam of 5. The
vocabulary goes to ``initial_prompt`` only (``hotwords`` is never used: it would move the terms to a different place in the decoder prompt
than the mlx-whisper path puts them). The prompt budget (``asr.ASR_PROMPT_TOKENS``, 140) is counted with the model's own
tokenizer, the way faster-whisper encodes ``initial_prompt`` (``" " + prompt.strip()``).

Device and compute type (asr-server.json ``backend_options``): ``device`` auto | cuda | cpu, ``compute_type`` float16 | int8_float16 | int8.
``auto`` takes CUDA when CTranslate2 sees a device and otherwise the CPU; if CUDA is there but the model cannot start on it (a missing
cuDNN library shows only when the first chunk is decoded, so ``load()`` decodes one second of silence), ``auto`` falls back to the CPU with
a WARNING. ``cuda`` never falls back: a server that was told to use the GPU and cannot must not run quietly at a tenth of the speed.
On the CPU the two float16 types do not exist, so they become ``int8`` (WARNING); the same chain applies on a GPU that does not support the
requested type (float16 -> int8_float16 -> int8). Nothing in this file was run against a real GPU or a real faster-whisper (the tests inject a
fake module); the first start on the real machine is the test (``python -m mcap.asr_faster_whisper check --load``).

``python -m mcap.asr_faster_whisper check [--load]`` prints what is installed, the device plan and whether the model is complete (no
download; ``--load`` also starts it and decodes one second of silence); ``fetch --yes`` is the one explicit, logged download.
"""
from __future__ import annotations

import argparse
import gc
import logging
import math
import os
import sys
import threading
import time
from pathlib import Path
from typing import Callable, NamedTuple

import numpy as np

from .asr_engines import (LID_CANDIDATES, SR, Engine, EngineUnavailable, ModelNotAvailable, WhisperEngine, resolve_model_path,
                          restrict_lid)

log = logging.getLogger("mcap.asr")

DEFAULT_MODEL = "large-v3"                      # a name of MODEL_REPOS, an HF repo id or a directory (asr-server.json "model")
N_SAMPLES = 30 * SR                             # Whisper's window: language ID looks at the first 30 s of a clip at most
DEVICES = ("auto", "cuda", "cpu")
COMPUTE_CHAIN = ("float16", "int8_float16", "int8")     # best first: what a type that is not supported falls back to
COMPUTE_TYPES = COMPUTE_CHAIN
SERVER_OPTIONS = ("device", "device_index", "compute_type", "beam_size", "cpu_threads", "num_workers", "warmup")   # backend_options keys

# Short names -> CTranslate2 repositories of the Hugging Face hub (the table faster_whisper.utils keeps; [미검증] against the 2026 hub).
# A name that is not here is NOT guessed: pass the repo id ("owner/name") or a directory. There is no short name for the turbo model on purpose:
# the repository that served it moved to another organisation, so pass the repo id you have checked.
MODEL_REPOS = {
    "tiny": "Systran/faster-whisper-tiny",
    "base": "Systran/faster-whisper-base",
    "small": "Systran/faster-whisper-small",
    "medium": "Systran/faster-whisper-medium",
    "large-v2": "Systran/faster-whisper-large-v2",
    "large-v3": "Systran/faster-whisper-large-v3",
    "distil-large-v3": "Systran/faster-distil-whisper-large-v3",
}
INSTALL_HINT = "pip install -r pipeline/requirements-server.txt in the SERVER venv (never the client venv; docs/ASR_SERVER_LINUX.md)"


def hf_offline() -> bool:
    """HF_HUB_OFFLINE the way huggingface_hub reads it (1, ON, YES, TRUE in any case)."""
    return os.environ.get("HF_HUB_OFFLINE", "").strip().upper() in {"1", "ON", "YES", "TRUE"}


def ct2_files_present(path: Path) -> bool:
    """Is ``path`` a complete CTranslate2 Whisper model? ``tokenizer.json`` is required on purpose: without it faster-whisper fetches
    a tokenizer from the hub, which an offline server must never do."""
    return (all((path / name).is_file() for name in ("model.bin", "config.json", "tokenizer.json"))
            and ((path / "vocabulary.json").is_file() or (path / "vocabulary.txt").is_file()))


class RuntimePlan(NamedTuple):
    device: str                  # cuda | cpu
    compute_type: str            # float16 | int8_float16 | int8
    notes: tuple                 # one sentence per fallback that was taken (each is logged as a WARNING)


def plan_runtime(device: str, compute_type: str, *, cuda_count: int, supported: Callable[[str], "set | None"]) -> RuntimePlan:
    """Resolve the configured ``device`` / ``compute_type`` against what the host offers (a pure function, tested without a GPU).
    ``cuda_count``: CUDA devices CTranslate2 sees. ``supported(device)``: the compute types CTranslate2 supports there, or None when that
    is unknown (then the CPU keeps ``int8`` only and a GPU keeps the requested type). ``EngineUnavailable`` for ``cuda`` without a device and
    when no type of the chain is supported."""
    notes: list[str] = []
    if device == "cuda":
        if cuda_count < 1:
            raise EngineUnavailable("device 'cuda' was requested but CTranslate2 sees no CUDA device (NVIDIA driver, CUDA 12 libraries, "
                                    "cuDNN 9?): fix the host, or set device to 'auto' or 'cpu' (docs/ASR_SERVER_LINUX.md)")
        resolved = "cuda"
    elif device == "cpu":
        resolved = "cpu"
    else:
        resolved = "cuda" if cuda_count >= 1 else "cpu"
        if resolved == "cpu":
            notes.append("no CUDA device is visible to CTranslate2: running on the CPU (much slower than real time on a large model)")
    chain = COMPUTE_CHAIN[COMPUTE_CHAIN.index(compute_type):]
    available = supported(resolved)
    if available is None:
        usable = [c for c in chain if resolved == "cuda" or c == "int8"]
    else:
        usable = [c for c in chain if c in available]
    if not usable:
        raise EngineUnavailable(f"compute_type {compute_type!r} (and the cheaper ones) is not supported on {resolved}"
                                + (f": CTranslate2 reports {', '.join(sorted(available)) or 'nothing'}" if available is not None else ""))
    if usable[0] != compute_type:
        notes.append(f"compute_type {compute_type} is not available on {resolved}: using {usable[0]}")
    return RuntimePlan(resolved, usable[0], tuple(notes))


class _Tokenizer:
    """The ``encode(str) -> list[int]`` of the prompt budget, over the Hugging Face tokenizer faster-whisper keeps (``hf_tokenizer``)."""

    def __init__(self, hf_tokenizer):
        self._hf = hf_tokenizer

    def encode(self, text: str) -> list[int]:
        out = self._hf.encode(text, add_special_tokens=False)        # tokenizers.Encoding: .ids; a plain list is accepted too
        return list(getattr(out, "ids", out))


def _finite(value, default=None):
    """``value`` as a float, ``default`` for None, NaN and infinity (a log-prob of -inf must not reach a JSON answer)."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _import_faster_whisper():
    try:
        import faster_whisper
    except (ImportError, OSError) as exc:                           # OSError: a shared library of CTranslate2 or onnxruntime is missing
        raise EngineUnavailable(f"faster-whisper cannot be imported: {INSTALL_HINT}  [{type(exc).__name__}: {exc}]") from exc
    return faster_whisper


def _import_ct2():
    try:
        import ctranslate2
    except (ImportError, OSError):
        return None
    return ctranslate2


def _cuda_count(ct2) -> int:
    try:
        return max(0, int(ct2.get_cuda_device_count())) if ct2 is not None else 0
    except Exception:                                               # no driver, no library: no device
        return 0


def _supported_types(ct2, device: str):
    try:
        return {str(t) for t in ct2.get_supported_compute_types(device)} if ct2 is not None else None
    except Exception:
        return None


class FasterWhisperEngine(Engine):
    """CTranslate2 Whisper behind the ``Engine`` interface (see the module docstring). A local-model engine from the point of view of the
    process that runs it (``kind`` local, ``residency`` device: the audio never leaves the server); the server reports it to clients as
    backend kind ``server``."""

    name = "faster-whisper"
    engine_id = "faster-whisper"
    supports_lid = True
    prompt_frames = WhisperEngine.prompt_frames
    # SPEC 13.2 decode settings in faster-whisper's names. Never passed: hotwords, word_timestamps=True, a VAD, language detection of its own.
    DECODE_KW = dict(
        vad_filter=False,
        condition_on_previous_text=False,
        temperature=(0.0, 0.2, 0.4, 0.6),
        compression_ratio_threshold=2.4,
        log_prob_threshold=-1.0,
        no_speech_threshold=0.6,
        word_timestamps=False,
    )

    def __init__(self, model: str, *, allow_download: bool = True, device: str = "auto", device_index: int = 0,
                 compute_type: str = "float16", beam_size: int = 5, cpu_threads: int = 0, num_workers: int = 1, warmup: bool = True):
        if not isinstance(model, str) or not model.strip():
            raise ValueError("faster-whisper needs a model: a name such as large-v3, a Hugging Face repo id or a directory")
        if model.lower().startswith("mlx-community/") or model.lower().endswith("-mlx"):
            raise ValueError(f"{model} is an MLX model: faster-whisper needs a CTranslate2 model such as {MODEL_REPOS['large-v3']}")
        if device not in DEVICES:
            raise ValueError(f"device must be one of {', '.join(DEVICES)} (got {device!r})")
        if compute_type not in COMPUTE_TYPES:
            raise ValueError(f"compute_type must be one of {', '.join(COMPUTE_TYPES)} (got {compute_type!r})")
        for key, value, low, high in (("device_index", device_index, 0, 64), ("beam_size", beam_size, 1, 10), ("cpu_threads", cpu_threads, 0, 256),
                                      ("num_workers", num_workers, 1, 16)):
            if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
                raise ValueError(f"{key} must be an integer from {low} to {high}")
        if not isinstance(warmup, bool):
            raise ValueError("warmup must be true or false")
        super().__init__(model.strip(), allow_download=allow_download)
        self.device, self.device_index, self.compute_type = device, device_index, compute_type
        self.beam_size, self.cpu_threads, self.num_workers, self.warmup = beam_size, cpu_threads, num_workers, warmup
        self.active_device: str | None = None            # what load() settled on (after the fallbacks)
        self.active_compute_type: str | None = None
        self._model = None
        self._tokenizer = None
        self._lock = threading.RLock()

    @classmethod
    def for_server(cls, options, *, model: str, secrets_dir) -> "FasterWhisperEngine":
        """What ``asr_server.default_backend_factory`` calls: ``options`` are the ``backend_options`` of asr-server.json (strict: an unknown
        key refuses to start, like the rest of that file), ``model`` its ``model`` ("" = ``DEFAULT_MODEL``). The server never downloads, so
        ``allow_download`` is not an option: ``fetch`` does that once, by hand. ``secrets_dir`` is unused (no vendor key)."""
        opts = dict(options or {})
        if "allow_download" in opts:
            raise ValueError("the server never downloads a model: run 'python -m mcap.asr_faster_whisper fetch --yes' once, as the service user")
        unknown = sorted(set(opts) - set(SERVER_OPTIONS))
        if unknown:
            raise ValueError(f"unknown backend_options key {unknown[0]!r} (allowed: {', '.join(SERVER_OPTIONS)})")
        return cls((model or "").strip() or DEFAULT_MODEL, allow_download=False, **opts)

    # ------------------------------------------------------------------ model and runtime
    def resolve_path(self) -> str:
        """The directory of the CTranslate2 model: a local directory as it is, else a cached or (only when allowed) downloaded repo."""
        if self.path is not None:
            return self.path
        local = Path(self.model).expanduser()
        if local.is_dir():
            if not ct2_files_present(local):
                raise ModelNotAvailable(f"{local} is not a complete CTranslate2 Whisper model (needs model.bin, config.json, tokenizer.json "
                                        "and vocabulary.json or vocabulary.txt)")
            path = str(local)
        else:
            if self.model.startswith(("/", ".", "~")):
                raise ModelNotAvailable(f"the model directory {self.model} does not exist")
            repo = MODEL_REPOS.get(self.model, self.model)
            if "/" not in repo:
                raise ModelNotAvailable(f"unknown faster-whisper model name {self.model!r} (names: {', '.join(sorted(MODEL_REPOS))}; "
                                        "or a Hugging Face repo id, or a directory)")
            download = self.allow_download and not hf_offline()
            if self.allow_download and not download:
                log.warning("downloads are allowed but HF_HUB_OFFLINE is set: %s will not be downloaded", repo)
            path = resolve_model_path(repo, allow_download=download, check=ct2_files_present)
        self.path = path
        return path

    def _plan(self, device: str, ct2) -> RuntimePlan:
        return plan_runtime(device, self.compute_type, cuda_count=_cuda_count(ct2), supported=lambda d: _supported_types(ct2, d))

    def _start(self, fw, path: str, plan: RuntimePlan):
        """Create the model for ``plan`` and decode one second of silence (CUDA kernels are loaded and a missing cuDNN shows here, not at
        the first meeting chunk). A model that was created but cannot decode is freed."""
        kwargs = dict(device=plan.device, compute_type=plan.compute_type, cpu_threads=self.cpu_threads, num_workers=self.num_workers,
                      local_files_only=True)
        if plan.device == "cuda":
            kwargs["device_index"] = self.device_index
        model = fw.WhisperModel(path, **kwargs)
        try:
            if self.warmup:
                segments, _info = model.transcribe(np.zeros(SR, np.float32), language="en", task="transcribe", beam_size=1, **self.DECODE_KW)
                for _ in segments:                                # the decoder runs while the generator is consumed
                    pass
        except BaseException:
            self._free(model)
            raise
        return model

    def load(self) -> None:
        with self._lock:
            if self._model is not None:
                return
            fw = _import_faster_whisper()
            path = self.resolve_path()
            ct2 = _import_ct2()
            plan = self._plan(self.device, ct2)
            for note in plan.notes:
                log.warning("faster-whisper: %s", note)
            try:
                model = self._start(fw, path, plan)
            except Exception as exc:
                if self.device != "auto" or plan.device != "cuda":
                    raise EngineUnavailable(f"faster-whisper could not start on {plan.device} ({plan.compute_type}): "
                                            f"{type(exc).__name__}: {str(exc)[:120]}") from exc
                log.warning("faster-whisper could not start on cuda (%s: %s): falling back to the CPU, which is much slower. Fix CUDA/cuDNN "
                            "(docs/ASR_SERVER_LINUX.md) or set device to cpu", type(exc).__name__, str(exc)[:120])
                plan = self._plan("cpu", ct2)
                for note in plan.notes:
                    log.warning("faster-whisper: %s", note)
                try:
                    model = self._start(fw, path, plan)
                except Exception as exc2:
                    raise EngineUnavailable(f"faster-whisper could not start on cuda or on the cpu: {type(exc2).__name__}: "
                                            f"{str(exc2)[:120]}") from exc2
            self._model, self._tokenizer = model, None
            self.active_device, self.active_compute_type = plan.device, plan.compute_type
            log.info("faster-whisper ready: model %s on %s (%s), beam %d", self.model, plan.device, plan.compute_type, self.beam_size)

    def _loaded(self):
        model = self._model
        if model is None:
            self.load()
            model = self._model
        if model is None:                                         # released by another thread between load() and here
            raise EngineUnavailable("the faster-whisper model was released")
        return model

    @property
    def tokenizer(self):
        """The model's own tokenizer (loads the model: ``tokenizer.json`` is part of it)."""
        model = self._loaded()
        if self._tokenizer is None:
            self._tokenizer = _Tokenizer(model.hf_tokenizer)
        return self._tokenizer

    def runtime(self) -> dict:
        """Content-free: what this engine runs on (None before ``load()``)."""
        return {"device": self.active_device, "compute_type": self.active_compute_type, "beam_size": self.beam_size,
                "model": self.model, "path_resolved": self.path is not None}

    # ------------------------------------------------------------------ decoding
    def detect_languages(self, clips: list[np.ndarray], languages=LID_CANDIDATES) -> list[dict]:
        """Language probabilities of each clip (its first 30 s), from the model's own language detection, restricted to ``languages`` and
        renormalised (``restrict_lid``): ``{"ko": p, "en": p, "top": code}``. An empty clip gets the uniform answer (the first language wins)."""
        model = self._loaded()
        out: list[dict] = []
        for clip in clips:
            audio = np.ascontiguousarray(np.asarray(clip)[:N_SAMPLES], dtype=np.float32)
            if audio.size == 0:
                out.append(restrict_lid({}, languages))
                continue
            found = model.detect_language(audio)                  # (language, probability, [(code, probability), ...])
            pairs = found[2] if len(found) > 2 and found[2] else [(found[0], found[1])]
            out.append(restrict_lid({str(code): _finite(p, 0.0) for code, p in pairs}, languages))
        return out

    def transcribe_chunk(self, audio: np.ndarray, language: str | None, prompt: str | None) -> dict:
        model = self._loaded()
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        if language is None:                                      # decide with the restricted language ID, never over all 99 languages
            language = self.detect_languages([audio])[0]["top"] if len(audio) else "en"
        if not len(audio):
            return {"text": "", "segments": [], "language": language, "avg_logprob": None}
        segments, _info = model.transcribe(audio, language=language, task="transcribe", beam_size=self.beam_size,
                                           initial_prompt=prompt or None, **self.DECODE_KW)
        raw = list(segments)                                      # lazy generator: the decoding happens while it is consumed
        out = [{
            "start": float(s.start), "end": float(s.end), "text": s.text.strip(),
            "avg_logprob": _finite(s.avg_logprob), "no_speech_prob": _finite(s.no_speech_prob),
            "compression_ratio": _finite(s.compression_ratio), "temperature": _finite(getattr(s, "temperature", 0.0), 0.0),
        } for s in raw]
        lps = [s["avg_logprob"] for s in out if s["avg_logprob"] is not None]
        return {"text": "".join(s.text for s in raw).strip(), "segments": out, "language": language,
                "avg_logprob": float(np.mean(lps)) if lps else None}

    # ------------------------------------------------------------------ release
    @staticmethod
    def _free(model) -> None:
        try:
            unload = getattr(getattr(model, "model", None), "unload_model", None)       # CTranslate2: give the device memory back now
            if callable(unload):
                unload()
        except Exception as exc:
            log.debug("unload_model failed: %s", type(exc).__name__)

    def release(self) -> None:
        with self._lock:
            model, self._model, self._tokenizer = self._model, None, None
            self.active_device = self.active_compute_type = None
        if model is not None:
            self._free(model)
        del model
        gc.collect()


# --------------------------------------------------------------------------------------
# operator commands: check and fetch
# --------------------------------------------------------------------------------------
def diagnose(engine: FasterWhisperEngine, *, load: bool = False) -> list[tuple[str, bool, str]]:
    """What ``check`` prints: (name, ok, detail) per step. Nothing is downloaded; ``load`` starts the model (and decodes one second of
    silence), which is the real test of the GPU stack."""
    rows: list[tuple[str, bool, str]] = [("python", True, sys.version.split()[0])]
    try:
        fw = _import_faster_whisper()
    except EngineUnavailable as exc:
        rows.append(("faster_whisper", False, str(exc)))
        return rows
    rows.append(("faster_whisper", True, str(getattr(fw, "__version__", "version unknown"))))
    ct2 = _import_ct2()
    count = _cuda_count(ct2)
    rows.append(("ctranslate2", ct2 is not None, f"{getattr(ct2, '__version__', 'version unknown')}, {count} CUDA device(s)" if ct2 is not None
                 else "not importable"))
    try:
        plan = engine._plan(engine.device, ct2)
        rows.append(("runtime", True, f"{plan.device} / {plan.compute_type}" + "".join(f" [{note}]" for note in plan.notes)))
    except EngineUnavailable as exc:
        rows.append(("runtime", False, str(exc)))
    try:
        rows.append(("model", True, f"{engine.model}: {engine.resolve_path()}"))
    except (ModelNotAvailable, ImportError) as exc:          # ImportError: huggingface_hub, which faster-whisper depends on, is missing
        rows.append(("model", False, f"{exc} (fetch it once: python -m mcap.asr_faster_whisper fetch --yes)"))
        return rows
    if load:
        began = time.monotonic()
        try:
            engine.load()
            runtime = engine.runtime()
            rows.append(("load", True, f"started on {runtime['device']} ({runtime['compute_type']}) in {time.monotonic() - began:.1f} s"))
        except Exception as exc:
            rows.append(("load", False, f"{type(exc).__name__}: {exc}"))
        finally:
            engine.release()
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mcap.asr_faster_whisper", description="faster-whisper backend of the mcap-asr/1 server")
    sub = parser.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check", help="what is installed, the device plan, whether the model is complete (no download)")
    fetch = sub.add_parser("fetch", help="download the model once into the Hugging Face cache of the current user (needs --yes)")
    for p in (check, fetch):
        p.add_argument("--model", default=DEFAULT_MODEL, help=f"name, repo id or directory (default {DEFAULT_MODEL})")
    check.add_argument("--device", choices=DEVICES, default="auto")
    check.add_argument("--compute-type", choices=COMPUTE_TYPES, default="float16")
    check.add_argument("--load", action="store_true", help="also start the model and decode one second of silence (loads ~3 GB)")
    fetch.add_argument("--yes", action="store_true", help="really download (about 3 GB from huggingface.co)")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        if args.cmd == "check":
            rows = diagnose(FasterWhisperEngine(args.model, allow_download=False, device=args.device, compute_type=args.compute_type),
                            load=args.load)
            for name, ok, detail in rows:
                print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
            return 0 if all(ok for _name, ok, _detail in rows) else 1
        if not args.yes:
            print("not downloading: this fetches the model (about 3 GB) from huggingface.co; add --yes to do it", file=sys.stderr)
            return 2
        if hf_offline():
            print("HF_HUB_OFFLINE is set: unset it for this one command", file=sys.stderr)
            return 1
        print(FasterWhisperEngine(args.model, allow_download=True).resolve_path())
        return 0
    except (ValueError, ModelNotAvailable, ImportError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
