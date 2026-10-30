"""The default path stays byte for byte what it was.

``pipeline/tests/golden/`` holds files that were frozen from the code BEFORE the engine seam was added (``make_golden.py``): the
``asr.transcribe_tracks`` result with a scripted engine (language ID, no language ID, a forced language), the transcript.md of it, the
note footer, and what ``pipeline.process_session`` leaves in the archive (FakeASR, and the real ASR stage with the scripted engine).
These tests regenerate every file from the CURRENT code and compare. A failure here means the output of a personal install changed:
fix the code, or, if the change is intended, regenerate on purpose with ``make_golden.py --write --force`` and say so in the review.
The goldens pin ``ASR_STRATEGY=single`` (``make_golden.golden_config``): the code they were frozen from decodes each chunk once, and that is
what an explicit ``single`` still does. The built-in default is ``dual`` since the bench gate passed (docs/CONFIGURATION.md), so a config
without the key is covered by ``test_asr_dual.py``, not by these files.

Also here: the default path opens no socket and starts no process, gets its engine with the plain ``get_engine(model)`` call, and writes
none of the keys, header lines or progress tags that only an external engine or a restricted meeting produces.
"""
import contextlib
import io
import json
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from golden import make_golden as mg  # noqa: E402
from mcap import asr, transcript as tr  # noqa: E402
from mcap.config import Config  # noqa: E402
from mcap.vocab import parse_vocab_text  # noqa: E402

GOLDEN = Path(mg.__file__).resolve().parent
DEFAULT_KEYS = ["schema", "asr_model", "languages", "segments", "dropped", "dropped_reasons", "echo_suppressed", "echo_suppressed_reasons",
                "aec", "speech_seconds", "missing_tracks", "stats"]


class GoldenFilesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generated = mg.generate()

    def test_every_golden_file_exists_and_is_listed(self):
        self.assertEqual(sorted(self.generated), sorted(mg.GOLDEN_FILES))
        for name in mg.GOLDEN_FILES:
            self.assertTrue((GOLDEN / name).is_file(), f"{name} is missing: it must be frozen from the unmodified code")

    def test_current_output_is_byte_identical_to_the_frozen_files(self):
        for name, text in self.generated.items():
            with self.subTest(name):
                frozen = (GOLDEN / name).read_bytes()
                self.assertEqual(text.encode("utf-8"), frozen, f"{name} differs from the frozen golden file: the default output changed")

    def test_generation_is_deterministic(self):
        again = mg.generate()
        self.assertEqual(again, self.generated)

    def test_make_golden_check_and_the_refusal_to_overwrite(self):
        for name in mg.GOLDEN_FILES:                                                               # a missing file would be WRITTEN by --write below
            self.assertTrue((GOLDEN / name).is_file(), f"{name} is missing")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mg.main(["--check"]), 0)
        self.assertEqual(out.getvalue().split(), ["same"] + [mg.GOLDEN_FILES[0], "same", mg.GOLDEN_FILES[1], "same", mg.GOLDEN_FILES[2],
                                                              "same", mg.GOLDEN_FILES[3]])
        before = {n: (GOLDEN / n).read_bytes() for n in mg.GOLDEN_FILES}
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(mg.main(["--write"]), 2)                                              # never overwrites a frozen file
        self.assertIn("refusing to overwrite", err.getvalue())
        self.assertEqual({n: (GOLDEN / n).read_bytes() for n in mg.GOLDEN_FILES}, before)

    def test_the_fixtures_exercise_the_branches_they_are_meant_to_freeze(self):
        data = json.loads(self.generated["default_transcribe_tracks.json"])
        self.assertEqual(sorted(data), ["forced_ko", "lid_auto", "no_lid_auto"])
        for name, run in data.items():
            stats = run["transcript"]["stats"]
            with self.subTest(name):
                self.assertTrue(run["transcript"]["segments"])
                self.assertGreaterEqual(sum(s["prompt_retries"] for s in stats.values()), 1)       # the prompt retry ran
                self.assertGreaterEqual(sum(s["retries_accepted"] for s in stats.values()), 1)
                self.assertGreaterEqual(sum(s["loops_collapsed"] for s in stats.values()), 1)
                reasons = {r for per_track in run["transcript"]["dropped_reasons"].values() for r in per_track}
                self.assertTrue({"strong_phantom", "no-content"} <= reasons, reasons)
                self.assertGreaterEqual(len(run["engine_calls"]), 7)
        lid = data["lid_auto"]
        self.assertTrue(lid["engine_lid_calls"])
        self.assertEqual(data["no_lid_auto"]["engine_lid_calls"], [])
        self.assertEqual(data["forced_ko"]["engine_lid_calls"], [])
        self.assertTrue(any(s["language_switches"] for s in lid["transcript"]["stats"].values() if "language_switches" in s))
        listing = json.loads(self.generated["default_archive_listing.json"])
        self.assertEqual(sorted(listing), ["fake_asr", "real_asr"])
        for run in listing.values():
            self.assertEqual((run["ok"], run["stage"], run["staging_after"]), (True, "done", ["state.json"]))
            self.assertEqual(run["files"], ["audio.m4a", "meeting-note.md", "mic.m4a", "remote.m4a", "session.json", "transcript.json", "transcript.md"])


