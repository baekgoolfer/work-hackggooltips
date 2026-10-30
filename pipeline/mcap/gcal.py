"""Google Calendar, read-only: the sign-in and the one query behind calendar autostart (docs/CALENDAR_AUTOSTART.md).

A single-user feature of the owner of the Mac, off unless the app's OFFLINE_AUTOSTART says so; this module only answers "which events are
around now?". It records nothing and starts nothing. Commands (``python -m mcap gcal ...``):

  upcoming --from-minutes N --to-minutes M   ONE JSON object on stdout, exit 0 whatever happened (the contract with the Swift app). Success
                                             ``{"schema":1,"ok":true,"now":...,"events":[...]}``, failure ``{"schema":1,"ok":false,"error":
                                             "not_configured|auth_required|network|lane_denied|policy|api_error","message":...}``.
  auth                                       browser consent (loopback redirect, PKCE S256, state), stores the token in the Keychain
  status                                     human text: client file, token, account, lane (never a secret, no network)
  forget                                     deletes the token from the Keychain

Rules (each has a test in tests/test_gcal.py)
  * Scope exactly ``https://www.googleapis.com/auth/calendar.readonly``. Nothing is ever written to the calendar.
  * The OAuth client is the OWNER'S OWN (a Desktop-app client of their own Google Cloud project): ``SUPPORT_DIR/google-oauth-client.json``, a private
    (0600) regular file in a directory only its owner can write. Only ``client_id`` and ``client_secret`` are read from it; the endpoints are the
    constants below (a file cannot send the secret to another host).
  * The refresh token and the cached access token live ONLY in the macOS Keychain (service ``MeetingCapture Google Calendar token``, account =
    user name, one JSON blob), read at call time through the ``security`` tool exactly as ``apikey`` does and written with ``security -i`` (the
    command goes through STDIN: neither the tokens nor the client secret are ever in argv, the environment, state.json, usage.jsonl or a log;
    ``apikey.remember`` registers every secret for exact masking and ``install_redaction`` adds the Google token shapes).
  * Every HTTP call goes through ``egress.EgressGuard`` (https only, exact hosts ``oauth2.googleapis.com`` and ``www.googleapis.com``, no redirect,
    no proxy or CA variable, size limits) behind the ``calendar`` lane gate. Errors are fixed sentences: never a URL, a header, a server text.
  * Event titles are content: they appear only in the JSON of ``upcoming``, never in a log line or an error.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import http.server
import json
import logging
import os
import re
import secrets
import socketserver
import stat as statmod
import subprocess
import sys
import time
import webbrowser
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import parse_qs, urlencode, urlsplit

from . import apikey, appinfo, lanes, status
from . import policy as policy_mod
from .egress import EgressDenied, EgressError, EgressGuard, Response

log = logging.getLogger("mcap.gcal")

SCHEMA = 1
LANE = "calendar"
SCOPE = "https://www.googleapis.com/auth/calendar.readonly"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"       # opened by the browser, never requested by this process
TOKEN_HOST, API_HOST = "oauth2.googleapis.com", "www.googleapis.com"
TOKEN_URL = f"https://{TOKEN_HOST}/token"
EVENTS_URL = f"https://{API_HOST}/calendar/v3/calendars/primary/events"
CALENDAR_URL = f"https://{API_HOST}/calendar/v3/calendars/primary"
TOKEN_SERVICE = "MeetingCapture Google Calendar token"
CLIENT_FILE = "google-oauth-client.json"
ERRORS = ("not_configured", "auth_required", "network", "lane_denied", "policy", "api_error")

DEFAULT_BACK_MIN, DEFAULT_AHEAD_MIN, MAX_WINDOW_MIN = 15, 30, 24 * 60
MAX_EVENTS = 50
HTTP_TIMEOUT_S = 8.0                                             # the app gives `upcoming` 20 s in all: a refresh and the events request must both fit
AUTH_TIMEOUT_S = 300.0
EXPIRY_SKEW_S = 120                                              # an access token that ends within this is refreshed first
MAX_CLIENT_FILE_BYTES = 16 * 1024
MAX_COMMAND_BYTES = 3000                                         # shortcut: security -i has an unverified line limit; above this the cached access token is left out
MAX_STRAY_REQUESTS = 16
FIELDS = ("items(id,status,summary,description,location,eventType,hangoutLink,conferenceData(conferenceSolution(name),entryPoints(uri)),"
          "start,end,organizer(self),creator(self),attendees(email,self,resource,responseStatus))")

_QUOTE_SAFE = re.compile(r'[^\x00-\x1f\x7f"\\]+\Z')              # what may sit inside the double quotes of a `security -i` command
_WORD = re.compile(r"[A-Za-z_]{1,40}\Z")
_PRINTABLE = re.compile(r"[\x21-\x7e]{1,512}\Z")
_CONFERENCE_LINK = re.compile(r"(?i)\b(?:zoom\.us|zoom\.com|zoomgov\.com|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|webex\.com)\b")
_ONLINE_PLACE = re.compile(r"(?i)https?://|www\.|\b(?:online|virtual|remote|zoom|google meet|teams|webex)\b|화상|온라인|비대면|원격")
_TOKEN_SHAPES = ((r"(?<![A-Za-z0-9_\-])ya29\.[A-Za-z0-9_\-]{20,}", "ya29.***"),                  # Google access token
                 (r"(?<![A-Za-z0-9_/\-])1//[A-Za-z0-9_\-]{20,}", "1//***"),                       # Google refresh token
                 (r"GOCSPX-[A-Za-z0-9_\-]{10,}", "GOCSPX-***"))                                   # Google OAuth client secret


# ---------------------------------------------------------------------------------- errors
class GcalError(Exception):
    """A failure with one of the contract's ``ERRORS`` and a short fixed sentence (never a secret, a URL, a server text or event content)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def install_redaction() -> None:
    """Mask the shapes of Google's tokens and client secret in every log line this process writes (idempotent). Called by the gcal commands
    only, so the rest of the pipeline is byte for byte what it was."""
    for pattern, mask in _TOKEN_SHAPES:
        apikey.register_redaction_pattern(pattern, mask)


