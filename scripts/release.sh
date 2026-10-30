#!/bin/bash
# Build the release assets of the app on this Mac, the same way .github/workflows/release.yml does. Publishes NOTHING: no push,
# no gh, no network, no keychain, no notarization. The workflow calls this script and only uploads what it wrote.
#
#   scripts/release.sh [options]
#
#   --version X.Y.Z[-pre]  version to build. Default: the VERSION file, else __version__ in pipeline/mcap/__init__.py. It must equal
#                          the version of the tree (those two must agree with each other when both exist).
#   --tag vX.Y.Z[-pre]     the git tag being released (the workflow passes it). Must equal v<version>, exist in this clone and point at
#                          HEAD, and the tree must have a LICENSE file. Without --tag a missing LICENSE is only a warning. A tag run also
#                          stops while a placeholder of the first release is left: the clone address in the install steps of the READMEs,
#                          CONTRIBUTING and INSTALL, or the undated CHANGELOG heading.
#   --out DIR              where the assets go (default: build/release; only the files named below are replaced in it)
#   --dry-run              run every check, print what would be built, build nothing
#   --scan-only            run only the publish-safety scan of the files (works on Linux, no Xcode needed; CI runs it on every push)
#   --skip-app             no app zip (without it: the zip is built on an Apple silicon Mac; elsewhere it is skipped with a warning, but a --tag run stops)
#   --skip-source          no source tarball (the tarball needs a git clone with at least one commit)
#   -h, --help             this text
#
# Assets, written to --out:
#   <short name>-<version>-macos-arm64-adhoc.zip     <short name>.app (CATE.app by default), signed AD-HOC (MC_CODESIGN_IDENTITY=-), NOT notarized, with the licence
#                                                    files and a README-FIRST.txt (Gatekeeper steps). Built by scripts/build_app.sh into a
#                                                    temporary directory, so ./build is not touched. After zipping, the zip is unpacked and
#                                                    codesign --verify is run on the copy.
#   meeting-capture-<version>-source.tar.gz          git archive of HEAD (committed files only; uncommitted changes are NOT in it)
#   SHA256SUMS                                       SHA-256 of the files above (check with: shasum -a 256 -c SHA256SUMS)
#   RELEASE_NOTES.md                                 release notes: the CHANGELOG.md section of this version if there is one, then what the
#                                                    files are and the Gatekeeper / quarantine steps. NOT an asset, the body of the release.
#
# The scan (always runs first, a finding stops the script): secret-shaped strings (key prefixes, private key blocks), absolute home
# directories of real people (/Users/<name>/), agent scratch paths, and Google Drive folders that name a concrete mailbox. It reports
# file:line and the kind, NEVER the matching text. Personal strings that cannot be written into this public file (your name, e-mail
# address, company terms) go into a private file of extended regular expressions, one per line, that you pass in the environment:
#   MCAP_SCAN_DENYLIST=/path/to/private-patterns.txt scripts/release.sh --scan-only
# Environment: MCAP_BUNDLE_ID is passed on to scripts/build_app.sh (a fork releases its own reverse-DNS id; unset: org.meetingcapture.app, the neutral one) and
# checked in the zip; MCAP_APP_NAME and MCAP_APP_SHORT_NAME the same way (unset: "Catch Everything" and CATE; the short name is the app folder and the file
# name of the zip). MCAP_RELEASE_SKIP_SCAN=1 skips the scan (only for testing this script on a tree that is known to be unclean; never in CI).
#
# Needs: bash, git (tarball, tag check), shasum or sha256sum, and for the app zip an Apple silicon Mac with swiftc, codesign, plutil, ditto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="meeting-capture"            # prefix of the source tarball
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
APP_NAME="$(mcap_resolve_app_name)" || { echo "[release] ERROR: the app name is refused (see above)" >&2; exit 1; }                     # what build_app.sh will use
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || { echo "[release] ERROR: the short app name is refused (see above)" >&2; exit 1; }
BUNDLE_ID="$(mcap_resolve_bundle_id)" || { echo "[release] ERROR: the bundle identifier is refused (see above)" >&2; exit 1; }     # MCAP_BUNDLE_ID or the default: what build_app.sh will use
# Not findings: placeholder users in docs and tests; PEM headers in three test files that hold fakes only: throw-away TLS keys that
# protect nothing (net_guard_support.py), a redaction canary (test_apikey_hardening.py, body "CANARYPEMBODY") and a stub with the
# body "MIIBstub" (test_install_server_linux.sh). A new real-looking key anywhere else is a finding.
HOME_PLACEHOLDERS='/Users/(alice|bob|someone|user|you|name|username|me|runner|Shared|Guest|example)/$'
KEY_FIXTURE_OK='^(\./)?(pipeline/tests/(net_guard_support|test_apikey_hardening)\.py|scripts/asr_server/test_install_server_linux\.sh):'

