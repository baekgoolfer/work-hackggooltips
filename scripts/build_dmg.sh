#!/bin/bash
# Build the app installer: build/<short name>-<version>.dmg (CATE-<version>.dmg by default), ONE file that the person who installs it opens, drags the app out of, and starts.
#
#   scripts/build_dmg.sh [options]
#
#   --runtime FILE        the Python runtime archive (default: build/runtime/python-runtime.tar.gz, made by scripts/fetch_python_runtime.sh)
#   --lock FILE           the lock file the runtime is checked against (default: scripts/python-runtime.lock)
#   --out-dir DIR         where the dmg and its .sha256 file go (default: the build directory)
#   --hash-lock FILE      also put a hash lock of the Python packages into the app (scripts/make_hash_lock.sh makes one); the first-run helper then
#                         installs with  pip install --require-hashes --no-deps  (setup_python.sh --hash-lock). The lock must list EXACTLY the pins of
#                         pipeline/requirements.lock.txt (the same comparison as the helper's step 3: setup_python.sh --check-hash-lock): a lock that does not
#                         is a build problem, because every Mac that installs the image would refuse it and a re-run could not fix that. Make it for the bundled Python:
#                         scripts/make_hash_lock.sh --python-tag cp312. Without --hash-lock the pinned VERSIONS of pipeline/requirements.lock.txt are used, as
#                         in the personal install: nothing then checks the hashes of the ~0.55 GB of packages, and the plan and the build say so.
#   --require-hash-lock   fail instead of building without a hash lock (use it, like --require-identity, for every build you share)
#   --require-identity    fail instead of signing ad-hoc when there is no fixed signing identity (passed on to scripts/build_app.sh)
#   --dry-run             print the plan (version, signing, what goes where, what would stop the build); build and write nothing
#   -h, --help            this text
#
# stdout: one line, "<sha256>  <path of the dmg>" (the sha256 is also written to <dmg>.sha256). Progress and diagnostics go to stderr.
#
# What it does, in this order (docs/DISTRIBUTE.md):
#   1. Refuses while python-runtime.lock has a PENDING value, while the runtime archive is missing or does not have the checksum of the lock.
#   2. Runs scripts/build_app.sh (same signing identity rules: MC_CODESIGN_IDENTITY, the identity named "MeetingCapture Local Signing", else ad-hoc;
#      MCAP_BUILT_BY, MCAP_BUNDLE_ID, MCAP_APP_NAME, MCAP_APP_SHORT_NAME, MCAP_VERSION and MCAP_BUILD_DIR are passed through) and copies the built app to
#      <build dir>/dmg-stage/.
#   3. Assembles the layout BEFORE signing, inside <short name>.app/Contents/Resources:
#        mcap/pipeline/mcap/                 the Python package (no tests, no bytecode) and the requirement files
#        mcap/config/                        the prompts, the example vocabulary and config.env.example
#        mcap/scripts/                       setup_python.sh, first_run_install.sh, legal_notice.sh, bundle_id.sh (the helpers read the names of the app from it)
#        mcap/VERSION, mcap/components.json  {"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":...},"requirements_lock_sha256":...}
#        runtime/python-runtime.tar.gz       the Python runtime (python-build-standalone, CPython 3.12, aarch64-apple-darwin)
#   4. Signs every nested Mach-O file inside the bundle (none is expected: the Python runtime is an archive until the first-run helper unpacks it) and
#      then the app, with the SAME identity as build_app.sh (no hardened runtime), and verifies the signature.
#   5. Creates the dmg with hdiutil (UDZO, volume name = the human name of the app, an /Applications link, README-install.txt) and prints its sha256.
#      README-install.txt is dmg/README-install.txt with the two names filled in (@APP_NAME@, @APP_SHORT_NAME@), so it names the file that is really in the image.
# It never notarizes (no plan or date: Apple Developer ID is described in docs/DISTRIBUTE.md section 9), never installs anything and never touches the keychain
# (build_app.sh only lists the signing identities).
#
# Environment: MCAP_BUILD_DIR, MCAP_BUILT_BY, MCAP_BUNDLE_ID, MCAP_APP_NAME, MCAP_APP_SHORT_NAME, MCAP_VERSION, MC_CODESIGN_IDENTITY (all as for build_app.sh); MCAP_DMG_SRC_ROOT = the folder that holds
# pipeline/, config/, VERSION and dmg/ (default: this repository; for tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="${MCAP_DMG_SRC_ROOT:-$PROJECT_DIR}"
BUILD_DIR="${MCAP_BUILD_DIR:-$PROJECT_DIR/build}"
LOCK="$SCRIPT_DIR/python-runtime.lock"
RUNTIME=""
OUT_DIR=""
HASH_LOCK=""
REQUIRE_HASH_LOCK=0
REQUIRE_IDENTITY=0
DRY_RUN=0
DIED=0

