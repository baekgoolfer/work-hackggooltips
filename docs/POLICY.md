# 조직 정책 `policy.json`: 형식, 우선순위, 판정 규칙

상태: **실험적 (조직 모드, SPEC 18).** 한 조직의 설치를 위해 쓰였고 법률 검토를 받지 않았으며 지원은 없다. 이 문서는 정책을 쓰고 배포하는 사람이 읽는 설명이다.
파서는 Python(`pipeline/mcap/policy.py`)과 Swift(`app/Sources/Policy.swift`)에 따로 있고, 둘은 `config/policy-fixtures/`의 공통 코퍼스로 같은 판정을 하도록 시험한다.
이 문서와 코드가 다르면 코드 시험(코퍼스)이 이긴다. 법률 판단은 담지 않는다: 어느 레인을 언제 여는가는 승인 참조(`approvals`)에 묶인 관리자와 법무의 결정이다.
처음 쓰는 사람은 `config/policy.example.json`(모든 레인 deny, 승인 없음)을 복사해서 시작한다.

관련 문서: 무엇이 어디로 나가는가 `docs/PRIVACY_LANES.md`, 서버 프로토콜 `docs/ASR_PROTOCOL.md`, 참석자 고지 문구는 법률 자문을 받아 정한다.

## 1. 한 장 요약

- 조직 정책은 **제한만 한다.** 개인 설정을 완화하지 못하고, 외부 레인을 *열어 주는* 것도 정책 혼자서는 못 한다: 외부 송신은 (회의가 local_only 아님) AND (정책 허용) AND (유효한 동의) AND (사용자 설정에 명시)가 모두 참일 때만 일어난다.
- 위치와 쓰는 주체: `/Library/Application Support/MeetingCapture/policy.json`, root/MDM만 쓴다. 경로를 바꿀 수단은 없다(시험용 `MCAP_POLICY_PATH`는 이 Mac에 시스템 정책과 마커가 둘 다 없을 때만 효과가 있다).
- 입력이 이상하면 **닫는다**: 파싱 실패, 알 수 없는 키, 빠진 `profile`, 권한 오류는 모두 '잠금'이고 잠금은 모든 외부 레인을 닫는다. 닫아도 회의는 잃지 않는다: 로컬 전사는 계속된다.
- 정책이 한 번도 없는 Mac(개인 설치)은 지금과 똑같이 동작한다. 정책이 있는 Mac은 `profile`로 `company`와 `personal` 둘 중 하나다.
- 이 정책이 막는 것의 한계: 같은 사용자 권한의 악성코드와 로컬 관리자는 못 막는다. 실질 강제는 MDM(표준 사용자, 앱 허용 목록, 프로세스별 네트워크 허용, FileVault)과 root 소유 런타임이 한다(11절).

## 2. 파일, 마커, 신뢰

| 파일 | 위치 | 역할 |
|---|---|---|
| `policy.json` | `/Library/Application Support/MeetingCapture/policy.json` | 정책 본문(0644, root 소유) |
| `policy.required` | 같은 폴더 | 마커: 이 Mac은 정책이 반드시 있어야 한다. 마커는 있는데 `policy.json`이 없으면 잠금이다. company pkg가 항상 둔다 |

`config.system_policy_present()`는 둘 중 하나라도 있으면(lstat) 참이고, 그때부터 이 Mac은 '정책 관리 Mac'이다. 정책 관리 Mac에서는 다음이 일어난다.

- 시험용 환경변수(`MCAP_CONFIG`, `MCAP_LOG_DIR`, `MCAP_SILERO_MODEL`, `MCAP_SECURITY_BIN`, `MCAP_POLICY_PATH`)와 `config.env`의 `SUPPORT_DIR`, `PYTHON_BIN`, `PROJECT_DIR`, `CLAUDE_BIN` 키를
  Python과 Swift가 모두 무시한다. Swift는 이 변수들을 자식 프로세스에 넘기지 않고, 자식 PATH에서 `~/.local/bin`과 `/opt/homebrew/bin`을 뺀다.
- `CLAUDE_BIN`은 `config.env` 값을 무시하고 고정 경로를 쓰며, 정책의 서명 핀을 통과해야 호출한다.
- `MCAP_SECURITY_BIN`은 무시되고 `/usr/bin/security` 절대 경로만 쓴다.

### 2.1 유효성 검사 (하나라도 어기면 '잠금')

- `lstat`으로 일반 파일(심볼릭 링크 아님), 소유자 uid 0, `(mode & 0o022) == 0`(그룹/기타 쓰기 불가), 상위 디렉터리도 root 소유이고 쓰기 불가.
- 크기 256 KiB 이하, UTF-8 JSON 객체(BOM이나 같은 키가 두 번 나오는 객체는 invalid).
- `schema`가 1, `profile`이 `company`|`personal`, 알 수 없는 키 없음(`ext` 안은 예외), 값 형식 오류 없음(3절).
- `min_pipeline_version`보다 낮은 파이프라인은 정책을 잠금으로 읽는다(12절).
- 읽기에 실패하면 **500 ms 뒤 한 번 더 읽고** 나서 잠금으로 판정한다(MDM이 쓰는 중간 상태를 잠금으로 오인하지 않기 위해). 배포는 임시 파일에 쓰고 rename 한다(10절).

