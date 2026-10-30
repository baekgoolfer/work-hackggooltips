"""gcal.py: Google Calendar, read-only, for calendar autostart (docs/CALENDAR_AUTOSTART.md): PKCE and the consent URL, the loopback listener, the
owner's OAuth client file, the token in the Keychain, token exchange and refresh, events.list -> the contract, error mapping, the lane gate,
secrecy, and `mcap gcal ...` through cli.main and as a child process.

Everything runs against FAKES: Google is an in-process ``Transport`` (``self.google``; its answers are DOCUMENT-DERIVED fixtures in fixtures/gcal/,
shaped after Google's public reference, never recorded from a real account), the Keychain is a fake `security` executable (``FakeKeychain``: it
also understands ``security -i``), the browser is a function that calls the loopback listener. ``NoNetworkCase`` fails any test that reaches for a
non-loopback socket or starts the real /usr/bin/security. No real account, token, client or event exists here: the only secrets are CANARY values.
"""
import base64
import contextlib
import hashlib
import http.client
import io
import json
import logging
import os
import re
import socket
import subprocess
import sys
import threading
import time
import unittest
from datetime import date, datetime
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlencode, urlsplit

from asr_support import json_response
from gcal_support import (ACCESS, ACCOUNT, CLIENT_SECRET, CODE, NEEDLES, NEW_ACCESS, NEW_REFRESH, NOW, REFRESH, GcalCase, fixture, refresh_doc,
                          token_doc)
from net_guard_support import NoNetworkCase
from notes_cli_support import load_test_policy
from test_lanes import company_doc, set_flag

from mcap import apikey, cli, egress, gcal, lanes, policy, status

PIPELINE_DIR = Path(__file__).resolve().parents[1]
ROOT = PIPELINE_DIR.parent
CONTRACT_KEYS = {"id", "title", "start", "end", "all_day", "declined", "event_type", "guests", "has_conference", "location"}
# fixture events that never reach the answer: cancelled, no start, an invitation the owner declined, an invitation the owner never answered
LEFT_OUT = ("cancelled0one", "no0start", "declined0review", "invite0unanswered")


def query_of(call) -> dict:
    return {k: v[0] for k, v in parse_qs(urlsplit(call.target).query).items()}


