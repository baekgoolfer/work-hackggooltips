"""Runtime configuration (SPEC section 3). Parsed from KEY=VALUE config.env; every key has a default.

Additive changes only: keep field names and the load_config() signature.

SPEC 18: the privacy-lane, external-ASR and local-data keys,
the location of the organisation policy (``policy.json``) and the rules for a policy-managed Mac. Every new key defaults to today's
behaviour, so a config.env without them reads exactly as before. Unrecognised text of a privacy switch is
read as the RESTRICTIVE value of that key (``_switch``) and recorded in ``Config.config_warnings`` for ``mcap doctor``.
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Callable, Optional

from .asr_providers import PROVIDERS            # stdlib only and imports nothing of this package: the names of the cloud providers

HOME = Path.home()
DEFAULT_SUPPORT_DIR = HOME / "Library" / "Application Support" / "MeetingCapture"
# A plain local folder (not under Documents or Desktop, so iCloud never syncs it by accident). Google Drive, or any other synced folder:
# set ARCHIVE_DIR in config.env (scripts/install.sh seeds it when exactly one Google Drive account is mounted).
DEFAULT_ARCHIVE_DIR = HOME / "Meetings"

# ---- organisation policy location ----------------------------------------------------------------------------
# Module globals read at CALL time (a test patches them to a temp dir); the dataclass default of Config.policy_path is the value
# these have at import.
POLICY_SYSTEM_PATH = Path("/Library/Application Support/MeetingCapture/policy.json")
POLICY_REQUIRED_MARKER = Path("/Library/Application Support/MeetingCapture/policy.required")
# Environment variables that exist for tests and e2e runs. A Mac that has a system policy (or the marker) ignores all of them:
# Python (here and in the modules that call ``test_hook_env``) and the Swift app.
TEST_HOOK_ENV = ("MCAP_CONFIG", "MCAP_LOG_DIR", "MCAP_SILERO_MODEL", "MCAP_SECURITY_BIN", "MCAP_POLICY_PATH")
# config.env keys a policy-managed Mac ignores (the policy decides where the runtime lives; CLAUDE_BIN must pass the signature pin).
POLICY_IGNORED_KEYS = ("SUPPORT_DIR", "PYTHON_BIN", "PROJECT_DIR", "CLAUDE_BIN")


def system_policy_present() -> bool:
    """True when this Mac is policy-managed: ``policy.json`` or the ``policy.required`` marker exists (lstat, so a dangling symlink counts).
    A lookup that fails for any reason other than 'not there' (permissions) also counts as managed: unknown is the closed reading."""
    for path in (POLICY_SYSTEM_PATH, POLICY_REQUIRED_MARKER):
        try:
            os.lstat(path)
            return True
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            return True
    return False


def policy_path_override() -> Optional[Path]:
    """``$MCAP_POLICY_PATH`` (tests and e2e runs), honoured ONLY when no system policy and no marker exist: it can never move a managed
    Mac's policy file, so it is no way around a policy."""
    if system_policy_present():
        return None
    value = os.environ.get("MCAP_POLICY_PATH")
    return Path(value) if value else None


def test_hook_env(name: str) -> Optional[str]:
    """The value of a test-hook environment variable (``TEST_HOOK_ENV``), or None when it is unset or this Mac is policy-managed.
    Modules that read such a variable (apikey/asr_creds: MCAP_SECURITY_BIN, vad: MCAP_SILERO_MODEL) go through this function."""
    value = os.environ.get(name)
    if not value or system_policy_present():
        return None
    return value


def _expand(value: str) -> Path:
    return Path(os.path.expanduser(value.strip()))


_SWITCH_ON = ("1", "true", "yes", "on")
_SWITCH_OFF = ("0", "false", "no", "off")


class _Switch:
    """Caster of a privacy switch: 1/true/yes/on and 0/false/no/off; any other text is read as ``restrictive`` of THAT key (a typo must
    never switch a protection off, nor a leak on). ``recognised`` tells doctor whether the text was understood."""

    def __init__(self, restrictive: bool):
        self.restrictive = bool(restrictive)

    def __call__(self, value: str) -> bool:
        text = str(value).strip().lower()
        if text in _SWITCH_ON:
            return True
        if text in _SWITCH_OFF:
            return False
        return self.restrictive

    @staticmethod
    def recognised(value: str) -> bool:
        return str(value).strip().lower() in _SWITCH_ON + _SWITCH_OFF


