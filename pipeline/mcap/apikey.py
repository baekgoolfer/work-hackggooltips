"""Anthropic API key access for CLAUDE_AUTH=api (SPEC 17). The key lives ONLY in the macOS Keychain.

Hard rules (all of them have a regression test in tests/test_apikey.py):
  * The key is never written anywhere by us: not to config files, logs, state.json, usage.jsonl, argv, the session folder or the
    transcript. `set_key_interactive()` does not even see it: the macOS `security` tool prompts on the terminal itself.
  * `read_key()` is called right before a claude child is started (note.child_env) and the value is only put into that child's
    environment as ANTHROPIC_API_KEY. Nothing is cached on disk and no argv ever contains it.
  * CLAUDE_AUTH=subscription never reaches this module's Keychain functions (note.child_env decides): the Keychain may hold a key and
    it is still never passed on.
  * Every string that is stored or printed goes through `redact()`: `sk-ant-...` shapes and the exact key we read are masked.
    SPEC 18 adds a few NARROW shapes of the external-ASR credentials (relay bearer tokens, JWTs, PEM
    blocks, the Azure key header) and `register_redaction_pattern()` for more; ordinary text such as a meeting title is not touched.

The `security` binary is overridable with $MCAP_SECURITY_BIN (tests use a shim; the default is /usr/bin/security). On a Mac with an
organisation policy the variable is ignored (config.test_hook_env): only /usr/bin/security runs. Never point a test or a script at the
real Keychain.
"""
from __future__ import annotations

import bisect
import getpass
import logging
import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from typing import Any, Optional

from .config import Config, test_hook_env

log = logging.getLogger("mcap.apikey")

MODE_SUBSCRIPTION, MODE_API = "subscription", "api"
MODES = (MODE_SUBSCRIPTION, MODE_API)
API_KEY_ENV = "ANTHROPIC_API_KEY"
API_KEY_SOURCE = "ANTHROPIC_API_KEY"          # init.apiKeySource of a claude run that really used the key from the environment
KEY_PREFIX = "sk-ant-"
SECURITY_BIN_ENV = "MCAP_SECURITY_BIN"
DEFAULT_SECURITY_BIN = "/usr/bin/security"
DEFAULT_SERVICE = "MeetingCapture Anthropic API key"
READ_TIMEOUT_S = 10.0
NOT_FOUND_MESSAGE = "API key not found in the Keychain: run make set-api-key"
BAD_SHAPE_MESSAGE = ("The Keychain item does not look like an Anthropic API key (it must start with sk-ant-): "
                     "run make set-api-key")
ITEM_NOT_FOUND_EXIT = 44                       # `security`: errSecItemNotFound
MASK = "sk-ant-***"


# ---------------------------------------------------------------------------------- the mode
def mode(cfg: Any) -> str:
    """CLAUDE_AUTH normalised (lower case, trimmed); an empty value is the default, api. Anything that is not a string counts as
    subscription (a test double: it never reaches the Keychain)."""
    value = getattr(cfg, "claude_auth", MODE_SUBSCRIPTION)
    if not isinstance(value, str):
        return MODE_SUBSCRIPTION
    return value.strip().lower() or MODE_API


def is_api(cfg: Any) -> bool:
    return mode(cfg) == MODE_API


def mode_problem(cfg: Any) -> Optional[str]:
    """A misspelt CLAUDE_AUTH must not silently pick a billing path: no Claude call is made until it is fixed."""
    value = mode(cfg)
    if value in MODES:
        return None
    return f"CLAUDE_AUTH must be 'subscription' or 'api' (got '{value[:30]}'): no Claude call is made until it is fixed"


# ---------------------------------------------------------------------------------- redaction
_KEY_RE = re.compile(r"sk-ant-[A-Za-z0-9_\-]+")
_known: set[str] = set()                         # exact keys read in this process (in memory only)
_known_lock = threading.Lock()
GENERIC_MASK = "***"

