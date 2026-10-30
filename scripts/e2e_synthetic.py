#!/usr/bin/env python3
"""e2e_synthetic.py - synthetic end-to-end test of the Python pipeline (`python -m mcap process`), hermetic and device-free.

    PY=<venv python with numpy + mlx-whisper>  HF_HOME=<cache that holds mlx-community/whisper-tiny-mlx>
    $PY scripts/e2e_synthetic.py [--keep] [--asr-model REPO] [--scenario NAME ...]

What it does (about 3 minutes with the tiny model; the real claude is NEVER called, a fake `claude` script is):
  * builds fake session directories (SPEC 4.1) in a temp SUPPORT_DIR from benchmarks/tts clips: remote.wav = meeting_like_184s
    (+ silence to 200 s) as 48 kHz mono int16 (afconvert), mic.wav = two of the user's own clips (alone and in double talk) plus a
    delayed / reverberant / -20 dB copy of the remote track (speaker leakage), start_offset_sec 0.03 / 0.05;
  * runs `python -m mcap process` the way PipelineLauncher does (scrubbed env, HOME = a temp dir, MCAP_CONFIG / MCAP_LOG_DIR /
    TMPDIR in the temp world, ARCHIVE_DIR with a space in its name), polling state.json for the stage progression;
  * asserts the result (state, transcript.json / .md, AEC stats applied, cleaned transcript, note + draft + verification footer,
    published folder, m4a files, WAVs removed, tombstone only in staging, what the fake claude saw) and then runs the same session
    through `reprocess --last --from note`, `reprocess --pending`, `doctor`, a kill -9 in the middle of the ASR and the resume.
Scenarios: main, followups (needs main), kill9, aec-off (informational), note-failed, archive-unavailable, no-leak (headphones),
discard (silence) and api (SPEC 17: CLAUDE_AUTH=api against a FAKE `security` Keychain shim that serves a CANARY key and the fake
claude: both modes end to end, per-call cost in usage.jsonl and `mcap usage`/`doctor`/`api-key`, credit exhaustion -> published
transcript -> `reprocess --pending` finishes it, the daily budget, and a scan of the whole temp world for the canary).
SPEC 18, the lane gates end to end with the real ASR: `local-only` (session.json local_only=true, CLAUDE_AUTH=api with a
key in the fake Keychain: ZERO claude processes, ZERO Keychain calls, the local archive, state `lanes`, the transcript policy block and the
Privacy line, the strict socket tripwire around the real ASR, a reprocess that leaves the folder alone), `org-denied` (an injected company
policy denies the calendar and Drive lanes: the note is made, no calendar call, the folder goes to the local archive; in-process because
a policy file must be root-owned) and `policy-locked` (an invalid policy file named by MCAP_POLICY_PATH closes every lane).
Nothing outside the temp directory is touched (HOME is a temp dir, no network, no real claude, no real Keychain, no Drive, no TCC).
Exit code 0 only if every assertion passed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pipeline"))
sys.path.insert(0, str(REPO / "pipeline" / "tests"))

TTS = REPO / "benchmarks" / "tts"
SR = 48000
TOTAL = 200.0
TITLE = "Alex Morgan Weekly"
FOLDER = "2026-10-07_1400_Alex-Morgan-Weekly"
SID = "2026-10-07_1400_meet"
TINY = "mlx-community/whisper-tiny-mlx"
MIC_CLIPS = (("ko_yuna_terms", 111.5), ("en_samantha_terms", 179.0))      # the user's own speech inside the 200 s session

results: list[bool] = []


def check(ok, name, detail="") -> bool:
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"   [{detail}]" if detail else ""), flush=True)
    return bool(ok)


def info(msg) -> None:
    print("INFO " + msg, flush=True)


def jload(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------------- synthetic session
def load48(name: str) -> np.ndarray:
    with tempfile.TemporaryDirectory() as t:
        out = Path(t) / "x.wav"
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1", str(TTS / f"{name}.wav"), str(out)], check=True)
        with wave.open(str(out)) as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (SR, 1, 2)
            return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def write16(path: Path, x: np.ndarray) -> None:
    x = np.clip(x, -1, 1)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767.0).astype("<i2").tobytes())


def build_session(sessions_dir: Path, session_id: str, title_hint: str, leak_gain: float = 0.1, silent: bool = False, seed: int = 11) -> Path:
    sdir = sessions_dir / session_id
    sdir.mkdir(parents=True)
    n = int(TOTAL * SR)
    remote = np.zeros(n, np.float32)
    r = load48("meeting_like_184s")
    remote[:len(r)] = r[:n]
    rng = np.random.default_rng(seed)
    rir = np.zeros(int(0.25 * SR), np.float32)                         # speaker -> room -> mic: 45 ms direct path + reverberant tail
    d = int(0.045 * SR)
    rir[d] = 1.0
    tail = rng.standard_normal(len(rir)).astype(np.float32) * np.exp(-np.arange(len(rir)) / (0.08 * SR))
    tail[: d + 1] = 0
    rir += tail * np.float32(np.sqrt(0.3 / float(np.sum(tail ** 2))))
    nfft = 1 << int(np.ceil(np.log2(n + len(rir))))
    leak = np.fft.irfft(np.fft.rfft(remote, nfft) * np.fft.rfft(rir, nfft), nfft)[:n].astype(np.float32) * leak_gain
    own = np.zeros(n, np.float32)
    for name, t0 in MIC_CLIPS:
        c = load48(name)
        a = int(t0 * SR)
        b = min(n, a + len(c))
        own[a:b] = c[: b - a]
    if silent:
        remote[:] = 0
        own[:] = 0
        leak[:] = 0
    mic = own + leak + 3e-4 * rng.standard_normal(n).astype(np.float32)
    write16(sdir / "remote.wav", remote[int(0.03 * SR):])               # a track file starts at its start_offset_sec
    write16(sdir / "mic.wav", mic[int(0.05 * SR):])
    hh, mm = session_id.split("_")[1][:2], int(session_id.split("_")[1][2:])
    session = {
        "schema": 1, "session_id": session_id, "platform": "meet", "platform_label": "Google Meet", "title_hint": title_hint,
        "meeting_url": "https://meet.google.com/abc-defg-hij", "app_bundle_id": "com.google.Chrome",
        "start_time": f"2026-10-07T{hh}:{mm:02d}:12+09:00", "end_time": f"2026-10-07T{hh}:{mm + 3:02d}:32+09:00", "end_reason": "meeting-ended",
        "tracks": {
            "remote": {"file": "remote.wav", "sample_rate": SR, "channels": 1, "start_offset_sec": 0.03, "source": "global-tap", "device": "MacBook Pro Speakers"},
            "mic": {"file": "mic.wav", "sample_rate": SR, "channels": 1, "start_offset_sec": 0.05, "source": "mic", "device": "MacBook Pro Microphone"}},
        "app_version": "0.1.0"}
    (sdir / "session.json").write_text(json.dumps(session, indent=2), encoding="utf-8")
    return sdir


# ---------------------------------------------------------------------------------- fake claude (note text built from the transcript it receives)
_DYN = r'''
def dyn_note(stdin, plan):
    import re
    tr = block(stdin, "transcript")
    blocks, cur = [], None
    for line in tr.splitlines():
        m = re.match(r"^\[(\d\d:\d\d:\d\d)\] (.+)$", line)
        if m: cur = [m.group(1), m.group(2), ""]; blocks.append(cur)
        elif cur is not None and line.strip(): cur[2] = (cur[2] + " " + line.strip()).strip()
    remote = [b for b in blocks if b[1] == "Remote"] or blocks
    mic = [b for b in blocks if b[1] != "Remote"]
    nums = []
    for m in re.finditer(r"\d[\d,.]*\d|\d", " ".join(b[2] for b in blocks)):
        t = m.group(0).rstrip(",.")
        if t not in nums: nums.append(t)
    first = remote[0] if remote else ["00:00:00", "Remote", "(nothing)"]
    last_mic = mic[-1] if mic else ["00:00:00", "Me", "(nothing)"]
    lines = ["# Weekly Sync (fake claude)", "", "Date: 1999-01-01", "Time: wrong", "Platform: Model Platform", "Participants: Me, Remote", "",
             "## Executive Summary", "- Remote said: " + first[2][:160] + " [" + first[0] + "]",
             "- the user said: " + last_mic[2][:160] + " [" + last_mic[0] + "]",
             "", "## Key Discussion", "- The fake model counted the speaker blocks of the transcript.", "",
             "## Decisions", "- Decision: the team will sign the Contoso agreement (invented by the fake model).", "",
             "## Action Items", "| Owner | Action | Due |", "|---|---|---|", "| Not stated | Not stated | Not stated |", "",
             "## Open Questions", "- Not stated.", "", "## Follow-up", "- Not stated.", "", "## Important Details",
             "- Numbers heard: " + (", ".join(nums[:6]) if nums else "none"), ""]
    return "\n".join(lines)

def run_note():'''


def make_fake_claude(directory: Path, replacements: dict | None = None, delay: float = 0.7):
    import notes_cli_support as h
    fake = h.FakeClaude(directory)
    script = h._FAKE_SCRIPT
    note_line = 'respond(plan, plan.get("note", SCEN.get("note", "")))'
    assert "def run_note():" in script and note_line in script, "tests/notes_cli_support.py changed: update make_fake_claude"
    script = script.replace("def run_note():", _DYN, 1).replace(note_line, "respond(plan, dyn_note(stdin, plan))", 1)   # SCEN["delay"] is handled by the base fake
    (directory / "fake_claude.py").write_text(script, encoding="utf-8")
    scen = {"delay": delay, "runs": [{"mode": "success"}], "note_offset": 0, "offsets": {"cleanup": 0, "verify": 0},
            "cleanup": {"replacements": replacements or {}}, "verify": {"remove": ["Contoso"]}}
    (directory / "scenario.json").write_text(json.dumps(scen), encoding="utf-8")
    return fake


def set_scenario(fake_dir: Path, **updates) -> None:
    p = fake_dir / "scenario.json"
    s = json.loads(p.read_text())
    s.update(updates)
    p.write_text(json.dumps(s))


def fake_calls(fake_dir: Path) -> list[dict]:
    p = fake_dir / "calls.jsonl"
    return [json.loads(line) for line in p.read_text().splitlines() if line.strip()] if p.exists() else []


# ---------------------------------------------------------------------------------- a temp world
class World:
    def __init__(self, root: Path, name: str, asr_model: str, replacements: dict | None = None, delay: float = 0.7, **cfg):
        self.root = root / name
        self.home = self.root / "home"
        self.support = self.root / "support"
        self.logs = self.root / "logs"
        self.tmp = self.root / "tmp"
        self.archive_parent = self.root / "archive dir (test)"
        self.archive = self.archive_parent / "Meetings"
        for d in (self.home, self.support / "sessions", self.logs, self.tmp, self.archive_parent):
            d.mkdir(parents=True)
        shutil.copy(REPO / "config" / "vocabulary.txt", self.support / "vocabulary.txt")
        self.fake_dir = self.root / "fake"
        make_fake_claude(self.fake_dir, replacements, delay)
        values = {"SUPPORT_DIR": self.support, "ARCHIVE_DIR": self.archive, "PROJECT_DIR": REPO, "PYTHON_BIN": sys.executable,
                  "CLAUDE_BIN": self.fake_dir / "claude", "SELF_NAME": "Me", "ASR_MODEL": asr_model, "ASR_LANGUAGE": "auto",
                  "ASR_VAD": "auto", "MIC_AEC": "auto", "TRANSCRIPT_CLEANUP": 1, "NOTE_VERIFY": 1, "CALENDAR_LOOKUP": 0,
                  "NOTE_STOP_ON_OVERAGE": 0, "AUDIO_RETENTION_DAYS": 0,
                  "CLAUDE_AUTH": "subscription"}       # the built-in default is api (a Keychain): only the scenarios that fake a Keychain ask for it
        values.update(cfg)
        self.config_path = self.root / "config.env"
        self.extra_env: dict = {}                      # e.g. MCAP_SECURITY_BIN (the fake Keychain of the api scenario)
        self.write_config(values)

    def write_config(self, values: dict) -> None:
        self.values = values
        self.config_path.write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")

    def env(self) -> dict:
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": os.environ.get("USER", "user"), "LANG": "en_US.UTF-8",
               "PYTHONUNBUFFERED": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "MCAP_CONFIG": str(self.config_path), "MCAP_LOG_DIR": str(self.logs),
               "TMPDIR": str(self.tmp) + "/", "HF_HUB_OFFLINE": "1"}
        for key in ("HF_HOME", "MCAP_SILERO_MODEL"):
            if os.environ.get(key):
                env[key] = os.environ[key]
        env.update(self.extra_env)
        return env

    def popen(self, *args, **kw) -> subprocess.Popen:
        return subprocess.Popen([sys.executable, "-m", "mcap", *args], cwd=REPO / "pipeline", env=self.env(), text=True,
                                stdout=kw.pop("stdout", subprocess.PIPE), stderr=kw.pop("stderr", subprocess.PIPE), **kw)

    def mcap(self, *args, timeout=900) -> tuple[int, str, str]:
        p = self.popen(*args)
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err

    def session_dir(self, sid=SID) -> Path:
        return self.support / "sessions" / sid

    def final(self, folder=FOLDER) -> Path:
        return self.archive / "2026-10" / folder

    def local_state(self, folder=FOLDER) -> Path:
        return self.support / "local-meetings" / "2026-10" / folder / "state.json"

    def add_session(self, sid=SID, hint="Meet – " + TITLE, **kw) -> Path:
        return build_session(self.support / "sessions", sid, hint, **kw)


class Poller(threading.Thread):
    """Samples state.json every 0.25 s and records every distinct (stage, detail, ...)."""
    def __init__(self, path: Path):
        super().__init__(daemon=True)
        self.path, self.rows, self.stop_flag, self.last = path, [], False, None
        self.t0 = time.time()

    def run(self):
        while not self.stop_flag:
            try:
                d = json.loads(self.path.read_text(encoding="utf-8"))
                key = (d.get("stage"), d.get("stage_detail"), json.dumps(d.get("done"), sort_keys=True), d.get("title"))
                if key != self.last:
                    self.last = key
                    self.rows.append({"t": round(time.time() - self.t0, 2), "stage": d.get("stage"), "detail": d.get("stage_detail")})
            except (OSError, ValueError):
                pass
            time.sleep(0.25)

    def finish(self):
        time.sleep(0.6)
        self.stop_flag = True
        self.join(2)


def process(world: World, sid=SID, *extra) -> tuple[int, str, str, list]:
    poller = Poller(world.session_dir(sid) / "state.json")
    poller.start()
    code, out, err = world.mcap("-v", "process", str(world.session_dir(sid)), *extra)
    poller.finish()
    return code, out, err, poller.rows


# ---------------------------------------------------------------------------------- assertions on a finished world
def afinfo(path: Path):
    out = subprocess.run(["/usr/bin/afinfo", str(path)], capture_output=True, text=True).stdout
    dur = re.search(r"estimated duration: ([\d.]+) sec", out)
    ftype = re.search(r"File type ID:\s+(\w+)", out)
    return (float(dur.group(1)) if dur else None), (ftype.group(1) if ftype else None), out


def assert_finished(w: World, out: str, prog: list, *, sid=SID, title=TITLE, folder=FOLDER, aec="applied", verify="applied", resume=False,
                    expect_cleanup_changes=None, api=False) -> None:
    from mcap import note as N, transcript as T
    final, staging = w.final(folder), w.session_dir(sid)
    stages = [p["stage"] for p in prog]
    order = ["queued", "audio", "transcribing", "noting", "publishing", "done"]
    idx = [order.index(s) for s in stages if s in order]
    check(prog and "failed" not in stages, "state progression never reaches failed", " > ".join(dict.fromkeys(stages)))
    check(resume or idx == sorted(idx), "state progression is monotonic" + (" (skipped: resumed run)" if resume else ""))
    check({"audio", "transcribing", "noting", "done"} <= set(stages), "progression covers audio, transcribing, noting, done", str(sorted(set(stages))))
    check(any((p["detail"] or "").startswith("transcribing remote") for p in prog), 'stage_detail carries "transcribing remote n/m"')
    if aec == "applied":
        check(any((p["detail"] or "").startswith("echo cancellation") for p in prog), "stage_detail shows the echo cancellation step")
    names = sorted(x.name for x in staging.iterdir())
    check(names == ["state.json"], "staging holds ONLY the tombstone state.json", str(names))
    st = jload(staging / "state.json")
    check(st["schema"] == 1 and st["stage"] == "done" and st["error"] is None, "tombstone: schema 1, stage done, no error", f"{st['stage']} {st['error']}")
    check(st["title"] == title and Path(st["final_dir"]) == final and final.is_dir(), "tombstone: title and final_dir point at the archive folder")
    check(st["discarded"] is False and all(st["done"].get(k) for k in ("audio", "asr", "note", "publish")), "tombstone: done flags", json.dumps(st["done"]))
    if verify == "applied":
        check(st["done"].get("verify") is True and not st.get("warning"), "tombstone: verify done, no warning", str(st.get("warning")))
    else:
        check(st["done"].get("verify") is False and "verification not applied" in (st.get("warning") or ""), "tombstone: verify rejected -> warning", str(st.get("warning")))
    check(st["done"].get("cleanup") is True, "tombstone: cleanup done")
    lines = out.strip().splitlines()
    check(lines and lines[-1] == f"DONE: {final}", 'stdout ends with "DONE: <final dir>"')

    got = sorted(p.name for p in final.iterdir())
    expect = {"audio.m4a", "mic.m4a", "remote.m4a", "session.json", "transcript.json", "transcript.md", "transcript.cleaned.json",
              "transcript.cleaned.md", "meeting-note.md"} | ({"meeting-note.draft.md"} if verify == "applied" else set())
    check(set(got) == expect, "archive folder has exactly the expected files", ", ".join(got))
    check(not any(n.endswith((".wav", ".part", ".tmp", ".partial")) or n.startswith((".", "_work")) or n == "state.json" for n in got), "no WAVs / work files / hidden dirs / state.json in the archive folder")
    stray = [p for p in w.root.rglob("*") if p.is_file() and (p.suffix in (".wav", ".part", ".partial") or ".prep-" in str(p)) and "/tmp/" not in str(p)]
    check(not stray, "no .wav / .prep-* / .part anywhere in the world", str(stray[:3]))
    check([p.name for p in w.archive.iterdir()] == ["2026-10"], "ARCHIVE_DIR/YYYY-MM layout (the archive path has a space)")
    for nm in ("audio.m4a", "mic.m4a", "remote.m4a"):
        d, ftype, raw = afinfo(final / nm)
        check(d is not None and abs(d - 200.0) < 1.0 and ftype == "m4af" and "aac" in raw.lower(), f"{nm}: AAC in m4af, {d} s (session 200 s, offsets applied)")
    sj = jload(final / "session.json")
    check(sj["session_id"] == sid and sj["end_time"] and sj["tracks"]["mic"]["start_offset_sec"] == 0.05, "session.json copied intact")

    tj, tmd = jload(final / "transcript.json"), (final / "transcript.md").read_text(encoding="utf-8")
    check(T.validate_transcript(tj) == [], "transcript.json valid (SPEC 4.4)", "; ".join(T.validate_transcript(tj))[:160])
    starts, ends = [s["start"] for s in tj["segments"]], [s["end"] for s in tj["segments"]]
    check(starts == sorted(starts) and min(starts) >= 0 and max(ends) <= TOTAL + 0.5, "segments time-ordered inside the 200 s session", f"{min(starts):.1f}..{max(ends):.1f}")
    check(tj["speech_seconds"]["remote"] > 100 and tj["missing_tracks"] == [], "speech/missing bookkeeping", json.dumps(tj["speech_seconds"]))
    a = tj.get("aec")
    if aec == "off":
        check(a == {"applied": False, "mode": "off", "reason": "MIC_AEC=0"}, "transcript.json aec = disabled marker", json.dumps(a))
    elif aec == "not-applied":
        check(isinstance(a, dict) and a.get("applied") is False and a.get("mode") == "auto" and a.get("reason"), "transcript.json aec present, NOT applied (no leakage), with a reason", json.dumps(a))
    else:
        check(isinstance(a, dict) and a.get("applied") is True and a.get("mode") == "auto", "transcript.json aec present and APPLIED", json.dumps({k: a.get(k) for k in ("applied", "mode", "coherence", "delay_ms", "erle_db")}) if a else "None")
        check(a and a["coherence"] >= 0.3 and abs(a["delay_ms"] - 45.0) <= 3.0 and (a["erle_db"] or 0) >= 15, "AEC stats plausible: coherence >= 0.3, delay 45 +-3 ms, ERLE >= 15 dB", f"{a['coherence']} {a['delay_ms']} {a['erle_db']}")
    mic = [s for s in tj["segments"] if s["track"] == "mic"]
    rem = [s for s in tj["segments"] if s["track"] == "remote"]
    check(all(s["speaker"] == "Me" for s in mic) and all(s["speaker"] == "Remote" for s in rem), "speaker labels: mic = the user, system audio = Remote")
    windows = [(t0, t0 + {"ko_yuna_terms": 18.1, "en_samantha_terms": 20.1}[name]) for name, t0 in MIC_CLIPS]
    outside = [s for s in mic if not any(a0 - 1.5 <= (s["start"] + s["end"]) / 2 <= b0 + 1.5 for a0, b0 in windows)]
    if aec == "off":
        info(f"(AEC off) mic segments outside the user's own clips: {len(outside)}; echo_suppressed={tj['echo_suppressed']}")
    else:
        check(not outside, "NO echo: every mic segment lies inside one of the user's own clips", "; ".join(f"{s['start']:.0f}-{s['end']:.0f}s {s['text'][:30]!r}" for s in outside[:4]))
        for a0, b0 in windows:
            cov = sum(max(0, min(s["end"], b0) - max(s["start"], a0)) for s in mic) / (b0 - a0)
            check(cov >= 0.7, f"the user's own clip {a0:.0f}-{b0:.0f}s is in the transcript (double talk included): {cov:.0%}")
    check(re.search(r"^# Transcript\n\nMeeting: " + re.escape(title) + r"\nDate: 2026-10-07\nPlatform: Google Meet\nStart: 14:00:12 \(KST\)   Duration: 00:03:20\nASR: \S+  \(mic: \w+, remote: \w+\)\n", tmd),
          "transcript.md header lines as SPEC 4.4 (the title replaced after publish)", tmd.splitlines()[2])
    blocks = re.findall(r"^\[(\d\d:\d\d:\d\d)\] (Me|Remote)$", tmd, re.M)
    check(len(blocks) >= 6 and [b[0] for b in blocks] == sorted(b[0] for b in blocks), "transcript.md [HH:MM:SS] blocks in time order", f"{len(blocks)} blocks")
    rendered = T.render_markdown(tj, {"title": title, "date": "2026-10-07", "platform_label": "Google Meet", "start_time": sj["start_time"], "duration_sec": 200.0, "asr_model": tj["asr_model"]})
    check(rendered.strip() == tmd.strip(), "transcript.md == render_markdown(transcript.json)")

    cj, cmd = jload(final / "transcript.cleaned.json"), (final / "transcript.cleaned.md").read_text(encoding="utf-8")
    check(len(cj["segments"]) == len(tj["segments"]) and all(abs(x["start"] - y["start"]) < 1e-6 and x["track"] == y["track"] for x, y in zip(cj["segments"], tj["segments"])), "cleaned.json: same segments / timing / tracks as raw")
    digits = lambda t: re.findall(r"\d+", t)
    check(all(digits(x["text"]) == digits(y["text"]) for x, y in zip(cj["segments"], tj["segments"])), "cleaned.json: every segment keeps its digits (numbers verified by code)")
    changed = sum(1 for x, y in zip(cj["segments"], tj["segments"]) if x["text"] != y["text"])
    if expect_cleanup_changes is not None:
        check(changed >= expect_cleanup_changes, f"cleanup changed >= {expect_cleanup_changes} segments (terms fixed)", f"changed={changed}, rejected={cj['stats']['rejected']}")
    check(cj.get("source_sha256") == hashlib.sha256((final / "transcript.json").read_bytes()).hexdigest(), "cleaned.json is bound to the SHA-256 of the untouched raw transcript.json")
    check(cmd != tmd and cmd.startswith("# Transcript"), "transcript.cleaned.md next to the raw one")

    nt = (final / "meeting-note.md").read_text(encoding="utf-8")
    check(not N.missing_headings(nt), "meeting-note.md has all 7 headings")
    check(nt.startswith(f"# {title}\n") and "Date: 2026-10-07" in nt and "Platform: Google Meet" in nt and "Time: 14:00-14:03 KST" in nt and "1999-01-01" not in nt, "note header: H1 = title, Date/Time/Platform from session facts (model values replaced)")
    check("<!-- generated by Claude Code 2.1.278 | model: claude-opus-5 (requested: opus) | effort: high" in nt and "transcript: cleaned" in nt, "note footer: version, resolved model, effort, transcript kind")
    if verify == "applied":
        check("<!-- Verification:" in nt and "Contoso" not in nt, "verification footer present, the invented decision removed")
        draft = (final / "meeting-note.draft.md").read_text(encoding="utf-8")
        check("Contoso" in draft and "<!-- Verification" not in draft, "meeting-note.draft.md keeps the unverified draft")
    else:
        check("Verification: not applied" in nt, "verification footer says not applied (draft kept as the note)")

    calls = fake_calls(w.fake_dir)
    kinds = [c["kind"] for c in calls]
    if api:
        check(kinds.count("note") >= 1 and kinds.count("verify") >= 1 and kinds.count("cleanup") >= 1 and kinds.count("auth") == 0, "claude calls: cleanup + note + verify and NO `claude auth status` (api mode)", str({k: kinds.count(k) for k in set(kinds)}))
    else:
        check(kinds.count("note") >= 1 and kinds.count("verify") >= 1 and kinds.count("cleanup") >= 1 and kinds.count("auth") >= 1, "claude calls: auth + cleanup + note + verify", str({k: kinds.count(k) for k in set(kinds)}))
    bad_env = []
    want_env = {"HOME", "USER", "PATH", "LANG"} | ({"ANTHROPIC_API_KEY"} if api else set())
    for c in calls:
        keys = {k for k in c["env"] if not (k.startswith(("LC_", "__CF")) or k in ("PWD", "SHLVL", "_", "OLDPWD"))}
        if keys != want_env:
            bad_env.append(sorted(keys))
    check(not bad_env, "every claude call got ONLY " + "/".join(sorted(want_env)), str(bad_env[:1]))
    nc = [c for c in calls if c["kind"] != "auth"]
    check(all(not any(f in " ".join(c["argv"]) for f in ("--bare", "--max-budget-usd", "--settings", "fable")) and "--safe-mode" in c["argv"]
              and "--no-session-persistence" in c["argv"] and c["argv"][c["argv"].index("--output-format") + 1] == "stream-json" for c in nc), "claude argv follows SPEC 13.3")
    check(all(Path(c["cwd"]).resolve() == (w.support / "claude-cwd").resolve() for c in nc), "claude cwd = SUPPORT_DIR/claude-cwd")
    nstdin = [c for c in calls if c["kind"] == "note"][-1]["stdin"]
    check("<transcript>" in nstdin and "echo" in nstdin.lower() and len(re.findall(r"^\[\d\d:\d\d:\d\d\] (?:Me|Remote)$", nstdin, re.M)) >= 6, "note prompt carries the transcript blocks and the echo rule")


# ---------------------------------------------------------------------------------- scenarios
def scenario_main(root, a) -> World:
    print("\n=== scenario main: process (AEC auto, cleanup, note, verify, publish)")
    w = World(root, "main", a.asr_model, {"FVA": "FDA", "Kontoso Labs": "Contoso-Labs", "$2.00": "$2.10"})
    w.add_session()
    t = time.time()
    code, out, err, prog = process(w)
    info(f"process rc={code} in {time.time() - t:.0f}s")
    check(code == 0, "mcap process exits 0", out.strip().splitlines()[-1][:120] if out.strip() else err[-300:])
    if code == 0:
        assert_finished(w, out, prog, expect_cleanup_changes=(1 if "tiny" in a.asr_model else None))  # the fake cleanup fixes tiny-model misspellings (FVA, Kontoso Labs); large-v3 already writes them right
        cleaned = (w.final() / "transcript.cleaned.md").read_text(encoding="utf-8")
        check("$2.10" not in cleaned, "a cleanup edit that changes a number ($2.00 -> $2.10) was rejected by the code")
    return w


def scenario_followups(w: World) -> None:
    print("\n=== scenario followups: reprocess --last --from note, reprocess --pending, doctor, transcribe-file (on the main session)")
    final = w.final()
    sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
    before = {n: sha(final / n) for n in ("transcript.json", "transcript.md", "transcript.cleaned.json")}
    code, out, err = w.mcap("-v", "reprocess", "--last", "--from", "note")
    check(code == 0 and out.strip().splitlines()[-1] == f"DONE: {final}", "reprocess --last --from note: DONE in place", out.strip()[-100:])
    check(all(sha(final / n) == v for n, v in before.items()), "raw transcript, transcript.md and the cleaned transcript are untouched by a note reprocess")
    check((final / "meeting-note.prev.md").is_file() and (final / "meeting-note.md").is_file(), "previous note kept as meeting-note.prev.md, new note written")
    check(len(fake_calls(w.fake_dir)) and [c["kind"] for c in fake_calls(w.fake_dir)].count("note") == 2, "exactly one more note call (cleanup skipped: a valid cleaned transcript exists)")
    st = jload(w.session_dir() / "state.json")
    check(st["stage"] == "done" and st["title"] == TITLE and Path(st["final_dir"]) == final, "tombstone still done with title/final_dir")
    code, out, err = w.mcap("reprocess", "--pending")
    check(code == 0 and "nothing pending" in out, "reprocess --pending with nothing failed: nothing pending", out.strip()[:100])
    code, out, err = w.mcap("doctor", "--no-warmup")
    check(code == 0 and "0 FAIL" in out, "doctor: no FAIL", out.strip().splitlines()[-1])
    code, out, err = w.mcap("transcribe-file", str(TTS / "en_samantha_terms.wav"), "--model", w.values["ASR_MODEL"], "--language", "en", "--out", str(w.root / "tf.md"))
    check(code == 0 and (w.root / "tf.md").read_text().startswith("# Transcript"), "transcribe-file writes a transcript")


def scenario_kill9(root, a) -> None:
    print("\n=== scenario kill9: kill -9 in the middle of the ASR, then resume")
    w = World(root, "kill9", a.asr_model, {"FVA": "FDA", "Kontoso Labs": "Contoso-Labs", "$2.00": "$2.10"})
    sd = w.add_session()
    p = w.popen("-v", "process", str(sd))
    killed = ""
    deadline = time.time() + 120
    while time.time() < deadline and p.poll() is None:
        try:
            detail = jload(sd / "state.json").get("stage_detail") or ""
        except (OSError, ValueError):
            detail = ""
        if re.match(r"transcribing remote [2-6]/\d+", detail):
            killed = detail
            p.send_signal(signal.SIGKILL)
            break
        time.sleep(0.1)
    p.communicate()
    check(bool(killed) and p.returncode == -signal.SIGKILL, "pipeline killed with SIGKILL while transcribing", killed)
    time.sleep(0.5)
    st = jload(sd / "state.json")
    names = sorted(x.name for x in sd.iterdir())
    check(st["stage"] == "transcribing" and st["error"] is None, "state.json says transcribing (not failed): the app will re-enqueue it", f"{st['stage']} {st['stage_detail']}")
    check({"mic.wav", "remote.wav", "session.json", "audio.m4a", "mic.m4a", "remote.m4a"} <= set(names) and "transcript.json" not in names, "audio and WAVs intact, no half-written transcript", ", ".join(names))
    check(not list(w.archive.rglob("*")) if w.archive.exists() else True, "nothing was published")
    code, out, err, prog = process(w)
    check(code == 0, "resume after kill -9: process exits 0", out.strip()[-100:])
    check("m4a" not in "\n".join(l for l in err.splitlines() if "created" in l), "the m4a files from the first run were reused (not re-encoded)")
    if code == 0:
        assert_finished(w, out, prog, resume=True, expect_cleanup_changes=(1 if "tiny" in a.asr_model else None))  # the fake cleanup fixes tiny-model misspellings (FVA, Kontoso Labs); large-v3 already writes them right


def scenario_aec_off(root, a) -> None:
    print("\n=== scenario aec-off: MIC_AEC=0 on the same audio (informational: shows what the canceller removes)")
    w = World(root, "aecoff", a.asr_model, {}, MIC_AEC=0)
    w.add_session()
    code, out, err, prog = process(w)
    check(code == 0, "process with MIC_AEC=0 exits 0")
    if code == 0:
        assert_finished(w, out, prog, aec="off")


def scenario_note_failed(root, a) -> None:
    print("\n=== scenario note-failed: Claude overloaded -> transcript published, retry with reprocess --pending")
    w = World(root, "notefail", a.asr_model, {"FVA": "FDA"}, delay=0.1)
    set_scenario(w.fake_dir, runs=[{"mode": "overloaded"}])
    w.add_session()
    code, out, err, _ = process(w)
    final = w.final()
    st_arch = jload(final / "state.json") if (final / "state.json").exists() else {}
    tomb = jload(w.session_dir() / "state.json")
    check(code == 1 and out.strip().splitlines()[-1].startswith("FAILED: Note failed:"), "process exits 1 with 'FAILED: Note failed: ...'", out.strip()[-120:])
    check((final / "transcript.md").is_file() and not (final / "meeting-note.md").exists() and (final / "audio.m4a").is_file(), "the transcript and audio are published, no note")
    check(st_arch.get("stage") == "failed" and st_arch.get("retryable") is True and st_arch.get("error_kind") == "overloaded", "archive state.json: failed, retryable, overloaded")
    check(tomb["stage"] == "failed" and Path(tomb["final_dir"]) == final, "tombstone: failed with final_dir (Open Meeting Folder still works)")
    set_scenario(w.fake_dir, runs=[{"mode": "success"}], note_offset=len([c for c in fake_calls(w.fake_dir) if c["kind"] == "note"]))
    sha = hashlib.sha256((final / "transcript.json").read_bytes()).hexdigest()
    code, out, err = w.mcap("reprocess", "--pending")
    check(code == 0 and "1 ok" in out, "reprocess --pending retried it successfully", out.strip().splitlines()[-1])
    check((final / "meeting-note.md").is_file() and not (final / "state.json").exists() and hashlib.sha256((final / "transcript.json").read_bytes()).hexdigest() == sha, "note created in place, state.json gone, transcript untouched")
    check(jload(w.session_dir() / "state.json")["stage"] == "done", "tombstone updated to done")


def scenario_archive_unavailable(root, a) -> None:
    print("\n=== scenario archive-unavailable: Drive not mounted -> failed in staging, retried after the mount appears")
    w = World(root, "nodrive", a.asr_model, {})
    w.write_config({**w.values, "ARCHIVE_DIR": w.root / "drive not mounted" / "My Drive" / "Meetings"})
    w.add_session()
    code, out, err, _ = process(w)
    sd = w.session_dir()
    st = jload(sd / "state.json")
    check(code == 1 and st["stage"] == "failed" and st["error_kind"] == "archive_unavailable" and st["retryable"] is True, "process fails with archive_unavailable (retryable)", st["error"][:60])
    check((sd / "mic.wav").is_file() and (sd / "transcript.json").is_file() and (sd / "meeting-note.md").is_file(), "WAVs, transcript and note stay in staging")
    check(not (w.root / "drive not mounted").exists(), "nothing is created under the missing mount")
    (w.root / "drive not mounted" / "My Drive").mkdir(parents=True)
    code, out, err = w.mcap("reprocess", "--pending")
    check(code == 0 and "1 ok" in out and (w.root / "drive not mounted" / "My Drive" / "Meetings" / "2026-10" / FOLDER / "meeting-note.md").is_file(), "after the mount appears reprocess --pending publishes it", out.strip().splitlines()[-1])


def scenario_noleak_and_discard(root, a) -> None:
    print("\n=== scenario no-leak + discard: headphones (AEC auto leaves the mic alone) and a silent session (discarded)")
    w = World(root, "noleak", a.asr_model, {})
    w.add_session("2026-10-07_1500_meet", "Meet – Acme Partner Call", leak_gain=0.0)
    code, out, err, _ = process(w, "2026-10-07_1500_meet")
    tj = jload(next((w.archive / "2026-10").glob("*")) / "transcript.json") if code == 0 else {}
    check(code == 0 and tj.get("aec", {}).get("applied") is False and tj["aec"].get("reason") and tj["echo_suppressed"] == 0, "no leakage: aec not applied (reason recorded), nothing suppressed", json.dumps(tj.get("aec"))[:140])
    check(sum(1 for s in tj.get("segments", []) if s["track"] == "mic") >= 2, "the user's own speech is transcribed untouched")
    w.add_session("2026-10-07_1600_meet", "Meet – abc-defg-hij", silent=True)
    code, out, err, _ = process(w, "2026-10-07_1600_meet")
    st = jload(w.session_dir("2026-10-07_1600_meet") / "state.json")
    check(code == 0 and st["stage"] == "done" and st["discarded"] is True and (w.support / "sessions" / "_discarded" / "2026-10-07_1600_meet").is_dir(), "a session without speech is discarded (kept 7 days in sessions/_discarded)")


def scenario_api(root, a) -> None:
    """SPEC 17 through the real CLI in subprocesses: the fake Keychain shim serves a CANARY key, the fake claude reports costs."""
    print("\n=== scenario api: CLAUDE_AUTH=api (fake Keychain + fake claude): cost log, credit exhaustion + retry, daily budget, canary scan")
    import hashlib
    import notes_cli_support as h
    sec = h.FakeSecurity(root / "api-keychain" / h.SECURITY_DIRNAME)           # outside the worlds: it IS the fake Keychain
    sec.store(h.CANARY)
    canary_sha = "sha256:" + hashlib.sha256(h.CANARY.encode()).hexdigest()
    outputs: list = []                                                          # everything the CLI printed, for the canary scan

    def run(w, *args):
        code, out, err = w.mcap(*args)
        outputs.extend([out, err])
        return code, out, err

    w = World(root, "api", a.asr_model, {"FVA": "FDA"}, delay=0.1, CLAUDE_AUTH="api", CLAUDE_DAILY_BUDGET_USD=30, CLAUDE_MEETING_BUDGET_USD=15)
    w.extra_env["MCAP_SECURITY_BIN"] = str(sec.path)
    set_scenario(w.fake_dir, cost=0.42)
    w.add_session()
    code, out, err, prog = process(w)
    outputs.extend([out, err])
    check(code == 0, "api: mcap process exits 0", out.strip().splitlines()[-1][:120] if out.strip() else err[-300:])
    if code != 0:
        return
    assert_finished(w, out, prog, api=True, expect_cleanup_changes=(1 if "tiny" in a.asr_model else None))
    calls = [c for c in fake_calls(w.fake_dir) if c["kind"] != "auth"]
    check(calls and all(c["env"].get("ANTHROPIC_API_KEY") == canary_sha for c in calls), "api: the Keychain key (sha256 matches) reached every claude child as ANTHROPIC_API_KEY")
    check(not any("CANARY" in " ".join(c["argv"]) for c in calls), "api: no key on any claude argv")
    check(sec.reads() >= len(calls), "api: the key was read from the fake Keychain at call time", f"{sec.reads()} reads for {len(calls)} calls")
    entries = [json.loads(l) for l in (w.support / "usage.jsonl").read_text().splitlines() if l.strip()]
    model_lines = [e for e in entries if e["stage"] in ("cleanup", "note", "verify")]
    check(model_lines and all(e["auth"] == "api" and abs(e["cost_usd"] - 0.42) < 1e-9 for e in model_lines), "api: usage.jsonl has auth=api and cost_usd=0.42 on every cleanup/note/verify line", str(len(model_lines)))
    code, out, err = run(w, "usage")
    total = 0.42 * len(model_lines)
    check(code == 0 and "Claude cost in USD" in out and f"${total:.2f}" in out and "api $" in out, "api: `mcap usage` shows the 7/30 day cost by billing path", f"expected ${total:.2f}")
    n0 = len(fake_calls(w.fake_dir))
    code, out, err = run(w, "doctor", "--no-warmup")
    line = lambda name: next((l for l in out.splitlines() if f"] {name}:" in l), "")
    check(code == 0 and line("api key").startswith("[PASS]") and "validated: no" in line("api key") and "API key (Console credits)" in line("billing mode") and line("api budget").startswith("[PASS]"), "api: `mcap doctor` reports the key (prefix ok, not validated), the billing mode and the daily budget", out.strip().splitlines()[-1])
    check(len(fake_calls(w.fake_dir)) == n0, "api: doctor made no claude call (no billing call by itself)")
    code, out, err = run(w, "api-key", "status")
    check(len(fake_calls(w.fake_dir)) == n0, "api: api-key status made no claude call")
    check(code == 0 and f"{len(h.CANARY)} characters" in out and "sk-ant-" in out, "api: `mcap api-key status` shows presence and length, not the key", out.strip()[:100])
    p = w.popen("api-key", "set", stdin=subprocess.DEVNULL)
    o, e = p.communicate(timeout=60)
    outputs.extend([o, e])
    check(p.returncode == 2 and "must run in a terminal" in e and not sec.argvs("add-generic-password"), "api: `mcap api-key set` without a TTY is refused and never starts the security tool", e.strip()[:100])
    code, out, err = run(w, "api-key", "check")
    check(code == 0 and "API key OK" in out and "apiKeySource: ANTHROPIC_API_KEY" in out and "cost_usd:     0.420000" in out, "api: `mcap api-key check` makes one call and prints model, source and cost", out.strip().splitlines()[0] if out.strip() else err[-100:])
    check(len(fake_calls(w.fake_dir)) == n0 + 1, "api: api-key check made exactly one claude call")

    # credit exhausted: transcript published, retryable, no attempt counted; a later `reprocess --pending` finishes it
    w.add_session("2026-10-07_1600_meet", "Meet – Acme Partner Call")
    set_scenario(w.fake_dir, runs=[{"mode": "api_credit"}], cleanup={"mode": "api_credit"}, leak_key=True)
    code, out, err, _ = process(w, "2026-10-07_1600_meet")
    outputs.extend([out, err])
    folder = next(p for p in (w.archive / "2026-10").iterdir() if p.name.startswith("2026-10-07_1600"))
    st = jload(folder / "state.json") if (folder / "state.json").exists() else {}
    check(code == 1 and out.strip().splitlines()[-1].startswith("FAILED: Note failed: Anthropic API credit exhausted"), "api: credit exhausted -> `FAILED: Note failed: Anthropic API credit exhausted ...`", out.strip()[-140:])
    check((folder / "transcript.md").is_file() and not (folder / "meeting-note.md").exists(), "api: credit exhausted: the transcript is published, no note")
    check(st.get("stage") == "failed" and st.get("error_kind") == "credit_exhausted" and st.get("retryable") is True and st.get("attempts", 0) == 0 and "credit exhausted" in (st.get("warning") or ""), "api: state.json = failed / credit_exhausted / retryable / not an attempt / warning", json.dumps({k: st.get(k) for k in ("stage", "error_kind", "retryable", "attempts")}))
    n_note = len([c for c in fake_calls(w.fake_dir) if c["kind"] == "note"])
    set_scenario(w.fake_dir, runs=[{"mode": "success"}], note_offset=n_note, cleanup={"replacements": {}}, leak_key=False)
    code, out, err = run(w, "reprocess", "--pending")
    check(code == 0 and "1 ok" in out and (folder / "meeting-note.md").is_file() and not (folder / "state.json").exists(), "api: after credit is added `reprocess --pending` finishes the note in place", out.strip().splitlines()[-1])

    # the daily budget: a tiny budget is already used up -> no claude call at all, the session waits for midnight, then finishes
    w.write_config({**w.values, "CLAUDE_DAILY_BUDGET_USD": 0.5})
    w.add_session("2026-10-07_1700_meet", "Meet – Budget Test")
    calls_before = len(fake_calls(w.fake_dir))
    code, out, err, _ = process(w, "2026-10-07_1700_meet")
    outputs.extend([out, err])
    folder3 = next(p for p in (w.archive / "2026-10").iterdir() if p.name.startswith("2026-10-07_1700"))
    st = jload(folder3 / "state.json") if (folder3 / "state.json").exists() else {}
    check(code == 1 and "daily Claude budget reached" in out and len(fake_calls(w.fake_dir)) == calls_before, "api: daily budget reached -> FAILED, no claude call was made", out.strip()[-120:])
    check(st.get("error_kind") == "budget_daily" and st.get("retryable") is True and st.get("attempts", 0) == 0 and st.get("resets_at") and (folder3 / "transcript.md").is_file(), "api: state.json = failed / budget_daily / retryable / waiting for midnight (resets_at) / transcript published")
    code, out, err = run(w, "reprocess", "--pending")
    check(code == 0 and "nothing pending" in out, "api: the sweep leaves a budget_daily session alone until midnight", out.strip()[:100])
    w.write_config({**w.values, "CLAUDE_DAILY_BUDGET_USD": 0})
    code, out, err = run(w, "reprocess", str(folder3))
    check(code == 0 and (folder3 / "meeting-note.md").is_file(), "api: with the budget off (or after midnight) the retry finishes the meeting", out.strip().splitlines()[-1])

    # review finding: the failure message says "wait for midnight or a higher budget, then: mcap reprocess --pending" - a higher budget must work at once
    w.write_config({**w.values, "CLAUDE_DAILY_BUDGET_USD": 0.5})
    w.add_session("2026-10-07_1800_meet", "Meet – Budget Raise Test")
    code, out, err, _ = process(w, "2026-10-07_1800_meet")
    outputs.extend([out, err])
    folder4 = next(p for p in (w.archive / "2026-10").iterdir() if p.name.startswith("2026-10-07_1800"))
    check(code == 1 and "daily Claude budget reached" in out and (folder4 / "transcript.md").is_file() and not (folder4 / "meeting-note.md").exists(),
          "api: a second session waits for the budget too (transcript published, no note)", out.strip()[-100:])
    code, out, err = run(w, "reprocess", "--pending")
    check(code == 0 and "nothing pending" in out, "api: while the budget is still reached the sweep leaves it alone", out.strip()[:100])
    w.write_config({**w.values, "CLAUDE_DAILY_BUDGET_USD": 500})
    code, out, err = run(w, "reprocess", "--pending")
    outputs.extend([out, err])
    check(code == 0 and "1 ok" in out and (folder4 / "meeting-note.md").is_file(),
          "api: after the daily budget is raised `reprocess --pending` finishes the meeting at once (before midnight)", out.strip().splitlines()[-1] if out.strip() else err[-100:])

    # nothing of the key anywhere in this world, in the logs or in anything the CLI printed
    hits = h.canary_hits(w.root, extra=tuple(outputs))
    check(not hits, "api: the canary key appears in NO file of the world and in none of the printed output", str(hits[:3]))

    # the subscription mode of the same machine: the Keychain is never read, the child env has no key
    ws = World(root, "api-sub", a.asr_model, {}, delay=0.1, CLAUDE_AUTH="subscription", TRANSCRIPT_CLEANUP=0, NOTE_VERIFY=0)
    ws.extra_env["MCAP_SECURITY_BIN"] = str(sec.path)
    reads_before = sec.reads()
    all_before = len(sec.calls())
    ws.add_session()
    code, out, err, prog = process(ws)
    outputs.extend([out, err])
    sub_calls = fake_calls(ws.fake_dir)
    check(code == 0 and len(sec.calls()) == all_before, "subscription: the run succeeds and the Keychain tool was never started", f"{len(sec.calls()) - all_before} security calls")
    check(sub_calls and all(set(k for k in c["env"] if not (k.startswith(("LC_", "__CF")) or k in ("PWD", "SHLVL", "_", "OLDPWD"))) == {"HOME", "USER", "PATH", "LANG"} for c in sub_calls) and sec.reads() == reads_before, "subscription: no key in any claude child env although the Keychain holds one")
    sub_entries = [json.loads(l) for l in (ws.support / "usage.jsonl").read_text().splitlines() if l.strip()]
    check({e["auth"] for e in sub_entries} == {"subscription"}, "subscription: usage.jsonl says auth=subscription on every line")
    check(not h.canary_hits(ws.root, extra=(out, err)), "subscription: no canary anywhere")


LOCAL_FILES = {"audio.m4a", "mic.m4a", "remote.m4a", "session.json", "state.json", "transcript.json", "transcript.md"}


def set_session_flag(sdir: Path, value) -> None:
    """The Swift app's write of the per-meeting flag into session.json (every other key stays)."""
    data = jload(sdir / "session.json")
    data["local_only"], data["local_only_source"] = value, "menu"
    (sdir / "session.json").write_text(json.dumps(data, indent=2), encoding="utf-8")


