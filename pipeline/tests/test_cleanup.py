"""cleanup.py: the numeric/name guard of the transcript cleanup, batch planning, and how the pass sizes itself against the meeting's
Claude call budget (MAX_CLAUDE_CALLS_PER_MEETING, SPEC 15). The model is a fake `call` seam; the end-to-end behaviour with the real
executor is in test_pipeline (QualityPassesRealExecutorTests, CallCapTests)."""
import math
import unittest

from notes_cli_support import FakeClaude, TempCase, make_cfg

from mcap import cleanup, note, usage
from mcap.vocab import Vocab

VOCAB = Vocab(terms=["FDA", "Contoso-Labs", "AcmeScan-CXR", "510(k)"])
ALLOWED = cleanup.allowed_name_pieces(VOCAB)


def segments(minutes: int, per_minute: int = 1) -> list:
    out = []
    for m in range(minutes):
        for k in range(per_minute):
            out.append({"start": 60.0 * m + 10.0 * k + 1, "end": 60.0 * m + 10.0 * k + 8, "speaker": "Me" if k % 2 == 0 else "Remote",
                        "track": "mic", "lang": "en", "text": f"Item {m}.{k}: the FVA submission costs $2.00 per study."})
    return out


class ProtectedTokenTests(unittest.TestCase):
    def test_terminology_fixes_keep_the_protected_tokens(self):
        a = "에프디에이 says the FVA fee is $2.00 on 2026-10-07, about 3.5% of the 12th batch, twenty thousand units, 삼 개월."
        b = a.replace("FVA", "FDA").replace("에프디에이", "FDA")
        self.assertEqual(cleanup.protected_tokens(a), cleanup.protected_tokens(b))

    def test_every_kind_of_number_change_is_detected(self):
        base = "The fee is $2.00 on the twelfth, 3.5%, 7,500 units, three sites."
        for changed in (base.replace("2.00", "2.10"), base.replace("twelfth", "thirteenth"), base.replace("3.5%", "3.6%"),
                        base.replace("7,500", "8,500"), base.replace("three", "four"), base + " Also 7."):
            self.assertNotEqual(cleanup.protected_tokens(base), cleanup.protected_tokens(changed), changed)


