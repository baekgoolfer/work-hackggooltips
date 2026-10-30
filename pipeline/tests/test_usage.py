"""usage.py: the per-meeting call budget (reservations, thread safety), usage.jsonl (one line per claude call, written by the one
executor, the preflight and the calendar lookup) and the 7-day summary of `mcap usage` / `mcap doctor`. Every claude call goes to
the FAKE executable from notes_cli_support."""
import json
import os
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

from notes_cli_support import START, FakeClaude, TempCase, make_cfg, sample_note

from mcap import calendar_lookup, note, usage

KST = timezone(timedelta(hours=9))

SESSION = {"session_id": "2026-10-07_1400_zoom", "platform": "zoom", "platform_label": "Zoom", "title_hint": None,
           "meeting_url": None, "start_time": START, "end_time": "2026-10-07T15:03:40+09:00"}


class BudgetTests(unittest.TestCase):
    def test_plain_counter(self):
        budget = usage.CallBudget(2)
        self.assertEqual([budget.take() for _ in range(3)], [True, True, False])
        self.assertEqual((budget.used, budget.denied["?"]), (2, 1))

    def test_reservations_leave_the_rest_to_the_cleanup_and_nobody_else_can_touch_them(self):
        budget = usage.CallBudget(30, usage.planned_reserve(calendar=True, verify=True))
        self.assertEqual(budget.reserved, {"note": 2, "calendar": 1, "verify": 2})
        self.assertEqual(budget.available("cleanup"), 25)            # 30 - 5 kept for the other stages
        self.assertEqual([budget.take("cleanup") for _ in range(26)], [True] * 25 + [False])
        self.assertEqual(budget.denied["cleanup"], 1)
        self.assertEqual(budget.available("cleanup"), 0)
        self.assertEqual([budget.take("calendar"), budget.take("calendar")], [True, False])   # its own single call
        self.assertEqual([budget.take("note") for _ in range(3)], [True, True, False])
        self.assertEqual([budget.take("verify") for _ in range(3)], [True, True, False])
        self.assertEqual(budget.used, 30)

    def test_a_stage_without_reservation_is_squeezed_but_the_note_is_never_starved(self):
        budget = usage.CallBudget(5, usage.planned_reserve(calendar=True, verify=True))
        self.assertEqual(budget.available("cleanup"), 0)             # 5 - (2 + 1 + 2)
        self.assertFalse(budget.take("cleanup"))
        self.assertEqual(budget.available("note"), 2)
        self.assertTrue(budget.take("note") and budget.take("note"))

    def test_reservations_are_clamped_in_priority_order_note_first(self):
        small = lambda cap: usage.CallBudget(cap, usage.planned_reserve(calendar=True, verify=True)).reserved
        self.assertEqual(small(4), {"note": 2, "calendar": 1, "verify": 1})
        self.assertEqual(small(3), {"note": 2, "calendar": 1})
        self.assertEqual(small(2), {"note": 2})
        self.assertEqual(small(1), {"note": 1})

    def test_no_calendar_and_no_verify_free_their_calls_for_the_cleanup(self):
        budget = usage.CallBudget(30, usage.planned_reserve(calendar=False, verify=False))
        self.assertEqual(budget.reserved, {"note": 2})
        self.assertEqual(budget.available("cleanup"), 28)

    def test_exactly_the_limit_succeeds_under_concurrency(self):
        budget = usage.CallBudget(25)
        won = []
        lock = threading.Lock()

        def worker():
            for _ in range(10):
                if budget.take("cleanup"):
                    with lock:
                        won.append(1)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual((len(won), budget.used), (25, 25))

    def test_effective_cap_never_drops_below_one(self):
        from mcap.config import Config
        for raw, expected in ((30, 30), (1, 1), (0, 1), (-4, 1)):
            self.assertEqual(usage.effective_cap(Config(max_claude_calls_per_meeting=raw)), expected, raw)

    def test_meeting_scope_is_set_and_restored(self):
        self.assertIsNone(usage.current_budget())
        outer, inner = usage.CallBudget(3), usage.CallBudget(4)
        with usage.meeting("s1", outer):
            self.assertEqual((usage.current_budget(), usage.current_session_id()), (outer, "s1"))
            with usage.meeting("s2", inner):
                self.assertEqual((usage.current_budget(), usage.current_session_id()), (inner, "s2"))
            self.assertEqual(usage.current_session_id(), "s1")
        self.assertEqual((usage.current_budget(), usage.current_session_id()), (None, None))
        with self.assertRaises(RuntimeError):
            with usage.meeting("s3", outer):
                raise RuntimeError("boom")
        self.assertIsNone(usage.current_budget())                    # also after an exception


class LogTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def lines(self):
        return [json.loads(line) for line in usage.usage_path(self.cfg).read_text(encoding="utf-8").splitlines()]

    def test_one_json_line_per_call_with_the_documented_fields(self):
        usage.record(self.cfg, "note", models=["claude-opus-5"], requested="opus", duration_s=12.34, is_using_overage=True,
                     outcome="ok", attempt=1, session_id="2026-10-07_1400_zoom", cost_usd=0.4321)
        usage.record(self.cfg, "verify", requested="opus", outcome="timeout", session_id="2026-10-07_1400_zoom")
        first, second = self.lines()
        self.assertEqual(usage.usage_path(self.cfg), self.cfg.support_dir / "usage.jsonl")
        self.assertEqual(set(first), {"ts", "session_id", "stage", "model", "models", "requested_model", "duration_s", "isUsingOverage",
                                      "outcome", "attempt", "auth", "cost_usd"})                # SPEC 17: the billing path and the cost
        self.assertEqual((first["auth"], first["cost_usd"]), ("subscription", 0.4321))
        self.assertEqual((second["auth"], second["cost_usd"]), ("subscription", 0.0))
        self.assertEqual((first["stage"], first["model"], first["models"], first["duration_s"], first["isUsingOverage"], first["outcome"]),
                         ("note", "claude-opus-5", ["claude-opus-5"], 12.3, True, "ok"))
        self.assertEqual(first["session_id"], "2026-10-07_1400_zoom")
        datetime.fromisoformat(first["ts"])
        self.assertEqual((second["models"], second["model"], second["isUsingOverage"]), ([], "opus", False))   # requested model as fallback

    def test_the_session_id_comes_from_the_running_meeting(self):
        with usage.meeting("2026-10-08_0900_teams", usage.CallBudget(5)):
            usage.record(self.cfg, "cleanup", outcome="ok")
        usage.record(self.cfg, "preflight", outcome="ok")
        self.assertEqual([e["session_id"] for e in self.lines()], ["2026-10-08_0900_teams", None])

    def test_a_write_problem_never_raises(self):
        blocker = self.root / "blocker"
        blocker.write_text("a file, not a directory")
        cfg = make_cfg(self.root / "other")
        cfg.support_dir = blocker / "Support"                         # mkdir below a regular file fails
        usage.record(cfg, "note", outcome="ok")                         # must not raise
        self.assertEqual(usage.read_entries(cfg), [])

    def test_reading_skips_garbage_and_old_entries(self):
        now = datetime.now().astimezone()
        old = (now - timedelta(days=10)).isoformat(timespec="seconds")
        path = usage.usage_path(self.cfg)
        path.write_text("\n".join([
            "not json", "[1, 2]", '{"stage": "note"}', json.dumps({"ts": old, "stage": "note", "outcome": "ok"}),
            json.dumps({"ts": now.isoformat(timespec="seconds"), "stage": "note", "outcome": "ok"})]) + "\n", encoding="utf-8")
        self.assertEqual(len(usage.read_entries(self.cfg)), 2)
        self.assertEqual(len(usage.read_entries(self.cfg, since=now - timedelta(days=7))), 1)
        self.assertEqual(usage.read_entries(make_cfg(self.root / "none")), [])

    def test_summary_counts_calls_stages_overage_and_keeps_preflight_and_cap_refusals_apart(self):
        sid = "2026-10-07_1400_zoom"
        for stage, kw in (("cleanup", {}), ("cleanup", {}), ("cleanup", {"outcome": "overloaded"}), ("note", {"is_using_overage": True}),
                          ("verify", {}), ("calendar", {}), ("preflight", {}), ("preflight", {}), ("verify", {"outcome": usage.OUTCOME_CAP})):
            usage.record(self.cfg, stage, models=[] if stage == "preflight" else ["claude-opus-5"], duration_s=2.0, session_id=sid, **kw)
        usage.record(self.cfg, "note", models=["claude-opus-5", "claude-sonnet-5"], session_id="2026-10-08_1000_teams")
        summary = usage.week_summary(self.cfg)
        self.assertEqual(summary["calls"], 7)                                           # preflights and the refused call are not calls
        self.assertEqual(summary["by_stage"], {"calendar": 1, "cleanup": 3, "note": 2, "verify": 1})
        self.assertEqual((summary["preflight"], summary["skipped_by_cap"], summary["overage_calls"], summary["not_ok"]), (2, 1, 1, 1))
        self.assertEqual((summary["meetings"], summary["max_calls_per_meeting"]), (2, 6))
        self.assertEqual(summary["by_model"], {"claude-opus-5": 7, "claude-sonnet-5": 1})
        text = "\n".join(usage.format_summary(summary))
        for needle in ("calls:        7", "cleanup 3", "note 2", "1 call(s) reported isUsingOverage=true", "1 call(s) refused by"):
            self.assertIn(needle, text)
        line = usage.one_line(summary)
        self.assertIn("7 call(s) in the last 7 days", line)
        self.assertIn("overage) seen in 1 call(s)", line)

    def test_an_empty_log_says_so(self):
        summary = usage.week_summary(self.cfg)
        self.assertEqual(summary["calls"], 0)
        self.assertEqual(usage.format_summary(summary), ["No claude call recorded in the last 7 days."])
        self.assertIn("no claude call recorded", usage.one_line(summary))


