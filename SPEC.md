# SPEC — Catch Everything (CATE) (설계 계약)

이 문서는 개발 중에 한국어로 쓴 **설계 결정과 컴포넌트 간 계약**이다. 코드와 테스트가 이 문서와 다르면 **코드와 테스트가 맞고**, 뒤의 절이 앞의 절보다 우선한다 (낡은 문장은 뒤의 절들이 대체한다). 파일 경로, 파일 포맷, CLI를 바꿀 때는 이 문서도 같이 고친다.
*English: the design contract of the project, written in Korean during development. Where it disagrees with the code and the tests, the code and the tests win; later sections override earlier ones. Change a path, a file format or the CLI together with this file.*

## 0. 기준 환경
설계는 아래 환경 하나에서 검증했다. 다른 환경(Intel Mac, macOS 14.4 미만, 다른 오디오 장치)은 검증하지 않았다.

| 항목 | 값 |
|---|---|
| 기기 | Apple silicon Mac (arm64), **RAM 16 GB 이상 권장** (전사 중 large-v3가 약 4 GB를 쓴다). Intel Mac은 지원하지 않는다 (MLX 불가) |
| OS | macOS 14.4 이상 (Core Audio process tap). 검증은 macOS 26에서만 했다 |
| 툴체인 | **Xcode 없이 Command Line Tools만** (Swift 5.10, SDK = MacOSX14.4.sdk). → `swiftc`로 직접 빌드, SwiftPM/XCTest/xcodebuild 가정 금지 |
| Python | **3.12 이상 필수** (3.12~3.13; Homebrew, python.org 등; 고정한 numpy·scipy가 3.12 이상을 요구하므로 3.11 이하는 쓸 수 없다). **ffmpeg 없음** (설치하지 않는다 → macOS 내장 `afconvert` 사용) |
| 브라우저 | Google Chrome (`com.google.Chrome`). Meet 감지를 켠 경우에만 쓰인다 |
| Zoom | `us.zoom.xos`, helper `us.zoom.caphost`. 미팅 중이 아닐 때 UDP 소켓이 없다 |
| Teams | new Teams `com.microsoft.teams2` (가상 오디오 드라이버 "Microsoft Teams Audio") |
| 보관 폴더 | 기본 `~/Meetings` (로컬). Google Drive for desktop 같은 동기화 폴더는 `ARCHIVE_DIR`로 지정한다 |
| Claude Code | `claude` CLI (`~/.local/bin/claude`), 본인 계정으로 로그인. `env -i`(깨끗한 환경)에서 `claude -p --model opus` 동작을 확인했다. 모델 alias: `opus`, `sonnet` |
| 서명 인증서 | 기본 **ad-hoc 서명** (재빌드 시 TCC 권한 재승인 필요). 선택: 로컬 자체 서명 인증서(`make signing-identity`). 공증(notarization)은 하지 않는다 |
| Core Audio | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput/Output` 조회는 권한 없이 동작한다. `CATapDescription` 컴파일 가능 |
| 기본 오디오 | 입력 MacBook 마이크, 출력 MacBook 스피커 (스피커 사용 → **마이크에 에코 유입 가능**) |

## 1. 핵심 설계 결정
1. **2-프로세스 구조**: (a) Swift 메뉴바 앱 `CATE.app` = 감지 + 녹음 + UI. (b) Python 패키지 `mcap` = 후처리(전사·노트·보관). 서로 **파일시스템(세션 폴더)** 으로만 통신. DB/큐 없음.
2. **시스템 오디오는 Core Audio Process Tap** (`CATapDescription`, macOS 14.2+), **ScreenCaptureKit 아님**. 이유: (i) 화면 녹화 권한 불필요 (System Audio Recording 권한만), (ii) macOS 15+의 ScreenCaptureKit 월간 재승인 팝업 회피, (iii) SDK 14.4에는 SCK 마이크 캡처 API가 없음, (iv) 오디오 전용. 기본 모드 `global`(우리 프로세스 제외 전체 시스템 출력), 옵션 `app`(회의 앱 프로세스만). **커널/시스템 확장·가상 오디오 드라이버(BlackHole 등) 설치 안 함.**
3. **마이크는 별도 트랙** (AVAudioEngine 또는 Core Audio 입력). `remote`(상대) / `mic`(나) 두 트랙을 각각 WAV로 기록. 진행 중 크래시에도 살아남도록 **PCM WAV(16-bit mono)를 쓰고 헤더 크기를 ≤5초마다 갱신**한다. m4a 인코딩은 종료 후 Python이 `afconvert`로.
4. **감지 = 신호 조합 + 디바운스 + grace**. 재현율(놓치지 않기) 우선: 약간의 오탐은 후처리(발화 거의 없음 → 폐기)에서 걸러낸다. 세부는 §5.
5. **ASR = 로컬 mlx-whisper, 기본 `mlx-community/whisper-large-v3-mlx`(fp16 full)**. 모델은 config 한 줄로 교체. 실제 회의 오디오로 후보 비교는 별도 단계(§9). VAD로 발화 구간만 잘라 전사 + vocabulary를 `initial_prompt`로 주입 + 환각 필터.
6. **노트 = `claude -p`**(기본은 API 키, 구독 로그인은 선택: 17절이 우선). 구독 모드에서는 `ANTHROPIC_API_KEY` 등 API 과금 경로로 새지 않도록 자식 프로세스 env에서 제거하고, `claude auth status`가 `claude.ai`가 아니면 노트 생성을 시도하지 않고 transcript만 남긴다. **`--bare` 금지** (OAuth/키체인을 읽지 않고 API key만 허용하므로 구독 우회 불가).
7. **보관 = 로컬 staging에서 처리 후 Drive 폴더로 이동(publish)**. Drive File Provider 경로에 녹음 중 직접 쓰지 않는다. 실패하면 staging에 그대로 남는다.
8. 자동 실행 = **LaunchAgent**(`KeepAlive: SuccessfulExit=false`). 앱 Quit(exit 0)은 재시작되지 않는다.

## 2. 디렉터리/경로
```
PROJECT_DIR   = ~/Developer/meeting-capture            (이 repo)
SUPPORT_DIR   = ~/Library/Application Support/MeetingCapture
  config.env            런타임 설정 (install 시 config/config.env.example에서 복사, 이미 있으면 보존)
  vocabulary.txt        (config/vocabulary.txt에서 복사, 보존)
  note_prompt.md        (config/note_prompt.md에서 복사, 보존)
  venv/                 Python venv (mlx-whisper 등)
  sessions/<session_id>/   ← staging (녹음~후처리)
LOG_DIR       = ~/Library/Logs/MeetingCapture
  app.log, pipeline-<session_id>.log
APP_PATH      = ~/Applications/CATE.app   (파일 이름은 빌드 입력 MCAP_APP_SHORT_NAME, 기본 CATE; 사람이 읽는 이름은 MCAP_APP_NAME, 기본 Catch Everything; bundle id: 빌드 입력 MCAP_BUNDLE_ID, 기본 org.meetingcapture.app)
LAUNCH_AGENT  = ~/Library/LaunchAgents/<bundle id>.plist
ARCHIVE_DIR   = ~/Meetings   (config 변경 가능, 예: ~/Library/CloudStorage/GoogleDrive-<계정>/My Drive/Meetings)
  YYYY-MM/YYYY-MM-DD_HHMM_<title-slug>/
      transcript.md  meeting-note.md  audio.m4a  mic.m4a  remote.m4a  session.json  transcript.json
