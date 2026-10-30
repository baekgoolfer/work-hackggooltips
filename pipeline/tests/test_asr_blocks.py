"""The block-upload seam of asr.py (asr_engines.BlockUpload, SPEC 18): an external engine that declares ``accepts_blocks`` gets ONE call per block of
speech instead of one per 28 s chunk, and the segment times come back on the original timeline.

Pinned: ``pack_blocks`` (the limit, a label change, offsets counted in samples), ``block_times`` (the mapping and its edge cases: a segment that
spans two chunks that touch or that do not, an empty answer, offsets exactly on a boundary, a start past the audio, and the one-chunk unit that is
exactly the old ``min(a + t, b)``), ``transcribe_track`` with a scripted block engine (the audio of a block is the chunks concatenated, the
segments land where the speech was, ``stats.<track>.blocks`` and ``block_audio_s``, a failing block, every block unreachable), a router in
front of the engine (the seam looks through it and packs for the engine that takes the chunks NOW; a block goes to a fallback only when the
fallback takes audio of that length, else the block is taken apart: ``EngineBlockDeclined``, ``split_block``, one chunk at a time with its own
language detection, a fallback with the request limit of an Azure one, a router settled on its fallback), ``ASR_STRATEGY=dual`` ignored for an
external engine, an engine without the declaration (28 s chunks, as before) and the track context (``Engine.set_track_context``) that
``transcribe_tracks`` hands over.
No socket, no real engine: scripted doubles only.

Run: python -m unittest discover -s pipeline/tests
"""
import logging
import random
import unittest
from unittest import mock

import numpy as np

from asr_support import FakeCloudEngine, FakeLocalEngine
from provider_support import SR, region_vad

from mcap import asr, audioprep, policy
from mcap import vad as vadmod
from mcap.asr_engines import EngineAuthError, EngineBlockDeclined, EnginePolicyDenied, EngineTransient, engine_caps
from mcap.asr_router import CircuitBreaker, RoutedEngine
from mcap.config import Config
from mcap.vocab import Vocab

logging.getLogger("mcap").addHandler(logging.NullHandler())

REGIONS = [(1.0, 5.0), (6.0, 9.0), (40.0, 45.0), (80.0, 83.0)]           # three chunks: the first two regions are one chunk
TOTAL = 100.0
LONG_REGIONS = [(1.0, 25.0), (30.0, 55.0), (60.0, 85.0), (90.0, 115.0)]   # four chunks of about 25 s
LONG_TOTAL = 120.0


def plan(regions=REGIONS, total=TOTAL):
    """The chunks ``transcribe_track`` plans for ``regions`` (the same call, the default window)."""
    return vadmod.plan_chunks(regions, region_vad(regions, total).db, total)


def noise(total_s: float, seed: int = 7) -> np.ndarray:
    """Distinct audio everywhere (a block can then be compared with the slices it should consist of)."""
    return (np.random.default_rng(seed).standard_normal(int(total_s * SR)) * 0.05).astype(np.float32)


def seg(start, end, text="words in the block", lp=None):
    return {"start": start, "end": end, "text": text, "avg_logprob": lp, "no_speech_prob": None, "compression_ratio": None, "temperature": 0.0}


def whole_block(audio, language, prompt):
    """One segment over the middle of whatever arrived."""
    seconds = len(audio) / SR
    return {"text": "block", "language": language or "en", "avg_logprob": None, "segments": [seg(0.2, seconds - 0.2, "words in the block")]}


def block_engine(behavior=whole_block, *, limit=900.0, **kw):
    """A scripted external engine that takes blocks of at most ``limit`` seconds."""
    return FakeCloudEngine(behavior, accepts_blocks=True, max_block_s=limit, **kw)


def run_track(engine, regions=REGIONS, total=TOTAL, x=None, config=None, **kw):
    progress = []
    kw.setdefault("language", "en")
    track = asr.transcribe_track(np.zeros(int(total * SR), np.float32) if x is None else x, engine, config or Config(), Vocab(), track="remote",
                                 vad=region_vad(regions, total), progress=progress.append, **kw)
    return track, progress


def samples(a, b):
    return int(b * SR) - int(a * SR)