class ExecutorLoggingTests(TempCase):
    """Every claude process the pipeline starts leaves a line: the shared executor (cleanup / note / verify), the preflight, the
    calendar lookup; a call the cap refuses leaves a `cap_reached` line and starts no process."""

    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.cfg = make_cfg(self.root, self.fake, note_timeout_seconds=60, calendar_lookup="auto")

    def lines(self, stage=None):
        entries = usage.read_entries(self.cfg)
        return [e for e in entries if stage is None or e["stage"] == stage]

    def call(self, stage="note", **kw):
        return note.call_claude(self.cfg, "prompt", note.extract_note, timeout_s=60, stage=stage, **kw)

    def test_a_successful_call_is_logged_with_the_resolved_model_and_the_stage(self):
        with usage.meeting("2026-10-07_1400_zoom", usage.CallBudget(5)) as budget:
            res = self.call("verify")
        self.assertTrue(res.ok, res.error)
        entry, = self.lines("verify")
        self.assertEqual((entry["session_id"], entry["models"], entry["requested_model"], entry["outcome"], entry["attempt"]),
                         ("2026-10-07_1400_zoom", ["claude-opus-5"], "opus", "ok", 1))
        self.assertGreaterEqual(entry["duration_s"], 0.0)
        self.assertFalse(entry["isUsingOverage"])
        self.assertEqual((budget.used, budget.by_stage["verify"]), (1, 1))

    def test_every_attempt_is_a_line_and_a_call_of_the_budget(self):
        self.fake.set(runs=[{"mode": "overloaded"}, {"mode": "success", "note": sample_note()}])
        with usage.meeting("s", usage.CallBudget(5)) as budget:
            res = self.call()
        self.assertTrue(res.ok, res.error)
        self.assertEqual([(e["attempt"], e["outcome"], e["requested_model"]) for e in self.lines("note")],
                         [(1, "overloaded", "opus"), (2, "ok", "sonnet")])
        self.assertEqual(budget.used, 2)
        self.assertEqual(len(self.fake.calls("note")), 2)

    def test_overage_is_logged_per_call(self):
        self.fake.set(runs=[{"mode": "overage_late", "note": sample_note()}])
        self.call()
        self.assertTrue(self.lines("note")[0]["isUsingOverage"])

    def test_a_call_the_cap_refuses_starts_no_process_and_is_logged_as_cap_reached(self):
        budget = usage.CallBudget(1, {"note": 1})
        with usage.meeting("s", budget):
            res = self.call("cleanup")
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, "budget")
        self.assertIn("MAX_CLAUDE_CALLS_PER_MEETING=1", res.error)
        self.assertEqual(self.fake.calls(), [])
        entry, = self.lines("cleanup")
        self.assertEqual(entry["outcome"], usage.OUTCOME_CAP)
        self.assertEqual(budget.denied["cleanup"], 1)

    def test_the_cap_that_arrives_before_the_retry_keeps_the_first_failure(self):
        self.fake.set(runs=[{"mode": "overloaded"}, {"mode": "success", "note": sample_note()}])
        with usage.meeting("s", usage.CallBudget(1)):
            res = self.call()
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, "overloaded")
        self.assertEqual(len(self.fake.calls("note")), 1)
        self.assertEqual([e["outcome"] for e in self.lines("note")], ["overloaded", usage.OUTCOME_CAP])

    def test_without_a_meeting_scope_calls_are_still_logged_and_not_capped(self):
        self.call()
        self.call()
        self.assertEqual(len(self.lines("note")), 2)
        self.assertIsNone(self.lines("note")[0]["session_id"])

    def test_the_preflight_is_logged_as_a_local_call_without_a_model(self):
        ready = note.check_ready(self.cfg)
        self.assertTrue(ready.ok)
        entry, = self.lines("preflight")
        self.assertEqual((entry["outcome"], entry["models"]), ("ok", []))
        self.fake.set(auth={"exit": 1, "json": {"loggedIn": False}})
        note.check_ready(self.cfg)
        self.assertEqual([e["outcome"] for e in self.lines("preflight")], ["ok", "auth"])

    def test_the_calendar_lookup_is_logged_and_counted(self):
        self.fake.set(calendar={"mode": "ok", "events": []})
        budget = usage.CallBudget(3, {"note": 2, "calendar": 1})
        with usage.meeting("s", budget):
            self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        entry, = self.lines("calendar")
        self.assertEqual((entry["outcome"], entry["models"], entry["session_id"]), ("ok", ["claude-sonnet-5"], "s"))
        self.assertEqual(budget.by_stage["calendar"], 1)

    def test_a_calendar_lookup_over_the_cap_makes_no_call(self):
        budget = usage.CallBudget(2, {"note": 2})
        with usage.meeting("s", budget):
            self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls(), [])
        self.assertEqual([e["outcome"] for e in self.lines("calendar")], [usage.OUTCOME_CAP])
        self.assertEqual(budget.denied["calendar"], 1)

    def test_failed_calendar_lookups_are_logged_with_their_reason(self):
        for mode, outcome in (("no_tool", "no_tool"), ("error", "error")):
            self.fake.set(calendar={"mode": mode})
            self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual([e["outcome"] for e in self.lines("calendar")], ["no_tool", "error"])


