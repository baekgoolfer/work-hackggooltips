#!/bin/bash
# Remove the app (CATE, "Catch Everything", unless you chose other names): stop the LaunchAgent, delete its plist and the app. Your data is KEPT unless --purge.
#
#   scripts/uninstall.sh [options]
#
#   1. unloads the LaunchAgent (launchctl bootout) and deletes ~/Library/LaunchAgents/<bundle id>.plist (the bundle id is the CFBundleIdentifier of the
#      installed app, else MCAP_BUNDLE_ID, else org.meetingcapture.app: if you removed the app by hand first, set MCAP_BUNDLE_ID to the id you built it with)
#   2. deletes ~/Applications/<short name>.app (CATE.app unless MCAP_APP_SHORT_NAME says otherwise: set it to the name you built with when it was not the
#      default). Another app in ~/Applications with the SAME bundle id under another file name (an older build) is not deleted by guess: it is named, with the way
#      to remove it
#      (and the live-test confirmation marker SUPPORT_DIR/live-tested.confirmed: a reinstall has to be confirmed again,
#      see make confirm-live-tested; the permissions of a new build may have to be granted again)
#   3. keeps SUPPORT_DIR (config.env, vocabulary.txt, note_prompt.md, sessions/, venv/, bench-venv/, models/) and LOG_DIR
#
# With --company it removes the COMPANY install INSTEAD (what the package put on the Mac): the system-wide LaunchAgent
# /Library/LaunchAgents/<bundle id>.plist (booted out for the logged-in user first), /Applications/<short name>.app, the shim
# /usr/local/bin/mcap (only when it is the shim of this install), and under /Library/Application Support/MeetingCapture: releases/ (every runtime
# release), tools/ and release-signing.pub.pem. It needs root (run it with sudo yourself). The bundle id and the app file name of that install are what
# the package recorded in tools/ (RELEASE_BUNDLE_ID, RELEASE_APP_SHORT_NAME; sudo does not pass your environment on, so MCAP_BUNDLE_ID and
# MCAP_APP_SHORT_NAME cannot be counted on); a package of an earlier version recorded nothing: then the app in /Applications that has the id (MCAP_BUNDLE_ID,
# else the default) is the one, and when neither the app nor the agent can be found the script stops before it deletes anything: it never says "done" about
# nothing. KEPT, always: policy.json and policy.required (MDM owns
# them: a Mac whose app is gone stays a Mac with a policy), every user's data (SUPPORT_DIR, LOG_DIR, local-meetings, sessions/, the Keychain items)
# and ARCHIVE_DIR. To remove the policy files too, the MDM removes them.
# --company leaves the PERSONAL install (steps 1 and 2: the per-user LaunchAgent, ~/Applications/<short name>.app, the live-test marker) alone: sudo
# keeps your HOME, and a rollback (scripts/migrate_owner_install.sh --rollback) has just put exactly those back. --also-personal removes them too.
# Order of a rollback to the personal install: THIS (--company) FIRST, then migrate_owner_install.sh --rollback: the company LaunchAgent has the same
# label as the personal one (when both are built with the same bundle id), so removing it boots out whichever agent is loaded (docs/MIGRATION.md 7).
#
# Options:
#   --purge     ALSO delete SUPPORT_DIR (incl. sessions/ = recordings that were not published yet, the venvs and
#               models) and LOG_DIR. With --purge nothing at all is changed until you have typed 'purge' (or passed
#               --yes): the question comes first, so a refused or non-interactive --purge leaves everything as it was.
#   --yes       do not ask (only used with --purge)
#   --company   remove the company install (see above; needs root); the personal install is left alone
#   --also-personal  with --company: remove the personal install as well (steps 1 and 2)
#   --dry-run   print every action, change nothing
#   -h, --help  this text
#
# Never touched: ARCHIVE_DIR (your meetings on Google Drive), the Hugging Face model cache (~/.cache/huggingface),
# this repository, the fixed signing identity (scripts/make_signing_identity.sh --help says how to remove it), and the
# macOS privacy permissions (see the hint printed at the end).
#
# Environment overrides (tests): MCAP_SUPPORT_DIR, MCAP_LOG_DIR, MCAP_SYSTEM_ROOT (a prefix for the /Applications, /Library and /usr/local paths of
# --company: a staged tree instead of the real system; then root is not needed and launchd is not touched).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
SUPPORT_DIR="${MCAP_SUPPORT_DIR:-$HOME/Library/Application Support/MeetingCapture}"
LOG_DIR="${MCAP_LOG_DIR:-$HOME/Library/Logs/MeetingCapture}"
APP_SHORT_NAME=""
APP_NAME=""
APP_PATH=""
LIVE_MARKER="$SUPPORT_DIR/live-tested.confirmed"

