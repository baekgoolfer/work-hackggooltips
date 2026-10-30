"""The lane gates of ONE pipeline run (SPEC 18).

Five lanes leave this Mac: ``asr_remote``, ``asr_cloud``, ``llm`` (cleanup, note, verification; the ``claude`` process and the Keychain read
that go with it), ``calendar`` and ``drive``. ``resolve_run`` evaluates the organisation policy, the meeting's ``local_only`` flag, the five
lane decisions and the ASR decision once when a run starts; ``run_scope`` makes that verdict the one every gate in the process answers
with; ``gate(lane)`` is what the leaf functions ask (``note.check_ready/preflight/call_claude/run_claude``, ``calendar_lookup.fetch_events/
lookup_calendar``, the lane gate of an external ASR engine) and ``RunPrivacy.lane_block(lane)`` what the pipeline stages ask.

Rules, each with the reason it exists
  * L1 The registry of active runs is a lock-guarded module-global STACK, not a ContextVar: the transcript cleanup calls ``note.call_claude``
    from ``ThreadPoolExecutor`` workers and a worker thread does not inherit a ContextVar (``usage.meeting`` is global for the same reason).
    ``gate`` answers for the innermost active run from ANY thread and answers None only when no run is active (an explicit command such as
    ``mcap api-key check``). A process works on its sessions one after the other (a sweep included), so a stack is enough; ``run_scope``
    nests.
  * L2 A lane check comes BEFORE everything that could start a process, read the Keychain, count a budget or open a socket.
  * L3 ``lane_block`` never caches: every call re-reads ``session.json`` (a small file) and looks at the policy file's (mtime_ns, ino, size)
    stamp; a changed stamp is read again and a verdict that is STRICTER or invalid wins (a relaxation in the middle of a run is not applied).
  * L4 Ratchet: a ``local_only`` that was seen true once stays true for the rest of the run, and so does every lane denial. An unreadable
    ``session.json`` denies the lane (reason ``session-unreadable``) and counts as true. The next run derives everything again from the files.
  The promise is 'no NEW external attempt starts'; a request or ``claude`` call that is already running is not interrupted.

A run that restricts anything (local_only, or an organisation denial of the note, calendar or Drive lane) says so in three places: the
``state.json`` keys (``state_fields``), the ``transcript.json["policy"]`` block (``transcript_policy_block``) and the ``Privacy:`` line of
transcript.md; such a folder keeps its ``state.json`` (``keeps_state``). The personal install (no policy, flag false) gets none of it,
so its files are byte for byte what they were.

Nothing here starts a process or opens a socket at import. ``run_scope`` installs the socket tripwire of ``egress`` (lazily) for a run that
neither uses an external engine nor may download a model.
"""
from __future__ import annotations

import dataclasses
import logging
import os
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Optional

from . import policy as policy_mod
from .policy import AsrDecision, ConsentSet, HardwareProbe, LaneBlock, LaneDecision, LocalOnly, OrgPolicy

log = logging.getLogger("mcap.lanes")

TEXT_LANES = ("llm", "calendar", "drive")     # the lanes a reader of a transcript knows (note, calendar, Drive); the ASR lanes are routing
USER_DISABLED = "user-disabled"               # the user's own setting is not a restriction that is shown or that keeps state.json
UNREADABLE_REASON = "session-unreadable"      # SPEC 18 / docs/PRIVACY_LANES.md 9
GATE_ERROR = "gate-error"                     # the gate itself failed: closed
POLICY_FILE_MARKER = "policy.required"


class LocalArchiveUnsafe(Exception):
    """LOCAL_ARCHIVE_DIR is not on the allow-list (``policy.local_archive_ok``). ``reason`` is the code (outside-allowed-roots, symlink-in-path,
    different-device, bad-path, empty-path). The pipeline reports it as ``error_kind=local_archive_unsafe`` (no automatic retry)."""

    def __init__(self, reason: str):
        super().__init__(f"LOCAL_ARCHIVE_DIR is not an allowed local folder ({reason})")
        self.reason = reason


