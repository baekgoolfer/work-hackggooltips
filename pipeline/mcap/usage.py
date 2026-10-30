"""Claude usage visibility, the per-meeting call cap (SPEC 15) and the USD budgets of api mode (SPEC 17).

Three small things that belong together because every `claude` process the pipeline starts goes through all of them:

1. `usage.jsonl` (SUPPORT_DIR): one JSON line per claude call, appended when the call has finished (or was refused by the cap):

       {"ts": "2026-10-08T14:03:11+09:00", "session_id": "2026-10-08_1400_zoom", "stage": "cleanup",
        "model": "claude-opus-5", "models": ["claude-opus-5"], "requested_model": "opus", "duration_s": 12.4,
        "isUsingOverage": false, "outcome": "ok", "attempt": 1, "auth": "api", "cost_usd": 0.4321}

   `stage` is cleanup | note | verify | calendar | preflight (`claude auth status`, a local call without a model) | check (`mcap
   api-key check`). `models` comes from the result's `modelUsage`, `outcome` is the classification of the call (ok, usage_limit,
   overloaded, timeout, ..., `cap_reached` for a call that was not made because of MAX_CLAUDE_CALLS_PER_MEETING, `budget_daily` /
   `budget_meeting` for one that was not made because of a USD budget). `auth` (SPEC 17) is the billing path of the call:
   `subscription` or `api` (the calendar lookup and the preflight are always `subscription`). `cost_usd` is the `total_cost_usd` of
   the result event (0.0 when there is none: counted as 0 and logged once; a call killed by the timeout has no result event, so its
   cost is unknown). With `auth=subscription` it is only the API-equivalent estimate of the CLI, nothing is billed per token.
   `mcap usage` and `mcap doctor` summarise the last 7 (and 30) days. The file is plain text, safe to delete or truncate at any time;
   a failed write is only logged, it never breaks a pipeline run. Every string in it passes through apikey.redact.

2. `CallBudget` / `meeting()`: MAX_CLAUDE_CALLS_PER_MEETING caps the claude calls (cleanup batches + note + verify + calendar,
   retries included) of ONE pipeline run of a meeting. The note is protected: the calls it may need (primary + fallback model)
   are RESERVED before anything else runs, so the optional stages can never starve it; calendar and verify get their own small
   reservations, and the transcript cleanup takes the rest (its batches grow bigger when little is left). A stage that finds
   no call left is skipped by its caller with a warning; the note itself is never skipped for that reason.

3. Budgets in USD (api mode only; CLAUDE_DAILY_BUDGET_USD / CLAUDE_MEETING_BUDGET_USD, 0 = off): `day_cost_usd()` adds up today's
   (local date) `auth=api` lines, `run_cost_usd()` the api cost of the running pipeline run, `budget_block()` says whether a stage
   may start. The daily budget stops every stage (the note too: it fails with budget_daily and waits for midnight), the meeting
   budget stops cleanup / verify / calendar but never the note. The check happens BEFORE each call is started (note.call_claude);
   parallel cleanup batches therefore overshoot a budget by at most the calls that were already running when it was reached
   (CONCURRENCY of them), never by a whole pass.

The budget of the running pipeline is ambient (`usage.meeting(...)` sets it for the duration of one run, `current_budget()` reads
it) so the one executor `note.call_claude` and the calendar lookup meter themselves without every function in between having to
pass it along. Cleanup runs its batches on worker threads, so the state is deliberately process-global, not thread-local.
"""
from __future__ import annotations

import json
import logging
import os
import threading
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, tzinfo
from pathlib import Path
from typing import Iterable, Iterator, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import apikey
from .config import Config

log = logging.getLogger("mcap.usage")

