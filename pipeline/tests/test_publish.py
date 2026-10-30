"""publish.py: titles, slugs, folder naming, archive move (incl. cross-volume copy), discard, work-file cleanup, pruning."""
import errno
import json
import os
import unicodedata
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

from notes_cli_support import START, TempCase, fake_m4a, make_cfg, make_session

from mcap import publish

DAY = 86400


class TitleTests(unittest.TestCase):
    def test_generic_titles(self):
        for title in ("Meet - abc-defg-hij", "Meet – abc-defg-hij", "Meet — abc-defg-hij", "meet - ABC-DEFG-HIJ",
                      "abc-defg-hij", "Meet", "Google Meet", "Meet - Google Chrome", "Zoom Meeting", "Zoom", "Zoom Workplace",
                      "Microsoft Teams", "Meeting | Microsoft Teams", "Teams", "Meeting", "Untitled", "Meeting Title",
                      "Zoom Meeting ID: 123 456 7890", "123 456 7890", "", None, "   ", "---", "Meet – abc-defg-hij - Google Chrome"):
            self.assertTrue(publish.is_generic_title(title), repr(title))

    def test_informative_titles(self):
        for title, expected in (("Alex Morgan Weekly", "Alex Morgan Weekly"),
                                ("Alex Morgan Weekly - Google Meet", "Alex Morgan Weekly"),
                                ("Meet – Acme x Fabrikam-Health sync", "Acme x Fabrikam-Health sync"),
                                ("Q3 planning | Microsoft Teams", "Q3 planning"),
                                ("숬빛 주간 회의 - Google Chrome", "숬빛 주간 회의"),
                                ("Zoom Meeting with Alice", "Zoom Meeting with Alice")):
            self.assertFalse(publish.is_generic_title(title), title)
            self.assertEqual(publish.informative_title(title), expected)

    def test_resolve_title_order(self):
        r = publish.resolve_title
        self.assertEqual(r("Calendar Title", "Window Title", "Note Title", "Google Meet"), ("Calendar Title", "calendar"))
        self.assertEqual(r(None, "Window Title", "Note Title", "Google Meet"), ("Window Title", "window"))
        self.assertEqual(r("Zoom Meeting", "Meet - abc-defg-hij", "Note Title", "Google Meet"), ("Note Title", "note"))
        self.assertEqual(r("", "Meeting", "Meeting Title", "Google Meet"), ("Google Meet", "platform"))
        self.assertEqual(r(None, None, None, None), ("Meeting", "platform"))
        # another app's call (platform "call"): no window title, so the app's name is the last resort
        self.assertEqual(r(None, None, None, "Slack huddle"), ("Slack huddle", "platform"))
        self.assertEqual(r(None, None, "Roadmap huddle", "Slack huddle"), ("Roadmap huddle", "note"))
        self.assertEqual(r("", "", "Meeting Title", "Lark / Feishu"), ("Lark / Feishu", "platform"))

    def test_clean_title_collapses_whitespace_and_controls(self):
        self.assertEqual(publish.clean_title("  A\tB\n C \x00 "), "A B C")
        nfd = unicodedata.normalize("NFD", "한글")
        self.assertEqual(publish.clean_title(nfd), "한글")


