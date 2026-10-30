"""The only door for outbound ASR traffic, and the socket tripwire that watches every other door
(SPEC 18).

Stdlib only (``truststore`` is imported lazily and is optional). Importing this module opens no socket, reads no file and starts no
process; the default local pipeline never imports it.

``EgressGuard.request`` is what an external engine (``asr_http.HttpEngine``) calls. Before any socket exists it checks, and refuses
with ``EgressDenied`` (a fixed message, never the URL, a header or server text):
    https only, no userinfo, a plain lower-case IDNA DNS name (no wildcard, no trailing dot, no IP literal) that EXACTLY equals a host
    of the rules it was built with, the rule's port, a request body within ``HostRule.max_request_bytes``, headers that cannot smuggle a
    second request, for ``trust="private"`` a rule that carries a bound private CA (see below), and a ``pre_connect`` callback that
    re-reads the lane gate (SPEC 18) before EVERY attempt and must return None (anything else is a closed lane).
The rules are built by the caller from (consent or org consent) INTERSECT (policy allowed_hosts): a host the policy excluded is simply
not in the mapping. After the answer: any 3xx is ``EgressDenied("redirect")`` (never followed), a body over
``max_response_bytes`` is ``EgressDenied("response_too_large")``. Network failures are plain ``EgressError`` with a short code
(``connect``, ``timeout``, ``tls``, ``protocol``, ``bad_request``, ``transport``): a caller maps ``EgressDenied`` to "this destination is
not permitted" and the other ``EgressError`` codes to "try again / fall back".

``HttpsTransport`` is stdlib ``http.client`` + ``ssl`` and nothing else: no ``requests``/``urllib.request`` (proxy variables, ``.netrc``,
``REQUESTS_CA_BUNDLE``), no environment variable is read (``HTTPS_PROXY``, ``SSL_CERT_FILE``, ``SSL_CERT_DIR``, ``SSLKEYLOGFILE`` have no
effect), TLS 1.2 or newer, ``CERT_REQUIRED``, ``check_hostname``, a new connection per request. A host whose rule carries a private CA
(``ca_pem_sha256`` + ``ca_file``) trusts ONLY that CA: the file is read once, hashed, and the very bytes that were hashed are handed
to ``load_verify_locations(cadata=...)`` (no gap between check and use; the system store is never loaded). A host without one (a cloud
vendor) uses ``truststore`` (the OS trust store; the residual risk of an enterprise TLS-inspection root is SPEC 18), else the macOS
bundle ``/etc/ssl/cert.pem``. ``EgressGuard(trust="private")`` is for the server tier: the system store is never an
option for it, a rule without a bound private CA is ``EgressDenied("ca_unbound")`` before any socket exists (the consent that made the
rule may lack a ``ca_sha256``; this is the last line). ``HostRule.cert_sha256`` optionally pins the leaf certificate (checked after the
handshake, before any request byte is sent).

``timeout`` is the budget of the WHOLE exchange (connect, send, answer), not of one socket operation: a watchdog shuts the socket down
when it is spent, so a server that drips its answer a byte at a time cannot keep a request alive (the answer header block is also
bounded in size, and an answer that ends inside it is a ``protocol`` error). Connecting and the TLS handshake have their own socket
timeouts; DNS resolution has none in-process (a residual risk). A server that answers BEFORE it has read a large body and hangs up
(401, 403, 413, 429, 503 with Retry-After) is heard: an error status that is readable after the send failed is returned as the answer,
anything else stays ``connect``.

``Tripwire`` is the in-process half: while installed it patches ``socket.socket.connect/connect_ex/sendto/sendmsg``,
``socket.getaddrinfo/gethostbyname(_ex)`` and ``socket.create_connection`` so that any destination other than loopback (and AF_UNIX
and other non-IP families) is refused with ``EgressViolation`` ("strict"), or only counted and warned about by a host hash ("audit").
``EgressGuard.request`` runs the transport inside ``authorized(host, port)``: a thread-local grant for exactly that host, port and the
addresses its own lookup returned, so another thread, another host and a later call are still refused. Installs are reference counted
(a sweep nests runs in one process); the strictest live install wins. This is a defence against mistakes and curiosity, not a sandbox: it sees Python sockets of this process only.

Nothing is cached on disk and nothing secret is ever put in an exception message, a log line or a usage record.

How the packages after this one use it
  * ``asr_http.HttpEngine`` builds ``EgressGuard(decision.hosts, engine_id=..., consent_id=decision.consent_ids[engine], usage=..., secrets=
    lambda: (token,), pre_connect=<the lane gate: raises when a lane closed, or returns a LaneBlock>, trust="private" for a kind=server
    engine, "system" for a cloud vendor)``, calls ``request`` for every attempt and maps
    ``EgressDenied`` to "this destination is not permitted", any other ``EgressError`` (``connect``, ``timeout``, ``tls``, ``protocol``,
    ``bad_request``, ``transport``) to "transient", and ``asr_creds.CredentialUnavailable`` to an authentication failure.
  * ``lanes.run_scope`` calls ``Tripwire.install("strict")`` for a run that uses no external engine and may not download models, and
    ``Tripwire.install("audit")`` for a run that has an external engine; it keeps the handle and calls ``uninstall()`` when the run ends.
  * ``HostRule.cert_sha256`` is the SHA-256 (hex) of the DER encoding of the server's LEAF certificate.
"""
from __future__ import annotations

