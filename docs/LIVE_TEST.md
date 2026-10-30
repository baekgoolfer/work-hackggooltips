# 첫 라이브 세션 체크리스트 (순서대로)

> English: [LIVE_TEST.en.md](LIVE_TEST.en.md) has the first-run steps and expected results in English. This file is the full checklist and is written in Korean.

## English summary (the rest of this file is in Korean)

This is the full first-run checklist. [LIVE_TEST.en.md](LIVE_TEST.en.md) has the minimum steps (sections 0 to 5, 7 and 8) with commands and expected results in English. The summary below says what each section of this Korean file verifies and what you should see, so that you can follow the commands (which are not translated) without reading the Korean text.

Automatic tests (`make test`) use no device and no permission. Everything here needs a real Mac, a real microphone, the macOS permission prompts and real calls. Each step has three parts: the command, what you should see (**기대**), and what to keep (**보낼 것**). If what you see differs, stop there, collect the files of section 8 and open an issue. Google Meet detection is off by default (`ENABLED_PLATFORMS=zoom,teams`), so the order is Zoom alone, then Teams alone; Meet is appendix A. Closing the laptop lid puts the Mac to sleep, and recording and processing stop until it wakes.

| Section | What it verifies | Expected result |
|---|---|---|
| 0 | what you need (two terminal tabs, a YouTube video as the remote voice, sentences to read aloud) and the shell variables | nothing to check; the variables are pasted once per tab |
| 1 | the install: `make doctor`, the code signature, the settings | `make doctor` ends with no FAIL; `codesign` shows `Identifier=<bundle id>` (`org.meetingcapture.app` unless you built with your own `MCAP_BUNDLE_ID`) and an ad-hoc or local-identity signature; `ENABLED_PLATFORMS=zoom,teams`; the login agent was **not** written yet |
| 2 | the macOS permissions, granted once to the app itself (`setup`, started with `open -n`) | every line is `[ OK ]` (Microphone, System Audio Recording, Notifications, the archive folder if it is in Google Drive); no Chrome prompt while Meet is off; a start from a plain shell prints `refused` |
| 3 | the real device test `selftest-capture --live` for the two tracks (3.1: AirPods and Bluetooth headsets, which switch sample rate when the microphone opens; 3.2: notifications `selftest-notify`: icon, text in the UI language, click opens the right folder) | verdict `PASS`, `remote_peak_window_db` above -50, about 12 seconds on both tracks; with a headset the remote track keeps a normal pitch and has no gaps; all six sample notifications show the app icon and open the folder or settings pane they promise |
| 4 | a Zoom call alone (new meeting): detection starts the recording after about 8 seconds, echo removal, your own speech kept, 60 seconds muted, recording ends about 32 seconds after you leave, the Zoom "Test Mic" false positive | a red dot while in the call; `transcript.md`, `audio.m4a`, `mic.m4a`, `remote.m4a`, `session.json` (and the note when Claude is used); your sentences almost as read, the YouTube voice under `Remote`, no echo in your lines; a Test Mic session with no speech is discarded |
| 5 | a Teams call alone (meet now): the same checks, and the main Teams risk, that muting drops the microphone input and ends the recording | the recording stays on for the whole 60 seconds of muting; it ends about 32 seconds after you leave |
| 6 | abnormal situations: Quit, `kill -9`, closing the lid while recording and while processing, switching audio devices, revoking the System Audio Recording permission, pause, manual recording, reprocess | nothing is lost: the session is closed with its `end_reason` (`app-quit`, `crash-recovered`, `sleep`) and processed after the restart; after the permission is revoked a notification says the remote audio looks silent after about 3 minutes |
| 7 | turning on the login agent (`make confirm-live-tested`, then `scripts/make_launchagent.sh --load`) and a log out and in | the agent is only written after you type the confirmations; the icon is back after login; a `kill -9` is restarted within about 30 seconds, Quit is not; the `claude` login is visible to the agent and no Keychain dialog appears |
| 8 | what to attach to a bug report | a script collects logs, the setup report, probe files and, per test call, `session.json`, `state.json` and transcript statistics. Never attach audio or the folder of a real meeting |
| 9 | the mute-aware microphone gate (`MIC_MUTE_GATE=on`, organisation mode): per app at least 10 calls | at least 95 percent of the muted seconds are recorded as exact zeros per app (Zoom, Teams, USB microphone), no signal means the microphone is recorded, and the manual Pause Microphone always works |
| A | Google Meet (optional, only when you enabled it): Chrome automation permission, lobby, join, leave, the known false positive when other media plays in a leftover Meet tab | `permission chrome-automation` is `[ OK ]`; recording starts about 8 seconds after joining and ends about 22 seconds after leaving |


자동 테스트(`make test`)는 장치도 권한도 쓰지 않는다. **실제 마이크, 시스템 오디오, macOS 권한 팝업이 필요한 확인은 전부 이 문서에서 직접** 한다.
**Google Meet 감지는 기본으로 꺼져 있다** (가장 덜 검증된 플랫폼이고 넓은 Chrome 자동화 권한이 필요하다. `ENABLED_PLATFORMS` 기본값 `zoom,teams`). 그래서 순서는 **Zoom 혼자 통화 -> Teams 혼자 통화**이고, Meet은 맨 끝 부록 A(선택)다.
각 단계는 **명령 / 기대 / 보낼 것** 순서다. 기대와 다르면 **거기서 멈추고** 지금까지의 자료를 8절대로 모아 이슈에 첨부한다.
감지 표(L-01..L-20)의 상세 근거와 판정 규칙은 `docs/DETECTION.md`에 있다.
9절의 **음소거 시험은 L-21..L-26**이다 (SPEC 18, 음소거 게이트). `docs/DETECTION.md` 10절도 L-21..L-23을 쓰고 있어 번호가 겹친다. 그쪽은 다른 시험(Zoom 대기 중 깜빡임, 마이크 없이 참가, Wi-Fi 25초 끊김)이므로 이 문서에서는 **9절 안의 L-21..L-26만 음소거 시험**을 뜻한다.

| 절 | 내용 | 시간 |
|---|---|---|
| 0 | 준비물, 셸 변수 | 5분 |
| 1 | 설치 점검 (`make doctor`, 서명, 설정) | 5분 (설치가 아직이면 +20분, 모델 다운로드 제외) |
| 2 | 권한 한 번에 허용 (`setup`): 마이크, 시스템 오디오 녹음, Google Drive, 알림 | 5분 |
| 3 | 장치 테스트 `selftest-capture --live` (환경 A, B) + 3.1 AirPods/블루투스 | 10분 + AirPods 10분 |
| 3.2 | 알림 점검: 아이콘, 내용(UI 언어), 클릭 (`selftest-notify`) | 5분 |
| 4 | **Zoom 혼자 통화** (새 회의) + 마이크 테스트 오탐 확인 | 20분 + 처리 시간 |
| 5 | **Teams 혼자 통화** (지금 회의) + 음소거 60초 | 15분 + 처리 시간 |
| 6 | 비정상 상황: Quit, `kill -9`, 덮개 닫기(녹음 중/처리 중), 장치 전환, 시스템 오디오 권한 끄기 | 30분 |
| 7 | LaunchAgent 켜기 + 로그아웃/로그인 | 15분 |
| 8 | **버그 리포트에 첨부할 것** | 5분 |
| 9 | **음소거 인식 마이크 캡처** (L-21..L-26: Zoom, Teams, USB 마이크, 신호 없음, 수동 Pause Microphone). 조직 모드(`MIC_MUTE_GATE=on`)의 선행 조건. **앱마다 통화 10회 이상** | 앱마다 통화 10회 x 회당 약 5분 (며칠에 나눠도 된다), 전체 3시간 안팎 + 처리 시간 |
| 부록 A | Google Meet (선택, 켠 경우만) | 20분 |

**덮개(노트북 뚜껑)**: 덮개를 닫으면 macOS는 잠자기에 들어가고, 그동안 녹음도 전사도 노트 생성도 **멈춘다** (외부 모니터+전원 연결 상태의 clamshell만 예외). 깨어나면 이어진다. 통화/처리 중에는 덮개를 닫지 않는다 (6절의 시험 제외).

## 0. 준비

- 터미널 탭 2개: **탭 A**는 명령 실행, **탭 B**는 `probe --watch` 출력을 보는 용도.
- 영어 연설/인터뷰 한 명이 5분 넘게 계속 말하는 YouTube 영상 하나 (상대방 `Remote` 역할, TED 강연 같은 것). 선택: 한국어 영상 하나 더.
- 통화는 **혼자** 한다 (Zoom은 New Meeting, Teams는 Meet now). YouTube는 별도 Chrome 창에서 재생한다.
- 환경 A = MacBook 스피커 + 내장 마이크 (시스템 설정 > 사운드 > 입력/출력을 MacBook Pro 마이크/스피커로). 환경 B = 회의용 스피커폰 (입력/출력을 그 장치로). 통화 시험은 **환경 A로** 하고, 환경 B는 3절과 4절 끝의 짧은 재시험에 쓴다.
- 아래 변수를 **각 터미널 탭에서 한 번** 붙여넣는다. (이후 명령이 이 변수를 쓴다.)

```bash
APP=~/Applications/CATE.app
SUP="$HOME/Library/Application Support/MeetingCapture"
LOGS=~/Library/Logs/MeetingCapture
PY="$SUP/venv/bin/python"
ARCHIVE="$(sed -n 's/^ARCHIVE_DIR=//p' "$SUP/config.env" | tail -1 | sed "s#^~#$HOME#")"; ARCHIVE="${ARCHIVE:-$HOME/Meetings}"     # where finished meetings go
PROJECT="$(sed -n 's/^PROJECT_DIR=//p' "$SUP/config.env" | tail -1 | sed "s#^~#$HOME#")"; cd "${PROJECT:-.}"     # the root of your clone: make install wrote its path as PROJECT_DIR
```

이 문서의 알림 문구는 한국어(`UI_LANGUAGE=ko`)로 적었다. 기본 설정(`UI_LANGUAGE=en`)에서는 같은 알림이 영어로 나온다 (예: `Meeting note is ready`). 한국어 문구로 시험하려면 `config.env`에 `UI_LANGUAGE=ko`를 넣고 앱을 다시 켠다.

