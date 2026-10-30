# 운영 런북: 상태 확인, 사고 대응, 서버 운영, 릴리스 운영

상태: **실험적 (조직 모드, SPEC 18).** 한 조직의 설치를 위해 쓰였고 법률 검토를 받지 않았으며 지원은 없다.
배포는 `docs/DEPLOY.md`, 정책 형식은 `docs/POLICY.md`, 서버 프로토콜은 `docs/ASR_PROTOCOL.md`, 이전은 `docs/MIGRATION.md`다. 이 문서에서 `mcap ...`은 회사 Mac의 `/usr/local/bin/mcap`(shim)이다.

**원칙 하나: MDM에 의존하지 않는 경로를 먼저 쓴다**(릴레이 토큰 폐기, Anthropic Console 키 폐기, Google Workspace 기기 로그아웃). MDM으로 내리는 정책은 배포 지연이 있다. 아래에서 `[관리자 결정]`은 이 저장소가
정할 수 없는 항목이고 `[미검증]`은 실제 환경에서 확인하기 전까지 믿지 않는 항목이다. 법률 판단(통지 의무, 보관 기간, 국외 이전)은 담지 않는다.

## 1. 역할 `[관리자 결정]`

| 역할 | 이름 | 하는 일 |
|---|---|---|
| 운영 담당(on-call)과 대리 | (관리자가 정한다) | 아래 2~7절. 서버 Mac의 root, MDM 관리자 권한 |
| 정책 승인자 | (관리자와 법무 트랙) | `approvals.<레인>` 참조를 발급한다. 참조 없이는 레인을 열 수 없다 |
| 릴리스 키 보관자 | (관리자) | 오프라인 Ed25519 개인키(`release-signing.key`). 서명은 이 사람만 한다 |
| 통지 의무 판단 | (법무) | 사고가 통지 대상인지 |

연락처는 정책의 `support.contact`(60자 이하)에 넣는다: 알림과 실패 문구에 나온다.

## 2. 일상 점검: 상태 피드

각 Mac은 MDM 확장 속성으로 **내용 없는 상태**를 올린다(`scripts/mdm/ea_status.sh`가 콘솔 사용자로 `mcap status --write`를 실행해 JSON 한 줄을 출력). 제목, 세션 ID, 경로, 사용자 이름은 없다. 사용량(`asr_usage_7d`, `llm_cost_7d_usd`)은
`STATUS_INCLUDE_USAGE=1`일 때만 들어가고 기본은 0이다: **직원 모니터링 자료가 되지 않게** 인사와 법무가 합의하기 전에는 켜지 않는다 `[관리자 결정]`. 한 Mac의 전체 상태는 그 Mac에서 `mcap status`(문장)나 `mcap status --json`.

| 필드 | 이상 신호 | 조치 |
|---|---|---|
| `error`(`no-console-user`, `mcap-missing`, `status-failed`, `status-timeout`, `status-unreadable`) | 필드가 있으면 상태 문서가 아니다 | `mcap-missing`: pkg가 설치되지 않았거나 지워졌다 → 재설치. `status-failed`: 그 Mac에서 `mcap doctor`. `no-console-user`는 정상(아무도 로그인하지 않음) |
| `policy.state` | `invalid` (`policy.locked_reason`에 코드) | 6절의 잠금 사유 표. 모든 외부 레인이 닫힌 채 로컬 전사만 한다: 회의는 잃지 않는다 |
| `policy.revision`, `pipeline_version` | 링의 분포가 계획과 다르다 | 롤아웃이 멈춘 Mac을 찾는다(5절) |
| `contract.satisfied` | `false` | 앱이 이 파이프라인을 실행하지 않는다(`pipeline_too_old`). 새 릴리스 설치 |
| `route.egress_allowed`, `route.primary` | 정책과 다르다 | 정책 리비전이 닿지 않았다 |
| `consent` | `consent-expired`, `consent-mismatch`, `consent-tampered` | 조직 동의(`org_consents`)를 갱신하거나 사용자가 다시 동의한다 |
| `sessions.failed_retryable`, `sessions.oldest_failed_age_h` | 24시간을 넘는 재시도 가능 실패 | 7절 지원 표 |
| `errors_7d` | 갑작스러운 증가 | 같은 링의 Mac들을 비교한다 |
| `device.filevault` | `off` | company 정책에서 `local_only.locked`인 기기군은 doctor가 FAIL이다. 켠다 |
| `disk.free_gb` | 5 미만 | 앱이 녹음을 멈춘다(`MIN_FREE_DISK_GB`) |
| `device.hw_arch` | `arm64`가 아님 | 이 앱은 Intel을 지원하지 않는다: 인벤토리 오류 |

