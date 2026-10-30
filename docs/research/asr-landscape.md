# Local ASR landscape for Korean + English business meetings: a survey of public sources (as of 2026-10-07)

Scope: speech-to-text models that can run locally on an Apple silicon laptop (macOS, Command Line Tools only, no ffmpeg, no package-manager
installs, no hosted speech API; see SPEC section 10). Audio of interest: mixed Korean / English meetings with code-switching, domain
vocabulary, numbers and names. The survey rests on public sources (papers, model cards, leaderboards, issue trackers) and on a few small
checks on one Pro-class Apple silicon laptop. It describes no particular recording.

**Evidence legend** (load-bearing claims carry one of these tags):

- **[V]** verified by running something on the test laptop on the day of writing (commands and scripts were executed there).
- **[S]** verified by reading source code, package metadata, HF API responses, model-card text or safetensors headers fetched today.
- **[W]** from the web (paper, blog, GitHub issue, leaderboard); URL in the Sources section; not reproduced here.

No model weights above 100 MB were downloaded. Only `mlx-community/whisper-tiny` (75 MB) and ~4.5 MB of Qwen tokenizer files
were pulled. So **no large model was run end-to-end on real or synthetic speech**. Speed numbers for large
models come from a synthetic-weights harness (real architecture, random weights, section 2), not from transcribing audio.

---

## 0. TL;DR

1. **Keep `mlx-community/whisper-large-v3-mlx` (fp16, 3.08 GB) as the baseline and as the default until a challenger wins on real audio of the intended kind.**
   It is the only candidate with Korean + English + timestamps + prompt + anti-hallucination knobs + a tiny dependency set,
   and it is the best-documented for Korean/English code-switching (still weak, see section 5).
2. **Challenger #1 = Qwen3-ASR-1.7B** (`mlx-community/Qwen3-ASR-1.7B-bf16`, 4.08 GB; Apache-2.0; run with `mlx-qwen3-asr` or `mlx-audio`).
   It beats Whisper large-v3 on English meeting audio by a wide margin on the Open ASR Leaderboard (AMI 8.31 vs 13.63 WER),
   is roughly equal or slightly better on Korean read speech (FLEURS-ko CER 2.57-4.60 vs 4.08-4.89 depending on the study),
   and has a `context` hotword feature. Its documented weaknesses are exactly this use case: mixed-language audio
   (language auto-detect collapses to one script), hotword leakage, repetition loops, noise/echo fillers. Needs a real-audio A/B.
3. **Korean fine-tunes: do not use Whisper Korean fine-tunes.** Literature shows Korean-only fine-tuning destroys English
   (Whisper-medium LibriSpeech WER 6.74 to 57.56). The only interesting one is `TeamUNIVA/qwen3_asr_1.7b_ko_beta`
   (Qwen3-ASR-1.7B fine-tune, self-reported Korean CER 6.86 to 5.37, English unchanged); `scripts/setup_python.sh` does not download it.
4. **NVIDIA Parakeet / Canary / Canary-Qwen, Granite-Speech, Voxtral 3B, Kyutai, FireRed, GLM-ASR, Phi-4-MM: no Korean. Rule out.**
   Korean-capable but not competitive: Voxtral-Mini-4B-Realtime, Cohere Transcribe (no code-switching, gated), SenseVoice-Small,
   Nemotron 3.5 ASR streaming, Fun-ASR-MLT-Nano (possible but odd runtime). VibeVoice-ASR (9B, 17 GB bf16) is the only model that
   *claims* native code-switching + hotwords + 60 min single pass, but it is huge; stretch candidate only.
5. **No newer OpenAI Whisper exists** (HF `openai` org newest ASR = large-v3-turbo, Oct 2024; GitHub tag v20250625 is a packaging release). [V]
6. mlx-whisper 0.4.3 facts that matter for the pipeline (all [V]/[S]): no beam search; `initial_prompt` only affects the first 30 s
   window of a call when `condition_on_previous_text=False` (so call `transcribe()` once per VAD chunk); prompt is left-truncated to the
   last 223 tokens; `hallucination_silence_threshold` only works with `word_timestamps=True`; `torch` is installed by pip metadata
   but **not needed at runtime** (uninstall it: venv 1.2 GB to 650 MB).
7. Speed on the test laptop (synthetic-weights harness, section 2): Whisper large-v3 fp16 ~6x real time on dense Korean, ~8x on English;
   Qwen3-ASR-1.7B fp16 ~6x Korean, ~9x English; turbo ~21x; Qwen 0.6B ~12x. A 60-minute meeting (about 40 min of speech over both tracks)
   should transcribe in roughly 7-10 minutes with either top model.

### Candidate shortlist for a local benchmark (max 4; downloads announced up front)

| # | HF repo (verified to exist) | Download | Runtime | Role |
|---|---|---|---|---|
| A | `mlx-community/whisper-large-v3-mlx` | **3.08 GB** (weights.npz 3,083 MB) | `mlx-whisper` 0.4.3 | **Baseline / current default** |
| B | `mlx-community/Qwen3-ASR-1.7B-bf16` | **4.08 GB** (4,076 MB) | `mlx-qwen3-asr` 0.4.4 (fallback `mlx-audio` 0.5.8) | Main challenger |
| C | `TeamUNIVA/qwen3_asr_1.7b_ko_beta` | **4.70 GB** (4,698 MB) | `mlx-qwen3-asr` (loads official-format `thinker.*` checkpoints; end-to-end load **not verified**) | Korean-tuned third-party fine-tune; **not downloaded by `scripts/setup_python.sh`**, listed for completeness |
| D | `mlx-community/whisper-large-v3-turbo` | **1.61 GB** (1,614 MB) | `mlx-whisper` | Speed/accuracy control (expected to lose on accuracy; optional) |

Total if all four: **13.5 GB**. If only A+B: 7.2 GB. Python side: one venv with `mlx-whisper` + `mlx-qwen3-asr` (+ uninstall `torch`) = **651 MB**, verified to co-install and import. [V]
Stretch (not worth downloading unless A/B/C fail on code-switching): `mlx-community/VibeVoice-ASR-4bit` 5.71 GB (needs `mlx-audio`, transformers 5.x, 552 MB venv). [S]

**Suggested default: A (Whisper large-v3 MLX fp16)** pending a comparison on real audio of the intended kind; switch to B (or C) only if it
wins on the SPEC section 9 error classes (decision rule in section 8). Reasoning: (a) when two models are not clearly different, the better
documented one (large-v3) stays; (b) A is
the only option with a mature, verified prompt + anti-hallucination toolbox in a minimal dependency set; (c) B's published advantages are mostly English and read-speech
Korean, while its documented failure modes (language collapse on mixed audio, hotword leakage, repetition) target mixed-language meeting audio.

---

## 1. Master comparison (Korean-capable and relevant candidates)

CER = character error rate (Korean), WER = word error rate. FLEURS-ko is clean read speech: it does not predict meeting performance.

