#!/bin/bash
# Build the COMPANY installer package: app + shim + system-wide LaunchAgent + a signed, root-owned runtime release + baseline policy.
#
#   scripts/build_pkg.sh --release-dir DIR --release-pubkey FILE [options]
#   scripts/build_pkg.sh --dry-run [options]            print the plan and every command, build and write nothing
#
# UNSIGNED IS THE DEFAULT. Without --app-identity and --installer-identity this builds a package that nobody has signed: good for a rehearsal on a
# test Mac (install it with  sudo installer -pkg ... -target /  or through your MDM, which ignores quarantine). Developer ID signing of the app with
# the hardened runtime, signing of the package, notarization and the upload to the MDM need your Apple Developer account and are ADMIN ACTIONS:
# this script takes the identities as arguments and runs codesign and productbuild with them, and it PRINTS the notarytool and stapler commands but
# never runs them. The personal build (scripts/build_app.sh) is not touched: the app is copied and the copy is the one that gets re-signed.
#
# What goes into the package (all root-owned after postinstall, scripts/pkg/postinstall):
#   /Applications/<short name>.app                                       the app (from --app, or built by scripts/build_app.sh)
#   /usr/local/bin/mcap                                                   shim: runs the CURRENT release's python with a fixed module path and a clean environment
#   /Library/LaunchAgents/<bundle id>.plist                               the label is the bundle id, as in the personal agent; loaded at the next login
#   /Library/Application Support/MeetingCapture/releases/<version>/       the release you prepared: pipeline/, venv/, models/ (full), MANIFEST.json + .sig
#   /Library/Application Support/MeetingCapture/release-signing.pub.pem   the public key that the manifest signature is checked against (also later, for new releases)
#   package scripts: preinstall, postinstall, provision_runtime.sh, provision_user_config.sh, migrate_owner_install.sh, bundle_id.sh, config.env.company.template,
#   baseline-policy.json (scripts/make_policy.sh: every external lane deny, local_only.default true), RELEASE_VERSION, RELEASE_FLAVOR, RELEASE_BUNDLE_ID, RELEASE_APP_NAME,
#   RELEASE_APP_SHORT_NAME, RELEASE_BASE_PYTHON
#   (where the venv's base python must be on every Mac: the package does NOT carry it, preinstall refuses a Mac without it before it changes anything)
#
# The bundle identifier is the one of the app that goes into the package: the Info.plist of --app, else MCAP_BUNDLE_ID (build_app.sh builds with it), else
# org.meetingcapture.app. The LaunchAgent label, the package identifier (<bundle id>.pkg) and the installer organisation (the bundle id without its last
# label) are derived from it; nothing else names it. A company that wants its own namespace builds with MCAP_BUNDLE_ID=<its reverse-DNS id>.
# The two names of the app are resolved the same way (the Info.plist of --app, else MCAP_APP_NAME / MCAP_APP_SHORT_NAME, else "Catch Everything" / "CATE"): the app
# folder in the package is /Applications/<short name>.app, the package files are <short name>-<version>[-client].pkg, the installer title is the human name.
#
# The release is prepared BEFORE this script (docs/DEPLOY.md): a venv built from a hash lock on a root-owned base python (scripts/make_hash_lock.sh,
# scripts/setup_python.sh --client-only --hash-lock ...), the model, then  scripts/provision_runtime.sh --make-manifest  and the offline signature.
# This script refuses a release whose manifest signature or hashes do not verify (provision_runtime.sh --verify-only), so a damaged or unsigned
# payload never gets into a package. That check includes the venv's base python (present, not writable by group or others), also as a normal user.
#
# NOTARIZATION needs EVERY Mach-O file of the payload (the venv's python, numpy and onnxruntime libraries, ... not only the app) signed with the
# Developer ID Application certificate, the hardened runtime and a secure timestamp. The release is hashed into the signed manifest, so its binaries
# are signed BEFORE the manifest is made (provision_runtime.sh --sign-macho --identity ..., docs/DEPLOY.md 3.5); signing them here would break the
# manifest. With --app-identity this script checks every Mach-O file of the payload (codesign -dvv) and stops the build, naming them, when one is
# not signed that way. [unverified] until you have done a real notarytool submit.
#
# Options:
#   --release-dir DIR       the prepared release; its folder name is its version (0.2.0) and must equal the package version. Required unless --dry-run
#   --release-pubkey FILE   Ed25519 public key (PEM) of the release signature. Required unless --dry-run
#   --client-only           the client-only flavour (remote ASR, no local model): the release's manifest must say client; the baseline policy has no ASR_MODEL.
#                           Not verified on 8 GB Macs.
#   --version V             package version (default: __version__ of pipeline/mcap/__init__.py)
#   --app PATH              a built <short name>.app (default: scripts/build_app.sh builds one into the build folder; MCAP_SOURCES_DIR, MC_CODESIGN_IDENTITY apply)
#   --app-identity NAME     "Developer ID Application: ..." : re-sign the COPY of the app with the hardened runtime, --entitlements and a secure timestamp
#   --installer-identity NAME  "Developer ID Installer: ..." : sign the distribution package (productbuild --sign)
#   --entitlements FILE     entitlements of the hardened app (default scripts/pkg/entitlements.plist)
#   --contact TEXT          support.contact of the baseline policy (shown in notifications), for example "IT 헬프데스크 #it-help"
#   --out-dir DIR           default $MCAP_BUILD_DIR/pkg (build/pkg)
#   --dry-run               print the plan and the commands, do nothing
#   -h, --help              this text
#
# Output: the last line is the path of the package. Work files stay in <out-dir>/work (payload, scripts, distribution.xml) for inspection and are replaced
# by the next build. Nothing is installed, loaded or uploaded; no Keychain is read here (codesign and productbuild read the identity themselves).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bundle_id.sh
. "$SCRIPT_DIR/bundle_id.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${MCAP_BUILD_DIR:-$PROJECT_DIR/build}"
RELEASES_ABS="/Library/Application Support/MeetingCapture/releases"