주간: 서버 `audit --daily`(4.3절), `token list`로 곧 만료되거나 처음 보는 주소(`net`)를 가진 토큰, 퇴사 목록과의 `token sync`(4.4절).

## 3. 사고 대응 표

정책은 **문서 하나 전체**다(병합이 아니다). 새 리비전은 이전 리비전에서 열어 둔 것을 **다시 적어야** 유지된다. 그래서 열 때 쓴 `make_policy.sh` 명령줄을 티켓에 남긴다. 아래 명령은 계획을 먼저 본다(`--out` 없이 실행하면 화면에만 나온다).

| 상황 | 조치 | 효과 시점 |
|---|---|---|
| 외부 송신 즉시 중단 | `scripts/make_policy.sh --revision <N+1> --local-only-locked --out policy.json` (모든 레인 deny + 플래그 고정) → MDM 배포 | 진행 중 실행의 **다음 외부 시도**부터(정책 파일의 mtime, inode, 크기가 바뀌면 다시 읽고 더 엄격한 판정이 이긴다). MDM 지연은 별도 |
| 녹음 즉시 중단 | `scripts/make_policy.sh --revision <N+1> --recording-off ...` | 앱이 **60초 안에** 진행 중인 녹음을 정상 종료하고 보존한다 |
| 릴레이 토큰 유출 | 서버에서 `token revoke --id <id>` 또는 `--user <이름>`, 필요하면 `org_consents`를 뺀 리비전 | **다음 요청부터**(서버). MDM 없이 가능 |
| Console API 키 유출 | Console에서 키 폐기와 회전. 사용자는 `mcap api-key set`으로 새 키를 저장 | 즉시. MDM 불필요 |
| 릴레이 침해 | 서버를 격리하고, `--host`를 뺀 리비전, 메타 로그 검토(`audit --daily`), 벤더 키 회전 | 서버 격리는 즉시, 정책은 MDM 배포 시점 |
| 잘못된 정책 배포 | **이전 리비전 재배포**. 잠금된 기기는 외부 레인이 닫힌 채 로컬 전사를 계속한다 | MDM 배포 시점 |
| 분실 기기 | FileVault에 의존, 그 사람의 토큰 폐기, Workspace 기기 로그아웃 | 토큰은 즉시 |
| 퇴사 | `scripts/mdm/offboard_user.sh` (4.4절) | 즉시 |

각 조치 뒤 확인: 정책은 해당 Mac의 `mcap status`(`policy.revision`)와 앱의 `CATE policy-status --json`, 서버 조치는 `token list`. **알림 의무가 있는 사고인지는 법무가 판단한다.**

## 4. 서버 운영 (Apple silicon Mac mini) `[관리자 결정: 하드웨어, 운영자, VPN, UPS]`

설치는 `scripts/asr_server/install_server.sh`(기본 계획만)와 `docs/DEPLOY.md` 9절이다. 아래 관리 명령은 서비스 사용자로 실행한다(토큰 표가 그 사용자의 0600 파일이다):