def _switch(restrictive: bool) -> Callable[[str], bool]:
    """1/true/yes/on, 0/false/no/off; anything else -> `restrictive` of THAT key: LOCAL_ONLY_DEFAULT true; ASR_ALLOW_DOWNLOAD,
    LOG_CONTENT, ASR_SEND_VOCAB and STATUS_INCLUDE_USAGE false."""
    return _Switch(restrictive)


class _Enum:
    """Caster of a closed word list: lower-cased and trimmed; an unknown word reads as ``fallback`` (the harmless engine: whisper / none),
    recorded as a warning (never an error, so a typo cannot stop the pipeline)."""

    def __init__(self, allowed: tuple, fallback: str):
        self.allowed, self.fallback = allowed, fallback

    def __call__(self, value: str) -> str:
        text = str(value).strip().lower()
        return text if text in self.allowed else self.fallback

    def recognised(self, value: str) -> bool:
        return str(value).strip().lower() in self.allowed


class _Canon(_Enum):
    """``_Enum`` for words with a fixed spelling (``ko-KR``): the match ignores case and the answer is the canonical spelling."""

    def __init__(self, words: tuple, fallback: str):
        super().__init__(tuple(words), fallback)
        self._by_lower = {word.lower(): word for word in words}

    def __call__(self, value: str) -> str:
        return self._by_lower.get(str(value).strip().lower(), self.fallback)

    def recognised(self, value: str) -> bool:
        return str(value).strip().lower() in self._by_lower


def _mic_gate(value: str) -> str:
    """MIC_MUTE_GATE off | on; unrecognised text reads as on (the restrictive value: the protection stays on)."""
    text = str(value).strip().lower()
    return "off" if text in _SWITCH_OFF else "on"


_mic_gate.recognised = _Switch.recognised  # type: ignore[attr-defined]


def _number(kind, minimum, *, exclusive: bool = False, maximum=None):
    """int / float caster that rejects NaN, infinities and values outside the range with ValueError (like a bad integer always did:
    load_config turns it into 'config.env: bad value for KEY')."""
    def cast(value: str):
        number = kind(value)
        if kind is float and not math.isfinite(number):
            raise ValueError("not finite")
        if number < minimum or (exclusive and number == minimum) or (maximum is not None and number > maximum):
            raise ValueError("out of range")
        return number
    return cast


def _text(value: str) -> str:
    return value.strip()


def _lower_text(value: str) -> str:
    return value.strip().lower()