# Narrow shapes of the external-ASR credentials: each one needs a marker that ordinary text does not have (a scheme word
# followed by a long token, a fixed prefix plus structure, a PEM fence, a header name), so a title like "Bearer token rotation sync" or
# "eyJ is a base64 prefix" comes out unchanged. Order matters: the PEM block first (`_mask_pem`: it spans lines; a private key whose END
# line was cut off, as in a truncated log line, is masked to the end of the text), the specific bearer shape before the generic one.
# redact() sees every log record, state write and claude result, and the text can come from a hostile server: each shape must cost
# time LINEAR in the text. A pattern that rescans a long run (or the rest of the text) for every start it finds does not (hence the
# lookbehind of the JWT shape: a start only at the beginning of a run of token characters, and the hand-written PEM scan).
_PEM_BEGIN = "-----BEGIN "
_PEM_END = "-----END "
_PEM_HEADER = re.compile(r"-----BEGIN [A-Z0-9 ]{1,40}-----")
_PEM_KEY_HEADER = re.compile(r"-----BEGIN [A-Z0-9 ]{0,30}PRIVATE KEY-----")      # the header of a private key (it may stand alone)
_PEM_FOOTER = re.compile(r"-----END [A-Z0-9 ]{1,40}-----")
_PEM_MASK = "-----BEGIN ***-----"
_NARROW_PATTERNS: tuple = (
    (re.compile(r"(?i:\bBearer)[ \t]+mcap1_[A-Za-z0-9_\-]+"), "Bearer ***"),
    (re.compile(r"(?i:\bBearer)[ \t]+[A-Za-z0-9._~+/=\-]{24,}"), "Bearer ***"),
    (re.compile(r"(?<![A-Za-z0-9])mcap1_[0-9a-f]{8}_[A-Za-z0-9_\-]{16,}"), "mcap1_***"),
    (re.compile(r"(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}(?:\.[A-Za-z0-9_\-]*)?"), "eyJ***"),
    (re.compile(r"(?i)(Ocp-Apim-Subscription-Key[\"']?[ \t]*[:=][ \t]*[\"']?)[^\s\"',;&]+"), r"\1***"),
)
_extra_patterns: list = []                       # (compiled pattern, replacement) added with register_redaction_pattern()


def remember(key: str) -> None:
    """Register an exact key for masking (also masks keys that do not have the sk-ant- shape). A key that contains line breaks is also
    masked in its escaped form (what an exception message shows for it: `repr` turns CR/LF into backslash sequences) and line by line."""
    if isinstance(key, str) and len(key) >= 8:
        variants = {key, key.encode("unicode_escape").decode("ascii")}
        if "\n" in key or "\r" in key:
            variants.update(piece.strip() for piece in re.split(r"[\r\n]+", key))
        with _known_lock:
            _known.update(v for v in variants if len(v) >= 8)


def register_redaction_pattern(regex, replacement: str = GENERIC_MASK) -> None:
    """Mask every match of `regex` (a pattern string or a compiled pattern) with `replacement` (a `re.sub` template) in everything
    `redact()` sees. Idempotent. A pattern that can match the empty string is refused (it would insert the mask everywhere)."""
    pattern = re.compile(regex) if isinstance(regex, str) else regex
    if not hasattr(pattern, "sub") or pattern.search("") is not None:
        raise ValueError("a redaction pattern must be a regex that cannot match the empty string")
    with _known_lock:
        if all(existing.pattern != pattern.pattern or existing.flags != pattern.flags for existing, _ in _extra_patterns):
            _extra_patterns.append((pattern, replacement))