USAGE_FILE = "usage.jsonl"
STAGES = ("cleanup", "note", "verify", "calendar", "preflight", "check")
OUTCOME_CAP = "cap_reached"          # a call that was NOT made because MAX_CLAUDE_CALLS_PER_MEETING was used up
OUTCOME_BUDGET_DAILY, OUTCOME_BUDGET_MEETING = "budget_daily", "budget_meeting"   # NOT made: a USD budget (SPEC 17) was reached
NOT_MADE = (OUTCOME_CAP, OUTCOME_BUDGET_DAILY, OUTCOME_BUDGET_MEETING)
AUTH_SUBSCRIPTION, AUTH_API = apikey.MODE_SUBSCRIPTION, apikey.MODE_API
SUBSCRIPTION_STAGES = ("preflight", "calendar")   # always the claude.ai login, also while CLAUDE_AUTH=api (SPEC 17: calendar exception)
SUMMARY_DAYS = 7
COST_WINDOWS = (7, 30)               # `mcap usage` / `mcap doctor` show the cost of these windows
# Calls kept back for the stages that must not be starved by the transcript cleanup, in priority order (the note first).
NOTE_RESERVE, CALENDAR_RESERVE, VERIFY_RESERVE = 2, 1, 2     # note: primary + fallback attempt; verify: the same; calendar: one process
MIN_CAP = 1


def usage_path(cfg: Config) -> Path:
    return Path(cfg.support_dir) / USAGE_FILE


def _local_zone() -> Optional[tzinfo]:
    """The machine's own time zone as a rules-based zone (DST aware), or None when it cannot be determined. `datetime.now().astimezone()`
    only carries the CURRENT utc offset: "midnight" computed from it is an hour off on a DST change day, so the daily budget would
    forget (fall back) or invent (spring forward) an hour of spending. $TZ wins (that is what the C library honours), else the
    /etc/localtime link (…/zoneinfo/Asia/Seoul)."""
    name = (os.environ.get("TZ") or "").lstrip(":")
    if not name:
        try:
            target = os.readlink("/etc/localtime")
        except OSError:
            return None
        name = target.split("zoneinfo/", 1)[1] if "zoneinfo/" in target else ""
    try:
        return ZoneInfo(name) if name else None
    except (ZoneInfoNotFoundError, ValueError, OSError):      # a POSIX TZ string like "EST5EDT4" or no tz database
        return None


def clock() -> datetime:
    """Local, timezone-aware 'now' (DST-aware zone when the machine's zone is known, else a fixed offset). Everything in this module
    that depends on the date (usage.jsonl timestamps, the daily budget) reads the time through here, so a test can replace it
    (midnight rollover)."""
    zone = _local_zone()
    return datetime.now(zone) if zone is not None else datetime.now().astimezone()


def _now_iso() -> str:
    return clock().isoformat(timespec="seconds")


# ---------------------------------------------------------------------------------- the budget
class CallBudget:
    """Cap on the number of claude calls with per-stage reservations. Thread-safe.

    `limit` calls in total. `reserve` = {stage: n} are held back for that stage in dict order (priority); a reservation is clamped
    so that the sum never exceeds `limit`. `take(stage)` uses the stage's own reservation first, otherwise the free pool (limit -
    used - what is still reserved for other stages). Without reservations it is a plain counter: CallBudget(2).take() -> True, True,
    False.
    """

    def __init__(self, limit: int, reserve: Optional[dict] = None, session_id: Optional[str] = None):
        self.limit = max(0, int(limit))
        self.session_id = session_id
        self.used = 0
        self.by_stage: Counter = Counter()
        self.denied: Counter = Counter()
        self.reserved: dict[str, int] = {}
        self._lock = threading.Lock()
        left = self.limit
        for stage, n in (reserve or {}).items():
            n = max(0, min(int(n), left))
            if n:
                self.reserved[stage] = n
                left -= n

    def take(self, stage: Optional[str] = None) -> bool:
        """Claim one call for `stage`. False = the cap is reached for that stage (nothing is claimed)."""
        with self._lock:
            own = self.reserved.get(stage or "", 0)
            if own > 0:
                self.reserved[stage] = own - 1
            elif self.used + sum(self.reserved.values()) >= self.limit:
                self.denied[stage or "?"] += 1
                return False
            self.used += 1
            self.by_stage[stage or "?"] += 1
            return True

    def available(self, stage: Optional[str] = None) -> int:
        """How many calls `stage` could still make: its own reservation plus the free pool."""
        with self._lock:
            others = sum(n for s, n in self.reserved.items() if s != stage)
            return max(0, self.limit - self.used - others)

    def exhausted_for(self, stage: str) -> bool:
        return self.available(stage) <= 0


