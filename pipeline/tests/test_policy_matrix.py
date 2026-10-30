"""The policy decision matrix (SPEC 18): policy {none, personal, company open,
company closed, locked, flag-pinned} x session flag {missing, true, false, "false", 0, unreadable} x consent {none, valid, expired, tampered} x
ASR_ENGINE x ASR_FALLBACK x hardware {capable, incapable, unknown}, every cell compared with an INDEPENDENT oracle (a table written from the
design text, sharing no code with policy.py), invariants that must hold in every cell, and 20 hand-written rows that pin concrete verdicts.

Pure: no file is read except the policies built once from temp files through an injected lstat; no clock, network or Keychain.

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import dataclasses
import itertools
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import policy  # noqa: E402
from notes_cli_support import make_cfg  # noqa: E402
import test_policy as tp  # noqa: E402  (module import only: its TestCase classes must not be collected here)

NOW = tp.NOW
UNREADABLE = policy.UNREADABLE
FLAGS = [None, True, False, "false", 0, UNREADABLE]
FLAG_NAMES = {id(None): "missing", id(True): "true", id(False): "false", id(UNREADABLE): "unreadable"}
CONSENTS = ["none", "valid", "expired", "tampered"]
ENGINES = ["whisper", "remote", "azure", "auto"]
FALLBACKS = ["none", "whisper", "remote", "azure"]
HARDWARE = [True, False, None]
POLICIES = ["none", "personal", "pinned", "open", "closed", "locked"]


def flag_name(raw) -> str:
    return repr(raw) if isinstance(raw, (str, int)) and not isinstance(raw, bool) else FLAG_NAMES.get(id(raw), repr(raw))


# ---------------------------------------------------------------------------------------------------- inputs
def build_policies(root: Path) -> dict:
    """Six policies. none: no file. personal: valid, nothing restricted. pinned: personal with local_only.locked. open: company, the two ASR lanes
    allowed (cloud approved), engines and hosts listed, an org consent for the relay. closed: company baseline (everything denied, flag
    default true). locked: a file that is not valid."""
    path = root / "policy.json"

    def load(doc):
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
        return policy.load_org_policy(path, required_marker=root / "none", stat_fn=tp.make_stat_fn(path), current_version="0.2.0", sleep=lambda s: None)
    org = {"engine": "remote", "host": tp.RELAY, "port": 443, "protocol": "mcap-asr/1", "backend_kind": "server", "ca_sha256": tp.CA,
           "attest_build_sha256": [tp.BUILD], "use": "both", "expires": "2027-10-14"}
    return {
        "none": policy.absent_policy(),
        "personal": load(tp.minimal()),
        "pinned": load(tp.minimal(local_only={"locked": True})),
        "open": load(tp.company(lanes={"asr_remote": "allow", "asr_cloud": "allow"}, approvals={"asr_cloud": "LEGAL-77"},
                                asr={"allowed_engines": ["whisper", "remote", "azure"], "allowed_hosts": [tp.RELAY, tp.AZURE_HOST], "org_consents": [org]})),
        "closed": load(tp.company(local_only={"default": True})),
        "locked": load("{"),
    }


def build_consents() -> dict:
    return {
        "none": tp.consent_set(),
        "valid": tp.consent_set(tp.relay_entry(), tp.azure_entry(use="both")),
        "expired": tp.consent_set(tp.relay_entry(expires="2020-01-01"), tp.azure_entry(use="both", expires="2020-01-01")),
        "tampered": tp.consent_set(tp.relay_entry(), tp.azure_entry(use="both"), tampered=True),
    }


# ---------------------------------------------------------------------------------------------------- the oracle
POLICY_FLAG_DEFAULT = {"none": False, "personal": False, "pinned": False, "open": False, "closed": True, "locked": True}


def oracle_flag(pk, raw, cfg_default):
    """SPEC 18, as a table: a locked policy or local_only.locked forces true; an unreadable session is true; a missing value takes the default
    chain (policy default OR LOCAL_ONLY_DEFAULT); a bool is itself; anything else is true."""
    if pk in ("locked", "pinned"):
        return True, "policy-lock"
    if raw is UNREADABLE:
        return True, "fail-closed:unreadable"
    if raw is None:
        return (POLICY_FLAG_DEFAULT[pk] or cfg_default), "default"
    if raw is True or raw is False:
        return raw, "session"
    return True, "fail-closed:bad-type"


USER_CONSENT_REASON = {"none": "no-consent", "valid": None, "expired": "consent-expired", "tampered": "consent-tampered"}


def oracle_external(pk, engine, closed, consent):
    """None when ``engine`` (remote | azure) may be used, else the reason: A0/A1, then the policy, then the consent (A2, A3)."""
    if closed:
        return closed
    if pk == "closed":
        return "policy-lane"
    if engine == "remote" and pk == "open":
        return None                                    # the organisation's own consent covers the relay, whatever the user's file says
    return USER_CONSENT_REASON[consent]


def oracle_asr(pk, flag, engine, fallback, consent, hw):
    closed = "policy-locked" if pk == "locked" else ("local_only" if flag else None)
    hw_reason = {True: "hw-capable", False: "hw-incapable", None: "hw-unknown"}[hw] if engine == "auto" else None
    asked = ("remote" if hw is False else "whisper") if engine == "auto" else engine
    if asked == "whisper":
        primary, blocked, reason = "whisper", None, closed or hw_reason or "ok"
    else:
        why = oracle_external(pk, asked, closed, consent)
        if why is None:
            primary, blocked, reason = asked, None, hw_reason or "ok"
        else:
            primary, blocked, reason = "whisper", ("asr_policy_blocked" if hw is False else None), why
    if blocked or fallback == "none" or fallback == primary:
        second = None
    elif fallback == "whisper":
        second = None if hw is False else "whisper"
    else:
        second = fallback if oracle_external(pk, fallback, closed, consent) is None else None
    egress = primary in ("remote", "azure") or second in ("remote", "azure")
    return {"primary": primary, "fallback": second, "allow_egress": egress, "blocked": blocked, "reason": reason}


class MatrixBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="mcap-matrix-")
        cls.policies = build_policies(Path(cls._tmp.name))
        cls.consents = build_consents()
        cls.root = Path(cls._tmp.name)
        cls.base_cfg = make_cfg(cls.root, asr_remote_url=f"https://{tp.RELAY}", calendar_lookup="auto")
        cls.base_cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def cfg(self, **kw):
        return dataclasses.replace(self.base_cfg, **kw)


class MatrixTests(MatrixBase):
    def test_the_setup_is_what_the_names_say(self):
        p = self.policies
        self.assertEqual([p[k].state for k in POLICIES], ["absent", "valid", "valid", "valid", "valid", "invalid"])
        self.assertTrue(p["pinned"].local_only_locked)
        self.assertEqual(dict(p["open"].lanes), {"asr_remote": "allow", "asr_cloud": "allow", "llm": "deny", "calendar": "deny", "drive": "deny"})
        self.assertTrue(p["closed"].local_only_default)
        self.assertEqual(len(p["open"].org_consents), 1)

    def test_local_only_matrix(self):
        count = 0
        for pk, raw, default in itertools.product(POLICIES, FLAGS, (False, True)):
            got = policy.effective_local_only(raw, self.policies[pk], SimpleNamespace(local_only_default=default))
            self.assertEqual((got.value, got.source), oracle_flag(pk, raw, default), f"{pk} / {flag_name(raw)} / default={default}")
            count += 1
        self.assertEqual(count, 6 * 6 * 2)

    def test_asr_decision_matrix(self):
        cells = 0
        for pk, raw, default in itertools.product(POLICIES, FLAGS, (False, True)):
            pol = self.policies[pk]
            lo = policy.effective_local_only(raw, pol, SimpleNamespace(local_only_default=default))
            for engine, fallback, consent, hw in itertools.product(ENGINES, FALLBACKS, CONSENTS, HARDWARE):
                cfg = self.cfg(asr_engine=engine, asr_fallback=fallback)
                got = policy.decide_asr(cfg, pol, lo, self.consents[consent], SimpleNamespace(capable=hw), now=NOW)
                want = oracle_asr(pk, lo.value, engine, fallback, consent, hw)
                label = f"policy={pk} flag={flag_name(raw)} default={default} engine={engine} fallback={fallback} consent={consent} hw={hw}"
                self.assertEqual({k: getattr(got, k) for k in want}, want, label)
                self.check_invariants(got, pk, lo, engine, consent, label)
                cells += 1
        self.assertEqual(cells, 6 * 6 * 2 * 4 * 4 * 4 * 3)

    def check_invariants(self, d, pk, lo, engine, consent, label):
        external = [e for e in (d.primary, d.fallback) if e in ("remote", "azure")]
        self.assertTrue(policy.is_issued(d), label)
        self.assertEqual(d.allow_egress, bool(external), label)
        self.assertEqual(d.local_only, lo.value, label)
        if lo.value or pk == "locked":                                   # nothing external when the gate is closed, whatever else is configured
            self.assertEqual((external, dict(d.hosts), dict(d.consent_ids), d.send_vocab, d.allow_download), ([], {}, {}, False, False), label)
            self.assertEqual(d.primary, "whisper", label)
        if "azure" in external:                                          # a cloud engine only ever with a valid user consent and an open lane
            self.assertEqual(consent, "valid", label)
            self.assertIn(pk, ("none", "personal", "open", "pinned"), label)
        if pk == "closed" and not lo.value:
            self.assertEqual(external, [], label)                        # the company baseline opens nothing
        self.assertEqual(set(d.engine_hosts), set(external), label)
        self.assertEqual(set(d.consent_ids), set(external), label)
        self.assertEqual(set(d.hosts), set(d.engine_hosts.values()), label)
        if engine == "whisper":
            self.assertEqual((d.primary, d.blocked), ("whisper", None), label)        # an explicit whisper is never blocked or replaced
        if d.blocked:
            self.assertEqual((d.blocked, d.primary, d.fallback, d.allow_egress, d.local_capable), ("asr_policy_blocked", "whisper", None, False, False), label)
        if not external:
            self.assertFalse(d.send_vocab, label)
        self.assertEqual(d.allow_download, (not lo.value) and pk != "locked", label)  # cfg.asr_allow_download is True in this matrix

    def test_lane_matrix(self):
        policy_lanes = {                                                # (allowed, reason) of the POLICY alone, per lane
            "none": dict.fromkeys(policy.LANES, (True, None)), "personal": dict.fromkeys(policy.LANES, (True, None)),
            "pinned": dict.fromkeys(policy.LANES, (True, None)),
            "open": {"asr_remote": (True, None), "asr_cloud": (True, None), "llm": (False, "policy-lane"), "calendar": (False, "policy-lane"),
                     "drive": (False, "policy-lane")},
            "closed": dict.fromkeys(policy.LANES, (False, "policy-lane")), "locked": dict.fromkeys(policy.LANES, (False, "policy-locked"))}
        asked = {"whisper": {"asr_remote": False, "asr_cloud": False}, "remote": {"asr_remote": True, "asr_cloud": False},
                 "azure": {"asr_remote": False, "asr_cloud": True}, "auto": {"asr_remote": True, "asr_cloud": False}}
        cells = 0
        for pk, raw, calendar, engine in itertools.product(POLICIES, FLAGS, ("auto", "0"), ENGINES):
            pol = self.policies[pk]
            lo = policy.effective_local_only(raw, pol, SimpleNamespace(local_only_default=False))
            got = policy.lane_decisions(lo, pol, self.cfg(asr_engine=engine, calendar_lookup=calendar))
            flag, _ = oracle_flag(pk, raw, False)
            for lane in policy.LANES:
                if pk == "locked":
                    want = (False, "policy-locked")
                elif flag:
                    want = (False, "local_only")
                elif not policy_lanes[pk][lane][0]:
                    want = (False, policy_lanes[pk][lane][1])
                elif lane == "calendar" and calendar == "0":
                    want = (False, "user-disabled")
                elif lane in asked[engine] and not asked[engine][lane]:
                    want = (False, "user-disabled")
                else:
                    want = (True, "ok")
                self.assertEqual((got[lane].allowed, got[lane].reason), want, f"{pk} / {flag_name(raw)} / cal={calendar} / {engine} / {lane}")
                cells += 1
        self.assertEqual(cells, 6 * 6 * 2 * 4 * 5)

    def test_drive_lane_matrix(self):
        archive = self.base_cfg.archive_dir
        approved = tp.company(lanes={"drive": "allow"}, approvals={"drive": "T-1"}, archive={"allowed_roots": [str(archive.parent)]})
        path = self.root / "drive-policy.json"
        path.write_text(json.dumps(approved), encoding="utf-8")
        drive_policy = policy.load_org_policy(path, required_marker=self.root / "none", stat_fn=tp.make_stat_fn(path), current_version="0.2.0",
                                              sleep=lambda s: None)
        unapproved = dataclasses.replace(drive_policy, lanes=dict(drive_policy.lanes, drive="deny"), lane_reasons={"drive": "policy-unapproved"})
        free = policy.LocalOnly(False, "session")
        cases = [  # (policy, archive dir, ARCHIVE_DIR explicit?) -> (allowed, reason)
            (drive_policy, archive, True, (True, "ok")), (drive_policy, archive / "2026-10", True, (True, "ok")),
            (drive_policy, self.root / "Elsewhere", True, (False, "policy-archive-root")), (drive_policy, archive, False, (False, "archive-not-configured")),
            (drive_policy, self.root / "Elsewhere", False, (False, "archive-not-configured")), (unapproved, archive, True, (False, "policy-unapproved")),
            (self.policies["personal"], self.root / "Elsewhere", False, (True, "ok")), (self.policies["none"], self.root / "Elsewhere", False, (True, "ok")),
            (self.policies["closed"], archive, True, (False, "policy-lane")),
        ]
        for pol, directory, explicit, want in cases:
            cfg = self.cfg(archive_dir=directory, explicit_keys=frozenset({"ARCHIVE_DIR"}) if explicit else frozenset())
            got = policy.lane_decisions(free, pol, cfg)["drive"]
            self.assertEqual((got.allowed, got.reason), want, f"{directory} explicit={explicit}")
        shut = policy.lane_decisions(policy.LocalOnly(True, "session"), drive_policy, self.base_cfg)["drive"]
        self.assertEqual((shut.allowed, shut.reason), (False, "local_only"))


# ---------------------------------------------------------------------------------------------------- 20 hand-written rows
HAND_ROWS = [
    # id, policy, raw flag, ASR_ENGINE, ASR_FALLBACK, consent, hardware  ->  primary, fallback, egress, blocked, reason
    ("01 default install",                    "none", None, "whisper", "none", "none", True, "whisper", None, False, None, "ok"),
    ("02 owner with a relay consent",         "none", None, "remote", "none", "valid", True, "remote", None, True, None, "ok"),
    ("03 relay then local fallback",          "personal", False, "remote", "whisper", "valid", True, "remote", "whisper", True, None, "ok"),
    ("04 local-only beats a valid consent",   "none", True, "remote", "whisper", "valid", True, "whisper", None, False, None, "local_only"),
    ("05 bad-type flag is local-only",        "none", "false", "remote", "none", "valid", True, "whisper", None, False, None, "local_only"),
    ("06 flag 0 (int) is local-only",         "personal", 0, "azure", "none", "valid", True, "whisper", None, False, None, "local_only"),
    ("07 unreadable session",                 "personal", UNREADABLE, "remote", "none", "valid", True, "whisper", None, False, None, "local_only"),
    ("08 locked policy",                      "locked", False, "remote", "azure", "valid", True, "whisper", None, False, None, "policy-locked"),
    ("09 flag-pinned policy overrides false", "pinned", False, "remote", "none", "valid", True, "whisper", None, False, None, "local_only"),
    ("10 company baseline opens nothing",     "closed", False, "remote", "azure", "valid", True, "whisper", None, False, None, "policy-lane"),
    ("11 company baseline default is true",   "closed", None, "remote", "none", "valid", True, "whisper", None, False, None, "local_only"),
    ("12 org consent covers the relay",       "open", False, "remote", "none", "none", True, "remote", None, True, None, "ok"),
    ("13 org consent beats a tampered file",  "open", False, "remote", "none", "tampered", True, "remote", None, True, None, "ok"),
    ("14 cloud needs the user's consent",     "open", False, "azure", "none", "none", True, "whisper", None, False, None, "no-consent"),
    ("15 expired cloud consent",              "open", False, "azure", "whisper", "expired", True, "whisper", None, False, None, "consent-expired"),
    ("16 auto on a capable Mac stays local",  "personal", False, "auto", "none", "valid", True, "whisper", None, False, None, "hw-capable"),
    ("17 auto on a weak Mac goes to the relay", "open", False, "auto", "none", "none", False, "remote", None, True, None, "hw-incapable"),
    ("18 weak Mac, nothing allowed",          "closed", False, "auto", "none", "valid", False, "whisper", None, False, "asr_policy_blocked", "policy-lane"),
    ("19 explicit whisper on a weak Mac",     "none", True, "whisper", "none", "none", False, "whisper", None, False, None, "local_only"),
    ("20 tampered consent, unknown Mac",      "personal", False, "remote", "azure", "tampered", None, "whisper", None, False, None, "consent-tampered"),
]


class HandWrittenRows(MatrixBase):
    def test_every_row(self):
        self.assertEqual(len(HAND_ROWS), 20)
        for name, pk, raw, engine, fallback, consent, hw, primary, second, egress, blocked, reason in HAND_ROWS:
            with self.subTest(row=name):
                pol = self.policies[pk]
                lo = policy.effective_local_only(raw, pol, SimpleNamespace(local_only_default=False))
                got = policy.decide_asr(self.cfg(asr_engine=engine, asr_fallback=fallback), pol, lo, self.consents[consent],
                                        SimpleNamespace(capable=hw), now=NOW)
                self.assertEqual((got.primary, got.fallback, got.allow_egress, got.blocked, got.reason), (primary, second, egress, blocked, reason))
                self.assertEqual(oracle_asr(pk, lo.value, engine, fallback, consent, hw),
                                 {"primary": primary, "fallback": second, "allow_egress": egress, "blocked": blocked, "reason": reason})


if __name__ == "__main__":
    unittest.main()
