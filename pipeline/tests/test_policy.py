"""Organisation policy, local-only flag, lanes, consents, hardware probe and the ASR decision table (SPEC 18). Nothing here touches the real SUPPORT_DIR, the real /Library policy, the Keychain or the network: every policy file lives
in a temp dir and the file owner / mode / type the loader sees is INJECTED through ``stat_fn`` (a test cannot be root), every subprocess is a
fake ``run``, every clock is passed in.

The shared corpus ``config/policy-fixtures/`` (index.json + fixture files) is read here and by the Swift selftest: both must reach the same
verdicts. ``test_policy_matrix.py`` checks the decision functions against an independent oracle; ``test_config_privacy.py`` the config side.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import re
import stat
import sys
import time
import unicodedata
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import policy  # noqa: E402
from mcap.config import Config  # noqa: E402
from notes_cli_support import TempCase, _st, load_test_policy, make_cfg, make_session, make_stat_fn  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "config" / "policy-fixtures"
NOW = datetime(2026, 10, 14, 12, 0, 0).astimezone()
CA = "a" * 64
BUILD = "b" * 64
RELAY = "asr.example.internal"
AZURE_HOST = "koreacentral.api.cognitive.microsoft.com"
MACHINE = "m" * 64


# ---------------------------------------------------------------------------------------------------- helpers
def minimal(profile="personal", **extra) -> dict:
    doc = {"schema": 1, "profile": profile, "revision": 1}
    doc.update(extra)
    return doc


def company(**extra) -> dict:
    return minimal("company", **extra)


NOSLEEP = lambda s: None  # noqa: E731


@contextlib.contextmanager
def working_directory(path):
    """chdir for the length of a block (the process-wide cwd is what a relative path would silently be read against)."""
    before = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(before)


class PolicyCase(TempCase):
    """A temp dir with a policy.json written by ``put`` and read by ``load`` through an injected lstat (root-owned, 0644, by default)."""

    def setUp(self):
        super().setUp()
        self.path = self.root / "etc" / "policy.json"
        self.path.parent.mkdir(parents=True)
        self.sleeps = []

    def put(self, doc, *, raw=None):
        if raw is not None:
            self.path.write_bytes(raw)
        else:
            self.path.write_text(doc if isinstance(doc, str) else json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return self.path

    def load(self, doc=None, *, raw=None, version="0.2.0", marker=False, **stat_kw):
        if doc is not None or raw is not None:
            self.put(doc, raw=raw)
        marker_path = self.path.parent / "policy.required"
        fn = make_stat_fn(self.path, marker=marker_path, marker_present=marker, missing=(doc is None and raw is None), **stat_kw)
        return policy.load_org_policy(self.path, required_marker=marker_path, stat_fn=fn, current_version=version,
                                      sleep=lambda s: self.sleeps.append(s))

    def assertLocked(self, pol, code):
        self.assertTrue(pol.locked, pol.locked_reason)
        self.assertEqual(pol.state, "invalid")
        self.assertTrue((pol.locked_reason or "").startswith(code), f"{code!r} not at the start of {pol.locked_reason!r}")
        self.assertEqual(set(pol.lanes.values()), {"deny"})
        self.assertEqual(set(pol.lane_reasons.values()), {"policy-locked"})


def corpus() -> dict:
    return json.loads((FIXTURES / "index.json").read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------------------------------- version
class VersionTests(unittest.TestCase):
    def test_tuple_of_ints_not_text(self):
        self.assertEqual(policy.parse_version("0.2.0"), (0, 2, 0))
        self.assertGreater(policy.parse_version("0.10.0"), policy.parse_version("0.2.0"))      # '0.10.0' < '0.2.0' as text
        self.assertEqual(policy.parse_version(" 1.0 "), (1, 0))
        for bad in ("", "x", "1..2", "1.2.3.4.5", "-1.0", "1.0-beta", "v1.0", "1.0.0 ", None, 3):
            if bad == "1.0.0 ":
                continue                                         # surrounding blanks are trimmed
            with self.assertRaises(ValueError, msg=repr(bad)):
                policy.parse_version(bad)

    def test_only_ascii_digits_count_and_only_ascii_spaces_pad(self):
        """``\\d`` matches every Unicode digit and ``strip()`` every Unicode space: a fullwidth version would be read here and not by Swift."""
        for bad in ("\uff10.\uff12.\uff10", "\u0660.\u0662", "\u0967", "0.2.0\u00a0", "\u30000.2.0", "0.2.0\n", "\t0.2.0"):
            with self.assertRaises(ValueError, msg=repr(bad)):
                policy.parse_version(bad)
        self.assertEqual(policy.parse_version("  0.2.0  "), (0, 2, 0))
        self.assertIsNone(policy._expiry("\uff12\uff10\uff12\uff17-\uff11\uff10-\uff11\uff14"))          # a date is ASCII digits too

    def test_shorter_tuples_are_padded(self):
        self.assertFalse(policy._version_less((0, 2), (0, 2, 0)))
        self.assertFalse(policy._version_less((0, 2, 0), (0, 2)))
        self.assertTrue(policy._version_less((0, 2), (0, 2, 1)))
        self.assertTrue(policy._version_less((0, 9, 9), (0, 10)))


# ---------------------------------------------------------------------------------------------------- the shared corpus
class CorpusTests(PolicyCase):
    """Every case of config/policy-fixtures/index.json: the same verdict the Swift selftest has to reach."""

    def build_bytes(self, row) -> bytes:
        if "content" in row:
            data = row["content"].encode("utf-8")
        elif "content_hex" in row:
            data = bytes.fromhex(row["content_hex"])
        else:
            data = (FIXTURES / row["file"]).read_bytes()
        if row.get("strip_prefix_hex"):
            lead = bytes.fromhex(row["strip_prefix_hex"])
            self.assertTrue(data.startswith(lead), row["id"])
            data = data[len(lead):]
        data = bytes.fromhex(row.get("prefix_hex", "")) + data + bytes.fromhex(row.get("append_hex", ""))
        if "truncate_to" in row:
            data = data[:row["truncate_to"]]
        return data

    def stat_kwargs(self, row, defaults, data) -> dict:
        info = dict(defaults["file_info"], **row.get("file_info", {}))
        ancestor = dict(defaults["ancestor_info"], **row.get("ancestor_info", {}))
        kwargs = dict(kind="file", uid=info["uid"], mode=int(info["mode"], 8), size=info.get("size", len(data)), ancestor_uid=ancestor["uid"],
                      ancestor_mode=int(ancestor["mode"], 8), ancestor_kind=ancestor.get("type", "directory"))
        if info["type"] == "error":
            kwargs["error"] = PermissionError(13, "Permission denied")
        else:
            kwargs["kind"] = {"file": "file", "symlink": "symlink", "directory": "directory"}[info["type"]]
        return kwargs

    def test_every_case(self):
        doc = corpus()
        self.assertEqual(doc["schema"], 1)
        defaults = doc["defaults"]
        self.assertGreaterEqual(len(doc["cases"]), 80)
        seen = set()
        for row in doc["cases"]:
            self.assertNotIn(row["id"], seen)
            seen.add(row["id"])
            with self.subTest(case=row["id"]):
                version = row.get("pipeline_version", defaults["pipeline_version"])
                marker = row.get("marker", defaults["marker"])
                self.assertEqual(len([key for key in ("file", "content", "content_hex") if key in row]), 1, row["id"])
                if "file" in row and row["file"] is None:
                    pol = self.load(None, version=version, marker=marker)
                else:
                    data = self.build_bytes(row)
                    pol = self.load(raw=data, version=version, marker=marker, **self.stat_kwargs(row, defaults, data))
                self.check(row["id"], row["expect"], pol, defaults)

    def check(self, cid, expect, pol, defaults):
        if expect["state"] == "invalid":
            expect = dict(defaults["invalid_expect"], **expect)
        self.assertEqual(pol.state, expect["state"], f"{cid}: {pol.locked_reason}")
        if expect["state"] == "invalid":
            self.assertIn(expect["reason"], pol.locked_reason or "", cid)
        else:
            self.assertIsNone(pol.locked_reason, cid)
        self.assertEqual(dict(pol.lanes), expect["lanes"], cid)
        self.assertEqual(pol.local_only_default, expect["local_only_default"], cid)
        self.assertEqual(pol.local_only_locked, expect["local_only_locked"], cid)
        self.assertEqual(pol.recording_enabled, expect["recording_enabled"], cid)
        if "profile" in expect:
            self.assertEqual(pol.profile, expect["profile"], cid)
        if "revision" in expect:
            self.assertEqual(pol.revision, expect["revision"], cid)
        for key, field in (("allowed_engines", "allowed_engines"), ("allowed_hosts", "allowed_hosts"),
                           ("archive_allowed_roots", "archive_allowed_roots"), ("local_roots", "local_roots")):
            if key in expect:
                want = None if expect[key] is None else tuple(expect[key])
                self.assertEqual(getattr(pol, field), want, f"{cid}: {key}")
        for lane, reason in expect.get("lane_reasons", {}).items():
            self.assertEqual(pol.lane_reasons[lane], reason, f"{cid}: {lane}")
        if "enforced" in expect:
            self.assertEqual(dict(pol.enforced), expect["enforced"], f"{cid}: enforced")
        elif expect["state"] == "absent":
            self.assertEqual(dict(pol.enforced), {}, f"{cid}: enforced")
        elif expect["state"] == "invalid":
            self.assertEqual(dict(pol.enforced), defaults["company_baseline_enforced"], f"{cid}: enforced")      # a lock keeps the baseline

    def test_corpus_files_are_what_the_index_says(self):
        """Every fixture file is used by a case, every case file exists (a stale index would let Swift and Python agree on nothing)."""
        used = {row["file"] for row in corpus()["cases"] if row.get("file")}
        on_disk = {p.name for p in FIXTURES.iterdir() if p.name not in ("index.json", "archive_roots_cases.json")}
        self.assertEqual(used, on_disk)

    def test_every_reason_code_has_a_case_and_the_list_is_the_one_the_code_can_produce(self):
        """The index says which codes the Swift parser must produce; a code with no case is a code nobody checks."""
        doc = corpus()
        listed, uncovered = set(doc["reason_codes"]), set(doc["reason_codes_without_a_case"])
        expected = {row["expect"]["reason"] for row in doc["cases"] if row["expect"]["state"] == "invalid"}
        self.assertEqual(expected - listed, set(), "a case expects a code the index does not list")
        self.assertEqual(listed - expected, uncovered)
        self.assertEqual(expected & uncovered, set())
        source = (REPO / "pipeline" / "mcap" / "policy.py").read_text(encoding="utf-8")
        produced = set(re.findall(r'_Invalid\("([a-z0-9-]+)"', source)) | set(re.findall(r'_locked_policy\("([a-z0-9-]+)', source))
        self.assertEqual(produced, listed)

    def test_the_baseline_in_the_index_is_the_one_in_the_code(self):
        self.assertEqual(corpus()["defaults"]["company_baseline_enforced"], policy.COMPANY_BASELINE_ENFORCED)

    def test_bom_file_really_has_a_bom_and_a_duplicate_key(self):
        data = (FIXTURES / "invalid_bom_duplicate_key.json").read_bytes()
        self.assertTrue(data.startswith(b"\xef\xbb\xbf"))
        self.assertEqual(data.decode("utf-8-sig").count('"lanes"'), 2)

    def test_the_inline_cases_say_what_they_mean(self):
        """A type-confusion case is only worth something when the text really holds the confusing value (JSON in JSON is easy to get wrong)."""
        by_id = {row["id"]: row for row in corpus()["cases"]}
        self.assertEqual(json.loads(by_id["type_local_only_locked_int"]["content"])["local_only"]["locked"], 0)
        self.assertIs(type(json.loads(by_id["type_local_only_locked_int"]["content"])["local_only"]["locked"]), int)
        self.assertIs(json.loads(by_id["schema_true"]["content"])["schema"], True)
        self.assertIs(type(json.loads(by_id["schema_float"]["content"])["schema"]), float)
        self.assertIs(type(json.loads(by_id["revision_float"]["content"])["revision"]), float)
        self.assertIn("NaN", by_id["nan_revision"]["content"])
        self.assertIn("1e999", by_id["overflowing_number_in_ext"]["content"])
        self.assertEqual(json.loads(by_id["version_fullwidth_digits"]["content"])["min_pipeline_version"], "\uff10.\uff12.\uff10")
        self.assertEqual(json.loads(by_id["version_no_break_space_padding"]["content"])["min_pipeline_version"], "0.2.0\u00a0")
        with self.assertRaises(UnicodeDecodeError):
            bytes.fromhex(by_id["not_utf8"]["content_hex"]).decode("utf-8")
        self.assertIsInstance(json.loads(by_id["top_level_array"]["content"]), list)


# ---------------------------------------------------------------------------------------------------- loading
class LoadTests(PolicyCase):
    def test_no_file_no_marker_is_absent_and_open(self):
        pol = self.load(None)
        self.assertEqual((pol.present, pol.valid, pol.locked, pol.state), (False, False, False, "absent"))
        self.assertEqual(set(pol.lanes.values()), {"allow"})
        self.assertIsNone(pol.allowed_hosts)
        self.assertEqual(self.sleeps, [])                   # nothing to wait for

    def test_marker_without_file_locks(self):
        pol = self.load(None, marker=True)
        self.assertLocked(pol, "required-missing")
        self.assertEqual(self.sleeps, [0.5])                # confirmed once, like every lock

    def test_marker_with_a_valid_file_is_valid(self):
        self.assertTrue(self.load(minimal(), marker=True).valid)

    def test_default_marker_is_next_to_the_file(self):
        (self.path.parent / "policy.required").write_text("")
        fn = make_stat_fn(self.path, missing=True, marker=self.path.parent / "policy.required", marker_present=True)
        pol = policy.load_org_policy(self.path, stat_fn=fn, sleep=NOSLEEP)
        self.assertLocked(pol, "required-missing")

    def test_path_none_uses_the_system_location(self):
        seen = []

        def fn(p):
            seen.append(Path(p))
            raise FileNotFoundError(p)
        pol = policy.load_org_policy(stat_fn=fn, sleep=NOSLEEP)
        self.assertEqual(pol.state, "absent")
        from mcap import config
        self.assertIn(config.POLICY_SYSTEM_PATH, seen)
        self.assertIn(config.POLICY_REQUIRED_MARKER, seen)

    def test_real_lstat_of_a_user_owned_file_is_a_lock(self):
        if os.geteuid() == 0:
            self.skipTest("running as root")
        self.put(minimal())
        pol = policy.load_org_policy(self.path, stat_fn=os.lstat, sleep=NOSLEEP, current_version="0.2.0")
        self.assertLocked(pol, "bad-owner")

    def test_valid_personal_defaults(self):
        pol = self.load(minimal())
        self.assertTrue(pol.valid)
        self.assertEqual((pol.profile, pol.revision), ("personal", 1))
        self.assertEqual(dict(pol.lanes), {lane: "allow" for lane in policy.LANES})
        self.assertEqual(pol.lane_reasons, {})
        self.assertIsNone(pol.allowed_engines)
        self.assertIsNone(pol.allowed_hosts)
        self.assertIsNone(pol.archive_allowed_roots)
        self.assertEqual(pol.local_roots, ())
        self.assertFalse(pol.allow_foreign)
        self.assertIsNone(pol.daily_audio_minutes_cap)
        self.assertEqual(dict(pol.send_vocab), {"server": True, "cloud": True})
        self.assertEqual((pol.local_only_default, pol.local_only_locked, pol.recording_enabled), (False, False, True))
        self.assertEqual((dict(pol.defaults), dict(pol.enforced)), ({}, {}))          # personal: no baseline
        self.assertIsNone(pol.claude_bin_pin)
        self.assertIsNone(pol.runtime_root)

    def test_valid_company_baseline(self):
        pol = self.load(company())
        self.assertTrue(pol.valid)
        self.assertEqual(set(pol.lanes.values()), {"deny"})                         # omitted lanes deny
        self.assertEqual(set(pol.lane_reasons.values()), {"policy-lane"})
        self.assertEqual((pol.allowed_engines, pol.allowed_hosts, pol.archive_allowed_roots), ((), (), ()))   # empty, not unrestricted
        self.assertEqual(dict(pol.send_vocab), {"server": True, "cloud": False})
        self.assertEqual(dict(pol.enforced), {"LOG_CONTENT": "0", "ASR_ALLOW_DOWNLOAD": "0", "MIC_MUTE_GATE": "on", "NOTIFY_RECORDING": "1"})

    def test_company_baseline_is_overridden_only_by_naming_the_key_in_enforced(self):
        pol = self.load(company(defaults={"LOG_CONTENT": "1", "ASR_ENGINE": "auto"}, enforced={"MIC_MUTE_GATE": "off", "AUDIO_RETENTION_DAYS": "30"}))
        self.assertEqual(pol.enforced["LOG_CONTENT"], "0")                           # a default cannot undo the baseline
        self.assertEqual(pol.enforced["MIC_MUTE_GATE"], "off")                       # named in enforced: overridden
        self.assertEqual(pol.enforced["ASR_ALLOW_DOWNLOAD"], "0")
        self.assertEqual(pol.enforced["AUDIO_RETENTION_DAYS"], "30")
        self.assertEqual(dict(pol.defaults), {"LOG_CONTENT": "1", "ASR_ENGINE": "auto"})

    def test_company_lane_rules(self):
        lanes = {lane: "allow" for lane in policy.LANES}
        pol = self.load(company(lanes=lanes))
        self.assertEqual(pol.lanes["asr_remote"], "allow")                           # no approval needed
        for lane in ("asr_cloud", "llm", "calendar", "drive"):
            self.assertEqual((pol.lanes[lane], pol.lane_reasons[lane]), ("deny", "policy-unapproved"), lane)
        approvals = {"asr_cloud": "L-1", "llm": "L-2", "calendar": "L-3", "drive": "L-4"}
        pol = self.load(company(lanes=lanes, approvals=approvals))
        self.assertEqual({k: v for k, v in pol.lanes.items()}, dict(lanes, llm="deny"))      # llm still needs a pin
        self.assertEqual(pol.lane_reasons, {"llm": "policy-claude-unpinned"})
        pol = self.load(company(lanes=lanes, approvals=approvals, llm={"claude_bin_pin": {"team_id": "ABCDE12345"}}))
        self.assertEqual(set(pol.lanes.values()), {"allow"})
        self.assertEqual(pol.claude_bin_pin, {"team_id": "ABCDE12345"})

    def test_personal_ignores_approvals_and_pin(self):
        pol = self.load(minimal(lanes={"llm": "allow", "drive": "allow"}))
        self.assertEqual((pol.lanes["llm"], pol.lanes["drive"]), ("allow", "allow"))

    def test_lane_value_other_than_allow_is_deny_for_that_lane_only(self):
        for odd in ("Allow", "ALLOW", "yes", "", "deny", "denyy", 1, True, None, [], {}, 0.5):
            with self.subTest(value=repr(odd)):
                pol = self.load(minimal(lanes={"llm": odd, "drive": "allow"}))
                self.assertTrue(pol.valid)
                self.assertEqual((pol.lanes["llm"], pol.lanes["drive"]), ("deny", "allow"))

    def test_approval_reference_rules(self):
        lanes = {"drive": "allow"}
        self.assertEqual(self.load(company(lanes=lanes, approvals={"drive": "  "})).lane_reasons["drive"], "policy-unapproved")
        self.assertEqual(self.load(company(lanes=lanes, approvals={"drive": ""})).lane_reasons["drive"], "policy-unapproved")
        self.assertEqual(self.load(company(lanes=lanes, approvals={"drive": " T-1 "})).lanes["drive"], "allow")
        self.assertLocked(self.load(company(lanes=lanes, approvals={"drive": 5})), "bad-type")
        self.assertLocked(self.load(company(lanes=lanes, approvals={"drive": "x" * 81})), "bad-value")
        self.assertTrue(self.load(company(lanes=lanes, approvals={"drive": "x" * 80})).valid)
        self.assertLocked(self.load(company(approvals={"asr_remote": "T-1"})), "unknown-key")     # asr_remote has no approval

    def test_local_only_and_recording_fields(self):
        pol = self.load(minimal(local_only={"default": True, "locked": True}, recording={"enabled": False}))
        self.assertEqual((pol.local_only_default, pol.local_only_locked, pol.recording_enabled), (True, True, False))
        pol = self.load(minimal(local_only={"default": True}))
        self.assertEqual((pol.local_only_default, pol.local_only_locked), (True, False))

    def test_asr_section(self):
        pol = self.load(minimal(asr={"allowed_engines": ["Whisper", " Remote "], "allowed_hosts": ["ASR.Example.Internal"], "allow_foreign": True,
                                    "daily_audio_minutes_cap": 90, "send_vocab": {"cloud": False}}))
        self.assertEqual(pol.allowed_engines, ("whisper", "remote"))
        self.assertEqual(pol.allowed_hosts, (RELAY,))
        self.assertEqual((pol.allow_foreign, pol.daily_audio_minutes_cap), (True, 90))
        self.assertEqual(dict(pol.send_vocab), {"server": True, "cloud": False})
        pol = self.load(company(asr={"allowed_engines": [], "allowed_hosts": ["h.example"]}))
        self.assertEqual((pol.allowed_engines, pol.allowed_hosts), ((), ("h.example",)))      # an explicit empty list stays empty

    def test_archive_and_runtime_sections(self):
        pol = self.load(company(archive={"allowed_roots": ["~/a/*/b"], "local_roots": ["/x"]}, runtime={"root": "/Library/MC/releases"}))
        self.assertEqual((pol.archive_allowed_roots, pol.local_roots, pol.runtime_root), (("~/a/*/b",), ("/x",), "/Library/MC/releases"))
        self.assertIsNone(self.load(minimal(runtime={"root": "/Library/MC/releases"})).runtime_root)   # company only
        pol = self.load(minimal(archive={"allowed_roots": []}))
        self.assertEqual(pol.archive_allowed_roots, ())

    def test_archive_roots_must_be_anchored(self):
        """A relative root is read against the working directory, which differs between the app (its own folder) and a shell: the same policy
        would open or close the Drive lane depending on who asks, and '*' or '.' would match whatever sits under the cwd."""
        for key in ("allowed_roots", "local_roots"):
            for bad in ("Meetings", "*", ".", "..", "../x", "./x", "a/b", "*/x", "Drive/*", "~user/x", "~root", "~x", "GoogleDrive-*"):
                with self.subTest(key=key, root=bad):
                    self.assertEqual(self.load(company(archive={key: [bad]})).locked_reason, f"bad-value: archive.{key}[0]")
            self.assertEqual(self.load(company(archive={key: ["~/ok", "relative"]})).locked_reason, f"bad-value: archive.{key}[1]")
            self.assertEqual(self.load(minimal(archive={key: ["/ok", " relative"]})).locked_reason, f"bad-value: archive.{key}[1]")   # the profile does not matter
        good = ["/abs", "/a/*/b", "~", "~/Meetings", "~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"]
        pol = self.load(company(archive={"allowed_roots": good, "local_roots": good}))
        self.assertEqual((pol.archive_allowed_roots, pol.local_roots), (tuple(good), tuple(good)))
        self.assertEqual(self.load(minimal(archive={"allowed_roots": ["  ~/x  "]})).archive_allowed_roots, ("~/x",))   # trimmed first, like every string list
        self.assertEqual(self.load(minimal(archive={"allowed_roots": [], "local_roots": []})).archive_allowed_roots, ())    # an empty list is not a root
        for text, anchored in (("/x", True), ("~", True), ("~/x", True), ("", False), ("x", False), ("~x", False), ("~root/x", False), (" /x", False),
                               ("*", False), (".", False), ("./x", False), ("../x", False), (None, False), (5, False)):
            self.assertIs(policy.anchored_path(text), anchored, repr(text))

    def test_a_version_is_ascii_digits_and_dots_in_the_policy_too(self):
        for bad in ("\uff10.\uff12.\uff10", "\u0660.\u0662.\u0660", "0.2.0\u00a0", "\u30000.2.0", "\u2003", "latest", "1.2.3.4.5", "0.2.0-beta"):
            with self.subTest(version=bad):
                self.assertLocked(self.load(minimal(min_pipeline_version=bad)), "bad-value")
        self.assertTrue(self.load(minimal(min_pipeline_version=" 0.2.0 ")).valid)                     # ASCII spaces around it are padding
        item = {"engine": "remote", "host": RELAY, "protocol": "mcap-asr/1", "backend_kind": "server", "ca_sha256": CA, "attest_build_sha256": [BUILD],
                "use": "both", "expires": "\uff12\uff10\uff12\uff17-\uff11\uff10-\uff11\uff14"}
        self.assertLocked(self.load(company(asr={"org_consents": [item]})), "bad-value")             # a fullwidth date is no date

    def test_a_number_that_is_not_finite_locks_wherever_it_sits(self):
        head = '{"schema":1,"profile":"personal",'
        for literal in ("NaN", "Infinity", "-Infinity", "1e999", "-1e999", "1E400", "1.5e9999"):
            for text in (head + '"revision":%s}', head + '"revision":1,"ext":{"x":[%s]}}', head + '"revision":1,"asr":{"daily_audio_minutes_cap":%s}}'):
                with self.subTest(literal=literal, where=text[len(head):]):
                    self.assertLocked(self.load(text % literal), "bad-json")
        self.assertEqual(self.load(head + '"revision":1,"ext":{"x":[1e5, 2.5, -0.0, 1E3]}}').revision, 1)       # a finite float in ext is fine
        self.assertTrue(self.load(head + '"revision":1,"ext":{"x":[1e5, 2.5, -0.0, 1E3]}}').valid)

    def test_llm_pin_and_child_env(self):
        self.assertEqual(self.load(company(llm={"claude_bin_pin": {"sha256": "AB" * 32}})).claude_bin_pin, {"sha256": "ab" * 32})
        pol = self.load(company(llm={"child_env": {"DISABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}}))
        self.assertEqual(dict(pol.llm_child_env), {"DISABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
        self.assertLocked(self.load(company(llm={"child_env": {"PATH": "/x"}})), "unknown-key")           # names come from a code allow-list
        self.assertLocked(self.load(company(llm={"child_env": {"DISABLE_TELEMETRY": 1}})), "bad-type")
        for bad in ({"team_id": "short"}, {"team_id": "abcde12345"}, {"sha256": "zz"}, {"team_id": "ABCDE12345", "sha256": "a" * 64}, {}):
            self.assertLocked(self.load(company(llm={"claude_bin_pin": bad})), "bad-value")

    def test_org_consents_parse(self):
        item = {"engine": "remote", "host": "ASR.Example.Internal", "port": 8443, "protocol": "mcap-asr/1", "backend_kind": "server",
                "ca_sha256": CA.upper(), "attest_build_sha256": [BUILD], "use": "both", "expires": "2027-10-14"}
        pol = self.load(company(asr={"org_consents": [item]}))
        oc = pol.org_consents[0]
        self.assertEqual((oc.engine, oc.host, oc.port, oc.use, oc.expires), ("remote", RELAY, 8443, "both", "2027-10-14"))
        self.assertEqual((oc.ca_sha256, oc.attest_build_sha256), (CA, (BUILD,)))
        self.assertTrue(oc.id.startswith("org:remote-"))
        self.assertLocked(self.load(company(asr={"org_consents": [dict(item, port=None)]})), "bad-type")
        del item["port"]
        self.assertEqual(self.load(company(asr={"org_consents": [item]})).org_consents[0].port, 443)       # default port
        bad = [dict(item, ca_sha256="abc"), dict(item, use="always"), dict(item, expires="2027-13-40"), dict(item, expires="next year"),
               dict(item, backend_kind="cloud"), dict(item, host="a b"), dict(item, attest_build_sha256=["zz"]), dict(item, port=0),
               dict(item, port=70000), dict(item, engine="")]
        for entry in bad:
            with self.subTest(entry=entry):
                self.assertLocked(self.load(company(asr={"org_consents": [entry]})), "bad-value")
        for key in ("engine", "host", "protocol", "backend_kind", "ca_sha256", "attest_build_sha256", "use", "expires"):
            partial = {k: v for k, v in item.items() if k != key}
            self.assertLocked(self.load(company(asr={"org_consents": [partial]})), "bad-value")             # every field but port is required
        self.assertLocked(self.load(company(asr={"org_consents": [dict(item, extra=1)]})), "unknown-key")
        self.assertLocked(self.load(company(asr={"org_consents": {"engine": "remote"}})), "bad-type")

    def test_org_consent_id_is_stable_and_binding_specific(self):
        base = policy.OrgConsent("remote", RELAY, 443, "mcap-asr/1", "server", "both", "2027-10-14", CA, (BUILD,))
        self.assertEqual(base.id, dataclasses.replace(base, expires="2030-01-01").id)           # the expiry is not part of the identity
        self.assertNotEqual(base.id, dataclasses.replace(base, host="other.internal").id)
        self.assertNotEqual(base.id, dataclasses.replace(base, ca_sha256="c" * 64).id)

    def test_ext_is_free_form(self):
        for ext in ({}, {"ring": "pilot"}, {"a": {"b": {"unknown_key_anywhere": [1, {"x": None}]}}}, [1, 2], "text", 5, None, True):
            with self.subTest(ext=repr(ext)):
                self.assertTrue(self.load(company(ext=ext)).valid)

    def test_issued_support_and_min_version_fields(self):
        pol = self.load(minimal(issued="2026-10-14T09:00:00+09:00", support={"contact": "IT 헬프데스크 #it-help"}, min_pipeline_version="0.2.0"))
        self.assertEqual((pol.support_contact, pol.min_pipeline_version), ("IT 헬프데스크 #it-help", "0.2.0"))
        self.assertLocked(self.load(minimal(issued=5)), "bad-type")
        self.assertLocked(self.load(minimal(support={"contact": "x" * 61})), "bad-value")
        self.assertLocked(self.load(minimal(support={"contact": "two\nlines"})), "bad-value")
        self.assertLocked(self.load(minimal(support={"contact": "  "})), "bad-value")
        self.assertLocked(self.load(minimal(support={"contact": 7})), "bad-type")
        for bad in ("latest", "0.2.x", "", 2, "1..0"):
            self.assertLocked(self.load(minimal(min_pipeline_version=bad)), "bad-")

    def test_min_pipeline_version_compares_as_tuple_of_ints(self):
        doc = minimal(min_pipeline_version="0.10.0")
        self.assertLocked(self.load(doc, version="0.2.0"), "pipeline-too-old")           # text compare would say 0.2.0 > 0.10.0
        self.assertTrue(self.load(doc, version="0.10.0").valid)
        self.assertTrue(self.load(doc, version="0.10.1").valid)
        self.assertTrue(self.load(doc, version="1.0.0").valid)
        self.assertTrue(self.load(minimal(min_pipeline_version="0.2.0"), version="0.2").valid)       # padded
        self.assertLocked(self.load(minimal(min_pipeline_version="0.2.1"), version="0.2"), "pipeline-too-old")
        self.assertLocked(self.load(doc, version="garbage"), "pipeline-too-old")                     # an unreadable version is too old

    def test_current_version_defaults_to_the_package_version(self):
        import mcap
        self.put(minimal(min_pipeline_version=mcap.__version__))
        fn = make_stat_fn(self.path)
        self.assertTrue(policy.load_org_policy(self.path, stat_fn=fn, sleep=NOSLEEP).valid)
        self.put(minimal(min_pipeline_version="99.0.0"))
        self.assertLocked(policy.load_org_policy(self.path, stat_fn=fn, sleep=NOSLEEP), "pipeline-too-old")

    def test_defaults_and_enforced_layers(self):
        pol = self.load(minimal(defaults={"ASR_ENGINE": "auto", "LOG_RETENTION_DAYS": "30", "ENABLED_PLATFORMS": "zoom"},
                                enforced={"AUDIO_RETENTION_DAYS": "90", "LOG_CONTENT": "maybe", "APP_LOG_MAX_MB": "5"}))
        self.assertEqual(dict(pol.defaults), {"ASR_ENGINE": "auto", "LOG_RETENTION_DAYS": "30", "ENABLED_PLATFORMS": "zoom"})
        self.assertEqual(pol.enforced["LOG_CONTENT"], "maybe")                    # unknown switch text is the restrictive value, not a lock
        for forbidden in sorted(policy.FORBIDDEN_LAYER_KEYS):
            for layer in ("defaults", "enforced"):
                with self.subTest(key=forbidden, layer=layer):
                    self.assertLocked(self.load(minimal(**{layer: {forbidden: "x"}})), "forbidden-key")
        self.assertLocked(self.load(minimal(defaults={"ASR_ENGIN": "auto"})), "unknown-key")
        self.assertLocked(self.load(minimal(enforced={"CLAUDE_KEY_SERVICE": "x"})), "unknown-key")
        self.assertLocked(self.load(minimal(defaults={"ASR_RETRY_MAX": 3})), "bad-type")
        self.assertLocked(self.load(minimal(defaults={"ASR_RETRY_MAX": "three"})), "bad-value")
        self.assertLocked(self.load(minimal(enforced={"ASR_LOCAL_MAX_RTF": "nan"})), "bad-value")
        self.assertLocked(self.load(minimal(enforced={"AUDIO_RETENTION_DAYS": "ten"})), "bad-value")
        self.assertLocked(self.load(minimal(enforced={"ASR_RETRY_MAX": "0"})), "bad-value")                 # the config parser's own range
        self.assertLocked(self.load(minimal(enforced={"AUDIO_RETENTION_DAYS": ""})), "bad-value")
        self.assertLocked(self.load(minimal(enforced={"AUDIO_RETENTION_DAYS": "1\n2"})), "bad-value")
        self.assertLocked(self.load(minimal(defaults=["ASR_ENGINE"])), "bad-type")

    def test_call_detection_keys_are_policy_keys(self):
        # Calls of other apps (CALL_DETECT and friends, Swift-only keys): an organisation can set them in defaults or enforce them. They were once missing, so a
        # company baseline of ENABLED_PLATFORMS=zoom,teams could not keep the app from recording other call apps.
        keys = ("CALL_DETECT", "CALL_GENERIC_SECONDS", "EXTRA_MEETING_APPS", "CALL_BROWSER_URLS")
        for key in keys:
            self.assertIn(key, policy.DEFAULTS_WHITELIST)
        pol = self.load(minimal(defaults={"CALL_GENERIC_SECONDS": "90"},
                                enforced={"CALL_DETECT": "off", "CALL_BROWSER_URLS": "0", "EXTRA_MEETING_APPS": "com.example.talk=Talk"}))
        self.assertTrue(pol.valid)
        self.assertEqual(pol.enforced["CALL_DETECT"], "off")
        self.assertEqual(dict(pol.defaults), {"CALL_GENERIC_SECONDS": "90"})
        self.assertLocked(self.load(minimal(enforced={"CALL_DETECTS": "off"})), "unknown-key")           # a typo is still a lock
        self.assertLocked(self.load(minimal(enforced={"CALL_DETECT": 0})), "bad-type")                    # values are strings

    def test_whitelist_is_closed_and_consistent(self):
        from mcap import config
        self.assertFalse(policy.DEFAULTS_WHITELIST & policy.FORBIDDEN_LAYER_KEYS)
        for key in ("ARCHIVE_DIR", "PROJECT_DIR", "PYTHON_BIN", "CLAUDE_BIN", "SUPPORT_DIR", "SELF_NAME", "LOCAL_ARCHIVE_DIR"):
            self.assertNotIn(key, policy.DEFAULTS_WHITELIST)
        for key in ("LOG_CONTENT", "ASR_ALLOW_DOWNLOAD", "MIC_MUTE_GATE", "NOTIFY_RECORDING", "ASR_ENGINE", "AUDIO_RETENTION_DAYS", "ASR_MODEL"):
            self.assertIn(key, policy.DEFAULTS_WHITELIST)
        for key in policy.COMPANY_BASELINE_ENFORCED:
            self.assertIn(key, policy.DEFAULTS_WHITELIST)
        self.assertTrue(policy.DEFAULTS_WHITELIST - set(config._KEYS) <= set("""NOTIFY_RECORDING ENABLED_PLATFORMS BROWSER_BUNDLE_IDS
            POLL_INTERVAL_SECONDS START_DEBOUNCE_SECONDS GRACE_SECONDS MIN_RECORDING_SECONDS MAX_RECORDING_HOURS MIN_FREE_DISK_GB
            NO_SPEECH_STOP_MINUTES RETRY_SWEEP_HOURS SYSTEM_AUDIO_MODE ZOOM_STRONG_SOCKETS ZOOM_WEAK_DEBOUNCE_SECONDS
            CALL_DETECT CALL_GENERIC_SECONDS EXTRA_MEETING_APPS CALL_BROWSER_URLS""".split()))  # Swift-only keys

    def test_closed_schema_rejects_an_unknown_key_at_every_level(self):
        base = company(lanes={"drive": "deny"})
        spots = {
            "top": lambda d: d.update(typo=1),
            "support": lambda d: d.update(support={"contact": "x", "phone": "1"}),
            "lanes": lambda d: d["lanes"].update(driev="allow"),
            "approvals": lambda d: d.update(approvals={"driev": "x"}),
            "local_only": lambda d: d.update(local_only={"lockd": True}),
            "recording": lambda d: d.update(recording={"enable": True}),
            "asr": lambda d: d.update(asr={"allowed_engine": []}),
            "asr.send_vocab": lambda d: d.update(asr={"send_vocab": {"edge": True}}),
            "archive": lambda d: d.update(archive={"allowed_root": []}),
            "llm": lambda d: d.update(llm={"pin": {}}),
            "llm.claude_bin_pin": lambda d: d.update(llm={"claude_bin_pin": {"team": "x"}}),
            "runtime": lambda d: d.update(runtime={"roots": "/x"}),
        }
        for name, mutate in spots.items():
            with self.subTest(where=name):
                doc = json.loads(json.dumps(base))
                mutate(doc)
                pol = self.load(doc)
                self.assertLocked(pol, "unknown-key")
        # the reason names WHERE (a key path), never a value
        self.assertEqual(self.load(company(lanes={"driev": "allow"})).locked_reason, "unknown-key: lanes.driev")
        self.assertEqual(self.load(company(local_only={"default": True, "lockd": True})).locked_reason, "unknown-key: local_only.lockd")

    def test_wrong_container_and_scalar_types_lock(self):
        cases = [
            ({"lanes": "allow"}, "bad-type"), ({"lanes": []}, "bad-type"), ({"asr": []}, "bad-type"), ({"asr": {"allowed_hosts": "x"}}, "bad-type"),
            ({"asr": {"allowed_hosts": [5]}}, "bad-type"), ({"asr": {"allowed_hosts": [""]}}, "bad-value"),
            ({"asr": {"allowed_engines": [None]}}, "bad-type"), ({"asr": {"allow_foreign": "false"}}, "bad-type"),
            ({"asr": {"allow_foreign": 0}}, "bad-type"), ({"asr": {"daily_audio_minutes_cap": "240"}}, "bad-type"),
            ({"asr": {"daily_audio_minutes_cap": True}}, "bad-type"), ({"asr": {"daily_audio_minutes_cap": 1.5}}, "bad-type"),
            ({"asr": {"daily_audio_minutes_cap": -1}}, "bad-value"), ({"asr": {"send_vocab": {"server": "yes"}}}, "bad-type"),
            ({"asr": {"send_vocab": True}}, "bad-type"), ({"local_only": {"default": "true"}}, "bad-type"), ({"local_only": {"locked": 1}}, "bad-type"),
            ({"local_only": []}, "bad-type"), ({"recording": {"enabled": "false"}}, "bad-type"), ({"recording": {"enabled": None}}, "bad-type"),
            ({"archive": {"allowed_roots": "~/x"}}, "bad-type"), ({"archive": {"local_roots": [3]}}, "bad-type"), ({"runtime": {"root": 5}}, "bad-type"),
            ({"runtime": {"root": "relative/path"}}, "bad-value"), ({"runtime": {"root": "/a/../b"}}, "bad-value"), ({"runtime": {"root": "/a/.."}}, "bad-value"),
            ({"llm": []}, "bad-type"), ({"defaults": "x"}, "bad-type"), ({"support": "x"}, "bad-type"), ({"approvals": ["x"]}, "bad-type"),
            ({"asr": {"allowed_hosts": ["a b"]}}, "bad-value"),
        ]
        for extra, code in cases:
            with self.subTest(extra=extra):
                self.assertLocked(self.load(minimal(**extra)), code)

    def test_header_rules(self):
        for doc, code in [({"profile": "personal", "revision": 1}, "bad-schema"), ({"schema": 2, "profile": "personal", "revision": 1}, "bad-schema"),
                          ({"schema": "1", "profile": "personal", "revision": 1}, "bad-schema"), ({"schema": True, "profile": "personal", "revision": 1}, "bad-schema"),
                          ({"schema": 1, "revision": 1}, "no-profile"), ({"schema": 1, "profile": "enterprise", "revision": 1}, "bad-profile"),
                          ({"schema": 1, "profile": "Company", "revision": 1}, "bad-profile"), ({"schema": 1, "profile": 7, "revision": 1}, "bad-profile"),
                          ({"schema": 1, "profile": None, "revision": 1}, "bad-profile"), ({"schema": 1, "profile": ["company"], "revision": 1}, "bad-profile"),
                          ({"schema": 1, "profile": "personal"}, "bad-revision"), ({"schema": 1, "profile": "personal", "revision": 0}, "bad-revision"),
                          ({"schema": 1, "profile": "personal", "revision": -3}, "bad-revision"), ({"schema": 1, "profile": "personal", "revision": "3"}, "bad-revision"),
                          ({"schema": 1, "profile": "personal", "revision": True}, "bad-revision"), ({"schema": 1, "profile": "personal", "revision": 1.0}, "bad-revision")]:
            with self.subTest(doc=doc):
                self.assertLocked(self.load(doc), code)

    def test_malformed_content_locks(self):
        good = json.dumps(minimal()).encode()
        cases = [("bom", b"\xef\xbb\xbf" + good, "bom"), ("not utf-8", b"\xff\xfe{}", "not-utf8"), ("latin-1", '{"profile": "é"}'.encode("latin-1"), "not-utf8"),
                 ("empty", b"", "bad-json"), ("blank", b"  \n", "bad-json"), ("garbage", b"not json", "bad-json"), ("truncated", good[:20], "bad-json"),
                 ("trailing", good + b" {}", "bad-json"), ("single quotes", b"{'schema': 1}", "bad-json"), ("trailing comma", b'{"schema": 1,}', "bad-json"),
                 ("array", b"[]", "not-object"), ("string", b'"text"', "not-object"), ("null", b"null", "not-object"), ("number", b"1", "not-object"),
                 ("NaN", b'{"schema": 1, "profile": "personal", "revision": NaN}', "bad-json"), ("Infinity", b'{"x": Infinity}', "bad-json"),
                 ("duplicate top key", b'{"schema": 1, "schema": 1, "profile": "personal", "revision": 1}', "duplicate-key"),
                 ("duplicate lanes", b'{"schema":1,"profile":"personal","revision":1,"lanes":{"drive":"deny"},"lanes":{"drive":"allow"}}', "duplicate-key"),
                 ("duplicate nested", b'{"schema":1,"profile":"personal","revision":1,"lanes":{"drive":"deny","drive":"allow"}}', "duplicate-key"),
                 ("duplicate inside ext", b'{"schema":1,"profile":"personal","revision":1,"ext":{"a":1,"a":2}}', "duplicate-key"),
                 ("deep nesting", b"[" * 100000, "bad-json")]
        for name, raw, code in cases:
            with self.subTest(case=name):
                self.assertLocked(self.load(raw=raw), code)

    def test_size_limit(self):
        pad = "x" * (policy.MAX_POLICY_BYTES - len(json.dumps(minimal(ext="")).encode()) - 1)
        raw = json.dumps(minimal(ext=pad)).encode()
        self.assertLessEqual(len(raw), policy.MAX_POLICY_BYTES)
        self.assertTrue(self.load(raw=raw).valid)
        self.assertLocked(self.load(raw=raw + b" " * 10), "too-large")                      # size lstat reports
        self.assertLocked(self.load(raw=raw + b" " * 10, size=100), "too-large")           # lstat says small, the bytes actually read are not
        self.assertLocked(self.load(raw=json.dumps(minimal()).encode(), size=policy.MAX_POLICY_BYTES + 1), "too-large")    # size lstat reports

    def test_file_type_owner_and_mode_come_from_the_injected_lstat(self):
        doc = minimal()
        for kw, code in [({"uid": 501}, "bad-owner"), ({"uid": 1}, "bad-owner"), ({"mode": 0o664}, "group-or-other-writable"),
                         ({"mode": 0o646}, "group-or-other-writable"), ({"mode": 0o666}, "group-or-other-writable"),
                         ({"mode": 0o620}, "group-or-other-writable"), ({"kind": "symlink", "mode": 0o755}, "not-regular-file"),
                         ({"kind": "directory", "mode": 0o755}, "not-regular-file"), ({"ancestor_uid": 501}, "parent-bad-owner"),
                         ({"ancestor_mode": 0o775}, "parent-writable"), ({"ancestor_mode": 0o757}, "parent-writable")]:
            with self.subTest(kw=kw):
                self.assertLocked(self.load(doc, **kw), code)
        for kw in ({"mode": 0o644}, {"mode": 0o444}, {"mode": 0o640}, {"mode": 0o755}, {"ancestor_mode": 0o755}, {"ancestor_mode": 0o700}):
            with self.subTest(kw=kw):
                self.assertTrue(self.load(doc, **kw).valid)

    def test_only_the_ancestors_chain_is_checked_and_each_one(self):
        self.put(minimal())
        grand = self.path.parent.parent

        def fn(p):
            p = Path(p)
            if p == self.path:
                return _st("file", 0, 0o644)
            if p == grand:
                return _st("directory", 0, 0o777)          # one writable directory far above the file
            if p in self.path.parents:
                return _st("directory", 0, 0o755)
            raise FileNotFoundError(p)
        pol = policy.load_org_policy(self.path, stat_fn=fn, sleep=NOSLEEP, current_version="0.2.0")
        self.assertLocked(pol, "parent-writable")

    def test_unreadable_stat_or_read_locks(self):
        self.assertLocked(self.load(minimal(), error=PermissionError("denied")), "unreadable")
        self.put(minimal())
        self.path.chmod(0)
        try:
            if os.geteuid() != 0:
                pol = policy.load_org_policy(self.path, stat_fn=make_stat_fn(self.path), sleep=NOSLEEP, current_version="0.2.0")
                self.assertLocked(pol, "unreadable")
        finally:
            self.path.chmod(0o644)

    def test_a_symlink_file_is_never_followed(self):
        self.put(minimal())
        link = self.path.parent / "link.json"
        link.symlink_to(self.path)
        pol = policy.load_org_policy(link, stat_fn=make_stat_fn(link, kind="file"), sleep=NOSLEEP, current_version="0.2.0")   # lstat lies: O_NOFOLLOW does not
        self.assertLocked(pol, "unreadable")

    def test_reread_after_500ms_turns_a_half_written_file_into_a_valid_one(self):
        self.put(b"{".decode())
        writes = []

        def sleeper(seconds):
            writes.append(seconds)
            self.put(minimal(revision=9))
        fn = make_stat_fn(self.path)
        pol = policy.load_org_policy(self.path, stat_fn=fn, sleep=sleeper, current_version="0.2.0")
        self.assertEqual(writes, [0.5])
        self.assertTrue(pol.valid)
        self.assertEqual(pol.revision, 9)

    def test_a_lock_is_confirmed_once_and_a_valid_policy_is_never_delayed(self):
        self.assertTrue(self.load(minimal()).valid)
        self.assertEqual(self.sleeps, [])
        self.assertLocked(self.load("{"), "bad-json")
        self.assertEqual(self.sleeps, [0.5])                                               # one more read, not a loop
        self.sleeps.clear()
        self.assertLocked(self.load(minimal(), uid=5), "bad-owner")
        self.assertEqual(self.sleeps, [0.5])

    def test_the_second_read_wins_even_when_it_is_worse(self):
        self.put(minimal())

        def sleeper(seconds):
            self.put("{")
        pol = policy.load_org_policy(self.path, stat_fn=make_stat_fn(self.path), sleep=sleeper, current_version="0.2.0")
        self.assertTrue(pol.valid)                                                         # valid first read is returned at once

    def test_never_raises(self):
        def boom(p):
            raise RuntimeError("boom")
        with self.assertLogs("mcap.policy", "WARNING"):
            pol = policy.load_org_policy(self.path, stat_fn=boom, sleep=NOSLEEP)
        self.assertTrue(pol.locked)                                                        # RuntimeError from stat_fn: internal error, closed
        with mock.patch.object(policy, "_build_policy", side_effect=ZeroDivisionError), self.assertLogs("mcap.policy", "WARNING"):
            self.assertLocked(self.load(minimal()), "internal-error")

    def test_file_stamp_and_hash(self):
        pol = self.load(minimal())
        self.assertEqual(len(pol.sha256_8), 8)
        self.assertEqual(pol.file_stamp, (1_700_000_000_000_000_000, 4242, self.path.stat().st_size))
        other = self.load(minimal(revision=2))
        self.assertNotEqual(pol.sha256_8, other.sha256_8)
        self.assertIsNone(self.load(None).file_stamp)

    def test_a_lock_still_shows_what_is_known_about_the_policy(self):
        pol = self.load(company(revision=7, support={"contact": "IT #it"}, lanes={"typo_lane": "allow"}))
        self.assertLocked(pol, "unknown-key")
        self.assertEqual((pol.profile, pol.revision, pol.support_contact), ("company", 7, "IT #it"))
        self.assertIsNotNone(pol.sha256_8)
        pol = self.load("{")
        self.assertEqual((pol.profile, pol.revision, pol.support_contact), ("unknown", None, None))

    def test_a_locked_policy_forces_local_only_keeps_recording_and_closes_every_lane(self):
        pol = self.load("{")
        self.assertEqual((pol.local_only_default, pol.local_only_locked, pol.recording_enabled), (True, True, True))
        self.assertEqual((pol.allowed_engines, pol.allowed_hosts, pol.archive_allowed_roots), ((), (), ()))
        self.assertEqual(dict(pol.send_vocab), {"server": False, "cloud": False})
        self.assertEqual(pol.org_consents, ())
        self.assertEqual(dict(pol.defaults), {})
        self.assertEqual(dict(pol.enforced), policy.COMPANY_BASELINE_ENFORCED)      # nothing is known about the file: the closed reading

    def test_a_lock_keeps_the_company_baseline_unless_the_file_positively_says_personal(self):
        """Damaged input reads as the closed value: a managed Mac whose policy.json cannot be trusted must not log transcript
        text or download models, which is exactly what the valid company policy forbids. The file's own enforced / defaults are not trusted."""
        baseline = dict(policy.COMPANY_BASELINE_ENFORCED)
        no_profile = {"schema": 1, "revision": 1}
        for label, pol in (("broken json", self.load("{")), ("bom", self.load(raw=b"\xef\xbb\xbf{}")), ("not an object", self.load("[]")),
                           ("bad owner (nothing is read)", self.load(minimal(), uid=5)), ("marker without a file", self.load(None, marker=True)),
                           ("profile spelled Personal", self.load(minimal("Personal"))), ("no profile", self.load(no_profile)),
                           ("profile of the wrong type", self.load(dict(no_profile, profile=["personal"]))),
                           ("company, unknown key", self.load(company(typo=1, enforced={"LOG_CONTENT": "1"}, defaults={"ASR_ENGINE": "auto"}))),
                           ("company, too old", self.load(company(min_pipeline_version="9.0.0"))),
                           ("company, bad value", self.load(company(local_only={"locked": 1})))):
            with self.subTest(label):
                self.assertTrue(pol.locked, label)
                self.assertEqual((dict(pol.enforced), dict(pol.defaults)), (baseline, {}))
        for label, pol in (("personal, unknown key", self.load(minimal(typo=1, enforced={"LOG_CONTENT": "1"}))),
                           ("personal, too old", self.load(minimal(min_pipeline_version="9.0.0"))),
                           ("personal, bad type", self.load(minimal(recording={"enabled": 1})))):
            with self.subTest(label):
                self.assertEqual((pol.locked, pol.profile, dict(pol.enforced), dict(pol.defaults)), (True, "personal", {}, {}))
        self.assertEqual(dict(policy._locked_policy("x").enforced), baseline)                  # the default profile is "unknown"
        self.assertEqual(dict(policy._locked_policy("x", profile="personal").enforced), {})
        self.assertEqual(dict(policy.absent_policy().enforced), {})                             # no policy at all: nothing is enforced
        self.assertEqual(dict(self.load(minimal()).enforced), {})

    def test_example_policy_is_valid_and_opens_nothing(self):
        example = REPO / "config" / "policy.example.json"
        pol = policy.load_org_policy(example, stat_fn=make_stat_fn(example), required_marker=self.path.parent / "none", sleep=NOSLEEP,
                                     current_version="0.1.0")
        self.assertTrue(pol.valid, pol.locked_reason)
        self.assertEqual(pol.profile, "company")
        self.assertEqual(set(pol.lanes.values()), {"deny"})
        self.assertTrue(pol.local_only_default)
        self.assertEqual(pol.allowed_hosts, ())
        self.assertEqual(pol.org_consents, ())
        self.assertEqual(pol.enforced["LOG_CONTENT"], "0")
        # a pipeline older than the example's own min_pipeline_version reads it as locked
        old = policy.load_org_policy(example, stat_fn=make_stat_fn(example), required_marker=self.path.parent / "none", sleep=NOSLEEP,
                                     current_version="0.0.9")
        self.assertLocked(old, "pipeline-too-old")


