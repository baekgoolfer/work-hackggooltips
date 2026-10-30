"""Offline acoustic echo cancellation of the microphone track (SPEC 14.2).

With laptop speakers (the user's normal setup) the microphone track contains the remote participants. The system-audio track is the
clean digital reference of what the speakers played, so the echo can be subtracted offline, with the whole recording in memory
(no real-time constraint, no look-ahead limit). Pure numpy, 16 kHz mono float arrays, index 0 = session start, same length.

Pipeline of ``cancel_echo`` (evidence: scripts/aec_eval.py and the tests):

1. activity of the reference (>= max(-60 dBFS, p98 - 32 dB) per 32 ms);
2. delay: GCC-PHAT per 30 s block over -50 ms..1.5 s, outlier rejection, steps (an output-device switch changes the delay for
   good), one clock-drift slope; refined with 5 s blocks in a +-10 ms window;
3. decision (mode "auto"): is there speaker leakage at all? Cross-validated 160 ms multi-tap coherence of the mic with the aligned
   reference >= 0.10 (headphones, hardware-AEC conference mics: ~0.0-0.02), otherwise the mic comes back bit for bit;
4. partitioned-block frequency-domain Kalman filter (13 x 32 ms = 416 ms of echo path), two passes, several streams in lock
   step; adaptation is frozen while the reference carries nothing the mic could echo;
5. residual echo suppression: spectral gain with a -15 dB floor, only where the echo estimate explains the residual (so the user
   talking over the echo keeps their bins);
6. blend + guard: exact copy of the mic wherever no echo estimate exists, and the processed signal is never allowed to be louder
   than the mic over any 0.5 s window.

Status: validated on SYNTHETIC data only (scripts/aec_eval.py, pipeline/tests/test_aec.py): on echo-only stretches ERLE is 20-30
dB (linear and mildly non-linear speakers, +-100 ppm clock drift, slow mic gain changes, clipping, a device switch), the user's
speech survives (single talk bit-near-identical, double talk >= 0.97 gain), and inputs without leakage are never touched.
Not yet measured on a real MacBook speaker / microphone recording: that is what ``scripts/aec_eval.py --session`` is for.
Known limits: a fast, large mic AGC (+-15 dB within seconds) and heavy clipping leave much of the echo (ERLE 3-10 dB; the user is
still preserved); the ASR stage has ``asr.suppress_echo`` behind it as a safety net.

``explained_fraction`` is the same multi-tap analysis used as an energy-weighted measure ("how much of this stretch of the mic
is the reference?") by ``asr.suppress_echo``.
"""
from __future__ import annotations

import logging
import math
import time
from dataclasses import dataclass
from typing import Callable

import numpy as np

log = logging.getLogger("mcap.aec")

SR = 16000
ACT = 512                      # frame length (samples) of the activity / power analysis (32 ms at 16 kHz)
Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


# --------------------------------------------------------------------------------------
# parameters
# --------------------------------------------------------------------------------------
@dataclass
class AecParams:
    # adaptive filter
    block: int = 512                 # hop of the partitioned filter (32 ms at 16 kHz), FFT length 2 * block
    partitions: int = 13             # 13 * 32 ms = 416 ms of filter
    margin: int = 320                # samples (20 ms) kept in front of the aligned direct path
    forget: float = 3e-3             # process-noise rate (1 - A^2 per block)
    lam: float = 0.8                 # smoothing of the observation-noise estimate
    p0: float = 0.5                  # initial state variance
    p_floor: float = 1e-5
    kappa: float = 2.0
    n_streams: int = 0               # 0 = auto
    passes: int = 2
    adapt_margin_db: float = 6.0     # the filter adapts only while some reference block in its span is within this of "active"
    # delay search
    min_delay_s: float = -0.05
    max_delay_s: float = 1.5
    delay_block_s: float = 30.0
    delay_min_active_s: float = 2.0
    delay_min_z: float = 8.0
    # decision
    coherence_threshold: float = 0.10
    min_ref_active_s: float = 3.0
    # residual suppressor
    res_floor_db: float = -15.0
    res_gamma: float = 2.0
    res_ne_lo: float = 2.5           # frame-level mic / expected-residual ratio below which no near-end speech is assumed
    res_ne_hi: float = 8.0           # ... and above which near-end speech is certain
    res_near_floor: float = 0.6
    res_enabled: bool = True
    guard: bool = True
    debug: dict | None = None


# --------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------
def _slice_pad(x: np.ndarray, i0: int, i1: int) -> np.ndarray:
    """x[i0:i1] with zeros outside the array (float32)."""
    out = np.zeros(max(0, i1 - i0), np.float32)
    lo, hi = max(i0, 0), min(i1, len(x))
    if hi > lo:
        out[lo - i0: hi - i0] = x[lo:hi]
    return out


