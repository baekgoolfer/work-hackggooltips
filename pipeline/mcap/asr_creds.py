"""Credentials of the external ASR engines (SPEC 18).

A relay token (``mcap1_<id8>_<secret32>``) or a vendor key lives in the macOS Keychain, service ``MeetingCapture ASR <engine>``, account
``<user>@<host>:<port>``. The host and port are part of the account, so a secret can only be read for the destination it was stored for:
change ``ASR_REMOTE_URL`` (or the Azure host) and the lookup finds nothing (``CredentialUnavailable("missing")``), the secret never
travels to another host. The Azure key is additionally refused for any host outside the two fixed Azure suffixes (5.5).

Rules (each one has a test in tests/test_asr_creds.py):
  * Reading goes through ``secret()``, a context manager the engine uses lazily and once per engine lifetime. The value is only in
    memory: not cached on disk, not in argv, not in the environment, never in an exception, a status dict or a log (``apikey.remember``
    registers it for exact-match masking). Nothing here writes a file.
  * The tool is the absolute ``/usr/bin/security``; ``$MCAP_SECURITY_BIN`` (tests) is honoured only on a Mac without an organisation
    policy (``apikey.security_bin`` -> ``config.test_hook_env``). stdin is closed, stderr is discarded (it can name the item), the
    environment is the minimal one of apikey.
  * ``CredentialUnavailable`` carries a reason word and a FIXED sentence: no service, account, host, tool output or server text.
  * ``set_secret_interactive`` never sees the secret: the macOS tool prompts on the terminal itself (as ``apikey.set_key_interactive``).
    ``secret_status`` asks the Keychain whether the item exists WITHOUT reading it.
  * ``FileSource`` is the server tier's exception to the Keychain-only rule (SPEC 18.3): the LaunchDaemon user has no login keychain,
    so ``asr_server`` installs a 0600 file source with ``install_source``. It is bound to one engine, host and port as well.

Nothing in this module runs unless an external engine is used: the default local pipeline never imports it.
"""
from __future__ import annotations

import contextlib
import os
import re
import stat as statmod
import subprocess
import sys
from typing import Any, Iterator, Optional, Protocol

from . import apikey
from .egress import EgressDenied, normalize_host
from .policy import AZURE_HOST_SUFFIXES

SERVICE_PREFIX = "MeetingCapture ASR "
MAX_SECRET_CHARS = 512
MAX_SECRET_FILE_BYTES = 4096
_ENGINE = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}\Z")

_REASONS = {
    "missing": "no secret is stored for it",
    "timeout": "the Keychain did not answer in time",
    "error": "the Keychain could not be read",
    "no_tool": "the security tool cannot be run",
    "unbound": "no secret can be stored for this engine, host and port",
    "insecure": "the secret file is not private to its owner",
    "malformed": "the stored value cannot be used",
}


class CredentialUnavailable(Exception):
    """No usable secret for this engine, host and port. ``reason`` is one of missing | timeout | error | no_tool | unbound | insecure |
    malformed; ``str()`` is a fixed sentence (plus the command that fixes a missing secret): never the service, account, host, tool
    output or anything a server said."""

    def __init__(self, reason: str, engine: str = ""):
        self.reason = reason
        self.engine = engine if isinstance(engine, str) and _ENGINE.fullmatch(engine) else ""
        text = f"credential unavailable ({reason}): {_REASONS.get(reason, 'unavailable')}"
        if self.engine:
            text = f"{self.engine} {text}"
        if reason == "missing" and self.engine:
            fix = "mcap asr-engines enroll remote" if self.engine == "remote" else f"mcap asr-engines secret set {self.engine}"
            text += f" (run {fix})"
        super().__init__(text)


# ---------------------------------------------------------------------------------- names
def _binding(engine: Any, host: Any, port: Any) -> tuple[str, str, int]:
    """(engine, normalized host, port) or ``CredentialUnavailable("unbound")``: the single place that decides what a secret can be
    bound to (a plain DNS name, a real port, and for azure only the fixed Azure host suffixes)."""
    if not isinstance(engine, str) or not _ENGINE.fullmatch(engine):
        raise CredentialUnavailable("unbound")
    try:
        name = normalize_host(host)
    except EgressDenied:
        raise CredentialUnavailable("unbound", engine) from None
    if isinstance(port, bool) or not isinstance(port, int) or not 0 < port < 65536:
        raise CredentialUnavailable("unbound", engine)
    if engine == "azure" and not any(name.endswith(suffix) and name != suffix[1:] for suffix in AZURE_HOST_SUFFIXES):
        raise CredentialUnavailable("unbound", engine)
    return engine, name, port


def service_name(engine: str) -> str:
    """Keychain service of an engine: ``MeetingCapture ASR <engine>``."""
    if not isinstance(engine, str) or not _ENGINE.fullmatch(engine):
        raise CredentialUnavailable("unbound")
    return SERVICE_PREFIX + engine