# ---------------------------------------------------------------------------------------------------- archive roots
class ArchiveRootTests(TempCase):
    def test_shared_cases(self):
        """Every case from three working directories: the verdict is the same wherever the process happens to run."""
        doc = json.loads((FIXTURES / "archive_roots_cases.json").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(doc["cases"]), 30)
        homes = [self.root / "cwd-a", self.root / "cwd-b"]
        for folder in homes:
            folder.mkdir()
        with mock.patch.dict(os.environ, {"HOME": doc["home"]}):
            for cwd in (os.getcwd(), homes[0], homes[1]):
                with working_directory(cwd):
                    for case in doc["cases"]:
                        with self.subTest(case=case["id"], cwd=str(cwd)):
                            self.assertIs(policy.archive_root_matches(case["path"], case["roots"]), case["expect"], case["note"])

    def test_a_relative_root_or_path_never_depends_on_the_working_directory(self):
        base = Path(self.root.resolve())
        for folder in ("here/Meetings/2026", "there/Meetings/2026", "here/x"):
            (base / folder).mkdir(parents=True)
        target = str(base / "here" / "Meetings" / "2026")
        for cwd in (base / "here", base / "there", base / "here" / "Meetings", base):
            with working_directory(cwd):
                for roots in (["Meetings"], ["*"], ["."], [".."], ["./Meetings"], ["Meetings/2026"], ["*/Meetings"], ["here"], ["~root"], ["~x"]):
                    with self.subTest(cwd=str(cwd), roots=roots):
                        self.assertFalse(policy.archive_root_matches(target, roots))
                for relative in ("Meetings/2026", ".", "2026", "../here/Meetings/2026", "x"):
                    with self.subTest(cwd=str(cwd), path=relative):
                        self.assertFalse(policy.archive_root_matches(relative, [str(base / "here")]))      # a relative PATH is inside nothing
                        self.assertFalse(policy.archive_root_matches(relative, [str(base)]))
                self.assertTrue(policy.archive_root_matches(target, [str(base / "here")]))               # an absolute root does not care
                self.assertFalse(policy.archive_root_matches(target, [str(base / "there")]))
                with mock.patch.dict(os.environ, {"HOME": str(base / "here")}):                          # ~ is the home folder, not the cwd
                    self.assertTrue(policy.archive_root_matches(target, ["~"]))
                    self.assertTrue(policy.archive_root_matches(target, ["~/Meetings"]))
                    self.assertTrue(policy.archive_root_matches("~/Meetings/2026", [str(base / "here" / "Meetings")]))
                    self.assertFalse(policy.archive_root_matches(str(base / "there" / "Meetings"), ["~"]))
                with mock.patch.dict(os.environ, {"HOME": "relative-home"}):                              # no usable home: nothing matches, not even by cwd
                    self.assertFalse(policy.archive_root_matches(str(base / "here" / "relative-home" / "x"), ["~", "~/x"]))
                    self.assertFalse(policy.archive_root_matches("~/x", [str(base / "here")]))

    def test_the_two_normalisation_forms_really_differ_in_the_corpus(self):
        doc = json.loads((FIXTURES / "archive_roots_cases.json").read_text(encoding="utf-8"))
        by_id = {c["id"]: c for c in doc["cases"]}
        root = by_id["nfc_root_nfd_path"]["roots"][0].rsplit("/", 1)[1]
        path = by_id["nfc_root_nfd_path"]["path"].split("/")[-2]
        self.assertNotEqual(root, path)
        self.assertEqual(unicodedata.normalize("NFC", root), unicodedata.normalize("NFC", path))

    def test_realpath_resolves_a_symlink_before_comparing(self):
        base = Path(self.root.resolve())
        allowed = base / "Drive" / "Shared" / "Meetings"
        allowed.mkdir(parents=True)
        outside = base / "Elsewhere"
        outside.mkdir()
        (base / "Drive" / "inside-link").symlink_to(allowed)
        (base / "Drive" / "escape-link").symlink_to(outside)
        roots = [str(base / "Drive" / "Shared" / "Meetings")]
        self.assertTrue(policy.archive_root_matches(base / "Drive" / "inside-link", roots))
        self.assertFalse(policy.archive_root_matches(base / "Drive" / "escape-link", roots))
        self.assertFalse(policy.archive_root_matches(base / "Drive" / "escape-link" / "Meetings", roots))
        # the root may be a symlink too: both sides are resolved
        (base / "link-root").symlink_to(allowed)
        self.assertTrue(policy.archive_root_matches(allowed / "2026-10", [str(base / "link-root")]))

    def test_unresolved_temp_path_matches_its_resolved_root(self):
        """/var/folders/... is /private/var/folders/... on macOS: the same folder in either spelling is inside the root."""
        sub = self.root / "a" / "b"
        sub.mkdir(parents=True)
        self.assertTrue(policy.archive_root_matches(sub, [str(self.root.resolve() / "a")]))
        self.assertTrue(policy.archive_root_matches(sub.resolve(), [str(self.root / "a")]))

    def test_a_path_the_os_cannot_resolve_is_no_match_not_an_error(self):
        self.assertFalse(policy.archive_root_matches("/x/y\x00z", ["/x"]))
        self.assertFalse(policy.archive_root_matches("/x/y", ["/x\x00"]))
        self.assertTrue(policy.archive_root_matches("/x/y", ["/x\x00", "/x"]))                  # the odd root is skipped, a good one still counts

    def test_none_empty_and_odd_inputs(self):
        self.assertTrue(policy.archive_root_matches("/x", None))
        self.assertFalse(policy.archive_root_matches("/x", ()))
        self.assertFalse(policy.archive_root_matches(None, ["/x"]))
        self.assertFalse(policy.archive_root_matches("/x", [None, 5, "/y"]))
        self.assertTrue(policy.archive_root_matches(Path("/x/y"), (Path("/x").as_posix(),)))


