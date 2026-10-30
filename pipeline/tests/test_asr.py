"""asr / asr_engines: post-filter, prompt budget, chunk loop (fake engine), language ID, echo suppression, model resolution,
engine routing, an end-to-end run with the tiny Whisper model and the benchmark script.

Environment for the model-dependent tests (they skip themselves when something is missing; nothing is ever downloaded):
  HF_HOME=<dir with models--mlx-community--whisper-tiny-mlx>   MCAP_SILERO_MODEL=<silero_vad.onnx> (optional)
  benchmarks/tts/*.wav (macOS `say` clips; git-ignored)
Run: python -m unittest discover -s pipeline/tests
"""
import importlib.util
import json
import logging
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from mcap import asr, asr_engines, audioprep, transcript as tr, vad, wavio  # noqa: E402
from mcap.asr_engines import Engine, WhisperEngine  # noqa: E402
from mcap.config import Config  # noqa: E402
from mcap.vocab import Vocab, parse_vocab_text  # noqa: E402

logging.getLogger("mcap").addHandler(logging.NullHandler())

ROOT = Path(__file__).resolve().parents[2]
TTS = ROOT / "benchmarks" / "tts"
TINY = "mlx-community/whisper-tiny-mlx"
SR = 16000

try:
    import mlx_whisper  # noqa: F401
    HAVE_MLX_WHISPER = True
except ImportError:
    HAVE_MLX_WHISPER = False


def tiny_available() -> bool:
    if not HAVE_MLX_WHISPER:
        return False
    try:
        from huggingface_hub import snapshot_download
        return (Path(snapshot_download(TINY, local_files_only=True)) / "config.json").exists()
    except Exception:
        return False


needs_mlx_whisper = unittest.skipUnless(HAVE_MLX_WHISPER, "mlx_whisper not installed")
needs_hf_hub = unittest.skipUnless(importlib.util.find_spec("huggingface_hub") is not None, "huggingface_hub not installed (production venv only)")
needs_tiny = unittest.skipUnless(tiny_available(), "whisper-tiny-mlx is not in the local HF cache (set HF_HOME)")
needs_tts = unittest.skipUnless((TTS / "meeting_like_184s.wav").exists(), "benchmarks/tts clips not generated")

VOCAB = parse_vocab_text("Acme\nAcmeScan-CXR\nFDA\n510(k)\nPre-Sub\nHIPAA\nExample Radiology\nAcme = 애크미 | 액미\n")


def seg(start, end, text, lp=-0.3, ns=0.02, cr=1.2, lang="en", temp=0.0):
    return asr.Seg(start, end, text, lang, lp, ns, cr, temp)


# ---------------------------------------------------------------------------------------
# fake engine: deterministic, records every call
# ---------------------------------------------------------------------------------------
class SpaceTokenizer:
    def encode(self, text):
        return text.split()


class FakeEngine(Engine):
    name = "fake"
    supports_lid = True
    prompt_frames = WhisperEngine.prompt_frames

    def __init__(self, script=None, lid=None, supports_lid=True):
        super().__init__("fake-model")
        self.supports_lid = supports_lid
        self.calls = []             # (n_samples, language, prompt)
        self.lid_calls = []         # number of clips per detect_languages call
        self.lid_languages = []     # the language set of every detect_languages call
        self.loaded = 0
        self.script = script or self.default_script
        self.lid = lid or (lambda clip: {"ko": 0.01, "en": 0.99, "top": "en"})
        self.released = 0

    def load(self):
        self.loaded += 1

    @property
    def tokenizer(self):
        return SpaceTokenizer()

    def detect_languages(self, clips, languages=asr_engines.LID_CANDIDATES):
        """Like WhisperEngine: whatever the backend `lid` says, restricted to `languages` and renormalised."""
        self.lid_calls.append(len(clips))
        self.lid_languages.append(tuple(languages))
        return [asr_engines.restrict_lid(self.lid(c), languages) for c in clips]

    def release(self):
        self.released += 1

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append((len(audio), language, prompt))
        return self.script(audio, language, prompt, len(self.calls) - 1)

    @staticmethod
    def default_script(audio, language, prompt, i):
        d = len(audio) / SR
        return {"text": f"chunk {i}", "language": language, "avg_logprob": -0.3,
                "segments": [{"start": 0.2, "end": d - 0.2, "text": f"chunk {i}", "avg_logprob": -0.3, "no_speech_prob": 0.01,
                              "compression_ratio": 1.1, "temperature": 0.0}]}


def vad_result(regions, total, probs=None):
    """A VAD result for tests; ``probs`` = Silero's mean probability per region (None: the energy VAD, which has none)."""
    return vad.VadResult(regions, "silero" if probs is not None else "energy", np.full(int(total * 50), -50.0, np.float32), {},
                         region_probs=probs)


def cfg(**kw):
    kw.setdefault("support_dir", Path(tempfile.gettempdir()) / "mcap-test-nonexistent")
    kw.setdefault("asr_strategy", "single")      # these tests count one decode per chunk; the built-in default is dual (test_asr_dual.py)
    return Config(**kw)


# ---------------------------------------------------------------------------------------
# post filter
# ---------------------------------------------------------------------------------------
class PostfilterTest(unittest.TestCase):
    def run_one(self, text, lp=-0.3, ns=0.02, cr=1.2, dur=2.0, prompt=None, others=0.0, languages=("ko", "en")):
        """``others`` = seconds of ordinary confident speech elsewhere in the same track (decides what a lone filler word is)."""
        segs = [seg(10.0, 10.0 + dur, text, lp, ns, cr)]
        if others:
            segs.append(seg(100.0, 100.0 + others, "We reviewed the FDA submission timeline and the open questions."))
        kept, dropped = asr.postfilter(segs, prompt=prompt, languages=languages)
        mine = [k for k in kept if k.start == 10.0]
        gone = [d for d in dropped if d[0].start == 10.0]
        return (mine[0].text if mine else None), (gone[0][1].split(":")[0] if gone else None)

    def test_table(self):
        cases = [
            # (label, text, kwargs, expected kept text or None, expected drop category)
            ("normal english", "Let's review the FDA submission timeline.", {}, "Let's review the FDA submission timeline.", None),
            ("normal korean", "다음 주에 미팅을 잡겠습니다.", {}, "다음 주에 미팅을 잡겠습니다.", None),
            ("thanks for watching", "Thanks for watching!", {}, None, "strong_phantom"),
            ("thank you for watching + extra", "Thank you for watching, and see you in the next video.", {}, None, "strong_phantom"),
            ("please subscribe", "Please subscribe to my channel", {"lp": -0.1}, None, "strong_phantom"),
            ("subtitles by amara", "Subtitles by the Amara.org community", {}, None, "strong_phantom"),
            ("korean watching phrase", "시청해 주셔서 감사합니다.", {"lp": -0.1}, None, "strong_phantom"),
            ("korean like and subscribe", "구독과 좋아요 부탁드립니다", {}, None, "strong_phantom"),
            ("korean next video", "다음 영상에서 만나요!", {}, None, "strong_phantom"),
            ("korean subtitle credit", "한글자막 제공 배달의민족", {}, None, "strong_phantom"),
            ("long sentence mentioning subtitles is kept", "We discussed that the team should write the subtitles by hand for the demo video next month.", {},
             "We discussed that the team should write the subtitles by hand for the demo video next month.", None),
            ("phantom phrase inside a real sentence, confident -> kept", "Thank you for watching the demo, any questions?", {},
             "Thank you for watching the demo, any questions?", None),
            ("subscribe inside a real sentence -> kept", "Please subscribe to the ExampleIRB portal for updates", {"lp": -0.2},
             "Please subscribe to the ExampleIRB portal for updates", None),
            ("... the same sentence from an unsure decoder -> dropped", "Thank you for watching the demo, any questions?", {"lp": -0.6}, None, "strong_phantom"),
            ("phantom phrase at the end with two words in front", "Okay everyone, thanks for watching.", {}, None, "strong_phantom"),
            ("news prefix, unsure", "MBC 뉴스 김철수입니다.", {"lp": -0.8}, None, "broadcast_credit"),
            ("news prefix, confident, is kept", "MBC 뉴스 이야기를 하면 좋겠습니다.", {"lp": -0.1, "ns": 0.01}, "MBC 뉴스 이야기를 하면 좋겠습니다.", None),
            ("weak phantom, confident -> kept", "Thank you.", {"lp": -0.2, "ns": 0.05, "dur": 1.5}, "Thank you.", None),
            ("weak phantom alone in the track, low logprob -> dropped", "Thank you.", {"lp": -0.9, "ns": 0.05, "dur": 1.5}, None, "weak_phantom"),
            ("weak phantom alone in the track, high no_speech -> dropped", "감사합니다.", {"lp": -0.3, "ns": 0.6, "dur": 1.0}, None, "weak_phantom"),
            ("weak phantom alone in the track, middling numbers -> kept", "감사합니다.", {"lp": -0.7, "ns": 0.4, "dur": 1.0}, "감사합니다.", None),
            ("weak phantom, long -> kept", "Thank you.", {"lp": -0.9, "ns": 0.4, "dur": 3.5}, "Thank you.", None),
            # a lone short real answer in a track that has real speech (SPEC 15): needs BOTH no_speech > 0.5 AND logprob < -0.8
            ("short answer, track with speech, one doubtful signal -> kept", "네", {"lp": -0.9, "ns": 0.1, "dur": 0.6, "others": 60}, "네", None),
            ("short answer, track with speech, other doubtful signal -> kept", "네", {"lp": -0.5, "ns": 0.55, "dur": 0.6, "others": 60}, "네", None),
            ("short answer, track with speech, lp -0.7 ns 0.35 -> kept", "OK.", {"lp": -0.7, "ns": 0.35, "dur": 0.5, "others": 60}, "OK.", None),
            ("Thank you., track with speech, lp -0.7 -> kept", "Thank you.", {"lp": -0.7, "ns": 0.1, "dur": 1.0, "others": 60}, "Thank you.", None),
            ("filler, track with speech, both signals -> dropped", "Thank you.", {"lp": -0.9, "ns": 0.55, "dur": 1.0, "others": 60}, None, "weak_phantom"),
            ("yes/no answer is not phantom", "네, 맞습니다.", {"lp": -0.9, "ns": 0.4}, "네, 맞습니다.", None),
            ("compression ratio", "blah blah blah blah blah", {"cr": 3.1}, None, "compression_ratio"),
            ("logprob floor", "Something unintelligible", {"lp": -1.8}, None, "avg_logprob"),
            ("silent and unsure", "Hmm okay then", {"lp": -0.8, "ns": 0.7}, None, "no_speech"),
            ("silent but sure -> kept", "Hmm okay then", {"lp": -0.4, "ns": 0.7}, "Hmm okay then", None),
            ("japanese hallucination in a ko/en meeting", "今日は会議の資料を確認しました", {}, None, "foreign_script"),
            ("japanese 'thanks for watching' in a ko/en meeting", "ご視聴ありがとうございました", {}, None, "strong_phantom"),
            ("cyrillic hallucination", "Продолжение следует", {}, None, "foreign_script"),
            ("mixed with a little han is kept", "이 환자는 CT 검사 結果를 확인했습니다 그리고 다음 주에 외래에서 설명할 예정입니다.", {},
             "이 환자는 CT 검사 結果를 확인했습니다 그리고 다음 주에 외래에서 설명할 예정입니다.", None),
        ]
        for label, text, kw, kept_text, category in cases:
            with self.subTest(label):
                got_kept, got_cat = self.run_one(text, **kw)
                self.assertEqual((got_kept, got_cat), (kept_text, category))

    def test_a_lone_filler_depends_on_how_much_other_speech_the_track_has(self):
        """SPEC 15: with almost no other speech one doubtful signal drops a filler word; with real speech around it both are needed."""
        doubtful = dict(lp=-0.9, ns=0.1, dur=0.8)
        self.assertEqual(self.run_one("네", **doubtful), (None, "weak_phantom"))                              # alone in the track
        self.assertEqual(self.run_one("네", others=5.0, **doubtful), (None, "weak_phantom"))                  # 5 s of speech: still "almost none"
        self.assertEqual(self.run_one("네", others=30.0, **doubtful), ("네", None))                           # real conversation around it
        for other in ("OK.", "Thank you.", "감사합니다.", "예", "bye"):
            with self.subTest(other):
                self.assertEqual(self.run_one(other, others=60.0, lp=-0.75, ns=0.3, dur=0.9)[1], None)

    def test_fillers_do_not_count_as_other_speech(self):
        segs = [seg(10.0, 11.0, "Thank you.", -0.9, 0.1), seg(20.0, 21.0, "네", -0.9, 0.1), seg(30.0, 31.0, "OK", -0.9, 0.1)]
        kept, dropped = asr.postfilter(segs)
        self.assertEqual((len(kept), len(dropped)), (0, 3))

    def test_a_dropped_hallucination_is_not_other_speech(self):
        segs = [seg(10.0, 11.0, "네", -0.9, 0.1), seg(20.0, 50.0, "blah blah blah blah blah", cr=3.5)]            # 30 s of looping nonsense
        kept, dropped = asr.postfilter(segs)
        self.assertEqual(kept, [])
        self.assertEqual({d[0].start: d[1].split(":")[0] for d in dropped}, {10.0: "weak_phantom", 20.0: "compression_ratio"})

    def test_japanese_in_the_language_set_is_not_foreign(self):
        """ASR_LANGUAGES=ja,ko,en: kana and Han are real text; the Japanese phantom phrases are still dropped."""
        ja = "今日は会議の資料を確認しました。次回までに修正します。"
        for languages, expected in ((("ko", "en"), (None, "foreign_script")), (("ja", "ko", "en"), (ja, None)), (("zh", "en"), (None, "foreign_script"))):
            with self.subTest(languages):
                self.assertEqual(self.run_one(ja, languages=languages), expected)       # zh allows Han but not kana: this is mostly kana
        zh = "今天我们讨论了会议材料，下周再确认。"
        self.assertEqual(self.run_one(zh, languages=("zh", "en")), (zh, None))
        self.assertEqual(self.run_one(zh, languages=("ko", "en")), (None, "foreign_script"))
        self.assertEqual(self.run_one("ご視聴ありがとうございました", languages=("ja", "ko", "en")), (None, "strong_phantom"))
        self.assertEqual(self.run_one("チャンネル登録をお願いします", languages=("ja", "en"))[1], "strong_phantom")
        # ... but a language that is not in the set is still a hallucination: Cyrillic with ja,ko,en, kana with ru
        self.assertEqual(self.run_one("Продолжение следует", languages=("ja", "ko", "en")), (None, "foreign_script"))
        self.assertEqual(self.run_one("Продолжение следует", languages=("ru", "en"))[0], "Продолжение следует")
        self.assertEqual(self.run_one(ja, languages=("ru", "en"))[1], "foreign_script")

    def test_foreign_pattern_per_language_set(self):
        default = asr.foreign_pattern(("ko", "en"))
        for ch in ("あ", "カ", "漢", "Ж", "ش", "ไ", "ह"):
            self.assertIsNotNone(default.search(ch), ch)
        self.assertIsNone(default.search("한글 text 123"))
        self.assertIsNone(asr.foreign_pattern(("ja",)).search("かな漢字カナ"))
        self.assertIsNotNone(asr.foreign_pattern(("ja",)).search("Ж"))
        self.assertIsNone(asr.foreign_pattern(("ja", "ru", "ar", "th", "hi")))

    def test_numeric_digits_are_not_collapsed(self):
        for text in ("가격은 10000 달러, 1,000,000 원이고", "Revenue was 1,000,000 or 10000 or 0.0.0.0 dollars", "The code is 1111 and 2222222",
                     "$100,000,000 in three tranches", "version 3.3.3.3 is out", "1 1 1 1 1 1 is a sequence of numbers"):
            with self.subTest(text):
                kept, _ = asr.postfilter([seg(0, 4, text)])
                self.assertEqual(kept[0].text, text)
                self.assertFalse(kept[0].loop)

    def test_word_loops_are_collapsed(self):
        cases = [("아, 아, 아, 아, 아, 아", "아"), ("yes yes yes yes yes", "yes"), ("so, so, so, so, then we go", "so, then we go"),
                 ("감사합니다 감사합니다 감사합니다 감사합니다", "감사합니다")]
        for text, expected in cases:
            with self.subTest(text):
                kept, _ = asr.postfilter([seg(0, 4, text)])
                self.assertEqual(kept[0].text, expected)
                self.assertTrue(kept[0].loop)

    def test_collapse_keeps_digits_inside_a_looping_sentence(self):
        self.assertEqual(asr.collapse_loops("가격은 10000 달러 달러 달러 달러 입니다"), "가격은 10000 달러 입니다")

    def test_prompt_echo_is_dropped(self):
        prompt = "A medical AI meeting. Terms: Acme, AcmeScan-CXR, FDA, Pre-Sub, HIPAA"
        self.assertEqual(self.run_one("Acme AcmeScan CXR FDA Pre Sub HIPAA", prompt=prompt)[1], "prompt_echo")
        self.assertEqual(self.run_one("We talked about the FDA", prompt=prompt)[1], None)           # < 5 words
        self.assertEqual(self.run_one("We talked about the FDA and HIPAA yesterday", prompt=prompt)[1], None)

    def test_a_segment_without_a_letter_or_digit_is_no_content(self):
        """Whisper can produce a segment whose text is just '!': no letter and no digit is no content."""
        for text in ("!", "?!", "...", "…", " - ", "♪ ♪", "。", "¿?", "( )", "!!!"):
            with self.subTest(text):
                self.assertEqual(self.run_one(text), (None, "no-content"))
                self.assertEqual(self.run_one(text, lp=-0.1, ns=0.0, dur=0.5, others=60.0), (None, "no-content"))      # whatever the confidence
        for text in ("OK!", "네.", "7", "3.5%", "a", "가", "-5", "?!5"):
            with self.subTest(text):
                self.assertEqual(self.run_one(text, others=60.0), (text, None))
        reason = asr.postfilter([seg(0, 1, "!")])[1][0][1]
        self.assertTrue(reason.startswith("no-content"), reason)

    PROMPT = "A medical AI meeting. Terms: Acme, AcmeScan-CXR, FDA, Pre-Sub, HIPAA"

    def test_a_lone_vocabulary_term_is_prompt_echo_only_when_the_decoder_is_unsure(self):
        """A lone 'Acme' next to Remote speech (SPEC 13.2 prompt echo, one-word case). A clearly spoken one is a real answer."""
        def lone(text, **kw):
            return self.run_one(text, dur=0.9, prompt=self.PROMPT, others=60.0, **kw)
        for text in ("Acme", "Acme.", "FDA", "HIPAA?", "Pre-Sub"):
            with self.subTest(text):
                self.assertEqual(lone(text, lp=-0.2, ns=0.02), (text, None))                       # spoken clearly: kept
                self.assertEqual(lone(text, lp=-0.7, ns=0.4), (text, None))                        # middling numbers: kept
                self.assertEqual(lone(text, lp=-0.95, ns=0.1), (None, "prompt_echo"))               # the decoder doubts the words
                self.assertEqual(lone(text, lp=-0.3, ns=0.6), (None, "prompt_echo"))                # ... or that there was speech at all
        self.assertEqual(lone("acme", lp=-0.95, ns=0.1), (None, "prompt_echo"))                  # case does not matter
        # not a vocabulary term, not alone, no prompt, no confidence numbers: untouched
        for text in ("meeting", "medical", "Okay", "Acme FDA", "Acme is great"):
            with self.subTest(text):
                self.assertEqual(lone(text, lp=-0.95, ns=0.1), (text, None))
        self.assertEqual(self.run_one("Acme", lp=-0.95, ns=0.1, dur=0.9, others=60.0), ("Acme", None))      # no prompt
        s = asr.Seg(0, 1, "Acme", "en", None, None, None)
        self.assertEqual(len(asr.postfilter([s], prompt=self.PROMPT)[0]), 1)

    def test_missing_confidence_numbers_skip_numeric_checks(self):
        s = asr.Seg(0, 3, "Hello there everyone", "en", None, None, None)
        kept, dropped = asr.postfilter([s])
        self.assertEqual((len(kept), len(dropped)), (1, 0))
        s = asr.Seg(0, 3, "Thanks for watching", "en", None, None, None)
        self.assertEqual(len(asr.postfilter([s])[1]), 1)

    def test_empty_text_after_collapse_is_not_kept_and_low_conf_flag(self):
        kept, _ = asr.postfilter([seg(0, 3, "ok fine", lp=-1.2)])
        self.assertTrue(kept[0].low_conf)
        kept, _ = asr.postfilter([seg(0, 3, "   ")])
        self.assertEqual(kept, [])


