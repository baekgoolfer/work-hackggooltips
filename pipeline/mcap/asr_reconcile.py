"""Dual-pass reconciliation (``ASR_STRATEGY=dual``): deterministic, no model, no network.

Dual mode decodes every VAD chunk twice with the SAME local engine: pass P is today's prompted decode (language frame + vocabulary prompt),
pass N is the plain decode of the same audio and language (no prompt). The prompt keeps more of your own terms but sometimes bends numbers
and merges short utterances; the plain decode is the opposite. ``reconcile`` merges the two segment lists of ONE chunk (times relative to the
chunk start) before the post-filters and echo suppression run:

1. align: a P and an N segment belong together when ``overlap / min(duration) >= ALIGN_MIN_OVERLAP``; the links are followed transitively
   (one P segment against three N segments is one group, and so is a chain), and each group is judged as a whole;
2. a group whose two sides read the same after normalisation (case, punctuation, spacing) keeps P;
3. otherwise each side is scored: + vocabulary term hits (``terms``, normalised) - implausible numbers (``implausible_numbers``). The
   higher score wins. On equal scores N wins only for a pure figure disagreement: both sides plausible, the digit tokens differ, both carry
   the same NUMBER of digit tokens (a figure that N spells out or drops is lost content, not a correction) and N has at least
   ``TIE_MIN_COVERAGE`` of P's words (a truncated N would silently drop spoken content); every other tie goes to P. One guard comes first: a
   side with a looped segment (compression ratio above ``LOOP_COMPRESSION_RATIO``, what the post-filter drops anyway) loses to a side without
   one, so a repeated term cannot win by volume;
4. N segments that align with no P segment are RESTORED when they last ``RESTORE_MIN_DURATION_S``, have ``avg_logprob >=
   RESTORE_MIN_AVG_LOGPROB`` and ``no_speech_prob <= RESTORE_MAX_NO_SPEECH`` (a missing number fails the test: nothing is added that the
   decoder did not vouch for), carry content, and are not a repeat of the neighbour on either side (the same words, or a run of at least two
   words that sits wholly inside the neighbour);
5. P segments with no N counterpart are kept.

The result is sorted by time and only contains segments of the inputs (nothing is rewritten). ``Reconciled`` carries the counts that go to
``transcript.json`` (``stats.<track>.dual`` and ``asr``): ``conflicts``, ``plain_chosen`` and ``restored``.

Implausible numbers (``implausible_numbers``) are a deliberately conservative heuristic for the figure artefacts a vocabulary prompt can
cause ("80,000억" where the speaker said "400억"). Only two shapes count, both followed by a Korean magnitude word:

* a digit group WITH a thousands separator whose value exceeds ``MAX_PLAUSIBLE_AMOUNT`` (default 10**12 = 1 jo): 80,000억 and 400,000억 are
  flagged, 1,200억 and 10,000억 are not;
* an UNSEPARATED run of more than ``MAX_PLAIN_DIGITS_BEFORE_EOK`` (3) digits before 억: 4000억 and 40000억 are flagged, 400억 and 83억 are not.

Everything else (13조, 400억, 3.5억, 1,000,000원, English figures) is never flagged, so a real large amount is not penalised by a guess.
"""
from __future__ import annotations

import bisect
import functools
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Iterable, Sequence

ALIGN_MIN_OVERLAP = 0.3                  # overlap / shorter duration for P and N to be the same speech
RESTORE_MIN_DURATION_S = 0.4             # an N-only segment shorter than this is a click, not an utterance
RESTORE_MIN_AVG_LOGPROB = -0.9           # ... and the decoder must be reasonably sure of it
RESTORE_MAX_NO_SPEECH = 0.5
LOOP_COMPRESSION_RATIO = 2.4             # the post-filter's cr_max: a side above it is dropped later anyway
MAX_PLAUSIBLE_AMOUNT = 10 ** 12          # won: a thousands-separated figure above this is an artefact (1 jo)
MAX_PLAIN_DIGITS_BEFORE_EOK = 3          # an unseparated figure of more digits than this before 억 is an artefact (400억 yes, 4000억 no)
TIE_MIN_COVERAGE = 0.8                   # on a tie N may win the digits only with at least this share of P's words (no truncated answer)
_EPS = 1e-6

_UNITS = {"만": 10 ** 4, "억": 10 ** 8, "조": 10 ** 12, "경": 10 ** 16}
_AMOUNT = re.compile(r"(?<![\d,.])(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?\s?([만억조경])")
_DIGITS = re.compile(r"\d+(?:[.,]\d+)*")