잠금 사유는 `policy-status`, `mcap doctor`, `mcap status`에 짧은 코드로 나온다. 잠금이면 모든 외부 레인이 닫히고, 앱은 회의별 플래그를 true로 강제하며, doctor는 FAIL을 보고한다.

## 3. 스키마 (schema 1)

**엄격성.** 모든 수준에서 알 수 없는 키는 잠금이다. 자유 영역은 `ext` 하나뿐이고 두 파서가 모두 무시한다. 오타 하나가 제한을 조용히 없애는 것보다 눈에 보이는 잠금이 낫기 때문이다.
형식이 잘못된 값(잘못된 타입 등)도 잠금이다. 단 레인 값은 예외로 더 좁게 읽는다: 레인 값이 `allow`와 `deny`가 아니면 그 레인만 `deny`다.

전체 모양(값은 예시. 모든 레인 deny의 기준 정책은 `config/policy.example.json`):

```json
{"schema":1,"profile":"company","revision":12,"issued":"2026-10-14T09:00:00+09:00","min_pipeline_version":"0.2.0",
 "support":{"contact":"IT 헬프데스크 #it-help"},
 "lanes":{"asr_remote":"allow","asr_cloud":"deny","llm":"deny","calendar":"deny","drive":"allow"},
 "approvals":{"drive":"TICKET-1234"},
 "local_only":{"default":false,"locked":false},
 "recording":{"enabled":true},
 "asr":{"allowed_engines":["whisper","remote"],"allowed_hosts":["asr.example.internal"],"allow_foreign":false,
        "daily_audio_minutes_cap":240,"send_vocab":{"server":true,"cloud":false},
        "org_consents":[{"engine":"remote","host":"asr.example.internal","port":443,"protocol":"mcap-asr/1","backend_kind":"server",
                         "ca_sha256":"<64 hex>","attest_build_sha256":["<64 hex>"],"use":"both","expires":"2027-10-14"}]},
 "archive":{"allowed_roots":["~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"],"local_roots":[]},
 "llm":{"claude_bin_pin":{"team_id":"<Team ID>"},"child_env":{}},
 "runtime":{"root":"/Library/Application Support/MeetingCapture/releases"},
 "defaults":{"ASR_ENGINE":"auto"},"enforced":{"AUDIO_RETENTION_DAYS":"30"},"ext":{}}
```

### 3.1 키 목록