```
`session_id` = `YYYY-MM-DD_HHMM_<platform>` (로컬 시각, platform ∈ `meet|zoom|teams|manual`), 충돌 시 `-2`, `-3` 접미.
`~`는 config.env 값에서 확장해서 쓴다 (Swift/Python 모두).

## 3. config.env (KEY=VALUE, `#` 주석, 따옴표 없이 값 전체가 경로여도 OK)
```
# --- 경로 ---
ARCHIVE_DIR=~/Meetings
PROJECT_DIR=~/Developer/meeting-capture
PYTHON_BIN=~/Library/Application Support/MeetingCapture/venv/bin/python
CLAUDE_BIN=~/.local/bin/claude
# --- 나 ---
SELF_NAME=Me
# --- 감지 ---
ENABLED_PLATFORMS=zoom,teams
BROWSER_BUNDLE_IDS=com.google.Chrome
POLL_INTERVAL_SECONDS=2
START_DEBOUNCE_SECONDS=4
GRACE_SECONDS=20
MIN_RECORDING_SECONDS=30
MAX_RECORDING_HOURS=6
MIN_FREE_DISK_GB=5
# --- 오디오 ---
SYSTEM_AUDIO_MODE=global        # global | app
# --- ASR ---
ASR_MODEL=mlx-community/whisper-large-v3-mlx
ASR_LANGUAGE=auto               # auto | ko | en  (auto = 구간(region) 단위 ko/en 감지, 아래 §13.2)
ASR_VAD=auto                    # auto | silero | energy
# --- 노트 ---
NOTE_MODEL=opus
NOTE_FALLBACK_MODEL=sonnet
NOTE_EFFORT=high
NOTE_LANGUAGE=auto              # auto = 회의의 주 언어로 작성
NOTE_TIMEOUT_SECONDS=1200
NOTE_STOP_ON_OVERAGE=1          # 1 = Claude가 extra-usage(초과 과금) 사용 중이라고 보고하면 노트 생성 중단(transcript만 보존)
CALENDAR_LOOKUP=auto            # auto | 0  (claude.ai Google Calendar 커넥터로 제목/참석자 조회, 실패 시 조용히 폴백)
# --- 보관 ---
AUDIO_RETENTION_DAYS=0          # 0 = 영구 보관. N>0이면 `mcap prune-audio`가 N일 지난 *.m4a만 삭제
```

## 4. 파일 포맷 계약

### 4.1 `session.json` — **Swift 앱만 쓴다.** 녹음 시작 시 생성, 종료 시 1회 갱신. 이후 불변.
```json
{
  "schema": 1,
  "session_id": "2026-10-07_1400_meet",
  "platform": "meet",                     // meet|zoom|teams|manual
  "platform_label": "Google Meet",
  "title_hint": "Meet – abc-defg-hij",    // 창/탭 제목, 없으면 null
  "meeting_url": "https://meet.google.com/abc-defg-hij",   // 없으면 null
  "app_bundle_id": "com.google.Chrome",
  "start_time": "2026-10-07T14:00:12+09:00",   // ISO8601 로컬 오프셋 포함. 모든 트랙 시간의 t0
  "end_time": "2026-10-07T15:03:40+09:00",     // 녹음 중에는 null
  "end_reason": "meeting-ended",          // meeting-ended|manual|paused|app-quit|sleep|disk-low|max-duration|crash-recovered|null
  "tracks": {
    "remote": {"file": "remote.wav", "sample_rate": 48000, "channels": 1, "start_offset_sec": 0.03, "source": "global-tap", "device": "MacBook Pro Speakers"},
    "mic":    {"file": "mic.wav",    "sample_rate": 48000, "channels": 1, "start_offset_sec": 0.05, "source": "mic", "device": "MacBook Pro Microphone"}
  },
  "app_version": "0.1.0"
}
```
- `start_offset_sec` = 트랙 첫 샘플의 시각 − `start_time` (≥0). 파이프라인이 앞을 무음으로 패딩해 정렬한다.
- 장치 변경(AirPods 연결 등)·일시 공백은 **Swift가 무음으로 채워 파일 타임라인을 연속**으로 유지한다. 파일 샘플레이트는 파일당 고정(WAV 헤더 값 = `sample_rate`).
- 크래시 복구: `end_time`이 null인 세션을 앱이 시작 시 발견하면 파일 길이로 `end_time`을 계산해 `end_reason="crash-recovered"`로 채우고 후처리 대상으로 넘긴다.

### 4.2 WAV
16-bit PCM, little-endian, mono. RIFF/data 크기 필드는 기록 중 ≤5초마다 pwrite로 갱신. Python은 헤더가 틀려도 파일 길이로 복구해서 읽는다(lenient reader).

### 4.3 `state.json` — **Python 파이프라인만 쓴다.** (앱은 읽기만 해서 메뉴 상태 표시)
```json
{"schema":1, "stage":"transcribing", "stage_detail":"remote 12/48", "error":null, "updated":"2026-10-07T15:10:02+09:00",
 "done":{"audio":true,"asr":false,"note":false,"publish":false}, "title":null, "final_dir":null}
```
`stage` ∈ `queued|audio|transcribing|noting|publishing|done|failed`. `failed`이면 `error`에 한 줄 사유. 각 단계는 **재진입 가능**(이미 만든 산출물이 있으면 건너뜀, `--force`로 재생성).

### 4.4 `transcript.json` (원본 데이터) / `transcript.md` (사람용)
```json
{"schema":1,"asr_model":"mlx-community/whisper-large-v3-mlx","languages":{"mic":"ko","remote":"en"},
 "segments":[{"start":13.2,"end":19.8,"speaker":"Me","track":"mic","lang":"ko","text":"...","avg_logprob":-0.21,"no_speech_prob":0.01}]}
```
`start/end`은 session t0 기준 초. `transcript.md` 형식:
```
# Transcript

Meeting: <title>
Date: 2026-10-07
Platform: Google Meet
Start: 14:00:12 (KST)   Duration: 01:03:28
ASR: mlx-community/whisper-large-v3-mlx  (mic: ko, remote: en)

[00:00:13] Me
...

[00:00:31] Remote
...
```
같은 화자의 인접 세그먼트(간격 <2s)는 한 블록으로 합친다. **transcript가 먼저 완성·저장된 뒤에만 노트 단계로 간다.**

### 4.5 라벨
내 마이크 트랙 = `SELF_NAME`(기본 `Me`). 시스템 오디오 트랙 = `Remote`. 화자 분리 없음.

## 5. 미팅 감지 (Swift) — "앱이 켜져 있음"만으로 판단 금지
폴링 `POLL_INTERVAL_SECONDS`(기본 2초). 모든 신호는 **권한 없이** 읽을 수 있는 것을 1순위로 한다.

**공통 신호 `AudioProcessMonitor`**: `kAudioHardwarePropertyProcessObjectList`의 각 process object에서 `kAudioProcessPropertyBundleID/PID/IsRunningInput/IsRunningOutput`를 읽어 bundle id prefix로 플랫폼 계열에 매핑.
- Meet: bundle id `com.google.Chrome*`(main + `.helper*`), 설정 `BROWSER_BUNDLE_IDS`
- Zoom: `us.zoom.xos`, `us.zoom.caphost`
- Teams: `com.microsoft.teams2*` (+ 구 Teams `com.microsoft.teams*`)

**플랫폼별 inCall 판정** (OR/AND 조합은 `probe`로 실측해 확정하고 근거를 `docs/DETECTION.md`에 기록):
- **Meet**: Chrome 탭 URL이 `https://meet.google.com/xxx-xxxx-xxx`(코드 형식, `landing`·`new`·`_meet` 등 제외) 인 탭이 존재 **AND** Chrome 계열 process가 입력(마이크) 사용 중이거나 출력이 지속(≥ N초) 중. 탭 목록은 AppleScript(`NSAppleScript`, 백그라운드 큐, 타임아웃)로 읽되 **Chrome이 실행 중일 때만 + Chrome 오디오 I/O가 활성일 때만** 질의(Chrome이 꺼져 있으면 `tell`이 Chrome을 띄우므로 반드시 NSRunningApplication으로 선확인). Automation 권한 거부 시: Chrome 입력 사용만으로 `inCall`(낮은 확신)로 폴백하고 title_hint=null.
- **Zoom**: `us.zoom.xos`의 입력 사용 중 **OR** `us.zoom.xos` PID가 UDP 소켓을 보유(libproc `proc_pidfdinfo`, 미팅 중에만 존재 — 유휴 시 0개 확인됨). 창 제목은 권한이 있을 때만 보조 신호.
- **Teams**: `com.microsoft.teams2*` 입력 사용 중 (+ UDP 소켓 보조). 알림음 같은 짧은 출력은 무시(출력만으로는 inCall 아님).
- 마이크를 쓰는 다른 앱(받아쓰기, 음성메모, Claude 음성 등)은 해당 계열 bundle이 아니면 무시.

