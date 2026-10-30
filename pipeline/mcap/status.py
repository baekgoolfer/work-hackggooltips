"""`mcap status`, `mcap sessions` and the content-free facts `mcap doctor` / `mcap asr-engines` print about this Mac
(SPEC 18).

``collect_status`` is the one function behind ``mcap status [--json]`` and ``mcap status --write PATH`` (the MDM extension attribute, run as
the console user by ``scripts/mdm/ea_status.sh``). Schema 1::

    {"schema":1, "generated":"<iso>", "pipeline_version":"0.2.0", "contract":{"required":"0.2.0"|null, "satisfied":true},
     "profile":"company"|"personal"|"none"|..., "policy":{"state":"absent|valid|invalid", "revision":12, "sha256_8":"ab12cd34", "locked_reason":null},
     "route":{"primary":"whisper", "fallback":null, "local_capable":true, "egress_allowed":false},
     "consent":{"remote":"ok|no-consent|consent-expired|consent-mismatch|consent-tampered|not-configured|bad-host", "azure":"..."},
     "local_only_default":false,
     "sessions":{"staging":0,"failed":0,"failed_retryable":0,"discarded":0,"last_done_age_h":1.5,"staging_gb":0.0,"oldest_failed_age_h":null},
     "errors_7d":0, "device":{"hw_arch":"arm64","macos":"15.1","ram_gb":32.0,"filevault":"on|off|unknown"}, "disk":{"free_gb":120.5},
     "checks":{"policy":"ok|warn|fail|n/a", "route":..., "consent":..., "local_asr":..., "filevault":..., "disk":..., "sessions":...},
     "asr_usage_7d":120, "llm_cost_7d_usd":1.25}                       <- the last two: see ``for_mdm``

Two keys exist only when ``config.env`` cannot be used (a bad value, an unreadable file): ``"config_error":"bad-value:<KEY>"|"unreadable"|
"invalid"`` (the key's NAME, never its value) and ``checks.config = "fail"``; every other part is then computed from the built-in defaults.
The feed is written all the same: a pipeline that cannot start must not leave the fleet a stale, healthy-looking file.

What is NOT in it, whatever happens (a canary test pins it): meeting titles, session ids, folder names, paths, host names, user names, e-mail
addresses, anything a transcript, a note or a calendar entry said. Only counts, ages, sizes, codes and versions. The MDM feed is device
health, not employee monitoring: ``asr_usage_7d`` (minutes, rounded to 30) and ``llm_cost_7d_usd`` are in the document of ``--write`` only
when ``STATUS_INCLUDE_USAGE=1`` (default 0); an interactive ``mcap status`` always shows them. The serialized document is at most 20 KB
(``fit``); every section is collected on its own, so a part that cannot be read is ``null`` / ``"unknown"`` and never an error.

The same facts are reused by ``mcap doctor`` and ``mcap asr-engines list|check`` (consent state, FileVault, the policy and its lane view),
so one definition of 'what is the consent of this engine' exists. Nothing here opens a socket, starts ``claude`` or reads a Keychain item;
the only processes are the read-only ``sysctl`` / ``ioreg`` of ``policy.probe_hardware`` and ``fdesetup status`` (both injectable).
"""
from __future__ import annotations

import json
import logging
import math
import os
import platform
import re
import shutil
import stat as statmod
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Optional

from . import __version__, asr_usage, pipeline, policy, publish, usage
from .state import atomic_write_text, read_json

log = logging.getLogger("mcap.status")

SCHEMA = 1
MAX_BYTES = 20 * 1024                       # the serialized document never exceeds this
CONTRACT_MIN_VERSION = "0.2.0"              # what the Swift launcher requires of a pipeline when a policy exists (PipelineContract.minVersion)
USAGE_ROUND_MINUTES = 30                    # asr_usage_7d is reported in steps of this many minutes
LOW_DISK_GB = 5.0                           # Swift Types.swift minFreeDiskGB: recording stops below it
STUCK_RETRYABLE_HOURS = 24.0                # a retryable failure older than this is a session nobody has finished
LOCAL_MONTHS = 2                            # months of the local archive that ``last_done_age_h`` looks at (cheap, no Drive access)
MAX_ENTRIES = 5000                          # directory entries looked at per scan
_STAMP = re.compile(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})")
_SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")
_SAFE_WORD = re.compile(r"[a-z0-9_]{1,32}\Z")
EXTERNAL_ENGINES = tuple(name for name, meta in policy.ENGINE_META.items() if meta["kind"] != "local" and meta["status"] == "ready")


