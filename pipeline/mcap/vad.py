"""Voice activity detection and chunk planning (SPEC 13.2).

Two detectors produce speech *regions* ``[(start_s, end_s)]`` on a 16 kHz mono float32 track:

* **Silero** (``silero_vad.onnx`` run with onnxruntime + numpy, no torch): speech probability per 32 ms window with
  hysteresis (enter p >= 0.5, stay p >= 0.35, close after 0.30 s below, drop regions < 0.25 s). ~250x real time.
  Zero false regions on digital silence, a noise floor and the synthetic non-speech stress file (dings, noise burst,
  chord, keyboard clicks) in ``benchmarks/tts``.
* **Energy** fallback (numpy only): 20 ms frame RMS, threshold = max(-58 dBFS, 10th percentile + 10 dB,
  98th percentile - 35 dB), bridge gaps < 0.30 s, drop regions < 0.25 s. It cannot tell speech from other loud sounds:
  on the non-speech stress file it reports the dings / noise burst / chord / clicks as "speech" (the ASR post-filter then
  has to remove whatever Whisper hallucinates there). Fine for quiet rooms, clearly worse than Silero.

``ASR_VAD=auto`` picks Silero when onnxruntime and the model file are available, otherwise energy; ``silero`` insists
(raises ``VadUnavailable`` when it cannot) and ``energy`` never loads the model. A fallback is never silent: it is logged
at WARNING level and ``VadResult.degraded`` carries the reason, which ``asr.transcribe_track`` records as
``transcript.json`` ``stats.<track>.vad = "energy (silero unavailable: <reason>)"``.

``plan_chunks`` packs regions into <= 28 s Whisper windows.
"""
from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

log = logging.getLogger("mcap.vad")

# SPEC 14.4: onnxruntime 1.30 contains a Microsoft telemetry client. `import onnxruntime` alone creates
# ~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/{deviceid,onnxruntime.db} and every session queues
# events there, so the switch has to be set BEFORE the first import (ORT_DISABLE_TELEMETRY=1: no telemetry system, no
# files; verified). An explicit value in the environment wins. The disable_telemetry_events() call in SileroVAD is the
# second line of defence for an onnxruntime that was imported earlier by someone else.
os.environ.setdefault("ORT_DISABLE_TELEMETRY", "1")

SR = 16000
FRAME = 320                 # 20 ms at 16 kHz (energy VAD and cut-point search)
SILERO_WINDOW = 512         # 32 ms at 16 kHz
SILERO_MODEL_NAME = "silero_vad.onnx"


class VadUnavailable(RuntimeError):
    """ASR_VAD=silero was requested but onnxruntime or the model file is missing."""


@dataclass
class VadResult:
    regions: list[tuple[float, float]]
    backend: str                                 # "silero" | "energy"
    db: np.ndarray                               # 20 ms frame RMS in dBFS (cut-point search, echo check)
    info: dict = field(default_factory=dict)
    region_probs: list[float] | None = None      # Silero: mean speech probability of each region (None for the energy VAD)
    degraded: str = ""                           # ASR_VAD=auto fell back to energy: why Silero could not be used

    @property
    def label(self) -> str:
        """Backend name for logs / transcript.json: "silero", "energy", or "energy (silero unavailable: <reason>)"."""
        return f"{self.backend} (silero unavailable: {self.degraded})" if self.degraded else self.backend

    @property
    def speech_seconds(self) -> float:
        return float(sum(e - s for s, e in self.regions))


# --------------------------------------------------------------------------------------
# energy VAD
# --------------------------------------------------------------------------------------
def frame_db(x: np.ndarray) -> np.ndarray:
    """20 ms frame RMS in dBFS (float32 audio in [-1, 1]); digital silence is -120. The mean of each frame is removed first:
    a DC offset (cheap audio interfaces) is not speech, and without this a 0.1 offset made the whole track "loud" so that
    the adaptive threshold found no speech at all."""
    n = len(x) // FRAME
    if n == 0:
        return np.zeros(0, np.float32)
    out = np.empty(n, np.float32)
    step = 1 << 16                                           # frames per block: bounded temporary memory for hour-long tracks
    for i in range(0, n, step):
        j = min(n, i + step)
        f = np.asarray(x[i * FRAME: j * FRAME], dtype=np.float32).reshape(j - i, FRAME)
        f = f - f.mean(axis=1, keepdims=True)
        out[i:j] = 10.0 * np.log10((f * f).mean(axis=1) + 1e-12)
    return out


