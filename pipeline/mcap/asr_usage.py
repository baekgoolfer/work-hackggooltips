"""Content-free record of every external ASR request (SPEC 18).

``asr-usage.jsonl`` (SUPPORT_DIR, ``Config.asr_usage_path``): one JSON line per HTTP attempt of an external engine (``asr_http.HttpEngine``),
appended when the attempt has ended, whatever its outcome::

    {"ts":"2026-10-15T09:12:03+09:00","session_id":"2026-10-15_0900_zoom","engine":"remote","kind":"server","host":"asr.example.internal",
     "op":"chunk","status":200,"outcome":"ok","attempt":1,"circuit":"closed","requests":1,"audio_s":14.2,"bytes_out":454400,"bytes_in":812,
     "dur_ms":2310,"est_usd":null}

It is the ONE place that names the exact host (a transcript folder goes to a shared drive, so ``transcript.json`` only carries a label).
It never carries content: there is no free-text field. Every string is checked against a closed shape (``record`` keeps what matches and
replaces the rest by a fixed word), every number must be finite and non-negative, and the values come from the engine's own bookkeeping,
never from what a server said. The canary tests of tests/test_asr_usage.py put CR/LF, a token and a transcript sentence into every argument.

What counts toward the daily cap (``ASR_CLOUD_DAILY_MINUTES``): per line ``audio_s + requests x 1.0`` seconds, over today's
(local date) lines of the server and cloud engines. ``requests`` is 1 when the request body may have left this Mac and 0 when it cannot have
(denied before a socket, a connection or TLS handshake that failed): ``record`` zeroes ``requests``, ``audio_s`` and ``bytes_out`` for such an
attempt, so a host that is down does not use the cap up. The file is the user's: advisory (the user can delete it; the relay's per-token
quota is authoritative), safe to truncate, 0600, and a failed write is only logged (a usage record must never break a transcription).

Size: when the file reaches ``MAX_BYTES`` it is renamed to ``asr-usage.jsonl.1`` (older ones shift up to ``.3``, the oldest is dropped), under a
lock so two processes cannot rotate at once. Readers (``read_entries``, ``minutes_today``, ``summary``) look at all of them.

Nothing here opens a socket, starts a process or reads the Keychain.
"""
from __future__ import annotations

import fcntl
import json
import logging
import math
import numbers
import os
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterator, Optional

from . import usage as claude_usage

log = logging.getLogger("mcap.asr_usage")

USAGE_FILE = "asr-usage.jsonl"
MAX_BYTES = 5 * 1024 * 1024          # rotate at this size (about 17,000 lines)
KEEP = 3                              # rotated files kept: asr-usage.jsonl.1 ... .3
KINDS = ("server", "cloud")           # what the daily cap counts (a local engine sends nothing)
REQUEST_SECONDS = 1.0                 # SPEC 18: every request counts as one second more than its audio
SUMMARY_DAYS = 7
CIRCUITS = ("closed", "half-open", "open")

_WORD = re.compile(r"[a-z0-9][a-z0-9_.\-]{0,31}\Z")
_OUTCOME = re.compile(r"(ok|http_[0-9]{3}|(error|denied):[a-z0-9_]{1,24})\Z")
_HOST = re.compile(r"[a-z0-9]([a-z0-9_.\-]{0,251}[a-z0-9])?\Z")
_SESSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}\Z")

# Outcomes (besides ok and http_<status>) after which the request body may have reached the server: it answered and the answer was refused
# by rule, or the exchange broke off after the body had been written (a timeout, a torn answer).
_SENT_OUTCOMES = frozenset({"denied:redirect", "denied:response_too_large", "error:timeout", "error:protocol", "error:transport",
                            "error:aborted"})


def request_was_sent(status: Any, outcome: Any) -> bool:
    """May the body of this attempt have left the Mac? Yes for any answer (``ok``, ``http_<status>``, a 3xx or oversized answer that was
    refused) and for a timeout or torn exchange; no for a denial before the socket, a failed connection or TLS handshake, a malformed
    request. The one rule behind ``requests``, the daily cap and ``HttpEngine.usage()``."""
    text = outcome if isinstance(outcome, str) else ""
    if text == "ok" or text.startswith("http_") or text in _SENT_OUTCOMES:
        return True
    return isinstance(status, int) and not isinstance(status, bool) and 100 <= status <= 599


def usage_path(cfg) -> Path:
    path = getattr(cfg, "asr_usage_path", None)
    return Path(path) if path else Path(cfg.support_dir) / USAGE_FILE


# ---------------------------------------------------------------------------------- what may be written
def _word(value: Any, default: str) -> str:
    text = value.strip().lower() if isinstance(value, str) else ""
    return text if _WORD.fullmatch(text) else default


def _kind(value: Any) -> str:
    text = value.strip().lower() if isinstance(value, str) else ""
    return text if text in ("local", "server", "cloud") else "unknown"


