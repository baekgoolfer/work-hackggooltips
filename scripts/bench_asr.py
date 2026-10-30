#!/usr/bin/env python3
"""bench_asr.py - local ASR model comparison for the Catch Everything pipeline (SPEC 9).

Runs the production ASR path (VAD -> language ID -> per-chunk decode -> post-filter, i.e. mcap.asr.transcribe_track) on one
audio slice for every model you list and writes a side-by-side report. Local models upload nothing; the only network
access is Hugging Face model downloads for models that are not cached yet (use --no-download to forbid even that).

External engines: `remote` (the company server) and `azure` can be listed as models too. They are built from the
decision a pipeline run makes (organisation policy, your consent from `mcap asr-engines consent`, the lane), so there is no benchmark around
that gate, and by default they get a SYNTHETIC clip, never your audio. Your audio goes to an external engine only with --allow-real-audio AND
the sentence you type in the terminal that nobody else was in that meeting. Local models always get the audio file.

Usage (from a checkout of this repo, with a Python that has mlx-whisper; add mlx-qwen3-asr for Qwen models):

    python scripts/bench_asr.py --audio meeting.m4a --start 600 --duration 900 \\
        --models mlx-community/whisper-large-v3-mlx mlx-community/whisper-large-v3-turbo \\
        --language-mode auto-region --prompt-style frame+list --out benchmarks/run1

Works unchanged on any Apple Silicon Mac that has this repo (pipeline/mcap, config/vocabulary.txt) and the packages above.
Audio may be m4a / mp4 / mp3 / wav (anything macOS afconvert reads; WAV files are read directly and may have broken headers).

Options
  --audio FILE          audio to transcribe (required unless only external engines are benchmarked, which then use the synthetic clip)
  --allow-real-audio    send --audio to the external engines too (terminal confirmation: nobody else was in the meeting)
  --synthetic-seconds S length of the synthetic clip the external engines get by default (default 20)
  --start S --duration S   slice in seconds (default: from 0 to the end)
  --models M [M ...]    Hugging Face repo ids or local model directories; whisper and qwen3-asr names are routed automatically
  --language-mode       forced-ko | forced-en | auto-region (per-region ko/en language ID, the production setting)
  --prompt-style        none | list (bare vocabulary list) | frame+list (production: language frame + list)
  --prompt-tokens N     token budget of the prompt, frame included (default: the production budget, asr.ASR_PROMPT_TOKENS = 140; the Whisper window allows 223)
  --vocab FILE          vocabulary (default config/vocabulary.txt)
  --vad                 auto | silero | energy (default auto: Silero when onnxruntime + model are available; a fallback to
                        energy is reported as "energy (silero unavailable: <reason>)")
  --languages L         ASR_LANGUAGES for the per-region language ID and the script filter (default ko,en; e.g. ja,ko,en)
  --strategy S          single | dual | both (default: ASR_STRATEGY of the built-in config). dual decodes every chunk twice and reconciles them
                        (pipeline/mcap/asr_reconcile.py); both runs every local model once per strategy (rows `<model>__single`,
                        `<model>__dual`). An external engine always runs once, single. Every row carries the strategy metrics below.
  --gate-from DIR ...   no run: read the summary.json of runs made with --strategy both and print whether `dual` may be the default
  --apply-aliases       apply vocabulary aliases to the text (off by default so model errors stay visible)
  --bucket S            row length of the side-by-side table (default 20 s)
  --out DIR             output directory (default benchmarks/bench-<timestamp>)
  --no-download         refuse to download models that are not cached

Outputs in --out:  <model>/transcript.md, <model>/segments.json, comparison.md (side by side), vocabulary.md (term hit counts),
numbers.md (number / price / date / time inventory), summary.md + summary.json (dropped, loops, retries, wall time, RTF).

Deciding the ASR_STRATEGY default (measure first, then switch): run the SAME slice with --strategy both for at least three slices of one
real recording, then `--gate-from` the output directories:

    for s in 660 4560 6960; do python scripts/bench_asr.py --audio meeting.m4a --start $s --duration 720 --strategy both --no-download \
        --models mlx-community/whisper-large-v3-mlx --language-mode auto-region --out benchmarks/strategy-$s; done
    python scripts/bench_asr.py --gate-from benchmarks/strategy-660 benchmarks/strategy-4560 benchmarks/strategy-6960

Strategy metrics per run (counts only, nothing of the text): segments, words, english_words (words of 2+ ASCII letters), digit_tokens,
implausible_numbers (``asr_reconcile.implausible_numbers``), loops4 (runs of an immediately repeated 4-word sequence), asr_s (time of the
transcription stage, the model load excluded). `dual` may be the default only when, on EVERY slice: implausible_numbers <= single,
english_words >= single - 1, segments >= single, loops4 <= single, digit_tokens >= single - 1, words >= 98% of single (nothing spoken
may get lost) and asr_s <= 2.4 x single.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import re
import shutil
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pipeline"))

from mcap import audioprep, vad as vadmod, wavio  # noqa: E402
from mcap.asr_reconcile import implausible_numbers, norm_text  # noqa: E402
from mcap.asr import ASR_PROMPT_TOKENS, transcribe_track  # noqa: E402
from mcap.asr_engines import create_engine  # noqa: E402
from mcap.config import Config  # noqa: E402
from mcap.transcript import format_ts, make_transcript, render_markdown  # noqa: E402
from mcap.vocab import Vocab, load_vocab  # noqa: E402

log = logging.getLogger("bench_asr")
SR = 16000
LANGUAGE_MODES = {"forced-ko": "ko", "forced-en": "en", "auto-region": "auto"}


# --------------------------------------------------------------------------------------
# audio
# --------------------------------------------------------------------------------------
def load_audio(path: Path, start: float, duration: float) -> np.ndarray:
    """File -> float32 mono 16 kHz slice [start, start + duration)."""
    if not path.is_file():
        raise SystemExit(f"audio file not found: {path}")
    x = None
    if path.suffix.lower() == ".wav":
        try:
            samples, sr = wavio.read_wav_lenient(path)
            x = audioprep.resample(samples, sr, SR)
        except (wavio.WavError, ValueError, OSError) as exc:
            log.info("direct WAV read failed (%s); trying afconvert", exc)
    if x is None:
        tmp = Path(tempfile.mkdtemp(prefix="bench-asr-"))
        try:
            audioprep.decode_to_wav(path, tmp / "in16k.wav", sample_rate=SR, channels=1)
            x, _ = wavio.read_wav_lenient(tmp / "in16k.wav")
        except audioprep.AfconvertError as exc:
            raise SystemExit(f"cannot decode {path.name}: {exc}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    a = max(0, int(start * SR))
    b = len(x) if duration <= 0 else min(len(x), a + int(duration * SR))
    x = x[a:b]
    if len(x) < SR // 2:
        raise SystemExit("the selected audio slice is empty")
    return np.ascontiguousarray(x, dtype=np.float32)


# --------------------------------------------------------------------------------------
# metrics
# --------------------------------------------------------------------------------------
def count_term(text: str, term: str) -> int:
    """Case-insensitive whole-term count: a Latin term may not be glued to other letters/digits (a Korean particle after it
    is fine: "FDA는" counts); terms containing Hangul are counted as substrings."""
    if re.search(r"[ᄀ-ᇿ㄰-㆏가-힯]", term):
        return len(re.findall(re.escape(term), text, re.IGNORECASE))
    return len(re.findall(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])", text, re.IGNORECASE))


def vocabulary_hits(text: str, terms: list[str]) -> Counter:
    hits: Counter = Counter()
    for term in terms:
        n = count_term(text, term)
        if n:
            hits[term] = n
    return hits


_MONTH = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"
NUMBER_PATTERNS = [   # order matters: earlier categories claim their text first
    ("date", r"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b|\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b|\d{4}\s?년(?:\s?\d{1,2}\s?월)?(?:\s?\d{1,2}\s?일)?|\d{1,2}\s?월\s?\d{1,2}\s?일|\d{1,2}\s?월|\d{1,2}\s?일"
             r"|\b" + _MONTH + r"\s+\d{1,2}(?:st|nd|rd|th)?\b|\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?" + _MONTH),
    ("time", r"\b\d{1,2}:\d{2}(?::\d{2})?\s?(?:am|pm|AM|PM)?|\d{1,2}\s?시(?:\s?\d{1,2}\s?분)?"),
    ("price", r"[$€£₩]\s?\d[\d,]*(?:\.\d+)?(?:\s?(?:k|m|bn|million|billion|thousand)\b)?|\d[\d,]*(?:\.\d+)?\s?(?:달러|만\s?원|원|억|천만|dollars?\b|usd\b|krw\b|won\b)"),
    ("percent", r"\d+(?:\.\d+)?\s?(?:%|퍼센트|percent)"),
    ("number", r"\d+(?:[.,]\d+)*"),
]


def number_inventory(text: str) -> dict[str, Counter]:
    """Digit-based numbers / prices / dates / times / percents found in ``text`` (spelled-out numbers are not detected)."""
    inv: dict[str, Counter] = {}
    claimed = [False] * len(text)
    for category, pattern in NUMBER_PATTERNS:
        found: Counter = Counter()
        for m in re.finditer(pattern, text, re.IGNORECASE):
            if m.end() == m.start() or any(claimed[m.start():m.end()]):
                continue
            for i in range(m.start(), m.end()):
                claimed[i] = True
            found[re.sub(r"\s+", " ", m.group(0).strip().lower())] += 1
        inv[category] = found
    return inv


ENGLISH_WORD = re.compile(r"[A-Za-z]{2,}(?:['’-][A-Za-z]+)*")
DIGIT_TOKEN = re.compile(r"\d+(?:[.,]\d+)*")
GATE_MAX_TIME_RATIO = 2.4          # dual may take at most this many times the transcription time of single
GATE_MIN_WORDS_PERCENT = 98        # dual keeps at least this percentage of the words of single
GATE_MAX_DIGIT_LOSS = 1            # ... and loses at most this many digit tokens


def loops4(texts: list[str]) -> int:
    """Runs of an immediately repeated 4-word sequence in the segments read as one text (a doubled sentence is one run, a stuck decoder one long
    run): positions i with words[i:i+4] == words[i+4:i+8], consecutive positions counted once."""
    words = norm_text(" ".join(texts)).split()
    hit = [words[i:i + 4] == words[i + 4:i + 8] for i in range(max(0, len(words) - 7))]
    return sum(1 for i, h in enumerate(hit) if h and (i == 0 or not hit[i - 1]))


def strategy_metrics(segments: list[dict], asr_s: float, wall_s: float) -> dict:
    """The numbers of the ASR_STRATEGY gate for one run (counts only; see the module doc)."""
    texts = [s["text"] for s in segments]
    joined = "\n".join(texts)
    return {"segments": len(segments), "words": sum(len(t.split()) for t in texts), "english_words": len(ENGLISH_WORD.findall(joined)),
            "digit_tokens": len(DIGIT_TOKEN.findall(joined)), "implausible_numbers": sum(len(implausible_numbers(t)) for t in texts),
            "loops4": loops4(texts), "asr_s": asr_s, "wall_s": wall_s}


def strategy_gate(slices: list[dict]) -> dict:
    """``slices`` = [{"slice": label, "single": metrics, "dual": metrics}, ...] -> ``{"checks": {rule: bool}, "ratios": [...], "default_dual": bool}``.
    Every rule has to hold on every slice (module doc)."""
    def every(test) -> bool:
        return bool(slices) and all(test(x["single"], x["dual"]) for x in slices)
    raw = [x["dual"]["asr_s"] / x["single"]["asr_s"] if x["single"]["asr_s"] else None for x in slices]
    ratios = [None if r is None else round(r, 2) for r in raw]
    checks = {
        "implausible numbers not higher": every(lambda a, b: b["implausible_numbers"] <= a["implausible_numbers"]),
        "english words >= single - 1": every(lambda a, b: b["english_words"] >= a["english_words"] - 1),
        "segments >= single": every(lambda a, b: b["segments"] >= a["segments"]),
        "no new repeated loops": every(lambda a, b: b["loops4"] <= a["loops4"]),
        f"digit tokens >= single - {GATE_MAX_DIGIT_LOSS}": every(lambda a, b: b["digit_tokens"] >= a["digit_tokens"] - GATE_MAX_DIGIT_LOSS),
        f"words >= {GATE_MIN_WORDS_PERCENT}% of single": every(lambda a, b: b["words"] * 100 >= a["words"] * GATE_MIN_WORDS_PERCENT),
        f"time <= {GATE_MAX_TIME_RATIO}x single": bool(slices) and all(r is not None and r <= GATE_MAX_TIME_RATIO for r in raw),
    }
    return {"checks": checks, "ratios": ratios, "default_dual": all(checks.values())}


def gate_slices(dirs: list[str]) -> list[dict]:
    """The single/dual metric pairs of the first model in each ``--strategy both`` run directory (its summary.json)."""
    out = []
    for d in dirs:
        path = Path(d) / "summary.json"
        if not path.is_file():
            raise SystemExit(f"{path} not found (run bench_asr.py --strategy both --out {d} first)")
        rows: dict[str, dict] = {}
        for r in json.loads(path.read_text(encoding="utf-8"))["models"]:
            if "error" not in r and r.get("strategy") in ("single", "dual"):
                rows.setdefault(r["strategy"], r)                         # the first model of the run
        if set(rows) != {"single", "dual"}:
            raise SystemExit(f"{path}: needs one successful single and one successful dual row (found: {sorted(rows) or 'none'})")
        out.append({"slice": Path(d).name, "single": rows["single"], "dual": rows["dual"]})
    return out


def format_gate(slices: list[dict], verdict: dict) -> str:
    cols = ("segments", "words", "english_words", "digit_tokens", "implausible_numbers", "loops4", "asr_s")
    table = [["slice", "strategy", *cols]]
    for x in slices:
        table += [[x["slice"], s, *[str(x[s].get(c, "")) for c in cols]] for s in ("single", "dual")]
    widths = [max(len(row[i]) for row in table) for i in range(len(table[0]))]
    lines = ["  ".join(cell.ljust(w) for cell, w in zip(row, widths)).rstrip() for row in table]
    lines.append("time ratio dual/single per slice: " + ", ".join(str(r) for r in verdict["ratios"]))
    lines += [f"{'PASS' if ok else 'FAIL'}  {rule}" for rule, ok in verdict["checks"].items()]
    lines.append("verdict: dual " + ("MAY be the default" if verdict["default_dual"] else "stays opt-in (the default stays single)"))
    return "\n".join(lines)


# --------------------------------------------------------------------------------------
# running models
# --------------------------------------------------------------------------------------
def slugify(model: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", Path(model).name if Path(model).is_dir() else model).strip("_") or "model"


def external_engine_ids(models: list[str]) -> list[str]:
    """The entries of ``models`` that name an EXTERNAL ASR engine (policy.ENGINE_META kind server / cloud: remote, azure, ...) rather than a
    local model; they get the gate of ``make_engine`` and the synthetic clip."""
    from mcap import policy as policy_mod
    return [m for m in models if m in policy_mod.ENGINE_META and policy_mod.ENGINE_META[m]["kind"] != "local"]


def make_engine(model: str, allow_download: bool):
    """The engine of one benchmark entry: a local model as always (``create_engine``); an external engine id through
    ``mcap.cli.open_external_engine`` (the decision of a run: policy, consent, lane: ``EngineRefused`` otherwise, which ``run_model``
    reports as that model's error)."""
    if external_engine_ids([model]):
        from mcap import cli
        from mcap.config import load_config
        return cli.open_external_engine(load_config(), model)
    return create_engine(model, allow_download=allow_download)


def run_model(model: str, audio: np.ndarray, vad: vadmod.VadResult, vocab: Vocab, cfg: Config, language: str, prompt_style: str,
              allow_download: bool, prompt_tokens: int = ASR_PROMPT_TOKENS, strategy: Optional[str] = None) -> dict:
    """One model through ``transcribe_track``; ``strategy`` (single | dual) overrides ``cfg.asr_strategy`` for this run."""
    if strategy is not None:
        cfg = dataclasses.replace(cfg, asr_strategy=strategy)
    res = {"model": model, "slug": slugify(model), "error": None, "strategy": strategy}
    t0 = time.time()
    engine = None
    try:
        engine = make_engine(model, allow_download)
        engine.load()
        res["engine"] = getattr(engine, "engine_id", "") or engine.name
        res["load_s"] = round(time.time() - t0, 2)
        t1 = time.time()
        tr = transcribe_track(audio, engine, cfg, vocab, track="bench", language=language, prompt_style=prompt_style, prompt_tokens=prompt_tokens, vad=vad)
        res["asr_s"] = round(time.time() - t1, 2)
        res["segments"] = tr.segments
        res["dropped"] = tr.dropped
        res["dropped_by_reason"] = tr.dropped_by_reason
        res["language"] = tr.language
        res["info"] = tr.info
        res["text"] = "\n".join(s["text"] for s in tr.segments)
    except Exception as exc:   # one broken model must not hide the results of the others
        log.error("%s failed: %s: %s", model, type(exc).__name__, exc)
        res["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if engine is not None:
            engine.release()
    res["wall_s"] = round(time.time() - t0, 2)
    return res


# --------------------------------------------------------------------------------------
# reports
# --------------------------------------------------------------------------------------
def _cell(text: str) -> str:
    return " ".join(text.split()).replace("|", "\\|")


def real_results(results: list[dict]) -> list[dict]:
    """The successful results that transcribed the REAL audio: an external engine's synthetic-clip run only has timing numbers (summary), its text
    says nothing a person said and is left out of the side-by-side, vocabulary and number reports."""
    return [r for r in results if not r["error"] and not r.get("synthetic")]


def render_comparison(results: list[dict], duration: float, bucket: float) -> str:
    ok = real_results(results)
    lines = ["# Side-by-side comparison", "", "Rows are time buckets of the audio slice; each cell holds the segments that start in the bucket.", ""]
    if not ok:
        return "\n".join(lines + ["(no model produced a result)", ""])
    lines.append("| time | " + " | ".join(_cell(r["slug"]) for r in ok) + " |")
    lines.append("|---|" + "---|" * len(ok))
    n = max(1, int(np.ceil(duration / bucket)))
    for b in range(n):
        lo, hi = b * bucket, (b + 1) * bucket
        cells = [" ".join(s["text"] for s in r["segments"] if lo <= s["start"] < hi) for r in ok]
        if any(cells):
            lines.append(f"| {format_ts(lo)} | " + " | ".join(_cell(c) or "-" for c in cells) + " |")
    return "\n".join(lines) + "\n"


def render_vocabulary(results: list[dict], terms: list[str]) -> str:
    ok = real_results(results)
    lines = ["# Vocabulary hits", "", "Case-insensitive whole-term counts in the raw model text (aliases not applied unless --apply-aliases).", ""]
    if not ok:
        return "\n".join(lines + ["(no results)", ""])
    for r in ok:
        r["vocab_hits"] = vocabulary_hits(r["text"], terms)
    lines.append("| term | " + " | ".join(_cell(r["slug"]) for r in ok) + " |")
    lines.append("|---|" + "---|" * len(ok))
    for term in terms:
        counts = [r["vocab_hits"].get(term, 0) for r in ok]
        if any(counts):
            lines.append(f"| {_cell(term)} | " + " | ".join(str(c) for c in counts) + " |")
    lines.append("| **distinct terms hit** | " + " | ".join(f"**{len(r['vocab_hits'])}/{len(terms)}**" for r in ok) + " |")
    lines.append("| **total hits** | " + " | ".join(f"**{sum(r['vocab_hits'].values())}**" for r in ok) + " |")
    return "\n".join(lines) + "\n"


def render_numbers(results: list[dict]) -> str:
    ok = real_results(results)
    lines = ["# Number / price / date / time inventory", "",
             "Digit-based tokens found in each model's text (spelled-out numbers such as 'two dollars fifty' are not detected). "
             "Rows marked `*` differ between models: check them against the audio.", ""]
    if not ok:
        return "\n".join(lines + ["(no results)", ""])
    for r in ok:
        r["numbers"] = number_inventory(r["text"])
    for category, _ in NUMBER_PATTERNS:
        tokens = sorted({t for r in ok for t in r["numbers"][category]})
        lines += [f"## {category}", ""]
        if not tokens:
            lines += ["(none)", ""]
            continue
        lines.append("| token | " + " | ".join(_cell(r["slug"]) for r in ok) + " |")
        lines.append("|---|" + "---|" * len(ok))
        for t in tokens:
            counts = [r["numbers"][category].get(t, 0) for r in ok]
            mark = " *" if len(set(counts)) > 1 else ""
            lines.append(f"| `{_cell(t)}`{mark} | " + " | ".join(str(c) for c in counts) + " |")
        lines.append("")
    return "\n".join(lines)


def summary_rows(results: list[dict], audio_s: float) -> list[dict]:
    rows = []
    for r in results:
        if r["error"]:
            rows.append({"model": r["slug"], "error": r["error"]})
            continue
        info = r["info"]
        hits = r.get("vocab_hits") or Counter()
        nums = r.get("numbers") or {}
        rows.append({
            "model": r["slug"], "engine": r["engine"], "language": r["language"], "vad": info.get("vad"),
            "chunks": info.get("chunks", 0), "segments": len(r["segments"]), "words": info.get("words", 0),
            "dropped": len(r["dropped"]), "dropped_by_reason": r["dropped_by_reason"],
            "loops_collapsed": info.get("loops_collapsed", 0), "prompt_retries": info.get("prompt_retries", 0),
            "retries_accepted": info.get("retries_accepted", 0), "truncated_chunks": info.get("truncated_chunks", 0),
            "failed_chunks": info.get("failed_chunks", 0),
            "vocab_distinct": len(hits), "vocab_total": sum(hits.values()),
            "numbers": sum(sum(c.values()) for c in nums.values()) if nums else 0,
            "load_s": r["load_s"], "asr_s": r["asr_s"], "wall_s": r["wall_s"],
            "rtf": round(r["asr_s"] / r.get("audio_s", audio_s), 3) if r.get("audio_s", audio_s) else None,
            **({"synthetic_clip": True} if r.get("synthetic") else {}),
            **({"strategy": r["strategy"], **{k: v for k, v in strategy_metrics(r["segments"], r["asr_s"], r["wall_s"]).items()
                                              if k not in ("segments", "words", "asr_s", "wall_s")}} if r.get("strategy") else {}),
        })
    return rows


def format_table(rows: list[dict]) -> str:
    """Aligned text table of the successful models, followed by one line per failed model."""
    errors = [f"{r['model']}: ERROR {r['error']}" for r in rows if "error" in r]
    rows = [r for r in rows if "error" not in r]
    cols = [("model", "model"), ("segments", "segs"), ("words", "words"), ("dropped", "drop"), ("loops_collapsed", "loops"),
            ("prompt_retries", "retry"), ("vocab_distinct", "terms"), ("vocab_total", "hits"), ("numbers", "nums"),
            ("load_s", "load s"), ("asr_s", "asr s"), ("rtf", "RTF")]
    table = [[h for _, h in cols]]
    for r in rows:
        table.append([str(r.get(k, "")) for k, _ in cols])
    widths = [max(len(row[i]) for row in table) for i in range(len(cols))]
    lines = ["  ".join(cell.ljust(w) for cell, w in zip(row, widths)).rstrip() for row in table]
    return "\n".join(lines + errors)


def write_outputs(out: Path, results: list[dict], args, audio_s: float, vad: Optional[vadmod.VadResult], vocab: Vocab) -> str:
    out.mkdir(parents=True, exist_ok=True)
    started = datetime.now().astimezone()
    for r in results:
        if r["error"]:
            continue
        d = out / r["slug"]
        d.mkdir(parents=True, exist_ok=True)
        segs = [{**s, "speaker": "Audio", "track": "mic", "lang": s["lang"] or ""} for s in r["segments"]]
        t = make_transcript(r["model"], {"mic": r["language"], "remote": None}, segs)
        meta = {"title": f"ASR benchmark: {Path(args.audio).name if args.audio and not r.get('synthetic') else 'synthetic clip'}",
                "platform_label": "benchmark", "start_time": started.isoformat(), "duration_sec": r.get("audio_s", audio_s), "asr_model": r["model"]}
        (d / "transcript.md").write_text(render_markdown(t, meta, merge_gap=0.0), encoding="utf-8")
        (d / "segments.json").write_text(json.dumps({k: r[k] for k in ("model", "engine", "language", "segments", "dropped", "dropped_by_reason", "info")},
                                                     ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    comparison = render_comparison(results, audio_s, args.bucket)
    vocabulary = render_vocabulary(results, vocab.terms)
    numbers = render_numbers(results)
    rows = summary_rows(results, audio_s)
    table = format_table(rows)
    synthetic_models = [r["slug"] for r in results if r.get("synthetic")]
    if vad is not None:
        header = (f"# ASR benchmark summary\n\nAudio: `{args.audio}` slice {args.start:.0f}s + {audio_s:.0f}s | language mode: {args.language_mode} | "
                  f"prompt style: {args.prompt_style} ({args.prompt_tokens} tokens) | strategy: {args.strategy} | VAD: {vad.label} ({len(vad.regions)} regions, {vad.speech_seconds:.0f}s speech)\n\n")
    else:
        header = f"# ASR benchmark summary\n\nAudio: synthetic clip {audio_s:.0f}s | language mode: {args.language_mode} | prompt style: {args.prompt_style}\n\n"
    if synthetic_models:                       # said in the report itself: these numbers are timings of a synthetic clip, not of the audio above
        header += f"Synthetic clip (no recorded voice left this Mac) for: {', '.join(synthetic_models)}: their rows are timings only.\n\n"
    reasons = "\n".join(f"- {r['model']}: {r.get('dropped_by_reason') or 'none'}" for r in rows if "error" not in r)
    (out / "comparison.md").write_text(comparison, encoding="utf-8")
    (out / "vocabulary.md").write_text(vocabulary, encoding="utf-8")
    (out / "numbers.md").write_text(numbers, encoding="utf-8")
    (out / "summary.md").write_text(header + "```\n" + table + "\n```\n\nDropped segments by reason:\n\n" + (reasons or "-") + "\n", encoding="utf-8")
    (out / "summary.json").write_text(json.dumps({"audio": str(args.audio) if args.audio else None, "start": args.start, "duration_s": audio_s,
                                                  "language_mode": args.language_mode, "prompt_style": args.prompt_style,
                                                  "vad": vad.label if vad is not None else None, "models": rows}, ensure_ascii=False, indent=1,
                                                 default=str), encoding="utf-8")
    return table


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Compare ASR models on one audio slice (local models upload nothing; external engines get a synthetic "
                                            "clip unless you confirm real audio).")
    p.add_argument("--audio", help="audio to transcribe (required unless only external engines are benchmarked)")
    p.add_argument("--allow-real-audio", action="store_true",
                   help="send --audio to external engines too (you type that nobody else was in the meeting)")
    p.add_argument("--synthetic-seconds", type=float, default=20.0, help="length of the synthetic clip of external engines (default 20)")
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--duration", type=float, default=0.0, help="0 = until the end")
    p.add_argument("--models", nargs="+")
    p.add_argument("--language-mode", choices=sorted(LANGUAGE_MODES), default="auto-region")
    p.add_argument("--prompt-style", choices=["none", "list", "frame+list"], default="frame+list")
    p.add_argument("--prompt-tokens", type=int, default=ASR_PROMPT_TOKENS)
    p.add_argument("--vocab", default=str(REPO / "config" / "vocabulary.txt"))
    p.add_argument("--vad", choices=["auto", "silero", "energy"], default="auto")
    p.add_argument("--languages", default=Config().asr_languages, help="ASR_LANGUAGES, e.g. ko,en or ja,ko,en")
    p.add_argument("--strategy", choices=["single", "dual", "both"], default=Config().asr_strategy,
                   help="ASR_STRATEGY of the run; both = every local model once per strategy (default: the built-in default)")
    p.add_argument("--gate-from", nargs="+", metavar="DIR", help="do not transcribe: judge the summary.json of --strategy both runs (see the module doc)")
    p.add_argument("--apply-aliases", action="store_true")
    p.add_argument("--bucket", type=float, default=20.0)
    p.add_argument("--out", default=None)
    p.add_argument("--no-download", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args(argv)
    if args.gate_from:
        return args
    if not args.models:
        p.error("--models is required")
    models = [m for item in args.models for m in item.split(",") if m]
    if not args.audio and not external_engine_ids(models):
        p.error("--audio is required (only external engines can be benchmarked without it: they use the synthetic clip)")
    if args.allow_real_audio and not args.audio:
        p.error("--allow-real-audio needs --audio")
    return args


def main(argv=None) -> int:
    args = parse_args(argv)
    if args.gate_from:
        slices = gate_slices(args.gate_from)
        verdict = strategy_gate(slices)
        print(format_gate(slices, verdict))
        return 0 if verdict["default_dual"] else 1
    logging.basicConfig(level=logging.WARNING if args.quiet else logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s",
                        datefmt="%H:%M:%S", stream=sys.stderr)
    models = [m for item in args.models for m in item.split(",") if m]
    out = Path(args.out) if args.out else Path("benchmarks") / f"bench-{datetime.now():%Y%m%d-%H%M%S}"
    external = external_engine_ids(models)
    real_to_external = False
    if args.audio and external:
        if args.allow_real_audio:
            from mcap import cli
            stop = cli.real_audio_gate(external)            # a terminal and the typed sentence: the audio is a recording of a meeting
            if stop is not None:
                return stop
            real_to_external = True
        else:
            print(f"note: --audio is NOT sent to {', '.join(external)} (add --allow-real-audio to confirm); they get a synthetic clip", flush=True)
    audio = load_audio(Path(args.audio), args.start, args.duration) if args.audio else None
    cfg = Config(asr_vad=args.vad, asr_languages=args.languages)
    synthetic = None
    if external and not real_to_external:
        from mcap import cli
        synthetic = cli.synthetic_audio(args.synthetic_seconds)
    audio_s = len(audio) / SR if audio is not None else len(synthetic) / SR
    full_vocab = load_vocab(Path(args.vocab))
    vocab = full_vocab if args.apply_aliases else Vocab(terms=list(full_vocab.terms), aliases={})
    vad = vadmod.detect_speech(audio, args.vad, cfg.support_dir) if audio is not None else None
    synthetic_vad = vadmod.detect_speech(synthetic, "energy", cfg.support_dir) if synthetic is not None else None   # synthetic 'speech': energy VAD finds it
    if vad is not None:
        print(f"audio {audio_s:.1f}s | VAD {vad.label}: {len(vad.regions)} regions, {vad.speech_seconds:.1f}s speech | "
              f"{len(full_vocab.terms)} vocabulary terms | models: {', '.join(models)}", flush=True)
    else:
        print(f"synthetic clip {audio_s:.1f}s | {len(full_vocab.terms)} vocabulary terms | models: {', '.join(models)}", flush=True)
    language = LANGUAGE_MODES[args.language_mode]
    results = []
    both = args.strategy == "both"
    for model in models:
        use_synthetic = model in external and not real_to_external
        clip, clip_vad = (synthetic, synthetic_vad) if use_synthetic else (audio, vad)
        for strategy in (["single"] if model in external else ["single", "dual"] if both else [args.strategy]):      # audio never goes out twice
            print(f"-- {model}" + (f" [{strategy}]" if both and model not in external else ""), flush=True)
            results.append(run_model(model, clip, clip_vad, vocab, cfg, language, args.prompt_style, not args.no_download, args.prompt_tokens,
                                     strategy=strategy))
            r = results[-1]
            if both and model not in external:
                r["slug"] += f"__{strategy}"
            if use_synthetic:
                r["synthetic"], r["audio_s"] = True, len(clip) / SR
            print("   " + (f"ERROR {r['error']}" if r["error"] else f"{len(r['segments'])} segments, load {r['load_s']}s, asr {r['asr_s']}s"), flush=True)
    table = write_outputs(out, results, args, audio_s, vad, full_vocab)
    print("\n" + table + f"\n\nreport written to {out}/ (comparison.md, vocabulary.md, numbers.md, summary.md, <model>/transcript.md)")
    return 0 if any(not r["error"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