```bash
srv() {   # 서비스 사용자로 서버의 관리 명령 실행 (경로의 공백 때문에 변수가 아니라 함수로 둔다)
    sudo -u mcap-asr env PYTHONPATH="/Library/Application Support/MeetingCapture/releases/current/pipeline" PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 \
        "/Library/Application Support/MeetingCapture/releases/current/venv/bin/python" -m mcap.asr_server \
        --config "/Library/Application Support/MeetingCapture-asr/asr-server.json" "$@"
}
srv token list
```

### 4.1 재시작과 FileVault

서비스 사용자에게는 잠금 해제된 로그인 키체인이 없고 FileVault가 켜진 Mac은 재시작 뒤 **수동으로 잠금을 풀기 전에는 아무것도 돌지 않는다.** 재시작은 계획해서 한다: `sudo fdesetup authrestart`(다음 한 번의 재시작에 잠금 해제를 넘긴다),
UPS를 둔다. 데몬: `launchctl bootstrap system /Library/LaunchDaemons/org.meetingcapture.asr.plist`, 정지 `launchctl bootout system/org.meetingcapture.asr`. 라벨이 바뀌기 전에 깐 서버는 옛 데몬이 포트를 쥔 채 남는다: `sudo launchctl list | grep mcap-asr`(일반 사용자 권한으로는 시스템 데몬이 보이지 않는다)로 옛 라벨(마지막 열)을 찾아 `sudo launchctl bootout system/<옛 라벨>`을 실행하고 `/Library/LaunchDaemons/<옛 라벨>.plist`를 지운 뒤 `install_server.sh`를 다시 돌린다(이름에 `mcap-asr`가 든 다른 plist가 보이면 스크립트가 경고한다). 서버가 내려간 동안 클라이언트는 `ASR_FALLBACK=whisper`면 로컬로 넘기고(로컬이 가능한 Mac),
아니면 `asr_unreachable`로 **조용히 기다린다**(시도 횟수에 세지 않고 연결이 돌아오면 자동 재시도, 조용한 알림만).

### 4.2 토큰과 등록 코드

- 사용자별 **1회용 등록 코드**(10분, 해시 저장, 1회 사용): `srv enroll-code issue --user <이름>`. 코드는 **채팅과 메일로 보내지 않는다**: 말로 전하거나 사용자에게 MDM 스크립트로 보낸다 `[관리자 결정: 전달 경로]`.
  사용자는 `mcap asr-engines enroll remote --code-stdin`(또는 후속 앱 메뉴)으로 토큰을 받고 파이프라인이 Keychain(계정에 호스트:포트가 결박)에 직접 저장한다. 토큰은 앱이 보지 않는다.
- 토큰은 90일 만료이고 남은 기간이 14일 이하면 클라이언트가 실행 시작에 갱신한다(구 토큰은 24시간 겹침). 목록: `srv token list`(비밀 없음, `--json`). 개별 토큰 발급 `srv token issue --user <이름> [--ttl-days N]`은 한 번만 출력된다.
- 토큰은 정적 베어러 비밀이다: 다른 망에서의 도용은 막지 못하고 **소프트 결속**(머신 id 해시, 마지막 사용, 주소 대역)과 감사로 **발견**한다(4.3절). 장치 키는 v2다.

### 4.3 감사와 보관

