# 개인정보 레인: 무엇이 이 Mac 밖으로 나가고 언제 막히는가

상태: **실험적 (조직 모드, SPEC 18).** 이 문서는 프라이버시 레인의 설계를 사람이 읽는 표로 옮긴 것이다. 법률 판단은 담지 않는다
(고지, 동의, 보관 기간, 국외 이전은 관리자와 법무가 정하고, 참석자 고지 문구는 법률 자문을 받는다). **개인 설치(정책 파일 없음, 새 설정 키 없음)의 외부 송신 동작과
출력 파일(전사본, 노트, 아카이브 폴더)의 바이트는 이 기능이 없을 때와 하나도 다르지 않다.**

관련 문서: 정책 파일은 `docs/POLICY.md`, 서버 프로토콜은 `docs/ASR_PROTOCOL.md`, 설정 키는 `config/config.env.example`.

## 1. 한눈에

외부로 나갈 수 있는 길은 **다섯 레인**이다. 그 밖의 로컬 임시 파일과 로그는 나가지 않는다.

| 레인 | 코드 지점 | 나가는 것 |
|---|---|---|
| 원격 ASR, 클라우드 ASR (`asr_remote`, `asr_cloud`) | `asr.transcribe_track`의 엔진 호출 | 청크 PCM(외부 엔진을 고른 경우에만) |
| LLM (`llm`) | `note.call_claude`(정리, 노트, 검증), `note.preflight`/`check_ready`(프로세스 기동, 키체인 읽기) | 전사 텍스트, vocabulary, 제목 힌트, 캘린더 참석자 |
| 캘린더 (`calendar`) | `calendar_lookup.fetch_events` | 녹음 시작 ±45분 시간대 요청(제목과 참석자가 `claude` 세션을 지나감) |
| Drive (`drive`) | `publish.publish` → `ARCHIVE_DIR`(Drive for desktop 동기화) | 회의 폴더 전체(m4a 3개, 전사본, 노트 등) |
| 로컬 임시·로그 | staging WAV, `.prep-*`, 로그, 사용량 기록 | 없음(보존, 백업 제외, 로그의 내용 노출은 `LOG_CONTENT`가 통제) |

핵심 규칙 셋.

1. **`local_only`는 단일 플래그다.** 회의별 유효값이 true이면 외부로 나가는 다섯 레인(원격 ASR, 클라우드 ASR, LLM, 캘린더, Drive)을 모두 막는다. 일부만 여는 값은 없다.
   ASR만 막는 해석과 별도의 '민감 LLM' 스위치는 만들지 않았다.
2. **외부 송신은 네 조건이 모두 참일 때만 일어난다:** (회의가 local_only 아님) AND (조직 정책 허용) AND (유효한 동의) AND (사용자 설정에 명시). 클라우드로의 자동 전환,
   '민감하지 않은 회의' 자동 판정은 없다.
3. **조직 정책은 제한만 한다.** 개인 설정보다 강하게 막을 수는 있어도 개인 설정을 완화시키지는 못하고, 깨진 입력은 항상 닫히는 쪽으로 해석한다. 닫는 것이 회의 손실이 되지 않도록
   로컬 처리는 계속한다(전사본과 녹음은 남는다).

이 문서가 하지 않는 주장: '오디오는 이 Mac을 떠나지 않는다'는 문장은 거짓이므로 어디에도 쓰지 않는다. Drive 레인이 열려 있으면 m4a가 Drive 폴더로 간다.

## 2. 레인별 표

범례: 송신 = 이 Mac 밖으로 나가는 것. 어떤 모드에서도 ASR 요청에 제목, 세션 ID, 플랫폼, 참석자, 파일명은 포함되지 않는다. 승인 참조 = company 정책의 `approvals.<레인>`.
열: **개인 기본**(현행 개인 설치) / **조직 정책**(company 프로필) / **local_only=true**(그 회의) / **서버 티어**(`remote` 엔진) / **클라우드 티어**(`azure` 엔진).

### 2.1 ASR 오디오