# ======================================================================================================================
class PkceAndUrlTests(unittest.TestCase):
    def test_the_verifier_and_the_s256_challenge(self):
        verifier, challenge = gcal.pkce_pair()
        self.assertRegex(verifier, r"^[A-Za-z0-9_-]{43,128}$")
        expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        self.assertEqual(challenge, expected)
        self.assertNotIn("=", challenge)
        self.assertNotEqual(gcal.pkce_pair()[0], verifier)                       # fresh every time

    def test_the_rfc_7636_example_vector(self):
        # RFC 7636 appendix B: the verifier and the challenge it must give (the function under test is the one-line S256 of pkce_pair)
        verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        digest = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        self.assertEqual(digest, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    def test_the_consent_url(self):
        url = gcal.authorization_url("client-1.apps.example", "http://127.0.0.1:51234/", "CHALLENGE", "STATE")
        parts = urlsplit(url)
        self.assertEqual((parts.scheme, parts.netloc, parts.path), ("https", "accounts.google.com", "/o/oauth2/v2/auth"))
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        self.assertEqual(query, {"client_id": "client-1.apps.example", "redirect_uri": "http://127.0.0.1:51234/", "response_type": "code",
                                 "scope": "https://www.googleapis.com/auth/calendar.readonly", "code_challenge": "CHALLENGE",
                                 "code_challenge_method": "S256", "state": "STATE", "access_type": "offline", "prompt": "consent"})
        self.assertNotIn("client_secret", url)

    def test_the_scope_is_exactly_read_only(self):
        self.assertEqual(gcal.SCOPE, "https://www.googleapis.com/auth/calendar.readonly")


# ======================================================================================================================
class LoopbackTests(NoNetworkCase):
    def listen(self, targets, *, state="state-1", timeout_s=5.0):
        """Start the listener, send ``targets`` (paths with query) from a helper thread, wait. -> (("code"|"error", value), [(status, body)], port)."""
        server = gcal.Loopback(state)
        port = server.server_address[1]
        answers = []

        def client():
            for target in targets:
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    conn.request("GET", target)
                    reply = conn.getresponse()
                    answers.append((reply.status, reply.read().decode("utf-8", "replace")))
                    conn.close()
                except (OSError, http.client.HTTPException) as exc:
                    answers.append((type(exc).__name__, ""))

        thread = threading.Thread(target=client)
        thread.start()
        try:
            outcome = ("code", server.wait(timeout_s))
        except gcal.GcalError as exc:
            outcome = ("error", exc.message)
        thread.join(15)
        return outcome, answers, port

    def refused(self, port) -> bool:
        try:
            http.client.HTTPConnection("127.0.0.1", port, timeout=2).request("GET", "/")
        except ConnectionRefusedError:
            return True
        except OSError:
            return True
        return False

    def test_the_answer_with_the_right_state_gives_the_code_and_the_server_closes(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            outcome, answers, port = self.listen(["/?code=abc123&state=state-1&scope=x"])
        self.assertEqual(outcome, ("code", "abc123"))
        self.assertEqual([a[0] for a in answers], [200])
        self.assertTrue(self.refused(port), "the listener is closed after the answer")
        self.assertEqual(err.getvalue(), "")                                       # the default handler logs the request line (the code) to stderr

    def test_it_listens_on_loopback_on_a_random_port(self):
        a, b = gcal.Loopback("s"), gcal.Loopback("s")
        self.addCleanup(a.server_close)
        self.addCleanup(b.server_close)
        self.assertEqual(a.server_address[0], "127.0.0.1")
        self.assertNotEqual(a.server_address[1], b.server_address[1])
        self.assertRegex(a.redirect_uri, r"^http://127\.0\.0\.1:\d+/$")

    def test_another_path_is_a_404_and_does_not_end_the_wait(self):
        outcome, answers, _port = self.listen(["/favicon.ico", "/?code=abc123&state=state-1"])
        self.assertEqual(outcome, ("code", "abc123"))
        self.assertEqual([a[0] for a in answers], [404, 200])

    def test_a_flood_of_wrong_paths_ends_the_wait(self):
        outcome, _answers, _port = self.listen(["/x"] * (gcal.MAX_STRAY_REQUESTS + 4))
        self.assertEqual(outcome[0], "error")
        self.assertIn("not the sign-in answer", outcome[1])

    def test_a_state_mismatch_is_refused_and_nothing_is_echoed(self):
        outcome, answers, port = self.listen(["/?code=abc123&state=OTHERSTATE"])
        self.assertEqual(outcome[0], "error")
        self.assertIn("state", outcome[1])
        self.assertNotIn("abc123", outcome[1])
        self.assertEqual(answers[0][0], 400)
        self.assertNotIn("OTHERSTATE", answers[0][1])                              # the page never reflects the query
        self.assertTrue(self.refused(port))

    def test_no_state_at_all_is_a_mismatch(self):
        outcome, _answers, _port = self.listen(["/?code=abc123"])
        self.assertEqual(outcome[0], "error")
        self.assertIn("state", outcome[1])

    def test_an_error_answer_means_nothing_was_granted(self):
        outcome, answers, _port = self.listen(["/?error=access_denied&state=state-1"])
        self.assertEqual(outcome[0], "error")
        self.assertIn("did not grant", outcome[1])
        self.assertEqual(answers[0][0], 200)

    def test_an_answer_without_a_code_is_an_error(self):
        outcome, _answers, _port = self.listen(["/?state=state-1"])
        self.assertEqual(outcome[0], "error")
        self.assertIn("no authorization code", outcome[1])

    def test_no_answer_in_time_is_a_timeout_and_the_server_closes(self):
        start = time.monotonic()
        outcome, _answers, port = self.listen([], timeout_s=0.3)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(outcome[0], "error")
        self.assertIn("no answer from the browser in time", outcome[1])
        self.assertTrue(self.refused(port))

    def test_a_connection_that_sends_nothing_does_not_hold_the_listener(self):
        server = gcal.Loopback("state-1")
        port = server.server_address[1]
        idle = socket.create_connection(("127.0.0.1", port), timeout=5)       # a browser's speculative pre-connection
        self.addCleanup(idle.close)
        with mock.patch.object(gcal._Callback, "timeout", 0.2):
            with self.assertRaises(gcal.GcalError) as cm:
                server.wait(1.0)
        self.assertIn("no answer", cm.exception.message)


# ======================================================================================================================
class ClientFileTests(GcalCase):
    def test_the_id_and_the_secret_are_read_and_the_secret_is_registered_for_masking(self):
        apikey._known.clear()
        client = gcal.load_client(self.cfg)
        self.assertEqual(client.client_id, "1234567890-abcdefghijklmnop.apps.googleusercontent.com")
        self.assertEqual(client.client_secret, CLIENT_SECRET)
        self.assertNotIn(CLIENT_SECRET, repr(client))
        self.assertNotIn("CANARY", apikey.redact(f"oops {CLIENT_SECRET}"))

    def test_a_missing_file_is_not_configured_with_the_pointer(self):
        gcal.client_path(self.cfg).unlink()
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.load_client(self.cfg)
        self.assertEqual(cm.exception.code, "not_configured")
        self.assertIn("docs/CALENDAR_AUTOSTART.md", cm.exception.message)

    def test_a_file_that_is_not_private_is_refused(self):
        for mode in (0o644, 0o640, 0o604, 0o660, 0o666, 0o620):
            with self.subTest(mode=oct(mode)):
                self.write_client(mode=mode)
                with self.assertRaises(gcal.GcalError) as cm:
                    gcal.load_client(self.cfg)
                self.assertEqual(cm.exception.code, "not_configured")
                self.assertIn("private", cm.exception.message)
                self.assertNotIn("CANARY", cm.exception.message)
        self.write_client(mode=0o600)
        gcal.load_client(self.cfg)                                                  # 0600 is fine
        self.write_client(mode=0o400)
        gcal.load_client(self.cfg)                                                  # so is read-only

    def test_a_symbolic_link_is_refused(self):
        real = self.root / "elsewhere.json"
        real.write_text(json.dumps(fixture("client_installed.json")), encoding="utf-8")
        real.chmod(0o600)
        link = gcal.client_path(self.cfg)
        link.unlink()
        link.symlink_to(real)
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.load_client(self.cfg)
        self.assertEqual(cm.exception.code, "not_configured")

    def test_a_directory_others_can_write_is_refused(self):
        support = Path(self.cfg.support_dir)
        support.chmod(0o775)
        self.addCleanup(support.chmod, 0o755)
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.load_client(self.cfg)
        self.assertIn("folder only you can write", cm.exception.message)

    def test_a_directory_is_not_a_file(self):
        path = gcal.client_path(self.cfg)
        path.unlink()
        path.mkdir()
        with self.assertRaises(gcal.GcalError):
            gcal.load_client(self.cfg)

    def test_a_web_client_is_not_accepted(self):
        self.write_client(fixture("client_web.json"))
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.load_client(self.cfg)
        self.assertEqual(cm.exception.code, "not_configured")
        self.assertIn("Desktop app", cm.exception.message)
        self.assertNotIn("CANARY", cm.exception.message)

    def test_a_damaged_file_is_not_configured_and_never_echoed(self):
        for text in ("{", "[]", "null", json.dumps({"installed": {}}), json.dumps({"installed": {"client_id": "has space"}}),
                     json.dumps({"installed": {"client_id": "id", "client_secret": "bad secret"}}), "x" * (gcal.MAX_CLIENT_FILE_BYTES + 1)):
            with self.subTest(text=text[:30]):
                path = gcal.client_path(self.cfg)
                path.unlink()
                path.write_text(text, encoding="utf-8")
                path.chmod(0o600)
                with self.assertRaises(gcal.GcalError) as cm:
                    gcal.load_client(self.cfg)
                self.assertEqual(cm.exception.code, "not_configured")
                self.assertNotIn("has space", cm.exception.message)

    def test_the_endpoints_in_the_file_are_ignored(self):
        doc = fixture("client_installed.json")
        doc["installed"]["token_uri"] = "https://evil.example.test/token"
        doc["installed"]["auth_uri"] = "https://evil.example.test/auth"
        self.write_client(doc)
        self.sign_in(expires_in=-10)                                                # the access token is stale: a refresh goes to the token host
        self.upcoming()
        self.assertEqual({c.rule.host for c in self.google.calls}, {gcal.TOKEN_HOST, gcal.API_HOST})


# ======================================================================================================================
class TokenStoreTests(GcalCase):
    def test_reading_asks_the_security_tool_with_the_exact_argv(self):
        token = gcal.read_token()
        self.assertEqual((token.refresh, token.access, token.account), (REFRESH, ACCESS, ACCOUNT))
        self.assertEqual(self.keychain.argvs(), [["find-generic-password", "-s", "MeetingCapture Google Calendar token", "-a",
                                                  apikey.keychain_account(), "-w"]])

    def test_the_tool_gets_no_stdin_no_stderr_and_a_minimal_environment(self):
        seen = {}
        real = subprocess.run

        def spy(argv, **kw):
            seen.update(kw)
            return real(argv, **kw)

        gcal.read_token(spy)
        self.assertIs(seen["stdin"], subprocess.DEVNULL)
        self.assertIs(seen["stderr"], subprocess.DEVNULL)
        self.assertEqual(set(seen["env"]), {"HOME", "USER", "PATH", "LANG"})
        self.assertGreater(seen["timeout"], 0)

    def test_the_token_never_prints_itself(self):
        token = gcal.Token(REFRESH, ACCESS, 5, ACCOUNT)
        for text in (repr(token), str(token), f"{token}", repr([token]), "%r" % (token,)):
            self.assertNotIn("CANARY", text)

    def test_no_item_means_sign_in_is_needed(self):
        self.keychain.clear()
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.read_token()
        self.assertEqual(cm.exception.code, "auth_required")
        self.assertIn("gcal auth", cm.exception.message)

    def test_an_item_that_is_not_ours_needs_a_new_sign_in(self):
        for text in ("not json", "[]", json.dumps({"v": 1}), json.dumps({"refresh": ""}), json.dumps({"refresh": 5})):
            with self.subTest(text=text):
                self.keychain.put(text)
                with self.assertRaises(gcal.GcalError) as cm:
                    gcal.read_token()
                self.assertEqual(cm.exception.code, "auth_required")

    def test_data_the_tool_prints_as_hex_is_still_read(self):
        self.keychain.set_mode("hexout")
        self.assertEqual(gcal.read_token().refresh, REFRESH)

    def test_a_keychain_that_cannot_be_read_is_an_api_error(self):
        self.keychain.set_mode("deny")
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.read_token()
        self.assertEqual((cm.exception.code, cm.exception.message), ("api_error", "the Keychain could not be read"))
        self.keychain.set_mode("timeout")
        with mock.patch.object(apikey, "READ_TIMEOUT_S", 0.5):
            with self.assertRaises(gcal.GcalError) as cm:
                gcal.read_token()
        self.assertEqual(cm.exception.code, "api_error")
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "no-such-security")}):
            with self.assertRaises(gcal.GcalError) as cm:
                gcal.read_token()
        self.assertEqual(cm.exception.code, "api_error")

    def test_writing_goes_through_stdin_hex_encoded_and_never_through_argv(self):
        self.keychain.clear()
        token = gcal.Token(NEW_REFRESH, NEW_ACCESS, int(NOW) + 3599, ACCOUNT)
        gcal.write_token(token, verify=True)
        writes = [c for c in self.keychain.calls() if c["argv"][:1] == ["-i"]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["argv"], ["-i"])
        command = writes[0]["stdin"]
        self.assertTrue(command.startswith(f'add-generic-password -U -a "{apikey.keychain_account()}" -s "MeetingCapture Google Calendar token" -X '))
        blob = json.loads(bytes.fromhex(command.split(" -X ")[1].strip()).decode("utf-8"))
        self.assertEqual((blob["refresh"], blob["access"], blob["account"]), (NEW_REFRESH, NEW_ACCESS, ACCOUNT))
        for argv in self.keychain.argvs():
            self.assertFalse(any(n in " ".join(argv) for n in NEEDLES), argv)
        self.assertEqual(self.keychain.stored().refresh, NEW_REFRESH)
        self.assertNotIn("CANARY", command)                                         # hex: not even a plain fragment is on the wire

    def test_the_read_back_catches_an_interactive_write_that_kept_nothing(self):
        self.keychain.clear()
        self.keychain.set_mode("ignore-add")
        with self.assertRaises(gcal.GcalError) as cm:
            gcal.write_token(gcal.Token(NEW_REFRESH, NEW_ACCESS, 5, ACCOUNT), verify=True)
        self.assertEqual((cm.exception.code, cm.exception.message), ("api_error", "the token could not be stored in the Keychain"))

    def test_a_stale_item_is_not_mistaken_for_the_new_one(self):
        self.keychain.set_mode("ignore-add")                                       # the old token stays: the read-back compares the refresh token
        with self.assertRaises(gcal.GcalError):
            gcal.write_token(gcal.Token(NEW_REFRESH, NEW_ACCESS, 5, ACCOUNT), verify=True)

    def test_a_very_long_access_token_is_left_out_not_the_refresh_token(self):
        self.keychain.clear()
        gcal.write_token(gcal.Token(REFRESH, "ya29." + "z" * 5000, 99, ACCOUNT), verify=True)
        stored = self.keychain.stored()
        self.assertEqual((stored.refresh, stored.access, stored.account), (REFRESH, "", ACCOUNT))

    def test_an_account_name_that_cannot_sit_in_the_command_is_refused(self):
        with mock.patch.object(apikey, "keychain_account", return_value='a"b'):
            with self.assertRaises(gcal.GcalError):
                gcal.write_token(gcal.Token(REFRESH))
        self.assertEqual([c for c in self.keychain.calls() if c["argv"][:1] == ["-i"]], [])

    def test_a_missing_tool_is_a_failure_not_a_crash(self):
        with mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.root / "no-such-security")}):
            with self.assertRaises(gcal.GcalError):
                gcal.write_token(gcal.Token(REFRESH))

    def test_forget_deletes_the_item_and_says_so(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gcal.forget_token(), 0)
        self.assertIsNone(self.keychain.stored())
        self.assertIn("Deleted", out.getvalue())
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gcal.forget_token(), 0)                               # a second time: nothing to delete is not a failure
        self.assertIn("Nothing to delete", out.getvalue())
        self.assertEqual(self.keychain.argvs("delete-generic-password")[0],
                         ["delete-generic-password", "-s", "MeetingCapture Google Calendar token", "-a", apikey.keychain_account()])

    def test_forget_reports_a_tool_that_failed(self):
        self.keychain.set_mode("deny")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(gcal.forget_token(), 1)
        self.assertIn("not deleted", err.getvalue())
        self.assertIsNotNone(self.keychain.stored())

    def test_forget_command_points_at_the_google_side_of_the_revocation(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gcal.forget(self.cfg), 0)
        self.assertIn("myaccount.google.com/permissions", out.getvalue())