# What goes into the app, one list for the plan, the copy and the check (names relative to SRC_ROOT / SCRIPT_DIR).
PIPELINE_FILES="requirements.lock.txt requirements-silero.txt requirements.client.txt"
CONFIG_FILES="note_prompt.md cleanup_prompt.md verify_prompt.md vocabulary.txt config.env.example"
SCRIPT_FILES="setup_python.sh first_run_install.sh legal_notice.sh bundle_id.sh"

log()  { echo "[build_dmg] $*" >&2; }
die()  { DIED=1; echo "[build_dmg] ERROR: $*" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}" >&2; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[build_dmg] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) [ $# -ge 2 ] || die "--runtime needs a file" 2; RUNTIME="$2"; shift ;;
        --lock) [ $# -ge 2 ] || die "--lock needs a file" 2; LOCK="$2"; shift ;;
        --out-dir) [ $# -ge 2 ] || die "--out-dir needs a directory" 2; OUT_DIR="$2"; shift ;;
        --hash-lock) [ $# -ge 2 ] || die "--hash-lock needs a file" 2; HASH_LOCK="$2"; shift ;;
        --require-hash-lock) REQUIRE_HASH_LOCK=1 ;;
        --require-identity) REQUIRE_IDENTITY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

case "$BUILD_DIR" in
    /*) ;;
    *) BUILD_DIR="$PWD/$BUILD_DIR" ;;
esac
BUILD_DIR="${BUILD_DIR%/}"
[ -n "$RUNTIME" ] || RUNTIME="$BUILD_DIR/runtime/python-runtime.tar.gz"
[ -n "$OUT_DIR" ] || OUT_DIR="$BUILD_DIR"
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
OUT_DIR="${OUT_DIR%/}"
export MCAP_BUILD_DIR="$BUILD_DIR"          # build_app.sh builds into the same directory
BUNDLE_ID="$(mcap_resolve_bundle_id)" || die "the bundle identifier is refused (see above); nothing was built" 2     # as build_app.sh reads it; after the build it is read back from the app
APP_NAME="$(mcap_resolve_app_name)" || die "the app name is refused (see above); nothing was built" 2                 # the same for the two names: the volume and the README carry
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above); nothing was built" 2   # the first, the file names the second
VOLUME_NAME="$APP_NAME"

# ---- version (the same rules as build_app.sh) -------------------------------------------------------------
VERSION="${MCAP_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$SRC_ROOT/VERSION" ]; then
    VERSION="$(head -n 1 "$SRC_ROOT/VERSION" | tr -d '[:space:]')"
fi
VERSION="${VERSION:-0.1.0}"
echo "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}([-.+][A-Za-z0-9.]+)?$' || die "invalid version string: '$VERSION'" 2
DMG="$OUT_DIR/$APP_SHORT_NAME-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"
APP_STAGED="$STAGE/$APP_SHORT_NAME.app"

sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
lock_value() {  # $1 = key: the value of the last KEY=value line of the lock file; empty when missing
    { grep -E "^$1=" "$LOCK" || true; } | tail -n 1 | sed -e "s/^$1=//" -e 's/[[:space:]]*$//'
}

# ---- what would stop the build (collected: the plan lists them all, a real run stops at the first look) -----------------------
PROBLEMS=""
problem() { PROBLEMS="${PROBLEMS}${PROBLEMS:+
}$1"; }

LOCK_SHA=""
if [ ! -f "$LOCK" ]; then
    problem "lock file not found: $LOCK"
else
    LOCK_URL="$(lock_value URL)"
    LOCK_SHA="$(lock_value SHA256 | tr 'A-F' 'a-f')"
    PENDING=""
    { [ -n "$LOCK_URL" ] && [ "$LOCK_URL" != PENDING ]; } || PENDING="URL"
    { [ -n "$LOCK_SHA" ] && [ "$LOCK_SHA" != PENDING ]; } || PENDING="${PENDING:+$PENDING and }SHA256"
    if [ -n "$PENDING" ]; then
        problem "$LOCK still has $PENDING=PENDING (or empty): fill it in once (docs/DISTRIBUTE.md section 2), then run scripts/fetch_python_runtime.sh --out-dir $(dirname "$RUNTIME")"
        LOCK_SHA=""
    elif ! printf '%s' "$LOCK_SHA" | grep -Eq '^[0-9a-f]{64}$'; then
        problem "SHA256 in $LOCK is not 64 hexadecimal digits"
        LOCK_SHA=""
    fi
fi
RUNTIME_SHA=""
if [ ! -f "$RUNTIME" ]; then
    problem "the Python runtime archive is missing: $RUNTIME (download it with scripts/fetch_python_runtime.sh --out-dir $(dirname "$RUNTIME"), docs/DISTRIBUTE.md section 2)"
else
    RUNTIME_SHA="$(sha256_of "$RUNTIME")"
    if [ -n "$LOCK_SHA" ] && [ "$RUNTIME_SHA" != "$LOCK_SHA" ]; then
        problem "the sha256 of $RUNTIME ($RUNTIME_SHA) is not the one in $LOCK ($LOCK_SHA): download it again with scripts/fetch_python_runtime.sh, which checks the checksum"
    fi
fi
if [ -n "$HASH_LOCK" ]; then
    if [ ! -f "$HASH_LOCK" ]; then problem "--hash-lock: not a file: $HASH_LOCK"
    elif ! grep -q -- '--hash=sha256:' "$HASH_LOCK"; then problem "--hash-lock: $HASH_LOCK has no --hash=sha256: line: it is not a hash lock (scripts/make_hash_lock.sh makes one)"
    elif [ -f "$SRC_ROOT/pipeline/requirements.lock.txt" ] && [ -f "$SCRIPT_DIR/setup_python.sh" ]; then
        # the comparison that step 3 of the helper makes on every Mac that installs the image (setup_python.sh check_hash_lock), made here while it can still be fixed
        if ! HL_DIFF="$(/bin/bash "$SCRIPT_DIR/setup_python.sh" --check-hash-lock "$SRC_ROOT/pipeline/requirements.lock.txt" "$HASH_LOCK" 2>&1)"; then
            HL_DIFF="$(printf '%s\n' "$HL_DIFF" | grep -E '^  ' | sed 's/^ *//' | head -n 5 | tr '\n' ';' | sed 's/;$//')"
            problem "--hash-lock: $HASH_LOCK does not list exactly the pins of $SRC_ROOT/pipeline/requirements.lock.txt, so the helper's step 3 would refuse it on every Mac and a re-run could not fix that (${HL_DIFF:-see setup_python.sh --check-hash-lock}). Make the lock again after a version change: scripts/make_hash_lock.sh --python-tag cp312"
        fi
    fi