RELEASE_DIR=""
RELEASE_PUBKEY=""
FLAVOR="full"
VERSION=""
APP=""
APP_IDENTITY=""
INSTALLER_IDENTITY=""
ENTITLEMENTS="$SCRIPT_DIR/pkg/entitlements.plist"
CONTACT=""
OUT_DIR=""
DRY_RUN=0
DIED=0

log()  { echo "[build_pkg] $*" >&2; }
die()  { DIED=1; echo "[build_pkg] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[build_pkg] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --release-dir) [ $# -ge 2 ] || die "--release-dir needs a directory" 2; RELEASE_DIR="$2"; shift ;;
        --release-pubkey) [ $# -ge 2 ] || die "--release-pubkey needs a file" 2; RELEASE_PUBKEY="$2"; shift ;;
        --client-only) FLAVOR="client" ;;
        --version) [ $# -ge 2 ] || die "--version needs a version" 2; VERSION="$2"; shift ;;
        --app) [ $# -ge 2 ] || die "--app needs a path" 2; APP="$2"; shift ;;
        --app-identity) [ $# -ge 2 ] || die "--app-identity needs a name" 2; APP_IDENTITY="$2"; shift ;;
        --installer-identity) [ $# -ge 2 ] || die "--installer-identity needs a name" 2; INSTALLER_IDENTITY="$2"; shift ;;
        --entitlements) [ $# -ge 2 ] || die "--entitlements needs a file" 2; ENTITLEMENTS="$2"; shift ;;
        --contact) [ $# -ge 2 ] || die "--contact needs a text" 2; CONTACT="$2"; shift ;;
        --out-dir) [ $# -ge 2 ] || die "--out-dir needs a directory" 2; OUT_DIR="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

[ "$(uname -s)" = Darwin ] || die "this builds a macOS package: run it on a Mac"
if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/^__version__ = "\([0-9.]*\)".*$/\1/p' "$PROJECT_DIR/pipeline/mcap/__init__.py" | head -n 1)"
fi
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' || die "cannot tell the package version (got '$VERSION'): pass --version" 2
[ -n "$OUT_DIR" ] || OUT_DIR="$BUILD_DIR/pkg"
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
WORK="$OUT_DIR/work"

# ---- inputs ---------------------------------------------------------------------------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
    [ -n "$RELEASE_DIR" ] || die "--release-dir is required (the prepared release: docs/DEPLOY.md). --dry-run shows the plan without it." 2
    [ -n "$RELEASE_PUBKEY" ] || die "--release-pubkey is required (the public key of the release signature). --dry-run shows the plan without it." 2
fi
if [ -n "$RELEASE_DIR" ]; then
    case "$RELEASE_DIR" in /*) ;; *) RELEASE_DIR="$PWD/$RELEASE_DIR" ;; esac
    RELEASE_DIR="${RELEASE_DIR%/}"
    [ "$(basename "$RELEASE_DIR")" = "$VERSION" ] || die "the release folder is named $(basename "$RELEASE_DIR") but the package version is $VERSION: a release is named by its version"
fi
if [ -n "$RELEASE_PUBKEY" ]; then
    case "$RELEASE_PUBKEY" in /*) ;; *) RELEASE_PUBKEY="$PWD/$RELEASE_PUBKEY" ;; esac
fi
if [ -n "$APP" ]; then
    case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
fi
case "$ENTITLEMENTS" in /*) ;; *) ENTITLEMENTS="$PWD/$ENTITLEMENTS" ;; esac
# the bundle id of the app that is packaged (read again from the built app below); derived from it: the package id and the installer organisation
BUNDLE_ID="$(mcap_resolve_bundle_id ${APP:+"$APP"})" || die "the bundle identifier is refused (see above): nothing was built" 2
PKG_ID="$BUNDLE_ID.pkg"
# the names of the app that is packaged, read again from the built app below: the app folder in the package, the package files and the installer title
APP_NAME="$(mcap_resolve_app_name ${APP:+"$APP"})" || die "the app name is refused (see above): nothing was built" 2
APP_SHORT_NAME="$(mcap_resolve_app_short_name ${APP:+"$APP"})" || die "the short app name is refused (see above): nothing was built" 2
if [ "$FLAVOR" = client ]; then PKG_NAME="$APP_SHORT_NAME-$VERSION-client.pkg"; else PKG_NAME="$APP_SHORT_NAME-$VERSION.pkg"; fi
COMPONENT_NAME="$APP_SHORT_NAME-$VERSION-component.pkg"
FINAL="$OUT_DIR/$PKG_NAME"
for f in "$SCRIPT_DIR/pkg/preinstall" "$SCRIPT_DIR/pkg/postinstall" "$SCRIPT_DIR/pkg/distribution.xml.template" "$SCRIPT_DIR/provision_runtime.sh" \
         "$SCRIPT_DIR/provision_user_config.sh" "$SCRIPT_DIR/migrate_owner_install.sh" "$SCRIPT_DIR/make_policy.sh" "$SCRIPT_DIR/bundle_id.sh" \
         "$PROJECT_DIR/config/config.env.company.template"; do
    [ -f "$f" ] || die "missing in the repository: $f"
done
if [ -n "$APP_IDENTITY" ]; then
    [ -f "$ENTITLEMENTS" ] || die "--entitlements: not a file: $ENTITLEMENTS"
    plutil -lint "$ENTITLEMENTS" >/dev/null || die "--entitlements is not a valid plist: $ENTITLEMENTS"
fi

run() {  # run a command, or print it with --dry-run
    if [ "$DRY_RUN" = 1 ]; then
        printf '[build_pkg] [dry-run] would run:' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
    else
        "$@"
    fi
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Every Mach-O file below $1 (found by content) must carry what the notary service asks for. Sets MACHO_TOTAL and MACHO_BAD (one "path: reason" each).
check_macho_signed() {
    local f info why
    MACHO_TOTAL=0
    MACHO_BAD=()
    while IFS= read -r f; do
        MACHO_TOTAL=$((MACHO_TOTAL + 1))
        why=""
        if ! info="$(codesign -dvv "$f" 2>&1)"; then why="not signed"
        elif ! grep -Eq '^Authority=Developer ID Application:' <<< "$info"; then why="no Developer ID Application signature (unsigned or ad-hoc)"
        elif ! grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<< "$info"; then why="no hardened runtime"
        elif ! grep -Eq '^Timestamp=' <<< "$info"; then why="no secure timestamp"
        fi
        if [ -n "$why" ]; then MACHO_BAD+=("${f#"$1"/}: $why"); fi
    done < <(find "$1" -type f -print0 | xargs -0 file 2>/dev/null | sed -n 's/: *Mach-O .*$//p')
}

# ---- the files that are generated ------------------------------------------------------------------------------------------------------------------
render_shim() {      # the names are validated (scripts/bundle_id.sh: no sed metacharacter can be in them)
    sed -e "s|@APP_NAME@|$APP_NAME|" -e "s|@APP_SHORT_NAME@|$APP_SHORT_NAME|" <<'EOF'
#!/bin/sh
# /usr/local/bin/mcap: root-owned shim of the MeetingCapture company install (written by scripts/build_pkg.sh; do not edit, the package replaces it).
# It runs the pipeline of the CURRENT release with a fixed module path and a clean environment. Whatever MCAP_*, PYTHON* or PATH the caller has set is
# dropped: a shell alias, a profile or a planted module in the working directory (PYTHONSAFEPATH keeps the working directory off sys.path) cannot
# change the code that runs. On a policy-managed Mac the MCAP_* test hooks are ignored anyway; this keeps even the code path out of reach.
# The two names of the app are the one exception: the package sets them (the names it was built with, so the pipeline names the app the way the app does).
RELEASE="/Library/Application Support/MeetingCapture/releases/current"
PY="$RELEASE/venv/bin/python"
if [ ! -x "$PY" ]; then
    echo "mcap: no company release is active ($PY is missing): the installation did not finish. Ask your IT help desk." >&2
    exit 127
fi
exec /usr/bin/env -i \
    HOME="${HOME:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" LANG="${LANG:-en_US.UTF-8}" TERM="${TERM:-dumb}" TMPDIR="${TMPDIR:-/tmp}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin MCAP_APP_NAME="@APP_NAME@" MCAP_APP_SHORT_NAME="@APP_SHORT_NAME@" \
    PYTHONPATH="$RELEASE/pipeline" PYTHONDONTWRITEBYTECODE=1 PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 HF_HUB_DISABLE_TELEMETRY=1 \
    "$PY" -m mcap "$@"
EOF
}

render_agent_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  System-wide LaunchAgent of the company install (scripts/build_pkg.sh; the same label as the personal per-user agent, which
  scripts/migrate_owner_install.sh puts aside first). Loaded by launchd at the next login of every user, in the GUI session only. A normal Quit from the
  menu is not restarted; a crash is, after 30 seconds. There is no StandardOutPath: a system-wide plist cannot name a per-user log folder (the app
  writes its own app.log). The live-test gate of scripts/make_launchagent.sh belongs to the personal install; a package install has its own first-run
  check (docs/DEPLOY.md).
-->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$BUNDLE_ID</string>
	</array>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/$APP_SHORT_NAME.app/Contents/MacOS/$APP_SHORT_NAME</string>
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
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
	</dict>
</dict>
</plist>
EOF
}

render_component_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key>
		<true/>
		<key>BundleIsRelocatable</key>
		<false/>
		<key>BundleIsVersionChecked</key>
		<false/>
		<key>BundleOverwriteAction</key>
		<string>upgrade</string>
		<key>RootRelativeBundlePath</key>
		<string>Applications/$APP_SHORT_NAME.app</string>
	</dict>
</array>
</plist>
EOF
}

# ---- the plan ----------------------------------------------------------------------------------------------------------------------------------------
log "package $PKG_NAME (version $VERSION, flavour $FLAVOR) -> $FINAL"
[ "$DRY_RUN" != 1 ] || log "DRY RUN: nothing is built, written or signed"
log "release : ${RELEASE_DIR:-<--release-dir not given>}   public key: ${RELEASE_PUBKEY:-<--release-pubkey not given>}"
if [ -n "$APP_IDENTITY" ]; then
    log "app     : copy of ${APP:-<built by build_app.sh>} signed with '$APP_IDENTITY', hardened runtime, entitlements $ENTITLEMENTS, secure timestamp"
else
    log "app     : copy of ${APP:-<built by build_app.sh>}, NOT re-signed (no --app-identity): it keeps the signature of the build (ad-hoc or the local identity)"
fi
if [ -n "$INSTALLER_IDENTITY" ]; then
    log "package : signed with '$INSTALLER_IDENTITY' (productbuild --sign)"
else
    log "package : UNSIGNED (no --installer-identity): Gatekeeper refuses it when it is opened by hand on a clean Mac; installer(8) and MDM install it"
fi
log "guards  : distribution hostArchitectures=arm64 and macOS 14.4 or newer (the same two are checked again by preinstall)"
log "baseline: policy.json with every external lane deny and local_only.default true, policy.required, root-owned 0644 (only where there is no policy yet)"

# ---- the release is verified BEFORE anything is built ---------------------------------------------------------------------------------------------------
if [ -n "$RELEASE_DIR" ] && [ -n "$RELEASE_PUBKEY" ]; then
    [ -d "$RELEASE_DIR" ] || die "release folder not found: $RELEASE_DIR"
    [ -f "$RELEASE_PUBKEY" ] || die "public key not found: $RELEASE_PUBKEY"
    log "verifying the release (signature, hashes, links): provision_runtime.sh --verify-only"
    /bin/bash "$SCRIPT_DIR/provision_runtime.sh" --release-dir "$RELEASE_DIR" --pubkey "$RELEASE_PUBKEY" --flavor "$FLAVOR" --verify-only >&2 \
        || die "the release does not verify: no package is built from it (see above; make the manifest and the offline signature first: docs/DEPLOY.md)"
    grep -q "__version__ = \"$VERSION\"" "$RELEASE_DIR/pipeline/mcap/__init__.py" 2>/dev/null \
        || die "the release's pipeline/mcap/__init__.py does not say __version__ = \"$VERSION\": the release and the package version must agree"
elif [ "$DRY_RUN" = 1 ]; then
    log "(dry run without --release-dir and --release-pubkey: the release would be verified with provision_runtime.sh --verify-only before anything is built)"
fi

# the base python the venv runs on ("home =" of its pyvenv.cfg) when it is not part of the release: a prerequisite of every Mac (docs/DEPLOY.md 3.1)
BASE_PYTHON_HOME=""
if [ -n "$RELEASE_DIR" ] && [ -f "$RELEASE_DIR/venv/pyvenv.cfg" ]; then
    BASE_PYTHON_HOME="$(sed -n 's/^home[[:space:]]*=[[:space:]]*//p' "$RELEASE_DIR/venv/pyvenv.cfg" | head -n 1 | sed 's/[[:space:]]*$//')"
    case "$BASE_PYTHON_HOME" in "$RELEASE_DIR"|"$RELEASE_DIR"/*) BASE_PYTHON_HOME="" ;; esac
    if [ -n "$BASE_PYTHON_HOME" ]; then
        log "base python: $BASE_PYTHON_HOME must be on every client Mac before this package, root-owned and not writable by others (docs/DEPLOY.md 3.1; preinstall checks it)"
    fi
fi

# ---- the app: built or given, then copied; only the copy is signed -------------------------------------------------------------------------------------
if [ -z "$APP" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        run "$SCRIPT_DIR/build_app.sh"
        APP="$BUILD_DIR/$APP_SHORT_NAME.app"
    else
        log "no --app: building one with scripts/build_app.sh"
        APP="$("$SCRIPT_DIR/build_app.sh" | tail -n 1)" || die "build_app.sh failed"
    fi
fi
if [ "$DRY_RUN" != 1 ]; then
    [ -x "$APP/Contents/MacOS/$APP_SHORT_NAME" ] || die "not the app of this package (no Contents/MacOS/$APP_SHORT_NAME): $APP. Pass the names it was built with (MCAP_APP_SHORT_NAME) or an app whose Info.plist has them"
    BUNDLE_ID="$(mcap_resolve_bundle_id "$APP")" || die "the bundle identifier is refused (see above)"       # the app that is packaged names itself
    PKG_ID="$BUNDLE_ID.pkg"
fi
log "bundle id: $BUNDLE_ID (LaunchAgent label, package id $PKG_ID, installer organisation ${BUNDLE_ID%.*})"
log "app names: $APP_NAME, /Applications/$APP_SHORT_NAME.app (installer title, app folder and program; package file $PKG_NAME)"

# ---- work tree ------------------------------------------------------------------------------------------------------------------------------------------
PAYLOAD="$WORK/payload"
SCRIPTS="$WORK/scripts"
SYS_REL="Library/Application Support/MeetingCapture"
if [ "$DRY_RUN" != 1 ]; then
    case "$WORK" in */work) rm -rf "$WORK" ;; *) die "refusing to clear '$WORK'" ;; esac