import contextlib
import functools
import hashlib
import hmac
import http.client
import ipaddress
import logging
import re
import socket
import ssl
import threading
import time
from dataclasses import dataclass, field, replace
from typing import Any, Callable, Iterator, Mapping, Optional, Protocol
from urllib.parse import urlsplit

from . import apikey
from .policy import HostRule

log = logging.getLogger("mcap.egress")

DEFAULT_TIMEOUT_S = 60.0
MAX_TIMEOUT_S = 600.0
MAX_URL_CHARS = 2048
MAX_HEADER_BYTES = 8192
MAX_RESPONSE_HEADER_BYTES = 65536                # status line + header block of an ANSWER (http.client alone allows about 6.5 MB)
MAX_CA_BYTES = 1 << 20                           # a CA bundle bigger than this is not a CA file
TRUST_MODES = ("system", "private")              # EgressGuard(trust=...): see the module docstring
SYSTEM_CA_BUNDLE = "/etc/ssl/cert.pem"           # macOS system roots: the fallback when truststore cannot be used
ALLOWED_METHODS = ("GET", "HEAD", "POST", "PUT", "DELETE")
HOP_HEADERS = frozenset({"host", "content-length", "transfer-encoding", "connection", "expect", "upgrade", "te", "trailer",
                         "proxy-authorization", "proxy-connection", "keep-alive"})   # set by the transport (or never allowed)
LOOPBACK_NAMES = ("localhost", "localhost.localdomain")

_MESSAGES = {
    "url": "the URL is malformed",
    "scheme": "only https is allowed",
    "userinfo": "credentials inside the URL are not allowed",
    "host": "the host name is not acceptable",
    "ip_literal": "an IP address is not accepted as a server name",
    "trailing_dot": "a trailing dot in the host name is not allowed",
    "host_not_allowed": "the host is not allowed for this engine",
    "port": "the port is not the allowed one",
    "bad_request": "the request is malformed",
    "request_too_large": "the request body is over the limit",
    "response_too_large": "the response is over the limit",
    "redirect": "redirects are never followed",
    "ca_unbound": "a private CA needs both a file and its sha256",
    "pre_connect": "the lane gate is closed for this request",
    "ca_unreadable": "the CA file cannot be used",
    "ca_mismatch": "the CA file does not match its sha256",
    "cert_pin": "the server certificate does not match the pin",
    "no_trust_store": "no system trust store is available",
    "connect": "the connection failed",
    "timeout": "the request timed out",
    "tls": "the TLS handshake or the certificate check failed",
    "protocol": "the answer was not valid HTTP",
    "transport": "the transport failed",
    "tripwire": "an outbound connection was blocked",
}


# ---------------------------------------------------------------------------------- errors
class EgressError(Exception):
    """An outbound request did not happen or did not complete. ``code`` is a short ASCII word, ``status`` the HTTP status when one
    exists. ``str()`` is a FIXED sentence built from the code (and the status): never the URL, a header value, the body or a server
    text, so an error can be logged, shown or stored as it is."""

    def __init__(self, code: str, status: Optional[int] = None):
        self.code = code
        self.status = status
        text = f"egress {code}: {_MESSAGES.get(code, 'the request failed')}"
        if status:
            text += f" (HTTP {int(status)})"
        super().__init__(text)


class EgressDenied(EgressError):
    """The request was refused by rule (before a socket, or by what the answer was): not a transient failure."""


class EgressViolation(EgressError):
    """The tripwire stopped an outbound connection that EgressGuard did not authorise."""

    def __init__(self, code: str = "tripwire"):
        super().__init__(code)


def map_exception(exc: BaseException) -> EgressError:
    """The fixed-string ``EgressError`` for anything a transport can raise. The original is dropped on purpose: ``http.client`` and
    ``ssl`` put header values, URLs and certificate details in their messages."""
    if isinstance(exc, EgressError):
        return exc
    if isinstance(exc, (TimeoutError, socket.timeout)):     # the same class from Python 3.10 on
        return EgressError("timeout")
    if isinstance(exc, ssl.SSLError):                       # includes SSLCertVerificationError (which is also a ValueError)
        return EgressError("tls")
    if isinstance(exc, http.client.HTTPException):          # includes InvalidURL, IncompleteRead, RemoteDisconnected
        return EgressError("protocol")
    if isinstance(exc, (ValueError, UnicodeError)):
        return EgressError("bad_request")
    if isinstance(exc, OSError):
        return EgressError("connect")
    return EgressError("transport")


# ---------------------------------------------------------------------------------- wire objects
@dataclass
class Response:
    """What came back. ``body`` and ``headers`` are left out of ``repr`` (a transcript or a cookie must not reach a log by accident).
    ``headers`` has lower-case names; ``elapsed_ms``, ``bytes_out`` (request body) and ``bytes_in`` (response body) are filled in by
    the guard."""
    status: int
    headers: Mapping[str, str] = field(repr=False)
    body: bytes = field(repr=False)
    elapsed_ms: int = 0
    bytes_out: int = 0
    bytes_in: int = 0