class SlugTests(unittest.TestCase):
    def test_basics(self):
        self.assertEqual(publish.slugify("Alex Morgan Weekly"), "Alex-Morgan-Weekly")
        self.assertEqual(publish.slugify("  spaced   out  "), "spaced-out")
        self.assertEqual(publish.slugify("숬빛 주간 회의"), "숬빛-주간-회의")
        self.assertEqual(publish.slugify("Acme × Fabrikam-Health 리뷰 Q&A (v2)"), "Acme-Fabrikam-Health-리뷰-Q&A-(v2)")

    def test_forbidden_and_control_characters_removed(self):
        self.assertEqual(publish.slugify('a/b\\c:d*e?f"g<h>i|j'), "abcdefghij")
        self.assertEqual(publish.slugify("tab\there\x00nul\x1fx"), "tab-herenul-x")
        self.assertEqual(publish.slugify("emoji \U0001F680 launch"), "emoji-launch")
        self.assertEqual(publish.slugify("it's, a. test"), "its-a.-test")

    def test_length_trailing_dots_and_empty(self):
        long = publish.slugify("x" * 200)
        self.assertEqual(len(long), 60)
        self.assertEqual(len(publish.slugify("가" * 100)), 60)
        self.assertEqual(publish.slugify("end with dots..."), "end-with-dots")
        self.assertEqual(publish.slugify("cut here " + "a" * 51 + "."), "cut-here-" + "a" * 51)
        self.assertEqual(publish.slugify("..."), "")
        self.assertEqual(publish.slugify("///"), "")
        self.assertEqual(publish.slugify(None), "")
        self.assertFalse(publish.slugify("a" * 59 + " bbbb").endswith("-"))

    def test_nfd_input_is_composed(self):
        nfd = unicodedata.normalize("NFD", "회의록")
        self.assertEqual(publish.slugify(nfd), "회의록")
        self.assertTrue(unicodedata.is_normalized("NFC", publish.slugify(nfd)))

    def test_folder_name(self):
        start = datetime.fromisoformat(START)
        self.assertEqual(publish.folder_name(start, "Weekly"), "2026-10-07_1400_Weekly")
        self.assertEqual(publish.folder_name(start, ""), "2026-10-07_1400_meeting")

    def test_session_start_uses_recorded_wall_clock_and_session_id_fallback(self):
        self.assertEqual(f"{publish.session_start({'start_time': START}):%Y-%m-%d_%H%M}", "2026-10-07_1400")
        self.assertEqual(f"{publish.session_start({'session_id': '2026-10-07_0930_zoom'}):%H%M}", "0930")
        self.assertEqual(f"{publish.session_start({'start_time': 'junk', 'session_id': '2026-01-02_2359_meet'}):%d-%H%M}", "02-2359")
        self.assertIsNone(publish.session_start({}))
        self.assertEqual(publish.parse_iso("2026-10-07T05:00:12Z").utcoffset(), timedelta(0))


class ArchiveStatusTests(TempCase):
    def test_ok_creates_one_level_only(self):
        cfg = make_cfg(self.root)
        ok, why = publish.archive_status(cfg)
        self.assertTrue(ok, why)
        self.assertTrue(cfg.archive_dir.is_dir())
        self.assertEqual(os.listdir(cfg.archive_dir), [])           # probe file removed

    def test_missing_parent_is_unavailable_and_creates_nothing(self):
        cfg = make_cfg(self.root)
        cfg.archive_dir = self.root / "GoogleDrive-x" / "My Drive" / "Meetings"
        ok, why = publish.archive_status(cfg)
        self.assertFalse(ok)
        self.assertIn("does not exist", why)
        self.assertFalse((self.root / "GoogleDrive-x").exists())

    def test_read_only_archive_is_unavailable(self):
        cfg = make_cfg(self.root)
        cfg.archive_dir.mkdir(parents=True)
        cfg.archive_dir.chmod(0o555)
        self.addCleanup(cfg.archive_dir.chmod, 0o755)
        ok, why = publish.archive_status(cfg)
        self.assertFalse(ok)
        self.assertIn("not writable", why)


class CleanupTests(TempCase):
    def test_wavs_removed_only_when_m4a_verified(self):
        cfg = make_cfg(self.root)
        d = make_session(cfg)
        session = json.loads((d / "session.json").read_text())
        (d / "transcript.md").write_text("t")
        (d / "_work").mkdir()
        (d / "_work" / "chunk.npy").write_bytes(b"x")
        (d / "asr.tmp").write_text("x")
        # no m4a yet: nothing is deleted
        self.assertEqual(publish.cleanup_work_files(d, session), [])
        self.assertTrue((d / "mic.wav").exists())
        # only some m4a: still nothing is deleted
        fake_m4a(d / "audio.m4a")
        self.assertEqual(publish.cleanup_work_files(d, session), [])
        # corrupt m4a (zero bytes / no ftyp): nothing is deleted
        (d / "mic.m4a").write_bytes(b"")
        fake_m4a(d / "remote.m4a")
        self.assertEqual(publish.cleanup_work_files(d, session), [])
        (d / "mic.m4a").write_bytes(b"x" * 4096)
        self.assertEqual(publish.cleanup_work_files(d, session), [])
        self.assertTrue((d / "remote.wav").exists())
        # all good
        fake_m4a(d / "mic.m4a")
        removed = publish.cleanup_work_files(d, session)
        self.assertEqual(sorted(removed), ["_work", "asr.tmp", "mic.wav", "remote.wav"])
        self.assertEqual(sorted(p.name for p in d.iterdir()),
                         ["audio.m4a", "mic.m4a", "remote.m4a", "session.json", "transcript.md"])

    def test_missing_track_is_not_required(self):
        cfg = make_cfg(self.root)
        d = make_session(cfg, tracks=("mic",))
        session = json.loads((d / "session.json").read_text())
        fake_m4a(d / "audio.m4a")
        fake_m4a(d / "mic.m4a")
        self.assertEqual(publish.cleanup_work_files(d, session), ["mic.wav"])


class PublishTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)
        self.src = make_session(self.cfg)
        self.session = json.loads((self.src / "session.json").read_text())
        for name in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(self.src / name)
        (self.src / "transcript.md").write_text("# Transcript\n\nMeeting: x\n", encoding="utf-8")
        (self.src / "state.json").write_text("{}", encoding="utf-8")

    def test_moves_to_month_folder_with_slug_and_removes_wavs(self):
        dest = publish.publish(self.src, self.cfg, "Alex Morgan Weekly", self.session)
        self.assertEqual(dest, self.cfg.archive_dir / "2026-10" / "2026-10-07_1400_Alex-Morgan-Weekly")
        self.assertFalse(self.src.exists())
        names = sorted(p.name for p in dest.iterdir())
        self.assertEqual(names, ["audio.m4a", "mic.m4a", "remote.m4a", "session.json", "state.json", "transcript.md"])

    def test_hangul_title_and_spaces_in_paths(self):
        self.assertIn(" ", str(self.cfg.support_dir))
        dest = publish.publish(self.src, self.cfg, "숬빛 주간 회의: Q3/Q4 버전?", self.session)
        self.assertEqual(dest.name, "2026-10-07_1400_숬빛-주간-회의-Q3Q4-버전")
        self.assertTrue((dest / "transcript.md").is_file())

    def test_collision_gets_numeric_suffix(self):
        first = publish.publish(self.src, self.cfg, "Weekly", self.session)
        src2 = make_session(self.cfg)
        for name in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(src2 / name)
        second = publish.publish(src2, self.cfg, "Weekly", self.session)
        self.assertEqual(first.name, "2026-10-07_1400_Weekly")
        self.assertEqual(second.name, "2026-10-07_1400_Weekly-2")

    def test_empty_slug_falls_back_to_platform_label_then_meeting(self):
        dest = publish.publish(self.src, self.cfg, "///", self.session)
        self.assertEqual(dest.name, "2026-10-07_1400_Google-Meet")

    def test_cross_volume_copy_verify_then_delete_source(self):
        real_rename = os.rename
        staging = self.src

        def exdev_for_staging(src, dst, *a, **k):
            if Path(src) == staging:
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            return real_rename(src, dst, *a, **k)

        with mock.patch("mcap.publish.os.rename", side_effect=exdev_for_staging):
            dest = publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertFalse(self.src.exists())
        self.assertTrue((dest / "audio.m4a").stat().st_size == 2048)
        self.assertEqual([p.name for p in dest.parent.iterdir() if p.name.startswith(".")], [])    # no .partial left

    def test_any_refused_rename_falls_back_to_copy_verify_delete(self):
        real_rename = os.rename
        staging = self.src

        def refuse(src, dst, *a, **k):
            if Path(src) == staging:
                raise OSError(errno.EPERM, "Operation not permitted")      # e.g. what a File Provider volume may answer
            return real_rename(src, dst, *a, **k)

        with mock.patch("mcap.publish.os.rename", side_effect=refuse):
            dest = publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertFalse(self.src.exists())
        self.assertTrue((dest / "audio.m4a").is_file())

    def test_failed_copy_keeps_the_source_untouched_and_cleans_partial(self):
        real_rename = os.rename
        staging = self.src

        def exdev(src, dst, *a, **k):
            if Path(src) == staging:
                raise OSError(errno.EXDEV, "cross-device")
            return real_rename(src, dst, *a, **k)

        with mock.patch("mcap.publish.os.rename", side_effect=exdev), \
                mock.patch("mcap.publish._verify_copy", side_effect=publish.PublishError("size mismatch")):
            with self.assertRaises(publish.PublishError):
                publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertTrue((self.src / "session.json").exists())
        self.assertTrue((self.src / "audio.m4a").exists())
        month = self.cfg.archive_dir / "2026-10"
        self.assertEqual(list(month.iterdir()), [])                 # no partial, no final folder

    def test_archive_unavailable_leaves_everything_including_wavs(self):
        self.cfg.archive_dir = self.root / "not-mounted" / "My Drive" / "Meetings"
        with self.assertRaises(publish.ArchiveUnavailable) as cm:
            publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertIn("archive unavailable", str(cm.exception))
        self.assertTrue((self.src / "mic.wav").exists())
        self.assertTrue((self.src / "remote.wav").exists())
        self.assertTrue((self.src / "audio.m4a").exists())

    def test_wavs_kept_when_m4a_is_incomplete_but_publish_still_moves(self):
        (self.src / "mic.m4a").unlink()
        dest = publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertTrue((dest / "mic.wav").exists())               # audio never deleted without its m4a
        self.assertTrue((dest / "remote.wav").exists())

    def test_move_failure_other_than_exdev_raises_publish_error(self):
        with mock.patch("mcap.publish.os.rename", side_effect=OSError(errno.EACCES, "denied")):
            with self.assertRaises(publish.PublishError):
                publish.publish(self.src, self.cfg, "Weekly", self.session)
        self.assertTrue((self.src / "session.json").exists())

    def test_discard_session_moves_to_discarded_with_collision_suffix(self):
        parked = publish.discard_session(self.src, self.cfg)
        self.assertEqual(parked, self.cfg.sessions_dir / "_discarded" / "2026-10-07_1400_meet")
        self.assertTrue((parked / "mic.wav").exists())             # audio kept for 7 days
        again = make_session(self.cfg)
        self.assertEqual(publish.discard_session(again, self.cfg).name, "2026-10-07_1400_meet-2")

    def test_leave_tombstone(self):
        publish.leave_tombstone(self.cfg.sessions_dir / "gone", {"stage": "done", "final_dir": "/x"})
        data = json.loads((self.cfg.sessions_dir / "gone" / "state.json").read_text())
        self.assertEqual(data["final_dir"], "/x")