# ======================================================================================================================
class EventMappingTests(GcalCase):
    def events(self) -> dict:
        result = self.upcoming()
        return {e["id"]: e for e in result["events"]}

    def test_the_shape_is_the_contract(self):
        result = self.upcoming()
        self.assertEqual(set(result), {"schema", "ok", "now", "events"})
        self.assertEqual((result["schema"], result["ok"]), (1, True))
        for event in result["events"]:
            self.assertEqual(set(event), CONTRACT_KEYS)
            self.assertIsInstance(event["all_day"], bool)
            self.assertIsInstance(event["declined"], bool)
            self.assertIsInstance(event["has_conference"], bool)
            self.assertIsInstance(event["guests"], int)
        self.assertEqual(datetime.fromisoformat(result["now"]).timestamp(), int(NOW))
        self.assertIsNotNone(datetime.fromisoformat(result["now"]).utcoffset())      # ISO 8601 with an offset

    def test_cancelled_events_and_events_without_a_readable_start_are_dropped(self):
        events = self.events()
        self.assertEqual(len(events), 15)
        for gone in LEFT_OUT:
            self.assertNotIn(gone, events)

    def test_the_order_of_the_answer_is_kept(self):
        ids = [e["id"] for e in self.upcoming()["events"]]
        expected = [i["id"] for i in self.events_doc["items"] if i["id"] not in LEFT_OUT]
        self.assertEqual(ids, expected)

    def test_a_meeting_with_a_guest_and_a_room(self):
        e = self.events()["mtg0planning0one"]
        self.assertEqual((e["title"], e["guests"], e["declined"], e["has_conference"], e["all_day"], e["event_type"], e["location"]),
                         ("Planning", 1, False, False, False, "default", "Room 4F"))
        self.assertEqual((e["start"], e["end"]), ("2026-10-07T14:00:00+09:00", "2026-10-07T15:00:00+09:00"))

    def test_an_all_day_event_starts_at_local_midnight_with_an_offset(self):
        e = self.events()["allday0offsite"]
        self.assertTrue(e["all_day"])
        self.assertEqual(e["start"], datetime(2026, 10, 7).astimezone().isoformat(timespec="seconds"))
        self.assertEqual(e["end"], datetime(2026, 10, 8).astimezone().isoformat(timespec="seconds"))
        self.assertIsNotNone(datetime.fromisoformat(e["start"]).utcoffset())
        self.assertEqual(e["guests"], 0)

    def test_a_declined_invitation_is_left_out_and_so_is_a_declined_own_event_marked(self):
        self.assertNotIn("declined0review", self.events())                          # an invitation the owner declined: not in the answer at all
        item = next(i for i in self.events_doc["items"] if i["id"] == "declined0review")
        item["organizer"] = item["creator"] = {"email": "owner@example.test", "self": True}
        e = self.events()["declined0review"]                                        # the owner's own event with the owner's decline: marked
        self.assertTrue(e["declined"])
        self.assertEqual(e["guests"], 1)
        self.assertFalse(self.events()["mtg0planning0one"]["declined"])             # accepted

    def test_someone_elses_decline_is_not_mine(self):
        item = next(i for i in self.events_doc["items"] if i["id"] == "mtg0planning0one")
        item["attendees"][1]["responseStatus"] = "declined"
        self.assertFalse(self.events()["mtg0planning0one"]["declined"])

    # ---- an invitation the owner has not accepted never reaches the app (anybody can e-mail an invitation; Google adds it to the calendar by default)
    @staticmethod
    def raw(organizer=None, creator=None, attendees=None, **extra) -> dict:
        event = {"id": "ev1", "status": "confirmed", "summary": "Chat", "start": {"dateTime": "2026-10-07T14:00:00+09:00"},
                 "end": {"dateTime": "2026-10-07T15:00:00+09:00"}}
        for key, value in (("organizer", organizer), ("creator", creator), ("attendees", attendees)):
            if value is not None:
                event[key] = value
        return {**event, **extra}

    @staticmethod
    def stranger(owner_status=None, **owner) -> dict:
        """An invitation from a stranger: the organizer is somebody else; the owner's own entry (when there is one) has this response."""
        attendees = [{"email": "stranger@example.test", "organizer": True, "responseStatus": "accepted"}]
        if owner_status is not None or owner:
            attendees.append({"email": "owner@example.test", "self": True, **({"responseStatus": owner_status} if owner_status else {}), **owner})
        return {"organizer": {"email": "stranger@example.test"}, "creator": {"email": "stranger@example.test"}, "attendees": attendees}

    def test_an_unanswered_invitation_is_left_out(self):
        self.assertNotIn("invite0unanswered", self.events())                        # the fixture: the owner's own entry says needsAction
        self.assertIsNone(gcal.map_event(self.raw(**self.stranger("needsAction"))))

    def test_an_accepted_or_tentative_invitation_is_kept(self):
        for status in ("accepted", "tentative"):
            with self.subTest(status):
                e = gcal.map_event(self.raw(**self.stranger(status)))
                self.assertIsNotNone(e)
                self.assertEqual((e["guests"], e["declined"]), (1, False))

    def test_a_declined_invitation_is_left_out_whoever_sent_it(self):
        self.assertIsNone(gcal.map_event(self.raw(**self.stranger("declined"))))

    def test_the_owners_own_event_is_kept_without_any_attendee(self):
        for who in ("organizer", "creator"):
            with self.subTest(who):
                e = gcal.map_event(self.raw(**{who: {"email": "owner@example.test", "self": True}}))
                self.assertIsNotNone(e)
                self.assertEqual(e["guests"], 0)
        # an event the owner organises keeps its guests, whatever they answered, and the owner's own decline is marked, not hidden
        e = gcal.map_event(self.raw(organizer={"self": True}, attendees=[{"email": "g@example.test", "responseStatus": "needsAction"}]))
        self.assertEqual((e["guests"], e["declined"]), (1, False))

    def test_attendees_without_an_entry_of_the_owner_are_left_out(self):
        self.assertIsNone(gcal.map_event(self.raw(**self.stranger())))
        self.assertIsNone(gcal.map_event(self.raw(organizer={"email": "stranger@example.test"}, attendees=[
            {"email": "a@example.test", "responseStatus": "accepted"}, {"email": "b@example.test", "responseStatus": "accepted"}])))
        self.assertIsNone(gcal.map_event(self.raw()))                               # no organizer, no creator, no attendees: no proof at all

    def test_the_decision_is_strict(self):
        for status, flag in (("accepted", "true"), ("accepted", 1), ("ACCEPTED", True), ("needsActions", True), (None, True)):
            with self.subTest(status=status, flag=flag):
                self.assertIsNone(gcal.map_event(self.raw(**self.stranger(status, self=flag))))
        for organizer in ("self", ["self"], {"self": "true"}, {"self": 1}, {"self": False}, {}, None):
            with self.subTest(organizer=organizer):
                self.assertIsNone(gcal.map_event(self.raw(organizer=organizer, creator=organizer)))

    def test_an_instance_of_a_recurring_event_keeps_its_own_id(self):
        e = self.events()["weeklysync0abc_20261007T050000Z"]
        self.assertEqual((e["title"], e["guests"]), ("Weekly sync", 2))

    def test_conference_detection(self):
        events = self.events()
        for key, why in (("hangout0link", "hangoutLink"), ("confdata0only", "conferenceData"), ("loc0zoom", "a Zoom link in the location"),
                         ("desc0teams", "a Teams link in the description"), ("desc0webex", "a Webex link in the description")):
            with self.subTest(why):
                self.assertTrue(events[key]["has_conference"], why)
        for key in ("desc0words", "mtg0planning0one", "no0attendees"):
            with self.subTest(key):
                self.assertFalse(events[key]["has_conference"], key)               # words are not links

    def test_a_booked_room_or_a_place_outweighs_the_meet_link_google_adds(self):
        """Google Calendar puts a Meet link on most invitations; an in-person meeting with one must still count as one (and an online one must not)."""
        owner = {"email": "owner@example.test", "self": True}
        guest = {"email": "guest@example.test", "responseStatus": "needsAction"}
        meet = {"conferenceData": {"entryPoints": [{"uri": "https://meet.google.com/aaa-bbbb-ccc"}]}}

        def mapped(room=None, location=None, link=True):
            attendees = [{**owner, "organizer": True, "responseStatus": "accepted"}, guest]
            if room is not None:
                attendees.append({"email": "room@resource.example.test", "resource": True, "responseStatus": room})
            extra = {**(meet if link else {}), **({"location": location} if location is not None else {})}
            return gcal.map_event(self.raw(organizer=owner, creator=owner, attendees=attendees, **extra))

        self.assertTrue(mapped()["has_conference"], "a link alone is a call")
        for room in ("accepted", "needsAction", "tentative"):
            with self.subTest(room=room):
                self.assertFalse(mapped(room=room)["has_conference"], "a booked room")
        self.assertTrue(mapped(room="declined")["has_conference"], "a room that declined is no room")
        for place in ("163", "Room 4F", "HQ 5F Soom", "서울 본사 5층 회의실", "Meeting room 3"):
            with self.subTest(place=place):
                self.assertFalse(mapped(location=place)["has_conference"], place)
        for place in ("", "   ", "Zoom", "Online", "online meeting", "Google Meet", "Teams", "Webex", "화상회의", "온라인", "비대면 미팅",
                      "https://zoom.us/j/1", "www.example.test/room", "Remote"):
            with self.subTest(place=place):
                self.assertTrue(mapped(location=place)["has_conference"], repr(place))
        self.assertFalse(mapped(room="accepted", link=False)["has_conference"], "no link, a room: as before")
        self.assertEqual(mapped(room="accepted")["guests"], 1, "a room is still no guest")

    def test_the_link_hosts(self):
        yes = ("https://zoom.us/j/1", "https://acme.zoom.us/j/1", "zoom.com/x", "https://us02web.zoom.us/j/9", "https://x.zoomgov.com/j/1",
               "https://teams.live.com/meet/1", "https://teams.microsoft.com/l/meetup-join/x", "https://meet.google.com/abc-defg-hij",
               "https://acme.webex.com/meet/a", "<a href=\"https://zoom.us/j/1\">")
        no = ("notzoom.us", "zoom.usa", "meet.google.company", "a zoom lens", "Teams of two", "google meet-up", "teams.microsoft.org", "")
        for text in yes:
            self.assertTrue(gcal._CONFERENCE_LINK.search(text), text)
        for text in no:
            self.assertFalse(gcal._CONFERENCE_LINK.search(text), text)

    def test_guests_are_the_attendees_other_than_me_and_rooms(self):
        events = self.events()
        self.assertEqual(events["resources0only"]["guests"], 0)
        self.assertEqual(events["no0attendees"]["guests"], 0)
        self.assertEqual(events["focus0time"]["guests"], 0)

    def test_the_event_type_comes_from_the_api(self):
        events = self.events()
        self.assertEqual(events["focus0time"]["event_type"], "focusTime")
        self.assertEqual(events["ooo0day"]["event_type"], "outOfOffice")
        self.assertEqual(events["mtg0planning0one"]["event_type"], "default")
        self.assertEqual(gcal.map_event({"id": "x", "eventType": "workingLocation", "organizer": {"self": True}, "start": {"date": "2026-10-07"},
                                         "end": {"date": "2026-10-08"}})["event_type"], "workingLocation")
        self.assertEqual(gcal.map_event({"id": "x", "eventType": "no spaces allowed!", "organizer": {"self": True}, "start": {"date": "2026-10-07"},
                                         "end": {"date": "2026-10-08"}})["event_type"], "default")

    def test_a_zulu_time_keeps_its_offset(self):
        e = self.events()["zulu0time"]
        self.assertEqual(datetime.fromisoformat(e["start"]).timestamp(), datetime.fromisoformat("2026-10-07T05:00:00+00:00").timestamp())
        self.assertIsNotNone(datetime.fromisoformat(e["start"]).utcoffset())

    def test_times_without_an_offset_are_read_as_this_macs_zone(self):
        iso, all_day = gcal._when({"dateTime": "2026-10-07T14:00:00"})
        self.assertFalse(all_day)
        self.assertEqual(iso, datetime(2026, 10, 7, 14).astimezone().isoformat(timespec="seconds"))
        self.assertIsNone(gcal._when({"date": "not-a-date"}))
        self.assertIsNone(gcal._when({"dateTime": "garbage"}))
        self.assertIsNone(gcal._when(None))
        self.assertIsNone(gcal._when({}))

    def test_a_title_and_a_location_may_be_missing_or_wrong_typed(self):
        e = gcal.map_event({"id": "x", "summary": 5, "location": ["a"], "attendees": "nope", "organizer": {"self": True},
                            "start": {"date": "2026-10-07"}, "end": {"date": "2026-10-08"}})
        self.assertEqual((e["title"], e["location"], e["guests"]), ("", "", 0))
        for raw in (None, "x", [], {"id": 5, "start": {"date": "2026-10-07"}, "end": {"date": "2026-10-08"}}, {"status": "cancelled", "id": "c"}):
            self.assertIsNone(gcal.map_event(raw))

    def test_an_empty_window_is_an_empty_list(self):
        self.events_doc = fixture("events_empty.json")
        self.assertEqual(self.upcoming()["events"], [])
        self.events_doc = {}                                                        # what a fields mask leaves of an empty answer
        self.assertEqual(self.upcoming()["events"], [])

    def test_an_answer_that_is_not_a_list_of_events_is_an_error(self):
        for doc in ({"items": "nope"}, {"items": {"id": 1}}):
            with self.subTest(doc=doc):
                self.events_doc = doc
                self.assertEqual(self.failure_of().code, "api_error")

    def test_a_body_that_is_not_a_json_object_is_an_error_not_an_empty_list(self):
        for raw in (b"", b"<html>oops</html>", b"[]", b"null"):
            with self.subTest(raw=raw):
                self.google.handler = lambda call, raw=raw: json_response(200, raw=raw)
                self.assertEqual(self.failure_of().code, "api_error")