class ValidateEditTests(unittest.TestCase):
    def check(self, orig, new, neighbours=()):
        return cleanup.validate_edit(orig, new, ALLOWED, list(neighbours))

    def test_a_terminology_fix_is_accepted(self):
        self.assertIsNone(self.check("에프디에이 clearance for AcmeScan is pending.", "FDA clearance for AcmeScan-CXR is pending."))

    def test_rejections(self):
        orig = "We pay $2.00 per study, and Contoso-Labs reviews the 510(k) draft."
        self.assertEqual(self.check(orig, 5), "not_text")
        self.assertEqual(self.check(orig, "   "), "empty")
        self.assertEqual(self.check(orig, "We pay $2.00 per study.\nContoso-Labs reviews the 510(k) draft."), "split")
        self.assertEqual(self.check(orig, orig), "unchanged")
        self.assertEqual(self.check(orig, orig.replace("$2.00", "$2.10")), "numbers")
        self.assertEqual(self.check(orig, "We pay $2.00."), "length")
        self.assertEqual(self.check(orig, orig + " [?] [?] [?]"), "too_many_marks")
        self.assertEqual(self.check(orig, orig.replace("Contoso-Labs", "Acme Corp")), "new_name")
        neighbour = "Yes, that works for me."
        self.assertEqual(self.check(orig, orig + " " + neighbour, [neighbour]), "merged")


    def test_times_and_durations_in_a_segment_are_judged_against_that_segment_alone(self):
        """The cleanup guard has no metadata block and no header: it compares a segment with its own original (multiset of numeric
        tokens), so a clock time or a length that is merely RESTATED is fine and a changed one is not. (The numbers of the session
        facts matter only to NOTE_VERIFY, whose body check is verify.allowed_numbers.)"""
        orig = "에프디에이 회의는 17:17에 시작해서 5분 21초 동안 했고 17:22에 끝났어요."
        fixed = "FDA 회의는 17:17에 시작해서 5분 21초 동안 했고 17:22에 끝났어요."
        self.assertIsNone(self.check(orig, fixed))
        for wrong in (fixed.replace("17:22", "17:23"), fixed.replace("5분", "6분"), fixed.replace("21초", "22초"), fixed + " 3명이 참석"):
            with self.subTest(wrong=wrong):
                self.assertEqual(self.check(orig, wrong), "numbers")


    def test_a_changed_korean_numeral_in_front_of_a_counter_is_rejected(self):
        """Wave E review: `두 명` -> `세 명`, `삼 개월` -> `오 개월`, `한 번` -> `두 번`, `나흘` -> `닷새` were ACCEPTED, because only runs of two
        numeral syllables and the numerals that stand alone were protected; the single syllable in front of a counter was not."""
        changed = (("두 명이 참석했습니다", "세 명이 참석했습니다"), ("삼 개월 뒤에 시작합니다", "오 개월 뒤에 시작합니다"),
                   ("한 번 더 해 볼게요", "두 번 더 해 볼게요"), ("세 가지를 말했어요", "네 가지를 말했어요"), ("나흘 뒤에 만나요", "닷새 뒤에 만나요"),
                   ("스물한 명이 왔어요", "스물두 명이 왔어요"), ("하루에 두 번 먹어요", "하루에 세 번 먹어요"), ("석 달 뒤에", "넉 달 뒤에"))
        for orig, new in changed:
            with self.subTest(orig=orig):
                self.assertEqual(self.check(orig, new), "numbers")
        # the same numeral with another spelling of the blank, or next to a terminology fix, is fine
        self.assertIsNone(self.check("에프디에이 심사는 세 가지로 나뉩니다", "FDA 심사는 세가지로 나뉩니다"))
        self.assertIsNone(self.check("에프디에이 담당자 두명이 왔어요", "FDA 담당자 두 명이 왔어요"))
        # words that only look like numerals are free to change
        self.assertIsNone(self.check("네, 에프디에이 건은 이 사람이 맡아요", "예, FDA 건은 그 사람이 맡아요"))


class ParseEditsTests(unittest.TestCase):
    def test_accepts_fences_and_a_preamble(self):
        edits, problems = cleanup.parse_edits('Sure:\n```json\n[{"id": 3, "text": "FDA"}]\n```')
        self.assertEqual((edits, problems), ([{"id": 3, "text": "FDA"}], []))
        self.assertEqual(cleanup.parse_edits("[]"), ([], []))

    def test_problems(self):
        for reply in ("", "no array here", "[1, 2]", '{"id": 1, "text": "x"}', '[{"id": "1", "text": "x"}]', "[{"):
            edits, problems = cleanup.parse_edits(reply)
            self.assertTrue(problems, reply)
            self.assertEqual(edits, [], reply)


class BatchPlanTests(unittest.TestCase):
    def test_four_minute_batches_with_context(self):
        segs = segments(60)
        batches = cleanup.build_batches(segs)
        self.assertEqual(len(batches), 15)
        self.assertEqual(sorted(i for b in batches for i in b.ids), list(range(60)))          # every segment is a target exactly once
        middle = batches[5]
        self.assertEqual(len(middle.before), 2)
        self.assertEqual(len(middle.after), 2)
        self.assertTrue(set(middle.before).isdisjoint(middle.ids))

    def test_a_smaller_call_budget_makes_bigger_batches_never_more_than_the_budget(self):
        segs = segments(120)
        for max_calls in (20, 10, 4, 1):
            batches = cleanup.build_batches(segs, max_calls=max_calls)
            self.assertLessEqual(len(batches), max_calls, max_calls)
            self.assertEqual(sorted(i for b in batches for i in b.ids), list(range(120)), max_calls)

    def test_segments_without_text_are_skipped(self):
        segs = segments(3)
        segs[1]["text"] = "   "
        ids = sorted(i for b in cleanup.build_batches(segs) for i in b.ids)
        self.assertEqual(ids, [0, 2])
        self.assertEqual(cleanup.build_batches([]), [])