fi
run mkdir -p "$PAYLOAD/Applications" "$PAYLOAD/Library/LaunchAgents" "$PAYLOAD/$SYS_REL/releases" "$PAYLOAD/usr/local/bin" "$SCRIPTS"
log "payload : app, shim, LaunchAgent, release $VERSION, public key"
run ditto "$APP" "$PAYLOAD/Applications/$APP_SHORT_NAME.app"
if [ -n "$RELEASE_DIR" ]; then
    run ditto "$RELEASE_DIR" "$PAYLOAD/$SYS_REL/releases/$VERSION"
else
    run ditto "<--release-dir>" "$PAYLOAD/$SYS_REL/releases/$VERSION"
fi
run cp "${RELEASE_PUBKEY:-<--release-pubkey>}" "$PAYLOAD/$SYS_REL/release-signing.pub.pem"
if [ "$DRY_RUN" != 1 ]; then
    render_shim > "$PAYLOAD/usr/local/bin/mcap"
    chmod 755 "$PAYLOAD/usr/local/bin/mcap"
    render_agent_plist > "$PAYLOAD/Library/LaunchAgents/$BUNDLE_ID.plist"
    chmod 644 "$PAYLOAD/Library/LaunchAgents/$BUNDLE_ID.plist"
    plutil -lint "$PAYLOAD/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null || die "the generated LaunchAgent plist is not valid"
    /bin/sh -n "$PAYLOAD/usr/local/bin/mcap" || die "the generated shim has a syntax error"
    render_component_plist > "$WORK/component.plist"
    plutil -lint "$WORK/component.plist" >/dev/null || die "the generated component plist is not valid"
    chmod 644 "$PAYLOAD/$SYS_REL/release-signing.pub.pem"
    chmod -R go-w "$PAYLOAD"
