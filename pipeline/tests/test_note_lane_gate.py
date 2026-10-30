"""The lane gate in the functions that start a `claude` process or read the Keychain (SPEC 18): ``note.check_ready / preflight / run_claude / call_claude / generate_note``, ``calendar_lookup.fetch_events /
lookup_calendar`` and the signature pin ``note.verify_claude_bin``.

The claim under test: while a pipeline run is active and a lane is closed (local-only, the organisation, an unreadable session.json) these
functions start NO process (not even `claude auth status`), read NO Keychain item, count NO budget and write NO usage line; with the lane
open (or no run active: an explicit command) they behave exactly as before. A FAKE `claude` that counts its starts and a FAKE `security`
that counts its calls are the witnesses; nothing here touches the real Keychain, the real claude, the network or /usr/bin/codesign.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import test_note  # noqa: E402  (the calendar event builder and SESSION; the module, so its tests are not collected twice)
from mcap import calendar_lookup, lanes, note, policy, usage  # noqa: E402
from notes_cli_support import FakeClaude, real_env_keys  # noqa: E402
from test_lanes import LaneCase, NOSLEEP, company_doc, set_flag  # noqa: E402

SESSION = test_note.SESSION
TRANSCRIPT = test_note.TRANSCRIPT
ALLOW_ENV = {"HOME", "USER", "PATH", "LANG"}


class GateCase(LaneCase):
    """LaneCase plus a fake claude wired into the config; ``run(priv)`` makes ``priv`` the active run for the rest of the test."""

    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.cfg.claude_bin = self.fake.path
        self.cfg.note_timeout_seconds = 60
        self.event = test_note.CalendarPureTests().ev()
        self.fake.set(calendar={"mode": "ok", "events": [self.event]})

    def run_scope(self, priv) -> None:
        scope = lanes.run_scope(priv)
        scope.__enter__()
        self.addCleanup(scope.__exit__, None, None, None)

    def start_run(self, flag=None, org=None) -> lanes.RunPrivacy:
        if flag is not None:
            set_flag(self.src, flag)
        priv = self.resolve(org)
        self.run_scope(priv)
        return priv

    def assert_nothing_started(self, what: str = "") -> None:
        self.assertEqual(self.fake.calls(), [], f"{what}: a claude process was started")
        self.assertEqual(self.security.calls(), [], f"{what}: the Keychain tool was started")
        self.assertEqual(usage.read_entries(self.cfg), [], f"{what}: a usage line was written")


class LocalOnlyGateTests(GateCase):
    """local_only closes the llm and calendar lanes at every leaf, in both billing modes."""

    def modes(self):
        for mode in ("subscription", "api"):
            self.cfg.claude_auth = mode
            if mode == "api":
                self.security.store()                                                  # a key IS in the fake Keychain: it must still not be read
            yield mode

    def test_check_ready_is_lane_denied_with_no_process_and_no_keychain_read(self):
        self.start_run(True)
        for mode in self.modes():
            with self.subTest(mode=mode):
                ready = note.check_ready(self.cfg)
                self.assertFalse(ready.ok)
                self.assertEqual((ready.kind, ready.retryable), ("lane_denied", False))
                self.assertIn("local_only", ready.error)
                self.assert_nothing_started(mode)

    def test_preflight_starts_no_auth_status(self):
        self.start_run(True)
        ok, info = note.preflight(str(self.fake.path), cfg=self.cfg)
        self.assertFalse(ok)
        self.assertTrue(info["lane_denied"])
        self.assertIn("local_only", info["error"])
        self.assert_nothing_started()

    def test_run_claude_returns_lane_denied_without_a_process_or_a_key_read(self):
        self.start_run(True)
        for mode in self.modes():
            with self.subTest(mode=mode):
                out = note.run_claude(self.cfg, "prompt", "opus", "sonnet", "high", 30)
                self.assertEqual((out.kind, out.detail["reason"]), ("lane_denied", "local_only"))
                self.assertEqual(out.note_text, "")
                self.assert_nothing_started(mode)

    def test_call_claude_is_lane_denied_before_any_budget_is_counted(self):
        self.start_run(True)
        budget = usage.CallBudget(5)
        for mode in self.modes():
            with self.subTest(mode=mode):
                res = note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30, budget=budget)
                self.assertFalse(res.ok)
                self.assertEqual((res.error_kind, res.retryable), ("lane_denied", False))
                self.assertEqual(budget.used, 0)
                self.assert_nothing_started(mode)

    def test_generate_note_reports_lane_denied(self):
        self.start_run(True)
        meta = note.note_meta(SESSION, None, 3808.0, "mlx-community/whisper-large-v3-mlx", self.cfg)
        res = note.generate_note(TRANSCRIPT, meta, self.cfg, test_note.VOCAB)
        self.assertEqual((res.ok, res.error_kind), (False, "lane_denied"))
        self.assert_nothing_started()

    def test_the_calendar_lookup_starts_nothing_not_even_the_login_check(self):
        self.start_run(True)
        for mode in self.modes():
            with self.subTest(mode=mode):
                self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
                with self.assertRaises(calendar_lookup.CalendarUnavailable) as cm:
                    calendar_lookup.fetch_events(self.cfg, *self.window())
                self.assertIn("local_only", str(cm.exception))
                self.assert_nothing_started(mode)

    def window(self):
        start = calendar_lookup.session_start(SESSION)
        return start - calendar_lookup.WINDOW_MARGIN, start + calendar_lookup.WINDOW_MARGIN

    def test_an_unreadable_session_json_closes_the_same_doors(self):
        priv = self.start_run()
        (self.src / "session.json").write_text("{broken", encoding="utf-8")
        self.assertEqual(note.check_ready(self.cfg).kind, "lane_denied")
        self.assertEqual(note.call_claude(self.cfg, "p", lambda t: (t, []), timeout_s=5).error_kind, "lane_denied")
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assert_nothing_started()
        self.assertEqual(priv.lane_block("llm").reason, "session-unreadable")

    def test_the_gate_closes_between_the_attempts_of_one_call(self):
        """The first attempt runs and fails (overloaded); the meeting becomes local-only meanwhile; the retry on the fallback model is NOT made."""
        self.start_run()
        self.fake.set(runs=[{"mode": "overloaded"}, {"mode": "success", "note": "later"}])
        real = note.run_claude
        started = []

        def run_then_flip(*args, **kwargs):
            out = real(*args, **kwargs)
            started.append(out.kind)
            set_flag(self.src, True)
            return out

        with mock.patch.object(note, "run_claude", run_then_flip):
            res = note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30)
        self.assertEqual((res.ok, res.error_kind), (False, "lane_denied"))
        self.assertEqual(started, ["overloaded"])
        self.assertEqual(len(self.fake.calls("note")), 1)                               # exactly the first attempt

    def test_with_the_lane_open_everything_runs_as_before(self):
        self.start_run(False)
        ready = note.check_ready(self.cfg)
        self.assertTrue(ready.ok, ready.error)
        self.assertEqual(len(self.fake.calls("auth")), 1)
        res = note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(len(self.fake.calls("note")), 1)
        match = calendar_lookup.lookup_calendar(self.cfg, SESSION)
        self.assertIsNotNone(match)
        self.assertEqual(match.title, "Alex Weekly")

    def test_without_an_active_run_nothing_is_gated(self):
        """An explicit command (`mcap api-key check`, doctor) has no run: no gate, even for a session folder that says local_only."""
        set_flag(self.src, True)
        self.assertIsNone(lanes.current())
        self.assertTrue(note.check_ready(self.cfg).ok)
        self.cfg.claude_auth = "api"
        self.security.store()
        out = note.run_claude(self.cfg, "prompt", "opus", "sonnet", "high", 30, auth="api")
        self.assertEqual(out.kind, "ok")
        self.assertEqual(self.security.reads(), 1)

    def test_a_lane_denied_call_is_not_recorded_and_costs_no_budget_in_api_mode_either(self):
        self.cfg.claude_auth = "api"
        self.cfg.claude_daily_budget_usd = 5.0
        self.security.store()
        self.start_run(True)
        for _ in range(3):
            note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30)
        self.assert_nothing_started()


class OrganisationGateTests(GateCase):
    """One lane at a time: the organisation denies llm or calendar, and only that lane's functions refuse."""

    def policy_run(self, **lane_overrides):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": {"sha256": self.pin_of_the_fake()}}, lanes=lane_overrides))
        priv = self.resolve(org)
        self.run_scope(priv)
        return priv

    def pin_of_the_fake(self) -> str:
        return hashlib.sha256(Path(self.fake.path).resolve().read_bytes()).hexdigest()

    def test_the_llm_lane_denied_closes_the_note_side_and_not_the_calendar_side(self):
        self.policy_run(llm="deny")
        ready = note.check_ready(self.cfg)
        self.assertEqual((ready.ok, ready.kind), (False, "lane_denied"))
        self.assertIn("policy-lane", ready.error)
        self.assertEqual(note.call_claude(self.cfg, "p", lambda t: (t, []), timeout_s=5).error_kind, "lane_denied")
        self.assertEqual(self.fake.calls(), [])
        match = calendar_lookup.lookup_calendar(self.cfg, SESSION)                    # the calendar lane is its own lane and is open
        self.assertIsNotNone(match)

    def test_the_calendar_lane_denied_closes_only_the_calendar(self):
        self.policy_run(calendar="deny")
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls("calendar"), [])
        self.assertTrue(note.check_ready(self.cfg).ok)
        self.assertTrue(note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30).ok)

    def test_a_company_llm_lane_without_an_approval_reference_is_closed(self):
        doc = company_doc(self.root)
        doc["approvals"].pop("llm")
        priv = self.resolve(self.put_policy(doc))
        self.run_scope(priv)
        ready = note.check_ready(self.cfg)
        self.assertEqual((ready.kind, "policy-unapproved" in ready.error), ("lane_denied", True))
        self.assertEqual(self.fake.calls(), [])

    def test_a_company_llm_lane_without_a_pin_is_closed(self):
        doc = company_doc(self.root)
        doc["llm"] = {}
        self.run_scope(self.resolve(self.put_policy(doc)))
        ready = note.check_ready(self.cfg)
        self.assertEqual((ready.kind, "policy-claude-unpinned" in ready.error), ("lane_denied", True))
        self.assertEqual(self.fake.calls(), [])

    def test_a_locked_policy_closes_both(self):
        org = self.put_policy({"schema": 1, "profile": "company", "revision": 1, "surprise": 1})
        self.run_scope(self.resolve(org))
        self.assertEqual(note.check_ready(self.cfg).kind, "lane_denied")
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls(), [])


