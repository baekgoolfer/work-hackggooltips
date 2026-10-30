#!/bin/bash
# First-run helper of the app installer: runs in Terminal, installs what the app needs, in seven numbered steps, and can be run again at any
# time (it resumes: finished steps are skipped, nothing that exists is overwritten). The app starts it for you (the alert at the first launch, or the
# menu item "Components: not installed - run installer"); you can also run it by hand:  bash first_run_install.sh
#
#   first_run_install.sh [--bundle DIR] [--accept-legal-notice] [--lang en|ko]
#
#   --bundle DIR           the app's Contents/Resources/mcap folder (default: found from $MCAP_BUNDLE_DIR, from SUPPORT_DIR/first-run.env, from the place of
#                          this script, then /Applications and ~/Applications)
#   --accept-legal-notice  accept the recording legal notice without asking (a run without a terminal needs it; never use it for someone else)
#   --lang en|ko           the language of this window (default: UI_LANGUAGE of an existing config.env, else the macOS language)
#
# The seven steps (each prints [n/7]):
#   1. the recording legal notice (type yes), and the checks: Apple silicon, macOS 14.4 or newer, 12 GB free (2 GB when it was installed before),
#      the package index and the model host answer (HEAD requests), the files of the app are complete
#   2. unpack the bundled Python runtime into SUPPORT_DIR/runtime/python after its sha256 matches components.json (the app's own record)
#   3. scripts/setup_python.sh with that Python: the venv from the pinned requirements (pip --no-deps, hash-locked when the app carries a hash lock),
#      the Silero model and the speech model (pinned revision, sha256 checked); every hash check of that script stays as it is
#   4. the Anthropic API key for the meeting notes: first only whether a Keychain item exists (the value is not read); if not, [1] type it now (the macOS
#      security tool asks for it, hidden: it never passes through this script, an argument, the environment or the shell history) or [2] later in the app's
#      Settings; skipping is fine, audio and transcripts work
#   5. SUPPORT_DIR/config.env from config/config.env.example, ONLY when there is none (never overwritten): ARCHIVE_DIR ~/Meetings, SELF_NAME = the
#      first word of your macOS full name, UI_LANGUAGE from the system language, CLAUDE_AUTH api; PROJECT_DIR is left out on purpose (the app finds
#      its pipeline inside itself)
#   6. where meetings are stored: ~/Meetings, or, when exactly one Google Drive for desktop account is mounted, you are asked (y/n) for My Drive/Meetings
#   7. the app's own `setup` (macOS asks for Microphone, System Audio Recording and Notifications), then SUPPORT_DIR/components-installed.json
#      (the hashes of what is installed: the app compares it with the bundle at every start) and a short summary
#
# A failure prints the step, the likely cause and "run this script again". Nothing half-written is left: files are written beside their destination
# and moved into place. This script never runs sudo, never touches launchctl and installs no login item.
#
# One window at a time: step 2 takes a lock first (SUPPORT_DIR/.first-run.lock, a symbolic link whose target is the pid of this run; ln -s fails when it
# exists, so two windows can never both get it). A second window stops there with "another installer window is already running" and changes nothing; the
# lock of a run that has ended (or of a pid that is not this script any more) is ignored. The app does not open a second window while the lock is held.
#
# The keychain: THIS SCRIPT never runs the macOS security tool and never sees the key. Its Python child (python -m mcap api-key ...) does, in two ways:
# step 4 asks "api-key status --exists", which runs the command "security find-generic-password" WITHOUT -w (attributes only: the stored value is not read and no
# Keychain dialog can appear); and "api-key set" lets the security tool prompt on the terminal, then reads the item back once to report its length and
# whether it starts with sk-ant-. The value is never printed, passed as an argument or stored by us.
#
# The app names in the messages come from the app that holds the files (its Info.plist), else MCAP_APP_NAME / MCAP_APP_SHORT_NAME, else the defaults,
# through scripts/bundle_id.sh of THAT app: the app starts a copy of this script from SUPPORT_DIR, so nothing is read from the script's own folder, and
# a message before the app is found says "the app" (the files are looked for without a name: every *.app of /Applications and ~/Applications).
#
# Environment (tests and support): MCAP_SUPPORT_DIR (default ~/Library/Application Support/MeetingCapture), MCAP_LOG_DIR (default ~/Library/Logs/MeetingCapture),
# MCAP_BUNDLE_DIR, MCAP_UI_LANGUAGE (en|ko), MCAP_APP_NAME, MCAP_APP_SHORT_NAME. The hosts that are checked: https://pypi.org/ and https://huggingface.co/.

set -euo pipefail

TOTAL=7
NEED_FREE_KB=12582912            # 12 GB: about 0.55 GB packages + 3.08 GB speech model + the runtime + headroom for the unpacking and the cache
NEED_FREE_KB_AGAIN=2097152       # 2 GB when the components were installed before (a re-run only repairs)
INDEX_URL="https://pypi.org/simple/"
MODEL_HOST_URL="https://huggingface.co/"

SUPPORT_DIR="${MCAP_SUPPORT_DIR:-$HOME/Library/Application Support/MeetingCapture}"
LOG_DIR="${MCAP_LOG_DIR:-$HOME/Library/Logs/MeetingCapture}"
BUNDLE_OPT=""
ACCEPT_LEGAL=0
LANG_OPT=""
UI="en"
BUNDLE_DIR=""
APP_PATH=""
CURRENT_STEP=0
STEP_TITLE=""
DIED=0
CLEAN=()
LOCK="$SUPPORT_DIR/.first-run.lock"
LOCK_OWNED=0
LOCK_HOLDER=""

# The names of the app, for the messages: learned from the app that holds the files once they are found (learn_names), generic words before.
APP_NAME="the app"
APP_SHORT_NAME=""
APP_FILE="the app"        # "<short name>.app" once the name is known
learn_names() {  # the Info.plist of $APP_PATH, else the environment, else the defaults (scripts/bundle_id.sh of the app that holds the files)
    local lib="$BUNDLE_DIR/scripts/bundle_id.sh" n s
    [ -f "$lib" ] || return 0               # an app that predates the names: the generic words stay
    if n="$(. "$lib"; mcap_resolve_app_name ${APP_PATH:+"$APP_PATH"} 2>/dev/null)" && [ -n "$n" ]; then APP_NAME="$n"; fi
    if s="$(. "$lib"; mcap_resolve_app_short_name ${APP_PATH:+"$APP_PATH"} 2>/dev/null)" && [ -n "$s" ]; then APP_SHORT_NAME="$s"; APP_FILE="$s.app"; fi
}

