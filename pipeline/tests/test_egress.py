"""egress.py: every denial of EgressGuard before a socket exists (through an injected Transport), the TLS
context HttpsTransport builds (private CA bytes hashed then used, min TLS 1.2, environment ignored, truststore fallback), the transport's
own bounds and fixed error strings (through a fake HTTPSConnection), and the Tripwire (strict and audit, thread-local authorisation,
reference counting). No test opens a socket: the socket layer is replaced by recorders (SocketStubs) or by NoNetworkCase."""
import contextlib
import dataclasses
import errno
import hashlib
import http.client
import io
import os
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import traceback
import unittest
import warnings
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from net_guard_support import (NetworkAttempt, NoNetworkCase, RealSecurityAttempt, SocketStubs, TEST_PKI, is_real_security, memory_handshake,
                               server_context, write_test_pki)
from notes_cli_support import load_test_policy, make_cfg

from mcap import apikey, asr_creds, config, egress, policy
from mcap.egress import (EgressDenied, EgressError, EgressGuard, EgressViolation, HttpsTransport, Response, Tripwire,
                         build_ssl_context)
from mcap.policy import HostRule, LaneBlock

HOST = "asr.example.internal"
URL = f"https://{HOST}/v1/chunk"
CANARY_TOKEN = "mcap1_0a1b2c3d_CANARY" + "x" * 11 + "_Zq9" + "y" * 10     # relay-token shaped
PLAIN_SECRET = "plain_secret_CANARY_9f8e7d6c5b"                               # no recognisable shape: only exact-match masking can catch it
EVIL_HEADER = "Bearer " + CANARY_TOKEN + "\r\nX-Injected: 1"
REAL_CREATE_CONNECTION = socket.create_connection                           # the stdlib one, taken before any test patches the socket module


class FakeTransport:
    """An in-process Transport: records what the guard handed it and answers with a canned Response, an exception or a handler."""

    def __init__(self, status=200, body=b"{}", headers=None, exc=None, handler=None):
        self.status, self.body, self.headers, self.exc, self.handler = status, body, dict(headers or {}), exc, handler
        self.calls = []

    def send(self, rule, method, target, headers, body, timeout):
        self.calls.append({"rule": rule, "method": method, "target": target, "headers": dict(headers), "body": body, "timeout": timeout})
        if self.handler is not None:
            return self.handler(rule, method, target, headers, body, timeout)
        if self.exc is not None:
            raise self.exc
        return Response(self.status, dict(self.headers), self.body, 0, 0, 0)