# ---------------------------------------------------------------------------------------
# prompt budget
# ---------------------------------------------------------------------------------------
class PromptBudgetTest(unittest.TestCase):
    def test_with_whitespace_tokenizer(self):
        vocab = parse_vocab_text("\n".join(f"Term{i}" for i in range(50)))
        p = asr.build_asr_prompt(vocab, SpaceTokenizer(), max_tokens=10)
        self.assertEqual(len(p.replace(",", "").split()), 10)
        self.assertTrue(p.endswith("Term0"), p)                    # most important term LAST
        self.assertEqual(asr.build_asr_prompt(Vocab(), SpaceTokenizer(), 100), "")
        self.assertEqual(asr.build_asr_prompt(vocab, SpaceTokenizer(), 0), "")

    def test_frames_and_bare_list(self):
        vocab = parse_vocab_text("Acme\nFDA")
        ko = asr.build_asr_prompt(vocab, SpaceTokenizer(), 100, language="ko", frames=WhisperEngine.prompt_frames)
        en = asr.build_asr_prompt(vocab, SpaceTokenizer(), 100, language="en", frames=WhisperEngine.prompt_frames)
        other = asr.build_asr_prompt(vocab, SpaceTokenizer(), 100, language="ja", frames=WhisperEngine.prompt_frames)
        bare = asr.build_asr_prompt(vocab, SpaceTokenizer(), 100)
        self.assertEqual(ko, "다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: FDA, Acme")
        self.assertEqual(en, "A medical AI meeting. Terms: FDA, Acme")
        self.assertEqual(other, "FDA, Acme")                    # SPEC 15: a language without a frame gets the bare term list
        self.assertEqual(bare, "FDA, Acme")
        for lang in ("ja", "zh", "de", "xx"):
            self.assertEqual(asr.build_asr_prompt(vocab, SpaceTokenizer(), 100, language=lang, frames=WhisperEngine.prompt_frames), bare)
        self.assertEqual(asr.build_asr_prompt(vocab, SpaceTokenizer(), 3, language="en", frames=WhisperEngine.prompt_frames), "")  # frame alone too long

    @needs_mlx_whisper
    def test_budget_is_respected_with_the_real_whisper_tokenizer(self):
        tok = WhisperEngine(TINY).tokenizer
        default_vocab = parse_vocab_text((ROOT / "config" / "vocabulary.txt").read_text(encoding="utf-8"))
        big = parse_vocab_text("\n".join(["Acme", "AcmeScan-CXR", "510(k)", "애크미"] + [f"Hospital Name {i} (Fabrikam-Health{i})" for i in range(300)]))
        for vocab in (default_vocab, big, VOCAB):
            for limit in (20, 60, 100, 120, 200):
                for lang in (None, "ko", "en"):
                    with self.subTest(vocab=len(vocab.terms), limit=limit, lang=lang):
                        p = asr.build_asr_prompt(vocab, tok, limit, language=lang, frames=WhisperEngine.prompt_frames)
                        self.assertLessEqual(len(tok.encode(" " + p.strip())), limit)
                        if p and lang is None:
                            self.assertTrue(p.endswith(vocab.terms[0]) or vocab.terms[0] not in p, "top priority term must come last")

    @needs_mlx_whisper
    def test_default_production_budget_keeps_the_top_priority_terms(self):
        tok = WhisperEngine(TINY).tokenizer
        vocab = parse_vocab_text((ROOT / "config" / "vocabulary.txt").read_text(encoding="utf-8"))
        for lang in ("ko", "en"):
            p = asr.build_asr_prompt(vocab, tok, asr.ASR_PROMPT_TOKENS, language=lang, frames=WhisperEngine.prompt_frames)
            self.assertLessEqual(len(tok.encode(" " + p)), asr.ASR_PROMPT_TOKENS)
            self.assertLess(asr.ASR_PROMPT_TOKENS, 223)  # Whisper keeps only the last 223 prompt tokens
            for term in vocab.terms[:12]:
                self.assertIn(term, p)
            self.assertTrue(p.endswith(vocab.terms[0]))
            # a smaller budget cut the terms at the end of a long list; the production budget must keep
            # every term of the shipped seed.
            for term in vocab.terms:
                self.assertIn(term, p, f"{term!r} no longer fits the production prompt budget ({lang}): raise ASR_PROMPT_TOKENS")

    @needs_mlx_whisper
    def test_empty_prompt_is_never_sent_as_empty_string(self):
        """build_asr_prompt returns "" for 'no prompt'; the track code must turn that into None for the model."""
        engine = FakeEngine()
        x = np.zeros(SR * 10, np.float32)
        asr.transcribe_track(x, engine, cfg(), Vocab(), language="en", vad=vad_result([(1.0, 5.0)], 10))
        self.assertEqual([c[2] for c in engine.calls], [None])


# ---------------------------------------------------------------------------------------
# chunk loop
# ---------------------------------------------------------------------------------------
class TrackLoopTest(unittest.TestCase):
    REGIONS = [(1.0, 5.0), (6.0, 9.0), (40.0, 45.0), (80.0, 83.0)]

    def run_track(self, engine, regions=None, total=100.0, **kw):
        progress = []
        kw.setdefault("language", "en")
        res = asr.transcribe_track(np.zeros(int(total * SR), np.float32), engine, cfg(), VOCAB, track="remote",
                                   vad=vad_result(self.REGIONS if regions is None else regions, total), progress=progress.append, **kw)
        return res, progress

    def test_one_call_per_chunk_with_the_prompt_every_time_and_absolute_times(self):
        engine = FakeEngine()
        res, progress = self.run_track(engine)
        chunks = vad.plan_chunks(self.REGIONS, vad_result(self.REGIONS, 100).db, 100.0, labels=["en"] * 4)
        self.assertEqual(len(chunks), 3)
        self.assertEqual(len(engine.calls), 3)
        for (a, b, _), (n, lang, prompt) in zip(chunks, engine.calls):
            self.assertEqual(n, int(b * SR) - int(a * SR))
            self.assertEqual(lang, "en")
            self.assertTrue(prompt and prompt.startswith("A medical AI meeting. Terms: "))
        self.assertEqual(len(res.segments), 3)
        for (a, b, _), s in zip(chunks, res.segments):
            self.assertAlmostEqual(s["start"], a + 0.2, places=2)
            self.assertAlmostEqual(s["end"], b - 0.2, places=2)
        self.assertEqual(progress, ["detecting speech remote", "transcribing remote 1/3", "transcribing remote 2/3", "transcribing remote 3/3"])
        self.assertEqual(res.language, "en")
        self.assertEqual(res.info["chunks"], 3)
        self.assertEqual(engine.loaded, 1)

    def test_decoder_times_past_the_chunk_end_are_clamped(self):
        def script(audio, language, prompt, i):
            return {"text": "x", "avg_logprob": -0.2, "segments": [
                {"start": 0.0, "end": 500.0, "text": "runs long", "avg_logprob": -0.2, "no_speech_prob": 0.0, "compression_ratio": 1.0},
                {"start": 400.0, "end": 410.0, "text": "entirely past the end", "avg_logprob": -0.2, "no_speech_prob": 0.0, "compression_ratio": 1.0}]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 20.0)])
        self.assertEqual(len(res.segments), 1)
        self.assertAlmostEqual(res.segments[0]["end"], 20.3, places=2)

    def test_retry_without_prompt_is_used_only_when_clearly_better(self):
        prompts_seen = []

        def script(audio, language, prompt, i):
            prompts_seen.append(prompt)
            if prompt:   # first attempt: loops
                return {"text": "", "avg_logprob": -0.4, "segments": [
                    {"start": 0, "end": 3, "text": "foo foo foo foo", "avg_logprob": -0.4, "no_speech_prob": 0.0, "compression_ratio": 3.5}]}
            return {"text": "", "avg_logprob": -0.2, "segments": [
                {"start": 0, "end": 3, "text": "a clean retry", "avg_logprob": -0.2, "no_speech_prob": 0.0, "compression_ratio": 1.1}]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 14.0)])
        self.assertEqual([s["text"] for s in res.segments], ["a clean retry"])
        self.assertEqual((res.info["prompt_retries"], res.info["retries_accepted"]), (1, 1))
        self.assertTrue(prompts_seen[0] and prompts_seen[1] is None)

    def test_retry_that_is_not_better_is_discarded(self):
        def script(audio, language, prompt, i):
            lp = -1.2 if prompt else -1.25                   # both poor, the retry is not better by 0.1
            return {"text": "", "avg_logprob": lp, "segments": [
                {"start": 0, "end": 3, "text": "mumbled words here", "avg_logprob": lp, "no_speech_prob": 0.0, "compression_ratio": 1.1}]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 14.0)])
        self.assertEqual((res.info["prompt_retries"], res.info.get("retries_accepted", 0)), (1, 0))
        self.assertEqual(len(res.segments), 1)

    def test_retry_that_loops_is_discarded_and_prompt_echo_triggers_a_retry(self):
        def script(audio, language, prompt, i):
            if prompt:
                return {"text": "", "avg_logprob": -0.5, "segments": [
                    {"start": 0, "end": 3, "text": "Acme AcmeScan CXR FDA Pre Sub HIPAA", "avg_logprob": -0.5, "no_speech_prob": 0.0, "compression_ratio": 1.2}]}
            return {"text": "", "avg_logprob": -0.1, "segments": [
                {"start": 0, "end": 3, "text": "loop loop loop", "avg_logprob": -0.1, "no_speech_prob": 0.0, "compression_ratio": 2.9}]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 14.0)])
        self.assertEqual(res.info["prompt_retries"], 1)
        self.assertEqual(res.info.get("retries_accepted", 0), 0)
        self.assertEqual(len(res.segments), 0)                          # the echoed original is then removed by the post-filter
        self.assertEqual(res.dropped_by_reason, {"prompt_echo": 1})

    def test_no_retry_when_there_is_no_prompt(self):
        engine = FakeEngine(lambda a, l, p, i: {"text": "", "avg_logprob": -1.3, "segments": [
            {"start": 0, "end": 3, "text": "poor but fine", "avg_logprob": -1.3, "no_speech_prob": 0.0, "compression_ratio": 1.0}]})
        res, _ = self.run_track(engine, regions=[(10.0, 14.0)], prompt_style="none")
        self.assertEqual(len(engine.calls), 1)
        self.assertEqual(engine.calls[0][2], None)

    def test_dropped_segments_are_counted_with_reasons(self):
        def script(audio, language, prompt, i):
            texts = [("Thanks for watching!", -0.2, 1.1), ("The FDA decision is due in March.", -0.3, 1.1), ("noise noise noise", -0.3, 2.8)]
            return {"text": "", "avg_logprob": -0.3, "segments": [
                {"start": k, "end": k + 0.9, "text": t, "avg_logprob": lp, "no_speech_prob": 0.0, "compression_ratio": cr} for k, (t, lp, cr) in enumerate(texts)]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 14.0)])
        self.assertEqual([s["text"] for s in res.segments], ["The FDA decision is due in March."])
        self.assertEqual(len(res.dropped), 2)
        self.assertEqual(res.dropped_by_reason, {"strong_phantom": 1, "compression_ratio": 1})
        self.assertEqual(res.info["dropped"], 2)

    def test_punctuation_only_and_prompt_echo_fragments_are_dropped_and_counted(self):
        def script(audio, language, prompt, i):
            texts = [("!", -0.5, 0.1), ("We will submit the 510(k) next week.", -0.3, 0.01), ("Acme", -0.95, 0.5), ("Acme", -0.2, 0.02)]
            return {"text": "", "avg_logprob": -0.3, "segments": [
                {"start": k, "end": k + 0.9, "text": t, "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": 1.1}
                for k, (t, lp, ns) in enumerate(texts)]}
        res, _ = self.run_track(FakeEngine(script), regions=[(10.0, 14.0)])
        self.assertEqual([s["text"] for s in res.segments], ["We will submit the 510(k) next week.", "Acme"])       # the clear one stays
        self.assertEqual(res.dropped_by_reason, {"no-content": 1, "prompt_echo": 1})
        self.assertEqual(res.info["dropped"], 2)
        self.assertEqual(sorted(d["text"] for d in res.dropped), ["!", "Acme"])

    def test_chunk_failures_are_survivable_but_total_failure_is_not(self):
        def flaky(audio, language, prompt, i):
            if i == 1:
                raise RuntimeError("metal hiccup")
            return FakeEngine.default_script(audio, language, prompt, i)
        res, _ = self.run_track(FakeEngine(flaky))
        self.assertEqual(len(res.segments), 2)
        self.assertEqual(res.info["failed_chunks"], 1)

        def broken(audio, language, prompt, i):
            raise ValueError("Unsupported language: xx")
        with self.assertRaisesRegex(RuntimeError, "every chunk"):
            self.run_track(FakeEngine(broken))

    def test_silent_track_does_not_load_the_model(self):
        engine = FakeEngine()
        res, _ = self.run_track(engine, regions=[])
        self.assertEqual((res.segments, res.language, engine.loaded, engine.calls), ([], None, 0, []))

    def test_forced_language_skips_language_id(self):
        engine = FakeEngine()
        res, _ = self.run_track(engine, language="ko")
        self.assertEqual(engine.lid_calls, [])
        self.assertEqual({c[1] for c in engine.calls}, {"ko"})
        self.assertTrue(all(c[2].startswith("다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: ") for c in engine.calls))
        self.assertEqual(res.language, "ko")

    def test_transcribe_array_none_means_auto_and_forced_codes_pass_through(self):
        regions = [(1.0, 6.0), (7.0, 12.0)]
        for language, expect_lid, expected in ((None, True, "en"), ("auto", True, "en"), ("ko", False, "ko")):
            with self.subTest(language=language):
                engine = FakeEngine()
                audio = np.zeros(20 * SR, np.float32)
                with mock.patch.object(asr, "get_engine", return_value=engine), \
                        mock.patch.object(vad, "detect_speech", return_value=vad_result(regions, 20.0)):
                    segs = asr.transcribe_array(audio, cfg(asr_language="ko"), VOCAB, language=language)
                self.assertEqual(bool(engine.lid_calls), expect_lid)
                self.assertEqual({s["lang"] for s in segs}, {expected})
                self.assertTrue(all(set(s) == {"start", "end", "lang", "text", "avg_logprob", "no_speech_prob"} for s in segs))

    def test_config_language_is_the_default(self):
        engine = FakeEngine()
        asr.transcribe_track(np.zeros(100 * SR, np.float32), engine, cfg(asr_language="ko"), VOCAB, vad=vad_result(self.REGIONS, 100))
        self.assertEqual({c[1] for c in engine.calls}, {"ko"})
        self.assertEqual(engine.lid_calls, [])

    def test_auto_language_uses_region_labels_and_per_language_prompts(self):
        regions = [(1.0, 6.0), (7.0, 12.0), (13.0, 18.0)]
        langs = {0: "ko", 1: "en", 2: "en"}
        probs = iter([0, 1, 2])

        def lid(clip):
            k = next(probs)
            return {"ko": 0.97, "en": 0.03, "top": "ko"} if langs[k] == "ko" else {"ko": 0.02, "en": 0.98, "top": "en"}
        engine = FakeEngine(lid=lid)
        res, _ = self.run_track(engine, regions=regions, total=20.0, language="auto")
        self.assertEqual([c[1] for c in engine.calls], ["ko", "en"])
        self.assertIn("다음은 한국어와", engine.calls[0][2])
        self.assertTrue(engine.calls[1][2].startswith("A medical AI meeting"))
        self.assertEqual([s["lang"] for s in res.segments], ["ko", "en"])
        self.assertEqual(res.info["language_switches"], 1)

    def test_engine_without_language_id_gets_none(self):
        engine = FakeEngine(supports_lid=False)
        engine.prompt_frames = {"ko": "Technical terms: ", "en": "Technical terms: "}
        res, _ = self.run_track(engine, language="auto")
        self.assertEqual({c[1] for c in engine.calls}, {None})
        self.assertTrue(all(c[2].startswith("Technical terms: ") for c in engine.calls))
        self.assertEqual(engine.lid_calls, [])

    def test_prompt_token_budget_is_a_parameter(self):
        vocab = parse_vocab_text("\n".join(f"Term{i}" for i in range(40)))
        for budget in (12, 30):
            engine = FakeEngine()
            self.run_track(engine, regions=[(10.0, 14.0)], prompt_style="list", prompt_tokens=budget)
            self.assertLessEqual(len(engine.calls[0][2].replace(",", "").split()), budget)
        small, large = FakeEngine(), FakeEngine()
        asr.transcribe_track(np.zeros(20 * SR, np.float32), small, cfg(), vocab, language="en", prompt_tokens=8, vad=vad_result([(1.0, 5.0)], 20))
        asr.transcribe_track(np.zeros(20 * SR, np.float32), large, cfg(), vocab, language="en", prompt_tokens=20, vad=vad_result([(1.0, 5.0)], 20))
        self.assertLess(len(small.calls[0][2].split()), len(large.calls[0][2].split()))

    def test_prompt_styles(self):
        for style, expected in (("none", None), ("list", "Acme"), ("frame+list", "Terms: ")):
            with self.subTest(style):
                engine = FakeEngine()
                self.run_track(engine, regions=[(10.0, 14.0)], prompt_style=style)
                prompt = engine.calls[0][2]
                if expected is None:
                    self.assertIsNone(prompt)
                else:
                    self.assertIn(expected, prompt)
                if style == "list":
                    self.assertNotIn("meeting", prompt)
        with self.assertRaises(ValueError):
            self.run_track(FakeEngine(), prompt_style="bogus")

    def test_aliases_are_applied_to_the_final_text(self):
        engine = FakeEngine(lambda a, l, p, i: {"text": "", "avg_logprob": -0.2, "segments": [
            {"start": 0, "end": 3, "text": "애크미은 FDA와 이야기했고 액미 팀도 참석했습니다", "avg_logprob": -0.2, "no_speech_prob": 0.0, "compression_ratio": 1.1}]})
        res, _ = self.run_track(engine, regions=[(10.0, 14.0)], language="ko")
        self.assertEqual(res.segments[0]["text"], "Acme은 FDA와 이야기했고 Acme 팀도 참석했습니다")

    def test_energy_vad_is_used_when_no_vad_result_is_given(self):
        x = np.zeros(20 * SR, np.float32) + 1e-4
        t = np.arange(5 * SR) / SR
        x[3 * SR: 8 * SR] += (0.2 * np.sin(2 * np.pi * 300 * t) * (1 + np.sin(2 * np.pi * 4 * t)) / 2).astype(np.float32)
        engine = FakeEngine()
        res = asr.transcribe_track(x, engine, cfg(asr_vad="energy"), VOCAB, language="en")
        self.assertEqual(res.info["vad"], "energy")
        self.assertEqual(len(res.segments), 1)
        self.assertTrue(2.5 < res.segments[0]["start"] < 4.0)