| 키 | 형식, 기본 | 뜻 |
|---|---|---|
| `schema` | 정수. 반드시 `1` | 다른 값은 잠금. 항상 명시한다 |
| `profile` | `"company"` \| `"personal"`, **필수** | 그 외 값이나 생략은 잠금. 프로필별 기본은 4절 |
| `revision` | 양의 정수, 필수 | doctor와 status에 표시된다. 정책을 고칠 때마다 올린다 |
| `issued` | ISO 8601 시각 문자열 | 발행 시각. 정보용이고 레인 판정에는 쓰이지 않는다 |
| `min_pipeline_version` | `"N.N.N"` 문자열 | 이보다 낮은 파이프라인은 정책을 잠금으로 읽고, Swift 앱은 더 낮은 파이프라인을 실행하지 않는다(12절). 정수 튜플로 비교한다(`0.10.0` > `0.2.0`) |
| `support.contact` | 한 줄, 60자 이하 | 정책 오류와 실패 알림에 문의처로 나온다 |
| `lanes.{asr_remote,asr_cloud,llm,calendar,drive}` | `"allow"` \| `"deny"`. 생략: company deny, personal allow | 레인별 조직 허용. 그 외 문자열은 deny |
| `approvals.{llm,asr_cloud,calendar,drive}` | 비어 있지 않은 참조 문자열(티켓, 법무 승인 번호), 80자 이하. company 전용 | 해당 레인의 allow가 효력을 가지려면 필요하다. 없으면 deny(`policy-unapproved`). 승인 참조가 필요한 레인은 이 네 개뿐이다(`asr_remote`에는 승인 참조가 없다) |
| `local_only.default` | bool, `false` | 새 회의의 local_only 기본값을 올린다(사용자가 내릴 수 없다). 6절 |
| `local_only.locked` | bool, `false` | true이면 유효값이 항상 true이고 앱의 메뉴 항목이 비활성이다 |
| `recording.enabled` | bool, `true` | false이면 녹음 킬 스위치다: 앱이 녹음 시작을 거부하고 진행 중인 녹음을 약 60초 안에 정상 종료·보존한다 |
| `asr.allowed_engines` | 엔진 id 목록. 생략: personal 제한 없음, company 빈 목록 | 목록에 없는 엔진은 제외(`policy-engine`) |
| `asr.allowed_hosts` | 정확한 호스트명 목록. 생략: personal 제한 없음, company 빈 목록 | 목록에 없는 호스트는 제외(`policy-host`) |
| `asr.allow_foreign` | bool, `false` | `residency=foreign` 엔진(국외 처리)을 허용할지(`policy-foreign`) |
| `asr.daily_audio_minutes_cap` | 정수(분) | `ASR_CLOUD_DAILY_MINUTES`와 비교해 작은 값이 그날의 외부 오디오 상한이다(`cap`) |
| `asr.send_vocab.{server,cloud}` | bool. personal 둘 다 true, company server true / cloud false | vocabulary 용어를 엔진 종류별로 외부에 보내도 되는가 |
| `asr.org_consents` | 목록, `[]` | 5.3절. server 종류 엔진에 대한 조직 동의. 사용자의 TTY 동의를 대신한다 |
| `archive.allowed_roots` | 경로 템플릿 목록. 생략: personal 제한 없음, company 빈 목록 | `ARCHIVE_DIR`가 맞아야 Drive 레인이 열린다(7절) |
| `archive.local_roots` | 경로 목록, `[]` | `LOCAL_ARCHIVE_DIR`로 허용하는 추가 상위 폴더 |
| `llm.claude_bin_pin` | `{"team_id": "..."}` 또는 `{"sha256": "..."}` | company에서 `llm`=allow의 필수 조건. 실행 직전에 `codesign -R`로 검증(`policy-claude-unpinned`) |
| `llm.child_env` | `{}`. 이름은 코드에 고정된 목록만 | `claude` 자식 환경에 더할 변수. 허용 이름: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. 정책이 있을 때만 적용되고 이름은 고정한 CLI 버전에서 확인한 뒤 템플릿에 넣는다 |
| `runtime.root` | 절대 경로. company 전용 | root 소유 릴리스 폴더. 있으면 `PROJECT_DIR`와 `PYTHON_BIN`은 `<root>/current` 기준 값으로 고정된다(11절) |
| `defaults` | `{KEY: "값"}` | `config.env` 아래 층(9절) |
| `enforced` | `{KEY: "값"}`. company 기준 강제값이 합쳐진다 | `config.env` 위 층(9절) |
| `ext` | 자유 | 관리자 메모, 링 이름 같은 메타데이터. 두 파서가 무시한다. 알 수 없는 키가 허용되는 유일한 곳 |

## 4. 프로필: company와 personal

| | company | personal |
|---|---|---|
| 생략된 `lanes.*` | deny | allow |
| `allowed_engines`, `allowed_hosts`, `archive.allowed_roots`가 생략되면 | 빈 목록(해당 레인이 사실상 닫힘) | 제한 없음 |
| `approvals.<레인>` | `llm`, `asr_cloud`, `calendar`, `drive`의 allow에 필요. 없으면 deny | 쓰이지 않음 |
| `llm`=allow의 서명 핀 | 필요(`claude_bin_pin`) | 필요 없음 |
| `runtime.root` | 있으면 root 소유 런타임에서만 실행(Swift가 매 실행 전에 검증) | 쓰이지 않음 |
| 기준 강제값 | `LOG_CONTENT=0`, `ASR_ALLOW_DOWNLOAD=0`, `MIC_MUTE_GATE=on`, `NOTIFY_RECORDING=1` | 없음 |
| 용도 | 회사 배포 | 개인 설치에 정책 기능(예: 킬 스위치)을 따로 쓰고 싶을 때 |

company의 기준 강제값은 `enforced`에 **그 키를 명시해야** 덮어쓸 수 있다. company pkg는 항상 기준 정책(모든 외부 레인 deny, `local_only.default=true`)과 `policy.required`를 설치하고,
MDM이 완화 리비전을 내려야 레인이 열린다. 정책이 아예 없는 Mac(개인 설치)은 personal 프로필처럼 동작하지만 정책 관리 Mac은 아니다.

## 5. 레인, 승인, ASR

### 5.1 레인 판정식

```
lane_allowed(lane) = NOT local_only
                 AND policy_lane(lane) == allow
                 AND approval_ok(lane)          # company 프로필의 llm, asr_cloud, calendar, drive
                 AND user_enabled(lane)         # config.env (TRANSCRIPT_CLEANUP, NOTE_VERIFY, CALENDAR_LOOKUP, ASR_ENGINE ...)
                 AND 레인별 조건                # llm: company는 claude_bin_pin; drive: archive.allowed_roots; asr: 5.2~5.3
```

`policy.json`이 invalid이면(잠금) `policy-locked`가 앞의 모든 항을 이긴다. 판정 사유 코드 전체는 `docs/PRIVACY_LANES.md` 9절에 있다.

### 5.2 ASR 결정표 (위에서부터, 외부 레인을 닫는 규칙이 먼저)