# ======================================================================================================================
class PackBlocksTests(unittest.TestCase):
    def test_one_block_holds_every_chunk_up_to_the_limit(self):
        chunks = plan()
        self.assertEqual(len(chunks), 3)
        (pieces, label), = asr.pack_blocks(chunks, 900.0)
        self.assertEqual(len(pieces), 3)
        self.assertEqual([(a, b) for _, a, b in pieces], [(a, b) for a, b, _ in chunks])
        self.assertEqual(label, "")

    def test_offsets_are_counted_in_samples(self):
        (pieces, _), = asr.pack_blocks(plan(), 900.0)
        used = 0
        for offset, a, b in pieces:
            self.assertEqual(offset * SR, used)                       # exact: the offset is a whole number of samples / SR
            used += samples(a, b)

    def test_the_limit_starts_a_new_block_and_a_chunk_that_fits_exactly_stays(self):
        chunks = plan()
        first_two = (samples(*chunks[0][:2]) + samples(*chunks[1][:2])) / SR
        units = asr.pack_blocks(chunks, first_two)
        self.assertEqual([len(pieces) for pieces, _ in units], [2, 1])
        self.assertEqual(units[1][0][0][0], 0.0)                      # offsets restart in every block
        units = asr.pack_blocks(chunks, first_two - 0.001)                # a hair less: the second chunk no longer fits behind the first
        self.assertEqual([len(pieces) for pieces, _ in units], [1, 2])

    def test_a_chunk_longer_than_the_limit_is_never_cut(self):
        units = asr.pack_blocks([(0.0, 28.0, ""), (40.0, 60.0, "")], 10.0)
        self.assertEqual([[(a, b) for _, a, b in pieces] for pieces, _ in units], [[(0.0, 28.0)], [(40.0, 60.0)]])

    def test_a_change_of_label_starts_a_new_block(self):
        units = asr.pack_blocks([(0.0, 5.0, "ko"), (10.0, 15.0, "ko"), (20.0, 25.0, "en"), (30.0, 35.0, "ko")], 900.0)
        self.assertEqual([(len(pieces), label) for pieces, label in units], [(2, "ko"), (1, "en"), (1, "ko")])

    def test_no_chunk_no_block(self):
        self.assertEqual(asr.pack_blocks([], 900.0), [])


