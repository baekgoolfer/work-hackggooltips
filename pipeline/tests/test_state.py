"""state.json (SPEC 4.3): defaults, merge rules, atomicity."""
import json
import os
import threading
import unittest
from unittest import mock

from notes_cli_support import TempCase

from mcap import state


class StateTests(TempCase):
    def test_default_when_missing_or_corrupt(self):
        d = self.root / "s"
        d.mkdir()
        st = state.read_state(d)
        self.assertEqual(st["stage"], "queued")
        self.assertEqual(st["done"], {"audio": False, "asr": False, "note": False, "publish": False})
        for key in ("schema", "stage_detail", "error", "error_kind", "retryable", "resets_at", "updated", "title", "final_dir", "discarded"):
            self.assertIn(key, st)
        (d / "state.json").write_text("{not json", encoding="utf-8")
        self.assertEqual(state.read_state(d)["stage"], "queued")
        (d / "state.json").write_text("[1,2]", encoding="utf-8")
        self.assertEqual(state.read_state(d)["stage"], "queued")

    def test_write_merges_done_and_resets_error_on_new_stage(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, stage="failed", error="boom", error_kind="usage_limit", retryable=True, resets_at="2026-10-07T18:00:00+09:00")
        st = state.read_state(d)
        self.assertEqual((st["stage"], st["error"], st["error_kind"], st["retryable"]), ("failed", "boom", "usage_limit", True))
        state.write_state(d, stage="audio", done={"audio": True})
        st = state.read_state(d)
        self.assertIsNone(st["error"])
        self.assertIsNone(st["error_kind"])
        self.assertIsNone(st["retryable"])
        self.assertIsNone(st["resets_at"])
        state.write_state(d, stage="transcribing", stage_detail="remote 12/48", done={"asr": False})
        st = state.read_state(d)
        self.assertEqual(st["stage_detail"], "remote 12/48")
        self.assertTrue(st["done"]["audio"])          # earlier flag survives
        state.write_state(d, stage="noting")
        self.assertIsNone(state.read_state(d)["stage_detail"])   # new stage clears the detail

    def test_failed_stage_keeps_given_fields(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, stage="failed", error="Note failed: usage limit", retryable=True, title="T", final_dir="/x")
        st = json.loads((d / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(st["title"], "T")
        self.assertEqual(st["final_dir"], "/x")
        self.assertEqual(st["schema"], 1)

    def test_unicode_and_updated_timestamp(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, title="숬빛 주간 회의")
        raw = (d / "state.json").read_text(encoding="utf-8")
        self.assertIn("숬빛", raw)            # not \u-escaped
        self.assertRegex(state.read_state(d)["updated"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$")

    def test_write_never_raises_and_old_file_survives_failed_replace(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, stage="transcribing", stage_detail="before")
        with mock.patch("mcap.state.os.replace", side_effect=OSError("disk full")):
            st = state.write_state(d, stage="noting")            # must not raise
        self.assertEqual(st["stage"], "noting")                   # returned merged state
        self.assertEqual(state.read_state(d)["stage"], "transcribing")   # file untouched
        self.assertEqual([p.name for p in d.iterdir()], ["state.json"])  # temp file removed

    def test_atomic_write_leaves_no_temp_and_replaces_whole_file(self):
        p = self.root / "f.txt"
        state.atomic_write_text(p, "one")
        state.atomic_write_text(p, "two")
        self.assertEqual(p.read_text(encoding="utf-8"), "two")
        self.assertEqual([x.name for x in self.root.iterdir()], ["f.txt"])
        with mock.patch("mcap.state.os.fsync", side_effect=OSError("io")):
            with self.assertRaises(OSError):
                state.atomic_write_text(p, "three")
        self.assertEqual(p.read_text(encoding="utf-8"), "two")
        self.assertEqual([x.name for x in self.root.iterdir()], ["f.txt"])

    def test_reader_never_sees_a_torn_file_while_writer_hammers(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, stage="queued")
        stop = threading.Event()
        bad: list = []

        def reader():
            while not stop.is_set():
                try:
                    json.loads((d / "state.json").read_text(encoding="utf-8"))
                except FileNotFoundError:
                    bad.append("missing")
                except ValueError as exc:
                    bad.append(str(exc))

        t = threading.Thread(target=reader)
        t.start()
        try:
            for i in range(300):
                state.write_state(d, stage="transcribing", stage_detail=f"chunk {i}/300 " + "x" * 2000)
        finally:
            stop.set()
            t.join()
        self.assertEqual(bad, [])

    def test_remove_state_and_read_json_helpers(self):
        d = self.root / "s"
        d.mkdir()
        state.write_state(d, stage="done")
        state.remove_state(d)
        self.assertFalse((d / "state.json").exists())
        state.remove_state(d)                                     # idempotent
        self.assertIsNone(state.read_json(d / "nope.json"))


if __name__ == "__main__":
    unittest.main()