class DefaultOutputShapeTest(unittest.TestCase):
    """Nothing that belongs to an external engine or a restricted meeting shows up on the default path."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix="mcap-default-") as tmp:
            cls.baseline = mg.run_transcribe_tracks(Path(tmp), asr_language="auto")

    def test_the_transcript_has_exactly_the_default_keys(self):
        self.assertEqual(list(self.baseline["transcript"]), DEFAULT_KEYS)
        self.assertEqual(self.baseline["transcript"]["asr_model"], Config().asr_model)

    def test_progress_messages_carry_no_tag(self):
        transcribing = [m for m in self.baseline["progress"] if m.startswith("transcribing ")]
        self.assertTrue(transcribing)
        for message in transcribing:
            self.assertRegex(message, r"^transcribing (mic|remote) \d+/\d+$")

    def test_the_header_has_no_route_or_privacy_line(self):
        md = tr.render_markdown(self.baseline["transcript"], dict(mg.META))
        self.assertEqual(md, (GOLDEN / "default_transcript.md").read_text(encoding="utf-8"))
        self.assertNotIn("Route:", md)
        self.assertNotIn("Privacy:", md)

    def test_the_default_run_opens_no_socket_and_starts_no_process(self):
        def forbidden(*args, **kwargs):
            raise AssertionError("the default ASR path must not open a socket or start a process")
        with mock.patch.object(socket.socket, "connect", forbidden), mock.patch.object(socket.socket, "connect_ex", forbidden), \
                mock.patch.object(socket, "create_connection", forbidden), mock.patch.object(socket, "getaddrinfo", forbidden), \
                mock.patch.object(subprocess, "Popen", forbidden):
            with tempfile.TemporaryDirectory(prefix="mcap-default-") as tmp:
                run = mg.run_transcribe_tracks(Path(tmp), asr_language="auto")
        self.assertEqual(run["transcript"], self.baseline["transcript"])

    def test_the_engine_comes_from_a_plain_get_engine_call(self):
        engine = mg.GoldenEngine()
        config = Config()
        self.assertIsNone(getattr(config, "asr_decision", None))                                    # nothing in a default config selects another path
        with mock.patch.object(asr, "get_engine", return_value=engine) as ge:
            self.assertIs(asr._engine_for(config, parse_vocab_text(mg.VOCAB_TEXT)), engine)
        ge.assert_called_once_with(config.asr_model)

    def test_a_default_run_never_touches_the_engine_seam_beyond_the_old_calls(self):
        engine = mg.GoldenEngine()
        seen = []
        for attr in ("provenance", "usage", "prompt_text_seen", "progress_tag"):
            real = getattr(engine, attr)
            setattr(engine, attr, lambda *a, _r=real, _n=attr, **k: seen.append(_n) or _r(*a, **k))
        with tempfile.TemporaryDirectory(prefix="mcap-default-") as tmp:
            cfg = mg.golden_config(Path(tmp), asr_language="auto")
            with mg.fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
                out = asr.transcribe_tracks(mg.prepared_audio(), cfg, parse_vocab_text(mg.VOCAB_TEXT))
        self.assertNotIn("asr", out)
        self.assertNotIn("usage", seen)                                                             # nothing is accounted for a local engine
        self.assertEqual(set(seen) - {"progress_tag", "prompt_text_seen", "provenance"}, set())


if __name__ == "__main__":
    unittest.main()