- 매일: `srv audit --daily [--day YYYY-MM-DD]`는 새 주소, 오디오 시간 급증, 머신 변경을 요약한다(거부하지 않는다, 사람이 본다).
- 분기: `srv audit`는 서비스 홈과 로그에서 **오디오 시그니처와 메타가 아닌 내용**을 찾는다. 결과가 0이어야 한다(`audit: 0 finding(s)`). 이것은 침해된 서버에 대한 증명이 아니라 자기 점검이다.
- 서버는 오디오와 전사를 저장하지 않는다(요청은 메모리에서만, 응답 뒤 해제). 메타 로그(내용 없음)는 기본 400일 보관(`metadata_log_days`): 접근 로그 의무 기간은 법무 결정이다 `[관리자 결정]`.
- **백업 범위**: 설정(`asr-server.json`), 토큰 해시 표, 메타 로그. TLS 개인키와 벤더 키는 별도로 안전하게. 오디오는 백업할 것이 없다.
- **벤더 키 회전**(`backend: azure`): 서비스 사용자 소유 0600 파일 `azure.key`를 새 키로 바꾼다. 릴레이는 Azure가 키를 거부(401/403)하면 파일을 다시 읽고 **새 키로 그 청크를 한 번 더** 보낸다: 재시작이 필요 없다.
  파일의 키가 그대로인데 Azure가 거부하면(폐기된 키) 청크마다 한 번만 실패하고 반복하지 않으며, 파일을 고치면 다음 청크부터 쓰인다. 리전은 한국 리전(`koreacentral`, `koreasouth`)만 시작한다(그 밖의 `region`, 리전을 말하지 않는 `host`는 시작을 거부한다).
- **알려진 문제 `[미해결]`**(`backend: azure`): 릴레이의 health는 `kind: cloud`인데 클라이언트(`RemoteEngine`)의 동의는 `backend_kind: server`에만 묶여 있어서 클라이언트가 이 릴레이를 `kind`로 거부한다.
  서버 쪽은 동작하지만(서버 코어와 Azure 사이는 시험으로 확인) 이 백엔드를 쓰는 릴레이에 클라이언트를 붙이는 것은 asr_remote/policy/cli 쪽 변경(동의가 `cloud`를 담을 수 있게 하기)이 들어오기 전에는 되지 않는다.
- 서버를 갱신하면 `srv selfcheck`의 `build_sha256`이 바뀐다(새 릴리스를 서버에 놓고 `current`를 바꾸기 **전에** 그 릴리스로 selfcheck를 돌려 값을 얻는다). 새 값을 이전 값과 **함께**
  `--org-consent`의 `attest=<이전>+<새>`에 넣은 정책 리비전을 먼저 배포하고, 서버를 전환하고, 전환이 끝나면 이전 값을 뺀 리비전을 낸다(허용 목록 밖의 빌드는 클라이언트가 거부한다).
  attest 변경은 경고와 status 카운터이고 사용자가 터미널에서 다시 동의하게 하지 않는다.

### 4.4 퇴사자

```bash
scripts/mdm/offboard_user.sh --user alice@example.com                     # 계획: 서버에서 할 명령과 손으로 할 일의 목록
sudo scripts/mdm/offboard_user.sh --user alice@example.com --apply        # 서버 Mac에서: token revoke (다음 요청부터)
scripts/mdm/offboard_user.sh --allow-list <Workspace가 내보낸 재직자 목록>      # 계획: 목록에 없는 모든 사용자의 토큰을 끈다 (token sync)
sudo scripts/mdm/offboard_user.sh --allow-list <목록> --apply              # 서버의 dry run을 보여 주고 'disable'을 입력해야 실행 (--yes로 생략)
```

`--user`에는 릴레이가 그 사람을 아는 이름을 **그대로** 쓴다(등록 코드를 발급한 이름: 한글, 공백이 든 이름, 메일 주소). 한 줄의 인쇄 가능한 글자이면 되고 제어 문자와 맨 앞의 `-`는 거부한다.
이름은 서버의 관리 명령에 인자 **하나**로 전달된다(셸이 해석하지 않는다). 서버는 **빈 목록을 거부한다**(모든 사용자를 끄지 않도록). 스크립트는 토큰만 폐기한다. 나머지는 손으로 하고 **아무것도 자동으로 지우지 않는다**: Console 키 폐기(그 사람의 llm 레인이 열려 있었다면), Workspace 계정 정지와 기기 로그아웃,
Mac 회수와 초기화, 그리고 **로컬 회의 데이터**(그 Mac의 `sessions/`와 `local-meetings/`, 공유 드라이브의 사본)의 처리: 보관과 삭제 기준은 관리자와 법무의 결정이고 정해지면 폴더 하나씩 `mcap forget <폴더> --yes`,
그 사용자 계정에서 `mcap asr-engines revoke --all --forget-secret --yes`로 동의와 Keychain의 릴레이 토큰을 지운다.

