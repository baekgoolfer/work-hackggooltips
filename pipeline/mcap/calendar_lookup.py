"""Optional, best-effort meeting title / attendee lookup through the claude.ai Google Calendar connector (SPEC 13.3).

Why two turns: claude.ai connectors are
fetched asynchronously and are normally not yet known when the first model request of a `claude -p` run is sent. Over
`--input-format stream-json` the process stays alive: turn 1 is a no-op that lets the connectors connect, turn 2 sees the
tools. The decision logic runs in Python on the RAW tool_result, never on the model's prose.

Read-only: `--allowedTools` is list_events only (no calendar writes, no other connector tool). Do NOT add `--safe-mode` /
`--strict-mcp-config` here: both switch the claude.ai connectors off. Any failure -> None (the title then falls back to the
window title / platform name). Hard timeout 90 s. Logs never contain event titles or attendees.

An overage observation always writes the marker; with NOTE_STOP_ON_OVERAGE=1 it also aborts the lookup and is SURFACED to
the caller (CalendarOverage is re-raised by lookup_calendar, the only exception it lets through) so the pipeline stops before
the note call instead of silently continuing. pick_event additionally refuses events of another meeting / another platform.

Privacy (SPEC 15): the query window is the recording start +-45 minutes (it used to span the whole recording, up to 8 h), so a
day full of unrelated meetings and their attendees never enters the Claude session. Only the matched event leaves this module: the
raw events exist in memory during pick_event and are dropped; calendar.json (CalendarMatch.to_dict) keeps the event's title, start,
end and the attendees' display names and emails, nothing else (no description, location, organizer, other events, conference data).
The lookup is one claude call (stage "calendar" in usage.jsonl, counted against MAX_CLAUDE_CALLS_PER_MEETING). CALENDAR_LOOKUP=0
switches the whole thing off.

SPEC 17 (billing modes): the Google Calendar connector belongs to the claude.ai LOGIN, an API key cannot use it. So this is the ONE
Claude call that always runs in subscription mode, also while CLAUDE_AUTH=api: the child env never has a key (clean_env()), the
subscription guards stay (init.apiKeySource must be "none"), usage.jsonl says `auth: subscription`. In api mode there is no
other check that a login exists, so the lookup first runs the local `claude auth status`; no claude.ai login = the lookup is skipped
quietly (the title falls back to the window title / platform). A reached USD budget (daily or meeting) skips it too. Overage
observations are not recorded as a marker in api mode (the overage logic is subscription-only).

SPEC 18: the calendar is its own lane. `fetch_events` and `lookup_calendar` begin with the lane gate
(`lanes.gate("calendar")`; no active pipeline run = no gate): a local-only meeting, an organisation that denies the lane or a gate that
cannot read session.json starts no `claude` process (not even `auth status`) and the title falls back to the window title / platform
name. With a company policy that pins the CLI the binary's signature is verified before the start (`note.verify_claude_bin`).
"""
from __future__ import annotations

import json
import logging
import os
import queue
import re
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional
from urllib.parse import unquote

from . import apikey, lanes, overage, usage
from .config import Config
from .note import child_dies_with_us, clean_env, preflight, result_cost, verify_claude_bin
from .publish import parse_iso, session_start
from .state import now_iso

log = logging.getLogger("mcap.calendar")

TOOL = "mcp__claude_ai_Google_Calendar__list_events"
CALENDAR_MODEL = "sonnet"
HARD_TIMEOUT_SECONDS = 90
WINDOW_MARGIN = timedelta(minutes=45)       # events are asked for in [recording start - 45 min, recording start + 45 min]
MAX_WINDOW = timedelta(hours=2)             # hard ceiling of any window handed to fetch_events (sanity, the margins give 90 min)
SYSTEM_PROMPT = "You are a careful assistant. Follow instructions exactly."
CALENDAR_FILE = "calendar.json"


@dataclass
class CalendarMatch:
    title: str
    attendees: list = field(default_factory=list)       # [{"name": str, "email": str}]
    conference_url: Optional[str] = None
    start: str = ""
    end: str = ""
    event_id: Optional[str] = None

    def attendee_labels(self) -> list[str]:
        return [a.get("name") or a.get("email") or "" for a in self.attendees if a.get("name") or a.get("email")]

    def to_dict(self) -> dict:
        """What calendar.json stores (and the pipeline uses): the matched event's title, start, end and its attendees' display
        names and emails. No event id, link, description, location, organizer or any other event."""
        return {"matched": True, "title": self.title, "start": self.start, "end": self.end,
                "attendees": self.attendee_labels(), "attendee_details": self.attendees, "fetched": now_iso()}


