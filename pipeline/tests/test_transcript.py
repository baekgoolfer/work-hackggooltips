"""transcript: format_ts, adjacent-segment merging, render_markdown golden output (SPEC 4.4), validation. numpy not needed."""
import copy
import json
import os
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcap import transcript as tr  # noqa: E402


def seg(start, end, speaker, text, track=None, lang=None, lp=-0.2, ns=0.01):
    track = track or ("mic" if speaker != "Remote" else "remote")
    return {"start": start, "end": end, "speaker": speaker, "track": track, "lang": lang or ("ko" if track == "mic" else "en"),
            "text": text, "avg_logprob": lp, "no_speech_prob": ns}


META = {"title": "Alex Morgan Weekly", "date": "2026-10-07", "platform_label": "Google Meet",
        "start_time": "2026-10-07T14:00:12+09:00", "duration_sec": 3808.4, "asr_model": "mlx-community/whisper-large-v3-mlx"}

SEGMENTS = [
    seg(13.2, 19.8, "Me", "안녕하세요, Alex."),
    seg(20.5, 24.0, "Me", "오늘 FDA 이야기를 하겠습니다."),         # 0.7 s after the previous: same block
    seg(31.0, 40.0, "Remote", "Sounds good."),
    seg(41.0, 45.0, "Remote", "Let's start with the 510(k)."),     # 1.0 s gap: same block
    seg(48.0, 50.0, "Me", "네."),
    seg(52.0, 53.0, "Me", "네?"),                                  # exactly 2.0 s gap: new block
]

GOLDEN = """# Transcript

Meeting: Alex Morgan Weekly
Date: 2026-10-07
Platform: Google Meet
Start: 14:00:12 (KST)   Duration: 01:03:28
ASR: mlx-community/whisper-large-v3-mlx  (mic: ko, remote: en)

[00:00:13] Me
안녕하세요, Alex. 오늘 FDA 이야기를 하겠습니다.

[00:00:31] Remote
Sounds good. Let's start with the 510(k).

[00:00:48] Me
네.

[00:00:52] Me
네?
"""


class TzCase(unittest.TestCase):
    """render_markdown prints the zone abbreviation of this machine; pin it so the golden text is deterministic."""

    def setUp(self):
        self._old = os.environ.get("TZ")
        os.environ["TZ"] = "Asia/Seoul"
        time.tzset()

    def tearDown(self):
        if self._old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self._old
        time.tzset()


class FormatTsTest(unittest.TestCase):
    def test_table(self):
        cases = [(0, "00:00:00"), (0.999, "00:00:00"), (13.2, "00:00:13"), (59.99, "00:00:59"), (60, "00:01:00"), (3599.9, "00:59:59"),
                 (3600, "01:00:00"), (3808.4, "01:03:28"), (86399, "23:59:59"), (90061, "25:01:01"), (360000, "100:00:00"),
                 (-5, "00:00:00"), (float("nan"), "00:00:00"), (float("inf"), "00:00:00"), (None, "00:00:00"), ("x", "00:00:00"), ("12.7", "00:00:12")]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(tr.format_ts(value), expected)


class MergeTest(unittest.TestCase):
    def test_same_speaker_gap_threshold(self):
        blocks = tr.merge_adjacent([seg(0, 1, "Me", "a"), seg(2.9, 4, "Me", "b"), seg(6.0, 7, "Me", "c")])
        self.assertEqual([b["text"] for b in blocks], ["a b", "c"])             # gap 1.9 merges, gap 2.0 does not
        self.assertEqual((blocks[0]["start"], blocks[0]["end"]), (0, 4))

    def test_different_speakers_never_merge_and_interleaving_splits_blocks(self):
        segs = [seg(0, 10, "Remote", "long remote sentence"), seg(3, 4, "Me", "mm-hm"), seg(10.5, 12, "Remote", "continues")]
        blocks = tr.merge_adjacent(segs)
        self.assertEqual([(b["speaker"], b["text"]) for b in blocks],
                         [("Remote", "long remote sentence"), ("Me", "mm-hm"), ("Remote", "continues")])

    def test_overlap_counts_as_adjacent(self):
        blocks = tr.merge_adjacent([seg(0, 5, "Me", "one"), seg(4, 6, "Me", "two")])
        self.assertEqual(blocks[0]["text"], "one two")
        self.assertEqual(blocks[0]["end"], 6)

    def test_unsorted_input_empty_text_and_whitespace(self):
        blocks = tr.merge_adjacent([seg(2.5, 3.5, "Me", "second\n line"), seg(0, 1, "Me", "  first  "), seg(1.2, 1.8, "Me", "   ")])
        self.assertEqual([b["text"] for b in blocks], ["first second line"])
        self.assertEqual(tr.merge_adjacent([]), [])

    def test_custom_gap(self):
        blocks = tr.merge_adjacent([seg(0, 1, "Me", "a"), seg(1.0, 2, "Me", "b")], gap=0.0)
        self.assertEqual(len(blocks), 2)


