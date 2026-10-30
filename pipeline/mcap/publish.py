"""Title resolution, folder naming, publishing to ARCHIVE_DIR, discarding, audio pruning (SPEC 7.4, 7.5, 13).

Safety rules: audio is never deleted on any failure. A move is "copy, verify, rename, only then delete the
source" when staging and the archive are on different volumes (Google Drive File Provider), and an archive that is not
mounted/writable makes publish fail with ArchiveUnavailable (the session simply stays in staging).

SPEC 18: `publish` / `move_dir` take an optional `before_commit` callback (the pipeline passes the drive lane
gate): it is asked before anything is touched, again before a same-volume rename and again after a cross-volume copy, right before the
hidden `.partial` folder is renamed into place; a non-empty answer raises `CommitBlocked`, the `.partial` copy is deleted and the source
is untouched (the caller then publishes to the local archive). `publish(archive_dir=...)` publishes into another root (the local archive
of a local-only meeting, created with Time Machine excluded: `exclude_from_backup`). `prune_audio` / `prune_local` also look at that local
root (LOCAL_ARCHIVE_RETENTION_DAYS) and at failed, non-retryable staging sessions (STAGING_FAILED_RETENTION_DAYS); both default to 0 = keep.
"""
from __future__ import annotations

import errno
import logging
import os
import re
import shutil
import subprocess
import time
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Optional

from .config import Config
from .state import atomic_write_json, atomic_write_text, read_json

log = logging.getLogger("mcap.publish")

DISCARDED_RETENTION_DAYS = 7
TOMBSTONE_RETENTION_DAYS = 30
LOCK_RETENTION_DAYS = 7
MAX_SLUG_CHARS = 60


class PublishError(Exception):
    pass


class ArchiveUnavailable(PublishError):
    """ARCHIVE_DIR (or its parent, e.g. the Google Drive mount) is missing or not writable."""


class CommitBlocked(PublishError):
    """`before_commit` said no (the drive lane closed meanwhile): nothing was committed, a `.partial` copy is gone, the source is untouched."""

    def __init__(self, reason: str):
        super().__init__(f"publishing blocked: {reason}")
        self.reason = reason


def _commit_check(before_commit: Optional[Callable[[], Any]]) -> None:
    """Ask the caller whether the move may go on: a falsy answer = yes, anything else (a LaneBlock, a reason string) = CommitBlocked."""
    if before_commit is None:
        return
    verdict = before_commit()
    if verdict:
        raise CommitBlocked(str(getattr(verdict, "reason", None) or verdict)[:80])


# ---------------------------------------------------------------------------------- time helpers
def parse_iso(value) -> Optional[datetime]:
    """ISO 8601 -> aware/naive datetime, None for anything unparsable."""
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def session_start(session: dict, session_dir: Optional[Path] = None) -> Optional[datetime]:
    """Session t0 with the offset it was recorded in: session.json start_time, else the session id (YYYY-MM-DD_HHMM)."""
    start = parse_iso((session or {}).get("start_time"))
    if start:
        return start
    sid = (session or {}).get("session_id") or (session_dir.name if session_dir else "")
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})", sid or "")
    if m:
        try:
            return datetime(*(int(g) for g in m.groups())).astimezone()
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------------------------- titles
_APP_SUFFIX = re.compile(r"\s*[-–—|·]\s*(google chrome|google meet|microsoft teams|zoom workplace|zoom meeting|zoom|chrome|safari)\s*$", re.I)
_MEET_PREFIX = re.compile(r"^\s*meet\s*[-–—:|]\s+(?=\S)", re.I)
_GENERIC_EXACT = {
    "meet", "google meet", "zoom", "zoom meeting", "zoom workplace", "zoom webinar", "microsoft teams", "teams",
    "meeting", "meeting in progress", "untitled", "untitled meeting", "(untitled)", "no title", "(no title)", "new tab",
    "meeting title", "meeting note", "meeting notes", "meeting summary", "transcript", "video call", "call", "calendar",
}
_GENERIC_PATTERNS = [
    re.compile(r"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"),                     # bare Meet code
    re.compile(r"^meet\s*[-–—:|]\s*[a-z]{3}-[a-z]{4}-[a-z]{3}$"),
    re.compile(r"^(zoom\s+)?meeting(\s+id)?[:\s#]*[\d\s-]{6,}$"),     # "Zoom Meeting ID: 123 456 789"
    re.compile(r"^[\d\s-]{6,}$"),                                      # bare numeric meeting id
    re.compile(r"^[\W_]*$"),                                           # nothing but punctuation
]


