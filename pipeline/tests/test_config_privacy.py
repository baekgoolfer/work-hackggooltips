"""The configuration side of SPEC 18: every new key of
config.env with its documented default, the per-key restrictive reading of an unrecognised switch, the location of the organisation policy
(no config.env key and no environment variable moves it), what a policy-managed Mac ignores, the defaults/enforced layers and
``explicit_keys``. Everything runs on temp files; the real /Library policy, SUPPORT_DIR and Keychain are never touched (the paths are
patched and every policy is loaded through an injected lstat).

Run: python -m unittest discover -s pipeline/tests
"""
from __future__ import annotations

import dataclasses
import json
import math
import os
import re
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import config, policy  # noqa: E402
from mcap.config import Config, load_config, parse_env_text  # noqa: E402
from notes_cli_support import TempCase  # noqa: E402
import test_policy as tp  # noqa: E402  (module import only: its TestCase classes must not be collected here)

REPO = Path(__file__).resolve().parents[2]
EXAMPLE = REPO / "config" / "config.env.example"

# key -> (Config field, value of the documented default). Written from fixtures/config_keys.json (the documented keys and defaults), not from config.py.
DOCUMENTED = {
    "LOCAL_ONLY_DEFAULT": ("local_only_default", False), "ASR_ENGINE": ("asr_engine", "whisper"), "ASR_FALLBACK": ("asr_fallback", "none"),
    "ASR_LOCAL_MIN_RAM_GB": ("asr_local_min_ram_gb", 16), "ASR_LOCAL_MAX_RTF": ("asr_local_max_rtf", 0.25),
    "ASR_REMOTE_URL": ("asr_remote_url", ""), "ASR_REMOTE_CA_FILE": ("asr_remote_ca_file", None),
    "ASR_REMOTE_MAX_WAIT_S": ("asr_remote_max_wait_s", 120), "ASR_AZURE_REGION": ("asr_azure_region", "koreacentral"),
    "ASR_AZURE_HOST": ("asr_azure_host", ""), "ASR_AZURE_LOCALES": ("asr_azure_locales", ""), "ASR_AZURE_BIAS": ("asr_azure_bias", 1.0),
    "ASR_AZURE_USD_PER_HOUR": ("asr_azure_usd_per_hour", 0.0), "ASR_CLOUD_DAILY_MINUTES": ("asr_cloud_daily_minutes", 240),
    "ASR_REQUEST_TIMEOUT_S": ("asr_request_timeout_s", 90), "ASR_RETRY_MAX": ("asr_retry_max", 3), "ASR_CIRCUIT_FAILS": ("asr_circuit_fails", 3),
    "ASR_CIRCUIT_COOLDOWN_S": ("asr_circuit_cooldown_s", 120), "ASR_ALLOW_DOWNLOAD": ("asr_allow_download", True),
    "ASR_SEND_VOCAB": ("asr_send_vocab", True), "LOCAL_ARCHIVE_DIR": ("local_archive_dir", None),
    "LOCAL_ARCHIVE_RETENTION_DAYS": ("local_archive_retention_days", 0), "STAGING_FAILED_RETENTION_DAYS": ("staging_failed_retention_days", 0),
    "MIC_MUTE_GATE": ("mic_mute_gate", "off"), "LOG_CONTENT": ("log_content", True), "LOG_RETENTION_DAYS": ("log_retention_days", 0),
    "APP_LOG_MAX_MB": ("app_log_max_mb", 0), "STATUS_INCLUDE_USAGE": ("status_include_usage", False),
}
# the text of each documented default as the example file shows it (an empty value means "unset")
DEFAULT_TEXT = {"LOCAL_ONLY_DEFAULT": "0", "ASR_ALLOW_DOWNLOAD": "1", "ASR_SEND_VOCAB": "1", "LOG_CONTENT": "1", "STATUS_INCLUDE_USAGE": "0"}
TEST_ENV = ("MCAP_CONFIG", "MCAP_LOG_DIR", "MCAP_SILERO_MODEL", "MCAP_SECURITY_BIN", "MCAP_POLICY_PATH")


