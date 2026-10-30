"""Pipeline orchestration: audio -> asr -> cleanup -> note -> verify -> publish for one session (SPEC 7, 14).

Design rules:
  * Resumable: each stage is skipped when its artifact already exists (transcript.json+md, a valid transcript.cleaned.*,
    meeting-note.md, the Verification footer of the note, archive folder). `from_stage` / `force` regenerate a stage and everything
    after it. cleanup and verify are LLM quality passes (TRANSCRIPT_CLEANUP / NOTE_VERIFY, both fail-soft): any problem there
    only sets state.warning and the pipeline carries on with the raw transcript / the draft note.
  * transcript.json / transcript.md are written atomically and fsynced BEFORE anything else happens and are never modified
    afterwards (except the `Meeting:` title line). The cleaned transcript is a separate pair of files.
  * state.stage stays one of queued|audio|transcribing|noting|publishing|done|failed (the Swift app maps them to menu text);
    the LLM passes use stage "noting" with stage_detail "cleaning transcript 3/15" / "creating note" / "verifying note".
  * Failure isolation: ASR failure keeps the audio (session stays in staging, state failed). A note failure keeps the
    transcript and the transcript is still published (archive folder has transcript.md, no meeting-note.md and a
    state.json = failed, retryable). An archive that is not available keeps the session in staging (failed, retryable).
  * One run per session at a time (flock on SUPPORT_DIR/locks/<session_id>.lock). A session that is still being recorded
    (session.json end_time null and fresh WAV files) is refused with SessionBusy.
  * mcap.audioprep / asr / transcript belong to the transcription component: they are imported lazily, and every one of
    them can be replaced through `Deps` (tests, benchmarks).
SPEC 17 (billing modes, CLAUDE_AUTH=api|subscription): the stages are the same in both modes. In api mode a USD budget (usage.budget_block) is
checked before the cleanup / calendar / note / verify stage: cleanup, calendar and verify are skipped with a state.warning, the note fails
with error_kind budget_daily (retryable, resets_at = the next local midnight, transcript still published). `budget_daily` and
`credit_exhausted` (the note stage waits for money) do not count as a failed attempt (WAITING_KINDS), so a retry sweep never uses the session up.
After publish the staging dir is gone; a "tombstone" dir holding only state.json stays behind so the Swift app can show the
title / open the folder and never re-enqueues the session (publish.leave_tombstone).

Every run has a Claude call budget (MAX_CLAUDE_CALLS_PER_MEETING, usage.py) with calls reserved for the note first, then the
calendar lookup and the verification; the transcript cleanup gets the rest. A pass that cannot run (cap, guard, failure) never stops
the note; the note says so: `Verification: not applied (<reason>)` under the H1 and in the footer comment, the footer also names a
skipped cleanup (`transcript: raw (cleanup not applied: <reason>)`). `pending_items()` / `find_pending_sessions()` find everything a
retry can finish (failed + retryable of every kind, sessions that died mid-stage), `process_session(only_if_pending=True)` re-checks
that under the session lock so a retry sweep can run next to a normal run and never touches a live recording.

SPEC 18: every run first resolves its privacy lanes (`lanes.resolve_run`: the
organisation policy, the meeting's `local_only` flag, the five lanes, the ASR decision) and works inside `lanes.run_scope`, so the gate of
every leaf function answers for it from any thread. A pipeline stage that needs a lane asks `self.privacy.lane_block(lane)` BEFORE
`self.ready()`, a budget, a process or a Keychain read; a closed lane is a SKIP (`lane_denied`, no warning, `stage` stays `done`), never a
failure. A restricted meeting (local-only, or an organisation denial of the note, calendar or Drive lane) says so in state.json
(`local_only`, `local_only_source`, `lanes`, `asr`), in `transcript.json["policy"]` and in the `Privacy:` line of transcript.md, goes to
the validated LOCAL_ARCHIVE_DIR instead of Drive and keeps its state.json; the personal default writes none of it. New error kinds:
`asr_policy_blocked` (this Mac cannot transcribe locally and no external engine may be used: audio kept, not retryable),
`asr_unreachable` (the external ASR server could not be reached: retryable and, like the budget waits, not a failed attempt) and
`local_archive_unsafe` (LOCAL_ARCHIVE_DIR is not on the allow-list: not retryable). The drive lane is checked again right before the move
and, after a cross-volume copy, right before the hidden `.partial` folder is renamed into place (`publish.CommitBlocked`: the copy is
deleted and the meeting goes to the local archive). A folder in the Drive or the local archive is processed in place (`in_archive`), so
reprocessing a local folder never reaches Drive.
"""
from __future__ import annotations

import fcntl
import importlib
import logging
import os
import re
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from . import apikey, calendar_lookup, cleanup, lanes, note, overage, publish, usage, verify
from .config import Config
from .state import atomic_write_json, atomic_write_text, read_json, read_state, remove_state, write_state
from .vocab import Vocab, load_vocab

log = logging.getLogger("mcap.pipeline")

STAGES = ("audio", "asr", "cleanup", "note", "verify", "publish")
DISCARD_SPEECH_SECONDS = 20.0          # SPEC 7.2: both tracks together less than ~20 s of speech -> discard
PROGRESS_MIN_INTERVAL = 1.0
LIVE_WINDOW_SECONDS = 120.0            # SPEC 14.4: no end_time and a WAV written within this long = still being recorded
MAX_AUTO_ATTEMPTS = 3                  # the automatic sweep gives up on a session after this many failed runs
MID_STAGES = ("queued", "audio", "transcribing", "noting", "publishing")   # state.stage values of a run in progress (or one that died)
WAITING_KINDS = ("budget_daily", "credit_exhausted", "asr_unreachable")   # the run waits for the clock / for credit (api mode, SPEC 17) / for the
                                                       # ASR server (SPEC 18), it did not fail by itself: not counted as a failed attempt,
                                                       # so retry sweeps never use the session up
NOTE_BACKUP = "meeting-note.prev.md"
_MEETING_DIR = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{4}_")
_STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}_\d{4})")


class SessionBusy(Exception):
    """Another process is already working on this session, or the session is still being recorded."""


class StageError(Exception):
    def __init__(self, stage: str, message: str, retryable: bool = True, resets_at: Optional[int] = None,
                 kind: Optional[str] = None):
        super().__init__(message)
        self.stage, self.message, self.retryable, self.resets_at = stage, message, retryable, resets_at
        self.kind = kind or f"{stage}_failed"


@dataclass
class PipelineResult:
    ok: bool
    stage: str                              # final state.stage: "done" | "failed"
    final_dir: Optional[Path] = None        # archive folder (or the session dir when it stayed in staging)
    error: Optional[str] = None
    error_kind: Optional[str] = None
    retryable: bool = False
    discarded: bool = False
    published: bool = False
    title: Optional[str] = None
    warning: Optional[str] = None           # soft problems (cleanup/verify skipped, overage seen, ...), one line
    skipped: bool = False                   # only_if_pending: nothing to do any more (another run finished it meanwhile)


# ---------------------------------------------------------------------------------- seam for the transcription component
def _lazy(module: str, name: str) -> Callable:
    def call(*args, **kwargs):
        return getattr(importlib.import_module(f"mcap.{module}"), name)(*args, **kwargs)
    return call


