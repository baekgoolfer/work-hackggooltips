"""asr_reconcile (ASR_STRATEGY=dual): the five rules on synthetic segments, the implausible-number heuristic, the vocabulary matcher.
No engine, no audio, no model: ``reconcile`` is a pure function of two segment lists.

Run: python -m unittest discover -s pipeline/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import asr, asr_reconcile as rc  # noqa: E402


def seg(start, end, text, lp=-0.3, ns=0.02, cr=1.2):
    return {"start": start, "end": end, "text": text, "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": cr, "temperature": 0.0}


def texts(result):
    return [s["text"] for s in result.segments]


TERMS = ("Acme", "FDA", "510(k)", "Pre-Sub", "애크미")


class OverlapTest(unittest.TestCase):
    def test_ratio_is_overlap_over_the_shorter_duration(self):
        self.assertEqual(rc.overlap_ratio(seg(0, 4, "a"), seg(3, 8, "b")), 0.25)               # 1 s of 4 s
        self.assertEqual(rc.overlap_ratio(seg(0, 4, "a"), seg(2, 3, "b")), 1.0)                # the short one lies inside
        self.assertEqual(rc.overlap_ratio(seg(0, 4, "a"), seg(4, 8, "b")), 0.0)                # touching is no overlap
        self.assertEqual(rc.overlap_ratio(seg(0, 4, "a"), seg(9, 10, "b")), 0.0)

    def test_a_zero_length_segment_is_aligned_when_its_instant_is_inside(self):
        self.assertEqual(rc.overlap_ratio(seg(2, 2, "a"), seg(1, 3, "b")), 1.0)
        self.assertEqual(rc.overlap_ratio(seg(5, 5, "a"), seg(1, 3, "b")), 0.0)
        self.assertEqual(rc.overlap_ratio(seg(2, 2, "a"), seg(2, 2, "b")), 1.0)

    def test_the_threshold_is_the_alignment_rule(self):
        for overlap, aligned in ((1.25, True), (1.0, False)):                    # 1.25 / 4 = 0.3125, 1.0 / 4 = 0.25
            p, n = [seg(0, 4, "alpha beta")], [seg(4 - overlap, 8, "gamma delta")]
            result = rc.reconcile(p, n)
            self.assertEqual(result.conflicts, 1 if aligned else 0, overlap)
            self.assertEqual(result.restored, 0 if aligned else 1, overlap)         # an unaligned N segment is judged by the restore rules instead


class EmptyAndTrivialTest(unittest.TestCase):
    def test_both_passes_empty(self):
        result = rc.reconcile([], [], TERMS)
        self.assertEqual((result.segments, result.counts()), ([], {"conflicts": 0, "plain_chosen": 0, "restored": 0}))

    def test_an_empty_plain_pass_keeps_every_prompted_segment(self):
        p = [seg(0, 2, "one"), seg(3, 5, "two")]
        result = rc.reconcile(p, [], TERMS)
        self.assertEqual(texts(result), ["one", "two"])
        self.assertEqual(result.counts(), {"conflicts": 0, "plain_chosen": 0, "restored": 0})

    def test_an_empty_prompted_pass_restores_the_plain_segments_that_pass_the_tests(self):
        n = [seg(0, 2, "one"), seg(3, 5, "two", lp=-1.2)]
        result = rc.reconcile([], n, TERMS)
        self.assertEqual(texts(result), ["one"])
        self.assertEqual((result.restored, result.rejected), (1, 1))

    def test_segments_without_text_are_ignored_on_both_sides(self):
        result = rc.reconcile([seg(0, 2, "   "), seg(3, 5, "kept")], [seg(0, 2, ""), seg(3, 5, "kept")], TERMS)
        self.assertEqual((texts(result), result.equal, result.conflicts), (["kept"], 1, 0))

    def test_the_inputs_are_not_modified_and_the_result_holds_the_same_dicts(self):
        p, n = [seg(0, 2, "alpha")], [seg(0, 2, "beta"), seg(6, 8, "gamma")]
        before = ([dict(s) for s in p], [dict(s) for s in n])
        result = rc.reconcile(p, n)
        self.assertEqual((p, n), before)
        self.assertTrue(all(any(s is t for t in p + n) for s in result.segments))

    def test_the_result_is_sorted_by_time(self):
        result = rc.reconcile([seg(10, 12, "late"), seg(0, 2, "early")], [seg(5, 7, "middle")], TERMS)
        self.assertEqual(texts(result), ["early", "middle", "late"])


class EqualTextTest(unittest.TestCase):
    def test_equal_after_normalisation_takes_p(self):
        p, n = [seg(0, 3, "FDA, Pre-Sub  meeting!")], [seg(0.1, 3.1, "fda pre sub MEETING")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.equal, result.conflicts, result.plain_chosen), (["FDA, Pre-Sub  meeting!"], 1, 0, 0))

    def test_p_wins_the_coarser_segmentation_when_the_words_are_the_same(self):
        p = [seg(0, 6, "네 알겠습니다 그럼 다음으로 넘어가겠습니다")]
        n = [seg(0, 1, "네"), seg(1, 2.5, "알겠습니다"), seg(2.5, 6, "그럼 다음으로 넘어가겠습니다")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.equal, result.conflicts, result.restored), ([p[0]["text"]], 1, 0, 0))


class ConflictTest(unittest.TestCase):
    def test_more_vocabulary_hits_win(self):
        p, n = [seg(0, 3, "the Acme FDA submission")], [seg(0, 3, "the ackme FDA submission")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), (["the Acme FDA submission"], 1, 0))
        result = rc.reconcile(n, p, TERMS)                                          # the roles swapped: the plain decode has the terms
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), (["the Acme FDA submission"], 1, 1))

    def test_an_implausible_number_loses_to_a_plausible_one(self):
        p = [seg(0, 4, "매출은 80,000억, 400,000억입니다")]
        n = [seg(0, 4, "매출은 400억, 83억입니다")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.plain_chosen), (["매출은 400억, 83억입니다"], 1))

    def test_an_implausible_number_costs_one_point_per_token_against_a_vocabulary_hit(self):
        p = [seg(0, 4, "Acme 80,000억")]               # +1 hit, -1 implausible = 0
        n = [seg(0, 4, "ackme 400억")]                 # 0
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["Acme 80,000억"])                 # tie, the digits differ but P is implausible: P
        p = [seg(0, 4, "80,000억 400,000억")]
        n = [seg(0, 4, "ackme 400억")]
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["ackme 400억"])                    # -2 against 0

    def test_equal_scores_with_different_but_plausible_digits_prefer_the_plain_decode(self):
        p, n = [seg(0, 3, "we have 12 sites and 30 patients")], [seg(0, 3, "we have 13 sites and 30 patients")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.plain_chosen), (["we have 13 sites and 30 patients"], 1))

    def test_a_truncated_plain_decode_never_wins_the_digit_tie_break(self):
        for p_text, n_text, p_end, n_end in (("매출 400억 영업이익 30억 입니다", "매출 400억", 8, 4),                        # a figure and a clause of P lost
                                             ("we have 12 sites and the budget is 30 patients", "we have 12 sites", 8, 8),
                                             ("we have 12 sites and 30 patients", "we have 13 sites", 6, 3)):               # the figures differ AND N is cut short
            with self.subTest(p_text):
                result = rc.reconcile([seg(0, p_end, p_text)], [seg(0, n_end, n_text)], TERMS)
                self.assertEqual((texts(result), result.conflicts, result.plain_chosen), ([p_text], 1, 0))

    def test_a_spelled_out_or_dropped_figure_is_lost_content_not_a_correction(self):
        for p_text, n_text in (("we have 12 sites", "we have twelve sites"), ("Phase 2 starts", "Phase two starts"), ("the 3 of us", "the three of us")):
            with self.subTest(p_text):
                result = rc.reconcile([seg(0, 3, p_text)], [seg(0, 3, n_text)], TERMS)
                self.assertEqual((texts(result), result.plain_chosen), ([p_text], 0))

    def test_a_fuller_plain_decode_with_more_figures_does_not_win_a_tie_either(self):
        p, n = [seg(0, 3, "매출 400억")], [seg(0, 6, "매출 400억 영업이익 30억")]                           # the figures differ in number: P (documented limit)
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["매출 400억"])

    def test_the_coverage_limit_of_the_digit_tie_break(self):
        p = [seg(0, 5, "one two three four 12")]                                                          # five words
        full = [seg(0, 5, "one two three four 13")]
        self.assertEqual(rc.TIE_MIN_COVERAGE, 0.8)
        self.assertEqual(texts(rc.reconcile(p, full, TERMS)), ["one two three four 13"])                  # 5 of 5
        cut = [seg(0, 5, "one two three 13")]                                                             # 4 of 5 words: exactly the limit
        self.assertEqual(texts(rc.reconcile(p, cut, TERMS)), ["one two three 13"])
        cut = [seg(0, 5, "one two 13")]                                                                   # 3 of 5: too short
        self.assertEqual(texts(rc.reconcile(p, cut, TERMS)), ["one two three four 12"])

    def test_the_coverage_is_counted_over_the_whole_group(self):
        p = [seg(0, 3, "alpha beta 12"), seg(3, 6, "gamma delta epsilon")]
        full = [seg(0, 6, "alpha beta 13 gamma delta epsilon")]                                           # one N segment over two P segments: one group
        self.assertEqual(texts(rc.reconcile(p, full, TERMS)), ["alpha beta 13 gamma delta epsilon"])
        cut = [seg(0, 6, "alpha beta 13")]                                                                # the same group, 3 of 6 words: P
        self.assertEqual(texts(rc.reconcile(p, cut, TERMS)), ["alpha beta 12", "gamma delta epsilon"])

    def test_the_digit_preference_never_beats_the_vocabulary_evidence(self):
        p, n = [seg(0, 3, "Acme has 12 sites")], [seg(0, 3, "ackme has 13 sites")]
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["Acme has 12 sites"])

    def test_a_thousands_separator_only_difference_is_the_same_digit_token(self):
        p, n = [seg(0, 3, "price 1,200 dollars")], [seg(0, 3, "price 1200 dollars")]
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["price 1,200 dollars"])           # tie, same digits: P

    def test_a_tie_goes_to_p(self):
        p, n = [seg(0, 3, "okay let us start")], [seg(0, 3, "okay lets start")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), (["okay let us start"], 1, 0))

    def test_both_implausible_is_a_tie_even_when_the_digits_differ(self):
        p, n = [seg(0, 3, "80,000억")], [seg(0, 3, "90,000억")]
        self.assertEqual(texts(rc.reconcile(p, n, TERMS)), ["80,000억"])

    def test_a_looped_side_loses_to_a_clean_one_even_with_more_terms(self):
        loop = [seg(0, 6, "FDA FDA FDA FDA FDA FDA", cr=3.1)]
        clean = [seg(0, 6, "the F D A said so")]
        self.assertEqual(texts(rc.reconcile(clean, loop, TERMS)), ["the F D A said so"])      # N looped: P
        self.assertEqual(texts(rc.reconcile(loop, clean, TERMS)), ["the F D A said so"])      # P looped: N
        both = rc.reconcile([seg(0, 6, "FDA FDA", cr=3.0)], [seg(0, 6, "FDA FDA FDA", cr=3.0)], TERMS)
        self.assertEqual(both.plain_chosen, 1)                                                # both looped: the score decides (3 hits vs 2)

    def test_an_aligned_group_is_judged_as_a_whole(self):
        p = [seg(0, 8, "the Acme pilot starts in May and the FDA reviews it")]
        n = [seg(0, 3, "the ackme pilot starts"), seg(3, 5, "in May"), seg(5, 8, "and the FDA reviews it")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), ([p[0]["text"]], 1, 0))      # 2 hits against 1
        result = rc.reconcile(n, p, TERMS)                                                                      # the other way round
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), ([p[0]["text"]], 1, 1))

    def test_a_winning_plain_group_replaces_every_prompted_segment_of_it(self):
        p = [seg(0, 3, "400,000억 first"), seg(3, 6, "80,000억 second")]
        n = [seg(0, 6, "400억 first and 83억 second")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), (["400억 first and 83억 second"], 1, 1))

    def test_a_chain_of_overlaps_is_one_group(self):
        p = [seg(0, 4, "alpha one"), seg(4, 8, "alpha two")]
        n = [seg(2, 6, "beta one two")]                         # overlaps both prompted segments by half of itself
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.restored), (["alpha one", "alpha two"], 1, 0))

    def test_independent_groups_are_decided_independently(self):
        p = [seg(0, 3, "the Acme team"), seg(10, 13, "total 80,000억")]
        n = [seg(0, 3, "the ackme team"), seg(10, 13, "total 400억")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.conflicts, result.plain_chosen), (["the Acme team", "total 400억"], 2, 1))


class RestoreTest(unittest.TestCase):
    def only_n(self, **kw):
        base = seg(20, 21, "아 이해했습니다")
        base.update(kw)
        return rc.reconcile([seg(0, 3, "something said earlier")], [base], TERMS)

    def test_a_plain_only_utterance_is_restored(self):
        result = self.only_n()
        self.assertEqual((texts(result), result.restored, result.rejected), (["something said earlier", "아 이해했습니다"], 1, 0))

    def test_duration_limit(self):
        self.assertEqual(self.only_n(start=20, end=20.4).restored, 1)                  # exactly 0.4 s
        self.assertEqual(self.only_n(start=20, end=20.39).restored, 0)
        self.assertEqual(self.only_n(start=20, end=20.0).restored, 0)

    def test_logprob_limit(self):
        self.assertEqual(self.only_n(avg_logprob=-0.9).restored, 1)
        self.assertEqual(self.only_n(avg_logprob=-0.91).restored, 0)

    def test_no_speech_limit(self):
        self.assertEqual(self.only_n(no_speech_prob=0.5).restored, 1)
        self.assertEqual(self.only_n(no_speech_prob=0.51).restored, 0)

    def test_a_missing_number_is_not_vouched_for(self):
        self.assertEqual(self.only_n(avg_logprob=None).restored, 0)
        self.assertEqual(self.only_n(no_speech_prob=None).restored, 0)

    def test_punctuation_only_is_not_restored(self):
        result = self.only_n(text="!?")
        self.assertEqual((result.restored, result.rejected), (0, 1))

    def test_a_repeat_of_the_previous_neighbour_is_not_restored(self):
        p = [seg(0, 3, "네, 알겠습니다.")]
        n = [seg(5, 6.5, "네 알겠습니다")]
        result = rc.reconcile(p, n, TERMS)
        self.assertEqual((texts(result), result.restored, result.rejected), (["네, 알겠습니다."], 0, 1))

    def test_a_repeat_of_the_next_neighbour_is_not_restored(self):
        p = [seg(10, 14, "we will send the contract tomorrow")]
        n = [seg(5, 7, "We will send the contract tomorrow")]
        self.assertEqual(rc.reconcile(p, n, TERMS).restored, 0)

    def test_words_wholly_inside_the_neighbour_count_as_a_repeat_only_from_two_words(self):
        p = [seg(0, 4, "we will send the contract tomorrow")]
        self.assertEqual(rc.reconcile(p, [seg(5, 6.5, "send the contract")], TERMS).restored, 0)
        self.assertEqual(rc.reconcile(p, [seg(5, 6.5, "contract")], TERMS).restored, 1)       # one word: a separate utterance
        self.assertEqual(rc.reconcile(p, [seg(5, 6.5, "send contract the")], TERMS).restored, 1)   # not a run of the neighbour

    def test_only_the_two_segments_next_to_it_are_compared(self):
        p = [seg(0, 3, "네 알겠습니다"), seg(4, 5, "그럼"), seg(10, 13, "마지막 이야기")]
        result = rc.reconcile(p, [seg(7, 8.5, "네 알겠습니다")], TERMS)                       # the same words, but two places away
        self.assertEqual((result.restored, texts(result)), (1, ["네 알겠습니다", "그럼", "네 알겠습니다", "마지막 이야기"]))

    def test_two_adjacent_identical_restored_segments_keep_only_the_first(self):
        n = [seg(5, 6.5, "okay then"), seg(7, 8.5, "okay then")]
        result = rc.reconcile([seg(0, 2, "first words here")], n, TERMS)
        self.assertEqual((result.restored, result.rejected, len(result.segments)), (1, 1, 2))

    def test_a_plain_segment_that_aligns_is_never_restored(self):
        result = rc.reconcile([seg(0, 4, "alpha beta")], [seg(1, 3, "alpha beta")], TERMS)
        self.assertEqual((result.restored, result.rejected, result.equal), (0, 0, 1))

    def test_p_only_segments_are_kept_whatever_their_numbers(self):
        p = [seg(0, 0.2, "uh", lp=-1.4, ns=0.9)]
        result = rc.reconcile(p, [], TERMS)
        self.assertEqual(texts(result), ["uh"])


class NumbersTest(unittest.TestCase):
    def test_flagged_shapes(self):
        for text in ("80,000억", "400,000억", "매출 80,000억, 400,000억", "4000억", "40000억", "12000억", "1,000,000억", "2,000조"):
            with self.subTest(text):
                self.assertTrue(rc.implausible_numbers(text), text)

    def test_plausible_figures_are_never_flagged(self):
        for text in ("400억", "83억", "1,200억", "10,000억", "999억", "13조", "100조", "3.5억", "3.5조", "1,000,000원", "12,000 dollars", "2026년 10월",
                     "80,000", "510(k)", "400 억", "1,23억", "8천억"):
            with self.subTest(text):
                self.assertEqual(rc.implausible_numbers(text), [], text)

    def test_each_token_is_counted_once(self):
        self.assertEqual(rc.implausible_numbers("80,000억 그리고 400,000억 그리고 400억"), ["80,000억", "400,000억"])

    def test_a_space_before_the_unit_is_allowed(self):
        self.assertEqual(rc.implausible_numbers("80,000 억"), ["80,000 억"])

    def test_a_longer_digit_run_is_not_cut_into_a_plausible_tail(self):
        self.assertEqual(rc.implausible_numbers("12345억"), ["12345억"])                         # not "345억"
        self.assertEqual(rc.implausible_numbers("1.2345억"), [])                                # a decimal fraction is not a digit run

    def test_the_limits_are_arguments(self):
        self.assertEqual(rc.implausible_numbers("1,200억", max_amount=10 ** 10), ["1,200억"])
        self.assertEqual(rc.implausible_numbers("400억", max_plain_digits=2), ["400억"])
        self.assertEqual(rc.implausible_numbers("80,000억", max_amount=10 ** 14), [])
        self.assertEqual((rc.MAX_PLAUSIBLE_AMOUNT, rc.MAX_PLAIN_DIGITS_BEFORE_EOK), (10 ** 12, 3))

    def test_digit_tokens_ignore_the_thousands_separator(self):
        self.assertEqual(rc.digit_tokens("1,200 and 1200 and 3.5 and 7"), {"1200": 2, "3.5": 1, "7": 1})


class VocabularyTest(unittest.TestCase):
    def test_latin_terms_are_whole_words_and_hangul_terms_substrings(self):
        self.assertEqual(rc.term_hits("The FDA said fda, and FDAs are many", ["FDA"]), 2)
        self.assertEqual(rc.term_hits("FDA는 승인했다", ["FDA"]), 1)                            # a Korean particle after a Latin term is fine
        self.assertEqual(rc.term_hits("애크미 팀과 애크미", ["애크미"]), 2)
        self.assertEqual(rc.term_hits("AcmeScan-CXR and Acme", ["Acme"]), 1)                    # inside a longer name: not a hit

    def test_terms_with_punctuation_are_normalised_like_the_text(self):
        self.assertEqual(rc.term_hits("The 510(k) and the 510(K) path", ["510(k)"]), 2)
        self.assertEqual(rc.term_hits("pre-sub meeting, Pre Sub", ["Pre-Sub"]), 2)

    def test_the_longest_term_wins_and_nothing_is_counted_twice(self):
        self.assertEqual(rc.term_hits("Example Radiology group", ["Example", "Example Radiology"]), 1)

    def test_no_terms_no_hits(self):
        self.assertEqual(rc.term_hits("anything at all", []), 0)
        self.assertEqual(rc.term_hits("anything at all", ["", "  ", "!!"]), 0)

    def test_the_normaliser_is_the_one_of_asr(self):
        for text in ("Hello,  World!", "510(k)", "FDA는 승인했다.", "  a\tb\nc ", "", "!!!"):
            self.assertEqual(rc.norm_text(text), asr._norm(text), repr(text))

    def test_the_loop_guard_matches_the_postfilter_default(self):
        import inspect
        self.assertEqual(rc.LOOP_COMPRESSION_RATIO, inspect.signature(asr.postfilter).parameters["cr_max"].default)


if __name__ == "__main__":
    unittest.main()
