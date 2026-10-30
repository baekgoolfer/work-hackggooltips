"""Organisation policy, per-meeting local-only flag, lane decisions, ASR consents, hardware probe and the ASR decision table
(SPEC 18).

Stdlib only. This module does not import ``config`` at module level (``config.load_config`` imports it lazily to layer the policy's
``defaults``/``enforced``; this module imports ``config`` lazily where it needs the config casters or the policy location, and
``asr_engines`` lazily for the pinned model revision of the hardware probe), and every function takes the config as a duck-typed object
read with ``getattr`` defaults, so a test double works.

Everything here is a decision: inputs in, verdict out. Only four things touch a file (``load_org_policy``, ``load_consents`` /
``write_consent`` / ``revoke_consent``, ``probe_hardware``). Nothing here opens a socket, starts ``claude`` or reads the Keychain.
Every loader answers a missing, damaged or odd input with the CLOSED reading of SPEC 18 and never raises: a policy that cannot be
trusted closes every external lane (``OrgPolicy.locked``), a consent that cannot be trusted excludes that engine, a flag that cannot be
read is ``local_only``. Closing is never a lost meeting: the local Whisper path stays open.

Rules worth knowing before changing anything
  * One flag, five lanes: ``local_only`` closes asr_remote, asr_cloud, llm, calendar and drive together (2.2). No partial value.
  * The policy only restricts. ``lane_decisions`` is NOT local_only AND policy allow AND approval AND user setting AND lane condition.
  * Unknown policy keys lock (3.2): a typo that silently drops a restriction is worse than a visible lock. ``ext`` is the one free area.
    company: omitted lanes deny, omitted allowed_engines / allowed_hosts / archive.allowed_roots are EMPTY lists, allow needs an approval.
  * Local Whisper is never excluded by the policy lists (they restrict external engines): closing a lane always has a local way out.
  * A lock also keeps the company baseline of ``enforced`` (unless the file positively says personal): damaged input must not loosen the
    privacy settings. A path template of the policy (``archive.allowed_roots`` / ``local_roots``) must be anchored (``anchored_path``), and a
    version or date is ASCII digits only: both parsers must read the same text the same way (the corpus pins it).
  * Reason codes are short ASCII words (docs/PRIVACY_LANES.md 9); ``OrgPolicy.locked_reason`` is ``code`` or ``code: detail`` and the
    Swift parser must produce the same ``code`` (``config/policy-fixtures/index.json`` is the shared proof).
  * A ``blocked`` ASR decision (error_kind asr_policy_blocked) carries no fallback and no egress; ``ASR_ENGINE=whisper`` is never blocked.

What the packages after this one take from here
  * ``consent_binding(cfg, engine)``: the single definition of what a consent binds (host, port, region, model, protocol, backend kind).
    The TTY consent command writes entries from it, ``decide_asr`` and the engines compare against it.
  * ``AsrDecision``: ``hosts`` (host -> HostRule), ``engine_hosts`` (engine -> host), ``consent_ids`` (engine -> id), ``is_issued()``.
  * ``LaneDecision.block()`` -> ``LaneBlock`` for the gate; ``read_session_local_only`` + ``effective_local_only`` for the flag.
  * ``PROBE_BENCH_ARGV``: ``probe_hardware(measure=True)`` runs ``<python> -m mcap asr-engines bench-synth --seconds 20 --json`` and expects a
    JSON line with ``rtf`` (the CLI owner implements that sub-command; the unit tests fake ``run``).
"""
from __future__ import annotations

import hashlib
import hmac
import importlib.metadata
import importlib.util
import ipaddress
import json
import logging
import math
import os
import platform
import re
import stat as statmod
import subprocess
import tempfile
import time
import unicodedata
import uuid
from dataclasses import dataclass, field, replace
from datetime import date, datetime, time as dtime, timedelta
from pathlib import Path
from typing import Any, Callable, Mapping, Optional
from urllib.parse import urlsplit

from . import asr_providers                                      # stdlib only and imports nothing of this package: the registry of the cloud providers

log = logging.getLogger("mcap.policy")