def account_name(host: str, port: int) -> str:
    """Keychain account of a destination: ``<user>@<host>:<port>`` (host lower-case, IDNA)."""
    try:
        name = normalize_host(host)
    except EgressDenied:
        raise CredentialUnavailable("unbound") from None
    if isinstance(port, bool) or not isinstance(port, int) or not 0 < port < 65536:
        raise CredentialUnavailable("unbound")
    return f"{apikey.keychain_account()}@{name}:{port}"


def _checked(engine: str, value: Any) -> str:
    """The secret itself must be one printable token: no space, no control character (a CR/LF would end a header), bounded."""
    text = value if isinstance(value, str) else ""
    if not text:
        raise CredentialUnavailable("missing", engine)
    if len(text) > MAX_SECRET_CHARS or not all(33 <= ord(ch) < 127 for ch in text):
        raise CredentialUnavailable("malformed", engine)
    return text


# ---------------------------------------------------------------------------------- sources
class SecretSource(Protocol):
    def read(self, engine: str, host: str, port: int) -> str:
        """The secret for exactly this binding, or ``CredentialUnavailable``."""


class KeychainSource:
    """``security find-generic-password -s <service> -a <account> -w`` (the client's only source)."""

    def __init__(self, run=subprocess.run):
        self._run = run

    def read(self, engine: str, host: str, port: int) -> str:
        argv = [apikey.security_bin(), "find-generic-password", "-s", service_name(engine), "-a", account_name(host, port), "-w"]
        try:
            done = self._run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=apikey.READ_TIMEOUT_S, env=apikey._security_env())
        except subprocess.TimeoutExpired:
            raise CredentialUnavailable("timeout", engine) from None
        except OSError:
            raise CredentialUnavailable("no_tool", engine) from None
        out = done.stdout.decode("utf-8", "replace") if isinstance(done.stdout, (bytes, bytearray)) else str(done.stdout or "")
        text = out.strip()
        if done.returncode == 0 and text:
            return text
        if done.returncode in (0, apikey.ITEM_NOT_FOUND_EXIT):
            raise CredentialUnavailable("missing", engine)
        raise CredentialUnavailable("error", engine)


class FileSource:
    """Server tier only (SPEC 18.3): the secret is the content of ONE file, bound to one engine, host and port (asking for
    any other binding is ``unbound``). The file must be a regular file (no symlink), owned by ``owner_uid`` (default: this process),
    with no group or other permission bits (0600), at most 4 KiB, in a directory that is not group- or other-writable. The file is
    opened and checked through the same descriptor and read on every call (nothing is cached)."""

    def __init__(self, path, *, engine: str, host: str, port: int = 443, owner_uid: Optional[int] = None):
        self._path = os.fspath(path)
        self._binding = _binding(engine, host, port)
        self._owner = os.geteuid() if owner_uid is None else owner_uid

    def read(self, engine: str, host: str, port: int) -> str:
        try:
            wanted = _binding(engine, host, port)
        except CredentialUnavailable:
            raise CredentialUnavailable("unbound", engine) from None
        if wanted != self._binding:
            raise CredentialUnavailable("unbound", engine)
        try:
            fd = os.open(self._path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            raise CredentialUnavailable("missing", engine) from None
        except OSError:
            raise CredentialUnavailable("insecure", engine) from None     # ELOOP (a symlink), EACCES ...
        try:
            info = os.fstat(fd)
            if (not statmod.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != self._owner
                    or self._parent_writable()):
                raise CredentialUnavailable("insecure", engine)
            if info.st_size > MAX_SECRET_FILE_BYTES:
                raise CredentialUnavailable("malformed", engine)
            with os.fdopen(fd, "rb", closefd=False) as fh:
                data = fh.read(MAX_SECRET_FILE_BYTES + 1)
        finally:
            os.close(fd)
        try:
            text = data.decode("utf-8").strip()
        except UnicodeDecodeError:
            raise CredentialUnavailable("malformed", engine) from None
        return _checked(engine, text)

    def _parent_writable(self) -> bool:
        try:
            return bool(os.stat(os.path.dirname(os.path.abspath(self._path))).st_mode & 0o022)
        except OSError:
            return True


_installed: tuple = ()


def install_source(*sources) -> tuple:
    """Set the sources ``secret()`` reads when it is not given one (the server tier installs its ``FileSource`` objects; the client
    never calls this). They are tried in order; with any installed the Keychain is NOT consulted. ``install_source()`` with no argument
    restores the default. Returns the previous tuple."""
    global _installed
    previous, _installed = _installed, tuple(sources)
    return previous


def _read(engine: str, host: str, port: int, source, run) -> str:
    sources = (source,) if source is not None else (_installed or (KeychainSource(run),))
    failures: list[CredentialUnavailable] = []
    for candidate in sources:
        try:
            return _checked(engine, candidate.read(engine, host, port))
        except CredentialUnavailable as exc:
            failures.append(exc)
    pick = next((f for f in failures if f.reason != "unbound"), failures[-1] if failures else CredentialUnavailable("missing", engine))
    raise pick


@contextlib.contextmanager
def secret(engine: str, host: str, port: int, *, source=None, run=subprocess.run) -> Iterator[str]:
    """``with secret("remote", host, port) as token:`` reads the secret for exactly this binding (Keychain via the absolute
    ``/usr/bin/security``, or ``source`` / the installed sources) and registers it for masking. Raises ``CredentialUnavailable`` when
    there is none for THIS engine, host and port. Read it lazily, keep it in memory for the engine's lifetime, never write it anywhere."""
    engine, host, port = _binding(engine, host, port)
    value = _read(engine, host, port, source, run)
    apikey.remember(value)
    yield value


# ---------------------------------------------------------------------------------- status, set, forget (terminal commands)
def _security_call(run, argv: list):
    return run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=apikey.READ_TIMEOUT_S,
               env=apikey._security_env())