**상태기계** (`DetectionStateMachine`, 순수 로직·단위 자가테스트 가능):
`idle → (inCall 신호가 START_DEBOUNCE_SECONDS 연속) → recording → (inCall 거짓이 GRACE_SECONDS 연속) → stop`. stop 후 길이 < `MIN_RECORDING_SECONDS`면 세션 폴더 삭제(단, 오디오가 의미 있는 크기면 보존). Meet는 회의 코드가 바뀌어 GRACE 이상 유지되면 세션을 분리(back-to-back 회의)한다(SHOULD). 안전장치: `MAX_RECORDING_HOURS`, `MIN_FREE_DISK_GB`, 시스템 sleep 시 정상 종료.
감지 로그(`app.log`)에 신호 스냅샷을 상태 전이 시점마다 남겨 사후 디버깅 가능하게 한다.

## 6. 앱(Swift) 동작/CLI
- 인자 없음 → 메뉴바 앱(`LSUIElement`, Dock 아이콘 없음). 상태: `Idle / Meeting detected / Recording mm:ss / Transcribing / Creating note / Done / Error`.
- 메뉴: 상태줄(비활성), `Pause Auto Recording`(토글; 녹음 중 누르면 **정상 종료+보존**하고 후처리 진행, 이후 재개 전까지 자동 시작 안 함), `Start/Stop Recording Now`(수동 폴백), `Open Meeting Folder`, `Reprocess Last Meeting`, `Open Logs`, `Quit`.
- 후처리는 `Process`로 `PYTHON_BIN -m mcap process <session_dir>` 실행(cwd=`PROJECT_DIR/pipeline`, env는 §7 규칙으로 정리), 로그는 `LOG_DIR/pipeline-<id>.log`. **동시에 1개**만. 앱 시작 시 `sessions/`에서 `state.json`이 `done`이 아니고 오디오가 있는 세션을 발견하면 1회 자동 재처리(재시도 폭주 방지: 실패 세션은 `failed`로 두고 자동 재시도하지 않음).
- 녹음/후처리 중 시스템 idle sleep 방지(`ProcessInfo.beginActivity`).
- CLI 서브커맨드(모두 stdout에 결과 출력, `--json` 지원 가능한 곳은 지원):
  - `probe [--watch]` : 현재 감지 신호 스냅샷(플랫폼별 inCall, 근거, process 입출력 상태, Chrome 탭 요약).
  - `selftest-detector` : 상태기계 시나리오 자가 단언 테스트(권한 불필요).
  - `selftest-capture --seconds N --out DIR` : 두 트랙 실녹음 + 레벨/길이 통계 출력(권한 필요).
  - `setup` : 첫 설치용. 마이크 / 시스템 오디오 탭 / Chrome Automation / ARCHIVE_DIR 쓰기 권한 프롬프트를 한 번에 유발하고 각 상태를 출력.
  - `--version`