# ---------------------------------------------------------------------------------- pure logic (unit-tested)
def events_from_tool_results(raw: list) -> Optional[list]:
    """First tool_result that is a list_events payload -> its events (the 'events' key is ABSENT for an empty window,
    verified). content is a JSON string or a list of {type: text, text}. None if no such result was seen."""
    for content in raw:
        text = content if isinstance(content, str) else "".join(
            x.get("text", "") for x in (content or []) if isinstance(x, dict))
        try:
            data = json.loads(text)
        except ValueError:
            continue
        if isinstance(data, dict) and ("events" in data or "accessRole" in data):
            events = data.get("events") or []
            return [e for e in events if isinstance(e, dict)]
    return None


_MEET_CODE = re.compile(r"meet\.google\.com/(?:lookup/)?([a-z]{3}-[a-z]{4}-[a-z]{3})", re.I)
_ZOOM_ID = re.compile(r"zoom\.(?:us|com)/(?:j|w|my|wc/join)/(\d{8,})", re.I)
_TEAMS_ID = re.compile(r"meetup-join/([^/?#\s\"]+)", re.I)
_HOSTS = (("meet", re.compile(r"meet\.google\.com", re.I)),          # link hosts: words in a description do not count
          ("zoom", re.compile(r"zoom\.(?:us|com)\b", re.I)),
          ("teams", re.compile(r"teams\.(?:microsoft|live)\.com", re.I)))
_SOLUTIONS = (("meet", re.compile(r"hangoutsmeet|google meet", re.I)),   # names inside conferenceData.conferenceSolution
              ("zoom", re.compile(r"zoom", re.I)),
              ("teams", re.compile(r"teams", re.I)))
KNOWN_PLATFORMS = ("meet", "zoom", "teams")
# The platform of every other call (Slack huddle, Webex, a Whereby page, ...: session.json `platform` "call"): it has no conference host of its
# own to compare, but it is not Meet, Zoom or Teams either, so an event whose conference is one of those three is not this call.
CALL_PLATFORM = "call"


def meeting_key(url: Optional[str]) -> Optional[str]:
    """Stable id of a meeting link (Meet code, Zoom meeting id, Teams thread id), lower case; None if not recognised."""
    if not url:
        return None
    for pattern in (_MEET_CODE, _ZOOM_ID, _TEAMS_ID):
        m = pattern.search(url)
        if m:
            return unquote(m.group(1)).lower()
    return None


def _event_window(event: dict) -> Optional[tuple[datetime, datetime]]:
    start, end = event.get("start") or {}, event.get("end") or {}
    a, b = parse_iso(start.get("dateTime")), parse_iso(end.get("dateTime"))   # all-day events only have "date"
    if a is None or b is None:
        return None
    return (a if a.tzinfo else a.astimezone()), (b if b.tzinfo else b.astimezone())


def _others(event: dict) -> list[dict]:
    out = []
    for a in event.get("attendees") or []:
        if isinstance(a, dict) and not a.get("self") and not a.get("resource") and (a.get("email") or a.get("displayName")):
            out.append(a)
    return out


def event_conference(ev: dict) -> tuple[set, set, bool]:
    """(meeting keys, platforms, has_any_conference_field) of an event: Meet codes / Zoom ids / Teams thread ids found anywhere in
    it (conference data, link fields, location, description) and the platforms they (or the conference solution) belong to."""
    blob = unquote(json.dumps(ev, ensure_ascii=False)).lower()
    keys = {m.group(1).lower() for rx in (_MEET_CODE, _ZOOM_ID, _TEAMS_ID) for m in rx.finditer(blob)}
    platforms = {name for name, rx in _HOSTS if rx.search(blob)}
    solution = json.dumps(ev.get("conferenceData") or {}, ensure_ascii=False)
    platforms |= {name for name, rx in _SOLUTIONS if rx.search(solution)}
    any_conf = bool(ev.get("conferenceUrl") or ev.get("hangoutLink") or ev.get("conferenceData") or keys or platforms)
    return keys, platforms, any_conf


_URL = re.compile(r"https?://|www\.", re.I)


def _physical_location(ev: dict) -> bool:
    """A free-text location that is not a link ('Restaurant Foo, 12 Main St'): the event happens somewhere else than a call."""
    loc = str(ev.get("location") or "").strip()
    return bool(loc) and not _URL.search(loc) and not any(rx.search(loc) for _n, rx in _HOSTS)