def _runs(mask: np.ndarray):
    m = np.concatenate(([0], mask.astype(np.int8), [0]))
    d = np.diff(m)
    return np.flatnonzero(d == 1), np.flatnonzero(d == -1)       # start index, end index (exclusive)


def energy_vad(x: np.ndarray, db: np.ndarray | None = None, *, abs_floor_db: float = -58.0, floor_margin_db: float = 10.0,
               peak_drop_db: float = 35.0, close_gap_s: float = 0.30, min_speech_s: float = 0.25):
    """Returns (regions, threshold_db)."""
    db = frame_db(x) if db is None else db
    if len(db) == 0:
        return [], abs_floor_db
    thr = max(abs_floor_db, float(np.percentile(db, 10)) + floor_margin_db, float(np.percentile(db, 98)) - peak_drop_db)
    speech = db > thr
    starts, ends = _runs(~speech)
    gap_frames = int(round(close_gap_s * SR / FRAME))
    for a, b in zip(starts, ends):                                   # bridge short pauses between speech frames
        if a > 0 and b < len(speech) and (b - a) <= gap_frames:
            speech[a:b] = True
    starts, ends = _runs(speech)
    min_frames = int(round(min_speech_s * SR / FRAME))
    regions = [(float(a * FRAME / SR), float(b * FRAME / SR)) for a, b in zip(starts, ends) if (b - a) >= min_frames]
    return regions, thr


# --------------------------------------------------------------------------------------
# Silero (onnxruntime + numpy)
# --------------------------------------------------------------------------------------
def find_silero_model(support_dir: Path | None = None) -> Path | None:
    """Model discovery order: $MCAP_SILERO_MODEL, SUPPORT_DIR/models/silero_vad.onnx, package data (mcap/data/)."""
    env = os.environ.get("MCAP_SILERO_MODEL")
    if env:
        p = Path(env).expanduser()
        return p if p.is_file() else None          # an explicit override is never silently replaced by another file
    if support_dir is None:
        from .config import DEFAULT_SUPPORT_DIR
        support_dir = DEFAULT_SUPPORT_DIR
    for p in (Path(support_dir) / "models" / SILERO_MODEL_NAME, Path(__file__).resolve().parent / "data" / SILERO_MODEL_NAME):
        if p.is_file():
            return p
    return None


def silero_model_path(cfg) -> Path | None:
    """The model the ASR stage would use (same lookup as ``detect_speech``), for callers that have a Config (``mcap doctor``)."""
    return find_silero_model(getattr(cfg, "support_dir", None))


class SileroVAD:
    """numpy + onnxruntime wrapper around silero_vad.onnx (v5/v6 interface: input [1, 64 + 512], state [2, 1, 128], sr)."""

    def __init__(self, onnx_path: Path):
        import onnxruntime as ort

        # SPEC 14.4: onnxruntime 1.30 ships a Microsoft telemetry client (writes ~/Library/Application Support/Microsoft/
        # DeveloperTools/.onnxruntime/onnxruntime.db). Switch it off before any session exists; never let this break VAD.
        try:
            ort.disable_telemetry_events()
        except Exception as exc:        # older onnxruntime without the function, or any other problem
            log.debug("onnxruntime.disable_telemetry_events() unavailable: %s", exc)
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        opts.log_severity_level = 4
        self.path = Path(onnx_path)
        self.sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"], sess_options=opts)

    def probs(self, x: np.ndarray) -> np.ndarray:
        """float32 mono 16 kHz -> speech probability for every 512-sample window."""
        x = np.asarray(x, dtype=np.float32)
        n = len(x) // SILERO_WINDOW
        state = np.zeros((2, 1, 128), np.float32)
        ctx = np.zeros((1, 64), np.float32)
        sr = np.array(SR, np.int64)
        out = np.empty(n, np.float32)
        for i in range(n):
            inp = np.concatenate([ctx, x[None, i * SILERO_WINDOW:(i + 1) * SILERO_WINDOW]], axis=1)
            p, state = self.sess.run(None, {"input": inp, "state": state, "sr": sr})
            out[i] = p[0, 0]
            ctx = inp[:, -64:]
        return out


