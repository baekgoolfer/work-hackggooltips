# Catch Everything (CATE)

Catch Everything(짧은 이름: CATE)은 통화에 들어가면(Zoom, Teams, Slack 허들·Webex·Discord·FaceTime 같은 다른 통화 앱, 켜 두었다면 Google Meet) 자동으로 감지해서 내 마이크와 통화 소리를 Mac에서 녹음하고, 로컬 Whisper로 전사하고, Claude로 회의록을 만들어 내가 정한 폴더에 저장하는 macOS 메뉴바 앱입니다. 녹음 버튼은 없습니다. 통화에 들어가면 시작하고 나오면 끝납니다.

[English README](README.md) | [설치 안내](docs/INSTALL.md) | [개인정보와 동의](docs/PRIVACY_AND_CONSENT.md) | [기여하기](CONTRIBUTING.md) | [보안](SECURITY.md)

> **상태: 실험 단계 (0.2.0).** 한 사람이 Apple silicon Mac 한 대(macOS 26)에서 만들고 써 본 도구입니다. 실제 통화로 확인한 것은 Zoom 감지뿐이고 그 환경에서만 확인했습니다. Teams, Google Meet, 다른 통화 앱, 다른 macOS 버전, 다른 오디오 환경은 실제 통화로 확인하지 않았습니다. 지원을 약속하지 않습니다. 아래 "제한 사항"을 먼저 읽어 주세요.