export LC_ALL=C                   # byte-wise grep: Korean text is not "binary", and the patterns mean the same on macOS and Linux

log()  { echo "[release] $*" >&2; }
warn() { echo "[release] WARNING: $*" >&2; }
die()  { echo "[release] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

WORK=""
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; return 0; }
trap cleanup EXIT

VERSION_ARG=""; TAG=""; OUT=""; DRY_RUN=0; SCAN_ONLY=0; SKIP_APP=0; SKIP_SOURCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION_ARG="$2"; shift ;;
        --tag)     [ $# -ge 2 ] || die "--tag needs a value"; TAG="$2"; shift ;;
        --out)     [ $# -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        --scan-only) SCAN_ONLY=1 ;;
        --skip-app) SKIP_APP=1 ;;
        --skip-source) SKIP_SOURCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$OUT" ] || OUT="$PROJECT_DIR/build/release"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-release.XXXXXX")" || die "cannot create a temporary directory"
cd "$PROJECT_DIR"

# ---- scan -------------------------------------------------------------------------------------------------------
FILES0="$WORK/files0"     # NUL-separated paths that would be published
FINDINGS=0
list_files() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -z --cached --others --exclude-standard
    else
        find . \( -name .git -o -name build -o -name venv -o -name .venv -o -name __pycache__ \) -prune -o -type f -print0
    fi
}
# scan_with <kind> <regex of findings to ignore, matched against "path:line:matched text"> <grep options...>
scan_with() {
    local kind="$1" ignore="$2" found line
    shift 2
    # /dev/null keeps grep off stdin when xargs has nothing to pass; this script itself is not scanned (it names the patterns)
    found="$(xargs -0 grep -sHIno "$@" /dev/null < "$FILES0" | grep -vE "$ignore" | grep -vE '^(\./)?scripts/release\.sh:' | cut -d: -f1,2 | sort -u || true)"
    if [ -n "$found" ]; then
        while IFS= read -r line; do
            echo "[release] FOUND $kind: $line" >&2
            FINDINGS=$((FINDINGS + 1))
        done <<EOF
$found
EOF
    fi
}
scan_tree() {
    list_files > "$FILES0"
    log "scan: $(tr -cd '\0' < "$FILES0" | wc -c | tr -d ' ') files"
    scan_with "private key block" "$KEY_FIXTURE_OK" -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    scan_with "Anthropic API key" '^$' -E -e 'sk-ant-[A-Za-z0-9_-]{60,}'
    scan_with "OpenAI-style API key" '^$' -E -e 'sk-[A-Za-z0-9]{40,}'
    scan_with "GitHub token" '^$' -E -e '(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})'
    scan_with "AWS access key id" '^$' -E -e 'AKIA[0-9A-Z]{16}'
    scan_with "Slack token" '^$' -E -e 'xox[abprs]-[A-Za-z0-9-]{10,}'
    scan_with "Google API key" '^$' -E -e 'AIza[0-9A-Za-z_-]{35}'
    scan_with "Hugging Face token" '^$' -E -e 'hf_[A-Za-z0-9]{34,}'
    scan_with "home directory of a real person" "$HOME_PLACEHOLDERS" -E -e '/Users/[A-Za-z0-9._-]+/'
    scan_with "agent scratch path" '^$' -E -e '(claude-[0-9]{3}/|scratch-w[o]rkspaces)'
    scan_with "Google Drive folder of a concrete mailbox" '@example\.[A-Za-z.]*$' -E -i -e 'GoogleDrive-[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+'
    if [ -n "${MCAP_SCAN_DENYLIST:-}" ]; then
        [ -f "$MCAP_SCAN_DENYLIST" ] || die "MCAP_SCAN_DENYLIST is not a file: $MCAP_SCAN_DENYLIST"
        grep -vE '^[[:space:]]*(#|$)' "$MCAP_SCAN_DENYLIST" > "$WORK/denylist" || true
        if [ -s "$WORK/denylist" ]; then
            scan_with "private denylist pattern" '^$' -E -i -f "$WORK/denylist"
        fi
    fi
    if [ "$FINDINGS" -gt 0 ]; then
        die "scan: $FINDINGS finding(s) above (file:line and kind only). Remove or replace the value. A deliberate test fixture needs a narrow allow rule at the top of this script, with the reason."
    fi
    log "scan: clean"
}
if [ "${MCAP_RELEASE_SKIP_SCAN:-0}" = 1 ]; then
    warn "MCAP_RELEASE_SKIP_SCAN=1: the publish-safety scan is skipped"