def at(day: int, hour: int = 12, minute: int = 0, second: int = 0) -> datetime:
    return datetime(2026, 10, day, hour, minute, second, tzinfo=KST)


class FrozenClock:
    """Replaces usage.clock (the one place the date comes from): `with FrozenClock(at(7, 23, 59)):` ... then `.set(at(8, 0, 1))`."""

    def __init__(self, now: datetime):
        self.now = now
        self.patch = mock.patch.object(usage, "clock", lambda: self.now)

    def set(self, now: datetime) -> None:
        self.now = now

    def __enter__(self):
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()


class CostLogTests(TempCase):
    """SPEC 17: auth + cost_usd on every line, the run cost of the meeting, the day cost, the 7 / 30 day sums."""

    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)
        self.api = make_cfg(self.root / "api", claude_auth="api")
        patcher = mock.patch.object(usage, "_missing_cost_logged", False)
        patcher.start()
        self.addCleanup(patcher.stop)

    def lines(self, cfg=None):
        return [json.loads(l) for l in usage.usage_path(cfg or self.cfg).read_text(encoding="utf-8").splitlines()]

    def test_auth_defaults_to_the_configured_mode_but_preflight_and_calendar_are_always_subscription(self):
        for stage in ("cleanup", "note", "verify", "preflight", "calendar", "check"):
            usage.record(self.api, stage, models=["m"], cost_usd=0.1)
            usage.record(self.cfg, stage, models=["m"], cost_usd=0.1)
        api = {e["stage"]: e["auth"] for e in self.lines(self.api)}
        sub = {e["stage"]: e["auth"] for e in self.lines(self.cfg)}
        self.assertEqual(api, {"cleanup": "api", "note": "api", "verify": "api", "preflight": "subscription",
                               "calendar": "subscription", "check": "api"})
        self.assertEqual(set(sub.values()), {"subscription"})
        usage.record(self.api, "note", models=["m"], cost_usd=0.1, auth="subscription")           # explicit wins
        self.assertEqual(self.lines(self.api)[-1]["auth"], "subscription")

    def test_cost_is_a_number_on_every_line_and_bad_values_count_as_zero(self):
        for cost in (0.5, None, -3.0, float("nan"), "abc", True):
            usage.record(self.cfg, "note", cost_usd=cost)                                            # no models: not flagged as missing
        costs = [e["cost_usd"] for e in self.lines()]
        self.assertEqual(costs[0], 0.5)
        self.assertEqual(costs[1:], [0.0] * 5)                                                        # None, negative, NaN, text, True
        self.assertTrue(all(isinstance(c, float) for c in costs))

    def test_a_result_without_cost_is_flagged_on_the_line_and_logged_once_per_process(self):
        with self.assertLogs("mcap.usage", level="WARNING") as logged:
            usage.record(self.api, "note", models=["claude-opus-5"])
            usage.record(self.api, "cleanup", models=["claude-opus-5"])
        self.assertEqual(len([m for m in logged.output if "no total_cost_usd" in m]), 1)
        self.assertTrue(all(e.get("cost_missing") is True and e["cost_usd"] == 0.0 for e in self.lines(self.api)))
        usage.record(self.api, "note", models=["claude-opus-5"], cost_usd=0.2)
        self.assertNotIn("cost_missing", self.lines(self.api)[-1])
        self.assertEqual(usage.summarize(usage.read_entries(self.api))["cost_missing"], 2)

    def test_the_meeting_cost_counts_api_calls_inside_the_scope_only(self):
        self.assertIsNone(usage.run_cost_usd())
        usage.record(self.api, "note", models=["m"], cost_usd=9.0)                                   # outside a run: not counted anywhere
        with usage.meeting("s1", usage.CallBudget(5)):
            self.assertEqual(usage.run_cost_usd(), 0.0)
            usage.record(self.api, "cleanup", models=["m"], cost_usd=1.25)
            usage.record(self.api, "note", models=["m"], cost_usd=0.75)
            usage.record(self.api, "calendar", models=["m"], cost_usd=4.0)                           # subscription: not counted
            usage.record(self.api, "verify", models=["m"], cost_usd=2.0, auth="subscription")
            self.assertEqual(usage.run_cost_usd(), 2.0)
        self.assertIsNone(usage.run_cost_usd())
        with usage.meeting("s2", usage.CallBudget(5)):
            self.assertEqual(usage.run_cost_usd(), 0.0)                                              # the next run starts at zero

    def test_day_cost_counts_api_lines_of_the_local_date_only(self):
        with FrozenClock(at(6, 23, 59, 59)):
            usage.record(self.api, "note", models=["m"], cost_usd=10.0)                              # yesterday
        with FrozenClock(at(7, 0, 0, 1)):
            usage.record(self.api, "note", models=["m"], cost_usd=1.5)
            usage.record(self.api, "cleanup", models=["m"], cost_usd=2.0)
            usage.record(self.api, "calendar", models=["m"], cost_usd=7.0)                           # subscription
        with FrozenClock(at(7, 23, 59, 59)):
            usage.record(self.api, "verify", models=["m"], cost_usd=0.25)
        with FrozenClock(at(8, 0, 0, 1)):
            usage.record(self.api, "note", models=["m"], cost_usd=100.0)                             # tomorrow
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 12)), 3.75)
        self.assertEqual(usage.day_cost_usd(self.api, "subscription", now=at(7, 12)), 7.0)
        self.assertEqual(usage.day_cost_usd(self.api, now=at(6, 12)), 10.0)
        self.assertEqual(usage.day_cost_usd(self.api, now=at(8, 12)), 100.0)
        self.assertEqual(usage.day_cost_usd(self.api, now=at(9, 12)), 0.0)

    def test_old_lines_without_auth_are_subscription_and_garbage_is_skipped(self):
        path = usage.usage_path(self.api)
        path.write_text("\n".join(["garbage", json.dumps({"ts": at(7).isoformat(), "stage": "note", "cost_usd": 5.0}),
                                   json.dumps({"ts": at(7).isoformat(), "stage": "note", "auth": "api", "cost_usd": "x"}),
                                   json.dumps({"ts": at(7).isoformat(), "stage": "note", "auth": "api", "cost_usd": 1.0})]) + "\n")
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 13)), 1.0)
        self.assertEqual(usage.day_cost_usd(make_cfg(self.root / "none"), now=at(7)), 0.0)         # no log at all

    def test_an_out_of_order_log_is_still_counted_the_budget_guards_money(self):
        path = usage.usage_path(self.api)
        rows = [(at(7, 9), 2.0), (at(1), 50.0), (at(7, 10), 3.0), (at(5), 7.0), (at(7, 8), 1.0)]                # not sorted by time
        path.write_text("\n".join(json.dumps({"ts": ts.isoformat(), "stage": "note", "auth": "api", "cost_usd": c}) for ts, c in rows) + "\n")
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 13)), 6.0)

    def test_the_day_cost_does_not_depend_on_the_spacing_of_the_json(self):
        # review finding: the byte pre-filter looked for the exact text `"auth": "api"`, so a line written with compact separators (another
        # tool, a later json.dumps(separators=(",", ":"))) silently dropped out of the money guard
        path = usage.usage_path(self.api)
        base = {"ts": at(7, 9).isoformat(), "stage": "note", "cost_usd": 2.0}
        lines = [json.dumps({**base, "auth": "api"}),                                    # the format record() writes
                 json.dumps({**base, "auth": "api"}, separators=(",", ":")),             # compact
                 json.dumps({"auth": "api", **base}, indent=None, separators=(", ", " : ")),        # another spacing and key order
                 json.dumps({**base, "auth": "subscription"}),                           # not api: never counted
                 json.dumps({**base, "auth": "api", "cost_usd": 100.0, "ts": at(8, 9).isoformat()})]   # another day
        path.write_text("\n".join(lines) + "\n")
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 13)), 6.0)

    def test_the_day_scan_stays_correct_on_a_long_log(self):
        path = usage.usage_path(self.api)
        old = [json.dumps({"ts": (at(7) - timedelta(days=d)).isoformat(), "stage": "note", "auth": "api", "cost_usd": 1.0}) for d in range(1, 400)]
        path.write_text("\n".join(old + [json.dumps({"ts": at(7, 9).isoformat(), "stage": "note", "auth": "api", "cost_usd": 2.0})]) + "\n")
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 13)), 2.0)

    def test_cost_summary_by_auth_and_stage_and_the_7_and_30_day_windows(self):
        for days_ago, stage, auth, cost in ((1, "note", "api", 1.0), (2, "cleanup", "api", 2.0), (3, "note", "subscription", 0.5),
                                            (10, "note", "api", 4.0), (20, "verify", "api", 8.0), (45, "note", "api", 100.0)):
            with FrozenClock(at(20) - timedelta(days=days_ago)):
                usage.record(self.api, stage, models=["m"], cost_usd=cost, auth=auth)
        windows = usage.cost_windows(self.api, now=at(20))
        self.assertEqual(sorted(windows), [7, 30])
        seven, thirty = windows[7], windows[30]
        self.assertEqual(seven["cost_by_auth"], {"api": 3.0, "subscription": 0.5})
        self.assertEqual(seven["cost_by_stage"], {"api": {"cleanup": 2.0, "note": 1.0}, "subscription": {"note": 0.5}})
        self.assertEqual(thirty["cost_by_auth"], {"api": 15.0, "subscription": 0.5})
        self.assertEqual(thirty["cost_by_stage"]["api"], {"cleanup": 2.0, "note": 5.0, "verify": 8.0})
        self.assertEqual((seven["cost_usd"], thirty["cost_usd"]), (3.5, 15.5))
        text = "\n".join(usage.format_costs(windows))
        for needle in ("last  7 days: $3.50", "last 30 days: $15.50", "api $3.00", "subscription $0.50", "cleanup $2.00, note $1.00"):
            self.assertIn(needle, text)
        line = usage.cost_one_line(windows)
        self.assertIn("last 7 days $3.50 (api $3.00, subscription $0.50 equivalent)", line)
        self.assertIn("last 30 days $15.50", line)

    def test_week_summary_carries_the_costs_too(self):
        usage.record(self.api, "note", models=["m"], cost_usd=1.5)
        usage.record(self.api, "verify", requested="opus", outcome=usage.OUTCOME_BUDGET_DAILY)
        summary = usage.week_summary(self.api)
        self.assertEqual((summary["cost_usd"], summary["cost_by_auth"]["api"], summary["calls"]), (1.5, 1.5, 1))
        self.assertEqual(summary["skipped_by_budget"], 1)                                             # a call that was not made is not a call
        text = "\n".join(usage.format_summary(summary))
        self.assertIn("1 call(s) not made because a USD budget was reached", text)
        self.assertIn("not made because a USD budget", usage.one_line(summary))


