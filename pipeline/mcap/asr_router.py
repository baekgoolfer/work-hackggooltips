"""Which engine transcribes a chunk: the primary, and ONE fallback when the primary cannot (SPEC 18). ``build_engine`` is the only place that turns the policy decision of a run into engine objects.

``RoutedEngine(primary, fallback, breaker, gate=...)`` is what ``asr.py`` sees (``asr._engine_for`` calls ``build_engine`` as soon as a run
carries a policy decision):

* Per CHUNK the primary is tried first and only a failure sends that chunk to the fallback; a chunk is never processed by both. The fallback
  is a local engine or one more external engine that the consent allowed in that role; nothing is chained after it. A fallback that fails
  fails the chunk (``asr.py`` counts it and goes on). A BLOCK (``asr_engines.BlockUpload``: the chunks of a stretch of speech in one call)
  only goes to a fallback that takes audio of that length (a Whisper fallback takes 28 s, an Azure one a chunk): else the router raises
  ``EngineBlockDeclined`` and ``asr.py`` decodes the block's chunks one by one, each routed as any chunk is.
* Triggers (the primary is bypassed for this chunk): ``EngineTransient`` (its own retries are used up), ``EngineAuthError``,
  ``EnginePolicyDenied`` (also a lane gate that closed mid-run), ``EngineCapReached``, an open circuit. Everything else (an empty answer, a
  4xx the server gave for this audio, a bug) is NOT one: it propagates and the circuit is not touched.
* ``CircuitBreaker``: three consecutive ``EngineTransient`` open it (ASR_CIRCUIT_FAILS); while open nothing is sent to the primary; after
  the cooldown (120 s) ONE chunk is the probe (half-open): success closes it, failure re-opens it with the cooldown doubled up to 600 s.
  ``EngineAuthError`` / ``EnginePolicyDenied`` / a closed gate open it for the rest of the run. ``EngineCapReached`` bypasses the chunk
  without opening anything (the cap is a budget, not a fault: the next chunk asks again). State lives in memory, per run.
* The lane gate is read again before EVERY chunk that would go to the primary (never cached): a meeting switched to local-only goes to the
  fallback from the next chunk on, without a request, and the circuit opens for good (the local_only ratchet, SPEC 18). The engines
  have their own per-attempt gate (``HttpEngine``); this one keeps the primary from even being asked.
* ``load()`` is idempotent (``asr.py`` calls it for every track). A primary that fails to load (health refused, attestation, retention, backend
  kind, unreachable) opens the circuit and the fallback is loaded; without a fallback the error propagates (``EngineTransient`` becomes
  ``AsrUnreachable`` in ``asr.py``: a waiting condition, not a failed meeting). The fallback is loaded when first needed, not before (a local
  Whisper is 3 GB).
* The prompt goes only to members that use it. The router looks like a prompt-using engine when ANY member is (a Whisper fallback), and then
  offers the tokenizer and frames of that member. ``decode_chunk`` may ask for the SAME audio again without the prompt (its retry): that
  retry goes to the member that gave the first answer and, for a member that never used the prompt, is answered from that first answer
  (the same request would only be sent, and billed, twice).
* ``provenance()`` is the ``transcript.json["asr"]`` block: what was configured, which engine processed how many chunks, how
  often the fallback was used, how often the circuit opened, what was sent, and ``privacy`` computed from what really happened (local | server |
  cloud | mixed: a request that may have reached an external server counts even when the chunk was finally transcribed locally).
  ``destination`` is a label, never a host.

``build_member`` makes one engine of a decision (what the CLI uses to look at a single engine); ``build_engine`` raises
``EnginePolicyDenied("no policy decision")`` for a missing or hand-made decision (``policy.is_issued``) and for a
blocked one. A decision whose primary is local and that has no fallback gives the plain local engine (no router, no ``asr`` key in the
transcript: the default path stays byte for byte what it was). Nothing is opened, read or started before an engine method is called.
"""
from __future__ import annotations

import logging
import random
import threading
import time
from collections import Counter
from typing import Any, Callable, Optional

from . import asr_engines, policy
from .asr_engines import (LID_CANDIDATES, SR, Engine, EngineAuthError, EngineBlockDeclined, EngineCapReached, EngineError,
                          EnginePolicyDenied, EngineTransient, engine_caps)
from .egress import EgressGuard
from .policy import ENGINE_META, LaneBlock

