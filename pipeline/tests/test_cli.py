"""cli.py / __main__.py: command behaviour, exit codes, last-line contract, reprocess target selection, doctor, prune-audio,
transcribe-file. Claude is the FAKE executable; the transcription component is FakeASR."""
import contextlib
import importlib.util
import io
import json
import logging
import os
import subprocess
import sys
import time
import unittest
import wave
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

from notes_cli_support import (CANARY, FakeASR, FakeClaude, StubNote, TempCase, afconvert_available, canary_hits, fake_m4a, make_cfg,
                               make_session, ready_ok, sample_note)

from mcap import apikey, cli, overage, pipeline, usage
from mcap.state import read_state, write_state

PIPELINE_DIR = Path(__file__).resolve().parents[1]


class TtyInput(io.StringIO):
    def isatty(self):
        return True


# doctor and transcribe-file import numpy (a hard requirement of the production venv; the rest of mcap runs without it)
NEEDS_NUMPY = unittest.skipUnless(importlib.util.find_spec("numpy") is not None, "numpy not installed")


class CliBase(TempCase):
    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.cfg = make_cfg(self.root, self.fake, note_timeout_seconds=60)
        self.asr = FakeASR()
        self.stub = StubNote()
        self.write_config()
        # emulate an installed SUPPORT_DIR (the installer copies these two files there)
        for name in ("note_prompt.md", "vocabulary.txt"):
            (self.cfg.support_dir / name).write_text((self.cfg.project_dir / "config" / name).read_text(encoding="utf-8"), encoding="utf-8")
        env = {"MCAP_CONFIG": str(self.root / "config.env"), "MCAP_LOG_DIR": str(self.root / "logs"), "HF_HUB_OFFLINE": "1"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("MCAP_SILERO_MODEL", None)     # the VAD tests need it exported; the doctor tests expect "no model" (undone by patcher.stop)
        hf = mock.patch("mcap.cli._hf_cache_roots", return_value=[self.root / "hf-empty" / "hub"])     # never look at the real HF cache
        hf.start()
        self.addCleanup(hf.stop)

    def write_config(self, **extra):
        values = {"SUPPORT_DIR": self.cfg.support_dir, "ARCHIVE_DIR": self.cfg.archive_dir, "PROJECT_DIR": self.cfg.project_dir,
                  "PYTHON_BIN": sys.executable, "CLAUDE_BIN": self.cfg.claude_bin, "CALENDAR_LOOKUP": "0",
                  "NOTE_TIMEOUT_SECONDS": "60", "CLAUDE_AUTH": "subscription"}      # the built-in default is api; api tests pass CLAUDE_AUTH=api
        values.update(extra)
        (self.root / "config.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def deps(self, stub=None, **extra):
        kwargs = {"check_ready": ready_ok, "generate_note": stub or self.stub}
        kwargs.update(extra)
        return self.asr.deps(**kwargs)

    def run_cli(self, *argv, deps=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(argv), deps=deps)
        return code, out.getvalue(), err.getvalue()

    def session(self, sid="2026-10-07_1400_meet", **kw):
        return make_session(self.cfg, sid, **kw)


class ProcessCommandTests(CliBase):
    def test_success_exit_0_and_last_line(self):
        src = self.session()
        code, out, _err = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(code, 0)
        last = out.strip().splitlines()[-1]
        self.assertTrue(last.startswith("DONE: "), last)
        self.assertTrue(Path(last[6:]).is_dir())

    def test_note_failure_exit_1_with_one_line_reason_last(self):
        src = self.session()
        stub = StubNote(ok=False, kind="usage_limit", error="Claude usage limit reached (resets 2026-10-07 18:00 KST)")
        code, out, _err = self.run_cli("process", str(src), deps=self.deps(stub))
        self.assertEqual(code, 1)
        last = out.strip().splitlines()[-1]
        self.assertTrue(last.startswith("FAILED: Note failed: Claude usage limit reached"), last)
        self.assertIn("transcript kept in", last)
        self.assertEqual(len(out.strip().splitlines()[-1].splitlines()), 1)

    def test_asr_failure_exit_1(self):
        src = self.session()
        self.asr.fail_asr = "model not found"
        code, out, _err = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(code, 1)
        self.assertEqual(out.strip().splitlines()[-1], "FAILED: transcription failed: model not found")
        self.assertTrue((src / "mic.wav").exists())

    def test_discarded_session_exit_0(self):
        src = self.session()
        self.asr.speech_seconds = 3
        code, out, _err = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(code, 0)
        self.assertIn("DONE: no speech", out)

    def test_bad_arguments(self):
        code, _out, err = self.run_cli("process", str(self.root / "missing"))
        self.assertEqual(code, 2)
        self.assertIn("not a directory", err)
        plain = self.root / "plain"
        plain.mkdir()
        code, _out, err = self.run_cli("process", str(plain))
        self.assertEqual(code, 2)
        self.assertIn("no session.json", err)

    def test_busy_session_exit_75(self):
        src = self.session()
        with pipeline.session_lock(self.cfg, "2026-10-07_1400_meet"):
            code, out, _err = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(code, 75)
        self.assertIn("BUSY", out)

    def test_flags_reach_the_pipeline(self):
        src = self.session()
        seen = {}

        def fake_process(path, cfg, force=False, from_stage=None, allow_overage=False, deps=None):
            seen.update(path=path, force=force, from_stage=from_stage, allow_overage=allow_overage)
            return pipeline.PipelineResult(True, "done", Path("/x"), published=True)

        with mock.patch("mcap.cli.pipeline.process_session", fake_process):
            code, _out, _err = self.run_cli("process", str(src), "--force", "--from", "note", "--allow-overage")
        self.assertEqual(code, 0)
        self.assertEqual((seen["force"], seen["from_stage"], seen["allow_overage"]), (True, "note", True))

    def test_invalid_from_stage_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as cm:
                cli.main(["process", "x", "--from", "bogus"])
        self.assertEqual(cm.exception.code, 2)

    def test_process_on_tombstone_redirects_to_published_folder(self):
        src = self.session()
        first = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(first[0], 0)
        code, out, _err = self.run_cli("process", str(src), deps=self.deps())     # staging dir is only a tombstone now
        self.assertEqual(code, 0)
        self.assertIn("already published", out)

    def test_housekeeping_runs_after_processing_and_never_affects_the_result(self):
        old = self.cfg.discarded_dir / "2026-09-01_1000_meet"
        old.mkdir(parents=True)
        (old / "state.json").write_text("{}")
        os.utime(old / "state.json", (time.time() - 9 * 86400,) * 2)
        src = self.session()
        code, _out, _err = self.run_cli("process", str(src), deps=self.deps())
        self.assertEqual(code, 0)
        self.assertFalse(old.exists())
        with mock.patch("mcap.cli.publish.prune_audio", side_effect=RuntimeError("boom")):
            src2 = self.session("2026-10-07_1600_meet", start="2026-10-07T16:00:00+09:00", end="2026-10-07T16:30:00+09:00")
            code, _out, _err = self.run_cli("process", str(src2), deps=self.deps())
        self.assertEqual(code, 0)


class ReprocessCommandTests(CliBase):
    def test_nothing_to_reprocess(self):
        code, _out, err = self.run_cli("reprocess", "--last")
        self.assertEqual(code, 3)
        self.assertIn("nothing to reprocess", err)

    def test_last_resumes_a_failed_published_meeting_in_place(self):
        src = self.session()
        failing = StubNote(ok=False, kind="usage_limit", error="limit", retryable=True)
        self.assertEqual(self.run_cli("process", str(src), deps=self.deps(failing))[0], 1)
        good = StubNote()
        code, out, _err = self.run_cli("reprocess", "--last", deps=self.deps(good))
        self.assertEqual(code, 0, out)
        self.assertIn("reprocessing", out)
        self.assertNotIn("complete", out)
        self.assertEqual(len(good.calls), 1)
        self.assertEqual(self.asr.asr_calls, 1)
        folders = [p for m in self.cfg.archive_dir.iterdir() for p in m.iterdir()]
        self.assertEqual(len(folders), 1)
        self.assertTrue((folders[0] / "meeting-note.md").exists())

    def test_last_on_a_complete_meeting_regenerates_the_note(self):
        src = self.session()
        self.assertEqual(self.run_cli("process", str(src), deps=self.deps())[0], 0)
        again = StubNote(text=sample_note(extra="SECOND VERSION"))
        code, out, _err = self.run_cli("reprocess", deps=self.deps(again))          # --last is the default
        self.assertEqual(code, 0)
        self.assertIn("meeting is complete: regenerating the note", out)
        self.assertEqual(self.asr.asr_calls, 1)
        folder = next(p for m in self.cfg.archive_dir.iterdir() for p in m.iterdir())
        self.assertIn("SECOND VERSION", (folder / "meeting-note.md").read_text(encoding="utf-8"))

    def test_last_prefers_the_newest_by_start_time_staging_or_archive(self):
        old = self.session("2026-10-06_0900_meet", start="2026-10-06T09:00:00+09:00", end="2026-10-06T09:30:00+09:00")
        self.assertEqual(self.run_cli("process", str(old), deps=self.deps())[0], 0)       # now in the archive
        newest_staging = self.session("2026-10-07_1100_meet", start="2026-10-07T11:00:00+09:00", end="2026-10-07T11:30:00+09:00")
        self.asr.fail_asr = "boom"
        self.assertEqual(self.run_cli("process", str(newest_staging), deps=self.deps())[0], 1)   # stays in staging, failed
        self.asr.fail_asr = None
        code, out, _err = self.run_cli("reprocess", "--last", deps=self.deps())
        self.assertEqual(code, 0)
        self.assertIn(str(newest_staging), out)
        self.assertEqual(len([p for m in self.cfg.archive_dir.iterdir() for p in m.iterdir()]), 2)

    def test_explicit_dir_and_from_stage(self):
        src = self.session()
        self.assertEqual(self.run_cli("process", str(src), deps=self.deps())[0], 0)
        folder = next(p for m in self.cfg.archive_dir.iterdir() for p in m.iterdir())
        stub = StubNote()
        code, _out, _err = self.run_cli("reprocess", str(folder), "--from", "note", deps=self.deps(stub))
        self.assertEqual(code, 0)
        self.assertEqual(len(stub.calls), 1)
        code, _out, err = self.run_cli("reprocess", str(self.root), deps=self.deps())
        self.assertEqual(code, 2)

    def test_allow_overage_flag_is_passed_to_the_note_stage(self):
        src = self.session()
        self.assertEqual(self.run_cli("process", str(src), deps=self.deps())[0], 0)
        stub = StubNote()
        self.run_cli("reprocess", "--allow-overage", deps=self.deps(stub))
        self.assertTrue(stub.calls[0]["allow_overage"])
        stub2 = StubNote()
        self.run_cli("reprocess", deps=self.deps(stub2))
        self.assertFalse(stub2.calls[0]["allow_overage"])


@NEEDS_NUMPY
class TranscribeFileTests(CliBase):
    def make_wav(self, name="speech.wav", seconds=1.0, rate=16000):
        path = self.root / name
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(b"\x10\x00" * int(rate * seconds))
        return path

    def fake_array(self, record):
        def transcribe_array(audio, cfg, vocab, language=None, progress=lambda m: None):
            record.update(n=len(audio), language=language, model=cfg.asr_model, dtype=str(audio.dtype))
            progress("chunk 1/1")
            return [{"start": 0.5, "end": 3.0, "text": "hello world", "lang": "en"}]
        return transcribe_array

    @unittest.skipUnless(afconvert_available(), "afconvert not available")
    def test_stdout_and_overrides(self):
        wav = self.make_wav(rate=44100)
        record = {}
        deps = self.deps(transcribe_array=self.fake_array(record))
        code, out, _err = self.run_cli("transcribe-file", str(wav), "--model", "mlx-community/whisper-tiny-mlx", "--language", "ko", deps=deps)
        self.assertEqual(code, 0)
        self.assertEqual((record["language"], record["model"], record["dtype"]), ("ko", "mlx-community/whisper-tiny-mlx", "float32"))
        self.assertAlmostEqual(record["n"] / 16000, 1.0, delta=0.1)               # resampled to 16 kHz
        self.assertIn("Meeting: speech.wav", out)
        self.assertIn("hello world", out)
        self.assertIn("mlx-community/whisper-tiny-mlx", out)

    @unittest.skipUnless(afconvert_available(), "afconvert not available")
    def test_out_file_and_auto_language(self):
        wav = self.make_wav()
        record = {}
        out_path = self.root / "out dir" / "t.md"
        out_path.parent.mkdir()
        code, out, _err = self.run_cli("transcribe-file", str(wav), "--out", str(out_path),
                                       deps=self.deps(transcribe_array=self.fake_array(record)))
        self.assertEqual(code, 0)
        self.assertIsNone(record["language"])                                     # auto -> None (SPEC 12.2)
        self.assertIn("hello world", out_path.read_text(encoding="utf-8"))
        self.assertTrue(out.startswith("DONE: "))

    def test_errors(self):
        code, _out, err = self.run_cli("transcribe-file", str(self.root / "missing.wav"))
        self.assertEqual(code, 2)
        bad = self.root / "bad.wav"
        bad.write_bytes(b"not audio")
        code, _out, err = self.run_cli("transcribe-file", str(bad), deps=self.deps())
        self.assertEqual(code, 1)
        self.assertIn("FAILED", err)


class PruneCommandTests(CliBase):
    def test_prune_audio_command(self):
        self.write_config(AUDIO_RETENTION_DAYS="30")
        old = self.cfg.archive_dir / "2020-01" / "2020-01-02_1000_Old"
        old.mkdir(parents=True)
        for f in ("audio.m4a", "mic.m4a"):
            fake_m4a(old / f)
        (old / "transcript.md").write_text("t")
        (old / "meeting-note.md").write_text("n")
        code, out, _err = self.run_cli("prune-audio", "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("would delete", out)
        self.assertTrue((old / "audio.m4a").exists())
        code, out, _err = self.run_cli("prune-audio")
        self.assertEqual(code, 0)
        self.assertFalse((old / "audio.m4a").exists())
        self.assertTrue((old / "transcript.md").exists() and (old / "meeting-note.md").exists())
        self.assertIn("deleted: 2 audio file(s)", out)

    def test_retention_zero_message(self):
        code, out, _err = self.run_cli("prune-audio")
        self.assertEqual(code, 0)
        self.assertIn("AUDIO_RETENTION_DAYS=0", out)


@NEEDS_NUMPY
class DoctorTests(CliBase):
    def doctor(self, **extra):
        if extra:
            self.write_config(**extra)
        code, out, _err = self.run_cli("doctor", "--no-warmup")
        return code, out

    def line(self, out, name):
        return next(l for l in out.splitlines() if f"] {name}:" in l)

    def test_healthy_setup_passes_with_warnings_only(self):
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        for name in ("python", "numpy", "claude cli", "claude login", "billing mode", "overage guard", "archive dir", "afconvert", "note prompt"):
            self.assertTrue(self.line(out, name).startswith("[PASS]"), self.line(out, name))
        self.assertTrue(self.line(out, "asr model").startswith("[WARN]"))
        self.assertTrue(self.line(out, "silero vad").startswith("[WARN]"))
        self.assertTrue(self.line(out, "mlx warm-up").startswith("[WARN]"))
        self.assertRegex(out.strip().splitlines()[-1], r"^doctor: \d+ PASS, \d+ WARN, 0 FAIL$")

    def test_doctor_prints_the_seven_day_usage_summary(self):
        sid = "2026-10-07_1400_zoom"
        for stage, kw in (("cleanup", {}), ("cleanup", {}), ("note", {"is_using_overage": True}), ("verify", {}), ("calendar", {})):
            usage.record(self.cfg, stage, models=["claude-opus-5"], duration_s=1.0, session_id=sid, **kw)
        code, out = self.doctor()
        line = self.line(out, "claude usage")
        self.assertTrue(line.startswith("[PASS]"), line)
        self.assertIn("5 call(s) in the last 7 days (calendar 1, cleanup 2, note 1, verify 1)", line)
        self.assertIn("extra usage (overage) seen in 1 call(s)", line)
        self.assertIn("usage.jsonl", line)
        self.assertTrue(self.line(out, "claude call cap").startswith("[PASS]"))
        self.assertIn("MAX_CLAUDE_CALLS_PER_MEETING=30", self.line(out, "claude call cap"))

    def test_doctor_warns_about_a_call_cap_that_refused_calls_and_a_cap_that_is_too_low(self):
        usage.record(self.cfg, "verify", outcome=usage.OUTCOME_CAP, session_id="s")
        code, out = self.doctor(MAX_CLAUDE_CALLS_PER_MEETING="3")
        self.assertEqual(code, 0, out)
        self.assertTrue(self.line(out, "claude usage").startswith("[WARN]"))
        self.assertIn("refused by MAX_CLAUDE_CALLS_PER_MEETING", self.line(out, "claude usage"))
        cap = self.line(out, "claude call cap")
        self.assertTrue(cap.startswith("[WARN]"), cap)
        self.assertIn("always made", cap)

    def test_doctor_without_any_usage_says_so(self):
        code, out = self.doctor()
        self.assertIn("no claude call recorded in the last 7 days", self.line(out, "claude usage"))

    def test_doctor_names_the_calendar_window_and_the_off_switch(self):
        code, out = self.doctor(CALENDAR_LOOKUP="auto")
        line = self.line(out, "calendar")
        self.assertTrue(line.startswith("[PASS]"))
        self.assertIn("+-45 minutes", line)
        self.assertIn("only the matched event is kept", line)
        self.assertIn("CALENDAR_LOOKUP=0", line)
        code, out = self.doctor(CALENDAR_LOOKUP="0")
        self.assertIn("switched off", self.line(out, "calendar"))

    def test_note_prompt_drift_is_a_warning_and_missing_copy_falls_back(self):
        (self.cfg.support_dir / "note_prompt.md").write_text("my edited prompt", encoding="utf-8")
        code, out = self.doctor()
        self.assertEqual(code, 0)
        self.assertTrue(self.line(out, "note prompt").startswith("[WARN]"))
        self.assertIn("differs", self.line(out, "note prompt"))
        (self.cfg.support_dir / "note_prompt.md").unlink()
        code, out = self.doctor()
        self.assertEqual(code, 0)
        self.assertTrue(self.line(out, "note prompt").startswith("[PASS]"), self.line(out, "note prompt"))
        self.assertIn("repo copy", self.line(out, "note prompt"))
        self.assertIn("no override", self.line(out, "note prompt"))

    def test_not_logged_in_fails(self):
        self.fake.set(auth={"exit": 1, "json": {"loggedIn": False}})
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "claude login").startswith("[FAIL]"))

    def test_api_billing_login_fails_the_billing_check(self):
        self.fake.set(auth={"exit": 0, "json": {"loggedIn": True, "authMethod": "api_key", "apiProvider": "firstParty"}})
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "billing mode").startswith("[FAIL]"))
        self.assertIn("api_key", self.line(out, "billing mode"))

    def test_missing_claude_binary_fails(self):
        code, out = self.doctor(CLAUDE_BIN=self.root / "nope")
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "claude cli").startswith("[FAIL]"))

    def test_polluted_environment_is_a_warning(self):
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-x"}):
            code, out = self.doctor()
        self.assertEqual(code, 0)
        self.assertTrue(self.line(out, "environment").startswith("[WARN]"))
        self.assertIn("ANTHROPIC_API_KEY", self.line(out, "environment"))

    def test_overage_marker_is_a_warning(self):
        overage.write_marker(self.cfg, resets_at=int(time.time()) + 3600)
        code, out = self.doctor()
        self.assertEqual(code, 0)
        self.assertTrue(self.line(out, "overage guard").startswith("[WARN]"))
        self.assertIn("overage.json", self.line(out, "overage guard"))

    def test_stop_on_overage_off_is_a_deliberate_pass(self):
        # SPEC 14.1: extra usage is allowed on purpose (NOTE_STOP_ON_OVERAGE=0), so this is no warning.
        code, out = self.doctor(NOTE_STOP_ON_OVERAGE="0")
        self.assertEqual(code, 0, out)
        self.assertTrue(self.line(out, "overage guard").startswith("[PASS]"), self.line(out, "overage guard"))
        self.assertIn("on purpose", self.line(out, "overage guard"))

    def test_stop_on_overage_on_names_the_switch(self):
        code, out = self.doctor(NOTE_STOP_ON_OVERAGE="1")
        self.assertEqual(code, 0, out)
        self.assertTrue(self.line(out, "overage guard").startswith("[PASS]"), self.line(out, "overage guard"))
        self.assertIn("NOTE_STOP_ON_OVERAGE=1", self.line(out, "overage guard"))

    def test_archive_checks(self):
        code, out = self.doctor(ARCHIVE_DIR=self.root / "GoogleDrive-x" / "My Drive" / "Meetings")
        self.assertEqual(code, 1)
        self.assertIn("does not exist", self.line(out, "archive dir"))
        self.assertFalse((self.root / "GoogleDrive-x").exists())             # doctor creates nothing
        code, out = self.doctor(ARCHIVE_DIR=self.root / "Drive" / "My Drive" / "NewMeetings")
        self.assertEqual(code, 0)
        self.assertIn("it will be created", self.line(out, "archive dir"))
        self.assertFalse((self.root / "Drive" / "My Drive" / "NewMeetings").exists())
        self.assertEqual(os.listdir(self.root / "Drive" / "My Drive"), [])    # probe file removed
        ro = self.root / "ro"
        ro.mkdir()
        ro.chmod(0o555)
        self.addCleanup(ro.chmod, 0o755)
        code, out = self.doctor(ARCHIVE_DIR=ro)
        self.assertEqual(code, 1)
        self.assertIn("not writable", self.line(out, "archive dir"))

    def test_missing_python_fails_and_missing_afconvert_fails(self):
        code, out = self.doctor(PYTHON_BIN=self.root / "no-venv" / "bin" / "python")
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "python").startswith("[FAIL]"))
        with mock.patch("mcap.cli.shutil.which", return_value=None), mock.patch("mcap.cli.os.access", return_value=False):
            code, out = self.doctor(PYTHON_BIN=sys.executable)
        self.assertTrue(self.line(out, "afconvert").startswith("[FAIL]"))

    def test_bad_config_value_is_reported(self):
        self.write_config(NOTE_TIMEOUT_SECONDS="soon")
        code, out, _err = self.run_cli("doctor", "--no-warmup")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] config", out)

    def test_mlx_warmup_uses_the_configured_python(self):
        good = self.root / "good-python"
        good.write_text("#!/bin/sh\nexit 0\n")
        good.chmod(0o755)
        bad = self.root / "bad-python"
        bad.write_text("#!/bin/sh\necho \"ModuleNotFoundError: No module named 'mlx'\" >&2\nexit 1\n")
        bad.chmod(0o755)
        self.write_config(PYTHON_BIN=good)
        code, out, _err = self.run_cli("doctor")
        self.assertTrue(self.line(out, "mlx warm-up").startswith("[PASS]"), out)
        self.write_config(PYTHON_BIN=bad)
        code, out, _err = self.run_cli("doctor")
        self.assertEqual(code, 1)
        self.assertIn("No module named 'mlx'", self.line(out, "mlx warm-up"))

    def test_model_cache_and_silero_detection(self):
        hf = self.root / "hf"
        snap = hf / "hub" / "models--mlx-community--whisper-large-v3-mlx" / "snapshots" / "abc"
        snap.mkdir(parents=True)
        with mock.patch("mcap.cli._hf_cache_roots", return_value=[hf / "hub"]):
            self.assertFalse(cli.model_cache_status("mlx-community/whisper-large-v3-mlx")[0])        # no weights yet
            (snap / "config.json").write_text("{}")
            (snap / "weights.safetensors").write_bytes(b"x")
            self.assertTrue(cli.model_cache_status("mlx-community/whisper-large-v3-mlx")[0])
            self.assertFalse(cli.model_cache_status("mlx-community/other")[0])
        self.assertTrue(cli.model_cache_status(str(snap))[0])                                         # local directory
        self.assertFalse(cli.model_cache_status("not-a-repo-id")[0])
        model = self.root / "models" / "silero_vad.onnx"
        with mock.patch.dict(os.environ, {"MCAP_SILERO_MODEL": str(model)}):         # the VAD module's own override hook
            self.assertIsNone(cli.silero_model_path(self.cfg))
            model.parent.mkdir()
            model.write_bytes(b"onnx")
            self.assertEqual(cli.silero_model_path(self.cfg), model)
            code, out = self.doctor(ASR_VAD="silero")
            self.assertTrue(self.line(out, "silero vad").startswith("[PASS]"))
            model.unlink()
            code, out = self.doctor(ASR_VAD="silero")
            self.assertEqual(code, 1)
            self.assertTrue(self.line(out, "silero vad").startswith("[FAIL]"))
            code, out = self.doctor(ASR_VAD="energy")
            self.assertTrue(self.line(out, "silero vad").startswith("[PASS]"))