@dataclass
class PrivacyInputs:
    """What ``resolve_run`` reads from the outside, replaceable in a test: a value of None means 'load it the normal way'. ``policy`` an
    already loaded OrgPolicy, ``consents`` / ``hw`` the ASR inputs (the consent file is only read, and the hardware only probed, when the
    configuration names an engine that needs them), ``now`` the clock of the ASR decision. ``stat_fn`` is the lstat the policy file is
    read through when the gate loads it AGAIN (a test is not root; default ``os.lstat``), ``sleep`` the pause of the loader's confirming
    re-read of an invalid file, ``meeting`` session facts for a caller that has no session folder (``transcribe-file``: None = the default
    chain of the flag)."""
    policy: Optional[OrgPolicy] = None
    consents: Optional[ConsentSet] = None
    hw: Optional[HardwareProbe] = None
    now: Optional[datetime] = None
    stat_fn: Optional[Callable] = None
    sleep: Optional[Callable[[float], None]] = None
    meeting: Optional[Mapping] = None


# How informative a denial reason is: the lock of the policy explains more than an unreadable session, that more than local_only, that more
# than a single lane's organisation rule, and the user's own 'off' least. A lane stays closed whatever happens; this only picks the word shown.
_RANKS = {USER_DISABLED: 0, "local_only": 2, UNREADABLE_REASON: 3, "policy-locked": 4, GATE_ERROR: 4}


def _rank(reason: str) -> int:
    return _RANKS.get(reason, 1)


def _plain(lane: str, reason: str) -> LaneDecision:
    return LaneDecision(lane, False, reason)


def _closed_block(lane: str, reason: str = GATE_ERROR) -> LaneBlock:
    return LaneBlock(lane, "lane_denied", reason, f"lane '{lane}' is not allowed: {reason}")


