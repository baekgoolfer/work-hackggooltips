"""mcap asr-engines list | check | bench | bench-synth | consent | enroll | revoke | purge | secret, transcribe-file under a policy and the
benchmark script's upload gate (cli.py, scripts/bench_asr.py).

Everything runs through ``cli.main`` against FAKES: the server is an in-process ``Transport`` (``MiniServer``), the Keychain is the fake `security`
(plus ``KeychainRun`` for the one command that goes through ``security -i``), the hardware probe and its benchmark child are a scripted runner, the
local engine a ``FakeLocalEngine``, a terminal is a ``TtyInput``. ``NoNetworkCase`` fails any test that tries a non-loopback socket and any attempt
to start the real /usr/bin/security. The only audio that ever reaches the fake server is a synthetic tone or clip, except in the tests that
confirm real audio on purpose (the file is then a synthetic one of the test's own: no recorded voice is in this suite).

Pinned: consent refused without a TTY, with a wrong sentence, for a policy-denied engine; an organisation consent that needs no TTY; expiry; check
--live and --probe (refused while a recording is live) over the injected transport / runner with a synthetic tone only; the bench upload gate
(--allow-real-audio plus the typed sentence, synthetic clips by default); enroll, revoke, purge and secret with host-bound Keychain items and no
secret in any output; transcribe-file's lane decision."""
import contextlib
import importlib.util
import io
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import unittest
import wave
from datetime import timedelta
from pathlib import Path
from unittest import mock

import numpy as np

from asr_support import (CANARY_FRAGMENTS, CANARY_TEXT, HOST, MACHINE, NOW, TOKEN, AsrCase, FakeCloudEngine, FakeClock, FakeLocalEngine, chunk_answer,
                         consent_entry, error_answer, health_document, json_response, usage_lines)
from notes_cli_support import canary_hits, make_session
from test_status import company_doc, company_org, locked_org, probe, write_usage

from mcap import asr_creds, asr_engines, asr_http, asr_usage, cli, egress, lanes, pipeline, policy, status, wavio

ROOT = Path(__file__).resolve().parents[2]
NEW_TOKEN = "mcap1_11223344_" + "Wx7yZ" * 6 + "cd"
ENROLL_CODE = "GOODCODE1"
SR = 16000


class TtyInput(io.StringIO):
    def isatty(self):
        return True


class MiniServer:
    """The few endpoints these commands use (docs/ASR_PROTOCOL.md): health, chunk, purge, enroll. ``calls`` is the FakeTransport's job."""

    def __init__(self, token: str = TOKEN):
        self.token, self.health, self.purged = token, health_document(), 3

    def __call__(self, call):
        headers = {k.lower(): v for k, v in call.headers.items()}
        if call.path == "/v1/enroll":
            if call.json().get("code") != ENROLL_CODE:
                return error_answer(401, "enroll_invalid", message=CANARY_TEXT)
            return json_response(200, {"token": NEW_TOKEN, "expires": "2027-01-12T12:00:00+09:00", "user": "alice"})
        if headers.get("authorization") != f"Bearer {self.token}":
            return error_answer(401, "unauthorized")
        if call.path == "/v1/health":
            return json_response(200, self.health)
        if call.path == "/v1/chunk":
            return json_response(200, chunk_answer("tone transcript canary", duration=len(call.body) / 32000.0))
        if call.path == "/v1/purge":
            return json_response(200, {"purged": self.purged})
        return error_answer(404, "not_found")


class KeychainRun:
    """``subprocess.run`` for the `security` tool: ``security -i`` (the command on stdin: how an enrolled token is stored) is carried out against the
    fake Keychain, every other call runs the fake shim. ``calls`` records argv and stdin."""

    def __init__(self, case):
        self.case, self.calls = case, []

    def __call__(self, argv, **kw):
        self.calls.append({"argv": list(argv), "input": kw.get("input")})
        if len(argv) >= 2 and argv[1] == "-i":
            words = shlex.split(kw["input"].decode("utf-8"))
            self.case.security.store_item(words[words.index("-w") + 1], words[words.index("-s") + 1], words[words.index("-a") + 1])
            return subprocess.CompletedProcess(argv, 0, stdout=b"", stderr=b"")
        return subprocess.run(argv, **kw)


class ProbeRun:
    """The process runner of the hardware probe: sysctl, ioreg and the benchmark child (``bench-synth``) answer from a script."""

    def __init__(self, rtf=0.12, bench_rc=0):
        self.rtf, self.bench_rc, self.calls = rtf, bench_rc, []

    def __call__(self, argv, **kw):
        self.calls.append(list(argv))
        text = " ".join(str(a) for a in argv)
        out = {"hw.optional.arm64": "1\n", "hw.memsize": f"{32 * 1024 ** 3}\n",
               "ioreg": '"IOPlatformUUID" = "00000000-0000-0000-0000-000000000000"\n'}
        for key, value in out.items():
            if key in text:
                return subprocess.CompletedProcess(argv, 0, stdout=value, stderr="")
        if "bench-synth" in text:
            return subprocess.CompletedProcess(argv, self.bench_rc, stdout="synthetic benchmark\n" + json.dumps({"rtf": self.rtf}) + "\n", stderr="")
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

    def bench_calls(self):
        return [c for c in self.calls if "bench-synth" in c]


def pcm_of(call) -> np.ndarray:
    return np.frombuffer(call.body, dtype="<i2").astype(np.float64) / 32768.0


def write_wav(path: Path, samples: np.ndarray, rate: int = SR) -> Path:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    return path