class LocalArchiveTests(TempCase):
    def setUp(self):
        super().setUp()
        self.support = self.root / "Support Dir"                   # spaces on purpose; NOT resolved: /var/... is a symlink on macOS
        self.support.mkdir()

    def ok(self, path, extra=(), **kw):
        return policy.local_archive_ok(path, self.support, extra, **kw)

    def test_default_location_is_safe(self):
        self.assertEqual(self.ok(self.support / "local-meetings"), (True, "ok"))
        self.assertEqual(self.ok(Config(support_dir=self.support).local_archive_root), (True, "ok"))
        self.assertEqual(self.ok(self.support / "local-meetings" / "2026-10"), (True, "ok"))
        self.assertEqual(self.ok(self.support), (True, "ok"))

    def test_outside_the_allow_list_is_refused(self):
        other = self.root / "Other"
        other.mkdir()
        self.assertEqual(self.ok(other), (False, "outside-allowed-roots"))
        self.assertEqual(self.ok(self.root / "Support Dir-evil"), (False, "outside-allowed-roots"))     # prefix of the NAME is not inside
        self.assertEqual(self.ok(self.root), (False, "outside-allowed-roots"))
        self.assertEqual(self.ok(Path.home() / "Library" / "CloudStorage" / "GoogleDrive-x" / "Meetings"), (False, "outside-allowed-roots"))
        self.assertEqual(self.ok("/tmp"), (False, "outside-allowed-roots"))

    def test_extra_roots_come_from_the_policy(self):
        other = self.root / "Other" / "Meetings"
        other.mkdir(parents=True)
        self.assertEqual(self.ok(other, [str(self.root / "Other")]), (True, "ok"))
        self.assertEqual(self.ok(other, [str(self.root / "Else")]), (False, "outside-allowed-roots"))
        self.assertEqual(self.ok(other, [str(self.root / "*")]), (True, "ok"))                          # component wildcard
        self.assertEqual(self.ok(other, ()), (False, "outside-allowed-roots"))
        self.assertEqual(self.ok(other, None), (False, "outside-allowed-roots"))

    def test_symlink_components_are_refused(self):
        real = self.root / "Real"
        real.mkdir()
        (self.support / "local-meetings").symlink_to(real)
        self.assertEqual(self.ok(self.support / "local-meetings"), (False, "symlink-in-path"))
        self.assertEqual(self.ok(self.support / "local-meetings" / "x"), (False, "symlink-in-path"))
        # a symlinked SUPPORT_DIR cannot launder the check: the path through it has a symlink component
        link_support = self.root / "SupportLink"
        link_support.symlink_to(real)
        self.assertEqual(policy.local_archive_ok(link_support / "local-meetings", link_support, ()), (False, "symlink-in-path"))
        # a ".." that passes through a symlink is not the path it looks like
        deep = self.root / "Other" / "deep"
        deep.mkdir(parents=True)
        (self.support / "hop").symlink_to(deep)
        self.assertEqual(self.ok(self.support / "hop" / ".." / "x"), (False, "symlink-in-path"))      # really lands in Other/x

    def test_macos_temp_aliases_are_not_symlinks_an_attacker_can_make(self):
        if not str(self.root).startswith(("/var/", "/tmp/")):
            self.skipTest("temp dir is not under /var or /tmp")
        self.assertNotEqual(str(self.root), str(self.root.resolve()))
        self.assertEqual(self.ok(self.support / "local-meetings"), (True, "ok"))

    def test_same_device_as_home_is_required(self):
        calls = []

        def stat_fn(p):
            calls.append(str(p))
            return SimpleNamespace(st_dev=7 if "Support Dir" in str(p) else 9)
        self.assertEqual(self.ok(self.support / "local-meetings", home="/home/x", stat_fn=stat_fn), (False, "different-device"))
        self.assertTrue(any("Support Dir" in c for c in calls))
        same = lambda p: SimpleNamespace(st_dev=7)  # noqa: E731
        self.assertEqual(self.ok(self.support / "local-meetings", home="/home/x", stat_fn=same), (True, "ok"))

        def failing(p):
            raise OSError("gone")
        self.assertEqual(self.ok(self.support / "local-meetings", stat_fn=failing), (False, "different-device"))    # cannot tell = no

    def test_nearest_existing_ancestor_is_what_is_stat_ed(self):
        seen = []

        def stat_fn(p):
            seen.append(str(p))
            return SimpleNamespace(st_dev=1)
        self.ok(self.support / "does" / "not" / "exist" / "yet", home="/h", stat_fn=stat_fn)
        self.assertTrue(any(s.endswith("Support Dir") for s in seen), seen)

    def test_a_path_the_os_cannot_resolve_is_unsafe_not_an_error(self):
        self.assertEqual(self.ok(str(self.support / "a\x00b")), (False, "bad-path"))
        self.assertEqual(policy.local_archive_ok(self.support / "x", str(self.support) + "\x00", ()), (False, "bad-path"))

    def test_relative_paths_and_roots_are_never_read_against_the_working_directory(self):
        (self.support / "local-meetings").mkdir()
        other = self.root / "Other" / "Meetings"
        other.mkdir(parents=True)
        for cwd in (self.support, self.root, self.root / "Other"):
            with working_directory(cwd):
                with self.subTest(cwd=str(cwd)):
                    self.assertEqual(self.ok("local-meetings"), (False, "bad-path"))                    # relative LOCAL_ARCHIVE_DIR
                    self.assertEqual(self.ok("./local-meetings"), (False, "bad-path"))
                    self.assertEqual(self.ok("."), (False, "bad-path"))
                    self.assertEqual(policy.local_archive_ok(self.support / "local-meetings", "Support Dir", ()), (False, "bad-path"))   # relative SUPPORT_DIR
                    self.assertEqual(policy.local_archive_ok(self.support / "local-meetings", ".", ()), (False, "bad-path"))
                    for root in ("Other", "*", ".", "Other/Meetings", "../Other"):                      # relative roots: skipped, not read against the cwd
                        self.assertEqual(self.ok(other, [root]), (False, "outside-allowed-roots"), root)
                    self.assertEqual(self.ok(other, ["Other", str(self.root / "Other")]), (True, "ok"))     # an anchored root next to it still counts
                    self.assertEqual(self.ok(self.support / "local-meetings"), (True, "ok"))             # the default location does not care

    def test_empty_path(self):
        self.assertEqual(self.ok(""), (False, "empty-path"))
        self.assertEqual(self.ok(None), (False, "empty-path"))
        self.assertEqual(self.ok("  "), (False, "empty-path"))

    def test_case_and_unicode_variants_of_the_support_dir_are_inside(self):
        base = unicodedata.normalize("NFD", "지원")
        support = self.root / "Support" / base
        support.mkdir(parents=True)
        probe = self.root / "Support" / unicodedata.normalize("NFC", "지원") / "local-meetings"
        ok, reason = policy.local_archive_ok(probe, support, ())                       # APFS may or may not unify the two spellings
        self.assertIn(reason, ("ok", "symlink-in-path", "outside-allowed-roots"))