log = logging.getLogger("mcap.asr")

BREAKER_MAX_COOLDOWN_S = 600.0
CHUNK_SLACK_S = 0.1                  # a chunk is at most ``max_chunk_s`` long, give or take the rounding of its samples


# ---------------------------------------------------------------------------------- circuit breaker
class CircuitBreaker:
    """closed -> (``threshold`` consecutive failures) -> open -> (cooldown) -> half-open: ONE probe -> closed, or open again with the
    cooldown doubled (``max_cooldown_s`` at most). ``failure(permanent=True)`` opens it for good. Thread-safe; the clock is injected.
    ``allow()`` is the question "may I send?": in the open state after the cooldown it answers True ONCE (that call is the probe, the state
    becomes half-open) and False for everyone else until the probe has reported ``success()`` / ``failure()`` / ``abandon()``.
    ``opened`` counts the times the circuit went from closed to open (a failed probe re-opens the same outage and is not counted again)."""
    CLOSED, OPEN, HALF_OPEN = "closed", "open", "half-open"

    def __init__(self, threshold: int = 3, cooldown_s: float = 120.0, max_cooldown_s: float = BREAKER_MAX_COOLDOWN_S,
                 clock: Callable[[], float] = time.monotonic):
        self.threshold = max(1, int(threshold))
        self.base_cooldown = max(0.0, float(cooldown_s))
        self.max_cooldown = max(self.base_cooldown, float(max_cooldown_s))
        self._clock = clock
        self._lock = threading.Lock()
        self._state = self.CLOSED
        self._failures = 0
        self._cooldown = self.base_cooldown
        self._opened_at = 0.0
        self._permanent = False
        self._probing = False
        self.opened = 0

    @property
    def state(self) -> str:
        return self._state

    @property
    def permanent(self) -> bool:
        return self._permanent

    @property
    def cooldown(self) -> float:
        """The cooldown the NEXT open period will last (doubles with every failed probe)."""
        return self._cooldown

    def remaining(self) -> float:
        """Seconds until a probe is allowed (0 when closed or already due; infinite when permanent)."""
        with self._lock:
            if self._permanent:
                return float("inf")
            if self._state == self.CLOSED:
                return 0.0
            return max(0.0, self._cooldown - (self._clock() - self._opened_at))

    def allow(self) -> bool:
        with self._lock:
            if self._state == self.CLOSED:
                return True
            if self._permanent or self._probing:
                return False
            if self._state == self.OPEN and self._clock() - self._opened_at >= self._cooldown:
                self._state, self._probing = self.HALF_OPEN, True
                return True
            return False

    def success(self) -> None:
        with self._lock:
            if self._permanent:
                return
            self._state, self._failures, self._cooldown, self._probing = self.CLOSED, 0, self.base_cooldown, False

    def failure(self, *, permanent: bool = False) -> None:
        with self._lock:
            if permanent:
                self._open(permanent=True)
            elif self._state == self.HALF_OPEN:                      # the probe failed: same outage, longer cooldown
                self._cooldown = min(self._cooldown * 2.0, self.max_cooldown)
                self._state, self._opened_at, self._probing = self.OPEN, self._clock(), False
            elif self._state == self.CLOSED:
                self._failures += 1
                if self._failures >= self.threshold:
                    self._open()

    def trip(self, *, permanent: bool = False) -> None:
        """Open at once (a load that failed is not three failures away from being a verdict)."""
        with self._lock:
            if permanent or self._state == self.CLOSED:
                self._open(permanent=permanent)
            elif self._state == self.HALF_OPEN:
                self._cooldown = min(self._cooldown * 2.0, self.max_cooldown)
                self._state, self._opened_at, self._probing = self.OPEN, self._clock(), False

    def abandon(self) -> None:
        """A probe that ended neither well nor badly (a cap, a bug): the next ``allow()`` may probe again at once."""
        with self._lock:
            if self._state == self.HALF_OPEN:
                self._state, self._probing = self.OPEN, False
                self._opened_at = self._clock() - self._cooldown

    def _open(self, permanent: bool = False) -> None:
        if self._state == self.CLOSED:
            self.opened += 1                                          # only a closed circuit opening is a new outage
        self._state, self._opened_at, self._probing = self.OPEN, self._clock(), False
        if permanent:
            self._permanent = True