def _mask_pem(text: str) -> str:
    """Every PEM block (from a `-----BEGIN <LABEL>-----` header to the first `-----END <LABEL>-----` footer after it) becomes
    `-----BEGIN ***-----`; a private key header with no footer after it masks everything to the end of the text. The same result as
    the regex `BEGIN-header [\\s\\S]*? END-footer | private-key-header [\\s\\S]*` that stood here, in time linear in the text: the
    footers are found once, so a text with many headers and no footer is not scanned to its end again for each of them."""
    start = text.find(_PEM_BEGIN)
    if start < 0:
        return text
    footers: Optional[list] = None                    # (start, end) of every valid footer, in order; found on the first header that needs it
    footer_starts: list = []
    out: list = []
    pos = 0
    while start >= 0:
        header = _PEM_HEADER.match(text, start)
        if header is not None:
            if footers is None:
                footers, i = [], text.find(_PEM_END)
                while i >= 0:
                    found = _PEM_FOOTER.match(text, i)
                    if found is not None:
                        footers.append((i, found.end()))
                    i = text.find(_PEM_END, i + 1)
                footer_starts = [begin for begin, _end in footers]
            k = bisect.bisect_left(footer_starts, header.end())
            if k < len(footers):
                out.append(text[pos:start])
                out.append(_PEM_MASK)
                pos = footers[k][1]
                start = text.find(_PEM_BEGIN, pos)
                continue
        if _PEM_KEY_HEADER.match(text, start) is not None:
            out.append(text[pos:start])
            out.append(_PEM_MASK)
            return "".join(out)
        start = text.find(_PEM_BEGIN, start + 1)
    out.append(text[pos:])
    return "".join(out)


def redact(text: Any) -> Any:
    """`text` with every sk-ant-... token, every key read in this process, the narrow credential shapes and every registered pattern
    masked. Non-strings are returned unchanged."""
    if not isinstance(text, str) or not text:
        return text
    with _known_lock:
        exact = sorted(_known, key=len, reverse=True)
        extra = list(_extra_patterns)
    for key in exact:
        if key in text:
            text = text.replace(key, MASK)
    text = _KEY_RE.sub(MASK, text)
    text = _mask_pem(text)
    for pattern, replacement in _NARROW_PATTERNS:
        text = pattern.sub(replacement, text)
    for pattern, replacement in extra:
        text = pattern.sub(replacement, text)
    return text