# ---------------------------------------------------------------------------------------------------- local-only flag
class LocalOnlyTests(PolicyCase):
    def cfg(self, **kw):
        return SimpleNamespace(**kw)

    def pol(self, doc=None):
        return policy.absent_policy() if doc is None else self.load(doc)

    def test_read_session_local_only(self):
        self.assertEqual(policy.read_session_local_only({"local_only": True}), (True, "present"))
        self.assertEqual(policy.read_session_local_only({"local_only": False}), (False, "present"))
        self.assertEqual(policy.read_session_local_only({}), (None, "absent"))
        self.assertEqual(policy.read_session_local_only({"local_only": None}), (None, "absent"))
        self.assertEqual(policy.read_session_local_only({"local_only": "false"}), ("false", "present"))
        self.assertEqual(policy.read_session_local_only({"local_only": 0}), (0, "present"))

    def test_read_session_local_only_from_files(self):
        folder = self.root / "sess"
        folder.mkdir()
        (folder / "session.json").write_text('{"local_only": true}')
        self.assertEqual(policy.read_session_local_only(folder), (True, "present"))
        self.assertEqual(policy.read_session_local_only(folder / "session.json"), (True, "present"))
        self.assertEqual(policy.read_session_local_only(str(folder)), (True, "present"))
        (folder / "session.json").write_text('{"local_only": false}')                 # read anew every time: no cache
        self.assertEqual(policy.read_session_local_only(folder), (False, "present"))
        for text in ("{", "[]", "null", '"x"', "", "﻿{}"):
            (folder / "session.json").write_text(text, encoding="utf-8")
            self.assertEqual(policy.read_session_local_only(folder), (policy.UNREADABLE, "unreadable"), repr(text))
        (folder / "session.json").write_bytes(b"\xff\xfe")
        self.assertIs(policy.read_session_local_only(folder)[0], policy.UNREADABLE)
        self.assertIs(policy.read_session_local_only(self.root / "missing")[0], policy.UNREADABLE)
        self.assertIs(policy.read_session_local_only(None)[0], policy.UNREADABLE)

    def test_unreadable_marker_is_not_a_bool_and_not_none(self):
        self.assertIsNot(policy.UNREADABLE, None)
        self.assertNotEqual(policy.UNREADABLE, False)
        self.assertNotEqual(policy.UNREADABLE, True)
        self.assertEqual(repr(policy.UNREADABLE), "UNREADABLE")

    def test_default_chain_without_a_value(self):
        for raw in (None,):
            self.assertEqual(policy.effective_local_only(raw, self.pol(), self.cfg(local_only_default=False)), policy.LocalOnly(False, "default"))
            self.assertEqual(policy.effective_local_only(raw, self.pol(), self.cfg(local_only_default=True)), policy.LocalOnly(True, "default"))
            self.assertEqual(policy.effective_local_only(raw, self.pol(minimal(local_only={"default": True})), self.cfg(local_only_default=False)),
                             policy.LocalOnly(True, "default"))                           # policy default ORed with LOCAL_ONLY_DEFAULT
            self.assertEqual(policy.effective_local_only(raw, self.pol(minimal(local_only={"default": False})), self.cfg(local_only_default=True)),
                             policy.LocalOnly(True, "default"))                           # the user cannot lower the policy, the policy cannot lower the user
        self.assertEqual(policy.effective_local_only(None, self.pol(), self.cfg()), policy.LocalOnly(False, "default"))   # no attribute at all

    def test_a_bool_is_taken_as_it_is(self):
        for value in (True, False):
            self.assertEqual(policy.effective_local_only(value, self.pol(), self.cfg(local_only_default=True)), policy.LocalOnly(value, "session"))
            self.assertEqual(policy.effective_local_only(value, self.pol(minimal(local_only={"default": True})), self.cfg()),
                             policy.LocalOnly(value, "session"))                          # the DEFAULT never overrides a recorded value

    def test_every_other_type_is_true_fail_closed(self):
        for raw in ("false", "true", "0", "1", "", "no", 0, 1, 0.0, [], [False], {}, {"a": 1}, b"x", ("a",), object()):
            with self.subTest(raw=repr(raw)):
                self.assertEqual(policy.effective_local_only(raw, self.pol(), self.cfg()), policy.LocalOnly(True, "fail-closed:bad-type"))

    def test_unreadable_session_is_true(self):
        self.assertEqual(policy.effective_local_only(policy.UNREADABLE, self.pol(), self.cfg()), policy.LocalOnly(True, "fail-closed:unreadable"))

    def test_policy_lock_wins_over_everything(self):
        locked = self.pol(minimal(local_only={"locked": True}))
        for raw in (False, True, None, "false", 0, policy.UNREADABLE):
            with self.subTest(raw=repr(raw)):
                self.assertEqual(policy.effective_local_only(raw, locked, self.cfg()), policy.LocalOnly(True, "policy-lock"))

    def test_an_invalid_policy_is_a_lock_too(self):
        broken = self.load("{")
        self.assertTrue(broken.locked)
        for raw in (False, True, None):
            self.assertEqual(policy.effective_local_only(raw, broken, self.cfg()), policy.LocalOnly(True, "policy-lock"))

    def test_bad_type_of_the_config_default_is_true(self):
        self.assertEqual(policy.effective_local_only(None, self.pol(), self.cfg(local_only_default="maybe")), policy.LocalOnly(True, "default"))
        self.assertEqual(policy.effective_local_only(None, None, self.cfg(local_only_default=False)), policy.LocalOnly(False, "default"))


# ---------------------------------------------------------------------------------------------------- lanes
def lane_cfg(root, **kw):
    cfg = make_cfg(root, **kw)
    return cfg