elif [ "$REQUIRE_HASH_LOCK" = 1 ]; then
    problem "--require-hash-lock: no --hash-lock FILE was given (scripts/make_hash_lock.sh --python-tag cp312 --apply makes one; docs/DISTRIBUTE.md section 4)"
fi
for f in $PIPELINE_FILES; do [ -f "$SRC_ROOT/pipeline/$f" ] || problem "missing $SRC_ROOT/pipeline/$f"; done
[ -d "$SRC_ROOT/pipeline/mcap" ] || problem "missing $SRC_ROOT/pipeline/mcap"
for f in $CONFIG_FILES; do [ -f "$SRC_ROOT/config/$f" ] || problem "missing $SRC_ROOT/config/$f"; done
for f in $SCRIPT_FILES; do [ -f "$SCRIPT_DIR/$f" ] || problem "missing $SCRIPT_DIR/$f"; done
[ -f "$SRC_ROOT/dmg/README-install.txt" ] || problem "missing $SRC_ROOT/dmg/README-install.txt"
[ -x "$SCRIPT_DIR/build_app.sh" ] || problem "missing or not executable: $SCRIPT_DIR/build_app.sh"

# ---- the signing identity: exactly what build_app.sh would use (it only LISTS the identities; it never creates or changes one) ----
SIGN_MODE=""; SIGN_ARG="-"; SIGN_HASH=""; SIGN_NAME=""
BUILD_APP_ARGS=()
[ "$REQUIRE_IDENTITY" != 1 ] || BUILD_APP_ARGS+=(--require-identity)
if [ -x "$SCRIPT_DIR/build_app.sh" ]; then
    if SIGN_LINE="$("$SCRIPT_DIR/build_app.sh" --print-signing ${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"} 2>/dev/null | tail -n 1)" && [ -n "$SIGN_LINE" ]; then
        case "$SIGN_LINE" in
            adhoc) SIGN_MODE="adhoc" ;;
            "identity "*) SIGN_MODE="identity"; SIGN_HASH="$(printf '%s' "$SIGN_LINE" | awk '{ print $2 }')"; SIGN_NAME="${SIGN_LINE#identity * }"; SIGN_ARG="$SIGN_HASH" ;;
            *) problem "scripts/build_app.sh --print-signing printed something unexpected: $SIGN_LINE" ;;
        esac
    else
        problem "scripts/build_app.sh --print-signing failed (run it by hand to see why; with --require-identity it needs the identity from scripts/make_signing_identity.sh)"
    fi