# ======================================================================================================================
class BlockTimesTests(unittest.TestCase):
    # block time:   0 ..... 8 | 8 ..... 13 | 13 ..... 19 | 19 ..... 23
    # original:     10 .. 18    20 ..... 25   25 ..... 31   50 ..... 54      (piece 1 and 2 touch: one cut inside a long region)
    PIECES = [(0.0, 10.0, 18.0), (8.0, 20.0, 25.0), (13.0, 25.0, 31.0), (19.0, 50.0, 54.0)]

    def times(self, start, end):
        return asr.block_times(self.PIECES, start, end)

    def test_a_segment_inside_one_piece(self):
        self.assertEqual(self.times(1.0, 3.0), (11.0, 13.0))
        self.assertEqual(self.times(9.0, 11.0), (21.0, 23.0))
        self.assertEqual(self.times(14.0, 16.5), (26.0, 28.5))

    def test_a_segment_that_spans_two_chunks_that_touch_keeps_its_true_span(self):
        self.assertEqual(self.times(11.0, 15.0), (23.0, 27.0))        # 25 is where piece 1 ends and piece 2 begins in the original too

    def test_a_segment_that_spans_two_chunks_with_silence_between_them_is_cut_at_the_end_of_the_first_and_its_text_is_kept(self):
        self.assertEqual(self.times(6.0, 9.0), (16.0, 18.0))          # piece 0 ends at 18 and piece 1 starts at 20: silence was cut out

    def test_a_segment_across_three_pieces_is_cut_at_the_first_gap(self):
        self.assertEqual(self.times(9.0, 21.0), (21.0, 31.0))          # pieces 1 and 2 touch (to 31), piece 3 is far away

    def test_offsets_exactly_on_a_boundary(self):
        self.assertEqual(self.times(0.0, 1.0), (10.0, 11.0))
        self.assertEqual(self.times(8.0, 9.0), (20.0, 21.0))          # a start on the offset of a piece belongs to that piece
        self.assertEqual(self.times(4.0, 8.0), (14.0, 18.0))          # an end exactly on the next offset: the first piece's end
        self.assertEqual(self.times(20.0, 23.0), (51.0, 54.0))        # an end exactly at the end of the block
        self.assertEqual(self.times(19.0, 19.0), (50.0, 50.0))

    def test_a_start_after_the_audio_is_nothing(self):
        self.assertIsNone(self.times(23.0, 24.0))
        self.assertIsNone(self.times(22.97, 23.5))                    # in the last 0.05 s of the LAST piece: the decoder ran on
        self.assertIsNone(self.times(40.0, 50.0))

    def test_a_start_in_the_last_50_ms_of_a_piece_that_is_not_the_last_is_the_next_pieces_first_word(self):
        self.assertEqual(self.times(12.97, 14.0), (25.0, 26.0))

    def test_an_end_past_the_block_is_clamped_to_the_end_of_the_last_piece(self):
        self.assertEqual(self.times(21.0, 99.0), (52.0, 54.0))

    def test_odd_numbers_are_taken_like_the_old_loop_took_them(self):
        self.assertEqual(self.times(-0.5, 1.0), (9.5, 11.0))          # a negative start is a + start, as before
        self.assertEqual(self.times(3.0, 2.0), (13.0, 13.0))          # an end before the start is a zero-length segment

    def test_a_unit_of_one_chunk_is_exactly_the_old_formula(self):
        rng = random.Random(20261020)
        for _ in range(2000):
            a = rng.uniform(0, 3000)
            b = a + rng.uniform(0.4, 28.0)
            start, end = rng.uniform(-1.0, b - a + 3.0), rng.uniform(-1.0, b - a + 3.0)
            old_start, old_end = min(a + start, b), min(a + end, b)
            got = asr.block_times([(0.0, a, b)], start, end)
            if old_start < b - 0.05:
                self.assertEqual(got, (old_start, max(old_start, old_end)), (a, b, start, end))
            else:
                self.assertIsNone(got, (a, b, start, end))


