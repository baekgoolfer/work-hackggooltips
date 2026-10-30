"""ASR stage (SPEC 7 step 2, 12.2, 13.2): VAD -> chunks -> per-chunk transcription -> post-filter -> echo -> transcript.json.

Per track (mic first, then remote, sequentially):

1. speech regions from ``vad.detect_speech`` (Silero or energy);
2. languages: ``ASR_LANGUAGE=ko|en`` forces one language; ``auto`` runs the per-region language ID restricted to
   ``ASR_LANGUAGES`` (default ko,en; ``region_languages``: probe <= 16 regions, single-language fast path ONLY when every
   probe agrees with p >= 0.95, otherwise every region >= 1 s is classified: >= 2.5 s regions may leave the track language
   at p >= 0.90, 1-2.5 s regions only when confident, shorter ones inherit their neighbours);
3. regions are packed into <= 28 s chunks (a language change always starts a new chunk);
4. ONE ``engine.transcribe_chunk`` call per chunk so the vocabulary prompt is applied to every chunk; the prompt is
   budgeted with the real tokenizer; a chunk that looped, parroted the prompt or has a poor mean log-prob is retried once
   WITHOUT the prompt and the retry is used only when it is clearly better;
   ``ASR_STRATEGY=dual`` (the default; a local engine that uses the prompt, never an external one) decodes every chunk a second time WITHOUT
   the prompt and ``asr_reconcile.reconcile`` merges the two answers per chunk before step 5 (the plain decode restores short utterances and
   wins where the prompt bent a number); ``single`` (what every version before dual did) makes the one decode above;
5. ``postfilter`` removes phantom phrases / loops / low-confidence junk, segments without a letter or digit (``no-content``) and a lone
   prompt term the decoder is unsure of (every drop is logged and counted).

Before step 1 the microphone track goes through the offline echo canceller (``aec.cancel_echo``, SPEC 14.2, ``MIC_AEC``):
the remote (system audio) track is the clean reference of what the speakers played. Only the ASR input of the mic track is
replaced by the cleaned audio; the archived ``mic.m4a`` and the audio used by the ``suppress_echo`` safety net stay the raw
microphone signal. The canceller's statistics are stored in ``transcript.json["aec"]``.

Then the mic track is checked for speaker echo of the remote track (``suppress_echo``: whole segments, and short fragments that
repeat words of a nearby Remote segment), vocabulary aliases are applied
and everything is assembled into the SPEC 4.4 dict.

Block upload (an external engine with ``accepts_blocks``, ``asr_engines.BlockUpload``: CLOVA, the OpenAI-style providers): billing rounds up
per request, so instead of one request per 28 s chunk ``transcribe_track`` concatenates the consecutive chunks of ``plan_chunks`` (each already
carries its 0.3 s pad; the silence between them is cut out) into blocks of up to ``ASR_CLOUD_BLOCK_SECONDS`` (``pack_blocks``), makes ONE
``engine.transcribe_chunk`` call per block and maps every returned segment time back to the original timeline through the cumulative offsets of
the chunks in the block (``block_times``). Dual-pass is never used for such an engine; ``stats.<track>.blocks`` / ``block_audio_s`` count what was
sent (no content). Every other engine takes the same path as before with one unit per chunk: the golden fixtures freeze that. Before the chunks of
a track the engine hears which track it is (``Engine.set_track_context``: track, solo, platform; CLOVA decides speaker separation with it).
A block is packed for the engine that takes the chunks NOW (a router's primary, its fallback once the primary is out for good). A block that is
not answered as one call (``EngineBlockDeclined``: the service refused its length, or the primary was bypassed and the fallback takes chunks
only, as Whisper and Azure do) is taken apart: smaller blocks when the engine now takes shorter ones, else its chunks one by one, each with its
own language ID or detection and routed like any chunk (``split_block``; ``stats.<track>.split_blocks`` counts them).

Engine seam (SPEC 18): the engine comes from ``_engine_for`` (``get_engine(cfg.asr_model)`` unless a policy
decision is attached to the config), the per-chunk prompt retry lives in ``decode_chunk`` (a server reference implementation calls the
same function), an engine with ``uses_prompt=False`` skips the prompt, the tokenizer and the retry (its ``prompt_text_seen()`` feeds the
echo guard), an engine without confidence numbers (``confidence`` opaque/none: None values) skips the numeric post-filter rules by itself,
and an external engine adds a tag to the progress text and a provenance block to the transcript. Whatever an engine declares is checked
before it is used: the chunk limit must be a number of 1 to 28 s (``asr_engines.chunk_limit``), the provenance block is cleaned to the
SPEC 18 keys, and an external engine whose record is unusable still leaves a minimal ``privacy: unknown`` one. A ``load()`` or language
ID that cannot reach the external engine is ``AsrUnreachable``, like a track whose every chunk could not be sent. Without such an engine
every line below does what it did before: the golden fixtures of pipeline/tests/golden freeze that.
"""
from __future__ import annotations

import bisect
import difflib
import functools
import importlib
import json
import logging
import math
import re
import sys
import time
import unicodedata
from collections import Counter, deque
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from . import asr_reconcile, logsafe
from . import vad as vadmod
from .asr_engines import (LID_CANDIDATES, EngineBlockDeclined, EngineTransient, EngineUnavailable, WhisperEngine, engine_caps, get_engine,
                          parse_languages)
from .audioprep import TRACK_NAMES, PreparedAudio
from .config import Config
from .transcript import REMOTE_LABEL, make_transcript
from .vocab import Vocab, apply_aliases

log = logging.getLogger("mcap.asr")

SR = 16000
ASR_PROMPT_TOKENS = 140          # 120 cut the terms at the end of a long list; 140 keeps a list of about 30 short terms plus the ko frame; Whisper keeps only the last 223 prompt tokens
DUAL_KEYS = ("chunks", "conflicts", "plain_chosen", "restored")     # what ASR_STRATEGY=dual records in transcript.json (stats.<track>.dual, asr.dual)
Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


class AsrUnreachable(RuntimeError):
    """Every chunk of a track failed with ``EngineTransient`` (the external engine could not be reached at all). The pipeline reports
    it as a waiting condition (``asr_unreachable``), not as a failed meeting."""


def _engine_for(cfg: Config, vocab: Vocab, progress: Progress | None = None):
    """The engine for this run. Without a policy decision (``cfg.asr_decision`` is None: the default, and every config that was not built by
    the lane resolver) this is ``get_engine(cfg.asr_model)`` exactly as before; with one the router builds it (``asr_router.build_engine``)."""
    decision = getattr(cfg, "asr_decision", None)
    if decision is None:
        return get_engine(cfg.asr_model)
    try:
        asr_router = importlib.import_module(".asr_router", __package__)
    except ImportError as exc:                   # the router belongs to a later package: never fall back to a different engine silently
        raise EngineUnavailable(f"ASR router is not installed ({exc})") from exc
    return asr_router.build_engine(cfg, vocab, progress=progress)


def _progress_tag(engine) -> str:
    """"[server]" / "[local fallback]" for an external engine, "" for a local one (``Engine.progress_tag``; a double without the method
    has none). Brackets are added when the engine did not write them. Never raises: a progress text must not cost a transcript."""
    try:
        tag = str(getattr(engine, "progress_tag", lambda: "")() or "").strip()
    except Exception:
        return ""
    if tag and not tag.startswith("["):
        tag = f"[{tag}]"
    return tag


def _prompt_text_seen(engine) -> str | None:
    """What an engine that builds its own prompt says it used (``Engine.prompt_text_seen``), or None."""
    try:
        text = getattr(engine, "prompt_text_seen", lambda: None)()
    except Exception:
        return None
    return text if isinstance(text, str) and text.strip() else None


# --------------------------------------------------------------------------------------
# prompt
# --------------------------------------------------------------------------------------
def build_asr_prompt(vocab: Vocab, tokenizer, max_tokens: int = 200, language: str | None = None,
                     frames: dict[str, str] | None = None) -> str:
    """Initial prompt from the vocabulary, never longer than ``max_tokens`` tokens (counted the way mlx-whisper encodes it:
    ``" " + prompt.strip()``). ``tokenizer`` is any object with ``encode(str) -> list``.

    Terms are taken in file order (= priority) while they fit, and written in REVERSE so the most important term comes
    last: Whisper keeps only the last tokens of an over-long prompt and recent tokens influence the decoder most.
    ``language`` ("ko"/"en") prefixes a frame that makes the prompt look like a transcript of that language (SPEC 13.2);
    None gives the bare comma list, and so does any language that has no frame (ja, zh, ... : the term list alone, SPEC 15).
    An empty string means "no prompt" (callers must pass None to the model).
    """
    terms = list(vocab.terms)
    if not terms:
        return ""
    frame = ""
    if language:
        table = frames if frames is not None else WhisperEngine.prompt_frames
        frame = table.get(language, "")

    def count(text: str) -> int:
        return len(tokenizer.encode(" " + text.strip()))

    if frame and count(frame) > max_tokens:
        return ""
    picked: list[str] = []
    for term in terms:
        if count(frame + ", ".join(reversed(picked + [term]))) <= max_tokens:
            picked.append(term)
    return frame + ", ".join(reversed(picked)) if picked else ""