LANES = ("asr_remote", "asr_cloud", "llm", "calendar", "drive")
APPROVAL_LANES = ("llm", "asr_cloud", "calendar", "drive")     # asr_remote has no approval reference
COMPANY, PERSONAL = "company", "personal"
PROFILES = (COMPANY, PERSONAL)
NO_POLICY_PROFILE = "none"                                      # OrgPolicy.profile when there is no policy at all
POLICY_SCHEMA = 1
MAX_POLICY_BYTES = 256 * 1024
REREAD_DELAY_S = 0.5                                             # one more read before an invalid verdict (MDM writes)
COMPANY_BASELINE_ENFORCED = {"LOG_CONTENT": "0", "ASR_ALLOW_DOWNLOAD": "0", "MIC_MUTE_GATE": "on", "NOTIFY_RECORDING": "1"}
CHILD_ENV_ALLOWED = ("DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
AZURE_HOST_SUFFIXES = (".api.cognitive.microsoft.com", ".cognitiveservices.azure.com")
SYSTEM_SYMLINKS = ("var", "tmp", "etc")                          # macOS firmlinks to /private/*: not a symlink an attacker can make

# kind / residency are the single truth for the policy; asr_engines.REGISTRY has the same keys (a test pins it).
# residency: device (this Mac) | a country code | foreign (processed outside the home jurisdiction: needs asr.allow_foreign).
ENGINE_META: dict[str, dict] = {
    "whisper": {"kind": "local", "residency": "device", "status": "ready", "lane": None, "protocol": "", "backend_kind": "", "model": ""},
    "qwen3-asr": {"kind": "local", "residency": "device", "status": "bench_only", "lane": None, "protocol": "", "backend_kind": "", "model": ""},
    "remote": {"kind": "server", "residency": "kr", "status": "ready", "lane": "asr_remote", "protocol": "mcap-asr/1",
               "backend_kind": "server", "model": ""},
    "azure": {"kind": "cloud", "residency": "kr", "status": "ready", "lane": "asr_cloud", "protocol": "azure-fast-transcription",
              "backend_kind": "cloud", "model": "fast-transcription"},
    "google": {"kind": "cloud", "residency": "foreign", "status": "stub", "lane": "asr_cloud", "protocol": "", "backend_kind": "cloud",
               "model": ""},
    # The providers of asr_providers.PROVIDERS (a vendor is one adapter class plus one entry there and one here). A block engine uploads up to
    # ASR_CLOUD_BLOCK_SECONDS of audio per request and gets the answer of a sync call: ``max_request_bytes`` / ``max_response_bytes`` replace the
    # HostRule defaults (2.5 MB / 256 KB, sized for 28 s chunks) of the one host this engine may talk to.
    "clova": {"kind": "cloud", "residency": "kr", "status": "ready", "lane": "asr_cloud", "protocol": "clova-speech-upload",
              "backend_kind": "cloud", "model": "clova-speech-long", "max_request_bytes": 64 << 20, "max_response_bytes": 16 << 20},
    "openai-compat": {"kind": "cloud", "residency": "foreign", "status": "ready", "lane": "asr_cloud", "protocol": "openai-audio-transcriptions",
                      "backend_kind": "cloud", "model": "", "destination": "destination chosen by the user",
                      "max_request_bytes": 64 << 20, "max_response_bytes": 16 << 20},
}
ASR_ENGINE_CHOICES = ("whisper", "remote", "azure", *asr_providers.PROVIDERS, "auto")      # values of ASR_ENGINE (config.py normalises anything else to whisper)
ASR_FALLBACK_CHOICES = ("none", "whisper", "remote", "azure", *asr_providers.PROVIDERS)


# ======================================================================================================================
# closed schema of policy.json
# ======================================================================================================================
class _Free:
    """Schema marker: any JSON value (the ``ext`` object)."""


class _Names(frozenset):
    """Schema marker: an object whose keys must be in this set (the defaults/enforced maps, llm.child_env)."""


FREE = _Free()

# Keys a config.env-style layer (defaults / enforced) may carry: behavioural settings only.
DEFAULTS_WHITELIST = frozenset("""
ASR_MODEL ASR_LANGUAGE ASR_LANGUAGES ASR_VAD ASR_ENGINE ASR_FALLBACK ASR_LOCAL_MIN_RAM_GB ASR_LOCAL_MAX_RTF ASR_REMOTE_URL
ASR_REMOTE_CA_FILE ASR_REMOTE_MAX_WAIT_S ASR_AZURE_REGION ASR_AZURE_HOST ASR_AZURE_LOCALES ASR_AZURE_BIAS ASR_AZURE_USD_PER_HOUR
ASR_CLOUD_DAILY_MINUTES ASR_REQUEST_TIMEOUT_S ASR_RETRY_MAX ASR_CIRCUIT_FAILS ASR_CIRCUIT_COOLDOWN_S ASR_ALLOW_DOWNLOAD ASR_SEND_VOCAB
LOCAL_ONLY_DEFAULT AUDIO_RETENTION_DAYS LOCAL_ARCHIVE_RETENTION_DAYS STAGING_FAILED_RETENTION_DAYS LOG_CONTENT LOG_RETENTION_DAYS
APP_LOG_MAX_MB STATUS_INCLUDE_USAGE MIC_MUTE_GATE NOTIFY_RECORDING CLAUDE_AUTH CLAUDE_DAILY_BUDGET_USD CLAUDE_MEETING_BUDGET_USD
MAX_CLAUDE_CALLS_PER_MEETING NOTE_MODEL NOTE_FALLBACK_MODEL NOTE_EFFORT NOTE_LANGUAGE NOTE_TIMEOUT_SECONDS NOTE_STOP_ON_OVERAGE
TRANSCRIPT_CLEANUP NOTE_VERIFY CALENDAR_LOOKUP MIC_AEC ENABLED_PLATFORMS BROWSER_BUNDLE_IDS POLL_INTERVAL_SECONDS START_DEBOUNCE_SECONDS
GRACE_SECONDS MIN_RECORDING_SECONDS MAX_RECORDING_HOURS MIN_FREE_DISK_GB NO_SPEECH_STOP_MINUTES RETRY_SWEEP_HOURS SYSTEM_AUDIO_MODE
ZOOM_STRONG_SOCKETS ZOOM_WEAK_DEBOUNCE_SECONDS CALL_DETECT CALL_GENERIC_SECONDS EXTRA_MEETING_APPS CALL_BROWSER_URLS
""".split())
# Never settable through ANY policy layer (shared contract files and the personal install: SPEC 18 and docs/POLICY.md 9).
FORBIDDEN_LAYER_KEYS = frozenset(["ARCHIVE_DIR", "PROJECT_DIR", "PYTHON_BIN", "CLAUDE_BIN", "SUPPORT_DIR", "SELF_NAME", "LOCAL_ARCHIVE_DIR"])

ORG_CONSENT_KEYS = {"engine": None, "host": None, "port": None, "protocol": None, "backend_kind": None, "ca_sha256": None,
                    "attest_build_sha256": None, "use": None, "expires": None}
POLICY_KEYS: dict = {
    "schema": None, "profile": None, "revision": None, "issued": None, "min_pipeline_version": None,
    "support": {"contact": None},
    "lanes": {lane: None for lane in LANES},
    "approvals": {lane: None for lane in APPROVAL_LANES},
    "local_only": {"default": None, "locked": None},
    "recording": {"enabled": None},
    "asr": {"allowed_engines": None, "allowed_hosts": None, "allow_foreign": None, "daily_audio_minutes_cap": None,
            "send_vocab": {"server": None, "cloud": None}, "org_consents": [ORG_CONSENT_KEYS]},
    "archive": {"allowed_roots": None, "local_roots": None},
    "llm": {"claude_bin_pin": {"team_id": None, "sha256": None}, "child_env": _Names(CHILD_ENV_ALLOWED)},
    "runtime": {"root": None},
    "defaults": _Names(DEFAULTS_WHITELIST),
    "enforced": _Names(DEFAULTS_WHITELIST),
    "ext": FREE,
}


class _Invalid(Exception):
    """A reason to lock: ``code`` is the stable word, ``detail`` where it happened (a key path; never policy values)."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(code, detail)
        self.code, self.detail = code, detail

    @property
    def reason(self) -> str:
        return (f"{self.code}: {self.detail}" if self.detail else self.code)[:80]


def _scan_keys(obj: Any, schema: Any, path: str) -> None:
    """Closed-schema pass: an unknown key anywhere (outside ``ext``) or a wrong container type is an immediate lock."""
    if schema is None or isinstance(schema, _Free):
        return
    if isinstance(schema, list):                          # a list of closed objects (asr.org_consents)
        if not isinstance(obj, list):
            raise _Invalid("bad-type", path)
        for i, item in enumerate(obj):
            _scan_keys(item, schema[0], f"{path}[{i}]")
        return
    if not isinstance(obj, dict):
        raise _Invalid("bad-type", path)
    for key, value in obj.items():
        here = f"{path}.{key}" if path else str(key)
        if isinstance(schema, _Names):
            if key in FORBIDDEN_LAYER_KEYS:
                raise _Invalid("forbidden-key", here)
            if key not in schema:
                raise _Invalid("unknown-key", here)
            continue
        if key not in schema:
            raise _Invalid("unknown-key", here)
        _scan_keys(value, schema[key], here)


# ---- typed readers (bool is not an int; null is not "absent" except inside ext) ------------------------------------------
def _is_int(value: Any) -> bool:
    return type(value) is int


def _get_bool(obj: dict, key: str, default: bool, path: str) -> bool:
    if key not in obj:
        return default
    if type(obj[key]) is not bool:
        raise _Invalid("bad-type", f"{path}{key}")
    return obj[key]


def _get_int(obj: dict, key: str, path: str, *, minimum: int, maximum: Optional[int] = None) -> Optional[int]:
    if key not in obj:
        return None
    value = obj[key]
    if not _is_int(value):
        raise _Invalid("bad-type", f"{path}{key}")
    if value < minimum or (maximum is not None and value > maximum):
        raise _Invalid("bad-value", f"{path}{key}")
    return value


def _clean_str(value: Any, path: str, *, max_len: int, single_line: bool = True) -> str:
    if not isinstance(value, str):
        raise _Invalid("bad-type", path)
    if len(value) > max_len or "\x00" in value or (single_line and any(ord(ch) < 32 or ord(ch) == 127 for ch in value)):
        raise _Invalid("bad-value", path)
    return value


def _get_str_list(obj: dict, key: str, path: str, *, lower: bool = False, max_items: int = 256, max_len: int = 1024) -> Optional[tuple]:
    if key not in obj:
        return None
    value = obj[key]
    if not isinstance(value, list) or len(value) > max_items:
        raise _Invalid("bad-type", f"{path}{key}")
    out = []
    for i, item in enumerate(value):
        text = _clean_str(item, f"{path}{key}[{i}]", max_len=max_len).strip()
        if not text:
            raise _Invalid("bad-value", f"{path}{key}[{i}]")
        out.append(text.lower() if lower else text)
    return tuple(out)


_HEX64 = re.compile(r"[0-9a-fA-F]{64}")
_TEAM_ID = re.compile(r"[A-Z0-9]{10}")
_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")                # ASCII digits only: ``\d`` also matches fullwidth / Arabic-Indic digits
_VERSION = re.compile(r"[0-9]{1,6}(\.[0-9]{1,6}){0,3}")


def parse_version(text: str) -> tuple[int, ...]:
    """'0.10.0' -> (0, 10, 0): ASCII digits and dots only (a fullwidth or Arabic-Indic digit is not a digit here: the Swift parser would not
    read it), compared as a tuple of ints ('0.10.0' > '0.2.0'); surrounding ASCII spaces are trimmed, any other character (a no-break space
    included) is not; ValueError for anything else."""
    if not isinstance(text, str) or not _VERSION.fullmatch(text.strip(" ")):
        raise ValueError(f"not a version: {str(text)[:30]!r}")
    return tuple(int(part) for part in text.strip(" ").split("."))


def _version_less(a: tuple, b: tuple) -> bool:
    """a < b with the shorter tuple padded by zeros ((0, 2) == (0, 2, 0))."""
    width = max(len(a), len(b))
    return tuple(a) + (0,) * (width - len(a)) < tuple(b) + (0,) * (width - len(b))


# ======================================================================================================================
# the policy
# ======================================================================================================================
@dataclass(frozen=True)
class HostRule:
    """One destination an EgressGuard may talk to (defined here so policy.py does not depend on the egress module)."""
    host: str
    port: int = 443
    ca_pem_sha256: Optional[str] = None
    ca_file: Optional[str] = None
    cert_sha256: tuple = ()
    max_request_bytes: int = 2_500_000
    max_response_bytes: int = 262_144


@dataclass(frozen=True)
class LaneBlock:
    """Why an external attempt must not start. ``kind`` is always "lane_denied" (a skip, not a failure)."""
    lane: str
    kind: str
    reason: str
    message: str


@dataclass(frozen=True)
class OrgConsent:
    """Organisation consent for a kind=server engine (policy ``asr.org_consents``); replaces the user's TTY consent for the relay.
    ``attest_build_sha256`` is the allow-list of server builds the client accepts from the health check: an EMPTY tuple allows no build
    (the policy parser accepts it so that the lock is visible at use, not at load)."""
    engine: str
    host: str
    port: int
    protocol: str
    backend_kind: str
    use: str
    expires: str
    ca_sha256: Optional[str]
    attest_build_sha256: tuple

    @property
    def id(self) -> str:
        """Derived (the policy carries no id): ``org:<engine>-<8 hex of its binding>``; shown in provenance and the usage record."""
        blob = "|".join((self.engine, self.host, str(self.port), self.protocol, self.backend_kind, self.ca_sha256 or ""))
        return f"org:{self.engine}-{hashlib.sha256(blob.encode()).hexdigest()[:8]}"


@dataclass(frozen=True)
class OrgPolicy:
    """The organisation policy as this process reads it. ``state`` is absent (no policy.json and no policy.required: personal install),
    valid, or invalid (``locked``: every external lane closed). For an absent policy nothing restricts; for an invalid one every lane is
    deny (``policy-locked``), the local_only default and lock are true (the app forces the flag) and recording stays enabled (a lock must
    not lose a meeting). A lock also keeps the company baseline in ``enforced`` unless the file positively says ``personal`` (the privacy
    settings of a managed Mac must not get looser because its policy file is damaged); it carries no ``defaults`` and none of the file's
    own ``enforced`` keys. ``lanes`` are EFFECTIVE verdicts (approvals and the signature pin already applied), ``lane_reasons`` the
    policy-level reason of each deny. The two allowed_* lists and archive_allowed_roots are None = no restriction, () = nothing allowed."""
    present: bool
    valid: bool
    locked_reason: Optional[str]
    profile: str
    revision: Optional[int]
    sha256_8: Optional[str]
    support_contact: Optional[str]
    min_pipeline_version: Optional[str]
    lanes: Mapping[str, str]
    lane_reasons: Mapping[str, str]
    allowed_engines: Optional[tuple]
    allowed_hosts: Optional[tuple]
    allow_foreign: bool
    daily_audio_minutes_cap: Optional[int]
    send_vocab: Mapping[str, bool]
    org_consents: tuple
    archive_allowed_roots: Optional[tuple]
    local_roots: tuple
    claude_bin_pin: Optional[Mapping]
    llm_child_env: Mapping[str, str]
    runtime_root: Optional[str]
    local_only_default: bool
    local_only_locked: bool
    recording_enabled: bool
    defaults: Mapping[str, str]
    enforced: Mapping[str, str]
    file_stamp: Optional[tuple]

    @property
    def locked(self) -> bool:
        """Present and not valid (a bad file, or policy.required without a policy.json): all external lanes closed."""
        return self.present and not self.valid

    @property
    def state(self) -> str:
        return "absent" if not self.present else ("valid" if self.valid else "invalid")


def absent_policy() -> OrgPolicy:
    """No policy.json and no policy.required: the personal install. Nothing restricts."""
    return OrgPolicy(
        present=False, valid=False, locked_reason=None, profile=NO_POLICY_PROFILE, revision=None, sha256_8=None, support_contact=None,
        min_pipeline_version=None, lanes={lane: "allow" for lane in LANES}, lane_reasons={}, allowed_engines=None, allowed_hosts=None,
        allow_foreign=True, daily_audio_minutes_cap=None, send_vocab={"server": True, "cloud": True}, org_consents=(),
        archive_allowed_roots=None, local_roots=(), claude_bin_pin=None, llm_child_env={}, runtime_root=None, local_only_default=False,
        local_only_locked=False, recording_enabled=True, defaults={}, enforced={}, file_stamp=None)


def _locked_policy(reason: str, *, profile: str = "unknown", revision: Optional[int] = None, sha256_8: Optional[str] = None,
                   contact: Optional[str] = None, min_version: Optional[str] = None, stamp: Optional[tuple] = None) -> OrgPolicy:
    """A policy that cannot be trusted. ``profile`` is what ``_lenient`` could read of the file ("unknown" when nothing): only a file that
    positively says personal is spared the company baseline (SPEC 18: damaged input reads as the closed value)."""
    return OrgPolicy(
        present=True, valid=False, locked_reason=reason, profile=profile, revision=revision, sha256_8=sha256_8, support_contact=contact,
        min_pipeline_version=min_version, lanes={lane: "deny" for lane in LANES}, lane_reasons={lane: "policy-locked" for lane in LANES},
        allowed_engines=(), allowed_hosts=(), allow_foreign=False, daily_audio_minutes_cap=None,
        send_vocab={"server": False, "cloud": False}, org_consents=(), archive_allowed_roots=(), local_roots=(), claude_bin_pin=None,
        llm_child_env={}, runtime_root=None, local_only_default=True, local_only_locked=True, recording_enabled=True, defaults={},
        enforced={} if profile == PERSONAL else dict(COMPANY_BASELINE_ENFORCED), file_stamp=stamp)


def _lenient(obj: Any) -> dict:
    """Facts worth showing next to a lock reason (profile, revision, contact, min version) from a policy that parsed but failed a rule."""
    out: dict = {}
    if not isinstance(obj, dict):
        return out
    if obj.get("profile") in PROFILES:
        out["profile"] = obj["profile"]
    if _is_int(obj.get("revision")) and obj["revision"] > 0:
        out["revision"] = obj["revision"]
    support = obj.get("support")
    if isinstance(support, dict) and isinstance(support.get("contact"), str):
        text = support["contact"]
        if 0 < len(text) <= 60 and not any(ord(ch) < 32 for ch in text):
            out["contact"] = text
    if isinstance(obj.get("min_pipeline_version"), str):
        out["min_version"] = obj["min_pipeline_version"][:20]
    return out


def _parse_json_strict(text: str) -> Any:
    """json.loads that rejects duplicate keys (at any depth) and NaN / Infinity / a number that overflows to infinity (1e999): all of them
    are unreadable in one parser and fine in another."""
    def pairs(items):
        seen = set()
        for key, _ in items:
            if key in seen:
                raise _Invalid("duplicate-key", str(key)[:30])
            seen.add(key)
        return dict(items)

    def constant(name):
        raise _Invalid("bad-json", "non-finite number")

    def real(literal):
        value = float(literal)
        if not math.isfinite(value):
            raise _Invalid("bad-json", "non-finite number")
        return value
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant, parse_float=real)


def _build_policy(obj: Any, *, sha8: str, stamp: Optional[tuple], current_version: Optional[str]) -> OrgPolicy:
    """The validated OrgPolicy of a parsed policy; raises _Invalid at the first rule it breaks."""
    if not isinstance(obj, dict):
        raise _Invalid("not-object")
    _scan_keys(obj, POLICY_KEYS, "")
    if "schema" not in obj or obj["schema"] != POLICY_SCHEMA or type(obj["schema"]) is not int:
        raise _Invalid("bad-schema")
    if "profile" not in obj:
        raise _Invalid("no-profile")
    if obj["profile"] not in PROFILES or not isinstance(obj["profile"], str):
        raise _Invalid("bad-profile")
    profile = obj["profile"]
    company = profile == COMPANY
    revision = obj.get("revision")
    if not _is_int(revision) or revision <= 0:
        raise _Invalid("bad-revision")
    if "issued" in obj:
        _clean_str(obj["issued"], "issued", max_len=64)
    min_version = None
    if "min_pipeline_version" in obj:
        min_version = _clean_str(obj["min_pipeline_version"], "min_pipeline_version", max_len=20).strip(" ")
        try:
            parse_version(min_version)
        except ValueError:
            raise _Invalid("bad-value", "min_pipeline_version")
    contact = None
    support = obj.get("support", {})
    if "contact" in support:
        contact = _clean_str(support["contact"], "support.contact", max_len=60)
        if not contact.strip():
            raise _Invalid("bad-value", "support.contact")

    # lanes: a value that is not exactly "allow" is deny for THAT lane (never a lock); a missing lane follows the profile
    lanes_raw = obj.get("lanes", {})
    approvals_raw = obj.get("approvals", {})
    approvals: dict[str, str] = {}
    for lane, ref in approvals_raw.items():
        if not isinstance(ref, str):
            raise _Invalid("bad-type", f"approvals.{lane}")
        if len(ref) > 80 or any(ord(ch) < 32 for ch in ref):
            raise _Invalid("bad-value", f"approvals.{lane}")
        if ref.strip():
            approvals[lane] = ref.strip()

    # llm
    llm = obj.get("llm", {})
    pin = None
    if "claude_bin_pin" in llm:
        raw = llm["claude_bin_pin"]
        if set(raw) == {"team_id"} and isinstance(raw["team_id"], str) and _TEAM_ID.fullmatch(raw["team_id"]):
            pin = {"team_id": raw["team_id"]}
        elif set(raw) == {"sha256"} and isinstance(raw["sha256"], str) and _HEX64.fullmatch(raw["sha256"]):
            pin = {"sha256": raw["sha256"].lower()}
        else:
            raise _Invalid("bad-value", "llm.claude_bin_pin")
    child_env: dict[str, str] = {}
    for name, value in llm.get("child_env", {}).items():
        child_env[name] = _clean_str(value, f"llm.child_env.{name}", max_len=64)

    effective: dict[str, str] = {}
    reasons: dict[str, str] = {}
    for lane in LANES:
        if lane not in lanes_raw:
            verdict = "deny" if company else "allow"
        else:
            verdict = "allow" if isinstance(lanes_raw[lane], str) and lanes_raw[lane] == "allow" else "deny"
        reason = None
        if verdict == "deny":
            reason = "policy-lane"
        elif company and lane in APPROVAL_LANES and lane not in approvals:
            verdict, reason = "deny", "policy-unapproved"
        elif company and lane == "llm" and pin is None:
            verdict, reason = "deny", "policy-claude-unpinned"
        effective[lane] = verdict
        if reason:
            reasons[lane] = reason

    local_only = obj.get("local_only", {})
    lo_default = _get_bool(local_only, "default", False, "local_only.")
    lo_locked = _get_bool(local_only, "locked", False, "local_only.")
    recording = _get_bool(obj.get("recording", {}), "enabled", True, "recording.")

    # asr
    asr = obj.get("asr", {})
    engines = _get_str_list(asr, "allowed_engines", "asr.", lower=True, max_len=40)
    hosts = _get_str_list(asr, "allowed_hosts", "asr.", lower=True, max_len=253)
    if hosts is not None and any(re.search(r"\s", h) for h in hosts):
        raise _Invalid("bad-value", "asr.allowed_hosts")
    allow_foreign = _get_bool(asr, "allow_foreign", False, "asr.")
    cap = _get_int(asr, "daily_audio_minutes_cap", "asr.", minimum=0, maximum=100_000)
    vocab_raw = asr.get("send_vocab", {})
    send_vocab = {"server": _get_bool(vocab_raw, "server", True, "asr.send_vocab."),
                  "cloud": _get_bool(vocab_raw, "cloud", not company, "asr.send_vocab.")}
    consents = []
    org_raw = asr.get("org_consents", [])
    if len(org_raw) > 50:
        raise _Invalid("bad-value", "asr.org_consents")
    for i, item in enumerate(org_raw):
        here = f"asr.org_consents[{i}]."
        for key in ("engine", "host", "protocol", "backend_kind", "ca_sha256", "attest_build_sha256", "use", "expires"):
            if key not in item:
                raise _Invalid("bad-value", here + key)
        engine = _clean_str(item["engine"], here + "engine", max_len=40).strip().lower()
        host = _clean_str(item["host"], here + "host", max_len=253).strip().lower()
        protocol = _clean_str(item["protocol"], here + "protocol", max_len=40)
        backend = _clean_str(item["backend_kind"], here + "backend_kind", max_len=20)
        port = _get_int(item, "port", here, minimum=1, maximum=65535) or 443
        ca = _clean_str(item["ca_sha256"], here + "ca_sha256", max_len=64)
        use = _clean_str(item["use"], here + "use", max_len=20)
        expires = _clean_str(item["expires"], here + "expires", max_len=10)
        builds_raw = item["attest_build_sha256"]
        if not isinstance(builds_raw, list) or len(builds_raw) > 64:
            raise _Invalid("bad-type", here + "attest_build_sha256")
        builds = tuple(_clean_str(b, here + "attest_build_sha256", max_len=64).lower() for b in builds_raw)
        if (not engine or not host or re.search(r"\s", host) or not _HEX64.fullmatch(ca) or any(not _HEX64.fullmatch(b) for b in builds)
                or use not in ("primary", "fallback", "both") or backend != "server"
                or not _DATE.fullmatch(expires) or _bad_date(expires)):
            raise _Invalid("bad-value", f"asr.org_consents[{i}]")
        consents.append(OrgConsent(engine=engine, host=host, port=port, protocol=protocol, backend_kind=backend, use=use,
                                   expires=expires, ca_sha256=ca.lower(), attest_build_sha256=builds))

    # archive and runtime
    archive = obj.get("archive", {})
    roots = _get_str_list(archive, "allowed_roots", "archive.")
    local_roots = _get_str_list(archive, "local_roots", "archive.") or ()
    for key, items in (("allowed_roots", roots), ("local_roots", local_roots)):
        for i, item in enumerate(items or ()):
            if not anchored_path(item):                 # 'Meetings', '*', '.', '~user/x': the verdict would depend on the process cwd
                raise _Invalid("bad-value", f"archive.{key}[{i}]")
    if roots is None and company:
        roots = ()
    if engines is None and company:
        engines = ()
    if hosts is None and company:
        hosts = ()
    runtime_root = None
    if "root" in obj.get("runtime", {}):
        root = _clean_str(obj["runtime"]["root"], "runtime.root", max_len=1024)
        if not root.startswith("/") or "/../" in root + "/" or root.endswith("/.."):
            raise _Invalid("bad-value", "runtime.root")
        runtime_root = root if company else None

    # defaults / enforced: whitelisted behavioural keys, string values that the config parser itself accepts
    layers = {}
    for name in ("defaults", "enforced"):
        layer: dict[str, str] = {}
        for key, value in obj.get(name, {}).items():
            text = _clean_str(value, f"{name}.{key}", max_len=500)
            if not text.strip():
                raise _Invalid("bad-value", f"{name}.{key}")
            _check_layer_value(key, text, f"{name}.{key}")
            layer[key] = text
        layers[name] = layer
    enforced = dict(COMPANY_BASELINE_ENFORCED) if company else {}
    enforced.update(layers["enforced"])

    # a pipeline older than the policy asks for reads it as locked: the policy may use keys it cannot know
    if min_version is not None:
        if current_version is None:
            from . import __version__ as current_version      # noqa: N813
        try:
            too_old = _version_less(parse_version(current_version), parse_version(min_version))
        except ValueError:
            too_old = True
        if too_old:
            raise _Invalid("pipeline-too-old", min_version)

    return OrgPolicy(
        present=True, valid=True, locked_reason=None, profile=profile, revision=revision, sha256_8=sha8, support_contact=contact,
        min_pipeline_version=min_version, lanes=effective, lane_reasons=reasons, allowed_engines=engines, allowed_hosts=hosts,
        allow_foreign=allow_foreign, daily_audio_minutes_cap=cap, send_vocab=send_vocab, org_consents=tuple(consents),
        archive_allowed_roots=roots, local_roots=tuple(local_roots), claude_bin_pin=pin, llm_child_env=child_env,
        runtime_root=runtime_root, local_only_default=lo_default, local_only_locked=lo_locked, recording_enabled=recording,
        defaults=layers["defaults"], enforced=enforced, file_stamp=stamp)


def _bad_date(text: str) -> bool:
    try:
        date.fromisoformat(text)
        return False
    except ValueError:
        return True


def _check_layer_value(key: str, text: str, path: str) -> None:
    """The config parser's own rules for this key: a number key needs a number. Switch and word keys never fail (unknown text reads as
    the restrictive / harmless value). Keys only the Swift app reads have no Python caster and are accepted as text."""
    from . import config
    entry = config._KEYS.get(key)
    if entry is None:
        return
    try:
        entry[1](text)
    except ValueError:
        raise _Invalid("bad-value", path)


def _lstat_exists(stat_fn: Callable, path: Path) -> Optional[Any]:
    """stat_fn(path), or None when it is not there. Any other failure raises OSError (the caller decides: it means 'cannot tell')."""
    try:
        return stat_fn(path)
    except (FileNotFoundError, NotADirectoryError):
        return None


def _evaluate(path: Path, marker: Path, stat_fn: Callable, current_version: Optional[str]) -> OrgPolicy:
    """One read of the policy: absent, valid or locked. Never raises."""
    try:
        marker_present = _lstat_exists(stat_fn, marker) is not None
    except OSError:
        marker_present = True                       # cannot tell: managed
    try:
        st = _lstat_exists(stat_fn, path)
    except OSError:
        return _locked_policy("unreadable: stat")
    if st is None:
        if marker_present:
            return _locked_policy("required-missing")
        return absent_policy()
    stamp = (getattr(st, "st_mtime_ns", 0), getattr(st, "st_ino", 0), getattr(st, "st_size", 0))
    mode = st.st_mode
    if statmod.S_ISLNK(mode) or not statmod.S_ISREG(mode):
        return _locked_policy("not-regular-file", stamp=stamp)
    if st.st_uid != 0:
        return _locked_policy("bad-owner", stamp=stamp)
    if mode & 0o022:
        return _locked_policy("group-or-other-writable", stamp=stamp)
    if st.st_size > MAX_POLICY_BYTES:
        return _locked_policy("too-large", stamp=stamp)
    for ancestor in path.parents:                   # nearest first; the chain ends at "/"
        try:
            pst = _lstat_exists(stat_fn, ancestor)
        except OSError:
            return _locked_policy("parent-unreadable", stamp=stamp)
        if pst is None or not statmod.S_ISDIR(pst.st_mode) and not statmod.S_ISLNK(pst.st_mode):
            return _locked_policy("parent-unreadable", stamp=stamp)
        if pst.st_uid != 0:
            return _locked_policy("parent-bad-owner", stamp=stamp)
        if pst.st_mode & 0o022:
            return _locked_policy("parent-writable", stamp=stamp)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            data = os.read(fd, MAX_POLICY_BYTES + 1)
            if len(data) <= MAX_POLICY_BYTES:
                while True:                          # os.read may return less than the file
                    more = os.read(fd, MAX_POLICY_BYTES + 1 - len(data))
                    if not more:
                        break
                    data += more
                    if len(data) > MAX_POLICY_BYTES:
                        break
        finally:
            os.close(fd)
    except OSError:
        return _locked_policy("unreadable: read", stamp=stamp)
    sha8 = hashlib.sha256(data).hexdigest()[:8]
    if len(data) > MAX_POLICY_BYTES:
        return _locked_policy("too-large", sha256_8=sha8, stamp=stamp)
    parsed: Any = None
    try:
        if data.startswith(b"\xef\xbb\xbf"):
            raise _Invalid("bom")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            raise _Invalid("not-utf8")
        try:
            parsed = _parse_json_strict(text)
        except (ValueError, RecursionError):
            raise _Invalid("bad-json")
        return _build_policy(parsed, sha8=sha8, stamp=stamp, current_version=current_version)
    except _Invalid as exc:
        return _locked_policy(exc.reason, sha256_8=sha8, stamp=stamp, **_lenient(parsed))
    except Exception as exc:                        # a bug here must close, not crash a recording's pipeline
        log.warning("policy evaluation failed (%s): treating the policy as locked", type(exc).__name__)
        return _locked_policy("internal-error", sha256_8=sha8, stamp=stamp)


def load_org_policy(path=None, *, required_marker=None, stat_fn=os.lstat, current_version=None, sleep=time.sleep) -> OrgPolicy:
    """Read the organisation policy. Never raises.

    ``path``: default the system policy (or the test override when no system policy exists, ``config.policy_path_override``). The marker
    ``policy.required`` is looked for next to it unless ``required_marker`` names another path: a marker without a policy file is a lock.
    ``stat_fn`` (lstat) serves the file, the marker and every ancestor directory, so a test can present any owner, mode or type without
    needing root; ``current_version`` is the pipeline version compared (as a tuple of ints) with ``min_pipeline_version``.

    Verdicts: no file and no marker -> absent (personal install); a valid file -> valid; anything else -> locked. A locked verdict is
    confirmed by one more read after 500 ms (``sleep``): MDM writes the file, and a half-written one must not lock the Mac for a run."""
    try:
        if path is None:
            from . import config
            path = config.policy_path_override() or config.POLICY_SYSTEM_PATH
        path = Path(path)
        marker = Path(required_marker) if required_marker is not None else path.parent / "policy.required"
        first = _evaluate(path, marker, stat_fn, current_version)
        if first.state != "invalid":
            return first
        sleep(REREAD_DELAY_S)
        return _evaluate(path, marker, stat_fn, current_version)
    except Exception as exc:                        # pragma: no cover - _evaluate does not raise; belt and braces
        log.warning("policy load failed (%s): treating the policy as locked", type(exc).__name__)
        return _locked_policy("internal-error")


# ======================================================================================================================
# archive roots
# ======================================================================================================================
def _fold(text: str) -> str:
    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", text).casefold())


def _components(path: str) -> list[str]:
    return [_fold(part) for part in path.split("/") if part]


def _component_matches(component: str, pattern: str) -> bool:
    """One path component against one pattern component: ``*`` matches any run of characters INSIDE the component, everything else is
    literal (fnmatch's ? and [...] are not wildcards here: the Swift matcher implements the same single rule)."""
    if "*" not in pattern:
        return component == pattern
    return re.fullmatch(".*".join(re.escape(piece) for piece in pattern.split("*")), component) is not None


def anchored_path(text: Any) -> bool:
    """Does this path (or archive root template) name its place without help from the working directory? ``/...``, ``~`` or ``~/...``.
    Anything else ('Meetings', '*', '.', '../x', ``~user/x``) is not: ``os.path.realpath`` would resolve it against whatever directory the
    process happens to run in (the app starts the pipeline in its own folder, a shell anywhere), and ``~user`` reads another account's
    home. The policy loader locks on such a root and the matchers below treat it as matching nothing. One rule, shared with Swift."""
    return isinstance(text, str) and (text == "~" or text.startswith(("/", "~/")))


def _real(path: Any) -> str:
    """realpath of an anchored ``~`` path; ValueError for a string the OS cannot take (a NUL byte), for one that is not anchored and for one
    that is still relative after the ``~`` is expanded (no usable $HOME)."""
    text = str(path)
    expanded = os.path.expanduser(text) if anchored_path(text) else ""
    if not expanded.startswith("/"):                  # also a ``~`` that stays unexpanded or a relative $HOME: realpath would use the cwd
        raise ValueError("path is relative to the working directory")
    return os.path.realpath(expanded)


def archive_root_matches(path, roots) -> bool:
    """Is ``path`` (realpath, NFC + casefold, component by component) inside one of the root templates? Each root is ``~``-expanded and
    realpath'ed, its components may hold ``*``; a root matches by PREFIX of whole components ('Meetings-evil' is not inside 'Meetings').
    ``roots`` None = no restriction (True); an empty collection matches nothing; a root with no component ('/' or '') never matches.
    A root or a path that is not anchored (``anchored_path``: relative, ``*``, ``~user``) matches nothing, whatever the working directory."""
    if roots is None:
        return True
    if not path or not str(path).strip():
        return False
    try:
        actual = _components(_real(path))
    except (ValueError, OSError):
        return False                                 # a path the OS cannot even resolve is not inside anything
    for root in roots:
        if not isinstance(root, str) or not root.strip():
            continue
        try:
            pattern = _components(_real(root))
        except (ValueError, OSError):
            continue
        if not pattern or len(pattern) > len(actual):
            continue
        if all(_component_matches(a, p) for a, p in zip(actual, pattern)):
            return True
    return False


def _nearest_existing(path: str) -> str:
    probe = path
    while probe and not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    return probe or "/"


def local_archive_ok(path, support_dir, extra_roots, *, home=None, stat_fn=os.stat) -> tuple[bool, str]:
    """Allow-list of LOCAL_ARCHIVE_DIR: realpath under SUPPORT_DIR or matching a policy ``archive.local_roots`` entry, no
    symlink in the path (realpath == abspath, except the macOS /var /tmp /etc firmlinks that every temp directory sits behind), and the
    same device (st_dev) as the home directory. Returns (ok, reason) with reason ok | empty-path | bad-path | symlink-in-path |
    outside-allowed-roots | different-device. A refusal is error_kind ``local_archive_unsafe``. A relative path or SUPPORT_DIR (not
    anchored: ``anchored_path``) is ``bad-path``: it would mean a different folder for every working directory."""
    if not path or not str(path).strip():
        return False, "empty-path"
    try:
        absolute = os.path.abspath(os.path.expanduser(str(path)))      # '..' collapsed lexically
        real = _real(path)                                              # '..' followed on disk: differs when a symlink sits before it
    except (ValueError, OSError):
        return False, "bad-path"
    head = absolute.lstrip("/").partition("/")[0]
    aliased = "/private/" + absolute.lstrip("/") if head in SYSTEM_SYMLINKS else absolute
    if real != absolute and real != aliased:
        return False, "symlink-in-path"
    inside = False
    if support_dir:
        try:
            base = _components(_real(support_dir))
        except (ValueError, OSError):
            return False, "bad-path"
        mine = _components(real)
        inside = bool(base) and mine[:len(base)] == base
    if not inside and extra_roots:
        inside = archive_root_matches(real, tuple(extra_roots))
    if not inside:
        return False, "outside-allowed-roots"
    try:
        home_dev = stat_fn(home if home is not None else os.path.expanduser("~")).st_dev
        if stat_fn(_nearest_existing(real)).st_dev != home_dev:
            return False, "different-device"
    except OSError:
        return False, "different-device"
    return True, "ok"


# ======================================================================================================================
# the per-meeting flag and the lanes
# ======================================================================================================================
@dataclass(frozen=True)
class LocalOnly:
    value: bool
    source: str        # session | default | policy-lock | fail-closed:bad-type | fail-closed:unreadable


class _Unreadable:
    """What ``read_session_local_only`` returns instead of a value when session.json cannot be read (never equal to any real value)."""
    __slots__ = ()

    def __repr__(self) -> str:
        return "UNREADABLE"


UNREADABLE = _Unreadable()


def read_session_local_only(session) -> tuple[object, str]:
    """The raw ``local_only`` of a session: ``session`` is the parsed session.json (a mapping), the path of the file or of its folder.
    Returns (raw, status): (value, "present") for any non-null value (whatever its type), (None, "absent") for a missing key or null,
    (UNREADABLE, "unreadable") when the file cannot be read, is not JSON or is not an object. Reads the file anew on every call."""
    if isinstance(session, Mapping):
        data: Any = session
    else:
        try:
            target = Path(session)
            if target.is_dir():
                target = target / "session.json"
            data = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError, RecursionError, TypeError):
            return UNREADABLE, "unreadable"
    if not isinstance(data, Mapping):
        return UNREADABLE, "unreadable"
    raw = data.get("local_only")
    if raw is None:
        return None, "absent"
    return raw, "present"