class Transport(Protocol):
    """Sends one already-validated request to ``rule.host:rule.port`` and returns the answer (no redirects, no retries). Tests inject
    an in-process implementation; ``HttpsTransport`` is the real one."""

    def send(self, rule: HostRule, method: str, target: str, headers: Mapping[str, str], body: bytes, timeout: float) -> Response: ...


# ---------------------------------------------------------------------------------- host and URL rules
_LABEL = re.compile(r"[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\Z")


def normalize_host(host: Any) -> str:
    """The lower-case ASCII (IDNA) form of a DNS name, or ``EgressDenied`` for anything else: empty, wildcard, trailing dot, IP
    literal (also the numeric last label that a resolver would read as an IPv4 address: ``127.1``, ``2130706433``, ``0x7f.1``),
    characters outside a host name, a label that is empty or too long. The result is what rules and requests are compared as."""
    if not isinstance(host, str) or not host:
        raise EgressDenied("host")
    if host.endswith("."):
        raise EgressDenied("trailing_dot")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise EgressDenied("ip_literal")
    if any(ord(ch) <= 32 or ord(ch) == 127 or ch in "*[]@:/\\%?#" for ch in host):
        raise EgressDenied("host")
    try:
        ascii_host = host.encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise EgressDenied("host") from None
    labels = ascii_host.split(".")
    if len(ascii_host) > 253 or not all(_LABEL.fullmatch(label) for label in labels):
        raise EgressDenied("host")
    last = labels[-1]
    if last.isdigit() or re.fullmatch(r"0x[0-9a-f]*", last):
        raise EgressDenied("ip_literal")
    return ascii_host


def split_url(url: Any) -> tuple[str, int, str]:
    """(normalized host, port, path+query) of an https URL, or ``EgressDenied``. Nothing here looks at a rule."""
    if not isinstance(url, str) or not url or len(url) > MAX_URL_CHARS:
        raise EgressDenied("url")
    if any(ord(ch) <= 32 or ord(ch) == 127 or ch == "\\" for ch in url) or "#" in url:
        raise EgressDenied("url")
    try:
        parts = urlsplit(url)
    except ValueError:
        raise EgressDenied("url") from None
    if parts.scheme != "https":
        raise EgressDenied("scheme")
    if "@" in parts.netloc:
        raise EgressDenied("userinfo")
    host = normalize_host(parts.hostname or "")
    try:
        port = parts.port
    except ValueError:
        raise EgressDenied("port") from None
    path = parts.path or "/"
    target = path + (("?" + parts.query) if parts.query or url.endswith("?") else "")
    if not path.startswith("/") or not target.isascii():
        raise EgressDenied("url")
    return host, 443 if port is None else port, target


_TOKEN = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")


def _clean_headers(headers: Any) -> dict:
    """A copy of the caller's headers if every name is an HTTP token and every value printable ASCII; the hop-by-hop and framing
    headers are the transport's, a caller cannot set them (a second ``Host`` or a ``Transfer-Encoding`` is a smuggling attempt)."""
    if headers is None:
        return {}
    if not isinstance(headers, Mapping):
        raise EgressDenied("bad_request")
    clean: dict[str, str] = {}
    seen: set[str] = set()
    size = 0
    for name, value in headers.items():
        if not isinstance(name, str) or not isinstance(value, str) or not _TOKEN.fullmatch(name):
            raise EgressDenied("bad_request")
        lowered = name.lower()
        if lowered in HOP_HEADERS or lowered in seen or not value.isascii():
            raise EgressDenied("bad_request")
        if any(ord(ch) < 32 and ch != "\t" or ord(ch) == 127 for ch in value):
            raise EgressDenied("bad_request")
        seen.add(lowered)
        clean[name] = value
        size += len(name) + len(value) + 4
    if size > MAX_HEADER_BYTES:
        raise EgressDenied("bad_request")
    return clean


# ---------------------------------------------------------------------------------- TLS
def _sha256_hex(value: Any) -> str:
    return str(value or "").replace(":", "").strip().lower()


def _read_ca_bytes(path: Any) -> bytes:
    """The bytes of a CA file, read ONCE (the hash is computed over exactly what this returns). A seam for tests."""
    with open(path, "rb") as fh:
        return fh.read(MAX_CA_BYTES + 1)


def ca_bound(rule: HostRule) -> bool:
    """Does the rule carry a private CA somebody vouched for: a file AND the 64 hex digits of its sha256?"""
    return bool(rule.ca_file) and bool(re.fullmatch(r"[0-9a-f]{64}", _sha256_hex(rule.ca_pem_sha256)))