else
    scan_tree
fi
if [ "$SCAN_ONLY" = 1 ]; then exit 0; fi

# ---- version, tag, licence ----------------------------------------------------------------------------------------
FILE_VERSION=""
if [ -f VERSION ]; then FILE_VERSION="$(head -n 1 VERSION | tr -d '[:space:]')"; fi
PY_VERSION="$(sed -n 's/^__version__ = "\([^"]*\)".*$/\1/p' pipeline/mcap/__init__.py 2>/dev/null | head -n 1 || true)"
if [ -n "$FILE_VERSION" ] && [ -n "$PY_VERSION" ] && [ "$FILE_VERSION" != "$PY_VERSION" ]; then
    die "VERSION says $FILE_VERSION but pipeline/mcap/__init__.py says $PY_VERSION: make them equal first"
fi
TREE_VERSION="${FILE_VERSION:-$PY_VERSION}"
[ -n "$TREE_VERSION" ] || die "cannot tell the version of the tree (no VERSION file, no __version__)"
VERSION="$VERSION_ARG"
if [ -z "$VERSION" ] && [ -n "$TAG" ]; then VERSION="${TAG#v}"; fi
[ -n "$VERSION" ] || VERSION="$TREE_VERSION"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "version '$VERSION' is not X.Y.Z or X.Y.Z-pre"
[ "$VERSION" = "$TREE_VERSION" ] || die "version $VERSION differs from the version of the tree ($TREE_VERSION): bump VERSION and pipeline/mcap/__init__.py in a commit, or build $TREE_VERSION"
APP_VERSION="${VERSION%%-*}"      # CFBundleShortVersionString is numeric

if [ -n "$TAG" ]; then
    printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "tag '$TAG' is not vX.Y.Z or vX.Y.Z-pre"
    [ "$TAG" = "v$VERSION" ] || die "tag $TAG does not match version $VERSION"
    git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" >/dev/null || die "tag $TAG does not exist in this clone (git fetch --tags)"
    [ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "tag $TAG does not point at HEAD: check out the tag first"
    # The bracket in the last letter keeps these patterns from matching this file. The address cannot be known before the repository exists, so a scan would be too early.
    left="$(grep -nE -e '<repository-ur[l]>' -e 'set the date when you tag i[t]' README.md README.ko.md CONTRIBUTING.md docs/INSTALL.md CHANGELOG.md 2>/dev/null | cut -d: -f1,2 || true)"
    if [ -n "$left" ]; then
        die "a placeholder of the first release is still there (put the clone address of the repository in the install steps and a date in the CHANGELOG heading, docs/RELEASING.md): $(echo "$left" | tr '\n' ' ')"
    fi
fi
if [ ! -f LICENSE ]; then
    if [ -n "$TAG" ]; then die "LICENSE is missing: a release must not go out without a licence"; fi
    warn "LICENSE is missing (a tagged release would stop here)"
fi

ZIP_BASE="$APP_SHORT_NAME-$VERSION-macos-arm64-adhoc"
ZIP_NAME="$ZIP_BASE.zip"
TAR_NAME="$NAME-$VERSION-source.tar.gz"
if [ "$SKIP_APP" != 1 ] && { [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; }; then
    if [ -n "$TAG" ]; then die "a tagged release includes the app zip, which needs an Apple silicon Mac in a native arm64 shell (not Rosetta); use --skip-app to release the source only"; fi
    warn "not an Apple silicon Mac (native arm64 shell): no app zip, source tarball only"
    SKIP_APP=1
fi
if [ "$SKIP_APP" = 1 ] && [ "$SKIP_SOURCE" = 1 ]; then die "nothing to build (--skip-app and --skip-source, or no Apple silicon Mac and --skip-source)"; fi
if [ "$SKIP_SOURCE" != 1 ]; then
    git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || die "the source tarball needs a git clone with a commit; use --skip-source to build only the app zip"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then warn "uncommitted changes: the tarball holds the committed HEAD only, the app zip is built from the working tree"; fi
fi

echo "[release] version $VERSION (app $APP_VERSION)${TAG:+, tag $TAG}, output $OUT" >&2
if [ "$SKIP_APP" != 1 ];    then echo "[release] would build: $ZIP_NAME" >&2; fi
if [ "$SKIP_SOURCE" != 1 ]; then echo "[release] would build: $TAR_NAME" >&2; fi
echo "[release] would build: SHA256SUMS, RELEASE_NOTES.md" >&2
if [ "$DRY_RUN" = 1 ]; then log "dry run: nothing built"; exit 0; fi

mkdir -p "$OUT"
rm -f "$OUT/$ZIP_NAME" "$OUT/$TAR_NAME" "$OUT/SHA256SUMS" "$OUT/RELEASE_NOTES.md"

# ---- app zip ------------------------------------------------------------------------------------------------------
write_app_readme() {   # the text that travels inside the zip
    cat <<EOF
$APP_NAME $VERSION - menu-bar app for Apple silicon Macs, macOS 14.4 or newer

READ THIS BEFORE YOU OPEN THE APP

1. This is a test build. It is signed ad-hoc (no Apple Developer ID) and is NOT notarized.
   Recommended: build it yourself from the source tarball or a git clone. A local build is not quarantined, so there is no
   Gatekeeper step at all.

2. The app is only the menu-bar part. It starts the Python pipeline from a source checkout of the SAME version (PROJECT_DIR in
   config.env) and needs the Python environment and the speech model that the setup scripts install. Without that checkout the
   app cannot process a recording. The README of the source tree has the full install steps.

3. Gatekeeper. A zip downloaded with a browser is quarantined, so macOS refuses to open an app that is not notarized.
   First compare the SHA-256 of the zip with SHA256SUMS on the release page (shasum -a 256 -c SHA256SUMS). Then either:
     - macOS 15 or newer: try to open the app once, then System Settings > Privacy & Security > scroll down > Open Anyway.
     - macOS 14: Control-click the app > Open > Open.
     - or remove the quarantine flag yourself:   xattr -dr com.apple.quarantine $APP_SHORT_NAME.app
   Downloading with curl or gh does not set the quarantine flag.

4. Permissions. The Microphone, System Audio Recording and Notifications grants are tied to the code hash of an ad-hoc build, so
   macOS asks again for every new build.

5. This app records the other people in your meetings and shows them no notice. Recording consent is your responsibility. Read the
   legal notice in the README first.

LICENSE (and NOTICE, THIRD_PARTY_NOTICES.md when present) are next to the app. No third-party code, model or font is bundled.
EOF
}
build_app_zip() {
    local build="$WORK/build" stage="$WORK/stage/$ZIP_BASE" verify="$WORK/verify" app f ver sig
    mkdir -p "$build" "$stage" "$verify"
    log "building $APP_SHORT_NAME.app with an ad-hoc signature (swiftc, a few minutes) ..."
    if ! app="$(MCAP_BUILD_DIR="$build" MCAP_VERSION="$APP_VERSION" MC_CODESIGN_IDENTITY=- "$SCRIPT_DIR/build_app.sh" 2>"$WORK/build_app.log" | tail -n 1)"; then
        sed 's/^/    | /' "$WORK/build_app.log" >&2
        die "scripts/build_app.sh failed"
    fi
    [ -d "$app" ] || { sed 's/^/    | /' "$WORK/build_app.log" >&2; die "build_app.sh did not produce an app bundle"; }
    ditto "$app" "$stage/$APP_SHORT_NAME.app"            # ditto keeps the code signature intact
    for f in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
        if [ -f "$PROJECT_DIR/$f" ]; then cp "$PROJECT_DIR/$f" "$stage/$f"; fi
    done
    write_app_readme > "$stage/README-FIRST.txt"
    # --norsrc: no AppleDouble (__MACOSX) entries; it implies no extended attributes either. --noqtn: never carry a quarantine flag into the zip.
    ditto -c -k --keepParent --norsrc --noqtn "$stage" "$OUT/$ZIP_NAME"
    # Check the zip as a user would get it: unpack, signature valid, ad-hoc, right identifier and version, no stray __MACOSX folder.
    ditto -x -k "$OUT/$ZIP_NAME" "$verify"
    app="$verify/$ZIP_BASE/$APP_SHORT_NAME.app"
    [ -d "$app" ] || die "the zip does not contain $ZIP_BASE/$APP_SHORT_NAME.app"
    [ ! -e "$verify/__MACOSX" ] || die "the zip contains a __MACOSX folder"
    codesign --verify --strict --verbose=2 "$app" >/dev/null 2>&1 || die "codesign --verify fails on the unpacked app"
    sig="$(codesign -dvv "$app" 2>&1)" || die "codesign -dvv fails on the unpacked app"
    case "$sig" in *"Signature=adhoc"*) ;; *) die "the app is not ad-hoc signed (a signing identity was used?)" ;; esac
    case "$sig" in *"Identifier=$BUNDLE_ID"*) ;; *) die "unexpected code signature identifier (expected $BUNDLE_ID)" ;; esac
    ver="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
    [ "$ver" = "$APP_VERSION" ] || die "the app says version $ver, expected $APP_VERSION"
    log "app zip ok: $ZIP_NAME ($(du -h "$OUT/$ZIP_NAME" | awk '{print $1}'))"
}
if [ "$SKIP_APP" != 1 ]; then build_app_zip; fi