| Model | Korean? | Disk | Licence | Apple Silicon path | Korean FLEURS CER | English | Code-switching evidence | Hotwords |
|---|---|---|---|---|---|---|---|---|
| **Whisper large-v3** | yes (99 langs) | 3.08 GB MLX fp16 | Apache-2.0 (HF card) | MLX (`mlx-whisper`), whisper.cpp(+CoreML), CT2 CPU | 4.89 [W handy], 4.08 [W zkaelxz] | Open ASR avg 5.78, AMI 13.63, long-form 11.23 [S] | HiKE: overall MER 26.1 vs mono CER 3.2 [W] | `initial_prompt` (223-token window) |
| Whisper large-v3-turbo | yes | 1.61 GB | MIT (HF) | same | 5.24 [W handy], 4.60 [W zkaelxz] (large-v3 better by 0.52 pt, CI excludes 0) | avg 6.36, AMI 13.88 [S] | not separately measured | same |
| **Qwen3-ASR-1.7B** | yes (30 langs) | 4.08 GB bf16, 2.47 GB 8-bit | Apache-2.0 | MLX (`mlx-qwen3-asr`, `mlx-audio`), transformers>=5.13 (MPS untested), sherpa-onnx CPU | 2.57 [W paper], 3.34 plain / 4.82 VAD-spans [W zkaelxz], 4.60 [W handy], 3.54 [W whispernotes] | **avg 4.31**, AMI 8.31, E22 5.84 [S] | issues #16, #163: auto-LID collapses to English phonetics; forced language translates [W] | `context` string (leaks, see 4.4) |
| Qwen3-ASR-0.6B | yes | 1.57 GB bf16, 1.01 GB 8-bit | Apache-2.0 | same | 3.72 [W paper], 5.82 [W handy] | avg 5.04 [S] | same | same |
| TeamUNIVA ko_beta (Qwen3-ASR-1.7B FT) | yes | 4.70 GB | Apache-2.0 | probably `mlx-qwen3-asr` | self-reported mixed-set CER 5.37 vs base 6.86 [S card] | LibriSpeech 2.46 vs 2.50 (self-reported) | none | as Qwen |
| VibeVoice-ASR (9B) | yes (50+) | 17.35 GB bf16 / 5.71 GB 4-bit | MIT | `mlx-audio` | MLC-Challenge ko WER 9.65 (vendor doc) [S] | Open ASR (HF port) avg 5.58, AMI 12.02 [S] | claims native [S, vendor] | `hotwords` |
| Cohere Transcribe 03-2026 | yes (14) | 4.13 GB | Apache-2.0 but **HF-gated** | `mlx-audio` (`cohere_asr`), CoreML 6-bit (GPL-3.0, community) | 6.57 [W handy] | avg 4.67, long-form 9.73 [S] | card: "inconsistent on code-switched audio"; no LID; eager on non-speech [W] | none |
| Fun-ASR-MLT-Nano-2512 | yes (31) | 1.99 GB | Apache-2.0 tag (handy table says "FunASR v1.1") | `mlx-audio` (`fun_asr_nano`), funasr | 5.20 [W handy] | n/a (Nano EN avg 5.74) [S] | none | hotwords (funasr API) |
| SenseVoice-Small | yes (5) | 0.94 GB | "other" (FunASR model licence) | `mlx-audio`, sherpa-onnx | 8.27 [W handy] | n/a | HiKE overall MER 32.5 [W] | none |
| Nemotron 3.5 ASR streaming 0.6B | yes (40) | 1.28 GB MLX | NVIDIA open / OpenMDW | `mlx-audio` | 7.12-8.31 (NVIDIA card) / 8.89 (handy) | avg 7.88 [S] | none | none |
| Voxtral-Mini-4B-Realtime-2602 | yes (13) | 8.89 GB fp16 / 3.15 GB 4-bit | Apache-2.0 | `mlx-audio`, voxmlx | Mistral card: Korean 15.74 % at 480 ms (metric not stated, probably WER); 5.27 CER [W handy] | avg 6.46 [S] | none | none |
| MOSS-Transcribe-Diarize 0.9B | yes (50+, MLC-SLM winner) | 1.83 GB | Apache-2.0 | community MLX only; `trust_remote_code` | no number | avg 4.64 [S] | none | prompt hotwords (Chinese prompt) |
| Parakeet-TDT-0.6B-v3, Canary-1B-v2, Canary-Qwen-2.5B | **no** (25 EU / English) | - | CC-BY-4.0 | - | - | strong EN | - | - |
| Granite-Speech 4.1 / 5.0, Voxtral 3B, Kyutai STT, FireRedASR2, GLM-ASR-Nano, Phi-4-MM | **no** | - | - | - | - | - | - | - |

---

## 2. Environment, what was actually run, and local speed numbers

### 2.1 Hardware measurements [V]

```
python (mlx 0.32.3): fp16 matmul 4096/8192 -> 4.43-4.44 TFLOPS
                     memory read (sum over 2.15 GB fp16 array) -> ~134 GB/s   (spec peak 200 GB/s)
system_profiler: a Pro-class Apple silicon chip, 16 GPU cores
```

### 2.2 Synthetic-weights timing harness [V]

Real model architectures with **random weights** (no download), forced decode lengths, fp16, one 30 s window per call.
The harness scripts are not part of this repository.
They exclude VAD, temperature-fallback re-decodes, word-timestamp DTW and I/O, so real runs are **~10-30 % slower**.

| Model (fp16, the test laptop) | Fixed cost per 30 s window | Decode speed | Dense Korean window (~160-175 tokens) | English window (~105-115 tokens) |
|---|---|---|---|---|
| Whisper large-v3 | encoder 0.64 s | 38 tok/s (26 ms/token) | ~4.9 s = **~6x RT** | ~3.7 s = ~8x RT |
| Whisper large-v3-turbo | encoder 0.66 s | 203 tok/s | ~1.5 s = ~21x RT | ~1.2 s = ~25x RT |
| Qwen3-ASR-1.7B | 0.42 s (mel+encoder+prefill) | 37 tok/s (26.9 ms/token) | ~5.2 s = **~6x RT** | ~3.2 s = ~9x RT |
| Qwen3-ASR-0.6B | 0.11 s | 77 tok/s (13.0 ms/token) | ~2.4 s = ~12x RT | ~1.5 s = ~20x RT |

Token counts per 30 s of continuous speech were estimated from the real tokenizers: Korean ~1.0 Whisper token per Hangul syllable
(~160 tokens at 5.5 syl/s) and ~1.07 Qwen tokens/syllable (~177); English ~1.4 tokens/word (~115 at 2.7 words/s). [V]
Estimated wall time for a 60-minute meeting with ~40 min of detected speech (80 windows): ~6.5 min ideal, **~7-10 min realistic** for either top model.

Third-party numbers for orientation [W]: Whisper large-v3 MLX 10.5x RT on M1 Max (vllm-mlx page), 24x on M4 Max;
Qwen3-ASR-1.7B MLX RTF 0.077 fp16 on M4 Pro (mlx-qwen3-asr README) and 30x RT 8-bit on M5 Pro (soniqo). Consistent with the above after scaling for GPU class.

### 2.3 Environments created (all in throw-away folders, nothing global)

```
venvs/both      mlx-whisper 0.4.3 + mlx-qwen3-asr 0.4.4 (+mlx 0.32.3, numpy 2.5.3, numba 0.68, scipy, tiktoken) = 651 MB, torch removed
venvs/mlxaudio  mlx-audio[stt] 0.5.8 (+transformers 5.19.0, huggingface_hub>=1, sentencepiece, miniaudio...) = 552 MB
```
- `pip install mlx-whisper` pulls **torch** (PyPI metadata) = +550 MB. `import mlx_whisper` does not import torch and
  full `transcribe()` works after `pip uninstall -y torch` (re-run verified). `pip check` then warns "requires torch"; harmless. [V]
  Alternative: `pip install --no-deps mlx-whisper` + its other deps by hand.
