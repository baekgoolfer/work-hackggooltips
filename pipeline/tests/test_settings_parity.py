"""The Settings window (app/Sources/Settings*.swift) and the pipeline must agree.

Nothing here starts the app. It reads the Swift sources as text and runs the Python side against the same fixtures as the Swift self test
(`<short name> selftest-session`, section S-ST-01), so that neither side can change without one of the two failing:

  * every config.env key the window edits is a key a parser knows (config.py `_KEYS`, or a Swift-only key of Config.swift / Policy.swift), is documented in
    docs/CONFIGURATION.md and docs/SETTINGS.md, is in config/config.env.example, and the defaults and the word lists agree;
  * what the window writes into config.env is read by the Python parser as intended (the shared corpus fixtures/settings_parity.json: parsing, exact
    writer output, and the host / port of a cloud engine's address, `asr_providers.split_base`);
  * what the window writes into the Keychain is what Python reads (the command of `security -i` is run against the fake security tool of the gcal tests and
    read back by apikey.lookup / asr_creds.KeychainSource, with the same service and account strings);
  * the words of the pipeline's answers that the window interprets (api-key check, gcal status, asr-engines list --json) are still those words;
  * no secret is a config key, and the window's sources never name the consent file or the Google token.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gcal_support import FakeKeychain

from mcap import apikey, asr_creds, asr_openai_compat, asr_providers, config, gcal, usage

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "pipeline" / "tests" / "fixtures" / "settings_parity.json"


def read(rel: str) -> str:
    return (REPO / rel).read_text(encoding="utf-8")


def catalog() -> list:
    """(key, default, choice words or None) of every SettingsField in SettingsModel.swift, read from the source."""
    swift = read("app/Sources/SettingsModel.swift")
    rows = []
    for m in re.finditer(r'SettingsField\(key: "([A-Z0-9_]+)", tab: \.(\w+), kind: (.*?), defaultValue: "([^"]*)", reader: \.(\w+),', swift):
        key, tab, kind, default, reader = m.groups()
        words = re.search(r"\.choice\(\[([^\]]*)\]\)", kind)
        rows.append({"key": key, "tab": tab, "kind": kind, "default": default, "reader": reader,
                     "words": [w.strip().strip('"') for w in words.group(1).split(",")] if words else None})
    return rows


FIELDS = catalog()
KEYS = [f["key"] for f in FIELDS]


class CatalogTests(unittest.TestCase):
    def test_the_catalog_is_the_twenty_keys_of_the_five_tabs(self):
        self.assertEqual(len(KEYS), 20)
        self.assertEqual(len(set(KEYS)), 20)
        tabs = {}
        for f in FIELDS:
            tabs.setdefault(f["tab"], []).append(f["key"])
        self.assertEqual(tabs, {
            "general": ["UI_LANGUAGE", "ARCHIVE_DIR", "SELF_NAME"],
            "claude": ["CLAUDE_AUTH", "NOTE_MODEL", "CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD"],
            "transcription": ["ASR_ENGINE", "ASR_STRATEGY", "ASR_CLOVA_INVOKE_URL", "ASR_OPENAI_COMPAT_URL", "ASR_OPENAI_COMPAT_MODEL"],
            "detection": ["ENABLED_PLATFORMS", "CALL_DETECT", "CALL_BROWSER_URLS", "EXTRA_MEETING_APPS", "OFFLINE_AUTOSTART"],
            "privacy": ["LOCAL_ONLY_DEFAULT", "NOTIFY_RECORDING", "LOG_CONTENT"]})

    def test_no_key_is_a_secret(self):
        for key in KEYS:
            self.assertFalse(re.search(r"API_KEY|TOKEN|SECRET|PASSWORD|_KEY$", key), key)
        self.assertNotIn("CLAUDE_KEY_SERVICE", KEYS)

    def test_every_key_is_a_key_a_parser_knows(self):
        swift = read("app/Sources/Config.swift") + read("app/Sources/Policy.swift")
        python_keys = set(config._KEYS)
        for key in KEYS:
            self.assertTrue(key in python_keys or f'"{key}"' in swift, f"{key} is parsed by neither config.py nor Config.swift / Policy.swift")

    def test_the_keys_that_only_the_app_reads_are_not_in_python_and_the_pipeline_keys_are(self):
        for f in FIELDS:
            in_python = f["key"] in config._KEYS
            if f["reader"] == "pipeline":
                self.assertTrue(in_python, f"{f['key']} is marked as read by the pipeline but config.py does not parse it")
            if f["reader"] == "app":
                self.assertFalse(in_python, f"{f['key']} is marked app-only but config.py parses it")

    def test_every_key_is_documented_in_configuration_example_and_settings_docs(self):
        doc = read("docs/CONFIGURATION.md")
        example = read("config/config.env.example")
        settings = read("docs/SETTINGS.md")
        for key in KEYS:
            self.assertRegex(doc, rf"(?m)^\| `{key}` \|", f"{key} has no row in docs/CONFIGURATION.md")
            self.assertRegex(example, rf"(?m)^#? ?{key}=", f"{key} is not in config/config.env.example")
            self.assertIn(f"`{key}`", settings, f"{key} is not explained in docs/SETTINGS.md")

    def test_the_defaults_are_the_documented_and_the_coded_defaults(self):
        doc = read("docs/CONFIGURATION.md").split("## Settings (`config.env`)", 1)[-1].split("\n## ", 1)[0]       # the table of the keys, not the one of the folders
        cfg = config.Config()
        expected_python = {"CLAUDE_AUTH": cfg.claude_auth, "NOTE_MODEL": cfg.note_model, "SELF_NAME": cfg.self_name, "ASR_STRATEGY": cfg.asr_strategy,
                           "ASR_OPENAI_COMPAT_MODEL": cfg.asr_openai_compat_model, "ASR_ENGINE": cfg.asr_engine,
                           "CLAUDE_DAILY_BUDGET_USD": f"{cfg.claude_daily_budget_usd:g}", "CLAUDE_MEETING_BUDGET_USD": f"{cfg.claude_meeting_budget_usd:g}",
                           "ASR_CLOVA_INVOKE_URL": cfg.asr_clova_invoke_url, "ASR_OPENAI_COMPAT_URL": cfg.asr_openai_compat_url}
        for f in FIELDS:
            row = re.search(rf"(?m)^\| `{f['key']}` \| (`[^`]*`|<[^|]*>)", doc)
            self.assertIsNotNone(row, f["key"])
            documented = row.group(1).strip("`")
            if documented.startswith("<"):
                documented = ""
            self.assertEqual(f["default"], documented, f"{f['key']}: the window's default differs from docs/CONFIGURATION.md")
            if f["key"] in expected_python:
                self.assertEqual(f["default"], str(expected_python[f["key"]]), f"{f['key']}: the window's default differs from config.py")

    def test_the_word_lists_are_the_parsers_word_lists(self):
        words = {f["key"]: f["words"] for f in FIELDS if f["words"]}
        self.assertEqual(sorted(words["CLAUDE_AUTH"]), sorted(apikey.MODES))
        self.assertEqual(sorted(words["ASR_STRATEGY"]), ["dual", "single"])
        self.assertEqual(sorted(words["CALL_DETECT"]), ["generic", "known", "off"])
        self.assertEqual(words["UI_LANGUAGE"], ["en", "ko"])
        self.assertIn("PrivacySettings.engineWords", next(f["kind"] for f in FIELDS if f["key"] == "ASR_ENGINE"))
        policy_swift = read("app/Sources/Policy.swift")
        engine_words = re.search(r"static let engineWords = \[([^\]]*)\]", policy_swift).group(1)
        self.assertEqual([w.strip().strip('"') for w in engine_words.split(",")], list(config._KEYS["ASR_ENGINE"][1].allowed))

    def test_what_the_window_writes_for_every_key_is_accepted_by_the_python_parser(self):
        samples = {"UI_LANGUAGE": "ko", "ARCHIVE_DIR": "~/Notes Archive", "SELF_NAME": "Sam", "CLAUDE_AUTH": "subscription", "NOTE_MODEL": "sonnet",
                   "CLAUDE_DAILY_BUDGET_USD": "7.5", "CLAUDE_MEETING_BUDGET_USD": "0", "ASR_ENGINE": "openai-compat", "ASR_STRATEGY": "single",
                   "ASR_CLOVA_INVOKE_URL": "https://clovaspeech-gw.ncloud.com/external/v1/abc/def", "ASR_OPENAI_COMPAT_URL": "https://api.example.com/v1",
                   "ASR_OPENAI_COMPAT_MODEL": "whisper-1", "ENABLED_PLATFORMS": "zoom,teams,meet", "CALL_DETECT": "generic", "CALL_BROWSER_URLS": "on",
                   "EXTRA_MEETING_APPS": "com.example.talk=Example Talk", "OFFLINE_AUTOSTART": "auto", "LOCAL_ONLY_DEFAULT": "true", "NOTIFY_RECORDING": "0",
                   "LOG_CONTENT": "no"}
        self.assertEqual(sorted(samples), sorted(KEYS), "this test has a sample for every key of the catalog")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.env"
            path.write_text("".join(f"{k}={v}\n" for k, v in samples.items()), encoding="utf-8")
            with mock.patch.dict(os.environ, {"MCAP_CONFIG": str(path)}):
                cfg = config.load_config(path)           # raises ValueError for a value the pipeline cannot read
        self.assertEqual((cfg.claude_auth, cfg.note_model, cfg.claude_daily_budget_usd, cfg.claude_meeting_budget_usd), ("subscription", "sonnet", 7.5, 0.0))
        self.assertEqual((cfg.asr_engine, cfg.asr_strategy, cfg.asr_openai_compat_model, cfg.self_name), ("openai-compat", "single", "whisper-1", "Sam"))
        self.assertEqual((cfg.local_only_default, cfg.log_content), (True, False))
        self.assertEqual(cfg.asr_clova_invoke_url, samples["ASR_CLOVA_INVOKE_URL"])


class CorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_destinations_are_read_like_split_base(self):
        for row in self.corpus["destinations"]:
            suffixes = asr_providers.CLOVA_HOST_SUFFIXES if row["engine"] == "clova" else ()
            if "error" in row:
                with self.assertRaises(ValueError, msg=row["url"]) as cm:
                    asr_providers.split_base(row["url"], suffixes)
                self.assertEqual(str(cm.exception), row["error"], row["url"])
            else:
                self.assertEqual(asr_providers.split_base(row["url"], suffixes), (row["host"], row["port"], row["path"]), row["url"])
        self.assertGreaterEqual(len(self.corpus["destinations"]), 30)

    def test_the_keychain_account_of_every_good_address_is_user_at_host_port(self):
        for row in self.corpus["destinations"]:
            if "error" not in row:
                with mock.patch.dict(os.environ, {"USER": "tester"}):
                    self.assertEqual(asr_creds.account_name(row["host"], row["port"]), f"tester@{row['host']}:{row['port']}")

    def test_env_parse_cases_are_read_as_the_corpus_says(self):
        for row in self.corpus["env_parse"]:
            self.assertEqual(config.parse_env_text(row["text"]), row["expect"], repr(row["text"]))

    def test_writer_results_read_back_as_the_change_says(self):
        for row in self.corpus["writer"]:
            expected = config.parse_env_text(row["text"])
            for key, value in row["changes"].items():
                if value is None:
                    expected.pop(key, None)
                else:
                    expected[key] = value
            self.assertEqual(config.parse_env_text(row["result"]), expected, row["name"])

    def python_reading(self, key: str, text: str) -> str:
        """What the pipeline makes of `KEY=text` in config.env, in the words of the corpus `reads_as` rows."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.env"
            path.write_text(f"{key}={text}\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {"MCAP_CONFIG": str(path)}):
                try:
                    cfg = config.load_config(path)
                except ValueError:
                    return "refuses-to-run"
        if key in ("LOCAL_ONLY_DEFAULT", "LOG_CONTENT"):
            return "1" if getattr(cfg, key.lower()) else "0"
        if key == "CLAUDE_AUTH":
            return "no-claude-call" if apikey.mode_problem(cfg) else apikey.mode(cfg)
        if key == "ASR_STRATEGY":
            return cfg.asr_strategy
        if key in ("CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD"):
            return f"limit-{usage._limit(getattr(cfg, key.lower())):g}"
        raise AssertionError(key)

    def test_a_stored_text_the_window_does_not_understand_is_read_as_the_corpus_says(self):
        """The window shows what the code reads for a typo (the Swift self test checks `shown`/`problem` against the same rows): not always the default."""
        rows = self.corpus["reads_as"]
        self.assertGreaterEqual(len(rows), 10)
        for row in rows:
            self.assertEqual(self.python_reading(row["key"], row["text"]), row["python"], f"{row['key']}={row['text']!r}")

    def test_the_window_accepts_a_model_name_only_when_the_pipeline_does(self):
        for row in self.corpus["model_names"]:
            self.assertEqual(asr_openai_compat._MODEL.fullmatch(row["text"]) is not None, row["python"], repr(row["text"]))
            self.assertTrue(row["python"] or not row["window"], f"the window must never accept {row['text']!r}: the pipeline refuses it")
            if row["python"] and "\n" not in row["text"]:
                with tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "config.env"
                    path.write_text(f"ASR_OPENAI_COMPAT_MODEL={row['text']}\n", encoding="utf-8")
                    cfg = config.load_config(path)
                self.assertEqual(asr_openai_compat._MODEL.fullmatch(cfg.asr_openai_compat_model) is not None, True)

    def test_the_writer_keeps_every_untouched_line_byte_for_byte(self):
        for row in self.corpus["writer"]:
            keys = set(row["changes"])
            kept = [line for line in row["text"].splitlines(keepends=True)
                    if not (re.match(r"\s*([A-Z0-9_]+)\s*=", line) and re.match(r"\s*([A-Z0-9_]+)\s*=", line).group(1) in keys)]
            for line in kept:
                self.assertIn(line, row["result"], f"{row['name']}: {line!r} was not kept")


class KeychainParityTests(unittest.TestCase):
    """The Swift side writes `add-generic-password -U -a "<account>" -s "<service>" -X <hex>` to `security -i` (SettingsKeychain.addCommand; the Swift self test
    pins the exact string). Here the same string goes to the fake tool of the gcal tests and Python reads the item with its own code."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.keychain = FakeKeychain(Path(self.tmp.name) / "kc")
        patcher = mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.keychain.path), "USER": "tester"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(apikey._known.clear)

    def swift_command(self, service: str, account: str, secret: str) -> str:
        return f'add-generic-password -U -a "{account}" -s "{service}" -X {secret.encode("utf-8").hex()}\n'

    def store(self, service: str, account: str, secret: str) -> None:
        done = subprocess.run([str(self.keychain.path), "-i"], input=self.swift_command(service, account, secret).encode("utf-8"), capture_output=True, timeout=20)
        self.assertEqual(done.returncode, 0)

    def test_python_reads_the_anthropic_key_the_window_stores(self):
        key = "sk-ant-api03-" + "PARITY" * 6
        self.store("MeetingCapture Anthropic API key", "tester", key)
        cfg = config.Config()
        self.assertEqual(apikey.keychain_service(cfg), "MeetingCapture Anthropic API key")
        self.assertEqual(apikey.keychain_account(), "tester")
        self.assertEqual(apikey.read_key(cfg), key)
        st = apikey.key_status(cfg)
        self.assertTrue(st.present and st.prefix_ok)

    def test_python_reads_the_anthropic_key_under_a_custom_service(self):
        self.store("Custom Service", "tester", "sk-ant-api03-custom-" + "x" * 20)
        cfg = config.Config(claude_key_service="Custom Service")
        self.assertTrue(apikey.read_key(cfg).startswith("sk-ant-api03-custom-"))

    def test_python_reads_an_engine_key_stored_for_the_host_of_the_saved_address(self):
        host, port, _path = asr_providers.split_base("https://clovaspeech-gw.ncloud.com/external/v1/abc/def", asr_providers.CLOVA_HOST_SUFFIXES)
        self.store("MeetingCapture ASR clova", f"tester@{host}:{port}", "ENGINEKEY-" + "Q" * 30)
        self.assertEqual(asr_creds.service_name("clova"), "MeetingCapture ASR clova")
        self.assertEqual(asr_creds.KeychainSource().read("clova", host, port), "ENGINEKEY-" + "Q" * 30)
        self.assertTrue(asr_creds.secret_status("clova", host, port)["present"])
        with self.assertRaises(asr_creds.CredentialUnavailable):                 # bound to the host: another address finds nothing
            asr_creds.KeychainSource().read("clova", "other.ncloud.com", port)

    def test_python_reads_an_openai_compatible_key_with_its_port(self):
        host, port, _path = asr_providers.split_base("https://llm.example.org:8443/v1")
        self.assertEqual((host, port), ("llm.example.org", 8443))
        self.store("MeetingCapture ASR openai-compat", f"tester@{host}:{port}", "KEY-" + "z" * 24)
        self.assertEqual(asr_creds.KeychainSource().read("openai-compat", host, port), "KEY-" + "z" * 24)

    def test_the_same_item_is_updated_not_duplicated(self):
        self.store("MeetingCapture Anthropic API key", "tester", "sk-ant-api03-first-" + "a" * 20)
        self.store("MeetingCapture Anthropic API key", "tester", "sk-ant-api03-second-" + "b" * 20)
        self.assertEqual(len(self.keychain.items()), 1)
        self.assertTrue(apikey.read_key(config.Config()).startswith("sk-ant-api03-second-"))

    def test_the_swift_command_has_exactly_the_shape_of_the_python_writer(self):
        swift = read("app/Sources/SettingsKeychain.swift")
        self.assertIn('"add-generic-password -U -a \\"\\(item.account)\\" -s \\"\\(item.service)\\" -X \\(hex)\\n"', swift)
        gcal_src = read("pipeline/mcap/gcal.py")
        self.assertIn("command = f'add-generic-password -U -a \"{account}\" -s \"{TOKEN_SERVICE}\" -X {blob.encode(\"utf-8\").hex()}\\n'", gcal_src)
        self.assertIn('[apikey.security_bin(), "-i"]', gcal_src)


class WordsOfThePipelineTests(unittest.TestCase):
    """The window shows what the pipeline answers by its words; when the words change the window must change with them."""

    def test_api_key_check_says_ok_or_failed_in_the_words_the_window_reads(self):
        cli_src = read("pipeline/mcap/cli.py")
        self.assertIn('print("API key OK")', cli_src)
        self.assertIn('print(f"FAILED: {apikey.redact(res.message)}", file=sys.stderr)', cli_src)
        swift = read("app/Sources/SettingsBackend.swift")
        self.assertIn('hasPrefix("API key OK")', swift)
        self.assertIn('hasPrefix("FAILED:")', swift)

    def test_gcal_status_lines_carry_the_words_the_window_reads(self):
        from gcal_support import GcalCase

        class Probe(GcalCase):
            def runTest(self):
                pass

        case = Probe()
        case.setUp()
        try:
            lines, ready = gcal.status_lines(case.cfg, clock=lambda: case.now)
            text = "\n".join(line.strip() for line in lines)
            self.assertTrue(ready, text)
            self.assertIn("OAuth client file:", text)
            self.assertNotIn("NOT usable", text)
            self.assertRegex(text, r"token:\s+in the Keychain")
            self.assertIn("organisation lane: allowed", text)
            case.keychain.clear()
            lines, ready = gcal.status_lines(case.cfg, clock=lambda: case.now)
            self.assertFalse(ready)
            self.assertRegex("\n".join(line.strip() for line in lines), r"token:\s+NOT available")
            case.write_client({"bogus": True})
            lines, _ready = gcal.status_lines(case.cfg, clock=lambda: case.now)
            self.assertRegex("\n".join(line.strip() for line in lines), r"OAuth client file: NOT usable")
        finally:
            case.doCleanups()
        gcal_src = read("pipeline/mcap/gcal.py")
        self.assertIn('print("ready" if ready else "not ready: see docs/CALENDAR_AUTOSTART.md")', gcal_src)
        self.assertIn("DENIED (", gcal_src)
        swift = read("app/Sources/SettingsBackend.swift")
        for word in ('lines.last == "ready"', "NOT usable", "NOT available", "DENIED"):
            self.assertIn(word, swift)

    def test_engine_rows_have_the_fields_and_consent_words_the_window_reads(self):
        from test_cli_asr import CliAsrCase

        class Probe(CliAsrCase):
            def runTest(self):
                pass

        case = Probe()
        case.setUp()
        try:
            case.write_config(ASR_CLOVA_INVOKE_URL="https://clovaspeech-gw.ncloud.com/external/v1/abc/def")
            code, out, _err = case.mcap("asr-engines", "list", "--json")
            self.assertEqual(code, 0)
            doc = json.loads(out)
            rows = {r["engine"]: r for r in doc["engines"]}
            self.assertEqual(doc["schema"], 1)
            for engine in ("whisper", "clova", "openai-compat", "azure", "remote"):
                self.assertIn(engine, rows)
                self.assertTrue({"engine", "consent", "credential"} <= set(rows[engine]), engine)
            self.assertEqual(rows["clova"]["consent"], "no-consent")
            self.assertEqual(rows["whisper"]["consent"], "not needed")
            self.assertEqual(rows["openai-compat"]["consent"], "not-configured")
        finally:
            case.doCleanups()
        swift = read("app/Sources/SettingsBackend.swift")
        for word in ('hasPrefix("ok")', '"no-consent"', '"consent-expired"', '"consent-mismatch"', '"consent-tampered"', '"not-configured"', '"bad-host"', '"not needed"'):
            self.assertIn(word, swift)
        self.assertIn('row["consent"] = state["state"] + (f" (until {state[\'expires\']})" if state["state"] == "ok" else "")', read("pipeline/mcap/cli.py"))

    def test_the_commands_the_window_runs_exist(self):
        cli_src = read("pipeline/mcap/cli.py")
        for command in ('add_parser("api-key"', 'add_parser("gcal"', 'add_parser("asr-engines"', 'a = asub.add_parser("list"', 'a = asub.add_parser("consent"'):
            self.assertIn(command, cli_src)
        swift = read("app/Sources/SettingsBackend.swift")
        for arguments in ('["-m", "mcap", "api-key", "check"]', '["-m", "mcap", "gcal", "status"]', '["-m", "mcap", "asr-engines", "list", "--json"]',
                          '["-m", "mcap", "asr-engines", "consent", engine]', '["-m", "mcap", "gcal", "auth"]'):
            self.assertIn(arguments, swift)


class WindowSourcesTests(unittest.TestCase):
    OWN = ("SettingsModel", "SettingsConfigWriter", "SettingsKeychain", "SettingsBackend", "SettingsWindow")

    def test_the_window_never_names_the_consent_file_or_the_google_token(self):
        for name in self.OWN:
            text = read(f"app/Sources/{name}.swift")
            for forbidden in ("asr-consent", "consent_path", "write_consent", "TOKEN_SERVICE", "Google Calendar token"):
                self.assertNotIn(forbidden, text, f"{name}.swift names {forbidden}")

    def test_a_key_is_never_passed_in_an_argument_or_written_to_a_file_by_the_keychain_code(self):
        text = read("app/Sources/SettingsKeychain.swift")
        self.assertIn('run(["-i"], Data(command.utf8), false)', text)
        for forbidden in ("-w \\(", "write(to:", "setenv", "environment[\"ANTHROPIC", "print(", "Log."):
            self.assertNotIn(forbidden, text, forbidden)

    def test_config_env_is_written_only_by_the_editor_and_writer(self):
        for name in ("SettingsModel", "SettingsKeychain", "SettingsWindow"):
            text = read(f"app/Sources/{name}.swift")
            for forbidden in ("write(to:", "createFile", "removeItem", "moveItem"):
                self.assertNotIn(forbidden, text, f"{name}.swift: {forbidden}")


if __name__ == "__main__":
    unittest.main()
