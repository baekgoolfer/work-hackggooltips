# 회사 배포: 설치 프로필, 패키지, 릴리스, 정책, 롤아웃

상태: **실험적 (조직 모드, SPEC 18).** 한 조직의 설치를 위해 쓰였고 법률 검토를 받지 않았으며 지원은 없다.
이 문서는 배포하는 사람(관리자)이 순서대로 따라 하는 설명이다. 정책 형식은 `docs/POLICY.md`, 무엇이 어디로 나가는가는 `docs/PRIVACY_LANES.md`, 운영과 사고 대응은 `docs/OPS_RUNBOOK.md`,
개인 설치에서 회사 설치로 옮기는 절차는 `docs/MIGRATION.md`다.

이 문서의 명령은 모두 **계획이나 리허설로 먼저 볼 수 있다**(`--dry-run`, 계획만 보여 주는 기본 동작, 임시 폴더). 이 저장소의 어떤 스크립트도 서명, 공증, MDM 업로드, 키체인 접근, 네트워크 접속을
스스로 하지 않는다: 그것은 **관리자 작업**이고 필요한 곳마다 그렇게 적었다. 법률 판단은 담지 않는다(승인 참조 `approvals`와 고지 문구는 관리자와 법무 트랙).

## 1. 설치 프로필 세 가지

| 프로필 | 누가, 어떻게 | 런타임이 있는 곳 | 정책 |
|---|---|---|---|
| `personal` | 개인 Mac. `make install`(`scripts/install.sh`) | 홈 폴더(저장소 체크아웃, `~/Library/Application Support/MeetingCapture/venv`, `~/Applications`) | 없음. 현행 동작 그대로 |
| `company-client` | 직원 Mac. 서명된 pkg를 MDM이 설치 | root 소유 `/Library/Application Support/MeetingCapture/releases/<버전>/` | pkg가 기준 정책(모든 외부 레인 deny)과 `policy.required`를 항상 깐다. MDM이 리비전을 올려야 열린다 |
| `asr-server` | Apple silicon Mac mini. `scripts/asr_server/install_server.sh` | 같은 root 소유 릴리스(`--project`) | 서버 자체 설정 `asr-server.json` (`docs/ASR_PROTOCOL.md`) |

개인 설치와 회사 설치는 **같은 앱, 같은 LaunchAgent 라벨**을 쓴다(라벨은 번들 ID다. 두 설치를 같은 `MCAP_BUNDLE_ID`로 빌드했을 때. 기본값은 `org.meetingcapture.app`). 한 Mac에서 둘이 함께 돌면 앱의 단일 인스턴스 락(`app.lock`) 때문에 두 번째가 말없이 종료되므로
pkg의 preinstall이 개인 설치를 먼저 치운다(`docs/MIGRATION.md`). 정책이 있는 Mac(`policy.required` 또는 `policy.json`이 있다)에서 `scripts/install.sh`를 돌리면 경고가 나온다: 그 Mac의 앱은
root 소유 회사 런타임에서만 파이프라인을 시작하므로 홈 폴더에 만든 앱과 venv는 `runtime-untrusted`로 거부된다.

## 2. company-client 레이아웃 (모두 root 소유)

```
/Applications/CATE.app                                앱 (회사 빌드: Developer ID, hardened runtime, 공증은 관리자 작업)
/usr/local/bin/mcap                                    셸 shim: 현재 릴리스의 python을 고정 PYTHONPATH와 깨끗한 환경으로 실행
/Library/LaunchAgents/<번들 ID>.plist                  시스템 전체 LaunchAgent (다음 로그인 때 로드)
/Library/Application Support/MeetingCapture/
   policy.json, policy.required                        0644. MDM이 리비전을 올린다 (pkg는 policy.json이 없을 때만 기준 정책을 둔다)
   release-signing.pub.pem                             릴리스 서명의 공개키 (Ed25519, PEM)
   tools/                                              provision_runtime.sh, provision_user_config.sh, migrate_owner_install.sh, config.env.company.template
   releases/<버전>/{pipeline/, config/, venv/, models/, MANIFEST.json, MANIFEST.sig}
   releases/current -> <버전>                          상대 심볼릭 링크, 원자적으로 바뀐다. 직전 버전(N-1)이 남는다
```

- **신뢰 루트.** company 프로필 정책의 `runtime.root`가 이 `releases` 폴더다. 앱은 실행 전에 `PYTHON_BIN`과 `PROJECT_DIR/pipeline`의 realpath가 그 루트 아래이고 경로의 모든 구성요소가 uid 0이며
  그룹과 기타 쓰기가 불가능한지 확인한다(아니면 `runtime-untrusted`). `config.env`의 `PROJECT_DIR`, `PYTHON_BIN`, `CLAUDE_BIN`, `SUPPORT_DIR`는 정책이 있으면 무시된다.
- `config/`는 프롬프트(`note_prompt.md`, `cleanup_prompt.md`, `verify_prompt.md`)와 `vocabulary.txt` 시드다. 파이프라인은 사용자의 `SUPPORT_DIR` 복사본이 없으면 `<릴리스>/config/`에서 읽는다.
- `models/`는 읽기 전용 모델(약 3 GB)이다. 기준 정책의 `defaults.ASR_MODEL`이 `<루트>/current/models/whisper-large-v3-mlx`를 가리키고 `ASR_ALLOW_DOWNLOAD=0`이 강제되므로 첫 실행에 다운로드가 없다.
  `--client-only` 릴리스에는 `models/`가 없다(원격 ASR만).
