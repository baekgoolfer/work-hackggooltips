#!/bin/bash
# Move a personal install out of the way of the company install, and back again if needed (docs/MIGRATION.md).
#
#   scripts/migrate_owner_install.sh [mode] [options]
#
# The personal install lives in the user's home: the app ~/Applications/<short name>.app, its per-user LaunchAgent
# ~/Library/LaunchAgents/<bundle id>.plist, the settings ~/Library/Application Support/MeetingCapture/config.env, a venv and
# the pipeline in a checkout. The company install brings its own app, a system-wide LaunchAgent with the SAME label (when both are built with the
# same bundle id, scripts/bundle_id.sh), and a root-owned runtime. The bundle id (the label) is the CFBundleIdentifier of the personal app, else
# MCAP_BUNDLE_ID, else org.meetingcapture.app. The file name of the app is <short name>.app: MCAP_APP_SHORT_NAME, else CATE (the package sets it to its own);
# when there is no such app but another app in ~/Applications has the bundle id (an older build under another file name), that one is the personal app, and
# the state record names it, so --rollback and --finish find it again.
# Two apps must not run at once (the single-instance lock app.lock makes the second one quit without a word), so the old one has to go
# first, in a way that can be undone. This script does only that, and only inside the user's home:
#
# Modes (one; --detect is the default):
#   --detect      report what is there (changes nothing): the LaunchAgent and whether it is loaded, the app and whether it runs, config.env,
#                 recordings in progress or waiting in staging
#   --backup      refuse while a recording is in progress, then: copy config.env to config.env.bak and write migration.state (these two
#                 first: when either cannot be made nothing has been touched), boot the per-user agent out (launchctl bootout), move the
#                 plist to <plist>.prev and the app to <app>.app.prev. A move that fails puts the earlier steps back (the agent is
#                 loaded again), so a retry starts clean. Nothing is deleted: data, venv, models, sessions and the Keychain items stay where
#                 they are.
#   --rollback    undo --backup: put the app and the plist back, restore config.env.bak when config.env changed since (the changed one is kept as
#                 config.env.after-migration), load the agent again if it was loaded before. The company parts (system LaunchAgent, /Applications
#                 app, releases) are not touched here and have to go FIRST:  sudo scripts/uninstall.sh --company  and then this --rollback. Both
#                 installs use the same LaunchAgent label, so a company agent that is still loaded keeps the personal one from loading (and removing
#                 the company install after the rollback boots whichever agent is loaded out again; it leaves the restored files alone).
#   --finish      after the company install has proved itself: delete the .prev copies and the state record (config.env.bak stays).
#   --rehearse    do --backup, a check, --rollback and a comparison on a COPY of the legacy files in a temp home, and report PASS or FAIL.
#                 launchctl is never called and the real home is only read. Do this first on every Mac (docs/MIGRATION.md).
#
# Options:
#   --home DIR          the home directory of the account (default: your own; as root give --home and --user)
#   --user NAME         the account (needed as root: it names the launchd domain gui/<uid>)
#   --rehearse-dir DIR  --rehearse: put the temp home here (default a new folder under $TMPDIR; it is deleted afterwards)
#   --stop-app          --backup: after the agent is booted out, ask a still running old app to quit (SIGTERM, the app saves a recording and exits)
#   --no-launchctl      never call launchctl (a rehearsal of the package on a Mac whose real agent must stay as it is): the agent is then treated as
#                       not loaded and nothing is booted out or loaded again. --rehearse implies it.
#   --dry-run           print every action, change nothing
#   -h, --help          this text
#
# Every path is checked to stay inside the home directory after links are resolved (a link such as ~/Applications -> /Applications is refused),
# no file is ever overwritten (a name that is taken stops the step), and as root every move, copy and write inside the home is done AS THAT USER
# (sudo -u <user>): only launchctl keeps root's rights, so a link the user plants between the check and the move can only reach what the user
# could change anyway.
# The installer's preinstall calls  --backup  for the console user; MDM can call it for others. Korean note for the user: printed at the end of --backup.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle_id.sh
. "$HERE/bundle_id.sh"
LABEL=""                      # the bundle id of the personal app, set by paths_for
PKG_APP_FILE=""               # <short name>.app of the company package (MCAP_APP_SHORT_NAME, else the default), set by paths_for
MODE="detect"
HOME_DIR=""
USER_NAME=""
REHEARSE_DIR=""
STOP_APP=0
DRY_RUN=0
NO_LAUNCHCTL=0
WORK=""
DIED=0