def assert_restricted_local(w: World, out: str, *, sec=None, flag_source: str, lane_reason: str, privacy_line: str, label: str) -> None:
    """What a finished restricted meeting looks like when EVERY text lane is closed: local archive, no note, state.json kept, the three
    places that say so, nothing claude, nothing Keychain, nothing in Drive."""
    from mcap import transcript as T
    final = w.support / "local-meetings" / "2026-10" / FOLDER
    lines = out.strip().splitlines()
    check(lines and lines[-1] == f"DONE: {final}", f"{label}: stdout ends with DONE: <local archive folder>", lines[-1] if lines else "")
    got = sorted(p.name for p in final.iterdir()) if final.is_dir() else []
    check(set(got) == LOCAL_FILES, f"{label}: the local folder holds the transcript, the audio, session.json and the state file, no note", ", ".join(got))
    check(not (w.archive / "2026-10").exists() and not list(w.archive.rglob("*")) if w.archive.exists() else True,
          f"{label}: nothing reached the Drive archive (not even a month folder)")
    check(fake_calls(w.fake_dir) == [], f"{label}: ZERO claude processes (not even `claude auth status`)", str([c["kind"] for c in fake_calls(w.fake_dir)]))
    if sec is not None:
        check(sec.calls() == [], f"{label}: ZERO Keychain calls although a key is stored and CLAUDE_AUTH=api", str(len(sec.calls())))
    check(not (w.support / "usage.jsonl").exists(), f"{label}: no usage.jsonl line (no Claude call, not even a refused one)")
    check(sorted(p.name for p in w.session_dir().iterdir()) == ["state.json"], f"{label}: staging holds only the tombstone")
    tomb = jload(w.session_dir() / "state.json")
    check(tomb["stage"] == "done" and Path(tomb["final_dir"]) == final and tomb["lanes"]["llm"] == f"skipped:{lane_reason}", f"{label}: tombstone is done and points at the local folder")
    state = jload(final / "state.json")
    check(state["stage"] == "done" and state["error"] is None and state["error_kind"] is None and state["warning"] is None,
          f"{label}: state.json stage done, no error, no warning (a skip is not a failure)")
    check(state["local_only"] is True and state["local_only_source"] == flag_source, f"{label}: state.json local_only / local_only_source", f"{state.get('local_only')} {state.get('local_only_source')}")
    check(state["lanes"] == {lane: f"skipped:{lane_reason}" for lane in ("llm", "calendar", "drive")}, f"{label}: state.json lanes", json.dumps(state["lanes"]))
    check(state["done"] == {"audio": True, "asr": True, "note": False, "publish": True}, f"{label}: done flags", json.dumps(state["done"]))
    tj, tmd = jload(final / "transcript.json"), (final / "transcript.md").read_text(encoding="utf-8")
    check(T.validate_transcript(tj) == [], f"{label}: transcript.json valid")
    check(tj.get("policy") == {"local_only": True, "lanes": {lane: f"skipped:{lane_reason}" for lane in ("llm", "calendar", "drive")}} and "asr" not in tj,
          f"{label}: transcript.json policy block (and no asr block: no external engine)", json.dumps(tj.get("policy")))
    check(privacy_line in tmd.splitlines()[:9], f"{label}: transcript.md header carries the Privacy line", privacy_line)
    check(tmd.strip() == T.render_markdown(tj, {"title": TITLE, "date": "2026-10-07", "platform_label": "Google Meet", "start_time": jload(final / "session.json")["start_time"],
                                               "duration_sec": 200.0, "asr_model": tj["asr_model"]}).strip(), f"{label}: transcript.md == render_markdown(transcript.json)")
    for nm in ("audio.m4a", "mic.m4a", "remote.m4a"):
        d, ftype, raw = afinfo(final / nm)
        check(d is not None and abs(d - 200.0) < 1.0 and ftype == "m4af", f"{label}: {nm} is a {d} s AAC m4a")
    check(sum(1 for s in tj["segments"] if s["track"] == "remote") >= 6, f"{label}: the real ASR transcribed the meeting under the strict socket tripwire")