def secret_status(engine: str, host: str, port: int, *, run=subprocess.run) -> dict:
    """Is there a Keychain item for this binding? Asks WITHOUT ``-w``: the secret is not read, not even into this process. Returns
    ``{engine, service, account, present, reason}``; ``reason`` is ok | missing | timeout | error | no_tool | unbound. Never the value."""
    try:
        engine, host, port = _binding(engine, host, port)
    except CredentialUnavailable as exc:
        return {"engine": engine if isinstance(engine, str) and _ENGINE.fullmatch(engine) else "", "service": None, "account": None,
                "present": False, "reason": exc.reason}
    service, account = service_name(engine), account_name(host, port)
    result = {"engine": engine, "service": service, "account": account, "present": False, "reason": "error"}
    try:
        done = _security_call(run, [apikey.security_bin(), "find-generic-password", "-s", service, "-a", account])
    except subprocess.TimeoutExpired:
        result["reason"] = "timeout"
    except OSError:
        result["reason"] = "no_tool"
    else:
        if done.returncode == 0:
            result.update(present=True, reason="ok")
        elif done.returncode == apikey.ITEM_NOT_FOUND_EXIT:
            result["reason"] = "missing"
    return result


def set_secret_interactive(engine: str, host: str, port: int, *, run=subprocess.run) -> int:
    """Store a secret: ``security add-generic-password -U -a <account> -s <service> -w`` with stdin/stdout/stderr inherited, so the macOS
    tool prompts for the secret on the terminal itself (no echo; nothing passes through this process, nothing is on argv). Refused unless
    stdin is a terminal. Exit codes: 0 stored, 1 the tool failed, 2 not a terminal or a binding that cannot hold a secret."""
    stdin = sys.stdin
    if stdin is None or not stdin.isatty():
        print("error: storing a secret must run in a terminal (stdin is not a TTY): open Terminal and run mcap asr-engines secret set",
              file=sys.stderr)
        return 2
    try:
        engine, host, port = _binding(engine, host, port)
        service, account = service_name(engine), account_name(host, port)
    except CredentialUnavailable:
        print("error: this engine, host and port cannot hold a stored secret", file=sys.stderr)
        return 2
    if apikey.security_bin() != apikey.DEFAULT_SECURITY_BIN:
        print(f"WARNING: ${apikey.SECURITY_BIN_ENV} is set: the secret would be typed into {apikey.security_bin()} instead of "
              f"{apikey.DEFAULT_SECURITY_BIN}. Press Ctrl-C now and run `unset {apikey.SECURITY_BIN_ENV}` unless that is what you want.",
              file=sys.stderr, flush=True)
    print(f"Storing the secret for engine '{engine}' in the macOS Keychain (service '{service}', account '{account}').\n"
          "The macOS security tool asks for it now; what you type is not shown and never goes through this program.", flush=True)
    try:
        rc = run([apikey.security_bin(), "add-generic-password", "-U", "-a", account, "-s", service, "-w"],
                 env=apikey._security_env()).returncode
    except OSError as exc:
        print(f"error: cannot run {apikey.security_bin()}: {exc.strerror or type(exc).__name__}", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"error: the security tool exited with {rc}: nothing was stored (or the update was refused)", file=sys.stderr)
        return 1
    if not secret_status(engine, host, port, run=run)["present"]:
        print("warning: the security tool reported success but the item cannot be found afterwards", file=sys.stderr)
        return 1
    print("Stored.")
    return 0


def forget_secret(engine: str, host: str, port: int, *, run=subprocess.run) -> int:
    """Delete the Keychain item of this binding. 0 deleted or nothing there, 1 the tool failed (2 for a binding that cannot hold one)."""
    try:
        engine, host, port = _binding(engine, host, port)
        service, account = service_name(engine), account_name(host, port)
    except CredentialUnavailable:
        print("error: this engine, host and port cannot hold a stored secret", file=sys.stderr)
        return 2
    try:
        done = _security_call(run, [apikey.security_bin(), "delete-generic-password", "-s", service, "-a", account])
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"error: cannot run the security tool: {type(exc).__name__}", file=sys.stderr)
        return 1
    if done.returncode == 0:
        print(f"Deleted the Keychain item (service '{service}', account '{account}').")
        return 0
    if done.returncode == apikey.ITEM_NOT_FOUND_EXIT:
        print(f"Nothing to delete: no Keychain item (service '{service}', account '{account}').")
        return 0
    print(f"error: the security tool exited with {done.returncode}: the item was not deleted", file=sys.stderr)
    return 1
