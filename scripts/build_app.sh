#!/bin/bash
# Build, assemble and sign the app, <short name>.app (CATE.app unless you set MCAP_APP_SHORT_NAME; Command Line Tools only: swiftc, no Xcode/SwiftPM).
#
#   scripts/build_app.sh                    build into build/<short name>.app
#   scripts/build_app.sh --clean            remove the previous build outputs first, then build
#   scripts/build_app.sh --clean-only       remove build outputs and exit
#   scripts/build_app.sh --install          also copy the app to ~/Applications/<short name>.app (refused, before anything is built, when the
#                                           installed app has another bundle id than this build: see MCAP_ALLOW_ID_CHANGE; also refused when another
#                                           app in ~/Applications has the SAME bundle id under another file name: two apps with one id share one
#                                           login agent and one set of permissions)
#   scripts/build_app.sh --require-identity fail instead of falling back to an ad-hoc signature
#   scripts/build_app.sh --print-signing    only say which signature would be used (reads the keychain list, builds nothing)
#
# stdout: only the absolute path of the built app (last line); with --print-signing one line: "adhoc" or
# "identity <SHA-1> <name>". Progress and diagnostics go to stderr. Any failure aborts with a non-zero exit code.
#
# Signing (decided in this order):
#   1. MC_CODESIGN_IDENTITY=<name or SHA-1>  that identity (it must be listed by `security find-identity -p codesigning`)
#      MC_CODESIGN_IDENTITY=-                force an ad-hoc signature
#   2. an identity named "MeetingCapture Local Signing" (created once by scripts/make_signing_identity.sh; the name is the label of a certificate
#      in your keychain, not the name of the app, and stays what it was so that an identity you made earlier is still found)
#   3. ad-hoc (no certificate)
# With a fixed identity the code requirement macOS stores for the Microphone / System Audio Recording / Notifications (and Chrome Automation, if Meet is enabled) permissions
# is  identifier "<bundle id>" and certificate leaf = H"<cert hash>",  which does not change when the
# code changes: permissions survive rebuilds. An ad-hoc app is identified by its code hash, so every changed build
# asks for them again. The identity list is read with `security find-identity -p codesigning` (no -v, so untrusted
# self-signed identities are included); this script never creates, imports or modifies anything in a keychain.
# Always --identifier <bundle id> (MCAP_BUNDLE_ID below), NO hardened runtime. Builds are deterministic (no timestamps).
#
# Icon: the Info.plist names CFBundleIconFile=AppIcon; the .icns is copied to Contents/Resources/AppIcon.icns BEFORE signing (the
# signature seals it) and must decode with iconutil. macOS shows it in notifications, System Settings and Finder.
#
# Environment overrides (for building without the real sources, e.g. with stubs in a scratch directory):
#   MCAP_SOURCES_DIR     directory with the *.swift files to compile   (default: app/Sources)
#   MCAP_BUILD_DIR       output directory                              (default: build)
#   MCAP_PLIST_TEMPLATE  Info.plist template                           (default: app/Info.plist.template)
#   MCAP_ICON_FILE       the .icns copied into the bundle              (default: app/Resources/AppIcon.icns; made by scripts/make_icon.swift)
#   MCAP_NO_LSREGISTER=1 --install: do not refresh Launch Services for the installed app (see "optional install")
#   MCAP_VERSION         CFBundleShortVersionString                    (default: VERSION file, else 0.1.0)
#   MCAP_BUNDLE_ID       the bundle identifier of this copy           (default: org.meetingcapture.app)
#                        Reverse-DNS: dot-separated labels of letters, digits and hyphens, at least two labels, no label starting or ending with a
#                        hyphen, at most 155 characters; anything else is refused before anything is built. It is the CFBundleIdentifier, the codesign
#                        --identifier and (derived by the other scripts) the LaunchAgent label and the package identifier. macOS ties its permissions
#                        to it: keep it the same on every build of your copy, a different one is a different app and asks again (docs/CONFIGURATION.md).
#   MCAP_APP_NAME        the human name of the app                      (default: Catch Everything)
#                        ASCII letters, digits, spaces, hyphens and periods, starting with a letter or digit, no trailing space, 1 to 40 characters; anything
#                        else is refused before anything is built. It is CFBundleDisplayName and the name in the usage strings of Info.plist; the app
#                        itself shows it in every message (it reads it from Info.plist at run time).
#   MCAP_APP_SHORT_NAME  the file-safe short name of the app            (default: CATE)
#                        ASCII letters and digits, starting with a letter, 1 to 32 characters; anything else is refused before anything is built. It is the
#                        app folder <short name>.app, the executable <short name> and CFBundleName. The paths and identifiers that are not the product
#                        name (the data folder MeetingCapture, the Keychain items, the python package mcap) do not follow it.
#   MCAP_ALLOW_ID_CHANGE=1  --install: replace an installed app that has ANOTHER bundle id (default: refused, because the permissions are asked
#                        again and the login agent of the old id keeps starting the app); says how to remove the old login agent
#   MCAP_BUILT_BY        who built this copy, e.g. "Example Team, example.org"   (default: empty = no builder anywhere in the bundle)
#                        Set: Info.plist gets MCBuiltBy=<value> and NSHumanReadableCopyright "<copyright>. Built by <value>", and the
#                        menu item "About <name>" shows the line. One line of at most 80 characters (whitespace runs and
#                        newlines become one space, the ends are trimmed, a longer value is cut and ends in an ellipsis). The value
#                        is a plain build input: no timestamp, so the build stays deterministic. See docs/BRANDING.md.
#   MC_CODESIGN_IDENTITY see above