- **shim `/usr/local/bin/mcap`**: `env -i`로 호출자의 `MCAP_*`, `PYTHON*`, `PATH`, 프록시, `DYLD_*`를 버리고 `PYTHONPATH=<릴리스>/pipeline`, `PYTHONSAFEPATH=1`(작업 폴더의 `ssl.py` 같은 파일이 import되지 않는다),
  `PYTHONNOUSERSITE=1`로 `python -m mcap`을 실행한다. 사용자 계정의 셸 별칭이나 프로파일로는 실행되는 코드를 바꿀 수 없다. 앱의 이름 둘(`MCAP_APP_NAME`, `MCAP_APP_SHORT_NAME`)만은 패키지를 만들 때 정해져 shim에 고정되어 들어가므로, shim으로 실행한 pipeline도 앱과 같은 이름을 쓴다.
- LaunchAgent plist에는 `StandardOutPath`가 없다(시스템 전체 plist는 사용자별 로그 폴더를 가리킬 수 없다). 앱은 자기 `app.log`를 쓴다. 개인 설치의 `live-tested.confirmed` 관문은 pkg 설치에 적용되지 않고
  pkg 설치는 첫 실행 점검(아래 5절)이 그 자리를 맡는다.

## 3. 릴리스를 만드는 순서 (빌드 Mac, 관리자 또는 빌드 담당)

릴리스는 pkg와 별개로 먼저 만든다. 서버 티어도 같은 릴리스를 쓸 수 있다.

### 3.1 베이스 Python: 모든 Mac의 같은 경로에, root 소유로, 다른 사람이 쓸 수 없게

venv는 `python -m venv`로 만들고 그 python은 `pyvenv.cfg`의 `home`이 가리키는 **베이스 인터프리터**를 쓴다: 실행 파일, 표준 라이브러리(`lib/python3.13`과 그 안의 `lib-dynload`, `site-packages`), `Python` 라이브러리.
이것은 **릴리스 밖**에 있고 **pkg는 베이스를 싣지 않는다.** 그래서 두 가지가 pkg의 **선행 조건**이다:

1. **모든 클라이언트 Mac의 같은 경로에 같은 베이스 python이 pkg보다 먼저 깔려 있어야 한다**(예: MDM이 python.org 설치 프로그램을 배포). 없으면 preinstall이 종료 코드 16으로 설치를 멈춘다. 개인 설치를 치우기 **전**이라 그 Mac의 앱은 그대로다.
   베이스의 경로는 pkg 스크립트의 `RELEASE_BASE_PYTHON`에 있고 `build_pkg.sh`가 빌드할 때 출력한다.
2. **그 베이스는 root 소유이고 그룹과 기타가 쓸 수 없어야 한다.** 쓸 수 있으면 관리자 그룹의 누구나 모든 회사 python이 import하는 표준 라이브러리를 고칠 수 있어서 신뢰 루트가 무너진다. `scripts/provision_runtime.sh`는 **쓰기 비트를 누가 실행하든**
   (빌드 담당의 일반 사용자 포함: `--verify-only`, `build_pkg.sh`) 검사하고 소유자(uid 0)는 root로 실행할 때 검사한다. 대상은 인터프리터 실행 파일, 베이스 폴더와 그 위의 모든 폴더, 베이스 폴더 **아래의 모든 파일**(표준 라이브러리, 확장 모듈, `Python` 라이브러리)이다.

Homebrew의 python(`/opt/homebrew/...`)은 관리자 사용자가 소유하므로 쓸 수 없다. **python.org의 macOS 설치 프로그램도 그대로는 통과하지 못한다**: 프레임워크 `/Library/Frameworks/Python.framework`를 `root:admin`, mode 775로 깔아서 그룹이 쓸 수 있다
(`Versions` 폴더도 `root:wheel` 775다). **빌드 Mac과 모든 클라이언트 Mac에서** 설치 프로그램 **뒤에** 한 번(MDM 스크립트로) 다음을 돌린다:

```bash
sudo chown -R root:wheel /Library/Frameworks/Python.framework
sudo chmod -R go-w /Library/Frameworks/Python.framework
scripts/provision_runtime.sh --check-base /Library/Frameworks/Python.framework/Versions/3.13/bin     # 확인: 일반 사용자로도 돌고, 문제를 한 줄씩 말한다
```

python.org 설치 프로그램이 다시 돌면(업그레이드) 권한이 설치 때의 값으로 돌아가므로 이 두 명령도 다시 돌려야 한다(MDM 스크립트에 함께 둔다). 다른 방법은 `root:wheel` 755로 직접 만든 베이스 복사본이다. 두 경우 모두 모든 Mac에서 **같은 경로**여야 한다.
`--check-base`는 `/Library/Frameworks/Python.framework/Versions/3.13`이 775일 때 거부하는 것을 이 저장소의 점검으로 확인했다(소유자 점검은 root로 실행해야 한다). **[미검증]** 하드닝한 실제 프레임워크로 릴리스를 만들고 설치까지 끝내 보지는 않았다.
그 python을 `scripts/setup_python.sh --python <경로> --copies`에 준다(`--copies`는 베이스로의 심볼릭 링크 대신 실행 파일 복사본을 둔다. 베이스 폴더 자체는 릴리스 밖에 남는다).

### 3.2 해시 lock (`scripts/make_hash_lock.sh`)

`pipeline/requirements.lock.txt`는 버전만 고정한다(PyPI가 그 버전 이름으로 주는 것을 pip가 믿는다). 회사 venv는 wheel의 sha256까지 고정한 lock으로 만든다.