def _private_ca_context(rule: HostRule) -> ssl.SSLContext:
    expected = _sha256_hex(rule.ca_pem_sha256)
    if not ca_bound(rule):
        raise EgressDenied("ca_unbound")                  # a CA file nobody vouched for, or a hash without a file: not trusted
    try:
        data = _read_ca_bytes(rule.ca_file)
    except OSError:
        raise EgressDenied("ca_unreadable") from None
    if len(data) > MAX_CA_BYTES:
        raise EgressDenied("ca_unreadable")
    if not hmac.compare_digest(hashlib.sha256(data).hexdigest(), expected):
        raise EgressDenied("ca_mismatch")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise EgressDenied("ca_unreadable") from None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)         # empty trust store: no default certs, no SSL_CERT_FILE / SSL_CERT_DIR
    try:
        ctx.load_verify_locations(cadata=text)            # the hashed bytes ARE the bytes used
    except (ssl.SSLError, ValueError):
        raise EgressDenied("ca_unreadable") from None
    return ctx


def _system_context() -> ssl.SSLContext:
    try:
        import truststore                                  # the OS trust store (Security.framework on macOS); pinned in requirements.lock
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception:                                      # not installed (a client-only venv), or unusable on this OS
        log.debug("truststore is not usable: falling back to %s", SYSTEM_CA_BUNDLE)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    try:
        ctx.load_verify_locations(cafile=SYSTEM_CA_BUNDLE)  # an explicit file: the environment is not consulted
    except (OSError, ssl.SSLError):
        raise EgressDenied("no_trust_store") from None
    return ctx


def build_ssl_context(rule: HostRule) -> ssl.SSLContext:
    """The TLS context for one destination (see the module docstring). Raises ``EgressDenied`` before any socket exists."""
    ctx = _private_ca_context(rule) if (rule.ca_pem_sha256 or rule.ca_file) else _system_context()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.check_hostname = True
    return ctx


def _lower_headers(pairs) -> dict:
    out: dict[str, str] = {}
    for name, value in pairs:
        key = str(name).lower()
        out[key] = f"{out[key]}, {value}" if key in out else str(value)
    return out


# The peer hung up while the request was still being sent (a server that rejects a large body before reading it: 401, 413, 503 ...).
_EARLY_CLOSE = (ConnectionError, ssl.SSLEOFError, ssl.SSLZeroReturnError)


class _Watchdog:
    """The hard end of ONE request: ``seconds`` after ``start()`` the socket is shut down, so a read or write that is blocked (a
    server that drips its answer a byte at a time never trips the per-operation socket timeout) fails at once. ``expired`` is set
    first, so the caller can tell this ending from a network failure. ``stop()`` waits for a shutdown in flight: the connection is
    never closed (and its descriptor never reused) under it."""

    def __init__(self, seconds: float):
        self.expired = threading.Event()
        self._sock = None
        self._timer = threading.Timer(seconds, self._fire)
        self._timer.daemon = True

    def start(self) -> None:
        self._timer.start()

    def attach(self, sock) -> None:
        """The socket to shut down, handed over right after connecting: ``http.client`` lets go of ``conn.sock`` as soon as it has an
        answer to read (``Connection: close`` passes the connection to the answer), so the connection object cannot be asked later."""
        self._sock = sock
        if self.expired.is_set():                           # the budget ran out while connecting
            self._shutdown()

    def stop(self) -> None:
        self._timer.cancel()
        if self._timer.is_alive():
            self._timer.join()

    def check(self) -> None:
        if self.expired.is_set():
            raise EgressError("timeout")

    def _fire(self) -> None:
        self.expired.set()                                  # first: attach() and the reader look at it
        self._shutdown()

    def _shutdown(self) -> None:
        sock = self._sock                                   # None while still connecting: connect() has its own socket timeout
        if sock is not None:
            with contextlib.suppress(Exception):
                socket.socket.shutdown(sock, socket.SHUT_RDWR)   # the plain socket call: SSLSocket.shutdown would unwrap TLS under the reader


class _EofWatch:
    """Wraps the buffered reader of an answer while its header block is parsed: counts the bytes and notes an end of stream."""

    def __init__(self, fp):
        self._fp = fp
        self.eof = False
        self.size = 0

    def readline(self, *args):
        line = self._fp.readline(*args)
        if not line:
            self.eof = True                               # http.client reads this as 'the header block is complete'
        self.size += len(line)
        if self.size > MAX_RESPONSE_HEADER_BYTES:
            raise http.client.LineTooLong("response header block")
        return line

    def __getattr__(self, name):
        return getattr(self._fp, name)


class _StrictResponse(http.client.HTTPResponse):
    """An answer whose status line and headers are bounded in size and that must be complete: ``http.client`` alone accepts a server
    that closes in the middle of the header block (or right after the status line) as an answer with fewer headers and no body."""

    def begin(self):
        real = self.fp
        watch = _EofWatch(real)
        self.fp = watch
        try:
            super().begin()
        finally:
            if self.fp is watch:
                self.fp = real
        if watch.eof:
            raise http.client.IncompleteRead(b"")