set -euo pipefail

MODULE_NAME="MeetingCapture"      # the Swift module: an internal name, the same for every build whatever the app is called
MIN_MACOS="14.4"
TARGET="arm64-apple-macos${MIN_MACOS}"
IDENTITY_NAME="MeetingCapture Local Signing"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCES_DIR="${MCAP_SOURCES_DIR:-$PROJECT_DIR/app/Sources}"
BUILD_DIR="${MCAP_BUILD_DIR:-$PROJECT_DIR/build}"
PLIST_TEMPLATE="${MCAP_PLIST_TEMPLATE:-$PROJECT_DIR/app/Info.plist.template}"
ICON_FILE="${MCAP_ICON_FILE:-$PROJECT_DIR/app/Resources/AppIcon.icns}"

DIED=0
log() { echo "[build_app] $*" >&2; }
die() { DIED=1; echo "[build_app] ERROR: $*" >&2; exit 1; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[build_app] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

DO_CLEAN=0
CLEAN_ONLY=0
DO_INSTALL=0
REQUIRE_IDENTITY=0
PRINT_SIGNING=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) DO_CLEAN=1 ;;
        --clean-only) DO_CLEAN=1; CLEAN_ONLY=1 ;;
        --install) DO_INSTALL=1 ;;
        --require-identity) REQUIRE_IDENTITY=1 ;;
        --print-signing) PRINT_SIGNING=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# Absolute BUILD_DIR (it may be given relative to the caller's directory).