```bash
scripts/make_hash_lock.sh                    # 계획만: 입력(전체 lock 29개, 클라이언트 2개), 출처, 설치 명령. 아무것도 받지 않는다
scripts/make_hash_lock.sh --apply            # 네트워크: pypi.org에서 핀마다 wheel 해시를 받아 build/hash-locks/*.hashes.txt를 쓴다 (관리자가 빌드 호스트에서)
```

파일은 `name==version \` 블록과 `--hash=sha256:...` 줄이고 `pip install --require-hashes --no-deps -r <파일>`로 설치한다. 모든 핀에 허용 wheel이 하나라도 없으면(소스 배포만 있다) 아무 파일도 쓰지 않는다.
결과 파일은 검토한 뒤 릴리스와 함께 보관한다. 이것이 없으면 PyPI wheel은 버전 고정만 된 것이다(공급망).

### 3.3 venv

```bash
REL=build/release/0.2.0                        # 폴더 이름이 곧 버전이다 (파이프라인의 __version__과 같아야 한다)
BASE=/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13
# 클라이언트 전용 (원격 ASR, 로컬 모델 없음, 8 GB Mac은 측정 전까지 미검증): numpy와 truststore만
scripts/setup_python.sh --client-only --with-cloud --hash-lock build/hash-locks/requirements.client.hashes.txt --venv-dir "$PWD/$REL/venv" --copies --python "$BASE"
# 전체 (로컬 Whisper): 전체 lock
scripts/setup_python.sh --hash-lock build/hash-locks/requirements.lock.hashes.txt --venv-dir "$PWD/$REL/venv" --copies --python "$BASE"
```

`--hash-lock`의 핀은 그 실행이 쓰는 요구사항 파일의 핀과 정확히 같아야 한다(다르면 멈춘다). `--with-cloud`는 클라우드 엔진(Azure)이 쓰는 운영체제 인증서 저장소 패키지 `truststore`가 venv에 있는지
확인하고 import해 본다(클라이언트 전용 요구사항과 전체 lock에 이미 들어 있다. 릴레이는 고정 사설 CA를 쓰므로 TLS에 패키지가 필요 없다). Silero 런타임과 벤치마크 venv는 이 해시 고정에 들어가지 않는다.
venv의 `bin/pip` 등은 셔뱅에 빌드 경로가 들어 있다. 런타임은 `bin/python -m mcap`만 쓰므로 문제가 없고 지워도 된다.

### 3.4 파이프라인, 설정 시드, 모델

```bash
mkdir -p "$REL/pipeline" "$REL/config" "$REL/models"
rsync -a --exclude '__pycache__' --exclude '*.pyc' pipeline/mcap/ "$REL/pipeline/mcap/"
cp config/note_prompt.md config/cleanup_prompt.md config/verify_prompt.md config/vocabulary.txt "$REL/config/"
# 전체 릴리스만: 모델. 빌드 Mac의 개인 venv로 한 번 받은 스냅샷을 실제 파일로 복사한다 (심볼릭 링크가 아니다: 링크는 릴리스 밖을 가리킨다)
scripts/setup_python.sh --pre-download-model
cp -RL ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-mlx/snapshots/49e6aa286ad60c14352c404340ded53710378a11 "$REL/models/whisper-large-v3-mlx"
```

릴리스 안의 심볼릭 링크는 릴리스 밖을 가리키면 안 된다(다음 절 검사가 거부한다). 소스에는 `pipeline/tests`와 `__pycache__`를 넣지 않는다.

### 3.5 릴리스 바이너리 서명, 매니페스트와 오프라인 서명

**공증하려면 pkg 안의 Mach-O 파일이 전부**(앱만이 아니다: venv의 python, numpy와 onnxruntime의 `.so`와 `.dylib` 등) Developer ID Application 인증서, hardened runtime, 보안 타임스탬프로 서명되어 있어야 한다.
하나라도 서명이 없거나 ad-hoc(pip가 깐 wheel의 `.so`는 링커가 붙인 ad-hoc 서명뿐이다)이면 `notarytool`이 pkg 전체를 거부한다. 릴리스의 모든 파일은 서명된 매니페스트의 해시에 들어가므로 **서명은 매니페스트보다 먼저** 한다
(나중에 서명하면 해시가 바뀌어 검증이 거부한다). 관리자의 Apple Developer 계정이 필요한 **관리자 작업**이다.

```bash
chmod -R go-w "$REL"                                                              # python -m venv는 activate 같은 파일을 664로 만든다: 그룹이 쓸 수 있는 파일은 매니페스트도 검증도 거부한다
scripts/provision_runtime.sh --release-dir "$PWD/$REL" --sign-macho --identity "Developer ID Application: <이름> (<TEAMID>)"     # 릴리스의 모든 Mach-O: --options runtime --timestamp
scripts/provision_runtime.sh --release-dir "$PWD/$REL" --make-manifest           # MANIFEST.json: 모든 파일의 sha256과 mode, 모든 심볼릭 링크, 종류(full 또는 client)
# 릴리스 키를 가진 오프라인 Mac에서 (OpenSSL 3 이상: macOS의 /usr/bin/openssl은 LibreSSL이라 Ed25519 서명을 못 한다. Homebrew의 openssl@3 등)
openssl pkeyutl -sign -inkey release-signing.key -rawin -in "$REL/MANIFEST.json" -out "$REL/MANIFEST.sig"
scripts/provision_runtime.sh --release-dir "$PWD/$REL" --pubkey release-signing.pub.pem --verify-only
```

`--sign-macho`는 파일 이름이 아니라 **내용**(`file`이 Mach-O라고 하는 것)으로 찾아 하나씩 `codesign --force --options runtime --timestamp --sign <신원>`을 돌린다. 이미 `MANIFEST.json`이 있는 릴리스는 거부한다
(서명이 목록의 해시를 바꾸므로: `MANIFEST.json`과 `MANIFEST.sig`를 지우고 서명한 다음 다시 만든다). `--entitlements FILE`로 실행 파일의 entitlements를 줄 수 있다(기본 없음).
**[미검증]** 이 저장소의 점검은 가짜 `codesign`으로 호출 형태와 거부 경로만 확인한다. 실제 서명, 그리고 `notarytool submit`이 이 결과를 받아 주는지는 관리자가 한 번 해 봐야 안다. 특히 hardened runtime의 venv python이
**다른 팀이 서명한 베이스 python 프레임워크**(3.1절)와 확장 모듈을 로드하는지(library validation), ctypes나 onnxruntime이 추가 entitlements(`com.apple.security.cs.*`)를 요구하는지는 기기 시험이 필요하다.
`scripts/build_pkg.sh --app-identity`는 payload의 Mach-O 파일마다 `codesign -dvv`로 Developer ID Application 서명, hardened runtime, 보안 타임스탬프를 확인하고, 하나라도 어긋나면 파일 이름과 이유를 말하고 pkg를 만들지 않는다.

키 쌍은 한 번 만든다: `openssl genpkey -algorithm ed25519 -out release-signing.key`, `openssl pkey -in release-signing.key -pubout -out release-signing.pub.pem`. **개인키의 보관은 관리자 결정**이다(오프라인, 접근자 한정).
공개키는 pkg에 들어가 Mac에 `release-signing.pub.pem`으로 깔리고 이후의 릴리스도 그 키로 검증한다.

검증이 확인하는 것: 서명이 `MANIFEST.json`의 바이트와 맞는다, 모든 파일의 해시가 같다, 매니페스트에 없는 파일이나 링크가 없다, 링크는 릴리스 안으로만 향한다, 특수 파일이 없다, 그룹이나 기타가 쓸 수 있는 파일이 없다,
(root로 실행하면) 모든 파일이 root 소유다, venv의 **베이스 python**(릴리스 밖, 3.1절)이 이 Mac에 있고 그 아래 모든 것을 그룹과 기타가 쓸 수 없다(root로 실행하면 root 소유이기도 하다),
폴더 이름이 매니페스트의 버전이다. **하나라도 어긋나면 활성화하지 않는다.** 서명 검증은 내장된 RFC 8032 코드(표준 라이브러리만)가 기본이고
`--openssl <OpenSSL 3>`로 OpenSSL을 쓸 수도 있다(두 방식은 시험에서 서로의 서명을 확인한다). 검증기를 돌리는 python은 릴리스 자신의 venv가 아니다: root로 돌 때는 `/usr/bin/python3` 또는 root 소유 `--python`만 받는다.
**[미검증]** 명령줄 도구가 없는 Mac의 `/usr/bin/python3`는 껍데기일 뿐이다. 그런 Mac에서는 postinstall이 이 이유로 실패하므로 Command Line Tools를 MDM으로 깔거나 검증용 root 소유 python을 정해야 한다(관리자 결정).

### 3.6 패키지 (`scripts/build_pkg.sh`)

`make pkg ARGS="..."`는 `scripts/build_pkg.sh ...`의 단축이다 (`make pkg ARGS=--dry-run`으로 먼저 본다).

```bash
scripts/build_pkg.sh --dry-run                                                   # 계획과 모든 명령. 아무것도 만들지 않는다
scripts/build_pkg.sh --release-dir "$PWD/$REL" --release-pubkey release-signing.pub.pem --contact "IT 헬프데스크 #it-help"      # 서명 없는 pkg (기본)
scripts/build_pkg.sh --release-dir "$PWD/$REL" --release-pubkey release-signing.pub.pem \
    --app-identity "Developer ID Application: <이름> (<TEAMID>)" --installer-identity "Developer ID Installer: <이름> (<TEAMID>)"   # 서명 (관리자 계정)
