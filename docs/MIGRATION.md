# 개인 설치 → 회사 설치로 옮기기, 그리고 되돌리기

상태: **실험적 (조직 모드, SPEC 18).** 한 조직의 설치를 위해 쓰였고 법률 검토를 받지 않았으며 지원은 없다. 배포 전체는 `docs/DEPLOY.md`, 운영은 `docs/OPS_RUNBOOK.md`다.
이 문서는 개인 설치가 있는 Mac에서 **개인 설치를 지우지 않고 치운 뒤** 회사 pkg를 설치하는 순서와, 안 맞을 때 되돌리는 순서를 적는다.

원칙: **새 코드는 별도 체크아웃이고 지금 쓰고 있는 설치는 그대로다.** 이전은 임시 홈에서 먼저 리허설하고, 실제 이전에서도 아무것도 지우지 않는다(`.prev`, `.bak`로 치울 뿐이다). 되돌리기는 그것을 되돌리는 것이다.
개인 설치에 정책 파일이 없고 새 설정 키가 없으면 새 코드도 지금과 똑같이 동작한다(모든 새 키의 기본값은 현행 동작): 이전하지 않고 새 코드만 쓰는 것도 가능하다.

## 1. 무엇이 바뀌는가

| | 개인 설치 (지금) | 회사 설치 (pkg) |
|---|---|---|
| 앱 | `~/Applications/CATE.app`, 자체 서명 `MeetingCapture Local Signing`, hardened runtime 없음 | `/Applications/CATE.app`, Developer ID 서명, hardened runtime, 공증(관리자 계정) |
| **권한** | 이 서명에 묶인 마이크, 시스템 오디오 녹음, 알림 | **서명 신원이 바뀌므로 macOS가 모두 다시 묻는다**(자동으로 옮겨 가지 않는다) |
| LaunchAgent | `~/Library/LaunchAgents/<번들 ID>.plist` (사용자별, `make confirm-live-tested` 뒤에만) | `/Library/LaunchAgents/<번들 ID>.plist` (**같은 라벨**, 시스템 전체, 다음 로그인에 로드) |
| 런타임 | 홈의 체크아웃과 venv, 모델 캐시 `~/.cache/huggingface` | root 소유 `/Library/Application Support/MeetingCapture/releases/<버전>`, 모델은 릴리스 안 |
| `config.env` | 그대로 쓴다 | 그대로 쓴다. 단 정책이 있으면 `PROJECT_DIR`, `PYTHON_BIN`, `CLAUDE_BIN`, `SUPPORT_DIR`는 **무시**된다(런타임은 정책이 정한다) |
| `ARCHIVE_DIR` | 개인 `My Drive/Meetings` | 정책의 `archive.allowed_roots`(팀 공유 드라이브)에 맞아야 Drive로 간다. 안 맞으면 **로컬 아카이브**에 남는다 |
| 레인 | 현행: Claude 정리, 노트, 검증, 캘린더, Drive | 기준 정책은 모든 외부 레인 deny, `local_only` 기본 true: **승인 전에는 전사본만 나온다** |
| Keychain | Anthropic API 키(`MeetingCapture Anthropic API key`) | 그대로 남는다. llm 레인이 닫혀 있으면 읽히지 않는다 |
| 상태, 로그, 세션 | `~/Library/Application Support/MeetingCapture`, `~/Library/Logs/MeetingCapture` | 같은 폴더를 그대로 쓴다(staging의 미게시 세션도 새 파이프라인이 처리한다) |

개인 앱의 파일 이름은 `<짧은 이름>.app`이다(`MCAP_APP_SHORT_NAME`, 기본 `CATE`). 그 이름의 앱이 없고 같은 번들 ID의 앱이 `~/Applications`에 다른 파일 이름으로 있으면(이름이 빌드 입력이 되기 전에 만든 빌드) 스크립트는 그 앱을 개인 앱으로 보고, 상태 기록에 그 파일 이름을 적어 `--rollback`과 `--finish`가 같은 앱을 다시 찾는다. 이름과 번들 ID의 규칙은 `docs/CONFIGURATION.md`의 "Names and identifier of the app"다.

두 앱은 **동시에 돌면 안 된다**: 단일 인스턴스 락(`app.lock`) 때문에 두 번째 앱이 말없이 종료된다. 그래서 이전이 이전 앱을 **먼저** 내린다(아래 3단계).