else
    log "[dry-run] would write the shim /usr/local/bin/mcap, the LaunchAgent plist (label $BUNDLE_ID) and the component plist into the work tree"
fi

# ---- sign the COPY of the app: hardened runtime, entitlements, secure timestamp (your identity) --------------------------------------------------------------
if [ -n "$APP_IDENTITY" ]; then
    SIGNED_APP="$PAYLOAD/Applications/$APP_SHORT_NAME.app"
    run codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" --sign "$APP_IDENTITY" "$SIGNED_APP"
    run codesign --verify --strict --verbose=2 "$SIGNED_APP"
    if [ "$DRY_RUN" != 1 ]; then
        SIGNED_INFO="$(codesign -dvvv "$SIGNED_APP" 2>&1)" || die "codesign -d failed on the signed app"
        grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<< "$SIGNED_INFO" || die "the signed app does not carry the hardened runtime flag: not packaging it"
        log "app signed with the hardened runtime ([미검증] Process Tap capture under it needs a device test: docs/LIVE_TEST.md, docs/DEPLOY.md)"
    fi
    # the rest of the payload: the notary service rejects the package for ONE Mach-O file that is not signed (see the header)
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would check every Mach-O file of the payload (the app and the release: venv python, libraries) for a Developer ID Application signature, the hardened runtime and a secure timestamp (codesign -dvv)"
    else
        check_macho_signed "$PAYLOAD"
        if [ "${#MACHO_BAD[@]}" -gt 0 ]; then
            printf '[build_pkg]   %s\n' "${MACHO_BAD[@]:0:20}" >&2
            die "${#MACHO_BAD[@]} of $MACHO_TOTAL Mach-O file(s) of the payload are not signed the way the notary service needs (listed above, at most 20): sign the release's binaries BEFORE its manifest (scripts/provision_runtime.sh --release-dir <dir> --sign-macho --identity '$APP_IDENTITY', then --make-manifest and the offline signature: docs/DEPLOY.md 3.5)"
        fi
        log "$MACHO_TOTAL Mach-O file(s) of the payload: all signed with a Developer ID Application certificate, the hardened runtime and a secure timestamp ([미검증] until a real notarytool submit)"
    fi
