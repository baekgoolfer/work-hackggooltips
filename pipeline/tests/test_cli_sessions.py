"""mcap sessions, mcap forget and mcap release (cli.py).

sessions: the listing carries no title. forget: ONE session or meeting folder of the three roots (staging, local archive, Drive archive) after
a yes in the terminal or --yes, never anything else (roots, months, links, other places), never a session being recorded or processed.
release: list / switch of the company layout, atomic, refusing a version below the policy's minimum (0.2.0 when a policy exists). Every path is
under a temp root; the real SUPPORT_DIR, LOG_DIR and the system policy are not read."""
import contextlib
import io
import json
import os
import sys
import time
from pathlib import Path
from unittest import mock

from net_guard_support import NoNetworkCase
from notes_cli_support import fake_m4a, make_cfg, make_session
from test_status import company_doc, company_org, locked_org

from mcap import cli, pipeline, policy, status


class TtyInput(io.StringIO):
    def isatty(self):
        return True


class SessionsCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        env = mock.patch.dict(os.environ, {"MCAP_LOG_DIR": str(self.logs), "MCAP_CONFIG": str(self.root / "config.env")})
        env.start()
        self.addCleanup(env.stop)
        self.cfg = make_cfg(self.root)
        values = {"SUPPORT_DIR": self.cfg.support_dir, "ARCHIVE_DIR": self.cfg.archive_dir, "PROJECT_DIR": self.cfg.project_dir,
                  "PYTHON_BIN": sys.executable, "CLAUDE_BIN": self.cfg.claude_bin, "CALENDAR_LOOKUP": "0"}
        (self.root / "config.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def run_cli(self, *argv, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(sys, "stdin", stdin if stdin is not None else io.StringIO()):
            code = cli.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def meeting(self, root: Path, name: str = "2026-10-07_1400_Weekly-Sync", month: str = "2026-10") -> Path:
        folder = Path(root) / month / name
        folder.mkdir(parents=True)
        for f in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(folder / f)
        (folder / "transcript.md").write_text("# Transcript\nconfidential words\n", encoding="utf-8")
        (folder / "session.json").write_text(json.dumps({"session_id": name}), encoding="utf-8")
        return folder


# ======================================================================================================================
class SessionsCommandTests(SessionsCase):
    def test_the_listing_has_id_stage_error_kind_age_and_size_but_no_title(self):
        d = make_session(self.cfg, "2026-10-07_1400_zoom", title_hint="Confidential Merger Talks")
        (d / "state.json").write_text(json.dumps({"stage": "failed", "error": "note failed: patient Kim Minsu", "error_kind": "usage_limit",
                                                  "retryable": True}), encoding="utf-8")
        make_session(self.cfg, "2026-10-08_0900_meet", title_hint="Board Prep")
        code, out, _err = self.run_cli("sessions")
        self.assertEqual(code, 0)
        lines = out.splitlines()
        self.assertEqual(lines[0].split(), ["session", "stage", "error", "kind", "age", "size"])
        self.assertTrue(lines[1].startswith("2026-10-08_0900_meet"))                         # newest first
        self.assertRegex(out, r"2026-10-07_1400_zoom\s+failed\s+usage_limit\s+")
        self.assertIn("2 session folder(s) in staging", out)
        for fragment in ("Confidential", "Merger", "Kim Minsu", "Board Prep", "meet.google.com", str(self.root)):
            self.assertNotIn(fragment, out)

    def test_json_and_empty_forms(self):
        code, out, _err = self.run_cli("sessions")
        self.assertEqual((code, out.strip()), (0, "no session in staging"))
        make_session(self.cfg, "2026-10-07_1400_zoom", title_hint="Confidential Merger Talks")
        code, out, _err = self.run_cli("sessions", "--json")
        doc = json.loads(out)
        self.assertEqual((code, doc["schema"], [r["id"] for r in doc["sessions"]]), (0, 1, ["2026-10-07_1400_zoom"]))
        self.assertNotIn("Confidential", out)


# ======================================================================================================================
class ForgetTests(SessionsCase):
    def test_yes_deletes_one_staging_session_and_nothing_else(self):
        a = make_session(self.cfg, "2026-10-07_1400_zoom")
        b = make_session(self.cfg, "2026-10-07_1500_zoom")
        code, out, _err = self.run_cli("forget", str(a), "--yes")
        self.assertEqual(code, 0)
        self.assertFalse(a.exists())
        self.assertTrue(b.exists())
        self.assertIn("Deleted the staging folder 2026-10-07_1400_zoom", out)
        self.assertNotIn("confidential", out.lower())

    def test_a_typed_yes_deletes_and_anything_else_cancels(self):
        a = make_session(self.cfg, "2026-10-07_1400_zoom")
        code, out, _err = self.run_cli("forget", str(a), stdin=TtyInput("n\n"))
        self.assertEqual((code, a.exists()), (0, True))
        self.assertIn("cancelled", out)
        code, out, _err = self.run_cli("forget", str(a), stdin=TtyInput(""))                  # end of input
        self.assertEqual((code, a.exists()), (0, True))
        code, out, _err = self.run_cli("forget", str(a), stdin=TtyInput("y\n"))
        self.assertEqual((code, a.exists()), (0, False))
        self.assertIn("This cannot be undone", out)

    def test_without_a_terminal_and_without_yes_nothing_is_deleted(self):
        a = make_session(self.cfg, "2026-10-07_1400_zoom")
        code, _out, err = self.run_cli("forget", str(a))
        self.assertEqual((code, a.exists()), (2, True))
        self.assertIn("run it in a terminal or pass --yes", err)

    def test_meeting_folders_of_the_local_archive_and_the_drive_archive_can_be_forgotten(self):
        drive = self.meeting(self.cfg.archive_dir)
        local = self.meeting(self.cfg.local_archive_root, "2026-10-08_0900_Local-Talk")
        keep = self.meeting(self.cfg.archive_dir, "2026-10-09_1000_Other")
        self.assertEqual(self.run_cli("forget", str(drive), "--yes")[0], 0)
        self.assertEqual(self.run_cli("forget", str(local), "--yes")[0], 0)
        self.assertFalse(drive.exists() or local.exists())
        self.assertTrue(keep.exists() and (self.cfg.archive_dir / "2026-10").is_dir())
        out = self.run_cli("forget", str(keep), "--yes")[1]
        self.assertIn("Deleted the archive folder", out)

    def test_the_stub_a_published_meeting_left_in_staging_goes_with_it_but_other_stubs_stay(self):
        drive = self.meeting(self.cfg.archive_dir)
        mine = Path(self.cfg.sessions_dir) / "2026-10-07_1400_zoom"
        mine.mkdir(parents=True)
        (mine / "state.json").write_text(json.dumps({"stage": "done", "final_dir": str(drive)}))
        other = Path(self.cfg.sessions_dir) / "2026-10-07_1500_zoom"
        other.mkdir()
        (other / "state.json").write_text(json.dumps({"stage": "done", "final_dir": str(self.cfg.archive_dir / "2026-10" / "elsewhere")}))
        self.assertEqual(self.run_cli("forget", str(drive), "--yes")[0], 0)
        self.assertFalse(mine.exists())
        self.assertTrue(other.exists())

    def test_the_discarded_sessions_can_be_forgotten_but_not_the_discarded_folder_itself(self):
        one = Path(self.cfg.sessions_dir) / "_discarded" / "2026-10-07_1400_zoom"
        one.mkdir(parents=True)
        (one / "session.json").write_text(json.dumps({"end_time": "2026-10-07T14:05:00+09:00"}))
        code, _out, err = self.run_cli("forget", str(Path(self.cfg.sessions_dir) / "_discarded"), "--yes")
        self.assertEqual((code, (Path(self.cfg.sessions_dir) / "_discarded").exists()), (2, True))
        self.assertEqual(self.run_cli("forget", str(one), "--yes")[0], 0)
        self.assertFalse(one.exists())

    def test_nothing_outside_the_three_roots_and_no_other_shape_is_ever_deleted(self):
        make_session(self.cfg, "2026-10-07_1400_zoom")
        self.meeting(self.cfg.archive_dir)
        Path(self.cfg.local_archive_root).mkdir(parents=True)
        outside = self.root / "Documents" / "2026-10" / "2026-10-07_1400_Weekly-Sync"          # meeting-shaped, but not under a root
        outside.mkdir(parents=True)
        (outside / "precious.txt").write_text("x")
        plain = self.root / "Documents" / "photos"
        plain.mkdir()
        month = self.cfg.archive_dir / "2026-10"
        not_a_meeting = month / "notes-folder"
        not_a_meeting.mkdir()
        file_in_month = month / "2026-10-07_1400_file"
        file_in_month.write_text("x")
        deep = month / "2026-10-07_1400_Weekly-Sync" / "sub"
        deep.mkdir()
        targets = [outside, plain, self.cfg.sessions_dir, self.cfg.archive_dir, self.cfg.local_archive_root, month, not_a_meeting, file_in_month,
                   deep, Path(self.root), Path.home(), self.root / "no-such-folder", Path("/")]
        for target in targets:
            with self.subTest(target=str(target)):
                code, _out, err = self.run_cli("forget", str(target), "--yes")
                self.assertEqual(code, 2, err)
                self.assertTrue(Path(target).exists() or str(target).endswith("no-such-folder"))
        self.assertTrue((outside / "precious.txt").exists() and (deep.parent / "audio.m4a").exists())

    def test_a_symbolic_link_is_refused_and_so_is_a_link_that_leads_out_of_a_root(self):
        victim = self.root / "Documents" / "important"
        victim.mkdir(parents=True)
        (victim / "keep.txt").write_text("x")
        link = Path(self.cfg.sessions_dir) / "2026-10-07_1400_zoom"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(victim)
        code, _out, err = self.run_cli("forget", str(link), "--yes")
        self.assertEqual(code, 2)
        self.assertIn("symbolic link", err)
        self.assertTrue((victim / "keep.txt").exists())
        month_link = Path(self.cfg.archive_dir) / "2026-10"
        month_link.parent.mkdir(parents=True, exist_ok=True)
        month_link.symlink_to(victim, target_is_directory=True)
        (victim / "2026-10-07_1400_Weekly-Sync").mkdir()
        code, _out, _err = self.run_cli("forget", str(month_link / "2026-10-07_1400_Weekly-Sync"), "--yes")
        self.assertEqual(code, 2)                                                              # a link inside the root that leads out
        self.assertTrue((victim / "2026-10-07_1400_Weekly-Sync").exists())

    def test_a_session_that_is_being_recorded_is_busy(self):
        live = make_session(self.cfg, "2026-10-07_1400_zoom", end=None)
        os.utime(live / "mic.wav", (time.time(), time.time()))
        code, out, _err = self.run_cli("forget", str(live), "--yes")
        self.assertEqual((code, live.exists()), (75, True))
        self.assertIn("BUSY", out)

    def test_a_session_another_process_is_working_on_is_busy(self):
        a = make_session(self.cfg, "2026-10-07_1400_zoom")
        with pipeline.session_lock(self.cfg, "2026-10-07_1400_zoom"):
            code, out, _err = self.run_cli("forget", str(a), "--yes")
        self.assertEqual((code, a.exists()), (75, True))
        self.assertIn("BUSY", out)

    def test_a_folder_that_cannot_be_deleted_completely_is_an_error_not_a_crash(self):
        a = make_session(self.cfg, "2026-10-07_1400_zoom")
        with mock.patch.object(cli.shutil, "rmtree", side_effect=PermissionError(13, "Permission denied")):
            code, _out, err = self.run_cli("forget", str(a), "--yes")
        self.assertEqual(code, 1)
        self.assertIn("could not be deleted completely", err)

    def test_forget_target_names_the_place(self):
        cfg = self.cfg
        staging = make_session(cfg, "2026-10-07_1400_zoom")
        drive = self.meeting(cfg.archive_dir)
        self.assertEqual(cli.forget_target(cfg, staging)[0], "staging")
        self.assertEqual(cli.forget_target(cfg, drive)[0], "archive")
        self.assertIsNone(cli.forget_target(cfg, self.root)[0])


# ======================================================================================================================
class ReleaseCase(SessionsCase):
    def setUp(self):
        super().setUp()
        self.releases = self.root / "releases"
        for version in ("0.1.0", "0.2.0", "0.2.1", "0.10.0"):
            (self.releases / version / "pipeline").mkdir(parents=True)
        (self.releases / "0.3.0").mkdir()                                                      # incomplete: no pipeline folder
        (self.releases / "notes").mkdir()                                                      # not a version at all
        (self.releases / "current").symlink_to("0.2.0")

    def current(self) -> str:
        return os.readlink(self.releases / "current")

    def release(self, *argv, org=None):
        with mock.patch.object(status, "load_policy", return_value=org if org is not None else policy.absent_policy()):
            return self.run_cli("release", "--root", str(self.releases), *argv)


class ReleaseListTests(ReleaseCase):
    def test_the_releases_are_listed_in_version_order_with_the_current_one_marked(self):
        code, out, _err = self.release("list")
        self.assertEqual(code, 0)
        names = [line.split()[0] for line in out.splitlines()]
        self.assertEqual(names, ["0.1.0", "0.2.0", "0.2.1", "0.3.0", "0.10.0"])               # 0.10.0 is above 0.2.1: a tuple of ints, not text
        self.assertIn("current", next(l for l in out.splitlines() if l.startswith("0.2.0")))
        self.assertNotIn("minimum", out)                                                      # no policy: no floor

    def test_with_a_policy_the_versions_below_its_minimum_are_marked(self):
        org = company_org(self.root, company_doc(min_pipeline_version="0.2.1"), version="0.2.1")
        code, out, _err = self.release("list", org=org)
        self.assertEqual(code, 0)
        self.assertIn("below the minimum version", next(l for l in out.splitlines() if l.startswith("0.2.0")))
        self.assertNotIn("below the minimum version", next(l for l in out.splitlines() if l.startswith("0.2.1")))
        self.assertIn("minimum version: 0.2.1 (policy)", out)

    def test_an_empty_root_says_so(self):
        with mock.patch.object(status, "load_policy", return_value=policy.absent_policy()):
            code, out, _err = self.run_cli("release", "--root", str(self.root / "nothing-here"), "list")
        self.assertEqual(code, 0)
        self.assertIn("no release directory", out)

    def test_the_root_defaults_to_the_runtime_root_of_the_policy(self):
        org = company_org(self.root, company_doc(runtime={"root": str(self.releases)}))
        with mock.patch.object(status, "load_policy", return_value=org):
            code, out, _err = self.run_cli("release", "list")
        self.assertEqual(code, 0)
        self.assertIn("0.2.1", out)


class ReleaseSwitchTests(ReleaseCase):
    def test_switch_replaces_the_current_link_atomically_with_a_relative_target(self):
        code, out, _err = self.release("switch", "0.2.1")
        self.assertEqual(code, 0)
        self.assertEqual(self.current(), "0.2.1")
        self.assertIn("0.2.0 -> 0.2.1", out)
        self.assertIn("mcap release switch 0.2.0", out)                                       # how to go back
        self.assertEqual(sorted(p.name for p in self.releases.iterdir() if p.name.startswith(".")), [])
        self.assertEqual(self.release("switch", "0.10.0")[0], 0)
        self.assertEqual(self.current(), "0.10.0")

    def test_the_current_release_is_a_no_op(self):
        code, out, _err = self.release("switch", "0.2.0")
        self.assertEqual((code, self.current()), (0, "0.2.0"))
        self.assertIn("already the current release", out)

    def test_without_a_policy_any_complete_release_can_be_switched_to(self):
        self.assertEqual(self.release("switch", "0.1.0")[0], 0)
        self.assertEqual(self.current(), "0.1.0")

    def test_below_the_policy_minimum_is_refused_and_the_link_stays(self):
        org = company_org(self.root, company_doc(min_pipeline_version="0.2.1"), version="0.2.1")
        for version in ("0.2.0", "0.1.0"):
            code, _out, err = self.release("switch", version, org=org)
            self.assertEqual(code, 1)
            self.assertIn("below the minimum pipeline version 0.2.1", err)
            self.assertEqual(self.current(), "0.2.0")
        self.assertEqual(self.release("switch", "0.10.0", org=org)[0], 0)                      # a tuple compare: 0.10.0 is above 0.2.1
        self.assertEqual(self.current(), "0.10.0")

    def test_with_a_policy_nothing_below_0_2_0_is_ever_allowed(self):
        for org in (company_org(self.root), locked_org(self.root)):
            code, _out, err = self.release("switch", "0.1.0", org=org)
            self.assertEqual(code, 1)
            self.assertIn("lane gates", err)
            self.assertEqual(self.current(), "0.2.0")

    def test_an_unknown_incomplete_or_malformed_version_is_a_usage_error(self):
        for version in ("9.9.9", "0.3.0", "notes", "abc", "0.2", "", "../0.2.1"):
            with self.subTest(version=version):
                code, _out, err = self.release("switch", version)
                self.assertEqual(code, 2, err)
                self.assertEqual(self.current(), "0.2.0")

    def test_a_link_that_cannot_be_switched_is_an_error_and_leaves_the_old_one(self):
        os.chmod(self.releases, 0o500)
        self.addCleanup(os.chmod, self.releases, 0o700)
        code, _out, err = self.release("switch", "0.2.1")
        self.assertEqual(code, 1)
        self.assertIn("administrator", err)
        self.assertEqual(self.current(), "0.2.0")


if __name__ == "__main__":
    import unittest
    unittest.main()