class CliAsrCase(AsrCase):
    """``AsrCase`` (a config for the relay, a clock, a transport, the relay token in the fake Keychain) with the pieces of the CLI: a config.env, the
    CA file, the deps, a terminal and the MiniServer behind the transport. ``self.cfg`` is the object the tests look at, ``cli.main`` loads its own
    from config.env (same paths)."""

    def setUp(self):
        super().setUp()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        env = mock.patch.dict(os.environ, {"MCAP_CONFIG": str(self.root / "config.env"), "MCAP_LOG_DIR": str(self.logs)})
        env.start()
        self.addCleanup(env.stop)
        (self.root / "relay-ca.pem").write_text("-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n", encoding="utf-8")
        self.server = MiniServer()
        self.transport.handler = self.server
        self.keychain = KeychainRun(self)
        self.probe_run = ProbeRun()
        self.deps = cli.AsrDeps(transport_factory=lambda: self.transport, run=self.probe_run, security_run=self.keychain, machine_id=MACHINE, now=NOW,
                                sleep=self.sleep, clock=self.clock)
        self.org = policy.absent_policy()
        patcher = mock.patch.object(status, "load_policy", lambda cfg: self.org)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.write_config()

    def write_config(self, **extra):
        values = {"SUPPORT_DIR": self.cfg.support_dir, "ARCHIVE_DIR": self.cfg.archive_dir, "PROJECT_DIR": self.cfg.project_dir,
                  "PYTHON_BIN": sys.executable, "CLAUDE_BIN": self.cfg.claude_bin, "CALENDAR_LOOKUP": "0",
                  "ASR_REMOTE_URL": f"https://{HOST}", "ASR_REMOTE_CA_FILE": self.root / "relay-ca.pem"}
        values.update(extra)
        (self.root / "config.env").write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def consent(self, engine="remote", **kw):
        policy.write_consent(self.cfg.consent_path, consent_entry(engine, **kw), machine_id=MACHINE)

    def mcap(self, *argv, stdin=None, deps=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(sys, "stdin", stdin if stdin is not None else io.StringIO()):
            code = cli.main(list(argv), deps=deps if deps is not None else self.deps)
        return code, out.getvalue(), err.getvalue()

    def tty(self, *lines):
        return TtyInput("".join(line + "\n" for line in lines))

    def paths(self):
        return self.transport.paths()

    def assert_clean(self, *outputs):
        """No token, enrollment code or server text in what was printed, written to the support folder or the logs."""
        text = "\n".join(outputs)
        for secret in (TOKEN, NEW_TOKEN, ENROLL_CODE, "mcap1_", *CANARY_FRAGMENTS, "tone transcript canary"):
            self.assertNotIn(secret, text)
        self.assertEqual(canary_hits(self.root, extra=outputs), [])
        for path in self.root.rglob("*"):
            if path.is_file() and "security-shim" not in str(path):
                data = path.read_bytes()
                for secret in (TOKEN, NEW_TOKEN, ENROLL_CODE):
                    self.assertNotIn(secret.encode(), data, str(path))


# ======================================================================================================================
class ListTests(CliAsrCase):
    def test_list_shows_every_engine_with_its_destination_label_and_not_the_host(self):
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "list")
        self.assertEqual(code, 0)
        rows = {line.split()[0]: line for line in out.splitlines()[1:]}
        self.assertEqual(set(rows), {"whisper", "qwen3-asr", "remote", "azure", "google", "clova", "openai-compat"})
        self.assertIn("company-asr", rows["remote"])
        self.assertIn("ok (until 2027-10-14)", rows["remote"])
        self.assertIn("stored", rows["remote"])
        self.assertIn("allowed", rows["remote"])
        self.assertTrue(rows["remote"].rstrip().endswith("yes"))
        self.assertIn("no-consent", rows["azure"])
        self.assertIn("no adapter", rows["google"])
        self.assertIn("this Mac", rows["whisper"])
        self.assertNotIn(HOST, out)
        self.assertNotIn("example.internal", out)

    def test_json_rows_carry_state_and_the_last_use_and_circuit_from_the_usage_record(self):
        self.consent("remote")
        write_usage(self.cfg, minutes=2, when=NOW - timedelta(hours=1))
        code, out, _err = self.mcap("asr-engines", "list", "--json")
        doc = json.loads(out)
        remote = next(r for r in doc["engines"] if r["engine"] == "remote")
        self.assertEqual((doc["schema"], remote["usable"], remote["credential"], remote["policy"]), (1, True, "stored", "allowed"))
        self.assertEqual(remote["last_used"], (NOW - timedelta(hours=1)).isoformat(timespec="seconds"))
        self.assertEqual(remote["circuit"], "closed")
        self.assertEqual(next(r for r in doc["engines"] if r["engine"] == "whisper")["usable"], True)
        self.assertEqual(next(r for r in doc["engines"] if r["engine"] == "google")["usable"], False)

    def test_a_policy_denial_an_expired_consent_and_a_missing_credential_are_each_shown(self):
        self.consent("remote", expires="2026-10-01")
        self.security.remove()
        self.org = company_org(self.root, company_doc(lanes={"asr_remote": "deny"}, asr={"org_consents": []}))
        remote = next(r for r in json.loads(self.mcap("asr-engines", "list", "--json")[1])["engines"] if r["engine"] == "remote")
        self.assertEqual((remote["policy"], remote["usable"]), ("denied (policy-lane)", False))
        self.assertTrue(remote["consent"].startswith("consent-expired"))
        self.assertEqual(remote["credential"], "missing")

    def test_an_engine_that_is_not_configured_says_so(self):
        self.write_config(ASR_REMOTE_URL="")
        remote = next(r for r in json.loads(self.mcap("asr-engines", "list", "--json")[1])["engines"] if r["engine"] == "remote")
        self.assertEqual((remote["consent"], remote["destination"], remote["credential"], remote["usable"]), ("not-configured", "-", "n/a", False))

    def test_list_reads_no_credential_value(self):
        self.consent("remote")
        self.mcap("asr-engines", "list")
        self.assertEqual(self.security.reads(), 0)
        self.assertEqual(self.transport.calls, [])


# ======================================================================================================================
class CheckStaticTests(CliAsrCase):
    def test_a_consented_engine_with_a_token_and_a_bound_ca_passes_without_a_request(self):
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "check", "remote")
        self.assertEqual(code, 0, out)
        self.assertIn("remote (server, kr)", out)
        for part in ("[ok]   destination: company-asr", "[ok]   policy: no organisation policy", "[ok]   consent: user consent c-remote",
                     "[ok]   private CA bound and a credential is stored (the value is not read)", "check: ok"):
            self.assertIn(part, out)
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.security.reads(), 0)

    def test_without_a_consent_the_check_fails_and_names_the_command_that_fixes_it(self):
        code, out, _err = self.mcap("asr-engines", "check", "remote")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] consent: no-consent: run `mcap asr-engines consent remote`", out)
        self.assertIn("check: 1 problem(s)", out)

    def test_a_policy_denial_a_missing_token_and_an_unbound_ca_are_problems(self):
        self.consent("remote")
        self.security.remove()
        code, out, _err = self.mcap("asr-engines", "check", "remote")
        self.assertEqual(code, 1)
        self.assertIn("no credential is stored", out)
        self.org = company_org(self.root, company_doc(asr={"allowed_hosts": ["other.example.com"]}))
        code, out, _err = self.mcap("asr-engines", "check", "remote")
        self.assertIn("[FAIL] policy: denied (policy-host)", out)
        self.write_config(ASR_REMOTE_CA_FILE="")
        self.org = policy.absent_policy()
        self.store_token()
        code, out, _err = self.mcap("asr-engines", "check", "remote")
        self.assertIn("private CA of the server is not bound", out)

    def test_without_an_engine_argument_the_engines_named_by_the_config_are_checked(self):
        code, out, _err = self.mcap("asr-engines", "check")
        self.assertEqual(code, 0)
        self.assertIn("no external ASR engine is configured", out)
        self.write_config(ASR_ENGINE="remote")
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "check")
        self.assertIn("remote (server, kr)", out)
        self.assertEqual(code, 0, out)

    def test_an_engine_whose_adapter_is_not_installed_is_a_problem_not_a_crash(self):
        self.consent("azure")
        self.store_token("azure-key-0123456789abcdef", engine="azure", host="koreacentral.api.cognitive.microsoft.com")
        with mock.patch.dict(asr_engines.REGISTRY, {"azure": "mcap.no_such_adapter:Nope"}):
            code, out, _err = self.mcap("asr-engines", "check", "azure")
        self.assertEqual(code, 1)
        self.assertIn("no adapter", out)
        self.assertEqual(self.transport.calls, [])

    def test_bad_engine_arguments_are_usage_errors(self):
        for engine in ("whisper", "google", "nonsense"):
            code, _out, err = self.mcap("asr-engines", "check", engine)
            self.assertEqual(code, 2, engine)
        self.assertIn("local engine", self.mcap("asr-engines", "check", "whisper")[2])
        self.assertIn("no adapter", self.mcap("asr-engines", "check", "google")[2])