fi

# ---- the plan --------------------------------------------------------------------------------------------------
print_plan() {
    echo "Plan (nothing is built or written in a dry run)"
    echo "  version       : $VERSION"
    echo "  bundle id     : $BUNDLE_ID (MCAP_BUNDLE_ID, default $MCAP_DEFAULT_BUNDLE_ID): Info.plist, the signature identifier; macOS keys its permissions to it"
    echo "  app names     : $APP_NAME (MCAP_APP_NAME, default $MCAP_DEFAULT_APP_NAME), file name $APP_SHORT_NAME.app (MCAP_APP_SHORT_NAME, default $MCAP_DEFAULT_APP_SHORT_NAME)"
    echo "  app           : $BUILD_DIR/$APP_SHORT_NAME.app (scripts/build_app.sh), staged copy $APP_STAGED"
    case "$SIGN_MODE" in
        identity) echo "  signing       : identity '$SIGN_NAME' (SHA-1 $SIGN_HASH), every nested Mach-O file and then the app, no hardened runtime" ;;
        adhoc)    echo "  signing       : ad-hoc (no fixed identity): macOS asks for the permissions again after every changed build; scripts/make_signing_identity.sh makes one" ;;
        *)        echo "  signing       : unknown (see the problem list)" ;;
    esac
    echo "  built by      : ${MCAP_BUILT_BY:-(not set: the bundle names no builder)}"
    echo "  runtime       : $RUNTIME${RUNTIME_SHA:+ (sha256 $RUNTIME_SHA)}"
    echo "  lock file     : $LOCK"
    echo "  layout        : Contents/Resources/mcap/{pipeline/mcap, pipeline/{${PIPELINE_FILES// /,}}, config/{${CONFIG_FILES// /,}}, scripts/{${SCRIPT_FILES// /,}}, VERSION, components.json}"
    echo "                  Contents/Resources/runtime/python-runtime.tar.gz"
    if [ -n "$HASH_LOCK" ]; then
        echo "                  mcap/pipeline/requirements.hash-lock.txt (from $HASH_LOCK)"
        echo "  hash lock     : $HASH_LOCK (compared with pipeline/requirements.lock.txt at build time: the helper installs with pip --require-hashes)"
    else
        echo "  hash lock     : NONE: version pins only, nothing checks the hashes of the ~0.55 GB of packages that everybody who installs it downloads (make hash-lock, then --hash-lock FILE; --require-hash-lock makes this an error)"
    fi
    echo "  dmg           : $DMG (UDZO, volume '$VOLUME_NAME', /Applications link, README-install.txt) and $DMG.sha256"
    echo "  not done here : notarization (docs/DISTRIBUTE.md section 9), upload, the test on a second Mac (docs/DISTRIBUTE.md)"
}