- First `import mlx_whisper` took 25 s (cold caches), 1.5 s afterwards. [V]
- HF downloads without a token work (only a rate-limit warning). No `hf` CLI is installed; use `huggingface_hub.snapshot_download` from the venv.
- Not available on the test laptop: `ffmpeg`, `cmake` (so `transcribe.cpp` / whisper.cpp builds are out unless something is installed; do not). [V]
- `mlx-qwen3-asr` needs ffmpeg only for non-WAV *files*; passing a 16 kHz float32 numpy array (as the pipeline does) works without it. [S+V smoke]

---

## 3. Whisper family

### 3.1 Whisper large-v3, MLX fp16 (baseline)

- Repo [S]: `mlx-community/whisper-large-v3-mlx` (weights.npz 3,083.5 MB, fp16, MIT tag; original `openai/whisper-large-v3` is Apache-2.0 on its card).
  Quantized siblings exist but are not recommended for accuracy: `-8bit` 1.71 GB, `-4bit` 1.95 GB. Same weights in mlx-audio layout: `mlx-community/whisper-large-v3-asr-fp16` 3.09 GB.
- Other runtimes [S]: CT2 `Systran/faster-whisper-large-v3` 3.09 GB (CPU on Mac, no GPU), GGUF `handy-computer/whisper-large-v3-gguf`
  (needs `transcribe.cpp`, which needs cmake), whisper.cpp 1.9.5 released 2026-10-06 (+CoreML encoder). MLX is the pragmatic path (an independent blog measured mlx_whisper turbo 2.03x faster than whisper.cpp turbo [W]).
- Package: `mlx-whisper` **0.4.3** (Aug 2025, latest on PyPI); upstream mlx-examples still receives small commits (Dec 2025: also accepts `model.safetensors`). [S]

**Verified API facts (mlx-whisper 0.4.3, inspected and exercised with `whisper-tiny`)** [V]