| 모드 | 동작 |
|---|---|
| 개인 기본 | 송신 없음. 로컬 mlx-whisper. |
| 조직 정책 | `asr_remote`, `asr_cloud` 레인과 `asr.allowed_engines`, `asr.allowed_hosts`(생략 = 빈 목록)가 제한한다. 동의 필수(서버 종류는 정책 `org_consents`가 대신할 수 있고, 클라우드는 사용자 동의). 클라우드는 승인 참조가 필요하다. |
| local_only=true | 외부 엔진을 만들지 않는다. 로컬만(모델 다운로드도 금지). 로컬 전사가 불가능한 Mac이면 오디오를 보존하고 `asr_policy_blocked`로 실패한다. |
| 서버 티어 | 송신: 에코 제거 후 VAD 발화 청크(16 kHz mono int16, 28초 이하)와 언어 식별 클립(6초 이하) → 동의/정책 호스트 1개(HTTPS, Bearer 토큰). 서버는 메모리에서만 처리하고 저장하지 않는다. |
| 클라우드 티어 | 송신: 같은 청크 → `koreacentral.api.cognitive.microsoft.com`(단일 Mac이 직접) 또는 릴레이 경유(회사). 벤더의 보관은 벤더의 주장이고 검증되지 않았다. |

오디오에는 원격 참석자의 목소리가 들어 있을 수 있다(시스템 오디오 트랙). 동의 문구가 이를 밝힌다.

클라우드 제공자(`clova`, `openai-compat`; `asr_providers.py`, 추가 방법은 `ADD_A_PROVIDER.md`)는 같은 `asr_cloud` 레인과 같은 게이트(local_only, 정책, 동의, 호스트와 포트 결박, https만, 리다이렉트 금지)를 쓴다. 다른 점은 넷이다. (1) 28초 청크가 아니라 쉼을 잘라 이어 붙인 발화 블록(최대 `ASR_CLOUD_BLOCK_SECONDS`초, 16 kHz mono WAV, 파일명 `block.wav`)을 요청 하나로 보낸다: 벤더가 요청마다 올림해 과금하기 때문이다. (2) `openai-compat`는 보내는 곳과 그 뒤의 벤더를 사용자가 정하므로 `policy.ENGINE_META`가 `destination chosen by the user`라고 적고, 거주지는 `foreign`(회사 정책은 `asr.allow_foreign`이 필요)이며, 동의 문구가 설정된 호스트를 밝힌다. (3) CLOVA는 용어를 `boostings`로 보내고(`ASR_SEND_VOCAB`와 정책이 모두 허용할 때만) `openai-compat`는 용어를 보내지 않는다. (4) CLOVA 인보크 URL의 경로(도메인 식별자)와 API 키는 로그, 상태 파일, 사용량 기록, `transcript.json`에 남지 않는다(`asr-usage.jsonl`에는 호스트만 있다). 요금은 사용자와 벤더 사이의 일이고 이 프로젝트는 금액을 추정하거나 예산을 두지 않는다. 호출마다 오디오 초만 기록하고 하루 상한 `ASR_CLOUD_DAILY_MINUTES`는 그대로 적용된다.

### 2.2 vocabulary

| 모드 | 동작 |
|---|---|
| 개인 기본 | 로컬 Whisper 프롬프트로만 쓰인다(송신 없음). |
| 조직 정책 | `asr.send_vocab`(서버/클라우드 종류별)이 제한한다. company의 클라우드 기본은 false. |
| local_only=true | 송신 없음. |
| 서버 티어 | 송신: 용어 목록 PUT(`ASR_SEND_VOCAB`가 켜진 때만, 동의 문구에 명시). 목록에 파트너·경쟁사 이름이 들어 있을 수 있다. |
| 클라우드 티어: Azure | 송신: Azure `phraseList`(`ASR_SEND_VOCAB`가 켜진 때만). |
| 클라우드 티어: CLOVA | 송신: CLOVA `boostings`(용어만, 별칭 제외, 한 글자 용어와 한글·영어 밖의 문자가 있는 용어는 뺀다, 최대 1000개). `ASR_SEND_VOCAB`가 켜져 있고 정책 `asr.send_vocab.cloud`가 허용할 때만 가고 동의 문구에 명시된다. 목록에 파트너·경쟁사 이름이 들어 있을 수 있다. |
| 클라우드 티어: openai-compat | 송신 없음: 요청에 용어 필드가 없다(요청에는 모델 이름과 저장된 API 키가 간다). |