def planned_reserve(*, calendar: bool, verify: bool) -> dict:
    """Reservations of one run: the note always, the calendar lookup / the verification only when they can happen."""
    reserve = {"note": NOTE_RESERVE}
    if calendar:
        reserve["calendar"] = CALENDAR_RESERVE
    if verify:
        reserve["verify"] = VERIFY_RESERVE
    return reserve


def effective_cap(cfg: Config) -> int:
    """MAX_CLAUDE_CALLS_PER_MEETING, but never below 1: the note must always be possible."""
    try:
        return max(MIN_CAP, int(cfg.max_claude_calls_per_meeting))
    except (TypeError, ValueError):
        return MIN_CAP


# ---------------------------------------------------------------------------------- ambient scope of one pipeline run
@dataclass
class _Scope:
    session_id: Optional[str]
    budget: Optional[CallBudget]
    cost_usd: float = 0.0                                        # api cost of this run so far (the meeting budget counts it)
    lock: threading.Lock = field(default_factory=threading.Lock)


_current: Optional[_Scope] = None


@contextmanager
def meeting(session_id: Optional[str], budget: Optional[CallBudget] = None) -> Iterator[Optional[CallBudget]]:
    """Everything that calls claude inside this block is logged under `session_id` and counted against `budget`."""
    global _current
    previous = _current
    _current = _Scope(session_id, budget)
    try:
        yield budget
    finally:
        _current = previous


def current_budget() -> Optional[CallBudget]:
    scope = _current
    return scope.budget if scope else None


def current_session_id() -> Optional[str]:
    scope = _current
    return scope.session_id if scope else None


def run_cost_usd() -> Optional[float]:
    """api cost of the running pipeline run (None outside a run). Every api call that record() logs is added to it."""
    scope = _current
    if scope is None:
        return None
    with scope.lock:
        return scope.cost_usd


def _add_run_cost(usd: float) -> None:
    scope = _current
    if scope is not None and usd > 0:
        with scope.lock:
            scope.cost_usd += usd


# ---------------------------------------------------------------------------------- usage.jsonl
_missing_cost_logged = False          # "no total_cost_usd in the result" is logged once per process, not once per call


def default_auth(cfg: Config, stage: str) -> str:
    """The billing path of a logged call: the preflight and the calendar lookup always use the claude.ai login."""
    if stage in SUBSCRIPTION_STAGES:
        return AUTH_SUBSCRIPTION
    return AUTH_API if apikey.is_api(cfg) else AUTH_SUBSCRIPTION


def _cost(entry: dict) -> float:
    raw = entry.get("cost_usd")
    if isinstance(raw, bool):
        return 0.0
    try:
        value = float(raw or 0.0)
    except (TypeError, ValueError):
        return 0.0
    return value if value == value and value > 0 else 0.0           # NaN and negative numbers count as 0


