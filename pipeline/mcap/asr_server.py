"""mcap-asr/1 reference server: the company ASR relay (docs/ASR_PROTOCOL.md; SPEC 18). Run it with ``python -m mcap.asr_server`` (``serve``, ``token``, ``enroll-code``,
``audit``, ``selfcheck``); the LaunchDaemon files are in scripts/asr_server.

Importing this module opens no socket, reads no file, starts no process and loads no model; nothing here runs on a laptop unless an
operator starts ``serve`` on a server Mac. The default local pipeline never imports it.

What the server is: one chunk of 16 kHz mono int16 PCM per request (or one batch of short language-ID clips), one engine worker, a fair
round-robin queue over tokens, per-token quotas, and a JSON answer. What it never does: store audio, text or a token. The request body
lives in memory until the answer is built and is then dropped; there is no spool, no temp file, no database; core dumps are switched
off at start (``harden_process``). The only copies of transcript text are the answers in the 120 second idempotency cache (memory only)
and the answer on the wire. The only files are the ones in ``secrets_dir`` (token table with SHA-256 digests, enrollment codes as digests,
the private TLS key; all 0600, the directory 0700: the documented server-tier exception to the Keychain rule) and the
content-free metadata log in ``log_dir`` (one JSON object per request: who, which operation, how many samples, how long; never audio,
text, titles, session ids, tokens or a client address beyond a coarse network). Lines of requests that cost the server almost nothing
(refusals, failed enrollments, vocabulary PUTs, purges) are written within a budget per token or source network and only counted beyond
it (one server-log line a minute reports the count), so a flood of them cannot fill the disk.

Layout of the module
  * ``ServerConfig`` / ``load_server_config``: asr-server.json (strict: an unknown key or a value out of range refuses to start).
  * ``TokenTable`` / ``CodeTable``: the 0600 files, re-read when they change, updated with flock + atomic rename so the daemon and the
    admin commands never lose each other's writes. A ``revoked`` or ``disabled`` mark of any kind (not just a well-formed one) locks a
    row. A renewal is only possible with an expires_in_days of 14 or less and only once per token, rows that have been dead for 30 days are dropped
    when the table is written, and a write that would grow a table past 4 MiB fails instead of the table being refused as a whole.
  * ``MetaLog`` / ``Quotas`` / ``FairQueue`` / ``ServerState``: the core. ``handle_request(state, method, path, headers, body, now)``
    is the pure entry point the tests (and an in-process Transport) call; ``ServerState.admit`` validates headers, token, lengths
    and capacity BEFORE a body is read, ``ServerState.complete`` runs the request.
  * ``serve`` / ``make_server``: a small HTTP/1.1 front end on ``socketserver`` with the deadlines of the protocol (headers 10 s, body
    30 s, whole request 120 s, 16 unauthenticated connections, 10 s idle, and per token its concurrency + 2 open connections from the
    moment its head is accepted), optional TLS 1.2+, one request per connection.
  * ``run_selfchecks``, ``scan_for_content`` / ``audit``, ``main``: startup checks, the content scan, the admin CLI.

Backends: ``backend`` of the config names an engine of ``asr_engines.REGISTRY`` (``whisper`` = the local MLX WhisperEngine, the
default; later ``faster-whisper``, ``azure``). ``default_backend_factory`` builds ``engine_class(backend)``: through the class method
``for_server(options, *, model, secrets_dir)`` when the class has one (an HTTP-based relay backend gets its host, its secret file and its
own EgressGuard there), else as ``cls(model, allow_download=False, **backend_options)``. An optional engine method
``set_request_terms(terms)`` is called before each chunk with the vocabulary the request named (a phraseList for a backend that builds
no prompt) and ``vendor_info()`` fills ``health.vendor``; both are looked up with ``getattr``.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import hmac
import ipaddress
import json
import logging
import math
import os
import re
import resource
import secrets
import signal
import socket
import socketserver
import ssl
import stat as statmod
import sys
import threading
import time
from collections import Counter, OrderedDict, defaultdict, deque
from dataclasses import dataclass, field
from http import HTTPStatus
from pathlib import Path
from typing import Any, Callable, Mapping, Optional
from urllib.parse import parse_qs, urlsplit

import numpy as np

from . import apikey, asr, asr_creds
from .asr_engines import REVISION_PINS, WHISPER_LANGUAGE_CODES, EngineUnavailable, engine_class, parse_languages
from .vocab import Vocab

log = logging.getLogger("mcap.asr_server")

PROTO = "mcap-asr/1"
SUPPORTED = [PROTO]
SAMPLE_RATE = 16000
MAX_CHUNK_SAMPLES = 496000                    # 31 s: the client plans chunks of 28 s or less
MAX_LID_CLIPS = 12
MAX_LID_CLIP_SAMPLES = 96000                  # 6 s per clip
MAX_VOCAB_BYTES = 64 * 1024
MAX_VOCAB_TERMS = 2000
MAX_TERM_CHARS = 200
MAX_SMALL_BODY = 1024                         # enroll, renew, purge
MAX_RESPONSE_BYTES = 250_000                  # the client refuses an answer over 256 KB: an over-long one is an error, never cut text
IDEM_TTL_S = 120.0
IDEM_PER_TOKEN = 256
VOCAB_PER_TOKEN = 16
RENEW_OVERLAP_S = 24 * 3600
RPM_WINDOW_S = 60.0
FLUSH_EVERY_S = 60.0                          # last-used time of a token is written at most this often (a changed machine at once)
ENROLL_FAILS_PER_SOURCE = 5
ENROLL_FAILS_GLOBAL = 50
ENROLL_WINDOW_S = 600.0
REQUEST_DEADLINE_S = 120.0
HEADER_DEADLINE_S = 10.0
BODY_DEADLINE_S = 30.0
IDLE_S = 10.0
MAX_UNAUTH_CONNECTIONS = 16
MAX_CONNECTIONS = 256
CONNECTION_MARGIN = 2                         # open connections of one token = its concurrency + this (a health check, a vocabulary PUT)
MAX_HEAD_BYTES = 16 * 1024
MAX_HEADERS = 64
MAX_TABLE_BYTES = 4 * 1024 * 1024             # a write that would GROW a token table past this fails (issue, renew); a larger file is still read
MAX_READ_BYTES = 32 * 1024 * 1024             # only a file past this is refused as a table (a table that merely grew large must not lock everyone out)
RENEW_DAYS = 14                               # a token can be renewed when its health `expires_in_days` (whole days, rounded down) is this or less
DEAD_ROW_KEEP_S = 30 * 86400                  # a row that has been revoked or expired this long is dropped when the table is next written
LOG_REJECTS_PER_TOKEN = 30                    # metadata lines per token and LOG_REJECT_WINDOW_S for refusals, vocabulary PUTs and purges
LOG_REJECT_WINDOW_S = 60.0
LOG_ENROLL_FAILS_PER_SOURCE = 10              # metadata lines per source network and ENROLL_WINDOW_S for failed enrollments
LOG_ENROLL_FAILS_GLOBAL = 60
LOG_BUDGET_KEYS = 1024
REPORT_EVERY_S = 60.0                         # one server-log line a minute for what was counted instead of logged
SCAN_FILE_LIMIT = 200_000                     # files the audit looks at in one directory tree before it reports that it stopped
SCAN_LOG_BYTES = 64 * 1024 * 1024             # bytes of one log file the audit reads before it reports that it stopped
LOG_LABEL_CHARS = 80
DEFAULT_SECRETS_DIR = "/Library/Application Support/MeetingCapture-asr"
DEFAULT_LOG_DIR = "/Library/Logs/MeetingCapture-asr"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-mlx"       # Config.asr_model (a test pins the two together)
CONFIG_ENV = "MCAP_ASR_SERVER_CONFIG"
META_KEYS = ("ts", "user", "token_id", "op", "samples", "audio_s", "status", "queue_ms", "dur_ms", "engine", "bytes_in", "src_net",
             "machine_changed")
AUDIO_EXTENSIONS = frozenset(".wav .m4a .mp3 .flac .ogg .opus .aac .caf .aif .aiff .amr .wma .webm .mp4 .mov .pcm .raw .sph".split())

_ERRORS: dict[str, tuple[int, str]] = {
    "bad_request": (400, "the request is malformed"),
    "unauthorized": (401, "the token is missing, unknown, revoked or expired"),
    "enroll_invalid": (401, "the enrollment code is wrong, used or expired"),
    "forbidden": (403, "the token is disabled"),
    "not_found": (404, "there is no such endpoint"),
    "vocab_unknown": (404, "the vocabulary is not on the server"),
    "method_not_allowed": (405, "the method is not allowed for this endpoint"),
    "request_timeout": (408, "the request was not received in time"),
    "idem_conflict": (409, "the idempotency key was used with a different body"),
    "length_required": (411, "a Content-Length header is required"),
    "payload_too_large": (413, "the request is over the limits"),
    "unsupported_media_type": (415, "the media type is not supported"),
    "unprocessable_audio": (422, "the audio cannot be processed"),
    "proto_mismatch": (426, "the protocol version is not supported"),
    "quota_exceeded": (429, "a per-token quota is used up"),
    "enroll_throttled": (429, "too many failed enrollment attempts"),
    "engine_error": (500, "the engine failed"),
    "busy": (503, "the server is busy"),
    "engine_timeout": (504, "the engine did not answer in time"),
}


class ApiError(Exception):
    """An answer with an error status. ``str()`` is the status and code only: never a header value, a body or content."""

    def __init__(self, code: str, retry_after: Optional[int] = None, *, extra: Optional[dict] = None):
        self.code = code
        self.status, self.message = _ERRORS[code]
        self.retry_after = None if retry_after is None else max(1, int(retry_after))
        self.extra = extra or {}
        self.adm: Optional["Admission"] = None
        super().__init__(f"{self.status} {code}")


class ConfigError(ValueError):
    """asr-server.json cannot be used (the message names the key and the rule, never a value that could be a secret)."""


class TableError(RuntimeError):
    """A token or code file cannot be used safely (not private, not readable, not valid). The message is fixed text plus the file name."""


# ======================================================================================================================
# time and small helpers
# ======================================================================================================================
def _epoch(now: Any) -> float:
    """``now`` (aware or naive datetime, epoch seconds, or None for the wall clock) as epoch seconds. A naive datetime is local time."""
    if now is None:
        return time.time()
    if isinstance(now, dt.datetime):
        return (now.astimezone() if now.tzinfo is None else now).timestamp()
    return float(now)


def _iso(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def _parse_iso(text: Any) -> Optional[float]:
    if not isinstance(text, str):
        return None
    try:
        moment = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    return (moment.astimezone() if moment.tzinfo is None else moment).timestamp()


def _day(ts: float) -> str:
    """The local calendar day of an epoch time (the quota day)."""
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def _seconds_to_midnight(ts: float) -> int:
    moment = dt.datetime.fromtimestamp(ts)
    nxt = (moment + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(1, math.ceil(nxt.timestamp() - ts))


def src_net(peer: Any) -> Optional[str]:
    """The coarse source network of a peer address (IPv4 /24, IPv6 /48); None for anything that is not an address. Nothing finer is kept."""
    if not peer:
        return None
    try:
        ip = ipaddress.ip_address(str(peer).split("%", 1)[0])
    except ValueError:
        return None
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return str(ipaddress.ip_network((ip, 24 if ip.version == 4 else 48), strict=False))


def _label(text: Any) -> str:
    """A user label made safe for a log line and a JSON field: printable, one line, bounded."""
    clean = "".join(ch for ch in str(text) if ch.isprintable())
    return clean.strip()[:LOG_LABEL_CHARS]


def _num(value: Any) -> Optional[float]:
    """A finite number or None (bool, NaN, infinity and text are not numbers for the answer)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def _dumps(obj: Any) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def canonical_vocab_digest(obj: Any) -> str:
    """The digest of ``PUT /v1/vocab/{sha256}`` (docs/ASR_PROTOCOL.md 12.1): sha256 of the compact, key-sorted, non-ASCII-preserving JSON."""
    return hashlib.sha256(json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")).hexdigest()


def _reply(status: int, payload: Any = None, *, retry_after: Optional[int] = None) -> tuple[int, dict, bytes]:
    """(status, headers, body) of an answer. ``payload`` is a JSON-able object, ready bytes, or None (no body: 204)."""
    body = payload if isinstance(payload, (bytes, bytearray)) else (b"" if payload is None else _dumps(payload))
    headers = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-MCAP-Proto": PROTO}
    if status != 204:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    if retry_after is not None:
        headers["Retry-After"] = str(int(retry_after))
    return status, headers, bytes(body)


def error_reply(exc: ApiError) -> tuple[int, dict, bytes]:
    body = {"error": {"code": exc.code, "message": exc.message, "retry_after_s": exc.retry_after}}
    body.update(exc.extra)
    status, headers, data = _reply(exc.status, body, retry_after=exc.retry_after)
    if exc.status == 401:
        headers["WWW-Authenticate"] = "Bearer"
    return status, headers, data


# ======================================================================================================================
# configuration (asr-server.json)
# ======================================================================================================================
@dataclass(frozen=True)
class ServerConfig:
    """asr-server.json. Every default is the documented one; the file is strict (see ``config_from_dict``)."""
    listen: str = "127.0.0.1:8443"
    tls_cert: str = ""
    tls_key: str = ""
    secrets_dir: str = DEFAULT_SECRETS_DIR
    log_dir: str = DEFAULT_LOG_DIR
    backend: str = "whisper"
    model: str = ""
    backend_options: Mapping = field(default_factory=dict)
    max_queue: int = 64
    max_wait_s: int = 45
    per_token_concurrency: int = 2
    per_token_audio_s_per_day: int = 43200
    per_token_rpm: int = 120
    token_ttl_days: int = 90
    enroll_code_ttl_s: int = 600
    metadata_log_days: int = 400
    initial_service_s: float = 4.0
    ext: Mapping = field(default_factory=dict)

    @property
    def tokens_path(self) -> str:
        return os.path.join(self.secrets_dir, "tokens.json")

    @property
    def codes_path(self) -> str:
        return os.path.join(self.secrets_dir, "enroll-codes.json")

    @property
    def listen_address(self) -> tuple[str, int]:
        return parse_listen(self.listen)

    @property
    def tls(self) -> bool:
        return bool(self.tls_cert and self.tls_key)

    def effective_sha256(self) -> str:
        """sha256 of the effective settings (what ``health.attest.config_sha256`` reports): changes when any setting changes."""
        data = {k: (dict(v) if isinstance(v, Mapping) else v) for k, v in self.__dict__.items()}
        return hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=True).encode("utf-8")).hexdigest()