class ConfigCase(TempCase):
    """Temp root + a clean environment (no MCAP_* hook leaks in from the runner) + patched system-policy locations that do not exist."""

    def setUp(self):
        super().setUp()
        clean = {k: v for k, v in os.environ.items() if k not in TEST_ENV and k != "MCAP_SECURITY_BIN"}
        clean["MCAP_SECURITY_BIN"] = os.environ["MCAP_SECURITY_BIN"]            # TempCase's fake security stays
        env = mock.patch.dict(os.environ, clean, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.sys_dir = self.root / "Library" / "MeetingCapture"
        self.sys_dir.mkdir(parents=True)
        self.sys_policy, self.sys_marker = self.sys_dir / "policy.json", self.sys_dir / "policy.required"
        for name, value in (("POLICY_SYSTEM_PATH", self.sys_policy), ("POLICY_REQUIRED_MARKER", self.sys_marker)):
            patcher = mock.patch.object(config, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.env_file = self.root / "config.env"

    def write(self, text: str) -> Path:
        self.env_file.write_text(text, encoding="utf-8")
        return self.env_file

    def load(self, text: str = "") -> Config:
        return load_config(self.write(text))

    def managed_by(self, doc=None, *, marker=False, broken=False):
        """Make this Mac policy-managed: the (patched) policy.json and/or the marker exist. ``doc`` is the policy, ``broken`` a policy.json that
        is not JSON, neither with ``marker`` = a marker without a policy file. The loader is handed the file read through an injected
        root-owned lstat (a test is not root)."""
        for stale in (self.sys_policy, self.sys_marker):
            stale.unlink(missing_ok=True)
        if doc is not None:
            self.sys_policy.write_text(json.dumps(doc), encoding="utf-8")
        elif broken:
            self.sys_policy.write_text("{", encoding="utf-8")
        if marker:
            self.sys_marker.write_text("")
        real = policy.load_org_policy
        fake_stat = tp.make_stat_fn(self.sys_policy, marker=self.sys_marker, marker_present=marker, missing=(doc is None and not broken))
        patcher = mock.patch.object(policy, "load_org_policy", lambda path=None, **kw: real(
            path, required_marker=self.sys_marker, stat_fn=fake_stat, current_version="0.2.0", sleep=lambda s: None))
        patcher.start()
        self.addCleanup(patcher.stop)


# ---------------------------------------------------------------------------------------------------- the keys and the example file
def privacy_section_text() -> str:
    """config.env.example with every commented line of the SPEC 18 section uncommented (the section ends at the 'Tests only' note)."""
    lines = EXAMPLE.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if "Privacy lanes, external ASR, local data" in line)
    end = next(i for i, line in enumerate(lines) if line.startswith("# Tests only"))
    out = []
    for line in lines[start:end]:
        m = re.match(r"^# ?([A-Z][A-Z0-9_]*=.*)$", line)
        out.append(m.group(1) if m else line)
    return "\n".join(out) + "\n"


class NewKeyTests(ConfigCase):
    def test_every_new_key_is_in_keys_and_defaults_to_todays_behaviour(self):
        for key, (field, default) in DOCUMENTED.items():
            with self.subTest(key=key):
                self.assertIn(key, config._KEYS)
                self.assertEqual(config._KEYS[key][0], field)
                self.assertEqual(getattr(Config(), field), default)

    def test_work_packages_config_keys_are_all_known(self):
        doc = json.loads((REPO / "pipeline" / "tests" / "fixtures" / "config_keys.json").read_text(encoding="utf-8"))
        names = [row["key"] for row in doc["config_keys"] if re.fullmatch(r"[A-Z][A-Z0-9_]+", row["key"]) and row["key"] != "MCAP_POLICY_PATH"]
        self.assertGreaterEqual(len(names), 28)
        self.assertEqual(set(names), set(DOCUMENTED))
        for row in doc["config_keys"]:
            if row["key"] in DOCUMENTED:
                key = row["key"]
                text = row["default"]
                with self.subTest(key=key):
                    if text.startswith("(") or text.startswith("SUPPORT_DIR"):
                        continue                                                # empty: unset
                    cfg = self.load(f"{key}={text}\n")
                    self.assertEqual(getattr(cfg, DOCUMENTED[key][0]), DOCUMENTED[key][1])

    def test_example_file_lists_each_key_commented_with_its_default(self):
        text = privacy_section_text()
        values = parse_env_text(text)
        self.assertEqual(set(values), set(DOCUMENTED))                         # exactly the documented keys, no stray one
        cfg = load_config(self.write(text))
        for key, (field, default) in DOCUMENTED.items():
            with self.subTest(key=key):
                self.assertEqual(getattr(cfg, field), default)
        self.assertEqual(cfg.config_warnings, ())                              # the example is a clean config
        self.assertEqual(cfg.explicit_keys, frozenset(k for k, v in values.items() if v != ""))
        # and while commented out the section changes nothing
        plain = load_config(EXAMPLE)
        self.assertEqual({f: getattr(plain, f) for _, (f, _) in DOCUMENTED.items()}, {f: d for _, (f, d) in DOCUMENTED.items()})

    def test_every_key_line_of_the_example_is_commented_out(self):
        values = parse_env_text(EXAMPLE.read_text(encoding="utf-8"))
        for key in DOCUMENTED:
            self.assertNotIn(key, values, key)
        self.assertNotIn("SUPPORT_DIR", values)

    def test_values_are_read(self):
        cfg = self.load("\n".join(["LOCAL_ONLY_DEFAULT=1", "ASR_ENGINE=remote", "ASR_FALLBACK=whisper", "ASR_LOCAL_MIN_RAM_GB=8",
                                   "ASR_LOCAL_MAX_RTF=0.5", "ASR_REMOTE_URL= https://asr.example:8443/ ", "ASR_REMOTE_CA_FILE=~/ca.pem",
                                   "ASR_REMOTE_MAX_WAIT_S=30", "ASR_AZURE_REGION=KoreaCentral", "ASR_AZURE_HOST=My.Speech.CognitiveServices.Azure.com",
                                   "ASR_AZURE_LOCALES=ko-KR,en-US", "ASR_AZURE_BIAS=1.5", "ASR_AZURE_USD_PER_HOUR=1.2", "ASR_CLOUD_DAILY_MINUTES=0",
                                   "ASR_REQUEST_TIMEOUT_S=45", "ASR_RETRY_MAX=5", "ASR_CIRCUIT_FAILS=2", "ASR_CIRCUIT_COOLDOWN_S=60",
                                   "ASR_ALLOW_DOWNLOAD=0", "ASR_SEND_VOCAB=no", "LOCAL_ARCHIVE_DIR=~/Local Meetings", "LOCAL_ARCHIVE_RETENTION_DAYS=30",
                                   "STAGING_FAILED_RETENTION_DAYS=14", "MIC_MUTE_GATE=on", "LOG_CONTENT=0", "LOG_RETENTION_DAYS=30", "APP_LOG_MAX_MB=5",
                                   "STATUS_INCLUDE_USAGE=yes"]) + "\n")
        home = Path.home()
        expect = dict(local_only_default=True, asr_engine="remote", asr_fallback="whisper", asr_local_min_ram_gb=8, asr_local_max_rtf=0.5,
                      asr_remote_url="https://asr.example:8443/", asr_remote_ca_file=home / "ca.pem", asr_remote_max_wait_s=30,
                      asr_azure_region="koreacentral", asr_azure_host="my.speech.cognitiveservices.azure.com", asr_azure_locales="ko-KR,en-US",
                      asr_azure_bias=1.5, asr_azure_usd_per_hour=1.2, asr_cloud_daily_minutes=0, asr_request_timeout_s=45, asr_retry_max=5,
                      asr_circuit_fails=2, asr_circuit_cooldown_s=60, asr_allow_download=False, asr_send_vocab=False,
                      local_archive_dir=home / "Local Meetings", local_archive_retention_days=30, staging_failed_retention_days=14,
                      mic_mute_gate="on", log_content=False, log_retention_days=30, app_log_max_mb=5, status_include_usage=True)
        for field, value in expect.items():
            self.assertEqual(getattr(cfg, field), value, field)
        self.assertEqual(cfg.config_warnings, ())

    def test_empty_values_mean_the_default(self):
        cfg = self.load("ASR_ENGINE=\nLOCAL_ONLY_DEFAULT=\nASR_ALLOW_DOWNLOAD=\nASR_REMOTE_CA_FILE=\nLOCAL_ARCHIVE_DIR=\nLOG_CONTENT=\n")
        self.assertEqual((cfg.asr_engine, cfg.local_only_default, cfg.asr_allow_download, cfg.asr_remote_ca_file, cfg.local_archive_dir, cfg.log_content),
                         ("whisper", False, True, None, None, True))
        self.assertEqual(cfg.explicit_keys, frozenset())
        self.assertEqual(cfg.config_warnings, ())

    def test_numbers_are_checked_like_every_number_always_was(self):
        for line in ("ASR_RETRY_MAX=abc", "ASR_RETRY_MAX=0", "ASR_RETRY_MAX=-1", "ASR_RETRY_MAX=2.5", "ASR_CIRCUIT_FAILS=0", "ASR_REQUEST_TIMEOUT_S=0",
                     "ASR_REMOTE_MAX_WAIT_S=0", "ASR_CIRCUIT_COOLDOWN_S=0", "ASR_LOCAL_MAX_RTF=0", "ASR_LOCAL_MAX_RTF=-0.5", "ASR_LOCAL_MAX_RTF=nan",
                     "ASR_LOCAL_MAX_RTF=inf", "ASR_AZURE_BIAS=2.5", "ASR_AZURE_BIAS=-0.1", "ASR_AZURE_BIAS=nan", "ASR_AZURE_USD_PER_HOUR=-1",
                     "ASR_AZURE_USD_PER_HOUR=inf", "ASR_CLOUD_DAILY_MINUTES=-5", "ASR_LOCAL_MIN_RAM_GB=-1", "LOG_RETENTION_DAYS=-1",
                     "APP_LOG_MAX_MB=ten", "LOCAL_ARCHIVE_RETENTION_DAYS=-3", "STAGING_FAILED_RETENTION_DAYS=1.5"):
            with self.subTest(line=line):
                with self.assertRaisesRegex(ValueError, "config.env: bad value for " + line.split("=")[0]):
                    self.load(line + "\n")
        self.assertEqual(self.load("ASR_AZURE_BIAS=0\nASR_AZURE_BIAS=2\n").asr_azure_bias, 2.0)
        self.assertEqual(self.load("ASR_CLOUD_DAILY_MINUTES=0\n").asr_cloud_daily_minutes, 0)

    def test_existing_keys_behave_as_before(self):
        cfg = self.load("NOTE_TIMEOUT_SECONDS=30\nSELF_NAME=Alice\nTRANSCRIPT_CLEANUP=0\nNOTE_VERIFY=yes\nARCHIVE_DIR=~/Meetings\nCLAUDE_AUTH=api\n")
        self.assertEqual((cfg.note_timeout_seconds, cfg.self_name, cfg.transcript_cleanup, cfg.note_verify, cfg.archive_dir, cfg.claude_auth),
                         (30, "Alice", False, True, Path.home() / "Meetings", "api"))
        with self.assertRaisesRegex(ValueError, "config.env: bad value for NOTE_TIMEOUT_SECONDS"):
            self.load("NOTE_TIMEOUT_SECONDS=soon\n")

    def test_mic_aec_defaults_to_auto_and_reads_its_key(self):
        self.assertEqual(self.load("").mic_aec, "auto")
        self.assertEqual(self.load("MIC_AEC=0\n").mic_aec, "0")

    def test_the_default_archive_is_a_plain_local_folder(self):
        self.assertEqual(Config().archive_dir, Path.home() / "Meetings")

    def test_an_empty_config_is_the_default_config(self):
        here = Config(policy_path=self.sys_policy)                              # the policy location is patched into a temp dir here
        self.assertEqual(self.load(""), here)
        missing = load_config(self.root / "nonexistent.env")
        self.assertEqual(missing, here)
        self.assertEqual(missing.explicit_keys, frozenset())
        self.assertEqual(missing.config_warnings, ())
        self.assertIsNone(missing.asr_decision)


class SwitchTests(ConfigCase):
    ON = ("1", "true", "yes", "on", "TRUE", " Yes ", "On")
    OFF = ("0", "false", "no", "off", "FALSE", " No ", "Off")
    JUNK = ("maybe", "2", "enable", "tru", "y", "n", "disabled", "-1", "yes please", "0.0", "none", "null", "ja", "x" * 50)

    def test_switch_function_reads_the_restrictive_value_of_its_key(self):
        for restrictive in (True, False):
            cast = config._switch(restrictive)
            for text in self.ON:
                self.assertIs(cast(text), True)
            for text in self.OFF:
                self.assertIs(cast(text), False)
            for text in self.JUNK + ("",):
                self.assertIs(cast(text), restrictive, text)
        self.assertTrue(config._switch(True).recognised("on"))
        self.assertFalse(config._switch(True).recognised("maybe"))

    def test_the_restrictive_value_of_each_key(self):
        # key -> (field, value read from unrecognised text): SPEC 18
        restrictive = {"LOCAL_ONLY_DEFAULT": ("local_only_default", True), "ASR_ALLOW_DOWNLOAD": ("asr_allow_download", False),
                       "LOG_CONTENT": ("log_content", False), "ASR_SEND_VOCAB": ("asr_send_vocab", False),
                       "STATUS_INCLUDE_USAGE": ("status_include_usage", False), "MIC_MUTE_GATE": ("mic_mute_gate", "on")}
        for key, (field, value) in restrictive.items():
            for junk in self.JUNK:
                with self.subTest(key=key, text=junk):
                    cfg = self.load(f"{key}={junk}\n")
                    self.assertEqual(getattr(cfg, field), value)
                    self.assertEqual(len(cfg.config_warnings), 1)
                    self.assertTrue(cfg.config_warnings[0].startswith(f"{key}: unrecognised value"))

    def test_recognised_texts_read_plainly_and_warn_about_nothing(self):
        for key, field in (("LOCAL_ONLY_DEFAULT", "local_only_default"), ("ASR_ALLOW_DOWNLOAD", "asr_allow_download"), ("LOG_CONTENT", "log_content"),
                           ("ASR_SEND_VOCAB", "asr_send_vocab"), ("STATUS_INCLUDE_USAGE", "status_include_usage")):
            for text in self.ON:
                cfg = self.load(f"{key}={text}\n")
                self.assertIs(getattr(cfg, field), True, f"{key}={text}")
                self.assertEqual(cfg.config_warnings, ())
            for text in self.OFF:
                cfg = self.load(f"{key}={text}\n")
                self.assertIs(getattr(cfg, field), False, f"{key}={text}")
        for text in self.ON:
            self.assertEqual(self.load(f"MIC_MUTE_GATE={text}\n").mic_mute_gate, "on")
        for text in self.OFF:
            self.assertEqual(self.load(f"MIC_MUTE_GATE={text}\n").mic_mute_gate, "off")

    def test_engine_words(self):
        for key, field, default, good in (("ASR_ENGINE", "asr_engine", "whisper", ("whisper", "remote", "azure", "auto")),
                                         ("ASR_FALLBACK", "asr_fallback", "none", ("none", "whisper", "remote", "azure"))):
            for word in good:
                cfg = self.load(f"{key}={word.upper()}\n")
                self.assertEqual(getattr(cfg, field), word)
                self.assertEqual(cfg.config_warnings, ())
            for junk in ("banana", "google", "whisper2", "remote,azure", "qwen3-asr", "1"):
                with self.subTest(key=key, junk=junk):
                    cfg = self.load(f"{key}={junk}\n")
                    self.assertEqual(getattr(cfg, field), default)
                    self.assertEqual(len(cfg.config_warnings), 1)
        self.assertEqual(self.load("ASR_ENGINE=remote\nASR_FALLBACK=banana\n").asr_engine, "remote")

    def test_warnings_never_carry_more_than_a_short_piece_of_the_value(self):
        cfg = self.load("LOG_CONTENT=" + "x" * 500 + "\n")
        self.assertLess(len(cfg.config_warnings[0]), 140)
        self.assertNotIn("x" * 40, cfg.config_warnings[0])


# ---------------------------------------------------------------------------------------------------- policy location and hooks
class PolicyPathTests(ConfigCase):
    def test_default_policy_path_is_the_system_one(self):
        self.assertEqual(Config().policy_path, Path("/Library/Application Support/MeetingCapture/policy.json"))
        self.assertEqual(load_config(self.write("")).policy_path, self.sys_policy)                  # patched constant, read at call time

    def test_the_real_constants(self):
        self.assertEqual(os.fspath(Path("/Library/Application Support/MeetingCapture/policy.required")), "/Library/Application Support/MeetingCapture/policy.required")
        src = Path(config.__file__).read_text(encoding="utf-8")
        self.assertIn('Path("/Library/Application Support/MeetingCapture/policy.json")', src)
        self.assertIn('Path("/Library/Application Support/MeetingCapture/policy.required")', src)

    def test_policy_path_is_not_a_config_key_and_no_config_env_line_moves_it(self):
        self.assertNotIn("POLICY_PATH", config._KEYS)
        self.assertFalse([k for k, (field, _) in config._KEYS.items() if field == "policy_path"])
        cfg = self.load("POLICY_PATH=/tmp/evil.json\npolicy_path=/tmp/evil.json\nMCAP_POLICY_PATH=/tmp/evil.json\n")
        self.assertEqual(cfg.policy_path, self.sys_policy)
        self.assertFalse(config.policy_path_override())

    def test_no_environment_variable_moves_the_default_of_config(self):
        with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": "/tmp/x.json", "POLICY_PATH": "/tmp/y.json"}):
            self.assertEqual(Config().policy_path, Path("/Library/Application Support/MeetingCapture/policy.json"))

    def test_mcap_policy_path_is_honoured_only_without_a_system_policy(self):
        other = self.root / "other-policy.json"
        with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": str(other)}):
            self.assertEqual(config.policy_path_override(), other)
            self.assertEqual(load_config(self.write("")).policy_path, other)
            self.sys_policy.write_text("{")                                                         # now a system policy exists
            self.assertIsNone(config.policy_path_override())
            self.assertEqual(load_config(self.write("")).policy_path, self.sys_policy)
            self.sys_policy.unlink()
            self.assertEqual(config.policy_path_override(), other)
            self.sys_marker.write_text("")                                                          # the marker alone is enough
            self.assertIsNone(config.policy_path_override())
            self.assertEqual(load_config(self.write("")).policy_path, self.sys_policy)
        self.assertIsNone(config.policy_path_override())                                            # variable unset
        with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": ""}):
            self.assertIsNone(config.policy_path_override())

    def test_system_policy_present(self):
        self.assertFalse(config.system_policy_present())
        self.sys_marker.write_text("")
        self.assertTrue(config.system_policy_present())
        self.sys_marker.unlink()
        self.sys_policy.write_text("")
        self.assertTrue(config.system_policy_present())
        self.sys_policy.unlink()
        self.sys_policy.symlink_to(self.root / "dangling")                                          # lstat: a dangling link is still there
        self.assertTrue(config.system_policy_present())
        self.sys_policy.unlink()
        self.assertFalse(config.system_policy_present())
        with mock.patch.object(config, "POLICY_SYSTEM_PATH", self.root / "a-file" / "policy.json"):
            (self.root / "a-file").write_text("")                                                   # ENOTDIR counts as absent
            self.assertFalse(config.system_policy_present())

    def test_a_lookup_that_fails_for_another_reason_counts_as_managed(self):
        with mock.patch("os.lstat", side_effect=PermissionError("denied")):
            self.assertTrue(config.system_policy_present())
        with mock.patch("os.lstat", side_effect=OSError("io")):
            self.assertTrue(config.system_policy_present())
        with mock.patch("os.lstat", side_effect=FileNotFoundError()):
            self.assertFalse(config.system_policy_present())


class TestHookTests(ConfigCase):
    def hooks(self, **extra):
        values = {"MCAP_CONFIG": str(self.root / "hook.env"), "MCAP_LOG_DIR": str(self.root / "hook-logs"), "MCAP_SILERO_MODEL": "/x/silero.onnx",
                  "MCAP_SECURITY_BIN": "/x/security", "MCAP_POLICY_PATH": str(self.root / "hook-policy.json")}
        values.update(extra)
        return mock.patch.dict(os.environ, values)

    def test_hooks_work_without_a_system_policy(self):
        (self.root / "hook.env").write_text("SELF_NAME=FromHook\n")
        with self.hooks():
            for name in config.TEST_HOOK_ENV:
                self.assertEqual(config.test_hook_env(name), os.environ[name], name)
            self.assertEqual(load_config().self_name, "FromHook")                                   # MCAP_CONFIG is read
            self.assertEqual(Config().log_dir, self.root / "hook-logs")
        self.assertIsNone(config.test_hook_env("MCAP_CONFIG"))
        self.assertEqual(Config().log_dir, Path.home() / "Library" / "Logs" / "MeetingCapture")

    def test_hooks_are_ignored_on_a_managed_mac(self):
        (self.root / "hook.env").write_text("SELF_NAME=FromHook\n")
        for managed in (lambda: self.sys_policy.write_text("{"), lambda: self.sys_marker.write_text("")):
            for stale in (self.sys_policy, self.sys_marker):
                stale.unlink(missing_ok=True)
            managed()
            with self.hooks():
                for name in config.TEST_HOOK_ENV:
                    self.assertIsNone(config.test_hook_env(name), name)
                self.assertEqual(Config().log_dir, Path.home() / "Library" / "Logs" / "MeetingCapture")
                self.assertEqual(Config().log_dir, Config(support_dir=self.root).log_dir)
                with mock.patch.object(config, "DEFAULT_SUPPORT_DIR", self.root / "default-support"):
                    (self.root / "default-support").mkdir(exist_ok=True)
                    (self.root / "default-support" / "config.env").write_text("SELF_NAME=FromDefault\n")
                    self.assertEqual(load_config().self_name, "FromDefault")                       # MCAP_CONFIG is ignored

    def test_the_list_of_hooks_is_the_documented_one(self):
        self.assertEqual(set(config.TEST_HOOK_ENV), set(TEST_ENV))
        self.assertEqual(set(config.POLICY_IGNORED_KEYS), {"SUPPORT_DIR", "PYTHON_BIN", "PROJECT_DIR", "CLAUDE_BIN"})

    def test_config_env_path_keys_are_ignored_on_a_managed_mac_and_honoured_otherwise(self):
        text = (f"SUPPORT_DIR={self.root}/other-support\nPYTHON_BIN={self.root}/py\nPROJECT_DIR={self.root}/proj\nCLAUDE_BIN={self.root}/claude\n"
                f"ARCHIVE_DIR={self.root}/archive\nSELF_NAME=Alice\nLOCAL_ARCHIVE_DIR={self.root}/local\n")
        free = self.load(text)
        self.assertEqual((free.support_dir, free.python_bin, free.project_dir, free.claude_bin),
                         (self.root / "other-support", self.root / "py", self.root / "proj", self.root / "claude"))
        self.assertEqual(free.explicit_keys, {"SUPPORT_DIR", "PYTHON_BIN", "PROJECT_DIR", "CLAUDE_BIN", "ARCHIVE_DIR", "SELF_NAME", "LOCAL_ARCHIVE_DIR"})
        self.sys_marker.write_text("")                                                              # now this Mac is managed
        managed = self.load(text)
        default = Config()
        self.assertEqual((managed.support_dir, managed.python_bin, managed.project_dir, managed.claude_bin),
                         (default.support_dir, default.python_bin, default.project_dir, default.claude_bin))
        self.assertEqual((managed.archive_dir, managed.self_name, managed.local_archive_dir),
                         (self.root / "archive", "Alice", self.root / "local"))                       # everything else still reads
        self.assertEqual(managed.explicit_keys, {"ARCHIVE_DIR", "SELF_NAME", "LOCAL_ARCHIVE_DIR"})

    def test_support_dir_override_resets_python_bin_like_before(self):
        cfg = self.load(f"SUPPORT_DIR={self.root}/s\n")
        self.assertEqual((cfg.support_dir, cfg.python_bin), (self.root / "s", self.root / "s" / "venv" / "bin" / "python"))
        cfg = self.load(f"SUPPORT_DIR={self.root}/s\nPYTHON_BIN={self.root}/p\n")
        self.assertEqual(cfg.python_bin, self.root / "p")


# ---------------------------------------------------------------------------------------------------- explicit keys
class ExplicitKeysTests(ConfigCase):
    def test_keys_present_with_a_value_in_config_env(self):
        cfg = self.load("ARCHIVE_DIR=~/M\nSELF_NAME=\nASR_ENGINE=remote\n# NOTE_MODEL=opus\nUNKNOWN_KEY=1\nLOG_CONTENT=0 # inline comment\n")
        self.assertEqual(cfg.explicit_keys, frozenset({"ARCHIVE_DIR", "ASR_ENGINE", "UNKNOWN_KEY", "LOG_CONTENT"}))
        self.assertIsInstance(cfg.explicit_keys, frozenset)

    def test_it_does_not_enter_equality_or_repr(self):
        a, b = self.load("ARCHIVE_DIR=~/M\n"), Config(archive_dir=Path.home() / "M", policy_path=self.sys_policy)
        self.assertEqual(a, b)
        self.assertNotIn("explicit_keys", repr(a))
        self.assertNotIn("asr_decision", repr(a))
        self.assertNotIn("config_warnings", repr(a))

    def test_policy_layers_do_not_count_as_explicit(self):
        self.managed_by(tp.company(defaults={"ASR_ENGINE": "auto"}, enforced={"AUDIO_RETENTION_DAYS": "30"}))
        cfg = self.load("ARCHIVE_DIR=~/M\n")
        self.assertEqual(cfg.explicit_keys, frozenset({"ARCHIVE_DIR"}))

    def test_a_blank_archive_dir_is_not_an_explicit_choice(self):
        self.assertNotIn("ARCHIVE_DIR", self.load("ARCHIVE_DIR=\n").explicit_keys)
        self.assertNotIn("ARCHIVE_DIR", self.load("ARCHIVE_DIR=   \n").explicit_keys)


# ---------------------------------------------------------------------------------------------------- layers
class PolicyLayerTests(ConfigCase):
    def test_no_policy_no_layers(self):
        cfg = self.load("ASR_ENGINE=remote\n")
        self.assertEqual((cfg.asr_engine, cfg.log_content, cfg.asr_allow_download), ("remote", True, True))

    def test_defaults_sit_below_config_env(self):
        self.managed_by(tp.minimal(defaults={"ASR_ENGINE": "auto", "LOG_RETENTION_DAYS": "30", "ASR_FALLBACK": "whisper"}))
        cfg = self.load("ASR_ENGINE=remote\nASR_FALLBACK=\n")
        self.assertEqual((cfg.asr_engine, cfg.log_retention_days, cfg.asr_fallback), ("remote", 30, "whisper"))     # config.env wins; empty = unset
        self.assertEqual(self.load("").asr_engine, "auto")

    def test_enforced_sits_above_config_env(self):
        self.managed_by(tp.minimal(enforced={"ASR_ENGINE": "whisper", "AUDIO_RETENTION_DAYS": "30", "LOG_CONTENT": "maybe"}))
        cfg = self.load("ASR_ENGINE=remote\nAUDIO_RETENTION_DAYS=0\nLOG_CONTENT=1\n")
        self.assertEqual((cfg.asr_engine, cfg.audio_retention_days, cfg.log_content), ("whisper", 30, False))   # junk switch text: the restrictive value
        self.assertEqual(cfg.config_warnings, ("LOG_CONTENT: unrecognised value 'maybe' is read as False",))

    def test_defaults_and_enforced_together(self):
        self.managed_by(tp.minimal(defaults={"ASR_ENGINE": "auto", "ASR_FALLBACK": "whisper"}, enforced={"ASR_ENGINE": "remote"}))
        cfg = self.load("")
        self.assertEqual((cfg.asr_engine, cfg.asr_fallback), ("remote", "whisper"))

    def test_company_baseline_is_enforced(self):
        self.managed_by(tp.company())
        cfg = self.load("LOG_CONTENT=1\nASR_ALLOW_DOWNLOAD=1\nMIC_MUTE_GATE=off\n")
        self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (False, False, "on"))
        self.managed_by(tp.company(enforced={"LOG_CONTENT": "1"}))
        self.assertTrue(self.load("LOG_CONTENT=0\n").log_content)                                  # overridden by naming the key
        self.managed_by(tp.minimal())
        self.assertTrue(self.load("").log_content)                                                  # personal profile: no baseline

    def test_a_locked_policy_keeps_the_company_baseline_configures_nothing_else_and_the_hooks_stay_off(self):
        self.managed_by(broken=True)                                                                # policy.json that is not valid JSON
        (self.root / "hook.env").write_text("SELF_NAME=Hooked\n")
        with mock.patch.dict(os.environ, {"MCAP_CONFIG": str(self.root / "hook.env")}):
            cfg = self.load("ASR_ENGINE=remote\nPROJECT_DIR=/x\n")
        self.assertEqual((cfg.asr_engine, cfg.self_name, cfg.project_dir), ("remote", "Me", Config().project_dir))
        # the lock closes the lanes AND keeps the privacy baseline: a damaged policy must not make the Mac more permissive than a valid one
        self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (False, False, "on"))
        cfg = self.load("LOG_CONTENT=1\nASR_ALLOW_DOWNLOAD=1\nMIC_MUTE_GATE=off\n")               # config.env cannot undo it either
        self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (False, False, "on"))

    def test_a_lock_applies_the_baseline_and_nothing_the_damaged_file_says(self):
        self.managed_by(tp.company(typo=1, defaults={"ASR_ENGINE": "auto", "LOG_RETENTION_DAYS": "30"},
                                   enforced={"LOG_CONTENT": "1", "AUDIO_RETENTION_DAYS": "30"}))
        cfg = self.load("")
        self.assertEqual((cfg.asr_engine, cfg.log_retention_days, cfg.audio_retention_days), ("whisper", 0, 0))      # its own layers are not trusted
        self.assertEqual((cfg.log_content, cfg.asr_allow_download), (False, False))

    def test_every_kind_of_lock_of_a_managed_mac_keeps_the_baseline(self):
        for label, kwargs in (("marker without a file", {"marker": True}), ("not json", {"broken": True}),
                              ("company, pipeline too old", {"doc": tp.company(min_pipeline_version="9.0.0")}),
                              ("company, bad value", {"doc": tp.company(recording={"enabled": 1})})):
            with self.subTest(label):
                self.managed_by(**kwargs)
                cfg = self.load("")
                self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (False, False, "on"))

    def test_a_locked_policy_that_positively_says_personal_changes_no_setting(self):
        self.managed_by(tp.minimal(typo=1, enforced={"LOG_CONTENT": "0"}))                          # personal: no baseline, and its own layer is not trusted
        cfg = self.load("")
        self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (True, True, "off"))
        self.managed_by(tp.minimal(min_pipeline_version="9.0.0"))
        self.assertEqual((self.load("").log_content, self.load("").asr_allow_download), (True, True))

    def test_no_policy_at_all_still_changes_no_setting(self):
        cfg = self.load("")                                                                         # no policy.json, no marker: the personal install
        self.assertEqual((cfg.log_content, cfg.asr_allow_download, cfg.mic_mute_gate), (True, True, "off"))

    def test_the_layers_by_state_of_the_policy(self):
        valid = SimpleNamespace(valid=True, locked=False, defaults={"A": "1"}, enforced={"C": "3"})
        locked = SimpleNamespace(valid=False, locked=True, defaults={"A": "1"}, enforced={"C": "3"})
        absent = SimpleNamespace(valid=False, locked=False, defaults={}, enforced={})
        values = {"B": "2", "A": ""}
        self.assertEqual(config._apply_policy_layers(values, valid), {"A": "1", "B": "2", "C": "3"})
        self.assertEqual(config._apply_policy_layers(values, locked), {"B": "2", "C": "3"})        # a lock enforces; it supplies no defaults
        self.assertEqual(config._apply_policy_layers(values, absent), {"B": "2"})
        self.assertEqual(config._apply_policy_layers(values, None), {"B": "2"})
        self.assertEqual(config._apply_policy_layers(values, SimpleNamespace()), {"B": "2"})

    def test_marker_without_a_policy_file_is_a_lock_too(self):
        self.managed_by(marker=True)
        cfg = self.load("SUPPORT_DIR=/elsewhere\nASR_ENGINE=remote\n")
        self.assertEqual((cfg.support_dir, cfg.asr_engine), (Config().support_dir, "remote"))

    def test_company_runtime_root_fixes_project_and_python(self):
        root = "/Library/Application Support/MeetingCapture/releases"
        self.managed_by(tp.company(runtime={"root": root}))
        cfg = self.load(f"PROJECT_DIR={self.root}/mine\nPYTHON_BIN={self.root}/mypy\n")
        self.assertEqual(cfg.project_dir, Path(root) / "current")
        self.assertEqual(cfg.python_bin, Path(root) / "current" / "venv" / "bin" / "python")
        self.managed_by(tp.minimal(runtime={"root": root}))                                         # personal: no runtime root
        cfg = self.load(f"PROJECT_DIR={self.root}/mine\n")
        self.assertEqual(cfg.project_dir, Config().project_dir)                                     # the managed Mac ignores the key, nothing replaces it

    def test_runtime_root_also_works_for_the_test_override_policy(self):
        """MCAP_POLICY_PATH (no system policy on this Mac) is read through the same loader."""
        other = self.root / "ov" / "policy.json"
        other.parent.mkdir()
        other.write_text(json.dumps(tp.company(defaults={"ASR_ENGINE": "auto"})))
        real = policy.load_org_policy
        fake = tp.make_stat_fn(other)
        with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": str(other)}), \
                mock.patch.object(policy, "load_org_policy", lambda path=None, **kw: real(path, stat_fn=fake, current_version="0.2.0", sleep=lambda s: None)):
            cfg = self.load("")
        self.assertEqual((cfg.policy_path, cfg.asr_engine, cfg.log_content), (other, "auto", False))

    def test_layers_pass_through_the_config_parser(self):
        self.managed_by(tp.minimal(enforced={"ASR_REMOTE_CA_FILE": "~/ca.pem", "ASR_AZURE_REGION": "KoreaCentral", "APP_LOG_MAX_MB": "5"}))
        cfg = self.load("")
        self.assertEqual((cfg.asr_remote_ca_file, cfg.asr_azure_region, cfg.app_log_max_mb), (Path.home() / "ca.pem", "koreacentral", 5))

    def test_layer_keys_the_swift_app_alone_reads_do_not_break_python(self):
        self.managed_by(tp.minimal(enforced={"NOTIFY_RECORDING": "1", "ENABLED_PLATFORMS": "zoom"}))
        cfg = self.load("")
        self.assertEqual(cfg, Config(policy_path=self.sys_policy))