fi

# ---- the package scripts -------------------------------------------------------------------------------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
    cp "$SCRIPT_DIR/pkg/preinstall" "$SCRIPT_DIR/pkg/postinstall" "$SCRIPTS/"
    cp "$SCRIPT_DIR/provision_runtime.sh" "$SCRIPT_DIR/provision_user_config.sh" "$SCRIPT_DIR/migrate_owner_install.sh" "$SCRIPT_DIR/bundle_id.sh" \
       "$PROJECT_DIR/config/config.env.company.template" "$SCRIPTS/"
    chmod 755 "$SCRIPTS/preinstall" "$SCRIPTS/postinstall" "$SCRIPTS/provision_runtime.sh" "$SCRIPTS/provision_user_config.sh" "$SCRIPTS/migrate_owner_install.sh"
    chmod 644 "$SCRIPTS/config.env.company.template" "$SCRIPTS/bundle_id.sh"
    printf '%s\n' "$VERSION" > "$SCRIPTS/RELEASE_VERSION"
    printf '%s\n' "$FLAVOR" > "$SCRIPTS/RELEASE_FLAVOR"
    printf '%s\n' "$BUNDLE_ID" > "$SCRIPTS/RELEASE_BUNDLE_ID"
    printf '%s\n' "$APP_NAME" > "$SCRIPTS/RELEASE_APP_NAME"
    printf '%s\n' "$APP_SHORT_NAME" > "$SCRIPTS/RELEASE_APP_SHORT_NAME"
    # The base python of the venv lives OUTSIDE the release and the package does not carry it: preinstall checks that it is on the Mac (and nobody but
    # root can write it) BEFORE it puts a personal install aside, so a Mac without it keeps its working app. Empty: the python is inside the release.
    printf '%s\n' "$BASE_PYTHON_HOME" > "$SCRIPTS/RELEASE_BASE_PYTHON"
