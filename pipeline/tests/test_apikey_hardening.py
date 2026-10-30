"""apikey.py additions of: the narrow redaction shapes of the external-ASR credentials (relay bearer tokens,
the mcap1 token shape, JWTs, PEM blocks, the Azure key header) through `redact`, logging, state.json and usage.jsonl, WITH CR/LF; the proof
that ordinary text (a meeting title) is not touched; `register_redaction_pattern`; the escaped and line-by-line masking of a key with line
breaks; $MCAP_SECURITY_BIN being ignored under an organisation policy. test_apikey.py is not edited and still passes."""
import contextlib
import io
import json
import logging
import os
import random
import re
import subprocess
import sys
import time
import traceback
import unittest
from unittest import mock

from net_guard_support import NoNetworkCase
from notes_cli_support import make_cfg

from mcap import apikey, egress, state, usage

# Every canary carries a fragment that no legitimate text has; FRAGMENTS are what must never survive masking.
BEARER_TOKEN = "mcap1_0a1b2c3d_CANARYBEARER0123456789abcdefgh"
JWT = "eyJhbGciOiJIUzI1NiJ9CANARYJWT.eyJzdWIiOiJDQU5BUlkifQCANARYPAYLOAD.sig_CANARYSIGNATURE-0123"
PEM = ("-----BEGIN PRIVATE KEY-----\r\nMIIE_CANARYPEMBODY_line1\r\nline2_CANARYPEMBODY\r\n-----END PRIVATE KEY-----")
APIM = "CANARYAPIMKEY0123456789abcdef"
LONG_BEARER = "CANARYLONGBEARERTOKEN0123456789abcdef"

SHAPES = {
    "bearer mcap1": (f"Authorization: Bearer {BEARER_TOKEN}", ("CANARYBEARER", "0a1b2c3d")),
    "mcap1 alone": (f"token={BEARER_TOKEN}", ("CANARYBEARER", "0a1b2c3d")),
    "long bearer": (f"Authorization: Bearer {LONG_BEARER}", ("CANARYLONGBEARER",)),
    "jwt": (f"id_token {JWT} end", ("CANARYJWT", "CANARYPAYLOAD", "CANARYSIGNATURE", "eyJhbGci")),
    "pem": (f"key follows\r\n{PEM}\r\nand more text", ("CANARYPEMBODY", "MIIE_")),
    "apim header": (f"Ocp-Apim-Subscription-Key: {APIM}", ("CANARYAPIMKEY",)),
    "apim dict repr": (f"{{'Ocp-Apim-Subscription-Key': '{APIM}', 'Content-Type': 'audio/wav'}}", ("CANARYAPIMKEY",)),
}
VARIANTS = {                                           # the same text as it appears in real output
    "bare": lambda text: text,
    "crlf around": lambda text: f"before\r\n{text}\r\nafter",
    "lf around": lambda text: f"before\n{text}\nafter",
    "exception message": lambda text: f"Invalid header value {text!r}",
    "bytes repr": lambda text: f"Invalid header value {text.encode()!r}",
    "traceback line": lambda text: f'  File "x.py", line 3, in send\n    conn.putheader("X", {text!r})',
}

ORDINARY_TEXT = [
    "Bearer token rotation sync", "Weekly sync: Bearer of good news", "eyJ is the base64 prefix of a JWT header", "mcap1 rollout plan",
    "Ocp-Apim review and subscription key rotation", "BEGIN and END of the migration", "-----BEGIN is how a PEM block starts",
    "Q4 planning -- budget -- hiring", "Sync with Bearer Inc. about the 2026 pilot", "bearer", "Bearer ", "Bearer short",
    "회의: Bearer 토큰 교체 논의", "Subscription-Key is mentioned here", "mcap1_ is a prefix", "mcap1_0a1b2c3d_short",
    "https://example.test/path?token=abc", "Authorization header discussion", "sk-ant- is only a prefix",
    "The JWT eyJ and the PEM -----BEGIN CERTIFICATE----- are mentioned in the agenda only",
]


class TtyInput(io.StringIO):
    def isatty(self):
        return True


def survivors(text: str, fragments) -> list:
    return [f for f in fragments if f in text]


class RedactShapesTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(apikey._known.clear)

    def test_every_shape_is_masked_in_every_variant_of_real_output(self):
        for shape, (text, fragments) in SHAPES.items():
            for variant, wrap in VARIANTS.items():
                with self.subTest(shape=shape, variant=variant):
                    clean = apikey.redact(wrap(text))
                    self.assertEqual(survivors(clean, fragments), [], clean)
                    self.assertEqual(apikey.redact(clean), clean)                       # idempotent

    def test_the_masks_keep_enough_context_to_read_the_line(self):
        self.assertEqual(apikey.redact(f"Authorization: Bearer {BEARER_TOKEN}\r\nHost: x"), "Authorization: Bearer ***\r\nHost: x")
        self.assertEqual(apikey.redact(f"a {BEARER_TOKEN} b"), "a mcap1_*** b")
        self.assertEqual(apikey.redact(f"t {JWT} u"), "t eyJ*** u")
        self.assertEqual(apikey.redact(f"Ocp-Apim-Subscription-Key: {APIM}"), "Ocp-Apim-Subscription-Key: ***")
        self.assertEqual(apikey.redact(f"ocp-apim-subscription-key={APIM}&x=1"), "ocp-apim-subscription-key=***&x=1")
        self.assertEqual(apikey.redact(f"x\r\n{PEM}\r\ny"), "x\r\n-----BEGIN ***-----\r\ny")

    def test_a_truncated_pem_block_is_masked_to_the_end(self):
        clean = apikey.redact("-----BEGIN PRIVATE KEY-----\r\nMIIE_CANARYPEMBODY_line1\r\nline2_CANARYPEMBODY")
        self.assertEqual(clean, "-----BEGIN ***-----")
        two = apikey.redact(f"{PEM}\nmiddle\n{PEM}")
        self.assertEqual(two, "-----BEGIN ***-----\nmiddle\n-----BEGIN ***-----")
        for label in ("RSA PRIVATE KEY", "EC PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "OPENSSH PRIVATE KEY"):
            self.assertEqual(apikey.redact(f"x -----BEGIN {label}-----\nMIIE_CANARYPEMBODY"), "x -----BEGIN ***-----")
        cut_certificate = "a public certificate -----BEGIN CERTIFICATE-----\nMIIBdjCCAR2gAwIBAgIU cut off"      # public data: only a complete block is masked
        self.assertEqual(apikey.redact(cut_certificate), cut_certificate)
        self.assertEqual(apikey.redact("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"), "-----BEGIN ***-----")

    def test_ordinary_text_is_not_changed(self):
        for text in ORDINARY_TEXT:
            with self.subTest(text=text):
                self.assertEqual(apikey.redact(text), text)
        self.assertEqual(apikey.redact_obj({"title": "Bearer token rotation sync", "n": ["eyJ is a prefix"]}),
                         {"title": "Bearer token rotation sync", "n": ["eyJ is a prefix"]})

    def test_the_bearer_rules_need_a_real_token_after_the_word(self):
        self.assertEqual(apikey.redact("Bearer token rotation sync"), "Bearer token rotation sync")
        self.assertEqual(apikey.redact("Bearer " + "a" * 23), "Bearer " + "a" * 23)                  # one short of a token
        self.assertEqual(apikey.redact("Bearer " + "a" * 24), "Bearer ***")
        self.assertEqual(apikey.redact("bearer " + "A1" * 12), "Bearer ***")                         # the scheme word is case-insensitive
        self.assertEqual(apikey.redact("Bearer mcap1_x"), "Bearer ***")                              # the relay scheme needs no length

    def test_jwt_and_mcap1_shapes_need_their_structure(self):
        self.assertEqual(apikey.redact("eyJabc.def"), "eyJabc.def")                                  # too short to be a JWT
        self.assertEqual(apikey.redact("eyJ" + "a" * 20), "eyJ" + "a" * 20)                          # one segment is not a JWT
        self.assertEqual(apikey.redact("eyJ" + "a" * 8 + "." + "b" * 8), "eyJ***")
        self.assertEqual(apikey.redact("mcap1_0a1b2c3d_" + "z" * 15), "mcap1_0a1b2c3d_" + "z" * 15)  # secret part too short
        self.assertEqual(apikey.redact("mcap1_0A1B2C3D_" + "z" * 32), "mcap1_0A1B2C3D_" + "z" * 32)  # the id is lower-case hex
        self.assertEqual(apikey.redact("xmcap1_0a1b2c3d_" + "z" * 32), "xmcap1_0a1b2c3d_" + "z" * 32)
        self.assertEqual(apikey.redact("mcap1_0a1b2c3d_" + "z" * 32), "mcap1_***")

    def test_existing_behaviour_is_unchanged(self):
        self.assertEqual(apikey.redact("Invalid API key sk-ant-api03-AbC_d-123 (x)"), "Invalid API key sk-ant-*** (x)")
        self.assertIsNone(apikey.redact(None))
        self.assertEqual(apikey.redact(42), 42)
        self.assertEqual(apikey.redact(""), "")


# The PEM rule as it was written before it became a scan (apikey._mask_pem): the reference of the differential test below.
OLD_PEM_RULE = re.compile(r"-----BEGIN [A-Z0-9 ]{1,40}-----[\s\S]*?-----END [A-Z0-9 ]{1,40}-----|"
                          r"-----BEGIN [A-Z0-9 ]{0,30}PRIVATE KEY-----[\s\S]*")


class RedactCostTests(NoNetworkCase):
    """redact() runs on every log record, state write and claude result, and its input can come from a hostile server: no shape may cost
    more than linear time. (A lazy PEM body that is rescanned to the end of the text for every header without a footer, and a JWT start
    inside a long run of token characters, took 14 to 50 seconds for 300 to 450 KB.)"""
    BUDGET_S = 3.0                                     # these inputs take about 0.02 s; a quadratic rule needs 14 s or more

    def timed(self, text):
        started = time.monotonic()
        clean = apikey.redact(text)
        return clean, time.monotonic() - started

    def test_hostile_runs_of_every_marker_are_handled_in_linear_time(self):
        cases = {
            "PEM headers without a footer": "-----BEGIN A-----\n" * 16000,
            "certificate headers without a footer": "-----BEGIN CERTIFICATE-----\n" * 16000,
            "PEM headers and a footer that is none": "-----BEGIN A-----\n" * 16000 + "-----END a-----",
            "footers only": "-----END A-----\n" * 20000,
            "JWT starts inside one run": "eyJaaaaaaa-" * 32000,
            "JWT starts, a dot, a short second segment": "eyJaaaaaaa.a " * 25000,
            "Bearer scheme words": "Bearer " * 40000,
            "Bearer and one short token each": ("Bearer " + "a" * 23 + " ") * 10000,
            "Bearer and a long blank run": "Bearer" + " " * 300000,
            "mcap1 prefixes": "mcap1_" * 40000,
            "mcap1 ids glued with hyphens": "-mcap1_0a1b2c3d" * 40000,
            "Ocp-Apim names and a long blank run": "Ocp-Apim-Subscription-Key" + " " * 300000,
            "Ocp-Apim names": "Ocp-Apim-Subscription-Key: " * 20000,
            "sk-ant prefixes": "sk-ant-" * 40000,
        }
        for name, text in cases.items():
            with self.subTest(case=name):
                clean, seconds = self.timed(text)
                self.assertLess(seconds, self.BUDGET_S, f"{name}: {seconds:.1f} s for {len(text)} characters")
                self.assertGreater(len(clean), 0)

    def test_a_text_without_a_complete_shape_comes_out_unchanged_whatever_its_size(self):
        for text in ("-----BEGIN A-----\n" * 16000, "-----BEGIN CERTIFICATE-----\n" * 16000, "eyJaaaaaaa-" * 32000, "Bearer " * 40000,
                     "-----BEGIN A-----\n" * 16000 + "-----END a-----"):
            self.assertEqual(self.timed(text)[0], text)

    def test_a_real_secret_inside_hostile_noise_is_still_masked(self):
        noise = "-----BEGIN A-----\n" * 4000 + "eyJaaaaaaa-" * 4000
        secrets = (("Authorization: Bearer " + BEARER_TOKEN, "CANARYBEARER"), (f"token {JWT} end", "CANARYJWT"),
                   (PEM, "CANARYPEMBODY"), (f"mcap1_0a1b2c3d_{'z' * 32} and CANARYMCAP", "mcap1_0a1b2c3d_z"))
        for secret, fragment in secrets:
            with self.subTest(fragment=fragment):
                clean, seconds = self.timed(noise + "\n" + secret + "\n" + noise)
                self.assertLess(seconds, self.BUDGET_S)
                self.assertNotIn(fragment, clean)

    def test_the_pem_scan_masks_exactly_what_the_regex_it_replaced_masked(self):
        pieces = ["-----BEGIN ", "-----END ", "A", "PRIVATE KEY", "CERTIFICATE", "-----", "\n", " ", "x", "--", "-----BEGIN PRIVATE KEY-----",
                  "-----END PRIVATE KEY-----", "lower", "-", "RSA ", "0", "-----BEGIN A-----", "-----END A-----", " " * 31, "Z" * 41, "\r\n"]
        rng = random.Random(20261015)
        for _ in range(30000):
            text = "".join(rng.choice(pieces) for _ in range(rng.randint(1, 12)))
            expected = OLD_PEM_RULE.sub("-----BEGIN ***-----", text)
            if apikey._mask_pem(text) != expected:
                self.fail(f"{text!r}: {apikey._mask_pem(text)!r} instead of {expected!r}")
        for text in ("", "no fence", "-----BEGIN ", "-----BEGIN A-----", PEM, f"x {PEM} y {PEM} z", "-----BEGIN A-----BEGIN B-----END C-----"):
            self.assertEqual(apikey._mask_pem(text), OLD_PEM_RULE.sub("-----BEGIN ***-----", text), text)

    def test_a_jwt_is_masked_wherever_a_token_starts(self):
        for before in ("", " ", "\n", "\t", '"', "'", "=", ":", "(", "[", ",", ";", "/", "<", "id_token="):
            with self.subTest(before=before):
                self.assertEqual(apikey.redact(f"{before}{JWT}!"), f"{before}eyJ***!")
        self.assertEqual(apikey.redact(f"Authorization: Bearer {JWT}!"), "Authorization: Bearer ***!")           # the bearer rule masks it first


class RememberTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(apikey._known.clear)

    def test_a_key_with_line_breaks_is_masked_whole_escaped_and_line_by_line(self):
        key = "plain-secret-line-one-CANARY\r\nsecond-line-of-it-CANARY"
        apikey.remember(key)
        for text in (f"x {key} y", f"Invalid header value {key!r}", f"Invalid header value {key.encode()!r}",
                     "only the first: plain-secret-line-one-CANARY.", "only the second: second-line-of-it-CANARY."):
            with self.subTest(text=text[:30]):
                self.assertNotIn("CANARY", apikey.redact(text))

    def test_short_values_and_non_strings_are_not_registered(self):
        apikey.remember("short")
        apikey.remember(None)
        apikey.remember(12345678)
        apikey.remember("a\nb")
        self.assertEqual(apikey._known, set())
        self.assertEqual(apikey.redact("a short word a\nb"), "a short word a\nb")

    def test_a_plain_key_registers_one_entry(self):
        apikey.remember("plain-relay-secret-CANARY-0123456789")
        self.assertEqual(apikey._known, {"plain-relay-secret-CANARY-0123456789"})

    def test_a_key_with_a_backslash_is_masked_in_its_escaped_form_too(self):
        key = "secret\\with\\backslashes-CANARY"
        apikey.remember(key)
        self.assertNotIn("CANARY", apikey.redact(f"repr: {key!r}"))


class RegisterPatternTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        saved = list(apikey._extra_patterns)
        self.addCleanup(lambda: apikey._extra_patterns.__setitem__(slice(None), saved))
        self.addCleanup(apikey._known.clear)

    def test_a_registered_pattern_masks_everything_redact_sees(self):
        apikey.register_redaction_pattern(r"vendorkey-[0-9a-f]{12}")
        self.assertEqual(apikey.redact("k=vendorkey-0123456789ab!"), "k=***!")
        apikey.register_redaction_pattern(re.compile(r"(?i)x-vendor-sig: (\S+)"), r"X-Vendor-Sig: <masked>")
        self.assertEqual(apikey.redact("X-VENDOR-SIG: abcdef"), "X-Vendor-Sig: <masked>")
        self.assertEqual(apikey.redact("nothing here"), "nothing here")

    def test_registering_twice_adds_it_once(self):
        before = len(apikey._extra_patterns)
        apikey.register_redaction_pattern(r"vendorkey-[0-9a-f]{12}")
        apikey.register_redaction_pattern(r"vendorkey-[0-9a-f]{12}")
        self.assertEqual(len(apikey._extra_patterns), before + 1)

    def test_a_pattern_that_matches_the_empty_string_is_refused(self):
        for bad in (r"", r"a*", r"(?:x)?", re.compile(r"x*")):
            with self.subTest(pattern=str(bad)):
                with self.assertRaises(ValueError):
                    apikey.register_redaction_pattern(bad)
        with self.assertRaises(ValueError):
            apikey.register_redaction_pattern(42)
        self.assertEqual(apikey.redact("some text"), "some text")

    def test_a_bad_regex_is_the_callers_error(self):
        with self.assertRaises(re.error):
            apikey.register_redaction_pattern("(unclosed")

    def test_state_and_logs_use_it_too(self):
        apikey.register_redaction_pattern(r"vendorkey-[0-9a-f]{12}")
        self.assertEqual(apikey.redact_obj({"a": ["x vendorkey-0123456789ab"]}), {"a": ["x ***"]})


class LogFilterShapeTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
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

    def test_every_shape_with_line_breaks_is_masked_in_messages_arguments_and_tracebacks(self):
        log = logging.getLogger("mcap.egress.test")
        for shape, (text, fragments) in SHAPES.items():
            self.stream.truncate(0)
            self.stream.seek(0)
            with self.subTest(shape=shape):
                log.warning("attempt failed: " + text.replace("%", "%%"))
                log.warning("attempt failed: %s", f"before\r\n{text}\r\nafter")
                try:
                    raise ValueError(f"Invalid header value {text!r}")
                except ValueError:
                    log.exception("send failed")
                self.assertEqual(survivors(self.stream.getvalue(), fragments), [], self.stream.getvalue())

    def test_a_registered_secret_with_line_breaks_is_masked_in_a_log_record(self):
        secret = "plain-relay-secret-line-one-CANARY\r\nsecond-line-of-the-secret-CANARY"
        apikey.remember(secret)
        logging.getLogger("mcap.egress").error("the transport said %r", secret)
        logging.getLogger("mcap.egress").error("the transport said " + secret.split("\r\n")[1])
        self.assertNotIn("CANARY", self.stream.getvalue())

    def test_a_title_in_a_log_line_is_not_changed(self):
        logging.getLogger("mcap.note").info("title: Bearer token rotation sync")
        self.assertIn("title: Bearer token rotation sync", self.stream.getvalue())


class StoredFilesShapeTests(NoNetworkCase):
    def test_state_json_never_carries_a_shape_even_with_line_breaks(self):
        d = self.root / "session"
        d.mkdir()
        for shape, (text, fragments) in SHAPES.items():
            with self.subTest(shape=shape):
                state.write_state(d, stage="failed", error=f"relay said:\r\n{text}", warning=f"w {text}", stage_detail=f"d\n{text}\n",
                                  title="Bearer token rotation sync", error_kind="asr_unreachable")
                raw = (d / "state.json").read_text(encoding="utf-8")
                self.assertEqual(survivors(raw, fragments), [], raw)
                loaded = json.loads(raw)                                                   # still valid JSON
                self.assertEqual(loaded["title"], "Bearer token rotation sync")            # a title next to the masked text is untouched
                self.assertEqual(state.read_state(d)["error_kind"], "asr_unreachable")

    def test_usage_jsonl_never_carries_a_shape(self):
        cfg = make_cfg(self.root)
        for shape, (text, fragments) in SHAPES.items():
            usage.record(cfg, "note", models=[f"m {text}"], requested=f"r\r\n{text}", outcome=f"bad {text}", session_id=f"s {text}", cost_usd=0.01)
        raw = usage.usage_path(cfg).read_text(encoding="utf-8")
        every_fragment = [f for _text, fragments in SHAPES.values() for f in fragments]
        self.assertEqual(survivors(raw, every_fragment), [])
        self.assertEqual(len(raw.splitlines()), len(SHAPES))

    def test_an_egress_failure_written_to_state_and_log_carries_none_of_the_headers(self):
        # the whole chain: http.client's ValueError names the header value; the guard drops it; what is stored is the fixed sentence
        class Transport:
            def send(self, rule, method, target, headers, body, timeout):
                raise ValueError(f"Invalid header value {headers['Authorization']!r}")

        header = "Bearer " + BEARER_TOKEN
        guard = egress.EgressGuard({"asr.example.internal": egress.HostRule("asr.example.internal")}, engine_id="remote",
                                   consent_id="c", transport=Transport(), secrets=lambda: (BEARER_TOKEN,))
        with self.assertRaises(egress.EgressError) as cm:
            guard.request("POST", "https://asr.example.internal/v1/chunk", headers={"Authorization": header}, body=b"x", path_label="chunk")
        d = self.root / "session"
        d.mkdir()
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        logging.getLogger("mcap.egress").addHandler(handler)
        self.addCleanup(logging.getLogger("mcap.egress").removeHandler, handler)
        logging.getLogger("mcap.egress").error("asr request failed: %s", cm.exception)
        state.write_state(d, stage="failed", error=str(cm.exception), error_kind="asr_unreachable")
        everything = stream.getvalue() + (d / "state.json").read_text(encoding="utf-8") + "".join(traceback.format_exception(cm.exception))
        self.assertNotIn("CANARY", everything)
        self.assertNotIn("0a1b2c3d", everything)
        self.assertIn("egress bad_request", everything)


class SecurityBinaryPolicyTests(NoNetworkCase):
    """$MCAP_SECURITY_BIN is honoured without an organisation policy (the existing tests rely on it) and ignored under one."""

    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def run_lookup(self):
        seen = []

        def fake_run(argv, **kwargs):
            seen.append(argv)
            return subprocess.CompletedProcess(argv, 44, stdout=b"", stderr=b"")

        with mock.patch.object(apikey.subprocess, "run", fake_run):
            apikey.lookup(self.cfg)
        return seen[0][0]

    def test_the_variable_is_honoured_without_a_policy(self):
        self.assertEqual(apikey.security_bin(), str(self.security.path))
        self.assertEqual(self.run_lookup(), str(self.security.path))

    def test_the_default_is_the_absolute_system_tool(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SECURITY_BIN")
            self.assertEqual(apikey.security_bin(), "/usr/bin/security")
            self.assertEqual(self.run_lookup(), "/usr/bin/security")

    def test_under_a_policy_the_variable_is_ignored_for_every_keychain_call(self):
        self.system_policy(True)
        self.assertEqual(apikey.security_bin(), "/usr/bin/security")
        self.assertEqual(self.run_lookup(), "/usr/bin/security")
        argvs = []
        fake = lambda argv, **kw: argvs.append(argv) or subprocess.CompletedProcess(argv, 0, stdout=b"")  # noqa: E731
        with mock.patch.object(apikey.subprocess, "run", fake), mock.patch.object(sys, "stdin", TtyInput()), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            apikey.forget_key(self.cfg)
            apikey.set_key_interactive(self.cfg)
        self.assertEqual({a[0] for a in argvs}, {"/usr/bin/security"})
        self.assertGreaterEqual(len(argvs), 3)
        self.assertEqual(self.security.calls(), [])                                          # the shim never ran

    def test_an_empty_variable_means_the_default_too(self):
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": ""}):
            self.assertEqual(apikey.security_bin(), "/usr/bin/security")


class ExistingBehaviourTests(NoNetworkCase):
    """The additions do not change what test_apikey.py pins (spot checks that do not depend on it)."""

    def test_the_lookup_still_masks_the_key_it_read_and_the_security_env_is_unchanged(self):
        self.addCleanup(apikey._known.clear)
        self.security.store("sk-ant-api03-CANARY-" + "0" * 40)
        found = apikey.lookup(make_cfg(self.root))
        self.assertEqual(found.reason, "ok")
        self.assertNotIn("CANARY", apikey.redact(f"leak {found.key}"))
        self.assertEqual(set(apikey._security_env()), {"HOME", "USER", "PATH", "LANG"})


if __name__ == "__main__":
    unittest.main()
