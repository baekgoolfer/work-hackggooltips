#!/bin/bash
# Install the mcap-asr/1 server (pipeline/mcap/asr_server.py) as a LaunchDaemon on an Apple silicon Mac.
#
#   scripts/asr_server/install_server.sh [options]
#
#   (no mode option)     DRY RUN: prints the plan and the rendered LaunchDaemon plist, changes nothing, starts nothing.
#   --apply              do it (needs root: run it with sudo yourself; the script never calls sudo): create the service user
#                        and group, the 0700 directories, the config (only when there is none), the LaunchDaemon plist (validated with
#                        plutil -lint) and the log file. Nothing is loaded: the launchctl commands are printed for you to run.
#   --load               with --apply: also load and start the daemon:  launchctl bootstrap system <plist>  (an already loaded copy
#                        is booted out first, so this also applies a changed plist).
#   --stage-dir DIR      write the file tree that --apply would create under DIR instead of the system (no root, no user, no chown,
#                        no launchctl): for a package payload or a rehearsal. The plist inside names the REAL target paths.
#   --python PATH        python of the SERVER venv (mlx-whisper, numpy, truststore). Required with --apply and --stage-dir.
#   --project DIR        the checkout or release that holds pipeline/mcap (default: this checkout). With --apply it and the python
#                        must be owned by root and not writable by group or others: the service user must not be able to change
#                        the code it runs.
#   --service-user NAME  default mcap-asr (a group of the same name is created)
#   --support-dir DIR    secrets_dir: tokens, enrollment codes, TLS key, asr-server.json
#                        (default /Library/Application Support/MeetingCapture-asr)
#   --log-dir DIR        metadata log and server.log (default /Library/Logs/MeetingCapture-asr)
#   --plist-path PATH    default /Library/LaunchDaemons/org.meetingcapture.asr.plist
#   -h, --help           this text
#
# Re-running (an upgrade, a changed plist) is safe against the service user: the support, home and log directories and the files in
# them belong to that user, so it could have put a symbolic link where the installer chmods, chowns or writes as root. The script
# therefore refuses any of these paths that is a link, creates every new file exclusively (never through a link, never over a file),
# uses chmod -h and chown -h, and refuses an existing support or log directory that is not owned by root or the service user, or that
# is not empty and was not made by this script (a mistaken --support-dir /var/log must not be chmod 700 and chowned).
#
# What is NOT done here: TLS keys and certificates (put tls.crt and tls.key into the support directory, owner mcap-asr, tls.key 0600,
# and set tls_cert / tls_key in asr-server.json: a non-loopback listen address is refused without them), the model (put it in the
# Hugging Face cache of the service user: the server never downloads), FileVault, a UPS, the VPN, the first token. The end of the output
# lists the commands. launchctl is only ever called with --apply --load. Nothing here touches a Keychain.
#
# [미검증] the --apply path has been exercised with stubbed dscl/chown/launchctl only (scripts/asr_server/test_install_server.sh), never
# on a real server Mac: do the first install by hand-reading the plan (run without options first).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$HERE/../.." && pwd -P)"
LABEL="org.meetingcapture.asr"
SERVICE_USER="mcap-asr"
SUPPORT_DIR="/Library/Application Support/MeetingCapture-asr"
LOG_DIR="/Library/Logs/MeetingCapture-asr"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
TEMPLATE="$HERE/org.meetingcapture.asr.plist.template"
EXAMPLE="$HERE/asr-server.example.json"
PYTHON=""
MODE="dry"           # dry | apply | stage
LOAD=0
STAGE=""
TMP_FILES=()

DIED=0
say() { echo "[install_server] $*"; }
die() { DIED=1; echo "[install_server] ERROR: $*" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
on_exit() {
    local rc=$?
    local f
    for f in "${TMP_FILES[@]:-}"; do [ -z "$f" ] || rm -f "$f"; done
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[install_server] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) [ "$MODE" != stage ] || die "--apply and --stage-dir exclude each other" 2; MODE=apply ;;
        --load) LOAD=1 ;;
        --stage-dir) [ $# -ge 2 ] || die "--stage-dir needs a directory" 2; [ "$MODE" != apply ] || die "--apply and --stage-dir exclude each other" 2
                     MODE=stage; STAGE="$2"; shift ;;
        --python) [ $# -ge 2 ] || die "--python needs a path" 2; PYTHON="$2"; shift ;;
        --project) [ $# -ge 2 ] || die "--project needs a directory" 2; PROJECT_DIR="$2"; shift ;;
        --service-user) [ $# -ge 2 ] || die "--service-user needs a name" 2; SERVICE_USER="$2"; shift ;;
        --support-dir) [ $# -ge 2 ] || die "--support-dir needs a directory" 2; SUPPORT_DIR="$2"; shift ;;
        --log-dir) [ $# -ge 2 ] || die "--log-dir needs a directory" 2; LOG_DIR="$2"; shift ;;
        --plist-path) [ $# -ge 2 ] || die "--plist-path needs a path" 2; PLIST_PATH="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

[ "$LOAD" != 1 ] || [ "$MODE" = apply ] || die "--load needs --apply" 2
case "$SERVICE_USER" in
    [a-z_]*) case "$SERVICE_USER" in *[!a-z0-9_-]*) die "--service-user must be lower-case letters, digits, - and _" 2 ;; esac ;;
    *) die "--service-user must start with a lower-case letter or _" 2 ;;