def aware(moment: Optional[datetime] = None) -> datetime:
    """``moment`` (default: now) as a timezone-aware datetime."""
    moment = moment or usage.clock()
    return moment if moment.tzinfo else moment.astimezone()


# ---------------------------------------------------------------------------------------------- the policy and the consents
def load_policy(cfg) -> "policy.OrgPolicy":
    """The organisation policy as this process reads it (``cfg.policy_path``; never raises). One seam: doctor, status, asr-engines and
    sessions read the policy here, so a test replaces this one function."""
    return policy.load_org_policy(getattr(cfg, "policy_path", None), current_version=__version__)


def default_local_only(org, cfg) -> "policy.LocalOnly":
    """What a NEW meeting starts with (the default chain ``policy.local_only.default OR LOCAL_ONLY_DEFAULT``, true when the policy is locked
    or the flag is locked)."""
    return policy.effective_local_only(None, org, cfg)


def lane_view_local_only(org) -> "policy.LocalOnly":
    """The flag the ORGANISATION-level lane view uses (doctor, asr-engines): the per-meeting default is a default of a flag, not a rule, so
    only a lock closes the lanes here (a locked or invalid policy, ``local_only.locked``)."""
    if org.locked or (org.valid and org.local_only_locked):
        return policy.LocalOnly(True, "policy-lock")
    return policy.LocalOnly(False, "default")


def load_consent_set(cfg, now: Optional[datetime] = None, *, machine: Optional[str] = None, run=subprocess.run) -> "policy.ConsentSet":
    """The user's consents (never raises). ``machine`` is the machine id the entries are checked against (default: this Mac's)."""
    try:
        return policy.load_consents(cfg.consent_path, machine_id=machine if machine is not None else policy.machine_id(run=run), now=now)
    except Exception as exc:                                  # pragma: no cover - load_consents does not raise
        log.warning("consent file unreadable (%s): no consent", type(exc).__name__)
        return policy.ConsentSet()


def consent_state(cfg, engine: str, org, consents, now: Optional[datetime] = None) -> dict:
    """How the consent of ``engine`` stands: ``{"state": ..., "source": "org"|"user"|None, "id": ..., "expires": ..., "use": ...}``.

    state is ``ok`` (a consent covers this engine at its configured host, in the primary or the fallback role), or why not: ``not-configured``
    (ASR_REMOTE_URL / the Azure host is not set), ``bad-host``, ``no-consent``, ``consent-mismatch`` (something it was bound to changed:
    host, port, region, model, protocol, backend kind, machine, role), ``consent-expired``, ``consent-tampered``. The binding is the one of
    ``policy.consent_binding`` (single definition); a kind=server engine is covered by a policy org consent first."""
    binding, why = policy.consent_binding(cfg, engine)
    if binding is None:
        return {"state": why or "not-configured", "source": None, "id": None, "expires": None, "use": None}
    rank = {"no-consent": 0, "consent-mismatch": 1, "consent-expired": 2, "consent-tampered": 3}
    worst = "no-consent"
    for role in ("primary", "fallback"):
        entry, reason = consents.valid_for(engine, binding["host"], binding["port"], role, region=binding["region"], model=binding["model"],
                                           protocol=binding["protocol"], backend_kind=binding["backend_kind"], now=now, org=org)
        if entry is not None:
            return {"state": "ok", "source": "org" if isinstance(entry, policy.OrgConsent) else "user", "id": policy.consent_id(entry),
                    "expires": entry.expires, "use": entry.use}
        if rank.get(reason, 0) > rank[worst]:
            worst = reason
    return {"state": worst, "source": None, "id": None, "expires": None, "use": None}