class TrackPolicyTest(unittest.TestCase):
    """SPEC 15 / review_transcribe wiring: ASR_LANGUAGES, short answers, degraded VAD."""

    @staticmethod
    def say(text, lp=-0.25, ns=0.02):
        return lambda audio, language, prompt, i: {"text": text, "language": language, "avg_logprob": lp, "segments": [
            {"start": 0.0, "end": len(audio) / SR, "text": text, "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": 1.1}]}

    def test_asr_languages_reaches_the_language_id_the_prompts_and_the_script_filter(self):
        spec = [(1, 6, 0.10), (7, 12, 0.30), (13, 18, 0.30), (19, 24, 0.10), (25, 30, 0.20)]
        x, regions = lid_track(spec, total=40.0)

        def script(audio, language, prompt, i):
            text = {"ko": "다음 주에 미팅을 잡겠습니다.", "ja": "今日は会議の資料を確認しました。", "en": "Let's review the timeline."}[language]
            return self.say(text)(audio, language, prompt, i)
        engine = FakeEngine(script, lid=lid_by_level)
        res = asr.transcribe_track(x, engine, cfg(asr_languages="ja, ko ,en"), VOCAB, track="mic", language="auto", vad=vad_result(regions, 40.0))
        self.assertEqual(engine.lid_languages, [("ja", "ko", "en")])
        self.assertEqual([c[1] for c in engine.calls], ["ko", "ja", "ko", "en"])              # the two Japanese regions form one chunk
        prompts = {c[1]: c[2] for c in engine.calls}
        self.assertTrue(prompts["ko"].startswith("다음은 한국어와"))
        self.assertTrue(prompts["en"].startswith("A medical AI meeting. Terms: "))
        self.assertNotIn("meeting", prompts["ja"].lower())                                       # no frame for ja: the bare term list
        self.assertTrue(prompts["ja"].startswith("Pre-Sub") or "Acme" in prompts["ja"])
        self.assertEqual([s["lang"] for s in res.segments], ["ko", "ja", "ko", "en"])
        self.assertEqual(res.dropped, [])                                                         # Japanese text is not a "foreign script" here
        self.assertEqual(res.info["languages"], ["ja", "ko", "en"])

    def test_without_ja_in_the_set_japanese_text_is_dropped_but_a_forced_language_is_never_foreign(self):
        x, regions = lid_track([(1, 6, 0.10)], total=20.0)
        engine = FakeEngine(self.say("今日は会議の資料を確認しました。"), lid=lid_by_level)
        res = asr.transcribe_track(x, engine, cfg(), VOCAB, track="mic", language="auto", vad=vad_result(regions, 20.0))
        self.assertEqual((res.segments, res.dropped_by_reason), ([], {"foreign_script": 1}))
        engine = FakeEngine(self.say("今日は会議の資料を確認しました。"))
        res = asr.transcribe_track(x, engine, cfg(), VOCAB, track="mic", language="ja", vad=vad_result(regions, 20.0))
        self.assertEqual([s["text"] for s in res.segments], ["今日は会議の資料を確認しました。"])      # ASR_LANGUAGE=ja: its script is allowed
        self.assertEqual({c[1] for c in engine.calls}, {"ja"})
        self.assertNotIn("meeting", engine.calls[0][2].lower())

    def test_unknown_language_codes_fail_early_with_a_clear_error(self):
        engine = FakeEngine()
        x, regions = lid_track([(1, 6, 0.10)], total=20.0)
        with self.assertRaisesRegex(ValueError, r"ASR_LANGUAGES: unknown language code 'jp'"):
            asr.transcribe_track(x, engine, cfg(asr_languages="ko,jp"), VOCAB, track="mic", vad=vad_result(regions, 20.0))
        self.assertEqual((engine.calls, engine.loaded), ([], 0))                                 # nothing was started
        prepared = audioprep.PreparedAudio({t: np.zeros(10 * SR, np.float32) for t in ("mic", "remote")}, SR, 10.0, {})
        with mock.patch.object(asr, "get_engine", return_value=engine) as ge, mock.patch("mcap.aec.cancel_echo") as aec_call:
            with self.assertRaisesRegex(ValueError, "ASR_LANGUAGES"):
                asr.transcribe_tracks(prepared, cfg(asr_languages="korean"), VOCAB)
        ge.assert_not_called()
        aec_call.assert_not_called()                                                              # before any heavy work

    def test_a_single_language_set_never_runs_language_id(self):
        engine = FakeEngine(self.say("다음 주에 미팅을 잡겠습니다."), lid=lid_by_level)
        x, regions = lid_track(long_regions([0.20] * 3), total=20.0)
        res = asr.transcribe_track(x, engine, cfg(asr_languages="ko"), VOCAB, track="mic", language="auto", vad=vad_result(regions, 20.0))
        self.assertEqual(engine.lid_calls, [])
        self.assertEqual({c[1] for c in engine.calls}, {"ko"})

    def test_a_lone_short_answer_reaches_whisper_when_silero_is_sure_and_survives_the_filter(self):
        """review: '네.' (0.22 s) gave a Silero region of 0.29 s and 0 chunks; a real short answer was lost, and 'weak phantom'
        filtering would have removed it at lp -0.7 / ns 0.35 anyway."""
        regions = [(5.0, 5.3), (20.0, 26.0)]
        calls = []

        def script(audio, language, prompt, i):
            calls.append(len(audio) / SR)
            if len(audio) / SR < 2.0:
                return self.say("네", lp=-0.7, ns=0.35)(audio, language, prompt, i)
            return self.say("다음 주에 미팅을 잡겠습니다.")(audio, language, prompt, i)
        engine = FakeEngine(script)
        x = np.zeros(30 * SR, np.float32)
        res = asr.transcribe_track(x, engine, cfg(), VOCAB, track="mic", language="ko", vad=vad_result(regions, 30.0, probs=[0.93, 0.95]))
        self.assertEqual([s["text"] for s in res.segments], ["네", "다음 주에 미팅을 잡겠습니다."])
        self.assertAlmostEqual(calls[0], 0.9, places=2)                                           # 0.3 s of speech + 0.3 s padding each side
        # the energy VAD has no probabilities: the lone 0.3 s region is dropped like before
        engine = FakeEngine(script)
        res = asr.transcribe_track(x, engine, cfg(), VOCAB, track="mic", language="ko", vad=vad_result(regions, 30.0))
        self.assertEqual([s["text"] for s in res.segments], ["다음 주에 미팅을 잡겠습니다."])

    def test_a_confident_phantom_word_in_a_silent_track_is_still_dropped(self):
        engine = FakeEngine(self.say("Thank you.", lp=-0.9, ns=0.2))
        x = np.zeros(30 * SR, np.float32)
        res = asr.transcribe_track(x, engine, cfg(), VOCAB, track="mic", language="en", vad=vad_result([(5.0, 7.0)], 30.0))
        self.assertEqual((res.segments, res.dropped_by_reason), ([], {"weak_phantom": 1}))

    def test_degraded_vad_is_recorded_in_the_transcript_stats(self):
        prepared = TranscribeTracksTest.prepared(TranscribeTracksTest())
        with mock.patch.dict(os.environ):
            os.environ.pop("MCAP_SILERO_MODEL", None)
            for mode, label, degraded in (("auto", "energy (silero unavailable: ", True), ("energy", "energy", False)):
                with self.subTest(mode):
                    with mock.patch.object(asr, "get_engine", return_value=FakeEngine()), self.assertLogs("mcap.vad", "WARNING") if degraded else mock.MagicMock():
                        out = asr.transcribe_tracks(prepared, cfg(asr_vad=mode, asr_language="en", mic_aec="0"), VOCAB)
                    for track in ("mic", "remote"):
                        info = out["stats"][track]
                        if degraded:
                            self.assertTrue(info["vad"].startswith(label), info["vad"])
                            self.assertIn("Silero model not found", info["vad"])
                            self.assertEqual(info["vad_degraded"], info["vad"][len(label):-1])
                        else:
                            self.assertEqual(info["vad"], label)
                            self.assertNotIn("vad_degraded", info)
                    json.dumps(out, ensure_ascii=False)
                    self.assertEqual(tr.validate_transcript(out), [])


# ---------------------------------------------------------------------------------------
# language id per region
# ---------------------------------------------------------------------------------------
LEVELS = {            # region audio level -> what the fake language-ID backend says about a clip of it (full-model probabilities)
    0.10: {"ko": 0.99, "en": 0.01},
    0.11: {"ko": 0.97, "en": 0.03},
    0.20: {"ko": 0.01, "en": 0.99},
    0.21: {"ko": 0.03, "en": 0.97},
    0.22: {"ko": 0.10, "en": 0.90},                 # unsure English (p_en 0.90 -> still switches at >= 2.5 s, not at 1-2.5 s)
    0.23: {"ko": 0.12, "en": 0.88},                 # p_en 0.88: not enough to leave Korean
    0.30: {"ja": 0.97, "ko": 0.02, "en": 0.01},
    0.40: {"ja": 0.70, "ko": 0.20, "en": 0.10},     # model thinks Japanese, but Japanese is not in ko,en: renormalised -> ko 0.67
}


def lid_by_level(clip):
    return dict(LEVELS[round(float(np.abs(clip).max()), 2)])


def lid_track(spec, total=None):
    """spec = [(start_s, end_s, level)] -> (audio with every region filled with its level, regions)."""
    total = total or spec[-1][1] + 5
    x = np.zeros(int(total * SR), np.float32)
    for a, b, v in spec:
        x[int(a * SR): int(b * SR)] = v
    return x, [(a, b) for a, b, _ in spec]


def long_regions(levels, length=4.0, gap=1.0):
    """One region per level, back to back."""
    return [(i * (length + gap), i * (length + gap) + length, v) for i, v in enumerate(levels)]


