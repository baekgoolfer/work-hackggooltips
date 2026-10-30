# ASR 벤치마크 키트: 다른 Apple Silicon Mac에서 `scripts/bench_asr.py` 돌리기 (선택 기능)

**Intel Mac은 쓸 수 없다** (MLX가 설치되지 않는다). 이 키트는 ASR 벤치마크를 **다른 Apple Silicon Mac에서** 돌리고 싶을 때만 쓰는 선택 기능(개발자 도구)이다.
같은 Mac에서 직접 비교하려면 키트가 필요 없다: `scripts/setup_python.sh --with-qwen-bench --download qwen3-asr-1.7b`가 **별도 벤치 venv**(`SUPPORT_DIR/bench-venv`)를 만들고,
`"$HOME/Library/Application Support/MeetingCapture/bench-venv/bin/python" scripts/bench_asr.py ...`로 아래 5절과 같은 명령을 돌리면 된다 (운영 venv에는 Qwen 패키지가 들어가지 않는다).

> English summary: `make bench-kit` packs `scripts/bench_asr.py` and what it needs into a tarball so that you can compare speech models on another Apple silicon Mac. The kit holds no recording, no reference transcript and no result: you bring your own audio, and nothing in this repository says which model is better for you. The rest of this page is in Korean.

이 키트에는 비교용 녹음, 정답 전사본, 결과가 들어 있지 않다. 사용자 본인의 녹음으로 직접 비교하는 도구다.

**이 비교는 어떤 macOS 권한도 필요 없고 라이브 테스트(`docs/LIVE_TEST.md`)와 독립적이다.** 아직 실제 회의 오디오로 모델을 비교한 적이 없으면 라이브 테스트 전에, 내 실제 회의 녹음 10~20분으로 먼저 해 볼 만하다. 결과는 모델 선택과 `ASR_LANGUAGE`/`ASR_LANGUAGES` 결정에 쓴다 (예: 일본어 회의가 있으면 `ASR_LANGUAGES=ko,en,ja`). 벤치마크 전사본과 오디오는 이 Mac 밖으로 보내지 않는다.

메인 Mac은 회의 중에 녹음과 전사를 같이 돌려야 해서 큰 모델을 여러 개 비교하기엔 부담스러울 수 있다. 이 키트는 **프로젝트 나머지(Swift 앱, 노트 단계, LaunchAgent)
없이** 벤치마크 스크립트만 다른 Mac으로 옮겨 돌리는 방법이다. 설치는 키트 폴더 **안에서만** 일어나므로 폴더를 지우면 끝이다.
키트에는 운영 venv가 없고 **벤치 venv 하나**(`support/bench-venv`: 고정 패키지 29개 + (선택) Silero + (선택) `mlx-qwen3-asr` 고정 버전)만 있다.
**전체 저장소에서는 `setup_bench_env.sh`가 실행을 거부한다**: `make bench-kit`만 키트에 마커 파일 `BENCH_KIT`을 넣고, 마커가 없거나 `app/`/`SPEC.md`가 있는 폴더에서는 아무것도 하지 않고 멈춘다.

## 한눈에 보기

| 단계 | 어디서 | 명령 |
|---|---|---|
| 1. 키트 만들기 | 메인 Mac | `make bench-kit` → `build/bench-kit.tar.gz` |
| 2. 오디오 슬라이스 준비 | 메인 Mac | 10~20분짜리 실제 회의 오디오 (아래 2절) |
| 3. 두 파일 옮기기 | 메인 → 다른 Mac | AirDrop / `scp` / USB (**클라우드 업로드 금지**) |
| 4. 환경 만들기 | 다른 Mac | `scripts/bench_kit/setup_bench_env.sh --with-silero --with-qwen --download whisper-large-v3,qwen3-asr-1.7b` (키트 폴더 안의 `support/bench-venv`) |
| 5. 벤치마크 실행 | 다른 Mac | `source ./bench.env` 후 `"$BENCH_PY" scripts/bench_asr.py ...` (5절) |
| 6. 결과 가져오기 | 다른 Mac → 메인 | `benchmarks/<run>/` 폴더 (오디오 아님, 전사 텍스트임) |

## 0. 요구사항

- Apple Silicon Mac, macOS 14 이상. Intel Mac에서는 mlx가 설치되지 않는다. (Rosetta로 연 터미널도 `uname -m`이 x86_64라서 안 된다.)
- Python 3.13 (Homebrew의 `/opt/homebrew/bin/python3.13` 등; 없으면 3.12가 대체로 쓰이지만 lock 파일은 3.13에서만 검증했다. 3.11은 고정한 numpy·scipy가 설치되지 않는다). 스크립트는 Homebrew 패키지를 **설치하지 않는다**. 없으면 직접 `brew install python@3.13`.
- `afconvert` (macOS에 기본 포함): m4a/mp3 입력을 읽을 때 쓴다. ffmpeg는 필요 없다.
- 인터넷: **환경을 만들 때 한 번만** (PyPI와 Hugging Face 다운로드). 벤치마크 실행 중에는 필요 없고, `bench.env`가 오프라인 모드로 고정한다.
- 디스크 여유: 아래 표 + 약 1 GB. RAM: 모델을 하나씩 순서대로 올리므로 16 GB면 충분할 것으로 본다 (large-v3 피크 약 4 GB, Qwen3-ASR-1.7B bf16은 약 5 GB 안팎으로 추정).