def default_transport():
    """None = the real ``HttpsTransport``; a test patches this to return an in-process transport."""
    return None


# ---------------------------------------------------------------------------------- the lane
def lane_block(cfg) -> Optional[policy_mod.LaneBlock]:
    """None when the calendar lane may be used now. An active pipeline run answers with its own verdict (``lanes.gate``); an explicit command
    (no run) is closed only by the ORGANISATION: a locked or invalid policy, a policy that denies the lane or lacks its approval, a local-only
    lock. The user's own CALENDAR_LOOKUP (the claude.ai connector) and LOCAL_ONLY_DEFAULT are settings of meetings, not of this command. A
    failure of the check closes the lane."""
    try:
        block = lanes.gate(LANE)
        if block is not None or lanes.current() is not None:
            return block
        org = status.load_policy(cfg)
        decision = policy_mod.lane_decisions(status.lane_view_local_only(org), org, cfg)[LANE]
        if decision.allowed or decision.reason == lanes.USER_DISABLED:
            return None
        return decision.block()
    except Exception as exc:
        log.warning("calendar lane check failed (%s): closed", type(exc).__name__)
        return policy_mod.LaneBlock(LANE, "lane_denied", lanes.GATE_ERROR, f"lane '{LANE}' is not allowed: {lanes.GATE_ERROR}")


# ---------------------------------------------------------------------------------- the OAuth client file
@dataclass
class Client:
    client_id: str
    client_secret: str = field(default="", repr=False)


def client_path(cfg) -> Path:
    return Path(cfg.support_dir) / CLIENT_FILE


def _not_configured(text: str) -> GcalError:
    return GcalError("not_configured", text)


def load_client(cfg) -> Client:
    """``client_id`` / ``client_secret`` of the owner's Desktop-app client. ``not_configured`` (with the reason) for a missing file, a file that
    is not private (a symlink, not a regular file, another owner, any group/other permission, a directory others can write, over 16 KiB) and
    a file that is not a Desktop-app client."""
    path = client_path(cfg)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        raise _not_configured("the OAuth client file google-oauth-client.json is missing: see docs/CALENDAR_AUTOSTART.md") from None
    except OSError:
        raise _not_configured("the OAuth client file cannot be opened (a symbolic link?): save a plain file with mode 600") from None
    try:
        info = os.fstat(fd)
        try:
            parent_mode = os.stat(path.parent).st_mode
        except OSError:
            parent_mode = 0o777
        if not statmod.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or parent_mode & 0o022:
            raise _not_configured("the OAuth client file must be a private file of yours (chmod 600) in a folder only you can write")
        if info.st_size > MAX_CLIENT_FILE_BYTES:
            raise _not_configured("the OAuth client file is too large to be a client file")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            data = fh.read(MAX_CLIENT_FILE_BYTES + 1)
    finally:
        os.close(fd)
    try:
        doc = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise _not_configured("the OAuth client file is not valid JSON") from None
    installed = doc.get("installed") if isinstance(doc, dict) else None
    if not isinstance(installed, dict):
        raise _not_configured("the OAuth client file is not a Desktop app client (it needs an 'installed' section): create a Desktop app client")
    client_id, client_secret = installed.get("client_id"), installed.get("client_secret", "")
    if not isinstance(client_id, str) or not _PRINTABLE.fullmatch(client_id) or not isinstance(client_secret, str) or (
            client_secret and not _PRINTABLE.fullmatch(client_secret)):
        raise _not_configured("the OAuth client file has no usable client_id / client_secret")
    if client_secret:
        apikey.remember(client_secret)
    return Client(client_id, client_secret)


