"""asr_creds.py: host-and-port-bound Keychain items through the FAKE `security` of notes_cli_support
(the real Keychain is never touched: every test either uses the fake shim or injects `run`), the policy rule for $MCAP_SECURITY_BIN, the
absolute /usr/bin/security, FileSource for the server tier, fixed error strings, nothing cached on disk."""
import io
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from net_guard_support import NoNetworkCase

from mcap import apikey, asr_creds, config
from mcap.asr_creds import CredentialUnavailable, FileSource, KeychainSource, account_name, secret, service_name

HOST = "asr.example.internal"
AZURE = "koreacentral.api.cognitive.microsoft.com"
TOKEN = "mcap1_0a1b2c3d_" + "Zq9xK" * 6 + "ab"                    # relay-token shaped: mcap1_<8 hex>_<32>
VENDOR_KEY = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"                     # an Azure-style hex key
PLAIN = "plain-relay-secret-CANARY-0123456789"                      # no shape at all: only exact masking can catch it


class TtyInput(io.StringIO):
    def isatty(self):
        return True


class FakeRun:
    """A stand-in for subprocess.run: records (argv, kwargs), answers rc/stdout, or raises."""

    def __init__(self, returncode=0, stdout=b"", exc=None, rcs=None):
        self.returncode, self.stdout, self.exc, self.rcs = returncode, stdout, exc, list(rcs or [])
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), kwargs))
        if self.exc is not None:
            raise self.exc
        code = self.rcs.pop(0) if self.rcs else self.returncode
        return subprocess.CompletedProcess(argv, code, stdout=self.stdout, stderr=b"")

    def argvs(self):
        return [argv for argv, _ in self.calls]


class CredsCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(apikey._known.clear)
        self.addCleanup(asr_creds.install_source)                 # back to the Keychain default whatever a test installed

    def managed(self):
        """This Mac has a system policy (the file exists: its content is not read by anything under test)."""
        self.system_policy(True)

    def store(self, value, engine="remote", host=HOST, port=443):
        self.security.store_item(value, service_name(engine), account_name(host, port))

    def read(self, engine="remote", host=HOST, port=443, **kw):
        with secret(engine, host, port, **kw) as value:
            return value

    def assertUnavailable(self, reason, *args, **kw):
        with self.assertRaises(CredentialUnavailable) as cm:
            self.read(*args, **kw)
        self.assertEqual(cm.exception.reason, reason)
        return cm.exception


# ======================================================================================================================
class NameTests(CredsCase):
    def test_the_service_and_the_account_carry_the_engine_the_host_and_the_port(self):
        self.assertEqual(service_name("remote"), "MeetingCapture ASR remote")
        self.assertEqual(service_name("azure"), "MeetingCapture ASR azure")
        self.assertEqual(account_name(HOST, 443), f"{apikey.keychain_account()}@{HOST}:443")
        # lower case: one name per host
        self.assertEqual(account_name("ASR.Example.Internal", 8443), f"{apikey.keychain_account()}@{HOST}:8443")

    def test_a_name_that_cannot_be_a_binding_is_refused(self):
        for engine in ("", "Remote", "re mote", "remote/x", "a" * 33, None, 5, "-x", "../x"):
            with self.subTest(engine=engine):
                with self.assertRaises(CredentialUnavailable) as cm:
                    service_name(engine)
                self.assertEqual(cm.exception.reason, "unbound")
        for host, port in (("", 443), ("127.0.0.1", 443), ("[::1]", 443), ("asr.example.internal.", 443), ("a b.test", 443), (None, 443),
                           (HOST, 0), (HOST, 65536), (HOST, "443"), (HOST, True), (HOST, None), ("*.test", 443), ("a@b.test", 443)):
            with self.subTest(host=host, port=port):
                with self.assertRaises(CredentialUnavailable) as cm:
                    account_name(host, port)
                self.assertEqual(cm.exception.reason, "unbound")

    def test_the_azure_key_is_bound_to_the_fixed_azure_host_suffixes(self):
        for host in (AZURE, "mycompany.cognitiveservices.azure.com", "eu.south.api.cognitive.microsoft.com"):
            with self.subTest(host=host):
                self.store(VENDOR_KEY, "azure", host)
                self.assertEqual(self.read("azure", host), VENDOR_KEY)
        self.security.set_mode("ok")
        before = len(self.security.calls())
        for host in ("evil.example.test", "api.cognitive.microsoft.com", "cognitiveservices.azure.com", "azure.com.evil.test",
                     "evil-api.cognitive.microsoft.com", "koreacentral.api.cognitive.microsoft.com.evil.test", "microsoft.com"):
            with self.subTest(host=host):
                self.assertUnavailable("unbound", "azure", host)
        self.assertEqual(len(self.security.calls()), before)          # an Azure key is not even looked for at another host