### 2.3 LLM 정리, 노트, 검증

| 모드 | 동작 |
|---|---|
| 개인 기본 | 송신: 전사 세그먼트, vocabulary, 제목 힌트, 정리본/원문 전문, 메타(제목, 날짜, 플랫폼 라벨, 캘린더 참석자) → `claude -p` → Anthropic. `claude` 프로세스 기동과 키체인 읽기를 포함한다. |
| 조직 정책 | `lanes.llm`. 승인 참조와 `llm.claude_bin_pin`(서명 핀)이 없으면 deny. 기본 deny이고 파일럿 자원자 링에서만 allow. |
| local_only=true | 차단(`skipped:local_only`). `claude` 프로세스 0개, 키체인 읽기 0회. `meeting-note.md`는 만들어지지 않는다. |
| 서버/클라우드 티어 | ASR 티어와 독립이다. ASR 엔진을 고르는 것이 LLM 레인을 열지 않는다. |

### 2.4 캘린더 조회

| 모드 | 동작 |
|---|---|
| 개인 기본 | 송신: 녹음 시작 ±45분 시간대(요청). 일치 1건만 `calendar.json`에 보관한다. claude.ai 구독 로그인으로 호출 1회. |
| 조직 정책 | `lanes.calendar`. company 기본 deny(커넥터가 claude.ai 로그인에 묶여 있음). 승인 참조가 필요하다. |
| local_only=true | 차단. 제목은 창 제목 힌트나 플랫폼명을 쓴다. |
| 서버/클라우드 티어 | 독립이다. |

**Google Calendar 읽기 접근 (캘린더 자동 시작, 선택, 기본 꺼짐).** `OFFLINE_AUTOSTART=auto`이면 앱이 `python -m mcap gcal upcoming`으로 본인 기본 캘린더의 지금 전후 일정(제목, 시간, 장소, 내 응답, 다른 참석자 수, 화상회의 링크 유무)을 읽어 대면 대화의 녹음을 스스로 시작한다. 읽기 전용(`calendar.readonly`)이고 본인 Google Cloud OAuth 클라이언트와 로그인을 쓰며 토큰은 키체인에만 있고 통신 상대는 Google뿐이다(Anthropic 등 다른 곳으로는 아무것도 가지 않고 캘린더에 쓰지도 않는다). 이 접근도 `calendar` 레인의 게이트(`lanes.gate("calendar")`)를 지난다: 조직 정책의 deny, 승인 참조 없음, 잠금, local_only 잠금이면 요청 없이 `lane_denied`로 답하고, 실행 중인 파이프라인이 있으면 그 실행의 판정을 따른다. 명시적 명령(실행 중인 파이프라인 없음)에서는 사용자의 `CALENDAR_LOOKUP`과 `LOCAL_ONLY_DEFAULT`가 이 접근을 막지 않는다(그 둘은 claude.ai 커넥터 조회와 회의별 기본값의 설정이다). 이 기능이 시작하는 녹음은 그 자리에 있는 사람들의 녹음이며 버튼 없이 시작되므로 동의 문제가 그대로 따른다. [docs/CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md).

### 2.5 Drive 아카이브