# ======================================================================================================================
class RequestTests(GcalCase):
    def test_a_fresh_token_costs_one_request_and_no_keychain_write(self):
        self.upcoming()
        self.assertEqual(len(self.google.calls), 1)
        call = self.google.calls[0]
        self.assertEqual((call.method, call.rule.host, call.rule.port, call.path), ("GET", gcal.API_HOST, 443, "/calendar/v3/calendars/primary/events"))
        self.assertEqual(call.header("Authorization"), f"Bearer {ACCESS}")
        self.assertEqual(call.body, b"")
        self.assertEqual(self.keychain.argvs("-i"), [])
        self.assertEqual(len(self.keychain.argvs("find-generic-password")), 1)

    def test_the_query(self):
        self.upcoming()
        self.assertEqual(query_of(self.google.calls[0]), {"timeMin": "2026-10-07T04:45:00Z", "timeMax": "2026-10-07T05:30:00Z",
                                                          "singleEvents": "true", "orderBy": "startTime", "maxResults": "50", "fields": gcal.FIELDS})
        for needed in ("id", "status", "summary", "description", "location", "eventType", "hangoutLink", "conferenceData", "start", "end",
                       "organizer(self)", "creator(self)", "attendees(email,self,resource,responseStatus)"):
            self.assertIn(needed, gcal.FIELDS)

    def test_the_window_follows_the_arguments_and_is_clamped(self):
        self.upcoming(5, 60)
        self.assertEqual({k: v for k, v in query_of(self.google.calls[-1]).items() if k.startswith("time")},
                         {"timeMin": "2026-10-07T04:55:00Z", "timeMax": "2026-10-07T06:00:00Z"})
        self.upcoming(-5, 10 ** 6)
        self.assertEqual({k: v for k, v in query_of(self.google.calls[-1]).items() if k.startswith("time")},
                         {"timeMin": "2026-10-07T05:00:00Z", "timeMax": "2026-10-08T05:00:00Z"})
        self.upcoming("x", None)
        self.assertEqual({k: v for k, v in query_of(self.google.calls[-1]).items() if k.startswith("time")},
                         {"timeMin": "2026-10-07T04:45:00Z", "timeMax": "2026-10-07T05:30:00Z"})

    def test_a_stale_access_token_is_refreshed_cached_and_used(self):
        self.sign_in(expires_in=60)                                                 # inside the skew
        result = self.upcoming()
        self.assertTrue(result["ok"])
        token_call, events_call = self.google.calls
        self.assertEqual((token_call.method, token_call.rule.host, token_call.path), ("POST", gcal.TOKEN_HOST, "/token"))
        self.assertEqual(token_call.header("Content-Type"), "application/x-www-form-urlencoded")
        body = {k: v[0] for k, v in parse_qs(token_call.body.decode("ascii")).items()}
        self.assertEqual(body, {"grant_type": "refresh_token", "refresh_token": REFRESH, "client_id": "1234567890-abcdefghijklmnop.apps.googleusercontent.com",
                                "client_secret": CLIENT_SECRET})
        self.assertEqual(events_call.header("Authorization"), f"Bearer {NEW_ACCESS}")
        stored = self.keychain.stored()
        self.assertEqual((stored.refresh, stored.access, stored.expires_at, stored.account), (REFRESH, NEW_ACCESS, int(NOW) + 3599, ACCOUNT))
        self.assertEqual(self.keychain.argvs("-i"), [["-i"]])

    def test_a_rotated_refresh_token_is_stored(self):
        self.sign_in(expires_in=-5)
        self.google.handler = lambda call: json_response(200, token_doc()) if call.path == "/token" else json_response(200, self.events_doc)
        self.upcoming()
        self.assertEqual(self.keychain.stored().refresh, NEW_REFRESH)

    def test_a_token_without_a_cached_access_token_is_refreshed_first(self):
        self.keychain.put(gcal.Token(REFRESH, "", 0, ACCOUNT).dump(with_access=False))
        self.upcoming()
        self.assertEqual([c.path for c in self.google.calls], ["/token", "/calendar/v3/calendars/primary/events"])

    def test_a_rejected_cached_token_is_refreshed_once_and_the_request_repeated(self):
        script = [json_response(401, {"error": {"code": 401}}), json_response(200, refresh_doc()), json_response(200, self.events_doc)]
        self.google.script = script
        result = self.upcoming()
        self.assertTrue(result["ok"])
        self.assertEqual([c.path for c in self.google.calls], ["/calendar/v3/calendars/primary/events", "/token", "/calendar/v3/calendars/primary/events"])
        self.assertEqual(self.google.calls[2].header("Authorization"), f"Bearer {NEW_ACCESS}")

    def test_two_rejections_need_a_new_sign_in(self):
        self.google.handler = lambda call: json_response(200, refresh_doc()) if call.path == "/token" else json_response(401, {"error": {}})
        error = self.failure_of()
        self.assertEqual(error.code, "auth_required")
        self.assertEqual(len(self.google.calls), 3)

    def test_a_token_that_was_just_refreshed_is_not_refreshed_again_on_a_401(self):
        self.sign_in(expires_in=-5)
        self.google.handler = lambda call: json_response(200, refresh_doc()) if call.path == "/token" else json_response(401, {"error": {}})
        self.assertEqual(self.failure_of().code, "auth_required")
        self.assertEqual([c.path for c in self.google.calls], ["/token", "/calendar/v3/calendars/primary/events"])

    def test_a_cache_that_cannot_be_written_does_not_fail_the_call(self):
        self.sign_in(expires_in=-5)
        self.keychain.set_mode("fail-add")
        with self.assertLogs("mcap.gcal", "WARNING") as logs:
            result = self.upcoming()
        self.assertTrue(result["ok"])
        self.assertNotIn("CANARY", "\n".join(logs.output))

    def test_only_the_two_google_hosts_over_https_are_reachable(self):
        with mock.patch.object(gcal, "EVENTS_URL", "https://evil.example.test/calendar/v3/calendars/primary/events"):
            error = self.failure_of()
        self.assertEqual(error.code, "policy")
        self.assertEqual(self.google.calls, [])
        with mock.patch.object(gcal, "EVENTS_URL", "http://www.googleapis.com/calendar/v3/calendars/primary/events"):
            error = self.failure_of()
        self.assertEqual(error.code, "policy")
        self.assertEqual(self.google.calls, [])
        self.assertNotIn("evil", error.message)
        with mock.patch.object(gcal, "EVENTS_URL", "https://www.googleapis.com:8443/calendar/v3/calendars/primary/events"):
            self.assertEqual(self.failure_of().code, "policy")

    def test_the_rules_carry_size_limits(self):
        self.upcoming()
        rule = self.google.calls[0].rule
        self.assertEqual((rule.max_request_bytes, rule.max_response_bytes), (4096, 4 * 1024 * 1024))
        self.assertIsNone(rule.ca_file)                                              # the system trust store, no private CA