- 통화 중 읽을 문장 (용어와 숫자가 들어 있다. **그대로 읽고**, 나중에 전사와 대조):

```
(1) 안녕하세요, ExampleCorp의 ExampleScan-CXR 팀입니다. 오늘은 API 연동이랑 KPI 일정에 대해 이야기할게요.
(2) The OKR review with Fabrikam-Health is on March twelfth. The budget is forty thousand dollars, about 3.5 percent over plan.
(3) Fabrikam-Health랑 Example Radiology 쪽 API 문서는 다음 주 목요일까지 검토하기로 했습니다. Contoso-Labs가 KPI 표를 보내 주기로 했고요.
(4) 숫자 확인: 1,234,567달러, 2026년 11월 18일 오후 3시 30분, PO 번호는 555-0100입니다.
(5) ExampleCorp.ai, ExampleScan-CT, Example Radiology, Fabrikam-Health, Contoso-Labs, API, KPI, OKR.
```

- 시각은 `date +%T`로 찍어 가며 메모한다 (입장, 음소거 시작/끝, 퇴장). 로그와 맞춰 볼 때 쓴다.
- 이 시험에서는 **LaunchAgent 없이 앱을 직접 켠다** (`open "$APP"`). LaunchAgent는 7절에서 마지막에 켠다.

## 1. 설치 점검

설치가 아직이면 (이미 했으면 건너뛴다). 인증서는 **직접** 실행한다 (macOS 대화상자가 뜰 수 있다: 로그인 암호는 **그 macOS 창에** 입력하고 **항상 허용**; 스크립트는 암호를 묻지도 읽지도 않는다. 종료 코드 3이면 출력된 설명을 읽고 `scripts/make_signing_identity.sh --trust`):

```bash
scripts/make_signing_identity.sh --dry-run && scripts/make_signing_identity.sh
scripts/install.sh --dry-run --python --with-silero --pre-download-model     # 계획과 다운로드 크기(정확한 바이트)
scripts/install.sh --require-signing --python --with-silero --pre-download-model
```

**명령** (이미 설치된 상태의 점검):

```bash
make doctor
codesign -dvvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature"
grep -E '^(CLAUDE_AUTH|CLAUDE_DAILY_BUDGET_USD|CLAUDE_MEETING_BUDGET_USD)' "$SUP/config.env"     # CLAUDE_AUTH=api(기본) = Console API 키로 과금, subscription = 본인의 Claude 로그인 (선택). 줄이 없으면 기본값 api
~/.local/bin/claude auth status          # subscription 모드의 로그인 확인 (api 모드에서는 캘린더 조회용 구독 로그인만 해당)
grep -E '^ENABLED_PLATFORMS' "$SUP/config.env"
ls ~/Library/CloudStorage
```

**과금 설정 확인**: 새로 설치되는 `config.env`는 `CLAUDE_AUTH=api`, 예산 `CLAUDE_DAILY_BUDGET_USD=5`와 `CLAUDE_MEETING_BUDGET_USD=2`, `CALENDAR_LOOKUP=0`으로 시작한다. **이미 있는 `config.env`는 설치가 덮어쓰지 않는다.** 줄이 없으면 코드 기본값이 쓰인다 (`CLAUDE_AUTH`는 `api`, 예산은 5와 2, `CALENDAR_LOOKUP`은 `auto`). `scripts/install.sh`는 `CLAUDE_AUTH` 줄이 없는 상태를 "CLAUDE_AUTH is not set, so the code default applies: API"로 알려 준다. 구독 로그인을 쓰려면(선택) 한 줄을 직접 넣는다. 이 도구는 사람이 없는 동안에도 `claude -p`를 돌리므로, 무인 사용이 계정 약관에서 허용되는지 먼저 확인한다 (README의 Anthropic and Claude 절):

```bash
printf '\nCLAUDE_AUTH=subscription\n' >> "$SUP/config.env"      # 이미 CLAUDE_AUTH 줄이 있으면 그 줄을 고친다
(cd pipeline && "$PY" -m mcap api-key status)     # 첫 줄이 "CLAUDE_AUTH=subscription"으로 시작하고 "does NOT use it"이어야 한다
```

**API 키 (`CLAUDE_AUTH=api`일 때, 직접 터미널에서 1회. 이미 저장했으면 건너뛴다)**: 키는 채팅/파일/로그에 붙여넣지 않는다. macOS `security` 도구가 터미널에서 직접 묻는다 (화면에 안 보임). Console에서 이 프로젝트 **전용 키**를 만들고 **월 지출 한도**를 먼저 걸어 둔다.

```bash
make set-api-key
(cd pipeline && "$PY" -m mcap api-key status)     # 값은 출력되지 않는다: 항목 유무, sk-ant- 접두사, 길이, 서비스 이름. 첫 줄이 "CLAUDE_AUTH=api: the pipeline uses it"여야 한다
(cd pipeline && "$PY" -m mcap api-key check)      # 아주 작은 호출 1회 (약 0.1센트). 직접 실행할 때만 호출한다 (doctor는 호출하지 않는다)
```

**기대**
- `make doctor`: FAIL 0 (config, venv, 모델 캐시 large-v3, Silero 모델, ARCHIVE_DIR 쓰기). api 모드면 `[PASS] api key`(Keychain에 있고 `sk-ant-` 접두사 정상, `validated: no`), `[PASS] billing mode: API key (Console credits)`, `[PASS] api budget`; 구독 모드면 `claude auth status`가 claude.ai 구독. WARN은 내용을 읽는다 (`calendar login` WARN = claude.ai 로그인이 없어 캘린더 조회를 조용히 건너뜀: 정상).
- `Authority=MeetingCapture Local Signing`, `Identifier=<bundle id>` (the id of your build: `MCAP_BUNDLE_ID`, default `org.meetingcapture.app`).
- `mcap api-key check` (api 모드): `API key OK`, `apiKeySource: ANTHROPIC_API_KEY`, 해석된 모델 id, `cost_usd`가 아주 작은 값 (콘솔의 사용량 화면에도 haiku 호출 1건이 보인다). `API key rejected`/`credit`이면 거기서 멈추고 보고. `apiKeySource`가 `ANTHROPIC_API_KEY`가 **아니면**(`billing_mode_violation`) 파이프라인의 api 가드는 실제 CLI의 값과 맞지 않는 것이니 **실제 회의 전에** 멈추고 보고한다 (그대로 두면 api 모드의 모든 호출이 비용만 쓰고 버려진다).
- 첫 `mcap api-key check` 뒤 (사용자가 직접, 불리언만 출력된다): `python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.claude.json"))); print(bool((d.get("customApiKeyResponses") or {}).get("approved")))'`가 `False`여야 한다. `True`이면 그 사실만 보고한다 (파일 내용은 붙여넣지 않는다): 이 프로젝트가 아니라 Claude CLI가 승인한 키의 끝부분을 자기 설정 파일에 남기는 경우다.
- `claude auth status`: `authMethod`가 `claude.ai` (구독 모드, 그리고 api 모드의 캘린더 조회).
- `ENABLED_PLATFORMS=zoom,teams` (줄이 없어도 기본값이 같다. `meet`이 들어 있으면 Meet이 켜진 것이니 부록 A를 읽는다).
- Google Drive를 보관 폴더로 쓰는 경우에만: `ls`에 `GoogleDrive-...`가 보인다 (Drive for desktop 실행 중). 기본 보관 폴더 `~/Meetings`는 로컬 폴더라서 Drive가 필요 없다.
- `install.sh`는 LaunchAgent plist를 **쓰지 않는다** ("not written: you have not confirmed the live test yet"). 7절 전에는 로그인해도 앱이 저절로 뜨지 않는다.

**보낼 것**: `make doctor` 출력 전체, `codesign` 세 줄, `make_signing_identity.sh`를 돌렸다면 종료 코드와 `--trust`가 필요했는지, `mcap api-key status`와 `mcap api-key check` 출력 (키 값은 출력되지 않는다. 그래도 보내기 전에 눈으로 확인).

## 2. 권한 한 번에 허용 (`setup`)

**명령** (**항상 `open -n`으로**: 권한 팝업이 터미널이 아니라 Catch Everything에 붙는다. `-n`이 없으면 이미 떠 있는 메뉴바 앱만 활성화되고 인자가 무시된 채 영원히 기다린다):

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args setup
```

**기대**
- 뜨는 프롬프트를 전부 **허용**: **마이크**, **시스템 오디오 녹음** (짧은 "띵" 소리가 나고 최대 15초 기다린다), **Google Drive 폴더**, **알림**. 알림을 거부하면 이후 경고/완료가 로그와 메뉴에만 남으니 허용한다 (시스템 설정 > 알림 > Catch Everything).
- **Chrome 자동화 프롬프트는 뜨지 않아야 한다** (Meet이 꺼져 있다: `permission chrome-automation: skipped`). 뜨면 `ENABLED_PLATFORMS`에 `meet`이 있는 것이다.
- 항목마다 `[ OK ]`. `[FAIL]`/`[WARN]`이면 바로 아래 `next:` 줄대로 하고 `setup`을 **다시** 실행한다 (시스템 오디오는 "허용"을 늦게 눌렀으면 무음 오류가 나므로 재실행).
- 확인: 시스템 설정 > 개인정보 보호 및 보안 > 마이크, 화면 및 시스템 오디오 녹음(시스템 오디오 녹음 전용)에 Catch Everything이 켜져 있다. 같은 내용이 `$LOGS/setup-report.txt`에 남는다.
- 터미널에서 바이너리를 직접 실행하면 `refused`가 나오는 것이 정상이다 (프롬프트를 엉뚱한 앱에 붙이지 않는 안전장치).

**보낼 것**: `$LOGS/setup-report.txt`, 처음 보는 팝업이 있었다면 그 문구.

## 3. 장치 테스트: `selftest-capture --live`

실제 마이크와 시스템 오디오 탭으로 두 트랙을 녹음한다 (앱이 스피커로 짧은 문장을 말해 remote 트랙을 채운다). **실제 회의 중에는 하지 않는다.** 말을 하면서 실행한다.

**명령** (환경 A, 노트북 스피커 + 내장 마이크):

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out ~/mcap-selftest
```