class GuardCase(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(apikey._known.clear)
        self.rule = HostRule(HOST)
        self.transport = FakeTransport()
        self.usage = []

    def make(self, rules=None, **kw):
        kw.setdefault("transport", self.transport)
        kw.setdefault("usage", self.usage.append)
        return EgressGuard({HOST: self.rule} if rules is None else rules, engine_id="remote", consent_id="org:remote-test", **kw)

    def post(self, guard=None, url=URL, **kw):
        kw.setdefault("headers", {"Content-Type": "application/octet-stream"})
        kw.setdefault("body", b"pcm")
        kw.setdefault("path_label", "chunk")
        return (guard or self.make()).request("POST", url, **kw)

    def assertDenied(self, url, code, **kw):
        with self.assertRaises(EgressDenied) as cm:
            self.post(url=url, **kw)
        self.assertEqual(cm.exception.code, code, url)
        self.assertEqual(len(self.transport.calls), 0, f"{url} reached the transport")
        return cm.exception


# ======================================================================================================================
# EgressGuard: what is refused before any socket exists
# ======================================================================================================================
class DenialTests(GuardCase):
    def test_every_malformed_or_unlisted_destination_is_refused_before_the_transport(self):
        cases = [
            # scheme
            ("http://asr.example.internal/v1/chunk", "scheme"), ("HTTP://asr.example.internal/x", "scheme"),
            ("ftp://asr.example.internal/x", "scheme"), ("file:///etc/passwd", "scheme"), ("//asr.example.internal/x", "scheme"),
            ("asr.example.internal/x", "scheme"), ("wss://asr.example.internal/x", "scheme"),
            # userinfo
            ("https://user:pass@asr.example.internal/x", "userinfo"), ("https://user@asr.example.internal/x", "userinfo"),
            ("https://asr.example.internal:443@evil.example.test/x", "userinfo"), ("https://@asr.example.internal/x", "userinfo"),
            # not in the rules
            ("https://evil.example.test/x", "host_not_allowed"), ("https://asr.example.internal.evil.example.test/x", "host_not_allowed"),
            ("https://xasr.example.internal/x", "host_not_allowed"), ("https://a.asr.example.internal/x", "host_not_allowed"),
            ("https://example.internal/x", "host_not_allowed"), ("https://asr.example.internal%2eevil.test/x", "host"),
            ("https://ASR.ACME.INTERNAL.evil.test/x", "host_not_allowed"),
            # wildcard, odd characters
            ("https://*.example.internal/x", "host"), ("https://asr..example.internal/x", "host"), ("https://-asr.example.internal/x", "host"),
            ("https:///x", "host"), ("https:x", "host"),
            # IP literals, also the forms a resolver reads as an address
            ("https://127.0.0.1/x", "ip_literal"), ("https://10.1.2.3:443/x", "ip_literal"), ("https://[::1]/x", "ip_literal"),
            ("https://[2001:db8::1]:443/x", "ip_literal"), ("https://2130706433/x", "ip_literal"), ("https://0x7f.1/x", "ip_literal"),
            ("https://127.1/x", "ip_literal"),
            # a trailing dot
            ("https://asr.example.internal./v1/chunk", "trailing_dot"),
            # IDNA look-alikes of the allowed name
            ("https://xn--sr-9ba.example.internal/x", "host_not_allowed"), ("https://xn--asr-9ba.example.internal/x", "host_not_allowed"),
            ("https://аsr.example.internal/x", "host_not_allowed"),        # Cyrillic a
            ("https://asr.acme.intеrnal/x", "host_not_allowed"),        # Cyrillic e
            # port
            ("https://asr.example.internal:8443/x", "port"), ("https://asr.example.internal:444/x", "port"),
            ("https://asr.example.internal:80/x", "port"), ("https://asr.example.internal:0/x", "port"),
            ("https://asr.example.internal:99999/x", "port"), ("https://asr.example.internal:abc/x", "port"),
            # the URL itself
            ("", "url"), (None, "url"), (123, "url"), ("https://asr.example.internal/x y", "url"),
            ("https://asr.example.internal/\r\nHost: evil.test", "url"), ("https://asr.example.internal/x#frag", "url"),
            ("https://asr.example.internal\\@evil.test/x", "url"), ("https://asr.example.internal/é", "url"),
            ("https://asr.example.internal/" + "a" * 3000, "url"), ("https://[::1/x", "url"),
        ]
        for url, code in cases:
            with self.subTest(url=url):
                self.assertDenied(url, code)

    def test_a_denial_message_is_fixed_text_without_the_url_or_the_credentials_in_it(self):
        exc = self.assertDenied("https://user:hunter2-pass@asr.example.internal/v1/chunk?token=SECRETVALUE", "userinfo")
        for text in (str(exc), repr(exc), "".join(traceback.format_exception(exc))):
            for needle in ("hunter2", "SECRETVALUE", "evil", "asr.example.internal"):
                self.assertNotIn(needle, text)
        self.assertEqual(str(exc), "egress userinfo: credentials inside the URL are not allowed")
        self.assertEqual((exc.code, exc.status), ("userinfo", None))

    def test_a_listed_host_with_the_right_port_goes_through_and_the_transport_gets_the_rule_not_the_url(self):
        for url in (URL, f"https://{HOST}:443/v1/chunk", "https://ASR.Example.Internal/v1/chunk", f"https://{HOST}/v1/chunk?lang=ko&n=2"):
            with self.subTest(url=url):
                self.transport.calls.clear()
                self.post(url=url)
                call = self.transport.calls[0]
                self.assertEqual((call["rule"].host, call["rule"].port, call["method"]), (HOST, 443, "POST"))
                self.assertTrue(call["target"].startswith("/v1/chunk"))
        self.assertEqual(call["target"], "/v1/chunk?lang=ko&n=2")

    def test_a_non_default_port_is_a_different_destination(self):
        guard = self.make({HOST: HostRule(HOST, port=8443)})
        self.assertDenied(URL, "port", guard=guard)
        guard.request("GET", f"https://{HOST}:8443/v1/health", path_label="health")
        self.assertEqual(self.transport.calls[0]["rule"].port, 8443)

    def test_the_rules_only_hold_hosts_the_policy_left_in(self):
        # SPEC 18: the hosts are (consent or org consent) INTERSECT (policy allowed_hosts); a host the policy excluded is not a rule
        relay, other = HOST, "other.example.internal"
        ca = "a" * 64
        entry = policy.ConsentEntry(id="c-relay", engine="remote", kind="server", host=relay, port=443, region="", model="",
                                    protocol="mcap-asr/1", backend_kind="server", use="both", machine="m" * 64,
                                    granted_at="2026-10-01T09:00:00+09:00", granted_by="tty", expires="2027-10-14", ca_sha256=ca)
        consents = policy.ConsentSet(entries=(entry,), tampered=False, machine="m" * 64)
        now = datetime(2026, 10, 14, 12, 0, 0).astimezone()
        cfg = make_cfg(self.root, asr_remote_url=f"https://{relay}", asr_engine="remote", asr_fallback="none",
                       asr_remote_ca_file=self.root / "relay-ca.pem")

        def decide(allowed_hosts):
            doc = {"schema": 1, "profile": "company", "revision": 3, "lanes": {"asr_remote": "allow"},
                   "asr": {"allowed_engines": ["whisper", "remote"], "allowed_hosts": allowed_hosts}}
            pol = load_test_policy(self.root / "etc" / "policy.json", doc)
            return policy.decide_asr(cfg, pol, policy.LocalOnly(False, "session"), consents, SimpleNamespace(capable=True), now=now)

        excluded = decide([other])
        self.assertEqual((dict(excluded.hosts), excluded.allow_egress), ({}, False))
        self.assertDenied(URL, "host_not_allowed", guard=self.make(excluded.hosts))
        allowed = decide([relay])
        self.assertEqual(sorted(allowed.hosts), [relay])
        self.post(guard=self.make(allowed.hosts))
        self.assertEqual(self.transport.calls[0]["rule"].ca_pem_sha256, ca)

    def test_an_unacceptable_rule_is_ignored_and_never_matches(self):
        with self.assertLogs("mcap.egress", "WARNING") as logs:
            for bad in ("127.0.0.1", "asr.example.internal.", "*.example.internal", "", "asr acme"):
                with self.subTest(rule=bad):
                    guard = self.make({bad: HostRule(bad)})
                    self.assertEqual(guard.hosts, ())
            guard = self.make({"asr.example.internal": HostRule("asr.example.internal", port=70000)})
            self.assertEqual(guard.hosts, ())
            guard = self.make({"other.example.internal": HostRule(HOST)})            # the key must be the rule's host
            self.assertEqual(guard.hosts, ())
            self.assertDenied("https://127.0.0.1/x", "ip_literal", guard=self.make({"127.0.0.1": HostRule("127.0.0.1")}))
        self.assertEqual(len(logs.output), 8)
        self.assertTrue(all(line.endswith("is not acceptable and is ignored") for line in logs.output))
        guard = self.make({"ASR.Example.Internal": HostRule("ASR.Example.Internal")})  # normalised to lower case
        self.assertEqual(guard.hosts, (HOST,))
        self.assertEqual(self.make({}).hosts, ())

    def test_normalize_host_is_idna_and_lower_case(self):
        self.assertEqual(egress.normalize_host("ASR.Example.Internal"), HOST)
        self.assertEqual(egress.normalize_host("bücher.example.test"), "xn--bcher-kva.example.test")
        for bad in ("", None, "a.b.", "1.2.3.4", "::1", "a b.test", "a/b.test", "a:80.test", "*.test", "a..test", "a" * 64 + ".test"):
            with self.subTest(host=bad):
                with self.assertRaises(EgressDenied):
                    egress.normalize_host(bad)

    # ------------------------------------------------------------------------------------------ headers, method, body, timeout
    def test_headers_cannot_smuggle_a_second_request_or_override_the_framing(self):
        bad_headers = [
            {"X-A": "ok\r\nHost: evil.test"}, {"X-A": "line\nbreak"}, {"X-A": "nul\x00byte"}, {"X-A": "café"},
            {"X-A\r\nHost": "evil"}, {"X A": "space in name"}, {"": "empty name"}, {"Host": "evil.test"}, {"host": HOST},
            {"Content-Length": "5"}, {"Transfer-Encoding": "chunked"}, {"Connection": "keep-alive"}, {"Expect": "100-continue"},
            {"Upgrade": "websocket"}, {"Proxy-Authorization": "x"}, {"X-A": "1", "x-a": "2"}, {"X-A": 1}, {1: "x"}, ["X-A", "1"],
            {"Authorization": EVIL_HEADER},
        ]
        for headers in bad_headers:
            with self.subTest(headers=repr(headers)[:50]):
                with self.assertRaises(EgressDenied) as cm:
                    self.post(headers=headers)
                self.assertEqual(cm.exception.code, "bad_request")
                self.assertNotIn("CANARY", str(cm.exception) + repr(cm.exception))
        self.assertEqual(self.transport.calls, [])
        self.post(headers={"Authorization": "Bearer " + CANARY_TOKEN, "X-MCAP-Proto": "mcap-asr/1", "Content-Type": "audio/x-raw"})
        self.assertEqual(self.transport.calls[0]["headers"]["Authorization"], "Bearer " + CANARY_TOKEN)

    def test_only_the_five_plain_methods_are_allowed(self):
        for method in ("CONNECT", "TRACE", "OPTIONS", "PATCH", "", None, 5, "GE T"):
            with self.subTest(method=method):
                with self.assertRaises(EgressDenied) as cm:
                    self.make().request(method, URL, path_label="x")
                self.assertEqual(cm.exception.code, "bad_request")
        self.make().request("post", URL, body=b"x", path_label="x")
        self.assertEqual([c["method"] for c in self.transport.calls], ["POST"])

    def test_request_size_limit_is_checked_before_the_transport(self):
        rule = HostRule(HOST, max_request_bytes=10)
        guard = self.make({HOST: rule})
        self.post(guard=guard, body=b"x" * 10)
        self.transport.calls.clear()
        self.assertDenied(URL, "request_too_large", guard=guard, body=b"x" * 11)
        for body in ("a string", 12, ["x"]):
            with self.assertRaises(EgressDenied) as cm:
                self.post(guard=guard, body=body)
            self.assertEqual(cm.exception.code, "bad_request")
        self.assertEqual(self.transport.calls, [])
        self.post(guard=guard, body=None)                                      # no body is an empty body
        self.post(guard=guard, body=bytearray(b"abc"))
        self.post(guard=guard, body=memoryview(b"abc"))
        self.assertEqual([c["body"] for c in self.transport.calls], [b"", b"abc", b"abc"])

    def test_the_default_request_limit_is_two_and_a_half_megabytes(self):
        self.assertEqual((self.rule.max_request_bytes, self.rule.max_response_bytes), (2_500_000, 262_144))
        self.post(body=b"x" * 2_500_000)
        self.transport.calls.clear()
        self.assertDenied(URL, "request_too_large", body=b"x" * 2_500_001)

    def test_timeout_is_validated_and_capped(self):
        for bad in (0, -1, -0.5, "soon", None, float("nan")):
            with self.subTest(timeout=bad):
                with self.assertRaises(EgressDenied):
                    self.post(timeout=bad)
        self.post(timeout=12.5)
        self.post(timeout=100000)
        self.assertEqual([c["timeout"] for c in self.transport.calls], [12.5, 600.0])

    # ------------------------------------------------------------------------------------------ the answer
    def test_every_redirect_is_refused_and_never_followed(self):
        for status in (300, 301, 302, 303, 305, 307, 308, 399):
            with self.subTest(status=status):
                self.transport.calls.clear()
                self.transport.status = status
                self.transport.headers = {"Location": "https://evil.example.test/steal?t=SECRETVALUE"}
                with self.assertRaises(EgressDenied) as cm:
                    self.post()
                self.assertEqual((cm.exception.code, cm.exception.status), ("redirect", status))
                self.assertEqual(len(self.transport.calls), 1)                      # no second request, to anything
                for text in (str(cm.exception), repr(cm.exception)):
                    self.assertNotIn("evil", text)
                    self.assertNotIn("SECRETVALUE", text)
                self.assertIn(f"HTTP {status}", str(cm.exception))

    def test_other_statuses_are_returned_to_the_caller_untouched(self):
        for status in (200, 204, 400, 401, 403, 404, 409, 413, 429, 500, 503):
            with self.subTest(status=status):
                self.transport.status, self.transport.body = status, b'{"error":"server text"}'
                self.transport.headers = {"Retry-After": "3", "X-Odd": "Value"}
                response = self.post()
                self.assertEqual((response.status, response.body), (status, b'{"error":"server text"}'))
                self.assertEqual(response.headers, {"retry-after": "3", "x-odd": "Value"})        # names are lower-cased

    def test_a_status_outside_100_to_599_is_a_protocol_error(self):
        for status in (0, 99, 600, 1000, -1, True, "200", None):
            with self.subTest(status=status):
                self.transport.status = status
                with self.assertRaises(EgressError) as cm:
                    self.post()
                self.assertEqual(cm.exception.code, "protocol")
                self.assertNotIsInstance(cm.exception, EgressDenied)

    def test_response_size_limit(self):
        rule = HostRule(HOST, max_response_bytes=8)
        guard = self.make({HOST: rule})
        self.transport.body = b"x" * 8
        self.assertEqual(self.post(guard=guard).bytes_in, 8)
        self.transport.body = b"x" * 9
        with self.assertRaises(EgressDenied) as cm:
            self.post(guard=guard)
        self.assertEqual(cm.exception.code, "response_too_large")
        self.assertEqual(self.usage[-1]["outcome"], "denied:response_too_large")
        self.assertEqual(self.usage[-1]["bytes_in"], 9)

    def test_the_response_is_filled_in_by_the_guard(self):
        ticks = iter([10.0, 10.25, 10.5, 10.75, 11.0])
        guard = self.make(clock=lambda: next(ticks))
        self.transport.body = b'{"ok":true}'
        response = guard.request("POST", URL, headers={}, body=b"abcd", path_label="chunk")
        self.assertEqual((response.status, response.bytes_out, response.bytes_in), (200, 4, 11))
        self.assertEqual(response.elapsed_ms, 250)
        self.assertNotIn("ok", repr(response))                                   # the body and the headers are not in the repr
        self.assertIsInstance(response.headers, dict)

    # ------------------------------------------------------------------------------------------ the lane gate
    def test_pre_connect_runs_before_every_attempt_and_before_the_socket(self):
        class LaneDenied(Exception):
            pass

        seen = []
        verdicts = [None, LaneDenied("lane asr_remote is closed"), None]

        def gate():
            seen.append(len(self.transport.calls))
            verdict = verdicts.pop(0)
            if verdict is not None:
                raise verdict

        guard = self.make(pre_connect=gate)
        self.post(guard=guard)                                                 # attempt 1: open
        with self.assertRaises(LaneDenied) as cm:                              # attempt 2: closed since: the caller's exception, unchanged
            self.post(guard=guard)
        self.assertEqual(str(cm.exception), "lane asr_remote is closed")
        self.assertEqual(len(self.transport.calls), 1)                         # nothing was sent for attempt 2
        self.post(guard=guard)                                                 # attempt 3: open again: the gate is not cached
        self.assertEqual(seen, [0, 1, 1])
        self.assertEqual([u["outcome"] for u in self.usage], ["ok", "denied:pre_connect", "ok"])

    def test_pre_connect_is_not_asked_when_the_request_is_invalid(self):
        asked = []
        guard = self.make(pre_connect=lambda: asked.append(1))
        with self.assertRaises(EgressDenied):
            self.post(guard=guard, url="http://" + HOST + "/x")
        self.assertEqual(asked, [])

    # ------------------------------------------------------------------------------------------ transport failures
    def test_transport_exceptions_become_fixed_codes_and_the_original_is_dropped(self):
        secret_text = "CANARY " + CANARY_TOKEN
        cases = [
            (ConnectionRefusedError(61, secret_text), "connect"), (socket.gaierror(8, secret_text), "connect"),
            (BrokenPipeError(secret_text), "connect"), (TimeoutError(secret_text), "timeout"), (socket.timeout(secret_text), "timeout"),
            (ssl.SSLCertVerificationError(1, "hostname '" + secret_text + "' doesn't match"), "tls"), (ssl.SSLError(1, secret_text), "tls"),
            (ValueError("Invalid header value b'" + secret_text + "'"), "bad_request"), (UnicodeEncodeError("ascii", secret_text, 0, 1, "x"), "bad_request"),
            (http.client.InvalidURL("URL can't contain control characters. " + secret_text), "protocol"),
            (http.client.RemoteDisconnected(secret_text), "protocol"), (http.client.IncompleteRead(secret_text.encode()), "protocol"),
            (RuntimeError(secret_text), "transport"), (KeyError(secret_text), "transport"),
        ]
        for exc, code in cases:
            with self.subTest(exc=type(exc).__name__):
                self.transport.exc = exc
                with self.assertRaises(EgressError) as cm:
                    self.post(headers={"Authorization": "Bearer " + CANARY_TOKEN})
                self.assertEqual(cm.exception.code, code)
                self.assertNotIsInstance(cm.exception, EgressDenied)
                self.assertIsNone(cm.exception.__cause__)
                self.assertTrue(cm.exception.__suppress_context__)
                shown = str(cm.exception) + repr(cm.exception) + "".join(traceback.format_exception(cm.exception))
                self.assertNotIn("CANARY", shown)
                self.assertEqual(self.usage[-1]["outcome"], f"error:{code}")

    def test_an_exception_that_is_not_an_error_passes_through(self):
        self.transport.exc = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.post()
        self.assertEqual(self.usage[-1]["outcome"], "error:aborted")

    def test_an_egress_error_from_the_transport_keeps_its_code(self):
        self.transport.exc = EgressDenied("ca_mismatch")
        with self.assertRaises(EgressDenied) as cm:
            self.post()
        self.assertEqual(cm.exception.code, "ca_mismatch")
        self.assertEqual(self.usage[-1]["outcome"], "denied:ca_mismatch")

    def test_map_exception_covers_the_ssl_value_error_overlap(self):
        # SSLCertVerificationError is an SSLError AND a ValueError: it must be 'tls', not 'bad_request'
        self.assertEqual(egress.map_exception(ssl.SSLCertVerificationError()).code, "tls")
        self.assertEqual(egress.map_exception(ConnectionResetError()).code, "connect")
        violation = EgressViolation()
        self.assertIs(egress.map_exception(violation), violation)

    # ------------------------------------------------------------------------------------------ usage and secrets
    def test_the_usage_record_is_content_free(self):
        self.transport.body = b"TRANSCRIPT TEXT"
        self.post(url=f"https://{HOST}/v1/chunk?secret=QUERYVALUE", body=b"AUDIO BYTES",
                  headers={"Authorization": "Bearer " + CANARY_TOKEN}, path_label="chunk")
        record = self.usage[0]
        self.assertEqual(set(record), {"engine", "consent_id", "host", "op", "path_label", "status", "bytes_out", "bytes_in", "dur_ms", "outcome"})
        self.assertEqual((record["engine"], record["consent_id"], record["host"], record["op"], record["path_label"]),
                         ("remote", "org:remote-test", HOST, "POST", "chunk"))
        self.assertEqual((record["status"], record["bytes_out"], record["bytes_in"], record["outcome"]), (200, 11, 15, "ok"))
        flat = repr(record)
        for needle in ("QUERYVALUE", "AUDIO", "TRANSCRIPT", "CANARY", "v1/chunk?"):
            self.assertNotIn(needle, flat)

    def test_usage_outcomes_for_every_kind_of_request(self):
        self.transport.status = 429
        self.post()
        with self.assertRaises(EgressDenied):
            self.post(url="https://evil.example.test/x")
        with self.assertRaises(EgressDenied):
            self.post(url=f"https://{HOST}:99/x")
        self.transport.status = 301
        with self.assertRaises(EgressDenied):
            self.post()
        got = [(u["outcome"], u["host"], u["status"]) for u in self.usage]
        self.assertEqual(got, [("http_429", HOST, 429), ("denied:host_not_allowed", "", 0), ("denied:port", HOST, 0), ("denied:redirect", HOST, 301)])

    def test_a_host_that_is_not_allowed_is_not_written_to_the_usage_record(self):
        with self.assertRaises(EgressDenied):
            self.post(url="https://attacker-chosen.example.test/x")
        self.assertNotIn("attacker", repr(self.usage))

    def test_the_path_label_is_sanitised_and_masked(self):
        apikey.remember(PLAIN_SECRET)
        for label, expected in (("chunk", "chunk"), ("v1/lid", "v1/lid"), ("a b\r\nc", "a?b??c"), ("x" * 100, "x" * 40), ("", "-"), (None, "-"),
                                ("Bearer " + CANARY_TOKEN, "Bearer????"), ("lid-" + PLAIN_SECRET, "lid-sk-ant-???")):
            self.usage.clear()
            self.post(path_label=label)
            self.assertEqual(self.usage[0]["path_label"], expected)
        self.assertNotIn("CANARY", repr(self.usage))

    def test_the_secrets_of_the_engine_are_registered_for_masking_before_the_request(self):
        guard = self.make(secrets=lambda: (PLAIN_SECRET,))
        self.assertIn("CANARY", apikey.redact("t=" + PLAIN_SECRET))                  # not shaped like anything: not known yet
        self.post(guard=guard)
        self.assertNotIn("CANARY", apikey.redact("t=" + PLAIN_SECRET))

    def test_a_failing_secrets_or_usage_callback_never_breaks_a_request(self):
        def boom(*args):
            raise RuntimeError("callback failed with " + CANARY_TOKEN)

        guard = self.make(secrets=boom, usage=boom)
        self.assertEqual(self.post(guard=guard).status, 200)

    def test_the_tripwire_grant_is_open_only_during_the_transport_call(self):
        grants = []

        def handler(rule, *args):
            grants.append([(g.host, g.port) for g in egress._grants()])
            return Response(200, {}, b"", 0, 0, 0)

        self.transport.handler = handler
        self.post()
        self.assertEqual(grants, [[(HOST, 443)]])
        self.assertEqual(egress._grants(), [])
        self.transport.handler = None
        self.transport.exc = RuntimeError("x")
        with self.assertRaises(EgressError):
            self.post()
        self.assertEqual(egress._grants(), [])

    def test_the_default_transport_is_the_https_one(self):
        guard = EgressGuard({HOST: self.rule}, engine_id="remote", consent_id="c")
        with mock.patch.object(HttpsTransport, "send", return_value=Response(204, {}, b"", 0, 0, 0)) as send:
            self.assertEqual(guard.request("GET", f"https://{HOST}/v1/health", path_label="health").status, 204)
        self.assertEqual(send.call_args.args[:3], (self.rule, "GET", "/v1/health"))


# ======================================================================================================================
# EgressGuard: the lane gate that hands a verdict back, and the trust mode of the server tier
# ======================================================================================================================
class GateAndTrustTests(GuardCase):
    def test_a_lane_block_handed_back_by_pre_connect_closes_the_request(self):
        # RunPrivacy.lane_block(lane) and lanes.gate(lane) return a LaneBlock and never raise: passed in as they are they must not fail open
        block = LaneBlock(lane="asr_remote", kind="lane_denied", reason="local_only", message="local-only meeting")
        guard = self.make(pre_connect=lambda: block)
        with self.assertRaises(EgressDenied) as cm:
            self.post(guard=guard)
        self.assertEqual(cm.exception.code, "pre_connect")
        self.assertEqual(len(self.transport.calls), 0)
        self.assertEqual(self.usage[-1]["outcome"], "denied:pre_connect")
        self.assertNotIn("local-only meeting", str(cm.exception) + repr(self.usage))

    def test_any_value_other_than_none_from_pre_connect_is_a_closed_lane(self):
        for verdict in (False, True, 0, "", "ok", object(), (), {}):
            with self.subTest(verdict=repr(verdict)[:20]):
                guard = self.make(pre_connect=lambda verdict=verdict: verdict)
                with self.assertRaises(EgressDenied) as cm:
                    self.post(guard=guard)
                self.assertEqual(cm.exception.code, "pre_connect")
        self.assertEqual(len(self.transport.calls), 0)
        self.assertEqual(self.post(guard=self.make(pre_connect=lambda: None)).status, 200)       # None, and only None, lets it through
        self.assertEqual(len(self.transport.calls), 1)

    def test_a_lane_gate_that_raises_still_propagates_unchanged(self):
        class Closed(Exception):
            pass

        def gate():
            raise Closed("closed")

        with self.assertRaises(Closed):
            self.post(guard=self.make(pre_connect=gate))
        self.assertEqual(self.usage[-1]["outcome"], "denied:pre_connect")

    def test_a_private_trust_guard_refuses_a_rule_without_a_bound_private_ca(self):
        digest = "ab" * 32
        unbound = [HostRule(HOST), HostRule(HOST, ca_file="/etc/mcap/ca.pem"), HostRule(HOST, ca_pem_sha256=digest),
                   HostRule(HOST, ca_file="/etc/mcap/ca.pem", ca_pem_sha256="abc"), HostRule(HOST, ca_file="", ca_pem_sha256=digest),
                   HostRule(HOST, ca_file="/etc/mcap/ca.pem", ca_pem_sha256="zz" * 32), HostRule(HOST, cert_sha256=(digest,))]
        asked = []
        for rule in unbound:
            with self.subTest(rule=rule):
                guard = self.make({HOST: rule}, trust="private", pre_connect=lambda: asked.append(1))
                with self.assertRaises(EgressDenied) as cm:
                    self.post(guard=guard)
                self.assertEqual(cm.exception.code, "ca_unbound")
                self.assertEqual(self.usage[-1]["outcome"], "denied:ca_unbound")
        self.assertEqual(len(self.transport.calls), 0)                                # nothing reached the transport (and no socket)
        self.assertEqual(asked, [])                                                    # ... and the lane gate was not even asked
        self.assertFalse(egress.ca_bound(unbound[0]))

    def test_a_private_trust_guard_lets_a_bound_rule_through_and_the_default_is_unchanged(self):
        digest = "ab" * 32
        for text in (digest, digest.upper(), ":".join(digest[i:i + 2] for i in range(0, 64, 2))):
            rule = HostRule(HOST, ca_file="/etc/mcap/ca.pem", ca_pem_sha256=text)
            self.assertTrue(egress.ca_bound(rule))
            self.assertEqual(self.post(guard=self.make({HOST: rule}, trust="private")).status, 200)
        self.assertEqual(self.post(guard=self.make({HOST: HostRule(HOST)})).status, 200)               # trust "system": a cloud vendor needs none
        self.assertEqual(self.post(guard=self.make({HOST: HostRule(HOST)}, trust="system")).status, 200)

    def test_the_trust_mode_is_checked(self):
        for bad in ("", "PRIVATE", "public", None, True):
            with self.subTest(trust=bad):
                with self.assertRaises(ValueError):
                    self.make(trust=bad)
        self.assertEqual(egress.TRUST_MODES, ("system", "private"))


# ======================================================================================================================
# the TLS context
# ======================================================================================================================
def sha256_of(text: str) -> str:
    return hashlib.sha256(text.encode("ascii")).hexdigest()


class TlsContextTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.pki = write_test_pki(self.root / "pki", "a")
        self.ca_text = TEST_PKI["a"]["cert"]
        self.rule = HostRule(TEST_PKI["a"]["host"], ca_pem_sha256=sha256_of(self.ca_text), ca_file=str(self.pki["cert"]))

    def assertStrict(self, ctx):
        self.assertEqual(ctx.minimum_version, ssl.TLSVersion.TLSv1_2)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)

    def test_a_private_ca_context_trusts_only_that_ca_and_is_strict(self):
        ctx = build_ssl_context(self.rule)
        self.assertStrict(ctx)
        self.assertEqual(ctx.cert_store_stats()["x509_ca"], 1)                  # the one CA of the file: no system store
        self.assertEqual(ctx.cert_store_stats()["x509"], 1)

    def test_the_hashed_bytes_are_the_bytes_that_are_trusted(self):
        # the file is read ONCE: even if another file is put in its place right after, what is loaded is what was hashed
        reads = []
        contents = iter([self.ca_text.encode(), TEST_PKI["b"]["cert"].encode(), TEST_PKI["b"]["cert"].encode()])

        def read_once(path):
            reads.append(path)
            return next(contents)

        loaded = []
        real = ssl.SSLContext.load_verify_locations

        def spy(ctx, *args, **kwargs):
            loaded.append((args, kwargs))
            return real(ctx, *args, **kwargs)

        with mock.patch.object(egress, "_read_ca_bytes", read_once), mock.patch.object(ssl.SSLContext, "load_verify_locations", spy), \
                mock.patch.object(ssl.SSLContext, "load_default_certs", side_effect=AssertionError("system store")), \
                mock.patch.object(ssl.SSLContext, "set_default_verify_paths", side_effect=AssertionError("default paths")):
            build_ssl_context(self.rule)
        self.assertEqual(reads, [str(self.pki["cert"])])
        self.assertEqual(loaded, [((), {"cadata": self.ca_text})])               # cadata with exactly the hashed text: no cafile, no capath

    def test_a_ca_file_that_does_not_match_its_hash_is_refused_before_anything_is_loaded(self):
        other = write_test_pki(self.root / "pki-b", "b")
        rule = dataclasses.replace(self.rule, ca_file=str(other["cert"]))
        with mock.patch.object(ssl.SSLContext, "load_verify_locations", side_effect=AssertionError("loaded")):
            with self.assertRaises(EgressDenied) as cm:
                build_ssl_context(rule)
        self.assertEqual(cm.exception.code, "ca_mismatch")
        self.assertNotIn(str(other["cert"]), str(cm.exception))

    def test_the_hash_may_be_upper_case_or_colon_separated(self):
        digest = sha256_of(self.ca_text)
        for text in (digest.upper(), ":".join(digest[i:i + 2] for i in range(0, 64, 2))):
            self.assertStrict(build_ssl_context(dataclasses.replace(self.rule, ca_pem_sha256=text)))

    def test_a_private_ca_needs_both_a_file_and_a_hash(self):
        digest = sha256_of(self.ca_text)
        for rule in (dataclasses.replace(self.rule, ca_file=None), dataclasses.replace(self.rule, ca_pem_sha256=None),
                     dataclasses.replace(self.rule, ca_pem_sha256="abc"), dataclasses.replace(self.rule, ca_pem_sha256=""),
                     HostRule(HOST, ca_file=str(self.pki["cert"])), HostRule(HOST, ca_pem_sha256=digest)):
            with self.subTest(rule=rule):
                with self.assertRaises(EgressDenied) as cm:
                    build_ssl_context(rule)
                self.assertEqual(cm.exception.code, "ca_unbound")

    def test_an_unusable_ca_file_is_ca_unreadable(self):
        missing = dataclasses.replace(self.rule, ca_file=str(self.root / "nope.pem"))
        garbage = self.root / "garbage.pem"
        garbage.write_text("not a certificate\n", encoding="ascii")
        non_ascii = self.root / "latin.pem"
        non_ascii.write_bytes("café".encode("utf-8"))
        huge = self.root / "huge.pem"
        huge.write_bytes(b"A" * (egress.MAX_CA_BYTES + 1))
        rules = [missing]
        for path in (garbage, non_ascii, huge):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            rules.append(dataclasses.replace(self.rule, ca_file=str(path), ca_pem_sha256=digest))
        for rule in rules:
            with self.subTest(file=rule.ca_file):
                with self.assertRaises(EgressDenied) as cm:
                    build_ssl_context(rule)
                self.assertEqual(cm.exception.code, "ca_unreadable")

    def test_the_environment_and_proxies_have_no_effect_on_the_context(self):
        env = {"HTTPS_PROXY": "http://proxy.example.test:3128", "https_proxy": "http://proxy.example.test:3128",
               "ALL_PROXY": "socks5://proxy.example.test", "SSL_CERT_FILE": str(self.root / "evil.pem"), "SSL_CERT_DIR": str(self.root),
               "REQUESTS_CA_BUNDLE": str(self.root / "evil.pem"), "CURL_CA_BUNDLE": str(self.root / "evil.pem"),
               "SSLKEYLOGFILE": str(self.root / "keys.log"), "NO_PROXY": ""}
        (self.root / "evil.pem").write_text(TEST_PKI["b"]["cert"], encoding="ascii")
        with mock.patch.dict(os.environ, env):
            with mock.patch.object(ssl.SSLContext, "load_default_certs", side_effect=AssertionError("system store")), \
                    mock.patch.object(ssl.SSLContext, "set_default_verify_paths", side_effect=AssertionError("default paths")):
                ctx = build_ssl_context(self.rule)
        self.assertEqual(ctx.cert_store_stats()["x509_ca"], 1)                  # still only the CA file, not SSL_CERT_FILE
        self.assertIsNone(ctx.keylog_filename)                                  # SSLKEYLOGFILE would write the session keys to disk
        self.assertFalse((self.root / "keys.log").exists())

    # ------------------------------------------------------------------------------------------ hosts without a private CA
    def test_a_host_without_a_private_ca_uses_truststore(self):
        class FakeTruststoreContext(ssl.SSLContext):
            pass

        with mock.patch.dict(sys.modules, {"truststore": SimpleNamespace(SSLContext=FakeTruststoreContext)}):
            ctx = build_ssl_context(HostRule("koreacentral.api.cognitive.microsoft.com"))
        self.assertIsInstance(ctx, FakeTruststoreContext)
        self.assertStrict(ctx)

    def test_the_real_truststore_context_is_strict_too(self):
        try:
            import truststore  # noqa: F401
        except ImportError:
            self.skipTest("truststore is not installed here")
        ctx = build_ssl_context(HostRule("koreacentral.api.cognitive.microsoft.com"))
        self.assertStrict(ctx)
        self.assertTrue(type(ctx).__module__.startswith("truststore"))

    def test_without_truststore_the_macos_bundle_is_used_by_explicit_path(self):
        bundle = self.root / "cert.pem"
        bundle.write_text(TEST_PKI["b"]["cert"], encoding="ascii")
        loaded = []
        real = ssl.SSLContext.load_verify_locations

        def spy(ctx, *args, **kwargs):
            loaded.append((args, kwargs))
            return real(ctx, *args, **kwargs)

        for broken in (None, SimpleNamespace(SSLContext=mock.Mock(side_effect=OSError("no keychain")))):
            loaded.clear()
            with mock.patch.dict(sys.modules, {"truststore": broken}), mock.patch.object(egress, "SYSTEM_CA_BUNDLE", str(bundle)), \
                    mock.patch.object(ssl.SSLContext, "load_verify_locations", spy), \
                    mock.patch.dict(os.environ, {"SSL_CERT_FILE": str(self.root / "evil.pem")}):
                ctx = build_ssl_context(HostRule("koreacentral.api.cognitive.microsoft.com"))
            self.assertEqual(loaded, [((), {"cafile": str(bundle)})])
            self.assertStrict(ctx)
            self.assertEqual(ctx.cert_store_stats()["x509_ca"], 1)

    def test_no_truststore_and_no_bundle_is_a_refusal_not_an_open_context(self):
        with mock.patch.dict(sys.modules, {"truststore": None}), mock.patch.object(egress, "SYSTEM_CA_BUNDLE", str(self.root / "absent.pem")):
            with self.assertRaises(EgressDenied) as cm:
                build_ssl_context(HostRule("vendor.example.test"))
        self.assertEqual(cm.exception.code, "no_trust_store")
        self.assertEqual(egress.SYSTEM_CA_BUNDLE, "/etc/ssl/cert.pem")

    # ------------------------------------------------------------------------------------------ a real handshake, in memory
    def test_the_private_ca_context_verifies_the_server_and_its_name(self):
        server = server_context(self.root / "srv", "a")
        client = build_ssl_context(self.rule)
        self.assertIn(memory_handshake(client, server, TEST_PKI["a"]["host"]), ("TLSv1.2", "TLSv1.3"))
        with self.assertRaises(ssl.SSLCertVerificationError):                     # right certificate, wrong name
            memory_handshake(build_ssl_context(self.rule), server, "asr-b.test")

    def test_a_certificate_of_another_ca_is_refused_even_for_the_right_name(self):
        server = server_context(self.root / "srv-b", "b")
        with self.assertRaises(ssl.SSLCertVerificationError):
            memory_handshake(build_ssl_context(self.rule), server, TEST_PKI["b"]["host"])

    def test_a_server_that_only_speaks_old_tls_is_refused(self):
        server = server_context(self.root / "srv-old", "a")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", DeprecationWarning)
                server.minimum_version = ssl.TLSVersion.TLSv1
                server.maximum_version = ssl.TLSVersion.TLSv1_1
        except (ValueError, ssl.SSLError):
            self.skipTest("this OpenSSL cannot be configured for TLS 1.1")
        with self.assertRaises(ssl.SSLError):
            memory_handshake(build_ssl_context(self.rule), server, TEST_PKI["a"]["host"])


