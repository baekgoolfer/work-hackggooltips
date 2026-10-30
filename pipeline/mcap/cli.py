"""`python -m mcap <command>` (SPEC 7). Run from PROJECT_DIR/pipeline.

  process <session_dir> [--force] [--from audio|asr|cleanup|note|verify|publish] [--allow-overage] [--no-sweep]
  reprocess [--last | <dir> | --pending [--max-attempts N]] [--from ...] [--force] [--allow-overage] [--no-sweep]
            (--pending: a session that already failed 10 runs is skipped unless --max-attempts says otherwise, 0 = no limit)
  transcribe-file <audio> [--out transcript.md] [--model ...] [--language auto|ko|en]
  prune-audio [--dry-run]
  usage [--days N] [--json]                          (calls, and the cost of the last 7 / 30 days by billing path and stage)
  doctor [--no-warmup] [--share]
  api-key status [--exists]|set|check|forget [--yes] (CLAUDE_AUTH=api: the Console API key in the macOS Keychain, SPEC 17; status --exists only asks whether
            the item exists and never reads the value: the app installer's helper uses it)
  gcal auth|status|forget|upcoming [--from-minutes N --to-minutes M]   (Google Calendar, read-only, for calendar autostart: docs/CALENDAR_AUTOSTART.md;
            upcoming always prints ONE JSON object and exits 0)

SPEC 18 adds the operations surface of the external ASR engines and the company profile:

  asr-engines list|check|bench|consent|enroll|revoke|purge|secret ...   (list/check/bench: engines, consent, credential, health; consent: TTY only)
  status [--json | --write PATH]                     (content-free state: versions, policy, route, sessions, device; the MDM feed with --write)
  sessions [--json]                                  (the sessions in staging: id, stage, error kind, age, size; never a title)
  forget <folder> [--yes]                            (delete ONE session or meeting folder of staging / the local archive / the archive)
  release list|switch <version>                      (company layout: the releases/current link; never below the policy's minimum version)

Logs go to stderr (the Swift app appends stdout+stderr to LOG_DIR/pipeline-<id>.log); the last line of a process/reprocess run
is always `DONE: <folder>` or `FAILED: <one-line reason>`.
Exit codes: 0 ok (also: discarded session, nothing pending), 1 pipeline failed / doctor FAIL / a refusal by policy, 2 usage or config error,
3 nothing to reprocess (no session found), 75 session already being processed or still being recorded.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Optional

from . import __version__, apikey, appinfo, asr_providers, calendar_lookup, gcal, lanes, logsafe, note, overage, pipeline, publish, status, usage
from . import policy as policy_mod
from . import config as config_mod
from .config import DEFAULT_SUPPORT_DIR, Config, load_config
from .state import atomic_write_text, read_json

log = logging.getLogger("mcap.cli")

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_BUSY = 0, 1, 2, 3, 75


# ---------------------------------------------------------------------------------- process / reprocess
def _housekeeping(cfg: Config) -> None:
    """Cheap local cleanup after a run (discarded sessions > 7 days, stale locks); the archive is only scanned when
    AUDIO_RETENTION_DAYS > 0. Pipeline logs older than LOG_RETENTION_DAYS go too (default 0: nothing is pruned, as before).
    Must never influence the result."""
    try:
        report = publish.prune_audio(cfg, include_archive=cfg.audio_retention_days > 0)
        if report.audio or report.discarded or report.tombstones or report.locks:
            log.info("housekeeping: %s", report.summary())
    except Exception as exc:
        log.warning("housekeeping skipped: %s", exc)
    try:
        pruned = logsafe.prune_logs(cfg)
        if pruned:
            log.info("housekeeping: removed %d pipeline log(s) older than %d days", len(pruned), cfg.log_retention_days)
    except Exception as exc:
        log.warning("log housekeeping skipped: %s", exc)


SWEEP_MAX = 3          # after a successful run: retry at most this many other failed-but-retryable sessions
PENDING_MAX_ATTEMPTS = 10   # `reprocess --pending` leaves a session alone after this many failed runs (--max-attempts 0 = no limit): the
                            # app runs it every RETRY_SWEEP_HOURS, a session that can never succeed must not be retried (and announced) forever


def _sweep(cfg: Config, exclude: Path, deps: Optional[pipeline.Deps], allow_overage: bool) -> None:
    """After a successful run the machine evidently works again (Google Drive mounted, Claude reachable): give the failed,
    retryable sessions that piled up in staging (archive unavailable, a transient ASR/note failure, a run that died) one more
    try. Bounded (SWEEP_MAX sessions, MAX_AUTO_ATTEMPTS runs per session, nothing before a usage limit reset) and it can never
    change the result of the run that triggered it."""
    try:
        pending = [p for p in pipeline.find_pending_sessions(cfg, max_attempts=pipeline.MAX_AUTO_ATTEMPTS)
                   if p.resolve() != Path(exclude).resolve()][:SWEEP_MAX]
    except Exception as exc:
        log.warning("sweep skipped: %s", exc)
        return
    for target in pending:
        try:
            res = pipeline.process_session(target, cfg, allow_overage=allow_overage, deps=deps, only_if_pending=True)
        except pipeline.SessionBusy:
            print(f"SWEEP: {target.name} is busy, skipped", flush=True)
            continue
        except Exception as exc:
            log.exception("sweep of %s crashed", target)
            print(f"SWEEP: {target.name} crashed ({type(exc).__name__}), skipped", flush=True)
            continue
        if res.skipped:
            print(f"SWEEP: {target.name} needs no retry any more, skipped", flush=True)
            continue
        print(f"SWEEP: retried {target.name}: " + (f"ok -> {res.final_dir}" if res.ok else f"failed ({apikey.redact(res.error)})"),
              flush=True)


def _run_pipeline(target: Path, cfg: Config, *, force: bool, from_stage: Optional[str], allow_overage: bool,
                  deps: Optional[pipeline.Deps], sweep: bool = True) -> int:
    try:
        result = pipeline.process_session(target, cfg, force=force, from_stage=from_stage, allow_overage=allow_overage,
                                          deps=deps)
    except pipeline.SessionBusy as exc:
        print(f"BUSY: {exc}", flush=True)
        return EXIT_BUSY
    _housekeeping(cfg)
    if sweep and result.ok and not result.discarded:
        _sweep(cfg, target, deps, allow_overage)
    if result.warning:
        print(f"WARNING: {apikey.redact(result.warning)}", flush=True)
    if result.discarded:
        print("DONE: no speech, session discarded (kept 7 days in sessions/_discarded)", flush=True)
        return EXIT_OK
    if result.ok:
        print(f"DONE: {result.final_dir}", flush=True)
        return EXIT_OK
    where = f" (transcript kept in {result.final_dir})" if result.published else ""
    print(f"FAILED: {apikey.redact(result.error)}{where}", flush=True)
    return EXIT_FAILED


def cmd_process(args, deps=None) -> int:
    cfg = load_config()
    target = Path(args.session_dir).expanduser()
    if not target.is_dir():
        print(f"error: not a directory: {target}", file=sys.stderr)
        return EXIT_USAGE
    redirected = pipeline.resolve_session_path(target)
    if redirected is None:
        print(f"error: {target} is not a session folder (no session.json)", file=sys.stderr)
        return EXIT_USAGE
    if redirected != target:
        print(f"{target.name} was already published: working on {redirected}", flush=True)
    return _run_pipeline(redirected, cfg, force=args.force, from_stage=args.from_stage, allow_overage=args.allow_overage,
                         deps=deps, sweep=not args.no_sweep)


def _reprocess_pending(args, cfg: Config, deps) -> int:
    """`reprocess --pending`: everything a retry can finish (pipeline.pending_items): failed + retryable sessions of every kind
    (note failures, a usage limit only after its reset time, archive unavailable, asr failed, a stalled / killed job) and sessions
    that died mid-stage. Safe next to a normal run and to the app: a session still being recorded is never touched, a session
    another process is working on (its lock is held) is skipped as busy, and every session is looked at again once its lock is
    held, so a run that finished it meanwhile is not repeated. A session that already failed PENDING_MAX_ATTEMPTS runs (or
    --max-attempts N; 0 = no limit) is listed as skipped: `mcap reprocess <dir>` retries it by hand."""
    limit = PENDING_MAX_ATTEMPTS if args.max_attempts is None else args.max_attempts
    max_attempts = limit if limit > 0 else None
    pending = pipeline.pending_items(cfg, max_attempts=max_attempts)
    if max_attempts is not None:
        listed = {str(p) for p, _why in pending}
        for target, why in pipeline.pending_items(cfg):
            if str(target) not in listed:
                print(f"skipping {target.name}: it already failed {max_attempts} or more runs ({why}); retry it by hand with "
                      f"`mcap reprocess {target}` or lift the limit with --max-attempts 0", flush=True)
    if not pending:
        print("nothing pending: no failed session with a retryable error, no interrupted session (a Claude usage limit that "
              "has not reset yet, a recording in progress and sessions that failed too often are left alone)", flush=True)
        return EXIT_OK
    ok = failed = busy = skipped = 0
    for target, why in pending:
        print(f"retrying {target}: {why}", flush=True)
        try:
            res = pipeline.process_session(target, cfg, force=args.force, from_stage=args.from_stage,
                                           allow_overage=args.allow_overage, deps=deps, only_if_pending=True)
        except pipeline.SessionBusy as exc:
            busy += 1
            print(f"  BUSY: {exc}", flush=True)
            continue
        if res.skipped:
            skipped += 1
            print("  SKIPPED: it needs no retry any more (another run finished it)", flush=True)
        elif res.ok:
            ok += 1
            print(f"  DONE: {res.final_dir}", flush=True)
        else:
            failed += 1
            print(f"  FAILED: {apikey.redact(res.error)}", flush=True)
    _housekeeping(cfg)
    summary = f"pending: {len(pending)} session(s) found, {ok} ok, {failed} failed, {busy} busy, {skipped} already handled"
    if failed:
        print(f"FAILED: {summary}", flush=True)
        return EXIT_FAILED
    print(f"DONE: {summary}", flush=True)
    return EXIT_OK


def cmd_reprocess(args, deps=None) -> int:
    cfg = load_config()
    if args.pending:
        if args.dir or args.last:
            print("error: --pending cannot be combined with a folder or --last", file=sys.stderr)
            return EXIT_USAGE
        return _reprocess_pending(args, cfg, deps)
    if args.dir:
        target = pipeline.resolve_session_path(Path(args.dir).expanduser())
        if target is None:
            print(f"error: {args.dir} is not a session or meeting folder (no session.json)", file=sys.stderr)
            return EXIT_USAGE
    else:
        target = pipeline.find_last_session(cfg)
        if target is None:
            print("nothing to reprocess: no session in staging or in the archive (a session that is still being recorded "
                  "does not count)", file=sys.stderr)
            return EXIT_NOT_FOUND
    from_stage = args.from_stage
    if not from_stage and not args.force and pipeline.is_complete(target):
        from_stage = "note"       # a finished meeting: the only cheap thing to redo is the note
        print("meeting is complete: regenerating the note (use --from asr to re-transcribe; the old note is kept as "
              "meeting-note.prev.md)", flush=True)
    print(f"reprocessing {target}", flush=True)
    return _run_pipeline(target, cfg, force=args.force, from_stage=from_stage, allow_overage=args.allow_overage,
                         deps=deps, sweep=not args.no_sweep)


# ---------------------------------------------------------------------------------- transcribe-file
def _privacy_inputs() -> "lanes.PrivacyInputs":
    """What ``lanes.resolve_run`` reads from the outside for a command that has no session folder (tests replace this one function: an injected
    policy, consents, hardware verdict, clock). ``meeting`` None = the default chain of the local-only flag (``policy.local_only.default`` OR
    ``LOCAL_ONLY_DEFAULT``): an audio file has no ``session.json``."""
    return lanes.PrivacyInputs(meeting=None)


def cmd_transcribe_file(args, deps=None) -> int:
    cfg = load_config()
    audio = Path(args.audio).expanduser()
    if not audio.is_file():
        print(f"error: no such file: {audio}", file=sys.stderr)
        return EXIT_USAGE
    if args.model:
        cfg = dataclasses.replace(cfg, asr_model=args.model)
    language = args.language or cfg.asr_language
    deps = (deps or pipeline.Deps()).resolved()
    # SPEC 18: the same lane decision a pipeline run makes (organisation policy, consent, local-only default, hardware). The personal
    # default (no policy, flag false, Whisper) gets the SAME cfg object back from cfg_for_asr: nothing changes for it.
    privacy = lanes.resolve_run(cfg, None, None, inputs=_privacy_inputs())
    if privacy.asr.blocked:
        print("FAILED: transcription blocked: this Mac cannot run the local engine and no external engine is allowed "
              f"({privacy.asr.reason})", file=sys.stderr)
        return EXIT_FAILED
    try:
        samples = pipeline.decode_audio_16k(audio)
        vocab = pipeline.load_vocab_for(cfg)
        with lanes.run_scope(privacy):
            segments = deps.transcribe_array(samples, privacy.cfg_for_asr(cfg), vocab, language=None if language == "auto" else language,
                                             progress=lambda msg: log.info("asr: %s", msg))
        transcript = {"schema": 1, "asr_model": cfg.asr_model, "languages": {"file": language}, "segments": [
            {**seg, "speaker": seg.get("speaker") or "Speaker", "track": seg.get("track") or "file"} for seg in segments]}
        policy_block = privacy.transcript_policy_block()          # None for the personal default: the transcript has no new key
        if policy_block is not None:
            transcript["policy"] = policy_block
        duration = len(samples) / 16000.0
        meta = {"title": audio.name, "date": f"{datetime.fromtimestamp(audio.stat().st_mtime):%Y-%m-%d}",
                "platform_label": "Audio file", "start_time": None, "duration_sec": duration, "asr_model": cfg.asr_model}
        markdown = deps.render_markdown(transcript, meta)
    except Exception as exc:
        log.exception("transcribe-file failed")
        print(f"FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_FAILED
    if args.out:
        atomic_write_text(Path(args.out).expanduser(), markdown)
        print(f"DONE: {args.out}", flush=True)
    else:
        sys.stdout.write(markdown if markdown.endswith("\n") else markdown + "\n")
    return EXIT_OK


# ---------------------------------------------------------------------------------- prune-audio
def cmd_prune_audio(args, deps=None) -> int:
    cfg = load_config()
    report = publish.prune_audio(cfg, dry_run=args.dry_run)
    if cfg.audio_retention_days <= 0:
        print("AUDIO_RETENTION_DAYS=0: audio in the archive is kept forever (only local housekeeping ran)")
    for label, items in (("audio", report.audio), ("discarded", report.discarded), ("state stub", report.tombstones),
                         ("lock", report.locks)):
        for item in items:
            print(f"  {'would delete' if args.dry_run else 'deleted'} {label}: {item}")
    for err in report.errors:
        print(f"  error: {err}", file=sys.stderr)
    print(report.summary())
    if cfg.log_retention_days > 0:                                 # LOG_RETENTION_DAYS=0 (default): logs are kept and nothing is printed
        for path in logsafe.prune_logs(cfg, dry_run=args.dry_run):
            print(f"  {'would delete' if args.dry_run else 'deleted'} log: {path.name}")
    return EXIT_FAILED if report.errors else EXIT_OK


# ---------------------------------------------------------------------------------- usage
def cmd_usage(args, deps=None) -> int:
    """`mcap usage [--days N] [--json]`: the claude calls of the last N days (default 7) from usage.jsonl and what they cost: the
    cost of the last 7 and 30 days by billing path (api = billed to the Console key, subscription = API-equivalent estimate) and stage."""
    cfg = load_config()
    summary = usage.week_summary(cfg, days=max(1, args.days))
    windows = usage.cost_windows(cfg)
    if args.json:
        print(json.dumps({**summary, "billing": apikey.mode(cfg), "cost_windows": {str(d): w for d, w in windows.items()}},
                         ensure_ascii=False, indent=2))
    else:
        for line in usage.format_summary(summary):
            print(line)
        for line in usage.format_costs(windows):
            print(line)
        if apikey.is_api(cfg):
            print(usage.budget_line(cfg))
        print(f"(log: {usage.usage_path(cfg)}; billing: CLAUDE_AUTH={apikey.mode(cfg)}; cap per meeting run: "
              f"MAX_CLAUDE_CALLS_PER_MEETING={cfg.max_claude_calls_per_meeting})")
    return EXIT_OK


# ---------------------------------------------------------------------------------- api-key (SPEC 17)
def _api_key_status(cfg: Config) -> int:
    st = apikey.key_status(cfg)
    if apikey.mode_problem(cfg):                  # a misspelt value is neither mode: say so instead of claiming "subscription"
        uses = "invalid value: the pipeline makes no Claude call until CLAUDE_AUTH is 'subscription' or 'api'"
    elif apikey.is_api(cfg):
        uses = "the pipeline uses it"
    else:
        uses = "the pipeline does NOT use it: CLAUDE_AUTH=subscription"
    print(f"Anthropic API key in the macOS Keychain (CLAUDE_AUTH={apikey.mode(cfg)}: {uses})")
    for line in apikey.format_status(st):
        print(line)
    return EXIT_OK if st.usable else EXIT_FAILED


def _api_key_exists(cfg: Config) -> int:
    """`api-key status --exists`: is there a Keychain item? The value is NOT read (apikey.item_exists). Exit 0 yes, 1 no or unknown."""
    found = apikey.item_exists(cfg)
    if found:
        print("A Keychain item for the Anthropic API key exists (its value was not read).")
        return EXIT_OK
    print("No Keychain item for the Anthropic API key." if found is False else "The Keychain could not be asked whether the Anthropic API key exists.")
    return EXIT_FAILED


def _api_key_check(cfg: Config) -> int:
    """The ONE place that makes a call just to test the key, and only on this explicit command (one tiny haiku call)."""
    res = note.check_api_key(cfg)
    cost = f"{res.cost_usd:.6f}" if res.cost_usd is not None else "unknown (the result has no total_cost_usd)"
    if res.ok:
        print("API key OK")
        print(f"  model:        {res.model or '?'} (requested: {res.requested})")
        print(f"  apiKeySource: {res.api_key_source or '?'}")
        print(f"  cost_usd:     {cost}")
        print(f"  reply:        {res.reply}")
        if apikey.mode_problem(cfg):
            print(f"  note:         CLAUDE_AUTH={apikey.mode(cfg)} is not a valid value: the pipeline makes no Claude call until it is "
                  "'subscription' or 'api'")
        elif not apikey.is_api(cfg):
            print("  note:         CLAUDE_AUTH=subscription: the pipeline keeps using the subscription until you set CLAUDE_AUTH=api")
        return EXIT_OK
    print(f"FAILED: {apikey.redact(res.message)}", file=sys.stderr)
    if res.api_key_source:
        print(f"  apiKeySource: {res.api_key_source}", file=sys.stderr)
    if res.cost_usd:
        print(f"  cost_usd:     {cost}", file=sys.stderr)
    return EXIT_FAILED


def _api_key_forget(cfg: Config, yes: bool) -> int:
    if not yes:
        if sys.stdin is None or not sys.stdin.isatty():
            print("error: mcap api-key forget deletes the Keychain item: pass --yes (or run it in a terminal)", file=sys.stderr)
            return EXIT_USAGE
        answer = input(f"Delete the Keychain item '{apikey.keychain_service(cfg)}' (account '{apikey.keychain_account()}')? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            print("cancelled")
            return EXIT_OK
    return apikey.forget_key(cfg)


def cmd_api_key(args, deps=None) -> int:
    """`mcap api-key status|set|check|forget`. None of them ever prints the key; `set` leaves the typing to the macOS security tool."""
    cfg = load_config()
    if args.action == "status":
        return _api_key_exists(cfg) if getattr(args, "exists", False) else _api_key_status(cfg)
    if args.action == "set":
        return apikey.set_key_interactive(cfg)
    if args.action == "check":
        return _api_key_check(cfg)
    return _api_key_forget(cfg, args.yes)


# ---------------------------------------------------------------------------------- gcal (docs/CALENDAR_AUTOSTART.md)
def cmd_gcal(args, deps=None) -> int:
    """`mcap gcal auth|status|forget|upcoming`. `upcoming` is the contract with the Swift app: one JSON object on stdout, exit 0 whatever happens.
    None of them ever prints a token or the client secret."""
    if args.action == "upcoming":
        return gcal.print_upcoming(load_config, args.from_minutes, args.to_minutes)
    cfg = load_config()
    if args.action == "auth":
        return gcal.authorize(cfg)
    if args.action == "status":
        return gcal.print_status(cfg)
    return gcal.forget(cfg)


# ---------------------------------------------------------------------------------- doctor
class _Doctor:
    def __init__(self, out: Callable[[str], None] = print):
        self.out = out
        self.counts = {"PASS": 0, "WARN": 0, "FAIL": 0}

    def add(self, level: str, name: str, message: str) -> None:
        self.counts[level] += 1
        self.out(f"[{level}] {name}: {message}")


def _hf_cache_roots() -> list[Path]:
    roots = []
    if os.environ.get("HF_HUB_CACHE"):
        roots.append(Path(os.environ["HF_HUB_CACHE"]))
    if os.environ.get("HF_HOME"):
        roots.append(Path(os.environ["HF_HOME"]) / "hub")
    roots.append(Path.home() / ".cache" / "huggingface" / "hub")
    return roots


def model_cache_status(model: str) -> tuple[bool, str]:
    """Is the ASR model present locally? Never downloads anything."""
    local = Path(os.path.expanduser(model))
    if local.is_dir():
        return True, f"local directory {local}"
    if "/" not in model:
        return False, f"{model!r} is not a Hugging Face repo id or an existing directory"
    folder = "models--" + model.replace("/", "--")
    for root in _hf_cache_roots():
        for snap in sorted((root / folder / "snapshots").glob("*")) if (root / folder / "snapshots").is_dir() else []:
            has_cfg = (snap / "config.json").exists()
            has_weights = any(snap.glob("*.safetensors")) or any(snap.glob("*.npz"))
            if has_cfg and has_weights:
                return True, f"{snap}"
    return False, "not in the Hugging Face cache (first run would download it)"


def silero_model_path(cfg: Config) -> Optional[Path]:
    """Where the VAD component finds the Silero model (it owns the lookup: $MCAP_SILERO_MODEL, SUPPORT_DIR/models, package data)."""
    try:
        from . import vad
        return vad.silero_model_path(cfg)
    except ImportError:
        return None


def _write_probe(directory: Path) -> Optional[str]:
    """None if a temp file can be created and deleted in `directory`, else the reason."""
    probe = directory / f".mcap-doctor-{os.getpid()}"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        return exc.strerror or str(exc)
    return None


def _doctor_prompt(d: "_Doctor", cfg: Config, label: str, filename: str, needed: bool) -> None:
    """Report WHICH prompt file is used (SPEC 14.4: SUPPORT_DIR/<name> = the user's override, else the repo's config/<name>)."""
    try:
        used = note.resolve_prompt(cfg, filename)
    except FileNotFoundError as exc:
        d.add("FAIL" if needed else "WARN", label, str(exc))
        return
    repo = Path(cfg.repo_config_dir) / filename
    override = Path(cfg.support_dir) / filename
    if used == override:
        same = False
        try:
            same = repo.is_file() and override.read_text(encoding="utf-8") == repo.read_text(encoding="utf-8")
        except OSError:
            pass
        if same:
            d.add("PASS", label, f"user override {override} (identical to the repo version; delete it to follow future repo updates)")
        else:
            d.add("WARN", label, f"user override {override} is used and it differs from the repo version {repo} "
                                 "(delete the override to use the repo prompt)")
    else:
        d.add("PASS", label, f"repo copy {used} (no override in {cfg.support_dir})")


_SWITCH_KEYS = ("NOTE_STOP_ON_OVERAGE", "TRANSCRIPT_CLEANUP", "NOTE_VERIFY")
_SWITCH_VALUES = {"1", "true", "yes", "on", "0", "false", "no", "off", ""}


def _unrecognised_switches() -> list[tuple[str, str]]:
    """config.env on/off switches with a value the Python parser silently reads as OFF ('y', 'enabled', a typo): the guard of a
    billing switch must not fail open without a word."""
    from .config import parse_env_text
    path = Path(os.environ.get("MCAP_CONFIG") or DEFAULT_SUPPORT_DIR / "config.env")
    try:
        values = parse_env_text(path.read_text(encoding="utf-8"))
    except OSError:
        return []
    return [(k, values[k]) for k in _SWITCH_KEYS if k in values and values[k].strip().lower() not in _SWITCH_VALUES]


def _doctor_api(d: "_Doctor", cfg: Config, claude_bin: Path, calendar_off: Optional[str] = None) -> None:
    """CLAUDE_AUTH=api: the key (never its value), what is billed where, the budgets. The doctor never makes a billing call itself;
    `mcap api-key check` is the explicit one. ``calendar_off``: the organisation denies the calendar lane (no login check for it)."""
    st = apikey.key_status(cfg)
    where = f"service '{st.service}', account '{st.account}'"
    if st.usable:
        d.add("PASS", "api key", f"present in the Keychain ({where}), {st.length} characters, sk-ant- prefix ok; validated: no, "
                                 "run `mcap api-key check` (the doctor never makes a billing call)")
    elif st.present:
        d.add("FAIL", "api key", f"{st.message} ({where})")
    else:
        d.add("FAIL", "api key", f"{st.message} ({where})")
    d.add("PASS", "billing mode", "API key (Console credits), CLAUDE_AUTH=api: cleanup, note and verify calls are billed per token to the "
                                  "Console account behind the key (a bug or a false-positive recording costs money); only the calendar "
                                  "lookup uses the claude.ai login (subscription)")
    if calendar_lookup.enabled(cfg) and not calendar_off:
        ok, info = note.preflight(str(claude_bin), cfg=cfg)          # local `claude auth status`, no model, not billed
        if ok:
            d.add("PASS", "calendar login", f"claude.ai login found (authMethod={info.get('authMethod')}): the calendar lookup can run "
                                            "in subscription mode")
        else:
            d.add("WARN", "calendar login", "no claude.ai login: the calendar lookup is skipped quietly (the window title / platform "
                                            "name is used); run `claude auth login` to enable it, or set CALENDAR_LOOKUP=0")
    status = usage.budget_status(cfg)
    d.add("WARN" if status["reached"] else "PASS", "api budget", usage.budget_line(cfg))


# ---- organisation policy view of the doctor --------------------------------------------------------------
_EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
DOCTOR_EXPIRY_WARN_DAYS = 14                    # a consent that ends within this many days is a WARN (expiry: the engine is excluded, local goes on)


def share_filter(text: str) -> str:
    """`mcap doctor --share`: the home directory becomes ``~`` and every e-mail address ``<email>``, so the output can be pasted into a
    support ticket (a Drive mount is named after the account, the paths after the user)."""
    home = os.path.expanduser("~")
    if home and home != "/":
        text = text.replace(home, "~")
    return _EMAIL.sub("<email>", text)


class _OrgView:
    """What the organisation policy says about this Mac, for the doctor. ``active`` is False when there is no policy (no policy.json and no
    policy.required): every doctor line is then exactly what it always was. ``denied(lane)`` is the reason an ORGANISATION-level rule closes
    the lane (a policy deny, a missing approval, an archive root that does not match, a lock), None when it is open or only the user's own
    setting is off. Lane denials are never a FAIL: the doctor says ``skipped: lane denied`` and checks what the Mac uses instead."""

    def __init__(self, cfg: Config, org):
        self.cfg, self.org = cfg, org
        self.active = bool(org.present)
        self.decisions = policy_mod.lane_decisions(status.lane_view_local_only(org), org, cfg) if self.active else {}

    def denied(self, lane: str) -> Optional[str]:
        decision = self.decisions.get(lane)
        if decision is None or decision.allowed or decision.reason == "user-disabled":
            return None
        return decision.reason


def named_external_engines(cfg: Config) -> list[str]:
    """The external engines ASR_ENGINE / ASR_FALLBACK ask for (``auto`` can pick the company server)."""
    primary, fallback = policy_mod.requested_engines(cfg)
    names = ["remote" if primary == "auto" else primary, fallback]
    return [name for name in dict.fromkeys(names) if name in status.EXTERNAL_ENGINES]


def _setup_settings(engine: str, default: str = "ASR_REMOTE_URL / ASR_AZURE_REGION") -> str:
    """The setting(s) of config.env that configure ``engine``, for the 'not configured' messages: a provider names its own URL setting."""
    return asr_providers.setup_hint(engine) or default


def _remote_only(cfg: Config) -> bool:
    """ASR_ENGINE=remote without a Whisper fallback: this Mac never needs the local model or mlx."""
    primary, fallback = policy_mod.requested_engines(cfg)
    return primary == "remote" and fallback != "whisper"


def _doctor_local_archive(d: "_Doctor", cfg: Config, view: _OrgView) -> None:
    """LOCAL_ARCHIVE_DIR (where local-only and Drive-denied meetings go): on the allow-list, writable, kept out of the backup."""
    root = Path(cfg.local_archive_root)
    ok, why = policy_mod.local_archive_ok(root, cfg.support_dir, view.org.local_roots if view.org.valid else ())
    if not ok:
        d.add("FAIL", "local archive", f"{root} is not an allowed local folder ({why}): local-only meetings cannot be kept there "
                                       "(it must be under SUPPORT_DIR or a policy local_roots entry, no symbolic link, same disk as the home folder)")
        return
    if not root.is_dir():
        d.add("PASS", "local archive", f"{root} does not exist yet: it is created, and excluded from Time Machine, when a meeting needs it")
        return
    reason = _write_probe(root)
    if reason:
        d.add("FAIL", "local archive", f"{root} is not writable: {reason}")
        return
    excluded = status.backup_excluded(root)
    if excluded is True:
        d.add("PASS", "local archive", f"{root} (writable, excluded from Time Machine)")
    elif excluded is False:
        d.add("WARN", "local archive", f"{root} is writable but NOT excluded from Time Machine: `tmutil addexclusion` is applied when the "
                                       "folder is created; run it once by hand for this one")
    else:
        d.add("WARN", "local archive", f"{root} is writable; whether Time Machine excludes it could not be read")


def _doctor_policy(d: "_Doctor", cfg: Config, view: _OrgView, external: bool) -> None:
    """The lines a policy-managed Mac (or one that configured an external engine) gets on top of the personal ones: profile and policy state,
    the local-only default, the lane view, the effective ASR route after policy and consent, consent expiry, credential presence (never the
    value), the allow-listed destinations as labels, the hardware verdict, the log content mode, the daily cap, and the FAIL rules of a
    company Mac whose local-only flag is locked (no transcript without a local engine; no FileVault)."""
    org, now = view.org, status.aware()
    contact = f" (contact: {org.support_contact})" if org.support_contact else ""
    if view.active:
        if org.valid:
            d.add("PASS", "organisation policy", f"profile {org.profile}, revision {org.revision}, sha256 {org.sha256_8}{contact}")
        else:
            d.add("FAIL", "organisation policy", f"LOCKED ({org.locked_reason or 'invalid'}): every external lane is closed and transcription "
                                                 f"stays on this Mac; ask the administrator to redeploy the policy{contact}")
        lo = status.default_local_only(org, cfg)
        d.add("PASS", "local-only default", f"new meetings start local-only: {'yes' if lo.value else 'no'} ({lo.source})"
                                            + ("; the policy locks it" if org.local_only_locked else ""))
        parts = []
        for lane in policy_mod.LANES:
            decision = view.decisions[lane]
            parts.append(f"{lane} " + ("allow" if decision.allowed else ("off (setting)" if decision.reason == "user-disabled"
                                                                         else f"deny ({decision.reason})")))
        d.add("PASS", "lanes", ", ".join(parts))
        drive = view.denied("drive")
        if drive == "archive-not-configured":
            d.add("WARN", "archive dir", "ARCHIVE_DIR is not set in config.env: on a company Mac the Drive lane stays closed and meetings go to "
                                         "the local archive until the user's config names the team drive")
        elif drive == "policy-archive-root":
            d.add("WARN", "archive dir", "ARCHIVE_DIR is outside the team drives this policy allows: meetings go to the local archive, not there")
        if org.valid and org.profile == policy_mod.COMPANY and "SELF_NAME" not in cfg.explicit_keys:
            d.add("WARN", "config", "SELF_NAME is not set in config.env: the transcript names this user 'Me' (the built-in default)")
    # ---- the ASR route and what it rests on
    machine_used = 0.0
    try:
        from . import asr_usage
        machine_used = asr_usage.minutes_today(cfg, now=now)
    except Exception:
        pass
    consents = status.load_consent_set(cfg, now)
    hw = status.hardware_probe(cfg, now=now)
    decision = policy_mod.decide_asr(cfg, org, status.lane_view_local_only(org), consents, hw, used_minutes_today=machine_used, now=now)
    excluded = [n for n in decision.notes if "excluded" in n]
    level = "FAIL" if decision.blocked else ("WARN" if excluded else "PASS")
    d.add(level, "asr route", f"primary {decision.primary}, fallback {decision.fallback or 'none'} (reason {decision.reason})"
          + (f"; {'; '.join(decision.notes)}" if decision.notes else "")
          + ("; BLOCKED: this Mac cannot run the local engine and no external engine is allowed (asr_policy_blocked)" if decision.blocked else ""))
    if consents.problem:
        bad = consents.problem.startswith("bad-entries")
        d.add("WARN" if bad else "FAIL", "asr consent", f"the consent file is not usable ({consents.problem}): "
              + ("the damaged entries are ignored" if bad else "no consent is valid until it is recreated (mcap asr-engines consent <engine>)"))
    for engine in named_external_engines(cfg):
        state = status.consent_state(cfg, engine, org, consents, now)
        if state["state"] != "ok":
            d.add("WARN", f"asr consent {engine}", f"{state['state']}: {engine} is not used (local Whisper is) until "
                  + (f"it is configured ({_setup_settings(engine)})" if state["state"] in ("not-configured", "bad-host")
                     else f"`mcap asr-engines consent {engine}` is done again"))
            continue
        left = None
        limit = policy_mod._expiry(state["expires"])
        if limit is not None:
            left = (limit - now).days
        soon = left is not None and left <= DOCTOR_EXPIRY_WARN_DAYS
        d.add("WARN" if soon else "PASS", f"asr consent {engine}", f"{state['source']} consent {state['id']} for {state['use']} use, valid until "
              f"{state['expires']}" + (f" ({left} day(s) left: renew it)" if soon else ""))
        binding, _why = policy_mod.consent_binding(cfg, engine)
        if binding is not None:
            label = "company-asr" if binding["kind"] == "server" else f"{engine}/{binding['region'] or 'default'}"
            listed = org.allowed_hosts is None or binding["host"] in org.allowed_hosts
            how = ("no allow list (no restriction)" if org.allowed_hosts is None
                   else ("on the allow list" if listed else "NOT on the policy's allow list: it is not used"))
            d.add("PASS" if listed else "WARN", f"asr destination {engine}", f"{label}: {how}")
            from . import asr_creds
            cred = asr_creds.secret_status(engine, binding["host"], binding["port"])
            d.add("PASS" if cred["present"] else "WARN", f"asr credential {engine}",
                  "stored in the Keychain (the value is not read)" if cred["present"]
                  else f"not stored ({cred['reason']}): run `mcap asr-engines {'enroll remote' if engine == 'remote' else 'secret set ' + engine}`")
    d.add("WARN" if hw.capable is False else "PASS", "asr capability",
          f"{hw.arch}, {hw.mem_gb or 'unknown'} GB RAM, mlx {_yn(hw.mlx_ok)}, model on disk {_yn(hw.model_present)}, "
          f"rtf {hw.rtf if hw.rtf is not None else 'not measured'}; local engine capable: {_yn(hw.capable)}"
          + (f" ({', '.join(hw.reasons)})" if hw.reasons and hw.capable is not True else ""))
    if view.active:
        d.add("PASS", "log content", "LOG_CONTENT=" + ("on: pipeline logs may carry up to 60 characters of transcript text"
                                                       if cfg.log_content else "off: transcript pieces are logged as length and hash only"))
    if external or view.active:
        caps = [float(cfg.asr_cloud_daily_minutes)] + ([float(org.daily_audio_minutes_cap)] if org.daily_audio_minutes_cap is not None else [])
        cap = min(caps)
        d.add("WARN" if cap and machine_used >= 0.9 * cap else "PASS", "asr daily cap",
              f"{machine_used:.1f} of {cap:g} minutes of external audio used today (counted as audio + 1 s per request)")
    # ---- the FAIL rules of a company Mac that locked local-only (no external fallback exists for it)
    if org.valid and org.profile == policy_mod.COMPANY:
        locked = org.local_only_locked
        if locked and hw.capable is False:
            d.add("FAIL", "local transcription", "local-only is locked for this Mac but it cannot run the local engine "
                  f"({', '.join(hw.reasons) or 'not capable'}): no meeting could be transcribed (asr_policy_blocked); take it out of this device group")
        vault = status.filevault_state()
        if vault == "on":
            d.add("PASS", "filevault", "on")
        elif vault == "off":
            d.add("FAIL" if locked else "WARN", "filevault", "FileVault is OFF: recordings and transcripts on this Mac are not encrypted at rest"
                  + (" (required for a device group with locked local-only)" if locked else ""))
        else:
            d.add("WARN", "filevault", "could not be read (fdesetup status)")


def _yn(value: Optional[bool]) -> str:
    return "unknown" if value is None else ("yes" if value else "no")


def _claude_pin_block(cfg: Config, view: "_OrgView", run=None):
    """Why the doctor must not start ``claude`` at all, or None. Under a valid COMPANY policy whose llm lane is open the binary at CLAUDE_BIN
    has to match the policy's signature pin before ANY process is started from it, and the doctor's own ``--version`` and
    ``auth status`` calls are spawn sites like the pipeline's. The doctor has no pipeline run that carries the policy, so it is
    passed explicitly; ``note.verify_claude_bin`` answers None for no policy and for a personal-profile policy. ``run``: the codesign runner."""
    if not view.active:
        return None
    return note.verify_claude_bin(cfg, view.org, run=run)


def _doctor_claude(d: "_Doctor", cfg: Config, calendar_off: Optional[str] = None, child_env: Optional[dict] = None) -> None:
    """The Claude CLI, login / API key and billing mode checks (SPEC 17: they follow the billing mode, and the billing line says which one is on).
    ``calendar_off``: the organisation denies the calendar lane, so the calendar login is not looked at either. ``child_env``: the extra names
    a valid policy adds to the claude child's environment (``llm.child_env``: telemetry, error reporting and auto-update off) for the
    ``--version`` call; ``auth status`` goes through ``note.preflight``, which builds its own environment."""
    claude_bin = Path(cfg.claude_bin)
    problem = apikey.mode_problem(cfg)
    if problem:
        d.add("FAIL", "billing mode", problem)
    if claude_bin.is_file() and os.access(claude_bin, os.X_OK):
        try:
            v = subprocess.run([str(claude_bin), "--version"], env=note.clean_env(extra=child_env), capture_output=True, text=True,
                               timeout=20, stdin=subprocess.DEVNULL)
            d.add("PASS", "claude cli", f"{claude_bin} ({v.stdout.strip() or 'version unknown'})")
        except (OSError, subprocess.SubprocessError) as exc:
            d.add("WARN", "claude cli", f"{claude_bin}: cannot read version ({exc})")
        if problem:
            pass
        elif apikey.is_api(cfg):
            _doctor_api(d, cfg, claude_bin, calendar_off)
        else:
            ready = note.check_ready(cfg, allow_overage=True)
            if ready.ok:
                info = ready.info
                d.add("PASS", "claude login", f"authMethod={info.get('authMethod')} apiProvider={info.get('apiProvider')}"
                      + (f" subscription={info['subscriptionType']}" if info.get("subscriptionType") else ""))
                d.add("PASS", "billing mode", "subscription (CLAUDE_AUTH=subscription): subscription login (claude.ai / firstParty), "
                                              "no API billing path; the Keychain API key is not read. Opt-in mode: check Anthropic's terms for unattended `claude -p`")
            elif ready.kind == "billing_mode_violation":
                d.add("FAIL", "billing mode", ready.error)
            else:
                d.add("FAIL", "claude login", ready.error)
    else:
        d.add("FAIL", "claude cli", f"CLAUDE_BIN {claude_bin} not found or not executable")
    leaked = note.polluted_parent_env()
    if leaked:
        d.add("WARN", "environment", f"{', '.join(leaked)} set in this shell: ignored by the pipeline (allow-list env), "
                                     "but unset them to avoid confusion")
    marker = overage.read_marker(cfg)
    if apikey.is_api(cfg):
        d.add("PASS", "overage guard", "not used in api mode (CLAUDE_AUTH=api): the Console key has no subscription window; "
                                       "NOTE_STOP_ON_OVERAGE is ignored and nothing is written to overage.json")
    elif marker and cfg.note_stop_on_overage:
        d.add("WARN", "overage guard", overage.describe(marker) + f" (delete {cfg.overage_path} to clear)")
    elif marker:
        d.add("WARN", "overage guard", f"extra-usage billing was reported until {overage.format_epoch(marker.get('expires'))}; notes "
              f"continue (NOTE_STOP_ON_OVERAGE=0, allowed on purpose; marker {cfg.overage_path})")
    elif cfg.note_stop_on_overage:
        d.add("PASS", "overage guard", "no active extra-usage marker (NOTE_STOP_ON_OVERAGE=1)")
    else:
        d.add("PASS", "overage guard", "extra usage is allowed on purpose (NOTE_STOP_ON_OVERAGE=0): it is only logged, "
                                       "recorded in overage.json and shown as a warning, never blocking")


def _doctor_claude_budget(d: "_Doctor", cfg: Config) -> None:
    """The per-meeting call cap and the seven-day call / cost summary of usage.jsonl."""
    reserve = usage.planned_reserve(calendar=calendar_lookup.enabled(cfg), verify=cfg.note_verify)
    needed = sum(reserve.values())
    if cfg.max_claude_calls_per_meeting < needed:
        d.add("WARN", "claude call cap", f"MAX_CLAUDE_CALLS_PER_MEETING={cfg.max_claude_calls_per_meeting} is below {needed}: the note "
              f"is always made ({usage.NOTE_RESERVE} calls kept for it), but the calendar lookup, the verification and the transcript "
              "cleanup are skipped or squeezed when the cap is that low")
    else:
        d.add("PASS", "claude call cap", f"MAX_CLAUDE_CALLS_PER_MEETING={cfg.max_claude_calls_per_meeting} per meeting run: the note "
              f"(+ calendar / verification when on) keeps {needed} call(s), the transcript cleanup "
              + (f"uses up to {cfg.max_claude_calls_per_meeting - needed}" if cfg.transcript_cleanup else "is off"))
    summary = usage.week_summary(cfg)
    d.add("WARN" if summary["skipped_by_cap"] else "PASS", "claude usage", usage.one_line(summary) + f" [{usage.usage_path(cfg)}]")
    d.add("PASS", "claude cost", usage.cost_one_line(usage.cost_windows(cfg)) + " (mcap usage shows it by stage)")


def run_doctor(cfg: Config, *, warmup: bool = True, out: Callable[[str], None] = print, share: bool = False, claude_pin_run=None) -> int:
    """The checks of `mcap doctor`. Without an organisation policy (and without an external ASR engine in the config) every line is what it
    was before SPEC 18. With one the doctor is LANE-AWARE: a lane the organisation denies (or a locked local-only flag) is not checked and is
    never a FAIL (``skipped: lane denied``), the local archive is checked instead of the Drive folder, and the policy, the route, the consents
    and the device rules of ``_doctor_policy`` are added. An OPEN llm lane under a company policy still needs the claude binary to match the
    policy's signature pin: when it does not, no claude process is started and ``claude cli`` is a FAIL (the pipeline would close the lane the
    same way). ``share`` removes the home folder and e-mail addresses from every line. ``claude_pin_run``: the codesign runner (tests)."""
    if share:
        raw_out = out
        out = lambda line: raw_out(share_filter(line))                     # noqa: E731
    d = _Doctor(out)
    view = _OrgView(cfg, status.load_policy(cfg))
    llm_off = view.denied("llm")
    calendar_off = view.denied("calendar")
    drive_off = view.denied("drive")
    external = bool(named_external_engines(cfg))
    remote_only = _remote_only(cfg)

    # config / files
    cfg_path = Path(os.environ.get("MCAP_CONFIG") or DEFAULT_SUPPORT_DIR / "config.env")
    if cfg_path.exists():
        d.add("PASS", "config", f"{cfg_path}")
    else:
        d.add("WARN", "config", f"{cfg_path} not found: built-in defaults are in use")
    if Path(cfg.support_dir).is_dir():
        d.add("PASS", "support dir", str(cfg.support_dir))
    else:
        d.add("WARN", "support dir", f"{cfg.support_dir} does not exist yet (the installer creates it)")
    vocab = pipeline.load_vocab_for(cfg)
    vpath = next((p for p in (Path(cfg.vocab_path), Path(cfg.repo_config_dir) / "vocabulary.txt") if p.is_file()), None)
    if vpath:
        d.add("PASS", "vocabulary", f"{len(vocab.terms)} terms from {vpath}")
    else:
        d.add("WARN", "vocabulary", "vocabulary.txt not found (ASR prompt and notes get no domain terms)")
    for label, filename, needed in (("note prompt", note.PROMPT_NOTE, True),
                                    ("cleanup prompt", note.PROMPT_CLEANUP, cfg.transcript_cleanup),
                                    ("verify prompt", note.PROMPT_VERIFY, cfg.note_verify)):
        _doctor_prompt(d, cfg, label, filename, needed and not llm_off)
    for label, on, what in (("transcript cleanup", cfg.transcript_cleanup, "TRANSCRIPT_CLEANUP"),
                            ("note verify", cfg.note_verify, "NOTE_VERIFY")):
        if llm_off:
            d.add("PASS", label, f"skipped: lane denied (llm: {llm_off})")
        else:
            d.add("PASS", label, f"{what}=" + ("on" if on else "off (that pass is skipped)"))
    for key, value in _unrecognised_switches():
        d.add("WARN", "config", f"{key}={value!r} is not recognised and is treated as OFF (use 1 or 0)")
    for text in cfg.config_warnings:                       # SPEC 18 keys: an unrecognised switch / engine word is read as its restrictive value
        d.add("WARN", "config", text)

    # python / mlx / models
    python_bin = Path(cfg.python_bin)
    if python_bin.is_file() and os.access(python_bin, os.X_OK):
        d.add("PASS", "python", f"{python_bin}" + ("" if Path(sys.executable).resolve() == python_bin.resolve()
                                                    else f" (doctor itself runs under {sys.executable})"))
    else:
        d.add("FAIL", "python", f"PYTHON_BIN {python_bin} not found (run scripts/setup_python.sh)")
    try:
        import numpy
        d.add("PASS", "numpy", numpy.__version__)
    except ImportError as exc:
        d.add("FAIL", "numpy", f"cannot import: {exc}")
    probe_python = str(python_bin) if python_bin.is_file() and os.access(python_bin, os.X_OK) else sys.executable
    if warmup:
        t0 = time.monotonic()
        try:
            p = subprocess.run([probe_python, "-c", "import mlx.core, mlx_whisper"], capture_output=True, text=True,
                               timeout=300, stdin=subprocess.DEVNULL)
            if p.returncode == 0:
                d.add("PASS", "mlx warm-up", f"mlx + mlx_whisper import ok ({time.monotonic() - t0:.1f} s, python {probe_python})")
            elif remote_only:
                d.add("PASS", "mlx warm-up", "not needed (ASR_ENGINE=remote: the company server transcribes, mlx is not installed here)")
            else:
                tail = (p.stderr.strip().splitlines() or ["unknown error"])[-1]
                d.add("FAIL", "mlx warm-up", f"import failed: {tail}")
        except (OSError, subprocess.SubprocessError) as exc:
            d.add("FAIL", "mlx warm-up", f"{type(exc).__name__}: {exc}")
    else:
        d.add("WARN", "mlx warm-up", "skipped (--no-warmup): the first run imports mlx (about 24 s)")
    cached, where = model_cache_status(cfg.asr_model)
    if remote_only and not cached:
        d.add("PASS", "asr model", f"{cfg.asr_model}: not needed (ASR_ENGINE=remote)")
    else:
        d.add("PASS" if cached else "WARN", "asr model", f"{cfg.asr_model}: {where}")
    silero = silero_model_path(cfg)
    if cfg.asr_vad == "energy":
        d.add("PASS", "silero vad", "not needed (ASR_VAD=energy)")
    elif silero:
        d.add("PASS", "silero vad", str(silero))
    elif cfg.asr_vad == "silero":
        d.add("FAIL", "silero vad", "ASR_VAD=silero but silero_vad.onnx was not found (scripts/setup_python.sh --with-silero)")
    else:
        d.add("WARN", "silero vad", "model not found: the energy VAD fallback will be used (ASR_VAD=auto)")
    if view.active or external:
        _doctor_policy(d, cfg, view, external)

    # claude (SPEC 17: the checks follow the billing mode, and the billing line says which one is on)
    pin_block = None if llm_off else _claude_pin_block(cfg, view, claude_pin_run)
    if llm_off:
        d.add("PASS", "claude cli", f"skipped: lane denied (llm: {llm_off}); no Claude check is made on this Mac")
    elif pin_block is not None:
        detail = re.search(r"\(([^()]*)\)\s*$", pin_block.message)
        d.add("FAIL", "claude cli", f"{pin_block.reason}: {cfg.claude_bin} does not match the organisation policy's signature pin"
              + (f" ({detail.group(1)})" if detail else "")
              + "; no claude process was started (the llm lane stays closed until the pinned claude is installed)")
    else:
        _doctor_claude(d, cfg, calendar_off, dict(view.org.llm_child_env) if view.active and view.org.valid else None)
    if calendar_off:
        d.add("PASS", "calendar", f"skipped: lane denied (calendar: {calendar_off})")
    elif calendar_lookup.enabled(cfg):
        d.add("PASS", "calendar", f"CALENDAR_LOOKUP={cfg.calendar_lookup}: best effort at note time, read-only, only events within "
                                  f"+-{int(calendar_lookup.WINDOW_MARGIN.total_seconds() // 60)} minutes of the recording start are "
                                  "requested and only the matched event is kept (set CALENDAR_LOOKUP=0 to switch it off)")
    else:
        d.add("PASS", "calendar", f"CALENDAR_LOOKUP={cfg.calendar_lookup}: switched off (no calendar data is requested)")
    if llm_off:
        d.add("PASS", "claude usage", f"skipped: lane denied (llm: {llm_off})")
    else:
        _doctor_claude_budget(d, cfg)

    # archive / tools
    archive = Path(cfg.archive_dir)
    if drive_off:
        d.add("PASS", "archive dir", f"skipped: lane denied (drive: {drive_off}); meetings are kept in the local archive")
    elif archive.is_dir():
        reason = _write_probe(archive)
        d.add("FAIL" if reason else "PASS", "archive dir", f"{archive}" + (f" is not writable: {reason}" if reason else " (writable)"))
    elif archive.parent.is_dir():
        reason = _write_probe(archive.parent)
        d.add("FAIL" if reason else "PASS", "archive dir",
              f"{archive} does not exist yet; " + (f"parent is not writable: {reason}" if reason else "parent exists and is writable, it will be created"))
    else:
        d.add("FAIL", "archive dir", f"parent {archive.parent} does not exist (Google Drive not running or not mounted?)")
    if view.active:
        _doctor_local_archive(d, cfg, view)
    afconvert = shutil.which("afconvert") or ("/usr/bin/afconvert" if os.access("/usr/bin/afconvert", os.X_OK) else None)
    d.add("PASS" if afconvert else "FAIL", "afconvert", afconvert or "not found (needed to encode m4a)")

    d.out(f"doctor: {d.counts['PASS']} PASS, {d.counts['WARN']} WARN, {d.counts['FAIL']} FAIL")
    return EXIT_FAILED if d.counts["FAIL"] else EXIT_OK


def cmd_doctor(args, deps=None) -> int:
    share = bool(getattr(args, "share", False))
    out = (lambda line: print(share_filter(line))) if share else print
    try:
        cfg = load_config()
    except ValueError as exc:
        out(f"[FAIL] config: {exc}")
        out("doctor: 0 PASS, 0 WARN, 1 FAIL")
        return EXIT_FAILED
    return run_doctor(cfg, warmup=not args.no_warmup, share=share)



# ---------------------------------------------------------------------------------- asr-engines
# `mcap asr-engines list|check|bench|consent|enroll|revoke|purge|secret` is the terminal side of the external ASR engines. It is the ONLY place
# that records a consent (a typed phrase on a TTY), stores a credential (the macOS security tool types it, this program never sees it) and
# sends anything to a server on request (`check --live`: the health request and ONE synthetic 1-second tone; `bench`: synthetic clips unless
# the user confirms in the terminal that real audio of a meeting with nobody else in it may go). Everything printed is content-free: no
# transcript text, no token, no code, no host in a list that may be pasted (labels instead).
REAL_AUDIO_PHRASE = "참석자는 나뿐입니다"                  # typed to let REAL audio go to an external engine (SPEC 18 bench)
CONSENT_PHRASE = "동의합니다 {engine}@{host}"                # typed to record a consent (SPEC 18 consent)
CONSENT_DEFAULT_DAYS = 180                                 # how long a consent given at the terminal lasts (--days; at most CONSENT_MAX_DAYS)
CONSENT_MAX_DAYS = 365
SYNTH_SECONDS = 20.0                                       # length of the synthetic benchmark clip (the capability probe uses 20 s too)
TONE_SECONDS = 1.0                                         # the one synthetic tone of `check --live`
REQUEST_SECONDS = 25.0                                     # bench: the longest audio sent in one request (the engines take at most 28 s)
SR = 16000
# the codes of the policy part of the decision table (3.3 A0/A2): what `list` calls 'denied by policy' as against consent / configuration
POLICY_REASONS = frozenset({"policy-locked", "local_only", "policy-lane", "policy-unapproved", "policy-engine", "policy-host",
                            "policy-foreign"})


@dataclasses.dataclass
class AsrDeps:
    """Collaborators of ``cmd_asr_engines`` that a test replaces (everything defaults to the real thing). ``transport_factory()`` gives the
    ``egress.Transport`` of an external engine's guard (default: the real HTTPS transport); ``run`` is the process runner of the hardware
    probe (sysctl, ioreg, the benchmark child); ``security_run`` runs the macOS ``security`` tool; ``local_engine(cfg)`` makes the local
    engine ``bench`` / ``bench-synth`` measure (default: ``asr_engines.get_engine(cfg.asr_model, allow_download=False)``); ``machine_id`` is
    the full machine id the consents are bound to (default: this Mac's); ``now`` the clock of every decision; ``sleep`` / ``clock`` those of
    the engines."""
    transport_factory: Optional[Callable[[], Any]] = None
    run: Optional[Callable] = None
    security_run: Callable = subprocess.run
    local_engine: Optional[Callable[[Any], Any]] = None
    machine_id: Optional[str] = None
    now: Optional[datetime] = None
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic


def _is_tty() -> bool:
    return sys.stdin is not None and sys.stdin.isatty()


def _ask(prompt: str) -> Optional[str]:
    """One line typed by the user, or None at the end of input."""
    try:
        return input(prompt)
    except EOFError:
        return None


def _confirm(prompt: str) -> bool:
    answer = _ask(prompt)
    return answer is not None and answer.strip().lower() in ("y", "yes")


def synthetic_tone(seconds: float = TONE_SECONDS):
    """A 440 Hz sine, float32 mono 16 kHz, quiet: what ``check --live`` sends (no audio of the user's, nothing a person said)."""
    import numpy as np
    t = np.arange(int(seconds * SR), dtype=np.float64) / SR
    return (0.2 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)


def synthetic_audio(seconds: float = SYNTH_SECONDS):
    """A deterministic speech-like clip (float32 mono 16 kHz): a gliding voice pitch with formant-weighted harmonics, syllable-rate
    amplitude and a little noise. It is not speech (an engine makes nothing of it) but it costs a decoder what speech costs, so it measures
    latency, real-time factor and the whole request path without any recorded voice leaving the Mac. Same output on every call."""
    import numpy as np
    n = int(seconds * SR)
    t = np.arange(n, dtype=np.float64) / SR
    pitch = 120.0 + 25.0 * np.sin(2 * np.pi * 0.3 * t)                      # a slowly moving fundamental
    phase = 2 * np.pi * np.cumsum(pitch) / SR
    voice = np.zeros(n)
    for k in range(1, 31):
        freq = k * pitch
        weight = np.exp(-((freq - 700.0) / 350.0) ** 2) + 0.6 * np.exp(-((freq - 1800.0) / 600.0) ** 2) + 0.05
        voice += weight * np.sin(k * phase) / k
    syllable = np.clip(np.sin(2 * np.pi * 3.5 * t), 0.0, None) ** 0.7        # about 3.5 syllables per second with a pause between them
    rng = np.random.default_rng(20261014)
    clip = 0.35 * voice / max(float(np.max(np.abs(voice))), 1e-9) * syllable + 0.01 * rng.standard_normal(n)
    return np.clip(clip, -1.0, 1.0).astype(np.float32)


def policy_denial(org, engine: str, binding: dict) -> Optional[str]:
    """The organisation-level reason an external engine may not be used at its configured destination (decision table 3.3 A0 and A2 without
    consent, cap and hardware): the policy is locked, the flag is locked to local-only, the lane is denied (or unapproved), the engine or the
    host is not on the allow list, a foreign engine without ``allow_foreign``. None = the policy lets it be used (no policy: always)."""
    meta = policy_mod.ENGINE_META[engine]
    if org.locked:
        return "policy-locked"
    if org.valid and org.local_only_locked:
        return "local_only"
    if org.lanes.get(meta["lane"], "deny") != "allow":
        return org.lane_reasons.get(meta["lane"], "policy-lane")
    if org.allowed_engines is not None and engine not in org.allowed_engines:
        return "policy-engine"
    if org.allowed_hosts is not None and binding["host"] not in org.allowed_hosts:
        return "policy-host"
    if meta["residency"] == "foreign" and not org.allow_foreign:
        return "policy-foreign"
    return None


def destination_label(binding: dict) -> str:
    """What a destination is called outside the local files: ``company-asr`` for a server, ``<engine>/<region>`` for a cloud engine."""
    return "company-asr" if binding["kind"] == "server" else f"{binding['engine']}/{binding['region'] or 'default'}"


class _AsrContext:
    """The inputs every asr-engines command decides with: the policy, the consents, the clock and this Mac's machine id (read once)."""

    def __init__(self, cfg: Config, deps: AsrDeps):
        self.cfg, self.deps = cfg, deps
        self.now = status.aware(deps.now)
        self.machine = deps.machine_id if deps.machine_id is not None else policy_mod.machine_id(run=deps.run or subprocess.run)
        self.org = status.load_policy(cfg)
        self.consents = status.load_consent_set(cfg, self.now, machine=self.machine)

    def decision(self, engine: str, hw=None, used: Optional[float] = None):
        """The ASR decision of a run that asks for ``engine`` as its primary (``decide_asr``): ``decision.primary == engine`` means it may be
        used, else ``decision.reason`` says why not. The per-meeting flag counts only through a lock (this is the organisation's view)."""
        run_cfg = dataclasses.replace(self.cfg, asr_engine=engine, asr_fallback="none")
        if used is None:
            try:
                from . import asr_usage
                used = asr_usage.minutes_today(self.cfg, now=self.now)
            except Exception:
                used = 0.0
        return policy_mod.decide_asr(run_cfg, self.org, status.lane_view_local_only(self.org), self.consents, hw, used_minutes_today=used,
                                     now=self.now)

    def build(self, engine: str, decision, vocab=None):
        """The external engine of ``decision`` without a router (``asr_router.build_member``: guard, lane gate, daily cap)."""
        from . import asr_router
        return asr_router.build_member(self.cfg, vocab, decision, engine, transport_factory=self.deps.transport_factory,
                                       sleep=self.deps.sleep, clock=self.deps.clock)


class EngineRefused(RuntimeError):
    """An external engine may not be used right now (policy, consent, configuration): ``reason`` is the code of the decision table."""

    def __init__(self, engine: str, reason: str):
        super().__init__(f"{engine} is refused ({reason}): it needs the organisation policy's lane, a consent (mcap asr-engines consent {engine}) "
                         "and a configured destination")
        self.engine, self.reason = engine, reason


def asr_context(cfg: Config, deps: Optional[AsrDeps] = None) -> _AsrContext:
    """The policy, consents, clock and machine id the engine decisions are made with (for tools outside this module: scripts/bench_asr.py)."""
    return _AsrContext(cfg, deps or AsrDeps())


def open_external_engine(cfg: Config, engine: str, deps: Optional[AsrDeps] = None):
    """An external engine for a tool that benchmarks it, built from the decision a pipeline run would make (``decide_asr``): ``EngineRefused``
    when the policy, the consent or the configuration say no. There is no way around the gate: the benchmark tools use this function."""
    ctx = asr_context(cfg, deps)
    decision = ctx.decision(engine)
    if decision.primary != engine:
        raise EngineRefused(engine, decision.reason)
    return ctx.build(engine, decision)


def _external_ready(engine: str) -> Optional[str]:
    """None when ``engine`` names an external engine with an adapter, else the sentence that says why not."""
    meta = policy_mod.ENGINE_META.get(engine)
    if meta is None:
        return f"unknown engine {engine!r} (known: {', '.join(policy_mod.ENGINE_META)})"
    if meta["kind"] == "local":
        return f"{engine} is a local engine: it needs no consent, credential or server"
    if meta["status"] != "ready":
        return f"{engine} has no adapter in this version (status {meta['status']})"
    return None


# ---- list
def _usage_by_engine(cfg: Config, now: datetime) -> dict:
    """engine -> (timestamp, circuit) of its newest asr-usage line of the last 30 days (content-free: no host is read)."""
    seen: dict = {}
    try:
        from . import asr_usage
        for entry, ts in asr_usage.read_entries(cfg, now - timedelta(days=30)):
            engine = entry.get("engine")
            if isinstance(engine, str) and (engine not in seen or ts >= seen[engine][0]):
                circuit = entry.get("circuit")
                seen[engine] = (ts, circuit if circuit in ("closed", "half-open", "open") else None)
    except Exception:
        log.debug("asr usage unreadable", exc_info=True)
    return seen


def engine_rows(cfg: Config, ctx: _AsrContext) -> list[dict]:
    """One row per engine of ``policy.ENGINE_META`` for ``asr-engines list`` (strings and booleans only)."""
    from . import asr_creds
    recent = _usage_by_engine(cfg, ctx.now)
    rows = []
    for engine, meta in policy_mod.ENGINE_META.items():
        row = {"engine": engine, "kind": meta["kind"], "residency": meta["residency"], "status": meta["status"], "destination": "-",
               "policy": "n/a", "consent": "n/a", "credential": "n/a", "settings": asr_providers.settings_summary(cfg, engine), "circuit": "n/a",
               "last_used": None, "usable": False}
        if meta["kind"] == "local":
            row.update(destination="this Mac", policy="not restricted", consent="not needed", credential="not needed",
                       usable=meta["status"] == "ready")
        elif meta["status"] != "ready":
            row.update(consent="no adapter")
        else:
            state = status.consent_state(cfg, engine, ctx.org, ctx.consents, ctx.now)
            row["consent"] = state["state"] + (f" (until {state['expires']})" if state["state"] == "ok" else "")
            binding, _why = policy_mod.consent_binding(cfg, engine)
            if binding is not None:
                denial = policy_denial(ctx.org, engine, binding)
                row.update(destination=destination_label(binding), policy="allowed" if denial is None else f"denied ({denial})",
                           usable=ctx.decision(engine).primary == engine)
                cred = asr_creds.secret_status(engine, binding["host"], binding["port"], run=ctx.deps.security_run)
                row["credential"] = ("stored" if cred["present"] else "missing" if cred["reason"] == "missing" else f"missing ({cred['reason']})")
                if not cred["present"] and cred["reason"] == "missing" and asr_providers.secret_note(engine) == "optional":
                    row["credential"] = "none (optional)"                              # a server without a key is a legitimate setup
        if engine in recent:
            stamp, circuit = recent[engine]
            row.update(last_used=stamp.isoformat(timespec="seconds"), circuit=circuit or "n/a")
        rows.append(row)
    return rows


def _asr_list(cfg: Config, args, deps: AsrDeps) -> int:
    rows = engine_rows(cfg, _AsrContext(cfg, deps))
    if args.json:
        print(json.dumps({"schema": 1, "engines": rows}, ensure_ascii=False, indent=2))
        return EXIT_OK
    columns = (("engine", "engine"), ("kind", "kind"), ("residency", "residency"), ("status", "status"), ("destination", "destination"),
               ("policy", "policy"), ("consent", "consent"), ("credential", "credential"), ("settings", "settings"), ("circuit", "circuit"),
               ("last_used", "last used"), ("usable", "usable"))
    table = [[title for _k, title in columns]]
    for row in rows:
        table.append([("yes" if row[k] else "no") if isinstance(row[k], bool) else str(row[k] if row[k] is not None else "-") for k, _t in columns])
    widths = [max(len(r[i]) for r in table) for i in range(len(columns))]
    for r in table:
        print("  ".join(cell.ljust(w) for cell, w in zip(r, widths)).rstrip())
    return EXIT_OK


# ---- check
def _mark(ok: Optional[bool]) -> str:
    return "[ok]  " if ok else ("[warn]" if ok is None else "[FAIL]")


def _static_check(ctx: _AsrContext, engine: str) -> tuple[list, list, Any]:
    """(lines, problems, decision) of the static check of one external engine; no request is made and no secret is read."""
    cfg, lines, problems = ctx.cfg, [], []
    binding, why = policy_mod.consent_binding(cfg, engine)
    if binding is None:
        return [f"{_mark(False)} destination: not configured ({why}): set {_setup_settings(engine, 'ASR_REMOTE_URL / ASR_AZURE_REGION')} in config.env"], \
            [f"{engine}: not configured ({why})"], None
    lines.append(f"{_mark(True)} destination: {destination_label(binding)} ({binding['kind']}, {policy_mod.ENGINE_META[engine]['residency']})")
    denial = policy_denial(ctx.org, engine, binding)
    if denial:
        lines.append(f"{_mark(False)} policy: denied ({denial})")
        problems.append(f"{engine}: denied by policy ({denial})")
    else:
        lines.append(f"{_mark(True)} policy: " + ("no organisation policy" if not ctx.org.present else "allowed"))
    state = status.consent_state(cfg, engine, ctx.org, ctx.consents, ctx.now)
    if state["state"] == "ok":
        lines.append(f"{_mark(True)} consent: {state['source']} consent {state['id']}, use {state['use']}, valid until {state['expires']}")
    else:
        lines.append(f"{_mark(False)} consent: {state['state']}: run `mcap asr-engines consent {engine}`")
        problems.append(f"{engine}: consent {state['state']}")
    decision = ctx.decision(engine)
    if not denial and state["state"] == "ok" and decision.primary != engine:
        lines.append(f"{_mark(False)} decision: excluded ({decision.reason})")
        problems.append(f"{engine}: excluded ({decision.reason})")
    if decision.primary == engine:
        from . import asr_engines
        try:
            member = ctx.build(engine, decision)
            issues = member.preflight(run=ctx.deps.security_run)
        except asr_engines.EngineUnavailable as exc:
            issues = [f"no adapter ({exc})"]
        except asr_engines.EngineError as exc:
            issues = [str(exc)]
        for issue in issues:
            lines.append(f"{_mark(False)} {apikey.redact(issue)}")
            problems.append(f"{engine}: {apikey.redact(issue)}")
        if not issues:
            if asr_providers.secret_note(engine) == "optional":
                lines.append(f"{_mark(True)} the credential is optional: a key is sent only when one is stored (the value is not read)")
            else:
                lines.append(f"{_mark(True)} private CA bound and a credential is stored (the value is not read)" if binding["kind"] == "server"
                             else f"{_mark(True)} a credential is stored (the value is not read)")
    return lines, problems, decision


def _live_check(ctx: _AsrContext, engine: str, decision) -> list:
    """`check --live` for one engine: health (token, retention, backend kind, attestation) and ONE chunk request with a 1 s synthetic tone.
    Prints latency, what the server attests and what it keeps; never the answer's text. Returns the problems."""
    from . import asr_engines
    clock = ctx.deps.clock
    try:
        member = ctx.build(engine, decision)
    except (asr_engines.EngineError, asr_engines.EngineUnavailable) as exc:
        print(f"{_mark(False)} live: {apikey.redact(str(exc))}")
        return [f"{engine}: {apikey.redact(str(exc))}"]
    try:
        started = clock()
        member.load()                                           # the health check: authentication, protocol, retention, backend kind, attestation
        health_ms = int((clock() - started) * 1000)
        health = getattr(member, "health", None) or {}
        attest = (health.get("attest") or {}).get("build_sha256") or ""
        build = f"{attest[:8]}" if attest else "none"
        allow = sorted({b for oc in ctx.org.org_consents if oc.engine == engine for b in oc.attest_build_sha256}) if ctx.org.valid else []
        listed = ("in the policy allow list" if attest in allow else "NOT in the policy allow list") if allow else "no allow list in the policy"
        retention = (health.get("retention") or {}).get("mode")
        left = (health.get("token") or {}).get("expires_in_days")
        print(f"{_mark(True)} health: ok in {health_ms} ms; backend kind {health.get('kind') or '?'}, retention {retention or '?'}, attest build "
              f"{build} ({listed})" + (f", token valid for {int(left)} more day(s)" if left is not None else ""))
        started = clock()
        answer = member.transcribe_chunk(synthetic_tone(TONE_SECONDS), "en", None)
        chunk_ms = int((clock() - started) * 1000)
        print(f"{_mark(True)} chunk: one {TONE_SECONDS:g} s synthetic tone answered in {chunk_ms} ms ({len(answer.get('segments') or [])} segment(s); "
              "the text is not shown)")
        used = member.usage()
        print(f"       sent: {used.get('requests', 0)} chunk request(s), {used.get('audio_s', 0)} s of audio, {used.get('bytes', 0)} bytes")
        return []
    except asr_engines.EngineError as exc:
        message = apikey.redact(str(exc))
        print(f"{_mark(False)} live: {message}")
        return [f"{engine}: {message}"]
    finally:
        member.release()


def _live_gate(args, label: str) -> Optional[int]:
    """The confirmation of `check --live`: a yes in the terminal (or --yes for a script). The exit code to stop with, None = go ahead."""
    if args.yes:
        return None
    if not _is_tty():
        print("error: check --live contacts the server: run it in a terminal (or pass --yes)", file=sys.stderr)
        return EXIT_USAGE
    if not _confirm(f"Contact {label} now? It sends a health request and ONE synthetic {TONE_SECONDS:g} s tone (nothing of yours) [y/N] "):
        print("cancelled")
        return EXIT_FAILED
    return None


def _probe_runner(deps: AsrDeps) -> Callable:
    """The process runner of the hardware probe. The benchmark child is `python -m mcap ...`: it needs THIS code on its path, whatever the
    working directory of the terminal is."""
    base = deps.run or subprocess.run
    if deps.run is not None:
        return base
    package_parent = str(Path(__file__).resolve().parents[1])

    def run(argv, **kwargs):
        if "bench-synth" in argv:
            env = dict(kwargs.pop("env", None) or os.environ)
            env["PYTHONPATH"] = package_parent + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
            return base(argv, cwd=package_parent, env=env, **kwargs)
        return base(argv, **kwargs)
    return run


def _print_probe(hw) -> None:
    print(f"hardware: {hw.arch}, {hw.mem_gb or 'unknown'} GB RAM, mlx {_yn(hw.mlx_ok)}, model on disk {_yn(hw.model_present)}, "
          f"measured real-time factor {hw.rtf if hw.rtf is not None else 'not measured'}"
          + (f" (probed {hw.probed_at})" if hw.probed_at else ""))
    print(f"local engine capable: {_yn(hw.capable)}" + (f" ({', '.join(hw.reasons)})" if hw.reasons else ""))


def _asr_check(cfg: Config, args, deps: AsrDeps) -> int:
    ctx = _AsrContext(cfg, deps)
    if args.engine:
        problem = _external_ready(args.engine)
        if problem:
            print(f"error: {problem}", file=sys.stderr)
            return EXIT_USAGE
        engines = [args.engine]
    else:
        engines = named_external_engines(cfg)
    problems: list = []
    if not engines:
        print("no external ASR engine is configured (ASR_ENGINE=whisper): transcription stays on this Mac")
    if args.live and engines:
        label = ", ".join(engines)
        stop = _live_gate(args, label)
        if stop is not None:
            return stop
    for engine in engines:
        meta = policy_mod.ENGINE_META[engine]
        print(f"{engine} ({meta['kind']}, {meta['residency']})")
        lines, issues, decision = _static_check(ctx, engine)
        for line in lines:
            print("  " + line)
        problems += issues
        if args.live and not issues and decision is not None:
            problems += _live_check(ctx, engine, decision)
    if args.probe:
        try:
            hw = policy_mod.probe_hardware(cfg, run=_probe_runner(deps), now=ctx.now, measure=True)
        except policy_mod.ProbeRefused:
            print("refused: a recording is in progress; the 20 s benchmark would take CPU from the capture (try again after it)", file=sys.stderr)
            return EXIT_BUSY
        _print_probe(hw)
        if "bench-failed" in hw.reasons:
            problems.append("the benchmark failed (see `mcap asr-engines bench-synth --seconds 20`)")
    if problems:
        print(f"check: {len(problems)} problem(s)")
        return EXIT_FAILED
    print("check: ok")
    return EXIT_OK


# ---- bench-synth (the child of `check --probe`) and bench
def _local_engine(cfg: Config, deps: AsrDeps):
    if deps.local_engine is not None:
        return deps.local_engine(cfg)
    from . import asr_engines
    return asr_engines.get_engine(cfg.asr_model, allow_download=False)       # a benchmark never downloads a model


def _time_chunks(engine, audio, clock: Callable[[], float]) -> dict:
    """Run ``audio`` through ``engine`` in requests of at most REQUEST_SECONDS: ``{audio_s, elapsed_s, rtf, requests, segments}``."""
    step, pos, requests, segments = int(REQUEST_SECONDS * SR), 0, 0, 0
    started = clock()
    while pos < len(audio):
        piece = audio[pos:pos + step]
        pos += len(piece)
        answer = engine.transcribe_chunk(piece, "en", None)
        requests += 1
        segments += len((answer or {}).get("segments") or [])
    elapsed = max(clock() - started, 1e-9)
    seconds = len(audio) / SR
    return {"audio_s": round(seconds, 2), "elapsed_s": round(elapsed, 3), "rtf": round(elapsed / seconds, 4) if seconds else None,
            "requests": requests, "segments": segments}


def _asr_bench_synth(cfg: Config, args, deps: AsrDeps) -> int:
    """`asr-engines bench-synth --seconds N [--json]`: the real-time factor of the LOCAL engine on a synthetic clip (a warm-up of 2 s first,
    so loading and compiling are not counted). The last stdout line is ``{"rtf": ...}``: ``policy.probe_hardware`` reads it."""
    engine = None
    try:
        engine = _local_engine(cfg, deps)
        engine.load()
        engine.transcribe_chunk(synthetic_audio(2.0), "en", None)
        result = _time_chunks(engine, synthetic_audio(max(1.0, float(args.seconds))), deps.clock)
    except Exception as exc:
        print(f"FAILED: the benchmark could not run: {type(exc).__name__}: {apikey.redact(str(exc))[:200]}", file=sys.stderr)
        return EXIT_FAILED
    finally:
        if engine is not None:
            try:
                engine.release()
            except Exception:
                log.debug("engine release failed", exc_info=True)
    record = {"rtf": result["rtf"], "seconds": result["audio_s"], "elapsed_s": result["elapsed_s"], "engine": "whisper"}
    if not args.json:
        print(f"synthetic benchmark: {result['audio_s']} s of audio in {result['elapsed_s']} s")
    print(json.dumps(record))
    return EXIT_OK


def real_audio_gate(engines: list[str]) -> Optional[int]:
    """The confirmation that lets REAL audio go to an external engine: a terminal, and the typed sentence that the
    meeting had no other participants. The exit code to stop with (2: not a terminal, 1: the sentence did not match), None = confirmed.
    Shared by `mcap asr-engines bench` and scripts/bench_asr.py."""
    if not _is_tty():
        print("error: real audio goes to an external engine only after a confirmation typed in a terminal (stdin is not a TTY)", file=sys.stderr)
        return EXIT_USAGE
    print(f"The audio file(s) will be SENT to: {', '.join(engines)}.\n"
          "Use real audio only from a meeting where you were the only participant (otherwise use the synthetic clips: leave out "
          "--allow-real-audio). A recording with other people's voices must not leave this Mac for a benchmark.")
    answer = _ask(f"To confirm, type exactly: {REAL_AUDIO_PHRASE}\n> ")
    if answer is None or answer.strip() != REAL_AUDIO_PHRASE:
        print("cancelled: the sentence did not match; nothing was sent", file=sys.stderr)
        return EXIT_FAILED
    return None


def _decode_clip(path: Path, seconds: float):
    audio = pipeline.decode_audio_16k(path)
    return audio[:int(seconds * SR)] if seconds > 0 else audio


def _asr_bench(cfg: Config, args, deps: AsrDeps) -> int:
    """`asr-engines bench [audio ...] [--engine E ...] [--allow-real-audio]`: latency and real-time factor per engine; no text is printed.
    The default clip is synthetic. An external engine gets the audio FILES only with --allow-real-audio AND the typed confirmation of
    ``real_audio_gate``; without it the files are used for local engines only and the external engine gets the synthetic clip. An external
    engine needs the consent and policy of a run (`decide_asr`): there is no bench around the gate."""
    ctx = _AsrContext(cfg, deps)
    files = [Path(a).expanduser() for a in args.audio]
    for path in files:
        if not path.is_file():
            print(f"error: no such file: {path}", file=sys.stderr)
            return EXIT_USAGE
    if args.allow_real_audio and not files:
        print("error: --allow-real-audio needs at least one audio file", file=sys.stderr)
        return EXIT_USAGE
    names = args.engine or list(dict.fromkeys(("whisper" if e == "auto" else e) for e in policy_mod.requested_engines(cfg) if e != "none"))
    for name in names:
        if name not in policy_mod.ENGINE_META:
            print(f"error: unknown engine {name!r} (known: {', '.join(policy_mod.ENGINE_META)})", file=sys.stderr)
            return EXIT_USAGE
        if policy_mod.ENGINE_META[name]["status"] != "ready":
            print(f"error: {name} cannot be benchmarked here (status {policy_mod.ENGINE_META[name]['status']})", file=sys.stderr)
            return EXIT_USAGE
    external = [n for n in names if policy_mod.ENGINE_META[n]["kind"] != "local"]
    real_to_external = False
    if files and external and args.allow_real_audio:
        stop = real_audio_gate(external)
        if stop is not None:
            return stop
        real_to_external = True
    elif files and external:
        print(f"note: {len(files)} audio file(s) are NOT sent to {', '.join(external)} (add --allow-real-audio to confirm); "
              "a synthetic clip is used for the external engine(s)")
    seconds = float(args.seconds)
    failed = False
    for name in names:
        meta = policy_mod.ENGINE_META[name]
        engine, decision = None, None
        try:
            if meta["kind"] == "local":
                engine = _local_engine(cfg, deps)
            else:
                decision = ctx.decision(name)
                if decision.primary != name:
                    print(f"{name}: refused ({decision.reason}): an external engine needs the policy's lane and a consent "
                          f"(mcap asr-engines consent {name})")
                    failed = True
                    continue
                engine = ctx.build(name, decision)
            print(name)
            clips = [("synthetic", synthetic_audio(seconds))]
            if files and (meta["kind"] == "local" or real_to_external):
                real = [(f"file {i + 1}", _decode_clip(path, seconds)) for i, path in enumerate(files)]
                clips = real if meta["kind"] != "local" else real + clips      # what was confirmed to go out is all that goes out
            if hasattr(engine, "load"):
                engine.load()
            for label, audio in clips:
                result = _time_chunks(engine, audio, deps.clock)
                print(f"  {label}: {result['audio_s']} s in {result['elapsed_s']} s (real-time factor {result['rtf']}), "
                      f"{result['requests']} request(s), {result['segments']} segment(s)")
            used = engine.usage() if hasattr(engine, "usage") else {}
            if used:
                price = float(getattr(engine, "price_per_hour", lambda: 0.0)() or 0.0)
                cost = f", about ${used.get('audio_s', 0) / 3600.0 * price:.4f} (ASR_{name.upper()}_USD_PER_HOUR)" if price > 0 else ""
                print(f"  sent: {used.get('requests', 0)} request(s), {used.get('audio_s', 0)} s of audio, {used.get('bytes', 0)} bytes{cost}")
        except Exception as exc:                                   # one engine failing must not hide the others
            print(f"{name}: FAILED: {type(exc).__name__}: {apikey.redact(str(exc))[:200]}")
            failed = True
        finally:
            if engine is not None and hasattr(engine, "release"):
                try:
                    engine.release()
                except Exception:
                    log.debug("engine release failed", exc_info=True)
    return EXIT_FAILED if failed else EXIT_OK


# ---- consent / enroll / revoke / purge / secret
def _consent_lines(cfg: Config, ctx: _AsrContext, binding: dict, use: str, days: int, ca_hash: Optional[str]) -> list:
    engine = binding["engine"]
    server = binding["kind"] == "server"
    terms = 0
    try:
        terms = len(pipeline.load_vocab_for(cfg).terms)
    except Exception:
        pass
    sends_vocab = bool(cfg.asr_send_vocab) and ctx.org.send_vocab.get(binding["kind"], True)
    price = float(getattr(cfg, f"asr_{engine}_usd_per_hour", 0.0) or 0.0)
    caps = [int(cfg.asr_cloud_daily_minutes)] + ([ctx.org.daily_audio_minutes_cap] if ctx.org.daily_audio_minutes_cap is not None else [])
    until = (ctx.now.date() + timedelta(days=days)).isoformat()
    own = asr_providers.consent_overrides(cfg, binding, sends_vocab)           # {} for remote and azure: their text is exactly what it was
    lines = [
        "외부 전사 엔진에 회의 음성을 보내는 데 동의하는 절차입니다. 아래 내용을 읽고 확인하세요.",
        f"  엔진:        {engine} ({'회사 서버' if server else '클라우드'})",
        own.get("destination", f"  보내는 곳:   {binding['host']}:{binding['port']}" + (f" (리전 {binding['region']})" if binding["region"] else "")),
        own.get("sends", "  보내는 것:   에코 제거 후 발화 구간의 음성 조각(16 kHz mono, 한 번에 약 28초 이하)과 언어 식별용 짧은 클립. "
                "제목, 세션 ID, 플랫폼, 참석자, 파일명은 보내지 않습니다."),
        "  상대방 음성: 시스템 오디오 트랙이 포함되므로 원격 참석자의 목소리가 들어 있을 수 있습니다.",
        own.get("vocab", (f"  용어집:      ASR_SEND_VOCAB가 켜져 있어 vocabulary.txt의 용어 {terms}개가 함께 전송됩니다."
                          if sends_vocab else "  용어집:      용어는 전송하지 않습니다 (ASR_SEND_VOCAB 꺼짐 또는 정책이 제한).")),
        ("  보관:        서버는 오디오와 텍스트를 저장하지 않는다고 자기보고하며, 클라이언트가 매 실행 시작에 health로 확인합니다. "
         "서버의 백엔드가 클라우드이면 오디오는 그 벤더로 전달됩니다 (health의 kind와 vendor가 알려 줌)."
         if server else "  보관:        벤더의 보관 정책은 벤더의 주장이며 확인되지 않았습니다. 이 Mac이 확인할 수 없습니다."),
        own.get("price", (f"  단가 추정:   오디오 1시간당 약 ${price:g} (ASR_{engine.upper()}_USD_PER_HOUR, 추정일 뿐 실제 청구는 벤더 기준)"
                          if price > 0 else "  단가 추정:   알 수 없음 (ASR_" + engine.upper() + "_USD_PER_HOUR=0)")),
        f"  일일 상한:   하루 {min(caps)}분 (오디오 + 요청당 1초). 이 Mac의 기록이므로 참고용입니다.",
        f"  유효 기간:   {until}까지 ({days}일), 사용: {use}",
    ]
    if ca_hash:
        lines.append(f"  사설 CA:     sha256 {ca_hash[:16]}… ({cfg.asr_remote_ca_file.name if cfg.asr_remote_ca_file else '?'}): 이 호스트에는 이 CA만 신뢰합니다.")
    return lines


def _read_ca_hash(cfg: Config) -> tuple[Optional[str], Optional[str]]:
    """(sha256 hex of ASR_REMOTE_CA_FILE, None) or (None, why not): the hash a consent for a server binds the private CA to."""
    path = cfg.asr_remote_ca_file
    if not path:
        return None, "ASR_REMOTE_CA_FILE is not set: a server consent binds the private CA that signs the server certificate"
    try:
        with open(path, "rb") as fh:
            data = fh.read(1 << 20 | 1)
    except OSError as exc:
        return None, f"ASR_REMOTE_CA_FILE cannot be read ({exc.strerror or type(exc).__name__})"
    if not data or len(data) > 1 << 20:
        return None, "ASR_REMOTE_CA_FILE is empty or too large for a CA file"
    return hashlib.sha256(data).hexdigest(), None


def _asr_consent(cfg: Config, args, deps: AsrDeps) -> int:
    problem = _external_ready(args.engine)
    if problem:
        print(f"error: {problem}", file=sys.stderr)
        return EXIT_USAGE
    ctx = _AsrContext(cfg, deps)
    binding, why = policy_mod.consent_binding(cfg, args.engine)
    if binding is None:
        print(f"error: {args.engine} is not configured ({why}): set {_setup_settings(args.engine, 'ASR_REMOTE_URL (https, a DNS name) / ASR_AZURE_REGION')} "
              "in config.env first", file=sys.stderr)
        return EXIT_USAGE
    denial = policy_denial(ctx.org, args.engine, binding)
    if denial:
        print(f"refused: the organisation policy does not allow {args.engine} on this Mac ({denial}); a consent would have no effect", file=sys.stderr)
        return EXIT_FAILED
    state = status.consent_state(cfg, args.engine, ctx.org, ctx.consents, ctx.now)
    if state["state"] == "ok" and state["source"] == "org":
        print(f"{args.engine}: the organisation's consent {state['id']} covers this server (use {state['use']}, valid until {state['expires']}): "
              "nothing to confirm here")
        return EXIT_OK
    days = int(args.days if args.days is not None else CONSENT_DEFAULT_DAYS)
    if not 1 <= days <= CONSENT_MAX_DAYS:
        print(f"error: --days must be between 1 and {CONSENT_MAX_DAYS}", file=sys.stderr)
        return EXIT_USAGE
    ca_hash = None
    if binding["kind"] == "server":
        ca_hash, why = _read_ca_hash(cfg)
        if ca_hash is None:
            print(f"error: {why}", file=sys.stderr)
            return EXIT_USAGE
    if not _is_tty():
        print("error: a consent is given by typing a sentence in a terminal (stdin is not a TTY); open Terminal and run "
              f"`mcap asr-engines consent {args.engine}`", file=sys.stderr)
        return EXIT_USAGE
    for line in _consent_lines(cfg, ctx, binding, args.use, days, ca_hash):
        print(line)
    phrase = CONSENT_PHRASE.format(engine=args.engine, host=binding["host"])
    answer = _ask(f"동의하려면 정확히 입력하세요: {phrase}\n> ")
    if answer is None or answer.strip() != phrase:
        print("cancelled: the sentence did not match; nothing was recorded", file=sys.stderr)
        return EXIT_FAILED
    entry = policy_mod.ConsentEntry(
        id=f"c-{ctx.now:%Y%m%d}-{secrets.token_hex(3)}", engine=args.engine, kind=binding["kind"], host=binding["host"], port=binding["port"],
        region=binding["region"], model=binding["model"], protocol=binding["protocol"], backend_kind=binding["backend_kind"], use=args.use,
        machine=ctx.machine, granted_at=ctx.now.isoformat(timespec="seconds"), granted_by="tty",
        expires=(ctx.now.date() + timedelta(days=days)).isoformat(), ca_sha256=ca_hash)
    try:
        policy_mod.write_consent(cfg.consent_path, entry, machine_id=ctx.machine)
    except OSError as exc:
        print(f"error: the consent could not be written ({exc.strerror or type(exc).__name__})", file=sys.stderr)
        return EXIT_FAILED
    print(f"Recorded consent {entry.id} for {args.engine} (use {entry.use}) until {entry.expires}. "
          f"Set ASR_ENGINE={args.engine} (or ASR_FALLBACK) in config.env to use it; `mcap asr-engines check {args.engine}` shows the result.")
    return EXIT_OK


def _asr_enroll(cfg: Config, args, deps: AsrDeps) -> int:
    from . import asr_engines, asr_remote
    # The decision a run asking for the server would get, made with the ORGANISATION's view (a locked local-only flag closes the lane here like
    # in every other command). Without it enroll() builds its own blind to the lock. Refused BEFORE the code is asked for: a token for a server
    # the policy keeps this Mac away from would be a way around the lock. No daily cap applies to an enrollment.
    ctx = _AsrContext(cfg, deps)
    decision = ctx.decision("remote", used=-1.0)
    if decision.primary != "remote":
        print(f"FAILED: enrollment is not allowed for this server ({decision.reason})", file=sys.stderr)
        return EXIT_FAILED
    if args.code_stdin:
        code = sys.stdin.readline() if sys.stdin is not None else ""
    else:
        if not _is_tty():
            print("error: type the enrollment code in a terminal, or pass it on stdin with --code-stdin", file=sys.stderr)
            return EXIT_USAGE
        code = _ask("Enrollment code (from your administrator): ") or ""
    try:
        summary = asr_remote.enroll(cfg, code, transport=deps.transport_factory() if deps.transport_factory else None, run=deps.security_run,
                                    decision=decision, machine=deps.machine_id, now=deps.now)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except asr_engines.EngineError as exc:
        print(f"FAILED: {apikey.redact(str(exc))}", file=sys.stderr)
        return EXIT_FAILED
    days = summary.get("expires_in_days")
    print(f"Enrolled: the token for {summary['host']}:{summary['port']} is stored in the macOS Keychain"
          + (f" and valid until {summary['expires']}" if summary.get("expires") else "")
          + (f" ({days} days)" if days is not None else "") + ". Check it with: mcap asr-engines check remote --live")
    return EXIT_OK


def _asr_revoke(cfg: Config, args, deps: AsrDeps) -> int:
    if bool(args.target) == bool(args.all):
        print("error: name one engine to revoke, or use --all", file=sys.stderr)
        return EXIT_USAGE
    if args.target and args.target not in policy_mod.ENGINE_META:
        print(f"error: unknown engine {args.target!r}", file=sys.stderr)
        return EXIT_USAGE
    ctx = _AsrContext(cfg, deps)
    engines = [e for e in status.EXTERNAL_ENGINES] if args.all else [args.target]
    wipe = set()
    for engine in engines:
        binding, _why = policy_mod.consent_binding(cfg, engine)
        if binding is not None:
            wipe.add((engine, binding["host"], binding["port"]))
    wipe |= {(e.engine, e.host, e.port) for e in ctx.consents.entries if e.engine in engines}
    org_covered = [e for e in engines if status.consent_state(cfg, e, ctx.org, ctx.consents, ctx.now)["source"] == "org"]
    forget = bool(args.forget_secret)
    if forget and not args.yes:
        if not _is_tty():
            print("error: --forget-secret deletes Keychain items: run it in a terminal or pass --yes", file=sys.stderr)
            return EXIT_USAGE
        if not _confirm(f"Delete the stored credential(s) of {', '.join(engines)} from the macOS Keychain too? [y/N] "):
            forget = False
    removed = policy_mod.revoke_consent(cfg.consent_path, None if args.all else args.target)
    print(f"Revoked {removed} consent(s) of {'all engines' if args.all else args.target}." if removed else
          f"No consent of {'any engine' if args.all else args.target} was recorded on this Mac.")
    for engine in org_covered:
        print(f"note: the organisation's policy covers {engine} too; only the administrator can withdraw that (a new policy revision).")
    code = EXIT_OK
    if forget:
        from . import asr_creds
        for engine, host, port in sorted(wipe):
            code = max(code, asr_creds.forget_secret(engine, host, port, run=deps.security_run))
    return code


def _asr_purge(cfg: Config, args, deps: AsrDeps) -> int:
    if not (args.usage or args.capability or args.server):
        print("error: say what to purge: --usage (asr-usage.jsonl), --capability (asr-capability.json), --server (the server's memory cache)",
              file=sys.stderr)
        return EXIT_USAGE
    if args.usage and not args.yes:
        if not _is_tty():
            print("error: --usage deletes the record of external requests (and with it the day's count): run it in a terminal or pass --yes",
                  file=sys.stderr)
            return EXIT_USAGE
        if not _confirm("Delete asr-usage.jsonl? [y/N] "):
            print("cancelled")
            return EXIT_OK
    code = EXIT_OK
    targets = []
    if args.usage:
        base = Path(cfg.asr_usage_path)
        targets += [base] + [base.with_name(f"{base.name}.{n}") for n in range(1, 4)]
    if args.capability:
        cap = Path(cfg.capability_path)
        targets += [cap, cap.with_name(cap.name + ".tmp")]
    removed = 0
    for path in targets:
        try:
            path.unlink()
            removed += 1
        except FileNotFoundError:
            continue
        except OSError as exc:
            print(f"error: {path.name} could not be removed ({exc.strerror or type(exc).__name__})", file=sys.stderr)
            code = EXIT_FAILED
    if args.usage or args.capability:
        print(f"Removed {removed} local file(s).")
    if args.server:
        from . import asr_engines
        ctx = _AsrContext(cfg, deps)
        decision = ctx.decision("remote")
        if decision.primary != "remote":
            print(f"server: not purged: remote is not usable here ({decision.reason})", file=sys.stderr)
            return EXIT_FAILED
        try:
            member = ctx.build("remote", decision)
            try:
                print(f"Server: {member.purge()} cached entr(ies) dropped.")
            finally:
                member.release()
        except (asr_engines.EngineError, asr_engines.EngineUnavailable) as exc:
            print(f"FAILED: {apikey.redact(str(exc))}", file=sys.stderr)
            return EXIT_FAILED
    return code


def _asr_secret(cfg: Config, args, deps: AsrDeps) -> int:
    from . import asr_creds
    problem = _external_ready(args.engine)
    if problem:
        print(f"error: {problem}", file=sys.stderr)
        return EXIT_USAGE
    binding, why = policy_mod.consent_binding(cfg, args.engine)
    if binding is None:
        print(f"error: {args.engine} is not configured ({why}): set {_setup_settings(args.engine)} in config.env first", file=sys.stderr)
        return EXIT_USAGE
    host, port = binding["host"], binding["port"]
    if args.op == "status":
        info = asr_creds.secret_status(args.engine, host, port, run=deps.security_run)
        print(f"{args.engine}: " + ("a credential is stored" if info["present"] else f"no credential is stored ({info['reason']})")
              + f" for {destination_label(binding)} (Keychain service '{info['service']}', account '{info['account']}'); the value is never shown")
        return EXIT_OK if info["present"] else EXIT_FAILED
    if args.op == "set":
        return asr_creds.set_secret_interactive(args.engine, host, port, run=deps.security_run)
    if not args.yes:
        if not _is_tty():
            print("error: secret forget deletes the Keychain item: run it in a terminal or pass --yes", file=sys.stderr)
            return EXIT_USAGE
        if not _confirm(f"Delete the stored credential of {args.engine} for {destination_label(binding)}? [y/N] "):
            print("cancelled")
            return EXIT_OK
    return asr_creds.forget_secret(args.engine, host, port, run=deps.security_run)


def cmd_asr_engines(args, deps=None) -> int:
    """`mcap asr-engines <action>`: see the section comment. ``deps`` is an ``AsrDeps`` (tests) or anything else (the pipeline's Deps: ignored)."""
    cfg = load_config()
    deps = deps if isinstance(deps, AsrDeps) else AsrDeps()
    handler = {"list": _asr_list, "check": _asr_check, "bench": _asr_bench, "bench-synth": _asr_bench_synth, "consent": _asr_consent,
               "enroll": _asr_enroll, "revoke": _asr_revoke, "purge": _asr_purge, "secret": _asr_secret}[args.action]
    return handler(cfg, args, deps)


# ---------------------------------------------------------------------------------- status / sessions / forget / release
_BAD_CONFIG_KEY = re.compile(r"config\.env: bad value for ([A-Z][A-Z0-9_]{0,63}):", re.S)


def status_config() -> tuple[Config, Optional[str]]:
    """The config ``mcap status`` reports on and the code of what is wrong with it (None: nothing). The status feed must keep saying something
    about a Mac whose config.env the pipeline cannot start with (the fleet would otherwise read a stale, healthy-looking file): the built-in
    defaults, with the policy location ``load_config`` would have used, stand in for the unusable file, and the code names the KEY only, never
    the value: ``bad-value:<KEY>``, ``unreadable`` (the file cannot be read) or ``invalid``."""
    try:
        return load_config(), None
    except (ValueError, OSError) as exc:
        match = _BAD_CONFIG_KEY.match(str(exc)) if isinstance(exc, ValueError) else None
        code = f"bad-value:{match.group(1)}" if match else ("unreadable" if isinstance(exc, OSError) else "invalid")
        cfg = Config()
        cfg.policy_path = config_mod.policy_path_override() or config_mod.POLICY_SYSTEM_PATH
        return cfg, code


def cmd_status(args, deps=None) -> int:
    """`mcap status [--json | --write PATH]`: the content-free state of this Mac (mcap/status.py). ``--write`` is the MDM feed: the file is
    atomic and the usage numbers are left out unless STATUS_INCLUDE_USAGE=1; the interactive forms always show everything. A config.env that
    cannot be used does not stop it: the document says so (``config_error``, ``checks.config`` fail) and is still written."""
    cfg, config_error = status_config()
    doc = status.collect_status(cfg, for_mdm=bool(args.write), config_error=config_error)
    if config_error and not args.write:
        print(f"warning: config.env cannot be used ({config_error}): this document is computed from the built-in defaults; "
              "`mcap doctor` names the problem", file=sys.stderr)
    if args.write:
        try:
            status.write_status(Path(args.write).expanduser(), doc)
        except OSError as exc:
            print(f"error: cannot write the status file ({exc.strerror or type(exc).__name__})", file=sys.stderr)
            return EXIT_FAILED
        return EXIT_OK
    if args.json:
        print(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        for line in status.render_text(doc):
            print(line)
    return EXIT_OK


def cmd_sessions(args, deps=None) -> int:
    """`mcap sessions [--json]`: the sessions in staging (id, stage, error kind, age, size). Never a title."""
    cfg = load_config()
    rows = status.list_sessions(cfg)
    if args.json:
        print(json.dumps({"schema": 1, "sessions": rows}, ensure_ascii=False, indent=2))
        return EXIT_OK
    if not rows:
        print("no session in staging")
        return EXIT_OK
    table = [["session", "stage", "error kind", "age", "size"]]
    for row in rows:
        table.append([row["id"], row["stage"] + (" (published)" if row["tombstone"] else ""), row["error_kind"] or "-",
                      "-" if row["age_h"] is None else f"{row['age_h']:g} h", f"{row['size_mb']:g} MB"])
    widths = [max(len(r[i]) for r in table) for i in range(5)]
    for r in table:
        print("  ".join(cell.ljust(w) for cell, w in zip(r, widths)).rstrip())
    print(f"{len(rows)} session folder(s) in staging")
    return EXIT_OK


_ARCHIVE_MONTH = re.compile(r"\d{4}-\d{2}\Z")
_MEETING_FOLDER = re.compile(r"\d{4}-\d{2}-\d{2}_\d{4}_")


def _real(path) -> Path:
    return Path(os.path.realpath(path))


def forget_target(cfg: Config, folder: Path) -> tuple[Optional[str], Optional[Path], str]:
    """Which of the three places a folder is in, as ``(label, real path, "")``, or ``(None, None, why not)``. Only ONE session folder of the
    staging directory (``sessions/<id>`` and ``sessions/_discarded/<id>``) or ONE meeting folder of the local archive or the Drive archive
    (``<root>/YYYY-MM/YYYY-MM-DD_HHMM_<slug>``) qualifies: not a root, not a month, not a symbolic link, nothing outside the three roots
    (compared by real path, so a link inside a root that leads out is refused)."""
    if folder.is_symlink():
        return None, None, "it is a symbolic link"
    real = _real(folder)
    if not real.is_dir():
        return None, None, "it is not a folder"
    parent = real.parent
    staging = _real(cfg.sessions_dir)
    if parent == staging and not real.name.startswith("_"):
        return "staging", real, ""
    if parent == staging / "_discarded":
        return "staging (discarded)", real, ""
    for label, root in (("local archive", _real(cfg.local_archive_root)), ("archive", _real(cfg.archive_dir))):
        if parent.parent == root and _ARCHIVE_MONTH.fullmatch(parent.name) and _MEETING_FOLDER.match(real.name):
            return label, real, ""
    return None, None, ("it is not one session folder of staging or one meeting folder (<root>/YYYY-MM/YYYY-MM-DD_HHMM_<name>) of the local "
                        "archive or the archive")


def cmd_forget(args, deps=None) -> int:
    """`mcap forget <folder> [--yes]`: delete ONE session or meeting folder (staging, the local archive, the Drive archive) after a yes in the
    terminal (or --yes). Refused while the session is being recorded or processed. A staging stub that points at the deleted meeting goes too."""
    cfg = load_config()
    folder = Path(args.folder).expanduser()
    label, real, why = forget_target(cfg, folder)
    if real is None:
        print(f"error: {folder.name or args.folder} is not forgotten: {why}", file=sys.stderr)
        return EXIT_USAGE
    session = read_json(real / "session.json")
    key = str(session.get("session_id") or real.name) if isinstance(session, dict) else real.name
    if label.startswith("staging") and pipeline.is_live_recording(real):
        print(f"BUSY: {real.name} is still being recorded", flush=True)
        return EXIT_BUSY
    files = sum(len(names) for _root, _dirs, names in os.walk(real))
    megabytes = status.dir_bytes(real) / 1e6
    try:
        with pipeline.session_lock(cfg, key):
            if not args.yes:
                if not _is_tty():
                    print("error: mcap forget deletes the folder for good: run it in a terminal or pass --yes", file=sys.stderr)
                    return EXIT_USAGE
                if not _confirm(f"Delete the {label} folder {real.name} ({files} file(s), {megabytes:.1f} MB)? This cannot be undone. [y/N] "):
                    print("cancelled")
                    return EXIT_OK
            try:
                shutil.rmtree(real)
            except OSError as exc:
                print(f"error: {real.name} could not be deleted completely ({exc.strerror or type(exc).__name__})", file=sys.stderr)
                return EXIT_FAILED
    except pipeline.SessionBusy as exc:
        print(f"BUSY: {exc}", flush=True)
        return EXIT_BUSY
    for entry in status._staging_entries(cfg):                    # the stub a published meeting leaves in staging points at the folder just deleted
        stub = read_json(entry / "state.json")
        final = stub.get("final_dir") if isinstance(stub, dict) else None
        try:
            names = {p.name for p in entry.iterdir()}
        except OSError:
            continue
        if final and names == {"state.json"} and _real(final) == real:
            shutil.rmtree(entry, ignore_errors=True)
    print(f"Deleted the {label} folder {real.name} ({files} file(s), {megabytes:.1f} MB).")
    return EXIT_OK


RELEASES_DEFAULT = Path("/Library/Application Support/MeetingCapture/releases")


def _release_floor(org) -> Optional[tuple]:
    """The lowest pipeline version a switch may land on: with a policy (valid or locked) the larger of 0.2.0 and its min_pipeline_version,
    without one nothing (the personal install has no release layout and no requirement)."""
    if not org.present:
        return None
    floor = policy_mod.parse_version(status.CONTRACT_MIN_VERSION)
    if org.min_pipeline_version:
        try:
            wanted = policy_mod.parse_version(org.min_pipeline_version)
            if policy_mod._version_less(floor, wanted):
                floor = wanted
        except ValueError:
            pass
    return floor


def _release_dirs(root: Path) -> list[tuple[tuple, str]]:
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    found = []
    for name in names:
        try:
            version = policy_mod.parse_version(name)
        except ValueError:
            continue
        path = root / name
        if path.is_dir() and not path.is_symlink():
            found.append((version, name))
    found.sort(key=lambda item: item[0] + (0,) * (4 - len(item[0])))
    return found


def _current_release(root: Path) -> Optional[str]:
    try:
        return os.path.basename(os.readlink(root / "current"))
    except OSError:
        return None


def cmd_release(args, deps=None) -> int:
    """`mcap release list|switch <version>` (company layout): ``<root>/<version>/`` directories and ``<root>/current`` -> ``<version>``.
    ``switch`` replaces the link atomically and refuses a version below the policy's ``min_pipeline_version`` and, when a policy exists, below
    0.2.0 (a pipeline without the lane gates must not run on a policy-managed Mac). The root is the policy's ``runtime.root`` (``--root`` for a
    rehearsal)."""
    cfg = load_config()
    org = status.load_policy(cfg)
    root = Path(args.root).expanduser() if args.root else Path(org.runtime_root) if (org.valid and org.runtime_root) else RELEASES_DEFAULT
    floor = _release_floor(org)
    releases = _release_dirs(root)
    current = _current_release(root)
    if args.action == "list":
        if not releases:
            print(f"no release directory under {root} (the personal install has none)")
            return EXIT_OK
        for version, name in releases:
            allowed = floor is None or not policy_mod._version_less(version, floor)
            print(f"{name:<12} {'current' if name == current else '       '}  " + ("" if allowed else "below the minimum version: cannot be switched to"))
        if floor is not None:
            print(f"minimum version: {'.'.join(str(n) for n in floor)} (policy)")
        return EXIT_OK
    try:
        wanted = policy_mod.parse_version(args.version)
    except ValueError:
        print(f"error: {args.version!r} is not a version (like 0.2.1)", file=sys.stderr)
        return EXIT_USAGE
    name = args.version.strip() if args.version.strip() in {n for _v, n in releases} else None
    if name is None:
        print(f"error: no release {args.version} under {root} (mcap release list)", file=sys.stderr)
        return EXIT_USAGE
    if floor is not None and policy_mod._version_less(wanted, floor):
        print(f"refused: {name} is below the minimum pipeline version {'.'.join(str(n) for n in floor)} of the organisation policy "
              "(a downgrade would run a pipeline without the lane gates)", file=sys.stderr)
        return EXIT_FAILED
    if not (root / name / "pipeline").is_dir():
        print(f"error: {root / name} is not a complete release (no pipeline folder)", file=sys.stderr)
        return EXIT_USAGE
    if name == current:
        print(f"{name} is already the current release")
        return EXIT_OK
    link, scratch = root / "current", root / f".current.{os.getpid()}"
    try:
        os.symlink(name, scratch)
        os.replace(scratch, link)                                    # atomic: a launcher sees the old release or the new one, never none
    except OSError as exc:
        try:
            os.unlink(scratch)
        except OSError:
            pass
        print(f"error: the current link could not be switched ({exc.strerror or type(exc).__name__}): this needs the administrator's rights",
              file=sys.stderr)
        return EXIT_FAILED
    print(f"Switched current: {current or '(none)'} -> {name}. A job already running keeps the release it started with; "
          f"to go back: mcap release switch {current}" if current else f"Switched current to {name}.")
    return EXIT_OK


# ---------------------------------------------------------------------------------- argparse
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m mcap", description=f"{appinfo.display_name()} post-processing pipeline")
    parser.add_argument("--version", action="version", version=f"mcap {__version__}")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    sub = parser.add_subparsers(dest="command", required=True)

    def stage_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--from", dest="from_stage", choices=pipeline.STAGES,
                       help="regenerate this stage and everything after it")
        p.add_argument("--force", action="store_true", help="regenerate every stage")
        p.add_argument("--allow-overage", action="store_true",
                       help="write the note even while Claude reports extra-usage (overage) billing and NOTE_STOP_ON_OVERAGE=1")
        p.add_argument("--no-sweep", action="store_true",
                       help="do not retry other failed (retryable) sessions after a successful run")

    p = sub.add_parser("process", help="process one recorded session (staging dir)")
    p.add_argument("session_dir")
    stage_args(p)
    p.set_defaults(func=cmd_process)

    p = sub.add_parser("reprocess", help="resume/redo the latest (or a given) session, in staging or in the archive")
    p.add_argument("dir", nargs="?", help="session or meeting folder (default: the most recent one)")
    p.add_argument("--last", action="store_true", help="the most recent session (default)")
    p.add_argument("--pending", action="store_true",
                   help="retry everything a retry can finish: failed sessions with a retryable error of any kind (archive unavailable, "
                        "usage limit after its reset, asr failed, stalled, ...) and sessions that died mid-stage; never a live recording")
    p.add_argument("--max-attempts", type=int, default=None, metavar="N",
                   help=f"with --pending: leave sessions alone that already failed N runs (default {PENDING_MAX_ATTEMPTS}, 0 = no limit)")
    stage_args(p)
    p.set_defaults(func=cmd_reprocess)

    p = sub.add_parser("transcribe-file", help="transcribe any audio file (benchmark / ad hoc)")
    p.add_argument("audio")
    p.add_argument("--out", help="write the transcript here (default: stdout)")
    p.add_argument("--model", help="override ASR_MODEL")
    p.add_argument("--language", choices=["auto", "ko", "en"], help="override ASR_LANGUAGE")
    p.set_defaults(func=cmd_transcribe_file)

    p = sub.add_parser("prune-audio", help="delete old *.m4a (AUDIO_RETENTION_DAYS) and expired discarded sessions")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_prune_audio)

    p = sub.add_parser("usage", help="summary of the claude calls of the last days (usage.jsonl)")
    p.add_argument("--days", type=int, default=usage.SUMMARY_DAYS, help="how many days to look back (default 7)")
    p.add_argument("--json", action="store_true", help="machine readable")
    p.set_defaults(func=cmd_usage)

    p = sub.add_parser("doctor", help="check configuration, models, Claude login / API key, archive")
    p.add_argument("--no-warmup", action="store_true", help="skip the (slow) mlx import test")
    p.add_argument("--share", action="store_true",
                   help="remove the home folder and e-mail addresses from the output (to paste it into a support ticket)")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("api-key", help="the Anthropic API key of CLAUDE_AUTH=api in the macOS Keychain: status | set | check | forget")
    p.add_argument("action", choices=["status", "set", "check", "forget"],
                   help="status: is there a key (never its value); set: type it in the terminal (the macOS security tool asks); "
                        "check: ONE tiny real call that validates it and shows model / cost; forget: delete the Keychain item")
    p.add_argument("--yes", action="store_true", help="forget: do not ask for confirmation")
    p.add_argument("--exists", action="store_true",
                   help="status: only ask whether the Keychain item exists (exit 0 / 1): the value is not read, no Keychain dialog can appear")
    p.set_defaults(func=cmd_api_key)

    p = sub.add_parser("gcal", help="Google Calendar, read-only, for calendar autostart: auth | status | forget | upcoming")
    p.add_argument("action", choices=["auth", "status", "forget", "upcoming"],
                   help="auth: browser consent, stores the token in the Keychain; status: client file, token, account (never a secret); "
                        "forget: delete the token from the Keychain; upcoming: ONE JSON object with the events around now (exit 0 always)")
    p.add_argument("--from-minutes", type=int, default=gcal.DEFAULT_BACK_MIN, metavar="N",
                   help=f"upcoming: how far back to look (default {gcal.DEFAULT_BACK_MIN}, at most {gcal.MAX_WINDOW_MIN})")
    p.add_argument("--to-minutes", type=int, default=gcal.DEFAULT_AHEAD_MIN, metavar="M",
                   help=f"upcoming: how far ahead to look (default {gcal.DEFAULT_AHEAD_MIN}, at most {gcal.MAX_WINDOW_MIN})")
    p.set_defaults(func=cmd_gcal)

    # ---- SPEC 18: the external ASR engines and the company profile
    p = sub.add_parser("asr-engines", help="the speech-to-text engines: list | check | bench | consent | enroll | revoke | purge | secret")
    asub = p.add_subparsers(dest="action", required=True)
    a = asub.add_parser("list", help="engines, kind, destination label, policy, consent, credential, settings, circuit, last use")
    a.add_argument("--json", action="store_true", help="machine readable")
    a = asub.add_parser("check", help="static check of the configured external engine(s); --probe measures this Mac, --live asks the server")
    a.add_argument("engine", nargs="?", help="remote | azure | clova | openai-compat (default: the engines ASR_ENGINE / ASR_FALLBACK name)")
    a.add_argument("--probe", action="store_true", help="hardware probe + 20 s synthetic benchmark of the local engine (refused while recording)")
    a.add_argument("--live", action="store_true", help="after a confirmation: health request + ONE synthetic 1 s tone (nothing of yours is sent)")
    a.add_argument("--yes", action="store_true", help="--live: do not ask for confirmation")
    a = asub.add_parser("bench", help="latency and real-time factor per engine; synthetic clips unless --allow-real-audio")
    a.add_argument("audio", nargs="*", help="audio files: local engines use them; external engines only with --allow-real-audio")
    a.add_argument("--engine", action="append", help="engine to measure (repeatable; default: ASR_ENGINE / ASR_FALLBACK)")
    a.add_argument("--seconds", type=float, default=SYNTH_SECONDS, help=f"length of the synthetic clip / slice of a file (default {SYNTH_SECONDS:g})")
    a.add_argument("--allow-real-audio", action="store_true",
                   help="let the audio files go to external engines: asks you to type that nobody else was in the meeting")
    a = asub.add_parser("bench-synth", description="real-time factor of the local engine on a synthetic clip (the child of `check --probe`); "
                                                    'the last line of stdout is {"rtf": ...}')
    a.add_argument("--seconds", type=float, default=SYNTH_SECONDS)
    a.add_argument("--json", action="store_true")
    a = asub.add_parser("consent", help="record YOUR consent to send audio to an engine (terminal only; you type a sentence)")
    a.add_argument("engine", help="remote | azure | clova | openai-compat")
    a.add_argument("--use", choices=list(policy_mod.CONSENT_USES), default="both", help="primary, fallback or both (default both)")
    a.add_argument("--days", type=int, default=None, help=f"validity in days (default {CONSENT_DEFAULT_DAYS}, at most {CONSENT_MAX_DAYS})")
    a = asub.add_parser("enroll", help="exchange the enrollment code of your administrator for a token (stored in the Keychain)")
    a.add_argument("engine", choices=["remote"])
    a.add_argument("--code-stdin", action="store_true", help="read the code from stdin (for the app / an MDM script) instead of asking")
    a = asub.add_parser("revoke", help="withdraw your consent of an engine (or --all); optionally delete the stored credential too")
    a.add_argument("target", nargs="?", help="engine id")
    a.add_argument("--all", action="store_true", help="every engine")
    a.add_argument("--forget-secret", action="store_true", help="also delete the Keychain item of that engine's destination")
    a.add_argument("--yes", action="store_true", help="do not ask before deleting Keychain items")
    a = asub.add_parser("purge", help="delete local files (usage record, capability cache) and/or the server's memory cache of your token")
    a.add_argument("--usage", action="store_true", help="asr-usage.jsonl (and its rotated files)")
    a.add_argument("--capability", action="store_true", help="asr-capability.json (the hardware benchmark cache)")
    a.add_argument("--server", action="store_true", help="ask the company server to drop its cached answers and vocabularies of your token")
    a.add_argument("--yes", action="store_true", help="--usage: do not ask for confirmation")
    a = asub.add_parser("secret", help="the credential of an engine in the Keychain: set | status | forget (the value is never shown)")
    a.add_argument("op", choices=["set", "status", "forget"])
    a.add_argument("engine", help="remote | azure | clova | openai-compat")
    a.add_argument("--yes", action="store_true", help="forget: do not ask for confirmation")
    p.set_defaults(func=cmd_asr_engines)

    p = sub.add_parser("status", help="content-free state of this Mac: versions, policy, route, sessions, device (no titles, ids, paths, names)")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--json", action="store_true", help="machine readable (everything)")
    group.add_argument("--write", metavar="PATH", help="write the JSON atomically (the MDM extension attribute; usage numbers only with STATUS_INCLUDE_USAGE=1)")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("sessions", help="the sessions in staging: id, stage, error kind, age, size (never a title)")
    p.add_argument("--json", action="store_true", help="machine readable")
    p.set_defaults(func=cmd_sessions)

    p = sub.add_parser("forget", help="delete ONE session or meeting folder (staging, the local archive or the archive) for good")
    p.add_argument("folder")
    p.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    p.set_defaults(func=cmd_forget)

    p = sub.add_parser("release", help="company layout: list the releases / switch the current link (never below the policy's minimum version)")
    p.add_argument("--root", help="the releases directory (default: the policy's runtime.root, else /Library/Application Support/MeetingCapture/releases)")
    rsub = p.add_subparsers(dest="action", required=True)
    rsub.add_parser("list", help="the releases and which one is current")
    r = rsub.add_parser("switch", help="make <version> the current release (atomic)")
    r.add_argument("version")
    p.set_defaults(func=cmd_release)
    return parser


def main(argv: Optional[list[str]] = None, deps: Optional[pipeline.Deps] = None) -> int:
    # The app starts its pipelines with HF_HUB_DISABLE_TELEMETRY=1; a terminal run (reprocess, doctor) must not be the one that talks.
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    apikey.install_log_redaction()               # SPEC 17: an API key shape never reaches a log line
    try:
        return args.func(args, deps)
    except ValueError as exc:                      # bad config.env value
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except KeyboardInterrupt:
        return 130
