"""apikey.py (SPEC 17): the billing-mode helpers, the Keychain access through the FAKE `security` tool of notes_cli_support (the real
Keychain is never touched, no real key exists: the only key is the CANARY), `api-key set` (terminal only, no key through us),
`forget`, and the redaction (sk-ant shapes, the exact key, logging, state.json, usage.jsonl)."""
import io
import logging
import os
import subprocess
import sys
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from notes_cli_support import CANARY, ODD_CANARY, TempCase, canary_hits, make_cfg

from mcap import apikey, state, usage
from mcap.config import Config


class TtyInput(io.StringIO):
    def isatty(self):
        return True


class ModeTests(unittest.TestCase):
    def test_mode_is_normalised_and_defaults_to_api(self):
        self.assertEqual(apikey.mode(Config()), "api")                                # the Console key is the supported path; subscription is opt-in
        self.assertEqual(apikey.mode(Config(claude_auth=" API ")), "api")
        self.assertEqual(apikey.mode(Config(claude_auth="Subscription")), "subscription")
        self.assertEqual(apikey.mode(Config(claude_auth="")), "api")                  # an empty value is the default
        self.assertEqual(apikey.mode(mock.Mock()), "subscription")                    # a test double without the setting
        self.assertTrue(apikey.is_api(Config(claude_auth="api")))
        self.assertTrue(apikey.is_api(Config()))
        self.assertFalse(apikey.is_api(Config(claude_auth="subscription")))

    def test_a_misspelt_mode_is_a_problem_not_a_silent_choice(self):
        self.assertIsNone(apikey.mode_problem(Config()))
        self.assertIsNone(apikey.mode_problem(Config(claude_auth="api")))
        for bad in ("apikey", "api-key", "pay-as-you-go", "yes"):
            problem = apikey.mode_problem(Config(claude_auth=bad))
            self.assertIn("CLAUDE_AUTH must be 'subscription' or 'api'", problem)
            self.assertIn(bad, problem)
            self.assertFalse(apikey.is_api(Config(claude_auth=bad)))                  # never api by accident

    def test_config_has_the_spec_17_defaults_and_keys(self):
        cfg = Config()
        self.assertEqual((cfg.claude_auth, cfg.claude_key_service, cfg.claude_daily_budget_usd, cfg.claude_meeting_budget_usd),
                         ("api", "MeetingCapture Anthropic API key", 5.0, 2.0))
        self.assertEqual(apikey.DEFAULT_SERVICE, cfg.claude_key_service)


class LookupTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def test_the_default_security_tool_is_the_system_one_and_the_env_overrides_it(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SECURITY_BIN", None)
            self.assertEqual(apikey.security_bin(), "/usr/bin/security")
        self.assertEqual(apikey.security_bin(), str(self.security.path))              # TempCase selects the fake

    def test_read_key_asks_with_the_exact_argv_and_strips_the_newline(self):
        self.security.store()
        self.assertEqual(apikey.read_key(self.cfg), CANARY)
        self.assertEqual(self.security.argvs(), [["find-generic-password", "-s", "MeetingCapture Anthropic API key",
                                                  "-a", apikey.keychain_account(), "-w"]])

    def test_the_lookup_result_never_prints_the_key_in_str_repr_or_an_f_string(self):
        # review finding: the dataclass repr used to show `key='sk-ant-...'`, one careless `log.debug("%s", found)` away from a leak
        self.security.store()
        found = apikey.lookup(self.cfg)
        self.assertEqual(found.key, CANARY)                                             # the value is still there for the caller
        for text in (repr(found), str(found), f"{found}", "%s %r" % (found, found), repr([found]), repr({"k": found})):
            self.assertNotIn("CANARY", text)
            self.assertNotIn("sk-ant-", text)
        self.assertIn("reason='ok'", repr(found))
        self.assertNotIn("CANARY", repr(apikey.key_status(self.cfg)))

    def test_the_service_name_comes_from_the_config(self):
        self.cfg.claude_key_service = "Another service"
        self.security.store(service="Another service")
        self.assertEqual(apikey.read_key(self.cfg), CANARY)
        self.assertEqual(apikey.read_key(make_cfg(self.root)), None)                   # the default service has no item

    def test_the_tool_stderr_is_discarded_and_stdin_is_closed(self):
        self.security.store()
        real = subprocess.run
        seen = {}

        def spy(argv, **kw):
            seen.update(kw)
            return real(argv, **kw)

        with mock.patch("mcap.apikey.subprocess.run", spy):
            apikey.read_key(self.cfg)
        self.assertIs(seen["stderr"], subprocess.DEVNULL)
        self.assertIs(seen["stdin"], subprocess.DEVNULL)
        self.assertEqual(set(seen["env"]), {"HOME", "USER", "PATH", "LANG"})            # the tool gets no other variable
        self.assertGreater(seen["timeout"], 0)

    def test_a_missing_item_is_none_with_the_fix_in_the_message(self):
        self.assertIsNone(apikey.read_key(self.cfg))
        self.assertEqual(apikey.lookup(self.cfg).reason, "missing")
        self.assertEqual(apikey.usable_key(self.cfg), (None, "API key not found in the Keychain: run make set-api-key"))

    def test_item_exists_asks_without_w_and_g_so_the_secret_is_never_read(self):
        # the app installer's helper only needs to know whether a key is stored: attributes only, no value, no access-list check (no Keychain dialog)
        self.security.store()
        self.assertIs(apikey.item_exists(self.cfg), True)
        self.assertEqual(self.security.argvs("find-generic-password"),
                         [["find-generic-password", "-s", apikey.DEFAULT_SERVICE, "-a", apikey.keychain_account()]])
        self.assertEqual(self.security.reads(), 0)                                    # no -w: the key was not asked for
        self.assertNotIn("-g", self.security.argvs("find-generic-password")[0])
        self.security.remove()
        self.assertIs(apikey.item_exists(self.cfg), False)                            # exit 44: no item
        self.assertEqual(self.security.reads(), 0)
        self.assertEqual(apikey.read_key(self.cfg), None)                             # (the value lookup still exists and does use -w)
        self.assertEqual(self.security.reads(), 1)

    def test_item_exists_is_none_when_nobody_can_answer(self):
        self.security.store()
        self.security.set_mode("deny")
        self.assertIsNone(apikey.item_exists(self.cfg))                               # exit 36: neither yes nor no
        self.security.set_mode("timeout")
        with mock.patch.object(apikey, "READ_TIMEOUT_S", 0.5):
            self.assertIsNone(apikey.item_exists(self.cfg))
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "no-such-security")}):
            self.assertIsNone(apikey.item_exists(self.cfg))
        self.assertEqual(self.security.reads(), 0)

    def test_item_exists_uses_the_service_of_the_config(self):
        self.security.store(service="Other service")
        self.assertIs(apikey.item_exists(make_cfg(self.root, claude_key_service="Other service")), True)
        self.assertIs(apikey.item_exists(self.cfg), False)

    def test_an_unusable_tool_is_none_too(self):
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "no-such-security")}):
            self.assertEqual(apikey.lookup(self.cfg).reason, "no_tool")
            self.assertEqual(apikey.usable_key(self.cfg)[1], apikey.NOT_FOUND_MESSAGE)

    def test_a_tool_that_never_answers_times_out_with_a_hint(self):
        self.security.store()
        self.security.set_mode("timeout")
        with mock.patch.object(apikey, "READ_TIMEOUT_S", 0.5):
            t0 = time.monotonic()
            found = apikey.lookup(self.cfg)
            message = apikey.usable_key(self.cfg)[1]
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual((found.key, found.reason), (None, "timeout"))
        self.assertIn("did not answer", message)
        self.assertIn("api-key status", message)

    def test_a_denied_keychain_is_an_error_not_a_missing_key(self):
        self.security.store()
        self.security.set_mode("deny")
        found = apikey.lookup(self.cfg)
        self.assertEqual((found.key, found.reason, found.detail), (None, "error", "security exit 36"))
        self.assertIn("could not be read", apikey.usable_key(self.cfg)[1])

    def test_only_something_shaped_like_an_anthropic_key_is_usable(self):
        self.security.store(CANARY)
        self.assertEqual(apikey.usable_key(self.cfg), (CANARY, ""))
        self.security.store(ODD_CANARY)
        self.assertEqual(apikey.usable_key(self.cfg), (None, apikey.BAD_SHAPE_MESSAGE))
        self.assertIn("sk-ant-", apikey.BAD_SHAPE_MESSAGE)

    def test_a_key_that_was_read_is_masked_everywhere_afterwards_even_without_the_sk_ant_shape(self):
        self.addCleanup(apikey._known.clear)
        self.security.store(ODD_CANARY)
        apikey.read_key(self.cfg)
        self.assertEqual(apikey.redact(f"the key was {ODD_CANARY}!"), "the key was sk-ant-***!")


class StatusTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def test_status_of_a_good_key_says_present_prefix_length_and_never_the_value(self):
        self.security.store()
        st = apikey.key_status(self.cfg)
        self.assertTrue(st.present and st.prefix_ok and st.usable)
        self.assertEqual((st.length, st.service, st.account), (len(CANARY), "MeetingCapture Anthropic API key", apikey.keychain_account()))
        text = "\n".join(apikey.format_status(st)) + repr(st)
        self.assertNotIn("CANARY", text)
        self.assertIn(f"{len(CANARY)} characters", text)
        self.assertIn("validated: no", text)
        self.assertIn("mcap api-key check", text)

    def test_status_of_a_key_with_the_wrong_shape_and_of_no_key(self):
        self.security.store(ODD_CANARY)
        st = apikey.key_status(self.cfg)
        self.assertTrue(st.present)
        self.assertFalse(st.prefix_ok or st.usable)
        text = "\n".join(apikey.format_status(st))
        self.assertIn("does NOT start with sk-ant-", text)
        self.assertNotIn("canary_ODD", text)
        self.security.remove()
        st = apikey.key_status(self.cfg)
        self.assertFalse(st.present)
        self.assertIn("API key not found in the Keychain: run make set-api-key", "\n".join(apikey.format_status(st)))