class UsageCommandTests(CliBase):
    def seed(self):
        sid = "2026-10-07_1400_zoom"
        for stage, kw in (("cleanup", {}), ("cleanup", {"outcome": "overloaded"}), ("note", {"is_using_overage": True}),
                          ("verify", {}), ("preflight", {}), ("verify", {"outcome": usage.OUTCOME_CAP})):
            usage.record(self.cfg, stage, models=[] if stage == "preflight" else ["claude-opus-5"], duration_s=2.0, session_id=sid, **kw)
        usage.record(self.cfg, "note", models=["claude-opus-5"], duration_s=2.0, session_id="2026-10-08_0900_teams",
                     is_using_overage=False)

    def test_usage_command_prints_calls_by_stage_and_the_overage_count(self):
        self.seed()
        code, out, _err = self.run_cli("usage")
        self.assertEqual(code, 0)
        for needle in ("last 7 days", "calls:        5 (cleanup 2, note 2, verify 1)", "meetings:     2", "claude-opus-5 x5",
                       "1 call(s) reported isUsingOverage=true", "1 call(s) ended with an error", "1 call(s) refused by",
                       "1 'claude auth status'", "MAX_CLAUDE_CALLS_PER_MEETING=30"):
            self.assertIn(needle, out)

    def test_usage_json_and_the_days_window(self):
        self.seed()
        code, out, _err = self.run_cli("usage", "--json")
        data = json.loads(out)
        self.assertEqual((code, data["calls"], data["by_stage"], data["overage_calls"], data["days"]),
                         (0, 5, {"cleanup": 2, "note": 2, "verify": 1}, 1, 7))
        old = (datetime.now().astimezone() - timedelta(days=30)).isoformat(timespec="seconds")
        with open(usage.usage_path(self.cfg), "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": old, "stage": "note", "outcome": "ok", "models": ["claude-opus-5"]}) + "\n")
        self.assertEqual(json.loads(self.run_cli("usage", "--json")[1])["calls"], 5)                  # 30 days ago is outside the 7
        self.assertEqual(json.loads(self.run_cli("usage", "--json", "--days", "60")[1])["calls"], 6)

    def test_usage_without_a_log_is_a_clean_message(self):
        code, out, _err = self.run_cli("usage")
        self.assertEqual(code, 0)
        self.assertIn("No claude call recorded in the last 7 days.", out)