| 모드 | 동작 |
|---|---|
| 개인 기본 | 송신: 회의 폴더 전체(m4a x3, `transcript.md`/`json`, 노트, `session.json`, `calendar.json`)를 `ARCHIVE_DIR`로 이동(Drive for desktop이 동기화). 같은 디스크가 아닐 때 복사 중에 생기는 숨김 `.partial` 폴더도 동기화될 수 있다. |
| 조직 정책 | `lanes.drive` + 승인 참조 + `archive.allowed_roots`(realpath의 구성요소별 비교, 팀 공유 드라이브로 제한). 어긋나거나 company에서 `ARCHIVE_DIR`가 config.env에 명시되지 않았으면 로컬 아카이브로 간다. |
| local_only=true | 차단. `LOCAL_ARCHIVE_DIR`(허용 목록으로 검증, 기본 `SUPPORT_DIR/local-meetings`)에 저장한다. 이동 직전과 복사 커밋 직전에 레인을 다시 확인한다. |
| 서버/클라우드 티어 | 독립이다. |

### 2.6 로컬 임시, 로그, 사본

| 모드 | 동작 |
|---|---|
| 개인 기본 | 송신 없음. staging WAV(게시 후 삭제), `.prep-*`, `pipeline-*.log`(최대 60자 전사 조각), `app.log`(제목 포함), `usage.jsonl`, `asr-usage.jsonl`. Time Machine 제외는 `sessions/`와 `local-meetings/`에 건다. |
| 조직 정책 | `LOG_CONTENT=0` 기준 강제(전사 조각과 제목을 해시와 길이로 바꿈), 로그 보존일, 앱 로그 회전, 보존 기간 상한(`enforced`). |
| local_only=true | 위와 같고, 추가로 엄격 소켓 트립와이어(루프백과 AF_UNIX 외 연결을 거부)와 알림·로그에서 제목 제외. |
| 서버/클라우드 티어 | 위와 같다. |

## 3. 모드 간 규칙

1. local_only는 위 표의 모든 외부 송신 칸을 '차단'으로 만든다.
2. 조직 정책의 거부는 해당 레인만 같은 방식(`skipped:policy-lane` 등)으로 건너뛴다.
3. 레인을 막아도 실패가 아니다(`stage=done`, `error=null`). 단 ASR이 불가능한 경우는 `asr_policy_blocked` 실패다(오디오 보존, 자동 재시도 없음, 수동 `mcap reprocess <폴더>`는 가능).
4. 서버/클라우드 티어는 ASR 레인의 선택지일 뿐 LLM, 캘린더, Drive 레인을 열지 않는다.
5. 모든 레인 검사는 프로세스 기동, 키체인 읽기, 예산 계산, 소켓보다 먼저다(`ready()`, `check_ready`, `preflight`도 마찬가지로 레인 검사 뒤다).

## 4. 프로필별 기본값

| 프로필 | `local_only` 기본 | 레인 | 결과 |
|---|---|---|---|
| 개인 설치(정책 없음, 새 config 키 없음) | false | 현행 그대로: 로컬 Whisper, Claude 정리/노트/검증(api), 캘린더(구독 로그인), Drive | 오늘과 동일 |
| 회사 일반 기기 | false | `asr_remote`=allow, `asr_cloud`=deny, `llm`/`calendar`는 승인 참조 전까지 deny(파일럿 자원자 링만 `llm`=allow), `drive`=allow + `archive.allowed_roots`를 팀 공유 드라이브로 제한 | 승인 전에는 전사본만 나온다 |
| 임상·제휴병원 기기군 | true, 잠금(locked) | 위와 같으나 플래그가 항상 true | 노트·캘린더·Drive·원격 ASR이 전부 없다. 로컬 probe를 통과한 Mac만(아니면 `asr_policy_blocked`) |
| 정책이 없는 기기(pkg 미설치, MDM 미등록) | 개인 프로필과 같다 | 개인 프로필과 같다 | company pkg는 항상 기준 정책(모든 외부 레인 deny, local_only 기본 true)과 `policy.required`를 깔고 MDM이 완화 리비전을 내려야 열린다. 그 pkg와 MDM이 닿지 않은 Mac은 보호받지 못하고 doctor/status가 정책 부재를 FAIL로 보고한다 |

`config/policy.example.json`이 이 기준 정책(모든 레인 deny, 승인 없음)의 예시다.

## 5. local_only가 정확히 하는 일