_INT_RULES: dict[str, tuple[int, int]] = {
    "max_queue": (1, 1024), "max_wait_s": (1, 110), "per_token_concurrency": (1, 16), "per_token_audio_s_per_day": (1, 604800),
    "per_token_rpm": (1, 6000), "token_ttl_days": (1, 3650), "enroll_code_ttl_s": (30, 86400), "metadata_log_days": (1, 3650),
}
_BACKEND = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}\Z")


def parse_listen(text: str) -> tuple[str, int]:
    """``host:port`` or ``[v6]:port`` -> (host, port). The host is an IP literal or ``localhost``; port 0 asks the OS for one (tests)."""
    if not isinstance(text, str) or not text:
        raise ConfigError("listen must be host:port")
    host, sep, port_text = text.rpartition(":")
    if not sep or not port_text.isascii() or not port_text.isdigit() or int(port_text) > 65535:
        raise ConfigError("listen must be host:port with a port of 0 to 65535")
    host = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    if host != "localhost":
        try:
            ipaddress.ip_address(host)
        except ValueError:
            raise ConfigError("listen host must be an IP address or localhost") from None
    return host, int(port_text)


def is_loopback_host(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or bool(getattr(ip, "ipv4_mapped", None) and ip.ipv4_mapped.is_loopback)


def config_from_dict(obj: Any) -> ServerConfig:
    """Validate a parsed asr-server.json. Strict like the policy file: an unknown key (outside ``ext``), a wrong type or a value out of
    range raises ``ConfigError`` (a typo that silently drops a limit is worse than a server that does not start)."""
    if not isinstance(obj, dict):
        raise ConfigError("the config must be a JSON object")
    known = {f for f in ServerConfig.__dataclass_fields__}
    for key in obj:
        if key not in known:
            raise ConfigError(f"unknown key {key!r}")
    values: dict[str, Any] = {}
    for key, value in obj.items():
        if key in _INT_RULES:
            low, high = _INT_RULES[key]
            if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
                raise ConfigError(f"{key} must be an integer from {low} to {high}")
        elif key == "initial_service_s":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0.1 <= value <= 600:
                raise ConfigError("initial_service_s must be a number from 0.1 to 600")
            value = float(value)
        elif key in ("backend_options", "ext"):
            if not isinstance(value, dict) or any(not isinstance(k, str) for k in value):
                raise ConfigError(f"{key} must be a JSON object")
        elif key == "backend":
            if not isinstance(value, str) or not _BACKEND.fullmatch(value):
                raise ConfigError("backend must be an engine id such as whisper")
        elif key == "model":
            if not isinstance(value, str) or len(value) > 300 or any(ord(ch) < 32 for ch in value):
                raise ConfigError("model must be a short string")
        else:                                                      # listen, tls_cert, tls_key, secrets_dir, log_dir
            if not isinstance(value, str):
                raise ConfigError(f"{key} must be a string")
            if key in ("tls_cert", "tls_key", "secrets_dir", "log_dir") and value and not os.path.isabs(value):
                raise ConfigError(f"{key} must be an absolute path")
        values[key] = value
    cfg = ServerConfig(**values)
    parse_listen(cfg.listen)
    if bool(cfg.tls_cert) != bool(cfg.tls_key):
        raise ConfigError("tls_cert and tls_key go together")
    if not cfg.secrets_dir or not cfg.log_dir:
        raise ConfigError("secrets_dir and log_dir must not be empty")
    return cfg


def _no_duplicate_keys(pairs: list) -> dict:
    out: dict = {}
    for key, value in pairs:
        if key in out:
            raise ConfigError(f"duplicate key {key!r}")
        out[key] = value
    return out


def load_server_config(path: Any) -> ServerConfig:
    """Read and validate a config file (at most 64 KiB, UTF-8 JSON, no duplicate keys)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(64 * 1024 + 1)
    except OSError as exc:
        raise ConfigError(f"cannot read the config file ({type(exc).__name__})") from None
    if len(data) > 64 * 1024:
        raise ConfigError("the config file is over 64 KiB")
    try:
        obj = json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicate_keys)
    except ConfigError:
        raise
    except ValueError:
        raise ConfigError("the config file is not valid UTF-8 JSON") from None
    return config_from_dict(obj)


# ======================================================================================================================
# private files: the token table, the enrollment codes, the metadata log
# ======================================================================================================================
def private_dir_problem(path: Any, *, euid: Optional[int] = None) -> Optional[str]:
    """Why ``path`` is not a private directory (a plain directory, no group or other permission bits, owned by the service user; root
    may administer), or None."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return "does not exist"
    except OSError:
        return "cannot be read"
    if statmod.S_ISLNK(info.st_mode) or not statmod.S_ISDIR(info.st_mode):
        return "is not a plain directory"
    if info.st_mode & 0o077:
        return f"has mode {info.st_mode & 0o777:04o} (it must be 0700)"
    me = os.geteuid() if euid is None else euid
    if info.st_uid != me and me != 0:
        return "is owned by another user"
    return None


def private_file_problem(path: Any, *, owner_uid: int) -> Optional[str]:
    """Why ``path`` is not a private file (regular, no group or other bits, owned by ``owner_uid``), or None."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return "does not exist"
    except OSError:
        return "cannot be read"
    if not statmod.S_ISREG(info.st_mode):
        return "is not a regular file"
    if info.st_mode & 0o077:
        return f"has mode {info.st_mode & 0o777:04o} (it must be 0600)"
    if info.st_uid != owner_uid:
        return "is owned by another user"
    return None


def _adopt(fd_or_path: Any, directory: str) -> None:
    """When root writes into the service directory, the new file belongs to the directory's owner (the daemon runs as that user)."""
    if os.geteuid() != 0:
        return
    info = os.stat(directory)
    if isinstance(fd_or_path, int):
        os.fchown(fd_or_path, info.st_uid, info.st_gid)
    else:
        os.chown(fd_or_path, info.st_uid, info.st_gid)


@contextlib.contextmanager
def _file_lock(path: str):
    fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
    try:
        _adopt(fd, os.path.dirname(path))
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)                                  # closing the descriptor releases the lock


def _write_private(path: str, data: bytes) -> None:
    """Replace ``path`` atomically with a 0600 file holding ``data`` (temp file in the same directory, fsync, rename)."""
    tmp = f"{path}.tmp-{os.getpid()}-{secrets.token_hex(3)}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        _adopt(fd, os.path.dirname(path))
    finally:
        os.close(fd)
    os.replace(tmp, path)


class _JsonTable:
    """A 0600 JSON file ``{"schema": 1, KEY: [row, ...]}`` that a daemon and admin commands both change: ``update`` holds a flock, reads,
    lets the caller edit the rows, and replaces the file atomically."""
    KEY = "rows"

    def __init__(self, path: Any):
        self.path = os.fspath(path)

    def _name(self) -> str:
        return os.path.basename(self.path)

    def read_raw(self) -> list:
        """The rows ([] when the file does not exist). ``TableError`` when the directory or the file is not private or the content is
        not a valid table (fail closed: nobody authenticates against a table that cannot be trusted)."""
        directory = os.path.dirname(self.path) or "."
        problem = private_dir_problem(directory)
        if problem:
            raise TableError(f"{self._name()}: the directory {problem}")
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            return []
        except OSError:
            raise TableError(f"{self._name()}: the file cannot be opened") from None
        try:
            info = os.fstat(fd)
            if not statmod.S_ISREG(info.st_mode) or info.st_mode & 0o077:
                raise TableError(f"{self._name()}: the file is not a private regular file (0600)")
            if info.st_uid != os.stat(directory).st_uid:
                raise TableError(f"{self._name()}: the file is owned by another user than its directory")
            if info.st_size > MAX_READ_BYTES:
                raise TableError(f"{self._name()}: the file is too large")
            with os.fdopen(os.dup(fd), "rb") as fh:
                data = fh.read(MAX_READ_BYTES + 1)
        finally:
            os.close(fd)
        if len(data) > MAX_READ_BYTES:
            raise TableError(f"{self._name()}: the file is too large")
        try:
            obj = json.loads(data.decode("utf-8"))
        except ValueError:
            raise TableError(f"{self._name()}: the file is not valid JSON") from None
        rows = obj.get(self.KEY) if isinstance(obj, dict) and obj.get("schema") == 1 else None
        if not isinstance(rows, list) or any(not isinstance(r, dict) for r in rows):
            raise TableError(f"{self._name()}: the file has an unexpected shape")
        return rows

    def _serialize(self, rows: list) -> bytes:
        return json.dumps({"schema": 1, self.KEY: rows}, ensure_ascii=True, indent=1).encode("utf-8")

    def update(self, mutator: Callable[[list], tuple[Any, bool]], *, grow_limit: Optional[int] = None) -> Any:
        """``mutator(rows) -> (result, changed)`` edits the rows in place; the file is only rewritten when ``changed``. With ``grow_limit``
        (token issue and renewal) a write that makes the file bigger AND larger than that many bytes fails with ``TableError`` before
        anything is written: the table is never refused as a whole because it is big, only a write that would grow it is (a revocation
        or a usage update can always be written)."""
        with _file_lock(self.path):
            rows = self.read_raw()
            before = len(self._serialize(rows)) if grow_limit is not None else 0
            result, changed = mutator(rows)
            if changed:
                data = self._serialize(rows)
                if grow_limit is not None and len(data) > grow_limit and len(data) > before:
                    raise TableError(f"{self._name()}: the table is full (revoke tokens or let old ones expire)")
                _write_private(self.path, data)
        return result


