"""Audio preparation (SPEC 7 step 1, 13.2, 13.4): session WAVs -> aligned 16 kHz arrays for ASR + archive m4a files.

* Every track is padded at the front with ``start_offset_sec`` of silence (and at the end up to the session length), so
  sample 0 of every array / archive file is session t0 and all tracks have the same length.
* A track the recorder never produced (missing from ``session.json`` or its WAV is absent/empty/unreadable) is replaced by
  silence and reported in ``PreparedAudio.missing``; with no usable track at all ``NoAudioError("no audio")`` is raised.
* 48 kHz -> 16 kHz is done in memory with a numpy polyphase FIR decimator (zero phase, so no time shift). Reasons for not
  using ``afconvert`` here: no temp files or subprocess for the hot path, deterministic output, unit-testable, ~2 s per
  hour of audio. ``afconvert`` is used for AAC encoding (the only thing that needs Apple's encoder) and to decode m4a/mp4.
  Rates that are not an integer multiple of 16 kHz (never produced by the app, which always writes 48 kHz) go through
  ``scipy.signal.resample_poly`` if scipy is installed (it is a dependency of mlx-whisper).
* ``mic.m4a`` / ``remote.m4a`` / ``audio.m4a`` (mono AAC; audio.m4a = mix of both tracks at full rate with a global gain
  that avoids clipping) are created with ``afconvert`` and skipped when they are newer than their inputs (``force``
  overrides). Encoder failures are logged and non-fatal: transcription does not depend on them, and the missing file is
  simply absent from ``archive_files`` so the publisher keeps the WAVs.
* After a session was published the WAVs are gone; if ``<track>.m4a`` exists it is decoded and used instead (its offset
  is already baked in, and it is never re-encoded from itself).
* Scratch files (the decoded / padded full-length WAVs that feed the AAC encoder, ~345 MB per hour per track) live in a
  temporary directory OUTSIDE the session directory (``$TMPDIR``): a session directory can be the Google Drive archive folder
  (``reprocess --from asr`` of a published meeting), and a killed run must never leave scratch behind that gets published.
  ``sweep_stale_scratch`` removes what an earlier killed run left: ``.prep-*`` directories and ``*.part`` files in the session
  directory, and old ``mcap-prep-*`` directories in the temp directory.
"""
from __future__ import annotations

import logging
import math
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import wavio

log = logging.getLogger("mcap.audioprep")

ASR_SR = 16000
TRACK_NAMES = ("mic", "remote")        # processing order (SPEC 13.2: mic first)
AAC_BPS_TRACK = 48_000                 # per-track archive files (speech, mono)
AAC_BPS_MIX = 64_000                   # audio.m4a, the file a human actually listens to
CLIP_CEILING = 0.89                    # -1 dBFS: peak of the mixed archive audio (headroom for AAC overshoot)
MAX_OFFSET_SEC = 6 * 3600              # sanity cap for start_offset_sec (MAX_RECORDING_HOURS)
MIN_RATE, MAX_RATE = 8000, 192000
SCRATCH_PREFIX = "mcap-prep-"          # temp directory of one prepare_audio run (in $TMPDIR)
LEGACY_SCRATCH_PREFIX = ".prep-"       # older versions created it inside the session directory
STALE_TMP_SECONDS = 6 * 3600           # a mcap-prep-* directory in $TMPDIR older than this belongs to a dead run


class NoAudioError(RuntimeError):
    """Neither track has usable audio (SPEC 13.2: the session fails with 'no audio')."""


class AfconvertError(RuntimeError):
    pass


@dataclass
class PreparedAudio:
    tracks: dict[str, np.ndarray]       # "mic", "remote": float32 mono 16 kHz, index 0 == session t0, same length
    sample_rate: int                    # 16000
    duration_sec: float
    archive_files: dict[str, Path]      # "audio", "mic", "remote" -> m4a in session_dir (only files that exist)
    missing: list[str] = field(default_factory=list)    # tracks with no usable audio (zeros were synthesized)
    warnings: list[str] = field(default_factory=list)   # human-readable notes (also logged)


# --------------------------------------------------------------------------------------
# resampling
# --------------------------------------------------------------------------------------
def _lowpass_taps(q: int, sr_in: int) -> np.ndarray:
    """Kaiser-windowed sinc, unity DC gain, cutoff 7.52 kHz (just under the 8 kHz Nyquist of the 16 kHz output)."""
    length = 42 * q + 1
    n = np.arange(length) - (length - 1) / 2
    fc = 7520.0 / sr_in
    h = 2 * fc * np.sinc(2 * fc * n) * np.kaiser(length, 8.0)
    return (h / h.sum()).astype(np.float32)