@dataclass
class Config:
    support_dir: Path = DEFAULT_SUPPORT_DIR
    archive_dir: Path = DEFAULT_ARCHIVE_DIR
    project_dir: Path = HOME / "Developer" / "meeting-capture"
    python_bin: Path = DEFAULT_SUPPORT_DIR / "venv" / "bin" / "python"
    claude_bin: Path = HOME / ".local" / "bin" / "claude"
    self_name: str = "Me"
    asr_model: str = "mlx-community/whisper-large-v3-mlx"
    asr_language: str = "auto"  # auto | ko | en
    note_model: str = "opus"
    note_fallback_model: str = "sonnet"
    note_effort: str = "high"
    note_language: str = "auto"
    note_timeout_seconds: int = 1200
    audio_retention_days: int = 0  # 0 = keep forever
    asr_languages: str = "ko,en"  # languages the ASR may use (per-region language ID is restricted to this set); add ja for Japanese meetings
    max_claude_calls_per_meeting: int = 30  # hard cap on claude -p calls (cleanup batches + note + verify + calendar)
    asr_vad: str = "auto"  # auto (silero if onnxruntime+model available, else energy) | silero | energy
    asr_strategy: str = "dual"  # single | dual: dual decodes each chunk twice (prompted + plain) and reconciles them; local engines only (asr_reconcile.py). dual is the default because it passed the bench gate (docs/CONFIGURATION.md); an unknown word reads as single
    calendar_lookup: str = "auto"  # auto | 0 : best-effort title/participants from the claude.ai Google Calendar connector
    claude_auth: str = "api"  # api | subscription (SPEC 17): api = key from the macOS Keychain, billed per token to your Console account (the supported path); subscription is opt-in
    claude_key_service: str = "MeetingCapture Anthropic API key"  # Keychain generic-password service (account = $USER)
    claude_daily_budget_usd: float = 5.0  # api mode: stop LLM stages for the rest of the day when the logged cost reaches this (0 = off)
    claude_meeting_budget_usd: float = 2.0  # api mode: per pipeline run; the note itself is always reserved (0 = off)
    mic_aec: str = "auto"  # auto | 1 | 0 : offline echo cancellation of the mic track against the system-audio track
    transcript_cleanup: bool = True  # LLM pass -> transcript.cleaned.md (raw transcript.md is never modified)
    note_verify: bool = True  # second LLM pass that checks the note against the transcript
    note_stop_on_overage: bool = True  # True = stop notes (keep the transcript) while Claude reports extra-usage billing; False = only record it

    # ---- SPEC 18 (W2): privacy lanes, external ASR, local data. Every default reproduces today's behaviour. -------------------
    local_only_default: bool = False  # LOCAL_ONLY_DEFAULT (_switch(True)): default of the per-meeting local_only flag; unknown text = true
    asr_engine: str = "whisper"  # ASR_ENGINE whisper|remote|azure|clova|openai-compat|auto (unknown -> whisper + warning)
    asr_fallback: str = "none"  # ASR_FALLBACK none|whisper|remote|azure|clova|openai-compat (unknown -> none + warning)
    asr_local_min_ram_gb: int = 16  # capable verdict (auto, doctor): minimum RAM
    asr_local_max_rtf: float = 0.25  # capable verdict: maximum measured real-time factor
    asr_remote_url: str = ""  # ASR_REMOTE_URL base URL of the mcap-asr/1 server (https, DNS name)
    asr_remote_ca_file: Optional[Path] = None  # ASR_REMOTE_CA_FILE private CA PEM (its sha256 must equal the consent's ca_sha256)
    asr_remote_max_wait_s: int = 120
    asr_azure_region: str = "koreacentral"
    asr_azure_host: str = ""  # explicit Azure endpoint host (suffix-checked by the engine and by policy.consent_binding)
    asr_azure_locales: str = ""
    asr_azure_bias: float = 1.0
    asr_azure_usd_per_hour: float = 0.0
    asr_clova_invoke_url: str = ""  # ASR_CLOVA_INVOKE_URL: https invoke URL of the user's CLOVA Speech domain (host and port are bound into the consent)
    asr_clova_language: str = "enko"  # ASR_CLOVA_LANGUAGE ko-KR | en-US | enko (| ja | zh-cn | zh-tw)
    asr_clova_diarization: str = "auto"  # ASR_CLOVA_DIARIZATION auto | on | off
    asr_openai_compat_url: str = ""  # ASR_OPENAI_COMPAT_URL: base URL (https) of a server with POST <base>/audio/transcriptions
    asr_openai_compat_model: str = "whisper-1"  # ASR_OPENAI_COMPAT_MODEL: the ``model`` field of that request
    asr_cloud_block_seconds: int = 900  # ASR_CLOUD_BLOCK_SECONDS: audio per upload of an engine that takes blocks (30 to 1800)
    asr_cloud_daily_minutes: int = 240  # daily cap of external audio on this Mac (min with the policy cap); 0 = no external audio
    asr_request_timeout_s: int = 90
    asr_retry_max: int = 3
    asr_circuit_fails: int = 3
    asr_circuit_cooldown_s: int = 120
    asr_allow_download: bool = True  # ASR_ALLOW_DOWNLOAD (_switch(False)): today the model may be downloaded when missing
    asr_send_vocab: bool = True  # ASR_SEND_VOCAB (_switch(False)): vocabulary terms to an external engine
    local_archive_dir: Optional[Path] = None  # LOCAL_ARCHIVE_DIR; None -> support_dir/"local-meetings" (validated by policy.local_archive_ok)
    local_archive_retention_days: int = 0
    staging_failed_retention_days: int = 0
    mic_mute_gate: str = "off"  # MIC_MUTE_GATE off|on: Swift acts on it, Python reports it (unknown text = on)
    log_content: bool = True  # LOG_CONTENT (_switch(False)): pipeline logs may carry transcript snippets
    log_retention_days: int = 0  # 0 = keep (today nothing is ever pruned)
    app_log_max_mb: int = 0  # APP_LOG_MAX_MB: read by the Swift app only (0 = no rotation); here so doctor and the policy layers know it
    status_include_usage: bool = False  # STATUS_INCLUDE_USAGE (_switch(False))
    # Where the organisation policy lives. NOT a config key and no environment variable moves it: load_config() sets it from
    # policy_path_override() (tests; ignored on a managed Mac) and a test builds Config(policy_path=tmp / "policy.json").
    policy_path: Path = POLICY_SYSTEM_PATH
    explicit_keys: frozenset = field(default_factory=frozenset, repr=False, compare=False)  # keys present (non-empty) in config.env
    asr_decision: Optional[object] = field(default=None, repr=False, compare=False)  # set only by lanes (RunPrivacy.cfg_for_asr)
    config_warnings: tuple = field(default=(), repr=False, compare=False)  # unrecognised switch / engine words, for mcap doctor

    # ---- derived paths -------------------------------------------------------------
    @property
    def sessions_dir(self) -> Path:
        return self.support_dir / "sessions"

    @property
    def vocab_path(self) -> Path:
        return self.support_dir / "vocabulary.txt"

    @property
    def note_prompt_path(self) -> Path:
        return self.support_dir / "note_prompt.md"

    @property
    def config_path(self) -> Path:
        return self.support_dir / "config.env"

    @property
    def log_dir(self) -> Path:
        override = test_hook_env("MCAP_LOG_DIR")  # test hook shared with the Swift app; ignored on a policy-managed Mac
        return Path(override) if override else HOME / "Library" / "Logs" / "MeetingCapture"

    # ---- additive (notes/CLI owner) ---------------------------------------------------
    @property
    def discarded_dir(self) -> Path:
        """Sessions without speech are parked here and pruned after 7 days (SPEC 7.4)."""
        return self.sessions_dir / "_discarded"

    @property
    def locks_dir(self) -> Path:
        return self.support_dir / "locks"

    @property
    def overage_path(self) -> Path:
        """Marker written when Claude reports extra-usage billing (SPEC 13.3)."""
        return self.support_dir / "overage.json"

    @property
    def claude_cwd(self) -> Path:
        """Empty neutral working directory for `claude -p` (no CLAUDE.md / project settings pickup)."""
        return self.support_dir / "claude-cwd"

    @property
    def repo_config_dir(self) -> Path:
        """PROJECT_DIR/config: fallback location of note_prompt.md / vocabulary.txt if the SUPPORT_DIR copy is missing."""
        return self.project_dir / "config"

    # ---- additive (W2): derived paths of the SPEC 18 files ----------------------------------------------------------
    @property
    def consent_path(self) -> Path:
        """User consents for external ASR engines (written only by `mcap asr-engines consent`)."""
        return self.support_dir / "asr-consent.json"

    @property
    def capability_path(self) -> Path:
        """Hardware probe cache (`mcap asr-engines check --probe`)."""
        return self.support_dir / "asr-capability.json"

    @property
    def asr_usage_path(self) -> Path:
        """Content-free record of every external ASR request."""
        return self.support_dir / "asr-usage.jsonl"

    @property
    def local_archive_root(self) -> Path:
        """Where local-only (and Drive-denied) meetings are kept; validated against the allow-list by policy.local_archive_ok."""
        return Path(self.local_archive_dir) if self.local_archive_dir else self.support_dir / "local-meetings"

    @property
    def session_private_dir(self) -> Path:
        """Swift-only per-session extras (toggle history, mute spans); never goes to Drive."""
        return self.support_dir / "session-private"


