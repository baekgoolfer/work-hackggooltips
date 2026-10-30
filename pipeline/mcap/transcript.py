"""Transcript data and rendering (SPEC 4.4, 4.5).

``transcript.json`` (the source of truth) keeps every ASR segment of both tracks in time order::

    {"schema": 1, "asr_model": "...", "languages": {"mic": "ko", "remote": "en"},
     "segments": [{"start", "end", "speaker", "track", "lang", "text", "avg_logprob", "no_speech_prob"}, ...],
     ...extra keys added by asr.transcribe_tracks (dropped, dropped_reasons, echo_suppressed, echo_suppressed_reasons, aec,
     speech_seconds, missing_tracks, stats)}

Two optional blocks exist only when something left the default local path (SPEC 18); without them
transcript.json and transcript.md are byte for byte what they always were:

* ``"asr"``: provenance of an external or routed ASR engine (``engine``, ``kind``, ``model``, ``destination`` label, ``region``,
  ``chunks`` {engine: n}, ``fallbacks``, ...; ``privacy`` is ``unknown`` when an external engine's own record was unusable).
  ``render_markdown`` adds one ``Route:`` line after ``ASR:`` for it. A local ``ASR_STRATEGY=dual`` run also writes this block, with only
  ``engine``, ``kind: local``, ``strategy: dual`` and the counts ``dual`` {chunks, conflicts, plain_chosen, restored}; nothing left the Mac,
  so it has no ``Route:`` line (the header of a dual transcript is the one of a single transcript).
* ``"policy"``: set by the pipeline when the meeting is local-only or the organization denied a lane: ``{"local_only": bool,
  "lanes": {"llm": "skipped:<reason>", "calendar": ..., "drive": ...}}``. ``render_markdown`` adds one ``Privacy:`` line for it
  ("Privacy: local-only (note, calendar, Drive skipped)").

``transcript.md`` is the human version: both tracks merged by time, adjacent segments of the same speaker (gap < 2 s)
joined into one block, but never a block longer than about a minute (``MAX_BLOCK_SEC``) or 600 characters
(``MAX_BLOCK_CHARS``): a remote speaker who talks for ten minutes with short pauses still gets a timestamp every minute, because
the note model and the human use these timestamps to find things again.
"""
from __future__ import annotations

import math
from datetime import datetime

SCHEMA = 1
MERGE_GAP_SEC = 2.0
MAX_BLOCK_SEC = 60.0            # a block of one speaker spans at most this long (a single longer segment stays whole)
MAX_BLOCK_CHARS = 600           # ... and holds at most this many characters
TRACK_ORDER = {"mic": 0, "remote": 1}
REMOTE_LABEL = "Remote"


def format_ts(seconds) -> str:
    """Seconds -> "HH:MM:SS" (floored; negative, NaN or missing values give 00:00:00; hours may exceed 99)."""
    try:
        s = float(seconds)
    except (TypeError, ValueError):
        return "00:00:00"
    if not math.isfinite(s) or s < 0:
        return "00:00:00"
    total = int(s)
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def make_transcript(asr_model: str, languages: dict, segments: list[dict], **extra) -> dict:
    """Assemble the transcript.json dict: segments of all tracks sorted by time (mic before remote on ties)."""
    ordered = sorted(segments, key=lambda s: (s["start"], s["end"], TRACK_ORDER.get(s.get("track"), 9)))
    out = {"schema": SCHEMA, "asr_model": asr_model, "languages": languages, "segments": ordered}
    out.update(extra)
    return out


def validate_transcript(t) -> list[str]:
    """Problems found when checking ``t`` against the SPEC 4.4 shape (empty list = valid)."""
    problems: list[str] = []
    if not isinstance(t, dict):
        return ["transcript is not an object"]
    if t.get("schema") != SCHEMA:
        problems.append(f"schema must be {SCHEMA}")
    if not isinstance(t.get("asr_model"), str) or not t.get("asr_model"):
        problems.append("asr_model must be a non-empty string")
    langs = t.get("languages")
    if not isinstance(langs, dict) or not all(k in langs for k in TRACK_ORDER):
        problems.append("languages must be an object with mic and remote")
    for key in ("asr", "policy"):
        if key in t and not isinstance(t[key], dict):
            problems.append(f"{key} must be an object")
    segs = t.get("segments")
    if not isinstance(segs, list):
        return problems + ["segments must be a list"]
    prev_start = -1.0
    for i, s in enumerate(segs):
        if not isinstance(s, dict):
            problems.append(f"segments[{i}] is not an object")
            continue
        for key, types in (("start", (int, float)), ("end", (int, float)), ("speaker", str), ("track", str), ("lang", str), ("text", str)):
            if not isinstance(s.get(key), types) or isinstance(s.get(key), bool):
                problems.append(f"segments[{i}].{key} missing or wrong type")
        for key in ("avg_logprob", "no_speech_prob"):
            if key not in s or not (s[key] is None or isinstance(s[key], (int, float))):
                problems.append(f"segments[{i}].{key} must be a number or null")
        if isinstance(s.get("start"), (int, float)) and isinstance(s.get("end"), (int, float)):
            if not (0 <= s["start"] <= s["end"]):
                problems.append(f"segments[{i}] has an invalid time range {s['start']}..{s['end']}")
            if s["start"] < prev_start:
                problems.append(f"segments[{i}] is out of time order")
            prev_start = s["start"]
        if s.get("track") not in TRACK_ORDER:
            problems.append(f"segments[{i}].track must be mic or remote")
        if isinstance(s.get("text"), str) and not s["text"].strip():
            problems.append(f"segments[{i}] has empty text")
    return problems