class RunPrivacy:
    """The verdict of one run. ``local_only``, ``policy``, ``lanes`` and ``asr`` are the facts as they stand NOW (they only ever get
    stricter); ``lane_block`` is the gate. All state is guarded by one re-entrant lock, so the cleanup's worker threads and the main thread
    may ask at the same time. Nothing here raises."""

    def __init__(self, cfg, *, session_path: Optional[Path], local_only: LocalOnly, policy: OrgPolicy, lanes: Mapping[str, LaneDecision],
                 asr: AsrDecision, stat_fn: Optional[Callable] = None, sleep: Optional[Callable[[float], None]] = None):
        self.cfg = cfg
        self.session_path = Path(session_path) if session_path is not None else None
        self.local_only = local_only
        self.policy = policy
        self.lanes: Mapping[str, LaneDecision] = dict(lanes)
        self.asr = asr
        self.claude_pin_cache: dict = {}                  # note.verify_claude_bin: one signature check per run
        self._lock = threading.RLock()
        self._stat = stat_fn or os.lstat
        self._sleep = sleep or time.sleep
        self._ratchet: Optional[LocalOnly] = local_only if local_only.value else None
        self._denied: dict[str, LaneDecision] = {lane: d for lane, d in self.lanes.items() if not d.allowed}
        self._stamp = self._policy_stamp()

    # ------------------------------------------------------------------------------------------ the gate
    def lane_block(self, lane: str) -> Optional[LaneBlock]:
        """None when ``lane`` may start a new external attempt right now, else the LaneBlock (kind ``lane_denied``). Re-reads session.json and
        the policy stamp on EVERY call (SPEC 18), ratchets (L4) and never raises: a failure inside the gate closes the lane."""
        try:
            with self._lock:
                self._refresh()
                decision = self.lanes.get(lane)
                if decision is None:
                    return _closed_block(lane, "unknown-lane")
                return None if decision.allowed else decision.block()
        except Exception as exc:                       # the gate must close, never open, on its own failure
            log.warning("lane gate failed (%s): lane %s closed", type(exc).__name__, lane)
            return _closed_block(lane)

    def _refresh(self) -> None:
        stamp = self._policy_stamp()
        if stamp != self._stamp:
            self._stamp = stamp
            self._adopt_policy()
        raw, _status = self._read_flag()
        lo = policy_mod.effective_local_only(raw, self.policy, self.cfg)
        if lo.value and self._ratchet is None:
            self._ratchet = lo
        self.local_only = self._ratchet or lo
        merged = policy_mod.lane_decisions(self.local_only, self.policy, self.cfg)
        unreadable = self.local_only.source == "fail-closed:unreadable"
        for lane, decision in merged.items():
            if not decision.allowed:
                if unreadable and decision.reason == "local_only":
                    decision = _plain(lane, UNREADABLE_REASON)
                before = self._denied.get(lane)
                if before is None or _rank(decision.reason) > _rank(before.reason):
                    self._denied[lane] = decision          # sticky; a stronger reason replaces a weaker one (never an opening)
        self.lanes = {lane: self._denied.get(lane) or decision for lane, decision in merged.items()}

    def _read_flag(self):
        if self.session_path is None:                   # no session folder (transcribe-file): the default chain, nothing to re-read
            return None, "absent"
        return policy_mod.read_session_local_only(self.session_path)

    def _policy_stamp(self) -> Any:
        """(policy file stamp, marker stamp) as lstat reports them: a changed value means 'read the policy again'. A file that cannot be
        examined is its own value ("error"), so it is read again (and a policy that cannot be read locks)."""
        path = getattr(self.cfg, "policy_path", None)
        if path is None:
            return None
        out = []
        for target in (Path(path), Path(path).parent / POLICY_FILE_MARKER):
            try:
                st = os.lstat(target)             # the real file system: the injected stat_fn only decides what the LOADER believes of owner and mode
                out.append((getattr(st, "st_mtime_ns", 0), getattr(st, "st_ino", 0), getattr(st, "st_size", 0)))
            except (FileNotFoundError, NotADirectoryError):
                out.append(None)
            except OSError:
                out.append("error")
        return tuple(out)

    def _adopt_policy(self) -> None:
        """The policy file changed during the run: read it again. A locked reading, or a valid one that replaces a valid or absent policy, is
        adopted (the sticky per-lane denials of ``_refresh`` keep every lane any reading denied closed); a vanished file and a valid file
        after a lock are relaxations and are not."""
        try:
            from . import __version__
            path = Path(self.cfg.policy_path)
            fresh = policy_mod.load_org_policy(path, required_marker=path.parent / POLICY_FILE_MARKER, stat_fn=self._stat,
                                               current_version=__version__, sleep=self._sleep)
        except Exception as exc:
            log.warning("policy re-read failed (%s): the lanes stay as they are", type(exc).__name__)
            return
        if not fresh.present:                              # the file vanished: a relaxation, and the pin / child env of the old one stay
            return
        if fresh.locked or not self.policy.locked:
            if fresh.locked and not self.policy.locked:
                log.warning("the organisation policy changed during the run and is now locked (%s): external lanes closed",
                            (fresh.locked_reason or "invalid")[:60])
            self.policy = fresh

    def record_denial(self, lane: str, reason: str) -> None:
        """A layer below the pipeline closed ``lane`` for a reason the lane decision does not know (the claude binary does not match the
        policy's signature pin): the run now says so too (state.json, the Privacy line, the kept state file). Sticky like every denial."""
        with self._lock:
            before = self._denied.get(lane)
            if before is None or _rank(reason) > _rank(before.reason):
                self._denied[lane] = _plain(lane, reason)
            self.lanes = {name: self._denied.get(name) or decision for name, decision in self.lanes.items()}

    def rebind(self, session_dir: Path) -> None:
        """The session folder moved (publish): later gate calls read session.json from its new place."""
        with self._lock:
            self.session_path = Path(session_dir) / "session.json"

    # ------------------------------------------------------------------------------------------ what the run says about itself
    def _snapshot(self) -> tuple[LocalOnly, Mapping[str, LaneDecision]]:
        with self._lock:
            try:
                self._refresh()
            except Exception as exc:
                log.warning("lane status unavailable (%s): reported as closed", type(exc).__name__)
            return self.local_only, dict(self.lanes)

    def restricted(self) -> bool:
        """True when this meeting is local-only or the organisation denied the note, calendar or Drive lane (the user's own switch off does
        not count): the folder then says so and keeps its state.json."""
        lo, lanes = self._snapshot()
        return bool(lo.value) or any(not lanes[lane].allowed and lanes[lane].reason != USER_DISABLED for lane in TEXT_LANES if lane in lanes)

    def keeps_state(self) -> bool:
        """A restricted folder keeps state.json (the documented exception of the 'a clean archive folder has no state file' rule)."""
        return self.restricted()

    @staticmethod
    def _status(decision: LaneDecision) -> str:
        if decision.allowed:
            return "ok"
        return "off" if decision.reason == USER_DISABLED else f"skipped:{decision.reason}"

    def lane_status(self) -> dict:
        """{"llm": "ok" | "skipped:<reason>" | "off", "calendar": ..., "drive": ...} as of now ("off": the user's own setting; not a restriction)."""
        _lo, lanes = self._snapshot()
        return {lane: self._status(lanes[lane]) for lane in TEXT_LANES if lane in lanes}

    def transcript_policy_block(self) -> Optional[dict]:
        """The ``transcript.json["policy"]`` block, or None for a meeting that restricted nothing (the file then has no new key)."""
        if not self.restricted():
            return None
        lo, _lanes = self._snapshot()
        return {"local_only": bool(lo.value), "lanes": self.lane_status()}

    def state_fields(self) -> dict:
        """The keys a run adds to state.json: local_only, local_only_source, lanes and asr (content-free). Empty for the personal default
        (no policy, flag false, nothing denied): that state.json is byte for byte what it was."""
        lo, _lanes = self._snapshot()
        if not (self.policy.present or self.restricted()):
            return {}
        return {"local_only": bool(lo.value), "local_only_source": lo.source, "lanes": self.lane_status(),
                "asr": {"primary": self.asr.primary, "fallback": self.asr.fallback, "reason": self.asr.reason}}

    # ------------------------------------------------------------------------------------------ ASR and the archive
    def default_local_asr(self, cfg) -> bool:
        """True when ASR runs exactly as it always did: no policy, flag false, local Whisper alone, model download allowed. The flag is read
        again for the answer (a Local-Only switch made after the run started, while the audio was prepared, counts)."""
        lo, _lanes = self._snapshot()
        return self._default_local(cfg, lo)

    def _default_local(self, cfg, lo: LocalOnly) -> bool:
        d = self.asr
        return (not self.policy.present and not lo.value and d.primary == "whisper" and d.fallback is None and not d.allow_egress
                and not d.blocked and d.allow_download is True and getattr(cfg, "asr_allow_download", True) is True)

    def cfg_for_asr(self, cfg):
        """The config the ASR stage gets: the SAME object for the default path (the engine then comes from ``get_engine(cfg.asr_model)`` as
        before, goldens and test patches stay valid), otherwise a copy that carries this run's ASR decision. The pipeline log of a
        local-only meeting carries no transcript snippets (``log_content`` False) and no model is downloaded for it. The flag is read at
        THIS moment: a meeting switched to local-only after the run's decision was made gets the same treatment (the decision of the run is
        narrowed to ``allow_download=False`` for the copy; ``self.asr`` is not touched)."""
        with self._lock:
            lo, _lanes = self._snapshot()
            if self._default_local(cfg, lo):
                return cfg
            decision = self.asr
            if lo.value and decision.allow_download:
                decision = dataclasses.replace(decision, local_only=True, allow_download=False)
            return dataclasses.replace(cfg, asr_decision=decision, log_content=bool(getattr(cfg, "log_content", True)) and not lo.value)

    def archive_root(self) -> tuple[Path, str]:
        """(root, "drive" | "local"): ``ARCHIVE_DIR`` while the drive lane is open, else the validated ``LOCAL_ARCHIVE_DIR``. The lane (and
        with it the realpath of ARCHIVE_DIR against ``archive.allowed_roots``) is evaluated anew on every call. Raises LocalArchiveUnsafe."""
        if self.lane_block("drive") is None:
            return Path(self.cfg.archive_dir), "drive"
        root = Path(self.cfg.local_archive_root)
        ok, why = policy_mod.local_archive_ok(root, self.cfg.support_dir, self.policy.local_roots)
        if not ok:
            raise LocalArchiveUnsafe(why)
        return root, "local"