| 순위 | 규칙 | 조건 | 결과 | 사유 코드 |
|---|---|---|---|---|
| A0 | 정책 잠금 | `policy.json`이 있으나 invalid, 또는 `policy.required`가 있는데 파일 없음 | 외부 레인 닫힘, 로컬 Whisper만 | `policy-locked` |
| A1 | 회의 local_only | 유효값 true | 외부 레인 닫힘 | `local_only` |
| A2 | 조직 제한 | lane deny, 엔진이 `allowed_engines`에 없음, 호스트가 `allowed_hosts`에 없음, 국외 처리 엔진인데 `allow_foreign=false`, 일일 분 상한 초과 | 해당 엔진 제외 | `policy-lane`, `policy-engine`, `policy-host`, `policy-foreign`, `cap` |
| A3 | 동의 | server 종류는 정책 `org_consents` 또는 사용자 동의, cloud 종류는 사용자 동의가 있어야 한다. 엔진, 호스트, 포트, 리전, 모델, 프로토콜, backend kind, 머신, 만료, 역할 중 하나라도 불일치 또는 `integrity` 불일치 | 해당 엔진 제외 | `no-consent`, `consent-mismatch`, `consent-expired`, `consent-tampered` |
| A4 | 사용자 설정 | `ASR_ENGINE`(`whisper` 기본, `remote`, `azure`, `clova`, `openai-compat`, `auto`), `ASR_FALLBACK`(`none` 기본, `whisper`, `remote`, `azure`, `clova`, `openai-compat`) | 후보 | - |
| A5 | 하드웨어 | `auto`일 때만: arm64, RAM >= `ASR_LOCAL_MIN_RAM_GB`, MLX 모듈 존재, 모델 존재, 측정 RTF <= `ASR_LOCAL_MAX_RTF`이면 whisper, 아니면 remote 후보. 로컬이 불가(`capable is False`)면 로컬 폴백도 제외 | 후보 선택 | `hw-capable`, `hw-incapable`, `hw-unknown` |
| A6 | 종합 | 명시한 외부 primary가 제외되면 로컬로 대체하고 경고. 로컬 불가이고 외부도 불가이면 blocked(단 `ASR_ENGINE=whisper` 명시는 막지 않고 시도) | `asr_policy_blocked` | - |

로컬은 새 송신을 만들지 않으므로 '닫힘'의 대체 경로는 항상 로컬이다. 클라우드로의 자동 전환은 없고, 하드웨어 폴백 대상은 사내 서버(릴레이)뿐이다.

### 5.3 `asr.org_consents` (서버 종류만)

회사 릴레이에 대한 조직 동의다. 사용자가 터미널에서 `mcap asr-engines consent remote`를 하는 일을 대신하고, 사용자 동의보다 CA 핀에서 권위가 있다. 항목 하나의 모양:

| 필드 | 뜻 |
|---|---|
| `engine` | 엔진 id. 서버 종류는 `remote` |
| `host`, `port` | 정확한 호스트명(DNS 이름, IP 불가)과 포트. 자격증명(Keychain account `<user>@<host>:<port>`)도 여기에 결박된다 |
| `protocol` | `mcap-asr/1` |
| `backend_kind` | 서버가 health에서 보고하는 종류와 같아야 한다. 정책 동의는 `server`(Whisper 백엔드)만 덮는다. 클라우드 종류는 정책이 대신 동의하지 않고 사용자가 TTY에서 동의한다 |
| `ca_sha256` | 필수. 서버 인증서를 서명하는 사설 CA PEM의 SHA-256(64 hex). 클라이언트는 파일을 한 번 읽어 해시를 검증하고 그 바이트만 신뢰한다 |
| `attest_build_sha256` | 서버 빌드 해시 허용 목록. health의 `attest.build_sha256`이 목록 밖이면 거부 |
| `use` | `primary`, `fallback`, `both` 중 하나(역할) |
| `expires` | 만료일(날짜). 지나면 `consent-expired` |

호스트는 (동의 또는 `org_consents`의 호스트) AND (`asr.allowed_hosts`)에 둘 다 있을 때만 쓰인다. 동의 문구는 원격 참석자의 목소리가 오디오에 있을 수 있다는 점, `ASR_SEND_VOCAB`가 켜진 때 vocabulary 용어가
간다는 점, 클라우드 백엔드의 릴레이는 오디오를 벤더로 전달한다는 점을 밝혀야 한다. 동의 파일의 `integrity`는 우연한 손상 검출용이고 MAC이 아니다: 조직 통제는 정책의 `allowed_hosts`가 한다.

## 6. 회의별 local_only와 정책

시작값(새 녹음, Swift가 `session.json`에 쓴다), 위에서부터 첫 번째:

1. 정책 잠금 또는 invalid: true (`policy-invalid`)
2. `policy.local_only.default`가 true: true (`policy-default`)
3. `LOCAL_ONLY_DEFAULT`가 참: true (`config-default`)
4. 그 외: false