log()  { echo "[migrate] $*"; }
warn() { echo "[migrate] WARNING: $*" >&2; }
die()  { DIED=1; echo "[migrate] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[migrate] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --detect) MODE="detect" ;;
        --backup) MODE="backup" ;;
        --rollback) MODE="rollback" ;;
        --finish) MODE="finish" ;;
        --rehearse) MODE="rehearse" ;;
        --home) [ $# -ge 2 ] || die "--home needs a directory" 2; HOME_DIR="$2"; shift ;;
        --user) [ $# -ge 2 ] || die "--user needs a name" 2; USER_NAME="$2"; shift ;;
        --rehearse-dir) [ $# -ge 2 ] || die "--rehearse-dir needs a directory" 2; REHEARSE_DIR="$2"; shift ;;
        --stop-app) STOP_APP=1 ;;
        --no-launchctl) NO_LAUNCHCTL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

[ -n "$HOME_DIR" ] || HOME_DIR="$HOME"
case "$HOME_DIR" in /*) ;; *) die "--home must be an absolute path (got '$HOME_DIR')" 2 ;; esac
[ -d "$HOME_DIR" ] || die "the home directory does not exist: $HOME_DIR"
if [ -n "$USER_NAME" ]; then
    printf '%s' "$USER_NAME" | grep -Eq '^[A-Za-z0-9._-]+$' || die "--user looks wrong: '$USER_NAME'" 2
fi
if [ "$(id -u)" = 0 ] && [ -z "$USER_NAME" ] && [ "$MODE" != detect ] && [ "$MODE" != rehearse ]; then
    die "as root give --user NAME as well: the launchd domain of the account is gui/<uid> (and --home DIR)" 2
fi

# As root, every change inside the user's home is made with the user's own rights (see the header).
AS_USER=()
if [ "$(id -u)" = 0 ] && [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ]; then AS_USER=(sudo -u "$USER_NAME"); fi

paths_for() {  # $1 = home directory: sets the paths of the legacy install
    local other_app
    HOME_DIR="$1"
    HOME_REAL="$(cd -P "$HOME_DIR" && pwd -P)"
    PKG_APP_FILE="$(mcap_resolve_app_short_name).app" || die "the short app name is refused (see above)" 2
    APP="$HOME_DIR/Applications/$PKG_APP_FILE"
    LABEL="$(mcap_resolve_bundle_id "$APP")" || die "the bundle identifier is refused (see above)" 2
    if [ ! -e "$APP" ] && [ ! -L "$APP" ]; then          # an older build under another file name: the same id, so the same login agent
        other_app="$(mcap_apps_with_bundle_id "$HOME_DIR/Applications" "$LABEL" | head -n 1 || true)"
        [ -z "$other_app" ] || APP="$other_app"
    fi
    AGENT="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
    SUPPORT="$HOME_DIR/Library/Application Support/MeetingCapture"
    CONFIG="$SUPPORT/config.env"
    STATE="$SUPPORT/migration.state"
}
paths_for "$HOME_DIR"

# ---- helpers ---------------------------------------------------------------------------------------------------------------------------
run() {  # run a command, or only print it with --dry-run
    if [ "$DRY_RUN" = 1 ]; then
        printf '[migrate] [dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# The folder that holds a path must resolve (links followed) to a place inside the home directory, and the path itself must not be a link.
check_path() {  # $1 = path
    local parent real
    if [ -L "$1" ]; then die "$1 is a symbolic link: refusing to move or copy it (remove the link yourself and run again)"; fi
    parent="$(dirname "$1")"
    [ -d "$parent" ] || return 0
    real="$(cd -P "$parent" && pwd -P)"
    case "$real/" in
        "$HOME_REAL"/*) ;;
        *) die "$parent resolves to $real, outside the home directory $HOME_REAL: refusing (a link such as ~/Applications -> /Applications?)" ;;
    esac
}

target_uid() {
    if [ -n "$USER_NAME" ]; then id -u "$USER_NAME"; else id -u; fi
}

agent_loaded() {
    [ "$NO_LAUNCHCTL" != 1 ] || return 1
    launchctl print "gui/$(target_uid)/$LABEL" >/dev/null 2>&1
}

app_running() {
    pgrep -f "$APP/Contents/MacOS/$(basename "$APP" .app)" >/dev/null 2>&1
}

# A recording in progress writes a wav in a session folder: modified within the last two minutes (the pipeline's own rule, SPEC 14.4).
live_recording() {
    [ -d "$SUPPORT/sessions" ] || return 1
    [ -n "$(find "$SUPPORT/sessions" -maxdepth 2 -name '*.wav' -mmin -2 2>/dev/null | head -n 1)" ]
}

unpublished_sessions() {
    local d n=0
    [ -d "$SUPPORT/sessions" ] || { echo 0; return 0; }
    for d in "$SUPPORT/sessions"/*/; do
        [ -d "$d" ] || continue
        case "$(basename "$d")" in _*) continue ;; esac
        [ -f "${d}session.json" ] && n=$((n + 1))
    done
    echo "$n"
}