# ======================================================================================================================
class ErrorMappingTests(GcalCase):
    def answers(self, response):
        self.google.handler = lambda call: response(call) if callable(response) else response

    def test_network_failures_are_network_with_a_content_free_message(self):
        for code in ("connect", "timeout", "tls", "protocol", "transport"):
            with self.subTest(code=code):
                self.google.script = [egress.EgressError(code)]
                error = self.failure_of()
                self.assertEqual(error.code, "network")
                self.assertIn(code, error.message)
        self.google.script = [OSError("connection refused: 203.0.113.9 CANARY")]       # a raw exception: still fixed text
        error = self.failure_of()
        self.assertEqual(error.code, "network")
        self.assertNotIn("CANARY", error.message)
        self.assertNotIn("203.0.113.9", error.message)

    def test_server_errors_are_api_errors(self):
        for status_code in (500, 502, 503, 504, 429):
            with self.subTest(status=status_code):
                self.answers(json_response(status_code, {"error": {"message": "CANARY server text"}}))
                error = self.failure_of()
                self.assertEqual(error.code, "api_error")
                self.assertIn(f"HTTP {status_code}", error.message)
                self.assertNotIn("CANARY", error.message)

    def test_a_disabled_api_is_named_and_the_fix_is_in_the_message(self):
        self.answers(json_response(403, fixture("api_error_access_not_configured.json")))
        error = self.failure_of()
        self.assertEqual(error.code, "api_error")
        self.assertIn("accessNotConfigured", error.message)
        self.assertIn("enable the Google Calendar API", error.message)
        self.assertNotIn("project 1", error.message)                                  # the server's sentence is never echoed

    def test_other_client_errors_are_api_errors_with_the_status(self):
        self.answers(json_response(403, fixture("api_error_rate_limit.json")))
        error = self.failure_of()
        self.assertEqual(error.code, "api_error")
        self.assertIn("HTTP 403, rateLimitExceeded", error.message)
        self.answers(json_response(404, {"error": {"status": "NOT FOUND!", "message": "x"}}))
        self.assertEqual(self.failure_of().message, "Google refused the calendar request (HTTP 404)")

    def test_a_redirect_is_never_followed(self):
        self.answers(json_response(302, {}, {"Location": "https://evil.example.test/"}))
        error = self.failure_of()
        self.assertEqual(error.code, "api_error")
        self.assertNotIn("evil", error.message)
        self.assertEqual(len(self.google.calls), 1)

    def test_an_answer_over_the_limit_is_an_api_error(self):
        self.answers(json_response(200, raw=b"{" + b" " * (4 * 1024 * 1024 + 1) + b"}"))
        self.assertEqual(self.failure_of().code, "api_error")

    def test_a_refresh_token_google_no_longer_accepts_needs_a_new_sign_in(self):
        self.sign_in(expires_in=-5)
        self.answers(json_response(400, fixture("token_error_invalid_grant.json")))
        error = self.failure_of()
        self.assertEqual(error.code, "auth_required")
        self.assertIn("gcal auth", error.message)
        self.assertNotIn("Token has been expired", error.message)                     # the server's sentence is not echoed
        self.assertEqual(len(self.google.calls), 1)                                   # no events request without a token

    def test_a_rejected_client_is_auth_required_too(self):
        self.sign_in(expires_in=-5)
        self.answers(json_response(401, fixture("token_error_invalid_client.json")))
        error = self.failure_of()
        self.assertEqual(error.code, "auth_required")
        self.assertIn("google-oauth-client.json", error.message)

    def test_token_endpoint_failures(self):
        self.sign_in(expires_in=-5)
        self.answers(json_response(400, {"error": "invalid_request"}))
        error = self.failure_of()
        self.assertEqual((error.code, error.message), ("api_error", "Google refused the token request (HTTP 400, invalid_request)"))
        self.answers(json_response(503, {}))
        self.assertEqual(self.failure_of().code, "api_error")
        self.answers(json_response(200, {"token_type": "Bearer"}))                    # no access token
        self.assertEqual(self.failure_of().code, "api_error")
        self.answers(json_response(200, raw=b"not json"))
        self.assertEqual(self.failure_of().code, "api_error")
        self.google.script = [egress.EgressError("timeout")]
        self.assertEqual(self.failure_of().code, "network")

    def test_a_missing_client_file_is_not_configured_before_anything_else_happens(self):
        gcal.client_path(self.cfg).unlink()
        self.assertEqual(self.failure_of().code, "not_configured")
        self.assertEqual(self.google.calls, [])
        self.assertEqual(self.keychain.calls(), [])                                   # not even the Keychain was asked

    def test_no_token_is_auth_required_and_nothing_is_sent(self):
        self.keychain.clear()
        self.assertEqual(self.failure_of().code, "auth_required")
        self.assertEqual(self.google.calls, [])

    def test_an_unreadable_keychain_is_an_api_error_and_nothing_is_sent(self):
        self.keychain.set_mode("deny")
        self.assertEqual(self.failure_of().code, "api_error")
        self.assertEqual(self.google.calls, [])

    def test_every_error_is_one_of_the_contract_codes(self):
        self.assertEqual(set(gcal.ERRORS), {"not_configured", "auth_required", "network", "lane_denied", "policy", "api_error"})
        self.assertEqual(gcal.failure("surprise", "x")["error"], "api_error")