class CheckLiveTests(CliAsrCase):
    def test_live_sends_the_health_request_and_one_synthetic_tone_and_prints_what_the_server_attests(self):
        self.consent("remote")
        code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/health", "/v1/chunk"])
        for call in self.transport.calls:
            self.assertEqual(call.header("authorization"), f"Bearer {TOKEN}")
            self.assertEqual(call.rule.host, HOST)
        chunk = pcm_of(self.transport.calls[1])
        self.assertEqual(len(chunk), SR)                                                       # one second
        spectrum = np.abs(np.fft.rfft(chunk))
        self.assertAlmostEqual(float(np.argmax(spectrum)), 440.0, delta=1.0)                   # a pure 440 Hz tone: nothing a person said
        self.assertLess(float(np.max(np.abs(chunk))), 0.25)
        self.assertGreater(float(spectrum[440]) / float(np.sum(spectrum)), 0.9)
        for part in ("[ok]   health: ok in", "backend kind server, retention none", "attest build bbbbbbbb (no allow list in the policy)",
                     "token valid for 71 more day(s)", "[ok]   chunk: one 1 s synthetic tone answered in", "the text is not shown)",
                     "sent: 1 chunk request(s), 1.0 s of audio"):
            self.assertIn(part, out)
        self.assertEqual(self.security.reads(service="MeetingCapture ASR remote"), 1)           # the token was read once, lazily
        self.assertEqual([l["op"] for l in usage_lines(self.cfg)], ["health", "chunk"])
        self.assert_clean(out, err)

    def test_the_build_the_server_attests_is_held_to_the_allow_list_of_the_org_consent(self):
        self.org = company_org(self.root)                                                       # its org consent allows build bbbb... only
        with mock.patch.object(policy, "load_org_policy", lambda path=None, **kw: self.org):    # the engine reads the policy file itself
            code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
            self.assertEqual(code, 0, out + err)
            self.assertIn("attest build bbbbbbbb (in the policy allow list)", out)
            self.server.health["attest"]["build_sha256"] = "d" * 64
            code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] live: the server was refused: attest", out)
        self.assertEqual(self.paths().count("/v1/chunk"), 1)                                    # no tone is sent to a server whose build is not allowed

    def test_live_without_a_terminal_or_a_yes_contacts_nothing(self):
        self.consent("remote")
        code, _out, err = self.mcap("asr-engines", "check", "remote", "--live")
        self.assertEqual(code, 2)
        self.assertIn("contacts the server", err)
        self.assertEqual(self.transport.calls, [])

    def test_live_asks_in_the_terminal_and_a_no_stops_it(self):
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "check", "remote", "--live", stdin=self.tty("n"))
        self.assertEqual((code, self.transport.calls), (1, []))
        self.assertIn("cancelled", out)
        self.assertIn("nothing of yours", out)
        code, out, _err = self.mcap("asr-engines", "check", "remote", "--live", stdin=self.tty("y"))
        self.assertEqual(code, 0, out)
        self.assertEqual(self.paths(), ["/v1/health", "/v1/chunk"])

    def test_a_server_that_keeps_things_is_refused_at_the_health_check_and_no_tone_is_sent(self):
        self.consent("remote")
        self.server.health = health_document(retention={"mode": "disk", "audio_disk": True, "text_disk": False, "memory_cache_s": 120, "log_content": False})
        code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] live: the server was refused: retention", out)
        self.assertEqual(self.paths(), ["/v1/health"])
        self.assertNotIn(TOKEN, out + err)

    def test_a_wrong_token_is_an_auth_failure_with_a_fixed_message(self):
        self.consent("remote")
        self.store_token("mcap1_99999999_" + "Z" * 32)
        code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("the server refused the credential (HTTP 401)", out)
        self.assertNotIn("Z" * 32, out + err)

    def test_live_is_not_tried_when_the_static_check_found_a_problem(self):
        code, out, _err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")              # no consent
        self.assertEqual(code, 1)
        self.assertEqual(self.transport.calls, [])

    def test_a_policy_that_denies_the_lane_stops_the_live_check_before_any_request(self):
        self.consent("remote")
        self.org = company_org(self.root, company_doc(lanes={"asr_remote": "deny"}))
        code, out, _err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 1)
        self.assertEqual(self.transport.calls, [])


class ProbeTests(CliAsrCase):
    def test_probe_runs_the_benchmark_child_and_records_the_capability(self):
        code, out, err = self.mcap("asr-engines", "check", "--probe")
        self.assertEqual(code, 0, out + err)
        bench = self.probe_run.bench_calls()
        self.assertEqual(len(bench), 1)
        self.assertEqual(bench[0][1:], ["-m", "mcap", "asr-engines", "bench-synth", "--seconds", "20", "--json"])
        self.assertEqual(bench[0][0], sys.executable)                                           # the pipeline's python (PYTHON_BIN)
        record = json.loads(Path(self.cfg.capability_path).read_text(encoding="utf-8"))
        self.assertEqual((record["rtf"], record["schema"]), (0.12, 1))
        self.assertRegex(record["machine"], r"^[0-9a-f]{64}$")
        self.assertIn("measured real-time factor 0.12", out)
        self.assertIn("local engine capable:", out)

    def test_probe_is_refused_while_a_recording_is_live(self):
        live = make_session(self.cfg, "2026-10-14_1200_zoom", end=None)
        os.utime(live / "mic.wav", None)                                                       # written just now
        code, out, err = self.mcap("asr-engines", "check", "--probe")
        self.assertEqual(code, 75)
        self.assertIn("a recording is in progress", err)
        self.assertEqual(self.probe_run.bench_calls(), [])
        self.assertFalse(Path(self.cfg.capability_path).exists())

    def test_a_failing_benchmark_is_a_problem_and_leaves_no_capability_record(self):
        self.probe_run.bench_rc = 1
        code, out, _err = self.mcap("asr-engines", "check", "--probe")
        self.assertEqual(code, 1)
        self.assertIn("bench-failed", out)
        self.assertFalse(Path(self.cfg.capability_path).exists())

    def test_the_default_runner_gives_the_child_this_code_on_its_path(self):
        seen = []
        with mock.patch.object(cli.subprocess, "run", lambda argv, **kw: seen.append((list(argv), kw)) or subprocess.CompletedProcess(argv, 0, stdout="", stderr="")):
            runner = cli._probe_runner(cli.AsrDeps())
            runner(["python", "-m", "mcap", "asr-engines", "bench-synth", "--seconds", "20", "--json"], capture_output=True)
            runner(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True)
        child, other = seen
        package_parent = str(Path(cli.__file__).resolve().parents[1])
        self.assertEqual(child[1]["cwd"], package_parent)
        self.assertTrue(child[1]["env"]["PYTHONPATH"].startswith(package_parent))
        self.assertNotIn("cwd", other[1])


class BenchSynthTests(CliAsrCase):
    def engine(self, **kw):
        def work(audio, language, prompt):
            self.clock.advance(len(audio) / SR * 0.1)                                          # a decoder at real-time factor 0.1
            return "text"
        return FakeLocalEngine([work], **kw)

    def test_the_last_line_is_the_rtf_of_the_local_engine_on_a_synthetic_clip(self):
        engine = self.engine()
        deps = cli.AsrDeps(local_engine=lambda cfg: engine, clock=self.clock)
        code, out, err = self.mcap("asr-engines", "bench-synth", "--seconds", "20", "--json", deps=deps)
        self.assertEqual(code, 0, err)
        record = json.loads(out.strip().splitlines()[-1])
        self.assertEqual((record["rtf"], record["seconds"], record["engine"]), (0.1, 20.0, "whisper"))
        self.assertEqual([n for n, _l, _p in engine.calls], [2 * SR, 20 * SR])                 # a 2 s warm-up (not counted), then the clip in one request
        self.assertEqual((engine.load_calls, engine.release_calls), (1, 1))
        self.assertEqual(out.count("\n"), 1)                                                   # --json: nothing else on stdout

    def test_a_clip_longer_than_a_request_is_split(self):
        engine = self.engine()
        code, out, _err = self.mcap("asr-engines", "bench-synth", "--seconds", "60", deps=cli.AsrDeps(local_engine=lambda cfg: engine, clock=self.clock))
        self.assertEqual([n for n, _l, _p in engine.calls], [2 * SR, 25 * SR, 25 * SR, 10 * SR])
        self.assertIn("synthetic benchmark: 60.0 s of audio", out)

    def test_an_engine_that_cannot_load_is_a_failure_without_a_json_line(self):
        engine = self.engine(load_error=asr_engines.ModelNotAvailable("not on disk"))
        code, out, err = self.mcap("asr-engines", "bench-synth", "--json", deps=cli.AsrDeps(local_engine=lambda cfg: engine, clock=self.clock))
        self.assertEqual((code, out), (1, ""))
        self.assertIn("FAILED: the benchmark could not run", err)
        self.assertEqual(engine.release_calls, 1)

    def test_the_synthetic_clip_is_deterministic_and_is_not_speech_of_anyone(self):
        a, b = cli.synthetic_audio(3.0), cli.synthetic_audio(3.0)
        self.assertTrue(np.array_equal(a, b))
        self.assertEqual((a.dtype, len(a)), (np.float32, 3 * SR))
        self.assertLessEqual(float(np.max(np.abs(a))), 1.0)
        self.assertGreater(float(np.sqrt(np.mean(a ** 2))), 0.01)
        tone = cli.synthetic_tone(1.0)
        self.assertEqual((tone.dtype, len(tone)), (np.float32, SR))