class RegionLanguagesTest(unittest.TestCase):
    def run_it(self, spec, languages=("ko", "en"), **kw):
        engine = FakeEngine(lid=lid_by_level)
        x, regions = lid_track(spec)
        track, labels, info = asr.region_languages(engine, x, regions, languages, **kw)
        return track, labels, info, engine

    def test_monolingual_fast_path_probes_at_most_sixteen_regions_and_only_when_all_agree(self):
        track, labels, info, engine = self.run_it(long_regions([0.10] * 40))
        self.assertEqual((track, set(labels), info["monolingual_fast_path"]), ("ko", {"ko"}, True))
        self.assertEqual(engine.lid_calls, [16])                          # SPEC 15: up to 16 probes, one batched call
        self.assertEqual(info["probes"], 16)
        track, labels, info, engine = self.run_it(long_regions([0.20] * 7))   # fewer long regions than probes: all of them are probed
        self.assertEqual((track, info["probes"], engine.lid_calls), ("en", 7, [7]))

    def test_one_dissenting_probe_switches_to_classifying_every_region(self):
        regions = long_regions([0.10] * 40)
        probe_ix = sorted({int(round(k)) for k in np.linspace(0, 39, 16)})
        levels = [0.10] * 40
        levels[probe_ix[5]] = 0.20                                              # one English region that is among the probes
        levels[2] = 0.20 if 2 not in probe_ix else 0.10                         # and one that is not
        track, labels, info, engine = self.run_it(long_regions(levels))
        self.assertFalse(info["monolingual_fast_path"])
        self.assertEqual(track, "ko")
        self.assertEqual(labels, ["en" if v == 0.20 else "ko" for v in levels])
        self.assertEqual(sum(engine.lid_calls), 40)                             # every region >= 2.5 s was classified, none twice
        self.assertEqual(info["lid_regions"], 40)

    def test_korean_track_with_ten_percent_english_regions_keeps_the_english_regions_english(self):
        """The failure the review measured: a handful of probes misses a minority language. With up to 16 probes that must all
        agree, the miss rate drops a lot (it cannot reach zero: that is what the language-ID of every region costs), and
        whenever the full path runs every English region comes out English and every Korean one Korean."""
        rng = np.random.default_rng(5)
        n, n_en, trials = 60, 6, 300
        missed = {6: 0, 16: 0}
        for _ in range(trials):
            en = set(rng.choice(n, n_en, replace=False).tolist())
            levels = [0.20 if i in en else 0.10 for i in range(n)]
            x, regions = lid_track(long_regions(levels))
            for n_probe in (6, 16):
                engine = FakeEngine(lid=lid_by_level)
                track, labels, info = asr.region_languages(engine, x, regions, n_probe=n_probe)
                if info["monolingual_fast_path"]:
                    missed[n_probe] += 1
                else:
                    self.assertEqual([i for i, lab in enumerate(labels) if lab == "en"], sorted(en))
        self.assertLess(missed[16], missed[6] * 0.55, missed)
        self.assertLess(missed[16] / trials, 0.30, missed)                       # 10 % minority: (0.9)^16 = 18 % in theory

    def test_known_english_regions_among_the_probes_are_always_found(self):
        """Deterministic variant of the above with ~10 % English regions (5 of 50) of which two sit on probe positions."""
        probe_ix = sorted({int(round(k)) for k in np.linspace(0, 49, 16)})
        en = {probe_ix[3], probe_ix[9], 1, 17, 40}
        levels = [0.20 if i in en else 0.10 for i in range(50)]
        track, labels, info, _ = self.run_it(long_regions(levels))
        self.assertFalse(info["monolingual_fast_path"])
        self.assertEqual([i for i, lab in enumerate(labels) if lab == "en"], sorted(en))
        self.assertEqual(info["language_switches"], sum(1 for a, b in zip(levels, levels[1:]) if a != b))

    def test_flip_needs_p_0_90_for_regions_of_2_5_seconds_and_more(self):
        spec = long_regions([0.10, 0.10, 0.22, 0.10, 0.23, 0.10, 0.20])
        track, labels, info, _ = self.run_it(spec)
        self.assertEqual(track, "ko")
        self.assertEqual(labels, ["ko", "ko", "en", "ko", "ko", "ko", "en"])      # p_en 0.90 flips, 0.88 does not (and inherits Korean)

    def test_short_regions_weak_labels_and_inheritance(self):
        # Korean ... a 1.5 s confident English answer ... Korean ... a 1.5 s unsure one ... a 0.6 s one ... Korean
        spec = [(0, 5, 0.10), (6, 7.5, 0.20), (8.5, 13.5, 0.10), (14.5, 16.0, 0.22), (17, 17.6, 0.20), (18.6, 23.6, 0.10), (24.6, 29.6, 0.20)]
        track, labels, info, engine = self.run_it(spec)
        self.assertEqual(labels[0], "ko")
        self.assertEqual(labels[1], "en")             # 1.5 s, p_en 0.99 >= 0.95: confident, switches
        self.assertEqual(labels[2], "ko")
        self.assertEqual(labels[3], "ko")             # 1.5 s, p_en 0.90 < 0.95: inherits (both neighbours are Korean)
        self.assertEqual(labels[4], "ko")             # 0.6 s: never classified, inherits
        self.assertEqual(labels[6], "en")
        self.assertEqual(sum(engine.lid_calls), 6)    # the 0.6 s region never reaches the language ID
        self.assertEqual(info["weak_regions"], 2)

    def test_an_undecided_region_between_different_neighbours_takes_the_nearer_one(self):
        # en | 0.6 s region 0.1 s after the English one, 2.5 s before the Korean one | ko
        spec = [(0, 5, 0.20), (5.1, 5.7, 0.10), (8.2, 13.2, 0.10), (14, 19, 0.20), (20, 25, 0.20), (26, 31, 0.10), (32, 37, 0.10)]
        track, labels, info, _ = self.run_it(spec)
        self.assertEqual(labels[0], "en")
        self.assertEqual(labels[1], "en")             # nearer to the English neighbour
        self.assertEqual(labels[2], "ko")
        spec = [(0, 5, 0.20), (7.4, 8.0, 0.10), (8.1, 13.1, 0.10), (14, 19, 0.20), (20, 25, 0.20), (26, 31, 0.10), (32, 37, 0.10)]
        labels = self.run_it(spec)[1]
        self.assertEqual(labels[1], "ko")              # nearer to the Korean one

    def test_probabilities_are_restricted_to_the_language_set(self):
        """Japanese is the model's top choice but not allowed: renormalised over ko,en it is ko (0.67) and en (0.33)."""
        track, labels, info, engine = self.run_it(long_regions([0.40] * 5))
        self.assertEqual(engine.lid_languages, [("ko", "en")])
        self.assertEqual((track, set(labels)), ("ko", {"ko"}))
        self.assertAlmostEqual(info["track_scores"]["ko"], 0.2 / 0.3, places=3)
        self.assertEqual(set(info["track_scores"]), {"ko", "en"})

    def test_japanese_korean_english_configuration(self):
        levels = [0.10, 0.10, 0.30, 0.30, 0.10, 0.20, 0.10, 0.10, 0.30, 0.10]
        track, labels, info, engine = self.run_it(long_regions(levels), languages=("ja", "ko", "en"))
        self.assertEqual(track, "ko")
        self.assertEqual(labels, [{0.10: "ko", 0.20: "en", 0.30: "ja"}[v] for v in levels])
        self.assertTrue(all(langs == ("ja", "ko", "en") for langs in engine.lid_languages))
        self.assertEqual(set(info["track_scores"]), {"ja", "ko", "en"})
        self.assertAlmostEqual(sum(info["track_scores"].values()), 1.0, places=2)
        # Japanese is real now: a pure Japanese track is a single-language fast path
        track, labels, info, _ = self.run_it(long_regions([0.30] * 6), languages=("ja", "ko", "en"))
        self.assertEqual((track, set(labels), info["monolingual_fast_path"]), ("ja", {"ja"}, True))

    def test_a_single_language_set_needs_no_language_id(self):
        track, labels, info, engine = self.run_it(long_regions([0.20] * 5), languages=("ko",))
        self.assertEqual((track, labels, engine.lid_calls), ("ko", ["ko"] * 5, []))
        self.assertTrue(info["monolingual_fast_path"])

    def test_no_regions_and_only_short_regions(self):
        engine = FakeEngine(lid=lid_by_level)
        self.assertEqual(asr.region_languages(engine, np.zeros(SR, np.float32), [])[:2], ("ko", []))
        x, regions = lid_track([(0, 0.5, 0.20), (1.5, 2.0, 0.20), (3, 3.4, 0.20)])
        track, labels, info = asr.region_languages(FakeEngine(lid=lid_by_level), x, regions)
        self.assertEqual((track, set(labels)), ("en", {"en"}))                   # nothing long enough: the short ones are probed

    def test_a_six_hour_track_is_cheap_to_label(self):
        """~10 000 regions, a third of them weak / undecided: the neighbour inheritance must not be quadratic."""
        rng = np.random.default_rng(3)
        n = 10000
        starts = np.arange(n) * 5.0
        durs = rng.choice([0.5, 1.5, 4.0], n, p=[0.2, 0.2, 0.6])
        regions = [(float(a), float(a + d)) for a, d in zip(starts, durs)]
        calls = {"n": 0}

        def lid(clip):
            calls["n"] += 1
            en = (calls["n"] // 4) % 2 == 1                     # blocks of English among Korean (also among the first 16 probes: no shortcut)
            return {"ko": 0.02, "en": 0.98} if en else {"ko": 0.98, "en": 0.02}
        engine = FakeEngine(lid=lid)
        t0 = __import__("time").time()
        track, labels, info = asr.region_languages(engine, np.zeros(SR, np.float32), regions)
        self.assertLess(__import__("time").time() - t0, 20.0)
        self.assertEqual(len(labels), n)
        self.assertEqual(set(labels), {"ko", "en"})
        self.assertGreater(info["language_switches"], 20)

    def test_ambiguous_region_stays_in_the_track_language(self):
        track, labels, _, _ = self.run_it(long_regions([0.10, 0.10, 0.23]))
        self.assertEqual(labels, ["ko", "ko", "ko"])


class LanguageSetParsingTest(unittest.TestCase):
    def test_parse(self):
        parse = asr_engines.parse_languages
        self.assertEqual(parse("ko,en"), ("ko", "en"))
        self.assertEqual(parse(" JA , ko ;en  ko "), ("ja", "ko", "en"))          # case, separators, duplicates dropped, order kept
        self.assertEqual(parse(["en", "ko"]), ("en", "ko"))
        self.assertEqual(parse("ko"), ("ko",))
        self.assertEqual((parse(""), parse("  , "), parse(None)), (("ko", "en"),) * 3)       # empty -> the default
        self.assertEqual(parse("yue,zh"), ("yue", "zh"))

    def test_unknown_codes_are_rejected_with_a_clear_message(self):
        for spec in ("ko,xx", "korean,en", "ko,en,jp", "kor"):
            with self.subTest(spec):
                with self.assertRaises(ValueError) as cm:
                    asr_engines.parse_languages(spec)
                self.assertIn("ASR_LANGUAGES", str(cm.exception))
                self.assertIn(spec, str(cm.exception))

    def test_restrict_lid_renormalises(self):
        out = asr_engines.restrict_lid({"ja": 0.7, "ko": 0.2, "en": 0.1}, ("ko", "en"))
        self.assertEqual(set(out), {"ko", "en", "top"})
        self.assertAlmostEqual(out["ko"], 2 / 3)
        self.assertAlmostEqual(out["en"] + out["ko"], 1.0)
        self.assertEqual(out["top"], "ko")
        three = asr_engines.restrict_lid({"ja": 0.7, "ko": 0.2, "en": 0.1, "de": 0.5}, ("ja", "ko", "en"))
        self.assertEqual(three["top"], "ja")
        self.assertAlmostEqual(three["ja"] + three["ko"] + three["en"], 1.0)
        self.assertEqual(asr_engines.restrict_lid({"de": 1.0}, ("ko", "en")), {"ko": 0.5, "en": 0.5, "top": "ko"})   # no mass at all: uniform, first wins
        self.assertEqual(asr_engines.restrict_lid({"en": 0.6}, ("ko", "en"))["en"], 1.0)                            # missing code counts as 0

    def test_default_set_is_ko_en(self):
        self.assertEqual(asr_engines.LID_CANDIDATES, ("ko", "en"))
        self.assertEqual(Config().asr_languages, "ko,en")


# ---------------------------------------------------------------------------------------
# echo suppression
# ---------------------------------------------------------------------------------------
def pseudo_speech(seconds, seed, amp=0.3):
    """Speech-like signal: harmonic 'words' with syllable pulsing, pauses in between (deterministic per seed)."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = np.zeros(n, np.float32)
    t = 0.0
    while t < seconds - 0.1:
        word, gap, f0 = rng.uniform(0.25, 0.7), rng.uniform(0.08, 0.35), rng.uniform(95, 190)
        m = int(min(word, seconds - t) * SR)
        tt = np.arange(m) / SR
        env = np.sin(np.pi * tt / word) ** 2 * (0.4 + 0.6 * np.abs(np.sin(2 * np.pi * rng.uniform(3, 6) * tt + rng.uniform(0, 6.28))))
        sig = sum(np.sin(2 * np.pi * f0 * k * tt * (1 + 0.02 * np.sin(2 * np.pi * 3 * tt))) / k for k in range(1, 18))
        out[int(t * SR): int(t * SR) + m] = env * sig
        t += word + gap
    return (amp * out / max(1e-9, float(np.abs(out).max()))).astype(np.float32)


def delayed(x, seconds):
    d = int(seconds * SR)
    return np.concatenate([np.zeros(d, np.float32), x])[: len(x)]


def reverb(x, seed=7, rt=0.08, length=0.4):
    rng = np.random.default_rng(seed)
    ir = (rng.standard_normal(int(length * SR)) * np.exp(-np.arange(int(length * SR)) / (rt * SR))).astype(np.float32)
    ir[0] = 1.0
    y = np.convolve(x, ir)[: len(x)]
    return (y / max(1e-9, float(np.abs(y).max())) * float(np.abs(x).max())).astype(np.float32)


def S(start, end, text, track="mic"):
    return {"start": start, "end": end, "lang": "en", "text": text, "avg_logprob": -0.2, "no_speech_prob": 0.01}


R1 = "Okay so the FDA 510(k) submission is planned for the next quarter and we need the clinical data"
R2 = "The predicate device is ExamplePlatform and we should confirm the Pre-Sub meeting date with the FDA soon"
MIC_OWN = "네 저는 애크미의 AcmeScan 가격은 환자당 이 달러라고 생각합니다"


class EchoCoherenceTest(unittest.TestCase):
    def test_echo_scores_high_and_everything_else_low(self):
        remote = pseudo_speech(20.0, seed=1)
        own = pseudo_speech(20.0, seed=2, amp=0.35)
        cases = {
            "delayed attenuated copy": (delayed(remote, 0.12) * 0.1, 0.9, 1.01),
            "copy with room reverb and noise": (reverb(delayed(remote, 0.15) * 0.1) + 0.0005 * np.random.default_rng(1).standard_normal(len(remote)).astype(np.float32), 0.4, 1.0),
            "own voice with a faint echo underneath": (own + delayed(remote, 0.12) * 0.1, 0.0, 0.2),
            "independent speech": (pseudo_speech(20.0, seed=3), 0.0, 0.15),
            "silence": (np.zeros(len(remote), np.float32), 0.0, 0.01),
        }
        for label, (mic, lo, hi) in cases.items():
            with self.subTest(label):
                c = asr._echo_coherence(mic, remote, 4.0, 12.0)
                self.assertTrue(lo <= c <= hi, f"{label}: coherence {c:.3f} not in [{lo}, {hi}]")

    def test_works_at_the_edges_and_for_degenerate_input(self):
        remote = pseudo_speech(10.0, seed=1)
        echo = delayed(remote, 0.1) * 0.2
        self.assertGreater(asr._echo_coherence(echo, remote, 0.0, 5.0), 0.9)             # lag window reaches before t = 0
        self.assertGreater(asr._echo_coherence(echo, remote, 5.0, 10.0), 0.9)            # and past the end of the track
        self.assertGreater(asr._echo_coherence(echo, remote, 8.0, 14.0), 0.9)            # segment end beyond the audio is clipped
        self.assertIsNone(asr._echo_coherence(echo, remote, 1.0, 1.1))                   # too short to judge
        self.assertEqual(asr._echo_coherence(echo, np.zeros(len(remote), np.float32), 1.0, 5.0), 0.0)

    def test_echo_delay_range(self):
        remote = pseudo_speech(12.0, seed=4)
        for delay in (0.0, 0.03, 0.25, 0.6, 0.79):
            with self.subTest(delay=delay):
                self.assertGreater(asr._echo_coherence(delayed(remote, delay) * 0.1, remote, 3.0, 9.0), 0.9)
        self.assertLess(asr._echo_coherence(delayed(remote, 1.5) * 0.1, remote, 3.0, 9.0), 0.2)    # beyond the search range


def room_echo(x, *, gain=0.1, delay_s=0.09, drr_db=0.0, rt60=0.4, band=(250.0, 4500.0), noise_db=-65.0, seed=11):
    """What a laptop's microphone hears of ``x`` played through its speakers: band-limited (loudspeaker), a direct path at
    ``delay_s`` plus an exponentially decaying noise tail (``drr_db`` direct-to-reverberant ratio, ``rt60``), RMS scaled to
    ``gain`` x the RMS of ``x``, a noise floor. numpy only."""
    rng = np.random.default_rng(seed)
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    xb = np.fft.irfft(spec * ((freqs >= band[0]) & (freqs <= band[1])), len(x)).astype(np.float64)
    n = int(rt60 * SR)
    tail = rng.standard_normal(n) * 10.0 ** (-3.0 * np.arange(n) / (rt60 * SR))
    tail *= np.sqrt(10.0 ** (-drr_db / 10.0) / float(np.sum(tail ** 2)))
    ir = tail.copy()
    ir[0] += 1.0
    nfft = 1 << int(np.ceil(np.log2(len(x) + n)))
    y = np.fft.irfft(np.fft.rfft(xb, nfft) * np.fft.rfft(ir, nfft), nfft)[: len(x)]
    y = np.concatenate([np.zeros(int(delay_s * SR)), y])[: len(x)]
    y *= gain * float(np.sqrt(np.mean(x ** 2))) / float(np.sqrt(np.mean(y ** 2)) + 1e-12)
    return (y + rng.standard_normal(len(y)) * 10.0 ** (noise_db / 20.0)).astype(np.float32)


class EchoSuppressionTest(unittest.TestCase):
    def scenario(self, echo_gain=0.1, room=False, mic_speaks=True):
        remote = pseudo_speech(30.0, seed=1, amp=0.3)
        echo = delayed(remote, 0.12) * echo_gain
        if room:
            echo = reverb(echo) + (np.random.default_rng(3).standard_normal(len(echo)) * 0.0005).astype(np.float32)
        mic = echo.copy()
        own = pseudo_speech(5.0, seed=2, amp=0.35)
        if mic_speaks:
            mic[int(14 * SR): int(19 * SR)] += own                       # the user talks over the remote (double talk)
        again = pseudo_speech(5.0, seed=5, amp=0.35)
        mic[int(24 * SR): int(29 * SR)] += again                         # later the user repeats a remote phrase in their own, loud voice
        remote_segs = [S(0.5, 10.0, R1, "remote"), S(10.5, 22.0, R2, "remote")]
        mic_segs = [
            S(0.6, 10.1, "Okay, so the FDA 510K submission is planned for the next quarter and we need clinical data."),    # pure echo
            S(10.6, 13.9, "The predicate device is ExamplePlatform and we should confirm the Pre-Sub meeting"),                      # echo
            S(14.0, 19.0, MIC_OWN),                                                                                      # real, overlaps remote speech
            S(21.0, 21.6, "okay"),                                                                                       # echo only, 0.6 s, text too short to judge
            S(24.0, 29.0, "the predicate device is ExamplePlatform and we should confirm the pre sub meeting date"),               # real: repeats remote words
        ]
        return mic, remote, mic_segs, remote_segs

    def texts(self, segs):
        return [s["text"][:12] for s in segs]

    def test_echo_is_removed_and_real_speech_that_overlaps_remote_speech_survives(self):
        mic, remote, mic_segs, remote_segs = self.scenario()
        kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
        self.assertEqual([s["start"] for s in suppressed], [0.6, 10.6, 21.0])   # the 0.6 s "okay" is judged by its audio: pure echo
        self.assertEqual([s["start"] for s in kept], [14.0, 24.0])
        self.assertIn(MIC_OWN, [s["text"] for s in kept])                  # the user's own utterance, overlapping remote speech, is kept

    def test_room_reverb_noise_and_a_louder_echo_still_work(self):
        for gain in (0.05, 0.1, 0.18):
            with self.subTest(gain=gain):
                mic, remote, mic_segs, remote_segs = self.scenario(echo_gain=gain, room=True)
                kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
                self.assertEqual([s["start"] for s in suppressed], [0.6, 10.6, 21.0])
                self.assertIn(MIC_OWN, [s["text"] for s in kept])

    def test_mic_never_speaks_but_echo_is_present(self):
        mic, remote, mic_segs, remote_segs = self.scenario(mic_speaks=False)
        kept, suppressed = asr.suppress_echo(mic_segs[:2], remote_segs, mic, remote)
        self.assertEqual(len(suppressed), 2)                             # no own-voice reference: removed all the same
        self.assertEqual(kept, [])

    def test_same_words_in_mic_own_loud_voice_are_kept(self):
        """Text identical to the remote's, but the mic envelope/level say it is the user talking: never deleted."""
        mic, remote, mic_segs, remote_segs = self.scenario()
        repeat = [s for s in mic_segs if s["start"] == 24.0]
        kept, suppressed = asr.suppress_echo(repeat + [mic_segs[2]], remote_segs, mic, remote)
        self.assertEqual(suppressed, [])
        self.assertEqual(len(kept), 2)

    def test_repeating_the_remote_loudly_is_kept_even_without_any_other_own_utterance(self):
        """No own-voice level reference exists (every mic segment resembles the remote): the coherence test alone must protect it."""
        mic, remote, mic_segs, remote_segs = self.scenario()
        repeat = [s for s in mic_segs if s["start"] == 24.0]
        near = [S(24.0, 29.0, R2)]                                       # verbatim copy of the remote's words
        kept, suppressed = asr.suppress_echo(repeat + near, remote_segs, mic, remote)
        self.assertEqual((len(kept), len(suppressed)), (2, 0))

    def test_mic_speaking_the_same_words_at_the_same_time_as_the_remote_is_kept(self):
        remote = pseudo_speech(12.0, seed=1)
        mic = delayed(remote, 0.1) * 0.08 + pseudo_speech(12.0, seed=9, amp=0.4)       # loud independent voice + faint echo
        remote_segs = [S(0.5, 11.0, R1, "remote")]
        mic_segs = [S(0.5, 11.0, R1)]
        kept, suppressed = asr.suppress_echo(mic_segs + [S(20, 21, "something else entirely different here")], remote_segs, mic, remote)
        self.assertEqual(suppressed, [])

    def test_unrelated_text_over_echo_is_judged_by_the_audio_unrelated_text_over_mic_voice_is_kept(self):
        """Whisper often spells an echo differently from the remote's own transcript (Korean especially): the text then looks
        unrelated. What decides is the audio: over a pure echo the line goes, over the user's own voice it stays."""
        mic, remote, _, remote_segs = self.scenario()
        unrelated = "오늘 점심 뭐 먹을지 생각해 보니까 김치찌개가 좋을 것 같아요"
        over_echo = S(1.0, 9.0, unrelated)
        over_mic = S(14.0, 19.0, unrelated)
        own = S(24.0, 29.0, "the predicate device is ExamplePlatform and we should confirm the pre sub meeting date")
        kept, suppressed = asr.suppress_echo([over_echo, over_mic, own], remote_segs, mic, remote)
        self.assertEqual([s["start"] for s in suppressed], [1.0])
        self.assertEqual([s["start"] for s in kept], [14.0, 24.0])

    def test_without_audio_nothing_is_removed(self):
        _, _, mic_segs, remote_segs = self.scenario()
        self.assertEqual(asr.suppress_echo(mic_segs, remote_segs), (mic_segs, []))                     # text alone cannot prove an echo
        self.assertEqual(asr.suppress_echo([S(0.6, 10.1, R1)], remote_segs), ([S(0.6, 10.1, R1)], []))

    def test_short_texts_are_judged_by_audio_only(self):
        mic, remote, _, remote_segs = self.scenario()
        kept, suppressed = asr.suppress_echo([S(0.6, 1.5, "FDA"), S(2.0, 3.0, "okay")], remote_segs, mic, remote)   # echo only: gone
        self.assertEqual((len(kept), len(suppressed)), (0, 2))
        kept, suppressed = asr.suppress_echo([S(14.0, 15.5, "yes"), S(16.0, 17.0, "FDA")], remote_segs, mic, remote)   # the user's voice: stays
        self.assertEqual((len(kept), len(suppressed)), (2, 0))

    def test_no_remote_segments_or_no_mic_segments(self):
        mic, remote, mic_segs, remote_segs = self.scenario()
        self.assertEqual(asr.suppress_echo(mic_segs, [], mic, remote), (mic_segs, []))
        self.assertEqual(asr.suppress_echo([], remote_segs, mic, remote), ([], []))

    def test_far_away_remote_speech_is_not_a_text_match(self):
        """Same words 10 s after the remote said them: the text rule must not fire (and the user's own voice is not coherent)."""
        mic, remote, _, _ = self.scenario()
        far = [S(0.5, 10.0, R1, "remote")]
        segs = [S(24.0, 29.0, "Okay so the FDA 510(k) submission is planned for the next quarter and we need the clinical data")]
        kept, suppressed = asr.suppress_echo(segs, far, mic, remote)
        self.assertEqual(len(suppressed), 0)

    def test_inputs_are_not_mutated_and_order_is_preserved(self):
        mic, remote, mic_segs, remote_segs = self.scenario()
        before = json.dumps(mic_segs)
        kept, _ = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
        self.assertEqual(json.dumps(mic_segs), before)
        self.assertEqual([s["start"] for s in kept], sorted(s["start"] for s in kept))

    # ---- SPEC 15 / review_transcribe: the own-level reference and the audio-only rule -------------------------------------
    def world(self, *, gain, mic_gain=0.35, drr_db=0.0, rt60=0.4, mic_clips=((40.0, 45.0, 2),), echo_segs=((1.0, 9.0), (11.0, 19.0), (21.0, 29.0)), seed=1):
        """Remote speaking for 60 s; the mic hears a reverberant, band-limited echo of it plus the user's own voice in ``mic_clips``
        (start, end, speech seed). Returns (mic, remote, remote_segs, mic_segs): ``echo_segs`` are transcribed from the echo with
        text that does NOT resemble the remote transcript (Whisper spelled the echo differently), one more segment per clip."""
        remote = pseudo_speech(60.0, seed=seed, amp=0.3)
        mic = room_echo(remote, gain=gain, drr_db=drr_db, rt60=rt60)
        mic_segs = [S(a, b, f"전혀 다른 한국어 문장 번호 {i} 입니다 아무 상관 없는 내용") for i, (a, b) in enumerate(echo_segs)]
        for a, b, sd in mic_clips:
            mic[int(a * SR): int(b * SR)] += pseudo_speech(b - a, seed=sd + 20, amp=mic_gain)
            mic_segs.append(S(a, b, MIC_OWN))
        remote_segs = [S(0.5, 29.5, R1 + " " + R2, "remote")]
        return mic, remote, remote_segs, sorted(mic_segs, key=lambda x: x["start"])

    def test_echo_that_whisper_spelled_differently_does_not_poison_the_own_level_reference(self):
        """The review's finding: segments with dissimilar TEXT were the 'own utterance' reference, so echo transcribed
        differently pulled the reference down to the echo level and nothing was ever 'clearly quieter'."""
        for drr_db, gain in ((6.0, 0.06), (0.0, 0.06), (0.0, 0.03), (-6.0, 0.06)):
            with self.subTest(drr_db=drr_db, gain=gain):
                mic, remote, remote_segs, mic_segs = self.world(gain=gain, drr_db=drr_db)
                kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
                self.assertEqual([s["start"] for s in suppressed], [1.0, 11.0, 21.0])
                self.assertEqual([s["start"] for s in kept], [40.0])
                self.assertEqual(kept[0]["text"], MIC_OWN)

    def test_listen_only_mic_muted_all_echo_is_removed_even_with_unrelated_text(self):
        """The user is muted (or just listens): the whole mic track is echo and there is no own-voice reference at all."""
        for drr_db, gain in ((6.0, 0.06), (0.0, 0.06), (-6.0, 0.03)):
            with self.subTest(drr_db=drr_db, gain=gain):
                mic, remote, remote_segs, mic_segs = self.world(gain=gain, drr_db=drr_db, mic_clips=())
                text_like_remote = S(31.0, 38.0, "okay so the fda 510k submission is planned for the next quarter and we need clinical data")
                kept, suppressed = asr.suppress_echo(mic_segs + [text_like_remote], remote_segs, mic, remote)
                self.assertEqual(kept, [])
                self.assertEqual(len(suppressed), 4)

    def test_double_talk_mic_survives_over_a_loud_echo(self):
        """The user talks while the remote speaks and the echo is as loud as -12 dB under the user: whatever the text says (also the user
        repeating the remote's words verbatim), the user's segment stays; the echo-only segments around it go."""
        for mic_gain in (0.35, 0.2):
            with self.subTest(mic_gain=mic_gain):
                mic, remote, remote_segs, mic_segs = self.world(gain=0.12, mic_gain=mic_gain, mic_clips=((12.0, 18.0, 2), (24.0, 28.0, 3)),
                                                                echo_segs=((1.0, 9.0), (19.5, 23.0)))
                mic_segs[-1]["text"] = R2                                               # verbatim copy of what the remote said at that time
                kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
                self.assertEqual([s["start"] for s in suppressed], [1.0, 19.5])
                self.assertEqual([s["start"] for s in kept], [12.0, 24.0])

    def test_a_segment_not_clearly_quieter_than_mic_own_voice_is_never_suppressed_by_the_audio_rule(self):
        """The level guard: coherent with the remote but NOT clearly quieter than the user's own utterances (a loud echo and a soft
        the user: the coherent segment may hold a real answer, so the audio-only rule keeps its hands off)."""
        remote = pseudo_speech(60.0, seed=1, amp=0.3)
        remote[int(40 * SR):] = 0.0                                              # the remote is silent from 40 s on
        mic = room_echo(remote, gain=1.5, drr_db=6.0)                            # loud echo ...
        mic[int(45 * SR): int(50 * SR)] += pseudo_speech(5.0, seed=22, amp=0.1)    # ... and the user speaking softly, alone
        mic_segs = [S(1.0, 9.0, "전혀 다른 한국어 문장 번호 0 입니다 아무 상관 없는 내용"), S(45.0, 50.0, MIC_OWN)]
        remote_segs = [S(0.5, 29.5, R1 + " " + R2, "remote")]
        self.assertGreater(asr._echo_coherence(mic, remote, 1.0, 9.0), 0.6)      # the first segment IS echo ...
        kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote)
        self.assertEqual(suppressed, [])                                         # ... but it is louder than the user's own voice: it stays
        self.assertEqual(len(kept), 2)

    def test_the_audio_only_rule_and_the_text_rule_can_be_switched_off_by_thresholds(self):
        mic, remote, remote_segs, mic_segs = self.world(gain=0.06)
        kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote, audio_corr_min=2.0)     # audio-only rule disabled
        self.assertEqual(suppressed, [])                                                                  # text is unrelated: nothing else fires
        kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, mic, remote, level_margin_db=60.0)    # nothing is "clearly quieter"
        self.assertEqual(suppressed, [])

    def test_coherence_is_the_echo_share_of_the_energy_not_just_one_delayed_copy(self):
        remote = pseudo_speech(40.0, seed=4, amp=0.3)
        mic_voice = pseudo_speech(40.0, seed=8, amp=0.3)
        for drr_db in (6.0, 0.0, -6.0, -10.0):
            echo = room_echo(remote, gain=0.2, drr_db=drr_db, rt60=0.5)
            with self.subTest(drr_db=drr_db):
                pure = asr._echo_coherence(echo, remote, 4.0, 12.0)
                over = asr._echo_coherence(echo * 0.3 + mic_voice * 0.5, remote, 4.0, 12.0)          # the user ~ 12 dB above the echo
                self.assertGreater(pure, 0.6, pure)
                self.assertLess(over, 0.25, over)

    def test_long_segments_are_judged_on_their_middle_and_many_segments_are_fast(self):
        mic, remote, remote_segs, mic_segs = self.world(gain=0.06, mic_clips=())
        many = [S(1.0 + 0.1 * i, 3.0 + 0.1 * i, f"segment number {i} of many") for i in range(150)] + [S(0.0, 58.0, "one very long segment")]
        t0 = __import__("time").time()
        kept, suppressed = asr.suppress_echo(many, remote_segs, mic, remote)
        self.assertLess(__import__("time").time() - t0, 30.0)
        self.assertEqual(len(kept) + len(suppressed), len(many))

    def test_transcribe_tracks_applies_echo_suppression_and_reports_it(self):
        mic, remote, _, _ = self.scenario()

        order = []
        shared = FakeEngine()

        def fake_transcribe_track(x, engine, c, v, **kw):
            order.append(kw["track"])
            if kw["track"] == "mic":
                segs = [S(0.6, 10.1, "Okay, so the FDA 510K submission is planned for the next quarter and we need clinical data."), S(14.0, 19.0, MIC_OWN)]
            else:
                segs = [S(0.5, 10.0, R1, "remote"), S(10.5, 20.0, R2, "remote")]
            return asr.TrackResult(kw["track"], segs, [{"start": 1, "end": 2, "text": "x", "reason": "strong_phantom: p"}] if kw["track"] == "remote" else [],
                                   "en" if kw["track"] == "remote" else "ko", {"speech_s": 12.5 if kw["track"] == "mic" else 20.0})
        prepared = audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, 30.0, {})
        with mock.patch.object(asr, "get_engine", return_value=shared), mock.patch.object(asr, "transcribe_track", side_effect=fake_transcribe_track):
            out = asr.transcribe_tracks(prepared, cfg(self_name="Tester"), VOCAB)
        self.assertEqual(order, ["mic", "remote"])                       # mic first (SPEC 13.2)
        self.assertEqual(out["echo_suppressed"], 1)
        self.assertEqual([s["speaker"] for s in out["segments"]], ["Remote", "Remote", "Tester"])
        self.assertEqual(out["dropped"], {"mic": 0, "remote": 1})
        self.assertEqual(out["dropped_reasons"]["remote"], {"strong_phantom": 1})
        self.assertEqual(out["speech_seconds"], {"mic": 12.5, "remote": 20.0, "total": 32.5})
        self.assertEqual(out["languages"], {"mic": "ko", "remote": "en"})
        self.assertEqual(tr.validate_transcript(out), [])
        self.assertEqual(shared.released, 1)