class BlockCapTest(unittest.TestCase):
    """review_transcribe: a remote speaker who pauses < 2 s between Whisper segments used to become ONE block with ONE timestamp
    for the whole turn (a synthetic 12-minute monologue: one block, 713 s, one [00:00:30]). A block is now capped."""

    def monologue(self, n=70, seg_s=9.5, pause=0.4, speaker="Remote"):
        segs, t = [], 30.0
        for i in range(n):
            segs.append(seg(t, t + seg_s, speaker, f"Sentence number {i} of a very long monologue."))
            t += seg_s + pause
        return segs

    def test_a_long_monologue_gets_a_timestamp_about_every_minute(self):
        segs = self.monologue()
        blocks = tr.merge_adjacent(segs)
        self.assertGreater(len(blocks), 10)
        self.assertTrue(all(b["end"] - b["start"] <= 60.0 + 1e-9 for b in blocks), [b["end"] - b["start"] for b in blocks])
        self.assertTrue(all(len(b["text"]) <= 600 for b in blocks))
        self.assertEqual(" ".join(b["text"] for b in blocks), " ".join(s["text"] for s in segs))      # no text lost or reordered
        self.assertEqual(blocks[0]["start"], 30.0)
        starts = [b["start"] for b in blocks]
        self.assertEqual(starts, sorted(starts))
        out = tr.render_markdown(tr.make_transcript("m", {"mic": "ko", "remote": "en"}, segs), META)
        self.assertEqual(out.count("] Remote\n"), len(blocks))
        self.assertIn("[00:00:30] Remote\n", out)

    def test_the_character_cap(self):
        segs = [seg(i * 3.0, i * 3.0 + 2.5, "Me", "x" * 150) for i in range(10)]              # 3 s apart: well within 60 s
        blocks = tr.merge_adjacent(segs)
        self.assertEqual([len(b["text"]) for b in blocks], [452, 452, 452, 150])               # 3 x 150 + 2 spaces; a 4th would make 603
        self.assertTrue(all(len(b["text"]) <= 600 for b in blocks))

    def test_a_single_long_segment_is_never_split(self):
        blocks = tr.merge_adjacent([seg(0, 180, "Remote", "y" * 2000), seg(180.5, 185, "Remote", "after")])
        self.assertEqual(blocks[0]["text"], "y" * 2000)
        self.assertEqual((blocks[0]["start"], blocks[0]["end"]), (0, 180))
        self.assertEqual(blocks[1]["text"], "after")                                             # the next one starts its own block

    def test_below_the_caps_the_spec_merge_rule_is_unchanged(self):
        blocks = tr.merge_adjacent([seg(0, 20, "Me", "a"), seg(21, 40, "Me", "b"), seg(41, 59.5, "Me", "c")])
        self.assertEqual([b["text"] for b in blocks], ["a b c"])                                  # exactly 59.5 s
        blocks = tr.merge_adjacent([seg(0, 20, "Me", "a"), seg(21, 40, "Me", "b"), seg(41, 60.5, "Me", "c")])
        self.assertEqual([b["text"] for b in blocks], ["a b", "c"])                               # 60.5 s would exceed the cap

    def test_caps_can_be_changed_or_switched_off(self):
        segs = self.monologue(n=20)
        self.assertEqual(len(tr.merge_adjacent(segs, max_block_sec=None, max_block_chars=None)), 1)
        self.assertGreater(len(tr.merge_adjacent(segs, max_block_sec=20.0)), len(tr.merge_adjacent(segs)))
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, segs)
        self.assertEqual(tr.render_markdown(t, META, max_block_sec=None, max_block_chars=None).count("] Remote\n"), 1)

    def test_other_speakers_still_split_blocks_and_each_cap_window_restarts(self):
        segs = self.monologue(n=14, speaker="Remote") + [seg(200.0, 201.0, "Me", "mm-hm")] + [seg(202.0 + i * 9.0, 211.0 + i * 9.0, "Remote", f"back {i}") for i in range(3)]
        blocks = tr.merge_adjacent(segs)
        self.assertEqual([b["speaker"] for b in blocks if b["start"] >= 200.0], ["Me", "Remote"])
        self.assertEqual(blocks[-1]["start"], 202.0)


