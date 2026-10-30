"""Domain vocabulary (config/vocabulary.txt). One term per line, optional aliases:

    Canonical
    Canonical = alias1 | alias2     # ASR often writes the alias; replaced by Canonical (exact match only)

Additive changes only: keep the Vocab fields and the function signatures.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

_HANGUL = re.compile(r"[ᄀ-ᇿ㄰-㆏가-힯]")


@dataclass
class Vocab:
    terms: list[str] = field(default_factory=list)          # canonical terms in file order (priority order)
    aliases: dict[str, str] = field(default_factory=dict)   # alias (casefolded) -> canonical


def parse_vocab_text(text: str) -> Vocab:
    vocab = Vocab()
    seen: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # inline comment
        for i, ch in enumerate(line):
            if ch == "#" and i > 0 and line[i - 1].isspace():
                line = line[:i].strip()
                break
        canonical, sep, alias_part = line.partition("=")
        canonical = canonical.strip()
        if not canonical:
            continue
        if canonical.casefold() not in seen:
            seen.add(canonical.casefold())
            vocab.terms.append(canonical)
        if sep:
            for alias in alias_part.split("|"):
                alias = alias.strip()
                if alias:
                    vocab.aliases[alias.casefold()] = canonical
    return vocab


def load_vocab(path: Path) -> Vocab:
    if not path.exists():
        return Vocab()
    return parse_vocab_text(path.read_text(encoding="utf-8"))


def apply_aliases(text: str, vocab: Vocab) -> str:
    """Replace known mis-transcriptions by their canonical spelling.

    Latin aliases need word boundaries; aliases containing Hangul are replaced anywhere (Korean particles attach directly).
    Longest alias first so that overlapping aliases behave deterministically. Numbers/dates are never touched.
    """
    if not vocab.aliases or not text:
        return text
    for alias in sorted(vocab.aliases, key=len, reverse=True):
        canonical = vocab.aliases[alias]
        if _HANGUL.search(alias):
            pattern = re.compile(re.escape(alias), re.IGNORECASE)
        else:
            pattern = re.compile(r"(?<![\w])" + re.escape(alias) + r"(?![\w])", re.IGNORECASE)
        text = pattern.sub(canonical, text)
    return text