# ---- source tarball -----------------------------------------------------------------------------------------------
if [ "$SKIP_SOURCE" != 1 ]; then
    git archive --format=tar.gz --prefix="$NAME-$VERSION/" -o "$OUT/$TAR_NAME" HEAD
    log "source tarball ok: $TAR_NAME ($(du -h "$OUT/$TAR_NAME" | awk '{print $1}'))"
fi

# ---- checksums ----------------------------------------------------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then SHA=(shasum -a 256); else SHA=(sha256sum); fi
ASSETS=""
if [ -f "$OUT/$ZIP_NAME" ]; then ASSETS="$ZIP_NAME"; fi
if [ -f "$OUT/$TAR_NAME" ]; then ASSETS="$ASSETS $TAR_NAME"; fi
# shellcheck disable=SC2086  # ASSETS is a list of plain file names without spaces, split on purpose
( cd "$OUT" && "${SHA[@]}" $ASSETS > SHA256SUMS && "${SHA[@]}" -c SHA256SUMS >/dev/null ) || die "could not write or verify SHA256SUMS"

# ---- release notes ------------------------------------------------------------------------------------------------
changes_section() {    # the CHANGELOG.md section of this version, if there is one
    local body=""
    if [ -f CHANGELOG.md ]; then
        body="$(awk -v a="[$VERSION]" -v b="## $VERSION" '/^## / { if (on) exit; if (index($0, a) || index($0, b)) { on = 1; next } } on { print }' CHANGELOG.md | sed '/./,$!d')"
    fi
    if [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
        printf '%s\n\n' "$body"
    else
        printf 'No changelog entry was found for this version: see the commit history since the previous tag.\n\n'
    fi
}
write_notes() {
    printf '## %s %s\n\n' "$APP_NAME" "$VERSION"
    changes_section
    printf '### Files\n\n| File | What it is |\n|---|---|\n'
    if [ -f "$OUT/$TAR_NAME" ]; then printf '| `%s` | The source. **Recommended:** build it yourself, see the README. |\n' "$TAR_NAME"; fi
    if [ -f "$OUT/$ZIP_NAME" ]; then printf '| `%s` | `%s.app`, built from this tag. Signed ad-hoc, **not notarized**. Read the next section first. |\n' "$ZIP_NAME" "$APP_SHORT_NAME"; fi
    printf '| `SHA256SUMS` | SHA-256 of the files above. Check: `shasum -a 256 -c SHA256SUMS` in the folder where you saved them. |\n\n'
    printf 'Requirements: an Apple silicon Mac, macOS 14.4 or newer. The README says what has and has not been tested.\n\n'
    if [ -f "$OUT/$ZIP_NAME" ]; then
        cat <<'EOF'
### Using the app zip (and why building from source is better)

- The zip holds only the menu-bar app. It runs the Python pipeline from a source checkout of the same version and needs the Python
  environment and the speech model that the setup scripts install, so the zip alone cannot process a recording.
- The build is signed ad-hoc and not notarized (no Apple Developer ID). A browser download is quarantined and macOS will refuse to
  open it. After you checked the SHA-256:
  - macOS 15 or newer: try to open the app once, then System Settings > Privacy & Security > Open Anyway.
  - macOS 14: Control-click the app, then Open.
EOF
        printf '  - Or remove the quarantine flag: `xattr -dr com.apple.quarantine %s.app`\n' "$APP_SHORT_NAME"
        cat <<'EOF'
- A build you compile yourself is not quarantined, so none of this applies to it.
- The Microphone, System Audio Recording and Notifications permissions are tied to the code hash of an ad-hoc build: macOS asks again
  for every new build.
- Nothing from third parties is bundled: no model, no Python package, no font.

EOF
    fi
    cat <<'EOF'
### Before you record anyone

This software records the other people in your meetings and shows them no notice. Recording consent is your responsibility. Read the
legal notice in the README and in `docs/PRIVACY_AND_CONSENT.md` first. See `LICENSE` for the terms of use.
EOF
}
write_notes > "$OUT/RELEASE_NOTES.md"

log "done. Files in $OUT:"
# shellcheck disable=SC2086
( cd "$OUT" && ls -l RELEASE_NOTES.md SHA256SUMS $ASSETS ) >&2
log "nothing was published. To publish: push the tag, see docs/RELEASING.md"
