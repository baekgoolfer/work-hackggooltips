"""logsafe.prune_logs (SPEC 18: LOG_RETENTION_DAYS, default 0 = keep) and its wiring into the housekeeping of the CLI.
The snip / configure half of logsafe has its tests in test_asr_seam.py; here only a content-free check that the two halves do not disturb
each other. Nothing here touches the real LOG_DIR: every config points into a temp root."""
import contextlib
import io
import os
import time
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

from notes_cli_support import FakeASR, StubNote, TempCase, make_cfg, make_session, ready_ok

from mcap import cli, logsafe

DAY = 86400.0


class LogCase(TempCase):
    def setUp(self):
        super().setUp()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        patcher = mock.patch.dict(os.environ, {"MCAP_LOG_DIR": str(self.logs)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cfg = make_cfg(self.root)
        self.now = time.time()

    def log(self, name: str, age_days: float, text: str = "x\n") -> Path:
        path = self.logs / name
        path.write_text(text, encoding="utf-8")
        stamp = self.now - age_days * DAY
        os.utime(path, (stamp, stamp))
        return path

    def with_retention(self, days: int):
        self.cfg.log_retention_days = days
        return self.cfg


class PruneLogsTests(LogCase):
    def test_the_default_keeps_everything_and_touches_nothing(self):
        old = self.log("pipeline-2020-01-01_0900_zoom.log", 4000)
        self.assertEqual(self.cfg.log_retention_days, 0)
        self.assertEqual(logsafe.prune_logs(self.cfg, now=self.now), [])
        self.assertTrue(old.exists())

    def test_a_log_older_than_the_retention_goes_and_a_newer_one_stays(self):
        old = self.log("pipeline-2026-09-01_0900_zoom.log", 40)
        edge = self.log("pipeline-2026-09-10_0900_zoom.log", 29.9)
        fresh = self.log("pipeline-2026-10-14_0900_zoom.log", 1)
        removed = logsafe.prune_logs(self.with_retention(30), now=self.now)
        self.assertEqual([p.name for p in removed], [old.name])
        self.assertFalse(old.exists())
        self.assertTrue(edge.exists() and fresh.exists())

    def test_only_pipeline_logs_are_pruned_never_the_app_log_or_other_files(self):
        keep = [self.log("app.log", 400), self.log("app.log.1", 400), self.log("notes.txt", 400), self.log("pipeline-x.log.bak", 400),
                self.log("pipeline-.log", 400), self.log("pipeline-a b.log", 400)]
        gone = [self.log("pipeline-retry-sweep.log", 400), self.log("pipeline-reprocess-1790000000.log", 400)]
        logsafe.prune_logs(self.with_retention(30), now=self.now)
        self.assertTrue(all(p.exists() for p in keep), [p.name for p in keep if not p.exists()])
        self.assertFalse(any(p.exists() for p in gone))

    def test_a_symbolic_link_and_a_directory_with_a_log_name_are_left_alone(self):
        target = self.root / "elsewhere.txt"
        target.write_text("precious", encoding="utf-8")
        link = self.logs / "pipeline-link.log"
        link.symlink_to(target)
        os.utime(link, (self.now - 400 * DAY, self.now - 400 * DAY), follow_symlinks=False)
        folder = self.logs / "pipeline-dir.log"
        folder.mkdir()
        os.utime(folder, (self.now - 400 * DAY, self.now - 400 * DAY))
        self.assertEqual(logsafe.prune_logs(self.with_retention(1), now=self.now), [])
        self.assertTrue(link.is_symlink() and target.read_text(encoding="utf-8") == "precious" and folder.is_dir())

    def test_a_dry_run_lists_without_deleting(self):
        old = self.log("pipeline-old.log", 90)
        removed = logsafe.prune_logs(self.with_retention(30), now=self.now, dry_run=True)
        self.assertEqual([p.name for p in removed], ["pipeline-old.log"])
        self.assertTrue(old.exists())

    def test_now_may_be_a_datetime_and_defaults_to_the_clock(self):
        old = self.log("pipeline-old.log", 10)
        cfg = self.with_retention(7)
        self.assertEqual(logsafe.prune_logs(cfg, now=datetime.fromtimestamp(self.now) - timedelta(days=5)), [])
        self.assertTrue(old.exists())
        self.assertEqual([p.name for p in logsafe.prune_logs(cfg)], ["pipeline-old.log"])          # now = the real clock

    def test_a_missing_log_directory_or_a_config_without_the_key_is_not_an_error(self):
        cfg = self.with_retention(5)
        with mock.patch.dict(os.environ, {"MCAP_LOG_DIR": str(self.root / "no-such-dir")}):
            self.assertEqual(logsafe.prune_logs(cfg, now=self.now), [])
        bare = type("Bare", (), {})()
        self.assertEqual(logsafe.prune_logs(bare), [])                                              # no log_retention_days: keep

    def test_a_file_that_cannot_be_removed_does_not_stop_the_rest(self):
        a, b = self.log("pipeline-a.log", 90), self.log("pipeline-b.log", 90)
        real = os.unlink

        def flaky(path, *args, **kw):
            if str(path).endswith("pipeline-a.log"):
                raise PermissionError("denied")
            return real(path, *args, **kw)
        with mock.patch.object(os, "unlink", flaky):
            removed = logsafe.prune_logs(self.with_retention(30), now=self.now)
        self.assertEqual([p.name for p in removed], ["pipeline-b.log"])
        self.assertTrue(a.exists() and not b.exists())

    def test_prune_logs_leaves_the_snip_setting_alone(self):
        self.addCleanup(logsafe.configure, True)
        logsafe.configure(False)
        self.log("pipeline-old.log", 90)
        logsafe.prune_logs(self.with_retention(30), now=self.now)
        self.assertFalse(logsafe.content_allowed())
        self.assertRegex(logsafe.snip("meeting text"), r"^<12 chars sha1:[0-9a-f]{6}>$")


class HousekeepingWiringTests(LogCase):
    def test_housekeeping_with_the_default_prunes_no_log(self):
        old = self.log("pipeline-ancient.log", 4000)
        cli._housekeeping(self.cfg)
        self.assertTrue(old.exists())

    def test_housekeeping_prunes_old_logs_when_the_retention_is_set(self):
        old, fresh = self.log("pipeline-ancient.log", 400), self.log("pipeline-today.log", 0)
        cli._housekeeping(self.with_retention(30))
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())

    def test_a_failing_log_pruning_never_breaks_the_housekeeping(self):
        with mock.patch.object(logsafe, "prune_logs", side_effect=RuntimeError("boom")), self.assertLogs("mcap.cli", "WARNING") as seen:
            cli._housekeeping(self.with_retention(30))                                              # must not raise
        self.assertIn("log housekeeping skipped", seen.output[0])

    def test_a_pipeline_run_ends_with_the_housekeeping_and_so_with_the_log_age_rule(self):
        cfg = self.with_retention(30)
        session = make_session(cfg)
        old, fresh = self.log("pipeline-ancient.log", 400), self.log("pipeline-today.log", 0)
        deps = FakeASR().deps(check_ready=ready_ok, generate_note=StubNote())
        with contextlib.redirect_stdout(io.StringIO()):
            code = cli._run_pipeline(session, cfg, force=False, from_stage=None, allow_overage=False, deps=deps, sweep=False)
        self.assertEqual(code, 0)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())

    def test_a_pipeline_run_with_the_default_retention_keeps_every_log(self):
        session = make_session(self.cfg)
        old = self.log("pipeline-ancient.log", 400)
        deps = FakeASR().deps(check_ready=ready_ok, generate_note=StubNote())
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli._run_pipeline(session, self.cfg, force=False, from_stage=None, allow_overage=False, deps=deps, sweep=False), 0)
        self.assertTrue(old.exists())

    def test_prune_audio_reports_logs_only_when_a_retention_is_set(self):
        old = self.log("pipeline-ancient.log", 400)
        out = io.StringIO()
        with mock.patch.object(cli, "load_config", return_value=self.cfg), contextlib.redirect_stdout(out):
            cli.cmd_prune_audio(mock.Mock(dry_run=False))
        self.assertNotIn("log", out.getvalue().replace("deleted: 0 audio file(s)", ""))            # the default output is what it was
        self.assertTrue(old.exists())
        out = io.StringIO()
        with mock.patch.object(cli, "load_config", return_value=self.with_retention(30)), contextlib.redirect_stdout(out):
            cli.cmd_prune_audio(mock.Mock(dry_run=True))
        self.assertIn("would delete log: pipeline-ancient.log", out.getvalue())
        self.assertTrue(old.exists())
        out = io.StringIO()
        with mock.patch.object(cli, "load_config", return_value=self.cfg), contextlib.redirect_stdout(out):
            self.cfg.log_retention_days = 30
            cli.cmd_prune_audio(mock.Mock(dry_run=False))
        self.assertIn("deleted log: pipeline-ancient.log", out.getvalue())
        self.assertFalse(old.exists())


if __name__ == "__main__":
    import unittest
    unittest.main()