else
    log "[dry-run] would copy preinstall, postinstall, provision_runtime.sh, provision_user_config.sh, migrate_owner_install.sh, bundle_id.sh, the config template and RELEASE_VERSION/RELEASE_FLAVOR/RELEASE_BUNDLE_ID/RELEASE_APP_NAME/RELEASE_APP_SHORT_NAME/RELEASE_BASE_PYTHON into $SCRIPTS"
fi
POLICY_ARGS=(--out "$SCRIPTS/baseline-policy.json" --runtime-root "$RELEASES_ABS" --ring "pkg-baseline" --note "Baseline of the company package: every external lane deny. MDM delivers the real policy (docs/POLICY.md).")
[ "$FLAVOR" != client ] || POLICY_ARGS+=(--client-only)
[ -z "$CONTACT" ] || POLICY_ARGS+=(--contact "$CONTACT")
run /bin/bash "$SCRIPT_DIR/make_policy.sh" "${POLICY_ARGS[@]}"

# ---- the packages ----------------------------------------------------------------------------------------------------------------------------------------------
run pkgbuild --root "$PAYLOAD" --component-plist "$WORK/component.plist" --identifier "$PKG_ID" --version "$VERSION" --install-location / \
    --ownership recommended --min-os-version 14.4 --scripts "$SCRIPTS" "$WORK/$COMPONENT_NAME"