# --------------------------------------------------------------------------------------
# post filter
# --------------------------------------------------------------------------------------
@dataclass
class Seg:
    start: float
    end: float
    text: str
    lang: str
    avg_logprob: float | None
    no_speech_prob: float | None
    compression_ratio: float | None = None
    temperature: float = 0.0
    chunk: int = 0
    low_conf: bool = False
    loop: bool = False            # a repetition loop was collapsed in the text


def _norm(t: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", t.casefold())).strip()


# Phantom phrases (YouTube / broadcast boilerplate). Dropped when the phrase is (nearly) the whole segment, or when the decoder
# is unsure; a real sentence that merely contains one ("Thank you for watching the demo, any questions?") is kept.
STRONG_PHANTOMS = [
    "thanks for watching", "thank you for watching", "thanks for watching and see you in the next video",
    "thank you for watching and see you in the next video", "thank you for watching and please subscribe",
    "please subscribe", "please subscribe to my channel", "like and subscribe", "don t forget to subscribe",
    "subtitles by the amara org community", "transcript emily beynon", "subtitles by",
    "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "시청 감사합니다", "시청해 주셔서 대단히 감사합니다",
    "구독과 좋아요", "구독 좋아요", "좋아요와 구독", "다음 영상에서 만나요", "다음 시간에 만나요", "한글자막", "자막 제공",
    "ご視聴ありがとうございました", "ご視聴ありがとうございます", "チャンネル登録をお願いします",   # only reachable when ja is an allowed language
]
STRONG_PREFIX = ["mbc 뉴스", "kbs 뉴스", "sbs 뉴스", "ytn", "자막 by", "번역 by"]
PHANTOM_MAX_WORDS = 12          # longer segments are never judged by the phrase list
PHANTOM_OTHER_WORDS = 3         # "(nearly) the whole segment": the phrase at the start or the end with at most this many other words
# Legitimate in meetings but also what Whisper says over noise: dropped only when short AND the decoder itself is clearly unsure
# (no_speech_prob > 0.5 AND avg_logprob < -0.8); on a track with almost no other speech either signal is enough.
WEAK_PHANTOMS = {"thank you", "thanks", "you", "bye", "bye bye", "okay", "ok", "감사합니다", "고맙습니다", "네", "예", "음", "어", "아"}
SPARSE_TRACK_SPEECH_S = 10.0    # "almost no other speech": less than this much non-filler speech in the track

_LOOP_RE = re.compile(r"(.{1,40}?)(?:[\s,.!?]*\1){3,}")
_LETTER = re.compile(r"[^\W\d_]")


def _has_content(text: str) -> bool:
    """A letter or a digit of any script. '!', '...', '?!' and '♪' are punctuation Whisper wrote over silence: no content."""
    return any(c.isalnum() for c in text)


def _prompt_terms(prompt: str | None) -> set[str]:
    """The normalised vocabulary terms inside the prompt(s) (``build_asr_prompt``: 'frame: term, term, ...', one prompt per line).
    The frame sentence in front of the list is not a term."""
    return {t for t in (_norm(piece.rsplit(": ", 1)[-1]) for piece in re.split(r"[,\n]", prompt or "")) if t}

# Scripts that are almost surely a Whisper hallucination in a Korean/English meeting (kana, Han, Cyrillic, Arabic, Thai,
# Devanagari). A script stops being "foreign" when an allowed language (ASR_LANGUAGES) is written in it.
_SCRIPT_RANGES = {"kana": "\u3040-\u30ff", "han": "\u4e00-\u9fff", "cyrillic": "\u0400-\u04ff", "arabic": "\u0600-\u06ff",
                  "thai": "\u0e00-\u0e7f", "devanagari": "\u0900-\u097f"}
_LANG_SCRIPTS: dict[str, tuple[str, ...]] = {"ja": ("kana", "han"), "zh": ("han",), "yue": ("han",), "th": ("thai",)}
_LANG_SCRIPTS.update({c: ("cyrillic",) for c in "ru uk be bg sr mk kk tg mn tt ba".split()})
_LANG_SCRIPTS.update({c: ("arabic",) for c in "ar fa ur ps sd".split()})
_LANG_SCRIPTS.update({c: ("devanagari",) for c in "hi mr ne sa".split()})


@functools.lru_cache(maxsize=32)
def foreign_pattern(languages: tuple[str, ...] = LID_CANDIDATES):
    """Regex of the letters that do not belong to any of ``languages`` (None when every script is allowed)."""
    allowed = {sc for lang in languages for sc in _LANG_SCRIPTS.get(lang, ())}
    ranges = "".join(r for sc, r in _SCRIPT_RANGES.items() if sc not in allowed)
    return re.compile(f"[{ranges}]") if ranges else None


def collapse_loops(text: str) -> str:
    """"아, 아, 아, 아, 아" -> "아". Repeats made only of digits/punctuation ("10000", "1,000,000", "0.0.0.0") are left alone."""
    return _LOOP_RE.sub(lambda m: m.group(1) if _LETTER.search(m.group(1)) else m.group(0), text).strip()


def _strong_phantom(n: str) -> tuple[bool, bool]:
    """``(contains a phantom phrase, the phrase is (nearly) the whole segment)`` for the normalised text ``n``."""
    found = False
    for p in STRONG_PHANTOMS:
        i = n.find(p)
        if i < 0:
            continue
        found = True
        others = (n[:i] + " " + n[i + len(p):]).split()
        if (i == 0 or i + len(p) == len(n)) and len(others) <= PHANTOM_OTHER_WORDS:
            return True, True
    return found, False


def postfilter(segs: list[Seg], *, prompt: str | None = None, echo_ratio_min: float = 0.7, echo_min_words: int = 5,
               cr_max: float = 2.4, ns_max: float = 0.6, lp_min_when_silent: float = -0.7, lp_floor: float = -1.5,
               weak_lp: float = -0.8, weak_ns: float = 0.5, foreign_max: float = 0.3,
               sparse_speech_s: float = SPARSE_TRACK_SPEECH_S, languages: tuple[str, ...] = LID_CANDIDATES):
    """Returns ``(kept, dropped)``; ``dropped`` is a list of ``(seg, reason)`` with reason ``"category: detail"``.
    Segments without confidence numbers (engines that do not report them) skip the numeric checks. Kept segments get
    their loops collapsed (``loop`` set) and ``low_conf`` set (avg_logprob < -1.0).

    ``segs`` should be all candidate segments of ONE track: whether a lone "네" / "OK" is a phantom depends on how much other
    speech the track has. ``languages`` (ASR_LANGUAGES) decides which scripts count as foreign.

    Two drops for what Whisper writes over silence and echo: a segment with no letter or digit at all (``no-content``: "!"), and a
    segment that is nothing but ONE vocabulary term of the prompt ("Acme") while the decoder is unsure of it (log-prob below
    ``weak_lp`` or no-speech above ``weak_ns``: ``prompt_echo``); the same word spoken clearly is a real one-word answer and stays."""
    pattern = foreign_pattern(tuple(languages))
    prompt_words = set(_norm(prompt).split()) if prompt else set()
    prompt_terms = _prompt_terms(prompt)
    verdicts: list[str | None] = []
    for s in segs:
        why = None
        n = _norm(s.text)
        words = n.split()
        if not _has_content(s.text):
            verdicts.append("no-content: no letter or digit")
            continue
        lp, ns, cr = s.avg_logprob, s.no_speech_prob, s.compression_ratio
        echo = (sum(w in prompt_words for w in words) / len(words)) if (prompt_words and words) else 0.0
        letters = [c for c in s.text if unicodedata.category(c).startswith("L")]
        foreign = (len(pattern.findall(s.text)) / max(1, len(letters))) if pattern else 0.0
        unsure = (lp is not None and lp < -0.4) or (ns is not None and ns > 0.2)
        phrase, whole = _strong_phantom(n)
        if cr is not None and cr > cr_max:
            why = f"compression_ratio: {cr:.1f}"
        elif lp is not None and lp < lp_floor:
            why = f"avg_logprob: {lp:.2f} < {lp_floor}"
        elif ns is not None and lp is not None and ns > ns_max and lp < lp_min_when_silent:
            why = f"no_speech: {ns:.2f} with logprob {lp:.2f}"
        elif phrase and len(words) <= PHANTOM_MAX_WORDS and (whole or unsure):
            why = "strong_phantom: known boilerplate phrase" + ("" if whole else " (decoder unsure)")
        elif any(n.startswith(p) for p in STRONG_PREFIX) and unsure:
            why = "broadcast_credit: news/credit prefix"
        elif len(words) >= echo_min_words and echo >= echo_ratio_min:
            why = f"prompt_echo: {echo:.2f} of the words come from the prompt"
        elif n in prompt_terms and ((lp is not None and lp < weak_lp) or (ns is not None and ns > weak_ns)):
            why = f"prompt_echo: lone vocabulary term, decoder unsure (logprob {lp}, no_speech {ns})"
        elif foreign > foreign_max:
            why = f"foreign_script: {foreign:.2f}"
        verdicts.append(why)

    # weak phantoms ("thank you", "네", ...): a lone one in a track that has real speech is almost always a real answer
    other_speech = sum(max(0.0, s.end - s.start) for s, why in zip(segs, verdicts) if why is None and _norm(s.text) not in WEAK_PHANTOMS)
    sparse = other_speech < sparse_speech_s
    kept: list[Seg] = []
    dropped: list[tuple[Seg, str]] = []
    for s, why in zip(segs, verdicts):
        lp, ns = s.avg_logprob, s.no_speech_prob
        if why is None and _norm(s.text) in WEAK_PHANTOMS and s.end - s.start <= 3.0:
            silent = ns is not None and ns > weak_ns
            doubtful = lp is not None and lp < weak_lp
            if (silent or doubtful) if sparse else (silent and doubtful):
                why = ("weak_phantom: short filler with low confidence" +
                       (f" in a track with only {other_speech:.0f} s of other speech" if sparse else ""))
        if why:
            dropped.append((s, why))
            continue
        collapsed = collapse_loops(s.text)
        s.loop = collapsed != s.text.strip()
        s.text = collapsed
        s.low_conf = lp is not None and lp < -1.0
        if s.text:
            kept.append(s)
    return kept, dropped


# --------------------------------------------------------------------------------------
# language ID per region
# --------------------------------------------------------------------------------------
def region_languages(engine, x: np.ndarray, regions, languages: tuple[str, ...] = LID_CANDIDATES, *, pad_s: float = 0.2,
                     min_probe_s: float = 3.0, min_region_s: float = 2.5, min_weak_s: float = 1.0, flip_conf: float = 0.90,
                     weak_conf: float = 0.95, mono_conf: float = 0.95, n_probe: int = 16):
    """Returns ``(track_language, labels[len(regions)], info)``. The language ID only chooses from ``languages`` (ASR_LANGUAGES,
    probabilities renormalised over that set by the engine). SPEC 13.2 / 15:

    1. probe up to ``n_probe`` regions of >= ``min_probe_s`` spread over the track -> duration-weighted track prior;
    2. the single-language fast path is taken ONLY when EVERY probe agrees on the prior at p >= ``mono_conf`` (a minority
       language in 5-25 % of the regions is missed by a handful of probes most of the time, so the bar is "all 16 agree");
    3. otherwise every region >= ``min_weak_s`` is classified (batched). A region >= ``min_region_s`` leaves the track language
       only when another language has p >= ``flip_conf``; a weak region (``min_weak_s``..``min_region_s``) takes its own
       language only when p >= ``weak_conf``; every undecided region and every region shorter than ``min_weak_s`` inherits the
       label of its neighbours (both agree: that label; they differ: the nearer one).
    """
    langs = tuple(languages) or LID_CANDIDATES
    n = len(regions)
    if len(langs) == 1 or n == 0:                          # nothing to choose from
        lang = langs[0]
        return lang, [lang] * n, {"track_language": lang, "monolingual_fast_path": True, "probes": 0, "languages": list(langs)}

    def clip(i):
        a, b = max(0, int((regions[i][0] - pad_s) * SR)), min(len(x), int((regions[i][1] + pad_s) * SR))
        return x[a:b]

    def classify(idx):
        return dict(zip(idx, engine.detect_languages([clip(i) for i in idx], langs))) if idx else {}

    def dur(i):
        return regions[i][1] - regions[i][0]

    def prior(pp, idx):
        total = sum(dur(i) for i in idx) or 1.0
        score = {c: sum(dur(i) * pp[i][c] for i in idx) / total for c in langs}
        return max(langs, key=lambda c: score[c]), score

    pool = ([i for i in range(n) if dur(i) >= min_probe_s] or [i for i in range(n) if dur(i) >= min_weak_s] or list(range(n)))
    probe = sorted({pool[int(round(k))] for k in np.linspace(0, len(pool) - 1, min(n_probe, len(pool)))})
    pp = classify(probe)
    track, score = prior(pp, probe)
    mono = all(pp[i][track] >= mono_conf for i in probe)
    info = {"track_language": track, "track_scores": {c: round(v, 3) for c, v in score.items()}, "monolingual_fast_path": mono,
            "probes": len(probe), "languages": list(langs)}
    if mono:
        return track, [track] * n, info

    pp.update(classify([i for i in range(n) if dur(i) >= min_weak_s and i not in pp]))
    strong = [i for i in pp if dur(i) >= min_region_s]
    if strong:                                             # a better prior now that every long region has been classified
        track, score = prior(pp, strong)
        info.update(track_language=track, track_scores={c: round(v, 3) for c, v in score.items()})
    decided: dict[int, str] = {}
    for i, p in pp.items():
        top = p["top"]
        if dur(i) >= min_region_s:
            if top != track and p[top] >= flip_conf:
                decided[i] = top
            elif top == track or p[track] >= 0.5:
                decided[i] = track
        elif p[top] >= weak_conf:
            decided[i] = top
    labels = [decided.get(i) for i in range(n)]
    anchors = sorted(decided)
    for i in range(n):
        if labels[i] is None:
            k = bisect.bisect_left(anchors, i)                  # anchors[:k] lie before region i, anchors[k:] after it (i itself is no anchor)
            before, after = (anchors[k - 1] if k else None), (anchors[k] if k < len(anchors) else None)
            prev_l, next_l = (labels[before] if before is not None else None), (labels[after] if after is not None else None)
            if prev_l and next_l and prev_l != next_l:      # neighbours disagree: the nearer one
                gap_prev, gap_next = regions[i][0] - regions[before][1], regions[after][0] - regions[i][1]
                labels[i] = prev_l if gap_prev <= gap_next else next_l
            else:
                labels[i] = prev_l or next_l or track
    info["lid_regions"] = len(pp)
    info["weak_regions"] = sum(1 for i in pp if dur(i) < min_region_s)
    info["language_switches"] = sum(1 for a, b in zip(labels, labels[1:]) if a != b)
    return track, labels, info


# --------------------------------------------------------------------------------------
# one track
# --------------------------------------------------------------------------------------
@dataclass
class TrackResult:
    track: str
    segments: list[dict]                      # kept segments: start, end, lang, text, avg_logprob, no_speech_prob
    dropped: list[dict]                       # {"start", "end", "text", "reason"}
    language: str | None                      # language with the most transcribed speech time, None without speech
    info: dict = field(default_factory=dict)  # vad backend, speech_s, chunks, retries, timings, ...

    @property
    def dropped_by_reason(self) -> dict[str, int]:
        return dict(Counter(d["reason"].split(":")[0] for d in self.dropped))


def _mean_lp(segments: list[dict]) -> float | None:
    vals = [s["avg_logprob"] for s in segments if s.get("avg_logprob") is not None]
    return float(np.mean(vals)) if vals else None


def _suspicious(res: dict, prompt_words: set[str]) -> bool:
    """Looped, parroted the prompt, truncated, or low mean confidence -> worth one retry without the prompt."""
    if res.get("truncated"):
        return True
    for q in res["segments"]:
        words = _norm(q["text"]).split()
        if (q.get("compression_ratio") or 0.0) > 2.4 or (len(words) >= 5 and sum(w in prompt_words for w in words) / len(words) >= 0.7):
            return True
    lp = _mean_lp(res["segments"])
    return lp is not None and lp < -1.0


def _better(alt: dict, orig: dict) -> bool:
    """Is the no-prompt retry clearly better (no loop and +0.1 mean log-prob; without log-probs: not truncated vs truncated)?"""
    if not alt["segments"] or any((q.get("compression_ratio") or 0.0) > 2.4 for q in alt["segments"]):
        return False
    la, lo = _mean_lp(alt["segments"]), _mean_lp(orig["segments"])
    if la is None or lo is None:
        return bool(orig.get("truncated")) and not alt.get("truncated")
    return la > lo + 0.1


def decode_chunk(engine, audio: np.ndarray, lab: str, prompt: str | None, prompt_words: set[str], stats: Counter,
                 log_label: str = "") -> dict:
    """ONE chunk through ``engine`` with the vocabulary prompt; a chunk that looped, parroted the prompt, was truncated or has a poor mean
    log-prob is retried once WITHOUT the prompt and the retry replaces the first answer only when it is clearly better (``_better``).
    ``stats`` counts ``prompt_retries`` / ``retries_accepted``; ``log_label`` ("remote chunk 3 (12.0-20.5s)") names the chunk in the log.
    No prompt (``prompt`` falsy: prompt style none, or an engine that builds its own) means no retry. This is the loop body that used
    to be inlined in ``transcribe_track``; the reference ASR server calls it too, so the relay output goes through the same heuristics."""
    res = engine.transcribe_chunk(audio, lab or None, prompt)
    if prompt and _suspicious(res, prompt_words):
        stats["prompt_retries"] += 1
        alt = engine.transcribe_chunk(audio, lab or None, None)
        if _better(alt, res):
            stats["retries_accepted"] += 1
            log.info("%s: retry without prompt accepted", log_label or "chunk")
            res = alt
    return res


def asr_strategy(cfg) -> str:
    """ASR_STRATEGY as ``single`` or ``dual``; anything else, and a config object without the field, reads as ``single``."""
    return "dual" if str(getattr(cfg, "asr_strategy", "single") or "").strip().lower() == "dual" else "single"


def decode_plain(engine, audio: np.ndarray, lab: str, log_label: str = "") -> dict | None:
    """Pass N of ``ASR_STRATEGY=dual``: the same chunk and language without a prompt. None when it failed: the extra pass is an improvement,
    never a reason to lose a chunk that pass P already decoded."""
    try:
        return engine.transcribe_chunk(audio, lab or None, None)
    except Exception as exc:
        log.warning("%s: plain pass failed (%s: %s), the prompted pass is used alone", log_label or "chunk", type(exc).__name__, exc)
        return None


def _reconcile_chunk(prompted: dict, plain: dict, lab: str, terms, counts: Counter) -> list[tuple[dict, str]]:
    """The segments of pass P and pass N of one chunk merged by ``asr_reconcile.reconcile``, each with the language code of the pass it came
    from; ``counts`` collects chunks / equal / conflicts / plain_chosen / restored / rejected."""
    def tag(res: dict) -> list[dict]:
        return [{**sg, "lang": res.get("language") or lab} for sg in res["segments"]]

    merged = asr_reconcile.reconcile(tag(prompted), tag(plain), terms)
    counts["chunks"] += 1
    for key in ("equal", "conflicts", "plain_chosen", "restored", "rejected"):
        counts[key] += getattr(merged, key)
    return [(sg, sg["lang"]) for sg in merged.segments]


_LANG_NAMES = {"korean": "ko", "english": "en"}


def _lang_code(lang) -> str:
    lang = (lang or "").strip().lower()
    return _LANG_NAMES.get(lang, lang)


def _seg_dict(s: Seg, vocab: Vocab) -> dict:
    return {
        "start": round(s.start, 2), "end": round(s.end, 2), "lang": s.lang,
        "text": apply_aliases(s.text, vocab),
        "avg_logprob": None if s.avg_logprob is None else round(s.avg_logprob, 3),
        "no_speech_prob": None if s.no_speech_prob is None else round(s.no_speech_prob, 3),
    }


# --------------------------------------------------------------------------------------
# blocks: an engine that takes blocks of speech instead of 28 s chunks (asr_engines.BlockUpload)
# --------------------------------------------------------------------------------------
BLOCK_GAP_EPS = 1e-6                 # chunks that touch (a cut inside one long region) are one stretch of the original audio
BLOCK_START_SLACK = 0.05             # a segment that starts this close to the end of its audio is the decoder running on


def _members(engine) -> list:
    """The engines behind a router (``asr_router.RoutedEngine``: primary, then fallback) or the engine itself. A router can only exist when its
    module has been imported, so the module is looked up, never imported here."""
    router = sys.modules.get(f"{__package__}.asr_router")
    if router is not None and isinstance(engine, router.RoutedEngine):
        return [m for m in (engine.primary, engine.fallback) if m is not None]
    return [engine]


def _lead_member(engine):
    """The engine that takes the chunks now: a router's primary, or its fallback once the primary is out for good (``RoutedEngine.lead``); the
    engine itself otherwise."""
    router = sys.modules.get(f"{__package__}.asr_router")
    return engine.lead() if router is not None and isinstance(engine, router.RoutedEngine) else engine


def block_seconds(engine) -> float:
    """Seconds of one upload block when the engine that takes the chunks now (``_lead_member``) is external and declares ``accepts_blocks``
    (``engine_caps``), else 0.0: 28 s chunks, as every earlier version did. A router whose primary is out for good (it did not load: no key, no
    model name) packs for its fallback, which is a local Whisper engine in the usual setup and takes chunks."""
    caps = engine_caps(_lead_member(engine))
    return caps.max_block_s if caps.accepts_blocks and caps.kind != "local" else 0.0


def pack_blocks(chunks, max_block_s: float) -> list:
    """``[(pieces, label)]``: the ``(start, end, label)`` chunks of ``vad.plan_chunks`` packed, in order, into blocks of at most ``max_block_s``
    seconds of audio (a chunk is never cut; a change of label starts a new block). ``pieces`` is ``[(offset_s, start, end)]``: where the audio of
    the chunk begins INSIDE the block (cumulative, counted in samples) and which span of the original track it is."""
    limit = int(max_block_s * SR)
    units: list = []
    pieces: list = []
    used, label = 0, None
    for a, b, lab in chunks:
        n = int(b * SR) - int(a * SR)
        if pieces and (lab != label or used + n > limit):
            units.append((pieces, label))
            pieces, used = [], 0
        if not pieces:
            label = lab
        pieces.append((used / SR, a, b))
        used += n
    if pieces:
        units.append((pieces, label))
    return units


def unit_audio(x: np.ndarray, pieces) -> np.ndarray:
    """The audio of one unit: the slice of one chunk, or the pieces of a block concatenated."""
    if len(pieces) == 1:
        return x[int(pieces[0][1] * SR): int(pieces[0][2] * SR)]
    return np.concatenate([x[int(a * SR): int(b * SR)] for _, a, b in pieces])


def split_block(engine, pieces, label: str) -> list:
    """The units a declined block (``EngineBlockDeclined``) becomes: blocks as long as the engine takes now (it may have learned what its service
    refuses), else one unit per chunk. Always more than one unit, so a unit is never declined for ever."""
    limit = block_seconds(engine)
    units = pack_blocks([(a, b, label) for _, a, b in pieces], limit) if limit else []
    return units if len(units) > 1 else [([(0.0, a, b)], label) for _, a, b in pieces]


def block_times(pieces, start: float, end: float):
    """``(start, end)`` on the original timeline of a segment that the engine placed at ``start``..``end`` seconds inside its unit, or None when it
    starts after the unit's audio ended (the decoder ran on: nothing is there). The piece that holds ``start`` maps it (``a + start - offset``).
    The end goes through the piece that holds it; when the segment runs over into a chunk that does not touch the one it started in (silence was
    cut out between them) it is cut at the end of the last chunk that touches, and its text is kept whole. A start in the last 0.05 s of a
    piece that is not the last one is the first word of the next piece. For a unit of one chunk this is ``min(a + t, b)`` as it always was."""
    offsets = [piece[0] for piece in pieces]
    k = max(bisect.bisect_right(offsets, start) - 1, 0)
    offset, a, b = pieces[k]
    begin = a + (start - offset)
    if begin >= b - BLOCK_START_SLACK:
        if k + 1 == len(pieces):
            return None
        k += 1
        offset, a, b = pieces[k]
        begin = a
    last = max(bisect.bisect_right(offsets, end) - 1, k)
    stop = k
    while stop < last and pieces[stop + 1][1] - pieces[stop][2] <= BLOCK_GAP_EPS:
        stop += 1
    offset, a, b = pieces[stop]
    finish = b if stop < last else min(a + (end - offset), b)
    return begin, max(begin, finish)


def _tell_track_context(engine, track: str, context: dict | None) -> None:
    """``Engine.set_track_context`` of the engine, or of every member behind a router. An engine without the method (a test double) hears nothing;
    one that fails is logged: the context only tunes a vendor request, it is never a reason to lose a track."""
    info = {"solo": True, "platform": "", **(context or {})}
    for member in _members(engine):
        hook = getattr(member, "set_track_context", None)
        if callable(hook):
            try:
                hook(track=track, solo=bool(info["solo"]), platform=str(info["platform"] or ""))
            except Exception as exc:
                log.warning("%s: the engine did not take the track context (%s)", track, type(exc).__name__)


def transcribe_track(x: np.ndarray, engine, cfg: Config, vocab: Vocab, *, track: str = "track", language: str | None = None,
                     prompt_style: str = "frame+list", prompt_tokens: int = ASR_PROMPT_TOKENS, vad: vadmod.VadResult | None = None,
                     progress: Progress = _noop, context: dict | None = None) -> TrackResult:
    """Transcribe one 16 kHz mono float32 track.

    ``language``: None -> ``cfg.asr_language``; "auto" -> per-region ko/en ID; "ko"/"en"/other code -> forced.
    ``prompt_style``: "frame+list" (default, SPEC 13.2) | "list" (bare vocabulary list) | "none"; ``prompt_tokens``: its token budget.
    ``vad``: precomputed speech regions (benchmarks share one VAD result between models).
    ``context``: ``{"solo": the only track of the meeting, "platform": the session's platform}`` for ``Engine.set_track_context`` (default: solo).
    """
    if prompt_style not in ("frame+list", "list", "none"):
        raise ValueError(f"unknown prompt_style {prompt_style!r}")
    logsafe.configure(getattr(cfg, "log_content", True))
    t_begin = time.time()
    x = np.asarray(x, dtype=np.float32)
    total = len(x) / SR
    mode = (language if language is not None else (cfg.asr_language or "auto")).strip().lower()
    langs = parse_languages(cfg.asr_languages)                      # ValueError with a clear message for an unknown code
    script_langs = langs if mode == "auto" or mode in langs else langs + (mode,)     # a forced language's script is never "foreign"
    progress(f"detecting speech {track}")
    vad = vad if vad is not None else vadmod.detect_speech(x, cfg.asr_vad, cfg.support_dir)
    regions = vad.regions
    info: dict = {"duration_s": round(total, 1), "vad": vad.label, "vad_info": vad.info, "regions": len(regions),
                  "speech_s": round(vad.speech_seconds, 1), "language_mode": mode, "languages": list(langs),
                  "prompt_style": prompt_style}
    if vad.degraded:
        info["vad_degraded"] = vad.degraded
    if not regions:
        log.info("%s: no speech found (%s VAD)", track, vad.label)
        return TrackResult(track, [], [], None, info)

    try:
        engine.load()
    except EngineTransient as exc:                # the health check of an external engine found nobody there: a waiting condition, not a failed meeting
        raise AsrUnreachable(f"ASR unreachable: the engine did not load for the {track} track: {type(exc).__name__}: {exc}") from exc
    caps = engine_caps(engine)                    # after load(): a routed engine may have settled on its fallback while loading
    _tell_track_context(engine, track, context)
    t_lid = time.time()
    if mode == "auto" and caps.supports_lid:
        progress(f"detecting language {track}")
        try:
            _, labels, linfo = region_languages(engine, x, regions, langs)
        except EngineTransient as exc:            # language ID is a request to the engine too
            raise AsrUnreachable(f"ASR unreachable: language detection of the {track} track did not reach the engine: "
                                 f"{type(exc).__name__}: {exc}") from exc
        info.update(linfo)
    elif mode == "auto":
        labels = [""] * len(regions)               # the engine decides on its own
    else:
        labels = [mode] * len(regions)
    info["lid_s"] = round(time.time() - t_lid, 2)

    chunk_params = engine.chunk_params if isinstance(getattr(engine, "chunk_params", None), dict) else {}
    chunk_params = {**chunk_params, "max_chunk_s": caps.max_chunk_s}   # engine_caps' one rule: 28.0 unless the engine declares a shorter, usable limit
    chunks = vadmod.plan_chunks(regions, vad.db, total, labels=labels, region_probs=vad.region_probs, **chunk_params)
    block_s = block_seconds(engine)                 # 0.0 for every engine that takes 28 s chunks
    units = pack_blocks(chunks, block_s) if block_s else [([(0.0, a, b)], lab) for a, b, lab in chunks]
    n = len(units)
    info["chunks"] = len(chunks)
    if block_s:
        info.update(blocks=n, block_s=block_s)
    sent_s = 0.0
    prompts: dict[str, str | None] = {}
    for lab in {lab for _, _, lab in chunks}:
        if prompt_style == "none" or not caps.uses_prompt:           # no prompt: also for an engine that builds its own (no tokenizer needed)
            prompts[lab] = None
            continue
        text = build_asr_prompt(vocab, engine.tokenizer, prompt_tokens, language=(lab or "en") if prompt_style == "frame+list" else None,
                                frames=engine.prompt_frames)
        prompts[lab] = text or None
        used = [t for t in vocab.terms if re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", text)] if text else []
        left_out = "" if len(used) == len(vocab.terms) else f" (left out: {', '.join(t for t in vocab.terms if t not in used)})"
        log.info("%s prompt [%s]: %d tokens, %d/%d vocabulary terms%s", track, lab or "-",
                 len(engine.tokenizer.encode(" " + text.strip())) if text else 0, len(used), len(vocab.terms), left_out)
    prompt_words = set(_norm(" ".join(p for p in prompts.values() if p)).split())
    # ASR_STRATEGY=dual only for a local engine that takes the prompt and reports log-probs (the reconcile rules read them); else single
    dual = (asr_strategy(cfg) == "dual" and caps.kind == "local" and caps.uses_prompt and caps.confidence == "logprob"
            and prompt_style != "none")
    dual_counts: Counter = Counter()

    segs: list[Seg] = []
    stats: Counter = Counter()
    last_error: Exception | None = None
    unreachable = 0                               # chunks that failed with EngineTransient (the external engine could not be reached)
    ran = 0                                       # units decoded (or failed): a block that is taken apart counts through its parts
    t_asr = time.time()
    work = deque(enumerate(units))
    while work:
        i, (pieces, lab) = work.popleft()
        ran += 1
        a, b = pieces[0][1], pieces[-1][2]
        tag = _progress_tag(engine)               # "" for a local engine: the message is the one it always was
        progress(f"transcribing {track} {i + 1}/{n}" + (f" {tag}" if tag else ""))
        audio = unit_audio(x, pieces)
        sent_s += len(audio) / SR
        prompt = prompts.get(lab)
        label = f"{track} {'block' if len(pieces) > 1 else 'chunk'} {i + 1} ({a:.1f}-{b:.1f}s)"
        accepted = stats["retries_accepted"]
        try:
            res = decode_chunk(engine, audio, lab, prompt, prompt_words, stats, label)
        except EngineBlockDeclined as exc:        # not answered as one call: its chunks go one by one (or in shorter blocks), nothing is lost
            if len(pieces) < 2:
                stats["failed_chunks"] += 1
                last_error = exc
                log.error("%s chunk %d/%d (%.1f-%.1fs) failed: %s: %s", track, i + 1, n, a, b, type(exc).__name__, exc)
                continue
            parts = split_block(engine, pieces, lab)
            stats["split_blocks"] += 1
            sent_s -= len(audio) / SR             # the audio was not taken: its parts count when they go
            ran -= 1
            log.warning("%s block %d (%.1f-%.1fs) was not taken as one call (%s): decoding it in %d parts", track, i + 1, a, b,
                        type(exc).__name__, len(parts))
            work.extendleft((i, part) for part in reversed(parts))
            continue
        except Exception as exc:                  # one bad chunk must not lose the whole track
            stats["failed_chunks"] += 1
            last_error = exc
            if isinstance(exc, EngineTransient):
                unreachable += 1
            log.error("%s chunk %d/%d (%.1f-%.1fs) failed: %s: %s", track, i + 1, n, a, b, type(exc).__name__, exc)
            continue
        if res.get("truncated"):
            stats["truncated_chunks"] += 1
        pairs = [(sg, res.get("language") or lab) for sg in res["segments"]]
        if dual and prompt:                       # a chunk without a prompt (no vocabulary) would decode the same way twice
            plain = res if stats["retries_accepted"] != accepted else decode_plain(engine, audio, lab, label)    # an accepted retry IS pass N
            if plain is not None:
                pairs = _reconcile_chunk(res, plain, lab, vocab.terms, dual_counts)
        for sg, code in pairs:
            text = (sg.get("text") or "").strip()
            times = block_times(pieces, sg["start"], sg["end"])               # decoders can emit times past the real chunk end
            if text and times is not None:
                segs.append(Seg(times[0], times[1], text, _lang_code(code), sg.get("avg_logprob"),
                                sg.get("no_speech_prob"), sg.get("compression_ratio"), sg.get("temperature", 0.0), i))
    if ran and stats["failed_chunks"] == ran:
        if unreachable == ran:                      # nothing got through and every failure was a connection problem, not a bad chunk
            raise AsrUnreachable(f"ASR unreachable: every chunk of the {track} track failed to reach the engine: "
                                 f"{type(last_error).__name__}: {last_error}") from last_error
        raise RuntimeError(f"ASR failed for every chunk of the {track} track: {type(last_error).__name__}: {last_error}")
    info["asr_s"] = round(time.time() - t_asr, 2)

    guard = [p for p in prompts.values() if p]
    seen = _prompt_text_seen(engine)              # the prompt a server built itself (uses_prompt False) feeds the echo guard too
    if seen:
        guard.append(seen)
    kept, dropped = postfilter(segs, prompt="\n".join(guard) or None, languages=script_langs)
    for s, why in dropped:
        log.info("dropped [%s] %.1f-%.1fs %s | %r", track, s.start, s.end, why, logsafe.snip(s.text))
    weights: Counter = Counter()                  # track language = language with the most transcribed speech time
    for s in kept:
        if s.lang:
            weights[s.lang] += max(s.end - s.start, 0.01)
    if not weights:
        for a, b, lab in chunks:
            if lab:
                weights[lab] += b - a
    language = weights.most_common(1)[0][0] if weights else None
    info.update(dict(stats))
    if block_s:
        info["block_audio_s"] = round(sent_s, 1)  # the audio handed to the engine, in blocks (no content)
    if dual_counts["chunks"]:                     # nothing is added for single (or for a dual run that never decoded a chunk twice)
        info["strategy"] = "dual"
        info["dual"] = {key: dual_counts[key] for key in DUAL_KEYS}
        log.info("%s dual: %d chunks, %d equal, %d conflicts (%d plain chosen), %d restored, %d plain-only segments rejected", track,
                 dual_counts["chunks"], dual_counts["equal"], dual_counts["conflicts"], dual_counts["plain_chosen"], dual_counts["restored"],
                 dual_counts["rejected"])
    info["segments"] = len(kept)
    info["dropped"] = len(dropped)
    info["loops_collapsed"] = sum(1 for s in kept if s.loop)
    info["words"] = sum(len(s.text.split()) for s in kept)
    info["total_s"] = round(time.time() - t_begin, 2)
    log.info("%s: %d chunks, %d segments kept, %d dropped, language %s, vad %s, %.1fs (asr %.1fs)", track, len(chunks), len(kept),
             len(dropped), language, vad.label, info["total_s"], info["asr_s"])
    return TrackResult(track, [_seg_dict(s, vocab) for s in kept],
                       [{"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text, "reason": why} for s, why in dropped],
                       language, info)


def transcribe_array(audio: np.ndarray, cfg: Config, vocab: Vocab, language: str | None = None,
                     progress: Progress = _noop) -> list[dict]:
    """Segments of one 16 kHz mono float32 array (transcribe-file / benchmarks): start, end, lang, text, avg_logprob, no_speech_prob.

    ``language``: None or "auto" = per-region ko/en language ID, "ko"/"en" = forced (callers resolve ASR_LANGUAGE themselves).
    """
    return transcribe_track(audio, _engine_for(cfg, vocab, progress), cfg, vocab, track="audio", language=language or "auto",
                            progress=progress).segments


# --------------------------------------------------------------------------------------
# echo suppression
# --------------------------------------------------------------------------------------
def _norm_chars(text: str) -> str:
    return re.sub(r"[\W_]+", "", text.casefold())


def _match_ratio(a: str, b: str) -> float:
    """Share of ``a`` covered by in-order common blocks of >= 3 characters with ``b``."""
    if not a or not b:
        return 0.0
    blocks = difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()
    return sum(m.size for m in blocks if m.size >= 3) / len(a)


def _span_db(x: np.ndarray, t0: float, t1: float, sr: int = SR) -> float | None:
    seg = x[max(0, int(t0 * sr)): int(t1 * sr)]
    if len(seg) < 160:
        return None
    return float(10.0 * np.log10(float(np.mean(np.square(seg, dtype=np.float64))) + 1e-12))


def _echo_alignment(mic: np.ndarray, remote: np.ndarray, t0: float, t1: float, sr: int = SR,
                    lag_min_s: float = -0.05, lag_max_s: float = 0.8) -> tuple[float, int] | None:
    """``(peak normalised cross-correlation 0..1, lag in samples)`` between the mic over [t0, t1] and the remote track delayed by
    ``lag_min_s``..``lag_max_s`` (speaker -> mic path; a small negative lag allows clock slack); lag > 0 = the mic lags the
    remote. None when the span is too short."""
    a, b = int(t0 * sr), min(int(t1 * sr), len(mic))
    if b - a < sr // 5:
        return None
    x = mic[a:b].astype(np.float64)
    lmin, lmax = int(lag_min_s * sr), int(lag_max_s * sr)
    ra, rb = a - lmax, b - lmin
    ref = np.zeros(rb - ra)
    lo, hi = max(ra, 0), min(rb, len(remote))
    if hi <= lo:
        return 0.0, 0
    ref[lo - ra: hi - ra] = remote[lo:hi]
    n = len(x)
    nfft = 1 << int(np.ceil(np.log2(n + len(ref))))
    cc = np.fft.irfft(np.fft.rfft(ref, nfft) * np.conj(np.fft.rfft(x, nfft)), nfft)      # cc[k] = sum_t ref[t + k] * x[t]
    ks = np.arange(0, lmax - lmin + 1)                                                    # k = lmax - lag
    power = np.concatenate([[0.0], np.cumsum(ref * ref)])
    den = np.sqrt(float(np.dot(x, x)) * (power[ks + n] - power[ks]) + 1e-18)
    score = np.abs(cc[ks]) / den
    k = int(np.argmax(score))
    return float(score[k]), int(lmax - k)


def _echo_coherence(mic: np.ndarray, remote: np.ndarray, t0: float, t1: float, sr: int = SR,
                    lag_min_s: float = -0.05, lag_max_s: float = 0.8) -> float | None:
    """How much of the mic over [t0, t1] is the remote track played through the speakers (0..1); None when the span is too short.

    * every span: the peak normalised cross-correlation with the remote delayed by ``lag_min_s``..``lag_max_s`` (a person talking
      into the mic scores ~0.1 even with a faint echo underneath and independent speech ~0.05, but a pure echo that went through
      a reverberant room scores only 0.3-0.6, because the reverberant tail is not a delayed copy);
    * spans with >= ~1.5 s of remote activity: additionally the energy-weighted, cross-validated share of the mic energy that a
      160 ms linear model of the delay-aligned remote explains (``aec.explained_fraction``): 0.65-0.98 for pure echo through a
      reverberant, band-limited room (DRR +6..-10 dB), <= 0.11 for the user talking over it. The larger of the two is returned."""
    found = _echo_alignment(mic, remote, t0, t1, sr, lag_min_s, lag_max_s)
    if found is None:
        return None
    peak, lag = found
    if peak <= 0.0:
        return peak
    a, b = int(t0 * sr), min(int(t1 * sr), len(mic))
    try:
        from . import aec
        ref = aec._slice_pad(remote, a - lag + aec.AecParams.margin, b - lag + aec.AecParams.margin)
        share = aec.explained_fraction(mic[a:b], ref, sr)
    except Exception as exc:                     # the cross-correlation alone is still a valid (weaker) answer
        log.debug("explained-fraction coherence unavailable: %s", exc)
        share = None
    return peak if share is None else max(peak, share)


FRAGMENT_MIN_WORDS = 2          # a mic segment needs this many words ...
FRAGMENT_MIN_CHARS = 8          # ... or this many letters/digits to be judged as a fragment of Remote speech


def _contains_run(words: list[str], run: list[str]) -> bool:
    """True when ``run`` occurs in ``words`` as consecutive words."""
    n = len(run)
    return n > 0 and any(words[i:i + n] == run for i in range(len(words) - n + 1))


def suppress_echo(mic_segs: list[dict], remote_segs: list[dict], mic_audio: np.ndarray | None = None,
                  remote_audio: np.ndarray | None = None, *, window_s: float = 3.0, min_chars: int = 6, sim_min: float = 0.70,
                  corr_min: float = 0.30, audio_corr_min: float = 0.50, own_corr_max: float = 0.20, level_margin_db: float = 4.0,
                  max_span_s: float = 15.0, fragment_before_s: float = 4.0, fragment_after_s: float = 1.5,
                  fragment_louder_db: float = 0.0, fragment_corr_min: float = 0.40, fragment_short_s: float = 1.0,
                  fragment_mid_s: float = 2.0, reasons: Counter | None = None, sr: int = SR) -> tuple[list[dict], list[dict]]:
    """Remove mic-track segments that are speaker echo of the remote track. Returns ``(kept, suppressed)``; ``reasons`` (a Counter,
    optional) is incremented per suppressed segment with ``"whole-segment"`` or ``"fragment-echo"``.

    Safety net behind the echo canceller (it matters when ``MIC_AEC=0``, when the canceller was not applicable, or when its
    residue was transcribed anyway). Per mic segment three facts are measured: the text similarity with the remote speech within
    +-``window_s`` s (share of the text covered by in-order common blocks), the *coherence* of the mic over the segment with the
    remote track delayed 0-800 ms (see ``_echo_coherence``: ~0.1 for a person speaking, >= 0.3 for echo), and the mic level.

    The "own level" reference is the median level of the segments that are NOT coherent with the remote track
    (coherence < ``own_corr_max``): those are the user talking, whatever the words. (Taking the segments with dissimilar *text*
    instead, as an earlier version did, lets echo that Whisper transcribed differently, typically Korean, pull the reference
    down to the echo level so nothing is ever "clearly quieter".) A segment is suppressed when it is clearly quieter than that
    reference (``level_margin_db``; with no reference at all, e.g. The user muted and only echo on the mic, this condition is waived)
    AND one of:

    * text rule: >= ``sim_min`` text similarity AND coherence >= ``corr_min``;
    * audio-only rule: coherence >= ``audio_corr_min`` regardless of the text: at that coherence at least a quarter of the mic
      energy is a delayed copy of what the speakers played, however Whisper happened to spell it.

    Fragment rule (``"fragment-echo"``, for the short duplicate that a loud speaker or a partly cancelled echo leaves, e.g.
    "Okay, now..." two seconds after the Remote said "Okay, now I am reading the sample agenda ..."): the words of a mic segment of
    >= 2 words (or >= 8 letters/digits) occur as consecutive words inside a Remote segment that starts at most ``fragment_before_s``
    before it or ``fragment_after_s`` after it (sharing a word or the beginning of a word is not a match). Text this specific allows
    a looser level test than the rules above, but the audio decides whether the words were the user's: the closer the segment is to
    the user's own level, the more coherence with the remote track it needs. Short spans make coherence noisy (independent speech scored
    0.2 or more on about one span in ten at one second, one in three at half a second), so the user's level is the first witness:

    * louder than the reference (more than ``fragment_louder_db`` above it): the user's own voice, never removed (the user talking over an echo
      as loud as they are comes out 0.5-2 dB ABOVE their usual level, an echo alone at or under it);
    * clearly quieter (``level_margin_db`` below): the coherence must clear the noise of a person who is simply talking over the
      remote speech, and that noise depends on the length of the span (TTS speech vs the remote track, share of spans at or above
      0.20 / 0.30 / 0.40: 0.5 s 36 / 19 / 5 %, 0.8 s 18 / 5 / 0 %, 1.2 s 10 / 1 / 0 %, 1.5 s 4 / 0 / 0 %, 2 s 3 / 0 / 0 %; a pure echo
      reaches 0.30 in 98-100 % and 0.40 in about 90 % of the spans of any length). So a span under ``fragment_short_s`` needs
      ``fragment_corr_min``, one under ``fragment_mid_s`` needs ``corr_min``, a longer one ``own_corr_max`` (the line between "the user
      talking" and "not the user"): a quiet real answer that repeats Remote words is not removed on the strength of a chance 0.2;
    * from the user's level down to ``level_margin_db`` under it, or no reference at all: coherence >= ``fragment_corr_min``;
    * one single long word always needs coherence >= ``corr_min`` as well: one word is never judged by its text alone.

    Without audio (None) nothing is removed: text alone cannot tell an echo from the user repeating what was just said. A real
    utterance that overlaps remote speech is loud at the mic and barely coherent with the remote track, so it survives.
    """
    have_audio = mic_audio is not None and remote_audio is not None
    if not mic_segs or not remote_segs or not have_audio:
        return list(mic_segs), []
    remote_sorted = sorted(remote_segs, key=lambda s: s["start"])
    remote_words = [_norm(r["text"]).split() for r in remote_sorted]
    remote_starts = [r["start"] for r in remote_sorted]

    def fragment_words(s: dict) -> int:
        """The number of words of ``s`` when they are a run of consecutive words of a nearby Remote segment, else 0."""
        words = _norm(s["text"]).split()
        if len(words) < FRAGMENT_MIN_WORDS and len("".join(words)) < FRAGMENT_MIN_CHARS:
            return 0
        lo = bisect.bisect_left(remote_starts, s["start"] - fragment_before_s)
        hi = bisect.bisect_right(remote_starts, s["start"] + fragment_after_s)
        return len(words) if any(_contains_run(remote_words[i], words) for i in range(lo, hi)) else 0

    rows = []
    for s in mic_segs:
        jn = _norm_chars(s["text"])
        sim = None
        if len(jn) >= min_chars:
            near = [r for r in remote_sorted if r["end"] >= s["start"] - window_s and r["start"] <= s["end"] + window_s]
            sim = _match_ratio(jn, _norm_chars(" ".join(r["text"] for r in near))) if near else 0.0
        mid = (s["start"] + s["end"]) / 2.0
        half = min(s["end"] - s["start"], max_span_s) / 2.0                  # very long segments: judge the middle part
        rows.append({"seg": s, "sim": sim, "level": _span_db(mic_audio, s["start"], s["end"], sr), "fragment": fragment_words(s),
                     "span": 2.0 * half, "corr": _echo_coherence(mic_audio, remote_audio, mid - half, mid + half, sr)})
    own = [(r["seg"]["end"] - r["seg"]["start"], r["level"]) for r in rows
           if r["level"] is not None and r["corr"] is not None and r["corr"] < own_corr_max]
    own_long = [lv for d, lv in own if d >= 1.0] or [lv for _, lv in own]
    own_ref = float(np.median(own_long)) if own_long else None

    kept, suppressed = [], []
    for r in rows:
        s, sim, corr, level = r["seg"], r["sim"], r["corr"], r["level"]
        why = None
        if corr is not None and level is not None:
            quiet = own_ref is None or level <= own_ref - level_margin_db
            if quiet and ((sim is not None and sim >= sim_min and corr >= corr_min) or corr >= audio_corr_min):
                why = "whole-segment"
            elif r["fragment"]:
                if own_ref is not None and level > own_ref + fragment_louder_db:
                    need = None                                                      # louder than the user's own voice: their
                else:
                    if own_ref is not None and level <= own_ref - level_margin_db:
                        span = r["span"]
                        need = (max(own_corr_max, fragment_corr_min) if span < fragment_short_s
                                else max(own_corr_max, corr_min) if span < fragment_mid_s else own_corr_max)
                    else:
                        need = fragment_corr_min
                    need = need if r["fragment"] >= FRAGMENT_MIN_WORDS else max(need, corr_min)
                if need is not None and corr >= need:
                    why = "fragment-echo"
        if why:
            suppressed.append(s)
            if reasons is not None:
                reasons[why] += 1
            log.info("echo suppressed mic %.1f-%.1fs (%s: text %s, coherence %.2f, level %.1f dB vs own %s) | %r", s["start"], s["end"], why,
                     "n/a" if sim is None else f"{sim:.2f}", corr, level, "n/a" if own_ref is None else f"{own_ref:.1f}", logsafe.snip(s["text"]))
        else:
            kept.append(s)
    return kept, suppressed


# --------------------------------------------------------------------------------------
# offline echo cancellation of the microphone track (SPEC 14.2)
# --------------------------------------------------------------------------------------
def _jsonable(value):
    """numpy scalars / arrays / tuples inside the canceller's statistics -> plain JSON types."""
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    return value


def aec_mode(cfg: Config) -> str | None:
    """MIC_AEC -> the ``aec.cancel_echo`` mode: ``None`` (off, 0), ``"always"`` (1) or ``"auto"`` (default; unknown values too)."""
    value = str(getattr(cfg, "mic_aec", "auto") or "auto").strip().lower()
    if value in ("0", "off", "false", "no", "none"):
        return None
    if value in ("1", "on", "true", "yes", "always"):
        return "always"
    if value != "auto":
        log.warning("unknown MIC_AEC=%r, using auto", value)
    return "auto"


def echo_cancel_mic(prepared: PreparedAudio, cfg: Config, progress: Progress = _noop) -> tuple[np.ndarray | None, dict]:
    """Run the echo canceller on the microphone track. Returns ``(cleaned mic audio or None, stats)``: ``None`` means "use the
    untouched microphone track" (disabled, a track is missing, not applicable, or the canceller failed). ``stats`` always
    exists and goes to ``transcript.json["aec"]``: ``applied`` plus ``coherence``, ``delay_ms``, ``erle_db``, ``mode``, ``reason`` ...
    Never raises: the echo canceller is an improvement, never a reason to lose a transcript."""
    mode = aec_mode(cfg)
    if mode is None:
        return None, {"applied": False, "mode": "off", "reason": "MIC_AEC=0"}
    missing = [t for t in TRACK_NAMES if t in prepared.missing or t not in prepared.tracks]
    if missing:
        return None, {"applied": False, "mode": mode, "reason": f"no {'/'.join(missing)} track to compare"}
    try:
        from . import aec
        t0 = time.time()
        progress("echo cancellation")
        cleaned, stats = aec.cancel_echo(prepared.tracks["mic"], prepared.tracks["remote"], prepared.sample_rate, mode, progress)
        stats = _jsonable(stats)
        stats.setdefault("applied", False)
        log.info("echo cancellation (%s): applied=%s, coherence %s, delay %s ms, ERLE %s dB, %.1f s%s", mode, stats["applied"],
                 stats.get("coherence"), stats.get("delay_ms"), stats.get("erle_db"), time.time() - t0,
                 f", not applied: {stats['reason']}" if not stats["applied"] and stats.get("reason") else "")
        if stats.get("error"):
            log.warning("echo cancellation failed, the microphone track is used unchanged: %s", stats["error"])
        if not stats["applied"] or len(cleaned) != len(prepared.tracks["mic"]):
            return None, stats
        return cleaned, stats
    except Exception as exc:                  # a bug in the canceller must not cost the transcript
        log.exception("echo cancellation crashed; using the microphone track unchanged")
        return None, {"applied": False, "mode": mode, "error": f"{type(exc).__name__}: {exc}"[:300]}


# --------------------------------------------------------------------------------------
# both tracks -> transcript.json
# --------------------------------------------------------------------------------------
PROVENANCE_TEXT_KEYS = ("engine", "model", "kind", "privacy", "destination", "region", "protocol", "consent_id")   # SPEC 18 (strings)
PROVENANCE_COUNT_KEYS = ("fallbacks", "circuit_opened")
PROVENANCE_SENT_KEYS = ("requests", "lid_requests", "audio_s", "bytes")
PROVENANCE_TEXT_MAX = 120                 # characters of one text value
PROVENANCE_CHUNK_ENGINES_MAX = 16         # entries of "chunks"


def _prov_text(value) -> str | None:
    """A provenance string on ONE line (a newline in a model name would forge a header line of transcript.md), capped; None for a non-string."""
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:PROVENANCE_TEXT_MAX]


def _prov_number(value, *, integer: bool = False):
    """A finite, non-negative number (numpy scalars become Python ones); an integer for ``integer=True``; None for anything else."""
    if isinstance(value, np.generic):
        value = value.item()
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        if not math.isfinite(value) or value < 0:
            return None
        if not integer:
            return value
        return int(value) if float(value).is_integer() else None
    except OverflowError:                         # an int too large for a float
        return None


def _clean_provenance(block: dict) -> dict:
    """Only the SPEC 18 keys of ``block``, each with the right type: text on one line (capped), counts as numbers, ``chunks`` {engine:
    n}, ``sent`` {requests, lid_requests, audio_s, bytes}. Everything else (a host, a token, a wrongly typed value, NaN, a numpy scalar
    that json cannot write) is dropped or converted, so the block can never fail ``atomic_write_json`` or ``render_markdown`` after the
    ASR work is done, and a server cannot put text of its own into the shared transcript folder."""
    out: dict = {}
    schema = _prov_number(block.get("schema"), integer=True)
    if schema is not None:
        out["schema"] = schema
    for key in PROVENANCE_TEXT_KEYS:
        text = _prov_text(block.get(key))
        if text is not None:
            out[key] = text
    chunks = block.get("chunks")
    if isinstance(chunks, dict):
        counted = {}
        for name, n in list(chunks.items())[:PROVENANCE_CHUNK_ENGINES_MAX]:
            name, n = _prov_text(name), _prov_number(n, integer=True)
            if name and n is not None:
                counted[name] = n
        if counted:
            out["chunks"] = counted
    for key in PROVENANCE_COUNT_KEYS:
        n = _prov_number(block.get(key), integer=True)
        if n is not None:
            out[key] = n
    sent = block.get("sent")
    if isinstance(sent, dict):
        counts = {key: v for key in PROVENANCE_SENT_KEYS if (v := _prov_number(sent.get(key))) is not None}
        if counts:
            out["sent"] = counts
    return json.loads(json.dumps(out, allow_nan=False))        # what is returned is what the transcript file will hold


def _engine_label(engine) -> str:
    """How an engine names itself (``Engine.describe``: ``engine_id`` or ``name``), on one line; never raises."""
    for attr in ("engine_id", "name"):
        try:
            label = _prov_text(getattr(engine, attr, None))
        except Exception:
            label = None
        if label:
            return label
    return _prov_text(type(engine).__name__) or "unknown"


def _engine_kind(engine) -> str:
    """The kind an engine declares ("local", "server", "cloud"), "unknown" when it cannot be read as a string; never raises."""
    try:
        return _prov_text(engine_caps(engine).kind) or "unknown"
    except Exception:
        return "unknown"


def _provenance(engine, kind: str = "local") -> dict | None:
    """The ``transcript.json["asr"]`` block of the engine, cleaned by ``_clean_provenance``. A local engine gives None and the
    transcript gets no new key; a double without the method, or one that fails, adds nothing (provenance never costs a transcript).
    The record of where the audio went must not vanish for an EXTERNAL engine (``kind``: what it declared, anything but "local", e.g. server,
    cloud or unknown): when ``provenance()`` raises, returns a non-dict, an empty block or one without a usable key, the block is a minimal
    content-free one from the engine's own declarations with ``privacy`` "unknown"; a usable block that misses ``engine`` or ``kind`` gets
    them, and one that says neither ``privacy`` nor ``chunks`` gets ``privacy`` "unknown"."""
    block = None
    try:
        raw = getattr(engine, "provenance", lambda: None)()
        if isinstance(raw, dict) and raw:
            block = _clean_provenance(raw) or None
    except Exception:
        log.exception("engine provenance unavailable")
    if kind == "local":
        return block
    if block is None:
        log.warning("the external ASR engine %s gave no usable provenance: the transcript records only what the engine declares",
                    _engine_label(engine))
        return {"schema": 1, "engine": _engine_label(engine), "kind": kind, "privacy": "unknown"}
    block.setdefault("engine", _engine_label(engine))
    block.setdefault("kind", kind)
    if "privacy" not in block and "chunks" not in block:
        block["privacy"] = "unknown"
    return block


def _external_processed(provenance: dict, default: bool = False) -> bool:
    """Did an external engine (server or cloud) process at least one chunk? ``privacy`` is computed from what really happened
    (local | server | cloud | mixed); without it the chunk counts of the primary engine decide. A block that cannot be read gives ``default``."""
    try:
        privacy = provenance.get("privacy")
        if isinstance(privacy, str):
            return privacy in ("server", "cloud", "mixed")
        chunks = provenance.get("chunks")
        return (provenance.get("kind") in ("server", "cloud") and isinstance(chunks, dict)
                and bool(chunks.get(provenance.get("engine"), 0)))
    except Exception:
        return default


def _dual_provenance(results: dict) -> dict | None:
    """``{"strategy": "dual", "dual": {chunks, conflicts, plain_chosen, restored}}`` summed over the tracks that ran ``ASR_STRATEGY=dual``,
    None when none did (single, an external engine, or a run that never decoded a chunk twice): such a transcript gets no new key."""
    parts = [r.info["dual"] for r in results.values() if r is not None and r.info.get("dual")]
    if not parts:
        return None
    return {"strategy": "dual", "dual": {key: sum(part.get(key, 0) for part in parts) for key in DUAL_KEYS}}


def transcribe_tracks(prepared: PreparedAudio, cfg: Config, vocab: Vocab, progress: Progress = _noop) -> dict:
    """The SPEC 4.4 transcript dict for a prepared session (mic first, then remote; missing tracks are skipped).

    Extra keys beyond SPEC 4.4: ``dropped`` {track: count}, ``dropped_reasons``, ``echo_suppressed`` (count) with
    ``echo_suppressed_reasons`` ({"whole-segment": n, "fragment-echo": n}), ``aec`` (echo
    canceller statistics, SPEC 14.2: applied, coherence, delay_ms, erle_db, mode, reason ...), ``speech_seconds`` {mic, remote,
    total: VAD speech time}, ``missing_tracks``, ``stats`` (per-track details), and ``asr`` (SPEC 18: where the audio went, only for an
    external or routed engine; see ``_provenance``). A local ``ASR_STRATEGY=dual`` run adds ``stats.<track>.strategy`` / ``.dual`` and an
    ``asr`` block that holds only ``schema``, ``engine``, ``kind: local``, ``strategy`` and ``dual`` (``transcript.route_line`` says nothing
    for it); ``single`` writes none of these keys.
    """
    parse_languages(cfg.asr_languages)                  # fail fast (clear ValueError) on an unknown ASR_LANGUAGES code, before any heavy work
    logsafe.configure(getattr(cfg, "log_content", True))
    engine = _engine_for(cfg, vocab, progress)
    kind = _engine_kind(engine)                           # asked again after the run: a router may have fallen back to local meanwhile
    mic_clean, aec_stats = echo_cancel_mic(prepared, cfg, progress)      # SPEC 14.2: after audioprep, before the VAD
    results: dict[str, TrackResult | None] = {}
    present = [t for t in TRACK_NAMES if t not in prepared.missing and t in prepared.tracks]
    context = {"solo": len(present) == 1, "platform": str(getattr(prepared, "platform", "") or "")}    # for Engine.set_track_context
    for track in TRACK_NAMES:
        if track in prepared.missing or track not in prepared.tracks:
            results[track] = None
            continue
        audio = mic_clean if (track == "mic" and mic_clean is not None) else prepared.tracks[track]
        results[track] = transcribe_track(audio, engine, cfg, vocab, track=track, progress=progress, context=context)
        if track == "mic":
            mic_clean = None                  # the cleaned copy is not needed any more (long meetings: hundreds of MB)

    mic, remote = results.get("mic"), results.get("remote")
    mic_segs = list(mic.segments) if mic else []
    remote_segs = list(remote.segments) if remote else []
    echo_count = 0
    echo_reasons: Counter = Counter()
    if mic_segs and remote_segs:
        progress("checking echo")
        mic_segs, suppressed = suppress_echo(mic_segs, remote_segs, prepared.tracks.get("mic"), prepared.tracks.get("remote"),
                                             sr=prepared.sample_rate, reasons=echo_reasons)
        echo_count = len(suppressed)

    segments = []
    for track, segs, speaker in (("mic", mic_segs, cfg.self_name), ("remote", remote_segs, REMOTE_LABEL)):
        for s in segs:
            segments.append({"start": s["start"], "end": s["end"], "speaker": speaker, "track": track, "lang": s["lang"] or "",
                             "text": s["text"], "avg_logprob": s["avg_logprob"], "no_speech_prob": s["no_speech_prob"]})
    speech = {t: round(float(results[t].info.get("speech_s", 0.0)), 1) if results.get(t) else 0.0 for t in TRACK_NAMES}
    speech["total"] = round(sum(speech[t] for t in TRACK_NAMES), 1)
    kind = kind if kind != "local" else _engine_kind(engine)
    external = kind != "local"                            # server, cloud, or a kind this code does not know: nothing fails open
    provenance = _provenance(engine, kind)                # before release(): None for a local engine, a dict for an external or routed one
    dual = _dual_provenance(results)
    if dual and not external:                             # a local dual run records its strategy (and nothing else) in the asr block
        provenance = {**(provenance or {"schema": 1, "engine": _engine_label(engine), "kind": "local"}), **dual}
    try:
        engine.release()
    except Exception:
        pass
    extra: dict = {}
    asr_model = cfg.asr_model
    if provenance is not None:
        extra["asr"] = provenance
        if _external_processed(provenance, external) or (external and provenance.get("privacy") == "unknown"):
            model = provenance.get("model")               # header and footer name the model that really did the work, never cfg.asr_model
            asr_model = (model if isinstance(model, str) and model.strip() else
                         f"{provenance.get('engine') or 'external engine'} ({provenance.get('kind') or 'unknown'}, model unknown)")
    return make_transcript(
        asr_model,
        {t: (results[t].language if results.get(t) else None) for t in TRACK_NAMES},
        segments,
        dropped={t: len(results[t].dropped) if results.get(t) else 0 for t in TRACK_NAMES},
        dropped_reasons={t: results[t].dropped_by_reason if results.get(t) else {} for t in TRACK_NAMES},
        echo_suppressed=echo_count,
        echo_suppressed_reasons=dict(echo_reasons),
        aec=aec_stats,
        speech_seconds=speech,
        missing_tracks=list(prepared.missing),
        stats={t: results[t].info if results.get(t) else None for t in TRACK_NAMES},
        **extra,
    )