class KeychainReadTests(CredsCase):
    def test_the_item_is_asked_for_with_the_exact_argv_and_returned(self):
        self.store(TOKEN)
        self.assertEqual(self.read(), TOKEN)
        self.assertEqual(self.security.argvs(), [["find-generic-password", "-s", "MeetingCapture ASR remote", "-a",
                                                 f"{apikey.keychain_account()}@{HOST}:443", "-w"]])

    def test_a_secret_stored_for_one_host_and_port_is_never_given_for_another(self):
        self.store(TOKEN)
        self.store("second-secret-for-another-engine", "other")
        for engine, host, port in (("remote", "other.example.internal", 443), ("remote", HOST, 8443), ("remote", "example.internal", 443),
                                   ("remote", "x." + HOST, 443), ("remote2", HOST, 443), ("other", HOST, 8443)):
            with self.subTest(engine=engine, host=host, port=port):
                self.assertUnavailable("missing", engine, host, port)
        self.assertEqual(self.read("remote", "ASR.Example.Internal", 443), TOKEN)          # the same host in another spelling
        self.assertEqual(self.read("other", HOST, 443), "second-secret-for-another-engine")

    def test_several_items_live_side_by_side(self):
        self.store(TOKEN)
        self.store(VENDOR_KEY, "azure", AZURE)
        self.security.store("sk-ant-api03-OTHER-" + "0" * 30)                                        # the Anthropic key is a different item
        self.assertEqual((self.read(), self.read("azure", AZURE)), (TOKEN, VENDOR_KEY))

    def test_how_the_tool_is_run(self):
        self.store(TOKEN)
        run = FakeRun(0, (TOKEN + "\n").encode())
        self.assertEqual(self.read(run=run), TOKEN)
        argv, kw = run.calls[0]
        self.assertIs(kw["stdin"], subprocess.DEVNULL)
        self.assertIs(kw["stderr"], subprocess.DEVNULL)               # the tool's stderr can name the item
        self.assertIs(kw["stdout"], subprocess.PIPE)
        self.assertEqual(set(kw["env"]), {"HOME", "USER", "PATH", "LANG"})
        self.assertGreater(kw["timeout"], 0)
        self.assertEqual(argv[1:3], ["find-generic-password", "-s"])
        self.assertNotIn(TOKEN, " ".join(argv))

    def test_a_missing_item_a_hang_a_denial_and_a_broken_tool(self):
        self.assertUnavailable("missing")
        self.store(TOKEN)
        self.security.set_mode("timeout")
        with mock.patch.object(apikey, "READ_TIMEOUT_S", 0.5):
            self.assertUnavailable("timeout")
        self.security.set_mode("deny")
        self.assertUnavailable("error")
        self.security.set_mode("ok")
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "no-such-security")}):
            self.assertUnavailable("no_tool")
        self.assertUnavailable("error", run=FakeRun(1, b"server says: leaked text"))
        self.assertUnavailable("missing", run=FakeRun(44))
        self.assertUnavailable("missing", run=FakeRun(0, b"  \n"))
        self.assertUnavailable("timeout", run=FakeRun(exc=subprocess.TimeoutExpired(["security"], 1)))
        self.assertUnavailable("no_tool", run=FakeRun(exc=PermissionError(13, "nope")))

    def test_a_secret_must_be_one_printable_token(self):
        for bad in ("two words", "tab\there", "line\nbreak", "café", "x" * (asr_creds.MAX_SECRET_CHARS + 1), "ctrl\x01char"):
            with self.subTest(value=bad[:12]):
                self.assertUnavailable("malformed", run=FakeRun(0, bad.encode()))
        self.assertEqual(self.read(run=FakeRun(0, b"x" * asr_creds.MAX_SECRET_CHARS + b"\n")), "x" * asr_creds.MAX_SECRET_CHARS)

    def test_the_value_is_masked_everywhere_after_it_was_read(self):
        for value in (TOKEN, PLAIN):
            with self.subTest(value=value[:8]):
                self.store(value)
                self.assertEqual(self.read(), value)
                self.assertNotIn(value, apikey.redact(f"Authorization: Bearer {value} (and again {value})"))
                self.assertNotIn(value, apikey.redact("raw " + value))


