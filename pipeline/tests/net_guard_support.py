"""Shared helpers for every test file that touches the outbound-network code (stdlib only).

  * ``NoNetworkCase``: the base class of every later test class of the external-ASR work. It is a ``TempCase`` (a temp root, a FAKE
    `security`), it makes this Mac look policy-free whatever /Library really holds (``self.system_policy(True)`` pretends there is one:
    $MCAP_SECURITY_BIN and the other test hooks are ignored then, exactly as on a managed Mac, so the code under test would reach for
    /usr/bin/security: any attempt to START that binary, in any spelling, raises ``RealSecurityAttempt`` instead, whatever the policy
    state, so the real Keychain is unreachable from these tests) and it makes every non-loopback socket call fail: ``connect``, ``connect_ex``,
    ``sendto``, ``sendmsg``, ``getaddrinfo``, ``gethostbyname(_ex)`` and ``create_connection`` raise ``NetworkAttempt`` AND are written to
    ``self.network_attempts``. A cleanup asserts that list is empty, so code that swallows the exception still fails the test
    ("zero non-loopback connections"). Loopback and AF_UNIX calls reach the real functions. A test that wants to see what
    its code would have connected to uses ``with self.expect_network_attempts() as seen:`` (the call then fails with
    ConnectionRefusedError and is listed in ``seen`` instead of failing the test).
  * ``SocketStubs``: a context manager that replaces the same calls with recorders that never reach the network (for tests of the
    Tripwire, which wraps whatever is installed when it is switched on).
  * ``TEST_PKI``: two throw-away self-signed certificates (CN/SAN asr-a.test and asr-b.test, valid 2020 to 2120) with their keys,
    generated once with openssl for these tests only; ``write_test_pki`` puts them in a directory and ``memory_handshake`` runs a TLS
    handshake between two contexts in memory (``ssl.MemoryBIO``, no socket).
"""
from __future__ import annotations

import contextlib
import ipaddress
import os
import shutil
import socket
import ssl
import subprocess
import sys
import unittest.mock as mock
from pathlib import Path
from typing import Callable, Iterator, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # pipeline/ on sys.path when run via discover

from mcap import config  # noqa: E402
from notes_cli_support import TempCase  # noqa: E402

SOCKET_METHODS = ("connect", "connect_ex", "sendto", "sendmsg")
MODULE_FUNCTIONS = ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "create_connection")
INET_FAMILIES = (socket.AF_INET, socket.AF_INET6)
TEST_NET_ADDRESS = "203.0.113.9"                 # RFC 5737 TEST-NET-3: what SocketStubs.getaddrinfo answers by default
REAL_SECURITY = "/usr/bin/security"              # the macOS Keychain tool: no test may start it


class NetworkAttempt(AssertionError):
    """A test reached for a non-loopback destination."""


class RealSecurityAttempt(AssertionError):
    """A test tried to start the real macOS `security` tool (the login Keychain of whoever runs the suite)."""


def _resolves_to_real_security(word) -> bool:
    try:
        word = os.fsdecode(word)
    except TypeError:
        return False
    found = word if os.sep in word else shutil.which(word)
    return bool(found) and os.path.realpath(found) == os.path.realpath(REAL_SECURITY)


def is_real_security(args, executable=None) -> bool:
    """Would ``subprocess.Popen(args, executable=executable)`` start /usr/bin/security? ``executable``, the first item of a list or a
    tuple, a path-like, or (a shell command string) any word of the string; a bare ``security`` is looked up on PATH and a link to the
    tool counts (the real paths are compared)."""
    if executable is not None:
        return _resolves_to_real_security(executable)
    if isinstance(args, (str, bytes)):
        return any(_resolves_to_real_security(word) for word in os.fsdecode(args).split())
    if isinstance(args, os.PathLike):
        return _resolves_to_real_security(args)
    try:
        return _resolves_to_real_security(args[0])
    except (TypeError, IndexError, KeyError):
        return False


class _GuardedPopen(subprocess.Popen):
    """The real ``Popen`` that refuses to start /usr/bin/security (``subprocess.run`` and friends call ``Popen`` by its module name, so
    patching it covers a ``run=subprocess.run`` default that was bound at import time too)."""

    def __init__(self, args, *popenargs, **kwargs):
        if is_real_security(args, kwargs.get("executable")):
            raise RealSecurityAttempt("a test started the real /usr/bin/security (the Keychain of the person running the tests)")
        super().__init__(args, *popenargs, **kwargs)


