"""The company ASR server as an engine: the client half of ``mcap-asr/1`` (docs/ASR_PROTOCOL.md;
SPEC 18).

``RemoteEngine`` is an ``asr_http.HttpEngine`` (kind ``server``, engine id ``remote``). The base class owns everything that every external
engine does the same way (the URL of the consented host, the per-attempt lane gate, the Keychain read, retry and ``Retry-After``, the
usage line, the daily cap, fixed error messages); this module adds what is specific to the wire contract of docs/ASR_PROTOCOL.md and
nothing else. It opens no socket (only ``EgressGuard`` does), reads no Keychain item except through ``asr_creds`` and never puts a
server's text into a message, a log line, a state file or a usage record. It is imported only when ``ASR_ENGINE``/``ASR_FALLBACK`` name
``remote`` (``asr_engines.engine_class``); the default local pipeline never loads it. The server half (``asr_server``) is built against the
same document: nothing here imports it.

What the engine adds to ``HttpEngine``

* ``load()`` is the start-of-run check (5.1): ``GET /v1/health?detail=1`` within 5 s, refused with ``EnginePolicyDenied`` when the protocol
  differs, ``retention.mode`` is not ``none``, the backend kind is not the one the consent was given for, or the build hash is not in the
  allow list of the organisation consent (``attest_build_sha256``; an empty list allows no build). A build or configuration hash that
  merely CHANGED since the last run is a warning and a counter (``attest_status``), never a new consent. What the server says about
  itself is adopted only where it can SHORTEN or switch off something: the chunk window (never longer than 28 s), the language-ID clip
  count and length, ``supports_lid`` and ``confidence``; the model label is taken only when it has the shape of a model id. When the token
  has 14 days or less left it is renewed (5.3) and the Keychain item (same host-bound account) overwritten; a renewal that fails never
  fails the run.
* ``transcribe_chunk`` sends ``POST /v1/chunk`` (5.5): raw int16 PCM, ``X-MCAP-Samples/Lang/Langs/Prompt/Vocab``. The vocabulary
  (``PUT /v1/vocab/{sha256}``, canonical JSON of 12.1) is sent once before the first chunk and again after a ``404 vocab_unknown``
  (``recover``: the same request, the same ``X-MCAP-Idem``, goes out once more), and only when ``ASR_SEND_VOCAB`` and the policy
  (``decision.send_vocab``) say so; otherwise the prompt header is ``none`` and no term leaves the Mac.
* ``detect_languages`` sends ``POST /v1/lid`` (5.6) in requests of at most 12 clips, each clip trimmed to its centre 6 s. A request the
  server refuses (a 4xx: no language ID after all, a limit, an unusable clip) switches language ID off for the rest of the run and is
  answered with uniform probabilities (docs/ASR_PROTOCOL.md 12.3: the client then uses its single-label path): the chunks go out with
  ``X-MCAP-Lang: auto`` and the server decides; a refused language-ID batch never costs the meeting its transcript.
* Every request carries ``X-MCAP-Proto``, ``X-MCAP-Client``, ``X-MCAP-Run`` (16 random hex per engine, i.e. per run), a fresh
  ``X-MCAP-Idem`` per LOGICAL request (``common_headers`` is called once per request, so every retry reuses it) and the soft machine
  binding ``X-MCAP-Machine``. ``X-MCAP-Chunk`` (accounting only) is not sent: ``transcribe_chunk`` is not told which track it works on.
* ``enroll(cfg, code)`` (5.2) exchanges the one-time code for a token and stores it in the Keychain under the host-bound account.
  ``purge()`` (5.7) flushes the server's memory for this token (``mcap asr-engines purge --server``).

Where a secret may be: the token is only in the Keychain and in memory. It is written with ``security -i`` and the command on STDIN
(``add-generic-password ... -w "<token>"``), never in argv, and read back to prove that the Keychain kept it. The enrollment code is not a
secret once used, but it is registered for masking and never logged, put in argv or in an exception.
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import logging
import math
import numbers
import os
import random
import re
import secrets
import subprocess
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

import numpy as np

from . import __version__, apikey, asr_creds, policy, usage as claude_usage
from .asr_engines import (LID_CANDIDATES, SR, EngineAuthError, EngineError, EnginePolicyDenied, EngineTransient, chunk_limit, parse_languages,
                          restrict_lid)
from .asr_http import PROTOCOL, EngineHttpError, HttpEngine, pcm16
from .egress import EgressGuard, ca_bound
from .policy import ENGINE_META

log = logging.getLogger("mcap.asr")

CLIENT = f"mcap/{__version__}"
RENEW_WITHIN_DAYS = 14                    # docs/ASR_PROTOCOL.md 5.3: renew at run start when the token has this many days or fewer left
MAX_CHUNK_SAMPLES = 31 * SR               # the server's hard limit (496000); the client plans 28 s or less
MAX_LID_CLIPS = 12
LID_CLIP_SAMPLES = 6 * SR                 # a language-ID clip is trimmed to its centre 6 s
VOCAB_MAX_BYTES = 64 * 1024               # PUT /v1/vocab body
VOCAB_MAX_TERMS = 2000
VOCAB_TERM_CHARS = 200
ATTEST_FILE = "asr-remote-attest.json"    # SUPPORT_DIR: the hashes of the last accepted health document (content-free)
PROMPT_STYLE = "frame+list"               # what the server builds when terms are sent (12.2); "none" when none are

TOKEN_SHAPE = re.compile(r"mcap1_[0-9a-f]{8}_[A-Za-z0-9_\-]{32}\Z")
_MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]{0,99}\Z")
_REVISION = re.compile(r"[0-9a-f]{4,40}\Z")
_CODE_SHAPE = re.compile(r"[\x21-\x7e]([\x20-\x7e]{0,62}[\x21-\x7e])?\Z")            # printable ASCII, 1 to 64 characters, no edge space
_ISO = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?([+\-][0-9]{2}:[0-9]{2}|Z)?\Z")
_ACCOUNT = re.compile(r"[^\x00-\x1f\x7f\"\\]+\Z")                                    # what may sit inside the double quotes of a security command
_CONFIDENCE = ("logprob", "opaque", "none")
JSON_HEADERS = {"Content-Type": "application/json"}
_HEX16 = re.compile(r"[0-9a-f]{16}\Z")
_HEX64 = re.compile(r"[0-9a-f]{64}\Z")


def _error(cls, message: str, status: Optional[int] = None, code: Optional[str] = None):
    """An engine error with a FIXED message and the ``status`` / ``code`` attributes every error of the engines has (the same shape as
    ``asr_http``'s): never a server's text."""
    exc = cls(message)
    exc.status = status
    exc.code = code
    return exc


def _object(body: Any) -> dict:
    """A server answer as a JSON object; ``EngineTransient`` (an answer that cannot be used is a server that is not well, not a verdict)
    for anything else."""
    try:
        doc = json.loads(bytes(body).decode("utf-8"))
    except (ValueError, TypeError, RecursionError):
        raise _error(EngineTransient, "the engine answer could not be read") from None
    if not isinstance(doc, dict):
        raise _error(EngineTransient, "the engine answer could not be read")
    return doc


def _probability(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        return 0.0
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return 0.0
    return min(max(number, 0.0), 1.0) if math.isfinite(number) else 0.0


def _sha256_or_none(value: Any) -> Optional[str]:
    """A hash the server reported, only when it IS one (64 lower-case hex digits): it is written to a file."""
    return value if isinstance(value, str) and _HEX64.fullmatch(value) else None


def _iso_or_none(value: Any) -> Optional[str]:
    """A date the server gave, only when it has the shape of an ISO timestamp (it is shown to the user and nothing else)."""
    if isinstance(value, str) and _ISO.fullmatch(value):
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return value
    return None


def _wellformed(value: str) -> str:
    """A server string as text that can be written to disk: a lone surrogate (JSON ``"\\ud800"``) is valid to ``json.loads`` but not to
    ``str.encode('utf-8')``, which is what the transcript writer does after the whole ASR run; it becomes ``?``."""
    return value.encode("utf-8", "replace").decode("utf-8")


def _days_left(expires: Optional[str], now: datetime) -> Optional[int]:
    """Whole days from ``now`` to ``expires`` (never negative); None when there is no usable date."""
    if expires is None:
        return None
    moment = datetime.fromisoformat(expires.replace("Z", "+00:00"))
    moment, now = (x if x.tzinfo is not None else x.astimezone() for x in (moment, now))        # a naive time is local time
    return max(0, math.floor((moment - now).total_seconds() / 86400))


# ---------------------------------------------------------------------------------- the vocabulary (docs/ASR_PROTOCOL.md 5.4, 12.1)
def vocab_terms(vocab: Any) -> list:
    """The terms of ``vocab`` the server accepts, in file order: a non-empty string of at most 200 characters without control
    characters that can be written as UTF-8; at most 2000 terms and, as JSON, at most 64 KiB (the rest is left out, like the terms that
    do not fit a local prompt budget). ``None`` or anything without terms gives []."""
    raw = getattr(vocab, "terms", None)
    if not isinstance(raw, (list, tuple)):
        return []
    terms: list = []
    size = len('{"terms":[]}')
    for term in raw:
        if not isinstance(term, str) or not term.strip() or len(term) > VOCAB_TERM_CHARS or any(ord(ch) < 32 or ord(ch) == 127 for ch in term):
            continue
        try:
            piece = len(json.dumps(term, ensure_ascii=False).encode("utf-8")) + 1
        except UnicodeEncodeError:                          # a lone surrogate cannot be sent
            continue
        if len(terms) >= VOCAB_MAX_TERMS or size + piece > VOCAB_MAX_BYTES:
            break
        terms.append(term)
        size += piece
    return terms


def canonical_vocab(terms) -> tuple:
    """``(body bytes, sha256 hex)`` of ``{"terms": [...]}``: compact, keys sorted, non-ASCII kept (12.1). The body is exactly the bytes the
    digest of the URL was computed over, so the server's check cannot differ by a spelling."""
    body = json.dumps({"terms": list(terms)}, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return body, hashlib.sha256(body).hexdigest()


# ---------------------------------------------------------------------------------- the Keychain (the token's only home)
def store_token(host: str, port: int, token: str, *, run=subprocess.run) -> None:
    """Put ``token`` into the Keychain item of ``MeetingCapture ASR remote`` for this host and port (``asr_creds.service_name`` and
    ``account_name``: ``<user>@<host>:<port>``, so it can only be read for the destination it was issued for), replacing an older one.

    ``security -i`` reads its command from STDIN, so the token is in neither argv nor the environment (argv is ``[security, "-i"]``); the
    macOS tool's own prompt (``-w`` last) reads the terminal and cannot be fed from here. The item is then READ BACK and compared: the
    interactive mode does not tell a command that failed from one that worked, and a stale token left in place would look enrolled.
    ``EngineAuthError`` (code ``store_failed``, a fixed sentence) when anything goes wrong; nothing secret is in it."""
    failed = _error(EngineAuthError, "the token could not be stored in the Keychain: nothing was changed or the item could not be verified",
                    None, "store_failed")
    try:
        service, account = asr_creds.service_name("remote"), asr_creds.account_name(host, port)
    except asr_creds.CredentialUnavailable:
        raise failed from None
    if not TOKEN_SHAPE.fullmatch(token) or not _ACCOUNT.fullmatch(account) or not _ACCOUNT.fullmatch(service):
        raise failed
    command = f'add-generic-password -U -a "{account}" -s "{service}" -w "{token}"\n'
    try:
        done = run([apikey.security_bin(), "-i"], input=command.encode("utf-8"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=apikey.READ_TIMEOUT_S, env=apikey._security_env())
    except (OSError, subprocess.TimeoutExpired):
        raise failed from None
    if getattr(done, "returncode", 1) != 0:
        raise failed
    try:
        with asr_creds.secret("remote", host, port, run=run) as stored:
            same = secrets.compare_digest(stored.encode("utf-8"), token.encode("utf-8"))
    except asr_creds.CredentialUnavailable:
        raise failed from None
    if not same:
        raise failed


# ---------------------------------------------------------------------------------- what changed on the server (a warning and a counter)
def attest_status(cfg) -> dict:
    """The content-free record of the last accepted health document, for ``mcap status`` and doctor: ``{host, port, build_sha256_8,
    changes, changed_at}`` or ``{}`` (no remote server seen yet, or the file is unreadable). A changed build or configuration hash is
    counted here and warned about once per change; it never needs a new consent (a server update must not send every employee to a
    terminal), only the organisation's allow list (``attest_build_sha256``) can refuse a build."""
    try:
        doc = json.loads((Path(cfg.support_dir) / ATTEST_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(doc, dict):
        return {}
    build = doc.get("build_sha256")
    changes = doc.get("changes")
    return {"host": doc.get("host") if isinstance(doc.get("host"), str) else "",
            "port": doc.get("port") if isinstance(doc.get("port"), int) else 0,
            "build_sha256_8": build[:8] if _sha256_or_none(build) else "",
            "changes": changes if isinstance(changes, int) and not isinstance(changes, bool) and changes >= 0 else 0,
            "changed_at": _iso_or_none(doc.get("changed_at"))}


def _write_private(path: Path, text: str) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------------- the engine
class RemoteEngine(HttpEngine):
    """See the module docstring. Built by ``asr_router.build_member`` (guard, gate, clocks), or by ``enroll``. ``machine_id_fn`` (default
    ``policy.machine_id``), ``idem_fn`` (a fresh key per logical request), ``run_id`` (16 hex), ``policy_fn`` (the organisation policy; default:
    read ``cfg.policy_path``) and ``security_run`` (``subprocess.run`` for the Keychain write of a renewed token) are injected by tests."""

    engine_id = "remote"
    kind = "server"
    uses_prompt = False                      # the server builds its own prompt (X-MCAP-Prompt): asr.py sends none and builds no tokenizer
    supports_lid = True                      # until the health answer says otherwise

    def __init__(self, cfg, vocab, decision, guard, *, gate=None, sleep=time.sleep, rand=random.random, clock=time.monotonic,
                 cap_minutes: Optional[float] = None, machine_id_fn: Optional[Callable[[], str]] = None,
                 idem_fn: Callable[[], str] = lambda: str(uuid.uuid4()), run_id: Optional[str] = None,
                 policy_fn: Optional[Callable[[], Any]] = None, security_run=subprocess.run,
                 now_fn: Optional[Callable[[], datetime]] = None):
        super().__init__(cfg, vocab, decision, guard, gate=gate, sleep=sleep, rand=rand, clock=clock, cap_minutes=cap_minutes)
        self._machine_fn = machine_id_fn or (lambda: policy.machine_id())          # looked up at call time
        self._idem_fn, self._security_run = idem_fn, security_run
        self._now_fn = now_fn or (lambda: claude_usage.clock())                    # the date a consent's expiry is held against (looked up at call time)
        self._policy_fn = policy_fn or (lambda: policy.load_org_policy(cfg.policy_path))
        self.run_id = run_id if run_id and _HEX16.fullmatch(run_id) else secrets.token_hex(8)
        self._machine: Optional[str] = None
        self._machine_read = False
        self._loaded = False
        self.attest_changed = False
        self._max_lid_clips = MAX_LID_CLIPS
        self._lid_clip_samples = LID_CLIP_SAMPLES
        self._lid_lost = False               # a /v1/lid request was refused during this run: no more language ID, chunks go out as ``auto``
        self._vocab_lock = threading.RLock()
        self._vocab_sent = False
        self._putting = False
        self._vocab_body, self._vocab_sha = b"", None
        if bool(getattr(decision, "send_vocab", False)) and bool(getattr(cfg, "asr_send_vocab", False)):
            terms = vocab_terms(vocab)
            if terms:
                self._vocab_body, self._vocab_sha = canonical_vocab(terms)
        try:
            self._langs = ",".join(parse_languages(getattr(cfg, "asr_languages", None)))
        except ValueError:                   # asr.py has refused an unknown code long before an engine exists; this is only a safe default
            self._langs = ",".join(LID_CANDIDATES)

    # ------------------------------------------------------------------------------------------ headers
    def _machine_header(self) -> Optional[str]:
        """``X-MCAP-Machine``: the first 16 hex characters of sha256(machine id) (12.5), read once; None when the id cannot be had (the
        header is optional: the server only logs a change, it never rejects on it)."""
        if not self._machine_read:
            self._machine_read = True
            try:
                self._machine = hashlib.sha256(str(self._machine_fn()).encode("utf-8")).hexdigest()[:16]
            except Exception:
                self._machine = None
        return self._machine

    def common_headers(self) -> dict:
        headers = {"X-MCAP-Proto": PROTOCOL, "X-MCAP-Client": CLIENT, "X-MCAP-Run": self.run_id, "X-MCAP-Idem": self._idem_fn()}
        machine = self._machine_header()
        if machine:
            headers["X-MCAP-Machine"] = machine
        return headers

    # ------------------------------------------------------------------------------------------ the start-of-run check
    def _role(self) -> str:
        """``primary`` or ``fallback``: the role this engine has in the run's decision (the consent was checked for it)."""
        decision = self.decision
        if getattr(decision, "primary", None) != self.engine_id and getattr(decision, "fallback", None) == self.engine_id:
            return "fallback"
        return "primary"

    def _consent_terms(self) -> tuple:
        """``(backend_kind, attest_allow)`` the health answer is held to: the backend kind of the consent the run was started under and the
        allow list of build hashes of the organisation consent(s) in force for this server (None: the policy has none). Only a consent that
        is in force counts, because a build is retired by letting its entry expire:

        * a run that rests on an organisation consent (``org:`` id) is held to the list of THE entry it uses, the one ``decide_asr`` picked
          (``ConsentSet.valid_for`` with this run's role, protocol and backend kind, not expired); a duplicate entry for the same binding
          that has expired, or is meant for the other role, widens nothing. When no such entry can be found any more the run is refused
          (closed, never open);
        * a run under a consent of the user is held to the union of the lists of the organisation consents for this host that are not
          expired (the organisation's pin of its own server binds the user's consent too); none in force: no list."""
        meta = ENGINE_META[self.engine_id]
        backend = meta["backend_kind"]
        try:
            org = self._policy_fn()
        except Exception:
            org = None
        usable = org is not None and bool(getattr(org, "valid", False))
        moment = self._now_fn()
        if self.consent_id.startswith("org:"):
            entry = None
            if usable:
                entry, _why = policy.ConsentSet().valid_for(self.engine_id, self.host, self.port, self._role(), protocol=meta["protocol"],
                                                            backend_kind=backend, now=moment, org=org)
            if entry is None or getattr(entry, "id", None) != self.consent_id:
                raise _error(EnginePolicyDenied, "the organisation consent of this server cannot be found any more", None, "org_consent_missing")
            return entry.backend_kind, tuple(sorted({build for build in entry.attest_build_sha256}))
        matches = ()
        if usable:
            matches = tuple(oc for oc in getattr(org, "org_consents", ()) if oc.engine == self.engine_id and oc.host == self.host
                            and oc.port == self.port and not policy._is_expired(oc.expires, moment))      # the policy's own reading of 'expired'
        return backend, (tuple(sorted({build for oc in matches for build in oc.attest_build_sha256})) if matches else None)

    def load(self) -> None:
        """Health, attestation, retention and backend kind (docs/ASR_PROTOCOL.md 5.1), then the token renewal. Idempotent: ``asr.py`` calls it
        for every track and the server is asked once per run (a load that failed is tried again). Raises what ``check_health`` raises:
        ``EnginePolicyDenied`` (a refusal), ``EngineAuthError`` (401/403), ``EngineTransient`` (unreachable, unwell, unreadable)."""
        if self._loaded:
            return
        super().load()
        backend, allow = self._consent_terms()
        health = self.check_health(backend_kind=backend, attest_allow=allow)
        self._adopt(health)
        self._renew_if_due(health)
        self._loaded = True

    def _adopt(self, health: dict) -> None:
        """What the health answer may change in this engine: only what shortens or switches off (never a longer window, never a feature
        the client did not already have)."""
        label = self._model_label(health)
        if label:
            self.model = label
        if isinstance(health.get("supports_lid"), bool):
            self.supports_lid = health["supports_lid"]
        if health.get("confidence") in _CONFIDENCE:
            self.confidence = health["confidence"]
        limits = health.get("limits") if isinstance(health.get("limits"), dict) else {}
        samples = limits.get("max_chunk_samples")
        window = chunk_limit(samples / SR) if isinstance(samples, numbers.Real) and not isinstance(samples, bool) else None
        if window is not None:                                  # chunk_limit: 1 s to 28 s, finite; a longer or junk value changes nothing
            self.max_chunk_s = window
        clips = limits.get("max_lid_clips")
        if isinstance(clips, numbers.Real) and not isinstance(clips, bool) and clips >= 1:
            self._max_lid_clips = min(MAX_LID_CLIPS, int(clips))
        clip_samples = limits.get("max_lid_clip_samples")
        if isinstance(clip_samples, numbers.Real) and not isinstance(clip_samples, bool) and clip_samples >= SR:
            self._lid_clip_samples = min(LID_CLIP_SAMPLES, int(clip_samples))
        self._note_attest(health)

    @staticmethod
    def _model_label(health: dict) -> str:
        """``<model>@<revision>`` when the server's model name has the shape of a model id (a transcript header carries it: free text
        from a server must not get there), else ''."""
        model, revision = health.get("model"), health.get("revision")
        if not isinstance(model, str) or not _MODEL.fullmatch(model):
            return ""
        return f"{model}@{revision}" if isinstance(revision, str) and _REVISION.fullmatch(revision) else model

    def _note_attest(self, health: dict) -> None:
        """Count a build or configuration hash that differs from the last run's (a warning, not a re-consent). Never raises."""
        attest = health.get("attest") if isinstance(health.get("attest"), dict) else {}
        build, config = _sha256_or_none(attest.get("build_sha256")), _sha256_or_none(attest.get("config_sha256"))
        if self.host is None:
            return
        path = Path(self.cfg.support_dir) / ATTEST_FILE
        try:
            try:
                old = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                old = None
            old = old if isinstance(old, dict) else {}
            if old.get("host") == self.host and old.get("port") == self.port:          # the same server as last time
                changed = (old.get("build_sha256"), old.get("config_sha256")) != (build, config)
                changes = old["changes"] if isinstance(old.get("changes"), int) and not isinstance(old.get("changes"), bool) else 0
                changed_at = old.get("changed_at")
            else:                                                                       # a first sight (or another server): nothing to compare
                changed, changes, changed_at = False, 0, None
            if changed:
                self.attest_changed = True
                changes += 1
                changed_at = datetime.now().astimezone().isoformat(timespec="seconds")
                log.warning("the ASR server's build or configuration changed since the last run (attestation); no new consent is needed")
            record = {"schema": 1, "host": self.host, "port": self.port, "build_sha256": build, "config_sha256": config, "changes": changes,
                      "changed_at": changed_at}
            if record != old:
                _write_private(path, json.dumps(record, sort_keys=True))
        except Exception:
            log.debug("the attestation record could not be updated")

    # ------------------------------------------------------------------------------------------ the token
    def _renew_if_due(self, health: dict) -> None:
        left = (health.get("token") or {}).get("expires_in_days")
        if left is None or left > RENEW_WITHIN_DAYS:
            return
        try:
            self.renew()
        except EnginePolicyDenied:
            raise                                               # a closed gate or a refused destination is not a renewal problem
        except EngineError as exc:
            log.warning("the server token has %d day(s) left and could not be renewed (HTTP %s, %s): run mcap asr-engines enroll remote "
                        "before it expires", int(left), getattr(exc, "status", None) or "-", getattr(exc, "code", None) or "no code")

    def renew(self) -> dict:
        """``POST /v1/token/renew`` (5.3): a new token, written over the Keychain item of the same host-bound account and used from now
        on (the old one stays valid for 24 hours on the server). Returns ``{"renewed": True, "stored": bool, "expires": ISO or None}``.
        When only the Keychain write fails the new token is still used for this run and a warning says that the next run needs a new
        enrollment: the old token is valid for another day only. ``EngineError`` as ``exchange`` raises it, ``EngineTransient`` for an
        answer without a usable token."""
        response = self.exchange("renew", "POST", "/v1/token/renew", JSON_HEADERS, b"")
        doc = _object(response.body)
        token = doc.get("token")
        if not isinstance(token, str) or not TOKEN_SHAPE.fullmatch(token):
            raise _error(EngineTransient, "the renewal answer could not be used")
        apikey.remember(token)
        stored = True
        try:
            store_token(self.host, self.port, token, run=self._security_run)
        except EngineAuthError:
            stored = False
            log.warning("the renewed server token could not be stored in the Keychain: the old one is valid for about a day, then run "
                        "mcap asr-engines enroll remote again")
        self._token = token
        return {"renewed": True, "stored": stored, "expires": _iso_or_none(doc.get("expires"))}

    def purge(self) -> int:
        """``POST /v1/purge`` (5.7): the server forgets this token's cached answers and vocabularies. Returns how many entries it dropped."""
        response = self.exchange("purge", "POST", "/v1/purge", JSON_HEADERS, b"")
        count = _object(response.body).get("purged")
        with self._vocab_lock:
            self._vocab_sent = False                             # the server's copy of the vocabulary is gone
        return int(count) if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else 0

    # ------------------------------------------------------------------------------------------ the vocabulary
    def _ensure_vocab(self) -> None:
        """PUT the vocabulary once per run, before the first chunk that names it. A server that refuses it (4xx) costs the vocabulary for
        this run, not the transcript; anything else (the lane gate, the credential, the network) is the chunk's own failure."""
        with self._vocab_lock:
            if not self._vocab_sha or self._vocab_sent or self._putting:
                return
            self._putting = True
            try:
                self.exchange("vocab", "PUT", f"/v1/vocab/{self._vocab_sha}", JSON_HEADERS, self._vocab_body)
            except EngineHttpError as exc:
                log.warning("the server refused the vocabulary (HTTP %s): this run goes on without it", exc.status)
                self._vocab_sha = None
            else:
                self._vocab_sent = True
            finally:
                self._putting = False

    def recover(self, status: int, code: Optional[str]) -> bool:
        """404 ``vocab_unknown``: the server lost the vocabulary (a restart, the LRU of 16): send it again; the SAME chunk request goes out
        once more (same headers, same idempotency key, no attempt used). The PUT itself is never recovered this way."""
        if status != 404 or code != "vocab_unknown" or not self._vocab_sha or self._putting:
            return False
        with self._vocab_lock:
            self._vocab_sent = False
        self._ensure_vocab()
        return bool(self._vocab_sha) and self._vocab_sent

    # ------------------------------------------------------------------------------------------ chunks
    def transcribe_chunk(self, audio, language, prompt) -> dict:
        if len(audio) == 0:                                     # nothing to send (the server refuses an empty chunk)
            return {"text": "", "segments": [], "language": language or None, "avg_logprob": None, "truncated": False}
        self._ensure_vocab()
        return super().transcribe_chunk(audio, language, prompt)

    def build_request(self, chunk, language) -> tuple:
        samples = len(chunk)
        if samples > MAX_CHUNK_SAMPLES:
            raise EngineHttpError(413, "payload_too_large")     # no request: the planner never makes such a chunk, the server would say 413
        lang = language.strip().lower() if isinstance(language, str) and not self._lid_lost else ""      # after a refused /v1/lid the labels are not real
        headers = {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(samples),
                   "X-MCAP-Lang": lang if re.fullmatch(r"[a-z]{2,3}", lang) else "auto", "X-MCAP-Langs": self._langs,
                   "X-MCAP-Prompt": PROMPT_STYLE if self._vocab_sha else "none"}
        if self._vocab_sha:
            headers["X-MCAP-Vocab"] = self._vocab_sha
        return "POST", "/v1/chunk", headers, pcm16(chunk)

    def parse_response(self, status: int, body: bytes) -> dict:
        doc = _object(body)
        if doc.get("proto") != PROTOCOL or doc.get("op", "transcribe") != "transcribe":
            raise _error(EngineTransient, "the engine answer could not be used")
        segments = doc.get("segments")
        if not isinstance(segments, list):
            raise _error(EngineTransient, "the engine answer could not be used")
        opaque = self.confidence != "logprob"                   # an opaque backend has no log-prob: whatever number comes is not one
        segments = [self._segment(s, opaque) for s in segments]
        language = doc.get("language")
        text, prompt_text = doc.get("text"), doc.get("prompt_text")
        return {"text": _wellformed(text) if isinstance(text, str) else text, "segments": segments,
                "language": _wellformed(language.strip().lower()) if isinstance(language, str) else None,
                "avg_logprob": None if opaque else doc.get("avg_logprob"), "truncated": doc.get("truncated") is True,
                "prompt_text": _wellformed(prompt_text) if isinstance(prompt_text, str) else prompt_text}

    @staticmethod
    def _segment(raw: Any, opaque: bool) -> Any:
        """One segment of an answer: its text as text that can be written to disk, and no numbers when the backend has none. What is not a
        dict is passed on as it is (``clean_result`` drops it)."""
        if not isinstance(raw, dict):
            return raw
        out = dict(raw, avg_logprob=None, no_speech_prob=None, compression_ratio=None) if opaque else dict(raw)
        if isinstance(out.get("text"), str):
            out["text"] = _wellformed(out["text"])
        return out

    # ------------------------------------------------------------------------------------------ language ID
    def _lid_clip(self, clip) -> Any:
        """A clip as float32, trimmed to its centre ``_lid_clip_samples`` (6 s) when it is longer."""
        x = np.ascontiguousarray(clip, dtype=np.float32).reshape(-1)
        if len(x) > self._lid_clip_samples:
            start = (len(x) - self._lid_clip_samples) // 2
            x = x[start:start + self._lid_clip_samples]
        return x

    def detect_languages(self, clips, languages=LID_CANDIDATES):
        """Per clip ``{code: p, ..., "top": best}`` restricted to ``languages`` and renormalised (``restrict_lid``: the client does it again
        whatever the server sent), or None when the server has no language ID (health ``supports_lid`` false: ``asr.py`` then never asks).
        Requests of at most 12 clips (the server's smaller limit wins), each clip trimmed to its centre 6 s; an empty clip is not sent
        (it gets the uniform answer). A request the server REFUSES (any 4xx but the credential's: ``400`` the server has no language ID
        after all, ``413`` a limit, ``422`` an unusable clip) switches language ID off for the rest of the run (``supports_lid`` False, so
        ``asr.py`` does not ask for the next track) and is answered, like every later call in the track under way, with uniform
        probabilities and nothing sent: docs/ASR_PROTOCOL.md 12.3 (the client then uses its single-label path). The labels that come out of
        uniform answers are made up, so from then on ``build_request`` sends ``X-MCAP-Lang: auto`` and the server decides. Raising the
        refusal would fail the whole meeting's ASR stage (a configured local fallback is not tried for a 4xx), where a bad chunk only fails
        that chunk."""
        if not self.supports_lid and not self._lid_lost:
            return None
        langs = tuple(languages) or LID_CANDIDATES
        if self._lid_lost:
            return [restrict_lid({}, langs) for _ in clips]
        arrays = [self._lid_clip(clip) for clip in clips]
        out: list = [restrict_lid({}, langs) if len(a) == 0 else None for a in arrays]
        pending = [i for i, a in enumerate(arrays) if len(a)]
        for start in range(0, len(pending), self._max_lid_clips):
            batch = pending[start:start + self._max_lid_clips]
            if self._lid_lost:                                  # an earlier batch of this call was refused
                answers = [restrict_lid({}, langs) for _ in batch]
            else:
                answers = self._lid_request([arrays[i] for i in batch], langs)
            for i, answer in zip(batch, answers):
                out[i] = answer
        return out

    def _lid_request(self, arrays: list, langs: tuple) -> list:
        counts = [len(a) for a in arrays]
        headers = {"Content-Type": "application/octet-stream", "X-MCAP-Clips": ",".join(str(n) for n in counts), "X-MCAP-Langs": ",".join(langs)}
        try:
            response = self.exchange("lid", "POST", "/v1/lid", headers, b"".join(pcm16(a) for a in arrays), audio_s=sum(counts) / SR)
        except EngineHttpError as exc:
            self.supports_lid, self._lid_lost = False, True
            log.warning("the server refused language ID (HTTP %s): the language is left to the server for the rest of this run", exc.status)
            return [restrict_lid({}, langs) for _ in arrays]
        doc = _object(response.body)
        results = doc.get("results")
        if doc.get("proto") != PROTOCOL or not isinstance(results, list) or len(results) != len(arrays):
            raise _error(EngineTransient, "the language-ID answer could not be used")
        return [restrict_lid({code: _probability((item if isinstance(item, dict) else {}).get(code)) for code in langs}, langs)
                for item in results]


# ---------------------------------------------------------------------------------- enrollment (docs/ASR_PROTOCOL.md 5.2)
def enroll(cfg, code: str, *, transport=None, run=subprocess.run, decision=None, machine: Optional[str] = None,
           now: Optional[datetime] = None) -> dict:
    """Exchange a one-time enrollment code for a token and store it in the Keychain (host-bound account): ``POST /v1/enroll`` with
    ``{"code", "machine"}``, no token needed. Returns a content-free summary ``{engine, host, port, stored, expires, expires_in_days}``
    (the token, the code and the label of the user the server gave are not in it).

    The destination is the one a run would be allowed to use: ``ASR_REMOTE_URL``, the organisation policy (lane, engine list, host list)
    and a consent (organisation or user) that binds the server's private CA; without all of them nothing is sent (``EnginePolicyDenied``
    with the reason code). One attempt only: a retry after a lost answer would meet a used code, and the code is not worth more than
    one try; a code the server refused is ``EngineAuthError``, a throttled or unreachable server ``EngineTransient``, each with a fixed
    sentence. ``transport`` (tests), ``run`` (the ``security`` tool), ``decision`` and ``machine`` (the full machine id) are injectable."""
    text = code.strip() if isinstance(code, str) else ""
    if not _CODE_SHAPE.fullmatch(text):
        raise ValueError("the enrollment code is empty or malformed")
    apikey.remember(text)                                       # never printed, whatever a log or an exception would show
    moment = now or datetime.now().astimezone()
    if decision is None:
        machine_full = machine if machine is not None else policy.machine_id()
        decision = policy.decide_asr(dataclasses.replace(cfg, asr_engine="remote", asr_fallback="none"), policy.load_org_policy(cfg.policy_path),
                                     policy.LocalOnly(False, "default"), policy.load_consents(cfg.consent_path, machine_id=machine_full), None,
                                     used_minutes_today=-1.0, now=moment)
    host = (getattr(decision, "engine_hosts", None) or {}).get("remote")
    rule = (getattr(decision, "hosts", None) or {}).get(host) if host else None
    if rule is None:
        raise _error(EnginePolicyDenied, f"enrollment is not allowed for this server ({getattr(decision, 'reason', 'no-decision')})", None,
                     "not_allowed")
    if not ca_bound(rule):
        raise _error(EnginePolicyDenied, "the private CA of the server is not bound (ASR_REMOTE_CA_FILE and the consent's ca_sha256)", None,
                     "ca_unbound")
    guard = EgressGuard({host: rule}, engine_id="remote", consent_id=str((decision.consent_ids or {}).get("remote", "")), transport=transport,
                        trust="private")
    engine = RemoteEngine(dataclasses.replace(cfg, asr_retry_max=1), None, decision, guard, cap_minutes=float("inf"),
                          machine_id_fn=(lambda: machine) if machine is not None else None)
    engine.needs_secret = False                                  # there is no token yet: the code is the credential
    payload = {"code": text}
    machine_header = engine._machine_header()
    if machine_header:
        payload["machine"] = machine_header                      # the soft binding (optional): never an empty value
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    try:
        try:
            response = engine.exchange("enroll", "POST", "/v1/enroll", JSON_HEADERS, body)
        except EngineAuthError as exc:
            raise _error(EngineAuthError, "the enrollment code was refused (wrong, already used or expired): ask the administrator for a "
                         "new one", exc.status, exc.code) from None
        except EngineTransient as exc:
            if exc.status == 429:
                raise _error(EngineTransient, "too many enrollment attempts from this Mac: wait a while and try again", 429, exc.code) from None
            raise _error(EngineTransient, "the server could not be reached for enrollment (if the code was used up, ask the administrator "
                         "for a new one)", exc.status, exc.code) from None
        doc = _object(response.body)
        token = doc.get("token")
        if not isinstance(token, str) or not TOKEN_SHAPE.fullmatch(token):
            raise _error(EngineTransient, "the enrollment answer could not be used (ask the administrator for a new code)")
        apikey.remember(token)
        store_token(engine.host, engine.port, token, run=run)
        expires = _iso_or_none(doc.get("expires"))
        return {"engine": "remote", "host": engine.host, "port": engine.port, "stored": True, "expires": expires,
                "expires_in_days": _days_left(expires, moment)}
    finally:
        engine.release()
