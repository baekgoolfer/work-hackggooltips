"""WAV I/O for the pipeline: a lenient reader and an int16 writer (SPEC 4.2 / 12.2).

The Swift recorder streams PCM into ``mic.wav`` / ``remote.wav`` and refreshes the RIFF/data size fields only every
~5 s, so a killed or crashed app leaves a file whose header is stale (or still says 0). The reader therefore never
trusts the size fields blindly: the ``data`` chunk is the last thing in the file, and its true length is whatever is
left in the file (rounded down to a whole frame, which also drops a torn odd byte).

Only the standard library and numpy are used.
"""
from __future__ import annotations

import logging
import os
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np

log = logging.getLogger("mcap.wavio")

_FMT_PCM = 1
_FMT_FLOAT = 3
_FMT_EXTENSIBLE = 0xFFFE
_UINT32_MAX = 0xFFFFFFFF


class WavError(ValueError):
    """The file is not a WAV file we can interpret (no RIFF/WAVE header, no fmt or data chunk, unsupported format)."""


@dataclass
class WavInfo:
    sample_rate: int
    channels: int
    bits: int
    is_float: bool
    data_offset: int
    data_bytes: int      # usable audio bytes (a whole number of frames)
    frames: int
    repaired: str        # "" when the header was consistent, otherwise what had to be repaired

    @property
    def duration_sec(self) -> float:
        return self.frames / self.sample_rate if self.sample_rate else 0.0


def _looks_like_chunk_id(raw: bytes) -> bool:
    return len(raw) == 4 and all(0x20 <= b < 0x7F for b in raw)