def effective_local_only(raw, policy: OrgPolicy, cfg) -> LocalOnly:
    """The meeting's flag, first match wins:
    a locked policy (invalid) or ``local_only.locked`` -> true (policy-lock, whatever the session says); an unreadable session -> true;
    no value (missing / null) -> the default chain ``policy.local_only.default OR LOCAL_ONLY_DEFAULT`` (default); a bool -> that bool
    (session); any other type ("false", 0, [], ...) -> true (fail-closed:bad-type)."""
    if policy is not None and (policy.locked or (policy.valid and policy.local_only_locked)):
        return LocalOnly(True, "policy-lock")
    if raw is UNREADABLE:
        return LocalOnly(True, "fail-closed:unreadable")
    if raw is None:
        configured = getattr(cfg, "local_only_default", False)
        chain = bool(policy is not None and policy.valid and policy.local_only_default) or configured is not False
        return LocalOnly(bool(chain), "default")
    if type(raw) is bool:
        return LocalOnly(raw, "session")
    return LocalOnly(True, "fail-closed:bad-type")


@dataclass(frozen=True)
class LaneDecision:
    lane: str
    allowed: bool
    reason: str        # ok|local_only|policy-lane|policy-unapproved|policy-locked|policy-archive-root|archive-not-configured|policy-claude-unpinned|user-disabled

    def block(self) -> Optional[LaneBlock]:
        """The LaneBlock of a denied lane (kind lane_denied), None when allowed."""
        if self.allowed:
            return None
        return LaneBlock(self.lane, "lane_denied", self.reason, f"lane '{self.lane}' is not allowed: {self.reason}")