def scenario_local_only(root, a) -> None:
    print("\n=== scenario local-only: session.json local_only=true, CLAUDE_AUTH=api with a key in the fake Keychain, real ASR")
    import notes_cli_support as h
    sec = h.FakeSecurity(root / "lo-keychain" / h.SECURITY_DIRNAME)
    sec.store(h.CANARY)
    w = World(root, "localonly", a.asr_model, {"FVA": "FDA"}, delay=0.1, CLAUDE_AUTH="api", CALENDAR_LOOKUP="auto")
    w.extra_env["MCAP_SECURITY_BIN"] = str(sec.path)
    sdir = w.add_session()
    set_session_flag(sdir, True)
    code, out, err, prog = process(w)
    check(code == 0, "local-only: mcap process exits 0", out.strip().splitlines()[-1][:120] if out.strip() else err[-300:])
    if code != 0:
        return
    stages = [p["stage"] for p in prog]
    check("failed" not in stages and {"audio", "transcribing", "done"} <= set(stages) and "noting" not in stages, "local-only: the state never shows a note step", " > ".join(dict.fromkeys(stages)))
    assert_restricted_local(w, out, sec=sec, flag_source="session", lane_reason="local_only",
                            privacy_line="Privacy: local-only (note, calendar, Drive skipped)", label="local-only")
    final = w.support / "local-meetings" / "2026-10" / FOLDER
    check(not h.canary_hits(w.root, extra=(out, err)), "local-only: the canary key appears nowhere")
    # reprocess: the finished local folder is found by --last, stays where it is, keeps its name and file list, and still starts nothing
    before = sorted(p.name for p in final.iterdir())
    code, out2, err2 = w.mcap("-v", "reprocess", "--last")
    check(code == 0 and out2.strip().splitlines()[-1] == f"DONE: {final}", "local-only: reprocess --last finds the local folder and ends DONE in place", out2.strip()[-100:])
    check(sorted(p.name for p in final.iterdir()) == before and not (w.archive / "2026-10").exists(), "local-only: reprocess leaves name, place and file list alone and never reaches Drive")
    check(fake_calls(w.fake_dir) == [] and sec.calls() == [], "local-only: reprocess started no claude and read no Keychain item")
    # the same session with the flag OFF still makes a note (the gate does not close anything by itself)
    w.add_session("2026-10-07_1500_meet", "Meet – Acme Partner Call")
    set_session_flag(w.session_dir("2026-10-07_1500_meet"), False)
    code, out3, err3, _ = process(w, "2026-10-07_1500_meet")
    kinds = [c["kind"] for c in fake_calls(w.fake_dir)]
    check(code == 0 and "note" in kinds and sec.reads() >= 1, "local-only: with the flag false the same world makes a note (claude called, the key read)", str({k: kinds.count(k) for k in set(kinds)}))