class PendingCommandTests(CliBase):
    """`mcap reprocess --pending` (SPEC 15): failed + retryable sessions of every kind and sessions that died mid-stage; never a live
    recording, never a session another process is working on; safe next to a normal run."""

    FAILED = {"stage": "failed", "error": "x", "retryable": True}

    def staged(self, hhmm, **state):
        sid = f"2026-10-07_{hhmm}_zoom"
        d = self.session(sid, start=f"2026-10-07T{hhmm[:2]}:{hhmm[2:]}:00+09:00", end=f"2026-10-07T{hhmm[:2]}:59:00+09:00",
                         platform="zoom", label="Zoom", title_hint=None, meeting_url=None)
        write_state(d, **state)
        return d

    def snapshot(self, d):
        return {p.name: (p.read_bytes() if p.is_file() else None) for p in sorted(d.iterdir())}

    def folders(self):
        root = self.cfg.archive_dir
        return sorted(p for m in root.iterdir() if m.is_dir() for p in m.iterdir() if p.is_dir()) if root.exists() else []

    def test_nothing_pending(self):
        code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 0)
        self.assertIn("nothing pending", out)

    def test_the_matrix_every_kind_is_retried_and_everything_else_is_left_alone(self):
        kinds = {"0900": "archive_unavailable", "0910": "asr_failed", "0920": "stalled", "0930": "audio_failed",
                 "0940": "publish_failed", "0950": "internal"}
        retried = {hhmm: self.staged(hhmm, error_kind=kind, **self.FAILED) for hhmm, kind in kinds.items()}
        retried["1000"] = self.staged("1000", error_kind="usage_limit", resets_at="2020-01-01T00:00:00+09:00", **self.FAILED)  # reset passed
        retried["1010"] = self.staged("1010", stage="transcribing", stage_detail="remote 4/8")                                  # died mid-stage
        # a meeting that was published without its note (the tombstone points at it)
        first = pipeline.process_session(self.session("2026-10-07_1020_zoom", start="2026-10-07T10:20:00+09:00", end="2026-10-07T10:59:00+09:00"),
                                         self.cfg, deps=self.deps(StubNote(ok=False, kind="overloaded", error="Claude API overloaded")))
        self.assertEqual(first.error_kind, "overloaded")
        untouched = {
            "usage limit not reset": self.staged("1100", error_kind="usage_limit", resets_at="2099-01-01T00:00:00+09:00", **self.FAILED),
            "not retryable": self.staged("1110", error_kind="asr_failed", **{**self.FAILED, "retryable": False}),
            "done tombstone": self.staged("1120", stage="done"),
        }
        live = make_session(self.cfg, "2026-10-07_1130_zoom", start="2026-10-07T11:30:00+09:00", end=None)    # being recorded right now
        write_state(live, error_kind="asr_failed", **self.FAILED)
        busy = self.staged("1140", error_kind="asr_failed", **self.FAILED)
        before = {name: self.snapshot(d) for name, d in untouched.items()}
        before["live"], before["busy"] = self.snapshot(live), self.snapshot(busy)

        with pipeline.session_lock(self.cfg, "2026-10-07_1140_zoom"):                 # another process is working on this one
            code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 0, out)
        lines = out.strip().splitlines()
        order = [Path(l[len("retrying "):].split(": ")[0]).name for l in lines if l.startswith("retrying ")]
        self.assertEqual(order, sorted(order))                                              # oldest first
        self.assertEqual(len(order), 10)
        self.assertNotIn("2026-10-07_1130_zoom", order)                                     # the live recording is not even listed
        self.assertEqual(lines[-1], "DONE: pending: 10 session(s) found, 9 ok, 0 failed, 1 busy, 0 already handled")
        self.assertIn("stalled", out)
        self.assertIn("interrupted in stage 'transcribing'", out)
        self.assertEqual(len(self.folders()), 9)                                              # all but the busy one are published
        for d in retried.values():
            self.assertEqual(read_state(d)["stage"], "done", d.name)                          # their tombstones say so
        self.assertTrue((first.final_dir / "meeting-note.md").exists())                       # the note was made in place
        self.assertEqual(read_state(self.cfg.sessions_dir / "2026-10-07_1020_zoom")["stage"], "done")
        for name, d in untouched.items():
            self.assertEqual(self.snapshot(d), before[name], name)
        self.assertEqual(self.snapshot(live), before["live"])
        self.assertEqual(self.snapshot(busy), before["busy"])
        self.assertIn("BUSY", out)
        self.assertEqual(self.asr.asr_calls, 9)           # 1 (first run of the note-less meeting) + the 8 staged sessions; the retry of that one needs none

    def test_a_live_recording_is_never_touched_even_when_it_is_listed_as_failed(self):
        live = make_session(self.cfg, "2026-10-07_1130_zoom", start="2026-10-07T11:30:00+09:00", end=None)
        write_state(live, error_kind="asr_failed", **self.FAILED)
        before = self.snapshot(live)
        code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 0)
        self.assertIn("nothing pending", out)
        self.assertEqual(self.snapshot(live), before)
        self.assertEqual(self.asr.asr_calls, 0)
        # and even when a stale listing hands it to the pipeline: SessionBusy, nothing written
        with self.assertRaises(pipeline.SessionBusy):
            pipeline.process_session(live, self.cfg, deps=self.deps(), only_if_pending=True)
        self.assertEqual(self.snapshot(live), before)

    def test_a_session_that_another_run_finished_meanwhile_is_skipped_not_repeated_or_damaged(self):
        d = self.staged("0900", error_kind="archive_unavailable", **self.FAILED)
        real = pipeline.pending_items

        def stale_listing(cfg, *a, **kw):
            items = real(cfg, *a, **kw)
            # a normal run finishes the session between the scan and the retry
            self.assertEqual(pipeline.process_session(d, cfg, deps=self.deps()).stage, "done")
            return items

        with mock.patch("mcap.cli.pipeline.pending_items", stale_listing):
            code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 0, out)
        self.assertIn("SKIPPED", out)
        self.assertIn("1 already handled", out)
        self.assertEqual(self.asr.asr_calls, 1)                                               # transcribed once, by the normal run
        self.assertEqual(read_state(d)["stage"], "done")                                      # the tombstone was not overwritten
        self.assertEqual(len(self.folders()), 1)

    def test_a_failing_retry_is_reported_and_counts_as_an_attempt_and_max_attempts_limits_it(self):
        d = self.staged("0900", error_kind="asr_failed", **self.FAILED)
        self.asr.fail_asr = "model not found"
        code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 1)
        self.assertIn("FAILED: pending: 1 session(s) found, 0 ok, 1 failed, 0 busy, 0 already handled", out)
        self.assertEqual(read_state(d)["attempts"], 1)
        code, out, _err = self.run_cli("reprocess", "--pending", "--max-attempts", "1", deps=self.deps())
        self.assertEqual(code, 0)
        self.assertIn("nothing pending", out)
        self.assertEqual(self.asr.asr_calls, 1)                                               # the second command never started a run
        self.asr.fail_asr = None
        code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())            # no limit by default
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.folders()), 1)

    def test_a_session_that_failed_ten_runs_is_skipped_by_default_and_max_attempts_0_lifts_the_limit(self):
        tired = self.staged("0900", error_kind="asr_failed", attempts=10, **self.FAILED)
        fresh = self.staged("0910", error_kind="asr_failed", attempts=9, **self.FAILED)
        code, out, _err = self.run_cli("reprocess", "--pending", deps=self.deps())
        self.assertEqual(code, 0, out)
        self.assertIn(f"skipping {tired.name}: it already failed 10 or more runs", out)
        self.assertIn("mcap reprocess", out)
        self.assertIn("pending: 1 session(s) found, 1 ok", out)
        self.assertEqual(read_state(fresh)["stage"], "done")
        self.assertEqual(read_state(tired)["stage"], "failed")                                 # untouched
        code, out, _err = self.run_cli("reprocess", "--pending", "--max-attempts", "0", deps=self.deps())
        self.assertEqual(code, 0, out)
        self.assertNotIn("skipping", out)
        self.assertEqual(read_state(tired)["stage"], "done")
        # by hand it always works
        again = self.staged("0920", error_kind="asr_failed", attempts=50, **self.FAILED)
        self.assertEqual(self.run_cli("reprocess", str(again), deps=self.deps())[0], 0)

    def test_the_cli_switches_hf_telemetry_off_for_terminal_runs_too(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("HF_HUB_DISABLE_TELEMETRY", None)
            self.run_cli("usage")
            self.assertEqual(os.environ.get("HF_HUB_DISABLE_TELEMETRY"), "1")
        with mock.patch.dict(os.environ, {"HF_HUB_DISABLE_TELEMETRY": "0"}):
            self.run_cli("usage")
            self.assertEqual(os.environ["HF_HUB_DISABLE_TELEMETRY"], "0")                      # an explicit value is respected

    def test_pending_cannot_be_combined_with_a_folder_or_last(self):
        code, _out, err = self.run_cli("reprocess", "--pending", "--last")
        self.assertEqual(code, 2)
        self.assertIn("--pending cannot be combined", err)


class ApiKeyCommandTests(CliBase):
    """`mcap api-key status|set|check|forget` (SPEC 17), against the fake Keychain and the fake claude. Nothing prints the key."""

    def setUp(self):
        super().setUp()
        self.write_config(CLAUDE_AUTH="api")
        for patcher in (mock.patch.object(usage, "_missing_cost_logged", False),):
            patcher.start()
            self.addCleanup(patcher.stop)

    def outputs(self, *results):
        return tuple(t for r in results for t in r[1:])

    def test_status_of_no_key_a_good_key_and_a_key_that_is_not_one(self):
        code, out, err = self.run_cli("api-key", "status")
        self.assertEqual(code, 1)
        self.assertIn("not available (API key not found in the Keychain: run make set-api-key)", out)
        self.security.store()
        code, out, err = self.run_cli("api-key", "status")
        self.assertEqual(code, 0)
        for needle in ("CLAUDE_AUTH=api: the pipeline uses it", "MeetingCapture Anthropic API key", f"account:   {apikey.keychain_account()}",
                       f"present, {len(CANARY)} characters, starts with sk-ant-", "validated: no", "mcap api-key check"):
            self.assertIn(needle, out)
        self.assertEqual(self.fake.calls(), [])                                            # status makes no claude call
        self.security.store("not-an-anthropic-key-0000")
        code, out, err = self.run_cli("api-key", "status")
        self.assertEqual(code, 1)
        self.assertIn("does NOT start with sk-ant-", out)
        self.assertNotIn("not-an-anthropic-key", out + err)

    def test_status_exists_asks_whether_the_item_is_there_and_never_reads_the_value(self):
        code, out, err = self.run_cli("api-key", "status", "--exists")
        self.assertEqual((code, out.strip()), (1, "No Keychain item for the Anthropic API key."))
        self.security.store()
        code, out, err = self.run_cli("api-key", "status", "--exists")
        self.assertEqual((code, out.strip()), (0, "A Keychain item for the Anthropic API key exists (its value was not read)."))
        self.assertEqual(self.security.reads(), 0)                                         # no find-generic-password ... -w at all
        self.assertTrue(all("-w" not in argv for argv in self.security.argvs()))
        self.security.set_mode("deny")
        code, out, err = self.run_cli("api-key", "status", "--exists")
        self.assertEqual(code, 1)
        self.assertIn("could not be asked", out)
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])
        self.assertEqual(self.fake.calls(), [])                                            # no claude call either

    def test_status_says_so_when_the_pipeline_does_not_use_the_key(self):
        self.write_config(CLAUDE_AUTH="subscription")
        self.security.store()
        code, out, err = self.run_cli("api-key", "status")
        self.assertEqual(code, 0)
        self.assertIn("the pipeline does NOT use it: CLAUDE_AUTH=subscription", out)

    def test_a_misspelt_mode_is_called_invalid_by_status_and_check_not_subscription(self):
        # review finding: `api-key status` / `check` claimed "CLAUDE_AUTH=subscription: the pipeline keeps using the subscription" for a
        # typo, while the pipeline refuses every Claude call until the value is fixed
        self.security.store()
        self.fake.set(cost=0.002)
        self.write_config(CLAUDE_AUTH="apikey")
        code, out, err = self.run_cli("api-key", "status")
        self.assertEqual(code, 0)
        self.assertIn("CLAUDE_AUTH=apikey: invalid value: the pipeline makes no Claude call until CLAUDE_AUTH is 'subscription' or 'api'", out)
        self.assertNotIn("keeps using the subscription", out)
        code, out, err = self.run_cli("api-key", "check")                       # the explicit check still validates the key
        self.assertEqual(code, 0)
        self.assertIn("CLAUDE_AUTH=apikey is not a valid value: the pipeline makes no Claude call until it is 'subscription' or 'api'", out)
        self.assertNotIn("keeps using the subscription", out)
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])

    def test_set_is_refused_without_a_terminal_and_runs_the_exact_command_in_one(self):
        with mock.patch.object(sys, "stdin", io.StringIO()):
            code, out, err = self.run_cli("api-key", "set")
        self.assertEqual(code, 2)
        self.assertIn("must run in a terminal", err)
        self.assertEqual(self.security.calls(), [])
        self.security.store()                                                              # the fake tool "updates" this item
        with mock.patch.object(sys, "stdin", TtyInput()):
            code, out, err = self.run_cli("api-key", "set")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.security.argvs("add-generic-password"),
                         [["add-generic-password", "-U", "-a", apikey.keychain_account(), "-s", "MeetingCapture Anthropic API key", "-w"]])
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])

    def test_check_makes_exactly_one_tiny_call_and_prints_model_source_and_cost(self):
        self.security.store()
        self.fake.set(runs=[{"mode": "success", "note": "OK", "model": "claude-haiku-4-5", "cost": 0.000412}])
        code, out, err = self.run_cli("api-key", "check")
        self.assertEqual(code, 0, err)
        for needle in ("API key OK", "claude-haiku-4-5 (requested: haiku)", "apiKeySource: ANTHROPIC_API_KEY", "cost_usd:     0.000412", "reply:        OK"):
            self.assertIn(needle, out)
        self.assertEqual(len(self.fake.calls()), 1)
        call = self.fake.calls()[0]
        self.assertEqual(call["argv"][call["argv"].index("--model") + 1], "haiku")
        self.assertEqual(call["stdin"], "Reply with exactly: OK")
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])
        self.assertEqual(usage.week_summary(self.cfg)["by_stage"], {"check": 1})

    def test_check_before_the_switch_says_the_pipeline_still_uses_the_subscription(self):
        self.write_config(CLAUDE_AUTH="subscription")
        self.security.store()
        self.fake.set(runs=[{"mode": "success", "note": "OK", "model": "claude-haiku-4-5"}])
        code, out, err = self.run_cli("api-key", "check")
        self.assertEqual(code, 0, err)
        self.assertIn("CLAUDE_AUTH=subscription: the pipeline keeps using the subscription", out)

    def test_check_failures_exit_non_zero_with_a_clear_message_and_never_the_key(self):
        self.security.store()
        for mode, needle in (("api_401", "API key rejected (HTTP 401)"), ("api_credit", "credit"), ("api_429", "key is accepted"),
                             ("fallback_login", "not billed to the API key")):
            self.fake.set(runs=[{"mode": mode, "note": "OK"}], leak_key=True)
            code, out, err = self.run_cli("api-key", "check")
            self.assertEqual(code, 1, mode)
            self.assertIn("FAILED:", err)
            self.assertIn(needle, err, mode)
            self.assertEqual(canary_hits(self.root, extra=(out, err)), [], mode)
        self.security.remove()
        before = len(self.fake.calls())
        code, out, err = self.run_cli("api-key", "check")
        self.assertEqual(code, 1)
        self.assertIn("FAILED: API key not found in the Keychain: run make set-api-key", err)
        self.assertEqual(len(self.fake.calls()), before)                                   # no key: no call

    def test_forget_needs_yes_outside_a_terminal_and_deletes_with_it(self):
        self.security.store()
        with mock.patch.object(sys, "stdin", io.StringIO()):
            code, out, err = self.run_cli("api-key", "forget")
        self.assertEqual(code, 2)
        self.assertIn("--yes", err)
        self.assertEqual(self.security.argvs("delete-generic-password"), [])
        code, out, err = self.run_cli("api-key", "forget", "--yes")
        self.assertEqual(code, 0)
        self.assertIn("Deleted the Keychain item", out)
        self.assertIsNone(apikey.read_key(self.cfg))

    def test_forget_in_a_terminal_asks_first(self):
        self.security.store()
        with mock.patch.object(sys, "stdin", TtyInput()), mock.patch("builtins.input", return_value="n"):
            code, out, err = self.run_cli("api-key", "forget")
        self.assertEqual((code, self.security.argvs("delete-generic-password")), (0, []))
        self.assertIn("cancelled", out)
        with mock.patch.object(sys, "stdin", TtyInput()), mock.patch("builtins.input", return_value="yes"):
            code, out, err = self.run_cli("api-key", "forget")
        self.assertEqual(len(self.security.argvs("delete-generic-password")), 1)

    def test_an_unknown_action_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as cm:
                cli.main(["api-key", "show"])
        self.assertEqual(cm.exception.code, 2)

    def test_nothing_but_check_ever_makes_a_call_to_test_the_key(self):
        self.security.store()
        for argv in (("api-key", "status"), ("usage",), ("doctor", "--no-warmup")):
            self.run_cli(*argv)
        self.assertEqual(self.fake.calls("note") + self.fake.calls("cleanup") + self.fake.calls("verify"), [])


