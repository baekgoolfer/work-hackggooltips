# Third-party notices

Catch Everything is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)). This file lists the third-party software, models and services it uses and the licence each one is published under.

This repository contains none of the components below. The Python packages are downloaded from PyPI, and the speech and VAD models from Hugging Face and GitHub, onto your own machine when you run `scripts/setup_python.sh` or `scripts/install.sh`. Each component stays under its own licence. Exact pins are in `pipeline/requirements*.txt` and `scripts/setup_python.sh`. Licences were read from each project's PyPI metadata, Hugging Face model metadata and LICENSE files on 2026-10-16; the licence that ships inside the version you install is authoritative. Re-check this list whenever a pin changes.

If you redistribute a built app, a virtualenv, a `.pkg` (`make pkg`) or model weights, you take on the obligations of the licences below: notice files for the MIT/BSD/Apache components, MPL-2.0 source availability for certifi and tqdm, the LGPL / GPL-with-runtime-exception terms of the runtime libraries inside the numpy and scipy wheels, and NVIDIA's terms for CUDA libraries. The project's own release assets contain only this repository's own code: the source and a build of the app that is signed ad-hoc, is not notarized and links only Apple system frameworks. Python packages, virtualenvs and model weights are never distributed by this project.

## 1. Python packages of the standard install

`pipeline/requirements.lock.txt`, 29 pins, installed with `pip install --no-deps`.

| Component | Version | Licence | URL |
|---|---|---|---|
| anyio | 4.15.1 | MIT | https://github.com/agronholm/anyio |
| certifi | 2026.7.22 | MPL-2.0 | https://github.com/certifi/python-certifi |
| charset-normalizer | 3.5.2 | MIT | https://github.com/jawah/charset_normalizer |
| click | 8.5.0 | BSD-3-Clause | https://github.com/pallets/click/ |
| filelock | 4.0.12 | MIT | https://github.com/tox-dev/py-filelock |
| fsspec | 2026.9.0 | BSD-3-Clause | https://github.com/fsspec/filesystem_spec |
| h11 | 0.16.0 | MIT | https://github.com/python-hyper/h11 |
| hf-xet | 1.7.0 | Apache-2.0 | https://github.com/huggingface/xet-core |
| httpcore2 | 2.13.1 | BSD-3-Clause | https://github.com/pydantic/httpx2 |
| httpx2 | 2.13.1 | BSD-3-Clause | https://github.com/pydantic/httpx2 |
| huggingface_hub | 2.1.1 | Apache-2.0 | https://github.com/huggingface/huggingface_hub |
| idna | 3.20 | BSD-3-Clause | https://github.com/kjd/idna |
| llvmlite | 0.50.0 | BSD-2-Clause AND Apache-2.0 WITH LLVM-exception | https://github.com/numba/llvmlite |
| mlx | 0.32.3 | MIT (Copyright 2023 Apple Inc.) | https://github.com/ml-explore/mlx |
| mlx-metal | 0.32.3 | MIT | https://github.com/ml-explore/mlx |
| mlx-whisper | 0.4.3 | MIT | https://github.com/ml-explore/mlx-examples |
| more-itertools | 11.1.0 | MIT | https://github.com/more-itertools/more-itertools |
| numba | 0.68.0 | BSD (PyPI: "BSD", classifier BSD License) | https://numba.pydata.org |
| numpy | 2.5.3 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 (binary wheels also bundle OpenBLAS and runtime libraries, see below) | https://github.com/numpy/numpy |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause | https://github.com/pypa/packaging |
| PyYAML | 6.0.3 | MIT | https://github.com/yaml/pyyaml |
| regex | 2026.9.29 | Apache-2.0 AND CNRI-Python | https://github.com/mrabarnett/mrab-regex |
| requests | 2.34.2 | Apache-2.0 | https://github.com/psf/requests |
| scipy | 1.18.1 | BSD-3-Clause (SciPy licence; wheels bundle OpenBLAS BSD-3-Clause, LAPACK BSD-3-Clause-Open-MPI, GCC runtime libgfortran/libgcc GPL-3.0-or-later WITH GCC-exception-3.1, libquadmath LGPL-2.1-or-later) | https://github.com/scipy/scipy |
| tiktoken | 0.14.0 | MIT (Copyright 2022 OpenAI, Shantanu Jain) | https://github.com/openai/tiktoken |
| tqdm | 4.70.1 | MPL-2.0 AND MIT | https://github.com/tqdm/tqdm |
| truststore | 0.10.4 | MIT | https://github.com/sethmlarson/truststore |
| typing_extensions | 4.16.0 | PSF-2.0 | https://github.com/python/typing_extensions |
| urllib3 | 2.8.0 | MIT | https://github.com/urllib3/urllib3 |

Notes.