def redact_obj(obj: Any) -> Any:
    """redact() applied to every string inside nested dicts / lists (what state.json and usage.jsonl are written from)."""
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, dict):
        return {k: redact_obj(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [redact_obj(v) for v in obj]
    return obj


class RedactFilter(logging.Filter):
    """logging.Filter that masks keys in the formatted message and in the traceback text of a record. Never drops a record."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:                       # a broken format string must not lose the record
            message = str(record.msg)
        clean = redact(message)
        if clean != message or record.args:
            record.msg, record.args = clean, None
        if record.exc_info and not record.exc_text:
            record.exc_text = logging.Formatter().formatException(record.exc_info)
        if record.exc_text:
            record.exc_text = redact(record.exc_text)
        if record.stack_info:
            record.stack_info = redact(record.stack_info)
        return True


_FILTER = RedactFilter()


def install_log_redaction() -> None:
    """Put the filter on every mcap logger that exists and on every handler of the root and mcap loggers (a logger filter alone
    does not see records of child loggers; a handler filter sees everything that reaches the handler). Idempotent."""
    names = ["mcap"] + [n for n in list(logging.root.manager.loggerDict) if n.startswith("mcap.")]
    for name in names:
        logging.getLogger(name).addFilter(_FILTER)
    for owner in (logging.getLogger(), logging.getLogger("mcap")):
        for handler in owner.handlers:
            handler.addFilter(_FILTER)


# ---------------------------------------------------------------------------------- Keychain access
def security_bin() -> str:
    """/usr/bin/security, or $MCAP_SECURITY_BIN (tests) unless this Mac has an organisation policy: then the variable is ignored."""
    return test_hook_env(SECURITY_BIN_ENV) or DEFAULT_SECURITY_BIN


def keychain_account() -> str:
    return os.environ.get("USER") or getpass.getuser()


def keychain_service(cfg: Any) -> str:
    value = getattr(cfg, "claude_key_service", "")
    return value.strip() if isinstance(value, str) and value.strip() else DEFAULT_SERVICE


def _security_env() -> dict:
    return {"HOME": os.path.expanduser("~"), "USER": keychain_account(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8"}


@dataclass
class Lookup:
    key: Optional[str] = field(repr=False)     # repr=False: str()/repr()/an f-string of a Lookup must never print the key
    reason: str            # ok | missing | timeout | error | no_tool
    detail: str = ""


def lookup(cfg: Config) -> Lookup:
    """`security find-generic-password -s <service> -a <user> -w`: stderr is discarded (it can name the item), the answer is the
    key plus a newline."""
    argv = [security_bin(), "find-generic-password", "-s", keychain_service(cfg), "-a", keychain_account(), "-w"]
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=READ_TIMEOUT_S, env=_security_env())
    except subprocess.TimeoutExpired:
        return Lookup(None, "timeout")
    except OSError as exc:
        return Lookup(None, "no_tool", exc.strerror or type(exc).__name__)
    text = p.stdout.decode("utf-8", "replace").strip()
    if p.returncode == 0 and text:
        remember(text)
        return Lookup(text, "ok")
    if p.returncode in (0, ITEM_NOT_FOUND_EXIT):
        return Lookup(None, "missing")
    return Lookup(None, "error", f"security exit {p.returncode}")


def item_exists(cfg: Config) -> Optional[bool]:
    """Is there a Keychain item for the key? `security find-generic-password -s <service> -a <user>` WITHOUT -w and -g: only the attributes
    come back (discarded here), the secret is not read and the access list of the item is not consulted, so no Keychain dialog can appear.
    True / False; None when nobody could answer (timeout, tool missing, any exit other than found / not found). The first-run helper of the
    app installer asks this (`api-key status --exists`) instead of reading the key."""
    argv = [security_bin(), "find-generic-password", "-s", keychain_service(cfg), "-a", keychain_account()]
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=READ_TIMEOUT_S, env=_security_env())
    except (subprocess.TimeoutExpired, OSError):
        return None
    if p.returncode == 0:
        return True
    return False if p.returncode == ITEM_NOT_FOUND_EXIT else None


def read_key(cfg: Config) -> Optional[str]:
    """The key from the Keychain, or None (missing, unreadable, timeout). Call it only right before it is used."""
    return lookup(cfg).key


def _unavailable_message(found: Lookup) -> str:
    """One line (with the fix) for a lookup that returned no key."""
    if found.reason == "timeout":
        return (f"The Keychain did not answer within {int(READ_TIMEOUT_S)} s (a permission dialog may be waiting in "
                "Keychain Access): then run mcap api-key status")
    if found.reason == "error":
        return f"The Keychain could not be read ({found.detail}): run mcap api-key status"
    return NOT_FOUND_MESSAGE


def usable_key(cfg: Config) -> tuple[Optional[str], str]:
    """(key, "") when the Keychain holds something shaped like an Anthropic key, else (None, one-line reason with the fix)."""
    found = lookup(cfg)
    if not found.key:
        return None, _unavailable_message(found)
    if not found.key.startswith(KEY_PREFIX):
        return None, BAD_SHAPE_MESSAGE
    return found.key, ""


class KeyUnavailable(Exception):
    """api mode, but no usable key in the Keychain (str(exc) is the one-line message with the fix)."""


@dataclass
class KeyStatus:
    service: str
    account: str
    present: bool
    prefix_ok: bool = False
    length: int = 0
    reason: str = ""           # why it is not present (missing | timeout | error | no_tool)
    message: str = ""

    @property
    def usable(self) -> bool:
        return self.present and self.prefix_ok


def key_status(cfg: Config) -> KeyStatus:
    """Is there a key, does it look like one (sk-ant- prefix), how long is it. NEVER the value."""
    found = lookup(cfg)
    service, account = keychain_service(cfg), keychain_account()
    if not found.key:
        return KeyStatus(service, account, False, reason=found.reason, message=_unavailable_message(found))
    ok = found.key.startswith(KEY_PREFIX)
    return KeyStatus(service, account, True, prefix_ok=ok, length=len(found.key), message="" if ok else BAD_SHAPE_MESSAGE)


def format_status(st: KeyStatus) -> list[str]:
    lines = [f"  service:   {st.service}", f"  account:   {st.account}"]
    if st.present:
        lines.append(f"  key:       present, {st.length} characters, " + ("starts with sk-ant- (looks like an Anthropic key)"
                                                                         if st.prefix_ok else "does NOT start with sk-ant-"))
    else:
        lines.append(f"  key:       not available ({st.message})")
    lines.append("  validated: no, this only looks at the Keychain item: run mcap api-key check (one tiny paid call)")
    return lines


# ---------------------------------------------------------------------------------- set / forget (terminal only)
def set_key_interactive(cfg: Config) -> int:
    """Store the key: `security add-generic-password -U -a <user> -s <service> -w` with stdin/stdout/stderr inherited, so the
    macOS tool itself prompts for the key on the terminal (no echo). No key on argv and none through this process. Refused
    unless stdin is a terminal. Exit codes: 0 stored, 1 the tool failed, 2 not a terminal."""
    stdin = sys.stdin
    if stdin is None or not stdin.isatty():
        print("error: mcap api-key set must run in a terminal (stdin is not a TTY): open Terminal and run `make set-api-key`",
              file=sys.stderr)
        return 2
    service, account = keychain_service(cfg), keychain_account()
    if security_bin() != DEFAULT_SECURITY_BIN:
        # a test shim in the environment (a leftover `export MCAP_SECURITY_BIN=...`) would be handed the key you are about to type
        print(f"WARNING: ${SECURITY_BIN_ENV} is set: the key would be typed into {security_bin()} instead of {DEFAULT_SECURITY_BIN}. "
              f"Press Ctrl-C now and run `unset {SECURITY_BIN_ENV}` unless that is what you want.", file=sys.stderr, flush=True)
    print(f"Storing the Anthropic API key in the macOS Keychain (service '{service}', account '{account}').\n"
          "The macOS security tool asks for the key now; what you type is not shown and never goes through this program.",
          flush=True)
    try:
        rc = subprocess.run([security_bin(), "add-generic-password", "-U", "-a", account, "-s", service, "-w"],
                            env=_security_env()).returncode
    except OSError as exc:
        print(f"error: cannot run {security_bin()}: {exc.strerror or exc}", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"error: the security tool exited with {rc}: nothing was stored (or the update was refused)", file=sys.stderr)
        return 1
    st = key_status(cfg)
    if not st.present:
        print("warning: the security tool reported success but the item cannot be read back: " + st.message, file=sys.stderr)
        return 1
    print(f"Stored ({st.length} characters).")
    if not st.prefix_ok:
        print("warning: the stored value does not start with sk-ant-: check that you pasted an API key from the Console "
              "(Settings > API keys) and run make set-api-key again", file=sys.stderr)
    print("Next: `mcap api-key check` validates it with one tiny call (about a tenth of a cent).")
    return 0


def forget_key(cfg: Config) -> int:
    """Delete the Keychain item. 0 deleted or nothing there, 1 the tool failed."""
    service, account = keychain_service(cfg), keychain_account()
    try:
        p = subprocess.run([security_bin(), "delete-generic-password", "-s", service, "-a", account], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=READ_TIMEOUT_S, env=_security_env())
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"error: cannot run the security tool: {type(exc).__name__}", file=sys.stderr)
        return 1
    if p.returncode == 0:
        print(f"Deleted the Keychain item (service '{service}', account '{account}').")
        return 0
    if p.returncode == ITEM_NOT_FOUND_EXIT:
        print(f"Nothing to delete: no Keychain item (service '{service}', account '{account}').")
        return 0
    print(f"error: the security tool exited with {p.returncode}: the item was not deleted", file=sys.stderr)
    return 1