class LaneDecisionTests(PolicyCase):
    def decisions(self, lo, pol, cfg):
        return {lane: (d.allowed, d.reason) for lane, d in policy.lane_decisions(lo, pol, cfg).items()}

    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root, calendar_lookup="auto", asr_engine="remote", asr_fallback="azure")
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        self.free, self.shut = policy.LocalOnly(False, "session"), policy.LocalOnly(True, "session")

    def test_no_policy_every_lane_allowed_when_the_user_asks_for_it(self):
        got = self.decisions(self.free, policy.absent_policy(), self.cfg)
        self.assertEqual(got, {lane: (True, "ok") for lane in policy.LANES})

    def test_no_policy_default_user_settings_ask_for_no_external_asr(self):
        cfg = make_cfg(self.root)                              # ASR_ENGINE whisper, fallback none
        got = self.decisions(self.free, policy.absent_policy(), cfg)
        self.assertEqual(got["asr_remote"], (False, "user-disabled"))
        self.assertEqual(got["asr_cloud"], (False, "user-disabled"))
        self.assertEqual(got["llm"], (True, "ok"))
        self.assertEqual(got["drive"], (True, "ok"))
        self.assertEqual(got["calendar"], (False, "user-disabled"))          # make_cfg switches the lookup off

    def test_local_only_closes_all_five_lanes(self):
        got = self.decisions(self.shut, policy.absent_policy(), self.cfg)
        self.assertEqual(got, {lane: (False, "local_only") for lane in policy.LANES})

    def test_a_locked_policy_closes_all_five_lanes_with_its_own_reason(self):
        broken = self.load("{")
        for lo in (self.free, self.shut):
            self.assertEqual(self.decisions(lo, broken, self.cfg), {lane: (False, "policy-locked") for lane in policy.LANES})

    def test_policy_reasons(self):
        lanes = {lane: "allow" for lane in policy.LANES}
        pol = self.load(company(lanes=lanes, approvals={"llm": "L-2", "drive": "L-4"}, archive={"allowed_roots": [str(self.cfg.archive_dir)]}))
        got = self.decisions(self.free, pol, self.cfg)
        self.assertEqual(got["asr_remote"], (True, "ok"))
        self.assertEqual(got["asr_cloud"], (False, "policy-unapproved"))
        self.assertEqual(got["llm"], (False, "policy-claude-unpinned"))
        self.assertEqual(got["calendar"], (False, "policy-unapproved"))
        self.assertEqual(got["drive"], (True, "ok"))
        got = self.decisions(self.free, self.load(company()), self.cfg)
        self.assertEqual({lane: reason for lane, (_, reason) in got.items()}, {lane: "policy-lane" for lane in policy.LANES})

    def test_local_only_is_reported_before_a_policy_deny(self):
        got = self.decisions(self.shut, self.load(company()), self.cfg)
        self.assertEqual(set(r for _, r in got.values()), {"local_only"})

    def test_drive_needs_an_allowed_root_and_for_company_an_explicit_archive_dir(self):
        lanes = {"drive": "allow"}
        approvals = {"drive": "T-1"}
        roots_ok = [str(self.cfg.archive_dir.parent)]
        pol = self.load(company(lanes=lanes, approvals=approvals, archive={"allowed_roots": roots_ok}))
        self.assertEqual(self.decisions(self.free, pol, self.cfg)["drive"], (True, "ok"))
        self.assertEqual(self.decisions(self.free, pol, dataclasses.replace(self.cfg, archive_dir=self.root / "Elsewhere"))["drive"],
                         (False, "policy-archive-root"))
        no_explicit = dataclasses.replace(self.cfg, explicit_keys=frozenset())
        self.assertEqual(self.decisions(self.free, pol, no_explicit)["drive"], (False, "archive-not-configured"))
        omitted = self.load(company(lanes=lanes, approvals=approvals))                         # roots omitted = empty = nothing allowed
        self.assertEqual(self.decisions(self.free, omitted, self.cfg)["drive"], (False, "policy-archive-root"))
        self.assertEqual(self.decisions(self.free, omitted, no_explicit)["drive"], (False, "archive-not-configured"))
        personal = self.load(minimal(lanes=lanes))                                              # personal: unrestricted, explicit not needed
        self.assertEqual(self.decisions(self.free, personal, no_explicit)["drive"], (True, "ok"))
        personal_roots = self.load(minimal(archive={"allowed_roots": roots_ok}))
        self.assertEqual(self.decisions(self.free, personal_roots, dataclasses.replace(self.cfg, archive_dir=self.root / "Elsewhere"))["drive"],
                         (False, "policy-archive-root"))

    def test_a_relative_policy_root_opens_no_drive_lane_in_any_working_directory(self):
        """The loader refuses a relative root now; a hand-built policy (a stale object, a later bug) still must not read it against the cwd."""
        self.cfg.archive_dir.mkdir(parents=True, exist_ok=True)
        pol = self.load(company(lanes={"drive": "allow"}, approvals={"drive": "T-1"}, archive={"allowed_roots": [str(self.cfg.archive_dir.parent)]}))
        self.assertEqual(self.decisions(self.free, pol, self.cfg)["drive"], (True, "ok"))
        for root in (self.cfg.archive_dir.name, "*", ".", "../My Drive/Meetings"):
            sneaky = dataclasses.replace(pol, archive_allowed_roots=(root,))
            for cwd in (self.cfg.archive_dir, self.cfg.archive_dir.parent, self.root):
                with working_directory(cwd), self.subTest(root=root, cwd=str(cwd)):
                    self.assertEqual(self.decisions(self.free, sneaky, self.cfg)["drive"], (False, "policy-archive-root"))
        relative_dir = dataclasses.replace(self.cfg, archive_dir=Path("Meetings"))                  # a relative ARCHIVE_DIR is not inside the root either
        with working_directory(self.cfg.archive_dir.parent):
            self.assertEqual(self.decisions(self.free, pol, relative_dir)["drive"], (False, "policy-archive-root"))

    def test_calendar_follows_the_calendar_lookup_setting(self):
        for value, enabled in [("auto", True), ("AUTO", True), ("1", True), ("anything", True), ("0", False), ("off", False), ("False", False),
                               ("no", False), ("none", False), ("", False), (" 0 ", False)]:
            with self.subTest(value=value):
                cfg = dataclasses.replace(self.cfg, calendar_lookup=value)
                self.assertEqual(self.decisions(self.free, policy.absent_policy(), cfg)["calendar"], (enabled, "ok" if enabled else "user-disabled"))

    def test_asr_lanes_follow_the_engines_the_user_named(self):
        def lanes_for(engine, fallback):
            cfg = dataclasses.replace(self.cfg, asr_engine=engine, asr_fallback=fallback)
            got = self.decisions(self.free, policy.absent_policy(), cfg)
            return got["asr_remote"][0], got["asr_cloud"][0]
        self.assertEqual(lanes_for("whisper", "none"), (False, False))
        self.assertEqual(lanes_for("remote", "none"), (True, False))
        self.assertEqual(lanes_for("azure", "none"), (False, True))
        self.assertEqual(lanes_for("auto", "none"), (True, False))              # auto may pick the company server, never a cloud engine
        self.assertEqual(lanes_for("whisper", "azure"), (False, True))
        self.assertEqual(lanes_for("whisper", "remote"), (True, False))
        self.assertEqual(lanes_for("remote", "azure"), (True, True))
        self.assertEqual(lanes_for("banana", "none"), (False, False))           # unknown word = whisper

    def test_cfg_without_attributes_still_works(self):
        got = policy.lane_decisions(self.free, policy.absent_policy(), SimpleNamespace())
        self.assertEqual(got["llm"].allowed, True)
        self.assertEqual(got["drive"].allowed, True)

    def test_lane_block(self):
        got = policy.lane_decisions(self.shut, policy.absent_policy(), self.cfg)
        block = got["llm"].block()
        self.assertEqual((block.lane, block.kind, block.reason), ("llm", "lane_denied", "local_only"))
        self.assertIn("llm", block.message)
        self.assertIsNone(policy.lane_decisions(self.free, policy.absent_policy(), self.cfg)["llm"].block())



# ---------------------------------------------------------------------------------------------------- consents
def relay_entry(**kw) -> policy.ConsentEntry:
    base = dict(id="c-relay", engine="remote", kind="server", host=RELAY, port=443, region="", model="", protocol="mcap-asr/1",
                backend_kind="server", use="both", machine=MACHINE, granted_at="2026-10-01T09:00:00+09:00", granted_by="tty",
                expires="2027-10-14", ca_sha256=CA)
    base.update(kw)
    return policy.ConsentEntry(**base)


def azure_entry(**kw) -> policy.ConsentEntry:
    base = dict(id="c-azure", engine="azure", kind="cloud", host=AZURE_HOST, port=443, region="koreacentral", model="fast-transcription",
                protocol="azure-fast-transcription", backend_kind="cloud", use="primary", machine=MACHINE,
                granted_at="2026-10-01T09:00:00+09:00", granted_by="tty", expires="2027-10-14")
    base.update(kw)
    return policy.ConsentEntry(**base)


def consent_set(*entries, tampered=False, machine=MACHINE) -> policy.ConsentSet:
    return policy.ConsentSet(entries=tuple(entries), tampered=tampered, machine=machine)


RELAY_ARGS = dict(region="", model="", protocol="mcap-asr/1", backend_kind="server")
AZURE_ARGS = dict(region="koreacentral", model="fast-transcription", protocol="azure-fast-transcription", backend_kind="cloud")


