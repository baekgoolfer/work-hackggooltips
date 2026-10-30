"""The lane gates of one run (SPEC 18): ``lanes.resolve_run``,
``RunPrivacy`` (the gate, the ratchet, the policy re-read, the three places a restricted run says so), the registry of active runs
(``run_scope`` / ``gate`` / ``current``) and the socket tripwire choice.

Nothing here reads the real SUPPORT_DIR, LOG_DIR, /Library policy or Keychain, starts a claude process or opens a socket: every policy file
lives in a temp dir (the owner and mode the loader sees are injected, a test is not root), every flag is a ``session.json`` in a temp
session folder, and the base class turns any non-loopback socket call and any start of the real `security` tool into a test failure.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import json
import os
import socket
import sys
import threading
import unicodedata
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import config, egress, lanes, policy  # noqa: E402
from mcap.config import load_config  # noqa: E402
from net_guard_support import NoNetworkCase  # noqa: E402
from notes_cli_support import load_test_policy, make_cfg, make_session, make_stat_fn  # noqa: E402

NOSLEEP = lambda seconds: None  # noqa: E731
GONE = object()                    # set_flag: remove the key
NOW = datetime(2026, 10, 14, 12, 0, 0).astimezone()
TEAM = "ABCDE12345"


# ---------------------------------------------------------------------------------------------- helpers shared with the other W6b tests
def set_flag(session_dir: Path, value, source: str = "menu") -> None:
    """Write ``local_only`` into session.json the way the Swift app does (any other key stays); GONE removes it."""
    path = Path(session_dir) / "session.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    if value is GONE:
        data.pop("local_only", None)
        data.pop("local_only_source", None)
    else:
        data["local_only"], data["local_only_source"] = value, source
    path.write_text(json.dumps(data), encoding="utf-8")


def company_doc(root: Path, **overrides) -> dict:
    """A valid company policy: every lane allowed with an approval reference, a signature pin, one allowed archive root (``root``/Drive)."""
    doc = {"schema": 1, "profile": "company", "revision": 7, "support": {"contact": "IT #help"},
           "lanes": {"asr_remote": "allow", "asr_cloud": "deny", "llm": "allow", "calendar": "allow", "drive": "allow"},
           "approvals": {"llm": "TICKET-1", "calendar": "TICKET-2", "drive": "TICKET-3"},
           "llm": {"claude_bin_pin": {"team_id": TEAM}},
           "archive": {"allowed_roots": [str(Path(root) / "Drive")], "local_roots": []},
           "asr": {"allowed_engines": ["whisper"], "allowed_hosts": []}}
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(doc.get(key), dict):
            doc[key] = {**doc[key], **value}
        else:
            doc[key] = value
    return doc


class LaneCase(NoNetworkCase):
    """A temp world: ``self.cfg`` (make_cfg, calendar lookup on), one staging session ``self.src``, a fake ``security`` that is never asked,
    no Time Machine call (``exclude_from_backup`` is replaced by a recorder) and helpers to put a policy in place."""

    def setUp(self) -> None:
        super().setUp()
        from mcap import publish
        self.excluded: list = []
        patcher = mock.patch.object(publish, "exclude_from_backup", side_effect=lambda path, **kw: self.excluded.append(str(path)) or True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cfg = make_cfg(self.root, calendar_lookup="auto")
        self.src = make_session(self.cfg)
        self.policy_path = self.root / "etc" / "policy.json"

    # ---- policy
    def put_policy(self, doc, **stat_kw) -> policy.OrgPolicy:
        """Write ``doc`` as THE policy file of this config and load it as a root-owned file (``stat_kw`` as make_stat_fn)."""
        self.cfg.policy_path = self.policy_path
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        return load_test_policy(self.policy_path, doc, **stat_kw)

    def inputs(self, org: policy.OrgPolicy = None, **kw) -> lanes.PrivacyInputs:
        stat_fn = make_stat_fn(self.policy_path) if self.policy_path.exists() else None
        return lanes.PrivacyInputs(policy=org, stat_fn=stat_fn, sleep=NOSLEEP, **kw)

    def resolve(self, org=None, session_dir="src", **kw) -> lanes.RunPrivacy:
        target = self.src if session_dir == "src" else session_dir
        return lanes.resolve_run(self.cfg, None, target, inputs=self.inputs(org, **kw))


class ResolveRunTests(LaneCase):
    def test_the_personal_default_restricts_nothing_and_changes_nothing(self):
        priv = self.resolve()
        self.assertEqual((priv.local_only.value, priv.local_only.source), (False, "default"))
        self.assertTrue(all(priv.lanes[lane].allowed for lane in lanes.TEXT_LANES), priv.lanes)
        self.assertEqual({priv.lanes[lane].reason for lane in ("asr_remote", "asr_cloud")}, {"user-disabled"})      # no external engine is named
        self.assertEqual((priv.asr.primary, priv.asr.fallback, priv.asr.allow_egress, priv.asr.blocked), ("whisper", None, False, None))
        self.assertTrue(priv.asr.allow_download)
        self.assertIs(priv.cfg_for_asr(self.cfg), self.cfg)                      # the SAME object: get_engine(cfg.asr_model) as before
        self.assertEqual(priv.state_fields(), {})
        self.assertIsNone(priv.transcript_policy_block())
        self.assertFalse(priv.keeps_state())
        self.assertFalse(priv.restricted())
        self.assertEqual(priv.archive_root(), (Path(self.cfg.archive_dir), "drive"))
        self.assertEqual(priv.lane_status(), {"llm": "ok", "calendar": "ok", "drive": "ok"})

    def test_resolving_the_default_starts_no_process_and_reads_no_keychain(self):
        with mock.patch("subprocess.run", side_effect=AssertionError("a process")), \
                mock.patch.object(policy, "probe_hardware", side_effect=AssertionError("the hardware probe")), \
                mock.patch.object(policy, "machine_id", side_effect=AssertionError("machine id (ioreg)")):
            priv = self.resolve()
        self.assertEqual(self.security.calls(), [])
        self.assertIsNotNone(priv)

    def test_a_calendar_switched_off_by_the_user_is_not_a_restriction(self):
        self.cfg.calendar_lookup = "0"
        priv = self.resolve()
        self.assertEqual(priv.lanes["calendar"].reason, "user-disabled")
        self.assertFalse(priv.restricted())
        self.assertIsNone(priv.transcript_policy_block())
        self.assertEqual(priv.state_fields(), {})
        self.assertEqual(priv.lane_status()["calendar"], "off")

    def test_local_only_closes_all_five_lanes_and_says_so_in_three_places(self):
        set_flag(self.src, True)
        priv = self.resolve()
        self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "session"))
        for lane in policy.LANES:
            block = priv.lane_block(lane)
            self.assertEqual((block.kind, block.reason, block.lane), ("lane_denied", "local_only", lane))
        self.assertTrue(priv.restricted() and priv.keeps_state())
        self.assertEqual(priv.transcript_policy_block(),
                         {"local_only": True, "lanes": {"llm": "skipped:local_only", "calendar": "skipped:local_only", "drive": "skipped:local_only"}})
        fields = priv.state_fields()
        self.assertEqual((fields["local_only"], fields["local_only_source"]), (True, "session"))
        self.assertEqual(fields["lanes"], {"llm": "skipped:local_only", "calendar": "skipped:local_only", "drive": "skipped:local_only"})
        self.assertEqual(fields["asr"], {"primary": "whisper", "fallback": None, "reason": "local_only"})

    def test_a_local_only_run_gets_a_copy_of_the_config_with_its_decision_and_no_download_and_quiet_logs(self):
        set_flag(self.src, True)
        priv = self.resolve()
        cfg = priv.cfg_for_asr(self.cfg)
        self.assertIsNot(cfg, self.cfg)
        self.assertIs(cfg.asr_decision, priv.asr)
        self.assertFalse(cfg.log_content)
        self.assertIsNone(self.cfg.asr_decision)                                  # the original is untouched
        self.assertTrue(self.cfg.log_content)
        self.assertFalse(priv.asr.allow_download)
        self.assertTrue(policy.is_issued(priv.asr))

    def test_a_flag_switched_after_the_run_started_reaches_the_asr_stage(self):
        """The flag is switched on after resolve_run (while the audio is prepared): the config of the ASR stage is read from the file at
        that moment, not from the state at the start of the run."""
        priv = self.resolve()
        self.assertIs(priv.cfg_for_asr(self.cfg), self.cfg)                                  # still the default: the same object
        set_flag(self.src, True)
        cfg = priv.cfg_for_asr(self.cfg)                                                      # the first look after the switch
        self.assertIsNot(cfg, self.cfg)
        self.assertFalse(cfg.log_content)                                                     # no transcript snippets in the pipeline log
        self.assertTrue(policy.is_issued(cfg.asr_decision))
        self.assertEqual((cfg.asr_decision.local_only, cfg.asr_decision.allow_download), (True, False))   # and no model download
        self.assertEqual((cfg.asr_decision.primary, cfg.asr_decision.fallback), ("whisper", None))
        self.assertTrue(priv.asr.allow_download and not priv.asr.local_only)                  # the decision of the run start is not rewritten
        self.assertIsNone(self.cfg.asr_decision)
        self.assertTrue(self.cfg.log_content)

    def test_default_local_asr_reads_the_flag_again(self):
        priv = self.resolve()
        self.assertTrue(priv.default_local_asr(self.cfg))
        set_flag(self.src, True)
        self.assertFalse(priv.default_local_asr(self.cfg))                                    # not the value of the start of the run

    def test_the_flag_read_for_the_asr_stage_is_the_ratcheted_one(self):
        priv = self.resolve()
        set_flag(self.src, True)
        self.assertFalse(priv.cfg_for_asr(self.cfg).log_content)
        set_flag(self.src, False)                                                             # off again: a run that was local-only stays so
        cfg = priv.cfg_for_asr(self.cfg)
        self.assertFalse(cfg.log_content)
        self.assertFalse(cfg.asr_decision.allow_download)

    def test_a_flag_that_stays_false_leaves_the_asr_config_alone_on_every_call(self):
        priv = self.resolve()
        for _ in range(3):
            self.assertIs(priv.cfg_for_asr(self.cfg), self.cfg)
        set_flag(self.src, False)
        self.assertIs(priv.cfg_for_asr(self.cfg), self.cfg)

    def test_flag_values_that_are_not_booleans_close_the_run(self):
        for value in ("false", 0, 1, [], {}, "no"):
            with self.subTest(value=value):
                set_flag(self.src, value)
                priv = self.resolve()
                self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "fail-closed:bad-type"))
                self.assertEqual(priv.lane_block("llm").reason, "local_only")

    def test_a_flag_that_is_false_or_missing_follows_the_default_chain(self):
        set_flag(self.src, False)
        self.assertFalse(self.resolve().local_only.value)
        set_flag(self.src, GONE)
        self.assertEqual((self.resolve().local_only.value, self.resolve().local_only.source), (False, "default"))
        self.cfg.local_only_default = True                                        # LOCAL_ONLY_DEFAULT
        priv = self.resolve()
        self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "default"))
        set_flag(self.src, False)                                                 # a value of the meeting itself beats the default
        self.assertFalse(self.resolve().local_only.value)

    def test_an_unreadable_session_json_closes_every_lane_with_its_own_reason(self):
        (self.src / "session.json").write_text("{not json", encoding="utf-8")
        priv = self.resolve()
        self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "fail-closed:unreadable"))
        self.assertEqual({lane: priv.lane_block(lane).reason for lane in policy.LANES}, {lane: "session-unreadable" for lane in policy.LANES})
        (self.src / "session.json").unlink()
        self.assertEqual(self.resolve().lane_block("drive").reason, "session-unreadable")

    def test_without_a_session_folder_the_default_chain_decides(self):
        priv = lanes.resolve_run(self.cfg, None, None, inputs=self.inputs())
        self.assertIsNone(priv.session_path)
        self.assertFalse(priv.local_only.value)
        self.assertIsNone(priv.lane_block("llm"))
        self.cfg.local_only_default = True
        priv = lanes.resolve_run(self.cfg, None, None, inputs=self.inputs())
        self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "default"))
        self.assertEqual(priv.lane_block("llm").reason, "local_only")
        facts = lanes.resolve_run(self.cfg, None, None, inputs=self.inputs(meeting={"local_only": False}))
        self.assertFalse(facts.local_only.value)

    def test_a_failure_while_resolving_is_a_closed_run_never_an_exception(self):
        with mock.patch.object(policy, "lane_decisions", side_effect=RuntimeError("bug")), self.assertLogs("mcap.lanes", level="ERROR"):
            priv = self.resolve()
        self.assertTrue(priv.local_only.value)
        self.assertEqual(priv.local_only.source, "fail-closed:resolve-error")
        self.assertEqual(priv.asr.primary, "whisper")                              # the meeting is still transcribed
        self.assertFalse(priv.asr.allow_egress)
        self.assertEqual(priv.lane_block("llm").reason, "gate-error")
        self.assertEqual(priv.lane_block("drive").kind, "lane_denied")

    def test_the_hardware_and_the_consents_are_only_looked_at_when_the_configuration_names_an_engine_that_needs_them(self):
        hw = SimpleNamespace(capable=True)
        with mock.patch.object(policy, "probe_hardware", return_value=hw) as probe, \
                mock.patch.object(policy, "machine_id", return_value="m" * 64) as machine, \
                mock.patch.object(policy, "load_consents", return_value=policy.ConsentSet(machine="m" * 64)) as consents:
            self.cfg.asr_engine = "whisper"
            self.resolve()
            self.assertEqual((probe.call_count, machine.call_count, consents.call_count), (0, 0, 0))
            self.cfg.asr_engine = "auto"
            self.resolve()
            self.assertEqual((probe.call_count, consents.call_count), (1, 1))
            self.cfg.asr_engine, self.cfg.asr_fallback = "whisper", "remote"
            self.resolve()
            self.assertEqual((probe.call_count, consents.call_count), (1, 2))      # a consent file is read for the fallback, hardware is not needed

    def test_an_injected_policy_consents_and_hardware_are_used_as_given(self):
        set_flag(self.src, False)
        self.cfg.asr_engine, self.cfg.asr_remote_url = "remote", "https://asr.example.internal"
        org = self.put_policy(company_doc(self.root, asr={"allowed_engines": ["whisper", "remote"], "allowed_hosts": ["asr.example.internal"]}))
        priv = self.resolve(org, hw=SimpleNamespace(capable=False), consents=policy.ConsentSet(machine="x"), now=NOW)
        self.assertEqual(priv.asr.primary, "whisper")                               # no consent: the local engine instead ...
        self.assertEqual(priv.asr.blocked, "asr_policy_blocked")                    # ... and this Mac cannot run it: blocked (A6)
        self.assertEqual(priv.asr.reason, "no-consent")


class OrganisationLaneTests(LaneCase):
    """The organisation denies lanes one by one; each denial is a reason code and every other lane stays open."""

    def lanes_of(self, doc, **resolve_kw) -> dict:
        priv = self.resolve(self.put_policy(doc), **resolve_kw)
        return {lane: priv.lanes[lane].reason for lane in policy.LANES}

    def test_a_company_policy_with_everything_approved_opens_the_lanes_the_flag_allows(self):
        self.cfg.asr_engine = "whisper"
        reasons = self.lanes_of(company_doc(self.root))
        self.assertEqual(reasons["llm"], "ok")
        self.assertEqual(reasons["calendar"], "ok")
        self.assertEqual(reasons["drive"], "ok")                                   # ARCHIVE_DIR is explicit and inside the allowed root
        self.assertEqual(reasons["asr_cloud"], "policy-lane")

    def test_each_organisation_denial_closes_exactly_its_lane(self):
        for lane in ("llm", "calendar", "drive"):
            with self.subTest(lane=lane):
                doc = company_doc(self.root, lanes={lane: "deny"})
                reasons = self.lanes_of(doc)
                self.assertEqual(reasons[lane], "policy-lane")
                self.assertTrue(all(reasons[other] == "ok" for other in ("llm", "calendar", "drive") if other != lane), reasons)

    def test_a_lane_without_an_approval_reference_is_denied_in_the_company_profile(self):
        for lane in ("llm", "calendar", "drive"):
            with self.subTest(lane=lane):
                approvals = {k: v for k, v in company_doc(self.root)["approvals"].items() if k != lane}
                doc = company_doc(self.root)
                doc["approvals"] = approvals
                self.assertEqual(self.lanes_of(doc)[lane], "policy-unapproved")

    def test_llm_without_a_signature_pin_is_denied(self):
        doc = company_doc(self.root)
        doc["llm"] = {}
        self.assertEqual(self.lanes_of(doc)["llm"], "policy-claude-unpinned")

    def test_a_policy_that_does_not_list_a_lane_denies_it_in_the_company_profile(self):
        doc = company_doc(self.root)
        del doc["lanes"]["calendar"]
        self.assertEqual(self.lanes_of(doc)["calendar"], "policy-lane")

    def test_the_drive_lane_needs_an_explicit_archive_dir_and_a_matching_root(self):
        priv = self.resolve(self.put_policy(company_doc(self.root)))
        self.assertIsNone(priv.lane_block("drive"))
        org = self.put_policy(company_doc(self.root))
        self.cfg.explicit_keys = frozenset()                                       # ARCHIVE_DIR is a built-in default, not set by the user
        self.assertEqual(self.resolve(org).lane_block("drive").reason, "archive-not-configured")
        self.cfg.archive_dir = self.root / "elsewhere" / "Meetings"
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        self.assertEqual(self.resolve(org).lane_block("drive").reason, "policy-archive-root")

    def test_a_locked_policy_closes_everything_and_forces_the_flag(self):
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        org = self.put_policy({"schema": 1, "profile": "company", "revision": 1, "bogus": True})
        self.assertTrue(org.locked)
        priv = self.resolve(org)
        self.assertEqual((priv.local_only.value, priv.local_only.source), (True, "policy-lock"))
        self.assertEqual({lane: priv.lane_block(lane).reason for lane in policy.LANES}, {lane: "policy-locked" for lane in policy.LANES})
        set_flag(self.src, False)                                                  # the session cannot say otherwise
        self.assertTrue(self.resolve(org).local_only.value)

    def test_the_policy_can_lock_the_flag_on_and_default_it(self):
        org = self.put_policy(company_doc(self.root, local_only={"default": True, "locked": False}))
        self.assertEqual(self.resolve(org).local_only.source, "default")
        self.assertTrue(self.resolve(org).local_only.value)
        set_flag(self.src, False)
        self.assertFalse(self.resolve(org).local_only.value)                       # not locked: the meeting's own value wins
        org = self.put_policy(company_doc(self.root, local_only={"default": False, "locked": True}))
        self.assertEqual((self.resolve(org).local_only.value, self.resolve(org).local_only.source), (True, "policy-lock"))

    def test_an_organisation_denial_is_a_restriction_that_is_shown_and_keeps_the_state_file(self):
        org = self.put_policy(company_doc(self.root, lanes={"calendar": "deny"}))
        priv = self.resolve(org)
        self.assertTrue(priv.restricted() and priv.keeps_state())
        self.assertEqual(priv.transcript_policy_block(),
                         {"local_only": False, "lanes": {"llm": "ok", "calendar": "skipped:policy-lane", "drive": "ok"}})
        fields = priv.state_fields()
        self.assertEqual((fields["local_only"], fields["lanes"]["calendar"]), (False, "skipped:policy-lane"))
        self.assertEqual(priv.archive_root()[1], "drive")                          # the Drive lane itself is open

    def test_a_policy_without_any_denial_writes_state_fields_but_no_transcript_block(self):
        self.cfg.asr_engine = "whisper"
        org = self.put_policy(company_doc(self.root))
        priv = self.resolve(org)
        self.assertFalse(priv.restricted())
        self.assertIsNone(priv.transcript_policy_block())
        self.assertFalse(priv.keeps_state())
        self.assertEqual(priv.state_fields()["lanes"], {"llm": "ok", "calendar": "ok", "drive": "ok"})
        self.assertIsNot(priv.cfg_for_asr(self.cfg), self.cfg)                      # a policy always hands the decision to the ASR stage

    def test_the_company_baseline_forbids_downloads_so_the_run_is_strict(self):
        self.cfg.asr_allow_download = False                                        # what the policy's enforced baseline reads as
        priv = self.resolve(self.put_policy(company_doc(self.root)))
        self.assertFalse(priv.asr.allow_download)
        self.assertEqual(lanes.tripwire_mode(priv.asr), "strict")


class ArchiveRootTests(LaneCase):
    def test_a_denied_drive_lane_goes_to_the_default_local_archive_under_support_dir(self):
        set_flag(self.src, True)
        root, kind = self.resolve().archive_root()
        self.assertEqual((root, kind), (self.cfg.support_dir / "local-meetings", "local"))

    def test_a_local_archive_dir_inside_support_dir_is_fine(self):
        set_flag(self.src, True)
        self.cfg.local_archive_dir = self.cfg.support_dir / "my local" / "meetings"
        self.assertEqual(self.resolve().archive_root(), (self.cfg.local_archive_dir, "local"))

    def test_a_local_archive_dir_outside_the_allow_list_is_unsafe(self):
        set_flag(self.src, True)
        for where in (self.root / "Drive" / "Meetings", Path("/tmp/mcap-local"), Path("/Users/Shared/meetings")):
            with self.subTest(where=str(where)):
                self.cfg.local_archive_dir = where
                with self.assertRaises(lanes.LocalArchiveUnsafe) as cm:
                    self.resolve().archive_root()
                self.assertEqual(cm.exception.reason, "outside-allowed-roots")

    def test_a_symlink_in_the_local_archive_path_is_unsafe(self):
        set_flag(self.src, True)
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        link = self.cfg.support_dir / "local-link"
        link.symlink_to(elsewhere)
        self.cfg.local_archive_dir = link / "meetings"
        with self.assertRaises(lanes.LocalArchiveUnsafe) as cm:
            self.resolve().archive_root()
        self.assertEqual(cm.exception.reason, "symlink-in-path")
        self.cfg.local_archive_dir = link                                          # the link itself
        with self.assertRaises(lanes.LocalArchiveUnsafe):
            self.resolve().archive_root()

    def test_a_local_archive_dir_on_another_device_is_unsafe(self):
        set_flag(self.src, True)
        real = os.stat

        def other_device(path, *args, **kwargs):
            st = real(path, *args, **kwargs)
            if str(path).startswith(str(Path(self.cfg.support_dir).resolve())):
                return SimpleNamespace(st_dev=st.st_dev + 1)
            return st

        with mock.patch.dict(policy.local_archive_ok.__kwdefaults__, {"stat_fn": other_device}):     # the stat function is a keyword default
            with self.assertRaises(lanes.LocalArchiveUnsafe) as cm:
                self.resolve().archive_root()
        self.assertEqual(cm.exception.reason, "different-device")

    def test_a_policy_local_root_extends_the_allow_list(self):
        set_flag(self.src, True)
        extra = self.root / "managed local"
        extra.mkdir()
        self.cfg.local_archive_dir = extra / "m"
        with self.assertRaises(lanes.LocalArchiveUnsafe):
            self.resolve().archive_root()
        org = self.put_policy(company_doc(self.root, archive={"local_roots": [str(extra)]}))
        self.assertEqual(self.resolve(org).archive_root(), (extra / "m", "local"))

    def test_nfd_and_case_variants_of_the_allowed_root_still_match(self):
        name = "Mëeting-Drive"
        base = self.root / unicodedata.normalize("NFC", name)
        (base / "inbox").mkdir(parents=True)
        self.cfg.archive_dir = Path(str(self.root / unicodedata.normalize("NFD", name)) + "/inbox")
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        doc = company_doc(self.root, archive={"allowed_roots": [str(base)]})
        org = self.put_policy(doc)
        priv = self.resolve(org)
        self.assertIsNone(priv.lane_block("drive"), "an NFD spelling of the same folder is inside the root")
        self.cfg.archive_dir = Path(str(base).upper() + "/inbox")
        self.assertIsNone(self.resolve(org).lane_block("drive"))                    # casefold (APFS is case-insensitive by default)

    def test_the_archive_root_is_evaluated_again_on_every_call(self):
        org = self.put_policy(company_doc(self.root))
        priv = self.resolve(org)
        self.assertEqual(priv.archive_root()[1], "drive")
        self.cfg.archive_dir = self.root / "swapped" / "Meetings"                   # the Drive folder is repointed after the run started
        self.assertEqual(priv.archive_root()[1], "local")
        self.cfg.archive_dir = self.root / "Drive" / "My Drive" / "Meetings"
        self.assertEqual(priv.archive_root()[1], "local", "the denial is sticky for the rest of the run (ratchet)")


class GateTests(LaneCase):
    """L1 - L4: the registry of active runs, re-reading, the ratchet."""

    def test_no_active_run_means_no_gate(self):
        self.assertIsNone(lanes.current())
        self.assertIsNone(lanes.gate("llm"))
        self.assertEqual(lanes.llm_child_env(), {})

    def test_gate_answers_for_the_active_run_from_a_bare_thread(self):
        set_flag(self.src, True)
        priv = self.resolve()
        seen: dict = {}

        def worker():                                                               # a thread of its own, like the cleanup's pool workers
            seen["llm"] = lanes.gate("llm")
            seen["drive"] = lanes.gate("drive")

        with lanes.run_scope(priv):
            thread = threading.Thread(target=worker)
            thread.start()
            thread.join(10)
            self.assertIs(lanes.current(), priv)
        self.assertEqual((seen["llm"].reason, seen["drive"].reason), ("local_only", "local_only"))
        self.assertIsNone(lanes.gate("llm"))
        self.assertIsNone(lanes.current())

    def test_a_run_that_restricts_nothing_lets_every_thread_through(self):
        priv = self.resolve()
        results = []
        with lanes.run_scope(priv):
            threads = [threading.Thread(target=lambda: results.append(lanes.gate("llm"))) for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(10)
        self.assertEqual(results, [None] * 4)

    def test_nested_runs_answer_for_the_innermost_and_leave_in_order(self):
        outer = self.resolve()
        other = make_session(self.cfg, "2026-10-07_1500_meet")
        set_flag(other, True)
        inner = self.resolve(session_dir=other)
        with lanes.run_scope(outer):
            self.assertIsNone(lanes.gate("llm"))
            with lanes.run_scope(inner):
                self.assertIs(lanes.current(), inner)
                self.assertEqual(lanes.gate("llm").reason, "local_only")
            self.assertIs(lanes.current(), outer)
            self.assertIsNone(lanes.gate("llm"))
        self.assertIsNone(lanes.current())

    def test_two_sessions_with_different_flags_one_after_the_other_in_one_process(self):
        first, second = self.src, make_session(self.cfg, "2026-10-07_1500_meet")
        set_flag(first, True)
        set_flag(second, False)
        for target, expected in ((first, "local_only"), (second, None), (first, "local_only"), (second, None)):
            priv = self.resolve(session_dir=target)
            with lanes.run_scope(priv):
                block = lanes.gate("llm")
                self.assertEqual(block.reason if block else None, expected, target.name)
            self.assertIsNone(lanes.gate("llm"))

    def test_the_scope_is_left_when_the_block_raises(self):
        priv = self.resolve()
        with self.assertRaises(RuntimeError):
            with lanes.run_scope(priv):
                raise RuntimeError("boom")
        self.assertIsNone(lanes.current())

    def test_every_call_reads_session_json_again(self):
        priv = self.resolve()
        with lanes.run_scope(priv):
            self.assertIsNone(lanes.gate("llm"))
            set_flag(self.src, True)                                                # the Swift app switches the meeting to local-only
            block = lanes.gate("llm")
            self.assertEqual((block.kind, block.reason), ("lane_denied", "local_only"))
            self.assertEqual(lanes.gate("calendar").reason, "local_only")
            self.assertEqual(lanes.gate("drive").reason, "local_only")
            self.assertEqual(lanes.gate("asr_remote").reason, "local_only")
        self.assertTrue(priv.local_only.value)

    def test_the_ratchet_keeps_a_lane_closed_even_when_the_flag_is_switched_back(self):
        priv = self.resolve()
        set_flag(self.src, True)
        self.assertIsNotNone(priv.lane_block("llm"))
        set_flag(self.src, False)
        self.assertIsNotNone(priv.lane_block("llm"), "OFF (a relaxation) applies from the next (re)processing, not inside this run")
        set_flag(self.src, GONE)
        self.assertIsNotNone(priv.lane_block("drive"))
        self.assertTrue(priv.local_only.value)
        self.assertIsNone(self.resolve().lane_block("llm"), "the next run derives everything from the file again")

    def test_an_unreadable_session_json_at_the_gate_closes_the_lane_and_ratchets(self):
        priv = self.resolve()
        self.assertIsNone(priv.lane_block("llm"))
        original = (self.src / "session.json").read_text(encoding="utf-8")
        (self.src / "session.json").write_text("\x00\x01 not json", encoding="utf-8")
        for lane in policy.LANES:
            self.assertEqual(priv.lane_block(lane).reason, "session-unreadable")
        (self.src / "session.json").write_text(original, encoding="utf-8")         # the file is fine again: the lane stays closed
        self.assertEqual(priv.lane_block("llm").reason, "session-unreadable")
        self.assertTrue(priv.local_only.value)
        self.assertEqual(priv.local_only.source, "fail-closed:unreadable")

    def test_a_vanished_session_json_closes_the_lane_and_a_rebind_points_at_the_moved_folder(self):
        priv = self.resolve()
        moved = self.root / "moved"
        self.src.rename(moved)
        self.assertEqual(priv.lane_block("llm").reason, "session-unreadable")       # (after the move nobody asks, but it must never open)
        fresh = lanes.resolve_run(self.cfg, None, moved, inputs=self.inputs())
        fresh_other = self.root / "moved-again"
        moved.rename(fresh_other)
        fresh.rebind(fresh_other)
        self.assertIsNone(fresh.lane_block("llm"))

    def test_an_unknown_lane_is_closed(self):
        block = self.resolve().lane_block("telemetry")
        self.assertEqual((block.kind, block.reason), ("lane_denied", "unknown-lane"))

    def test_a_failure_inside_the_gate_closes_the_lane(self):
        priv = self.resolve()
        with mock.patch.object(policy, "read_session_local_only", side_effect=RuntimeError("bug")), self.assertLogs("mcap.lanes", level="WARNING"):
            block = priv.lane_block("llm")
        self.assertEqual((block.kind, block.reason), ("lane_denied", "gate-error"))

    def test_concurrent_gate_calls_during_a_flip_never_see_an_open_lane_afterwards(self):
        priv = self.resolve()
        errors, opened_after_flip = [], []
        flipped = threading.Event()

        def worker():
            try:
                for _ in range(200):
                    was_flipped = flipped.is_set()
                    block = priv.lane_block("llm")
                    if was_flipped and block is None:
                        opened_after_flip.append(1)
            except Exception as exc:                                                # pragma: no cover
                errors.append(exc)

        threads = [threading.Thread(target=worker) for _ in range(6)]
        for thread in threads:
            thread.start()
        set_flag(self.src, True)
        flipped.set()
        for thread in threads:
            thread.join(30)
        self.assertEqual((errors, opened_after_flip), ([], []))

    def test_the_gate_serves_every_asr_lane_name_the_router_uses(self):
        self.cfg.asr_engine, self.cfg.asr_fallback = "remote", "none"
        priv = self.resolve()
        self.assertIsNone(priv.lane_block("asr_remote"))                            # named by ASR_ENGINE
        self.assertEqual(priv.lane_block("asr_cloud").reason, "user-disabled")      # no cloud engine is named
        set_flag(self.src, True)
        self.assertEqual(priv.lane_block("asr_remote").reason, "local_only")


class PolicyRereadTests(LaneCase):
    """SPEC 18: a changed policy file is read again at the gate; a stricter or invalid verdict wins, a relaxation does not."""

    def start(self, doc=None):
        org = self.put_policy(doc or company_doc(self.root))
        return self.resolve(org)

    def rewrite(self, doc) -> None:
        text = json.dumps(doc) if not isinstance(doc, str) else doc
        self.policy_path.write_text(text, encoding="utf-8")

    def test_an_unchanged_policy_file_is_not_read_again(self):
        priv = self.start()
        with mock.patch.object(policy, "load_org_policy", side_effect=AssertionError("read again")):
            for lane in ("llm", "calendar", "drive"):
                self.assertIsNone(priv.lane_block(lane))

    def test_a_stricter_policy_replaced_during_the_run_closes_the_lanes_it_denies(self):
        priv = self.start()
        self.assertIsNone(priv.lane_block("llm"))
        self.rewrite(company_doc(self.root, lanes={"llm": "deny", "calendar": "deny"}))
        self.assertEqual(priv.lane_block("llm").reason, "policy-lane")
        self.assertEqual(priv.lane_block("calendar").reason, "policy-lane")
        self.assertIsNone(priv.lane_block("drive"))
        self.assertTrue(priv.restricted())

    def test_a_policy_that_becomes_invalid_during_the_run_locks_every_lane(self):
        priv = self.start()
        self.rewrite("{ this is not json")
        for lane in policy.LANES:
            self.assertEqual(priv.lane_block(lane).reason, "policy-locked")
        self.assertTrue(priv.local_only.value)                                      # a locked policy forces the flag
        self.assertEqual(priv.local_only.source, "policy-lock")

    def test_a_relaxed_policy_during_the_run_changes_nothing(self):
        priv = self.start(company_doc(self.root, lanes={"llm": "deny"}))
        self.assertEqual(priv.lane_block("llm").reason, "policy-lane")
        self.rewrite(company_doc(self.root))                                        # llm allowed again
        self.assertEqual(priv.lane_block("llm").reason, "policy-lane", "no relaxation inside a run")

    def test_a_lock_is_not_relaxed_by_a_valid_file_either(self):
        priv = self.start()
        self.rewrite("garbage")
        self.assertEqual(priv.lane_block("llm").reason, "policy-locked")
        self.rewrite(company_doc(self.root))
        self.assertEqual(priv.lane_block("llm").reason, "policy-locked")

    def test_a_deleted_policy_file_is_a_relaxation_and_ignored(self):
        priv = self.start(company_doc(self.root, lanes={"calendar": "deny"}))
        self.policy_path.unlink()
        priv._stat = make_stat_fn(self.policy_path, missing=True)                  # the loader now finds no file (and no marker): no policy
        self.assertEqual(priv.lane_block("calendar").reason, "policy-lane")
        self.assertEqual(priv.policy.state, "valid", "an absent policy is a relaxation: the one in force stays")

    def test_a_policy_that_appears_during_a_personal_run_applies_when_it_denies(self):
        self.cfg.policy_path = self.policy_path                                      # nothing there yet
        priv = lanes.resolve_run(self.cfg, None, self.src, inputs=lanes.PrivacyInputs(sleep=NOSLEEP))
        self.assertEqual(priv.policy.state, "absent")
        self.assertIsNone(priv.lane_block("llm"))
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        load_test_policy(self.policy_path, company_doc(self.root, lanes={"llm": "deny"}))
        priv._stat = make_stat_fn(self.policy_path)                                  # the injected lstat the loader reads the new file through
        self.assertEqual(priv.lane_block("llm").reason, "policy-lane")
        self.assertIsNone(priv.lane_block("drive"))

    def test_the_policy_marker_appearing_without_a_policy_file_locks_the_lanes(self):
        self.cfg.policy_path = self.policy_path
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        priv = lanes.resolve_run(self.cfg, None, self.src, inputs=lanes.PrivacyInputs(sleep=NOSLEEP))
        self.assertIsNone(priv.lane_block("llm"))
        (self.policy_path.parent / "policy.required").write_text("", encoding="utf-8")
        priv._stat = make_stat_fn(self.policy_path, missing=True, marker=self.policy_path.parent / "policy.required", marker_present=True)
        self.assertEqual(priv.lane_block("llm").reason, "policy-locked")

    def test_a_policy_that_cannot_be_examined_closes_the_lane(self):
        priv = self.start()
        real = os.lstat

        def broken(path, *a, **k):
            if str(path) == str(self.policy_path):
                raise PermissionError(13, "denied")
            return real(path, *a, **k)

        priv._stat = lambda p: (_ for _ in ()).throw(PermissionError(13, "denied"))   # what the loader reads through
        with mock.patch.object(lanes.os, "lstat", side_effect=broken):
            self.assertEqual(priv.lane_block("llm").reason, "policy-locked")

    def test_the_policy_is_read_once_per_change_not_on_every_call(self):
        priv = self.start()
        self.rewrite(company_doc(self.root, lanes={"llm": "deny"}))
        with mock.patch.object(policy, "load_org_policy", wraps=policy.load_org_policy) as loader:
            for _ in range(5):
                priv.lane_block("llm")
        self.assertEqual(loader.call_count, 1)

    def test_a_newer_policy_than_the_pipeline_understands_locks(self):
        priv = self.start()
        self.rewrite(company_doc(self.root, min_pipeline_version="99.0.0"))
        self.assertEqual(priv.lane_block("llm").reason, "policy-locked")


class RunScopeTests(NoNetworkCase):
    """The socket tripwire of a run and the nesting of runs. A real Tripwire is installed here: it wraps the blockers of
    NoNetworkCase, so what it refuses never reaches them."""

    def setUp(self):
        super().setUp()
        self.addCleanup(egress.Tripwire.uninstall_all)
        self.cfg = make_cfg(self.root)
        self.src = make_session(self.cfg)

    def decision(self, **kw) -> policy.AsrDecision:
        base = dict(primary="whisper", fallback=None, allow_egress=False, local_only=False, allow_download=True, hosts={}, consent_ids={},
                    blocked=None, reason="ok", local_capable=True, notes=(), send_vocab=False)
        base.update(kw)
        return policy.AsrDecision(**base)

    def test_the_tripwire_mode_follows_the_decision(self):
        self.assertIsNone(lanes.tripwire_mode(self.decision()))                                          # the personal default: no tripwire
        self.assertEqual(lanes.tripwire_mode(self.decision(allow_download=False)), "strict")             # local-only, the company baseline
        self.assertEqual(lanes.tripwire_mode(self.decision(allow_egress=True)), "audit")                 # an external engine
        self.assertEqual(lanes.tripwire_mode(self.decision(allow_egress=True, allow_download=False)), "audit")
        self.assertEqual(lanes.tripwire_mode(self.decision(local_only=True, allow_download=False, blocked="asr_policy_blocked")), "strict")

    def priv(self, **decision_kw) -> lanes.RunPrivacy:
        priv = lanes.resolve_run(self.cfg, None, self.src)
        priv.asr = self.decision(**decision_kw)
        return priv

    def test_a_default_run_installs_no_tripwire(self):
        with lanes.run_scope(self.priv()):
            self.assertFalse(egress.Tripwire.active())

    def test_a_strict_run_refuses_a_non_loopback_destination_and_removes_the_tripwire_afterwards(self):
        with lanes.run_scope(self.priv(allow_download=False)):
            self.assertEqual(egress.Tripwire.effective_mode(), "strict")
            with self.assertRaises(egress.EgressViolation):
                socket.getaddrinfo("example.invalid", 443)
            socket.getaddrinfo("127.0.0.1", 80)                                                         # loopback is fine
        self.assertFalse(egress.Tripwire.active())
        self.assertEqual(self.network_attempts, [])

    def test_a_run_with_an_external_engine_gets_the_audit_tripwire(self):
        with lanes.run_scope(self.priv(allow_egress=True)):
            self.assertEqual(egress.Tripwire.effective_mode(), "audit")
        self.assertFalse(egress.Tripwire.active())

    def test_runs_of_a_sweep_nest_their_tripwires(self):
        with lanes.run_scope(self.priv(allow_download=False)):
            with lanes.run_scope(self.priv(allow_egress=True)):
                self.assertEqual(egress.Tripwire.effective_mode(), "strict")                            # the strictest live install wins
            self.assertEqual(egress.Tripwire.effective_mode(), "strict")
        self.assertFalse(egress.Tripwire.active())

    def test_a_tripwire_that_cannot_be_installed_does_not_stop_the_run(self):
        with mock.patch.object(egress.Tripwire, "install", side_effect=RuntimeError("no")), self.assertLogs("mcap.lanes", level="WARNING"):
            with lanes.run_scope(self.priv(allow_download=False)) as active:
                self.assertIs(lanes.current(), active)
        self.assertIsNone(lanes.current())


class ChildEnvTests(LaneCase):
    def test_the_child_env_extras_come_from_a_valid_policy_of_the_active_run_only(self):
        org = self.put_policy(company_doc(self.root, llm={"child_env": {"DISABLE_TELEMETRY": "1", "DISABLE_AUTOUPDATER": "1"}}))
        priv = self.resolve(org)
        self.assertEqual(lanes.llm_child_env(), {})                                  # no run is active
        with lanes.run_scope(priv):
            self.assertEqual(lanes.llm_child_env(), {"DISABLE_TELEMETRY": "1", "DISABLE_AUTOUPDATER": "1"})
        self.cfg.policy_path = self.root / "no-policy" / "policy.json"
        with lanes.run_scope(lanes.resolve_run(self.cfg, None, self.src, inputs=lanes.PrivacyInputs(sleep=NOSLEEP))):
            self.assertEqual(lanes.llm_child_env(), {})                              # no policy: the allow-list it always was

    def test_a_name_outside_the_code_list_is_dropped(self):
        priv = self.resolve(self.put_policy(company_doc(self.root, llm={"child_env": {"DISABLE_TELEMETRY": "1"}})))
        object.__setattr__(priv.policy, "llm_child_env", {"DISABLE_TELEMETRY": "1", "PATH": "/evil", "ANTHROPIC_BASE_URL": "https://x"})
        with lanes.run_scope(priv):
            self.assertEqual(lanes.llm_child_env(), {"DISABLE_TELEMETRY": "1"})


class SystemPolicyHookTests(NoNetworkCase):
    """MCAP_* test hooks have no effect on a policy-managed Mac: a permissive policy named by MCAP_POLICY_PATH cannot open
    the lanes that the system policy (here: an invalid one, a test is not root) closes."""

    def test_the_policy_override_and_the_other_hooks_are_ignored_under_a_system_policy(self):
        permissive = self.root / "hook-policy.json"
        permissive.write_text(json.dumps({"schema": 1, "profile": "personal", "revision": 1}), encoding="utf-8")
        elsewhere = self.root / "elsewhere.env"
        elsewhere.write_text("SELF_NAME=Hooked\n", encoding="utf-8")
        env = {"MCAP_POLICY_PATH": str(permissive), "MCAP_CONFIG": str(elsewhere), "MCAP_LOG_DIR": str(self.root / "hook-logs"),
               "MCAP_SECURITY_BIN": str(self.security.path)}
        with mock.patch.dict(os.environ, env):
            self.system_policy(False)
            cfg = load_config()                                                      # no system policy: the hooks work (tests / e2e)
            self.assertEqual((cfg.policy_path, cfg.self_name), (permissive, "Hooked"))
            self.assertEqual(cfg.log_dir, self.root / "hook-logs")
            self.system_policy(True)                                                 # a system policy.json exists (here: not root-owned)
            cfg = load_config()
            self.assertEqual(cfg.policy_path, config.POLICY_SYSTEM_PATH)             # the hook cannot move it
            self.assertNotEqual(cfg.self_name, "Hooked")
            self.assertNotEqual(cfg.log_dir, self.root / "hook-logs")
            self.assertIsNone(config.test_hook_env("MCAP_SECURITY_BIN"))
            src = make_session(make_cfg(self.root))
            priv = lanes.resolve_run(cfg, None, src, inputs=lanes.PrivacyInputs(sleep=NOSLEEP))
        self.assertTrue(priv.policy.locked)
        self.assertEqual({lane: priv.lane_block(lane).reason for lane in policy.LANES}, {lane: "policy-locked" for lane in policy.LANES})
        self.assertTrue(priv.local_only.value)


class PackageNamespaceTests(unittest.TestCase):
    """``mcap.lanes`` is looked up in sys.modules on every access (mcap/__init__.py), so a test of another module can stand in for it."""

    def test_the_package_version_is_the_one_the_swift_contract_asks_for(self):
        import mcap
        self.assertEqual(mcap.__version__, "0.2.0")

    def test_the_lane_module_is_what_sys_modules_says_it_is(self):
        import mcap
        real = sys.modules["mcap.lanes"]
        self.assertIs(mcap.lanes, real)
        self.assertIs(lanes, real)
        self.assertNotIn("lanes", vars(mcap))                                        # not stored in the package namespace
        with mock.patch.dict(sys.modules, {"mcap.lanes": None}):
            self.assertFalse(hasattr(mcap, "lanes"))
            with self.assertRaises(ImportError):
                from mcap import lanes as missing  # noqa: F401
        stand_in = SimpleNamespace(gate=lambda lane: None)
        with mock.patch.dict(sys.modules, {"mcap.lanes": stand_in}):
            from mcap import lanes as substituted
            self.assertIs(substituted, stand_in)
        self.assertIs(mcap.lanes, real)
        from mcap import lanes as again
        self.assertIs(again, real)

    def test_other_submodules_stay_ordinary_attributes(self):
        import mcap
        from mcap import policy as module
        self.assertIs(mcap.policy, module)
        self.assertIn("policy", vars(mcap))


if __name__ == "__main__":
    unittest.main()