state_get() { { grep -E "^$1=" "$STATE" 2>/dev/null || true; } | tail -n 1 | sed -e 's/^[^=]*=//'; }

# --backup moves the app away, and the app is where the label was read from: --rollback and --finish take the label the backup recorded (a state
# record of an older version has none: then it is read as before, from MCAP_BUNDLE_ID or the default).
use_recorded_label() {
    local recorded prevs
    recorded="$(state_get label)"
    if [ -n "$recorded" ] && mcap_valid_bundle_id "$recorded"; then
        LABEL="$recorded"
        AGENT="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
    fi
    recorded="$(state_get app)"       # the file name of the app that was put aside (a record of an older version has none: the name paths_for found)
    case "$recorded" in
        *.app) if mcap_valid_app_short_name "${recorded%.app}"; then APP="$HOME_DIR/Applications/$recorded"; fi ;;
        *)     if [ ! -e "$APP.prev" ]; then      # an older record names no app: the one .prev copy that is there, if any. Several: nothing is guessed (--finish deletes it)
                   prevs="$(ls -d "$HOME_DIR/Applications"/*.app.prev 2>/dev/null || true)"
                   [ "$(printf '%s' "$prevs" | grep -c .)" -le 1 ] || die "the state record names no app, and there is more than one *.app.prev in $HOME_DIR/Applications ($(printf '%s\n' "$prevs" | sed 's|.*/||' | tr '\n' ' ')): I cannot tell which one is the backup. Run again with MCAP_APP_SHORT_NAME set to the file name of the app that was put aside (without .app), and delete or move the other copies yourself"
                   [ -z "$prevs" ] || APP="${prevs%.prev}"
               fi ;;
    esac
}