REMOTE_PHONE = "Okay, now I am reading the sample agenda for the demo call and the placeholder topics"
REMOTE_PHONE_KO = "지금 제 샘플 안건을 데모에 공유하고 있습니다 그리고 메모도 정리했습니다"


class FragmentEchoTest(unittest.TestCase):
    """A remote participant says 'Okay, now I am reading the sample agenda ...' on the Remote track and the Mac microphone (speakers on)
    hears it again; the mic track gets a short duplicate 'Okay, now...' two seconds later and the whole-segment rules keep it
    (its level is not clearly under the user's own voice, or its coherence is in the grey zone).

    The mic audio of the scenarios (the fragment's 2 s span vs the user's own utterance at 40-45 s, which has no echo under it):
      loud   = speakers nearly as loud as the user  coherence 0.46, level 2.4 dB under the user's voice (the old rules need it 4 dB under)
      grey   = quiet echo + a faint voice      coherence 0.24, level 15 dB under the user (the old text rule needs coherence 0.30)
      voice  = the user talking over a quiet echo   coherence 0.17, level 5 dB under the user (the user's own voice: never suppressed)
      quiet  = a pure quiet echo               coherence 0.46, level 20 dB under the user (the old text rule removes it)
      mixed  = a soft voice over a loud echo     coherence 0.24, level 3 dB under the user (ambiguous: the audio cannot tell, so it stays)
    The span is 2 s on purpose: a clearly quieter fragment needs 0.20 coherence only from 2 s on (0.30 from 1 s, 0.40 under 1 s),
    because independent speech scores 0.2 on one 1.2 s span in ten (``test_a_short_quiet_span_needs_more_coherence...``).
    """
    FRAG = (12.0, 14.0)

    def world(self, kind, own_amp=0.35, frag=None):
        remote = pseudo_speech(60.0, seed=1, amp=0.3)
        remote[int(36 * SR): int(50 * SR)] = 0.0                                  # silent while the user speaks alone (no echo under their utterance)
        gain, faint = {"loud": (0.8, 0.0), "grey": (0.1, 0.05), "voice": (0.1, 0.2), "quiet": (0.1, 0.0), "mixed": (0.4, 0.2)}[kind]
        mic = room_echo(remote, gain=gain, drr_db=0.0)
        mic[int(40 * SR): int(45 * SR)] += pseudo_speech(5.0, seed=22, amp=own_amp)            # the user's own utterance = the level reference
        if faint:
            f0, f1 = frag or self.FRAG
            v = pseudo_speech(f1 - f0, seed=31, amp=faint)
            mic[int(f0 * SR): int(f0 * SR) + len(v)] += v
        return mic, remote

    def run_it(self, kind, text, remote_text=REMOTE_PHONE, remote_start=10.0, own_amp=0.35, frag=None, **kw):
        mic, remote = self.world(kind, own_amp, frag)
        frag, own = S(*(frag or self.FRAG), text), S(40.0, 45.0, MIC_OWN)
        kept, suppressed = asr.suppress_echo([frag, own], [S(remote_start, remote_start + 8.0, remote_text, "remote")], mic, remote, **kw)
        return frag, own, kept, suppressed

    def test_the_fragment_is_removed_where_the_whole_segment_rules_keep_it(self):
        for kind in ("loud", "grey"):
            with self.subTest(kind):
                frag, own, kept, suppressed = self.run_it(kind, "Okay, now...")
                self.assertEqual(suppressed, [frag])
                self.assertEqual(kept, [own])
        for text in ("Okay, now I am reading", "okay now i am reading the sample agenda", "OKAY... NOW!", "the placeholder topics"):
            with self.subTest(text):
                self.assertEqual(self.run_it("loud", text)[3][0]["text"], text)

    def test_the_audio_of_the_scenarios_is_what_the_docstring_says(self):
        for kind, (lo, hi) in {"loud": (0.4, 0.6), "grey": (0.2, 0.3), "voice": (0.0, 0.2), "mixed": (0.2, 0.3)}.items():
            mic, remote = self.world(kind)
            self.assertTrue(lo <= asr._echo_coherence(mic, remote, *self.FRAG) < hi, kind)

    def test_the_whole_segment_rules_still_come_first_and_are_counted_separately(self):
        from collections import Counter
        reasons = Counter()
        frag, own, kept, suppressed = self.run_it("quiet", "Okay, now...", reasons=reasons)                # pure quiet echo: the old text rule
        self.assertEqual((suppressed, reasons), ([frag], Counter({"whole-segment": 1})))
        reasons = Counter()
        frag, own, kept, suppressed = self.run_it("grey", "Okay, now...", reasons=reasons)
        self.assertEqual((suppressed, reasons), ([frag], Counter({"fragment-echo": 1})))

    def test_mic_own_voice_is_never_removed_whatever_the_words(self):
        frag, own, kept, suppressed = self.run_it("voice", "Okay, now I am reading the sample agenda")      # same words, the user talking over the echo
        self.assertEqual((suppressed, kept), ([], [frag, own]))
        mic, remote = self.world("loud", own_amp=0.1)                                                    # echo louder than the user's soft voice
        frag, own = S(*self.FRAG, "Okay, now..."), S(40.0, 45.0, MIC_OWN)
        kept, suppressed = asr.suppress_echo([frag, own], [S(10.0, 18.0, REMOTE_PHONE, "remote")], mic, remote)
        self.assertEqual((suppressed, kept), ([], [frag, own]))

    def test_a_short_quiet_span_needs_more_coherence_than_a_long_one(self):
        """Independent speech reaches coherence 0.2 on about one 1.2 s span in ten (0.5 s: one in three), 0.3 on one in a hundred
        (0.5 s: one in five), while a pure echo reaches 0.3 almost always. A real quiet answer that repeats the Remote's words must
        not be removed on the strength of such a chance: a clearly quieter fragment needs 0.40 under 1 s, 0.30 under 2 s and 0.20
        from 2 s on (the thresholds and the span limits are parameters)."""
        grey = {"short": (12.0, 12.8), "mid": (12.0, 13.2), "long": (12.0, 14.0)}      # the 'grey' audio: 15 dB under the user
        wanted = {("short", 0.35): False, ("short", 0.45): True, ("mid", 0.25): False, ("mid", 0.35): True,
                  ("long", 0.15): False, ("long", 0.25): True}
        for (span, coherence), removed in wanted.items():
            with self.subTest(span=span, coherence=coherence):
                frag = grey[span]
                real = asr._echo_coherence

                def fake(mic, remote, t0, t1, *a, _c=coherence, **k):
                    return _c if t0 < 30.0 else real(mic, remote, t0, t1, *a, **k)      # the user's own utterance (40 s) keeps its real score
                with mock.patch.object(asr, "_echo_coherence", side_effect=fake):       # "ok now" is 5 letters: the text rule cannot judge it
                    got = self.run_it("grey", "Ok, now", remote_text="Ok, now I am reading the sample agenda items", frag=frag)[3]
                self.assertEqual(len(got), 1 if removed else 0)
        # the real 'grey' audio (coherence 0.24): removed as a 2 s span, kept as a 1.2 s one
        self.assertEqual(len(self.run_it("grey", "Okay, now I am reading", frag=grey["long"])[3]), 1)
        self.assertEqual(self.run_it("grey", "Okay, now I am reading", frag=grey["mid"])[3], [])
        self.assertEqual(len(self.run_it("grey", "Okay, now I am reading", frag=grey["mid"], fragment_mid_s=1.0)[3]), 1)
        self.assertEqual(self.run_it("grey", "Okay, now I am reading", frag=grey["long"], fragment_mid_s=3.0)[3], [])
        # a clearly quieter span with real echo coherence (0.47-0.49) is removed at any length
        for span, frag in grey.items():
            with self.subTest(echo=span):
                self.assertEqual(len(self.run_it("quiet", "Okay, now I am reading", frag=frag)[3]), 1)

    def test_about_mic_own_level_it_takes_more_coherence_than_under_it(self):
        """Short spans make coherence noisy (independent speech reaches 0.2 on about one span in ten): a segment at the user's own level
        needs 0.40, a clearly quieter one 0.20. The 'mixed' scenario (coherence 0.24 at the user's level) is kept, 'grey' (0.24, 15 dB
        under the user) is removed; the thresholds are parameters."""
        frag, own, kept, suppressed = self.run_it("mixed", "Okay, now I am reading")
        self.assertEqual((suppressed, kept), ([], [frag, own]))
        self.assertEqual(len(self.run_it("grey", "Okay, now I am reading")[3]), 1)
        self.assertEqual(len(self.run_it("mixed", "Okay, now I am reading", fragment_corr_min=0.2)[3]), 1)
        self.assertEqual(self.run_it("grey", "Okay, now I am reading", own_corr_max=0.3)[3], [])
        self.assertEqual(self.run_it("loud", "Okay, now I am reading", fragment_louder_db=-5.0)[3], [])      # "must be 5 dB under the user"

    def test_sharing_a_word_or_a_prefix_is_not_enough_and_single_words_never_match_alone(self):
        for text in ("okay then", "okay let us start the review", "now I think so", "Okay, now what", "now", "okay", "agenda from now", "demo phone"):
            with self.subTest(text):
                self.assertEqual(self.run_it("loud", text)[3], [])                      # not a contiguous run of the Remote words
        self.assertEqual(self.run_it("grey", "placeholder")[3], [])                        # one long word: needs coherence 0.30 as well
        self.assertEqual(len(self.run_it("loud", "placeholder")[3]), 1)
        self.assertEqual(self.run_it("loud", "now")[3], [])                              # a short single word: never by this rule

    def test_mic_answering_on_purpose_with_the_same_first_words_but_going_on_is_kept(self):
        """Wave E review. The user says 'okay, now let's start' two seconds after the Remote said 'Okay, now I am reading ...': the words
        are not a run of the Remote's words, so no audio can make this rule fire, whatever the level and the coherence (and
        the real 'voice' / 'mixed' audio of the user talking over the echo keeps even the exact same words, see above)."""
        for text in ("Okay, now let's start", "okay now let us start the review", "Okay, now, are you ready", "Okay, now I will join too",
                     "Okay, now I am reading the other call"):
            for kind in ("loud", "grey", "mixed", "voice"):         # (a pure quiet echo is judged by the whole-segment rules, by similarity)
                with self.subTest(text=text, audio=kind):
                    self.assertEqual(self.run_it(kind, text)[3], [], text)

    def test_script_mixing_and_spacing_are_conservative(self):
        """Hangul and Latin in one segment are compared as words (casefold, punctuation stripped). A different spacing of the same
        Korean words ('데모에서' vs '데모 에서') is not a word match: the segment stays (never delete on a doubtful match)."""
        remote = "Demo 에서 샘플 안건을 확인 하고 있습니다 and the phone"
        for text, removed in (("demo 에서 샘플", True), ("Demo, 에서 샘플 안건을", True), ("안건을 확인 하고 있습니다 and", True),
                              ("Demo에서 샘플", False), ("demo 에서 샘플안건을", False), ("샘플 안건", False), ("확인 and", False)):
            with self.subTest(text=text):
                got = self.run_it("loud", text, remote_text=remote)[3]
                self.assertEqual(len(got), 1 if removed else 0)

    def test_the_lookup_of_the_remote_segments_is_not_quadratic(self):
        """~300 segments per track (one hour): every mic segment looks at the Remote segments that START inside its window (a bisect
        over the sorted starts), not at all of them."""
        n, calls = 300, []
        real = asr._contains_run

        def counting(words, run):
            calls.append(1)
            return real(words, run)
        mic_segs = [S(12.0 * i + 1.0, 12.0 * i + 3.0, f"okay now item {i} of the agenda") for i in range(n)]
        remote_segs = [S(12.0 * i, 12.0 * i + 9.0, f"remote speaker talks about topic {i} for a while", "remote") for i in range(n)]
        silent = np.zeros(SR * 10, np.float32)
        with mock.patch.object(asr, "_contains_run", side_effect=counting), mock.patch.object(asr, "_echo_coherence", return_value=0.0), \
                mock.patch.object(asr, "_span_db", return_value=-30.0):
            kept, suppressed = asr.suppress_echo(mic_segs, remote_segs, silent, silent)
        self.assertEqual((len(kept), len(suppressed)), (n, 0))
        self.assertLessEqual(len(calls), 3 * n)                      # a few Remote segments per user segment, never 300 x 300

    def test_the_remote_segment_must_start_within_four_seconds_before_or_a_second_and_a_half_after(self):
        start = self.FRAG[0]
        for offset, removed in ((-3.9, True), (-4.5, False), (0.0, True), (1.4, True), (2.0, False), (6.0, False)):
            with self.subTest(remote_starts_at=offset):
                suppressed = self.run_it("loud", "Okay, now...", remote_start=start + offset)[3]
                self.assertEqual(len(suppressed), 1 if removed else 0)

    def test_korean_fragments_and_a_segment_that_covers_the_whole_remote_text(self):
        for text in ("샘플 안건을", "제 샘플", "지금 제 샘플 안건을 데모에"):
            with self.subTest(text):
                self.assertEqual(self.run_it("loud", text, remote_text=REMOTE_PHONE_KO)[3][0]["text"], text)
        for text in ("샘플 안건", "안건을 데모"):                                                          # '안건' is not '안건을', '데모' is not '데모에'
            with self.subTest(text):
                self.assertEqual(self.run_it("loud", text, remote_text=REMOTE_PHONE_KO)[3], [])
        self.assertEqual(len(self.run_it("loud", REMOTE_PHONE)[3]), 1)

    def test_without_audio_or_without_remote_speech_nothing_is_removed(self):
        frag = S(*self.FRAG, "Okay, now...")
        self.assertEqual(asr.suppress_echo([frag], [S(10.0, 18.0, REMOTE_PHONE, "remote")]), ([frag], []))
        mic, remote = self.world("loud")
        self.assertEqual(asr.suppress_echo([frag], [], mic, remote), ([frag], []))

    def test_inputs_are_not_mutated(self):
        mic, remote = self.world("loud")
        mic_segs, remote_segs = [S(*self.FRAG, "Okay, now..."), S(40.0, 45.0, MIC_OWN)], [S(10.0, 18.0, REMOTE_PHONE, "remote")]
        before = json.dumps([mic_segs, remote_segs])
        asr.suppress_echo(mic_segs, remote_segs, mic, remote)
        self.assertEqual(json.dumps([mic_segs, remote_segs]), before)

    def test_transcribe_tracks_reports_the_reason(self):
        mic, remote = self.world("loud")
        frag, own = S(*self.FRAG, "Okay, now..."), S(40.0, 45.0, MIC_OWN)

        def fake_transcribe_track(x, engine, c, v, **kw):
            segs = [S(10.0, 18.0, REMOTE_PHONE, "remote")] if kw["track"] == "remote" else [frag, own]
            return asr.TrackResult(kw["track"], segs, [], "en", {"speech_s": 10.0})
        prepared = audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, 60.0, {})
        with mock.patch.object(asr, "get_engine", return_value=FakeEngine()), mock.patch.object(asr, "transcribe_track", side_effect=fake_transcribe_track):
            out = asr.transcribe_tracks(prepared, cfg(self_name="Tester", mic_aec="0"), VOCAB)
        self.assertEqual((out["echo_suppressed"], out["echo_suppressed_reasons"]), (1, {"fragment-echo": 1}))
        self.assertEqual([s["text"] for s in out["segments"] if s["track"] == "mic"], [MIC_OWN])
        self.assertEqual(tr.validate_transcript(out), [])