def _outcome(value: Any) -> str:
    text = value.strip() if isinstance(value, str) else ""
    return text if _OUTCOME.fullmatch(text) else "error:other"


def _host(value: Any) -> str:
    text = value.strip().lower() if isinstance(value, str) else ""
    return text if _HOST.fullmatch(text) else ""


def _session(value: Any) -> Optional[str]:
    text = value.strip() if isinstance(value, str) else ""
    return text if _SESSION.fullmatch(text) else None


def _circuit(value: Any) -> str:
    text = value.strip().lower() if isinstance(value, str) else ""
    return text if text in CIRCUITS else "closed"


def _number(value: Any, *, integer: bool = False, ceiling: float = 1e12) -> float:
    """A finite, non-negative number (bool, NaN, infinity, negative or non-numeric input is 0), capped so a wild value cannot flood a total."""
    if isinstance(value, bool) or not isinstance(value, numbers.Real):          # numpy scalars are numbers.Real too
        return 0
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return 0
    if not math.isfinite(number) or number < 0:
        return 0
    number = min(number, ceiling)
    return int(number) if integer else number


def _entry(*, engine, kind, host, op, status, audio_s, bytes_out, bytes_in, dur_ms, outcome, attempt, est_usd, circuit, session_id) -> dict:
    clean_outcome = _outcome(outcome)
    code = int(_number(status, integer=True, ceiling=599))
    sent = request_was_sent(code, clean_outcome)
    price = None if est_usd is None else round(_number(est_usd, ceiling=1e9), 6)
    return {
        "ts": claude_usage.clock().isoformat(timespec="seconds"),
        "session_id": _session(session_id if session_id is not None else claude_usage.current_session_id()),
        "engine": _word(engine, "unknown"),
        "kind": _kind(kind),
        "host": _host(host),
        "op": _word(op, "unknown"),
        "status": code,
        "outcome": clean_outcome,
        "attempt": max(1, int(_number(attempt, integer=True, ceiling=99))),
        "circuit": _circuit(circuit),
        "requests": 1 if sent else 0,
        "audio_s": round(_number(audio_s, ceiling=86400.0 * 7), 2) if sent else 0.0,
        "bytes_out": int(_number(bytes_out, integer=True)) if sent else 0,
        "bytes_in": int(_number(bytes_in, integer=True)),
        "dur_ms": int(_number(dur_ms, integer=True, ceiling=86_400_000.0)),
        "est_usd": price if sent else None,
    }


# ---------------------------------------------------------------------------------- writing
def record(cfg, *, engine: str, kind: str, host: str, op: str, status: int, audio_s: float, bytes_out: int, bytes_in: int, dur_ms: int,
           outcome: str, attempt: int = 1, est_usd: Optional[float] = None, circuit: str = "closed",
           session_id: Optional[str] = None) -> None:
    """Append one line for one attempt. Never raises. ``outcome`` is ``ok``, ``http_<status>``, ``error:<code>`` or ``denied:<code>`` (the
    words of ``EgressGuard``); anything else is written as ``error:other``. ``audio_s`` is the audio the attempt carried (a chunk's seconds, the
    clips of a language-ID request, 0 for a health check). ``session_id`` defaults to the session of the running pipeline (``usage.meeting``).
    ``circuit`` is the state of the circuit breaker (closed | half-open | open) when the attempt started."""
    try:
        entry = _entry(engine=engine, kind=kind, host=host, op=op, status=status, audio_s=audio_s, bytes_out=bytes_out, bytes_in=bytes_in,
                       dur_ms=dur_ms, outcome=outcome, attempt=attempt, est_usd=est_usd, circuit=circuit, session_id=session_id)
        data = (json.dumps(entry, separators=(",", ":")) + "\n").encode("ascii")
        path = usage_path(cfg)
        path.parent.mkdir(parents=True, exist_ok=True)
        _rotate_if_full(path)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)       # one write(): lines of concurrent runs never mix
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except Exception as exc:                                                    # a usage line must never cost a transcript
        log.warning("cannot write the ASR usage record: %s", type(exc).__name__)


def _rotated(path: Path, n: int) -> Path:
    return path.with_name(f"{path.name}.{n}")


def _rotate_if_full(path: Path) -> None:
    try:
        if path.stat().st_size < MAX_BYTES:
            return
    except OSError:
        return
    lock = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if path.stat().st_size < MAX_BYTES:                                  # another process rotated while we waited
                return
        except OSError:
            return
        for n in range(KEEP, 1, -1):                                             # .2 -> .3, .1 -> .2 (the old .3 is replaced)
            if _rotated(path, n - 1).exists():
                os.replace(_rotated(path, n - 1), _rotated(path, n))
        os.replace(path, _rotated(path, 1))
    finally:
        os.close(lock)                                                           # releases the flock


