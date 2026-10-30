"""mcap doctor is LANE-AWARE (cli.py).

Without an organisation policy (and without an external ASR engine in the config) the output is what it was before SPEC 18: the names and levels
of the lines are pinned here and the existing test_cli.DoctorTests / DoctorApiTests (unmodified) keep proving the content. With a policy a lane
the organisation denies is ``skipped: lane denied`` (never a FAIL, and no ``claude`` process, no Keychain read, no calendar login check is
made for it), the local archive is checked instead of the Drive folder, and the policy / route / consent / credential / capability / cap lines
and the FAIL rules of a company Mac with a locked local-only flag (no local engine, no FileVault) are added. ``--share`` removes the home folder
and e-mail addresses. Claude is the FAKE executable, the Keychain the fake `security`, no socket opens."""
import contextlib
import hashlib
import io
import os
import subprocess
import sys
from datetime import timedelta
from pathlib import Path
from unittest import mock

from asr_support import MACHINE, NOW, consent_entry
from net_guard_support import NoNetworkCase
from notes_cli_support import FakeClaude, make_cfg
from test_status import company_doc, company_org, locked_org, probe, write_usage

from mcap import asr_creds, cli, note, policy, status, usage


class DoctorCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.home = self.root / "home"
        self.home.mkdir()
        env = {"MCAP_CONFIG": str(self.root / "config.env"), "MCAP_LOG_DIR": str(self.root / "logs"), "HF_HUB_OFFLINE": "1"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("MCAP_SILERO_MODEL", None)
        for target, value in (("mcap.cli._hf_cache_roots", [self.root / "hf-empty" / "hub"]), ):
            hf = mock.patch(target, return_value=value)
            hf.start()
            self.addCleanup(hf.stop)
        self.cfg = make_cfg(self.root, self.fake, note_timeout_seconds=60)
        self.cfg.python_bin = Path(sys.executable)
        for name in ("note_prompt.md", "vocabulary.txt"):
            (self.cfg.support_dir / name).write_text((self.cfg.project_dir / "config" / name).read_text(encoding="utf-8"), encoding="utf-8")
        self.write_config()
        self.hw = probe(capable=True)
        self.vault = "on"
        self.excluded = True
        for target, value in (("hardware_probe", lambda cfg, **kw: self.hw), ("filevault_state", lambda run=None: self.vault),
                              ("backup_excluded", lambda path, run=None: self.excluded), ("load_policy", lambda cfg: self.org)):
            patcher = mock.patch.object(status, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        clock = mock.patch.object(usage, "clock", lambda: NOW)
        clock.start()
        self.addCleanup(clock.stop)
        self.org = policy.absent_policy()
        self.pin_ok = True                                          # what the (fake) codesign says about the claude binary
        self.pin_calls: list[list] = []

    def pin_run(self, argv, **kw):
        """The codesign runner of the signature pin: this suite never starts /usr/bin/codesign."""
        self.pin_calls.append(list(argv))
        return subprocess.CompletedProcess(argv, 0 if self.pin_ok else 3, stdout="", stderr="")

    def write_config(self, **extra):
        values = {"SUPPORT_DIR": self.cfg.support_dir, "ARCHIVE_DIR": self.cfg.archive_dir, "PROJECT_DIR": self.cfg.project_dir,
                  "PYTHON_BIN": sys.executable, "CLAUDE_BIN": self.cfg.claude_bin, "CALENDAR_LOOKUP": "0", "NOTE_TIMEOUT_SECONDS": "60"}
        values.update(extra)
        (self.root / "config.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def doctor(self, org=None, warmup=False, **cfg_changes):
        if org is not None:
            self.org = org
        for key, value in cfg_changes.items():
            setattr(self.cfg, key, value)
        lines: list[str] = []
        code = cli.run_doctor(self.cfg, warmup=warmup, out=lines.append, claude_pin_run=self.pin_run)
        return code, lines

    @staticmethod
    def line(lines, name):
        found = [l for l in lines if l.startswith(("[PASS] ", "[WARN] ", "[FAIL] ")) and l.split("] ", 1)[1].startswith(f"{name}:")]
        assert found, f"no line named {name!r} in:\n" + "\n".join(lines)
        return found[0]

    @staticmethod
    def has(lines, name):
        return any(l.split("] ", 1)[1].startswith(f"{name}:") for l in lines if l.startswith(("[PASS] ", "[WARN] ", "[FAIL] ")))

    @staticmethod
    def levels(lines):
        """(level, name) of every line; the 'environment' warning depends on the shell the suite runs in and is left out."""
        pairs = [(l[1:5], l.split("] ", 1)[1].split(":", 1)[0]) for l in lines if l.startswith(("[PASS] ", "[WARN] ", "[FAIL] "))]
        return [pair for pair in pairs if pair[1] != "environment"]


def explicit_archive_org(root, home: Path, **sections):
    """A company policy that allows the Drive lane for ``home``'s shared drive; returns (org, the matching ARCHIVE_DIR)."""
    mount = home / "Library" / "CloudStorage" / "GoogleDrive-x@example.com" / "Shared drives" / "Meetings"
    mount.mkdir(parents=True, exist_ok=True)
    return company_org(root, company_doc(**sections)), mount


# ======================================================================================================================
class UnchangedWithoutPolicyTests(DoctorCase):
    EXPECTED = [("PASS", "config"), ("PASS", "support dir"), ("PASS", "vocabulary"), ("PASS", "note prompt"), ("PASS", "cleanup prompt"),
                ("PASS", "verify prompt"), ("PASS", "transcript cleanup"), ("PASS", "note verify"), ("PASS", "python"), ("PASS", "numpy"),
                ("WARN", "mlx warm-up"), ("WARN", "asr model"), ("WARN", "silero vad"), ("PASS", "claude cli"), ("PASS", "claude login"),
                ("PASS", "billing mode"), ("PASS", "overage guard"), ("PASS", "calendar"), ("PASS", "claude call cap"), ("PASS", "claude usage"),
                ("PASS", "claude cost"), ("PASS", "archive dir"), ("PASS", "afconvert")]

    def test_the_lines_and_levels_of_a_mac_without_a_policy_are_the_ones_it_always_had(self):
        code, lines = self.doctor()
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertEqual(self.levels(lines), self.EXPECTED)
        self.assertRegex(lines[-1], r"^doctor: \d+ PASS, \d+ WARN, 0 FAIL$")

    def test_no_policy_work_is_done_for_the_personal_default(self):
        with mock.patch.object(status, "hardware_probe", side_effect=AssertionError("probed")), \
                mock.patch.object(status, "filevault_state", side_effect=AssertionError("fdesetup")), \
                mock.patch.object(asr_creds, "secret_status", side_effect=AssertionError("keychain")):
            code, lines = self.doctor()
        self.assertEqual(code, 0)
        for name in ("organisation policy", "local-only default", "lanes", "asr route", "asr capability", "local archive", "filevault"):
            self.assertFalse(self.has(lines, name), name)

    def test_the_claude_checks_still_run_for_the_personal_default(self):
        code, lines = self.doctor()
        self.assertGreater(len(self.fake.calls()), 0)                                         # the fake claude was asked (auth status): as before
        self.assertIn("claude.ai", self.line(lines, "claude login"))

    def test_an_unrecognised_switch_of_the_new_keys_is_a_warning_in_every_mode(self):
        self.cfg.config_warnings = ("LOCAL_ONLY_DEFAULT: unrecognised value 'maybe' is read as True",)
        code, lines = self.doctor()
        self.assertEqual(code, 0)
        self.assertEqual(self.line(lines, "config").split("] ", 1)[0], "[PASS")                # the first config line is the file
        self.assertTrue(any(l.startswith("[WARN] config: LOCAL_ONLY_DEFAULT") for l in lines))


# ======================================================================================================================
class DeniedLaneTests(DoctorCase):
    def test_a_company_policy_that_denies_the_note_lanes_skips_every_claude_check_and_fails_nothing(self):
        with mock.patch.object(note, "check_ready", side_effect=AssertionError("claude readiness")), \
                mock.patch.object(note, "preflight", side_effect=AssertionError("claude auth status")):
            code, lines = self.doctor(org=company_org(self.root))
        text = "\n".join(lines)
        self.assertEqual(code, 0, text)
        self.assertEqual(self.fake.calls(), [])                                               # not one claude process, not even `--version`
        self.assertEqual(self.security.calls(), [])                                           # not one Keychain read
        for name in ("claude cli", "calendar", "claude usage", "transcript cleanup", "note verify"):
            self.assertIn("skipped: lane denied", self.line(lines, name), name)
        self.assertIn("llm: policy-lane", self.line(lines, "claude cli"))
        self.assertIn("calendar: policy-lane", self.line(lines, "calendar"))
        self.assertNotIn("[FAIL]", text)
        self.assertFalse(self.has(lines, "claude login"))

    def test_a_missing_approval_is_reported_as_the_reason(self):
        org = company_org(self.root, company_doc(lanes={"llm": "allow"}))                      # allow without an approval reference: deny
        code, lines = self.doctor(org=org)
        self.assertIn("llm: policy-unapproved", self.line(lines, "claude cli"))

    def test_when_the_llm_lane_is_open_the_claude_checks_run_as_before_and_a_denied_calendar_is_still_skipped(self):
        org = company_org(self.root, company_doc(lanes={"llm": "allow", "calendar": "deny"}, approvals={"drive": "TICKET-1", "llm": "LEGAL-9"}))
        self.security.store()                                                                    # a (fake) API key: api mode would look at the calendar login
        with mock.patch.object(note, "preflight", side_effect=AssertionError("calendar login check")):
            code, lines = self.doctor(org=org, claude_auth="api", calendar_lookup="auto")
        self.assertIn("(2.1.278", self.line(lines, "claude cli"))
        self.assertIn("calendar: policy-lane", self.line(lines, "calendar"))
        self.assertTrue(self.has(lines, "api key"))                                              # the api-mode checks ran
        self.assertFalse(self.has(lines, "calendar login"))
        code, lines = self.doctor(org=policy.absent_policy())                                    # no policy: the calendar login IS looked at
        self.assertTrue(self.has(lines, "calendar login") or self.has(lines, "api key"))

    def test_the_drive_folder_is_not_checked_when_the_lane_is_denied_and_the_local_archive_is(self):
        code, lines = self.doctor(org=company_org(self.root, company_doc(lanes={"drive": "deny"})))
        self.assertIn("skipped: lane denied (drive: policy-lane)", self.line(lines, "archive dir"))
        self.assertIn("kept in the local archive", self.line(lines, "archive dir"))
        local = self.line(lines, "local archive")
        self.assertTrue(local.startswith("[PASS]"), local)
        self.assertIn("does not exist yet", local)

    def test_a_company_mac_without_an_explicit_archive_dir_warns_and_skips_the_drive_folder(self):
        code, lines = self.doctor(org=company_org(self.root))                                  # explicit_keys is empty: ARCHIVE_DIR is the built-in
        warns = [l for l in lines if l.startswith("[WARN] archive dir:")]
        self.assertEqual(len(warns), 1)
        self.assertIn("ARCHIVE_DIR is not set in config.env", warns[0])
        self.assertTrue(any(l.startswith("[PASS] archive dir: skipped: lane denied (drive: archive-not-configured)") for l in lines))
        self.assertTrue(any(l.startswith("[WARN] config: SELF_NAME is not set") for l in lines))

    def test_an_archive_dir_outside_the_allowed_team_drives_warns_and_keeps_the_meetings_local(self):
        self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR"})
        code, lines = self.doctor(org=company_org(self.root))
        self.assertTrue(any(l.startswith("[WARN] archive dir: ARCHIVE_DIR is outside the team drives") for l in lines))
        self.assertTrue(any("(drive: policy-archive-root)" in l for l in lines))
        self.assertEqual(code, 0)

    def test_an_allowed_team_drive_is_checked_like_always(self):
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}):
            org, mount = explicit_archive_org(self.root, self.home, approvals={"drive": "TICKET-1"})
            self.cfg.explicit_keys = frozenset({"ARCHIVE_DIR", "SELF_NAME"})
            code, lines = self.doctor(org=org, archive_dir=mount)
        self.assertEqual(self.line(lines, "archive dir"), f"[PASS] archive dir: {mount} (writable)")
        self.assertEqual(code, 0)

    def test_a_locked_policy_is_a_fail_and_every_lane_is_skipped(self):
        code, lines = self.doctor(org=locked_org(self.root))
        self.assertEqual(code, 1)
        fail = self.line(lines, "organisation policy")
        self.assertTrue(fail.startswith("[FAIL]"))
        self.assertIn("LOCKED (bad-json)", fail)
        self.assertEqual(self.fake.calls(), [])
        for name in ("claude cli", "calendar", "archive dir"):
            self.assertIn("skipped: lane denied", self.line(lines, name))
            self.assertIn("policy-locked", self.line(lines, name))

    def test_the_policy_lines_show_profile_revision_hash_default_and_lanes(self):
        self.cfg.asr_engine = "remote"
        code, lines = self.doctor(org=company_org(self.root))
        line = self.line(lines, "organisation policy")
        self.assertRegex(line, r"^\[PASS\] organisation policy: profile company, revision 12, sha256 [0-9a-f]{8} \(contact: IT 헬프데스크 #it-help\)$")
        self.assertEqual(self.line(lines, "local-only default"), "[PASS] local-only default: new meetings start local-only: no (default)")
        lanes = self.line(lines, "lanes")
        for part in ("asr_remote allow", "asr_cloud deny (policy-lane)", "llm deny (policy-lane)", "calendar deny (policy-lane)"):
            self.assertIn(part, lanes)
        locked = company_org(self.root, company_doc(local_only={"default": True, "locked": True}))
        self.assertIn("yes (policy-lock); the policy locks it", self.line(self.doctor(org=locked)[1], "local-only default"))


# ======================================================================================================================
class ClaudeSpawns:
    """``subprocess.run`` that records every start of the FAKE claude (argv and env) and then really runs it. ``--version`` is not in the fake's
    own call log, so this is how the suite sees it."""

    def __init__(self, fake):
        self.fake, self.real, self.calls = fake, subprocess.run, []

    def __call__(self, argv, *args, **kwargs):
        if argv and str(argv[0]) == str(self.fake.path):
            self.calls.append({"argv": [str(a) for a in argv[1:]], "env": dict(kwargs.get("env") or {})})
        return self.real(argv, *args, **kwargs)

    def argvs(self):
        return [c["argv"] for c in self.calls]


class ClaudePinTests(DoctorCase):
    """Under a company policy with an OPEN llm lane the doctor starts no ``claude`` (not ``--version``, not ``auth status``) before the binary
    matches the policy's signature pin; a mismatch is a FAIL, not a PASS. Matching pins: sha256 of the file (no
    process) or a team id through the injected codesign runner."""

    def llm_org(self, pin, **llm):
        return company_org(self.root, company_doc(lanes={"llm": "allow"}, approvals={"drive": "TICKET-1234", "llm": "LEGAL-9"},
                                                  llm={"claude_bin_pin": pin, **llm}))

    def own_sha256(self):
        return hashlib.sha256(Path(self.fake.path).resolve().read_bytes()).hexdigest()

    def doctor_spied(self, **kw):
        spy = ClaudeSpawns(self.fake)
        with mock.patch.object(subprocess, "run", spy):
            code, lines = self.doctor(**kw)
        return code, lines, spy

    def test_a_claude_that_does_not_match_the_pin_is_started_never_and_is_a_fail(self):
        org = self.llm_org({"sha256": "0" * 64})
        with mock.patch.object(note, "check_ready", side_effect=AssertionError("claude readiness")), \
                mock.patch.object(note, "preflight", side_effect=AssertionError("claude auth status")):
            code, lines, spy = self.doctor_spied(org=org)
        text = "\n".join(lines)
        self.assertEqual(code, 1, text)
        self.assertEqual(spy.calls, [])                                                       # not `--version`, not `auth status`
        self.assertEqual(self.fake.calls(), [])
        self.assertEqual(self.pin_calls, [])                                                  # a sha256 pin needs no codesign
        line = self.line(lines, "claude cli")
        self.assertTrue(line.startswith("[FAIL] claude cli: policy-claude-unpinned:"), line)
        self.assertIn("sha256 differs", line)
        self.assertIn("no claude process was started", line)
        self.assertFalse(self.has(lines, "claude login"))
        self.assertEqual(self.security.calls(), [])
        self.assertTrue(self.has(lines, "claude usage"))                                      # the local usage numbers are still reported

    def test_a_claude_that_matches_a_sha256_pin_is_checked_like_always(self):
        code, lines, spy = self.doctor_spied(org=self.llm_org({"sha256": self.own_sha256()}))
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn(["--version"], spy.argvs())
        self.assertIn(["auth", "status"], spy.argvs())
        self.assertTrue(self.line(lines, "claude cli").startswith("[PASS] claude cli:"))
        self.assertIn("claude.ai", self.line(lines, "claude login"))

    def test_a_team_id_pin_is_verified_once_with_codesign_before_any_claude_start(self):
        org = self.llm_org({"team_id": "ABCDE12345"})
        self.pin_ok = False
        code, lines, spy = self.doctor_spied(org=org)
        self.assertEqual(code, 1)
        self.assertEqual(spy.calls, [])
        self.assertEqual(len(self.pin_calls), 1)
        argv = self.pin_calls[0]
        self.assertEqual(argv[:2], ["/usr/bin/codesign", "--verify"])
        self.assertIn('-R=anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"', argv)
        self.assertIn("signature does not match", self.line(lines, "claude cli"))
        self.pin_ok, self.pin_calls = True, []
        code, lines, spy = self.doctor_spied()
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertEqual(len(self.pin_calls), 1)                                              # one check for the whole doctor, not one per call
        self.assertIn(["--version"], spy.argvs())
        self.assertTrue(self.line(lines, "claude cli").startswith("[PASS]"))

    def test_the_calendar_login_check_of_api_mode_is_not_made_for_a_claude_that_fails_the_pin(self):
        self.security.store()                                                                 # a (fake) API key
        org = self.llm_org({"sha256": "f" * 64})
        with mock.patch.object(note, "preflight", side_effect=AssertionError("calendar login check")):
            code, lines, spy = self.doctor_spied(org=org, claude_auth="api", calendar_lookup="auto")
        self.assertEqual(code, 1)
        self.assertEqual(spy.calls, [])
        self.assertEqual(self.security.calls(), [])
        self.assertFalse(self.has(lines, "calendar login"))
        self.assertFalse(self.has(lines, "api key"))

    def test_a_missing_claude_binary_under_a_pin_is_a_fail_without_a_start(self):
        code, lines, spy = self.doctor_spied(org=self.llm_org({"sha256": "a" * 64}), claude_bin=self.root / "nowhere" / "claude")
        self.assertEqual(code, 1)
        self.assertEqual(spy.calls, [])
        self.assertIn("not found", self.line(lines, "claude cli"))

    def test_the_pin_is_not_looked_at_without_a_company_policy_or_for_a_closed_lane(self):
        real, explicit = note.verify_claude_bin, []

        def recorder(cfg, org=None, **kw):
            explicit.append(org)                                                               # the doctor passes its policy explicitly
            return real(cfg, org, **kw)
        with mock.patch.object(note, "verify_claude_bin", recorder):
            code, lines, spy = self.doctor_spied(org=policy.absent_policy())                  # a personal Mac: as it always was
            self.assertEqual(code, 0, "\n".join(lines))
            self.assertIn(["--version"], spy.argvs())
            personal = company_doc(profile="personal", lanes={"llm": "allow"})                # the pin is for the company profile only
            personal.pop("runtime"), personal.pop("approvals")
            code, lines, spy = self.doctor_spied(org=company_org(self.root, personal))
            self.assertIn(["--version"], spy.argvs())
            self.assertTrue(self.line(lines, "claude cli").startswith("[PASS]"))
            code, lines, spy = self.doctor_spied(org=company_org(self.root))                  # llm denied by the policy: skipped, no check
            self.assertEqual(spy.calls, [])
            self.assertIn("skipped: lane denied", self.line(lines, "claude cli"))
        self.assertEqual([org for org in explicit if org is not None and org.profile == "company"], [])      # never asked for these
        self.assertEqual(self.pin_calls, [])

    def test_the_version_call_carries_the_policys_child_env_and_a_personal_mac_gets_the_plain_allow_list(self):
        extra = {"DISABLE_TELEMETRY": "1", "DISABLE_AUTOUPDATER": "1"}
        code, lines, spy = self.doctor_spied(org=self.llm_org({"sha256": self.own_sha256()}, child_env=extra))
        version = next(c for c in spy.calls if c["argv"] == ["--version"])
        for name, value in extra.items():
            self.assertEqual(version["env"].get(name), value)
        self.assertEqual(sorted(version["env"]), sorted({**note.clean_env(), **extra}))
        code, lines, spy = self.doctor_spied(org=policy.absent_policy())
        plain = next(c for c in spy.calls if c["argv"] == ["--version"])
        self.assertEqual(plain["env"], note.clean_env())


# ======================================================================================================================
class CompanyRuleTests(DoctorCase):
    def locked_company(self):
        return company_org(self.root, company_doc(local_only={"default": True, "locked": True}))

    def test_locked_local_only_without_a_capable_local_engine_is_a_fail(self):
        self.hw = probe(capable=False, reasons=("ram-low",))
        code, lines = self.doctor(org=self.locked_company())
        self.assertEqual(code, 1)
        fail = self.line(lines, "local transcription")
        self.assertTrue(fail.startswith("[FAIL]"))
        self.assertIn("ram-low", fail)
        self.assertIn("asr_policy_blocked", fail)
        self.assertTrue(self.line(lines, "asr capability").startswith("[WARN]"))

    def test_a_capable_mac_in_a_locked_group_passes(self):
        code, lines = self.doctor(org=self.locked_company())
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertFalse(self.has(lines, "local transcription"))
        self.assertEqual(self.line(lines, "filevault"), "[PASS] filevault: on")

    def test_filevault_off_is_a_fail_for_a_locked_group_and_a_warning_otherwise(self):
        self.vault = "off"
        code, lines = self.doctor(org=self.locked_company())
        self.assertTrue(self.line(lines, "filevault").startswith("[FAIL]"))
        self.assertEqual(code, 1)
        self.assertIn("required for a device group with locked local-only", self.line(lines, "filevault"))
        code, lines = self.doctor(org=company_org(self.root))
        self.assertTrue(self.line(lines, "filevault").startswith("[WARN]"))
        self.assertEqual(code, 0)

    def test_filevault_unknown_is_a_warning(self):
        self.vault = "unknown"
        code, lines = self.doctor(org=self.locked_company())
        self.assertTrue(self.line(lines, "filevault").startswith("[WARN]"))
        self.assertEqual(code, 0)

    def test_the_rules_are_for_the_company_profile_only(self):
        personal = company_doc(profile="personal")
        personal.pop("runtime"), personal.pop("approvals")
        self.hw, self.vault = probe(capable=False), "off"
        code, lines = self.doctor(org=company_org(self.root, personal))
        self.assertFalse(self.has(lines, "filevault"))
        self.assertFalse(self.has(lines, "local transcription"))

    def test_the_local_archive_is_checked_against_the_allow_list_and_the_backup_exclusion(self):
        folder = Path(self.cfg.local_archive_root)
        folder.mkdir(parents=True)
        code, lines = self.doctor(org=company_org(self.root))
        self.assertEqual(self.line(lines, "local archive"), f"[PASS] local archive: {folder} (writable, excluded from Time Machine)")
        self.excluded = False
        self.assertTrue(self.line(self.doctor()[1], "local archive").startswith("[WARN]"))
        self.assertIn("NOT excluded from Time Machine", self.line(self.doctor()[1], "local archive"))
        self.excluded = None
        self.assertIn("could not be read", self.line(self.doctor()[1], "local archive"))
        outside = self.root / "elsewhere"
        outside.mkdir()
        code, lines = self.doctor(local_archive_dir=outside)
        fail = self.line(lines, "local archive")
        self.assertTrue(fail.startswith("[FAIL]"), fail)
        self.assertIn("outside-allowed-roots", fail)
        self.assertEqual(code, 1)

    def test_the_log_content_mode_is_reported(self):
        code, lines = self.doctor(org=company_org(self.root), log_content=False)
        self.assertIn("LOG_CONTENT=off", self.line(lines, "log content"))
        self.assertIn("LOG_CONTENT=on", self.line(self.doctor(log_content=True)[1], "log content"))


# ======================================================================================================================
class AsrRouteLineTests(DoctorCase):
    def setUp(self):
        super().setUp()
        self.cfg.asr_engine = "remote"
        self.cfg.asr_remote_url = "https://asr.example.internal"
        self.cfg.asr_remote_ca_file = self.root / "relay-ca.pem"
        self.consents = policy.ConsentSet(machine=MACHINE)
        patcher = mock.patch.object(status, "load_consent_set", lambda cfg, now=None, **kw: self.consents)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.security_item()

    def security_item(self, token=True):
        self.security.remove()
        if token:
            self.security.store_item("mcap1_0a1b2c3d_" + "Zq9xK" * 6 + "ab", asr_creds.service_name("remote"), asr_creds.account_name("asr.example.internal", 443))

    def test_the_org_consent_credential_destination_and_capability_lines(self):
        code, lines = self.doctor(org=company_org(self.root))
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertRegex(self.line(lines, "asr route"), r"^\[PASS\] asr route: primary remote, fallback none \(reason ok\)$")
        consent = self.line(lines, "asr consent remote")
        self.assertTrue(consent.startswith("[PASS]"), consent)
        self.assertRegex(consent, r"org consent org:remote-[0-9a-f]{8} for both use, valid until 2027-10-14$")
        self.assertEqual(self.line(lines, "asr destination remote"), "[PASS] asr destination remote: company-asr: on the allow list")
        self.assertEqual(self.line(lines, "asr credential remote"), "[PASS] asr credential remote: stored in the Keychain (the value is not read)")
        self.assertIn("arm64, 32.0 GB RAM, mlx yes, model on disk yes, rtf 0.1; local engine capable: yes", self.line(lines, "asr capability"))
        self.assertEqual(self.security.reads(), 0)                                             # the credential's presence is asked, its value never read
        self.assertNotIn("asr.example.internal", "\n".join(lines))                             # a label, not the host name

    def test_a_missing_credential_is_a_warning_with_the_command_that_fixes_it(self):
        self.security_item(token=False)
        code, lines = self.doctor(org=company_org(self.root))
        line = self.line(lines, "asr credential remote")
        self.assertTrue(line.startswith("[WARN]"))
        self.assertIn("mcap asr-engines enroll remote", line)
        self.assertEqual(code, 0)

    def test_no_consent_excludes_the_engine_and_says_how_to_get_one(self):
        org = company_org(self.root, company_doc(asr={"org_consents": []}))
        code, lines = self.doctor(org=org)
        consent = self.line(lines, "asr consent remote")
        self.assertTrue(consent.startswith("[WARN]"))
        self.assertIn("no-consent", consent)
        self.assertIn("mcap asr-engines consent remote", consent)
        route = self.line(lines, "asr route")
        self.assertTrue(route.startswith("[WARN]"))
        self.assertIn("remote: excluded (no-consent)", route)
        self.assertFalse(self.has(lines, "asr credential remote"))

    def test_a_consent_that_ends_soon_is_a_warning_and_an_expired_one_excludes_the_engine(self):
        soon = (NOW.date() + timedelta(days=5)).isoformat()
        org = company_org(self.root, company_doc(asr={"org_consents": [dict(company_doc()["asr"]["org_consents"][0], expires=soon)]}))
        code, lines = self.doctor(org=org)
        line = self.line(lines, "asr consent remote")
        self.assertTrue(line.startswith("[WARN]"), line)
        self.assertIn("5 day(s) left: renew it", line)
        gone = (NOW.date() - timedelta(days=1)).isoformat()
        org = company_org(self.root, company_doc(asr={"org_consents": [dict(company_doc()["asr"]["org_consents"][0], expires=gone)]}))
        code, lines = self.doctor(org=org)
        self.assertIn("consent-expired", self.line(lines, "asr consent remote"))
        self.assertIn("remote: excluded (consent-expired)", self.line(lines, "asr route"))

    def test_a_host_the_policy_does_not_list_is_excluded_and_called_so(self):
        org = company_org(self.root, company_doc(asr={"allowed_hosts": ["other.example.com"]}))
        code, lines = self.doctor(org=org)
        self.assertTrue(self.line(lines, "asr destination remote").startswith("[WARN]"))
        self.assertIn("NOT on the policy's allow list", self.line(lines, "asr destination remote"))
        self.assertIn("remote: excluded (policy-host)", self.line(lines, "asr route"))

    def test_a_user_consent_is_shown_with_its_expiry(self):
        self.consents = policy.ConsentSet(entries=(consent_entry("remote"),), machine=MACHINE)
        code, lines = self.doctor(org=company_org(self.root, company_doc(asr={"org_consents": []})))
        self.assertRegex(self.line(lines, "asr consent remote"), r"^\[PASS\] asr consent remote: user consent c-remote for both use, valid until 2027-10-14$")

    def test_a_damaged_consent_file_is_a_fail_and_a_dropped_entry_a_warning(self):
        self.consents = policy.ConsentSet(problem="bad-json", machine=MACHINE)
        code, lines = self.doctor(org=company_org(self.root, company_doc(asr={"org_consents": []})))
        self.assertTrue(self.line(lines, "asr consent").startswith("[FAIL]"))
        self.assertEqual(code, 1)
        self.consents = policy.ConsentSet(problem="bad-entries:1", machine=MACHINE)
        code, lines = self.doctor()
        self.assertTrue(self.line(lines, "asr consent").startswith("[WARN]"))

    def test_the_daily_cap_line_counts_the_minutes_used_today(self):
        write_usage(self.cfg, minutes=200, when=NOW - timedelta(minutes=5))
        code, lines = self.doctor(org=company_org(self.root))
        cap = self.line(lines, "asr daily cap")
        self.assertTrue(cap.startswith("[PASS]"))
        self.assertIn("200.0 of 240 minutes", cap)
        write_usage(self.cfg, minutes=30, when=NOW - timedelta(minutes=2))
        self.assertTrue(self.line(self.doctor()[1], "asr daily cap").startswith("[WARN]"))                 # 230 of 240: above 90 percent

    def test_an_external_engine_without_a_policy_gets_the_route_lines_but_not_the_policy_lines(self):
        self.consents = policy.ConsentSet(entries=(consent_entry("remote"),), machine=MACHINE)
        code, lines = self.doctor(org=policy.absent_policy())
        self.assertTrue(self.has(lines, "asr route") and self.has(lines, "asr consent remote"))
        for name in ("organisation policy", "lanes", "local-only default", "filevault", "local archive"):
            self.assertFalse(self.has(lines, name), name)
        self.assertEqual(code, 0)

    def test_the_local_model_and_mlx_are_not_needed_for_a_server_only_mac(self):
        failing = subprocess.CompletedProcess([], 1, stdout="", stderr="ModuleNotFoundError: No module named 'mlx'")
        real = subprocess.run

        def run(argv, *a, **kw):
            return failing if any("import mlx.core" in str(x) for x in argv) else real(argv, *a, **kw)
        with mock.patch.object(cli.subprocess, "run", run):
            code, lines = self.doctor(warmup=True, org=company_org(self.root))
            self.assertIn("not needed (ASR_ENGINE=remote", self.line(lines, "mlx warm-up"))
            self.assertTrue(self.line(lines, "mlx warm-up").startswith("[PASS]"))
            self.assertIn("not needed (ASR_ENGINE=remote)", self.line(lines, "asr model"))
            self.cfg.asr_engine = "whisper"                                                     # the same failure on a local Mac is what it was: a FAIL
            code, lines = self.doctor(warmup=True, org=policy.absent_policy())
            self.assertTrue(self.line(lines, "mlx warm-up").startswith("[FAIL]"))
            self.cfg.asr_engine, self.cfg.asr_fallback = "remote", "whisper"                    # a Whisper fallback needs the engine again
            code, lines = self.doctor(warmup=True)
            self.assertTrue(self.line(lines, "mlx warm-up").startswith("[FAIL]"))


# ======================================================================================================================
class ShareTests(DoctorCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(argv))
        return code, out.getvalue()

    def test_share_replaces_the_home_folder_and_e_mail_addresses_in_every_line(self):
        drive = self.root / "Library" / "CloudStorage" / "GoogleDrive-user@example.com" / "My Drive" / "Meetings"
        self.write_config(ARCHIVE_DIR=drive, SELF_NAME="Me")
        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            code, plain = self.run_main("doctor", "--no-warmup")
            code, shared = self.run_main("doctor", "--no-warmup", "--share")
        self.assertIn(str(self.root), plain)
        self.assertIn("user@example.com", plain)
        self.assertNotIn(str(self.root), shared)
        self.assertNotIn("user@example.com", shared)
        self.assertNotIn("@", shared.replace("<email>", ""))
        self.assertIn("~/Library/CloudStorage/<email>/My Drive", shared)
        self.assertEqual(plain.count("\n"), shared.count("\n"))                               # the same lines, only less personal

    def test_share_also_covers_a_config_error(self):
        (self.root / "config.env").write_text(f"SUPPORT_DIR={self.root}/user@example.com\nAUDIO_RETENTION_DAYS=abc\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            code, out = self.run_main("doctor", "--no-warmup", "--share")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] config:", out)
        self.assertTrue(out.strip().endswith("doctor: 0 PASS, 0 WARN, 1 FAIL"))

    def test_share_filter_on_its_own(self):
        with mock.patch.dict(os.environ, {"HOME": "/Users/someone"}):
            self.assertEqual(cli.share_filter("/Users/someone/Library/x and a.b+c@example.co.kr"), "~/Library/x and <email>")
            self.assertEqual(cli.share_filter("no personal data here"), "no personal data here")


if __name__ == "__main__":
    import unittest
    unittest.main()
