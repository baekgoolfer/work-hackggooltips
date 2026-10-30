"""asr_usage.py (SPEC 18): the content-free usage record of the external ASR engines:
append, rotation, the daily minutes the cap counts, the summary, and the canary proof that no content can reach a line."""
import json
import os
import stat
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from asr_support import CANARY_FRAGMENTS, CANARY_TEXT, HOST, TOKEN
from net_guard_support import NoNetworkCase
from notes_cli_support import make_cfg

from mcap import asr_usage
from mcap import usage as claude_usage

KEYS = {"ts", "session_id", "engine", "kind", "host", "op", "status", "outcome", "attempt", "circuit", "requests", "audio_s", "bytes_out",
        "bytes_in", "dur_ms", "est_usd"}


def at(day: int = 15, hour: int = 12, minute: int = 0) -> datetime:
    return datetime(2026, 10, day, hour, minute, 0).astimezone()


class UsageCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)
        self.now = at()
        patcher = mock.patch.object(claude_usage, "clock", lambda: self.now)
        patcher.start()
        self.addCleanup(patcher.stop)

    def rec(self, **kw):
        values = dict(engine="remote", kind="server", host=HOST, op="chunk", status=200, audio_s=10.0, bytes_out=320000, bytes_in=800,
                      dur_ms=1500, outcome="ok")
        values.update(kw)
        asr_usage.record(self.cfg, **values)

    def lines(self, path=None):
        target = path or self.cfg.asr_usage_path
        return [json.loads(line) for line in target.read_text(encoding="utf-8").splitlines() if line.strip()]

    def raw(self, text, path=None):
        target = path or self.cfg.asr_usage_path
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(text)