# ======================================================================================================================
class BenchTests(CliAsrCase):
    def setUp(self):
        super().setUp()
        self.local = FakeLocalEngine(["local text"])
        self.deps.local_engine = lambda cfg: self.local
        voice = cli.synthetic_audio(3.0)
        self.real = write_wav(self.root / "my-meeting.wav", 0.5 * voice[::-1])                  # a file of the test's own (not a recording of anyone)
        self.real_pcm = asr_http.pcm16(pipeline.decode_audio_16k(self.real))
        self.synthetic_pcm = asr_http.pcm16(cli.synthetic_audio(3.0))
        self.assertNotEqual(self.real_pcm, self.synthetic_pcm)

    def chunk_bodies(self):
        return [c.body for c in self.transport.calls if c.path == "/v1/chunk"]

    def test_an_external_engine_gets_the_synthetic_clip_by_default_even_when_a_file_is_given(self):
        self.consent("remote")
        code, out, err = self.mcap("asr-engines", "bench", str(self.real), "--engine", "remote", "--engine", "whisper", "--seconds", "3")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.chunk_bodies(), [self.synthetic_pcm])
        self.assertIn("1 audio file(s) are NOT sent to remote", out)
        self.assertEqual([n for n, _l, _p in self.local.calls], [3 * SR, 3 * SR])                # the local engine got the file AND the synthetic clip
        self.assertIn("file 1:", out)
        self.assertIn("synthetic:", out)
        self.assertNotIn("my-meeting", out)
        self.assertNotIn("tone transcript canary", out)
        self.assert_clean(out, err)

    def test_real_audio_needs_the_flag_a_terminal_and_the_typed_sentence(self):
        self.consent("remote")
        args = ("asr-engines", "bench", str(self.real), "--engine", "remote", "--seconds", "3", "--allow-real-audio")
        code, _out, err = self.mcap(*args)                                                      # no terminal
        self.assertEqual(code, 2)
        self.assertIn("confirmation typed in a terminal", err)
        code, _out, err = self.mcap(*args, stdin=self.tty("yes"))                              # the wrong sentence
        self.assertEqual(code, 1)
        self.assertIn("the sentence did not match", err)
        code, _out, err = self.mcap(*args, stdin=TtyInput(""))                                 # end of input
        self.assertEqual(code, 1)
        self.assertEqual(self.transport.calls, [])                                             # nothing was sent in any of the three
        code, out, err = self.mcap(*args, stdin=self.tty(cli.REAL_AUDIO_PHRASE))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.chunk_bodies(), [self.real_pcm])                                 # now, and only now, the file itself
        self.assertIn(cli.REAL_AUDIO_PHRASE, out)
        self.assertIn("only from a meeting where you were the only participant", out)

    def test_the_confirmation_lists_the_engines_the_audio_goes_to(self):
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "bench", str(self.real), "--engine", "remote", "--seconds", "3", "--allow-real-audio",
                                   stdin=self.tty("no"))
        self.assertIn("will be SENT to: remote", out)

    def test_an_external_engine_without_a_consent_is_refused_and_nothing_is_sent(self):
        code, out, err = self.mcap("asr-engines", "bench", "--engine", "remote", "--seconds", "3")
        self.assertEqual(code, 1)
        self.assertIn("remote: refused (no-consent)", out)
        self.assertEqual(self.transport.calls, [])

    def test_a_policy_that_denies_the_lane_refuses_the_bench_too(self):
        self.consent("remote")
        self.org = company_org(self.root, company_doc(lanes={"asr_remote": "deny"}))
        code, out, _err = self.mcap("asr-engines", "bench", "--engine", "remote", "--seconds", "3")
        self.assertEqual(code, 1)
        self.assertIn("refused (policy-lane)", out)
        self.assertEqual(self.transport.calls, [])

    def test_the_real_audio_flag_is_only_asked_about_when_it_could_leave_the_mac(self):
        code, out, err = self.mcap("asr-engines", "bench", str(self.real), "--engine", "whisper", "--seconds", "3", "--allow-real-audio")
        self.assertEqual(code, 0, out + err)                                                   # a local engine: no confirmation, no terminal needed
        self.assertEqual([n for n, _l, _p in self.local.calls], [3 * SR, 3 * SR])

    def test_usage_errors(self):
        self.assertEqual(self.mcap("asr-engines", "bench", "--allow-real-audio")[0], 2)         # nothing to send
        self.assertEqual(self.mcap("asr-engines", "bench", str(self.root / "nope.wav"))[0], 2)
        self.assertEqual(self.mcap("asr-engines", "bench", "--engine", "nonsense")[0], 2)
        self.assertEqual(self.mcap("asr-engines", "bench", "--engine", "google")[0], 2)
        self.assertEqual(self.mcap("asr-engines", "bench", "--engine", "qwen3-asr")[0], 2)

    def test_the_engines_default_to_the_configured_ones(self):
        self.write_config(ASR_ENGINE="remote", ASR_FALLBACK="whisper")
        self.consent("remote")
        code, out, _err = self.mcap("asr-engines", "bench", "--seconds", "3")
        self.assertEqual(code, 0, out)
        self.assertEqual([line for line in out.splitlines() if not line.startswith(" ")], ["remote", "whisper"])
        self.assertEqual(self.chunk_bodies(), [self.synthetic_pcm])

    def test_a_failing_engine_does_not_hide_the_others(self):
        self.write_config(ASR_ENGINE="remote")
        self.consent("remote")
        self.server.token = "other"                                                            # the relay now refuses our token: a failure of one engine
        code, out, err = self.mcap("asr-engines", "bench", "--engine", "remote", "--engine", "whisper", "--seconds", "3")
        self.assertEqual(code, 1)
        self.assertIn("remote: FAILED: EngineAuthError", out)
        self.assertEqual([n for n, _l, _p in self.local.calls], [3 * SR])                      # whisper still ran
        self.assertNotIn(TOKEN, out + err)