class ConsentFileTests(TempCase):
    def setUp(self):
        super().setUp()
        self.path = self.root / "Support Dir" / "asr-consent.json"

    def test_missing_file_means_no_consent_and_no_problem(self):
        got = policy.load_consents(self.path, machine_id=MACHINE, now=NOW)
        self.assertEqual((got.entries, got.tampered, got.problem, got.machine), ((), False, None, MACHINE))

    def test_write_load_roundtrip_binds_the_machine(self):
        policy.write_consent(self.path, relay_entry(machine="other"), machine_id=MACHINE)
        got = policy.load_consents(self.path, machine_id=MACHINE, now=NOW)
        self.assertFalse(got.tampered)
        self.assertIsNone(got.problem)
        self.assertEqual(got.entries, (relay_entry(),))                            # machine replaced by the one given
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ["asr-consent.json"])          # no temp file left behind
        doc = json.loads(self.path.read_text())
        self.assertEqual(doc["schema"], 1)
        self.assertTrue(doc["integrity"].startswith("sha256:"))

    def test_a_second_consent_for_the_same_engine_replaces_the_first(self):
        policy.write_consent(self.path, relay_entry(host="old.example"), machine_id=MACHINE)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        policy.write_consent(self.path, relay_entry(host="new.example"), machine_id=MACHINE)
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual(sorted((e.engine, e.host) for e in got.entries), [("azure", AZURE_HOST), ("remote", "new.example")])
        self.assertIsNone(got.problem)

    def test_revoke(self):
        self.assertEqual(policy.revoke_consent(self.path, "remote"), 0)               # no file
        policy.write_consent(self.path, relay_entry(), machine_id=MACHINE)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        self.assertEqual(policy.revoke_consent(self.path, "azure"), 1)
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual([e.engine for e in got.entries], ["remote"])
        self.assertFalse(got.tampered)                                                 # the integrity is rewritten with the entries
        self.assertEqual(policy.revoke_consent(self.path, "azure"), 0)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        self.assertEqual(policy.revoke_consent(self.path, "all"), 2)
        self.assertEqual(policy.load_consents(self.path, machine_id=MACHINE).entries, ())
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        self.assertEqual(policy.revoke_consent(self.path, None), 1)

    def test_rewriting_a_tampered_file_does_not_launder_its_entries(self):
        policy.write_consent(self.path, relay_entry(), machine_id=MACHINE)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        doc = json.loads(self.path.read_text())
        doc["entries"][1]["host"] = "evil.example"                                    # a hand edit of the azure consent
        self.path.write_text(json.dumps(doc))
        self.assertTrue(policy.load_consents(self.path, machine_id=MACHINE).tampered)
        policy.write_consent(self.path, relay_entry(host="new.example"), machine_id=MACHINE)       # a fresh consent for another engine
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertFalse(got.tampered)
        self.assertEqual([(e.engine, e.host) for e in got.entries], [("remote", "new.example")])    # the edited entry is gone, not blessed

    def test_revoking_from_a_tampered_file_empties_it(self):
        policy.write_consent(self.path, relay_entry(), machine_id=MACHINE)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        doc = json.loads(self.path.read_text())
        doc["entries"][0]["host"] = "evil.example"
        self.path.write_text(json.dumps(doc))
        self.assertEqual(policy.revoke_consent(self.path, "azure"), 0)                 # nothing in it was trustworthy enough to count
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual((got.entries, got.tampered, got.problem), ((), False, None))

    def test_a_file_without_integrity_is_not_kept_by_a_rewrite(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text(json.dumps({"schema": 1, "entries": [policy._entry_to_dict(relay_entry())]}))
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        self.assertEqual([e.engine for e in policy.load_consents(self.path, machine_id=MACHINE).entries], ["azure"])

    def test_damage_is_no_consent_with_a_problem(self):
        self.path.parent.mkdir(parents=True)
        for text, problem in [("{", "bad-json"), ("", "bad-json"), ("[]", "bad-schema"), ('{"schema": 2, "entries": []}', "bad-schema"),
                              ('{"schema": 1, "entries": {}}', "bad-schema"), ('{"schema": 1}', "bad-schema"), ("null", "bad-schema")]:
            with self.subTest(text=text):
                self.path.write_text(text)
                got = policy.load_consents(self.path, machine_id=MACHINE)
                self.assertEqual((got.entries, got.problem), ((), problem))
        self.path.write_bytes(b"\xff\xfe")
        self.assertEqual(policy.load_consents(self.path, machine_id=MACHINE).problem, "bad-json")
        self.path.write_text(" " * (policy.MAX_CONSENT_BYTES + 1))
        self.assertEqual(policy.load_consents(self.path, machine_id=MACHINE).problem, "too-large")

    def test_a_hand_edit_is_tampering_and_voids_every_entry(self):
        policy.write_consent(self.path, relay_entry(), machine_id=MACHINE)
        policy.write_consent(self.path, azure_entry(), machine_id=MACHINE)
        doc = json.loads(self.path.read_text())
        doc["entries"][0]["host"] = "evil.example"
        self.path.write_text(json.dumps(doc))
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual((got.tampered, got.problem), (True, "integrity"))
        self.assertEqual(len(got.entries), 2)                                          # still visible for doctor
        for engine, host, args in (("remote", RELAY, RELAY_ARGS), ("azure", AZURE_HOST, AZURE_ARGS)):
            self.assertEqual(got.valid_for(engine, host, 443, "primary", now=NOW, **args), (None, "consent-tampered"))
        del doc["integrity"]
        self.path.write_text(json.dumps(doc))
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual((got.tampered, got.problem), (True, "integrity-missing"))
        doc["integrity"] = 5
        self.path.write_text(json.dumps(doc))
        self.assertTrue(policy.load_consents(self.path, machine_id=MACHINE).tampered)

    def test_a_malformed_entry_is_dropped_alone(self):
        good = policy._entry_to_dict(relay_entry())
        bad = [dict(good, id=5), dict(good, port="443"), dict(good, port=True), dict(good, use="never"), dict(good, expires="soon"),
               dict(good, ca_sha256="xyz"), dict(good, cert_sha256="abc"), dict(good, cert_sha256=["zz"]), dict(good, daily_minutes_cap=-5),
               {k: v for k, v in good.items() if k != "host"}, "not a dict", None, dict(good, host="")]
        policy._write_consent_file(self.path, [good, *bad])
        got = policy.load_consents(self.path, machine_id=MACHINE)
        self.assertEqual(got.entries, (relay_entry(),))
        self.assertEqual(got.problem, f"bad-entries:{len(bad)}")
        self.assertFalse(got.tampered)

    def test_optional_fields(self):
        policy.write_consent(self.path, relay_entry(cert_sha256=("C" * 64,), daily_minutes_cap=30, ca_sha256=None), machine_id=MACHINE)
        got = policy.load_consents(self.path, machine_id=MACHINE).entries[0]
        self.assertEqual((got.cert_sha256, got.daily_minutes_cap, got.ca_sha256), (("c" * 64,), 30, None))

    def test_machine_id(self):
        out = "  | |   \"IOPlatformUUID\" = \"ABCDEF01-2345-6789-ABCD-EF0123456789\"\n"
        fake = lambda argv, **kw: SimpleNamespace(stdout=out, returncode=0)  # noqa: E731
        one = policy.machine_id(run=fake)
        self.assertRegex(one, r"^[0-9a-f]{64}$")
        self.assertNotIn("abcdef01", one)                                              # the hardware UUID itself is never stored
        self.assertEqual(one, policy.machine_id(run=fake))
        other = policy.machine_id(run=lambda argv, **kw: SimpleNamespace(stdout=out.replace("ABCDEF01", "ABCDEF02"), returncode=0))
        self.assertNotEqual(one, other)

        def broken(argv, **kw):
            raise OSError("no ioreg")
        fallback = policy.machine_id(run=broken)
        self.assertRegex(fallback, r"^[0-9a-f]{64}$")
        self.assertEqual(fallback, policy.machine_id(run=lambda argv, **kw: SimpleNamespace(stdout="nothing useful", returncode=0)))
        self.assertRegex(policy.machine_id(), r"^[0-9a-f]{64}$")                       # the real ioreg (read only) on this Mac

    def test_load_uses_now_as_the_default_clock_of_valid_for(self):
        policy.write_consent(self.path, relay_entry(expires="2026-10-14"), machine_id=MACHINE)
        early = policy.load_consents(self.path, machine_id=MACHINE, now=datetime(2026, 10, 14, 23, 0).astimezone())
        late = policy.load_consents(self.path, machine_id=MACHINE, now=datetime(2026, 10, 15, 0, 1).astimezone())
        self.assertEqual(early.valid_for("remote", RELAY, 443, "primary", **RELAY_ARGS)[1], "ok")
        self.assertEqual(late.valid_for("remote", RELAY, 443, "primary", **RELAY_ARGS)[1], "consent-expired")


class ConsentValidityTests(unittest.TestCase):
    def check(self, cset, engine="remote", host=RELAY, port=443, role="primary", args=RELAY_ARGS, org=None, now=NOW):
        entry, reason = cset.valid_for(engine, host, port, role, now=now, org=org, **args)
        return reason

    def test_ok_returns_the_entry(self):
        entry, reason = consent_set(relay_entry()).valid_for("remote", RELAY, 443, "primary", now=NOW, **RELAY_ARGS)
        self.assertEqual((reason, entry), ("ok", relay_entry()))
        self.assertEqual(policy.consent_id(entry), "c-relay")

    def test_no_consent_for_the_engine(self):
        self.assertEqual(self.check(consent_set()), "no-consent")
        self.assertEqual(self.check(consent_set(azure_entry())), "no-consent")

    def test_every_binding_field_must_match(self):
        base = consent_set(relay_entry())
        self.assertEqual(self.check(base, host="other.example"), "consent-mismatch")
        self.assertEqual(self.check(base, host=RELAY.upper()), "ok")                    # hosts compare lower-cased
        self.assertEqual(self.check(base, port=8443), "consent-mismatch")
        for key in ("region", "model", "protocol", "backend_kind"):
            self.assertEqual(self.check(base, args=dict(RELAY_ARGS, **{key: "changed"})), "consent-mismatch", key)
        self.assertEqual(self.check(consent_set(relay_entry(), machine="another-mac")), "consent-mismatch")      # given on another Mac
        self.assertEqual(self.check(consent_set(relay_entry(machine="another-mac"))), "consent-mismatch")

    def test_role(self):
        self.assertEqual(self.check(consent_set(relay_entry(use="primary")), role="primary"), "ok")
        self.assertEqual(self.check(consent_set(relay_entry(use="primary")), role="fallback"), "consent-mismatch")
        self.assertEqual(self.check(consent_set(relay_entry(use="fallback")), role="primary"), "consent-mismatch")
        self.assertEqual(self.check(consent_set(relay_entry(use="fallback")), role="fallback"), "ok")
        for role in ("primary", "fallback"):
            self.assertEqual(self.check(consent_set(relay_entry(use="both")), role=role), "ok")

    def test_expiry_is_the_end_of_the_day(self):
        day = relay_entry(expires="2026-10-14")
        self.assertEqual(self.check(consent_set(day), now=datetime(2026, 10, 14, 23, 59).astimezone()), "ok")
        self.assertEqual(self.check(consent_set(day), now=datetime(2026, 10, 15, 0, 1).astimezone()), "consent-expired")
        stamp = relay_entry(expires="2026-10-14T12:00:00+00:00")
        self.assertEqual(self.check(consent_set(stamp), now=datetime(2026, 10, 14, 11, 59, tzinfo=timezone.utc)), "ok")
        self.assertEqual(self.check(consent_set(stamp), now=datetime(2026, 10, 14, 12, 1, tzinfo=timezone.utc)), "consent-expired")
        naive = datetime(2026, 10, 14, 12, 0, 0)                                          # a naive clock is local time
        self.assertEqual(self.check(consent_set(relay_entry(expires="2099-01-01")), now=naive), "ok")

    def test_ranking_when_several_entries_fail_differently(self):
        wrong_host = relay_entry(host="other.example", id="a")
        expired = relay_entry(expires="2020-01-01", id="b")
        self.assertEqual(self.check(consent_set(wrong_host, expired)), "consent-expired")       # the closest miss is reported
        self.assertEqual(self.check(consent_set(expired, wrong_host)), "consent-expired")
        self.assertEqual(self.check(consent_set(wrong_host)), "consent-mismatch")
        self.assertEqual(self.check(consent_set(wrong_host, relay_entry(id="ok"))), "ok")       # any matching entry wins

    def test_tampered_file_voids_user_consents(self):
        self.assertEqual(self.check(consent_set(relay_entry(), tampered=True)), "consent-tampered")
        self.assertEqual(self.check(consent_set(tampered=True)), "consent-tampered")

    def test_cloud_consent_is_always_the_users(self):
        self.assertEqual(self.check(consent_set(azure_entry()), "azure", AZURE_HOST, args=AZURE_ARGS), "ok")
        oc = policy.OrgConsent("azure", AZURE_HOST, 443, "azure-fast-transcription", "cloud", "both", "2027-10-14", CA, ())
        org = dataclasses.replace(policy.absent_policy(), present=True, valid=True, org_consents=(oc,))
        self.assertEqual(self.check(consent_set(), "azure", AZURE_HOST, args=AZURE_ARGS, org=org), "no-consent")   # org consent cannot cover a cloud

    def org(self, **kw):
        oc = policy.OrgConsent("remote", RELAY, 443, "mcap-asr/1", "server", kw.pop("use", "both"), kw.pop("expires", "2027-10-14"), CA, (BUILD,))
        oc = dataclasses.replace(oc, **kw)
        return dataclasses.replace(policy.absent_policy(), present=True, valid=True, org_consents=(oc,)), oc

    def test_org_consent_covers_a_server_without_a_user_consent(self):
        org, oc = self.org()
        entry, reason = consent_set().valid_for("remote", RELAY, 443, "primary", now=NOW, org=org, **RELAY_ARGS)
        self.assertEqual((reason, entry), ("ok", oc))
        self.assertTrue(policy.consent_id(entry).startswith("org:remote-"))
        self.assertEqual(self.check(consent_set(), role="fallback", org=org), "ok")

    def test_org_consent_beats_a_tampered_user_file(self):
        org, _ = self.org()
        self.assertEqual(self.check(consent_set(relay_entry(), tampered=True), org=org), "ok")

    def test_org_consent_checks_the_same_things(self):
        org, _ = self.org()
        self.assertEqual(self.check(consent_set(), host="other.example", org=org), "consent-mismatch")
        self.assertEqual(self.check(consent_set(), port=8443, org=org), "consent-mismatch")
        self.assertEqual(self.check(consent_set(), args=dict(RELAY_ARGS, protocol="mcap-asr/2"), org=org), "consent-mismatch")
        self.assertEqual(self.check(consent_set(), args=dict(RELAY_ARGS, backend_kind="cloud"), org=org), "consent-mismatch")
        expired, _ = self.org(expires="2020-01-01")
        self.assertEqual(self.check(consent_set(), org=expired), "consent-expired")
        primary_only, _ = self.org(use="primary")
        self.assertEqual(self.check(consent_set(), role="fallback", org=primary_only), "consent-mismatch")
        self.assertEqual(self.check(consent_set(), role="primary", org=primary_only), "ok")

    def test_user_consent_can_still_cover_what_the_org_consent_misses(self):
        expired, _ = self.org(expires="2020-01-01")
        self.assertEqual(self.check(consent_set(relay_entry()), org=expired), "ok")

    def test_an_invalid_policy_contributes_no_org_consent(self):
        org, _ = self.org()
        self.assertEqual(self.check(consent_set(), org=dataclasses.replace(org, valid=False)), "no-consent")
        self.assertEqual(self.check(consent_set(), org=None), "no-consent")


# ---------------------------------------------------------------------------------------------------- hardware probe
GB = 1024 ** 3
IOREG = '"IOPlatformUUID" = "ABCDEF01-2345-6789-ABCD-EF0123456789"'


class FakeRun:
    """A subprocess.run stand-in answering by argv; records every call. No process is started."""

    def __init__(self, mem_gb=32, arm="1", bench=None, ioreg=IOREG, fail=()):
        self.mem_gb, self.arm, self.bench, self.ioreg, self.fail = mem_gb, arm, bench, ioreg, fail
        self.calls = []

    def __call__(self, argv, **kw):
        self.calls.append(list(argv))
        joined = " ".join(argv)
        for needle in self.fail:
            if needle in joined:
                raise OSError("fake failure: " + needle)
        if "hw.memsize" in joined:
            return SimpleNamespace(stdout=f"{int(self.mem_gb * GB)}\n", returncode=0)
        if "hw.optional.arm64" in joined:
            return SimpleNamespace(stdout=self.arm + "\n", returncode=0)
        if "ioreg" in joined:
            return SimpleNamespace(stdout=self.ioreg, returncode=0)
        if "bench-synth" in joined:
            if isinstance(self.bench, Exception):
                raise self.bench
            return self.bench if isinstance(self.bench, SimpleNamespace) else SimpleNamespace(stdout=json.dumps({"rtf": self.bench}), returncode=0)
        raise AssertionError("unexpected command: " + joined)

    def bench_calls(self):
        return [c for c in self.calls if "bench-synth" in " ".join(c)]


class HardwareProbeTests(TempCase):
    def setUp(self):
        super().setUp()
        self.model = self.root / "model"
        self.model.mkdir()
        self.cfg = make_cfg(self.root, asr_model=str(self.model))
        self.patches = [mock.patch.object(policy, "_module_present", return_value=True), mock.patch.object(policy, "_mlx_version", return_value="0.32.3"),
                        mock.patch("platform.machine", return_value="arm64")]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)
        self.machine = policy.machine_id(run=FakeRun())

    def probe(self, run=None, cfg=None, **kw):
        return policy.probe_hardware(cfg or self.cfg, run=run or FakeRun(), now=NOW, **kw)

    def write_cache(self, **kw):
        doc = {"schema": 1, "probed_at": NOW.isoformat(timespec="seconds"), "machine": self.machine, "mlx_version": "0.32.3", "rtf": 0.1}
        doc.update(kw)
        self.cfg.capability_path.write_text(json.dumps(doc))

    def test_static_facts_of_a_capable_mac(self):
        got = self.probe()
        self.assertEqual((got.arch, got.mem_gb, got.mlx_ok, got.model_present, got.rtf, got.probed_at), ("arm64", 32.0, True, True, None, None))
        self.assertIs(got.capable, True)
        self.assertEqual(got.reasons, ("rtf-unmeasured",))

    def test_ram_threshold_is_inclusive(self):
        self.assertIs(self.probe(FakeRun(mem_gb=16)).capable, True)
        low = self.probe(FakeRun(mem_gb=8))
        self.assertIs(low.capable, False)
        self.assertIn("ram-low", low.reasons)
        self.assertIs(self.probe(FakeRun(mem_gb=15.9)).capable, False)
        cfg = dataclasses.replace(self.cfg, asr_local_min_ram_gb=8)
        self.assertIs(self.probe(FakeRun(mem_gb=8), cfg=cfg).capable, True)

    def test_architecture(self):
        with mock.patch("platform.machine", return_value="x86_64"):
            got = self.probe(FakeRun(arm="0"))
            self.assertEqual((got.arch, got.capable), ("x86_64", False))
            self.assertIn("arch-not-arm64", got.reasons)
            self.assertEqual(self.probe(FakeRun(arm="1")).arch, "arm64")                     # an x86 python under Rosetta on arm64 hardware

    def test_unknown_facts_are_unknown_not_guessed(self):
        got = self.probe(FakeRun(fail=("hw.memsize",)))
        self.assertEqual((got.mem_gb, got.capable), (0.0, None))
        self.assertIn("ram-unknown", got.reasons)
        got = self.probe(FakeRun(fail=("hw.optional.arm64", "hw.memsize")))
        self.assertEqual((got.arch, got.mem_gb, got.capable), ("arm64", 0.0, None))
        cfg = dataclasses.replace(self.cfg, asr_model="not a repo id")
        got = self.probe(cfg=cfg)
        self.assertEqual((got.model_present, got.capable), (None, None))
        self.assertIn("model-unknown", got.reasons)
        low = self.probe(FakeRun(mem_gb=4, fail=("hw.optional.arm64",)), cfg=cfg)
        self.assertIs(low.capable, False)                                                   # one definite no beats the unknowns

    def test_mlx_and_model(self):
        with mock.patch.object(policy, "_module_present", return_value=False):
            got = self.probe()
            self.assertEqual((got.mlx_ok, got.capable), (False, False))
            self.assertIn("mlx-missing", got.reasons)
        with mock.patch.object(policy, "_module_present", side_effect=lambda name: name == "mlx"):
            self.assertIs(self.probe().mlx_ok, False)                                       # mlx without mlx_whisper cannot transcribe
        gone = dataclasses.replace(self.cfg, asr_model="mlx-community/whisper-test")
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": str(self.root / "hub")}):
            got = self.probe(cfg=gone)
            self.assertEqual((got.model_present, got.capable), (False, False))
            self.assertIn("model-missing", got.reasons)

    COMMIT = "c" * 40

    def snapshot(self, hub, repo, commit, files=("config.json", "weights.safetensors"), *, ref=False):
        """A Hugging Face cache entry as the hub library lays it out: snapshots/<commit>/<file> are links into blobs/ (``ref`` writes refs/main)."""
        base = hub / ("models--" + repo.replace("/", "--"))
        snap = base / "snapshots" / commit
        snap.mkdir(parents=True)
        (base / "blobs").mkdir(exist_ok=True)
        for name in files:
            blob = base / "blobs" / ("blob-" + commit[:6] + "-" + name)
            blob.write_bytes(b"x")
            (snap / name).symlink_to(os.path.relpath(blob, snap))                           # relative, like the hub library: the cache can be moved
        if ref:
            (base / "refs").mkdir(exist_ok=True)
            (base / "refs" / "main").write_text(commit)
        return snap

    def present(self, hub, repo):
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": str(hub)}):
            return policy._model_present(dataclasses.replace(self.cfg, asr_model=repo))

    def test_model_present_in_the_hugging_face_cache(self):
        hub = self.root / "hub"
        repo = "mlx-community/whisper-test"                                                  # not pinned: the commit refs/main names
        cfg = dataclasses.replace(self.cfg, asr_model=repo)
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": str(hub)}):
            self.assertIs(policy._model_present(cfg), False)                                 # nothing cached
            snap = self.snapshot(hub, repo, self.COMMIT, ("config.json",), ref=True)
            self.assertIs(policy._model_present(cfg), False)                                 # no weights yet (an interrupted download)
            (snap / "weights.safetensors").write_bytes(b"x")
            self.assertIs(policy._model_present(cfg), True)
        home = self.root / "hf-home"                                                         # HF_HOME/hub is the cache when no *_CACHE variable is set
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": "", "HUGGINGFACE_HUB_CACHE": "", "HF_HOME": str(home)}):
            self.assertIs(policy._model_present(cfg), False)
            (home / "hub").parent.mkdir()
            hub.rename(home / "hub")
            self.assertIs(policy._model_present(cfg), True)
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": "", "HUGGINGFACE_HUB_CACHE": str(home / "hub"), "HF_HOME": "/nonexistent"}):
            self.assertIs(policy._model_present(cfg), True)
        self.assertIsNone(policy._model_present(dataclasses.replace(cfg, asr_model="")))
        self.assertIs(policy._model_present(dataclasses.replace(cfg, asr_model=str(self.model))), True)       # a local directory is taken as it is

    def test_only_the_revision_the_engine_loads_counts(self):
        """The engine loads the pinned revision with local_files_only; another snapshot of the same repo is not 'the model' (with ASR_ALLOW_DOWNLOAD
        off it raises ModelNotAvailable instead of falling back to the relay, while the probe said 'capable')."""
        from mcap import asr_engines
        repo = "mlx-community/whisper-large-v3-mlx"
        pin = asr_engines.REVISION_PINS[repo]
        hub = self.root / "hub"
        self.snapshot(hub, repo, "d" * 40, ref=True)                                         # complete, and even what refs/main names: still not the pin
        self.assertIs(self.present(hub, repo), False)
        self.snapshot(hub, repo, pin, ("config.json",))                                      # the pin, but the download stopped before the weights
        self.assertIs(self.present(hub, repo), False)
        (hub / ("models--" + repo.replace("/", "--")) / "snapshots" / pin / "weights.npz").write_bytes(b"x")
        self.assertIs(self.present(hub, repo), True)
        with mock.patch.dict(asr_engines.REVISION_PINS, {repo: "e" * 40}):                   # the pin moves: the old snapshot is no longer the model
            self.assertIs(self.present(hub, repo), False)

    def test_a_dangling_weights_link_is_not_a_model(self):
        repo = "mlx-community/whisper-test"
        hub = self.root / "hub"
        snap = self.snapshot(hub, repo, self.COMMIT, ref=True)
        self.assertIs(self.present(hub, repo), True)
        (snap / "weights.safetensors").resolve().unlink()                                    # the blob is gone: the name is still listed
        self.assertIn("weights.safetensors", {p.name for p in snap.iterdir()})
        self.assertIs(self.present(hub, repo), False)
        (snap / "weights.npz").write_bytes(b"x")                                             # either of the engine's two weight names will do
        self.assertIs(self.present(hub, repo), True)
        (snap / "config.json").resolve().unlink()                                            # a dangling config is no config
        self.assertIs(self.present(hub, repo), False)

    def test_the_weight_names_are_the_engines_own(self):
        hub = self.root / "hub"
        repo = "mlx-community/whisper-test"
        self.snapshot(hub, repo, self.COMMIT, ("config.json", "model.safetensors", "weights.bin"), ref=True)
        self.assertIs(self.present(hub, repo), False)                                        # the engine looks for weights.safetensors / weights.npz only

    def test_an_unpinned_repo_follows_refs_main(self):
        repo = "mlx-community/whisper-test"
        hub = self.root / "hub"
        base = hub / ("models--" + repo.replace("/", "--"))
        self.snapshot(hub, repo, self.COMMIT)                                                # complete, but no refs/main: the offline lookup fails
        self.assertIs(self.present(hub, repo), False)
        (base / "refs").mkdir()
        for ref, expected in ((self.COMMIT, True), (self.COMMIT + "\n", True), ("a" * 40, False), ("", False), ("../snapshots/" + self.COMMIT, False),
                              ("main", False), (self.COMMIT.upper(), False)):
            with self.subTest(ref=ref):
                (base / "refs" / "main").write_text(ref)
                self.assertIs(self.present(hub, repo), expected)
        (base / "refs" / "main").unlink()
        (base / "refs" / "main").mkdir()                                                     # a refs/main that cannot be read
        self.assertIs(self.present(hub, repo), False)

    def test_unknown_when_the_engine_module_cannot_be_imported(self):
        hub = self.root / "hub"
        repo = "mlx-community/whisper-test"
        self.snapshot(hub, repo, self.COMMIT, ref=True)
        with mock.patch.object(policy, "_cached_snapshot", side_effect=ImportError("numpy")):
            self.assertIsNone(self.present(hub, repo))                                       # which revision the engine wants is unknown: never a guess
        with mock.patch.dict(os.environ, {"HF_HUB_CACHE": str(hub)}):
            cfg = dataclasses.replace(self.cfg, asr_model=repo)
            with mock.patch.object(policy, "_cached_snapshot", side_effect=ImportError("numpy")):
                got = self.probe(cfg=cfg)
        self.assertEqual((got.model_present, got.capable), (None, None))
        self.assertIn("model-unknown", got.reasons)

    def test_the_probe_agrees_with_the_engine_on_every_cache_layout(self):
        """The engine's own resolver (local files only, downloads off) is the oracle: probe True <=> it returns a path."""
        try:
            from huggingface_hub import constants
            from mcap import asr_engines
        except ImportError:
            self.skipTest("huggingface_hub or numpy is not installed")
        repo = "mlx-community/whisper-large-v3-mlx"
        pin = asr_engines.REVISION_PINS[repo]
        wrong = "f" * 40
        layouts = {
            "pinned, safetensors": lambda hub: self.snapshot(hub, repo, pin),
            "pinned, npz": lambda hub: self.snapshot(hub, repo, pin, ("config.json", "weights.npz")),
            "pinned, config only": lambda hub: self.snapshot(hub, repo, pin, ("config.json",)),
            "pinned, weights only": lambda hub: self.snapshot(hub, repo, pin, ("weights.safetensors",)),
            "pinned, other weight name": lambda hub: self.snapshot(hub, repo, pin, ("config.json", "model.safetensors")),
            "pinned, dangling weights": lambda hub: self.dangle(self.snapshot(hub, repo, pin)),
            "wrong revision, refs/main": lambda hub: self.snapshot(hub, repo, wrong, ref=True),
            "wrong revision, no ref": lambda hub: self.snapshot(hub, repo, wrong),
            "pin and a wrong one": lambda hub: (self.snapshot(hub, repo, wrong, ref=True), self.snapshot(hub, repo, pin)),
            "nothing": lambda hub: hub.mkdir(),
        }
        verdicts = {}
        quiet = mock.patch.object(asr_engines, "log", mock.Mock())                             # the resolver warns about an incomplete copy
        quiet.start()
        self.addCleanup(quiet.stop)
        for index, (name, build) in enumerate(layouts.items()):
            hub = self.root / f"oracle-hub-{index}"
            build(hub)
            hub.mkdir(exist_ok=True)
            with self.subTest(layout=name), mock.patch.object(constants, "HF_HUB_CACHE", str(hub)):
                try:
                    asr_engines.resolve_model_path(repo, allow_download=False, check=asr_engines._whisper_files_present)
                    engine = True
                except asr_engines.ModelNotAvailable:
                    engine = False
                verdicts[name] = self.present(hub, repo)
                self.assertIs(verdicts[name], engine)
        self.assertEqual({v for v in verdicts.values()}, {True, False})                      # the table is not trivially one-sided

    @staticmethod
    def dangle(snap):
        (snap / "weights.safetensors").resolve().unlink()
        return snap

    def test_the_cached_benchmark_is_used_while_valid(self):
        self.write_cache(rtf=0.1)
        got = self.probe()
        self.assertEqual((got.rtf, got.capable, got.probed_at), (0.1, True, NOW.isoformat(timespec="seconds")))
        self.assertNotIn("rtf-unmeasured", got.reasons)
        self.write_cache(rtf=0.25)
        self.assertIs(self.probe().capable, True)                                            # the limit is inclusive
        self.write_cache(rtf=0.40)
        slow = self.probe()
        self.assertIs(slow.capable, False)
        self.assertIn("rtf-slow", slow.reasons)
        self.assertIs(self.probe(cfg=dataclasses.replace(self.cfg, asr_local_max_rtf=0.5)).capable, True)

    def test_a_cache_that_cannot_be_trusted_is_ignored(self):
        probed = lambda delta: (NOW - delta).isoformat(timespec="seconds")  # noqa: E731
        for name, kw in [("stale", {"probed_at": probed(timedelta(days=31))}), ("future", {"probed_at": probed(-timedelta(days=3))}),
                         ("machine", {"machine": "another"}), ("mlx", {"mlx_version": "0.1"}), ("zero", {"rtf": 0}), ("negative", {"rtf": -1}),
                         ("bool", {"rtf": True}), ("string", {"rtf": "0.1"}), ("nan", {"rtf": float("nan")}), ("schema", {"schema": 2}),
                         ("no time", {"probed_at": "yesterday"})]:
            with self.subTest(case=name):
                self.write_cache(**kw)
                got = self.probe()
                self.assertEqual((got.rtf, got.probed_at, got.capable), (None, None, True), name)
        for text in ("{", "[]", "", "null"):
            self.cfg.capability_path.write_text(text)
            self.assertIsNone(self.probe().rtf)
        self.cfg.capability_path.unlink()
        self.assertIsNone(self.probe().rtf)
        self.write_cache(probed_at=probed(timedelta(days=29)))
        self.assertEqual(self.probe().rtf, 0.1)                                              # inside the 30 days
        with mock.patch.object(policy, "_mlx_version", return_value=None):
            self.assertIsNone(self.probe().rtf)                                              # mlx got uninstalled since

    def test_measure_runs_the_benchmark_and_caches_it(self):
        run = FakeRun(bench=0.12)
        got = self.probe(run, measure=True)
        self.assertEqual((got.rtf, got.capable, got.probed_at), (0.12, True, NOW.isoformat(timespec="seconds")))
        self.assertEqual(len(run.bench_calls()), 1)
        argv = run.bench_calls()[0]
        self.assertEqual(argv[0], str(self.cfg.python_bin))
        self.assertEqual(tuple(argv[1:]), policy.PROBE_BENCH_ARGV)
        doc = json.loads(self.cfg.capability_path.read_text())
        self.assertEqual((doc["rtf"], doc["machine"], doc["mlx_version"], doc["schema"]), (0.12, self.machine, "0.32.3", 1))
        again = self.probe()                                                                 # a later probe without measuring reads the cache
        self.assertEqual(again.rtf, 0.12)

    def test_measure_refuses_while_a_recording_is_live(self):
        sess = make_session(self.cfg, "2026-10-14_1000_live", end=None)
        now = datetime.now().astimezone()
        run = FakeRun(bench=0.12)
        with self.assertRaises(policy.ProbeRefused):
            policy.probe_hardware(self.cfg, run=run, now=now, measure=True)
        self.assertEqual(run.bench_calls(), [])
        self.assertFalse(self.cfg.capability_path.exists())
        policy.probe_hardware(self.cfg, run=run, now=now)                                    # without measure a live recording is no problem
        # a recording that crashed minutes ago is not live
        past = time.time() - 600
        for f in sess.iterdir():
            os.utime(f, (past, past))
        self.assertEqual(policy.probe_hardware(self.cfg, run=run, now=datetime.now().astimezone(), measure=True).rtf, 0.12)

    def test_live_recording_rule(self):
        now = datetime.now().astimezone()
        done = make_session(self.cfg, "2026-10-14_0900_done")                                # end_time set
        self.assertFalse(policy._live_recording(self.cfg, now))
        live = make_session(self.cfg, "2026-10-14_1000_live", end=None)
        self.assertTrue(policy._live_recording(self.cfg, now))
        self.assertFalse(policy._live_recording(self.cfg, now + timedelta(seconds=policy.LIVE_WINDOW_SECONDS + 5)))
        (live / "session.json").write_text("{")                                              # unreadable: not counted
        self.assertFalse(policy._live_recording(self.cfg, now))
        self.assertFalse(policy._live_recording(SimpleNamespace(sessions_dir=self.root / "nowhere"), now))
        self.assertFalse(policy._live_recording(SimpleNamespace(), now))
        self.assertTrue(done.exists())

    def test_a_failing_benchmark_leaves_the_rtf_unknown(self):
        for bench in (OSError("no python"), SimpleNamespace(stdout="not json", returncode=0), SimpleNamespace(stdout="", returncode=0),
                      SimpleNamespace(stdout=json.dumps({"rtf": 0.1}), returncode=1), 0, -2, True, "x", float("nan"), None):
            with self.subTest(bench=repr(bench)):
                run = FakeRun(bench=bench)
                got = self.probe(run, measure=True)
                self.assertIsNone(got.rtf)
                self.assertIn("bench-failed", got.reasons)
                self.assertFalse(self.cfg.capability_path.exists())
                self.assertEqual(len(run.bench_calls()), 1)