**기대**: 마지막에 `"verdict": "PASS"`, `remote_peak_window_db` > -50, `remote_seconds`와 `mic_seconds`가 약 12, `offsets`가 0 이상의 작은 값.

**환경 B (스피커폰)**: 입력/출력을 스피커폰으로 바꾸고 `--seconds 30`으로 같은 명령을 실행한다 (USB/블루투스 스피커폰이 기본 출력이면 먼저 내장 출력으로 클럭을 잡고, 10초 무음이면 다음 방식으로 바꾼다). 같은 기대. 로그도 본다:

```bash
grep -E "tap host strategy|tap format|first IO callback" "$LOGS/app.log" | tail
```

remote가 무음이면(`verdict: FAIL`) 방식을 고정해 본다: `open -n -W -a "$APP" --env MC_TAP_HOST=tap-only --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 30 --out ~/mcap-selftest` (값: `builtin | default | tap-only`). 어떤 값에서 PASS였는지 보낸다.
`~/mcap-selftest/selftest_*/`의 `remote.wav`를 QuickTime으로 열어 "띵/문장"이 들리는지 확인한다 (테스트 문장뿐인 파일).

**보낼 것**: JSON 전체 (A, B 각각). B는 `tap host strategy` 로그 줄과 PASS였던 `MC_TAP_HOST` 값.

## 3.1 AirPods / 블루투스 헤드셋 (샘플레이트 수정 확인)

**배경**: 개발 중의 AirPods 테스트에서 remote 트랙이 2배 빠르게(한 옥타브 위) 기록되고 0.21초 소리 / 0.21초 무음이 번갈아 나왔다 (`gaps(remote=28)`). 마이크가 열리면 AirPods가 통화용 프로파일(24kHz)로 바뀌는데 탭은 "48kHz"라고만 보고했기 때문이다. 수정: 실제 전달 속도를 호스트 시계로 측정해 그 속도에서 변환하고(처음 약 0.5초는 확인 때문에 늦게 쓰일 뿐 사라지지 않는다), 블루투스 출력이면 탭의 클럭을 내장 출력으로 잡고, 통화 중 프로파일 전환이 오면 다시 측정한다.

**준비**: AirPods를 끼고 시스템 설정 > 사운드에서 **입력과 출력 모두 AirPods**로 둔다. 말하면서 실행한다 (앱이 `say` 문장을 AirPods로 재생한다; 마이크가 열려 있어 소리가 평소보다 낮은 음질로 들리는 것은 정상이다). 변수(`$APP`, `$LOGS`, `$PY`)는 0절에서 정한 것이다.

**명령 A (자동 선택 = 새 기본 동작: 블루투스이면 내장 출력이 클럭)**:

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out "$HOME/mcap-selftest"
```

**명령 B (예전에 실패한 구성을 일부러 재현: AirPods 자신의 클럭에 고정)**: `--env`는 `--args` **앞에** 쓴다 (`open --env NAME=VALUE`는 이 Mac의 `man open`에서 확인한 철자다).

```bash
open -n -W --env MC_TAP_HOST=default -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out "$HOME/mcap-selftest"
```

**명령 C (선택: 내장 출력으로 고정, 자동 전환 없음)**: B와 같고 `MC_TAP_HOST=builtin`.

**결과 확인** (각 실행 뒤):

```bash
LATEST="$(ls -dt "$HOME"/mcap-selftest/selftest_*/ | head -1)"; echo "$LATEST"
grep -E "tap host strategy|tap host policy|system audio: rates|delivered rate verified|effective rate|rebuilding capture|recorder: stopped|rate measurement|measured delivered rate|unusable stamps" "$LOGS/app.log" | tail -30
(cd pipeline && "$PY" -m mcap transcribe-file "$LATEST/remote.wav" --language en)     # remote 트랙만 로컬 Whisper로 (Claude 호출 없음)
```

`remote.wav`를 QuickTime으로도 들어 본다 (목소리가 정상 속도/음높이이고 소리가 끊기며 번갈아 나오지 않아야 한다).

**기대**
- **A**: `"verdict": "PASS"`, `remote_seconds` 약 12, `remote_peak_window_db` > -50. app.log: `tap host strategy built-in-output (first choice for this output device)`, `tap host policy: the default output is a Bluetooth device ...`, `delivered rate verified ... 48000 Hz`, 마지막 `recorder: stopped ... gaps(mic=0 remote=0)`. JSON의 `devices.remote`에 `[tap host: built-in output]`. `warnings`에 `effective rate` 줄이 없거나(내장 클럭이 48kHz) 정확히 1개. 전사에 "Meeting Capture Audio Test" 문장이 거의 그대로 나온다.
- **B**: `"verdict": "PASS"`, `remote_seconds` 약 12, `warnings`에 **정확히 1개** `system audio: effective rate 24000 Hz differs from tap format 48000 Hz: resampling from 24000 ...` (16000일 수도 있다), app.log에 `delivered rate verified ...: 24000 Hz`와 `HAL figures now: ...` (aggregate nominal/actual 값이 이 줄에 나온다), stop 줄 `gaps(mic=0 remote=0)` (수정 전에는 `remote=28`), 전사 정상. 이 실행이 수정 ①을 증명한다.
- **A에서 remote가 무음**(`verdict: FAIL`, `remote track is silent`)이면 "내장 클럭 탭이 AirPods로 가는 소리도 잡는다"는 가정이 이 Mac에서 틀린 것이다. 그때는 `--seconds 30`으로 A를 다시 실행한다 (10초 무음이면 자동으로 AirPods 자신의 클럭 -> tap-only 순으로 바꾼다). 어느 방식에서 PASS였는지, 위 `grep` 출력을 보낸다.
- 어느 실행이든 `gaps(remote=N)`에서 N이 3 이상이거나 `sample-rate mismatch` 경고가 나오면 (측정이 놓친 경우) 그대로 보낸다.
- 정상 장치(MacBook 스피커 + 내장 마이크, 환경 A와 같은 경우)에서는 `effective rate` 경고나 `measured delivered rate changed` 줄이 **없어야** 한다. 있으면 측정이 멀쩡한 장치를 잘못 보정한 것이므로 그 줄들을 그대로 보낸다 (같은 그래프에서 6번 바뀌면 자동으로 장치가 말한 속도로 돌아가고 `kept changing its mind` 경고가 하나 남는다).

**통화 중 전환 시험 (선택, 5분)**: A로 `--seconds 40`을 실행하는 동안 시스템 설정 > 사운드에서 출력을 MacBook 스피커로 바꿨다가 다시 AirPods로 바꾼다. 기대: app.log에 `rebuilding capture (...)`와 새 `delivered rate verified`, remote 타임라인이 끊기지 않음(`remote_seconds` 약 40).

**보낼 것**: 각 실행의 JSON 전체 (A, B, 선택 C), 위 `grep` 출력 (app.log 줄 전부: `tap host policy`, `system audio: rates`, `delivered rate verified`, `effective rate`), `mcap transcribe-file` 출력, 목소리가 정상이었는지 예/아니오, FAIL이었다면 어떤 `MC_TAP_HOST` 값에서 PASS였는지.

## 3.2 알림 점검: 아이콘, 내용, 클릭

메뉴바 아이콘이 노치나 메뉴바 정리 앱(Vorssaint 등)에 가려져 있어도 알림으로 확인할 수 있어야 한다. 알림에는 **(1) Catch Everything 아이콘** (파란 둥근 사각형, 흰 파형, 빨간 점), **(2) 한국어 제목 / 부제 / 본문**, **(3) 클릭하면 열리는 것**이 있어야 한다. 앱을 새로 설치한 뒤(아이콘이 번들에 들어갔다) 한 번 확인한다.

**명령** (진짜 알림 6개를 띄운다. 부제가 `[테스트]`로 시작한다. 셸에서 바이너리를 직접 실행하면 `refusing to run`이 나오는 것이 정상이고, 반드시 `open -n`):

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args selftest-notify --wait 90
```

**기대** (2초 간격으로 6개가 뜬다. 터미널에 각 줄이 `delivered`로 끝난다. 알림이 안 뜨면 시스템 설정 > 알림 > Catch Everything이 꺼져 있는 것이다):

| 알림 (제목) | 부제 / 본문에 있어야 할 것 | 클릭하면 |
|---|---|---|
| `회의록이 준비됐어요` | 부제 `[테스트] 주간 제품 회의`, 본문 `Zoom · 32분 녹음 · 클릭하면 폴더가 열립니다` | Finder: 회의 보관 폴더 (`ARCHIVE_DIR`) |
| `회의록 생성 실패` | 부제 `전사본·녹음은 안전하게 보관됨`, 본문 `Claude 사용 한도...` + `mcap reprocess` 안내, **소리** | Finder: 보관 폴더 |
| `상대방 소리가 녹음되지 않는 것 같아요` | 혼자 발표 / 시스템 오디오 권한 / AirPods, **소리** | 시스템 설정: 시스템 오디오 녹음 (못 열면 개인정보 보호 및 보안) |
| `녹음을 시작하지 못했어요` | 부제 `시스템 오디오 녹음 권한이 필요해요`, **소리** | 시스템 설정: 시스템 오디오 녹음 |
| `녹음 시작 · Zoom` | `메뉴바 아이콘이 가려져 있어도 이 알림으로 확인할 수 있어요` | Finder: `sessions` 폴더 |
| `녹음 종료 · 전사 시작` | 부제 `Zoom · 32분` | Finder: `sessions` 폴더 |