def scenario_policy_locked(root, a) -> None:
    print("\n=== scenario policy-locked: an invalid policy file (MCAP_POLICY_PATH) closes every lane; the meeting is still transcribed")
    from mcap import config
    if config.system_policy_present():
        info("this Mac has a system policy or policy.required: MCAP_POLICY_PATH is ignored here, scenario skipped")
        return
    import notes_cli_support as h
    sec = h.FakeSecurity(root / "pl-keychain" / h.SECURITY_DIRNAME)
    sec.store(h.CANARY)
    w = World(root, "policylocked", a.asr_model, {}, delay=0.1, CLAUDE_AUTH="api", CALENDAR_LOOKUP="auto")
    w.extra_env["MCAP_SECURITY_BIN"] = str(sec.path)
    policy_file = w.root / "etc" / "policy.json"
    policy_file.parent.mkdir()
    policy_file.write_text(json.dumps({"schema": 1, "profile": "personal", "revision": 1}), encoding="utf-8")   # valid JSON, but not root-owned: locked
    w.extra_env["MCAP_POLICY_PATH"] = str(policy_file)
    w.add_session()
    code, out, err, _ = process(w)
    check(code == 0, "policy-locked: mcap process exits 0 (a lock never loses the meeting)", out.strip().splitlines()[-1][:120] if out.strip() else err[-300:])
    if code != 0:
        return
    assert_restricted_local(w, out, sec=sec, flag_source="policy-lock", lane_reason="policy-locked",
                            privacy_line="Privacy: local-only (note, calendar, Drive skipped)", label="policy-locked")
    check(jload(w.local_state())["asr"]["reason"] == "policy-locked", "policy-locked: state.json asr.reason says policy-locked")
    code, out2, err2 = w.mcap("doctor", "--no-warmup")
    check(not h.canary_hits(w.root, extra=(out, err, out2, err2)), "policy-locked: the canary key appears nowhere")