# ---------------------------------------------------------------------------------------------------- the decision table
class DecideBase(PolicyCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root, asr_remote_url=f"https://{RELAY}", asr_engine="whisper", asr_fallback="none")
        self.free, self.shut = policy.LocalOnly(False, "session"), policy.LocalOnly(True, "session")
        self.capable = SimpleNamespace(capable=True)
        self.weak = SimpleNamespace(capable=False)
        self.unknown = SimpleNamespace(capable=None)
        self.open = self.load(minimal())

    def cfg_with(self, **kw):
        return dataclasses.replace(self.cfg, **kw)

    def decide(self, *, cfg=None, pol=None, lo=None, consents=None, hw=..., **kw):
        return policy.decide_asr(cfg or self.cfg, pol if pol is not None else self.open, lo or self.free,
                                 consents if consents is not None else consent_set(), self.capable if hw is ... else hw, now=NOW, **kw)

    def company_open(self, **asr):
        item = {"engine": "remote", "host": RELAY, "port": 443, "protocol": "mcap-asr/1", "backend_kind": "server", "ca_sha256": CA,
                "attest_build_sha256": [BUILD], "use": "both", "expires": "2027-10-14"}
        doc = company(lanes={"asr_remote": "allow", "asr_cloud": "allow"}, approvals={"asr_cloud": "LEGAL-77"},
                      asr=dict({"allowed_engines": ["whisper", "remote", "azure"], "allowed_hosts": [RELAY, AZURE_HOST], "org_consents": [item]}, **asr))
        return self.load(doc)