def pick_event(events: list, start: datetime, end: Optional[datetime], meeting_url: Optional[str] = None,
               platform: Optional[str] = None) -> Optional[dict]:
    """The calendar event this recording belongs to, or None. A wrong title is worse than none, so:

    * the event must overlap the recording;
    * an event whose OWN conference link belongs to a different meeting (a Meet code / Zoom id / Teams thread that differs from
      the recorded `meeting_url`) is rejected, and so is an event whose conference platform is not the recorded `platform`
      (Zoom event for a Meet recording, a Webex link for a Teams recording, ...). A recording of platform `call` (another app) has no platform
      of its own to compare: a Meet / Zoom / Teams event is refused for it, any other event follows the rules below like for a manual recording;
    * an event with the recorded link is the strongest match; an event with a conference link of the right platform needs a
      real overlap; an event WITHOUT any conference link (a dinner, a focus block) is only accepted when it covers >= 60 % of
      the recording and the recording covers >= 50 % of it, it has another attendee and no physical location;
    * ambiguous ties return None.
    """
    if start.tzinfo is None:
        start = start.astimezone()
    end = end or start + timedelta(seconds=60)
    if end.tzinfo is None:
        end = end.astimezone()
    rec_len = max((end - start).total_seconds(), 60.0)
    min_overlap = min(120.0, 0.5 * rec_len)
    key = meeting_key(meeting_url)
    is_other_call = platform == CALL_PLATFORM
    platform = platform if platform in KNOWN_PLATFORMS else None
    scored: list[tuple[float, bool, dict]] = []
    for ev in events or []:
        if not isinstance(ev, dict) or ev.get("status") == "cancelled" or not (ev.get("summary") or "").strip():
            continue
        if ev.get("eventType") in ("outOfOffice", "workingLocation", "focusTime"):
            continue
        if any(isinstance(a, dict) and a.get("self") and a.get("responseStatus") == "declined"
               for a in ev.get("attendees") or []):
            continue
        window = _event_window(ev)
        if window is None:
            continue
        ev_start, ev_end = window
        overlap = (min(ev_end, end) - max(ev_start, start)).total_seconds()
        if overlap <= 0:
            continue
        ev_len = max((ev_end - ev_start).total_seconds(), 60.0)
        keys, platforms, any_conf = event_conference(ev)
        if key and keys and key not in keys:
            continue                     # the event's own link is another meeting
        if platform and any_conf and platform not in platforms:
            continue                     # a conference of another (or an unknown) platform
        if is_other_call and platforms.intersection(KNOWN_PLATFORMS):
            continue                     # a Meet / Zoom / Teams event for a call of another app
        url_match = bool(key and key in keys)
        others = _others(ev)
        if not url_match:
            if any_conf:
                ok = overlap >= min_overlap
            else:
                ok = (overlap >= 0.6 * rec_len and overlap >= 0.5 * ev_len and bool(others) and not _physical_location(ev))
            if not ok:
                continue
        score = (1000.0 if url_match else 0.0) + (50.0 if any_conf else 0.0) + 3.0 * min(len(others), 10) \
            + 20.0 * min(overlap / ev_len, 1.0) + 20.0 * min(overlap / rec_len, 1.0) \
            - abs((ev_start - start).total_seconds()) / 600.0
        scored.append((score, url_match, ev))
    if not scored:
        return None
    scored.sort(key=lambda t: t[0], reverse=True)
    if len(scored) > 1 and not scored[0][1] and scored[0][0] - scored[1][0] < 5.0:
        return None                      # two similar candidates and no link to decide: do not guess
    return scored[0][2]


def match_from_event(ev: dict) -> CalendarMatch:
    attendees = []
    for a in _others(ev):
        attendees.append({"name": (a.get("displayName") or "").strip(), "email": (a.get("email") or "").strip()})
    url = ev.get("conferenceUrl") or ev.get("hangoutLink")
    if not url:
        m = _MEET_CODE.search(json.dumps(ev)) or None
        url = f"https://meet.google.com/{m.group(1)}" if m else None
    return CalendarMatch(title=re.sub(r"\s+", " ", ev.get("summary") or "").strip(), attendees=attendees,
                         conference_url=url, start=(ev.get("start") or {}).get("dateTime", ""),
                         end=(ev.get("end") or {}).get("dateTime", ""), event_id=ev.get("id"))


# ---------------------------------------------------------------------------------- claude 2-turn query
class CalendarUnavailable(Exception):
    pass


class CalendarOverage(CalendarUnavailable):
    """Claude reported extra-usage billing during the lookup and NOTE_STOP_ON_OVERAGE=1: the marker is written and the caller
    must not go on to spend a note call (lookup_calendar re-raises this one exception)."""