class SecurityBinaryTests(CredsCase):
    """MCAP_SECURITY_BIN is a test hook: honoured without a policy, ignored under one; the default is the absolute system path."""

    def run_once(self, **env):
        run = FakeRun(44)
        with mock.patch.dict(os.environ, env):
            with self.assertRaises(CredentialUnavailable):
                self.read(run=run)
        return run.argvs()[0][0]

    def test_without_a_policy_the_variable_selects_the_tool(self):
        self.assertEqual(self.run_once(MCAP_SECURITY_BIN="/tmp/shim/security"), "/tmp/shim/security")

    def test_with_neither_the_tool_is_the_absolute_system_one(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SECURITY_BIN", None)
            self.assertEqual(self.run_once(), "/usr/bin/security")
            self.assertEqual(asr_creds.apikey.security_bin(), "/usr/bin/security")

    def test_under_a_policy_the_variable_is_ignored(self):
        self.store(TOKEN)
        self.managed()
        self.assertEqual(self.run_once(MCAP_SECURITY_BIN=str(self.security.path)), "/usr/bin/security")
        self.assertEqual(self.security.calls(), [])                    # the fake was never started
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": ""}):
            self.assertEqual(apikey.security_bin(), "/usr/bin/security")

    def test_the_marker_alone_also_means_a_policy(self):
        marker = self.root / "marker-only" / "policy.required"
        marker.parent.mkdir()
        marker.write_text("", encoding="utf-8")
        with mock.patch.object(config, "POLICY_REQUIRED_MARKER", marker):
            self.assertTrue(config.system_policy_present())
            self.assertEqual(self.run_once(MCAP_SECURITY_BIN="/tmp/shim/security"), "/usr/bin/security")

    def test_status_set_and_forget_use_the_same_rule(self):
        self.managed()
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.security.path)}):
            run = FakeRun(0)
            asr_creds.secret_status("remote", HOST, 443, run=run)
            with mock.patch.object(sys, "stdin", TtyInput()), redirect_stdout(io.StringIO()):
                asr_creds.forget_secret("remote", HOST, 443, run=run)
                asr_creds.set_secret_interactive("remote", HOST, 443, run=run)
        self.assertEqual({argv[0] for argv in run.argvs()}, {"/usr/bin/security"})
        self.assertEqual(self.security.calls(), [])


