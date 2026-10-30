"""Publishing to the local archive and the commit checks of a move (SPEC 18):
``publish.publish(archive_dir=..., before_commit=...)``, ``publish.move_dir(before_commit=...)``, ``publish.exclude_from_backup`` and the
pruning of the local archive and of failed staging sessions (``LOCAL_ARCHIVE_RETENTION_DAYS``, ``STAGING_FAILED_RETENTION_DAYS``, both 0 =
keep, which is today's behaviour).

Nothing here touches a real Drive folder, Time Machine (``tmutil`` is a fake runner) or the real SUPPORT_DIR; every folder is a temp dir.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import errno
import json
import os
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import publish  # noqa: E402
from mcap.policy import LaneBlock  # noqa: E402
from notes_cli_support import TempCase, fake_m4a, make_cfg, make_session  # noqa: E402

DAY = 86400.0


def block(reason: str = "local_only") -> LaneBlock:
    return LaneBlock("drive", "lane_denied", reason, f"lane 'drive' is not allowed: {reason}")


class PublishCase(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)
        self.src = make_session(self.cfg)
        self.session = json.loads((self.src / "session.json").read_text())
        for name in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(self.src / name)
        (self.src / "transcript.md").write_text("# Transcript\n\nMeeting: x\n", encoding="utf-8")
        self.local = self.cfg.support_dir / "local-meetings"
        self.excluded: list = []
        patcher = mock.patch.object(publish, "exclude_from_backup", side_effect=lambda path, **kw: self.excluded.append(str(path)) or True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def force_copy(self):
        """Make the rename of the staging folder fail like a cross-volume move (EXDEV): publish copies, verifies, renames, deletes."""
        real_rename = os.rename
        staging = self.src

        def exdev(src, dst, *args, **kwargs):
            if Path(src) == staging:
                raise OSError(errno.EXDEV, "cross-device")
            return real_rename(src, dst, *args, **kwargs)

        return mock.patch("mcap.publish.os.rename", side_effect=exdev)


class PublishToLocalRootTests(PublishCase):
    def test_a_folder_is_published_under_the_local_root_with_the_same_layout(self):
        dest = publish.publish(self.src, self.cfg, "Weekly Sync", self.session, archive_dir=self.local)
        self.assertEqual(dest, self.local / "2026-10" / "2026-10-07_1400_Weekly-Sync")
        self.assertFalse(self.src.exists())
        self.assertEqual(sorted(p.name for p in dest.iterdir()), ["audio.m4a", "mic.m4a", "remote.m4a", "session.json", "transcript.md"])
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists(), "the Drive archive was not touched")

    def test_the_local_root_is_created_on_first_use_with_its_parents_and_excluded_from_time_machine(self):
        deep = self.cfg.support_dir / "a" / "b" / "local-meetings"
        publish.publish(self.src, self.cfg, "Weekly", self.session, archive_dir=deep)
        self.assertTrue(deep.is_dir())
        self.assertEqual(self.excluded, [str(deep)])
        again = make_session(self.cfg, "2026-10-07_1500_meet")
        for name in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(again / name)
        publish.publish(again, self.cfg, "Second", self.session, archive_dir=deep)
        self.assertEqual(self.excluded, [str(deep)], "an existing root is not excluded again")

    def test_the_drive_archive_still_needs_its_parent_and_is_never_excluded(self):
        self.cfg.archive_dir = self.root / "not-mounted" / "My Drive" / "Meetings"
        with self.assertRaises(publish.ArchiveUnavailable):
            publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertFalse((self.root / "not-mounted").exists())
        self.assertEqual(self.excluded, [])
        ok, why = publish.archive_status(make_cfg(self.root))
        self.assertTrue(ok, why)
        self.assertEqual(self.excluded, [])                                          # the default archive status never touches Time Machine

    def test_passing_the_drive_root_as_archive_dir_is_the_same_as_not_passing_it(self):
        dest = publish.publish(self.src, self.cfg, "Weekly", self.session, archive_dir=Path(self.cfg.archive_dir))
        self.assertEqual(dest, self.cfg.archive_dir / "2026-10" / "2026-10-07_1400_Weekly")
        self.assertEqual(self.excluded, [])

    def test_an_unwritable_local_root_is_archive_unavailable(self):
        blocker = self.cfg.support_dir / "a-file"
        blocker.write_text("x", encoding="utf-8")
        with self.assertRaises(publish.ArchiveUnavailable):
            publish.publish(self.src, self.cfg, "Weekly", self.session, archive_dir=blocker / "local")
        self.assertTrue((self.src / "session.json").exists())


class ExcludeFromBackupTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(publish, "_EXCLUDED", set())
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_it_runs_tmutil_addexclusion_on_the_path_once_per_process(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((list(argv), kwargs.get("stdin")))
            return SimpleNamespace(returncode=0)

        self.assertTrue(publish.exclude_from_backup("/x/local-meetings", run=run))
        self.assertTrue(publish.exclude_from_backup(Path("/x/local-meetings"), run=run))
        self.assertEqual([c[0] for c in calls], [["/usr/bin/tmutil", "addexclusion", "/x/local-meetings"]])
        self.assertEqual(calls[0][1], __import__("subprocess").DEVNULL)

    def test_a_failure_is_reported_as_false_and_tried_again_next_time(self):
        for outcome in (SimpleNamespace(returncode=1), OSError("no tmutil"), RuntimeError("odd")):
            with self.subTest(outcome=repr(outcome)):
                def run(argv, **kwargs):
                    if isinstance(outcome, BaseException):
                        raise outcome
                    return outcome
                self.assertFalse(publish.exclude_from_backup("/y/sessions", run=run))
        seen = []
        self.assertTrue(publish.exclude_from_backup("/y/sessions", run=lambda argv, **k: seen.append(argv) or SimpleNamespace(returncode=0)))
        self.assertEqual(len(seen), 1)


class CommitCheckTests(PublishCase):
    def test_a_blocked_commit_before_anything_touches_the_archive_publishes_nothing(self):
        asked = []
        with self.assertRaises(publish.CommitBlocked) as cm:
            publish.publish(self.src, self.cfg, "Weekly", self.session, before_commit=lambda: asked.append(1) or block())
        self.assertEqual(cm.exception.reason, "local_only")
        self.assertEqual(asked, [1])
        self.assertFalse(self.cfg.archive_dir.exists() and any(self.cfg.archive_dir.iterdir()), "not even the write probe or a month folder")
        self.assertTrue((self.src / "mic.wav").exists() and (self.src / "audio.m4a").exists(), "the WAVs are still there")

    def test_the_gate_is_asked_before_the_month_folder_is_created(self):
        answers = iter([None])
        asked = []

        def gate():
            asked.append(1)
            return next(answers, block())

        with self.assertRaises(publish.CommitBlocked):
            publish.publish(self.src, self.cfg, "Weekly", self.session, before_commit=gate)
        self.assertEqual(len(asked), 2)                                              # at the start (yes), then before anything is created (no)
        self.assertFalse((self.cfg.archive_dir / "2026-10").exists(), "no month folder was created in the synced folder")

    def test_the_gate_is_asked_again_by_move_dir_before_a_same_volume_rename(self):
        answers = iter([None, None])
        asked = []

        def gate():
            asked.append(1)
            return next(answers, block())

        with self.assertRaises(publish.CommitBlocked):
            publish.publish(self.src, self.cfg, "Weekly", self.session, before_commit=gate)
        self.assertEqual(len(asked), 3)                                              # start, before the month folder, then move_dir right before the rename
        self.assertTrue((self.src / "session.json").exists() and (self.src / "transcript.md").exists())
        self.assertEqual(list((self.cfg.archive_dir / "2026-10").iterdir()), [])

    def test_a_gate_that_closes_during_a_cross_volume_copy_removes_the_partial_copy(self):
        answers = iter([None, None, None, block("local_only")])                      # start, before the month folder, move_dir start, right before the rename
        seen_partial = []
        real_verify = publish._verify_copy

        def verify(src, dst):
            real_verify(src, dst)
            seen_partial.append(Path(dst).is_dir())                                  # the hidden copy was complete when the gate said no

        with self.force_copy(), mock.patch.object(publish, "_verify_copy", verify):
            with self.assertRaises(publish.CommitBlocked) as cm:
                publish.publish(self.src, self.cfg, "Weekly", self.session, before_commit=lambda: next(answers))
        self.assertEqual(cm.exception.reason, "local_only")
        self.assertEqual(seen_partial, [True])
        month = self.cfg.archive_dir / "2026-10"
        self.assertEqual([p.name for p in month.iterdir()], [], "neither the .partial copy nor a final folder is left in the synced folder")
        self.assertTrue((self.src / "session.json").exists() and (self.src / "audio.m4a").exists())

    def test_a_gate_that_stays_open_publishes_exactly_as_without_one(self):
        asked = []
        with self.force_copy():
            dest = publish.publish(self.src, self.cfg, "Weekly", self.session, before_commit=lambda: asked.append(1) and None)
        self.assertEqual(dest.name, "2026-10-07_1400_Weekly")
        self.assertFalse(self.src.exists())
        self.assertEqual(len(asked), 4)                                              # start, before the month folder, move_dir start, before the rename
        self.assertEqual([p.name for p in dest.parent.iterdir() if p.name.startswith(".")], [])

    def test_move_dir_accepts_a_reason_string_and_a_lane_block(self):
        target = self.root / "moved"
        with self.assertRaises(publish.CommitBlocked) as cm:
            publish.move_dir(self.src, target, before_commit=lambda: "policy-archive-root")
        self.assertEqual(cm.exception.reason, "policy-archive-root")
        self.assertFalse(target.exists())
        with self.assertRaises(publish.CommitBlocked) as cm:
            publish.move_dir(self.src, target, before_commit=lambda: block("policy-lane"))
        self.assertEqual(cm.exception.reason, "policy-lane")
        publish.move_dir(self.src, target, before_commit=lambda: None)
        self.assertTrue((target / "session.json").exists())

    def test_move_dir_without_a_hook_is_unchanged(self):
        target = self.root / "moved-plain"
        publish.move_dir(self.src, target)
        self.assertTrue((target / "session.json").exists())

    def test_a_blocked_commit_is_not_a_publish_error_of_the_other_kinds(self):
        self.assertTrue(issubclass(publish.CommitBlocked, publish.PublishError))
        self.assertFalse(issubclass(publish.CommitBlocked, publish.ArchiveUnavailable))


class PruneLocalArchiveTests(PublishCase):
    def meeting(self, root: Path, name: str, *, with_transcript: bool = True) -> Path:
        month = root / name[:7]
        folder = month / name
        folder.mkdir(parents=True)
        for audio in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(folder / audio)
        if with_transcript:
            (folder / "transcript.md").write_text("# Transcript\n", encoding="utf-8")
        (folder / "state.json").write_text('{"stage": "done"}', encoding="utf-8")
        return folder

    NOW = time.mktime((2026, 10, 15, 12, 0, 0, 0, 0, -1))

    def test_nothing_is_pruned_by_default(self):
        old = self.meeting(self.local, "2025-01-05_1000_old")
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual((report.audio, report.failed), ([], []))
        self.assertTrue((old / "mic.m4a").exists())
        self.assertNotIn("failed session", report.summary())                           # the summary line is what it always was

    def test_the_audio_of_old_local_meetings_is_deleted_and_the_transcripts_stay(self):
        self.cfg.local_archive_retention_days = 30
        old = self.meeting(self.local, "2026-08-01_1000_old")
        new = self.meeting(self.local, "2026-10-10_1000_recent")
        no_transcript = self.meeting(self.local, "2026-08-02_1000_notrans", with_transcript=False)
        report = publish.prune_audio(self.cfg, now=self.NOW, include_archive=False)    # the Drive scan is off: the local root is local
        self.assertEqual(len(report.audio), 3)
        self.assertEqual(sorted(p.name for p in old.iterdir()), ["state.json", "transcript.md"])
        self.assertTrue((new / "audio.m4a").exists())
        self.assertTrue((no_transcript / "audio.m4a").exists(), "audio is only deleted in a folder that still has its transcript")

    def test_the_drive_archive_is_not_touched_by_the_local_retention(self):
        self.cfg.local_archive_retention_days = 30
        drive_old = self.meeting(Path(self.cfg.archive_dir), "2026-08-01_1000_drive")
        publish.prune_audio(self.cfg, now=self.NOW)
        self.assertTrue((drive_old / "audio.m4a").exists())                            # AUDIO_RETENTION_DAYS is 0: the Drive archive stays

    def test_the_local_retention_is_independent_of_audio_retention_days(self):
        self.cfg.audio_retention_days = 30
        self.cfg.local_archive_retention_days = 0
        drive_old = self.meeting(Path(self.cfg.archive_dir), "2026-08-01_1000_drive")
        local_old = self.meeting(self.local, "2026-08-01_1000_local")
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(len(report.audio), 3)
        self.assertFalse((drive_old / "audio.m4a").exists())
        self.assertTrue((local_old / "audio.m4a").exists())

    def test_a_dry_run_lists_and_deletes_nothing(self):
        self.cfg.local_archive_retention_days = 30
        old = self.meeting(self.local, "2026-08-01_1000_old")
        report = publish.prune_audio(self.cfg, now=self.NOW, dry_run=True)
        self.assertEqual(len(report.audio), 3)
        self.assertTrue((old / "mic.m4a").exists())
        self.assertIn("would delete", report.summary())

    def test_a_local_archive_dir_that_fails_the_allow_list_is_left_alone(self):
        outside = self.root / "outside-local"
        old = self.meeting(outside, "2026-08-01_1000_old")
        self.cfg.local_archive_dir = outside
        self.cfg.local_archive_retention_days = 30
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(report.audio, [])
        self.assertTrue((old / "audio.m4a").exists())

    def test_a_policy_local_root_counts_when_the_policy_is_valid(self):
        from notes_cli_support import load_test_policy
        outside = self.root / "managed-local"
        old = self.meeting(outside, "2026-08-01_1000_old")
        self.cfg.local_archive_dir = outside
        self.cfg.local_archive_retention_days = 30
        path = self.root / "etc" / "policy.json"
        self.cfg.policy_path = path
        doc = {"schema": 1, "profile": "company", "revision": 1, "archive": {"local_roots": [str(outside)]}}
        valid = load_test_policy(path, doc)
        self.assertTrue(valid.valid)
        with mock.patch("mcap.policy.load_org_policy", return_value=valid):
            report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(len(report.audio), 3)
        self.assertFalse((old / "audio.m4a").exists())


class PruneFailedStagingTests(PublishCase):
    NOW = time.mktime((2026, 10, 15, 12, 0, 0, 0, 0, -1))

    def failed_session(self, name: str, *, retryable, age_days: float, stage: str = "failed", kind: str = "asr_policy_blocked") -> Path:
        folder = make_session(self.cfg, name)
        state = folder / "state.json"
        state.write_text(json.dumps({"stage": stage, "error_kind": kind, "retryable": retryable}), encoding="utf-8")
        stamp = self.NOW - age_days * DAY
        os.utime(state, (stamp, stamp))
        return folder

    def test_nothing_is_removed_by_default(self):
        old = self.failed_session("2026-01-01_1000_meet", retryable=False, age_days=200)
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(report.failed, [])
        self.assertTrue((old / "mic.wav").exists())

    def test_only_old_failed_non_retryable_sessions_are_removed(self):
        self.cfg.staging_failed_retention_days = 30
        blocked = self.failed_session("2026-08-01_1000_meet", retryable=False, age_days=60)
        unsafe = self.failed_session("2026-08-02_1000_meet", retryable=False, age_days=45, kind="local_archive_unsafe")
        young = self.failed_session("2026-10-10_1000_meet", retryable=False, age_days=5)
        retryable = self.failed_session("2026-08-03_1000_meet", retryable=True, age_days=90, kind="asr_unreachable")
        mid_run = self.failed_session("2026-08-04_1000_meet", retryable=None, age_days=90, stage="transcribing")
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(sorted(p.name for p in report.failed), [blocked.name, unsafe.name])
        self.assertFalse(blocked.exists() or unsafe.exists())
        self.assertTrue(young.exists() and retryable.exists() and mid_run.exists())
        self.assertIn("2 failed session(s)", report.summary())

    def test_a_tombstone_is_not_a_failed_session_and_follows_its_own_rule(self):
        self.cfg.staging_failed_retention_days = 30
        stub = Path(self.cfg.sessions_dir) / "2026-08-05_1000_meet"
        stub.mkdir(parents=True)
        (stub / "state.json").write_text(json.dumps({"stage": "failed", "retryable": False}), encoding="utf-8")
        old = self.NOW - 60 * DAY
        os.utime(stub / "state.json", (old, old))
        report = publish.prune_audio(self.cfg, now=self.NOW)
        self.assertEqual(report.failed, [])
        self.assertEqual([p.name for p in report.tombstones], [stub.name])           # the 30-day tombstone rule, as before

    def test_a_dry_run_removes_nothing(self):
        self.cfg.staging_failed_retention_days = 30
        blocked = self.failed_session("2026-08-01_1000_meet", retryable=False, age_days=60)
        report = publish.prune_audio(self.cfg, now=self.NOW, dry_run=True)
        self.assertEqual(len(report.failed), 1)
        self.assertTrue(blocked.exists())


if __name__ == "__main__":
    unittest.main()