# ---------------------------------------------------------------------------------------------- resolving a run
def _needs_hardware(cfg) -> bool:
    """Does the ASR decision need the hardware verdict? Only for ASR_ENGINE=auto or an external primary (the 'blocked' rule; a Whisper
    fallback behind one is covered by the external primary): ASR_ENGINE=whisper (today's default) starts no process to find out."""
    primary, _fallback = policy_mod.requested_engines(cfg)
    return primary != "whisper"


def _needs_consents(cfg) -> bool:
    """Does the ASR decision need the consent file (and today's usage)? When the primary is ``auto`` or any engine of kind other than local
    is named as primary or fallback. The list is ``policy.ENGINE_META``'s, so a new provider needs no change here."""
    primary, fallback = policy_mod.requested_engines(cfg)
    external = tuple(name for name, meta in policy_mod.ENGINE_META.items() if meta["kind"] != "local")
    return primary in external + ("auto",) or fallback in external


def _asr_inputs(cfg, inputs: PrivacyInputs) -> tuple[Optional[ConsentSet], Optional[HardwareProbe], float]:
    hw = inputs.hw
    if hw is None and _needs_hardware(cfg):
        try:
            hw = policy_mod.probe_hardware(cfg, now=inputs.now)
        except Exception as exc:
            log.warning("hardware probe failed (%s): capability unknown", type(exc).__name__)
    consents, used = inputs.consents, 0.0
    if _needs_consents(cfg):
        if consents is None:
            try:
                consents = policy_mod.load_consents(cfg.consent_path, machine_id=policy_mod.machine_id(), now=inputs.now)
            except Exception as exc:
                log.warning("consent file unreadable (%s): no consent", type(exc).__name__)
        try:
            from . import asr_usage
            used = float(asr_usage.minutes_today(cfg))
        except Exception as exc:
            log.warning("asr usage unreadable (%s): counted as none", type(exc).__name__)
    return consents, hw, used


