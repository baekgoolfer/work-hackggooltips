#!/bin/bash
# Write the LaunchAgent plist that starts the app (<short name>.app, CATE.app by default) at login, and optionally (un)load it.
#
#   scripts/make_launchagent.sh [options]
#
#   (no option)        write ~/Library/LaunchAgents/<bundle id>.plist and check it with plutil -lint. The label is the bundle id: the
#                      CFBundleIdentifier of the app (--app), else MCAP_BUNDLE_ID, else org.meetingcapture.app (scripts/bundle_id.sh).
#                      Nothing is loaded: the agent starts at the next login (or use --load).
#   --load             after writing, load it now:  launchctl bootstrap gui/$UID <plist>  (an already loaded copy is
#                      booted out first, so this also applies a changed plist). Starts the app immediately.
#   --unload           stop and unload the agent:  launchctl bootout gui/$UID/<bundle id>
#                      (the plist file stays; scripts/uninstall.sh removes it). Writes nothing.
#   --confirm-live-tested
#                      YOU run this (make confirm-live-tested) after `setup` showed no [FAIL] and `selftest-capture --live`
#                      said PASS. It prints the recording legal notice, asks you to type yes, then to type 'confirmed', and then
#                      writes the marker file SUPPORT_DIR/live-tested.confirmed that unlocks writing / loading the LaunchAgent.
#                      It needs a terminal.
#   --accept-legal-notice
#                      only with --confirm-live-tested: counts the legal notice as accepted without the yes question. The typed
#                      'confirmed' still needs a terminal; there is no way around that.
#   --app PATH         app bundle to run (default ~/Applications/<short name>.app: MCAP_APP_SHORT_NAME, else CATE; scripts/bundle_id.sh). When that
#                      app is not there and exactly one other app in ~/Applications has the bundle id (MCAP_BUNDLE_ID, else the default: an older
#                      build under another file name; one id is one login agent), that app is the one.
#   --out PATH         plist path (default ~/Library/LaunchAgents/<bundle id>.plist)
#   --env KEY=VALUE    add an environment variable to the agent (repeatable). Normally not needed; example for a
#                      live-test escape hatch: --env MC_TAP_HOST=default
#   --dry-run          render and lint the plist in a temp file, print it and the launchctl command, change nothing
#   -h, --help         this text
#
# PREREQUISITE for writing or loading the plist (not for --unload): the marker above. A written plist starts the app at
# the next login, and from then on it records every Zoom / Teams call and every call of the other call apps of the
# built-in table (Slack huddles, FaceTime, WhatsApp, ...: CALL_DETECT in config.env), so it must not exist before you have
# seen the permissions and the device test work (docs/LIVE_TEST.md). There is no bypass option: the marker is a plain file, creating
# it is a deliberate act of yours (make confirm-live-tested).
#
# launchd settings: RunAtLoad, KeepAlive {SuccessfulExit: false} (a crash is restarted after ThrottleInterval 30 s, a normal
# Quit from the menu is not), LimitLoadToSessionType Aqua (only in the GUI login session), ProcessType Interactive.
# launchctl is only ever called with --load or --unload.
#
# Environment overrides: MCAP_LOG_DIR (default ~/Library/Logs/MeetingCapture), MCAP_SUPPORT_DIR (default
# ~/Library/Application Support/MeetingCapture; where the marker lives).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=legal_notice.sh
. "$SCRIPT_DIR/legal_notice.sh"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
APP_PATH=""               # default below: ~/Applications/<short name>.app (--app overrides it)
PLIST_PATH=""             # default below: ~/Library/LaunchAgents/<label>.plist, once the app (and so its bundle id) is known
LOG_DIR="${MCAP_LOG_DIR:-$HOME/Library/Logs/MeetingCapture}"
SUPPORT_DIR="${MCAP_SUPPORT_DIR:-$HOME/Library/Application Support/MeetingCapture}"
MARKER="$SUPPORT_DIR/live-tested.confirmed"
DRY_RUN=0
ACCEPT_LEGAL=0
ACTION="write"          # write | load | unload | confirm | check
ENV_KEYS=()
ENV_VALUES=()
TMP_PLIST=""