esac
for p in "$PROJECT_DIR" "$SUPPORT_DIR" "$LOG_DIR" "$PLIST_PATH" "$PYTHON"; do
    case "$p" in
        "") ;;
        /*) ;;
        *) die "every path must be absolute (got '$p')" 2 ;;
    esac
done
[ "$MODE" = dry ] || [ -n "$PYTHON" ] || die "--python is required with --apply and --stage-dir" 2
[ -f "$TEMPLATE" ] || die "plist template not found: $TEMPLATE"
[ -f "$EXAMPLE" ] || die "example config not found: $EXAMPLE"
SERVICE_GROUP="$SERVICE_USER"
HOME_DIR="$SUPPORT_DIR/home"
CONFIG="$SUPPORT_DIR/asr-server.json"
SHOW_PYTHON="${PYTHON:-<--python PATH of the server venv>}"

# Where files really go: the system, or a staging tree.
if [ "$MODE" = stage ]; then
    case "$STAGE" in /*) ;; *) die "--stage-dir must be an absolute path" 2 ;; esac
    DEST_SUPPORT="$STAGE$SUPPORT_DIR"; DEST_LOG="$STAGE$LOG_DIR"; DEST_PLIST="$STAGE$PLIST_PATH"
else
    DEST_SUPPORT="$SUPPORT_DIR"; DEST_LOG="$LOG_DIR"; DEST_PLIST="$PLIST_PATH"
fi
DEST_HOME="$DEST_SUPPORT/home"
DEST_CONFIG="$DEST_SUPPORT/asr-server.json"
MARKER=".mcap-asr-install"          # written into the support and the log directory: 'this directory was made by install_server.sh'

# run <cmd...>: show the command; execute it unless this is a dry run.
run() {
    printf '[install_server]   +'; printf ' %q' "$@"; printf '\n'
    if [ "$MODE" != dry ]; then "$@"; fi
}
# priv <cmd...>: like run, but only on the real system (a staging tree has no users, owners or daemons).
priv() {
    case "$MODE" in
        apply) run "$@" ;;
        stage) printf '[install_server]   - (skipped in --stage-dir mode):'; printf ' %q' "$@"; printf '\n' ;;
        *) run "$@" ;;
    esac
}
step() { echo; say "== $*"; }

render_plist() {
    sed -e "s|@PYTHON@|$(sed_escape "$(xml_escape "$SHOW_PYTHON")")|g" \
        -e "s|@PROJECT_DIR@|$(sed_escape "$(xml_escape "$PROJECT_DIR")")|g" \
        -e "s|@CONFIG@|$(sed_escape "$(xml_escape "$CONFIG")")|g" \
        -e "s|@SERVICE_USER@|$(sed_escape "$(xml_escape "$SERVICE_USER")")|g" \
        -e "s|@SERVICE_GROUP@|$(sed_escape "$(xml_escape "$SERVICE_GROUP")")|g" \
        -e "s|@HOME_DIR@|$(sed_escape "$(xml_escape "$HOME_DIR")")|g" \
        -e "s|@LOG_DIR@|$(sed_escape "$(xml_escape "$LOG_DIR")")|g" "$TEMPLATE"
}

render_config() {
    "${MCAP_PYTHON3:-python3}" - "$EXAMPLE" "$SUPPORT_DIR" "$LOG_DIR" <<'PYEOF'
import json, sys
src, support, logs = sys.argv[1:4]
with open(src, encoding="utf-8") as fh:
    obj = json.load(fh)
obj["secrets_dir"], obj["log_dir"] = support, logs
json.dump(obj, sys.stdout, indent=2, ensure_ascii=False)
print()
PYEOF
}

# check_root_owned <path> <what>: the code the daemon runs must belong to root and not be writable by anybody else.
check_root_owned() {
    local path="$1" what="$2" owner mode
    [ -e "$path" ] || die "$what does not exist: $path"
    owner="$(stat -f %u "$path" 2>/dev/null)" || die "cannot read the owner of $what ($path)"
    mode="$(stat -f %Lp "$path")"
    [ "$owner" = 0 ] || die "$what ($path) must be owned by root (it is owned by uid $owner): the service user must not be able to change the code it runs"
    [ $((8#$mode & 8#022)) -eq 0 ] || die "$what ($path) must not be writable by group or others (mode $mode)"
}

# no_symlink <path> <what>: root writes into directories that the service user owns, so what is found there may have been put there by it.
no_symlink() {
    if [ -L "$1" ]; then die "$2 ($1) is a symbolic link: refusing to chmod, chown or write through it (remove it, then run again)"; fi
}

# check_existing_dir <path> <what> [<an entry that proves it is ours>]: a directory that is already there must be a real directory
# (never a link), owned by root or by the service user (a staging tree is owned by whoever stages it), and, when an entry name is
# given, empty or made by an earlier run of this script (the marker file, or that entry).
check_existing_dir() {
    local path="$1" what="$2" proof="${3:-}" owner service_uid=""
    no_symlink "$path" "$what"
    [ -e "$path" ] || return 0
    [ -d "$path" ] || die "$what ($path) exists and is not a directory"
    if [ "$MODE" != stage ]; then
        owner="$(stat -f %u "$path" 2>/dev/null)" || die "cannot read the owner of $what ($path)"
        service_uid="$(id -u "$SERVICE_USER" 2>/dev/null || true)"
        if [ "$owner" != 0 ] && [ "$owner" != "$service_uid" ]; then
            die "$what ($path) is owned by uid $owner: it must belong to root or to $SERVICE_USER (is --support-dir or --log-dir a mistake?)"
        fi
    fi
    if [ -n "$proof" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ] && [ ! -e "$path/$MARKER" ] && [ ! -e "$path/$proof" ]; then
        die "$what ($path) is not empty and was not made by this script (no $MARKER, no $proof): refusing to chmod and chown it. Is --support-dir or --log-dir a mistake?"
    fi
}

# make_file <path> <mode> <owner:group or -> [<source file>]: create a NEW file with the content of <source> (default: empty). The shell's
# noclobber makes the open exclusive: it fails when anything is there, a file or a link (a dangling one too), so nothing is written through
# a link. Then the mode and the owner, both without following a link.
make_file() {
    local path="$1" mode="$2" owner="$3" src="${4:-/dev/null}"
    printf '[install_server]   + new file %q (mode %s%s)\n' "$path" "$mode" "$([ "$owner" = - ] || printf ', owner %s' "$owner")"
    if [ "$MODE" = dry ]; then return 0; fi
    ( umask 077; set -C; cat "$src" > "$path" ) 2>/dev/null || die "cannot create $path: something is there already (a file or a link)"
    run chmod -h "$mode" "$path"
    if [ "$owner" != - ]; then priv chown -h "$owner" "$path"; fi
}

# ---- 0. plan header ------------------------------------------------------------------------------------------------
case "$MODE" in
    dry) say "DRY RUN: nothing is changed or started. Add --apply (as root) to do it, or --stage-dir DIR to write the tree somewhere else." ;;
    apply) say "APPLY: installing the mcap-asr/1 server as $LABEL (user $SERVICE_USER)" ;;
    stage) say "STAGE: writing the tree under $STAGE (no root, no user, no daemon)" ;;
esac
say "project $PROJECT_DIR"
say "python  $SHOW_PYTHON"
say "support $SUPPORT_DIR (tokens, enrollment codes, TLS key, asr-server.json)    log $LOG_DIR"

# ---- 1. preconditions ------------------------------------------------------------------------------------------------
step "1. preconditions"
if [ "$MODE" = apply ]; then
    [ "$(id -u)" = 0 ] || die "--apply needs root: run it with sudo (this script never calls sudo itself)"
    [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "the server runs on an Apple silicon Mac only (this is $(uname -s) $(uname -m))"
    check_root_owned "$PROJECT_DIR/pipeline" "the pipeline directory"
    check_root_owned "$PROJECT_DIR/pipeline/mcap" "the mcap package"
    [ -x "$PYTHON" ] || die "--python is not an executable file: $PYTHON"
    check_root_owned "$(cd "$(dirname "$PYTHON")" && pwd -P)" "the directory of the server python"
    say "ok: root-owned code, Apple silicon, running as root"
else
    say "would check: running as root (id -u), Apple silicon (uname -m = arm64), root-owned $PROJECT_DIR/pipeline, $PROJECT_DIR/pipeline/mcap and the directory of the python"
    if [ "$MODE" = dry ] && [ "$(uname -m)" != arm64 ]; then say "WARNING (dry run): this machine is $(uname -m): the real run needs Apple silicon"; fi
    [ -f "$PROJECT_DIR/pipeline/mcap/asr_server.py" ] || die "no pipeline/mcap/asr_server.py under $PROJECT_DIR"
    if [ -n "$PYTHON" ] && [ ! -x "$PYTHON" ]; then die "--python is not an executable file: $PYTHON"; fi
fi
[ -f "$PROJECT_DIR/pipeline/mcap/asr_server.py" ] || die "no pipeline/mcap/asr_server.py under $PROJECT_DIR"
# What is already there (an upgrade, or a mistaken path): refused BEFORE anything is changed, in a dry run too.
check_existing_dir "$DEST_SUPPORT" "the support directory" "asr-server.json"
check_existing_dir "$DEST_LOG" "the log directory" "server.log"
check_existing_dir "$DEST_HOME" "the service home"
no_symlink "$DEST_CONFIG" "the config file"
no_symlink "$DEST_LOG/server.log" "server.log"
no_symlink "$DEST_PLIST" "the LaunchDaemon plist"
say "ok: the existing support, home and log paths, the config, server.log and the plist are not links (and the directories are ours or empty)"

# ---- 2. the service user ---------------------------------------------------------------------------------------------
step "2. service user $SERVICE_USER (no login, no password, no login keychain)"
if [ "$MODE" = apply ] && dscl . -read "/Users/$SERVICE_USER" >/dev/null 2>&1; then
    say "user $SERVICE_USER exists already: left as it is"
elif [ "$MODE" = stage ]; then
    say "(skipped in --stage-dir mode) would create group and user $SERVICE_USER with dscl unless they exist"
else
    if [ "$MODE" = apply ]; then
        used="$({ dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } | awk '{print $2}')"
        ID=""
        for cand in $(seq 250 499); do
            if ! printf '%s\n' "$used" | grep -qx "$cand"; then ID="$cand"; break; fi
        done
        [ -n "$ID" ] || die "no free id between 250 and 499 for the service user"
    else
        ID="<free id in 250-499>"
    fi
    run dscl . -create "/Groups/$SERVICE_GROUP"
    run dscl . -create "/Groups/$SERVICE_GROUP" PrimaryGroupID "$ID"
    run dscl . -create "/Users/$SERVICE_USER"
    run dscl . -create "/Users/$SERVICE_USER" UniqueID "$ID"
    run dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID "$ID"
    run dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
    run dscl . -create "/Users/$SERVICE_USER" RealName "MeetingCapture ASR server"
    run dscl . -create "/Users/$SERVICE_USER" NFSHomeDirectory "$HOME_DIR"
    run dscl . -create "/Users/$SERVICE_USER" Password '*'
    run dscl . -create "/Users/$SERVICE_USER" IsHidden 1
fi

# ---- 3. directories ----------------------------------------------------------------------------------------------------
step "3. private directories (0700, owned by $SERVICE_USER)"
# Everything is made and set while root still owns it; the support directory is handed over last (it holds the home directory, and
# once the service user owns it the user could swap what is inside for a link).
for d in "$DEST_SUPPORT" "$DEST_LOG"; do
    ( umask 077; run mkdir -p "$d" )
done
( umask 077; run mkdir -p "$DEST_HOME" )
for d in "$DEST_SUPPORT" "$DEST_LOG"; do
    if [ ! -e "$d/$MARKER" ]; then make_file "$d/$MARKER" 644 root:wheel; fi
done
for d in "$DEST_HOME" "$DEST_LOG" "$DEST_SUPPORT"; do
    run chmod -h 700 "$d"
    priv chown -h "$SERVICE_USER:$SERVICE_GROUP" "$d"
done

# ---- 4. config -----------------------------------------------------------------------------------------------------------
step "4. $CONFIG (root-owned and read-only for the service: it cannot change its own limits)"
if [ "$MODE" != dry ] && [ -e "$DEST_CONFIG" ]; then
    say "$CONFIG exists: left as it is (compare with $EXAMPLE yourself)"
else
    say "would write $CONFIG from $EXAMPLE with secrets_dir and log_dir set to the paths above (mode 0644)"
    if [ "$MODE" != dry ]; then
        TMP_CFG="$(mktemp "${TMPDIR:-/tmp}/mcap-asr-config.XXXXXX")"; TMP_FILES+=("$TMP_CFG")
        render_config > "$TMP_CFG" || die "cannot render the config (needs python3 on PATH)"
        make_file "$DEST_CONFIG" 644 root:wheel "$TMP_CFG"
    fi
fi

# ---- 5. log file --------------------------------------------------------------------------------------------------------
step "5. $LOG_DIR/server.log (launchd opens it before it drops privileges: create it for the service user, 0600)"
if [ "$MODE" != dry ] && [ -e "$DEST_LOG/server.log" ]; then
    say "server.log exists: left as it is"
else
    make_file "$DEST_LOG/server.log" 600 "$SERVICE_USER:$SERVICE_GROUP"
fi

# ---- 6. the LaunchDaemon ------------------------------------------------------------------------------------------------
step "6. $PLIST_PATH"
TMP_PLIST="$(mktemp "${TMPDIR:-/tmp}/mcap-asr-plist.XXXXXX")"; TMP_FILES+=("$TMP_PLIST")
render_plist > "$TMP_PLIST"
if grep -Eq '@[A-Z_]+@' "$TMP_PLIST"; then
    die "unreplaced placeholder left in the plist: $(grep -Eo '@[A-Z_]+@' "$TMP_PLIST" | sort -u | tr '\n' ' ')"
fi
plutil -lint "$TMP_PLIST" >/dev/null || { cat "$TMP_PLIST" >&2; die "the generated plist is not valid"; }
say "the rendered plist is valid (plutil -lint)"
if [ "$MODE" = dry ]; then
    say "would write it to $PLIST_PATH (root:wheel 0644). It reads:"
    echo "-----"
    cat "$TMP_PLIST"
    echo "-----"
else
    run mkdir -p "$(dirname "$DEST_PLIST")"
    no_symlink "$DEST_PLIST" "the LaunchDaemon plist"
    run cp "$TMP_PLIST" "$DEST_PLIST"
    run chmod -h 644 "$DEST_PLIST"
    priv chown -h root:wheel "$DEST_PLIST"
fi

# ---- 7. load -------------------------------------------------------------------------------------------------------------
step "7. loading"
# A server installed under another label (this script used another one before) keeps its daemon, its plist and its port. Found by the name
# of the plist, so no old label is spelled here; this only says so, it never boots out or removes anything.
for OLD_PLIST in "$(dirname "$PLIST_PATH")"/*mcap-asr*.plist; do
    { [ -e "$OLD_PLIST" ] && [ "$OLD_PLIST" != "$PLIST_PATH" ]; } || continue
    say "WARNING: $OLD_PLIST is another speech-server LaunchDaemon and keeps the port. Stop it by hand:  sudo launchctl bootout system/$(basename "$OLD_PLIST" .plist)  and remove that plist"
done
if [ "$LOAD" = 1 ]; then
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    run launchctl bootstrap system "$PLIST_PATH"
    run launchctl kickstart -k "system/$LABEL"
else
    say "not loaded. To start it (as root):  launchctl bootstrap system '$PLIST_PATH'     (stop: launchctl bootout system/$LABEL)"
fi

# ---- 8. what is left for you ----------------------------------------------------------------------------------------------
step "8. next steps (by hand)"
cat <<EOS
[install_server]   1. TLS for a non-loopback address: put tls.crt and tls.key into '$SUPPORT_DIR' (owner $SERVICE_USER, tls.key 0600),
[install_server]      set tls_cert / tls_key in $CONFIG. Give the policy's org_consents the sha256 of the CA file that signs tls.crt.
[install_server]   2. The model: put it into the Hugging Face cache of $SERVICE_USER (the server never downloads; HF_HUB_OFFLINE=1).
[install_server]   3. Self-check, as the service user:
[install_server]        sudo -u $SERVICE_USER env PYTHONPATH='$PROJECT_DIR/pipeline' '$SHOW_PYTHON' -m mcap.asr_server --config '$CONFIG' selfcheck
[install_server]      its build_sha256 line is the value for attest_build_sha256 in the organisation policy.
[install_server]   4. Enrollment codes (they are exchanged by the client for tokens; the code never goes into chat):
[install_server]        sudo -u $SERVICE_USER env PYTHONPATH='$PROJECT_DIR/pipeline' '$SHOW_PYTHON' -m mcap.asr_server --config '$CONFIG' enroll-code issue --user NAME
[install_server]   5. After a restart of a FileVault Mac nothing runs until it is unlocked: plan restarts with  sudo fdesetup authrestart
[install_server]   6. Quarterly:  ... -m mcap.asr_server --config '$CONFIG' audit --home '$HOME_DIR'     and daily:  ... audit --daily
EOS
if [ "$MODE" = dry ]; then
    echo
    say "DRY RUN finished: nothing was changed."
fi