# ---- --detect ------------------------------------------------------------------------------------------------------------------------
do_detect() {
    local found=0 n
    log "home: $HOME_DIR"
    if [ -e "$AGENT" ] || [ -L "$AGENT" ]; then
        found=1
        if agent_loaded; then log "per-user LaunchAgent: $AGENT (LOADED: the app is started by launchd at login)"
        else log "per-user LaunchAgent: $AGENT (not loaded)"; fi
    else
        log "per-user LaunchAgent: none"
    fi
    if [ -e "$APP" ] || [ -L "$APP" ]; then
        found=1
        if app_running; then log "app: $APP (RUNNING now)"; else log "app: $APP (not running)"; fi
    else
        log "app: none in ~/Applications"
    fi
    if [ -f "$CONFIG" ]; then
        found=1
        log "config.env: $CONFIG ($(wc -c < "$CONFIG" | tr -d ' ') bytes; it is kept and is never overwritten by the company install)"
        case "$({ grep -E '^ARCHIVE_DIR=' "$CONFIG" || true; } | tail -n 1)" in
            *"My Drive"*) log "  note: ARCHIVE_DIR points into a personal My Drive; the company policy only lets meetings go to its archive.allowed_roots (the team shared drive), anything else stays in the local archive" ;;
        esac
    else
        log "config.env: none"
    fi
    n="$(unpublished_sessions)"
    log "staging: $n recording(s) not published yet (they are kept; the company pipeline processes them like new ones)"
    if live_recording; then log "A RECORDING IS IN PROGRESS (a wav changed in the last two minutes): --backup would refuse"; fi
    if [ -f "$STATE" ]; then log "a migration is recorded ($STATE): --rollback undoes it, --finish closes it"; fi
    [ "$found" = 1 ] || log "no personal install found: nothing to migrate"
}

# ---- --backup --------------------------------------------------------------------------------------------------------------------------
# What a --backup that stops half way puts back, so that the personal install is as it was and a retry (the package's preinstall is retried by
# MDM) starts clean: the app and the plist moved so far, the agent if it was booted out, and the files this run made (config.env.bak, the state
# record). When something cannot be put back, the state record stays: --rollback then finishes the job. Reads the locals of do_backup.
backup_undo() {
    local undone=1
    warn "the backup stopped before it was done: putting back what it had moved"
    if [ "$moved_app" = 1 ]; then run ${AS_USER[@]+"${AS_USER[@]}"} mv "$APP.prev" "$APP" || { undone=0; warn "cannot put $APP.prev back"; }; fi
    if [ "$moved_agent" = 1 ]; then run ${AS_USER[@]+"${AS_USER[@]}"} mv "$AGENT.prev" "$AGENT" || { undone=0; warn "cannot put $AGENT.prev back"; }; fi
    if [ "$booted_out" = 1 ] && [ "$NO_LAUNCHCTL" != 1 ] && [ -e "$AGENT" ]; then
        run launchctl bootstrap "gui/$(target_uid)" "$AGENT" || warn "launchctl bootstrap failed: start the app by hand, or log out and in"
    fi
    if [ "$undone" = 1 ]; then
        if [ "$bak_made" = 1 ]; then run ${AS_USER[@]+"${AS_USER[@]}"} rm -f "$bak"; fi
        if [ "$state_made" = 1 ]; then run ${AS_USER[@]+"${AS_USER[@]}"} rm -f "$STATE" "$STATE.part"; fi
    else
        warn "the state record $STATE is kept: run --rollback to put the rest back"
    fi
}
abort_backup() { backup_undo; die "$1"; }