# ======================================================================================================================
class LaneTests(GcalCase):
    def org(self, **lanes_):
        doc = company_doc(self.root, lanes={"calendar": "deny", **lanes_})
        return self.put_policy(doc)

    def test_no_policy_and_no_run_is_open(self):
        self.assertIsNone(gcal.lane_block(self.cfg))
        self.assertTrue(self.upcoming()["ok"])

    def test_the_users_own_settings_do_not_close_it(self):
        self.cfg.calendar_lookup = "0"                                               # the claude.ai connector switch: another feature
        self.cfg.local_only_default = True                                           # a default of meetings
        self.assertIsNone(gcal.lane_block(self.cfg))
        self.assertTrue(self.upcoming()["ok"])

    def test_an_organisation_that_denies_the_lane_gives_lane_denied_and_nothing_starts(self):
        with mock.patch.object(status, "load_policy", return_value=self.org()):
            error = self.failure_of()
        self.assertEqual(error.code, "lane_denied")
        self.assertIn("lane 'calendar' is not allowed", error.message)
        self.assertEqual(self.google.calls, [])
        self.assertEqual(self.keychain.calls(), [])

    def test_an_approved_lane_is_open(self):
        with mock.patch.object(status, "load_policy", return_value=self.org(calendar="allow")):
            self.assertTrue(self.upcoming()["ok"])

    def test_a_policy_that_allows_without_an_approval_is_closed(self):
        doc = company_doc(self.root)
        doc["approvals"].pop("calendar")
        with mock.patch.object(status, "load_policy", return_value=self.put_policy(doc)):
            self.assertEqual(self.failure_of().code, "lane_denied")

    def test_a_locked_policy_closes_it(self):
        locked = load_test_policy(self.root / "bad" / "policy.json", "{")
        with mock.patch.object(status, "load_policy", return_value=locked):
            error = self.failure_of()
        self.assertEqual(error.code, "lane_denied")
        self.assertIn("policy-locked", error.message)

    def test_a_local_only_lock_closes_it(self):
        doc = company_doc(self.root, local_only={"locked": True})
        with mock.patch.object(status, "load_policy", return_value=self.put_policy(doc)):
            self.assertEqual(self.failure_of().code, "lane_denied")

    def test_an_active_run_answers_with_its_own_verdict(self):
        set_flag(self.src, True)
        priv = self.resolve()
        with lanes.run_scope(priv):
            error = self.failure_of()
        self.assertEqual(error.code, "lane_denied")
        self.assertIn("local_only", error.message)
        self.assertEqual((self.google.calls, self.keychain.calls()), ([], []))
        self.assertTrue(self.upcoming()["ok"])                                       # the run is over: an explicit command again

    def test_a_check_that_fails_closes_the_lane(self):
        with mock.patch.object(status, "load_policy", side_effect=RuntimeError("boom")):
            block = gcal.lane_block(self.cfg)
        self.assertEqual((block.kind, block.reason), ("lane_denied", "gate-error"))

    def test_the_gate_is_asked_again_before_the_request(self):
        block = policy.LaneBlock("calendar", "lane_denied", "policy-lane", "lane 'calendar' is not allowed: policy-lane")
        with mock.patch.object(gcal, "lane_block", side_effect=[None, block]):
            error = self.failure_of()
        self.assertEqual(error.code, "lane_denied")
        self.assertEqual(self.google.calls, [])

    def test_auth_is_gated_too_and_never_opens_a_browser(self):
        opened = []
        with mock.patch.object(status, "load_policy", return_value=self.org()), contextlib.redirect_stderr(io.StringIO()) as err:
            rc = gcal.authorize(self.cfg, transport=self.google, open_browser=opened.append)
        self.assertEqual(rc, 1)
        self.assertIn("not allowed", err.getvalue())
        self.assertEqual((opened, self.google.calls), ([], []))


# ======================================================================================================================
class AuthTests(GcalCase):
    def setUp(self):
        super().setUp()
        self.keychain.clear()

    def browser(self, *, state=None, query=None):
        """The user's browser: opens the consent URL and lets Google redirect to the loopback listener (code and state of the URL)."""
        seen: dict = {}

        def open_browser(url):
            q = parse_qs(urlsplit(url).query)
            seen["url"], seen["query"] = url, {k: v[0] for k, v in q.items()}
            real = q["state"][0]
            params = ({k: (real if v == "<state>" else v) for k, v in query.items()} if query is not None
                      else {"code": CODE, "state": real if state is None else state})
            port = urlsplit(q["redirect_uri"][0]).port

            def go():
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("GET", "/?" + urlencode(params))
                conn.getresponse().read()
                conn.close()

            thread = threading.Thread(target=go)
            thread.start()
            self.addCleanup(thread.join, 15)

        open_browser.seen = seen
        return open_browser

    def run_auth(self, opener, **kw):
        kw.setdefault("transport", self.google)
        kw.setdefault("clock", lambda: self.now)
        kw.setdefault("timeout_s", 10.0)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = gcal.authorize(self.cfg, open_browser=opener, **kw)
        return rc, out.getvalue(), err.getvalue()

    def test_the_whole_sign_in(self):
        opener = self.browser()
        rc, out, err = self.run_auth(opener)
        self.assertEqual((rc, err), (0, ""))
        query = opener.seen["query"]
        self.assertEqual((query["scope"], query["code_challenge_method"], query["response_type"]), (gcal.SCOPE, "S256", "code"))
        self.assertRegex(query["redirect_uri"], r"^http://127\.0\.0.1:\d+/$")
        self.assertIn(opener.seen["url"], out)                                       # the URL is printed as well as opened
        self.assertIn(f"Signed in as {ACCOUNT}", out)
        token_call, account_call = self.google.calls
        form = {k: v[0] for k, v in parse_qs(token_call.body.decode("ascii")).items()}
        self.assertEqual((token_call.rule.host, token_call.path, form["grant_type"], form["code"], form["redirect_uri"]),
                         (gcal.TOKEN_HOST, "/token", "authorization_code", CODE, query["redirect_uri"]))
        self.assertEqual(form["client_secret"], CLIENT_SECRET)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"].encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        self.assertEqual(challenge, query["code_challenge"])                          # the verifier belongs to the challenge that was sent
        self.assertEqual((account_call.rule.host, account_call.path, account_call.header("Authorization")),
                         (gcal.API_HOST, "/calendar/v3/calendars/primary", f"Bearer {NEW_ACCESS}"))
        self.assertEqual(query_of(account_call), {"fields": "id"})
        stored = self.keychain.stored()
        self.assertEqual((stored.refresh, stored.access, stored.account, stored.expires_at), (NEW_REFRESH, NEW_ACCESS, ACCOUNT, int(NOW) + 3599))
        self.assertEqual(self.keychain.argvs("-i"), [["-i"]])
        self.assertNotIn(NEW_ACCESS, out)
        self.assertNotIn(NEW_REFRESH, out)
        self.assertNotIn(CODE, out)
        self.assertNotIn(form["code_verifier"], out)

    def test_after_the_sign_in_the_events_come_without_a_refresh(self):
        self.run_auth(self.browser())
        self.google.calls.clear()
        self.assertTrue(self.upcoming()["ok"])
        self.assertEqual([c.path for c in self.google.calls], ["/calendar/v3/calendars/primary/events"])

    def test_another_state_stores_nothing_and_exchanges_nothing(self):
        rc, out, err = self.run_auth(self.browser(state="forged"))
        self.assertEqual(rc, 1)
        self.assertIn("state", err)
        self.assertEqual((self.google.calls, self.keychain.stored()), ([], None))
        self.assertNotIn("forged", err)

    def test_declining_stores_nothing(self):
        rc, _out, err = self.run_auth(self.browser(query={"error": "access_denied", "state": "<state>"}))
        self.assertEqual(rc, 1)
        self.assertIn("did not grant", err)
        self.assertEqual((self.google.calls, self.keychain.stored()), ([], None))

    def test_no_answer_is_a_timeout(self):
        rc, _out, err = self.run_auth(lambda url: None, timeout_s=0.3)
        self.assertEqual(rc, 1)
        self.assertIn("no answer from the browser in time", err)
        self.assertIsNone(self.keychain.stored())

    def test_a_browser_that_cannot_be_opened_does_not_crash_the_command(self):
        def broken(url):
            raise RuntimeError("no browser")

        rc, out, _err = self.run_auth(broken, timeout_s=0.3)
        self.assertEqual(rc, 1)
        self.assertIn("paste this address", out)

    def test_a_refused_code_stores_nothing(self):
        self.google.handler = lambda call: json_response(400, fixture("token_error_invalid_grant.json"))
        rc, _out, err = self.run_auth(self.browser())
        self.assertEqual(rc, 1)
        self.assertIn("rejected the sign-in code", err)
        self.assertIsNone(self.keychain.stored())

    def test_a_grant_without_the_read_only_scope_is_refused(self):
        self.google.handler = lambda call: json_response(200, token_doc(scope="openid email"))
        rc, _out, err = self.run_auth(self.browser())
        self.assertEqual(rc, 1)
        self.assertIn("read-only calendar access", err)
        self.assertIsNone(self.keychain.stored())

    def test_a_grant_without_a_refresh_token_is_refused(self):
        self.google.handler = lambda call: json_response(200, refresh_doc())
        rc, _out, err = self.run_auth(self.browser())
        self.assertEqual(rc, 1)
        self.assertIn("no refresh token", err)
        self.assertIsNone(self.keychain.stored())

    def test_a_disabled_calendar_api_is_reported_but_the_token_is_kept(self):
        def google(call):
            if call.path == "/token":
                return json_response(200, token_doc())
            return json_response(403, fixture("api_error_access_not_configured.json"))

        self.google.handler = google
        rc, _out, err = self.run_auth(self.browser())
        self.assertEqual(rc, 1)
        self.assertIn("enable the Google Calendar API", err)
        self.assertIn("The token is stored", err)
        self.assertEqual(self.keychain.stored().refresh, NEW_REFRESH)
        self.assertEqual(self.keychain.stored().account, "")

    def test_a_keychain_that_keeps_nothing_is_an_error(self):
        self.keychain.set_mode("ignore-add")
        rc, _out, err = self.run_auth(self.browser())
        self.assertEqual(rc, 1)
        self.assertIn("could not be stored", err)

    def test_a_missing_client_file_never_opens_a_browser(self):
        gcal.client_path(self.cfg).unlink()
        opened = []
        rc, _out, err = self.run_auth(opened.append)
        self.assertEqual(rc, 1)
        self.assertIn("google-oauth-client.json", err)
        self.assertEqual((opened, self.google.calls), ([], []))

    def test_a_loose_client_file_never_opens_a_browser(self):
        self.write_client(mode=0o644)
        opened = []
        rc, _out, err = self.run_auth(opened.append)
        self.assertEqual((rc, opened), (1, []))
        self.assertIn("private", err)