## 2. 사전 확인 (아무것도 바꾸지 않는다)

```bash
scripts/migrate_owner_install.sh --home "$HOME"                    # --detect: 무엇이 있는지만 본다
```

보고하는 것: 사용자 LaunchAgent(로드되어 있는지), 앱 복사본(실행 중인지), `config.env`(`ARCHIVE_DIR`가 개인 My Drive를 가리키면 그 사실), staging의 **미게시 녹음 개수**(이전해도 그대로 남고 새 파이프라인이 처리한다),
**녹음 진행 중 여부**(세션 폴더의 wav가 최근 2분 안에 바뀜). 녹음 중이면 이전을 시작하지 않는다.

## 3. 리허설 (임시 홈에서, 실제 파일은 읽기만 한다)

```bash
scripts/migrate_owner_install.sh --home "$HOME" --rehearse
```

실제 홈의 LaunchAgent plist, 앱, `config.env`, `vocabulary.txt`를 **임시 홈에 복사**해서 백업 → 되돌리기를 돌리고 모든 파일이 바이트 단위로 같은지 비교한다. 마지막 줄이 `REHEARSAL PASS`여야 한다(`FAIL`이면 이 Mac을 이전하지 않는다).
`launchctl`은 한 번도 부르지 않고 임시 홈은 끝나면 지워진다. 설치 쪽 리허설은 pkg의 스크립트가 지원한다: 대상 볼륨을 `/`가 아닌 폴더로 주면 root 없이 서식만 확인한다(`docs/DEPLOY.md` 4절).
그 다음 **깨끗한 시험 Mac**에서 pkg를 실제로 설치해 TCC 재승인까지 한 번 해 본다(이 저장소의 시험은 스텁과 임시 폴더만 쓴다).

## 4. 이전

회사 pkg를 설치하면 **preinstall이 같은 일을 자동으로 한다**(콘솔 사용자의 개인 설치를 찾아 치운다). 손으로 하려면:

```bash
scripts/migrate_owner_install.sh --home "$HOME" --backup           # 사용자 에이전트를 내리고 앱과 plist를 .prev로, config.env를 .bak으로
```

하는 일: 녹음 중이면 거부(종료 코드 3, 아무것도 바꾸지 않음) → `config.env`를 `config.env.bak`으로 **복사**(원래 파일은 그 자리에 남는다)하고 `SUPPORT_DIR/migration.state` 기록 → 사용자 LaunchAgent를 `launchctl bootout`(앱도 종료)
→ plist를 `<plist>.prev`, 앱을 `CATE.app.prev`로 **이동**. 데이터, 세션, venv, 모델, Keychain 항목은 건드리지 않는다.
복사와 기록을 먼저 하므로 Support 폴더에 쓸 수 없거나 `config.env.bak` 자리에 깨진 링크가 있으면 아무것도 옮기기 전에 멈춘다. 이동이 중간에 실패하면(예: `~/Applications`에 쓸 수 없음) 이미 한 단계를 되돌리고(내렸던 에이전트를 다시 로드하고, 만든 `.bak`과 기록을 지운다) 실패로 끝나므로,
원인을 고친 뒤 다시 실행하면(MDM의 pkg 재시도 포함) 처음부터 시작한다. 되돌리는 것 자체가 실패하면 `migration.state`를 남기고 그렇게 알리므로 `--rollback`이 나머지를 마무리한다.
앱이 손으로 실행 중이어서 남아 있으면 경고하고(회사 앱이 시작되지 않는다), `--stop-app`이 SIGTERM으로 종료를 요청한다.

안전장치: 모든 경로는 링크를 따라간 뒤 **홈 폴더 안**이어야 한다(`~/Applications`가 `/Applications`로 가는 링크이면 거부). plist나 앱 자리의 심볼릭 링크는 거부한다. 이미 있는 이름은 절대 덮어쓰지 않는다(`.prev`가 있으면 멈춘다).
root(MDM, 설치 프로그램)로 돌 때는 `--user NAME`과 `--home DIR`가 필요하다(launchd 도메인 `gui/<uid>`).