def local_tz_name() -> str:
    try:
        target = os.readlink("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return "UTC"


def build_argv(claude_bin: str) -> list[str]:
    return [claude_bin, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", CALENDAR_MODEL, "--effort", "low", "--tools", "ToolSearch", "--allowedTools", TOOL,
            "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
            "--system-prompt", SYSTEM_PROMPT]


def _ask(window_start: datetime, window_end: datetime) -> str:
    return (f'Call {TOOL} once with calendarId "primary", startTime "{window_start.isoformat()}", '
            f'endTime "{window_end.isoformat()}", timeZone "{local_tz_name()}". '
            "After the tool returns, reply with the single word DONE.")


def _kill(proc: subprocess.Popen) -> None:
    for sig, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, None)):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def fetch_events(cfg: Config, window_start: datetime, window_end: datetime, timeout_s: float = HARD_TIMEOUT_SECONDS) -> list:
    """Raises CalendarUnavailable (or another Exception) on any problem. One claude process = one call of the meeting's call budget,
    logged in usage.jsonl as stage "calendar" (auth: subscription) whatever the outcome. Always the claude.ai login, never a key.
    The lane gate is the first statement (SPEC 18): a closed calendar lane raises CalendarUnavailable before anything else happens."""
    block = lanes.gate("calendar")
    if block is not None:
        raise CalendarUnavailable(block.message)
    claude_bin = Path(cfg.claude_bin)
    if not (claude_bin.is_file() and os.access(claude_bin, os.X_OK)):
        raise CalendarUnavailable("claude CLI not found")
    pinned = verify_claude_bin(cfg)                       # company policy with a signature pin: the binary must match before it is started
    if pinned is not None:
        raise CalendarUnavailable(pinned.message)
    if apikey.is_api(cfg):
        # CLAUDE_AUTH=api: nobody has checked for a claude.ai login yet (the readiness check only looked at the key)
        ok, _info = preflight(str(claude_bin), cfg=cfg)
        if not ok:
            raise CalendarUnavailable("no claude.ai login: the calendar connector needs one (api mode), lookup skipped")
        money = usage.budget_block(cfg, "calendar")
        if money is not None:
            log.info("calendar lookup skipped: %s", money.message)
            usage.record(cfg, "calendar", requested=CALENDAR_MODEL, outcome=money.kind, auth=usage.AUTH_SUBSCRIPTION)
            raise CalendarUnavailable(money.message)
    budget = usage.current_budget()
    if budget is not None and not budget.take("calendar"):
        log.info("calendar lookup skipped: claude call cap reached (%d)", budget.limit)
        usage.record(cfg, "calendar", requested=CALENDAR_MODEL, outcome=usage.OUTCOME_CAP, auth=usage.AUTH_SUBSCRIPTION)
        raise CalendarUnavailable("claude call cap reached")
    t0 = time.monotonic()
    meter = {"outcome": "error", "models": [], "overage": False, "cost": None}
    try:
        return _fetch_events(cfg, claude_bin, window_start, window_end, timeout_s, meter)
    except CalendarOverage:
        meter["outcome"] = "overage_guard"
        raise
    except TimeoutError:
        meter["outcome"] = "timeout"
        raise
    finally:
        usage.record(cfg, "calendar", models=meter["models"], requested=CALENDAR_MODEL, duration_s=time.monotonic() - t0,
                     is_using_overage=meter["overage"], outcome=meter["outcome"], cost_usd=meter["cost"],
                     auth=usage.AUTH_SUBSCRIPTION)