def read_wav_info(path: Path) -> WavInfo:
    """Parse the header of ``path`` and work out how many audio bytes are really there. Raises WavError / OSError."""
    path = Path(path)
    file_len = path.stat().st_size
    with open(path, "rb") as f:
        head = f.read(12)
        if len(head) < 12 or head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise WavError(f"{path.name}: not a RIFF/WAVE file")
        fmt = None
        data_offset = data_size = None
        pos = 12
        while pos + 8 <= file_len:
            f.seek(pos)
            hdr = f.read(8)
            if len(hdr) < 8:
                break
            cid, size = hdr[:4], struct.unpack("<I", hdr[4:])[0]
            body = pos + 8
            if cid == b"fmt ":
                f.seek(body)
                fmt = f.read(min(size, 40))
            elif cid == b"data":
                data_offset, data_size = body, size
                break
            pos = body + size + (size & 1)
        if fmt is None or len(fmt) < 16:
            raise WavError(f"{path.name}: missing or short fmt chunk")
        if data_offset is None:
            raise WavError(f"{path.name}: no data chunk")
        tag, channels, rate, _byte_rate, _align, bits = struct.unpack("<HHIIHH", fmt[:16])
        if tag == _FMT_EXTENSIBLE and len(fmt) >= 26:
            tag = struct.unpack("<H", fmt[24:26])[0]  # first two bytes of the sub-format GUID
        is_float = tag == _FMT_FLOAT
        if tag not in (_FMT_PCM, _FMT_FLOAT):
            raise WavError(f"{path.name}: unsupported WAV format tag {tag}")
        if channels < 1 or rate < 1 or bits not in (8, 16, 24, 32, 64) or (is_float and bits not in (32, 64)):
            raise WavError(f"{path.name}: unsupported format ({channels} ch, {rate} Hz, {bits} bit)")

        remaining = file_len - data_offset
        repaired = ""
        n = data_size
        if data_size == 0 or data_size == _UINT32_MAX or data_size > remaining:
            n = remaining
            repaired = f"data size field {data_size} -> {remaining} (from file length)"
        elif data_size < remaining:
            # Either a valid chunk (LIST, ...) follows the audio, or the header is stale and more PCM follows.
            f.seek(data_offset + data_size + (data_size & 1))
            nxt = f.read(8)
            trailing_chunk = (
                len(nxt) == 8
                and _looks_like_chunk_id(nxt[:4])
                and struct.unpack("<I", nxt[4:])[0] <= remaining - data_size
            )
            if not trailing_chunk:
                n = remaining
                repaired = f"stale data size {data_size} -> {remaining} (more audio follows the declared end)"
        frame_bytes = channels * (bits // 8)
        usable = n - (n % frame_bytes)
        if usable != n:
            repaired = (repaired + "; " if repaired else "") + f"dropped {n - usable} torn byte(s)"
        return WavInfo(rate, channels, bits, is_float, data_offset, usable, usable // frame_bytes, repaired)


_READ_BLOCK = 1 << 20       # samples per read step for 16-bit mono (bounded temporary memory)


def _decode_other_formats(path: Path, info: WavInfo) -> np.ndarray:
    """8/24/32-bit, float and multi-channel files (never written by the recorder): whole file -> float32 mono."""
    count = info.frames * info.channels
    if info.bits == 16 and not info.is_float:
        x = np.fromfile(path, dtype="<i2", count=count, offset=info.data_offset).astype(np.float32) * np.float32(1.0 / 32768.0)
    elif info.bits == 8:
        raw = np.fromfile(path, dtype=np.uint8, count=count, offset=info.data_offset)
        x = (raw.astype(np.float32) - 128.0) * np.float32(1.0 / 128.0)
    elif info.bits == 24:
        raw = np.fromfile(path, dtype=np.uint8, count=count * 3, offset=info.data_offset).reshape(-1, 3).astype(np.int32)
        v = raw[:, 0] | (raw[:, 1] << 8) | (raw[:, 2] << 16)
        x = (((v ^ 0x800000) - 0x800000).astype(np.float32)) * np.float32(1.0 / 8388608.0)
    elif info.bits == 32 and not info.is_float:
        raw = np.fromfile(path, dtype="<i4", count=count, offset=info.data_offset)
        x = (raw.astype(np.float64) / 2147483648.0).astype(np.float32)
    elif info.is_float and info.bits in (32, 64):
        raw = np.fromfile(path, dtype="<f4" if info.bits == 32 else "<f8", count=count, offset=info.data_offset)
        x = np.nan_to_num(raw.astype(np.float32), nan=0.0, posinf=1.0, neginf=-1.0)
    else:  # pragma: no cover - read_wav_info already rejected everything else
        raise WavError(f"{path.name}: unsupported sample format")
    if x.size != count:  # file shrank between stat() and read: keep whole frames only
        x = x[: x.size - (x.size % info.channels)]
    if info.channels > 1:
        x = x.reshape(-1, info.channels).mean(axis=1).astype(np.float32)
    return x


def read_wav_padded(path: Path, front: int = 0, total: int | None = None) -> tuple[np.ndarray, int]:
    """Like ``read_wav_lenient`` but the audio is placed at sample ``front`` of a zero-filled float32 array of length
    ``total`` (default: front + all frames); audio that does not fit is cut. One allocation, no full-size temporaries, which
    keeps hour-long recordings cheap (used by audioprep for the start-offset padding)."""
    path = Path(path)
    info = read_wav_info(path)
    if info.repaired:
        log.info("%s: repaired WAV header: %s", path.name, info.repaired)
    front = max(0, int(front))
    total = front + info.frames if total is None else max(0, int(total))
    out = np.zeros(total, np.float32)
    take = max(0, min(info.frames, total - front))
    if take == 0:
        return out, info.sample_rate
    if info.bits == 16 and not info.is_float and info.channels == 1:
        with open(path, "rb") as f:
            f.seek(info.data_offset)
            pos = 0
            while pos < take:
                raw = np.fromfile(f, dtype="<i2", count=min(_READ_BLOCK, take - pos))
                if raw.size == 0:                       # file shrank while reading
                    break
                dst = out[front + pos: front + pos + raw.size]
                dst[:] = raw
                dst *= np.float32(1.0 / 32768.0)
                pos += raw.size
    else:
        x = _decode_other_formats(path, info)
        take = min(take, len(x))
        out[front: front + take] = x[:take]
    return out, info.sample_rate


def read_wav_lenient(path: Path) -> tuple[np.ndarray, int]:
    """Read a WAV file -> (float32 mono samples in [-1, 1], sample_rate). Multi-channel audio is averaged.

    Header problems left by an interrupted recording are repaired from the file length (logged at INFO). Raises
    WavError for files that are not WAV at all and OSError for I/O problems; an empty data chunk gives an empty array.
    """
    return read_wav_padded(path, 0, None)


def to_int16(samples: np.ndarray) -> np.ndarray:
    """float [-1, 1] (or int16) -> little-endian int16 with rounding and clipping; NaN becomes 0."""
    x = np.asarray(samples)
    if x.dtype == np.int16:
        return x.astype("<i2", copy=False)
    x = np.nan_to_num(x.astype(np.float32, copy=False), nan=0.0, posinf=1.0, neginf=-1.0)
    return np.clip(np.rint(x * 32768.0), -32768, 32767).astype("<i2")


_WRITE_BLOCK = 1 << 20      # samples converted per step: bounded temporary memory for hour-long tracks


def write_wav_int16(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    """Write mono 16-bit PCM. ``samples``: float array in [-1, 1] (clipped) or int16. The file appears atomically."""
    path = Path(path)
    x = np.asarray(samples)
    if x.ndim != 1:
        raise ValueError("write_wav_int16 expects a 1-D (mono) array")
    data_bytes = x.size * 2
    if data_bytes > _UINT32_MAX - 36:
        raise ValueError("audio too long for a RIFF/WAVE file")
    sample_rate = int(sample_rate)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_bytes, b"WAVE", b"fmt ", 16, _FMT_PCM, 1, sample_rate, sample_rate * 2, 2, 16, b"data", data_bytes,
    )
    tmp = path.with_name(path.name + ".tmp")
    try:
        with open(tmp, "wb") as f:
            f.write(header)
            for i in range(0, x.size, _WRITE_BLOCK):
                to_int16(x[i: i + _WRITE_BLOCK]).tofile(f)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