- 정책 `locked`이면 유효값은 `session.json`에 무엇이 있든 true다(`policy-lock`). 앱 메뉴는 비활성이고 `조직 정책으로 고정` 문구를 보인다.
- 정책 `default`와 `LOCAL_ONLY_DEFAULT`는 OR로 합쳐진다. 사용자가 내릴 수 없다.
- 키가 없거나 null이면 같은 기본값 체인, bool이 아니면(`"false"`, `0`) true(`fail-closed:bad-type`)다.
- 래칫: 한 실행에서 true로 관측되면 끝까지 true다. 해제(OFF)는 다음 (재)처리부터 적용된다.
- 앱의 알림이 정책 오류를 알릴 때는 영문 원문 대신 사유 코드를 짧은 한국어로 바꾸고 `support.contact`를 100자 안에서 잘리지 않게 붙인다.

## 7. 아카이브

### 7.1 Drive 레인과 `archive.allowed_roots`

Drive 레인이 열리려면 `ARCHIVE_DIR`가 정책 루트와 맞아야 한다. 비교는 문자열 전체 글롭이 아니라 **구성요소별**이다.

1. `realpath(ARCHIVE_DIR)`를 NFC로 정규화하고 casefold 한 구성요소 목록을 만든다.
2. 정책 루트도 `~`를 확장하고 realpath 한 뒤 같은 방식으로 구성요소 목록을 만든다.
3. 루트의 각 구성요소는 `fnmatch`로 비교한다(구성요소 안에서 `*` 허용, 예: `GoogleDrive-*@example.com`). 루트의 구성요소를 모두 맞춘 접두 일치만 통과한다.
4. 일치하지 않으면 `policy-archive-root`다. company인데 `ARCHIVE_DIR`가 `config.env`에 명시되지 않았으면(내장 기본값은 개인용 로컬 폴더다) `archive-not-configured`다. 둘 다 Drive를 거부하고
   로컬 아카이브로 간다.

이동 직전에 다시 해석해 한 번 더 검사하고, 복사 뒤 이름을 바꾸기 직전에도 레인을 다시 본다(그 사이 local_only가 켜지면 `.partial`을 지우고 로컬로 간다).

### 7.2 로컬 아카이브

`LOCAL_ARCHIVE_DIR`(기본 `SUPPORT_DIR/local-meetings`)는 정책이나 `defaults`/`enforced`로 바꿀 수 없다. 허용 목록: realpath가 `SUPPORT_DIR` 아래이거나 `archive.local_roots`에 맞고, 경로에 심볼릭 링크가 없고,
홈과 같은 장치여야 한다. 아니면 `local_archive_unsafe`(재시도 안 함).

## 8. 판정이 어긋날 때: fail-closed 표

| 입력 | 없음 | 손상, 비정상 | 결과 |
|---|---|---|---|
| `session.json`의 `local_only` | 키 없음/null: 기본값 체인(`policy.local_only.default` OR `LOCAL_ONLY_DEFAULT`) | bool 아님(`"false"`, `0`): true, `fail-closed:bad-type`. 정책 locked면 false도 true(`policy-lock`) | |
| 게이트 시 `session.json` | - | 읽기/파싱 실패: 그 레인 거부, 래칫 true | 외부 거부 |
| `policy.json` | 파일도 마커도 없음: 정책 없음(개인) | 파싱 실패, schema != 1, 알 수 없는 키, profile 없음, 권한/소유자/심볼릭 링크, 256 KiB 초과, `min_pipeline_version` 초과: 잠금 | 모든 외부 레인 거부, doctor FAIL, 앱은 flag를 true로 강제 |
| 정책 값 | company: deny/빈 목록, personal: allow | `allow`/`deny` 외: deny | 레인별 |
| 동의 | 동의 없음 | JSON 오류: 동의 없음 + doctor FAIL. integrity 불일치: 전부 무효. 항목 불일치: 그 항목만 무효 | 외부 엔진 제외, 로컬 계속 |
| config 스위치 | 기본값 | 키별 제한값으로 읽음(`LOCAL_ONLY_DEFAULT`는 true, `ASR_ALLOW_DOWNLOAD`/`LOG_CONTENT`/`ASR_SEND_VOCAB`는 false, `MIC_MUTE_GATE`는 on) + doctor WARN | 숫자 오류는 기존대로 ValueError |
| capability 캐시 | 정적 판정 | 손상, 30일 초과, 머신 id/mlx 버전 불일치: 무시 | `auto`는 정적 기준 |
| Keychain 항목 | `EngineAuthError` | 타임아웃, 거부, host:port 불일치: `EngineAuthError` | 폴백 또는 로컬 |
| `cfg.asr_decision` 없음 + 비-whisper | - | - | `EnginePolicyDenied` |
| 서버 health | - | `proto` 불일치, `retention.mode` != `none`, backend kind 불일치, 정책 attest 허용 목록 밖 | `EnginePolicyDenied` |
| `LOCAL_ARCHIVE_DIR` | 기본값 | 허용 목록 밖 | `local_archive_unsafe` |
| `CLAUDE_BIN` 서명 | - | 핀 불일치(company, llm 허용 시) | llm 레인 deny(`policy-claude-unpinned`) |