## 1. 키트 만들기 (메인 Mac)

```bash
cd <이 저장소의 체크아웃>
make bench-kit            # build/bench-kit.tar.gz (작다: 수백 KB). 다른 위치: make bench-kit BUILD_DIR=/some/dir
```

키트에 들어가는 파일 (`make bench-kit`은 이 파일들을 임시 폴더에 모아 **마커 파일 `BENCH_KIT`** 을 더하고 묶는다. 마커는 키트에만 있고 저장소에는 없다):

| 파일 | 용도 |
|---|---|
| `pipeline/mcap/` (전체 폴더) | 운영과 같은 ASR 코드 (VAD, 언어 감지, 청킹, 후처리). `bench_asr.py`가 import 한다 |
| `pipeline/requirements.lock.txt` | 고정된 패키지 29개 (mlx-whisper, torch 없음) |
| `pipeline/requirements-silero.txt` | 선택: onnxruntime 등 3개 (Silero VAD용) |
| `pipeline/requirements-qwen-bench.txt` | 선택: `mlx-qwen3-asr` 0.4.4 (Qwen 벤치마크 전용) |
| `scripts/bench_asr.py` | 벤치마크 본체 |
| `scripts/setup_python.sh` | venv/모델/Silero 설치 (체크섬 검증, 멱등) |
| `scripts/bench_kit/setup_bench_env.sh`, `README.md` | 이 키트용 래퍼와 요약 |
| `config/vocabulary.txt` | 용어 목록 (프롬프트와 용어 적중률 계산에 쓰임) |
| `docs/BENCH_KIT.md` | 이 문서 |
| `BENCH_KIT` | 마커 파일 (`make bench-kit`만 만든다). 이게 없으면 `setup_bench_env.sh`는 거부한다 |

직접 묶지 말고 `make bench-kit`을 쓴다 (마커가 없으면 키트가 거부된다).

## 2. 오디오 슬라이스 준비 (메인 Mac)

실제 회의 오디오 **10~20분**을 고른다 (쓰는 언어, 한영 혼용, 숫자, 이름, 전문 용어가 섞인 구간이 좋다). `bench_asr.py`는 m4a, mp4, mp3, wav를
읽고 `--start`/`--duration`(초)으로 직접 자르므로 **파일 통째로 옮겨도 된다**. 필요한 구간만 옮기고 싶으면 (파일이 작아지고, 다른 구간은 아예 나가지 않는다):

```bash
afconvert -f WAVE -d LEI16@16000 -c 1 "원본.m4a" /tmp/full.wav        # 16 kHz mono 16-bit WAV (10분 약 19 MB)
python3 - <<'EOF'
import wave
start, dur = 600, 900            # 10:00부터 15분
src = wave.open('/tmp/full.wav'); sr = src.getframerate()
src.setpos(int(start * sr)); frames = src.readframes(int(dur * sr))
dst = wave.open('slice.wav', 'wb'); dst.setnchannels(1); dst.setsampwidth(2); dst.setframerate(sr); dst.writeframes(frames); dst.close()
EOF
rm /tmp/full.wav
```

트랙을 따로 비교하고 싶으면 (언어 고정 실험) 세션 폴더의 `mic.m4a`, `remote.m4a`를 같은 방법으로 자른다. 처음엔 두 트랙이 섞인 `audio.m4a` 한 파일이면 충분하다.

## 3. 옮기기

AirDrop, `scp`, USB 디스크 중 하나. 예:

```bash
scp build/bench-kit.tar.gz slice.wav alice@other-mac.local:~/
```

**오디오를 Google Drive, iCloud, Slack, 이메일 등 외부 서비스에 올리지 않는다.** 이 키트의 전제가 "오디오는 내 Mac 두 대 사이에서만 오간다"이다.

## 4. 환경 만들기 (다른 Mac)

```bash
mkdir -p ~/mcap-bench && tar -xzf ~/bench-kit.tar.gz -C ~/mcap-bench
mv ~/slice.wav ~/mcap-bench/            # 어디 있어도 상관없다, 경로만 맞추면 된다
cd ~/mcap-bench

# 먼저 계획과 정확한 다운로드 크기를 본다 (아무것도 바꾸지 않는다)
scripts/bench_kit/setup_bench_env.sh --dry-run --with-silero --with-qwen --download whisper-large-v3,qwen3-asr-1.7b

# 실제로 설치
scripts/bench_kit/setup_bench_env.sh --with-silero --with-qwen --download whisper-large-v3,qwen3-asr-1.7b
```