# ---- output (English and Korean) -----------------------------------------------------------------------------
t()   { if [ "$UI" = ko ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say() { printf '%s\n' "$(t "$1" "$2")"; }
warn() { printf '%s\n' "$(t "WARNING: $1" "주의: $2")" >&2; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

step() {  # $1 = number, $2 = English title, $3 = Korean title
    CURRENT_STEP="$1"
    STEP_TITLE="$(t "$2" "$3")"
    echo
    echo "[$1/$TOTAL] $STEP_TITLE"
}

# fail_step "English: what happened and the likely cause" "Korean ..." : prints the step, the cause and how to continue, then stops.
fail_step() {
    DIED=1
    echo >&2
    printf '%s\n' "$(t "ERROR in step [$CURRENT_STEP/$TOTAL] $STEP_TITLE" "오류: [$CURRENT_STEP/$TOTAL] $STEP_TITLE 단계에서 멈췄어요")" >&2
    printf '  %s\n' "$(t "$1" "$2")" >&2
    printf '%s\n' "$(t "Run this script again: it resumes where it stopped (finished steps are skipped, nothing that exists is overwritten)." \
                       "이 스크립트를 다시 실행하세요. 멈춘 곳부터 이어서 진행해요 (끝난 단계는 건너뛰고, 이미 있는 파일은 덮어쓰지 않아요).")" >&2
    exit 1
}

# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure and a Ctrl-C are reported here.
on_exit() {
    local rc=$? f
    for f in ${CLEAN[@]+"${CLEAN[@]}"}; do rm -rf "$f"; done
    # the lock is removed only while it still names this run
    if [ "$LOCK_OWNED" = 1 ] && [ "$(readlink "$LOCK" 2>/dev/null || true)" = "$$" ]; then rm -f "$LOCK"; fi
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo >&2
        printf '%s\n' "$(t "Stopped in step [$CURRENT_STEP/$TOTAL] $STEP_TITLE (exit code $rc). Run this script again: it resumes." \
                           "[$CURRENT_STEP/$TOTAL] $STEP_TITLE 단계에서 멈췄어요 (종료 코드 $rc). 이 스크립트를 다시 실행하면 이어서 진행해요.")" >&2
    fi
    return 0
}
trap on_exit EXIT
trap 'exit 130' INT TERM
trap 'exit 129' HUP

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) [ $# -ge 2 ] || { echo "--bundle needs a folder" >&2; exit 2; }; BUNDLE_OPT="$2"; shift ;;
        --accept-legal-notice) ACCEPT_LEGAL=1 ;;
        --lang) [ $# -ge 2 ] || { echo "--lang needs en or ko" >&2; exit 2; }; LANG_OPT="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ---- small helpers -------------------------------------------------------------------------------------------
sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

# Value of the last KEY=value line of a config file (inline comment, quotes and blanks removed); empty when missing.
config_value() {  # $1 = file, $2 = key
    [ -f "$1" ] || return 0
    { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" || true; } | tail -n 1 | sed -e 's/^[^=]*=//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

version_ge() {  # $1 >= $2 for dotted numbers (14.4, 15.0.1, 26)
    local i x y
    for i in 1 2 3; do
        x="$(printf '%s' "$1" | awk -F. -v n="$i" '{ print $n }')"
        y="$(printf '%s' "$2" | awk -F. -v n="$i" '{ print $n }')"
        x="${x:-0}"; y="${y:-0}"
        case "$x$y" in *[!0-9]*) return 1 ;; esac
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# The language of this window: --lang, MCAP_UI_LANGUAGE, UI_LANGUAGE of an existing config.env, the macOS language, the locale.
system_language() {  # prints ko or en
    local raw first
    raw="$(defaults read -g AppleLanguages 2>/dev/null || true)"
    first="$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*"\{0,1\}\([A-Za-z][A-Za-z]*\).*$/\1/p' | sed -n '1p')"
    if [ -z "$first" ]; then
        first="$(printf '%s' "${LC_ALL:-${LANG:-}}" | sed -n 's/^\([A-Za-z][A-Za-z]*\).*$/\1/p')"
    fi
    case "$first" in ko|KO|Ko) echo ko ;; *) echo en ;; esac
}
choose_language() {
    local v
    for v in "$LANG_OPT" "${MCAP_UI_LANGUAGE:-}" "$(config_value "$SUPPORT_DIR/config.env" UI_LANGUAGE | tr 'A-Z' 'a-z')"; do
        case "$v" in ko|en) UI="$v"; return 0 ;; esac
    done
    UI="$(system_language)"
}
if [ -n "$LANG_OPT" ]; then
    case "$LANG_OPT" in ko|en) ;; *) echo "--lang must be en or ko" >&2; exit 2 ;; esac
fi
choose_language

# ---- find the app's files ---------------------------------------------------------------------------------------
bundle_ok() { [ -n "$1" ] && [ -f "$1/components.json" ] && [ -d "$1/pipeline/mcap" ] && [ -f "$1/scripts/setup_python.sh" ]; }