# ---------------------------------------------------------------------------------------------- the device
def filevault_state(run=subprocess.run) -> str:
    """``on`` | ``off`` | ``unknown`` from ``fdesetup status`` (read-only, no root needed). Anything else it says (an encryption in progress,
    a failure, the tool missing) is unknown."""
    try:
        done = run(["/usr/bin/fdesetup", "status"], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        text = ((getattr(done, "stdout", "") or "") + " " + (getattr(done, "stderr", "") or "")).lower()
    except Exception:
        return "unknown"
    if "filevault is on" in text:
        return "on"
    if "filevault is off" in text:
        return "off"
    return "unknown"


def hardware_probe(cfg, *, run=subprocess.run, now: Optional[datetime] = None) -> "policy.HardwareProbe":
    """What this Mac can do for the local engine (``policy.probe_hardware``: static facts and the cached benchmark; nothing is measured here).
    One seam for status and doctor (a test replaces it). A failure is 'unknown', never an exception."""
    try:
        return policy.probe_hardware(cfg, run=run, now=now)
    except Exception as exc:
        log.debug("hardware probe failed (%s)", type(exc).__name__)
        return policy.HardwareProbe(arch=platform.machine() or "unknown", mem_gb=0.0, mlx_ok=None, model_present=None, rtf=None,
                                    probed_at=None, capable=None, reasons=("probe-failed",))


def backup_excluded(path, run=subprocess.run) -> Optional[bool]:
    """Is ``path`` excluded from Time Machine? ``tmutil isexcluded`` answers ``[Excluded] <path>`` / ``[Included] <path>``; None when it
    cannot be read (read-only call; the exclusion itself is set by ``publish.exclude_from_backup``)."""
    try:
        done = run([publish.TMUTIL, "isexcluded", str(path)], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        text = (getattr(done, "stdout", "") or "")
    except Exception:
        return None
    if "[Excluded]" in text:
        return True
    if "[Included]" in text:
        return False
    return None


def macos_version() -> str:
    return platform.mac_ver()[0] or "unknown"


def disk_free_gb(cfg, free: Optional[Callable[[Path], int]] = None) -> Optional[float]:
    """Free space (GB, one decimal) of the volume that holds SUPPORT_DIR (or its nearest existing parent)."""
    probe = Path(cfg.support_dir)
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        value = free(probe) if free is not None else shutil.disk_usage(probe).free
        return round(value / 1e9, 1)
    except OSError:
        return None


# ---------------------------------------------------------------------------------------------- sessions
def _age_hours(moment: Optional[datetime], now: datetime) -> Optional[float]:
    if moment is None:
        return None
    return round(max(0.0, (now - aware(moment)).total_seconds() / 3600.0), 1)


def _parse_iso(value: Any) -> Optional[datetime]:
    if not isinstance(value, str):
        return None
    try:
        return aware(datetime.fromisoformat(value))
    except ValueError:
        return None


def _stamp_time(name: str) -> Optional[datetime]:
    match = _STAMP.match(name)
    if not match:
        return None
    try:
        return aware(datetime(*(int(g) for g in match.groups())))
    except ValueError:
        return None


def _mtime(path: Path) -> Optional[datetime]:
    try:
        return aware(datetime.fromtimestamp(path.stat().st_mtime))
    except OSError:
        return None


def dir_bytes(path: Path, limit: int = MAX_ENTRIES * 10) -> int:
    """Bytes of the regular files under ``path`` (no symbolic link followed; at most ``limit`` entries are looked at)."""
    total, seen = 0, 0
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in files:
            seen += 1
            if seen > limit:
                return total
            try:
                info = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            if statmod.S_ISREG(info.st_mode):
                total += info.st_size
    return total


def _staging_entries(cfg) -> list[Path]:
    sessions = Path(cfg.sessions_dir)
    try:
        entries = sorted(sessions.iterdir())
    except OSError:
        return []
    return [e for e in entries[:MAX_ENTRIES] if not e.name.startswith("_") and e.is_dir() and not e.is_symlink()]


def list_sessions(cfg, now: Optional[datetime] = None) -> list[dict]:
    """The sessions in staging, newest first, as ``{id, stage, error_kind, retryable, age_h, size_mb}``. NO title (a session id is
    ``YYYY-MM-DD_HHMM_<platform>``; the archive folders carry the title in their name and are not listed). ``stage`` is ``recording`` for a
    session the app is still writing, the stage of state.json, or ``waiting`` when no state.json exists yet. A staging folder that only
    holds a state.json is the tombstone of a published meeting (``tombstone`` true, size 0)."""
    now = aware(now)
    rows = []
    for entry in _staging_entries(cfg):
        state = read_json(entry / "state.json")
        state = state if isinstance(state, dict) else {}
        has_session = (entry / "session.json").is_file()
        if has_session and pipeline.is_live_recording(entry):
            stage = "recording"
        else:
            stage = state.get("stage") if isinstance(state.get("stage"), str) and _SAFE_WORD.fullmatch(state["stage"]) else None
            stage = stage or ("waiting" if has_session else "unknown")
        kind = state.get("error_kind")
        started = _stamp_time(entry.name) or _mtime(entry / "state.json") or _mtime(entry)
        rows.append({"id": entry.name if _SAFE_ID.fullmatch(entry.name) else "?", "stage": stage,
                     "error_kind": kind if isinstance(kind, str) and _SAFE_WORD.fullmatch(kind) else None,
                     "retryable": state.get("retryable") if isinstance(state.get("retryable"), bool) else None,
                     "age_h": _age_hours(started, now), "size_mb": round(dir_bytes(entry) / 1e6, 1) if has_session else 0.0,
                     "tombstone": not has_session, "_sort": entry.name})
    rows.sort(key=lambda r: r["_sort"], reverse=True)
    for row in rows:
        del row["_sort"]
    return rows


def _last_done(cfg, now: datetime) -> Optional[datetime]:
    """When the last meeting finished: the newest ``stage == done`` state.json among the staging tombstones and the local archive's two
    newest months. The Drive archive is never looked at (it may be slow, offline or not allowed)."""
    best: Optional[datetime] = None

    def consider(path: Path) -> None:
        nonlocal best
        state = read_json(path)
        if isinstance(state, dict) and state.get("stage") == "done":
            moment = _parse_iso(state.get("updated")) or _mtime(path)
            if moment is not None and (best is None or moment > best):
                best = moment

    for entry in _staging_entries(cfg):
        consider(entry / "state.json")
    root = Path(getattr(cfg, "local_archive_root", "") or "")
    try:
        months = sorted((m for m in root.iterdir() if re.fullmatch(r"\d{4}-\d{2}", m.name) and m.is_dir() and not m.is_symlink()), reverse=True)
    except OSError:
        months = []
    for month in months[:LOCAL_MONTHS]:
        try:
            folders = sorted(month.iterdir())[:MAX_ENTRIES]
        except OSError:
            continue
        for folder in folders:
            if folder.is_dir() and not folder.is_symlink():
                consider(folder / "state.json")
    return best


def session_summary(cfg, now: Optional[datetime] = None) -> dict:
    """The ``sessions`` block: counts, an age and a size, nothing that names a session."""
    now = aware(now)
    staging = failed = retryable = 0
    size = 0
    oldest_failed: Optional[datetime] = None
    for entry in _staging_entries(cfg):
        if not (entry / "session.json").is_file():
            continue                                            # a tombstone of a published meeting is not a session in staging
        staging += 1
        size += dir_bytes(entry)
        state = read_json(entry / "state.json")
        if isinstance(state, dict) and state.get("stage") == "failed":
            failed += 1
            retryable += 1 if state.get("retryable") is True else 0
            moment = _parse_iso(state.get("updated")) or _mtime(entry / "state.json")
            if moment is not None and (oldest_failed is None or moment < oldest_failed):
                oldest_failed = moment
    try:
        discarded = sum(1 for e in Path(cfg.discarded_dir).iterdir())
    except OSError:
        discarded = 0
    return {"staging": staging, "failed": failed, "failed_retryable": retryable, "discarded": discarded,
            "last_done_age_h": _age_hours(_last_done(cfg, now), now), "staging_gb": round(size / 1e9, 2),
            "oldest_failed_age_h": _age_hours(oldest_failed, now)}


def failed_runs(cfg, now: Optional[datetime] = None, days: int = 7) -> int:
    """How many pipeline runs of the last ``days`` days ended with ``FAILED:`` (the last line of a pipeline log is always ``DONE: ...`` or
    ``FAILED: ...``, docs of cli.py): the logs are only counted, never quoted. 0 when there is no log directory."""
    since = aware(now) - timedelta(days=days)
    try:
        names = sorted(os.listdir(cfg.log_dir))
    except OSError:
        return 0
    count = 0
    for name in names[:MAX_ENTRIES]:
        if not (name.startswith("pipeline-") and name.endswith(".log")):
            continue
        path = Path(cfg.log_dir) / name
        try:
            info = os.lstat(path)
            if not statmod.S_ISREG(info.st_mode) or datetime.fromtimestamp(info.st_mtime).astimezone() < since:
                continue
            with open(path, "rb") as fh:
                fh.seek(max(0, info.st_size - 4096))
                tail = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        lines = [line for line in tail.splitlines() if line.strip()]
        if lines and lines[-1].startswith("FAILED:"):
            count += 1
    return count


# ---------------------------------------------------------------------------------------------- the document
def _short(text: Any, limit: int = 60) -> Optional[str]:
    """A lock reason as a short code line: letters, digits and a few punctuation marks only (no path can get through)."""
    if not isinstance(text, str) or not text:
        return None
    return re.sub(r"[^A-Za-z0-9 _:.,\-\[\]]", "?", text)[:limit]


def _safe(default: Any, fn: Callable[[], Any]) -> Any:
    try:
        return fn()
    except Exception as exc:
        log.debug("status part unavailable (%s)", type(exc).__name__)
        return default


def _required_version(org) -> Optional[str]:
    """The pipeline version the Swift launcher demands (PipelineContract.required without a session): none without a policy, else the larger of
    0.2.0 and the policy's min_pipeline_version."""
    if not org.present:
        return None
    wanted = org.min_pipeline_version
    try:
        if wanted and policy._version_less(policy.parse_version(CONTRACT_MIN_VERSION), policy.parse_version(wanted)):
            return wanted
    except ValueError:
        pass
    return CONTRACT_MIN_VERSION


def _level_for(*, bad: bool, severe: bool) -> str:
    return "ok" if not bad else ("fail" if severe else "warn")


def collect_status(cfg, *, now: Optional[datetime] = None, for_mdm: bool = False, org=None, consents=None, hw=None,
                   filevault: Optional[str] = None, run=subprocess.run, machine: Optional[str] = None,
                   disk_free: Optional[Callable[[Path], int]] = None, config_error: Optional[str] = None) -> dict:
    """The status document (schema 1, module docstring). ``for_mdm`` True is the ``--write`` form: ``asr_usage_7d`` and ``llm_cost_7d_usd``
    are included only when ``STATUS_INCLUDE_USAGE`` is on. ``config_error``: the code of a config.env that could not be used (``cfg`` is then
    the built-in defaults): it becomes ``config_error`` and ``checks.config = "fail"``. The keyword arguments after ``for_mdm`` are seams for
    tests (an already loaded policy / consents, a hardware verdict, the FileVault word, the process runner, the machine id, the disk probe); by
    default everything is read from this Mac. Never raises."""
    now = aware(now)
    org = org if org is not None else _safe(policy.absent_policy(), lambda: load_policy(cfg))
    consents = consents if consents is not None else load_consent_set(cfg, now, machine=machine, run=run)
    hw = hw if hw is not None else hardware_probe(cfg, run=run, now=now)
    vault = filevault if filevault is not None else filevault_state(run)
    lo = default_local_only(org, cfg)
    try:
        minutes = asr_usage.minutes_today(cfg, now=now)
    except Exception:
        minutes = 0.0
    decision = _safe(None, lambda: policy.decide_asr(cfg, org, lo, consents, hw, used_minutes_today=minutes, now=now))
    consent = {engine: consent_state(cfg, engine, org, consents, now)["state"] for engine in EXTERNAL_ENGINES}
    sessions = _safe({"staging": None, "failed": None, "failed_retryable": None, "discarded": None, "last_done_age_h": None,
                      "staging_gb": None, "oldest_failed_age_h": None}, lambda: session_summary(cfg, now))
    free = _safe(None, lambda: disk_free_gb(cfg, disk_free))
    required = _required_version(org)
    try:
        satisfied = required is None or not policy._version_less(policy.parse_version(__version__), policy.parse_version(required))
    except ValueError:
        satisfied = False
    capable = getattr(hw, "capable", None)
    locked_local = bool(org.valid and org.profile == policy.COMPANY and org.local_only_locked)
    named = {name for name in policy.requested_engines(cfg) if name in EXTERNAL_ENGINES}
    if policy.requested_engines(cfg)[0] == "auto":
        named.add("remote")
    stuck = (sessions.get("oldest_failed_age_h") or 0.0) > STUCK_RETRYABLE_HOURS and bool(sessions.get("failed_retryable"))
    checks = {
        "policy": "n/a" if not org.present else ("ok" if org.valid else "fail"),
        "route": "fail" if getattr(decision, "blocked", None) else "ok",
        "consent": "n/a" if not named else ("ok" if all(consent.get(e) == "ok" for e in named) else "warn"),
        "local_asr": "n/a" if capable is None else _level_for(bad=capable is False, severe=locked_local),
        "filevault": "n/a" if vault == "unknown" else _level_for(bad=vault == "off", severe=locked_local),
        "disk": "n/a" if free is None else ("fail" if free < 1.0 else ("warn" if free < LOW_DISK_GB else "ok")),
        "sessions": "warn" if stuck else "ok",
    }
    doc: dict = {
        "schema": SCHEMA,
        "generated": now.isoformat(timespec="seconds"),
        "pipeline_version": __version__,
        "contract": {"required": required, "satisfied": satisfied},
        "profile": org.profile,
        "policy": {"state": org.state, "revision": org.revision, "sha256_8": org.sha256_8, "locked_reason": _short(org.locked_reason)},
        "route": {"primary": getattr(decision, "primary", None), "fallback": getattr(decision, "fallback", None),
                  "local_capable": capable, "egress_allowed": bool(getattr(decision, "allow_egress", False))},
        "consent": consent,
        "local_only_default": bool(lo.value),
        "sessions": sessions,
        "errors_7d": _safe(None, lambda: failed_runs(cfg, now)),
        "device": {"hw_arch": getattr(hw, "arch", None), "macos": macos_version(), "ram_gb": getattr(hw, "mem_gb", None) or None,
                   "filevault": vault},
        "disk": {"free_gb": free},
        "checks": checks,
    }
    if config_error:
        checks["config"] = "fail"
        doc["config_error"] = _short(config_error, 80) or "invalid"
    if not for_mdm or bool(getattr(cfg, "status_include_usage", False)):
        doc["asr_usage_7d"] = _safe(None, lambda: usage_minutes_rounded(cfg, now))
        doc["llm_cost_7d_usd"] = _safe(None, lambda: round(float(usage.cost_windows(cfg, now)[7]["cost_usd"]), 2))
    return fit(doc)


def usage_minutes_rounded(cfg, now: datetime) -> int:
    """External audio of the last 7 days in minutes (as the daily cap counts it), rounded to ``USAGE_ROUND_MINUTES``."""
    minutes = float(asr_usage.summary(cfg, days=7, now=now)["minutes"])
    return int(math.floor(minutes / USAGE_ROUND_MINUTES + 0.5) * USAGE_ROUND_MINUTES)


def serialize(doc: dict) -> str:
    return json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def fit(doc: dict) -> dict:
    """``doc`` unchanged when its JSON is at most ``MAX_BYTES``; otherwise optional parts are dropped, least important first (the bound is a
    promise to the MDM feed, not a hope). The minimal document is always small."""
    if len(serialize(doc).encode("utf-8")) <= MAX_BYTES:
        return doc
    out = dict(doc)
    for key in ("checks", "consent", "sessions", "asr_usage_7d", "llm_cost_7d_usd", "device", "route", "policy"):
        out.pop(key, None)
        out["truncated"] = True
        if len(serialize(out).encode("utf-8")) <= MAX_BYTES:
            return out
    minimal = {"schema": SCHEMA, "pipeline_version": __version__, "truncated": True}
    if "config_error" in doc:                                  # the one fact the fleet must not lose
        minimal["config_error"] = doc["config_error"]
    return minimal


def write_status(path, doc: dict) -> int:
    """Atomically write the JSON of ``doc`` to ``path`` (readable by the MDM agent: 0644, the content is not secret). Returns the bytes
    written. Raises OSError."""
    text = serialize(doc) + "\n"
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(target, text)
    try:
        os.chmod(target, 0o644)
    except OSError:
        pass
    return len(text.encode("utf-8"))


def _fmt(value: Any, none: str = "-") -> str:
    if value is None:
        return none
    if isinstance(value, bool):
        return "yes" if value else "no"
    return str(value)


def render_text(doc: dict) -> list[str]:
    """The status document as lines for a terminal (the same facts as the JSON, nothing more)."""
    policy_doc, route, sessions = doc.get("policy") or {}, doc.get("route") or {}, doc.get("sessions") or {}
    device, contract = doc.get("device") or {}, doc.get("contract") or {}
    lines = [f"mcap status (schema {doc.get('schema')}, {doc.get('generated', '-')})",
             f"  pipeline:      {doc.get('pipeline_version')} (contract: required {_fmt(contract.get('required'), 'none')}, "
             f"satisfied {_fmt(contract.get('satisfied'))})",
             f"  profile:       {doc.get('profile')}   policy: {policy_doc.get('state')}"
             + (f" revision {policy_doc.get('revision')} sha256 {policy_doc.get('sha256_8')}" if policy_doc.get("revision") is not None else "")
             + (f" LOCKED ({policy_doc.get('locked_reason')})" if policy_doc.get("locked_reason") else ""),
             f"  route:         primary {_fmt(route.get('primary'))}, fallback {_fmt(route.get('fallback'), 'none')}, external audio allowed "
             f"{_fmt(route.get('egress_allowed'))}, local engine capable {_fmt(route.get('local_capable'), 'unknown')}",
             "  consent:       " + (", ".join(f"{e} {s}" for e, s in sorted((doc.get("consent") or {}).items())) or "-"),
             f"  local-only default for new meetings: {_fmt(doc.get('local_only_default'))}",
             f"  sessions:      {_fmt(sessions.get('staging'))} in staging, {_fmt(sessions.get('failed'))} failed "
             f"({_fmt(sessions.get('failed_retryable'))} retryable, oldest {_fmt(sessions.get('oldest_failed_age_h'))} h), "
             f"{_fmt(sessions.get('discarded'))} discarded, staging {_fmt(sessions.get('staging_gb'))} GB, last meeting finished "
             f"{_fmt(sessions.get('last_done_age_h'))} h ago",
             f"  failed runs in the last 7 days: {_fmt(doc.get('errors_7d'))}",
             f"  device:        {_fmt(device.get('hw_arch'))}, macOS {_fmt(device.get('macos'))}, {_fmt(device.get('ram_gb'))} GB RAM, FileVault "
             f"{_fmt(device.get('filevault'))}; free disk {_fmt((doc.get('disk') or {}).get('free_gb'))} GB",
             "  checks:        " + (", ".join(f"{k} {v}" for k, v in (doc.get("checks") or {}).items()) or "-")]
    if doc.get("config_error"):
        lines.insert(2, f"  config:        config.env CANNOT BE USED ({doc['config_error']}): the rest of this document comes from the built-in defaults")
    if "asr_usage_7d" in doc:
        lines.append(f"  usage (7 days): external ASR about {_fmt(doc.get('asr_usage_7d'))} min, Claude calls about "
                     f"${_fmt(doc.get('llm_cost_7d_usd'))}")
    if doc.get("truncated"):
        lines.append("  (some parts were left out to keep the document small)")
    return lines