**거부되는 것:** 원격/클라우드 엔진 생성, `claude` 프로세스 기동 전부(`auth status`, 정리, 노트, 검증, 캘린더), Anthropic 키의 키체인 읽기, `ARCHIVE_DIR`로의 이동, 모델 다운로드.

**로컬에서 만들어지는 것:** m4a 3개, `transcript.json`/`transcript.md`, 제목(창 제목 힌트 또는 플랫폼명), `state.json`. 폴더는 `LOCAL_ARCHIVE_DIR/YYYY-MM/YYYY-MM-DD_HHMM_<slug>/`다.
`meeting-note.md`는 없다. 이 폴더는 `state.json`을 지우지 않는다(정상 아카이브의 '상태 파일 없음' 규칙의 문서화된 예외이고, 조직이 레인을 거부한 폴더도 같다).

**표시 세 곳:**

- `state.json`의 `local_only`, `local_only_source`, `lanes`(예: `"llm":"skipped:local_only"`).
- `transcript.json["policy"]`(local_only이거나 조직이 레인을 거부한 경우에만 생긴다).
- `transcript.md` 머리의 한 줄 `Privacy: local-only (note, calendar, Drive skipped)`.

외부 엔진이 한 청크라도 처리했으면 `transcript.json["asr"]`가 생긴다(엔진, 종류, 목적지 라벨, 청크 수, 폴백 횟수, 송신 횟수·초·바이트). 목적지는 정확한 호스트가 아니라 동의/정책의
라벨(서버)이나 `벤더/리전`(클라우드)이다. 전사 폴더가 Drive로 가므로 내부 호스트명을 싣지 않고, 정확한 호스트는 로컬 `asr-usage.jsonl`에만 있다. 두 키가 모두 없는 폴더는 지금과
바이트까지 같다.

엔진이 자기 기록(provenance)을 내지 못하거나 쓸 수 없는 값을 주면(예외, dict가 아님, 빈 값) 외부 엔진에 한해 엔진이 스스로 밝힌 이름과 종류만으로 내용 없는 최소 블록
`{"engine", "kind", "privacy": "unknown"}`을 쓴다. 이때 머리는 `ASR: <엔진> (<종류>, model unknown)`과 `Route: ... (privacy unknown)`이고 설정된 Whisper 모델 이름을 모델처럼
보이지 않는다. 블록은 정해진 키만(문자열은 한 줄, 길이 제한, 수는 유한한 값) 남기고, 호스트나 토큰 같은 다른 값은 버린다.

**flag 해석 (회의별 유효값):**

| 입력 | 결과 |
|---|---|
| `session.json`에 값 있음(bool) | 그 값. 단 정책 `local_only.locked`가 참이면 false도 true(`policy-lock`) |
| 키 없음 또는 null | 기본값 체인: `policy.local_only.default` OR `LOCAL_ONLY_DEFAULT` |
| bool이 아닌 값(`"false"`, `0` 등) | true(`fail-closed:bad-type`) |
| 게이트 시 `session.json`을 읽지 못함 | 그 레인 거부, 이후 끝까지 true(`session-unreadable`) |

## 6. 게이트 규칙 (요약)

- **활성-실행 레지스트리.** 게이트는 ContextVar가 아니라 프로세스 전역 레지스트리다. 정리 단계가 `ThreadPoolExecutor` 워커에서 `claude`를 부르는데 워커 스레드는 ContextVar를 상속하지 않기 때문이다.
  활성 실행이 있으면 어느 스레드에서 불러도 그 실행의 판정이 돌아온다.
- **순서.** 레인 검사는 언제나 (a) 준비 확인과 프로세스 기동, (b) 키체인 읽기, (c) 예산·호출 상한 계산, (d) 소켓보다 앞이다.
- **재읽기.** 레인 검사는 캐시 없이 매번 `session.json`을 읽는다. 모든 외부 시도 직전(LLM 호출, ASR HTTP 시도의 재시도마다, 캘린더, Drive 복사 시작과 커밋 직전)에 부른다.
  조직 정책도 같다: `policy.json`의 (mtime, inode, 크기)가 바뀌었으면 다시 읽고, 새 판정이 더 엄격하거나 invalid이면 그것이 이긴다(중간에 완화는 적용하지 않는다).