def _closed_run(cfg, session_dir, inputs: PrivacyInputs, why: str) -> RunPrivacy:
    """What a run gets when resolving it failed: local-only, every lane denied, local ASR (SPEC 18: closing never loses the meeting)."""
    lo = LocalOnly(True, f"fail-closed:{why}")
    lanes = {lane: _plain(lane, GATE_ERROR) for lane in policy_mod.LANES}
    path = Path(session_dir) / "session.json" if session_dir is not None else None
    return RunPrivacy(cfg, session_path=path, local_only=lo, policy=policy_mod.absent_policy(), lanes=lanes,
                      asr=policy_mod._safe_decision(cfg, lo, why), stat_fn=inputs.stat_fn, sleep=inputs.sleep)


def resolve_run(cfg, session, session_dir, *, inputs: Optional[PrivacyInputs] = None) -> RunPrivacy:
    """Evaluate the organisation policy, the flag of this meeting, the five lanes and the ASR decision. ``session`` is the parsed
    session.json (informational: the flag is read from the file itself so that the first read and every gate read are the same kind of
    read), ``session_dir`` its folder (None: no session folder, the default chain of the flag). Never raises: a failure here is a closed run."""
    inputs = inputs or PrivacyInputs()
    try:
        stat_fn = inputs.stat_fn or os.lstat
        org = inputs.policy
        if org is None:
            from . import __version__
            path = getattr(cfg, "policy_path", None)
            org = policy_mod.load_org_policy(path, stat_fn=stat_fn, current_version=__version__,
                                             **({"sleep": inputs.sleep} if inputs.sleep else {}))
        session_path = Path(session_dir) / "session.json" if session_dir is not None else None
        if session_path is not None:
            raw, _status = policy_mod.read_session_local_only(session_path)
        else:
            facts = inputs.meeting if inputs.meeting is not None else (session if isinstance(session, Mapping) and session_dir is None else {})
            raw, _status = policy_mod.read_session_local_only(facts)
        lo = policy_mod.effective_local_only(raw, org, cfg)
        lanes = policy_mod.lane_decisions(lo, org, cfg)
        if lo.source == "fail-closed:unreadable":
            lanes = {lane: _plain(lane, UNREADABLE_REASON) if d.reason == "local_only" else d for lane, d in lanes.items()}
        consents, hw, used = _asr_inputs(cfg, inputs)
        decision = policy_mod.decide_asr(cfg, org, lo, consents, hw, used_minutes_today=used, now=inputs.now)
        return RunPrivacy(cfg, session_path=session_path, local_only=lo, policy=org, lanes=lanes, asr=decision, stat_fn=inputs.stat_fn,
                          sleep=inputs.sleep)
    except Exception as exc:
        log.exception("could not resolve the privacy lanes of this run (%s): treating it as local-only", type(exc).__name__)
        return _closed_run(cfg, session_dir, inputs, "resolve-error")