```

- **서명하지 않는 것이 기본이다.** 서명 없는 pkg는 클린 Mac에서 손으로 열면 Gatekeeper가 막지만 `installer(8)`와 MDM은 설치한다. 리허설에는 이것으로 충분하다.
- `--app-identity`를 주면 **앱 복사본**(개인 빌드는 그대로)을 `--options runtime --timestamp --entitlements scripts/pkg/entitlements.plist --identifier <번들 ID>`로 서명하고 hardened runtime 플래그를 확인한다.
  entitlements는 마이크(`com.apple.security.device.audio-input`)와 Chrome으로의 Apple Events(`com.apple.security.automation.apple-events`) 둘뿐이다(`--entitlements FILE`로 바꾼다).
  **[미검증]** hardened runtime에서 Process Tap 시스템 오디오 캡처가 이 entitlements만으로 동작하는지는 기기 시험이 필요하다(`docs/LIVE_TEST.md`). 개인 빌드는 hardened runtime을 쓰지 않는다.
- 번들 ID(LaunchAgent 라벨, pkg 식별자 `<번들 ID>.pkg`, 설치 프로그램의 organization = 번들 ID에서 마지막 레이블을 뺀 것)는 pkg에 들어가는 앱의 `CFBundleIdentifier`다. `--app`을 주지 않으면 `build_pkg.sh`가 `MCAP_BUNDLE_ID`(기본 `org.meetingcapture.app`)로 앱을 빌드한다. 회사 고유의 역도메인 ID를 쓰려면 앱 빌드와 `build_pkg.sh`를 같은 `MCAP_BUNDLE_ID`로 돌리고, 이후 모든 업데이트도 같은 값으로 만든다. ID가 바뀌면 macOS는 다른 앱으로 보고 권한을 다시 묻는다. 패키지 스크립트는 `RELEASE_BUNDLE_ID`와 `bundle_id.sh`를 함께 싣는다.
- 앱의 이름도 번들 ID와 같은 방식으로 정해진다: `--app`의 `Info.plist`(`CFBundleDisplayName`, `CFBundleName`)가 먼저이고, 그다음 `MCAP_APP_NAME`(기본 `Catch Everything`)과 `MCAP_APP_SHORT_NAME`(기본 `CATE`), 없으면 기본값이다. 짧은 이름이 pkg 안의 앱 폴더 `/Applications/<짧은 이름>.app`, 앱 실행 파일, pkg 파일 이름(`<짧은 이름>-<버전>.pkg`)을 정하고, 사람이 읽는 이름이 설치 프로그램의 제목이다. 이 소스로 만든 모든 사본이 같은 기본값을 쓰므로, 회사가 자기 이름을 쓰려면 앱 빌드와 `build_pkg.sh`를 같은 `MCAP_APP_NAME`, `MCAP_APP_SHORT_NAME`으로 돌리고 이후 모든 업데이트도 같은 값으로 만든다(규칙은 `docs/CONFIGURATION.md`의 "Names and identifier of the app"). 데이터 폴더, 로그 폴더, Keychain 항목, LaunchAgent 라벨, ASR 데몬 라벨은 제품 이름이 아니라 경로와 식별자이므로 이름을 따라 바뀌지 않는다. 패키지 스크립트는 `RELEASE_APP_NAME`과 `RELEASE_APP_SHORT_NAME`도 싣는다.
- `--app-identity`를 주면 앱 말고도 **payload의 모든 Mach-O 파일**(릴리스의 venv와 라이브러리)이 Developer ID Application 서명, hardened runtime, 보안 타임스탬프를 갖췄는지 확인한다(3.5절에서 매니페스트 전에 서명한다). 하나라도 아니면 파일 이름과 이유를 출력하고 멈춘다.
  서명 없는 리허설 pkg(`--app-identity` 없음)는 이 점검을 받지 않는다. **[미검증]** 실제 공증을 한 번 통과하기 전까지는 이 점검이 공증 조건의 전부인지 알 수 없다.
- `--installer-identity`를 주면 distribution pkg를 `productbuild --sign ... --timestamp`로 서명하고 `pkgutil --check-signature`로 확인한다.
- **공증은 스크립트가 하지 않는다.** 마지막에 `xcrun notarytool submit <pkg> --keychain-profile <프로필> --wait`와 `xcrun stapler staple <pkg>`를 출력만 한다(Apple Developer 계정, D-U-N-S 번호, 연회비가 필요한 관리자 작업).
- 매니페스트 검증이 실패한 릴리스(베이스 python 점검 포함: 3.1절)로는 pkg를 만들지 않는다. distribution에는 `hostArchitectures="arm64"`와 macOS 14.4 조건이 들어가고 preinstall이 같은 둘을 다시 확인한다.
- `--client-only`는 클라이언트 전용 릴리스용이고 pkg 이름이 `-client.pkg`다(두 종류가 섞이지 않는다). 기준 정책에는 `ASR_MODEL`이 들어가지 않는다.

pkg 안: 앱, shim, LaunchAgent, 릴리스, 공개키, 스크립트(preinstall, postinstall, 도우미 셋, 설정 템플릿, `baseline-policy.json`, `RELEASE_VERSION`, `RELEASE_FLAVOR`, `RELEASE_BASE_PYTHON`, 앱 이름 두 개). 베이스 python은 pkg 안에 **없다**(3.1절). 작업 폴더 `build/pkg/work/`가 남아 payload를 열어 볼 수 있다.

## 4. 설치가 하는 일 (preinstall과 postinstall)

**preinstall** (root, payload 전): Intel이면 종료 코드 10, macOS 14.4 미만이면 11. 릴리스의 **베이스 python**(`RELEASE_BASE_PYTHON`, 3.1절)이 이 Mac에 없거나 root 소유가 아니거나 다른 사람이 쓸 수 있으면 16:
**아무것도 바꾸기 전에** 멈춘다(그렇지 않으면 postinstall이 20으로 실패한 뒤 Mac에 동작하는 앱이 없다). `/Applications`에 이 pkg와 **같은 번들 ID**인 앱이 **다른 파일 이름**으로 이미 있으면(예전 pkg의 앱, 또는 다른 `MCAP_APP_SHORT_NAME`으로 만든 pkg) 17로 멈춘다: 같은 ID의 앱 둘은 로그인 에이전트와 권한을 함께 쓰고 옛 앱은 새 앱 옆에 남는다. 옛 앱을 지우거나(데이터는 건드리지 않는다), pkg를 옛 파일 이름으로 다시 만든다(`MCAP_APP_SHORT_NAME=<옛 파일 이름, .app 제외>`). 같은 파일 이름의 앱은 업그레이드라 통과한다. 콘솔 사용자의 **개인 설치**(`~/Applications/CATE.app`, 또는 같은 번들 ID의 다른 파일 이름 앱, 사용자 LaunchAgent)가 있으면
`migrate_owner_install.sh --backup`으로 치운다(삭제 없음). 녹음 중이면(세션 폴더의 wav가 2분 안에 바뀜) 아무것도 바꾸지 않고 12로 끝나 MDM이 나중에 다시 시도한다.

**postinstall** (root, payload 후):

1. payload가 만든 앱, shim, LaunchAgent, 공개키를 root:wheel로 하고 그룹과 기타 쓰기를 뺀다.
2. **기준 정책**: `policy.json`이 **없을 때만** 기준 정책(모든 외부 레인 deny, `local_only.default` true)을 0644로 둔다. 있으면(MDM이 준 리비전) 건드리지 않는다. `policy.required` 마커는 항상 둔다:
   정책 파일이 지워진 Mac은 자유가 아니라 **잠금**이다(`policy-locked`: 모든 외부 레인이 닫히고 로컬 전사는 계속된다).
3. **릴리스 활성화**: `provision_runtime.sh --apply`가 서명과 해시를 검증하고 root 소유를 확인한 뒤 `releases/current`를 새 릴리스로 **원자적으로**(새 링크를 만들어 이름을 바꿔 덮는다) 바꾸고 직전 릴리스를 남긴다.
   검증에 실패하면 `current`는 그대로이고 설치가 20으로 실패한다.
4. 도구를 `tools/`에 둔다(MDM이 나중에 쓴다). 설치한 것의 기록(`RELEASE_BUNDLE_ID`, `RELEASE_APP_SHORT_NAME`)도 거기에 둔다: `sudo scripts/uninstall.sh --company`는 sudo가 환경을 넘기지 않으므로 이 기록으로 앱과 LaunchAgent를 찾는다.
5. 콘솔 사용자의 `config.env`를 만든다(6절). 개인 앱이 실행 중이었다면 새 LaunchAgent를 그 사용자에게 로드한다(로그아웃 없이 녹음이 이어진다). **새로 설치한 Mac은 시작하지 않는다**: 다음 로그인에 시작한다.

종료 코드: 0 정상, 10 Apple silicon 아님, 11 macOS 14.4 미만, 12 녹음 중, 13 root 아님, 14 개인 설치를 치우지 못함, 15 payload 불완전, 16 베이스 python이 없거나 안전하지 않음(preinstall), 17 `/Applications`에 같은 번들 ID의 다른 이름 앱이 있음(preinstall), 20 릴리스 검증 실패, 21 pkg에 기준 정책이 없음.
20으로 끝났는데 preinstall이 개인 설치를 치운 뒤라면 `scripts/migrate_owner_install.sh --home "$HOME" --rollback`으로 되돌린다(`docs/MIGRATION.md` 7절).
출력은 `/var/log/install.log`에 남는다. 두 스크립트는 설치 프로그램의 세 번째 인자(대상 볼륨)가 `/`가 아니면 **리허설**로 동작한다(root 불필요, chown을 하지 않고 말만 함, launchd를 건드리지 않음):

```bash
mkdir /tmp/stage && cp -R build/pkg/work/payload/. /tmp/stage/              # 설치 프로그램이 payload를 놓는 것과 같다
MCAP_PKG_CONSOLE_USER=$(id -un) MCAP_PKG_CONSOLE_HOME=$HOME build/pkg/work/scripts/postinstall pkg / /tmp/stage
```

**클린 테스트 Mac에서의 실제 리허설이 먼저다**(TCC 재승인 포함). 이 저장소의 시험은 스텁과 임시 폴더만 쓰고 실제 설치, 서명, 공증, MDM 업로드는 시험하지 않는다.

## 5. 설치 뒤 첫 실행 순서

pkg 설치 → 앱 `setup`(마이크, 시스템 오디오 권한: **MDM으로 없앨 수 없다**, 서명 신원이 바뀌면 다시 묻는다) → `mcap doctor` → (원격 사용 시) 관리자가 준 등록 코드로 `mcap asr-engines enroll remote --code-stdin`
→ `mcap asr-engines check remote --live`. `doctor`는 정책이 있으면 레인 인지형이고(거부된 레인은 `skipped: lane denied`) 정책이 없는 Mac은 FAIL로 보고한다.

## 6. 사용자별 설정 (`scripts/provision_user_config.sh`)

`config/config.env.company.template`에서 `~/Library/Application Support/MeetingCapture/config.env`를 **없을 때만** 만든다(빈 파일이나 끊어진 링크도 있는 것으로 본다: 덮어쓰지 않고 링크를 따라 쓰지도 않는다).

- `SELF_NAME`은 디렉터리 서비스의 실제 이름(`--self-name`으로 덮어쓴다), 없으면 계정 이름.
- `ARCHIVE_DIR`는 `~/Library/CloudStorage/GoogleDrive-*@example.com`(`--drive-domain`) 마운트가 **정확히 하나**이고 그 안에 `Shared drives/Meetings`(`--drive-folder`)가 있을 때만 채운다. 없거나 둘 이상이면 **비운다**:
  회의는 이 Mac의 로컬 아카이브에 남고 Drive 레인은 건너뛴다(company 정책에서 `ARCHIVE_DIR`가 명시되지 않으면 drive는 deny). 한국어 안내가 출력된다. 폴더는 정책의 `archive.allowed_roots`에도 맞아야 한다.
- `CLAUDE_AUTH`는 `--llm allow`(llm 레인이 열린 파일럿 그룹)일 때 `api`, 아니면 `subscription`(Keychain 항목을 읽지 않는 값).
- 개인 값(이름, 메일 주소, 개인 Drive 폴더)은 어디에도 들어가지 않는다. `LOG_RETENTION_DAYS`, `APP_LOG_MAX_MB`, `LOG_CONTENT` 같은 조직 기본값과 강제값은 **정책**이 가진다: 템플릿에 두면 조직의 기본값을 가린다.
- 같은 스크립트가 `sessions/`와 `local-meetings/`를 만들고 Time Machine에서 제외한다(`tmutil addexclusion`, 실패는 경고).

root(postinstall, MDM)로 실행하면 스크립트는 사용자 홈에 스스로 쓰지 않고 `sudo -u <사용자>`로 자신을 다시 실행한다(root가 사용자 폴더에 쓰면 심볼릭 링크로 아무 파일이나 가리킬 수 있다).
설치 때 로그인하지 않은 사용자에게는 MDM이 `/Library/Application Support/MeetingCapture/tools/provision_user_config.sh --user <이름>`을 나중에 돌린다.
**앱의 첫 실행 보강(config.env가 없으면 앱이 직접 만드는 것)은 Swift 쪽 후속 작업이고 이 패키지에 없다.**

## 7. 정책 배포

기준 정책은 `scripts/make_policy.sh`가 만든다(pkg에도 같은 것이 들어간다). 어떤 것도 기본으로 열리지 않고 레인 하나를 여는 것은 새 리비전에서 **승인 참조와 함께**만 가능하다:

```bash
scripts/make_policy.sh --out policy.json                                      # 기준 (모든 레인 deny)
scripts/make_policy.sh --revision 2 --allow drive=TICKET-1234 --out policy.json          # drive만 열기: 승인 참조 필수 (없으면 거부)
scripts/make_policy.sh --revision 3 --allow asr_remote --host asr.example.internal \
    --org-consent "engine=remote,host=asr.example.internal,ca_sha256=<64 hex>,attest=<64 hex>,use=both,expires=2027-10-14" --out policy.json