# ---------------------------------------------------------------------------------- router
def _is_external(member) -> bool:
    return engine_caps(member).kind != "local"


def _takes(member, seconds: float) -> bool:
    """Can ``member`` be given ``seconds`` of audio in ONE call? A chunk always; more (a block) only when it takes blocks of that length."""
    caps = engine_caps(member)
    return seconds <= caps.max_chunk_s + CHUNK_SLACK_S or (caps.accepts_blocks and caps.kind != "local" and seconds <= caps.max_block_s)


def _member_id(member) -> str:
    for attr in ("engine_id", "name"):
        value = getattr(member, attr, "")
        if isinstance(value, str) and value:
            return value
    return type(member).__name__


def _text(value: Any, limit: int = 120) -> str:
    return " ".join(value.split())[:limit] if isinstance(value, str) else ""


class RoutedEngine(Engine):
    """See the module docstring. ``gate()`` returns None (go on) or a ``LaneBlock`` (closed); it guards the PRIMARY and is called before every
    chunk that would go to it, never cached. ``progress`` (optional) receives short content-free notices."""
    name = "routed"

    def __init__(self, primary, fallback, breaker: CircuitBreaker, *, gate: Optional[Callable[[], Optional[LaneBlock]]] = None,
                 clock: Callable[[], float] = time.monotonic, progress: Optional[Callable[[str], None]] = None):
        super().__init__(str(getattr(primary, "model", "") or ""), allow_download=False)
        self.primary, self.fallback, self.breaker = primary, fallback, breaker
        self._gate, self._clock, self._progress = gate, clock, progress
        self._lock = threading.RLock()
        self._loaded = False
        self._primary_loaded = False
        self._fallback_loaded = False
        self._fallback_error: Optional[BaseException] = None
        self._open_class: type = EngineTransient            # what opened the circuit: what a call without a fallback raises
        self.chunks: Counter = Counter()                    # engine id -> chunks it transcribed
        self.fallbacks = 0                                  # chunks that went to the fallback
        self._last: Optional[tuple] = None                  # (audio, member, result, prompted) of the last chunk
        for member in (primary, fallback):
            bind = getattr(member, "bind_breaker", None)
            if bind is not None:
                bind(breaker)

    # ------------------------------------------------------------------------------------------ what the stage reads
    @property
    def engine_id(self) -> str:                             # type: ignore[override]
        return _member_id(self.primary)

    def _members(self) -> list:
        return [m for m in (self.primary, self.fallback) if m is not None]

    def lead(self):
        """The member whose declarations describe the run now: the primary, unless it is out for good and a fallback exists."""
        return self.fallback if (self.breaker.permanent and self.fallback is not None) else self.primary

    def _prompt_member(self):
        return next((m for m in self._members() if engine_caps(m).uses_prompt), None)

    @property
    def kind(self) -> str:                                  # type: ignore[override]
        """The kind of the first EXTERNAL member (primary first): a router with an external member never reports ``local``, so the
        transcript always gets its provenance block (the audio may have gone out) even when the run ended up local."""
        for member in self._members():
            if _is_external(member):
                return engine_caps(member).kind
        return engine_caps(self.primary).kind

    @property
    def residency(self) -> str:                             # type: ignore[override]
        return engine_caps(self.lead()).residency

    @property
    def uses_prompt(self) -> bool:                          # type: ignore[override]
        return self._prompt_member() is not None

    @property
    def supports_lid(self) -> bool:                         # type: ignore[override]
        return engine_caps(self.lead()).supports_lid

    @property
    def timing(self) -> str:                                # type: ignore[override]
        return engine_caps(self.lead()).timing

    @property
    def confidence(self) -> str:                            # type: ignore[override]
        return engine_caps(self.lead()).confidence

    @property
    def max_chunk_s(self) -> float:
        """The shortest chunk limit of the members: whichever of them gets a chunk can take it."""
        return min(engine_caps(m).max_chunk_s for m in self._members())

    @property
    def chunk_params(self) -> dict:                         # type: ignore[override]
        params = getattr(self.lead(), "chunk_params", None)
        return dict(params) if isinstance(params, dict) else {}

    @property
    def prompt_frames(self) -> dict:                        # type: ignore[override]
        member = self._prompt_member()
        frames = getattr(member, "prompt_frames", None) if member is not None else None
        return frames if isinstance(frames, dict) else {}

    @property
    def tokenizer(self):
        member = self._prompt_member()
        if member is None:
            raise NotImplementedError("no member of this router uses a prompt")
        return member.tokenizer

    def progress_tag(self) -> str:
        """"[server]" while the primary takes the chunks, "[local fallback]" (or "[<kind> fallback]") while the circuit is open or the
        gate has closed; empty for a local primary."""
        with self._lock:
            fallback_now = self.fallback is not None and (self.breaker.state != CircuitBreaker.CLOSED)
            if fallback_now:
                return "[local fallback]" if not _is_external(self.fallback) else f"[{engine_caps(self.fallback).kind} fallback]"
            tag = getattr(self.primary, "progress_tag", lambda: "")()
            return tag if isinstance(tag, str) else ""

    def prompt_text_seen(self) -> Optional[str]:
        texts = []
        for member in self._members():
            seen = getattr(member, "prompt_text_seen", lambda: None)()
            if isinstance(seen, str) and seen.strip() and seen not in texts:
                texts.append(seen)
        return "\n".join(texts) or None

    def describe(self) -> dict:
        info = super().describe()
        info.update({"engine": self.engine_id, "kind": self.kind, "fallback": _member_id(self.fallback) if self.fallback is not None else None,
                     "circuit": self.breaker.state})
        return info

    def usage(self) -> dict:
        total = {"requests": 0, "lid_requests": 0, "audio_s": 0.0, "bytes": 0}
        for member in self._members():
            part = getattr(member, "usage", lambda: {})()
            for key in total:
                value = part.get(key, 0) if isinstance(part, dict) else 0
                total[key] += value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0
        total["audio_s"] = round(total["audio_s"], 1)
        return total

    # ------------------------------------------------------------------------------------------ loading
    def load(self) -> None:
        with self._lock:
            if self._loaded:
                return
            try:
                self._load_primary()
                self._loaded = True
                return
            except Exception as exc:
                cause = exc
            kind = self._classify(cause, loading=True)
            if kind != "cap":
                self._open_for(cause, kind)
            if self.fallback is None:
                raise cause
            log.warning("the %s engine did not load (%s): the fallback takes over", _member_id(self.primary), type(cause).__name__)
            self._notice("ASR engine unavailable: loading the fallback")
            try:
                self._load_fallback()
            except Exception:
                if isinstance(cause, EngineTransient):
                    raise cause                       # a server that cannot be reached is a waiting condition: report that, not a missing local model
                raise
            self._loaded = True

    def _load_primary(self) -> None:
        if not self._primary_loaded:
            self.primary.load()
            self._primary_loaded = True

    def _load_fallback(self) -> None:
        if self._fallback_loaded:
            return
        if self._fallback_error is not None:
            raise self._fallback_error
        try:
            self.fallback.load()
        except Exception as exc:
            self._fallback_error = exc
            raise
        self._fallback_loaded = True

    # ------------------------------------------------------------------------------------------ the breaker's view of an error
    @staticmethod
    def _classify(exc: BaseException, *, loading: bool = False) -> Optional[str]:
        """cap | transient | permanent | None (not a trigger: it propagates). While loading, any other exception means the engine cannot
        start (a missing runtime or model): permanent for this run."""
        if isinstance(exc, EngineCapReached):
            return "cap"
        if isinstance(exc, EngineTransient):
            return "transient"
        if isinstance(exc, (EngineAuthError, EnginePolicyDenied)):
            return "permanent"
        return "permanent" if loading and isinstance(exc, Exception) else None

    def _open_for(self, exc: BaseException, kind: str) -> None:
        if kind == "transient":
            self._open_class = EngineTransient
            self.breaker.trip()
        else:
            self._open_class = EngineAuthError if isinstance(exc, EngineAuthError) else EnginePolicyDenied
            self.breaker.trip(permanent=True)

    def _open_error(self) -> EngineError:
        """What a call raises when the primary is out and there is no fallback (fixed sentences)."""
        if self._open_class is EngineAuthError:
            return EngineAuthError("the engine refused its credential earlier in this run: circuit open")
        if self._open_class is EnginePolicyDenied:
            return EnginePolicyDenied("external ASR is not allowed in this run: circuit open")
        return EngineTransient("the engine is unavailable: circuit open")

    def _primary_allowed(self) -> tuple:
        """``(True, None)`` when the primary may be asked now, else ``(False, the error to raise when there is no fallback)``. The gate is read
        first (never cached); a closed gate opens the circuit for good (local_only only ever tightens within a run)."""
        if self.breaker.permanent:
            return False, self._open_error()
        if self._gate is not None:
            try:
                block = self._gate()
            except Exception:
                block = "gate-failed"
            if block is not None:
                reason = block if isinstance(block, str) else _text(getattr(block, "reason", ""), 40)
                self._open_class = EnginePolicyDenied
                self.breaker.trip(permanent=True)
                error = EnginePolicyDenied(f"external ASR is not allowed now ({reason or 'closed'})")
                error.status, error.code = None, reason or "closed"
                return False, error
        if not self.breaker.allow():
            return False, self._open_error()
        return True, None

    def _attempt_primary(self, call: Callable[[Any], Any]) -> tuple:
        """``(result, None)`` when the primary did it, ``(None, cause)`` when it must be bypassed for this call. Any other exception
        propagates (the probe slot is given back)."""
        allowed, cause = self._primary_allowed()
        if not allowed:
            return None, cause
        stage = "load"
        try:
            self._load_primary()                       # a primary that did not load at the start (circuit opened by it) is loaded again for the probe
            stage = "call"
            result = call(self.primary)
        except Exception as exc:
            kind = self._classify(exc, loading=(stage == "load"))
            if kind is None:
                self.breaker.abandon()
                raise
            if kind == "cap":
                self.breaker.abandon()
            elif kind == "transient":
                self.breaker.failure()
                self._open_class = EngineTransient
            else:
                self._open_for(exc, "permanent")
            return None, exc
        self.breaker.success()
        return result, None

    # ------------------------------------------------------------------------------------------ chunks
    def _invoke(self, member, audio, language, prompt):
        return member.transcribe_chunk(audio, language, prompt if (prompt and engine_caps(member).uses_prompt) else None)

    def transcribe_chunk(self, audio, language, prompt) -> dict:
        with self._lock:
            last = self._last
            if last is not None and last[0] is audio and prompt is None and last[3]:
                return self._retry_without_prompt(last, audio, language)
            result, member = self._route(audio, language, prompt)
            self._last = (audio, member, result, bool(prompt))
            return result

    def _retry_without_prompt(self, last: tuple, audio, language) -> dict:
        """``decode_chunk`` asks again, without the prompt, for the audio it just had answered: the member that answered gets it (never the
        other one); a member that does not use the prompt would answer the same, so its first answer stands."""
        _, member, result, _ = last
        self._last = None                                   # one retry per first answer: the next call with this audio is a new chunk
        if not engine_caps(member).uses_prompt:
            return result
        return member.transcribe_chunk(audio, language, None)

    def _route(self, audio, language, prompt) -> tuple:
        result, cause = self._attempt_primary(lambda member: self._invoke(member, audio, language, prompt))
        if cause is None:
            self.chunks[_member_id(self.primary)] += 1
            return result, self.primary
        if self.fallback is None:
            raise cause
        if not _takes(self.fallback, len(audio) / SR):          # a block that only the primary could answer: asr.py decodes its chunks instead
            raise EngineBlockDeclined("the primary was bypassed and the fallback takes chunks only") from cause
        self._load_fallback()
        result = self._invoke(self.fallback, audio, language, prompt)
        self.chunks[_member_id(self.fallback)] += 1
        self.fallbacks += 1
        return result, self.fallback

    def detect_languages(self, clips, languages=LID_CANDIDATES):
        """Language ID by the primary when it has one and may be asked, else by the fallback when that has one; None when no member has
        one. A primary that has one but cannot be reached, with a fallback that has none, raises what stopped it (``asr.py``: unreachable)."""
        with self._lock:
            cause: Optional[BaseException] = None
            if engine_caps(self.primary).supports_lid:
                result, cause = self._attempt_primary(lambda member: member.detect_languages(clips, languages))
                if cause is None:
                    return result
            if self.fallback is not None and engine_caps(self.fallback).supports_lid:
                self._load_fallback()
                return self.fallback.detect_languages(clips, languages)
            if cause is not None:
                raise cause
            return None

    # ------------------------------------------------------------------------------------------ record
    def provenance(self) -> Optional[dict]:
        """The ``transcript.json["asr"]`` block, content-free; None when no member is external (nothing to record)."""
        with self._lock:
            members = self._members()
            if not any(_is_external(m) for m in members):
                return None
            touched_kinds: set = set()
            local_used = False
            ordered = []                                           # external members, the ones that were touched first
            for member in members:
                n = self.chunks.get(_member_id(member), 0)
                if _is_external(member):
                    used = getattr(member, "usage", lambda: {})()
                    used = used if isinstance(used, dict) else {}
                    sent = getattr(member, "sent_anything", None)
                    if n > 0 or bool(used.get("requests") or used.get("lid_requests")) or bool(sent and sent()):
                        touched_kinds.add(engine_caps(member).kind)
                        ordered.append(member)
                elif n > 0:
                    local_used = True
            if not ordered:
                ordered = [m for m in members if _is_external(m)][:1]
            if len(touched_kinds) > 1 or (touched_kinds and local_used):
                privacy = "mixed"
            else:
                privacy = next(iter(touched_kinds)) if touched_kinds else "local"
            worked = next((m for m in members if self.chunks.get(_member_id(m), 0) > 0), self.primary)
            labels = []
            for member in ordered:
                label = getattr(member, "destination_label", None)
                text = _text(label() if label is not None else engine_caps(member).kind)
                if text and text not in labels:
                    labels.append(text)
            first = ordered[0]
            block = {"schema": 1, "engine": _member_id(self.primary), "model": _text(getattr(worked, "model", "")), "kind": self.kind,
                     "privacy": privacy, "destination": _text("+".join(labels)), "region": _text(engine_caps(first).residency),
                     "protocol": _text(ENGINE_META.get(_member_id(first), {}).get("protocol", "")),
                     "consent_id": _text(getattr(first, "consent_id", "")),
                     "chunks": {k: int(v) for k, v in self.chunks.items()}, "fallbacks": int(self.fallbacks),
                     "circuit_opened": int(self.breaker.opened), "sent": self.usage()}
            return {k: v for k, v in block.items() if v not in ("", {})}

    # ------------------------------------------------------------------------------------------ release
    def release(self) -> None:
        """Releases BOTH members, whatever the first one does."""
        for member in self._members():
            try:
                member.release()
            except Exception:
                log.exception("releasing the %s engine failed", _member_id(member))
        self._last = None

    def _notice(self, text: str) -> None:
        if self._progress is not None:
            try:
                self._progress(text)
            except Exception:
                pass


