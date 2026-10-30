#!/bin/bash
# Install the app (CATE, "Catch Everything", unless you chose other names) for the current user. Safe to run again (idempotent); never overwrites your edits.
#
#   scripts/install.sh [options]
#
#   1. creates SUPPORT_DIR (~/Library/Application Support/MeetingCapture) and LOG_DIR (~/Library/Logs/MeetingCapture)
#   2. copies config.env and vocabulary.txt from config/ into SUPPORT_DIR ONLY if they are missing (an existing file is
#      kept; if the repo version differs a diff hint is printed). note_prompt.md is NOT copied: the pipeline reads the
#      repo copy (config/note_prompt.md) unless you create SUPPORT_DIR/note_prompt.md yourself to override it
#   0. shows the recording legal notice and asks you to type yes (see --accept-legal-notice); nothing is changed before that
#   3. builds the app and installs it to ~/Applications/<short name>.app, CATE.app by default   (scripts/build_app.sh --install). It is signed
#      with the identity 'MeetingCapture Local Signing' when you created one (scripts/make_signing_identity.sh), else ad-hoc
#   4. optional: Python venv (--python and friends, see scripts/setup_python.sh)
#   5. writes the LaunchAgent plist (scripts/make_launchagent.sh) ONLY after you confirmed the live test yourself
#      (make confirm-live-tested, see docs/LIVE_TEST.md): a written plist starts the app at the next login and from then on it
#      records every Zoom / Teams call and every call of the other call apps of the built-in table (CALL_DETECT), so a fresh install does not
#      write it. It is never loaded unless --load is given.
#   6. prints the next steps in the order of docs/LIVE_TEST.md: permissions (setup), device test (selftest-capture --live),
#      doctor, solo test calls started by hand (Zoom, then Teams; Google Meet is OFF by default), confirm, load
#
# Options:
#   --dry-run             print every action, change nothing
#   --require-signing     fail instead of installing an ad-hoc signed app (needs the identity from make_signing_identity.sh)
#   --accept-legal-notice accept the recording legal notice without being asked (a run without a terminal needs this; on a terminal the
#                         notice is shown and you type yes once). The notice is always printed; --dry-run changes nothing and asks nothing.
#   --python              also run scripts/setup_python.sh (production venv: pinned packages, about 550 MB download). With make:
#                         make install ARGS="--python --with-silero --pre-download-model"; to pick the interpreter set MCAP_PYTHON=/path/to/python3.13
#   --with-silero         (implies --python) also install the Silero VAD runtime and model (about 25 MB)
#   --with-qwen-bench     (implies --python) also build the SEPARATE bench venv SUPPORT_DIR/bench-venv with mlx-qwen3-asr
#                         (benchmark only; the production venv never gets it)
#   --pre-download-model  (implies --python) also download whisper-large-v3 now (3.08 GB; the size is printed first)
#   --client-only         (implies --python) the client-only venv (numpy and truststore: remote ASR, no local speech model, no model download);
#                         see scripts/setup_python.sh --help. Not verified on 8 GB Macs. The company install does not use this script (below).
#   --with-cloud          (implies --python) also check the certificate-store package of the cloud engines (scripts/setup_python.sh --with-cloud)
#   --load                load the LaunchAgent now (launchctl bootstrap); the app starts immediately. REFUSED, before anything is
#                         changed, until you ran `make confirm-live-tested` (setup without [FAIL] + selftest-capture --live PASS)
#   --no-build            skip building/installing the app (reuse the installed one)
#   --no-launchagent      do not touch the LaunchAgent at all
#   -h, --help            this text
#
# This is the PERSONAL install (your own Mac, everything in the home folder). The COMPANY install is a package: scripts/build_pkg.sh makes it, MDM
# installs it, and a policy-managed Mac only runs the root-owned runtime of that package (docs/DEPLOY.md). Run on a Mac that has an organisation
# policy this script warns: the app it installs would be refused there (runtime-untrusted).
#
# Environment overrides (tests): MCAP_SUPPORT_DIR, MCAP_LOG_DIR, MCAP_SYSTEM_ROOT (prefix of /Library for the policy check below); build_app.sh
# honours MCAP_BUILD_DIR, MCAP_SOURCES_DIR, MC_CODESIGN_IDENTITY. The app is built and installed under MCAP_APP_NAME / MCAP_APP_SHORT_NAME (build_app.sh,
# scripts/bundle_id.sh); with --no-build the installed app tells its own names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
# shellcheck source=legal_notice.sh
. "$SCRIPT_DIR/legal_notice.sh"
SUPPORT_DIR="${MCAP_SUPPORT_DIR:-$HOME/Library/Application Support/MeetingCapture}"
LOG_DIR="${MCAP_LOG_DIR:-$HOME/Library/Logs/MeetingCapture}"
APP_PATH=""
APP_BIN=""
APP_NAME=""
APP_SHORT_NAME=""

