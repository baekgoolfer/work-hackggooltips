#!/bin/bash
# Create the per-user config.env of the COMPANY install: the user's name, the Drive folder of the company account, and no
# string of the personal install.
#
#   scripts/provision_user_config.sh [options]
#
# What it does for ONE account:
#   1. config.env from config/config.env.company.template in ~/Library/Application Support/MeetingCapture/, ONLY when that file does not
#      exist (not even an empty one, not even a dangling link): an existing config.env is never read for overwriting, never changed, never
#      replaced. The new file is created exclusively and atomically.
#        SELF_NAME    the real name of the account from the directory service (--self-name overrides), else the account name
#        ARCHIVE_DIR  <Google Drive mount of the company account>/<--drive-folder> when that folder exists (exactly one mount named
#                     GoogleDrive-*@<--drive-domain> under ~/Library/CloudStorage; no domain given = no look), else EMPTY: then the meeting stays on this Mac
#                     (the local archive), the Drive lane is skipped, and a Korean note says what to do
#        CLAUDE_AUTH  api when --llm allow (a pilot group whose policy opens the llm lane), else subscription (never reads a Keychain item)
#        paths        the root-owned release (PROJECT_DIR, PYTHON_BIN: a policy-managed Mac ignores them and fixes them itself)
#   2. the staging and the local archive folders (sessions/, local-meetings/) excluded from Time Machine (tmutil addexclusion; a failure
#      is a warning: mcap doctor reports it).
#
# Options:
#   --user NAME          the account (default: the user who runs this; as root: the console user)
#   --home DIR           its home directory (default: from the directory service, for yourself $HOME)
#   --self-name TEXT     the SELF_NAME to write (default: real name, else account name)
#   --llm allow|deny     does this device group have the llm lane open? (default deny)
#   --drive-domain D     Google Workspace domain of the Drive mount, e.g. example.com (default: $MCAP_DRIVE_DOMAIN, else the one domain that
#                        the GoogleDrive-*@domain archive roots of the installed policy.json name, else none: no Drive folder is looked for)
#   --drive-folder P     folder below the mount that holds the meetings (default "Shared drives/Meetings"; it must also match the
#                        organisation's archive.allowed_roots, docs/POLICY.md)
#   --template FILE      the template (default: config.env.company.template next to this script, else ../config/ of the repository)
#   --release-root DIR   the releases folder written into the path keys (default /Library/Application Support/MeetingCapture/releases)
#   --dry-run            show what would be written (the file's lines, never secrets: there are none), change nothing
#   -h, --help           this text
#
# As root (the installer's postinstall, an MDM script) it never writes into a user's home itself: it starts itself again as that user with
# sudo -u, because a root process that writes into a folder the user owns can be pointed at any file by a symbolic link. A rehearsal or
# test as a normal user needs nothing of that. The Swift app does not call this script (a first-run fallback in the app is a follow-up);
# MDM runs it for users who were not logged in during the installation.
#
# Environment (tests): MCAP_PROVISION_DROPPED=1 marks the second, unprivileged run (set by the script itself).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=""
HOME_DIR=""
SELF_NAME=""
LLM="deny"
DRIVE_DOMAIN="${MCAP_DRIVE_DOMAIN:-}"
DRIVE_FOLDER="Shared drives/Meetings"
TEMPLATE=""
RELEASE_ROOT="/Library/Application Support/MeetingCapture/releases"
DRY_RUN=0
ORIG_ARGS=("$@")
TMP_FILE=""
DIED=0

log()  { echo "[provision_user_config] $*"; }
warn() { echo "[provision_user_config] WARNING: $*" >&2; }
die()  { DIED=1; echo "[provision_user_config] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[provision_user_config] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --user) [ $# -ge 2 ] || die "--user needs a name" 2; USER_NAME="$2"; shift ;;
        --home) [ $# -ge 2 ] || die "--home needs a directory" 2; HOME_DIR="$2"; shift ;;
        --self-name) [ $# -ge 2 ] || die "--self-name needs a text" 2; SELF_NAME="$2"; shift ;;
        --llm) [ $# -ge 2 ] || die "--llm needs allow or deny" 2; LLM="$2"; shift ;;
        --drive-domain) [ $# -ge 2 ] || die "--drive-domain needs a domain" 2; DRIVE_DOMAIN="$2"; shift ;;
        --drive-folder) [ $# -ge 2 ] || die "--drive-folder needs a path" 2; DRIVE_FOLDER="$2"; shift ;;
        --template) [ $# -ge 2 ] || die "--template needs a file" 2; TEMPLATE="$2"; shift ;;
        --release-root) [ $# -ge 2 ] || die "--release-root needs a directory" 2; RELEASE_ROOT="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

case "$LLM" in allow|deny) ;; *) die "--llm must be allow or deny" 2 ;; esac
if [ -z "$DRIVE_DOMAIN" ]; then          # the organisation policy already names the company domain in its archive roots
    DOMAINS="$(grep -o 'GoogleDrive-\*@[A-Za-z0-9.-]*' "${MCAP_POLICY_PATH:-/Library/Application Support/MeetingCapture/policy.json}" 2>/dev/null | sed 's/.*@//' | sort -u || true)"
    if [ -n "$DOMAINS" ] && [ "$(printf '%s\n' "$DOMAINS" | grep -c .)" = 1 ]; then DRIVE_DOMAIN="$DOMAINS"; fi