case "$BUILD_DIR" in
    /*) ;;
    *) BUILD_DIR="$PWD/$BUILD_DIR" ;;
esac

# The names of the app (scripts/bundle_id.sh): environment, else the defaults. Refused before anything is built or cleaned.
APP_NAME="$(mcap_resolve_app_name)" || die "the app name is refused (see above). Nothing was built."
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above). Nothing was built."
APP="$BUILD_DIR/$APP_SHORT_NAME.app"
OBJ_DIR="$BUILD_DIR/obj"

# ---- signing identity selection ----------------------------------------------------------------------------
# Prints "<SHA-1>\t<name>\t<note>" for every distinct code-signing identity the keychains list. `security find-identity`
# without -v includes untrusted (self-signed) identities; the output has a "Matching identities" and a "Valid identities
# only" section, so the same identity can appear twice: de-duplicated by hash. Read-only.
list_signing_identities() {
    local out
    out="$(security find-identity -p codesigning 2>/dev/null)" || return 0
    printf '%s\n' "$out" \
        | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)"\(.*\)$/\1	\2	\3/p' \
        | awk -F'\t' '!seen[toupper($1)]++'
}

SIGN_MODE="adhoc"     # adhoc | identity
SIGN_ARG="-"          # what is passed to codesign --sign
SIGN_NAME=""
SIGN_HASH=""
SIGN_NOTE=""

choose_signing() {
    local want="${MC_CODESIGN_IDENTITY:-}" ids matches count upper
    SIGN_MODE="adhoc"; SIGN_ARG="-"; SIGN_NAME=""; SIGN_HASH=""; SIGN_NOTE=""
    if [ "$want" = "-" ]; then
        [ "$REQUIRE_IDENTITY" != 1 ] || die "--require-identity contradicts MC_CODESIGN_IDENTITY=- (forced ad-hoc)"
        return 0
    fi
    command -v security >/dev/null 2>&1 || die "the 'security' tool is missing (it ships with macOS)"
    ids="$(list_signing_identities)"
    if [ -n "$want" ]; then
        if printf '%s' "$want" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
            upper="$(printf '%s' "$want" | tr 'a-f' 'A-F')"
            matches="$(printf '%s\n' "$ids" | awk -F'\t' -v h="$upper" 'toupper($1) == h')"
        else
            matches="$(printf '%s\n' "$ids" | awk -F'\t' -v n="$want" '$2 == n')"
        fi
        count="$(printf '%s' "$matches" | grep -c . || true)"
        [ "$count" -ge 1 ] || die "MC_CODESIGN_IDENTITY='$want' is not a code-signing identity of this Mac (list: security find-identity -p codesigning)"
        [ "$count" -le 1 ] || die "MC_CODESIGN_IDENTITY='$want' matches $count identities; pass the SHA-1 of the one you mean (security find-identity -p codesigning)"
    else
        matches="$(printf '%s\n' "$ids" | awk -F'\t' -v n="$IDENTITY_NAME" '$2 == n')"
        count="$(printf '%s' "$matches" | grep -c . || true)"
        if [ "$count" -eq 0 ]; then
            [ "$REQUIRE_IDENTITY" != 1 ] || die "--require-identity: no code-signing identity named '$IDENTITY_NAME' (create it once: scripts/make_signing_identity.sh) and MC_CODESIGN_IDENTITY is not set"
            return 0
        fi
        [ "$count" -le 1 ] || die "$count identities are named '$IDENTITY_NAME' (the sign would be ambiguous). Delete the extra ones in Keychain Access or pass MC_CODESIGN_IDENTITY=<SHA-1> (security find-identity -p codesigning)"
    fi
    SIGN_MODE="identity"
    SIGN_HASH="$(printf '%s' "$matches" | cut -f1 | tr 'a-f' 'A-F')"
    SIGN_NAME="$(printf '%s' "$matches" | cut -f2)"
    SIGN_NOTE="$(printf '%s' "$matches" | cut -f3 | sed -e 's/^[[:space:]]*//')"
    SIGN_ARG="$SIGN_HASH"      # by hash: unambiguous even when another certificate has a similar name
    return 0
}

if [ "$PRINT_SIGNING" = 1 ]; then
    choose_signing
    if [ "$SIGN_MODE" = identity ]; then
        log "signing: identity '$SIGN_NAME' (SHA-1 $SIGN_HASH)${SIGN_NOTE:+ $SIGN_NOTE}"
        echo "identity $SIGN_HASH $SIGN_NAME"
    else
        if [ "${MC_CODESIGN_IDENTITY:-}" = "-" ]; then
            log "signing: ad-hoc (forced by MC_CODESIGN_IDENTITY=-)"
        else
            log "signing: ad-hoc (no identity named '$IDENTITY_NAME'; permissions will be asked again after every changed build. Fix once: scripts/make_signing_identity.sh)"
        fi
        echo "adhoc"
    fi
    exit 0
fi

# --clean removes only what this script creates, never the whole build directory (other tools may use it).
if [ "$DO_CLEAN" = 1 ]; then
    log "cleaning $APP and $OBJ_DIR"
    rm -rf "$APP" "$OBJ_DIR"
    if [ "$CLEAN_ONLY" = 1 ]; then
        log "clean done"
        exit 0
    fi
fi

# Fail early (before the compile) when the identifier or the signature cannot be what the caller asked for.
BUNDLE_ID="${MCAP_BUNDLE_ID:-$MCAP_DEFAULT_BUNDLE_ID}"
mcap_valid_bundle_id "$BUNDLE_ID" || die "$(mcap_bundle_id_refusal MCAP_BUNDLE_ID "$BUNDLE_ID"). Nothing was built."
choose_signing