class RecordTests(UsageCase):
    def test_a_line_has_exactly_the_documented_fields(self):
        self.rec(attempt=2, circuit="half-open", session_id="2026-10-15_0900_zoom")
        (line,) = self.lines()
        self.assertEqual(set(line), KEYS)
        self.assertEqual((line["engine"], line["kind"], line["host"], line["op"], line["status"], line["outcome"]),
                         ("remote", "server", HOST, "chunk", 200, "ok"))
        self.assertEqual((line["attempt"], line["circuit"], line["session_id"], line["requests"]), (2, "half-open", "2026-10-15_0900_zoom", 1))
        self.assertEqual((line["audio_s"], line["bytes_out"], line["bytes_in"], line["dur_ms"], line["est_usd"]), (10.0, 320000, 800, 1500, None))
        self.assertEqual(line["ts"], self.now.isoformat(timespec="seconds"))

    def test_the_file_is_where_the_config_says_and_private(self):
        self.rec()
        self.assertEqual(self.cfg.asr_usage_path, self.cfg.support_dir / "asr-usage.jsonl")
        self.assertEqual(stat.S_IMODE(os.stat(self.cfg.asr_usage_path).st_mode), 0o600)

    def test_lines_are_appended_one_per_attempt(self):
        for n in range(3):
            self.rec(attempt=n + 1)
        self.assertEqual([x["attempt"] for x in self.lines()], [1, 2, 3])

    def test_a_cost_estimate_is_kept_as_a_number_and_otherwise_null(self):
        self.rec(est_usd=0.0123456789)
        self.rec()
        self.assertEqual([x["est_usd"] for x in self.lines()], [0.012346, None])

    def test_the_session_defaults_to_the_running_pipeline(self):
        with claude_usage.meeting("2026-10-15_0900_zoom"):
            self.rec()
        self.rec()
        self.assertEqual([x["session_id"] for x in self.lines()], ["2026-10-15_0900_zoom", None])

    def test_an_explicit_session_wins_and_a_session_that_is_not_an_id_is_dropped(self):
        self.rec(session_id="2026-10-15_1000_meet")
        self.rec(session_id="a title with spaces\nand a newline")
        self.assertEqual([x["session_id"] for x in self.lines()], ["2026-10-15_1000_meet", None])

    def test_a_request_that_cannot_have_left_the_mac_counts_for_nothing(self):
        for outcome in ("denied:pre_connect", "denied:gate", "denied:host_not_allowed", "error:connect", "error:tls", "error:bad_request"):
            with self.subTest(outcome=outcome):
                self.rec(outcome=outcome, status=0, audio_s=12.0, bytes_out=500000, est_usd=1.0)
        for line in self.lines():
            self.assertEqual((line["requests"], line["audio_s"], line["bytes_out"], line["est_usd"]), (0, 0.0, 0, None))

    def test_a_request_that_may_have_reached_the_server_counts(self):
        cases = [("ok", 200), ("http_503", 503), ("http_401", 401), ("error:timeout", 0), ("error:protocol", 0), ("error:transport", 0),
                 ("error:aborted", 0), ("denied:redirect", 302), ("denied:response_too_large", 0)]
        for outcome, status in cases:
            with self.subTest(outcome=outcome):
                self.rec(outcome=outcome, status=status, audio_s=12.0, bytes_out=500000)
        for line in self.lines():
            self.assertEqual((line["requests"], line["audio_s"], line["bytes_out"]), (1, 12.0, 500000))

    def test_request_was_sent_is_one_rule(self):
        self.assertTrue(asr_usage.request_was_sent(200, "ok"))
        self.assertTrue(asr_usage.request_was_sent(0, "error:timeout"))
        self.assertTrue(asr_usage.request_was_sent(503, "weird"))        # an answer came back, whatever the word
        self.assertFalse(asr_usage.request_was_sent(0, "error:connect"))
        self.assertFalse(asr_usage.request_was_sent(0, None))
        self.assertFalse(asr_usage.request_was_sent(True, "denied:gate"))   # a bool is not a status

    def test_it_never_raises(self):
        blocker = self.root / "a-file"
        blocker.write_text("x", encoding="utf-8")
        broken = make_cfg(self.root)
        broken.support_dir = blocker / "inside"                          # the directory cannot be created
        with self.assertLogs("mcap.asr_usage", level="WARNING") as logs:
            asr_usage.record(broken, engine="remote", kind="server", host=HOST, op="chunk", status=200, audio_s=1, bytes_out=1, bytes_in=1,
                             dur_ms=1, outcome="ok")
        self.assertRegex(logs.output[0], r"Error$")                    # the exception class only: no path, no message
        with self.assertLogs("mcap.asr_usage", level="WARNING"):
            asr_usage.record(SimpleNamespace(), engine="x", kind="x", host="x", op="x", status=0, audio_s=0, bytes_out=0, bytes_in=0,
                             dur_ms=0, outcome="ok")                     # a config that is not one: still no exception

    def test_a_config_double_without_the_property_uses_the_support_dir(self):
        double = SimpleNamespace(support_dir=self.root / "elsewhere")
        asr_usage.record(double, engine="remote", kind="server", host=HOST, op="chunk", status=200, audio_s=1, bytes_out=1, bytes_in=1,
                         dur_ms=1, outcome="ok")
        self.assertTrue((self.root / "elsewhere" / "asr-usage.jsonl").exists())