# ---------------------------------------------------------------------------------- the factory
def _closed_gate(lane: str) -> LaneBlock:
    return LaneBlock(lane, "lane_denied", "gate-unavailable", f"lane '{lane}' cannot be checked: the lane gate is not available")


def _lane_gate(lane: str, gate: Optional[Callable[[str], Optional[LaneBlock]]]) -> Callable[[], Optional[LaneBlock]]:
    """A zero-argument gate for ONE lane. ``gate(lane)`` defaults to ``lanes.gate`` (the process-wide registry of the active run, which
    answers None when no run is active: ``mcap asr-engines check``); when that module cannot be imported the gate is CLOSED (an external
    engine never runs without a gate)."""
    if gate is None:
        try:
            from . import lanes
            gate = lanes.gate
        except (ImportError, AttributeError):
            return lambda: _closed_gate(lane)
    return lambda: gate(lane)


def effective_cap_minutes(cfg, consent_id: str = "") -> float:
    """The daily cap of external audio in minutes: the smallest of ASR_CLOUD_DAILY_MINUTES, the policy cap and the cap of the consent entry
    the engine runs under (the same terms ``policy.decide_asr`` applies at the start of a run; here it also bites in the middle of one).
    Reading the policy or the consent file never raises: what cannot be read adds no cap."""
    caps = [float(getattr(cfg, "asr_cloud_daily_minutes", 240))]
    try:
        path = getattr(cfg, "policy_path", None)
        if path is not None:
            org = policy.load_org_policy(path)
            if org.daily_audio_minutes_cap is not None:
                caps.append(float(org.daily_audio_minutes_cap))
        if consent_id and not consent_id.startswith("org:"):
            for entry in policy.load_consents(cfg.consent_path, machine_id="").entries:
                if entry.id == consent_id and entry.daily_minutes_cap is not None:
                    caps.append(float(entry.daily_minutes_cap))
    except Exception:
        log.debug("the daily cap could only be read from the settings")
    return min(caps)