def merge_adjacent(segments: list[dict], gap: float = MERGE_GAP_SEC, max_block_sec: float | None = MAX_BLOCK_SEC,
                   max_block_chars: int | None = MAX_BLOCK_CHARS) -> list[dict]:
    """Blocks ``{"speaker", "track", "start", "end", "text"}`` in time order. A segment joins the previous block when the
    speaker is the same and it starts less than ``gap`` seconds after the block ended (overlaps count as adjacent) AND the
    block would stay within ``max_block_sec`` seconds / ``max_block_chars`` characters (None = no limit); otherwise a new block
    with its own timestamp starts. A single segment longer than a limit is never split."""
    blocks: list[dict] = []
    ordered = sorted(segments, key=lambda s: (s["start"], s["end"], TRACK_ORDER.get(s.get("track"), 9)))
    for s in ordered:
        text = " ".join(str(s.get("text", "")).split())
        if not text:
            continue
        last = blocks[-1] if blocks else None
        if last and last["speaker"] == s["speaker"] and s["start"] - last["end"] < gap:
            fits = ((max_block_sec is None or max(last["end"], s["end"]) - last["start"] <= max_block_sec)
                    and (max_block_chars is None or len(last["text"]) + 1 + len(text) <= max_block_chars))
            if fits:
                last["text"] += " " + text
                last["end"] = max(last["end"], s["end"])
                continue
        blocks.append({"speaker": s["speaker"], "track": s.get("track"), "start": s["start"], "end": s["end"], "text": text})
    return blocks


def _parse_start(value):
    if isinstance(value, datetime):
        return value
    if isinstance(value, str) and value.strip():
        try:
            return datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            return None
    return None