@NEEDS_NUMPY
class DoctorApiTests(CliBase):
    """`mcap doctor` in api mode: key present (prefix), service name, budgets, 'validated: run mcap api-key check', no billing call."""

    def setUp(self):
        super().setUp()
        self.write_config(CLAUDE_AUTH="api")
        self.security.store()

    def doctor(self, **extra):
        if extra:
            self.write_config(**{"CLAUDE_AUTH": "api", **extra})
        code, out, err = self.run_cli("doctor", "--no-warmup")
        return code, out

    def line(self, out, name):
        return next(l for l in out.splitlines() if f"] {name}:" in l)

    def test_a_healthy_api_setup(self):
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        key = self.line(out, "api key")
        self.assertTrue(key.startswith("[PASS]"), key)
        for needle in ("present in the Keychain", "service 'MeetingCapture Anthropic API key'", f"account '{apikey.keychain_account()}'",
                       f"{len(CANARY)} characters", "sk-ant- prefix ok", "validated: no", "run `mcap api-key check`"):
            self.assertIn(needle, key)
        billing = self.line(out, "billing mode")
        self.assertTrue(billing.startswith("[PASS]"))
        self.assertIn("API key (Console credits)", billing)
        self.assertIn("costs money", billing)
        self.assertIn("only the calendar lookup uses the claude.ai login", billing)
        self.assertNotIn("claude login", out)                                              # that is the subscription's line
        self.assertIn("not used in api mode", self.line(out, "overage guard"))
        self.assertNotIn("CANARY", out)

    def test_it_makes_no_billing_call_and_no_claude_login_check_without_the_calendar(self):
        code, out = self.doctor()
        self.assertEqual(self.fake.calls("note") + self.fake.calls("cleanup") + self.fake.calls("verify") + self.fake.calls("calendar"), [])
        self.assertEqual(self.fake.calls("auth"), [])                                      # CALENDAR_LOOKUP=0 (the test default)

    def test_with_the_calendar_on_the_doctor_checks_the_login_it_needs_with_a_local_call_only(self):
        code, out = self.doctor(CALENDAR_LOOKUP="auto")
        self.assertTrue(self.line(out, "calendar login").startswith("[PASS]"), out)
        self.assertEqual(len(self.fake.calls("auth")), 1)
        self.assertEqual(self.fake.calls("note") + self.fake.calls("calendar"), [])
        self.fake.set(auth={"exit": 1, "json": {"loggedIn": False}})
        code, out = self.doctor(CALENDAR_LOOKUP="auto")
        self.assertEqual(code, 0, out)                                                     # only a warning: the lookup is skipped quietly
        warn = self.line(out, "calendar login")
        self.assertTrue(warn.startswith("[WARN]"))
        self.assertIn("skipped quietly", warn)

    def test_no_key_and_a_key_of_the_wrong_shape_fail(self):
        self.security.remove()
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "api key").startswith("[FAIL]"))
        self.assertIn("API key not found in the Keychain: run make set-api-key", self.line(out, "api key"))
        self.security.store("canary_ODD_key_value_9f8e7d6c5b4a")
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertIn("sk-ant-", self.line(out, "api key"))
        self.assertNotIn("canary_ODD", out)

    def test_the_budget_line_shows_today_and_warns_when_the_daily_budget_is_reached(self):
        usage.record(self.cfg, "note", models=["claude-opus-5"], cost_usd=12.5, auth="api")
        code, out = self.doctor(CLAUDE_DAILY_BUDGET_USD="30", CLAUDE_MEETING_BUDGET_USD="15")
        line = self.line(out, "api budget")
        self.assertTrue(line.startswith("[PASS]"), line)
        self.assertIn("$12.50 of the $30.00 daily budget", line)
        self.assertIn("$15.00 per meeting run", line)
        code, out = self.doctor(CLAUDE_DAILY_BUDGET_USD="5", CLAUDE_MEETING_BUDGET_USD="2")      # the shipped budgets: 12.50 is over
        line = self.line(out, "api budget")
        self.assertTrue(line.startswith("[WARN]"), line)
        self.assertIn("$5.00", line)
        self.assertIn("$2.00 per meeting run", line)
        code, out = self.doctor(CLAUDE_DAILY_BUDGET_USD="10")
        line = self.line(out, "api budget")
        self.assertTrue(line.startswith("[WARN]"), line)
        self.assertIn("REACHED", line)
        self.assertEqual(code, 0)

    def test_the_cost_line_has_the_7_and_30_day_sums_by_billing_path(self):
        usage.record(self.cfg, "note", models=["claude-opus-5"], cost_usd=1.25, auth="api")
        usage.record(self.cfg, "cleanup", models=["claude-opus-5"], cost_usd=0.5, auth="subscription")
        code, out = self.doctor()
        line = self.line(out, "claude cost")
        self.assertIn("last 7 days $1.75 (api $1.25, subscription $0.50 equivalent)", line)
        self.assertIn("last 30 days $1.75", line)

    def test_a_misspelt_mode_is_a_fail_and_the_keychain_is_not_touched(self):
        self.security.set_mode("deny")
        code, out = self.doctor(CLAUDE_AUTH="apikey")
        self.assertEqual(code, 1)
        self.assertIn("CLAUDE_AUTH must be", self.line(out, "billing mode"))
        self.assertEqual(self.security.calls(), [])

    def test_subscription_mode_says_so_and_never_reads_the_keychain(self):
        code, out = self.doctor(CLAUDE_AUTH="subscription")
        self.assertEqual(code, 0, out)
        billing = self.line(out, "billing mode")
        self.assertIn("subscription (CLAUDE_AUTH=subscription)", billing)
        self.assertNotIn("API key (Console credits)", billing)
        self.assertEqual(self.security.calls(), [])
        self.assertTrue(self.line(out, "claude login").startswith("[PASS]"))
        self.assertNotIn("api key", out)