class NoContentTests(UsageCase):
    """The canary: hostile text in every argument. The line must stay valid JSON with the same keys and carry none of it."""

    def test_no_argument_can_put_content_into_a_line(self):
        hostile = CANARY_TEXT + " " + TOKEN
        self.rec(engine=hostile, kind=hostile, host=hostile, op=hostile, outcome=hostile, circuit=hostile, session_id=hostile)
        self.rec(outcome="error:" + hostile, status=hostile, audio_s=hostile, bytes_out=hostile, bytes_in=hostile, dur_ms=hostile, attempt=hostile,
                 est_usd=hostile)
        self.rec(outcome=f"http_{hostile}", host="asr.example.internal\nsecond line", op="chunk\r\nX: y")
        text = self.cfg.asr_usage_path.read_text(encoding="utf-8")
        for fragment in CANARY_FRAGMENTS + (TOKEN,):
            self.assertNotIn(fragment, text)
        lines = self.lines()
        self.assertEqual(len(lines), 3)
        for line in lines:
            self.assertEqual(set(line), KEYS)
        self.assertEqual((lines[0]["engine"], lines[0]["kind"], lines[0]["host"], lines[0]["op"], lines[0]["outcome"], lines[0]["circuit"],
                          lines[0]["session_id"]), ("unknown", "unknown", "", "unknown", "error:other", "closed", None))
        self.assertEqual((lines[2]["host"], lines[2]["op"], lines[2]["outcome"]), ("", "unknown", "error:other"))

    def test_text_in_a_number_field_is_zero_and_wild_numbers_are_clamped(self):
        self.rec(audio_s=float("nan"), bytes_out=-5, bytes_in=float("inf"), dur_ms=True, attempt=0, status=99999)
        self.rec(audio_s=1e300, bytes_out=10 ** 30, dur_ms=10 ** 30)
        a, b = self.lines()
        self.assertEqual((a["audio_s"], a["bytes_out"], a["bytes_in"], a["dur_ms"], a["attempt"], a["status"]), (0.0, 0, 0, 0, 1, 599))
        self.assertLessEqual(b["audio_s"], 86400.0 * 7)
        self.assertLessEqual(b["bytes_out"], 10 ** 12)
        self.assertLessEqual(b["dur_ms"], 86_400_000)

    def test_a_string_is_accepted_only_in_its_closed_shape(self):
        for outcome in ("ok", "http_404", "error:connect", "denied:pre_connect"):
            self.rec(outcome=outcome)
        for outcome in ("OK", "http_4040", "error:", "error:has space", "denied:" + "x" * 40, "anything else", "", None):
            self.rec(outcome=outcome)
        self.assertEqual([x["outcome"] for x in self.lines()], ["ok", "http_404", "error:connect", "denied:pre_connect"] + ["error:other"] * 8)

    def test_a_server_text_in_the_logs_of_a_failed_write_is_not_possible_either(self):
        blocker = self.root / "blocker"
        blocker.write_text("x", encoding="utf-8")
        self.cfg.support_dir = blocker / "inside"
        with self.assertLogs("mcap.asr_usage", level="WARNING") as logs:
            self.rec(outcome=CANARY_TEXT)
        for fragment in CANARY_FRAGMENTS:
            self.assertNotIn(fragment, "\n".join(logs.output))


class MinutesTodayTests(UsageCase):
    def test_audio_plus_one_second_per_request(self):
        self.rec(audio_s=29.0)                       # 29 s + 1 request = 30 s
        self.rec(audio_s=29.0, kind="cloud", engine="azure")
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 1.0)

    def test_nothing_is_nothing(self):
        self.assertEqual(asr_usage.minutes_today(self.cfg), 0.0)

    def test_a_request_that_was_not_sent_adds_nothing(self):
        self.rec(audio_s=29.0, outcome="error:connect", status=0)
        self.rec(audio_s=29.0, outcome="denied:gate", status=0)
        self.assertEqual(asr_usage.minutes_today(self.cfg), 0.0)

    def test_a_health_check_counts_one_second(self):
        self.rec(op="health", audio_s=0.0, bytes_out=0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 1.0 / 60.0)

    def test_only_the_local_date_of_now_counts(self):
        self.now = at(day=14, hour=23, minute=59)
        self.rec(audio_s=59.0)
        self.now = at(day=15, hour=0, minute=1)
        self.rec(audio_s=29.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg, now=at(15, 12)), 0.5)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg, now=at(14, 23, 59)), 1.0)
        self.assertEqual(asr_usage.minutes_today(self.cfg, now=at(16, 1)), 0.0)

    def test_the_cap_starts_over_at_midnight(self):
        self.now = at(15, 23, 58)
        self.rec(audio_s=119.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 2.0)
        self.now = at(16, 0, 5)
        self.assertEqual(asr_usage.minutes_today(self.cfg), 0.0)

    def test_kinds_filter(self):
        self.rec(audio_s=59.0)                       # server, 1 min
        self.rec(audio_s=119.0, kind="cloud", engine="azure")           # cloud, 2 min
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg, kinds=("server",)), 1.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg, kinds=("cloud",)), 2.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 3.0)
        self.assertEqual(asr_usage.minutes_today(self.cfg, kinds=("local",)), 0.0)

    def test_a_line_from_an_older_file_without_requests_is_one_request(self):
        self.raw(json.dumps({"ts": self.now.isoformat(), "kind": "server", "audio_s": 29.0}) + "\n")
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 0.5)

    def test_garbage_is_ignored(self):
        self.rec(audio_s=29.0)
        self.raw("not json\n{broken\n\n[1, 2]\n" + json.dumps({"ts": "yesterday-ish", "kind": "server", "audio_s": 999}) + "\n"
                 + json.dumps({"no_ts": 1}) + "\n" + json.dumps({"ts": self.now.isoformat(), "kind": "server", "audio_s": "lots"}) + "\n")
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 0.5 + 1.0 / 60.0)

    def test_it_does_not_depend_on_the_order_of_the_lines(self):
        self.now = at(15, 12)
        self.rec(audio_s=29.0)
        self.raw(json.dumps({"ts": at(14, 12).isoformat(), "kind": "server", "audio_s": 3000, "requests": 1}) + "\n")
        self.now = at(15, 13)
        self.rec(audio_s=29.0)
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), 1.0)