class HttpsTransport:
    """The real ``Transport``: one new TLS connection per request to ``rule.host:rule.port`` (never the host of the URL: the guard
    already proved they are the same), ``Connection: close``, no proxy, no redirect, response body read with a hard bound, the whole
    exchange within ``timeout`` seconds (see ``_Watchdog``)."""

    def __init__(self, *, ssl_context_factory: Optional[Callable[[HostRule], ssl.SSLContext]] = None):
        self._factory = ssl_context_factory or build_ssl_context

    def send(self, rule, method, target, headers, body, timeout) -> Response:
        ctx = self._factory(rule)                           # EgressDenied (CA, trust store) here, before any socket
        started = time.monotonic()
        conn = http.client.HTTPSConnection(rule.host, rule.port, timeout=timeout, context=ctx)
        conn.response_class = _StrictResponse
        dog = _Watchdog(timeout)
        resp = None
        try:
            try:
                dog.start()
                conn.connect()
                dog.attach(conn.sock)
                dog.check()
                self._check_pin(conn, rule)
                send_headers = dict(headers)
                send_headers["Connection"] = "close"
                early: Optional[BaseException] = None
                try:
                    conn.request(method, target, body=(body if (body or method in ("POST", "PUT")) else None), headers=send_headers)
                except _EARLY_CLOSE as exc:
                    early = exc                             # the server may have answered before it read the body: look for the answer
                if early is not None:
                    dog.check()
                try:
                    resp = conn.getresponse()
                except Exception:
                    if early is None:
                        raise
                    raise map_exception(early) from None
                if early is not None and int(resp.status) < 400:
                    raise map_exception(early) from None    # an answer to a body that did not arrive whole is not an answer
                limit = int(rule.max_response_bytes)
                answer = _lower_headers(resp.getheaders())
                declared = answer.get("content-length", "").strip()
                declared_length = None
                if declared.isascii() and declared.isdigit():
                    declared_length = int(declared) if len(declared) <= 18 else limit + 1     # int() of thousands of digits raises
                if declared_length is not None and declared_length > limit:
                    raise EgressDenied("response_too_large")
                try:
                    data = b"" if method == "HEAD" else resp.read(limit + 1)
                except (OSError, http.client.HTTPException):
                    if early is None:
                        raise
                    data = b""                              # an early answer: the status and Retry-After are what counts, the body may be lost
                dog.check()                                 # a body cut short by the watchdog is not an answer
                if len(data) > limit:
                    raise EgressDenied("response_too_large")
                if (early is None and declared_length is not None and method != "HEAD" and len(data) < declared_length
                        and int(resp.status) not in (204, 304) and not 100 <= int(resp.status) < 200):
                    raise EgressError("protocol")           # closed before the declared length: http.client returns the short read silently
                return Response(int(resp.status), answer, data, int((time.monotonic() - started) * 1000), len(body or b""), len(data))
            except EgressError:
                raise
            except Exception as exc:
                raise (EgressError("timeout") if dog.expired.is_set() else map_exception(exc)) from None
        finally:
            dog.stop()
            with contextlib.suppress(Exception):
                if resp is not None:
                    resp.close()                            # the answer owns the socket once it was asked for (Connection: close)
            with contextlib.suppress(Exception):
                conn.close()

    @staticmethod
    def _check_pin(conn, rule: HostRule) -> None:
        pins = [_sha256_hex(pin) for pin in (rule.cert_sha256 or ())]
        if not pins:
            return
        der = conn.sock.getpeercert(binary_form=True) if conn.sock is not None else None
        digest = hashlib.sha256(der or b"").hexdigest()
        if not der or not any(hmac.compare_digest(digest, pin) for pin in pins):
            raise EgressDenied("cert_pin")


# ---------------------------------------------------------------------------------- the guard
_LABEL_CHARS = re.compile(r"[^A-Za-z0-9_.:/\-]")