- **모든 배너에 아이콘이 있어야 한다** (빈 회색 아이콘이면 안 된다). 앱이 떠 있는 중에도 배너가 뜬다.
- 알림 하나를 클릭할 때마다 아래 중 하나가 보인다: 이 터미널에 `click received (pid N): openFolder` (이 실행이 받은 경우), 또는 **이미 떠 있는 메뉴바 앱이 대신 받은 경우** `grep "notification clicked" "$LOGS/app.log" | tail -5`의 `notification clicked: openFolder <경로>` 줄. 어느 쪽이든 폴더나 설정 창이 열려야 한다. 클릭해도 아무 줄도 없으면 클릭 처리기가 설치되지 않은 것이다 (`grep "click handler installed" "$LOGS/app.log" | tail -2`가 있어야 한다).
- 안전: 앱은 `ARCHIVE_DIR`, `sessions`, `LOG_DIR` 안의 폴더와 로그, 그리고 정해진 설정 창만 연다. 그 밖의 경로나 알 수 없는 동작은 열지 않고 `notification clicked: ... rejected (...)`만 남긴다.
- **업데이트 전에 이미 알림센터에 쌓여 있던 알림은 계속 클릭해도 아무 일도 없다.** 그것들은 클릭 대상 없이 (옛 빌드로) 보내졌다. 점검 전에 알림센터에서 Catch Everything 알림을 모두 지우고 (알림 그룹의 X / 모두 지우기), 위 명령으로 새로 띄운 것만 본다. 새 알림을 클릭해도 `notification clicked:` 줄이 없다면 그때 문제다.
- 아이콘이 계속 빈 아이콘이면: 설치(`scripts/install.sh`)가 Launch Services에 이 앱을 다시 읽게 했는지 로그에서 `Launch Services re-read`를 보고, 그래도 같으면 **로그아웃 후 로그인**한다 (알림센터가 아이콘을 캐시한다). 그다음 이 점검을 다시 한다.

**실제 상황에서** (각 절의 시험 중에 같이 본다):
- 4절 Zoom 혼자 통화: 시작할 때 `녹음 시작 · Zoom`, 끝나고 약 30초 뒤 `녹음 종료 · 전사 시작`, 처리가 끝나면 `회의록이 준비됐어요`. 끄려면 `$SUP/config.env`에 `NOTIFY_RECORDING=0` 한 줄 + 앱 재시작 (시작/종료 알림만 사라지고 경고와 결과는 계속 온다).
- 6절 시스템 오디오 권한 끄기: 약 3분 뒤 `상대방 소리가 녹음되지 않는 것 같아요`. 마이크 권한을 끄고 통화를 시작하면 `녹음을 시작하지 못했어요` (마이크 설정이 열린다).

**보낼 것**: 위 터미널 출력 전체, `grep -E "notification (\(|clicked|not delivered|action)|click handler" "$LOGS/app.log" | tail -30`, 6개 각각 "아이콘 보임 / 내용 한국어 / 클릭하면 열림"을 예/아니오로 (열린 것이 무엇이었는지), 가능하면 배너 스크린샷.

## 4. Zoom 혼자 통화 (L-01..L-09, L-19)

**준비**: 탭 B에서 감지 신호를 파일로 남기면서 본다 (`open`으로 시작한 watch는 Ctrl-C로 못 끈다: `--minutes`가 지나면 끝나거나 `pkill -f 'probe --watch'`). 그다음 **앱을 직접 켠다** (메뉴바에 `Idle`).

```bash
mkdir -p ~/mcap-feedback; : > ~/mcap-feedback/probe-zoom.txt
open -n -W -a "$APP" --stdout ~/mcap-feedback/probe-zoom.txt --stderr ~/mcap-feedback/probe-zoom.txt --args probe --watch --interval 1 --minutes 30 &
tail -f ~/mcap-feedback/probe-zoom.txt          # 탭 B
open "$APP"                                      # 탭 A: 메뉴바 앱 시작 (LaunchAgent 아님)
```

**진행** (탭 A에서 시각 메모, Zoom에서 통화). 한 번에 약 8분이다:

| 시각 | 하는 일 | 기대 결과 |
|---|---|---|
| T0 | Zoom을 켠 채 통화 없이 30초 (L-02) | `zoom ... udp 0`, `inCall=no`, 녹음 안 함 |
| T1 | **New Meeting**, **컴퓨터 오디오로 참가** (L-01) | 약 8초 뒤 메뉴바에 빨간 점 + `Recording mm:ss`. probe: `udp >= 1`(보통 4~6), `via=udp`. 메인 pid에 0이고 `child` 행에 소켓이 있으면 어느 child인지 기록. `app.log`: `detect: zoom inCall false->true` |
| T1~+30초 | 혼자 문장 (1), (2) 읽기. YouTube는 아직 꺼 둠 | (이 구간은 나만 말함: 내 전사의 기준선) |
| T2 | 별도 창에서 YouTube 재생 시작 (평소 회의 볼륨). **30초 동안 나는 가만히** | 나중에 mic 트랙에 **상대 음성이 에코 텍스트로 남으면 안 됨** (에코 제거 시험) |
| T2+30초 | YouTube가 계속 나오는 중에 문장 (3) 읽기 (동시 발화) | 나중에 (3)이 전부 `SELF_NAME` 라벨로 남아야 함 (에코 제거가 내 발화를 지우면 안 됨) |
| T3 | Zoom에서 **음소거 60초**, 해제 (L-03). YouTube는 계속. 음소거 중에 문장 (4) 읽기 | 녹음 계속(`Recording`). probe에서 `in`이 음소거 중에도 1인지 기록. 음소거해도 내 마이크 트랙은 계속 녹음된다 -> (4)가 `SELF_NAME` 라벨로 전사될 것으로 예상 |
| T4 | YouTube 정지, 문장 (5) 읽고 30초 침묵 | 침묵 중에도 `Recording` 유지 |
| T5 | (선택) 비디오 끔/켬, 화면 공유 시작/종료 (L-05) | 새 `child` 행 이름 기록 |
| T6 | **Leave** 후 End Meeting (L-04). 시각을 정확히 메모 | 약 32초 뒤 녹음 종료(Zoom은 유예 최소 30초). **기록**: probe의 `udp 4 -> 0`, `in 1 -> 0`이 나온 시각 (`probe-zoom.txt`에 시각과 함께 남는다). `in=1`이 남으면 구버전 Zoom 마이크 점 버그 |
| T7 | Zoom > 설정 > 오디오 > **마이크 테스트** (통화 아님) 30초 (L-08) | 오탐 확인: `in=1 udp=0`이면 세션이 시작될 수 있다 (알려진 오탐). 시작되면 메뉴 `Stop Recording Now`로 끝낸다: 발화가 없어 `sessions/_discarded`로 폐기돼야 하고 노트가 생기면 안 됨 |

- 선택 (한 번만): T7에서 시작된 세션을 **그대로 둔다**. 두 트랙이 −70 dBFS 아래(사실상 디지털 무음)로 `NO_SPEECH_STOP_MINUTES`(기본 15분) 이어지면 `stop (no-speech)` 로그와 함께 정상 종료·보존된다. **마이크가 방 소음을 잡고 있으면 이 기준에 걸리지 않아 종료되지 않는 것이 정상이다** (그 경우 세션은 Zoom 신호가 끝나면 끝난다). 어느 쪽이었는지 보고한다 (`grep -E "stop \(no-speech\)" "$LOGS/app.log"`). 빨리 보려면 `$SUP/config.env`에 `NO_SPEECH_STOP_MINUTES=2`를 한 줄 넣고 앱을 다시 켠 뒤 시험하고, 끝나면 그 줄을 지운다.
- 선택 (상대 필요): 대기실, 소회의실, Wi-Fi 10초 끊기 -> 30초 유예 안이면 `stop`이 나오면 안 됨 (L-07, L-09). 컴퓨터 오디오 없이 참가 -> `udp >= 1`이면 `in=0`이어도 녹음 (L-19).
- 중간 확인 (탭 A): `grep -E "meeting candidate|start: zoom|recording started|detect: zoom inCall" "$LOGS/app.log" | tail -5`. 종료 후: `grep -E "stop \(|recording stopped" "$LOGS/app.log" | tail -3` -> `stop (meeting-ended): ...`, `recording stopped: <id> reason=meeting-ended duration=...` (duration이 실제 통화 시간 + 약 30초 유예).
- 환경 B에서 **짧게 재시험**: 입력/출력을 스피커폰으로 바꾸고 New Meeting, 문장 (1), (2), YouTube 30초 + 문장 (3), Leave. 아래 4.1대로 읽는다. `remote.device`의 `[tap host: ...]`도 기록한다: `python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["tracks"]["remote"]["device"])' "<세션 폴더>/session.json"`.

### 4.1 결과 읽기 (Teams 통화 뒤에도 같은 방식)

처리는 통화 종료 약 30초 뒤 시작된다. 메뉴: `Transcribing ...` -> `Creating note` -> `Done`, 그리고 **macOS 알림 `회의록이 준비됐어요`** (부제 = 회의 제목, 클릭하면 회의 폴더가 열린다). `Done`이 뜬 시각을 메모한다 (1시간 회의 약 10~20분 예상; 8분 통화는 훨씬 짧다). 메뉴 `Open Meeting Folder`로 Drive 폴더를 연다.

```bash
LAST="$(ls -dt "$ARCHIVE"/*/*/ | head -1)"; echo "$LAST"; ls -la "$LAST"
PLOG="$(ls -t "$LOGS"/pipeline-*.log | head -1)"; tail -40 "$PLOG"
```

기대 파일: `transcript.md  transcript.json  transcript.cleaned.md  transcript.cleaned.json  meeting-note.md  meeting-note.draft.md  audio.m4a  mic.m4a  remote.m4a  session.json` (정리/검증 패스를 껐다면 cleaned/draft는 없다). 로그 마지막 줄은 `DONE: <폴더>`.

```bash
cat "$LAST/session.json"
grep -E "echo suppressed|aec" "$PLOG"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("aec"));print({k:d.get(k) for k in ("echo_suppressed","dropped","speech_seconds")})' "$LAST/transcript.json"
diff "$LAST/transcript.md" "$LAST/transcript.cleaned.md" | head -40
grep -c '^## ' "$LAST/meeting-note.md"
diff "$LAST/meeting-note.draft.md" "$LAST/meeting-note.md"
grep -E "claude attempt|note verified|cleanup:" "$PLOG"
grep -E "chunks, .* segments kept" "$PLOG"
(cd pipeline && "$PY" -m mcap usage --days 1); cat "$SUP/overage.json" 2>/dev/null
```