class RotationTests(UsageCase):
    def setUp(self):
        super().setUp()
        self.now = datetime.now().astimezone()               # file times are real: the fake clock must agree with them here
        patcher = mock.patch.object(asr_usage, "MAX_BYTES", 2000)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fill(self, n):
        for i in range(n):
            self.rec(attempt=(i % 90) + 1, audio_s=10.0)

    def test_a_full_file_is_renamed_and_a_new_one_started(self):
        self.fill(5)
        path = self.cfg.asr_usage_path
        self.assertFalse(path.with_name(path.name + ".1").exists())
        self.fill(5)
        self.assertTrue(path.with_name(path.name + ".1").exists())
        self.assertLess(path.stat().st_size, 2000 + 500)
        self.assertEqual(stat.S_IMODE(os.stat(path.with_name(path.name + ".1")).st_mode), 0o600)

    def test_only_a_few_old_files_are_kept(self):
        self.fill(200)
        path = self.cfg.asr_usage_path
        names = sorted(p.name for p in path.parent.iterdir() if p.name.startswith("asr-usage.jsonl") and not p.name.endswith(".lock"))
        self.assertEqual(names, ["asr-usage.jsonl", "asr-usage.jsonl.1", "asr-usage.jsonl.2", "asr-usage.jsonl.3"])

    def test_readers_look_at_the_rotated_files_too(self):
        self.fill(40)
        path = self.cfg.asr_usage_path
        self.assertTrue(path.with_name(path.name + ".1").exists())
        total = sum(1 for _ in asr_usage.read_entries(self.cfg))
        in_files = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in path.parent.iterdir()
                       if p.name.startswith("asr-usage.jsonl") and not p.name.endswith(".lock"))
        self.assertEqual(total, in_files)
        self.assertGreater(total, len(path.read_text(encoding="utf-8").splitlines()))
        expected_minutes = total * 11.0 / 60.0
        self.assertAlmostEqual(asr_usage.minutes_today(self.cfg), expected_minutes)

    def test_the_oldest_file_is_dropped_not_the_newest_line(self):
        self.fill(300)
        entries = list(asr_usage.read_entries(self.cfg))
        self.assertLess(len(entries), 300)
        last_attempt = ((300 - 1) % 90) + 1
        self.assertEqual(entries[-1][0]["attempt"], last_attempt)

    def test_a_second_rotator_that_finds_the_file_small_again_does_not_rotate(self):
        self.fill(12)
        path = self.cfg.asr_usage_path
        rotated = path.with_name(path.name + ".1")
        self.assertTrue(rotated.exists())
        before = rotated.read_bytes()
        small = path.stat().st_size
        self.assertLess(small, 2000)
        asr_usage._rotate_if_full(path)                          # what the loser of a race does after it got the lock
        self.assertEqual(rotated.read_bytes(), before)
        self.assertEqual(path.stat().st_size, small)

    def test_a_rotator_that_waited_for_the_lock_looks_again(self):
        self.fill(12)
        path = self.cfg.asr_usage_path
        rotated = path.with_name(path.name + ".1")
        before = rotated.read_bytes()
        path.write_bytes(b"x\n" * 1500)                           # full again: the first look says rotate

        def other_process_rotated_meanwhile(fd, operation):
            path.write_bytes(b'{"ts":"x"}\n')                       # what the winner of the race left behind
        with mock.patch.object(asr_usage.fcntl, "flock", other_process_rotated_meanwhile):
            asr_usage._rotate_if_full(path)
        self.assertEqual(rotated.read_bytes(), before)               # the winner's file was not pushed aside again
        self.assertEqual(path.read_bytes(), b'{"ts":"x"}\n')

    def test_an_old_rotated_file_is_not_opened_for_a_recent_window(self):
        self.fill(40)
        path = self.cfg.asr_usage_path
        old = path.with_name(path.name + ".1")
        os.utime(old, (1_000_000, 1_000_000))                    # last written in 1970
        since = self.now - timedelta(days=1)
        opened = []
        real = Path.read_bytes

        def spy(p):
            opened.append(p.name)
            return real(p)
        with mock.patch.object(Path, "read_bytes", spy):
            list(asr_usage.read_entries(self.cfg, since))
        self.assertNotIn("asr-usage.jsonl.1", opened)
        self.assertIn("asr-usage.jsonl", opened)