do_backup() {
    local was_loaded=0 had_agent=0 had_app=0 bak="" bak_made=0 state_made=0 booted_out=0 moved_agent=0 moved_app=0
    check_path "$AGENT"; check_path "$APP"; check_path "$CONFIG"
    [ ! -e "$STATE" ] || die "a migration is already recorded ($STATE): run --rollback to undo it or --finish to close it"
    [ ! -e "$AGENT.prev" ] || die "$AGENT.prev exists already: a former migration was not closed (--rollback or --finish first)"
    [ ! -e "$APP.prev" ] || die "$APP.prev exists already: a former migration was not closed (--rollback or --finish first)"
    if live_recording; then
        die "a recording is in progress (a wav of a session folder changed in the last two minutes): try again after the meeting. Nothing was changed." 3
    fi
    if [ -e "$AGENT" ]; then had_agent=1; fi
    if [ -d "$APP" ]; then had_app=1; fi
    if [ "$had_agent" = 0 ] && [ "$had_app" = 0 ] && [ ! -f "$CONFIG" ]; then
        log "no personal install found in $HOME_DIR: nothing to back up"
        return 0
    fi
    if agent_loaded; then was_loaded=1; fi
    # First everything that changes nothing of the install: the copy of config.env and the state record. When one of them cannot be made (a
    # folder that is not writable, a name that is taken, a link in the way) nothing has been booted out or moved yet.
    if [ -f "$CONFIG" ]; then
        bak="$CONFIG.bak"
        [ ! -e "$bak" ] || bak="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
        [ ! -e "$bak" ] || die "$bak exists already"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$bak" ]; then log "[dry-run] would copy $CONFIG to $bak"; fi
    else
        ${AS_USER[@]+"${AS_USER[@]}"} mkdir -p "$SUPPORT" || die "cannot create $SUPPORT: nothing was changed"
        if [ -n "$bak" ]; then
            # exclusive create: nothing is written through a link or over a file
            ${AS_USER[@]+"${AS_USER[@]}"} /bin/sh -c 'set -C; cat "$1" > "$2"' sh "$CONFIG" "$bak" || die "cannot create $bak: nothing was changed"
            bak_made=1
            log "copied config.env to $bak"
        fi
        {
            echo "migrated=$(date '+%Y-%m-%dT%H:%M:%S%z')"
            echo "agent_was_present=$had_agent"
            echo "agent_was_loaded=$was_loaded"
            echo "app_was_present=$had_app"
            echo "label=$LABEL"
            echo "app=$(basename "$APP")"
            echo "config_bak=$(basename "$bak")"
        } | ${AS_USER[@]+"${AS_USER[@]}"} /bin/sh -c 'set -C; cat > "$1"' sh "$STATE.part" || abort_backup "cannot write the state record $STATE.part (a leftover of an earlier run? remove it and try again): nothing was changed"
        state_made=1
        # recorded BEFORE anything moves: whatever stops the moves (even a power cut), --rollback knows what to put back
        ${AS_USER[@]+"${AS_USER[@]}"} mv "$STATE.part" "$STATE" || abort_backup "cannot write the state record $STATE: nothing was changed"
        log "recorded $STATE"
    fi
    if [ "$was_loaded" = 1 ]; then
        log "booting the per-user agent out (the app quits; a recording would have been refused above)"
        if run launchctl bootout "gui/$(target_uid)/$LABEL"; then booted_out=1; else warn "launchctl bootout failed (the agent was perhaps not loaded for this user)"; fi
    fi
    if [ "$had_agent" = 1 ]; then
        run ${AS_USER[@]+"${AS_USER[@]}"} mv "$AGENT" "$AGENT.prev" || abort_backup "cannot move $AGENT to $AGENT.prev"
        moved_agent=1
        log "moved the LaunchAgent plist to $AGENT.prev"
    fi
    if app_running; then
        if [ "$STOP_APP" = 1 ]; then
            log "the old app still runs: asking it to quit (SIGTERM)"
            run pkill -TERM -f "$APP/Contents/MacOS/$(basename "$APP" .app)" || true
            [ "$DRY_RUN" = 1 ] || sleep 2
        else
            warn "the old app is still running (it was started by hand?): quit it from its menu, otherwise the company app cannot start (single-instance lock). --stop-app asks it to quit."
        fi
    fi
    if [ "$had_app" = 1 ]; then
        run ${AS_USER[@]+"${AS_USER[@]}"} mv "$APP" "$APP.prev" || abort_backup "cannot move $APP to $APP.prev"
        moved_app=1
        log "moved the app to $APP.prev"
    fi
    log "done. Nothing was deleted: data, sessions, venv, models and Keychain items are where they were."
    echo "새 앱은 Developer ID로 서명되어 있어서 macOS가 마이크와 시스템 오디오 녹음 권한을 다시 물어요. 설치 뒤 첫 실행에서 허용해 주세요."
    echo "되돌리려면: scripts/migrate_owner_install.sh --rollback"
}

# ---- --rollback ------------------------------------------------------------------------------------------------------------------------
# Is the company install (the package's app or system LaunchAgent) still on this Mac? MCAP_SYSTEM_ROOT is a prefix for tests, like in uninstall.sh.
company_install_present() {
    [ -e "${MCAP_SYSTEM_ROOT:-}/Applications/$PKG_APP_FILE" ] || [ -e "${MCAP_SYSTEM_ROOT:-}/Library/LaunchAgents/$LABEL.plist" ]
}