그다음 pkg를 설치한다(MDM 또는 시험 Mac에서 `sudo installer -pkg <파일> -target /`). 개인 앱이 실행 중이었다면 postinstall이 새 LaunchAgent를 그 사용자에게 로드한다. 새로 설치한 Mac은 다음 로그인에 시작한다.

## 5. 첫 실행: 권한 안내

서명 신원이 바뀌므로 macOS가 권한을 다시 묻는다. 사용자에게 보여 줄 한국어 안내:

번들 ID는 빌드 입력 `MCAP_BUNDLE_ID`다(기본 `org.meetingcapture.app`). 개인 빌드와 회사 pkg를 같은 값으로 빌드해야 라벨이 같다. 값이 다르면 라벨도 달라서 이 문서의 "같은 라벨" 설명은 적용되지 않고(두 에이전트는 따로 존재), 앱의 단일 인스턴스 락 때문에 한쪽만 돈다. `migrate_owner_install.sh`는 개인 앱의 `Info.plist`에 적힌 번들 ID로 개인 에이전트를 찾고, 앱이 이미 없으면 `MCAP_BUNDLE_ID`(pkg의 preinstall은 패키지의 ID를 넘긴다), 그것도 없으면 기본값을 쓴다.

> 새 앱은 Developer ID로 서명되어 있어서 macOS가 마이크와 시스템 오디오 녹음 권한을 다시 물어요. 설치 뒤 첫 실행에서 허용해 주세요.

`migrate_owner_install.sh --backup`이 이 문구를 출력한다. **앱 안의 첫 실행 한 번 안내(권한을 다시 묻는다는 알림)는 Swift 쪽 후속 작업이고 이 패키지에 없다.** 순서: `setup` → `mcap doctor` → (원격 사용 시) `enroll` → `check remote --live`(`docs/DEPLOY.md` 5절).
권한이 꼬이면 `tccutil reset All <번들 ID>` 뒤 `setup`(`README.md`, 문제 해결).

## 6. 이전 뒤 확인

- 메뉴바 앱이 하나만 떠 있다(`pgrep -fl "CATE.app/Contents/MacOS/CATE"`), `mcap status`가 `profile: company`, `policy.state: valid`, `contract.satisfied: true`를 보여 준다.
- 시험 회의 하나(혼자 하는 Zoom 또는 Teams): 전사본이 나오고(기준 정책에서는 노트, 캘린더, Drive는 건너뛴다) 알림이 온다. `state.json`의 `lanes`에 `skipped:policy-lane`이 보인다.
- `config.env`의 `ARCHIVE_DIR`가 개인 Drive를 가리키면 회의는 로컬 아카이브(`~/Library/Application Support/MeetingCapture/local-meetings/`)에 남는다. 이것은 정책대로의 동작이다. 팀 공유 드라이브로 보내려면
  정책에 drive 레인(승인 참조)을 열고 `ARCHIVE_DIR`를 그 폴더로 고친다(`docs/POLICY.md`, `docs/DEPLOY.md` 6절).
- 이전 앱이 만든 **게시 안 된 세션**(`sessions/`)은 새 파이프라인이 `mcap reprocess --pending`으로 이어서 처리한다(앱도 `RETRY_SWEEP_HOURS`마다).

## 7. 되돌리기 (롤백)

**순서가 중요하다: 회사 쪽을 먼저 지우고, 그다음에 롤백한다.**

```bash
sudo scripts/uninstall.sh --company                                # 1) 회사 쪽(시스템 LaunchAgent, /Applications 앱, shim, releases, tools, 공개키)을 지운다. 개인 설치는 건드리지 않는다
scripts/migrate_owner_install.sh --home "$HOME" --rollback         # 2) .prev의 앱과 plist를 제자리로, config.env.bak 복원, 에이전트를 다시 로드(전에 로드되어 있었으면)
```