def regions_from_probs(p: np.ndarray, *, thr: float = 0.5, neg: float = 0.35, min_silence_s: float = 0.30, min_speech_s: float = 0.25):
    """Hysteresis: enter at p >= thr, stay while p >= neg, close after min_silence_s below neg."""
    w = SILERO_WINDOW / SR
    regions, start, last_speech = [], None, None
    for i, v in enumerate(p):
        t = i * w
        if v >= thr and start is None:
            start = t
        if start is not None:
            if v >= neg:
                last_speech = t + w
            elif t + w - last_speech >= min_silence_s:
                if last_speech - start >= min_speech_s:
                    regions.append((float(start), float(last_speech)))
                start, last_speech = None, None
    if start is not None and last_speech - start >= min_speech_s:
        regions.append((float(start), float(last_speech)))
    return regions


def region_mean_probs(p: np.ndarray, regions) -> list[float]:
    """Mean Silero speech probability over the windows of each region (how sure the detector is that it is speech)."""
    w = SILERO_WINDOW / SR
    out: list[float] = []
    for s, e in regions:
        a, b = int(s / w), max(int(np.ceil(e / w)), int(s / w) + 1)
        seg = p[a:b]
        out.append(float(seg.mean()) if len(seg) else 0.0)
    return out


_silero_cache: dict[str, SileroVAD] = {}


def _get_silero(path: Path) -> SileroVAD:
    key = str(path)
    if key not in _silero_cache:
        _silero_cache[key] = SileroVAD(path)
    return _silero_cache[key]


def detect_speech(x: np.ndarray, mode: str = "auto", support_dir: Path | None = None) -> VadResult:
    """Speech regions of one track. ``mode`` is ASR_VAD: auto | silero | energy."""
    mode = (mode or "auto").strip().lower()
    if mode not in ("auto", "silero", "energy"):
        log.warning("unknown ASR_VAD=%r, using auto", mode)
        mode = "auto"
    t0 = time.time()
    db = frame_db(x)
    degraded = ""
    if mode in ("auto", "silero"):
        model = find_silero_model(support_dir)
        try:
            if model is None:
                raise VadUnavailable(f"Silero model not found (looked at $MCAP_SILERO_MODEL, {SILERO_MODEL_NAME} under "
                                     f"SUPPORT_DIR/models and the package data dir)")
            try:
                vad = _get_silero(model)
            except ImportError as exc:
                raise VadUnavailable(f"onnxruntime is not installed ({exc})") from exc
            probs = vad.probs(x)
            regions = regions_from_probs(probs)
            info = {"model": str(model), "seconds": round(time.time() - t0, 2)}
            return VadResult(regions, "silero", db, info, region_probs=region_mean_probs(probs, regions))
        except VadUnavailable as exc:
            if mode == "silero":
                raise
            degraded = str(exc)
        except Exception as exc:       # onnx runtime/model problems: auto mode must still produce a transcript
            if mode == "silero":
                raise VadUnavailable(f"Silero VAD failed: {exc}") from exc
            degraded = f"Silero VAD failed: {exc}"
        degraded = " ".join(degraded.split())[:200]
        log.warning("VAD DEGRADED: Silero is unavailable (%s); using the energy VAD, which also reports dings, typing and noise "
                    "as speech (run `mcap doctor`, or scripts/setup_python.sh --with-silero)", degraded)
    regions, thr = energy_vad(x, db)
    info = {"threshold_db": round(float(thr), 1), "seconds": round(time.time() - t0, 2)}
    if degraded:
        info["silero_unavailable"] = degraded
    return VadResult(regions, "energy", db, info, degraded=degraded)