class TranscriptTitleTests(TempCase):
    def test_rewrites_meeting_line_atomically(self):
        p = self.root / "transcript.md"
        p.write_text("# Transcript\n\nMeeting: Google Meet\nDate: 2026-10-07\n\n[00:00:13] Me\nMeeting: not a header\n", encoding="utf-8")
        self.assertTrue(publish.set_transcript_title(p, "Alex  Weekly\n"))
        text = p.read_text(encoding="utf-8")
        self.assertIn("Meeting: Alex Weekly\n", text)
        self.assertIn("Meeting: not a header", text)               # only the header line changes
        self.assertFalse(publish.set_transcript_title(p, "Alex Weekly"))   # unchanged
        self.assertFalse(publish.set_transcript_title(self.root / "missing.md", "x"))
        self.assertEqual([x.name for x in self.root.iterdir()], ["transcript.md"])


class PruneTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root, audio_retention_days=30)
        self.now = datetime(2026, 10, 7, 12, 0).timestamp()

    def meeting(self, name, *, transcript=True, month=None):
        d = self.cfg.archive_dir / (month or name[:7]) / name
        d.mkdir(parents=True)
        for f in ("audio.m4a", "mic.m4a", "remote.m4a"):
            fake_m4a(d / f)
        (d / "meeting-note.md").write_text("note")
        (d / "transcript.json").write_text("{}")
        if transcript:
            (d / "transcript.md").write_text("t")
        return d

    def test_old_audio_deleted_but_never_transcripts_or_notes(self):
        old = self.meeting("2026-08-01_1000_Old")
        recent = self.meeting("2026-10-01_1000_Recent")
        no_tx = self.meeting("2026-07-01_1000_NoTranscript", transcript=False)
        report = publish.prune_audio(self.cfg, now=self.now)
        self.assertEqual(len(report.audio), 3)
        self.assertEqual(sorted(p.name for p in old.iterdir()), ["meeting-note.md", "transcript.json", "transcript.md"])
        self.assertEqual(len(list(recent.glob("*.m4a"))), 3)
        self.assertEqual(len(list(no_tx.glob("*.m4a"))), 3)        # folder without transcript.md: audio is the only data

    def test_retention_zero_keeps_everything(self):
        self.cfg.audio_retention_days = 0
        old = self.meeting("2025-01-01_1000_Old")
        report = publish.prune_audio(self.cfg, now=self.now)
        self.assertEqual(report.audio, [])
        self.assertEqual(len(list(old.glob("*.m4a"))), 3)

    def test_dry_run_deletes_nothing(self):
        old = self.meeting("2026-08-01_1000_Old")
        report = publish.prune_audio(self.cfg, now=self.now, dry_run=True)
        self.assertEqual(len(report.audio), 3)
        self.assertEqual(len(list(old.glob("*.m4a"))), 3)
        self.assertIn("would delete", report.summary())

    def test_ignores_foreign_folders_and_symlinks(self):
        (self.cfg.archive_dir / "Notes").mkdir(parents=True)
        fake_m4a(self.cfg.archive_dir / "Notes" / "keep.m4a")
        (self.cfg.archive_dir / "2026-08").mkdir(parents=True)
        (self.cfg.archive_dir / "2026-08" / "random.m4a").write_bytes(b"x")
        target = self.root / "elsewhere"
        target.mkdir()
        (target / "transcript.md").write_text("t")
        fake_m4a(target / "audio.m4a")
        (self.cfg.archive_dir / "2026-08" / "2026-08-01_1000_Link").symlink_to(target)
        report = publish.prune_audio(self.cfg, now=self.now)
        self.assertEqual(report.audio, [])
        self.assertTrue((target / "audio.m4a").exists())

    def test_local_housekeeping_discarded_tombstones_locks(self):
        old_disc = self.cfg.discarded_dir / "2026-09-01_1000_meet"
        new_disc = self.cfg.discarded_dir / "2026-10-06_1000_meet"
        for d, age in ((old_disc, 8), (new_disc, 6)):
            d.mkdir(parents=True)
            (d / "mic.wav").write_bytes(b"x")
            stamp = self.now - age * DAY
            (d / "state.json").write_text("{}")
            os.utime(d / "state.json", (stamp, stamp))
        old_stub = self.cfg.sessions_dir / "2026-08-01_1000_meet"
        new_stub = self.cfg.sessions_dir / "2026-10-05_1000_meet"
        for d, age in ((old_stub, 31), (new_stub, 2)):
            d.mkdir(parents=True)
            (d / "state.json").write_text("{}")
            stamp = self.now - age * DAY
            os.utime(d / "state.json", (stamp, stamp))
        live = self.cfg.sessions_dir / "2026-08-02_1000_meet"          # a real session (has audio): never touched
        live.mkdir()
        (live / "state.json").write_text("{}")
        (live / "mic.wav").write_bytes(b"x")
        os.utime(live / "state.json", (self.now - 90 * DAY,) * 2)
        self.cfg.locks_dir.mkdir(parents=True)
        (self.cfg.locks_dir / "old.lock").write_text("1")
        (self.cfg.locks_dir / "new.lock").write_text("1")
        os.utime(self.cfg.locks_dir / "old.lock", (self.now - 8 * DAY,) * 2)
        os.utime(self.cfg.locks_dir / "new.lock", (self.now - DAY,) * 2)
        report = publish.prune_audio(self.cfg, now=self.now)
        self.assertFalse(old_disc.exists())
        self.assertTrue(new_disc.exists())
        self.assertFalse(old_stub.exists())
        self.assertTrue(new_stub.exists())
        self.assertTrue((live / "mic.wav").exists())
        self.assertFalse((self.cfg.locks_dir / "old.lock").exists())
        self.assertTrue((self.cfg.locks_dir / "new.lock").exists())
        self.assertEqual((len(report.discarded), len(report.tombstones), len(report.locks)), (1, 1, 1))

    def test_old_stubs_of_meetings_still_waiting_for_their_note_are_kept(self):
        """`reprocess --pending` finds a published-without-note meeting through its staging stub: pruning it after 30 days would end
        the retries silently."""
        waiting = self.cfg.sessions_dir / "2026-08-01_1000_meet"
        finished = self.cfg.sessions_dir / "2026-08-02_1000_meet"
        hopeless = self.cfg.sessions_dir / "2026-08-03_1000_meet"
        for d, state in ((waiting, {"stage": "failed", "retryable": True, "error_kind": "usage_limit"}),
                         (finished, {"stage": "done"}), (hopeless, {"stage": "failed", "retryable": False})):
            d.mkdir(parents=True)
            (d / "state.json").write_text(json.dumps(state))
            os.utime(d / "state.json", (self.now - 90 * DAY,) * 2)
        report = publish.prune_audio(self.cfg, now=self.now)
        self.assertTrue(waiting.exists())
        self.assertFalse(finished.exists())
        self.assertFalse(hopeless.exists())
        self.assertEqual(len(report.tombstones), 2)


if __name__ == "__main__":
    unittest.main()