## 9. `defaults`와 `enforced`: 설정 층

값의 우선순위(낮은 것부터): 내장 기본값 < `policy.defaults`(그 키가 `config.env`에 없을 때만) < `config.env`(사용자) < `policy.enforced`. 레인 허용 목록 같은 정책의 제한은 설정 값과 AND로 겹친다.

- 허용 키는 코드에 고정된 목록이다(`ASR_*`, 보존·로그 값, 알림, 예산, 플랫폼 목록 같은 동작 키. 정본은 `pipeline/mcap/policy.py`의 `DEFAULTS_WHITELIST`).
  `ARCHIVE_DIR`, `PROJECT_DIR`, `PYTHON_BIN`, `CLAUDE_BIN`, `SUPPORT_DIR`, `SELF_NAME`, `LOCAL_ARCHIVE_DIR`는 **어떤 층으로도 바꿀 수 없다.**
- 다른 앱의 통화 키(`CALL_DETECT`, `CALL_GENERIC_SECONDS`, `EXTRA_MEETING_APPS`, `CALL_BROWSER_URLS`)도 허용 키다. `ENABLED_PLATFORMS`는 Zoom, Teams, Meet만 정하고 다른 앱의 통화는 `CALL_DETECT`가 정한다.
  정책이 있는 Mac에서 `config.env`도 정책도 `CALL_DETECT`를 정하지 않으면 `off`다(기준 정책의 `ENABLED_PLATFORMS=zoom,teams`는 Zoom과 Teams만 녹음한다는 뜻 그대로). 켜려면 `defaults`에 `known`, 잠그려면 `enforced`에 쓴다(`"enforced": {"CALL_DETECT": "off"}`).
  `recording.enabled=false`이면 다른 앱의 통화는 `app.log`에 한 줄만 남기고 건너뛴다("녹음 실패" 알림 없음). `MIC_MUTE_GATE=on`이어도 통화 앱 자신의 음소거 상태는 읽을 수 없어 마이크는 녹음된다(메뉴의 Pause Microphone이 확실한 방법).
- 값은 `config.env` 파서와 같은 규칙으로 검증된다(알 수 없는 스위치 텍스트는 그 키의 제한값). 값은 문자열로 쓴다(`"0"`, `"on"`).
- company의 기준 강제값(`LOG_CONTENT=0`, `ASR_ALLOW_DOWNLOAD=0`, `MIC_MUTE_GATE=on`, `NOTIFY_RECORDING=1`)은 `enforced`에 합쳐진 상태로 시작한다. 덮으려면 그 키를 `enforced`에 직접 쓴다.
- company이고 `runtime.root`가 있으면 `PROJECT_DIR`/`PYTHON_BIN`은 `<root>/current` 기준으로 고정되고 `config.env`의 값은 무시된다. 모델은 릴리스 안의 읽기 전용 폴더이고 `ASR_MODEL`을 `defaults`로 그 경로에 둔다
  (`ASR_ALLOW_DOWNLOAD=0`이므로 첫 실행 다운로드가 없다).
- 보존 기간(`AUDIO_RETENTION_DAYS`, `LOCAL_ARCHIVE_RETENTION_DAYS`, `STAGING_FAILED_RETENTION_DAYS`, 로그 보존)은 `enforced`로 상한을 건다. 기본은 모두 0 = 보관(기존 동작)이고 전사본과 노트는 어디서도
  자동 삭제되지 않는다. 기간 값은 관리자와 법무가 정한다(이 문서는 숫자를 권하지 않는다).
- 앱은 `AppConfig.load`에서 같은 층을 같은 허용 목록으로 적용한다(`PolicyLayers`).

## 10. 배포, 롤아웃, 사고 대응

- 정책은 기기군별로 MDM이 root 소유 0644로 배포하고 리비전을 올린다. 임시 파일에 쓰고 rename 한다(쓰는 중간 상태가 읽히지 않게).
- **버전 올림 규칙:** 새 키가 들어간 정책은 새 파이프라인 링이 끝난 뒤에 내린다. 구버전은 알 수 없는 키를 잠금으로 읽어 문제를 드러낸다(조용히 무시하지 않는다).
- 링별 배포(3-5대 카나리, 일부, 전체)는 `mcap status`의 `pipeline_version` 분포와 `policy.revision`을 지표로 쓴다.
- 중간 변경: 진행 중인 실행도 `policy.json`의 (mtime, inode, 크기)가 바뀌면 다시 읽고 새 판정이 더 엄격하면 그것을 쓴다. 완화는 진행 중인 실행에 적용하지 않는다.

사고 대응(MDM에 의존하지 않는 경로를 먼저 쓴다):