- 빌드: `swiftc -O -target arm64-apple-macos14.4` 로 `app/Sources/*.swift` 전체 컴파일 → `scripts/build_app.sh`가 `.app` 번들 조립(Info.plist: `LSUIElement`, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSAppleEventsUsageDescription`, `LSMinimumSystemVersion 14.4`) 후 `codesign --force --sign - --identifier <bundle id>`(hardened runtime 사용 안 함). bundle id는 `MCAP_BUNDLE_ID`(기본 `org.meetingcapture.app`)이고 Info.plist `CFBundleIdentifier`, codesign `--identifier`, LaunchAgent 라벨, pkg ID(`<id>.pkg`)가 모두 여기서 나온다. Swift는 실행 시 `Bundle.main.bundleIdentifier`를 읽고(`AppInfo.bundleID`), Info.plist가 없는 단독 바이너리는 기본값을 쓴다.

## 7. 파이프라인(Python `mcap`) 동작
실행: `cd pipeline && PYTHON_BIN -m mcap <command>`. 의존성 최소: `mlx-whisper`(+전이 의존성), `numpy`. 오디오 변환은 `afconvert`/stdlib `wave`. **ffmpeg·soundfile·torchaudio를 새로 요구하지 말 것.**

명령:
- `process <session_dir> [--force] [--from audio|asr|note|publish]`
- `reprocess [--last | <dir>] [--from ...]` — staging과 ARCHIVE_DIR 양쪽에서 최근 세션을 찾는다. 이미 publish된 폴더는 그 자리에서 노트/전사를 재생성.
- `transcribe-file <audio> [--out transcript.md] [--model ...] [--language ...]` — 벤치마크/임의 파일용.
- `prune-audio` — `AUDIO_RETENTION_DAYS`>0이면 ARCHIVE_DIR에서 N일 지난 `*.m4a` 삭제(transcript/note는 절대 삭제 안 함).
- `doctor` — config/venv/모델 캐시/`claude auth status`/ARCHIVE_DIR 쓰기 가능 여부 점검.

단계:
1. **audio**: lenient WAV 읽기 → `start_offset_sec`만큼 앞 패딩 → `mic.m4a`, `remote.m4a`, `audio.m4a`(두 트랙 mono mix; 클리핑 방지) 생성(AAC, `afconvert`) → ASR용 16kHz mono float 배열.
2. **asr**: 트랙별 VAD(에너지 기반, 적응형 임계, numpy) → 발화 구간을 ≤~28s 청크로 병합 → mlx-whisper 전사. 요구:
   - `initial_prompt` = `vocabulary.txt` 상위 용어(Whisper 프롬프트 한도 ~224 토큰 안으로 토큰 수 계산해 자름) + 직전 청크 마지막 문장은 환각 루프 위험이 있으면 생략 가능.
   - `condition_on_previous_text=False`, temperature fallback, `compression_ratio_threshold`, `logprob_threshold`, `no_speech_threshold`, 가능하면 `hallucination_silence_threshold`.
   - 언어: `ASR_LANGUAGE=auto`면 트랙별로 발화 청크 여러 개(예: 균등 5~8개)에서 언어 감지 다수결 → 트랙 언어 확정. 한국어 트랙은 영어 용어가 라틴 문자로 남도록 프롬프트에 영어 용어를 포함.
   - 환각 필터: 알려진 유령 문구("시청해 주셔서 감사합니다", "Thanks for watching", "Subtitles by…", "구독과 좋아요" 등)·반복 n-gram·극단적 compression ratio 제거. 제거 내역은 로그에만 남기고 transcript.json엔 `dropped` 카운트.
   - **에코 처리**: 스피커 사용 시 `mic` 트랙에 상대 음성이 새어 들어온다. 두 트랙 에너지/텍스트 유사도로 `mic` 트랙의 에코 세그먼트를 제거(상대 트랙과 ±3s 내 텍스트 유사도 높고 마이크 에너지가 낮은 경우). 오탐으로 내 발화를 지우지 않도록 보수적으로.
   - vocabulary alias 후처리(`Canonical = alias1 | alias2` 문법) — 정확히 일치하는 오인식 표기만 치환.
   - 발화가 거의 없는 세션(두 트랙 합쳐 발화 < ~20초)은 `state.stage=done, discarded=true`로 표시하고 노트 생략.
3. **note**: `claude -p`로 `meeting-note.md` 생성. 프롬프트는 `note_prompt.md`(노트 구조 + 환각 금지 규칙) + 메타데이터(제목 힌트, 시각, 플랫폼, 길이) + vocabulary(용어 철자 정규화용; 숫자·가격·날짜는 절대 수정 금지) + transcript.md. stdin으로 전달. 호출 정책은 §8. 실패 시: 폴백 모델로 1회 재시도 → 그래도 실패면 `failed` + transcript는 그대로 둔다.
4. **publish**: 제목 결정(캘린더(가능한 경우) → 의미 있는 창/탭 제목(일반적인 "Meet – abc-defg-hij", "Zoom Meeting" 등은 무시) → 노트 H1 → 플랫폼명) → 폴더명 `YYYY-MM-DD_HHMM_<slug>` → `ARCHIVE_DIR/YYYY-MM/`로 이동 → ASR용 임시 파일과 `*.wav` 삭제(m4a 생성 확인 후). ARCHIVE_DIR을 쓸 수 없으면 staging에 남기고 `failed`("archive unavailable")로 표시.
5. 완료 후 `state.json`에 `final_dir` 기록(앱의 "Open Meeting Folder"가 사용).

## 8. Claude 호출 정책 (노트 단계)
- 사전: `claude auth status`(JSON)의 `authMethod`가 `claude.ai`여야 함. 아니면 노트 생략 + 명확한 에러.
- 자식 env: `HOME`, `PATH`(+`~/.local/bin`), `USER`, `LANG`만 최소 전달. **다음은 반드시 제거**: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK/VERTEX/FOUNDRY`, `CLAUDE_CODE_OAUTH_TOKEN`(설정돼 있으면 구독 토큰이 아니라 별도 경로일 수 있음 — 조사 후 판단), `CLAUDECODE` 계열(중첩 세션 오인 방지).
- 플래그(조사 결과로 확정): `-p --model $NOTE_MODEL --tools "" --no-session-persistence --disable-slash-commands --output-format json` + 설정/플러그인/CLAUDE.md 격리(`--safe-mode` 등 실측 후 결정) + `--effort $NOTE_EFFORT`. cwd는 빈 임시 디렉터리. **`--bare` 사용 금지.**
- JSON 결과의 `modelUsage` 키로 실제 사용 모델을 `meeting-note.md` 맨 아래 주석(`<!-- generated by ... -->`)과 로그에 기록.

## 9. ASR 모델 선택 절차
1. 후보 조사(웹): Whisper large-v3(MLX fp16), large-v3-turbo, Qwen3-ASR 계열, 한국어 특화 Whisper 파인튜닝, 기타 2026년 강한 multilingual 로컬 ASR.
2. `scripts/bench_asr.py`: 같은 오디오 슬라이스(10~20분)에 후보별로 전사 → `benchmarks/<run>/<model>.md` + side-by-side diff + 용어 적중률(vocabulary 용어가 올바르게 나온 횟수) + 소요 시간. WER 정밀 계산 불필요.
3. 실제 회의 오디오가 없으면: (a) 사용자 본인의 실제 녹음 일부를 **로컬에서만** 사용(공유하지 않는 개인 파일), (b) macOS `say`(ko_KR/en_US 음성)로 용어 포함 코드스위칭 합성 음성 생성. 벤치마크 결과/전사본은 `benchmarks/`(gitignore)에만 두고 외부로 보내지 않는다.
4. 차이가 크지 않으면 large-v3 MLX 확정. 명확히 우수하고 실용적(RAM, 회의 시간 대비 합리적 시간)이면 교체.

## 10. 하지 않는 것 / 금지 (설계 제약)
- 전사와 노트는 로컬 mlx-whisper와 `claude -p`(구독 로그인, 또는 §17의 API 키 모드)만 쓴다. 다른 외부 전사 엔진은 SPEC 18(조직 모드)에서만, 동의와 정책 아래에서 쓴다.
- 커널/시스템 확장, 가상 오디오 드라이버, brew로 ffmpeg 등 대형 의존성 설치 금지. 전역(시스템) Python 패키지 설치 금지: venv에만.
- **OS 권한 프롬프트(TCC)는 사용자가 `CATE.app` 자신에게 허용한다.** 코드는 `tccutil`, TCC.db, 시스템 설정을 건드리지 않는다. 권한이 거부되면 명확한 오류를 낸다. 시스템 오디오 권한은 터미널이나 다른 앱이 아니라 `CATE.app`(`open -n`으로 실행)에 부여된다.
- Chrome에 대한 AppleScript/자동화 호출은 `CATE.app` 안에서만 실행한다(셸에서 실행하면 호출한 앱에 Automation 권한 프롬프트가 뜬다).
- LaunchAgent 로드(`launchctl`)는 사용자가 라이브 테스트를 확인한 뒤에만 한다 (`make confirm-live-tested`, §14.4). 설치 스크립트는 plist 생성기와 install/uninstall만 제공한다.
- 사용자의 미팅 오디오와 전사본은 외부 서비스로 보내지 않는다. 예외는 노트 단계의 Claude 호출(전사 텍스트)과 사용자가 켠 선택 기능이다 (`docs/PRIVACY_LANES.md`).
- 과설계 금지: DB, 큐, 대시보드, Docker, 다중 사용자.

## 12. 모듈 간 인터페이스 계약

### 12.1 Swift (`app/Sources/Types.swift`가 정본 — 반드시 읽을 것)
- `Platform`, `PlatformSignal`, `DetectionSnapshot`, `MeetingDetecting`(protocol; 구현 `final class Detector: MeetingDetecting`, `init(config: AppConfig)`), `EndReason`, `StateAction`.
- `DetectionStateMachine`: `init(startDebounce:grace:)`, `isRecording`, `isCandidate`, `step(now:snapshot:) -> StateAction`, `reset()`, `adoptManualRecording()`.
- `SessionRecording`(protocol) / `final class Recorder: SessionRecording`, `init(sessionDir: URL, signal: PlatformSignal, config: AppConfig)`. `RecorderSummary`, `RecorderError`.
- `AppConfig` 구조체는 Types.swift에 있고, `extension AppConfig { static func load() -> AppConfig }`(config.env 파싱)는 `Config.swift`에 구현. `Log.info/warn/error/flush`는 Types.swift에 있음.
- CLI 진입 함수(`main.swift`가 호출): `func runProbe(config: AppConfig, watch: Bool, json: Bool) -> Int32`, `func runSelftestDetector() -> Int32`, `func runSelftestCapture(config: AppConfig, seconds: Int, outDir: URL) -> Int32`, `func runSetup(config: AppConfig) -> Int32` (`setup`의 마이크/시스템 오디오 권한 유발은 `func requestCapturePermissions() -> [String: String]`, Chrome Automation 프롬프트 유발은 `func requestChromeAutomationPermission() -> String`).
- 플랫폼 타깃 `arm64-apple-macos14.4`, Swift 5.10 언어 모드(strict concurrency 아님). 프레임워크: AppKit, Foundation, CoreAudio, AudioToolbox, AVFoundation, ApplicationServices(필요 시), Darwin(libproc).

### 12.2 Python
```python
# mcap/wavio.py           
read_wav_lenient(path: Path) -> tuple[np.ndarray, int]        # float32 mono [-1,1], sample_rate. 헤더가 틀려도 파일 길이로 복구.
write_wav_int16(path: Path, samples: np.ndarray, sample_rate: int) -> None

# mcap/audioprep.py       
@dataclass
class PreparedAudio:
    tracks: dict[str, np.ndarray]   # "mic", "remote": float32 mono 16 kHz, index 0 == session t0, 같은 길이
    sample_rate: int                # 16000
    duration_sec: float
    archive_files: dict[str, Path]  # "audio","mic","remote" -> session_dir 안의 m4a
prepare_audio(session_dir: Path, session: dict, force: bool = False) -> PreparedAudio   # session = session.json 내용

# mcap/asr.py             
transcribe_tracks(prepared: PreparedAudio, cfg: Config, vocab: Vocab, progress: Callable[[str], None] = ...) -> dict   # transcript.json(§4.4) dict
transcribe_array(audio: np.ndarray, cfg: Config, vocab: Vocab, language: str | None = None, progress=...) -> list[dict] # 한 트랙 세그먼트 (transcribe-file / bench용)
build_asr_prompt(vocab: Vocab, tokenizer, max_tokens: int = 200) -> str

# mcap/transcript.py      
format_ts(seconds: float) -> str                                  # "HH:MM:SS"
render_markdown(transcript: dict, meta: dict) -> str              # meta: title, date(YYYY-MM-DD), platform_label, start_time, duration_sec, asr_model

# mcap/state.py             read_state(session_dir) / write_state(session_dir, **fields)   # §4.3, 원자적 쓰기
# mcap/note.py              generate_note(transcript_md: str, meta: dict, cfg: Config, vocab: Vocab) -> NoteResult(ok, text, model, error_kind, error)
# mcap/publish.py           resolve_title(...), slugify(...), publish(session_dir, cfg, title) -> Path
# mcap/pipeline.py          process_session(session_dir: Path, cfg: Config, force: bool = False, from_stage: str | None = None) -> None
# mcap/cli.py, __main__.py
```
`Config`/`Vocab`는 이미 있는 `mcap/config.py`, `mcap/vocab.py`를 import (테스트는 `Config()` 기본값 + `Config(support_dir=tmp)`로 생성). 단위 테스트는 `pytest` 불필요 — stdlib `unittest`로 작성하고 `python -m unittest discover -s pipeline/tests`로 돌아가야 한다(venv 없이 python3 + numpy가 있으면 되는 테스트와, venv가 필요한 통합 테스트를 구분).


## 13. 조사 결과 반영 / 수정 사항 — **앞 절과 충돌하면 이 절이 우선**
근거 문서: `docs/research/asr-landscape.md`(ASR 후보 조사), `docs/DETECTION.md`(감지 근거와 라이브 테스트 목록).

### 13.0 설치 정책
- 프로덕션 venv(`~/Library/Application Support/MeetingCapture/venv`)와 대용량 모델 가중치(large-v3 등)는 사용자가 `scripts/install.sh --python ...` 또는 `scripts/setup_python.sh`로 설치한다. 테스트는 tiny 모델과 랜덤 가중치 하네스까지만 쓴다(100MB 넘는 가중치를 받지 않는다).
- Silero VAD는 `--with-silero`로만 설치된다. 코드는 Silero(onnxruntime, torch 불필요) 경로와 에너지 VAD 폴백(`ASR_VAD=auto`)을 모두 지원한다. 서명 인증서는 기본으로 만들지 않는다(ad-hoc 유지; `make signing-identity`는 선택).

### 13.1 감지 (Swift) 수정
- 폴링 방식(프로퍼티 리스너는 발화하지 않음). 스냅샷당 3.7ms 수준으로 PID/BundleID를 AudioObjectID별 캐시하고 현재 목록에 없는 ID는 제거, `IsRunning*`은 계열 prefix에 맞는 프로세스만 읽는다. 입력/UDP는 ≥2회 폴링 smoothing, 출력은 ≥5회(~10s) smoothing. IsRunningOutput은 "스트림이 열려 있음"이지 "소리가 남"이 아니다(무음도 1).
- **Meet**: `tabMeet`(Chrome 탭 URL이 회의 코드 형식; Chrome 실행 중이고 `chromeIn||chromeOut`일 때만 질의) AND `chromeIn||chromeOut`(~10s 지속). 시작은 debounce 후, 유지는 `tabMeet && (chromeIn||chromeOut)`, 종료는 grace 후. 확신도: HIGH = tabMeet && in && out, MEDIUM = tabMeet && (in||out), **Automation 거부 시 폴백 LOW = in && out (in 단독 금지)**. Chrome 오디오는 audio-service 유틸리티 helper(`com.google.Chrome.helper`)가 소유 → `com.google.Chrome*` 전체 process object를 합산. 탭 질의는 `tell application id "com.google.Chrome"` + `with timeout of 3 seconds`, `URL of every tab of w`/`title of every tab of w` 일괄 조회, 단일 직렬 큐, Chrome 미실행이면 절대 호출 금지, 권한 상태는 `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:false)`로 읽고 프롬프트는 `setup`에서만.
- **Zoom**: `us.zoom.xos` **메인 PID**의 UDP 소켓 ≥1(2회 연속) OR `us.zoom.xos`/`us.zoom.caphost` 입력 사용이 debounce 동안 유지. 헬퍼(ZoomCefHelper*)의 UDP는 세지 않는다. `caphost` 존재·창 제목·로그는 신호로 쓰지 않는다(창 제목은 Screen Recording 없이는 비어 있음, 로그는 암호화).
- **Teams**: `com.microsoft.teams*` 입력 사용(+ 메인 MSTeams PID UDP 보조). 출력만으로는 시작/유지하지 않음.
- Grace: 상태기계는 `grace` 하나를 받되, 유효 grace = Meet은 config 값, Zoom/Teams는 `max(config 값, 30s)`(breakout/재연결 보호). 자기 자신의 bundle id(`AppInfo.bundleID`)와 그 helper는 항상 제외.
- 거부(v1): Chrome 원격 디버깅, 확장/native messaging, Accessibility·Screen Recording 창 제목, Zoom/Teams 로그, caphost 존재, device-level IsRunningSomewhere.
- 라이브 테스트 체크리스트 L-01..L-20은 `docs/DETECTION.md` 10절 — `probe --watch`가 그 검증에 필요한 값(프로세스별 in/out, PID, UDP 수, 탭 분류)을 모두 출력해야 한다.

### 13.2 ASR (Python) 수정
- venv 설치는 **lock 파일 + `pip install --no-deps`** (`pipeline/requirements.lock.txt`, 29개 pin, torch 미설치, ~550MB). `pip install mlx-whisper` 직접 설치 금지(torch를 끌어옴). 첫 import에 ~24s 걸리므로 `doctor`에서 pre-warm.
- 입력은 float32 mono 16kHz numpy 배열만(경로 전달 금지: ffmpeg 없음). `language=None`·`beam_size`·`initial_prompt=''`·`verbose=False` 금지(`None` 사용). 모델은 `path_or_hf_repo`에 **로컬 디렉터리**를 전달(`snapshot_download(local_files_only=True)` 우선, 없으면 다운로드; large-v3 revision `49e6aa286ad60c14352c404340ded53710378a11` 고정).
- **VAD 구간 단위로 `mlx_whisper.transcribe()`를 청크마다 1회 호출**(initial_prompt가 매 청크 적용되도록), 호출 후 `mx.clear_cache()`. 청크 = 같은 언어의 인접 구간을 gap≤2.5s, 길이≤27.4s(패딩 0.3s 포함 28s 이내)로 병합, 긴 연속 구간은 마지막 35% 중 가장 조용한 100ms에서 절단. 0.4s 미만 발화 청크는 건너뜀. Silero 임계: 진입 p≥0.5, 유지 p≥0.35, 0.30s 이하로 닫음, 0.25s 미만 발화 제거. 에너지 VAD 폴백: 20ms 프레임, 임계 = max(−58dBFS, 하위 10퍼센타일+10dB, 상위 98퍼센타일−35dB), 0.30s 미만 간격 연결, 0.25s 미만 제거.
- 디코드 설정: `condition_on_previous_text=False, temperature=(0.0,0.2,0.4,0.6), compression_ratio_threshold=2.4, logprob_threshold=-1.0, no_speech_threshold=0.6, word_timestamps=False, fp16=True, verbose=None`(+청크별 `language`, `initial_prompt`). 절대 시간 = 청크 시작 + 세그먼트 시간(청크 끝으로 clamp).
- **언어**: 트랙 다수결 대신 구간 단위 `region_languages()`: 트랙 prior를 ≤6개 구간(≥3s)으로 탐침, 모두 p≥0.95로 일치하면 단일언어 빠른 경로, 아니면 ≥2.5s 구간 전부 {ko,en}로 제한한 LID(B=4 배치), p_other≥0.90일 때만 트랙 언어에서 이탈, 짧은 구간은 직전 라벨 상속, 라벨이 바뀌면 청크 경계 강제. `ASR_LANGUAGE=ko|en`이면 LID 생략.
- **프롬프트**: ≤100–120 토큰, 토큰 예산 계산, 우선순위 순서 입력·가장 중요한 용어를 **마지막**에. 한국어 틀 `다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: <terms>`, 영어 틀 `A medical AI meeting. Terms: <terms>`. 프롬프트 안에 한글 음차 금지. 프롬프트 echo(≥5단어 중 70%+가 프롬프트 단어) 가드. 그래도 음차 오인식("애크미" 등)은 vocab alias로 후처리.
- **후처리 필터**(`postfilter()`): compression_ratio>2.4; no_speech_prob>0.6 && avg_logprob<−0.7; avg_logprob<−1.5; 강한 유령 문구(≤12단어: thanks for watching, please subscribe, subtitles by…, 시청해 주셔서 감사합니다, 구독과 좋아요, 다음 영상에서 만나요, 한글자막 …); 신뢰도 낮은 MBC/KBS/SBS 뉴스 접두; 약한 유령(thank you, you, bye, 감사합니다, 네 …)은 ≤3s이고 (avg_logprob<−0.6 또는 no_speech>0.3)일 때만; 가타카나/한자/키릴/아랍/태국/데바나가리 문자 30%+; n-gram 루프 축약(숫자열 내부 제외). 루프/평균 logprob<−1.0/echo인 청크는 **프롬프트 없이 1회 재시도**, 재시도가 명확히 나을 때(+0.1 logprob, 루프 없음)만 채택. 드롭된 세그먼트는 사유와 함께 로그, `transcript.json`에 `dropped` 카운트.
- 메모리/프로세스: 세션당 하위 프로세스, 트랙 순차(mic → remote), 배치 디코드 안 함. 진행 상황은 `state.json.stage_detail`.
- **엔진 추상화**: `Engine.transcribe_chunk(audio, language, prompt) -> {text, segments, avg_logprob, ...}`; `WhisperEngine`(운영 기본). `ASR_MODEL` 이름에 `qwen3_asr`/`Qwen3-ASR`가 들어 있으면 `mlx-qwen3-asr` 기반 엔진(지연 import, **벤치마크 전용 — 운영 경로 기본 아님**). Qwen 사용 시 4-bit/5-bit 금지, 작은 VAD 조각 대신 긴 청크 사용, `finish_reason/truncated` 기록.
- **누락 트랙**: 한 트랙이 프레임을 한 번도 못 만들면 앱은 그 WAV를 삭제하고 `session.json.tracks`에서 생략한다. `audioprep`은 누락 트랙을 무음으로 합성하되(전사 시 건너뜀), 두 트랙 모두 없으면 `failed("no audio")`.
- 파일 샘플레이트는 두 트랙 모두 **48000Hz 고정**(앱이 변환), 헤더 보정은 앱이 크래시 복구 시 수행하지만 Python lenient reader도 유지.

### 13.3 Claude 노트 호출 (Python) 수정
- 구현: `pipeline/mcap/note.py`(clean_env, polluted_parent_env, preflight, build_argv, run_claude, parse_stream, classify, next_action).
- argv: `~/.local/bin/claude -p --model <NOTE_MODEL> [--fallback-model <NOTE_FALLBACK_MODEL> (주 모델과 다를 때)] --effort <NOTE_EFFORT> --tools "" --disable-slash-commands --safe-mode --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence --permission-prompts none --system-prompt "<짧은 고정 문구>" --output-format stream-json --verbose`, 프롬프트는 **stdin(UTF-8)**. `--bare`, `--max-budget-usd`, apiKeyHelper/env가 든 `--settings`, `--model fable` 금지.
- env 허용목록(그 외 전부 제거): `HOME`, `USER`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin`, `LANG=en_US.UTF-8` (**셋 중 하나라도 빠지면 "Not logged in"으로 오인되는 증상** 확인됨). `os.environ` 상속 금지. cwd는 빈 중립 디렉터리(`SUPPORT_DIR/claude-cwd`).
- 사전 점검: `claude auth status`가 `loggedIn true, authMethod claude.ai, apiProvider firstParty`. 호출별 가드: init의 `apiKeySource`가 `none`, 모든 `modelUsage` provider가 `firstParty`, 아니면 `billing_mode_violation`으로 중단. 실패 분류는 `is_error`/`api_error_status` 기준(래퍼의 classify 사용): usage_limit(429+rejected) → 재시도 안 함·retryable로 표시·`resetsAt` 기록, Opus 전용 한도면 sonnet으로 즉시 재시도, overloaded/rate_limited/model_unavailable/timeout → 폴백 1회, auth/billing → 재시도 없음.
- **과금 가드(NOTE_STOP_ON_OVERAGE=1)**: 계정에 extra usage가 켜져 있으면 구독 한도 뒤의 호출이 추가 과금된다. `rate_limit_event.isUsingOverage`가 true로 관측되면 `SUPPORT_DIR/overage.json`에 시각/`resetsAt`을 기록하고 경고(state.json, 로그, 노트 푸터), 이후 노트 단계는 그 marker가 유효한 동안 시도하지 않고 `failed(retryable: overage-guard)`로 transcript만 남긴다(`mcap reprocess --allow-overage`로만 강제). `fable`은 사용하지 않는다.
- 프롬프트 규칙 추가: 부분 날짜("the twelfth", "next Thursday")를 임의로 완성 금지, 노트 길이 상한 지시, 제목/날짜/시간/플랫폼/참석자는 session.json(및 캘린더)에서 채우고 모델이 지어내지 않게 함.
- 모델 alias는 고정 id가 아니라 `opus`/`sonnet` 그대로. 노트 푸터 주석에 resolved model id(`modelUsage` 키), claude 버전, effort 기록. `CLAUDE_BIN`은 `~/.local/bin/claude` 고정(auto-update off 상태 유지가 전제).
- 선택(CALENDAR_LOOKUP): 2-turn stream-json 조회(`pipeline/mcap/calendar_lookup.py`). 30–90s 타임아웃, 어떤 실패든 창 제목/플랫폼으로 폴백, 원시 tool_result를 Python에서 파싱해 겹침 판정(모델의 산문 금지), 캘린더 쓰기/다른 커넥터 도구는 차단(`--allowedTools`는 list_events만).

### 13.4 캡처와 셸
- 마이크는 Core Audio IOProc, 파일 샘플레이트 48k 고정, `CaptureHAL.swift`/`CaptureSelfTest.swift`/`Setup.swift`/`SelfTests.swift`가 추가 파일이다. `selftest-capture`는 `--synthetic`(장치·권한 불필요) 또는 서명된 .app에서의 live 모드다. live 모드는 셸에서 직접 실행하지 않는다.

## 14. 설계 결정 / 신규 사항 — **13절과 충돌하면 이 절이 우선**

### 14.1 결정
- **Intel Mac은 지원하지 않는다** (MLX 불가). `scripts/bench_kit`은 "다른 Apple silicon Mac용" 선택 기능으로만 유지한다.
- **초과 사용(Extra usage)**: `NOTE_STOP_ON_OVERAGE=1`(기본)이면 Claude가 초과 과금을 보고하는 동안 노트 생성을 멈추고 transcript만 남긴다. `0`이면 허용하고 기록만 한다. API key/PAYG 경로 차단(env 허용목록, `--bare` 금지, apiKeySource 단언)은 그대로다. 기본 모델은 `opus`이고 `fable`은 쓰지 않는다.
- **일반적인 사용 환경 = MacBook 스피커+내장 마이크, 또는 회의용 마이크**(이어폰은 드물다). → 마이크 트랙에 상대방 음성(에코)이 크게 섞인다. **오프라인 에코 캔슬러가 필수 기능**(14.2). 회의실에서 회의용 마이크를 쓰면 마이크 트랙에 현장 참석자 전원이 들어가며 라벨은 `SELF_NAME`(기본 `Me`)로 표시되는 한계가 있다(문서화).

### 14.2 오프라인 에코 캔슬러 (`pipeline/mcap/aec.py`, 신규)
- 입력: 16kHz mono float32 `mic`(마이크) 트랙과 `remote`(시스템 오디오, 스피커로 나간 소리의 디지털 기준 신호). 출력: 에코가 제거된 mic 트랙 + 통계(`applied`, `coherence`, `delay_ms`, `erle_db`).
- 방식: numpy 주파수영역 적응필터(PBFDAF/분할블록 NLMS) + 지연 추정(상호상관) + **double-talk 검출**(적응 동결) + 잔여 에코 억제(스펙트럴 게인). 외부 의존성 추가 금지(numpy만).
- `MIC_AEC=auto|1|0`: auto = 두 트랙의 상관/코히어런스로 "스피커 누설 존재"를 판정해 적용 여부 결정(헤드폰·하드웨어 AEC 회의용 마이크면 건너뜀). 적용은 audioprep 이후, VAD 이전. 통계는 `transcript.json.aec`에 기록.
- **절대 원칙: 사용자 본인의 실제 발화를 지우지 않는다.** 검증은 합성 데이터(TTS remote + 인위적 RIR/감쇠/지연/비선형 + 별도 마이크 발화, double-talk 포함)로 ERLE와 마이크 발화 구간의 에너지 보존율을 측정. 기존 `suppress_echo`는 후단 안전망으로 유지하되 리뷰 지적(own-level 기준 오염, 오디오-only 규칙 부재)을 수정.

### 14.3 LLM 품질 패스 (둘 다 fail-soft, 설정으로 끌 수 있음)
- `TRANSCRIPT_CLEANUP=1`: 원본 `transcript.md/json`은 **절대 수정하지 않고** `transcript.cleaned.md`(+`transcript.cleaned.json`)를 따로 만든다. 세그먼트 id 기준 JSON 입출력, 3~5분 단위 배치(앞뒤 문맥 겹침), 용어·음차(예: "에프디에이"→FDA, vocabulary 철자)·명백한 동음 오류만 교정, 문장 병합/분할/삭제 금지, 불확실하면 원문 유지 또는 `[?]` 표시. **코드가 숫자/날짜/가격/퍼센트 토큰이 원문과 동일한지 검증하고, 하나라도 다르면 그 세그먼트는 원문을 사용**한다. 실패/시간초과 시 원본으로 계속.
- 노트 생성은 cleaned가 유효하면 cleaned를, 아니면 raw를 입력으로 쓴다. 노트 프롬프트에 "마이크 라벨(`SELF_NAME`) 줄에는 에코(Remote 발화의 거의 동일한 반복)가 섞일 수 있음"을 명시.
- `NOTE_VERIFY=1`: 초안 노트 + 원본 transcript로 두 번째 호출(검증 패스). 결정/담당자/기한/숫자 각각에 대해 transcript 근거를 확인해 근거 없는 항목은 제거하거나 "(근거 불명확)"으로 표기한 최종 노트를 반환. **코드 검증**: 최종 노트의 모든 숫자·날짜·금액 토큰은 transcript(raw 또는 cleaned)에 존재해야 하고 필수 헤딩이 유지돼야 한다. 위반/실패 시 초안 노트(검증 전)를 사용하고 `state.warning`에 기록.
- 모든 호출은 §13.3의 env 허용목록/가드를 그대로 사용(중복 구현 금지, `note.py`의 실행기 재사용).

### 14.4 코드 변경 규칙
- **`LaunchGuard.isSignedAppLaunch`**(Types.swift, 신규)가 모든 권한 프롬프트/AppleScript/live 캡처 가드의 기준이다: 번들 id 일치 **AND** (ppid == 1 또는 `__CFBundleIdentifier` == 번들 id). 번들 id만 보던 기존 검사는 모두 이것으로 교체.
- 앱을 이미 실행 중일 때 라이브 점검 명령은 `open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args <subcommand>` (**`-n` 필수**: 없으면 기존 인스턴스만 활성화되고 인자가 무시되며 `-W`가 영원히 대기). `selftest-capture`는 `--live`(서명 앱) 또는 `--synthetic`(셸) 중 정확히 하나를 요구한다.
- onnxruntime 1.30은 Microsoft 텔레메트리 클라이언트를 포함한다. 세션 생성 전에 `onnxruntime.disable_telemetry_events()`를 호출한다(try/except). 기본 상태에서 네트워크 소켓/DB 기록은 관찰되지 않았지만 명시적으로 끈다.
- 노트 프롬프트 경로: `SUPPORT_DIR/note_prompt.md`(사용자 오버라이드, 있으면 우선) → 없으면 repo `config/note_prompt.md`. 설치 스크립트는 note_prompt.md를 복사하지 않는다(드리프트 방지). vocabulary.txt/config.env는 기존대로 "없을 때만 복사".
- 실행 중인 녹음 세션은 파이프라인이 처리하지 않는다(`session.json.end_time`이 null이고 WAV mtime이 최근 ~2분이면 `SessionBusy`, `reprocess --last`는 라이브 세션 제외, 메뉴의 Reprocess는 녹음 중 비활성).
- 재시도 가능한 실패(`archive_unavailable`, 일시적 asr 실패)는 앱 시작 시 1회 자동 재처리하고, `mcap reprocess --pending`으로 일괄 재시도한다.

## 15. 운영 결정 — **14절과 충돌하면 이 절이 우선**
- **Meet 기본 해제**(가장 덜 검증된 플랫폼이고 넓은 Chrome 자동화 권한이 필요하다). `ENABLED_PLATFORMS` 기본값 = `zoom,teams`(Swift `AppConfig` 기본값과 `config.env.example` 모두). Meet 코드는 유지, 한 줄(`ENABLED_PLATFORMS=zoom,teams,meet`)로 다시 켠다. Meet가 꺼져 있으면 Chrome 탭 조회/Automation 프롬프트/`setup`의 Chrome 단계는 실행하지 않는다. 첫 라이브 테스트는 **Zoom 혼자 회의 → Teams 혼자 회의** 순서.
- 신규 설정: Swift `NO_SPEECH_STOP_MINUTES`(기본 15; AUTO 녹음에서 두 트랙이 이 시간 동안 무음이면 정상 종료·보존, 0=끔), `RETRY_SWEEP_HOURS`(기본 6; 실패+retryable 세션이 있으면 앱이 주기적으로 `mcap reprocess --pending` 실행, 0=끔). Python `ASR_LANGUAGES`(기본 `ko,en`; 구간 단위 LID와 외국 문자 필터가 이 집합을 따른다 — `ja`를 넣으면 가나/한자를 버리지 않는다), `MAX_CLAUDE_CALLS_PER_MEETING`(기본 30).
- 운영 안전: (a) 캡처 경고와 "remote 트랙 무음" 플래그를 `session.json`에 영속화(`warnings` 배열, additive), (b) 앱이 macOS 알림(UNUserNotificationCenter)으로 알린다: remote 무음 의심, 권한 오류, 파이프라인 실패, 회의록 완료(제목) — `setup`이 알림 권한도 요청, 거부되면 로그/메뉴만, (c) 파이프라인 stall watchdog은 깨어 있던 시간(monotonic)으로 계산하고 wake 때 재무장, 죽은 작업은 retryable 실패로 표시하여 sweep가 재시도, (d) 호출별 Claude 사용 로그 `SUPPORT_DIR/usage.jsonl`(세션, 단계, 모델, 소요시간, isUsingOverage)과 호출 상한.
- 캘린더 조회 창은 녹음 시작 ±45분으로 좁힌다(이전 8시간 → 불필요한 일정/참석자 이메일 노출 축소).
- LID 결정: 단일언어 빠른 경로는 "최대 16개 탐침 전부 p≥0.95 일치"일 때만, 아니면 ≥2.5s 구간 전체에 배치 LID. 실제 코드스위칭 음성(벤치마크)으로 재튜닝.

## 16. 정오표와 ASR 결정 — **15절과 충돌하면 이 절이 우선**
- **정오표**: 앞 절(0, 2, 3, 4.3/4.4, 5, 6, 7, 8)에 남아 있는 낡은 문장(Meet 우선 → Zoom 우선, ad-hoc → 고정 서명, tombstone state.json, blip 삭제 규칙, 새 config 키, stage_detail 문자열, 명령 목록, `--output-format stream-json`, 호출 상한/usage.jsonl 등)과 그 **대체 문구**는 이 절과 뒤의 절들, 그리고 코드와 테스트가 대체한다. 구현 동작이 궁금하면 코드와 테스트를 먼저 본다.
- **ASR 모델 확정**: `mlx-community/whisper-large-v3-mlx`(fp16 전체)가 기본. Qwen3-ASR-1.7B와 비교했으나 바꿀 뚜렷한 이유가 없었다(비공개 녹음 한 건으로 한 번 해 본 비교라 재현할 수 없고 수치를 공개하지 않는다). 직접 비교하려면 `docs/BENCH_KIT.md`와 `scripts/bench_asr.py`를 쓴다. Qwen은 운영 경로에 넣지 않는다(벤치 venv 전용).
- **프롬프트 예산 140 토큰**(`asr.ASR_PROMPT_TOKENS`): ko 프레임과 vocabulary의 짧은 용어 30개 안팎까지 포함한다(Whisper 한도 223). 120토큰에서는 긴 용어 목록의 뒤쪽 용어가 잘려 실제 발화에서 놓쳤다. vocabulary에 용어를 추가해 예산을 넘기면 위쪽(우선순위 높은) 용어부터 유지된다 — 파일 순서 = 우선순위.
- 영어·한영 혼용 평가는 아직 없다. 첫 실제 영어/혼용 회의로 `region_languages` 임계(p≥0.95 / 0.90)를 재튜닝한다.

## 17. Claude 과금 모드: 구독 또는 API 키 — **앞 절의 "API 금지" 문구보다 우선**
- 파이프라인의 Claude 호출은 **API 키**(Console, 토큰 단위 과금, 기본이자 지원되는 방식) 또는 **구독 로그인**(선택)으로 과금할 수 있다. 처음 설계의 "API 금지 / 몰래 전환 금지"는 이 절의 설정(`CLAUDE_AUTH`, 기본 api)으로 대체된다. 구독 모드(`CLAUDE_AUTH=subscription`)는 선택 사항이고, 이 도구가 사람이 없는 동안 `claude -p`를 돌리므로 계정 약관이 무인 사용을 허용하는지 먼저 확인해야 한다(README 경고).
- 설정: `CLAUDE_AUTH=api|subscription`(기본 api), `CLAUDE_KEY_SERVICE`(Keychain 서비스명, 기본 "MeetingCapture Anthropic API key", account=$USER), `CLAUDE_DAILY_BUDGET_USD`(기본 5, 0=끔), `CLAUDE_MEETING_BUDGET_USD`(기본 2, 0=끔; 노트 호출은 항상 예약). 초과 사용 가드 `NOTE_STOP_ON_OVERAGE`(기본 1)는 subscription 모드에서만 의미가 있다. 예시 `config.env`는 `CALENDAR_LOOKUP=0`으로 시작한다(코드 기본값은 `auto`).
- **키 취급(절대 규칙)**: 키는 macOS Keychain(generic password)에만 있다. 채팅/설정 파일/저장소/로그/state.json/usage.jsonl/argv/세션 폴더에 절대 남기지 않는다. 사용자가 직접 `mcap api-key set`(내부적으로 `security add-generic-password -U -a $USER -s <service> -w`가 터미널에서 직접 비밀번호를 묻는다)으로 저장한다. 코드와 도구는 키를 요청하거나 출력하지 않는다(파이프라인만 호출 직전에 읽는다). 파이프라인은 호출 직전에 `/usr/bin/security find-generic-password -w`로 읽어 **자식 프로세스 env의 `ANTHROPIC_API_KEY`로만** 전달한다(argv 금지). 모든 로그/오류 문자열은 `sk-ant-[A-Za-z0-9_-]+`를 마스킹한다. Swift 앱은 키를 읽지 않는다(존재 여부만 `security find-generic-password`로 확인).
- 자식 env 허용목록은 그대로(HOME, USER, PATH, LANG)이고 api 모드에서만 `ANTHROPIC_API_KEY`가 추가된다. `ANTHROPIC_BASE_URL`/`AUTH_TOKEN`/`USE_BEDROCK` 등은 계속 차단. subscription 모드에서는 Keychain에 키가 있어도 **절대 전달하지 않는다.**
- 가드 반전: subscription 모드는 기존 가드(`claude auth status`가 claude.ai, init `apiKeySource == "none"`). **api 모드**: init `apiKeySource == "ANTHROPIC_API_KEY"`(다르면 CLI가 로그인으로 폴백한 것 → billing_mode_violation으로 중단), 모든 `modelUsage` provider firstParty. 사전 점검은 `claude auth status`를 쓰지 않고 키 존재/형식(`sk-ant-`)만 본다(실제 유효성은 `mcap api-key check`와 첫 호출이 판정).
- 실패 분류(api): 401/403 invalid key → `auth`(재시도 없음, "키를 확인: mcap api-key set"), "credit balance is too low"/billing → `credit_exhausted`(재시도 없음, retryable=true로 표시해 크레딧 충전 후 `reprocess --pending`이 이어서 처리, 알림), 429 → rate_limited(백오프 후 폴백 1회), 5xx/overloaded → 폴백 1회.
- **비용 기록과 한도**: 결과 이벤트의 `total_cost_usd`를 호출마다 `usage.jsonl`에 `cost_usd`, `auth`(subscription|api)와 함께 기록. api 모드에서 (a) 당일(로컬 날짜) 누적이 `CLAUDE_DAILY_BUDGET_USD`에 도달하면 이후 LLM 단계를 건너뛰고 노트는 `failed(retryable, error_kind budget_daily)`로 transcript만 보존하며 알림, (b) 한 번의 파이프라인 실행 비용이 `CLAUDE_MEETING_BUDGET_USD`에 닿으면 cleanup/verify/calendar를 건너뛴다(노트 호출은 예약). `mcap usage`/`doctor`는 7일/30일 비용 합계를 보여 준다.
- **캘린더 조회 예외**: Claude의 Google Calendar 커넥터는 claude.ai 로그인에 묶여 API 키로는 동작하지 않는다. 따라서 `CALENDAR_LOOKUP=auto`의 호출 1건만 **구독 로그인**(키 미전달, 기존 구독용 가드)으로 실행하고 usage.jsonl에 `auth: subscription`으로 기록한다. 구독 로그인이 없으면 조용히 건너뛴다.
- CLI: `mcap api-key status`(Keychain 항목 존재 여부, 값 출력 없음), `mcap api-key set`(터미널에서 직접 입력, 값은 argv/화면/로그에 나오지 않음), `mcap api-key check`(저비용 모델로 1회 실제 호출: 키 유효성, 해석된 모델, 비용 출력; 키 검증용 호출은 명시적으로 실행할 때만), `mcap api-key forget`. `make set-api-key`는 set의 단축. `setup`(Swift)은 api 모드에서 Keychain 항목 존재를 확인하고 없으면 FAIL + 명령 안내.
- Console 쪽 권장(사용자 작업): 이 프로젝트 전용 키를 만들고 **월 지출 한도**를 건다. 데이터 처리/보관 정책은 플랜(claude.ai vs API)마다 다를 수 있으니 약관을 확인한다. 구독 로그인의 약관은 일반적인 개인 사용으로 제한되므로, 무인 운영이나 조직 사용에는 API 키를 쓴다.

## 18. 조직 모드 (프라이버시 레인, 외부 전사 엔진, 회사 설치) — 실험적
코드와 주석이 `SPEC 18`로 가리키는 기능이다. 개인 설치는 정책 파일이 없고 새 설정 키를 하나도 쓰지 않으면 이 기능이 없을 때와 똑같이 동작한다(모든 키의 기본값은 현행 동작, 골든 파일 `pipeline/tests/golden/`이 바이트 단위로 증명한다). 계약은 아래 문서에 나뉘어 있다.
- 프라이버시 레인(전사 원격/클라우드, LLM, 캘린더, 보관), 회의별 로컬 전용 스위치, 동의: `docs/PRIVACY_LANES.md`
- 조직 정책 파일 `policy.json`과 서명/신뢰 규칙: `docs/POLICY.md`
- 전사 서버 프로토콜 `mcap-asr/1`: `docs/ASR_PROTOCOL.md`, 서버 설치(Linux): `docs/ASR_SERVER_LINUX.md`
- 회사 패키지, 릴리스, 롤아웃: `docs/DEPLOY.md`, 운영: `docs/OPS_RUNBOOK.md`, 개인 설치에서 옮기기: `docs/MIGRATION.md`
이 기능은 한 조직의 설치를 위해 쓰였고 법률 검토를 받지 않았다. 지원은 없다.