# --install replaces the installed app: with another id that is another app to macOS, so it is refused here, before the compile and before anything is replaced.
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_SHORT_NAME.app"
OLD_ID=""
if [ "$DO_INSTALL" = 1 ]; then
    OLD_ID="$(mcap_app_bundle_id "$DEST")"
    mcap_valid_bundle_id "$OLD_ID" || OLD_ID=""            # no app, or a damaged / foreign plist: nothing to compare with
    if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$BUNDLE_ID" ] && [ "${MCAP_ALLOW_ID_CHANGE:-0}" != 1 ]; then
        die "the installed app $DEST has the bundle id $OLD_ID, this build has $BUNDLE_ID. macOS sees a different app: Microphone, System Audio Recording and Notifications are asked again, and the login agent of $OLD_ID keeps starting the app. Build with MCAP_BUNDLE_ID=$OLD_ID to keep the id, or set MCAP_ALLOW_ID_CHANGE=1 to switch on purpose. Nothing was built or replaced."
    fi
    # The same id under another file name (an older build was called differently): macOS sees ONE app, so the two copies would share one login agent and
    # one set of permissions, and the agent would start whichever the label points at. No override: remove one of them, or install under the old name.
    SAME_ID_APPS="$(mcap_apps_with_bundle_id "$DEST_DIR" "$BUNDLE_ID")"
    while IFS= read -r other_app; do
        [ -n "$other_app" ] && [ "$other_app" != "$DEST" ] || continue
        die "$other_app already has this build's bundle id ($BUNDLE_ID), but this build would install to $DEST. Two apps with one id share one login agent and one set of permissions. Remove or rename the old one ($other_app), or set MCAP_APP_SHORT_NAME=$(basename "$other_app" .app) to keep installing under its name. Nothing was built or replaced."
    done <<< "$SAME_ID_APPS"
fi

# ---- tools -----------------------------------------------------------------------------------------
for tool in swiftc xcrun codesign plutil ditto sed; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (install the Xcode Command Line Tools)"
done
SDK="$(xcrun --sdk macosx --show-sdk-path)" || die "cannot locate the macOS SDK (xcode-select --install)"
[ -d "$SDK" ] || die "SDK directory does not exist: $SDK"

# ---- version ---------------------------------------------------------------------------------------
VERSION="${MCAP_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$PROJECT_DIR/VERSION" ]; then
    VERSION="$(head -n 1 "$PROJECT_DIR/VERSION" | tr -d '[:space:]')"
fi
VERSION="${VERSION:-0.1.0}"
echo "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}([-.+][A-Za-z0-9.]+)?$' || die "invalid version string: '$VERSION'"

# ---- build attribution (optional) ----------------------------------------------------------------------
# The same rules as StatusMenuController.normalizedBuiltBy (app/Sources/StatusMenu.swift), so the plist and the About panel agree: every
# run of spaces / control characters (newlines included) becomes one space, the ends are trimmed, a value longer than BUILT_BY_MAX
# characters is cut to BUILT_BY_MAX-1 and ends in an ellipsis. Called inside $(...): the locale change stays in that subshell.
BUILT_BY_MAX=80
normalize_built_by() {  # $1 = raw value; prints the single-line value (empty stays empty)
    local v
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || die "MCAP_BUILT_BY is not valid UTF-8"
    LC_ALL=en_US.UTF-8     # so ${#v} and ${v:0:n} count characters, not bytes (a Korean or accented name must not be cut in the middle)
    v="$(printf '%s' "$1" | tr '[:cntrl:]' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
    if [ "${#v}" -gt "$BUILT_BY_MAX" ]; then
        v="${v:0:$((BUILT_BY_MAX - 1))}"
        v="${v% }"$'\xe2\x80\xa6'
    fi
    printf '%s' "$v"
}
BUILT_BY="$(normalize_built_by "${MCAP_BUILT_BY:-}")" || exit 1
[ -z "$BUILT_BY" ] || log "built by: $BUILT_BY"