# ---------------------------------------------------------------------------------- the token in the Keychain
@dataclass
class Token:
    refresh: str = field(repr=False)
    access: str = field(default="", repr=False)
    expires_at: int = 0                                          # epoch seconds
    account: str = ""                                            # the primary calendar's id (the e-mail address), shown by `status`

    def fresh(self, now: float) -> bool:
        return bool(self.access) and now + EXPIRY_SKEW_S < self.expires_at

    def dump(self, *, with_access: bool = True) -> str:
        doc: dict = {"v": 1, "refresh": self.refresh, "account": self.account}
        if with_access and self.access:
            doc.update(access=self.access, expires_at=int(self.expires_at))
        return json.dumps(doc, separators=(",", ":"))

    @classmethod
    def load(cls, text: str) -> Optional["Token"]:
        try:
            doc = json.loads(text)
        except ValueError:
            return None
        if not isinstance(doc, dict) or not isinstance(doc.get("refresh"), str) or not doc["refresh"]:
            return None
        access, expires, account = doc.get("access"), doc.get("expires_at"), doc.get("account")
        return cls(doc["refresh"], access if isinstance(access, str) else "",
                   expires if isinstance(expires, int) and not isinstance(expires, bool) else 0, account if isinstance(account, str) else "")


def _security(run, argv: list, **kwargs):
    return run([apikey.security_bin(), *argv], stderr=subprocess.DEVNULL, timeout=apikey.READ_TIMEOUT_S, env=apikey._security_env(), **kwargs)