- **래칫.** 한 실행에서 true로 한 번 관측되면 끝까지 true다. OFF(완화)는 다음 (재)처리부터 적용되고 앱은 처리 시작 전에만 허용한다.
- **보증 범위.** 약속하는 것은 '새 외부 시도를 시작하지 않는다'이다. 이미 진행 중인 HTTP 요청이나 `claude` 호출은 끝날 때까지 간다.
  처리 중에 local_only가 켜지면 다음 시도부터 외부 호출 없이 로컬(폴백)로 간다.

## 7. ASR 요청에 들어가는 것

- 들어가는 것: AEC 적용 후 마이크 트랙(적용하지 않기로 했으면 원본)과 remote 트랙의 VAD 발화 청크(16 kHz mono int16 PCM, 약 28초 이하), 언어 식별용 짧은 클립(클립당 6초 이하, 요청당 12개 이하).
  `ASR_SEND_VOCAB`가 켜져 있으면 용어 목록. 인증 토큰, 로그 상관용 무작위 실행 번호, 머신 id 해시 앞 16자.
- 들어가지 않는 것: 무음, 제목, 세션 ID, 플랫폼, 참석자, 파일명.
- 에코 제거, 스피커 누설 억제, VAD, 청크 계획은 항상 클라이언트(이 Mac)에서 한다. 서버는 청크를 받아 텍스트를 돌려줄 뿐이다.

와이어 형식의 전부는 `docs/ASR_PROTOCOL.md`에 있다.

## 8. 누가 무엇을 쓰고 읽는가

| 입력 | 위치 | 쓰는 주체 | 읽는 주체 |
|---|---|---|---|
| 회의별 flag | `session.json`의 `local_only`, `local_only_source`(+ `mic_gate` 집계) | Swift만 | Swift, Python |
| 회의별 부가 기록 | `SUPPORT_DIR/session-private/<id>.json` (`local_only_history` 최대 20건, 음소거 구간) | Swift만(Drive로 가지 않음) | Swift |
| 조직 정책 | `/Library/Application Support/MeetingCapture/policy.json`, `policy.required` | root/MDM만 | Swift, Python(경로를 바꿀 수단 없음) |
| 동의(사용자 기록) | `SUPPORT_DIR/asr-consent.json` | `mcap asr-engines consent`/`revoke`(TTY)만 | Python |
| 사용자 설정 | `SUPPORT_DIR/config.env` | 사용자(직접 편집, 또는 앱 메뉴 `Settings…`: 건드린 줄만 바꾸고 API 키는 쓰지 않는다) | Swift, Python |
| 하드웨어 probe | `SUPPORT_DIR/asr-capability.json` | `mcap asr-engines check --probe` | Python |
| 자격증명 | Keychain `MeetingCapture ASR <엔진>`, account `<user>@<host>:<port>` | `mcap asr-engines secret set`/`enroll`, 또는 앱 메뉴 `Settings…`의 Save key(같은 service와 account 문자열, `security -i`) | Python |
| 처리 상태 | `state.json`, `transcript.json`, `asr-usage.jsonl` | Python만 | Swift는 `state.json` 읽기만 |

동의 파일의 `integrity`는 우연한 손상을 찾는 체크섬이지 MAC이 아니다(같은 사용자가 다시 계산할 수 있다). 조직 통제는 정책이 한다: 위조된 동의가 가리킬 수 있는 호스트는 정책
`allowed_hosts`에 들어 있는 것뿐이고, 비밀은 host:port에 결박되어 있다.

## 9. 판정 사유 코드

`state.json`의 `lanes`, `mcap doctor`, `mcap status`, `policy-status`가 쓰는 짧은 코드다. 레인이 막혔을 때 '왜'를 내용 없이 알려 준다.