class UsageCostCommandTests(CliBase):
    def seed(self):
        now = datetime.now().astimezone()
        for days_ago, stage, auth, cost in ((0, "note", "api", 1.25), (1, "cleanup", "api", 2.0), (3, "note", "subscription", 0.5),
                                            (12, "verify", "api", 4.0), (40, "note", "api", 99.0)):
            path = usage.usage_path(self.cfg)
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"ts": (now - timedelta(days=days_ago)).isoformat(timespec="seconds"), "session_id": "s", "stage": stage,
                                     "models": ["claude-opus-5"], "model": "claude-opus-5", "outcome": "ok", "duration_s": 1.0,
                                     "auth": auth, "cost_usd": cost}) + "\n")

    def test_usage_shows_the_7_and_30_day_costs_by_auth_and_stage(self):
        self.seed()
        code, out, _err = self.run_cli("usage")
        self.assertEqual(code, 0)
        for needle in ("Claude cost in USD", "last  7 days: $3.75", "api $3.25", "subscription $0.50", "last 30 days: $7.75",
                       "cleanup $2.00, note $1.25", "verify $4.00", "billing: CLAUDE_AUTH=subscription"):
            self.assertIn(needle, out)
        self.assertNotIn("api cost today", out)                                           # the budget line is for api mode

    def test_usage_in_api_mode_adds_the_budget_line_and_json_carries_the_windows(self):
        self.write_config(CLAUDE_AUTH="api", CLAUDE_DAILY_BUDGET_USD="30", CLAUDE_MEETING_BUDGET_USD="15")
        self.seed()
        code, out, _err = self.run_cli("usage")
        self.assertIn("api cost today (local date): $1.25 of the $30.00 daily budget", out)
        code, out, _err = self.run_cli("usage", "--json")
        data = json.loads(out)
        self.assertEqual((data["billing"], data["cost_windows"]["7"]["cost_usd"], data["cost_windows"]["30"]["cost_by_auth"]),
                         ("api", 3.75, {"api": 7.25, "subscription": 0.5}))
        self.assertEqual(data["calls"], 3)                                                 # the existing keys are still there

    def test_usage_never_prints_a_key(self):
        usage.record(self.cfg, "note", models=["claude-opus-5"], cost_usd=1.0, outcome="x " + CANARY)
        code, out, err = self.run_cli("usage")
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])


