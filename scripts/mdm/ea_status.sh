#!/bin/bash
# MDM extension attribute: the content-free status of this Mac. `mcap status --write` run as the CONSOLE USER, printed as one line.
#
#   scripts/mdm/ea_status.sh [options]
#
# Why a wrapper: the status is about a user's setup (their config.env, their staging folder, their consents, their Keychain-free usage), but an
# MDM agent runs scripts as root, and root's home has none of that. So this script finds the user at the console and runs mcap status AS THAT
# USER (sudo -u <user> -H), writes the document to a private folder that only that user can write, reads it back with a size limit, checks that it
# is JSON and prints it on one line (as root it reads the file with the user's rights, never with root's). It never reads a meeting, a title, a path or a name: mcap status itself leaves them out, schema 1, at most
# 20 KB (asr_usage_7d and llm_cost_7d_usd are in it only when STATUS_INCLUDE_USAGE=1: default 0, device health only).
#
# Whatever happens it prints ONE valid JSON line and exits 0, so that the MDM never stores a half line or an error text as an attribute:
#   {"schema":1,"error":"no-console-user"}       nobody is logged in (the login window, or a root-only session)
#   {"schema":1,"error":"mcap-missing"}          /usr/local/bin/mcap (the company shim) is not there: the package is not installed or broke
#   {"schema":1,"error":"status-failed"}         mcap status exited with an error
#   {"schema":1,"error":"status-timeout"}        it ran for more than 60 seconds and was stopped
#   {"schema":1,"error":"status-unreadable"}     what it wrote is not JSON, or is larger than 24 KB
# The document of mcap status has no key named error, so the two cannot be confused. The same facts, as text, are in `mcap status` itself.
#
# Options:
#   --console-user NAME   the account to report on (default: the user at the console, from /dev/console)
#   --home DIR            its home directory (default: from the directory service)
#   --mcap PATH           the mcap to run (default /usr/local/bin/mcap)
#   --out FILE            ALSO write the line here as root (for an MDM agent that reads a file, for example
#                         "/Library/Application Support/MeetingCapture/status.json"), atomically, mode 0644
#   --format json|jamf    json = the line as it is (Intune custom attribute, most agents); jamf = wrapped in <result>...</result>
#   --timeout SECONDS     stop mcap status after this long (default 60) and report status-timeout
#   -h, --help            this text
#
# Run it as root (the MDM does) or as the console user itself (a test, support). As anyone else it refuses: it would report on another person's
# setup without being able to read it. Nothing here starts claude, reads a Keychain item or opens a socket.
# As root the private work folder is made under /private/var/tmp whatever TMPDIR says (the console user has to be able to reach it; MCAP_EA_TMPDIR
# overrides the place for tests); as the console user it is made under TMPDIR.

set -euo pipefail

MCAP="/usr/local/bin/mcap"
CONSOLE_USER=""
HOME_DIR=""
OUT_FILE=""
FORMAT="json"
TIMEOUT_S=60
MAX_BYTES=24576
WORK=""
DIED=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2).
on_exit() {
    local rc=$?
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[ea_status] aborted (exit code $rc)" >&2
    fi
    return 0
}
trap on_exit EXIT

die() { DIED=1; echo "[ea_status] ERROR: $1" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --console-user) [ $# -ge 2 ] || die "--console-user needs a name"; CONSOLE_USER="$2"; shift ;;
        --home) [ $# -ge 2 ] || die "--home needs a directory"; HOME_DIR="$2"; shift ;;
        --mcap) [ $# -ge 2 ] || die "--mcap needs a path"; MCAP="$2"; shift ;;
        --out) [ $# -ge 2 ] || die "--out needs a file"; OUT_FILE="$2"; shift ;;
        --format) [ $# -ge 2 ] || die "--format needs json or jamf"; FORMAT="$2"; shift ;;
        --timeout) [ $# -ge 2 ] || die "--timeout needs a number of seconds"; TIMEOUT_S="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
case "$FORMAT" in json|jamf) ;; *) die "--format must be json or jamf" ;; esac
printf '%s' "$TIMEOUT_S" | grep -Eq '^[0-9]{1,4}$' || die "--timeout must be a number of seconds"

emit() {  # $1 = one line of JSON: stdout (and --out)
    local line="$1"
    if [ -n "$OUT_FILE" ]; then
        printf '%s\n' "$line" > "$OUT_FILE.part" && chmod 644 "$OUT_FILE.part" && mv -f "$OUT_FILE.part" "$OUT_FILE" || echo "[ea_status] cannot write $OUT_FILE" >&2
    fi
    if [ "$FORMAT" = jamf ]; then printf '<result>%s</result>\n' "$line"; else printf '%s\n' "$line"; fi
}
fail_doc() { emit "{\"schema\":1,\"error\":\"$1\"}"; exit 0; }