# ---------------------------------------------------------------------------------------------- the registry of active runs (L1)
_STACK: list[RunPrivacy] = []
_STACK_LOCK = threading.Lock()


def tripwire_mode(decision: AsrDecision) -> Optional[str]:
    """Which socket tripwire a run gets: "audit" when an external ASR engine may be used, "strict" when no external engine is
    used AND no model may be downloaded (a local-only run, the company baseline), None for the personal default (no tripwire: today)."""
    if decision.allow_egress:
        return "audit"
    if not decision.allow_download:
        return "strict"
    return None


@contextmanager
def run_scope(priv: RunPrivacy) -> Iterator[RunPrivacy]:
    """``priv`` is the active run inside the block (``gate`` answers with it from any thread) and, depending on its ASR decision, the socket
    tripwire is installed (``tripwire_mode``; reference counted, so a sweep's sessions nest). A tripwire that cannot be installed is logged,
    never fatal: it is a second line of defence behind the gates."""
    handle = None
    with _STACK_LOCK:
        _STACK.append(priv)
    try:
        mode = tripwire_mode(priv.asr)
        if mode is not None:
            try:
                from .egress import Tripwire
                handle = Tripwire.install(mode)
            except Exception as exc:
                log.warning("socket tripwire not installed (%s)", type(exc).__name__)
        yield priv
    finally:
        if handle is not None:
            try:
                handle.uninstall()
            except Exception:
                log.debug("tripwire uninstall failed", exc_info=True)
        with _STACK_LOCK:
            for i in range(len(_STACK) - 1, -1, -1):
                if _STACK[i] is priv:
                    del _STACK[i]
                    break


def current() -> Optional[RunPrivacy]:
    """The innermost active run, or None."""
    with _STACK_LOCK:
        return _STACK[-1] if _STACK else None


def gate(lane: str) -> Optional[LaneBlock]:
    """The lane gate of the leaf functions. Any thread. None = go ahead: the lane is open for the active run, or NO run is active (an
    explicit command: nothing to gate). A LaneBlock = do not start a new external attempt. Never raises."""
    priv = current()
    if priv is None:
        return None
    return priv.lane_block(lane)


def llm_child_env() -> dict:
    """The extra variables the active run's valid policy adds to the claude child's environment (``policy.llm.child_env``, names from a
    fixed code allow-list); empty without an active run or without a policy: the child env is then the allow-list it always was."""
    priv = current()
    try:
        if priv is not None and priv.policy.valid:
            return {k: v for k, v in dict(priv.policy.llm_child_env).items() if k in policy_mod.CHILD_ENV_ALLOWED and isinstance(v, str)}
    except Exception:
        log.debug("llm child env unavailable", exc_info=True)
    return {}