class ApiCliCanaryTests(CliBase):
    """Whole CLI runs in api mode (process / reprocess --pending) with a fake claude that echoes the key everywhere it can: the
    printed lines, the log and the files contain no part of it."""

    def test_printed_lines_logs_and_files_never_hold_the_key(self):
        self.write_config(CLAUDE_AUTH="api", TRANSCRIPT_CLEANUP="1", NOTE_VERIFY="1")
        self.security.store()
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        root = logging.getLogger()
        root.addHandler(handler)
        old = root.level
        self.addCleanup(root.removeHandler, handler)
        self.addCleanup(root.setLevel, old)
        outs = []
        for scenario in ({"runs": [{"mode": "crash"}, {"mode": "crash"}], "cleanup": {"mode": "crash"}, "leak_key": True},
                         {"runs": [{"mode": "api_401"}], "cleanup": {"mode": "api_401"}, "leak_key": True}):
            self.fake.set(**scenario)
            src = self.session("2026-10-07_1400_meet" if not outs else "2026-10-07_1500_meet",
                               start="2026-10-07T14:00:12+09:00" if not outs else "2026-10-07T15:00:12+09:00",
                               end="2026-10-07T14:50:00+09:00" if not outs else "2026-10-07T15:50:00+09:00")
            outs.append(self.run_cli("-v", "process", str(src), deps=self.asr.deps()))
        self.fake.set(runs=[{"mode": "api_credit"}], cleanup={"mode": "api_credit"}, leak_key=True)
        outs.append(self.run_cli("-v", "reprocess", "--pending", "--max-attempts", "0", deps=self.asr.deps()))
        self.assertEqual([o[0] for o in outs[:2]], [1, 1])
        self.assertIn("FAILED: Note failed:", outs[0][1])
        self.assertIn("boom: network unreachable", outs[0][1])                              # the masked stderr tail is in the message
        texts = tuple(t for o in outs for t in o[1:]) + (stream.getvalue(),)
        self.assertEqual(canary_hits(self.root, extra=texts), [])
        self.assertIn("sk-ant-***", "".join(texts))                                         # it did leak into the child's output: masked