if [ "$DRY_RUN" = 1 ]; then
    print_plan
    if [ -n "$PROBLEMS" ]; then
        echo
        echo "A real run would stop here:"
        printf '%s\n' "$PROBLEMS" | sed 's/^/  - /'
    fi
    echo
    echo "dry run: nothing was built or written"
    exit 0
fi

if [ -n "$PROBLEMS" ]; then
    echo "[build_dmg] ERROR: the build cannot start. Nothing was built or written:" >&2
    printf '%s\n' "$PROBLEMS" | sed 's/^/  - /' >&2
    DIED=1
    exit 2
fi
[ -n "$HASH_LOCK" ] || log "WARNING: no --hash-lock: the packages are installed by version only, nothing checks their hashes (docs/DISTRIBUTE.md section 4; --require-hash-lock makes this an error)"
for tool in hdiutil codesign ditto plutil shasum tar find awk od sort; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
SIGN_LABEL="$SIGN_MODE"
[ -z "$SIGN_NAME" ] || SIGN_LABEL="$SIGN_MODE '$SIGN_NAME'"
log "version $VERSION, signing: $SIGN_LABEL"

# ---- 1. the app ------------------------------------------------------------------------------------------------
log "building the app with scripts/build_app.sh"
BUILT_APP="$("$SCRIPT_DIR/build_app.sh" ${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"} | tail -n 1)" || die "scripts/build_app.sh failed (see above)"
[ -d "$BUILT_APP" ] || die "build_app.sh did not report a built app (got: $BUILT_APP)"
BUNDLE_ID="$(mcap_resolve_bundle_id "$BUILT_APP")" || die "the built app has no valid CFBundleIdentifier"     # the app's own identifier is what the signature must name
[ "$(mcap_resolve_app_short_name "$BUILT_APP")" = "$APP_SHORT_NAME" ] && [ "$(mcap_resolve_app_name "$BUILT_APP")" = "$APP_NAME" ] \
    || die "the built app does not carry the names this script resolved ($APP_NAME, $APP_SHORT_NAME): the volume and the README would name another app"

# ---- 2. stage: a copy of the app, so the plain build stays a plain build ----------------------------------------------
case "$STAGE" in
    */dmg-stage) ;;
    *) die "refusing to clean a directory that is not named dmg-stage: $STAGE" ;;
esac
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --noextattr --noqtn --norsrc "$BUILT_APP" "$APP_STAGED"