# ======================================================================================================================
class ConsentTests(CliAsrCase):
    def phrase(self, engine="remote", host=HOST):
        return f"동의합니다 {engine}@{host}"

    def entries(self):
        return policy.load_consents(self.cfg.consent_path, machine_id=MACHINE, now=NOW)

    def test_a_consent_needs_a_terminal(self):
        code, _out, err = self.mcap("asr-engines", "consent", "remote")
        self.assertEqual(code, 2)
        self.assertIn("typing a sentence in a terminal", err)
        self.assertFalse(Path(self.cfg.consent_path).exists())

    def test_a_wrong_sentence_records_nothing(self):
        for typed in ("동의합니다", "yes", "동의합니다 remote@other.example.com", "동의합니다  remote@" + HOST + " now", ""):
            with self.subTest(typed=typed):
                code, out, err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty(typed))
                self.assertEqual(code, 1)
                self.assertIn("the sentence did not match", err)
                self.assertFalse(Path(self.cfg.consent_path).exists())
        code, _out, _err = self.mcap("asr-engines", "consent", "remote", stdin=TtyInput(""))      # end of input
        self.assertEqual((code, Path(self.cfg.consent_path).exists()), (1, False))

    def test_the_typed_sentence_records_a_consent_bound_to_host_port_ca_and_this_mac(self):
        code, out, err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty(self.phrase()))
        self.assertEqual(code, 0, out + err)
        consents = self.entries()
        self.assertIsNone(consents.problem)
        entry = consents.entries[0]
        until = (NOW.date() + timedelta(days=cli.CONSENT_DEFAULT_DAYS)).isoformat()
        self.assertEqual((entry.engine, entry.kind, entry.host, entry.port, entry.protocol, entry.backend_kind, entry.use, entry.machine, entry.granted_by),
                         ("remote", "server", HOST, 443, "mcap-asr/1", "server", "both", MACHINE, "tty"))
        self.assertEqual(entry.expires, until)
        self.assertEqual(entry.ca_sha256, __import__("hashlib").sha256((self.root / "relay-ca.pem").read_bytes()).hexdigest())
        self.assertRegex(entry.id, r"^c-20261014-[0-9a-f]{6}$")
        found, reason = consents.valid_for("remote", HOST, 443, "primary", protocol="mcap-asr/1", backend_kind="server", now=NOW)
        self.assertEqual((reason, found.id), ("ok", entry.id))
        self.assertIn(f"Recorded consent {entry.id} for remote (use both) until {until}", out)
        self.assertEqual(oct(Path(self.cfg.consent_path).stat().st_mode & 0o777), "0o600")

    def test_the_text_shown_before_the_sentence_says_what_leaves_the_mac(self):
        code, out, _err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty("nothing"))
        for part in (f"{HOST}:443", "16 kHz mono", "제목, 세션 ID, 플랫폼, 참석자, 파일명은 보내지 않습니다", "원격 참석자의 목소리", "서버는 오디오와 텍스트를 저장하지 않는다고 자기보고",
                     "벤더로 전달됩니다", "하루 240분", "사설 CA", "동의하려면 정확히 입력하세요: " + self.phrase()):
            self.assertIn(part, out)
        self.assertRegex(out, r"용어집:\s+ASR_SEND_VOCAB가 켜져 있어 vocabulary.txt의 용어 \d+개가 함께 전송됩니다")
        self.write_config(ASR_SEND_VOCAB="0")
        code, out, _err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty("nothing"))
        self.assertIn("용어는 전송하지 않습니다", out)

    def test_days_and_use_are_honoured_and_validated(self):
        code, out, _err = self.mcap("asr-engines", "consent", "remote", "--days", "30", "--use", "fallback", stdin=self.tty(self.phrase()))
        entry = self.entries().entries[0]
        self.assertEqual((code, entry.use, entry.expires), (0, "fallback", (NOW.date() + timedelta(days=30)).isoformat()))
        for days in ("0", "366", "-1"):
            code, _out, err = self.mcap("asr-engines", "consent", "remote", "--days", days, stdin=self.tty(self.phrase()))
            self.assertEqual(code, 2, days)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cli.main(["asr-engines", "consent", "remote", "--use", "always"], deps=self.deps)

    def test_a_second_consent_replaces_the_first_and_renews_an_expired_one(self):
        self.consent("remote", expires="2026-10-01")
        self.assertEqual(status.consent_state(self.cfg, "remote", self.org, self.entries(), NOW)["state"], "consent-expired")
        code, _out, _err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty(self.phrase()))
        consents = self.entries()
        self.assertEqual((code, len(consents.entries), status.consent_state(self.cfg, "remote", self.org, consents, NOW)["state"]), (0, 1, "ok"))

    def test_a_policy_denied_engine_is_refused_without_a_prompt(self):
        for sections, reason in ((dict(lanes={"asr_remote": "deny"}), "policy-lane"), (dict(asr={"allowed_engines": ["whisper"]}), "policy-engine"),
                                 (dict(asr={"allowed_hosts": ["other.example.com"]}), "policy-host"),
                                 (dict(local_only={"default": True, "locked": True}), "local_only")):
            with self.subTest(reason=reason):
                self.org = company_org(self.root, company_doc(**sections))
                code, out, err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty(self.phrase()))
                self.assertEqual(code, 1)
                self.assertIn(f"does not allow remote on this Mac ({reason})", err)
                self.assertNotIn("동의하려면", out)
                self.assertFalse(Path(self.cfg.consent_path).exists())
        self.org = locked_org(self.root)
        self.assertIn("policy-locked", self.mcap("asr-engines", "consent", "remote", stdin=self.tty(self.phrase()))[2])

    def test_a_company_policy_does_not_let_the_user_consent_to_a_cloud_engine(self):
        self.org = company_org(self.root)                                                       # lanes.asr_cloud is deny
        code, out, err = self.mcap("asr-engines", "consent", "azure", stdin=self.tty("동의합니다 azure@koreacentral.api.cognitive.microsoft.com"))
        self.assertEqual(code, 1)
        self.assertIn("does not allow azure on this Mac (policy-lane)", err)
        self.assertFalse(Path(self.cfg.consent_path).exists())

    def test_an_org_consent_covers_a_server_and_needs_no_terminal(self):
        self.org = company_org(self.root)
        code, out, _err = self.mcap("asr-engines", "consent", "remote")                         # no TTY, no typed sentence
        self.assertEqual(code, 0)
        self.assertRegex(out, r"the organisation's consent org:remote-[0-9a-f]{8} covers this server \(use both, valid until 2027-10-14\)")
        self.assertFalse(Path(self.cfg.consent_path).exists())

    def test_an_expired_org_consent_does_not_skip_the_terminal(self):
        doc = company_doc(asr={"org_consents": [dict(company_doc()["asr"]["org_consents"][0], expires="2026-10-01")]})
        self.org = company_org(self.root, doc)
        code, _out, err = self.mcap("asr-engines", "consent", "remote")
        self.assertEqual(code, 2)                                                              # it now needs the user's own consent: a terminal

    def test_a_cloud_engine_needs_no_ca_and_binds_the_region(self):
        self.write_config()
        code, out, err = self.mcap("asr-engines", "consent", "azure", stdin=self.tty("동의합니다 azure@koreacentral.api.cognitive.microsoft.com"))
        self.assertEqual(code, 0, out + err)
        entry = self.entries().entries[0]
        self.assertEqual((entry.engine, entry.kind, entry.region, entry.model, entry.protocol, entry.backend_kind, entry.ca_sha256),
                         ("azure", "cloud", "koreacentral", "fast-transcription", "azure-fast-transcription", "cloud", None))
        self.assertIn("벤더의 보관 정책은 벤더의 주장이며 확인되지 않았습니다", out)
        self.assertIn("알 수 없음 (ASR_AZURE_USD_PER_HOUR=0)", out)

    def test_the_price_estimate_is_shown_when_one_is_configured(self):
        self.write_config(ASR_AZURE_USD_PER_HOUR="1.5")
        code, out, _err = self.mcap("asr-engines", "consent", "azure", stdin=self.tty("nothing"))
        self.assertIn("오디오 1시간당 약 $1.5", out)

    def test_engines_that_cannot_be_consented_to_and_missing_configuration_are_usage_errors(self):
        self.assertIn("local engine", self.mcap("asr-engines", "consent", "whisper", stdin=self.tty("x"))[2])
        self.assertIn("no adapter", self.mcap("asr-engines", "consent", "google", stdin=self.tty("x"))[2])
        self.assertIn("unknown engine", self.mcap("asr-engines", "consent", "nonsense", stdin=self.tty("x"))[2])
        self.write_config(ASR_REMOTE_URL="")
        code, _out, err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty("x"))
        self.assertEqual(code, 2)
        self.assertIn("not configured", err)
        self.write_config(ASR_REMOTE_CA_FILE="")
        code, _out, err = self.mcap("asr-engines", "consent", "remote", stdin=self.tty("x"))
        self.assertEqual(code, 2)
        self.assertIn("ASR_REMOTE_CA_FILE is not set", err)
        self.write_config(ASR_REMOTE_CA_FILE=self.root / "missing.pem")
        self.assertIn("cannot be read", self.mcap("asr-engines", "consent", "remote", stdin=self.tty("x"))[2])
        self.assertFalse(Path(self.cfg.consent_path).exists())

    def test_a_recorded_consent_makes_the_engine_usable_end_to_end(self):
        self.mcap("asr-engines", "consent", "remote", stdin=self.tty(self.phrase()))
        code, out, err = self.mcap("asr-engines", "check", "remote", "--live", "--yes")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/health", "/v1/chunk"])