def read_token(run=subprocess.run) -> Token:
    """The token from the Keychain (``security find-generic-password ... -w``; stderr discarded, stdin closed). ``auth_required`` when there is
    none or it is unreadable as ours, ``api_error`` when the Keychain cannot be read (timeout, tool missing, locked)."""
    try:
        done = _security(run, ["find-generic-password", "-s", TOKEN_SERVICE, "-a", apikey.keychain_account(), "-w"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    except (OSError, subprocess.TimeoutExpired):
        raise GcalError("api_error", "the Keychain could not be read") from None
    out = done.stdout.decode("utf-8", "replace").strip() if isinstance(done.stdout, (bytes, bytearray)) else ""
    if done.returncode in (0, apikey.ITEM_NOT_FOUND_EXIT) and not out:
        raise GcalError("auth_required", "Google Calendar is not signed in: run gcal auth")
    if done.returncode != 0:
        raise GcalError("api_error", "the Keychain could not be read")
    apikey.remember(out)
    token = Token.load(out)
    if token is None:                                            # the tool prints data it thinks is not text as hex
        try:
            token = Token.load(bytes.fromhex(out).decode("utf-8"))
        except ValueError:
            token = None
    if token is None:
        raise GcalError("auth_required", "the stored Google sign-in is unreadable: run gcal auth")
    apikey.remember(token.refresh)
    apikey.remember(token.access)
    return token


def write_token(token: Token, *, run=subprocess.run, verify: bool = False) -> None:
    """Store the token. ``security -i`` reads its command from STDIN (argv is [security, -i]) and the blob travels hex-encoded (``-X``), so
    no secret is in argv or the environment and no quoting can break it. ``verify`` reads the item back: the interactive mode does not tell a
    failed command from a good one. The cached access token is left out when the command would be long (shortcut: the line limit of
    ``security -i`` is not verified on this Mac; the refresh token alone still works)."""
    failure = GcalError("api_error", "the token could not be stored in the Keychain")
    account = apikey.keychain_account()
    if not _QUOTE_SAFE.fullmatch(account):
        raise failure
    for blob in (token.dump(), token.dump(with_access=False)):
        command = f'add-generic-password -U -a "{account}" -s "{TOKEN_SERVICE}" -X {blob.encode("utf-8").hex()}\n'
        if len(command) <= MAX_COMMAND_BYTES:
            break
    else:
        raise failure
    try:
        done = run([apikey.security_bin(), "-i"], input=command.encode("utf-8"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=apikey.READ_TIMEOUT_S, env=apikey._security_env())
    except (OSError, subprocess.TimeoutExpired):
        raise failure from None
    if done.returncode != 0:
        raise failure
    if verify:
        try:
            stored = read_token(run)
        except GcalError:
            raise failure from None
        if not hmac.compare_digest(stored.refresh.encode("utf-8"), token.refresh.encode("utf-8")):
            raise failure


def forget_token(run=subprocess.run) -> int:
    """Delete the Keychain item. 0 deleted or nothing there, 1 the tool failed."""
    account = apikey.keychain_account()
    try:
        done = _security(run, ["delete-generic-password", "-s", TOKEN_SERVICE, "-a", account], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"error: cannot run the security tool: {type(exc).__name__}", file=sys.stderr)
        return 1
    if done.returncode == 0:
        print(f"Deleted the Google Calendar token from the Keychain (service '{TOKEN_SERVICE}', account '{account}').")
        return 0
    if done.returncode == apikey.ITEM_NOT_FOUND_EXIT:
        print("Nothing to delete: no Google Calendar token in the Keychain.")
        return 0
    print(f"error: the security tool exited with {done.returncode}: the token was not deleted", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------------- HTTP through the egress guard
class _Api:
    """The two Google hosts behind one ``EgressGuard`` (exact hosts, https, no redirect) and the calendar lane gate before every attempt."""

    def __init__(self, cfg, transport=None):
        rules = {TOKEN_HOST: policy_mod.HostRule(host=TOKEN_HOST, port=443, max_request_bytes=8192, max_response_bytes=64 * 1024),
                 API_HOST: policy_mod.HostRule(host=API_HOST, port=443, max_request_bytes=4096, max_response_bytes=4 * 1024 * 1024)}
        self.secrets: list = []
        self._guard = EgressGuard(rules, engine_id="gcal", consent_id="owner", transport=transport if transport is not None else default_transport(),
                                  secrets=lambda: tuple(self.secrets), pre_connect=lambda: lane_block(cfg), trust="system")

    def request(self, method: str, url: str, *, headers: dict, body: bytes = b"", label: str) -> Response:
        try:
            return self._guard.request(method, url, headers=headers, body=body, timeout=HTTP_TIMEOUT_S, path_label=label)
        except EgressDenied as exc:
            if exc.code == "pre_connect":
                raise GcalError("lane_denied", f"lane '{LANE}' is closed") from None
            if exc.code in ("redirect", "response_too_large"):
                raise GcalError("api_error", "Google answered in a way that is not accepted") from None
            if exc.code == "no_trust_store":
                raise GcalError("network", "no system trust store for the TLS check") from None
            raise GcalError("policy", f"the destination is not permitted ({exc.code})") from None
        except EgressError as exc:
            raise GcalError("network", f"could not reach Google ({exc.code})") from None


def _json(resp: Response) -> Optional[dict]:
    """The body as a JSON object, or None when it is anything else."""
    try:
        doc = json.loads(resp.body.decode("utf-8"))
    except (ValueError, UnicodeError):
        return None
    return doc if isinstance(doc, dict) else None


def _error_word(doc: dict) -> str:
    """The short error word of a Google error answer (OAuth ``error`` or the API's first ``reason`` / ``status``), only if it is a plain word."""
    err = doc.get("error")
    word = err
    if isinstance(err, dict):
        errors = err.get("errors")
        word = errors[0].get("reason") if isinstance(errors, list) and errors and isinstance(errors[0], dict) else None
        word = word or err.get("status")
    return word if isinstance(word, str) and _WORD.fullmatch(word) else ""


def _http_error(status_code: int, word: str, what: str) -> GcalError:
    if status_code == 429 or status_code >= 500:
        return GcalError("api_error", f"Google answered HTTP {status_code}")
    hint = ": enable the Google Calendar API in your Cloud project" if word == "accessNotConfigured" else ""
    return GcalError("api_error", f"Google refused the {what} (HTTP {status_code}{', ' + word if word else ''}){hint}")


def _token_request(api: _Api, client: Client, params: dict, *, refreshing: bool) -> dict:
    body = {**params, "client_id": client.client_id}
    if client.client_secret:
        body["client_secret"] = client.client_secret
    resp = api.request("POST", TOKEN_URL, headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
                       body=urlencode(body).encode("ascii"), label="token")
    doc = _json(resp) or {}
    if resp.status == 200 and isinstance(doc.get("access_token"), str) and doc["access_token"]:
        apikey.remember(doc["access_token"])
        if isinstance(doc.get("refresh_token"), str):
            apikey.remember(doc["refresh_token"])
        return doc
    word = _error_word(doc)
    if resp.status == 401 or word in ("invalid_client", "unauthorized_client"):
        raise GcalError("auth_required", "Google rejected the OAuth client: check google-oauth-client.json, then run gcal auth")
    if resp.status == 400 and word == "invalid_grant":
        raise GcalError("auth_required", "Google no longer accepts the saved sign-in (revoked, expired or the test-mode limit): run gcal auth" if refreshing
                        else "Google rejected the sign-in code: run gcal auth again")
    if resp.status == 200:
        raise GcalError("api_error", "Google's token answer is not usable")
    raise _http_error(resp.status, word, "token request")


def _expiry(doc: dict, now: float) -> int:
    seconds = doc.get("expires_in")
    seconds = seconds if isinstance(seconds, int) and not isinstance(seconds, bool) and 0 < seconds <= 86400 else 3000
    return int(now + seconds)


def refresh_access(api: _Api, client: Client, token: Token, now: float) -> Token:
    doc = _token_request(api, client, {"grant_type": "refresh_token", "refresh_token": token.refresh}, refreshing=True)
    new_refresh = doc.get("refresh_token")
    return Token(new_refresh if isinstance(new_refresh, str) and new_refresh else token.refresh, doc["access_token"], _expiry(doc, now), token.account)


def exchange_code(api: _Api, client: Client, code: str, verifier: str, redirect_uri: str, now: float) -> Token:
    doc = _token_request(api, client, {"grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                       "redirect_uri": redirect_uri}, refreshing=False)
    granted = doc.get("scope")
    if isinstance(granted, str) and SCOPE not in granted.split():
        raise GcalError("auth_required", "Google did not grant read-only calendar access: allow it on the consent screen and try again")
    refresh = doc.get("refresh_token")
    if not isinstance(refresh, str) or not refresh:
        raise GcalError("auth_required", "Google sent no refresh token: remove this app at myaccount.google.com/permissions and run gcal auth again")
    return Token(refresh, doc["access_token"], _expiry(doc, now))


def _api_get(api: _Api, url: str, access: str, label: str) -> Response:
    return api.request("GET", url, headers={"Authorization": f"Bearer {access}", "Accept": "application/json"}, label=label)


def primary_account(api: _Api, access: str) -> str:
    """The id of the primary calendar (the account's e-mail address), or "" when the answer does not carry one."""
    resp = _api_get(api, CALENDAR_URL + "?" + urlencode({"fields": "id"}), access, "calendar")
    if resp.status == 401:
        raise GcalError("auth_required", "Google rejected the access token: run gcal auth")
    if resp.status != 200:
        raise _http_error(resp.status, _error_word(_json(resp) or {}), "calendar request")
    value = (_json(resp) or {}).get("id")
    return value if isinstance(value, str) and len(value) <= 254 and _PRINTABLE.fullmatch(value) else ""


# ---------------------------------------------------------------------------------- PKCE, the consent URL and the loopback listener
def pkce_pair() -> tuple[str, str]:
    """(code_verifier, S256 code_challenge): 86 URL-safe characters (the RFC allows 43 to 128), the challenge is base64url(sha256) without padding."""
    verifier = secrets.token_urlsafe(64)
    return verifier, base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")


def authorization_url(client_id: str, redirect_uri: str, challenge: str, state: str) -> str:
    return AUTH_URL + "?" + urlencode({"client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code", "scope": SCOPE,
                                       "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
                                       "access_type": "offline", "prompt": "consent"})


_PAGE = b"<!doctype html><meta charset=utf-8><title>%s</title><p>%s</p>"      # the title is the human name of the app (appinfo: ASCII, no markup)


class _Callback(http.server.BaseHTTPRequestHandler):
    server_version, sys_version = "mcap-gcal", ""
    timeout = 5                                                  # a browser that opens a connection and sends nothing must not hold us

    def log_message(self, *args) -> None:                        # the default writes the request line, which carries the code, to stderr
        pass

    def _reply(self, status_code: int, text: str) -> None:
        body = _PAGE % (appinfo.display_name().encode("ascii"), text.encode("ascii"))
        self.send_response(status_code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parts = urlsplit(self.path)
        if parts.path != "/":
            self.server.stray += 1
            return self._reply(404, "Not found")
        query = parse_qs(parts.query)
        state = (query.get("state") or [""])[0]
        if not hmac.compare_digest(state.encode("utf-8", "replace"), self.server.state.encode("utf-8")):
            self.server.result = ("error", "the answer did not carry the state of this sign-in (another program, or an old tab): try again")
            return self._reply(400, "This sign-in could not be completed. You can close this tab.")
        if "error" in query:
            self.server.result = ("error", "Google did not grant access (you declined, or the app is not allowed to ask): nothing was stored")
            return self._reply(200, "Access was not granted. You can close this tab.")
        code = (query.get("code") or [""])[0]
        if not code:
            self.server.result = ("error", "the answer carried no authorization code")
            return self._reply(400, "This sign-in could not be completed. You can close this tab.")
        self.server.result = ("code", code)
        self._reply(200, "Signed in. You can close this tab and return to the terminal.")


class Loopback(http.server.HTTPServer):
    """The redirect target: 127.0.0.1 only, a random port, ONE callback request (the path ``/`` with the right state) ends the wait and the
    socket is closed. A request for any other path (a favicon) gets a 404 and does not end it; after ``MAX_STRAY_REQUESTS`` of them it does."""
    allow_reuse_address = False

    def __init__(self, state: str):
        super().__init__(("127.0.0.1", 0), _Callback)
        self.state, self.result, self.stray = state, None, 0

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)                 # not HTTPServer's: it asks a resolver for the name of the address (a reverse lookup)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]

    @property
    def redirect_uri(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}/"

    def wait(self, timeout_s: float) -> str:
        """The authorization code, or ``GcalError`` (state mismatch, declined, timeout). The listener is closed whatever happens."""
        deadline = time.monotonic() + timeout_s
        try:
            while self.result is None and self.stray <= MAX_STRAY_REQUESTS:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise GcalError("auth_required", "no answer from the browser in time: run gcal auth again")
                self.timeout = min(remaining, 1.0)
                self.handle_request()
        finally:
            self.server_close()
        if self.result is None:
            raise GcalError("auth_required", "the listener received requests that were not the sign-in answer: run gcal auth again")
        kind, value = self.result
        if kind != "code":
            raise GcalError("auth_required", value)
        return value


# ---------------------------------------------------------------------------------- events -> the contract
def _clamp(minutes: Any, default: int) -> int:
    try:
        return max(0, min(int(minutes), MAX_WINDOW_MIN))
    except (TypeError, ValueError):
        return default


def _when(part: Any) -> Optional[tuple[str, bool]]:
    """(ISO 8601 with offset, all_day) of an event's start/end. An all-day ``date`` is midnight of that day in this Mac's zone."""
    if not isinstance(part, dict):
        return None
    try:
        if isinstance(part.get("dateTime"), str):
            moment = datetime.fromisoformat(part["dateTime"])
            return (moment if moment.tzinfo else moment.astimezone()).isoformat(timespec="seconds"), False
        if isinstance(part.get("date"), str):
            day = date.fromisoformat(part["date"])
            return datetime(day.year, day.month, day.day).astimezone().isoformat(timespec="seconds"), True
    except ValueError:
        return None
    return None


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _owner_takes_part(raw: dict, attendees: list) -> bool:
    """True only when the owner demonstrably is part of the event: its organizer or creator, or an attendee who accepted or said maybe. An invitation that
    was never answered (needsAction), an event without an entry of the owner next to other attendees and any other status are NOT: anybody can e-mail an
    invitation, and Google adds it to the calendar by default. Strict ``is True``: a value of another type counts as no."""
    if any(isinstance(who, dict) and who.get("self") is True for who in (raw.get("organizer"), raw.get("creator"))):
        return True
    return any(a.get("self") is True and a.get("responseStatus") in ("accepted", "tentative") for a in attendees)


def _in_person(attendees: list, location: str) -> bool:
    """The people sit in one place: a room that is booked (a resource attendee that did not decline) or a place name in the location (no URL, no word
    like online or Zoom). Google Calendar attaches a Meet link to most invitations whether anybody means to join it, so a link alone says nothing."""
    if any(a.get("resource") is True and a.get("responseStatus") != "declined" for a in attendees):
        return True
    place = location.strip()
    return bool(place) and not _ONLINE_PLACE.search(place)


def map_event(raw: Any) -> Optional[dict]:
    """One event of events.list in the contract's shape, or None (not an event, cancelled, no readable start or end, or an event the owner does not
    take part in: see ``_owner_takes_part``; such an event is left out of the answer, so the app never sees it)."""
    if not isinstance(raw, dict) or raw.get("status") == "cancelled" or not isinstance(raw.get("id"), str):
        return None
    start, end = _when(raw.get("start")), _when(raw.get("end"))
    if start is None or end is None:
        return None
    attendees = [a for a in raw.get("attendees") or [] if isinstance(a, dict)]
    if not _owner_takes_part(raw, attendees):
        return None
    guests = sum(1 for a in attendees if not a.get("self") and not a.get("resource"))
    declined = any(a.get("self") and a.get("responseStatus") == "declined" for a in attendees)
    location, description = _text(raw.get("location")), _text(raw.get("description"))
    conference = bool(raw.get("hangoutLink")) or bool(raw.get("conferenceData")) or bool(
        _CONFERENCE_LINK.search(location) or _CONFERENCE_LINK.search(description))
    conference = conference and not _in_person(attendees, location)       # a meeting in a room is the calendar's business even with a link on it
    kind = raw.get("eventType")
    return {"id": raw["id"], "title": _text(raw.get("summary")), "start": start[0], "end": end[0], "all_day": start[1],
            "declined": declined, "event_type": kind if isinstance(kind, str) and _WORD.fullmatch(kind) else "default",
            "guests": guests, "has_conference": conference, "location": location}


def _rfc3339(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def upcoming(cfg, back_min: int = DEFAULT_BACK_MIN, ahead_min: int = DEFAULT_AHEAD_MIN, *, transport=None, run=subprocess.run,
             clock: Callable[[], float] = time.time) -> dict:
    """The events of the primary calendar from now-N to now+M minutes as the contract's success object. ``GcalError`` for every failure."""
    back, ahead = _clamp(back_min, DEFAULT_BACK_MIN), _clamp(ahead_min, DEFAULT_AHEAD_MIN)
    block = lane_block(cfg)
    if block is not None:
        raise GcalError("lane_denied", block.message)
    client = load_client(cfg)
    token = read_token(run)
    api = _Api(cfg, transport)
    api.secrets += [token.refresh, token.access, client.client_secret]
    now = clock()

    def renew(current: Token) -> Token:
        fresh = refresh_access(api, client, current, clock())
        api.secrets += [fresh.refresh, fresh.access]
        try:
            write_token(fresh, run=run)
        except GcalError:
            log.warning("the refreshed access token could not be cached in the Keychain")
        return fresh

    renewed = not token.fresh(now)
    if renewed:
        token = renew(token)
    query = urlencode({"timeMin": _rfc3339(now - back * 60), "timeMax": _rfc3339(now + ahead * 60), "singleEvents": "true",
                       "orderBy": "startTime", "maxResults": MAX_EVENTS, "fields": FIELDS})
    resp = _api_get(api, f"{EVENTS_URL}?{query}", token.access, "events")
    if resp.status == 401 and not renewed:                       # the cached token was revoked or is older than it says: one refresh, one retry
        token = renew(token)
        resp = _api_get(api, f"{EVENTS_URL}?{query}", token.access, "events")
    if resp.status == 401:
        raise GcalError("auth_required", "Google rejected the access token: run gcal auth")
    doc = _json(resp)
    if resp.status != 200:
        raise _http_error(resp.status, _error_word(doc or {}), "calendar request")
    items = doc.get("items", []) if doc is not None else None       # a fields mask leaves an empty window as {}
    if not isinstance(items, list):
        raise GcalError("api_error", "Google's calendar answer is not usable")
    events = [e for e in map(map_event, items) if e is not None]
    log.debug("gcal upcoming: %d events", len(events))
    return {"schema": SCHEMA, "ok": True, "now": datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"), "events": events}


def failure(code: str, message: str) -> dict:
    return {"schema": SCHEMA, "ok": False, "error": code if code in ERRORS else "api_error", "message": message}


def print_upcoming(load_config: Callable[[], Any], back_min: int, ahead_min: int, *, out=None, **seams) -> int:
    """`gcal upcoming`: exactly one JSON object on stdout, exit 0, whatever happens (a bug, a bad config.env, a missing file included).
    ASCII-only JSON, so the answer does not depend on the locale of the process that reads it."""
    install_redaction()
    try:
        try:
            cfg = load_config()
        except Exception:                                        # a bad value in config.env (ValueError) or an unreadable file
            raise GcalError("not_configured", "config.env cannot be read") from None
        result = upcoming(cfg, back_min, ahead_min, **seams)
    except GcalError as exc:
        result = failure(exc.code, exc.message)
    except Exception as exc:                                     # the contract: a JSON answer, never a crash (the type only: a message can carry content)
        log.warning("gcal upcoming failed (%s)", type(exc).__name__)
        result = failure("api_error", "unexpected error")
    stream = out or sys.stdout
    stream.write(json.dumps(result, ensure_ascii=True, separators=(",", ":")) + "\n")
    stream.flush()
    return 0


# ---------------------------------------------------------------------------------- auth, status, forget (terminal commands)
def authorize(cfg, *, transport=None, run=subprocess.run, clock: Callable[[], float] = time.time, open_browser=webbrowser.open,
              timeout_s: float = AUTH_TIMEOUT_S) -> int:
    """`gcal auth`: print the consent URL and open it, receive the code on the loopback listener, exchange it (PKCE), name the account, store
    the token and read it back. 0 done, 1 anything else (a sentence says why)."""
    install_redaction()
    stored = False
    try:
        block = lane_block(cfg)
        if block is not None:
            raise GcalError("lane_denied", block.message)
        client = load_client(cfg)
        state, (verifier, challenge) = secrets.token_urlsafe(24), pkce_pair()
        api = _Api(cfg, transport)
        api.secrets += [client.client_secret, verifier]
        listener = Loopback(state)
        try:
            redirect = listener.redirect_uri
            url = authorization_url(client.client_id, redirect, challenge, state)
            print("Sign in with the Google account whose calendar should start recordings and allow READ-ONLY access to it.\n"
                  f"Opening your browser; if nothing opens, paste this address into one:\n\n{url}\n", flush=True)
            try:
                open_browser(url)
            except Exception:
                log.debug("the browser could not be opened")
            code = listener.wait(timeout_s)
        finally:
            listener.server_close()
        token = exchange_code(api, client, code, verifier, redirect, clock())
        api.secrets += [token.refresh, token.access]
        account, problem = "", None
        try:
            account = primary_account(api, token.access)
        except GcalError as exc:
            problem = exc
        token.account = account
        write_token(token, run=run, verify=True)
        stored = True
        if problem is not None:
            raise problem
    except GcalError as exc:
        print(("The token is stored, but the check call failed: " if stored else "error: ") + exc.message, file=sys.stderr)
        return 1
    print(f"Signed in{' as ' + account if account else ''}. Read-only calendar access is stored in the Keychain "
          f"(service '{TOKEN_SERVICE}'). Revoke it any time: gcal forget, and myaccount.google.com/permissions.")
    return 0


def status_lines(cfg, *, run=subprocess.run, clock: Callable[[], float] = time.time) -> tuple[list[str], bool]:
    """(lines, ready) for `gcal status`: no network, no secret."""
    lines, ready = ["Google Calendar (read-only, for calendar autostart; docs/CALENDAR_AUTOSTART.md)"], True
    try:
        load_client(cfg)
        lines.append(f"  OAuth client file: {client_path(cfg)} (private, Desktop app client)")
    except GcalError as exc:
        lines.append(f"  OAuth client file: NOT usable: {exc.message}")
        ready = False
    try:
        token = read_token(run)
        lines.append(f"  token:             in the Keychain (service '{TOKEN_SERVICE}'), signed in as {token.account or 'an account (name unknown)'}")
        left = int((token.expires_at - clock()) // 60)
        lines.append("  access token:      " + (f"cached, valid for about {left} more minutes" if token.fresh(clock()) else
                                                "not cached or expired (it is renewed from the refresh token when needed)"))
    except GcalError as exc:
        lines.append(f"  token:             NOT available: {exc.message}")
        ready = False
    block = lane_block(cfg)
    lines.append(f"  organisation lane: {'allowed' if block is None else 'DENIED (' + block.reason + ')'}")
    ready = ready and block is None
    return lines, ready


def print_status(cfg, **seams) -> int:
    install_redaction()
    lines, ready = status_lines(cfg, **seams)
    print("\n".join(lines))
    print("ready" if ready else "not ready: see docs/CALENDAR_AUTOSTART.md")
    return 0 if ready else 1


def forget(cfg, *, run=subprocess.run) -> int:
    install_redaction()
    code = forget_token(run)
    if code == 0:
        print("Google keeps the grant until you remove it: myaccount.google.com/permissions (the app named in your Cloud project).")
    return code