class SignaturePinTests(GateCase):
    def pin_run(self, pin, **kw):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": pin}, **kw))
        priv = self.resolve(org)
        self.run_scope(priv)
        return org, priv

    def fake_binary_hash(self) -> str:
        return hashlib.sha256(Path(self.fake.path).resolve().read_bytes()).hexdigest()

    def codesign_runner(self, returncode=0, *, raises=None):
        calls = []
        real_run = subprocess.run

        def run(argv, *args, **kwargs):
            if argv and argv[0] == "/usr/bin/codesign":
                calls.append(list(argv))
                if raises:
                    raise raises
                return SimpleNamespace(returncode=returncode, stdout="", stderr="")
            return real_run(argv, *args, **kwargs)

        run.calls = calls
        return run

    # ---- nothing to verify
    def test_without_a_policy_or_a_run_there_is_nothing_to_verify(self):
        run = self.codesign_runner()
        self.assertIsNone(note.verify_claude_bin(self.cfg, run=run))
        self.assertIsNone(note.verify_claude_bin(self.cfg, policy.absent_policy(), run=run))
        self.assertEqual(run.calls, [])

    def test_the_personal_profile_is_not_verified(self):
        run = self.codesign_runner(returncode=1)
        org = self.put_policy({"schema": 1, "profile": "personal", "revision": 1, "llm": {"claude_bin_pin": {"team_id": "ABCDE12345"}}})
        self.assertIsNone(note.verify_claude_bin(self.cfg, org, run=run))
        self.assertEqual(run.calls, [])

    def test_a_locked_policy_is_not_verified_here_its_lanes_are_closed_before(self):
        run = self.codesign_runner(returncode=1)
        org = self.put_policy({"schema": 1, "profile": "company", "revision": 1, "bogus": 1})
        self.assertIsNone(note.verify_claude_bin(self.cfg, org, run=run))
        self.assertEqual(run.calls, [])

    def test_a_company_policy_without_a_pin_is_a_closed_door_for_every_start_of_claude(self):
        """The llm lane is already denied for a missing pin; the calendar lane (allowed on its own) must not start an unpinned binary either."""
        doc = company_doc(self.root)
        doc["llm"] = {}
        org = self.put_policy(doc)
        block = note.verify_claude_bin(self.cfg, org, run=self.codesign_runner(0))
        self.assertEqual((block.kind, block.reason), ("lane_denied", "policy-claude-unpinned"))
        self.run_scope(self.resolve(org))
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls(), [], "the calendar lane is open, the binary is unpinned: nothing was started")

    def test_a_denied_llm_lane_still_pins_the_binary_the_calendar_starts(self):
        org, _priv = self.pin_run({"sha256": "0" * 64}, lanes={"llm": "deny"})
        self.assertIsNotNone(note.verify_claude_bin(self.cfg, org))
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls(), [])

    # ---- team id: codesign -R
    def test_a_team_id_pin_is_checked_with_a_codesign_requirement_of_that_team(self):
        org, _priv = self.pin_run({"team_id": "ABCDE12345"})
        run = self.codesign_runner(0)
        self.assertIsNone(note.verify_claude_bin(self.cfg, org, run=run))
        argv, = run.calls
        self.assertEqual(argv[:3], ["/usr/bin/codesign", "--verify", "--strict"])
        self.assertEqual(argv[3], '-R=anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"')    # "-R" + "=<text requirement>"
        self.assertEqual(argv[4], str(Path(self.fake.path).resolve()))

    def test_a_signature_that_does_not_match_is_policy_claude_unpinned(self):
        org, _priv = self.pin_run({"team_id": "ABCDE12345"})
        block = note.verify_claude_bin(self.cfg, org, run=self.codesign_runner(1))
        self.assertEqual((block.lane, block.kind, block.reason), ("llm", "lane_denied", "policy-claude-unpinned"))
        self.assertIn("signature", block.message)

    def test_codesign_that_cannot_run_is_a_closed_lane(self):
        org, _priv = self.pin_run({"team_id": "ABCDE12345"})
        block = note.verify_claude_bin(self.cfg, org, run=self.codesign_runner(raises=OSError("no codesign")))
        self.assertEqual(block.reason, "policy-claude-unpinned")

    def test_the_check_is_made_once_per_run_and_binary(self):
        self.pin_run({"team_id": "ABCDE12345"})
        run = self.codesign_runner(0)
        with mock.patch.object(subprocess, "run", run):
            for _ in range(4):
                self.assertTrue(note.check_ready(self.cfg).ok)
        self.assertEqual(len(run.calls), 1)
        self.assertEqual(len(self.fake.calls("auth")), 4)

    def test_a_failed_check_is_remembered_for_the_run_too(self):
        self.pin_run({"team_id": "ABCDE12345"})
        run = self.codesign_runner(1)
        with mock.patch.object(subprocess, "run", run):
            for _ in range(3):
                self.assertEqual(note.check_ready(self.cfg).kind, "lane_denied")
        self.assertEqual(len(run.calls), 1)
        self.assertEqual(self.fake.calls(), [])                                          # the unpinned binary was never started

    # ---- sha256
    def test_a_sha256_pin_compares_the_file_and_starts_no_codesign(self):
        org, _priv = self.pin_run({"sha256": self.fake_binary_hash()})
        run = self.codesign_runner(1)
        self.assertIsNone(note.verify_claude_bin(self.cfg, org, run=run))
        self.assertEqual(run.calls, [])

    def test_a_different_sha256_closes_the_lane_and_the_binary_is_not_started(self):
        self.pin_run({"sha256": "0" * 64})
        ready = note.check_ready(self.cfg)
        self.assertEqual((ready.ok, ready.kind), (False, "lane_denied"))
        self.assertIn("sha256", ready.error)
        res = note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30)
        self.assertEqual(res.error_kind, "lane_denied")
        self.assertIsNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.assertEqual(self.fake.calls(), [])

    def test_a_missing_binary_closes_the_lane(self):
        self.pin_run({"sha256": self.fake_binary_hash()})
        self.cfg.claude_bin = self.root / "nowhere" / "claude"
        self.assertEqual(note.check_ready(self.cfg).kind, "lane_denied")

    def test_the_matching_binary_is_used_and_the_calendar_goes_through_the_same_check(self):
        self.pin_run({"sha256": self.fake_binary_hash()})
        self.assertTrue(note.check_ready(self.cfg).ok)
        self.assertIsNotNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        self.fake.set(calendar={"mode": "ok", "events": [self.event]})

    def test_a_binary_that_does_not_match_is_not_used_for_the_calendar_either(self):
        self.pin_run({"sha256": "f" * 64})
        with self.assertRaises(calendar_lookup.CalendarUnavailable):
            calendar_lookup.fetch_events(self.cfg, *LocalOnlyGateTests.window(self))
        self.assertEqual(self.fake.calls(), [])