# ======================================================================================================================
class BlockTrackTests(unittest.TestCase):
    def test_the_chunks_of_a_track_go_out_as_one_block_and_the_segments_land_where_the_speech_was(self):
        chunks = plan()
        (pieces, _), = asr.pack_blocks(chunks, 900.0)
        got = []

        def behavior(audio, language, prompt):
            got.append(audio.copy())
            offs = [offset for offset, _, _ in pieces]
            return {"text": "", "language": "en", "avg_logprob": None,
                    "segments": [seg(1.0, 3.0, "first"), seg(offs[1] + 0.5, offs[1] + 2.0, "second"), seg(offs[2] + 0.4, offs[2] + 1.5, "third")]}

        x = noise(TOTAL)
        engine = block_engine(behavior)
        res, progress = run_track(engine, x=x)
        self.assertEqual(len(engine.calls), 1)                                  # ONE request for the whole track
        self.assertTrue(np.array_equal(got[0], np.concatenate([x[int(a * SR): int(b * SR)] for _, a, b in pieces])))
        (o0, a0, _), (o1, a1, _), (o2, a2, _) = pieces
        self.assertEqual([(s["start"], s["end"], s["text"]) for s in res.segments],
                         [(round(a0 + 1.0 - o0, 2), round(a0 + 3.0 - o0, 2), "first"), (round(a1 + 0.5, 2), round(a1 + 2.0, 2), "second"),
                          (round(a2 + 0.4, 2), round(a2 + 1.5, 2), "third")])
        self.assertEqual([p for p in progress if p.startswith("transcribing")], ["transcribing remote 1/1"])
        self.assertEqual((res.info["chunks"], res.info["blocks"], res.info["block_s"]), (3, 1, 900.0))
        self.assertAlmostEqual(res.info["block_audio_s"], round(sum(samples(a, b) for a, b, _ in chunks) / SR, 1), places=1)

    def test_a_long_track_goes_out_in_blocks_of_at_most_the_limit(self):
        engine = block_engine(limit=60.0)
        res, _ = run_track(engine, LONG_REGIONS, LONG_TOTAL)
        lengths = [n / SR for n, _, _ in engine.calls]
        self.assertEqual(len(plan(LONG_REGIONS, LONG_TOTAL)), 4)
        self.assertEqual(len(lengths), 2)                                       # two chunks of about 25 s per block of at most 60 s
        self.assertTrue(all(length <= 60.0 for length in lengths), lengths)
        self.assertEqual((res.info["chunks"], res.info["blocks"]), (4, 2))
        self.assertEqual(len(res.segments), 2)
        starts = [s["start"] for s in res.segments]
        self.assertAlmostEqual(starts[0], 1.0 - 0.3 + 0.2, places=1)            # the block's first chunk starts 0.3 s before its region
        self.assertGreater(starts[1], 55.0)                                     # the second block's segment is in the second half of the track

    def test_an_empty_answer_gives_an_empty_track_and_no_error(self):
        engine = block_engine(lambda audio, language, prompt: {"text": "", "segments": [], "language": None, "avg_logprob": None})
        res, _ = run_track(engine)
        self.assertEqual((res.segments, res.dropped, res.info.get("failed_chunks", 0)), ([], [], 0))
        self.assertEqual(res.info["blocks"], 1)

    def test_a_segment_after_the_block_audio_is_dropped_like_one_after_a_chunk(self):
        engine = block_engine(lambda audio, language, prompt: {"text": "", "language": "en", "avg_logprob": None,
                                                              "segments": [seg(len(audio) / SR + 5.0, len(audio) / SR + 9.0, "after the end"),
                                                                           seg(0.5, 2.0, "inside")]})
        res, _ = run_track(engine)
        self.assertEqual([s["text"] for s in res.segments], ["inside"])

    def test_a_failing_block_loses_that_block_only(self):
        engine = block_engine([RuntimeError("one bad request"), whole_block], limit=30.0)
        res, _ = run_track(engine, LONG_REGIONS, LONG_TOTAL)
        self.assertEqual((res.info["failed_chunks"], res.info["blocks"]), (1, 4))
        self.assertEqual(len(res.segments), 3)

    def test_every_block_unreachable_is_asr_unreachable(self):
        engine = block_engine(EngineTransient("no route"))
        with self.assertRaises(asr.AsrUnreachable):
            run_track(engine)

    def test_every_block_failing_for_another_reason_is_a_failed_track(self):
        engine = block_engine(RuntimeError("bad"))
        with self.assertRaisesRegex(RuntimeError, "ASR failed for every chunk"):
            run_track(engine)

    def test_the_engine_declaration_is_checked_before_it_is_used(self):
        for declared in (0.0, 5.0, 4000.0, float("nan"), True, "900", None):
            with self.subTest(declared=declared):
                engine = FakeCloudEngine(whole_block, accepts_blocks=True, max_block_s=declared)
                self.assertEqual(asr.block_seconds(engine), 0.0)
                run_track(engine)
                self.assertEqual(len(engine.calls), 3)                          # 28 s chunks, as before
        self.assertEqual(asr.block_seconds(FakeCloudEngine(accepts_blocks=1, max_block_s=900.0)), 0.0)         # only a real True counts
        local = FakeLocalEngine(accepts_blocks=True, max_block_s=900.0)
        self.assertEqual(asr.block_seconds(local), 0.0)                         # a local engine never gets blocks

    def test_an_engine_without_the_declaration_still_gets_one_call_per_chunk_and_no_block_keys(self):
        engine = FakeCloudEngine(whole_block)
        res, _ = run_track(engine)
        self.assertEqual(len(engine.calls), 3)
        self.assertNotIn("blocks", res.info)
        self.assertNotIn("block_audio_s", res.info)
        self.assertEqual(res.info["chunks"], 3)

    def test_dual_is_ignored_for_an_external_engine(self):
        engine = block_engine()
        res, _ = run_track(engine, config=Config(asr_strategy="dual"))
        self.assertEqual(len(engine.calls), 1)                                  # one decode, no second pass
        self.assertNotIn("strategy", res.info)
        self.assertNotIn("dual", res.info)