이유: 회사 LaunchAgent와 개인 LaunchAgent는 **같은 라벨**(번들 ID)이다. 회사 쪽이 아직 로드되어 있으면 롤백이 개인 에이전트를 올릴 수 없고, 회사 쪽을 지우는 `uninstall.sh --company`는 그 라벨을 launchd에서 내리므로(로드된 쪽이 누구든)
롤백 **뒤에** 돌리면 방금 올린 개인 에이전트가 내려간다. `--company`는 개인 설치의 파일(앱, 사용자 LaunchAgent plist, 라이브 테스트 확인 표시)을 **지우지 않는다**(sudo는 HOME을 유지하므로 관리자 본인의 파일이다):
순서를 거꾸로 했다면 파일은 그대로이고 로그아웃 후 다시 로그인하거나 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<번들 ID>.plist`로 다시 올리면 된다. 롤백이 회사 설치가 아직 있다고 알려 주고 순서를 말한다.
개인 설치까지 함께 지우려면(롤백이 아니라 정리할 때) `sudo scripts/uninstall.sh --company --also-personal`이다.

`--company`는 번들 ID와 앱 파일 이름을 pkg가 `tools/`에 남긴 기록(`RELEASE_BUNDLE_ID`, `RELEASE_APP_SHORT_NAME`)에서 읽는다(sudo는 환경 변수를 넘기지 않는다). 기록이 없는 예전 pkg면 `/Applications`에서 그 ID(`MCAP_BUNDLE_ID`, 없으면 기본값)를 가진 앱 하나를 찾는다. 앱도 에이전트도 찾지 못하면 아무것도 지우지 않고 오류로 끝난다(`releases/`와 `tools/`만 지우고 앱을 남기지 않는다): `sudo env MCAP_BUNDLE_ID=<ID> MCAP_APP_SHORT_NAME=<앱 파일 이름, .app 제외> scripts/uninstall.sh --company`로 이름을 넘긴다. 같은 ID의 다른 이름 앱은 지우지 않고 이름만 알려 준다.

`--rollback`은 사용자 폴더 안의 것만 되돌린다: 앱과 plist를 제자리로 옮기고, 그 사이에 같은 자리에 새로 생긴 앱이나 plist는 `*.rollback-new`로 **보관**하고, `config.env`가 이전 뒤에 바뀌었으면 백업을 복원하고
바뀐 파일을 `config.env.after-migration`으로 남긴다. 이전에 에이전트가 로드되어 있었으면 다시 로드한다. 상태 기록은 `migration.state.rolled-back`으로 닫힌다.
`uninstall.sh --company`는 **데이터와 정책 파일을 남긴다**: 사용자 데이터(`SUPPORT_DIR`, 로그, 로컬 아카이브, 세션, Keychain 항목)와 `policy.json`, `policy.required`는 그대로다(정책은 MDM이 소유한다).
**주의**: 정책 파일이 남은 Mac에서 개인 설치로 돌아가면 개인 앱은 `runtime-untrusted`로 거부된다(정책이 있는 Mac은 root 소유 런타임만 실행한다). 정책 제거는 MDM 관리자가 한다(`docs/OPS_RUNBOOK.md`).

설치가 20으로 실패했을 때도 같은 순서다: payload(앱, shim, LaunchAgent, 릴리스 폴더)는 이미 깔려 있으므로 먼저 위 1)로 지우고, 그다음 2)로 preinstall이 치운 개인 설치를 되돌린다. (베이스 python이 없는 Mac은 preinstall이 16으로 멈추므로 개인 설치가 치워지지 않는다: `docs/DEPLOY.md` 3.1절.)

## 8. 마무리

회사 설치가 며칠 동안 문제없이 돌고 롤백이 필요 없다고 판단되면:

```bash
scripts/migrate_owner_install.sh --home "$HOME" --finish           # .prev 복사본과 상태 기록을 지운다 (config.env.bak은 남는다)
```

그 뒤에는 `--rollback`이 할 일이 없다. 개인 체크아웃, venv, `~/.cache/huggingface`의 모델은 지워지지 않는다. 정리하려면 손으로 한다(`scripts/uninstall.sh --purge`는 데이터가 든 SUPPORT_DIR 전체를 지우므로 회사 설치에서는 쓰지 않는다).

## 9. 하지 않는 것

- 개인 Keychain의 API 키, 서명 인증서(`MeetingCapture Local Signing`), 홈의 체크아웃은 건드리지 않는다.
- 자동 데이터 삭제는 없다. 정책과 사용자 데이터의 보관과 삭제는 관리자와 법무의 결정이다(`docs/OPS_RUNBOOK.md` 7절).
- 앱 안의 첫 실행 안내와 `config.env` 자동 생성(앱이 직접)은 이 패키지에 없다(Swift 후속 작업).