class EgressGuard:
    """Validates and sends requests for ONE engine to the hosts of ``rules`` (host -> HostRule). See the module docstring.

    ``usage`` (optional) is called once per ``request``, whatever its outcome, with a content-free dict
    ``{engine, consent_id, host, op, path_label, status, bytes_out, bytes_in, dur_ms, outcome}``; ``outcome`` is ``ok``, ``http_<status>``,
    ``error:<code>`` or ``denied:<code>`` (``denied:pre_connect`` when the lane gate said no). ``host`` is "" unless the request got as far
    as an allowed host. An exception inside ``usage`` is swallowed. ``secrets`` returns the strings that must never be printed (the
    bearer token); they are registered with ``apikey.remember`` before every request. ``pre_connect`` runs before EVERY attempt, after
    validation and before the transport; whatever it raises propagates unchanged (it is the lane gate: the exception is the caller's).
    It must return None to let the request through: ANY other value (``RunPrivacy.lane_block`` and ``lanes.gate`` return a
    ``LaneBlock``, never raise) is a closed lane and ends as ``EgressDenied("pre_connect")``, so a gate passed in as it is cannot
    fail open. ``trust`` is ``"system"`` (default: a rule without a private CA uses the OS trust store, the cloud vendors) or
    ``"private"`` (the server tier: every rule must carry a bound private CA, else ``EgressDenied("ca_unbound")``).
    """

    def __init__(self, rules: Mapping[str, HostRule], *, engine_id: str, consent_id: str, transport: Optional[Transport] = None,
                 usage: Optional[Callable[[dict], None]] = None, clock: Callable[[], float] = time.monotonic,
                 secrets: Callable[[], Any] = lambda: (), pre_connect: Optional[Callable[[], Any]] = None, trust: str = "system"):
        if trust not in TRUST_MODES:
            raise ValueError(f"trust must be one of {TRUST_MODES}")
        self.engine_id = engine_id
        self.consent_id = consent_id
        self._trust = trust
        self._rules: dict[str, HostRule] = {}
        for key, rule in dict(rules or {}).items():
            try:
                host = normalize_host(getattr(rule, "host", ""))
                if not isinstance(key, str) or normalize_host(key) != host:
                    raise EgressDenied("host")
                port = int(rule.port)
                if not 0 < port < 65536:
                    raise EgressDenied("port")
            except (EgressDenied, TypeError, ValueError):
                log.warning("egress: a host rule for engine %s is not acceptable and is ignored", engine_id)
                continue
            self._rules[host] = rule if rule.host == host else replace(rule, host=host)
        self._transport = transport
        self._usage = usage
        self._clock = clock
        self._secrets = secrets
        self._pre_connect = pre_connect

    @property
    def hosts(self) -> tuple:
        return tuple(sorted(self._rules))

    # ------------------------------------------------------------------------------------------ request
    def request(self, method: str, url: str, *, headers: Optional[Mapping[str, str]] = None, body: Any = b"",
                timeout: float = DEFAULT_TIMEOUT_S, path_label: str) -> Response:
        started = self._clock()
        record = {"host": "", "status": 0, "bytes_out": 0, "bytes_in": 0, "outcome": "error:unknown"}
        try:
            response = self._request(method, url, headers, body, timeout, record, started)
        except EgressDenied as exc:
            record["outcome"] = f"denied:{exc.code}"
            raise
        except EgressError as exc:
            record["outcome"] = f"error:{exc.code}"
            raise
        except BaseException:
            record["outcome"] = record["outcome"] if record["outcome"].startswith("denied:") else "error:aborted"
            raise
        else:
            record["outcome"] = "ok" if 200 <= response.status < 300 else f"http_{response.status}"
            return response
        finally:
            self._note(record, method, path_label, started)

    def _request(self, method, url, headers, body, timeout, record, started) -> Response:
        self._remember_secrets()
        verb = method.upper() if isinstance(method, str) else ""
        if verb not in ALLOWED_METHODS:
            raise EgressDenied("bad_request")
        host, port, target = split_url(url)
        rule = self._rules.get(host)
        if rule is None:
            raise EgressDenied("host_not_allowed")
        record["host"] = host
        if port != rule.port:
            raise EgressDenied("port")
        if self._trust == "private" and not ca_bound(rule):
            raise EgressDenied("ca_unbound")                  # the server tier never falls back to the system trust store
        clean = _clean_headers(headers)
        if body is None:
            body = b""
        if not isinstance(body, (bytes, bytearray, memoryview)):
            raise EgressDenied("bad_request")
        payload = bytes(body)
        record["bytes_out"] = len(payload)
        if len(payload) > int(rule.max_request_bytes):
            raise EgressDenied("request_too_large")
        try:
            seconds = float(timeout)
        except (TypeError, ValueError):
            raise EgressDenied("bad_request") from None
        if not 0 < seconds:
            raise EgressDenied("bad_request")
        seconds = min(seconds, MAX_TIMEOUT_S)

        if self._pre_connect is not None:
            try:
                verdict = self._pre_connect()
            except BaseException:
                record["outcome"] = "denied:pre_connect"
                raise
            if verdict is not None:                           # a LaneBlock (or anything else) handed back instead of raised: closed
                raise EgressDenied("pre_connect")
        transport = self._transport
        if transport is None:
            transport = self._transport = HttpsTransport()
        try:
            with authorized(rule.host, rule.port):
                answer = transport.send(rule, verb, target, clean, payload, seconds)
        except Exception as exc:
            raise map_exception(exc) from None
        status = answer.status if isinstance(answer, Response) else 0
        if not isinstance(status, int) or isinstance(status, bool) or not 100 <= status <= 599:
            raise EgressError("protocol")
        if not isinstance(answer.body, (bytes, bytearray)):
            raise EgressError("protocol")
        record["status"] = status
        record["bytes_in"] = len(answer.body)
        if 300 <= status < 400:
            raise EgressDenied("redirect", status)
        if len(answer.body) > int(rule.max_response_bytes):
            raise EgressDenied("response_too_large")
        headers_in = {str(k).lower(): str(v) for k, v in dict(answer.headers or {}).items()}
        return replace(answer, headers=headers_in, body=bytes(answer.body), elapsed_ms=int((self._clock() - started) * 1000),
                       bytes_out=len(payload), bytes_in=len(answer.body))

    # ------------------------------------------------------------------------------------------ bookkeeping
    def _remember_secrets(self) -> None:
        try:
            for value in self._secrets() or ():
                apikey.remember(value)
        except Exception:
            log.debug("egress: the secrets callback failed (%s)", "ignored")

    def _label(self, label: Any) -> str:
        text = apikey.redact(label) if isinstance(label, str) else ""
        return _LABEL_CHARS.sub("?", text)[:40] or "-"

    def _note(self, record: dict, method: Any, path_label: Any, started: float) -> None:
        if self._usage is None:
            return
        entry = {"engine": self.engine_id, "consent_id": self.consent_id, "host": record["host"],
                 "op": method.upper() if isinstance(method, str) and method.upper() in ALLOWED_METHODS else "?",
                 "path_label": self._label(path_label), "status": record["status"], "bytes_out": record["bytes_out"],
                 "bytes_in": record["bytes_in"], "dur_ms": int((self._clock() - started) * 1000), "outcome": record["outcome"]}
        try:
            self._usage(entry)
        except Exception:
            log.debug("egress: the usage callback failed (%s)", "ignored")