class ConfigExampleTests(TempCase):
    SPEC_KEYS = ["ARCHIVE_DIR", "PROJECT_DIR", "PYTHON_BIN", "CLAUDE_BIN", "SELF_NAME", "ENABLED_PLATFORMS", "BROWSER_BUNDLE_IDS",
                 "POLL_INTERVAL_SECONDS", "START_DEBOUNCE_SECONDS", "GRACE_SECONDS", "MIN_RECORDING_SECONDS", "MAX_RECORDING_HOURS",
                 "MIN_FREE_DISK_GB", "SYSTEM_AUDIO_MODE", "ASR_MODEL", "ASR_LANGUAGE", "ASR_VAD", "NOTE_MODEL", "NOTE_FALLBACK_MODEL",
                 "NOTE_EFFORT", "NOTE_LANGUAGE", "NOTE_TIMEOUT_SECONDS", "NOTE_STOP_ON_OVERAGE", "CALENDAR_LOOKUP", "AUDIO_RETENTION_DAYS",
                 # SPEC 15
                 "ASR_LANGUAGES", "MAX_CLAUDE_CALLS_PER_MEETING", "NO_SPEECH_STOP_MINUTES", "RETRY_SWEEP_HOURS"]

    def test_example_has_every_key_and_matches_the_python_defaults(self):
        from mcap.config import Config, load_config, parse_env_text
        example = Path(__file__).resolve().parents[2] / "config" / "config.env.example"
        values = parse_env_text(example.read_text(encoding="utf-8"))
        for key in self.SPEC_KEYS:
            self.assertIn(key, values, key)
        self.assertNotIn("SUPPORT_DIR", values)                     # commented out
        cfg = load_config(example)
        default = Config()
        for field in ("archive_dir", "project_dir", "python_bin", "claude_bin", "self_name", "asr_model", "asr_language", "asr_vad",
                      "note_model", "note_fallback_model", "note_effort", "note_language", "note_timeout_seconds",
                      "audio_retention_days", "note_stop_on_overage", "asr_languages",
                      "max_claude_calls_per_meeting", "transcript_cleanup", "note_verify"):
            self.assertEqual(getattr(cfg, field), getattr(default, field), field)
        self.assertEqual((cfg.calendar_lookup, default.calendar_lookup), ("0", "auto"))   # the example opts out of the calendar lookup; the built-in value is auto
        self.assertEqual(values["ENABLED_PLATFORMS"], "zoom,teams")        # SPEC 15: Google Meet is off by default (add ,meet to enable it)
        self.assertEqual(values["NO_SPEECH_STOP_MINUTES"], "15")
        self.assertEqual(values["RETRY_SWEEP_HOURS"], "6")
        self.assertEqual(values["ARCHIVE_DIR"].split("/")[-1], "Meetings")

    def test_example_has_the_billing_mode_keys_with_the_same_default_as_the_code(self):
        """SPEC 17: the code default and the INSTALLED config.env (a copy of the example) are both api (a Console key); subscription is opt-in."""
        from mcap.config import Config, load_config, parse_env_text
        example = Path(__file__).resolve().parents[2] / "config" / "config.env.example"
        text = example.read_text(encoding="utf-8")
        values = parse_env_text(text)
        for key in ("CLAUDE_AUTH", "CLAUDE_KEY_SERVICE", "CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD"):
            self.assertIn(key, values, key)
        cfg, default = load_config(example), Config()
        self.assertEqual(cfg.claude_auth, "api")
        self.assertEqual(default.claude_auth, "api")
        for field in ("claude_key_service", "claude_daily_budget_usd", "claude_meeting_budget_usd"):
            self.assertEqual(getattr(cfg, field), getattr(default, field), field)
        self.assertEqual((cfg.claude_daily_budget_usd, cfg.claude_meeting_budget_usd), (5.0, 2.0))
        for needle in ("make set-api-key", "mcap api-key check", "mcap usage", "CLAUDE_AUTH=subscription", "calendar", "Console",
                       "spend limit", "bug", "money"):
            self.assertIn(needle, text, needle)
        self.assertNotIn("sk-ant", text)                                       # never a key, not even an example one

    def test_calendar_privacy_note_is_in_the_example(self):
        text = (Path(__file__).resolve().parents[2] / "config" / "config.env.example").read_text(encoding="utf-8")
        for needle in ("CALENDAR_LOOKUP=0", "+-45 minutes", "only the one event that matches"):
            self.assertIn(needle, text)