def _fetch_events(cfg: Config, claude_bin: Path, window_start: datetime, window_end: datetime, timeout_s: float,
                  meter: dict) -> list:
    cwd = Path(cfg.claude_cwd)
    cwd.mkdir(parents=True, exist_ok=True)
    if window_end - window_start > MAX_WINDOW:
        window_end = window_start + MAX_WINDOW
    extra = lanes.llm_child_env()                         # only with a valid policy: fixed telemetry-off names; else clean_env() as it was
    proc = subprocess.Popen(build_argv(str(claude_bin)), cwd=str(cwd), env=clean_env(extra=extra) if extra else clean_env(), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
                            start_new_session=True)
    lines: "queue.Queue[Optional[str]]" = queue.Queue()

    def pump() -> None:
        try:
            for line in proc.stdout:
                lines.put(line)
        except (OSError, ValueError):
            pass
        lines.put(None)

    pump_thread = threading.Thread(target=pump, daemon=True)
    pump_thread.start()

    def send(text: str) -> None:
        proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
        proc.stdin.flush()

    deadline = time.monotonic() + timeout_s
    results = 0
    raw: list = []
    with child_dies_with_us(proc):
        try:
            send("Reply with the single word OK.")
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("calendar lookup timed out")
                try:
                    line = lines.get(timeout=min(remaining, 1.0))
                except queue.Empty:
                    continue
                if line is None:
                    break
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                kind = obj.get("type")
                if kind == "rate_limit_event":
                    info = obj.get("rate_limit_info") or {}
                    if info.get("isUsingOverage"):
                        meter["overage"] = True
                        if apikey.is_api(cfg):
                            # api mode: the overage logic is not used (no marker, nothing stops the note); the usage.jsonl line shows it
                            log.warning("calendar lookup: the claude.ai login reports extra-usage (overage) billing")
                            continue
                        # always recorded (guard on or off); only the guard stops the run
                        overage.write_marker(cfg, resets_at=info.get("resetsAt"), rate_limit_type=info.get("rateLimitType"),
                                             source="calendar")
                        if cfg.note_stop_on_overage:
                            raise CalendarOverage("extra-usage (overage) billing reported; lookup aborted")
                        log.warning("calendar lookup: Claude reports extra-usage (overage) billing; allowed (NOTE_STOP_ON_OVERAGE=0)")
                elif kind == "system" and obj.get("subtype") == "init" and obj.get("apiKeySource") not in (None, "none"):
                    raise CalendarUnavailable("refusing: apiKeySource is not 'none'")
                elif kind == "user" and isinstance(obj.get("message", {}).get("content"), list):
                    for part in obj["message"]["content"]:
                        if isinstance(part, dict) and part.get("type") == "tool_result" and not part.get("is_error"):
                            raw.append(part.get("content"))
                elif kind == "result":
                    results += 1
                    meter["cost"] = result_cost(obj)
                    for model in (obj.get("modelUsage") or {}):
                        if model not in meter["models"]:
                            meter["models"].append(model)
                    if obj.get("is_error"):
                        raise CalendarUnavailable("claude error during calendar lookup")
                    if results == 1:
                        time.sleep(1.0)          # connectors have connected by now
                        send(_ask(window_start, window_end))
                    else:
                        break
        finally:
            try:
                proc.stdin.close()
            except (OSError, ValueError):
                pass
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                _kill(proc)
            pump_thread.join(timeout=5)
            if not pump_thread.is_alive():
                try:
                    proc.stdout.close()
                except (OSError, ValueError):
                    pass
    events = events_from_tool_results(raw)
    if events is None:
        meter["outcome"] = "no_tool"
        raise CalendarUnavailable("no list_events result seen (connector not available?)")
    meter["outcome"] = "ok"
    return events


def enabled(cfg: Config) -> bool:
    """CALENDAR_LOOKUP=auto (default) or anything but an 'off' word. The user can switch the whole lookup off with CALENDAR_LOOKUP=0."""
    return str(cfg.calendar_lookup).strip().lower() not in ("0", "off", "false", "no", "none", "")


def lookup_calendar(cfg: Config, session: dict, timeout_s: float = HARD_TIMEOUT_SECONDS,
                    session_dir: Optional[Path] = None) -> Optional[CalendarMatch]:
    """CALENDAR_LOOKUP=auto|0. Returns the matching event or None for no match / disabled / ANY failure. Never raises, with ONE
    exception: CalendarOverage (extra-usage billing seen while NOTE_STOP_ON_OVERAGE=1) is surfaced so that the caller can stop
    before the note call. With the guard off the overage is only logged and recorded in overage.json.
    SPEC 18: the lane gate is the first statement; a closed calendar lane is None (no process, no event title is asked for)."""
    if lanes.gate("calendar") is not None:
        return None
    if not enabled(cfg):
        return None
    try:
        start = session_start(session, session_dir)
        if start is None:
            return None
        if start.tzinfo is None:
            start = start.astimezone()
        end = parse_iso(session.get("end_time"))
        if end is not None and end.tzinfo is None:
            end = end.astimezone()
        # only the hour and a half around the START is asked for (the matcher still needs the event to overlap the recording)
        events = fetch_events(cfg, start - WINDOW_MARGIN, start + WINDOW_MARGIN, timeout_s)
        picked = pick_event(events, start, end, session.get("meeting_url"), session.get("platform"))
        log.info("calendar lookup: %d event(s) in the window, %s", len(events), "matched" if picked else "no match")
        return match_from_event(picked) if picked else None      # everything else is dropped here, never stored or logged
    except CalendarOverage:
        raise
    except Exception as exc:          # best effort by design
        log.info("calendar lookup skipped: %s: %s", type(exc).__name__, str(exc)[:120])
        return None