| 상황 | 조치 | 효과 시점 |
|---|---|---|
| 외부 송신 즉시 중단 | `lanes` 전부 deny 리비전(또는 `local_only.locked`) | 진행 중 실행의 다음 외부 시도부터, MDM 지연은 별도 |
| 녹음 즉시 중단 | `recording.enabled=false` | 앱이 60초 안에 진행 중 녹음을 정상 종료·보존 |
| 릴레이 토큰 유출 | `token revoke`, `org_consents` 제거 리비전 | 다음 요청부터(서버), MDM 없이도 가능 |
| Console API 키 유출 | Console에서 키 폐기와 회전 | 즉시(MDM 불필요) |
| 릴레이 침해 | 정책에서 호스트 제거, 서버 격리, 메타 로그 검토, 벤더 키 회전 | MDM 배포 시점 |
| 잘못된 정책 배포 | 이전 리비전 재배포(잠금된 기기는 외부 레인이 닫힌 채 로컬 전사 계속) | MDM 배포 시점 |
| 분실 기기 | FileVault 의존, 토큰 폐기, Workspace 기기 로그아웃 | 즉시(토큰) |
| 퇴사 | `offboard_user.sh`(토큰 폐기, 서버 `sync`, 로컬 데이터 처리 안내) | 즉시 |

## 11. 코드가 강제하는 것과 MDM이 있어야 강제되는 것

| 대상 | 코드가 막는 것 | 방법 | 못 막는 것 |
|---|---|---|---|
| 호기심 많은 직원(표준 사용자) | `ASR_ENGINE`을 임의 벤더로 바꿔 오디오 송신, local_only 해제, 타인 토큰 사용 | 호스트는 (동의 AND 정책 `allowed_hosts`)에서만 만들고 비밀은 host:port에 결박, 정책은 root 소유(권한 검사), 토큰은 사용자별 SHA-256, 서버는 내용을 저장하지 않음 | 본인 계정에서 본인 데이터를 복사하는 행위, 본인 녹화 |
| 설정 실수 | 오타, 잘못된 리전, 동의 후 설정 변경, 정책 파일 손상, 정책 키 오타 | fail-closed(8절), 동의 결박과 무효화, 정책 스키마 엄격(알 수 없는 키 = 잠금) | 올바른 설정이지만 법적으로 부적절한 선택 |
| 같은 사용자 권한 악성코드, 로컬 관리자 | 없음(설계가 막지 않는다) | `security`로 만든 Keychain 항목은 같은 사용자의 아무 프로세스가 읽을 수 있고 동의, config, 사용량, 개인 설치의 코드는 사용자가 쓸 수 있다 | 실질 강제는 MDM(표준 사용자, 앱 허용 목록, 프로세스별 네트워크 허용, FileVault)과 root 소유 런타임 |
| 정책 없는 기기(미등록 Mac) | 없음 | pkg는 항상 `policy.required`와 기준 정책을 깐다. MDM이 완화 리비전을 내려야 열린다 | MDM에 등록되지 않은 Mac은 개인 프로필과 같다 |

company 프로필의 root 소유 런타임(`runtime.root`)은 권장이 아니라 필수 조건이다: Swift가 매 실행 전에 `pythonBin`과 `projectDir/pipeline`의 realpath가 그 루트 아래이고 경로의 각 구성요소가 uid 0이며
그룹/기타 쓰기 불가임을 확인한다(아니면 `runtime-untrusted`로 실행을 거부하고 알린다). 레이아웃, 서명, 릴리스 롤백은 `docs/DEPLOY.md`에 있다. 개인 설치(정책 없음)에는 이 요구가 없다.

## 12. 버전과 호환

- `min_pipeline_version`: 이보다 낮은 파이프라인은 정책을 잠금으로 읽는다. 정수 튜플로 비교한다.
- Swift 앱의 실행 전 계약(`PipelineContract`): 정책이 있거나, `policy.required`가 있거나, 세션의 `local_only`가 true이면 `max(0.2.0, policy.min_pipeline_version)` 이상의 파이프라인일 때만 실행한다.
  아니면 실행하지 않고 세션을 staging에 그대로 두며(시도 횟수에 넣지 않음) `파이프라인 업데이트가 필요해요` 알림과 `policy-status`의 `pipeline_too_old`로 알린다.
  정책도 없고 `local_only`도 false인 개인 설치는 이전 파이프라인과도 그대로 동작한다.
- `mcap release switch`는 `min_pipeline_version` 미만이나(정책이 있을 때) 0.2.0 미만으로의 전환을 거부한다.
- `config/policy.example.json`의 `min_pipeline_version`은 `0.1.0`이다: 그 파일이 정책을 읽을 수 있는 모든 파이프라인에서 valid로 남도록 한 값이고(Swift 앱은 정책이 있으면 어차피 0.2.0 이상을 요구한다), 실제
  정책은 함대가 0.2.0 이상이 된 뒤 `0.2.0` 이상으로 쓴다.

## 13. 진단