# ======================================================================================================================
class StatusTests(GcalCase):
    def lines(self, **kw):
        kw.setdefault("clock", lambda: self.now)
        return gcal.status_lines(self.cfg, **kw)

    def test_everything_in_place(self):
        lines, ready = self.lines()
        text = "\n".join(lines)
        self.assertTrue(ready)
        self.assertIn(f"signed in as {ACCOUNT}", text)
        self.assertIn("valid for about 30 more minutes", text)
        self.assertIn("organisation lane: allowed", text)
        self.assertEqual(self.google.calls, [])                                       # no network

    def test_no_secret_is_ever_in_it(self):
        self.sign_in(expires_in=-5)
        self.assertEqual(self.leaks(*self.lines()[0]), [])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gcal.print_status(self.cfg), 0)
        self.assertFalse(any(n in out.getvalue() for n in NEEDLES))
        self.assertIn("ready", out.getvalue())

    def test_an_expired_access_token_is_not_a_problem(self):
        self.sign_in(expires_in=-100)
        lines, ready = self.lines()
        self.assertTrue(ready)
        self.assertIn("renewed from the refresh token", "\n".join(lines))

    def test_each_missing_piece_is_named_and_not_ready(self):
        gcal.client_path(self.cfg).unlink()
        lines, ready = self.lines()
        self.assertFalse(ready)
        self.assertIn("OAuth client file: NOT usable", "\n".join(lines))
        self.write_client()
        self.keychain.clear()
        lines, ready = self.lines()
        self.assertFalse(ready)
        self.assertIn("token:             NOT available", "\n".join(lines))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gcal.print_status(self.cfg), 1)
        self.assertIn("not ready", out.getvalue())

    def test_a_denied_lane_is_shown(self):
        doc = company_doc(self.root, lanes={"calendar": "deny"})
        with mock.patch.object(status, "load_policy", return_value=self.put_policy(doc)):
            lines, ready = self.lines()
        self.assertFalse(ready)
        self.assertIn("DENIED", "\n".join(lines))

    def test_a_token_without_an_account_name_still_reads(self):
        self.keychain.put(gcal.Token(REFRESH, ACCESS, int(NOW) + 1800, "").dump())
        lines, ready = self.lines()
        self.assertTrue(ready)
        self.assertIn("name unknown", "\n".join(lines))


# ======================================================================================================================
class SecrecyTests(GcalCase):
    """The canaries (tokens, client secret, code) are in every flow below; none may reach a log, a file, stdout/stderr, an error or an argv."""

    def test_a_full_life_leaves_no_canary_anywhere(self):
        records = []

        class Catch(logging.Handler):
            def emit(self, record):
                records.append(self.format(record))

        handler = Catch(level=logging.DEBUG)
        logging.getLogger().addHandler(handler)
        old_level = logging.getLogger().level
        logging.getLogger().setLevel(logging.DEBUG)
        self.addCleanup(logging.getLogger().removeHandler, handler)
        self.addCleanup(logging.getLogger().setLevel, old_level)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.keychain.clear()
            opener = AuthTests.browser(self, state=None)
            self.assertEqual(gcal.authorize(self.cfg, transport=self.google, open_browser=opener, clock=lambda: self.now, timeout_s=10.0), 0)
            self.sign_in(expires_in=-5)
            gcal.print_status(self.cfg)
            self.upcoming()
            self.google.script = [egress.EgressError("connect")]
            gcal.print_upcoming(lambda: self.cfg, 15, 30, transport=self.google, clock=lambda: self.now)
            self.google.script = [json_response(400, fixture("token_error_invalid_grant.json"))]
            self.sign_in(expires_in=-5)
            gcal.print_upcoming(lambda: self.cfg, 15, 30, transport=self.google, clock=lambda: self.now)
            gcal.forget(self.cfg)
        shown = out.getvalue() + err.getvalue()
        self.assertFalse(any(n in shown for n in ("CANARY", "ya29.", "1//0g")), shown)
        self.assertFalse(any(n in "\n".join(records) for n in NEEDLES), records)
        self.assertEqual(self.leaks(), [])
        for argv in self.keychain.argvs():
            self.assertFalse(any(n in " ".join(argv) for n in NEEDLES), argv)

    def test_log_masking_knows_the_google_shapes_even_for_values_never_read(self):
        apikey._known.clear()
        gcal.install_redaction()
        gcal.install_redaction()                                                      # idempotent
        text = apikey.redact("a ya29.A0abcdefghijklmnopqrstuvwxyz b 1//0gabcdefghijklmnopqrstuvwxyz c GOCSPX-abcdefghijklmnop d")
        self.assertEqual(text, "a ya29.*** b 1//*** c GOCSPX-*** d")
        self.assertEqual(apikey.redact("see 1//2 and ya29 and https://x.example/1//2"), "see 1//2 and ya29 and https://x.example/1//2")   # ordinary text stays

    def test_values_read_from_the_keychain_are_masked_exactly(self):
        apikey._known.clear()
        gcal.read_token()
        self.assertNotIn("CANARY", apikey.redact(f"x {ACCESS} y {REFRESH}"))

    def test_the_log_filter_masks_a_token_that_slips_into_an_exception(self):
        gcal.install_redaction()
        record = logging.LogRecord("mcap.gcal", logging.WARNING, __file__, 1, "failed with %s", (ACCESS,), None)
        apikey.RedactFilter().filter(record)
        self.assertNotIn("CANARY", record.getMessage())