class SummaryTests(UsageCase):
    def test_nothing_gives_zeros(self):
        s = asr_usage.summary(self.cfg)
        self.assertEqual((s["attempts"], s["requests"], s["audio_s"], s["minutes"], s["failures"], s["denied"], s["est_usd"], s["last_ts"]),
                         (0, 0, 0.0, 0.0, 0, 0, None, None))
        self.assertEqual(s["by_engine"], {})
        self.assertEqual(s["days"], 7)

    def test_totals_failures_denials_and_engines(self):
        self.rec(audio_s=10.0, bytes_out=1000, bytes_in=100)
        self.rec(audio_s=20.0, bytes_out=2000, bytes_in=200, est_usd=0.25, kind="cloud", engine="azure")
        self.rec(audio_s=5.0, outcome="http_503", status=503, bytes_out=500, bytes_in=50)
        self.rec(audio_s=5.0, outcome="denied:gate", status=0, bytes_in=0)
        self.rec(audio_s=5.0, outcome="error:connect", status=0, bytes_in=0)
        s = asr_usage.summary(self.cfg)
        self.assertEqual((s["attempts"], s["requests"], s["audio_s"]), (5, 3, 35.0))
        self.assertEqual((s["bytes_out"], s["bytes_in"]), (3500, 350))
        self.assertEqual((s["failures"], s["denied"]), (1, 1))                  # the 503 (the connect error was not sent)
        self.assertEqual(s["est_usd"], 0.25)
        self.assertAlmostEqual(s["minutes"], (35.0 + 3.0) / 60.0, places=2)
        self.assertEqual(s["by_engine"], {"remote": {"requests": 2, "audio_s": 15.0, "failures": 1},
                                          "azure": {"requests": 1, "audio_s": 20.0, "failures": 0}})
        self.assertEqual(s["last_ts"], self.now.isoformat(timespec="seconds"))

    def test_the_window_is_the_last_days(self):
        self.now = at(5, 12)
        self.rec(audio_s=100.0)
        self.now = at(14, 12)
        self.rec(audio_s=10.0)
        self.now = at(15, 12)
        self.assertEqual(asr_usage.summary(self.cfg, days=7)["audio_s"], 10.0)
        self.assertEqual(asr_usage.summary(self.cfg, days=30)["audio_s"], 110.0)
        self.assertEqual(asr_usage.summary(self.cfg, days=0)["days"], 1)

    def test_the_summary_has_no_host_and_is_json(self):
        self.rec()
        text = json.dumps(asr_usage.summary(self.cfg))
        self.assertNotIn(HOST, text)
        for fragment in CANARY_FRAGMENTS:
            self.assertNotIn(fragment, text)


if __name__ == "__main__":
    unittest.main()