DIST="$WORK/distribution.xml"
if [ "$DRY_RUN" != 1 ]; then
    sed -e "s|@PKG_ID@|$(xml_escape "$PKG_ID")|g" -e "s|@ORGANIZATION@|$(xml_escape "${BUNDLE_ID%.*}")|g" -e "s|@VERSION@|$(xml_escape "$VERSION")|g" -e "s|@COMPONENT_PKG@|$(xml_escape "$COMPONENT_NAME")|g" -e "s|@APP_NAME@|$(xml_escape "$APP_NAME")|g" \
        "$SCRIPT_DIR/pkg/distribution.xml.template" > "$DIST"
    if grep -Eq '@[A-Z_]+@' "$DIST"; then die "unreplaced placeholder left in distribution.xml: $(grep -Eo '@[A-Z_]+@' "$DIST" | sort -u | tr '\n' ' ')"; fi
    xmllint --noout "$DIST" || die "the generated distribution.xml is not well-formed"
    grep -q 'hostArchitectures="arm64"' "$DIST" && grep -q '<os-version min="14.4"/>' "$DIST" || die "the distribution lost its arm64 or macOS 14.4 guard"
else
    log "[dry-run] would write $DIST from scripts/pkg/distribution.xml.template (hostArchitectures=arm64, os-version min 14.4)"