def _norm_word(value: Any, allowed: tuple, fallback: str) -> str:
    text = value.strip().lower() if isinstance(value, str) else ""
    return text if text in allowed else fallback


def requested_engines(cfg) -> tuple[str, str]:
    """(ASR_ENGINE, ASR_FALLBACK) normalised like config.py does: an unknown word is whisper / none."""
    return (_norm_word(getattr(cfg, "asr_engine", "whisper"), ASR_ENGINE_CHOICES, "whisper"),
            _norm_word(getattr(cfg, "asr_fallback", "none"), ASR_FALLBACK_CHOICES, "none"))


def _calendar_enabled(cfg) -> bool:
    return str(getattr(cfg, "calendar_lookup", "auto")).strip().lower() not in ("0", "off", "false", "no", "none", "")


def _user_enabled(lane: str, cfg) -> bool:
    """Does the user's own configuration ask for this lane? llm and drive are always asked for: a note is always made and an
    archive always written; calendar follows CALENDAR_LOOKUP; an ASR lane follows ASR_ENGINE / ASR_FALLBACK naming an engine of that kind."""
    if lane == "calendar":
        return _calendar_enabled(cfg)
    if lane in ("asr_remote", "asr_cloud"):
        primary, fallback = requested_engines(cfg)
        named = {primary, fallback}
        if primary == "auto":
            named.add("remote")                     # auto can pick the company server (never a cloud engine)
        return any(ENGINE_META.get(name, {}).get("lane") == lane for name in named)
    return True