# config.env KEY -> (Config field, caster)
def _bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


_KEYS = {
    "ARCHIVE_DIR": ("archive_dir", _expand),
    "PROJECT_DIR": ("project_dir", _expand),
    "PYTHON_BIN": ("python_bin", _expand),
    "CLAUDE_BIN": ("claude_bin", _expand),
    "SELF_NAME": ("self_name", str),
    "ASR_MODEL": ("asr_model", str),
    "ASR_LANGUAGE": ("asr_language", str),
    "NOTE_MODEL": ("note_model", str),
    "NOTE_FALLBACK_MODEL": ("note_fallback_model", str),
    "NOTE_EFFORT": ("note_effort", str),
    "NOTE_LANGUAGE": ("note_language", str),
    "NOTE_TIMEOUT_SECONDS": ("note_timeout_seconds", int),
    "AUDIO_RETENTION_DAYS": ("audio_retention_days", int),
    "ASR_VAD": ("asr_vad", str),
    "ASR_STRATEGY": ("asr_strategy", _Enum(("single", "dual"), "single")),
    "ASR_LANGUAGES": ("asr_languages", str),
    "MAX_CLAUDE_CALLS_PER_MEETING": ("max_claude_calls_per_meeting", int),
    "CALENDAR_LOOKUP": ("calendar_lookup", str),
    "NOTE_STOP_ON_OVERAGE": ("note_stop_on_overage", _bool),
    "CLAUDE_AUTH": ("claude_auth", str),
    "CLAUDE_KEY_SERVICE": ("claude_key_service", str),
    "CLAUDE_DAILY_BUDGET_USD": ("claude_daily_budget_usd", float),
    "CLAUDE_MEETING_BUDGET_USD": ("claude_meeting_budget_usd", float),
    "MIC_AEC": ("mic_aec", str),
    "TRANSCRIPT_CLEANUP": ("transcript_cleanup", _bool),
    "NOTE_VERIFY": ("note_verify", _bool),
    # ---- SPEC 18 (W2) ----
    "LOCAL_ONLY_DEFAULT": ("local_only_default", _switch(True)),
    "ASR_ENGINE": ("asr_engine", _Enum(("whisper", "remote", "azure", *PROVIDERS, "auto"), "whisper")),          # PROVIDERS: asr_providers.py (clova, openai-compat)
    "ASR_FALLBACK": ("asr_fallback", _Enum(("none", "whisper", "remote", "azure", *PROVIDERS), "none")),
    "ASR_LOCAL_MIN_RAM_GB": ("asr_local_min_ram_gb", _number(int, 0)),
    "ASR_LOCAL_MAX_RTF": ("asr_local_max_rtf", _number(float, 0.0, exclusive=True)),
    "ASR_REMOTE_URL": ("asr_remote_url", _text),
    "ASR_REMOTE_CA_FILE": ("asr_remote_ca_file", _expand),
    "ASR_REMOTE_MAX_WAIT_S": ("asr_remote_max_wait_s", _number(int, 1)),
    "ASR_AZURE_REGION": ("asr_azure_region", _lower_text),
    "ASR_AZURE_HOST": ("asr_azure_host", _lower_text),
    "ASR_AZURE_LOCALES": ("asr_azure_locales", _text),
    "ASR_AZURE_BIAS": ("asr_azure_bias", _number(float, 0.0, maximum=2.0)),
    "ASR_AZURE_USD_PER_HOUR": ("asr_azure_usd_per_hour", _number(float, 0.0)),
    "ASR_CLOVA_INVOKE_URL": ("asr_clova_invoke_url", _text),
    "ASR_CLOVA_LANGUAGE": ("asr_clova_language", _Canon(("ko-KR", "en-US", "enko", "ja", "zh-cn", "zh-tw"), "enko")),
    "ASR_CLOVA_DIARIZATION": ("asr_clova_diarization", _Enum(("auto", "on", "off"), "auto")),
    "ASR_OPENAI_COMPAT_URL": ("asr_openai_compat_url", _text),
    "ASR_OPENAI_COMPAT_MODEL": ("asr_openai_compat_model", _text),
    "ASR_CLOUD_BLOCK_SECONDS": ("asr_cloud_block_seconds", _number(int, 30, maximum=1800)),
    "ASR_CLOUD_DAILY_MINUTES": ("asr_cloud_daily_minutes", _number(int, 0)),
    "ASR_REQUEST_TIMEOUT_S": ("asr_request_timeout_s", _number(int, 1)),
    "ASR_RETRY_MAX": ("asr_retry_max", _number(int, 1)),
    "ASR_CIRCUIT_FAILS": ("asr_circuit_fails", _number(int, 1)),
    "ASR_CIRCUIT_COOLDOWN_S": ("asr_circuit_cooldown_s", _number(int, 1)),
    "ASR_ALLOW_DOWNLOAD": ("asr_allow_download", _switch(False)),
    "ASR_SEND_VOCAB": ("asr_send_vocab", _switch(False)),
    "LOCAL_ARCHIVE_DIR": ("local_archive_dir", _expand),
    "LOCAL_ARCHIVE_RETENTION_DAYS": ("local_archive_retention_days", _number(int, 0)),
    "STAGING_FAILED_RETENTION_DAYS": ("staging_failed_retention_days", _number(int, 0)),
    "MIC_MUTE_GATE": ("mic_mute_gate", _mic_gate),
    "LOG_CONTENT": ("log_content", _switch(False)),
    "LOG_RETENTION_DAYS": ("log_retention_days", _number(int, 0)),
    "APP_LOG_MAX_MB": ("app_log_max_mb", _number(int, 0)),
    "STATUS_INCLUDE_USAGE": ("status_include_usage", _switch(False)),
}