def build_member(cfg, vocab, decision, engine_id: str, *, transport_factory: Optional[Callable[[], Any]] = None,
                 gate: Optional[Callable[[str], Optional[LaneBlock]]] = None, sleep: Callable[[float], None] = time.sleep,
                 rand: Callable[[], float] = random.random, clock: Callable[[], float] = time.monotonic) -> Engine:
    """ONE engine of a decision, without a router: the cached local engine (``asr_engines.get_engine``, downloads only if the decision allows
    them), or an external ``HttpEngine`` over an ``EgressGuard`` that knows that engine's host only (``trust="private"`` for a server, the
    system store for a cloud vendor; the lane gate of the engine's lane as ``pre_connect`` and as the engine's own gate; no ``usage`` hook:
    the engine records its attempts itself). ``mcap asr-engines check`` and doctor use it to look at a single engine. ``EnginePolicyDenied``
    when the decision names no destination for it, ``EngineUnavailable`` when no adapter exists."""
    meta = ENGINE_META.get(engine_id)
    if meta is None:
        raise EnginePolicyDenied("unknown ASR engine in the policy decision")
    if meta["kind"] == "local":
        return asr_engines.get_engine(cfg.asr_model, allow_download=bool(decision.allow_download))
    host = (decision.engine_hosts or {}).get(engine_id)
    rule = (decision.hosts or {}).get(host) if host else None
    if rule is None:
        raise EnginePolicyDenied("no destination is allowed for this ASR engine")
    cls = asr_engines.engine_class(engine_id)
    lane_gate = _lane_gate(meta["lane"], gate)
    consent = str((decision.consent_ids or {}).get(engine_id, ""))
    guard = EgressGuard({host: rule}, engine_id=engine_id, consent_id=consent, transport=transport_factory() if transport_factory else None,
                        clock=clock, pre_connect=lane_gate, trust="private" if meta["kind"] == "server" else "system")
    return cls(cfg, vocab, decision, guard, gate=lane_gate, sleep=sleep, rand=rand, clock=clock, cap_minutes=effective_cap_minutes(cfg, consent))