def lane_decisions(lo: LocalOnly, policy: OrgPolicy, cfg) -> dict[str, LaneDecision]:
    """The five lanes for one meeting. ``lane_allowed = NOT local_only AND policy allow AND approval AND user setting AND lane condition``;
    the reason is the FIRST failing term: policy-locked, local_only, the policy's own reason (policy-lane / policy-unapproved /
    policy-claude-unpinned), the lane condition (drive: archive-not-configured / policy-archive-root), user-disabled, else ok."""
    policy = policy if policy is not None else absent_policy()
    out: dict[str, LaneDecision] = {}
    for lane in LANES:
        reason = "ok"
        if policy.locked:
            reason = "policy-locked"
        elif lo.value:
            reason = "local_only"
        elif policy.lanes.get(lane, "deny") != "allow":
            reason = policy.lane_reasons.get(lane, "policy-lane")
        elif lane == "drive":
            explicit = "ARCHIVE_DIR" in getattr(cfg, "explicit_keys", frozenset())
            if policy.valid and policy.profile == COMPANY and not explicit:
                reason = "archive-not-configured"
            elif policy.archive_allowed_roots is not None and not archive_root_matches(getattr(cfg, "archive_dir", None),
                                                                                       policy.archive_allowed_roots):
                reason = "policy-archive-root"
        if reason == "ok" and not _user_enabled(lane, cfg):
            reason = "user-disabled"
        out[lane] = LaneDecision(lane, reason == "ok", reason)
    return out


# ======================================================================================================================
# consents (3.3 A3)
# ======================================================================================================================
CONSENT_SCHEMA = 1
CONSENT_USES = ("primary", "fallback", "both")
MAX_CONSENT_BYTES = 1024 * 1024


@dataclass(frozen=True)
class ConsentEntry:
    id: str
    engine: str
    kind: str
    host: str
    port: int
    region: str
    model: str
    protocol: str
    backend_kind: str
    use: str
    machine: str
    granted_at: str
    granted_by: str
    expires: str
    ca_sha256: Optional[str] = None
    cert_sha256: tuple = ()
    daily_minutes_cap: Optional[int] = None


def _aware(moment: Optional[datetime]) -> datetime:
    moment = moment or datetime.now()
    return moment if moment.tzinfo else moment.astimezone()


def _expiry(text: Any) -> Optional[datetime]:
    """The last instant a consent is valid: a date (YYYY-MM-DD) is valid through that whole day (local time), a datetime until then."""
    if not isinstance(text, str):
        return None
    try:
        if _DATE.fullmatch(text):
            return datetime.combine(date.fromisoformat(text), dtime(23, 59, 59, 999999)).astimezone()
        return _aware(datetime.fromisoformat(text))
    except ValueError:
        return None


def _is_expired(text: Any, now: datetime) -> bool:
    limit = _expiry(text)
    return limit is None or now > limit               # an expiry nobody can read is an expired consent


def _role_ok(use: str, role: str) -> bool:
    return use == "both" or use == role