# ---------------------------------------------------------------------------------------
# transcribe_tracks with the fake engine
# ---------------------------------------------------------------------------------------
class TranscribeTracksTest(unittest.TestCase):
    def prepared(self, missing=()):
        n = 40 * SR
        tracks = {t: np.zeros(n, np.float32) for t in ("mic", "remote")}
        for t, (a, b) in (("mic", (2, 8)), ("remote", (10, 20))):
            tt = np.arange((b - a) * SR) / SR
            tracks[t][a * SR: b * SR] = (0.2 * np.sin(2 * np.pi * (200 if t == "mic" else 300) * tt) * (1 + np.sin(2 * np.pi * 4 * tt)) / 2).astype(np.float32)
        return audioprep.PreparedAudio(tracks, SR, 40.0, {}, missing=list(missing))

    def run_it(self, missing=(), **cfg_kw):
        engine = FakeEngine()
        progress = []
        with mock.patch.object(asr, "get_engine", return_value=engine):
            out = asr.transcribe_tracks(self.prepared(missing), cfg(asr_vad="energy", asr_language="en", **cfg_kw), VOCAB, progress.append)
        return out, engine, progress

    def test_structure_order_labels_and_progress(self):
        out, engine, progress = self.run_it(self_name="Tester")
        self.assertEqual(tr.validate_transcript(out), [])
        self.assertEqual([(s["track"], s["speaker"]) for s in out["segments"]], [("mic", "Tester"), ("remote", "Remote")])
        self.assertEqual(out["schema"], 1)
        self.assertEqual(out["asr_model"], cfg().asr_model)
        self.assertEqual(out["languages"], {"mic": "en", "remote": "en"})
        self.assertEqual(out["missing_tracks"], [])
        self.assertEqual(out["echo_suppressed"], 0)
        self.assertEqual(out["dropped"], {"mic": 0, "remote": 0})
        self.assertGreater(out["speech_seconds"]["mic"], 4.0)
        self.assertGreater(out["speech_seconds"]["remote"], 8.0)
        self.assertEqual([p for p in progress if p.startswith("transcribing")],
                         ["transcribing mic 1/1", "transcribing remote 1/1"])
        self.assertIn("checking echo", progress)
        self.assertEqual(progress.index("detecting speech mic") < progress.index("detecting speech remote"), True)
        json.dumps(out, ensure_ascii=False)                              # serializable as is
        self.assertEqual(engine.released, 1)

    def test_no_content_segments_are_counted_in_transcript_json(self):
        def script(audio, language, prompt, i):
            texts = ["!", "Hello team"] if i == 0 else ["Hello"]                          # chunk 0 = the mic track (mic is transcribed first)
            return {"text": "", "avg_logprob": -0.3, "segments": [
                {"start": 0.2 + k, "end": 0.9 + k, "text": t, "avg_logprob": -0.3, "no_speech_prob": 0.02, "compression_ratio": 1.1}
                for k, t in enumerate(texts)]}
        with mock.patch.object(asr, "get_engine", return_value=FakeEngine(script)):
            out = asr.transcribe_tracks(self.prepared(), cfg(asr_vad="energy", asr_language="en"), VOCAB)
        self.assertEqual([s["text"] for s in out["segments"] if s["track"] == "mic"], ["Hello team"])
        self.assertEqual(out["dropped"], {"mic": 1, "remote": 0})
        self.assertEqual(out["dropped_reasons"], {"mic": {"no-content": 1}, "remote": {}})
        self.assertEqual(tr.validate_transcript(out), [])

    def test_missing_track_is_skipped(self):
        out, engine, progress = self.run_it(missing=["remote"])
        self.assertEqual(out["missing_tracks"], ["remote"])
        self.assertEqual(out["languages"]["remote"], None)
        self.assertEqual({s["track"] for s in out["segments"]}, {"mic"})
        self.assertEqual(len(engine.calls), 1)
        self.assertFalse(any("remote" in p for p in progress))
        self.assertEqual(tr.validate_transcript(out), [])

    def test_all_silent_gives_an_empty_valid_transcript(self):
        prepared = audioprep.PreparedAudio({t: np.zeros(10 * SR, np.float32) for t in ("mic", "remote")}, SR, 10.0, {})
        with mock.patch.object(asr, "get_engine", return_value=FakeEngine()):
            out = asr.transcribe_tracks(prepared, cfg(asr_vad="energy"), VOCAB)
        self.assertEqual((out["segments"], out["speech_seconds"]["total"]), ([], 0.0))
        self.assertEqual(tr.validate_transcript(out), [])
        self.assertIn("(no speech detected)", tr.render_markdown(out, {"title": "t", "platform_label": "p"}))