DRY_RUN=0
PURGE=0
ASSUME_YES=0
COMPANY=0
ALSO_PERSONAL=0
DIED=0
SYSTEM_ROOT="${MCAP_SYSTEM_ROOT:-}"
SYS_SUPPORT="$SYSTEM_ROOT/Library/Application Support/MeetingCapture"
SYS_APP=""
SYS_SHIM="$SYSTEM_ROOT/usr/local/bin/mcap"

# One line of what the company package recorded in tools/ (scripts/pkg/postinstall); empty when there is no record (a package of an earlier version).
sys_record() { { tr -d '[:space:]' < "$SYS_SUPPORT/tools/$1"; } 2>/dev/null || true; }

log()  { echo "[uninstall] $*"; }
die()  { DIED=1; echo "[uninstall] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[uninstall] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --yes) ASSUME_YES=1 ;;
        --company) COMPANY=1 ;;
        --also-personal) ALSO_PERSONAL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# Deletes a path only when it is absolute, not a dangerous location and has the expected name.
safe_rm() {  # $1 = path, $2 = required basename
    local path="$1" want="$2"
    case "$path" in
        /*) ;;
        *) die "refusing to delete a relative path: '$path'" ;;
    esac
    [ "$path" != "/" ] && [ "$path" != "$HOME" ] && [ "$(basename "$path")" = "$want" ] || die "refusing to delete '$path' (expected a path ending in /$want)"
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would delete $path"
    else
        rm -rf "$path"
        log "deleted $path"
    fi
}

size_of() { du -sh "$1" 2>/dev/null | awk '{ print $1 }'; }

# Recordings that were never published: staging folders that still have a session.json. Not counted: the _discarded
# housekeeping folder (and any other name starting with _) and the tombstones of published meetings (state.json only).
unpublished_sessions() {
    local d
    [ -d "$SUPPORT_DIR/sessions" ] || return 0
    for d in "$SUPPORT_DIR/sessions"/*/; do
        [ -d "$d" ] || continue
        case "$(basename "$d")" in _*) continue ;; esac
        [ -f "${d}session.json" ] || continue
        basename "$d"
    done
}

[ "$ALSO_PERSONAL" != 1 ] || [ "$COMPANY" = 1 ] || die "--also-personal goes with --company (without --company the personal install is removed anyway)"
# The file name of the app comes from MCAP_APP_SHORT_NAME, else the default (the same rule as the build); the app that is there tells its own human name.
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above). Nothing was changed."
APP_PATH="$HOME/Applications/$APP_SHORT_NAME.app"
# The company install is named by the record the package left, then by the environment, then by the defaults.
SYS_SHORT_NAME="$APP_SHORT_NAME"
SYS_RECORDED_ID=""
if [ "$COMPANY" = 1 ]; then
    recorded="$(sys_record RELEASE_APP_SHORT_NAME)"
    if mcap_valid_app_short_name "$recorded"; then SYS_SHORT_NAME="$recorded"; fi
    recorded="$(sys_record RELEASE_BUNDLE_ID)"
    if mcap_valid_bundle_id "$recorded"; then SYS_RECORDED_ID="$recorded"; fi
fi
SYS_APP="$SYSTEM_ROOT/Applications/$SYS_SHORT_NAME.app"
APP_NAME="$(mcap_resolve_app_name "$APP_PATH" "$SYS_APP" 2>/dev/null)" || APP_NAME="$MCAP_DEFAULT_APP_NAME"
# The bundle ids, read BEFORE anything is deleted (the app is what names them). They name the LaunchAgent plists and the launchctl label.
BUNDLE_ID="$(mcap_resolve_bundle_id "$APP_PATH")" || die "the bundle identifier is refused (see above). Nothing was changed."
PLIST_PATH="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SYS_BUNDLE_ID="$(MCAP_BUNDLE_ID="${SYS_RECORDED_ID:-${MCAP_BUNDLE_ID:-}}" mcap_resolve_bundle_id "$SYS_APP")" || die "the bundle identifier is refused (see above). Nothing was changed."
SYS_AGENT="$SYSTEM_ROOT/Library/LaunchAgents/$SYS_BUNDLE_ID.plist"
if [ "$COMPANY" = 1 ] && [ ! -e "$SYS_APP" ]; then       # no record and another file name than the one asked for (an earlier package): the app that has the id is the app
    SYS_SAME_ID="$(mcap_apps_with_bundle_id "$SYSTEM_ROOT/Applications" "$SYS_BUNDLE_ID")"
    if [ "$(printf '%s' "$SYS_SAME_ID" | grep -c .)" = 1 ]; then SYS_APP="$SYS_SAME_ID"; fi
