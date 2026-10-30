"""mcap status / mcap sessions and the facts doctor shares with them (status.py).

Pinned here: the schema 1 document, the 20 KB bound, the CANARIES (no title, session id, folder name, path, host name or user name in the
document, whatever the sessions, logs and consents contain), usage fields only with STATUS_INCLUDE_USAGE for ``--write``, the policy / consent /
route / device / checks sections, the session counts and the sessions listing without titles. Nothing opens a socket, starts claude or reads the
Keychain (NoNetworkCase and the fake security), and no test reads the real LOG_DIR, SUPPORT_DIR or system policy."""
import contextlib
import dataclasses
import io
import json
import os
import stat
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

from asr_support import HOST, MACHINE, NOW, asr_cfg, consent_entry
from net_guard_support import NoNetworkCase
from notes_cli_support import load_test_policy, make_session

from mcap import cli, config, policy, status, usage
from mcap import asr_usage

FIXTURES = Path(__file__).resolve().parents[2] / "config" / "policy-fixtures"
DAY = 86400.0
CANARY_TITLE = "Confidential Merger Talks"
CANARY_PATIENT = "patient Kim Minsu has chest pain"


# ---------------------------------------------------------------------------------------------- helpers shared with the other W7a tests
def company_doc(**sections) -> dict:
    """The valid company policy of the shared corpus (config/policy-fixtures/valid_company.json) with sections replaced or (dicts) merged."""
    doc = json.loads((FIXTURES / "valid_company.json").read_text(encoding="utf-8"))
    for key, value in sections.items():
        doc[key] = {**doc[key], **value} if isinstance(value, dict) and isinstance(doc.get(key), dict) else value
    return doc


def company_org(root, doc=None, **stat_kw) -> "policy.OrgPolicy":
    """A VALID company policy as ``load_org_policy`` reads it (the file is written under ``root``; owner and mode are injected: a test is not root)."""
    return load_test_policy(Path(root) / "policy" / "policy.json", doc if doc is not None else company_doc(), **stat_kw)


def locked_org(root) -> "policy.OrgPolicy":
    return load_test_policy(Path(root) / "policy-bad" / "policy.json", "{")


def probe(capable=True, arch="arm64", mem=32.0, rtf=0.1, reasons=()) -> "policy.HardwareProbe":
    return policy.HardwareProbe(arch=arch, mem_gb=mem, mlx_ok=True, model_present=True, rtf=rtf, probed_at=None, capable=capable, reasons=tuple(reasons))


def write_usage(cfg, *, minutes: float, when: datetime, engine="remote") -> None:
    """One asr-usage line worth ``minutes`` of the daily cap (audio_s + 1 request), written with the real recorder."""
    seconds = minutes * 60.0 - asr_usage.REQUEST_SECONDS
    with mock.patch.object(usage, "clock", lambda: when):
        asr_usage.record(cfg, engine=engine, kind="server", host=HOST, op="chunk", status=200, audio_s=seconds, bytes_out=1000, bytes_in=100,
                         dur_ms=10, outcome="ok")