class RenderTest(TzCase):
    def test_golden(self):
        t = tr.make_transcript("mlx-community/whisper-large-v3-mlx", {"mic": "ko", "remote": "en"}, copy.deepcopy(SEGMENTS))
        self.assertEqual(tr.render_markdown(t, META), GOLDEN)

    def test_render_does_not_depend_on_segment_order_or_extra_keys(self):
        t = {"schema": 1, "asr_model": "m", "languages": {"mic": "ko", "remote": "en"}, "segments": list(reversed(copy.deepcopy(SEGMENTS))),
             "dropped": {"mic": 1}, "stats": {"anything": 1}}
        self.assertEqual(tr.render_markdown(t, META), GOLDEN)

    def test_speaker_label_comes_from_the_segments(self):
        segs = [seg(1, 2, "Tester", "hello"), seg(5, 6, "Remote", "hi")]
        out = tr.render_markdown(tr.make_transcript("m", {"mic": "en", "remote": "en"}, segs), META)
        self.assertIn("[00:00:01] Tester\nhello\n", out)
        self.assertIn("[00:00:05] Remote\nhi\n", out)

    def test_missing_language_and_no_segments(self):
        out = tr.render_markdown(tr.make_transcript("m", {"mic": None, "remote": "en"}, []), META)
        self.assertIn("ASR: mlx-community/whisper-large-v3-mlx  (mic: -, remote: en)", out)
        self.assertTrue(out.endswith("(no speech detected)\n"))
        self.assertNotIn("\n\n\n", out)

    def test_languages_of_other_shapes(self):
        """transcribe-file passes {"file": "auto"}; a transcript without languages gets no parenthesis."""
        segs = [seg(1, 2, "Speaker", "x", track="file")]
        out = tr.render_markdown({"schema": 1, "asr_model": "m", "languages": {"file": "auto"}, "segments": segs}, META)
        self.assertIn("ASR: mlx-community/whisper-large-v3-mlx  (file: auto)\n", out)
        out = tr.render_markdown({"schema": 1, "asr_model": "m", "segments": segs}, {})
        self.assertIn("ASR: m\n", out)
        out = tr.render_markdown({"schema": 1, "asr_model": "m", "languages": {"remote": "en", "mic": "ko", "extra": None}, "segments": []}, {})
        self.assertIn("ASR: m  (mic: ko, remote: en, extra: -)\n", out)

    def test_sparse_meta(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, [seg(0, 70, "Me", "x")])
        out = tr.render_markdown(t, {})
        self.assertIn("Meeting: Untitled meeting\n", out)
        self.assertIn("Date: unknown\n", out)
        self.assertIn("Start: unknown   Duration: 00:01:10\n", out)       # duration falls back to the last segment end
        self.assertIn("ASR: m  (mic: ko, remote: en)\n", out)

    def test_title_falls_back_to_platform_and_is_one_line(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, [])
        self.assertIn("Meeting: Google Meet\n", tr.render_markdown(t, {"platform_label": "Google Meet", "title": "  "}))
        self.assertIn("Meeting: A B\n", tr.render_markdown(t, {"title": "A\nB"}))
        self.assertIn("Meeting: Slack huddle\n", tr.render_markdown(t, {"platform_label": "Slack huddle"}))      # another app's call: the app's name
        self.assertIn("Platform: Slack huddle\n", tr.render_markdown(t, {"platform_label": "Slack huddle"}))

    def test_start_time_variants(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, [])
        kst = tr.render_markdown(t, {"start_time": datetime(2026, 10, 7, 14, 0, 12, tzinfo=timezone(timedelta(hours=9)))})
        self.assertIn("Start: 14:00:12 (KST)", kst)
        self.assertIn("Date: 2026-10-07", kst)                              # derived from start_time when date is absent
        other = tr.render_markdown(t, {"start_time": "2026-10-07T14:00:12+05:30"})
        self.assertIn("Start: 14:00:12 (UTC+05:30)", other)
        self.assertIn("Start: 14:00:12 (UTC-08:00)", tr.render_markdown(t, {"start_time": "2026-10-07T14:00:12-08:00"}))
        self.assertIn("Start: 05:00:12 (UTC)", tr.render_markdown(t, {"start_time": "2026-10-07T05:00:12Z"}))
        self.assertIn("Start: 14:00:12 (KST)", tr.render_markdown(t, {"start_time": "2026-10-07T14:00:12"}))     # naive = local time
        self.assertIn("Start: unknown", tr.render_markdown(t, {"start_time": "garbage"}))

    def test_merge_gap_zero_keeps_every_segment(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, copy.deepcopy(SEGMENTS))
        out = tr.render_markdown(t, META, merge_gap=0.0)
        self.assertEqual(out.count("] Me\n"), 4)
        self.assertEqual(out.count("] Remote\n"), 2)

    def test_json_roundtrip_keeps_hangul(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, copy.deepcopy(SEGMENTS))
        again = json.loads(json.dumps(t, ensure_ascii=False))
        self.assertEqual(tr.render_markdown(again, META), GOLDEN)