## 5. 릴리스와 정책 롤아웃

순서(빌드는 `docs/DEPLOY.md` 3절): 릴리스 빌드와 오프라인 서명 → pkg(또는 MDM이 폴더 전달 + `provision_runtime.sh --src`) → **링별**: 카나리 3~5대 → 일부 → 전체. 각 링 뒤에 상태 피드의
`pipeline_version`과 `policy.revision` 분포, `errors_7d`, `sessions.failed`를 본다.

1. 새 릴리스를 배포한다. 활성화는 postinstall 또는 `provision_runtime.sh --apply`가 한다: 서명, 해시, root 소유를 확인하고 `current`를 원자적으로 바꾸며 직전 릴리스(N-1)를 남긴다. 실행 중인 작업은 시작한 릴리스를 끝까지 쓴다.
2. **함대의 모든 Mac이 새 버전이 된 뒤에야** 정책의 `min_pipeline_version`을 올린다. 먼저 올리면 뒤처진 Mac의 파이프라인이 정책을 잠금(`pipeline-too-old`)으로 읽는다.
3. 새 키를 쓰는 정책은 그 키를 아는 파이프라인 링이 끝난 뒤에 내린다(구버전은 알 수 없는 키를 잠금으로 읽는다).
4. 롤백: `mcap release list`, `mcap release switch <버전>`(정책의 최소 버전과 0.2.0 미만은 거부). 정책이 문제면 이전 리비전 재배포.

## 6. 지원: 증상과 원인

Mac에서 `mcap doctor --share`(홈 경로와 이메일을 가려 지원용으로 붙여 넣을 수 있다)와 `mcap status`, `mcap sessions`(제목 없이 ID, 단계, 오류 종류, 나이, 크기)를 받는다.

| 증상 / 코드 | 뜻 | 조치 |
|---|---|---|
| 알림 `파이프라인 업데이트가 필요해요`, `contract.satisfied=false` | 앱이 정책, `policy.required`, local-only 회의에서 `max(0.2.0, min_pipeline_version)` 미만의 파이프라인을 실행하지 않는다 | 새 릴리스 설치. 세션은 staging에 남고 시도 횟수에 들어가지 않는다 |
| `runtime-untrusted` | `PYTHON_BIN` 또는 `PROJECT_DIR/pipeline`이 `runtime.root` 밖이거나 root 소유가 아니다 | `CATE policy-status --json`. 누군가 개인 런타임을 깔았거나 릴리스를 고쳤다: pkg 재설치(postinstall이 검증한다) |
| `조직 정책을 읽을 수 없어요`, `policy.locked_reason` | 정책 잠금. 대표 코드: `bad-owner`, `group-or-other-writable`, `parent-writable`(권한), `unknown-key`, `bad-json`(내용), `pipeline-too-old`, `required-missing`(마커는 있는데 파일이 없다) | 파일이 root 소유 0644인지, `scripts/make_policy.sh --check <파일>`, 이전 리비전 재배포 |
| 메뉴 `조직 정책으로 고정` | `local_only.locked` | 정상. 해제는 정책으로만 |
| `asr_policy_blocked` | 로컬 전사가 불가능한 Mac이고 외부 엔진도 못 쓴다. 오디오는 보존, 재시도하지 않음 | 기기군이 잘못됐다(잠금된 local-only 기기군에는 로컬 probe를 통과한 Mac만): `mcap asr-engines check --probe`. 수동 `mcap reprocess <폴더>`는 가능 |
| `asr_unreachable` | 서버에 닿지 않는다. 기다리는 종류(시도 횟수 불산입) | 연결이 돌아오면 자동 처리. macOS 15 이상에서 서버가 LAN이면 로컬 네트워크 권한을 거부했을 수 있다 `[미검증]` |
| `consent-expired`, `consent-mismatch` | 동의 만료 또는 결박한 호스트, 포트, 모델, 빌드가 바뀜 | `org_consents` 갱신 또는 `mcap asr-engines consent <엔진>`(TTY) |
| Drive에 안 올라간다, 폴더가 로컬에 남는다 | `ARCHIVE_DIR`가 `config.env`에 명시되지 않았거나 `archive.allowed_roots`에 맞지 않는다(company는 drive deny, 로컬 아카이브로) | 사용자가 Drive for desktop에 회사 계정으로 로그인했는지, `provision_user_config.sh --user <이름>` (기존 파일은 안 건드리므로 그 줄은 사용자가 직접) |
| `local_archive_unsafe` | `LOCAL_ARCHIVE_DIR`가 허용 목록 밖(링크, 다른 디스크, SUPPORT_DIR 밖) | 기본값(비움)으로 되돌린다 |
| 알림이 없다 | 앱이 꺼졌거나(Quit, 반복 크래시) 로그인 항목이 꺼졌다 | 상태 피드에 마지막 완료 나이(`sessions.last_done_age_h`)가 크다 |

