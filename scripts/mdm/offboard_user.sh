#!/bin/bash
# Offboarding of a person who leaves: cut the relay access now, and list what is left to do by hand. A PLAN unless --apply.
#
#   scripts/mdm/offboard_user.sh --user NAME [--apply]               one person
#   scripts/mdm/offboard_user.sh --allow-list FILE [--apply]         everybody who is NOT in the list of people who still work here
#
# What it does itself (on the ASR server Mac, as root; it starts the admin command as the service user mcap-asr with sudo -u, because the token
# table is a 0600 file of that user):
#   --user NAME        python -m mcap.asr_server token revoke --user NAME      effective at the next request of that person's token (no MDM wait)
#   --allow-list FILE  python -m mcap.asr_server token sync --allow-list FILE  disables every token of a user that is not in the file (one name per
#                      line, '#' comments; the file is the Workspace export of active accounts). The server refuses an EMPTY list. With --apply the
#                      script first shows the users it would disable (the server's own --dry-run) and asks you to type 'disable' (or --yes).
# Then it lists the other steps. They are not done by this script, because each needs a decision or an account of its own:
#   - the Anthropic Console key of that person, when the llm lane was open for them: revoke it in the Console (the recorded spend limit stays)
#   - the Google Workspace account: suspend it, sign the devices out (this also ends Drive access to the team drive)
#   - the Mac: return and wipe, or keep it under MDM; FileVault protects what is on it until then
#   - their local meeting data: the staging folders and the local archive (local-only meetings) of that Mac, and their copies on the shared drive.
#     NOTHING IS DELETED AUTOMATICALLY: the retention and deletion rules are the administrator's and legal's decision (docs/OPS_RUNBOOK.md). When it is decided,
#     one folder at a time:  mcap forget <folder> --yes     and on that Mac, as that user:  mcap asr-engines revoke --all --forget-secret --yes
#
# Options:
#   --user NAME          the person, as the relay knows the token (the name the enrollment code was issued for): one printable line, any characters
#                        (spaces and Korean are fine), no control characters, not starting with '-'
#   --allow-list FILE    see above (exclusive with --user)
#   --server-config FILE asr-server.json of the server (default /Library/Application Support/MeetingCapture-asr/asr-server.json)
#   --project DIR        the release the server runs (default /Library/Application Support/MeetingCapture/releases/current)
#   --server-python PATH python of the server venv (default <project>/venv/bin/python)
#   --service-user NAME  default mcap-asr
#   --apply              run the revocation (needs root; without it: a plan, nothing is run)
#   --yes                --allow-list with --apply: do not ask for the typed confirmation
#   -h, --help           this text
#
# Re-running is safe: a token that is revoked or disabled already is left as it is, and the command says how many it changed (0 is reported as
# a failure by the server's revoke: look at `token list` before you assume the person had no token).

set -euo pipefail

USER_NAME=""
ALLOW_LIST=""
SERVER_CONFIG="/Library/Application Support/MeetingCapture-asr/asr-server.json"
PROJECT="/Library/Application Support/MeetingCapture/releases/current"
SERVER_PYTHON=""
SERVICE_USER="mcap-asr"
APPLY=0
ASSUME_YES=0
DIED=0

log() { echo "[offboard] $*"; }
die() { DIED=1; echo "[offboard] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[offboard] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --user) [ $# -ge 2 ] || die "--user needs a name" 2; USER_NAME="$2"; shift ;;
        --allow-list) [ $# -ge 2 ] || die "--allow-list needs a file" 2; ALLOW_LIST="$2"; shift ;;
        --server-config) [ $# -ge 2 ] || die "--server-config needs a file" 2; SERVER_CONFIG="$2"; shift ;;
        --project) [ $# -ge 2 ] || die "--project needs a directory" 2; PROJECT="$2"; shift ;;
        --server-python) [ $# -ge 2 ] || die "--server-python needs a path" 2; SERVER_PYTHON="$2"; shift ;;
        --service-user) [ $# -ge 2 ] || die "--service-user needs a name" 2; SERVICE_USER="$2"; shift ;;
        --apply) APPLY=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

if [ -n "$USER_NAME" ] && [ -n "$ALLOW_LIST" ]; then die "--user and --allow-list exclude each other" 2; fi
if [ -z "$USER_NAME" ] && [ -z "$ALLOW_LIST" ]; then die "give --user NAME or --allow-list FILE (try --help)" 2; fi
# The relay takes any printable label for a person (enroll-code issue --user, token issue --user: a Korean name, "first last", an e-mail address), so
# this script takes any text that is one printable line: no control character (a tab or a line break included), valid UTF-8, no leading '-' (it
# would be read as an option), at least one character that is not a space. The name goes to the server as one argument, never through a shell.
valid_person_name() {
    local total printable
    [ -n "$1" ] && [ "${#1}" -le 200 ] || return 1
    case "$1" in -*) return 1 ;; esac
    printf '%s' "$1" | grep -q '[^[:space:]]' || return 1
    total="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
    printable="$(printf '%s' "$1" | LC_ALL=C tr -cd '\040-\176\200-\377' | wc -c | tr -d ' ')"
    [ "$total" = "$printable" ] || return 1
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}
if [ -n "$USER_NAME" ]; then
    valid_person_name "$USER_NAME" || die "--user looks wrong: it must be one printable line of at most 200 characters, not starting with '-' (a name as the relay knows it: 'Hong Gildong', 홍길동, alice@example.com)" 2