다운로드 크기 (스크립트가 시작할 때 같은 숫자를 출력한다):

| 구성요소 | 크기 | 옵션 |
|---|---|---|
| Python 패키지 29개 (벤치 venv `support/bench-venv`, torch 없음) | 디스크 약 550 MB | 항상 |
| Silero VAD: onnxruntime 등 + 모델 `silero_vad.onnx` | 약 22 MB + **2,327,524 바이트** | `--with-silero` (권장: 운영과 같은 VAD) |
| `mlx-qwen3-asr` 0.4.4 (버전 고정, 벤치 venv에만) | 작음 (순수 Python) | `--with-qwen` |
| `mlx-community/whisper-large-v3-mlx` (기준선) | **3,083,522,487 바이트 = 3.08 GB** | `--download whisper-large-v3` |
| `mlx-community/Qwen3-ASR-1.7B-bf16` (도전자) | **4,080,710,353 바이트 = 4.08 GB** | `--download qwen3-asr-1.7b` |
| `mlx-community/whisper-large-v3-turbo` (속도 대조군, 선택) | 1,613,979,758 바이트 = 1.61 GB | `--download whisper-large-v3-turbo` |

A+B만이면 합계 약 7.2 GB(+ venv 0.55 GB), 세 개 모두면 약 8.8 GB. 모델 파일은 고정된 리비전으로 받고 크기와 sha256을 검증한다. Silero 모델도
sha256 `1a153a22...`로 검증한다. 인터넷이 막힌 곳이면 Silero 모델 파일(`silero_vad.onnx`)을 메인 Mac의 `~/Library/Application Support/MeetingCapture/models/`에서 복사해
`--silero-file 경로`로 넘기면 된다. 같은 명령을 다시 실행해도 이미 있는 것은 건너뛴다 (멱등).

설치가 끝나면 키트 폴더에 `bench.env`가 생긴다. 이 파일이 `BENCH_PY`(벤치 venv의 Python), `HF_HOME`(키트 안의 모델 캐시), `MCAP_SILERO_MODEL`을 잡고
`HF_HUB_OFFLINE=1`로 네트워크를 막는다. **모델을 더 받으려면 `bench.env`를 source 하지 않은 새 터미널에서** `setup_bench_env.sh --download ...`를 다시 실행한다.

## 5. 벤치마크 실행 (다른 Mac)

```bash
cd ~/mcap-bench && source ./bench.env
"$BENCH_PY" scripts/bench_asr.py --help
```

**실험 1: 운영과 같은 설정으로 후보 비교** (구간별 한/영 자동 감지, 언어 프레임 + 용어 목록 프롬프트):

```bash
"$BENCH_PY" scripts/bench_asr.py --audio slice.wav \
  --models mlx-community/whisper-large-v3-mlx mlx-community/Qwen3-ASR-1.7B-bf16 \
  --language-mode auto-region --prompt-style frame+list --no-download --out benchmarks/run1-auto
```

모델마다 순서대로 돌고 모델이 끝날 때마다 메모리를 해제한다. 속도는 Mac마다 크게 다르다. 15분 슬라이스면 모델 하나당 몇 분 정도로 보면 된다.

**실험 2: 프롬프트(용어 힌트) 효과**:

```bash
"$BENCH_PY" scripts/bench_asr.py --audio slice.wav --models mlx-community/whisper-large-v3-mlx --prompt-style none --no-download --out benchmarks/run2-noprompt
"$BENCH_PY" scripts/bench_asr.py --audio slice.wav --models mlx-community/whisper-large-v3-mlx --prompt-style list --no-download --out benchmarks/run3-list
```

**실험 3: 언어 고정** (트랙별 파일이 있을 때. 한국어 트랙은 `forced-ko`, 영어 트랙은 `forced-en`):

```bash
"$BENCH_PY" scripts/bench_asr.py --audio mic-slice.wav    --models mlx-community/whisper-large-v3-mlx mlx-community/Qwen3-ASR-1.7B-bf16 --language-mode forced-ko --no-download --out benchmarks/run4-mic-ko
"$BENCH_PY" scripts/bench_asr.py --audio remote-slice.wav --models mlx-community/whisper-large-v3-mlx mlx-community/Qwen3-ASR-1.7B-bf16 --language-mode forced-en --no-download --out benchmarks/run5-remote-en
```

선택 사항: `--vad energy`(Silero 대신 에너지 VAD), `--vocab 파일`(내 `~/Library/Application Support/MeetingCapture/vocabulary.txt`를 복사해 쓸 때), `--apply-aliases`(alias 치환 후 결과).
`-q`는 로그를 줄인다.

