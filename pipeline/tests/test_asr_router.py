"""asr_router.py (SPEC 18): the circuit breaker, RoutedEngine (fallback order, one fallback, the
uncached gate, caps, the prompt rule, the provenance record) and build_engine. The members are fakes (asr_support), the breaker runs on a fake
clock; the last class drives the real asr.transcribe_tracks through build_engine with an in-process transport.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import json
import logging
import subprocess
import sys
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from asr_support import (HOST, TOKEN, AsrCase, FakeClock, FakeCloudEngine, FakeLocalEngine, FakeTransport, MiniCloudEngine, MiniRemoteEngine, audio,
                         consent_entry, error_answer, fake_registry, json_response, make_run, usage_lines)
from golden import make_golden as mg

from mcap import asr, asr_creds, asr_engines, policy
from mcap.asr_engines import (EngineAuthError, EngineCapReached, EngineError, EnginePolicyDenied, EngineTransient, EngineUnavailable,
                              ModelNotAvailable, engine_caps)
from mcap.asr_http import EngineHttpError
from mcap.asr_router import CircuitBreaker, RoutedEngine, build_engine, build_member, effective_cap_minutes
from mcap.vocab import parse_vocab_text

logging.getLogger("mcap").addHandler(logging.NullHandler())


# ======================================================================================================================
class BreakerTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock(0.0)
        self.breaker = CircuitBreaker(3, 120.0, 600.0, clock=self.clock)

    def fail(self, n=1):
        for _ in range(n):
            self.breaker.failure()

    def test_it_starts_closed_and_lets_everything_through(self):
        self.assertEqual((self.breaker.state, self.breaker.opened, self.breaker.permanent), ("closed", 0, False))
        self.assertTrue(all(self.breaker.allow() for _ in range(5)))

    def test_three_consecutive_failures_open_it(self):
        self.fail(2)
        self.assertEqual(self.breaker.state, "closed")
        self.assertTrue(self.breaker.allow())
        self.fail()
        self.assertEqual((self.breaker.state, self.breaker.opened), ("open", 1))
        self.assertFalse(self.breaker.allow())

    def test_a_success_resets_the_count(self):
        self.fail(2)
        self.breaker.success()
        self.fail(2)
        self.assertEqual(self.breaker.state, "closed")
        self.fail()
        self.assertEqual(self.breaker.state, "open")

    def test_the_threshold_and_the_cooldown_are_parameters(self):
        b = CircuitBreaker(1, 5.0, clock=self.clock)
        b.failure()
        self.assertEqual(b.state, "open")
        self.clock.advance(4.9)
        self.assertFalse(b.allow())
        self.clock.advance(0.2)
        self.assertTrue(b.allow())

    def test_after_the_cooldown_exactly_one_probe_goes_through(self):
        self.fail(3)
        self.clock.advance(119.9)
        self.assertFalse(self.breaker.allow())
        self.clock.advance(0.1)
        self.assertTrue(self.breaker.allow())                              # the probe
        self.assertEqual(self.breaker.state, "half-open")
        self.assertFalse(self.breaker.allow())                             # nobody else while it is out
        self.assertFalse(self.breaker.allow())

    def test_a_probe_that_succeeds_closes_it_and_resets_the_cooldown(self):
        self.fail(3)
        self.clock.advance(120)
        self.assertTrue(self.breaker.allow())
        self.breaker.success()
        self.assertEqual((self.breaker.state, self.breaker.cooldown), ("closed", 120.0))
        self.assertTrue(self.breaker.allow())
        self.fail(2)
        self.assertEqual(self.breaker.state, "closed")                     # the count started again from zero

    def test_a_probe_that_fails_doubles_the_cooldown_up_to_600(self):
        self.fail(3)
        waits = []
        for _ in range(6):
            cooldown = self.breaker.cooldown
            waits.append(cooldown)
            self.clock.advance(cooldown - 0.1)
            self.assertFalse(self.breaker.allow(), "not yet")
            self.clock.advance(0.1)
            self.assertTrue(self.breaker.allow(), "the probe")
            self.breaker.failure()
            self.assertEqual(self.breaker.state, "open")
        self.assertEqual(waits, [120.0, 240.0, 480.0, 600.0, 600.0, 600.0])
        self.assertEqual(self.breaker.opened, 1)                           # one outage, however many probes failed

    def test_a_success_after_long_trouble_starts_over_at_the_base_cooldown(self):
        self.fail(3)
        for _ in range(3):
            self.clock.advance(self.breaker.cooldown)
            self.assertTrue(self.breaker.allow())
            self.breaker.failure()
        self.clock.advance(self.breaker.cooldown)
        self.assertTrue(self.breaker.allow())
        self.breaker.success()
        self.fail(3)
        self.assertEqual(self.breaker.cooldown, 120.0)
        self.assertEqual(self.breaker.opened, 2)

    def test_a_permanent_failure_never_lets_a_probe_through(self):
        self.breaker.failure(permanent=True)
        self.assertEqual((self.breaker.state, self.breaker.permanent, self.breaker.opened), ("open", True, 1))
        for hours in (1, 10, 1000):
            self.clock.advance(hours * 3600)
            self.assertFalse(self.breaker.allow())
        self.breaker.success()                                             # a stray success does not undo it
        self.assertFalse(self.breaker.allow())
        self.assertEqual(self.breaker.remaining(), float("inf"))

    def test_a_permanent_failure_after_a_transient_opening_counts_once(self):
        self.fail(3)
        self.breaker.failure(permanent=True)
        self.assertEqual((self.breaker.opened, self.breaker.permanent), (1, True))

    def test_trip_opens_at_once(self):
        self.breaker.trip()
        self.assertEqual((self.breaker.state, self.breaker.opened, self.breaker.permanent), ("open", 1, False))
        self.clock.advance(120)
        self.assertTrue(self.breaker.allow())

    def test_trip_during_a_probe_doubles_the_cooldown(self):
        self.breaker.trip()
        self.clock.advance(120)
        self.assertTrue(self.breaker.allow())
        self.breaker.trip()
        self.assertEqual((self.breaker.state, self.breaker.cooldown), ("open", 240.0))

    def test_abandon_gives_the_probe_back_at_once(self):
        self.fail(3)
        self.clock.advance(120)
        self.assertTrue(self.breaker.allow())
        self.breaker.abandon()
        self.assertEqual(self.breaker.state, "open")
        self.assertTrue(self.breaker.allow())                              # no new cooldown: the probe never ran
        self.breaker.abandon()
        self.breaker.success()
        self.assertEqual(self.breaker.state, "closed")

    def test_abandon_does_nothing_when_not_probing(self):
        self.breaker.abandon()
        self.assertEqual(self.breaker.state, "closed")
        self.fail(3)
        self.breaker.abandon()
        self.assertFalse(self.breaker.allow())

    def test_remaining(self):
        self.assertEqual(self.breaker.remaining(), 0.0)
        self.fail(3)
        self.clock.advance(20)
        self.assertEqual(self.breaker.remaining(), 100.0)
        self.clock.advance(500)
        self.assertEqual(self.breaker.remaining(), 0.0)

    def test_the_maximum_never_lies_below_the_base(self):
        b = CircuitBreaker(1, 900.0, 600.0, clock=self.clock)
        self.assertEqual(b.max_cooldown, 900.0)

    def test_only_one_thread_gets_the_probe(self):
        self.fail(3)
        self.clock.advance(120)
        results, barrier = [], threading.Barrier(8)

        def ask():
            barrier.wait()
            results.append(self.breaker.allow())
        threads = [threading.Thread(target=ask) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results.count(True), 1)


# ======================================================================================================================
class RoutedCase(AsrCase):
    def server(self, behaviors=("cloud text",), **kw):
        kw.setdefault("kind", "server")
        kw.setdefault("engine_id", "remote")
        return FakeCloudEngine(behaviors, **kw)

    def router(self, primary=None, fallback="local", *, gate="gate", threshold=3, cooldown=120.0, progress=None):
        primary = primary if primary is not None else self.server()
        fallback = FakeLocalEngine() if fallback == "local" else fallback
        self.breaker = CircuitBreaker(threshold, cooldown, 600.0, clock=self.clock)
        self.local = fallback
        return RoutedEngine(primary, fallback, self.breaker, gate=self.gate if gate == "gate" else gate, clock=self.clock, progress=progress)

    def texts(self, router, n=1, prompt=None):
        return [router.transcribe_chunk(audio(), "en", prompt)["text"] for _ in range(n)]


class FallbackTests(RoutedCase):
    def test_the_primary_takes_the_chunk_and_the_fallback_is_not_even_loaded(self):
        r = self.router()
        r.load()
        self.assertEqual(self.texts(r, 3), ["cloud text"] * 3)
        self.assertEqual((r.primary.load_calls, self.local.load_calls, len(self.local.calls), r.fallbacks), (1, 0, 0, 0))
        self.assertEqual(dict(r.chunks), {"remote": 3})

    def test_a_failed_chunk_goes_to_the_fallback_and_only_that_chunk(self):
        r = self.router(self.server(["a", EngineTransient("busy"), "c"]))
        r.load()
        self.assertEqual(self.texts(r, 3), ["a", "local text", "c"])
        self.assertEqual((len(r.primary.calls), len(self.local.calls), r.fallbacks), (3, 1, 1))
        self.assertEqual(dict(r.chunks), {"remote": 2, "whisper": 1})
        self.assertEqual((self.local.load_calls, self.breaker.state), (1, "closed"))     # loaded when first needed; one failure is not three

    def test_a_chunk_is_never_processed_by_both(self):
        r = self.router(self.server(["a", EngineTransient("x"), "c", EngineAuthError("y")]))
        chunks = [audio(float(n)) for n in (1, 2, 3, 4)]                     # one length each: the length tells the chunks apart
        results = [r.transcribe_chunk(chunk, "en", None)["text"] for chunk in chunks]
        self.assertEqual(results, ["a", "local text", "c", "local text"])
        self.assertEqual([call[0] for call in r.primary.calls], [16000, 32000, 48000, 64000])     # the primary was asked first, every time
        self.assertEqual([call[0] for call in self.local.calls], [32000, 64000])                  # the fallback got only the chunks it failed
        self.assertEqual((sum(r.chunks.values()), r.fallbacks), (4, 2))                           # four chunks, four results: one engine each

    def test_without_a_fallback_the_error_is_the_primarys_own(self):
        err = EngineTransient("the server answered HTTP 503")
        r = self.router(self.server([err]), fallback=None)
        with self.assertRaises(EngineTransient) as cm:
            r.transcribe_chunk(audio(), "en", None)
        self.assertIs(cm.exception, err)

    def test_only_one_fallback_nothing_is_chained(self):
        third = FakeLocalEngine(["third engine"])
        second = self.server([EngineTransient("second fails")], engine_id="azure", kind="cloud")
        r = RoutedEngine(self.server([EngineTransient("first fails")]), second, CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        with self.assertRaises(EngineTransient) as cm:
            r.transcribe_chunk(audio(), "en", None)
        self.assertEqual(str(cm.exception), "second fails")                 # the fallback's failure is the chunk's failure
        self.assertEqual((len(r.primary.calls), len(second.calls), len(third.calls)), (1, 1, 0))

    def test_an_external_fallback_works_like_a_local_one(self):
        second = self.server(["second"], engine_id="azure", kind="cloud")
        r = RoutedEngine(self.server([EngineTransient("x")]), second, CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        self.assertEqual(r.transcribe_chunk(audio(), "en", None)["text"], "second")
        self.assertEqual(dict(r.chunks), {"azure": 1})

    def test_the_failures_of_the_fallback_do_not_count_against_the_primarys_circuit(self):
        r = self.router(self.server([EngineTransient("down")]), FakeLocalEngine([RuntimeError("local broke")]), threshold=3)
        for _ in range(2):
            with self.assertRaises(RuntimeError):
                r.transcribe_chunk(audio(), "en", None)
        self.assertEqual((self.breaker.state, self.breaker.opened), ("closed", 0))

    def test_every_trigger_sends_the_chunk_to_the_fallback(self):
        for exc in (EngineTransient("t"), EngineAuthError("a"), EnginePolicyDenied("p"), EngineCapReached("c")):
            with self.subTest(exc=type(exc).__name__):
                r = self.router(self.server([exc]))
                self.assertEqual(self.texts(r), ["local text"])

    def test_what_is_not_a_trigger_propagates_and_leaves_the_circuit_alone(self):
        for exc in (EngineError("content"), EngineHttpError(422, "unprocessable_audio"), ValueError("v"), RuntimeError("r"), KeyError("k")):
            with self.subTest(exc=type(exc).__name__):
                r = self.router(self.server([exc]))
                with self.assertRaises(type(exc)):
                    r.transcribe_chunk(audio(), "en", None)
                self.assertEqual((len(self.local.calls), self.breaker.state, self.breaker.opened), (0, "closed", 0))

    def test_an_empty_answer_is_not_a_trigger(self):
        r = self.router(self.server([{"text": "", "segments": [], "language": "en", "avg_logprob": None}]))
        self.assertEqual(r.transcribe_chunk(audio(), "en", None)["segments"], [])
        self.assertEqual(len(self.local.calls), 0)


class LoadTests(RoutedCase):
    def test_load_is_idempotent(self):
        r = self.router()
        r.load()
        r.load()
        r.load()
        self.assertEqual(r.primary.load_calls, 1)

    def test_a_primary_that_does_not_load_opens_the_circuit_and_the_fallback_is_loaded(self):
        r = self.router(self.server(load_error=EnginePolicyDenied("the server was refused: retention")))
        r.load()
        self.assertEqual((self.breaker.state, self.breaker.permanent, self.breaker.opened), ("open", True, 1))
        self.assertEqual(self.local.load_calls, 1)
        self.assertEqual(self.texts(r, 3), ["local text"] * 3)
        self.assertEqual((len(r.primary.calls), r.fallbacks, dict(r.chunks)), (0, 3, {"whisper": 3}))
        r.load()
        self.assertEqual((r.primary.load_calls, self.local.load_calls), (1, 1))

    def test_a_transient_load_failure_is_probed_again_after_the_cooldown(self):
        primary = self.server(["cloud text"], load_error=EngineTransient("health: connect"))
        r = self.router(primary)
        r.load()
        self.assertEqual((self.breaker.state, self.breaker.permanent), ("open", False))
        self.assertEqual(self.texts(r), ["local text"])
        self.clock.advance(120)
        primary.load_error = None                                           # the server is back
        self.assertEqual(self.texts(r, 2), ["cloud text", "cloud text"])
        self.assertEqual((primary.load_calls, self.breaker.state), (2, "closed"))

    def test_a_probe_whose_load_fails_again_doubles_the_cooldown(self):
        primary = self.server(load_error=EngineTransient("down"))
        r = self.router(primary)
        r.load()
        self.clock.advance(120)
        self.assertEqual(self.texts(r), ["local text"])                     # the probe: load failed again
        self.assertEqual((primary.load_calls, self.breaker.cooldown), (2, 240.0))
        self.clock.advance(239)
        self.texts(r)
        self.assertEqual(primary.load_calls, 2)
        self.clock.advance(1)
        self.texts(r)
        self.assertEqual(primary.load_calls, 3)

    def test_without_a_fallback_load_raises_what_stopped_it(self):
        for exc in (EngineTransient("unreachable"), EnginePolicyDenied("refused"), EngineAuthError("no credential")):
            with self.subTest(exc=type(exc).__name__):
                r = self.router(self.server(load_error=exc), fallback=None)
                with self.assertRaises(type(exc)):
                    r.load()

    def test_a_load_that_failed_is_tried_again_by_the_next_load_call_when_there_is_no_fallback(self):
        primary = self.server(load_error=EngineTransient("unreachable"))
        r = self.router(primary, fallback=None)
        with self.assertRaises(EngineTransient):
            r.load()
        primary.load_error = None
        r.load()                                                            # the next track
        self.assertEqual(primary.load_calls, 2)

    def test_a_server_that_cannot_be_reached_is_reported_even_when_the_local_engine_fails_too(self):
        r = self.router(self.server(load_error=EngineTransient("unreachable")), FakeLocalEngine(load_error=ModelNotAvailable("no model")))
        with self.assertRaises(EngineTransient):
            r.load()

    def test_a_refusal_is_not_hidden_behind_a_local_failure(self):
        r = self.router(self.server(load_error=EnginePolicyDenied("refused")), FakeLocalEngine(load_error=ModelNotAvailable("no model")))
        with self.assertRaises(ModelNotAvailable):
            r.load()

    def test_a_fallback_that_cannot_load_fails_each_chunk_without_loading_again(self):
        r = self.router(self.server([EngineTransient("x")]), FakeLocalEngine(load_error=ModelNotAvailable("no model")))
        for _ in range(3):
            with self.assertRaises(ModelNotAvailable):
                r.transcribe_chunk(audio(), "en", None)
        self.assertEqual(self.local.load_calls, 1)

    def test_a_runtime_that_is_missing_is_permanent(self):
        r = self.router(self.server(load_error=EngineUnavailable("no adapter")))
        r.load()
        self.assertEqual((self.breaker.permanent, self.texts(r)), (True, ["local text"]))

    def test_a_cap_at_load_bypasses_without_opening(self):
        primary = self.server(load_error=EngineCapReached("cap"))
        r = self.router(primary)
        r.load()
        self.assertEqual((self.breaker.state, self.breaker.opened), ("closed", 0))
        primary.load_error = None
        self.assertEqual(self.texts(r), ["cloud text"])                      # asked again, and the load is repeated for it

    def test_a_local_primary_that_cannot_load_hands_over_to_the_fallback(self):
        local = FakeLocalEngine(load_error=ModelNotAvailable("no model"))
        r = RoutedEngine(local, self.server(["server text"]), CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        r.load()
        self.assertEqual(r.transcribe_chunk(audio(), "en", None)["text"], "server text")

    def test_the_user_is_told_when_the_fallback_is_being_loaded(self):
        notes = []
        r = self.router(self.server(load_error=EngineTransient("x")), progress=notes.append)
        r.load()
        self.assertEqual(len(notes), 1)
        self.assertNotIn(HOST, notes[0])
        self.router(self.server(), progress=notes.append).load()
        self.assertEqual(len(notes), 1)

    def test_a_progress_callback_that_raises_is_ignored(self):
        def broken(text):
            raise RuntimeError("ui gone")
        self.router(self.server(load_error=EngineTransient("x")), progress=broken).load()


class CircuitFlowTests(RoutedCase):
    def test_three_failures_open_the_circuit_and_the_primary_is_left_alone(self):
        r = self.router(self.server([EngineTransient("x")] * 3 + ["back"]))
        r.load()
        self.assertEqual(self.texts(r, 3), ["local text"] * 3)
        self.assertEqual((self.breaker.state, len(r.primary.calls)), ("open", 3))
        self.assertEqual(self.texts(r, 5), ["local text"] * 5)
        self.assertEqual(len(r.primary.calls), 3)                            # nothing more was sent to it
        self.assertEqual((r.fallbacks, dict(r.chunks)), (8, {"whisper": 8}))

    def test_after_the_cooldown_one_chunk_probes_and_success_closes_it(self):
        r = self.router(self.server([EngineTransient("x")] * 3 + ["back"]))
        self.texts(r, 4)
        self.clock.advance(120)
        self.assertEqual(self.texts(r, 3), ["back", "back", "back"])         # the probe, then normal traffic again
        self.assertEqual((self.breaker.state, len(r.primary.calls)), ("closed", 6))

    def test_a_failed_probe_doubles_the_cooldown(self):
        r = self.router(self.server([EngineTransient("x")]))
        self.texts(r, 3)
        for expected in (240.0, 480.0, 600.0, 600.0):
            self.clock.advance(self.breaker.cooldown)
            calls = len(r.primary.calls)
            self.assertEqual(self.texts(r), ["local text"])
            self.assertEqual((len(r.primary.calls), self.breaker.cooldown), (calls + 1, expected))
        self.assertEqual(self.breaker.opened, 1)

    def test_a_success_between_failures_keeps_it_closed(self):
        r = self.router(self.server([EngineTransient("x"), EngineTransient("x"), "ok"] * 3))
        self.texts(r, 9)
        self.assertEqual((self.breaker.state, self.breaker.opened, len(r.primary.calls)), ("closed", 0, 9))

    def test_authentication_and_policy_errors_open_it_for_the_rest_of_the_run(self):
        for exc in (EngineAuthError("no"), EnginePolicyDenied("no")):
            with self.subTest(exc=type(exc).__name__):
                r = self.router(self.server([exc, "never"]))
                self.assertEqual(self.texts(r, 3), ["local text"] * 3)
                self.assertEqual((self.breaker.permanent, self.breaker.opened, len(r.primary.calls)), (True, 1, 1))
                self.clock.advance(10 ** 6)
                self.assertEqual(self.texts(r), ["local text"])
                self.assertEqual(len(r.primary.calls), 1)

    def test_a_cap_bypasses_the_chunk_without_tripping_anything(self):
        r = self.router(self.server([EngineCapReached("cap")] * 5 + ["ok"]))
        self.assertEqual(self.texts(r, 5), ["local text"] * 5)
        self.assertEqual((self.breaker.state, self.breaker.opened, len(r.primary.calls)), ("closed", 0, 5))   # asked every time
        self.assertEqual(self.texts(r), ["ok"])                                                              # and used again when it can

    def test_a_cap_during_a_probe_gives_the_probe_back(self):
        r = self.router(self.server([EngineTransient("x")] * 3 + [EngineCapReached("cap"), "back"]))
        self.texts(r, 3)
        self.clock.advance(120)
        self.assertEqual(self.texts(r), ["local text"])                      # the probe hit the cap
        self.assertEqual(self.breaker.state, "open")
        self.assertEqual(self.texts(r), ["back"])                            # the next chunk may probe at once, no new cooldown
        self.assertEqual(self.breaker.state, "closed")

    def test_a_chunk_error_that_is_not_a_trigger_gives_a_probe_back_too(self):
        r = self.router(self.server([EngineTransient("x")] * 3 + [ValueError("bug"), "back"]))
        self.texts(r, 3)
        self.clock.advance(120)
        with self.assertRaises(ValueError):
            r.transcribe_chunk(audio(), "en", None)
        self.assertEqual(self.texts(r), ["back"])

    def test_without_a_fallback_an_open_circuit_fails_fast_with_a_fixed_message(self):
        r = self.router(self.server([EngineTransient("x")]), fallback=None)
        for _ in range(3):
            with self.assertRaises(EngineTransient):
                r.transcribe_chunk(audio(), "en", None)
        with self.assertRaises(EngineTransient) as cm:
            r.transcribe_chunk(audio(), "en", None)
        self.assertEqual(str(cm.exception), "the engine is unavailable: circuit open")
        self.assertEqual(len(r.primary.calls), 3)

    def test_without_a_fallback_a_permanent_opening_keeps_its_kind(self):
        cases = [(EngineAuthError("a"), EngineAuthError, "the engine refused its credential earlier in this run: circuit open"),
                 (EnginePolicyDenied("p"), EnginePolicyDenied, "external ASR is not allowed in this run: circuit open")]
        for exc, kind, message in cases:
            with self.subTest(kind=kind.__name__):
                r = self.router(self.server([exc]), fallback=None)
                with self.assertRaises(kind):
                    r.transcribe_chunk(audio(), "en", None)
                with self.assertRaises(kind) as cm:
                    r.transcribe_chunk(audio(), "en", None)
                self.assertEqual(str(cm.exception), message)
                self.assertEqual(len(r.primary.calls), 1)

    def test_without_a_fallback_a_cap_is_the_primarys_error(self):
        r = self.router(self.server([EngineCapReached("cap")]), fallback=None)
        with self.assertRaises(EngineCapReached):
            r.transcribe_chunk(audio(), "en", None)

    def test_the_circuit_settings_come_from_the_constructor(self):
        r = self.router(self.server([EngineTransient("x")]), threshold=2, cooldown=30.0)
        self.texts(r, 2)
        self.assertEqual(self.breaker.state, "open")
        self.clock.advance(30)
        calls = len(r.primary.calls)
        self.texts(r)
        self.assertEqual(len(r.primary.calls), calls + 1)

    def test_the_breaker_is_bound_to_the_members_so_they_can_report_its_state(self):
        r = self.router()
        self.assertIs(r.primary.breaker, self.breaker)
        self.assertFalse(hasattr(self.local, "breaker"))                    # a local engine has no use for it


class GateTests(RoutedCase):
    def test_a_gate_that_is_closed_from_the_start_keeps_the_primary_from_being_asked(self):
        self.gate.close("local_only")
        r = self.router()
        r.load()
        self.assertEqual(self.texts(r, 3), ["local text"] * 3)
        self.assertEqual(len(r.primary.calls), 0)
        self.assertEqual((self.breaker.permanent, self.breaker.opened), (True, 1))

    def test_the_gate_is_read_for_every_chunk_never_cached(self):
        r = self.router()
        self.texts(r, 4)
        self.assertEqual(self.gate.calls, 4)

    def test_a_gate_that_closes_mid_run_sends_the_next_chunks_to_the_fallback_without_a_request(self):
        r = self.router()
        self.gate.close_after(2)
        self.assertEqual(self.texts(r, 5), ["cloud text", "cloud text", "local text", "local text", "local text"])
        self.assertEqual(len(r.primary.calls), 2)
        self.assertEqual((r.fallbacks, dict(r.chunks)), (3, {"remote": 2, "whisper": 3}))

    def test_closing_is_a_ratchet_within_a_run(self):
        r = self.router()
        self.gate.close_after(1)
        self.texts(r, 2)
        self.gate.open()                                                     # a relaxation mid-run is not applied
        self.assertEqual(self.texts(r, 3), ["local text"] * 3)
        self.assertEqual(len(r.primary.calls), 1)

    def test_once_it_is_out_for_good_the_gate_is_not_asked_again(self):
        r = self.router()
        self.gate.close_after(1)
        self.texts(r, 6)
        self.assertEqual(self.gate.calls, 2)

    def test_without_a_fallback_a_closed_gate_is_a_policy_error_with_the_reason(self):
        self.gate.close("policy-lane")
        r = self.router(fallback=None)
        with self.assertRaises(EnginePolicyDenied) as cm:
            r.transcribe_chunk(audio(), "en", None)
        self.assertEqual((str(cm.exception), cm.exception.code), ("external ASR is not allowed now (policy-lane)", "policy-lane"))
        self.assertEqual(len(r.primary.calls), 0)

    def test_a_gate_that_raises_or_answers_with_text_is_closed(self):
        def broken():
            raise RuntimeError("gate bug")
        r = self.router(gate=broken)
        self.assertEqual(self.texts(r), ["local text"])
        r2 = self.router(gate=lambda: "session-unreadable")
        self.assertEqual(self.texts(r2), ["local text"])

    def test_a_local_primary_is_not_gated(self):
        self.gate.close("local_only")
        r = RoutedEngine(FakeLocalEngine(["local"]), self.server(["server"]), CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        self.assertEqual(r.transcribe_chunk(audio(), "en", None)["text"], "local")
        self.assertEqual(self.gate.calls, 0)

    def test_language_id_is_gated_too(self):
        self.gate.close("local_only")
        r = self.router(self.server(supports_lid=True))
        self.assertEqual(len(r.detect_languages([audio()])), 1)
        self.assertEqual(r.primary.lid_calls, 0)
        self.assertEqual(self.local.lid_calls, 1)


class PromptTests(RoutedCase):
    def test_the_prompt_goes_only_to_members_that_use_it(self):
        r = self.router(self.server([EngineTransient("x"), "ok"]))
        r.transcribe_chunk(audio(), "en", "Terms: A, B")
        r.transcribe_chunk(audio(), "en", "Terms: A, B")
        self.assertEqual([c[2] for c in r.primary.calls], [None, None])
        self.assertEqual([c[2] for c in self.local.calls], ["Terms: A, B"])

    def test_the_router_looks_like_a_prompt_user_when_the_fallback_is_whisper(self):
        r = self.router()
        self.assertTrue(r.uses_prompt)
        self.assertTrue(engine_caps(r).uses_prompt)
        self.assertEqual(r.prompt_frames, FakeLocalEngine.prompt_frames)
        self.assertEqual(r.tokenizer.encode("a b c"), ["a", "b", "c"])

    def test_without_a_prompt_user_the_router_has_none(self):
        second = self.server(engine_id="azure", kind="cloud")
        r = RoutedEngine(self.server(), second, CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        self.assertFalse(r.uses_prompt)
        self.assertEqual(r.prompt_frames, {})
        with self.assertRaises(NotImplementedError):
            r.tokenizer
        r2 = RoutedEngine(self.server(), None, CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        self.assertFalse(engine_caps(r2).uses_prompt)

    def test_a_local_primary_gets_the_prompt(self):
        local = FakeLocalEngine()
        r = RoutedEngine(local, self.server(), CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        r.transcribe_chunk(audio(), "en", "Terms: A")
        self.assertEqual(local.calls[0][2], "Terms: A")

    def test_the_retry_without_the_prompt_never_sends_the_same_audio_to_a_server_twice(self):
        r = self.router()
        chunk = audio()
        first = r.transcribe_chunk(chunk, "en", "Terms: A")
        again = r.transcribe_chunk(chunk, "en", None)                       # decode_chunk's retry
        self.assertIs(again, first)
        self.assertEqual((len(r.primary.calls), len(self.local.calls)), (1, 0))
        self.assertEqual(dict(r.chunks), {"remote": 1})
        r.transcribe_chunk(chunk, "en", None)                                 # a third call with this audio is a new chunk
        self.assertEqual(len(r.primary.calls), 2)

    def test_the_retry_goes_to_the_member_that_answered_the_first_time(self):
        r = self.router(self.server([EngineTransient("x"), "must not be asked"]))
        chunk = audio()
        r.transcribe_chunk(chunk, "en", "Terms: A")                          # the primary failed, the fallback answered
        text = r.transcribe_chunk(chunk, "en", None)["text"]
        self.assertEqual(text, "local text")
        self.assertEqual([c[2] for c in self.local.calls], ["Terms: A", None])  # a real retry, without the prompt, by the same engine
        self.assertEqual(len(r.primary.calls), 1)

    def test_a_different_audio_with_no_prompt_is_a_new_chunk(self):
        r = self.router()
        r.transcribe_chunk(audio(), "en", "Terms: A")
        r.transcribe_chunk(audio(), "en", None)
        self.assertEqual(len(r.primary.calls), 2)

    def test_two_calls_without_a_prompt_are_two_chunks(self):
        r = self.router()
        chunk = audio()
        r.transcribe_chunk(chunk, "en", None)
        r.transcribe_chunk(chunk, "en", None)
        self.assertEqual(len(r.primary.calls), 2)

    def test_the_prompt_text_a_server_used_is_offered_for_the_echo_guard(self):
        primary = self.server()
        primary.prompt_text_seen = lambda: "KO frame. Terms: A"
        r = self.router(primary)
        self.assertEqual(r.prompt_text_seen(), "KO frame. Terms: A")
        self.assertIsNone(self.router().prompt_text_seen())


class CapabilityTests(RoutedCase):
    def test_kind_is_the_first_external_member(self):
        self.assertEqual(self.router().kind, "server")
        cloud = RoutedEngine(self.server(kind="cloud", engine_id="azure"), FakeLocalEngine(), CircuitBreaker(clock=self.clock), clock=self.clock)
        self.assertEqual(cloud.kind, "cloud")
        hybrid = RoutedEngine(FakeLocalEngine(), self.server(kind="cloud", engine_id="azure"), CircuitBreaker(clock=self.clock), clock=self.clock)
        self.assertEqual(hybrid.kind, "cloud")                              # a local primary with an external fallback is still external
        local = RoutedEngine(FakeLocalEngine(), None, CircuitBreaker(clock=self.clock), clock=self.clock)
        self.assertEqual(local.kind, "local")

    def test_the_chunk_limit_is_the_shortest_of_the_members(self):
        r = self.router(self.server(max_chunk_s=20.0))
        self.assertEqual(engine_caps(r).max_chunk_s, 20.0)
        self.assertEqual(engine_caps(self.router()).max_chunk_s, 28.0)
        r3 = self.router(self.server(chunk_params={"max_chunk_s": 15.0}), fallback=FakeLocalEngine(max_chunk_s=25.0))
        self.assertEqual(engine_caps(r3).max_chunk_s, 15.0)

    def test_language_id_follows_the_member_that_can_do_it(self):
        r = self.router(self.server(supports_lid=True))
        self.assertTrue(engine_caps(r).supports_lid)
        self.assertEqual(len(r.detect_languages([audio(), audio()], ("ko", "en"))), 2)
        self.assertEqual((r.primary.lid_calls, self.local.lid_calls), (1, 0))

    def test_language_id_falls_back_when_the_primary_cannot_be_reached(self):
        primary = self.server(supports_lid=True)
        primary.detect_languages = mock.Mock(side_effect=EngineTransient("unreachable"))
        r = self.router(primary)
        self.assertEqual(len(r.detect_languages([audio()])), 1)
        self.assertEqual(self.local.lid_calls, 1)
        self.assertEqual(self.breaker.state, "closed")                      # one failure

    def test_language_id_by_the_fallback_when_the_primary_has_none(self):
        r = self.router(self.server(supports_lid=False))
        self.assertFalse(engine_caps(r).supports_lid)
        self.assertEqual(len(r.detect_languages([audio()])), 1)
        self.assertEqual((r.primary.lid_calls, self.local.lid_calls), (0, 1))

    def test_no_language_id_anywhere_gives_none(self):
        r = RoutedEngine(self.server(), self.server(engine_id="azure", kind="cloud"), CircuitBreaker(clock=self.clock), clock=self.clock)
        self.assertIsNone(r.detect_languages([audio()]))

    def test_an_unreachable_primary_with_language_id_and_no_fallback_raises(self):
        primary = self.server(supports_lid=True)
        primary.detect_languages = mock.Mock(side_effect=EngineTransient("unreachable"))
        r = self.router(primary, fallback=None)
        with self.assertRaises(EngineTransient):
            r.detect_languages([audio()])

    def test_an_unreachable_primary_with_language_id_and_a_fallback_without_it_raises(self):
        primary = self.server(supports_lid=True)
        primary.detect_languages = mock.Mock(side_effect=EngineTransient("unreachable"))
        r = RoutedEngine(primary, self.server(engine_id="azure", kind="cloud"), CircuitBreaker(clock=self.clock), clock=self.clock)
        with self.assertRaises(EngineTransient):
            r.detect_languages([audio()])

    def test_when_the_primary_is_out_for_good_the_router_describes_the_fallback(self):
        r = self.router(self.server(supports_lid=True, load_error=EnginePolicyDenied("refused"), residency="kr"))
        self.assertTrue(engine_caps(r).supports_lid)                         # before load: the primary's word
        r.load()
        self.assertEqual((engine_caps(r).residency, r.confidence), ("device", "logprob"))      # now the local engine's

    def test_chunk_params_are_the_leads(self):
        r = self.router(self.server(chunk_params={"max_inner_gap_s": 4.0}))
        self.assertEqual(r.chunk_params, {"max_inner_gap_s": 4.0})
        self.assertEqual(self.router().chunk_params, {})

    def test_the_progress_tag_says_who_is_working(self):
        r = self.router(self.server(["a", EngineTransient("x"), EngineTransient("x"), EngineTransient("x")]))
        self.assertEqual(r.progress_tag(), "")                                 # FakeCloudEngine has no tag of its own
        r.primary.progress_tag = lambda: "[server]"
        self.assertEqual(r.progress_tag(), "[server]")
        self.texts(r, 4)
        self.assertEqual(r.progress_tag(), "[local fallback]")
        ext = RoutedEngine(self.server(), self.server(engine_id="azure", kind="cloud"), CircuitBreaker(1, 1.0, clock=self.clock), clock=self.clock)
        ext.breaker.trip()
        self.assertEqual(ext.progress_tag(), "[cloud fallback]")
        self.assertEqual(RoutedEngine(FakeLocalEngine(), None, CircuitBreaker(clock=self.clock), clock=self.clock).progress_tag(), "")

    def test_describe_names_no_host(self):
        r = self.router(self.server(supports_lid=True))
        info = r.describe()
        self.assertEqual((info["engine"], info["kind"], info["fallback"], info["circuit"]), ("remote", "server", "whisper", "closed"))
        self.assertNotIn(HOST, json.dumps(info))

    def test_usage_is_the_sum_of_the_members(self):
        r = self.router(self.server([EngineTransient("x"), "ok"]), fallback=self.server(engine_id="azure", kind="cloud"))
        self.texts(r, 2)
        usage = r.usage()
        self.assertEqual(usage["requests"], 3)                              # two to the primary, one to the fallback
        self.assertEqual(usage["lid_requests"], 0)
        self.assertEqual(r.usage()["audio_s"], 6.0)

    def test_the_engine_id_is_the_primarys(self):
        self.assertEqual(self.router().engine_id, "remote")
        self.assertEqual(RoutedEngine(FakeLocalEngine(), None, CircuitBreaker(clock=self.clock), clock=self.clock).engine_id, "whisper")


class ReleaseTests(RoutedCase):
    def test_both_members_are_released(self):
        r = self.router()
        r.release()
        self.assertEqual((r.primary.release_calls, self.local.release_calls), (1, 1))

    def test_both_are_released_even_when_the_first_one_raises(self):
        r = self.router(self.server(release_error=RuntimeError("boom")))
        with self.assertLogs("mcap.asr", level="ERROR"):
            r.release()
        self.assertEqual((r.primary.release_calls, self.local.release_calls), (1, 1))

    def test_release_without_a_fallback(self):
        r = self.router(fallback=None)
        r.release()
        self.assertEqual(r.primary.release_calls, 1)


class ProvenanceTests(RoutedCase):
    def block(self, r):
        block = r.provenance()
        self.assertEqual(asr._clean_provenance(block), block)                  # asr.py keeps every key exactly as it is
        json.dumps(block, allow_nan=False)
        return block

    def test_a_server_that_did_everything(self):
        r = self.router(self.server())
        self.texts(r, 3)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["kind"], b["engine"], b["model"], b["destination"], b["region"]),
                         ("server", "server", "remote", "fake-cloud-model", "company-asr", "kr"))
        self.assertEqual((b["protocol"], b["consent_id"], b["chunks"], b["fallbacks"], b["circuit_opened"]),
                         ("mcap-asr/1", "c-fake", {"remote": 3}, 0, 0))
        self.assertEqual(b["sent"], {"requests": 3, "lid_requests": 0, "audio_s": 6.0, "bytes": 192000})
        self.assertEqual(b["schema"], 1)

    def test_a_cloud_engine_that_did_everything(self):
        r = self.router(self.server(kind="cloud", engine_id="azure"))
        self.texts(r, 2)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["kind"], b["destination"]), ("cloud", "cloud", "azure/kr"))

    def test_a_run_that_stayed_on_this_mac_even_though_the_server_was_allowed(self):
        self.gate.close("local_only")
        r = self.router(self.server())
        self.texts(r, 3)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["chunks"], b["fallbacks"], b["circuit_opened"], b["sent"]["requests"]),
                         ("local", {"whisper": 3}, 3, 1, 0))
        self.assertEqual((b["engine"], b["kind"], b["model"], b["destination"]), ("remote", "server", "fake-whisper", "company-asr"))

    def test_server_and_local_chunks_are_mixed(self):
        r = self.router(self.server(["a", "b", EngineTransient("x"), "c"]))
        self.texts(r, 4)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["chunks"], b["fallbacks"]), ("mixed", {"remote": 3, "whisper": 1}, 1))
        self.assertEqual(b["model"], "fake-cloud-model")                       # the model that did most of the work: the primary's

    def test_a_request_that_may_have_left_the_mac_counts_even_when_the_chunk_ended_up_local(self):
        r = self.router(self.server([EngineTransient("x")] * 3))
        self.texts(r, 5)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["chunks"], b["circuit_opened"]), ("mixed", {"whisper": 5}, 1))
        self.assertEqual(b["sent"]["requests"], 3)
        self.assertEqual(b["model"], "fake-whisper")

    def test_a_server_and_a_cloud_engine_are_mixed(self):
        r = self.router(self.server([EngineTransient("x"), "ok"]), fallback=self.server(["second"], kind="cloud", engine_id="azure"))
        self.texts(r, 2)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["destination"], b["chunks"]), ("mixed", "company-asr+azure/kr", {"azure": 1, "remote": 1}))

    def test_a_local_primary_with_an_unused_server_fallback_records_a_local_run(self):
        r = RoutedEngine(FakeLocalEngine(["a"]), self.server(), CircuitBreaker(clock=self.clock), gate=None, clock=self.clock)
        r.transcribe_chunk(audio(), "en", None)
        b = self.block(r)
        self.assertEqual((b["privacy"], b["kind"], b["engine"], b["chunks"]), ("local", "server", "whisper", {"whisper": 1}))

    def test_nothing_processed_and_nothing_sent_is_local(self):
        b = self.block(self.router())
        self.assertEqual((b["privacy"], b.get("chunks"), b["fallbacks"], b["sent"]["requests"]), ("local", None, 0, 0))

    def test_language_id_requests_are_data_sent(self):
        r = self.router(self.server(supports_lid=True))
        r.detect_languages([audio()])
        self.assertEqual(self.block(r)["privacy"], "server")
        self.assertEqual(self.block(r)["sent"]["lid_requests"], 1)

    def test_no_external_member_means_no_record(self):
        self.assertIsNone(RoutedEngine(FakeLocalEngine(), None, CircuitBreaker(clock=self.clock), clock=self.clock).provenance())
        both_local = RoutedEngine(FakeLocalEngine(), FakeLocalEngine(), CircuitBreaker(clock=self.clock), clock=self.clock)
        self.assertIsNone(both_local.provenance())

    def test_the_record_never_names_a_host_or_a_secret(self):
        r = self.router(self.server())
        self.texts(r, 2)
        text = json.dumps(self.block(r))
        self.assertNotIn(HOST, text)
        self.assertNotIn(TOKEN, text)

    def test_empty_values_are_left_out(self):
        primary = self.server(label="x")
        primary.consent_id = ""
        r = self.router(primary)
        self.texts(r)
        self.assertNotIn("consent_id", r.provenance())


# ======================================================================================================================
class BuildEngineTests(RoutedCase):
    def setUp(self):
        super().setUp()
        registry = fake_registry()
        registry.start()
        self.addCleanup(registry.stop)
        self.local_engine = FakeLocalEngine()
        patcher = mock.patch.object(asr_engines, "get_engine", return_value=self.local_engine)
        self.get_engine = patcher.start()
        self.addCleanup(patcher.stop)
        self.transports = []

    def factory(self):
        self.transports.append(FakeTransport(clock=self.clock))
        return self.transports[-1]

    def build(self, primary="remote", fallback="none", *, hooks=True, **kw):
        cfg, decision = make_run(self.cfg, primary, fallback, **{k: kw.pop(k) for k in ("consents", "capable", "local_only") if k in kw})
        extra = dict(transport_factory=self.factory, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock) if hooks else {}
        extra.update(kw)
        return build_engine(cfg, None, **extra), cfg, decision

    def test_a_missing_decision_is_refused(self):
        with self.assertRaises(EnginePolicyDenied) as cm:
            build_engine(self.cfg, None)
        self.assertEqual(str(cm.exception), "no policy decision")

    def test_a_decision_that_was_not_made_by_decide_asr_is_refused(self):
        cfg, decision = make_run(self.cfg, "remote")
        forged = policy.AsrDecision(**{**{f.name: getattr(decision, f.name) for f in dataclasses.fields(decision)}, "_issued": None})
        with self.assertRaises(EnginePolicyDenied) as cm:
            build_engine(dataclasses.replace(cfg, asr_decision=forged), None)
        self.assertEqual(str(cm.exception), "no policy decision")
        for junk in (object(), {"primary": "remote"}, "remote"):
            with self.assertRaises(EnginePolicyDenied):
                build_engine(dataclasses.replace(cfg, asr_decision=junk), None)

    def test_a_blocked_decision_is_refused(self):
        cfg, decision = make_run(self.cfg, "remote", consents=(), capable=False)
        self.assertEqual(decision.blocked, "asr_policy_blocked")
        with self.assertRaises(EnginePolicyDenied):
            build_engine(cfg, None)

    def test_the_default_decision_gives_the_plain_local_engine_and_no_router(self):
        engine, cfg, decision = self.build("whisper")
        self.assertIs(engine, self.local_engine)
        self.get_engine.assert_called_once_with(cfg.asr_model, allow_download=True)
        self.assertEqual(self.transports, [])

    def test_a_local_only_run_gets_an_engine_made_without_downloads(self):
        engine, cfg, decision = self.build("remote", local_only=True)
        self.assertIs(engine, self.local_engine)
        self.get_engine.assert_called_once_with(cfg.asr_model, allow_download=False)

    def test_a_server_primary_is_a_routed_engine_over_a_guard_for_its_host_only(self):
        engine, cfg, decision = self.build("remote")
        self.assertIsInstance(engine, RoutedEngine)
        self.assertIsInstance(engine.primary, MiniRemoteEngine)
        self.assertIsNone(engine.fallback)
        self.assertEqual(engine.primary.guard.hosts, (HOST,))
        self.assertEqual(len(self.transports), 1)
        self.assertEqual(engine.primary.consent_id, "c-remote")
        self.assertEqual(self.transports[0].calls, [])                           # nothing was opened, sent or read yet
        self.assertEqual((self.security.calls(), self.cfg.asr_usage_path.exists()), ([], False))

    def test_the_guard_of_a_server_engine_never_trusts_the_system_store(self):
        loose = consent_entry("remote", ca_sha256=None)
        engine, cfg, decision = self.build("remote", consents=(loose,))
        with self.assertRaises(EnginePolicyDenied) as cm:                        # a rule without a bound private CA: refused before any socket
            engine.primary.exchange("chunk", "POST", "/v1/chunk", {}, b"x")
        self.assertEqual(cm.exception.code, "ca_unbound")
        self.assertEqual(self.transports[0].calls, [])

    def test_a_cloud_primary_uses_the_system_trust(self):
        self.store_token("k" * 32, "azure", "koreacentral.api.cognitive.microsoft.com")
        engine, cfg, decision = self.build("azure", consents=("azure",))
        self.assertIsInstance(engine.primary, MiniCloudEngine)
        result = engine.transcribe_chunk(audio(), "en", None)
        self.assertEqual(result["segments"][0]["text"], "hello world")
        self.assertEqual(self.transports[0].calls[0].rule.host, "koreacentral.api.cognitive.microsoft.com")

    def test_a_local_fallback_is_the_cached_local_engine(self):
        engine, cfg, decision = self.build("remote", "whisper")
        self.assertIs(engine.fallback, self.local_engine)
        self.get_engine.assert_called_once_with(cfg.asr_model, allow_download=True)

    def test_an_external_fallback_gets_its_own_guard_and_host(self):
        self.store_token("k" * 32, "azure", "koreacentral.api.cognitive.microsoft.com")
        engine, cfg, decision = self.build("remote", "azure", consents=("remote", "azure"))
        self.assertEqual(engine.primary.guard.hosts, (HOST,))
        self.assertEqual(engine.fallback.guard.hosts, ("koreacentral.api.cognitive.microsoft.com",))
        self.assertEqual(len(self.transports), 2)
        self.assertIsNot(engine.primary.guard, engine.fallback.guard)

    def test_a_local_primary_with_a_server_fallback_is_gated_only_through_the_fallback(self):
        engine, cfg, decision = self.build("whisper", "remote")
        self.assertIs(engine.primary, self.local_engine)
        self.assertIsInstance(engine.fallback, MiniRemoteEngine)
        self.assertIsNone(engine._gate)

    def test_a_missing_adapter_is_unavailable_not_silently_replaced(self):
        with mock.patch.dict(asr_engines.REGISTRY, {"remote": "mcap.no_such_adapter:Nope"}):
            with self.assertRaises(EngineUnavailable):
                self.build("remote")

    def test_the_circuit_settings_come_from_the_config(self):
        self.cfg.asr_circuit_fails, self.cfg.asr_circuit_cooldown_s = 2, 30
        engine, cfg, decision = self.build("remote")
        self.assertEqual((engine.breaker.threshold, engine.breaker.base_cooldown, engine.breaker.max_cooldown), (2, 30.0, 600.0))
        self.cfg.asr_circuit_cooldown_s = 900
        engine, cfg, decision = self.build("remote")
        self.assertEqual(engine.breaker.max_cooldown, 900.0)

    def test_the_gate_is_asked_with_the_lane_of_each_engine(self):
        asked = []

        def gate(lane):
            asked.append(lane)
            return None
        self.store_token("k" * 32, "azure", "koreacentral.api.cognitive.microsoft.com")
        engine, cfg, decision = self.build("remote", "azure", consents=("remote", "azure"), gate=gate)
        engine.primary.exchange("chunk", "POST", "/v1/chunk", {}, b"x")
        engine.fallback.exchange("chunk", "POST", "/x", {}, b"x")
        self.assertEqual(set(asked), {"asr_remote", "asr_cloud"})
        self.assertEqual(asked[0], "asr_remote")

    def test_the_built_guard_asks_the_lane_gate_once_more_right_before_the_socket(self):
        # build_member hands the lane gate to the guard as pre_connect AND to the engine as its own gate. The two are told apart here: the gate
        # answers open to the engine's first question and closed to the next one (the guard's), so only the guard's pre_connect can stop it.
        engine, cfg, decision = self.build("remote")
        self.gate.close_after(1)
        with self.assertRaises(EnginePolicyDenied) as cm:
            engine.primary.transcribe_chunk(audio(), "en", None)
        self.assertEqual(cm.exception.code, "pre_connect")
        self.assertEqual(self.transports[0].calls, [])                           # the request never reached the transport
        self.assertEqual(self.gate.calls, 2)                                     # the engine's gate, then the guard's pre_connect
        self.assertEqual([x["outcome"] for x in usage_lines(self.cfg)], ["denied:pre_connect"])

    def test_a_gate_that_closes_during_the_keychain_read_stops_the_first_request_at_pre_connect(self):
        # The order inside one attempt is: engine gate, cap, credential (the Keychain can take seconds to answer or to prompt), pre_connect,
        # socket. A meeting switched to local-only while the credential is being read must not send its audio.
        gate = self.gate

        class ClosingSource:
            def read(self, engine, host, port):
                gate.close("local_only")
                return TOKEN

        asr_creds.install_source(ClosingSource())                                # (AsrCase restores the Keychain source afterwards)
        engine, cfg, decision = self.build("remote")
        with self.assertRaises(EnginePolicyDenied) as cm:
            engine.primary.transcribe_chunk(audio(), "en", None)
        self.assertEqual(cm.exception.code, "pre_connect")
        self.assertEqual(self.transports[0].calls, [])
        self.assertEqual(self.security.reads(), 0)                               # the fake Keychain was never the source of this read

    def test_a_gate_that_closes_during_the_keychain_read_sends_the_chunk_to_the_local_fallback_through_the_router(self):
        gate = self.gate

        class ClosingSource:
            def read(self, engine, host, port):
                gate.close("local_only")
                return TOKEN

        asr_creds.install_source(ClosingSource())
        engine, cfg, decision = self.build("remote", "whisper")
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "local text")
        self.assertEqual(self.transports[0].calls, [])
        self.assertTrue(engine.breaker.permanent)                                # a policy denial ends the external engine for this run

    def test_without_the_lane_module_the_gate_is_closed(self):
        with mock.patch.dict(sys.modules, {"mcap.lanes": None}):
            engine, cfg, decision = self.build("remote", "whisper", gate=None)
            self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "local text")
            self.assertEqual((self.transports[0].calls, self.security.reads()), ([], 0))
            engine2, _, _ = self.build("remote", "none", gate=None)
            with self.assertRaises(EnginePolicyDenied) as cm:
                engine2.transcribe_chunk(audio(), "en", None)
            self.assertEqual(cm.exception.code, "gate-unavailable")

    def test_the_lane_module_gate_is_used_by_default(self):
        seen = []
        fake = SimpleNamespace(gate=lambda lane: seen.append(lane))
        with mock.patch.dict(sys.modules, {"mcap.lanes": fake}):
            engine, cfg, decision = self.build("remote", gate=None)
            engine.transcribe_chunk(audio(), "en", None)
        self.assertIn("asr_remote", seen)
        self.assertEqual(len(self.transports[0].calls), 1)

    def test_a_gate_that_closes_during_a_retry_after_sleep_ends_the_request_and_the_circuit_opens_for_good(self):
        engine, cfg, decision = self.build("remote", "whisper")
        self.transports[0].script = [error_answer(503, "busy", retry_after=30)]
        self.sleep.on_sleep = lambda seconds: self.gate.close("local_only")
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "local text")    # this chunk went to the fallback
        self.assertEqual(len(self.transports[0].calls), 1)                                       # nothing was sent after the sleep
        self.assertEqual(self.sleep.waits, [30.0])
        self.assertTrue(engine.breaker.permanent)
        self.assertEqual(engine.transcribe_chunk(audio(), "en", None)["text"], "local text")
        self.assertEqual(len(self.transports[0].calls), 1)
        self.assertEqual([x["outcome"] for x in [json.loads(l) for l in self.cfg.asr_usage_path.read_text().splitlines()]], ["http_503", "denied:gate"])

    def test_build_member_makes_one_engine_without_a_router(self):
        cfg, decision = make_run(self.cfg, "remote", "whisper")
        hooks = dict(transport_factory=self.factory, gate=self.gate, sleep=self.sleep, rand=lambda: 0.5, clock=self.clock)
        remote = build_member(cfg, None, decision, "remote", **hooks)
        self.assertIsInstance(remote, MiniRemoteEngine)
        self.assertEqual((remote.guard.hosts, remote.host, remote.consent_id), ((HOST,), HOST, "c-remote"))
        self.assertIs(build_member(cfg, None, decision, "whisper", **hooks), self.local_engine)
        with self.assertRaises(EnginePolicyDenied):
            build_member(cfg, None, decision, "azure", **hooks)                 # the decision names no destination for it
        with self.assertRaises(EnginePolicyDenied):
            build_member(cfg, None, decision, "no-such-engine", **hooks)

    def test_the_cap_is_the_smallest_of_the_setting_the_policy_and_the_consent(self):
        self.cfg.asr_cloud_daily_minutes = 240
        self.assertEqual(effective_cap_minutes(self.cfg), 240.0)
        org = dataclasses.replace(policy.absent_policy(), daily_audio_minutes_cap=30)
        with mock.patch.object(policy, "load_org_policy", return_value=org):
            self.assertEqual(effective_cap_minutes(self.cfg), 30.0)
            self.assertEqual(effective_cap_minutes(dataclasses.replace(self.cfg, asr_cloud_daily_minutes=10)), 10.0)
        policy.write_consent(self.cfg.consent_path, consent_entry("remote", daily_minutes_cap=5), machine_id="m" * 64)
        self.assertEqual(effective_cap_minutes(self.cfg, "c-remote"), 5.0)
        self.assertEqual(effective_cap_minutes(self.cfg, "c-other"), 240.0)
        self.assertEqual(effective_cap_minutes(self.cfg, "org:remote-ab12cd34"), 240.0)       # an organisation consent has no file entry
        self.assertEqual(effective_cap_minutes(SimpleNamespace()), 240.0)

    def test_a_damaged_consent_file_adds_no_cap(self):
        self.cfg.consent_path.write_text("{ not json", encoding="utf-8")
        self.assertEqual(effective_cap_minutes(self.cfg, "c-remote"), 240.0)

    def test_the_engines_are_built_with_that_cap(self):
        policy.write_consent(self.cfg.consent_path, consent_entry("remote", daily_minutes_cap=0), machine_id="m" * 64)
        cfg, decision = make_run(self.cfg, "remote")
        engine = build_engine(cfg, None, transport_factory=self.factory, gate=self.gate, sleep=self.sleep, clock=self.clock)
        with self.assertRaises(EngineCapReached):
            engine.primary.transcribe_chunk(audio(), "en", None)

    def test_a_cap_reached_in_the_middle_of_a_run_sends_the_chunk_to_the_fallback_and_trips_nothing(self):
        policy.write_consent(self.cfg.consent_path, consent_entry("remote", daily_minutes_cap=0), machine_id="m" * 64)
        cfg, decision = make_run(self.cfg, "remote", "whisper")
        engine = build_engine(cfg, None, transport_factory=self.factory, gate=self.gate, sleep=self.sleep, clock=self.clock)
        self.assertEqual([engine.transcribe_chunk(audio(), "en", None)["text"] for _ in range(4)], ["local text"] * 4)
        self.assertEqual((self.transports[0].calls, self.security.reads()), ([], 0))             # nothing sent, no Keychain read
        self.assertEqual((engine.breaker.state, engine.breaker.opened), ("closed", 0))
        self.assertEqual(dict(engine.chunks), {"whisper": 4})


# ======================================================================================================================
class EndToEndTests(RoutedCase):
    """The real asr.transcribe_tracks over the synthetic two-track audio of the golden fixtures, through build_engine, an in-process transport
    and a real EgressGuard. The only fakes: the transport, the local engine, the clock and the gate."""

    def setUp(self):
        super().setUp()
        registry = fake_registry()
        registry.start()
        self.addCleanup(registry.stop)
        self.local_engine = FakeLocalEngine()
        patcher = mock.patch.object(asr_engines, "get_engine", return_value=self.local_engine)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.vocab = parse_vocab_text("Acme\nAcmeScan-CXR\n")

    def run_asr(self, primary="remote", fallback="none", **kw):
        cfg, decision = make_run(self.cfg, primary, fallback, **kw)
        cfg = dataclasses.replace(cfg, asr_vad="energy", mic_aec="0", asr_language="en", self_name="Me")

        def engine_for(c, vocab, progress=None):
            return build_engine(c, vocab, progress=progress, transport_factory=lambda: self.transport, gate=self.gate, sleep=self.sleep,
                                rand=lambda: 0.5, clock=self.clock)
        with mock.patch.object(asr, "_engine_for", engine_for):
            return asr.transcribe_tracks(mg.prepared_audio(), cfg, self.vocab)

    def usage_lines(self):
        path = self.cfg.asr_usage_path
        return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    def test_a_server_transcribes_both_tracks_and_the_transcript_says_so(self):
        out = self.run_asr()
        block = out["asr"]
        self.assertEqual((block["engine"], block["kind"], block["privacy"], block["destination"]), ("remote", "server", "server", "company-asr"))
        self.assertEqual((block["fallbacks"], block["circuit_opened"]), (0, 0))
        self.assertGreaterEqual(block["chunks"]["remote"], 2)
        self.assertEqual(block["sent"]["requests"], block["chunks"]["remote"])
        self.assertGreater(len(out["segments"]), 0)
        text = json.dumps(out)
        self.assertNotIn(HOST, text)
        self.assertNotIn(TOKEN, text)
        self.assertEqual(len(self.usage_lines()), block["sent"]["requests"])
        self.assertTrue(all(call.header("Authorization") == f"Bearer {TOKEN}" for call in self.transport.calls))
        self.assertEqual(self.security.reads(), 1)

    def test_a_server_that_is_down_with_a_local_fallback_gives_a_local_transcript(self):
        self.transport.default = None
        self.transport.handler = lambda call: ConnectionRefusedError("down")
        out = self.run_asr("remote", "whisper")
        block = out["asr"]
        self.assertEqual((block["privacy"], block["circuit_opened"]), ("local", 1))               # nothing was delivered: no audio left the Mac
        self.assertEqual(block["chunks"], {"whisper": block["fallbacks"]})
        self.assertGreater(len(out["segments"]), 0)
        self.assertEqual(self.security.reads(), 1)
        self.assertEqual(self.local_engine.release_calls, 1)

    def test_a_server_that_is_down_without_a_fallback_is_unreachable_not_a_failed_meeting(self):
        self.transport.handler = lambda call: ConnectionRefusedError("down")
        with self.assertRaises(asr.AsrUnreachable):
            self.run_asr("remote", "none")
        self.assertLessEqual(len(self.transport.calls), 9)                                         # three chunks of three attempts, then the circuit

    def test_a_meeting_switched_to_local_only_midway_sends_nothing_more(self):
        sent = []
        self.transport.on_send = lambda call: (sent.append(call), self.gate.close("local_only") if len(sent) == 1 else None)
        out = self.run_asr("remote", "whisper")
        block = out["asr"]
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(block["chunks"].get("remote", 0), 1)
        self.assertGreaterEqual(block["fallbacks"], 1)
        self.assertEqual(block["privacy"], "mixed")
        self.assertEqual(block["circuit_opened"], 1)

    def test_a_hybrid_run_does_not_send_the_decode_retry_to_the_server_again(self):
        suspicious = {"text": "Acme Acme Acme", "language": "en", "avg_logprob": -2.5, "truncated": False,
                      "segments": [{"start": 0.0, "end": 2.0, "text": "Acme Acme Acme", "avg_logprob": -2.5, "no_speech_prob": 0.01,
                                    "compression_ratio": 1.1, "temperature": 0.0}]}
        self.transport.default = json_response(200, suspicious)
        with mock.patch.object(asr, "_better", wraps=asr._better) as better:
            out = self.run_asr("remote", "whisper")
        self.assertGreater(better.call_count, 0)                                                    # decode_chunk did ask again without the prompt
        chunks = out["asr"]["chunks"]["remote"]
        self.assertEqual(len(self.transport.calls), chunks)                                         # one request per chunk, retry or not
        self.assertEqual(len(self.local_engine.calls), 0)


class DefaultPathTests(unittest.TestCase):
    def test_the_default_path_does_not_import_the_external_engine_modules(self):
        """Nothing external is switched on by importing the stage: asr.py loads the router only when a run carries a policy decision."""
        code = ("import sys, mcap.asr, mcap.asr_engines, mcap.transcript; "
                "print(','.join(m for m in ('mcap.asr_router', 'mcap.asr_http', 'mcap.asr_usage') if m in sys.modules))")
        done = subprocess.run([sys.executable, "-c", code], cwd=str(Path(__file__).resolve().parents[1]), capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, ""), done.stderr)


if __name__ == "__main__":
    unittest.main()
