"""Extra-usage ("overage") guard marker (SPEC 13.3).

This Claude account has extra usage switched on, which would bill like pay-as-you-go once the subscription window is used up.
When `claude` reports `rate_limit_event.rate_limit_info.isUsingOverage == true` we write SUPPORT_DIR/overage.json. While
the marker is valid (until the reported reset time) and NOTE_STOP_ON_OVERAGE=1, the note stage does not call Claude at all
and the session ends as failed(retryable, "overage-guard") with the transcript intact. `mcap reprocess --allow-overage`
is the only way to force a note while the marker is valid.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from .config import Config
from .state import atomic_write_json, now_iso, read_json

log = logging.getLogger("mcap.overage")

DEFAULT_TTL_SECONDS = 5 * 3600     # used when Claude did not report a reset time (the 5-hour window)


def read_marker(cfg: Config, now: Optional[float] = None) -> Optional[dict]:
    """The marker if it is still valid, else None. An expired marker is deleted (best effort)."""
    path = Path(cfg.overage_path)
    data = read_json(path)
    if not isinstance(data, dict):
        return None
    now = time.time() if now is None else now
    try:
        expires = float(data.get("expires"))
    except (TypeError, ValueError):
        expires = 0.0
    if expires <= now:
        try:
            path.unlink()
        except OSError:
            pass
        return None
    return data


def write_marker(cfg: Config, resets_at: Optional[int] = None, rate_limit_type: Optional[str] = None,
                 source: str = "note", now: Optional[float] = None) -> dict:
    now = time.time() if now is None else now
    expires = float(resets_at) if resets_at and float(resets_at) > now else now + DEFAULT_TTL_SECONDS
    marker = {
        "schema": 1,
        "detected": now_iso(),
        "detected_epoch": int(now),
        "resets_at": int(resets_at) if resets_at else None,
        "expires": int(expires),
        "rate_limit_type": rate_limit_type,
        "source": source,
        "note": "Claude reported extra-usage (overage) billing. Notes are paused until 'expires' "
                "(set NOTE_STOP_ON_OVERAGE=0 or use 'mcap reprocess --allow-overage' to override; delete this file to clear).",
    }
    try:
        Path(cfg.overage_path).parent.mkdir(parents=True, exist_ok=True)
        atomic_write_json(Path(cfg.overage_path), marker)
    except OSError as exc:
        log.warning("cannot write overage marker %s: %s", cfg.overage_path, exc)
    return marker


def clear_marker(cfg: Config) -> None:
    try:
        Path(cfg.overage_path).unlink()
    except OSError:
        pass


def format_epoch(epoch: Optional[float]) -> str:
    """Local, human readable ('2026-10-07 18:00 KST')."""
    if not epoch:
        return "unknown"
    try:
        return datetime.fromtimestamp(float(epoch)).astimezone().strftime("%Y-%m-%d %H:%M %Z").strip()
    except (OverflowError, OSError, ValueError):
        return "unknown"


def describe(marker: dict) -> str:
    until = format_epoch(marker.get("expires"))
    return f"Claude reported extra-usage (overage) billing; notes are paused until {until} (NOTE_STOP_ON_OVERAGE=1)"