# ---------------------------------------------------------------------------------------
# echo canceller wiring (SPEC 14.2) - integration fix: aec.py existed but nothing called it
# ---------------------------------------------------------------------------------------
class AecWiringTest(unittest.TestCase):
    """transcribe_tracks runs aec.cancel_echo(mic, remote, 16000, mode) before the mic VAD, feeds only the ASR with the cleaned
    audio, keeps the raw mic for suppress_echo, and stores the statistics in transcript.json['aec']."""

    def prepared(self, missing=()):
        return TranscribeTracksTest.prepared(self, missing)

    def run_it(self, cancel, missing=(), **cfg_kw):
        engine = FakeEngine()
        prepared = self.prepared(missing)
        seen = {}

        def fake_suppress(mic_segs, remote_segs, mic_audio=None, remote_audio=None, **kw):
            seen["suppress_mic_audio"] = mic_audio
            return list(mic_segs), []
        with mock.patch.object(asr, "get_engine", return_value=engine), mock.patch("mcap.aec.cancel_echo", side_effect=cancel) as m, \
                mock.patch.object(asr, "suppress_echo", side_effect=fake_suppress), \
                mock.patch.object(asr.vadmod, "detect_speech", wraps=asr.vadmod.detect_speech) as vad_spy:
            out = asr.transcribe_tracks(prepared, cfg(asr_vad="energy", asr_language="en", **cfg_kw), VOCAB, lambda _m: None)
        return out, m, prepared, seen, vad_spy

    @staticmethod
    def applied(mic, ref, sr, mode, progress=None, **kw):
        stats = {"applied": True, "coherence": np.float32(0.62), "delay_ms": np.float64(31.5), "erle_db": 24.0, "mode": mode,
                 "delay_track": [(np.float32(0.0), np.float32(31.5))], "preserved_ratio": None, "reason": ""}
        return (np.asarray(mic) * 0.5).astype(np.float32), stats

    def test_auto_runs_before_the_vad_and_only_the_asr_input_changes(self):
        out, m, prepared, seen, vad_spy = self.run_it(self.applied)
        m.assert_called_once()
        args = m.call_args.args
        self.assertIs(args[0], prepared.tracks["mic"])
        self.assertIs(args[1], prepared.tracks["remote"])
        self.assertEqual(args[2:4], (SR, "auto"))
        # the mic VAD saw the CLEANED audio (here: the mic at half amplitude), the remote VAD the untouched remote track
        np.testing.assert_allclose(vad_spy.call_args_list[0].args[0], 0.5 * prepared.tracks["mic"])
        self.assertIs(vad_spy.call_args_list[1].args[0], prepared.tracks["remote"])
        self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})
        self.assertIs(seen["suppress_mic_audio"], prepared.tracks["mic"])             # the safety net looks at the raw microphone
        self.assertGreater(float(np.abs(prepared.tracks["mic"]).max()), 0.19)         # the prepared mic track is not modified in place
        self.assertTrue(out["aec"]["applied"])
        self.assertAlmostEqual(out["aec"]["coherence"], 0.62, places=5)
        self.assertEqual((out["aec"]["delay_ms"], out["aec"]["erle_db"]), (31.5, 24.0))
        json.dumps(out, ensure_ascii=False)                                           # numpy scalars were converted
        self.assertEqual(tr.validate_transcript(out), [])

    def test_modes_and_switch(self):
        cases = [("auto", "auto"), ("AUTO", "auto"), ("1", "always"), ("on", "always"), ("bogus", "auto")]
        for value, mode in cases:
            with self.subTest(value):
                out, m, *_ = self.run_it(self.applied, mic_aec=value)
                self.assertEqual(m.call_args.args[3], mode)
        for value in ("0", "off", "False"):
            with self.subTest(value):
                out, m, prepared, seen, vad_spy = self.run_it(self.applied, mic_aec=value)
                m.assert_not_called()
                self.assertEqual(out["aec"], {"applied": False, "mode": "off", "reason": "MIC_AEC=0"})
                self.assertIs(seen["suppress_mic_audio"], prepared.tracks["mic"])
                self.assertIs(vad_spy.call_args_list[0].args[0], prepared.tracks["mic"])             # raw mic transcribed
                self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})

    def test_not_applied_keeps_the_raw_mic_and_reports_why(self):
        def not_applied(mic, ref, sr, mode, progress=None, **kw):
            return np.asarray(mic, dtype=np.float32), {"applied": False, "coherence": 0.02, "mode": mode,
                                                       "reason": "coherence 0.020 below 0.10: no speaker leakage"}
        out, m, prepared, seen, vad_spy = self.run_it(not_applied)
        self.assertFalse(out["aec"]["applied"])
        self.assertIn("no speaker leakage", out["aec"]["reason"])
        self.assertIs(vad_spy.call_args_list[0].args[0], prepared.tracks["mic"])
        self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})

    def test_a_crashing_or_wrong_sized_canceller_never_loses_the_transcript(self):
        def boom(*a, **kw):
            raise RuntimeError("fft exploded")
        out, *_ = self.run_it(boom)
        self.assertFalse(out["aec"]["applied"])
        self.assertIn("fft exploded", out["aec"]["error"])
        self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})
        self.assertEqual(tr.validate_transcript(out), [])

        def short(mic, ref, sr, mode, progress=None, **kw):
            return np.zeros(10, np.float32), {"applied": True, "mode": mode}
        out, m, prepared, seen, vad_spy = self.run_it(short)
        self.assertIs(vad_spy.call_args_list[0].args[0], prepared.tracks["mic"])             # unusable result ignored
        self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})

        def failed(mic, ref, sr, mode, progress=None, **kw):                  # cancel_echo's own never-raise contract
            return np.asarray(mic, dtype=np.float32), {"applied": False, "mode": mode, "error": "ValueError: bad audio"}
        out, *_ = self.run_it(failed)
        self.assertEqual(out["aec"]["error"], "ValueError: bad audio")

    def test_without_the_canceller_echo_only_chunks_are_removed_and_mic_own_chunk_stays(self):
        """Deterministic version of the MIC_AEC=0 situation (fake engine that "transcribes" every chunk it is given): the
        remote speaks for 40 s and the mic hears a reverberant, band-limited echo of it; the user speaks alone from 50 s on. The
        text of the echo lines is unrelated to anything, so only the audio can tell: every echo line goes, the user's stays."""
        remote = np.zeros(70 * SR, np.float32)
        remote[: 40 * SR] = pseudo_speech(40.0, seed=1, amp=0.3)
        mic = room_echo(remote, gain=0.1, delay_s=0.07, drr_db=3.0, rt60=0.35)
        mic[50 * SR: 62 * SR] += pseudo_speech(12.0, seed=2, amp=0.35)
        prepared = audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, 70.0, {})
        sentences = ["kimchi stew sounds wonderful on a rainy evening", "the quarterly forecast mentions steady demand", "please remind everybody about parking",
                     "my flight lands shortly after midnight tomorrow", "rotating the tires costs about forty dollars", "a violin concerto played in the lobby",
                     "yesterday's marathon route crossed three bridges", "bananas ripen faster next to apples", "the printer on the third floor jammed again",
                     "somebody left an umbrella in the elevator"]
        engine = FakeEngine(lambda audio, language, prompt, i: {"text": "x", "language": language, "avg_logprob": -0.3, "segments": [
            {"start": 0.2, "end": len(audio) / SR - 0.2, "text": sentences[i % len(sentences)], "avg_logprob": -0.3,
             "no_speech_prob": 0.01, "compression_ratio": 1.1}]})
        with mock.patch.object(asr, "get_engine", return_value=engine):
            out = asr.transcribe_tracks(prepared, cfg(asr_vad="energy", asr_language="en", mic_aec="0"), VOCAB)
        self.assertEqual(out["aec"], {"applied": False, "mode": "off", "reason": "MIC_AEC=0"})
        mic_segs = [s for s in out["segments"] if s["track"] == "mic"]
        self.assertGreaterEqual(out["echo_suppressed"], 1)                          # the net had real work to do ...
        self.assertTrue(mic_segs and all(s["start"] >= 49.0 for s in mic_segs), [(s["start"], s["end"]) for s in mic_segs])       # ... and left only the user
        self.assertTrue(any(s["track"] == "remote" and s["end"] < 41.0 for s in out["segments"]))
        self.assertEqual(tr.validate_transcript(out), [])

    def test_a_missing_track_skips_the_canceller(self):
        for missing in (["remote"], ["mic"]):
            with self.subTest(missing):
                out, m, *_ = self.run_it(self.applied, missing=missing)
                m.assert_not_called()
                self.assertFalse(out["aec"]["applied"])
                self.assertIn(missing[0], out["aec"]["reason"])
                self.assertEqual(out["missing_tracks"], missing)

    @needs_tts
    def test_real_canceller_on_a_synthetic_speaker_leak(self):
        """No mocks: remote = TTS speech, mic = quiet delayed + reverberated copy of it (laptop speakers), the user silent."""
        x, sr = wavio.read_wav_lenient(TTS / "meeting_like_184s.wav")
        self.assertEqual(sr, SR)
        remote = np.ascontiguousarray(x[: 40 * SR])
        rng = np.random.default_rng(7)
        rir = np.zeros(int(0.25 * SR), np.float32)
        rir[int(0.040 * SR)] = 1.0                                                  # direct path 40 ms
        tail = rng.standard_normal(len(rir)).astype(np.float32) * np.exp(-np.arange(len(rir)) / (0.08 * SR))
        tail[: int(0.040 * SR) + 1] = 0.0
        rir += tail * np.float32(np.sqrt(0.3 / float(np.sum(tail ** 2))))           # reverberant tail with 30 % of the direct energy
        mic = np.convolve(remote, rir)[: len(remote)].astype(np.float32) * 0.1 + 1e-4 * rng.standard_normal(len(remote)).astype(np.float32)
        prepared = audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, 40.0, {})
        engine = FakeEngine()
        with mock.patch.object(asr, "get_engine", return_value=engine):
            out = asr.transcribe_tracks(prepared, cfg(asr_vad="energy", asr_language="en", mic_aec="auto"), VOCAB)
        aec_stats = out["aec"]
        self.assertTrue(aec_stats["applied"], aec_stats)
        self.assertGreater(aec_stats["coherence"], 0.3)
        self.assertAlmostEqual(aec_stats["delay_ms"], 40.0, delta=3.0)
        self.assertGreater(aec_stats["erle_db"] or 0.0, 20.0)
        json.dumps(out, ensure_ascii=False)


# ---------------------------------------------------------------------------------------
# engines, routing, model resolution
# ---------------------------------------------------------------------------------------
class EngineRoutingTest(unittest.TestCase):
    def test_routing_by_name(self):
        self.assertIsInstance(asr_engines.create_engine("mlx-community/whisper-large-v3-mlx"), WhisperEngine)
        self.assertIsInstance(asr_engines.create_engine("/some/local/dir"), WhisperEngine)
        for name in ("mlx-community/Qwen3-ASR-1.7B-bf16", "Qwen/Qwen3-ASR-1.7B", "example-org/qwen3_asr_1.7b_finetune", "mlx-community/Qwen3-ASR-1.7B-8bit"):
            with self.subTest(name):
                e = asr_engines.create_engine(name)
                self.assertIsInstance(e, asr_engines.QwenEngine)
                self.assertFalse(e.supports_lid)

    def test_low_bit_qwen_is_rejected(self):
        for name in ("mlx-community/Qwen3-ASR-1.7B-4bit", "mlx-community/Qwen3-ASR-0.6B-5bit", "moona3k/mlx-qwen3-asr-1.7b-4bit", "x/qwen3_asr-4-bit"):
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    asr_engines.create_engine(name)

    def test_get_engine_is_cached_per_model(self):
        with mock.patch.dict(asr_engines._engines, clear=True):
            a, b = asr_engines.get_engine("x/whisper-a"), asr_engines.get_engine("x/whisper-a")
            self.assertIs(a, b)
            self.assertIsNot(a, asr_engines.get_engine("x/whisper-b"))

    def test_qwen_needs_its_package(self):
        e = asr_engines.create_engine("mlx-community/Qwen3-ASR-1.7B-bf16")
        with mock.patch.dict(sys.modules, {"mlx_qwen3_asr": None}):
            with self.assertRaises(asr_engines.EngineUnavailable):
                e.load()

    def test_qwen_engine_wiring_with_a_stub_package(self):
        calls = []

        def fake_transcribe(audio, *, model, language, context, **kw):
            calls.append({"n": len(audio), "dtype": audio.dtype, "model": model, "language": language, "context": context})
            return types.SimpleNamespace(text="  안녕하세요 FDA  ", language="Korean", finish_reason="length" if len(audio) > SR * 5 else "eos",
                                         truncated=False)
        stub = types.ModuleType("mlx_qwen3_asr")
        stub.transcribe = fake_transcribe
        with mock.patch.dict(sys.modules, {"mlx_qwen3_asr": stub}), mock.patch.object(asr_engines, "resolve_model_path", return_value="/models/q"):
            e = asr_engines.create_engine("mlx-community/Qwen3-ASR-1.7B-bf16")
            r = e.transcribe_chunk(np.zeros(SR * 2, np.float32), "ko", "Technical terms: FDA")
            self.assertEqual((calls[0]["language"], calls[0]["context"], calls[0]["dtype"]), ("Korean", "Technical terms: FDA", np.float32))
            self.assertEqual(r["text"], "안녕하세요 FDA")
            self.assertFalse(r["truncated"])
            self.assertEqual((r["segments"][0]["start"], r["segments"][0]["end"], r["segments"][0]["avg_logprob"]), (0.0, 2.0, None))
            r = e.transcribe_chunk(np.zeros(SR * 7, np.float32), None, None)
            self.assertEqual((calls[1]["language"], calls[1]["context"]), (None, ""))
            self.assertTrue(r["truncated"])                                  # finish_reason != eos is recorded as truncated
            # through the track loop: None language, longer chunks, truncated recorded, no crash on missing log-probs
            res = asr.transcribe_track(np.zeros(60 * SR, np.float32), e, cfg(), VOCAB, language="auto", vad=vad_result([(1.0, 9.0), (12.0, 20.0)], 60))
            self.assertEqual(res.info["chunks"], 1)
            self.assertEqual(res.info["truncated_chunks"], 1)
            self.assertEqual(res.info["prompt_retries"], 1)
            self.assertEqual(len(res.segments), 1)
            self.assertIsNone(res.segments[0]["avg_logprob"])
            self.assertEqual(res.language, "ko")                             # "Korean" -> "ko"


class ModelResolutionTest(unittest.TestCase):
    def test_pin_for_large_v3(self):
        self.assertEqual(asr_engines.REVISION_PINS["mlx-community/whisper-large-v3-mlx"], "49e6aa286ad60c14352c404340ded53710378a11")

    @needs_hf_hub
    def test_local_directory_is_returned_without_touching_hugging_face(self):
        with tempfile.TemporaryDirectory() as d, mock.patch("huggingface_hub.snapshot_download", side_effect=AssertionError("no HF")):
            self.assertEqual(asr_engines.resolve_model_path(d), d)

    @needs_hf_hub
    def test_cache_hit_never_downloads_and_uses_the_pin(self):
        calls = []

        def fake(repo, **kw):
            calls.append((repo, kw))
            return "/cache/snap"
        with mock.patch("huggingface_hub.snapshot_download", side_effect=fake):
            self.assertEqual(asr_engines.resolve_model_path("mlx-community/whisper-large-v3-mlx"), "/cache/snap")
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1]["local_files_only"])
        self.assertEqual(calls[0][1]["revision"], "49e6aa286ad60c14352c404340ded53710378a11")

    @needs_hf_hub
    def test_missing_model_is_downloaded_explicitly_and_logged(self):
        calls = []

        def fake(repo, **kw):
            calls.append(dict(kw))
            if kw.get("local_files_only"):
                raise FileNotFoundError("not cached")
            return "/cache/new"
        with mock.patch("huggingface_hub.snapshot_download", side_effect=fake):
            with self.assertLogs("mcap.asr", level="WARNING") as logs:
                self.assertEqual(asr_engines.resolve_model_path("someone/whisper-x"), "/cache/new")
        self.assertEqual([bool(c.get("local_files_only")) for c in calls], [True, False])
        self.assertTrue(any("DOWNLOADING" in m and "someone/whisper-x" in m for m in logs.output), logs.output)

    @needs_hf_hub
    def test_incomplete_cached_copy_triggers_a_download(self):
        calls = []

        def fake(repo, **kw):
            calls.append(bool(kw.get("local_files_only")))
            return "/cache/snap"
        with mock.patch("huggingface_hub.snapshot_download", side_effect=fake):
            asr_engines.resolve_model_path("someone/whisper-x", check=lambda p: len(calls) > 1)
        self.assertEqual(calls, [True, False])

    @needs_hf_hub
    def test_downloads_can_be_forbidden_and_failures_are_clear(self):
        def offline(repo, **kw):
            raise FileNotFoundError("not cached") if kw.get("local_files_only") else OSError("network down")
        with mock.patch("huggingface_hub.snapshot_download", side_effect=offline):
            with self.assertRaisesRegex(asr_engines.ModelNotAvailable, "downloads are disabled"):
                asr_engines.resolve_model_path("someone/whisper-x", allow_download=False)
            with self.assertRaisesRegex(asr_engines.ModelNotAvailable, "network down"):
                asr_engines.resolve_model_path("someone/whisper-x")

    @needs_tiny
    def test_tiny_model_resolves_from_the_local_cache(self):
        path = asr_engines.resolve_model_path(TINY, allow_download=False)
        self.assertTrue((Path(path) / "config.json").exists())


@needs_mlx_whisper
class WhisperEngineCallTest(unittest.TestCase):
    """The forbidden mlx-whisper arguments must never be passed (SPEC 13.2)."""

    def test_arguments_passed_to_mlx_whisper(self):
        captured = []

        def fake_transcribe(audio, **kw):
            captured.append(kw)
            return {"text": " hi ", "segments": [{"start": 0.0, "end": 1.0, "text": " hi ", "avg_logprob": -0.1, "no_speech_prob": 0.0,
                                                 "compression_ratio": 1.0, "temperature": 0.0}]}
        e = WhisperEngine("fake/whisper")
        e.path = "/fake/dir"
        with mock.patch("mlx_whisper.transcribe", fake_transcribe):
            r = e.transcribe_chunk(np.zeros(SR, np.float64), "ko", "prompt text")
            e.transcribe_chunk(np.zeros(SR, np.float32), "en", None)
            e.transcribe_chunk(np.zeros(SR, np.float32), "en", "")
        kw = captured[0]
        self.assertEqual((kw["language"], kw["initial_prompt"], kw["path_or_hf_repo"]), ("ko", "prompt text", "/fake/dir"))
        self.assertIs(kw["verbose"], None)
        self.assertNotIn("beam_size", kw)
        self.assertFalse(kw["condition_on_previous_text"])
        self.assertEqual(kw["temperature"], (0.0, 0.2, 0.4, 0.6))
        self.assertEqual((kw["compression_ratio_threshold"], kw["logprob_threshold"], kw["no_speech_threshold"]), (2.4, -1.0, 0.6))
        self.assertFalse(kw["word_timestamps"])
        self.assertTrue(kw["fp16"])
        self.assertIsNone(captured[2]["initial_prompt"])                  # '' is turned into None
        self.assertEqual(r["text"], "hi")
        self.assertEqual(r["segments"][0]["text"], "hi")