def record(cfg: Config, stage: str, *, models: Iterable[str] = (), requested: str = "", duration_s: float = 0.0,
           is_using_overage: bool = False, outcome: str = "ok", attempt: Optional[int] = None,
           session_id: Optional[str] = None, cost_usd: Optional[float] = None, auth: Optional[str] = None) -> None:
    """Append one line to usage.jsonl. Never raises (usage logging must not be able to break a run). `cost_usd` is the result's
    total_cost_usd (None = the call has no cost field: counted as 0, `cost_missing` is set on the line when a result with models
    exists, and the first such call of the process is logged). An api cost is also added to the running meeting's cost."""
    global _missing_cost_logged
    resolved = [str(m) for m in models if m]
    auth = auth or default_auth(cfg, stage)
    cost_missing = cost_usd is None and bool(resolved) and stage != "preflight"
    cost = _cost({"cost_usd": cost_usd})
    entry = {
        "ts": _now_iso(),
        "session_id": session_id if session_id is not None else current_session_id(),
        "stage": stage,
        "model": ", ".join(resolved) or requested or None,
        "models": resolved,
        "requested_model": requested or None,
        "duration_s": round(float(duration_s or 0.0), 1),
        "isUsingOverage": bool(is_using_overage),
        "outcome": outcome or "unknown",
        "auth": auth,
        "cost_usd": round(cost, 6),
    }
    if attempt is not None:
        entry["attempt"] = attempt
    if cost_missing:
        entry["cost_missing"] = True
        if not _missing_cost_logged:
            _missing_cost_logged = True
            log.warning("the result of a %s call has no total_cost_usd: it counts as 0 (budgets and `mcap usage` undercount; "
                        "logged once per process)", stage)
    if auth == AUTH_API:
        _add_run_cost(cost)
    try:
        path = usage_path(cfg)
        path.parent.mkdir(parents=True, exist_ok=True)
        data = (json.dumps(apikey.redact_obj(entry), ensure_ascii=False) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)      # one write(): lines of concurrent runs never mix
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as exc:
        log.warning("cannot write %s: %s", usage_path(cfg), exc)


def _parse_ts(value) -> Optional[datetime]:
    try:
        ts = datetime.fromisoformat(str(value))
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.astimezone()


def _parse_line(line: str) -> Optional[tuple[dict, datetime]]:
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        obj = json.loads(line)
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    ts = _parse_ts(obj.get("ts"))
    return (obj, ts) if ts is not None else None


def read_entries(cfg: Config, since: Optional[datetime] = None) -> list[dict]:
    """All well-formed lines (optionally only those at or after `since`). Garbage lines and a missing file are ignored."""
    entries: list[dict] = []
    try:
        with open(usage_path(cfg), "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parsed = _parse_line(line)
                if parsed is None or (since is not None and parsed[1] < since):
                    continue
                entries.append(parsed[0])
    except OSError:
        pass
    return entries


def _entries_since(cfg: Config, since: datetime, needle: Optional[bytes] = None) -> Iterator[dict]:
    """Lines at or after `since` whose raw bytes contain `needle` (a cheap pre-filter: only matching lines are parsed, so the budget
    check that runs before every call stays fast on a log of many months). The whole file is read in file order: the budget guards
    money, so it must not depend on the log being sorted."""
    try:
        data = usage_path(cfg).read_bytes()
    except OSError:
        return
    for raw in data.splitlines():
        if needle is not None and needle not in raw:
            continue
        parsed = _parse_line(raw.decode("utf-8", "replace"))
        if parsed is not None and parsed[1] >= since:
            yield parsed[0]


# ---------------------------------------------------------------------------------- budgets (SPEC 17, api mode only)
def day_cost_usd(cfg: Config, auth: str = AUTH_API, now: Optional[datetime] = None) -> float:
    """What the logged calls of `auth` cost today. 'Today' is the local calendar date of `now` (default: clock()); a line counts when
    its own timestamp falls on that date. Lines without an `auth` field (older logs) are subscription calls."""
    now = now or clock()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    total = 0.0
    # pre-filter on the value only, never on the spacing of the JSON (`"auth": "api"` vs `"auth":"api"`): a log line written by another
    # tool or a later json.dumps(separators=...) must not silently drop out of the money guard; the exact check is made after parsing
    needle = f'"{auth}"'.encode() if auth != AUTH_SUBSCRIPTION else None             # (lines of old logs have no auth: subscription)
    for entry in _entries_since(cfg, midnight, needle):
        ts = _parse_ts(entry.get("ts"))
        if ts is None or str(entry.get("auth") or AUTH_SUBSCRIPTION) != auth or ts.astimezone(now.tzinfo).date() != now.date():
            continue
        total += _cost(entry)
    return total


def next_midnight_epoch(now: Optional[datetime] = None) -> int:
    """Epoch seconds of the next local midnight: when the daily budget starts over."""
    now = now or clock()
    return int((now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)).timestamp())