fi
PERSONAL=1            # the per-user LaunchAgent, ~/Applications/<short name>.app and the live-test marker: removed unless --company stands alone
if [ "$COMPANY" = 1 ] && [ "$ALSO_PERSONAL" != 1 ]; then PERSONAL=0; fi

[ "$DRY_RUN" != 1 ] || log "dry run: nothing is stopped or deleted"
if [ "$COMPANY" = 1 ] && [ -z "$SYSTEM_ROOT" ] && [ "$DRY_RUN" != 1 ] && [ "$(id -u)" != 0 ]; then
    die "--company removes system folders: run it with sudo yourself. Nothing was changed."
fi
# A runtime is here but neither its app nor its agent can be found under the names looked for: the names are wrong. Deleting releases/ and tools/ now would leave the
# app and its root-run agent on the Mac without their runtime, so nothing is deleted.
if [ "$COMPANY" = 1 ] && [ ! -e "$SYS_APP" ] && [ ! -e "$SYS_AGENT" ] && { [ -e "$SYS_SUPPORT/releases" ] || [ -e "$SYS_SUPPORT/tools" ]; }; then
    if [ -n "$SYS_RECORDED_ID" ]; then SYS_NAMES_FROM="the record of the package"; else SYS_NAMES_FROM="MCAP_BUNDLE_ID and MCAP_APP_SHORT_NAME or the defaults (sudo does not pass your environment on)"; fi
    die "the company runtime is in $SYS_SUPPORT, but there is no app at $SYS_APP and no LaunchAgent at $SYS_AGENT (bundle id $SYS_BUNDLE_ID and app file $SYS_SHORT_NAME.app, from $SYS_NAMES_FROM). The install uses other names. Nothing was changed. Give them:  sudo env MCAP_BUNDLE_ID=<the id> MCAP_APP_SHORT_NAME=<the file name of the app, without .app> scripts/uninstall.sh --company"
fi

# ---- plan, and the confirmation for --purge BEFORE anything is changed ----------------------------------------------------
if [ "$PURGE" = 1 ]; then
    UNPUBLISHED="$(unpublished_sessions)"
    N_UNPUBLISHED="$(printf '%s' "$UNPUBLISHED" | grep -c . || true)"
    if [ "$PERSONAL" = 1 ]; then echo "--purge will delete (after the LaunchAgent and the app are removed):"; else echo "--purge will delete (the personal app and LaunchAgent are left alone: --also-personal):"; fi
    [ ! -d "$SUPPORT_DIR" ] || echo "    $SUPPORT_DIR ($(size_of "$SUPPORT_DIR"): config, venv, bench-venv, models, $N_UNPUBLISHED unpublished session folder(s) with recordings)"
    [ ! -d "$LOG_DIR" ] || echo "    $LOG_DIR ($(size_of "$LOG_DIR"))"
    if [ "$N_UNPUBLISHED" -gt 0 ]; then
        echo "  Unpublished recordings that would be lost (audio that was never turned into a transcript in ARCHIVE_DIR):"
        printf '%s\n' "$UNPUBLISHED" | head -n 10 | sed 's/^/      /'
        [ "$N_UNPUBLISHED" -le 10 ] || echo "      ... and $((N_UNPUBLISHED - 10)) more"
    fi
    echo "It will NOT delete the published meetings in ARCHIVE_DIR (Google Drive)."
    if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
        [ -t 0 ] || die "--purge needs a terminal to ask for confirmation (or pass --yes). Nothing was changed: the LaunchAgent, the app and your data are all still there."
        printf "Type 'purge' to delete them: "
        read -r answer || answer=""
        [ "$answer" = "purge" ] || die "not confirmed. Nothing was changed: the LaunchAgent, the app and your data are all still there."
    fi