def clean_title(title) -> str:
    """Single line, NFC, without a trailing browser/app suffix ('- Google Chrome') or a leading 'Meet - '."""
    text = unicodedata.normalize("NFC", str(title or ""))
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    for _ in range(3):
        stripped = _APP_SUFFIX.sub("", text).strip()
        if stripped == text:
            break
        text = stripped
    return text


def is_generic_title(title) -> bool:
    """True for titles that carry no information ('Meet - abc-defg-hij', 'Zoom Meeting', 'Microsoft Teams', ...)."""
    text = clean_title(title)
    if not text:
        return True
    low = text.casefold()
    if low in _GENERIC_EXACT or any(p.match(low) for p in _GENERIC_PATTERNS):
        return True
    stripped = _MEET_PREFIX.sub("", text).strip()
    if stripped != text:
        return is_generic_title(stripped)
    return False


def informative_title(title) -> Optional[str]:
    """Cleaned title, or None when it is empty/generic. A leading 'Meet - ' is removed from tab titles."""
    if is_generic_title(title):
        return None
    text = clean_title(title)
    return _MEET_PREFIX.sub("", text).strip() or None


def resolve_title(calendar_title: Optional[str], title_hint: Optional[str], note_title: Optional[str],
                  platform_label: Optional[str]) -> tuple[str, str]:
    """SPEC 7.4: calendar -> informative window/tab title -> note H1 -> platform name. (title, source)."""
    for value, source in ((calendar_title, "calendar"), (title_hint, "window"), (note_title, "note")):
        title = informative_title(value)
        if title:
            return title, source
    return clean_title(platform_label) or "Meeting", "platform"


_SLUG_DROP = re.compile(r"[\\/:*?\"<>|\x00-\x1f\x7f]")
_SLUG_KEEP = "-_.()&+"


def slugify(title, max_len: int = MAX_SLUG_CHARS) -> str:
    """Folder-name slug: Hangul/Latin letters and digits kept, spaces -> '-', / \\ : * ? " < > | and control characters
    removed, other punctuation dropped, at most `max_len` characters, never ending in a dot/space/hyphen."""
    text = unicodedata.normalize("NFC", str(title or ""))
    text = re.sub(r"\s+", " ", text).strip()          # tabs/newlines count as spaces
    text = _SLUG_DROP.sub("", text).replace(" ", "-")
    text = "".join(ch for ch in text if ch.isalnum() or ch in _SLUG_KEEP)
    text = re.sub(r"-{2,}", "-", text)[:max_len]
    return text.strip("-_. ")


def folder_name(start: datetime, slug: str) -> str:
    return f"{start:%Y-%m-%d_%H%M}_{slug or 'meeting'}"


def note_title_of(note_text: str) -> Optional[str]:
    m = re.search(r"^#[ \t]+(\S.*?)\s*$", note_text or "", re.M)
    return m.group(1) if m else None