def _limit(value) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    return number if number == number and number > 0 else 0.0


@dataclass
class BudgetBlock:
    kind: str                 # budget_daily | budget_meeting (also the error_kind of a failure it causes)
    message: str              # one line, says what to do
    used: float
    limit: float
    resets_at: Optional[int] = None


def budget_block(cfg: Config, stage: str, now: Optional[datetime] = None) -> Optional[BudgetBlock]:
    """Why `stage` (cleanup | note | verify | calendar) must NOT start now, or None. Only in api mode (CLAUDE_AUTH=api); 0 switches a
    budget off. The daily budget blocks every stage, the note included; the meeting budget blocks everything but the note (the note
    call is always reserved)."""
    if not apikey.is_api(cfg):
        return None
    now = now or clock()
    daily = _limit(getattr(cfg, "claude_daily_budget_usd", 0))
    if daily:
        used = day_cost_usd(cfg, AUTH_API, now)
        if used >= daily:
            return BudgetBlock(OUTCOME_BUDGET_DAILY,
                               f"daily Claude budget reached: ${used:.2f} of ${daily:.2f} spent today (CLAUDE_DAILY_BUDGET_USD); "
                               "later Claude stages wait for midnight (local time) or a higher budget, then: mcap reprocess --pending",
                               used, daily, next_midnight_epoch(now))
    meeting = _limit(getattr(cfg, "claude_meeting_budget_usd", 0))
    spent = run_cost_usd()
    if stage != "note" and meeting and spent is not None and spent >= meeting:
        return BudgetBlock(OUTCOME_BUDGET_MEETING,
                           f"meeting Claude budget reached: ${spent:.2f} of ${meeting:.2f} spent on this meeting "
                           "(CLAUDE_MEETING_BUDGET_USD); only the note is still made", spent, meeting)
    return None



def budget_status(cfg: Config, now: Optional[datetime] = None) -> dict:
    """Today's api cost against the configured budgets (0 = off): {used, daily, meeting, reached}."""
    daily = _limit(getattr(cfg, "claude_daily_budget_usd", 0))
    used = day_cost_usd(cfg, AUTH_API, now)
    return {"used": used, "daily": daily, "meeting": _limit(getattr(cfg, "claude_meeting_budget_usd", 0)),
            "reached": bool(daily and used >= daily)}


def budget_line(cfg: Config, now: Optional[datetime] = None) -> str:
    """One line for `mcap usage` / `mcap doctor` (api mode): what today cost against the daily budget, the per-meeting budget."""
    st = budget_status(cfg, now)
    if st["daily"]:
        today = f"api cost today (local date): ${st['used']:.2f} of the ${st['daily']:.2f} daily budget (CLAUDE_DAILY_BUDGET_USD)"
    else:
        today = f"api cost today (local date): ${st['used']:.2f}, no daily budget (CLAUDE_DAILY_BUDGET_USD=0)"
    per_meeting = (f"${st['meeting']:.2f} per meeting run, the note itself is always reserved (CLAUDE_MEETING_BUDGET_USD)"
                   if st["meeting"] else "no per-meeting budget (CLAUDE_MEETING_BUDGET_USD=0)")
    reached = "; REACHED: later Claude stages are skipped until midnight (local time)" if st["reached"] else ""
    return f"{today}; {per_meeting}{reached}"