class DecideAsrTests(DecideBase):
    def test_the_default_run_is_local_whisper_and_sends_nothing(self):
        d = self.decide()
        self.assertEqual((d.primary, d.fallback, d.allow_egress, d.blocked, d.reason), ("whisper", None, False, None, "ok"))
        self.assertEqual((dict(d.hosts), dict(d.consent_ids), d.send_vocab, d.local_only, d.allow_download), ({}, {}, False, False, True))
        self.assertEqual(d.notes, ())
        self.assertTrue(policy.is_issued(d))

    def test_is_issued_rejects_look_alikes(self):
        d = self.decide()
        self.assertTrue(policy.is_issued(dataclasses.replace(d, reason="x")))             # a copy of a real decision is still one
        built = policy.AsrDecision(primary="remote", fallback=None, allow_egress=True, local_only=False, allow_download=False, hosts={},
                                   consent_ids={}, blocked=None, reason="ok", local_capable=True, notes=(), send_vocab=False)
        self.assertFalse(policy.is_issued(built))
        self.assertFalse(policy.is_issued(None))
        self.assertFalse(policy.is_issued(SimpleNamespace(_issued=policy._ISSUER)))

    def remote_cfg(self, **kw):
        return self.cfg_with(asr_engine="remote", **kw)

    def test_remote_with_a_user_consent(self):
        cfg = self.remote_cfg(asr_remote_ca_file=self.root / "relay-ca.pem")
        entry = relay_entry(cert_sha256=("c" * 64,))
        d = self.decide(cfg=cfg, consents=consent_set(entry))
        self.assertEqual((d.primary, d.fallback, d.allow_egress, d.blocked, d.reason), ("remote", None, True, None, "ok"))
        rule = d.hosts[RELAY]
        self.assertEqual((rule.host, rule.port, rule.ca_pem_sha256, rule.ca_file, rule.cert_sha256),
                         (RELAY, 443, CA, str(self.root / "relay-ca.pem"), ("c" * 64,)))
        self.assertEqual((rule.max_request_bytes, rule.max_response_bytes), (2_500_000, 262_144))
        self.assertEqual((dict(d.consent_ids), dict(d.engine_hosts)), ({"remote": "c-relay"}, {"remote": RELAY}))
        self.assertTrue(d.send_vocab)
        self.assertTrue(d.allow_download)                                                      # unchanged: a run with an external engine may still fetch

    def test_remote_with_an_org_consent_needs_no_user_consent(self):
        d = self.decide(cfg=self.remote_cfg(), pol=self.company_open())
        self.assertEqual((d.primary, d.allow_egress, d.reason), ("remote", True, "ok"))
        self.assertTrue(d.consent_ids["remote"].startswith("org:remote-"))
        self.assertEqual(d.hosts[RELAY].ca_pem_sha256, CA)

    def test_no_consent_no_remote(self):
        d = self.decide(cfg=self.remote_cfg())
        self.assertEqual((d.primary, d.allow_egress, d.blocked, d.reason, dict(d.hosts)), ("whisper", False, None, "no-consent", {}))
        self.assertIn("remote: excluded (no-consent)", d.notes)
        self.assertIn("using local whisper instead", d.notes)

    def test_each_consent_failure_has_its_code(self):
        cfg = self.remote_cfg()
        cases = [("mismatch", consent_set(relay_entry(host="other.example")), "consent-mismatch"),
                 ("expired", consent_set(relay_entry(expires="2020-01-01")), "consent-expired"),
                 ("tampered", consent_set(relay_entry(), tampered=True), "consent-tampered"),
                 ("machine", consent_set(relay_entry(machine="other")), "consent-mismatch"),
                 ("role", consent_set(relay_entry(use="fallback")), "consent-mismatch"),
                 ("none", consent_set(), "no-consent")]
        for name, cset, reason in cases:
            with self.subTest(case=name):
                d = self.decide(cfg=cfg, consents=cset)
                self.assertEqual((d.primary, d.allow_egress, d.reason), ("whisper", False, reason))

    def test_a_consent_does_not_open_a_closed_gate(self):
        cset = consent_set(relay_entry())
        cfg = self.remote_cfg()
        d = self.decide(cfg=cfg, consents=cset, lo=self.shut)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.local_only, d.allow_download), ("whisper", False, "local_only", True, False))
        d = self.decide(cfg=cfg, consents=cset, pol=self.load("{"), lo=self.free)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.allow_download), ("whisper", False, "policy-locked", False))
        d = self.decide(cfg=self.cfg, lo=self.shut)                                           # nothing external asked: the reason still says why
        self.assertEqual((d.reason, d.allow_egress, d.blocked), ("local_only", False, None))

    def test_a2_policy_limits(self):
        cfg, cset = self.remote_cfg(), consent_set(relay_entry())
        lane_off = self.load(minimal(lanes={"asr_remote": "deny"}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=lane_off).reason, "policy-lane")
        no_engine = self.load(minimal(asr={"allowed_engines": ["whisper"]}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=no_engine).reason, "policy-engine")
        no_host = self.load(minimal(asr={"allowed_hosts": ["other.example"]}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=no_host).reason, "policy-host")
        yes_host = self.load(minimal(asr={"allowed_hosts": [RELAY.upper()], "allowed_engines": ["Remote"]}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=yes_host).primary, "remote")
        company_omitted = self.load(company(lanes={"asr_remote": "allow"}))                   # company: omitted lists are empty
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=company_omitted).reason, "policy-engine")
        only_hosts_missing = self.load(company(lanes={"asr_remote": "allow"}, asr={"allowed_engines": ["remote"]}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=only_hosts_missing).reason, "policy-host")
        unapproved = self.load(company(lanes={"asr_cloud": "allow"}))
        azure = self.cfg_with(asr_engine="azure")
        self.assertEqual(self.decide(cfg=azure, consents=consent_set(azure_entry()), pol=unapproved).reason, "policy-unapproved")

    def test_local_whisper_is_never_excluded_by_a_policy_list(self):
        closed = self.load(company())
        d = self.decide(pol=closed)
        self.assertEqual((d.primary, d.blocked, d.reason), ("whisper", None, "ok"))
        d = self.decide(pol=closed, hw=self.weak)
        self.assertEqual((d.primary, d.blocked), ("whisper", None))                           # ASR_ENGINE=whisper is tried even on weak hardware

    def test_a2_foreign_residency(self):
        cfg = self.cfg_with(asr_engine="azure")
        cset = consent_set(azure_entry())
        with mock.patch.dict(policy.ENGINE_META["azure"], {"residency": "foreign"}):
            self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=self.load(minimal())).reason, "policy-foreign")
            self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=self.load(minimal(asr={"allow_foreign": True}))).primary, "azure")
            self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=policy.absent_policy()).primary, "azure")    # no policy: nothing restricts
        self.assertEqual(self.decide(cfg=cfg, consents=cset).primary, "azure")                       # residency kr

    def test_a2_daily_cap(self):
        cfg, cset = self.remote_cfg(asr_cloud_daily_minutes=60), consent_set(relay_entry())
        self.assertEqual(self.decide(cfg=cfg, consents=cset, used_minutes_today=59.9).primary, "remote")
        d = self.decide(cfg=cfg, consents=cset, used_minutes_today=60)
        self.assertEqual((d.primary, d.reason), ("whisper", "cap"))
        capped = self.load(minimal(asr={"daily_audio_minutes_cap": 30}))
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=capped, used_minutes_today=30).reason, "cap")         # the smaller cap wins
        self.assertEqual(self.decide(cfg=cfg, consents=cset, pol=capped, used_minutes_today=29).primary, "remote")
        self.assertEqual(self.decide(cfg=self.remote_cfg(asr_cloud_daily_minutes=0), consents=cset).reason, "cap")     # 0 = no external audio
        self.assertEqual(self.decide(cfg=self.remote_cfg(asr_cloud_daily_minutes=1000), consents=consent_set(relay_entry(daily_minutes_cap=10)),
                                     used_minutes_today=10).reason, "cap")                                           # the consent's own cap
        self.assertEqual(self.decide(cfg=self.remote_cfg(asr_cloud_daily_minutes=1000), pol=self.load(minimal(asr={"daily_audio_minutes_cap": 0})),
                                     consents=cset).reason, "cap")

    def test_a4_unknown_words_read_as_the_harmless_value(self):
        d = self.decide(cfg=self.cfg_with(asr_engine="banana", asr_fallback="carrot"))
        self.assertEqual((d.primary, d.fallback), ("whisper", None))
        self.assertIn("ASR_ENGINE: unrecognised value read as whisper", d.notes)
        self.assertIn("ASR_FALLBACK: unrecognised value read as none", d.notes)
        d = self.decide(cfg=self.cfg_with(asr_engine=" Remote ", asr_fallback="WHISPER"), consents=consent_set(relay_entry()))
        self.assertEqual((d.primary, d.fallback), ("remote", "whisper"))

    def test_a5_auto(self):
        cfg, cset = self.cfg_with(asr_engine="auto"), consent_set(relay_entry())
        d = self.decide(cfg=cfg, consents=cset, hw=self.capable)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.local_capable), ("whisper", False, "hw-capable", True))
        d = self.decide(cfg=cfg, consents=cset, hw=self.unknown)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.local_capable), ("whisper", False, "hw-unknown", None))
        d = self.decide(cfg=cfg, consents=cset, hw=None)
        self.assertEqual((d.primary, d.reason), ("whisper", "hw-unknown"))
        d = self.decide(cfg=cfg, consents=cset, hw=self.weak)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.blocked, d.local_capable), ("remote", True, "hw-incapable", None, False))
        d = self.decide(cfg=self.cfg_with(asr_engine="auto", asr_remote_url=""), consents=cset, hw=self.weak)       # nothing to fall back to
        self.assertEqual((d.primary, d.blocked, d.reason), ("whisper", "asr_policy_blocked", "not-configured"))

    def test_auto_never_picks_a_cloud_engine(self):
        cfg = self.cfg_with(asr_engine="auto", asr_remote_url="")
        d = self.decide(cfg=cfg, consents=consent_set(azure_entry()), hw=self.weak)
        self.assertEqual((d.primary, d.blocked, d.allow_egress), ("whisper", "asr_policy_blocked", False))

    def test_a6_blocked_only_when_nothing_can_transcribe(self):
        remote = self.remote_cfg()
        d = self.decide(cfg=remote, hw=self.weak)                                                 # no consent + a Mac that cannot run Whisper
        self.assertEqual((d.blocked, d.primary, d.reason, d.allow_egress), ("asr_policy_blocked", "whisper", "no-consent", False))
        self.assertEqual(self.decide(cfg=remote, hw=self.unknown).blocked, None)                  # unknown is tried
        self.assertEqual(self.decide(cfg=remote, hw=self.capable).blocked, None)
        d = self.decide(cfg=remote, hw=self.weak, lo=self.shut, consents=consent_set(relay_entry()))     # local-only + weak Mac: the clinical case
        self.assertEqual((d.blocked, d.reason), ("asr_policy_blocked", "local_only"))
        d = self.decide(cfg=remote, hw=self.weak, pol=self.load("{"))
        self.assertEqual((d.blocked, d.reason), ("asr_policy_blocked", "policy-locked"))
        d = self.decide(cfg=self.cfg_with(asr_engine="whisper"), hw=self.weak, lo=self.shut)      # ASR_ENGINE=whisper is never blocked
        self.assertEqual((d.blocked, d.primary, d.reason), (None, "whisper", "local_only"))
        d = self.decide(cfg=remote, hw=self.weak, consents=consent_set(relay_entry()))            # usable remote: nothing blocked
        self.assertEqual((d.blocked, d.primary), (None, "remote"))

    def test_fallback_local_and_external(self):
        cset = consent_set(relay_entry(), azure_entry(use="both"))
        cfg = self.remote_cfg(asr_fallback="whisper")
        d = self.decide(cfg=cfg, consents=cset)
        self.assertEqual((d.primary, d.fallback), ("remote", "whisper"))
        d = self.decide(cfg=cfg, consents=cset, hw=self.weak)
        self.assertEqual((d.primary, d.fallback), ("remote", None))
        self.assertIn("whisper fallback dropped (this Mac cannot run it)", d.notes)
        d = self.decide(cfg=self.cfg_with(asr_engine="whisper", asr_fallback="azure"), consents=cset)
        self.assertEqual((d.primary, d.fallback, d.allow_egress), ("whisper", "azure", True))
        self.assertEqual((set(d.hosts), dict(d.engine_hosts)), ({AZURE_HOST}, {"azure": AZURE_HOST}))
        d = self.decide(cfg=self.remote_cfg(asr_fallback="azure"), consents=cset)
        self.assertEqual((d.primary, d.fallback), ("remote", "azure"))
        self.assertEqual(set(d.hosts), {RELAY, AZURE_HOST})
        self.assertEqual(dict(d.consent_ids), {"remote": "c-relay", "azure": "c-azure"})

    def test_an_external_fallback_needs_its_own_consent_with_the_fallback_role(self):
        cfg = self.cfg_with(asr_engine="whisper", asr_fallback="azure")
        d = self.decide(cfg=cfg, consents=consent_set(azure_entry(use="primary")))
        self.assertEqual((d.fallback, d.allow_egress), (None, False))
        self.assertIn(f"azure: fallback excluded (consent-mismatch)", d.notes)
        self.assertEqual(self.decide(cfg=cfg, consents=consent_set(azure_entry(use="fallback"))).fallback, "azure")
        self.assertEqual(self.decide(cfg=cfg, consents=consent_set()).fallback, None)
        d = self.decide(cfg=cfg, consents=consent_set(azure_entry(use="both")), lo=self.shut)           # local-only closes the fallback too
        self.assertEqual((d.fallback, d.allow_egress), (None, False))
        pol = self.load(minimal(lanes={"asr_cloud": "deny"}))
        self.assertEqual(self.decide(cfg=cfg, consents=consent_set(azure_entry(use="both")), pol=pol).fallback, None)

    def test_a_fallback_equal_to_the_primary_is_dropped(self):
        d = self.decide(cfg=self.remote_cfg(asr_fallback="remote"), consents=consent_set(relay_entry()))
        self.assertEqual((d.primary, d.fallback), ("remote", None))
        self.assertIn("fallback equals the primary: dropped", d.notes)
        d = self.decide(cfg=self.cfg_with(asr_engine="whisper", asr_fallback="whisper"))
        self.assertEqual((d.primary, d.fallback), ("whisper", None))

    def test_when_the_primary_is_excluded_the_fallback_does_not_become_the_primary(self):
        cfg = self.cfg_with(asr_engine="remote", asr_fallback="azure")
        d = self.decide(cfg=cfg, consents=consent_set(azure_entry(use="both")))                    # relay has no consent
        self.assertEqual((d.primary, d.fallback, d.reason), ("whisper", "azure", "no-consent"))     # Whisper first, azure still a chunk fallback

    def test_send_vocab_is_the_and_of_user_policy_and_every_external_kind(self):
        cset = consent_set(relay_entry(), azure_entry(use="both"))
        server = self.decide(cfg=self.remote_cfg(), consents=cset)
        self.assertTrue(server.send_vocab)
        self.assertFalse(self.decide(cfg=self.remote_cfg(asr_send_vocab=False), consents=cset).send_vocab)
        company_pol = self.company_open()                                                          # company: server true, cloud false
        self.assertTrue(self.decide(cfg=self.remote_cfg(), pol=company_pol).send_vocab)
        self.assertFalse(self.decide(cfg=self.cfg_with(asr_engine="azure"), pol=company_pol, consents=cset).send_vocab)
        both = self.decide(cfg=self.remote_cfg(asr_fallback="azure"), pol=company_pol, consents=cset)
        self.assertEqual((both.primary, both.fallback, both.send_vocab), ("remote", "azure", False))
        self.assertFalse(self.decide().send_vocab)                                                 # nothing external: nothing sent

    def test_unusable_hosts(self):
        cset = consent_set(relay_entry())
        for url, reason in [("", "not-configured"), ("   ", "not-configured"), (f"http://{RELAY}", "bad-host"), ("https://10.0.0.5", "bad-host"),
                            ("https://[::1]/", "bad-host"), (f"https://user:pw@{RELAY}", "bad-host"), (f"https://{RELAY}.", "bad-host"),
                            ("https://", "bad-host"), (f"https://{RELAY}:notaport", "bad-host"), (f"ftp://{RELAY}", "bad-host"), ("asr.example.internal", "bad-host")]:
            with self.subTest(url=url):
                d = self.decide(cfg=self.remote_cfg(asr_remote_url=url), consents=cset)
                self.assertEqual((d.primary, d.allow_egress, d.reason), ("whisper", False, reason))

    def test_url_port_and_case(self):
        d = self.decide(cfg=self.remote_cfg(asr_remote_url=f"https://{RELAY.upper()}:8443/base/path"), consents=consent_set(relay_entry(port=8443)))
        self.assertEqual((d.primary, d.hosts[RELAY].port), ("remote", 8443))
        d = self.decide(cfg=self.remote_cfg(asr_remote_url=f"https://{RELAY}:8443"), consents=consent_set(relay_entry()))     # consent says 443
        self.assertEqual((d.primary, d.reason), ("whisper", "consent-mismatch"))

    def test_azure_host_rules(self):
        cset = consent_set(azure_entry())
        d = self.decide(cfg=self.cfg_with(asr_engine="azure"), consents=cset)
        self.assertEqual((d.primary, d.engine_hosts["azure"]), ("azure", AZURE_HOST))
        custom = "my-speech.cognitiveservices.azure.com"
        d = self.decide(cfg=self.cfg_with(asr_engine="azure", asr_azure_host=custom), consents=consent_set(azure_entry(host=custom)))
        self.assertEqual((d.primary, d.engine_hosts["azure"]), ("azure", custom))
        for host in ("evil.example", "x.api.cognitive.microsoft.com.evil.example", ".api.cognitive.microsoft.com", "api.cognitive.microsoft.com",
                     "cognitiveservices.azure.com", "a b.api.cognitive.microsoft.com", "-x.api.cognitive.microsoft.com", "10.0.0.1"):
            with self.subTest(host=host):
                d = self.decide(cfg=self.cfg_with(asr_engine="azure", asr_azure_host=host), consents=cset)
                self.assertEqual((d.primary, d.reason), ("whisper", "bad-host"))
        for region in ("", "korea central", "kr/x", "a"):
            d = self.decide(cfg=self.cfg_with(asr_engine="azure", asr_azure_region=region), consents=cset)
            self.assertEqual(d.reason, "bad-host", region)
        other = self.cfg_with(asr_engine="azure", asr_azure_region="japaneast")                    # changing the region voids the consent
        self.assertEqual(self.decide(cfg=other, consents=cset).reason, "consent-mismatch")

    def test_consent_binding(self):
        binding, why = policy.consent_binding(self.remote_cfg(), "remote")
        self.assertEqual((why, binding), (None, {"engine": "remote", "kind": "server", "host": RELAY, "port": 443, "region": "", "model": "",
                                                    "protocol": "mcap-asr/1", "backend_kind": "server"}))
        binding, why = policy.consent_binding(self.cfg, "azure")
        self.assertEqual((binding["host"], binding["region"], binding["model"], binding["kind"]), (AZURE_HOST, "koreacentral", "fast-transcription", "cloud"))
        for engine in ("whisper", "qwen3-asr", "google", "clova", "nonsense", ""):
            self.assertEqual(policy.consent_binding(self.cfg, engine), (None, "not-configured"), engine)

    def test_decide_never_raises(self):
        class Hostile:
            def __getattr__(self, name):
                raise RuntimeError("boom")
        with self.assertLogs("mcap.policy", "WARNING"):
            d = policy.decide_asr(Hostile(), self.open, self.free, consent_set(), self.capable, now=NOW)
        self.assertEqual((d.primary, d.allow_egress, d.reason, d.blocked), ("whisper", False, "decision-error", None))
        self.assertTrue(policy.is_issued(d))
        with self.assertLogs("mcap.policy", "WARNING"):
            d = policy.decide_asr(self.cfg, self.open, None, consent_set(), self.capable)
        self.assertEqual((d.allow_egress, d.reason), (False, "decision-error"))
        d = policy.decide_asr(self.cfg, None, self.free, None, None, now=NOW)                      # None policy / consents / hardware are fine
        self.assertEqual((d.primary, d.reason, d.local_capable), ("whisper", "ok", None))

    def test_allow_download_follows_the_flag_and_the_policy(self):
        self.assertTrue(self.decide().allow_download)
        self.assertFalse(self.decide(cfg=self.cfg_with(asr_allow_download=False)).allow_download)
        self.assertFalse(self.decide(lo=self.shut).allow_download)
        self.assertFalse(self.decide(pol=self.load("{")).allow_download)


class EngineMetaTests(unittest.TestCase):
    def test_keys_match_the_engine_registry(self):
        from mcap import asr_engines
        self.assertEqual(set(policy.ENGINE_META), set(asr_engines.REGISTRY))

    def test_kind_and_residency_are_known_values(self):
        for engine, meta in policy.ENGINE_META.items():
            self.assertIn(meta["kind"], ("local", "server", "cloud"), engine)
            self.assertTrue(meta["residency"] in ("device", "foreign") or len(meta["residency"]) == 2, engine)
            self.assertIn(meta["status"], ("ready", "stub", "bench_only"), engine)
            self.assertEqual(meta["lane"], {"local": None, "server": "asr_remote", "cloud": "asr_cloud"}[meta["kind"]], engine)
            self.assertEqual(meta["backend_kind"], {"local": "", "server": "server", "cloud": "cloud"}[meta["kind"]], engine)

    def test_local_engines_agree_with_the_engine_classes(self):
        from mcap import asr_engines
        for engine_id, cls in (("whisper", asr_engines.WhisperEngine), ("qwen3-asr", asr_engines.QwenEngine)):
            self.assertEqual(policy.ENGINE_META[engine_id]["kind"], cls.kind, engine_id)
            self.assertEqual(policy.ENGINE_META[engine_id]["residency"], cls.residency, engine_id)

    def test_selectable_choices_exist_in_the_table(self):
        for choice in policy.ASR_ENGINE_CHOICES + policy.ASR_FALLBACK_CHOICES:
            if choice not in ("auto", "none"):
                self.assertIn(choice, policy.ENGINE_META)
        from mcap import config
        self.assertEqual(config._KEYS["ASR_ENGINE"][1].allowed, policy.ASR_ENGINE_CHOICES)
        self.assertEqual(config._KEYS["ASR_FALLBACK"][1].allowed, policy.ASR_FALLBACK_CHOICES)

    def test_stubs_cannot_be_selected_or_connected(self):
        for engine in ("google",):                                   # clova and openai-compat are providers now (asr_providers): tests/test_asr_providers.py
            self.assertEqual(policy.ENGINE_META[engine]["status"], "stub")
            self.assertNotIn(engine, policy.ASR_ENGINE_CHOICES)
        self.assertEqual(policy.ENGINE_META["google"]["residency"], "foreign")



# ---------------------------------------------------------------------------------------------------- the shared test support (single owner: this package)
class SupportHelperTests(TempCase):
    """notes_cli_support: make_cfg isolates the policy location and FakeSecurity serves several (service, account) items."""

    def test_make_cfg_never_points_at_the_system_policy(self):
        cfg = make_cfg(self.root)
        self.assertNotEqual(cfg.policy_path, Config().policy_path)
        self.assertEqual(cfg.policy_path, self.root / "no-policy" / "policy.json")
        self.assertFalse(cfg.policy_path.exists())
        self.assertTrue(str(cfg.policy_path).startswith(str(self.root)))
        self.assertEqual(policy.load_org_policy(cfg.policy_path, sleep=NOSLEEP).state, "absent")
        mine = self.root / "mine.json"
        self.assertEqual(make_cfg(self.root, policy_path=mine).policy_path, mine)                  # a test may still choose its own

    def test_load_test_policy_helper_for_other_packages(self):
        path = self.root / "etc" / "policy.json"
        pol = load_test_policy(path, minimal())
        self.assertEqual((pol.state, pol.profile), ("valid", "personal"))
        self.assertEqual(load_test_policy(path, minimal("company")).profile, "company")
        self.assertEqual(load_test_policy(path, minimal(), uid=501).locked_reason, "bad-owner")
        self.assertEqual(load_test_policy(path, "{").locked_reason, "bad-json")
        self.assertEqual(load_test_policy(path, b"\xef\xbb\xbf{}").locked_reason, "bom")
        self.assertEqual(load_test_policy(path, minimal(min_pipeline_version="0.3.0")).locked_reason, "pipeline-too-old: 0.3.0")
        self.assertTrue(load_test_policy(path, minimal(min_pipeline_version="0.3.0"), version="0.3.0").valid)
        self.assertEqual(make_stat_fn(path)(path).st_uid, 0)
        self.assertEqual(make_stat_fn(path)(path.parent).st_mode & 0o022, 0)

    def run_find(self, service, account, *, with_w=True):
        import subprocess
        argv = [str(self.security.path), "find-generic-password", "-s", service, "-a", account] + (["-w"] if with_w else [])
        return subprocess.run(argv, capture_output=True, text=True)

    def test_fake_security_serves_several_items(self):
        self.security.store("anthropic-secret", "MeetingCapture Anthropic API key", "alice")
        self.security.store_item("relay-token", "MeetingCapture ASR remote", "alice@asr.example.internal:443")
        self.security.store_item("azure-key", "MeetingCapture ASR azure", "alice@" + AZURE_HOST + ":443")
        for service, account, secret in (("MeetingCapture Anthropic API key", "alice", "anthropic-secret"),
                                         ("MeetingCapture ASR remote", "alice@asr.example.internal:443", "relay-token"),
                                         ("MeetingCapture ASR azure", "alice@" + AZURE_HOST + ":443", "azure-key")):
            done = self.run_find(service, account)
            self.assertEqual((done.returncode, done.stdout), (0, secret + "\n"), service)
        self.assertEqual(self.run_find("MeetingCapture ASR remote", "alice@other.example:443").returncode, 44)      # the account binds the destination
        self.assertEqual(self.run_find("MeetingCapture ASR remote", "alice").returncode, 44)
        self.assertEqual(self.run_find("Nothing", "alice").returncode, 44)
        self.assertIn("login.keychain", self.run_find("MeetingCapture ASR remote", "alice@asr.example.internal:443", with_w=False).stdout)

    def test_fake_security_store_item_replaces_and_remove_clears_all(self):
        self.security.store_item("one", "svc", "acct")
        self.security.store_item("two", "svc", "acct")
        self.assertEqual(self.run_find("svc", "acct").stdout, "two\n")
        self.security.remove()
        self.assertEqual(self.run_find("svc", "acct").returncode, 44)

    def test_fake_security_counts_reads_per_service(self):
        self.security.store_item("t", "svc-a", "acct")
        self.run_find("svc-a", "acct")
        self.run_find("svc-a", "acct")
        self.run_find("svc-b", "acct")
        self.run_find("svc-a", "acct", with_w=False)                                                # existence check, not a read of the secret
        self.assertEqual(self.security.reads(), 3)
        self.assertEqual(self.security.reads("svc-a"), 2)
        self.assertEqual(self.security.reads("svc-b"), 1)
        self.assertEqual(self.security.reads("svc-c"), 0)

    def test_fake_security_delete_of_a_multi_item(self):
        import subprocess
        self.security.store_item("t", "svc-a", "acct")
        self.security.store_item("u", "svc-b", "acct")
        done = subprocess.run([str(self.security.path), "delete-generic-password", "-s", "svc-a", "-a", "acct"], capture_output=True)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(self.run_find("svc-a", "acct").returncode, 44)
        self.assertEqual(self.run_find("svc-b", "acct").stdout, "u\n")
        self.assertEqual(subprocess.run([str(self.security.path), "delete-generic-password", "-s", "svc-a", "-a", "acct"], capture_output=True).returncode, 44)

    def test_the_original_single_item_behaviour_is_unchanged(self):
        self.security.store()
        from mcap import apikey
        found = apikey.lookup(make_cfg(self.root))
        self.assertEqual((found.reason, found.key is not None), ("ok", True))
        self.security.remove()
        self.assertEqual(apikey.lookup(make_cfg(self.root)).reason, "missing")


if __name__ == "__main__":
    unittest.main()