@dataclass(frozen=True)
class ConsentSet:
    """The user's consents as read from asr-consent.json. ``tampered``: the file's integrity check failed (every entry is void, the
    entries stay visible for doctor); ``problem``: why the file is unusable or partly unusable (bad-json | bad-schema | integrity |
    integrity-missing | too-large | bad-entries:N), None when it is fine or simply absent. ``machine`` is the id the entries are checked
    against; ``loaded_at`` is the clock of the load (default ``now`` of valid_for)."""
    entries: tuple = ()
    tampered: bool = False
    problem: Optional[str] = None
    machine: str = ""
    loaded_at: Optional[datetime] = None

    def valid_for(self, engine, host, port, role, *, region="", model="", protocol="", backend_kind="", now=None,
                  org: Optional[OrgPolicy] = None) -> tuple[Optional[Any], str]:
        """The consent that lets ``engine`` talk to host:port in ``role`` (primary | fallback), and a reason code.
        (entry, "ok") or (None, no-consent | consent-mismatch | consent-expired | consent-tampered). A kind=server engine can be
        covered by a policy org consent (checked first, independent of the user's file); every other case needs a user entry that
        matches engine, host, port, region, model, protocol, backend kind, machine and role and has not expired."""
        moment = _aware(now or self.loaded_at)
        host = str(host or "").lower()
        kind = ENGINE_META.get(engine, {}).get("kind", "")
        rank = {"no-consent": 0, "consent-mismatch": 1, "consent-expired": 2}
        worst = "no-consent"

        def note(reason: str) -> None:
            nonlocal worst
            if rank[reason] > rank[worst]:
                worst = reason

        if kind == "server" and org is not None and org.valid:
            for oc in org.org_consents:
                if oc.engine != engine:
                    continue
                if (oc.host != host or oc.port != port or oc.protocol != protocol or oc.backend_kind != backend_kind
                        or not _role_ok(oc.use, role)):
                    note("consent-mismatch")
                elif _is_expired(oc.expires, moment):
                    note("consent-expired")
                else:
                    return oc, "ok"
        if self.tampered:
            return None, "consent-tampered"
        for entry in self.entries:
            if entry.engine != engine:
                continue
            if (entry.host.lower() != host or entry.port != port or entry.region != region or entry.model != model
                    or entry.protocol != protocol or entry.backend_kind != backend_kind or entry.machine != self.machine
                    or not _role_ok(entry.use, role)):
                note("consent-mismatch")
            elif _is_expired(entry.expires, moment):
                note("consent-expired")
            else:
                return entry, "ok"
        return None, worst


def consent_id(entry) -> str:
    """The id recorded in provenance and the usage record for a ConsentEntry or an OrgConsent."""
    return str(getattr(entry, "id", ""))


def _entry_from_dict(raw: Any) -> ConsentEntry:
    """A ConsentEntry from a file's dict, or ValueError: wrong types are dropped, never coerced."""
    if not isinstance(raw, dict):
        raise ValueError("entry")
    texts = ("id", "engine", "kind", "host", "region", "model", "protocol", "backend_kind", "use", "machine", "granted_at", "granted_by",
             "expires")
    values = {}
    for key in texts:
        if not isinstance(raw.get(key), str):
            raise ValueError(key)
        values[key] = raw[key]
    if not _is_int(raw.get("port")) or not 0 < raw["port"] < 65536:
        raise ValueError("port")
    if values["use"] not in CONSENT_USES or not values["engine"] or not values["host"] or _expiry(values["expires"]) is None:
        raise ValueError("value")
    ca = raw.get("ca_sha256")
    if ca is not None and not (isinstance(ca, str) and _HEX64.fullmatch(ca)):
        raise ValueError("ca_sha256")
    certs = raw.get("cert_sha256", [])
    if not isinstance(certs, list) or any(not (isinstance(c, str) and _HEX64.fullmatch(c)) for c in certs):
        raise ValueError("cert_sha256")
    cap = raw.get("daily_minutes_cap")
    if cap is not None and (not _is_int(cap) or cap < 0):
        raise ValueError("daily_minutes_cap")
    return ConsentEntry(port=raw["port"], ca_sha256=ca.lower() if ca else None, cert_sha256=tuple(c.lower() for c in certs),
                        daily_minutes_cap=cap, **values)


def _entry_to_dict(entry: ConsentEntry) -> dict:
    return {"id": entry.id, "engine": entry.engine, "kind": entry.kind, "host": entry.host, "port": entry.port, "region": entry.region,
            "model": entry.model, "protocol": entry.protocol, "backend_kind": entry.backend_kind, "use": entry.use,
            "machine": entry.machine, "granted_at": entry.granted_at, "granted_by": entry.granted_by, "expires": entry.expires,
            "ca_sha256": entry.ca_sha256, "cert_sha256": list(entry.cert_sha256), "daily_minutes_cap": entry.daily_minutes_cap}


def _integrity(raw_entries: list) -> str:
    """A checksum of the entries: it finds accidental damage and a hand edit; it is NOT a MAC (anyone who can write the
    file can recompute it). The organisation's control is the policy's allowed_hosts, not this."""
    blob = json.dumps(raw_entries, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return "sha256:" + hashlib.sha256(blob).hexdigest()


def load_consents(path, *, machine_id, now=None) -> ConsentSet:
    """Read asr-consent.json. Never raises. No file = no consents. Damage is answered with no consent: unreadable / bad JSON / wrong schema
    -> empty set with ``problem`` (doctor FAILs); integrity mismatch or missing -> ``tampered`` (every entry void); a malformed entry is
    dropped alone (``problem`` bad-entries:N)."""
    loaded_at = _aware(now)
    empty = {"machine": machine_id, "loaded_at": loaded_at}
    try:
        target = Path(path)
        if not target.exists():
            return ConsentSet(**empty)
        if target.stat().st_size > MAX_CONSENT_BYTES:
            return ConsentSet(problem="too-large", **empty)
        doc = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError, RecursionError):
        return ConsentSet(problem="bad-json", **empty)
    if not isinstance(doc, dict) or doc.get("schema") != CONSENT_SCHEMA or not isinstance(doc.get("entries"), list):
        return ConsentSet(problem="bad-schema", **empty)
    raw_entries = doc["entries"]
    entries, dropped = [], 0
    for raw in raw_entries:
        try:
            entries.append(_entry_from_dict(raw))
        except ValueError:
            dropped += 1
    stored = doc.get("integrity")
    if not isinstance(stored, str):
        return ConsentSet(entries=tuple(entries), tampered=True, problem="integrity-missing", **empty)
    if not hmac.compare_digest(stored.encode("utf-8", "replace"), _integrity(raw_entries).encode()):
        return ConsentSet(entries=tuple(entries), tampered=True, problem="integrity", **empty)
    return ConsentSet(entries=tuple(entries), problem=f"bad-entries:{dropped}" if dropped else None, **empty)