# ---------------------------------------------------------------------------------- reading
def _aware(moment: datetime) -> datetime:
    return moment if moment.tzinfo else moment.astimezone()


def _parse_ts(value: Any) -> Optional[datetime]:
    try:
        return _aware(datetime.fromisoformat(str(value)))
    except ValueError:
        return None


def read_entries(cfg, since: Optional[datetime] = None) -> Iterator[tuple]:
    """``(entry, timestamp)`` of every well-formed line at or after ``since`` (oldest file first). Garbage lines and a missing file are
    ignored; a rotated file that was last written before ``since`` is not opened (the current file always is)."""
    path = usage_path(cfg)
    files = [_rotated(path, n) for n in range(KEEP, 0, -1)] + [path]
    for target in files:
        try:
            if target != path and since is not None and datetime.fromtimestamp(target.stat().st_mtime).astimezone() < since:
                continue                                                 # a rotated file nobody wrote to since: no line in it is recent
            data = target.read_bytes()
        except OSError:
            continue
        for raw in data.splitlines():
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            ts = _parse_ts(entry.get("ts")) if isinstance(entry, dict) else None
            if ts is not None and (since is None or ts >= since):
                yield entry, ts


def _seconds(entry: dict) -> float:
    """What a line counts toward the cap: its audio plus one second per request (an old line without ``requests`` is one request)."""
    requests = entry.get("requests", 1)
    return _number(entry.get("audio_s")) + (_number(requests) if isinstance(requests, (int, float)) else 1.0) * REQUEST_SECONDS


def minutes_today(cfg, kinds=KINDS, now: Optional[datetime] = None) -> float:
    """External audio of today (the local calendar date of ``now``, default ``usage.clock()``) in minutes: per line of an engine of one of
    ``kinds``, ``audio_s + requests x 1.0`` seconds. What ``ASR_CLOUD_DAILY_MINUTES`` and the policy cap are compared with."""
    now = _aware(now) if now is not None else claude_usage.clock()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    wanted = tuple(kinds)
    total = 0.0
    for entry, ts in read_entries(cfg, midnight):
        if entry.get("kind") in wanted and ts.astimezone(now.tzinfo).date() == now.date():
            total += _seconds(entry)
    return total / 60.0


def summary(cfg, days: int = SUMMARY_DAYS, now: Optional[datetime] = None) -> dict:
    """The last ``days`` days at a glance (``mcap usage``, doctor, status): attempts, requests that were sent, audio seconds, bytes, minutes
    as the cap counts them, failures (a sent request that did not end in ``ok``), denials, the estimated cost (None when no line has a price)
    and the same per engine. Content-free; no host."""
    now = _aware(now) if now is not None else claude_usage.clock()
    since = now - timedelta(days=max(1, int(days)))
    out: dict = {"days": max(1, int(days)), "since": since.isoformat(timespec="seconds"), "attempts": 0, "requests": 0, "audio_s": 0.0,
                 "bytes_out": 0, "bytes_in": 0, "minutes": 0.0, "failures": 0, "denied": 0, "est_usd": None, "last_ts": None,
                 "by_engine": {}}
    seconds = 0.0
    last: Optional[datetime] = None
    for entry, ts in read_entries(cfg, since):
        out["attempts"] += 1
        requests = int(_number(entry.get("requests", 1), integer=True))
        audio = _number(entry.get("audio_s"))
        outcome = entry.get("outcome") if isinstance(entry.get("outcome"), str) else ""
        failed = bool(requests) and outcome != "ok"
        out["requests"] += requests
        out["audio_s"] += audio
        out["bytes_out"] += int(_number(entry.get("bytes_out"), integer=True))
        out["bytes_in"] += int(_number(entry.get("bytes_in"), integer=True))
        out["failures"] += 1 if failed else 0
        out["denied"] += 1 if outcome.startswith("denied:") else 0
        seconds += _seconds(entry)
        price = entry.get("est_usd")
        if isinstance(price, (int, float)) and not isinstance(price, bool) and math.isfinite(price) and price >= 0:
            out["est_usd"] = (out["est_usd"] or 0.0) + float(price)
        engine = _word(entry.get("engine"), "unknown")
        per = out["by_engine"].setdefault(engine, {"requests": 0, "audio_s": 0.0, "failures": 0})
        per["requests"] += requests
        per["audio_s"] += audio
        per["failures"] += 1 if failed else 0
        if last is None or ts > last:
            last = ts
    out["audio_s"] = round(out["audio_s"], 2)
    out["minutes"] = round(seconds / 60.0, 2)
    if out["est_usd"] is not None:
        out["est_usd"] = round(out["est_usd"], 6)
    for per in out["by_engine"].values():
        per["audio_s"] = round(per["audio_s"], 2)
    out["last_ts"] = last.isoformat(timespec="seconds") if last else None
    return out