# ======================================================================================================================
# HttpsTransport (a fake HTTPSConnection instead of a socket)
# ======================================================================================================================
class FakeResponse:
    def __init__(self, status=200, headers=(), body=b""):
        self.status, self._headers, self._body = status, list(headers), body
        self.reads = []

    def getheaders(self):
        return list(self._headers)

    def read(self, amt=None):
        self.reads.append(amt)
        return self._body if amt is None else self._body[:amt]


class FakeConnection:
    """Stands in for http.client.HTTPSConnection: records everything, opens nothing."""
    instances: list = []
    response = None
    connect_exc = None
    request_exc = None
    response_exc = None
    peer_der = b"leaf-certificate-der"

    def __init__(self, host, port=None, *, timeout=None, context=None, **kw):
        self.host, self.port, self.timeout, self.context, self.kw = host, port, timeout, context, kw
        self.events, self.closed, self.sock = [], False, None
        type(self).instances.append(self)

    def connect(self):
        self.events.append("connect")
        if self.connect_exc:
            raise self.connect_exc
        self.sock = SimpleNamespace(getpeercert=lambda binary_form=False: self.peer_der)

    def request(self, method, target, body=None, headers=None):
        self.events.append("request")
        self.sent = {"method": method, "target": target, "body": body, "headers": dict(headers or {})}
        if self.request_exc:
            raise self.request_exc

    def getresponse(self):
        self.events.append("getresponse")
        if self.response_exc:
            raise self.response_exc
        return self.response

    def close(self):
        self.closed = True