class ErrorStringTests(CredsCase):
    def test_every_reason_has_one_fixed_sentence_without_names_hosts_or_output(self):
        expected = {
            "missing": "remote credential unavailable (missing): no secret is stored for it (run mcap asr-engines enroll remote)",
            "timeout": "remote credential unavailable (timeout): the Keychain did not answer in time",
            "error": "remote credential unavailable (error): the Keychain could not be read",
            "no_tool": "remote credential unavailable (no_tool): the security tool cannot be run",
            "unbound": "remote credential unavailable (unbound): no secret can be stored for this engine, host and port",
            "insecure": "remote credential unavailable (insecure): the secret file is not private to its owner",
            "malformed": "remote credential unavailable (malformed): the stored value cannot be used",
        }
        for reason, text in expected.items():
            with self.subTest(reason=reason):
                exc = CredentialUnavailable(reason, "remote")
                self.assertEqual((str(exc), exc.reason, exc.engine), (text, reason, "remote"))
        self.assertEqual(str(CredentialUnavailable("missing", "azure")),
                         "azure credential unavailable (missing): no secret is stored for it (run mcap asr-engines secret set azure)")
        self.assertEqual(str(CredentialUnavailable("missing")), "credential unavailable (missing): no secret is stored for it")
        self.assertEqual(CredentialUnavailable("missing", "../etc/passwd; rm").engine, "")      # a bad engine id is never echoed

    def test_what_the_tool_and_the_files_say_never_reaches_an_exception(self):
        run = FakeRun(1, b"SERVER TEXT with " + TOKEN.encode() + b" and host " + HOST.encode())
        exc = self.assertUnavailable("error", run=run)
        for text in (str(exc), repr(exc), repr(exc.args)):
            for needle in ("SERVER TEXT", "mcap1_", HOST, apikey.keychain_account(), "MeetingCapture ASR"):
                self.assertNotIn(needle, text)
        exc = self.assertUnavailable("missing", "remote", "other.example.internal", 443)
        self.assertNotIn("other.example.internal", str(exc))
        self.assertNotIn(apikey.keychain_account(), str(exc))


class NothingOnDiskTests(CredsCase):
    def test_the_secret_is_never_written_anywhere(self):
        self.store(TOKEN)
        run = FakeRun(0, TOKEN.encode())
        with secret("remote", HOST, 443, run=run) as value:
            self.assertEqual(value, TOKEN)
        self.read()
        asr_creds.secret_status("remote", HOST, 443)
        for needle in (TOKEN.encode(), TOKEN[10:30].encode()):
            hits = [str(p) for p in self.root.rglob("*") if p.is_file() and needle in p.read_bytes()]
            self.assertEqual(hits, [])
        self.assertNotIn(TOKEN, repr(sorted(os.environ.items())))
        self.assertTrue(all(TOKEN not in " ".join(argv) for argv in self.security.argvs()))

    def test_secret_status_does_not_read_the_value(self):
        self.store(TOKEN)
        status = asr_creds.secret_status("remote", HOST, 443)
        self.assertEqual(status, {"engine": "remote", "service": "MeetingCapture ASR remote",
                                  "account": f"{apikey.keychain_account()}@{HOST}:443", "present": True, "reason": "ok"})
        self.assertEqual(self.security.reads(), 0)                     # no -w: the secret was not even read into this process
        self.assertEqual(self.security.argvs("find-generic-password"), [["find-generic-password", "-s", "MeetingCapture ASR remote",
                                                                          "-a", f"{apikey.keychain_account()}@{HOST}:443"]])
        self.assertNotIn(TOKEN, repr(status))

    def test_secret_status_for_every_state(self):
        self.assertEqual(asr_creds.secret_status("remote", HOST, 443)["reason"], "missing")
        self.assertFalse(asr_creds.secret_status("remote", HOST, 443)["present"])
        self.assertEqual(asr_creds.secret_status("remote", HOST, 8443)["reason"], "missing")          # other port: another item
        self.store(TOKEN)
        self.assertEqual(asr_creds.secret_status("remote", HOST, 8443)["reason"], "missing")
        self.assertEqual(asr_creds.secret_status("remote", HOST, 443)["reason"], "ok")
        self.assertEqual(asr_creds.secret_status("azure", "evil.example.test", 443),
                         {"engine": "azure", "service": None, "account": None, "present": False, "reason": "unbound"})
        self.assertEqual(asr_creds.secret_status("Bad Engine", HOST, 443)["engine"], "")
        run = FakeRun(exc=subprocess.TimeoutExpired(["security"], 1))
        self.assertEqual(asr_creds.secret_status("remote", HOST, 443, run=run)["reason"], "timeout")
        self.assertEqual(asr_creds.secret_status("remote", HOST, 443, run=FakeRun(exc=OSError(2, "x")))["reason"], "no_tool")
        self.assertEqual(asr_creds.secret_status("remote", HOST, 443, run=FakeRun(36))["reason"], "error")