# ---- 3. the layout, before signing -------------------------------------------------------------------------------
RES="$APP_STAGED/Contents/Resources"
MCAP="$RES/mcap"
log "assembling Contents/Resources/mcap and runtime"
mkdir -p "$MCAP/pipeline" "$MCAP/config" "$MCAP/scripts" "$RES/runtime"
COPYFILE_DISABLE=1 tar -cf - --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' --exclude='tests' -C "$SRC_ROOT/pipeline" mcap \
    | tar -xf - -C "$MCAP/pipeline"
for f in $PIPELINE_FILES; do cp "$SRC_ROOT/pipeline/$f" "$MCAP/pipeline/$f"; done
[ -z "$HASH_LOCK" ] || cp "$HASH_LOCK" "$MCAP/pipeline/requirements.hash-lock.txt"
for f in $CONFIG_FILES; do cp "$SRC_ROOT/config/$f" "$MCAP/config/$f"; done
for f in $SCRIPT_FILES; do cp "$SCRIPT_DIR/$f" "$MCAP/scripts/$f"; done
printf '%s\n' "$VERSION" > "$MCAP/VERSION"
cp "$RUNTIME" "$RES/runtime/python-runtime.tar.gz"
LOCK_REQ_SHA="$(sha256_of "$MCAP/pipeline/requirements.lock.txt")"
printf '{"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$RUNTIME_SHA" "$LOCK_REQ_SHA" > "$MCAP/components.json"
# plutil reads JSON (its -lint option does not): read the two hashes back, the way the first-run helper will
[ "$(plutil -extract python_runtime.sha256 raw -o - "$MCAP/components.json" 2>/dev/null)" = "$RUNTIME_SHA" ] || die "components.json is not valid JSON or does not carry the sha256 of the runtime"
[ "$(plutil -extract requirements_lock_sha256 raw -o - "$MCAP/components.json" 2>/dev/null)" = "$LOCK_REQ_SHA" ] || die "components.json does not carry the sha256 of the requirements lock"
# modes do not depend on the umask of this shell: folders 755, files 644, the three scripts 755
find "$MCAP" "$RES/runtime" -type d -exec chmod 755 {} +
find "$MCAP" "$RES/runtime" -type f -exec chmod 644 {} +
for f in $SCRIPT_FILES; do chmod 755 "$MCAP/scripts/$f"; done
LEFTOVER="$(find "$MCAP" \( -name '__pycache__' -o -name '*.pyc' -o -name '.DS_Store' \) -print)"
[ -z "$LEFTOVER" ] || die "bytecode or Finder files ended up in the bundle (the signature would break when Python writes next to them): $LEFTOVER"

# ---- 4. sign: every nested Mach-O file first, then the app, with the identity build_app.sh used -------------------------------
is_macho() {  # $1 = file; exit 0 when it starts with a Mach-O or universal-binary magic number
    case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
        cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
    esac
    return 1
}

sign_one() {  # $1 = path
    if [ "$SIGN_MODE" = identity ]; then
        codesign --force --sign "$SIGN_ARG" --timestamp=none "$@" >&2
    else
        codesign --force --sign - "$@" >&2
    fi
}

NESTED_LIST="$STAGE/.nested-macho.txt"
: > "$NESTED_LIST"
find "$APP_STAGED/Contents" -type f ! -path "$APP_STAGED/Contents/MacOS/$APP_SHORT_NAME" | while IFS= read -r f; do
    if is_macho "$f"; then printf '%s\n' "$f" >> "$NESTED_LIST"; fi
done
NESTED_COUNT="$(grep -c . "$NESTED_LIST" || true)"
log "nested Mach-O files to sign: $NESTED_COUNT"
if [ "$NESTED_COUNT" -gt 0 ]; then
    # deepest paths first (a nested file is signed before whatever contains it)
    awk '{ n = gsub("/", "/"); print n "\t" $0 }' "$NESTED_LIST" | sort -rn | cut -f2- | while IFS= read -r f; do
        log "signing nested $f"
        sign_one "$f" || exit 1
    done || die "signing a nested Mach-O file failed (see above)"