DRY_RUN=0
ACCEPT_LEGAL=0
DO_PYTHON=0
DO_BUILD=1
DO_AGENT=1
DO_LOAD=0
REQUIRE_SIGNING=0
PY_ARGS=()
WARNINGS=0
TMP_FILE=""
DIED=0
SIGNING_LINE="adhoc"

log()  { echo "[install] $*"; }
step() { echo; echo "== $*"; }
warn() { echo "[install] WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { DIED=1; echo "[install] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[install] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

# Run a command or print it (--dry-run).
act() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --accept-legal-notice) ACCEPT_LEGAL=1 ;;
        --require-signing) REQUIRE_SIGNING=1 ;;
        --python) DO_PYTHON=1 ;;
        --with-silero|--with-qwen-bench|--pre-download-model|--client-only|--with-cloud) DO_PYTHON=1; PY_ARGS+=("$1") ;;
        --load) DO_LOAD=1 ;;
        --no-build) DO_BUILD=0 ;;
        --no-launchagent) DO_AGENT=0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# The names of the app (scripts/bundle_id.sh): a build uses the environment, else the defaults (build_app.sh does the same); --no-build reuses the installed
# app, which tells its own. A refused value stops here, before anything is changed.
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above). Nothing was changed."
APP_PATH="$HOME/Applications/$APP_SHORT_NAME.app"
APP_BIN="$APP_PATH/Contents/MacOS/$APP_SHORT_NAME"
if [ "$DO_BUILD" = 1 ]; then
    APP_NAME="$(mcap_resolve_app_name)" || die "the app name is refused (see above). Nothing was changed."
else
    APP_NAME="$(mcap_resolve_app_name "$APP_PATH")" || die "the app name is refused (see above). Nothing was changed."
fi

# ---- preflight ------------------------------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "this is for macOS"
[ "$(uname -m)" = "arm64" ] || die "Apple silicon is required (this shell reports $(uname -m): Intel Macs and Rosetta shells are not supported; the speech model runs on MLX)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
case "${MACOS_VERSION%%.*}" in ''|*[!0-9]*) MACOS_MAJOR=0 ;; *) MACOS_MAJOR="${MACOS_VERSION%%.*}" ;; esac
MACOS_MINOR="$(printf '%s' "$MACOS_VERSION" | cut -d. -f2)"; case "$MACOS_MINOR" in ''|*[!0-9]*) MACOS_MINOR=0 ;; esac
if [ "$MACOS_MAJOR" -lt 14 ] || { [ "$MACOS_MAJOR" -eq 14 ] && [ "$MACOS_MINOR" -lt 4 ]; }; then
    die "macOS 14.4 or newer is required (this is $MACOS_VERSION): the system audio capture uses the Core Audio process tap API"
fi
[ -f "$SCRIPT_DIR/build_app.sh" ] && [ -d "$PROJECT_DIR/pipeline/mcap" ] || die "run this from the meeting-capture repository (scripts/build_app.sh or pipeline/mcap not found in $PROJECT_DIR)"
if [ "$DO_BUILD" = 1 ] && ! command -v swiftc >/dev/null 2>&1; then
    die "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"
fi
[ "$DRY_RUN" != 1 ] || log "dry run: nothing is created, copied, built or loaded"
# A policy-managed Mac (the company package put policy.required there) runs only the root-owned company runtime: say so BEFORE building anything.
SYSTEM_ROOT="${MCAP_SYSTEM_ROOT:-}"
for managed_file in "$SYSTEM_ROOT/Library/Application Support/MeetingCapture/policy.required" "$SYSTEM_ROOT/Library/Application Support/MeetingCapture/policy.json"; do
    if [ -e "$managed_file" ] || [ -L "$managed_file" ]; then
        warn "this Mac is managed by an organisation policy ($managed_file exists). A policy-managed Mac only starts a pipeline from the root-owned company runtime (docs/DEPLOY.md): the app and the venv installed here would be refused (runtime-untrusted). Use the company package instead; go on only if you know why."
        break
    fi