| 코드 | 뜻 |
|---|---|
| `ok` | 이 레인은 허용 |
| `local_only` | 이 회의가 로컬 전용이다 |
| `session-unreadable` | 게이트가 `session.json`을 읽지 못해 그 레인을 거부했고 이후 끝까지 local_only로 본다 |
| `policy-locked` | 정책 파일이 있는데 invalid이거나(또는 `policy.required`가 있는데 파일이 없음) 모든 외부 레인이 닫혔다 |
| `policy-lane` | 정책이 이 레인을 deny한다(회사 프로필에서 생략된 레인도 deny) |
| `policy-unapproved` | company에서 allow지만 `approvals.<레인>` 참조가 없다 |
| `policy-claude-unpinned` | `llm`=allow인데 `claude_bin_pin`이 없거나 서명 검증이 맞지 않는다 |
| `policy-archive-root` | `ARCHIVE_DIR`가 정책 `archive.allowed_roots`와 맞지 않는다(로컬 아카이브로 대체) |
| `archive-not-configured` | company인데 `ARCHIVE_DIR`가 config.env에 명시되지 않았다 |
| `user-disabled` | 사용자 설정이 이 레인을 끈다(`TRANSCRIPT_CLEANUP=0`, `CALENDAR_LOOKUP=0` 등) |
| `policy-engine`, `policy-host`, `policy-foreign` | ASR 엔진/호스트가 정책 허용 목록 밖이거나 국외 처리 엔진인데 `allow_foreign=false` |
| `cap` | 일일 외부 오디오 분 상한을 넘겼다 |
| `no-consent`, `consent-mismatch`, `consent-expired`, `consent-tampered` | 동의가 없거나, 엔진·호스트·포트·리전·모델·프로토콜·backend kind·머신·역할 중 하나가 어긋나거나, 만료됐거나, 파일의 `integrity`가 맞지 않는다 |
| `hw-capable`, `hw-incapable`, `hw-unknown` | `ASR_ENGINE=auto`일 때의 하드웨어 판정 |

`local_only_source` 값(Python): `session`, `default`, `policy-lock`, `fail-closed:bad-type`, `fail-closed:unreadable`. Swift가 `session.json`에 기록하는 출처:
`default`, `config-default`, `policy-default`, `policy-invalid`, `menu`, `menu-after-stop`, `policy-lock`.

새 `error_kind`: `asr_policy_blocked`(로컬 전사가 불가능하고 외부도 못 쓴다: 오디오 보존, 재시도 안 함), `asr_unreachable`(외부 서버에 닿지 못함: 재시도 가능, 시도 횟수에 넣지 않는 대기 종류),
`local_archive_unsafe`(`LOCAL_ARCHIVE_DIR`가 허용 목록 밖: 재시도 안 함), `lane_denied`(건너뜀으로 매핑되고 실패가 아니다).

## 10. 로컬 아카이브

`LOCAL_ARCHIVE_DIR`는 차단 목록이 아니라 **허용 목록**으로 검증한다: realpath가 `SUPPORT_DIR` 아래이거나 정책 `archive.local_roots`에 맞아야 하고, 경로 구성요소에 심볼릭 링크가 없어야 하고
(`realpath == abspath`), 홈 디렉터리와 같은 장치여야 한다. 아니면 `local_archive_unsafe`다. 기본값(`SUPPORT_DIR/local-meetings`)은 구성상 안전하다. 생성할 때 `sessions/`와
`local-meetings/`에 Time Machine 제외를 건다(실패해도 진행하고 doctor가 보고한다). Drive 같은 동기화 폴더는 로컬 아카이브가 될 수 없다.

로컬 폴더를 `mcap reprocess`로 다시 처리해도 이름, 위치, 파일 목록은 바뀌지 않고 Drive로 가지 않는다. 끝난 로컬 전용 폴더는 '완료'로 본다.

## 11. 막지 못하는 것 (정직한 한계)

이 가드는 Python 프로세스 안의 소켓을 보는 **실수와 호기심을 막는 방어선**이지 샌드박스가 아니다.