DIED=0
log() { echo "[make_launchagent] $*"; }
die() { DIED=1; echo "[make_launchagent] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    [ -z "$TMP_PLIST" ] || rm -f "$TMP_PLIST"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[make_launchagent] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --load) case "$ACTION" in write|load) ACTION=load ;; *) die "--load cannot be combined with --$ACTION" ;; esac ;;
        --unload) case "$ACTION" in write|unload) ACTION=unload ;; *) die "--unload cannot be combined with --$ACTION" ;; esac ;;
        --confirm-live-tested) case "$ACTION" in write|confirm) ACTION=confirm ;; *) die "--confirm-live-tested cannot be combined with --$ACTION" ;; esac ;;
        --check-live-tested) ACTION=check ;;
        --app) [ $# -ge 2 ] || die "--app needs a path"; APP_PATH="$2"; shift ;;
        --out) [ $# -ge 2 ] || die "--out needs a path"; PLIST_PATH="$2"; shift ;;
        --env)
            [ $# -ge 2 ] || die "--env needs KEY=VALUE"
            case "$2" in
                [A-Za-z_]*=*) ;;
                *) die "--env expects KEY=VALUE, got '$2'" ;;
            esac
            ENV_KEYS+=("${2%%=*}")
            ENV_VALUES+=("${2#*=}")
            shift ;;
        --dry-run) DRY_RUN=1 ;;
        --accept-legal-notice) ACCEPT_LEGAL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

if [ -z "$APP_PATH" ]; then
    APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above)"
    APP_PATH="$HOME/Applications/$APP_SHORT_NAME.app"
    if [ ! -d "$APP_PATH" ]; then
        WANT_ID="$(mcap_resolve_bundle_id)" || die "the bundle identifier is refused (see above)"
        SAME_ID_APPS="$(mcap_apps_with_bundle_id "$HOME/Applications" "$WANT_ID")"
        if [ "$(printf '%s' "$SAME_ID_APPS" | grep -c .)" = 1 ]; then
            log "$APP_PATH does not exist; $SAME_ID_APPS has the bundle id $WANT_ID, so that is the app"
            APP_PATH="$SAME_ID_APPS"
        fi
    fi