# ---- sources ---------------------------------------------------------------------------------------
[ -d "$SOURCES_DIR" ] || die "sources directory not found: $SOURCES_DIR"
[ -f "$SOURCES_DIR/main.swift" ] || die "$SOURCES_DIR/main.swift is missing"
[ -f "$PLIST_TEMPLATE" ] || die "Info.plist template not found: $PLIST_TEMPLATE"
SOURCES=()
for f in "$SOURCES_DIR"/*.swift; do
    [ -e "$f" ] && SOURCES+=("$f")
done
[ "${#SOURCES[@]}" -gt 0 ] || die "no .swift files in $SOURCES_DIR"
log "app $APP_NAME ($APP_SHORT_NAME.app), bundle id $BUNDLE_ID, version $VERSION, ${#SOURCES[@]} source files from $SOURCES_DIR"
log "SDK $SDK, target $TARGET"

# ---- compile ---------------------------------------------------------------------------------------
mkdir -p "$OBJ_DIR"
BIN="$OBJ_DIR/$APP_SHORT_NAME"
rm -f "$BIN"
swiftc -O \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    -module-name "$MODULE_NAME" \
    -framework AppKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Foundation \
    -framework ApplicationServices \
    -o "$BIN" \
    "${SOURCES[@]}" >&2
[ -x "$BIN" ] || die "compiler produced no executable"
ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
[ "$ARCHS" = "arm64" ] || die "unexpected architectures in binary: $ARCHS (expected arm64)"

# ---- assemble the bundle -----------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_SHORT_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_SHORT_NAME"

# the values are validated (no slash, ampersand or backslash in any of them), so they are safe in a sed replacement
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@APP_NAME@/$APP_NAME/g" -e "s/@APP_SHORT_NAME@/$APP_SHORT_NAME/g" "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"
if grep -Eq '@[A-Z_]+@' "$APP/Contents/Info.plist"; then
    die "unreplaced placeholder left in Info.plist: $(grep -Eo '@[A-Z_]+@' "$APP/Contents/Info.plist" | sort -u | tr '\n' ' ')"
fi
# Build attribution: plutil does the XML escaping (the value may hold & < > quotes), sed would not. It rewrites the plist
# (keys sorted, comments dropped), the same bytes for the same input. Without MCAP_BUILT_BY the plist is the template, nothing else.
if [ -n "$BUILT_BY" ]; then
    COPYRIGHT="$(plutil -extract NSHumanReadableCopyright raw -o - "$APP/Contents/Info.plist")" || die "Info.plist lacks NSHumanReadableCopyright"
    plutil -replace NSHumanReadableCopyright -string "$COPYRIGHT. Built by $BUILT_BY" "$APP/Contents/Info.plist" || die "cannot add the builder to Info.plist"
    plutil -insert MCBuiltBy -string "$BUILT_BY" "$APP/Contents/Info.plist" || die "cannot add MCBuiltBy to Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >&2 || die "Info.plist is not valid"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Required keys must be present (fails loudly if the template regresses).
for key in CFBundleIdentifier CFBundleExecutable CFBundleName CFBundleDisplayName CFBundleIconFile LSUIElement LSMinimumSystemVersion NSMicrophoneUsageDescription \
           NSAudioCaptureUsageDescription NSAppleEventsUsageDescription CFBundleShortVersionString NSHumanReadableCopyright; do
    plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 || die "Info.plist lacks required key $key"
done
# The public tree stays neutral: without MCAP_BUILT_BY nothing about a builder may be in the bundle (a template regression guard).
if [ -z "$BUILT_BY" ]; then
    ! plutil -extract MCBuiltBy raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 || die "Info.plist has MCBuiltBy although MCAP_BUILT_BY is empty"
    ! plutil -extract NSHumanReadableCopyright raw -o - "$APP/Contents/Info.plist" | grep -q 'Built by' || die "the copyright line names a builder although MCAP_BUILT_BY is empty"
elif [ "$(plutil -extract MCBuiltBy raw -o - "$APP/Contents/Info.plist")" != "$BUILT_BY" ]; then
    die "MCBuiltBy in Info.plist is not the requested value"
fi
[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || die "CFBundleIdentifier is not $BUNDLE_ID"
[ "$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")" = "$APP_SHORT_NAME" ] || die "CFBundleExecutable is not $APP_SHORT_NAME"
[ "$(plutil -extract CFBundleName raw -o - "$APP/Contents/Info.plist")" = "$APP_SHORT_NAME" ] || die "CFBundleName is not $APP_SHORT_NAME"
[ "$(plutil -extract CFBundleDisplayName raw -o - "$APP/Contents/Info.plist")" = "$APP_NAME" ] || die "CFBundleDisplayName is not $APP_NAME"

# ---- icon ---------------------------------------------------------------------------------------------
# CFBundleIconFile names the .icns inside Contents/Resources (with or without the extension). Without the file every notification
# of the app shows a blank generic icon, so a missing or undecodable icon fails the build instead of shipping a bundle that
# points at nothing. The check decodes the file with iconutil into a scratch directory (nothing else is touched).
ICON_NAME="$(plutil -extract CFBundleIconFile raw -o - "$APP/Contents/Info.plist")"
ICON_NAME="${ICON_NAME%.icns}"
case "$ICON_NAME" in
    ""|*/*|.*) die "CFBundleIconFile '$ICON_NAME' in Info.plist is not a plain file name" ;;