class BlockRouterTests(unittest.TestCase):
    def router(self, primary, fallback=None):
        return RoutedEngine(primary, fallback, CircuitBreaker(threshold=3, cooldown_s=120.0))

    def test_the_seam_looks_through_a_router_at_its_primary(self):
        primary = block_engine()
        router = self.router(primary)
        self.assertFalse(engine_caps(router).accepts_blocks)                    # the router does not declare it ...
        self.assertEqual(asr.block_seconds(router), 900.0)                      # ... the primary behind it does
        res, _ = run_track(router)
        self.assertEqual(len(primary.calls), 1)
        self.assertEqual(res.info["blocks"], 1)

    def test_a_primary_that_cannot_be_reached_hands_a_block_that_fits_the_fallback_over_whole(self):
        primary = block_engine(EngineTransient("down"))
        seen = []

        def local(audio, language, prompt):
            seen.append(len(audio))
            return whole_block(audio, language, prompt)

        fallback = FakeLocalEngine(local)
        res, _ = run_track(self.router(primary, fallback))                      # the three chunks of REGIONS are 17.8 s of speech: one chunk's worth
        self.assertEqual(len(primary.calls), 1)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0], primary.calls[0][0])                          # the same block: the fallback takes audio of that length
        self.assertEqual(len(res.segments), 1)
        self.assertNotIn("split_blocks", res.info)

    def test_a_block_longer_than_the_fallback_takes_is_decoded_chunk_by_chunk(self):
        # the Whisper-like fallback takes 28 s: a block of 100 s must not reach it whole (the prompt, the language and the dual logic work per chunk)
        primary = block_engine(EngineTransient("down"))
        seen = []

        def local(audio, language, prompt):
            seen.append((len(audio) / SR, language, prompt))
            return whole_block(audio, language, prompt)

        chunks = plan(LONG_REGIONS, LONG_TOTAL)
        res, _ = run_track(self.router(primary, FakeLocalEngine(local)), LONG_REGIONS, LONG_TOTAL)
        self.assertEqual(len(seen), 4)
        self.assertTrue(all(seconds <= 28.0 for seconds, _, _ in seen), seen)
        self.assertAlmostEqual(sum(seconds for seconds, _, _ in seen), sum(samples(a, b) for a, b, _ in chunks) / SR, places=3)
        self.assertLessEqual(len(primary.calls), 3)                             # the block, then chunks until the circuit opens: the breaker's bound
        self.assertEqual((res.info["split_blocks"], res.info["blocks"], res.info.get("failed_chunks", 0)), (1, 1, 0))
        self.assertEqual(len(res.segments), 4)                                  # every chunk was transcribed and lands in its own region
        self.assertEqual([int(s["start"] // 30) for s in res.segments], [0, 0, 1, 2])
        self.assertEqual(res.info["block_audio_s"], round(sum(samples(a, b) for a, b, _ in chunks) / SR, 1))    # the declined block is not counted, its parts are

    def test_the_fallback_gets_the_language_detection_of_every_chunk_and_not_of_the_first_30_seconds(self):
        # auto language, the primary has no language ID: the labels are empty and the local decoder detects the language itself, from the first
        # 30 s of what it is given. A whole block would be read in the language of its first chunk.
        def whisper_like(audio, language, prompt):
            lang = language or ("ko" if float(np.abs(audio[: 30 * SR]).max()) < 0.15 else "en")
            return {"text": "", "language": lang, "avg_logprob": -0.2, "segments": [seg(0.2, len(audio) / SR - 0.2, f"words {lang}", lp=-0.2)]}

        x = np.zeros(int(LONG_TOTAL * SR), np.float32)
        for (a, b), level in zip(LONG_REGIONS, (0.1, 0.2, 0.1, 0.2)):
            x[int(a * SR): int(b * SR)] = level
        res, _ = run_track(self.router(block_engine(EngineTransient("down")), FakeLocalEngine(whisper_like)), LONG_REGIONS, LONG_TOTAL, x=x,
                           language="auto")
        self.assertEqual([s["lang"] for s in res.segments], ["ko", "en", "ko", "en"])

    def test_a_fallback_with_the_request_limit_of_an_azure_one_never_gets_a_block(self):
        limit = policy.HostRule(host="asr.example.org").max_request_bytes        # what an azure or remote fallback may send in one request
        got = []

        def azure_sized(audio, language, prompt):
            got.append(len(audio))
            if 2 * len(audio) + 44 > limit:
                raise EnginePolicyDenied("request_too_large")
            return whole_block(audio, language, prompt)

        fallback = FakeCloudEngine(azure_sized, engine_id="azure")
        self.assertGreater(2 * sum(samples(a, b) for a, b, _ in plan(LONG_REGIONS, LONG_TOTAL)) + 44, limit)      # the block would have been refused
        res, _ = run_track(self.router(block_engine(EngineTransient("down")), fallback), LONG_REGIONS, LONG_TOTAL)
        self.assertEqual((len(got), res.info.get("failed_chunks", 0), len(res.segments)), (4, 0, 4))
        self.assertTrue(all(2 * n + 44 <= limit for n in got))

    def test_a_router_that_settled_on_its_fallback_packs_for_the_fallback(self):
        # no key (EngineAuthError at load): the primary is out for the whole run, the local fallback leads and takes 28 s chunks
        primary = block_engine(load_error=EngineAuthError("no key"))
        fallback = FakeLocalEngine()
        router = self.router(primary, fallback)
        self.assertEqual(asr.block_seconds(router), 900.0)                      # before it has loaded it still looks like the primary's run
        res, _ = run_track(router, LONG_REGIONS, LONG_TOTAL)
        self.assertEqual((asr.block_seconds(router), len(primary.calls), len(fallback.calls)), (0.0, 0, 4))
        self.assertNotIn("blocks", res.info)
        self.assertNotIn("split_blocks", res.info)

    def test_a_block_the_engine_declines_without_a_fallback_is_decoded_in_chunks_by_the_same_engine(self):
        declined = []

        def behavior(audio, language, prompt):
            if len(audio) / SR > 28.0:                                          # the service takes a chunk, not a block
                declined.append(len(audio))
                raise EngineBlockDeclined("too long")
            return whole_block(audio, language, prompt)

        engine = block_engine(behavior)
        res, _ = run_track(engine, LONG_REGIONS, LONG_TOTAL)
        self.assertEqual((len(declined), len(engine.calls), res.info["split_blocks"], res.info.get("failed_chunks", 0)), (1, 5, 1, 0))
        self.assertEqual(len(res.segments), 4)

    def test_a_chunk_that_is_declined_is_a_failed_chunk_and_not_an_endless_loop(self):
        engine = block_engine(EngineBlockDeclined("no"), limit=30.0)                  # blocks of one chunk: nothing left to take apart
        with self.assertRaisesRegex(RuntimeError, "ASR failed for every chunk"):
            run_track(engine, LONG_REGIONS, LONG_TOTAL)
        self.assertEqual(len(engine.calls), 4)

    def test_a_local_primary_with_an_external_fallback_gets_chunks(self):
        primary = FakeLocalEngine()
        res, _ = run_track(self.router(primary, block_engine()))
        self.assertEqual(asr.block_seconds(self.router(primary, block_engine())), 0.0)
        self.assertEqual(len(primary.calls), 3)
        self.assertNotIn("blocks", res.info)

    def test_members_of_a_router_and_a_plain_engine(self):
        a, b = block_engine(), FakeLocalEngine()
        self.assertEqual(asr._members(self.router(a, b)), [a, b])
        self.assertEqual(asr._members(self.router(a)), [a])
        self.assertEqual(asr._members(a), [a])
        self.assertEqual(asr._members(mock.MagicMock()).__len__(), 1)           # a double with every attribute is not mistaken for a router


# ======================================================================================================================
class SplitBlockTests(unittest.TestCase):
    def pieces(self):
        (pieces, label), = asr.pack_blocks(plan(LONG_REGIONS, LONG_TOTAL), 900.0)
        self.assertEqual(len(pieces), 4)
        return pieces, label

    def test_an_engine_that_still_takes_the_same_length_gets_its_chunks_one_by_one(self):
        pieces, label = self.pieces()
        units = asr.split_block(block_engine(limit=900.0), pieces, label)
        self.assertEqual([[(a, b) for _, a, b in p] for p, _ in units], [[(a, b)] for _, a, b in pieces])
        self.assertTrue(all(p[0][0] == 0.0 for p, _ in units))                  # every unit counts its offsets from 0

    def test_an_engine_that_now_takes_shorter_blocks_gets_blocks_of_that_length(self):
        pieces, label = self.pieces()
        self.assertEqual([len(p) for p, _ in asr.split_block(block_engine(limit=60.0), pieces, label)], [2, 2])

    def test_an_engine_that_takes_no_blocks_gets_chunks(self):
        pieces, label = self.pieces()
        self.assertEqual([len(p) for p, _ in asr.split_block(FakeLocalEngine(), pieces, label)], [1, 1, 1, 1])

    def test_a_router_whose_primary_is_out_for_good_splits_for_its_fallback(self):
        pieces, label = self.pieces()
        router = RoutedEngine(block_engine(limit=60.0), FakeLocalEngine(), CircuitBreaker())
        self.assertEqual([len(p) for p, _ in asr.split_block(router, pieces, label)], [2, 2])             # the primary leads: blocks of its length
        router.breaker.trip(permanent=True)
        self.assertEqual([len(p) for p, _ in asr.split_block(router, pieces, label)], [1, 1, 1, 1])       # the fallback leads: chunks


# ======================================================================================================================
class TrackContextTests(unittest.TestCase):
    def recorder(self):
        heard = []
        return heard, (lambda track, solo, platform: heard.append((track, solo, platform)))

    def test_the_engine_hears_the_track_before_its_chunks(self):
        heard, hook = self.recorder()
        engine = block_engine(set_track_context=hook)
        run_track(engine, context={"solo": False, "platform": "zoom"})
        self.assertEqual(heard, [("remote", False, "zoom")])

    def test_the_default_context_is_a_single_track(self):
        heard, hook = self.recorder()
        run_track(block_engine(set_track_context=hook))
        self.assertEqual(heard, [("remote", True, "")])

    def test_every_member_of_a_router_hears_it(self):
        one, two = self.recorder(), self.recorder()
        router = RoutedEngine(block_engine(set_track_context=one[1]), FakeLocalEngine(set_track_context=two[1]), CircuitBreaker())
        run_track(router, context={"solo": False, "platform": ""})
        self.assertEqual((one[0], two[0]), ([("remote", False, "")], [("remote", False, "")]))

    def test_an_engine_that_cannot_take_it_does_not_cost_the_track(self):
        def broken(track, solo, platform):
            raise RuntimeError("no")

        with self.assertLogs("mcap.asr", "WARNING") as logs:
            res, _ = run_track(block_engine(set_track_context=broken))
        self.assertEqual(len(res.segments), 1)
        self.assertIn("did not take the track context", logs.output[0])
        run_track(FakeCloudEngine(whole_block))                                 # a double without the method hears nothing

    def tracks(self, missing=(), platform=None):
        prepared = audioprep.PreparedAudio({"mic": np.zeros(SR, np.float32), "remote": np.zeros(SR, np.float32)}, SR, 1.0, {}, list(missing))
        if platform is not None:
            prepared.platform = platform
        contexts = {}

        def fake_track(x, engine, c, v, **kw):
            contexts[kw["track"]] = kw["context"]
            return asr.TrackResult(kw["track"], [], [], None, {"speech_s": 0.0})

        with mock.patch.object(asr, "get_engine", return_value=FakeLocalEngine()), mock.patch.object(asr, "transcribe_track", side_effect=fake_track):
            asr.transcribe_tracks(prepared, Config(mic_aec="0"), Vocab())
        return contexts

    def test_transcribe_tracks_says_whether_a_track_is_the_only_one_and_what_the_platform_is(self):
        self.assertEqual(self.tracks(), {"mic": {"solo": False, "platform": ""}, "remote": {"solo": False, "platform": ""}})
        self.assertEqual(self.tracks(missing=("remote",)), {"mic": {"solo": True, "platform": ""}})
        self.assertEqual(self.tracks(missing=("mic",)), {"remote": {"solo": True, "platform": ""}})
        self.assertEqual(self.tracks(platform="manual")["mic"], {"solo": False, "platform": "manual"})       # PreparedAudio.platform, when a caller sets it
        self.assertEqual(self.tracks(platform=None)["remote"]["platform"], "")


if __name__ == "__main__":
    unittest.main()