fi
[ -z "$DRIVE_DOMAIN" ] || printf '%s' "$DRIVE_DOMAIN" | grep -Eq '^[A-Za-z0-9.-]+$' || die "--drive-domain looks wrong: '$DRIVE_DOMAIN'" 2
case "$DRIVE_FOLDER" in /*|*..*) die "--drive-folder must be a relative folder path without .. (got '$DRIVE_FOLDER')" 2 ;; esac
case "$RELEASE_ROOT" in /*) ;; *) die "--release-root must be an absolute path" 2 ;; esac
if [ -z "$TEMPLATE" ]; then
    if [ -f "$SCRIPT_DIR/config.env.company.template" ]; then TEMPLATE="$SCRIPT_DIR/config.env.company.template"
    else TEMPLATE="$SCRIPT_DIR/../config/config.env.company.template"; fi
fi
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

# ---- which account -------------------------------------------------------------------------------------------------------------------
console_user() { stat -f %Su /dev/console 2>/dev/null || true; }

if [ -z "$USER_NAME" ]; then
    if [ "$(id -u)" = 0 ]; then
        USER_NAME="$(console_user)"
        case "$USER_NAME" in ""|root|loginwindow|_*) die "no user is logged in at the console: pass --user NAME" ;; esac
    else
        USER_NAME="$(id -un)"
    fi
fi
printf '%s' "$USER_NAME" | grep -Eq '^[A-Za-z0-9._-]+$' || die "--user looks wrong: '$USER_NAME'" 2

# root never writes into a home folder: run again as that user
if [ "$(id -u)" = 0 ] && [ -z "${MCAP_PROVISION_DROPPED:-}" ] && [ "$USER_NAME" != root ]; then
    log "running as root: starting again as $USER_NAME (a root process must not write into a user's folder)"
    exec sudo -u "$USER_NAME" -H env MCAP_PROVISION_DROPPED=1 /bin/bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} --user "$USER_NAME"
fi

dscl_value() {  # $1 = attribute: the value of /Users/<user>, one line, blanks trimmed; empty when unknown
    dscl . -read "/Users/$USER_NAME" "$1" 2>/dev/null | sed -e "1s/^$1://" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

if [ -z "$HOME_DIR" ]; then
    if [ "$USER_NAME" = "$(id -un)" ]; then
        HOME_DIR="$HOME"
    else
        HOME_DIR="$(dscl_value NFSHomeDirectory)"
    fi
fi
case "$HOME_DIR" in /*) ;; *) die "cannot tell the home directory of $USER_NAME: pass --home DIR" ;; esac
[ -d "$HOME_DIR" ] || die "the home directory does not exist: $HOME_DIR"
SUPPORT="$HOME_DIR/Library/Application Support/MeetingCapture"
CONFIG="$SUPPORT/config.env"

# ---- the values ------------------------------------------------------------------------------------------------------------------------
clean_text() {  # one line (control characters become blanks), no '#' (it would start a comment), single blanks, at most 60 characters
    printf '%s' "$1" | tr '\000-\037\177' ' ' | tr -d '#' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' | cut -c1-60
}

if [ -z "$SELF_NAME" ]; then
    SELF_NAME="$(dscl_value RealName)"
    if [ -z "$SELF_NAME" ] && [ "$USER_NAME" = "$(id -un)" ]; then SELF_NAME="$(id -F 2>/dev/null || true)"; fi
fi
SELF_NAME="$(clean_text "$SELF_NAME")"
[ -n "$SELF_NAME" ] || SELF_NAME="$(clean_text "$USER_NAME")"
[ -n "$SELF_NAME" ] || die "no usable name for SELF_NAME: pass --self-name"

# The Drive mount of the company account: exactly one GoogleDrive-*@<domain> folder with the meetings folder inside.
ARCHIVE_VALUE=""
DRIVE_NOTE=""
MOUNTS=()
if [ -n "$DRIVE_DOMAIN" ] && [ -d "$HOME_DIR/Library/CloudStorage" ]; then
    for m in "$HOME_DIR/Library/CloudStorage"/GoogleDrive-*@"$DRIVE_DOMAIN"; do
        [ -d "$m" ] && MOUNTS+=("$m")
    done
fi
case "${#MOUNTS[@]}" in
    0) if [ -n "$DRIVE_DOMAIN" ]; then DRIVE_NOTE="no Google Drive mount of a @$DRIVE_DOMAIN account under ~/Library/CloudStorage"
       else DRIVE_NOTE="no Drive domain given (--drive-domain or MCAP_DRIVE_DOMAIN): no Drive folder was looked for"; fi ;;
    1) if [ -d "${MOUNTS[0]}/$DRIVE_FOLDER" ]; then
           ARCHIVE_VALUE="~/Library/CloudStorage/$(basename "${MOUNTS[0]}")/$DRIVE_FOLDER"
       else
           DRIVE_NOTE="the Drive mount has no folder '$DRIVE_FOLDER' (a shared drive that is not synced to this Mac yet?)"
       fi ;;
    *) DRIVE_NOTE="${#MOUNTS[@]} Google Drive mounts of @$DRIVE_DOMAIN accounts: not guessing which one" ;;
esac
if [ "$LLM" = allow ]; then CLAUDE_AUTH_VALUE="api"; else CLAUDE_AUTH_VALUE="subscription"; fi

render() {  # the template with the three per-user values and the release paths, line by line (no value goes through sed or a shell eval)
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ARCHIVE_DIR=@ARCHIVE_DIR@) printf 'ARCHIVE_DIR=%s\n' "$ARCHIVE_VALUE" ;;
            SELF_NAME=@SELF_NAME@) printf 'SELF_NAME=%s\n' "$SELF_NAME" ;;
            CLAUDE_AUTH=@CLAUDE_AUTH@) printf 'CLAUDE_AUTH=%s\n' "$CLAUDE_AUTH_VALUE" ;;
            PROJECT_DIR=@RELEASE_ROOT@/current) printf 'PROJECT_DIR=%s/current\n' "$RELEASE_ROOT" ;;
            PYTHON_BIN=@RELEASE_ROOT@/current/venv/bin/python) printf 'PYTHON_BIN=%s/current/venv/bin/python\n' "$RELEASE_ROOT" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$TEMPLATE"
}

# ---- 1. config.env ---------------------------------------------------------------------------------------------------------------------
log "account $USER_NAME, home $HOME_DIR"
WRITING=0
if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    log "config.env exists: kept as it is (never overwritten): $CONFIG"
else
    WRITING=1
    TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/mcap-userconfig.XXXXXX")"
    render > "$TMP_FILE"
    if grep -Eq '@[A-Z_]+@' "$TMP_FILE"; then
        die "unreplaced placeholder left in the config: $(grep -Eo '@[A-Z_]+@' "$TMP_FILE" | sort -u | tr '\n' ' ')"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would create $CONFIG with SELF_NAME=$SELF_NAME, ARCHIVE_DIR=${ARCHIVE_VALUE:-(empty)}, CLAUDE_AUTH=$CLAUDE_AUTH_VALUE"
    else
        mkdir -p "$SUPPORT"
        PART="$SUPPORT/.config.env.part.$$"
        cp "$TMP_FILE" "$PART"                 # in the same folder as the destination: a hard link cannot cross volumes
        chmod 644 "$PART"
        # a hard link is created only when nothing is at the destination, a link included: the file cannot replace anything, and a reader
        # sees the whole file or none
        if ln "$PART" "$CONFIG" 2>/dev/null; then
            log "created $CONFIG (SELF_NAME=$SELF_NAME, ARCHIVE_DIR=${ARCHIVE_VALUE:-(empty)}, CLAUDE_AUTH=$CLAUDE_AUTH_VALUE)"
        else
            log "config.env appeared meanwhile: kept as it is (never overwritten)"
        fi
        rm -f "$PART"
    fi
    rm -f "$TMP_FILE"
    TMP_FILE=""
fi

if [ "$WRITING" = 1 ] && [ -z "$ARCHIVE_VALUE" ]; then
    log "ARCHIVE_DIR is empty: $DRIVE_NOTE"
    echo "Google Drive 폴더를 찾지 못했어요. 회의는 이 Mac의 로컬 폴더(~/Library/Application Support/MeetingCapture/local-meetings)에 저장되고 Drive 업로드는 하지 않아요."
    if [ -n "$DRIVE_DOMAIN" ]; then
        echo "Google Drive for desktop에 회사(@$DRIVE_DOMAIN) 계정으로 로그인한 뒤 IT 헬프데스크에 알려 주세요."
    else
        echo "Drive 계정 도메인이 지정되지 않았어요. 지정하려면 --drive-domain 도메인 또는 MCAP_DRIVE_DOMAIN을 쓰세요."
    fi
fi

# ---- 2. Time Machine exclusion of the staging and the local archive --------------------------------------------------------------------
for d in sessions local-meetings; do
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would create $SUPPORT/$d and exclude it from Time Machine"
        continue
    fi
    mkdir -p "$SUPPORT/$d"
    if tmutil addexclusion "$SUPPORT/$d" >/dev/null 2>&1; then
        log "$d/: excluded from Time Machine"
    else
        warn "could not exclude $SUPPORT/$d from Time Machine (mcap doctor reports it)"
    fi
done
log "done."
[ "$DRY_RUN" != 1 ] || log "(dry run: nothing was changed)"