esac
[ -f "$ICON_FILE" ] || die "icon not found: $ICON_FILE (generate it: swiftc scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon app/Resources/AppIcon.icns)"
[ "$(head -c 4 "$ICON_FILE")" = "icns" ] || die "$ICON_FILE is not an .icns file"
command -v iconutil >/dev/null 2>&1 || die "required tool not found: iconutil (macOS ships it in /usr/bin)"
ICON_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-icon-check.XXXXXX")" || die "cannot create a temporary directory"
if ! iconutil -c iconset -o "$ICON_CHECK/check.iconset" "$ICON_FILE" >/dev/null 2>&1 \
        || [ ! -f "$ICON_CHECK/check.iconset/icon_16x16.png" ] || [ ! -f "$ICON_CHECK/check.iconset/icon_512x512@2x.png" ]; then
    rm -rf "$ICON_CHECK"
    die "$ICON_FILE does not decode with iconutil or lacks the 16 px / 512@2x images (regenerate it with scripts/make_icon.swift)"
fi
rm -rf "$ICON_CHECK"
cp "$ICON_FILE" "$APP/Contents/Resources/$ICON_NAME.icns"
chmod 644 "$APP/Contents/Resources/$ICON_NAME.icns"
log "icon: $ICON_NAME.icns ($(wc -c < "$APP/Contents/Resources/$ICON_NAME.icns" | tr -d ' ') bytes, from $ICON_FILE)"

# ---- sign (no hardened runtime) -----------------------------------------------------------------------
# designated requirement of a signed bundle (empty when it cannot be read)
designated_requirement() {  # $1 = bundle
    { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p' | head -n 1; } || true
}

if [ "$SIGN_MODE" = identity ]; then
    log "signing with identity '$SIGN_NAME' (SHA-1 $SIGN_HASH)${SIGN_NOTE:+ $SIGN_NOTE}"
    log "if macOS asks whether codesign may use the key '$SIGN_NAME': type your login password into THAT macOS dialog and choose Always Allow"
    if ! codesign --force --sign "$SIGN_ARG" --timestamp=none --identifier "$BUNDLE_ID" "$APP" >&2; then
        die "codesign failed with identity '$SIGN_NAME'. If it says the identity was not found or is not trusted, see scripts/make_signing_identity.sh --help (the --trust step); if it says the key is not accessible, unlock the login keychain and run again"
    fi
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >&2
fi
codesign --verify --strict --verbose=2 "$APP" >&2 || die "codesign --verify failed"
SIGINFO="$(codesign -dvvv "$APP" 2>&1)" || die "codesign -d failed"
echo "$SIGINFO" | grep -q "^Identifier=$BUNDLE_ID\$" || die "signature identifier is not $BUNDLE_ID"
if echo "$SIGINFO" | grep -Eq 'flags=0x[0-9a-f]+\(.*runtime'; then
    die "hardened runtime flag is set; it must not be (no --options runtime)"
fi
CDHASH="$(echo "$SIGINFO" | sed -n 's/^CDHash=//p' | head -n 1)"
[ -n "$CDHASH" ] || die "could not read the cdhash"
DESIGNATED="$(designated_requirement "$APP")"
if [ "$SIGN_MODE" = identity ]; then
    FIRST_AUTHORITY="$(echo "$SIGINFO" | sed -n 's/^Authority=//p' | head -n 1)"
    [ "$FIRST_AUTHORITY" = "$SIGN_NAME" ] || log "WARNING: the signature's first Authority is '${FIRST_AUTHORITY:-none}', expected '$SIGN_NAME'"
    case "$DESIGNATED" in
        cdhash*|"") log "WARNING: the designated requirement is '${DESIGNATED:-unreadable}', not tied to the certificate: macOS permissions will not survive a rebuild" ;;
    esac
    log "signed with identity '$SIGN_NAME' (SHA-1 $SIGN_HASH), identifier $BUNDLE_ID, cdhash $CDHASH"