class ModuleEntryPointTests(CliBase):
    def run_module(self, *args):
        env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "MCAP_CONFIG": os.environ["MCAP_CONFIG"],
               "MCAP_LOG_DIR": os.environ["MCAP_LOG_DIR"], "LANG": "en_US.UTF-8", "HF_HUB_OFFLINE": "1"}
        return subprocess.run([sys.executable, "-m", "mcap", *args], cwd=PIPELINE_DIR, env=env, capture_output=True, text=True, timeout=120)

    def test_version_and_usage_errors(self):
        p = self.run_module("--version")
        self.assertEqual(p.returncode, 0)
        self.assertRegex(p.stdout, r"^mcap \d+\.\d+\.\d+")
        p = self.run_module("process", str(self.root / "missing"))
        self.assertEqual(p.returncode, 2)
        p = self.run_module("nonsense")
        self.assertEqual(p.returncode, 2)

    @NEEDS_NUMPY
    def test_doctor_as_a_module_against_the_fake_claude(self):
        p = self.run_module("doctor", "--no-warmup")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("[PASS] claude login", p.stdout)
        self.assertRegex(p.stdout.strip().splitlines()[-1], r"^doctor: \d+ PASS, \d+ WARN, 0 FAIL$")
        # the child environment of the app (no inherited variables) works as well
        self.assertEqual(len(self.fake.calls("auth")), 1)

    @unittest.skipIf(importlib.util.find_spec("mcap.audioprep") is not None, "real transcription modules exist: never run them on junk audio")
    def test_process_as_a_module_without_transcription_modules_fails_cleanly_and_keeps_audio(self):
        src = self.session()
        p = self.run_module("process", str(src))
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        last = p.stdout.strip().splitlines()[-1]
        self.assertTrue(last.startswith("FAILED: audio:"), last)
        self.assertTrue((src / "mic.wav").exists() and (src / "remote.wav").exists())
        self.assertEqual(read_state(src)["stage"], "failed")


if __name__ == "__main__":
    unittest.main()