# ---------------------------------------------------------------------------------- tripwire
class _Auth:
    """One thread-local grant: this host and port, and the addresses its own lookup returned while the grant was open."""

    def __init__(self, host: str, port: int):
        self.host, self.port = host, port
        self.addresses: set[str] = set()

    def covers_name(self, host: str, port: Optional[int]) -> bool:
        return host == self.host and (port is None or port == self.port)


_local = threading.local()


def _grants() -> list:
    stack = getattr(_local, "stack", None)
    if stack is None:
        stack = _local.stack = []
    return stack


@contextlib.contextmanager
def authorized(host: str, port: int) -> Iterator[None]:
    """Grant THIS thread one outbound destination for the length of the block (see Tripwire). A no-op while no tripwire is installed.
    ``EgressGuard.request`` is the only caller in the product."""
    grant = _Auth(str(host).lower(), int(port))
    stack = _grants()
    stack.append(grant)
    try:
        yield
    finally:
        stack.remove(grant)


def _plain_host(host: Any) -> Optional[str]:
    if host is None:
        return None
    if isinstance(host, (bytes, bytearray)):
        host = bytes(host).decode("ascii", "replace")
    return str(host).strip().lower()


def _plain_port(port: Any) -> Optional[int]:
    if isinstance(port, bool):
        return None
    if isinstance(port, int):
        return port
    if isinstance(port, (str, bytes)) and str(port.decode() if isinstance(port, bytes) else port).isdigit():
        return int(port)
    return None


def _is_loopback(host: Optional[str]) -> bool:
    if host is None or host == "":
        return True                                         # a passive lookup / bind
    if host in LOOPBACK_NAMES:
        return True
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    return ip.is_loopback or bool(getattr(ip, "ipv4_mapped", None) and ip.ipv4_mapped.is_loopback)