class MakeAndValidateTest(unittest.TestCase):
    def test_make_transcript_sorts_by_time_then_track(self):
        segs = [seg(5, 6, "Remote", "r"), seg(5, 6, "Me", "j"), seg(1, 2, "Remote", "first")]
        t = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, segs, dropped={"mic": 0}, echo_suppressed=2)
        self.assertEqual([s["text"] for s in t["segments"]], ["first", "j", "r"])
        self.assertEqual((t["schema"], t["echo_suppressed"], t["dropped"]), (1, 2, {"mic": 0}))

    def test_valid_transcript_has_no_problems(self):
        t = tr.make_transcript("m", {"mic": "ko", "remote": None}, copy.deepcopy(SEGMENTS))
        self.assertEqual(tr.validate_transcript(t), [])
        t["segments"][0]["avg_logprob"] = None                  # engines without log-probs
        self.assertEqual(tr.validate_transcript(t), [])

    def test_problems_are_reported(self):
        good = tr.make_transcript("m", {"mic": "ko", "remote": "en"}, copy.deepcopy(SEGMENTS))
        cases = {
            "not an object": [],
            "schema": {**good, "schema": 2},
            "asr_model": {**good, "asr_model": ""},
            "languages": {**good, "languages": {"mic": "ko"}},
            "segments type": {**good, "segments": "x"},
        }
        self.assertTrue(tr.validate_transcript([]))
        for label, bad in cases.items():
            if label != "not an object":
                with self.subTest(label):
                    self.assertTrue(tr.validate_transcript(bad), label)
        broken = copy.deepcopy(good)
        broken["segments"][1]["start"] = "13"
        broken["segments"][2]["track"] = "nobody"
        broken["segments"][3]["end"] = 1.0                      # end < start
        broken["segments"][4]["text"] = "  "
        del broken["segments"][5]["no_speech_prob"]
        problems = tr.validate_transcript(broken)
        for needle in ("segments[1].start", "segments[2].track", "segments[3]", "segments[4]", "no_speech_prob"):
            self.assertTrue(any(needle in p for p in problems), (needle, problems))

    def test_out_of_order_segments_are_flagged(self):
        t = {"schema": 1, "asr_model": "m", "languages": {"mic": "ko", "remote": "en"},
             "segments": [seg(5, 6, "Me", "b"), seg(1, 2, "Me", "a")]}
        self.assertTrue(any("out of time order" in p for p in tr.validate_transcript(t)))


if __name__ == "__main__":
    unittest.main()