class StatusCase(NoNetworkCase):
    """A temp root with its own LOG_DIR (the real one is never read), a config whose paths are all under the root and no system policy."""

    def setUp(self):
        super().setUp()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        env = mock.patch.dict(os.environ, {"MCAP_LOG_DIR": str(self.logs), "MCAP_CONFIG": str(self.root / "config.env")})
        env.start()
        self.addCleanup(env.stop)
        self.cfg = asr_cfg(self.root)
        self.machine = mock.patch.object(policy, "machine_id", return_value=MACHINE)
        self.machine.start()
        self.addCleanup(self.machine.stop)

    def collect(self, **kw):
        kw.setdefault("now", NOW)
        kw.setdefault("hw", probe())
        kw.setdefault("filevault", "on")
        kw.setdefault("machine", MACHINE)
        return status.collect_status(self.cfg, **kw)

    def write_config(self, **extra):
        values = {"SUPPORT_DIR": self.cfg.support_dir, "ARCHIVE_DIR": self.cfg.archive_dir, "PROJECT_DIR": self.cfg.project_dir,
                  "PYTHON_BIN": sys.executable, "CLAUDE_BIN": self.cfg.claude_bin, "CALENDAR_LOOKUP": "0"}
        values.update(extra)
        (self.root / "config.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                mock.patch.object(status, "hardware_probe", return_value=probe()), mock.patch.object(status, "filevault_state", return_value="on"):
            code = cli.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def make_failed(self, sid: str, *, retryable: bool, age_hours: float, kind: str = "asr_failed") -> Path:
        d = make_session(self.cfg, sid)
        (d / "state.json").write_text(json.dumps({"schema": 1, "stage": "failed", "error": f"transcription failed: {CANARY_PATIENT}",
                                                  "error_kind": kind, "retryable": retryable,
                                                  "updated": (NOW - timedelta(hours=age_hours)).isoformat()}), encoding="utf-8")
        return d

    def log(self, name: str, text: str, age_days: float = 0.0) -> Path:
        path = self.logs / name
        path.write_text(text, encoding="utf-8")
        stamp = NOW.timestamp() - age_days * DAY
        os.utime(path, (stamp, stamp))
        return path


EXPECTED_KEYS = {"schema", "generated", "pipeline_version", "contract", "profile", "policy", "route", "consent", "local_only_default", "sessions",
                 "errors_7d", "device", "disk", "checks"}
USAGE_KEYS = {"asr_usage_7d", "llm_cost_7d_usd"}
CHECK_KEYS = {"policy", "route", "consent", "local_asr", "filevault", "disk", "sessions"}


# ======================================================================================================================
class SchemaTests(StatusCase):
    def test_schema_one_has_the_documented_keys_for_a_mac_without_a_policy(self):
        doc = self.collect()
        self.assertEqual(set(doc), EXPECTED_KEYS | USAGE_KEYS)
        self.assertEqual(doc["schema"], 1)
        self.assertEqual(doc["pipeline_version"], "0.2.0")
        self.assertEqual(doc["contract"], {"required": None, "satisfied": True})
        self.assertEqual(doc["profile"], "none")
        self.assertEqual(doc["policy"], {"state": "absent", "revision": None, "sha256_8": None, "locked_reason": None})
        self.assertEqual(doc["route"], {"primary": "whisper", "fallback": None, "local_capable": True, "egress_allowed": False})
        self.assertEqual(set(doc["consent"]), {"remote", "azure", "clova", "openai-compat"})
        self.assertIs(doc["local_only_default"], False)
        self.assertEqual(set(doc["sessions"]), {"staging", "failed", "failed_retryable", "discarded", "last_done_age_h", "staging_gb", "oldest_failed_age_h"})
        self.assertEqual(doc["errors_7d"], 0)
        self.assertEqual(doc["device"], {"hw_arch": "arm64", "macos": status.macos_version(), "ram_gb": 32.0, "filevault": "on"})
        self.assertIsInstance(doc["disk"]["free_gb"], float)
        self.assertEqual(set(doc["checks"]), CHECK_KEYS)
        self.assertEqual(doc["generated"], NOW.isoformat(timespec="seconds"))
        json.loads(status.serialize(doc))                                                  # serializable
        self.assertLess(len(status.serialize(doc).encode()), 4096)

    def test_a_valid_company_policy_is_reported_by_state_revision_and_hash_only(self):
        org = company_org(self.root)
        doc = self.collect(org=org)
        self.assertEqual((doc["profile"], doc["policy"]["state"], doc["policy"]["revision"]), ("company", "valid", 12))
        self.assertRegex(doc["policy"]["sha256_8"], r"^[0-9a-f]{8}$")
        self.assertIsNone(doc["policy"]["locked_reason"])
        self.assertEqual(doc["contract"], {"required": "0.2.0", "satisfied": True})
        self.assertEqual(doc["checks"]["policy"], "ok")

    def test_a_higher_min_pipeline_version_is_the_required_one_and_an_older_pipeline_does_not_satisfy_it(self):
        org = company_org(self.root, company_doc(min_pipeline_version="0.10.0"), version="0.10.0")
        doc = self.collect(org=org)
        self.assertEqual(doc["contract"], {"required": "0.10.0", "satisfied": False})

    def test_a_locked_policy_says_why_with_a_short_code_and_closes_the_route(self):
        doc = self.collect(org=locked_org(self.root))
        self.assertEqual((doc["policy"]["state"], doc["policy"]["locked_reason"]), ("invalid", "bad-json"))
        self.assertEqual(doc["checks"]["policy"], "fail")
        self.assertIs(doc["local_only_default"], True)
        self.assertIs(doc["route"]["egress_allowed"], False)
        self.assertEqual(doc["contract"]["required"], "0.2.0")

    def test_a_long_or_odd_lock_reason_is_cut_and_cleaned(self):
        org = policy._locked_policy("odd: /Users/someone/secret path\n" + "x" * 200)
        reason = self.collect(org=org)["policy"]["locked_reason"]
        self.assertLessEqual(len(reason), 60)
        self.assertNotIn("/", reason)
        self.assertNotIn("\n", reason)


class RouteAndConsentTests(StatusCase):
    def org_consent_org(self, **sections):
        return company_org(self.root, company_doc(**sections))

    def test_with_the_org_consent_and_an_incapable_mac_the_route_is_the_server(self):
        self.cfg.asr_engine = "auto"
        doc = self.collect(org=self.org_consent_org(), hw=probe(capable=False))
        self.assertEqual(doc["route"], {"primary": "remote", "fallback": None, "local_capable": False, "egress_allowed": True})
        self.assertEqual(doc["consent"]["remote"], "ok")
        self.assertEqual((doc["checks"]["consent"], doc["checks"]["route"], doc["checks"]["local_asr"]), ("ok", "ok", "warn"))

    def test_without_any_consent_an_incapable_mac_is_blocked(self):
        self.cfg.asr_engine = "auto"
        doc = self.collect(org=company_org(self.root, company_doc(asr={"org_consents": []})), hw=probe(capable=False))
        self.assertEqual(doc["consent"]["remote"], "no-consent")
        self.assertEqual((doc["checks"]["route"], doc["checks"]["consent"]), ("fail", "warn"))
        self.assertIs(doc["route"]["egress_allowed"], False)

    def test_consent_states(self):
        org = policy.absent_policy()
        cfg = self.cfg
        entry = consent_entry("remote")
        with_entry = policy.ConsentSet(entries=(entry,), machine=MACHINE)

        def state(consents, **kw):
            return status.consent_state(kw.pop("cfg", cfg), "remote", org, consents, NOW)

        self.assertEqual(state(policy.ConsentSet(machine=MACHINE))["state"], "no-consent")
        ok = state(with_entry)
        self.assertEqual((ok["state"], ok["source"], ok["use"], ok["expires"]), ("ok", "user", "both", "2027-10-14"))
        expired = policy.ConsentSet(entries=(consent_entry("remote", expires="2026-10-01"),), machine=MACHINE)
        self.assertEqual(state(expired)["state"], "consent-expired")
        moved = policy.ConsentSet(entries=(consent_entry("remote", host="other.example.com"),), machine=MACHINE)
        self.assertEqual(state(moved)["state"], "consent-mismatch")
        other_mac = policy.ConsentSet(entries=(entry,), machine="x" * 64)
        self.assertEqual(state(other_mac)["state"], "consent-mismatch")
        self.assertEqual(state(policy.ConsentSet(entries=(entry,), tampered=True, problem="integrity", machine=MACHINE))["state"], "consent-tampered")
        self.cfg.asr_remote_url = ""
        self.assertEqual(state(with_entry)["state"], "not-configured")
        self.cfg.asr_remote_url = "https://10.1.2.3"
        self.assertEqual(state(with_entry)["state"], "bad-host")

    def test_the_org_consent_is_the_source_and_wins_over_nothing(self):
        state = status.consent_state(self.cfg, "remote", company_org(self.root), policy.ConsentSet(machine=MACHINE), NOW)
        self.assertEqual((state["state"], state["source"]), ("ok", "org"))
        self.assertTrue(state["id"].startswith("org:remote-"))

    def test_the_hardware_verdict_and_filevault_drive_the_checks_by_policy_severity(self):
        locked = company_org(self.root, company_doc(local_only={"default": True, "locked": True}))
        plain = company_org(self.root)
        bad = dict(hw=probe(capable=False), filevault="off")
        self.assertEqual({k: self.collect(org=locked, **bad)["checks"][k] for k in ("local_asr", "filevault")}, {"local_asr": "fail", "filevault": "fail"})
        self.assertEqual({k: self.collect(org=plain, **bad)["checks"][k] for k in ("local_asr", "filevault")}, {"local_asr": "warn", "filevault": "warn"})
        unknown = self.collect(org=locked, hw=probe(capable=None), filevault="unknown")["checks"]
        self.assertEqual((unknown["local_asr"], unknown["filevault"]), ("n/a", "n/a"))


class SessionFactTests(StatusCase):
    def test_counts_ages_and_sizes_of_the_staging_sessions(self):
        self.make_failed("2026-10-14_0900_zoom", retryable=True, age_hours=30)
        self.make_failed("2026-10-14_1000_meet", retryable=False, age_hours=5)
        make_session(self.cfg, "2026-10-14_1100_teams")                                       # waiting: no state.json yet
        stub = Path(self.cfg.sessions_dir) / "2026-10-13_1000_zoom"
        stub.mkdir()
        (stub / "state.json").write_text(json.dumps({"stage": "done", "final_dir": "/x", "updated": (NOW - timedelta(hours=3)).isoformat()}))
        (Path(self.cfg.sessions_dir) / "_discarded" / "a").mkdir(parents=True)
        (Path(self.cfg.sessions_dir) / "_discarded" / "b").mkdir()
        sessions = self.collect()["sessions"]
        self.assertEqual((sessions["staging"], sessions["failed"], sessions["failed_retryable"], sessions["discarded"]), (3, 2, 1, 2))
        self.assertEqual(sessions["oldest_failed_age_h"], 30.0)
        self.assertEqual(sessions["last_done_age_h"], 3.0)
        self.assertEqual(sessions["staging_gb"], 0.0)                                         # a few KB of test files
        with mock.patch.object(status, "dir_bytes", return_value=1_500_000_000):              # three sessions of 1.5 GB
            self.assertEqual(self.collect()["sessions"]["staging_gb"], 4.5)

    def test_a_retryable_failure_older_than_a_day_is_a_warning_in_the_checks(self):
        self.make_failed("2026-10-14_0900_zoom", retryable=True, age_hours=30)
        self.assertEqual(self.collect()["checks"]["sessions"], "warn")
        shutil_target = Path(self.cfg.sessions_dir) / "2026-10-14_0900_zoom" / "state.json"
        shutil_target.write_text(json.dumps({"stage": "failed", "retryable": False, "updated": (NOW - timedelta(hours=90)).isoformat()}))
        self.assertEqual(self.collect()["checks"]["sessions"], "ok")

    def test_last_done_looks_at_the_local_archive_too_and_never_at_the_drive(self):
        folder = Path(self.cfg.local_archive_root) / "2026-10" / "2026-10-14_1000_local-meeting"
        folder.mkdir(parents=True)
        (folder / "state.json").write_text(json.dumps({"stage": "done", "updated": (NOW - timedelta(hours=2)).isoformat()}))
        drive = Path(self.cfg.archive_dir) / "2026-10" / "2026-10-14_1100_drive-meeting"
        drive.mkdir(parents=True)
        (drive / "state.json").write_text(json.dumps({"stage": "done", "updated": (NOW - timedelta(hours=1)).isoformat()}))
        self.assertEqual(self.collect()["sessions"]["last_done_age_h"], 2.0)                 # the Drive folder (1 h) is not looked at

    def test_failed_runs_of_the_last_seven_days_are_counted_from_the_last_line_of_each_log(self):
        self.log("pipeline-a.log", "log line\nFAILED: transcription failed: " + CANARY_PATIENT + "\n", 1)
        self.log("pipeline-b.log", "log line\nDONE: /somewhere\n", 1)
        self.log("pipeline-c.log", "FAILED: old\n", 20)                                       # too old
        self.log("pipeline-d.log", "FAILED: first\nDONE: later\n", 2)                         # only the LAST line counts
        self.log("pipeline-retry-sweep.log", "  FAILED: one\nFAILED: pending: 1 session(s) found\n", 0)
        self.log("app.log", "FAILED: not a pipeline log\n", 0)
        self.assertEqual(status.failed_runs(self.cfg, NOW), 2)
        self.assertEqual(self.collect()["errors_7d"], 2)

    def test_an_unreadable_part_is_null_not_an_error(self):
        with mock.patch.object(status, "session_summary", side_effect=OSError("disk")), mock.patch.object(status, "failed_runs", side_effect=OSError("disk")):
            doc = self.collect()
        self.assertIsNone(doc["errors_7d"])
        self.assertIsNone(doc["sessions"]["staging"])


class ListSessionsTests(StatusCase):
    def test_rows_carry_no_title_and_say_what_state_the_session_is_in(self):
        a = self.make_failed("2026-10-14_0900_zoom", retryable=True, age_hours=1)
        (a / "session.json").write_text(json.dumps({"session_id": "2026-10-14_0900_zoom", "title_hint": CANARY_TITLE, "end_time": "2026-10-14T09:30:00+09:00"}))
        make_session(self.cfg, "2026-10-14_1100_teams", title_hint=CANARY_TITLE)
        live = make_session(self.cfg, "2026-10-14_1200_meet", end=None, title_hint=CANARY_TITLE)
        os.utime(live / "mic.wav", (time.time(), time.time()))                                # being written right now
        stub = Path(self.cfg.sessions_dir) / "2026-10-13_1000_zoom"
        stub.mkdir()
        (stub / "state.json").write_text(json.dumps({"stage": "done", "final_dir": "/x"}))
        rows = status.list_sessions(self.cfg, NOW)
        by_id = {r["id"]: r for r in rows}
        self.assertEqual([r["id"] for r in rows], sorted(by_id, reverse=True))                # newest first
        self.assertEqual((by_id["2026-10-14_0900_zoom"]["stage"], by_id["2026-10-14_0900_zoom"]["error_kind"], by_id["2026-10-14_0900_zoom"]["retryable"]),
                         ("failed", "asr_failed", True))
        self.assertEqual(by_id["2026-10-14_1100_teams"]["stage"], "waiting")
        self.assertEqual(by_id["2026-10-14_1200_meet"]["stage"], "recording")
        self.assertTrue(by_id["2026-10-13_1000_zoom"]["tombstone"])
        self.assertEqual(by_id["2026-10-13_1000_zoom"]["size_mb"], 0.0)
        text = json.dumps(rows, ensure_ascii=False)
        for fragment in (CANARY_TITLE, "Confidential", "Kim Minsu", "meet.google.com", str(self.root)):
            self.assertNotIn(fragment, text)
        self.assertEqual(set(rows[0]), {"id", "stage", "error_kind", "retryable", "age_h", "size_mb", "tombstone"})

    def test_a_folder_name_that_is_not_a_plain_id_is_not_shown(self):
        odd = Path(self.cfg.sessions_dir) / "2026-10-14_1000_zoom Kim Minsu (secret)"
        odd.mkdir(parents=True)
        (odd / "session.json").write_text("{}")
        self.assertEqual([r["id"] for r in status.list_sessions(self.cfg, NOW)], ["?"])

    def test_the_sessions_command_prints_a_table_and_json_and_an_empty_message(self):
        self.write_config()
        code, out, _err = self.run_cli("sessions")
        self.assertEqual((code, out.strip()), (0, "no session in staging"))
        self.make_failed("2026-10-14_0900_zoom", retryable=True, age_hours=2)
        code, out, _err = self.run_cli("sessions")
        self.assertEqual(code, 0)
        self.assertIn("2026-10-14_0900_zoom", out)
        self.assertIn("asr_failed", out)
        self.assertIn("1 session folder(s) in staging", out)
        self.assertNotIn("Kim Minsu", out)
        code, out, _err = self.run_cli("sessions", "--json")
        doc = json.loads(out)
        self.assertEqual((doc["schema"], len(doc["sessions"]), doc["sessions"][0]["error_kind"]), (1, 1, "asr_failed"))


# ======================================================================================================================
class CanaryTests(StatusCase):
    """The document of ``mcap status`` is device health: nothing a meeting, a user or an installation could be recognised by."""

    FRAGMENTS = (CANARY_TITLE, "Confidential", "Merger", "Kim Minsu", "chest pain", "2026-10-07_1400", "2026-10-14_0900", "local-meeting",
                 HOST, "example.internal", "Support Dir", "meet.google.com", "relay-ca")

    def build_world(self):
        d = self.make_failed("2026-10-14_0900_zoom", retryable=True, age_hours=30)
        (d / "session.json").write_text(json.dumps({"session_id": "2026-10-14_0900_zoom", "title_hint": CANARY_TITLE,
                                                    "meeting_url": "https://meet.google.com/abc-defg-hij", "end_time": "2026-10-14T09:30:00+09:00"}))
        folder = Path(self.cfg.local_archive_root) / "2026-10" / f"2026-10-07_1400_{CANARY_TITLE.replace(' ', '-')}-local-meeting"
        folder.mkdir(parents=True)
        (folder / "state.json").write_text(json.dumps({"stage": "done", "updated": (NOW - timedelta(hours=2)).isoformat(), "title": CANARY_TITLE}))
        self.log("pipeline-2026-10-14_0900_zoom.log", f"transcribing\nFAILED: transcription failed: {CANARY_PATIENT} in {CANARY_TITLE}\n", 1)
        policy.write_consent(self.cfg.consent_path, consent_entry("remote"), machine_id=MACHINE)
        write_usage(self.cfg, minutes=61, when=NOW - timedelta(days=1))
        usage.record(self.cfg, "note", models=["claude-opus-5"], duration_s=1.0, session_id="2026-10-14_0900_zoom", cost_usd=1.2345)

    def test_no_title_session_id_path_host_or_user_name_is_in_any_form_of_the_document(self):
        self.build_world()
        self.cfg.status_include_usage = True
        home = str(Path.home())
        user = Path.home().name
        docs = [self.collect(org=company_org(self.root)), self.collect(org=policy.absent_policy()), self.collect(org=locked_org(self.root)),
                self.collect(for_mdm=True), self.collect(for_mdm=True, org=company_org(self.root))]
        texts = [status.serialize(d) for d in docs] + ["\n".join(status.render_text(d)) for d in docs]
        for text in texts:
            for fragment in self.FRAGMENTS + (str(self.root), home):
                self.assertNotIn(fragment, text)
            if len(user) >= 4:
                self.assertNotIn(user, text)
            self.assertNotIn("/Users/", text)
            self.assertNotIn("@", text)


class SizeBoundTests(StatusCase):
    def test_the_serialized_document_is_at_most_20_kb(self):
        self.assertEqual(status.MAX_BYTES, 20 * 1024)
        self.assertLessEqual(len(status.serialize(self.collect()).encode()), status.MAX_BYTES)

    def test_fit_drops_optional_parts_when_the_document_is_too_big_and_keeps_the_rest(self):
        doc = self.collect()
        doc["checks"] = {"x%d" % i: "ok" for i in range(3000)}
        fitted = status.fit(doc)
        self.assertLessEqual(len(status.serialize(fitted).encode()), status.MAX_BYTES)
        self.assertTrue(fitted["truncated"])
        self.assertNotIn("checks", fitted)
        self.assertEqual((fitted["schema"], fitted["pipeline_version"]), (1, "0.2.0"))

    def test_fit_ends_in_a_minimal_document_when_nothing_else_helps(self):
        doc = self.collect()
        doc["pipeline_version"] = "9" * 30000
        fitted = status.fit(doc)
        self.assertEqual(set(fitted), {"schema", "pipeline_version", "truncated"})
        self.assertLessEqual(len(status.serialize(fitted).encode()), status.MAX_BYTES)

    def test_the_config_error_survives_every_truncation(self):
        doc = self.collect(config_error="bad-value:AUDIO_RETENTION_DAYS")
        doc["checks"] = {"x%d" % i: "ok" for i in range(3000)}
        self.assertEqual(status.fit(doc)["config_error"], "bad-value:AUDIO_RETENTION_DAYS")
        doc["pipeline_version"] = "9" * 30000
        fitted = status.fit(doc)
        self.assertEqual(set(fitted), {"schema", "pipeline_version", "truncated", "config_error"})
        self.assertLessEqual(len(status.serialize(fitted).encode()), status.MAX_BYTES)

    def test_a_small_limit_in_force_truncates_collect_status_itself(self):
        with mock.patch.object(status, "MAX_BYTES", 600):
            doc = self.collect()
        self.assertTrue(doc.get("truncated"))
        self.assertLessEqual(len(status.serialize(doc).encode()), 600)


class UsageFieldTests(StatusCase):
    def test_usage_numbers_are_in_the_interactive_document_and_in_the_mdm_one_only_when_asked_for(self):
        write_usage(self.cfg, minutes=44, when=NOW - timedelta(days=2))
        write_usage(self.cfg, minutes=47, when=NOW - timedelta(days=1))
        interactive = self.collect()
        self.assertEqual(interactive["asr_usage_7d"], 90)                                     # 91 minutes, rounded to a multiple of 30
        self.assertEqual(self.cfg.status_include_usage, False)
        mdm = self.collect(for_mdm=True)
        self.assertFalse(USAGE_KEYS & set(mdm))
        self.cfg.status_include_usage = True
        mdm_on = self.collect(for_mdm=True)
        self.assertEqual((mdm_on["asr_usage_7d"], mdm_on["llm_cost_7d_usd"]), (90, 0.0))

    def test_rounding_goes_to_the_nearest_half_hour(self):
        for minutes, expected in ((0, 0), (14.9, 0), (15.1, 30), (44, 30), (46, 60), (95, 90)):
            with self.subTest(minutes=minutes):
                with mock.patch.object(asr_usage, "summary", return_value={"minutes": minutes}):
                    self.assertEqual(status.usage_minutes_rounded(self.cfg, NOW), expected)

    def test_the_claude_cost_is_a_total_of_the_seven_days_in_dollars(self):
        self.cfg.status_include_usage = True
        with mock.patch.object(usage, "clock", lambda: NOW - timedelta(days=1)):
            usage.record(self.cfg, "note", models=["claude-opus-5"], duration_s=1.0, session_id="s", cost_usd=1.2345, auth="api")
        self.assertEqual(self.collect(for_mdm=True)["llm_cost_7d_usd"], 1.23)


class DeviceHelperTests(StatusCase):
    @staticmethod
    def runner(stdout="", stderr="", raises=None):
        def run(argv, **kw):
            if raises:
                raise raises
            return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr=stderr)
        return run

    def test_filevault_state_reads_fdesetup_and_never_guesses(self):
        self.assertEqual(status.filevault_state(self.runner("FileVault is On.\n")), "on")
        self.assertEqual(status.filevault_state(self.runner("FileVault is Off.\n")), "off")
        self.assertEqual(status.filevault_state(self.runner("Encryption in progress: Percent completed = 40\n")), "unknown")
        self.assertEqual(status.filevault_state(self.runner(raises=OSError("no such tool"))), "unknown")
        self.assertEqual(status.filevault_state(self.runner(raises=subprocess.TimeoutExpired("fdesetup", 10))), "unknown")

    def test_backup_exclusion_is_read_with_tmutil_isexcluded(self):
        self.assertIs(status.backup_excluded("/x", self.runner("[Excluded]    /x\n")), True)
        self.assertIs(status.backup_excluded("/x", self.runner("[Included]    /x\n")), False)
        self.assertIsNone(status.backup_excluded("/x", self.runner("something else")))
        self.assertIsNone(status.backup_excluded("/x", self.runner(raises=OSError("gone"))))

    def test_free_disk_is_rounded_gigabytes_of_the_support_volume(self):
        self.assertEqual(status.disk_free_gb(self.cfg, lambda path: 12_345_000_000), 12.3)
        self.assertIsNone(status.disk_free_gb(self.cfg, mock.Mock(side_effect=OSError("io"))))
        doc = self.collect(disk_free=lambda path: 800_000_000)
        self.assertEqual((doc["disk"]["free_gb"], doc["checks"]["disk"]), (0.8, "fail"))
        self.assertEqual(self.collect(disk_free=lambda path: 3_000_000_000)["checks"]["disk"], "warn")
        self.assertEqual(self.collect(disk_free=lambda path: 30_000_000_000)["checks"]["disk"], "ok")

    def test_the_hardware_probe_failing_is_unknown_not_an_error(self):
        with mock.patch.object(policy, "probe_hardware", side_effect=RuntimeError("boom")):
            hw = status.hardware_probe(self.cfg)
        self.assertIsNone(hw.capable)
        self.assertEqual(hw.reasons, ("probe-failed",))