class SetKeyTests(TempCase):
    """`mcap api-key set`: the macOS security tool prompts on the terminal; nothing about the key passes through this program."""

    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def run_set(self, tty: bool):
        out, err = io.StringIO(), io.StringIO()
        stdin = TtyInput() if tty else io.StringIO()
        with mock.patch.object(sys, "stdin", stdin), redirect_stdout(out), redirect_stderr(err):
            rc = apikey.set_key_interactive(self.cfg)
        return rc, out.getvalue(), err.getvalue()

    def test_refused_without_a_terminal_and_the_tool_is_never_started(self):
        rc, out, err = self.run_set(tty=False)
        self.assertEqual(rc, 2)
        self.assertIn("must run in a terminal", err)
        self.assertIn("make set-api-key", err)
        self.assertEqual(self.security.calls(), [])
        with mock.patch.object(sys, "stdin", None), redirect_stderr(io.StringIO()):     # no stdin at all (a detached process)
            self.assertEqual(apikey.set_key_interactive(self.cfg), 2)

    def test_a_security_tool_override_is_announced_before_the_key_is_typed(self):
        # a leftover `export MCAP_SECURITY_BIN=<test shim>` in the shell would receive the real key: the user is told first
        self.security.store()
        rc, out, err = self.run_set(tty=True)                    # TempCase points MCAP_SECURITY_BIN at the fake: that IS an override
        self.assertEqual(rc, 0, err)
        self.assertIn("WARNING: $MCAP_SECURITY_BIN is set", err)
        self.assertIn(str(self.security.path), err)
        self.assertIn("unset MCAP_SECURITY_BIN", err)
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SECURITY_BIN")
            with mock.patch.object(apikey, "DEFAULT_SECURITY_BIN", str(self.security.path)):    # default tool = the fake: no override
                rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 0, err)
        self.assertNotIn("WARNING", err)

    def test_in_a_terminal_it_runs_the_exact_add_command_with_inherited_stdio_and_no_key_on_argv(self):
        self.security.store()                                    # the fake tool does not store: this is the item `-U` updates
        real = subprocess.run
        runs = []

        def spy(argv, **kw):
            runs.append((list(argv), kw))
            return real(argv, **kw)

        with mock.patch("mcap.apikey.subprocess.run", spy):
            rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 0, err)
        add_argv, add_kw = next(r for r in runs if r[0][1] == "add-generic-password")
        self.assertEqual(add_argv, [str(self.security.path), "add-generic-password", "-U", "-a", apikey.keychain_account(),
                                    "-s", "MeetingCapture Anthropic API key", "-w"])
        self.assertEqual(self.security.argvs("add-generic-password"), [add_argv[1:]])
        for stream in ("stdin", "stdout", "stderr", "input", "capture_output"):
            self.assertNotIn(stream, add_kw, f"{stream} must be inherited from the terminal, not redirected")
        self.assertIn("Stored (", out)
        self.assertEqual(canary_hits(self.root, extra=(out, err, " ".join(add_argv))), [])

    def test_a_stored_value_with_the_wrong_shape_is_reported(self):
        self.security.store(ODD_CANARY)
        rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 0)
        self.assertIn("does not start with sk-ant-", err)
        self.assertEqual(canary_hits(self.root, extra=(out, err)), [])

    def test_the_tool_failing_or_storing_nothing_is_a_failure(self):
        self.security.set_add_exit(45)
        rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 1)
        self.assertIn("exited with 45", err)
        self.security.set_add_exit(0)                            # exit 0 but nothing can be read back (the fake stored nothing)
        rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 1)
        self.assertIn("cannot be read back", err)

    def test_a_missing_tool_is_reported(self):
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "gone")}):
            rc, out, err = self.run_set(tty=True)
        self.assertEqual(rc, 1)
        self.assertIn("cannot run", err)


class ForgetTests(TempCase):
    def test_forget_deletes_the_item_and_is_idempotent(self):
        cfg = make_cfg(self.root)
        self.security.store()
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(apikey.forget_key(cfg), 0)
            self.assertEqual(apikey.forget_key(cfg), 0)
        self.assertEqual(self.security.argvs("delete-generic-password")[0],
                         ["delete-generic-password", "-s", "MeetingCapture Anthropic API key", "-a", apikey.keychain_account()])
        self.assertIn("Deleted the Keychain item", out.getvalue())
        self.assertIn("Nothing to delete", out.getvalue())
        self.assertIsNone(apikey.read_key(cfg))


class RedactTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(apikey._known.clear)

    def test_every_sk_ant_token_is_masked(self):
        self.assertEqual(apikey.redact("Invalid API key sk-ant-api03-AbC_d-123 (x)"), "Invalid API key sk-ant-*** (x)")
        self.assertEqual(apikey.redact("a sk-ant-oat01-xyz b sk-ant-api03-q_9 c"), "a sk-ant-*** b sk-ant-*** c")
        self.assertEqual(apikey.redact(f"key={CANARY}"), "key=sk-ant-***")
        self.assertNotIn("CANARY", apikey.redact(f"{CANARY[:30]}...{CANARY}"))

    def test_text_without_a_key_and_non_strings_pass_through(self):
        self.assertEqual(apikey.redact("sk-ant- is only a prefix"), "sk-ant- is only a prefix")
        self.assertEqual(apikey.redact("nothing to hide"), "nothing to hide")
        self.assertEqual(apikey.redact(""), "")
        self.assertIsNone(apikey.redact(None))
        self.assertEqual(apikey.redact(42), 42)

    def test_masking_is_idempotent(self):
        once = apikey.redact(f"x {CANARY} y")
        self.assertEqual(apikey.redact(once), once)

    def test_the_exact_key_is_masked_even_without_the_prefix_and_short_values_are_not_registered(self):
        apikey.remember(ODD_CANARY)
        apikey.remember("short")
        self.assertEqual(apikey.redact(f"leak {ODD_CANARY} leak"), "leak sk-ant-*** leak")
        self.assertEqual(apikey.redact("a short word"), "a short word")

    def test_redact_obj_walks_nested_data(self):
        data = {"a": f"x {CANARY}", "b": [f"{CANARY}", {"c": f"y {CANARY}"}], "n": 3, "none": None}
        clean = apikey.redact_obj(data)
        self.assertNotIn("CANARY", repr(clean))
        self.assertEqual((clean["n"], clean["none"]), (3, None))


class LogFilterTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(apikey._known.clear)
        self.stream = io.StringIO()
        self.handler = logging.StreamHandler(self.stream)
        self.handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
        root = logging.getLogger()
        root.addHandler(self.handler)
        self.addCleanup(root.removeHandler, self.handler)
        old_level = root.level
        root.setLevel(logging.DEBUG)
        self.addCleanup(root.setLevel, old_level)
        apikey.install_log_redaction()

    def test_messages_arguments_and_tracebacks_of_every_mcap_logger_are_masked(self):
        log = logging.getLogger("mcap.note")
        log.warning("call failed with %s", CANARY)
        log.error("key=" + CANARY)
        try:
            raise RuntimeError("boom " + CANARY)
        except RuntimeError:
            log.exception("it crashed")
        late = logging.getLogger("mcap.created.after.install")           # a logger that did not exist when the filter was installed
        late.info("leak %s", CANARY)
        text = self.stream.getvalue()
        self.assertNotIn(CANARY[:24], text)                              # (not the word CANARY: a traceback shows this test's source line)
        self.assertGreaterEqual(text.count("sk-ant-***"), 4)
        self.assertIn("RuntimeError: boom sk-ant-***", text)             # the traceback is masked too

    def test_ordinary_messages_survive_unchanged_and_a_percent_sign_is_harmless(self):
        logging.getLogger("mcap.cli").info("done: %d call(s), 100%% sure", 3)
        logging.getLogger("mcap.cli").warning("plain 50% text")
        self.assertIn("INFO mcap.cli: done: 3 call(s), 100% sure", self.stream.getvalue())
        self.assertIn("WARNING mcap.cli: plain 50% text", self.stream.getvalue())

    def test_installing_twice_does_not_double_anything(self):
        apikey.install_log_redaction()
        logging.getLogger("mcap.usage").warning("x %s", CANARY)
        self.assertEqual(self.stream.getvalue().count("sk-ant-***"), 1)


class StoredFilesAreMaskedTests(TempCase):
    """What is written to state.json and usage.jsonl never carries a key shape."""

    def test_state_json_masks_error_warning_and_stage_detail(self):
        d = self.root / "session"
        d.mkdir()
        state.write_state(d, stage="failed", error=f"Claude said: invalid key {CANARY}", warning=f"w {CANARY}",
                          stage_detail=f"d {CANARY}", title=f"t {CANARY}", error_kind="auth")
        text = (d / "state.json").read_text(encoding="utf-8")
        self.assertNotIn("CANARY", text)
        self.assertIn("invalid key sk-ant-***", text)
        self.assertEqual(state.read_state(d)["error_kind"], "auth")                       # the rest is untouched

    def test_usage_jsonl_masks_every_string(self):
        cfg = make_cfg(self.root)
        usage.record(cfg, "note", models=[f"m-{CANARY}"], requested=f"r-{CANARY}", outcome=f"bad {CANARY}", session_id=f"s-{CANARY}")
        text = usage.usage_path(cfg).read_text(encoding="utf-8")
        self.assertNotIn("CANARY", text)
        self.assertIn("sk-ant-***", text)


if __name__ == "__main__":
    unittest.main()
