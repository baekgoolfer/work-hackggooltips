"""Whole pipeline runs under the lane gates (SPEC 18).

Witnesses: a FAKE `claude` that counts every start (`auth status` included), a FAKE `security` that counts every call, the real ``note``,
``cleanup``, ``verify`` and ``calendar_lookup`` modules (so the gate is exercised where it really sits), a fake ASR, and a recorder in place of
Time Machine. Nothing touches the real SUPPORT_DIR, LOG_DIR, /Library policy, Keychain, claude, Drive or the network.

What is shown
  * the personal default (no policy, flag false): file list, bytes and state keys are what they always were (the frozen goldens too);
  * local_only: zero claude processes (auth status included), zero Keychain reads, the local archive, state `lanes`, the transcript policy
    block and Privacy line, is_complete, state.json kept; the REAL cleanup ThreadPoolExecutor with the flag flipped after the first batch;
    the gate from a bare thread inside a run; two sessions with different flags in one sweep process; session.json unreadable at the gate;
  * the organisation: every lane denial one by one, a missing approval, a missing or mismatching claude pin, a locked policy, a policy file
    replaced during the run by a stricter one;
  * the error kinds: asr_policy_blocked (audio kept, not retryable), asr_unreachable (a waiting kind), local_archive_unsafe (symlink, outside
    SUPPORT_DIR, other device; an NFD spelling is fine), `lane_denied` mapped to a skip in cleanup, note and verify;
  * the drive lane: archive.allowed_roots mismatch, the commit re-check (same volume and cross volume) falling back to the local archive,
    reprocessing a local folder (name, place, file list unchanged, Drive never reached), find_last_session / is_complete / prune;
  * the socket tripwire only when no external engine is used and nothing may be downloaded; a flag switched during an ASR Retry-After sleep.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import errno
import json
import os
import shutil
import sys
import threading
import unicodedata
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from golden import make_golden as mg  # noqa: E402
from mcap import asr_engines, asr_router, cleanup, cli, egress, lanes, note, pipeline, policy, publish, transcript  # noqa: E402
from mcap.asr import AsrUnreachable  # noqa: E402
from mcap.pipeline import Deps  # noqa: E402
from asr_support import (AsrCase, FakeLocalEngine, NOW, chunk_answer, consent_entry, error_answer, json_response,  # noqa: E402
                         fake_registry, result_for, audio, MACHINE)
from notes_cli_support import (FakeASR, FakeClaude, StubCleanup, StubNote, StubVerify, ready_ok, make_cfg, make_session,  # noqa: E402
                               make_stat_fn, sample_note)
from test_lanes import GONE, LaneCase, NOSLEEP, company_doc, set_flag  # noqa: E402

GOLDEN = Path(mg.__file__).resolve().parent
LISTING = ["audio.m4a", "meeting-note.md", "mic.m4a", "remote.m4a", "session.json", "transcript.json", "transcript.md"]


def minute_segments(minutes: int) -> list:
    """One segment per minute (a 4-minute cleanup batch holds 4 of them); the numbers are those of sample_note(), so verify finds them."""
    return [{"start": 60.0 * i + 1, "end": 60.0 * i + 26, "speaker": "Me" if i % 2 == 0 else "Remote", "track": "mic" if i % 2 == 0 else "remote",
             "lang": "en", "text": f"Item {i}: the pilot price is USD 7,500 for three sites and 90 days, the license is USD 2,500 per site per year, "
                                   "and the next sync is Thursday the nineteenth.", "avg_logprob": -0.2, "no_speech_prob": 0.01}
            for i in range(max(minutes, 1))]


def listing(folder: Path) -> list:
    return sorted(p.name for p in Path(folder).iterdir())


class PipeCase(LaneCase):
    """LaneCase plus a fake claude on the config and the real LLM stack: cleanup, note, verify and the calendar all switched on."""

    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.cfg.claude_bin = self.fake.path
        self.cfg.note_timeout_seconds = 60
        self.cfg.transcript_cleanup = True
        self.cfg.note_verify = True
        self.cfg.calendar_lookup = "auto"
        self.cfg.max_claude_calls_per_meeting = 30
        self.note_text = sample_note()
        self.fake.set(runs=[{"mode": "success", "note": self.note_text}], calendar={"mode": "ok", "events": []})
        self.asr = FakeASR(segments=minute_segments(2))
        self.hooks: list = []

    @property
    def local_root(self) -> Path:
        return self.cfg.support_dir / "local-meetings"

    def deps(self, **extra) -> Deps:
        """The ASR of the fake, the REAL transcript renderer (the Privacy line is part of what is checked) and the real LLM stages."""
        parts = dict(prepare_audio=self.asr.prepare_audio, transcribe_tracks=self.asr.transcribe_tracks,
                     render_markdown=transcript.render_markdown)
        parts.update(extra)
        return Deps(**parts)

    def run_pipeline(self, src=None, *, org=None, inputs=None, deps=None, **kw):
        inputs = inputs or self.inputs(org)
        return pipeline.process_session(src or self.src, self.cfg, deps=deps or self.deps(), privacy_inputs=inputs, **kw)

    def state_of(self, folder: Path) -> dict:
        return json.loads((Path(folder) / "state.json").read_text(encoding="utf-8"))

    def claude_kinds(self) -> list:
        return [c["kind"] for c in self.fake.calls()]

    def assert_no_claude_no_keychain(self, what=""):
        self.assertEqual(self.fake.calls(), [], f"{what}: a claude process was started")
        self.assertEqual(self.security.calls(), [], f"{what}: the Keychain tool was started")

    def sha(self, path: Path) -> str:
        import hashlib
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# ---------------------------------------------------------------------------------------------------------------- the default
class PersonalDefaultTests(PipeCase):
    def test_the_frozen_goldens_are_what_the_code_produces_now(self):
        frozen = json.loads((GOLDEN / "default_archive_listing.json").read_text(encoding="utf-8"))
        self.assertEqual(mg.build_archive_listing(), frozen)

    def test_a_default_run_with_the_real_stack_writes_exactly_the_old_files_and_state(self):
        result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)
        final = result.final_dir
        self.assertEqual(final.parent.parent, Path(self.cfg.archive_dir))
        self.assertTrue(set(listing(final)) >= set(LISTING), listing(final))
        self.assertNotIn("state.json", listing(final))                                   # a clean archive folder has no state file
        self.assertFalse(self.local_root.exists())
        tomb = self.state_of(self.src)
        self.assertEqual((tomb["stage"], tomb["error"], tomb["final_dir"]), ("done", None, str(final)))
        self.assertTrue({"local_only", "local_only_source", "lanes", "asr"}.isdisjoint(tomb), sorted(tomb))
        data = json.loads((final / "transcript.json").read_text(encoding="utf-8"))
        self.assertTrue({"policy", "asr"}.isdisjoint(data))
        self.assertNotIn("Privacy:", (final / "transcript.md").read_text(encoding="utf-8"))
        self.assertEqual(self.excluded, [], "the personal default never calls tmutil")
        # and the LLM stack ran: the gate did not close anything by itself
        self.assertEqual(self.claude_kinds(), ["auth", "cleanup", "note", "verify"] if "calendar" not in self.claude_kinds() else self.claude_kinds())
        self.assertEqual(self.security.calls(), [], "subscription mode reads no Keychain item")
        self.assertFalse(egress.Tripwire.active())

    def test_the_default_run_and_a_run_with_a_valid_but_empty_personal_policy_differ_only_by_the_state_keys(self):
        first = self.run_pipeline()
        base_files = listing(first.final_dir)
        base_sha = {n: self.sha(first.final_dir / n) for n in ("transcript.json", "audio.m4a")}
        # a second world, personal policy present (valid, nothing denied)
        other_cfg_root = self.root / "world2"
        other_cfg_root.mkdir()
        self.fake.set(runs=[{"mode": "success", "note": self.note_text}])
        cfg2 = make_cfg(other_cfg_root, self.fake, calendar_lookup="0", transcript_cleanup=False, note_verify=False)
        src2 = make_session(cfg2)
        path = other_cfg_root / "etc" / "policy.json"
        from notes_cli_support import load_test_policy
        org = load_test_policy(path, {"schema": 1, "profile": "personal", "revision": 1})
        cfg2.policy_path = path
        res2 = pipeline.process_session(src2, cfg2, deps=FakeASR().deps(check_ready=ready_ok, generate_note=StubNote()),
                                        privacy_inputs=lanes.PrivacyInputs(policy=org, stat_fn=make_stat_fn(path), sleep=NOSLEEP))
        self.assertTrue(res2.ok, res2.error)
        self.assertTrue(set(listing(res2.final_dir)) <= set(base_files) | {"state.json"})
        self.assertEqual(self.state_of(src2)["lanes"], {"llm": "ok", "calendar": "off", "drive": "ok"})      # the policy is present: the keys say so
        self.assertEqual(base_sha["audio.m4a"], self.sha(first.final_dir / "audio.m4a"))


# ---------------------------------------------------------------------------------------------------------------- local-only
class LocalOnlyRunTests(PipeCase):
    def test_a_local_only_meeting_starts_no_claude_reads_no_keychain_and_lands_in_the_local_archive(self):
        set_flag(self.src, True)
        result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.stage, result.error, result.error_kind), ("done", None, None))
        self.assert_no_claude_no_keychain()
        self.assertEqual(usage_entries(self.cfg), [])
        final = result.final_dir
        self.assertEqual(final, self.local_root / "2026-10" / "2026-10-07_1400_Google-Meet")
        self.assertEqual(listing(final), ["audio.m4a", "mic.m4a", "remote.m4a", "session.json", "state.json", "transcript.json", "transcript.md"])
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists(), "nothing reached the Drive archive")
        self.assertEqual(listing(self.src), ["state.json"])                                # the staging tombstone only
        self.assertEqual(self.state_of(self.src)["final_dir"], str(final))

    def test_the_three_places_that_say_so(self):
        set_flag(self.src, True)
        final = self.run_pipeline().final_dir
        state = self.state_of(final)
        self.assertEqual((state["stage"], state["error"], state["error_kind"]), ("done", None, None))
        self.assertEqual((state["local_only"], state["local_only_source"]), (True, "session"))
        self.assertEqual(state["lanes"], {"llm": "skipped:local_only", "calendar": "skipped:local_only", "drive": "skipped:local_only"})
        self.assertEqual(state["done"], {"audio": True, "asr": True, "note": False, "publish": True})
        self.assertIsNone(state["warning"])                                                # a skip is not a warning
        data = json.loads((final / "transcript.json").read_text(encoding="utf-8"))
        self.assertEqual(data["policy"], {"local_only": True, "lanes": {"llm": "skipped:local_only", "calendar": "skipped:local_only",
                                                                       "drive": "skipped:local_only"}})
        self.assertNotIn("asr", data)
        md = (final / "transcript.md").read_text(encoding="utf-8")
        self.assertIn("Privacy: local-only (note, calendar, Drive skipped)", md.splitlines()[:9])
        self.assertIn("Item 0: the pilot price", md)
        tomb = self.state_of(self.src)
        self.assertEqual((tomb["local_only"], tomb["lanes"]["llm"]), (True, "skipped:local_only"))

    def test_no_note_no_calendar_no_cleaned_transcript_and_the_session_json_is_copied_as_it_was(self):
        set_flag(self.src, True)
        before = (self.src / "session.json").read_bytes()
        final = self.run_pipeline().final_dir
        self.assertFalse((final / "meeting-note.md").exists() or (final / "calendar.json").exists())
        self.assertFalse((final / "transcript.cleaned.md").exists() or (final / "meeting-note.draft.md").exists())
        self.assertEqual((final / "session.json").read_bytes(), before)

    def test_is_complete_find_last_session_and_the_backup_exclusion(self):
        set_flag(self.src, True)
        final = self.run_pipeline().final_dir
        self.assertTrue(pipeline.is_complete(final))
        self.assertEqual(pipeline.find_last_session(self.cfg), final)
        self.assertEqual(self.excluded, [str(self.cfg.sessions_dir), str(self.local_root)])
        self.assertFalse(pipeline.is_complete(self.root / "nowhere"))
        (final / "state.json").write_text(json.dumps({"stage": "failed", "retryable": True}), encoding="utf-8")
        self.assertFalse(pipeline.is_complete(final))
        (final / "state.json").write_text(json.dumps({"stage": "done", "lanes": {"llm": "ok"}}), encoding="utf-8")
        self.assertFalse(pipeline.is_complete(final), "done without a note and without a skipped note lane is not complete")

    def test_the_stage_gate_comes_before_the_collaborators_are_even_asked(self):
        set_flag(self.src, True)
        ready, stub_note, stub_cleanup, stub_verify = mock.Mock(side_effect=ready_ok), StubNote(), StubCleanup(), StubVerify()
        lookup = mock.Mock(return_value=None)
        result = self.run_pipeline(deps=self.deps(check_ready=ready, generate_note=stub_note, cleanup_transcript=stub_cleanup,
                                                  verify_note=stub_verify, lookup_calendar=lookup))
        self.assertTrue(result.ok, result.error)
        self.assertEqual((ready.call_count, len(stub_note.calls), len(stub_cleanup.calls), len(stub_verify.calls), lookup.call_count), (0, 0, 0, 0, 0))

    def test_api_mode_with_a_key_in_the_keychain_reads_nothing(self):
        self.cfg.claude_auth = "api"
        self.security.store()
        set_flag(self.src, True)
        self.assertTrue(self.run_pipeline().ok)
        self.assert_no_claude_no_keychain("api mode")

    def test_a_note_is_still_made_for_a_meeting_that_is_not_local_only(self):
        set_flag(self.src, False)
        result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)
        self.assertTrue((result.final_dir / "meeting-note.md").is_file())
        self.assertIn("note", self.claude_kinds())

    def test_a_locally_finished_meeting_keeps_its_audio_in_the_local_folder_and_stages_nothing_else(self):
        set_flag(self.src, True)
        result = self.run_pipeline()
        self.assertEqual(sorted(p.name for p in Path(self.cfg.sessions_dir).iterdir()), [self.src.name])
        for name in ("audio.m4a", "mic.m4a", "remote.m4a"):
            self.assertGreater((result.final_dir / name).stat().st_size, 0)

    def test_the_fail_closed_flag_values_behave_like_true(self):
        set_flag(self.src, "false")                                                         # a string is not a boolean
        result = self.run_pipeline()
        self.assertTrue(result.ok)
        self.assert_no_claude_no_keychain()
        self.assertEqual(self.state_of(result.final_dir)["local_only_source"], "fail-closed:bad-type")

    def test_the_policy_can_default_the_flag_for_a_session_that_has_none(self):
        set_flag(self.src, GONE)
        org = self.put_policy(company_doc(self.root, local_only={"default": True}))
        result = self.run_pipeline(org=org)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(self.state_of(result.final_dir)["local_only_source"], "default")
        self.assert_no_claude_no_keychain()


def usage_entries(cfg):
    from mcap import usage
    return usage.read_entries(cfg)


# ---------------------------------------------------------------------------------------------------------------- the gate in a real run
class GateInARunTests(PipeCase):
    def test_the_real_cleanup_executor_stops_when_the_flag_is_switched_after_the_first_batch(self):
        self.asr = FakeASR(segments=minute_segments(60))                                    # 15 four-minute batches
        flipped, after = threading.Event(), []
        real = note.run_claude

        def run_then_flip(cfg, prompt, *args, **kwargs):
            was = flipped.is_set()
            out = real(cfg, prompt, *args, **kwargs)
            if was:
                after.append(out.kind)
            if not flipped.is_set():
                set_flag(self.src, True)                                                     # the Swift app: Local-Only Meeting ON
                flipped.set()
            return out

        with mock.patch.object(note, "run_claude", run_then_flip), mock.patch.object(cleanup, "CONCURRENCY", 1):
            result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)
        self.assertEqual(self.claude_kinds(), ["auth", "cleanup"], "the one batch that ran, and nothing after the switch")
        self.assertEqual(after, [])
        state = self.state_of(result.final_dir)
        self.assertEqual(state["lanes"], {"llm": "skipped:local_only", "calendar": "skipped:local_only", "drive": "skipped:local_only"})
        self.assertEqual(result.final_dir.parent.parent, self.local_root, "publishing found the drive lane closed")
        self.assertFalse((result.final_dir / "meeting-note.md").exists())
        self.assertFalse((result.final_dir / "transcript.cleaned.md").exists(), "a cleanup that lost most batches is not applied")
        self.assertIsNone(state["warning"])

    def test_with_the_default_pool_no_process_starts_after_the_switch(self):
        self.asr = FakeASR(segments=minute_segments(60))
        self.fake.set(runs=[{"mode": "success", "note": self.note_text}], delay=0.4)
        flipped, after = threading.Event(), []
        real = note.run_claude

        def run_then_flip(cfg, prompt, *args, **kwargs):
            was = flipped.is_set()
            out = real(cfg, prompt, *args, **kwargs)
            if was:
                after.append(out.kind)
            if not flipped.is_set():
                set_flag(self.src, True)
                flipped.set()
            return out

        with mock.patch.object(note, "run_claude", run_then_flip):
            result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)
        self.assertTrue(flipped.is_set())
        self.assertTrue(all(kind == "lane_denied" for kind in after), after)                # whatever got as far as run_claude was refused there
        self.assertLess(len(self.fake.calls("cleanup")), 15)
        self.assertLessEqual(len(self.fake.calls("cleanup")), cleanup.CONCURRENCY + 1)
        self.assertEqual({c["kind"] for c in self.fake.calls()} - {"auth", "cleanup"}, set(), "no note, no verify, no calendar after the switch")

    def test_the_gate_answers_from_a_bare_thread_inside_the_active_run(self):
        set_flag(self.src, True)
        seen = {}

        def prepare(session_dir, session, force=False):
            thread = threading.Thread(target=lambda: seen.update(llm=lanes.gate("llm"), drive=lanes.gate("drive"), current=lanes.current()))
            thread.start()
            thread.join(10)
            return self.asr.prepare_audio(session_dir, session, force=force)

        self.assertTrue(self.run_pipeline(deps=self.deps(prepare_audio=prepare)).ok)
        self.assertEqual((seen["llm"].reason, seen["drive"].reason), ("local_only", "local_only"))
        self.assertIsNotNone(seen["current"])
        self.assertIsNone(lanes.current(), "and afterwards no run is active")

    def test_two_sessions_with_different_flags_in_one_sweep_process(self):
        a = make_session(self.cfg, "2026-10-07_1000_meet", title_hint=None, start="2026-10-07T10:00:12+09:00", end="2026-10-07T10:50:00+09:00")
        b = make_session(self.cfg, "2026-10-07_1100_meet", title_hint=None, start="2026-10-07T11:00:12+09:00", end="2026-10-07T11:50:00+09:00")
        set_flag(a, True)
        set_flag(b, False)
        shutil.rmtree(self.src)
        for target in (a, b):                                                              # failed + retryable: what a sweep retries
            (target / "state.json").write_text(json.dumps({"stage": "failed", "error": "x", "error_kind": "asr_failed", "retryable": True,
                                                           "attempts": 0}), encoding="utf-8")
        stub_note = StubNote()
        deps = self.deps(check_ready=ready_ok, generate_note=stub_note, cleanup_transcript=StubCleanup(), verify_note=StubVerify())
        cli._sweep(self.cfg, self.root / "nothing", deps, False)
        self.assertEqual(len(stub_note.calls), 1, "a note was made for the session that is not local-only, and only for it")
        self.assertTrue(stub_note.calls[0]["meta"]["time"].startswith("11:00"), stub_note.calls[0]["meta"]["time"])   # the 11:00 session, not the 10:00 one
        locals_ = sorted(p.name for p in (self.local_root / "2026-10").iterdir())
        drive = sorted(p.name for p in (Path(self.cfg.archive_dir) / "2026-10").iterdir())
        self.assertEqual((len(locals_), len(drive)), (1, 1))
        self.assertTrue(locals_[0].startswith("2026-10-07_1000"))
        self.assertTrue(drive[0].startswith("2026-10-07_1100"))
        self.assertEqual(self.state_of(self.local_root / "2026-10" / locals_[0])["local_only"], True)
        self.assertNotIn("state.json", listing(Path(self.cfg.archive_dir) / "2026-10" / drive[0]))
        self.assertIsNone(lanes.current())

    def test_session_json_unreadable_at_the_gate_closes_the_llm_calendar_and_drive_lanes(self):
        real = self.asr.transcribe_tracks

        def transcribe(prepared, cfg, vocab, progress=lambda m: None):
            out = real(prepared, cfg, vocab, progress)
            (self.src / "session.json").write_text("{ broken", encoding="utf-8")            # the ASR is done; from here on the gate cannot read the file
            return out

        result = self.run_pipeline(deps=self.deps(transcribe_tracks=transcribe))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        state = self.state_of(result.final_dir)
        self.assertEqual(state["lanes"], {lane: "skipped:session-unreadable" for lane in ("llm", "calendar", "drive")})
        self.assertEqual(state["local_only_source"], "fail-closed:unreadable")
        self.assertEqual(result.final_dir.parent.parent, self.local_root)

    def test_a_flag_that_arrives_during_the_asr_is_in_the_transcript_policy_block(self):
        real = self.asr.transcribe_tracks

        def transcribe(prepared, cfg, vocab, progress=lambda m: None):
            out = real(prepared, cfg, vocab, progress)
            set_flag(self.src, True)                                                          # the ASR is finished; the block is written right after it
            return out

        result = self.run_pipeline(deps=self.deps(transcribe_tracks=transcribe))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertEqual(json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8"))["policy"]["local_only"], True)

    def test_a_flag_that_arrives_during_the_audio_preparation_reaches_the_asr_config(self):
        seen = []
        real_prepare, real_asr = self.asr.prepare_audio, self.asr.transcribe_tracks

        def prepare(session_dir, session, force=False):
            out = real_prepare(session_dir, session, force=force)
            set_flag(self.src, True)                                                          # after the start of the run, before the ASR stage
            return out

        def transcribe(prepared, cfg, vocab, progress=lambda m: None):
            seen.append(cfg)
            return real_asr(prepared, cfg, vocab, progress)

        result = self.run_pipeline(deps=self.deps(prepare_audio=prepare, transcribe_tracks=transcribe))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(len(seen), 1)
        self.assertIsNot(seen[0], self.cfg)                                                   # not the personal default any more
        self.assertFalse(seen[0].log_content)
        self.assertEqual((seen[0].asr_decision.local_only, seen[0].asr_decision.allow_download), (True, False))
        self.assertEqual(result.final_dir.parent.parent, self.local_root)

    def test_a_flag_that_arrives_after_the_transcript_was_written_leaves_the_transcript_alone_and_the_state_says_what_happened(self):
        from mcap import cleanup as cleanup_mod

        def cleanup_then_flip(transcript_, cfg, vocab, **kw):
            set_flag(self.src, True)                                                          # the transcript files exist; the note stage is next
            return cleanup_mod.CleanupResult(False, stats={"batches": 1}, error_kind="lane_denied", error="lane 'llm' is not allowed: local_only")

        result = self.run_pipeline(deps=self.deps(check_ready=ready_ok, cleanup_transcript=cleanup_then_flip))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertNotIn("policy", json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8")),
                         "written transcripts are never rewritten: the block only says what was known when they were written")
        self.assertNotIn("Privacy:", (result.final_dir / "transcript.md").read_text(encoding="utf-8"))
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["llm"], "skipped:local_only")
        self.assertFalse((result.final_dir / "meeting-note.md").exists())


# ---------------------------------------------------------------------------------------------------------------- the organisation
class OrganisationRunTests(PipeCase):
    def pin(self) -> str:
        import hashlib
        return hashlib.sha256(Path(self.fake.path).resolve().read_bytes()).hexdigest()

    def run_with(self, doc=None, **lane_overrides):
        doc = doc or company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}}, **({"lanes": lane_overrides} if lane_overrides else {}))
        org = self.put_policy(doc)
        return self.run_pipeline(org=org)

    def test_everything_approved_runs_the_whole_stack_and_publishes_to_the_allowed_drive(self):
        result = self.run_with()
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, Path(self.cfg.archive_dir))
        self.assertTrue((result.final_dir / "meeting-note.md").is_file())
        self.assertNotIn("state.json", listing(result.final_dir))                            # nothing was restricted
        self.assertEqual(self.state_of(self.src)["lanes"], {"llm": "ok", "calendar": "ok", "drive": "ok"})
        self.assertNotIn("policy", json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8")))

    def test_the_llm_lane_denied_gives_a_transcript_only_meeting(self):
        result = self.run_with(llm="deny")
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        final = result.final_dir
        self.assertEqual(final.parent.parent, Path(self.cfg.archive_dir))                    # the Drive lane itself is open
        self.assertFalse((final / "meeting-note.md").exists())
        state = self.state_of(final)
        self.assertEqual(state["lanes"]["llm"], "skipped:policy-lane")
        self.assertEqual((state["stage"], state["error"], state["local_only"]), ("done", None, False))
        md = (final / "transcript.md").read_text(encoding="utf-8")
        self.assertIn("Privacy: restricted by organization policy (note skipped)", md)
        self.assertTrue(pipeline.is_complete(final))

    def test_the_calendar_lane_denied_still_makes_the_note_without_a_calendar_call(self):
        result = self.run_with(calendar="deny")
        self.assertTrue(result.ok, result.error)
        kinds = self.claude_kinds()
        self.assertIn("note", kinds)
        self.assertNotIn("calendar", kinds)
        self.assertFalse((result.final_dir / "calendar.json").exists())
        self.assertTrue((result.final_dir / "meeting-note.md").is_file())
        state = self.state_of(result.final_dir)                                              # restricted: the folder keeps its state.json
        self.assertEqual(state["lanes"], {"llm": "ok", "calendar": "skipped:policy-lane", "drive": "ok"})
        self.assertIn("Privacy: restricted by organization policy (calendar skipped)",
                      (result.final_dir / "transcript.md").read_text(encoding="utf-8"))

    def test_the_drive_lane_denied_publishes_to_the_local_archive_with_a_full_note(self):
        result = self.run_with(drive="deny")
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertTrue((result.final_dir / "meeting-note.md").is_file())
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["drive"], "skipped:policy-lane")
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists())

    def test_a_lane_without_an_approval_reference_is_skipped_with_policy_unapproved(self):
        for lane in ("llm", "calendar", "drive"):
            with self.subTest(lane=lane):
                self.setUp()
                doc = company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}})
                doc["approvals"].pop(lane)
                result = self.run_with(doc)
                self.assertTrue(result.ok, result.error)
                self.assertEqual(self.state_of(result.final_dir)["lanes"][lane], "skipped:policy-unapproved")

    def test_a_company_policy_without_a_claude_pin_skips_the_llm_lane(self):
        doc = company_doc(self.root)
        doc["llm"] = {}
        result = self.run_with(doc)
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["llm"], "skipped:policy-claude-unpinned")

    def test_a_pin_that_the_binary_does_not_match_is_a_skip_not_a_failure(self):
        """The lane decision says allow; check_ready finds the binary unpinned and answers lane_denied: mapped to a skip in every stage."""
        result = self.run_with(company_doc(self.root, llm={"claude_bin_pin": {"sha256": "0" * 64}}))
        self.assertTrue(result.ok, result.error)
        self.assertEqual((result.stage, result.error, result.error_kind), ("done", None, None))
        self.assert_no_claude_no_keychain()
        self.assertFalse((result.final_dir / "meeting-note.md").exists())
        state = self.state_of(result.final_dir)                                              # and the folder says why (restricted: state.json is kept)
        self.assertIsNone(state["warning"])
        self.assertEqual(state["lanes"]["llm"], "skipped:policy-claude-unpinned")
        self.assertEqual(self.state_of(self.src)["lanes"]["llm"], "skipped:policy-claude-unpinned")          # the tombstone too

    def test_a_locked_policy_closes_every_lane_and_keeps_the_meeting_local(self):
        org = self.put_policy({"schema": 1, "profile": "company", "revision": 1, "unknown_key": True})
        result = self.run_pipeline(org=org)
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        state = self.state_of(result.final_dir)
        self.assertEqual((state["local_only"], state["local_only_source"]), (True, "policy-lock"))
        self.assertEqual(state["lanes"], {lane: "skipped:policy-locked" for lane in ("llm", "calendar", "drive")})
        self.assertEqual(state["asr"]["reason"], "policy-locked")

    def test_a_policy_file_replaced_during_the_run_by_a_stricter_one_closes_the_lane_for_the_rest_of_it(self):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}}))
        inputs = self.inputs(org)
        real = self.asr.transcribe_tracks

        def transcribe(prepared, cfg, vocab, progress=lambda m: None):
            out = real(prepared, cfg, vocab, progress)
            self.policy_path.write_text(json.dumps(company_doc(self.root, lanes={"llm": "deny"})), encoding="utf-8")
            return out

        result = self.run_pipeline(inputs=inputs, deps=self.deps(transcribe_tracks=transcribe))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["llm"], "skipped:policy-lane")
        self.assertEqual(result.final_dir.parent.parent, Path(self.cfg.archive_dir), "the Drive lane is still open")

    def test_a_policy_file_that_becomes_invalid_during_the_run_locks_it_and_the_meeting_goes_local(self):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}}))
        inputs = self.inputs(org)
        real = self.asr.transcribe_tracks

        def transcribe(prepared, cfg, vocab, progress=lambda m: None):
            out = real(prepared, cfg, vocab, progress)
            self.policy_path.write_text("garbage", encoding="utf-8")
            return out

        result = self.run_pipeline(inputs=inputs, deps=self.deps(transcribe_tracks=transcribe))
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["drive"], "skipped:policy-locked")

    def test_archive_roots_that_do_not_match_the_archive_dir_send_the_meeting_to_the_local_archive(self):
        doc = company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}}, archive={"allowed_roots": [str(self.root / "Team Drive")]})
        result = self.run_with(doc)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["drive"], "skipped:policy-archive-root")
        self.assertTrue((result.final_dir / "meeting-note.md").is_file(), "the note lane is open: the note is made and stays local")

    def test_an_archive_dir_that_the_user_never_set_closes_the_drive_lane_in_the_company_profile(self):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin()}}))
        self.cfg.explicit_keys = frozenset()
        result = self.run_pipeline(org=org)
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["drive"], "skipped:archive-not-configured")
        self.assertEqual(result.final_dir.parent.parent, self.local_root)


# ---------------------------------------------------------------------------------------------------------------- error kinds
class ErrorKindTests(PipeCase):
    def blocked_inputs(self) -> lanes.PrivacyInputs:
        self.cfg.asr_engine, self.cfg.asr_remote_url = "remote", "https://asr.example.internal"
        return lanes.PrivacyInputs(hw=SimpleNamespace(capable=False), consents=policy.ConsentSet(machine=MACHINE), now=NOW, sleep=NOSLEEP)

    def test_asr_policy_blocked_keeps_the_audio_is_not_retryable_and_never_calls_the_asr(self):
        set_flag(self.src, True)
        result = self.run_pipeline(inputs=self.blocked_inputs())
        self.assertFalse(result.ok)
        self.assertEqual((result.stage, result.error_kind, result.retryable), ("failed", "asr_policy_blocked", False))
        self.assertEqual(self.asr.asr_calls, 0)
        state = self.state_of(self.src)
        self.assertEqual((state["stage"], state["error_kind"], state["retryable"], state["attempts"]), ("failed", "asr_policy_blocked", False, 1))
        self.assertIn("audio is kept", state["error"])
        self.assertTrue((self.src / "mic.wav").exists() and (self.src / "remote.wav").exists())
        self.assertFalse((self.src / "transcript.json").exists())
        self.assertEqual(pipeline.pending_reason(self.cfg, state), None, "no automatic retry")
        self.assertEqual(pipeline.find_pending_sessions(self.cfg), [])
        self.assertEqual((state["local_only"], state["lanes"]["llm"]), (True, "skipped:local_only"))
        self.assert_no_claude_no_keychain()
        self.assertFalse(self.local_root.exists() and any(self.local_root.iterdir()))

    def test_asr_policy_blocked_can_still_be_run_by_hand_when_the_condition_is_gone(self):
        set_flag(self.src, True)
        self.run_pipeline(inputs=self.blocked_inputs())
        self.cfg.asr_engine = "whisper"                                                       # an explicit local engine is never blocked
        result = self.run_pipeline()
        self.assertTrue(result.ok, result.error)

    def test_asr_unreachable_is_a_retryable_waiting_kind_that_is_not_a_failed_attempt(self):
        self.assertIn("asr_unreachable", pipeline.WAITING_KINDS)
        calls = []

        def unreachable(prepared, cfg, vocab, progress=lambda m: None):
            calls.append(1)
            raise AsrUnreachable("ASR unreachable: every chunk of the mic track failed to reach the engine")

        for run in range(3):
            result = self.run_pipeline(deps=self.deps(transcribe_tracks=unreachable))
            self.assertEqual((result.ok, result.error_kind, result.retryable), (False, "asr_unreachable", True), run)
            state = self.state_of(self.src)
            self.assertEqual((state["attempts"], state["stage"]), (0, "failed"), "a waiting kind does not count as a failed attempt")
        self.assertIn("unreachable", result.error)
        self.assertEqual(pipeline.pending_reason(self.cfg, state), "failed earlier (asr_unreachable)")
        self.assertEqual(pipeline.find_pending_sessions(self.cfg, max_attempts=pipeline.MAX_AUTO_ATTEMPTS), [self.src])
        self.assertTrue((self.src / "mic.wav").exists(), "the audio stays")
        later = self.run_pipeline()
        self.assertTrue(later.ok, later.error)

    def test_another_asr_error_is_still_asr_failed_and_counts(self):
        def broken(prepared, cfg, vocab, progress=lambda m: None):
            raise RuntimeError("model exploded")
        result = self.run_pipeline(deps=self.deps(transcribe_tracks=broken))
        self.assertEqual((result.error_kind, result.retryable), ("asr_failed", True))
        self.assertEqual(self.state_of(self.src)["attempts"], 1)

    def test_lane_denied_results_are_a_skip_in_cleanup_note_and_verify(self):
        denied = note.CallResult(False, error_kind="lane_denied", error="lane 'llm' is not allowed: local_only")
        from mcap import cleanup as cleanup_mod, verify as verify_mod
        cleanup_stub = mock.Mock(return_value=cleanup_mod.CleanupResult(False, stats={"batches": 1}, error_kind="lane_denied", error=denied.error))
        note_stub = mock.Mock(return_value=note.NoteResult(False, error_kind="lane_denied", error=denied.error))
        deps = self.deps(check_ready=ready_ok, cleanup_transcript=cleanup_stub, generate_note=note_stub, verify_note=mock.Mock())
        result = self.run_pipeline(deps=deps)
        self.assertTrue(result.ok, result.error)
        self.assertEqual((cleanup_stub.call_count, note_stub.call_count), (1, 1))
        state = self.state_of(self.src)
        self.assertEqual((state["stage"], state["error"], state["warning"]), ("done", None, None))
        self.assertFalse((result.final_dir / "meeting-note.md").exists())
        self.assertFalse((result.final_dir / "transcript.cleaned.md").exists())
        self.assertIsNone(result.warning)

    def test_a_readiness_that_says_lane_denied_is_a_skip_for_cleanup_and_note_and_verify(self):
        lane_closed = lambda cfg, allow_overage=False: note.Readiness(False, "lane_denied", "lane 'llm' is not allowed: policy-claude-unpinned", False)
        result = self.run_pipeline(deps=self.deps(check_ready=lane_closed))
        self.assertTrue(result.ok, result.error)
        state = self.state_of(self.src)
        self.assertEqual((state["stage"], state["warning"], state["error_kind"]), ("done", None, None))

    def test_a_verification_that_loses_the_lane_leaves_the_note_marked_and_without_a_warning(self):
        from mcap import verify as verify_mod
        verify_stub = mock.Mock(return_value=verify_mod.VerifyResult(False, error_kind="lane_denied", error="lane 'llm' is not allowed: local_only"))
        result = self.run_pipeline(deps=self.deps(check_ready=ready_ok, generate_note=StubNote(), verify_note=verify_stub))
        self.assertTrue(result.ok, result.error)
        text = (result.final_dir / "meeting-note.md").read_text(encoding="utf-8")
        self.assertIn("Verification: not applied", text)
        self.assertIsNone(self.state_of(self.src)["warning"])

    def test_verification_of_an_existing_note_under_a_closed_lane_marks_it_and_calls_nothing(self):
        first = self.run_pipeline(deps=self.deps(check_ready=ready_ok, generate_note=StubNote()))
        self.assertTrue(first.ok)
        folder = first.final_dir
        (folder / "meeting-note.md").write_text(sample_note(), encoding="utf-8")            # a note without verification, as an older run left it
        set_flag(folder, True)
        verify_stub = mock.Mock()
        result = pipeline.process_session(folder, self.cfg, from_stage="verify", deps=self.deps(check_ready=ready_ok, verify_note=verify_stub),
                                          privacy_inputs=self.inputs())
        self.assertTrue(result.ok, result.error)
        verify_stub.assert_not_called()
        self.assertIn("Verification: not applied (llm lane closed: local_only)", (folder / "meeting-note.md").read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------------------------------------------- the local archive
class LocalArchiveRunTests(PipeCase):
    def run_local(self):
        set_flag(self.src, True)
        return self.run_pipeline()

    def assert_unsafe(self, result):
        self.assertFalse(result.ok)
        self.assertEqual((result.stage, result.error_kind, result.retryable), ("failed", "local_archive_unsafe", False))
        state = self.state_of(self.src)
        self.assertEqual((state["stage"], state["error_kind"], state["retryable"]), ("failed", "local_archive_unsafe", False))
        self.assertTrue((self.src / "transcript.json").exists() and (self.src / "mic.m4a").exists(), "audio and transcript stay in staging")
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists(), "nothing reached Drive")
        self.assertEqual(pipeline.find_pending_sessions(self.cfg), [], "never retried by itself")
        self.assert_no_claude_no_keychain()

    def test_a_local_archive_dir_outside_support_dir_is_unsafe(self):
        self.cfg.local_archive_dir = self.root / "elsewhere" / "meetings"
        self.assert_unsafe(self.run_local())

    def test_a_symlink_in_the_local_archive_dir_is_unsafe(self):
        elsewhere = self.root / "target"
        elsewhere.mkdir()
        link = self.cfg.support_dir / "sneaky"
        link.symlink_to(elsewhere)
        self.cfg.local_archive_dir = link
        self.assert_unsafe(self.run_local())
        self.assertEqual(list(elsewhere.iterdir()), [], "nothing was written through the link")

    def test_a_local_archive_dir_on_another_device_is_unsafe(self):
        real = os.stat

        def other_device(path, *args, **kwargs):
            st = real(path, *args, **kwargs)
            return SimpleNamespace(st_dev=st.st_dev + 1) if str(path).startswith(str(Path(self.cfg.support_dir).resolve())) else st

        with mock.patch.dict(policy.local_archive_ok.__kwdefaults__, {"stat_fn": other_device}):
            self.assert_unsafe(self.run_local())

    def test_an_nfd_spelling_inside_support_dir_is_accepted(self):
        name = "회의-로컬"
        self.cfg.local_archive_dir = self.cfg.support_dir / unicodedata.normalize("NFD", name)
        result = self.run_local()
        self.assertTrue(result.ok, result.error)
        self.assertTrue((self.cfg.support_dir / unicodedata.normalize("NFC", name) / "2026-10").is_dir())
        self.assertTrue((result.final_dir / "transcript.json").is_file())

    def test_an_explicitly_set_local_archive_dir_under_support_dir_is_used(self):
        self.cfg.local_archive_dir = self.cfg.support_dir / "my local meetings"
        result = self.run_local()
        self.assertEqual(result.final_dir.parent.parent, self.cfg.local_archive_dir)
        self.assertEqual(self.excluded, [str(self.cfg.sessions_dir), str(self.cfg.local_archive_dir)])


class ReprocessLocalFolderTests(PipeCase):
    def setUp(self):
        super().setUp()
        set_flag(self.src, True)
        self.first = self.run_pipeline()
        self.folder = self.first.final_dir
        self.before = (listing(self.folder), self.folder.name, self.folder.parent)

    def assert_unchanged(self, result):
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir, self.folder)
        self.assertEqual((listing(result.final_dir), result.final_dir.name, result.final_dir.parent), self.before)
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists(), "Drive was never reached")
        self.assertEqual([p.name for p in (self.local_root / "2026-10").iterdir()], [self.folder.name], "no second folder")
        self.assert_no_claude_no_keychain()

    def test_a_plain_reprocess_leaves_name_place_and_file_list_alone(self):
        self.assert_unchanged(self.run_pipeline(self.folder))

    def test_reprocess_from_the_note_stage_stays_in_place_and_does_not_start_claude(self):
        self.assert_unchanged(self.run_pipeline(self.folder, from_stage="note"))

    def test_a_forced_reprocess_regenerates_the_transcript_in_place(self):
        before = self.sha(self.folder / "transcript.json")
        result = self.run_pipeline(self.folder, force=True)
        self.assert_unchanged(result)
        self.assertEqual(self.sha(self.folder / "transcript.json"), before, "the same fake ASR gives the same transcript")
        self.assertIn("Privacy: local-only", (self.folder / "transcript.md").read_text(encoding="utf-8"))
        self.assertTrue(self.state_of(self.folder)["local_only"])

    def test_the_tombstone_in_staging_is_refreshed_not_recreated_elsewhere(self):
        self.run_pipeline(self.folder)
        self.assertEqual(self.state_of(self.src)["final_dir"], str(self.folder))

    def test_find_last_session_prefers_the_newest_of_both_archives(self):
        shutil.rmtree(self.cfg.sessions_dir)                                                  # no staging tombstone: only the scan of the archive roots can find it
        older_drive = Path(self.cfg.archive_dir) / "2026-09" / "2026-09-30_1000_old-drive"
        older_drive.mkdir(parents=True)
        (older_drive / "session.json").write_text("{}", encoding="utf-8")
        self.assertEqual(pipeline.find_last_session(self.cfg), self.folder)
        newer_drive = Path(self.cfg.archive_dir) / "2026-10" / "2026-10-20_1000_newer-drive"
        newer_drive.mkdir(parents=True)
        (newer_drive / "session.json").write_text("{}", encoding="utf-8")
        self.assertEqual(pipeline.find_last_session(self.cfg), newer_drive)

    def test_find_last_session_sees_the_local_root_when_the_tombstone_is_gone(self):
        """``mcap reprocess --last`` after the 7-day tombstone in staging was pruned: the local folder is found by scanning LOCAL_ARCHIVE_DIR."""
        shutil.rmtree(self.cfg.sessions_dir)
        self.assertFalse(Path(self.cfg.archive_dir, "2026-10").exists(), "Drive has nothing")
        self.assertEqual(pipeline.find_last_session(self.cfg), self.folder)
        self.assertEqual(self.folder.parent.parent, self.local_root)

    def test_find_last_session_without_a_local_archive_is_the_old_behaviour(self):
        shutil.rmtree(self.local_root)
        shutil.rmtree(self.cfg.sessions_dir)
        self.assertIsNone(pipeline.find_last_session(self.cfg))

    def test_prune_audio_sees_the_local_root(self):
        self.cfg.local_archive_retention_days = 1
        report = publish.prune_audio(self.cfg, now=__import__("time").time() + 40 * 86400)
        self.assertEqual(sorted(p.name for p in report.audio), ["audio.m4a", "mic.m4a", "remote.m4a"])
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["session.json", "state.json", "transcript.json", "transcript.md"])


# ---------------------------------------------------------------------------------------------------------------- the commit re-check
class DriveCommitTests(PipeCase):
    def test_a_flag_switched_between_the_lane_check_and_the_move_sends_the_meeting_to_the_local_archive(self):
        real = publish.archive_status

        def flip_then_status(cfg, archive_dir=None):
            set_flag(self.src, True)                                                          # after publish's first look, before the move
            return real(cfg, archive_dir)

        with mock.patch.object(publish, "archive_status", flip_then_status):
            result = self.run_pipeline(deps=self.deps(check_ready=ready_ok, generate_note=StubNote()))
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["drive"], "skipped:local_only")
        drive = Path(self.cfg.archive_dir)
        self.assertEqual([p.name for p in drive.rglob("*") if p.name.startswith("2026") or p.name.startswith(".")], [],
                         "nothing, not even a month folder or a partial copy, is left in the synced folder")

    def test_a_flag_switched_during_a_cross_volume_copy_removes_the_partial_copy_and_publishes_locally(self):
        real_rename, staging = os.rename, self.src

        def exdev(src, dst, *args, **kwargs):
            if Path(src) == staging:
                raise OSError(errno.EXDEV, "cross-device")
            return real_rename(src, dst, *args, **kwargs)

        real_verify = publish._verify_copy

        def verify_then_flip(src, dst):
            real_verify(src, dst)
            if Path(dst).name.startswith(".") and Path(dst).parent.parent == Path(self.cfg.archive_dir):
                set_flag(self.src, True)                                                      # the copy is complete, the rename is next

        with mock.patch("mcap.publish.os.rename", side_effect=exdev), mock.patch.object(publish, "_verify_copy", verify_then_flip):
            result = self.run_pipeline(deps=self.deps(check_ready=ready_ok, generate_note=StubNote()))
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, self.local_root)
        month = Path(self.cfg.archive_dir) / "2026-10"
        self.assertEqual([p.name for p in month.iterdir()] if month.exists() else [], [], "the hidden .partial copy is gone")
        self.assertTrue((result.final_dir / "audio.m4a").is_file())
        self.assertFalse(self.src.exists() and (self.src / "audio.m4a").exists(), "the staging folder moved to the local archive")

    def test_without_a_switch_the_same_cross_volume_copy_publishes_to_drive(self):
        real_rename, staging = os.rename, self.src

        def exdev(src, dst, *args, **kwargs):
            if Path(src) == staging:
                raise OSError(errno.EXDEV, "cross-device")
            return real_rename(src, dst, *args, **kwargs)

        with mock.patch("mcap.publish.os.rename", side_effect=exdev):
            result = self.run_pipeline(deps=self.deps(check_ready=ready_ok, generate_note=StubNote()))
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.final_dir.parent.parent, Path(self.cfg.archive_dir))
        self.assertFalse(self.local_root.exists())


# ---------------------------------------------------------------------------------------------------------------- the sweep and pending
class PendingTests(PipeCase):
    def test_local_only_sessions_that_failed_retryably_are_retried_locally_without_claude(self):
        set_flag(self.src, True)
        (self.src / "state.json").write_text(json.dumps({"stage": "failed", "error": "x", "error_kind": "archive_unavailable", "retryable": True,
                                                         "attempts": 1}), encoding="utf-8")
        self.assertEqual(pipeline.find_pending_sessions(self.cfg), [self.src])
        result = pipeline.process_session(self.src, self.cfg, deps=self.deps(), only_if_pending=True, privacy_inputs=self.inputs())
        self.assertTrue(result.ok, result.error)
        self.assert_no_claude_no_keychain()
        self.assertEqual(result.final_dir.parent.parent, self.local_root)


# ---------------------------------------------------------------------------------------------------------------- the tripwire
class TripwireInARunTests(PipeCase):
    """The socket tripwire exists only for a run that uses no external engine AND may download nothing."""

    def observe(self, **inputs_kw) -> object:
        seen = []
        real = self.asr.prepare_audio

        def prepare(session_dir, session, force=False):
            seen.append(egress.Tripwire.effective_mode())
            return real(session_dir, session, force=force)

        result = self.run_pipeline(deps=self.deps(prepare_audio=prepare), **({"inputs": lanes.PrivacyInputs(sleep=NOSLEEP, **inputs_kw)} if inputs_kw else {}))
        self.assertTrue(result.ok, result.error)
        self.assertFalse(egress.Tripwire.active(), "the tripwire is gone after the run")
        return seen[0]

    def setUp(self):
        super().setUp()
        self.addCleanup(egress.Tripwire.uninstall_all)

    def test_the_personal_default_has_no_tripwire(self):
        self.assertIsNone(self.observe())

    def test_a_local_only_run_is_strict(self):
        set_flag(self.src, True)
        self.assertEqual(self.observe(), "strict")

    def test_a_run_that_may_not_download_is_strict_even_when_the_flag_is_off(self):
        self.cfg.asr_allow_download = False                                                    # what the company baseline (enforced) says
        self.assertEqual(self.observe(), "strict")

    def test_a_run_with_an_external_engine_gets_the_audit_tripwire_only(self):
        self.cfg.asr_engine, self.cfg.asr_remote_url = "remote", "https://asr.example.internal"
        consents = policy.ConsentSet(entries=(consent_entry("remote"),), machine=MACHINE)
        self.assertEqual(self.observe(consents=consents, hw=SimpleNamespace(capable=True), now=NOW), "audit")

    def test_a_local_only_run_with_an_external_engine_configured_is_strict_again(self):
        self.cfg.asr_engine, self.cfg.asr_remote_url = "remote", "https://asr.example.internal"
        consents = policy.ConsentSet(entries=(consent_entry("remote"),), machine=MACHINE)
        set_flag(self.src, True)
        self.assertEqual(self.observe(consents=consents, hw=SimpleNamespace(capable=True), now=NOW), "strict")

    def test_a_tripwire_is_not_left_behind_when_the_run_fails(self):
        set_flag(self.src, True)

        def broken(prepared, cfg, vocab, progress=lambda m: None):
            raise RuntimeError("boom")

        result = self.run_pipeline(deps=self.deps(transcribe_tracks=broken))
        self.assertFalse(result.ok)
        self.assertFalse(egress.Tripwire.active())
        self.assertIsNone(lanes.current())


# ---------------------------------------------------------------------------------------------------------------- ASR Retry-After
class RetryAfterToggleTests(AsrCase):
    """A meeting becomes local-only while an external ASR engine sleeps for Retry-After: no request is made after the sleep, the chunk and
    the rest of the meeting are transcribed by the local fallback, and the meeting says so."""

    def setUp(self):
        super().setUp()
        self.excluded = []
        patcher = mock.patch.object(publish, "exclude_from_backup", side_effect=lambda path, **kw: self.excluded.append(str(path)) or True)
        patcher.start()
        self.addCleanup(patcher.stop)
        registry = fake_registry()
        registry.start()
        self.addCleanup(registry.stop)
        self.local = FakeLocalEngine([result_for("local text", duration=15.0)])
        patcher = mock.patch.object(asr_engines, "get_engine", return_value=self.local)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cfg.calendar_lookup = "0"
        self.cfg.transcript_cleanup = False
        self.cfg.note_verify = False
        self.cfg.asr_engine, self.cfg.asr_fallback = "remote", "whisper"
        self.src = make_session(self.cfg)
        self.transport.default = json_response(200, chunk_answer("remote text", duration=15.0))
        self.engine = None

    def transcribe(self, prepared, cfg, vocab, progress=lambda m: None):
        engine = asr_router.build_engine(cfg, vocab, transport_factory=lambda: self.transport, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock)
        self.engine = engine
        engine.load()
        segments = []
        for index in range(3):
            result = engine.transcribe_chunk(audio(15.0), "en", None)
            for seg in result["segments"]:
                segments.append({"start": index * 20.0 + seg["start"], "end": index * 20.0 + seg["end"], "speaker": "Me", "track": "mic", "lang": "en",
                                 "text": seg["text"], "avg_logprob": None, "no_speech_prob": None})
        return {"schema": 1, "asr_model": "fake", "languages": {"mic": "en", "remote": "en"}, "dropped": 0, "segments": segments,
                "asr": engine.provenance()}

    def run_once(self, **kw):
        asr_fake = FakeASR()
        deps = Deps(prepare_audio=asr_fake.prepare_audio, transcribe_tracks=self.transcribe, render_markdown=transcript.render_markdown,
                    check_ready=ready_ok, generate_note=StubNote())
        inputs = lanes.PrivacyInputs(consents=policy.ConsentSet(entries=(consent_entry("remote"),), machine=MACHINE),
                                     hw=SimpleNamespace(capable=True), now=NOW, sleep=NOSLEEP)
        return pipeline.process_session(self.src, self.cfg, deps=deps, privacy_inputs=inputs, **kw)

    def test_the_flag_switched_during_the_sleep_stops_the_requests_and_the_meeting_finishes_locally(self):
        self.transport.script = [error_answer(503, "busy", retry_after=30)]
        self.sleep.on_sleep = lambda seconds: set_flag(self.src, True)
        result = self.run_once()
        self.assertTrue(result.ok, result.error)
        self.assertEqual(len(self.transport.calls), 1, "the first attempt only: nothing is sent after the sleep")
        self.assertEqual(self.sleep.waits, [30.0])
        self.assertTrue(self.engine.breaker.permanent)
        data = json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8"))
        self.assertEqual([s["text"] for s in data["segments"]], ["local text"] * 3)
        self.assertEqual(data["asr"]["engine"], "remote")
        self.assertEqual(data["asr"]["fallbacks"], 3)
        self.assertEqual(data["policy"]["local_only"], True)
        self.assertIn("Privacy: local-only", (result.final_dir / "transcript.md").read_text(encoding="utf-8"))
        self.assertEqual(result.final_dir.parent.parent, self.cfg.support_dir / "local-meetings")
        self.assertEqual(self.state_of(result.final_dir)["lanes"]["llm"], "skipped:local_only")
        lines = [json.loads(x) for x in self.cfg.asr_usage_path.read_text().splitlines()]
        self.assertEqual([x["outcome"] for x in lines], ["http_503", "denied:gate"])
        self.assertEqual(self.security.reads(), 1, "the relay token was read once, before the first attempt, and never again")

    def state_of(self, folder):
        return json.loads((Path(folder) / "state.json").read_text(encoding="utf-8"))

    def test_without_the_switch_the_relay_answers_every_chunk(self):
        result = self.run_once()
        self.assertTrue(result.ok, result.error)
        self.assertEqual(len(self.transport.calls), 3)
        data = json.loads((result.final_dir / "transcript.json").read_text(encoding="utf-8"))
        self.assertEqual({s["text"] for s in data["segments"]}, {"remote text"})
        self.assertNotIn("policy", data)


if __name__ == "__main__":
    unittest.main()