def summarize(entries: list[dict], days: int = SUMMARY_DAYS) -> dict:
    """Counts for the usage command / doctor. `calls` are real claude runs: preflight (`claude auth status`, no model) and calls
    that were not made (call cap, USD budget) are listed separately."""
    calls = [e for e in entries if e.get("stage") != "preflight" and e.get("outcome") not in NOT_MADE]
    by_stage = Counter(str(e.get("stage") or "?") for e in calls)
    by_model: Counter = Counter()
    for e in calls:
        models = e.get("models") if isinstance(e.get("models"), list) and e.get("models") else [e.get("model") or "unknown"]
        for m in models:
            by_model[str(m)] += 1
    per_meeting = Counter(str(e.get("session_id")) for e in calls if e.get("session_id"))
    seconds = 0.0
    for e in calls:
        try:
            seconds += float(e.get("duration_s") or 0.0)
        except (TypeError, ValueError):
            pass
    return {
        "days": days,
        "calls": len(calls),
        "by_stage": dict(sorted(by_stage.items())),
        "by_model": dict(sorted(by_model.items())),
        "overage_calls": sum(1 for e in calls if e.get("isUsingOverage")),
        "not_ok": sum(1 for e in calls if e.get("outcome") != "ok"),
        "preflight": sum(1 for e in entries if e.get("stage") == "preflight"),
        "skipped_by_cap": sum(1 for e in entries if e.get("outcome") == OUTCOME_CAP),
        "skipped_by_budget": sum(1 for e in entries if e.get("outcome") in (OUTCOME_BUDGET_DAILY, OUTCOME_BUDGET_MEETING)),
        "meetings": len(per_meeting),
        "max_calls_per_meeting": max(per_meeting.values(), default=0),
        "seconds": round(seconds, 1),
        "cost_missing": sum(1 for e in calls if e.get("cost_missing")),
        **cost_summary(entries),
    }


def cost_summary(entries: list[dict]) -> dict:
    """Cost of the lines in USD: {"cost_usd": total, "cost_by_auth": {"api": x, "subscription": y}, "cost_by_stage": {"api":
    {"note": ...}, "subscription": {...}}}. The subscription figure is the CLI's API-equivalent estimate (nothing is billed for it)."""
    by_auth = {AUTH_API: 0.0, AUTH_SUBSCRIPTION: 0.0}
    by_stage: dict[str, dict[str, float]] = {AUTH_API: {}, AUTH_SUBSCRIPTION: {}}
    for e in entries:
        cost = _cost(e)
        if not cost:
            continue
        auth = AUTH_API if e.get("auth") == AUTH_API else AUTH_SUBSCRIPTION
        stage = str(e.get("stage") or "?")
        by_auth[auth] += cost
        by_stage[auth][stage] = by_stage[auth].get(stage, 0.0) + cost
    return {"cost_usd": round(sum(by_auth.values()), 4),
            "cost_by_auth": {k: round(v, 4) for k, v in by_auth.items()},
            "cost_by_stage": {a: {k: round(v, 4) for k, v in sorted(st.items())} for a, st in by_stage.items()}}


def week_summary(cfg: Config, days: int = SUMMARY_DAYS, now: Optional[datetime] = None) -> dict:
    now = now or clock()
    return summarize(read_entries(cfg, now - timedelta(days=days)), days)


def cost_windows(cfg: Config, now: Optional[datetime] = None) -> dict:
    """{7: cost_summary of the last 7 days, 30: ... of the last 30 days} (one read of the log)."""
    now = now or clock()
    entries = read_entries(cfg, now - timedelta(days=max(COST_WINDOWS)))
    out = {}
    for days in COST_WINDOWS:
        since = now - timedelta(days=days)
        out[days] = cost_summary([e for e in entries if (_parse_ts(e.get("ts")) or now) >= since])
    return out


def _usd(value: float) -> str:
    return f"${value:,.2f}" if value >= 0.005 or not value else f"${value:.4f}"