resolve_bundle() {
    local c own
    if [ -n "$BUNDLE_OPT" ]; then      # a folder given on the command line is the only candidate: it is never replaced by a guess
        if bundle_ok "$BUNDLE_OPT"; then BUNDLE_DIR="$(cd "$BUNDLE_OPT" && pwd -P)"; return 0; fi
        return 1
    fi
    own="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
    for c in "${MCAP_BUNDLE_DIR:-}" \
             "$({ grep -E '^MCAP_BUNDLE_DIR=' "$SUPPORT_DIR/first-run.env" 2>/dev/null || true; } | tail -n 1 | sed 's/^MCAP_BUNDLE_DIR=//')" \
             "$own" \
             /Applications/*.app/Contents/Resources/mcap "$HOME"/Applications/*.app/Contents/Resources/mcap; do      # no name needed: bundle_ok decides
        if bundle_ok "$c"; then
            BUNDLE_DIR="$(cd "$c" && pwd -P)"
            return 0
        fi
    done
    return 1
}

# Find the app's files now, quietly, so that this window can name the app from the first line on; a failure is reported in step 1.
RESOLVED=0
if resolve_bundle; then
    RESOLVED=1
    APP_PATH="$(cd "$BUNDLE_DIR/../../.." 2>/dev/null && pwd -P || true)"
    learn_names
fi

echo
say "$APP_NAME installer" "$APP_NAME 설치 프로그램"
say "This window installs what the app needs: about 10 to 40 minutes, mostly the download (about 3.7 GB). You can run it again at any time: it resumes." \
    "이 창은 앱에 필요한 것들을 설치해요. 대부분 다운로드(약 3.7 GB)라서 10분에서 40분쯤 걸려요. 언제든 다시 실행할 수 있고, 멈춘 곳부터 이어가요."

# =====================================================================================================================
step 1 "Checking this Mac and the app" "이 Mac과 앱 확인"
# =====================================================================================================================
[ "$RESOLVED" = 1 ] || fail_step "The files of the app were not found (looked for components.json in the folder given with --bundle, in /Applications and in ~/Applications). Likely cause: the app was moved or deleted. Open the app again from its new place and use its menu item to start the installer, or run: bash \"$0\" --bundle <path to the app>/Contents/Resources/mcap" \
    "앱 파일을 찾지 못했어요 (--bundle로 준 폴더, /Applications, ~/Applications에서 components.json을 찾았어요). 앱을 옮기거나 지웠을 수 있어요. 앱을 새 위치에서 다시 열고 메뉴의 설치 항목을 쓰거나, 다음처럼 실행하세요: bash \"$0\" --bundle <앱 경로>/Contents/Resources/mcap"
say "App files: $BUNDLE_DIR" "앱 파일: $BUNDLE_DIR"

# the recording legal notice, before anything is changed (the same text and rule as scripts/install.sh)
if [ ! -f "$BUNDLE_DIR/scripts/legal_notice.sh" ]; then
    fail_step "The app is incomplete: scripts/legal_notice.sh is missing from $BUNDLE_DIR. Likely cause: a damaged copy of the app. Copy $APP_FILE from the disk image again." \
        "앱이 온전하지 않아요: $BUNDLE_DIR 에 scripts/legal_notice.sh 가 없어요. 앱 복사가 잘못됐을 수 있어요. 디스크 이미지에서 $APP_FILE을 다시 복사하세요."
fi
if [ "$UI" = ko ]; then
    echo
    echo "녹음 안내: 이 앱은 회의의 모든 참가자의 목소리를 녹음해요. 참가자에게 알리고 필요한 동의를 받는 것, 그리고 파일을 법에 맞게 보관하고 지우는 것은 사용하는 분의 책임이에요."
    echo "아래 영어 고지를 읽고, 따르겠다면 yes 를 입력하세요."
fi
# shellcheck source=legal_notice.sh
. "$BUNDLE_DIR/scripts/legal_notice.sh"
legal_notice_gate "first-run" "$ACCEPT_LEGAL" 0 "$APP_NAME" \
    || fail_step "The recording legal notice was not accepted (or there is no terminal to ask on). Nothing was changed." \
                 "녹음 고지에 동의하지 않았어요 (또는 물어볼 터미널이 없어요). 아무것도 바뀌지 않았어요."

PROBLEMS=()
say "Checking: Apple silicon, macOS 14.4 or newer, free disk space, the internet." "확인: 애플 실리콘, macOS 14.4 이상, 남은 저장 공간, 인터넷."

is_apple_silicon() {
    [ "$(uname -m 2>/dev/null || true)" = arm64 ] && return 0
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]
}
if is_apple_silicon; then
    say "  Apple silicon: ok" "  애플 실리콘: 확인"
else
    PROBLEMS+=("$(t "This Mac is not an Apple silicon Mac (M1 or newer). The speech model needs one; Intel Macs are not supported." \
                    "이 Mac은 애플 실리콘(M1 이상)이 아니에요. 음성 인식 모델에 필요해서 인텔 Mac은 지원하지 않아요.")")
fi

MACOS="$(sw_vers -productVersion 2>/dev/null || true)"
if [ -n "$MACOS" ] && version_ge "$MACOS" 14.4; then
    say "  macOS $MACOS: ok" "  macOS $MACOS: 확인"
else
    PROBLEMS+=("$(t "macOS ${MACOS:-unknown} is older than 14.4 (the system audio recording the app uses needs 14.4). Update macOS in System Settings > General > Software Update." \
                    "macOS ${MACOS:-알 수 없음}은 14.4보다 낮아요 (앱이 쓰는 시스템 오디오 녹음에 14.4가 필요해요). 시스템 설정 > 일반 > 소프트웨어 업데이트에서 업데이트하세요.")")
fi

FREE_KB="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
FREE_KB="${FREE_KB:-0}"
case "$FREE_KB" in *[!0-9]*) FREE_KB=0 ;; esac
NEED_KB="$NEED_FREE_KB"
[ ! -f "$SUPPORT_DIR/components-installed.json" ] || NEED_KB="$NEED_FREE_KB_AGAIN"
FREE_GB="$(awk -v k="$FREE_KB" 'BEGIN { printf "%.1f", k / 1048576 }')"
NEED_GB="$(awk -v k="$NEED_KB" 'BEGIN { printf "%.0f", k / 1048576 }')"
if [ "$FREE_KB" -ge "$NEED_KB" ]; then
    say "  free disk space: $FREE_GB GB (needs $NEED_GB GB): ok" "  남은 저장 공간: $FREE_GB GB ($NEED_GB GB 필요): 확인"
else
    PROBLEMS+=("$(t "Only $FREE_GB GB of disk space is free, the installation needs $NEED_GB GB. Free some space (empty the Trash, delete large files), then run this again." \
                    "남은 저장 공간이 $FREE_GB GB뿐이에요. 설치에는 $NEED_GB GB가 필요해요. 휴지통을 비우거나 큰 파일을 지워 공간을 확보한 뒤 다시 실행하세요.")")
fi

reachable() {  # $1 = https address: a HEAD request that gets ANY http answer below 500 (the server was reached)
    local code
    code="$(curl --proto '=https' --tlsv1.2 --silent --show-error --head --max-time 20 --output /dev/null --write-out '%{http_code}' "$1" 2>/dev/null || true)"
    case "$code" in [234][0-9][0-9]) return 0 ;; esac
    return 1
}
for url in "$INDEX_URL" "$MODEL_HOST_URL"; do
    if reachable "$url"; then
        say "  $url: reachable" "  $url: 연결됨"
    else
        PROBLEMS+=("$(t "Cannot reach $url. Check your internet connection; a VPN, proxy or firewall (at work or school, for example) may block it (ask whoever runs that network)." \
                        "$url 에 연결할 수 없어요. 인터넷 연결을 확인하세요. VPN, 프록시, 방화벽(회사나 학교 네트워크 등)이 막고 있을 수도 있어요 (그 네트워크의 관리자에게 문의하세요).")")
    fi
done

# the files of the app that the next steps need
COMPONENTS_JSON="$BUNDLE_DIR/components.json"
RUNTIME_SHA="$(plutil -extract python_runtime.sha256 raw -o - "$COMPONENTS_JSON" 2>/dev/null || true)"
RUNTIME_REL="$(plutil -extract python_runtime.file raw -o - "$COMPONENTS_JSON" 2>/dev/null || true)"
LOCK_SHA="$(plutil -extract requirements_lock_sha256 raw -o - "$COMPONENTS_JSON" 2>/dev/null || true)"
if ! printf '%s' "$RUNTIME_SHA" | grep -Eq '^[0-9a-f]{64}$' || ! printf '%s' "$LOCK_SHA" | grep -Eq '^[0-9a-f]{64}$' || [ -z "$RUNTIME_REL" ]; then
    PROBLEMS+=("$(t "components.json of the app is damaged or incomplete ($COMPONENTS_JSON). Copy $APP_FILE from the disk image again." \
                    "앱의 components.json이 손상되었거나 불완전해요 ($COMPONENTS_JSON). 디스크 이미지에서 $APP_FILE을 다시 복사하세요.")")
fi
RES_DIR="$(cd "$BUNDLE_DIR/.." && pwd -P)"
ARCHIVE=""
if [ -n "$RUNTIME_REL" ] && [ -f "$BUNDLE_DIR/$RUNTIME_REL" ]; then
    ARCHIVE="$(cd "$(dirname "$BUNDLE_DIR/$RUNTIME_REL")" && pwd -P)/$(basename "$RUNTIME_REL")"
    case "$ARCHIVE" in
        "$RES_DIR"/*) ;;
        *) PROBLEMS+=("$(t "components.json names a file outside the app ($RUNTIME_REL): refused." "components.json이 앱 밖의 파일($RUNTIME_REL)을 가리켜서 거부했어요.")"); ARCHIVE="" ;;
    esac
elif [ -n "$RUNTIME_REL" ]; then
    PROBLEMS+=("$(t "The Python runtime is missing from the app ($BUNDLE_DIR/$RUNTIME_REL). Copy $APP_FILE from the disk image again." \
                    "앱에 Python 런타임이 없어요 ($BUNDLE_DIR/$RUNTIME_REL). 디스크 이미지에서 $APP_FILE을 다시 복사하세요.")")
fi
for f in setup_python.sh first_run_install.sh; do
    [ -f "$BUNDLE_DIR/scripts/$f" ] || PROBLEMS+=("$(t "The app is incomplete: scripts/$f is missing." "앱이 온전하지 않아요: scripts/$f 가 없어요.")")
done
[ -f "$BUNDLE_DIR/pipeline/requirements.lock.txt" ] || PROBLEMS+=("$(t "The app is incomplete: pipeline/requirements.lock.txt is missing." "앱이 온전하지 않아요: pipeline/requirements.lock.txt 가 없어요.")")
[ -f "$BUNDLE_DIR/config/config.env.example" ] || PROBLEMS+=("$(t "The app is incomplete: config/config.env.example is missing." "앱이 온전하지 않아요: config/config.env.example 이 없어요.")")

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    DETAIL=""
    for p in "${PROBLEMS[@]}"; do DETAIL="$DETAIL
  - $p"; done
    fail_step "$(printf 'These checks failed:%s' "$DETAIL")" "$(printf '다음 확인에서 막혔어요:%s' "$DETAIL")"
fi

# =====================================================================================================================
step 2 "Unpacking the Python runtime" "Python 런타임 풀기"
# =====================================================================================================================
RT_DIR="$SUPPORT_DIR/runtime"
PY_DIR="$RT_DIR/python"
PY="$PY_DIR/bin/python3"
MARKER="$RT_DIR/python-runtime.sha256"

lock_holder_alive() {  # $1 = pid from the lock: true while that process runs AND looks like this helper (a recycled pid of another program does not count)
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    ps -p "$1" -o command= 2>/dev/null | grep -Eq 'first[-_]run[-_]install'
}
take_lock() {  # 0 = this run holds the lock; 1 = another running helper holds it (LOCK_HOLDER = its pid)
    local tries=0 holder
    while [ "$tries" -lt 3 ]; do
        if ln -s "$$" "$LOCK" 2>/dev/null; then LOCK_OWNED=1; return 0; fi
        holder="$(readlink "$LOCK" 2>/dev/null || true)"
        if lock_holder_alive "$holder"; then LOCK_HOLDER="$holder"; return 1; fi
        # shortcut: a stale lock is removed after a second look, two runs that find the same stale lock in the same instant can both pass; fine for two clicks, not for a daemon
        [ "$(readlink "$LOCK" 2>/dev/null || true)" != "$holder" ] || rm -f "$LOCK"
        tries=$((tries + 1))
    done
    LOCK_HOLDER="?"
    return 1
}
mkdir -p "$SUPPORT_DIR"
take_lock || fail_step "Another installer window is already running (process $LOCK_HOLDER). Two installers at once would damage each other's files, so this one changed nothing. Finish the installation in that window (it may be behind other windows). If you cannot find it, close every Terminal window that shows the installer and run this script again." \
    "다른 설치 창이 이미 실행 중이에요 (프로세스 $LOCK_HOLDER). 설치 창 두 개가 동시에 돌면 서로의 파일을 망가뜨려서 이 창은 아무것도 바꾸지 않았어요. 그 창에서 설치를 끝내세요 (다른 창 뒤에 있을 수 있어요). 찾을 수 없으면 설치 화면이 보이는 터미널 창을 모두 닫고 이 스크립트를 다시 실행하세요."
mkdir -p "$RT_DIR"
rm -rf "$RT_DIR"/.python.new.* "$RT_DIR"/.python.old.* "$RT_DIR"/.marker.* 2>/dev/null || true

runtime_ready() {
    [ "$(cat "$MARKER" 2>/dev/null || true)" = "$RUNTIME_SHA" ] || return 1
    [ -x "$PY" ] || return 1
    "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
}

if runtime_ready; then
    say "The Python runtime is already unpacked and matches this app: $PY_DIR" "Python 런타임은 이미 풀려 있고 이 앱과 일치해요: $PY_DIR"
else
    say "Checking the runtime archive against the checksum in components.json ..." "런타임 파일을 components.json의 체크섬과 비교하는 중 ..."
    GOT="$(sha256_of "$ARCHIVE")"
    if [ "$GOT" != "$RUNTIME_SHA" ]; then
        fail_step "The Python runtime inside the app does not match its checksum (expected $RUNTIME_SHA, found $GOT). It was NOT unpacked. Likely cause: a damaged or changed copy of the app. Copy $APP_FILE from the disk image again (or download the disk image again) and open it." \
            "앱 안의 Python 런타임이 체크섬과 달라요 (기대값 $RUNTIME_SHA, 실제 $GOT). 풀지 않았어요. 앱 복사가 손상되었거나 바뀌었을 수 있어요. 디스크 이미지에서 $APP_FILE을 다시 복사하거나 디스크 이미지를 다시 받아 여세요."
    fi
    LIST_FILE="$RT_DIR/.python.list.$$"
    CLEAN+=("$LIST_FILE")
    tar -tzf "$ARCHIVE" > "$LIST_FILE" 2>/dev/null \
        || fail_step "The runtime archive cannot be read. Likely cause: a damaged copy of the app. Copy $APP_FILE from the disk image again." \
                     "런타임 파일을 읽을 수 없어요. 앱 복사가 손상되었을 수 있어요. 디스크 이미지에서 $APP_FILE을 다시 복사하세요."
    if grep -Eq '^/|(^|/)\.\.(/|$)' "$LIST_FILE" || ! grep -Eq '^(\./)?python/bin/python3$' "$LIST_FILE"; then
        fail_step "The runtime archive has an unexpected layout (an absolute path, a '..' member, or no python/bin/python3): refused." \
                  "런타임 파일의 구조가 예상과 달라서 거부했어요 (절대 경로, '..' 항목, 또는 python/bin/python3 없음)."
    fi
    NEW="$RT_DIR/.python.new.$$"
    OLD="$RT_DIR/.python.old.$$"
    CLEAN+=("$NEW" "$OLD")
    mkdir "$NEW"
    say "Unpacking ..." "푸는 중 ..."
    tar -xzf "$ARCHIVE" -C "$NEW" \
        || fail_step "Unpacking failed. Likely cause: the disk is full or the archive is damaged." "푸는 데 실패했어요. 저장 공간이 부족하거나 파일이 손상되었을 수 있어요."
    [ -x "$NEW/python/bin/python3" ] || fail_step "The unpacked runtime has no python/bin/python3." "푼 런타임에 python/bin/python3 가 없어요."
    "$NEW/python/bin/python3" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1 \
        || fail_step "The bundled Python does not run on this Mac (or is older than 3.12). Likely cause: an Intel Mac, or a blocked file. Tell whoever shared the app, or see docs/USER_GUIDE.md of the project it comes from." \
                     "앱에 들어 있는 Python이 이 Mac에서 실행되지 않거나 3.12보다 낮아요. 인텔 Mac이거나 파일이 막혔을 수 있어요. 앱을 공유한 분께 알리거나, 앱을 받은 프로젝트의 docs/USER_GUIDE.ko.md를 보세요."
    if [ -e "$PY_DIR" ]; then mv "$PY_DIR" "$OLD"; fi
    mv "$NEW/python" "$PY_DIR"
    printf '%s\n' "$RUNTIME_SHA" > "$RT_DIR/.marker.$$"
    CLEAN+=("$RT_DIR/.marker.$$")
    mv -f "$RT_DIR/.marker.$$" "$MARKER"
    say "Python runtime ready: $PY_DIR" "Python 런타임 준비 완료: $PY_DIR"
fi

# =====================================================================================================================
step 3 "Installing the packages and the speech models (about 3.7 GB download)" "패키지와 음성 인식 모델 설치 (약 3.7 GB 다운로드)"
# =====================================================================================================================
say "This is the long step: about 0.55 GB of packages and 3.08 GB for the speech model. Leave the Mac on and connected; closing this window stops it, and running it again resumes." \
    "가장 오래 걸리는 단계예요. 패키지 약 0.55 GB와 음성 인식 모델 3.08 GB를 받아요. Mac을 켜 두고 인터넷에 연결해 두세요. 창을 닫으면 멈추지만 다시 실행하면 이어서 받아요."
say "A line about Python 3.12 may appear: it is about the Python bundled with the app." "Python 3.12에 관한 안내가 나올 수 있어요: 앱에 들어 있는 Python에 대한 안내예요."
SETUP_ARGS=(--python "$PY" --with-silero --pre-download-model)
if [ -f "$BUNDLE_DIR/pipeline/requirements.hash-lock.txt" ]; then
    SETUP_ARGS+=(--hash-lock "$BUNDLE_DIR/pipeline/requirements.hash-lock.txt")
    say "The app carries a hash lock: every package is checked against its sha256." "앱에 해시 잠금 파일이 있어서 모든 패키지를 sha256으로 확인해요."
fi
MCAP_SUPPORT_DIR="$SUPPORT_DIR" PYTHONDONTWRITEBYTECODE=1 /bin/bash "$BUNDLE_DIR/scripts/setup_python.sh" "${SETUP_ARGS[@]}" \
    || fail_step "scripts/setup_python.sh stopped (the messages above say why). Likely causes: the connection dropped, a VPN, proxy or firewall blocks pypi.org, huggingface.co or github.com, or the disk is full. A downloaded part is kept and checked again, so a second run is faster." \
                 "scripts/setup_python.sh가 멈췄어요 (위 메시지에 이유가 있어요). 연결이 끊겼거나, VPN·프록시·방화벽이 pypi.org, huggingface.co, github.com을 막고 있거나, 저장 공간이 부족할 수 있어요. 받던 파일은 남겨 두고 다시 확인하므로 두 번째 실행은 더 빨라요."
VENV_PY="$SUPPORT_DIR/venv/bin/python"
[ -x "$VENV_PY" ] || fail_step "setup_python.sh finished but $VENV_PY does not exist." "setup_python.sh가 끝났는데 $VENV_PY 가 없어요."

# Python writes bytecode next to the sources it imports: inside the signed app that would change the sealed bundle. The venv sends the bytecode of
# everything to a cache folder instead (a .pth line of the venv, read by Python at every start).
SITE=""
for d in "$SUPPORT_DIR"/venv/lib/python3.*/site-packages; do
    if [ -d "$d" ]; then SITE="$d"; fi
done
if [ -n "$SITE" ]; then
    printf '%s\n' 'import sys, os; sys.pycache_prefix = os.path.join(os.path.expanduser("~"), "Library", "Caches", "MeetingCapture", "pycache")' > "$SITE/.mcap-bytecode.pth.$$"
    CLEAN+=("$SITE/.mcap-bytecode.pth.$$")
    mv -f "$SITE/.mcap-bytecode.pth.$$" "$SITE/mcap-bytecode.pth"
else
    warn "no site-packages folder found in the venv: the app may write Python bytecode inside itself" "venv에서 site-packages 폴더를 찾지 못했어요. 앱이 자기 안에 Python 바이트코드를 쓸 수 있어요"
fi
say "Packages and models are installed." "패키지와 모델 설치 완료."

# =====================================================================================================================
step 4 "Claude API key (for the meeting notes)" "Claude API 키 (회의록용)"
# =====================================================================================================================
run_mcap() {  # python -m mcap <args> from the pipeline folder of the app, with the venv's Python; no bytecode is written into the app
    ( cd "$BUNDLE_DIR/pipeline" && PYTHONDONTWRITEBYTECODE=1 "$VENV_PY" -m mcap "$@" )
}
if [ -x "$HOME/.local/bin/claude" ] || command -v claude >/dev/null 2>&1; then
    say "The Claude Code tool is installed." "Claude Code 도구가 설치되어 있어요."
else
    say "Note: the meeting notes also need the Claude Code tool (the 'claude' command), which this installer does not install. Install it from https://code.claude.com/docs/en/overview when you want notes." \
        "참고: 회의록을 만들려면 Claude Code 도구('claude' 명령)도 필요해요. 이 설치 프로그램은 설치하지 않아요. 회의록이 필요할 때 https://code.claude.com/docs/en/overview 에서 설치하세요."
fi
# --exists: only the question "is there an item?" (find-generic-password without -w, see the header): the stored value is not read, no Keychain dialog appears
if run_mcap api-key status --exists >/dev/null 2>&1; then
    say "An Anthropic API key is already stored in the macOS Keychain: nothing to do." "Anthropic API 키가 이미 macOS 키체인에 저장되어 있어요. 할 일은 없어요."
else
    say "The meeting notes (the summary after each meeting) are written by Claude and need an Anthropic API key. Audio and transcripts work without one." \
        "회의록(회의가 끝난 뒤의 요약)은 Claude가 쓰고, Anthropic API 키가 필요해요. 키가 없어도 녹음과 전사는 돼요."
    say "  [1] Enter the key now (the macOS security tool asks for it and hides what you type; the key never passes through this script)" \
        "  [1] 지금 키 입력 (macOS security 도구가 키를 물어보고 입력은 화면에 보이지 않아요. 키는 이 스크립트를 거치지 않아요)"
    say "  [2] Later, in the app: menu bar icon > Settings > Claude" "  [2] 나중에 앱에서: 메뉴 막대 아이콘 > 설정 > Claude"
    printf '%s' "$(t "Choose 1 or 2 [2]: " "1 또는 2를 고르세요 [2]: ")"
    ANSWER=""
    read -r ANSWER || ANSWER=""
    if [ "$ANSWER" = 1 ]; then
        if run_mcap api-key set; then
            say "The key is stored in the macOS Keychain." "키를 macOS 키체인에 저장했어요."
        else
            warn "the key was not stored. You can enter it later in the app: menu bar icon > Settings > Claude." "키를 저장하지 못했어요. 나중에 앱에서 입력하세요: 메뉴 막대 아이콘 > 설정 > Claude."
        fi
    else
        say "Skipped. Without a key you get audio and transcripts but no meeting notes; add the key in the app (menu bar icon > Settings > Claude) when you want them." \
            "건너뛰었어요. 키가 없으면 녹음과 전사만 되고 회의록은 만들어지지 않아요. 필요할 때 앱(메뉴 막대 아이콘 > 설정 > Claude)에서 키를 추가하세요."
    fi
fi

# =====================================================================================================================
step 5 "Settings file" "설정 파일"
# =====================================================================================================================
CONFIG="$SUPPORT_DIR/config.env"
STATE="$SUPPORT_DIR/first-run.state"
state_has() { [ -f "$STATE" ] && grep -q "^$1=1\$" "$STATE"; }
state_set() { printf '%s=1\n' "$1" >> "$STATE"; }

clean_text() {  # one line, no '#' (it would start a comment), single blanks, at most 40 characters
    printf '%s' "$1" | tr '\000-\037\177' ' ' | tr -d '#' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' | cut -c1-40
}

mkdir -p "$SUPPORT_DIR"
if [ ! -f "$SUPPORT_DIR/vocabulary.txt" ] && [ -f "$BUNDLE_DIR/config/vocabulary.txt" ]; then
    cp "$BUNDLE_DIR/config/vocabulary.txt" "$SUPPORT_DIR/.vocabulary.txt.$$"
    CLEAN+=("$SUPPORT_DIR/.vocabulary.txt.$$")
    mv -n "$SUPPORT_DIR/.vocabulary.txt.$$" "$SUPPORT_DIR/vocabulary.txt"
fi
if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    say "config.env already exists: kept exactly as it is (never overwritten): $CONFIG" "config.env가 이미 있어서 그대로 두었어요 (덮어쓰지 않아요): $CONFIG"
else
    FULL_NAME="$(id -F 2>/dev/null || true)"
    SELF_VALUE="$(clean_text "$(printf '%s' "$FULL_NAME" | awk '{ print $1 }')")"
    [ -n "$SELF_VALUE" ] || SELF_VALUE="Me"
    LANG_VALUE="$(system_language)"
    [ -z "$LANG_OPT" ] || LANG_VALUE="$LANG_OPT"
    PART="$SUPPORT_DIR/.config.env.part.$$"
    CLEAN+=("$PART")
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ARCHIVE_DIR=*) printf 'ARCHIVE_DIR=~/Meetings\n' ;;
            PROJECT_DIR=*) printf '# PROJECT_DIR is not set on purpose: the app finds its pipeline inside %s (set it only to run another copy)\n' "$APP_FILE" ;;
            SELF_NAME=*) printf 'SELF_NAME=%s\n' "$SELF_VALUE" ;;
            UI_LANGUAGE=*) printf 'UI_LANGUAGE=%s\n' "$LANG_VALUE" ;;
            CLAUDE_AUTH=*) printf 'CLAUDE_AUTH=api\n' ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$BUNDLE_DIR/config/config.env.example" > "$PART"
    grep -q '^ARCHIVE_DIR=' "$PART" && grep -q '^CLAUDE_AUTH=api$' "$PART" || fail_step "config.env could not be prepared from config.env.example. Nothing was written." "config.env.example로 config.env를 만들지 못했어요. 아무것도 쓰지 않았어요."
    chmod 600 "$PART"
    # a hard link is created only when nothing is at the destination, a link included: the file can never replace anything, and a reader sees the whole file or none
    if ln "$PART" "$CONFIG" 2>/dev/null; then
        state_set config_created
        say "Created $CONFIG (name $SELF_VALUE, language $LANG_VALUE, Claude billing: API key)." "$CONFIG 를 만들었어요 (이름 $SELF_VALUE, 언어 $LANG_VALUE, Claude 과금: API 키)."
    elif [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
        say "config.env appeared meanwhile: kept as it is (never overwritten)." "그사이 config.env가 생겨서 그대로 두었어요 (덮어쓰지 않아요)."
    else
        fail_step "config.env could not be created in $SUPPORT_DIR. Nothing half-written was left. Likely cause: the folder is not writable." \
                  "$SUPPORT_DIR 에 config.env를 만들지 못했어요. 쓰다 만 파일은 남기지 않았어요. 폴더에 쓸 권한이 없을 수 있어요."
    fi
    rm -f "$PART"
fi

# =====================================================================================================================
step 6 "Where meetings are stored" "회의 저장 위치"
# =====================================================================================================================
set_archive_dir() {  # $1 = value for ARCHIVE_DIR: the one line of config.env is replaced through a copy beside it (nothing half-written)
    local tmp="$SUPPORT_DIR/.config.env.new.$$" line
    CLEAN+=("$tmp")
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ARCHIVE_DIR=*) printf 'ARCHIVE_DIR=%s\n' "$1" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$CONFIG" > "$tmp"
    grep -q "^ARCHIVE_DIR=" "$tmp" || return 1
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG"
}