class LostBodyResponse(FakeResponse):
    """An answer whose body is lost to a reset (the server hung up while we were still sending)."""

    def read(self, amt=None):
        self.reads.append(amt)
        raise ConnectionResetError(errno.ECONNRESET, "reset " + CANARY_TOKEN)


class DripConnection(FakeConnection):
    """A connection whose answer never comes: a read blocks on a REAL socket (an AF_UNIX pair, no network) until the watchdog of the
    transport shuts the socket down. ``stage`` is where it hangs: ``headers`` (getresponse) or ``body`` (read)."""
    stage = "headers"

    def connect(self):
        super().connect()
        self.a, self.b = socket.socketpair()
        self.a.settimeout(10)                      # a watchdog that never fires shows up as an error here, not as a hang
        self.sock = self.a

    def getresponse(self):
        self.events.append("getresponse")
        if self.stage == "headers":
            self.a.recv(1)                         # returns b"" once the socket was shut down, like a peer that hung up
            raise http.client.RemoteDisconnected("Remote end closed connection without response")
        sock = self.a
        self.sock = None                           # http.client does this when it hands the connection to an answer (Connection: close)
        return SimpleNamespace(status=200, getheaders=lambda: [("Content-Length", "100")], read=lambda amt=None: sock.recv(1))

    def close(self):
        super().close()
        for name in ("a", "b"):
            with contextlib.suppress(Exception):
                getattr(self, name).close()


class HttpsTransportTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(apikey._known.clear)
        self.conn_cls = type("Conn", (FakeConnection,), {"instances": [], "response": FakeResponse(200, [("Content-Type", "application/json"), ("Retry-After", "2")], b'{"ok":1}'),
                                                       "connect_exc": None, "request_exc": None, "response_exc": None})
        patcher = mock.patch.object(http.client, "HTTPSConnection", self.conn_cls)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.ctx = object()
        self.rule = HostRule(HOST)
        self.transport = HttpsTransport(ssl_context_factory=lambda rule: self.ctx)
        self.usage = []

    def guard(self, rule=None, **kw):
        rule = rule or self.rule
        return EgressGuard({rule.host: rule}, engine_id="remote", consent_id="c", transport=self.transport, usage=self.usage.append, **kw)

    def get(self, rule=None, **kw):
        return self.guard(rule).request("POST", URL, headers={"X-A": "1"}, body=b"pcm", path_label="chunk", **kw)

    def test_the_connection_goes_to_the_rule_with_the_factory_context(self):
        with mock.patch.dict(os.environ, {"HTTPS_PROXY": "http://proxy.example.test:3128", "https_proxy": "http://proxy.example.test:3128",
                                          "ALL_PROXY": "http://proxy.example.test:3128", "NO_PROXY": ""}):
            response = self.get(timeout=12.5)
        conn = self.conn_cls.instances[0]
        self.assertEqual((conn.host, conn.port, conn.timeout, conn.context), (HOST, 443, 12.5, self.ctx))
        self.assertEqual(conn.events, ["connect", "request", "getresponse"])
        self.assertEqual((conn.sent["method"], conn.sent["target"], conn.sent["body"]), ("POST", "/v1/chunk", b"pcm"))
        self.assertEqual(conn.sent["headers"], {"X-A": "1", "Connection": "close"})
        self.assertTrue(conn.closed)
        self.assertEqual((response.status, response.body, response.headers), (200, b'{"ok":1}', {"content-type": "application/json", "retry-after": "2"}))
        self.assertEqual((response.bytes_out, response.bytes_in), (3, 8))

    def test_every_request_is_a_new_connection(self):
        self.get()
        self.get()
        self.assertEqual(len(self.conn_cls.instances), 2)
        self.assertTrue(all(c.closed for c in self.conn_cls.instances))

    def test_a_get_without_a_body_sends_none(self):
        self.guard().request("GET", f"https://{HOST}/v1/health", path_label="health")
        self.assertIsNone(self.conn_cls.instances[0].sent["body"])
        self.guard().request("POST", URL, body=b"", path_label="chunk")
        self.assertEqual(self.conn_cls.instances[1].sent["body"], b"")

    def test_duplicate_response_headers_are_joined(self):
        self.conn_cls.response = FakeResponse(200, [("Set-Cookie", "a=1"), ("set-cookie", "b=2")], b"")
        self.assertEqual(self.get().headers, {"set-cookie": "a=1, b=2"})

    def test_a_redirect_answer_is_refused_by_the_guard_over_the_real_transport(self):
        self.conn_cls.response = FakeResponse(302, [("Location", "https://evil.example.test/")], b"moved")
        with self.assertRaises(EgressDenied) as cm:
            self.get()
        self.assertEqual((cm.exception.code, cm.exception.status), ("redirect", 302))
        self.assertEqual(len(self.conn_cls.instances), 1)

    def test_a_declared_length_over_the_limit_is_refused_without_reading(self):
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "262145")], b"x")
        with self.assertRaises(EgressDenied) as cm:
            self.get()
        self.assertEqual(cm.exception.code, "response_too_large")
        self.assertEqual(self.conn_cls.response.reads, [])

    def test_the_body_is_read_with_a_hard_bound(self):
        limit = self.rule.max_response_bytes
        self.conn_cls.response = FakeResponse(200, [], b"x" * limit)
        self.assertEqual(len(self.get().body), limit)
        self.assertEqual(self.conn_cls.response.reads, [limit + 1])
        self.conn_cls.response = FakeResponse(200, [], b"x" * (limit + 1))                # no Content-Length: the bound still holds
        with self.assertRaises(EgressDenied) as cm:
            self.get()
        self.assertEqual(cm.exception.code, "response_too_large")
        small = HostRule(HOST, max_response_bytes=4)
        self.conn_cls.response = FakeResponse(200, [], b"12345")
        with self.assertRaises(EgressDenied):
            self.get(small)

    def test_a_head_request_reads_no_body(self):
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "10")], b"0123456789")
        self.guard().request("HEAD", f"https://{HOST}/v1/health", path_label="health")
        self.assertEqual(self.conn_cls.response.reads, [])

    def test_failures_are_fixed_codes_and_nothing_of_the_exception_survives(self):
        secret_text = "CANARY " + CANARY_TOKEN
        cases = [
            ("connect_exc", ConnectionRefusedError(61, secret_text), "connect"), ("connect_exc", socket.gaierror(8, secret_text), "connect"),
            ("connect_exc", TimeoutError(secret_text), "timeout"),
            ("connect_exc", ssl.SSLCertVerificationError(1, "certificate for " + secret_text), "tls"),
            ("request_exc", ValueError("Invalid header value b'" + secret_text + "'"), "bad_request"),
            ("request_exc", http.client.InvalidURL("URL can't contain " + secret_text), "protocol"),
            ("request_exc", BrokenPipeError(secret_text), "connect"),
            ("response_exc", http.client.RemoteDisconnected(secret_text), "protocol"),
            ("response_exc", http.client.IncompleteRead(secret_text.encode()), "protocol"),
            ("response_exc", TimeoutError(secret_text), "timeout"),
        ]
        for attribute, exc, code in cases:
            with self.subTest(exc=type(exc).__name__, where=attribute):
                self.conn_cls.connect_exc = self.conn_cls.request_exc = self.conn_cls.response_exc = None
                setattr(self.conn_cls, attribute, exc)
                with self.assertRaises(EgressError) as cm:
                    self.guard(secrets=lambda: (CANARY_TOKEN,)).request("POST", URL, headers={"Authorization": "Bearer " + CANARY_TOKEN},
                                                                        body=b"x", path_label="chunk")
                self.assertEqual(cm.exception.code, code)
                self.assertIsNone(cm.exception.__cause__)
                shown = str(cm.exception) + repr(cm.exception) + "".join(traceback.format_exception(cm.exception))
                self.assertNotIn("CANARY", shown)
                self.assertTrue(self.conn_cls.instances[-1].closed)
        self.assertNotIn("CANARY", repr(self.usage))

    def test_a_context_that_cannot_be_built_stops_before_any_connection_exists(self):
        def refuse(rule):
            raise EgressDenied("ca_mismatch")

        transport = HttpsTransport(ssl_context_factory=refuse)
        guard = EgressGuard({HOST: self.rule}, engine_id="remote", consent_id="c", transport=transport)
        with self.assertRaises(EgressDenied) as cm:
            guard.request("POST", URL, body=b"x", path_label="chunk")
        self.assertEqual(cm.exception.code, "ca_mismatch")
        self.assertEqual(self.conn_cls.instances, [])

    def test_the_default_factory_is_build_ssl_context(self):
        self.assertIs(HttpsTransport()._factory, build_ssl_context)

    def test_the_leaf_certificate_pin_is_checked_before_a_request_byte_is_sent(self):
        digest = hashlib.sha256(FakeConnection.peer_der).hexdigest()
        pinned = HostRule(HOST, cert_sha256=("f" * 64, digest.upper()))
        self.get(pinned)
        self.assertEqual(self.conn_cls.instances[0].events, ["connect", "request", "getresponse"])
        for pins in (("0" * 64,), ("0" * 64, "1" * 64)):
            self.conn_cls.instances.clear()
            with self.assertRaises(EgressDenied) as cm:
                self.get(HostRule(HOST, cert_sha256=pins))
            self.assertEqual(cm.exception.code, "cert_pin")
            self.assertEqual(self.conn_cls.instances[0].events, ["connect"])              # the connection was dropped before the request
            self.assertTrue(self.conn_cls.instances[0].closed)
        self.conn_cls.instances.clear()
        self.conn_cls.peer_der = b""
        with self.assertRaises(EgressDenied):
            self.get(HostRule(HOST, cert_sha256=("0" * 64,)))
        self.conn_cls.peer_der = FakeConnection.peer_der

    def test_without_a_pin_the_certificate_is_not_looked_at(self):
        self.get()
        self.assertEqual(self.conn_cls.instances[0].events, ["connect", "request", "getresponse"])

    # ------------------------------------------------------------------------------------------ an answer given before the body was read
    def test_an_error_answer_given_before_the_body_was_read_is_returned(self):
        # the server rejects a big chunk at once (busy, token expired, too large) and hangs up: the send fails, the answer is waiting
        for exc in (BrokenPipeError(errno.EPIPE, "x"), ConnectionResetError(errno.ECONNRESET, "y"), ConnectionAbortedError(), ssl.SSLEOFError(8, "EOF"),
                    ssl.SSLZeroReturnError(6, "closed")):
            for status, headers in ((503, [("Retry-After", "7")]), (401, []), (413, []), (429, [("Retry-After", "3")]), (403, [])):
                with self.subTest(exc=type(exc).__name__, status=status):
                    self.conn_cls.instances.clear()
                    self.conn_cls.request_exc = exc
                    self.conn_cls.response = FakeResponse(status, headers, b'{"error":"early"}')
                    response = self.get()
                    self.assertEqual((response.status, response.body), (status, b'{"error":"early"}'))
                    self.assertEqual(response.headers.get("retry-after"), dict(headers).get("Retry-After"))
                    self.assertEqual(self.conn_cls.instances[0].events, ["connect", "request", "getresponse"])
                    self.assertTrue(self.conn_cls.instances[0].closed)
                    self.assertEqual(self.usage[-1]["outcome"], f"http_{status}")

    def test_an_early_answer_that_is_not_an_error_is_not_an_answer(self):
        # a 2xx for a body that did not arrive whole must never count as 'transcribed'; a redirect is not followed through this door either
        for status in (200, 201, 204, 302, 100):
            with self.subTest(status=status):
                self.conn_cls.request_exc = BrokenPipeError(CANARY_TOKEN)
                self.conn_cls.response = FakeResponse(status, [("Location", "https://evil.example.test/")], b"{}")
                with self.assertRaises(EgressError) as cm:
                    self.get()
                self.assertEqual(cm.exception.code, "connect")
                self.assertNotIsInstance(cm.exception, EgressDenied)
                self.assertIsNone(cm.exception.__cause__)
                self.assertNotIn("CANARY", str(cm.exception) + "".join(traceback.format_exception(cm.exception)))

    def test_a_failed_send_with_no_answer_to_read_stays_a_connect_error(self):
        for answer_exc in (http.client.RemoteDisconnected("gone " + CANARY_TOKEN), ConnectionResetError(errno.ECONNRESET, "rst"), TimeoutError("slow"),
                           ssl.SSLError(1, "bad")):
            with self.subTest(exc=type(answer_exc).__name__):
                self.conn_cls.request_exc = BrokenPipeError(errno.EPIPE, "pipe " + CANARY_TOKEN)
                self.conn_cls.response_exc = answer_exc
                with self.assertRaises(EgressError) as cm:
                    self.get()
                self.assertEqual(cm.exception.code, "connect")                             # the error of the SEND, not of the failed look
                self.assertIsNone(cm.exception.__cause__)
                self.assertNotIn("CANARY", str(cm.exception) + "".join(traceback.format_exception(cm.exception)))
                self.assertTrue(self.conn_cls.instances[-1].closed)

    def test_only_a_hang_up_during_the_send_triggers_the_look_for_an_answer(self):
        for exc, code in ((TimeoutError("t"), "timeout"), (ssl.SSLCertVerificationError(1, "cert"), "tls"), (ValueError("bad header"), "bad_request"),
                          (http.client.CannotSendRequest("x"), "protocol")):
            with self.subTest(exc=type(exc).__name__):
                self.conn_cls.instances.clear()
                self.conn_cls.request_exc = exc
                with self.assertRaises(EgressError) as cm:
                    self.get()
                self.assertEqual(cm.exception.code, code)
                self.assertEqual(self.conn_cls.instances[0].events, ["connect", "request"])      # getresponse was never asked

    def test_a_lost_body_after_an_early_answer_still_gives_the_status_and_the_headers(self):
        self.conn_cls.request_exc = BrokenPipeError(errno.EPIPE, "x")
        self.conn_cls.response = LostBodyResponse(503, [("Retry-After", "9"), ("Content-Length", "20")], b"")
        response = self.get()
        self.assertEqual((response.status, response.body, response.headers["retry-after"]), (503, b"", "9"))
        self.conn_cls.request_exc = None                                                     # without an early answer a lost body is an error
        with self.assertRaises(EgressError) as cm:
            self.get()
        self.assertEqual(cm.exception.code, "connect")
        self.assertNotIn("CANARY", str(cm.exception) + "".join(traceback.format_exception(cm.exception)))

    # ------------------------------------------------------------------------------------------ the answer must be complete
    def test_a_body_shorter_than_its_declared_length_is_a_protocol_error(self):
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "10")], b"01234")
        with self.assertRaises(EgressError) as cm:
            self.get()
        self.assertEqual(cm.exception.code, "protocol")
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "5")], b"01234")
        self.assertEqual(self.get().body, b"01234")
        self.conn_cls.response = FakeResponse(204, [("Content-Length", "10")], b"")           # no body by definition
        self.assertEqual(self.get().status, 204)
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "10")], b"0123456789")
        self.assertEqual(self.guard().request("HEAD", f"https://{HOST}/v1/health", path_label="health").body, b"")

    def test_a_declared_length_of_thousands_of_digits_is_too_large_not_a_crash(self):
        self.conn_cls.response = FakeResponse(200, [("Content-Length", "9" * 5000)], b"")
        with self.assertRaises(EgressDenied) as cm:
            self.get()
        self.assertEqual(cm.exception.code, "response_too_large")

    # ------------------------------------------------------------------------------------------ the budget of the whole exchange
    def drip(self, stage):
        conn_cls = type("Drip", (DripConnection,), {"instances": [], "stage": stage})
        patcher = mock.patch.object(http.client, "HTTPSConnection", conn_cls)
        patcher.start()
        self.addCleanup(patcher.stop)
        return conn_cls

    def test_the_timeout_is_the_budget_of_the_whole_exchange_not_of_one_read(self):
        # a server that never finishes its answer is cut off when the budget is spent, however slowly it drips
        for stage in ("headers", "body"):
            with self.subTest(stage=stage):
                conn_cls = self.drip(stage)
                threads_before = threading.active_count()
                started = time.monotonic()
                with self.assertRaises(EgressError) as cm:
                    self.guard().request("POST", URL, body=b"pcm", path_label="chunk", timeout=0.3)
                elapsed = time.monotonic() - started
                self.assertEqual(cm.exception.code, "timeout")
                self.assertNotIsInstance(cm.exception, EgressDenied)
                self.assertGreaterEqual(elapsed, 0.25)
                self.assertLess(elapsed, 5.0)
                self.assertTrue(conn_cls.instances[0].closed)
                self.assertEqual(self.usage[-1]["outcome"], "error:timeout")
                self.assertEqual(threading.active_count(), threads_before)                 # the watchdog is stopped, no timer thread is left

    def test_an_exchange_within_the_budget_is_not_touched_by_the_watchdog(self):
        threads_before = threading.active_count()
        response = self.guard().request("POST", URL, body=b"pcm", path_label="chunk", timeout=30)
        self.assertEqual(response.status, 200)
        self.assertEqual(threading.active_count(), threads_before)
        time.sleep(0.05)
        self.assertEqual(self.conn_cls.instances[0].sock.getpeercert(), FakeConnection.peer_der)    # nothing was shut down

    def test_the_watchdog_shuts_a_real_socket_down_and_says_why(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        a.settimeout(10)
        dog = egress._Watchdog(0.05)
        dog.attach(a)
        dog.start()
        try:
            self.assertEqual(a.recv(1), b"")                                                # blocked until the shutdown
            self.assertTrue(dog.expired.is_set())
            with self.assertRaises(EgressError) as cm:
                dog.check()
            self.assertEqual(cm.exception.code, "timeout")
        finally:
            dog.stop()
        quiet = egress._Watchdog(60)                                                       # stopped long before it fires; not connected yet: no-op
        quiet.start()
        quiet.stop()
        self.assertFalse(quiet.expired.is_set())
        quiet.check()
        egress._Watchdog(0.01).stop()                                                      # never started: still harmless
        late = egress._Watchdog(0.01)                                                      # the budget runs out while connecting: attach() acts at once
        late.start()
        deadline = time.monotonic() + 5
        while not late.expired.is_set() and time.monotonic() < deadline:
            time.sleep(0.01)
        c, d = socket.socketpair()
        self.addCleanup(c.close)
        self.addCleanup(d.close)
        c.settimeout(10)
        late.attach(c)
        self.assertEqual(c.recv(1), b"")
        late.stop()
        egress._Watchdog(0.01).attach(object())                                            # a socket that is none: nothing happens


class StrictResponseTests(unittest.TestCase):
    """The answer parser of HttpsTransport on raw bytes (http.client over an in-memory reader: no socket)."""

    def begin(self, raw: bytes, method="POST"):
        class Sock:
            def makefile(self, mode):
                return io.BytesIO(raw)

        response = egress._StrictResponse(Sock(), method=method)
        response.begin()
        return response

    def test_a_complete_answer_is_parsed_like_http_client_does(self):
        response = self.begin(b"HTTP/1.1 503 Busy\r\nRetry-After: 7\r\nContent-Length: 2\r\n\r\n{}")
        self.assertEqual((response.status, response.getheader("Retry-After"), response.read()), (503, "7", b"{}"))
        self.assertNotIsInstance(response.fp, egress._EofWatch)                          # the plain reader is back for the body

    def test_an_answer_that_ends_inside_the_header_block_is_refused(self):
        for raw in (b"HTTP/1.1 200 OK\r\n", b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n", b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Cut: yes",
                    b"HTTP/1.1 100 Continue\r\nX: y\r\n"):
            with self.subTest(raw=raw):
                with self.assertRaises((http.client.IncompleteRead, http.client.RemoteDisconnected)) as cm:      # both are 'protocol'
                    self.begin(raw)
                self.assertEqual(egress.map_exception(cm.exception).code, "protocol")

    def test_the_status_line_and_headers_are_bounded_in_size(self):
        pad = b"X-Pad: " + b"a" * 1000 + b"\r\n"
        under = b"HTTP/1.1 200 OK\r\n" + pad * 60 + b"Content-Length: 0\r\n\r\n"
        over = b"HTTP/1.1 200 OK\r\n" + pad * 70 + b"Content-Length: 0\r\n\r\n"
        self.assertEqual(self.begin(under).status, 200)
        with self.assertRaises(http.client.LineTooLong):
            self.begin(over)
        self.assertEqual(egress.map_exception(http.client.LineTooLong("header")).code, "protocol")

    def test_a_status_line_without_an_answer_is_still_the_usual_error(self):
        with self.assertRaises(http.client.RemoteDisconnected):
            self.begin(b"")
        with self.assertRaises(http.client.BadStatusLine):
            self.begin(b"garbage\r\n\r\n")


# ======================================================================================================================
# Tripwire
# ======================================================================================================================
class TripwireTests(NoNetworkCase):
    def setUp(self):
        super().setUp()
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        self.stubs = stack.enter_context(SocketStubs({"asr.example.test": "198.51.100.7"}))
        self.addCleanup(Tripwire.uninstall_all)              # registered after the stubs: runs before they are removed
        self.addCleanup(Tripwire.reset_audit)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.addCleanup(self.udp.close)
        self.udp6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        self.addCleanup(self.udp6.close)
        self.unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.unix.close)

    def outbound_calls(self):
        """Every way a Python program can reach a non-loopback destination, as (label, callable)."""
        udp, udp6, remote = self.udp, self.udp6, ("203.0.113.5", 53)
        return [
            ("create_connection", lambda: socket.create_connection(("example.test", 443))),
            ("getaddrinfo", lambda: socket.getaddrinfo("example.test", 443)),
            ("getaddrinfo bytes", lambda: socket.getaddrinfo(b"example.test", 443)),
            ("gethostbyname", lambda: socket.gethostbyname("example.test")),
            ("gethostbyname_ex", lambda: socket.gethostbyname_ex("example.test")),
            ("connect", lambda: udp.connect(remote)),
            ("connect_ex", lambda: udp.connect_ex(remote)),
            ("sendto", lambda: udp.sendto(b"x", remote)),
            ("sendto flags", lambda: udp.sendto(b"x", 0, remote)),
            ("sendmsg", lambda: udp.sendmsg([b"x"], [], 0, remote)),
            ("connect v6", lambda: udp6.connect(("2001:db8::1", 53, 0, 0))),
            ("sendto v6", lambda: udp6.sendto(b"x", ("2001:db8::1", 53, 0, 0))),
            ("connect ipv4-mapped", lambda: udp6.connect(("::ffff:203.0.113.5", 53, 0, 0))),
        ]

    def test_strict_refuses_every_outbound_call_before_it_reaches_the_socket(self):
        Tripwire.install("strict")
        for label, call in self.outbound_calls():
            with self.subTest(call=label):
                with self.assertRaises(EgressViolation) as cm:
                    call()
                self.assertEqual(cm.exception.code, "tripwire")
                self.assertEqual(str(cm.exception), "egress tripwire: an outbound connection was blocked")
        self.assertEqual(self.stubs.calls, [])

    def test_loopback_and_unix_sockets_are_never_blocked(self):
        Tripwire.install("strict")
        self.udp.connect(("127.0.0.1", 9))
        self.udp.connect_ex(("127.0.0.1", 9))
        self.udp.sendto(b"x", ("127.0.0.1", 9))
        self.udp.sendto(b"x", 0, ("localhost", 9))
        self.udp.sendmsg([b"x"], [], 0, ("127.0.0.1", 9))
        self.udp.sendmsg([b"x"])                                       # connected send: no address, nothing new to judge
        self.udp6.connect(("::1", 9, 0, 0))
        self.udp6.connect(("::ffff:127.0.0.1", 9, 0, 0))
        self.unix.connect("/var/run/some.sock")
        self.unix.sendto(b"x", "/var/run/other.sock")
        socket.getaddrinfo("localhost", 80)
        socket.getaddrinfo("127.0.0.1", 80)
        socket.getaddrinfo("::1", 80)
        socket.getaddrinfo(None, 80)
        socket.gethostbyname("localhost")
        socket.create_connection(("127.0.0.1", 1))
        self.assertEqual(len(self.stubs.calls), 16)

    def test_audit_lets_the_call_through_and_only_counts_and_warns_by_a_host_hash(self):
        Tripwire.install("audit")
        with self.assertLogs("mcap.egress", "WARNING") as logs:
            for label, call in self.outbound_calls()[:3]:
                call()
            self.udp.connect(("203.0.113.5", 53))
        self.assertEqual(self.stubs.names(), ["create_connection", "getaddrinfo", "getaddrinfo", "connect"])     # nothing was blocked
        digest = hashlib.sha256(b"example.test").hexdigest()[:8]
        counts = Tripwire.audit_counts()
        self.assertEqual(counts[digest], 3)
        self.assertEqual(counts[hashlib.sha256(b"203.0.113.5").hexdigest()[:8]], 1)
        text = "\n".join(logs.output)
        self.assertIn(digest, text)
        for needle in ("example.test", "203.0.113.5"):
            self.assertNotIn(needle, text)                                                                      # the host itself is never logged
        self.assertEqual(len(logs.output), 2)                                                                   # first sight of each hash only
        Tripwire.reset_audit()
        self.assertEqual(Tripwire.audit_counts(), {})

    def test_an_authorised_destination_is_allowed_only_in_the_granting_thread_and_only_for_its_own_addresses(self):
        wire = Tripwire.install("strict")
        with wire.authorized("asr.example.test", 443):
            socket.getaddrinfo("asr.example.test", 443)
            self.udp.connect(("198.51.100.7", 443))                                      # the address its own lookup returned
            self.udp.sendto(b"x", ("198.51.100.7", 443))
            socket.create_connection(("asr.example.test", 443))
            for label, call in (("another address", lambda: self.udp.connect(("198.51.100.8", 443))),
                                ("another port", lambda: self.udp.connect(("198.51.100.7", 8443))),
                                ("another name", lambda: socket.getaddrinfo("other.example.test", 443)),
                                ("name, another port", lambda: socket.getaddrinfo("asr.example.test", 8443)),
                                ("connect by another name", lambda: socket.create_connection(("other.example.test", 443))),
                                ("sendto another address", lambda: self.udp.sendto(b"x", ("198.51.100.9", 443)))):
                with self.subTest(refused=label):
                    with self.assertRaises(EgressViolation):
                        call()
        with self.assertRaises(EgressViolation):                                         # the grant ended with the block
            self.udp.connect(("198.51.100.7", 443))
        with self.assertRaises(EgressViolation):
            socket.getaddrinfo("asr.example.test", 443)

    def test_the_grant_does_not_leak_into_another_thread(self):
        wire = Tripwire.install("strict")
        inside, finish, outcome = threading.Event(), threading.Event(), {}

        def worker():
            with wire.authorized("asr.example.test", 443):
                socket.getaddrinfo("asr.example.test", 443)
                outcome["worker"] = "allowed"
                inside.set()
                finish.wait(5)

        thread = threading.Thread(target=worker)
        thread.start()
        try:
            self.assertTrue(inside.wait(5))
            with self.assertRaises(EgressViolation):                                     # same name, same port, but not this thread's grant
                socket.getaddrinfo("asr.example.test", 443)
            with self.assertRaises(EgressViolation):
                self.udp.connect(("198.51.100.7", 443))

            def other_thread():
                try:
                    socket.getaddrinfo("asr.example.test", 443)
                    outcome["other"] = "allowed"
                except EgressViolation:
                    outcome["other"] = "refused"

            probe = threading.Thread(target=other_thread)
            probe.start()
            probe.join(5)
        finally:
            finish.set()
            thread.join(5)
        self.assertEqual(outcome, {"worker": "allowed", "other": "refused"})

    def test_nested_grants_each_cover_their_own_destination(self):
        wire = Tripwire.install("strict")
        with wire.authorized("asr.example.test", 443):
            with wire.authorized("other.example.test", 8443):
                socket.getaddrinfo("asr.example.test", 443)
                socket.getaddrinfo("other.example.test", 8443)
            with self.assertRaises(EgressViolation):
                socket.getaddrinfo("other.example.test", 8443)
            socket.getaddrinfo("asr.example.test", 443)
        self.assertEqual(egress._grants(), [])

    def test_the_stdlib_create_connection_runs_through_the_grant(self):
        with mock.patch.object(socket, "create_connection", REAL_CREATE_CONNECTION):    # the real one, on top of the recorders
            wire = Tripwire.install("strict")
            with self.assertRaises(EgressViolation):                                     # no grant: refused by name, before any lookup
                socket.create_connection(("asr.example.test", 443), 1)
            self.assertEqual(self.stubs.calls, [])
            with wire.authorized("asr.example.test", 443):
                sock = socket.create_connection(("asr.example.test", 443), 1)            # real create_connection -> getaddrinfo -> connect
                sock.close()
            wire.uninstall()
        self.assertEqual(self.stubs.names(), ["getaddrinfo", "connect"])
        self.assertEqual(self.stubs.calls[1][1], (("198.51.100.7", 443),))

    def test_installs_are_reference_counted_and_restore_the_originals(self):
        before = {name: getattr(socket.socket, name) for name in ("connect", "connect_ex", "sendto", "sendmsg")}
        before.update({name: getattr(socket, name) for name in ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "create_connection")})
        self.assertFalse(Tripwire.active())
        one = Tripwire.install("strict")
        two = Tripwire.install("strict")
        three = Tripwire.install("audit")
        self.assertTrue(Tripwire.active())
        self.assertIsNot(socket.socket.connect, before["connect"])
        one.uninstall()
        one.uninstall()                                                                  # idempotent: it must not release somebody else's install
        two.uninstall()
        self.assertTrue(Tripwire.active())
        self.assertEqual(Tripwire.effective_mode(), "audit")                             # only the audit install is left
        three.uninstall()
        self.assertFalse(Tripwire.active())
        self.assertIsNone(Tripwire.effective_mode())
        for name in ("connect", "connect_ex", "sendto", "sendmsg"):
            self.assertIs(getattr(socket.socket, name), before[name], name)
        for name in ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "create_connection"):
            self.assertIs(getattr(socket, name), before[name], name)
        socket.getaddrinfo("example.test", 80)                                           # nothing blocks any more
        self.assertEqual(self.stubs.names(), ["getaddrinfo"])

    def test_the_strictest_live_install_wins_and_a_nested_run_ends_cleanly(self):
        outer = Tripwire.install("audit")
        with self.assertLogs("mcap.egress", "WARNING"):
            socket.getaddrinfo("example.test", 80)                                       # audit: through
        inner = Tripwire.install("strict")
        self.assertEqual(Tripwire.effective_mode(), "strict")
        with self.assertRaises(EgressViolation):
            socket.getaddrinfo("example.test", 80)
        inner.uninstall()
        self.assertEqual(Tripwire.effective_mode(), "audit")
        socket.getaddrinfo("example.test", 80)                                           # audit again (the second sighting is only counted)
        self.assertEqual(sum(Tripwire.audit_counts().values()), 2)
        outer.uninstall()
        self.assertEqual(self.stubs.names(), ["getaddrinfo", "getaddrinfo"])

    def test_a_handle_works_as_a_context_manager_and_the_mode_is_checked(self):
        with Tripwire.install("strict") as wire:
            self.assertIn("strict", repr(wire))
            with self.assertRaises(EgressViolation):
                socket.getaddrinfo("example.test", 80)
        self.assertFalse(Tripwire.active())
        with self.assertRaises(ValueError):
            Tripwire.install("loud")
        self.assertFalse(Tripwire.active())

    def test_a_patch_put_on_top_later_is_left_alone_and_our_wrapper_passes_through(self):
        wire = Tripwire.install("strict")
        mine = socket.socket.connect
        replacement = mock.Mock(return_value=None)
        with mock.patch.object(socket.socket, "connect", replacement):
            wire.uninstall()
            self.assertIs(socket.socket.connect, replacement)                            # not clobbered by our restore
        self.assertIs(socket.socket.connect, mine)                                       # mock put our (now idle) wrapper back
        self.udp.connect(("203.0.113.5", 53))                                            # idle wrapper: no handle, no check
        self.assertEqual(self.stubs.names(), ["connect"])

    def test_authorized_without_an_install_is_a_no_op_and_cleans_up_after_an_exception(self):
        with self.assertRaises(RuntimeError):
            with egress.authorized("asr.example.test", 443):
                self.assertEqual(len(egress._grants()), 1)
                raise RuntimeError("boom")
        self.assertEqual(egress._grants(), [])
        socket.getaddrinfo("asr.example.test", 443)                                      # no tripwire: nothing refused
        self.assertEqual(self.stubs.names(), ["getaddrinfo"])

    def test_a_guard_request_under_a_strict_tripwire_can_reach_only_its_own_host(self):
        wire = Tripwire.install("strict")
        outcomes = []

        def handler(rule, *args):
            socket.getaddrinfo(rule.host, rule.port)
            for name in ("other.example.test", "127.0.0.2.evil.test"):
                try:
                    socket.getaddrinfo(name, rule.port)
                    outcomes.append("allowed")
                except EgressViolation:
                    outcomes.append("refused")
            return Response(200, {}, b"", 0, 0, 0)

        guard = EgressGuard({HOST: HostRule(HOST)}, engine_id="remote", consent_id="c", transport=FakeTransport(handler=handler))
        self.assertEqual(guard.request("GET", f"https://{HOST}/v1/health", path_label="health").status, 200)
        self.assertEqual(outcomes, ["refused", "refused"])
        with self.assertRaises(EgressViolation):
            socket.getaddrinfo(HOST, 443)
        wire.uninstall()