def format_costs(windows: dict) -> list[str]:
    """Human readable cost lines (`mcap usage`)."""
    lines = ["Claude cost in USD (total_cost_usd of the result events; billing path = auth)"]
    for days in sorted(windows):
        w = windows[days]
        by_auth = w["cost_by_auth"]
        lines.append(f"  last {days:>2} days: {_usd(w['cost_usd'])}  (api {_usd(by_auth['api'])} billed to the Console key, "
                     f"subscription {_usd(by_auth['subscription'])} API-equivalent, not billed per token)")
        for auth in (AUTH_API, AUTH_SUBSCRIPTION):
            stages = w["cost_by_stage"][auth]
            if stages:
                lines.append(f"      {auth:<12} " + ", ".join(f"{k} {_usd(v)}" for k, v in stages.items()))
    return lines


def cost_one_line(windows: dict) -> str:
    """The doctor line: 7 and 30 day sums by billing path."""
    parts = []
    for days in sorted(windows):
        by_auth = windows[days]["cost_by_auth"]
        parts.append(f"last {days} days {_usd(windows[days]['cost_usd'])} (api {_usd(by_auth['api'])}, "
                     f"subscription {_usd(by_auth['subscription'])} equivalent)")
    return "; ".join(parts)


def format_summary(summary: dict) -> list[str]:
    """Human readable lines for `mcap usage`."""
    days = summary["days"]
    skipped = summary["skipped_by_cap"] + summary.get("skipped_by_budget", 0)
    if not summary["calls"] and not summary["preflight"] and not skipped:
        return [f"No claude call recorded in the last {days} days."]
    stages = ", ".join(f"{k} {v}" for k, v in summary["by_stage"].items()) or "none"
    models = ", ".join(f"{k} x{v}" for k, v in summary["by_model"].items()) or "none"
    lines = [
        f"Claude usage, last {days} days ({USAGE_FILE})",
        f"  calls:        {summary['calls']} ({stages})",
        f"  meetings:     {summary['meetings']} (at most {summary['max_calls_per_meeting']} call(s) for one meeting)",
        f"  models:       {models}",
        f"  extra usage:  {summary['overage_calls']} call(s) reported isUsingOverage=true",
        f"  not ok:       {summary['not_ok']} call(s) ended with an error or an unusable reply",
        f"  skipped:      {summary['skipped_by_cap']} call(s) refused by MAX_CLAUDE_CALLS_PER_MEETING",
    ]
    if summary.get("skipped_by_budget"):
        lines.append(f"  budget:       {summary['skipped_by_budget']} call(s) not made because a USD budget was reached")
    if summary.get("cost_missing"):
        lines.append(f"  cost unknown: {summary['cost_missing']} call(s) had no total_cost_usd (counted as 0)")
    lines += [
        f"  preflight:    {summary['preflight']} 'claude auth status' check(s) (local, no model)",
        f"  busy time:    {summary['seconds']:.0f} s of claude run time",
    ]
    return lines


def one_line(summary: dict) -> str:
    """The doctor line: calls, by stage, overage count."""
    skipped = summary["skipped_by_cap"] + summary.get("skipped_by_budget", 0)
    if not summary["calls"] and not skipped:
        return f"no claude call recorded in the last {summary['days']} days"
    stages = ", ".join(f"{k} {v}" for k, v in summary["by_stage"].items()) or "none"
    text = (f"{summary['calls']} call(s) in the last {summary['days']} days ({stages}); "
            f"extra usage (overage) seen in {summary['overage_calls']} call(s)")
    if summary["skipped_by_cap"]:
        text += f"; {summary['skipped_by_cap']} call(s) refused by MAX_CLAUDE_CALLS_PER_MEETING"
    if summary.get("skipped_by_budget"):
        text += f"; {summary['skipped_by_budget']} call(s) not made because a USD budget was reached"
    return text