| 확인 | 어디서 | 기대 |
|---|---|---|
| 세션 | `session.json` | `end_reason: "meeting-ended"`, tracks에 `remote`/`mic`, `start_offset_sec` >= 0, `platform: zoom`(Teams는 `teams`). `remote_silent_suspected`가 없거나 false (YouTube를 틀었는데 true면 보고). `warnings`가 비어 있거나, 있으면 그 내용을 그대로 보고 |
| 내 발화 | `transcript.md`의 `SELF_NAME`(기본 `Me`) 블록 | (1)~(5)가 거의 그대로. **용어 철자**(ExampleCorp, ExampleScan-CXR, ExampleScan-CT, Fabrikam-Health, Contoso-Labs, Example Radiology, API, KPI, OKR ...)와 **숫자** (3.5, 1,234,567, 2026년 11월 18일, 555-0100). 틀린 것을 적어 둔다 |
| 한영 혼용 | (1), (3)의 영어 용어 | 라틴 문자로 남음 ("에이알리드" 같은 음차는 오류) |
| 상대 | YouTube 내용 | `Remote`로 전사 |
| **에코** | T2 구간(내가 가만히 있던 30초)의 `SELF_NAME` 줄, 위 `echo suppressed`/`aec` 로그 | `SELF_NAME` 줄이 없음 (상대 문장을 거의 그대로 반복한 줄이 없음) |
| **내 발화 보존** | T2+30초 구간의 (3) | 전부 `SELF_NAME` 라벨로 남음. **지워졌으면 최우선 보고** |
| AEC 통계 | 위 python 출력의 `aec` | 환경 A: `applied: true`와 `coherence`, `delay_ms`, `erle_db` 값을 기록. 환경 B(스피커폰의 하드웨어 AEC): auto가 건너뛰어 `applied: false`일 수 있음 (그것도 기록). `aec`는 항상 객체다. `applied: false`면 `reason`/`error`를 그대로 보고 |
| VAD | `chunks, ... segments kept` 줄의 `vad` | `vad silero` (`vad energy`면 Silero 모델을 못 찾은 것: `make doctor`의 silero 항목과 `$SUP/models/silero_vad.onnx` 확인). 트랙마다 한 줄 (mic, remote) |
| 음소거 중 발화 | 문장 (4)가 `SELF_NAME` 줄에 있는가 | 있으면 "음소거해도 마이크 트랙은 녹음된다"가 확인된 것 (아키텍처상 예상, 기록) |
| 정리본 | `diff transcript.md transcript.cleaned.md` | 용어/음차만 바뀜 (예 "에프디에이"->FDA). **숫자/날짜는 원문과 동일.** `transcript.md`(원본)는 수정되지 않았다 |
| 노트 | `meeting-note.md` | 제목 7개(`grep -c` = 7), 참석자는 지어내지 않음(`Not identified ...`), 결정/담당자/기한을 만들지 않음, 숫자 그대로. 맨 아래 주석에 모델(`claude-opus-...`), effort, 검증 요약 |
| 검증 패스 | `meeting-note.draft.md`와 `meeting-note.md`의 diff | 근거 없는 항목이 제거/표시됨. 검증이 거부되면 draft가 최종본이고 `state.json`에 warning |
| Claude 사용 | `mcap usage`(= `$SUP/usage.jsonl` 요약), `overage.json` | 호출마다 한 줄 (세션, 단계, 모델, 소요시간, `isUsingOverage`, `auth`, `cost_usd`). 회의당 호출 수가 `MAX_CLAUDE_CALLS_PER_MEETING`(기본 30) 아래. 구독 모드에서 초과 사용이 보이면 기록만 하고 계속 (기본값) |
| **비용 (api 모드)** | `mcap usage`의 `Claude cost in USD`, Console의 사용량 화면 | cleanup/note/verify 줄은 `auth: api`와 `cost_usd`(0보다 큼), 캘린더 줄만 `auth: subscription`. 이 통화 한 번의 합계를 적고 Console 사용량과 같은 자릿수인지 대조. **오탐 세션(예: 마이크 테스트)도 말이 있으면 transcript가 Claude로 가서 돈이 든다.** 일일/회의 예산(`mcap doctor`의 `api budget`)이 줄어든 만큼 보인다 |
| 제목 | 폴더 이름 | 캘린더 일정이 있으면 그 제목(회의 시작 ±45분 일정만 조회), 없으면 창 제목/플랫폼 (한글 폴더명이 Drive에서 정상 동기화되는지) |
| Drive | Drive 앱 | 폴더가 올라가고 숨김 `.partial` 폴더가 남지 않음 |
| 알림 | macOS 알림 센터 | `Meeting note ready: <제목>` 알림이 떴다 |

**보낼 것**: 위 표의 각 항목에 대한 예/아니오 + 틀린 용어/숫자 목록, 입장/음소거/퇴장/녹음 시작·종료/`Done` 시각, **플래그가 내려간 시각** (`udp`, `in`), 8절의 폴더.

## 5. Teams 혼자 통화 (L-06, L-20)

**준비**: 4절과 같은 명령으로 `probe-teams.txt`를 새로 만들고 `probe --watch`를 시작한다 (`--minutes 25`). 앱은 켜 둔 채.

**진행**: Teams > **Meet now** (혼자). 한 번에 약 6분:

| 시각 | 하는 일 | 기대 결과 |
|---|---|---|
| T0 | 사전 입장 화면(마이크 미터)에서 10초 | 아직 녹음 안 함 (또는 입력만 보이고 시작 안 함) |
| T1 | **입장** (컴퓨터 오디오). 문장 (1), (2) 읽기 | 약 8초 뒤 `Recording`. probe `FAMILY PROCESSES`에서 입출력을 쥔 프로세스(`com.microsoft.teams2` 본체인지 `.helper`인지), `TEAMS` 릴레이 포트(3478-3481) 소켓 수, `Microsoft Teams Audio` 장치 상태를 기록 |
| T2 | YouTube 30초 재생 + 문장 (3) 읽기 | 4절 T2와 같은 에코/보존 시험 |
| T3 | **음소거 60초**, 문장 (4) 읽기, 해제 | **이 단계가 Teams의 핵심 위험이다**: Teams가 음소거 중 마이크 입력을 놓으면 입력 신호가 사라지고, 유예(최소 30초)가 지나 약 32초 뒤 **통화 도중에 녹음이 끝날 수 있다.** 기대: 60초 내내 `Recording` 유지. 중간에 처리 상태로 바뀌면 **그 즉시 시각과 함께 보고** (감지 보정이 필요하다). 음소거 중 `in` 값이 어떻게 변했는지 `probe-teams.txt`에서 확인 |
| T4 | 문장 (5) 읽고 퇴장. 시각 메모 | 퇴장 후 약 32초에 종료. 신호가 꺼지는 시각 기록 |

- 선택 (상대 필요): 걸려 온 전화 벨소리만 울리고 거절 -> `out=1`, `in=0`: **세션이 시작되면 안 됨** (L-20).
- 결과는 4.1대로 읽는다 (`platform: teams`).

**보낼 것**: `probe-teams.txt`, T3 구간의 `app.log`, 음소거 중 녹음이 유지됐는지 예/아니오와 시각, 4.1의 표 항목.

## 6. 비정상 종료, 절전, 장치 전환, 권한 해제

**녹음 중** 항목은 Zoom 혼자 통화를 시작하고 1분 뒤에 한다. 이 절은 LaunchAgent 없이 하므로 **자동 재시작은 7절에서** 확인하고, 여기서는 `open "$APP"`로 직접 다시 켠다.

| 상황 | 하는 일 | 기대 결과 |
|---|---|---|
| **Quit** | 녹음 중 메뉴 Quit | 앱 종료. `session.json`이 `end_reason: "app-quit"`로 닫힘. `open "$APP"`로 다시 켜면 시작 점검(`startup scan: enqueue ...`)이 그 세션을 처리한다 |
| **kill -9** | 녹음 중 `pkill -9 -fx "$APP/Contents/MacOS/CATE"` (인자 없는 메뉴바 앱만 정확히 죽인다), 그다음 `open "$APP"` | 로그: `crash recovery: ... closed at ...s of audio`, `repaired the WAV header`, 이어서 `startup scan: enqueue`. 세션이 `end_reason: crash-recovered`로 처리되어 전사/노트가 생긴다. 통화가 계속 중이면 새 세션이 하나 더 시작된다 |
| **덮개 닫기 (녹음 중)** | 녹음 중 덮개를 닫고 20초 뒤 연다 | 로그 `system will sleep: stopping recording`, 세션은 `end_reason: sleep`으로 보존되어 처리됨. 통화가 아직 있으면 깨어난 뒤 새 세션. (덮개를 닫은 동안은 녹음이 없다: macOS가 잠들기 때문) |
| **덮개 닫기 (처리 중)** | 4절의 회의가 끝난 뒤 메뉴 `Reprocess Last Meeting`으로 처리를 시작하고, 메뉴가 `Transcribing`일 때 덮개를 닫고 **2분** 뒤 연다. (선택, 길게: 점심시간처럼 **90분 이상**) | 깨어난 뒤 처리가 이어져 `Done`이 되거나, 죽었다면(깨어 있던 시간으로 90분 무반응) 한 번 다시 큐에 들어가고, 또 죽으면 **retryable 실패로 표시**되어 `Meeting processing failed` 알림이 뜨고 `RETRY_SWEEP_HOURS`(기본 6) 안에 자동 재시도된다 (`retry sweep:` 로그). **아무 표시 없이 멈춰 있으면 안 된다.** 확인: `grep -E "system did wake|wake from sleep|stall watchdog|retry sweep" "$LOGS/app.log" | tail`, 수동 재시도는 `cd pipeline && "$PY" -m mcap reprocess --pending` |
| **장치 전환** | 녹음 중 출력/입력을 MacBook <-> 스피커폰으로 바꾼다 (USB를 꽂거나 뽑기) | 로그 `rebuilding capture (...)`, `tap host strategy ...`. remote.wav 타임라인이 끊기지 않고(무음으로 메워짐) 나중 전사에서 시간이 맞음 |
| **시스템 오디오 권한 끄기** | 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 > 시스템 오디오 녹음 전용에서 Catch Everything을 **끄고**, Zoom 혼자 통화를 **4분** 한다 (YouTube를 틀어 두고, 문장 몇 개를 읽는다: 마이크 쪽에는 소리가 있어야 한다) | 약 3분 뒤 **macOS 알림 `Remote audio looks silent`**, 메뉴에 같은 내용(해결: 시스템 오디오 권한), 통화가 끝난 뒤 `session.json`에 `"remote_silent_suspected": true`와 `warnings`. 처리된 노트가 the user 쪽만 있어도 알림이 먼저 알려 준 셈이어야 한다. **끝나면 다시 켜고** 2절의 `setup`을 다시 실행한다 |
| **Pause** | 녹음 중 메뉴 Pause Auto Recording | 녹음이 정상 종료되어 처리됨. Resume 전에는 자동 시작 없음 |
| **수동 녹음** | 회의 없이 Start Recording Now, 20초 말하고 Stop | 세션 `platform: manual`이 처리됨 (발화가 거의 없으면 폐기되고 `sessions/_discarded`로) |
| **Reprocess** | 완료 후 메뉴 Reprocess Last Meeting | 노트만 다시 만들어짐 (원본 `transcript.md` 불변). 녹음 중에는 메뉴가 비활성 |