class Tripwire:
    """Reference-counted socket tripwire (see the module docstring). ``Tripwire.install(mode)`` returns a handle; ``handle.uninstall()``
    releases it (idempotent); the patches come off when the last handle is released. Usable as a context manager."""

    _lock = threading.RLock()
    _handles: list["Tripwire"] = []
    _patched: list[tuple[Any, str, Any, Any]] = []        # (owner, name, original, wrapper)
    _audit: dict[str, int] = {}

    def __init__(self, mode: str):
        self.mode = mode
        self._live = False

    # ------------------------------------------------------------------------------------------ install / uninstall
    @classmethod
    def install(cls, mode: str = "strict") -> "Tripwire":
        if mode not in ("strict", "audit"):
            raise ValueError("Tripwire mode must be 'strict' or 'audit'")
        with cls._lock:
            handle = cls(mode)
            if not cls._handles:
                cls._patch()
            handle._live = True
            cls._handles.append(handle)
        return handle

    def uninstall(self) -> None:
        cls = type(self)
        with cls._lock:
            if not self._live:
                return
            self._live = False
            cls._handles.remove(self)
            if not cls._handles:
                cls._unpatch()

    def __enter__(self) -> "Tripwire":
        return self

    def __exit__(self, *exc) -> None:
        self.uninstall()

    def __repr__(self) -> str:
        return f"Tripwire(mode={self.mode!r}, live={self._live})"

    @contextlib.contextmanager
    def authorized(self, host: str, port: int) -> Iterator[None]:
        with authorized(host, port):
            yield

    @classmethod
    def uninstall_all(cls) -> None:
        """Drop every handle and restore the sockets (test teardown after a failure)."""
        with cls._lock:
            for handle in cls._handles:
                handle._live = False
            cls._handles.clear()
            cls._unpatch()

    @classmethod
    def active(cls) -> bool:
        return bool(cls._handles)

    @classmethod
    def effective_mode(cls) -> Optional[str]:
        """"strict" while any live handle is strict, "audit" while only audit handles are live, None when nothing is installed."""
        with cls._lock:
            if not cls._handles:
                return None
            return "strict" if any(h.mode == "strict" for h in cls._handles) else "audit"

    @classmethod
    def audit_counts(cls) -> dict:
        """host hash (first 8 hex of sha256 of the lower-case host) -> number of unauthorised attempts seen in audit mode."""
        with cls._lock:
            return dict(cls._audit)

    @classmethod
    def reset_audit(cls) -> None:
        with cls._lock:
            cls._audit.clear()

    # ------------------------------------------------------------------------------------------ patching
    @classmethod
    def _patch(cls) -> None:
        for name in ("connect", "connect_ex", "sendto", "sendmsg"):
            original = getattr(socket.socket, name, None)
            if original is not None:
                cls._set(socket.socket, name, original, cls._method_wrapper(name, original))
        for name, make in (("getaddrinfo", cls._lookup_wrapper), ("gethostbyname", cls._lookup_wrapper),
                           ("gethostbyname_ex", cls._lookup_wrapper), ("create_connection", cls._connection_wrapper)):
            original = getattr(socket, name, None)
            if original is not None:
                cls._set(socket, name, original, make(name, original))

    @classmethod
    def _set(cls, owner, name, original, wrapper) -> None:
        setattr(owner, name, wrapper)
        cls._patched.append((owner, name, original, wrapper))

    @classmethod
    def _unpatch(cls) -> None:
        for owner, name, original, wrapper in reversed(cls._patched):
            if getattr(owner, name, None) is wrapper:       # something installed on top of us since: leave its patch alone (our wrapper
                setattr(owner, name, original)              # is a pass-through once no handle is live)
        cls._patched.clear()

    @classmethod
    def _method_wrapper(cls, name: str, original: Callable) -> Callable:
        @functools.wraps(original)
        def wrapper(sock, *args, **kwargs):
            if cls._handles and getattr(sock, "family", None) in (socket.AF_INET, socket.AF_INET6):
                cls._check_address(sock, name, args, kwargs)
            return original(sock, *args, **kwargs)
        return wrapper

    @classmethod
    def _lookup_wrapper(cls, name: str, original: Callable) -> Callable:
        @functools.wraps(original)
        def wrapper(*args, **kwargs):
            grant = None
            if cls._handles:
                host = _plain_host(args[0] if args else kwargs.get("host", kwargs.get("hostname")))
                port = _plain_port(args[1] if len(args) > 1 else kwargs.get("port")) if name == "getaddrinfo" else None
                grant = cls._grant_for_name(host, port)
            result = original(*args, **kwargs)
            if grant is not None:
                cls._remember_addresses(grant, name, result)
            return result
        return wrapper

    @classmethod
    def _connection_wrapper(cls, name: str, original: Callable) -> Callable:
        @functools.wraps(original)
        def wrapper(address, *args, **kwargs):
            if cls._handles:
                host, port = (address[0], address[1]) if isinstance(address, tuple) and len(address) >= 2 else (None, None)
                cls._grant_for_name(_plain_host(host), _plain_port(port))
            return original(address, *args, **kwargs)
        return wrapper

    @classmethod
    def _grant_for_name(cls, host: Optional[str], port: Optional[int]) -> Optional[_Auth]:
        """The grant that covers a lookup or a connect by NAME; loopback needs none (None); anything else is refused / audited."""
        if _is_loopback(host):
            return None
        for grant in reversed(_grants()):
            if grant.covers_name(host or "", port):
                return grant
        cls._refuse(host)
        return None

    @staticmethod
    def _remember_addresses(grant: _Auth, name: str, result: Any) -> None:
        try:
            if name == "getaddrinfo":
                grant.addresses.update(str(item[4][0]).split("%", 1)[0] for item in result)
            elif name == "gethostbyname":
                grant.addresses.add(str(result))
            elif name == "gethostbyname_ex":
                grant.addresses.update(str(ip) for ip in result[2])
        except (TypeError, IndexError, KeyError):
            pass

    @classmethod
    def _check_address(cls, sock, name: str, args: tuple, kwargs: dict) -> None:
        if name in ("connect", "connect_ex"):
            address = args[0] if args else kwargs.get("address")
        elif name == "sendto":
            address = args[-1] if len(args) >= 2 else kwargs.get("address")
        else:                                              # sendmsg(buffers, ancdata=(), flags=0, address=None)
            address = args[3] if len(args) > 3 else kwargs.get("address")
            if address is None:
                return                                     # a send on a connected socket: its connect was judged
        if not isinstance(address, tuple) or len(address) < 2:
            return                                         # not an IP destination: the real call rejects it itself
        host, port = (_plain_host(address[0]) or "").split("%", 1)[0], _plain_port(address[1])
        if _is_loopback(host):
            return
        for grant in reversed(_grants()):
            if port == grant.port and (host in grant.addresses or host == grant.host):
                return
        cls._refuse(host)

    @classmethod
    def _refuse(cls, host: Optional[str]) -> None:
        if cls.effective_mode() == "strict":
            raise EgressViolation("tripwire")
        digest = hashlib.sha256((host or "").encode("utf-8", "replace")).hexdigest()[:8]
        with cls._lock:
            count = cls._audit[digest] = cls._audit.get(digest, 0) + 1
        if count in (1, 10, 100, 1000, 10000):
            log.warning("tripwire audit: outbound connection without authorisation (host sha256 %s, %d so far)", digest, count)