def parse_env_text(text: str) -> dict[str, str]:
    """Parse KEY=VALUE lines. '#' starts a comment at line start or after whitespace. No quote processing needed."""
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        # strip inline comment (whitespace + '#')
        for i, ch in enumerate(value):
            if ch == "#" and i > 0 and value[i - 1].isspace():
                value = value[:i]
                break
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def _apply_policy_layers(values: dict[str, str], policy) -> dict[str, str]:
    """SPEC 18: built-in default < policy.defaults (only when the key is unset) < config.env < policy.enforced. ``defaults`` come only
    from a VALID policy. ``enforced`` also comes from a LOCKED one, where the policy loader has reduced it to the company baseline (a
    damaged policy file must not make the privacy settings of a managed Mac looser; a file that positively says personal carries none).
    Empty config.env values count as unset, as they always did. The policy loader has already restricted both maps to the whitelisted
    behavioural keys."""
    merged: dict[str, str] = {}
    valid = bool(getattr(policy, "valid", False))
    if valid:
        merged.update(policy.defaults)
    merged.update({key: value for key, value in values.items() if value != ""})
    if valid or bool(getattr(policy, "locked", False)):
        merged.update(policy.enforced)
    return merged


def load_config(path: Optional[Path] = None) -> Config:
    """Load config.env (default: $MCAP_CONFIG or SUPPORT_DIR/config.env). Missing file/keys -> defaults.

    On a policy-managed Mac (``system_policy_present()``) the test-hook variables (MCAP_CONFIG ...) and the config.env keys SUPPORT_DIR,
    PYTHON_BIN, PROJECT_DIR and CLAUDE_BIN are ignored, and a valid policy's ``defaults``/``enforced`` layers are applied around
    config.env (a locked policy still enforces the company baseline, see ``_apply_policy_layers``; company profile with ``runtime.root``:
    PROJECT_DIR / PYTHON_BIN are fixed to ``<root>/current``)."""
    from . import policy as policy_mod          # lazy: policy.py only imports this module inside its functions

    managed = system_policy_present()
    if path is None:
        env_path = None if managed else os.environ.get("MCAP_CONFIG")
        path = Path(env_path) if env_path else DEFAULT_SUPPORT_DIR / "config.env"
    cfg = Config()
    cfg.policy_path = policy_path_override() or POLICY_SYSTEM_PATH
    values: dict[str, str] = {}
    if path.exists():
        values = parse_env_text(path.read_text(encoding="utf-8"))
    if managed:
        for key in POLICY_IGNORED_KEYS:
            values.pop(key, None)
    cfg.explicit_keys = frozenset(key for key, value in values.items() if value != "")
    org = policy_mod.load_org_policy(cfg.policy_path)
    layered = _apply_policy_layers(values, org)
    # SUPPORT_DIR is not a config key (fixed location), but allow override for tests
    if "SUPPORT_DIR" in layered:
        cfg.support_dir = _expand(layered["SUPPORT_DIR"])
        cfg.python_bin = cfg.support_dir / "venv" / "bin" / "python"
    warnings: list[str] = []
    for key, (field_name, caster) in _KEYS.items():
        if key in layered and layered[key] != "":
            try:
                setattr(cfg, field_name, caster(layered[key]))
            except ValueError:
                raise ValueError(f"config.env: bad value for {key}: {layered[key]!r}")
            known = getattr(caster, "recognised", None)
            if known is not None and not known(layered[key]):
                warnings.append(f"{key}: unrecognised value {layered[key][:30]!r} is read as {getattr(cfg, field_name)!r}")
    cfg.config_warnings = tuple(warnings)
    if org.valid and org.profile == "company" and org.runtime_root:
        release = Path(org.runtime_root) / "current"
        cfg.project_dir = release
        cfg.python_bin = release / "venv" / "bin" / "python"
    return cfg