# ---------------------------------------------------------------------------------------------------- derived paths
class DerivedPathTests(unittest.TestCase):
    def test_paths_under_support_dir(self):
        cfg = Config(support_dir=Path("/s"))
        self.assertEqual((cfg.consent_path, cfg.capability_path, cfg.asr_usage_path, cfg.session_private_dir),
                         (Path("/s/asr-consent.json"), Path("/s/asr-capability.json"), Path("/s/asr-usage.jsonl"), Path("/s/session-private")))
        self.assertEqual(cfg.local_archive_root, Path("/s/local-meetings"))
        self.assertEqual(dataclasses.replace(cfg, local_archive_dir=Path("/x/y")).local_archive_root, Path("/x/y"))
        self.assertEqual(Config().local_archive_root, Config().support_dir / "local-meetings")

    def test_replace_keeps_the_decision_slot_out_of_equality(self):
        cfg = Config()
        token = object()
        copy = dataclasses.replace(cfg, asr_decision=token)
        self.assertIs(copy.asr_decision, token)
        self.assertEqual(copy, cfg)
        self.assertIsNone(cfg.asr_decision)

    def test_no_new_field_changes_an_old_default(self):
        """The defaults of the public release (neutral label, extra-usage guard on) and the ones that never changed."""
        cfg = Config()
        for field, value in (("asr_model", "mlx-community/whisper-large-v3-mlx"), ("claude_auth", "api"), ("audio_retention_days", 0),
                             ("transcript_cleanup", True), ("note_verify", True), ("self_name", "Me"), ("asr_languages", "ko,en"),
                             ("calendar_lookup", "auto"), ("note_stop_on_overage", True)):
            self.assertEqual(getattr(cfg, field), value, field)
        self.assertTrue(math.isclose(cfg.claude_daily_budget_usd, 5.0))
        self.assertTrue(math.isclose(cfg.claude_meeting_budget_usd, 2.0))


if __name__ == "__main__":
    unittest.main()
