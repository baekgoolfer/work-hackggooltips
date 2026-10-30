#!/usr/bin/env python3
"""aec_eval.py - evaluation of the offline echo canceller (pipeline/mcap/aec.py): synthetic suite and real-session check.

Synthetic suite (default; reproducible, numpy only, writes nothing):
    python scripts/aec_eval.py [--quick] [--seed N] [--json out.json] [--no-vad] [--runtime-hour]
  remote = TTS speech (benchmarks/tts/meeting_like_184s.wav; pseudo-speech when the clips are absent), echo path =
  direct path (20-120 ms) + exponentially decaying noise RIR (RT60 0.2-0.5 s) x gain + speaker band limit, optional tanh
  nonlinearity before the room (loudspeaker), background noise (25-40 dB below the echo), clock drift up to +-100 ppm,
  optional delay jump / volume change, and the things a real microphone chain does to the sum: slow AGC gain changes (a
  sinusoidal wobble or a level-following AGC, applied to echo, the user and noise alike), a soft-clipping preamp, hard clipping at
  the converter; "Me" = other TTS clips placed at known times: alone (remote silent) and as double talk.
  Reports per case: ERLE on echo-only frames, residual vs the noise floor, the user preservation on single talk and double
  talk (energy gain, waveform correlation, SDR, each also for the untouched mic), false speech regions of the VAD before
  and after (energy VAD, and Silero when MCAP_SILERO_MODEL points at the model), runtime. Then the false-apply table: auto
  mode on inputs with NO echo (independent noise, a different speech clip = headphones, residual below the noise floor,
  remote echo of the user in the reference, zeros, silent reference, ...) must never apply and must return the mic bit for bit.

Real recording:
    python scripts/aec_eval.py --session <session_dir> [--vad auto|energy|silero] [--write-cleaned]
  Reads mic.wav / remote.wav (or mic.m4a / remote.m4a decoded into a temp dir) READ-ONLY, aligns them like the pipeline
  (start_offset_sec, 16 kHz), runs the canceller in mode 'auto' and prints coherence / delay / drift / ERLE estimates, the
  VAD speech regions of the mic track before and after, and the regions that disappeared (with levels, so you can
  listen to them). Nothing is written into the session dir unless --write-cleaned is given: then mic.aec.wav (16 kHz).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import resource
import sys
import tempfile
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pipeline"))

from mcap import aec, audioprep, vad as vadmod, wavio  # noqa: E402

SR = 16000
TTS_DIR = REPO / "benchmarks" / "tts"
FRAME = 320                                   # 20 ms scoring frames


# --------------------------------------------------------------------------------------
# DSP helpers
# --------------------------------------------------------------------------------------
def fft_convolve(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    """Causal linear convolution, same length as x."""
    n = len(x) + len(h) - 1
    nfft = 1 << int(np.ceil(np.log2(n)))
    return np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(h, nfft), nfft)[: len(x)].astype(np.float32)


def pink_noise(rng: np.random.Generator, n: int) -> np.ndarray:
    f = np.fft.rfft(rng.standard_normal(n))
    k = np.arange(len(f), dtype=np.float64)
    k[0] = 1.0
    x = np.fft.irfft(f / np.sqrt(k / k[1]), n)
    return (x / x.std()).astype(np.float32)


def resample_cubic(x: np.ndarray, ratio: float) -> np.ndarray:
    """y[n] = x(n * ratio) with 4-point cubic interpolation (clock drift of the mic relative to the tap)."""
    n = min(len(x), int((len(x) - 4) / ratio))
    pos = np.arange(n) * ratio
    i = np.floor(pos).astype(np.int64)
    f = (pos - i).astype(np.float32)
    xm1, x0, x1, x2 = x[np.maximum(i - 1, 0)], x[i], x[i + 1], x[i + 2]
    y = ((((-0.5 * xm1 + 1.5 * x0 - 1.5 * x1 + 0.5 * x2) * f + (xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2)) * f
          + (-0.5 * xm1 + 0.5 * x1)) * f + x0)
    out = np.zeros(len(x), np.float32)
    out[:n] = y
    return out


def agc_gain(x: np.ndarray, target_db: float, max_gain_db: float, attack_s: float = 0.3, release_s: float = 4.0) -> np.ndarray:
    """Per-sample gain of a level-following AGC: gain_dB = clip(target - smoothed level, +-max). The level follower reacts
    quickly to a rise (``attack_s``) and slowly to a fall (``release_s``), like a speech AGC: the gain drops during loud
    passages and creeps back up in the pauses."""
    n = len(x) // FRAME
    p = db(frame_power(x[: n * FRAME]))
    env = np.empty(n)
    level = p[0]
    a_att, a_rel = np.exp(-FRAME / SR / attack_s), np.exp(-FRAME / SR / release_s)
    for i in range(n):
        a = a_att if p[i] > level else a_rel
        level = a * level + (1.0 - a) * p[i]
        env[i] = level
    g_db = np.clip(target_db - env, -max_gain_db, max_gain_db)
    centres = (np.arange(n) + 0.5) * FRAME
    return (10.0 ** (np.interp(np.arange(len(x)), centres, g_db) / 20.0)).astype(np.float32)


def frame_power(x: np.ndarray, frame: int = FRAME) -> np.ndarray:
    n = len(x) // frame
    f = np.asarray(x[: n * frame], np.float32).reshape(n, frame)
    return (f * f).mean(axis=1)


def db(p) -> np.ndarray | float:
    return 10.0 * np.log10(np.asarray(p, dtype=np.float64) + 1e-20)


def active_frames(x: np.ndarray, floor_db: float = -60.0, drop_db: float = 32.0) -> np.ndarray:
    d = db(frame_power(x))
    return d > max(floor_db, float(np.percentile(d, 98)) - drop_db)


def dilate(mask: np.ndarray, frames: int) -> np.ndarray:
    return np.convolve(mask.astype(np.float32), np.ones(2 * frames + 1, np.float32), mode="same") > 0


def active_rms(x: np.ndarray) -> float:
    m = np.repeat(active_frames(x), FRAME)
    seg = x[: len(m)][m]
    return float(np.sqrt(np.mean(seg ** 2))) if seg.size else 1e-6


def set_active_rms(x: np.ndarray, target: float) -> np.ndarray:
    return (x * (target / active_rms(x))).astype(np.float32)


# --------------------------------------------------------------------------------------
# speech material: TTS clips, or pseudo-speech when benchmarks/tts is absent
# --------------------------------------------------------------------------------------
def pseudo_speech(duration_s: float, rng: np.random.Generator, f0: float = 120.0, pauses: bool = True) -> np.ndarray:
    """Speech-like signal: voiced syllables (glissando harmonics under a random 3-formant envelope), fricative bursts and
    pauses. Not intelligible, but non-stationary, band-limited and spectrally structured like speech."""
    n_total = int(duration_s * SR)
    out = np.zeros(n_total, np.float32)
    t = int(0.2 * SR)
    while t < n_total:
        n = int(rng.uniform(0.08, 0.28) * SR)
        n = min(n, n_total - t)
        if n < 400:
            break
        tt = np.arange(n) / SR
        if rng.random() < 0.75:
            f = f0 * (1.0 + 0.2 * np.sin(2 * np.pi * rng.uniform(1, 3) * tt + rng.uniform(0, 6))) * rng.uniform(0.8, 1.4)
            ph = 2 * np.pi * np.cumsum(f) / SR
            sig = sum(np.sin(h * ph) / h for h in range(1, int(4000 / f0)))
            spec = np.fft.rfft(sig)
            fr = np.fft.rfftfreq(n, 1 / SR)
            env = np.zeros_like(fr)
            for fc, bw, amp in ((rng.uniform(300, 800), 120, 1.0), (rng.uniform(900, 2200), 250, 0.6), (rng.uniform(2200, 3200), 300, 0.3)):
                env += amp * np.exp(-0.5 * ((fr - fc) / bw) ** 2)
            sig = np.fft.irfft(spec * (env + 0.02), n)
        else:
            sig = rng.standard_normal(n)
            spec = np.fft.rfft(sig)
            fr = np.fft.rfftfreq(n, 1 / SR)
            sig = np.fft.irfft(spec * (fr > 2500) * (fr < 7000), n)
        sig = sig / (np.abs(sig).max() + 1e-9) * rng.uniform(0.3, 0.8)
        out[t: t + n] += (sig * np.hanning(n) ** 0.7).astype(np.float32)
        gap = rng.choice([0.01, 0.04, 0.1, 0.25, 0.6, 1.8], p=[0.25, 0.25, 0.2, 0.15, 0.1, 0.05]) if pauses else 0.02
        t += n + int(gap * SR)
    return out / (np.abs(out).max() + 1e-9) * 0.8


def have_tts() -> bool:
    return (TTS_DIR / "meeting_like_184s.wav").exists()


_clip_cache: dict[str, np.ndarray] = {}


def load_clip(name: str) -> np.ndarray:
    if name not in _clip_cache:
        x, sr = wavio.read_wav_lenient(TTS_DIR / f"{name}.wav")
        assert sr == SR, f"{name}: {sr} Hz"
        _clip_cache[name] = x
    return _clip_cache[name]


def speech_clip(name: str, rng: np.random.Generator, pseudo_s: float) -> np.ndarray:
    """A TTS clip by name when the clips exist, else a pseudo-speech clip of ``pseudo_s`` seconds."""
    if have_tts():
        return load_clip(name)
    return pseudo_speech(pseudo_s, rng, f0=float(rng.uniform(95, 220)))


# --------------------------------------------------------------------------------------
# echo path simulation
# --------------------------------------------------------------------------------------
def make_rir(rng: np.random.Generator, delay_ms: float, rt60: float, drr_db: float = 3.0, band=(250.0, 7000.0),
             length_s: float = 0.8) -> np.ndarray:
    """Direct path at ``delay_ms`` (+ 4 ms of band-limiting filter delay) followed by an exponentially decaying noise tail
    (RT60), direct-to-reverberant ratio ``drr_db``, speaker band limit. Unit energy is NOT applied here (see simulate)."""
    n = int(length_s * SR)
    d0 = int(delay_ms * SR / 1000)
    t = np.arange(n) / SR
    tail = rng.standard_normal(n) * 10.0 ** (-3.0 * np.maximum(t - delay_ms / 1000.0, 0.0) / rt60)
    tail[: d0 + 32] = 0.0
    tail *= np.sqrt(10.0 ** (-drr_db / 10.0) / max((tail ** 2).sum(), 1e-20))
    h = tail
    h[d0] += 1.0
    nt = 129
    k = np.arange(nt) - nt // 2

    def lp(fc: float) -> np.ndarray:
        return 2 * fc / SR * np.sinc(2 * fc / SR * k) * np.hanning(nt)

    return np.convolve(h, lp(band[1]) - lp(band[0])).astype(np.float32)


def crossfade_at(a: np.ndarray, b: np.ndarray, t0: int, width: int = 800) -> np.ndarray:
    w = np.clip((np.arange(len(a)) - t0) / width + 0.5, 0.0, 1.0).astype(np.float32)
    return a * (1 - w) + b * w


@dataclass
class Scenario:
    name: str = "baseline"
    seed: int = 0
    delay_ms: float = 60.0
    rt60: float = 0.35
    gain: float = 0.5                    # RMS amplitude gain of the echo path
    drive: float = 0.0                   # tanh loudspeaker saturation: 0 = linear
    snr_db: float = 35.0                 # noise below the echo's speech-level RMS
    ppm: float = 0.0                     # mic clock vs tap clock
    voice_vs_echo_db: float = 6.0          # the user speech level at the mic relative to the echo
    dt_clips: tuple = (("ko_flo_terms", 47.0), ("en_samantha_terms", 100.0), ("ko_yuna_terms", 140.0))
    single_clips: tuple = (("ko_eddy_terms", 2.0), ("en_samantha_names", 214.0))
    pre_s: float = 30.0                  # remote silence in front (the user talks alone)
    post_s: float = 18.0
    drr_db: float = 3.0
    delay_jump: tuple | None = None      # (t_s, new_delay_ms)
    gain_change: tuple | None = None     # (t_s, new_gain)
    remote_noise_db: float | None = None  # continuous noise floor in the remote track (dBFS)
    remote_len_s: float | None = None    # cut the remote clip (tests)
    mic_drive: float = 0.0               # tanh soft clipping of the mic preamp (drive relative to the mic peak); 0 = linear
    gain_wobble: tuple | None = None     # (amplitude_dB, period_s): slow sinusoidal mic gain (manual / system AGC drift)
    agc: tuple | None = None             # (target_dBFS, max_gain_dB): level-following mic AGC, 0.3 s attack / 4 s release
    clip: float | None = None            # hard clipping at this fraction of the mic's peak (converter / digital clipping)


@dataclass
class Sim:
    scn: Scenario
    mic: np.ndarray
    ref: np.ndarray
    echo: np.ndarray          # echo component at the mic (after drift)
    voice: np.ndarray           # clean user signal at the mic
    noise: np.ndarray
    masks: dict = field(default_factory=dict)   # frame-level truth: echo_only, single, dt, voice


def simulate(scn: Scenario) -> Sim:
    rng = np.random.default_rng(scn.seed)
    remote = speech_clip("meeting_like_184s", rng, 184.0)
    if scn.remote_len_s:
        remote = remote[: int(scn.remote_len_s * SR)]
    ref = np.concatenate([np.zeros(int(scn.pre_s * SR), np.float32), remote, np.zeros(int(scn.post_s * SR), np.float32)])
    t_len = len(ref)
    h = make_rir(rng, scn.delay_ms, scn.rt60, scn.drr_db)
    h *= scn.gain / np.sqrt((h ** 2).sum())
    xin = ref if scn.drive == 0 else (np.tanh(scn.drive * ref) / scn.drive).astype(np.float32)
    echo = fft_convolve(xin, h)
    if scn.delay_jump or scn.gain_change:
        h2 = h
        if scn.delay_jump:
            h2 = make_rir(np.random.default_rng(scn.seed + 1), scn.delay_jump[1], scn.rt60, scn.drr_db)
            h2 *= scn.gain / np.sqrt((h2 ** 2).sum())
        if scn.gain_change:
            h2 = h2 * (scn.gain_change[1] / scn.gain)
        t_change = int((scn.delay_jump or scn.gain_change)[0] * SR)
        echo = crossfade_at(echo, fft_convolve(xin, h2), t_change)
    if scn.ppm:
        echo = resample_cubic(echo, 1.0 + scn.ppm * 1e-6)
    if scn.remote_noise_db is not None:
        ref = ref + (pink_noise(rng, t_len) * 10.0 ** (scn.remote_noise_db / 20.0)).astype(np.float32)
    echo_rms = active_rms(echo)
    voice = np.zeros(t_len, np.float32)
    n_voice = 0
    for name, t0 in tuple(scn.single_clips) + tuple(scn.dt_clips):
        a = int(t0 * SR)
        if a >= t_len:
            continue
        clip = speech_clip(name, rng, 15.0)
        clip = set_active_rms(clip, echo_rms * 10.0 ** (scn.voice_vs_echo_db / 20.0))
        b = min(t_len, a + len(clip))
        voice[a:b] += clip[: b - a]
        n_voice += 1
    noise = (pink_noise(rng, t_len) * echo_rms * 10.0 ** (-scn.snr_db / 20.0)).astype(np.float32)
    mic = (echo + voice + noise).astype(np.float32)
    if scn.mic_drive:                                    # preamp soft clipping, relative to the mic peak (not separable per component)
        peak = float(np.abs(mic).max())
        mic = (peak * np.tanh(scn.mic_drive * mic / peak) / scn.mic_drive).astype(np.float32)
    if scn.gain_wobble or scn.agc:                       # a gain applied to the whole mic signal scales every component alike
        g = np.ones(t_len, np.float32)
        if scn.gain_wobble:
            g *= (10.0 ** (scn.gain_wobble[0] * np.sin(2 * np.pi * np.arange(t_len) / SR / scn.gain_wobble[1]) / 20.0)).astype(np.float32)
        if scn.agc:
            g *= agc_gain(mic * g, scn.agc[0], scn.agc[1])
        mic = (mic * g).astype(np.float32)
        echo, voice, noise = echo * g, voice * g, noise * g
    if scn.clip:                                         # hard clipping at the converter
        c = scn.clip * float(np.abs(mic).max())
        mic = np.clip(mic, -c, c).astype(np.float32)
    # frame-level truth
    pj, pe = db(frame_power(voice)), db(frame_power(echo))
    voice_on = dilate(pj > -75.0, 8)                         # the user present (incl. 160 ms hangover)
    echo_on = pe > -50.0
    echo_any = dilate(pe > -70.0, 10)
    masks = {
        "voice": pj > -75.0,
        "echo_only": echo_on & ~voice_on,
        "single": (pj > -60.0) & ~echo_any,
        "dt": (pj > -60.0) & echo_on,
    }
    return Sim(scn, mic, ref.astype(np.float32), echo, voice, noise, masks)


# --------------------------------------------------------------------------------------
# scoring
# --------------------------------------------------------------------------------------
def _sel(x: np.ndarray, mask: np.ndarray) -> np.ndarray:
    m = np.repeat(mask, FRAME)
    return x[: len(m)][m]


def _corr(a: np.ndarray, b: np.ndarray) -> float:
    if len(a) < 10:
        return float("nan")
    return float(np.corrcoef(a.astype(np.float64), b.astype(np.float64))[0, 1])


def score_audio(sim: Sim, out: np.ndarray) -> dict:
    """Ground-truth metrics of ``out`` (the processed mic) against the simulation."""
    m = sim.masks
    res: dict = {}
    eo_mic, eo_out, eo_noise = _sel(sim.mic, m["echo_only"]), _sel(out, m["echo_only"]), _sel(sim.noise, m["echo_only"])
    if len(eo_mic):
        res["erle_db"] = float(10 * np.log10(np.sum(eo_mic ** 2, dtype=np.float64) / (np.sum(eo_out ** 2, dtype=np.float64) + 1e-20)))
        res["resid_vs_noise_db"] = float(10 * np.log10(np.sum(eo_out ** 2, dtype=np.float64) / (np.sum(eo_noise ** 2, dtype=np.float64) + 1e-20)))
    st_mic, st_out, st_j = _sel(sim.mic, m["single"]), _sel(out, m["single"]), _sel(sim.voice, m["single"])
    if len(st_mic):
        res["single_energy_ratio"] = float(np.sum(st_out ** 2, dtype=np.float64) / (np.sum(st_mic ** 2, dtype=np.float64) + 1e-20))
        res["single_corr"] = _corr(st_out, st_j)
        res["single_corr_mic"] = _corr(st_mic, st_j)
    dt_mic, dt_out, dt_j = _sel(sim.mic, m["dt"]), _sel(out, m["dt"]), _sel(sim.voice, m["dt"])
    if len(dt_mic):
        jj = float(np.dot(dt_j.astype(np.float64), dt_j))
        res["dt_voice_gain"] = float(np.dot(dt_out.astype(np.float64), dt_j) / jj)          # 1.0 = the user kept at full level
        res["dt_corr"] = _corr(dt_out, dt_j)
        res["dt_corr_mic"] = _corr(dt_mic, dt_j)
        res["dt_sdr_db"] = float(10 * np.log10(jj / (np.sum((dt_out - dt_j).astype(np.float64) ** 2) + 1e-20)))
        res["dt_sdr_mic_db"] = float(10 * np.log10(jj / (np.sum((dt_mic - dt_j).astype(np.float64) ** 2) + 1e-20)))
    return res


def false_regions(x: np.ndarray, voice_truth: np.ndarray, mode: str, support_dir: Path | None) -> tuple[int, float, int]:
    """(VAD regions without any true user speech nearby, their total seconds, all regions)."""
    r = vadmod.detect_speech(x, mode, support_dir)
    near = dilate(voice_truth, 15)                              # +-0.3 s
    bad = [(s, e) for s, e in r.regions if not near[int(s * SR) // FRAME: int(np.ceil(e * SR / FRAME)) + 1].any()]
    return len(bad), float(sum(e - s for s, e in bad)), len(r.regions)


def silero_available(support_dir: Path | None) -> bool:
    try:
        import onnxruntime  # noqa: F401
    except ImportError:
        return False
    return vadmod.find_silero_model(support_dir) is not None


def run_case(scn: Scenario, vad_modes: list[str], support_dir: Path | None, params: aec.AecParams | None = None) -> dict:
    sim = simulate(scn)
    t0, c0 = time.time(), time.process_time()
    out, stats = aec.cancel_echo(sim.mic, sim.ref, SR, "auto", params=params)
    elapsed, cpu = time.time() - t0, time.process_time() - c0
    res = {"name": scn.name, "applied": stats["applied"], "coherence": stats["coherence"], "delay_ms": stats["delay_ms"],
           "true_delay_ms": scn.delay_ms + 4.0, "drift_ppm": stats.get("drift_ppm"), "est_erle_db": stats.get("erle_db"),
           "est_preserved": stats.get("preserved_ratio"), "seconds": round(elapsed, 1), "cpu_seconds": round(cpu, 1),
           "xrt": round(len(sim.mic) / SR / max(elapsed, 1e-3), 0), "xrt_cpu": round(len(sim.mic) / SR / max(cpu, 1e-3), 0)}
    res.update(score_audio(sim, out))
    base = score_audio(sim, sim.mic)
    res["erle_mic_db"] = base.get("erle_db")
    for mode in vad_modes:
        b = false_regions(sim.mic, sim.masks["voice"], mode, support_dir)
        a = false_regions(out, sim.masks["voice"], mode, support_dir)
        res[f"vad_{mode}_false_before"], res[f"vad_{mode}_false_s_before"], res[f"vad_{mode}_regions_before"] = b[0], round(b[1], 1), b[2]
        res[f"vad_{mode}_false_after"], res[f"vad_{mode}_false_s_after"], res[f"vad_{mode}_regions_after"] = a[0], round(a[1], 1), a[2]
    return res


# --------------------------------------------------------------------------------------
# scenario lists
# --------------------------------------------------------------------------------------
def echo_scenarios(quick: bool, seed: int) -> list[Scenario]:
    s = seed
    cases = [
        Scenario("baseline", s + 1),
        Scenario("delay 20 ms", s + 2, delay_ms=20),
        Scenario("delay 120 ms", s + 3, delay_ms=120),
        Scenario("RT60 0.5, gain 0.8", s + 4, rt60=0.5, gain=0.8),
        Scenario("RT60 0.2, gain 0.2", s + 5, rt60=0.2, gain=0.2),
        Scenario("drift +100 ppm", s + 6, ppm=100),
        Scenario("drift -100 ppm", s + 7, ppm=-100),
        Scenario("tanh drive 1.5", s + 8, drive=1.5),
        Scenario("tanh drive 3 (loud)", s + 9, drive=3.0),
        Scenario("SNR 25 dB", s + 10, snr_db=25),
        Scenario("heavy double talk (the user -3 dB)", s + 11, voice_vs_echo_db=-3.0),
        Scenario("hard: drive 3, +100 ppm, RT60 .5, g .8, 120 ms, 25 dB", s + 12, drive=3.0, ppm=100, rt60=0.5, gain=0.8, delay_ms=120, snr_db=25),
        Scenario("output device switch at 100 s (+40 ms)", s + 13, delay_jump=(100.0, 100.0)),
        Scenario("volume drop at 120 s (gain 0.5 -> 0.2)", s + 14, gain_change=(120.0, 0.2)),
        Scenario("remote noise floor -55 dBFS", s + 15, remote_noise_db=-55.0),
        # what a real microphone chain does to the sum (review_transcribe / SPEC 15)
        Scenario("mild loudspeaker nonlinearity (tanh drive 1.0)", s + 16, drive=1.0),
        Scenario("mic AGC: slow gain wobble +-6 dB / 40 s", s + 17, gain_wobble=(6.0, 40.0)),
        Scenario("mic AGC: slow gain wobble +-9 dB / 15 s", s + 18, gain_wobble=(9.0, 15.0)),
        Scenario("mic AGC: level-following, +-15 dB", s + 19, agc=(-28.0, 15.0)),
        Scenario("mic clipping at 50 % of the peak", s + 20, clip=0.5),
        Scenario("mic clipping at 25 % of the peak (heavy)", s + 21, clip=0.25),
        Scenario("mic preamp soft clip (drive 2)", s + 22, mic_drive=2.0),
        Scenario("AGC + clipping + drift +100 ppm + drive 1.5", s + 23, agc=(-28.0, 12.0), clip=0.5, ppm=100, drive=1.5),
    ]
    if quick:
        keep = {"baseline", "delay 120 ms", "drift +100 ppm", "tanh drive 3 (loud)", "heavy double talk (the user -3 dB)",
                "output device switch at 100 s (+40 ms)", "mild loudspeaker nonlinearity (tanh drive 1.0)",
                "mic AGC: slow gain wobble +-6 dB / 40 s", "mic AGC: level-following, +-15 dB", "mic clipping at 50 % of the peak",
                "AGC + clipping + drift +100 ppm + drive 1.5"}
        cases = [c for c in cases if c.name in keep]
    return cases


def null_cases(seed: int, k: int = 0) -> list[tuple[str, np.ndarray, np.ndarray]]:
    """Inputs WITHOUT speaker leakage, variant ``k``: (name, mic, ref). Auto mode must leave every one of them untouched."""
    out: list[tuple[str, np.ndarray, np.ndarray]] = []
    rng = np.random.default_rng(seed + 100 + k)
    remote = speech_clip("meeting_like_184s", rng, 184.0)
    t_len = len(remote)
    ref = remote
    if have_tts():
        voice_a = np.concatenate([load_clip(n) for n in ("ko_eddy_terms", "ko_flo_terms", "en_samantha_terms", "ko_yuna_terms", "mix_ko_en_ko_codeswitch", "en_samantha_names")])
        voice_a = np.tile(voice_a, 3)[:t_len]
        voice_b = np.roll(load_clip("en_then_ko_101s"), int(rng.integers(0, 40000)))
        voice_b = np.concatenate([voice_b, voice_b])[:t_len]
    else:
        voice_a, voice_b = pseudo_speech(t_len / SR, rng, 100), pseudo_speech(t_len / SR, rng, 190)
    voice_a = np.concatenate([voice_a, np.zeros(max(0, t_len - len(voice_a)), np.float32)])
    voice_b = np.concatenate([voice_b, np.zeros(max(0, t_len - len(voice_b)), np.float32)])
    noise = pink_noise(rng, t_len)
    lvl = lambda x, d: (x * (10.0 ** (d / 20.0) / (np.sqrt(np.mean(x ** 2)) + 1e-9))).astype(np.float32)
    out.append((f"pink noise only [{k}]", lvl(noise, -50 + 2 * k), ref))
    out.append((f"white noise only [{k}]", lvl(rng.standard_normal(t_len), -45 - 3 * k), ref))
    out.append((f"50 Hz hum + noise [{k}]", lvl(np.sin(2 * np.pi * 50 * np.arange(t_len) / SR), -40) + lvl(noise, -60), ref))
    out.append((f"headphones: user speech A [{k}]", lvl(voice_a, -22) + lvl(noise, -55), ref))
    out.append((f"headphones: user speech B [{k}]", lvl(voice_b, -20) + lvl(noise, -52), ref))
    out.append((f"digital silence mic [{k}]", np.zeros(t_len, np.float32), ref))
    out.append((f"silent reference [{k}]", lvl(voice_a, -22) + lvl(noise, -55), np.zeros(t_len, np.float32)))
    h = make_rir(rng, float(rng.uniform(20, 120)), 0.3)
    tiny = fft_convolve(ref, h * (0.003 / np.sqrt((h ** 2).sum())))
    out.append((f"hardware-AEC residual (-67 dBFS) [{k}]", tiny + lvl(voice_a, -22) + lvl(noise, -50), ref))
    late = np.concatenate([np.zeros(int(0.4 * SR), np.float32), lvl(voice_a, -20)])[:t_len]
    out.append((f"remote echo of the user (mic leads ref by 400 ms) [{k}]", lvl(voice_a, -20) + lvl(noise, -55), ref + 0.5 * late))
    out.append((f"copy of ref 5 s late (outside echo range) [{k}]", np.concatenate([np.zeros(5 * SR, np.float32), 0.3 * ref])[:t_len] + lvl(noise, -55), ref))
    music = (0.3 * np.sin(2 * np.pi * 440 * np.arange(t_len) / SR) * (np.sin(2 * np.pi * 0.5 * np.arange(t_len) / SR) > 0)).astype(np.float32)
    out.append((f"tonal ref vs speech mic [{k}]", lvl(voice_a, -22) + lvl(noise, -55), music))
    return out


def run_null(name: str, mic: np.ndarray, ref: np.ndarray, mode: str = "auto") -> dict:
    t0 = time.time()
    keep = mic.copy()
    out, stats = aec.cancel_echo(mic, ref, SR, mode)
    res = {"name": name, "applied": stats["applied"], "coherence": stats["coherence"], "delay_ms": stats["delay_ms"],
           "bit_exact": bool(np.array_equal(out, keep)) and out.dtype == np.float32, "reason": stats.get("reason", "")[:60],
           "seconds": round(time.time() - t0, 1)}
    if mode == "always":
        n = min(len(out), len(keep))
        res["energy_ratio"] = float(np.sum(out[:n] ** 2, dtype=np.float64) / (np.sum(keep[:n] ** 2, dtype=np.float64) + 1e-20))
        res["corr"] = _corr(out[:n], keep[:n])
    return res


def run_null_group(seed: int, k: int, always: bool) -> tuple[list[dict], list[dict]]:
    """All no-echo inputs of variant k (a worker unit: the arrays are generated here, never pickled)."""
    auto_rows, always_rows = [], []
    for name, mic, ref in null_cases(seed, k):
        auto_rows.append(run_null(name, mic, ref, "auto"))
        if always:
            always_rows.append(run_null(name, mic, ref, "always"))
    return auto_rows, always_rows


def lambda_free_null(args):
    return run_null_group(*args)


def _run_case_worker(args):
    scn, vad_modes, support_dir = args
    return run_case(scn, vad_modes, support_dir)


def parallel_map(fn, items: list, jobs: int) -> list:
    """Ordered map; ``jobs`` > 1 uses processes (the box this runs on is often loaded, more processes get more CPU share)."""
    if jobs <= 1 or len(items) <= 1:
        return [fn(i) for i in items]
    import concurrent.futures as cf
    with cf.ProcessPoolExecutor(max_workers=min(jobs, len(items))) as ex:
        return list(ex.map(fn, items))


# --------------------------------------------------------------------------------------
# printing
# --------------------------------------------------------------------------------------
def fmt(v, spec: str = ".1f", width: int = 7) -> str:
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return "-".rjust(width)
    return format(v, spec).rjust(width)


def print_echo_table(rows: list[dict], vad_modes: list[str]) -> None:
    print("\n=== echo cases: ground-truth metrics (auto mode) ===")
    print(f"{'case':<56} {'appl':>4} {'coh':>5} {'dly ms':>11} {'ppm':>6} | {'ERLE':>6} {'mic':>5} {'est':>5} {'vsNoise':>7} | "
          f"{'1T en':>6} {'1T cor':>6} | {'DT gain':>7} {'DT cor':>6} {'(mic)':>5} {'SDR':>5} {'(mic)':>5} | {'s':>4} {'xRT':>5}")
    for r in rows:
        print(f"{r['name']:<56} {str(r['applied'])[0]:>4} {fmt(r['coherence'], '.2f', 5)} "
              f"{fmt(r['delay_ms'], '.1f', 6)}/{fmt(r['true_delay_ms'], '.0f', 4)} {fmt(r['drift_ppm'], '.0f', 6)} | "
              f"{fmt(r.get('erle_db'), '.1f', 6)} {fmt(r.get('erle_mic_db'), '.1f', 5)} {fmt(r.get('est_erle_db'), '.1f', 5)} {fmt(r.get('resid_vs_noise_db'), '.1f', 7)} | "
              f"{fmt(r.get('single_energy_ratio'), '.3f', 6)} {fmt(r.get('single_corr'), '.3f', 6)} | "
              f"{fmt(r.get('dt_voice_gain'), '.2f', 7)} {fmt(r.get('dt_corr'), '.3f', 6)} {fmt(r.get('dt_corr_mic'), '.2f', 5)} "
              f"{fmt(r.get('dt_sdr_db'), '.1f', 5)} {fmt(r.get('dt_sdr_mic_db'), '.1f', 5)} | {fmt(r['cpu_seconds'], '.1f', 5)} {fmt(r['xrt_cpu'], '.0f', 5)}")
    print("columns: ERLE = echo-only frames, mic energy / output energy (dB; 'mic' = same for the untouched mic = 0 expected); est = the "
          "canceller's own estimate (no ground truth); vsNoise = output energy vs the true noise floor on echo-only frames; 1T = single "
          "talk (the user alone): output/mic energy and correlation with the true user signal; DT = double talk: gain of the true user signal in "
          "the output (1.0 = untouched), correlation with the true user signal (mic = before), SDR of the user vs the output (mic = before).")
    for mode in vad_modes:
        print(f"\n=== false VAD regions (no user speech within 0.3 s) -- {mode} VAD, before -> after cleaning ===")
        print(f"{'case':<56} {'regions':>13} {'false':>13} {'false sec':>15}")
        tb = ta = 0
        for r in rows:
            b, a = r[f'vad_{mode}_false_before'], r[f'vad_{mode}_false_after']
            tb += b
            ta += a
            print(f"{r['name']:<56} {r[f'vad_{mode}_regions_before']:>5} ->{r[f'vad_{mode}_regions_after']:>5} {b:>5} ->{a:>5} "
                  f"{r[f'vad_{mode}_false_s_before']:>6.1f} ->{r[f'vad_{mode}_false_s_after']:>5.1f}")
        print(f"{'TOTAL false regions':<56} {'':>13} {tb:>5} ->{ta:>5}")


def print_null_table(rows: list[dict]) -> None:
    print("\n=== no-echo inputs: auto mode must NOT apply and must return the mic bit for bit ===")
    print(f"{'case':<62} {'applied':>7} {'coh':>6} {'bit-exact':>9}  reason")
    bad = 0
    for r in rows:
        ok = (not r["applied"]) and r["bit_exact"]
        bad += 0 if ok else 1
        print(f"{r['name']:<62} {str(r['applied']):>7} {r['coherence']:>6.3f} {str(r['bit_exact']):>9}  {r['reason']}{'' if ok else '   <-- FALSE APPLY'}")
    print(f"false-apply rate: {bad}/{len(rows)}")


# --------------------------------------------------------------------------------------
# runtime on one hour
# --------------------------------------------------------------------------------------
def run_runtime_hour(seed: int) -> dict:
    base = simulate(Scenario("hour", seed, ppm=40, drive=1.0))
    reps = int(np.ceil(3600 / (len(base.mic) / SR)))
    mic, ref = np.tile(base.mic, reps), np.tile(base.ref, reps)
    del base
    print(f"\n=== runtime: {len(mic) / SR / 60:.1f} min of audio ===")
    t0 = time.time()
    out, stats = aec.cancel_echo(mic, ref, SR, "auto", progress=None)
    el = time.time() - t0
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20 if sys.platform == "darwin" else 1 << 10)
    print(f"applied={stats['applied']} time={el:.1f} s ({len(mic) / SR / el:.0f}x real time) peak RSS={rss:.0f} MB (process incl. the simulation)")
    return {"seconds": el, "xrt": len(mic) / SR / el, "peak_rss_mb": rss, "audio_s": len(mic) / SR, "stats": {k: v for k, v in stats.items() if k != "delay_track"}}


# --------------------------------------------------------------------------------------
# real session
# --------------------------------------------------------------------------------------
def _track_array(session_dir: Path, name: str, meta: dict | None, tmp: Path) -> np.ndarray | None:
    """One track as 16 kHz float32 with start_offset_sec of silence in front; reads only, decodes m4a into ``tmp``."""
    wav = session_dir / f"{name}.wav"
    src = wav if wav.exists() else None
    if src is None and (session_dir / f"{name}.m4a").exists():
        src = tmp / f"{name}.wav"
        audioprep.decode_to_wav(session_dir / f"{name}.m4a", src)
        meta = dict(meta or {}, start_offset_sec=0.0)                  # the m4a already contains the padding
    if src is None:
        return None
    info = wavio.read_wav_info(src)
    front = int(round(max(0.0, float((meta or {}).get("start_offset_sec", 0.0))) * info.sample_rate))
    x, sr = wavio.read_wav_padded(src, front=front)
    return audioprep.resample(x, sr, SR).astype(np.float32)


def load_session(session_dir: Path):
    meta = {}
    sj = session_dir / "session.json"
    if sj.exists():
        meta = json.loads(sj.read_text(encoding="utf-8")).get("tracks", {})
    with tempfile.TemporaryDirectory(prefix="aec-eval-") as td:
        mic = _track_array(session_dir, "mic", meta.get("mic"), Path(td))
        remote = _track_array(session_dir, "remote", meta.get("remote"), Path(td))
    if mic is None or remote is None:
        raise SystemExit(f"{session_dir}: need both mic and remote tracks (wav or m4a); found mic={mic is not None} remote={remote is not None}")
    n = max(len(mic), len(remote))
    pad = lambda x: np.concatenate([x, np.zeros(n - len(x), np.float32)])
    return pad(mic), pad(remote)


def region_levels(x: np.ndarray, regions) -> list[float]:
    return [float(db(np.mean(np.square(x[int(s * SR): int(e * SR)], dtype=np.float64)))) if e > s else -120.0 for s, e in regions]


def session_report(session_dir: Path, vad_mode: str, write_cleaned: bool, support_dir: Path | None) -> int:
    print(f"session: {session_dir}   (read-only{', will write mic.aec.wav' if write_cleaned else ''})")
    mic, remote = load_session(session_dir)
    print(f"mic {len(mic) / SR:.1f} s, remote {len(remote) / SR:.1f} s (16 kHz, offsets applied)")
    t0 = time.time()
    applicable, coh = aec.decide_applicable(mic, remote, SR)
    print(f"decide_applicable: {applicable}  coherence={coh:.3f} (threshold {aec.AecParams().coherence_threshold})  [{time.time() - t0:.1f} s]")
    out, stats = aec.cancel_echo(mic, remote, SR, "auto", progress=lambda m: print("  ", m))
    keys = ("applied", "reason", "coherence", "delay_ms", "drift_ppm", "erle_db", "erle_linear_db", "preserved_ratio", "echo_only_s",
            "double_talk_s", "ref_active_s", "res_rho_db", "guard_reverted", "runtime_s", "realtime_factor", "error")
    for k in keys:
        if k in stats and stats[k] not in (None, ""):
            print(f"  {k:<16} {stats[k]}")
    track = stats.get("delay_track") or []
    if track:
        print("  delay track (t s -> ms): " + ", ".join(f"{t:.0f}->{d:.1f}" for t, d in track[:24]) + (" ..." if len(track) > 24 else ""))
    if stats["applied"]:
        modes = [vad_mode] if vad_mode != "auto" else (["silero", "energy"] if silero_available(support_dir) else ["energy"])
        for mode in modes:
            try:
                rb = vadmod.detect_speech(mic, mode, support_dir)
                ra = vadmod.detect_speech(out, mode, support_dir)
            except vadmod.VadUnavailable as exc:
                print(f"VAD {mode}: unavailable ({exc})")
                continue
            print(f"\nVAD {mode} on the mic track: before {len(rb.regions)} regions / {rb.speech_seconds:.1f} s speech  ->  after "
                  f"{len(ra.regions)} regions / {ra.speech_seconds:.1f} s")
            after = np.zeros(int(len(out) / SR * 50) + 2, bool)
            for s, e in ra.regions:
                after[int(s * 50): int(np.ceil(e * 50)) + 1] = True
            lost = []
            for s, e in rb.regions:
                kept = float(after[int(s * 50): int(np.ceil(e * 50)) + 1].mean())
                if kept < 0.5:
                    lost.append((s, e, kept))
            print(f"regions that disappeared (listen to these in mic.m4a; each should be pure echo): {len(lost)}")
            lv_b = region_levels(mic, [(s, e) for s, e, _ in lost])
            lv_a = region_levels(out, [(s, e) for s, e, _ in lost])
            for (s, e, kept), lb, la in list(zip(lost, lv_b, lv_a))[:40]:
                print(f"   {s:8.1f} - {e:8.1f} s ({e - s:5.1f} s)  level {lb:6.1f} -> {la:6.1f} dBFS ({lb - la:4.1f} dB removed)")
            if len(lost) > 40:
                print(f"   ... {len(lost) - 40} more")
        if write_cleaned:
            dst = session_dir / "mic.aec.wav"
            wavio.write_wav_int16(dst, out, SR)
            print(f"\nwrote {dst}")
    elif write_cleaned:
        print("\nnot applied: no mic.aec.wav written")
    return 0


# --------------------------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--session", type=Path, help="evaluate a real session directory (read-only unless --write-cleaned)")
    ap.add_argument("--write-cleaned", action="store_true", help="with --session: write mic.aec.wav next to mic.wav")
    ap.add_argument("--vad", default="auto", choices=["auto", "energy", "silero"], help="VAD for the before/after counts")
    ap.add_argument("--quick", action="store_true", help="fewer synthetic cases")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-vad", action="store_true", help="skip the VAD comparison in the synthetic suite")
    ap.add_argument("--runtime-hour", action="store_true", help="also time a one hour synthetic recording")
    ap.add_argument("--always-null", action="store_true", help="also run 'always' mode on the no-echo inputs (damage check)")
    ap.add_argument("--jobs", type=int, default=1, help="worker processes for the synthetic suite (default 1)")
    ap.add_argument("--json", type=Path, help="write all results to this file")
    ap.add_argument("--support-dir", type=Path, help="SUPPORT_DIR for the Silero model lookup (default: real one for --session, a temp dir otherwise)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING, format="%(levelname)s %(name)s: %(message)s")

    if args.session:
        support = args.support_dir
        if support is None:
            from mcap.config import DEFAULT_SUPPORT_DIR
            support = DEFAULT_SUPPORT_DIR
        return session_report(args.session, args.vad, args.write_cleaned, support)

    if args.write_cleaned:
        ap.error("--write-cleaned needs --session")
    print(f"material: {'TTS clips from ' + str(TTS_DIR) if have_tts() else 'pseudo-speech (benchmarks/tts not found)'}")
    with tempfile.TemporaryDirectory(prefix="aec-eval-support-") as td:
        support = args.support_dir or Path(td)
        vad_modes: list[str] = []
        if not args.no_vad:
            vad_modes = ["energy"] + (["silero"] if silero_available(support) else [])
            if "silero" not in vad_modes:
                print("(Silero VAD not available: set MCAP_SILERO_MODEL=<silero_vad.onnx> and use a Python with onnxruntime to include it)")
        results: dict = {"echo": [], "null": [], "null_always": []}
        scns = echo_scenarios(args.quick, args.seed)
        results["echo"] = parallel_map(_run_case_worker, [(scn, vad_modes, support) for scn in scns], args.jobs)
        print_echo_table(results["echo"], vad_modes)
        n_seeds = 1 if args.quick else 3
        groups = parallel_map(lambda_free_null, [(args.seed, k, args.always_null) for k in range(n_seeds)], args.jobs)
        for auto_rows, always_rows in groups:
            results["null"] += auto_rows
            results["null_always"] += always_rows
        print_null_table(results["null"])
        if args.always_null:
            print("\n=== 'always' mode on the same no-echo inputs (damage check: ratio ~1, corr ~1) ===")
            for r in results["null_always"]:
                print(f"{r['name']:<62} applied={r['applied']!s:<5} energy ratio={fmt(r.get('energy_ratio'), '.3f', 6)} corr={fmt(r.get('corr'), '.4f', 7)}")
        if args.runtime_hour:
            results["runtime_hour"] = run_runtime_hour(args.seed)
    if args.json:
        args.json.write_text(json.dumps(results, indent=1, default=float), encoding="utf-8")
        print(f"\nresults written to {args.json}")
    bad = sum(1 for r in results["null"] if r["applied"] or not r["bit_exact"])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