def is_loopback_address(host) -> bool:
    """True for loopback names and addresses (and the empty host of a passive lookup)."""
    if host is None or host == "" or host == b"":
        return True
    if isinstance(host, bytes):
        host = host.decode("ascii", "replace")
    text = str(host).strip().lower()
    if text in ("localhost", "localhost.localdomain"):
        return True
    try:
        ip = ipaddress.ip_address(text.split("%", 1)[0])
    except ValueError:
        return False
    if ip.is_loopback:
        return True
    return bool(getattr(ip, "ipv4_mapped", None) and ip.ipv4_mapped.is_loopback)


def _host_of(name: str, args: tuple, kwargs: dict):
    """The destination host a socket-level call is about; None when the call has none (a connected send, a non-IP family)."""
    if name in ("getaddrinfo", "gethostbyname", "gethostbyname_ex"):
        return args[0] if args else kwargs.get("host", kwargs.get("hostname"))
    address = None
    if name in ("connect", "connect_ex", "create_connection"):
        address = args[0] if args else kwargs.get("address")
    elif name == "sendto":
        address = args[-1] if len(args) >= 2 else kwargs.get("address")
    elif name == "sendmsg":
        address = args[3] if len(args) > 3 else kwargs.get("address")
    if isinstance(address, tuple) and address:
        return address[0]
    return None


class NoNetworkCase(TempCase):
    """See the module docstring. Subclass it instead of ``unittest.TestCase`` / ``TempCase`` in every test file that can reach
    egress code. ``setUp`` of a subclass must call ``super().setUp()``."""

    def setUp(self) -> None:
        super().setUp()
        self.network_attempts: list[tuple[str, str]] = []
        self._collectors: list[list] = []
        self.system_policy(False)
        self._install_blockers()
        patcher = mock.patch.object(subprocess, "Popen", _GuardedPopen)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self._assert_no_attempts)

    def system_policy(self, present: bool) -> None:
        """Make ``config.system_policy_present()`` answer ``present`` for the rest of the test, whatever the real
        /Library/Application Support/MeetingCapture holds: the policy file and the marker are redirected into the temp root (the file
        exists, with content ``{}``, only when ``present``; nothing under test reads its content). Call it again to flip."""
        base = self.root / "system-policy"
        policy_file, marker = base / "policy.json", base / "policy.required"
        if present:
            base.mkdir(parents=True, exist_ok=True)
            policy_file.write_text("{}", encoding="utf-8")
        else:
            policy_file.unlink(missing_ok=True)
        for name, path in (("POLICY_SYSTEM_PATH", policy_file), ("POLICY_REQUIRED_MARKER", marker)):
            patcher = mock.patch.object(config, name, path)
            patcher.start()
            self.addCleanup(patcher.stop)

    # ------------------------------------------------------------------------------------------ blockers
    def _install_blockers(self) -> None:
        for name in SOCKET_METHODS:
            real = getattr(socket.socket, name, None)
            if real is None:
                continue
            patcher = mock.patch.object(socket.socket, name, self._method_blocker(name, real))
            patcher.start()
            self.addCleanup(patcher.stop)
        for name in MODULE_FUNCTIONS:
            real = getattr(socket, name)
            patcher = mock.patch.object(socket, name, self._function_blocker(name, real))
            patcher.start()
            self.addCleanup(patcher.stop)

    def _method_blocker(self, name: str, real: Callable) -> Callable:
        def blocker(sock, *args, **kwargs):
            if getattr(sock, "family", None) in INET_FAMILIES:        # AF_UNIX and friends carry no network traffic
                self._refuse_unless_loopback(name, _host_of(name, args, kwargs), args, kwargs)
            return real(sock, *args, **kwargs)
        return blocker

    def _function_blocker(self, name: str, real: Callable) -> Callable:
        def blocker(*args, **kwargs):
            self._refuse_unless_loopback(name, _host_of(name, args, kwargs), args, kwargs, require_host=True)
            return real(*args, **kwargs)
        return blocker

    def _refuse_unless_loopback(self, name: str, host, args, kwargs, require_host: bool = False) -> None:
        if host is None and not require_host:
            return                                                    # a send on a connected socket: its connect was judged already
        if is_loopback_address(host):
            return
        record = (name, repr(host))
        if self._collectors:
            for collected in self._collectors:
                collected.append(record)
            raise ConnectionRefusedError(f"NoNetworkCase: {name} refused")
        self.network_attempts.append(record)
        raise NetworkAttempt(f"{name} to a non-loopback destination in a no-network test: {host!r}")

    def _assert_no_attempts(self) -> None:
        self.assertEqual(self.network_attempts, [], "the code under test tried to reach a non-loopback destination")

    @contextlib.contextmanager
    def expect_network_attempts(self) -> Iterator[list]:
        """Attempts inside the block are recorded in the yielded list (and fail with ConnectionRefusedError) instead of failing the test."""
        collected: list = []
        self._collectors.append(collected)
        try:
            yield collected
        finally:
            self._collectors.remove(collected)