done
if [ ! -x "$HOME/.local/bin/claude" ] && CLAUDE_FOUND="$(command -v claude 2>/dev/null)"; then
    log "claude CLI : found at $CLAUDE_FOUND, not at the default ~/.local/bin/claude: set  CLAUDE_BIN=$CLAUDE_FOUND  in config.env"
fi
log "repository : $PROJECT_DIR"
log "SUPPORT_DIR: $SUPPORT_DIR"
log "LOG_DIR    : $LOG_DIR"
log "app        : $APP_NAME, $APP_PATH"

# The LaunchAgent is only written / loaded after the user confirmed the live test (make confirm-live-tested). Decided now, so a
# refused --load stops BEFORE anything is changed (like --require-signing).
LIVE_OK=0
if "$SCRIPT_DIR/make_launchagent.sh" --check-live-tested >/dev/null 2>&1; then LIVE_OK=1; fi
if [ "$DO_AGENT" = 1 ] && [ "$DO_LOAD" = 1 ] && [ "$LIVE_OK" != 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        warn "dry run: a real --load would STOP right here (nothing changed): the live test is not confirmed yet (see step 5/6 below)"
    else
        die "--load is refused: the live test is not confirmed yet, nothing was changed. Do the setup step, the device test and the solo test calls first (docs/LIVE_TEST.md), then run: make confirm-live-tested   and install again. Without --load this script still installs everything else."
    fi
fi

# Which signature the build would use (reads the keychain list only). Decided now so --require-signing fails BEFORE anything is changed.
if [ "$DO_BUILD" = 1 ]; then
    if [ "$REQUIRE_SIGNING" = 1 ]; then
        SIGNING_LINE="$("$SCRIPT_DIR/build_app.sh" --print-signing --require-identity 2>/dev/null)" \
            || die "--require-signing: there is no code-signing identity. Create it once (you run it, it asks macOS for a few clicks):  scripts/make_signing_identity.sh --dry-run   then   scripts/make_signing_identity.sh"
    else
        SIGNING_LINE="$("$SCRIPT_DIR/build_app.sh" --print-signing 2>/dev/null)" || SIGNING_LINE="adhoc"
    fi
    case "$SIGNING_LINE" in
        identity\ *) log "signing    : fixed identity '${SIGNING_LINE#identity * }' (macOS permissions survive rebuilds)" ;;
        *) log "signing    : ad-hoc (macOS asks for the permissions again after every changed build; see the signing step in the next steps below)" ;;
    esac
fi

# Without a build, say what the already installed app is signed with (it decides whether the signing step is still needed).
if [ "$DO_BUILD" != 1 ] && [ -d "$APP_PATH" ]; then
    INSTALLED_INFO="$(codesign -dvvv "$APP_PATH" 2>&1 || true)"
    FIRST_AUTHORITY="$(printf '%s\n' "$INSTALLED_INFO" | sed -n 's/^Authority=//p' | head -n 1)"
    if [ -n "$FIRST_AUTHORITY" ]; then
        SIGNING_LINE="identity installed $FIRST_AUTHORITY"
        log "signing    : the installed app is signed by '$FIRST_AUTHORITY'"
    else
        log "signing    : the installed app is signed ad-hoc"
    fi
fi

# ---- the recording legal notice: after every refusal above, before anything is created, copied, built or loaded ---------------------
legal_notice_gate "install" "$ACCEPT_LEGAL" "$DRY_RUN" "$APP_NAME" || die "the recording legal notice was not accepted, nothing was changed"

# ---- 1. directories ---------------------------------------------------------------------------------------------
step "1/6 directories"
act mkdir -p "$SUPPORT_DIR" "$SUPPORT_DIR/sessions" "$LOG_DIR"

# ---- 2. seed config files (never overwrite) ---------------------------------------------------------------------
step "2/6 config files (config.env and vocabulary.txt are copied only when missing)"

# The Meetings folder inside the My Drive of the ONE Google Drive for desktop account mounted for this user, as a ~ path; nothing when there is
# no such account or several (no guessing which one to write recordings to).
single_drive_meetings_dir() {
    local m found="" n=0
    for m in "$HOME/Library/CloudStorage"/GoogleDrive-*/"My Drive"; do
        [ -d "$m" ] || continue
        found="$m"; n=$((n + 1))
    done
    [ "$n" = 1 ] || return 0
    printf '~%s/Meetings' "${found#"$HOME"}"
}