def set_transcript_title(path: Path, title: str) -> bool:
    """Rewrite the `Meeting:` line near the top of transcript.md (the title is only known after the calendar lookup).
    Atomic; returns True if the file changed."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return False
    lines = text.split("\n")
    new = "Meeting: " + re.sub(r"\s+", " ", title).strip()
    for i, line in enumerate(lines[:12]):
        if line.startswith("Meeting:"):
            if line == new:
                return False
            lines[i] = new
            try:
                atomic_write_text(Path(path), "\n".join(lines))
            except OSError as exc:
                log.warning("cannot update transcript title: %s", exc)
                return False
            return True
    return False


# ---------------------------------------------------------------------------------- archive checks
TMUTIL = "/usr/bin/tmutil"
_EXCLUDED: set = set()          # paths this process already excluded from Time Machine (a sweep must not start tmutil again and again)


def exclude_from_backup(path, *, run=subprocess.run) -> bool:
    """`tmutil addexclusion <path>` (the sticky kind: an attribute of the folder, no admin rights): the local archive and the staging
    folder hold meetings that must not leave this Mac through a backup. Best effort: a failure (no tmutil, a refusal) is
    logged, the pipeline goes on and `mcap doctor` reports a folder that is not excluded. True = excluded (now or earlier in this process).
    `run` is the subprocess runner (tests). Never raises."""
    target = str(Path(path))
    if target in _EXCLUDED:
        return True
    try:
        done = run([TMUTIL, "addexclusion", target], capture_output=True, text=True, timeout=15, stdin=subprocess.DEVNULL)
        ok = getattr(done, "returncode", 1) == 0
    except Exception as exc:
        ok = False
        log.info("backup exclusion of %s not set (%s)", Path(target).name, type(exc).__name__)
    if ok:
        _EXCLUDED.add(target)
    return ok


def archive_status(cfg: Config, archive_dir: Optional[Path] = None) -> tuple[bool, str]:
    """Is ARCHIVE_DIR usable? Its parent must exist (so an unmounted Google Drive is never 'created' under
    ~/Library/CloudStorage), ARCHIVE_DIR is created if missing, and a temp file must be writable.
    `archive_dir` (SPEC 18) names another root, the local archive: there the folder (and its parents: the allow-list already
    vouched for the place) is created on first use and excluded from Time Machine."""
    archive = Path(archive_dir) if archive_dir is not None else Path(cfg.archive_dir)
    is_drive = archive == Path(cfg.archive_dir)
    try:
        if not archive.is_dir():
            if is_drive and not archive.parent.is_dir():
                return False, f"{archive.parent} does not exist (Google Drive not running or not mounted?)"
            archive.mkdir(parents=not is_drive)
            if not is_drive:
                exclude_from_backup(archive)
        probe = archive / f".mcap-write-test-{os.getpid()}"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        return False, f"{archive} is not writable: {exc.strerror or exc}"
    return True, str(archive)


# ---------------------------------------------------------------------------------- audio housekeeping
def _is_m4a(path: Path) -> bool:
    try:
        if path.stat().st_size < 512:
            return False
        with open(path, "rb") as fh:
            return fh.read(12)[4:8] == b"ftyp"
    except OSError:
        return False


def expected_m4a(session: dict) -> list[str]:
    names = ["audio.m4a"]
    tracks = (session or {}).get("tracks")
    if isinstance(tracks, dict):
        names += [f"{t}.m4a" for t in ("mic", "remote") if t in tracks]
    return names


def audio_archived_ok(session_dir: Path, session: dict) -> tuple[bool, list[str]]:
    """(all expected m4a files exist and look like m4a, the missing/bad names)."""
    bad = [n for n in expected_m4a(session) if not _is_m4a(Path(session_dir) / n)]
    return (not bad), bad


def _is_temp_artifact(name: str) -> bool:
    """audioprep's scratch: the `.prep-XXXX` directory (full-length encode WAVs) and the `*.part` file an m4a is encoded into.
    They are derived data, never the only copy of anything, and must never reach the Google Drive folder."""
    return name.startswith(".prep-") or name.lower().endswith(".part")


def _remove_entry(entry: Path) -> bool:
    try:
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()
        return True
    except OSError as exc:
        log.warning("cannot remove %s: %s", entry, exc)
        return False


def sweep_temp_files(session_dir: Path) -> list[str]:
    """Remove `.prep-*` directories and `*.part` files left behind when an earlier run was killed (SIGTERM from the app, power
    loss) during audio preparation. Safe whenever the caller holds the session lock. Never raises; returns the removed names."""
    session_dir = Path(session_dir)
    removed: list[str] = []
    try:
        entries = sorted(session_dir.iterdir())
    except OSError:
        return removed
    for entry in entries:
        if _is_temp_artifact(entry.name) and _remove_entry(entry):
            removed.append(entry.name)
    if removed:
        log.info("swept leftover temp files: %s", ", ".join(removed))
    return removed


def cleanup_work_files(session_dir: Path, session: dict) -> list[str]:
    """Delete the PCM WAVs and ASR temp files, but ONLY when every expected m4a exists and is a real m4a (the WAVs may be the
    only copy of the audio). The derived scratch (`.prep-*`, `*.part`) is removed in every case. Returns the removed names.
    Never raises."""
    session_dir = Path(session_dir)
    removed = sweep_temp_files(session_dir)
    ok, bad = audio_archived_ok(session_dir, session)
    if not ok:
        log.warning("keeping WAV/work files: m4a missing or invalid (%s)", ", ".join(bad))
        return removed
    for entry in sorted(session_dir.iterdir()):
        name = entry.name
        is_work = name.lower().endswith((".wav", ".tmp", ".partial")) or name.startswith("_work")
        if not is_work or name.startswith(".state.json"):
            continue
        if _remove_entry(entry):
            removed.append(name)
    if removed:
        log.info("removed work files: %s", ", ".join(removed))
    return removed


# ---------------------------------------------------------------------------------- moving
def _copy_file(src: str, dst: str) -> str:
    try:
        return shutil.copy2(src, dst)
    except OSError:
        return shutil.copyfile(src, dst)      # e.g. a file system that rejects the metadata copy


def _verify_copy(src: Path, dst: Path) -> None:
    for root, _dirs, files in os.walk(src):
        rel = Path(root).relative_to(src)
        for name in files:
            a, b = Path(root) / name, dst / rel / name
            try:
                same = a.stat().st_size == b.stat().st_size
            except OSError:
                same = False
            if not same:
                raise PublishError(f"copy verification failed for {rel / name}")


def move_dir(src: Path, dest: Path, before_commit: Optional[Callable[[], Any]] = None) -> None:
    """Move directory `src` to the non-existing path `dest`. Same volume: one rename. Otherwise (different volume, or a
    file system that refuses the rename): copy next to the destination under a hidden name, verify every file size, rename
    into place, and only then remove the source. On any failure the source is left exactly as it was.
    `before_commit` (SPEC 18): asked before the move starts and once more right before the final rename (after a copy: with the
    `.partial` folder complete); a non-empty answer raises CommitBlocked and removes the `.partial` copy."""
    src, dest = Path(src), Path(dest)
    _commit_check(before_commit)
    try:
        os.rename(src, dest)
        return
    except OSError as exc:
        if exc.errno in (errno.EEXIST, errno.ENOTEMPTY):
            raise                     # the name is taken: the caller picks another one
        # EXDEV (different volume) or whatever else a File Provider volume answers: copy, verify, rename, delete
        log.info("rename %s -> %s failed (%s): copying instead", src.name, dest.parent, exc.strerror or exc)
    partial = dest.with_name(f".{dest.name}.partial")
    if partial.exists():
        shutil.rmtree(partial, ignore_errors=True)
    try:
        shutil.copytree(src, partial, copy_function=_copy_file)
        _verify_copy(src, partial)
        _commit_check(before_commit)                 # the lane may have closed while the (slow) copy ran
        os.rename(partial, dest)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    try:
        shutil.rmtree(src)
    except OSError as exc:       # the archive copy is complete; a leftover in staging is only clutter
        log.warning("copied to %s but could not remove staging dir %s: %s", dest, src, exc)


def _free_name(parent: Path, base: str) -> list[Path]:
    return [parent / (base if n == 1 else f"{base}-{n}") for n in range(1, 100)]


def publish(session_dir: Path, cfg: Config, title: str, session: Optional[dict] = None, *, archive_dir: Optional[Path] = None,
            before_commit: Optional[Callable[[], Any]] = None) -> Path:
    """Move the staging dir to ARCHIVE_DIR/YYYY-MM/YYYY-MM-DD_HHMM_<slug>[-N] (local time of the session start) and return
    the new path. Raises ArchiveUnavailable / PublishError; the session dir is untouched in that case (WAVs are only deleted
    after the m4a files were verified, and never on failure).
    SPEC 18: `archive_dir` publishes into that root instead (the local archive); `before_commit` is the drive lane gate, asked FIRST
    (before even the write probe touches a synced folder) and again by move_dir; CommitBlocked = nothing was published."""
    session_dir = Path(session_dir)
    session = session or {}
    _commit_check(before_commit)
    start = session_start(session, session_dir) or datetime.fromtimestamp(session_dir.stat().st_mtime).astimezone()
    root = Path(archive_dir) if archive_dir is not None else Path(cfg.archive_dir)
    ok, why = archive_status(cfg, root)
    if not ok:
        raise ArchiveUnavailable(f"archive unavailable: {why}")
    cleanup_work_files(session_dir, session)

    _commit_check(before_commit)                       # the probe and the WAV clean-up took a moment: nothing is created in the archive on a no
    month = root / f"{start:%Y-%m}"
    try:
        month.mkdir(exist_ok=True)
    except OSError as exc:
        raise ArchiveUnavailable(f"archive unavailable: cannot create {month}: {exc.strerror or exc}") from exc
    base = folder_name(start, slugify(title) or slugify(session.get("platform_label")) or "meeting")
    for candidate in _free_name(month, base):
        if candidate.exists():
            continue
        try:
            move_dir(session_dir, candidate, before_commit)
            log.info("published %s -> %s", session_dir.name, candidate)
            return candidate
        except OSError as exc:
            if exc.errno in (errno.EEXIST, errno.ENOTEMPTY) and candidate.exists():
                continue          # lost a naming race: take the next suffix
            raise PublishError(f"cannot move session to {candidate}: {exc.strerror or exc}") from exc
    raise PublishError(f"no free folder name for {base}")


def discard_session(session_dir: Path, cfg: Config) -> Path:
    """Park a no-speech session under SUPPORT_DIR/sessions/_discarded/<id> (pruned after 7 days by prune-audio)."""
    session_dir = Path(session_dir)
    parent = Path(cfg.discarded_dir)
    parent.mkdir(parents=True, exist_ok=True)
    for candidate in _free_name(parent, session_dir.name):
        if candidate.exists():
            continue
        try:
            move_dir(session_dir, candidate)
            return candidate
        except OSError as exc:
            if exc.errno in (errno.EEXIST, errno.ENOTEMPTY) and candidate.exists():
                continue
            raise PublishError(f"cannot move session to {candidate}: {exc.strerror or exc}") from exc
    raise PublishError(f"no free name in {parent}")


def leave_tombstone(staging_dir: Path, state: dict) -> None:
    """After the staging dir moved away, leave a directory holding only state.json (stage done/failed, title, final_dir,
    discarded): the Swift app reads it for the menu and 'Open Meeting Folder', and its startup scan never re-enqueues it."""
    staging_dir = Path(staging_dir)
    try:
        staging_dir.mkdir(parents=True, exist_ok=True)
        atomic_write_json(staging_dir / "state.json", state)
    except OSError as exc:
        log.warning("cannot leave state tombstone in %s: %s", staging_dir, exc)


# ---------------------------------------------------------------------------------- pruning (prune-audio)
_MONTH_RE = re.compile(r"^\d{4}-\d{2}$")
_MEETING_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})_")


@dataclass
class PruneReport:
    dry_run: bool = False
    audio: list = field(default_factory=list)        # m4a files deleted from archived meetings
    discarded: list = field(default_factory=list)    # parked no-speech sessions removed
    tombstones: list = field(default_factory=list)   # old staging state.json stubs removed
    locks: list = field(default_factory=list)
    errors: list = field(default_factory=list)
    failed: list = field(default_factory=list)       # failed, non-retryable staging sessions removed (STAGING_FAILED_RETENTION_DAYS)

    def summary(self) -> str:
        verb = "would delete" if self.dry_run else "deleted"
        failed = f", {len(self.failed)} failed session(s)" if self.failed else ""          # only a configured retention adds this part
        return (f"{verb}: {len(self.audio)} audio file(s), {len(self.discarded)} discarded session(s), "
                f"{len(self.tombstones)} state stub(s){failed}, {len(self.locks)} stale lock(s); {len(self.errors)} error(s)")


def _age_days(path: Path, now: float) -> float:
    try:
        return (now - path.stat().st_mtime) / 86400.0
    except OSError:
        return 0.0


def _remove(path: Path, report_list: list, report: PruneReport) -> None:
    report_list.append(path)
    if report.dry_run:
        return
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except OSError as exc:
        report.errors.append(f"{path}: {exc}")
        report_list.pop()


def prune_local(cfg: Config, now: Optional[float] = None, dry_run: bool = False,
                report: Optional[PruneReport] = None) -> PruneReport:
    """Housekeeping that only touches SUPPORT_DIR (cheap, no Google Drive access)."""
    report = report or PruneReport(dry_run=dry_run)
    now = time.time() if now is None else now
    discarded = Path(cfg.discarded_dir)
    if discarded.is_dir():
        for entry in sorted(discarded.iterdir()):
            stamp = entry / "state.json"
            age = _age_days(stamp if stamp.exists() else entry, now)
            if not entry.is_symlink() and age > DISCARDED_RETENTION_DAYS:
                _remove(entry, report.discarded, report)
    sessions = Path(cfg.sessions_dir)
    if sessions.is_dir():
        for entry in sorted(sessions.iterdir()):
            if entry.name.startswith("_") or not entry.is_dir() or entry.is_symlink():
                continue
            names = {p.name for p in entry.iterdir()}
            if names == {"state.json"} and _age_days(entry / "state.json", now) > TOMBSTONE_RETENTION_DAYS:
                state = read_json(entry / "state.json")
                if isinstance(state, dict) and state.get("stage") == "failed" and state.get("retryable") is True:
                    continue      # a published meeting still waiting for its note: `reprocess --pending` finds it through this stub
                _remove(entry, report.tombstones, report)
    locks = Path(cfg.locks_dir)
    if locks.is_dir():
        for entry in sorted(locks.iterdir()):
            if entry.is_file() and not entry.is_symlink() and _age_days(entry, now) > LOCK_RETENTION_DAYS:
                _remove(entry, report.locks, report)
    failed_days = int(getattr(cfg, "staging_failed_retention_days", 0) or 0)
    if failed_days > 0 and sessions.is_dir():            # SPEC 18: STAGING_FAILED_RETENTION_DAYS (0 = keep, today's behaviour)
        for entry in sorted(sessions.iterdir()):
            if entry.name.startswith("_") or not entry.is_dir() or entry.is_symlink() or not (entry / "session.json").is_file():
                continue                                  # a tombstone (state.json only) has its own rule above
            state = read_json(entry / "state.json")
            if not isinstance(state, dict) or state.get("stage") != "failed" or state.get("retryable") is True:
                continue                                  # only a failure no retry will ever finish (asr_policy_blocked, local_archive_unsafe ...)
            if _age_days(entry / "state.json", now) > failed_days:
                _remove(entry, report.failed, report)
    return report


def _prune_meeting_audio(root: Path, days: int, now: float, report: PruneReport) -> None:
    """Delete *.m4a (only) of the meeting folders under `root`/YYYY-MM older than `days` days (age from the folder name), and only in
    folders that still have transcript.md."""
    cutoff = datetime.fromtimestamp(now) - timedelta(days=days)
    for month in sorted(root.iterdir()):
        if not _MONTH_RE.match(month.name) or not month.is_dir() or month.is_symlink():
            continue
        for meeting in sorted(month.iterdir()):
            m = _MEETING_RE.match(meeting.name)
            if not m or not meeting.is_dir() or meeting.is_symlink():
                continue
            try:
                when = datetime(*(int(g) for g in m.groups()))
            except ValueError:
                continue
            if when >= cutoff or not (meeting / "transcript.md").is_file():
                continue
            for audio in sorted(meeting.glob("*.m4a")):
                if audio.is_file() and not audio.is_symlink():
                    _remove(audio, report.audio, report)


def _local_root_for_pruning(cfg: Config) -> Optional[Path]:
    """The local archive root when pruning it is allowed: it exists and passes the allow-list (``policy.local_archive_ok``; the policy's
    own local_roots count only when the policy file is valid). Anything else is left alone."""
    root = getattr(cfg, "local_archive_root", None)
    if root is None or not Path(root).is_dir():
        return None
    from . import policy as policy_mod
    ok, _why = policy_mod.local_archive_ok(root, cfg.support_dir, ())
    if not ok and getattr(cfg, "policy_path", None) is not None:
        org = policy_mod.load_org_policy(cfg.policy_path)
        ok = policy_mod.local_archive_ok(root, cfg.support_dir, org.local_roots)[0] if org.valid else False
    return Path(root) if ok else None


def prune_audio(cfg: Config, now: Optional[float] = None, dry_run: bool = False,
                include_archive: bool = True) -> PruneReport:
    """AUDIO_RETENTION_DAYS > 0: delete *.m4a (only) from archived meetings older than N days (age from the folder name),
    and only in folders that still have transcript.md. Transcripts and notes are never touched. Also runs the local
    housekeeping (discarded sessions after 7 days, old state stubs, stale locks, failed staging sessions when
    STAGING_FAILED_RETENTION_DAYS > 0). SPEC 18: LOCAL_ARCHIVE_RETENTION_DAYS > 0 does the same for the local archive (only a folder
    that passes the allow-list; the Drive is not touched for it)."""
    report = PruneReport(dry_run=dry_run)
    now = time.time() if now is None else now
    prune_local(cfg, now, dry_run, report)
    days = cfg.audio_retention_days
    archive = Path(cfg.archive_dir)
    if include_archive and days > 0 and archive.is_dir():
        _prune_meeting_audio(archive, days, now, report)
    local_days = int(getattr(cfg, "local_archive_retention_days", 0) or 0)
    if local_days > 0:
        root = _local_root_for_pruning(cfg)
        if root is not None:
            _prune_meeting_audio(root, local_days, now, report)
    return report