do_rollback() {
    local bak="" aside
    use_recorded_label
    check_path "$AGENT"; check_path "$APP"; check_path "$CONFIG"
    [ -f "$STATE" ] || [ -e "$AGENT.prev" ] || [ -e "$APP.prev" ] || die "nothing to roll back: there is no $STATE and no .prev copy"
    if [ "$NO_LAUNCHCTL" != 1 ] && company_install_present; then
        warn "the company install is still on this Mac and has the same LaunchAgent label as the personal agent restored here: remove it FIRST (sudo scripts/uninstall.sh --company; it leaves this personal install alone), then run --rollback. Going on: the files are restored, but the personal agent will not load while the company agent is loaded."
    fi
    bak="$(state_get config_bak)"
    if [ -e "$APP.prev" ]; then
        if [ -e "$APP" ] || [ -L "$APP" ]; then
            aside="$APP.rollback-new"
            [ ! -e "$aside" ] || die "$aside exists already"
            run ${AS_USER[@]+"${AS_USER[@]}"} mv "$APP" "$aside"
            log "an app was installed at $APP since: moved to $aside (kept)"
        fi
        run ${AS_USER[@]+"${AS_USER[@]}"} mv "$APP.prev" "$APP"
        log "restored the app: $APP"
    fi
    if [ -e "$AGENT.prev" ]; then
        if [ -e "$AGENT" ] || [ -L "$AGENT" ]; then
            aside="$AGENT.rollback-new"
            [ ! -e "$aside" ] || die "$aside exists already"
            run ${AS_USER[@]+"${AS_USER[@]}"} mv "$AGENT" "$aside"
            log "a LaunchAgent plist was written at $AGENT since: moved to $aside (kept)"
        fi
        run ${AS_USER[@]+"${AS_USER[@]}"} mv "$AGENT.prev" "$AGENT"
        log "restored the LaunchAgent plist: $AGENT"
    fi
    if [ -n "$bak" ] && [ -f "$SUPPORT/$bak" ]; then
        if [ -f "$CONFIG" ] && ! cmp -s "$CONFIG" "$SUPPORT/$bak"; then
            [ ! -e "$CONFIG.after-migration" ] || die "$CONFIG.after-migration exists already"
            run ${AS_USER[@]+"${AS_USER[@]}"} mv "$CONFIG" "$CONFIG.after-migration"
            run ${AS_USER[@]+"${AS_USER[@]}"} cp "$SUPPORT/$bak" "$CONFIG"
            log "config.env had changed since the backup: the backup is restored, the changed file is kept as config.env.after-migration"
        elif [ ! -e "$CONFIG" ]; then
            run ${AS_USER[@]+"${AS_USER[@]}"} cp "$SUPPORT/$bak" "$CONFIG"
            log "config.env was gone: restored from $bak"
        else
            log "config.env is identical to the backup: unchanged"
        fi
    fi
    if [ "$(state_get agent_was_loaded)" = 1 ] && [ -e "$AGENT" ]; then
        if [ "$NO_LAUNCHCTL" = 1 ]; then
            log "(rehearsal: the agent would be loaded again here)"
        else
            run launchctl bootstrap "gui/$(target_uid)" "$AGENT" || warn "launchctl bootstrap failed: start the app by hand, or log out and in"
            log "loaded the per-user agent again"
        fi
    fi
    if [ -f "$STATE" ]; then run ${AS_USER[@]+"${AS_USER[@]}"} mv "$STATE" "$STATE.rolled-back"; fi
    if [ "$NO_LAUNCHCTL" = 1 ]; then
        log "done. The company parts are not touched here (they go FIRST: sudo scripts/uninstall.sh --company, then --rollback)."
    elif company_install_present; then
        log "done. The company install is STILL here (not touched by --rollback). Remove it with: sudo scripts/uninstall.sh --company (it leaves what was restored alone and boots the loaded agent out); then log out and in, or: launchctl bootstrap gui/$(target_uid) \"$AGENT\""
    else
        log "done. The company install is not on this Mac (removed first, as it has to be): the personal install is back."
    fi
}