class BudgetBlockTests(TempCase):
    def setUp(self):
        super().setUp()
        self.api = make_cfg(self.root, claude_auth="api", claude_daily_budget_usd=30.0, claude_meeting_budget_usd=15.0)

    def spend(self, usd, stage="note", cfg=None, **kw):
        usage.record(cfg or self.api, stage, models=["m"], cost_usd=usd, **kw)

    def test_nothing_is_blocked_below_the_budgets(self):
        with FrozenClock(at(7)):
            self.spend(29.99)
            self.assertIsNone(usage.budget_block(self.api, "note"))
            self.assertIsNone(usage.budget_block(self.api, "cleanup"))

    def test_the_daily_budget_blocks_every_stage_the_note_included_at_exactly_the_limit(self):
        with FrozenClock(at(7)):
            self.spend(30.0)
            for stage in ("cleanup", "note", "verify", "calendar"):
                block = usage.budget_block(self.api, stage)
                self.assertIsNotNone(block, stage)
                self.assertEqual(block.kind, "budget_daily")
                self.assertEqual((block.used, block.limit), (30.0, 30.0))
                self.assertIn("$30.00 of $30.00", block.message)
                self.assertIn("midnight", block.message)
                self.assertEqual(block.resets_at, int(at(8, 0).timestamp()))                          # next local midnight

    def test_midnight_rollover_releases_the_daily_budget(self):
        with FrozenClock(at(7, 23, 59, 30)) as clock:
            self.spend(31.0)
            self.assertEqual(usage.budget_block(self.api, "note").kind, "budget_daily")
            clock.set(at(8, 0, 0, 30))
            self.assertIsNone(usage.budget_block(self.api, "note"))
            self.spend(31.0)                                                                           # today's spending starts at zero again
            self.assertEqual(usage.budget_block(self.api, "note").kind, "budget_daily")
        self.assertEqual(usage.day_cost_usd(self.api, now=at(7, 12)), 31.0)

    def test_the_meeting_budget_blocks_everything_but_the_note(self):
        with FrozenClock(at(7)), usage.meeting("s", usage.CallBudget(30)):
            self.spend(15.0, "cleanup")
            for stage in ("cleanup", "verify", "calendar"):
                block = usage.budget_block(self.api, stage)
                self.assertEqual(block.kind, "budget_meeting", stage)
                self.assertIn("$15.00 of $15.00", block.message)
                self.assertIsNone(block.resets_at)
            self.assertIsNone(usage.budget_block(self.api, "note"))                                   # the note is always reserved

    def test_the_meeting_budget_is_per_run_and_the_daily_one_still_applies_to_the_note(self):
        with FrozenClock(at(7)):
            with usage.meeting("s1", usage.CallBudget(30)):
                self.spend(20.0, "cleanup")
                self.assertIsNotNone(usage.budget_block(self.api, "verify"))
            with usage.meeting("s2", usage.CallBudget(30)):
                self.assertIsNone(usage.budget_block(self.api, "verify"))                            # a new run: 0 spent on it
                self.spend(11.0, "cleanup")                                                          # day total 31 >= 30
                self.assertEqual(usage.budget_block(self.api, "note").kind, "budget_daily")

    def test_the_meeting_budget_needs_a_run_scope(self):
        with FrozenClock(at(7)):
            self.spend(99.0, cfg=make_cfg(self.root / "x", claude_auth="api", claude_daily_budget_usd=0.0))
            cfg = make_cfg(self.root, claude_auth="api", claude_daily_budget_usd=0.0, claude_meeting_budget_usd=15.0)
            self.assertIsNone(usage.budget_block(cfg, "cleanup"))                                    # not inside usage.meeting()

    def test_zero_switches_a_budget_off(self):
        cfg = make_cfg(self.root, claude_auth="api", claude_daily_budget_usd=0.0, claude_meeting_budget_usd=0.0)
        with FrozenClock(at(7)), usage.meeting("s", usage.CallBudget(30)):
            self.spend(1000.0, "cleanup", cfg=cfg)
            for stage in ("cleanup", "note", "verify", "calendar"):
                self.assertIsNone(usage.budget_block(cfg, stage), stage)

    def test_the_budgets_only_apply_to_api_mode(self):
        sub = make_cfg(self.root, claude_daily_budget_usd=1.0, claude_meeting_budget_usd=1.0)         # subscription
        with FrozenClock(at(7)), usage.meeting("s", usage.CallBudget(30)):
            usage.record(sub, "note", models=["m"], cost_usd=500.0)                                   # the CLI's API-equivalent estimate
            for stage in ("cleanup", "note", "verify", "calendar"):
                self.assertIsNone(usage.budget_block(sub, stage), stage)
        # subscription lines never count towards an api budget, either
        with FrozenClock(at(7)):
            self.assertEqual(usage.day_cost_usd(sub, now=at(7)), 0.0)

    def test_budget_status_and_the_one_line_for_usage_and_doctor(self):
        with FrozenClock(at(7)):
            self.spend(12.5)
            status = usage.budget_status(self.api)
            self.assertEqual((status["used"], status["daily"], status["meeting"], status["reached"]), (12.5, 30.0, 15.0, False))
            line = usage.budget_line(self.api)
            self.assertIn("$12.50 of the $30.00 daily budget", line)
            self.assertIn("$15.00 per meeting run", line)
            self.assertNotIn("REACHED", line)
            self.spend(20.0)
            self.assertTrue(usage.budget_status(self.api)["reached"])
            self.assertIn("REACHED", usage.budget_line(self.api))
            off = make_cfg(self.root, claude_auth="api", claude_daily_budget_usd=0.0, claude_meeting_budget_usd=0.0)
            self.assertIn("no daily budget", usage.budget_line(off))
            self.assertIn("no per-meeting budget", usage.budget_line(off))