def _frame_db(x: np.ndarray, frame: int = ACT) -> np.ndarray:
    n = len(x) // frame
    out = np.empty(n, np.float32)
    step = max(1, (1 << 22) // frame)
    for i in range(0, n, step):
        j = min(n, i + step)
        f = x[i * frame: j * frame].reshape(j - i, frame)
        out[i:j] = 10.0 * np.log10(np.einsum("ij,ij->i", f, f) / frame + 1e-12)
    return out


def _active_frames(db: np.ndarray) -> tuple[np.ndarray, float]:
    """Reference-active frames: above max(-60 dBFS, 98th percentile - 32 dB)."""
    if len(db) == 0:
        return np.zeros(0, bool), -60.0
    thr = max(-60.0, float(np.percentile(db, 98)) - 32.0)
    return db > thr, thr


# --------------------------------------------------------------------------------------
# delay estimation (GCC-PHAT per block) and the delay curve
# --------------------------------------------------------------------------------------
def _gcc_phat(d: np.ndarray, x: np.ndarray, n_lags: int, lag_max: int, sr: int, band=(150.0, 5000.0)):
    """Lag (samples, may be fractional) at which the mic ``d`` lags the reference, and the peak's robust z-score.

    ``x`` holds the reference samples [a - lag_max, b - lag_min) for the mic samples [a, b): c[u] = sum_n x[n + u] d[n],
    lag = lag_max - u. Phase transform weighting inside ``band``."""
    nfft = 1 << (len(x) - 1).bit_length()
    s = np.fft.rfft(x, nfft) * np.conj(np.fft.rfft(d, nfft))
    k0, k1 = int(band[0] * nfft / sr), int(band[1] * nfft / sr)
    mag = np.abs(s[k0:k1])
    w = np.zeros_like(s)
    w[k0:k1] = s[k0:k1] / (mag + 1e-3 * float(mag.mean()) + 1e-20)
    c = np.fft.irfft(w, nfft)[:n_lags].astype(np.float64)
    ac = np.abs(c)
    i = int(np.argmax(ac))
    scale = 1.4826 * float(np.median(np.abs(c - np.median(c)))) + 1e-30
    z = float(ac[i] / scale)
    frac = 0.0
    if 0 < i < len(ac) - 1:
        a, b, g = ac[i - 1], ac[i], ac[i + 1]
        den = a - 2 * b + g
        if den < 0:
            frac = float(np.clip(0.5 * (a - g) / den, -1.0, 1.0))
    return lag_max - (i + frac), z


@dataclass
class DelayEstimate:
    t: float            # block centre (s)
    lag: float          # samples; > 0 = the mic lags the reference
    z: float
    active_s: float


def _estimate_delays(mic, ref, sr, p: AecParams, ref_act: np.ndarray, progress: Progress) -> list[DelayEstimate]:
    """Coarse stage: one absolute delay per ``delay_block_s`` block over the whole search range."""
    t_len = len(mic)
    lag_min, lag_max = int(round(p.min_delay_s * sr)), int(round(p.max_delay_s * sr))
    n_lags = lag_max - lag_min + 1
    nblk = max(1, int(round(t_len / (p.delay_block_s * sr))))
    edges = np.linspace(0, t_len, nblk + 1).astype(np.int64)
    out: list[DelayEstimate] = []
    for i in range(nblk):
        a, b = int(edges[i]), int(edges[i + 1])
        act_s = float(ref_act[a // ACT: b // ACT].sum()) * ACT / sr
        if act_s < p.delay_min_active_s:
            continue
        lag, z = _gcc_phat(mic[a:b], _slice_pad(ref, a - lag_max, b - lag_min), n_lags, lag_max, sr)
        out.append(DelayEstimate((a + b) / 2.0 / sr, float(lag), z, act_s))
    return out


@dataclass
class DelayCurve:
    t: np.ndarray                   # knot positions (samples)
    d: np.ndarray                   # delay (samples) at the knots; piecewise linear in between, constant outside
    offsets: tuple = ()             # delay at t = 0 of every level (segment) of the model; slope is common to all levels
    slope: float = 0.0              # clock drift in samples per sample

    def at(self, a: int, b: int) -> np.ndarray:
        return np.interp(np.arange(a, b, dtype=np.float64), self.t, self.d)

    @property
    def is_constant(self) -> bool:
        return float(np.ptp(self.d)) < 4.0

    def median(self) -> float:
        return float(np.median(np.interp(np.linspace(self.t[0], self.t[-1], 257), self.t, self.d)))


MAX_DRIFT = 400e-6                  # the model never assumes more clock drift than this (the SPEC expects <= ~60 ppm)


def _fit_curve(est: list[DelayEstimate], n_samples: int, sr: int, min_z: float, tol_s: float = 0.004):
    """Delay curve from the valid block estimates: one drift slope shared by one or more levels (steps).

    * a block that disagrees with both neighbours while those agree with each other is an outlier and is dropped;
    * estimates that differ by more than ``tol_s`` (+ what ``MAX_DRIFT`` can explain) start a new level: an output device
      switch or a tap rebuild changes the delay for good, and a persistent change is never averaged into a line;
    * the drift is the span-weighted median of the least-squares slopes of the levels that cover >= 20 s;
    * each level's offset is the median of (delay - drift * t); levels are joined by a step half way between the last
      estimate of one and the first of the next.
    Returns (curve | None, drift_ppm)."""
    good = sorted((e for e in est if e.z >= min_z), key=lambda e: e.t)
    if not good:
        return None, 0.0
    t = np.array([e.t * sr for e in good])
    d = np.array([e.lag for e in good])
    tol = tol_s * sr
    if len(good) == 1:
        return DelayCurve(np.array([0.0, float(n_samples)]), np.array([d[0], d[0]]), (float(d[0]),), 0.0), 0.0
    keep = np.ones(len(d), bool)
    jump = np.abs(np.diff(d)) > tol + MAX_DRIFT * np.diff(t)
    for i in range(1, len(d) - 1):
        if jump[i - 1] and jump[i] and abs(d[i + 1] - d[i - 1]) <= tol + MAX_DRIFT * (t[i + 1] - t[i - 1]):
            keep[i] = False
    t, d = t[keep], d[keep]
    jump = np.abs(np.diff(d)) > tol + MAX_DRIFT * np.diff(t)
    seg = np.concatenate([[0], np.cumsum(jump)]).astype(int)
    n_seg = int(seg[-1]) + 1
    slopes, weights = [], []
    for k in range(n_seg):
        tk, dk = t[seg == k], d[seg == k]
        if len(tk) >= 3 and tk[-1] - tk[0] >= 20 * sr:
            slopes.append(float(np.polyfit(tk, dk, 1)[0]))
            weights.append(float(tk[-1] - tk[0]))
    b = 0.0
    if slopes:
        order = np.argsort(slopes)
        cw = np.cumsum(np.array(weights)[order])
        b = float(np.clip(np.array(slopes)[order][int(np.searchsorted(cw, cw[-1] / 2.0))], -MAX_DRIFT, MAX_DRIFT))
    offs = [float(np.median(d[seg == k] - b * t[seg == k])) for k in range(n_seg)]
    kt, kd = [0.0], [offs[0]]
    for k in range(1, n_seg):
        last_prev = float(t[seg == k - 1][-1])
        first_next = float(t[seg == k][0])
        mid = (last_prev + first_next) / 2.0
        kt += [mid - 1.0, mid + 1.0]
        kd += [offs[k - 1] + b * (mid - 1.0), offs[k] + b * (mid + 1.0)]
    kt.append(float(n_samples))
    kd.append(offs[-1] + b * n_samples)
    return DelayCurve(np.array(kt), np.array(kd), tuple(offs), b), b * 1e6


def _refine_curve(mic, ref, sr, curve: DelayCurve, ref_act: np.ndarray, min_z: float = 6.0, block_s: float = 5.0,
                  window: int = 160, min_active_s: float = 0.7):
    """Second stage: short blocks, narrow search. A long block smears a drifting delay, loses precision and cannot place a
    step, so every ``block_s`` block is measured in a +-``window`` sample window around the delay each level of the coarse
    curve predicts there (the best hypothesis wins) and the final curve is fitted to these absolute delays.
    Returns (curve, drift_ppm); the coarse curve and None when no block is usable."""
    t_len = len(mic)
    nblk = max(1, int(round(t_len / (block_s * sr))))
    edges = np.linspace(0, t_len, nblk + 1).astype(np.int64)
    levels = curve.offsets or (float(np.median(curve.d)),)
    pts: list[DelayEstimate] = []
    for i in range(nblk):
        a, b = int(edges[i]), int(edges[i + 1])
        act_s = float(ref_act[a // ACT: b // ACT].sum()) * ACT / sr
        if act_s < min_active_s:
            continue
        tc = (a + b) / 2.0
        best = None
        for off in levels:
            centre = int(round(off + curve.slope * tc))
            lag_max, lag_min = centre + window, centre - window
            lag, z = _gcc_phat(mic[a:b], _slice_pad(ref, a - lag_max, b - lag_min), 2 * window + 1, lag_max, sr)
            if best is None or z > best[1]:
                best = (lag, z)
        pts.append(DelayEstimate(tc / sr, float(best[0]), best[1], act_s))
    fine, ppm = _fit_curve(pts, t_len, sr, min_z)
    return (fine, ppm) if fine is not None else (curve, None)


# --------------------------------------------------------------------------------------
# reference alignment (constant shift, or drift-compensating windowed-sinc resampling)
# --------------------------------------------------------------------------------------
_PH = 128
_TAPS = 8


def _sinc_table() -> np.ndarray:
    """Kaiser-windowed sinc, 8 taps (offsets -3..4), 128 fractional phases (+1 so phase 128 == next sample)."""
    j = np.arange(-3, 5, dtype=np.float64)
    tab = np.zeros((_PH + 1, _TAPS), np.float32)
    for q in range(_PH + 1):
        u = j - q / _PH
        w = np.sinc(u) * np.i0(6.0 * np.sqrt(np.clip(1.0 - (u / 4.0) ** 2, 0.0, 1.0))) / np.i0(6.0)
        tab[q] = w / w.sum()
    return tab


_TABLE = _sinc_table()


def _align_ref(ref: np.ndarray, curve: DelayCurve, a: int, b: int, margin: int, exact: bool = False) -> np.ndarray:
    """Reference as seen by the mic samples [a, b): x_al[n] = ref(n - D(n) + margin). A (nearly) constant delay is a plain
    integer shift unless ``exact`` is set; otherwise fractional positions use 8-tap windowed-sinc interpolation."""
    if curve.is_constant and not exact:
        s = int(round(float(np.mean(curve.d))))
        return _slice_pad(ref, a - s + margin, b - s + margin)
    out = np.empty(b - a, np.float32)
    step = 1 << 18
    for i in range(a, b, step):
        j = min(b, i + step)
        pos = np.arange(i, j, dtype=np.float64) - curve.at(i, j) + margin
        i0 = np.floor(pos).astype(np.int64)
        q = np.rint((pos - i0) * _PH).astype(np.int64)
        lo = int(i0.min()) - 3
        seg = _slice_pad(ref, lo, int(i0.max()) + 5)
        idx = (i0 - lo)[:, None] + np.arange(-3, 5)[None, :]
        out[i - a: j - a] = np.einsum("nt,nt->n", seg[idx], _TABLE[q])
    return out


# --------------------------------------------------------------------------------------
# coherence of the mic with the aligned reference (decides whether there is speaker leakage at all)
# --------------------------------------------------------------------------------------
_FN, _FH = 512, 256            # STFT frame / hop of the coherence analysis
_TAPS_COH = 8                  # frames of echo path modelled (8 * 16 ms + 32 ms = 160 ms)


def _tile_scores(d: np.ndarray, x: np.ndarray, sr: int, act_thr_db: float) -> tuple[np.ndarray, np.ndarray]:
    """Frame-wise cross-validated multi-tap coherence of the mic with the aligned reference over one tile.

    Per frequency bin the mic spectrum is regressed on the last ``_TAPS_COH`` reference frames (a convolutive transfer
    function, so reverberation is modelled); the regression is fitted on one half of the tile and evaluated on the other
    (2-fold over 1.5 s chunks), so independent signals score ~0 instead of a positive fit bias. Returns, for the
    reference-active frames, the explained fraction of the mic energy (band 150-4500 Hz) and the mic energy of each frame
    (the weights for an energy-weighted mean). Both are empty when the tile is too short."""
    nfr = 1 + (len(d) - _FN) // _FH
    if nfr < 4 * _TAPS_COH:
        return np.zeros(0, np.float32), np.zeros(0, np.float32)
    win = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(_FN) / _FN)).astype(np.float32)
    sw = np.lib.stride_tricks.sliding_window_view
    k0, k1 = int(150 * _FN / sr), int(4500 * _FN / sr)
    dd = np.fft.rfft(sw(d, _FN)[::_FH][:nfr] * win, axis=-1)[:, k0:k1]
    xx = np.fft.rfft(sw(x, _FN)[::_FH][:nfr] * win, axis=-1)[:, k0:k1]
    xf = sw(x, _FN)[::_FH][:nfr]
    xdb = 10 * np.log10(np.einsum("ij,ij->i", xf, xf) / _FN + 1e-12)
    act = np.convolve((xdb > act_thr_db).astype(np.float32), np.ones(_TAPS_COH, np.float32))[: nfr] > 0
    t0 = _TAPS_COH - 1
    r = np.stack([xx[t0 - q: nfr - q] for q in range(_TAPS_COH)], axis=-1)              # [T, K, taps]
    r = np.ascontiguousarray(r.transpose(1, 0, 2))                                       # [K, T, taps]
    dm = np.ascontiguousarray(dd[t0:].T)[..., None]                                     # [K, T, 1]
    act = act[t0:]
    chunk = (np.arange(nfr - t0) // 96) % 2
    scores, energies = [], []
    for fold in (0, 1):
        fit, ev = act & (chunk != fold), act & (chunk == fold)
        if fit.sum() < 6 * _TAPS_COH or not ev.any():
            continue
        rf = r[:, fit]
        rh = rf.conj().transpose(0, 2, 1)
        a = rh @ rf
        b = rh @ dm[:, fit]
        tr = np.trace(a, axis1=1, axis2=2).real / _TAPS_COH
        a = a + (1e-3 * tr + 1e-20)[:, None, None] * np.eye(_TAPS_COH, dtype=a.dtype)
        h = np.linalg.solve(a, b)                                                        # [K, taps, 1]
        pred = r[:, ev] @ h
        res = dm[:, ev] - pred
        num = (np.abs(res[..., 0]) ** 2).sum(0)
        den = (np.abs(dm[:, ev, 0]) ** 2).sum(0)
        ok = den > 1e-7 * dd.shape[1]
        scores.append((1.0 - num / (den + 1e-30))[ok])
        energies.append(den[ok])
    if not scores:
        return np.zeros(0, np.float32), np.zeros(0, np.float32)
    return np.concatenate(scores).astype(np.float32), np.concatenate(energies).astype(np.float32)


def _tile_coherence(d: np.ndarray, x: np.ndarray, sr: int, act_thr_db: float) -> np.ndarray:
    """Per-frame explained fraction of ``_tile_scores`` (what ``decide_applicable`` averages)."""
    return _tile_scores(d, x, sr, act_thr_db)[0]


def explained_fraction(mic: np.ndarray, ref_aligned: np.ndarray, sr: int = SR) -> float | None:
    """Share (0..1) of the energy of ``mic`` that a 160 ms linear model of ``ref_aligned`` explains, cross-validated and
    weighted by frame energy: ~1 for a pure (reverberant, filtered) echo of the reference, ~0 for an independent signal (a person
    speaking, however loud the echo is underneath), and in between exactly the echo's share of the energy. ``ref_aligned`` is the
    reference already shifted by the delay of the echo path (a few tens of ms of slack are fine). ``None`` when the signal is too
    short (< ~1.5 s with reference activity) to judge."""
    mic = np.asarray(mic, dtype=np.float32)
    ref_aligned = np.asarray(ref_aligned, dtype=np.float32)
    if len(mic) != len(ref_aligned):
        raise ValueError("mic and ref_aligned must have the same length")
    db = _frame_db(ref_aligned)
    _, thr = _active_frames(db)
    frac, energy = _tile_scores(mic, ref_aligned, sr, thr)
    if len(frac) < 24 or float(energy.sum()) <= 0.0:
        return None
    return float(np.clip(np.average(np.clip(frac, 0.0, 1.0), weights=energy), 0.0, 1.0))


# --------------------------------------------------------------------------------------
# partitioned-block frequency-domain Kalman filter (overlap-save), several independent streams in parallel
# --------------------------------------------------------------------------------------
@dataclass
class _FilterState:
    w: np.ndarray       # [B, P, K] complex64, partitions ordered oldest reference block first
    pv: np.ndarray      # [B, P, K] float32 state-error variance
    psi: np.ndarray     # [B, K] float32 observation-noise PSD


def _run_filter(d: np.ndarray, x: np.ndarray, p: AecParams, n_streams: int, state: _FilterState | None = None,
                freeze: np.ndarray | None = None, label: str = "", progress: Progress = _noop):
    """Run the adaptive filter over the aligned reference ``x`` and the mic ``d`` (float32, same length).

    The signal is cut into ``n_streams`` equal segments that are processed in lock step (vectorised over the stream axis,
    which is what makes it fast in numpy). ``freeze[b, t] == 0`` stops the adaptation of stream b in block t.
    Returns (error e, echo estimate y, final state); e and y have the length of the input."""
    n, parts = p.block, p.partitions
    k = n + 1
    t_len = len(d)
    nb = -(-t_len // (n_streams * n))
    seg = nb * n
    total = n_streams * seg
    ds = np.zeros(total, np.float32)
    ds[:t_len] = d
    ds = ds.reshape(n_streams, seg)
    pad = (parts + 1) * n
    xp = np.zeros(pad + total, np.float32)
    xp[pad: pad + t_len] = x
    sw = np.lib.stride_tricks.sliding_window_view(xp, 2 * n)
    base = (np.arange(n_streams) * seg)[:, None]

    def spectra(t0: int, t1: int):
        starts = pad + base + (np.arange(t0, t1)[None, :] - 1) * n
        return np.fft.rfft(sw[starts], axis=-1)

    if state is None:
        state = _FilterState(np.zeros((n_streams, parts, k), np.complex64),
                             np.full((n_streams, parts, k), p.p0, np.float32), np.zeros((n_streams, k), np.float32))
    w, pv, psi = state.w, state.pv, state.psi
    fgt = np.float32(p.forget)
    lam = np.float32(p.lam)
    e_out = np.empty((n_streams, seg), np.float32)
    y_out = np.empty((n_streams, seg), np.float32)
    carry = spectra(-(parts - 1), 0)
    chunk = 64
    next_report = 0.1
    for t0 in range(0, nb, chunk):
        t1 = min(nb, t0 + chunk)
        xall = np.concatenate([carry, spectra(t0, t1)], axis=1)
        x2all = (xall.real * xall.real + xall.imag * xall.imag).astype(np.float32)
        for j in range(t1 - t0):
            t = t0 + j
            v, v2 = xall[:, j: j + parts], x2all[:, j: j + parts]
            yf = (w * v).sum(axis=1)
            y = np.fft.irfft(yf, 2 * n, axis=-1)[:, n:]
            e = ds[:, t * n: (t + 1) * n] - y
            ef = np.fft.rfft(np.concatenate([np.zeros_like(e), e], axis=1), axis=-1)
            e2 = (ef.real * ef.real + ef.imag * ef.imag) * np.float32(p.kappa)
            psi = lam * psi + (1 - lam) * e2
            sx = (pv * v2).sum(axis=1)
            s = sx + np.maximum(psi, 0.5 * e2) + np.float32(1e-9)
            g = pv / s[:, None, :]
            dw = g * np.conj(v) * ef[:, None, :]
            dwt = np.fft.irfft(dw, 2 * n, axis=-1)
            dwt[..., n:] = 0
            dw = np.fft.rfft(dwt, axis=-1)
            if freeze is not None:
                m = freeze[:, t][:, None, None]
                dw = dw * m
                g = g * m
            w = w + dw
            pv = (1 - 0.5 * g * v2) * pv + fgt * (w.real * w.real + w.imag * w.imag + np.float32(p.p_floor))
            e_out[:, t * n: (t + 1) * n] = e
            y_out[:, t * n: (t + 1) * n] = y
        carry = xall[:, -(parts - 1):] if parts > 1 else xall[:, :0]
        if t1 / nb >= next_report:
            progress(f"echo cancellation {label} {int(100 * t1 / nb)}%")
            next_report += 0.1
    return e_out.reshape(-1)[:t_len], y_out.reshape(-1)[:t_len], _FilterState(w, pv, psi)


# --------------------------------------------------------------------------------------
# residual echo suppression (spectral gain with a floor) and the final blend / guard
# --------------------------------------------------------------------------------------
_RN, _RH = 512, 256            # STFT frame / hop of the residual suppressor (sqrt-Hann, 50 % overlap)
_RK = _RN // 2 + 1


def _box_time(a: np.ndarray, w: int) -> np.ndarray:
    """Mean over ``w`` (odd) neighbouring frames along axis 0 (edge frames repeat)."""
    h = w // 2
    pad = np.concatenate([a[:1].repeat(h, 0), a, a[-1:].repeat(h, 0)], axis=0)
    return sum(pad[i: i + len(a)] for i in range(w)) / w


def _box_freq(a: np.ndarray, w: int) -> np.ndarray:
    h = w // 2
    pad = np.concatenate([a[:, :1].repeat(h, 1), a, a[:, -1:].repeat(h, 1)], axis=1)
    return sum(pad[:, i: i + a.shape[1]] for i in range(w)) / w


def _suppress_residual(e: np.ndarray, y: np.ndarray, p: AecParams, sr: int, progress: Progress = _noop):
    """Attenuate the echo that the linear filter leaves behind (nonlinear distortion, tails, misadjustment).

    Per time-frequency bin the residual echo is modelled as ``rho[k] * |echo estimate|^2`` (``rho`` = measured
    residual-to-estimate ratio of the echo-dominated frames of this very file); the gain is the Wiener-style
    ``1 - residual / (power of e)``, floored at ``res_floor_db`` so nothing is ever gated hard. Where real speech (the user)
    dominates the bin, ``|e|^2 >> residual`` and the gain stays 1. Returns (output, info)."""
    t_len = len(e)
    nfr = (t_len + _RH - 1) // _RH + 1
    total = (nfr + 3) * _RH
    ep = np.zeros(total, np.float32)
    ep[_RH: _RH + t_len] = e
    yp = np.zeros(total, np.float32)
    yp[_RH: _RH + t_len] = y
    win = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(_RN) / _RN)).astype(np.float32)
    swe = np.lib.stride_tricks.sliding_window_view(ep, _RN)
    swy = np.lib.stride_tricks.sliding_window_view(yp, _RN)
    k0, k1 = int(200 * _RN / sr), int(4000 * _RN / sr)
    chunk, margin = 2048, 2

    def spectra(f0: int, f1: int):
        """E, smoothed |E|^2 and smoothed |Y|^2 of frames [f0, f1) (context frames are read but not returned)."""
        g0, g1 = max(0, f0 - margin), min(nfr, f1 + margin)
        ee = np.fft.rfft(swe[g0 * _RH: g1 * _RH: _RH][: g1 - g0] * win, axis=-1)
        yy = np.fft.rfft(swy[g0 * _RH: g1 * _RH: _RH][: g1 - g0] * win, axis=-1)
        pe = _box_time(ee.real ** 2 + ee.imag ** 2, 3)
        py = _box_freq(_box_time(yy.real ** 2 + yy.imag ** 2, 3), 5)
        a, b = f0 - g0, f0 - g0 + (f1 - f0)
        return ee[a:b], pe[a:b], py[a:b]

    # sweep 1: frame-level sums for all frames, per-bin spectra of every 4th frame (statistics only)
    fe = np.empty(nfr, np.float32)
    fy = np.empty(nfr, np.float32)
    samp_e, samp_y = [], []
    for f0 in range(0, nfr, chunk):
        f1 = min(nfr, f0 + chunk)
        _, pe, py = spectra(f0, f1)
        fe[f0:f1] = pe[:, k0:k1].sum(1)
        fy[f0:f1] = py[:, k0:k1].sum(1)
        samp_e.append(pe[::4].copy())
        samp_y.append(py[::4].copy())
    samp_e, samp_y = np.concatenate(samp_e), np.concatenate(samp_y)
    fe_s, fy_s = fe[::4], fy[::4]
    noise = float(np.percentile(fe[fe > 1e-12], 5)) if (fe > 1e-12).any() else 1e-10
    echo = fy_s > 30.0 * noise
    info = {"res_rho_db": None, "res_frames_echo": int(echo.sum()) * 4}
    if echo.sum() < 20:
        return e.copy(), info
    ratio = fe_s / (fy_s + 1e-20)
    q = float(np.percentile(ratio[echo], 25))
    eo = echo & (ratio <= 3.0 * q)
    nf = np.percentile(samp_e, 10, axis=0)
    rho = np.maximum(samp_e[eo].mean(0) - 1.5 * nf, 0.0) / (samp_y[eo].mean(0) + 1e-20)
    rho = _box_freq(rho[None, :], 9)[0]
    rho = np.clip(rho, 1e-4, 0.5)
    info["res_rho_db"] = round(float(10 * np.log10(np.median(rho[k0:k1]))), 1)
    gmin = 10.0 ** (p.res_floor_db / 20.0)
    noise_frame = 1.5 * float(nf[k0:k1].sum())

    # sweep 2: gains and overlap-add
    out = np.zeros(total, np.float32)
    for f0 in range(0, nfr, chunk):
        f1 = min(nfr, f0 + chunk)
        ee, pe, py = spectra(f0, f1)
        resid = rho[None, :] * py                                     # expected residual echo power per bin
        # frame level: is the mic louder than "residual echo + noise floor" can explain?  (many bins -> a crisp decision)
        r = pe[:, k0:k1].sum(1) / (resid[:, k0:k1].sum(1) + noise_frame)
        z = np.clip((np.log(np.maximum(r, 1e-6)) - np.log(p.res_ne_lo)) / (np.log(p.res_ne_hi) - np.log(p.res_ne_lo)), 0.0, 1.0)
        z = np.clip(_box_time(z, 3), 0.0, 1.0)[:, None]
        share = resid / np.maximum(pe, 1e-20)
        g_deep = np.clip(1.0 - p.res_gamma * share, gmin, 1.0)        # echo only: strong suppression
        g_near = np.clip(1.0 - share, p.res_near_floor, 1.0)          # near-end speech present: only bins the echo dominates
        g = (1.0 - z) * g_deep + z * g_near
        g = np.clip(_box_freq(g, 3), gmin, 1.0)
        if p.debug is not None:
            p.debug.setdefault('r', []).append(r); p.debug.setdefault('z', []).append(z[:, 0]); p.debug.setdefault('gm', []).append(g[:, k0:k1].mean(1)); p.debug.setdefault('pe', []).append(pe[:, k0:k1].sum(1)); p.debug.setdefault('res', []).append(resid[:, k0:k1].sum(1))
        fr = np.fft.irfft(ee * g.astype(np.float32), _RN, axis=-1).astype(np.float32) * win
        if (f1 - f0) % 2:
            fr = np.concatenate([fr, np.zeros((1, _RN), np.float32)])
        base, half = f0 * _RH, len(fr) // 2 * _RN             # chunks start on an even frame: even frames are contiguous
        out[base: base + half] += fr[0::2].reshape(-1)
        out[base + _RH: base + _RH + half] += fr[1::2].reshape(-1)
    return out[_RH: _RH + t_len], info


def _block_db_sums(x: np.ndarray, bs: int) -> np.ndarray:
    """Mean power of consecutive ``bs``-sample blocks (the last, partial block is zero padded)."""
    nbk = -(-len(x) // bs)
    out = np.empty(nbk, np.float64)
    step = max(1, (1 << 22) // bs)
    for i in range(0, nbk, step):
        j = min(nbk, i + step)
        seg = x[i * bs: j * bs]
        if len(seg) < (j - i) * bs:
            seg = np.concatenate([seg, np.zeros((j - i) * bs - len(seg), np.float32)])
        f = seg.reshape(j - i, bs)
        out[i:j] = np.einsum("ij,ij->i", f, f, dtype=np.float64) / bs
    return out


def _blend(d: np.ndarray, proc: np.ndarray, y: np.ndarray, guard: bool):
    """Final output = the mic itself wherever no echo can be present or the processing made the block louder.

    * no echo estimate within +-2 blocks (-90 dBFS): exact copy of the mic (single-talk is bit-identical);
    * guard: in every 0.5 s window where the processed signal has more energy than the mic (an echo estimate that is
      wrong cannot reduce the energy), the mic is used instead;
    * 40 ms ramps (a 5-block moving average of 8 ms blocks) between the two."""
    bs = 128
    py = _block_db_sums(y, bs)
    near = np.convolve((py > 1e-9).astype(np.float32), np.ones(5, np.float32), mode="same") > 0
    w = near.astype(np.float32)
    reverted = 0
    if guard:
        pd, pp = _block_db_sums(d, bs), _block_db_sums(proc, bs)
        gb = 62
        starts = np.arange(0, len(w), gb)
        sd, sp, sw_ = (np.add.reduceat(a, starts) for a in (pd, pp, w))
        bad = (sw_ > 0) & (sp > 1.05 * sd + 1e-12 * gb)
        reverted = int(bad.sum())
        w[np.repeat(bad, gb)[: len(w)]] = 0.0
    w = np.convolve(w, np.ones(5, np.float32) / 5, mode="same")
    out = np.empty_like(d)
    step = 1 << 20
    for i in range(0, len(d), step):
        j = min(len(d), i + step)
        wi = np.repeat(w[i // bs: -(-j // bs)], bs)[: j - i]
        out[i:j] = d[i:j] + wi * (proc[i:j] - d[i:j])
    return out, reverted


# --------------------------------------------------------------------------------------
# analysis (activity, delay, coherence) and the public API
# --------------------------------------------------------------------------------------
@dataclass
class _Analysis:
    active_s: float = 0.0
    estimates: list = None
    curve: DelayCurve | None = None
    drift_ppm: float = 0.0
    coherence: float = 0.0
    coherence_frames: int = 0
    reason: str = ""
    ref_active: np.ndarray | None = None
    ref_thr_db: float = -60.0
    tentative: DelayCurve | None = None      # best-effort constant delay when no estimate was reliable (coherence report only)


def _measure_coherence(mic, ref, curve: DelayCurve, act: np.ndarray, thr_db: float, sr: int, p: AecParams):
    """(mean coherence, number of frames) over up to ten 12 s tiles that contain reference activity."""
    tile = 12 * sr
    n_tiles = max(1, len(mic) // tile)
    per_tile = act[: n_tiles * (tile // ACT)].reshape(n_tiles, tile // ACT).sum(1) * ACT / sr if len(mic) >= tile else None
    if per_tile is None:
        spans = [(0, len(mic))]
    else:
        cand = np.flatnonzero(per_tile >= 4.0)
        if len(cand) > 10:
            cand = cand[np.unique(np.linspace(0, len(cand) - 1, 10).round().astype(int))]
        spans = [(int(i) * tile, (int(i) + 1) * tile) for i in cand] or [(0, min(len(mic), tile))]
    scores = []
    for a, b in spans:
        x = _align_ref(ref, curve, a, b, p.margin)
        scores.append(_tile_coherence(mic[a:b], x, sr, thr_db))
    r = np.concatenate(scores) if scores else np.zeros(0, np.float32)
    return (float(np.clip(r, 0.0, 1.0).mean()) if len(r) >= 50 else 0.0), int(len(r))


def _analyze(mic: np.ndarray, ref: np.ndarray, sr: int, p: AecParams, progress: Progress = _noop) -> _Analysis:
    an = _Analysis(estimates=[])
    db = _frame_db(ref)
    act, thr = _active_frames(db)
    an.ref_active = act
    an.ref_thr_db = thr
    an.active_s = float(act.sum()) * ACT / sr
    if an.active_s < p.min_ref_active_s:
        an.reason = f"reference has only {an.active_s:.1f} s of speech-level audio"
        return an
    progress("echo cancellation: estimating delay")
    an.estimates = _estimate_delays(mic, ref, sr, p, act, progress)
    curve, _ = _fit_curve(an.estimates, len(mic), sr, p.delay_min_z)
    if curve is None:
        an.reason = "no reliable delay peak between mic and reference"
        if an.estimates:                      # still report how coherent the mic is at the most plausible delay
            lag = float(np.median([e.lag for e in an.estimates]))
            an.tentative = DelayCurve(np.array([0.0, float(len(mic))]), np.array([lag, lag]), (lag,), 0.0)
            progress("echo cancellation: measuring coherence")
            an.coherence, an.coherence_frames = _measure_coherence(mic, ref, an.tentative, act, thr, sr, p)
        return an
    curve, ppm = _refine_curve(mic, ref, sr, curve, act)
    an.curve = curve
    an.drift_ppm = float(ppm) if ppm is not None else 0.0
    progress("echo cancellation: measuring coherence")
    an.coherence, an.coherence_frames = _measure_coherence(mic, ref, curve, act, thr, sr, p)
    return an


def decide_applicable(mic: np.ndarray, ref: np.ndarray, sr: int = SR, params: AecParams | None = None) -> tuple[bool, float]:
    """Is there real speaker-to-microphone leakage in ``mic``?  Returns (applicable, coherence).

    ``coherence`` = mean, over reference-active frames, of the share of the mic energy (150-4500 Hz) that a 160 ms
    multi-tap linear model of the delay-aligned reference explains (cross-validated, so independent signals score ~0).
    Headphones or a hardware-AEC conference mic give ~0; a laptop speaker echo gives >= 0.3."""
    p = params or AecParams()
    mic, ref = _prepare_inputs(mic, ref)
    an = _analyze(mic, ref, sr, p)
    return bool(an.curve is not None and an.coherence >= p.coherence_threshold), an.coherence


def _finite(a: np.ndarray) -> np.ndarray:
    """NaN / inf samples would poison the adaptive filter for the rest of the file; they become silence (a copy; the caller's
    array is never modified)."""
    return a if np.isfinite(a).all() else np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)


def _prepare_inputs(mic, ref):
    mic = np.asarray(mic, dtype=np.float32)
    ref = np.asarray(ref, dtype=np.float32)
    if mic.ndim != 1 or ref.ndim != 1:
        raise ValueError("mic and ref must be 1-D mono arrays")
    mic, ref = _finite(mic), _finite(ref)
    if len(ref) != len(mic):
        fixed = np.zeros(len(mic), np.float32)
        m = min(len(ref), len(mic))
        fixed[:m] = ref[:m]
        ref = fixed
    return mic, ref


def _adapt_mask(x: np.ndarray, thr_db: float, p: AecParams, n_streams: int) -> np.ndarray:
    """[n_streams, blocks] float mask, 1 where the filter may adapt.

    Adaptation is allowed while some reference block inside the filter's span (the last ``partitions`` blocks) is within
    ``adapt_margin_db`` of the activity threshold. A reference that is only hiss / digital near-silence carries nothing
    the mic echoes, and adapting on it would pull the echo path towards zero (the Wiener solution for uncorrelated
    signals), so the first seconds of every speech burst would be badly cancelled."""
    n = p.block
    nb = -(-len(x) // (n_streams * n))
    blocks = np.full(n_streams * nb, 1e-12)
    pw = _block_db_sums(x, n)
    blocks[: len(pw)] = pw
    active = (10.0 * np.log10(blocks + 1e-12) > thr_db - p.adapt_margin_db).astype(np.float32)
    window = np.convolve(active, np.ones(p.partitions + 1, np.float32))[: len(active)] > 0
    return window.astype(np.float32).reshape(n_streams, nb)


def _process(mic: np.ndarray, ref: np.ndarray, an: _Analysis, p: AecParams, sr: int, progress: Progress):
    t_len = len(mic)
    x = _align_ref(ref, an.curve, 0, t_len, p.margin)
    n_streams = p.n_streams or int(np.clip(round(t_len / (60.0 * sr)), 1, 16))
    adapt = _adapt_mask(x, an.ref_thr_db, p, n_streams)
    state, e, y = None, None, None
    for k in range(p.passes):
        e, y, state = _run_filter(mic, x, p, n_streams, state, freeze=adapt, label=f"pass {k + 1}/{p.passes}", progress=progress)
    del x
    info = {"streams": n_streams}
    proc = e
    if p.res_enabled:
        progress("echo cancellation: residual suppression")
        proc, res_info = _suppress_residual(e, y, p, sr, progress)
        info.update(res_info)
    out, reverted = _blend(mic, proc, y, p.guard)
    info["guard_reverted"] = reverted
    if not np.isfinite(out).all():
        bad = ~np.isfinite(out)
        out[bad] = mic[bad]
        info["nonfinite_samples"] = int(bad.sum())
    # in-situ estimates on the real data (no ground truth needed)
    pd, pe, py, po = (_block_db_sums(a, ACT) for a in (mic, e, y, out))
    live = pd[pd > 1e-12]
    pn = max(float(np.percentile(live, 5)) if live.size else 1e-10, 1e-10)
    eo = (py > 0.5 * pd) & (pd > 10 * pn)
    info["echo_only_s"] = round(float(eo.sum()) * ACT / sr, 1)
    info["erle_db"] = round(float(10 * np.log10(pd[eo].sum() / (po[eo].sum() + 1e-20))), 1) if eo.sum() >= 20 else None
    info["erle_linear_db"] = round(float(10 * np.log10(pd[eo].sum() / (pe[eo].sum() + 1e-20))), 1) if eo.sum() >= 20 else None
    ne = (py > 3 * pn) & (py < 0.25 * pd) & (pd > 10 * pn)
    info["double_talk_s"] = round(float(ne.sum()) * ACT / sr, 1)
    info["preserved_ratio"] = (round(float(po[ne].sum() / np.maximum(pd[ne] - py[ne], 0.1 * pd[ne]).sum()), 3)
                               if ne.sum() >= 20 else None)
    return out.astype(np.float32, copy=False), info


def cancel_echo(mic: np.ndarray, ref: np.ndarray, sample_rate: int = SR, mode: str = "auto", progress: Progress | None = None,
                params: AecParams | None = None) -> tuple[np.ndarray, dict]:
    """Remove the speaker echo of ``ref`` (system audio, the clean reference) from ``mic`` (microphone track).

    Both are float mono arrays at ``sample_rate`` (16 kHz), index 0 = session start, same length. ``mode``: "auto" applies
    the canceller only when ``decide_applicable`` finds real speaker leakage (otherwise the mic comes back unchanged,
    bit for bit); "always" skips that decision. Returns (cleaned float32 array of the same length, stats):
    ``applied``, ``coherence``, ``delay_ms`` (median), ``delay_track`` [(t_s, ms)], ``drift_ppm``, ``erle_db`` (on echo-only
    blocks, whole chain), ``preserved_ratio`` (output / expected near-end energy on double-talk blocks, None if there are
    none), ``reason`` (why it was not applied), runtime numbers. Never raises for bad audio: on any error the mic track
    is returned untouched with ``applied`` False and ``error`` set."""
    t_begin = time.time()
    progress = progress or _noop
    p = params or AecParams()
    sr = int(sample_rate)
    stats: dict = {"applied": False, "coherence": 0.0, "delay_ms": None, "delay_track": [], "erle_db": None,
                   "preserved_ratio": None, "mode": mode, "reason": ""}
    try:
        if mode not in ("auto", "always"):
            raise ValueError(f"mode must be 'auto' or 'always', not {mode!r}")
        if sr != SR:
            raise ValueError(f"only {SR} Hz is supported (got {sr})")
        mic, ref = _prepare_inputs(mic, ref)
        stats["duration_s"] = round(len(mic) / sr, 1)
        an = _analyze(mic, ref, sr, p, progress)
        stats["coherence"] = round(an.coherence, 4)
        stats["ref_active_s"] = round(an.active_s, 1)
        if an.curve is not None:
            stats["delay_ms"] = round(an.curve.median() * 1000.0 / sr, 2)
            stats["drift_ppm"] = round(an.drift_ppm, 2)
            stats["delay_track"] = [(round(e.t, 1), round(e.lag * 1000.0 / sr, 2)) for e in an.estimates if e.z >= p.delay_min_z]
        if an.ref_active is None or an.active_s < p.min_ref_active_s:
            stats["reason"] = an.reason
            return mic, stats
        if an.curve is None:
            if mode == "auto":
                stats["reason"] = an.reason
                return mic, stats
            an.curve = an.tentative or DelayCurve(np.array([0.0, float(len(mic))]), np.zeros(2))
            stats["delay_ms"] = round(an.curve.median() * 1000.0 / sr, 2)
            log.warning("aec: no reliable delay peak, running with %.1f ms in mode 'always'", stats["delay_ms"])
        elif mode == "auto" and an.coherence < p.coherence_threshold:
            stats["reason"] = (f"coherence {an.coherence:.3f} below {p.coherence_threshold:.2f}: no speaker leakage "
                               f"(headphones or hardware echo cancellation)")
            return mic, stats
        out, info = _process(mic, ref, an, p, sr, progress)
        stats.update(info)
        stats["applied"] = True
        stats["runtime_s"] = round(time.time() - t_begin, 1)
        stats["realtime_factor"] = round(len(mic) / sr / max(stats["runtime_s"], 1e-3), 1)
        log.info("aec: applied, coherence %.2f, delay %.1f ms (drift %.1f ppm), ERLE %s dB (linear %s), preserved %s, %.1f s (%.0fx real time)",
                 stats["coherence"], stats["delay_ms"], an.drift_ppm, stats.get("erle_db"), stats.get("erle_linear_db"),
                 stats.get("preserved_ratio"), stats["runtime_s"], stats["realtime_factor"])
        return out, stats
    except Exception as exc:                       # an unattended pipeline must keep the original track on any failure
        log.exception("aec failed; the mic track is left unchanged")
        stats["applied"] = False
        stats["error"] = f"{type(exc).__name__}: {exc}"
        return np.asarray(mic, dtype=np.float32), stats