if state_has config_created && ! state_has archive_answered; then
    DRIVES=()
    for m in "$HOME/Library/CloudStorage"/GoogleDrive-*/"My Drive"; do
        if [ -d "$m" ]; then DRIVES+=("$m"); fi
    done
    if [ "${#DRIVES[@]}" -eq 1 ]; then
        DRIVE_VALUE="~/Library/CloudStorage/$(basename "$(dirname "${DRIVES[0]}")")/My Drive/Meetings"
        say "One Google Drive account is mounted on this Mac." "이 Mac에는 Google Drive 계정이 하나 연결되어 있어요."
        say "Store the meetings there ($DRIVE_VALUE) instead of on this Mac (~/Meetings)? The audio files are uploaded to that Drive, so follow your company's rules for it." \
            "회의를 이 Mac(~/Meetings) 대신 그 Drive($DRIVE_VALUE)에 저장할까요? 오디오 파일도 그 Drive에 올라가니 회사 규정을 따르세요."
        printf '%s' "$(t "Use Google Drive? [y/N]: " "Google Drive를 쓸까요? [y/N]: ")"
        ANSWER=""
        read -r ANSWER || ANSWER=""
        case "$ANSWER" in
            y|Y|yes|YES|Yes)
                set_archive_dir "$DRIVE_VALUE" \
                    || fail_step "ARCHIVE_DIR could not be written to config.env (the old file is unchanged)." "config.env에 ARCHIVE_DIR를 쓰지 못했어요 (기존 파일은 그대로예요)."
                mkdir -p "${DRIVES[0]}/Meetings"
                say "Meetings will be stored in $DRIVE_VALUE." "회의는 $DRIVE_VALUE 에 저장돼요." ;;
            *) say "Meetings will be stored in ~/Meetings." "회의는 ~/Meetings 에 저장돼요." ;;
        esac
    else
        say "Meetings are stored in ~/Meetings (change it later: menu bar icon > Settings > General)." "회의는 ~/Meetings 에 저장돼요 (나중에 바꾸려면 메뉴 막대 아이콘 > 설정 > 일반)."
    fi
    state_set archive_answered