class NoNetworkCaseTests(NoNetworkCase):
    """The base class itself: it must make a non-loopback attempt both fail and show up in the record."""

    def test_a_non_loopback_attempt_is_refused_and_recorded(self):
        with self.expect_network_attempts() as seen:
            with self.assertRaises(ConnectionRefusedError):
                socket.create_connection(("example.test", 443))
            with self.assertRaises(ConnectionRefusedError):
                socket.getaddrinfo("example.test", 443)
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.addCleanup(udp.close)
            with self.assertRaises(ConnectionRefusedError):
                udp.sendto(b"x", ("203.0.113.5", 53))
        self.assertEqual([name for name, _ in seen], ["create_connection", "getaddrinfo", "sendto"])
        self.assertEqual(self.network_attempts, [])

    def test_without_the_expectation_an_attempt_raises_network_attempt_and_is_recorded(self):
        with self.assertRaises(NetworkAttempt):
            socket.gethostbyname("example.test")
        self.assertEqual(len(self.network_attempts), 1)
        self.network_attempts.clear()                                    # this test provoked it on purpose: the cleanup must pass

    def test_the_system_policy_is_isolated_from_the_real_one_and_can_be_pretended(self):
        self.assertFalse(config.system_policy_present())                 # whatever /Library really holds
        self.assertEqual(config.test_hook_env("MCAP_SECURITY_BIN"), os.environ["MCAP_SECURITY_BIN"])
        self.system_policy(True)
        self.assertTrue(config.system_policy_present())
        self.assertIsNone(config.test_hook_env("MCAP_SECURITY_BIN"))     # a managed Mac ignores the test hooks
        self.system_policy(False)
        self.assertFalse(config.system_policy_present())
        self.assertTrue(str(config.POLICY_SYSTEM_PATH).startswith(str(self.root)))

    def test_loopback_and_unix_calls_reach_the_real_functions(self):
        unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(unix.close)
        with self.assertRaises(OSError):                                 # the real connect to a path that does not exist
            unix.connect(str(self.root / "no-such.sock"))
        self.assertEqual(socket.getaddrinfo("127.0.0.1", 80)[0][4][0], "127.0.0.1")
        self.assertEqual(self.network_attempts, [])

    def test_the_real_security_tool_cannot_be_started_even_when_a_policy_is_pretended(self):
        # system_policy(True) un-fakes `security` (a managed Mac ignores $MCAP_SECURITY_BIN): the call that forgot to inject `run` must
        # not reach the Keychain of whoever runs the suite
        cfg = make_cfg(self.root)
        self.assertEqual(apikey.security_bin(), str(self.security.path))
        self.system_policy(True)
        self.assertEqual(apikey.security_bin(), "/usr/bin/security")
        calls = {"lookup": lambda: apikey.lookup(cfg), "forget": lambda: apikey.forget_key(cfg),
                 "status": lambda: asr_creds.secret_status("remote", "asr.example.internal", 443),     # `run=subprocess.run` bound at import
                 "forget_secret": lambda: asr_creds.forget_secret("remote", "asr.example.internal", 443)}
        for name, call in calls.items():
            with self.subTest(call=name):
                with self.assertRaises(RealSecurityAttempt):
                    call()
        with self.assertRaises(RealSecurityAttempt):
            subprocess.run(["/usr/bin/security", "list-keychains"], stdin=subprocess.DEVNULL)
        self.assertEqual(self.security.calls(), [])                                                   # the shim was ignored, as designed

    def test_every_spelling_of_the_real_tool_is_recognised(self):
        link = self.root / "sec-link"
        link.symlink_to("/usr/bin/security")
        for args, executable in ((["/usr/bin/security", "x"], None), (("/usr/bin/security",), None), ("/usr/bin/security find-generic-password", None),
                                 (b"/usr/bin/security x", None), (Path("/usr/bin/security"), None), (["anything"], "/usr/bin/security"),
                                 ([str(link), "x"], None), ([b"/usr/bin/security"], None), ("echo hi; /usr/bin/security x", None),
                                 ([Path("/usr/bin/../bin/security")], None)):
            with self.subTest(args=args, executable=executable):
                self.assertTrue(is_real_security(args, executable))
        with mock.patch.object(shutil, "which", return_value="/usr/bin/security"):                    # a bare name found on PATH
            self.assertTrue(is_real_security(["security", "find-generic-password"]))
        for args in ([str(self.security.path), "x"], ["/bin/echo", "security"], ["/usr/bin/true"], [], "", None, 42, [None]):
            with self.subTest(args=args):
                self.assertFalse(is_real_security(args))

    def test_other_programs_and_the_fake_security_still_start(self):
        done = subprocess.run([sys.executable, "-c", "print('hi')"], stdout=subprocess.PIPE)
        self.assertEqual(done.stdout.strip(), b"hi")
        self.assertEqual(apikey.lookup(make_cfg(self.root)).reason, "missing")                        # the fake security answers (no key stored)
        self.assertEqual(len(self.security.calls()), 1)


if __name__ == "__main__":
    unittest.main()