scripts/make_policy.sh --check policy.json                                    # 파이프라인의 load_org_policy로 검증 (잠금이면 이유를 보여 준다)
```

**클라이언트 전용 릴리스**(`--client-only`: mlx도 로컬 모델도 없다)에서 릴레이를 여는 정책은 **엔진, 주소, CA 파일**을 모두 가져야 한다. `make_policy.sh --client-only`는 기준 정책의 `defaults.ASR_ENGINE`을 `remote`로 둔다
(Whisper를 돌릴 수 없는 Mac에 Whisper를 시키지 않는다. 명시한 `whisper`는 파이프라인이 바꾸지 않는다). 레인이 닫혀 있는 동안에는 아무것도 나가지 않는다. 주소와 CA 파일은 `--default`로 넣는다:

```bash
scripts/make_policy.sh --revision 3 --client-only --allow asr_remote --host asr.example.internal \
    --org-consent "engine=remote,host=asr.example.internal,ca_sha256=<64 hex>,attest=<64 hex>,use=both,expires=2027-10-14" \
    --default ASR_REMOTE_URL=https://asr.example.internal \
    --default "ASR_REMOTE_CA_FILE=/Library/Application Support/MeetingCapture/asr-ca.pem" --out policy.json
```

`ASR_REMOTE_URL`이 없으면 릴레이는 `not-configured`로 제외된 채 남는다(시험으로 확인한다). **CA PEM**(서버 인증서에 서명하는 사설 CA)은 pkg가 깔지 않는다: MDM이 각 Mac의 `/Library/Application Support/MeetingCapture/asr-ca.pem`에
root:wheel 0644로 배포한다(파일 배포 또는 스크립트). 그 파일의 sha256(`shasum -a 256 asr-ca.pem`)이 `--org-consent`의 `ca_sha256`과 **정확히 같아야** 신뢰된다: 다르면 `ca_mismatch`로 아무것도 나가지 않는다. CA가 바뀌면 새 리비전이 필요하다.
확인은 사용자 쪽에서 `mcap asr-engines check remote --live`다(5절).

만든 JSON은 쓰기 전에 파이프라인의 `load_org_policy`로 읽어 보고, **잠금이 될 정책은 쓰지 않는다.** `llm`을 열려면 승인 참조와 함께 `claude` CLI의 서명 핀(`--claude-team-id` 또는 `--claude-sha256`, 값은 관리자가 준다)이 필요하다.
MDM은 이 파일을 임시 파일에 쓰고 rename으로 root 소유 0644로 배포한다(읽는 쪽은 500 ms 뒤 한 번 더 읽는다). 규칙:

- **새 키가 들어간 정책은 새 파이프라인 링이 끝난 뒤에 내린다.** 구버전은 알 수 없는 키를 잠금으로 읽는다(조용히 무시하지 않는다).
- `min_pipeline_version`은 0.2.0 이상으로 쓴다(앱은 정책이 있으면 어차피 0.2.0 이상을 요구한다). 올리는 순서는 `docs/OPS_RUNBOOK.md`.
- 링: 3~5대 카나리 → 일부 → 전체. 지표는 `mcap status`의 `pipeline_version` 분포와 `policy.revision`이다(`scripts/mdm/ea_status.sh`).

## 8. 업그레이드와 롤백 (파이프라인)

릴리스 폴더는 불변이고 `current`만 바뀐다. 새 릴리스를 pkg로 내보내면 postinstall이 위 절차로 활성화한다. pkg 없이 MDM이 폴더를 전달하는 경우:

```bash
sudo /Library/Application\ Support/MeetingCapture/tools/provision_runtime.sh --release-dir "/Library/Application Support/MeetingCapture/releases/0.2.1" --src <전달된 폴더> --apply
```

복사본을 **검증한 뒤에만** 제자리로 옮기고(`--src`는 이미 있는 버전을 거부한다), `current`를 바꾸고, 직전 릴리스를 남기고 그보다 오래된 것을 지운다(`--keep N`). 지금 `current`보다 **낮은** 버전은 이 스크립트가 거부한다.
돌아가려면 `mcap release list`와 `mcap release switch <버전>`을 쓴다(정책의 `min_pipeline_version` 미만이나, 정책이 있을 때 0.2.0 미만으로의 전환은 거부된다). 실행 중인 작업은 시작한 릴리스를 끝까지 쓴다.

## 9. 서버 티어

`scripts/asr_server/install_server.sh`(기본 계획만, `--apply`는 root)는 root 소유 릴리스를 `--project`로 받는다(예: `--project "/Library/Application Support/MeetingCapture/releases/current"`, `--python <그 릴리스의 venv python>`).
서비스 사용자가 자기가 실행하는 코드를 바꿀 수 없어야 하므로 설치 스크립트가 root 소유를 확인한다. TLS 키, 벤더 키, 토큰 표는 서비스 사용자 소유 0600 파일이다(서버 티어에 한한 Keychain 규칙의 예외, SPEC 18.3).
운영은 `docs/OPS_RUNBOOK.md`, 프로토콜은 `docs/ASR_PROTOCOL.md`, 퇴사자 처리는 `scripts/mdm/offboard_user.sh`다.

## 10. MDM 기준과 상태 수집 (관리자 입력)

위협 모델이 기대는 것은 코드가 아니라 MDM이다: **표준 사용자**(관리자 권한 제거), **앱 허용 목록**과 venv python의 호스트별 네트워크 허용, **FileVault 필수**. 이것이 없으면 같은 사용자 권한의 악성코드와 로컬 관리자는 막히지 않는다(`docs/POLICY.md` 11절).
제품(Jamf, Intune 등)과 사용자 권한 정책은 관리자 결정이고, 아래 연결은 제품마다 **[미검증]**이다.

- **상태 수집**: `scripts/mdm/ea_status.sh`는 MDM이 root로 돌리는 확장 속성 스크립트다. 콘솔 사용자를 찾아 그 사용자로 `mcap status --write`를 실행하고 JSON **한 줄**을 출력한다(`--format jamf`는 `<result>`로 감싼다,
  `--out FILE`은 root 소유 파일로도 쓴다). 실패해도 항상 유효한 JSON 한 줄(`{"schema":1,"error":"..."}`)과 종료 코드 0이다. 내용(제목, 세션 ID, 경로, 사용자 이름)은 들어 있지 않다. 사용량은 `STATUS_INCLUDE_USAGE=1`일 때만 들어가고 기본 0이다.
- 이탈자 처리와 서버 토큰 폐기: `scripts/mdm/offboard_user.sh` (계획이 기본, `--apply`는 서버 Mac에서 root).

## 11. 아직 없는 것, 확인되지 않은 것

- 서명, 공증, MDM 업로드, 클린 Mac에서의 실제 설치, hardened runtime의 Process Tap 캡처는 시험하지 않았다(관리자 계정과 기기가 필요하다).
- 릴리스 매니페스트 서명을 **앱이 첫 실행 전에 검증하는 기능은 Swift 쪽에 아직 없다.** 지금 검증은 설치 시점에 `provision_runtime.sh`가 한다(앱의 `RuntimeTrust`는 경로와 관리자만 본다). 앱에 공개키를 넣고 실행 전에 매니페스트를 확인하는 일은 Swift 작업으로 남아 있다.
- 8 GB Mac에서 클라이언트 전용 venv의 동작은 측정 전까지 미검증이다. 이 상태의 기기군에 8 GB 정책 템플릿은 없다. 잠금된 local_only 기기군에는 로컬 probe를 통과한 Mac만 넣는다.
- 검증용 python 문제(3.5절), 베이스 python의 선택과 모든 Mac에 같은 경로로 배포하고 권한을 맞추는 MDM 구성(3.1절), 클라이언트 Mac의 CA PEM 배포(7절), 앱의 `config.env` 첫 실행 보강(6절)은 관리자 결정 또는 후속 작업이다.
- 해시 lock은 관리자가 네트워크에서 한 번 만들어야 생긴다(3.2절).

## 12. 시험

`make test-scripts`(= `scripts/test_scripts.sh`)가 이 문서의 스크립트를 스텁(`pkgbuild`, `productbuild`, `codesign`, `launchctl`, `security`, `tmutil`, `sudo` 등)과 임시 HOME으로 시험한다:
pkg 빌드 계획과 스텁 빌드, distribution의 arm64와 14.4 조건, preinstall과 postinstall의 리허설(기준 정책, 원자적 `current`, 개인 설치 치우기와 되돌리기, 베이스 python이 없거나 그룹이 쓸 수 있으면 아무것도 치우기 전에 16),
서명과 해시 불일치 거부, 베이스 python 점검(없음, 쓰기 가능한 폴더나 파일, 링크, 표준 라이브러리 없음; root 분기는 uid를 바꿔치기한 검증기로), 해시 lock 계획, `load_org_policy`가 받아들이는 정책 생성
(클라이언트 전용 정책에서 판정표가 릴레이를 고르는지 포함), 사용자별 설정(덮어쓰지 않음), EA와 퇴사 스크립트, `uninstall.sh --company`(데이터, 정책, 개인 설치를 남김)와 롤백 순서 전체,
`scripts/asr_server/test_install_server.sh`.