NEW_YORK = ZoneInfo("America/New_York")


class DaylightSavingTests(TempCase):
    """Review finding: `datetime.now().astimezone()` carries only the CURRENT utc offset, so 'local midnight' was an hour off on a
    DST change day (fall back: the first hour of the day was forgotten = the money guard undercounts; spring forward: an hour of the
    previous day was counted). The clock now returns a rules-based zone."""

    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root, claude_auth="api", claude_daily_budget_usd=100.0, claude_meeting_budget_usd=0.0)

    def write(self, rows):
        path = usage.usage_path(self.cfg)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps({"ts": ts, "stage": "note", "auth": "api", "cost_usd": cost, "outcome": "ok"}) + "\n"
                                for ts, cost in rows), encoding="utf-8")

    def test_fall_back_day_keeps_the_first_hour_and_drops_the_previous_evening(self):
        self.write([("2026-10-31T23:30:00-04:00", 1.0),      # the day before
                    ("2026-11-01T00:30:00-04:00", 10.0),     # the first hour of 11-01 (EDT), before the clock goes back
                    ("2026-11-01T03:00:00-05:00", 100.0)])   # after it (EST)
        now = datetime(2026, 11, 1, 10, 0, tzinfo=NEW_YORK)
        self.assertEqual(usage.day_cost_usd(self.cfg, now=now), 110.0)
        self.assertIsNotNone(usage.budget_block(self.cfg, "note", now))        # 110 >= 100: the guard sees all of it

    def test_spring_forward_day_does_not_count_the_previous_evening(self):
        self.write([("2026-03-07T23:30:00-05:00", 1.0), ("2026-03-08T00:30:00-05:00", 10.0), ("2026-03-08T04:00:00-04:00", 100.0)])
        now = datetime(2026, 3, 8, 10, 0, tzinfo=NEW_YORK)
        self.assertEqual(usage.day_cost_usd(self.cfg, now=now), 110.0)

    def test_the_next_midnight_is_the_real_local_midnight_on_a_dst_day(self):
        fall = datetime(2026, 11, 1, 10, 0, tzinfo=NEW_YORK)
        self.assertEqual(datetime.fromtimestamp(usage.next_midnight_epoch(fall), NEW_YORK), datetime(2026, 11, 2, 0, 0, tzinfo=NEW_YORK))
        spring = datetime(2026, 3, 8, 1, 0, tzinfo=NEW_YORK)
        self.assertEqual(datetime.fromtimestamp(usage.next_midnight_epoch(spring), NEW_YORK), datetime(2026, 3, 9, 0, 0, tzinfo=NEW_YORK))

    def test_the_default_now_of_the_budget_is_the_dst_aware_clock(self):
        self.write([("2026-11-01T00:30:00-04:00", 60.0), ("2026-11-01T03:00:00-05:00", 60.0)])    # 120 USD today, 60 of it before 01:00 EST

        class Instant(datetime):                       # "now" = 2026-11-01 10:00 in New York, whatever zone is asked for
            @classmethod
            def now(cls, tz=None):
                return datetime(2026, 11, 1, 15, 0, tzinfo=timezone.utc).astimezone(tz)

        with mock.patch.dict(os.environ, {"TZ": "America/New_York"}), mock.patch.object(usage, "datetime", Instant):
            self.assertEqual(usage.day_cost_usd(self.cfg), 120.0)
            block = usage.budget_block(self.cfg, "note")
            self.assertIsNotNone(block)                                          # 120 >= 100 only when the 00:30 EDT line counts
            self.assertEqual(datetime.fromtimestamp(block.resets_at, NEW_YORK), datetime(2026, 11, 2, 0, 0, tzinfo=NEW_YORK))

    def test_the_clock_uses_the_machine_zone_and_falls_back_to_a_fixed_offset(self):
        with mock.patch.dict(os.environ, {"TZ": "America/New_York"}):
            now = usage.clock()
            self.assertEqual(getattr(now.tzinfo, "key", None), "America/New_York")
        with mock.patch.dict(os.environ, {"TZ": ":Asia/Seoul"}):
            self.assertEqual(usage.clock().utcoffset(), timedelta(hours=9))
        with mock.patch.dict(os.environ, {"TZ": "EST5EDT4,M3.2.0,M11.1.0"}):      # a POSIX TZ string: no tz database key
            now = usage.clock()
            self.assertIsNotNone(now.utcoffset())                                  # still an aware local time, nothing raised


if __name__ == "__main__":
    unittest.main()