# ---------------------------------------------------------------------------------------
# real tiny model
# ---------------------------------------------------------------------------------------
@needs_tiny
@needs_tts
class TinyModelEndToEndTest(unittest.TestCase):
    """Quality of whisper-tiny is irrelevant here: structure, timing and plumbing are what is checked."""

    def make_session(self, d: Path, mic_clip="mix_ko_en_ko_codeswitch", remote_clip="en_samantha_terms", mic_off=0.05, remote_off=2.0):
        def up3(x):                                     # 16 kHz clip -> 48 kHz (linear interpolation is fine for a test input)
            return np.interp(np.arange(len(x) * 3) / 3.0, np.arange(len(x)), x).astype(np.float32)
        tracks = {}
        for name, clip, off in (("mic", mic_clip, mic_off), ("remote", remote_clip, remote_off)):
            if clip is None:
                continue
            x, _ = wavio.read_wav_lenient(TTS / f"{clip}.wav")
            wavio.write_wav_int16(d / f"{name}.wav", up3(x), 48000)
            tracks[name] = {"file": f"{name}.wav", "sample_rate": 48000, "channels": 1, "start_offset_sec": off}
        return {"schema": 1, "session_id": "t", "platform": "meet", "tracks": tracks}

    def test_prepare_then_transcribe_validates_against_the_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            session = self.make_session(d)
            prepared = audioprep.prepare_audio(d, session)
            c = cfg(asr_model=TINY, support_dir=d / "support")
            progress = []
            out = asr.transcribe_tracks(prepared, c, VOCAB, progress.append)
            self.assertEqual(tr.validate_transcript(out), [], tr.validate_transcript(out))
            self.assertEqual(out["asr_model"], TINY)
            self.assertGreater(len(out["segments"]), 3)
            self.assertEqual({s["track"] for s in out["segments"]}, {"mic", "remote"})
            for s in out["segments"]:
                self.assertGreaterEqual(s["start"], 0.0)
                self.assertLessEqual(s["end"], prepared.duration_sec + 0.05)
                self.assertIn(s["speaker"], ("Me", "Remote"))
                self.assertLessEqual(s["avg_logprob"], 0.0)
            remote_starts = [s["start"] for s in out["segments"] if s["track"] == "remote"]
            self.assertGreaterEqual(min(remote_starts), 2.0 - 0.4)                        # the remote clip starts 2.0 s after t0 (chunks carry 0.3 s of padding)
            mic_starts = [s["start"] for s in out["segments"] if s["track"] == "mic"]
            self.assertLess(min(mic_starts), 1.0)
            self.assertEqual(out["languages"]["mic"], "ko")
            self.assertEqual(out["languages"]["remote"], "en")
            self.assertTrue(any(p.startswith("transcribing remote ") and p.count("/") == 1 for p in progress))
            md = tr.render_markdown(out, {"title": "Tiny", "date": "2026-10-07", "platform_label": "Google Meet",
                                          "start_time": "2026-10-07T14:00:12+09:00", "duration_sec": prepared.duration_sec})
            self.assertIn("[00:00:0", md)
            self.assertIn("ASR: " + TINY, md)
            self.assertEqual(json.loads(json.dumps(out, ensure_ascii=False))["schema"], 1)
            # the archive files were produced next to the WAVs
            if audioprep.afconvert_path():
                self.assertEqual(set(prepared.archive_files), {"audio", "mic", "remote"})

    def leaky_session(self, mic_aec, languages="ko,en", asr_language="en"):
        """48 kHz WAVs with a reverberant band-limited speaker echo of the remote in the mic track, the user talking over the remote
        (18-38 s) and alone (52-64 s) -> prepare_audio -> echo canceller -> VAD -> tiny Whisper -> echo safety net.
        Returns (transcript, [(start, end) of the user's clips], progress)."""
        def up3(x):
            return np.interp(np.arange(len(x) * 3) / 3.0, np.arange(len(x)), x).astype(np.float32)

        def rms(x):
            return float(np.sqrt(np.mean(np.square(x, dtype=np.float64))) + 1e-12)
        total = 75 * SR
        meeting, _ = wavio.read_wav_lenient(TTS / "meeting_like_184s.wav")
        remote = np.zeros(total, np.float32)
        remote[: 45 * SR] = meeting[: 45 * SR]
        echo = room_echo(remote, gain=0.1, delay_s=0.07, drr_db=3.0, rt60=0.35)
        mic = echo.copy()
        spans = []
        for clip, start in (("en_samantha_terms", 18.0), ("en_samantha_names", 52.0)):
            x, _ = wavio.read_wav_lenient(TTS / f"{clip}.wav")
            x = x * (5.0 * rms(echo[: 45 * SR]) / rms(x))                       # the user is ~14 dB above the echo at their own microphone
            mic[int(start * SR): int(start * SR) + len(x)] += x
            spans.append((start, start + len(x) / SR))
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            wavio.write_wav_int16(d / "mic.wav", up3(mic), 48000)
            wavio.write_wav_int16(d / "remote.wav", up3(remote), 48000)
            session = {"schema": 1, "session_id": "t", "platform": "zoom", "tracks": {
                "mic": {"file": "mic.wav", "sample_rate": 48000, "channels": 1, "start_offset_sec": 0.0},
                "remote": {"file": "remote.wav", "sample_rate": 48000, "channels": 1, "start_offset_sec": 0.0}}}
            prepared = audioprep.prepare_audio(d, session)
            progress = []
            out = asr.transcribe_tracks(prepared, cfg(asr_model=TINY, support_dir=d / "support", asr_language=asr_language, mic_aec=mic_aec,
                                                      asr_languages=languages), VOCAB, progress.append)
        return out, spans, progress

    @staticmethod
    def mic_lines_outside(out, spans):
        inside = lambda s, lo, hi: s["end"] > lo - 1.5 and s["start"] < hi + 1.5
        mic = [s for s in out["segments"] if s["track"] == "mic"]
        return mic, [s for s in mic if not any(inside(s, lo, hi) for lo, hi in spans)], inside

    def test_a_speaker_leak_goes_through_audioprep_the_canceller_and_the_tiny_model(self):
        """The whole chain, nothing mocked. Every the user line must lie inside one of the user's two clips (no remote speech under their
        name) and both clips must be there."""
        out, spans, progress = self.leaky_session("auto")
        self.assertEqual(tr.validate_transcript(out), [])
        a = out["aec"]
        self.assertTrue(a["applied"], a)
        self.assertGreater(a["coherence"], 0.3)
        self.assertAlmostEqual(a["delay_ms"], 70.0, delta=2.0)                  # the delay of room_echo(), found through 3:1 resampling and the AEC
        self.assertGreater(a["erle_db"] or 0.0, 8.0)
        self.assertIn("echo cancellation", progress)
        mic, outside, inside = self.mic_lines_outside(out, spans)
        self.assertGreaterEqual(len([s for s in out["segments"] if s["track"] == "remote"]), 1)
        self.assertEqual(outside, [], [(s["start"], s["end"], s["text"][:40]) for s in outside])
        for lo, hi in spans:
            self.assertTrue(any(inside(s, lo, hi) for s in mic), (lo, hi, [(s["start"], s["end"]) for s in mic]))
        self.assertEqual(out["stats"]["mic"]["languages"], ["ko", "en"])
        json.dumps(out, ensure_ascii=False)

    def test_without_the_canceller_the_echo_safety_net_still_keeps_remote_speech_out_of_mic_lines(self):
        """MIC_AEC=0 (or an unusable canceller): the speaker echo is transcribed as the user and `suppress_echo` has to remove it
        (the review's finding: it used to keep much of it)."""
        out, spans, _ = self.leaky_session("0")
        self.assertEqual(out["aec"], {"applied": False, "mode": "off", "reason": "MIC_AEC=0"})
        mic, outside, inside = self.mic_lines_outside(out, spans)
        self.assertEqual(outside, [], [(s["start"], s["end"], s["text"][:40]) for s in outside])
        for lo, hi in spans:
            self.assertTrue(any(inside(s, lo, hi) for s in mic), (lo, hi, [(s["start"], s["end"]) for s in mic]))
        # (how many echo lines whisper-tiny produced, and so how many the net had to remove, varies from run to run: the
        #  deterministic version of this test is AecWiringTest.test_without_the_canceller_echo_only_chunks_are_removed)

    def test_missing_remote_track_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            session = self.make_session(d, remote_clip=None)
            prepared = audioprep.prepare_audio(d, session)
            out = asr.transcribe_tracks(prepared, cfg(asr_model=TINY, support_dir=d / "support"), VOCAB)
            self.assertEqual(out["missing_tracks"], ["remote"])
            self.assertEqual({s["track"] for s in out["segments"]}, {"mic"})
            self.assertEqual(tr.validate_transcript(out), [])

    def test_whisper_engine_language_id_and_transcribe_array(self):
        c = cfg(asr_model=TINY, support_dir=Path(tempfile.gettempdir()) / "mcap-nonexistent")
        e = asr_engines.get_engine(TINY)
        x, _ = wavio.read_wav_lenient(TTS / "en_samantha_terms.wav")
        k, _ = wavio.read_wav_lenient(TTS / "ko_yuna_terms.wav")
        lid = e.detect_languages([x[: 10 * SR], k[: 10 * SR]])
        self.assertEqual(len(lid), 2)
        for item in lid:
            self.assertAlmostEqual(item["ko"] + item["en"], 1.0, places=5)
            self.assertEqual(set(item), {"ko", "en", "top"})
            self.assertEqual(item["top"], max(("ko", "en"), key=item.get))
        self.assertEqual(lid[0]["top"], "en")
        self.assertEqual(lid[1]["top"], "ko")
        # ASR_LANGUAGES: the same clips, probabilities restricted to (and renormalised over) the configured set
        three = e.detect_languages([x[: 10 * SR], k[: 10 * SR]], ("ja", "ko", "en"))
        for item in three:
            self.assertEqual(set(item), {"ja", "ko", "en", "top"})
            self.assertAlmostEqual(item["ja"] + item["ko"] + item["en"], 1.0, places=5)
        self.assertEqual((three[0]["top"], three[1]["top"]), ("en", "ko"))
        only_ko = e.detect_languages([x[: 10 * SR]], ("ko",))
        self.assertEqual(only_ko, [{"ko": 1.0, "top": "ko"}])                       # a one-language set: the English clip is "ko" by definition
        segs = asr.transcribe_array(x, c, VOCAB, language="en")
        self.assertTrue(segs)
        self.assertTrue(all({"start", "end", "lang", "text", "avg_logprob", "no_speech_prob"} <= set(s) for s in segs))
        self.assertTrue(all(0 <= s["start"] <= s["end"] <= len(x) / SR + 0.1 for s in segs))
        e.release()


# ---------------------------------------------------------------------------------------
# benchmark script
# ---------------------------------------------------------------------------------------
def load_bench():
    spec = importlib.util.spec_from_file_location("bench_asr", ROOT / "scripts" / "bench_asr.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BenchHelpersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bench = load_bench()

    def test_term_counting_is_case_insensitive_and_whole_term(self):
        b = self.bench
        self.assertEqual(b.count_term("FDA는 fda, FDAs, an FDA.", "FDA"), 3)
        self.assertEqual(b.count_term("The 510(k) and the 510(K) path", "510(k)"), 2)
        self.assertEqual(b.count_term("PC, PCs, MPC", "PC"), 1)
        self.assertEqual(b.count_term("AcmeScan-CXR와 AcmeScan-CT", "AcmeScan"), 2)
        self.assertEqual(b.count_term("애크미 팀과 애크미", "애크미"), 2)
        self.assertEqual(dict(b.vocabulary_hits("FDA and HIPAA and FDA", ["FDA", "HIPAA", "BAA"])), {"FDA": 2, "HIPAA": 1})

    def test_number_inventory(self):
        text = ("The price is $2.00 per patient, about 1,200,000 won, or 2.5 달러 and 11월 3일. Meeting on March 5th at 3:30 PM, 2026-10-07, "
                "15% share, 10000 units, 3시 30분.")
        inv = self.bench.number_inventory(text)
        self.assertEqual(set(inv["price"]), {"$2.00", "1,200,000 won", "2.5 달러"})
        self.assertEqual(set(inv["date"]), {"11월 3일", "march 5th", "2026-10-07"})
        self.assertEqual(set(inv["time"]), {"3:30 pm", "3시 30분"})
        self.assertEqual(set(inv["percent"]), {"15%"})
        self.assertEqual(set(inv["number"]), {"10000"})                      # nothing is counted twice

    def test_load_audio_reads_wav_m4a_mp4_and_slices(self):
        import wave
        b = self.bench
        t = np.arange(48000 * 6) / 48000
        tone = (0.4 * np.sin(2 * np.pi * 1000 * t)).astype(np.float32)
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            wavio.write_wav_int16(d / "mono48k.wav", tone, 48000)
            x = b.load_audio(d / "mono48k.wav", 1.0, 2.0)
            self.assertEqual((x.dtype, len(x)), (np.float32, 32000))
            self.assertAlmostEqual(float(np.abs(np.fft.rfft(x)).argmax() * 16000 / len(x)), 1000.0, delta=1.0)
            self.assertEqual(len(b.load_audio(d / "mono48k.wav", 0.0, 0.0)), 6 * 16000)             # duration 0 = to the end
            self.assertEqual(len(b.load_audio(d / "mono48k.wav", 4.0, 99.0)), 2 * 16000)            # slice clipped to the file
            with self.assertRaises(SystemExit):
                b.load_audio(d / "mono48k.wav", 10.0, 1.0)                                          # nothing left
            with self.assertRaises(SystemExit):
                b.load_audio(d / "nope.wav", 0.0, 0.0)
            # stereo 16-bit with a broken header (size 0) at 16 kHz
            pcm = np.repeat((tone[::3] * 32767).astype("<i2"), 2)
            with wave.open(str(d / "st.wav"), "wb") as w:
                w.setnchannels(2); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm.tobytes())
            raw = bytearray((d / "st.wav").read_bytes())
            raw[40:44] = b"\x00\x00\x00\x00"
            (d / "st.wav").write_bytes(bytes(raw))
            self.assertEqual(len(b.load_audio(d / "st.wav", 0, 0)), 6 * 16000)
            if audioprep.afconvert_path():
                audioprep.encode_m4a(d / "mono48k.wav", d / "a.m4a", 64000)
                x = b.load_audio(d / "a.m4a", 0.0, 3.0)
                self.assertAlmostEqual(len(x) / 16000, 3.0, delta=0.05)
                subprocess.run([audioprep.afconvert_path(), "-f", "mp4f", "-d", "aac", str(d / "mono48k.wav"), str(d / "v.mp4")], check=True, capture_output=True)
                x = b.load_audio(d / "v.mp4", 0.0, 0.0)
                self.assertAlmostEqual(len(x) / 16000, 6.0, delta=0.05)
                self.assertAlmostEqual(float(np.abs(np.fft.rfft(x)).argmax() * 16000 / len(x)), 1000.0, delta=2.0)

    def test_reports_with_two_models_and_a_failed_one(self):
        b = self.bench
        mk = lambda slug, texts: {"model": slug, "slug": slug, "error": None, "engine": "whisper", "language": "ko", "load_s": 1.0, "asr_s": 2.0, "wall_s": 3.0,
                                  "segments": [{"start": 5.0 * i, "end": 5.0 * i + 4, "lang": "ko", "text": t, "avg_logprob": -0.2, "no_speech_prob": 0.0}
                                               for i, t in enumerate(texts)],
                                  "dropped": [{"start": 1, "end": 2, "text": "x", "reason": "strong_phantom: p"}], "dropped_by_reason": {"strong_phantom": 1},
                                  "info": {"vad": "silero", "chunks": 2, "words": 10, "loops_collapsed": 1, "prompt_retries": 1}, "text": "\n".join(texts)}
        results = [mk("model_a", ["FDA 510(k) is $2.00", "Acme met Fabrikam-Health"]), mk("model_b", ["FDA 510(k) is $2.10", "애크미 met Fabrikam-Health"]),
                   {"model": "broken", "slug": "broken", "error": "ModelNotAvailable: no", "wall_s": 0.1}]
        comparison = b.render_comparison(results, 20.0, 5.0)
        self.assertIn("| time | model_a | model_b |", comparison)
        self.assertIn("| 00:00:05 | Acme met Fabrikam-Health | 애크미 met Fabrikam-Health |", comparison)
        vocab = b.render_vocabulary(results, ["FDA", "Acme", "Fabrikam-Health"])
        self.assertIn("| Acme | 1 | 0 |", vocab)
        self.assertIn("**distinct terms hit** | **3/3** | **2/3**", vocab)
        numbers = b.render_numbers(results)
        self.assertIn("`$2.00` * | 1 | 0 |", numbers)
        rows = b.summary_rows(results, 20.0)
        self.assertEqual(rows[0]["rtf"], 0.1)
        self.assertEqual(rows[2]["error"], "ModelNotAvailable: no")
        table = b.format_table(rows)
        self.assertIn("model_a", table)
        self.assertTrue(table.splitlines()[-1].startswith("broken: ERROR"))


@needs_tiny
@needs_tts
class BenchScriptRunTest(unittest.TestCase):
    def test_runs_with_the_tiny_model_and_writes_the_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "run"
            env = dict(os.environ)
            env.setdefault("MCAP_SILERO_MODEL", str(Path(tmp) / "no-silero.onnx"))      # never look into the real SUPPORT_DIR
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "bench_asr.py"), "--audio", str(TTS / "mix_ko_en_ko_codeswitch.wav"), "--start", "2",
                 "--duration", "30", "--models", TINY, "mlx-community/not-a-real-model-xyz", "--language-mode", "auto-region",
                 "--prompt-style", "frame+list", "--out", str(out), "--no-download", "-q"],
                capture_output=True, text=True, timeout=600, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr[-2000:])
            slug = "mlx-community_whisper-tiny-mlx"
            for name in ("comparison.md", "vocabulary.md", "numbers.md", "summary.md", "summary.json", f"{slug}/transcript.md", f"{slug}/segments.json"):
                self.assertTrue((out / name).is_file(), name)
            summary = json.loads((out / "summary.json").read_text())
            by_model = {m["model"]: m for m in summary["models"]}
            self.assertGreater(by_model[slug]["segments"], 0)
            self.assertGreater(by_model[slug]["rtf"], 0)
            self.assertIn("error", by_model["mlx-community_not-a-real-model-xyz"])
            self.assertIn("RTF", proc.stdout)
            md = (out / slug / "transcript.md").read_text()
            self.assertTrue(md.startswith("# Transcript\n"))
            self.assertIn("[00:00:", md)
            self.assertIn("| time |", (out / "comparison.md").read_text())
            segs = json.loads((out / slug / "segments.json").read_text())
            self.assertTrue(all(s["end"] <= 30.5 for s in segs["segments"]))      # slice-relative times


if __name__ == "__main__":
    unittest.main()