def scenario_org_denied(root, a) -> None:
    print("\n=== scenario org-denied: an injected company policy denies the calendar and Drive lanes (in-process: a policy file must be root-owned)")
    import hashlib
    from unittest import mock
    import notes_cli_support as h
    from mcap import lanes, pipeline
    from mcap.config import load_config
    sec = h.FakeSecurity(root / "od-keychain" / h.SECURITY_DIRNAME)
    w = World(root, "orgdenied", a.asr_model, {"FVA": "FDA"}, delay=0.1, CALENDAR_LOOKUP="auto")
    pin = hashlib.sha256((w.fake_dir / "claude").resolve().read_bytes()).hexdigest()
    doc = {"schema": 1, "profile": "company", "revision": 3, "support": {"contact": "IT #help"},
           "lanes": {"asr_remote": "deny", "asr_cloud": "deny", "llm": "allow", "calendar": "deny", "drive": "deny"},
           "approvals": {"llm": "TICKET-1"}, "llm": {"claude_bin_pin": {"sha256": pin}},
           "asr": {"allowed_engines": ["whisper"], "allowed_hosts": []}, "archive": {"allowed_roots": [str(w.archive_parent)]}}
    policy_file = w.root / "etc" / "policy.json"
    org = h.load_test_policy(policy_file, doc)
    check(org.valid and org.lanes["calendar"] == "deny" and org.lanes["llm"] == "allow", "org-denied: the injected policy is a valid company policy", str(org.locked_reason))
    w.add_session()
    w.write_config({**w.values, "ASR_ALLOW_DOWNLOAD": 0})                 # what the company baseline enforces: the model is on disk, nothing may be fetched
    cfg = load_config(w.config_path)
    cfg.policy_path = policy_file
    inputs = lanes.PrivacyInputs(policy=org, stat_fn=h.make_stat_fn(policy_file), sleep=lambda seconds: None)
    env = {"MCAP_SECURITY_BIN": str(sec.path), "HF_HUB_OFFLINE": "1"}
    with mock.patch.dict(os.environ, env):
        result = pipeline.process_session(w.session_dir(), cfg, privacy_inputs=inputs)
    check(result.ok, "org-denied: the pipeline finishes", str(result.error))
    if not result.ok:
        return
    final = w.support / "local-meetings" / "2026-10" / FOLDER
    check(result.final_dir == final, "org-denied: the Drive lane is denied: the meeting is in the local archive", str(result.final_dir))
    check(not (w.archive / "2026-10").exists(), "org-denied: nothing reached the Drive archive")
    kinds = [c["kind"] for c in fake_calls(w.fake_dir)]
    check(kinds.count("note") == 1 and kinds.count("calendar") == 0 and sec.calls() == [], "org-denied: the llm lane is open (the note was made) and the calendar was never called", str({k: kinds.count(k) for k in set(kinds)}))
    check((final / "meeting-note.md").is_file() and (final / "state.json").is_file(), "org-denied: a note exists and the restricted folder keeps its state.json")
    state = jload(final / "state.json")
    check(state["lanes"] == {"llm": "ok", "calendar": "skipped:policy-lane", "drive": "skipped:policy-lane"} and state["local_only"] is False and state["stage"] == "done",
          "org-denied: state.json lanes say which lane the organisation closed", json.dumps(state["lanes"]))
    tmd = (final / "transcript.md").read_text(encoding="utf-8")
    check("Privacy: restricted by organization policy (calendar, Drive skipped)" in tmd.splitlines()[:9], "org-denied: transcript.md says it was restricted by organization policy")
    check(jload(final / "transcript.json")["policy"]["local_only"] is False, "org-denied: transcript.json policy block, local_only false")