def norm_text(text: str) -> str:
    """Case-folded text with punctuation removed and spaces collapsed (the same rule as ``asr._norm``)."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", str(text).casefold())).strip()


# ---------------------------------------------------------------------------------------
# scoring helpers
# ---------------------------------------------------------------------------------------
@functools.lru_cache(maxsize=16)
def _term_pattern(terms: tuple[str, ...]):
    """One regex over the normalised terms, longest first so that a term inside a longer one is not counted twice. A term made of ASCII
    letters and digits must not be glued to other ASCII letters or digits (a Korean particle after it is fine: "FDA는" is a hit); any
    other term (Hangul, kana, ...) is matched as a substring, like ``bench_asr.count_term``."""
    plain, wide = set(), set()
    for term in terms:
        n = norm_text(term)
        if n:
            (plain if n.isascii() else wide).add(n)
    parts = []
    for group, bounded in ((plain, True), (wide, False)):
        if group:
            body = "|".join(re.escape(t) for t in sorted(group, key=lambda t: (-len(t), t)))
            parts.append(f"(?<![a-z0-9])(?:{body})(?![a-z0-9])" if bounded else f"(?:{body})")
    return re.compile("|".join(parts)) if parts else None


def term_hits(text: str, terms: Iterable[str]) -> int:
    """How many times the vocabulary ``terms`` occur in ``text`` (normalised, longest term first, no overlaps)."""
    pattern = _term_pattern(tuple(terms))
    return len(pattern.findall(norm_text(text))) if pattern else 0


def implausible_numbers(text: str, *, max_amount: float = MAX_PLAUSIBLE_AMOUNT, max_plain_digits: int = MAX_PLAIN_DIGITS_BEFORE_EOK) -> list[str]:
    """The figures of ``text`` that look like a prompt-induced artefact (see the module doc for the two shapes); the matched text of each."""
    found = []
    for m in _AMOUNT.finditer(text):
        whole, fraction, unit = m.group(1), m.group(2) or "", m.group(3)
        if "," in whole:
            bad = float(whole.replace(",", "") + fraction) * _UNITS[unit] > max_amount
        else:
            bad = unit == "억" and len(whole) > max_plain_digits
        if bad:
            found.append(m.group(0))
    return found


def digit_tokens(text: str) -> Counter:
    """The digit tokens of ``text`` with thousands separators removed ("1,200" and "1200" are the same figure)."""
    return Counter(t.replace(",", "") for t in _DIGITS.findall(text))


# ---------------------------------------------------------------------------------------
# segments
# ---------------------------------------------------------------------------------------
def _text(seg: dict) -> str:
    return str(seg.get("text") or "").strip()


def _span(seg: dict) -> tuple[float, float]:
    start = float(seg.get("start") or 0.0)
    return start, max(start, float(seg.get("end") or start))


def _order(seg: dict) -> tuple[float, float]:
    return _span(seg)


def overlap_ratio(a: dict, b: dict) -> float:
    """Overlap of two segments divided by the shorter duration (0..1). A zero-length segment counts as 1.0 when its instant lies inside the
    other one."""
    (a0, a1), (b0, b1) = _span(a), _span(b)
    inter = min(a1, b1) - max(a0, b0)
    shortest = min(a1 - a0, b1 - b0)
    if shortest <= _EPS:
        return 1.0 if inter >= -_EPS else 0.0
    return max(0.0, inter) / shortest


def _groups(p: Sequence[dict], n: Sequence[dict], min_overlap: float) -> list[tuple[list[dict], list[dict]]]:
    """Connected groups of the overlap graph between ``p`` and ``n``: ``(p members, n members)`` each in time order, groups in time order."""
    parent = list(range(len(p) + len(n)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(p):
        for j, b in enumerate(n):
            if overlap_ratio(a, b) >= min_overlap:
                parent[find(i)] = find(len(p) + j)
    members: dict[int, tuple[list[dict], list[dict]]] = {}
    for i, seg in enumerate(p):
        members.setdefault(find(i), ([], []))[0].append(seg)
    for j, seg in enumerate(n):
        members.setdefault(find(len(p) + j), ([], []))[1].append(seg)
    groups = [(sorted(a, key=_order), sorted(b, key=_order)) for a, b in members.values()]
    return sorted(groups, key=lambda g: min(_order(s) for s in g[0] + g[1]))


def _looped(side: Sequence[dict]) -> bool:
    return any((s.get("compression_ratio") or 0.0) > LOOP_COMPRESSION_RATIO for s in side)


def _contains_run(words: list[str], run: list[str]) -> bool:
    n = len(run)
    return n > 0 and any(words[i:i + n] == run for i in range(len(words) - n + 1))


def is_repeat(text: str, neighbour: str) -> bool:
    """Is ``text`` a repeat of ``neighbour``: the same words after normalisation, or at least two words that sit wholly inside it?"""
    a, b = norm_text(text), norm_text(neighbour)
    if not a or not b:
        return False
    if a == b:
        return True
    words = a.split()
    return len(words) >= 2 and _contains_run(b.split(), words)


@dataclass
class Reconciled:
    segments: list[dict] = field(default_factory=list)
    equal: int = 0              # groups whose sides read the same: P kept
    conflicts: int = 0          # groups whose sides differ and were scored
    plain_chosen: int = 0       # ... of which the plain decode won
    restored: int = 0           # N-only segments added back
    rejected: int = 0           # N-only segments that failed a restore test

    def counts(self) -> dict[str, int]:
        return {"conflicts": self.conflicts, "plain_chosen": self.plain_chosen, "restored": self.restored}


def _prefer_plain(p_text: str, n_text: str, p_side: Sequence[dict], n_side: Sequence[dict], terms: tuple[str, ...], *, max_amount: float,
                  max_plain_digits: int) -> bool:
    """Rule 3 for two sides that read differently: True when the plain decode wins."""
    if _looped(p_side) != _looped(n_side):
        return _looped(p_side)
    bad_p = len(implausible_numbers(p_text, max_amount=max_amount, max_plain_digits=max_plain_digits))
    bad_n = len(implausible_numbers(n_text, max_amount=max_amount, max_plain_digits=max_plain_digits))
    score_p, score_n = term_hits(p_text, terms) - bad_p, term_hits(n_text, terms) - bad_n
    if score_p != score_n:
        return score_n > score_p
    if bad_p or bad_n:
        return False
    dp, dn = digit_tokens(p_text), digit_tokens(n_text)
    return (dp != dn and sum(dp.values()) == sum(dn.values())
            and len(norm_text(n_text).split()) >= TIE_MIN_COVERAGE * len(norm_text(p_text).split()))


def _restorable(seg: dict, *, min_duration: float, min_logprob: float, max_no_speech: float) -> bool:
    start, end = _span(seg)
    lp, ns = seg.get("avg_logprob"), seg.get("no_speech_prob")
    return (end - start >= min_duration - _EPS and lp is not None and lp >= min_logprob and ns is not None and ns <= max_no_speech
            and bool(norm_text(_text(seg))))


def reconcile(prompted: Sequence[dict], plain: Sequence[dict], terms: Sequence[str] = (), *, min_overlap: float = ALIGN_MIN_OVERLAP,
              restore_min_duration: float = RESTORE_MIN_DURATION_S, restore_min_logprob: float = RESTORE_MIN_AVG_LOGPROB,
              restore_max_no_speech: float = RESTORE_MAX_NO_SPEECH, max_amount: float = MAX_PLAUSIBLE_AMOUNT,
              max_plain_digits: int = MAX_PLAIN_DIGITS_BEFORE_EOK) -> Reconciled:
    """Merge the segments of pass P (``prompted``) and pass N (``plain``) of one chunk; see the module doc for the five rules. Segments are
    dicts with ``start``, ``end``, ``text`` (and ``avg_logprob``, ``no_speech_prob``, ``compression_ratio`` when the engine has them) on one
    time base; the inputs are not modified and the result holds the very same dicts. Segments without text are ignored."""
    p = [s for s in prompted if _text(s)]
    n = [s for s in plain if _text(s)]
    vocab = tuple(terms)
    out = Reconciled()
    kept: list[dict] = []
    only_n: list[dict] = []
    for p_side, n_side in _groups(p, n, min_overlap):
        if not n_side:
            kept += p_side                                                               # rule 5
        elif not p_side:
            only_n += n_side                                                             # rule 4 candidates
        else:
            p_text, n_text = " ".join(_text(s) for s in p_side), " ".join(_text(s) for s in n_side)
            if norm_text(p_text) == norm_text(n_text):                                   # rule 2
                out.equal += 1
                kept += p_side
                continue
            out.conflicts += 1                                                           # rule 3
            if _prefer_plain(p_text, n_text, p_side, n_side, vocab, max_amount=max_amount, max_plain_digits=max_plain_digits):
                out.plain_chosen += 1
                kept += n_side
            else:
                kept += p_side
    kept.sort(key=_order)
    for seg in sorted(only_n, key=_order):
        if not _restorable(seg, min_duration=restore_min_duration, min_logprob=restore_min_logprob, max_no_speech=restore_max_no_speech):
            out.rejected += 1
            continue
        at = bisect.bisect_right([_order(s) for s in kept], _order(seg))
        if any(is_repeat(_text(seg), _text(kept[i])) for i in (at - 1, at) if 0 <= i < len(kept)):
            out.rejected += 1
            continue
        kept.insert(at, seg)
        out.restored += 1
    out.segments = kept
    return out
