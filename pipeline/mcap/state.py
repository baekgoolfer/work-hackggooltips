"""state.json (SPEC 4.3): written ONLY by the Python pipeline, atomically; the Swift app only reads it.

    {"schema":1, "stage":"transcribing", "stage_detail":"remote 12/48", "error":null, "updated":"...",
     "done":{"audio":true,"asr":false,"note":false,"publish":false}, "title":null, "final_dir":null,
     "discarded":false, "retryable":null, "resets_at":null, "warning":null, "error_kind":null}

`retryable`, `resets_at`, `warning`, `discarded`, `error_kind` are additive fields (SPEC 13.3). Readers must tolerate unknown keys.
`error_kind` is the machine-readable reason of a failure: audio_failed, asr_failed, archive_unavailable, publish_failed, or the
note failure kind (usage_limit, overage_guard, auth, billing_mode_violation, overloaded, timeout, ...; api mode, SPEC 17:
credit_exhausted, budget_daily, config). `budget_daily` and `credit_exhausted` are waiting states: `attempts` is not increased.

This module also hosts the small atomic-file helpers every other module uses (tmp file + fsync + rename), so a
crash or power loss can never leave a half-written transcript, note or state file behind.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any

from .apikey import redact_obj

log = logging.getLogger("mcap.state")

SCHEMA = 1
STATE_FILE = "state.json"
STAGES = ("queued", "audio", "transcribing", "noting", "publishing", "done", "failed")
DONE_KEYS = ("audio", "asr", "note", "publish")


def now_iso() -> str:
    """Local time with UTC offset, seconds precision (same style as session.json)."""
    return datetime.now().astimezone().isoformat(timespec="seconds")


# ---------------------------------------------------------------------------------- atomic files
def _fsync_dir(directory: Path) -> None:
    try:
        fd = os.open(str(directory), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Write `data` to `path` so readers see either the old or the new content, never a mix. Raises OSError on failure
    (the temp file is removed, an existing target is left untouched)."""
    path = Path(path)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    _fsync_dir(path.parent)


def atomic_write_text(path: Path, text: str) -> None:
    atomic_write_bytes(path, text.encode("utf-8"))


def atomic_write_json(path: Path, obj: Any) -> None:
    atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2) + "\n")


def read_json(path: Path) -> Any:
    """Parsed JSON or None when missing/unreadable/corrupt (never raises)."""
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------- state.json
def default_state() -> dict:
    return {
        "schema": SCHEMA,
        "stage": "queued",
        "stage_detail": None,
        "error": None,
        "error_kind": None,
        "retryable": None,
        "resets_at": None,
        "warning": None,
        "updated": now_iso(),
        "done": {k: False for k in DONE_KEYS},
        "title": None,
        "final_dir": None,
        "discarded": False,
    }


def state_path(session_dir: Path) -> Path:
    return Path(session_dir) / STATE_FILE


def read_state(session_dir: Path) -> dict:
    """Current state with every standard key present. A missing or corrupt file yields the default (queued) state."""
    state = default_state()
    raw = read_json(state_path(session_dir))
    if isinstance(raw, dict):
        for key, value in raw.items():
            if key == "done":
                if isinstance(value, dict):
                    state["done"].update({k: bool(v) for k, v in value.items()})
            else:
                state[key] = value
    return state


def write_state(session_dir: Path, **fields: Any) -> dict:
    """Merge `fields` into state.json and write it atomically. Returns the merged state.

    * `done` is merged key by key: write_state(d, done={"asr": True}).
    * Setting `stage` resets `stage_detail` (unless given) and, for any stage except "failed", also clears
      `error` / `error_kind` / `retryable` / `resets_at` (unless given), so a new run never shows an old failure.
    * Every string is masked by apikey.redact (error / warning / stage_detail can carry text of a failed claude call: an API key
      shape must never reach this file, SPEC 17).
    * Never raises: progress information must not be able to kill a pipeline run. A failed write is logged.
    """
    state = read_state(session_dir)
    done_update = fields.pop("done", None)
    if "stage" in fields:
        if fields["stage"] not in STAGES:
            log.warning("unknown stage %r written to state.json", fields["stage"])
        fields.setdefault("stage_detail", None)
        if fields["stage"] != "failed":
            fields.setdefault("error", None)
            fields.setdefault("error_kind", None)
            fields.setdefault("retryable", None)
            fields.setdefault("resets_at", None)
    state.update(fields)
    if done_update:
        state["done"].update({k: bool(v) for k, v in done_update.items()})
    state["updated"] = now_iso()
    state = redact_obj(state)
    try:
        atomic_write_json(state_path(session_dir), state)
    except OSError as exc:
        log.warning("cannot write %s: %s", state_path(session_dir), exc)
    return state


def remove_state(session_dir: Path) -> None:
    try:
        state_path(session_dir).unlink()
    except OSError:
        pass