class FakeModel:
    """Stands in for note.call_claude: takes its call from the budget like the real executor does, answers with no edits."""

    def __init__(self, fail_kind=None):
        self.calls = 0
        self.fail_kind = fail_kind

    def __call__(self, cfg, prompt, validate, *, timeout_s, system_prompt, allow_overage, budget, cancel, stage="note", **kw):
        if budget is not None and not budget.take(stage):
            return note.CallResult(False, error_kind="budget", error="claude call cap reached")
        self.calls += 1
        if self.fail_kind:
            return note.CallResult(False, error_kind=self.fail_kind, error=f"{self.fail_kind} (fake)")
        return note.CallResult(True, value=[], model="claude-opus-5")


class BudgetAwareRunTests(TempCase):
    def setUp(self):
        super().setUp()
        self.cfg = make_cfg(self.root)

    def run_cleanup(self, minutes, budget=None, model=None):
        model = model or FakeModel()
        transcript = {"schema": 1, "languages": {"mic": "en"}, "segments": segments(minutes)}
        if budget is None:
            res = cleanup.cleanup_transcript(transcript, self.cfg, VOCAB, call=model)
        else:
            with usage.meeting("s", budget):
                res = cleanup.cleanup_transcript(transcript, self.cfg, VOCAB, call=model)
        return res, model

    def test_without_a_pipeline_budget_the_old_ceiling_applies(self):
        res, model = self.run_cleanup(120)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(model.calls, res.stats["batches"])
        self.assertLessEqual(model.calls, cleanup.MAX_CALLS - cleanup.RETRY_HEADROOM)

    def test_the_batches_are_planned_for_what_the_meeting_budget_leaves_for_cleanup(self):
        budget = usage.CallBudget(30, usage.planned_reserve(calendar=True, verify=True))
        res, model = self.run_cleanup(120, budget)
        self.assertTrue(res.ok, res.error)
        self.assertLessEqual(model.calls, 25 - 5)                                           # 25 left, 5 kept as retry headroom
        small = usage.CallBudget(10, usage.planned_reserve(calendar=True, verify=True))     # 10 - 5 = 5 left: 4 batches + 1 retry
        res, model = self.run_cleanup(120, small)
        self.assertTrue(res.ok, res.error)
        self.assertLessEqual(model.calls, 4)
        self.assertEqual(res.stats["batches"], model.calls)
        self.assertEqual(small.by_stage["cleanup"], model.calls)                            # counted under its own stage
        self.assertEqual(small.reserved, {"note": 2, "calendar": 1, "verify": 2})           # the other stages' calls are untouched

    def test_no_room_means_no_call_and_a_budget_error_never_an_exception(self):
        budget = usage.CallBudget(5, usage.planned_reserve(calendar=True, verify=True))     # everything is reserved
        res, model = self.run_cleanup(10, budget)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, "budget")
        self.assertIn("MAX_CLAUDE_CALLS_PER_MEETING=5", res.error)
        self.assertEqual(model.calls, 0)

    def test_failing_batches_stop_at_the_budget_and_the_reservations_survive(self):
        budget = usage.CallBudget(8, usage.planned_reserve(calendar=False, verify=True))   # note 2 + verify 2 -> 4 for cleanup
        res, model = self.run_cleanup(60, budget, FakeModel(fail_kind="overloaded"))
        self.assertFalse(res.ok)
        self.assertLessEqual(model.calls, 4)
        self.assertEqual(budget.reserved, {"note": 2, "verify": 2})

    def test_an_empty_transcript_is_a_clean_no_op(self):
        res, model = self.run_cleanup(0)
        self.assertEqual((res.ok, res.error_kind, model.calls), (False, "empty", 0))