- `pip install --no-deps` skips torch, which the mlx-whisper 0.4.3 metadata lists as a dependency. It is not installed.
- numpy 2.5.3 and truststore 0.10.4 are also the only packages of the client-only venv (`pipeline/requirements.client.txt`).
- The mlx-whisper package ships small data files (tokenizer vocabularies and a mel filter bank under `mlx_whisper/assets`) that come from OpenAI Whisper (MIT, Copyright 2022 OpenAI). They are covered by mlx-whisper's MIT licence.
- certifi and tqdm are used unmodified and are not copied into this repository. MPL-2.0 is file-level copyleft: it applies to modifications of those files and to redistributing them.
- The numpy and scipy binary wheels bundle OpenBLAS, LAPACK and the GCC runtime libraries listed above. That list comes from PyPI metadata; the wheels were not opened for this file.

## 2. Speech-to-text models

Downloaded from Hugging Face at install time with a pinned revision, never stored in this repository.

| Model | Revision | Licence as published | Source |
|---|---|---|---|
| mlx-community/whisper-large-v3-mlx (default `ASR_MODEL`) | 49e6aa286ad60c14352c404340ded53710378a11 | MIT (Hugging Face model metadata). The repository is an MLX build of OpenAI's whisper-large-v3 (its card names no base model). OpenAI's Whisper repository states that code and model weights are released under the MIT License (Copyright 2022 OpenAI); OpenAI's own Hugging Face card for openai/whisper-large-v3 says Apache-2.0. Both are permissive. | https://huggingface.co/mlx-community/whisper-large-v3-mlx , https://github.com/openai/whisper |
| mlx-community/whisper-large-v3-turbo (optional, `scripts/setup_python.sh --download`) | a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb | the repository carries no licence metadata; the upstream openai/whisper-large-v3-turbo is MIT | https://huggingface.co/mlx-community/whisper-large-v3-turbo |

The training data of these models is not documented by their publishers. The licences above cover the weights as published and say nothing about training-data rights.

## 3. Optional Silero VAD (`scripts/setup_python.sh --with-silero`)

| Component | Version | Licence | URL |
|---|---|---|---|
| silero_vad.onnx (model file, 2,327,524 bytes, sha256 1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3) | silero-vad v6.2.3 | MIT, Copyright (c) 2020-present Silero Team | https://github.com/snakers4/silero-vad/blob/v6.2.3/LICENSE |
| silero-vad wheel (fallback source of the same file) | 6.2.3 | MIT | https://pypi.org/project/silero-vad/6.2.3/ |
| onnxruntime | 1.30.0 | MIT | https://onnxruntime.ai |
| flatbuffers | 25.12.19 | Apache-2.0 | https://google.github.io/flatbuffers/ |
| protobuf | 7.36.2 | BSD-3-Clause | https://developers.google.com/protocol-buffers/ |

The Silero model is fetched from raw.githubusercontent.com at the v6.2.3 tag and checked against a pinned sha256. The Silero wrapper in `pipeline/mcap/vad.py` is an independent numpy and onnxruntime implementation that follows the input, state and context layout and the threshold hysteresis of the silero-vad reference code (MIT). onnxruntime contains a Microsoft telemetry client; this project sets `ORT_DISABLE_TELEMETRY=1`.

The Silero README badge carries the alt text "CC BY-NC 4.0" while the badge image, the README text, the LICENSE file at the tag and PyPI all say MIT. That is an upstream typo, not a different licence.

## 4. Benchmark only, never in the production venv

`pipeline/requirements-qwen-bench.txt`, `scripts/setup_python.sh --with-qwen-bench`. The model is downloaded with `scripts/setup_python.sh --download qwen3-asr-1.7b`.

| Component | Version / revision | Licence | URL |
|---|---|---|---|
| mlx-qwen3-asr | 0.4.4 | Apache-2.0 | https://github.com/moona3k/mlx-qwen3-asr |
| mlx-community/Qwen3-ASR-1.7B-bf16 | e1f6c266914abc5a46e8756e02580f834a6cf8a7 | Apache-2.0 (Hugging Face metadata) | https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16 |
| Qwen/Qwen3-ASR-1.7B (upstream of the above; not downloaded by the scripts) | n/a | Apache-2.0 (Hugging Face metadata; QwenLM/Qwen3-ASR repository Apache-2.0) | https://huggingface.co/Qwen/Qwen3-ASR-1.7B |

## 5. Optional Linux ASR server (organisation mode)

`pipeline/requirements-server.txt`. Never installed on the Mac client.