fi

personal_install() {
    # ---- 1. LaunchAgent -----------------------------------------------------------------------------------------
    echo "== LaunchAgent"
    if [ "$DRY_RUN" = 1 ]; then
        "$SCRIPT_DIR/make_launchagent.sh" --unload --dry-run
    else
        "$SCRIPT_DIR/make_launchagent.sh" --unload
    fi
    if [ -e "$PLIST_PATH" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            echo "[dry-run] would delete $PLIST_PATH"
        else
            rm -f "$PLIST_PATH"
            log "deleted $PLIST_PATH"
        fi
    else
        log "no plist at $PLIST_PATH"
    fi

    # The confirmation belongs to the installed app and its permissions: a reinstall must be confirmed again.
    if [ -e "$LIVE_MARKER" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            echo "[dry-run] would delete $LIVE_MARKER (the live-test confirmation)"
        else
            rm -f "$LIVE_MARKER"
            log "deleted the live-test confirmation $LIVE_MARKER (a reinstall has to be confirmed again: make confirm-live-tested)"
        fi
    fi

    # ---- 2. app -------------------------------------------------------------------------------------------------
    echo "== app"
    if [ "$DRY_RUN" != 1 ] && pgrep -f "$APP_PATH/Contents/MacOS/$APP_SHORT_NAME" >/dev/null 2>&1; then
        sleep 2
        if pgrep -f "$APP_PATH/Contents/MacOS/$APP_SHORT_NAME" >/dev/null 2>&1; then
            log "WARNING: $APP_NAME is still running. Quit it from the menu bar (a recording in progress is saved when you quit)."
        fi
    fi
    if [ -e "$APP_PATH" ]; then
        safe_rm "$APP_PATH" "$APP_SHORT_NAME.app"
    else
        log "no app at $APP_PATH"
    fi
    # an older build under another file name has the same bundle id: it is not ours to delete by guess, so it is named
    while IFS= read -r other_app; do
        [ -n "$other_app" ] && [ "$other_app" != "$APP_PATH" ] || continue
        log "NOTE: $other_app has the same bundle id ($BUNDLE_ID) under another file name (an older build?). It was NOT removed: delete it yourself, or run this again with MCAP_APP_SHORT_NAME=$(basename "$other_app" .app)"
    done <<< "$(mcap_apps_with_bundle_id "$HOME/Applications" "$BUNDLE_ID")"
}

if [ "$PERSONAL" = 1 ]; then
    personal_install
else
    echo "== personal install"
    if [ -e "$APP_PATH" ] || [ -e "$PLIST_PATH" ] || [ -e "$LIVE_MARKER" ]; then
        log "left alone (--company removes the company install only): $APP_PATH, $PLIST_PATH and the live-test confirmation. --also-personal removes them too."
    else
        log "no personal install here (no app at $APP_PATH, no plist at $PLIST_PATH)"
    fi
fi

# ---- 2b. the company install (--company) ---------------------------------------------------------------------------------------
if [ "$COMPANY" = 1 ]; then
    echo "== company install"
    if [ -z "$SYSTEM_ROOT" ] && [ "$DRY_RUN" != 1 ]; then
        CONSOLE_UID="$(stat -f %u /dev/console 2>/dev/null || true)"
        if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != 0 ]; then
            if launchctl bootout "gui/$CONSOLE_UID/$SYS_BUNDLE_ID" 2>/dev/null; then
                log "booted the system LaunchAgent out for the logged-in user (the app was asked to quit)"
            else
                log "the system LaunchAgent was not loaded for the logged-in user"
            fi
        fi
    elif [ -n "$SYSTEM_ROOT" ]; then
        log "(staged tree $SYSTEM_ROOT: launchd is not touched)"
    else
        echo "[dry-run] would boot the system LaunchAgent out for the logged-in user"
    fi
    if [ -e "$SYS_AGENT" ]; then
        if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would delete $SYS_AGENT"; else rm -f "$SYS_AGENT"; log "deleted $SYS_AGENT"; fi
    else
        log "no system LaunchAgent at $SYS_AGENT"
    fi
    if [ "$DRY_RUN" != 1 ] && pgrep -f "$SYS_APP/Contents/MacOS/" >/dev/null 2>&1; then
        log "WARNING: the company app is still running. It keeps running until it quits; its files are removed now."
    fi
    if [ -e "$SYS_APP" ]; then safe_rm "$SYS_APP" "$(basename "$SYS_APP")"; else log "no app at $SYS_APP"; fi
    # another app with the same bundle id under another file name (an older package): not deleted by guess, as for the personal install
    while IFS= read -r other_app; do
        [ -n "$other_app" ] && [ "$other_app" != "$SYS_APP" ] || continue
        log "NOTE: $other_app has the same bundle id ($SYS_BUNDLE_ID) under another file name (an older package?). It was NOT removed: delete it yourself."
    done <<< "$(mcap_apps_with_bundle_id "$SYSTEM_ROOT/Applications" "$SYS_BUNDLE_ID")"
    if [ -f "$SYS_SHIM" ] && grep -q 'shim of the MeetingCapture company install' "$SYS_SHIM" 2>/dev/null; then
        if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would delete $SYS_SHIM"; else rm -f "$SYS_SHIM"; log "deleted $SYS_SHIM"; fi
    elif [ -e "$SYS_SHIM" ]; then
        log "$SYS_SHIM is not the shim of this install: left alone"
    fi
    for sub_path in releases tools; do
        if [ -e "$SYS_SUPPORT/$sub_path" ]; then safe_rm "$SYS_SUPPORT/$sub_path" "$sub_path"; fi
    done
    if [ -e "$SYS_SUPPORT/release-signing.pub.pem" ]; then
        if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would delete $SYS_SUPPORT/release-signing.pub.pem"; else rm -f "$SYS_SUPPORT/release-signing.pub.pem"; log "deleted the release public key"; fi
    fi
    if [ -e "$SYS_SUPPORT/policy.json" ] || [ -e "$SYS_SUPPORT/policy.required" ]; then
        log "kept $SYS_SUPPORT/policy.json and policy.required: MDM owns the policy (a Mac without the app still has its policy). User data is kept as well."
    fi
fi

# ---- 3. data ------------------------------------------------------------------------------------------------
echo "== your data"
if [ "$PURGE" != 1 ]; then
    [ ! -d "$SUPPORT_DIR" ] || log "kept $SUPPORT_DIR ($(size_of "$SUPPORT_DIR")): config.env, vocabulary.txt, note_prompt.md, sessions/, venv/, bench-venv/, models/"
    [ ! -d "$LOG_DIR" ] || log "kept $LOG_DIR ($(size_of "$LOG_DIR"))"
    log "to delete them as well: scripts/uninstall.sh --purge"
else
    [ ! -d "$SUPPORT_DIR" ] || safe_rm "$SUPPORT_DIR" "MeetingCapture"
    [ ! -d "$LOG_DIR" ] || safe_rm "$LOG_DIR" "MeetingCapture"
fi

echo
log "done."
echo "Left for you to decide:"
echo "  - macOS permissions (Microphone, System Audio Recording, Notifications; Automation if you enabled Meet) stay listed in System Settings."
if [ "$COMPANY" = 1 ] && [ "$PERSONAL" != 1 ]; then TCC_IDS="$SYS_BUNDLE_ID"
elif [ "$COMPANY" = 1 ] && [ "$SYS_BUNDLE_ID" != "$BUNDLE_ID" ]; then TCC_IDS="$BUNDLE_ID $SYS_BUNDLE_ID"
else TCC_IDS="$BUNDLE_ID"; fi
for id in $TCC_IDS; do echo "    To drop them yourself:  tccutil reset All $id"; done
echo "  - the fixed signing identity 'MeetingCapture Local Signing' (if you created it) stays in your login keychain:"
echo "    security delete-identity -c \"MeetingCapture Local Signing\" -t ~/Library/Keychains/login.keychain-db"
echo "  - the downloaded ASR models (about 3 GB) are in ~/.cache/huggingface/hub (shared with other tools):"
echo "    rm -rf ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-mlx"
echo "  - this repository and build/ (make clean)."
[ "$COMPANY" != 1 ] || echo "  - the policy files in /Library/Application Support/MeetingCapture (kept; the MDM removes them) and every user's data under ~/Library (kept)."
[ "$DRY_RUN" != 1 ] || log "(dry run: nothing was changed)"
exit 0