else
    log "signed ad-hoc, identifier $BUNDLE_ID, cdhash $CDHASH"
    if [ "${MC_CODESIGN_IDENTITY:-}" != "-" ]; then
        log "ad-hoc: macOS asks for Microphone / System Audio Recording / Notifications again after every changed build. Create a fixed identity once: scripts/make_signing_identity.sh"
    fi
fi
log "designated requirement: ${DESIGNATED:-(unreadable)}"

# ---- optional install --------------------------------------------------------------------------------
# A new icon (or a first icon) is picked up by Finder / Notification Center only after Launch Services has looked at the bundle
# again. Safe version of "refresh the icon cache": touch the bundle (its modification time is what LS compares) and ask
# lsregister, at its standard path and for THIS bundle only (-f = register this path again), to re-read it. Never a global
# rebuild (-kill / -r), never killall. Skipped when HOME is not the account's real home (the script tests install into a fake
# HOME: registering that copy would put a test app into the real Launch Services database) and with MCAP_NO_LSREGISTER=1.
# Failure is only a warning: the app works without it, the icon then shows up after the next login.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
refresh_launch_services() {  # $1 = installed bundle
    local bundle="$1" real_home="" here=""
    touch "$bundle" 2>/dev/null || true
    if [ "${MCAP_NO_LSREGISTER:-0}" = 1 ]; then
        log "Launch Services refresh skipped (MCAP_NO_LSREGISTER=1)"
        return 0
    fi
    real_home="$(eval "printf '%s' ~$(id -un)" 2>/dev/null)" || real_home=""      # from the account database, not from $HOME
    if [ -n "$real_home" ]; then real_home="$(cd "$real_home" 2>/dev/null && pwd -P)" || real_home=""; fi
    here="$(cd "$HOME" 2>/dev/null && pwd -P)" || here=""
    if [ -z "$real_home" ] || [ "$here" != "$real_home" ]; then
        log "Launch Services refresh skipped: HOME ($HOME) is not this account's home directory"
        return 0
    fi
    if [ ! -x "$LSREGISTER" ]; then
        log "Launch Services refresh skipped: $LSREGISTER not found (the new icon appears after the next login)"
        return 0
    fi
    if "$LSREGISTER" -f "$bundle" >/dev/null 2>&1; then
        log "Launch Services re-read $bundle (icon cache refresh for this app only)"
    else
        log "WARNING: lsregister could not refresh $bundle; the new icon appears after the next login"
    fi
}

if [ "$DO_INSTALL" = 1 ]; then
    OLD_DESIGNATED=""
    [ ! -d "$DEST" ] || OLD_DESIGNATED="$(designated_requirement "$DEST" || true)"
    mkdir -p "$DEST_DIR"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"           # ditto keeps the code signature intact
    codesign --verify --strict --verbose=2 "$DEST" >&2 || die "installed copy fails codesign --verify"
    INSTALLED_HASH="$(codesign -dvvv "$DEST" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
    [ "$INSTALLED_HASH" = "$CDHASH" ] || die "installed cdhash $INSTALLED_HASH differs from built $CDHASH"
    log "installed $DEST"
    refresh_launch_services "$DEST"
    if [ -z "$OLD_DESIGNATED" ]; then
        log "first install of this app: macOS will ask for the permissions on the first run (Microphone, System Audio Recording, Google Drive, Notifications; scripts/install.sh prints the one-time setup step)"
    elif [ "$OLD_DESIGNATED" = "$DESIGNATED" ]; then
        log "designated requirement unchanged: the macOS permissions you already granted keep working"
    else
        log "designated requirement CHANGED (was: $OLD_DESIGNATED): macOS will ask for Microphone / System Audio Recording / Notifications once more (run the setup step again)"
    fi
    if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$BUNDLE_ID" ]; then
        log "WARNING: the bundle id changed ($OLD_ID -> $BUNDLE_ID). The login agent of the old id, if there is one, keeps starting this app next to the new one, and scripts/uninstall.sh only removes the agent of the installed id. Remove it: launchctl bootout gui/$(id -u)/$OLD_ID ; rm \"$HOME/Library/LaunchAgents/$OLD_ID.plist\""
    fi
    log "restart the running app (or the LaunchAgent) to use the new build"
fi

log "built $APP ($VERSION, arm64)"
echo "$APP"