_TOKEN_ID = re.compile(r"[0-9a-f]{8}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_MACHINE = re.compile(r"[0-9a-f]{16}\Z")
_BEARER = re.compile(r"(?i:bearer) mcap1_([0-9a-f]{8})_([A-Za-z0-9_-]{32})\Z")
_DUMMY_DIGEST = hashlib.sha256(b"mcap-asr unknown token").hexdigest()


@dataclass
class TokenRow:
    id: str
    user: str
    sha256: str = field(repr=False)
    issued: float
    expires: float
    issuer: str = "admin"
    revoked: Optional[float] = None               # token revoke: 401 like an unknown token
    disabled: Optional[str] = None                # token sync (offboarding): 403 forbidden
    last_used: Optional[float] = None
    machine: Optional[str] = None
    net: Optional[str] = None
    superseded_by: Optional[str] = None

    def status(self, now: float) -> str:
        if self.revoked is not None:
            return "revoked"
        if self.disabled:
            return "disabled"
        return "expired" if now >= self.expires else "active"


def _marked(value: Any) -> bool:
    """Is a ``revoked`` or ``disabled`` mark there? Anything but null and false is a mark (fail closed): ``true``, ``1``, ``"yes"``, a
    timestamp that cannot be parsed, an empty string. A row that somebody edited in a hurry stays locked, never open."""
    return value is not None and value is not False


def _row_from_raw(raw: dict) -> Optional[TokenRow]:
    issued, expires = _parse_iso(raw.get("issued")), _parse_iso(raw.get("expires"))
    if (not isinstance(raw.get("id"), str) or not _TOKEN_ID.fullmatch(raw["id"]) or not isinstance(raw.get("sha256"), str)
            or not _SHA256.fullmatch(raw["sha256"]) or not isinstance(raw.get("user"), str) or issued is None or expires is None):
        return None
    machine = raw.get("machine") if isinstance(raw.get("machine"), str) and _MACHINE.fullmatch(raw["machine"]) else None
    revoked: Optional[float] = None
    if _marked(raw.get("revoked")):
        revoked = _parse_iso(raw["revoked"]) if isinstance(raw["revoked"], str) else None
        if revoked is None:
            revoked = 0.0                                  # a mark whose time cannot be read still revokes
    disabled: Optional[str] = None
    if _marked(raw.get("disabled")):
        disabled = (_label(raw["disabled"]) if isinstance(raw["disabled"], str) else "") or "disabled"
    return TokenRow(id=raw["id"], user=_label(raw["user"]), sha256=raw["sha256"], issued=issued, expires=expires,
                    issuer=_label(raw.get("issuer") or "admin"), revoked=revoked, disabled=disabled,
                    last_used=_parse_iso(raw.get("last_used")), machine=machine,
                    net=raw["net"] if isinstance(raw.get("net"), str) else None,
                    superseded_by=raw["superseded_by"] if isinstance(raw.get("superseded_by"), str) else None)


def _prune_dead(rows: list, now: float) -> int:
    """Drop the rows that have been unusable for ``DEAD_ROW_KEEP_S``: revoked, or expired, that long ago (an offboarded or superseded row
    ends by its expiry). The token id is then unknown, which is the same 401 it was before, so nothing becomes valid. A row whose times
    cannot be read stays: it never authenticates and it is evidence. Returns how many were dropped."""
    keep = []
    for entry in rows:
        revoked = _parse_iso(entry.get("revoked")) if isinstance(entry.get("revoked"), str) else None
        ends = [t for t in (_parse_iso(entry.get("expires")), revoked) if t is not None]
        if not ends or min(ends) >= now - DEAD_ROW_KEEP_S:
            keep.append(entry)
    dropped = len(rows) - len(keep)
    if dropped:
        rows[:] = keep
    return dropped


class RenewRefused(Exception):
    """``TokenTable.renew`` said no: ``reason`` is ``unusable`` (revoked, disabled, expired or gone), ``superseded`` (the token has been
    renewed already: its successor is the one to use) or ``too_early`` (its ``expires_in_days`` is still above ``RENEW_DAYS``;
    ``retry_after`` seconds until it is not)."""

    def __init__(self, reason: str, retry_after: Optional[int] = None):
        self.reason, self.retry_after = reason, retry_after
        super().__init__(reason)


class TokenTable(_JsonTable):
    """``tokens.json``: one row per token id with the SHA-256 of the secret (never the secret), user label, issue and expiry time, issuer,
    revoked/disabled marks and the soft-binding data (last use, machine, source network). ``rows()`` re-reads the file when its
    (mtime, ctime, inode, size, mode, owner) changed, so a revocation by an admin command is effective at the next request. A table that cannot be read
    safely is empty (fail closed) and ``problem`` says why."""
    KEY = "tokens"

    def __init__(self, path: Any):
        super().__init__(path)
        self._lock = threading.Lock()
        self._stamp: Any = object()
        self._rows: dict[str, TokenRow] = {}
        self.problem: Optional[str] = None
        self._repeated = 0
        self._pending: dict[str, dict] = {}
        self._last_flush = 0.0

    def _file_stamp(self) -> Any:
        try:
            info = os.lstat(self.path)
        except OSError:
            return None
        return (info.st_mtime_ns, info.st_ctime_ns, info.st_ino, info.st_size, info.st_mode, info.st_uid)       # a chmod or chown shows too

    def rows(self) -> dict[str, TokenRow]:
        with self._lock:
            stamp = self._file_stamp()
            if stamp != self._stamp:
                self._reload(stamp)
            return self._rows

    def _reload(self, stamp: Any) -> None:
        try:
            raw = self.read_raw()
        except TableError as exc:
            rows, problem = {}, str(exc)
        else:
            rows, problem = {}, None
            repeated: set[str] = set()
            for entry in raw:
                row = _row_from_raw(entry)
                if row is not None:
                    if row.id in rows:
                        repeated.add(row.id)
                    rows[row.id] = row
            for token_id in repeated:                       # two rows of one id (a bad merge): which one is meant is unknowable, so neither is
                del rows[token_id]
            if repeated and len(repeated) != self._repeated:
                log.error("token table: %d token id(s) appear twice and are refused", len(repeated))
            self._repeated = len(repeated)
        if problem and problem != self.problem:
            log.error("token table unusable, nobody can authenticate: %s", problem)
        self._stamp, self._rows, self.problem = stamp, rows, problem
        for token_id, fields in self._pending.items():       # soft-binding data not yet written survives a reload
            row = rows.get(token_id)
            if row is not None:
                for name, value in fields.items():
                    setattr(row, name, value)

    def issue(self, user: str, now: float, ttl_days: int, *, issuer: str = "admin", machine: Optional[str] = None) -> tuple[str, TokenRow]:
        """A new token. Returns (the token text, which exists nowhere else, and its row). Only the SHA-256 of the secret is stored."""
        secret = secrets.token_urlsafe(24)                    # 24 bytes -> exactly 32 url-safe characters
        holder: dict = {}

        def mutate(rows: list) -> tuple[None, bool]:
            _prune_dead(rows, now)
            holder["id"] = self._new_id(rows)
            rows.append(self._new_row(holder["id"], user, secret, now, ttl_days, issuer, machine))
            return None, True

        self.update(mutate, grow_limit=MAX_TABLE_BYTES)
        row = self.rows().get(holder["id"])
        if row is None:
            raise TableError(f"{self._name()}: the new token cannot be read back")
        return f"mcap1_{holder['id']}_{secret}", row

    @staticmethod
    def _new_id(rows: list) -> str:
        taken = {r.get("id") for r in rows}
        token_id = secrets.token_hex(4)
        while token_id in taken:
            token_id = secrets.token_hex(4)
        return token_id

    @staticmethod
    def _new_row(token_id: str, user: str, secret: str, now: float, ttl_days: int, issuer: str, machine: Optional[str]) -> dict:
        return {"id": token_id, "user": _label(user), "sha256": hashlib.sha256(secret.encode("ascii")).hexdigest(),
                "issued": _iso(now), "expires": _iso(now + ttl_days * 86400), "issuer": issuer, "revoked": None,
                "disabled": None, "last_used": None, "machine": machine if machine and _MACHINE.fullmatch(machine) else None,
                "net": None, "superseded_by": None}

    def renew(self, old_id: str, now: float, ttl_days: int) -> tuple[str, TokenRow]:
        """A new token for the user of ``old_id``; the old one stays valid for 24 hours, never longer than it already was.

        One step under the file lock, so two renewals of one token cannot both pass: the token must still be usable, must not have been
        renewed already (``superseded_by``) and must show ``expires_in_days`` of ``RENEW_DAYS`` (14) or less in health, which is when the client
        renews at run start (whole days rounded down: up to 14 days 23 h 59 min 59 s left). Otherwise ``RenewRefused``. Without these rules
        one token holder could add a row per request until the table is full."""
        secret = secrets.token_urlsafe(24)
        holder: dict = {}

        def mutate(rows: list) -> tuple[None, bool]:
            entry = next((e for e in rows if e.get("id") == old_id), None)
            current = _row_from_raw(entry) if entry is not None else None
            if current is None or current.status(now) != "active":
                raise RenewRefused("unusable")
            if current.superseded_by:
                raise RenewRefused("superseded")
            left = current.expires - now
            if math.floor(left / 86400) > RENEW_DAYS:         # the same rounding as health's token.expires_in_days
                raise RenewRefused("too_early", math.ceil(left - (RENEW_DAYS + 1) * 86400) + 1)
            _prune_dead(rows, now)
            holder["id"] = self._new_id(rows)
            rows.append(self._new_row(holder["id"], current.user, secret, now, ttl_days, "renew", current.machine))
            limit = now + RENEW_OVERLAP_S
            if current.expires > limit:
                entry["expires"] = _iso(limit)
            entry["superseded_by"] = holder["id"]
            return None, True

        self.update(mutate, grow_limit=MAX_TABLE_BYTES)
        row = self.rows().get(holder["id"])
        if row is None:
            raise TableError(f"{self._name()}: the new token cannot be read back")
        return f"mcap1_{holder['id']}_{secret}", row

    def touch(self, token_id: str, now: float, machine: Optional[str], net: Optional[str]) -> bool:
        """Remember the last use of a token; True when ``machine`` differs from the one seen before (soft binding: never a rejection)."""
        self.rows()
        with self._lock:
            row = self._rows.get(token_id)
            if row is None:
                return False
            changed = bool(machine and row.machine and row.machine != machine)
            row.last_used = now
            fields = {"last_used": now}
            if net:
                row.net = fields["net"] = net
            if machine:
                row.machine = fields["machine"] = machine
            self._pending.setdefault(token_id, {}).update(fields)
        if changed:
            self.flush(now, force=True)
        return changed

    def flush(self, now: float, force: bool = False) -> None:
        """Write the pending soft-binding data (merged into the current file under the lock): at most once a minute, a changed machine
        at once. A failed write is logged and tried again later."""
        with self._lock:
            if not self._pending or (not force and now - self._last_flush < FLUSH_EVERY_S):
                return
            pending, self._pending = self._pending, {}
            self._last_flush = now

        def mutate(rows: list) -> tuple[None, bool]:
            changed = False
            for entry in rows:
                fields = pending.get(entry.get("id"))
                if fields:
                    for name, value in fields.items():
                        entry[name] = _iso(value) if name == "last_used" else value
                    changed = True
            return None, changed

        try:
            self.update(mutate)
        except (TableError, OSError) as exc:
            log.error("token usage not written: %s", type(exc).__name__)
            with self._lock:
                for token_id, fields in pending.items():
                    self._pending.setdefault(token_id, {}).update(fields)


_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def _normalize_code(code: str) -> str:
    return re.sub(r"[\s-]+", "", code).upper()


class CodeTable(_JsonTable):
    """``enroll-codes.json``: one-time enrollment codes, stored as SHA-256 only, each with its user label and expiry."""
    KEY = "codes"

    def issue(self, user: str, now: float, ttl_s: int) -> str:
        """A new code (shown once; ``XXXX-XXXX-XXXX``, 60 bits)."""
        raw = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(12))
        digest = hashlib.sha256(raw.encode("ascii")).hexdigest()

        def mutate(rows: list) -> tuple[None, bool]:
            rows[:] = [r for r in rows if (_parse_iso(r.get("expires")) or 0) > now]
            rows.append({"sha256": digest, "user": _label(user), "issued": _iso(now), "expires": _iso(now + ttl_s)})
            return None, True

        self.update(mutate)
        return "-".join(raw[i:i + 4] for i in range(0, 12, 4))

    def consume(self, code: str, now: float) -> Optional[str]:
        """The user label for a valid, unused, unexpired code, and the code is gone (single use, under the file lock); else None
        (a wrong, used and expired code are indistinguishable)."""
        digest = hashlib.sha256(_normalize_code(code).encode("utf-8", "replace")).hexdigest()

        def mutate(rows: list) -> tuple[Optional[str], bool]:
            alive = [r for r in rows if (_parse_iso(r.get("expires")) or 0) > now]
            found = -1
            for index, row in enumerate(alive):            # every row is compared: the time does not tell which one matched
                if hmac.compare_digest(str(row.get("sha256", "")), digest):
                    found = index
            user = alive[found].get("user") if found >= 0 else None
            if found >= 0:
                del alive[found]
            pruned = len(alive) != len(rows)
            rows[:] = alive
            return (user if isinstance(user, str) else None), pruned or found >= 0

        return self.update(mutate)