**보낼 것**: 각 상황의 결과 (특히 kill -9 후 `crash recovered` 로그, 덮개 닫기 뒤 세션 개수와 `end_reason`, 처리 중 덮개 닫기의 최종 상태, 권한을 끈 뒤 **알림이 실제로 떴는지 예/아니오와 문구**), 예상과 다른 메뉴 문구/팝업/알림 (스크린샷은 개인 정보가 없는 것만).

## 7. LaunchAgent 켜기 + 로그아웃/로그인

LaunchAgent는 **마지막에** 켠다. `install.sh`와 `make_launchagent.sh`는 아래 확인(`make confirm-live-tested`) 전에는 plist를 쓰지도 로드하지도 않는다.

**명령**

```bash
# 직접 켠 앱은 메뉴바에서 Quit 한다. 그다음:
make confirm-live-tested                       # setup 보고서에 [FAIL]이 없는지 확인하고, 녹음 법적 고지를 보여 준 뒤 yes와 'confirmed'를 입력하라고 묻는다
scripts/make_launchagent.sh --dry-run --load   # plist와 launchctl 명령만 출력
scripts/make_launchagent.sh --load
pgrep -fl "CATE.app/Contents/MacOS/CATE"
```

**기대**
- `confirm-live-tested`는 터미널에서 직접 입력해야 하고, 2절의 `setup`과 3절의 `selftest-capture --live`가 끝난 뒤에만 의미가 있다. 확인 없이 `--load`를 하면 "live test not confirmed"로 멈춘다.
- 몇 초 안에 메뉴바에 아이콘(`waveform`)과 `Idle`. macOS가 "백그라운드 항목이 추가됨" 알림을 띄우면 시스템 설정 > 일반 > 로그인 항목에서 Catch Everything을 켠다.
- 메뉴 항목을 한 번씩 확인: Pause/Resume Auto Recording, Start/Stop Recording Now, Open Meeting Folder, Reprocess Last Meeting, Open Logs, Quit.
- **kill -9 자동 재시작**: `pkill -9 -fx "$APP/Contents/MacOS/CATE"` -> 최대 약 30초 뒤 저절로 다시 뜬다. 메뉴 Quit은 다시 뜨지 않는다 (의도).
- **로그아웃 -> 로그인** (터미널을 열지 않는다): 로그인 후 메뉴바 아이콘이 저절로 떠 있다. 바로 Zoom 혼자 통화 2분 -> 처리 완료 -> 4.1의 표. 특히 `claude attempt 1: model=opus ... resolved=claude-opus-...`에 "Not logged in"이 없어야 한다 (LaunchAgent 환경에서 `claude`가 로그인 상태), Drive가 로그인 직후 아직 안 올라온 경우의 게시 결과(성공 또는 `archive unavailable` 후 자동 재시도).
- api 모드: 로그인 후 첫 처리에서 `claude attempt 1: ... auth=api`가 보이고 **`API key not found in the Keychain`/Keychain 허용 대화상자가 없어야 한다** (LaunchAgent 환경에서 `/usr/bin/security`가 키를 프롬프트 없이 읽는다). 대화상자가 뜨면 **항상 허용**하지 말고 먼저 보고: 키 항목의 접근 권한 문제다.
- 다른 터미널에서 `make doctor`도 한 번 (LaunchAgent 환경과 결과 비교).

**보낼 것**: `confirm-live-tested`/`--load` 출력, 로그인 직후 `app.log`의 첫 30줄, 로그인 후 통화의 4.1 결과, kill -9 재시작에 걸린 시간.

## 8. 버그 리포트에 첨부할 것

**오디오 파일(wav/m4a)은 올리지 않는다.** 전사본과 노트에는 회의 내용이 들어 있다. 이 체크리스트의 **테스트 통화(혼자 + YouTube)** 폴더는 그대로 올려도 되지만, **실제 회의 폴더는 올리지 않는다** (필요하면 이름/금액을 가리고 해당 줄만 올린다). 로그에는 회의 제목과 전사 조각이 들어 있을 수 있으니 올리기 전에 `LOG_CONTENT=0`으로 바꿔 다시 재현하거나 내용을 가린다. 아래 스니펫이 파일을 한 폴더에 모은다. 각 `<세션 폴더>`는 4.1의 `$LAST`다.

```bash
OUT=~/mcap-feedback/$(date +%Y%m%d-%H%M); mkdir -p "$OUT"
# 로그 (회의 코드는 가린다)
sed -E 's#meet\.google\.com/[a-z0-9-]+#meet.google.com/XXX#g' "$LOGS/app.log" > "$OUT/app.log"
cp "$LOGS/setup-report.txt" "$OUT/" 2>/dev/null
for f in $(ls -t "$LOGS"/pipeline-*.log | head -3); do cp "$f" "$OUT/"; done
cp ~/mcap-feedback/probe-*.txt "$OUT/" 2>/dev/null
# 테스트 통화 폴더마다 (이름을 붙인다: zoomA, zoomB, teams)
NAME=zoomA; LAST=<세션 폴더>
mkdir -p "$OUT/$NAME"
cp "$LAST"/{session.json,state.json,transcript.md,transcript.cleaned.md,meeting-note.md,meeting-note.draft.md,calendar.json} "$OUT/$NAME/" 2>/dev/null
python3 - "$LAST/transcript.json" > "$OUT/$NAME/transcript.stats.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["segment_count"] = len(d.pop("segments", []))     # 텍스트 없는 통계(aec, dropped, speech_seconds, stats ...)
print(json.dumps(d, indent=1, ensure_ascii=False))
EOF
ls -la "$LAST" > "$OUT/$NAME/files.txt"
tail -n 40 "$SUP/usage.jsonl" > "$OUT/usage.tail.jsonl" 2>/dev/null
(cd pipeline && "$PY" -m mcap usage --days 1) > "$OUT/usage.summary.txt" 2>&1
(cd pipeline && "$PY" -m mcap api-key status) > "$OUT/api-key.status.txt" 2>&1      # 키 값은 출력되지 않는다
cp "$SUP/overage.json" "$OUT/" 2>/dev/null
echo "$OUT"; open "$OUT"
```

메모해서 함께 보낼 것 (텍스트로): 각 절의 **보낼 것**에 적은 항목, 그리고 처음 보는 팝업/알림 문구, 1절의 `make_signing_identity.sh` 결과 (종료 코드, `--trust` 필요 여부, 지정 요구사항 줄).
문제가 있어 중간에 멈췄다면: 멈춘 절 번호, 마지막으로 실행한 명령과 출력 전체, `$LOGS/app.log`의 해당 시각 앞뒤 30줄.

## 9. 음소거 인식 마이크 캡처 (L-21..L-26, 조직 모드의 선행 조건)

`MIC_MUTE_GATE=on`이면 앱이 마이크 샘플을 0.5초 지연선에 거쳐 파일에 쓰고, **음소거 신호가 확실한 동안** `mic.wav`에 정확한 0을 기록한다 (타임라인, 파일 길이, `start_offset_sec`는 그대로다). 신호를 모르면 **기록한다** (fail-open). 신호원은 셋이다:

| 신호 | 이름 | 무엇을 보나 | 상태 |
|---|---|---|---|
| 입력 장치 | `device` | 입력 장치의 음소거 스위치(`kAudioDevicePropertyMute`)나 입력 볼륨 0. 권한 불필요 | 장치마다 다름 (속성이 없으면 신호 없음) |
| 회의 앱 | `app` | 통화 중 그 앱의 `IsRunningInput`이 **켜졌다가 꺼짐**. 켜진 것을 본 적이 없으면 신호 없음 | **미검증: 앱마다 다름. 이 절이 재는 것** |
| 수동 | `manual` | 메뉴 `Pause Microphone` | 항상 보장되는 경로 |

`MIC_MUTE_GATE`가 off(개인 설치의 기본)이면 4절과 5절의 "음소거해도 마이크 트랙은 계속 녹음된다"는 기대가 그대로다. 아래 시험은 on으로 바꿨을 때의 이야기다.

기기 없이 되는 부분(상태기계, 0 구간, 길이와 offset, `session.json`, 사이드카)은 `make test-swift`가 이미 확인한다 (`selftest-capture --synthetic`의 내장 음소거 스크립트. 환경변수 `MC_SELFTEST_MUTE_SCRIPT="1.6-3.0,4.4-5.2"`로 구간을 바꿀 수 있다). 이 절은 **실제 Zoom/Teams/장치에서 신호가 오는지**를 잰다. 통화는 **혼자** 하는 시험 통화이고 실제 회의 내용은 쓰지 않는다.

**합격 기준** (SPEC 18, 음소거 게이트): 호출 앱별로 **통화 10회 이상**에서 **음소거한 초의 합계 95% 이상이 0**으로 기록된다. 단위는 에피소드가 아니라 **통화**다: 한 통화 안의 에피소드는 같은 참가 상태, 같은 앱 버전, 같은 입력 열림 상태를 공유하므로 통화 한 번에 에피소드를 12번 해도 1회로 센다 (통화마다 달라지는 것을 보려는 기준이다). 10회보다 적게 합격시키는 것은 아래 9.4의 관리자 결정이고 참석자 고지 문구의 조건과 함께 바꾼다. 기준 미달이거나 신호가 없는 앱이 있으면 그 앱은 "음소거 인식 캡처가 보장되지 않는다"이고, 소유자가 9.4의 결정을 한다. 이 결과가 "음소거 중에는 기록하지 않는다"는 참석자 고지 문구를 쓸 수 있는지와 조직 파일럿 범위를 정한다.