# --------------------------------------------------------------------------------------
# chunk planning
# --------------------------------------------------------------------------------------
def _quietest_point(db: np.ndarray, t0: float, t1: float) -> float:
    a, b = int(t0 * SR / FRAME), int(t1 * SR / FRAME)
    a, b = max(0, a), min(len(db), b)
    if b - a < 3:
        return (t0 + t1) / 2
    seg = np.convolve(db[a:b], np.ones(5, np.float32) / 5, mode="same")        # 100 ms smoothing
    return float((a + int(np.argmin(seg))) * FRAME / SR)


def plan_chunks(regions, db: np.ndarray, total_s: float, *, max_chunk_s: float = 28.0, pad_s: float = 0.30,
                max_inner_gap_s: float = 2.5, min_chunk_speech_s: float = 0.40, labels: list[str] | None = None,
                region_probs: list[float] | None = None, short_keep_prob: float = 0.80, min_short_speech_s: float = 0.25):
    """Pack speech regions into Whisper windows. Returns ``[(start_s, end_s, label)]``: padded by ``pad_s`` on each side,
    sorted, non-overlapping, never longer than ``max_chunk_s`` (padding included), clipped to [0, total_s].

    * adjacent regions with the same label are merged while the pause is <= max_inner_gap_s and the speech span fits;
    * a change of label (language) always starts a new chunk;
    * a single region longer than a window is cut at the quietest 100 ms in the last 35 % of the window;
    * chunks with less than ``min_chunk_speech_s`` of speech are dropped, EXCEPT a lone region of at least
      ``min_short_speech_s`` whose mean speech probability (``region_probs``, Silero only) is >= ``short_keep_prob``: a real
      one-word answer ("네", "yes") is that short, and the 0.3 s padding on each side gives Whisper a usable window.
    """
    labels = list(labels) if labels is not None else [""] * len(regions)
    if len(labels) != len(regions):
        raise ValueError("labels must have one entry per region")
    if region_probs is not None and len(region_probs) != len(regions):
        raise ValueError("region_probs must have one entry per region")
    order = sorted(range(len(regions)), key=lambda i: regions[i][0])
    limit = max_chunk_s - 2 * pad_s
    packed: list[list] = []                                    # [start, end, label, member region indices]
    for i in order:
        (s, e), lab = regions[i], labels[i]
        if packed and packed[-1][2] == lab and (s - packed[-1][1]) <= max_inner_gap_s and (e - packed[-1][0]) <= limit:
            packed[-1][1] = max(packed[-1][1], e)
            packed[-1][3].append(i)
        else:
            packed.append([s, e, lab, [i]])
    pieces: list[tuple[float, float, str]] = []
    for s, e, lab, members in packed:
        while e - s > limit:
            cut = _quietest_point(db, s + 0.65 * limit, s + limit)
            cut = min(max(cut, s + 0.5 * limit), s + limit)    # always make progress, never exceed the window
            pieces.append((s, cut, lab))
            s = cut
        lone_but_sure = (len(members) == 1 and region_probs is not None and e - s >= min_short_speech_s
                         and region_probs[members[0]] >= short_keep_prob)
        if e - s >= min_chunk_speech_s or lone_but_sure:
            pieces.append((s, e, lab))
    padded = [[max(0.0, s - pad_s), min(total_s, e + pad_s), lab] for s, e, lab in pieces]
    for i in range(1, len(padded)):                            # padding must never overlap the neighbour
        if padded[i][0] < padded[i - 1][1]:
            mid = (padded[i][0] + padded[i - 1][1]) / 2
            padded[i][0] = padded[i - 1][1] = mid
    return [(a, b, lab) for a, b, lab in padded if b > a]