class MetaLog:
    """The content-free metadata log (docs/ASR_PROTOCOL.md 10): ``meta-YYYY-MM-DD.jsonl`` in ``log_dir`` (0700), one object per request
    with exactly ``META_KEYS``, ASCII only. Retention ``metadata_log_days``: older day files are deleted."""

    def __init__(self, log_dir: Any, retention_days: int):
        self.dir = os.fspath(log_dir)
        self.retention_days = retention_days

    def path_for(self, day: str) -> str:
        return os.path.join(self.dir, f"meta-{day}.jsonl")

    def append(self, record: dict, ts: float) -> bool:
        if tuple(record) != META_KEYS:
            raise ValueError("a metadata record has exactly the documented keys")
        line = (json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
        try:
            fd = os.open(self.path_for(_day(ts)), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)
        except OSError as exc:
            log.error("metadata log not written: %s", type(exc).__name__)
            return False
        return True

    def days(self) -> list[str]:
        try:
            names = os.listdir(self.dir)
        except OSError:
            return []
        return sorted(m.group(1) for m in (re.fullmatch(r"meta-(\d{4}-\d{2}-\d{2})\.jsonl", n) for n in names) if m)

    def read_day(self, day: str) -> list[dict]:
        """The records of one day; a line that is not a JSON object is skipped."""
        out: list[dict] = []
        try:
            with open(self.path_for(day), "rb") as fh:
                for line in fh:
                    try:
                        obj = json.loads(line.decode("utf-8"))
                    except ValueError:
                        continue
                    if isinstance(obj, dict):
                        out.append(obj)
        except OSError:
            pass
        return out

    def prune(self, now: float) -> int:
        cutoff = _day(now - self.retention_days * 86400)
        removed = 0
        for day in self.days():
            if day < cutoff:
                try:
                    os.unlink(self.path_for(day))
                    removed += 1
                except OSError:
                    pass
        return removed


# ======================================================================================================================
# quotas, queue
# ======================================================================================================================
class Quotas:
    """Per-token limits: requests in flight, requests per minute, audio seconds per local day. Counters are rebuilt from
    the metadata log at start. Called with the state lock held."""

    def __init__(self, cfg: ServerConfig):
        self.cfg = cfg
        self.inflight: Counter = Counter()
        self.recent: dict[str, deque] = defaultdict(deque)
        self.day = ""
        self.used: Counter = Counter()

    def _roll(self, now: float) -> None:
        today = _day(now)
        if today != self.day:
            self.day, self.used = today, Counter()

    def restore(self, metalog: MetaLog, now: float) -> None:
        """Daily seconds and the last minute of requests from today's metadata log (a restart does not reset a token's day)."""
        self._roll(now)
        for rec in metalog.read_day(self.day):
            audio, token_id = _num(rec.get("audio_s")), rec.get("token_id")
            if not audio or audio <= 0 or not isinstance(token_id, str):
                continue
            self.used[token_id] += audio
            ts = _parse_iso(rec.get("ts"))
            if ts is not None and now - RPM_WINDOW_S < ts <= now:
                self.recent[token_id].append(ts)

    def check(self, token_id: str, audio_s: float, now: float) -> Optional[ApiError]:
        self._roll(now)
        if self.inflight[token_id] >= self.cfg.per_token_concurrency:
            return ApiError("quota_exceeded", 1)
        window = self.recent[token_id]
        while window and window[0] <= now - RPM_WINDOW_S:
            window.popleft()
        if len(window) >= self.cfg.per_token_rpm:
            return ApiError("quota_exceeded", math.ceil(window[0] + RPM_WINDOW_S - now))
        if self.used[token_id] + audio_s > self.cfg.per_token_audio_s_per_day:
            return ApiError("quota_exceeded", _seconds_to_midnight(now))
        return None

    def charge(self, token_id: str, audio_s: float, now: float) -> None:
        self._roll(now)
        self.inflight[token_id] += 1
        self.recent[token_id].append(now)
        self.used[token_id] += audio_s

    def release(self, token_id: str) -> None:
        self.inflight[token_id] = max(0, self.inflight[token_id] - 1)


class Job:
    """One accepted request waiting for or running on the engine worker. ``pcm`` is dropped as soon as the engine is done with it."""

    def __init__(self, op: str, token_id: str, pcm: bytes, params: dict, audio_s: float, enqueued: float):
        self.op, self.token_id, self.pcm, self.params, self.audio_s = op, token_id, pcm, params, audio_s
        self.enqueued = enqueued
        self.started: Optional[float] = None
        self.queue_ms = 0
        self.waiters = 1
        self.done = threading.Event()
        self.response: Optional[bytes] = None
        self.error: Optional[ApiError] = None
        self.completed_at = 0.0


class FairQueue:
    """A round-robin queue over tokens: each token has its own FIFO and the worker serves the tokens in turn, so one busy user cannot
    starve the others. ``put`` and the depth figures are used with the state lock held (the condition shares it)."""

    def __init__(self, lock: Any):
        self._cond = threading.Condition(lock)
        self._by_token: dict[str, deque] = {}
        self._ring: deque = deque()
        self.running: Optional[Job] = None
        self._closed = False

    def queued(self) -> int:
        return sum(len(q) for q in self._by_token.values())

    def depth(self) -> int:
        """Jobs ahead of a new one: the waiting ones and the one on the engine."""
        return self.queued() + (1 if self.running is not None else 0)

    def put(self, job: Job) -> None:
        with self._cond:
            queue = self._by_token.get(job.token_id)
            if queue is None:
                queue = self._by_token[job.token_id] = deque()
                self._ring.append(job.token_id)
            queue.append(job)
            self._cond.notify()

    def take(self) -> Optional[Job]:
        with self._cond:
            while not self._ring:
                if self._closed:
                    return None
                self._cond.wait()
            token_id = self._ring[0]
            queue = self._by_token[token_id]
            job = queue.popleft()
            if queue:
                self._ring.rotate(-1)                      # this token goes to the back of the line
            else:
                self._ring.popleft()
                del self._by_token[token_id]
            self.running = job
            return job

    def finish(self) -> None:
        with self._cond:
            self.running = None

    def close(self) -> list[Job]:
        """Stop the worker; the jobs that never started are returned so the caller can answer them."""
        with self._cond:
            self._closed = True
            drained = [job for q in self._by_token.values() for job in q]
            self._by_token.clear()
            self._ring.clear()
            self._cond.notify_all()
            return drained


class _LogBudget:
    """How many metadata lines one key (a token id, a source network) may write per window: ``take`` says yes until the budget is used up.
    The number of keys is bounded too (a key that does not fit shares the key ``*``), so an attacker cannot grow this table either."""

    def __init__(self, limit: int, window_s: float, max_keys: int = LOG_BUDGET_KEYS):
        self.limit, self.window, self.max_keys = limit, window_s, max_keys
        self._by_key: dict[str, deque] = {}

    def take(self, key: str, now: float) -> bool:
        queue = self._by_key.get(key)
        if queue is None:
            if len(self._by_key) >= self.max_keys:
                for stale in [k for k, q in self._by_key.items() if not q or q[-1] <= now - self.window]:
                    del self._by_key[stale]
                if len(self._by_key) >= self.max_keys:
                    key = "*"
            queue = self._by_key.setdefault(key, deque())
        while queue and queue[0] <= now - self.window:
            queue.popleft()
        if len(queue) >= self.limit:
            return False
        queue.append(now)
        return True


class _FailureWindow:
    """Failure times per key within a window (enrollment throttling)."""

    def __init__(self, limit: int, window_s: float):
        self.limit, self.window = limit, window_s
        self._by_key: dict[str, deque] = defaultdict(deque)

    def blocked(self, key: str, now: float) -> int:
        """Seconds to wait when ``key`` has used up its failures, else 0."""
        queue = self._by_key[key]
        while queue and queue[0] <= now - self.window:
            queue.popleft()
        if not queue:
            self._by_key.pop(key, None)
            return 0
        return math.ceil(queue[0] + self.window - now) if len(queue) >= self.limit else 0

    def fail(self, key: str, now: float) -> None:
        self._by_key[key].append(now)


# ======================================================================================================================
# the core
# ======================================================================================================================
@dataclass
class Admission:
    """What ``admit`` decided before the body is read: the route, the token, the lengths and the parsed headers of the request."""
    route: str
    method: str = ""
    t: float = 0.0                                 # request time (epoch seconds)
    t0: float = 0.0                                # state clock when the request was admitted (deadlines, durations)
    peer: Optional[str] = None
    token: Optional[TokenRow] = None
    machine_changed: bool = False
    content_length: int = 0
    op: str = ""
    samples: int = 0
    audio_s: float = 0.0
    idem: Optional[str] = None
    vocab_sha: Optional[str] = None
    detail: bool = False
    params: dict = field(default_factory=dict)
    log_user: Optional[str] = None                 # enroll: who the answer was for
    log_token_id: Optional[str] = None


@dataclass
class _Result:
    status: int
    payload: Any = None
    charged: float = 0.0
    queue_ms: int = 0


class _IdemEntry:
    def __init__(self, body_sha: str, job: Job):
        self.body_sha, self.job = body_sha, job


_METHODS = {"/v1/health": "GET", "/v1/enroll": "POST", "/v1/token/renew": "POST", "/v1/chunk": "POST", "/v1/lid": "POST",
            "/v1/purge": "POST"}
_ROUTE_NAMES = {"/v1/health": "health", "/v1/enroll": "enroll", "/v1/token/renew": "renew", "/v1/chunk": "chunk", "/v1/lid": "lid",
                "/v1/purge": "purge"}
_OPS = {"chunk": "transcribe", "lid": "lid", "vocab": "vocab", "renew": "renew", "purge": "purge", "enroll": "enroll", "health": "health"}
_VOCAB_PATH = re.compile(r"/v1/vocab/([0-9a-f]{64})\Z")
_IDEM = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
_SINGLE = ("authorization", "content-type")
_FORBIDDEN = ("transfer-encoding", "expect", "upgrade")
_MAX_BODY = {"health": 0, "enroll": MAX_SMALL_BODY, "renew": MAX_SMALL_BODY, "purge": MAX_SMALL_BODY, "vocab": MAX_VOCAB_BYTES,
             "chunk": 2 * MAX_CHUNK_SAMPLES, "lid": 2 * MAX_LID_CLIPS * MAX_LID_CLIP_SAMPLES}


def _header_pairs(headers: Any) -> list[tuple[str, str]]:
    """Lower-case (name, value) pairs of a mapping or of a list of pairs (a duplicate stays visible); anything else is malformed."""
    pairs = headers.items() if isinstance(headers, Mapping) else headers
    out = []
    try:
        for name, value in pairs:
            if not isinstance(name, str) or not isinstance(value, str):
                raise ApiError("bad_request")
            out.append((name.lower(), value.strip()))
    except (TypeError, ValueError):
        raise ApiError("bad_request") from None
    return out


class ServerState:
    """Everything the server holds: the token and code tables, the backend engine and its one worker thread, the fair queue, the quotas,
    the idempotency cache and the vocabularies (memory only), the metadata log. ``now_fn`` is the wall clock and ``clock`` the monotonic
    one (both injectable); a request's own time is the ``now`` that ``handle_request`` is given."""

    def __init__(self, cfg: ServerConfig, backend: Any, *, now_fn: Callable[[], float] = time.time,
                 clock: Callable[[], float] = time.monotonic):
        self.cfg, self.backend = cfg, backend
        self.now_fn, self.clock = now_fn, clock
        self.tokens = TokenTable(cfg.tokens_path)
        self.codes = CodeTable(cfg.codes_path)
        self.metalog = MetaLog(cfg.log_dir, cfg.metadata_log_days)
        self.quotas = Quotas(cfg)
        self._lock = threading.RLock()
        self.queue = FairQueue(self._lock)
        self.avg_service_s = float(cfg.initial_service_s)
        self.request_deadline_s = REQUEST_DEADLINE_S
        self._idem: dict[str, OrderedDict] = {}
        self._vocab: dict[str, OrderedDict] = {}
        self._enroll_by_source = _FailureWindow(ENROLL_FAILS_PER_SOURCE, ENROLL_WINDOW_S)
        self._enroll_global = _FailureWindow(ENROLL_FAILS_GLOBAL, ENROLL_WINDOW_S)
        self._worker: Optional[threading.Thread] = None
        self._sweeper: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._auth_failures = 0
        self._auth_logged = 0.0
        self._log_lock = threading.Lock()
        self._reject_budget = _LogBudget(LOG_REJECTS_PER_TOKEN, LOG_REJECT_WINDOW_S)
        self._enroll_log_by_source = _LogBudget(LOG_ENROLL_FAILS_PER_SOURCE, ENROLL_WINDOW_S)
        self._enroll_log_global = _LogBudget(LOG_ENROLL_FAILS_GLOBAL, ENROLL_WINDOW_S)
        self._unlogged = 0
        self._unlogged_reported = 0.0
        self._loaded = False
        self.started = _iso(now_fn())
        self.build_sha256 = build_sha256()
        self.config_sha256 = cfg.effective_sha256()

    # ------------------------------------------------------------------------------------------ life cycle
    def start(self) -> "ServerState":
        """Load the backend, rebuild the quota counters from the metadata log, prune old logs, start the worker."""
        self.backend.load()
        self._loaded = True
        now = self.now_fn()
        self.metalog.prune(now)
        with self._lock:
            self.quotas.restore(self.metalog, now)
        self._worker = threading.Thread(target=self._work, name="asr-engine-worker", daemon=True)
        self._worker.start()
        self._sweeper = threading.Thread(target=self._sweep_loop, name="asr-cache-sweeper", daemon=True)
        self._sweeper.start()
        return self

    def close(self) -> None:
        self._stop.set()
        for job in self.queue.close():
            job.error = ApiError("busy", 1)
            self._finish(job, None)
        for thread in (self._worker, self._sweeper):
            if thread is not None:
                thread.join(timeout=10.0)
        with self._lock:                                    # the answers cached for a retry and the vocabularies go with the process
            self._idem.clear()
            self._vocab.clear()
        try:
            self.tokens.flush(self.now_fn(), force=True)
        finally:
            with contextlib.suppress(Exception):
                self.backend.release()

    def sweep(self, now: Any = None) -> int:
        """Drop every cached answer (of every token) that is older than 120 seconds, so that the transcript text it holds does not outlive
        ``retention.memory_cache_s`` for a token that has gone quiet. Returns how many were dropped."""
        t = self.now_fn() if now is None else _epoch(now)
        removed = 0
        with self._lock:
            for token_id in list(self._idem):
                entries = self._idem[token_id]
                for key in [k for k, e in entries.items() if e.job.done.is_set() and e.job.error is None
                            and t >= e.job.completed_at + IDEM_TTL_S]:
                    del entries[key]
                    removed += 1
                if not entries:
                    del self._idem[token_id]
        return removed

    def _sweep_loop(self) -> None:
        while not self._stop.wait(10.0):
            self.sweep()

    @property
    def ready(self) -> bool:
        return self._loaded and self._worker is not None and self._worker.is_alive()

    # ------------------------------------------------------------------------------------------ admission (before the body)
    def admit(self, method: str, path: str, headers: Any, now: Any = None, *, peer: Optional[str] = None) -> Admission:
        """Everything that can be decided from the request line and the headers: forbidden headers, protocol, route, token, lengths and
        types, the headers of the endpoint, and (advisory) quota and queue capacity. Raises ``ApiError``; the error carries the partial
        admission (``exc.adm``) so the attempt can be logged. No body has been read yet."""
        adm = Admission(route="", method=str(method).upper(), t=_epoch(now) if now is not None else self.now_fn(), t0=self.clock(),
                        peer=peer)
        try:
            self._admit(adm, path, headers)
        except ApiError as exc:
            exc.adm = adm
            raise
        return adm

    def _admit(self, adm: Admission, path: Any, headers: Any) -> None:
        pairs = _header_pairs(headers)
        hdr: dict[str, str] = {}
        for name, value in pairs:
            if name in hdr and (name in ("content-length", "authorization", "content-type") or name.startswith("x-mcap-")):
                raise ApiError("bad_request")              # duplicate Content-Length and friends: the request is ambiguous
            hdr.setdefault(name, value)
        if any(name in hdr for name in _FORBIDDEN) or "," in hdr.get("content-length", ""):
            raise ApiError("bad_request")
        if hdr.get("x-mcap-proto") != PROTO:
            raise ApiError("proto_mismatch", extra={"supported": SUPPORTED})
        if (not isinstance(path, str) or not path.startswith("/") or path.startswith("//") or len(path) > 2048 or not path.isascii()
                or "#" in path):
            raise ApiError("bad_request")
        parts = urlsplit(path)
        route = _ROUTE_NAMES.get(parts.path)
        vocab = _VOCAB_PATH.fullmatch(parts.path)
        if vocab:
            route, adm.vocab_sha = "vocab", vocab.group(1)
            wanted = "PUT"
        elif route:
            wanted = _METHODS[parts.path]
        elif parts.path.startswith("/v1/vocab/"):
            raise ApiError("bad_request")                  # a vocabulary digest that is not 64 lower-case hex characters
        else:
            raise ApiError("not_found")
        if adm.method != wanted:
            raise ApiError("method_not_allowed")
        adm.route, adm.op = route, _OPS[route]
        query = parse_qs(parts.query, keep_blank_values=True) if parts.query else {}
        if route == "health":
            adm.detail = query.get("detail") == ["1"]
        elif parts.query:
            raise ApiError("bad_request")
        if route in ("renew", "vocab", "chunk", "lid", "purge") or adm.detail:
            adm.token = self._authenticate(hdr, adm.t)
            adm.machine_changed = self._soft_bind(adm, hdr.get("x-mcap-machine"))
        # lengths and types
        raw = hdr.get("content-length")
        if wanted in ("POST", "PUT"):
            if raw is None:
                raise ApiError("length_required")
        elif raw not in (None, "0"):
            raise ApiError("bad_request")
        if raw is not None:
            if not raw.isascii() or not raw.isdigit() or len(raw) > 12:
                raise ApiError("bad_request")
            adm.content_length = int(raw)
        if adm.content_length > _MAX_BODY[route]:
            raise ApiError("payload_too_large")
        if hdr.get("content-encoding", "identity").lower() != "identity":
            raise ApiError("unsupported_media_type")
        ctype = hdr.get("content-type", "").split(";", 1)[0].strip().lower()
        if route in ("chunk", "lid"):
            if ctype != "application/octet-stream":
                raise ApiError("unsupported_media_type")
        elif route in ("enroll", "vocab") and ctype not in ("", "application/json"):
            raise ApiError("unsupported_media_type")
        idem = hdr.get("x-mcap-idem")
        if idem is not None and not _IDEM.fullmatch(idem):
            raise ApiError("bad_request")
        adm.idem = idem
        if route == "chunk":
            self._admit_chunk(adm, hdr)
        elif route == "lid":
            self._admit_lid(adm, hdr)
        if route in ("chunk", "lid"):
            with self._lock:                                # advisory: before a body is read; _compute checks again and reserves
                if not (adm.idem and adm.idem in self._idem.get(adm.token.id, ())):      # a replay costs nothing, whatever the quota
                    self._capacity(adm.token.id, adm.audio_s, adm.t, reserve=False)

    def _authenticate(self, hdr: Mapping[str, str], now: float) -> TokenRow:
        match = _BEARER.fullmatch(hdr.get("authorization", ""))
        if not match:
            self._note_auth_failure(now)
            raise ApiError("unauthorized")
        token_id, secret = match.group(1), match.group(2)
        row = self.tokens.rows().get(token_id)
        digest = hashlib.sha256(secret.encode("ascii")).hexdigest()
        if not hmac.compare_digest(digest, row.sha256 if row else _DUMMY_DIGEST) or row is None:
            self._note_auth_failure(now)
            raise ApiError("unauthorized")
        if row.revoked is not None or now >= row.expires:
            self._note_auth_failure(now)
            raise ApiError("unauthorized")
        if row.disabled:
            self._note_auth_failure(now)
            raise ApiError("forbidden")
        return row

    def _note_auth_failure(self, now: float) -> None:
        """Count a failed authentication; a line in the server log (a number, no address, no token) at most once a minute."""
        with self._lock:
            self._auth_failures += 1
            if now - self._auth_logged >= 60.0:
                self._auth_logged, count, self._auth_failures = now, self._auth_failures, 0
                log.warning("authentication failed %d time(s) since the last report", count)

    def _soft_bind(self, adm: Admission, machine: Optional[str]) -> bool:
        """Record the last use, the coarse source network and the machine id; True when the machine changed. Never rejects."""
        machine = machine if machine and _MACHINE.fullmatch(machine) else None
        changed = self.tokens.touch(adm.token.id, adm.t, machine, src_net(adm.peer))
        self.tokens.flush(adm.t)
        return changed

    def _admit_chunk(self, adm: Admission, hdr: Mapping[str, str]) -> None:
        raw = hdr.get("x-mcap-samples", "")
        if not raw.isascii() or not raw.isdigit() or not 0 < len(raw) <= 9 or int(raw) < 1:
            raise ApiError("bad_request")
        samples = int(raw)
        if samples > MAX_CHUNK_SAMPLES:
            raise ApiError("payload_too_large")
        if adm.content_length != 2 * samples:
            raise ApiError("bad_request")
        lang = hdr.get("x-mcap-lang", "auto").strip().lower()
        if lang != "auto" and lang not in WHISPER_LANGUAGE_CODES:
            raise ApiError("bad_request")
        prompt = hdr.get("x-mcap-prompt", "none").strip().lower()
        vocab = hdr.get("x-mcap-vocab")
        if prompt not in ("frame+list", "list", "none") or (vocab is not None and not _SHA256.fullmatch(vocab)):
            raise ApiError("bad_request")
        adm.samples, adm.audio_s = samples, samples / SAMPLE_RATE
        adm.vocab_sha = vocab
        adm.params = {"lang": lang, "langs": self._languages(hdr), "prompt": prompt}

    def _admit_lid(self, adm: Admission, hdr: Mapping[str, str]) -> None:
        if not getattr(self.backend, "supports_lid", False):
            raise ApiError("bad_request")                  # docs/ASR_PROTOCOL.md 12.3: the client then uses its single-label path
        pieces = [p.strip() for p in hdr.get("x-mcap-clips", "").split(",")]
        if any(not (p.isascii() and p.isdigit()) or len(p) > 9 for p in pieces):
            raise ApiError("bad_request")
        counts = [int(p) for p in pieces]
        if any(c < 1 for c in counts):
            raise ApiError("bad_request")
        if len(counts) > MAX_LID_CLIPS or any(c > MAX_LID_CLIP_SAMPLES for c in counts):
            raise ApiError("payload_too_large")
        if adm.content_length != 2 * sum(counts):
            raise ApiError("bad_request")
        adm.samples, adm.audio_s = sum(counts), sum(counts) / SAMPLE_RATE
        adm.params = {"clips": counts, "langs": self._languages(hdr)}

    @staticmethod
    def _languages(hdr: Mapping[str, str]) -> tuple[str, ...]:
        try:
            return parse_languages(hdr.get("x-mcap-langs"))
        except ValueError:
            raise ApiError("bad_request") from None

    def _capacity(self, token_id: str, audio_s: float, now: float, *, reserve: bool) -> None:
        """Per-token quotas, then the queue: 503 busy at once (the connection is not held) when the predicted wait is over ``max_wait_s``
        or the queue is full. ``reserve`` charges the quotas (state lock held)."""
        error = self.quotas.check(token_id, audio_s, now)
        if error:
            raise error
        ahead = self.queue.depth()
        if self.queue.queued() >= self.cfg.max_queue or ahead * self.avg_service_s > self.cfg.max_wait_s:
            raise ApiError("busy", math.ceil(ahead * self.avg_service_s))
        if reserve:
            self.quotas.charge(token_id, audio_s, now)

    # ------------------------------------------------------------------------------------------ running a request
    def complete(self, adm: Admission, body: bytes) -> tuple[int, dict, bytes]:
        """Run an admitted request with its body and return (status, headers, body); every failure becomes an error answer."""
        try:
            result = self._dispatch(adm, body)
        except ApiError as exc:
            return self.fail(exc, adm)
        except TableError as exc:                           # the token table cannot take another row (or cannot be written): try again later
            log.error("token table: %s", exc)
            return self.fail(ApiError("busy", 3600), adm)
        except Exception as exc:                            # a bug must not leak anything: the class name is all that is logged
            log.error("request failed: %s", type(exc).__name__)
            return self.fail(ApiError("engine_error"), adm)
        self._log(adm, result.status, result.charged, result.queue_ms)
        return _reply(result.status, result.payload)

    def fail(self, exc: ApiError, adm: Optional[Admission] = None) -> tuple[int, dict, bytes]:
        adm = adm or exc.adm
        if adm is not None:
            self._log(adm, exc.status, 0.0, 0)
        return error_reply(exc)

    def handle(self, method: str, path: str, headers: Any, body: bytes, now: Any = None, *, peer: Optional[str] = None):
        adm: Optional[Admission] = None
        try:
            adm = self.admit(method, path, headers, now, peer=peer)
            if len(body) != adm.content_length:
                raise ApiError("bad_request")
        except ApiError as exc:
            return self.fail(exc, adm)
        return self.complete(adm, body)

    def _dispatch(self, adm: Admission, body: bytes) -> _Result:
        route = adm.route
        if route == "health":
            return _Result(200, self._health(adm))
        if route == "enroll":
            return self._enroll(adm, body)
        if route == "renew":
            try:
                token, row = self.tokens.renew(adm.token.id, adm.t, self.cfg.token_ttl_days)
            except RenewRefused as refused:
                if refused.reason == "too_early":           # the client renews with 14 days or less left: a rate limit, not a verdict
                    raise ApiError("quota_exceeded", refused.retry_after) from None
                raise ApiError("unauthorized") from None    # revoked since, or already renewed: the successor is the token to use
            return _Result(200, {"token": token, "expires": _iso(row.expires)})
        if route == "vocab":
            return self._put_vocab(adm, body)
        if route == "purge":
            return _Result(200, {"purged": self._purge(adm.token.id)})
        return self._compute(adm, body)

    def _line_wanted(self, adm: Admission, status: int) -> bool:
        """Is this request's metadata line to be written? Lines for requests that cost the server almost nothing (a refusal, a failed
        enrollment, a vocabulary PUT, a purge) are written within a budget per token or source network and only counted beyond it: a flood
        of them must not fill the disk the audit trail lives on. Lines of work that was accepted (a chunk, a language-id request: bounded
        by the quotas and the engine), successful enrollments (bounded by the codes) and renewals (bounded by the renewal rules) are
        always written. What was counted instead of written is reported once a minute (a number only: no token, no address)."""
        with self._log_lock:
            if adm.route == "enroll" and status != 200:
                wanted = self._enroll_log_by_source.take(src_net(adm.peer) or "-", adm.t) and self._enroll_log_global.take("*", adm.t)
            elif adm.route != "enroll" and adm.token is not None and (status >= 400 or adm.route in ("vocab", "purge")):
                wanted = self._reject_budget.take(adm.token.id, adm.t)
            else:
                wanted = True
            if not wanted:
                self._unlogged += 1
            report = 0
            if self._unlogged and adm.t - self._unlogged_reported >= REPORT_EVERY_S:
                self._unlogged_reported, report, self._unlogged = adm.t, self._unlogged, 0
        if report:
            log.warning("%d metadata line(s) of refused or uncharged requests were counted but not written (a flood of requests?)", report)
        return wanted

    def _log(self, adm: Admission, status: int, audio_s: float, queue_ms: int) -> None:
        if adm.route == "health" or (adm.token is None and adm.route != "enroll"):
            return
        if not self._line_wanted(adm, status):
            return
        user = adm.token.user if adm.token else adm.log_user
        token_id = adm.token.id if adm.token else adm.log_token_id
        record = {"ts": _iso(adm.t), "user": user, "token_id": token_id, "op": adm.op, "samples": adm.samples,
                  "audio_s": round(audio_s, 3), "status": status, "queue_ms": queue_ms,
                  "dur_ms": int((self.clock() - adm.t0) * 1000), "engine": self.engine_id, "bytes_in": adm.content_length,
                  "src_net": src_net(adm.peer), "machine_changed": bool(adm.machine_changed)}
        self.metalog.append(record, adm.t)

    # ------------------------------------------------------------------------------------------ small endpoints
    @property
    def engine_id(self) -> str:
        return str(getattr(self.backend, "engine_id", "") or getattr(self.backend, "name", "") or "engine")

    @property
    def backend_kind(self) -> str:
        """What the CLIENT sees as the backend kind: ``cloud`` for a vendor relay, ``server`` for a model that runs on this machine."""
        return "cloud" if getattr(self.backend, "kind", "local") == "cloud" else "server"

    def _model_label(self) -> str:
        model = str(getattr(self.backend, "model", "") or "")
        revision = REVISION_PINS.get(model, "")[:8]
        return f"{model}@{revision}" if revision else model

    def _health(self, adm: Admission) -> dict:
        body: dict = {"proto": PROTO, "ok": self.ready}
        if not adm.detail:
            return body
        model = str(getattr(self.backend, "model", "") or "")
        vendor = None
        if self.backend_kind == "cloud":
            hook = getattr(self.backend, "vendor_info", None)
            vendor = hook() if callable(hook) else {"name": self.engine_id, "region": str(getattr(self.backend, "residency", "")),
                                                    "claim_url": "", "verified": False}
        left = max(0, math.floor((adm.token.expires - adm.t) / 86400))
        body.update({
            "engine": self.engine_id, "model": model, "revision": REVISION_PINS.get(model, "")[:8] or None, "kind": self.backend_kind,
            "supports_lid": bool(getattr(self.backend, "supports_lid", False)),
            "confidence": str(getattr(self.backend, "confidence", "logprob")),
            "limits": {"sample_rate": SAMPLE_RATE, "max_chunk_samples": MAX_CHUNK_SAMPLES, "max_lid_clips": MAX_LID_CLIPS,
                       "max_lid_clip_samples": MAX_LID_CLIP_SAMPLES, "max_wait_s": self.cfg.max_wait_s,
                       "concurrency_per_token": self.cfg.per_token_concurrency},
            "retention": {"mode": "none", "audio_disk": False, "text_disk": False, "memory_cache_s": int(IDEM_TTL_S),
                          "log_content": False},
            "attest": {"build_sha256": self.build_sha256, "config_sha256": self.config_sha256, "started": self.started,
                       "hf_offline": os.environ.get("HF_HUB_OFFLINE", "").lower() in ("1", "on", "yes", "true"),
                       "core_dumps_disabled": core_dumps_disabled()},
            "vendor": vendor, "token": {"expires_in_days": left},
            "queue": {"depth": self.queue.depth(), "avg_service_s": round(self.avg_service_s, 1)}})
        return body

    def _enroll(self, adm: Admission, body: bytes) -> _Result:
        key = src_net(adm.peer) or "-"
        wait = max(self._enroll_by_source.blocked(key, adm.t), self._enroll_global.blocked("*", adm.t))
        if wait:
            raise ApiError("enroll_throttled", wait)
        obj = _json_object(body)
        code, machine = obj.get("code"), obj.get("machine")
        if machine is not None and not (isinstance(machine, str) and _MACHINE.fullmatch(machine)):
            raise ApiError("bad_request")
        user = self.codes.consume(code, adm.t) if isinstance(code, str) and len(code) <= 64 else None
        if user is None:
            self._enroll_by_source.fail(key, adm.t)
            self._enroll_global.fail("*", adm.t)
            raise ApiError("enroll_invalid")
        token, row = self.tokens.issue(user, adm.t, self.cfg.token_ttl_days, issuer="enroll", machine=machine)
        adm.log_user, adm.log_token_id = row.user, row.id
        return _Result(200, {"token": token, "expires": _iso(row.expires), "user": row.user})

    def _put_vocab(self, adm: Admission, body: bytes) -> _Result:
        obj = _json_object(body)
        terms = obj.get("terms")
        if (set(obj) != {"terms"} or not isinstance(terms, list) or len(terms) > MAX_VOCAB_TERMS
                or any(not isinstance(t, str) or not t.strip() or len(t) > MAX_TERM_CHARS or any(ord(c) < 32 for c in t) for t in terms)):
            raise ApiError("bad_request")
        try:
            digest = canonical_vocab_digest(obj)
        except ValueError:                                  # a lone surrogate cannot be written as UTF-8
            raise ApiError("bad_request") from None
        if digest != adm.vocab_sha:
            raise ApiError("bad_request")
        with self._lock:
            store = self._vocab.setdefault(adm.token.id, OrderedDict())
            store[adm.vocab_sha] = tuple(terms)
            store.move_to_end(adm.vocab_sha)
            while len(store) > VOCAB_PER_TOKEN:
                store.popitem(last=False)
        return _Result(204)

    def _purge(self, token_id: str) -> int:
        with self._lock:
            count = len(self._vocab.pop(token_id, ()))
            entries = self._idem.get(token_id, OrderedDict())
            for key in [k for k, e in entries.items() if e.job.done.is_set()]:
                del entries[key]
                count += 1
            return count

    # ------------------------------------------------------------------------------------------ chunk and lid
    def _compute(self, adm: Admission, body: bytes) -> _Result:
        token_id = adm.token.id
        sha = hashlib.sha256(body).hexdigest()
        replay: Optional[bytes] = None
        creator = False
        with self._lock:
            self.sweep(adm.t)
            entries = self._idem.setdefault(token_id, OrderedDict())
            entry = entries.get(adm.idem) if adm.idem else None
            if entry is not None:
                if entry.body_sha != sha:
                    raise ApiError("idem_conflict")
                entries.move_to_end(adm.idem)
                job = entry.job
                if job.done.is_set() and job.error is None:
                    replay = job.response
                else:
                    job.waiters += 1                       # the same request is still running: attach to it
            else:
                terms: tuple = ()
                if adm.route == "chunk" and adm.vocab_sha:
                    terms = self._vocab.get(token_id, {}).get(adm.vocab_sha)
                    if terms is None:
                        raise ApiError("vocab_unknown")
                    self._vocab[token_id].move_to_end(adm.vocab_sha)
                self._capacity(token_id, adm.audio_s, adm.t, reserve=True)
                params = dict(adm.params, terms=terms)
                job = Job(adm.op, token_id, body, params, adm.audio_s, self.clock())
                creator = True
                if adm.idem:
                    entries[adm.idem] = _IdemEntry(sha, job)
                    self._trim_idem(entries)
                self.queue.put(job)
        if replay is not None:
            return _Result(200, replay)
        remaining = max(0.0, self.request_deadline_s - (self.clock() - adm.t0))
        if not job.done.wait(remaining):
            with self._lock:
                job.waiters -= 1
            raise ApiError("engine_timeout")
        if job.error is not None:
            raise ApiError(job.error.code, job.error.retry_after, extra=job.error.extra)
        return _Result(200, job.response, charged=adm.audio_s if creator else 0.0, queue_ms=job.queue_ms)

    @staticmethod
    def _trim_idem(entries: OrderedDict) -> None:
        while len(entries) > IDEM_PER_TOKEN:
            victim = next((k for k, e in entries.items() if e.job.done.is_set()), None)
            if victim is None:
                return
            del entries[victim]

    # ------------------------------------------------------------------------------------------ the engine worker
    def _work(self) -> None:
        while True:
            job = self.queue.take()
            if job is None:
                return
            try:
                self._execute(job)
            finally:
                self.queue.finish()

    def _execute(self, job: Job) -> None:
        with self._lock:
            abandoned = job.waiters <= 0                   # every request that waited for it gave up: no point in computing
            if not abandoned:
                job.started = self.clock()
                job.queue_ms = int((job.started - job.enqueued) * 1000)
        if abandoned:
            job.error = ApiError("engine_timeout")
            self._finish(job, None)
            return
        try:
            job.response = self._transcribe(job) if job.op == "transcribe" else self._identify(job)
        except ApiError as exc:
            job.error = exc
        except ValueError as exc:
            log.error("audio not processable: %s", type(exc).__name__)
            job.error = ApiError("unprocessable_audio")
        except TimeoutError:
            job.error = ApiError("engine_timeout")
        except Exception as exc:                            # only the class name: the message of an engine error may carry content
            log.error("engine failed: %s", type(exc).__name__)
            job.error = ApiError("engine_error")
        finally:
            job.pcm = None                                  # the audio is gone as soon as the engine is done with it
        self._finish(job, self.clock() - job.started)

    def _finish(self, job: Job, service_s: Optional[float]) -> None:
        with self._lock:
            if service_s is not None:
                self.avg_service_s = min(600.0, max(0.1, 0.8 * self.avg_service_s + 0.2 * service_s))
            self.quotas.release(job.token_id)
            job.completed_at = self.now_fn()
            job.pcm = None
            if job.error is not None:
                entries = self._idem.get(job.token_id, {})
                for key in [k for k, e in entries.items() if e.job is job]:
                    del entries[key]                       # failures are never cached: a retry computes again
        job.done.set()

    def _transcribe(self, job: Job) -> bytes:
        engine, params = self.backend, job.params
        audio = np.frombuffer(job.pcm, dtype="<i2").astype(np.float32) * np.float32(1.0 / 32768.0)
        lab = "" if params["lang"] == "auto" else params["lang"]
        if not lab and getattr(engine, "supports_lid", False):
            try:
                lab = str(engine.detect_languages([audio], params["langs"])[0]["top"])
            except Exception as exc:                        # the engine decides on its own, like a client without language ID
                log.warning("language id failed: %s", type(exc).__name__)
                lab = ""
        terms = params["terms"]
        prompt = None
        if getattr(engine, "uses_prompt", True) and params["prompt"] != "none" and terms:
            language = (lab or "en") if params["prompt"] == "frame+list" else None
            prompt = asr.build_asr_prompt(Vocab(terms=list(terms)), engine.tokenizer, asr.ASR_PROMPT_TOKENS, language=language,
                                          frames=getattr(engine, "prompt_frames", None)) or None
        hook = getattr(engine, "set_request_terms", None)
        if callable(hook):
            hook(tuple(terms))
        words = set(asr._norm(prompt).split()) if prompt else set()
        result = asr.decode_chunk(engine, audio, lab, prompt, words, Counter(), "chunk")      # the same prompt retry as the local path
        opaque = getattr(engine, "confidence", "logprob") != "logprob"
        segments = []
        for seg in result.get("segments") or []:
            text = seg.get("text")
            if not isinstance(text, str) or not text.strip():
                continue
            start = max(0.0, _num(seg.get("start")) or 0.0)
            end = max(start, _num(seg.get("end")) or start)
            segments.append({"start": start, "end": end, "text": text.strip(),
                             "avg_logprob": None if opaque else _num(seg.get("avg_logprob")),
                             "no_speech_prob": None if opaque else _num(seg.get("no_speech_prob")),
                             "compression_ratio": None if opaque else _num(seg.get("compression_ratio")),
                             "temperature": _num(seg.get("temperature"))})
        language = result.get("language") if isinstance(result.get("language"), str) else (lab or None)
        body = _dumps({"proto": PROTO, "op": "transcribe", "engine": self.engine_id, "model": self._model_label(),
                       "language": language, "text": str(result.get("text") or ""),
                       "avg_logprob": None if opaque else _num(result.get("avg_logprob")),
                       "truncated": bool(result.get("truncated")), "prompt_text": prompt or "", "segments": segments})
        if len(body) > MAX_RESPONSE_BYTES:
            raise ApiError("engine_error")                  # never cut transcript text: the client would refuse an over-long answer
        return body

    def _identify(self, job: Job) -> bytes:
        params = job.params
        flat = np.frombuffer(job.pcm, dtype="<i2").astype(np.float32) * np.float32(1.0 / 32768.0)
        clips, offset = [], 0
        for count in params["clips"]:
            clips.append(flat[offset:offset + count])
            offset += count
        found = self.backend.detect_languages(clips, params["langs"])
        if not isinstance(found, list) or len(found) != len(clips):
            raise ApiError("engine_error")
        results = []
        for item in found:
            entry = {code: _num(item.get(code)) or 0.0 for code in params["langs"]}
            entry["top"] = str(item.get("top") or max(params["langs"], key=lambda c: entry[c]))
            results.append(entry)
        return _dumps({"proto": PROTO, "op": "lid", "results": results})


def _json_object(body: bytes) -> dict:
    try:
        obj = json.loads(body.decode("utf-8"), parse_constant=lambda _c: (_ for _ in ()).throw(ValueError("constant")))
    except (ValueError, RecursionError):
        raise ApiError("bad_request") from None
    if not isinstance(obj, dict):
        raise ApiError("bad_request")
    return obj


def handle_request(state: ServerState, method: str, path: str, headers: Any, body: bytes, now: Any = None, *,
                   peer: Optional[str] = None) -> tuple[int, dict, bytes]:
    """The pure core: one request in, (status, headers, body) out; no socket is involved. ``headers`` is a mapping or a list of
    (name, value) pairs (a duplicate Content-Length is only visible in the list form), ``now`` a datetime or epoch seconds, ``peer`` the
    client address as the front end saw it (reduced to a coarse network before anything is logged)."""
    return state.handle(method, path, headers, bytes(body or b""), now, peer=peer)


# ======================================================================================================================
# process hardening, self checks, content scan
# ======================================================================================================================
def build_sha256(package_dir: Optional[Path] = None) -> str:
    """sha256 over the source files of the ``mcap`` package (sorted by name): the ``attest.build_sha256`` that an organisation policy
    lists in ``attest_build_sha256``. Reproducible for one release."""
    root = Path(package_dir) if package_dir else Path(__file__).resolve().parent
    digest = hashlib.sha256()
    for path in sorted(root.glob("*.py")):
        digest.update(path.name.encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def core_dumps_disabled() -> bool:
    try:
        return resource.getrlimit(resource.RLIMIT_CORE) == (0, 0)
    except (OSError, ValueError):
        return False


def harden_process() -> None:
    """RLIMIT_CORE to 0 (a crash must not write the memory, which holds audio and text, into a core file), umask 077, no model
    downloads (HF_HUB_OFFLINE is read when the libraries are imported, so this runs before the backend loads)."""
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    os.environ["HF_HUB_OFFLINE"] = "1"


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str = ""


def check_bind(cfg: ServerConfig) -> Check:
    host, _port = cfg.listen_address
    if not is_loopback_host(host) and not cfg.tls:
        return Check("bind", False, "a non-loopback address needs tls_cert and tls_key (plaintext is only for a loopback bind behind a TLS terminator)")
    return Check("bind", True, f"{'tls' if cfg.tls else 'plaintext on loopback'}")


def check_core_limit() -> Check:
    return Check("core_dumps", core_dumps_disabled(), "RLIMIT_CORE is 0" if core_dumps_disabled() else "RLIMIT_CORE is not 0")


def run_selfchecks(cfg: ServerConfig, *, config_path: Any = None) -> list[Check]:
    """The startup self-checks: bind, core dumps, directory and file modes, no audio file in the service directories."""
    checks = [check_bind(cfg), check_core_limit()]
    for name, path in (("secrets_dir", cfg.secrets_dir), ("log_dir", cfg.log_dir)):
        problem = private_dir_problem(path)
        checks.append(Check(name, problem is None, problem or "private (0700)"))
    try:
        owner = os.stat(cfg.secrets_dir).st_uid
    except OSError:
        owner = os.geteuid()
    files = [("tokens", cfg.tokens_path), ("enroll_codes", cfg.codes_path)] + ([("tls_key", cfg.tls_key)] if cfg.tls else [])
    if cfg.backend != "whisper":
        files.append(("vendor_key", vendor_key_path(cfg.secrets_dir, cfg.backend)))
    for name, path in files:
        problem = private_file_problem(path, owner_uid=owner)
        optional = name != "tls_key" and problem == "does not exist"           # no token yet; a backend that needs no vendor key has none
        checks.append(Check(name, problem is None or optional, "not there (yet)" if optional else (problem or "private (0600)")))
    if cfg.tls:
        try:
            ok = os.access(cfg.tls_cert, os.R_OK)
        except OSError:
            ok = False
        checks.append(Check("tls_cert", ok, "readable" if ok else "cannot be read"))
    if config_path is not None:
        try:
            info = os.stat(config_path)
            ok = not info.st_mode & 0o022 and info.st_uid in (os.geteuid(), 0)
        except OSError:
            ok = False
        checks.append(Check("config_file", ok, "not writable by group or others" if ok else "must be owned by the service user and not writable by others"))
    findings = [f for root in (cfg.secrets_dir, cfg.log_dir) for f in scan_for_audio(root)]
    heard = [f for f in findings if f.kind.startswith("audio-")]
    gaps = [f for f in findings if f.kind.startswith("scan-")]
    if heard:
        detail = "audio in the service directories: " + ", ".join(sorted({os.path.basename(f.path) for f in heard})[:5])
    elif gaps:
        detail = "the scan could not look at everything (" + ", ".join(sorted({f.kind for f in gaps})) + "): it cannot say there is no audio"
    else:
        detail = "no audio file in the service directories"
    checks.append(Check("no_audio_on_disk", not findings, detail))
    return checks


@dataclass(frozen=True)
class Finding:
    path: str
    kind: str
    detail: str = ""


_AUDIO_MAGIC = (("wav", 0, b"RIFF", 8, b"WAVE"), ("aiff", 0, b"FORM", 8, b"AIFF"), ("aifc", 0, b"FORM", 8, b"AIFC"), ("flac", 0, b"fLaC", 0, None),
                ("ogg", 0, b"OggS", 0, None), ("mp3-id3", 0, b"ID3", 0, None), ("caf", 0, b"caff", 0, None),
                ("matroska", 0, b"\x1a\x45\xdf\xa3", 0, None), ("mp4-m4a", 4, b"ftyp", 0, None), ("amr", 0, b"#!AMR", 0, None))


def audio_signature(head: bytes) -> Optional[str]:
    """The name of the audio container the first bytes of a file announce, or None. Raw headerless PCM has no signature: the guarantee
    against it is structural (no code path writes a request body), not this scan."""
    for name, at, magic, at2, magic2 in _AUDIO_MAGIC:
        if head[at:at + len(magic)] == magic and (magic2 is None or head[at2:at2 + len(magic2)] == magic2):
            return name
    return None


def scan_for_audio(root: Any, limit: Optional[int] = None) -> list[Finding]:
    """Files under ``root`` with an audio extension or an audio signature (names only; the audit never reads content into its output).
    A scan that could not look at everything says so with a finding of its own (``scan-incomplete``: it stopped after ``limit`` files,
    default ``SCAN_FILE_LIMIT``; ``scan-unreadable``: a directory or a file could not be read; ``scan-root``: ``root`` is not a
    directory): an audit that only skimmed must not report a clean result."""
    limit = SCAN_FILE_LIMIT if limit is None else limit
    found: list[Finding] = []
    if not os.path.isdir(root):
        return [Finding(os.fspath(root), "scan-root", "the directory does not exist or cannot be read: nothing was scanned")]

    def unreadable(exc: OSError) -> None:
        found.append(Finding(os.fspath(exc.filename) if exc.filename else os.fspath(root), "scan-unreadable", "a directory cannot be listed"))

    seen = 0
    for base, dirs, names in os.walk(root, followlinks=False, onerror=unreadable):
        dirs.sort()
        for name in sorted(names):
            seen += 1
            if seen > limit:
                found.append(Finding(os.fspath(root), "scan-incomplete", f"more than {limit} files: the scan stopped"))
                return found
            path = os.path.join(base, name)
            if os.path.splitext(name)[1].lower() in AUDIO_EXTENSIONS:
                found.append(Finding(path, "audio-extension"))
                continue
            try:
                if not statmod.S_ISREG(os.lstat(path).st_mode):
                    continue
                with open(path, "rb") as fh:
                    head = fh.read(16)
            except OSError:
                found.append(Finding(path, "scan-unreadable", "a file cannot be read"))
                continue
            kind = audio_signature(head)
            if kind:
                found.append(Finding(path, "audio-signature", kind))
    return found


def scan_log_dir(log_dir: Any) -> list[Finding]:
    """Everything in the log directory must be metadata or plain operational lines: a meta-*.jsonl line has exactly the documented keys
    and no text-like value, any other file is ASCII, one short line per entry, and not JSON that carries transcript fields."""
    found: list[Finding] = []
    try:
        names = sorted(os.listdir(log_dir))
    except OSError:
        return [Finding(os.fspath(log_dir), "scan-root", "the log directory does not exist or cannot be read: nothing was scanned")]
    for name in names:
        path = os.path.join(log_dir, name)
        try:
            mode = os.lstat(path).st_mode
            if statmod.S_ISDIR(mode):
                continue                                    # scan_for_audio walks it; a log file is a file
            if not statmod.S_ISREG(mode):
                found.append(Finding(path, "scan-unreadable", "not a regular file (a link or a special file): its content was not scanned"))
                continue
            with open(path, "rb") as fh:
                data = fh.read(SCAN_LOG_BYTES + 1)
        except OSError:
            found.append(Finding(path, "scan-unreadable", "a log file cannot be read"))
            continue
        if name.endswith(".lock"):
            continue
        if len(data) > SCAN_LOG_BYTES:
            found.append(Finding(path, "scan-incomplete", f"more than {SCAN_LOG_BYTES // (1024 * 1024)} MiB: only the start was scanned"))
            data = data[:SCAN_LOG_BYTES]
        if b"\x00" in data[:4096]:
            found.append(Finding(path, "binary-content", "a log file holds binary data"))
            continue
        for number, raw in enumerate(data.split(b"\n"), 1):
            if not raw:
                continue
            if name.startswith("meta-") and name.endswith(".jsonl"):
                problem = _meta_line_problem(raw)
            else:
                problem = (None if raw.isascii() and len(raw) <= 1000 and not re.search(rb'"(text|segments|prompt_text|terms)"\s*:', raw)
                           else "non-metadata content in a log line")
            if problem:
                found.append(Finding(path, "log-content", f"line {number}: {problem}"))
                break
    return found


def _meta_line_problem(raw: bytes) -> Optional[str]:
    try:
        obj = json.loads(raw.decode("ascii"))
    except ValueError:
        return "not an ASCII JSON line"
    if not isinstance(obj, dict) or tuple(obj) != META_KEYS:
        return "the keys are not the documented ones"
    for key, value in obj.items():
        if isinstance(value, str) and len(value) > LOG_LABEL_CHARS + 40:
            return f"{key} is too long for a label"
    return None


def audit_home(home: Any, secrets_dir: Any, log_dir: Any) -> list[Finding]:
    """The quarterly scan (docs/ASR_PROTOCOL.md 9): audio files in the service user's home and directories, and non-metadata content in
    the log directory. A scan, not a proof."""
    findings: list[Finding] = []
    seen_roots: set[str] = set()
    for root in (home, secrets_dir, log_dir):
        real = os.path.realpath(root)
        if real not in seen_roots:                          # a root that is missing or unreadable is a finding (scan_for_audio), never skipped
            seen_roots.add(real)
            findings.extend(scan_for_audio(real))
    findings.extend(scan_log_dir(log_dir))
    unique: dict[tuple[str, str], Finding] = {}
    for finding in findings:                                # the log directory is looked at twice: report a gap once
        unique.setdefault((finding.kind, os.path.realpath(finding.path)), finding)
    return list(unique.values())


# ======================================================================================================================
# daily audit summary
# ======================================================================================================================
def daily_summary(metalog: MetaLog, day: str, *, lookback_days: int = 30) -> dict:
    """What happened on ``day`` (content-free): requests, audio hours per user, new source networks (not seen for the token in the
    previous ``lookback_days`` days; a token's very first use is reported as such), audio-hour spikes (at least 2 h and at least three
    times the average of the previous 14 days of the token, or at least 6 h for a token without history) and machine changes."""
    records = metalog.read_day(day)
    first = dt.date.fromisoformat(day)
    history: dict[str, dict] = defaultdict(lambda: {"nets": set(), "hours": defaultdict(float)})
    for back in range(1, lookback_days + 1):
        past = (first - dt.timedelta(days=back)).isoformat()
        for rec in metalog.read_day(past):
            tid = rec.get("token_id")
            if isinstance(tid, str):
                if isinstance(rec.get("src_net"), str):
                    history[tid]["nets"].add(rec["src_net"])
                history[tid]["hours"][past] += (_num(rec.get("audio_s")) or 0.0) / 3600.0
    users: dict[str, dict] = {}
    statuses: Counter = Counter()
    new_nets: dict[tuple, str] = {}
    machine: Counter = Counter()
    for rec in records:
        tid = rec.get("token_id") or "-"
        statuses[str(rec.get("status"))] += 1
        entry = users.setdefault(tid, {"user": rec.get("user"), "requests": 0, "audio_s": 0.0})
        entry["requests"] += 1
        entry["audio_s"] += _num(rec.get("audio_s")) or 0.0
        net = rec.get("src_net")
        if isinstance(net, str) and net not in history[tid]["nets"] and (tid, net) not in new_nets:
            new_nets[(tid, net)] = "first-use" if not history[tid]["nets"] and not history[tid]["hours"] else "new-network"
        if rec.get("machine_changed") is True:
            machine[tid] += 1
    spikes = []
    for tid, entry in users.items():
        hours = entry["audio_s"] / 3600.0
        past = list(history[tid]["hours"].values())[:14]
        baseline = sum(past) / len(past) if past else 0.0
        if (past and hours >= 2.0 and hours >= 3.0 * baseline) or (not past and hours >= 6.0):
            spikes.append({"token_id": tid, "user": entry["user"], "hours": round(hours, 2), "baseline_hours": round(baseline, 2)})
    return {"day": day, "requests": len(records), "audio_hours": round(sum(u["audio_s"] for u in users.values()) / 3600.0, 2),
            "statuses": dict(sorted(statuses.items())),
            "users": [{"token_id": t, "user": u["user"], "requests": u["requests"], "audio_hours": round(u["audio_s"] / 3600.0, 2)}
                      for t, u in sorted(users.items())],
            "new_networks": [{"token_id": t, "user": users[t]["user"], "net": n, "kind": k} for (t, n), k in sorted(new_nets.items())],
            "spikes": spikes,
            "machine_changes": [{"token_id": t, "user": users[t]["user"], "requests": c} for t, c in sorted(machine.items())]}


def render_daily(summary: dict) -> str:
    lines = [f"mcap-asr daily audit {summary['day']}",
             f"requests {summary['requests']}  audio {summary['audio_hours']:.2f} h  users {len(summary['users'])}  "
             f"statuses {' '.join(f'{k}:{v}' for k, v in summary['statuses'].items()) or '-'}"]
    for u in summary["users"]:
        lines.append(f"USER {u['token_id']} {u['user'] or '-'} requests={u['requests']} audio_h={u['audio_hours']:.2f}")
    alerts = 0
    for n in summary["new_networks"]:
        tag = "FIRST-USE" if n["kind"] == "first-use" else "NEW-NET"
        alerts += n["kind"] != "first-use"
        lines.append(f"{tag} {n['token_id']} {n['user'] or '-'} {n['net']}")
    for s in summary["spikes"]:
        alerts += 1
        lines.append(f"SPIKE {s['token_id']} {s['user'] or '-'} audio_h={s['hours']:.2f} baseline_h={s['baseline_hours']:.2f}")
    for m in summary["machine_changes"]:
        alerts += 1
        lines.append(f"MACHINE {m['token_id']} {m['user'] or '-'} requests={m['requests']}")
    lines.append(f"ALERTS {alerts}")
    return "\n".join(lines)


# ======================================================================================================================
# HTTP front end
# ======================================================================================================================
_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")


def parse_request_head(raw: bytes) -> tuple[str, str, list[tuple[str, str]]]:
    """(method, target, [(name, value)]) of a request head (everything before the blank line). Strict: CRLF line ends only, ASCII only,
    no folded header, no space before the colon, HTTP/1.1, origin-form target. ``ApiError("bad_request")`` otherwise."""
    if len(raw) > MAX_HEAD_BYTES:
        raise ApiError("bad_request")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise ApiError("bad_request") from None
    lines = text.split("\r\n")
    if any("\n" in line or "\r" in line or any(ord(ch) < 32 and ch != "\t" or ord(ch) == 127 for ch in line) for line in lines):
        raise ApiError("bad_request")
    pieces = lines[0].split(" ")
    if len(pieces) != 3 or pieces[2] != "HTTP/1.1" or not re.fullmatch(r"[A-Z]{3,10}", pieces[0]) or not pieces[1].startswith("/"):
        raise ApiError("bad_request")
    pairs = []
    for line in lines[1:]:
        if not line or line[0] in " \t":
            raise ApiError("bad_request")
        name, sep, value = line.partition(":")
        if not sep or not _NAME.fullmatch(name):
            raise ApiError("bad_request")
        pairs.append((name, value.strip(" \t")))
    if len(pairs) > MAX_HEADERS:
        raise ApiError("bad_request")
    return pieces[0], pieces[1], pairs


class _Timeout(Exception):
    pass


def _read_until(sock: Any, buf: bytearray, marker: bytes, limit: int, deadline: float) -> bool:
    """Append to ``buf`` until it holds ``marker`` or the peer closes. False when the peer closed before anything arrived."""
    while marker not in buf:
        if len(buf) > limit:
            raise ApiError("bad_request")
        left = deadline - time.monotonic()
        if left <= 0:
            raise _Timeout
        sock.settimeout(min(left, IDLE_S))
        try:
            data = sock.recv(8192)
        except (socket.timeout, ssl.SSLWantReadError):
            raise _Timeout from None
        if not data:
            return bool(buf)
        buf += data
    return True


def _read_exact(sock: Any, buf: bytearray, count: int, deadline: float) -> bytes:
    while len(buf) < count:
        left = deadline - time.monotonic()
        if left <= 0:
            raise _Timeout
        sock.settimeout(min(left, IDLE_S))
        try:
            data = sock.recv(min(65536, count - len(buf)))
        except (socket.timeout, ssl.SSLWantReadError):
            raise _Timeout from None
        if not data:
            raise ApiError("bad_request")
        buf += data
    return bytes(buf[:count])


def serialize_response(status: int, headers: Mapping[str, str], body: bytes) -> bytes:
    try:
        reason = HTTPStatus(status).phrase
    except ValueError:
        reason = "Status"
    head = [f"HTTP/1.1 {status} {reason}"] + [f"{k}: {v}" for k, v in headers.items()] + ["Connection: close", "", ""]
    return "\r\n".join(head).encode("ascii") + body


class _Handler(socketserver.BaseRequestHandler):
    """One request per connection. Deadlines: headers 10 s (TLS handshake included), body 30 s, the whole request 120 s."""

    unauthenticated = True                                   # counted against MAX_UNAUTH_CONNECTIONS until a token was accepted
    token_id: Optional[str] = None                           # set when a token was accepted: the connection then counts against that token's limit
    counted_token: Optional[str] = None                      # the token this connection is counted for (set by the server, released by leave)

    def handle(self) -> None:
        server: _Server = self.server                        # type: ignore[assignment]
        state, sock = server.state, self.request
        start = time.monotonic()
        peer = self.client_address[0] if self.client_address else None
        adm: Optional[Admission] = None
        reply: Optional[tuple] = None
        try:
            if isinstance(sock, ssl.SSLSocket):
                sock.settimeout(HEADER_DEADLINE_S)
                sock.do_handshake()
            buf = bytearray()
            if not _read_until(sock, buf, b"\r\n\r\n", MAX_HEAD_BYTES, start + HEADER_DEADLINE_S):
                return
            end = buf.find(b"\r\n\r\n")
            if end < 0:
                raise ApiError("bad_request")
            head, rest = bytes(buf[:end]), bytearray(buf[end + 4:])
            method, target, pairs = parse_request_head(head)
            adm = state.admit(method, target, pairs, None, peer=peer)
            if adm.token is not None:
                self.token_id = adm.token.id
                if not server.mark_authenticated(self):         # this token has all the connections it may hold: nothing is read from this one
                    raise ApiError("quota_exceeded", 1)
            body = _read_exact(sock, rest, adm.content_length, time.monotonic() + BODY_DEADLINE_S) if adm.content_length else b""
            reply = state.complete(adm, body)
        except ApiError as exc:
            if exc.adm is not None and exc.adm.token is not None:
                self.token_id = exc.adm.token.id
                server.mark_authenticated(self)                 # the token was good, something after it was not
            reply = state.fail(exc, adm)
        except _Timeout:
            reply = state.fail(ApiError("request_timeout"), adm)
        except (OSError, ssl.SSLError):
            return                                           # the peer went away or the handshake failed: nothing to answer
        try:
            sock.settimeout(max(1.0, state.request_deadline_s - (time.monotonic() - start)))
            sock.sendall(serialize_response(*reply))
            self._linger(sock)
        except (OSError, ssl.SSLError):
            pass

    def finish(self) -> None:
        self.server.leave(self)                              # type: ignore[attr-defined]

    @staticmethod
    def _linger(sock: Any) -> None:
        """After an answer that was sent before the body was read, drain what the client still sends so that closing does not reset the
        connection before the client has read the status."""
        try:
            sock.shutdown(socket.SHUT_WR)
        except (OSError, ssl.SSLError):
            return
        end, drained = time.monotonic() + 3.0, 0
        while drained < 3 * (1 << 20) and time.monotonic() < end:           # more than the largest request the client's guard sends (2.5 MB)
            try:
                sock.settimeout(0.5)
                chunk = sock.recv(65536)
            except (OSError, ssl.SSLError):
                return
            if not chunk:
                return
            drained += len(chunk)


class _Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128

    def __init__(self, address: tuple, state: ServerState, tls: Optional[ssl.SSLContext], family: int):
        self.state, self.tls = state, tls
        self.address_family = family
        self._count_lock = threading.Lock()
        self.total = 0
        self.unauth = 0
        self.by_token: Counter = Counter()                   # open connections per token id, from the moment its token is accepted
        super().__init__(address, _Handler)

    def get_request(self):
        sock, addr = super().get_request()
        if self.tls is not None:
            sock = self.tls.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        return sock, addr

    def verify_request(self, request, client_address) -> bool:
        with self._count_lock:
            if self.total >= MAX_CONNECTIONS or self.unauth >= MAX_UNAUTH_CONNECTIONS:
                return False                                 # too many connections that have not authenticated: closed at once
            self.total += 1
            self.unauth += 1
        return True

    def token_connection_limit(self) -> int:
        """Open connections one token may hold at the same time: its concurrency plus a margin. The per-token concurrency limit counts
        requests only once their body has arrived, so without this a holder could park the whole server on connections that sent a valid
        head and withhold the body."""
        return self.state.cfg.per_token_concurrency + CONNECTION_MARGIN

    def mark_authenticated(self, handler: _Handler) -> bool:
        """A token was accepted on this connection (``handler.token_id``): it stops counting as unauthenticated and counts against the
        limit of that token. False when the token already holds its limit: the connection stays counted as unauthenticated (so it cannot
        be used to crowd out others either) and the caller answers 429 without reading a body."""
        with self._count_lock:
            token_id = getattr(handler, "token_id", None)
            if token_id is not None and getattr(handler, "counted_token", None) is None:
                if self.by_token[token_id] >= self.token_connection_limit():
                    return False
                self.by_token[token_id] += 1
                handler.counted_token = token_id
            if handler.unauthenticated:
                handler.unauthenticated = False
                self.unauth = max(0, self.unauth - 1)
            return True

    def leave(self, handler: _Handler) -> None:
        with self._count_lock:
            self.total = max(0, self.total - 1)
            if handler.unauthenticated:
                handler.unauthenticated = False
                self.unauth = max(0, self.unauth - 1)
            token_id = getattr(handler, "counted_token", None)
            if token_id is not None:
                handler.counted_token = None
                self.by_token[token_id] -= 1
                if self.by_token[token_id] <= 0:
                    del self.by_token[token_id]

    def handle_error(self, request, client_address) -> None:
        exc = sys.exc_info()[1]
        log.error("connection failed: %s", type(exc).__name__)


def make_server(state: ServerState, address: Optional[tuple] = None) -> _Server:
    """Bind (not yet serve) the front end for ``state``. Refuses a non-loopback bind without TLS. ``address`` overrides the config's
    (tests bind port 0)."""
    cfg = state.cfg
    bind = check_bind(cfg)
    if not bind.ok:
        raise StartupRefused([bind])
    host, port = address or cfg.listen_address
    context = None
    if cfg.tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.options |= ssl.OP_NO_COMPRESSION
        context.load_cert_chain(cfg.tls_cert, cfg.tls_key)
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    if host == "localhost":
        host = "127.0.0.1"
    return _Server((host, port), state, context, family)


class StartupRefused(RuntimeError):
    """A self-check failed: the server does not start. ``checks`` lists the failing ones."""

    def __init__(self, checks: list):
        self.checks = checks
        super().__init__("startup refused: " + "; ".join(f"{c.name}: {c.detail}" for c in checks))


# ======================================================================================================================
# backend and serve
# ======================================================================================================================
def vendor_key_path(secrets_dir: Any, engine: str) -> str:
    """Where the vendor key of a relay backend lives: ``<secrets_dir>/<engine>.key`` (0600, owned by the service user)."""
    return os.path.join(os.fspath(secrets_dir), f"{engine}.key")


def install_vendor_key_source(secrets_dir: Any, engine: str, host: str, port: int = 443) -> "asr_creds.FileSource":
    """For a relay backend's ``for_server`` hook: the server has no login keychain, so its vendor key is read from the 0600 file
    ``vendor_key_path`` through ``asr_creds.FileSource``, bound to this engine, host and port (asking for any other destination is
    ``unbound``). Installs it as the source ``asr_creds.secret()`` reads, and returns it."""
    source = asr_creds.FileSource(vendor_key_path(secrets_dir, engine), engine=engine, host=host, port=port)
    asr_creds.install_source(source)
    return source


def default_backend_factory(cfg: ServerConfig) -> Any:
    """The engine of ``cfg.backend`` (see the module docstring). ``EngineUnavailable`` when it is not registered or its module is not
    installed; the model is never downloaded (``allow_download=False``)."""
    cls = engine_class(cfg.backend)
    options = dict(cfg.backend_options)
    hook = getattr(cls, "for_server", None)
    if callable(hook):
        return hook(options, model=cfg.model, secrets_dir=cfg.secrets_dir)
    return cls(cfg.model or DEFAULT_MODEL, allow_download=False, **options)


def serve(config_path: Any, *, backend_factory: Optional[Callable[[ServerConfig], Any]] = None) -> None:
    """Start the server and block until SIGTERM/SIGINT. Refuses to start (``StartupRefused``) when a self-check fails."""
    cfg = load_server_config(config_path)
    harden_process()
    failed = [c for c in run_selfchecks(cfg, config_path=config_path) if not c.ok]
    if failed:
        raise StartupRefused(failed)
    apikey.install_log_redaction()
    try:
        state = ServerState(cfg, (backend_factory or default_backend_factory)(cfg)).start()
    except Exception as exc:                               # a model that is not there, a backend that is not installed
        raise StartupRefused([Check("backend", False, f"{type(exc).__name__}: {str(exc)[:200]}")]) from None
    server = make_server(state)
    stopper = threading.Thread(target=server.shutdown, daemon=True)

    def stop(_signum, _frame) -> None:
        if not stopper.is_alive():
            stopper.start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    host, port = server.server_address[:2]
    log.info("mcap-asr/1 listening on %s:%s (%s), backend %s, build %s", host, port, "tls" if cfg.tls else "plaintext loopback",
             state.engine_id, state.build_sha256[:12])
    try:
        server.serve_forever()
    finally:
        server.server_close()
        state.close()


# ======================================================================================================================
# command line
# ======================================================================================================================
def _default_config_path() -> str:
    return os.environ.get(CONFIG_ENV) or os.path.join(DEFAULT_SECRETS_DIR, "asr-server.json")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m mcap.asr_server", description="mcap-asr/1 server and its admin commands")
    parser.add_argument("--config", help=f"asr-server.json (default: ${CONFIG_ENV} or {DEFAULT_SECRETS_DIR}/asr-server.json)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="run the server")
    token = sub.add_parser("token", help="manage tokens").add_subparsers(dest="tcmd", required=True)
    issue = token.add_parser("issue", help="issue a token (printed once)")
    issue.add_argument("--user", required=True)
    issue.add_argument("--ttl-days", type=int)
    lst = token.add_parser("list", help="list tokens (never the secrets)")
    lst.add_argument("--json", action="store_true")
    revoke = token.add_parser("revoke", help="revoke by id or by user: effective at the next request")
    group = revoke.add_mutually_exclusive_group(required=True)
    group.add_argument("--id")
    group.add_argument("--user")
    sync = token.add_parser("sync", help="disable the tokens of users who are not in the allow-list")
    sync.add_argument("--allow-list", required=True, metavar="FILE")
    sync.add_argument("--dry-run", action="store_true")
    code = sub.add_parser("enroll-code", help="one-time enrollment codes").add_subparsers(dest="ccmd", required=True)
    code_issue = code.add_parser("issue", help="issue a code (printed once)")
    code_issue.add_argument("--user", required=True)
    audit = sub.add_parser("audit", help="scan for audio and non-metadata content, or summarise a day")
    audit.add_argument("--daily", action="store_true", help="summarise one day of the metadata log")
    audit.add_argument("--day", help="YYYY-MM-DD (default: yesterday)")
    audit.add_argument("--home", help="the service user's home to scan (default: <secrets_dir>/home, where install_server.sh puts it)")
    audit.add_argument("--json", action="store_true")
    selfcheck = sub.add_parser("selfcheck", help="run the startup self-checks and print the attest hashes")
    selfcheck.add_argument("--json", action="store_true")
    return parser


def _admin_error(exc: Exception) -> int:
    print(f"error: {exc}", file=sys.stderr)
    return 2 if isinstance(exc, ConfigError) else 1


def _read_allow_list(path: str) -> set[str]:
    with open(path, "r", encoding="utf-8") as fh:
        lines = [line.split("#", 1)[0].strip() for line in fh]
    return {line.casefold() for line in lines if line}


def main(argv: Optional[list] = None) -> int:
    """Exit codes: 0 done, 1 failed or findings, 2 usage or configuration error."""
    args = _build_parser().parse_args(argv)
    try:
        cfg = load_server_config(args.config or _default_config_path())
    except ConfigError as exc:
        return _admin_error(exc)
    now = time.time()
    try:
        if args.cmd == "serve":
            logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
            serve(args.config or _default_config_path())
            return 0
        if args.cmd == "token":
            return _cmd_token(args, cfg, now)
        if args.cmd == "enroll-code":
            code = CodeTable(cfg.codes_path).issue(args.user, now, cfg.enroll_code_ttl_s)
            print(code)
            print(f"valid {cfg.enroll_code_ttl_s} s, single use, for {_label(args.user)}", file=sys.stderr)
            return 0
        if args.cmd == "audit":
            return _cmd_audit(args, cfg, now)
        return _cmd_selfcheck(args, cfg, args.config or _default_config_path())
    except (TableError, StartupRefused, EngineUnavailable, OSError) as exc:
        return _admin_error(exc)


def _cmd_token(args: argparse.Namespace, cfg: ServerConfig, now: float) -> int:
    table = TokenTable(cfg.tokens_path)
    if args.tcmd == "issue":
        token, row = table.issue(args.user, now, args.ttl_days or cfg.token_ttl_days)
        print(token)
        print(f"id {row.id} user {row.user} expires {_iso(row.expires)} (shown once; only its SHA-256 is stored)", file=sys.stderr)
        return 0
    if args.tcmd == "list":
        rows = sorted(table.rows().values(), key=lambda r: (r.user, r.issued))
        if table.problem:
            print(f"error: {table.problem}", file=sys.stderr)
            return 1
        listing = [{"id": r.id, "user": r.user, "status": r.status(now), "issued": _iso(r.issued), "expires": _iso(r.expires),
                    "issuer": r.issuer, "last_used": _iso(r.last_used) if r.last_used else None, "net": r.net,
                    "machine": r.machine} for r in rows]
        if args.json:
            print(json.dumps(listing, ensure_ascii=True, indent=1))
        else:
            for item in listing:
                print(f"{item['id']} {item['status']:<8} {item['user']:<24} expires {item['expires']} last_used {item['last_used'] or '-'} "
                      f"net {item['net'] or '-'}")
        return 0
    if args.tcmd == "revoke":
        def mutate(rows: list) -> tuple[int, bool]:
            count = 0
            for entry in rows:
                hit = entry.get("id") == args.id if args.id else str(entry.get("user", "")).casefold() == args.user.casefold()
                if hit and not entry.get("revoked"):
                    entry["revoked"] = _iso(now)
                    count += 1
            return count, count > 0

        count = table.update(mutate)
        print(f"revoked {count} token(s): effective at the next request")
        return 0 if count else 1
    allowed = _read_allow_list(args.allow_list)
    if not allowed:
        print("error: the allow-list is empty: refusing to disable every user (use token revoke for one)", file=sys.stderr)
        return 2

    def sync(rows: list) -> tuple[list, bool]:
        hit = [e for e in rows if str(e.get("user", "")).casefold() not in allowed and not e.get("disabled") and not e.get("revoked")]
        if not args.dry_run:
            for entry in hit:
                entry["disabled"] = "offboarded"
        return sorted({str(e.get("user")) for e in hit}), bool(hit) and not args.dry_run

    users = table.update(sync)
    print(f"{'would disable' if args.dry_run else 'disabled'} the tokens of {len(users)} user(s): {', '.join(users) or '-'}")
    return 0


def _cmd_audit(args: argparse.Namespace, cfg: ServerConfig, now: float) -> int:
    if args.daily:
        day = args.day or _day(now - 86400)
        try:
            summary = daily_summary(MetaLog(cfg.log_dir, cfg.metadata_log_days), day)
        except ValueError:
            print("error: --day must be YYYY-MM-DD", file=sys.stderr)
            return 2
        print(json.dumps(summary, ensure_ascii=True, indent=1) if args.json else render_daily(summary))
        return 0
    home = args.home or os.path.join(cfg.secrets_dir, "home")        # the SERVICE user's home (install_server.sh), never the caller's
    if not os.path.isdir(home):
        print(f"error: the home to scan does not exist or is not a directory: {home} (the service user's home is <secrets_dir>/home: "
              f"pass --home if it is elsewhere)", file=sys.stderr)
        return 2
    findings = audit_home(home, cfg.secrets_dir, cfg.log_dir)
    if args.json:
        print(json.dumps([f.__dict__ for f in findings], ensure_ascii=True, indent=1))
    else:
        for f in findings:
            print(f"FINDING {f.kind} {f.path}" + (f" ({f.detail})" if f.detail else ""))
        print(f"audit: {len(findings)} finding(s)")
    return 1 if findings else 0


def _cmd_selfcheck(args: argparse.Namespace, cfg: ServerConfig, config_path: str) -> int:
    harden_process()
    checks = run_selfchecks(cfg, config_path=config_path)
    if args.json:
        print(json.dumps({"checks": [c.__dict__ for c in checks], "build_sha256": build_sha256(), "config_sha256": cfg.effective_sha256()},
                         indent=1))
    else:
        for c in checks:
            print(f"{'PASS' if c.ok else 'FAIL'} {c.name}: {c.detail}")
        print(f"build_sha256 {build_sha256()}")
        print(f"config_sha256 {cfg.effective_sha256()}")
    return 0 if all(c.ok for c in checks) else 1


if __name__ == "__main__":
    sys.exit(main())