### 9.1 준비

```bash
grep -E '^MIC_MUTE_GATE' "$SUP/config.env" || printf '\nMIC_MUTE_GATE=on\n' >> "$SUP/config.env"   # 개인 설치의 기본은 off. 시험하는 동안만 on
# 앱을 Quit 하고 다시 켠다: open "$APP"
mkdir -p ~/mcap-feedback
```

**기대**: 메뉴를 열면 `Pause Microphone` 항목이 **보인다** (`MIC_MUTE_GATE`가 off이면 항목 자체가 없다). 녹음 중이 아니면 회색이다. 녹음이 시작되면 `app.log`에 `mic_gate=on`이 찍힌다 (`grep "mic_gate=on" "$LOGS/app.log" | tail -1`). 시험이 끝나면 그 줄을 지우고(또는 `off`) 앱을 다시 켜서 원래대로 돌린다 (유지할지는 9.4의 결정이다).

**에피소드 기록기** (탭 C): 음소거를 누르는 **순간** Enter, 해제를 누르는 순간 Enter. 한 손은 Zoom/Teams 버튼, 다른 손은 Enter다. 줄마다 시각이 쌓이고 홀수 줄이 음소거 시작, 짝수 줄이 해제다. 통화가 끝나면 Ctrl-C.

```bash
MUTELOG=~/mcap-feedback/mute-NAME-01.txt; : > "$MUTELOG"      # NAME = zoom, teams, usb, ...   01..10 = 통화 번호 (통화마다 새 파일)
python3 -c '
import sys, datetime
for _ in sys.stdin:
    print(datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3], flush=True)
' | tee "$MUTELOG"
```

**한 통화의 진행** (앱마다 같다): 혼자 통화. 앱마다 **통화 10회 이상**, 통화마다 새로 참가한다 (같은 통화를 길게 끄는 것은 1회다). 한 통화에서 **에피소드 3회**: 길이 30초, 60초, 30초, 에피소드 사이는 30초 이상 풀어 둔다 (손으로 누르는 시각 오차가 길이의 몇 %를 넘지 않게 긴 에피소드로 한다). 통화마다 **1회는 말하는 도중에** 누른다 (문장 중간에 음소거). **음소거 중에는 쉬지 말고 숫자를 크게 센다** ("일, 이, 삼 ..."), **풀어 둔 구간에서는 문장 (1)~(5)** 를 읽는다. `probe --watch`(4절의 탭 B)도 같이 돌려 두면 `in`이 음소거 중에 어떻게 변했는지 남는다.

**통화 사이에 조건을 바꾼다** (통화 10번이 같은 상태의 반복이면 1회를 10번 본 것이다): 앱을 Quit 하고 다시 켠 뒤의 첫 통화를 포함하고, 입력 장치(내장 마이크, 헤드셋)를 바꾼 통화를 포함하고, 하루에 몰지 말고 적어도 이틀에 나눈다. Zoom/Teams의 버전은 그 앱의 정보 화면에서 보고 적어 둔다 (통화 도중에 앱이 갱신되면 그 통화부터 새 버전이다).

**통화가 끝나고 `Done`이 뜨면** (4.1의 `$LAST`를 구한 다음 한 줄씩 쌓는다. 9.3의 합계가 이 파일을 읽는다):

```bash
printf '%s\t%s\n' "$LAST" "$MUTELOG" >> ~/mcap-feedback/calls-NAME.tsv      # 세션 폴더, 그 통화의 에피소드 기록 파일 (탭으로 나눈다)
```

### 9.2 시험 항목

| ID | 하는 일 | 기대 결과 | 이 항목의 합격 |
|---|---|---|---|
| **L-21** | **Zoom**: New Meeting, 컴퓨터 오디오로 참가. 9.1의 통화를 **10회** (통화마다 에피소드 3회). 앱 안의 음소거 버튼(또는 Alt+A)으로 | `probe`에서 `in`이 음소거 중 0이 되는가를 기록. 에피소드마다 사이드카에 span이 생기고 `mic_gate.signals`에 `app`이 있다 | 9.3의 합계가 **95% 이상**, 통화 10회 이상 |
| **L-22** | **Teams**: Meet now, 혼자. 같은 통화 10회. (5절의 알려진 위험: Teams가 음소거 중 입력을 놓으면 감지가 통화를 끝낼 수 있다. 5절의 T3 결과와 같이 읽는다) | 같은 형태. `FAMILY PROCESSES`의 입력을 쥔 프로세스가 음소거 중 어떻게 바뀌는지 기록 | 9.3의 합계 **95% 이상**, 통화 10회 이상 |
| **L-23** | **Meet** (부록 A를 켠 경우만. 아니면 "건너뜀"으로 적는다): 혼자 통화, 같은 통화 10회 | 같은 형태. Meet의 가족은 Chrome 전체라서 다른 탭이 마이크를 쓰면 신호가 `unmuted`로 남을 수 있다: 그 사실을 기록 | 9.3의 합계 **95% 이상**, 통화 10회 이상 (아니면 "신호 안 됨"으로 기록) |
| **L-24** | **USB 마이크/헤드셋의 하드웨어 음소거**: 입력을 그 장치로 바꾸고 `Start Recording Now`. 장치의 **음소거 버튼**으로 녹음 10회 (같은 요령: 녹음마다 에피소드 3회). 버튼이 없는 장치면 시스템 설정 > 사운드 > 입력의 **입력 음량을 0**으로 내리는 것으로 대신한다 (그렇다고 적는다) | 사이드카 span의 `signals`가 `device`. 앱 신호 없이도 0이 된다 | 9.3의 합계 **95% 이상**, 녹음 10회 이상. 장치가 음소거 속성을 내놓지 않으면 `mic_gate.signals`에 `device`가 없다: 그 장치는 "신호 없음"(L-25)으로 기록 |
| **L-25** | **신호 없음 = 기록 (fail-open)**: (a) `Start Recording Now`(수동 녹음: 앱 신호 없음)로 Zoom에서 음소거 30초 동안 숫자 세기. 입력은 음소거 속성이 없거나 읽히지 않는 장치로 (있으면. 없으면 이 항목은 앱 신호 없음만으로 한다). (b) 같은 통화에서 **음소거하지 않은** 구간의 문장 (1)~(5) 전체 | (a) `mic.wav`가 **0으로 끊기지 않고** 음소거 중 숫자까지 기록된다 (신호가 없으므로 기록하는 것이 맞다). `mic_gate.signals`에 `app`이 없다, `unknown_seconds`가 통화 길이에 가깝다 (장치가 "음소거 아님"으로 답하면 그만큼 줄어든다). 어떤 신호도 한 번도 답하지 않았을 때는 `session.json`의 `warnings`에 `recorded in full (fail-open)`이 있다. (b) 음소거하지 않은 구간은 **한 글자도 0이 되지 않는다** (오탐 없음) | (a)(b) 둘 다. 음소거하지 않은 말이 0이 되면 **즉시 보고** (오탐은 회의 손실이다) |
| **L-26** | **수동 `Pause Microphone`**: 통화(Zoom)에서 앱 음소거는 **하지 않고** 메뉴 `Pause Microphone` / `Resume Microphone`으로 통화 10회 (같은 요령: 통화마다 에피소드 3회, Enter는 메뉴를 누르는 순간) | 상태줄이 `... · 마이크 일시중지`로 바뀌고 항목이 `Resume Microphone`(체크)이 된다. 사이드카 `signals`가 `manual`. 재개 직후 첫 단어가 남는다 | 9.3의 합계 **95% 이상** (이 경로는 보장되는 길이므로 사실상 99% 이상이어야 한다), 통화 10회 이상. 미달이면 수동 경로 자체의 결함이니 **즉시 보고** |

### 9.3 결과 읽기

통화가 끝나면 처리가 시작된다. 4.1의 `$LAST`(세션 폴더)로 `session.json`을 본다:

```bash
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d.get("mic_gate"),indent=1));print([w for w in d["warnings"] if "mic mute gate" in w])' "$LAST/session.json"
ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_id"])' "$LAST/session.json")"; echo "$ID"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1])).get("mute_spans",[]);print(len(d),"spans");[print(s) for s in d[:20]]' "$SUP/session-private/$ID.json"
```

**기대**: `mic_gate`는 정확히 `enabled`, `signals`(답한 신호의 이름: `app`, `device`, `manual`), `muted_seconds`, `unknown_seconds`다. **구간(span)은 `session.json`이 아니라 `$SUP/session-private/<session_id>.json`에만 있다** (Drive로 가지 않는다). `muted_seconds`는 0으로 기록한 초이고 에피소드마다 0.3초 안팎의 소급(backdate)이 더해진다.

`unknown_seconds`는 **어떤 신호도 답하지 못한 초**다. 장치가 "음소거 아님"이라고 답하는 것도 답이므로, 앱 신호가 오는지는 `signals`에 `app`이 있는지와 아래 합계로 판단한다 (`unknown_seconds`가 0이라고 앱 신호가 된다는 뜻이 아니다).

**합계 계산** (에피소드 기록기 파일과 사이드카를 맞춘다. 기록기 시각은 통화 날짜의 로컬 시각이다). **앱마다, 그 앱의 통화 10회 이상을 전부 한 번에** 돌린다: 인자는 통화마다 `세션파일 기록파일` 쌍이고, 통화가 끝날 때마다 쌓은 `calls-NAME.tsv`에서 만든다. 마지막 줄이 **통화 수**를 세고, 통화가 10회 미만이면 퍼센트가 얼마든 `FAIL`이다 (한 통화의 에피소드를 아무리 늘려도 1회다):