- 같은 사용자 권한의 악성코드나 로컬 관리자: 동의, config, 사용량 기록, 개인 설치의 코드는 사용자가 쓸 수 있다. 실질 강제는 MDM(표준 사용자, 앱 허용 목록, 프로세스별 네트워크 허용, FileVault)과
  root 소유 런타임이 한다. 이를 배포하는 것은 관리자 결정이다.
- 자식 프로세스(`claude`), C 레벨 소켓은 프로세스 안 가드가 보지 못한다. `claude` CLI 자체의 텔레메트리와 세션 캐시는 파일럿 전 감사 항목이다.
- 이미 진행 중인 요청: local_only를 켜도 이미 시작한 HTTP 요청이나 `claude` 호출은 끝날 때까지 간다. 게시(publishing)가 시작되는 순간의 토글은 보장하지 않는다: 복사 중인 숨김 `.partial`
  폴더를 Drive가 먼저 올릴 수 있고, 파이썬의 재확인 뒤에 켜진 ON은 되돌릴 수 없다(앱이 '이미 늦었을 수 있어요'라고 알린다).
- 벤더와 서버의 '보관 없음'은 자기보고다. 이미 보낸 오디오를 침해된 서버나 벤더가 읽는 것은 막지 못한다.
- OS 수준 사본: Spotlight, 알림 센터 기록, 제3자 백업 에이전트(Time Machine은 생성 시 제외), 화면 공유 중의 알림. FileVault와 화면 잠금은 doctor가 확인만 한다.
- 참석자의 개인 녹음, Zoom/Teams 자체 녹화 고지, DNS/SNI 메타데이터 관찰, 분실 기기(FileVault에 의존).
- 마이크 음소거 인식 캡처는 신호원이 앱마다 다르고 아직 검증 전이다. 신호를 모르면 녹음한다(fail-open). 수동 `Pause Microphone` 메뉴만 항상 보장되는 경로다.
- 고지, 동의, 국외 이전, 보관 기간은 법적 질문이고 이 설계가 풀지 않는다. `policy.approvals`는 레인을 켜는 일을 기록된 참조에 묶을 뿐이다.

## 12. 확인하는 방법

- `mcap doctor`: 정책이 없으면 출력은 지금과 같다. 정책이 있으면 프로필, 정책 상태(리비전, 해시 앞 8자, 잠금 사유), local-only 기본값, ASR 경로, 동의 유효기간, 자격증명 존재(값은 없음),
  허용 호스트 라벨, 로컬 아카이브, 로그 내용 모드가 더해지고 거부된 레인의 확인은 FAIL이 아니라 `skipped: lane denied`다.
- `mcap status [--json]`: 내용 없는 상태(제목, 세션 ID, 경로, 사용자 이름 없음).
- `CATE policy-status [--json]`: 앱이 읽은 정책 상태와 시작값, 파이프라인 계약.
- 한 회의가 어떻게 처리됐는지: 그 폴더의 `state.json`(`lanes`)과 `transcript.md` 머리의 `Privacy:`/`Route:` 줄.
- 앱 메뉴 `Settings…`의 Privacy 탭 상자 `What leaves this Mac`: **저장된 설정** 기준으로 이 문서의 레인(ASR 오디오, LLM, 캘린더, Drive)에서 무엇이 나가는지 한국어나 영어의 쉬운 말로 보여 준다. 동의 상태는 `mcap asr-engines list --json`에서 읽고, 읽지 못하면 그렇게 말하며 업로드를 단정하지 않는다. 동의 자체는 터미널의 `mcap asr-engines consent`로만 기록된다([SETTINGS.md](SETTINGS.md)).
- 앱 메뉴 `Local-Only Meeting`: 녹음 중에는 활성이고 현재 회의에만 적용된다. 종료 후에는 같은 세션이 staging에 있고 처리가 publishing 단계에 들어가기 전이면 ON을 허용하고,
  OFF는 `state.json`이 아직 없을 때(파이프라인 시작 전)만 허용한다. 정책이 잠그면 비활성이다.