fi
PB_SIGN=()
[ -z "$INSTALLER_IDENTITY" ] || PB_SIGN=(--sign "$INSTALLER_IDENTITY" --timestamp)
run mkdir -p "$OUT_DIR"
run productbuild --distribution "$DIST" --package-path "$WORK" ${PB_SIGN[@]+"${PB_SIGN[@]}"} "$FINAL"
if [ -n "$INSTALLER_IDENTITY" ]; then
    run pkgutil --check-signature "$FINAL"
fi

# ---- what is left for the administrator -----------------------------------------------------------------------------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
    [ -f "$FINAL" ] || die "productbuild did not produce $FINAL"
    log "built $FINAL ($(du -h "$FINAL" | awk '{print $1}'), sha256 $(shasum -a 256 "$FINAL" | awk '{print $1}'))"
fi
{
    echo "[build_pkg] next, ADMIN ACTIONS (this script never runs them; each needs your Apple Developer account or the MDM):"
    if [ -z "$APP_IDENTITY" ] || [ -z "$INSTALLER_IDENTITY" ]; then
        echo "[build_pkg]   1. sign: first the release's own binaries, BEFORE its manifest (the Mach-O mode of provision_runtime.sh, docs/DEPLOY.md 3.5),"
        echo "[build_pkg]      then run this again with --app-identity (the same certificate) and --installer-identity 'Developer ID Installer: <name> (<TEAMID>)'; the build stops at a Mach-O file that is not signed"
    fi
    echo "[build_pkg]   2. notarize and staple (needs a notarytool keychain profile made once with: xcrun notarytool store-credentials):"
    echo "[build_pkg]        xcrun notarytool submit '$FINAL' --keychain-profile <profile> --wait"
    echo "[build_pkg]        xcrun stapler staple '$FINAL'"
    echo "[build_pkg]   3. rehearse on a CLEAN test Mac first (docs/DEPLOY.md, docs/MIGRATION.md), then upload it to the MDM and give the first ring (3 to 5 Macs) the policy"
} >&2
[ "$DRY_RUN" != 1 ] || log "DRY RUN finished: nothing was built."
echo "$FINAL"