| Component | Version | Licence | URL |
|---|---|---|---|
| faster-whisper | 1.1.1 | MIT | https://github.com/SYSTRAN/faster-whisper |
| CTranslate2 | 4.5.0 | MIT (Linux wheels bundle native math libraries such as Intel OpenMP/oneDNN; not inspected) | https://github.com/OpenNMT/CTranslate2 |
| numpy | 1.26.4 | BSD-3-Clause (binary wheels bundle OpenBLAS BSD-3-Clause, LAPACK BSD-3-Clause-Attribution, libgfortran/libgcc GPL-3.0 with GCC exception, libquadmath LGPL-2.1-or-later) | https://numpy.org |
| huggingface-hub, tokenizers (pulled in by faster-whisper, not pinned) | resolved at install time | Apache-2.0 | https://github.com/huggingface/tokenizers |
| onnxruntime (pulled in, not pinned) | resolved at install time | MIT | https://onnxruntime.ai |
| av / PyAV (pulled in, not pinned) | resolved at install time | BSD-3-Clause for PyAV. Its binary wheels bundle FFmpeg libraries whose licence (LGPL or GPL, depending on the build) is not stated by the project pages. **Unverified:** check the licence files inside the wheel you install. | https://github.com/PyAV-Org/PyAV |
| nvidia-cublas-cu12, nvidia-cudnn-cu12 (optional, commented out in the requirements file) | 12.9.2.10 / 9.27.0.42 at the time of the licence check | NVIDIA proprietary licences (cuBLAS: LicenseRef-NVIDIA-Proprietary on PyPI; cuDNN: Software License Agreement, https://docs.nvidia.com/deeplearning/cudnn/backend/latest/reference/eula.html). Not open source. You accept NVIDIA's terms yourself when you install them. Never bundle them. | https://developer.nvidia.com/cuda-zone |
| Systran/faster-whisper-{tiny,base,small,medium,large-v2,large-v3}, Systran/faster-distil-whisper-large-v3 | model names in `pipeline/mcap/asr_faster_whisper.py` | MIT (Hugging Face metadata) | https://huggingface.co/Systran |

These are the only short model names the server code knows (`MODEL_REPOS` in `pipeline/mcap/asr_faster_whisper.py`). The server never downloads a model by itself: the operator fetches one once with `python -m mcap.asr_faster_whisper fetch --yes`. A model you pass by repository id or directory (for example a turbo build) is your own choice and is not covered by this file; check its licence first.

## 6. Apple platform (not redistributed)

The app links only Apple system frameworks that ship with macOS: Foundation, Darwin, CoreAudio, AudioToolbox, AVFoundation, AppKit, UserNotifications, CryptoKit and CoreServices. It is built with `swiftc` from the Xcode Command Line Tools and signed with `codesign`. The pipeline uses `/usr/bin/afconvert` (the AAC encoder of macOS) and the build uses `iconutil`, `plutil` and `ditto`. All of these are used under Apple's licence terms for macOS and the developer tools. None is bundled. The Python interpreter (python.org or Homebrew python@3.13) is installed by you under the Python Software Foundation licence and is not redistributed. There are no Swift Package Manager dependencies and no vendored code.

## 7. Services you configure yourself

These are not components of this repository. Your own accounts and their terms apply.

- **Anthropic.** The optional note-writing step runs the `claude` command-line tool (Claude Code) that you install yourself, or calls the Anthropic API with your own key. See "Anthropic and Claude" in the [README](README.md). Terms: https://www.anthropic.com/legal/consumer-terms , https://www.anthropic.com/legal/commercial-terms , https://www.anthropic.com/legal/aup
- **Google Drive for desktop.** The archive step writes ordinary files into a local folder you choose (which may be a Drive sync folder). No Google API is called by this project.
- **Google Calendar** through the Google Calendar connector of your claude.ai account (optional `CALENDAR_LOOKUP`). The project never handles Google credentials.
- **Hugging Face Hub** (model download, https://huggingface.co/terms-of-service), **PyPI** and **GitHub** (the Silero download).
- **Microsoft Azure AI Speech** (optional `ASR_ENGINE=azure`, organisation mode) and your own `mcap-asr` server (optional `ASR_ENGINE=remote`, organisation mode). You supply the account or server and accept its terms.
- **Zoom, Microsoft Teams, Google Meet and Google Chrome** are only observed through macOS process and audio state and, for Meet, the address and title of Chrome tabs through Apple Events. No code, SDK or logo of theirs is included.

## 8. Original material in this repository

The application icon (`app/Resources/AppIcon.icns`) is generated by `scripts/make_icon.swift` with CoreGraphics and ImageIO. It contains no third-party artwork and is covered by the project licence. The repository contains no fonts, photographs, sounds or other third-party media.

## 9. Trademarks

Zoom, Microsoft Teams, Azure, Google Meet, Google Drive, Google Calendar, Google Chrome, Claude, Claude Code, Anthropic, macOS, Apple, Core Audio, Whisper, OpenAI, Qwen, Hugging Face, NVIDIA and CUDA are trademarks of their respective owners and are used here only to say what this software works with. This project is not affiliated with, endorsed by or sponsored by any of them.