> **이름.** 제품 이름은 Catch Everything이고, CATE는 짧은 이름이자 앱 파일 이름(`CATE.app`)입니다. 데이터 폴더, 로그 폴더, Keychain 항목은 내부 이름 MeetingCapture를 그대로 씁니다(`~/Library/Application Support/MeetingCapture`, `~/Library/Logs/MeetingCapture`, "MeetingCapture Anthropic API key" 같은 Keychain 서비스). 이것들은 제품 이름이 아니라 경로와 식별자이고, 바꾸면 이미 있는 데이터가 고아가 되기 때문입니다. 다른 이름으로 빌드한 복사본(`MCAP_APP_NAME`, `MCAP_APP_SHORT_NAME`, [앱의 이름과 식별자](docs/CONFIGURATION.md#names-and-identifier-of-the-app))은 앱 파일 이름이 다르니, 아래 명령의 `CATE.app` 자리에 그 이름을 쓰세요.

## 법적 고지: 이 도구는 다른 사람의 음성을 녹음합니다

Catch Everything은 Mac이 재생하는 소리(통화의 모든 상대방)와 내 마이크를 녹음합니다. **회의 앱에서 음소거해도 마이크는 계속 녹음됩니다.** 앱은 소리나 표시를 내지 않고 상대방에게 아무것도 알리지 않으며, Zoom, Teams, Meet의 녹화 기능을 쓰지 않으므로 그 앱들도 "녹화 중" 표시를 띄우지 않습니다.

많은 나라, 지역, 조직에서 대화 상대에게 알리지 않거나 동의를 받지 않고 녹음하는 것은 불법이거나 정책 위반입니다. 규칙은 다릅니다. 한 쪽 동의와 모든 당사자 동의, 직장과 개인정보 관련 법, GDPR 같은 개인정보 보호법, 건강정보 등 민감정보 규정, 회의 플랫폼과 소속 회사의 약관이 모두 관련될 수 있습니다. 식별 가능한 사람의 녹음, 전사본, 회의록은 개인정보입니다.

적용되는 규칙을 알고 지키는 일, 필요한 경우 참석자에게 알리고 동의를 받는 일, 파일을 합법적으로 보관, 공유, 삭제하는 일, 몰래 녹음하는 데 쓰지 않는 일은 전적으로 사용자의 책임입니다. 계약과 정책이 허용하지 않는 한 규제 대상이거나 기밀인 내용(건강정보, 고객 비밀)이 있는 회의에는 쓰지 마십시오. 전사 텍스트, 회의 제목, 용어 목록, (켠 경우) 캘린더 정보가 Anthropic의 Claude로 가고, 선택 기능인 음성 인식 엔진은 오디오를 다른 서버로 보낼 수 있습니다 ([무엇이 Mac 밖으로 나가는지](docs/PRIVACY_AND_CONSENT.md)).

이 고지는 일반 정보이며 법률 자문이 아닙니다. 변호사에게 문의하십시오. 소프트웨어는 있는 그대로 제공되며 보증이 없고 저작자는 책임을 지지 않습니다 (Apache License 2.0 제7조, 제8조).

## 하는 일

```
통화 감지 (Zoom, Teams, 다른 통화 앱, 켠 경우 Meet)
  -> 트랙 두 개를 녹음: 시스템 오디오("Remote")와 내 마이크(SELF_NAME 라벨, 기본값 "Me")
  -> 통화가 끝나면 Mac 안에서: 마이크 트랙 에코 제거, 발화 구간 검출,
     로컬 Whisper(mlx-whisper large-v3) 전사, 환각 필터 -> transcript.md
  -> 선택: 내 Claude 계정이나 API 키로 용어 정리, 회의록, 회의록 검증
  -> 완성된 폴더를 ARCHIVE_DIR/YYYY-MM/YYYY-MM-DD_HHMM_<제목>/ 으로 이동
```

기본 설정에서 음성 인식은 Mac 밖으로 나가지 않고, 오디오는 Claude로 보내지 않습니다. 실패해도 오디오와 transcript는 지워지지 않습니다. 노트만 실패하면 transcript는 남고 다시 돌리면 됩니다.

## 요구사항

- Apple silicon Mac(M1 이상), macOS 14.4 이상, **RAM 16 GB 이상 권장**(회의를 전사하는 동안 음성 모델이 약 4 GB를 씁니다). Intel Mac은 지원하지 않습니다.
- Xcode **Command Line Tools** (`xcode-select --install`). Xcode 전체는 필요 없습니다 (`swiftc`로 직접 빌드).
- **Python 3.12 또는 3.13 필수** (고정한 패키지는 3.13에서 확인했고, 고정한 numpy와 scipy는 3.11 이하에 설치되지 않습니다. macOS나 Command Line Tools가 주는 `python3`에 기대지 말고 직접 설치하세요). `scripts/setup_python.sh`가 `python3.13`, 다음으로 `python3.12`를 Homebrew, python.org 프레임워크, `/usr/local/bin`, `PATH` 순으로 찾습니다. 다른 인터프리터는 `MCAP_PYTHON=/path/to/python3.13`으로 지정합니다. 스크립트는 Python이나 Homebrew 패키지를 대신 설치하지 않습니다.
- **본인의 Claude 접근**: Anthropic API 키(기본이자 지원되는 방식, `CLAUDE_AUTH=api`) 또는 선택 사항으로 로그인된 Claude 구독, 그리고 직접 설치한 `claude` 명령(Claude Code). 없어도 오디오와 transcript는 만들어집니다. 개인 설치에서는 `setup`이 `claude`가 없거나 로그인되지 않은 것을 실패가 아닌 경고로 표시하므로 자동 시작이 막히지 않습니다. transcript만 원하면 `config.env`에 `LOCAL_ONLY_DEFAULT=1`을 두세요(아니면 회의마다 노트 단계를 시도하고 실패하면 transcript만 남깁니다).
- 디스크: Python 환경 약 0.55 GB, 음성 모델 3.08 GB, 1시간 회의당 임시 오디오 약 0.7 GB (게시 후 삭제).
- 선택: Google Drive for desktop. 보관 폴더는 아무 폴더나 됩니다. Chrome은 Google Meet 감지를 켤 때만 필요합니다.

## 빠른 시작

내 손이 가는 시간은 약 10분이고 다운로드(약 3.6 GB)가 따로 걸립니다. 먼저 위의 법적 고지를 읽으십시오. 각 명령의 설명은 [영어 README](README.md#quick-start)와 [docs/INSTALL.md](docs/INSTALL.md)에 있습니다.

```bash
# 복제 주소는 이 저장소 페이지에 나오는 HTTPS 주소입니다
git clone -b catch-everything https://github.com/baekgoolfer/work-hackggooltips.git meeting-capture
cd meeting-capture
make install ARGS="--dry-run --python --with-silero --pre-download-model"   # 계획만 본다
make install ARGS="--python --with-silero --pre-download-model"             # 설치. 먼저 녹음 법적 고지를 보여 주고 yes 입력을 받는다 (터미널이 없으면 ARGS에 --accept-legal-notice를 더해 명시적으로 동의)

open -e ~/Library/Application\ Support/MeetingCapture/config.env            # ARCHIVE_DIR, SELF_NAME 확인. CLAUDE_AUTH=api가 기본(subscription은 선택), CALENDAR_LOOKUP=0이 예시 파일의 값(캘린더를 보지 않음)

make set-api-key                                                            # CLAUDE_AUTH=api(기본) 일 때: 키를 Keychain에 1회 저장
claude auth login                                                           # 선택 사항인 CLAUDE_AUTH=subscription 일 때만

open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args setup
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out "$HOME/mcap-selftest"
make doctor
```

그다음 앱을 직접 켜고(`open ~/Applications/CATE.app`) Zoom 혼자 통화, Teams 혼자 통화로 시험합니다 ([docs/LIVE_TEST.md](docs/LIVE_TEST.md), 영어 요약은 [docs/LIVE_TEST.en.md](docs/LIVE_TEST.en.md)). 잘 되면 로그인 때 자동 시작을 켭니다. 이때부터는 **내가 참여하는 모든 통화가 녹음되므로** 일부러 확인 단계를 거칩니다.

```bash
make confirm-live-tested                 # 법적 고지를 다시 보여 주고 yes와 'confirmed'를 직접 입력 (터미널 필요)
scripts/make_launchagent.sh --load       # 위 확인 전에는 거부된다
```

### 디스크 이미지로 설치 (개발 환경이 없는 분을 위해)

앱을 직접 빌드해서 개발 도구가 없는 사람에게 복사본을 건네려면 `make dmg`로 파일 하나, `CATE-<버전>.dmg`(볼륨 이름은 "Catch Everything")를 만듭니다. 이 안에 `CATE.app`이 들어 있고, 앱 안에 파이프라인, 설치 도우미, Python 런타임이 있습니다. 받은 사람은 `CATE.app`을 Applications로 끌어다 놓고 엽니다. 앱은 빌드한 사람이 직접 만든 자체 서명 인증서로 서명하며 Apple 공증을 받지 않았으므로 처음 한 번 macOS 경고가 뜹니다(Control-클릭 > 열기, 또는 시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기). 첫 실행에서 앱이 터미널의 안내형 설치(다운로드 약 4 GB)를 제안합니다. 0.2.0 버전을 빌드한 파일은 GitHub 릴리스 [cate-v0.2.0](https://github.com/baekgoolfer/work-hackggooltips/releases/tag/cate-v0.2.0)에 `.sha256` 파일과 함께 올라가 있습니다. 둘을 같은 폴더에 받아 `shasum -a 256 -c CATE-0.2.0.dmg.sha256`로 확인하세요. 누군가에게 이런 파일을 받았다면 먼저 사용 안내를 읽으세요: [docs/USER_GUIDE.ko.md](docs/USER_GUIDE.ko.md) (영어: [docs/USER_GUIDE.md](docs/USER_GUIDE.md)). 빌드, 공유, 시험 방법은 [docs/DISTRIBUTE.md](docs/DISTRIBUTE.md)입니다. 이 앱은 통화에 참여한 다른 사람을 녹음합니다. 먼저 알려야 합니다(위의 법적 고지 참고). 실제 통화로 확인된 것은 Zoom뿐이고, 이 설치 방식은 아직 새 Mac에서 해 보지 않았습니다.

## 감지 방식

메뉴바 앱이 2초마다 macOS 공개 인터페이스만으로 신호를 읽습니다. 회의 앱을 읽거나 수정하지 않습니다.

- **Zoom**: Zoom 프로세스가 열어 둔 네트워크 소켓(libproc, 추가 권한 없음)이 있거나 마이크를 쓰면 통화로 봅니다. 유휴 상태의 Zoom도 잠깐 소켓을 열기 때문에 약한 근거는 약 15초 이어져야 인정합니다.
- **Teams**: Teams가 마이크를 쓰면 통화로 봅니다. 소리 재생만으로는 시작하지 않습니다.
- **Google Meet (기본 꺼짐)**: Chrome 탭의 주소와 제목을 Apple Events로 읽습니다. Chrome 자동화 권한이 필요하고 가장 덜 검증된 플랫폼입니다. `ENABLED_PLATFORMS=zoom,teams,meet`로 켭니다.
- **다른 앱의 통화 (목록의 앱은 기본 켜짐, Google Meet은 제외)**: 내장 통화 앱 목록(Slack 허들, Cisco Webex, Discord, FaceTime, Skype, GoTo, Amazon Chime, BlueJeans, Lark, 카카오톡, WhatsApp, JANDI)은 앱이나 그 보조 프로세스가 마이크를 쓰면서 **동시에** 소리를 내면 통화로 봅니다. 목록에 없는 앱은 `EXTRA_MEETING_APPS`에 번들 ID로 추가합니다. 목록에는 개인 메신저(Discord, FaceTime, 카카오톡, WhatsApp, Skype)도 들어 있어서, 그 통화도 다른 통화처럼 녹음됩니다. 원하지 않으면 **Call Apps** 하위 메뉴에서 그 앱을 끄거나(첫 통화 전에도 목록의 모든 앱이 보입니다) `CALL_DETECT=off`로 끕니다. **추측은 직접 켜야 합니다**: `CALL_DETECT=generic`이면 내장 제외 목록(브라우저, 미디어 플레이어, 녹화·받아쓰기 도구, Apple 앱 등)에 없고 사용자가 거부하지 않은 그 밖의 모든 GUI 앱도, 마이크와 소리를 45초(`CALL_GENERIC_SECONDS`) 이어서 쓰면 통화로 봅니다. 그렇게 시작한 녹음은 앱 이름이 든 알림("`<앱>`이(가) 통화로 보여 녹음을 시작했어요 ... 메뉴 > Never record `<앱>`")을 보냅니다. 메뉴의 **Never record**(다른 앱의 통화를 녹음하는 동안 보임)와 **Call Apps** 하위 메뉴로 결정을 바꿀 수 있고, 결정은 `call-apps.json`(앱 ID, 이름, 결정만)에 남습니다. 이 파일을 읽을 수 없는 동안에는 다른 앱의 통화를 녹음하지 않습니다. `ENABLED_PLATFORMS`는 Zoom, Teams, Meet만 정하고 이 통화들은 제한하지 않습니다. 제한은 `CALL_DETECT`가 합니다(`CALL_DETECT=off`는 전부 끕니다). 진행 중인 Slack 허들 같은 통화가 Zoom, Teams, Meet 회의를 막지 않습니다. 그 회의가 녹음을 넘겨받습니다. Whereby, Jitsi, Webex 웹, Teams 웹, Zoom 웹 클라이언트의 회의 페이지는 `CALL_BROWSER_URLS=on`일 때만 Chrome 탭 주소로 읽습니다(Meet과 같은 Chrome 자동화 권한이 필요하므로 기본 꺼짐이고, 네이티브 앱만 쓰는 사람은 권한을 요청받지 않습니다). 조직 정책으로 이 키들을 정할 수 있고, 정책이 있는 Mac에서 `CALL_DETECT`가 없으면 `off`입니다.
- **검증 상태**: 실제 통화로 확인한 것은 Zoom뿐입니다. Teams, Google Meet, 위의 다른 앱은 공개된 신호로 구현하고 가짜 입력으로 단위 테스트한 것이지 실제 통화로 확인한 것이 아닙니다. 놓치는 통화와 통화가 아닌 것의 녹음이 있을 수 있습니다. 플랫폼별 신호, 근거 등급, 상태 표는 [docs/DETECTION.md](docs/DETECTION.md) 3b절에 있습니다.
- 신호가 4초 이어지면 녹음을 시작하고, Zoom, Teams, 다른 앱의 통화는 최소 30초 유예 뒤에 끝냅니다.
- 시스템 오디오는 Core Audio 프로세스 탭(macOS 14.4 이상, "시스템 오디오 녹음" 권한), 마이크는 Core Audio로 받습니다. 48 kHz 모노이고 영상과 화면 녹화는 없습니다.

오탐이 있을 수 있습니다 (예: Zoom 마이크 테스트). 발화가 20초 미만이면 폐기되고, 자동 녹음에서 두 트랙이 `NO_SPEECH_STOP_MINUTES`분 동안 디지털 무음이면 스스로 종료합니다. 신호를 직접 보려면 `open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args probe --watch`, 자세한 공식은 [docs/DETECTION.md](docs/DETECTION.md)입니다. 처리가 끝나면 macOS 알림이 오고, 실패한 세션은 앱이 `RETRY_SWEEP_HOURS`마다 자동으로 다시 시도합니다.

## 개인정보와 트레이드오프

자세한 내용은 [docs/PRIVACY_AND_CONSENT.md](docs/PRIVACY_AND_CONSENT.md)와 [docs/PRIVACY_LANES.md](docs/PRIVACY_LANES.md)에 있습니다.

- **Mac 밖으로 나가는 것**: 회의 transcript 전문, 용어 목록, 제목 힌트, (캘린더 조회를 켠 경우) 일정 제목과 참석자가 Anthropic의 Claude로 갑니다 (`claude -p`, 내 API 키 또는 내 구독 로그인). 회의 하나에 호출이 여러 번이고 상한은 `MAX_CLAUDE_CALLS_PER_MEETING`입니다. 오디오는 Claude로 가지 않습니다. 설치할 때 한 번 PyPI, Hugging Face, GitHub에서 내려받습니다.
- **Drive에 남는 것**: 보관 폴더가 Google Drive 같은 동기화 폴더이면 **양쪽 목소리가 담긴 오디오**(`.m4a`), transcript, 회의록, `session.json`, `calendar.json`(참석자 이메일)이 그 서비스로 올라가고 폴더 접근 권한이 있는 모든 사람이 볼 수 있습니다. 줄이려면 `AUDIO_RETENTION_DAYS=N`과 `CALENDAR_LOOKUP=0`을 씁니다.
- **동의와 법적 문제**: 상대방과 참석자는 녹음 알림을 받지 않습니다. 동의 규정과, 기밀이나 PHI 같은 규제 대상 내용을 Claude 약관과 내 계약이 허용하는지는 사용자가 판단합니다. 이 도구는 판단해 주지 않습니다.
- **권한 목록**: 마이크, 시스템 오디오 녹음(`SYSTEM_AUDIO_MODE=global`이면 녹음 중 Mac이 내는 모든 소리가 들어갑니다), 보관 폴더 접근, 알림, 로그인 항목, 그리고 Meet을 켠 경우에만 Chrome 자동화.
- **서명**: 기본 설치는 ad-hoc 서명입니다. 재빌드 때 권한을 다시 묻지 않게 하려면 자체 서명 인증서를 login 키체인에 만들 수 있는데, 그 개인 키는 이 계정의 프로세스가 프롬프트 없이 쓸 수 있고 앱은 hardened runtime 없이 서명됩니다. 대가를 이해한 뒤에만 쓰십시오 ([docs/INSTALL.md](docs/INSTALL.md)).
- **텔레메트리**: 앱 자체에는 없습니다. onnxruntime과 Hugging Face 텔레메트리는 꺼 둡니다. Claude Code 자체의 설정은 이 앱이 바꾸지 않습니다.
- **사용량과 비용**: 호출마다 `usage.jsonl`에 기록되고 `mcap usage`가 7일/30일 사용량과 비용을 보여 줍니다. api 모드에서는 버그나 오탐 녹음이 곧 돈이므로 Console에서 이 프로젝트 전용 키를 만들고 월 지출 한도를 거십시오.
- **로컬 전용 스위치**: 메뉴의 **Local-Only Meeting**(그 회의 하나) 또는 `LOCAL_ONLY_DEFAULT=1`(새 녹음 전부). 로컬 전용 회의는 이 Mac에서만 전사하고 외부 음성 엔진, Claude, 캘린더, 보관 폴더 업로드를 모두 건너뛰며 `LOCAL_ARCHIVE_DIR`에 transcript만 남깁니다.
- **캘린더 자동 시작(선택, 한 사람 전용)**: `OFFLINE_AUTOSTART=auto`이면 앱이 Google 캘린더에 있는 대면 대화에 대해 버튼 없이 스스로 녹음을 시작합니다. 본인 Google Cloud 프로젝트에서 한 번 만든 읽기 전용 Google Calendar 로그인(`python -m mcap gcal auth`)을 쓰고, 토큰은 Keychain에만 있으며 요청은 Google로만 갑니다(Anthropic 등 다른 곳으로는 아무것도 가지 않습니다). **그 자리에 있는 모든 사람이 버튼 없이 녹음됩니다.** 사람을 녹음하는 일은 동의가 필요하거나 지역에 따라 불법일 수 있으니 켜기 전에 [docs/CALENDAR_AUTOSTART.md](docs/CALENDAR_AUTOSTART.md)(경고, 설정, 읽는 것과 보내는 것, 해지)를 읽으십시오. 기본 설치에는 꺼져 있습니다.
- **클라우드 음성 엔진(선택)**: `clova`(NAVER CLOVA Speech, 본인 도메인의 인보크 URL)와 `openai-compat`(OpenAI 방식 `/audio/transcriptions`를 받는 서버, **그 뒤의 벤더는 사용자가 고르고** 동의 문구가 호스트를 밝힙니다)가 들어 있고, `ASR_ENGINE`에 이름을 쓰고 API 키를 Keychain에 저장(`mcap asr-engines secret set clova`)하고 동의를 입력(`mcap asr-engines consent clova`)하기 전에는 **꺼져** 있습니다. 쉼을 잘라 낸 발화 블록(최대 `ASR_CLOUD_BLOCK_SECONDS`초, 16 kHz mono WAV, 상대방 목소리 포함)과 그 호스트용으로 저장한 API 키(`openai-compat`는 모델 이름도)를 보내고, CLOVA에는 용어 목록의 용어(별칭 제외)를 `boostings`로 함께 보냅니다(`ASR_SEND_VOCAB`가 켜져 있고 정책이 허용할 때만). `openai-compat`는 용어를 보내지 않습니다. 제목, 세션 ID, 참석자, 로컬 전용 회의의 어떤 것도 보내지 않습니다. 요금은 벤더가 사용자에게 직접 청구하고 이 프로젝트는 금액을 추정하거나 예산을 두지 않습니다(요청마다 오디오 초를 기록하고 하루 상한 `ASR_CLOUD_DAILY_MINUTES`만 지킵니다). CLOVA sync 호출의 응답 형식은 공개 문서에 없어서 첫 실제 호출로 확인합니다. CLOVA Speech는 NAVER Cloud의 제품이고 이 프로젝트는 제휴 관계가 없습니다. [docs/CONFIGURATION.md](docs/CONFIGURATION.md), 제공자를 추가하려면 [docs/ADD_A_PROVIDER.md](docs/ADD_A_PROVIDER.md).
- **로그**: 로컬 로그에는 회의 제목과 짧은 transcript 조각이 들어갑니다. 로그를 어딘가에 붙이기 전에 `LOG_CONTENT=0`으로 바꾸십시오.

## 설정 (`config.env`)

설정은 `~/Library/Application Support/MeetingCapture/config.env`에 있고 [config/config.env.example](config/config.env.example)에서 설치됩니다. **모든 키, 기본값, 설명은 그 예시 파일(한/영 주석)이 기준입니다.** 파이프라인은 매 실행마다, 앱은 시작할 때 읽으므로 감지/녹음 키를 바꾸면 앱을 Quit 후 다시 켭니다.

**설정 창.** 메뉴 막대의 **Settings…**(설정, Cmd-,)는 아래 키 중 20개를 다섯 탭(일반, Claude, 전사, 감지, 개인정보)에서 바꿉니다. API 키는 macOS 키체인에만 저장하고(`config.env`에는 절대 쓰지 않음), 저장된 설정 기준으로 이 Mac 밖으로 무엇이 나가는지 보여 주며, 저장 뒤에는 **Restart now**를 제안합니다. 건드린 줄만 바꾸고 주석은 그대로 두며, 먼저 백업을 만들고, 파서가 잘못 읽을 값은 거절합니다. 클라우드 음성 엔진의 동의와 Google 로그인은 계속 터미널 명령이며(설정 창이 터미널을 열어 줍니다), 파일을 직접 고치는 방법도 그대로 됩니다. 자세한 내용과 검증되지 않은 부분: [docs/SETTINGS.md](docs/SETTINGS.md).

| 키 | 기본값 | 설명 |
|---|---|---|
| `ARCHIVE_DIR` | `~/Meetings` | 완성된 회의 보관 폴더. 아무 폴더나 되고 Google Drive 폴더(`~/Library/CloudStorage/GoogleDrive-<계정>/My Drive/Meetings`)도 됩니다. 상위 폴더가 없으면(Drive가 꺼져 있으면) 회의는 staging에 남습니다 |
| `PROJECT_DIR` | `~/Developer/meeting-capture` | 이 저장소 (앱이 `PROJECT_DIR/pipeline`에서 파이프라인을 실행, 노트 프롬프트도 여기서 읽음). `install.sh`가 이 체크아웃 경로로 채운다 |
| `PYTHON_BIN` | `<SUPPORT_DIR>/venv/bin/python` | 파이프라인 Python |
| `CLAUDE_BIN` | `~/.local/bin/claude` | Claude Code CLI |
| `CLAUDE_AUTH` | `api` | Claude 호출 과금: `api` = Keychain의 Console API 키 (토큰 단위, 기본이자 지원되는 방식), `subscription` = 구독 로그인 (선택: 무인 `claude -p`가 계정 약관에서 허용되는지 먼저 확인). 위 "Claude 사용" 절. 틀린 값은 호출 없이 실패한다 |
| `CLAUDE_KEY_SERVICE` | `MeetingCapture Anthropic API key` | 키를 저장한 Keychain generic-password 서비스 이름 (account = 로그인 이름) |
| `CLAUDE_DAILY_BUDGET_USD` | `5` | api 모드: 오늘 비용이 이 값(USD)에 닿으면 그날 남은 Claude 단계 중단 (노트는 `budget_daily`로 실패, transcript는 게시, 자정에 이어서). `0` = 끔 |
| `CLAUDE_MEETING_BUDGET_USD` | `2` | api 모드: 한 번의 처리 실행 비용이 이 값에 닿으면 정리/검증/캘린더 생략 (노트는 항상 확보). `0` = 끔 |
| `SELF_NAME` | `Me` | 마이크 트랙의 화자 라벨 (상대 트랙은 항상 `Remote`) |
| `UI_LANGUAGE` | `en` | 앱 자체 문구(알림, 메뉴 설명, 대화상자)의 언어: `en` 또는 `ko`. 알 수 없는 값은 `en`. 노트 언어는 `NOTE_LANGUAGE` |
| `ENABLED_PLATFORMS` | `zoom,teams` | Zoom, Teams, Meet 중 감지할 플랫폼. **`meet`은 기본 꺼짐** (`zoom,teams,meet`로 켠다). 다른 앱의 통화는 제한하지 않는다(`CALL_DETECT`가 한다). 비우면(`=`) 자동 감지 없이 수동 녹음만 |
| `CALL_DETECT` | `known` | 다른 앱의 통화 ([docs/DETECTION.md](docs/DETECTION.md) 3b절). `known` = 내장 통화 앱 목록(Slack 허들, Webex, Discord, FaceTime, 카카오톡 ...) + `EXTRA_MEETING_APPS`, 추측 없음; `generic` = (직접 켜는 추측) 그 밖에 내장 제외 목록에 없고 사용자가 거부하지 않은 GUI 앱이 마이크와 소리를 `CALL_GENERIC_SECONDS` 동안 함께 쓰면 녹음하고 앱 이름이 든 알림을 보냄 (메뉴 **Never record `<앱>`**, **Call Apps** 하위 메뉴, 결정은 `call-apps.json`); `off` = 끔. 그 밖의 값은 `known`으로 읽는다. 조직 정책이 있는 Mac에서 이 키가 없으면 `off`. Zoom, Teams, Meet, 수동 녹음은 영향 없다. `ENABLED_PLATFORMS`가 비어 있으면 이것도 꺼진다. 실제 통화로 확인한 것은 Zoom뿐 |
| `CALL_GENERIC_SECONDS` | `45` | `generic`: 앱이 마이크와 소리를 함께 쓰는 상태가 이만큼(10~600초) 이어져야 통화로 본다 (3초 끊기면 처음부터) |
| `EXTRA_MEETING_APPS` | `<none>` | 표에 없는 통화 앱의 번들 ID (쉼표로 구분, 각 `id` 또는 `id=이름`, 예: `com.example.talk=Example Talk`). ID는 `mdls -name kMDItemCFBundleIdentifier /Applications/<앱>.app`로 찾는다. 잘못된 항목, 중복, 브라우저, Zoom, Teams, 이 앱은 `app.log`에 한 줄을 남기고 버린다. 최대 64개. 내장 제외 목록은 이 앱들에 적용되지 않는다 |
| `CALL_BROWSER_URLS` | `off` | `on` = Whereby, Jitsi, Webex 웹, Teams 웹, Zoom 웹 클라이언트의 회의 페이지를 Chrome 탭 주소로도 읽는다. Meet처럼 Chrome 자동화 권한이 필요해서 기본 꺼짐 (네이티브 앱만 쓰는 사람은 요청받지 않는다). Google Meet은 계속 `ENABLED_PLATFORMS`의 `meet` 뒤에 있다 |
| `BROWSER_BUNDLE_IDS` | `com.google.Chrome` | Meet 감지에 쓰는 브라우저 (Meet을 켠 경우만 쓰임) |
| `POLL_INTERVAL_SECONDS` | `2` | 감지 폴링 간격 |
| `START_DEBOUNCE_SECONDS` | `4` | 회의 신호가 이만큼 이어지면 녹음 시작 |
| `GRACE_SECONDS` | `20` | 신호가 사라진 뒤 이만큼 기다렸다가 종료 (Zoom/Teams/다른 앱의 통화는 최소 30초) |
| `MIN_RECORDING_SECONDS` | `30` | 이보다 짧은 녹음 처리 기준 (실제로 지우는 건 10초 미만) |
| `MAX_RECORDING_HOURS` | `6` | 안전장치: 이 시간이 지나면 녹음 종료 |
| `MIN_FREE_DISK_GB` | `5` | 남은 디스크가 이보다 적으면 녹음 종료/시작 안 함 |
| `NO_SPEECH_STOP_MINUTES` | `15` | 자동 녹음에서 두 트랙이 이 시간(분) 동안 −70 dBFS 아래(디지털 무음)이면 정상 종료하고 보존 (1~600; 방 소음이 있으면 걸리지 않는다). `0` = 끔 |
| `RETRY_SWEEP_HOURS` | `6` | 재시도 가능한 실패 세션이 있으면 앱이 이 간격(시간)으로 `mcap reprocess --pending`을 실행 (0.25~168). `0` = 끔 |
| `NOTIFY_RECORDING` | `1` | 녹음이 시작 / 끝날 때 macOS 알림 (메뉴바 아이콘이 가려져도 확인용). `0` = 끔. 경고와 결과 알림은 항상 간다 |
| `SYSTEM_AUDIO_MODE` | `global` | `global` = 전체 시스템 출력(우리 앱 제외), `app` = 회의 앱 프로세스만 (녹음되는 소리가 줄어든다) |
| `ASR_MODEL` | `mlx-community/whisper-large-v3-mlx` | 전사 모델 (HF repo id 또는 로컬 폴더). 한 줄로 교체 |
| `ASR_LANGUAGE` | `auto` | `auto`(구간별 언어 감지), `ko`, `en` |
| `ASR_LANGUAGES` | `ko,en` | 구간별 언어 감지와 외국 문자 필터가 따르는 언어 집합. **일본어 회의가 있으면 `ko,en,ja`** (넣지 않으면 가나/한자가 외국 문자로 버려진다) |
| `ASR_VAD` | `auto` | `auto`(Silero가 있으면 Silero, 없으면 에너지), `silero`, `energy` |
| `ASR_STRATEGY` | `dual` | `dual` = 같은 로컬 모델로 청크마다 2회(프롬프트 있음 / 없음) 디코딩하고 고정 규칙으로 병합, 전사 시간 약 1.5~1.8배, 로컬 Whisper 전용(외부 엔진은 항상 `single`). `single` = 청크당 1회 디코딩(vocabulary 프롬프트 포함, 더 빠름). 알 수 없는 값은 `single`. docs/CONFIGURATION.md "Transcription strategy" |
| `MIC_AEC` | `auto` | 마이크 트랙 에코 제거: `auto`(새는 경우만), `1`, `0` |
| `TRANSCRIPT_CLEANUP` | `1` | LLM 정리본 `transcript.cleaned.md` 생성 (원본은 수정 안 함) |
| `NOTE_VERIFY` | `1` | 노트 초안을 원본 transcript로 검증하는 두 번째 패스 |
| `NOTE_MODEL` | `opus` | 노트 모델 alias (api 모드에서도 같은 alias) |
| `NOTE_FALLBACK_MODEL` | `sonnet` | 주 모델이 실패하면 1회 재시도 |
| `NOTE_EFFORT` | `high` | `claude --effort` |
| `NOTE_LANGUAGE` | `auto` | 노트 언어 (auto = 회의의 주 언어) |
| `NOTE_TIMEOUT_SECONDS` | `1200` | 노트 생성 제한 시간 |
| `NOTE_STOP_ON_OVERAGE` | `1` | subscription 모드 전용 (api 모드에서는 무시): `1` = Claude가 초과 사용(extra usage) 과금 중이라고 보고하면 노트 생성을 멈추고 transcript만 남김 (`mcap reprocess --allow-overage`로 강제). `0` = 기록만 하고 계속. 값은 `1`/`0`만 쓴다 (다른 표기는 꺼짐으로 읽힌다) |
| `MAX_CLAUDE_CALLS_PER_MEETING` | `30` | 한 회의에서 `claude -p` 호출 상한 (정리 배치 + 노트 + 검증 + 캘린더) |
| `CALENDAR_LOOKUP` | `0` | `auto`/`0`(이 예시 파일의 값은 `0`이고 키를 지우면 내장 기본값은 `auto`): claude.ai Google Calendar 커넥터로 제목/참석자를 조회 (녹음 시작 ±45분 일정만, 실패하면 조용히 창 제목/플랫폼으로 폴백). 켜 두면 일정 제목/참석자가 Claude로 간다. 이 호출만은 `CLAUDE_AUTH=api`여도 구독 로그인으로 실행된다 |
| `AUDIO_RETENTION_DAYS` | `0` | `0` = 영구 보관. N>0이면 처리가 끝날 때마다 N일 지난 `*.m4a`만 삭제 (transcript/note는 절대 삭제 안 함) |
| `LOCAL_ONLY_DEFAULT` | `0` | 새 녹음의 회의별 "로컬 전용" 기본값. `1`이면 새 녹음은 전사를 이 Mac에서만 하고 나갈 수 있는 다섯 레인(원격/클라우드 ASR, Claude 정리/노트/검증, 캘린더, Drive)을 모두 건너뛰며 `LOCAL_ARCHIVE_DIR`에 보관한다. 알 수 없는 값은 `1`로 읽는다. 조직 정책이 올리거나 잠글 수 있다 |
| `ASR_ENGINE` | `whisper` | 주 전사 엔진: `whisper`(로컬) \| `remote`(회사 mcap-asr 서버) \| `azure` \| `clova`(NAVER CLOVA Speech) \| `openai-compat`(사용자가 고른 OpenAI 전사 API 서버) \| `auto`(로컬이 가능한 Mac이면 whisper). 외부 엔진은 회의가 로컬 전용이 아니고 정책이 허용하고 동의가 있고 여기나 `ASR_FALLBACK`에 명시된 경우에만 쓰인다. 알 수 없는 값은 whisper |
| `ASR_FALLBACK` | `none` | 주 엔진이 실패했을 때 그 청크만 맡는 엔진(연쇄 없음): `none` \| `whisper` \| `remote` \| `azure` \| `clova` \| `openai-compat` |
| `ASR_LOCAL_MIN_RAM_GB` | `16` | 로컬 전사 가능 판정(엔진 `auto`와 doctor)의 최소 RAM(GB) |
| `ASR_LOCAL_MAX_RTF` | `0.25` | 같은 판정의 측정 실시간 배율(RTF) 상한 (`mcap asr-engines check --probe`) |
| `ASR_ALLOW_DOWNLOAD` | `1` | `1`이면 모델이 없을 때 받을 수 있다. 로컬 전용 실행에서는 항상 0, 회사 기준 정책은 0을 강제한다(모델은 릴리스 안). 알 수 없는 값은 `0` |
| `ASR_REMOTE_URL` | <비어 있음> | mcap-asr/1 서버 주소: https와 DNS 이름만. 호스트와 포트는 동의(또는 조직 동의)와 정책의 `allowed_hosts`에 맞아야 하고 Keychain 토큰이 이 host:port에 결박된다 |
| `ASR_REMOTE_CA_FILE` | <비어 있음> | 서버 인증서를 서명하는 사설 CA의 PEM. 그 호스트에는 이 CA만 신뢰하고 파일의 sha256이 동의의 `ca_sha256`과 같아야 한다 |
| `ASR_REMOTE_MAX_WAIT_S` | `120` | 청크 하나가 재시도, `Retry-After`, 큐 대기를 합해 기다리는 최대 시간(초) |
| `ASR_AZURE_REGION` | `koreacentral` | Azure Speech 리소스 리전(호스트 = `<리전>.api.cognitive.microsoft.com`). 바꾸면 동의가 무효가 된다. 엔진은 **한국 리전(`koreacentral`, `koreasouth`)만** 쓴다: 다른 리전은 아무것도 보내기 전에 `region_not_allowed`로 거부한다(정책 표는 엔진당 거주지 하나만 알아서 `allow_foreign=false`를 여기서 지킨다) |
| `ASR_AZURE_HOST` | <비어 있음> | 사용자 지정 엔드포인트 호스트(`.api.cognitive.microsoft.com` 또는 `.cognitiveservices.azure.com`으로 끝나야 한다). 비우면 리전에서 만든다. 호스트 이름이 리전을 말해 주지 않는 `.cognitiveservices.azure.com` 호스트는 `ASR_AZURE_REGION`도 **직접 적어야** 한국으로 인정된다 |
| `ASR_AZURE_LOCALES` | <비어 있음> | 후보 로케일 목록(`ko-KR,en-US`). 비우면 생략(다국어 모델) |
| `ASR_AZURE_BIAS` | `1.0` | vocabulary 용어의 phraseList 가중치(0.0~2.0, `ASR_SEND_VOCAB`가 켜진 때만) |
| `ASR_AZURE_USD_PER_HOUR` | `0` | `asr-usage.jsonl`의 `est_usd` 추정에만 쓰는 시간당 단가(USD). 0 = 모름. 실제 청구는 Azure Cost Management |
| `ASR_CLOVA_INVOKE_URL` | <비어 있음> | 본인 CLOVA Speech 도메인의 인보크 URL(`https://clovaspeech-gw.ncloud.com/external/v1/<id>/<key>`): https와 NAVER Cloud 게이트웨이 호스트(`.ncloud.com`, `.fin-ncloud.com`, `.gov-ncloud.com`)만. 호스트와 포트가 동의와 Keychain 키에 결박되고(호스트를 바꾸면 둘 다 무효) 경로(도메인 식별자)는 로그와 상태에 남지 않는다. 비밀 키는 `mcap asr-engines secret set clova`로 저장 |
| `ASR_CLOVA_LANGUAGE` | `enko` | `ko-KR`, `en-US`, `enko`(한 요청에 한국어와 영어), `ja`, `zh-cn`, `zh-tw`. 이 엔진은 `ASR_LANGUAGE`를 쓰지 않는다. 알 수 없는 값은 `enko` |
| `ASR_CLOVA_DIARIZATION` | `auto` | 화자 분리: `on`, `off`, `auto` = 회의의 유일한 트랙(오프라인 회의)과 온라인 회의의 상대 트랙은 켜고 온라인 회의의 마이크 트랙은 끈다 |
| `ASR_OPENAI_COMPAT_URL` | <비어 있음> | `POST <base>/audio/transcriptions`를 구현한 서버(OpenAI 자체, faster-whisper 서버, 자체 게이트웨이)의 base URL: https와 DNS 이름만(IP 주소 불가). 보내는 곳은 사용자가 정하므로 동의 문구가 호스트를 밝히고 회사 정책은 `asr.allow_foreign`이 필요하다. 호스트와 포트가 동의와 선택적 Keychain 키에 결박된다 |
| `ASR_OPENAI_COMPAT_MODEL` | `whisper-1` | 그 요청의 `model` 필드(공백 없는 한 덩어리, 100자 이하. `Systran/faster-whisper-large-v3` 같은 id도 돼요) |
| `ASR_CLOUD_BLOCK_SECONDS` | `900` | 블록을 받는 엔진(`clova`, `openai-compat`)의 한 번 업로드에 담는 발화 길이(초, 30~1800, `openai-compat`는 최대 720). docs/CONFIGURATION.md "Cloud providers" |
| `ASR_CLOUD_DAILY_MINUTES` | `240` | 이 Mac에서 외부 엔진으로 보내는 오디오의 하루 상한(분, 오디오 초 + 요청당 1초). 정책 상한과 작은 쪽을 쓴다. 클라이언트 쪽 자문이고 권위 있는 값은 서버의 토큰별 쿼터 |
| `ASR_REQUEST_TIMEOUT_S` | `90` | ASR HTTP 요청 1회 제한 시간(초, 서버 큐 상한 45초 + 처리 시간보다 크게) |
| `ASR_RETRY_MAX` | `3` | 외부 엔진 안의 청크당 시도 횟수 |
| `ASR_CIRCUIT_FAILS` | `3` | 서킷 브레이커: 이만큼 연속 일시 실패하면 그 실행의 나머지 동안 연다 |
| `ASR_CIRCUIT_COOLDOWN_S` | `120` | 다시 주 엔진에 청크 하나를 탐침하기 전 대기(초, 다시 열리면 2배, 최대 600) |
| `ASR_SEND_VOCAB` | `1` | `1`이면 vocabulary 용어를 외부 엔진에 보낸다(동의 문구에 명시). 로컬 Whisper는 항상 전체 목록을 쓴다. 정책이 엔진 종류별로 끌 수 있다. 알 수 없는 값은 `0` |
| `LOCAL_ARCHIVE_DIR` | <기본: `SUPPORT_DIR/local-meetings`> | 로컬 전용(과 Drive가 거부된) 회의의 보관 위치. `SUPPORT_DIR` 아래(또는 정책이 허용한 폴더)여야 하고 링크가 없고 홈과 같은 디스크여야 한다. 아니면 `local_archive_unsafe`. 조직 정책은 이 키를 바꿀 수 없다 |
| `LOCAL_ARCHIVE_RETENTION_DAYS` | `0` | `0` = 보관. N>0이면 로컬 아카이브의 N일 지난 `*.m4a`를 지운다(전사본은 지우지 않는다) |
| `STAGING_FAILED_RETENTION_DAYS` | `0` | `0` = 보관. N>0이면 staging의 재시도 불가 실패 세션 중 N일 지난 것을 지운다 |
| `MIC_MUTE_GATE` | `off` | `off` \| `on`. `on`이면 음소거 신호가 확실한 동안 마이크 구간을 0으로 기록한다(신호를 모르면 녹음). 앱이 읽는다. 알 수 없는 값은 `on`. 회사 기준 정책은 `on`을 강제한다 |
| `LOG_CONTENT` | `1` | `1`이면 파이프라인 로그에 전사 조각(최대 60자), 앱 로그에 회의 제목이 들어간다. `0`이면 길이와 짧은 해시만 남기고 알림과 앱 로그에서 제목과 slug 경로를 뺀다. 알 수 없는 값은 `0`. 회사 기준 정책은 `0`을 강제한다 |
| `LOG_RETENTION_DAYS` | `0` | 이 일수보다 오래된 `pipeline-*.log`를 처리 때 지운다(`0` = 보관). 회사 기준 정책의 기본값은 30 |
| `APP_LOG_MAX_MB` | `0` | `app.log` 회전 크기(MB, 5개 보관, `0` = 회전 없음). 앱만 읽는다. 회사 기준 정책의 기본값은 5 |
| `STATUS_INCLUDE_USAGE` | `0` | `1`이면 `mcap status --write`(MDM 확장 속성)가 거친 단위의 `asr_usage_7d`, `llm_cost_7d_usd`도 보고한다. `0` = 기기 상태만. 터미널의 `mcap status`는 항상 전부 보여 준다 |
| `OFFLINE_AUTOSTART` | `off` | `off` 또는 `auto`. `auto`이면 앱이 Google 캘린더에 있는 대면 대화에 대해 버튼 없이 스스로 녹음을 시작한다. **그 자리에 있는 모든 사람이 녹음된다**: [docs/CALENDAR_AUTOSTART.md](docs/CALENDAR_AUTOSTART.md)를 먼저 읽을 것. 한 사람(소유자) 전용 기능이며 본인 Google Cloud OAuth 클라이언트와 `python -m mcap gcal auth`가 필요하다. 알 수 없는 값은 `off` |
| `OFFLINE_START_BEFORE_MINUTES` | `2` | 일정 시작 이 시간(분, 0~30) 전부터 녹음을 시작할 수 있다 |
| `OFFLINE_START_AFTER_MINUTES` | `15` | 시작 후 이 시간(분, 0~120)까지 시작할 수 있다. 그보다 일찍 시작한 일정에는 늦게 들어가지 않는다 |
| `OFFLINE_STOP_AFTER_END_MINUTES` | `10` | 이 기능이 시작한 녹음은 일정 종료 후 이 시간(분, 0~120)이 지나면 멈춘다 |
| `OFFLINE_IDLE_MAX_MINUTES` | `5` | 키보드/마우스 입력이 이 시간(분, 1~120)보다 오래 없으면 자리에 아무도 없다고 보고 시작하지 않는다 |
| `OFFLINE_REQUIRE_GUESTS` | `1` | `1`이면 본인 외 참석자가 1명 이상인 일정만 녹음한다(혼자 잡은 일정은 대화가 아님). `0` = 조건 없음 |
| `OFFLINE_MIN_MINUTES` | `10` | 이보다 짧은 일정(분, 1~600)은 녹음하지 않는다 |
| `OFFLINE_MAX_MINUTES` | `240` | 이보다 긴 일정(분, 1~1440)은 녹음하지 않는다. `OFFLINE_MIN_MINUTES`가 이 값을 넘으면 안 된다 |

이 표는 `config/config.env.example`과 같은 키와 기본값을 가집니다 (`scripts/test_scripts.sh`가 확인합니다). 비밀(Azure 키, 릴레이 토큰, Anthropic API 키)은 이 파일에 쓰지 않고 Keychain에만 둡니다. 조직 정책(`policy.json`)의 키는 `config.env`가 아니라 [docs/POLICY.md](docs/POLICY.md)에 있습니다. `TRANSCRIPT_CLEANUP`, `NOTE_VERIFY` 같은 `1`/`0` 키는 오타가 나면 조용히 꺼질 수 있으니 값을 정확히 쓰십시오.

내 용어(고유명사, 전문용어)는 `~/Library/Application Support/MeetingCapture/vocabulary.txt`에 한 줄에 하나씩 적습니다. 위쪽이 우선이고 `Acme = 애크미 | 액미`처럼 자주 틀리는 표기를 맞는 표기로 바꿉니다. 이미 끝난 회의에는 `mcap reprocess --last --from asr`로 반영합니다.

## Claude 사용

회의록 단계는 내가 직접 설치한 `claude` 명령(Claude Code)을 내 Anthropic API 키(`CLAUDE_AUTH=api`, 기본이자 지원되는 방식)로 실행하거나, 선택 사항으로 내 로그인(`CLAUDE_AUTH=subscription`)으로 실행합니다. 설치는 [Anthropic 문서](https://code.claude.com/docs/en/overview)를 따릅니다. 앱은 기본으로 `~/.local/bin/claude`를 찾고 `CLAUDE_BIN`으로 바꿀 수 있습니다. api 모드의 키는 macOS Keychain에만 두고(`make set-api-key`) 호출 직전에 읽어 환경변수로만 넘깁니다. 예산 `CLAUDE_DAILY_BUDGET_USD`와 `CLAUDE_MEETING_BUDGET_USD`의 기본값은 일부러 작게 5와 2 USD입니다. subscription 모드(선택)는 **고르기 전에 계정의 Anthropic 약관을 확인하십시오**. Anthropic이 공개한 규칙상 구독 로그인은 일반적인 개인 사용에 한정되고, 이 도구는 사람이 없는 동안에도 `claude -p`를 돌리므로 무인으로 돌리거나 조직용이면 API 키를 쓰십시오. 이 프로젝트는 Claude Code를 포함, 수정, 재판매, 중계하지 않고 로그인 토큰을 읽거나 저장하지 않으며, 한 계정을 여러 사람이 나눠 쓰는 데 쓰면 안 됩니다. 이 프로젝트는 Anthropic과 제휴 관계가 없습니다.

## 문제 해결

`mcap` 명령은 저장소의 `pipeline` 폴더에서 앱의 Python으로 실행합니다.

```bash
cd pipeline
PY="$HOME/Library/Application Support/MeetingCapture/venv/bin/python"
"$PY" -m mcap doctor                       # make doctor와 같음
"$PY" -m mcap reprocess --last             # 마지막 회의를 멈춘 단계부터 이어서
"$PY" -m mcap reprocess --pending          # 재시도 가능한 실패를 한꺼번에
```

- **녹음이 안 된다**: 메뉴바 아이콘이 있는지, 플랫폼이 `ENABLED_PLATFORMS`에 있는지(Meet은 기본 꺼짐), `probe --watch`로 신호를 확인합니다. 메뉴의 Start Recording Now로 수동 녹음할 수 있습니다.
- **상대방 트랙이 무음**: 시스템 오디오 녹음 권한이 없는 경우가 가장 흔합니다 (오류 없이 무음). 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음을 확인하고 `setup`을 다시 실행합니다.
- **권한이 꼬였다**: 앱을 종료하고 `tccutil reset All "$(defaults read ~/Applications/CATE.app/Contents/Info CFBundleIdentifier)"` 후 `setup`을 다시 실행합니다.
- **보관 폴더가 없다**: Drive가 꺼져 있으면 회의가 staging에 남습니다. `ARCHIVE_DIR`을 고친 뒤 `"$PY" -m mcap reprocess --pending`.
- **노트가 없고 transcript만 있다**: api 모드는 `"$PY" -m mcap api-key status`와 `api-key check`, subscription 모드는 `claude auth status`를 봅니다.
- 로그는 `~/Library/Logs/MeetingCapture/`에 있습니다. 공유하기 전에 `LOG_CONTENT=0`으로 바꾸고, 녹음, transcript, 회의록은 이슈에 절대 첨부하지 마십시오.

## 제한 사항

- 에코 제거는 휴리스틱입니다. 합성 오디오로만 검증했고 내 목소리를 지우지 않는 쪽으로 보수적으로 동작합니다.
- 회의실에서 회의용 마이크를 쓰면 마이크 트랙에는 그 자리에 있는 모든 참석자의 목소리가 들어가고, 전부 `SELF_NAME` 라벨로 표시됩니다. 상대 참석자는 전부 `Remote`이며 화자 구분은 없습니다.
- 회의 앱에서 음소거해도 마이크는 녹음됩니다.
- 노트북 덮개를 닫으면 Mac이 잠들어 녹음이 끝나고 처리는 깨어난 뒤 이어집니다.
- Whisper는 무음에서 문장을 지어낼 수 있고 한영 혼용에 약합니다. 한국어와 영어만 시험했습니다. 앱 자체의 문구(알림, 메뉴 설명, 대화상자)는 기본이 영어이고 `UI_LANGUAGE=ko`이면 한국어입니다. 노트 본문 언어는 `NOTE_LANGUAGE`이고 제목은 항상 영어입니다. 기본 Whisper 프롬프트는 의료 AI 회의를 가정합니다(약한 편향).
- 실제 통화로 확인한 감지는 Zoom 한 환경뿐입니다. Teams, Meet, 다른 앱은 공개 신호로 구현하고 가짜 입력으로 테스트했을 뿐입니다. 처음 몇 주는 시험 삼아 쓰고 가끔 캘린더와 대조하십시오. 다른 앱용 generic 규칙은 통화가 아닌 것을 녹음할 수 있습니다(**Never record**를 쓰십시오).

## 조직 모드 (실험)

한 조직이 여러 Mac에 배포하려고 만든 부분(제한만 가능한 정책 파일, 서명한 설치 패키지, MDM 스크립트, 중앙 음성 인식 서버)도 저장소에 있습니다. **실험적이고, 한 조직을 위해 쓰였고, 대부분 한국어이며, 법무 검토를 받지 않았고, 개인 사용에는 필요 없습니다.** [docs/DEPLOY.md](docs/DEPLOY.md), [docs/OPS_RUNBOOK.md](docs/OPS_RUNBOOK.md), [docs/MIGRATION.md](docs/MIGRATION.md), [docs/POLICY.md](docs/POLICY.md), [docs/ASR_PROTOCOL.md](docs/ASR_PROTOCOL.md), [docs/ASR_SERVER_LINUX.md](docs/ASR_SERVER_LINUX.md)를 보십시오.

## 제거

```bash
scripts/uninstall.sh --dry-run     # 먼저 확인
scripts/uninstall.sh               # 로그인 에이전트와 앱 삭제 (설정, 세션, 모델, 로그는 남김)
scripts/uninstall.sh --purge       # 지원 폴더와 로그까지 삭제 ('purge' 입력 필요)
```

`ARCHIVE_DIR`의 회의 기록, Hugging Face 모델 캐시, 이 저장소, 서명 인증서는 건드리지 않습니다. 권한과 인증서 정리는 [docs/INSTALL.md](docs/INSTALL.md)를 보십시오.

## 개발, 로드맵, 비목표

`make test`는 마이크, 권한 프롬프트, Keychain, 네트워크 없이 도는 테스트를 모두 실행합니다. `make test-python`은 `make install ARGS=--python`이 만든 앱 환경의 Python을 쓰고, Command Line Tools만 있는 Mac에서는 Python 3.12 이상과 numpy가 든 인터프리터를 직접 지정합니다: `make test-python PY=/path/to/python3.13`. 실제 녹음, 권한, Zoom/Teams 감지는 실제 Mac에서만 확인할 수 있습니다. 자세한 내용은 [CONTRIBUTING.md](CONTRIBUTING.md)입니다.

- 로드맵(약속 아님): 앱 문구의 더 많은 언어(`UI_LANGUAGE`는 지금 영어와 한국어), 덮어쓸 수 있는 중립적인 Whisper 프롬프트, 해시 고정 설치, 공증된 빌드(Apple Developer 계정이 있는 관리자가 맡는 경우), Meet 감지 검증.
- 비목표: 영상/화면 녹화, 라이브 자막, 화자 식별, 호스팅 서비스, Intel Mac과 Windows/Linux 클라이언트, 회의에 들어가는 봇, 몰래 녹음, 법 준수 보장.

## 상표와 라이선스

이 프로젝트는 독립 오픈소스 프로젝트이며 Zoom, Microsoft, Slack, Cisco, Discord, Google, Anthropic, Apple, OpenAI, Hugging Face, NVIDIA와 제휴, 후원, 보증 관계가 없습니다. 각 이름은 해당 소유자의 상표이며 이 프로젝트가 어떤 소프트웨어와 함께 동작하는지 밝히는 용도로만 씁니다. 자세한 내용은 [영어 README](README.md#trademarks-and-independence)를 보십시오.

Copyright 2026 Meeting Capture contributors. Apache License 2.0 ([LICENSE](LICENSE)). 제3자 구성요소와 모델은 각자의 라이선스를 따릅니다 ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). 릴리스는 `scripts/release.sh`가 만듭니다: 소스, `SHA256SUMS`, 그리고 Apple silicon에서 빌드한 경우 공증되지 않은 ad-hoc 서명 앱 zip. 소스 빌드를 권장합니다. Python 패키지, 가상환경, 모델 가중치는 이 프로젝트가 배포하지 않으며 설치할 때 직접 내려받습니다.