# ======================================================================================================================
class EnrollTests(CliAsrCase):
    def setUp(self):
        super().setUp()
        self.security.remove()                                                                  # nothing is enrolled yet
        self.consent("remote")

    def test_the_code_on_stdin_becomes_a_token_in_the_host_bound_keychain_item(self):
        code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/enroll"])
        self.assertIn(f"Enrolled: the token for {HOST}:443 is stored in the macOS Keychain and valid until 2027-01-12T12:00:00+09:00", out)
        with asr_creds.secret("remote", HOST, 443) as stored:
            self.assertEqual(stored, NEW_TOKEN)
        self.assertEqual(self.security.dir.joinpath("items.json").exists(), True)
        writes = [c for c in self.keychain.calls if c["argv"][1:2] == ["-i"]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["argv"][1:], ["-i"])                                          # the token is on stdin, never in argv
        self.assert_clean(out, err)

    def test_the_code_can_be_typed_in_a_terminal(self):
        code, out, err = self.mcap("asr-engines", "enroll", "remote", stdin=self.tty(ENROLL_CODE))
        self.assertEqual(code, 0, out + err)
        self.assertIn("Enrollment code (from your administrator):", out)
        self.assert_clean(out, err)

    def test_an_org_consent_alone_is_enough_to_enroll(self):
        Path(self.cfg.consent_path).unlink()
        self.org = company_org(self.root)
        with mock.patch.object(policy, "load_org_policy", lambda path=None, **kw: self.org):
            code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/enroll"])
        with asr_creds.secret("remote", HOST, 443) as stored:
            self.assertEqual(stored, NEW_TOKEN)

    def test_without_a_terminal_and_without_code_stdin_there_is_no_way_to_give_the_code(self):
        code, _out, err = self.mcap("asr-engines", "enroll", "remote")
        self.assertEqual(code, 2)
        self.assertIn("--code-stdin", err)
        self.assertEqual(self.transport.calls, [])

    def test_an_empty_or_malformed_code_is_a_usage_error_and_nothing_is_sent(self):
        for text in ("\n", "   \n", "has\ttab\n", "x" * 70 + "\n"):
            code, _out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(text))
            self.assertEqual(code, 2, repr(text))
        self.assertEqual(self.transport.calls, [])

    def test_a_refused_code_is_a_failure_with_a_fixed_message_and_no_server_text(self):
        code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO("WRONGCODE\n"))
        self.assertEqual(code, 1)
        self.assertIn("the enrollment code was refused (wrong, already used or expired): ask the administrator for a new one", err)
        self.assert_clean(out, err)
        self.assertEqual([c for c in self.keychain.calls if c["argv"][1:2] == ["-i"]], [])        # nothing was stored

    def test_enrollment_is_not_allowed_without_a_consent_or_for_a_policy_denied_server(self):
        Path(self.cfg.consent_path).unlink()
        code, _out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 1)
        self.assertIn("enrollment is not allowed for this server (no-consent)", err)
        self.assertEqual(self.transport.calls, [])

    def test_a_locked_local_only_flag_refuses_enrollment_before_the_code_is_asked_for_and_sends_nothing(self):
        locked = company_org(self.root, company_doc(local_only={"default": True, "locked": True}))      # the org consent is in the document
        for label, org, reason in (("locked local-only", locked, "local_only"), ("locked policy", locked_org(self.root), "policy-locked")):
            with self.subTest(label):
                self.org = org
                piped = io.StringIO(ENROLL_CODE + "\n")
                code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=piped)
                self.assertEqual(code, 1, out + err)
                self.assertIn(f"enrollment is not allowed for this server ({reason})", err)
                self.assertEqual(piped.tell(), 0, "the code was read although the policy refuses the enrollment")
                code, out, err = self.mcap("asr-engines", "enroll", "remote", stdin=self.tty(ENROLL_CODE))
                self.assertEqual(code, 1, out + err)
                self.assertNotIn("Enrollment code", out)                                       # not even asked for
                self.assertEqual(self.transport.calls, [])
                self.assertEqual([c for c in self.keychain.calls if c["argv"][1:2] == ["-i"]], [])          # no token stored
                self.assert_clean(out, err)
        self.assertTrue(Path(self.cfg.consent_path).exists())                                  # the user's own consent did not open the lock

    def test_a_local_only_default_that_is_not_locked_does_not_stop_the_enrollment(self):
        self.org = company_org(self.root, company_doc(local_only={"default": True, "locked": False}))
        code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/enroll"])

    def test_the_daily_cap_does_not_count_against_an_enrollment(self):
        write_usage(self.cfg, minutes=5000, when=NOW - timedelta(minutes=5))
        code, out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/enroll"])

    def test_a_server_that_cannot_be_reached_is_a_failure_that_says_the_code_may_be_used_up(self):
        self.transport.script.append(egress.EgressError("connect") if False else egress.map_exception(ConnectionRefusedError()))
        code, _out, err = self.mcap("asr-engines", "enroll", "remote", "--code-stdin", stdin=io.StringIO(ENROLL_CODE + "\n"))
        self.assertEqual(code, 1)
        self.assertIn("could not be reached for enrollment", err)


# ======================================================================================================================
class RevokeTests(CliAsrCase):
    def setUp(self):
        super().setUp()
        self.consent("remote")
        self.consent("azure")

    def states(self):
        consents = policy.load_consents(self.cfg.consent_path, machine_id=MACHINE, now=NOW)
        return {e: status.consent_state(self.cfg, e, self.org, consents, NOW)["state"] for e in ("remote", "azure")}

    def test_revoking_one_engine_keeps_the_other(self):
        code, out, _err = self.mcap("asr-engines", "revoke", "remote")
        self.assertEqual(code, 0)
        self.assertIn("Revoked 1 consent(s) of remote", out)
        self.assertEqual(self.states(), {"remote": "no-consent", "azure": "ok"})

    def test_revoke_all_removes_every_consent(self):
        code, out, _err = self.mcap("asr-engines", "revoke", "--all")
        self.assertEqual(code, 0)
        self.assertIn("Revoked 2 consent(s) of all engines", out)
        self.assertEqual(self.states(), {"remote": "no-consent", "azure": "no-consent"})

    def test_revoking_what_was_never_consented_says_so(self):
        self.mcap("asr-engines", "revoke", "--all")
        code, out, _err = self.mcap("asr-engines", "revoke", "remote")
        self.assertEqual(code, 0)
        self.assertIn("No consent of remote was recorded on this Mac", out)

    def test_a_forget_secret_deletes_the_host_bound_keychain_item_after_a_yes(self):
        self.assertTrue(asr_creds.secret_status("remote", HOST, 443)["present"])
        code, out, err = self.mcap("asr-engines", "revoke", "remote", "--forget-secret", "--yes")
        self.assertEqual(code, 0, out + err)
        self.assertFalse(asr_creds.secret_status("remote", HOST, 443)["present"])
        deletes = self.security.argvs("delete-generic-password")
        self.assertEqual(len(deletes), 1)
        self.assertEqual(deletes[0][deletes[0].index("-s") + 1], "MeetingCapture ASR remote")
        self.assertTrue(deletes[0][deletes[0].index("-a") + 1].endswith(f"@{HOST}:443"))
        self.assert_clean(out, err)

    def test_a_forget_secret_without_a_terminal_or_yes_changes_nothing_at_all(self):
        code, _out, err = self.mcap("asr-engines", "revoke", "remote", "--forget-secret")
        self.assertEqual(code, 2)
        self.assertIn("run it in a terminal or pass --yes", err)
        self.assertEqual(self.states()["remote"], "ok")                                          # the consent is still there too
        self.assertTrue(asr_creds.secret_status("remote", HOST, 443)["present"])

    def test_a_forget_secret_that_is_declined_in_the_terminal_still_revokes_the_consent(self):
        code, out, _err = self.mcap("asr-engines", "revoke", "remote", "--forget-secret", stdin=self.tty("n"))
        self.assertEqual(code, 0)
        self.assertEqual(self.states()["remote"], "no-consent")
        self.assertTrue(asr_creds.secret_status("remote", HOST, 443)["present"])

    def test_an_organisation_consent_is_not_the_users_to_withdraw(self):
        self.org = company_org(self.root)
        code, out, _err = self.mcap("asr-engines", "revoke", "remote")
        self.assertIn("the organisation's policy covers remote too", out)

    def test_usage_errors(self):
        self.assertEqual(self.mcap("asr-engines", "revoke")[0], 2)
        self.assertEqual(self.mcap("asr-engines", "revoke", "remote", "--all")[0], 2)
        self.assertEqual(self.mcap("asr-engines", "revoke", "nonsense")[0], 2)