def build_engine(cfg, vocab, *, progress: Optional[Callable[[str], None]] = None, transport_factory: Optional[Callable[[], Any]] = None,
                 gate: Optional[Callable[[str], Optional[LaneBlock]]] = None, sleep: Callable[[float], None] = time.sleep,
                 rand: Callable[[], float] = random.random, clock: Callable[[], float] = time.monotonic) -> Engine:
    """The engine of this run, from ``cfg.asr_decision`` (made by ``policy.decide_asr``): a plain local engine, or a ``RoutedEngine`` around
    an external primary (and a fallback). ``transport_factory()`` gives the ``Transport`` of each external engine's guard (tests; default: the
    real ``HttpsTransport``), ``gate(lane)`` the lane gate (default ``lanes.gate``), ``sleep`` / ``rand`` / ``clock`` the engines' clocks.
    ``EnginePolicyDenied`` for a missing, foreign or blocked decision; ``EngineUnavailable`` for an adapter that does not exist."""
    decision = getattr(cfg, "asr_decision", None)
    if not policy.is_issued(decision):
        raise EnginePolicyDenied("no policy decision")
    if decision.blocked:
        raise EnginePolicyDenied("ASR is blocked by the policy decision")
    hooks = dict(transport_factory=transport_factory, gate=gate, sleep=sleep, rand=rand, clock=clock)
    primary = build_member(cfg, vocab, decision, decision.primary, **hooks)
    fallback = build_member(cfg, vocab, decision, decision.fallback, **hooks) if decision.fallback else None
    primary_meta = ENGINE_META[decision.primary]
    if primary_meta["kind"] == "local" and fallback is None:
        return primary                                           # the default path: no router, no provenance
    cooldown = float(getattr(cfg, "asr_circuit_cooldown_s", 120))
    breaker = CircuitBreaker(threshold=int(getattr(cfg, "asr_circuit_fails", 3)), cooldown_s=cooldown,
                             max_cooldown_s=max(BREAKER_MAX_COOLDOWN_S, cooldown), clock=clock)
    primary_gate = _lane_gate(primary_meta["lane"], gate) if primary_meta["kind"] != "local" else None
    return RoutedEngine(primary, fallback, breaker, gate=primary_gate, clock=clock, progress=progress)