class ApiBudgetTests(TempCase):
    """SPEC 17 (api mode): the USD budgets stop the batches that have not started yet. The check is made before every call starts, so
    the overshoot is bounded by the calls that were already running (cleanup.CONCURRENCY of them), never by a whole pass. The real
    executor against the fake claude (every call costs a fixed amount and takes a moment, so calls really overlap)."""

    PER_CALL = 4.0

    def setUp(self):
        super().setUp()
        self.fake = FakeClaude(self.root / "fake")
        self.cfg = make_cfg(self.root, self.fake, claude_auth="api", note_timeout_seconds=60, claude_daily_budget_usd=0.0,
                            claude_meeting_budget_usd=10.0)
        self.security.store()
        self.transcript = {"schema": 1, "asr_model": "x", "languages": {"mic": "en"}, "segments": segments(60)}    # 15 batches

    def run_pass(self, cost, delay=0.3):
        self.fake.set(cleanup={}, cost=cost, delay=delay)
        with usage.meeting("2026-10-07_1400_meet", usage.CallBudget(40, {"note": 2})):
            return cleanup.cleanup_transcript(self.transcript, self.cfg, VOCAB, meta={"title": "T"})

    def test_the_meeting_budget_stops_the_batches_not_yet_started_and_overshoots_by_the_calls_in_flight_only(self):
        res = self.run_pass(self.PER_CALL)
        calls = len(self.fake.calls("cleanup"))
        bound = math.ceil(10.0 / self.PER_CALL) + cleanup.CONCURRENCY                       # the budget's worth + what was running
        self.assertGreaterEqual(calls, 3)
        self.assertLessEqual(calls, bound, f"{calls} calls for a budget of 10 at {self.PER_CALL} each")
        self.assertLess(calls, 15)                                                          # never the whole pass
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, "budget_meeting")                                   # the cause, not "cancelled"
        self.assertIn("meeting Claude budget reached", res.error)
        spent = usage.day_cost_usd(self.cfg)
        self.assertLessEqual(spent, 10.0 + cleanup.CONCURRENCY * self.PER_CALL)
        self.assertEqual(sorted({e["outcome"] for e in usage.read_entries(self.cfg)} - {"ok"}), ["budget_meeting"])

    def test_batches_that_finished_before_the_budget_ran_out_are_kept(self):
        res = self.run_pass(1.0, delay=0.15)                                                 # ten calls fit, the rest of the 15 is stopped
        self.assertTrue(res.ok, res.error)
        self.assertGreaterEqual(res.stats["batches_ok"], 10)
        self.assertLessEqual(res.stats["batches_ok"], 10 + cleanup.CONCURRENCY)
        self.assertGreater(res.stats["batches_failed"], 0)
        self.assertIn("budget_meeting", res.stats["failed_kinds"])
        self.assertLessEqual(res.stats["batches_failed"], 15 // 2)

    def test_a_reached_daily_budget_means_no_call_at_all(self):
        self.cfg.claude_daily_budget_usd = 5.0
        usage.record(self.cfg, "note", models=["m"], cost_usd=6.0, auth="api")
        res = self.run_pass(self.PER_CALL)
        self.assertEqual((res.ok, res.error_kind), (False, "budget_daily"))
        self.assertEqual(self.fake.calls(), [])
        self.assertIn("daily Claude budget reached", res.error)

    def test_no_budget_is_applied_in_subscription_mode(self):
        self.cfg.claude_auth = "subscription"
        res = self.run_pass(self.PER_CALL, delay=0.0)
        self.assertTrue(res.ok, res.error)
        self.assertEqual(len(self.fake.calls("cleanup")), 15)

    def test_a_budget_stop_is_not_fatal_for_the_batches_but_credit_exhaustion_is(self):
        self.assertIn("credit_exhausted", cleanup.FATAL_KINDS)
        self.assertNotIn("budget_meeting", cleanup.FATAL_KINDS)
        self.assertEqual(cleanup.BUDGET_KINDS, ("budget_daily", "budget_meeting"))


if __name__ == "__main__":
    unittest.main()