class PurgeTests(CliAsrCase):
    def make_files(self):
        base = Path(self.cfg.asr_usage_path)
        base.parent.mkdir(parents=True, exist_ok=True)
        for name in (base.name, base.name + ".1", base.name + ".3"):
            (base.parent / name).write_text("{}\n")
        Path(self.cfg.capability_path).write_text("{}")

    def test_usage_and_capability_files_are_removed_only_when_asked(self):
        self.make_files()
        code, out, _err = self.mcap("asr-engines", "purge", "--capability")
        self.assertEqual(code, 0)
        self.assertFalse(Path(self.cfg.capability_path).exists())
        self.assertTrue(Path(self.cfg.asr_usage_path).exists())
        code, out, _err = self.mcap("asr-engines", "purge", "--usage", "--yes")
        self.assertEqual(code, 0)
        self.assertIn("Removed 3 local file(s)", out)
        self.assertEqual([p.name for p in Path(self.cfg.asr_usage_path).parent.glob("asr-usage*")], [])

    def test_removing_the_usage_record_needs_a_terminal_or_yes(self):
        self.make_files()
        code, _out, err = self.mcap("asr-engines", "purge", "--usage")
        self.assertEqual((code, Path(self.cfg.asr_usage_path).exists()), (2, True))
        code, out, _err = self.mcap("asr-engines", "purge", "--usage", stdin=self.tty("n"))
        self.assertEqual((code, Path(self.cfg.asr_usage_path).exists()), (0, True))
        code, out, _err = self.mcap("asr-engines", "purge", "--usage", stdin=self.tty("y"))
        self.assertEqual((code, Path(self.cfg.asr_usage_path).exists()), (0, False))

    def test_nothing_chosen_is_a_usage_error(self):
        code, _out, err = self.mcap("asr-engines", "purge")
        self.assertEqual(code, 2)
        self.assertIn("say what to purge", err)

    def test_the_server_cache_is_dropped_through_the_purge_endpoint(self):
        self.consent("remote")
        code, out, err = self.mcap("asr-engines", "purge", "--server")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.paths(), ["/v1/purge"])
        self.assertEqual(self.transport.calls[0].method, "POST")
        self.assertIn("Server: 3 cached entr(ies) dropped.", out)
        self.assert_clean(out, err)

    def test_the_server_cache_is_not_purged_when_the_server_may_not_be_used(self):
        code, _out, err = self.mcap("asr-engines", "purge", "--server")                          # no consent
        self.assertEqual(code, 1)
        self.assertIn("remote is not usable here (no-consent)", err)
        self.assertEqual(self.transport.calls, [])


class SecretTests(CliAsrCase):
    def test_status_says_whether_a_credential_is_stored_for_this_destination_and_never_shows_it(self):
        code, out, err = self.mcap("asr-engines", "secret", "status", "remote")
        self.assertEqual(code, 0)
        self.assertIn("remote: a credential is stored for company-asr", out)
        self.assertIn("Keychain service 'MeetingCapture ASR remote'", out)
        self.assertIn(f"@{HOST}:443", out)
        self.assert_clean(out, err)
        self.assertEqual(self.security.reads(), 0)
        self.security.remove()
        code, out, _err = self.mcap("asr-engines", "secret", "status", "remote")
        self.assertEqual(code, 1)
        self.assertIn("no credential is stored (missing)", out)

    def test_the_item_is_bound_to_the_host_a_changed_url_finds_nothing(self):
        self.write_config(ASR_REMOTE_URL="https://asr2.example.internal")
        code, out, _err = self.mcap("asr-engines", "secret", "status", "remote")
        self.assertEqual(code, 1)
        self.assertIn("(missing)", out)

    def test_set_needs_a_terminal_and_hands_the_typing_to_the_security_tool(self):
        code, _out, err = self.mcap("asr-engines", "secret", "set", "remote")
        self.assertEqual(code, 2)
        self.assertIn("must run in a terminal", err)
        self.assertEqual(self.security.argvs("add-generic-password"), [])
        code, out, err = self.mcap("asr-engines", "secret", "set", "remote", stdin=self.tty())
        self.assertEqual(code, 0, out + err)                                                    # the stored item is found afterwards (store_token's item)
        self.assertIn("Stored.", out)
        argv = self.security.argvs("add-generic-password")[0]
        self.assertEqual(argv[-1], "-w")                                                         # `-w` last: the tool prompts, the secret is not in argv
        self.assertEqual(argv[argv.index("-s") + 1], "MeetingCapture ASR remote")
        self.assertTrue(argv[argv.index("-a") + 1].endswith(f"@{HOST}:443"))
        self.assertNotIn(TOKEN, " ".join(argv))

    def test_forget_asks_first(self):
        code, _out, err = self.mcap("asr-engines", "secret", "forget", "remote")
        self.assertEqual(code, 2)
        self.assertTrue(asr_creds.secret_status("remote", HOST, 443)["present"])
        code, out, _err = self.mcap("asr-engines", "secret", "forget", "remote", stdin=self.tty("n"))
        self.assertEqual(code, 0)
        self.assertTrue(asr_creds.secret_status("remote", HOST, 443)["present"])
        code, out, err = self.mcap("asr-engines", "secret", "forget", "remote", "--yes")
        self.assertEqual(code, 0, err)
        self.assertFalse(asr_creds.secret_status("remote", HOST, 443)["present"])

    def test_engines_without_a_stored_secret_and_unconfigured_ones_are_usage_errors(self):
        self.assertEqual(self.mcap("asr-engines", "secret", "status", "whisper")[0], 2)
        self.assertEqual(self.mcap("asr-engines", "secret", "status", "google")[0], 2)
        self.write_config(ASR_REMOTE_URL="")
        code, _out, err = self.mcap("asr-engines", "secret", "status", "remote")
        self.assertEqual(code, 2)
        self.assertIn("not configured", err)

    def test_the_azure_secret_is_bound_to_the_azure_host_only(self):
        self.write_config(ASR_AZURE_HOST="evil.example.com")
        code, _out, err = self.mcap("asr-engines", "secret", "status", "azure")
        self.assertEqual(code, 2)                                                                # outside the fixed Azure suffixes: no binding, no secret
        self.write_config()
        code, out, _err = self.mcap("asr-engines", "secret", "status", "azure")
        self.assertEqual(code, 1)
        self.assertIn("azure/koreacentral", out)