class StatusCommandTests(StatusCase):
    def test_the_text_form_and_the_json_form_say_the_same_things(self):
        self.write_config()
        code, text, _err = self.run_cli("status")
        self.assertEqual(code, 0)
        self.assertIn("mcap status (schema 1", text)
        self.assertIn("profile:       none   policy: absent", text)
        self.assertIn("usage (7 days)", text)                                                 # the interactive form always shows usage
        code, out, _err = self.run_cli("status", "--json")
        doc = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(set(doc), EXPECTED_KEYS | USAGE_KEYS)

    def test_write_is_atomic_world_readable_and_leaves_the_usage_out_by_default(self):
        self.write_config()
        target = self.root / "mdm" / "status.json"
        code, out, _err = self.run_cli("status", "--write", str(target))
        self.assertEqual((code, out), (0, ""))
        doc = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(set(doc), EXPECTED_KEYS)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        self.assertEqual([p.name for p in target.parent.iterdir()], ["status.json"])           # no temp file is left behind
        self.write_config(STATUS_INCLUDE_USAGE="1")
        self.run_cli("status", "--write", str(target))
        self.assertEqual(set(json.loads(target.read_text(encoding="utf-8"))), EXPECTED_KEYS | USAGE_KEYS)

    def test_a_target_that_cannot_be_written_is_an_error_with_a_plain_message(self):
        self.write_config()
        blocker = self.root / "a-file"
        blocker.write_text("x")
        code, out, err = self.run_cli("status", "--write", str(blocker / "status.json"))
        self.assertEqual((code, out), (1, ""))
        self.assertIn("cannot write the status file", err)

    def test_json_and_write_exclude_each_other(self):
        self.write_config()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            cli.main(["status", "--json", "--write", str(self.root / "x.json")])
        self.assertEqual(raised.exception.code, 2)

    def test_status_starts_no_claude_reads_no_keychain_item_and_opens_no_socket(self):
        self.write_config()
        self.security.remove()
        self.run_cli("status")
        self.run_cli("status", "--json")
        self.run_cli("sessions")
        self.assertEqual(self.security.calls(), [])                                           # NoNetworkCase asserts the sockets after the test