| 명령 | 보여 주는 것 |
|---|---|
| `CATE policy-status [--json] [--console-user]` | 앱이 읽은 정책 상태, 프로필, 리비전, 해시 앞 8자, 시작값, lanes, 계약/신뢰 상태. 내용 없음. MDM이 root로 실행하므로 `--console-user`가 콘솔 사용자의 HOME과 config를 읽는다 |
| `mcap doctor` | 정책이 없으면 출력이 지금과 같다. 있으면 프로필, 정책 상태(리비전, 해시, 잠금 사유), local-only 기본값, ASR 경로(정책과 동의 적용 후 유효값), 동의 유효기간, 자격증명 존재(값 없음), 허용 호스트 라벨, capability, 로컬 아카이브, 로그 내용 모드, 일일 상한 사용량. 거부된 레인의 확인은 `skipped: lane denied` |
| `mcap status [--json]` | 내용 없는 상태: `profile`, `policy{state,revision,sha256_8,locked_reason}`, `route`, `consent`, `local_only_default` 등. 20 KB 이하 |

company에서 `local_only.locked`인데 로컬 전사가 불가(`capable` false)이거나 FileVault가 꺼져 있으면 doctor는 FAIL이다(그런 Mac은 전사본을 하나도 못 얻는다: `asr_policy_blocked`).

## 14. 공통 시험 코퍼스

`config/policy-fixtures/`(정상, 알 수 없는 키, 중복 키, BOM, 형식 오류, 권한 변형, 레인 이상값, 생략된 목록, 승인 없는 레인, 아카이브 루트 사례)와 `index.json`(파일, 주입한 파일 정보, 기대 상태,
사유 부분 문자열, 유효 레인, local_only 기본, 녹음 플래그)을 Python과 Swift 시험이 모두 읽어 같은 판정을 강제한다. 새 규칙은 코퍼스에 사례를 먼저 더한다.

## 15. 예시

### 15.1 기준 정책: 아무것도 열지 않는다

`config/policy.example.json`. 모든 레인이 deny이고 승인이 하나도 없으며 `local_only.default`가 true다. company pkg가 까는 기준 정책과 같은 성격이다.
한 번에 레인 하나만 열고, 열 때는 `lanes.<레인>`을 `allow`로 바꾸는 것과 `approvals.<레인>`에 실제 참조를 넣는 것을 한 리비전에서 함께 한다.

### 15.2 회사 일반 기기: 서버 ASR과 팀 드라이브만

```
"lanes": {"asr_remote":"allow","asr_cloud":"deny","llm":"deny","calendar":"deny","drive":"allow"},
"approvals": {"drive":"TICKET-1234"},
"local_only": {"default":false,"locked":false},
"asr": {"allowed_engines":["whisper","remote"],"allowed_hosts":["asr.example.internal"],"org_consents":[ ... 5.3절 ... ]},
"archive": {"allowed_roots":["~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"]}
```

`llm`과 `calendar`는 deny이므로 전사본만 나온다(노트, 캘린더 없음). 위 줄들은 기준 정책에서 바뀌는 부분만 보인 발췌이고 나머지 키는 그대로다. 호스트 `asr.example.internal`은 예시 이름이다.

### 15.3 임상·제휴병원 기기군: 플래그 고정

일반 기기 정책에서 `local_only`만 바꾼다.

```
"local_only": {"default":true,"locked":true}
```

플래그가 항상 true이므로 노트·캘린더·Drive·원격 ASR이 모두 없다. 이 기기군에는 로컬 probe를 통과한 Mac만 둔다(로컬 전사가 불가능하면 전사본을 못 얻는다).

### 15.4 파일럿 자원자 링: LLM 허용

```
"lanes": {"llm":"allow"},
"approvals": {"llm":"<승인 참조>"},
"llm": {"claude_bin_pin":{"team_id":"<10자 Team ID>"},"child_env":{}}
```

`llm`을 열려면 위 세 가지가 모두 필요하다: 승인 참조, 서명 핀, 그리고 사용자 설정. Console 워크스페이스와 키별 월 지출 한도를 만들고 CLI 서명의 Team ID 또는 sha256을 확인하는 일은 관리자 작업이다.

### 15.5 personal 프로필

```json
{"schema":1,"profile":"personal","revision":1,"recording":{"enabled":true}}
```

생략된 레인은 allow이고 목록은 제한 없음이다. 개인 설치에 킬 스위치 같은 정책 기능만 따로 쓰고 싶을 때의 모양이다.

## 16. 하지 않는 것

- 정책은 레인을 *열지* 못한다: 동의와 사용자 설정이 없으면 allow도 아무 일을 하지 않는다.
- 정책은 회의 내용을 읽는 경로가 아니다. 관리자가 회의 내용을 읽는 기능은 비목표다.
- `ARCHIVE_DIR`, `PROJECT_DIR`, `PYTHON_BIN`, `CLAUDE_BIN`, `SUPPORT_DIR`, `SELF_NAME`, `LOCAL_ARCHIVE_DIR`를 정책으로 바꾸지 않는다(개인 설치의 공유 계약 파일과 동작 보존).
- `/Library/Managed Preferences`(CFPreferences) 같은 두 번째 정책 소스는 v1에 없다(우선순위와 변조 규칙이 따로 필요하다). MDM 제품은 root 소유 파일을 배포할 수 있다.