```python
mlx_whisper.transcribe(audio: str | np.ndarray | mx.array, *, path_or_hf_repo='mlx-community/whisper-tiny', verbose=None,
    temperature=(0.0,0.2,0.4,0.6,0.8,1.0), compression_ratio_threshold=2.4, logprob_threshold=-1.0, no_speech_threshold=0.6,
    condition_on_previous_text=True, initial_prompt=None, word_timestamps=False, prepend_punctuations=..., append_punctuations=...,
    clip_timestamps='0', hallucination_silence_threshold=None, **decode_options)   # decode_options: language=, task=, fp16=, ...
```
1. **No beam search**: `DecodingOptions.beam_size` raises `NotImplementedError("Beam search decoder is not yet implemented")`. Greedy + temperature fallback only. (OpenAI's reference CLI defaults to beam 5.) Some quality difference vs published numbers is plausible.
2. `initial_prompt` is prepended to the **first 30 s window only** when `condition_on_previous_text=False`: after window 1 `prompt_reset_since` jumps past the prompt tokens. Therefore call `transcribe()` **once per VAD chunk (<= ~28 s)** so every chunk gets the vocabulary prompt. (Source-read in `transcribe.py` lines ~255-300, ~532.)
3. Prompt is left-truncated: only the **last 223 tokens** (`n_ctx//2 - 1`) are used. Put the most important terms **last**. Token counts with the real Whisper tokenizer [V]:
   an example list of about 30 short terms as a bare comma list = **120 tokens**; as a Korean sentence ("액미 AcmeScan-CXR 회의입니다. FDA 510(k)와 ...") = 87 tokens. Both fit.
4. `hallucination_silence_threshold` is implemented **inside the `if word_timestamps:` branch**; with `word_timestamps=False` it silently does nothing. Costs extra time (DTW alignment; numba).
5. Language: if `language` is None, detection runs **once on the first 30 s of the call** (`decode_options['language']`), then applies to the whole call.
6. Weights load with `weights.safetensors`, falling back to `weights.npz` (so the large-v3 repo works). Default dtype fp16 (`fp16=True`).

**Verified recipe** (executed here with `mlx-community/whisper-tiny`; swap the repo for large-v3; an `asr_backends_demo.py` script that is not part of this repository) [V]

```python
import numpy as np, mlx.core as mx, mlx_whisper
from mlx_whisper.load_models import load_model
from mlx_whisper.audio import log_mel_spectrogram, pad_or_trim, N_FRAMES, N_SAMPLES
from huggingface_hub import snapshot_download

REPO = "mlx-community/whisper-large-v3-mlx"

def detect_ko_en(model, chunk):                       # constrained per-chunk language ID (verified API)
    mel = log_mel_spectrogram(chunk, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    _, probs = model.detect_language(pad_or_trim(mel[:N_FRAMES], N_FRAMES, axis=-2).astype(mx.float16))
    return max(("ko", "en"), key=lambda k: float(probs[k]))   # probs is dict {lang: prob}

def whisper_chunk(chunk_f32_16k, language=None, prompt=None, repo=REPO):
    if language is None:
        language = detect_ko_en(load_model(snapshot_download(repo), dtype=mx.float16), chunk_f32_16k)
    r = mlx_whisper.transcribe(
        chunk_f32_16k, path_or_hf_repo=repo, language=language, initial_prompt=prompt,
        condition_on_previous_text=False, temperature=(0.0, 0.2, 0.4, 0.6),
        compression_ratio_threshold=2.4, logprob_threshold=-1.0, no_speech_threshold=0.6,
        word_timestamps=True, hallucination_silence_threshold=2.0, verbose=None)
    return language, [dict(start=float(s["start"]), end=float(s["end"]), text=s["text"].strip(),
                           avg_logprob=s["avg_logprob"], no_speech_prob=s["no_speech_prob"],
                           compression_ratio=s["compression_ratio"]) for s in r["segments"]]
```
(`mlx_whisper.transcribe` caches the model internally (`ModelHolder`); `load_model` in the LID helper should be cached by the caller in real code.)
The segment dict keys match SPEC 4.4 (`avg_logprob`, `no_speech_prob`). [V]

**Quality evidence**

- Korean FLEURS CER: 4.89 (handy.computer, Q8_0, FLEURS test); 4.08 (faster-whisper, 60 utterances, bootstrap CI 2.5-5.9; zkaelxz PR #740, Oct 2026). [W]
- English (Open ASR Leaderboard snapshot 2026-10-02, new cleaned datasets) [S, fetched `english_short_latest.csv`]: avg **5.78**; AMI-meeting **13.63**; Earnings22 7.99; GigaSpeech 8.35; LS-clean 1.56 / LS-other 3.52; SPGISpeech 2.71; VoxPopuli 3.95.
  Long-form (`longform_latest.csv`): **11.23** avg (earnings21 9.71, earnings22 13.16, tedlium 3.15, CORAAL 18.89). RTFx figures on the leaderboard come from datacenter GPUs, not a Mac.
- Code-switching, HiKE (Korean-English, 1,121 utterances, 2.2 h, Apache-2.0, EACL Findings 2026) [W]: **Whisper-Large 1.5B: overall MER 26.1 (word-level 28.5, phrase-level 25.3, sentence-level 20.0), PIER at switch points 36.0, versus monolingual FLEURS CER 3.2 / WER 4.4**; the paper does not state the large version. SenseVoice-Small 32.5 / 54.7; Whisper-Medium 31.3 / 41.3; GPT-4o-transcribe 21.8 / 28.8 (API, forbidden here); Gemma-3n 76.6; Seamless 83.6.
  Dominant error types: phonetic transcription of English in Hangul (or the reverse), hallucination, repetition. Fine-tuning Whisper-Medium on natural intra-sentence CS data cut MER 31.3 to 9.0 (but mono Korean CER 3.4 to 6.0), i.e. code-switching is trainable but not solved zero-shot.
- Real-world anecdotes [W]: faster-whisper discussion #1442 ("for dirty audio it is the best so far", Qwen3-ASR "didn't perform any better than whisper large-v2" for one user); Deepgram/others: large-v3 hallucinates more than v2 on silence/music. Korean "phantom subtitle" phrases are a documented failure (Solbox Korean write-up). openai/whisper discussion #1762 collects v3 hallucination reports.

**Known failure modes and mitigations for this project**

- Hallucination on silence / low-level noise (YouTube-outro phrases, loops that then feed `<|startofprev|>` context). Mitigate: VAD-trimmed chunks, `condition_on_previous_text=False`, compression-ratio + logprob thresholds, post-filter list from SPEC 7.2, repetition n-gram collapse. [W: yage.ai write-up; Solbox: raw-audio LID 95.2 %, Korean sometimes classified as Japanese/Chinese]
- Language mis-ID on code-switched chunks -> use **constrained ko/en LID** (recipe above) or force `ko` for the microphone track and `en` for Remote only after the benchmark shows it helps. Forcing `ko` pushes English terms into Hangul; forcing `en` on Korean can translate/transliterate. A/B all three.
- **Prompt leakage** (verified qualitatively with whisper-tiny, *not representative of large-v3*): with a Latin-only vocabulary prompt on Korean speech the output was Latin-script garbage that echoed prompt terms (`AcmeScan-CXR, FDA, ...`), whereas a Korean sentence prompt kept Hangul. [V `test_prompt_variants.py`] Benchmark three prompt styles: none / bare Latin list / Korean sentence containing the terms.

### 3.2 Whisper large-v3-turbo

- `mlx-community/whisper-large-v3-turbo` (1,614 MB safetensors; no licence tag, derivative of MIT `openai/whisper-large-v3-turbo`, 1.62 GB). 4 decoder layers. [S]
- Korean: FLEURS CER 5.24 (handy), 4.60 vs large-v3 4.08 (zkaelxz: paired diff -0.52 pt, CI -0.98 to -0.11, i.e. large-v3 significantly better; ~105 of turbo's 124 errors were in utterances with digits or Latin text, which is typical meeting content). [W]
- English: Open ASR avg 6.36 (AMI 13.88). [S]
- Speed here: ~21x RT dense Korean (section 2.2). Quantized: `-8bit` 0.86 GB, `-4bit` 0.46 GB (not worth the accuracy risk).
- Verdict: only a speed control; when accuracy comes first, prefer full large-v3.

### 3.3 Newer OpenAI Whisper releases / OpenAI speech

- HF `openai` org, newest ASR weights = `whisper-large-v3-turbo` (created 2024-10-01); 2025-2026 uploads there are gpt-oss, privacy-filter, circuit-sparsity. [V via HF API list]
- GitHub `openai/whisper` latest tag `v20250625`; PyPI `openai-whisper` 20250625 (no new weights). [V]
- `openai/gpt-transcribe` / gpt-4o-transcribe appear on the leaderboard as proprietary API models (avg 4.57): out of scope for a local-only design (SPEC section 10).
- Whisper-derived third-party: `TheStageAI/thewhisper-large-v3-turbo` (CoreML, cc-by-4.0, strong English avg 4.54) has **no Korean** in its language list and needs a TheStage token + Xcode SDK: rule out. [S]

---

## 4. Qwen3-ASR family

### 4.1 What exists (HF API verified today) [S]

| Repo | Size | Notes |
|---|---|---|
| `Qwen/Qwen3-ASR-1.7B` | 4.70 GB (2 shards, bf16) | Apache-2.0; official, `qwen-asr` package format (`thinker.*` keys) |
| `Qwen/Qwen3-ASR-0.6B` | 1.88 GB | |
| `Qwen/Qwen3-ASR-1.7B-hf`, `-0.6B-hf` | 4.09 GB / 1.58 GB | transformers-native (>=5.13.0), updated 2026-07-22; also appears on Open ASR Leaderboard (1.7B avg 4.31, 0.6B 5.04) |
| `Qwen/Qwen3-ForcedAligner-0.6B` (+`-hf`) | 1.84 GB | word timestamps; Korean supported; not needed (use VAD chunk times) |
| `mlx-community/Qwen3-ASR-1.7B-{bf16,8bit,6bit,4bit}` | 4.08 / 2.47 / 2.04 / 1.61 GB | mlx-audio 0.3.1 conversions (Jan 2026) |
| `mlx-community/Qwen3-ASR-0.6B-{bf16,8bit,6bit,4bit}` | 1.57 / 1.01 / 0.86 / 0.71 GB | |
| `moona3k/mlx-qwen3-asr-1.7b-{8bit,4bit}`, `-0.6b-{8bit,4bit}` | 2.17 / 1.31 / 0.84 / 0.54 GB | per-module quant (8-bit encoder), made for `mlx-qwen3-asr` |
| `csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` | 1.00 GB | sherpa-onnx CPU |
| `handy-computer/Qwen3-ASR-1.7B-gguf` | 14.9 GB (all quants) | `transcribe.cpp`, needs cmake: skip |
| `TeamUNIVA/qwen3_asr_1.7b_ko_beta` | 4.70 GB | Korean fine-tune, section 6 |

"Newer Qwen ASR": none open. The Qwen HF org's only ASR repos are the four above plus aligners; "Qwen3-ASR-Flash" in the paper is API-only. [V HF API]
Qwen3-ASR technical report: arXiv 2601.21337 (Jan 2026). 30 languages + 22 Chinese dialects, built on Qwen3-Omni; the audio encoder attends within ~8 s windows (800 mel frames, per QwenLM issue #213).

### 4.2 How to run on Apple Silicon (three routes)

| Route | Package / status | Notes |
|---|---|---|
| **A. `mlx-qwen3-asr` 0.4.4** (moona3k, Apache-2.0, 221 stars, single maintainer, created Feb 2026, active Sep 2026) | PyPI, deps: mlx, numpy, regex, huggingface-hub (no torch/transformers). Venv 285 MB. [S] | Re-implementation. Own 30 s energy-based chunking, built-in repetition collapse, `context=`, `language=`, numpy input, `finish_reason`/`truncated` flags. Claims parity: 67 % exact text match vs PyTorch, lower error on 80 s clips because it chunks at pauses. Loads official, `mlx-community/*` and `moona3k/*` repos. Past bugs fixed: runaway decode on no-EOS inputs (#8/#10), GPU memory growth, 4-min cap (#6). **Does not expose token log-probs.** |
| **B. `mlx-audio` 0.5.8** (Blaizzy, MIT, ~8k stars, very active, 2026-10-05) | PyPI; needs transformers>=5.14, huggingface_hub>=1.0, mlx>=0.31.1 (552 MB venv). [S] | `Qwen3ASRModel.generate(audio, *, language, system_prompt, hotwords=[...], chunk_duration=1200.0, repetition_penalty, repetition_context_size, ...)`. Default chunking is **1200 s**: always pass VAD chunks or `chunk_duration=30`. Open issues: mishandles short/no-speech inputs (#928), no token log-probs yet (#985). Same package also runs Whisper, Cohere, Fun-ASR, SenseVoice, VibeVoice, Nemotron, Voxtral... |
| C. transformers >= 5.13 native (`Qwen/Qwen3-ASR-1.7B-hf`) | `AutoModelForMultimodalLM`, `processor.apply_transcription_request(audio, language=, prompt=)` | MPS **untested** here (needs the 4 GB download). The older `qwen-asr` 0.0.6 package pins `transformers==4.57.6`, drags gradio/flask/sox, and its transformers backend does not apply the encoder attention windows on sdpa/eager (QwenLM/Qwen3-ASR #213, severe repetition loops on ~180 s chunks reported). **Do not use `qwen-asr` on Mac.** |

Not suitable for a local pipeline of this kind: vLLM (CUDA), `qwen-asr`, GGUF/transcribe.cpp (cmake), sherpa-onnx (CPU, 0.6B only).

**Verified (no weights) [V]**
```python
from mlx_qwen3_asr import transcribe            # signature verified by introspection
# transcribe(audio, *, model='Qwen/Qwen3-ASR-0.6B', draft_model=None, context='', language=None, return_timestamps=False,
#            diarize=False, ..., return_chunks=False, forced_aligner=None, dtype=mx.float16, max_new_tokens=None, verbose=False, on_progress=None)
# audio: path | np.ndarray (16 kHz float32) | mx.array | (array, sr). Result fields: text, language, segments, chunks, speaker_segments, finish_reason, truncated
```
- Language aliases accepted: `ko`, `ko-kr`, `Korean`, `en`, `English` (`canonicalize_language`). Raw output format parsed: `language Korean<asr_text>...` -> `('Korean', text)`.
- Code-path smoke test with a **random-weight 0.6B model instance** (no download): `transcribe(np_array, model=instance, language="Korean", context="Technical terms: Acme, ...", max_new_tokens=16)` ran without error. The same config parser also accepts the TeamUNIVA fine-tune `config.json` and its safetensors header uses the identical `thinker.*` key names (708 tensors, BF16) as the official repo. Whether the **weights load and decode** is unverified.
- Tokenizer check with the real Qwen vocab files (4.5 MB): Korean 71 chars = 45 tokens; a `context` string of a few dozen tokens for about ten key terms fits easily.

**Recipe (route A)** (API verified, weights not run):
```python
from mlx_qwen3_asr import transcribe
CTX = "Technical terms: Acme, AcmeScan-CXR, ExampleCorp, API, KPI, OKR"
r = transcribe(chunk_f32_16k, model="mlx-community/Qwen3-ASR-1.7B-bf16", language=None, context=CTX)  # also try language="Korean"
text, lang, bad = r.text.strip(), r.language, (r.truncated or r.finish_reason != "eos")
```
**Recipe (route B)**:
```python
from mlx_audio.stt import load
m = load("mlx-community/Qwen3-ASR-1.7B-bf16")
r = m.generate(chunk_f32_16k, language="Korean", hotwords=["Acme", "AcmeScan-CXR", "510(k)"], chunk_duration=30.0, repetition_penalty=1.05)
print(r.text, r.segments)   # CLI equivalent: python -m mlx_audio.stt.generate --model ... --audio a.wav --output-path out --language Korean --context "..."
```

### 4.3 Quality evidence

- **Korean read speech.** Paper (arXiv 2601.21337, Fleurs-ko CER): 0.6B **3.72**, 1.7B **2.57**, API-only Flash 2.07; CommonVoice-ko 8.48 / 5.88 / 3.82. Independent: handy.computer FLEURS-ko CER 1.7B 4.60 (rank 1) vs large-v3 4.89, turbo 5.24, 0.6B 5.82; zkaelxz (60 utterances, CPU) 1.7B 3.34 whole-utterance vs large-v3 4.08 (CIs overlap); whispernotes (M5, 150 sentences) 3.54 vs turbo 4.25 ("within error bars"). So **roughly +0.3 to +0.8 pt in Qwen's favor, not decisive**. [W]
- **Korean conversational.** Paper MLC-SLM ko (CER): 0.6B 10.31, 1.7B **8.61**, Flash 8.09. Whole MLC-SLM 11-language average: Whisper-large-v3 15.68 vs Qwen3-ASR-1.7B 12.74; Fleurs-12 avg 5.27 vs 4.90. [W]
  TeamUNIVA re-evaluated the **base** 1.7B on hand-cleaned Korean sets (best of TN/ITN reference): ClovaCall 4.48, CommonVoice-ko 7.19, FLEURS-ko 1.42, **KsponSpeech 8.65**, Zeroth 2.64, total 6.86. [S card] (For orientation, a search-summary of an ACL Findings 2025 paper reports Whisper-large-v2 zero-shot KsponSpeech CER 15.56; PDF not parseable here, treat as unverified.)
- **English meetings** (Open ASR Leaderboard 2026-10-02) [S]: 1.7B avg **4.31** (AMI **8.31**, Earnings22 5.84, GigaSpeech 7.22, LS-clean 1.26, LS-other 2.94, SPGISpeech 2.57, VoxPopuli 3.50) vs Whisper large-v3 5.78 (AMI 13.63). 0.6B avg 5.04 (AMI 9.33). No long-form (>30 s) row for Qwen3-ASR.
- Robustness (paper, internal sets) [W]: extreme-noise WER 16.17 (1.7B) vs Whisper-large-v3 63.17; accented English 16.07 vs 21.30.
- **Real-world dissent** [W]: faster-whisper #1442 user report says Qwen "no better than large-v2" on their audio; MLX vs PyTorch parity is imperfect (mlx-qwen3-asr README).

### 4.4 Code-switching, hotwords, long-form and hallucination: documented problems [W, QwenLM/Qwen3-ASR issues]

- **#16 / #163 (mixed language).** With `language=None` an audio that starts in Chinese and turns to English was output "completely in English, Chinese misrecognized as phonetically similar English words"; forcing `Chinese` made English words come out translated into Chinese. One workaround thread says "leave language unset (Auto)". Expect the **same class of failure for Korean+English**; no Korean-English evaluation of Qwen3-ASR was found anywhere (a Korean app's evaluation issue, woosublee/quill #287, is still an unexecuted plan).
- **#186 (hotwords).** Context string leaks into the transcript ("partly or fully mixed in"), weak/near-silent audio gets transcribed *as* hotwords; a user found that prefixing "Technical terms: " helps somewhat; another reproduced hotword-list output when the audio contains only one term. Streaming 0.6B variant has the same (#140).
  -> Mitigation: VAD must drop silent chunks; drop any output segment whose text is mostly vocabulary words; A/B `context` vs none.
- **#129 (repetition).** Runaway "I think. I think..." ~1 in 10 files on one user's vLLM run; **#165** noise/echo transcribed as fillers; **#37** quality drops on long audio; **#213** (above) loops on non-FA2 transformers path.
  mlx-qwen3-asr has built-in mitigations (30 s chunks at low-energy points, duration-aware token cap, repetition collapse, `finish_reason`/`truncated`).
- **Quantization hurts Korean much more than English.** soniqo's FLEURS multilingual table (Qwen3 4-bit vs 8-bit): Korean WER **19.95 vs 6.89**, Japanese CER 16.11 vs 8.64, English 6.57 vs 5.64 (page does not state which size). [W] -> **use bf16/fp16 or 8-bit, never 4-bit/5-bit** for Korean. mlx-qwen3-asr's own 4-bit validation covers English only.
- **Chunking.** zkaelxz measured Qwen3-1.7B at **3.34 % CER on whole utterances but 4.82 % on VAD spans** (batch 1): over-fragmenting hurts. Merge VAD spans into ~15-28 s chunks at natural pauses.
- No Korean-specific timestamp need: use chunk start times; forced aligner (Korean supported, needs `soynlp`) only if sub-chunk times are ever wanted.

---

## 5. Code-switching: what we actually know

| Evidence | Finding | Source |
|---|---|---|
| HiKE benchmark (Korean-English, 2.2 h, 13 bilingual speakers) | Best open model tested, Whisper-Large: MER 26.1 / PIER 36.0 vs mono 3.2-4.4; every model degrades 3-13x; word- and phrase-level switches worst; common errors = phonetic transcription across scripts, instruction-following failure (multitask LLMs), hallucination | arXiv 2509.24613 [W] |
| Same paper, fine-tuning | Whisper-Medium + natural intra-sentence CS data: MER 31.3 -> 9.0; even synthetic concatenated mono data helps (22.1) | arXiv 2509.24613 [W] |
| Qwen3-ASR | no Korean-English test anywhere; Chinese-English reports show auto-LID collapse | issues #16/#163 [W] |
| Cohere Transcribe | vendor states inconsistent on code-switched audio, no LID | HF card [S] |
| VibeVoice-ASR | claims native code-switching, no independent Korean number | vendor card [S] |
| Whisper family | works per 30 s window with one language token; the language token decides script of English words | mlx-whisper source [S] |

Implications: (1) an A/B on **audio of the intended kind** is the only trustworthy test; (2) try per-chunk constrained LID vs forced language;
(3) keep the vocabulary alias post-processing from SPEC 7.2 (English terms transliterated in Hangul such as "에프디에이" are cheap to alias);
(4) HiKE (`thetaone-ai/HiKE` on HF datasets, GitHub `ThetaOne-AI/HiKE`, Apache-2.0) is a small public code-switch test set that can be used as an extra local check (not downloaded here; it contains other people's speech but is explicitly public).

---

## 6. Korean-specialized ASR and Whisper Korean fine-tunes

| Repo [S] | Base | Data / claim | Size / licence | MLX? | Verdict |
|---|---|---|---|---|---|
| `ghost613/whisper-large-v3-turbo-korean` | **large-v3-turbo** | Zeroth-Korean (CC-BY-4.0, 206 h of read speech); held-out test CER 2.06 / WER 4.89 (from 7.58 / 26.75); card says "models did not converge" | 3.24 GB fp32 safetensors; **no licence field** (derives from MIT turbo) | no (needs torch + mlx-examples `convert.py`) | read-speech-only data, no English guard, no MLX: skip |
| `ghost613/faster-whisper-large-v3-turbo-korean` | same | CT2 build | 3.24 GB | CPU only on Mac | skip |
| `o0dimplz0o/Whisper-Large-v3-turbo-STT-Zeroth-KO-v2` | large-v3-turbo | "still fine-tuning": eval CER 6.6 %, WER 19.9 %; repo has training checkpoints (50 GB) | no licence | no | skip |
| `imTak/whisper_large_v3_turbo_Korean2`, `royshilkrot/whisper-large-v3-turbo-korean-ggml` | turbo | undocumented numbers | MIT / Apache-2.0 tags | ggml only | skip |
| `seastar105/whisper-medium-komixv2`, `...-ko-zeroth` | medium | Zeroth test WER 3.64 (read speech) | 3 GB | no | older/smaller base: skip |
| `gcasey2/whisper-large-v3-ko-en`(`-v2`) | **large-v3** | "Korean/English"; v1 eval WER 198 (broken), v2 WER 8.27; no dataset documented | Apache-2.0 | no | undocumented: skip |
| `TeamUNIVA/qwen3_asr_1.7b_ko_beta` | **Qwen3-ASR-1.7B** | fine-tuned on Korean speech; self-reported CER total 6.86 -> 5.37 (ClovaCall 4.48->2.93, KsponSpeech 8.65->6.70, Zeroth 2.64->2.30, CV-ko 7.19->6.28, FLEURS 1.42->1.38); LibriSpeech WER 2.50 -> 2.46; hand-reviewed eval sets | Apache-2.0, 4.70 GB BF16, "beta", third party | likely loads in `mlx-qwen3-asr` (same `thinker.*` keys, config parses); **unverified** | **the only Korean fine-tune with a documented English check** |
| `kresnik/wav2vec2-large-xlsr-korean`, KsponSpeech ESPnet/SpeechBrain models, `k2-fsa` sherpa-onnx Korean zipformer (KsponSpeech, 249 MB encoder fp32) | - | Korean-only CTC/transducer, no English | various | CPU | cannot emit Latin terms: skip |

**Critical caveat (literature).** *Building robust Korean speech recognition model by fine-tuning large pretrained model* (Phonetics and Speech Sciences 15(3), 2023) fine-tuned Whisper on ~1,000 h KsponSpeech:
Whisper-medium CER 11.94 -> 7.61 on kspon-eval-clean, but **LibriSpeech WER 6.74 -> 57.56**. Korean-only fine-tunes forget English, the opposite of what mixed-language meetings need. [W]
Any Korean fine-tune used for this purpose must be checked on English and mixed audio; the Qwen ko_beta claims no English loss but only on LibriSpeech.
Datasets: Zeroth-Korean is CC-BY-4.0 (attribution), KsponSpeech/AIHub data have their own terms; irrelevant for personal local use but worth knowing.

Commercial Korean ASR (Naver CLOVA, RTZR/VITO, Daglo) is API-only: out of scope.

---

## 7. Everything else surveyed

### NVIDIA
- `nvidia/parakeet-tdt-0.6b-v3` (cc-by-4.0, 25 European languages, no Korean) [S card]; MLX port `mlx-community/parakeet-tdt-0.6b-v3` 2.51 GB; English avg 4.86, 6076x RTFx on H200; great for English but cannot be the single model.
- `nvidia/canary-1b-v2` (25 European langs), `nvidia/canary-qwen-2.5b` (English only, avg 4.43, long-form 11.20). **No Korean.** NeMo toolkit dependency is heavy.
- `nvidia/nemotron-3.5-asr-streaming-0.6b` (Sept 2026, 40 locales, **Korean yes**, cache-aware streaming RNNT, language-ID prompt; OpenMDW/NVIDIA open licence): NVIDIA card reports Korean CER 7.1-8.3 depending on chunk size/condition; handy 8.89; English avg 7.88 (AMI 13.43, Earnings22 15.3). MLX `mlx-community/nemotron-3.5-asr-streaming-0.6b` 1.28 GB. Streaming-tuned, worse than Whisper offline. Skip.

### Mistral Voxtral
- Voxtral-Mini-3B-2507 / Small-24B: languages en, fr, de, es, it, pt, nl, hi: **no Korean**. [S]
- `mistralai/Voxtral-Mini-4B-Realtime-2602` (13 langs incl. ko, Apache-2.0, 17.7 GB repo; MLX fp16 8.89 GB, 4-bit 3.15 GB): card FLEURS Korean 15.74 % at 480 ms, 14.3 % at 2.4 s (offline Voxtral Transcribe 2.0 API: 12.29 %); handy CER 5.27; English avg 6.46. Official runtime vLLM/CUDA; MLX via mlx-audio/voxmlx. Not competitive for accuracy-first offline; skip.

### IBM Granite-Speech
- 4.0-1b, 4.1-2b (+plus, +nar), 5.0-470m-turboctc: English / fr / de / es / pt (+ja for 4.1-2b); **no Korean**; 5.0 TurboCTC is English-only (0.95 GB, Apache-2.0; also a `-nc` NC-licence variant). Best English leaderboard accuracy (4.1-2b avg 4.62; keyword biasing "Keywords: ..." in prompt). Possible English-only specialist, but the other side of a call is not guaranteed to speak English. Skip. [S]

### SenseVoice / Fun-ASR / GLM / FireRed
- SenseVoice-Small (`FunAudioLLM/SenseVoiceSmall` 0.94 GB, licence "other"; zh/en/ja/ko/yue; sherpa-onnx & mlx-audio): Korean FLEURS CER 8.27, HiKE MER 32.5 vs Whisper-Large 26.1. Fast (32x on GPU in handy table). Not accurate enough.
- Fun-ASR-MLT-Nano-2512 (800M, 31 languages incl. Korean; `mlx-community/Fun-ASR-MLT-Nano-2512-fp16` 1.99 GB / `-8bit` 1.56 GB; hotwords via funasr API; model card gives no MLT-specific results): handy Korean CER 5.20 (better than turbo 5.24, behind large-v3 4.89). Worth a footnote, not a slot.
- GLM-ASR-Nano-2512: zh/en only. FireRedASR2 (AED 1.18B, LLM 8B+): Mandarin/dialects/English only. **No Korean.** [S]

### Cohere Transcribe 03-2026
`CohereLabs/cohere-transcribe-03-2026` (2B conformer, Apache-2.0 but **gated=auto**: needs an HF account/token to accept; 4.13 GB). 14 languages incl. Korean. Open ASR avg 4.67, long-form 9.73; Korean FLEURS CER 6.57 (handy). Card limitations: no LID, "inconsistent performance on code-switched audio", "eager to transcribe, even non-speech sounds", no timestamps. Runs in `mlx-audio` (`cohere_asr`). Skip (gating + code-switching).

### Google Gemma 4 / Microsoft Phi-4-multimodal / Gemma-3n
- Gemma 4 E2B/E4B/12B take audio (Apache-2.0; E4B 16 GB bf16): ASR via prompt, **audio limited to 30 s**, generic FLEURS aggregate (0.08 for E4B) but no Korean number and no dedicated MLX STT path; LLM-style hallucination/instruction-following risks (HiKE: Gemma-3n MER 76.6). Skip.
- Phi-4-multimodal audio languages: en, zh, de, fr, it, ja, es, pt (**no Korean**). [S]

### Kyutai
`kyutai/stt-2.6b-en` (English), `stt-1b-en_fr`: **no Korean**. [S]

### Other 2026 releases surveyed
- **VibeVoice-ASR** (Microsoft, Jan 2026; MIT; 9B; `microsoft/VibeVoice-ASR` 17.35 GB; MLX `mlx-community/VibeVoice-ASR-{bf16 16.66, 8bit 9.52, 4bit 5.71} GB`; also `microsoft/VibeVoice-ASR-Streaming-1.5B` 5.65 GB, 10 languages): 60-min single pass, speaker + timestamps, **hotwords**, "native code-switching". MLC-Challenge Korean WER 9.65 / cpWER 15.35 (vendor doc); Open ASR (HF port) English avg 5.58, AMI 12.02. On a laptop with enough unified memory it fits at 4/8-bit, but decoding a 9B model at the ~134 GB/s memory bandwidth measured in section 2.1 is slow (back-of-envelope >= 0.5 RTF) and 4-bit quantization already proved harmful to Korean for Qwen. **Heavy/complex: stretch candidate only.**
- **MOSS-Transcribe-Diarize 0.9B** (OpenMOSS, Jul 2026, Apache-2.0, 1.83 GB; won 2nd MLC-SLM challenge incl. Korean; 90 min single pass; hotword prompt, Chinese-language prompt template; `trust_remote_code`; only community MLX conversions with tiny download counts). No Korean number published in the card; diarization is not needed for this use. Watch list.
- **ARK-ASR-3B** (AutoArk, 19 languages incl. Korean, Apache-2.0, 8.1 GB, custom remote code, no MLX, no Korean figures; English avg 4.47). Skip.
- Omnilingual ASR (Meta, 1,600 languages; CTC-1B 3.9 GB; LLM-7B gated): Open ASR avg 6.4 for the 7B; no Korean-specific evidence. Skip. Seamless-M4T-v2 (CC-BY-NC, 30 GB): skip.
- Moonshine ko (`moonshine-base-ko` tiny/base, MIT): FLEURS CER 8.1-9.0, edge models. Skip.
- `MedASR` (Google, English medical dictation, in mlx-audio): English-only, does not address Korean. Skip.

### Minimal recipes for the non-shortlisted Korean-capable candidates (all via `mlx-audio` 0.5.8; patterns from its per-model READMEs [S], **not executed** because they need >100 MB weights)

```python
from mlx_audio.stt import load                      # `pip install "mlx-audio[stt]"`; import verified [V]
# VibeVoice-ASR (heavy, 5.71 GB at 4-bit): hotwords supported, whole-file long-form
m = load("mlx-community/VibeVoice-ASR-4bit");  r = m.generate("meeting.wav", hotwords=["Acme", "AcmeScan-CXR", "510(k)"])
# Cohere Transcribe (HF-gated; needs accepted licence + token): explicit language required, no LID
m = load("CohereLabs/cohere-transcribe-03-2026");  r = m.generate("a.wav", language="ko")
# SenseVoice-Small (0.94 GB): language="auto" supported, emits language tag
m = load("mlx-community/SenseVoiceSmall");  r = m.generate("a.wav", language="auto", use_itn=True)
# Fun-ASR-MLT-Nano (1.99 GB fp16): README documents hint codes zh/en/ja + "auto"; pass language="auto" for Korean
m = load("mlx-community/Fun-ASR-MLT-Nano-2512-fp16");  r = m.generate("a.wav", language="auto", hotwords=["Acme"])
# Nemotron 3.5 streaming (1.28 GB): language keys like "ko-KR"
m = load("mlx-community/nemotron-3.5-asr-streaming-0.6b");  r = m.generate("a.wav", language="ko-KR")
print(r.text)
```
Generic CLI (flags verified with `--help` in 0.5.8 [V]): `python -m mlx_audio.stt.generate --model <repo> --audio a.wav --output-path out --format txt [--language ko] [--context "term1, term2"] [--chunk-duration 30]`.

---

## 8. A benchmark plan (what `scripts/bench_asr.py` implements)

**Models:** A, B, optionally D from the shortlist (C is not downloaded by the project scripts; 7.2 GB for A+B).

```bash
# one venv for both runtimes (verified co-installable)
python3.13 -m venv venv && venv/bin/pip install mlx-whisper mlx-qwen3-asr && venv/bin/pip uninstall -y torch
venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
for r in ["mlx-community/whisper-large-v3-mlx", "mlx-community/Qwen3-ASR-1.7B-bf16"]:   # + D after announcing sizes
    print(snapshot_download(r))
PY
```
Backend routing suggestion for `ASR_MODEL`: repo id contains `whisper` -> `mlx_whisper`; contains `Qwen3-ASR` or `qwen3_asr` -> `mlx_qwen3_asr`.
Keep the interface "chunk float32 16 kHz in, `{language, segments|text}` out"; both recipes in sections 3.1 and 4.2 do that.

**Run matrix per 10-20 min of real audio (the microphone track and the remote track separately):**

| Axis | Whisper (A/D) | Qwen (B) |
|---|---|---|
| Language | per-chunk constrained ko/en LID; forced `ko` (microphone) / `en` (remote) | `language=None`; forced `Korean` / `English` |
| Vocabulary | none / bare Latin list (120 tok) / Korean sentence (87 tok), terms last | no context / `"Technical terms: ..."` |
| Chunking | VAD spans merged to 15-28 s at pauses, one `transcribe()` per chunk | same chunks (do not feed tiny spans) |

**Record per run:** wall time and RTF; Whisper `avg_logprob / compression_ratio / no_speech_prob` per segment; Qwen `finish_reason`, `truncated`; counts of
dropped phantom phrases, repetition collapses, empty or vocabulary-only segments; vocabulary-term hit rate; numbers/prices/dates correctness; omitted sentences; Hangul-transliterated English terms.
If B/C are close, run the code-switch check on HiKE or on `say`-synthesized mixed sentences (macOS `say -v "Flo (Korean (South Korea))"` and `"Eddy (English (US))"` exist here).

**Decision rule:** keep Whisper large-v3 unless a challenger is clearly better on >= 2/3 of the reviewed items **and** shows no loop / hallucination / language-collapse episodes **and** transcribes a 60-min meeting in under ~15 min. If Qwen wins English but loses mixed Korean, either stay on Whisper or consider per-track model selection (remote track = Qwen, microphone track = Whisper), at the cost of a config change in SPEC section 3.

---

## 9. Heavy or complex dependencies to flag

| Item | Why it is a problem |
|---|---|
| `mlx-whisper` pulling **torch** | +550 MB; not needed at runtime; uninstall after pip install [V] |
| `qwen-asr` official package | pins `transformers==4.57.6`, gradio, flask, sox; encoder-window bug on non-FA2 path (#213) [S/W] |
| `mlx-audio` | transformers>=5.14, huggingface_hub>=1.0 (552 MB venv); fine as fallback runner, heavier than `mlx-qwen3-asr` |
| `mlx-qwen3-asr` | single-maintainer project (221 stars); 735 tests, quick fixes, but bus-factor 1 |
| VibeVoice-ASR (9B), Gemma 4, Voxtral-4B fp16, Canary/NeMo, ARK-ASR remote code, MOSS remote code | size (5.7-17 GB), CUDA-first runtimes, `trust_remote_code`, or NeMo |
| `transcribe.cpp`, whisper.cpp builds | need cmake (not installed; do not install) |
| Cohere Transcribe | HF gating needs an account token |
| Korean Whisper fine-tune conversion to MLX | needs torch + mlx-examples `convert.py` |

---

## 10. Open questions and what only a live test can answer

- Real accuracy on mixed ko/en meeting audio for A vs B vs C (no public Korean-English meeting benchmark covers Qwen3-ASR).
- Whether `TeamUNIVA/qwen3_asr_1.7b_ko_beta` actually loads and decodes in `mlx-qwen3-asr` (config + key names are compatible).
- Whether hotword/prompt leakage appears with large-v3 on Korean (only tested qualitatively on tiny).
- Actual RTF on a Mac under load (a video call and a browser running) and with temperature fallbacks active.
- Transformers-MPS path for Qwen3-ASR-hf (not tested; skip unless MLX routes fail).
- Echo: the `mic` track may contain remote speech from the speakers; Qwen issue #165 shows non-speech/echo turning into filler words.

---

## Sources

- Qwen3-ASR HF card: https://huggingface.co/Qwen/Qwen3-ASR-1.7B ; HF-native card https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf ; technical report https://arxiv.org/abs/2601.21337 (HTML https://arxiv.org/html/2601.21337)
- QwenLM/Qwen3-ASR issues: https://github.com/QwenLM/Qwen3-ASR/issues/16 , /163 , /186 , /129 , /165 , /213 , /140
- mlx-qwen3-asr: https://github.com/moona3k/mlx-qwen3-asr , https://pypi.org/project/mlx-qwen3-asr/
- mlx-audio: https://github.com/Blaizzy/mlx-audio (STT README, `mlx_audio/stt/models/qwen3_asr/`), https://pypi.org/project/mlx-audio/ ; issues #928, #985
- mlx-whisper: https://pypi.org/project/mlx-whisper/ , https://github.com/ml-explore/mlx-examples/tree/main/whisper
- Open ASR Leaderboard: https://huggingface.co/spaces/hf-audio/open_asr_leaderboard ; data https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results (`english_short_latest.csv`), https://huggingface.co/datasets/hf-audio/leaderboard_longform ; paper https://arxiv.org/abs/2510.06961
- Korean FLEURS benchmark (handy.computer): https://models.handy.computer/languages/ko ; transcribe.cpp https://github.com/handy-computer/transcribe.cpp
- zkaelxz Korean benchmark: https://github.com/zkaelxz/U00/pull/740
- whispernotes Qwen3-ASR vs Whisper (M5): https://whispernotes.app/blog/qwen3-asr-vs-whisper
- soniqo benchmarks (quantization, Korean 4-bit vs 8-bit): https://soniqo.audio/benchmarks
- vllm-mlx audio benchmarks: https://vllm-mlx.is-a.dev/benchmarks/audio/ ; whisper.cpp vs mlx_whisper: https://notes.billmill.org/dev_blog/2026/01/updated_my_mlx_whisper_vs._whisper.cpp_benchmark.html
- HiKE (Korean-English code-switching): https://arxiv.org/abs/2509.24613 , https://github.com/ThetaOne-AI/HiKE , https://huggingface.co/datasets/thetaone-ai/HiKE
- Korean Whisper fine-tune literature: https://www.eksss.org/archive/view_article?pid=pss-15-3-75 ; ACL Findings 2025 (unparsed): https://aclanthology.org/2025.findings-emnlp.561.pdf
- Whisper hallucination: https://github.com/openai/whisper/discussions/1762 , https://yage.ai/share/whisper-repetition-hallucination-en-20260526.html , https://doc.scenemaker.solbox.com/en/blog/4 , https://github.com/SYSTRAN/faster-whisper/discussions/1442
- Korean fine-tune cards: https://huggingface.co/ghost613/whisper-large-v3-turbo-korean , https://huggingface.co/TeamUNIVA/qwen3_asr_1.7b_ko_beta
- Other model cards: https://huggingface.co/microsoft/VibeVoice-ASR (+ https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr.md), https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize , https://huggingface.co/CohereLabs/cohere-transcribe-03-2026 , https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b , https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 , https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602 , https://huggingface.co/ibm-granite/granite-speech-4.1-2b , https://huggingface.co/FunAudioLLM/Fun-ASR-MLT-Nano-2512 , https://huggingface.co/FunAudioLLM/SenseVoiceSmall , https://huggingface.co/google/gemma-4-E4B-it , https://huggingface.co/AutoArk-AI/ARK-ASR-3B
- sherpa-onnx Korean zipformer: https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/zipformer-transducer-models.html
- HF API used for every repo id, size and licence in this file: `https://huggingface.co/api/models/<id>?blobs=true` (queried 2026-10-07).

### Scope of the experiments
The experiment scripts and throw-away environments are not part of this repository. Only `mlx-community/whisper-tiny` (75 MB) was added to the Hugging Face cache; the synthetic clips were made with the macOS `say` command.