fi
# the app tells its own names (its executable is what the agent starts), else MCAP_APP_NAME / MCAP_APP_SHORT_NAME, else the defaults
APP_SHORT_NAME="$(mcap_resolve_app_short_name "$APP_PATH")" || die "the short app name is refused (see above)"
APP_NAME="$(mcap_resolve_app_name "$APP_PATH")" || die "the app name is refused (see above)"
LABEL="$(mcap_resolve_bundle_id "$APP_PATH")" || die "the bundle identifier is refused (see above)"
[ -n "$PLIST_PATH" ] || PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
APP_BIN="$APP_PATH/Contents/MacOS/$APP_SHORT_NAME"
APP_SHOW="$APP_PATH"       # as printed in the commands below: a path under HOME is shown as "$HOME/..." (the shell expands it)
case "$APP_PATH" in "$HOME"/*) APP_SHOW='$HOME'"${APP_PATH#"$HOME"}" ;; esac

# ---- the live-test gate: marker file written by --confirm-live-tested ---------------------------------------------
print_prerequisite() {
    cat <<EOF
[make_launchagent] The live test has not been confirmed yet, so the LaunchAgent is not written or loaded
[make_launchagent] (a written plist starts the app at the next login, and from then on it records every call).
[make_launchagent] Do these first, on this Mac (the whole checklist with expected results: docs/LIVE_TEST.md):
[make_launchagent]   1. permissions:  open -n -W -a "$APP_SHOW" --stdout "\$(tty)" --stderr "\$(tty)" --args setup
[make_launchagent]                    (no [FAIL] line)
[make_launchagent]   2. device test:  open -n -W -a "$APP_SHOW" --stdout "\$(tty)" --stderr "\$(tty)" --args selftest-capture --live --seconds 12 --out "\$HOME/mcap-selftest"
[make_launchagent]                    (verdict PASS)
[make_launchagent]   3. solo test calls with the app started by hand (Zoom, then Teams): docs/LIVE_TEST.md sections 4 and 5
[make_launchagent]   4. then confirm it yourself:  make confirm-live-tested    (asks you to type 'confirmed'; marker: $MARKER)
[make_launchagent] and run this script again.
EOF
}

# ---- --check-live-tested (used by install.sh): exit status only -----------------------------------------------------
if [ "$ACTION" = check ]; then
    if [ -f "$MARKER" ]; then exit 0; else exit 1; fi
fi

# ---- --confirm-live-tested: a deliberate act of the user ---------------------------------------------------------------
if [ "$ACTION" = confirm ]; then
    case "$APP_PATH" in
        /*) ;;
        *) die "--app must be an absolute path (got '$APP_PATH')" ;;
    esac
    REPORT="$LOG_DIR/setup-report.txt"
    [ -x "$APP_BIN" ] || die "$APP_BIN does not exist or is not executable (run scripts/install.sh first; an app installed under another file name: set MCAP_APP_SHORT_NAME to it, or pass --app)"
    [ -f "$REPORT" ] || die "there is no $REPORT: run the permission step first, it writes this report:  open -n -W -a \"$APP_SHOW\" --stdout \"\$(tty)\" --stderr \"\$(tty)\" --args setup"
    FAILS="$({ grep -F '[FAIL]' "$REPORT" || true; })"
    if [ -n "$FAILS" ]; then
        echo "[make_launchagent] the setup report ($REPORT) still has failures:" >&2
        printf '%s\n' "$FAILS" | sed 's/^/    /' >&2
        die "fix them, run setup again until it shows no [FAIL], then confirm. Nothing was written."
    fi
    WARNS="$({ grep -F '[WARN]' "$REPORT" || true; })"
    log "setup report: $REPORT"
    if [ -n "$WARNS" ]; then
        log "it has warnings (read them; you decide):"
        printf '%s\n' "$WARNS" | sed 's/^/    /'
    else
        log "it has no [FAIL] and no [WARN] line"
    fi
    echo "You are about to record that YOU, on this Mac and with the installed build of the app, have seen:"
    echo "  1. 'setup' finish without [FAIL] (the report above)"
    echo "  2. 'selftest-capture --live' print verdict PASS (remote_peak_window_db above -50) in every audio setup you use"
    echo "Loading the LaunchAgent makes the app record every Zoom / Teams call from every login on, and every call of the other call apps of the built-in table"
    echo "(Slack huddles, Webex, Discord, FaceTime, KakaoTalk, WhatsApp, ...: CALL_DETECT=known is the default, CALL_DETECT=off switches them off, CALL_DETECT=generic would also guess"
    echo "apps nobody named). Google Meet only if you enabled it."
    if [ "$DRY_RUN" = 1 ]; then
        legal_notice_gate "make_launchagent" "$ACCEPT_LEGAL" 1 "$APP_NAME"
        log "[dry-run] would ask you to type 'confirmed' and then write $MARKER"
        exit 0
    fi
    [ -t 0 ] || die "this is a deliberate step for you and needs a terminal to ask. Nothing was written."
    legal_notice_gate "make_launchagent" "$ACCEPT_LEGAL" 0 "$APP_NAME" || die "the recording legal notice was not accepted. Nothing was written."
    printf "Type 'confirmed' to record this: "
    read -r ANSWER || ANSWER=""
    [ "$ANSWER" = "confirmed" ] || die "not confirmed. Nothing was written."
    mkdir -p "$SUPPORT_DIR"
    {
        echo "confirmed=$(date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "app=$APP_PATH"
        echo "setup_report=$REPORT"
    } > "$MARKER.part"
    mv "$MARKER.part" "$MARKER"
    log "recorded: $MARKER"
    log "next: scripts/make_launchagent.sh --load      (quit the hand-started app from its menu first; then log out and in once)"
    exit 0
fi

# ---- unload -------------------------------------------------------------------------------------------------
if [ "$ACTION" = unload ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would run: launchctl bootout $GUI_DOMAIN/$LABEL"
        exit 0
    fi
    if launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null; then
        log "unloaded $LABEL (the app was asked to quit; the plist file is still there)"
    else
        log "$LABEL was not loaded (nothing to do)"
    fi
    exit 0
fi

# ---- gate: writing or loading needs the confirmation marker -------------------------------------------------------
if [ ! -f "$MARKER" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "[make_launchagent] WARNING (dry run): a real run would STOP here, without writing or loading anything." >&2
        print_prerequisite >&2
    else
        print_prerequisite >&2
        die "live test not confirmed: nothing was written or loaded"
    fi
fi

# ---- render --------------------------------------------------------------------------------------------------
case "$APP_PATH" in
    /*) ;;
    *) die "--app must be an absolute path (got '$APP_PATH')" ;;
esac
if [ -f "$MARKER" ] && [ -x "$APP_BIN" ] && [ "$APP_BIN" -nt "$MARKER" ]; then
    echo "[make_launchagent] WARNING: the app was rebuilt after you confirmed the live test. With a fixed signing identity the permissions" >&2
    echo "[make_launchagent]          stay; with an ad-hoc signature macOS asks again: run the setup step once more (docs/LIVE_TEST.md section 2)." >&2
fi
if [ ! -x "$APP_BIN" ]; then
    if [ "$ACTION" = load ] && [ "$DRY_RUN" != 1 ]; then
        die "$APP_BIN does not exist or is not executable (run scripts/build_app.sh --install first; an app installed under another file name: set MCAP_APP_SHORT_NAME to it, or pass --app)"
    fi
    echo "[make_launchagent] WARNING: $APP_BIN does not exist yet (build and install the app before the next login; if it is installed under another file name, set MCAP_APP_SHORT_NAME to that name or pass --app, or the agent starts nothing)" >&2
fi

render() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by scripts/make_launchagent.sh. Regenerate it instead of editing: scripts/make_launchagent.sh --load -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml_escape "$APP_BIN")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ThrottleInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$LOG_DIR/launchd-stdout.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$LOG_DIR/launchd-stderr.log")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(xml_escape "$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
EOF
    local i=0
    while [ "$i" -lt "${#ENV_KEYS[@]}" ]; do
        printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "$(xml_escape "${ENV_KEYS[$i]}")" "$(xml_escape "${ENV_VALUES[$i]}")"
        i=$((i + 1))
    done
    cat <<EOF
	</dict>
</dict>
</plist>
EOF
}

# Render to a temp file first and lint it; the real file is only replaced by a valid plist.
TMP_PLIST="$(mktemp "${TMPDIR:-/tmp}/mcap-plist.XXXXXX")"
render > "$TMP_PLIST"
plutil -lint "$TMP_PLIST" >/dev/null || { cat "$TMP_PLIST" >&2; die "the generated plist is not valid"; }

if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would write $PLIST_PATH (validated with plutil -lint), and create $LOG_DIR"
    echo "-----"
    cat "$TMP_PLIST"
    echo "-----"
    if [ "$ACTION" = load ]; then
        log "[dry-run] would run: launchctl bootout $GUI_DOMAIN/$LABEL   (ignore errors; only if an old copy is loaded)"
        log "[dry-run] would run: launchctl bootstrap $GUI_DOMAIN $PLIST_PATH"
    else
        log "[dry-run] would NOT load it (no --load): the agent starts at the next login"
    fi
    exit 0
fi

mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"      # launchd does not create the log directory; a missing one fails the job
cp "$TMP_PLIST" "$PLIST_PATH.part"
mv "$PLIST_PATH.part" "$PLIST_PATH"
chmod 644 "$PLIST_PATH"
plutil -lint "$PLIST_PATH" >/dev/null || die "written plist failed plutil -lint: $PLIST_PATH"
log "wrote $PLIST_PATH (plutil -lint OK)"

if [ "$ACTION" = load ]; then
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true       # not loaded is fine
    launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
    log "loaded $LABEL: the menu bar icon should appear within a few seconds"
    log "status: launchctl print $GUI_DOMAIN/$LABEL | head -20      stop: scripts/make_launchagent.sh --unload"
    log "macOS may show 'Background item added': keep $APP_NAME switched on in System Settings > General > Login Items."
    log "Quit from the menu is NOT restarted (it stays off until the next login or --load); a crash or kill -9 is restarted after 30 s."
    log "next (docs/LIVE_TEST.md section 7): kill -9 restart check, then log out and in once without opening a terminal."
else
    log "not loaded. It starts at the next login; to start it now: scripts/make_launchagent.sh --load"
    log "(from then on it records every Zoom / Teams call and every call of the other call apps of the built-in table: CALL_DETECT in config.env; Google Meet only if ENABLED_PLATFORMS contains meet)"
fi