# ---------------------------------------------------------------------------------------------- socket recorders
class SocketStubs:
    """``with SocketStubs() as stubs:`` replaces the socket calls of ``SOCKET_METHODS`` and ``MODULE_FUNCTIONS`` with recorders that
    never touch the network. ``stubs.calls`` is a list of ``(name, args)``; ``stubs.resolve`` maps a host name to the address
    ``getaddrinfo`` answers (default ``TEST_NET_ADDRESS``); ``keep`` names calls that stay as they are. A Tripwire installed INSIDE the
    block wraps these recorders, so what reaches ``stubs.calls`` is exactly what the Tripwire let through."""

    def __init__(self, resolve: Optional[dict] = None, keep: tuple = ()):
        self.calls: list[tuple[str, tuple]] = []
        self.resolve = dict(resolve or {})
        self.keep = tuple(keep)                    # names left as they are (e.g. "create_connection": the stdlib one runs on the stubs)
        self._patchers: list = []

    def names(self) -> list[str]:
        return [name for name, _args in self.calls]

    def _method(self, name: str) -> Callable:
        def stub(sock, *args, **kwargs):
            self.calls.append((name, args))
            return 0 if name == "connect_ex" else None
        return stub

    def _getaddrinfo(self, host, port, *args, **kwargs):
        self.calls.append(("getaddrinfo", (host, port)))
        address = self.resolve.get(host if isinstance(host, str) else None, TEST_NET_ADDRESS)
        try:
            number = int(port) if port is not None else 0
        except (TypeError, ValueError):
            number = 0
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, number))]

    def _function(self, name: str) -> Callable:
        def stub(*args, **kwargs):
            self.calls.append((name, args))
            return TEST_NET_ADDRESS if name == "gethostbyname" else None
        return stub

    def __enter__(self) -> "SocketStubs":
        for name in SOCKET_METHODS:
            if getattr(socket.socket, name, None) is not None and name not in self.keep:
                self._patchers.append(mock.patch.object(socket.socket, name, self._method(name)))
        for name in MODULE_FUNCTIONS:
            if name in self.keep:
                continue
            fake = self._getaddrinfo if name == "getaddrinfo" else self._function(name)
            self._patchers.append(mock.patch.object(socket, name, fake))
        for patcher in self._patchers:
            patcher.start()
        return self

    def __exit__(self, *exc) -> None:
        for patcher in reversed(self._patchers):
            patcher.stop()
        self._patchers.clear()