def _tz_label(dt: datetime) -> str:
    """"KST" when the offset of ``dt`` is this machine's own (naive times are taken as local), "UTC", or "UTC+09:00" style."""
    offset = dt.utcoffset()
    try:
        local = dt.astimezone()
        if (offset is None or local.utcoffset() == offset) and local.tzname() and not local.tzname().startswith("UTC"):
            return local.tzname()
    except (OverflowError, OSError, ValueError):
        pass
    if offset is None:
        return "local"
    minutes = int(offset.total_seconds() // 60)
    if minutes == 0:
        return "UTC"
    sign = "+" if minutes > 0 else "-"
    return f"UTC{sign}{abs(minutes) // 60:02d}:{abs(minutes) % 60:02d}"


def _one_line(value) -> str:
    return " ".join(str(value).split())


def route_line(asr) -> str:
    """The ``Route:`` header line for a ``transcript["asr"]`` provenance block, "" when there is none (every local-only run):
    ``Route: remote (server, kr) via company-asr  (chunks: remote 41, whisper 7; fallbacks: 7)``. The destination is the label of the
    consent or policy (or ``vendor/region``), never a host name: this file goes to the shared archive."""
    if not isinstance(asr, dict) or not asr:
        return ""
    if asr.get("kind") == "local" and not any(k in asr for k in ("privacy", "chunks", "destination")):    # asr.py's dual strategy record: no route
        return ""
    head = _one_line(asr.get("engine") or "unknown")
    kind = [_one_line(asr[k]) for k in ("kind", "region") if asr.get(k)]
    if kind:
        head += f" ({', '.join(kind)})"
    if asr.get("destination"):
        head += f" via {_one_line(asr['destination'])}"
    details = []
    if asr.get("privacy") == "unknown":               # the engine's own record was unusable (asr._provenance wrote the minimal block)
        details.append("privacy unknown")
    chunks = asr.get("chunks")
    if isinstance(chunks, dict) and chunks:
        details.append("chunks: " + ", ".join(f"{_one_line(k)} {_one_line(v)}" for k, v in chunks.items()))
    for key, label in (("fallbacks", "fallbacks"), ("circuit_opened", "circuit opened")):
        if isinstance(asr.get(key), (int, float)) and not isinstance(asr.get(key), bool) and asr[key]:
            details.append(f"{label}: {int(asr[key])}")
    return "Route: " + head + (f"  ({'; '.join(details)})" if details else "")


_PRIVACY_LANES = (("llm", "note"), ("calendar", "calendar"), ("drive", "Drive"))     # lane id -> what the reader knows it as


def privacy_line(policy) -> str:
    """The ``Privacy:`` header line for a ``transcript["policy"]`` block, "" when there is none. Local-only meetings read
    ``Privacy: local-only (note, calendar, Drive skipped)``; a block from an organization denial reads
    ``Privacy: restricted by organization policy (note skipped)``. The skipped lanes come from ``policy["lanes"]`` (values that start with
    "skipped"); a block that does not say falls back to the three lanes a local-only meeting skips."""
    if not isinstance(policy, dict) or not policy:
        return ""
    lanes = policy.get("lanes") if isinstance(policy.get("lanes"), dict) else {}
    skipped = [label for lane, label in _PRIVACY_LANES if str(lanes.get(lane, "")).startswith("skipped")]
    if policy.get("local_only") is True:
        return f"Privacy: local-only ({', '.join(skipped or [label for _, label in _PRIVACY_LANES])} skipped)"
    return "Privacy: restricted by organization policy" + (f" ({', '.join(skipped)} skipped)" if skipped else "")


def render_markdown(transcript: dict, meta: dict, merge_gap: float = MERGE_GAP_SEC, max_block_sec: float | None = MAX_BLOCK_SEC,
                    max_block_chars: int | None = MAX_BLOCK_CHARS) -> str:
    """transcript.md exactly as in SPEC 4.4.

    ``meta`` keys (all optional): title, date (YYYY-MM-DD), platform_label, start_time (ISO 8601 string or datetime),
    duration_sec, asr_model. The speaker label of each block is the segment's ``speaker`` (SELF_NAME or "Remote").
    ``merge_gap`` is the SPEC 4.4 merge distance (2 s); benchmarks pass 0 to keep every ASR segment visible.
    ``max_block_sec`` / ``max_block_chars`` cap one block (a new timestamp starts when a same-speaker run gets longer).

    A ``Route:`` line (``transcript["asr"]``) and a ``Privacy:`` line (``transcript["policy"]``) follow the ``ASR:`` line only when the
    transcript has those blocks; the header of a default local transcript is unchanged.
    """
    meta = meta or {}
    start = _parse_start(meta.get("start_time"))
    date = meta.get("date") or (start.strftime("%Y-%m-%d") if start else "unknown")
    title = " ".join(str(meta.get("title") or "").split()) or meta.get("platform_label") or "Untitled meeting"
    duration = meta.get("duration_sec")
    if duration is None:
        ends = [s.get("end", 0) for s in transcript.get("segments", [])]
        duration = max(ends) if ends else 0
    start_text = f"{start.strftime('%H:%M:%S')} ({_tz_label(start)})" if start else "unknown"
    langs = transcript.get("languages") if isinstance(transcript.get("languages"), dict) else {}
    order = [t for t in TRACK_ORDER if t in langs] + [t for t in langs if t not in TRACK_ORDER]      # mic, remote, then others
    lang_text = ", ".join(f"{t}: {langs[t] or '-'}" for t in order)
    asr_model = meta.get("asr_model") or transcript.get("asr_model") or "unknown"
    lines = [
        "# Transcript",
        "",
        f"Meeting: {title}",
        f"Date: {date}",
        f"Platform: {meta.get('platform_label') or 'unknown'}",
        f"Start: {start_text}   Duration: {format_ts(duration)}",
        f"ASR: {asr_model}" + (f"  ({lang_text})" if lang_text else ""),
    ]
    lines += [extra for extra in (route_line(transcript.get("asr")), privacy_line(transcript.get("policy"))) if extra]
    lines.append("")
    blocks = merge_adjacent(transcript.get("segments", []), merge_gap, max_block_sec, max_block_chars)
    if not blocks:
        lines += ["(no speech detected)", ""]
    for b in blocks:
        lines += [f"[{format_ts(b['start'])}] {b['speaker']}", b["text"], ""]
    return "\n".join(lines).rstrip("\n") + "\n"