# ======================================================================================================================
class CliContractTests(GcalCase):
    """`mcap gcal ...` through cli.main: the contract of `upcoming` (ONE JSON object, exit 0, always) and the terminal commands."""

    def setUp(self):
        super().setUp()
        self.config_env = self.root / "config.env"
        self.config_env.write_text(f"SUPPORT_DIR={self.cfg.support_dir}\n", encoding="utf-8")
        patcher = mock.patch.dict(os.environ, {"MCAP_CONFIG": str(self.config_env)})
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(gcal, "default_transport", lambda: self.google)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.keychain.put(gcal.Token(REFRESH, ACCESS, int(time.time()) + 3000, ACCOUNT).dump())          # valid for the REAL clock of cli.main

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def upcoming_cli(self, *extra):
        rc, out, err = self.run_cli("gcal", "upcoming", *extra)
        self.assertEqual(rc, 0, "a non-zero exit means a crash")
        self.assertEqual(out.count("\n"), 1, out)                                        # exactly one line, one object
        self.assertTrue(out.isascii())
        return json.loads(out), out, err

    def test_success_is_one_json_object(self):
        doc, raw, _err = self.upcoming_cli("--from-minutes", "15", "--to-minutes", "30")
        self.assertEqual((doc["schema"], doc["ok"]), (1, True))
        self.assertEqual(len(doc["events"]), 15)
        self.assertEqual({e["title"] for e in doc["events"] if e["id"] == "korean0title"}, {"주간 회의"})        # the title survives the escaping
        self.assertIn("\\u", raw)                                                       # ASCII-only JSON: no locale can break it

    def test_the_window_defaults_and_flags(self):
        with mock.patch.object(gcal, "upcoming", return_value={"schema": 1, "ok": True, "now": "x", "events": []}) as fake:
            self.run_cli("gcal", "upcoming")
            self.run_cli("gcal", "upcoming", "--from-minutes", "5", "--to-minutes", "60")
        self.assertEqual([c.args[1:] for c in fake.call_args_list], [(15, 30), (5, 60)])

    def test_every_failure_is_json_and_exit_zero(self):
        def fresh():
            self.keychain.put(gcal.Token(REFRESH, ACCESS, int(time.time()) + 3000, ACCOUNT).dump())

        steps = [("not_configured", lambda: gcal.client_path(self.cfg).unlink()),
                 ("auth_required", lambda: (self.write_client(), self.keychain.clear())),
                 ("network", lambda: (fresh(), setattr(self.google, "script", [egress.EgressError("connect")]))),
                 ("api_error", lambda: setattr(self.google, "script", [json_response(503, {})]))]
        for expected, setup in steps:
            with self.subTest(expected):
                setup()
                doc, _raw, err = self.upcoming_cli()
                self.assertEqual((doc["schema"], doc["ok"], doc["error"]), (1, False, expected))
                self.assertEqual(set(doc), {"schema", "ok", "error", "message"})
                self.assertFalse(any(n in doc["message"] + err for n in NEEDLES))

    def test_a_denied_lane_is_json_too(self):
        doc = company_doc(self.root, lanes={"calendar": "deny"})
        with mock.patch.object(status, "load_policy", return_value=self.put_policy(doc)):
            result, _raw, _err = self.upcoming_cli()
        self.assertEqual((result["ok"], result["error"]), (False, "lane_denied"))

    def test_a_bug_is_json_and_exit_zero_and_never_prints_its_message(self):
        with mock.patch.object(gcal, "upcoming", side_effect=RuntimeError("Secret Board Meeting title")):
            result, raw, err = self.upcoming_cli()
        self.assertEqual((result["ok"], result["error"], result["message"]), (False, "api_error", "unexpected error"))
        self.assertNotIn("Secret Board Meeting", raw + err)

    def test_a_bad_config_env_is_json_too(self):
        self.config_env.write_text("ASR_RETRY_MAX=abc\n", encoding="utf-8")
        result, _raw, _err = self.upcoming_cli()
        self.assertEqual((result["ok"], result["error"]), (False, "not_configured"))

    def test_titles_are_not_logged_at_any_level(self):
        root = logging.getLogger()
        self.addCleanup(root.setLevel, root.level)
        rc, out, err = self.run_cli("-v", "gcal", "upcoming")
        self.assertEqual(rc, 0)
        titles = {e["title"] for e in json.loads(out)["events"] if len(e["title"]) >= 7}
        self.assertIn("Planning", titles)
        self.assertFalse(any(t in err for t in titles), err)

    def test_status_and_forget_commands(self):
        rc, out, _err = self.run_cli("gcal", "status")
        self.assertEqual(rc, 0)
        self.assertIn(f"signed in as {ACCOUNT}", out)
        rc, out, _err = self.run_cli("gcal", "forget")
        self.assertEqual(rc, 0)
        self.assertIsNone(self.keychain.stored())
        rc, out, _err = self.run_cli("gcal", "status")
        self.assertEqual(rc, 1)

    def test_the_parser(self):
        parser = cli.build_parser()
        args = parser.parse_args(["gcal", "upcoming"])
        self.assertEqual((args.action, args.from_minutes, args.to_minutes), ("upcoming", 15, 30))
        args = parser.parse_args(["gcal", "upcoming", "--from-minutes", "0", "--to-minutes", "120"])
        self.assertEqual((args.from_minutes, args.to_minutes), (0, 120))
        for action in ("auth", "status", "forget"):
            self.assertEqual(parser.parse_args(["gcal", action]).action, action)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["gcal", "delete-everything"])

    def test_as_a_child_process_with_a_c_locale(self):
        """`python -m mcap gcal upcoming` the way the app starts it: no token, so auth_required, as one ASCII JSON line, exit 0."""
        self.keychain.clear()
        env = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "MCAP_CONFIG": str(self.config_env), "MCAP_SECURITY_BIN": str(self.keychain.path),
               "LANG": "C", "LC_ALL": "C", "HF_HUB_OFFLINE": "1"}
        done = subprocess.run([sys.executable, "-m", "mcap", "gcal", "upcoming", "--from-minutes", "15", "--to-minutes", "30"], cwd=PIPELINE_DIR,
                              env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.count("\n"), 1)
        doc = json.loads(done.stdout)
        self.assertEqual((doc["ok"], doc["error"]), (False, "auth_required"))


# ======================================================================================================================
class DocsAndConfigTests(unittest.TestCase):
    """The documentation of the feature and the OFFLINE_* keys (read by the Swift app) stay in step with each other."""
    KEYS = {"OFFLINE_AUTOSTART": "off", "OFFLINE_START_BEFORE_MINUTES": "2", "OFFLINE_START_AFTER_MINUTES": "15",
            "OFFLINE_STOP_AFTER_END_MINUTES": "10", "OFFLINE_IDLE_MAX_MINUTES": "5", "OFFLINE_REQUIRE_GUESTS": "1",
            "OFFLINE_MIN_MINUTES": "10", "OFFLINE_MAX_MINUTES": "240"}

    def read(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_every_offline_key_has_a_row_with_the_contract_default_in_each_table_and_the_example(self):
        example = self.read("config/config.env.example")
        for key, default in self.KEYS.items():
            with self.subTest(key=key):
                self.assertRegex(example, rf"(?m)^# {key}={re.escape(default)}\s*$")          # commented: the feature is off by default
                self.assertNotRegex(example, rf"(?m)^{key}=")
                self.assertRegex(self.read("docs/CONFIGURATION.md"), rf"(?m)^\| `{key}` \| `{re.escape(default)}` \|")
                self.assertRegex(self.read("README.ko.md"), rf"(?m)^\| `{key}` \| `{re.escape(default)}` \|")
                self.assertRegex(self.read("README.md"), rf"(?m)^\| `{key}` \|")

    def test_the_guide_has_the_steps_the_warnings_and_the_revocation(self):
        text = self.read("docs/CALENDAR_AUTOSTART.md")
        for needle in ("calendar.readonly", "google-oauth-client.json", "Desktop app", "python -m mcap gcal auth", "python -m mcap gcal status",
                       "python -m mcap gcal forget", "myaccount.google.com/permissions", "7 days", "Internal", "External", "Test users",
                       "chmod 600", "OFFLINE_AUTOSTART=auto", "consent", "single-user", "only to Google", "nothing is sent", "Google Calendar API"):
            self.assertIn(needle, text, needle)
        self.assertNotIn("sk-ant", text)

    def test_the_privacy_documents_mention_the_calendar_read_access(self):
        for rel in ("docs/PRIVACY_AND_CONSENT.md", "docs/PRIVACY_LANES.md"):
            self.assertIn("CALENDAR_AUTOSTART.md", self.read(rel), rel)
            self.assertIn("calendar.readonly", self.read(rel), rel)

    def test_no_personal_data_in_the_new_files(self):
        for rel in ("pipeline/mcap/gcal.py", "pipeline/tests/test_gcal.py", "pipeline/tests/gcal_support.py", "docs/CALENDAR_AUTOSTART.md"):
            text = self.read(rel)
            self.assertNotRegex(text, r"@(?!example\.(test|com)|resource\.example\.test)[A-Za-z0-9-]+\.[a-z]{2,}", rel)
            self.assertNotIn("/Us" + "ers/", text, rel)


if __name__ == "__main__":
    unittest.main()