# ---------------------------------------------------------------------------------------------- throw-away TLS material
# openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -not_before 20200101000000Z -not_after 21200101000000Z
#   -subj /CN=asr-a.test -addext subjectAltName=DNS:asr-a.test -addext basicConstraints=critical,CA:TRUE   (and the same for asr-b.test)
# Test fixtures only: these keys protect nothing and are not used anywhere else.
TEST_PKI = {
    "a": {
        "host": "asr-a.test",
        "cert": """-----BEGIN CERTIFICATE-----
MIIBdjCCAR2gAwIBAgIUYo90qumitv2bMADILuw3arcLnwswCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKYXNyLWEudGVzdDAgFw0yMDAxMDEwMDAwMDBaGA8yMTIwMDEw
MTAwMDAwMFowFTETMBEGA1UEAwwKYXNyLWEudGVzdDBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABFJlWm96XffrbnYPYagGFAXMaWc0GqEMKgbnJ9sK+0CVjI0P0CiG
fkz4E1FDafZcOcTtgRcJSKHJd0ptdAdKGIajSTBHMB0GA1UdDgQWBBSDy83VXzHN
AKFin9LX3S0ZkM3HGDAVBgNVHREEDjAMggphc3ItYS50ZXN0MA8GA1UdEwEB/wQF
MAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgNIOGvLnsqei0ye5sNmcBm0+xct689wpf
DpfbTVdm+pQCICbUtlmOuQKwy8heQQlm9nkxUef2WHAZiX+FBQwO+MQG
-----END CERTIFICATE-----
""",
        "key": """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgOWtof4J3JihvoRG7
ZFol/e1JhLVDENr5iNoqtFl+tkuhRANCAARSZVpvel336252D2GoBhQFzGlnNBqh
DCoG5yfbCvtAlYyND9Aohn5M+BNRQ2n2XDnE7YEXCUihyXdKbXQHShiG
-----END PRIVATE KEY-----
""",
    },
    "b": {
        "host": "asr-b.test",
        "cert": """-----BEGIN CERTIFICATE-----
MIIBdzCCAR2gAwIBAgIUUtXj8uKgkc1bHvpd4GqMBsNhDBYwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKYXNyLWIudGVzdDAgFw0yMDAxMDEwMDAwMDBaGA8yMTIwMDEw
MTAwMDAwMFowFTETMBEGA1UEAwwKYXNyLWIudGVzdDBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABBhd8Bb48tWG1njIrKRAPTClKdg/4QggFAt/AdtDE450fmG92mmr
FqJvjNDw+2V/YOpgZeb1ycQyuRp5+11sB5ejSTBHMB0GA1UdDgQWBBRPNaeWyDrN
7KhsTP7uDfw81MTv/DAVBgNVHREEDjAMggphc3ItYi50ZXN0MA8GA1UdEwEB/wQF
MAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgA53Gihmq81ONu0sCULozVaaaV/AQf0S1
woTkqMl/bM0CIQDg+C8ETokP9dA84TE3jVclFM10i99w5K+1pT0cTsjhcA==
-----END CERTIFICATE-----
""",
        "key": """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg9khRciyjo8zQLTtU
Cs5AX10leZXSa7WwiQlkrCytZpqhRANCAAQYXfAW+PLVhtZ4yKykQD0wpSnYP+EI
IBQLfwHbQxOOdH5hvdppqxaib4zQ8Ptlf2DqYGXm9cnEMrkaeftdbAeX
-----END PRIVATE KEY-----
""",
    },
}


def write_test_pki(directory, which: str = "a") -> dict:
    """Write ``cert.pem`` and ``key.pem`` of ``TEST_PKI[which]`` into ``directory``; returns {"cert": Path, "key": Path, "host": str}."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    item = TEST_PKI[which]
    cert, key = directory / f"cert-{which}.pem", directory / f"key-{which}.pem"
    cert.write_text(item["cert"], encoding="ascii")
    key.write_text(item["key"], encoding="ascii")
    return {"cert": cert, "key": key, "host": item["host"]}


def server_context(directory, which: str = "a") -> ssl.SSLContext:
    """A server-side context presenting ``TEST_PKI[which]`` (for ``memory_handshake``)."""
    paths = write_test_pki(directory, which)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(paths["cert"]), str(paths["key"]))
    return ctx


def memory_handshake(client_ctx: ssl.SSLContext, server_ctx: ssl.SSLContext, server_hostname: str, rounds: int = 40) -> str:
    """Run a TLS handshake between a client and a server context through two ``ssl.MemoryBIO`` pairs (no socket). Returns the
    negotiated protocol version of the client; raises the client's ``ssl.SSLError`` (e.g. SSLCertVerificationError) or the server's."""
    c_in, c_out, s_in, s_out = ssl.MemoryBIO(), ssl.MemoryBIO(), ssl.MemoryBIO(), ssl.MemoryBIO()
    client = client_ctx.wrap_bio(c_in, c_out, server_hostname=server_hostname)
    server = server_ctx.wrap_bio(s_in, s_out, server_side=True)
    done = {"client": False, "server": False}
    for _ in range(rounds):
        for name, side, outgoing, peer_in in (("client", client, c_out, s_in), ("server", server, s_out, c_in)):
            if not done[name]:
                try:
                    side.do_handshake()
                    done[name] = True
                except ssl.SSLWantReadError:
                    pass
            data = outgoing.read()
            if data:
                peer_in.write(data)
        if all(done.values()):
            return client.version() or ""
    raise AssertionError("the in-memory TLS handshake did not finish")
