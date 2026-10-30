#!/usr/bin/env python3
"""Golden fixtures of the DEFAULT local ASR path (11.3-engine-seam).

The files next to this script were frozen from the code as it was BEFORE the engine seam was added, with this script, and
``test_default_unchanged.py`` regenerates every one of them from the current code and compares byte for byte. The default path
(no policy, no external engine, nothing new in the config) must keep producing the same transcript, the same transcript.md, the same
note footer and the same archive, so a change of a golden file is a change of the product's output: regenerate one only on purpose and
say so in the review.

    default_transcribe_tracks.json   asr.transcribe_tracks with a scripted engine: three scenarios (language ID, an engine without
                                     language ID, a forced language) with the engine's call log and the progress messages
    default_transcript.md            transcript.render_markdown of the first scenario
    default_footer.txt               note.build_footer with a fixed ``when``
    default_archive_listing.json     pipeline.process_session into a temp archive: file names, sha256 of transcript.json and
                                     transcript.md (FakeASR, and the real asr.transcribe_tracks with the scripted engine)

Determinism: time.time is replaced by a counter inside ``asr`` and ``vad`` (the only modules that stamp durations into the
transcript), the time zone is pinned to Asia/Seoul, the VAD is the energy one, the echo canceller is off (MIC_AEC=0), the model
and the vocabulary are written by this script. Nothing touches the real SUPPORT_DIR, LOG_DIR or Keychain.

    python pipeline/tests/golden/make_golden.py --check     # compare with the frozen files (exit 1 on a difference)
    python pipeline/tests/golden/make_golden.py --write     # create them (refuses to overwrite; --force to replace on purpose)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))          # pipeline/
sys.path.insert(0, str(HERE.parent))              # pipeline/tests/

import numpy as np  # noqa: E402

from mcap import asr, asr_engines, audioprep, note, pipeline, transcript, vad  # noqa: E402
from mcap.asr_engines import Engine, WhisperEngine  # noqa: E402
from mcap.config import Config  # noqa: E402
from mcap.vocab import parse_vocab_text  # noqa: E402

SR = 16000
TZ = "Asia/Seoul"
GOLDEN_FILES = ("default_transcribe_tracks.json", "default_transcript.md", "default_footer.txt", "default_archive_listing.json")
VOCAB_TEXT = "Acme\nAcmeScan-CXR\nFDA\n510(k)\nPre-Sub\nHIPAA\nExample Radiology\nAcme = 애크미 | 액미\n"
META = {"title": "Weekly Sync", "date": "2026-10-07", "platform_label": "Google Meet", "start_time": "2026-10-07T14:00:12+09:00",
        "duration_sec": 63.0, "asr_model": "mlx-community/whisper-large-v3-mlx"}


# ---------------------------------------------------------------------------------------
# determinism helpers
# ---------------------------------------------------------------------------------------
@contextmanager
def pinned_tz(name: str = TZ):
    old = os.environ.get("TZ")
    os.environ["TZ"] = name
    time.tzset()
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()


@contextmanager
def fake_clock(step: float = 0.25):
    """time.time of asr and vad -> one shared counter (every call advances it by ``step``)."""
    state = {"t": 1_000_000.0}

    def tick() -> float:
        state["t"] += step
        return state["t"]

    clock = SimpleNamespace(time=tick)           # asr/vad use time.time and nothing else: anything more is an AttributeError here
    with mock.patch.object(asr, "time", clock), mock.patch.object(vad, "time", clock):
        yield


# ---------------------------------------------------------------------------------------
# the scripted engine
# ---------------------------------------------------------------------------------------
class _SpaceTokenizer:
    def encode(self, text):
        return text.split()


def _lid(clip) -> dict:
    """Loud regions are Korean, quiet ones English (like the language-ID stub of test_asr)."""
    return {"ko": 0.97, "en": 0.03} if float(np.abs(clip).max()) > 0.15 else {"ko": 0.03, "en": 0.97}


def _seg(start, end, text, lp=-0.3, ns=0.02, cr=1.1) -> dict:
    return {"start": round(start, 2), "end": round(end, 2), "text": text, "avg_logprob": lp, "no_speech_prob": ns,
            "compression_ratio": cr, "temperature": 0.0}


def _script(audio, language, prompt, kind) -> dict:
    """``kind`` cycles over the calls that carry a prompt: 0 normal, 1 poor (retried), 2 phantom + real, 3 loop + punctuation."""
    d = len(audio) / SR
    ko = language == "ko"
    if prompt is None:                                                    # the retry without the prompt (or a prompt-less run)
        text = "다시 들어 보니 이렇게 말했습니다." if ko else "On a second listen this is what was said."
        return {"text": text, "language": language, "avg_logprob": -0.2, "segments": [_seg(0.3, d - 0.3, text, -0.2)]}
    if kind == 1:                                                         # poor first pass: retried without the prompt
        text = "uncertain words from the first pass"
        return {"text": text, "language": language, "avg_logprob": -1.4, "segments": [_seg(0.3, d - 0.3, text, -1.4)]}
    if kind == 2:                                                         # a phantom phrase and a real sentence
        real = "FDA 심사 일정은 다음 달입니다." if ko else "The FDA review is scheduled for next month."
        return {"text": "", "language": language, "avg_logprob": -0.3,
                "segments": [_seg(0.0, 1.5, "Thanks for watching!", -0.2), _seg(1.6, d - 0.3, real)]}
    if kind == 3:                                                         # a loop, and punctuation over silence
        return {"text": "", "language": language, "avg_logprob": -0.3,
                "segments": [_seg(0.2, 2.0, "아 아 아 아 아 알겠습니다"), _seg(2.1, 2.6, "!", -0.5, 0.1)]}
    first = "액미 파일럿 계약을 검토했습니다." if ko else "We reviewed the Acme pilot contract."
    second = "다음 주에 Pre-Sub 미팅을 잡겠습니다." if ko else "Let us schedule the Pre-Sub meeting next week."
    mid = d / 2
    return {"text": first + " " + second, "language": language, "avg_logprob": -0.3,
            "segments": [_seg(0.2, mid - 0.1, first), _seg(mid, d - 0.2, second, -0.35)]}


class GoldenEngine(Engine):
    """Deterministic engine that records every call (what the engine saw is part of the golden file)."""
    name = "golden-fake"
    prompt_frames = WhisperEngine.prompt_frames

    def __init__(self, supports_lid: bool = True):
        super().__init__("golden-fake-model")
        self.supports_lid = supports_lid
        self.calls: list = []                 # [n_samples, language, prompt]
        self.prompted = 0                     # calls that carried a prompt so far (picks the scripted behaviour)
        self.lid_calls: list = []             # clips per detect_languages call
        self.loaded = 0
        self.released = 0

    def load(self):
        self.loaded += 1

    @property
    def tokenizer(self):
        return _SpaceTokenizer()

    def detect_languages(self, clips, languages=asr_engines.LID_CANDIDATES):
        self.lid_calls.append(len(clips))
        return [asr_engines.restrict_lid(_lid(c), languages) for c in clips]

    def release(self):
        self.released += 1

    def transcribe_chunk(self, audio, language, prompt):
        self.calls.append([len(audio), language, prompt])
        kind = self.prompted % 4
        if prompt is not None:
            self.prompted += 1
        return _script(audio, language, prompt, kind)


# ---------------------------------------------------------------------------------------
# synthetic audio (no random numbers: the energy VAD must see the same regions on every run)
# ---------------------------------------------------------------------------------------
def _burst(n: int, amp: float) -> np.ndarray:
    t = np.arange(n) / SR
    tone = np.sin(2 * np.pi * (180 + 40 * np.sin(2 * np.pi * 3 * t)) * t) + 0.5 * np.sin(2 * np.pi * 620 * t)
    env = 0.8 * 0.5 * (1 + np.sin(2 * np.pi * 4 * t)) + 0.2
    return amp * tone * env


def synth_track(bursts, total_s: float) -> np.ndarray:
    n = int(total_s * SR)
    t = np.arange(n) / SR
    x = 2e-4 * np.sin(2 * np.pi * 1234.5 * t + 0.7)                  # a noise floor that is a pure function of the sample index
    for a, b, amp in bursts:
        x[int(a * SR): int(b * SR)] += _burst(int(b * SR) - int(a * SR), amp)
    return x.astype(np.float32)


def prepared_audio(archive_files=None) -> audioprep.PreparedAudio:
    mic = synth_track([(2, 6, 0.20), (8, 12, 0.20), (30, 36, 0.05), (50, 54, 0.20)], 63.0)
    remote = synth_track([(1, 5, 0.05), (14, 22, 0.05), (40, 47, 0.20), (55, 58, 0.05)], 63.0)
    return audioprep.PreparedAudio({"mic": mic, "remote": remote}, SR, 63.0, dict(archive_files or {}))


def golden_config(support_dir: Path, **kw) -> Config:
    # asr_strategy single: the files were frozen from code that decoded each chunk once; the built-in default is dual since the bench gate
    base = dict(support_dir=support_dir, asr_vad="energy", mic_aec="0", self_name="Me", asr_strategy="single")
    base.update(kw)
    return Config(**base)


# ---------------------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------------------
def run_transcribe_tracks(support_dir: Path, *, supports_lid: bool = True, **cfg_kw) -> dict:
    engine = GoldenEngine(supports_lid=supports_lid)
    progress: list = []
    cfg = golden_config(support_dir, **cfg_kw)
    with fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
        out = asr.transcribe_tracks(prepared_audio(), cfg, parse_vocab_text(VOCAB_TEXT), progress.append)
    return {"transcript": out, "progress": progress, "engine_calls": engine.calls, "engine_lid_calls": engine.lid_calls,
            "engine_loaded": engine.loaded, "engine_released": engine.released}


def build_transcribe_tracks(support_dir: Path) -> dict:
    return {"lid_auto": run_transcribe_tracks(support_dir, asr_language="auto"),
            "no_lid_auto": run_transcribe_tracks(support_dir, supports_lid=False, asr_language="auto"),
            "forced_ko": run_transcribe_tracks(support_dir, asr_language="ko")}


def build_footer_text() -> str:
    when = "2026-10-07T15:30:00+09:00"
    parts = [
        note.build_footer("2.1.278", ["claude-opus-5"], "opus", "high", "mlx-community/whisper-large-v3-mlx", when=when),
        note.build_footer("2.1.278", ["claude-opus-5", "claude-sonnet-5"], "opus", "high", "", "extra usage observed", when=when),
        note.build_footer("", [], "opus", "max", "mlx-community/whisper-tiny-mlx", when=when, transcript_kind="raw",
                          cleanup_note="cleanup not applied: usage limit"),
        note.build_footer("2.1.278", ["claude-opus-5"], "opus", "high", "/models/qwen3_asr", "", when=when, transcript_kind="cleaned"),
    ]
    return "\n---\n".join(parts) + "\n"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _archive_entry(result, src: Path, cfg: Config) -> dict:
    final = result.final_dir
    return {"ok": bool(result.ok), "stage": result.stage, "final_dir": final.relative_to(cfg.archive_dir).as_posix(),
            "files": sorted(p.name for p in final.iterdir()),
            "staging_after": sorted(p.name for p in Path(src).iterdir()),
            "transcript_json_sha256": sha256_file(final / "transcript.json"),
            "transcript_md_sha256": sha256_file(final / "transcript.md")}


def build_archive_listing() -> dict:
    """process_session end to end into a temp archive. Two runs: FakeASR (the existing test double) and the real
    asr.transcribe_tracks + transcript.render_markdown with the scripted engine."""
    from notes_cli_support import FakeASR, StubNote, fake_m4a, make_cfg, make_session, ready_ok

    out: dict = {}
    with tempfile.TemporaryDirectory(prefix="mcap-golden-") as tmp, pinned_tz():
        root = Path(tmp)
        env = {"MCAP_SECURITY_BIN": str(root / "no-security"), "MCAP_LOG_DIR": str(root / "logs")}   # nothing may reach the real Keychain
        with mock.patch.dict(os.environ, env):
            # --- FakeASR (design: process_session archive file list and transcript.json/md sha256 with FakeASR)
            run1 = root / "fake_asr"
            run1.mkdir()
            cfg = make_cfg(run1)
            src = make_session(cfg)
            deps = FakeASR().deps(check_ready=ready_ok, generate_note=StubNote())
            result = pipeline.process_session(src, cfg, deps=deps)
            out["fake_asr"] = _archive_entry(result, src, cfg)

            # --- the real ASR stage with the scripted engine and the real transcript.md renderer
            run2 = root / "real_asr"
            run2.mkdir()
            cfg = make_cfg(run2, asr_vad="energy", mic_aec="0", asr_strategy="single")      # single: see golden_config
            cfg.vocab_path.write_text(VOCAB_TEXT, encoding="utf-8")
            src = make_session(cfg)

            def prepare_audio(session_dir, session, force=False):
                files = {}
                for name in ("audio", "mic", "remote"):
                    fake_m4a(Path(session_dir) / f"{name}.m4a")
                    files[name] = Path(session_dir) / f"{name}.m4a"
                return prepared_audio(files)

            engine = GoldenEngine()
            deps = pipeline.Deps(prepare_audio=prepare_audio, transcribe_tracks=asr.transcribe_tracks,
                                 render_markdown=transcript.render_markdown, check_ready=ready_ok, generate_note=StubNote())
            with fake_clock(), mock.patch.object(asr, "get_engine", return_value=engine):
                result = pipeline.process_session(src, cfg, deps=deps)
            out["real_asr"] = _archive_entry(result, src, cfg)
            out["real_asr"]["engine_calls"] = len(engine.calls)
    return out


def dump_json(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=1) + "\n"


def generate() -> dict[str, str]:
    """File name -> exact text of every golden file, built from the CURRENT code."""
    with tempfile.TemporaryDirectory(prefix="mcap-golden-support-") as tmp, pinned_tz():
        tracks = build_transcribe_tracks(Path(tmp))
        markdown = transcript.render_markdown(tracks["lid_auto"]["transcript"], dict(META))
        footer = build_footer_text()
    return {"default_transcribe_tracks.json": dump_json(tracks), "default_transcript.md": markdown, "default_footer.txt": footer,
            "default_archive_listing.json": dump_json(build_archive_listing())}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write the golden files next to this script (refuses to overwrite)")
    mode.add_argument("--check", action="store_true", help="compare the current code's output with the golden files")
    ap.add_argument("--force", action="store_true", help="with --write: replace existing golden files (only on purpose)")
    args = ap.parse_args(argv)
    files = generate()
    if args.write:
        existing = [n for n in files if (HERE / n).exists()]
        if existing and not args.force:
            print("refusing to overwrite frozen golden files (use --force on purpose): " + ", ".join(existing), file=sys.stderr)
            return 2
        for name, text in files.items():
            (HERE / name).write_text(text, encoding="utf-8")
            print(f"wrote {name} ({len(text.encode('utf-8'))} bytes, sha256 {hashlib.sha256(text.encode('utf-8')).hexdigest()[:12]})")
        return 0
    bad = [n for n, text in files.items() if not (HERE / n).exists() or (HERE / n).read_text(encoding="utf-8") != text]
    for name in files:
        print(("DIFFERS " if name in bad else "same    ") + name)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