fi
rm -f "$NESTED_LIST"

if [ "$SIGN_MODE" = identity ]; then
    log "signing $APP_SHORT_NAME.app with identity '$SIGN_NAME' (SHA-1 $SIGN_HASH)"
    log "if macOS asks whether codesign may use the key '$SIGN_NAME': type your login password into THAT macOS dialog and choose Always Allow"
fi
sign_one --identifier "$BUNDLE_ID" "$APP_STAGED" || die "codesign failed for the app"
codesign --verify --strict --verbose=2 "$APP_STAGED" >&2 || die "codesign --verify failed for the staged app"
SIGINFO="$(codesign -dvvv "$APP_STAGED" 2>&1)" || die "codesign -d failed"
echo "$SIGINFO" | grep -q "^Identifier=$BUNDLE_ID\$" || die "signature identifier is not $BUNDLE_ID"
if echo "$SIGINFO" | grep -Eq 'flags=0x[0-9a-f]+\(.*runtime'; then die "hardened runtime flag is set; it must not be"; fi
DESIGNATED="$({ codesign -d -r- "$APP_STAGED" 2>&1 | sed -n 's/^#* *designated => //p' | head -n 1; } || true)"
log "signed ($SIGN_MODE), designated requirement: ${DESIGNATED:-(unreadable)}"
if [ "$SIGN_MODE" = identity ]; then
    case "$DESIGNATED" in
        cdhash*|"") log "WARNING: the designated requirement is '${DESIGNATED:-unreadable}', not tied to the certificate: macOS permissions will not survive an update" ;;
    esac
fi

# ---- 5. the disk image --------------------------------------------------------------------------------------------
DMG_ROOT="$STAGE/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP_STAGED" "$DMG_ROOT/$APP_SHORT_NAME.app"          # a copy that keeps the signature; the staged app stays for inspection
ln -s /Applications "$DMG_ROOT/Applications"
# the template carries @APP_NAME@ and @APP_SHORT_NAME@; the names are validated (no slash, ampersand or backslash), so they are safe in sed
sed -e "s/@APP_NAME@/$APP_NAME/g" -e "s/@APP_SHORT_NAME@/$APP_SHORT_NAME/g" "$SRC_ROOT/dmg/README-install.txt" > "$DMG_ROOT/README-install.txt"
! grep -Eq '@[A-Z_]+@' "$DMG_ROOT/README-install.txt" || die "an unreplaced placeholder is left in README-install.txt: $(grep -Eo '@[A-Z_]+@' "$DMG_ROOT/README-install.txt" | sort -u | tr '\n' ' ')"
chmod 644 "$DMG_ROOT/README-install.txt"
codesign --verify --strict --verbose=2 "$DMG_ROOT/$APP_SHORT_NAME.app" >&2 || die "the copy of the app inside the disk image folder fails codesign --verify"
mkdir -p "$OUT_DIR"
rm -f "$DMG" "$DMG.sha256"
log "creating $DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov -quiet "$DMG" >&2 || die "hdiutil create failed"
[ -f "$DMG" ] || die "hdiutil reported success but $DMG does not exist"
hdiutil verify -quiet "$DMG" >&2 || die "hdiutil verify failed for $DMG"
DMG_SHA="$(sha256_of "$DMG")"
printf '%s  %s\n' "$DMG_SHA" "$(basename "$DMG")" > "$DMG.sha256"
rm -rf "$DMG_ROOT"
log "dmg sha256: $DMG_SHA ($(wc -c < "$DMG" | tr -d ' ') bytes)"
log "next: test it on a second Mac (docs/DISTRIBUTE.md section 7), then share the .dmg and the sha256 through the file host you chose (docs/DISTRIBUTE.md section 6)"
echo "$DMG_SHA  $DMG"