class BadConfigTests(StatusCase):
    """A config.env the pipeline cannot start with (a bad value, an unreadable file) must not freeze the MDM feed: the old document would stay
    on disk and look healthy. The document says so instead (``config_error``, ``checks.config`` = fail; the KEY name, never the value) and is
    written all the same. The built-in defaults are stood in by the temp-rooted config, so the real SUPPORT_DIR is never read."""
    BAD_VALUE = "/Users/bob/patient-kim"

    def setUp(self):
        super().setUp()
        defaults = mock.patch.object(cli, "Config", lambda: dataclasses.replace(self.cfg))
        defaults.start()
        self.addCleanup(defaults.stop)
        self.write_config(AUDIO_RETENTION_DAYS=self.BAD_VALUE)
        self.target = self.root / "mdm" / "status.json"
        self.target.parent.mkdir()
        self.target.write_text('{"stale":"previous good document"}', encoding="utf-8")

    def test_write_replaces_the_stale_file_with_a_document_that_says_the_config_is_bad(self):
        code, out, err = self.run_cli("status", "--write", str(self.target))
        self.assertEqual((code, out, err), (0, "", ""))
        text = self.target.read_text(encoding="utf-8")
        doc = json.loads(text)
        self.assertNotIn("stale", doc)
        self.assertEqual(doc["config_error"], "bad-value:AUDIO_RETENTION_DAYS")
        self.assertEqual(doc["checks"]["config"], "fail")
        self.assertEqual(set(doc), EXPECTED_KEYS | {"config_error"})
        self.assertEqual(set(doc["checks"]), CHECK_KEYS | {"config"})
        self.assertEqual((doc["schema"], doc["policy"]["state"]), (1, "absent"))
        for fragment in (self.BAD_VALUE, "canary", "patient", "/Users/"):
            self.assertNotIn(fragment, text)
        self.assertEqual([p.name for p in self.target.parent.iterdir()], ["status.json"])

    def test_the_interactive_forms_show_it_and_warn_on_stderr_without_the_value(self):
        code, out, err = self.run_cli("status", "--json")
        doc = json.loads(out)
        self.assertEqual((code, doc["config_error"], doc["checks"]["config"]), (0, "bad-value:AUDIO_RETENTION_DAYS", "fail"))
        self.assertIn("warning: config.env cannot be used (bad-value:AUDIO_RETENTION_DAYS)", err)
        code, text, err = self.run_cli("status")
        self.assertEqual(code, 0)
        self.assertIn("config.env CANNOT BE USED (bad-value:AUDIO_RETENTION_DAYS)", text)
        self.assertIn("mcap status (schema 1", text)
        for output in (out, err, text):
            self.assertNotIn(self.BAD_VALUE, output)

    def test_an_unreadable_file_and_an_undecodable_one_have_their_own_codes(self):
        path = self.root / "config.env"
        path.unlink()
        path.mkdir()                                                                          # a folder where the file should be: OSError
        self.assertEqual(json.loads(self.run_cli("status", "--json")[1])["config_error"], "unreadable")
        path.rmdir()
        path.write_bytes(b"ARCHIVE_DIR=\xff\xfe\x80\n")                                       # not UTF-8: UnicodeDecodeError
        self.assertEqual(json.loads(self.run_cli("status", "--json")[1])["config_error"], "invalid")
        self.write_config(MAX_CLAUDE_CALLS_PER_MEETING="many")
        self.assertEqual(json.loads(self.run_cli("status", "--json")[1])["config_error"], "bad-value:MAX_CLAUDE_CALLS_PER_MEETING")

    def test_a_good_config_has_neither_key(self):
        self.write_config()
        code, out, _err = self.run_cli("status", "--json")
        doc = json.loads(out)
        self.assertNotIn("config_error", doc)
        self.assertEqual(set(doc["checks"]), CHECK_KEYS)

    def test_the_stand_in_config_keeps_the_policy_location_and_a_managed_mac_ignores_the_override(self):
        override = self.root / "pol" / "policy.json"
        with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": str(override)}):
            cfg, error = cli.status_config()
            self.assertEqual((error, cfg.policy_path), ("bad-value:AUDIO_RETENTION_DAYS", override))
            with mock.patch.object(cli, "load_config", side_effect=ValueError("config.env: bad value for ASR_REMOTE_MAX_WAIT_S: 'x'")):
                self.system_policy(True)                                                      # a managed Mac: the override is no way around it
                cfg, error = cli.status_config()
                self.assertEqual((error, cfg.policy_path), ("bad-value:ASR_REMOTE_MAX_WAIT_S", config.POLICY_SYSTEM_PATH))
                code, out, _err = self.run_cli("status", "--json")
        doc = json.loads(out)
        self.assertEqual((code, doc["policy"]["state"], doc["config_error"]), (0, "invalid", "bad-value:ASR_REMOTE_MAX_WAIT_S"))
        self.assertEqual(doc["route"]["primary"], "whisper")

    def test_a_config_error_code_given_to_collect_status_is_made_safe(self):
        doc = self.collect(config_error="bad-value:/Users/alice/AUDIO_RETENTION_DAYS")
        self.assertEqual(doc["checks"]["config"], "fail")
        self.assertNotIn("/", doc["config_error"])
        self.assertNotIn("config_error", self.collect(config_error=None))
        self.assertIn("config.env CANNOT BE USED", "\n".join(status.render_text(self.collect(config_error="invalid"))))


if __name__ == "__main__":
    import unittest
    unittest.main()