# ---- --finish --------------------------------------------------------------------------------------------------------------------------
do_finish() {
    use_recorded_label
    check_path "$AGENT"; check_path "$APP"
    [ -f "$STATE" ] || [ -e "$AGENT.prev" ] || [ -e "$APP.prev" ] || die "nothing to finish: there is no $STATE and no .prev copy"
    if [ -e "$APP.prev" ]; then
        case "$APP.prev" in */Applications/*.app.prev) run ${AS_USER[@]+"${AS_USER[@]}"} rm -rf "$APP.prev"; log "deleted $APP.prev" ;; *) die "unexpected path $APP.prev" ;; esac
    fi
    if [ -e "$AGENT.prev" ]; then run ${AS_USER[@]+"${AS_USER[@]}"} rm -f "$AGENT.prev"; log "deleted $AGENT.prev"; fi
    if [ -f "$STATE" ]; then run ${AS_USER[@]+"${AS_USER[@]}"} rm -f "$STATE"; fi
    log "done. config.env.bak is kept (it is small and only yours)."
}

# ---- --rehearse ------------------------------------------------------------------------------------------------------------------------
do_rehearse() {
    local real_home="$HOME_DIR" tmp ok=1 before after
    if [ -n "$REHEARSE_DIR" ]; then
        tmp="$REHEARSE_DIR"
        [ ! -e "$tmp" ] || die "--rehearse-dir exists already: $tmp"
        mkdir -p "$tmp"
    else
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/mcap-migrate-rehearsal.XXXXXX")"
        WORK="$tmp"
    fi
    log "rehearsal in a COPY of the legacy files: $tmp/home (the real home $real_home is only read; launchctl is never called)"
    mkdir -p "$tmp/home/Library/LaunchAgents" "$tmp/home/Applications" "$tmp/home/Library/Application Support/MeetingCapture"
    if [ -f "$real_home/Library/LaunchAgents/$LABEL.plist" ]; then cp "$real_home/Library/LaunchAgents/$LABEL.plist" "$tmp/home/Library/LaunchAgents/"; fi
    if [ -d "$APP" ]; then cp -R "$APP" "$tmp/home/Applications/"; fi          # the personal app paths_for found in the real home
    for f in config.env vocabulary.txt; do
        if [ -f "$real_home/Library/Application Support/MeetingCapture/$f" ]; then cp "$real_home/Library/Application Support/MeetingCapture/$f" "$tmp/home/Library/Application Support/MeetingCapture/"; fi
    done
    NO_LAUNCHCTL=1
    paths_for "$tmp/home"
    before="$(cd "$tmp/home" && find . -type f -not -name migration.state | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"; done)"
    log "step 1 of 2: --backup"
    ( do_backup ) || ok=0
    [ -f "$STATE" ] || [ "$ok" = 0 ] || log "(nothing to back up in this home)"
    log "step 2 of 2: --rollback"
    if [ "$ok" = 1 ] && { [ -f "$STATE" ] || [ -e "$AGENT.prev" ] || [ -e "$APP.prev" ]; }; then ( do_rollback ) || ok=0; fi
    after="$(cd "$tmp/home" && find . -type f -not -name 'migration.state*' -not -name 'config.env.bak*' | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"; done)"
    before="$(printf '%s\n' "$before" | grep -v 'config.env.bak' || true)"
    if [ "$ok" = 1 ] && [ "$before" = "$after" ]; then
        log "REHEARSAL PASS: backup and rollback gave back every file byte for byte ($(printf '%s\n' "$after" | grep -c . || true) files compared)"
    else
        log "REHEARSAL FAIL: the files after the rollback differ from the files before the backup (or a step failed): do NOT migrate this Mac before this is understood"
        DIED=1
        return 1
    fi
}

case "$MODE" in
    detect) do_detect ;;
    backup) do_backup ;;
    rollback) do_rollback ;;
    finish) do_finish ;;
    rehearse) do_rehearse ;;
esac