```bash
args=(); while IFS=$'\t' read -r dir log; do args+=("$dir/session.json" "$log"); done < ~/mcap-feedback/calls-NAME.tsv      # NAME = zoom, teams, usb, ...
python3 - "${args[@]}" <<'PY'
import sys, json, os, datetime
tot_muted = tot_zero = tot_wrong = 0.0
episodes = 0
calls = set()                                     # a call counts when its click log holds at least one complete episode
args = sys.argv[1:]
if not args or len(args) % 2:
    sys.exit("arguments are pairs: <session folder>/session.json <click log> (one pair per call)")
for sj_path, log_path in zip(args[0::2], args[1::2]):
    sj = json.load(open(sj_path))
    side = json.load(open(os.path.expanduser("~/Library/Application Support/MeetingCapture/session-private/%s.json" % sj["session_id"]))).get("mute_spans", [])
    start = datetime.datetime.fromisoformat(sj["start_time"])
    off = sj["tracks"]["mic"]["start_offset_sec"]
    stamps = []
    for line in open(log_path):
        line = line.strip()
        if line:
            t = datetime.datetime.strptime(line, "%H:%M:%S.%f").time()
            stamps.append((datetime.datetime.combine(start.date(), t, tzinfo=start.tzinfo) - start).total_seconds() - off)   # seconds of mic.wav
    muted = list(zip(stamps[0::2], stamps[1::2]))
    if muted:
        calls.add(sj["session_id"])
    def overlap(a, b, c, d): return max(0.0, min(b, d) - max(a, c))
    for i, (a, b) in enumerate(muted, 1):
        zero = sum(overlap(a, b, s["start"], s["end"]) for s in side)
        first = min((s["start"] for s in side if overlap(a, b, s["start"], s["end"]) > 0), default=None)
        print("%s episode %2d: muted %5.1f s, zeroed %5.1f s (%5.1f %%), first zero %s" % (sj["session_id"][:16], i, b - a, zero, 100 * zero / max(b - a, 1e-9),
              "-" if first is None else "%+.2f s after the click" % (first - a)))
        tot_muted += b - a; tot_zero += zero; episodes += 1
    all_zero = sum(s["end"] - s["start"] for s in side)
    tot_wrong += max(0.0, all_zero - sum(overlap(a, b, s["start"], s["end"]) for (a, b) in muted for s in side))
pct = 100 * tot_zero / max(tot_muted, 1e-9)
print("TOTAL: %d calls, %d episodes, %.0f s muted, %.0f s zeroed = %.1f %%  (zeroed while NOT muted: %.1f s)" % (len(calls), episodes, tot_muted, tot_zero, pct, tot_wrong))
print("PASS" if len(calls) >= 10 and pct >= 95 else "FAIL (needs >= 10 calls and >= 95 %%: %d calls, %.1f %%)" % (len(calls), pct))
PY
```

**기대**: 에피소드마다 `first zero`가 `-0.3 s`쯤(소급 0.3초) 또는 0 근처이고, `%`가 95 이상. `first zero`가 클수록 신호가 늦은 것이다 (예: `+0.8 s`면 누르고 0.8초 뒤에야 0이 시작된다: 앞 0.8초의 말이 기록됐다). `zeroed while NOT muted`는 에피소드당 0.5초 안팎(소급과 해제 지연)이어야 한다. 훨씬 크면 오탐이다. (눌러서 Enter를 치는 손의 오차가 0.2~0.4초라서 에피소드는 길게 한다: 30초 에피소드에서도 1~3% 정도는 측정 오차다.)

선택 (오디오로 한 번 확인): 처리된 `mic.m4a`에서 span 구간이 정말 무음인지 `afconvert -f WAVE -d LEI16 "$LAST/mic.m4a" /tmp/mic-check.wav` 뒤 그 구간의 최댓값을 본다 (m4a는 압축이라 정확히 0이 아니라 -60 dBFS 아래면 무음으로 본다). 정확한 0은 `make test-swift`가 이미 확인한다.

### 9.4 판정과 결정

| 결과 | 의미 | 결정할 것 (관리자) |
|---|---|---|
| L-21, L-22(와 쓰는 앱) 모두 **합격** (앱마다 **통화 10회 이상**, 합계 95% 이상), L-25 합격 | 그 앱에서는 음소거 인식이 기준을 만족한다 | 조직 기준 강제값 `MIC_MUTE_GATE=on` 유지. 참석자 고지에 "음소거하면 기록되지 않는다"고 쓰려면 **그 앱에 한해** 쓴다. 개인 설치는 off 유지를 권장 |
| 어떤 앱이 **미달** (95% 미만, 통화가 10회 미만, 또는 `app` 신호가 안 옴) | 그 앱의 음소거는 신호로 잡히지 않는다. 신호가 없으면 **기록된다** | 대체 경로를 고른다: (a) 수동 `Pause Microphone`을 절차로 삼고 **파일럿 범위를 제한**(그 앱 제외, 또는 호스트가 Pause를 쓰는 회의만), (b) v2에서 접근성 API로 Zoom/Teams의 음소거 버튼을 읽기(앱마다 새 권한 프롬프트: SPEC 13.1에서 창 제목 읽기에는 거부했던 권한이다). 음소거가 기록되지 않는다는 문구는 그 앱에 쓰지 않는다 |
| **L-25(b) 오탐** (음소거하지 않은 말이 0이 됨) | 게이트가 회의 내용을 잃는다 | 조직 기준 강제값을 올리지 말고 **즉시 보고**. 앱 신호만 끄는 방법은 코드 변경이다 |
| **L-26 미달** | 수동 경로의 결함 | 즉시 보고 (이 경로가 보장되는 길이다) |
| **통화 10회보다 적게** 시험하고 합격으로 하려는 경우 (예: 한 통화에 에피소드 12회) | 기준이 약해진다: 한 통화의 에피소드는 같은 참가 상태, 같은 앱 버전, 같은 입력 열림 상태를 공유해서 통화 사이의 차이를 보여 주지 못한다 | **관리자가 명시적으로 결정**하고 이 표와 참석자 고지의 조건(앱별 10회)에 같이 적는다. 적지 않으면 10회 미만은 미달이다 |

조직의 파일럿은 이 절의 결과가 기록되고 위 표의 결정이 내려진 뒤에 시작한다. '내부 참석자만'과 고지 문구는 기술로 강제할 수 없으므로 관리자와 법무의 결정이다 (고지 문구는 법률 자문을 받는다).

**보낼 것**: L-21..L-26 각각의 합격/불합격과 위 `TOTAL` 줄 (앱별: 통화 수가 보인다) 그리고 앱별 `calls-NAME.tsv`와 Zoom/Teams 버전, 에피소드 목록(`first zero` 줄들), `mic_gate` 출력 (앱마다 한 번), `probe-*.txt`의 음소거 구간(`in`의 변화), 처음 보는 팝업/알림, 상태줄의 `마이크 일시중지` 문구가 보였는지.

---

## 부록 A. Google Meet (선택: 켠 경우만)

Meet은 기본으로 꺼져 있다. 쓰고 싶을 때만 켠다. Meet을 켜면 Chrome 탭 주소를 읽기 위해 **Chrome 자동화 권한**(브라우저 전체에 대한 Apple Events 허용)이 추가로 필요하다.

```bash
open -e "$SUP/config.env"        # ENABLED_PLATFORMS=zoom,teams,meet 로 바꾼다 (한 줄)
# 앱을 Quit 하고 다시 켠다: open "$APP"  (또는 scripts/make_launchagent.sh --load)
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args setup     # Chrome 자동화 프롬프트가 이제 뜬다: 허용 (Chrome을 먼저 켜 둔다)
```

기대: `permission chrome-automation`이 `[ OK ]`. 다시 끄려면 `ENABLED_PLATFORMS=zoom,teams`로 되돌리고 앱을 다시 켠다 (Chrome 탭 조회는 그 순간부터 일어나지 않는다).

**통화** (4절의 변수/`probe` 명령에서 파일명만 `probe-meet.txt`로). `meet.google.com/new` 혼자 통화, 환경 A:

| 시각 | 하는 일 | 기대 결과 |
|---|---|---|
| T0 | 로비에서 10초 (L-10) | Chrome `in=1 out=0`, 아직 녹음 안 함 |
| T1 | **참여** (L-10, L-17) | 약 8초 뒤 `Recording`. `app.log`: `detect: meet inCall false->true conf=high [... tier=HIGH ...]`. 탭 조회 `ok` |
| T1~T4 | 4절 T1~T4와 같은 문장/YouTube/음소거 60초 (L-03) | 녹음 유지, 음소거 중 `in` 기록 |
| T6 | **나가기(Leave)**. 시각 메모. Meet 탭은 **60초 그대로 둔다** (L-12, L-13) | 퇴장 후 약 22초에 처리 상태로. 새 녹음이 시작되면 안 됨 |
| T7 | 탭 닫기, 60초 | 새 세션 없음 |

- **오탐 시험 (L-11, 중요)**: Meet를 나간 뒤 **남은 탭을 닫지 않고** YouTube / YouTube Music(PWA 포함)을 재생한다 -> 약 8초 뒤 MEDIUM 세션이 시작되면 알려진 한계가 실제로 확인된 것이다 (정크 세션). 확인 후 Pause로 끝내고 세션 폴더를 지운다. 시작되면 **즉시 보고** (감지 보정 필요).
- **L-16 (Automation 거부)**: 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Catch Everything의 Chrome 항목을 끈 뒤 Meet 통화 -> `tab query: automation-denied`, 근거에 `tier=LOW`, 제목/URL 없이도 마이크+출력이 동시에 있으면 녹음 시작. 다시 켜고 `ok` 확인.
- 선택: Meet PWA/시크릿 창/두 번째 Chrome 프로필 입장 -> 탭 목록에 보이는가 (L-15). 2명 이상 통화에서 말 없는 1분 -> 녹음 유지 (L-14). 연속 회의 분리: 통화 중 다른 탭에서 새 회의에 참여하고 첫 회의는 나간다 -> 약 20~32초 뒤 `split: meeting changed (<코드1> -> <코드2>)` 로그와 함께 세션이 둘로 나뉜다 (`grep -E "split:|stop \(|start: meet" "$LOGS/app.log" | tail`).
- 결과는 4.1대로 읽는다 (`platform: meet`, `meeting_url`/`title_hint` 포함). 보낼 것: 위 항목의 예/아니오와 `probe-meet.txt`.
- 판정 규칙(결과를 보고 `evaluateMeet` 등을 바꾸는 기준)은 `docs/DETECTION.md` 맨 끝에 있다.