else
    say "Meeting folder (ARCHIVE_DIR) in config.env: $(config_value "$CONFIG" ARCHIVE_DIR) (kept; change it in Settings)" \
        "config.env의 회의 폴더(ARCHIVE_DIR): $(config_value "$CONFIG" ARCHIVE_DIR) (그대로 둬요. 설정에서 바꿀 수 있어요)"
fi
case "$(config_value "$CONFIG" ARCHIVE_DIR)" in
    "~/Meetings") mkdir -p "$HOME/Meetings" ;;
esac

# =====================================================================================================================
step 7 "Permissions and finishing" "권한 요청과 마무리"
# =====================================================================================================================
if [ -n "$APP_PATH" ] && [ -n "$APP_SHORT_NAME" ] && [ -x "$APP_PATH/Contents/MacOS/$APP_SHORT_NAME" ]; then
    say "macOS now asks for Microphone, System Audio Recording and Notifications: click Allow each time. (If a window does not appear, look behind this one.)" \
        "이제 macOS가 마이크, 시스템 오디오 녹음, 알림 권한을 물어요. 매번 허용을 누르세요. (창이 안 보이면 이 창 뒤를 확인하세요.)"
    TTY_DEV="$(tty 2>/dev/null || true)"
    case "$TTY_DEV" in /dev/*) ;; *) TTY_DEV=/dev/null ;; esac
    if open -n -W -a "$APP_PATH" --stdout "$TTY_DEV" --stderr "$TTY_DEV" --args setup; then
        FAILS=0
        if [ -f "$LOG_DIR/setup-report.txt" ]; then
            FAILS="$({ grep -c '^\[FAIL\]' "$LOG_DIR/setup-report.txt" || true; })"
        fi
        if [ "${FAILS:-0}" -gt 0 ]; then
            warn "the app's check reported $FAILS problem(s): $LOG_DIR/setup-report.txt. A denied permission can be allowed later in System Settings > Privacy & Security, or run this script again." \
                 "앱의 점검에서 문제가 $FAILS 건 나왔어요: $LOG_DIR/setup-report.txt. 거부한 권한은 시스템 설정 > 개인정보 보호 및 보안에서 나중에 허용할 수 있어요. 이 스크립트를 다시 실행해도 돼요."
        else
            say "The app's check finished." "앱의 점검이 끝났어요."
        fi
    else
        warn "the app's permission check could not be started. Components are installed; run this script again to retry the permissions." \
             "앱의 권한 점검을 시작하지 못했어요. 구성 요소는 설치되었어요. 권한은 이 스크립트를 다시 실행해서 시도하세요."
    fi
else
    warn "the app was not found next to its files ($APP_PATH): the permission step was skipped. Open $APP_NAME from the Applications folder and allow what macOS asks." \
         "파일 옆에서 앱을 찾지 못해($APP_PATH) 권한 단계를 건너뛰었어요. Applications 폴더에서 $APP_NAME 앱을 열고 macOS가 묻는 권한을 허용하세요."
fi

APP_VERSION="$(head -n 1 "$BUNDLE_DIR/VERSION" 2>/dev/null | tr -cd 'A-Za-z0-9.+-' || true)"
MARK_TMP="$SUPPORT_DIR/.components-installed.json.$$"
CLEAN+=("$MARK_TMP")
printf '{"python_runtime":{"sha256":"%s"},"requirements_lock_sha256":"%s","app_version":"%s","installed_at":"%s"}\n' \
    "$RUNTIME_SHA" "$LOCK_SHA" "${APP_VERSION:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARK_TMP"
mv -f "$MARK_TMP" "$SUPPORT_DIR/components-installed.json"

echo
say "Done. $APP_NAME is installed." "끝났어요. $APP_NAME 설치가 완료되었어요."
say "What to do next:" "다음에 할 일:"
say "  1. Quit $APP_NAME once (menu bar icon > Quit) and open it again, so that it reads the new settings." \
    "  1. $APP_NAME 앱을 한 번 종료(메뉴 막대 아이콘 > Quit)하고 다시 열어서 새 설정을 읽게 하세요."
say "  2. Open Settings from the menu bar icon (Settings...) to check your name, the language and the Claude key." \
    "  2. 메뉴 막대 아이콘에서 설정(Settings...)을 열어 이름, 언어, Claude 키를 확인하세요."
say "  3. Start a call: a notification tells you when a recording starts and ends. Calls of Zoom, Teams and other call apps (Slack, Webex, Discord, FaceTime, KakaoTalk, WhatsApp ...) are recorded, Google Meet is not by default; switch an app off in the menu: Call Apps. Only Zoom calls have been verified so far." \
    "  3. 통화를 시작하면 녹음이 시작되고 끝날 때 알림이 와요. Zoom, Teams와 다른 통화 앱(Slack, Webex, Discord, FaceTime, 카카오톡, WhatsApp 등)의 통화가 녹음되고, Google Meet는 기본으로 꺼져 있어요. 앱별로 끄려면 메뉴의 Call Apps를 쓰세요. 지금까지 확인된 것은 Zoom 통화뿐이에요."
say "To quit: menu bar icon > Quit. To uninstall: quit the app, drag it to the Trash, and delete the folder $SUPPORT_DIR (your settings and the Python files; meetings already filed in your meeting folder stay)." \
    "종료: 메뉴 막대 아이콘 > Quit. 삭제: 앱을 종료하고 휴지통으로 끌어다 놓은 뒤 $SUPPORT_DIR 폴더를 지우세요 (설정과 Python 파일이에요. 회의 폴더에 이미 저장된 회의는 남아요)."
say "Guide and help: docs/USER_GUIDE.md (Korean: USER_GUIDE.ko.md) in the project this app comes from, or ask whoever shared the app with you." \
    "안내와 문의: 이 앱을 받은 프로젝트의 docs/USER_GUIDE.ko.md, 또는 앱을 공유한 분께 물어보세요."
say "You can close this window." "이 창은 닫아도 돼요."