@dataclass
class Deps:
    """Injectable collaborators. None = the real implementation (imported lazily when first used)."""
    prepare_audio: Optional[Callable] = None        # (session_dir, session, force=False) -> PreparedAudio
    transcribe_tracks: Optional[Callable] = None    # (prepared, cfg, vocab, progress) -> transcript dict (SPEC 4.4)
    transcribe_array: Optional[Callable] = None     # (audio, cfg, vocab, language=None, progress=...) -> [segment dict] (transcribe-file)
    render_markdown: Optional[Callable] = None      # (transcript, meta) -> str
    check_ready: Optional[Callable] = None          # (cfg, allow_overage) -> note.Readiness
    generate_note: Optional[Callable] = None        # (transcript_md, meta, cfg, vocab, allow_overage=, ready=) -> NoteResult
    lookup_calendar: Optional[Callable] = None      # (cfg, session, session_dir=) -> CalendarMatch | None
    cleanup_transcript: Optional[Callable] = None   # (transcript, cfg, vocab, meta=, render=, source_sha256=, progress=, allow_overage=) -> CleanupResult
    verify_note: Optional[Callable] = None          # (draft, raw_md, cleaned_md, meta, cfg, vocab, allow_overage=) -> VerifyResult

    def resolved(self) -> "Deps":
        return Deps(
            prepare_audio=self.prepare_audio or _lazy("audioprep", "prepare_audio"),
            transcribe_tracks=self.transcribe_tracks or _lazy("asr", "transcribe_tracks"),
            transcribe_array=self.transcribe_array or _lazy("asr", "transcribe_array"),
            render_markdown=self.render_markdown or _lazy("transcript", "render_markdown"),
            check_ready=self.check_ready or note.check_ready,
            generate_note=self.generate_note or note.generate_note,
            lookup_calendar=self.lookup_calendar or calendar_lookup.lookup_calendar,
            cleanup_transcript=self.cleanup_transcript or cleanup.cleanup_transcript,
            verify_note=self.verify_note or verify.verify_note,
        )


# ---------------------------------------------------------------------------------- small helpers
def _one_line(text: Any, limit: int = 220) -> str:
    """One bounded line; an API key shape in it is masked first (SPEC 17), then the text is cut (no half-masked key)."""
    return apikey.redact(re.sub(r"\s+", " ", str(text))).strip()[:limit]


def _is_within(path: Path, parent: Path) -> bool:
    try:
        a, b = os.path.realpath(path), os.path.realpath(parent)
        return os.path.commonpath([a, b]) == b and a != b
    except ValueError:
        return False