SCENARIOS = ("main", "followups", "kill9", "aec-off", "note-failed", "archive-unavailable", "no-leak", "api", "local-only", "org-denied", "policy-locked")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--keep", action="store_true", help="keep the temp worlds and print their location")
    ap.add_argument("--asr-model", default=TINY, help="ASR_MODEL for the runs (default: the tiny model; HF_HOME must hold it)")
    ap.add_argument("--scenario", action="append", choices=SCENARIOS, help="run only these (followups implies main); default: all")
    a = ap.parse_args()
    if not (TTS / "meeting_like_184s.wav").is_file():
        print("benchmarks/tts clips are missing (generated with macOS `say`); nothing to test")
        return 2
    want = set(a.scenario or SCENARIOS)
    if "followups" in want:
        want.add("main")
    root = Path(tempfile.mkdtemp(prefix="mcap-e2e-"))
    print(f"temp worlds in {root}  (python {sys.executable}, ASR_MODEL {a.asr_model}, HF_HOME {os.environ.get('HF_HOME')})")
    try:
        main_world = scenario_main(root, a) if "main" in want else None
        if "followups" in want and main_world:
            scenario_followups(main_world)
        if "kill9" in want:
            scenario_kill9(root, a)
        if "aec-off" in want:
            scenario_aec_off(root, a)
        if "note-failed" in want:
            scenario_note_failed(root, a)
        if "archive-unavailable" in want:
            scenario_archive_unavailable(root, a)
        if "no-leak" in want:
            scenario_noleak_and_discard(root, a)
        if "api" in want:
            scenario_api(root, a)
        if "local-only" in want:
            scenario_local_only(root, a)
        if "org-denied" in want:
            scenario_org_denied(root, a)
        if "policy-locked" in want:
            scenario_policy_locked(root, a)
    finally:
        if a.keep:
            print(f"kept: {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)
    print(f"\nE2E SYNTHETIC: {sum(results)} passed, {len(results) - sum(results)} failed")
    return 0 if results and all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