## 6. 결과 읽기와 가져오기

`benchmarks/<run>/` 안에 생기는 파일:

| 파일 | 내용 |
|---|---|
| `summary.md` | 모델별 소요 시간, RTF, 삭제된 세그먼트(환각 필터), 루프/재시도 횟수. 먼저 이것부터 본다 |
| `comparison.md` | 시간 구간별 side-by-side 표 (모델 열 비교) |
| `vocabulary.md` | 용어 목록의 용어가 몇 번 올바르게 나왔는지 |
| `numbers.md` | 숫자, 가격, 날짜, 시간 목록 (모델 간 차이를 눈으로 비교) |
| `<model>/transcript.md`, `segments.json` | 모델별 전체 전사본 |

볼 것: 한국어/영어 전사, 한영 전환, 숫자, 이름, 전문 용어, 약어, 문장 누락, 환각. 판단 기준(`docs/research/asr-landscape.md` 8절): 도전자가
위 항목 중 **2/3 이상에서 명확히 낫고**, 루프/환각/언어 붕괴가 없고, 60분 회의를 15분 안에 전사할 수 있을 때만 Whisper large-v3를 바꾼다. 차이가 크지 않으면 large-v3 MLX를 유지한다.

메인 Mac으로 가져오기 (전사 텍스트만, 오디오 아님):

```bash
cd ~/mcap-bench
tar -czf bench-results.tar.gz benchmarks
scp bench-results.tar.gz alice@main-mac.local:~/
# 메인 Mac:  cd <이 저장소의 체크아웃> && tar -xzf ~/bench-results.tar.gz     (benchmarks/는 .gitignore 대상)
```

결과 폴더에도 **회의 내용(전사 텍스트)이 들어 있다**. 오디오와 같은 기준으로 다루고 외부 서비스에 올리지 않는다.

## 7. 프라이버시 정리

- 오디오는 메인 Mac과 이 Mac에만 있다. 키트는 오디오를 어디로도 보내지 않는다. 네트워크는 설치 단계의 PyPI/GitHub/Hugging Face **다운로드(받기만 함)** 에만 쓰이고, 실행 단계는 `HF_HUB_OFFLINE=1`로 막혀 있다.
- 노트 단계(Claude)는 이 키트에 없다. 벤치마크는 전사까지만 한다.
- 끝나면 지운다 (아래 8절).

## 8. 정리

```bash
rm -rf ~/mcap-bench ~/slice.wav ~/bench-kit.tar.gz     # 키트, 모델 캐시, venv, 결과, 오디오 슬라이스가 한 번에 사라진다
```

pip 자체 캐시(`~/Library/Caches/pip`, 수백 MB)는 키트 밖에 있다. 필요하면 `rm -rf ~/Library/Caches/pip`.

## 9. 문제 해결

| 증상 | 원인 / 해결 |
|---|---|
| `no usable Python 3.12 or newer` | `brew install python@3.13`(또는 python.org 설치 프로그램)을 직접 실행하거나 `--python /경로/python3.13` |
| `mlx needs an Apple Silicon Mac` | Intel Mac이거나 Rosetta 터미널. 네이티브 터미널에서 `uname -m`이 `arm64`여야 한다 |
| 첫 실행이 느리다 (약 25초) | mlx-whisper 첫 import의 numba 캐시 생성. 이후엔 빠르다 |
| `LocalEntryNotFoundError`, 모델을 못 찾는다 | `HF_HUB_OFFLINE=1`이므로 모델이 캐시에 없는 것이다. 새 터미널(`bench.env` 없이)에서 `setup_bench_env.sh --download ...` |
| Qwen 모델에서 `mlx_qwen3_asr` import 오류 | `setup_bench_env.sh --with-qwen`을 실행하지 않았다 |
| `bench_asr.py`가 Silero 대신 에너지 VAD를 쓴다 (summary의 VAD 항목) | `--with-silero`를 빼먹었거나 `bench.env`를 source 하지 않았다 (`MCAP_SILERO_MODEL`) |
| 설치가 중간에 끊겼다 | 같은 명령을 다시 실행한다 (이미 맞는 것은 건너뛰고 나머지만 받는다). venv가 깨졌다는 오류가 나오면 키트 폴더의 `support/bench-venv`를 지우고 다시 실행 |
| `... is the full meeting-capture repository, not a bench kit` 또는 `BENCH_KIT ... is missing` | 키트가 아니라 저장소(또는 마커 없이 직접 묶은 폴더)에서 실행했다. 메인 Mac에서 `make bench-kit`으로 만든 `build/bench-kit.tar.gz`를 **다른 Mac에** 풀어서 거기서 실행한다 |