class SetAndForgetTests(CredsCase):
    def run_set(self, run, tty=True, **kw):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdin", TtyInput() if tty else io.StringIO()), redirect_stdout(out), redirect_stderr(err):
            rc = asr_creds.set_secret_interactive("remote", HOST, 443, run=run, **kw)
        return rc, out.getvalue(), err.getvalue()

    def test_set_refuses_without_a_terminal_and_runs_nothing(self):
        run = FakeRun(0)
        rc, out, err = self.run_set(run, tty=False)
        self.assertEqual((rc, run.calls, out), (2, [], ""))
        self.assertIn("terminal", err)

    def test_set_lets_the_tool_prompt_and_never_sees_the_secret(self):
        run = FakeRun(0)
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SECURITY_BIN", None)
            rc, out, err = self.run_set(run)
        self.assertEqual(rc, 0)
        add, kw = run.calls[0]
        self.assertEqual(add, ["/usr/bin/security", "add-generic-password", "-U", "-a", f"{apikey.keychain_account()}@{HOST}:443",
                               "-s", "MeetingCapture ASR remote", "-w"])
        for inherited in ("stdin", "stdout", "stderr", "input", "capture_output"):
            self.assertNotIn(inherited, kw)                            # the tool talks to the terminal itself
        self.assertEqual(set(kw["env"]), {"HOME", "USER", "PATH", "LANG"})
        self.assertEqual(run.calls[1][0][1], "find-generic-password")  # read back for existence only
        self.assertNotIn("-w", run.calls[1][0])
        self.assertIn("Stored.", out)
        self.assertEqual(err, "")

    def test_set_failures(self):
        rc, out, err = self.run_set(FakeRun(rcs=[5]))
        self.assertEqual(rc, 1)
        self.assertIn("exited with 5", err)
        rc, out, err = self.run_set(FakeRun(rcs=[0, 44]))
        self.assertEqual(rc, 1)
        self.assertIn("cannot be found afterwards", err)
        rc, out, err = self.run_set(FakeRun(exc=FileNotFoundError(2, "No such file")))
        self.assertEqual(rc, 1)
        self.assertIn("cannot run", err)

    def test_set_warns_when_the_tool_is_a_shim(self):
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": "/tmp/shim/security"}):
            rc, out, err = self.run_set(FakeRun(0))
        self.assertIn("WARNING", err)
        self.assertIn("MCAP_SECURITY_BIN", err)

    def test_set_refuses_a_binding_that_cannot_hold_a_secret(self):
        out, err = io.StringIO(), io.StringIO()
        run = FakeRun(0)
        with mock.patch.object(sys, "stdin", TtyInput()), redirect_stdout(out), redirect_stderr(err):
            rc = asr_creds.set_secret_interactive("azure", "evil.example.test", 443, run=run)
        self.assertEqual((rc, run.calls), (2, []))

    def test_set_with_the_fake_keychain_end_to_end(self):
        # the fake `add` succeeds but stores nothing, so the read-back finds nothing: the command says so instead of claiming success
        rc, out, err = self.run_set(subprocess.run)
        self.assertEqual(rc, 1)
        self.assertEqual([a[0] for a in self.security.argvs()], ["add-generic-password", "find-generic-password"])

    def test_forget(self):
        def forget(run, engine="remote", host=HOST, port=443):
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                return asr_creds.forget_secret(engine, host, port, run=run), out.getvalue(), err.getvalue()

        run = FakeRun(0)
        rc, out, err = forget(run)
        self.assertEqual((rc, "Deleted" in out), (0, True))
        self.assertEqual(run.argvs()[0][1:], ["delete-generic-password", "-s", "MeetingCapture ASR remote", "-a",
                                              f"{apikey.keychain_account()}@{HOST}:443"])
        self.assertEqual(forget(FakeRun(44))[0:2], (0, "Nothing to delete: no Keychain item (service 'MeetingCapture ASR remote', account "
                                                   f"'{apikey.keychain_account()}@{HOST}:443').\n"))
        rc, out, err = forget(FakeRun(36))
        self.assertEqual(rc, 1)
        self.assertIn("exited with 36", err)
        self.assertEqual(forget(FakeRun(exc=OSError(2, "x")))[0], 1)
        self.assertEqual(forget(FakeRun(exc=subprocess.TimeoutExpired(["security"], 1)))[0], 1)
        self.assertEqual(forget(FakeRun(0), "azure", "evil.example.test")[0], 2)

    def test_forget_with_the_fake_keychain(self):
        self.store(TOKEN)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(asr_creds.forget_secret("remote", HOST, 443), 0)
            self.assertEqual(asr_creds.forget_secret("remote", HOST, 443), 0)          # a second time: nothing there, still fine
        self.assertUnavailable("missing")