fi
if [ -n "$ALLOW_LIST" ]; then
    [ -f "$ALLOW_LIST" ] || die "--allow-list is not a file: $ALLOW_LIST" 2
    [ -n "$(sed -e 's/#.*$//' -e 's/[[:space:]]//g' "$ALLOW_LIST" | grep -v '^$' | head -n 1)" ] || die "the allow-list has no names: it would disable every user (the server refuses it too). Use --user for one person" 2
fi
printf '%s' "$SERVICE_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$' || die "--service-user must be lower-case letters, digits, - and _" 2
case "$PROJECT" in /*) ;; *) die "--project must be an absolute path" 2 ;; esac
case "$SERVER_CONFIG" in /*) ;; *) die "--server-config must be an absolute path" 2 ;; esac
[ -n "$SERVER_PYTHON" ] || SERVER_PYTHON="$PROJECT/venv/bin/python"

# The admin command, as an argument list (printed, and run through the service user).
admin() {  # admin <token subcommand words...>: prints the command line as it will be run
    local cmd=(env PYTHONPATH="$PROJECT/pipeline" PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 "$SERVER_PYTHON" -m mcap.asr_server --config "$SERVER_CONFIG" "$@")
    if [ "$(id -un)" = "$SERVICE_USER" ]; then printf ' %q' "${cmd[@]}"; else printf ' sudo -u %q' "$SERVICE_USER"; printf ' %q' "${cmd[@]}"; fi
    printf '\n'
}
run_admin() {
    local cmd=(env PYTHONPATH="$PROJECT/pipeline" PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 "$SERVER_PYTHON" -m mcap.asr_server --config "$SERVER_CONFIG" "$@")
    if [ "$(id -un)" = "$SERVICE_USER" ]; then "${cmd[@]}"; else sudo -u "$SERVICE_USER" "${cmd[@]}"; fi
}

if [ -n "$USER_NAME" ]; then WHO="$USER_NAME"; else WHO="everybody not in $ALLOW_LIST"; fi
if [ "$APPLY" = 1 ]; then log "APPLY: revoking the relay access of $WHO"; else log "PLAN for $WHO (nothing is run; add --apply on the server Mac, as root)"; fi

log "1. relay access (this script, on the ASR server Mac):"
if [ -n "$USER_NAME" ]; then
    log "     revoke:$(admin token revoke --user "$USER_NAME")"
else
    log "     look first:$(admin token sync --allow-list "$ALLOW_LIST" --dry-run)"
    log "     disable:$(admin token sync --allow-list "$ALLOW_LIST")"
fi
log "     check:$(admin token list)      (status revoked or disabled for that person; their enrollment code, if any, expires by itself in 10 minutes)"
log "2. by hand, because each needs an account or a decision of its own:"
log "     - Anthropic Console: revoke the API key of this person if the llm lane was open for them (their per-key spend limit goes with the key)"
log "     - Google Workspace: suspend the account and sign its devices out (this ends the team drive access too)"
log "     - the Mac: return and wipe it, or keep it under MDM; until then FileVault protects what is on it"
log "     - local meeting data of that Mac (sessions/, local-meetings/) and the copies on the shared drive: NOTHING is deleted automatically; retention and"
log "       deletion are the administrator's and legal's decision (docs/OPS_RUNBOOK.md). When it is decided, one folder at a time:  mcap forget <folder> --yes"
log "     - on that Mac, as that user, to remove consents and the stored relay token from the Keychain:  mcap asr-engines revoke --all --forget-secret --yes"

if [ "$APPLY" != 1 ]; then
    log "PLAN finished: nothing was run."
    exit 0
fi

# ---- apply: the revocation only ----------------------------------------------------------------------------------------------------------
if [ "$(id -u)" != 0 ] && [ "$(id -un)" != "$SERVICE_USER" ]; then
    die "--apply needs root (or the service user $SERVICE_USER): run it with sudo yourself on the server Mac. Nothing was changed."
fi
[ -x "$SERVER_PYTHON" ] || die "the server python is not executable: $SERVER_PYTHON (--server-python)"
if [ -n "$USER_NAME" ]; then
    run_admin token revoke --user "$USER_NAME"
else
    log "the users that would be disabled (the server's own dry run):"
    run_admin token sync --allow-list "$ALLOW_LIST" --dry-run
    if [ "$ASSUME_YES" != 1 ]; then
        [ -t 0 ] || die "--allow-list needs a terminal to ask for confirmation (or pass --yes). Nothing was changed."
        printf "Type 'disable' to disable these users: "
        read -r answer || answer=""
        [ "$answer" = "disable" ] || die "not confirmed. Nothing was changed."
    fi
    run_admin token sync --allow-list "$ALLOW_LIST"
fi
log "done. Check with the 'check' command above, then work through the list by hand."