_DECIMATE_BLOCK = 1 << 18    # output samples per block: bounded temporary memory for hour-long tracks


def _decimate(x: np.ndarray, q: int, block: int = _DECIMATE_BLOCK) -> np.ndarray:
    """FIR low-pass + keep every q-th sample, in polyphase form (q small correlations at the low rate), block by block.
    Zero phase: output n is centred on input sample n*q (input outside the array counts as silence).
    Output length = ceil(len(x) / q)."""
    h = _lowpass_taps(q, q * ASR_SR)
    length = len(h)
    centre = length // 2
    n_out = -(-len(x) // q)
    y = np.empty(n_out, np.float32)
    k = np.arange(length)
    phases = []
    for r in range(q):
        kk = k[((length - 1 - k) % q) == r]          # taps that see input phase r
        jj = (length - 1 - kk - r) // q              # their position inside that phase
        phases.append(h[kk[np.argsort(jj)]])
    for o0 in range(0, n_out, block):
        o1 = min(n_out, o0 + block)
        i0, i1 = o0 * q - centre, (o1 - 1) * q + length - centre            # input samples this block of outputs depends on
        seg = np.zeros(i1 - i0, np.float32)
        lo, hi = max(i0, 0), min(i1, len(x))
        if hi > lo:
            seg[lo - i0: hi - i0] = x[lo:hi]
        acc = np.zeros(o1 - o0, np.float32)
        for r in range(q):
            yy = np.correlate(seg[r::q], phases[r], mode="valid")
            m = min(len(yy), len(acc))
            acc[:m] += yy[:m]
        y[o0:o1] = acc
    return y


def resample(x: np.ndarray, sr_in: int, sr_out: int = ASR_SR) -> np.ndarray:
    """float32 mono -> float32 mono at sr_out (see module docstring for the method)."""
    x = np.asarray(x, dtype=np.float32)
    if sr_in == sr_out:
        return x
    if sr_in > sr_out and sr_in % sr_out == 0:
        return _decimate(x, sr_in // sr_out)
    try:
        from scipy.signal import resample_poly
    except ImportError as exc:
        raise ValueError(f"cannot resample {sr_in} Hz -> {sr_out} Hz without scipy") from exc
    g = math.gcd(sr_in, sr_out)
    return resample_poly(x, sr_out // g, sr_in // g).astype(np.float32)


def limit_peak(mixed: np.ndarray) -> np.ndarray:
    """In place: one global gain if the peak exceeds CLIP_CEILING (no clipping, no distortion); returns the same array."""
    peak = float(np.abs(mixed).max()) if mixed.size else 0.0
    if peak > CLIP_CEILING:
        mixed *= np.float32(CLIP_CEILING / peak)
    return mixed


def mix_tracks(arrays: list[np.ndarray]) -> np.ndarray:
    """Sum equally long tracks (new array) and apply the clipping protection."""
    mixed = arrays[0].astype(np.float32, copy=True)
    for a in arrays[1:]:
        mixed += a
    return limit_peak(mixed)


# --------------------------------------------------------------------------------------
# afconvert
# --------------------------------------------------------------------------------------
SYSTEM_AFCONVERT = "/usr/bin/afconvert"      # Apple's own binary (part of macOS); a PATH lookup can find a copy in a user-writable directory


def afconvert_path() -> str | None:
    """``/usr/bin/afconvert`` when it exists, so a lookalike earlier in PATH (a user-writable directory) is never run; the PATH lookup
    remains for a machine that has it elsewhere. On macOS this is the same binary the PATH lookup found before."""
    return SYSTEM_AFCONVERT if os.access(SYSTEM_AFCONVERT, os.X_OK) else shutil.which("afconvert")


def _run_afconvert(args: list[str], timeout: float) -> None:
    exe = afconvert_path()
    if exe is None:
        raise AfconvertError("afconvert not found (macOS only)")
    try:
        proc = subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise AfconvertError(f"afconvert timed out after {timeout:.0f}s") from exc
    if proc.returncode != 0:
        raise AfconvertError(f"afconvert exited {proc.returncode}: {(proc.stderr or proc.stdout).strip()[-300:]}")


def encode_m4a(src_wav: Path, dst_m4a: Path, bits_per_second: int, timeout: float = 1800) -> None:
    """AAC-LC in an m4a container. Written to a .part file first so a crash never leaves a truncated m4a behind.
    Not every bit rate is valid for every sample rate (64 kbit/s is refused for 16 kHz mono), so a rejected rate is retried
    once with the encoder's own default."""
    part = dst_m4a.with_name(dst_m4a.name + ".part")
    try:
        try:
            _run_afconvert(["-f", "m4af", "-d", "aac", "-b", str(bits_per_second), str(src_wav), str(part)], timeout)
        except AfconvertError as exc:
            log.info("afconvert rejected %d bit/s (%s); retrying with the default rate", bits_per_second, exc)
            _run_afconvert(["-f", "m4af", "-d", "aac", str(src_wav), str(part)], timeout)
        if not part.exists() or part.stat().st_size == 0:
            raise AfconvertError("afconvert produced no output")
        os.replace(part, dst_m4a)
    finally:
        if part.exists():
            try:
                part.unlink()
            except OSError:
                pass


def decode_to_wav(src: Path, dst_wav: Path, sample_rate: int | None = None, channels: int = 1, timeout: float = 1800) -> None:
    """Any audio file afconvert understands (m4a, mp4, mp3, wav...) -> 16-bit PCM WAV (native rate unless given)."""
    fmt = f"LEI16@{sample_rate}" if sample_rate else "LEI16"
    _run_afconvert(["-f", "WAVE", "-d", fmt, "-c", str(channels), str(src), str(dst_wav)], timeout)


# --------------------------------------------------------------------------------------
# sources
# --------------------------------------------------------------------------------------
@dataclass
class _Source:
    name: str
    path: Path                   # WAV to read: the recorder's file, or a temp decode of the archived m4a
    sr: int
    frames: int
    offset_sec: float
    kind: str                    # "wav" | "m4a"
    inputs: list[Path]           # files whose mtime decides whether archive files are stale


def _offset_seconds(meta: dict, name: str, warnings: list[str]) -> float:
    try:
        off = float(meta.get("start_offset_sec") or 0.0)
    except (TypeError, ValueError):
        off = float("nan")
    if not math.isfinite(off) or off < 0:
        _warn(warnings, f"{name}: invalid start_offset_sec {meta.get('start_offset_sec')!r}, using 0")
        return 0.0
    if off > MAX_OFFSET_SEC:
        _warn(warnings, f"{name}: start_offset_sec {off:.1f}s is implausible, clamped to {MAX_OFFSET_SEC}s")
        return float(MAX_OFFSET_SEC)
    return off


def _warn(warnings: list[str], msg: str) -> None:
    log.warning("%s", msg)
    warnings.append(msg)


def _probe_track(session_dir: Path, name: str, meta, tmpdir: Path, warnings: list[str]) -> _Source | None:
    """Header-level look at one track (no audio is read, so memory stays flat). None = treat the track as missing."""
    if not isinstance(meta, dict):
        _warn(warnings, f"{name}: not in session.json (never recorded)")
        return None
    wav = session_dir / Path(str(meta.get("file") or f"{name}.wav")).name        # session.json may name the file
    offset = _offset_seconds(meta, name, warnings)
    problem = None
    if wav.exists():
        try:
            info = wavio.read_wav_info(wav)
            if not (MIN_RATE <= info.sample_rate <= MAX_RATE):
                problem = f"unsupported sample rate {info.sample_rate}"
            elif info.frames == 0:
                problem = "no audio frames"
            else:
                declared = meta.get("sample_rate")
                try:
                    declared_rate = int(declared) if declared else None
                except (TypeError, ValueError):               # "48k", a list, ...: the header is what counts anyway
                    declared_rate = None
                    _warn(warnings, f"{name}: session.json sample_rate {declared!r} is not a number; using the WAV header ({info.sample_rate} Hz)")
                if declared_rate and declared_rate != info.sample_rate:
                    _warn(warnings, f"{name}: session.json says {declared} Hz but the WAV header says {info.sample_rate} Hz; using the header")
                return _Source(name, wav, info.sample_rate, info.frames, offset, "wav", [wav])
        except (wavio.WavError, OSError, ValueError) as exc:
            problem = f"unreadable ({exc})"
    else:
        problem = "WAV file missing"
    m4a = session_dir / f"{name}.m4a"
    if m4a.exists():
        try:
            decoded = tmpdir / f"{name}-from-m4a.wav"
            decode_to_wav(m4a, decoded)
            info = wavio.read_wav_info(decoded)
            if info.frames and MIN_RATE <= info.sample_rate <= MAX_RATE:
                log.info("%s: %s; using the archived %s instead (its offset is already applied)", name, problem, m4a.name)
                return _Source(name, decoded, info.sample_rate, info.frames, 0.0, "m4a", [m4a])
        except (AfconvertError, wavio.WavError, OSError, ValueError) as exc:
            problem = f"{problem}; m4a fallback failed ({exc})"
    _warn(warnings, f"{name}: {problem}; treating the track as missing")
    return None


def _is_fresh(out: Path, inputs: list[Path]) -> bool:
    try:
        st = out.stat()
        if st.st_size <= 0:
            return False
        return st.st_mtime_ns >= max((p.stat().st_mtime_ns for p in inputs if p.exists()), default=0)
    except OSError:
        return False


def _pad_front_and_back(x: np.ndarray, front: int, total: int) -> np.ndarray:
    out = np.zeros(total, np.float32)
    n = min(len(x), max(0, total - front))
    out[front: front + n] = x[:n]
    return out


def _try_encode(out: Path, write_wav, bps: int, tmpdir: Path, warnings: list[str]) -> bool:
    """Encode to ``out`` (a temp WAV is written by ``write_wav(path)`` first). True when ``out`` exists afterwards. Never raises."""
    if afconvert_path() is None:
        return False
    tmp_wav = tmpdir / (out.stem + "-enc.wav")
    t0 = time.time()
    try:
        write_wav(tmp_wav)
        encode_m4a(tmp_wav, out, bps)
        log.info("%s created (%.1f MB, %.1fs)", out.name, out.stat().st_size / 1e6, time.time() - t0)
        return True
    except (AfconvertError, OSError, ValueError) as exc:
        _warn(warnings, f"{out.name}: encoding failed ({exc}); keeping the WAV files")
        return False
    finally:
        if tmp_wav.exists():
            try:
                tmp_wav.unlink()
            except OSError:
                pass


# --------------------------------------------------------------------------------------
# scratch space
# --------------------------------------------------------------------------------------
def _rm(path: Path) -> bool:
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
        return True
    except OSError as exc:
        log.warning("could not remove stale scratch %s: %s", path, exc)
        return False


def sweep_stale_scratch(session_dir: Path, tmp_root: Path | None = None, max_age_s: float = STALE_TMP_SECONDS) -> list[str]:
    """Remove what a killed earlier run left behind. Never raises; returns the removed paths (for logs and tests).

    * session directory: ``.prep-*`` directories (scratch of older versions) and ``*.part`` files (an m4a that was being
      encoded when the process died). Safe because the pipeline holds the session lock while it prepares audio, and an
      unfinished ``.part`` file is never useful;
    * temp directory: ``mcap-prep-*`` directories older than ``max_age_s`` (younger ones may belong to a live run).
    """
    removed: list[str] = []
    try:
        entries = sorted(Path(session_dir).iterdir())
    except OSError:
        entries = []
    for entry in entries:
        name = entry.name
        if (name.startswith(LEGACY_SCRATCH_PREFIX) or name.lower().endswith(".part")) and _rm(entry):
            removed.append(str(entry))
    try:
        root = Path(tmp_root) if tmp_root is not None else Path(tempfile.gettempdir())
        now = time.time()
        for entry in sorted(root.glob(SCRATCH_PREFIX + "*")):
            try:
                if entry.is_dir() and now - entry.stat().st_mtime > max_age_s and _rm(entry):
                    removed.append(str(entry))
            except OSError:
                continue
    except OSError:
        pass
    if removed:
        log.info("swept stale scratch of an earlier run: %s", ", ".join(removed))
    return removed


def _make_scratch_dir(session_dir: Path) -> Path:
    """A private scratch directory outside the session directory ($TMPDIR). Only if that is impossible (no temp space) the
    session directory is used as a last resort, with a warning: ``.prep-*`` is then swept by the next run / the publisher."""
    try:
        return Path(tempfile.mkdtemp(prefix=SCRATCH_PREFIX))
    except OSError as exc:
        log.warning("cannot create a temp directory (%s); using the session directory for scratch files", exc)
        return Path(tempfile.mkdtemp(prefix=LEGACY_SCRATCH_PREFIX, dir=session_dir))


# --------------------------------------------------------------------------------------
# main entry
# --------------------------------------------------------------------------------------
def prepare_audio(session_dir: Path, session: dict, force: bool = False) -> PreparedAudio:
    """See the module docstring. ``session`` is the content of session.json.

    Memory: tracks are handled one at a time (header probe first, so the common length is known up front); at most the
    padded track being processed plus the running mix are held at the native rate (about 2 GB per hour of 48 kHz audio).
    """
    t_begin = time.time()
    session_dir = Path(session_dir)
    tracks_meta = (session or {}).get("tracks") if isinstance(session, dict) else None
    tracks_meta = tracks_meta if isinstance(tracks_meta, dict) else {}
    warnings: list[str] = []
    sweep_stale_scratch(session_dir)
    tmpdir = _make_scratch_dir(session_dir)
    try:
        sources: dict[str, _Source] = {}
        for n in TRACK_NAMES:
            src = _probe_track(session_dir, n, tracks_meta.get(n), tmpdir, warnings)
            if src is not None:
                sources[n] = src
        if not sources:
            raise NoAudioError("no audio")

        # common timeline: front padding by the offset, back padding up to the session length (at each track's native rate)
        front = {n: int(round(s.offset_sec * s.sr)) for n, s in sources.items()}
        duration = max((front[n] + s.frames) / s.sr for n, s in sources.items())
        rates = {s.sr for s in sources.values()}
        extra = [p for p in (session_dir / "session.json",) if p.exists()]
        all_inputs = [p for s in sources.values() for p in s.inputs] + extra
        have_afconvert = afconvert_path() is not None
        if not have_afconvert:
            _warn(warnings, "afconvert not available: no m4a files created")
        audio_m4a = session_dir / "audio.m4a"
        from_m4a = any(s.kind == "m4a" for s in sources.values())
        # audio.m4a is kept when it is newer than all inputs, or when an input is itself an archived m4a (never rebuilt from lossy sources)
        mix_ok = audio_m4a.exists() and (from_m4a or (not force and _is_fresh(audio_m4a, all_inputs)))
        need_mix = have_afconvert and not mix_ok

        archive: dict[str, Path] = {}
        arrays: dict[str, np.ndarray] = {}
        mix: np.ndarray | None = None
        for n in TRACK_NAMES:
            src = sources.get(n)
            if src is None:
                continue
            try:
                padded, sr = wavio.read_wav_padded(src.path, front[n], int(round(duration * src.sr)))
            except (wavio.WavError, OSError, ValueError) as exc:
                _warn(warnings, f"{n}: reading the audio failed ({exc}); treating the track as missing")
                del sources[n]
                continue
            out_m4a = session_dir / f"{n}.m4a"
            if src.kind == "m4a":                              # already the archive file; never re-encode lossy -> lossy
                archive[n] = out_m4a
            elif have_afconvert and not force and _is_fresh(out_m4a, src.inputs + extra):
                log.info("%s is up to date, skipped", out_m4a.name)
                archive[n] = out_m4a
            elif _try_encode(out_m4a, lambda p, x=padded, r=sr: wavio.write_wav_int16(p, x, r), AAC_BPS_TRACK, tmpdir, warnings):
                archive[n] = out_m4a
            a16 = resample(padded, sr, ASR_SR)
            arrays[n] = a16.copy() if a16 is padded else a16   # a 16 kHz source is returned as is; the mix below adds into `padded`
            if need_mix and len(rates) == 1:
                mix = padded if mix is None else _add_into(mix, padded)
            del padded

        missing = [n for n in TRACK_NAMES if n not in arrays]
        if not arrays:
            raise NoAudioError("no audio")
        n16 = max(len(a) for a in arrays.values())
        tracks: dict[str, np.ndarray] = {}
        for n in TRACK_NAMES:
            tracks[n] = _pad_front_and_back(arrays.pop(n), 0, n16) if n in arrays else np.zeros(n16, np.float32)
        for n in missing:
            _warn(warnings, f"{n}: no audio, silence synthesized for the {n16 / ASR_SR:.1f}s timeline")

        if need_mix:
            if len(rates) == 1:
                mix = limit_peak(mix) if mix is not None else None
                mix_sr = next(iter(rates))
            else:                                               # never produced by the app (48 kHz fixed): mix at 16 kHz instead of failing
                mix, mix_sr = mix_tracks([tracks[n] for n in TRACK_NAMES if n in sources]), ASR_SR
            if mix is not None and _try_encode(audio_m4a, lambda p, x=mix, r=mix_sr: wavio.write_wav_int16(p, x, r), AAC_BPS_MIX, tmpdir, warnings):
                archive["audio"] = audio_m4a
        elif mix_ok:
            log.info("audio.m4a is up to date, skipped")
            archive["audio"] = audio_m4a
        mix = None
        log.info("prepared audio: %.1fs, tracks %s, missing %s, m4a %s (%.1fs)", n16 / ASR_SR,
                 {n: f"{s.sr} Hz +{s.offset_sec:.2f}s {s.kind}" for n, s in sources.items()}, missing or "none", sorted(archive),
                 time.time() - t_begin)
        return PreparedAudio(tracks=tracks, sample_rate=ASR_SR, duration_sec=n16 / ASR_SR, archive_files=archive,
                             missing=missing, warnings=warnings)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def _add_into(acc: np.ndarray, x: np.ndarray) -> np.ndarray:
    acc += x
    return acc