class FileSourceTests(CredsCase):
    def setUp(self):
        super().setUp()
        self.dir = self.root / "asr-secrets"
        self.dir.mkdir(mode=0o700)
        self.path = self.dir / "azure.key"
        self.put(VENDOR_KEY + "\n")

    def put(self, text, mode=0o600, data=None):
        self.path.unlink(missing_ok=True)
        self.path.write_bytes(data if data is not None else text.encode())
        self.path.chmod(mode)

    def source(self, **kw):
        kw.setdefault("engine", "azure")
        kw.setdefault("host", AZURE)
        return FileSource(self.path, **kw)

    def test_the_file_is_the_secret_for_exactly_its_binding(self):
        source = self.source()
        self.assertEqual(self.read("azure", AZURE, source=source), VENDOR_KEY)
        for engine, host, port in (("remote", AZURE, 443), ("azure", "other.api.cognitive.microsoft.com", 443), ("azure", AZURE, 8443)):
            with self.subTest(engine=engine, host=host, port=port):
                self.assertUnavailable("unbound", engine, host, port, source=source)

    def test_it_is_read_every_time_and_nothing_is_cached(self):
        source = self.source()
        self.assertEqual(self.read("azure", AZURE, source=source), VENDOR_KEY)
        self.put("rotated-vendor-key-0123456789abcdef\n")
        self.assertEqual(self.read("azure", AZURE, source=source), "rotated-vendor-key-0123456789abcdef")
        self.path.unlink()
        self.assertUnavailable("missing", "azure", AZURE, source=source)

    def test_the_file_must_be_private_to_its_owner(self):
        source = self.source()
        for mode in (0o640, 0o644, 0o666, 0o604, 0o660):
            with self.subTest(mode=oct(mode)):
                self.put(VENDOR_KEY, mode)
                self.assertUnavailable("insecure", "azure", AZURE, source=source)
        for mode in (0o600, 0o400, 0o700):
            with self.subTest(mode=oct(mode)):
                self.put(VENDOR_KEY, mode)
                self.assertEqual(self.read("azure", AZURE, source=source), VENDOR_KEY)

    def test_a_symlink_a_directory_a_foreign_owner_and_a_writable_directory_are_refused(self):
        source = self.source()
        real = self.dir / "real.key"
        real.write_text(VENDOR_KEY, encoding="ascii")
        real.chmod(0o600)
        self.path.unlink()
        self.path.symlink_to(real)
        self.assertUnavailable("insecure", "azure", AZURE, source=source)
        self.path.unlink()
        self.path.mkdir()
        self.assertUnavailable("insecure", "azure", AZURE, source=source)
        self.path.rmdir()
        self.put(VENDOR_KEY)
        self.assertEqual(self.read("azure", AZURE, source=source), VENDOR_KEY)
        self.assertUnavailable("insecure", "azure", AZURE, source=self.source(owner_uid=os.geteuid() + 1))
        self.dir.chmod(0o770)
        self.assertUnavailable("insecure", "azure", AZURE, source=source)
        self.dir.chmod(0o755)                                          # readable by others is fine; writable is not
        self.assertEqual(self.read("azure", AZURE, source=source), VENDOR_KEY)
        self.dir.chmod(0o700)

    def test_size_content_and_shape(self):
        source = self.source()
        self.put("", data=b"x" * (asr_creds.MAX_SECRET_FILE_BYTES + 1))
        self.assertUnavailable("malformed", "azure", AZURE, source=source)
        for data, reason in ((b"", "missing"), (b"\n\n", "missing"), (b"two words", "malformed"), (b"line1\nline2", "malformed"),
                             (b"\xff\xfe\x00", "malformed")):
            with self.subTest(data=data):
                self.put("", data=data)
                self.assertUnavailable(reason, "azure", AZURE, source=source)

    def test_a_missing_file_is_missing(self):
        self.path.unlink()
        self.assertUnavailable("missing", "azure", AZURE, source=self.source())

    def test_a_source_for_a_binding_that_cannot_exist_is_refused_at_construction(self):
        with self.assertRaises(CredentialUnavailable):
            FileSource(self.path, engine="azure", host="evil.example.test")
        with self.assertRaises(CredentialUnavailable):
            FileSource(self.path, engine="Bad Engine", host=AZURE)

    def test_installed_sources_replace_the_keychain_for_secret(self):
        self.store(TOKEN, "azure", AZURE)                                # the Keychain holds a different value
        previous = asr_creds.install_source(self.source())
        self.assertEqual(previous, ())
        self.assertEqual(self.read("azure", AZURE), VENDOR_KEY)
        self.assertEqual(self.security.calls(), [])                      # the Keychain was not consulted
        self.assertUnavailable("unbound", "remote", HOST)                # and there is no fallback to it for another binding
        self.assertEqual(self.security.calls(), [])
        asr_creds.install_source()
        self.assertEqual(self.read("azure", AZURE), TOKEN)               # restored: the Keychain again

    def test_several_installed_sources_are_tried_in_order_and_the_explicit_one_wins(self):
        other = self.dir / "remote.token"
        other.write_text(TOKEN + "\n", encoding="ascii")
        other.chmod(0o600)
        first, second = self.source(), FileSource(other, engine="remote", host=HOST)
        asr_creds.install_source(first, second)
        self.assertEqual((self.read("azure", AZURE), self.read("remote", HOST)), (VENDOR_KEY, TOKEN))
        self.assertUnavailable("unbound", "remote", "elsewhere.example.internal")
        other.chmod(0o644)
        self.assertUnavailable("insecure", "remote", HOST)               # the failure that is not just 'not my binding' is the one reported
        self.assertEqual(self.read("remote", HOST, source=FileSource(self.path, engine="remote", host=HOST)), VENDOR_KEY)
        self.assertEqual(asr_creds.install_source(), (first, second))

    def test_a_value_read_from_a_file_is_masked_afterwards(self):
        self.put(PLAIN)
        self.assertEqual(self.read("azure", AZURE, source=self.source()), PLAIN)
        self.assertNotIn("CANARY", apikey.redact("x " + PLAIN))


class KeychainSourceTests(CredsCase):
    def test_the_source_can_be_used_directly(self):
        self.store(TOKEN)
        self.assertEqual(KeychainSource().read("remote", HOST, 443), TOKEN)
        with self.assertRaises(CredentialUnavailable) as cm:
            KeychainSource().read("remote", "evil host", 443)
        self.assertEqual(cm.exception.reason, "unbound")

    def test_an_explicit_source_replaces_the_keychain(self):
        class Fixed:
            def read(self, engine, host, port):
                return f"fixed-{engine}-{port}-token"

        self.assertEqual(self.read("remote", HOST, 8443, source=Fixed()), "fixed-remote-8443-token")
        self.assertEqual(self.security.calls(), [])


if __name__ == "__main__":
    unittest.main()