def _safe_key(key: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", key)[:120] or "session"


def _in_local_archive(path: Path, cfg: Config) -> bool:
    """Is `path` inside the local archive root (LOCAL_ARCHIVE_DIR, default SUPPORT_DIR/local-meetings)? Like the Drive archive, a folder
    there is processed in place (reprocess never moves it, so it never reaches Drive). Pure path arithmetic: nothing is created or checked."""
    root = getattr(cfg, "local_archive_root", None)
    return root is not None and _is_within(path, Path(root))


def _is_unreachable(exc: BaseException) -> bool:
    """asr.AsrUnreachable (every chunk failed to reach an external engine), recognised by name: asr.py is imported lazily (numpy)."""
    return any(klass.__name__ == "AsrUnreachable" for klass in type(exc).__mro__)


@contextmanager
def session_lock(cfg: Config, key: str) -> Iterator[None]:
    """Exclusive lock per session id (kept outside the session dir, which moves on publish). Raises SessionBusy."""
    try:
        Path(cfg.locks_dir).mkdir(parents=True, exist_ok=True)
        fd = os.open(Path(cfg.locks_dir) / f"{_safe_key(key)}.lock", os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as exc:
        log.warning("cannot create lock file (%s); continuing without a lock", exc)
        yield
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SessionBusy(f"session {key} is already being processed by another mcap process") from None
        try:
            os.ftruncate(fd, 0)
            os.write(fd, f"{os.getpid()}\n".encode())
        except OSError:
            pass
        yield
    finally:
        os.close(fd)           # also releases the flock


def is_live_recording(session_dir: Path, session: Optional[dict] = None, now: Optional[float] = None,
                      window: float = LIVE_WINDOW_SECONDS) -> bool:
    """SPEC 14.4: True while the Swift app is (probably) still recording into this directory: session.json has no end_time
    (the app sets it when the recording stops) AND a WAV file or session.json itself was written within `window` seconds (the
    app refreshes the WAV headers every <= 5 s). A crashed recording (no end_time, files untouched for minutes) is NOT live: the
    pipeline may process it. Never raises."""
    d = Path(session_dir)
    if session is None:
        session = read_json(d / "session.json")
    if not isinstance(session, dict) or session.get("end_time"):
        return False
    now = time.time() if now is None else now
    newest = 0.0
    try:
        for entry in d.iterdir():
            if entry.name == "session.json" or entry.name.lower().endswith(".wav"):
                try:
                    newest = max(newest, entry.stat().st_mtime)
                except OSError:
                    continue
    except OSError:
        return False
    return newest > 0 and (now - newest) < window


def load_vocab_for(cfg: Config) -> Vocab:
    for path in (Path(cfg.vocab_path), Path(cfg.repo_config_dir) / "vocabulary.txt"):
        if path.is_file():
            return load_vocab(path)
    return Vocab()


def decode_audio_16k(path: Path):
    """Any audio file macOS can read (wav, m4a, mp3, caf ...) -> float32 mono 16 kHz numpy array (transcribe-file).
    A 16 kHz WAV is read directly (the lenient reader also repairs broken headers); everything else goes through afconvert
    (no ffmpeg)."""
    from . import audioprep, wavio
    path = Path(path)
    try:
        samples, rate = wavio.read_wav_lenient(path)
        if rate == 16000:
            return samples
    except (wavio.WavError, OSError, ValueError):
        pass
    with tempfile.TemporaryDirectory(prefix="mcap-decode-") as tmp:
        out = Path(tmp) / "decoded.wav"
        try:
            audioprep.decode_to_wav(path, out, sample_rate=16000)
            samples, _rate = wavio.read_wav_lenient(out)
        except (audioprep.AfconvertError, wavio.WavError, OSError, ValueError) as exc:
            raise RuntimeError(f"cannot decode {path.name}: {exc}") from exc
    return samples


# ---------------------------------------------------------------------------------- the run
@dataclass
class NoteFailure:
    kind: str
    message: str
    retryable: bool = True
    resets_at: Optional[int] = None
    warning: str = ""


class _Run:
    def __init__(self, session_dir: Path, cfg: Config, session: dict, deps: Deps, force: bool,
                 from_stage: Optional[str], allow_overage: bool, privacy: Optional[lanes.RunPrivacy] = None):
        self.dir = session_dir
        self.cfg = cfg
        self.session = session
        self.deps = deps
        self.allow_overage = allow_overage
        self.privacy = privacy if privacy is not None else lanes.resolve_run(cfg, session, session_dir)
        self.force_from = STAGES.index(from_stage) if from_stage else (0 if force else None)
        self.in_archive = _is_within(session_dir, Path(cfg.archive_dir)) or _in_local_archive(session_dir, cfg)
        self.vocab = load_vocab_for(cfg)
        self.transcript: dict = {}
        self.duration: Optional[float] = None
        self.start = publish.session_start(session, session_dir)
        self.current = "audio"
        self.warnings: list[str] = []
        self.t_start = time.time()
        self.prev_attempts = 0
        self.cleaned_md: Optional[str] = None       # text of a VALID transcript.cleaned.md (input of the note) or None
        self.cal_data: Optional[dict] = None
        self._ready: Optional[note.Readiness] = None
        self._note_backed_up = False
        self._last_progress = 0.0
        self.cleanup_note: Optional[str] = None     # why the note was written from the raw transcript (footer), None = cleaned or n/a
        self.note_fresh = False                     # the note was written by THIS run
        self.budget: Optional[usage.CallBudget] = None

    # ---- paths / predicates
    @property
    def transcript_json(self) -> Path:
        return self.dir / "transcript.json"

    @property
    def transcript_md(self) -> Path:
        return self.dir / "transcript.md"

    @property
    def cleaned_json(self) -> Path:
        return self.dir / cleanup.CLEANED_JSON

    @property
    def cleaned_md_path(self) -> Path:
        return self.dir / cleanup.CLEANED_MD

    @property
    def note_path(self) -> Path:
        return self.dir / "meeting-note.md"

    def forced(self, stage: str) -> bool:
        return self.force_from is not None and STAGES.index(stage) >= self.force_from

    def asr_done(self) -> bool:
        data = read_json(self.transcript_json)
        try:
            return isinstance(data, dict) and isinstance(data.get("segments"), list) and self.transcript_md.stat().st_size > 0
        except OSError:
            return False

    def note_done(self) -> bool:
        try:
            text = self.note_path.read_text(encoding="utf-8")
        except OSError:
            return False
        return bool(text.strip()) and not note.missing_headings(text)

    def state(self, **fields: Any) -> dict:
        return write_state(self.dir, **fields)

    def add_warning(self, text: str) -> None:
        text = _one_line(text, 300)
        if text and text not in self.warnings:
            self.warnings.append(text)
            self.state(warning="; ".join(self.warnings))

    def privacy_fields(self) -> dict:
        """What this run adds to state.json for a restricted meeting or a policy-managed Mac (local_only, local_only_source, lanes, asr);
        {} for the personal default, so that state.json is what it always was. Never raises."""
        try:
            return self.privacy.state_fields()
        except Exception:
            log.debug("privacy state fields unavailable", exc_info=True)
            return {}

    def lane_skipped(self, lane: str, what: str) -> bool:
        """True when `lane` is closed for this meeting right now (local-only, the organisation, an unreadable session.json): `what` is
        skipped. Asked BEFORE self.ready(), a budget, a process or a Keychain read. A skip is not a failure and not a warning: state.json
        `lanes` and the Privacy line say it."""
        block = self.privacy.lane_block(lane)
        if block is None:
            return False
        log.info("%s skipped: %s", what, block.message)
        return True

    def llm_denied_below(self) -> None:
        """A function below the stages answered `lane_denied` although the lane decision allows the lane (the claude binary does not match
        the policy's signature pin): ask `note.llm_block` for the reason (the pin check is cached for the run) and let the run say so."""
        try:
            block = note.llm_block(self.cfg)
            if block is not None:
                self.privacy.record_denial(block.lane, block.reason)
        except Exception:
            log.debug("could not record the lane denial", exc_info=True)

    def ready(self) -> "note.Readiness":
        """Readiness (overage marker, CLI, subscription login), checked once per run and shared by cleanup / note / verify."""
        if self._ready is None:
            self._ready = self.deps.check_ready(self.cfg, self.allow_overage)
        return self._ready

    # ---- orchestration
    def run(self) -> PipelineResult:
        """One run = one Claude call budget (MAX_CLAUDE_CALLS_PER_MEETING) and one usage.jsonl session id."""
        key = str(self.session.get("session_id") or self.dir.name)
        self.budget = usage.CallBudget(usage.effective_cap(self.cfg),
                                       usage.planned_reserve(calendar=calendar_lookup.enabled(self.cfg), verify=self.cfg.note_verify),
                                       session_id=key)
        with lanes.run_scope(self.privacy), usage.meeting(key, self.budget):
            return self._run()

    def _run(self) -> PipelineResult:
        log.info("processing %s (force_from=%s, in_archive=%s, claude call cap %d, billing %s)", self.dir,
                 STAGES[self.force_from] if self.force_from is not None else None, self.in_archive,
                 self.budget.limit if self.budget else 0, apikey.mode(self.cfg))
        try:
            previous = read_json(self.dir / "state.json")
            try:
                self.prev_attempts = int((previous or {}).get("attempts") or 0) if isinstance(previous, dict) else 0
            except (TypeError, ValueError):
                self.prev_attempts = 0
            fields: dict = {}
            if isinstance(previous, dict) and previous.get("stage") in MID_STAGES:
                # the run before this one died (kill -9, power loss, the app's stall watchdog): that was a failed attempt, so a
                # session that keeps killing its process runs into the sweep's attempt limit instead of looping forever
                self.prev_attempts += 1
                fields["attempts"] = self.prev_attempts
            self.state(stage="queued", warning=None, **fields, **self.privacy_fields())
            if not self.in_archive and self.privacy.restricted():
                publish.exclude_from_backup(self.cfg.sessions_dir)       # a restricted meeting's audio must not leave through a backup
            publish.sweep_temp_files(self.dir)          # `.prep-*` / `*.part` of a run that was killed
            self.stage_transcript()
            if self.should_discard():
                return self.discard()
            self.soft(self.stage_cleanup, "transcript cleanup",
                      lambda exc: self.skip_cleanup(f"{type(exc).__name__}: {_one_line(exc, 100)}", warn=False))
            failure = self.stage_note()
            if failure is None:
                self.soft(self.stage_verify, "note verification")
            return self.stage_publish(failure)
        except StageError as exc:
            return self.fail(exc)
        except Exception as exc:        # a bug must not look like success or crash the launcher; the audio is intact
            log.exception("unexpected error in stage %s", self.current)
            return self.fail(StageError(self.current, f"{self.current}: {type(exc).__name__}: {_one_line(exc)}",
                                        kind=f"{self.current}_error"))

    def soft(self, stage: Callable[[], None], label: str, on_error: Optional[Callable[[Exception], None]] = None) -> None:
        """Run an optional quality pass: whatever goes wrong in it is only a warning (the pipeline goes on with the raw
        transcript / the draft note)."""
        try:
            stage()
        except Exception as exc:
            log.exception("%s crashed", label)
            self.add_warning(f"{label} skipped: {type(exc).__name__}: {_one_line(exc, 150)}")
            if on_error:
                try:
                    on_error(exc)
                except Exception:
                    log.debug("on_error of %s failed", label, exc_info=True)

    def fail(self, exc: StageError) -> PipelineResult:
        log.error("FAILED in stage %s: %s", exc.stage, exc.message)
        self.state(stage="failed", error=exc.message, error_kind=exc.kind, retryable=exc.retryable,
                   resets_at=_iso_epoch(exc.resets_at), attempts=self.prev_attempts + (0 if exc.kind in WAITING_KINDS else 1),
                   **self.privacy_fields())
        return PipelineResult(False, "failed", self.dir, exc.message, exc.kind, exc.retryable,
                              warning="; ".join(self.warnings) or None)

    # ---- audio + asr -> transcript.json / transcript.md
    def progress(self, message: str) -> None:
        now = time.monotonic()
        if now - self._last_progress >= PROGRESS_MIN_INTERVAL:
            self._last_progress = now
            self.state(stage="transcribing", stage_detail=_one_line(message, 80), done={"audio": True})

    def early_title(self) -> str:
        cal = read_json(self.dir / calendar_lookup.CALENDAR_FILE)
        title, _src = publish.resolve_title((cal or {}).get("title") if isinstance(cal, dict) else None,
                                            self.session.get("title_hint"), None, self.session.get("platform_label"))
        return title

    def recorded_nothing(self) -> bool:
        """A finished session (end_time set) whose recorder produced no track and left no audio file behind. Never true for a
        published meeting, a session still being recorded, or one whose files exist but are unreadable (that stays a failure)."""
        if self.in_archive or (self.force_from is not None and self.force_from >= STAGES.index("cleanup")):
            return False
        if self.session.get("tracks") or not self.session.get("end_time"):
            return False
        try:
            return not any(p.suffix.lower() in (".wav", ".m4a") for p in self.dir.iterdir())
        except OSError:
            return False

    def stage_transcript(self) -> None:
        if not self.forced("asr") and self.asr_done():
            log.info("transcript exists: skipping audio + asr")
            self.transcript = read_json(self.transcript_json) or {}
            self.state(done={"audio": publish.audio_archived_ok(self.dir, self.session)[0] or self.in_archive, "asr": True})
            return
        if self.recorded_nothing():
            # the recorder ran but neither track ever delivered a frame: session.json lists no tracks and no audio file exists.
            # Nothing to retry and nothing to keep, so an empty transcript, which the no-speech rule discards (not a failure)
            log.info("the recorder wrote no audio at all (session.json lists no tracks): nothing to transcribe")
            self.transcript = {"segments": []}
            return
        if self.privacy.asr.blocked:
            # SPEC 18: this Mac cannot run the local engine and no external engine may be used (local-only, the policy, no
            # consent): nothing could transcribe it. The audio stays, nothing is retried by itself (`mcap reprocess <folder>` works by hand).
            self.current = "asr"
            raise StageError("asr", "transcription blocked: this Mac cannot run the local engine and no external engine is allowed "
                                    f"({self.privacy.asr.reason}); the audio is kept (mcap reprocess <folder> to try again by hand)",
                             retryable=False, kind="asr_policy_blocked")
        self.current = "audio"
        self.state(stage="audio")
        try:
            # audioprep also copes with an already published meeting: no WAVs left -> it decodes the archived m4a files
            prepared = self.deps.prepare_audio(self.dir, self.session, force=self.forced("audio"))
        except Exception as exc:
            log.exception("audio stage failed")
            raise StageError("audio", f"audio: {_one_line(exc)}") from exc
        self.duration = getattr(prepared, "duration_sec", None)
        self.state(done={"audio": True})

        self.current = "asr"
        self.state(stage="transcribing", stage_detail=None)
        try:
            transcript = self.deps.transcribe_tracks(prepared, self.privacy.cfg_for_asr(self.cfg), self.vocab, self.progress)
            if not isinstance(transcript, dict) or not isinstance(transcript.get("segments"), list):
                raise ValueError("ASR returned no segment list")
            policy_block = self.privacy.transcript_policy_block()       # None for the personal default: transcript.json gets no new key
            if policy_block is not None:
                transcript["policy"] = policy_block
            md = self.deps.render_markdown(transcript, self.transcript_meta(transcript))
            if not isinstance(md, str) or not md.strip():
                raise ValueError("empty transcript.md")
        except Exception as exc:
            log.exception("transcription failed")
            if _is_unreachable(exc):         # the external ASR server could not be reached at all: wait for it, do not call it a failed meeting
                raise StageError("asr", f"transcription server unreachable: {_one_line(exc)}", kind="asr_unreachable") from exc
            hint = " (run scripts/setup_python.sh)" if isinstance(exc, ImportError) else ""
            raise StageError("asr", f"transcription failed: {_one_line(exc)}{hint}") from exc
        # transcript first (atomic + fsync), only then does anything else happen
        atomic_write_json(self.transcript_json, transcript)
        atomic_write_text(self.transcript_md, md)
        self.transcript = transcript
        self.drop_cleaned()          # a cleaned copy of the PREVIOUS transcript must never sit next to the new raw one
        self.state(done={"asr": True})
        log.info("transcript saved: %d segments", len(transcript["segments"]))

    def transcript_meta(self, transcript: dict) -> dict:
        start = self.start
        return {
            "title": self.early_title(),
            "date": f"{start:%Y-%m-%d}" if start else "",
            "platform_label": self.session.get("platform_label") or self.session.get("platform") or "",
            "start_time": self.session.get("start_time"),
            "duration_sec": self.duration if self.duration is not None else self.session_duration(),
            "asr_model": transcript.get("asr_model") or self.cfg.asr_model,
        }

    def session_duration(self) -> Optional[float]:
        end = publish.parse_iso(self.session.get("end_time"))
        if self.start and end and end > self.start:
            return (end - self.start).total_seconds()
        segs = (self.transcript or {}).get("segments") or []
        try:
            return max(float(s.get("end", 0)) for s in segs) if segs else None
        except (TypeError, ValueError):
            return None

    # ---- no speech -> discard
    def speech_seconds(self) -> float:
        total = 0.0
        for seg in (self.transcript or {}).get("segments") or []:
            try:
                total += max(0.0, float(seg.get("end", 0)) - float(seg.get("start", 0)))
            except (TypeError, ValueError):
                continue
        return total

    def should_discard(self) -> bool:
        if self.in_archive or (self.force_from is not None and self.force_from >= STAGES.index("cleanup")):
            return False
        return self.speech_seconds() < DISCARD_SPEECH_SECONDS

    def discard(self) -> PipelineResult:
        log.info("no speech (%.1f s < %.0f s): discarding session", self.speech_seconds(), DISCARD_SPEECH_SECONDS)
        self.state(stage="done", discarded=True, title=None, final_dir=None,
                   done={"audio": True, "asr": True, "note": False, "publish": False})
        try:
            parked = publish.discard_session(self.dir, self.cfg)
        except publish.PublishError as exc:
            raise StageError("publish", f"discard: {_one_line(exc)}") from exc
        stub = read_state(parked)
        stub["discarded_dir"] = str(parked)
        publish.leave_tombstone(self.dir, stub)
        return PipelineResult(True, "done", None, discarded=True)

    # ---- transcript cleanup (TRANSCRIPT_CLEANUP): transcript.cleaned.json / .md, raw is never touched
    def drop_cleaned(self) -> None:
        for path in (self.cleaned_json, self.cleaned_md_path):
            try:
                path.unlink()
            except OSError:
                pass

    def cleanup_progress(self, done: int, total: int) -> None:
        self.state(stage="noting", stage_detail=f"cleaning transcript {done}/{total}")

    def skip_cleanup(self, reason: str, warn: bool = True, drop: bool = True) -> None:
        """The note will be written from the raw transcript: remember why (the footer says so) and warn."""
        self.cleaned_md = None
        self.cleanup_note = f"cleanup not applied: {_one_line(reason, 100)}"
        if warn:
            self.add_warning(f"transcript cleanup skipped: {_one_line(reason, 200)}")
        if drop:
            self.drop_cleaned()

    def stage_cleanup(self) -> None:
        self.cleaned_md = None
        self.cleanup_note = None
        if not self.cfg.transcript_cleanup:
            self.cleanup_note = "cleanup not applied: disabled (TRANSCRIPT_CLEANUP=0)"
            return
        self.current = "cleanup"
        try:
            sha = cleanup.sha256_of(self.transcript_json.read_bytes())
        except OSError:
            return
        existing = read_json(self.cleaned_json)
        if not self.forced("cleanup") and cleanup.is_valid_cleaned(existing, sha):
            try:
                text = self.cleaned_md_path.read_text(encoding="utf-8")
            except OSError:
                text = ""
            if text.strip():
                log.info("valid transcript.cleaned.md exists: skipping cleanup")
                self.cleaned_md = text
                self.state(done={"cleanup": True})
                return
        if self.lane_skipped("llm", "transcript cleanup"):
            self.skip_cleanup("llm lane closed", warn=False)
            return
        ready = self.ready()
        if not ready.ok:
            log.warning("transcript cleanup skipped: %s", ready.error)
            if ready.kind == "lane_denied":
                self.llm_denied_below()
            self.skip_cleanup(ready.error, warn=ready.kind != "lane_denied")
            return
        blocked = usage.budget_block(self.cfg, "cleanup")        # api mode: a USD budget is used up (checked again before every call)
        if blocked:
            log.warning("transcript cleanup skipped: %s", blocked.message)
            self.skip_cleanup(blocked.message)
            return
        self.state(stage="noting", stage_detail="cleaning transcript")
        transcript = read_json(self.transcript_json) or self.transcript
        try:
            res = self.deps.cleanup_transcript(transcript, self.cfg, self.vocab, meta=self.transcript_meta(transcript),
                                               render=self.deps.render_markdown, source_sha256=sha,
                                               progress=self.cleanup_progress, allow_overage=self.allow_overage)
        except Exception as exc:       # fail-soft by design
            log.exception("transcript cleanup crashed")
            res = cleanup.CleanupResult(False, error_kind="internal", error=f"{type(exc).__name__}: {_one_line(exc)}")
        if res.warning:
            self.add_warning(res.warning)
        if not res.ok or not res.transcript or not res.markdown.strip():
            log.warning("transcript cleanup skipped: %s", res.error)
            if res.error_kind == "lane_denied":
                self.llm_denied_below()
            self.skip_cleanup(res.error or "no result", warn=res.error_kind != "lane_denied")      # the lane closed meanwhile: a skip, no warning
            return
        try:
            atomic_write_json(self.cleaned_json, res.transcript)
            atomic_write_text(self.cleaned_md_path, res.markdown)
        except OSError as exc:
            self.add_warning(f"transcript cleanup not saved: {_one_line(exc, 120)}")
            self.skip_cleanup(f"not saved: {_one_line(exc, 80)}", warn=False)
            return
        self.cleaned_md = res.markdown
        st = res.stats
        if st.get("batches_failed"):
            self.add_warning(f"transcript cleanup partial: {st.get('batches_failed')}/{st.get('batches')} batches failed "
                             "(those parts of the cleaned transcript are raw)")
            self.cleanup_note = f"cleanup partial: {st.get('batches_failed')}/{st.get('batches')} batches not cleaned, those parts are raw"
        self.state(done={"cleanup": True}, cleanup={k: st.get(k) for k in ("batches", "batches_failed", "changed", "rejected")})
        log.info("transcript cleaned: %s changed, %s rejected", st.get("changed"), st.get("rejected"))

    def note_input(self) -> tuple[str, str]:
        """(text for the note, 'cleaned' | 'raw'): the cleaned transcript when a valid one exists, else the raw transcript."""
        raw = self.transcript_md.read_text(encoding="utf-8")
        if self.cleaned_md and self.cleaned_md.strip():
            return self.cleaned_md, "cleaned"
        return raw, "raw"

    # ---- calendar + note
    def calendar(self) -> Optional[dict]:
        path = self.dir / calendar_lookup.CALENDAR_FILE
        cached = read_json(path)
        relookup = self.force_from is not None and self.force_from <= STAGES.index("asr")
        if isinstance(cached, dict) and cached.get("matched") and not relookup:
            return cached
        if not calendar_lookup.enabled(self.cfg):
            return None
        if self.lane_skipped("calendar", "calendar lookup"):
            return None                              # the title is the window title / platform name; the Privacy line says it
        blocked = usage.budget_block(self.cfg, "calendar")
        if blocked:
            self.add_warning(f"calendar lookup skipped: {blocked.message}; the window title / platform name is used")
            return None
        self.state(stage="noting", stage_detail="calendar lookup")
        try:
            match = self.deps.lookup_calendar(self.cfg, self.session, session_dir=self.dir)
        except calendar_lookup.CalendarOverage:
            raise                        # surfaced on purpose: the guard must stop the note call that would follow
        except Exception as exc:      # best effort by design
            log.info("calendar lookup failed: %s", type(exc).__name__)
            return None
        if self.budget is not None and self.budget.denied.get("calendar"):
            self.add_warning("calendar lookup skipped: claude call cap reached "
                             f"(MAX_CLAUDE_CALLS_PER_MEETING={self.budget.limit}); the window title / platform name is used")
        if not match:
            return None
        data = match.to_dict()
        try:
            atomic_write_json(path, data)
        except OSError as exc:
            log.warning("cannot save calendar.json: %s", exc)
        return data

    def cached_calendar(self) -> Optional[dict]:
        cached = read_json(self.dir / calendar_lookup.CALENDAR_FILE)
        return cached if isinstance(cached, dict) and cached.get("matched") else None

    def make_meta(self, cal: Optional[dict], kind: str) -> dict:
        meta = note.note_meta(self.session, cal, self.duration if self.duration is not None else self.session_duration(),
                              (self.transcript or {}).get("asr_model") or self.cfg.asr_model, self.cfg, self.start)
        meta["transcript_kind"] = kind
        meta["cleanup_note"] = self.cleanup_note
        return meta

    def stage_note(self) -> Optional[NoteFailure]:
        if not self.forced("note") and self.note_done():
            log.info("meeting-note.md exists: skipping note")
            self.state(done={"note": True})
            return None
        self.current = "note"
        if self.lane_skipped("llm", "meeting note"):
            self.state(done={"note": False})
            return None                              # no note, no failure: the transcript is all this meeting produces
        self.state(stage="noting", stage_detail="creating note")
        try:
            transcript_md, kind = self.note_input()
        except OSError as exc:
            raise StageError("note", f"note: cannot read transcript.md: {_one_line(exc)}") from exc
        try:
            return self.generate_and_save_note(transcript_md, kind)
        except Exception as exc:      # a bug here must not stop the transcript from being published
            log.exception("unexpected error in the note stage")
            return self.note_failed(NoteFailure("internal", f"{type(exc).__name__}: {_one_line(exc)}"))

    def overage_failure(self) -> Optional[NoteFailure]:
        """The overage guard, evaluated NOW (a calendar lookup or a cleanup batch may have written the marker since the
        readiness check at the start of the run)."""
        block = note.overage_block(self.cfg, self.allow_overage)
        if block:
            return NoteFailure(block.kind, block.error, block.retryable, block.resets_at)
        return None

    def note_lane_skipped(self, message: str) -> None:
        """The llm lane closed while the note stage was running (the flag was switched on, the gate could not read session.json): the
        note is skipped like at the start, not failed."""
        log.info("meeting note skipped: %s", message)
        self.state(done={"note": False})
        return None

    def generate_and_save_note(self, transcript_md: str, kind: str = "raw") -> Optional[NoteFailure]:
        if self.lane_skipped("llm", "meeting note"):
            return self.note_lane_skipped("llm lane closed")
        ready = self.ready()
        if not ready.ok:
            if ready.kind == "lane_denied":
                self.llm_denied_below()
                return self.note_lane_skipped(ready.error)
            return self.note_failed(NoteFailure(ready.kind, ready.error, ready.retryable, ready.resets_at))
        blocked = self.overage_failure()
        if blocked:
            return self.note_failed(blocked)
        money = usage.budget_block(self.cfg, "note")             # api mode: the DAILY budget stops the note too (the meeting budget never does)
        if money:
            return self.note_failed(NoteFailure(money.kind, money.message, True, money.resets_at))
        try:
            cal = self.calendar()
        except calendar_lookup.CalendarOverage:
            return self.note_failed(self.overage_failure() or NoteFailure(
                "overage_guard", "Claude started extra-usage (overage) billing during the calendar lookup; note skipped, "
                "transcript kept (mcap reprocess --allow-overage to force)"))
        self.cal_data = cal
        blocked = self.overage_failure()        # the lookup may have recorded an overage (e.g. through a stubbed collaborator)
        if blocked:
            return self.note_failed(blocked)
        marker = overage.read_marker(self.cfg)
        if marker and marker.get("source") == "calendar" and int(marker.get("detected_epoch") or 0) >= int(self.t_start):
            self.add_warning("Claude reported extra-usage (overage) billing during the calendar lookup; allowed "
                             "(NOTE_STOP_ON_OVERAGE=0)")
        meta = self.make_meta(cal, kind)
        self.state(stage="noting", stage_detail="creating note", note_transcript=kind)
        result = self.deps.generate_note(transcript_md, meta, self.cfg, self.vocab, allow_overage=self.allow_overage,
                                         ready=ready)
        if result.warning:
            self.add_warning(result.warning)
        if not result.ok and result.error_kind == "lane_denied":
            self.llm_denied_below()
            return self.note_lane_skipped(result.error)
        if not result.ok:
            return self.note_failed(NoteFailure(result.error_kind, result.error, result.retryable, result.resets_at,
                                                result.warning))
        title, source = publish.resolve_title((cal or {}).get("title"), self.session.get("title_hint"),
                                              note.note_h1(result.text), self.session.get("platform_label"))
        try:
            text = note.finish_note(result, meta, self.cfg, title if source != "note" else None)
        except Exception:
            log.exception("could not normalise the note header; saving the model output as is")
            text = result.text.rstrip() + "\n"
        self.write_note(text)
        self.note_fresh = True
        self.state(done={"note": True}, title=title)
        log.info("meeting note saved (%d chars, model %s, transcript %s)", len(text), result.model or "?", kind)
        return None

    def note_failed(self, failure: NoteFailure) -> NoteFailure:
        log.error("note failed (%s): %s", failure.kind, failure.message)
        return failure

    def write_note(self, text: str) -> None:
        """Atomic write of meeting-note.md. The note that was there before THIS run is kept once as meeting-note.prev.md (a
        reprocess must not destroy a hand-edited or earlier good note); the verified note replacing the draft of the same run
        does not touch the backup."""
        if not self._note_backed_up:
            self._note_backed_up = True
            try:
                old = self.note_path.read_text(encoding="utf-8")
                if old.strip() and old != text:
                    atomic_write_text(self.dir / NOTE_BACKUP, old)
                    log.info("previous note kept as %s", NOTE_BACKUP)
            except OSError:
                pass
        atomic_write_text(self.note_path, text)

    # ---- note verification (NOTE_VERIFY)
    def stage_verify(self) -> None:
        """Fact-check the draft note. Whatever happens the final note is honest about it: verified (footer comment with the counts), or
        marked `Verification: not applied (<reason>)` under the H1 and in the footer (rejected, failed, skipped by the call cap /
        the extra-usage guard / a crash / NOTE_VERIFY=0), so an unverified note is never mistaken for a verified one."""
        try:
            self._stage_verify()
        except Exception as exc:
            log.exception("note verification crashed")
            self.add_warning(f"note verification skipped: {type(exc).__name__}: {_one_line(exc, 150)}")
            try:
                self.verify_not_applied(self.note_path.read_text(encoding="utf-8"), f"internal error: {type(exc).__name__}: "
                                        f"{_one_line(exc, 100)}", warn=False)
            except Exception:
                log.debug("could not mark the note as unverified", exc_info=True)

    def _stage_verify(self) -> None:
        try:
            current = self.note_path.read_text(encoding="utf-8")
        except OSError:
            return
        if note.missing_headings(current):
            return                                    # not a complete note: nothing to verify
        if not self.cfg.note_verify:
            if self.note_fresh:                       # only the note this run wrote (an older / hand-edited note is left alone)
                self.write_marked(current, verify.DISABLED_REASON)
            return
        if not self.forced("verify") and verify.has_verification(current):
            log.info("note already went through verification: skipping")
            self.state(done={"verify": True})
            return
        self.current = "verify"
        draft_path = self.dir / verify.DRAFT_FILE
        draft = current
        if self.forced("verify") and not self.forced("note"):
            try:                                        # re-verify the ORIGINAL draft, not the already verified note
                draft = draft_path.read_text(encoding="utf-8")
            except OSError:
                pass
        draft = self.unmarked(draft)                    # a status line / verification comment of an earlier run is not part of the draft
        block = self.privacy.lane_block("llm")
        if block is not None:                           # BEFORE self.ready(): a closed lane starts nothing; the note says it was not verified
            log.info("note verification skipped: %s", block.message)
            self.verify_not_applied(draft, f"llm lane closed: {block.reason}", warn=False)
            return
        ready = self.ready()
        if not ready.ok:
            if ready.kind == "lane_denied":
                self.llm_denied_below()
            self.verify_not_applied(draft, ready.error, warn=ready.kind != "lane_denied")
            return
        blocked = self.overage_failure()
        if blocked:
            self.verify_not_applied(draft, blocked.message)
            return
        money = usage.budget_block(self.cfg, "verify")           # api mode: a USD budget is used up
        if money:
            self.verify_not_applied(draft, money.message)
            return
        try:
            raw_md = self.transcript_md.read_text(encoding="utf-8")
        except OSError as exc:
            self.verify_not_applied(draft, f"cannot read transcript.md: {_one_line(exc, 80)}")
            return
        cal = self.cal_data if self.cal_data is not None else self.cached_calendar()
        meta = self.make_meta(cal, "cleaned" if self.cleaned_md else "raw")
        self.state(stage="noting", stage_detail="verifying note")
        try:
            res = self.deps.verify_note(draft, raw_md, self.cleaned_md, meta, self.cfg, self.vocab,
                                        allow_overage=self.allow_overage)
        except Exception as exc:        # fail-soft by design
            log.exception("note verification crashed")
            res = verify.VerifyResult(False, error_kind="internal", error=f"{type(exc).__name__}: {_one_line(exc, 150)}")
        if res.warning:
            self.add_warning(res.warning)
        if not res.ok:
            if res.error_kind == "lane_denied":
                self.llm_denied_below()
            self.verify_not_applied(draft, res.error or res.error_kind or "no result", warn=res.error_kind != "lane_denied")
            return
        try:
            atomic_write_text(draft_path, draft.rstrip() + "\n")
        except OSError as exc:
            log.warning("cannot save %s: %s", verify.DRAFT_FILE, exc)
        self._note_backed_up = True       # the draft is kept as meeting-note.draft.md: it must not replace a real .prev.md
        self.write_note(verify.set_status_line(res.text, None))      # a verified note carries no "not applied" line, whoever wrote the text
        self.state(done={"verify": True}, verify=res.stats)

    @staticmethod
    def unmarked(text: str) -> str:
        """`text` without the `Verification: ...` status line under the H1 and without verification comments in the footer."""
        body, footers = verify.split_footer(text)
        footers = verify.without_verification(footers)
        return verify.set_status_line(body, None).rstrip() + ("\n\n" + "\n".join(footers) if footers else "") + "\n"

    @staticmethod
    def marked_note(draft: str, reason: str) -> str:
        """`draft` with the visible `Verification: not applied (<reason>)` line under the H1 and the same in the footer comment (an
        earlier verification comment is replaced, never stacked)."""
        body, footers = verify.split_footer(draft)
        footers = verify.without_verification(footers)
        body = verify.set_status_line(body, reason)
        return body.rstrip() + "\n\n" + "\n".join(footers + [verify.not_applied_footer(reason)]) + "\n"

    def write_marked(self, draft: str, reason: str) -> None:
        """Write the marked note. The note it replaces is the same text without the mark: no .prev.md backup for that."""
        text = self.marked_note(draft, reason)
        if text != draft:
            self._note_backed_up = True
            self.write_note(text)

    def verify_not_applied(self, draft: str, reason: str, warn: bool = True) -> None:
        """The draft stays the final note, marked as unverified (visible line + footer comment that record why, so the stage is not
        repeated on every run) and a state warning."""
        log.warning("note verification not applied: %s", reason)
        if warn:
            self.add_warning(f"note verification not applied: {_one_line(reason, 200)}")
        self.write_marked(draft, reason)
        try:
            (self.dir / verify.DRAFT_FILE).unlink()      # the final note IS the draft: no separate copy
        except OSError:
            pass
        self.state(done={"verify": False})

    # ---- publish
    def final_title(self) -> str:
        cal = read_json(self.dir / calendar_lookup.CALENDAR_FILE)
        note_title = None
        try:
            note_title = note.note_h1(self.note_path.read_text(encoding="utf-8"))
        except OSError:
            pass
        title, _src = publish.resolve_title((cal or {}).get("title") if isinstance(cal, dict) else None,
                                            self.session.get("title_hint"), note_title, self.session.get("platform_label"))
        return title

    def set_titles(self, title: str) -> None:
        """The `Meeting:` line of transcript.md (and of the cleaned copy): the title is only known now, and an in-place
        reprocess of an archived meeting (--from asr) regenerates transcript.md with the early title."""
        publish.set_transcript_title(self.transcript_md, title)
        if self.cleaned_md_path.is_file():
            publish.set_transcript_title(self.cleaned_md_path, title)

    def refresh_tombstone(self, stub: dict) -> None:
        """An archived meeting that was processed IN PLACE: bring the staging tombstone of its session (a directory holding only
        state.json, left by the first publish) up to date. Otherwise it keeps saying failed/retryable after the retry worked and
        every later sweep or `reprocess --pending` would process the finished meeting again."""
        key = str(self.session.get("session_id") or self.dir.name)
        staging = Path(self.cfg.sessions_dir) / key
        if staging == self.dir:
            return
        try:
            names = {p.name for p in staging.iterdir()}
        except OSError:
            return
        if names == {"state.json"}:
            publish.leave_tombstone(staging, stub)

    def publish_to_archive(self, title: str) -> Path:
        """Move the staging dir to the archive the lanes allow: ARCHIVE_DIR (Drive) while the drive lane is open, else the validated local
        archive. The drive lane is asked again by publish/move_dir right before anything is touched and right before the final rename: when
        it closes meanwhile (`publish.CommitBlocked`: the `.partial` copy is gone, the source untouched) the next round finds the lane closed
        and publishes to the local archive. LocalArchiveUnsafe: the local folder is not on the allow-list (never retried by itself)."""
        for _round in range(3):
            root, kind = self.privacy.archive_root()
            guard = (lambda: self.privacy.lane_block("drive")) if kind == "drive" else None
            try:
                return publish.publish(self.dir, self.cfg, title, self.session, archive_dir=root, before_commit=guard)
            except publish.CommitBlocked as exc:
                log.info("the drive lane closed during publishing (%s): publishing to the local archive instead", exc.reason)
        raise publish.PublishError("publishing was blocked again and again")

    def stage_publish(self, failure: Optional[NoteFailure]) -> PipelineResult:
        title = self.final_title()
        note_exists = self.note_path.is_file()
        done = {"audio": True, "asr": True, "note": note_exists, "publish": True}
        error = f"Note failed: {failure.message}" if failure else None
        if self.in_archive:
            final = self.dir
            self.set_titles(title)
        else:
            self.current = "publish"
            self.state(stage="publishing", title=title)
            self.set_titles(title)
            try:
                final = self.publish_to_archive(title)
            except lanes.LocalArchiveUnsafe as exc:
                raise StageError("publish", _one_line(exc), retryable=False, kind="local_archive_unsafe") from exc
            except publish.PublishError as exc:
                kind = "archive_unavailable" if isinstance(exc, publish.ArchiveUnavailable) else "publish_failed"
                raise StageError("publish", _one_line(exc), kind=kind) from exc
            self.privacy.rebind(final)
        if failure and failure.warning:
            self.add_warning(failure.warning)
        warning = "; ".join(self.warnings) or None
        final_state = {"title": title, "final_dir": str(final), "done": done, "discarded": False, "warning": warning,
                       **self.privacy_fields()}
        if failure:
            final_state.update(stage="failed", error=error, error_kind=failure.kind, retryable=failure.retryable,
                               resets_at=_iso_epoch(failure.resets_at),
                               attempts=self.prev_attempts + (0 if failure.kind in WAITING_KINDS else 1))
        else:
            final_state.update(stage="done", attempts=0)
        stub = write_state(final, **final_state)
        if not failure and not self.privacy.keeps_state():
            remove_state(final)          # a clean archive folder carries no state file (a restricted one keeps it: SPEC 18)
        if not self.in_archive:
            publish.leave_tombstone(self.dir, stub)
        else:
            self.refresh_tombstone(stub)
        if failure:
            log.error("FAILED: %s (transcript kept: %s)", error, final)
            return PipelineResult(False, "failed", final, error, failure.kind, failure.retryable, published=True, title=title,
                                  warning=warning)
        log.info("DONE: %s", final)
        return PipelineResult(True, "done", final, published=True, title=title, warning=warning)


def _iso_epoch(epoch: Optional[int]) -> Optional[str]:
    if not epoch:
        return None
    try:
        return datetime.fromtimestamp(float(epoch)).astimezone().isoformat(timespec="seconds")
    except (OverflowError, OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------- public API
def _tombstone_result(state: dict) -> Optional[PipelineResult]:
    """A staging dir that only holds the state.json tombstone of a finished (or discarded) session: nothing left to process."""
    if not isinstance(state, dict) or state.get("stage") != "done":
        return None
    final = state.get("final_dir")
    return PipelineResult(True, "done", Path(final) if final else None, discarded=bool(state.get("discarded")),
                          published=bool(final), title=state.get("title"), skipped=True)


def process_session(session_dir: Path, cfg: Config, force: bool = False, from_stage: Optional[str] = None, *,
                    allow_overage: bool = False, deps: Optional[Deps] = None, only_if_pending: bool = False,
                    privacy_inputs: Optional[lanes.PrivacyInputs] = None) -> PipelineResult:
    """Run (or resume) the pipeline for one session dir (staging or an already archived meeting folder).
    Raises SessionBusy if another process holds the session lock or the session is still being recorded; every other problem
    ends as a failed state, not a crash.

    only_if_pending (the retry sweep, `reprocess --pending`): look at the session AGAIN once the lock is held and do nothing
    (result.skipped) unless it still needs work (failed + retryable and due, or left in a mid-stage state by a run that died).
    A normal run may have finished it between the scan and now; that run's tombstone / state is never overwritten.

    privacy_inputs (SPEC 18, tests and e2e runs): what `lanes.resolve_run` reads from the outside (an injected organisation policy, consents,
    a hardware verdict, a clock); None = everything is loaded the normal way."""
    session_dir = Path(session_dir)
    if from_stage is not None and from_stage not in STAGES:
        raise ValueError(f"from_stage must be one of {', '.join(STAGES)}")
    session = read_json(session_dir / "session.json")
    if not isinstance(session, dict):
        state = read_json(session_dir / "state.json")
        done = _tombstone_result(state)
        if done is not None:                          # published/discarded meanwhile: the tombstone stays as it is
            log.info("%s was finished by another run", session_dir.name)
            return done
        if only_if_pending and not session_dir.exists():     # moved away by a normal run's publish between the scan and now
            log.info("%s is gone (published or discarded by another run)", session_dir.name)
            return PipelineResult(True, "done", None, skipped=True)
        msg = "session.json is missing or unreadable"
        if session_dir.is_dir() and not (isinstance(state, dict) and (state.get("final_dir") or state.get("discarded"))):
            write_state(session_dir, stage="failed", error=msg, retryable=False)
        log.error("FAILED: %s: %s", session_dir, msg)
        return PipelineResult(False, "failed", session_dir, msg)
    if is_live_recording(session_dir, session):
        raise SessionBusy(f"session {session_dir.name} is still being recorded (no end_time, files written within the last "
                          f"{int(LIVE_WINDOW_SECONDS)} s)")
    key = str(session.get("session_id") or session_dir.name)
    with session_lock(cfg, key):
        if only_if_pending:
            reason = pending_reason(cfg, read_json(session_dir / "state.json"))
            if reason is None:
                state = read_state(session_dir)
                log.info("%s needs no retry any more (state %s)", session_dir.name, state.get("stage"))
                return PipelineResult(state.get("stage") != "failed", str(state.get("stage")), session_dir,
                                      published=bool(state.get("final_dir")), title=state.get("title"), skipped=True)
        privacy = lanes.resolve_run(cfg, session, session_dir, inputs=privacy_inputs)
        return _Run(session_dir, cfg, session, (deps or Deps()).resolved(), force, from_stage, allow_overage, privacy).run()


def is_complete(session_dir: Path) -> bool:
    """True if this directory already holds a finished meeting (transcript + valid note, and no failed state). SPEC 18: a finished
    RESTRICTED folder is complete without a note: state.json says done and the note lane was skipped (local-only, or the organisation
    denied it), so `mcap reprocess <folder>` does not try to make one (--from note / --force still do)."""
    d = Path(session_dir)
    state = read_json(d / "state.json")
    if isinstance(state, dict) and state.get("stage") == "failed":
        return False
    try:
        text = (d / "meeting-note.md").read_text(encoding="utf-8")
    except OSError:
        return (isinstance(state, dict) and state.get("stage") == "done" and (d / "transcript.md").is_file()
                and str((state.get("lanes") or {}).get("llm", "")).startswith("skipped"))
    return (d / "transcript.md").is_file() and not note.missing_headings(text)


# ---------------------------------------------------------------------------------- locating sessions (reprocess)
def resolve_session_path(path: Path) -> Optional[Path]:
    """A session dir as is; a staging tombstone (state.json only) redirects to its final_dir."""
    p = Path(path)
    if (p / "session.json").is_file():
        return p
    state = read_json(p / "state.json")
    final = state.get("final_dir") if isinstance(state, dict) else None
    if final and (Path(final) / "session.json").is_file():
        return Path(final)
    return None


def _stamp(name: str) -> str:
    m = _STAMP.match(name)
    return m.group(1) if m else ""


def find_last_session(cfg: Config) -> Optional[Path]:
    """Most recent session by start time (the YYYY-MM-DD_HHMM prefix shared by session ids and archive folder names),
    staging first, then ARCHIVE_DIR. Discarded sessions and sessions that are still being recorded are ignored."""
    candidates: dict[str, tuple[str, int, Path]] = {}
    sessions = Path(cfg.sessions_dir)
    if sessions.is_dir():
        for entry in sessions.iterdir():
            if entry.name.startswith("_") or not entry.is_dir():
                continue
            target = resolve_session_path(entry)
            stamp = _stamp(entry.name)
            if target and stamp and not is_live_recording(target):
                candidates[str(target)] = (stamp, 1, target)
    roots = [Path(cfg.archive_dir)]
    local = getattr(cfg, "local_archive_root", None)               # SPEC 18: the local archive of local-only meetings is searched too
    if local is not None and Path(local) != roots[0]:
        roots.append(Path(local))
    for archive in roots:
        try:
            months = sorted((m for m in archive.iterdir() if re.fullmatch(r"\d{4}-\d{2}", m.name) and m.is_dir()), reverse=True) \
                if archive.is_dir() else []
        except OSError:
            months = []
        for month in months:
            try:
                meetings = sorted((p for p in month.iterdir() if p.is_dir() and _MEETING_DIR.match(p.name)), reverse=True)
            except OSError:
                continue
            if meetings:
                top = meetings[0]
                candidates.setdefault(str(top), (_stamp(top.name), 0, top))
                break
    if not candidates:
        return None
    return max(candidates.values(), key=lambda t: (t[0], t[1], t[2].name))[2]


def pending_reason(cfg: Config, state, now: Optional[float] = None) -> Optional[str]:
    """Why a retry should process a session with this state.json content, or None when it should be left alone:
      * failed + retryable of ANY error kind (note failures, archive_unavailable, asr_failed, a stalled / killed job, ...), except a
        Claude usage limit before its reset time, a reached daily USD budget (api mode, `budget_daily`) before midnight (it is due
        again at once when the budget was raised or the mode changed), and an overage-guard failure while the guard is on and its
        marker valid;
      * a mid-stage state (queued / audio / transcribing / noting / publishing): the run that wrote it died without finishing.
        Whether that run is really dead is the caller's lock: process_session(only_if_pending=True) holds the session lock when
        it asks, find_pending_sessions only lists candidates."""
    if not isinstance(state, dict):
        return None
    now = time.time() if now is None else now
    stage = state.get("stage")
    if stage in MID_STAGES:
        return f"interrupted in stage '{stage}' (no process holds its lock)"
    if stage != "failed" or state.get("retryable") is not True:
        return None
    due = publish.parse_iso(state.get("resets_at"))
    if due is not None:
        if due.tzinfo is None:
            due = due.astimezone()
        if due.timestamp() > now:
            # a usage limit that has not reset yet. Exception: a daily USD budget (api mode) only waits for midnight because it was
            # reached; with a higher CLAUDE_DAILY_BUDGET_USD (or CLAUDE_AUTH=subscription) nothing is left to wait for, and the failure
            # message itself says "or a higher budget, then: mcap reprocess --pending".
            if not (state.get("error_kind") == usage.OUTCOME_BUDGET_DAILY and usage.budget_block(cfg, "note") is None):
                return None
    if state.get("error_kind") == "overage_guard" and cfg.note_stop_on_overage and overage.read_marker(cfg, now):
        return None
    return f"failed earlier ({state.get('error_kind') or 'unknown'})"


def pending_items(cfg: Config, now: Optional[float] = None, max_attempts: Optional[int] = None) -> list[tuple[Path, str]]:
    """(session dir, reason) of everything a retry can finish, oldest first: staging sessions and meetings that were published
    without a note (their staging tombstone points at them) that failed with a retryable error, and staging sessions left in a
    mid-stage state. Not listed: sessions still being recorded, failures whose Claude usage limit has not reset yet, an
    overage_guard failure while the guard is on and the marker is valid, and (with `max_attempts`) sessions that already failed
    that many runs. A listed session may still be busy (a run holds its lock) or finished by then: process_session(...,
    only_if_pending=True) decides under the lock."""
    now = time.time() if now is None else now
    found: list[tuple[str, Path, str]] = []
    sessions = Path(cfg.sessions_dir)
    if not sessions.is_dir():
        return []
    for entry in sorted(sessions.iterdir()):
        if entry.name.startswith("_") or not entry.is_dir() or entry.is_symlink():
            continue
        state = read_json(entry / "state.json")
        reason = pending_reason(cfg, state, now)
        if reason is None:
            continue
        target = resolve_session_path(entry)
        if target is None or is_live_recording(target):
            continue
        try:
            attempts = int(state.get("attempts") or 0)
        except (TypeError, ValueError):
            attempts = 0
        if max_attempts is not None and attempts >= max_attempts:
            continue
        found.append((_stamp(entry.name) or entry.name, target, reason))
    return [(p, why) for _k, p, why in sorted(found, key=lambda t: t[0])]


def find_pending_sessions(cfg: Config, now: Optional[float] = None, max_attempts: Optional[int] = None) -> list[Path]:
    """The session dirs of pending_items(): failed + retryable sessions of every kind and mid-stage leftovers, oldest first."""
    return [p for p, _why in pending_items(cfg, now, max_attempts)]