# ======================================================================================================================
class TranscribeFileUnderPolicyTests(CliAsrCase):
    def setUp(self):
        super().setUp()
        self.wav = write_wav(self.root / "speech.wav", 0.1 * cli.synthetic_audio(1.0))
        self.seen = {}

    def transcribe_array(self, audio, cfg, vocab, language=None, progress=lambda m: None):
        self.seen.update(cfg=cfg, language=language)
        decision = cfg.asr_decision
        if decision is not None and not decision.allow_egress and not decision.allow_download:      # a strict run: the tripwire must be up
            try:
                socket.create_connection(("203.0.113.9", 80), timeout=1)
            except egress.EgressViolation:
                self.seen["tripwire"] = True
        return [{"start": 0.5, "end": 3.0, "text": "hello world", "lang": "en"}]

    def inputs(self, org, hw=None):
        return mock.patch.object(cli, "_privacy_inputs", lambda: lanes.PrivacyInputs(policy=org, hw=hw or probe(), consents=policy.ConsentSet(machine=MACHINE), now=NOW))

    def deps_for(self):
        return pipeline.Deps(transcribe_array=self.transcribe_array)

    def test_the_personal_default_gets_the_same_config_object_and_no_strict_tripwire(self):
        with self.inputs(policy.absent_policy()):
            code, out, err = self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        self.assertEqual(code, 0, err)
        self.assertIsNone(self.seen["cfg"].asr_decision)                                       # the same cfg as before SPEC 18: nothing changes
        self.assertNotIn("tripwire", self.seen)
        self.assertNotIn("Privacy:", out)

    def test_a_locked_local_only_policy_makes_the_run_local_only_with_the_strict_tripwire_and_a_privacy_line(self):
        org = company_org(self.root, company_doc(local_only={"default": True, "locked": True}))
        with self.inputs(org):
            code, out, err = self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        self.assertEqual(code, 0, err)
        cfg = self.seen["cfg"]
        self.assertTrue(cfg.asr_decision.local_only)
        self.assertFalse(cfg.asr_decision.allow_download)
        self.assertFalse(cfg.asr_decision.allow_egress)
        self.assertFalse(cfg.log_content)                                                       # no transcript snippets in the log
        self.assertTrue(self.seen["tripwire"])                                                  # a non-loopback connect is refused while it runs
        self.assertIn("Privacy: local-only", out)
        self.assertIn("hello world", out)

    def test_the_default_chain_of_the_flag_applies_to_a_file_without_session_json(self):
        org = company_org(self.root, company_doc(local_only={"default": True, "locked": False}))
        with self.inputs(org):
            code, out, err = self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        self.assertTrue(self.seen["cfg"].asr_decision.local_only)
        self.assertIn("Privacy: local-only", out)
        self.write_config(LOCAL_ONLY_DEFAULT="1")
        self.seen.clear()
        with self.inputs(policy.absent_policy()):
            self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        self.assertTrue(self.seen["cfg"].asr_decision.local_only)                               # LOCAL_ONLY_DEFAULT=1 reaches this command too

    def test_a_mac_that_cannot_transcribe_under_the_policy_stops_with_a_clear_failure(self):
        self.write_config(ASR_ENGINE="auto")
        org = company_org(self.root, company_doc(asr={"org_consents": []}))
        with self.inputs(org, hw=probe(capable=False)):
            code, out, err = self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        self.assertEqual(code, 1)
        self.assertIn("FAILED: transcription blocked", err)
        self.assertEqual(self.seen, {})                                                         # the engine was never asked

    def test_an_external_engine_is_used_only_with_consent_policy_and_a_flag_that_is_not_local_only(self):
        self.write_config(ASR_ENGINE="remote")
        self.consent("remote")
        consents = policy.load_consents(self.cfg.consent_path, machine_id=MACHINE, now=NOW)
        with mock.patch.object(cli, "_privacy_inputs", lambda: lanes.PrivacyInputs(policy=policy.absent_policy(), hw=probe(), consents=consents, now=NOW)):
            code, out, err = self.mcap("transcribe-file", str(self.wav), deps=self.deps_for())
        decision = self.seen["cfg"].asr_decision
        self.assertEqual((code, decision.primary, decision.allow_egress), (0, "remote", True))
        self.assertNotIn("tripwire", self.seen)                                                 # an external run is audited, not walled

    def test_the_audio_file_must_exist(self):
        self.assertEqual(self.mcap("transcribe-file", str(self.root / "missing.wav"))[0], 2)


# ======================================================================================================================
def load_bench():
    spec = importlib.util.spec_from_file_location("bench_asr_under_test", ROOT / "scripts" / "bench_asr.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BenchScriptGateTests(CliAsrCase):
    """scripts/bench_asr.py lists `remote` / `azure` like a model: the same gate as `mcap asr-engines bench` (synthetic clip by default, real audio
    only after --allow-real-audio and the typed sentence), and the engine is built from the decision of a run (consent, policy)."""

    @classmethod
    def setUpClass(cls):
        cls.bench = load_bench()

    def setUp(self):
        super().setUp()
        self.wav = write_wav(self.root / "meeting.wav", 0.3 * cli.synthetic_audio(6.0)[::-1])
        self.engines = []

        def fake_engine(model, allow_download):
            engine = FakeCloudEngine(["remote text"], kind="server", engine_id="remote", seconds=2.0)
            self.engines.append(engine)
            return engine
        patcher = mock.patch.object(self.bench, "make_engine", fake_engine)
        patcher.start()
        self.addCleanup(patcher.stop)

    def main(self, *argv, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(sys, "stdin", stdin if stdin is not None else io.StringIO()):
            try:
                code = self.bench.main(["--vad", "energy", "-q", "--out", str(self.root / "bench-out"), *argv])
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue(), err.getvalue()

    def test_external_engine_ids_are_told_from_model_names(self):
        self.assertEqual(self.bench.external_engine_ids(["remote", "mlx-community/whisper-large-v3-mlx", "azure", "/models/remote"]), ["remote", "azure"])
        self.assertEqual(self.bench.external_engine_ids(["mlx-community/whisper-tiny-mlx", "qwen3-asr"]), [])

    def test_audio_is_required_unless_only_external_engines_are_benchmarked(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                self.bench.parse_args(["--models", "mlx-community/whisper-tiny-mlx"])
            self.assertEqual(raised.exception.code, 2)
            with self.assertRaises(SystemExit):
                self.bench.parse_args(["--models", "remote", "--allow-real-audio"])
        self.assertIsNone(self.bench.parse_args(["--models", "remote"]).audio)
        self.assertEqual(self.bench.parse_args(["--audio", "x.wav", "--models", "remote", "--allow-real-audio"]).allow_real_audio, True)

    def test_without_the_flag_an_external_engine_runs_on_the_synthetic_clip_and_the_report_says_so(self):
        code, out, err = self.main("--audio", str(self.wav), "--models", "remote", "--synthetic-seconds", "6")
        self.assertEqual(code, 0, err)
        self.assertIn("note: --audio is NOT sent to remote", out)
        self.assertEqual(len(self.engines), 1)
        asked = self.engines[0].calls
        self.assertGreater(len(asked), 0)
        self.assertLessEqual(max(n for n, _l, _p in asked), 6 * SR)
        summary = (self.root / "bench-out" / "summary.md").read_text(encoding="utf-8")
        self.assertIn("Synthetic clip (no recorded voice left this Mac) for: remote", summary)
        rows = json.loads((self.root / "bench-out" / "summary.json").read_text(encoding="utf-8"))["models"]
        self.assertTrue(rows[0]["synthetic_clip"])
        self.assertIn("(no model produced a result)", (self.root / "bench-out" / "comparison.md").read_text(encoding="utf-8"))   # synthetic text is compared with nothing

    def test_a_synthetic_only_run_needs_no_audio_file_at_all(self):
        code, out, err = self.main("--models", "remote", "--synthetic-seconds", "5")
        self.assertEqual(code, 0, err)
        self.assertIn("synthetic clip 5.0s", out)
        rows = json.loads((self.root / "bench-out" / "summary.json").read_text(encoding="utf-8"))
        self.assertIsNone(rows["audio"])
        self.assertIsNone(rows["vad"])

    def test_real_audio_needs_the_flag_a_terminal_and_the_typed_sentence(self):
        args = ("--audio", str(self.wav), "--models", "remote", "--allow-real-audio")
        code, _out, err = self.main(*args)                                                      # not a terminal
        self.assertEqual(code, 2)
        self.assertEqual(self.engines, [])
        code, _out, err = self.main(*args, stdin=self.tty("maybe"))                             # the wrong sentence
        self.assertEqual(code, 1)
        self.assertEqual(self.engines, [])                                                      # no engine was even built
        code, out, err = self.main(*args, stdin=self.tty(cli.REAL_AUDIO_PHRASE))
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.engines), 1)
        asked = sum(n for n, _l, _p in self.engines[0].calls)
        self.assertGreater(asked, 3 * SR)                                                       # the 6 s file went (less its silence), not a 20 s clip

    def test_local_models_always_get_the_audio_and_need_no_confirmation(self):
        seen = []

        def local(model, allow_download):
            engine = FakeLocalEngine(["local text"])
            seen.append(engine)
            return engine
        with mock.patch.object(self.bench, "make_engine", local):
            code, out, err = self.main("--audio", str(self.wav), "--models", "mlx-community/some-local-model")
        self.assertEqual(code, 0, err)
        self.assertNotIn("NOT sent", out)
        self.assertGreater(sum(n for n, _l, _p in seen[0].calls), 3 * SR)

    def test_the_real_make_engine_refuses_an_engine_without_consent_as_an_error_of_that_model(self):
        real = load_bench()                                                                     # a module without the fake engine of setUp
        result = real.run_model("remote", cli.synthetic_audio(2.0), None, real.Vocab(), real.Config(), "en", "none", False)
        self.assertIn("EngineRefused", result["error"])
        self.assertIn("remote is refused (no-consent)", result["error"])
        self.assertEqual(self.transport.calls, [])


if __name__ == "__main__":
    unittest.main()