class ChildEnvPolicyTests(GateCase):
    """policy.llm.child_env (fixed names only) reaches the claude child only with a valid policy; without one the env is the allow-list."""

    def test_clean_env_adds_only_names_from_the_code_list(self):
        env = note.clean_env(home="/Users/alice", user="x", extra={"DISABLE_TELEMETRY": "1", "PATH": "/evil", "ANTHROPIC_BASE_URL": "https://x",
                                                              "DISABLE_AUTOUPDATER": 1})
        self.assertEqual(env, {"HOME": "/Users/alice", "USER": "x", "PATH": env["PATH"], "LANG": "en_US.UTF-8", "DISABLE_TELEMETRY": "1"})
        self.assertTrue(env["PATH"].startswith("/usr/bin:/bin"))
        self.assertEqual(set(note.clean_env(home="/Users/alice", user="x")), ALLOW_ENV)
        self.assertEqual(set(note.clean_env(home="/Users/alice", user="x", extra={})), ALLOW_ENV)

    def test_the_claude_child_of_a_policy_run_gets_the_names_and_a_run_without_a_policy_does_not(self):
        org = self.put_policy(company_doc(self.root, llm={"claude_bin_pin": {"sha256": hashlib.sha256(Path(self.fake.path).resolve().read_bytes()).hexdigest()},
                                                          "child_env": {"DISABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}}))
        with lanes.run_scope(self.resolve(org)):
            self.assertTrue(note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30).ok)
            self.assertIsNotNone(calendar_lookup.lookup_calendar(self.cfg, SESSION))
        for call in self.fake.calls():
            if call["kind"] in ("note", "calendar"):
                self.assertEqual(real_env_keys(call["env"]), ALLOW_ENV | {"DISABLE_TELEMETRY", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"}, call["kind"])
        self.assertEqual({c["kind"] for c in self.fake.calls()} & {"note", "calendar"}, {"note", "calendar"})
        before = len(self.fake.calls())
        self.cfg.policy_path = self.root / "no-policy" / "policy.json"
        plain = lanes.resolve_run(self.cfg, None, self.src, inputs=lanes.PrivacyInputs(sleep=NOSLEEP))
        with lanes.run_scope(plain):
            self.assertTrue(note.call_claude(self.cfg, "prompt", lambda text: (text, []), timeout_s=30).ok)
        for call in self.fake.calls()[before:]:
            self.assertEqual(real_env_keys(call["env"]), ALLOW_ENV)


if __name__ == "__main__":
    unittest.main()