# ---- who ---------------------------------------------------------------------------------------------------------------------------
if [ -z "$CONSOLE_USER" ]; then
    CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || true)"
fi
case "$CONSOLE_USER" in ""|root|loginwindow|_*) fail_doc "no-console-user" ;; esac
printf '%s' "$CONSOLE_USER" | grep -Eq '^[A-Za-z0-9._-]+$' || fail_doc "no-console-user"
USER_ID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
[ -n "$USER_ID" ] || fail_doc "no-console-user"
MY_ID="$(id -u)"
if [ "$MY_ID" != 0 ] && [ "$MY_ID" != "$USER_ID" ]; then
    die "run this as root (the MDM does) or as the console user $CONSOLE_USER: as another user it cannot read that user's setup"
fi
if [ -z "$HOME_DIR" ]; then
    if [ "$MY_ID" = "$USER_ID" ]; then
        HOME_DIR="$HOME"
    else
        HOME_DIR="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | sed -e '1s/^NFSHomeDirectory:[[:space:]]*//' -e 's/[[:space:]]*$//' | head -n 1 || true)"
    fi
fi
case "$HOME_DIR" in /*) ;; *) fail_doc "no-console-user" ;; esac
[ -x "$MCAP" ] || fail_doc "mcap-missing"

# ---- a private folder the user can write and nobody else can ----------------------------------------------------------------------------
if [ "$MY_ID" = 0 ]; then
    # NOT under TMPDIR: an MDM agent that runs as root often has root's own per-user temp folder there (mode 0700), which the console user cannot
    # get through to reach a folder inside it, so mcap status --write would fail and every Mac would report status-failed. /private/var/tmp is
    # searchable by everybody. MCAP_EA_TMPDIR names another such folder (tests).
    WORK="$(mktemp -d "${MCAP_EA_TMPDIR:-/private/var/tmp}/mcap-ea.XXXXXX")"
    chown "$USER_ID" "$WORK"
else
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-ea.XXXXXX")"
fi
chmod 700 "$WORK"
STATUS_FILE="$WORK/status.json"

# ---- run it as the user, with a clean environment and a watchdog ------------------------------------------------------------------------
if [ "$MY_ID" = 0 ]; then
    sudo -u "$CONSOLE_USER" -H /usr/bin/env -i HOME="$HOME_DIR" USER="$CONSOLE_USER" LOGNAME="$CONSOLE_USER" LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        "$MCAP" status --write "$STATUS_FILE" >/dev/null 2>&1 &
else
    /usr/bin/env -i HOME="$HOME_DIR" USER="$CONSOLE_USER" LOGNAME="$CONSOLE_USER" LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        "$MCAP" status --write "$STATUS_FILE" >/dev/null 2>&1 &
fi
PID=$!
waited=0
while kill -0 "$PID" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_S" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        fail_doc "status-timeout"
    fi
    sleep 1
    waited=$((waited + 1))
done
rc=0
wait "$PID" || rc=$?
[ "$rc" = 0 ] || fail_doc "status-failed"

# ---- read it back: bounded, valid JSON, one line ---------------------------------------------------------------------------------------------------
# As root the file is read WITH THE USER'S OWN RIGHTS (sudo -u <user> head -c): the folder belongs to the user, so a link put in place of the file could
# otherwise make root read something that only root may read. Root only handles the (size-limited) bytes that come back.
read_status() {
    if [ "$MY_ID" = 0 ]; then
        sudo -u "$CONSOLE_USER" -H /usr/bin/head -c "$((MAX_BYTES + 1))" "$STATUS_FILE" 2>/dev/null
    else
        /usr/bin/head -c "$((MAX_BYTES + 1))" "$STATUS_FILE" 2>/dev/null
    fi
}
SIZE="$(read_status | wc -c | tr -d ' ' || true)"
[ -n "$SIZE" ] && [ "$SIZE" -gt 0 ] && [ "$SIZE" -le "$MAX_BYTES" ] || fail_doc "status-unreadable"
LINE="$(read_status | plutil -convert json -o - - 2>/dev/null | tr -d '\n' || true)"
case "$LINE" in "{"*"}") ;; *) fail_doc "status-unreadable" ;; esac
emit "$LINE"