# Same as the repo example, with PROJECT_DIR pointing at this checkout (shown with ~ when it is under $HOME) and, when exactly one Google Drive
# account is mounted, ARCHIVE_DIR pointing at its Meetings folder (else the example's local folder ~/Meetings stays).
render_config_env() {  # $1 = example file
    local value="$PROJECT_DIR" line drive
    case "$value" in
        "$HOME"/*) value="~${value#"$HOME"}" ;;
    esac
    drive="$(single_drive_meetings_dir)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            PROJECT_DIR=*) printf 'PROJECT_DIR=%s\n' "$value" ;;
            ARCHIVE_DIR=*) if [ -n "$drive" ]; then printf 'ARCHIVE_DIR=%s\n' "$drive"; else printf '%s\n' "$line"; fi ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$1"
}

# Prints settings that exist (uncommented) in the repo example but not in the user's config.env.
report_new_keys() {  # $1 = example, $2 = user's file
    local line key found=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            [A-Z_]*=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        if ! grep -q "^[[:space:]]*$key[[:space:]]*=" "$2"; then
            [ "$found" = 1 ] || log "  config.env: settings in the repo example that you do not have yet (defaults apply; add them if you want to change them):"
            found=1
            log "      $line"
        fi
    done < "$1"
}

# Value of the last "KEY=value" line of a config file (inline comment, quotes and blanks removed); empty when the key is missing.
config_value() {  # $1 = file, $2 = key
    # grep finds nothing when the key is missing: that is not an error (no ERR trap, and the pipeline ends in sed)
    { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" || true; } | tail -n 1 | sed -e 's/^[^=]*=//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

check_project_dir() {  # warn when an existing config.env points at another checkout
    local value actual
    value="$(config_value "$1" PROJECT_DIR)"
    [ -n "$value" ] || return 0
    case "$value" in
        "~"|"~/"*) value="$HOME${value#"~"}" ;;
    esac
    actual="$PROJECT_DIR"
    if [ -d "$value" ] && [ "$(cd "$value" && pwd -P)" = "$actual" ]; then
        return 0
    fi
    warn "config.env says PROJECT_DIR=$value but this repository is $actual. The app starts the pipeline from PROJECT_DIR/pipeline: edit $1 if the repository moved."
}

# Google Meet detection is OFF by default (SPEC 15): say what an existing config.env does about it.
report_platforms() {  # $1 = the user's config.env
    local value
    value="$(config_value "$1" ENABLED_PLATFORMS)"
    if [ -z "$value" ]; then
        log "  config.env: ENABLED_PLATFORMS is not set, the default is zoom,teams (Google Meet detection is OFF; add it only if you want it: ENABLED_PLATFORMS=zoom,teams,meet)"
    else
        case ",$(printf '%s' "$value" | tr -d ' ' | tr 'A-Z' 'a-z')," in
            *,meet,*) log "  config.env: ENABLED_PLATFORMS=$value includes meet: Google Meet detection is ON, 'setup' also asks for the Chrome Automation permission, and the Meet part of docs/LIVE_TEST.md (appendix A) applies" ;;
            *) log "  config.env: ENABLED_PLATFORMS=$value (Google Meet detection is OFF)" ;;
        esac
    fi
}

# Calls of other apps (CALL_DETECT): say what an existing config.env does about it, in particular that a file without the key records the call apps of the
# built-in table after an update, and that guessing is only on when the file says generic.
report_calls() {  # $1 = the user's config.env
    local value
    value="$(config_value "$1" CALL_DETECT | tr 'A-Z' 'a-z')"
    case "$value" in
        "") log "  config.env: CALL_DETECT is not set, the default is known: calls of the call apps of the built-in table (Slack huddles, Webex, Discord, FaceTime, KakaoTalk, WhatsApp, ...) are recorded like Zoom / Teams calls, personal messengers included, no guessing. CALL_DETECT=off switches it off; the menu Call Apps switches single apps off" ;;
        off) log "  config.env: CALL_DETECT=off (calls of other apps are not recorded)" ;;
        generic) log "  config.env: CALL_DETECT=generic: besides the built-in table of call apps ANY other GUI app that holds the microphone and plays sound for about 45 s is recorded (a guess; a notification names the app). known stops the guessing, off stops all of it" ;;
        *) log "  config.env: CALL_DETECT=$value (known: the built-in table of call apps and EXTRA_MEETING_APPS, no guessing; an unknown value reads as known; off switches it off)" ;;
    esac
}

# Claude billing (SPEC 17): the code default and the repo example say api (an Anthropic Console key), and an existing config.env is never
# overwritten. Say which mode the installed file really selects, so a subscription is never used by accident and a missing key is noticed.
report_billing() {  # $1 = the user's config.env
    local value
    value="$(config_value "$1" CLAUDE_AUTH)"
    case "$(printf '%s' "$value" | tr 'A-Z' 'a-z')" in
        "") log "  config.env: CLAUDE_AUTH is not set, so the code default applies: API (Claude calls are billed per token to the Anthropic Console key in the Keychain: store it once with  make set-api-key , then check it with  python -m mcap api-key check )" ;;
        api) log "  config.env: CLAUDE_AUTH=$value: Claude calls are billed to the Anthropic API key in the Keychain (store it once with  make set-api-key , check it with  python -m mcap api-key check )" ;;
        subscription) log "  config.env: CLAUDE_AUTH=$value: Claude calls use the claude.ai subscription login (an API key in the Keychain is never read). Subscription mode is opt-in: this tool runs  claude -p  in the background, so check Anthropic's terms for your account before you leave it unattended (README, Anthropic and Claude)" ;;
        *) warn "config.env: CLAUDE_AUTH=$value is neither 'subscription' nor 'api': the pipeline makes no Claude call until it is fixed" ;;
    esac
}

# Lists the lines (terms) of the repo vocabulary that your copy does not have (comments and blank lines ignored).
report_new_vocab_terms() {  # $1 = repo file, $2 = your file
    local line shown=0 n=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        if ! grep -qxF -- "$line" "$2"; then
            n=$((n + 1))
            if [ "$shown" -lt 12 ]; then
                [ "$shown" -gt 0 ] || log "      terms in the repo version that your copy does not have as an identical line:"
                log "          $line"
                shown=$((shown + 1))
            fi
        fi
    done < "$1"
    [ "$n" -le "$shown" ] || log "          ... and $((n - shown)) more"
}

# Say where the meetings of a freshly written config.env go (a Google Drive folder is chosen only when exactly one account is mounted).
report_archive_choice() {  # $1 = the config.env written (or that would be)
    local value
    value="$(config_value "$1" ARCHIVE_DIR)"
    case "$value" in
        *GoogleDrive-*) log "  config.env: ARCHIVE_DIR=$value (the one Google Drive account found; meetings, including the audio, are synced to that account. For a local folder instead: ARCHIVE_DIR=~/Meetings)" ;;
        *) log "  config.env: ARCHIVE_DIR=$value (a local folder; point it at a Google Drive or other synced folder to archive there)" ;;
    esac
}

seed_file() {  # $1 = repo file, $2 = destination, $3 = "config" for config.env, "vocab" for vocabulary.txt
    local src="$1" dst="$2" name
    name="$(basename "$dst")"
    if [ ! -f "$src" ]; then
        warn "$src is missing in the repository, so $name was not created (the built-in defaults apply; check the checkout)"
        return 0
    fi
    # What a fresh install would write (config.env gets this checkout's PROJECT_DIR).
    TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/mcap-seed.XXXXXX")"
    if [ "${3:-}" = config ]; then
        render_config_env "$src" > "$TMP_FILE"
    else
        cat "$src" > "$TMP_FILE"
    fi
    if [ -e "$dst" ]; then
        if [ "${3:-}" = config ]; then
            check_project_dir "$dst"
            report_platforms "$dst"
            report_calls "$dst"
            report_billing "$dst"
            report_new_keys "$src" "$dst"
        fi
        if cmp -s "$TMP_FILE" "$dst"; then
            log "$name: kept (identical to the repo version)"
        else
            log "$name: kept, your copy is untouched (it is never overwritten). It differs from the repo version; compare with:"
            log "      diff -u '$dst' '$src'"
            if [ "${3:-}" = vocab ]; then
                report_new_vocab_terms "$src" "$dst"
                log "      (the order of the terms is their priority for the ASR prompt; to take the repo version as it is:"
                log "       cp -p '$dst' '$dst.bak' && cp '$src' '$dst')"
            fi
        fi
    elif [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would create $dst from $src"
        [ "${3:-}" != config ] || report_archive_choice "$TMP_FILE"
    else
        cp "$TMP_FILE" "$dst.part"
        chmod 644 "$dst.part"
        mv "$dst.part" "$dst"
        log "$name: created $dst"
        [ "${3:-}" != config ] || report_archive_choice "$dst"
    fi
    rm -f "$TMP_FILE"
    TMP_FILE=""
}

seed_file "$PROJECT_DIR/config/config.env.example" "$SUPPORT_DIR/config.env" config
seed_file "$PROJECT_DIR/config/vocabulary.txt"     "$SUPPORT_DIR/vocabulary.txt" vocab

# note_prompt.md is not copied (a copy would drift away from the repo): the pipeline uses PROJECT_DIR/config/note_prompt.md
# unless SUPPORT_DIR/note_prompt.md exists, which then wins.
if [ -f "$SUPPORT_DIR/note_prompt.md" ]; then
    if cmp -s "$PROJECT_DIR/config/note_prompt.md" "$SUPPORT_DIR/note_prompt.md"; then
        log "note_prompt.md: $SUPPORT_DIR/note_prompt.md is identical to the repo copy. It overrides the repo copy, so future prompt"
        log "      improvements in the repo would NOT reach you. Not needed any more; if you made no edits, delete it: rm '$SUPPORT_DIR/note_prompt.md'"
    else
        log "note_prompt.md: your override $SUPPORT_DIR/note_prompt.md is used instead of the repo copy (untouched). Differences:"
        log "      diff -u '$SUPPORT_DIR/note_prompt.md' '$PROJECT_DIR/config/note_prompt.md'"
    fi
else
    log "note_prompt.md: not copied; the pipeline reads $PROJECT_DIR/config/note_prompt.md (create $SUPPORT_DIR/note_prompt.md only to override it)"
fi

# ---- 3. app -------------------------------------------------------------------------------------------------------
step "3/6 app"
if [ "$DO_BUILD" = 1 ]; then
    if pgrep -f "$APP_BIN" >/dev/null 2>&1; then
        log "$APP_NAME is running now. The new build replaces the files; quit the old process afterwards (menu: Quit, or"
        log "      scripts/make_launchagent.sh --unload) and start the new one."
    fi
    BUILD_ARGS=(--install)
    [ "$REQUIRE_SIGNING" != 1 ] || BUILD_ARGS+=(--require-identity)
    act "$SCRIPT_DIR/build_app.sh" "${BUILD_ARGS[@]}"
else
    log "skipped (--no-build)"
    [ -x "$APP_BIN" ] || warn "$APP_BIN does not exist yet (run without --no-build)"
fi

# ---- 4. python ----------------------------------------------------------------------------------------------------
step "4/6 python venv"
if [ "$DO_PYTHON" = 1 ]; then
    SETUP_ARGS=(${PY_ARGS[@]+"${PY_ARGS[@]}"})
    [ "$DRY_RUN" != 1 ] || SETUP_ARGS+=(--dry-run)       # setup_python.sh's own dry run prints its plan with exact sizes
    "$SCRIPT_DIR/setup_python.sh" ${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}
else
    if [ -x "$SUPPORT_DIR/venv/bin/python" ]; then
        log "venv already exists: $SUPPORT_DIR/venv (to update it run again with --python: make install ARGS=\"--python\")"
    else
        log "no venv yet. Create it when you are ready (about 550 MB, no model is downloaded): make setup-python   (or scripts/setup_python.sh)"
    fi
fi

# ---- 5. LaunchAgent -------------------------------------------------------------------------------------------------
step "5/6 LaunchAgent"
if [ "$DO_AGENT" != 1 ]; then
    log "skipped (--no-launchagent)"
elif [ "$LIVE_OK" != 1 ]; then
    log "not written: you have not confirmed the live test yet. A written plist starts the app at the next login and from then on it"
    log "records every Zoom / Teams call and every call of the other call apps of the built-in table (Slack huddles, FaceTime, WhatsApp, ...: CALL_DETECT in config.env;"
    log "CALL_DETECT=off switches them off), so it comes after the permissions, the device test and the solo test calls (the next steps below):"
    log "      make confirm-live-tested     then     scripts/make_launchagent.sh --load"
else
    AGENT_ARGS=(--app "$APP_PATH")
    [ "$DO_LOAD" != 1 ] || AGENT_ARGS+=(--load)
    [ "$DRY_RUN" != 1 ] || AGENT_ARGS+=(--dry-run)
    "$SCRIPT_DIR/make_launchagent.sh" "${AGENT_ARGS[@]}"
fi

# ---- 6. next steps --------------------------------------------------------------------------------------------------
step "6/6 next steps (the same order as docs/LIVE_TEST.md, which has the expected result of every step; that file is Korean, docs/LIVE_TEST.en.md is the English summary)"
VENV_PY="$SUPPORT_DIR/venv/bin/python"
OPEN_APP="open -n -W -a \"$APP_PATH\" --stdout \"\$(tty)\" --stderr \"\$(tty)\""
n=1
case "$SIGNING_LINE" in
    identity\ *) ;;
    *)
        echo "  $n. Signing (once, YOU run it; recommended before the permission step, otherwise macOS asks for the permissions again"
        echo "     after every rebuild). It creates a self-signed certificate in your login keychain; look first with --dry-run:"
        echo "       scripts/make_signing_identity.sh --dry-run && scripts/make_signing_identity.sh"
        echo "     then rebuild and reinstall the app with it (repeat the steps below when macOS asks again):"
        echo "       scripts/install.sh --require-signing"
        n=$((n + 1)) ;;
esac
if [ ! -x "$VENV_PY" ] && [ "$DO_PYTHON" != 1 ]; then
    echo "  $n. Python environment (once, about 550 MB; add --with-silero for the better VAD):"
    echo "       scripts/setup_python.sh [--with-silero] [--pre-download-model]"
    n=$((n + 1))
fi
echo "  $n. Check config (ARCHIVE_DIR is where finished meetings are filed: a local folder or your Google Drive Meetings folder; SELF_NAME your name). ENABLED_PLATFORMS defaults to"
echo "     zoom,teams: Google Meet detection is OFF (append ,meet to ENABLED_PLATFORMS only if you want it):"
echo "       open -e \"$SUPPORT_DIR/config.env\""
n=$((n + 1))
echo "  $n. Grant the macOS permissions ONCE, to the app itself (click Allow in every prompt: Microphone, System Audio Recording,"
echo "     Google Drive folder, Notifications; a Google Chrome automation prompt only appears if meet is in ENABLED_PLATFORMS)."
echo "     Run it through 'open -n' so the prompts are attributed to $APP_NAME (-n also works while the menu-bar app is already"
echo "     running; without it 'open' only re-activates that instance):"
echo "       $OPEN_APP --args setup"
n=$((n + 1))
echo "  $n. Live device test (about 15 s; talk and play some sound, it records both tracks and prints levels; --live = real devices;"
echo "     do it in every audio setup you use: MacBook speakers + built-in mic, and the conference speakerphone):"
echo "       $OPEN_APP --args selftest-capture --live --seconds 12 --out \"\$HOME/mcap-selftest\""
echo "     (--synthetic instead of --live is the device-free variant that needs no permissions)"
n=$((n + 1))
echo "  $n. Check the pipeline (config, venv, model cache, Claude login, archive folder):"
echo "       make doctor      # = cd pipeline && '$VENV_PY' -m mcap doctor"
n=$((n + 1))
echo "  $n. Solo test calls with the app started BY HAND (no LaunchAgent yet): open \"$APP_PATH\", then a Zoom 'New Meeting' alone,"
echo "     then a Teams 'Meet now' alone, then the Quit / kill -9 / lid / permission tests (docs/LIVE_TEST.md sections 4 to 6)."
n=$((n + 1))
if [ "$DO_AGENT" = 1 ]; then
    if [ "$LIVE_OK" = 1 ]; then
        echo "  $n. The live test is confirmed. Start the app now and at every login (the plist is written but NOT loaded unless you gave --load):"
        echo "       scripts/make_launchagent.sh --load     (quit the hand-started app from its menu first)"
    else
        echo "  $n. Confirm the live test yourself (it asks you to type 'confirmed'; install.sh and make_launchagent.sh refuse to write or"
        echo "     load the LaunchAgent before this), then load it and log out and in once (docs/LIVE_TEST.md section 7):"
        echo "       make confirm-live-tested"
        echo "       scripts/make_launchagent.sh --load"
    fi
    n=$((n + 1))
fi
echo
if [ "$WARNINGS" -gt 0 ]; then
    log "finished with $WARNINGS warning(s), see above"
else
    log "finished"
fi
[ "$DRY_RUN" != 1 ] || log "(dry run: nothing was changed)"
exit 0