## 7. 보관과 삭제 `[관리자 결정]`

클라이언트가 지우는 것: 오디오(`AUDIO_RETENTION_DAYS`), 로컬 아카이브의 오디오(`LOCAL_ARCHIVE_RETENTION_DAYS`), 재시도 불가 실패 staging(`STAGING_FAILED_RETENTION_DAYS`), 로그(`LOG_RETENTION_DAYS`, 기준 정책 30일)다.
기본은 모두 0(보관)이고 정책의 `enforced`로 상한을 건다. **전사본과 노트는 어디서도 자동으로 지우지 않는다.** 공유 드라이브의 보관과 삭제는 Drive 관리자 신원으로 도는 별도 작업이고
(노트북 N대가 조율 없이 공유 드라이브를 일정으로 지우면 안 된다), 한 폴더의 수동 삭제 도구가 `mcap forget`이다. 파일럿 권장값: 오디오 90일, 나머지 보관, 로그 30일. 기간과 삭제 SLA는 관리자와 법무가 정한다.

## 8. 분기 점검 (감사 항목, 파일럿 전 게이트)

1. `claude -p`의 `--no-session-persistence`가 `~/.claude/projects` 캐시를 **실제로** 막는지: 카나리 문장으로 호출한 뒤 그 문장이 디스크에 없어야 한다. 있으면 설정 디렉터리를 격리한다.
2. `LOG_CONTENT=0`에서 `app.log`와 `pipeline-*.log`에 제목과 전사 조각이 들어가는지(카나리로).
3. onnxruntime 텔레메트리가 꺼져 있는지(`ORT_DISABLE_TELEMETRY`).
4. 정책 `llm.child_env`에 넣을 `claude` CLI 텔레메트리 환경변수 이름(`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`)을 **고정한 CLI 버전에서** 확인한 뒤에만 쓴다.
5. 서버: `audit`가 0건, 토큰 목록과 재직자 목록 대조, TLS 인증서 만료.
6. 정책의 `approvals` 참조가 아직 유효한지(법무), `org_consents`의 `expires`.
7. 릴리스 서명 키의 보관 상태와 `release-signing.pub.pem`이 Mac의 것과 같은지.

## 9. 이 문서가 하지 않는 것

- 법률 판단, 통지, 보관 기간을 정하지 않는다. 대시보드, DB, 에이전트 서버를 만들지 않는다(SPEC 18.3).
- 같은 사용자 권한의 악성코드와 로컬 관리자는 코드가 막지 못한다: 표준 사용자, 앱 허용 목록, 프로세스별 네트워크 허용, FileVault가 MDM에서 강제된 곳에서만 위 대응이 의미를 가진다(`docs/POLICY.md` 11절).
- MDM 제품별 절차는 이 저장소에 없다 `[미검증]`.