def _write_consent_file(path: Path, raw_entries: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {"schema": CONSENT_SCHEMA, "entries": raw_entries, "integrity": _integrity(raw_entries)}
    fd, tmp = tempfile.mkstemp(prefix=".asr-consent-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _existing_raw_entries(path: Path) -> list:
    """The entries of an existing consent file that a rewrite may keep: only those of a file whose integrity check passes. A missing,
    unreadable or tampered file contributes none, so rewriting a file never turns a hand-edited entry back into a valid one."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        entries, stored = doc["entries"], doc["integrity"]
        if not isinstance(entries, list) or not isinstance(stored, str):
            return []
        if not hmac.compare_digest(stored.encode("utf-8", "replace"), _integrity(entries).encode()):
            return []
        return [e for e in entries if isinstance(e, dict)]
    except (OSError, ValueError, UnicodeError, KeyError, TypeError, RecursionError):
        return []


def write_consent(path, entry: ConsentEntry, *, machine_id: str) -> None:
    """Record (or replace) the consent of ``entry.engine``, bound to this machine. Atomic (temp file + rename), mode 0600. The other engines'
    entries are kept only when the file's integrity check passes (a damaged or hand-edited file starts over with this one entry). Only the
    TTY command `mcap asr-engines consent` calls this."""
    target = Path(path)
    kept = [e for e in _existing_raw_entries(target) if e.get("engine") != entry.engine]
    kept.append(_entry_to_dict(replace(entry, machine=machine_id)))
    _write_consent_file(target, kept)


def revoke_consent(path, engine) -> int:
    """Remove the consent of ``engine`` (None or "all": every consent). Returns how many trusted entries were removed; 0 when there is no
    file. Revoking from a damaged or tampered file leaves it empty (nothing in it can be trusted)."""
    target = Path(path)
    if not target.exists():
        return 0
    existing = _existing_raw_entries(target)
    kept = [] if engine in (None, "all", "--all") else [e for e in existing if e.get("engine") != engine]
    removed = len(existing) - len(kept)
    _write_consent_file(target, kept)             # a tampered file is emptied: none of its entries can be trusted to stay
    return removed


_machine_cache: Optional[str] = None


def machine_id(*, run=subprocess.run) -> str:
    """A stable, non-reversible id of this Mac: sha256 of the hardware UUID (ioreg), or of the MAC address when ioreg is unavailable.
    Binds a consent to the Mac that gave it. The raw UUID is never stored."""
    global _machine_cache
    if run is subprocess.run and _machine_cache:
        return _machine_cache
    raw = ""
    try:
        done = run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, timeout=5)
        found = re.search(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"', getattr(done, "stdout", "") or "")
        raw = found.group(1).lower() if found else ""
    except Exception:
        raw = ""
    if not raw:
        raw = f"node-{uuid.getnode():012x}"
    digest = hashlib.sha256(("mcap-machine:" + raw).encode()).hexdigest()
    if run is subprocess.run:
        _machine_cache = digest
    return digest


# ======================================================================================================================
# hardware probe (SPEC 18 capability cache)
# ======================================================================================================================
CAPABILITY_MAX_AGE = timedelta(days=30)
PROBE_BENCH_ARGV = ("-m", "mcap", "asr-engines", "bench-synth", "--seconds", "20", "--json")   # contract with `mcap asr-engines` (W7a)
LIVE_WINDOW_SECONDS = 120.0                                       # same rule as pipeline.is_live_recording (SPEC 14.4)


class ProbeRefused(RuntimeError):
    """probe_hardware(measure=True) refuses while a recording is live: a 20 s benchmark would take the CPU from the capture."""


@dataclass(frozen=True)
class HardwareProbe:
    """What this Mac can do. ``capable``: True = the local engine fits (arm64, RAM, MLX, model, and the measured RTF when known),
    False = a definite 'no', None = not enough facts. mem_gb 0.0 = unknown. ``reasons`` are short codes (arch-not-arm64, ram-low,
    mlx-missing, model-missing, rtf-slow, ram-unknown, mlx-unknown, model-unknown, rtf-unmeasured, bench-failed)."""
    arch: str
    mem_gb: float
    mlx_ok: Optional[bool]
    model_present: Optional[bool]
    rtf: Optional[float]
    probed_at: Optional[str]
    capable: Optional[bool]
    reasons: tuple


def _module_present(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _mlx_version() -> Optional[str]:
    try:
        return importlib.metadata.version("mlx")
    except importlib.metadata.PackageNotFoundError:
        return None
    except Exception:
        return None


def _hub_cache() -> Path:
    for var in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        if os.environ.get(var):
            return Path(os.environ[var]).expanduser()
    home = os.environ.get("HF_HOME")
    return (Path(home).expanduser() / "hub") if home else Path.home() / ".cache" / "huggingface" / "hub"


_COMMIT_REF = re.compile(r"[0-9a-f]{7,64}")


def _weights_present(snapshot: Path) -> bool:
    """The engine's own completeness rule (asr_engines._whisper_files_present): config.json and weights.safetensors or weights.npz that
    EXIST. A name in a directory listing is not enough: a symlink into blobs/ whose blob is gone does not count."""
    return (snapshot / "config.json").exists() and ((snapshot / "weights.safetensors").exists() or (snapshot / "weights.npz").exists())


def _cached_snapshot(model: str) -> Optional[Path]:
    """The snapshot folder of the Hugging Face cache that ``asr_engines.resolve_model_path`` opens for ``model`` (local files only, no
    socket): ``snapshots/<pin>`` when REVISION_PINS pins the repo, otherwise the commit that ``refs/main`` names (what huggingface_hub's
    offline lookup does). Another snapshot in the same repo does not count: the engine never loads it. None when it is not there. Raises
    when the engine module cannot be imported (the caller reads that as unknown)."""
    from .asr_engines import REVISION_PINS
    repo = _hub_cache() / ("models--" + model.replace("/", "--"))
    commit = REVISION_PINS.get(model)
    if commit is None:
        try:
            commit = (repo / "refs" / "main").read_text(encoding="utf-8").strip()
        except (OSError, ValueError):
            return None
        if not _COMMIT_REF.fullmatch(commit):
            return None
    snapshot = repo / "snapshots" / commit
    return snapshot if snapshot.is_dir() else None


def _model_present(cfg) -> Optional[bool]:
    """Is the Whisper model the ENGINE would load on this disk? A local directory, or the cached snapshot of the pinned revision (see
    ``_cached_snapshot``) with a config and weights that exist. None when the name is neither a directory nor a repo id (or the engine
    module cannot be imported, so the pin is unknown): unknown."""
    model = str(getattr(cfg, "asr_model", "") or "").strip()
    if not model:
        return None
    try:
        local = Path(model).expanduser()
        if local.is_dir():
            return True
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", model):
            return None
        try:
            snapshot = _cached_snapshot(model)
        except ImportError:
            return None
        return snapshot is not None and _weights_present(snapshot)
    except (OSError, ValueError):
        return False


def _judge(cfg, arch: str, mem_gb: float, mlx_ok: Optional[bool], model_present: Optional[bool], rtf: Optional[float]):
    reasons: list[str] = []
    min_ram = float(getattr(cfg, "asr_local_min_ram_gb", 16))
    max_rtf = float(getattr(cfg, "asr_local_max_rtf", 0.25))
    failed, unknown = False, False
    if arch != "arm64":
        reasons.append("arch-not-arm64")
        failed = True
    if mem_gb <= 0:
        reasons.append("ram-unknown")
        unknown = True
    elif mem_gb < min_ram:
        reasons.append("ram-low")
        failed = True
    for name, value in (("mlx", mlx_ok), ("model", model_present)):
        if value is False:
            reasons.append(f"{name}-missing")
            failed = True
        elif value is None:
            reasons.append(f"{name}-unknown")
            unknown = True
    if rtf is not None and rtf > max_rtf:
        reasons.append("rtf-slow")
        failed = True
    elif rtf is None:
        reasons.append("rtf-unmeasured")
    return (False if failed else (None if unknown else True)), tuple(reasons)


def _read_capability_cache(cfg, machine: str, mlx_version: Optional[str], now: datetime) -> Optional[dict]:
    """The cached benchmark, or None when it is missing, corrupt, older than 30 days, from the future, or from another Mac / MLX build."""
    path = getattr(cfg, "capability_path", None)
    if not path:
        return None
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(doc, dict) or doc.get("schema") != 1:
            return None
        rtf = doc.get("rtf")
        if isinstance(rtf, bool) or not isinstance(rtf, (int, float)) or not math.isfinite(rtf) or rtf <= 0:
            return None
        probed = _aware(datetime.fromisoformat(doc["probed_at"]))
        if now - probed > CAPABILITY_MAX_AGE or probed - now > timedelta(days=1):
            return None
        if doc.get("machine") != machine or doc.get("mlx_version") != mlx_version:
            return None
        return {"rtf": float(rtf), "probed_at": doc["probed_at"]}
    except (OSError, ValueError, UnicodeError, KeyError, TypeError, RecursionError):
        return None


def _live_recording(cfg, now: datetime) -> bool:
    """Same rule as pipeline.is_live_recording: a session folder with no end_time and a WAV / session.json written within 120 s."""
    sessions = getattr(cfg, "sessions_dir", None)
    if not sessions:
        return False
    try:
        folders = [p for p in Path(sessions).iterdir() if p.is_dir() and not p.name.startswith("_")]
    except OSError:
        return False
    for folder in folders:
        try:
            session = json.loads((folder / "session.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError):
            continue
        if not isinstance(session, dict) or session.get("end_time"):
            continue
        newest = 0.0
        for entry in folder.iterdir():
            if entry.name == "session.json" or entry.name.lower().endswith(".wav"):
                try:
                    newest = max(newest, entry.stat().st_mtime)
                except OSError:
                    continue
        if newest > 0 and now.timestamp() - newest < LIVE_WINDOW_SECONDS:
            return True
    return False


def probe_hardware(cfg, *, run=subprocess.run, now=None, measure: bool = False) -> HardwareProbe:
    """Can this Mac run the local engine? Static facts (architecture, RAM, MLX, model on disk) plus the cached benchmark when it is still
    valid. ``measure=True`` also runs the 20 s synthetic benchmark (a child process: ``PROBE_BENCH_ARGV`` of the pipeline python, which
    prints JSON with ``rtf``) and caches it in asr-capability.json; it raises ProbeRefused while a recording is live. A failing
    benchmark leaves ``rtf`` None (``bench-failed``). Facts that cannot be read are unknown (None / 0.0), never guessed."""
    moment = _aware(now)
    machine = machine_id(run=run)
    arch = platform.machine() or "unknown"
    mem_gb = 0.0
    try:
        arm = run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True, timeout=5)
        if (getattr(arm, "stdout", "") or "").strip() == "1":
            arch = "arm64"                          # also under Rosetta: the hardware is arm64
    except Exception:
        pass
    try:
        memsize = run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5)
        mem_gb = round(int((getattr(memsize, "stdout", "") or "0").strip()) / 1024 ** 3, 1)
    except Exception:
        pass
    mlx_ok = _module_present("mlx") and _module_present("mlx_whisper")
    model_present = _model_present(cfg)
    version = _mlx_version()
    cached = _read_capability_cache(cfg, machine, version, moment)
    rtf, probed_at, extra = (cached["rtf"], cached["probed_at"], ()) if cached else (None, None, ())
    if measure:
        if _live_recording(cfg, moment):
            raise ProbeRefused("a recording is in progress: the benchmark would take CPU from the capture")
        try:
            done = run([str(getattr(cfg, "python_bin", "python3")), *PROBE_BENCH_ARGV], capture_output=True, text=True, timeout=600)
            if getattr(done, "returncode", 1) != 0:
                raise ValueError("bench exit")
            value = json.loads((getattr(done, "stdout", "") or "").strip().splitlines()[-1])["rtf"]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError("rtf")
            rtf, probed_at = float(value), moment.isoformat(timespec="seconds")
            doc = {"schema": 1, "probed_at": probed_at, "machine": machine, "mlx_version": version, "rtf": rtf, "arch": arch,
                   "mem_gb": mem_gb}
            cache_path = Path(getattr(cfg, "capability_path"))
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = cache_path.with_name(cache_path.name + ".tmp")
            tmp.write_text(json.dumps(doc, indent=1) + "\n", encoding="utf-8")
            os.replace(tmp, cache_path)
        except Exception:
            extra = ("bench-failed",)
    capable, reasons = _judge(cfg, arch, mem_gb, mlx_ok, model_present, rtf)
    return HardwareProbe(arch=arch, mem_gb=mem_gb, mlx_ok=mlx_ok, model_present=model_present, rtf=rtf, probed_at=probed_at,
                         capable=capable, reasons=reasons + extra)


# ======================================================================================================================
# the ASR decision table
# ======================================================================================================================
_ISSUER = object()          # marks a decision that came out of decide_asr (build_engine refuses any other: "no policy decision")


@dataclass(frozen=True)
class AsrDecision:
    """How this run transcribes. ``primary`` / ``fallback`` are engine ids (fallback None = none); ``allow_egress`` is True only when an
    external engine may be used at all; ``hosts`` maps an exact host to its HostRule for every allowed external engine and
    ``engine_hosts`` maps the engine id to that host; ``consent_ids`` maps engine id -> consent id. ``blocked`` is None, or the error_kind
    ("asr_policy_blocked") when no engine may or can transcribe; ``reason`` is the deciding code (policy-locked | local_only | the exclusion
    code of an unusable primary | hw-capable | hw-incapable | hw-unknown | ok); ``notes`` explain every exclusion ("remote: no-consent")."""
    primary: str
    fallback: Optional[str]
    allow_egress: bool
    local_only: bool
    allow_download: bool
    hosts: Mapping[str, HostRule]
    consent_ids: Mapping[str, str]
    blocked: Optional[str]
    reason: str
    local_capable: Optional[bool]
    notes: tuple
    send_vocab: bool
    _issued: object = field(default=None, repr=False, compare=False)
    engine_hosts: Mapping[str, str] = field(default_factory=dict, repr=False, compare=False)


def is_issued(decision: Any) -> bool:
    """True for a decision made by decide_asr in this process (a hand-built or copied-from-elsewhere object is not)."""
    return isinstance(decision, AsrDecision) and decision._issued is _ISSUER


def _remote_target(cfg) -> tuple[Optional[tuple], Optional[str]]:
    url = str(getattr(cfg, "asr_remote_url", "") or "").strip()
    if not url:
        return None, "not-configured"
    try:
        parts = urlsplit(url)
        host, port = (parts.hostname or "").lower(), parts.port or 443
    except ValueError:
        return None, "bad-host"
    if parts.scheme != "https" or not host or parts.username or parts.password or host.endswith("."):
        return None, "bad-host"
    try:
        ipaddress.ip_address(host)
        return None, "bad-host"                     # an IP literal is never a server name
    except ValueError:
        pass
    return (host, port), None


def _azure_target(cfg) -> tuple[Optional[tuple], Optional[str]]:
    host = str(getattr(cfg, "asr_azure_host", "") or "").strip().lower()
    if host:
        label = r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        if not any(host.endswith(suffix) and host != suffix[1:] for suffix in AZURE_HOST_SUFFIXES) or not re.fullmatch(
                rf"{label}(\.{label})+", host):
            return None, "bad-host"
        return (host, 443), None
    region = str(getattr(cfg, "asr_azure_region", "") or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9]{2,40}", region):
        return None, "bad-host"
    return (f"{region}.api.cognitive.microsoft.com", 443), None


def consent_binding(cfg, engine: str) -> tuple[Optional[dict], Optional[str]]:
    """What a consent for ``engine`` is bound to: (binding, None) with engine, kind, host, port, region, model, protocol, backend_kind, or
    (None, reason) when the engine is not configured (not-configured) or its host is unacceptable (bad-host). Single source of truth: the
    decision table, the TTY consent command and the engines all read the binding from here."""
    meta = ENGINE_META.get(engine)
    if meta is None or meta["kind"] == "local":
        return None, "not-configured"
    if engine == "remote":
        target, why = _remote_target(cfg)
        region = ""
    elif engine == "azure":
        target, why = _azure_target(cfg)
        region = str(getattr(cfg, "asr_azure_region", "") or "").strip().lower()
    else:                                           # a provider of asr_providers (the URL setting names the host); a stub has none
        target, why = asr_providers.target(cfg, engine)
        region = ""
    if target is None:
        return None, why
    return {"engine": engine, "kind": meta["kind"], "host": target[0], "port": target[1], "region": region, "model": meta["model"],
            "protocol": meta["protocol"], "backend_kind": meta["backend_kind"]}, None


def _safe_decision(cfg, lo, reason: str) -> AsrDecision:
    """What decide_asr answers when it fails inside: local only, nothing external, nothing blocked (closing must not lose a meeting)."""
    return AsrDecision(primary="whisper", fallback=None, allow_egress=False, local_only=True if lo is None else bool(lo.value),
                       allow_download=False, hosts={}, consent_ids={}, blocked=None, reason=reason, local_capable=None,
                       notes=(f"decision error: {reason}",), send_vocab=False, _issued=_ISSUER)


def decide_asr(cfg, policy, lo, consents, hw, *, used_minutes_today: float = 0.0, now=None) -> AsrDecision:
    """The ASR decision table A0-A6. Pure; never raises (an internal error answers local-only with reason decision-error).

    A0 policy locked, A1 meeting local_only: no external engine (whatever ASR_ENGINE says). A2 organisation limits (lane, engine list,
    host list, residency, daily cap) and A3 consent exclude an external engine one by one; A4 ASR_ENGINE / ASR_FALLBACK name the
    candidates; A5 ``auto`` picks whisper when the Mac is capable or unknown, else the company server; A6 an excluded external primary is
    replaced by local Whisper (reason says why), and when the Mac cannot run Whisper either the answer is ``blocked`` (error_kind
    asr_policy_blocked; it carries no fallback and no egress: a chunk fallback is no way around a primary that is not allowed), except that
    ASR_ENGINE=whisper is never blocked (it is tried even on weak hardware). A local fallback is dropped when the Mac is known to be
    incapable; an external fallback needs its own consent with use fallback|both. Local Whisper is never excluded by a policy list."""
    try:
        return _decide(cfg, policy, lo, consents, hw, used_minutes_today, now)
    except Exception as exc:
        log.warning("decide_asr failed (%s): local only", type(exc).__name__)
        return _safe_decision(cfg, lo, "decision-error")


def _decide(cfg, policy, lo, consents, hw, used_minutes_today, now) -> AsrDecision:
    moment = _aware(now)
    policy = policy if policy is not None else absent_policy()
    consents = consents if consents is not None else ConsentSet()
    notes: list[str] = []
    want_primary, want_fallback = requested_engines(cfg)
    for name, raw, got in (("ASR_ENGINE", getattr(cfg, "asr_engine", "whisper"), want_primary),
                           ("ASR_FALLBACK", getattr(cfg, "asr_fallback", "none"), want_fallback)):
        if isinstance(raw, str) and raw.strip().lower() != got:
            notes.append(f"{name}: unrecognised value read as {got}")
    capable = getattr(hw, "capable", None) if hw is not None else None
    closed = "policy-locked" if policy.locked else ("local_only" if lo.value else None)           # A0 then A1
    allow_download = bool(getattr(cfg, "asr_allow_download", True)) and not lo.value and not policy.locked

    if want_primary == "auto":                                                                    # A5
        primary_req = "remote" if capable is False else "whisper"
        hw_reason = {True: "hw-capable", False: "hw-incapable", None: "hw-unknown"}[capable]
    else:
        primary_req, hw_reason = want_primary, None

    usable: dict[str, dict] = {}                          # engine -> {"binding", "consent"} of the external engines that passed A2 + A3

    def evaluate(engine: str, role: str) -> Optional[str]:
        """None when ``engine`` may be used in ``role``; else the exclusion code (A0/A1 first, then A2, then A3)."""
        if closed:
            return closed
        binding, why = consent_binding(cfg, engine)
        if binding is None:
            return why
        meta = ENGINE_META[engine]
        lane = meta["lane"]
        if policy.lanes.get(lane, "deny") != "allow":
            return policy.lane_reasons.get(lane, "policy-lane")
        if policy.allowed_engines is not None and engine not in policy.allowed_engines:
            return "policy-engine"
        if policy.allowed_hosts is not None and binding["host"] not in policy.allowed_hosts:
            return "policy-host"
        if meta["residency"] == "foreign" and not policy.allow_foreign:
            return "policy-foreign"
        entry, reason = consents.valid_for(engine, binding["host"], binding["port"], role, region=binding["region"],
                                           model=binding["model"], protocol=binding["protocol"],
                                           backend_kind=binding["backend_kind"], now=moment, org=policy)
        if entry is None:
            return reason
        caps = [int(getattr(cfg, "asr_cloud_daily_minutes", 240))]
        if policy.daily_audio_minutes_cap is not None:
            caps.append(policy.daily_audio_minutes_cap)
        if getattr(entry, "daily_minutes_cap", None) is not None:
            caps.append(entry.daily_minutes_cap)
        if used_minutes_today >= min(caps):
            return "cap"
        usable[engine] = {"binding": binding, "consent": entry}
        return None

    reason = closed or hw_reason or "ok"
    blocked: Optional[str] = None
    if ENGINE_META[primary_req]["kind"] == "local":
        primary = primary_req                             # whisper: explicit or by auto; never excluded, never blocked
    else:
        why = evaluate(primary_req, "primary")
        if why is None:
            primary = primary_req
        else:
            notes.append(f"{primary_req}: excluded ({why})")
            reason = why
            if capable is False:                          # A6: no external engine and no local engine
                primary, blocked = "whisper", "asr_policy_blocked"
            else:
                primary = "whisper"
                notes.append("using local whisper instead")

    fallback: Optional[str] = None
    if blocked:
        notes.append("blocked: no engine can transcribe on this Mac under this policy (no fallback is tried)")
    elif want_fallback != "none" and want_fallback != primary:
        if ENGINE_META[want_fallback]["kind"] == "local":
            if capable is False:
                notes.append("whisper fallback dropped (this Mac cannot run it)")
            else:
                fallback = want_fallback
        else:
            why = evaluate(want_fallback, "fallback")
            if why is None:
                fallback = want_fallback
            else:
                notes.append(f"{want_fallback}: fallback excluded ({why})")
    elif want_fallback != "none":
        notes.append("fallback equals the primary: dropped")

    hosts: dict[str, HostRule] = {}
    engine_hosts: dict[str, str] = {}
    consent_ids: dict[str, str] = {}
    kinds: set[str] = set()
    for engine in (primary, fallback):
        if engine is None or engine not in usable:
            continue
        binding, entry = usable[engine]["binding"], usable[engine]["consent"]
        ca_file = getattr(cfg, "asr_remote_ca_file", None) if engine == "remote" else None
        limits = {key: ENGINE_META[engine][key] for key in ("max_request_bytes", "max_response_bytes") if key in ENGINE_META[engine]}
        hosts[binding["host"]] = HostRule(host=binding["host"], port=binding["port"], ca_pem_sha256=getattr(entry, "ca_sha256", None),
                                          ca_file=str(ca_file) if ca_file else None, cert_sha256=tuple(getattr(entry, "cert_sha256", ())),
                                          **limits)
        engine_hosts[engine] = binding["host"]
        consent_ids[engine] = consent_id(entry)
        kinds.add(binding["kind"])
    send_vocab = bool(kinds) and bool(getattr(cfg, "asr_send_vocab", True)) and all(policy.send_vocab.get(k, False) for k in kinds)
    return AsrDecision(primary=primary, fallback=fallback, allow_egress=bool(kinds), local_only=bool(lo.value),
                       allow_download=allow_download, hosts=hosts, consent_ids=consent_ids, blocked=blocked, reason=reason,
                       local_capable=capable, notes=tuple(notes), send_vocab=send_vocab, _issued=_ISSUER, engine_hosts=engine_hosts)
