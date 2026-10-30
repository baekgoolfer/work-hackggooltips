#!/bin/bash
# Regression tests for the install / uninstall / signing / bench-kit scripts and the Makefile.   Run: scripts/test_scripts.sh
#                                                                                                or: make test-scripts
#
# HERMETIC. Every script runs with HOME, TMPDIR, MCAP_SUPPORT_DIR and MCAP_LOG_DIR inside one temp directory and with
# stub programs first on PATH, so it can never touch the real system:
#   launchctl, open, osascript, tccutil   stubs that only log (launchctl is never the real one, nothing is loaded or launched)
#   security                              stub: find-identity / login-keychain are read-only fakes, import / add-trusted-cert only
#                                         change a fake state directory, ANY other subcommand is logged as FORBIDDEN and fails
#   codesign                              stub in the signing tests only (real ad-hoc codesign is used elsewhere, no keychain involved)
# No setup_python.sh run is real (only --dry-run and sourced functions with a fake model), no download, no model, no pip,
# no microphone, no system audio, no Chrome. The real keychain is never read or written by this script.
#
# Also covers: the live-test gate (install.sh / make_launchagent.sh write or load the LaunchAgent only after
# `make confirm-live-tested`), the Meet-off / Zoom-first documentation (docs/CONFIGURATION.md, docs/LIVE_TEST.md), and that every config key
# docs/CONFIGURATION.md documents is parsed by the code.
#
# Also covers (the app installer, a disk image for anybody who gets a copy): fetch_python_runtime.sh (stub curl, a fixture archive: refuses PENDING, a http address, a
# checksum mismatch, a bad archive; writes only into its folder), build_dmg.sh (refusals, the plan, the layout before signing, nested Mach-O files, the same
# identity as build_app.sh, stub hdiutil and codesign; one real-hdiutil smoke test only with MCAP_TEST_REAL_HDIUTIL=1), first_run_install.sh (a fake app, a fake
# runtime, a fake setup_python.sh and stubs for curl, sw_vers, uname, sysctl, df, defaults, id, open: the checks, the hash refusal, resume after a failure at
# every step, config.env never overwritten, the key never in an argument or the environment, English and Korean), and the agreement of FirstRun.swift with the
# scripts and the docs (DISTRIBUTE.md, USER_GUIDE.ko.md and USER_GUIDE.md: the same keywords in both languages, links in both directions, no personal data, no owner-specific wording). NOT covered: a clean Mac, Gatekeeper, a real download, the AppKit alert (Swift self tests cover the logic).
#
# Also covers (the company packaging and operations scripts): build_pkg.sh (dry run and a stub build, unsigned by default, identity
# and entitlements as arguments, hardened runtime, never notarization), the distribution guards (arm64, macOS 14.4), the package scripts preinstall and
# postinstall as a REHEARSAL on a staged tree (baseline policy.json and policy.required, the release layout with an atomic current link, the legacy
# personal install put aside and rolled back), provision_runtime.sh (signed manifest, hash and signature refusals, N-1 retention), make_hash_lock.sh,
# make_policy.sh (the pipeline's own load_org_policy accepts what it writes), provision_user_config.sh, migrate_owner_install.sh (with a rehearsal),
# mdm/ea_status.sh, mdm/offboard_user.sh, setup_python.sh --client-only / --with-cloud, uninstall.sh --company, and scripts/asr_server/test_install_server.sh.
# Extra stubs for these: pkgbuild, productbuild, pkgutil, xcrun (notarytool is FORBIDDEN), codesign, tmutil, chown, sudo, dscl, sysctl,
# sw_vers, and (only where a test says so) id and stat answering "root". NOT covered here: Developer ID signing, notarization and the MDM upload (they
# need real accounts), a real install on a clean Mac, and the app's own checks of the company runtime (Swift, PolicySelfTests).
#
# Also covers (the bundle identifier, scripts/bundle_id.sh): the validator against good and bad ids (shell and XML metacharacters, newlines, 155 and 156
# characters), build_app.sh refusing a bad MCAP_BUNDLE_ID before it compiles or signs, builds with the default id and with another one (Info.plist, codesign
# --identifier and the designated requirement through the stub; a real ad-hoc build checks the signature itself), and the names derived from the id: the
# LaunchAgent label and file, uninstall, the migration, the dmg, the package id, the installer organisation, RELEASE_BUNDLE_ID, preinstall and postinstall.
#
# Also covers (the two app names, MCAP_APP_NAME and MCAP_APP_SHORT_NAME, defaults "Catch Everything" and CATE): the validators against good and bad names (quotes,
# ampersand, angle brackets, slash, dot-dot, newlines, a leading dash or space, empty, too long, non-ASCII), the resolvers (the app's Info.plist, else the environment,
# else the defaults), build_app.sh refusing a bad value before anything is built, a default build and a build with a custom trio (app folder, executable,
# CFBundleName, CFBundleDisplayName, usage strings, the signature's identifier), --install under the short name and its refusal of another app with the same id,
# the Makefile stamp (a changed name rebuilds; a copy of the Makefile without the stamp proves the test can fail), the disk image dry run and README, the company
# package (app folder, package files, installer title, RELEASE_APP_NAME / RELEASE_APP_SHORT_NAME), the migration finding a personal app by its id. The checks that run
# the REAL app (selftest-firstrun) need a built one: build/<short name>.app, or MCAP_TEST_BUILD_DIR=<the BUILD_DIR of make test-swift>.
#
# Needs: macOS /bin/bash 3.2 (the tests deliberately run the scripts with it), swiftc (a one-line stub program is compiled),
# openssl (/usr/bin/openssl; /opt/homebrew/bin/openssl too when present: with an OpenSSL 3 the Ed25519 signatures are also cross-checked), plutil, xmllint,
# ditto, tar, script(1), python3 (3.9 or newer, standard library only).
#
# Exit code 0 only if every check passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-script-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
N=0
FAILED_NAMES=""

# Never inherit anything that could point the scripts at the real system.
unset MCAP_CONFIG MCAP_LOG_DIR MCAP_SUPPORT_DIR MCAP_BUILD_DIR MCAP_SOURCES_DIR MCAP_PYTHON MCAP_OPENSSL MC_CODESIGN_IDENTITY HF_HOME \
      MCAP_SILERO_MODEL HF_HUB_OFFLINE MCAP_PYTHON3 MCAP_SYSTEM_ROOT MCAP_PROVISION_DROPPED MCAP_PKG_CONSOLE_USER MCAP_PKG_CONSOLE_HOME MCAP_PIPELINE_DIR \
      MCAP_POLICY_PATH MCAP_SECURITY_BIN MCAP_BUILT_BY MCAP_DMG_SRC_ROOT MCAP_BUNDLE_DIR MCAP_UI_LANGUAGE MCAP_BUNDLE_ID MCAP_ALLOW_ID_CHANGE MCAP_APP_NAME MCAP_APP_SHORT_NAME

# The bundle identifier is a build input (scripts/bundle_id.sh): the neutral default, and the id of somebody else's build.
DEFAULT_ID="org.meetingcapture.app"
CUSTOM_ID="com.example.mcap-test"
# The two names of the app are build inputs too (scripts/bundle_id.sh): the defaults, and the names of somebody else's build.
DEFAULT_NAME="Catch Everything"
DEFAULT_SHORT="CATE"
CUSTOM_NAME="Example Recorder"
CUSTOM_SHORT="ExampleRecorder"

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    - $1"; echo "  FAIL $1"; }
check()   { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }          # check <status> <name>
section() { echo; echo "== $*"; }
# out_has <regex> <name> / out_lacks <regex> <name>: look in the last captured output
show_tail() { tail -n 8 "$OUT" 2>/dev/null | cut -c1-200 | sed 's/^/        | /'; }
out_has()   { if grep -Eq -- "$1" "$OUT"; then ok "$2"; else bad "$2   (expected /$1/)"; show_tail; fi; }
out_lacks() { if grep -Eq -- "$1" "$OUT"; then bad "$2   (found /$1/)"; sed -n "1,200p" "$OUT" | grep -E -- "$1" | head -3 | sed 's/^/        > /'; else ok "$2"; fi; }
rc_is()     { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2   (exit code $RC, expected $1)"; show_tail; fi; }
rc_not()    { if [ "$RC" != "$1" ]; then ok "$2"; else bad "$2   (exit code was $RC)"; show_tail; fi; }
count_in()  { grep -c -- "$1" "$2" 2>/dev/null || true; }

# ---------------------------------------------------------------------------------------------------------------
# stubs
# ---------------------------------------------------------------------------------------------------------------
STUBS_BASE="$WORK/stubs-base"       # launchctl, open, osascript, tccutil, security
STUBS_SIGN="$WORK/stubs-sign"       # the same + a stub codesign
mkdir -p "$STUBS_BASE" "$STUBS_SIGN"

cat > "$STUBS_BASE/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "${STUB_LOG:?}/launchctl.log"
exit "${STUB_LAUNCHCTL_RC:-3}"
EOF
for name in open osascript tccutil; do
    cat > "$STUBS_BASE/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "\${STUB_LOG:?}/$name.log"
exit 0
EOF
done

cat > "$STUBS_BASE/security" <<'EOF'
#!/bin/sh
# Fake `security`. State directory: $STUB_STATE (identities = lines "HASH|name|note"). Only what the scripts may use.
LOG="${STUB_LOG:?}"
echo "security $*" >> "$LOG/security.log"
S="${STUB_STATE:?}"
case "$1" in
  find-identity)
    echo "Policy: Code Signing"
    echo "  Matching identities"
    n=0
    if [ -f "$S/identities" ]; then
      while IFS='|' read -r h name note; do
        [ -n "$h" ] || continue
        n=$((n + 1)); echo "  $n) $h \"$name\"$note"
      done < "$S/identities"
    fi
    echo "     $n identities found"
    echo
    echo "  Valid identities only"
    v=0
    if [ -f "$S/identities" ]; then
      while IFS='|' read -r h name note; do
        [ -n "$h" ] || continue
        if [ -z "$note" ] || [ -f "$S/trusted" ]; then v=$((v + 1)); echo "  $v) $h \"$name\""; fi
      done < "$S/identities"
    fi
    echo "     $v valid identities found"
    exit 0 ;;
  login-keychain)
    echo "    \"$S/login.keychain-db\""
    exit 0 ;;
  import)
    file="$2"; shift 2; pass=""
    while [ $# -gt 0 ]; do case "$1" in -P) pass="$2"; shift ;; esac; shift; done
    echo "$pass" > "$S/last-p12-password"
    /usr/bin/openssl pkcs12 -in "$file" -passin "pass:$pass" -nokeys 2>/dev/null | /usr/bin/openssl x509 > "$S/cert.pem" 2>/dev/null || { echo "stub: cannot read the p12" >&2; exit 1; }
    fp="$(/usr/bin/openssl x509 -in "$S/cert.pem" -noout -fingerprint -sha1 | sed -e 's/^.*=//' -e 's/://g')"
    note=""; [ "${STUB_UNTRUSTED:-1}" = 1 ] && note=" (CSSMERR_TP_NOT_TRUSTED)"
    echo "$fp|MeetingCapture Local Signing|$note" >> "$S/identities"
    echo "1 identity imported."
    exit 0 ;;
  find-certificate)
    cat "$S/cert.pem" 2>/dev/null || exit 44
    exit 0 ;;
  add-trusted-cert)
    touch "$S/trusted"
    exit 0 ;;
  *)
    echo "FORBIDDEN security $*" >> "$LOG/forbidden.log"
    echo "stub security: refusing '$1'" >&2
    exit 99 ;;
esac
EOF

cat > "$STUBS_SIGN/codesign" <<'EOF'
#!/bin/sh
# Fake codesign: records the signature (what was passed to --sign) next to the target; honours $STUB_CODESIGN_MODE:
#   ok (default) | needs_trust (identity refused until `security add-trusted-cert` ran) | access (errSecInternalComponent)
LOG="${STUB_LOG:?}"
S="${STUB_STATE:?}"
echo "codesign $*" >> "$LOG/codesign.log"
sigfile() { if [ -d "$1" ]; then echo "$1/.stubsig"; else echo "$1.stubsig"; fi; }
case "$1" in
  --force)
    sign=""; ident=""; target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force|--timestamp=*) ;;
        --sign) sign="$2"; shift ;;
        --identifier) ident="$2"; shift ;;
        *) target="$1" ;;
      esac
      shift
    done
    case "${STUB_CODESIGN_MODE:-ok}" in
      needs_trust) if [ "$sign" != "-" ] && [ ! -f "$S/trusted" ]; then echo "$sign: no identity found" >&2; exit 1; fi ;;
      access)      if [ "$sign" != "-" ]; then echo "$target: errSecInternalComponent" >&2; exit 1; fi ;;
    esac
    printf '%s\n%s\n' "$sign" "$ident" > "$(sigfile "$target")"
    exit 0 ;;
  --verify) exit 0 ;;
  -d|-dvvv)
    target=""; want_dr=0
    for a in "$@"; do case "$a" in -r-) want_dr=1 ;; -d|-dvvv) ;; *) target="$a" ;; esac; done
    f="$(sigfile "$target")"
    [ -f "$f" ] || { echo "$target: code object is not signed at all" >&2; exit 1; }
    sign="$(sed -n 1p "$f")"; ident="$(sed -n 2p "$f")"
    if [ "$want_dr" = 1 ]; then
      echo "Executable=$target" >&2
      if [ "$sign" = "-" ]; then echo "# designated => cdhash H\"0123456789abcdef0123456789abcdef01234567\""
      else echo "designated => identifier \"$ident\" and certificate leaf = H\"$(echo "$sign" | tr 'A-F' 'a-f')\""; fi
    else
      echo "Executable=$target" >&2
      echo "Identifier=$ident" >&2
      echo "Format=app bundle with Mach-O thin (arm64)" >&2
      if [ "$sign" = "-" ]; then
        echo "CodeDirectory v=20400 size=338 flags=0x2(adhoc) hashes=4+3 location=embedded" >&2
        echo "CDHash=0123456789abcdef0123456789abcdef01234567" >&2
        echo "Signature=adhoc" >&2
      else
        name="$(grep -i "^$sign|" "$S/identities" 2>/dev/null | head -n 1 | cut -d'|' -f2)"
        echo "CodeDirectory v=20400 size=338 flags=0x0(none) hashes=4+3 location=embedded" >&2
        echo "CDHash=0123456789abcdef0123456789abcdef01234567" >&2
        echo "Signature size=1500" >&2
        echo "Authority=${name:-Unknown}" >&2
      fi
      echo "TeamIdentifier=not set" >&2
    fi
    exit 0 ;;
  *) echo "stub codesign: unexpected $*" >&2; exit 98 ;;
esac
EOF
cp "$STUBS_BASE"/* "$STUBS_SIGN"/          # STUBS_SIGN = the base stubs + codesign (written above)
chmod +x "$STUBS_BASE"/* "$STUBS_SIGN"/*
[ -x "$STUBS_SIGN/codesign" ] && [ ! -e "$STUBS_BASE/codesign" ] || { echo "internal error: stub layout is wrong"; exit 1; }

# tiny Swift program standing in for app/Sources (the real build takes minutes; build_app.sh only needs a main.swift)
mkdir -p "$WORK/swiftsrc"
printf 'import Foundation\nprint("stub")\n' > "$WORK/swiftsrc/main.swift"
MODCACHE="$WORK/modcache"; mkdir -p "$MODCACHE"

# ---------------------------------------------------------------------------------------------------------------
# environment per test group
# ---------------------------------------------------------------------------------------------------------------
H=""; LOGS=""; STATE=""; STUBS="$STUBS_BASE"
fresh_env() {   # $1 = base | sign | pkg (the company packaging stubs, defined further down); $2 = root: id and stat answer "root" as well
    N=$((N + 1))
    H="$WORK/env$N/home"; LOGS="$WORK/env$N/logs"; STATE="$WORK/env$N/state"
    mkdir -p "$H/tmp" "$LOGS" "$STATE"
    case "${1:-base}" in sign) STUBS="$STUBS_SIGN" ;; pkg) STUBS="$STUBS_PKG" ;; *) STUBS="$STUBS_BASE" ;; esac
    if [ "${2:-}" = root ]; then STUBS="$STUBS_ROOT:$STUBS"; fi
    SUPPORT="$H/Library/Application Support/MeetingCapture"
    APPLOGS="$H/Library/Logs/MeetingCapture"
}
# runx [VAR=value ...] command args...   runs inside the fake environment, stdin = /dev/null; sets OUT (file) and RC
runx() {
    N=$((N + 1))
    OUT="$WORK/out.$N.txt"
    ( cd "$ROOT" && env HOME="$H" PATH="$STUBS:$PATH" TMPDIR="$H/tmp" \
        MCAP_SUPPORT_DIR="$SUPPORT" MCAP_LOG_DIR="$APPLOGS" CLANG_MODULE_CACHE_PATH="$MODCACHE" \
        STUB_LOG="$LOGS" STUB_STATE="$STATE" "$@" ) > "$OUT" 2>&1 < /dev/null
    RC=$?
}
home_is_empty() {   # nothing except the temp dir was created in the fake HOME
    [ -z "$(find "$H" -mindepth 1 -not -path "$H/tmp" -not -path "$H/tmp/*" 2>/dev/null | head -n 1)" ]
}
stub_loaded() {     # a stub must really be the first one on PATH: never test with a real launchctl/security
    for s in launchctl security open; do
        [ -x "$STUBS/$s" ] || { echo "internal error: no stub $s in $STUBS"; exit 1; }
    done
}
add_identity() {    # add_identity HASH [note]
    echo "$1|MeetingCapture Local Signing|${2:-}" >> "$STATE/identities"
}
HASH_A="1111111111111111111111111111111111111111"
HASH_B="ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD"
OTHER_NAME_HASH="3333333333333333333333333333333333333333"

make_support_tree() {   # a believable installation inside the fake HOME
    mkdir -p "$H/Library/LaunchAgents" "$H/Applications/$DEFAULT_SHORT.app/Contents/MacOS" "$SUPPORT/sessions/_discarded/old1" \
             "$SUPPORT/sessions/2026-10-07_1400_meet" "$SUPPORT/sessions/2026-10-06_0900_zoom" "$SUPPORT/venv" "$APPLOGS"
    echo plist > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
    echo '{"schema":1}' > "$SUPPORT/sessions/2026-10-07_1400_meet/session.json"
    echo '{"stage":"done","final_dir":"/x"}' > "$SUPPORT/sessions/2026-10-06_0900_zoom/state.json"    # tombstone of a published meeting
    # housekeeping folders start with "_" and are never counted, even if one holds a session.json (pins the "_*" rule on its own,
    # the real _discarded/<id>/ layout is excluded by the session.json rule as well)
    echo '{"schema":1}' > "$SUPPORT/sessions/_discarded/session.json"
    echo cfg > "$SUPPORT/config.env"
    echo log > "$APPLOGS/app.log"
}

# ---------------------------------------------------------------------------------------------------------------
section "static checks of all scripts (bash 3.2, no ERR traps)"
# ---------------------------------------------------------------------------------------------------------------
ALL_SCRIPTS="$(ls "$ROOT"/scripts/*.sh "$ROOT"/scripts/bench_kit/*.sh "$ROOT"/scripts/mdm/*.sh "$ROOT"/scripts/pkg/preinstall "$ROOT"/scripts/pkg/postinstall "$ROOT"/scripts/asr_server/install_server.sh)"
bad_syntax=0
for f in $ALL_SCRIPTS; do /bin/bash -n "$f" || { bad_syntax=1; echo "      syntax error in $f"; }; done
check $bad_syntax "bash -n passes for every script ($(echo "$ALL_SCRIPTS" | wc -l | tr -d ' ') files)"
# set -E + trap ERR misfires inside $(...) on bash 3.2 (review finding): neither may come back
if grep -nE '^[[:space:]]*set[[:space:]]+-[A-Za-z]*E|trap[[:space:]].*[[:space:]]ERR' $ALL_SCRIPTS | grep -v 'test_scripts.sh' | grep -vE ':[0-9]+:[[:space:]]*#' > "$WORK/errtrap.txt"; then
    bad "no script uses set -E or an ERR trap"; sed 's/^/        > /' "$WORK/errtrap.txt"
else
    ok "no script uses set -E or an ERR trap"
fi
for f in $ALL_SCRIPTS; do
    case "$(basename "$f")" in test_scripts.sh) continue ;; esac
    grep -q '^set -euo pipefail$' "$f" || bad "$(basename "$f") starts with set -euo pipefail"
done
ok "every script has set -euo pipefail (a missing one is reported above)"
plutil -lint "$ROOT/app/Info.plist.template" >/dev/null 2>&1; check $? "Info.plist.template is a valid plist"

# ---------------------------------------------------------------------------------------------------------------
section "review finding: ERR trap / set -E printed a bogus FAILED line (bash 3.2)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
cat > "$WORK/errtrap_demo.sh" <<'EOF'
set -Eeuo pipefail
trap 'echo "TRAP FIRED" >&2' ERR
f() { return 1; }
if v="$(f 2>/dev/null)" && [ -n "$v" ]; then :; fi
EOF
/bin/bash "$WORK/errtrap_demo.sh" 2>&1 | grep -q "TRAP FIRED"
check $? "(premise) /bin/bash 3.2 with set -E still runs the ERR trap inside \$(...) in an if: why the scripts must not use it"
mkdir -p "$SUPPORT"; printf 'SELF_NAME=Tester\n' > "$SUPPORT/config.env"      # an existing config.env WITHOUT a PROJECT_DIR key
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
rc_is 0 "install.sh with a config.env that has no PROJECT_DIR key succeeds"
out_lacks 'FAILED at line' "install.sh prints no FAILED-at-line message for the missing PROJECT_DIR key"

# the not-cached model lookup in setup_python.sh (if path="$(snapshot ...)" && weights_ok): run download_model with a fake model
fresh_env base
cat > "$WORK/dl_test.sh" <<EOF
. "$ROOT/scripts/setup_python.sh"          # only defines functions when sourced
HF_HOME="$WORK/hf-fake"; export HF_HOME
mkdir -p "\$HF_HOME"
model_lookup() { M_ALLOW=""; M_IGNORE=""; M_MAIN_REF=0; M_REPO="fake/model"; M_REV="deadbeefdeadbeef"; M_BYTES=5; M_FILE="weights.npz"
                 M_FILE_BYTES=5; M_FILE_SHA="\$(printf 'hello' | shasum -a 256 | awk '{print \$1}')"; return 0; }
snapshot() {   # \$6 = local_files_only: the cache lookup fails (not cached), the real download works
    if [ "\$6" = 1 ]; then return 1; fi
    mkdir -p "$WORK/hf-fake/snap"; printf 'hello' > "$WORK/hf-fake/snap/weights.npz"; echo "$WORK/hf-fake/snap"
}
free_kb() { echo 99999999; }
download_model whatever
EOF
runx /bin/bash "$WORK/dl_test.sh"
rc_is 0 "setup_python.sh download_model works when the model is not cached yet"
out_has 'ready' "download_model reports the model as ready"
out_lacks 'FAILED at line' "no bogus FAILED-at-line message on the not-cached lookup path"

# the pinned numpy 2.5.3 and scipy 1.18.1 need Python 3.12 or newer: check_python_version must stop on 3.11 (not inside pip) and accept 3.12 and 3.13
cat > "$WORK/fakepy.sh" <<'EOF'
#!/bin/sh
# fake interpreter: $1 is -c, $2 the program; FAKE_PY_VERSION says what it claims to be
case "$2" in
    *'print("%d.%d.%d"'*) echo "$FAKE_PY_VERSION" ;;
    *) minor="$(echo "$FAKE_PY_VERSION" | cut -d. -f2)"; [ "$minor" -ge 12 ] ;;
esac
EOF
chmod 755 "$WORK/fakepy.sh"
for pv in 3.11.9 3.12.4 3.13.2; do
    runx env FAKE_PY_VERSION=$pv /bin/bash -c ". '$ROOT/scripts/setup_python.sh'; check_python_version '$WORK/fakepy.sh'"
    case "$pv" in
        3.11.*) rc_is 1 "check_python_version refuses Python $pv"; out_has 'need 3\.12 or newer' "... and says that 3.12 or newer is needed" ;;
        3.12.*) rc_is 0 "check_python_version accepts Python $pv"; out_has 'fallback' "... with the 'verified on 3.13' warning" ;;
        *)      rc_is 0 "check_python_version accepts Python $pv"; out_lacks 'WARNING' "... without a warning" ;;
    esac
done

# ---------------------------------------------------------------------------------------------------------------
section "review finding: live commands (--live, open -n) in install.sh, the READMEs, INSTALL, LIVE_TEST"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
runx /bin/bash scripts/install.sh --dry-run
rc_is 0 "install.sh --dry-run succeeds in a fake HOME"
out_has 'selftest-capture --live --seconds' "install.sh prints selftest-capture WITH --live"
out_lacks 'selftest-capture --seconds' "install.sh never prints selftest-capture without a mode flag"
out_has 'open -n -W -a' "install.sh prints open -n -W -a for the live commands"
out_lacks 'open -W -a' "install.sh prints no open -W without -n"
out_has 'note_prompt.md: not copied' "install.sh says note_prompt.md is not copied (SPEC 14.4)"
out_has 'docs/LIVE_TEST.md' "install.sh points to docs/LIVE_TEST.md"
out_has '--args setup' "install.sh prints the permission step (setup)"
out_has 'Microphone, System Audio Recording,' "the permission step lists Microphone and System Audio Recording"
out_has 'Google Drive folder, Notifications' "... and the Google Drive folder and Notifications prompts"
out_has 'prompt only appears if meet is in ENABLED_PLATFORMS' "the Chrome automation prompt is only mentioned as conditional on meet (Meet is off by default)"
out_has "Zoom 'New Meeting' alone" "install.sh's next steps name the solo Zoom call"
out_has "Teams 'Meet now' alone" "... and the solo Teams call"
out_has 'make confirm-live-tested' "install.sh's next steps name make confirm-live-tested before the LaunchAgent"
out_has 'ENABLED_PLATFORMS defaults to' "install.sh says what ENABLED_PLATFORMS defaults to"
out_has 'Google Meet detection is OFF' "... and that Google Meet detection is off"
out_has 'not written: you have not confirmed the live test yet' "install.sh does not write the LaunchAgent plist before the live test is confirmed"
out_has 'every call of the other call apps of the built-in table' "... and says that the login agent records the other call apps of the table too (not only Zoom / Teams)"
home_is_empty; check $? "install.sh --dry-run creates nothing in HOME"
[ ! -s "$LOGS/launchctl.log" ]; check $? "install.sh --dry-run never calls launchctl"
[ ! -s "$LOGS/forbidden.log" ]; check $? "install.sh --dry-run uses no forbidden security subcommand"

DOCS="$ROOT/README.md $ROOT/README.ko.md $ROOT/docs/INSTALL.md $ROOT/docs/CONFIGURATION.md $ROOT/docs/LIVE_TEST.md $ROOT/docs/LIVE_TEST.en.md $ROOT/docs/DETECTION.md $ROOT/docs/BENCH_KIT.md $ROOT/scripts/bench_kit/README.md $ROOT/docs/DISTRIBUTE.md $ROOT/docs/USER_GUIDE.ko.md $ROOT/docs/USER_GUIDE.md"
missing_doc=0; for f in $DOCS; do [ -f "$f" ] || { missing_doc=1; echo "      missing doc $f"; }; done
check $missing_doc "README.md, README.ko.md, docs/INSTALL.md, docs/CONFIGURATION.md, docs/LIVE_TEST.md, docs/LIVE_TEST.en.md, docs/DETECTION.md, docs/BENCH_KIT.md and the bench kit README exist"
# every `open ... --args` in the docs and scripts must use -n (SPEC 14.4): without it a running menu-bar app only gets re-activated
if grep -nE 'open +(-W|-a)' $DOCS "$ROOT"/scripts/*.sh 2>/dev/null | grep -vE 'open +-n ' | grep -v test_scripts.sh > "$WORK/open_nonn.txt"; then
    bad "every documented 'open -W/-a ... --args' command has -n"; sed 's/^/        > /' "$WORK/open_nonn.txt"
else
    ok "every documented 'open -W/-a ... --args' command has -n"
fi
# every selftest-capture command must say --live or --synthetic (main.swift fails closed without one of them)
if grep -nE 'selftest-capture' $DOCS "$ROOT"/scripts/install.sh "$ROOT"/Makefile 2>/dev/null | grep -E -- '--(seconds|out)' | grep -vE -- '--(live|synthetic)' > "$WORK/st_nomode.txt"; then
    bad "every selftest-capture command with arguments names --live or --synthetic"; sed 's/^/        > /' "$WORK/st_nomode.txt"
else
    ok "every selftest-capture command with arguments names --live or --synthetic"
fi
# every app subcommand named after --args exists in main.swift, every `-m mcap <cmd>` exists in cli.py
bad_cmd=0
for sub in $(grep -ohE -- '--args +[a-z-]+' $DOCS "$ROOT"/scripts/install.sh 2>/dev/null | awk '{print $2}' | sort -u); do
    grep -q "case \"$sub\"" "$ROOT/app/Sources/main.swift" || { bad_cmd=1; echo "      app subcommand '$sub' is not in main.swift"; }
done
for sub in $(grep -ohE -- '-m mcap +[a-z-]+' $DOCS 2>/dev/null | awk '{print $3}' | sort -u); do
    grep -qE "add_parser\(\"$sub\"|\"$sub\"" "$ROOT/pipeline/mcap/cli.py" || { bad_cmd=1; echo "      mcap command '$sub' is not in cli.py"; }
done
check $bad_cmd "every app subcommand / mcap command used in the docs exists in main.swift / cli.py"

# doc-vs-CLI consistency: every flag / make target / subcommand written in the docs exists in the code it belongs to
cat > "$WORK/doc_check.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
docs = [os.path.join(root, f) for f in ("README.md", "README.ko.md", "docs/INSTALL.md", "docs/CONFIGURATION.md", "docs/LIVE_TEST.md", "docs/LIVE_TEST.en.md", "docs/BENCH_KIT.md",
                                         "scripts/bench_kit/README.md", "docs/DETECTION.md", "docs/DEPLOY.md", "docs/OPS_RUNBOOK.md", "docs/MIGRATION.md", "docs/SETTINGS.md", "docs/BRANDING.md",
                                         "docs/DISTRIBUTE.md", "docs/USER_GUIDE.ko.md", "docs/USER_GUIDE.md")]
swift = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(root, "app/Sources/*.swift")))
cli = open(os.path.join(root, "pipeline/mcap/cli.py"), encoding="utf-8").read()
make = open(os.path.join(root, "Makefile"), encoding="utf-8").read()
scripts = {os.path.basename(f): open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(root, "scripts/*.sh")) + glob.glob(os.path.join(root, "scripts/bench_kit/*.sh"))
           + glob.glob(os.path.join(root, "scripts/mdm/*.sh")) + glob.glob(os.path.join(root, "scripts/asr_server/*.sh"))}
problems = []
def tail(text):                      # the command's arguments: up to a comment, backtick, && ; | ) or the end of the line
    return re.split(r"\s#|`|&&|;|\||\)", text, maxsplit=1)[0]
def flags(text):
    return re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", tail(text))
for doc in docs:
    for no, line in enumerate(open(doc, encoding="utf-8"), 1):
        where = "%s:%d" % (os.path.relpath(doc, root), no)
        for m in re.finditer(r"scripts/((?:bench_kit/|mdm/|asr_server/)?[a-z_]+\.sh)(.*)", line):
            name = os.path.basename(m.group(1))
            if name not in scripts:
                problems.append("%s: no such script scripts/%s" % (where, m.group(1))); continue
            for f in flags(m.group(2)):
                if f not in scripts[name]:
                    problems.append("%s: scripts/%s has no option %s" % (where, name, f))
        for m in re.finditer(r"\bmake ([a-z][a-z-]*)", line):
            if not re.search(r"^%s:" % re.escape(m.group(1)), make, re.M) and m.group(1) not in ("it", "sure"):
                problems.append("%s: no make target '%s'" % (where, m.group(1)))
        for m in re.finditer(r"-m mcap ([a-z][a-z-]*)(.*)", line):
            if '"%s"' % m.group(1) not in cli:
                problems.append("%s: no mcap command %s" % (where, m.group(1)))
            for f in flags(m.group(2)):
                if '"%s"' % f not in cli:
                    problems.append("%s: mcap has no option %s" % (where, f))
        for m in re.finditer(r"--args ([a-z][a-z-]*)(.*)", line):
            if 'case "%s"' % m.group(1) not in swift:
                problems.append("%s: the app has no subcommand %s" % (where, m.group(1)))
            for f in flags(m.group(2)):
                if '"%s"' % f not in swift:
                    problems.append("%s: the app has no option %s" % (where, f))
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
python3 "$WORK/doc_check.py" "$ROOT" > "$WORK/doc_check.out" 2>&1; DOC_RC=$?
if [ "$DOC_RC" = 0 ]; then ok "every script flag, make target, mcap command/flag and app subcommand/flag used in the READMEs / INSTALL / CONFIGURATION / LIVE_TEST / BENCH_KIT / DEPLOY / OPS_RUNBOOK / MIGRATION exists in the code"
else bad "docs mention things that do not exist in the code:"; sed 's/^/        > /' "$WORK/doc_check.out"; fi

# ---------------------------------------------------------------------------------------------------------------
section "docs: Meet off by default, Zoom first, documented config keys exist in the code and in config.env.example (SPEC 15)"
# ---------------------------------------------------------------------------------------------------------------
cat > "$WORK/doc_topics.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
def read(rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()
config_doc, live = read("docs/CONFIGURATION.md"), read("docs/LIVE_TEST.md")
example = read("config/config.env.example")
types_swift = read("app/Sources/Types.swift")
swift = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(root, "app/Sources/*.swift")))
config_py = read("pipeline/mcap/config.py")
problems = []
def need(cond, text):
    if not cond:
        problems.append(text)

# 1. the defaults agree: config.env.example, the Swift default, the CONFIGURATION.md table (Meet is OFF)
m = re.search(r"^ENABLED_PLATFORMS=([a-z,]+)", example, re.M)
need(m is not None and m.group(1) == "zoom,teams", "config.env.example: ENABLED_PLATFORMS must default to zoom,teams (got %r)" % (m and m.group(1)))
need(re.search(r"var enabledPlatforms: \[Platform\] = \[\.zoom, \.teams\]", types_swift) is not None, "Types.swift: enabledPlatforms must default to [.zoom, .teams]")
need(re.search(r"^\| `ENABLED_PLATFORMS` \| `zoom,teams` \|", config_doc, re.M) is not None, "CONFIGURATION.md table: ENABLED_PLATFORMS default must be `zoom,teams`")

# 2. LIVE_TEST order: install checks -> setup -> live selftest -> Zoom -> Teams -> resilience -> LaunchAgent; Meet only as the appendix
heads = [(m.start(), m.group(0)) for m in re.finditer(r"^## .*$", live, re.M)]
def pos(prefix):
    for at, text in heads:
        if text.startswith(prefix):
            return at
    problems.append("LIVE_TEST.md has no heading starting with %r" % prefix)
    return -1
order = [pos("## 1. "), pos("## 2. "), pos("## 3. "), pos("## 4. "), pos("## 5. "), pos("## 6. "), pos("## 7. "), pos("## 8. "), pos("## 부록 A")]
need(order == sorted(order) and -1 not in order, "LIVE_TEST.md sections are not in the order 1..8, appendix A")
sec = {}
for i, (at, text) in enumerate(heads):
    end = heads[i + 1][0] if i + 1 < len(heads) else len(live)
    sec[text.split(".")[0] if text.startswith("## ") and text[3].isdigit() else text] = live[at:end]
need("Zoom" in sec.get("## 4", "") and "Teams" in sec.get("## 5", ""), "LIVE_TEST.md: section 4 must be the Zoom call and section 5 the Teams call")
need(re.search(r"Meet(?![A-Za-z])|meet\.google", "".join(sec.get(k, "") for k in ("## 4", "## 5")).replace("Meet now", "")) is None, "LIVE_TEST.md: sections 4 and 5 must not depend on Google Meet (only the Teams 'Meet now' button name)")
need("Chrome 자동화 프롬프트는 뜨지 않아야 한다" in sec.get("## 2", ""), "LIVE_TEST.md section 2 must say that no Chrome automation prompt appears while Meet is off")
need("Notifications" in sec.get("## 2", "") or "알림" in sec.get("## 2", ""), "LIVE_TEST.md section 2 must list the notification permission")
need("make confirm-live-tested" in sec.get("## 7", ""), "LIVE_TEST.md section 7 must contain make confirm-live-tested before the LaunchAgent")
need(sec.get("## 7", "").find("make confirm-live-tested") < sec.get("## 7", "").find("make_launchagent.sh --load"), "LIVE_TEST.md section 7: confirm-live-tested must come before make_launchagent.sh --load")
need("마이크 테스트" in sec.get("## 4", ""), "LIVE_TEST.md section 4 must include the Zoom Test Mic false-positive check")
need("음소거 60초" in sec.get("## 4", "") and "음소거 60초" in sec.get("## 5", ""), "LIVE_TEST.md sections 4 and 5 must both include the 60 s mute test")
for kw in ("Quit", "kill -9", "덮개 닫기 (녹음 중)", "덮개 닫기 (처리 중)", "장치 전환", "시스템 오디오 권한 끄기"):
    need(kw in sec.get("## 6", ""), "LIVE_TEST.md section 6 must cover: " + kw)
need("로그아웃" in sec.get("## 7", ""), "LIVE_TEST.md section 7 must include the logout/login test")
need("잠자기" in live and "덮개" in live, "LIVE_TEST.md must say that the Mac sleeps when the lid is closed")
for n in range(1, 8):
    need("**보낼 것**" in sec.get("## %d" % n, ""), "LIVE_TEST.md section %d has no '**보낼 것**' (what to send back)" % n)

# 3. CONFIGURATION.md: the topics a user needs to find there (the prose of the READMEs is not pinned)
for kw, why in (("NO_SPEECH_STOP_MINUTES", "NO_SPEECH_STOP_MINUTES"), ("RETRY_SWEEP_HOURS", "RETRY_SWEEP_HOURS"), ("ASR_LANGUAGES", "ASR_LANGUAGES"), ("ko,en,ja", "the ja option of ASR_LANGUAGES"),
                ("MAX_CLAUDE_CALLS_PER_MEETING", "MAX_CLAUDE_CALLS_PER_MEETING"), ("usage.jsonl", "usage.jsonl"), ("UI_LANGUAGE", "the UI language"), ("CALENDAR_LOOKUP", "the calendar lookup"),
                ("ENABLED_PLATFORMS=zoom,teams,meet", "how to turn Meet back on"), ("ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-", "how to archive into Google Drive")):
    need(kw in config_doc, "docs/CONFIGURATION.md must mention %s (%r)" % (why, kw))

# 4. every config key in the CONFIGURATION.md table is parsed by the code (Python config.py or a Swift source)
config_table = config_doc.split("## Settings (`config.env`)", 1)[-1].split("\n## ", 1)[0]       # the paths table above it has LOG_DIR etc. (directory names, not keys)
keys = re.findall(r"^\| `([A-Z][A-Z0-9_]+)` \|", config_table, re.M)
need(len(keys) >= 25, "CONFIGURATION.md table: expected at least 25 keys, found %d" % len(keys))
for key in keys:
    if ('"%s"' % key) not in config_py and ('"%s"' % key) not in swift:
        problems.append("CONFIGURATION.md documents %s but neither config.py nor the Swift sources parse it" % key)
# 4b. and the other way round: every key config.py parses (the SPEC 18 keys included) has a row in the CONFIGURATION.md table
parsed = re.findall(r'^    "([A-Z][A-Z0-9_]+)": \(', config_py, re.M)
need(len(parsed) >= 50, "config.py: expected at least 50 parsed keys in _KEYS, found %d" % len(parsed))
for key in parsed:
    if key not in keys:
        problems.append("config.py parses %s but the CONFIGURATION.md table has no row for it" % key)
# 5. the CONFIGURATION.md table and config/config.env.example have the same keys and the same defaults. The keys of the privacy section
# (SPEC 18) are commented out in the example ('# KEY=default'): they count, with the same default, as lines of the example
example_values = dict(re.findall(r"^([A-Z][A-Z0-9_]+)=(.*?)(?:[ \t]+#.*)?$", example, re.M))        # [ \t]: an inline comment, never a newline (it would swallow the next line)
commented_values = dict(re.findall(r"^# ([A-Z][A-Z0-9_]+)=(.*?)(?:[ \t]+#.*)?$", example, re.M))
EXAMPLE_ONLY_COMMENTED = {"ZOOM_STRONG_SOCKETS", "ZOOM_WEAK_DEBOUNCE_SECONDS", "SUPPORT_DIR"}      # commented, deliberately not a table row (tier keys, tests only)
all_example = dict(commented_values)
all_example.update(example_values)
for key, default in re.findall(r"^\| `([A-Z][A-Z0-9_]+)` \| `([^`]*)` \|", config_table, re.M):
    if key not in all_example:
        problems.append("config.env.example has no line (not even a commented one) for %s (documented in the CONFIGURATION.md table)" % key)
    elif not default.startswith("<") and all_example[key].strip() != default.strip():
        problems.append("%s: CONFIGURATION.md default %r differs from config.env.example %r" % (key, default, all_example[key]))
for key in example_values:
    if key not in keys:
        problems.append("config.env.example sets %s but the CONFIGURATION.md table does not document it" % key)
for key in commented_values:
    if key not in keys and key not in EXAMPLE_ONLY_COMMENTED and key not in example_values:
        problems.append("config.env.example has the commented key %s but the CONFIGURATION.md table does not document it" % key)
for key in keys:
    if key not in all_example:
        problems.append("CONFIGURATION.md documents %s but config.env.example has no line for it" % key)
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
python3 "$WORK/doc_topics.py" "$ROOT" > "$WORK/doc_topics.out" 2>&1; TOPIC_RC=$?
if [ "$TOPIC_RC" = 0 ]; then ok "Meet is off by default everywhere, LIVE_TEST is Zoom -> Teams -> resilience -> LaunchAgent with Meet as appendix A, CONFIGURATION.md documents every config key the code parses (and the example file agrees)"
else bad "documentation checks (SPEC 15) failed:"; sed 's/^/        > /' "$WORK/doc_topics.out"; fi

# ---------------------------------------------------------------------------------------------------------------
section "Settings window and icons: docs, keys and the icon generator (docs/SETTINGS.md, docs/BRANDING.md, scripts/make_icon.swift)"
# ---------------------------------------------------------------------------------------------------------------
cat > "$WORK/doc_settings.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
def read(rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()
problems = []
def need(cond, text):
    if not cond:
        problems.append(text)
model = read("app/Sources/SettingsModel.swift")
keys = re.findall(r'SettingsField\(key: "([A-Z0-9_]+)"', model)
need(len(keys) == 20 and len(set(keys)) == 20, "SettingsModel.swift: expected twenty distinct keys in the catalog, found %d" % len(keys))
settings, config_doc, example = read("docs/SETTINGS.md"), read("docs/CONFIGURATION.md"), read("config/config.env.example")
config_table = config_doc.split("## Settings (`config.env`)", 1)[-1].split("\n## ", 1)[0]
config_py = read("pipeline/mcap/config.py")
other_swift = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(root, "app/Sources/*.swift")) if not os.path.basename(f).startswith("Settings"))
for key in keys:
    need("`%s`" % key in settings, "docs/SETTINGS.md does not explain %s" % key)
    need(re.search(r"^\| `%s` \|" % key, config_table, re.M) is not None, "docs/CONFIGURATION.md has no row for %s (an edited key)" % key)
    need(re.search(r"^#? ?%s=" % key, example, re.M) is not None, "config/config.env.example has no line for %s (an edited key)" % key)
    need(('"%s": (' % key) in config_py or ('"%s"' % key) in other_swift, "%s is parsed by neither config.py nor a Swift parser" % key)
    need(not re.search(r"API_KEY|TOKEN|SECRET|PASSWORD|_KEY$", key), "%s looks like a secret: secrets are Keychain items, never config keys" % key)
for needle, why in (("MeetingCapture Anthropic API key", "the service of the Anthropic key"), ("MeetingCapture ASR clova", "the service of the CLOVA key"),
                    ("security -i", "how a key is written"), ("python -m mcap asr-engines consent", "the consent command"), ("python -m mcap gcal auth", "the Google sign-in command"),
                    ("never writes", "that the window never writes the consent"), ("Not verified", "what was not verified"), ("Only Zoom has been verified", "the Zoom-only status"),
                    ("config.env.bak-settings-", "the backups"), ("Restart after the recording", "the restart guard"), ("Policy locks", "the policy locks")):
    need(needle in settings, "docs/SETTINGS.md must mention %s (%r)" % (why, needle))
for rel in ("README.md", "README.ko.md", "docs/INSTALL.md", "docs/CONFIGURATION.md", "docs/PRIVACY_LANES.md"):
    need("SETTINGS.md" in read(rel), "%s must link to docs/SETTINGS.md" % rel)
need("Settings window" in read("SECURITY.md") and "Settings window" in read("CHANGELOG.md"), "SECURITY.md and CHANGELOG.md must have an entry for the Settings window")
status_menu, branding, icon_src = read("app/Sources/StatusMenu.swift"), read("docs/BRANDING.md"), read("scripts/make_icon.swift")
need('keyEquivalent: ","' in status_menu and "Settings" in status_menu, "StatusMenu.swift: the Settings item with Cmd-,")
for name in ("pencil.and.list.clipboard", "pencil.and.scribble", "pencil.line", "pause.circle", "pencil.slash", "ellipsis.bubble", "checkmark.circle", "exclamationmark.triangle"):
    need(name in status_menu, "StatusMenu.swift: the symbol %s" % name)
    need(name in branding, "docs/BRANDING.md: the symbol %s" % name)
for v in ("D1", "D2", "D3", "A", "B", "C"):
    need("`%s`" % v in branding, "docs/BRANDING.md must describe variant %s" % v)
    need('"%s": Variant(' % v in icon_src, "make_icon.swift has no variant %s" % v)
need("--variant D1|D2|D3|A|B|C" in icon_src, "make_icon.swift: the usage names every variant")
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
python3 "$WORK/doc_settings.py" "$ROOT" > "$WORK/doc_settings.out" 2>&1; SET_RC=$?
if [ "$SET_RC" = 0 ]; then ok "the Settings window's twenty keys are parsed, documented (SETTINGS, CONFIGURATION, the example file), none is a secret; the docs state the Keychain method, the Terminal-only consent and what is not verified; the menu item, the icon symbols and every icon variant are documented"
else bad "Settings / icon documentation checks failed:"; sed 's/^/        > /' "$WORK/doc_settings.out"; fi

# the icon generator: every variant is accepted, an unknown one is a usage error, the output is deterministic, the icns decodes with iconutil
ICON_DIR="$WORK/icon"; mkdir -p "$ICON_DIR"
if swiftc -O "$ROOT/scripts/make_icon.swift" -o "$ICON_DIR/make_icon" >"$ICON_DIR/compile.log" 2>&1; then
    ok "scripts/make_icon.swift compiles"
    icon_ok=0
    for v in D1 D2 D3 A B C; do
        for size in 16 32 512; do
            "$ICON_DIR/make_icon" --variant "$v" --png "$ICON_DIR/$v-$size.png" --size "$size" >/dev/null 2>&1 && [ -s "$ICON_DIR/$v-$size.png" ] || { icon_ok=1; echo "      make_icon --variant $v --size $size failed"; }
        done
    done
    check $icon_ok "make_icon renders D1, D2, D3, A, B and C at 16, 32 and 512 px"
    "$ICON_DIR/make_icon" --variant Z --png "$ICON_DIR/z.png" >/dev/null 2>&1; [ "$?" = 2 ]; check $? "an unknown variant is a usage error (exit 2)"
    "$ICON_DIR/make_icon" "$ICON_DIR/one.icns" --variant D1 >/dev/null 2>&1; "$ICON_DIR/make_icon" "$ICON_DIR/two.icns" --variant D1 >/dev/null 2>&1
    cmp -s "$ICON_DIR/one.icns" "$ICON_DIR/two.icns"; check $? "the same variant gives the same bytes on every run (D1)"
    cmp -s "$ICON_DIR/D1-512.png" "$ICON_DIR/D2-512.png"; [ "$?" != 0 ]; check $? "D1 and D2 are different pictures"
    "$ICON_DIR/make_icon" --png "$ICON_DIR/default.png" >/dev/null 2>&1; cmp -s "$ICON_DIR/default.png" "$ICON_DIR/D1-512.png"; check $? "the default variant is D1 (the shipped icon)"
else
    bad "scripts/make_icon.swift compiles"; sed 's/^/        > /' "$ICON_DIR/compile.log" | head -10
fi
if iconutil -c iconset "$ROOT/app/Resources/AppIcon.icns" -o "$ICON_DIR/shipped.iconset" >/dev/null 2>&1 && [ -f "$ICON_DIR/shipped.iconset/icon_16x16.png" ] && [ -f "$ICON_DIR/shipped.iconset/icon_512x512@2x.png" ]; then
    ok "app/Resources/AppIcon.icns decodes with iconutil and has the 16 px and the 512@2x images"
else
    bad "app/Resources/AppIcon.icns decodes with iconutil and has the 16 px and the 512@2x images"
fi

# ---------------------------------------------------------------------------------------------------------------
section "install.sh: seeding rules (SPEC 14.4), real run in a fake HOME (no build, no launchctl)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
rc_is 0 "fresh install (no build, no agent) succeeds"
[ -f "$SUPPORT/config.env" ]; check $? "config.env was created"
[ -f "$SUPPORT/vocabulary.txt" ]; check $? "vocabulary.txt was created"
[ ! -e "$SUPPORT/note_prompt.md" ]; check $? "note_prompt.md was NOT copied"
grep -q '^PROJECT_DIR=' "$SUPPORT/config.env"; check $? "config.env has a PROJECT_DIR line"
cmp -s "$ROOT/config/vocabulary.txt" "$SUPPORT/vocabulary.txt"; check $? "vocabulary.txt is the repo version"
grep -q '^ARCHIVE_DIR=~/Meetings$' "$SUPPORT/config.env"; check $? "no Google Drive account mounted: ARCHIVE_DIR is the local folder ~/Meetings"
grep -q '^SELF_NAME=Me$' "$SUPPORT/config.env" && grep -q '^CLAUDE_AUTH=api$' "$SUPPORT/config.env" && grep -q '^NOTE_STOP_ON_OVERAGE=1$' "$SUPPORT/config.env"; check $? "the seeded config.env has the neutral defaults: label Me, api billing, extra-usage guard on"
grep -q '^CLAUDE_DAILY_BUDGET_USD=5$' "$SUPPORT/config.env" && grep -q '^CLAUDE_MEETING_BUDGET_USD=2$' "$SUPPORT/config.env" && grep -q '^CALENDAR_LOOKUP=0$' "$SUPPORT/config.env"; check $? "... small budgets (5 and 2 USD) and no calendar lookup"
out_has 'ARCHIVE_DIR=~/Meetings \(a local folder' "install.sh says where the meetings go (a local folder)"
# exactly one Google Drive account: its Meetings folder is chosen and the output says so; two accounts: nothing is guessed
fresh_env base; stub_loaded
mkdir -p "$H/Library/CloudStorage/GoogleDrive-me@example.com/My Drive"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
grep -q '^ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Meetings$' "$SUPPORT/config.env"; check $? "exactly one Google Drive account: ARCHIVE_DIR is its My Drive/Meetings folder"
out_has 'the one Google Drive account found' "... and install.sh says so, with the way back to a local folder"
fresh_env base; stub_loaded
mkdir -p "$H/Library/CloudStorage/GoogleDrive-a@example.com/My Drive" "$H/Library/CloudStorage/GoogleDrive-b@example.com/My Drive"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
grep -q '^ARCHIVE_DIR=~/Meetings$' "$SUPPORT/config.env"; check $? "two Google Drive accounts: no guess, ARCHIVE_DIR stays the local folder"
fresh_env base; stub_loaded
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
SUM1="$(cat "$SUPPORT/config.env" "$SUPPORT/vocabulary.txt" | shasum | awk '{print $1}')"
# edits are kept and a diff hint is printed, never overwritten
echo "My Private Term" >> "$SUPPORT/vocabulary.txt"
echo "SELF_NAME=Someone" >> "$SUPPORT/config.env"
SUM2="$(cat "$SUPPORT/config.env" "$SUPPORT/vocabulary.txt" | shasum | awk '{print $1}')"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
rc_is 0 "re-run succeeds"
SUM3="$(cat "$SUPPORT/config.env" "$SUPPORT/vocabulary.txt" | shasum | awk '{print $1}')"
[ "$SUM2" = "$SUM3" ]; check $? "re-run does not touch your edited config.env / vocabulary.txt"
out_has "diff -u '.*vocabulary.txt' '.*config/vocabulary.txt'" "a diff hint is printed for a vocabulary.txt that differs from the repo version"
out_has 'never overwritten' "the hint says the file is never overwritten"
# a vocabulary without the proper nouns: the new repo terms are listed
printf '# old seed\nFDA\nPACS\n' > "$SUPPORT/vocabulary.txt"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
out_has 'terms in the repo version that your copy does not have' "terms of the repo vocabulary missing in yours are listed"
out_has '          ExampleCorp' "a missing repo term (the first one, ExampleCorp) is named in the hint"
[ "$(cat "$SUPPORT/vocabulary.txt")" = "$(printf '# old seed\nFDA\nPACS')" ]; check $? "the old vocabulary.txt is still byte-identical (not overwritten)"
# note_prompt.md: identical copy of an old install, or a user's override
cp "$ROOT/config/note_prompt.md" "$SUPPORT/note_prompt.md"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
out_has 'note_prompt.md: .*identical to the repo copy' "an old identical note_prompt.md copy is called out (drift risk)"
echo "# my rule" >> "$SUPPORT/note_prompt.md"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
out_has 'note_prompt.md: your override' "an edited note_prompt.md is reported as an override"
grep -q '^# my rule$' "$SUPPORT/note_prompt.md"; check $? "the override was not touched"
[ ! -s "$LOGS/launchctl.log" ]; check $? "no launchctl call anywhere"

# Google Meet is off by default (SPEC 15): install.sh says what an existing config.env does about it
fresh_env base; stub_loaded; mkdir -p "$SUPPORT"
printf 'ENABLED_PLATFORMS=zoom,teams,meet   # on\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'ENABLED_PLATFORMS=zoom,teams,meet includes meet: Google Meet detection is ON' "an existing config.env with meet: install.sh says Meet is ON (and that setup then asks for Chrome Automation)"
printf 'ENABLED_PLATFORMS=zoom,teams\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'ENABLED_PLATFORMS=zoom,teams \(Google Meet detection is OFF\)' "an existing config.env without meet: Meet is OFF"
printf 'SELF_NAME=Tester\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'ENABLED_PLATFORMS is not set, the default is zoom,teams' "a config.env without the key: the default (Meet off) is named"

# Calls of other apps: install.sh says what an existing config.env does about CALL_DETECT (an update must not switch recording of other apps on unannounced)
fresh_env base; stub_loaded; mkdir -p "$SUPPORT"
printf 'SELF_NAME=Tester\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CALL_DETECT is not set, the default is known: calls of the call apps of the built-in table' "a config.env without CALL_DETECT: install.sh says that the table of call apps is recorded after the update"
out_has 'personal messengers included, no guessing' "... that this includes personal messengers, and that nothing is guessed"
out_has 'CALL_DETECT=off switches it off' "... and how to switch it off"
printf 'CALL_DETECT=generic   # guess\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CALL_DETECT=generic: besides the built-in table of call apps ANY other GUI app' "CALL_DETECT=generic: install.sh says that any GUI app is guessed"
printf 'CALL_DETECT=OFF\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CALL_DETECT=off \(calls of other apps are not recorded\)' "CALL_DETECT=off (any case): install.sh says they are not recorded"

# Claude billing (SPEC 17): a config.env without a CLAUDE_AUTH line takes the code default, API (a Console key), and install never overwrites the
# file. install.sh must say which mode the installed file selects, and that subscription is an opt-in.
fresh_env base; stub_loaded; mkdir -p "$SUPPORT"
printf 'SELF_NAME=Tester\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CLAUDE_AUTH is not set, so the code default applies: API' "an existing config.env without CLAUDE_AUTH: install.sh says the default is API (not 'defaults apply' as for the other keys)"
out_has 'store it once with  make set-api-key' "... and names the key command"
out_lacks 'sk-ant-' "... and never prints anything key-shaped"
printf 'CLAUDE_AUTH=API   # Console credits\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CLAUDE_AUTH=API: Claude calls are billed to the Anthropic API key in the Keychain' "CLAUDE_AUTH=API (any case, inline comment): reported as api"
printf 'CLAUDE_AUTH=subscription\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has 'CLAUDE_AUTH=subscription: Claude calls use the claude.ai subscription login' "CLAUDE_AUTH=subscription: reported as the subscription"
out_has 'Subscription mode is opt-in.*check Anthropic' "... with the warning to check Anthropic's terms for unattended use"
printf 'CLAUDE_AUTH=apikey\n' > "$SUPPORT/config.env"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_has "WARNING: config.env: CLAUDE_AUTH=apikey is neither 'subscription' nor 'api': the pipeline makes no Claude call until it is fixed" "a typo (CLAUDE_AUTH=apikey) is a warning with the fix, never silently one of the modes"
[ ! -s "$LOGS/forbidden.log" ]; check $? "none of the CLAUDE_AUTH reports uses a forbidden security subcommand (the Keychain item is never touched)"

# ---------------------------------------------------------------------------------------------------------------
section "install.sh: --require-signing fails before anything is changed; full install with a stub identity"
# ---------------------------------------------------------------------------------------------------------------
fresh_env sign; stub_loaded
runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" /bin/bash scripts/install.sh --require-signing
rc_not 0 "--require-signing without an identity fails"
out_has 'make_signing_identity.sh' "it tells how to create the identity"
[ ! -e "$SUPPORT" ] && [ ! -e "$H/Applications" ]; check $? "nothing was created (no SUPPORT_DIR, no app) when --require-signing fails"
add_identity "$HASH_A" " (CSSMERR_TP_NOT_TRUSTED)"
runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" /bin/bash scripts/install.sh --accept-legal-notice --require-signing
rc_is 0 "--require-signing with an (untrusted) identity: full install into the fake HOME succeeds"
out_has "signing +: fixed identity 'MeetingCapture Local Signing'" "install.sh reports the fixed identity"
[ -x "$H/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT" ]; check $? "the app was installed into the fake HOME"
[ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "the LaunchAgent plist is NOT written before the live test is confirmed"
out_has 'not written: you have not confirmed the live test yet' "install.sh says why (live test not confirmed)"
[ ! -s "$LOGS/launchctl.log" ]; check $? "nothing was loaded (no --load)"
grep -q -- "--sign $HASH_A --timestamp=none --identifier $DEFAULT_ID" "$LOGS/codesign.log"; check $? "codesign was called with the identity hash, --timestamp=none and the fixed identifier"
! grep -q 'runtime' "$LOGS/codesign.log"; check $? "no hardened runtime option"
out_lacks 'Signing \(once' "the signing step is not repeated in the next steps when an identity is in use"
# after the user's confirmation (marker file; the confirm flow itself is tested below through a pty) the plist is written, still not loaded
mkdir -p "$SUPPORT"; printf 'confirmed=test\n' > "$SUPPORT/live-tested.confirmed"
runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" /bin/bash scripts/install.sh --accept-legal-notice --no-build
rc_is 0 "install.sh after the confirmation"
plutil -lint "$H/Library/LaunchAgents/$DEFAULT_ID.plist" >/dev/null 2>&1; check $? "with the confirmation the LaunchAgent plist is written and valid"
[ ! -s "$LOGS/launchctl.log" ]; check $? "... and it is NOT loaded without --load"
out_has 'The live test is confirmed' "the next steps say the live test is confirmed"
# --load with a launchctl stub that succeeds: bootstrap is requested, nothing real
runx STUB_LAUNCHCTL_RC=0 MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" /bin/bash scripts/install.sh --accept-legal-notice --load --no-build
rc_is 0 "install.sh --load (stub launchctl, confirmed)"
grep -q "launchctl bootstrap gui/$(id -u) $H/Library/LaunchAgents/$DEFAULT_ID.plist" "$LOGS/launchctl.log"; check $? "launchctl bootstrap was requested for the fake plist (stub)"

# ---------------------------------------------------------------------------------------------------------------
section "uninstall.sh (review finding: --purge ordering and counting), stub launchctl"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded; make_support_tree
runx /bin/bash scripts/uninstall.sh --purge --dry-run
rc_is 0 "uninstall --purge --dry-run"
out_has '1 unpublished session folder' "only the real unpublished session is counted (_discarded and the tombstone are not)"
out_has '2026-10-07_1400_meet' "the unpublished recording is named"
[ -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ -e "$SUPPORT/config.env" ]; check $? "dry run deleted nothing"
[ ! -s "$LOGS/launchctl.log" ]; check $? "the dry run did not call launchctl"
runx /bin/bash scripts/uninstall.sh --purge
rc_not 0 "--purge without a terminal is refused"
out_has 'Nothing was changed' "the refusal says nothing was changed"
[ -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "plist still there after the refused --purge"
[ -d "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "app still there after the refused --purge"
[ -e "$SUPPORT/config.env" ] && [ -d "$SUPPORT/sessions/2026-10-07_1400_meet" ]; check $? "data still there after the refused --purge"
[ ! -s "$LOGS/launchctl.log" ]; check $? "the agent was not even unloaded (launchctl not called) after the refused --purge"
# wrong and right answers through a pseudo terminal (pty_run.py types the answer when the prompt appears)
cat > "$WORK/pty_run.py" <<'EOF'
import os, pty, select, sys
answers, cmd = sys.argv[1].split("|"), sys.argv[2:]
PROMPTS = os.environ.get("PTY_PROMPT", "Type 'purge'").encode().split(b"|")      # several prompts: "A|B" answered with "x|y", in this order
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, nxt, start = b"", 0, 0
while True:
    ready, _, _ = select.select([fd], [], [], 20)
    if not ready:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if nxt < len(PROMPTS) and PROMPTS[nxt] in buf[start:]:
        os.write(fd, (answers[nxt] + "\n").encode())
        start = len(buf)
        nxt += 1
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
EOF
pty() {   # pty <answer> <command...>: run in the fake environment with a terminal on stdin; sets OUT and RC
    N=$((N + 1)); OUT="$WORK/out.$N.txt"
    ( cd "$ROOT" && env HOME="$H" PATH="$STUBS:$PATH" TMPDIR="$H/tmp" MCAP_SUPPORT_DIR="$SUPPORT" MCAP_LOG_DIR="$APPLOGS" \
        STUB_LOG="$LOGS" STUB_STATE="$STATE" PTY_PROMPT="${PTY_PROMPT:-Type 'purge'}" python3 "$WORK/pty_run.py" "$@" ) > "$OUT" 2>&1
    RC=$?
}
pty nope /bin/bash scripts/uninstall.sh --purge
rc_not 0 "a wrong answer at the prompt is refused"
[ -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ -d "$H/Applications/$DEFAULT_SHORT.app" ] && [ -e "$SUPPORT/config.env" ]; check $? "a wrong answer at the prompt changes nothing (plist, app, data intact)"
[ ! -s "$LOGS/launchctl.log" ]; check $? "a wrong answer does not unload the agent"
pty purge /bin/bash scripts/uninstall.sh --purge
rc_is 0 "typing 'purge' at the prompt is accepted"
[ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -d "$H/Applications/$DEFAULT_SHORT.app" ] && [ ! -e "$SUPPORT" ] && [ ! -e "$APPLOGS" ]; check $? "typing 'purge' removes plist, app, SUPPORT_DIR and LOG_DIR"
grep -q 'launchctl bootout' "$LOGS/launchctl.log"; check $? "after the confirmation the agent is unloaded (stub launchctl bootout)"
# --yes, and the plain uninstall that keeps data
fresh_env base; make_support_tree
runx /bin/bash scripts/uninstall.sh
rc_is 0 "plain uninstall"
[ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -d "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "plain uninstall removes plist and app"
[ -e "$SUPPORT/config.env" ] && [ -d "$SUPPORT/sessions/2026-10-07_1400_meet" ] && [ -e "$APPLOGS/app.log" ]; check $? "plain uninstall keeps config, sessions and logs"
fresh_env base; make_support_tree
runx /bin/bash scripts/uninstall.sh --purge --yes
rc_is 0 "--purge --yes"
[ ! -e "$SUPPORT" ] && [ ! -e "$APPLOGS" ]; check $? "--purge --yes removes SUPPORT_DIR and LOG_DIR"

# ---------------------------------------------------------------------------------------------------------------
section "live-test gate: no LaunchAgent plist and no --load before the user ran make confirm-live-tested"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
PLIST="$H/Library/LaunchAgents/$DEFAULT_ID.plist"
MARKER="$SUPPORT/live-tested.confirmed"
runx /bin/bash scripts/make_launchagent.sh
rc_not 0 "make_launchagent.sh: writing the plist without the confirmation is refused"
out_has 'live test has not been confirmed' "the refusal explains why"
out_has 'make confirm-live-tested' "and names the command that unlocks it"
out_has 'open -n -W -a .* --args setup' "and the permission step (with -n)"
out_has 'selftest-capture --live --seconds' "and the live device test (--live)"
out_has 'docs/LIVE_TEST.md sections 4 and 5' "and the solo Zoom / Teams test calls"
[ ! -e "$PLIST" ] && [ ! -s "$LOGS/launchctl.log" ]; check $? "nothing was written and launchctl was not called"
runx /bin/bash scripts/make_launchagent.sh --load
rc_not 0 "make_launchagent.sh --load without the confirmation is refused"
[ ! -e "$PLIST" ] && [ ! -s "$LOGS/launchctl.log" ]; check $? "--load wrote nothing and never called launchctl"
runx /bin/bash scripts/make_launchagent.sh --dry-run --load
rc_is 0 "--dry-run --load still shows the plan"
out_has 'a real run would STOP here' "the dry run says that a real run would stop at the gate"
out_has '<key>RunAtLoad</key>' "the dry run still prints the plist"
home_is_empty; check $? "the dry run wrote nothing"
runx /bin/bash scripts/make_launchagent.sh --unload
rc_is 0 "--unload needs no confirmation (it only stops things)"
grep -q 'launchctl bootout' "$LOGS/launchctl.log"; check $? "--unload called launchctl bootout (stub)"
runx /bin/bash scripts/make_launchagent.sh --load --unload
rc_not 0 "--load and --unload together are refused"
runx /bin/bash scripts/install.sh --load --no-build
rc_not 0 "install.sh --load without the confirmation is refused"
out_has '[-][-]load is refused' "install.sh names the refusal"
out_has 'make confirm-live-tested' "install.sh names the command that unlocks it"
home_is_empty; check $? "install.sh --load refused BEFORE anything was changed (HOME is still empty)"
runx /bin/bash scripts/install.sh --dry-run --load --no-build
rc_is 0 "install.sh --dry-run --load shows the plan"
out_has 'a real --load would STOP right here' "and says that a real --load would stop"

# the confirmation: needs the app, a setup report without [FAIL], a terminal and the typed word
mkdir -p "$H/Applications/$DEFAULT_SHORT.app/Contents/MacOS" "$APPLOGS"
APPBIN="$H/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT"
runx /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "confirm without an installed app fails"
printf '#!/bin/sh\n' > "$APPBIN"; chmod +x "$APPBIN"
runx /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "confirm without a setup report fails"
out_has 'run the permission step first' "it says to run setup first (the app writes the report)"
printf '[ OK ] config.env: x\n[FAIL] permission system_audio: denied\n' > "$APPLOGS/setup-report.txt"
runx /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "confirm with a [FAIL] in the setup report fails"
out_has 'permission system_audio: denied' "the failing line is shown"
printf '[ OK ] config.env: x\n[WARN] permission notifications: denied\n[ OK ] ARCHIVE_DIR writable: y\n' > "$APPLOGS/setup-report.txt"
runx /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "confirm without a terminal is refused (deliberate human step)"
out_has 'needs a terminal' "with that explanation"
out_has '\[WARN\] permission notifications: denied' "warnings of the setup report are shown, the user decides"
runx /bin/bash scripts/make_launchagent.sh --confirm-live-tested --dry-run
rc_is 0 "confirm --dry-run"
out_has "would ask you to type 'confirmed'" "the dry run says what a real run would do"
[ ! -e "$MARKER" ]; check $? "no marker after the failed / refused / dry-run confirmations"
PTY_PROMPT="Type yes" pty no /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "a wrong answer to the legal notice is refused"
out_has 'LEGAL NOTICE: '"$DEFAULT_NAME"' records other people' "the confirm step prints the recording legal notice"
out_has 'the notice was not accepted' "... and says that a no is not an acceptance"
[ ! -e "$MARKER" ]; check $? "no marker after a refused notice"
PTY_PROMPT="Type yes|Type 'confirmed'" pty "yes|nope" /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_not 0 "a wrong answer at the prompt is refused"
[ ! -e "$MARKER" ]; check $? "no marker after a wrong answer"
: > "$LOGS/launchctl.log"          # forget the earlier --unload (bootout) call: from here on nothing may call launchctl until --load
PTY_PROMPT="Type 'confirmed'" pty confirmed /bin/bash scripts/make_launchagent.sh --confirm-live-tested --accept-legal-notice
rc_is 0 "with --accept-legal-notice only the typed 'confirmed' is asked, and it is accepted"
out_has 'accepted with --accept-legal-notice' "the notice acceptance is reported"
rm -f "$MARKER"
PTY_PROMPT="Type yes|Type 'confirmed'" pty "yes|confirmed" /bin/bash scripts/make_launchagent.sh --confirm-live-tested
rc_is 0 "typing yes and then 'confirmed' is accepted"
out_has 'every call of the other call apps of the built-in table' "the confirmation says that the login agent records the other call apps of the table too (not only Zoom / Teams)"
out_has 'CALL_DETECT=off switches them off' "... and how to switch them off"
[ -f "$MARKER" ] && grep -q '^confirmed=' "$MARKER"; check $? "the marker file was written"
[ ! -s "$LOGS/launchctl.log" ]; check $? "confirming does not touch launchd"
runx /bin/bash scripts/make_launchagent.sh
rc_is 0 "after the confirmation the plist can be written"
plutil -lint "$PLIST" >/dev/null 2>&1; check $? "the plist is valid"
[ ! -s "$LOGS/launchctl.log" ]; check $? "writing the plist does not load it"
touch -t 203001010000 "$APPBIN"
runx /bin/bash scripts/make_launchagent.sh --dry-run
out_has 'rebuilt after you confirmed the live test' "a rebuilt app after the confirmation gives a warning (not a refusal)"
runx STUB_LAUNCHCTL_RC=0 /bin/bash scripts/make_launchagent.sh --load
rc_is 0 "--load works after the confirmation (stub launchctl)"
grep -q "launchctl bootstrap gui/$(id -u) $PLIST" "$LOGS/launchctl.log"; check $? "launchctl bootstrap was requested (stub)"
# uninstall: the dry run keeps the marker, the real run deletes it (a reinstall must be confirmed again)
runx /bin/bash scripts/uninstall.sh --dry-run
[ -f "$MARKER" ]; check $? "uninstall --dry-run keeps the confirmation marker"
out_has 'would delete .*live-tested.confirmed' "... and says it would delete it"
runx /bin/bash scripts/uninstall.sh
rc_is 0 "uninstall"
[ ! -e "$MARKER" ]; check $? "uninstall deletes the confirmation marker (the next install has to be confirmed again)"

# ---------------------------------------------------------------------------------------------------------------
section "install.sh: the recording legal notice (dry run shows it, a terminal types yes, no terminal needs --accept-legal-notice)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
rc_is 0 "install.sh --dry-run shows the notice and asks nothing"
out_has 'LEGAL NOTICE: '"$DEFAULT_NAME"' records other people' "the legal notice is printed"
out_has 'also while you are muted' "... including that the microphone is recorded while you are muted"
out_has 'a real run asks you to type yes' "the dry run says what a real run does"
home_is_empty; check $? "the dry run created nothing"
runx /bin/bash scripts/install.sh --no-build --no-launchagent
rc_not 0 "a real install without a terminal and without --accept-legal-notice is refused"
out_has 'no terminal to ask' "... with the reason"
out_has 'run again with --accept-legal-notice' "... and the option that accepts the notice explicitly"
home_is_empty; check $? "nothing was created by the refused install"
PTY_PROMPT="Type yes" pty nope /bin/bash scripts/install.sh --no-build --no-launchagent
rc_not 0 "typing something else than yes at the terminal prompt is refused"
out_has 'LEGAL NOTICE' "the notice was shown on the terminal"
home_is_empty; check $? "nothing was created after a refused notice"
PTY_PROMPT="Type yes" pty yes /bin/bash scripts/install.sh --no-build --no-launchagent
rc_is 0 "typing yes at the terminal prompt installs"
[ -f "$SUPPORT/config.env" ]; check $? "... and config.env was created"
runx /bin/bash scripts/install.sh --accept-legal-notice --no-build --no-launchagent
rc_is 0 "--accept-legal-notice installs without a terminal"
out_has 'accepted with --accept-legal-notice' "... and says so"

# ---------------------------------------------------------------------------------------------------------------
section "make_launchagent.sh (plist only; launchctl is a stub)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
mkdir -p "$SUPPORT"; printf 'confirmed=test\n' > "$SUPPORT/live-tested.confirmed"      # the gate itself is tested above
runx /bin/bash scripts/make_launchagent.sh --dry-run
rc_is 0 "make_launchagent.sh --dry-run"
[ ! -e "$H/Library/LaunchAgents" ] && [ ! -e "$APPLOGS" ]; check $? "dry run writes nothing (no LaunchAgents dir, no log dir)"
runx /bin/bash scripts/make_launchagent.sh
rc_is 0 "make_launchagent.sh writes the plist into the fake HOME"
plutil -lint "$H/Library/LaunchAgents/$DEFAULT_ID.plist" >/dev/null 2>&1; check $? "plutil -lint of the plist"
[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$H/Library/LaunchAgents/$DEFAULT_ID.plist" 2>/dev/null)" = "false" ]; check $? "KeepAlive SuccessfulExit=false (Quit does not restart, a crash does)"
[ ! -s "$LOGS/launchctl.log" ]; check $? "writing the plist does not call launchctl"
runx /bin/bash scripts/make_launchagent.sh --unload --dry-run
[ ! -s "$LOGS/launchctl.log" ]; check $? "--unload --dry-run does not call launchctl"

# ---------------------------------------------------------------------------------------------------------------
section "Makefile (review finding: numpy preflight, BUILD_DIR consistency)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
for target in help build test test-swift test-python test-scripts install uninstall doctor setup-python signing-identity confirm-live-tested clean lint bench-kit pkg policy hash-lock; do
    ( cd "$ROOT" && make -n "$target" >/dev/null 2>&1 ); check $? "make -n $target"
done
# an interpreter that runs fine but cannot import numpy (the real situation before the production venv exists): `python -c pass` works,
# `python -c 'import numpy'` fails. (/usr/bin/false would fail every call, so it could not tell the preflight from no preflight.)
printf '#!/bin/sh\ncase "$*" in *numpy*) exit 1 ;; esac\nexit 0\n' > "$WORK/py-without-numpy"; chmod +x "$WORK/py-without-numpy"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make test-python PY="$WORK/py-without-numpy" ) > "$OUT" 2>&1; RC=$?
rc_not 0 "make test-python fails fast when the interpreter has no numpy"
out_has 'numpy is not importable' "with a clear message"
out_lacks '== python unittest' "and it does not start the unit tests"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n test-swift ) > "$OUT" 2>&1
out_has 'selftest-policy' "make test-swift runs selftest-policy (the CI swift job runs make test-swift)"
out_has 'selftest-detector' "... next to selftest-detector"
grep -q 'make test-swift' "$ROOT/.github/workflows/ci.yml"; check $? "the CI swift job runs make test-swift"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n confirm-live-tested ) > "$OUT" 2>&1
out_has 'scripts/make_launchagent.sh --confirm-live-tested' "make confirm-live-tested runs make_launchagent.sh --confirm-live-tested"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make help ) > "$OUT" 2>&1
out_has 'make confirm-live-tested' "make help lists confirm-live-tested"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n clean BUILD_DIR=/tmp/mcap-bd-test ) > "$OUT" 2>&1
out_has 'MCAP_BUILD_DIR="/tmp/mcap-bd-test" scripts/build_app.sh --clean-only' "make clean honours BUILD_DIR (passes it to build_app.sh)"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n bench-kit BUILD_DIR=/tmp/mcap-bd-test ) > "$OUT" 2>&1
out_has '/tmp/mcap-bd-test/bench-kit.tar.gz' "make bench-kit honours BUILD_DIR"
# MCAP_BUNDLE_ID, MCAP_APP_NAME and MCAP_APP_SHORT_NAME are build inputs: `make build` must rebuild when one changes although no source did (the stamp rule alone is
# run here, nothing is compiled). The stamp holds the three values, one per line.
STAMP="$H/mkstamp/.bundle-id"
stamp_is() { [ "$(cat "$STAMP")" = "$(printf '%s\n%s\n%s' "$1" "${2:-}" "${3:-}")" ]; }      # $(...) drops the final newline on both sides
runx env MCAP_BUNDLE_ID="$CUSTOM_ID" make BUILD_DIR="$H/mkstamp" "$STAMP"
stamp_is "$CUSTOM_ID"; check $? "the Makefile keeps the bundle id and the two app names of the last build in a stamp file (a prerequisite of the app)"
T1="$(stat -f %m "$STAMP")"; sleep 1.1
runx env MCAP_BUNDLE_ID="$CUSTOM_ID" make BUILD_DIR="$H/mkstamp" "$STAMP"
[ "$(stat -f %m "$STAMP")" = "$T1" ]; check $? "... the same inputs leave it alone (no rebuild)"
runx env MCAP_BUNDLE_ID="$DEFAULT_ID" make BUILD_DIR="$H/mkstamp" "$STAMP"
stamp_is "$DEFAULT_ID" && [ "$(stat -f %m "$STAMP")" != "$T1" ]; check $? "... another id rewrites it (make build then rebuilds the app)"
T2="$(stat -f %m "$STAMP")"; sleep 1.1
runx env MCAP_BUNDLE_ID="$DEFAULT_ID" MCAP_APP_NAME="$CUSTOM_NAME" make BUILD_DIR="$H/mkstamp" "$STAMP"
stamp_is "$DEFAULT_ID" "$CUSTOM_NAME" && [ "$(stat -f %m "$STAMP")" != "$T2" ]; check $? "... another app name rewrites it as well"
T3="$(stat -f %m "$STAMP")"; sleep 1.1
runx env MCAP_BUNDLE_ID="$DEFAULT_ID" MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" make BUILD_DIR="$H/mkstamp" "$STAMP"
stamp_is "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT" && [ "$(stat -f %m "$STAMP")" != "$T3" ]; check $? "... and another short name"
runx env MCAP_BUNDLE_ID='a.b;x' make BUILD_DIR="$H/mkstamp" "$STAMP"
[ "$RC" = 0 ] && stamp_is 'a.b;x' && [ ! -e "$H/x" ] && [ ! -e "$ROOT/x" ]; check $? "... the value is only data: a shell metacharacter in it is not run (build_app.sh refuses the id before anything is built)"
runx env MCAP_APP_NAME='x;touch '"$H"'/x2' make BUILD_DIR="$H/mkstamp" "$STAMP"
[ "$RC" = 0 ] && [ ! -e "$H/x2" ]; check $? "... the same for the app name"
runx env MCAP_APP_SHORT_NAME='a;touch '"$H"'/x3' make BUILD_DIR="$H/mkstamp" "$STAMP"
rc_not 0 "a short name with a shell metacharacter stops make before anything runs (the file name of the app)"
out_has 'not a valid short app name' "... with the reason from scripts/bundle_id.sh"
[ ! -e "$H/x3" ]; check $? "... and the value was never run"
runx env MCAP_APP_SHORT_NAME='' make -p -n BUILD_DIR="$H/mkstamp"
rc_is 0 "an EMPTY MCAP_APP_SHORT_NAME is the same as unset"
out_has "^APP_BIN := $H/mkstamp/$DEFAULT_SHORT\\.app/Contents/MacOS/$DEFAULT_SHORT\$" "make names the app after the default short name ($DEFAULT_SHORT): <build dir>/<short name>.app/Contents/MacOS/<short name>"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" make -p -n BUILD_DIR="$H/mkstamp"
out_has "^APP_BIN := $H/mkstamp/$CUSTOM_SHORT\\.app/Contents/MacOS/$CUSTOM_SHORT\$" "... and after MCAP_APP_SHORT_NAME when it is set"
# the short name given as a make ARGUMENT would be seen by the recipes but not by make's own $(shell) in GNU Make 3.81 (the program would be named one thing and built as another): refused
runx make MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" help
rc_not 0 "make refuses MCAP_APP_SHORT_NAME as a make argument (make MCAP_APP_SHORT_NAME=... target)"
out_has 'MCAP_APP_SHORT_NAME is a build input of the environment, not a make argument' "... with the reason and the way (MCAP_APP_SHORT_NAME=<name> make ...)"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" make help
rc_is 0 "... while the environment form works"
# a checkout path with a quote in it: the shell line of the Makefile must not splice the path into a quoted string
QMK="$WORK/o'brien mcap"; mkdir -p "$QMK/scripts"; cp "$ROOT/Makefile" "$QMK/Makefile"; cp "$ROOT/scripts/bundle_id.sh" "$QMK/scripts/bundle_id.sh"
runx make -C "$QMK" help
rc_is 0 "make help works from a checkout whose path has a quote and a space in it"
out_lacks 'syntax error|\*\*\*' "... without a shell error"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" make -C "$QMK" -p -n BUILD_DIR=b
out_has "^APP_BIN := b/$CUSTOM_SHORT\\.app/Contents/MacOS/$CUSTOM_SHORT\$" "... and still names the app after the short name"
# ... and `make build` itself: the stamp must be a prerequisite of the app binary, or the stamp rule above changes nothing (a copy of the Makefile with a
# stub build_app.sh that counts the builds; the sources are dated in the past so that only an input can make the app out of date)
MK="$WORK/mk-tree"; mkdir -p "$MK/scripts" "$MK/app/Sources"
cp "$ROOT/Makefile" "$MK/Makefile"; cp "$ROOT/scripts/bundle_id.sh" "$MK/scripts/bundle_id.sh"; : > "$MK/app/Sources/main.swift"; : > "$MK/app/Info.plist.template"
cat > "$MK/scripts/build_app.sh" <<'MKEOF'
#!/bin/sh
echo "$MCAP_BUNDLE_ID|${MCAP_APP_NAME:-}|${MCAP_APP_SHORT_NAME:-}" >> "$MK_LOG"
short="${MCAP_APP_SHORT_NAME:-CATE}"
mkdir -p "$MCAP_BUILD_DIR/$short.app/Contents/MacOS"
: > "$MCAP_BUILD_DIR/$short.app/Contents/MacOS/$short"
MKEOF
chmod 755 "$MK/scripts/build_app.sh"
touch -t 202001010000 "$MK/Makefile" "$MK/scripts/bundle_id.sh" "$MK/app/Sources/main.swift" "$MK/app/Info.plist.template" "$MK/scripts/build_app.sh"
mk_build() {   # mk_build <id> [<name> [<short name>]]: `make build` in the copy; the stamp is dated before the app, the app after the sources, like after a finished build
    local short="${3:-$DEFAULT_SHORT}"
    N=$((N + 1)); OUT="$WORK/out.$N.txt"
    [ ! -e "$MK/bd/.bundle-id" ] || touch -t 202001020000 "$MK/bd/.bundle-id"
    [ ! -e "$MK/bd/$short.app/Contents/MacOS/$short" ] || touch -t 202001030000 "$MK/bd/$short.app/Contents/MacOS/$short"
    ( cd "$MK" && env HOME="$H" MK_LOG="$MK/builds.log" MCAP_BUNDLE_ID="$1" MCAP_APP_NAME="${2:-}" MCAP_APP_SHORT_NAME="${3:-}" make BUILD_DIR="$MK/bd" build ) > "$OUT" 2>&1
    RC=$?
}
mk_builds() { grep -c . "$MK/builds.log" 2>/dev/null || echo 0; }
mk_build "$CUSTOM_ID"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 1 ]; check $? "make build with no app builds it (the stub counted 1 build)"
mk_build "$CUSTOM_ID"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 1 ]; check $? "... the same id and no new source: nothing is rebuilt"
mk_build "$DEFAULT_ID"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 2 ] && [ "$(tail -n 1 "$MK/builds.log")" = "$DEFAULT_ID||" ]; check $? "... another id rebuilds although no source changed (make build after an id change is not 'Nothing to be done')"
mk_build "$DEFAULT_ID"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 2 ]; check $? "... and the new id is then stable again"
mk_build "$DEFAULT_ID" "$CUSTOM_NAME"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 3 ] && [ "$(tail -n 1 "$MK/builds.log")" = "$DEFAULT_ID|$CUSTOM_NAME|" ]; check $? "... another app name rebuilds (the human name is in Info.plist) although no source changed"
mk_build "$DEFAULT_ID" "$CUSTOM_NAME"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 3 ]; check $? "... and the new name is then stable again"
mk_build "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 4 ] && [ "$(tail -n 1 "$MK/builds.log")" = "$DEFAULT_ID|$CUSTOM_NAME|$CUSTOM_SHORT" ] && [ -e "$MK/bd/$CUSTOM_SHORT.app/Contents/MacOS/$CUSTOM_SHORT" ]; check $? "... another short name rebuilds, into <short name>.app"
mk_build "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 4 ]; check $? "... and is stable again"
# the check can fail: the same copy of the Makefile WITHOUT the stamp in the prerequisites does not notice a changed name (a name change would then be 'Nothing to be done')
MK_ORIG="$MK"; MK="$WORK/mk-tree-mutated"; mkdir -p "$MK/scripts" "$MK/app/Sources"
sed 's/ \$(BUNDLE_ID_STAMP)$//' "$MK_ORIG/Makefile" > "$MK/Makefile"
cp "$MK_ORIG/scripts/bundle_id.sh" "$MK_ORIG/scripts/build_app.sh" "$MK/scripts/"; : > "$MK/app/Sources/main.swift"; : > "$MK/app/Info.plist.template"
! cmp -s "$MK_ORIG/Makefile" "$MK/Makefile"; check $? "(premise) the mutated Makefile really lacks the stamp prerequisite"
touch -t 202001010000 "$MK/Makefile" "$MK/scripts/bundle_id.sh" "$MK/app/Sources/main.swift" "$MK/app/Info.plist.template" "$MK/scripts/build_app.sh"
mk_build "$DEFAULT_ID" "$DEFAULT_NAME"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 1 ]; check $? "(mutation) without the stamp: the first build happens"
mk_build "$DEFAULT_ID" "$CUSTOM_NAME"
[ "$RC" = 0 ] && [ "$(mk_builds)" = 1 ]; check $? "(mutation) without the stamp a changed app name is NOT rebuilt: the name test above fails when the stamp rule is removed"
MK="$MK_ORIG"
out_lacks '[^/]build/bench-kit' "make bench-kit does not hard-code build/"

# ---------------------------------------------------------------------------------------------------------------
section "bench kit (review finding: must refuse to run from the full repository)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base; stub_loaded
for leftover in support hf bench.env BENCH_KIT; do [ ! -e "$ROOT/$leftover" ] || echo "  note: $ROOT/$leftover exists before the test"; done
runx /bin/bash scripts/bench_kit/setup_bench_env.sh --dry-run
rc_not 0 "setup_bench_env.sh refuses to run from the repository"
out_has 'full meeting-capture repository' "with an explanation"
runx /bin/bash scripts/bench_kit/setup_bench_env.sh
rc_not 0 "also without --dry-run"
[ ! -e "$ROOT/support" ] && [ ! -e "$ROOT/hf" ] && [ ! -e "$ROOT/bench.env" ]; check $? "nothing (support/, hf/, bench.env) was created in the repository"
[ ! -e "$ROOT/BENCH_KIT" ]; check $? "the repository has no BENCH_KIT marker"
grep -qE '^/support/$' "$ROOT/.gitignore" && grep -qE '^/hf/$' "$ROOT/.gitignore" && grep -qE '^/bench\.env$' "$ROOT/.gitignore"; check $? ".gitignore lists support/, hf/ and bench.env"
KB="$WORK/kitbuild"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make bench-kit BUILD_DIR="$KB" ) > "$OUT" 2>&1; RC=$?
rc_is 0 "make bench-kit BUILD_DIR=<temp> builds the kit"
[ -f "$KB/bench-kit.tar.gz" ] && [ ! -e "$KB/bench-kit-stage" ]; check $? "tarball exists in BUILD_DIR, staging directory removed"
tar -tzf "$KB/bench-kit.tar.gz" > "$WORK/kit.list"
grep -q '^\./BENCH_KIT$' "$WORK/kit.list"; check $? "the tarball contains the BENCH_KIT marker"
grep -q 'pipeline/mcap/asr.py' "$WORK/kit.list" && grep -q 'scripts/bench_kit/setup_bench_env.sh' "$WORK/kit.list"; check $? "the tarball contains the pipeline and the kit scripts"
! grep -qE '__pycache__|\.pyc|^\./app/|SPEC.md' "$WORK/kit.list"; check $? "no bytecode, no app/, no SPEC.md in the tarball"
mkdir -p "$WORK/kit" && tar -xzf "$KB/bench-kit.tar.gz" -C "$WORK/kit"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$WORK/kit" && env HOME="$H" PATH="$STUBS:$PATH" TMPDIR="$H/tmp" /bin/bash scripts/bench_kit/setup_bench_env.sh --dry-run --with-qwen --with-silero --download whisper-large-v3,qwen3-asr-1.7b ) > "$OUT" 2>&1; RC=$?
rc_is 0 "the unpacked kit accepts --dry-run"
out_has 'bench venv: create .*/support/bench-venv' "the kit plans the SEPARATE bench venv (support/bench-venv)"
out_lacks 'create the production venv|production venv exists' "the kit plans no production venv"
out_has '4,080,710,353 bytes' "download sizes are printed before any download (Qwen3-ASR)"
out_has 'mlx-qwen3-asr 0.4.4, pinned' "mlx-qwen3-asr is pinned"
[ ! -e "$WORK/kit/support" ] && [ ! -e "$WORK/kit/hf" ] && [ ! -e "$WORK/kit/bench.env" ]; check $? "the dry run wrote nothing into the kit"
home_is_empty; check $? "the dry run wrote nothing into HOME"
rm -f "$WORK/kit/BENCH_KIT"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$WORK/kit" && env HOME="$H" PATH="$STUBS:$PATH" /bin/bash scripts/bench_kit/setup_bench_env.sh --dry-run ) > "$OUT" 2>&1; RC=$?
rc_not 0 "a kit without its marker file is refused"

# ---------------------------------------------------------------------------------------------------------------
section "setup_python.sh dry runs: Qwen only in the separate bench venv"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
runx /bin/bash scripts/setup_python.sh --dry-run --with-silero --pre-download-model
rc_is 0 "setup_python.sh --dry-run --with-silero --pre-download-model"
out_has '3,083,522,487 bytes = 3.08 GB' "the exact model size is printed in the plan, before any download"
out_lacks 'qwen' "the production plan mentions no Qwen package"
out_lacks 'bench-venv' "the production plan has no bench venv"
home_is_empty; check $? "dry run created nothing"
runx /bin/bash scripts/setup_python.sh --dry-run --with-qwen-bench --with-silero
rc_is 0 "setup_python.sh --dry-run --with-qwen-bench --with-silero"
grep 'requirements-qwen-bench.txt' "$OUT" | grep -v 'bench-venv/bin/python' | grep -q 'pip install'
check $((1 - $?)) "the qwen requirement file is pip-installed ONLY by the bench-venv python"
grep 'pip install' "$OUT" | grep -v 'bench-venv' | grep -q 'qwen'
check $((1 - $?)) "no pip install line of the production venv mentions qwen"
runx /bin/bash scripts/setup_python.sh --dry-run --bench-only --with-qwen-bench
out_lacks 'create the production venv|production venv exists' "--bench-only plans no production venv"
home_is_empty; check $? "dry runs created nothing"

# ---------------------------------------------------------------------------------------------------------------
section "build_app.sh signing selection (stub security + stub codesign, tiny Swift program)"
# ---------------------------------------------------------------------------------------------------------------
build() {   # build [extra env/flags...]: stub-signed build of the tiny program
    runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" "$@"
}
fresh_env sign; stub_loaded
build /bin/bash scripts/build_app.sh
rc_is 0 "build without any identity succeeds (ad-hoc)"
out_has 'signed ad-hoc' "falls back to ad-hoc and says so"
grep -q -- "--sign - --identifier $DEFAULT_ID " "$LOGS/codesign.log"; check $? "ad-hoc: codesign --sign - --identifier $DEFAULT_ID (the default id, MCAP_BUNDLE_ID unset)"
! grep -q -- '--timestamp' "$LOGS/codesign.log"; check $? "ad-hoc command line is unchanged from before (no extra options)"
out_has 'designated requirement: cdhash' "the designated requirement is printed"
out_has 'make_signing_identity.sh' "the ad-hoc message tells how to get a fixed identity"
[ ! -s "$LOGS/forbidden.log" ]; check $? "build_app.sh only used read-only security subcommands"
! grep -qvE '^security (find-identity -p codesigning|login-keychain)$' "$LOGS/security.log"; check $? "the only security call is: security find-identity -p codesigning (no -v)"

fresh_env sign
add_identity "$HASH_A" " (CSSMERR_TP_NOT_TRUSTED)"
build /bin/bash scripts/build_app.sh
rc_is 0 "build with an untrusted 'MeetingCapture Local Signing' identity succeeds"
out_has "signed with identity 'MeetingCapture Local Signing' \(SHA-1 $HASH_A\)" "auto-detected the identity by name (untrusted ones included)"
grep -q -- "--force --sign $HASH_A --timestamp=none --identifier $DEFAULT_ID " "$LOGS/codesign.log"; check $? "codesign --sign <SHA-1> --timestamp=none --identifier $DEFAULT_ID"
out_has 'designated requirement: identifier "'"$DEFAULT_ID"'" and certificate leaf = H"1111' "prints the designated requirement (certificate leaf)"
out_has 'CDHash|cdhash 0123456789abcdef' "prints the cdhash"
out_has 'Always Allow' "warns about the keychain dialog"
[ ! -s "$LOGS/forbidden.log" ]; check $? "only read-only security subcommands"

fresh_env sign
add_identity "$HASH_A" ""
echo "$OTHER_NAME_HASH|Some Other Identity|" >> "$STATE/identities"
build /bin/bash scripts/build_app.sh --require-identity
rc_is 0 "--require-identity with exactly one named identity (plus other identities) works"
fresh_env sign
add_identity "$HASH_A"; add_identity "$HASH_B"
runx /bin/bash scripts/build_app.sh --print-signing
rc_not 0 "two identities with the same name are ambiguous (refused)"
out_has 'MC_CODESIGN_IDENTITY' "the message says to pass MC_CODESIGN_IDENTITY=<SHA-1>"
runx MC_CODESIGN_IDENTITY="$HASH_B" /bin/bash scripts/build_app.sh --print-signing
rc_is 0 "MC_CODESIGN_IDENTITY=<SHA-1> disambiguates"
out_has "^identity $HASH_B MeetingCapture Local Signing" "--print-signing prints 'identity <SHA-1> <name>'"
runx MC_CODESIGN_IDENTITY="$(echo "$HASH_B" | tr 'A-F' 'a-f')" /bin/bash scripts/build_app.sh --print-signing
rc_is 0 "the SHA-1 may be given in lower case"

fresh_env sign
echo "$OTHER_NAME_HASH|Some Other Identity|" >> "$STATE/identities"
runx MC_CODESIGN_IDENTITY="Some Other Identity" /bin/bash scripts/build_app.sh --print-signing
out_has "^identity $OTHER_NAME_HASH Some Other Identity" "MC_CODESIGN_IDENTITY=<name> resolves to that identity's SHA-1"
runx MC_CODESIGN_IDENTITY="No Such Identity" /bin/bash scripts/build_app.sh --print-signing
rc_not 0 "MC_CODESIGN_IDENTITY naming an unknown identity fails (no silent ad-hoc)"
runx MC_CODESIGN_IDENTITY="4444444444444444444444444444444444444444" /bin/bash scripts/build_app.sh --print-signing
rc_not 0 "MC_CODESIGN_IDENTITY with an unknown SHA-1 fails"
runx MC_CODESIGN_IDENTITY="-" /bin/bash scripts/build_app.sh --print-signing
out_has '^adhoc$' "MC_CODESIGN_IDENTITY=- forces ad-hoc"
build MC_CODESIGN_IDENTITY="No Such Identity" /bin/bash scripts/build_app.sh
rc_not 0 "a build with an unknown MC_CODESIGN_IDENTITY fails ..."
[ ! -e "$H/build/$DEFAULT_SHORT.app" ] && [ ! -e "$H/build/obj" ]; check $? "... before compiling anything"

fresh_env sign
build /bin/bash scripts/build_app.sh --require-identity
rc_not 0 "--require-identity without an identity fails"
out_has 'make_signing_identity.sh' "with the instruction to create one"
[ ! -e "$H/build/$DEFAULT_SHORT.app" ] && [ ! -e "$H/build/obj" ]; check $? "it fails before compiling (no obj, no app)"
add_identity "$HASH_A"
build MC_CODESIGN_IDENTITY="-" /bin/bash scripts/build_app.sh --require-identity
rc_not 0 "--require-identity contradicts MC_CODESIGN_IDENTITY=-"

# the designated requirement across installs: unchanged vs changed
fresh_env sign
add_identity "$HASH_A" " (CSSMERR_TP_NOT_TRUSTED)"
build /bin/bash scripts/build_app.sh --install
rc_is 0 "build --install (identity)"
out_has 'first install of this app' "first install: says macOS will ask for the permissions"
[ -d "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "installed into the fake HOME/Applications"
build /bin/bash scripts/build_app.sh --install
out_has 'designated requirement unchanged' "rebuild with the same identity: the designated requirement is unchanged (permissions keep working)"
build MC_CODESIGN_IDENTITY="-" /bin/bash scripts/build_app.sh --install
out_has 'designated requirement CHANGED' "switching from the identity to ad-hoc is flagged: macOS will ask again"

# stale-signature guard of the Makefile target is documented; the clean-only path of build_app.sh honours MCAP_BUILD_DIR
runx MCAP_BUILD_DIR="$H/build" /bin/bash scripts/build_app.sh --clean-only
[ ! -e "$H/build/$DEFAULT_SHORT.app" ]; check $? "--clean-only removes the app from MCAP_BUILD_DIR"

# build attribution: MCAP_BUILT_BY names the builder; the public tree names nobody (docs/BRANDING.md)
plist_val() {   # plist_val KEY: the string value in the built Info.plist, "<absent>" when the key is missing
    python3 -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb")); v = d.get(sys.argv[2])
sys.stdout.write("<absent>" if v is None else v)' "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" "$1"
}
plist_len() {   # plist_len KEY: "<characters> <ends in an ellipsis>"
    python3 -c 'import plistlib, sys
v = plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]]
print(len(v), v.endswith("…"))' "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" "$1"
}
COPYRIGHT_BASE="Copyright 2026 Meeting Capture contributors"
fresh_env sign; stub_loaded
build /bin/bash scripts/build_app.sh
rc_is 0 "MCAP_BUILT_BY unset: the build succeeds"
[ "$(plist_val MCBuiltBy)" = "<absent>" ]; check $? "... Info.plist has no MCBuiltBy"
[ "$(plist_val NSHumanReadableCopyright)" = "$COPYRIGHT_BASE" ]; check $? "... and the neutral copyright line, no builder"
! grep -Eq 'Built by|MCBuiltBy' "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist"; check $? "... nothing about a builder anywhere in Info.plist (comments included)"
out_lacks 'built by:' "... and the log does not mention one"
cp "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" "$WORK/plist.default"
build MCAP_BUILT_BY="" /bin/bash scripts/build_app.sh
cmp -s "$WORK/plist.default" "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist"; check $? "MCAP_BUILT_BY empty is the same plist as unset"
build MCAP_BUILT_BY=$' \n\t  ' /bin/bash scripts/build_app.sh
cmp -s "$WORK/plist.default" "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist"; check $? "a value of only whitespace and newlines is empty too"

build MCAP_BUILT_BY="Example Team, example.org" /bin/bash scripts/build_app.sh
rc_is 0 "MCAP_BUILT_BY set: the build succeeds"
out_has 'built by: Example Team, example.org' "... and says who it is built by"
[ "$(plist_val MCBuiltBy)" = "Example Team, example.org" ]; check $? "... MCBuiltBy is the value"
[ "$(plist_val NSHumanReadableCopyright)" = "$COPYRIGHT_BASE. Built by Example Team, example.org" ]; check $? "... NSHumanReadableCopyright is the copyright line plus 'Built by <value>'"
plutil -lint "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" >/dev/null 2>&1; check $? "... Info.plist is still a valid plist"
[ "$(plist_val CFBundleShortVersionString)" != "<absent>" ] && [ "$(plist_val CFBundleIdentifier)" = "$DEFAULT_ID" ]; check $? "... and the rest of it is untouched (version, bundle identifier)"
cp "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" "$WORK/plist.set1"
build MCAP_BUILT_BY="Example Team, example.org" /bin/bash scripts/build_app.sh
cmp -s "$WORK/plist.set1" "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist"; check $? "the same value gives the same Info.plist bytes (no timestamp in the build)"

build MCAP_BUILT_BY=$'  Example\n\tTeam,   example.org  \n' /bin/bash scripts/build_app.sh
[ "$(plist_val MCBuiltBy)" = "Example Team, example.org" ]; check $? "newlines, tabs, runs of spaces and trailing spaces become one clean line"
build MCAP_BUILT_BY='Example & Co <dev> "x"' /bin/bash scripts/build_app.sh
[ "$(plist_val MCBuiltBy)" = 'Example & Co <dev> "x"' ]; check $? "& < > and quotes survive (the plist is escaped, not hand-edited with sed)"
build MCAP_BUILT_BY='-Example @A@' /bin/bash scripts/build_app.sh
rc_is 0 "a value that starts with a dash and looks like a placeholder is plain text"
[ "$(plist_val MCBuiltBy)" = '-Example @A@' ]; check $? "... and is stored as given"
build MCAP_BUILT_BY="$(printf '%0200d' 0 | tr 0 a)" /bin/bash scripts/build_app.sh
[ "$(plist_len MCBuiltBy)" = "80 True" ]; check $? "a 200 character value is cut to 80 characters ending in an ellipsis"
KO_CHAR=$'\xea\xb0\x80'      # one Korean syllable, three bytes in UTF-8
build MCAP_BUILT_BY="$(printf '%0100d' 0 | sed "s/0/$KO_CHAR/g")" /bin/bash scripts/build_app.sh
[ "$(plist_len MCBuiltBy)" = "80 True" ]; check $? "a 100 character Korean value is cut by characters, not bytes (still valid UTF-8)"
build MCAP_BUILT_BY="$(printf '%080d' 0 | tr 0 b)" /bin/bash scripts/build_app.sh
[ "$(plist_len MCBuiltBy)" = "80 False" ]; check $? "exactly 80 characters is kept whole"
fresh_env sign; stub_loaded
build MCAP_BUILT_BY=$'\xff\xfe' /bin/bash scripts/build_app.sh
rc_not 0 "a value that is not valid UTF-8 is refused ..."
out_has 'not valid UTF-8' "... with the reason"
[ ! -e "$H/build/$DEFAULT_SHORT.app" ] && [ ! -e "$H/build/obj" ]; check $? "... before compiling anything"
[ ! -s "$LOGS/forbidden.log" ]; check $? "the attribution tests used only read-only security subcommands"

# ---------------------------------------------------------------------------------------------------------------
section "bundle identifier: ONE build input (MCAP_BUNDLE_ID), a neutral default, refused before anything is built (scripts/bundle_id.sh)"
# ---------------------------------------------------------------------------------------------------------------
valid_id() { /bin/bash -c '. "$1/scripts/bundle_id.sh"; mcap_valid_bundle_id "$2"' _ "$ROOT" "$1"; }
LONG_OK="$(printf '%0152d' 0 | tr 0 a).bc"        # 155 characters: the longest id that is accepted
LONG_BAD="$(printf '%0153d' 0 | tr 0 a).bc"       # 156
[ "${#LONG_OK}" = 155 ] && [ "${#LONG_BAD}" = 156 ]; check $? "(premise) the two long identifiers are 155 and 156 characters"
good_ids=("$DEFAULT_ID" "$CUSTOM_ID" "a.b" "A-b.C1" "io.github.some-user.mcap" "a.1" "$LONG_OK")
bad_ids=("" "a" ".a.b" "a.b." "a..b" "-a.b" "a-.b" "a.-b" "a.b-" "a b.c" " a.b" "a.b " "a.b;x" 'a.b$(x)' 'a.b`x`' "a.b/c" "a.b&c" "a.b<c>d" 'a.b"c' "a.b'c" 'a.b\c' "a.b|c" "a.b*"
         $'a.b\nc' $'a.b\n' $'a.b\tc' "a.é" "a.b_c" "a.b%s" "$LONG_BAD")
refused=0; for id in "${good_ids[@]}"; do valid_id "$id" || { refused=1; echo "      a good id was refused: $id"; }; done
check $refused "the validator accepts reverse-DNS ids: the default, a custom one, letters in both cases, digits, hyphens inside a label, 155 characters"
accepted=0; for id in "${bad_ids[@]}"; do if valid_id "$id"; then accepted=1; echo "      a bad id was accepted: $(printf '%q' "$id")"; fi; done
check $accepted "the validator refuses ${#bad_ids[@]} bad ids: empty, one label, empty or hyphen-edged labels, spaces, shell and XML metacharacters, newlines, non-ASCII, 156 characters"
[ "$(/bin/bash -c '. "$1/scripts/bundle_id.sh"; echo "$MCAP_DEFAULT_BUNDLE_ID"' _ "$ROOT")" = "$DEFAULT_ID" ]; check $? "the default of the library is $DEFAULT_ID"
grep -q "static let defaultBundleID = \"$DEFAULT_ID\"" "$ROOT/app/Sources/App.swift"; check $? "the Swift fallback for a bare binary (AppInfo.defaultBundleID) is the same default"
grep -q '<string>@BUNDLE_ID@</string>' "$ROOT/app/Info.plist.template" && ! grep -q "$DEFAULT_ID" "$ROOT/app/Info.plist.template"; check $? "Info.plist.template takes the id from the build (@BUNDLE_ID@), it names none itself"
[ "$(grep -l "$DEFAULT_ID" "$ROOT"/app/Sources/*.swift | xargs -n 1 basename | sort | tr '\n' ' ')" = "App.swift DetectorSelfTest.swift " ]; check $? "(Swift) only App.swift (the fallback constant) and its self test spell the default id: queues, prefixes and the launch guard derive from AppInfo.bundleID"
grep -q 'static let bundleID = resolveBundleID(Bundle.main.bundleIdentifier)' "$ROOT/app/Sources/App.swift"; check $? "(Swift) AppInfo.bundleID is read from the running bundle's Info.plist (resolveBundleID(Bundle.main.bundleIdentifier)), not the constant: the custom id reaches the run time"
! grep -hE 'hasPrefix\(.*ownBundlePrefix|ownBundlePrefix \+ "\*"' "$ROOT"/app/Sources/*.swift | grep -vF 'hasPrefix(ownBundlePrefix + ".")' | grep -q .; check $? "(Swift) our own id is matched at a dot (FamilyMatcher.isOwn), never as a bare prefix: a short id must not hide another app (com.goo and com.google.Chrome)"

# refused BEFORE anything is built: no compile, no app, no codesign call, and the value is never run by a shell
refuse_id() {   # refuse_id <id> <name>
    fresh_env sign; stub_loaded
    build MCAP_BUNDLE_ID="$1" /bin/bash scripts/build_app.sh
    if [ "$RC" != 0 ] && grep -q 'not a valid bundle identifier' "$OUT" && grep -q 'Nothing was built' "$OUT" && [ ! -e "$H/build/obj" ] && [ ! -e "$H/build/$DEFAULT_SHORT.app" ] && [ ! -s "$LOGS/codesign.log" ]; then
        ok "$2"
    else
        bad "$2   (exit code $RC)"; show_tail
    fi
}
refuse_id "a" "build_app.sh refuses MCAP_BUNDLE_ID with one label, before compiling and signing anything"
refuse_id "a.b;x" "... a semicolon"
refuse_id 'a.b$(x)' "... a command substitution"
refuse_id "a b.c" "... a space"
refuse_id 'a.b<c>&d' "... XML metacharacters"
refuse_id "-a.b" "... a label that starts with a hyphen"
refuse_id "a.b-" "... a label that ends with a hyphen"
refuse_id ".a.b" "... a leading dot"
refuse_id "$LONG_BAD" "... 156 characters"
refuse_id $'a.b\nc.d' "... a newline"
fresh_env sign; stub_loaded
build MCAP_BUNDLE_ID='a.b$(touch '"$WORK"'/pwned)' /bin/bash scripts/build_app.sh
[ ! -e "$WORK/pwned" ] && [ "$RC" != 0 ]; check $? "a command substitution in MCAP_BUNDLE_ID is refused and never executed"
fresh_env sign; stub_loaded
build MCAP_BUNDLE_ID="" /bin/bash scripts/build_app.sh
rc_is 0 "an EMPTY MCAP_BUNDLE_ID is the same as unset: the default id"
[ "$(plist_val CFBundleIdentifier)" = "$DEFAULT_ID" ]; check $? "... in Info.plist"

# the id reaches Info.plist, the codesign --identifier and the designated requirement (stub codesign with a fixed identity: its requirement names the identifier)
for id in "$DEFAULT_ID" "$CUSTOM_ID"; do
    fresh_env sign; stub_loaded
    add_identity "$HASH_A" " (CSSMERR_TP_NOT_TRUSTED)"
    if [ "$id" = "$DEFAULT_ID" ]; then build /bin/bash scripts/build_app.sh; else build MCAP_BUNDLE_ID="$id" /bin/bash scripts/build_app.sh; fi
    rc_is 0 "build (fixed identity, stub codesign) with the id $id"
    [ "$(plist_val CFBundleIdentifier)" = "$id" ]; check $? "... CFBundleIdentifier is $id"
    grep -q -- "--force --sign $HASH_A --timestamp=none --identifier $id " "$LOGS/codesign.log"; check $? "... codesign --identifier $id"
    out_has "designated requirement: identifier \"$id\" and certificate leaf = H\"1111" "... the designated requirement names $id and the certificate"
    out_has "identifier $id, cdhash" "... the log says which identifier it signed with"
    [ "$id" = "$DEFAULT_ID" ] || { ! grep -q "$DEFAULT_ID" "$H/build/$DEFAULT_SHORT.app/Contents/Info.plist" "$LOGS/codesign.log"; check $? "... and nothing of the default id is left over"; }
done
fresh_env sign; stub_loaded
build MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/build_app.sh
grep -q -- "--sign - --identifier $CUSTOM_ID " "$LOGS/codesign.log" && out_has 'designated requirement: cdhash' "ad-hoc (stub): codesign --sign - --identifier $CUSTOM_ID"
[ ! -s "$LOGS/forbidden.log" ]; check $? "the bundle id builds used only read-only security subcommands"

# a REAL ad-hoc build (real swiftc and real codesign, no identity, no keychain): the signature carries the id both times
for id in "$DEFAULT_ID" "$CUSTOM_ID"; do
    fresh_env base; stub_loaded
    if [ "$id" = "$DEFAULT_ID" ]; then build MC_CODESIGN_IDENTITY=- /bin/bash scripts/build_app.sh; else build MC_CODESIGN_IDENTITY=- MCAP_BUNDLE_ID="$id" /bin/bash scripts/build_app.sh; fi
    rc_is 0 "real ad-hoc build with the id $id"
    APPB="$H/build/$DEFAULT_SHORT.app"
    [ "$(plist_val CFBundleIdentifier)" = "$id" ]; check $? "... Info.plist CFBundleIdentifier is $id"
    SIGINFO_REAL="$(codesign -dvvv "$APPB" 2>&1)"      # captured first: grep -q closing the pipe would fail the pipeline under pipefail
    grep -q "^Identifier=$id\$" <<< "$SIGINFO_REAL"; check $? "... codesign -dvvv: Identifier=$id"
    codesign --verify --strict -R="identifier \"$id\"" "$APPB" 2>/dev/null; check $? "... the signature satisfies the requirement  identifier \"$id\""
    codesign --verify --strict -R="identifier \"nope.$id\"" "$APPB" 2>/dev/null; [ $? -ne 0 ]; check $? "... and not the requirement of another identifier (the check can fail)"
done

# the other scripts that name the app: the id is derived (the app's Info.plist, else MCAP_BUNDLE_ID, else the default), never retyped
fake_app_with_id() {   # fake_app_with_id <.app folder> <id>: a bundle with nothing but the identifier
    mkdir -p "$1/Contents/MacOS"
    cat > "$1/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string></dict></plist>
PLISTEOF
    printf '#!/bin/sh\n' > "$1/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$1/Contents/MacOS/$DEFAULT_SHORT"
}
la_label() { plutil -extract Label raw -o - "$1" 2>/dev/null; }

# --install and the id of the app that is installed: another id is another app to macOS (the permissions are asked again, the login agent of the old id keeps
# starting the app), so it is refused before anything is built or replaced; MCAP_ALLOW_ID_CHANGE=1 switches on purpose and says how to remove the old agent
fresh_env sign; stub_loaded
build MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/build_app.sh --install
rc_is 0 "(premise) an app with the id $CUSTOM_ID is installed"
INSTALLED_PLIST="$H/Applications/$DEFAULT_SHORT.app/Contents/Info.plist"
SUM_BEFORE="$(cksum < "$INSTALLED_PLIST")"
build MCAP_BUILD_DIR="$H/build-other" /bin/bash scripts/build_app.sh --install
rc_not 0 "--install of a build without the id that is installed (MCAP_BUNDLE_ID forgotten in a new terminal) is refused"
out_has "has the bundle id $CUSTOM_ID, this build has $DEFAULT_ID" "... naming both ids"
out_has "MCAP_BUNDLE_ID=$CUSTOM_ID to keep the id, or set MCAP_ALLOW_ID_CHANGE=1" "... and the two ways out"
[ ! -e "$H/build-other/obj" ] && [ ! -e "$H/build-other/$DEFAULT_SHORT.app" ] && [ "$(cksum < "$INSTALLED_PLIST")" = "$SUM_BEFORE" ]; check $? "... before anything was compiled, and the installed app is untouched"
build MCAP_BUILD_DIR="$H/build-other" /bin/bash scripts/build_app.sh
rc_is 0 "a build of another id without --install is not affected"
[ "$(cksum < "$INSTALLED_PLIST")" = "$SUM_BEFORE" ]; check $? "... and leaves the installed app alone"
build MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/build_app.sh --install
rc_is 0 "--install with the id that is installed"
out_lacks 'bundle id changed' "... says nothing about a change"
build MCAP_ALLOW_ID_CHANGE=1 /bin/bash scripts/build_app.sh --install
rc_is 0 "MCAP_ALLOW_ID_CHANGE=1 lets the id change on purpose"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$INSTALLED_PLIST")" = "$DEFAULT_ID" ]; check $? "... the installed app has the new id"
out_has "bundle id changed \\($CUSTOM_ID -> $DEFAULT_ID\\)" "... and the build says the id changed"
out_has "launchctl bootout gui/$(id -u)/$CUSTOM_ID" "... how to stop the login agent of the old id"
out_has "$H/Library/LaunchAgents/$CUSTOM_ID\\.plist" "... and which plist to delete"
fresh_env sign; stub_loaded
fake_app_with_id "$H/Applications/$DEFAULT_SHORT.app" 'a.b;x'
build /bin/bash scripts/build_app.sh --install
rc_is 0 "an installed app whose CFBundleIdentifier is not a valid id has nothing to compare with: it is replaced"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$H/Applications/$DEFAULT_SHORT.app/Contents/Info.plist")" = "$DEFAULT_ID" ]; check $? "... by the new app"
fresh_env base; stub_loaded
mkdir -p "$SUPPORT"; printf 'confirmed=test\n' > "$SUPPORT/live-tested.confirmed"
runx /bin/bash scripts/make_launchagent.sh
rc_is 0 "make_launchagent.sh without an app and without MCAP_BUNDLE_ID"
[ "$(la_label "$H/Library/LaunchAgents/$DEFAULT_ID.plist")" = "$DEFAULT_ID" ]; check $? "the LaunchAgent plist is named after the default id and its Label equals it"
rm -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/make_launchagent.sh
[ "$(la_label "$H/Library/LaunchAgents/$CUSTOM_ID.plist")" = "$CUSTOM_ID" ] && [ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "with MCAP_BUNDLE_ID the plist file name and its Label are that id"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/make_launchagent.sh --unload
grep -q "^launchctl bootout gui/$(id -u)/$CUSTOM_ID\$" "$LOGS/launchctl.log"; check $? "--unload boots out gui/<uid>/<that id>"
rm -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist"
fake_app_with_id "$H/Applications/$DEFAULT_SHORT.app" "$CUSTOM_ID"
runx MCAP_BUNDLE_ID="com.example.other-env" /bin/bash scripts/make_launchagent.sh
[ "$(la_label "$H/Library/LaunchAgents/$CUSTOM_ID.plist")" = "$CUSTOM_ID" ] && [ ! -e "$H/Library/LaunchAgents/com.example.other-env.plist" ]; check $? "the installed app's own CFBundleIdentifier wins over MCAP_BUNDLE_ID"
rm -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist"
runx /bin/bash scripts/make_launchagent.sh --out "$H/elsewhere.plist"
[ "$(la_label "$H/elsewhere.plist")" = "$CUSTOM_ID" ]; check $? "--out names the file, the Label still comes from the app"
fake_app_with_id "$H/Applications/$DEFAULT_SHORT.app" "../../evil"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/make_launchagent.sh
out_has 'WARNING: the CFBundleIdentifier of .* is not a valid identifier' "an app whose Info.plist holds no valid identifier is warned about ..."
[ "$(la_label "$H/Library/LaunchAgents/$CUSTOM_ID.plist")" = "$CUSTOM_ID" ] && [ ! -e "$H/Library/evil.plist" ]; check $? "... and skipped: MCAP_BUNDLE_ID decides, nothing is written outside LaunchAgents"
rm -rf "$H/Applications/$DEFAULT_SHORT.app"
runx MCAP_BUNDLE_ID='a.b;x' /bin/bash scripts/make_launchagent.sh
rc_not 0 "make_launchagent.sh refuses an invalid MCAP_BUNDLE_ID"
out_has 'not a valid bundle identifier' "... with the reason"

# uninstall.sh removes the agent of the id the installed app has
fresh_env base; stub_loaded
mkdir -p "$H/Library/LaunchAgents"; fake_app_with_id "$H/Applications/$DEFAULT_SHORT.app" "$CUSTOM_ID"
echo plist > "$H/Library/LaunchAgents/$CUSTOM_ID.plist"; echo plist > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx /bin/bash scripts/uninstall.sh
rc_is 0 "uninstall.sh of an app that has a custom id"
[ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -d "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "... it removed the agent named after the app's id, not the default one (which is not ours here)"
grep -q "^launchctl bootout gui/$(id -u)/$CUSTOM_ID\$" "$LOGS/launchctl.log"; check $? "... and booted out gui/<uid>/<that id>"
out_has "tccutil reset All $CUSTOM_ID" "... and the permission hint names that id"
fresh_env base; stub_loaded
mkdir -p "$H/Library/LaunchAgents"; echo plist > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx /bin/bash scripts/uninstall.sh
[ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "uninstall.sh without an app falls back to the default id"
fresh_env base; stub_loaded
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/uninstall.sh
out_has "tccutil reset All $CUSTOM_ID" "uninstall.sh without an app uses MCAP_BUNDLE_ID (the id you built it with)"
runx MCAP_BUNDLE_ID='a.b;x' /bin/bash scripts/uninstall.sh
rc_not 0 "uninstall.sh refuses an invalid MCAP_BUNDLE_ID (the id becomes a file name it deletes)"
out_has 'Nothing was changed' "... before changing anything"

# ---------------------------------------------------------------------------------------------------------------
section "app names: TWO build inputs (MCAP_APP_NAME, MCAP_APP_SHORT_NAME), defaults 'Catch Everything' and CATE, refused before anything is built (scripts/bundle_id.sh)"
# ---------------------------------------------------------------------------------------------------------------
valid_name()  { /bin/bash -c '. "$1/scripts/bundle_id.sh"; mcap_valid_app_name "$2"' _ "$ROOT" "$1"; }
valid_short() { /bin/bash -c '. "$1/scripts/bundle_id.sh"; mcap_valid_app_short_name "$2"' _ "$ROOT" "$1"; }
NAME40="$(printf '%040d' 0 | tr 0 a)"; NAME41="${NAME40}a"; SHORT32="$(printf '%032d' 0 | tr 0 a)"; SHORT33="${SHORT32}a"
[ "${#NAME40}" = 40 ] && [ "${#NAME41}" = 41 ] && [ "${#SHORT32}" = 32 ] && [ "${#SHORT33}" = 33 ]; check $? "(premise) the long names are 40, 41, 32 and 33 characters"
good_names=("$DEFAULT_NAME" "$CUSTOM_NAME" "a" "A-b.c 1" "7 Eleven" "x." "a..b" "$NAME40")
bad_names=("" " lead" "trail " "-lead" ".lead" ".." "../x" "a/b" "a&b" "a<b>" 'a"b' "a'b" 'a\b' 'a$(x)' 'a`x`' 'a;b' "a|b" "a*" "50%" $'a\nb' $'a\n' $'\na' $'a\tb' "é" "名前" "Ünï" "$NAME41")
good_shorts=("$DEFAULT_SHORT" "$CUSTOM_SHORT" "a" "A1" "Cate2" "$SHORT32")
bad_shorts=("" "1x" "a b" "a-b" "a.b" "a_b" "a/b" "../x" ".." "a&b" "a<b>" 'a"b' "a'b" 'a\b' 'a$(x)' 'a;b' "-a" " a" "a " $'a\nb' $'a\n' "é" "名前" "$SHORT33")
refused=0; for v in "${good_names[@]}"; do valid_name "$v" || { refused=1; echo "      a good name was refused: $(printf '%q' "$v")"; }; done
check $refused "the name validator accepts letters, digits, spaces, hyphens and periods (the default, a custom name, 40 characters)"
accepted=0; for v in "${bad_names[@]}"; do if valid_name "$v"; then accepted=1; echo "      a bad name was accepted: $(printf '%q' "$v")"; fi; done
check $accepted "the name validator refuses ${#bad_names[@]} bad names: empty, a leading space, hyphen or period, a trailing space, quotes, ampersand, angle brackets, slash, dot-dot, shell metacharacters, newlines, a tab, non-ASCII, 41 characters"
refused=0; for v in "${good_shorts[@]}"; do valid_short "$v" || { refused=1; echo "      a good short name was refused: $(printf '%q' "$v")"; }; done
check $refused "the short name validator accepts letters and digits that start with a letter (the default, a custom name, 32 characters)"
accepted=0; for v in "${bad_shorts[@]}"; do if valid_short "$v"; then accepted=1; echo "      a bad short name was accepted: $(printf '%q' "$v")"; fi; done
check $accepted "the short name validator refuses ${#bad_shorts[@]} bad names: empty, a leading digit, spaces, hyphen, period, underscore, slash, dot-dot, ampersand, quotes, shell metacharacters, newlines, non-ASCII, 33 characters"
[ "$(/bin/bash -c '. "$1/scripts/bundle_id.sh"; echo "$MCAP_DEFAULT_APP_NAME|$MCAP_DEFAULT_APP_SHORT_NAME"' _ "$ROOT")" = "$DEFAULT_NAME|$DEFAULT_SHORT" ]; check $? "the defaults of the library are '$DEFAULT_NAME' and $DEFAULT_SHORT (the one place that holds them)"
grep -q "static let defaultDisplayName = \"$DEFAULT_NAME\"" "$ROOT/app/Sources/App.swift" && grep -q "static let defaultShortName = \"$DEFAULT_SHORT\"" "$ROOT/app/Sources/App.swift"; check $? "the Swift fallbacks of a bare binary (AppInfo.defaultDisplayName / defaultShortName) are the same defaults"
grep -q "^DEFAULT_APP_NAME = \"$DEFAULT_NAME\"" "$ROOT/pipeline/mcap/appinfo.py" && grep -q "^DEFAULT_APP_SHORT_NAME = \"$DEFAULT_SHORT\"" "$ROOT/pipeline/mcap/appinfo.py"; check $? "the Python fallbacks (mcap/appinfo.py) are the same defaults"
grep -q "MCAP_APP_NAME:-$DEFAULT_NAME}" "$ROOT/.github/workflows/release.yml"; check $? "the release workflow's fallback for the title of the release (its publish job has no checkout) is the same default"
grep -q 'MCAP_APP_NAME: ${{ vars.MCAP_APP_NAME }}' "$ROOT/.github/workflows/release.yml" && grep -q 'MCAP_APP_SHORT_NAME: ${{ vars.MCAP_APP_SHORT_NAME }}' "$ROOT/.github/workflows/release.yml"; check $? "the release workflow forwards vars.MCAP_APP_NAME and vars.MCAP_APP_SHORT_NAME like the bundle id (an unset variable is empty: the default)"
grep -q '<key>CFBundleExecutable</key>' "$ROOT/app/Info.plist.template" && [ "$(plutil -extract CFBundleExecutable raw -o - "$ROOT/app/Info.plist.template")" = "@APP_SHORT_NAME@" ] && [ "$(plutil -extract CFBundleName raw -o - "$ROOT/app/Info.plist.template")" = "@APP_SHORT_NAME@" ] \
  && [ "$(plutil -extract CFBundleDisplayName raw -o - "$ROOT/app/Info.plist.template")" = "@APP_NAME@" ]; check $? "Info.plist.template: CFBundleExecutable and CFBundleName are @APP_SHORT_NAME@, CFBundleDisplayName is @APP_NAME@ (the template names no product)"
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSAppleEventsUsageDescription; do
    plutil -extract "$key" raw -o - "$ROOT/app/Info.plist.template" | grep -q '^@APP_NAME@ ' && plutil -extract "$key" raw -o - "$ROOT/app/Info.plist.template" | grep -q ' / @APP_NAME@ 앱은 ' || { echo "      $key does not name the app with @APP_NAME@ in both languages"; false; }
    check $? "Info.plist.template: $key names the app with @APP_NAME@, in English and in Korean (a fixed noun after the name, no particle that depends on it)"
done
grep -n 'MeetingCapture\.app\|Meeting Capture' "$ROOT"/app/Sources/*.swift | grep -v 'aboutCopyright' | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' > "$WORK/swift-names.txt" || true
[ ! -s "$WORK/swift-names.txt" ]; check $? "(Swift) no source line spells an app file or a product name (MeetingCapture.app, Meeting Capture) outside the copyright line and comments: they are built from AppInfo"
head -3 "$WORK/swift-names.txt" | sed 's/^/        > /'
grep -n 'MeetingCapture' "$ROOT"/app/Sources/*.swift | grep -v 'Application Support/MeetingCapture\|Logs/MeetingCapture\|MeetingCapture Anthropic API key\|MeetingCapture ASR\|^[^:]*:[0-9]*:[[:space:]]*//' > "$WORK/swift-internal.txt" || true
[ ! -s "$WORK/swift-internal.txt" ]; check $? "(Swift) what is left of the word MeetingCapture is an internal name: the data and log folders and the Keychain services (and the test fixtures of those)"
head -3 "$WORK/swift-internal.txt" | sed 's/^/        > /'

# resolvers: the app that is installed or built tells its own names, else the environment, else the defaults
fake_app_with_names() {   # fake_app_with_names <.app folder> <id> <name> <short name>
    mkdir -p "$1/Contents/MacOS"
    cat > "$1/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string><key>CFBundleDisplayName</key><string>$3</string><key>CFBundleName</key><string>$4</string></dict></plist>
PLISTEOF
    printf '#!/bin/sh\n' > "$1/Contents/MacOS/$4"; chmod 755 "$1/Contents/MacOS/$4"
}
resolve() {   # resolve <env assignments...> -- <function> [app...]: prints what the library resolves
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    env ${envs[@]+"${envs[@]}"} /bin/bash -c '. "$1/scripts/bundle_id.sh"; shift; "$@"' _ "$ROOT" "$@" 2>/dev/null
}
fake_app_with_names "$WORK/names-app/$CUSTOM_SHORT.app" "$CUSTOM_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
[ "$(resolve -- mcap_resolve_app_name)" = "$DEFAULT_NAME" ] && [ "$(resolve -- mcap_resolve_app_short_name)" = "$DEFAULT_SHORT" ]; check $? "resolvers without an app and without environment: the defaults"
[ "$(resolve MCAP_APP_NAME= MCAP_APP_SHORT_NAME= -- mcap_resolve_app_name)" = "$DEFAULT_NAME" ] && [ "$(resolve MCAP_APP_NAME= MCAP_APP_SHORT_NAME= -- mcap_resolve_app_short_name)" = "$DEFAULT_SHORT" ]; check $? "... an EMPTY value counts as unset"
[ "$(resolve MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" -- mcap_resolve_app_name)" = "$CUSTOM_NAME" ] && [ "$(resolve MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" -- mcap_resolve_app_short_name)" = "$CUSTOM_SHORT" ]; check $? "... the environment comes before the defaults"
[ "$(resolve MCAP_APP_NAME=Other MCAP_APP_SHORT_NAME=Other -- mcap_resolve_app_name "$WORK/names-app/$CUSTOM_SHORT.app")" = "$CUSTOM_NAME" ] && [ "$(resolve MCAP_APP_NAME=Other MCAP_APP_SHORT_NAME=Other -- mcap_resolve_app_short_name "$WORK/names-app/$CUSTOM_SHORT.app")" = "$CUSTOM_SHORT" ]; check $? "... and the app's own Info.plist (CFBundleDisplayName, CFBundleName) comes before the environment"
[ "$(resolve -- mcap_resolve_app_name "$WORK/names-app/none.app" "$WORK/names-app/$CUSTOM_SHORT.app")" = "$CUSTOM_NAME" ]; check $? "... a missing app is skipped, the next one is asked"
fake_app_with_names "$WORK/names-app/bad.app" "$CUSTOM_ID" 'bad &amp; name' 'bad name'
[ "$(resolve MCAP_APP_NAME=Other -- mcap_resolve_app_name "$WORK/names-app/bad.app")" = "Other" ] && [ "$(resolve -- mcap_resolve_app_short_name "$WORK/names-app/bad.app")" = "$DEFAULT_SHORT" ]; check $? "... an Info.plist with a name that breaks the rules is ignored (warned about), not trusted"
runx env MCAP_APP_NAME='a&b' MCAP_APP_SHORT_NAME='a b' /bin/bash -c '. scripts/bundle_id.sh; mcap_resolve_app_name || echo "rc=$?"; mcap_resolve_app_short_name || echo "rc=$?"'
out_has 'MCAP_APP_NAME=a\\&b is not a valid app name' "a bad MCAP_APP_NAME is refused with the reason, naming the variable and the value"
out_has 'MCAP_APP_SHORT_NAME=a\\ b is not a valid short app name' "... and a bad MCAP_APP_SHORT_NAME"
[ "$(grep -c '^rc=1$' "$OUT")" = 2 ]; check $? "... both resolvers return 1"

# build_app.sh refuses a bad name BEFORE anything is built (no compile, no app, no signature), and never runs it
refuse_name() {   # refuse_name <variable> <value> <text in the refusal> <test name>
    fresh_env sign; stub_loaded
    build env "$1=$2" /bin/bash scripts/build_app.sh
    if [ "$RC" != 0 ] && grep -q "$3" "$OUT" && grep -q 'Nothing was built' "$OUT" && [ ! -e "$H/build/obj" ] && ! ls "$H/build"/*.app >/dev/null 2>&1 && [ ! -s "$LOGS/codesign.log" ]; then
        ok "$4"
    else
        bad "$4   (exit code $RC)"; show_tail
    fi
}
refuse_name MCAP_APP_SHORT_NAME "a b" 'not a valid short app name' "build_app.sh refuses MCAP_APP_SHORT_NAME with a space, before compiling and signing anything"
refuse_name MCAP_APP_SHORT_NAME "1x" 'not a valid short app name' "... a leading digit"
refuse_name MCAP_APP_SHORT_NAME "a-b" 'not a valid short app name' "... a hyphen"
refuse_name MCAP_APP_SHORT_NAME "a/b" 'not a valid short app name' "... a slash"
refuse_name MCAP_APP_SHORT_NAME ".." 'not a valid short app name' "... dot-dot"
refuse_name MCAP_APP_SHORT_NAME 'a$(x)' 'not a valid short app name' "... a command substitution"
refuse_name MCAP_APP_SHORT_NAME $'a\nb' 'not a valid short app name' "... a newline"
refuse_name MCAP_APP_SHORT_NAME "$SHORT33" 'not a valid short app name' "... 33 characters"
refuse_name MCAP_APP_SHORT_NAME "é" 'not a valid short app name' "... a non-ASCII letter"
refuse_name MCAP_APP_NAME "a&b" 'not a valid app name' "build_app.sh refuses MCAP_APP_NAME with an ampersand (it would be a sed back-reference), before anything is built"
refuse_name MCAP_APP_NAME "a<b>" 'not a valid app name' "... angle brackets (XML)"
refuse_name MCAP_APP_NAME 'a"b' 'not a valid app name' "... a double quote"
refuse_name MCAP_APP_NAME "a/b" 'not a valid app name' "... a slash"
refuse_name MCAP_APP_NAME "-lead" 'not a valid app name' "... a leading hyphen"
refuse_name MCAP_APP_NAME " lead" 'not a valid app name' "... a leading space"
refuse_name MCAP_APP_NAME "trail " 'not a valid app name' "... a trailing space"
refuse_name MCAP_APP_NAME $'a\nb' 'not a valid app name' "... a newline"
refuse_name MCAP_APP_NAME "$NAME41" 'not a valid app name' "... 41 characters"
refuse_name MCAP_APP_NAME "名前" 'not a valid app name' "... non-ASCII characters"
fresh_env sign; stub_loaded
build MCAP_APP_NAME='a$(touch '"$WORK"'/pwned2)' /bin/bash scripts/build_app.sh
[ ! -e "$WORK/pwned2" ] && [ "$RC" != 0 ]; check $? "a command substitution in MCAP_APP_NAME is refused and never executed"

# a REAL ad-hoc build (real swiftc and real codesign, no identity, no keychain) with the default names and with a custom trio
for trio in default custom; do
    fresh_env base; stub_loaded
    if [ "$trio" = default ]; then WANT_ID="$DEFAULT_ID"; WANT_NAME="$DEFAULT_NAME"; WANT_SHORT="$DEFAULT_SHORT"; build MC_CODESIGN_IDENTITY=- /bin/bash scripts/build_app.sh
    else   # the custom build compiles the REAL app/Sources (minutes, no stub program): only a real program can show that the names are read from Info.plist at run time
        WANT_ID="$CUSTOM_ID"; WANT_NAME="$CUSTOM_NAME"; WANT_SHORT="$CUSTOM_SHORT"
        runx MCAP_BUILD_DIR="$H/build" MC_CODESIGN_IDENTITY=- MCAP_BUNDLE_ID="$WANT_ID" MCAP_APP_NAME="$WANT_NAME" MCAP_APP_SHORT_NAME="$WANT_SHORT" /bin/bash scripts/build_app.sh
    fi
    rc_is 0 "real ad-hoc build with the $trio names ($WANT_NAME, $WANT_SHORT.app, $WANT_ID)"
    APPB="$H/build/$WANT_SHORT.app"; PL="$APPB/Contents/Info.plist"
    [ -d "$APPB" ] && [ "$(ls "$H/build" | grep -c '\.app$')" = 1 ]; check $? "... the app folder is $WANT_SHORT.app, and it is the only app in the build folder"
    [ -x "$APPB/Contents/MacOS/$WANT_SHORT" ] && [ "$(ls "$APPB/Contents/MacOS")" = "$WANT_SHORT" ]; check $? "... its executable is Contents/MacOS/$WANT_SHORT (and nothing else is there)"
    [ "$(plutil -extract CFBundleExecutable raw -o - "$PL")" = "$WANT_SHORT" ] && [ "$(plutil -extract CFBundleName raw -o - "$PL")" = "$WANT_SHORT" ]; check $? "... CFBundleExecutable and CFBundleName are the short name"
    [ "$(plutil -extract CFBundleDisplayName raw -o - "$PL")" = "$WANT_NAME" ]; check $? "... CFBundleDisplayName is the human name"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$PL")" = "$WANT_ID" ]; check $? "... CFBundleIdentifier is $WANT_ID"
    names_ok=0
    for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSAppleEventsUsageDescription; do
        v="$(plutil -extract "$key" raw -o - "$PL")"
        case "$v" in "$WANT_NAME "*" / $WANT_NAME 앱은 "*) ;; *) names_ok=1; echo "      $key does not name the app in both languages: ${v:0:90}" ;; esac
    done
    check $names_ok "... the usage strings (microphone, system audio, Apple Events) name the app with the human name, in English and in Korean"
    ! grep -Eq '@[A-Z_]+@' "$PL"; check $? "... no placeholder is left in Info.plist"
    [ "$trio" = default ] || { ! grep -q "$DEFAULT_NAME\|$DEFAULT_SHORT\|MeetingCapture" "$PL" || { grep -n "$DEFAULT_NAME\|$DEFAULT_SHORT\|MeetingCapture" "$PL" | head -3 | sed 's/^/        > /'; false; }; check $? "... and nothing of the default names is left in it"; }
    SIGINFO_REAL="$(codesign -dvvv "$APPB" 2>&1)"
    grep -q "^Identifier=$WANT_ID\$" <<< "$SIGINFO_REAL"; check $? "... codesign Identifier is the bundle id ($WANT_ID), not a name"
    codesign --verify --strict -R="identifier \"$WANT_ID\"" "$APPB" 2>/dev/null; check $? "... the signature satisfies  identifier \"$WANT_ID\""
    if [ "$trio" = custom ]; then
        # the program reads its names from its Info.plist at run time (a program that ignored the plist would print the defaults here); --version and --help need no permission and capture nothing
        REAL_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PL")"
        REAL_RUN="$WORK/real-run"; mkdir -p "$REAL_RUN/home"
        [ "$(env HOME="$REAL_RUN/home" MCAP_LOG_DIR="$REAL_RUN" "$APPB/Contents/MacOS/$WANT_SHORT" --version 2>&1)" = "$WANT_NAME $REAL_VERSION" ]; check $? "... the program prints its human name at run time: --version is \"$WANT_NAME $REAL_VERSION\""
        env HOME="$REAL_RUN/home" MCAP_LOG_DIR="$REAL_RUN" "$APPB/Contents/MacOS/$WANT_SHORT" --help > "$REAL_RUN/help.txt" 2>&1
        grep -q "^usage: $WANT_SHORT \[command\]\$" "$REAL_RUN/help.txt" && grep -q "^$WANT_NAME $REAL_VERSION\$" "$REAL_RUN/help.txt" && grep -q "open -n -W -a ~/Applications/$WANT_SHORT\.app " "$REAL_RUN/help.txt"; check $? "... and --help names the program and the app file the same way (usage: $WANT_SHORT, ~/Applications/$WANT_SHORT.app)"
        ! grep -q "$DEFAULT_SHORT\|$DEFAULT_NAME" "$REAL_RUN/help.txt"; check $? "... and nothing of the default names is left in that help text"
        [ -z "$(ls -A "$REAL_RUN/home")" ]; check $? "... and running it created nothing in the home folder"
    fi
done

# --install goes to ~/Applications/<short name>.app; the same bundle id under another file name is refused (one login agent, one set of permissions)
fresh_env sign; stub_loaded
build MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" MCAP_APP_NAME="$CUSTOM_NAME" /bin/bash scripts/build_app.sh --install
rc_is 0 "--install with MCAP_APP_SHORT_NAME=$CUSTOM_SHORT"
[ -x "$H/Applications/$CUSTOM_SHORT.app/Contents/MacOS/$CUSTOM_SHORT" ] && [ ! -e "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "... the app is ~/Applications/$CUSTOM_SHORT.app, not $DEFAULT_SHORT.app"
SUM_BEFORE="$(cksum < "$H/Applications/$CUSTOM_SHORT.app/Contents/Info.plist")"
build MCAP_BUILD_DIR="$H/build-two" /bin/bash scripts/build_app.sh --install
rc_not 0 "--install of a build with the same id but another file name ($DEFAULT_SHORT.app next to $CUSTOM_SHORT.app) is refused"
out_has "$H/Applications/$CUSTOM_SHORT\\.app already has this build's bundle id \\($DEFAULT_ID\\), but this build would install to $H/Applications/$DEFAULT_SHORT\\.app" "... naming both paths and the id"
out_has 'Two apps with one id share one login agent and one set of permissions' "... and why"
out_has "Remove or rename the old one \\($H/Applications/$CUSTOM_SHORT\\.app\\), or set MCAP_APP_SHORT_NAME=$CUSTOM_SHORT" "... and the two ways out"
[ ! -e "$H/build-two/obj" ] && [ ! -e "$H/build-two/$DEFAULT_SHORT.app" ] && [ ! -e "$H/Applications/$DEFAULT_SHORT.app" ] && [ "$(cksum < "$H/Applications/$CUSTOM_SHORT.app/Contents/Info.plist")" = "$SUM_BEFORE" ]; check $? "... before anything was built, and the installed app is untouched"
build MCAP_BUILD_DIR="$H/build-two" /bin/bash scripts/build_app.sh
rc_is 0 "a build of another file name without --install is not affected"
build MCAP_BUILD_DIR="$H/build-two" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" MCAP_APP_NAME="$CUSTOM_NAME" /bin/bash scripts/build_app.sh --install
rc_is 0 "the way out: --install under the old file name replaces it (MCAP_APP_SHORT_NAME=$CUSTOM_SHORT)"
mv "$H/Applications/$CUSTOM_SHORT.app" "$WORK/old-copy.app"
build MCAP_BUILD_DIR="$H/build-two" /bin/bash scripts/build_app.sh --install
rc_is 0 "the other way out: the old copy removed or renamed, the install goes to $DEFAULT_SHORT.app"
[ -d "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "... ~/Applications/$DEFAULT_SHORT.app exists"
fresh_env sign; stub_loaded
fake_app_with_names "$H/Applications/Other.app" "com.example.other" "Other" "Other"
build /bin/bash scripts/build_app.sh --install
rc_is 0 "another app in ~/Applications with ANOTHER bundle id is not in the way"
fresh_env sign; stub_loaded
mkdir -p "$H/Applications/Damaged.app/Contents"; echo "not a plist" > "$H/Applications/Damaged.app/Contents/Info.plist"
build /bin/bash scripts/build_app.sh --install
rc_is 0 "an app in ~/Applications whose Info.plist cannot be read is not in the way"

# the other scripts name the app after the names, never retyped
fresh_env base; stub_loaded
mkdir -p "$SUPPORT"; printf 'confirmed=test\n' > "$SUPPORT/live-tested.confirmed"
runx /bin/bash scripts/make_launchagent.sh
rc_is 0 "make_launchagent.sh with the default names"
[ "$(plutil -extract ProgramArguments.0 raw -o - "$H/Library/LaunchAgents/$DEFAULT_ID.plist")" = "$H/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT" ]; check $? "... the agent starts ~/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT"
rm -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/make_launchagent.sh
[ "$(plutil -extract ProgramArguments.0 raw -o - "$H/Library/LaunchAgents/$DEFAULT_ID.plist")" = "$H/Applications/$CUSTOM_SHORT.app/Contents/MacOS/$CUSTOM_SHORT" ]; check $? "... with MCAP_APP_SHORT_NAME the agent starts that app's executable"
rm -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
fake_app_with_names "$H/Applications/Elsewhere.app" "$CUSTOM_ID" "$CUSTOM_NAME" "ExtraName"
runx /bin/bash scripts/make_launchagent.sh --app "$H/Applications/Elsewhere.app"
[ "$(plutil -extract ProgramArguments.0 raw -o - "$H/Library/LaunchAgents/$CUSTOM_ID.plist")" = "$H/Applications/Elsewhere.app/Contents/MacOS/ExtraName" ]; check $? "... --app PATH: the executable is the one the app's own CFBundleName says"
runx env MCAP_APP_SHORT_NAME='a b' /bin/bash scripts/make_launchagent.sh
rc_not 0 "make_launchagent.sh refuses a bad MCAP_APP_SHORT_NAME"
out_has 'not a valid short app name' "... with the reason"
# the app is installed under another file name than the names say (an older build; the builder who set only MCAP_BUNDLE_ID): the one app that has the id is the app
rm -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist"
runx /bin/bash scripts/make_launchagent.sh --dry-run
out_has 'WARNING: .*/Applications/'"$DEFAULT_SHORT"'\.app/Contents/MacOS/'"$DEFAULT_SHORT"' does not exist yet' "make_launchagent.sh with no app of that name (and none with the id) warns that the program does not exist"
out_has 'set MCAP_APP_SHORT_NAME to that name or pass --app' "... and says what to do when the app is installed under another file name"
runx env MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/make_launchagent.sh
out_has "$H/Applications/Elsewhere\\.app has the bundle id $CUSTOM_ID, so that is the app" "with MCAP_BUNDLE_ID only, the one app in ~/Applications that has the id is found although its file name is not the short name"
[ "$(plutil -extract ProgramArguments.0 raw -o - "$H/Library/LaunchAgents/$CUSTOM_ID.plist")" = "$H/Applications/Elsewhere.app/Contents/MacOS/ExtraName" ]; check $? "... and the agent starts that app's own program"
rm -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist"
fake_app_with_names "$H/Applications/Another.app" "$CUSTOM_ID" "$CUSTOM_NAME" "AnotherName"
runx env MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/make_launchagent.sh --load
rc_not 0 "two apps with the id and no file name to choose by: --load is refused (nothing is guessed)"
out_has 'set MCAP_APP_SHORT_NAME to it, or pass --app' "... and says how to choose"
[ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ]; check $? "... without writing the plist"
mv "$H/Applications/Another.app" "$WORK/another-aside.app"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent --accept-legal-notice
rc_is 0 "install.sh --dry-run --no-build with the default names"
out_has "app +: $DEFAULT_NAME, $H/Applications/$DEFAULT_SHORT\\.app" "... says which app it works with"
out_has "LEGAL NOTICE: $DEFAULT_NAME records other people" "... and the notice names it"
runx env MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/install.sh --dry-run --accept-legal-notice
rc_is 0 "install.sh --dry-run with MCAP_APP_NAME and MCAP_APP_SHORT_NAME"
out_has "app +: $CUSTOM_NAME, $H/Applications/$CUSTOM_SHORT\\.app" "... the app is ~/Applications/$CUSTOM_SHORT.app"
out_has "open -n -W -a \"$H/Applications/$CUSTOM_SHORT\\.app\"" "... and the commands it prints open that app"
out_has "attributed to $CUSTOM_NAME" "... and the permission text names the human name"
out_has "LEGAL NOTICE: $CUSTOM_NAME records other people" "... and the recording legal notice names the app by MCAP_APP_NAME"
out_lacks "$DEFAULT_SHORT\\.app" "... and nothing names the default app file"
runx env MCAP_APP_SHORT_NAME='a b' /bin/bash scripts/install.sh --dry-run --accept-legal-notice
rc_not 0 "install.sh refuses a bad MCAP_APP_SHORT_NAME"
out_has 'Nothing was changed' "... before changing anything"
fresh_env base; stub_loaded
fake_app_with_names "$H/Applications/$CUSTOM_SHORT.app" "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent --accept-legal-notice
out_has "app +: $DEFAULT_NAME, $H/Applications/$DEFAULT_SHORT\\.app" "install.sh --no-build looks at ~/Applications/<short name>.app of the environment (the default here) and not at another app"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent --accept-legal-notice
out_has "app +: $CUSTOM_NAME, $H/Applications/$CUSTOM_SHORT\\.app" "... --no-build with the short name: the installed app tells its own human name ($CUSTOM_NAME)"

# uninstall.sh: the app of the short name goes; another app with the same id (an older build) is named, not deleted by guess
fresh_env base; stub_loaded
fake_app_with_names "$H/Applications/$CUSTOM_SHORT.app" "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
runx /bin/bash scripts/uninstall.sh
rc_is 0 "uninstall.sh without the short name of an app that was built with another one"
[ -d "$H/Applications/$CUSTOM_SHORT.app" ]; check $? "... it does not delete an app it was not told about (the file name is not guessed)"
out_has "no app at $H/Applications/$DEFAULT_SHORT\\.app" "... and says what it looked for"
out_has "NOTE: $H/Applications/$CUSTOM_SHORT\\.app has the same bundle id \\($DEFAULT_ID\\) under another file name .* It was NOT removed: delete it yourself, or run this again with MCAP_APP_SHORT_NAME=$CUSTOM_SHORT" "... and names the app that has the same id, with the two ways out"
runx env MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/uninstall.sh
rc_is 0 "uninstall.sh with MCAP_APP_SHORT_NAME=$CUSTOM_SHORT"
[ ! -e "$H/Applications/$CUSTOM_SHORT.app" ]; check $? "... removes ~/Applications/$CUSTOM_SHORT.app"
fresh_env base; stub_loaded
runx env MCAP_APP_SHORT_NAME='../x' /bin/bash scripts/uninstall.sh
rc_not 0 "uninstall.sh refuses a bad MCAP_APP_SHORT_NAME (it becomes a file name that is deleted)"
out_has 'Nothing was changed' "... before changing anything"
fresh_env base; stub_loaded
fake_app_with_names "$H/Applications/$DEFAULT_SHORT.app" "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
runx /bin/bash scripts/uninstall.sh --dry-run
out_has "would delete $H/Applications/$DEFAULT_SHORT\\.app" "uninstall.sh --dry-run lists the app of the short name"

# ---------------------------------------------------------------------------------------------------------------
section "make_signing_identity.sh (stub security/codesign; real openssl; nothing touches a keychain)"
# ---------------------------------------------------------------------------------------------------------------
sign_home() { fresh_env sign; stub_loaded; mkdir -p "$H/tmp"; }
tmp_clean() { [ -z "$(ls -A "$H/tmp" 2>/dev/null)" ]; }

sign_home
runx /bin/bash scripts/make_signing_identity.sh --dry-run
rc_is 0 "--dry-run exits 0"
out_has 'would run: security import' "--dry-run prints the import command instead of running it"
out_has 'CN=MeetingCapture Local Signing.*Code Signing' "--dry-run shows the certificate it checked (extended key usage Code Signing)"
out_has 'security delete-identity -c "MeetingCapture Local Signing" -t' "--dry-run documents how to remove the identity"
! grep -qE '^security (import|add-trusted-cert|delete|create|set|unlock)' "$LOGS/security.log" 2>/dev/null; check $? "--dry-run called no modifying security subcommand"
[ ! -s "$LOGS/codesign.log" ]; check $? "--dry-run signed nothing"
[ ! -e "$STATE/identities" ]; check $? "--dry-run left the (fake) keychain unchanged"
tmp_clean; check $? "--dry-run left no temp files (the throw-away private key is deleted)"

sign_home
runx /bin/bash scripts/make_signing_identity.sh
rc_is 0 "fresh create + self-test (stub accepts the untrusted identity) exits 0"
grep -q "^security import .* -k $STATE/login.keychain-db -P [0-9a-f]\{32\} -T /usr/bin/codesign\$" "$LOGS/security.log"; check $? "security import <p12> -k <login keychain> -P <random> -T /usr/bin/codesign (exactly this form)"
[ "$(count_in '^security import' "$LOGS/security.log")" = 1 ]; check $? "exactly one import"
! grep -q 'add-trusted-cert' "$LOGS/security.log"; check $? "no trust change when codesign accepts the identity (nothing asked, nothing changed)"
[ ! -s "$LOGS/forbidden.log" ]; check $? "no forbidden security subcommand"
H1="$(sed -n 's/^\([0-9A-F]\{40\}\)|.*/\1/p' "$STATE/identities" | head -n 1)"
grep -q -- "--force --sign $H1 --timestamp=none --identifier $DEFAULT_ID " "$LOGS/codesign.log"; check $? "self-test signed a COPY of /usr/bin/true with the new identity hash and the app's identifier"
grep -q '/usr/bin/true' "$LOGS/codesign.log" || grep -q '/true' "$LOGS/codesign.log"; check $? "the signed object is the temp copy named true, not an installed binary"
out_has 'self-test OK' "prints the self-test result"
out_has "identifier \"$DEFAULT_ID\" and certificate leaf = H\"$(echo "$H1" | tr 'A-F' 'a-f')\"" "prints the designated requirement macOS will store"
runx /bin/bash scripts/make_signing_identity.sh --help
out_has 'never asks for, reads or stores your password' "--help promises that your password is never handled"
out_has 'delete-identity' "--help documents how to remove the identity"
tmp_clean; check $? "no temp files left (private key and p12 deleted)"
# the exact p12 the script made must be 3DES/SHA1 (macOS readable) and carry the code signing EKU: stub saved the cert
/usr/bin/openssl x509 -in "$STATE/cert.pem" -noout -text | grep -q 'Code Signing'; check $? "imported certificate has the Code Signing extended key usage"
/usr/bin/openssl x509 -in "$STATE/cert.pem" -noout -text | grep -q 'CA:FALSE'; check $? "imported certificate is a leaf (CA:FALSE)"

# idempotent: run again on the same state
runx /bin/bash scripts/make_signing_identity.sh
rc_is 0 "second run exits 0"
out_has 'already exists' "second run: the identity is detected by name"
[ "$(count_in '^security import' "$LOGS/security.log")" = 1 ]; check $? "second run does NOT import again"

# duplicates
sign_home
add_identity "$HASH_A"; add_identity "$HASH_B"
runx /bin/bash scripts/make_signing_identity.sh
rc_is 1 "two existing identities with the name: refused (exit 1)"
out_has "2 identities are named" "the duplicate is explained"
! grep -q '^security import' "$LOGS/security.log"; check $? "nothing imported when duplicates exist"

# codesign refuses an untrusted identity: print the follow-up, change nothing, exit 3
sign_home
runx STUB_CODESIGN_MODE=needs_trust /bin/bash scripts/make_signing_identity.sh
rc_is 3 "refused by codesign: exit code 3"
out_has 'security add-trusted-cert -r trustRoot -p codeSign' "prints the exact user-domain trust command"
out_has 'password dialog' "explains that it opens a password dialog"
out_has 'YOUR user account only' "explains what the trust setting changes"
out_has '[-][-]trust' "tells to re-run with --trust"
! grep -q 'add-trusted-cert' "$LOGS/security.log"; check $? "without --trust the trust command is NOT run"
# now with --trust (identity already imported)
runx STUB_CODESIGN_MODE=needs_trust /bin/bash scripts/make_signing_identity.sh --trust
rc_is 0 "--trust after a refusal: signing works afterwards, exit 0"
[ "$(count_in '^security add-trusted-cert' "$LOGS/security.log")" = 1 ]; check $? "add-trusted-cert called exactly once"
grep -q '^security add-trusted-cert -r trustRoot -p codeSign ' "$LOGS/security.log"; check $? "add-trusted-cert -r trustRoot -p codeSign <pem> (user domain: no -d)"
! grep '^security add-trusted-cert' "$LOGS/security.log" | grep -q -- ' -d '; check $? "never the admin domain (-d)"
[ "$(count_in '^security import' "$LOGS/security.log")" = 1 ]; check $? "no second import"
out_has 'self-test OK' "self-test passes after the trust step"
# --trust is only a permission: not used when signing works without it
sign_home
runx /bin/bash scripts/make_signing_identity.sh --trust
rc_is 0 "--trust on a Mac that accepts the untrusted identity"
! grep -q 'add-trusted-cert' "$LOGS/security.log"; check $? "--trust does not change trust settings when codesign already works"
# not a trust problem
sign_home
runx STUB_CODESIGN_MODE=access /bin/bash scripts/make_signing_identity.sh --trust
rc_is 3 "key access problem: exit code 3"
out_has 'not a trust problem' "says it is not a trust problem"
! grep -q 'add-trusted-cert' "$LOGS/security.log"; check $? "key access problem: no trust change even with --trust"

# --export-only: no keychain at all; both openssl flavours
for ossl in /usr/bin/openssl /opt/homebrew/bin/openssl; do
    [ -x "$ossl" ] || continue
    sign_home
    runx MCAP_OPENSSL="$ossl" /bin/bash scripts/make_signing_identity.sh --export-only "$H/exported"
    rc_is 0 "--export-only with $("$ossl" version | awk '{print $1, $2}')"
    [ ! -e "$LOGS/security.log" ]; check $? "--export-only does not call security at all"
    PW="$(sed -n 's/^One-time password of the .p12 file (it is not stored anywhere else): //p' "$OUT")"
    [ "${#PW}" = 32 ]; check $? "a 32-character one-time password is printed"
    "$ossl" pkcs12 -in "$H/exported/MeetingCapture-Local-Signing.p12" -passin "pass:$PW" -nokeys -noout 2>/dev/null; check $? "the p12 opens with that password ($ossl)"
    /usr/bin/openssl pkcs12 -info -in "$H/exported/MeetingCapture-Local-Signing.p12" -passin "pass:$PW" -noout 2>&1 | grep -q 'pbeWithSHA1And3-KeyTripleDES-CBC'; check $? "the p12 uses 3DES/SHA-1 PBE (what macOS 'security import' reads, also when made by OpenSSL 3)"
    "$ossl" x509 -in "$H/exported/MeetingCapture-Local-Signing.cert.pem" -noout -text | grep -q 'Code Signing'; check $? "exported certificate has the Code Signing extended key usage"
    [ "$(stat -f %Lp "$H/exported")" = 700 ] && [ "$(stat -f %Lp "$H/exported/MeetingCapture-Local-Signing.p12")" = 600 ]; check $? "the export directory is 700 and the p12 600"
done
sign_home
runx /bin/bash scripts/make_signing_identity.sh --bogus
rc_is 2 "unknown option: exit 2"

# >>> W8b company packaging tests (begin)
# ---------------------------------------------------------------------------------------------------------------
section "company packaging (W8b): stubs, an independent Ed25519 signer, helpers"
# ---------------------------------------------------------------------------------------------------------------
# Everything below runs in the temp directory with stubs first on PATH. Never real: pkgbuild, productbuild, productsign, pkgutil, xcrun (notarytool is
# logged as FORBIDDEN and fails), codesign (a stub that remembers whether the hardened runtime was asked for), launchctl, security, sudo (a stub that
# only logs and runs the command it was given), tmutil, dscl, sysctl, sw_vers, chown. No identity, no keychain, no notarization, no MDM, no network.
STUBS_PKG="$WORK/stubs-pkg"
mkdir -p "$STUBS_PKG"
cp "$STUBS_BASE"/* "$STUBS_PKG"/
for name in pkgbuild productbuild; do
    cat > "$STUBS_PKG/$name" <<EOF
#!/bin/sh
# Fake $name: logs its arguments and creates an EMPTY file at the output path (the last argument). It never builds anything.
echo "$name \$*" >> "\${STUB_LOG:?}/$name.log"
for last; do :; done
: > "\$last"
exit 0
EOF
done
cat > "$STUBS_PKG/pkgutil" <<'EOF'
#!/bin/sh
echo "pkgutil $*" >> "${STUB_LOG:?}/pkgutil.log"
exit 0
EOF
cat > "$STUBS_PKG/xcrun" <<'EOF'
#!/bin/sh
# Fake xcrun: notarytool, stapler and altool are FORBIDDEN here (notarization is an owner action with an Apple account); the SDK lookups that
# build_app.sh needs go to the real tool.
case "$1" in
    notarytool|stapler|altool) echo "xcrun $*" >> "${STUB_LOG:?}/forbidden.log"; echo "stub xcrun: refusing '$*'" >&2; exit 99 ;;
    *) exec /usr/bin/xcrun "$@" ;;
esac
EOF
cat > "$STUBS_PKG/codesign" <<'EOF'
#!/bin/sh
# Fake codesign for the package tests: remembers the identity, whether the hardened runtime ('--options runtime') and a secure timestamp ('--timestamp') were asked for.
LOG="${STUB_LOG:?}"
echo "codesign $*" >> "$LOG/codesign.log"
for target; do :; done
sigfile() { if [ -d "$1" ]; then echo "$1/.stubsig"; else echo "$1.stubsig"; fi; }
case "$1" in
  --force)
    sign=""; ident=""; runtime=0; stamp=0; prev=""
    for a in "$@"; do
        case "$prev" in --sign) sign="$a" ;; --identifier) ident="$a" ;; --options) [ "$a" = runtime ] && runtime=1 ;; esac
        [ "$a" = --timestamp ] && stamp=1
        prev="$a"
    done
    printf '%s\n%s\n%s\n%s\n' "$sign" "$ident" "$runtime" "$stamp" > "$(sigfile "$target")"
    exit 0 ;;
  --verify) exit 0 ;;
  -d|-dvv|-dvvv)
    f="$(sigfile "$target")"
    [ -f "$f" ] || { echo "$target: code object is not signed at all" >&2; exit 1; }
    sign="$(sed -n 1p "$f")"; ident="$(sed -n 2p "$f")"; runtime="$(sed -n 3p "$f")"; stamp="$(sed -n 4p "$f")"
    for a in "$@"; do
        if [ "$a" = "-r-" ]; then
            if [ "$sign" = "-" ]; then echo "# designated => cdhash H\"0123456789abcdef0123456789abcdef01234567\""
            else echo "designated => identifier \"$ident\" and certificate leaf = H\"$sign\""; fi
            exit 0
        fi
    done
    echo "Executable=$target" >&2
    echo "Identifier=$ident" >&2
    if [ "$runtime" = 1 ]; then echo "CodeDirectory v=20500 size=338 flags=0x10000(runtime) hashes=4+3 location=embedded" >&2
    elif [ "$sign" = "-" ]; then echo "CodeDirectory v=20400 size=338 flags=0x2(adhoc) hashes=4+3 location=embedded" >&2
    else echo "CodeDirectory v=20400 size=338 flags=0x0(none) hashes=4+3 location=embedded" >&2; fi
    echo "CDHash=0123456789abcdef0123456789abcdef01234567" >&2
    [ "$sign" = "-" ] || echo "Authority=$sign" >&2
    [ "$stamp" != 1 ] || echo "Timestamp=Oct 16, 2026 at 12:00:00 PM" >&2
    exit 0 ;;
  *) echo "stub codesign: unexpected $*" >&2; exit 98 ;;
esac
EOF
cat > "$STUBS_PKG/tmutil" <<'EOF'
#!/bin/sh
echo "tmutil $*" >> "${STUB_LOG:?}/tmutil.log"
exit 0
EOF
cat > "$STUBS_PKG/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "${STUB_LOG:?}/chown.log"
exit 0
EOF
cat > "$STUBS_PKG/sudo" <<'EOF'
#!/bin/sh
# Fake sudo: logs the call, drops -u NAME and -H, and runs the rest as the same (test) user.
echo "sudo $*" >> "${STUB_LOG:?}/sudo.log"
while [ $# -gt 0 ]; do
    case "$1" in -u) shift 2 ;; -H) shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac
done
exec "$@"
EOF
cat > "$STUBS_PKG/dscl" <<'EOF'
#!/bin/sh
# Fake dscl: the account database of the tests. STUB_REALNAME and STUB_HOME describe the user that is asked about.
echo "dscl $*" >> "${STUB_LOG:?}/dscl.log"
[ "$1" = "." ] && [ "$2" = "-read" ] || exit 56
case "$4" in
    RealName) [ -n "${STUB_REALNAME:-}" ] || exit 56; echo "RealName:"; echo " $STUB_REALNAME"; exit 0 ;;
    NFSHomeDirectory) [ -n "${STUB_HOME:-}" ] || exit 56; echo "NFSHomeDirectory: $STUB_HOME"; exit 0 ;;
esac
exit 56
EOF
cat > "$STUBS_PKG/sysctl" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "hw.optional.arm64" ]; then echo "${STUB_ARM64:-1}"; exit 0; fi
exec /usr/sbin/sysctl "$@"
EOF
cat > "$STUBS_PKG/sw_vers" <<'EOF'
#!/bin/sh
if [ "$1" = "-productVersion" ]; then echo "${STUB_MACOS:-15.1}"; exit 0; fi
exec /usr/bin/sw_vers "$@"
EOF
chmod +x "$STUBS_PKG"/*
# "root" for the scripts that check id -u and stat -f %u (the same trick as scripts/asr_server/test_install_server.sh): only in the tests that say so
STUBS_ROOT="$WORK/stubs-root"
mkdir -p "$STUBS_ROOT"
cat > "$STUBS_ROOT/id" <<'EOF'
#!/bin/sh
case "$*" in
    "-u") echo 0 ;;
    "-un") echo root ;;
    "-u "*) echo 501 ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF
cat > "$STUBS_ROOT/stat" <<'EOF'
#!/bin/sh
case "$*" in
    "-f %u "*) echo 0 ;;
    *) exec /usr/bin/stat "$@" ;;
esac
EOF
chmod +x "$STUBS_ROOT"/*

# the independent signer: RFC 8032 reference code, NOT the verifier of scripts/provision_runtime.sh (so a bug in one cannot hide in the other)
cat > "$WORK/ed25519_tool.py" <<'EOF'
import base64, hashlib, os, sys
p = 2**255 - 19
q = 2**252 + 27742317777372353535851937790883648493
d = -121665 * pow(121666, p - 2, p) % p
def inv(x): return pow(x, p - 2, p)
def add(P, Q):
    A, B = (P[1]-P[0]) * (Q[1]-Q[0]) % p, (P[1]+P[0]) * (Q[1]+Q[0]) % p
    C, D = 2 * P[3] * Q[3] * d % p, 2 * P[2] * Q[2] % p
    E, F, G, H = B-A, D-C, D+C, B+A
    return (E*F % p, G*H % p, F*G % p, E*H % p)
def mul(s, P):
    Q = (0, 1, 1, 0)
    while s > 0:
        if s & 1: Q = add(Q, P)
        P = add(P, P); s >>= 1
    return Q
sqrt_m1 = pow(2, (p-1)//4, p)
def recover_x(y, sign):
    x2 = (y*y-1) * inv(d*y*y+1) % p
    if x2 == 0: return 0
    x = pow(x2, (p+3)//8, p)
    if (x*x - x2) % p != 0: x = x * sqrt_m1 % p
    if (x & 1) != sign: x = p - x
    return x
gy = 4 * inv(5) % p; gx = recover_x(gy, 0); G = (gx, gy, 1, gx*gy % p)
def compress(P):
    zi = inv(P[2]); x = P[0]*zi % p; y = P[1]*zi % p
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")
def expand(secret):
    h = hashlib.sha512(secret).digest(); a = int.from_bytes(h[:32], "little"); a &= (1 << 254) - 8; a |= (1 << 254)
    return a, h[32:]
def public(secret): return compress(mul(expand(secret)[0], G))
def sign(secret, msg):
    a, prefix = expand(secret); A = compress(mul(a, G))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % q
    Rs = compress(mul(r, G))
    h = int.from_bytes(hashlib.sha512(Rs + A + msg).digest(), "little") % q
    return Rs + int.to_bytes((r + h*a) % q, 32, "little")
def pem(pub):
    return "-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(bytes.fromhex("302a300506032b6570032100") + pub).decode() + "\n-----END PUBLIC KEY-----\n"
cmd = sys.argv[1]
if cmd == "keygen":                  # keygen PRIV_HEX_FILE PUB_PEM_FILE
    sec = os.urandom(32); open(sys.argv[2], "w").write(sec.hex() + "\n"); open(sys.argv[3], "w").write(pem(public(sec)))
elif cmd == "sign":                  # sign PRIV_HEX_FILE MSG_FILE SIG_FILE
    sec = bytes.fromhex(open(sys.argv[2]).read().strip()); open(sys.argv[4], "wb").write(sign(sec, open(sys.argv[3], "rb").read()))
elif cmd == "rfc-vector":            # RFC 8032 section 7.1, test 1 (empty message)
    sec = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    print(public(sec).hex()); print(sign(sec, b"").hex())
EOF
ED="python3 $WORK/ed25519_tool.py"
RFC_PUB="d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
RFC_SIG="e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
RFC_OUT="$($ED rfc-vector)"
[ "$(echo "$RFC_OUT" | sed -n 1p)" = "$RFC_PUB" ] && [ "$(echo "$RFC_OUT" | sed -n 2p)" = "$RFC_SIG" ]; check $? "(premise) the test signer reproduces RFC 8032 section 7.1 test vector 1"

# The refusal tests for the REAL system ("as a normal user: refused") are only safe as a normal user: as root the script would not refuse. They are skipped then.
AM_ROOT=0; [ "$(id -u)" != 0 ] || AM_ROOT=1
PYTHON_FOR_TESTS="$(command -v python3)"
export PYTHONDONTWRITEBYTECODE=1                # the tests import the repository's pipeline package: no __pycache__ may appear in it
export MCAP_PYTHON3="$PYTHON_FOR_TESTS"       # the interpreter of the verifier / policy tools in every pkg test below (scripts take it from the environment)
unset MCAP_SYSTEM_ROOT MCAP_PROVISION_DROPPED MCAP_PKG_CONSOLE_USER MCAP_PKG_CONSOLE_HOME MCAP_PIPELINE_DIR MCAP_POLICY_PATH

out_has_plain() {   # like out_has, on the output with the backslashes of printf %q removed (a printed command line is easier to match that way)
    tr -d '\\' < "$OUT" > "$OUT.plain"
    if grep -Eq -- "$1" "$OUT.plain"; then ok "$2"; else bad "$2   (expected /$1/ in the plain output)"; tail -n 8 "$OUT.plain" | cut -c1-200 | sed 's/^/        | /'; fi
}
pkg_env() {   # fresh_env with the package stubs, an own sub-tree for fake system folders (SYSROOT) and a fake CloudStorage-less home
    fresh_env pkg
    SYSROOT="$WORK/env$N/sysroot"
    mkdir -p "$SYSROOT"
}
stubs_clean() {   # no forbidden call (notarytool, stapler, security, ...) happened in this environment
    [ ! -s "$LOGS/forbidden.log" ]
}
# A believable BASE python outside every release (what python -m venv points at with "home ="): interpreter, standard library with lib-dynload and
# site-packages, the Python library; root-owned in real life, here owned by the test user and not writable by anyone else. provision_runtime.sh checks
# it (presence, write bits; as root also the owner), so every release the tests make points at it.
FAKE_BASE="$WORK/fakebase"
make_base() {   # make_base <dir> : a fresh fake base python (755 folders, 644 files, 755 executables)
    rm -rf "$1"
    mkdir -p "$1/bin" "$1/lib/python3.13/lib-dynload" "$1/lib/python3.13/site-packages"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/python3.13"
    ln -s python3.13 "$1/bin/python3"
    : > "$1/lib/python3.13/os.py"; : > "$1/lib/python3.13/lib-dynload/_ssl.so"; : > "$1/lib/python3.13/site-packages/README"
    printf 'the Python library\n' > "$1/Python"
    chmod -R go-w "$1"; chmod 755 "$1/bin/python3.13" "$1/Python"
}
make_base "$FAKE_BASE"
# make_release <dir> <version> [flavor: full|client] : a believable release folder (pipeline, venv with a python, models) + MANIFEST.json (+ signed with $KEY_HEX when given)
make_release() {
    local dir="$1" v="$2" flavor="${3:-full}" key="${4:-}"
    rm -rf "$dir"
    mkdir -p "$dir/pipeline/mcap" "$dir/venv/bin"
    printf '__version__ = "%s"\n' "$v" > "$dir/pipeline/mcap/__init__.py"
    printf '#!/bin/sh\necho "fake python of release %s: $*"\n' "$v" > "$dir/venv/bin/python3.13"
    chmod 755 "$dir/venv/bin/python3.13"
    ln -s python3.13 "$dir/venv/bin/python"
    printf 'home = %s/bin\ninclude-system-site-packages = false\nversion = 3.13.5\n' "${BASE_HOME_FOR_RELEASE:-$FAKE_BASE}" > "$dir/venv/pyvenv.cfg"
    if [ "$flavor" = full ]; then mkdir -p "$dir/models/whisper-large-v3-mlx"; printf 'weights of %s\n' "$v" > "$dir/models/whisper-large-v3-mlx/weights.npz"; fi
    /bin/bash "$ROOT/scripts/provision_runtime.sh" --release-dir "$dir" --flavor "$flavor" --make-manifest > "$WORK/make_release.out" 2>&1 || { echo "make_release failed"; cat "$WORK/make_release.out"; return 1; }
    [ -z "$key" ] || $ED sign "$key" "$dir/MANIFEST.json" "$dir/MANIFEST.sig"
}
$ED keygen "$WORK/release.key.hex" "$WORK/release.pub.pem"
$ED keygen "$WORK/other.key.hex" "$WORK/other.pub.pem"
KEY_HEX="$WORK/release.key.hex"; PUB_PEM="$WORK/release.pub.pem"; OTHER_PEM="$WORK/other.pub.pem"
# a loader check of a policy file with the owner presented as root (what a package or MDM installs), by an independent call of the pipeline's loader
cat > "$WORK/load_policy.py" <<'EOF'
import json, sys
from pathlib import Path
from types import SimpleNamespace
import stat as statmod
sys.path.insert(0, sys.argv[1])
from mcap import policy, __version__
path = Path(sys.argv[2]).resolve()
def st(kind, mode):
    return SimpleNamespace(st_mode=(statmod.S_IFREG if kind == "file" else statmod.S_IFDIR) | mode, st_uid=0, st_size=path.stat().st_size,
                           st_mtime_ns=1, st_ino=1)
def stat_fn(p):
    p = Path(p)
    if p == path: return st("file", 0o644)
    if p in path.parents: return st("directory", 0o755)
    raise FileNotFoundError(str(p))
pol = policy.load_org_policy(path, required_marker=path.parent / "none", stat_fn=stat_fn, current_version=__version__, sleep=lambda s: None)
doc = json.load(open(path, encoding="utf-8"))
print(json.dumps({"state": pol.state, "locked": pol.locked_reason, "profile": pol.profile, "revision": pol.revision, "lanes": pol.lanes,
                  "local_only_default": pol.local_only_default, "local_only_locked": pol.local_only_locked, "approvals": doc.get("approvals", {}),
                  "recording": pol.recording_enabled, "runtime_root": pol.runtime_root, "defaults": pol.defaults, "enforced": pol.enforced}, sort_keys=True))
EOF
policy_state() {   # policy_state <file> -> one JSON line (state valid|invalid, lanes, ...) from the pipeline's own loader
    "$PYTHON_FOR_TESTS" "$WORK/load_policy.py" "$ROOT/pipeline" "$1"
}
json_get() {   # json_get <json text> <python expression over d>
    printf '%s' "$1" | "$PYTHON_FOR_TESTS" -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

# ---------------------------------------------------------------------------------------------------------------
section "company packaging: files, entitlements, distribution, client requirements, company template"
# ---------------------------------------------------------------------------------------------------------------
missing_pkg_file=0
for f in scripts/build_pkg.sh scripts/pkg/preinstall scripts/pkg/postinstall scripts/pkg/distribution.xml.template scripts/pkg/entitlements.plist \
         scripts/provision_runtime.sh scripts/provision_user_config.sh scripts/make_policy.sh scripts/make_hash_lock.sh scripts/migrate_owner_install.sh \
         scripts/mdm/ea_status.sh scripts/mdm/offboard_user.sh pipeline/requirements.client.txt config/config.env.company.template \
         docs/DEPLOY.md docs/OPS_RUNBOOK.md docs/MIGRATION.md; do
    [ -f "$ROOT/$f" ] || { missing_pkg_file=1; echo "      missing $f"; }
done
check $missing_pkg_file "every file of the company packaging package exists"
not_exec=0
for f in scripts/build_pkg.sh scripts/pkg/preinstall scripts/pkg/postinstall scripts/provision_runtime.sh scripts/provision_user_config.sh scripts/make_policy.sh \
         scripts/make_hash_lock.sh scripts/migrate_owner_install.sh scripts/mdm/ea_status.sh scripts/mdm/offboard_user.sh; do
    [ -x "$ROOT/$f" ] || { not_exec=1; echo "      not executable: $f"; }
done
check $not_exec "the scripts and the package scripts are executable (the Installer runs preinstall and postinstall directly)"
for f in scripts/pkg/preinstall scripts/pkg/postinstall; do
    [ "$(head -n 1 "$ROOT/$f")" = "#!/bin/bash" ]; check $? "$f starts with #!/bin/bash (the bash 3.2 of macOS, no env lookup)"
done
plutil -lint "$ROOT/scripts/pkg/entitlements.plist" >/dev/null 2>&1; check $? "entitlements.plist is a valid plist"
xmllint --noout "$ROOT/scripts/pkg/entitlements.plist" 2>/dev/null; check $? "entitlements.plist is well-formed XML (no double hyphen in a comment)"
ENT="$(plutil -convert json -o - "$ROOT/scripts/pkg/entitlements.plist" 2>/dev/null)"
[ "$(json_get "$ENT" 'sorted(d)')" = "['com.apple.security.automation.apple-events', 'com.apple.security.device.audio-input']" ]; check $? "the entitlements are exactly audio-input and apple-events (nothing that weakens the hardened runtime)"
grep -Eq 'allow-jit|allow-unsigned-executable-memory|disable-library-validation|get-task-allow' <(plutil -convert xml1 -o - "$ROOT/scripts/pkg/entitlements.plist"); [ $? -ne 0 ]; check $? "the entitlements contain no JIT, unsigned-memory, library-validation or debugger exception"
# the distribution: filled in like build_pkg.sh does, then checked
sed -e "s/@PKG_ID@/$DEFAULT_ID.pkg/g" -e "s/@ORGANIZATION@/${DEFAULT_ID%.*}/g" -e 's/@VERSION@/0.2.0/g' -e 's/@COMPONENT_PKG@/c.pkg/g' -e "s/@APP_NAME@/$DEFAULT_NAME/g" "$ROOT/scripts/pkg/distribution.xml.template" > "$WORK/dist.xml"
xmllint --noout "$WORK/dist.xml" 2>/dev/null; check $? "distribution.xml.template is well-formed once filled in"
grep -q 'hostArchitectures="arm64"' "$WORK/dist.xml"; check $? "distribution: hostArchitectures=arm64 (an Intel Mac is refused before anything is copied)"
[ "$(grep -c '<os-version min="14.4"/>' "$WORK/dist.xml")" = 2 ]; check $? "distribution: macOS 14.4 guard in allowed-os-versions AND in volume-check"
! grep -Eq '@[A-Z_]+@' "$WORK/dist.xml"; check $? "distribution: every placeholder of the template is one that build_pkg.sh fills"
# requirements.client.txt: exactly numpy + truststore at the versions of the lock
cat > "$WORK/pins.py" <<'EOF'
import re, sys
def pins(path):
    out = {}
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)$", line)
        if m: out[m.group(1).lower()] = m.group(2)
    return out
client, lock = pins(sys.argv[1]), pins(sys.argv[2])
bad = []
if sorted(client) != ["numpy", "truststore"]: bad.append("client pins are %s, expected numpy and truststore" % sorted(client))
for n, v in client.items():
    if lock.get(n) != v: bad.append("%s: client %s, lock %s" % (n, v, lock.get(n)))
for n in ("mlx", "mlx-whisper", "numba", "llvmlite", "tiktoken", "scipy", "requests", "huggingface-hub", "httpx2", "hf-xet"):
    if n in client: bad.append("%s must not be in the client file" % n)
print("\n".join(bad)); sys.exit(1 if bad else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/pins.py" "$ROOT/pipeline/requirements.client.txt" "$ROOT/pipeline/requirements.lock.txt" > "$WORK/pins.out" 2>&1; check $? "requirements.client.txt = numpy + truststore at the versions of requirements.lock.txt, none of the engine or HTTP packages"
[ -z "$(cat "$WORK/pins.out")" ] || sed 's/^/        > /' "$WORK/pins.out"
# the company template: no string of the owner, only keys the code knows, only placeholders the provisioning script fills
TPL="$ROOT/config/config.env.company.template"
! grep -Eq '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' "$TPL"; check $? "config.env.company.template contains no concrete mail address (the placeholders are filled per user)"
! grep -q 'GoogleDrive-' "$TPL"; check $? "... and no Drive mount name (the mount is found per user)"
cat > "$WORK/tpl_keys.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
tpl = open(os.path.join(root, "config/config.env.company.template"), encoding="utf-8").read()
config_py = open(os.path.join(root, "pipeline/mcap/config.py"), encoding="utf-8").read()
swift = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(root, "app/Sources/*.swift")))
keys = re.findall(r"^([A-Z][A-Z0-9_]+)=", tpl, re.M)
bad = ["%s is set by the template but neither config.py nor the app parses it" % k for k in keys if ('"%s"' % k) not in config_py and ('"%s"' % k) not in swift]
holders = set(re.findall(r"@([A-Z_]+)@", tpl))
if holders != {"ARCHIVE_DIR", "SELF_NAME", "CLAUDE_AUTH", "RELEASE_ROOT"}: bad.append("placeholders are %s" % sorted(holders))
for k in ("LOG_RETENTION_DAYS", "APP_LOG_MAX_MB", "LOG_CONTENT", "ASR_ALLOW_DOWNLOAD", "MIC_MUTE_GATE", "ASR_ENGINE", "LOCAL_ONLY_DEFAULT", "NOTIFY_RECORDING",
          "CALL_DETECT", "CALL_GENERIC_SECONDS", "EXTRA_MEETING_APPS", "CALL_BROWSER_URLS"):
    if k in keys: bad.append("%s is set by the template: that would hide the organisation's default or enforced value" % k)
print("\n".join(bad)); sys.exit(1 if bad else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/tpl_keys.py" "$ROOT" > "$WORK/tpl_keys.out" 2>&1; check $? "the template sets only keys the code parses, fills only the four placeholders, and leaves the organisation's defaults and enforced keys alone"
[ -z "$(cat "$WORK/tpl_keys.out")" ] || sed 's/^/        > /' "$WORK/tpl_keys.out"

# ---------------------------------------------------------------------------------------------------------------
section "setup_python.sh: --client-only, --with-cloud, --hash-lock, --venv-dir, --copies (plans only, nothing is installed)"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
runx /bin/bash scripts/setup_python.sh --dry-run --client-only
rc_is 0 "setup_python.sh --dry-run --client-only"
out_has '2 pinned packages from pipeline/requirements.client.txt \(numpy, truststore\)' "the client-only plan names numpy and truststore only"
out_has 'pip install --no-deps -r .*requirements.client.txt' "it installs the client file with --no-deps"
out_lacks 'mlx|numba|llvmlite|tiktoken|scipy|requests|torch|qwen' "the client-only plan names no engine, scientific or HTTP package"
out_has 'no local model' "it says there is no local model"
out_has 'would verify in .*: import numpy and truststore' "it verifies numpy and truststore, not an engine"
out_lacks 'import mlx_whisper' "... never mlx_whisper"
home_is_empty; check $? "the client-only dry run created nothing"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --pre-download-model
rc_not 0 "--client-only with --pre-download-model is refused (no local engine, no model)"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --with-qwen-bench
rc_not 0 "--client-only with --with-qwen-bench is refused"
runx /bin/bash scripts/setup_python.sh --dry-run --with-cloud
rc_is 0 "setup_python.sh --dry-run --with-cloud (full lock)"
out_has 'cloud +: truststore .* is part of the lock' "--with-cloud plan: truststore is part of the lock, nothing else is added"
out_has 'would verify in .*: import truststore' "... and truststore is imported after the install"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --with-cloud
out_has 'cloud +: truststore .* is part of --client-only' "--client-only --with-cloud plan: truststore is part of --client-only"
out_has 'relay needs no package for TLS' "... and the relay needs no package for TLS (pinned private CA)"
# a hash lock: the plan shows --require-hashes --no-deps, and a lock for another set of packages is refused
printf 'numpy==2.5.3 \\\n    --hash=sha256:%s\ntruststore==0.10.4 \\\n    --hash=sha256:%s\n' "$(printf 'a%.0s' $(seq 64))" "$(printf 'b%.0s' $(seq 64))" > "$WORK/client.hashes.txt"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --hash-lock "$WORK/client.hashes.txt" --venv-dir "$WORK/relstage/0.2.0/venv" --copies
rc_is 0 "setup_python.sh --client-only --hash-lock --venv-dir --copies (dry run)"
out_has 'pip install --require-hashes --no-deps -r' "the hash-locked install is pip install --require-hashes --no-deps -r <file>"
out_has 'hash lock +:.*client.hashes.txt: pip install --require-hashes --no-deps' "the plan names the hash lock"
out_has 'venv --copies .*relstage/0.2.0/venv' "the venv is made with --copies in the release staging folder"
printf 'numpy==2.5.2 \\\n    --hash=sha256:%s\n' "$(printf 'a%.0s' $(seq 64))" > "$WORK/wrong.hashes.txt"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --hash-lock "$WORK/wrong.hashes.txt"
rc_not 0 "a hash lock that does not match the requirement file is refused"
out_has 'numpy: the hash lock has 2.5.2, the requirement file 2.5.3' "... naming the difference"
out_has 'truststore==0.10.4 is not in the hash lock' "... and the pin that is missing"
runx /bin/bash scripts/setup_python.sh --dry-run --venv-dir "$WORK/relstage/0.2.0/notvenv"
rc_not 0 "--venv-dir must end in /venv (only such a folder is ever deleted by --recreate)"
home_is_empty; check $? "none of the dry runs created anything"

# ---------------------------------------------------------------------------------------------------------------
section "make_hash_lock.sh: plan (--require-hashes --no-deps), and the hash lock made from a canned index answer"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
runx /bin/bash scripts/make_hash_lock.sh
rc_is 0 "make_hash_lock.sh (plan)"
out_has 'PLAN \(nothing is fetched, nothing is written\)' "the default is a plan: nothing is fetched"
out_has 'requirements.lock.txt \(29 pins\)' "the plan lists the full lock with its pin count"
out_has 'requirements.client.txt \(2 pins\)' "... and the client file"
out_has 'pip install --require-hashes --no-deps -r' "the plan names the install command: --require-hashes --no-deps"
out_has 'https://pypi.org/pypi/<name>/<version>/json.*no other host' "the only source named is the package index (pypi.org), no other host"
out_has 'wheels only' "wheels only, never a source distribution"
home_is_empty; check $? "the plan wrote nothing"
[ ! -e "$ROOT/build/hash-locks" ]; check $? "... and no build/hash-locks folder appeared in the repository"
cat > "$WORK/make_index.py" <<'EOF'
import hashlib, json, sys
out = sys.argv[1]
def h(s): return hashlib.sha256(s.encode()).hexdigest()
def f(fn, kind="bdist_wheel", yanked=False): return {"filename": fn, "packagetype": kind, "yanked": yanked, "digests": {"sha256": h(fn)}}
json.dump({"urls": [f("numpy-2.5.3-cp313-cp313-macosx_14_0_arm64.whl"), f("numpy-2.5.3-cp313-cp313-macosx_11_0_arm64.whl"),
                    f("numpy-2.5.3-cp313-cp313-macosx_14_0_x86_64.whl"), f("numpy-2.5.3-cp313-cp313-macosx_15_0_arm64.whl"),
                    f("numpy-2.5.3-cp312-cp312-macosx_14_0_arm64.whl"), f("numpy-2.5.3-cp313-cp313-manylinux_2_28_x86_64.whl"),
                    f("numpy-2.5.3-cp313-cp313t-macosx_14_0_arm64.whl"), f("numpy-2.5.3.tar.gz", "sdist"),
                    f("numpy-2.5.3-cp313-cp313-macosx_13_0_arm64.whl", yanked=True)]}, open(out + "/numpy-2.5.3.json", "w"))
json.dump({"urls": [f("truststore-0.10.4-py3-none-any.whl"), f("truststore-0.10.4.tar.gz", "sdist")]}, open(out + "/truststore-0.10.4.json", "w"))
EOF
mkdir -p "$WORK/index"; "$PYTHON_FOR_TESTS" "$WORK/make_index.py" "$WORK/index"
runx /bin/bash scripts/make_hash_lock.sh --apply --input "$ROOT/pipeline/requirements.client.txt" --index-dir "$WORK/index" --out-dir "$WORK/locks"
rc_is 0 "make_hash_lock.sh --apply --index-dir <canned answers> (no network)"
LOCK="$WORK/locks/requirements.client.hashes.txt"
[ -f "$LOCK" ]; check $? "the hash lock was written"
[ "$(grep -c -- '--hash=sha256:' "$LOCK")" = 3 ]; check $? "numpy has the hashes of the macOS 14 and macOS 11 arm64 wheels, truststore the one of its pure python wheel (3 in all)"
grep -q "$(printf 'numpy-2.5.3-cp313-cp313-macosx_14_0_arm64.whl' | shasum -a 256 | awk '{print $1}')" "$LOCK" && grep -q "$(printf 'numpy-2.5.3-cp313-cp313-macosx_11_0_arm64.whl' | shasum -a 256 | awk '{print $1}')" "$LOCK"; check $? "the accepted wheels' sha256 are in the file"
wrongly_in=0
for rejected in numpy-2.5.3-cp313-cp313-macosx_14_0_x86_64.whl numpy-2.5.3-cp313-cp313-macosx_15_0_arm64.whl numpy-2.5.3-cp312-cp312-macosx_14_0_arm64.whl \
                numpy-2.5.3-cp313-cp313-manylinux_2_28_x86_64.whl numpy-2.5.3-cp313-cp313t-macosx_14_0_arm64.whl numpy-2.5.3.tar.gz numpy-2.5.3-cp313-cp313-macosx_13_0_arm64.whl; do
    if grep -q "$(printf '%s' "$rejected" | shasum -a 256 | awk '{print $1}')" "$LOCK"; then wrongly_in=1; echo "      make_hash_lock accepted $rejected"; fi
done
check $wrongly_in "x86_64-only, newer-macOS, other-python, free-threaded, Linux, yanked and source files are NOT in the lock"
grep -q '^numpy==2.5.3 \\$' "$LOCK" && grep -q '^truststore==0.10.4 \\$' "$LOCK"; check $? "the lock has the 'name==version \\' block format of pip --require-hashes"
runx /bin/bash scripts/setup_python.sh --dry-run --client-only --hash-lock "$LOCK"
rc_is 0 "setup_python.sh --client-only accepts the lock that make_hash_lock.sh made"
out_has 'pip install --require-hashes --no-deps -r .*requirements.client.hashes.txt' "... and installs it with --require-hashes --no-deps"
# a pin without any acceptable wheel stops the run and writes nothing
printf '{"urls": [{"filename": "truststore-0.10.4.tar.gz", "packagetype": "sdist", "digests": {"sha256": "%s"}}]}\n' "$(printf 'c%.0s' $(seq 64))" > "$WORK/index/truststore-0.10.4.json"
runx /bin/bash scripts/make_hash_lock.sh --apply --input "$ROOT/pipeline/requirements.client.txt" --index-dir "$WORK/index" --out-dir "$WORK/locks2"
rc_not 0 "a pin with no acceptable wheel (only a source distribution) stops the run"
out_has 'truststore==0.10.4: no wheel this venv could install' "... naming the pin"
[ ! -e "$WORK/locks2/requirements.client.hashes.txt" ]; check $? "... and no lock file was written for a partly covered set"

# ---------------------------------------------------------------------------------------------------------------
section "make_policy.sh: JSON that the pipeline's load_org_policy accepts; a lane is never opened without an approval reference"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
runx /bin/bash scripts/make_policy.sh --out "$WORK/baseline.json" --issued 2026-10-16T09:00:00+09:00 --contact "IT 헬프데스크 #it-help"
rc_is 0 "make_policy.sh (baseline)"
out_has 'valid: profile company, revision 1' "it reports the loader's verdict: valid, company, revision 1"
ST="$(policy_state "$WORK/baseline.json")"
[ "$(json_get "$ST" 'd["state"]')" = valid ]; check $? "an INDEPENDENT call of policy.load_org_policy accepts the baseline (state valid)"
[ "$(json_get "$ST" 'sorted(d["lanes"].items())')" = "[('asr_cloud', 'deny'), ('asr_remote', 'deny'), ('calendar', 'deny'), ('drive', 'deny'), ('llm', 'deny')]" ]; check $? "baseline: every external lane is deny"
[ "$(json_get "$ST" 'd["local_only_default"]')" = True ] && [ "$(json_get "$ST" 'd["local_only_locked"]')" = False ]; check $? "baseline: local_only.default true, not locked"
[ "$(json_get "$ST" 'd["approvals"]')" = "{}" ]; check $? "baseline: no approval, nothing is opened"
[ "$(json_get "$ST" 'sorted(d["enforced"].items())')" = "[('ASR_ALLOW_DOWNLOAD', '0'), ('LOG_CONTENT', '0'), ('MIC_MUTE_GATE', 'on'), ('NOTIFY_RECORDING', '1')]" ]; check $? "baseline: the company enforced values (LOG_CONTENT 0, ASR_ALLOW_DOWNLOAD 0, MIC_MUTE_GATE on, NOTIFY_RECORDING 1)"
[ "$(json_get "$ST" 'd["runtime_root"]')" = "/Library/Application Support/MeetingCapture/releases" ]; check $? "baseline: runtime.root is the root-owned releases folder"
[ "$(json_get "$ST" 'd["defaults"]["LOG_RETENTION_DAYS"] + "/" + d["defaults"]["APP_LOG_MAX_MB"]')" = "30/5" ]; check $? "baseline: the defaults LOG_RETENTION_DAYS 30 and APP_LOG_MAX_MB 5 (5 files of 5 MB)"
grep -q '"ASR_MODEL": "/Library/Application Support/MeetingCapture/releases/current/models/whisper-large-v3-mlx"' "$WORK/baseline.json"; check $? "baseline: ASR_MODEL points into the release (the model ships read-only, no download)"
grep -q 'IT 헬프데스크 #it-help' "$WORK/baseline.json"; check $? "baseline: the support contact (Korean text) survives"
[ "$(stat -f %Lp "$WORK/baseline.json")" = 644 ]; check $? "--out writes mode 0644"
runx /bin/bash scripts/make_policy.sh --check "$WORK/baseline.json"
rc_is 0 "make_policy.sh --check on a valid file"
runx /bin/bash scripts/make_policy.sh --check "$ROOT/config/policy.example.json"
rc_is 0 "make_policy.sh --check accepts config/policy.example.json"
printf '{"schema":1,"profile":"company","revision":1,"typo":1}\n' > "$WORK/typo.json"
runx /bin/bash scripts/make_policy.sh --check "$WORK/typo.json"
rc_is 1 "--check on a policy with an unknown key: locked, exit 1"
out_has 'locked: unknown-key' "... with the loader's reason"
# opening a lane: with a reference it works and is recorded, without one it is refused
runx /bin/bash scripts/make_policy.sh --revision 2 --allow drive=TICKET-1234 --out "$WORK/drive.json"
rc_is 0 "--allow drive=TICKET-1234"
ST="$(policy_state "$WORK/drive.json")"
[ "$(json_get "$ST" 'd["lanes"]["drive"]')" = allow ] && [ "$(json_get "$ST" 'd["approvals"]["drive"]')" = "TICKET-1234" ] && [ "$(json_get "$ST" 'd["revision"]')" = 2 ]; check $? "drive is allow with its approval reference, revision 2"
for lane in drive calendar asr_cloud llm; do
    runx /bin/bash scripts/make_policy.sh --allow "$lane" --claude-team-id ABCDE12345 --out "$WORK/refused-$lane.json"
    rc_is 2 "--allow $lane without an approval reference is refused (exit 2)"
    [ ! -e "$WORK/refused-$lane.json" ]; check $? "... and no policy file was written"
done
out_has 'needs an approval reference' "the refusal says why"
runx /bin/bash scripts/make_policy.sh --allow llm=TICKET-9 --out "$WORK/refused-pin.json"
rc_is 2 "--allow llm=<ref> without a signature pin of the claude CLI is refused"
out_has 'claude-team-id or --claude-sha256' "... naming the pin options"
runx /bin/bash scripts/make_policy.sh --allow llm=TICKET-9 --claude-team-id ABCDE12345 --out "$WORK/llm.json"
rc_is 0 "--allow llm=<ref> with --claude-team-id"
[ "$(json_get "$(policy_state "$WORK/llm.json")" 'd["lanes"]["llm"]')" = allow ]; check $? "llm is allow in the loader's view (reference and pin both present)"
runx /bin/bash scripts/make_policy.sh --allow asr_remote --host asr.example.internal --out "$WORK/relay.json"
rc_is 0 "--allow asr_remote needs no approval reference"
grep -q '"remote"' "$WORK/relay.json"; check $? "... and adds the engine remote to asr.allowed_engines"
runx /bin/bash scripts/make_policy.sh --allow bogus=1
rc_is 2 "an unknown lane is refused"
runx /bin/bash scripts/make_policy.sh --default ARCHIVE_DIR=/x --out "$WORK/locked.json"
rc_is 1 "a policy the loader would lock (ARCHIVE_DIR is never settable by a layer) is not written"
out_has 'would be LOCKED by the loader' "... and the reason comes from the loader"
[ ! -e "$WORK/locked.json" ]; check $? "... no file"
runx /bin/bash scripts/make_policy.sh --profile personal --allow llm
rc_is 2 "a personal policy takes no --allow (it allows what it does not restrict)"
runx /bin/bash scripts/make_policy.sh --profile personal --recording-off --out "$WORK/personal.json"
rc_is 0 "a personal policy with the kill switch"
[ "$(json_get "$(policy_state "$WORK/personal.json")" 'd["recording"]')" = False ]; check $? "... loads, recording disabled"
runx /bin/bash scripts/make_policy.sh --local-only-locked --recording-off --out "$WORK/locked-flag.json"
[ "$(json_get "$(policy_state "$WORK/locked-flag.json")" 'str(d["local_only_locked"]) + str(d["recording"])')" = "TrueFalse" ]; check $? "--local-only-locked and --recording-off reach the loader"
# the CLIENT-ONLY flavour (no mlx, no local model): it must be able to reach the relay with what the tooling ships. The pipeline's own decision table
# is asked, with the policy's defaults layered onto a Config the way load_config does it.
cat > "$WORK/decide.py" <<'EOF'
import json, sys, types
from datetime import datetime, timezone
from pathlib import Path
import stat as statmod
sys.path.insert(0, sys.argv[1])
from mcap import config, policy, __version__
path = Path(sys.argv[2]).resolve()
def st(kind, mode):
    return types.SimpleNamespace(st_mode=(statmod.S_IFREG if kind == "file" else statmod.S_IFDIR) | mode, st_uid=0, st_size=path.stat().st_size, st_mtime_ns=1, st_ino=1)
def stat_fn(p):
    p = Path(p)
    if p == path: return st("file", 0o644)
    if p in path.parents: return st("directory", 0o755)
    raise FileNotFoundError(str(p))
pol = policy.load_org_policy(path, required_marker=path.parent / "none", stat_fn=stat_fn, current_version=__version__, sleep=lambda s: None)
values = config._apply_policy_layers({}, pol)
cfg = config.Config()
for key, (field, caster) in config._KEYS.items():
    if key in values and values[key] != "":
        setattr(cfg, field, caster(values[key]))
d = policy.decide_asr(cfg, pol, policy.LocalOnly(False, "session"), policy.ConsentSet(machine="m"), types.SimpleNamespace(capable=True),
                      now=datetime(2026, 10, 16, tzinfo=timezone.utc))
print(json.dumps({"state": pol.state, "engine_setting": cfg.asr_engine, "url": str(cfg.asr_remote_url), "ca": str(cfg.asr_remote_ca_file),
                  "primary": d.primary, "reason": d.reason, "hosts": d.engine_hosts}, sort_keys=True))
EOF
decide_for() { "$PYTHON_FOR_TESTS" "$WORK/decide.py" "$ROOT/pipeline" "$1"; }
HEX_A="$(printf 'a%.0s' $(seq 1 64))"; HEX_B="$(printf 'b%.0s' $(seq 1 64))"
CONSENT="engine=remote,host=asr.example.internal,ca_sha256=$HEX_A,attest=$HEX_B,use=both,expires=2027-10-14"
runx /bin/bash scripts/make_policy.sh --client-only --out "$WORK/client-base.json"
[ "$(json_get "$(cat "$WORK/client-base.json")" 'd["defaults"]["ASR_ENGINE"]')" = remote ] && ! grep -q ASR_MODEL "$WORK/client-base.json"; check $? "--client-only: defaults.ASR_ENGINE is remote (not whisper) and there is no ASR_MODEL"
runx /bin/bash scripts/make_policy.sh --out "$WORK/full-base.json"
[ "$(json_get "$(cat "$WORK/full-base.json")" 'd["defaults"]["ASR_ENGINE"]')" = whisper ]; check $? "the full flavour keeps ASR_ENGINE whisper"
runx /bin/bash scripts/make_policy.sh --revision 3 --client-only --allow asr_remote --host asr.example.internal --org-consent "$CONSENT" \
    --default ASR_REMOTE_URL=https://asr.example.internal --default "ASR_REMOTE_CA_FILE=/Library/Application Support/MeetingCapture/asr-ca.pem" --out "$WORK/client-relay.json"
rc_is 0 "make_policy.sh --client-only --allow asr_remote --host ... --org-consent ... --default ASR_REMOTE_URL=... --default ASR_REMOTE_CA_FILE=..."
DEC="$(decide_for "$WORK/client-relay.json")"
[ "$(json_get "$DEC" 'd["state"]')" = valid ] && [ "$(json_get "$DEC" 'd["engine_setting"]')" = remote ] && [ "$(json_get "$DEC" 'd["url"]')" = "https://asr.example.internal" ] \
  && [ "$(json_get "$DEC" 'd["ca"]')" = "/Library/Application Support/MeetingCapture/asr-ca.pem" ]; check $? "the pipeline reads ASR_ENGINE=remote, the relay URL and the CA file from the policy's defaults"
[ "$(json_get "$DEC" 'd["primary"]')" = remote ] && [ "$(json_get "$DEC" 'd["reason"]')" = ok ] && [ "$(json_get "$DEC" 'd["hosts"]')" = "{'remote': 'asr.example.internal'}" ]; check $? "the decision table SELECTS the remote engine for that host: a client-only Mac can reach the relay with this policy"
runx /bin/bash scripts/make_policy.sh --revision 3 --client-only --allow asr_remote --host asr.example.internal --org-consent "$CONSENT" --out "$WORK/client-no-url.json"
DEC="$(decide_for "$WORK/client-no-url.json")"
[ "$(json_get "$DEC" 'd["primary"]')" = whisper ] && [ "$(json_get "$DEC" 'd["reason"]')" = not-configured ]; check $? "without ASR_REMOTE_URL the relay stays excluded (not-configured): the docs must name the --default options (docs/DEPLOY.md 7)"
runx /bin/bash scripts/make_policy.sh --client-only --out "$WORK/client-closed.json"
DEC="$(decide_for "$WORK/client-closed.json")"
[ "$(json_get "$DEC" 'd["hosts"]')" = "{}" ]; check $? "the client-only baseline (every lane deny) sends nothing anywhere, whatever ASR_ENGINE says"
runx /bin/bash scripts/make_policy.sh --help
out_has 'ASR_REMOTE_URL=https://asr.example.internal --default ASR_REMOTE_CA_FILE=' "the help of make_policy.sh shows the relay URL and the CA file defaults that --client-only needs"
runx /bin/bash scripts/make_policy.sh --revision 0
rc_is 2 "revision 0 is refused"
home_is_empty; check $? "make_policy.sh wrote nothing into HOME"

# ---------------------------------------------------------------------------------------------------------------
section "provision_runtime.sh: manifest, signature, hashes (a release that does not verify is never activated)"
# ---------------------------------------------------------------------------------------------------------------
pkg_env
PR="scripts/provision_runtime.sh"
REL="$SYSROOT/stage/0.2.0"
make_release "$REL" 0.2.0 full
MJ="$REL/MANIFEST.json"
[ -f "$MJ" ] && [ ! -e "$REL/MANIFEST.sig" ]; check $? "--make-manifest wrote MANIFEST.json and no signature"
cat > "$WORK/manifest_check.py" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
ok = (d["schema"] == 1 and d["version"] == "0.2.0" and d["flavor"] == sys.argv[2]
      and set(d["files"]) >= {"pipeline/mcap/__init__.py", "venv/bin/python3.13", "venv/pyvenv.cfg"}
      and d["links"] == {"venv/bin/python": "python3.13"}
      and all(len(v["sha256"]) == 64 and v["mode"] in ("644", "755") for v in d["files"].values())
      and "MANIFEST.json" not in d["files"] and "MANIFEST.sig" not in d["files"])
sys.exit(0 if ok else 1)
EOF
"$PYTHON_FOR_TESTS" "$WORK/manifest_check.py" "$MJ" full; check $? "MANIFEST.json: schema 1, version, flavor full, every file with sha256 and mode, the python link, no entry for itself or the signature"
runx /bin/bash "$PR" --release-dir "$REL" --make-manifest
rc_not 0 "--make-manifest does not replace an existing manifest without --force"
runx /bin/bash "$PR" --release-dir "$REL" --make-manifest --force
rc_is 0 "--make-manifest --force"
out_has "openssl pkeyutl -sign -inkey <release-signing.key> -rawin -in '.*MANIFEST.json' -out '.*MANIFEST.sig'" "it prints the OFFLINE signing command (OpenSSL 3, -rawin) for the owner"
out_has 'LibreSSL and cannot sign Ed25519' "... and says why the stock /usr/bin/openssl does not do"
$ED sign "$KEY_HEX" "$MJ" "$REL/MANIFEST.sig"
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$PUB_PEM"
rc_is 0 "dry run of a signed release"
out_has 'DRY RUN: nothing is changed' "the default mode is a dry run"
out_has 'signature OK, verified 4 files and 1 links' "the signature and every hash verified"
out_has 'switch .*/stage/current: \(none\) -> 0.2.0' "it says what --apply would do (switch current)"
[ ! -e "$SYSROOT/stage/current" ]; check $? "the dry run changed nothing"
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$PUB_PEM" --verify-only
rc_is 0 "--verify-only"
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$PUB_PEM" --verify-only --flavor client
rc_not 0 "a full release is refused when --flavor client was asked for"
out_has 'is a full release but --flavor client' "... saying so"
# the signature is the same bytes whatever the verifier: OpenSSL 3 (when there is one) and the built-in one agree both ways
OSSL3=""
for cand in /opt/homebrew/bin/openssl /usr/local/bin/openssl "$(command -v openssl 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && "$cand" version 2>/dev/null | grep -q '^OpenSSL [3-9]' && { OSSL3="$cand"; break; }
done
if [ -n "$OSSL3" ]; then
    runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$PUB_PEM" --verify-only --openssl "$OSSL3"
    rc_is 0 "a signature made by the independent signer also verifies with $($OSSL3 version | awk '{print $1, $2}') (--openssl)"
    "$OSSL3" genpkey -algorithm ed25519 -out "$WORK/ossl.key" 2>/dev/null && "$OSSL3" pkey -in "$WORK/ossl.key" -pubout -out "$WORK/ossl.pub" 2>/dev/null
    cp "$REL/MANIFEST.sig" "$WORK/keep.sig"
    "$OSSL3" pkeyutl -sign -inkey "$WORK/ossl.key" -rawin -in "$MJ" -out "$REL/MANIFEST.sig" 2>/dev/null
    runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$WORK/ossl.pub" --verify-only
    rc_is 0 "a signature made by OpenSSL 3 verifies with the built-in verifier (RFC 8032 code in provision_runtime.sh)"
    cp "$WORK/keep.sig" "$REL/MANIFEST.sig"
else
    echo "  skip the OpenSSL cross-check (no OpenSSL 3 on this Mac)"
fi
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$PUB_PEM" --verify-only --openssl /usr/bin/openssl
rc_not 0 "--openssl with the LibreSSL of macOS is refused (it cannot verify Ed25519)"
out_has 'not OpenSSL 3 or newer' "... with the reason"
# --- refusals: each one on its own copy of the release; the message names what is wrong; nothing is activated
tamper() {   # tamper <name> <function that damages $T>: a signed copy of the release, damaged, verified
    T="$SYSROOT/tamper-$1/0.2.0"
    rm -rf "$SYSROOT/tamper-$1"; mkdir -p "$SYSROOT/tamper-$1"; cp -R "$REL" "$T"
}
tamper hash;   echo tampered >> "$T/pipeline/mcap/__init__.py"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a file whose hash differs from the signed manifest is refused"
out_has 'hash differs: pipeline/mcap/__init__.py' "... naming the file"
tamper manifest; sed -i '' 's/"flavor": "full"/"flavor": "client"/' "$T/MANIFEST.json"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a manifest changed after it was signed is refused"
out_has 'the signature does not match MANIFEST.json' "... as a signature mismatch (not as a hash problem)"
tamper wrongkey
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$OTHER_PEM" --verify-only
rc_not 0 "a signature checked with the wrong public key is refused"
out_has 'the signature does not match MANIFEST.json' "... as a signature mismatch"
tamper nosig; rm -f "$T/MANIFEST.sig"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a release without MANIFEST.sig is refused"
out_has 'never activated' "... and the message says an unsigned release is never activated"
tamper nomanifest; rm -f "$T/MANIFEST.json"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a release without MANIFEST.json is refused"
tamper badsig; head -c 40 /dev/urandom > "$T/MANIFEST.sig"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a signature that is not 64 bytes is refused"
tamper flipsig; "$PYTHON_FOR_TESTS" -c "import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[5]^=1; open(p,'wb').write(bytes(b))" "$T/MANIFEST.sig"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "one flipped bit of the signature is refused"
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$WORK/does-not-exist.pem" --verify-only
rc_not 0 "a missing public key is refused"
printf 'not a key\n' > "$WORK/garbage.pem"
runx /bin/bash "$PR" --release-dir "$REL" --pubkey "$WORK/garbage.pem" --verify-only
rc_not 0 "a public key file that is no Ed25519 key is refused"
tamper extra; echo planted > "$T/pipeline/mcap/evil.py"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "an extra file that the manifest does not list is refused"
out_has 'not in the manifest: pipeline/mcap/evil.py' "... naming it"
tamper missing; rm -f "$T/pipeline/mcap/__init__.py"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a file that the manifest lists but the release lacks is refused"
out_has 'missing: pipeline/mcap/__init__.py' "... naming it"
tamper link; ln -s /etc/passwd "$T/escape"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a symbolic link the manifest does not list, pointing out of the release, is refused"
out_has 'a link leaves the release: escape' "... as a link that leaves the release"
tamper relink; rm "$T/venv/bin/python"; ln -s /usr/bin/python3 "$T/venv/bin/python"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "the python link re-pointed to a system python is refused"
out_has 'link target differs: venv/bin/python' "... as a changed link"
tamper fifo; mkfifo "$T/pipeline/pipe"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a special file (a pipe) in the release is refused"
out_has 'special file' "... named as such"
tamper gw; chmod 664 "$T/pipeline/mcap/__init__.py"
runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only
rc_not 0 "a group-writable file in the release is refused"
out_has 'writable by group or others' "... as writable"
tamper dirname
runx /bin/bash "$PR" --release-dir "$SYSROOT/tamper-dirname/0.3.0" --src "$T" --pubkey "$PUB_PEM"
rc_not 0 "a release folder named 0.3.0 for a manifest of 0.2.0 is refused"
out_has 'is for version .0.2.0. but the directory is 0.3.0' "... naming both versions"
runx /bin/bash "$PR" --release-dir "$SYSROOT/stage/latest" --pubkey "$PUB_PEM"
rc_not 0 "a release folder whose name is not a version is refused"
# --- the BASE python (outside the release, never carried by the package): presence, write bits, the whole prefix; checked also as a normal user (the build
#     host, --verify-only, build_pkg.sh). The python.org installer leaves the framework root:admin and mode 775: that is what this must catch.
base_release() {   # base_release <name>: a signed release whose venv points at a fresh base python of its own; sets BASE and T
    BASE="$SYSROOT/base-$1"; make_base "$BASE"
    BASE_HOME_FOR_RELEASE="$BASE" make_release "$SYSROOT/br-$1/0.2.0" 0.2.0 full "$KEY_HEX"
    T="$SYSROOT/br-$1/0.2.0"
}
verify_t() { runx /bin/bash "$PR" --release-dir "$T" --pubkey "$PUB_PEM" --verify-only; }
base_release ok
verify_t
rc_is 0 "a release whose base python is present and not writable by others verifies (as a normal user)"
out_has 'base interpreter: .*/base-ok/bin, not writable by group or others, owner not checked: this is not root' "... and the result names the base python and what was (not) checked"
base_release gwbin; chmod 775 "$BASE/bin"
verify_t
rc_not 0 "a base python whose bin folder is group-writable (the python.org framework as installed) is refused EVEN AS A NORMAL USER"
out_has "base interpreter is not trustworthy: .*/base-gwbin/bin/python3.13|base python is not trustworthy" "... naming what is wrong"
out_has 'docs/DEPLOY.md 3.1' "... and where the way out is described"
out_has 'chown -R root:wheel and chmod -R go-w' "... with the commands that make it right"
base_release gwprefix; chmod 775 "$BASE"
verify_t
rc_not 0 "a group-writable prefix folder of the base python is refused"
out_has 'base-gwprefix is writable by group or others' "... naming the folder"
base_release gwlib; chmod 664 "$BASE/lib/python3.13/os.py"
verify_t
rc_not 0 "ONE group-writable file of the base python's standard library is refused (what python imports, not only the folder of the interpreter)"
out_has 'path\(s\) below .*/base-gwlib are writable by group or others' "... with a count and examples"
base_release gwdyn; chmod 775 "$BASE/lib/python3.13/lib-dynload"
verify_t
rc_not 0 "a group-writable lib-dynload folder is refused"
base_release gwso; chmod 666 "$BASE/lib/python3.13/lib-dynload/_ssl.so"
verify_t
rc_not 0 "a world-writable extension module is refused"
base_release gwexe; chmod 775 "$BASE/bin/python3.13"
verify_t
rc_not 0 "a group-writable interpreter file is refused"
base_release gwdylib; chmod 775 "$BASE/Python"
verify_t
rc_not 0 "a group-writable Python library (the dylib of the framework) is refused"
base_release gwsite; chmod 775 "$BASE/lib/python3.13/site-packages"
verify_t
rc_not 0 "a group-writable site-packages is refused"
base_release link; mkdir -m 777 "$SYSROOT/open-dir"; ln -s "$SYSROOT/open-dir" "$BASE/lib/python3.13/site-packages/shared"
verify_t
rc_not 0 "a link in the base python that leaves it for a world-writable folder is refused"
out_has 'the target of the link' "... as the target of a link"
base_release missing; rm -rf "$BASE"
verify_t
rc_not 0 "a base python that is MISSING on this Mac is refused (not as 'cannot be read')"
out_has 'base python is missing on this Mac' "... saying so"
out_has 'same base python at the same path BEFORE the package is installed' "... and that every Mac needs it at the same path before the package"
out_lacks 'cannot be read' "... and not with the misleading old wording"
base_release nolib; rm -rf "$BASE/lib"
verify_t
rc_not 0 "a base python without a standard library is refused"
out_has 'standard library of the venv.s base python was not found' "... saying so"
base_release nointerp; rm -f "$BASE/bin/python3" "$BASE/bin/python3.13"
verify_t
rc_not 0 "a base python folder without any python is refused"
base_release sticky; mkdir -m 1777 "$SYSROOT/sticky-parent"; mv "$BASE" "$SYSROOT/sticky-parent/base"
BASE_HOME_FOR_RELEASE="$SYSROOT/sticky-parent/base" make_release "$T" 0.2.0 full "$KEY_HEX"
verify_t
rc_is 0 "a base python below a sticky world-writable folder (/private/tmp, nobody can replace what is inside it) is accepted"
base_release open; mkdir -m 777 "$SYSROOT/open-parent"; mv "$BASE" "$SYSROOT/open-parent/base"
BASE_HOME_FOR_RELEASE="$SYSROOT/open-parent/base" make_release "$T" 0.2.0 full "$KEY_HEX"
verify_t
rc_not 0 "... but not below a world-writable folder that is not sticky"
out_has 'open-parent is writable by group or others' "... naming it"
# a python that lives inside the release needs no prerequisite (a relocatable python)
base_release inside; printf 'home = %s/venv/bin\n' "$T" > "$T/venv/pyvenv.cfg"
runx /bin/bash "$PR" --release-dir "$T" --make-manifest --force; $ED sign "$KEY_HEX" "$T/MANIFEST.json" "$T/MANIFEST.sig"
verify_t
rc_is 0 "a venv whose home is inside the release verifies without a base python"
out_has 'base interpreter: inside the release' "... and says so"
# --check-base alone: the same check for one folder, no release
runx /bin/bash "$PR" --check-base "$FAKE_BASE/bin"
rc_is 0 "--check-base on a good base python (no release is needed)"
out_has 'present, not writable by group or others' "... says what it checked"
base_release cb; chmod 775 "$BASE/lib/python3.13"
runx /bin/bash "$PR" --check-base "$BASE/bin"
rc_is 11 "--check-base on a base python with a group-writable standard library: exit 11"
runx /bin/bash "$PR" --check-base "$SYSROOT/nowhere/bin"
rc_is 11 "--check-base on a folder that does not exist: exit 11"
out_has 'BEFORE the package is installed' "... with the prerequisite in the message"
runx /bin/bash "$PR" --check-base relative/bin
rc_is 2 "--check-base needs an absolute path"
# build_pkg.sh checks it too: no package is built from a release that no Mac could install
base_release bp; chmod 775 "$BASE/bin"
mkdir -p "$SYSROOT/bpapp/Contents/MacOS"; printf '#!/bin/sh\n' > "$SYSROOT/bpapp/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$SYSROOT/bpapp/Contents/MacOS/$DEFAULT_SHORT"
runx /bin/bash scripts/build_pkg.sh --release-dir "$T" --release-pubkey "$PUB_PEM" --app "$SYSROOT/bpapp" --out-dir "$SYSROOT/bp-out"
rc_not 0 "build_pkg.sh refuses a release whose base python is group-writable (as a normal user, on the build host)"
out_has 'the release does not verify: no package is built from it' "... before anything is built"
[ ! -e "$SYSROOT/bp-out/$DEFAULT_SHORT-0.2.0.pkg" ]; check $? "... and no package exists"
# make-manifest: a venv left at 664 by python -m venv is named and the way out is printed
rm -rf "$SYSROOT/mm"; mkdir -p "$SYSROOT/mm"; cp -R "$REL" "$SYSROOT/mm/0.2.0"; rm -f "$SYSROOT/mm/0.2.0/MANIFEST.json" "$SYSROOT/mm/0.2.0/MANIFEST.sig"
echo '# activate' > "$SYSROOT/mm/0.2.0/venv/bin/activate"; chmod 664 "$SYSROOT/mm/0.2.0/venv/bin/activate"
runx /bin/bash "$PR" --release-dir "$SYSROOT/mm/0.2.0" --make-manifest
rc_not 0 "--make-manifest refuses a venv file that group can write"
out_has 'writable by group or others: venv/bin/activate' "... naming the file"
out_has "fix: chmod -R go-w '.*/mm/0.2.0'" "... and printing the fix (chmod -R go-w on the release)"
chmod -R go-w "$SYSROOT/mm/0.2.0"
runx /bin/bash "$PR" --release-dir "$SYSROOT/mm/0.2.0" --make-manifest
rc_is 0 "... and after chmod -R go-w the manifest is made"
# the AS-ROOT branch (owner uid 0 of the prefix, the stdlib and every folder above) cannot run here as a normal user: the verifier is run with
# os.geteuid patched to 0 and every stat answering uid 0 (except where a case says otherwise). Same code, same messages.
awk '/<<.PYEOF.$/ { f = 1; next } /^PYEOF$/ { f = 0 } f' "$ROOT/scripts/provision_runtime.sh" > "$WORK/provision_verifier.py"
cat > "$WORK/as_root.py" <<'EOF'
import os, runpy, sys
program, not_root, args = sys.argv[1], sys.argv[2], sys.argv[3:]
# the verifier stats real paths (/private/var/... below the default macOS TMPDIR), so the prefix is resolved the same way (before os.stat is patched)
not_root = os.path.realpath(not_root) if not_root else ""
real_stat, real_lstat = os.stat, os.lstat
def as_uid(st, path):
    uid = 1234 if (not_root and str(path).startswith(not_root)) else 0
    return os.stat_result((st.st_mode, st.st_ino, st.st_dev, st.st_nlink, uid, st.st_gid, st.st_size, int(st.st_atime), int(st.st_mtime), int(st.st_ctime)))
os.geteuid = lambda: 0
os.stat = lambda path, *a, **k: as_uid(real_stat(path, *a, **k), path)
os.lstat = lambda path, *a, **k: as_uid(real_lstat(path, *a, **k), path)
sys.argv = [program] + args
runpy.run_path(program, run_name="__main__")
EOF
as_root() {   # as_root <not-root path prefix or ""> <subcommand args...>
    local nr="$1"; shift
    runx "$PYTHON_FOR_TESTS" -I "$WORK/as_root.py" "$WORK/provision_verifier.py" "$nr" "$@"
}
make_base "$SYSROOT/rb"
as_root "" base-check "$SYSROOT/rb/bin" "" 1
rc_is 0 "as root (patched): a base python that root owns and nobody else can write passes"
out_has 'root-owned' "... and says that the owner was checked"
as_root "$SYSROOT/rb/lib/python3.13/lib-dynload" base-check "$SYSROOT/rb/bin" "" 1
rc_is 11 "as root: ONE folder of the standard library that root does not own is refused"
out_has 'lib-dynload is not owned by root|not owned by root' "... as not owned by root"
as_root "$SYSROOT/rb/bin/python3.13" base-check "$SYSROOT/rb/bin" "" 1
rc_is 11 "as root: an interpreter that root does not own is refused"
as_root "$SYSROOT/rb" base-check "$SYSROOT/rb/bin" "" 1
rc_is 11 "as root: a prefix that root does not own is refused (every folder above it counts)"
# the same folder named through a link (/var -> /private/var below the default macOS TMPDIR): the verifier stats real paths, the shim must too
ln -s "$SYSROOT/rb" "$SYSROOT/rb-link"
as_root "$SYSROOT/rb-link/lib/python3.13/lib-dynload" base-check "$SYSROOT/rb/bin" "" 1
rc_is 11 "as root: a folder that root does not own is refused when it is named through a link (the shim resolves its prefix like the verifier does)"
out_has 'not owned by root' "... as not owned by root"
as_root "" base-check "$SYSROOT/rb/bin" "" 0
rc_is 0 "as a normal user (flag 0) the owner is not looked at: the same tree passes, and says 'owner not checked'"
out_has 'owner not checked' "... saying so"
chmod 775 "$SYSROOT/rb/lib/python3.13/lib-dynload"
as_root "" base-check "$SYSROOT/rb/bin" "" 1
rc_is 11 "as root the write bits are refused too"
stubs_clean; check $? "none of the refusal runs used a forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "provision_runtime.sh --apply: atomic current link, N-1 kept, nothing activated on a failure"
# ---------------------------------------------------------------------------------------------------------------
pkg_env
RROOT="$SYSROOT/releases"
make_release "$SYSROOT/src/0.2.0" 0.2.0 full "$KEY_HEX"
make_release "$SYSROOT/src/0.3.0" 0.3.0 full "$KEY_HEX"
make_release "$SYSROOT/src/0.4.0" 0.4.0 full "$KEY_HEX"
make_release "$SYSROOT/src/0.2.1" 0.2.1 full "$KEY_HEX"
for v in 0.2.0 0.3.0; do
    runx /bin/bash "$PR" --release-dir "$RROOT/$v" --src "$SYSROOT/src/$v" --pubkey "$PUB_PEM" --apply
    rc_is 0 "--apply --src installs release $v"
done
[ "$(readlink "$RROOT/current")" = 0.3.0 ]; check $? "current is a RELATIVE link to the newest release (0.3.0)"
[ -d "$RROOT/0.2.0" ] && [ -d "$RROOT/0.3.0" ]; check $? "the release before it (0.2.0) is kept: N-1"
ls "$RROOT" | grep -q incoming; [ $? -ne 0 ]; check $? "no .incoming folder is left behind"
out_has 'previous release 0.2.0 is kept' "the output names the kept release and the way back (mcap release switch)"
runx /bin/bash "$PR" --release-dir "$RROOT/0.4.0" --src "$SYSROOT/src/0.4.0" --pubkey "$PUB_PEM" --apply
rc_is 0 "--apply --src installs release 0.4.0"
[ "$(readlink "$RROOT/current")" = 0.4.0 ] && [ -d "$RROOT/0.3.0" ] && [ ! -e "$RROOT/0.2.0" ]; check $? "current -> 0.4.0, 0.3.0 kept, 0.2.0 pruned (current and the one before stay)"
out_has 'pruned old release 0.2.0' "the prune is reported"
[ "$("$RROOT/current/venv/bin/python")" = "fake python of release 0.4.0: " ]; check $? "the venv python is reached through current and is the one of 0.4.0"
runx /bin/bash "$PR" --release-dir "$RROOT/0.2.1" --src "$SYSROOT/src/0.2.1" --pubkey "$PUB_PEM" --apply
rc_not 0 "a version older than the current release is refused"
out_has 'older than the current release 0.4.0' "... saying so"
out_has 'mcap release switch' "... and pointing at mcap release switch for a rollback (it checks the policy minimum)"
[ "$(readlink "$RROOT/current")" = 0.4.0 ] && [ ! -e "$RROOT/0.2.1" ]; check $? "nothing changed after the refused downgrade"
runx /bin/bash "$PR" --release-dir "$RROOT/0.4.0" --src "$SYSROOT/src/0.4.0" --pubkey "$PUB_PEM" --apply
rc_not 0 "a release is immutable: --src onto an existing version is refused"
out_has 'releases are immutable' "... saying so"
# re-running the package (same version, in place) keeps the newest OTHER release instead of pruning it
runx /bin/bash "$PR" --release-dir "$RROOT/0.4.0" --pubkey "$PUB_PEM" --apply
rc_is 0 "--apply in place on the current release (the package ran again)"
[ -d "$RROOT/0.3.0" ] && [ "$(readlink "$RROOT/current")" = 0.4.0 ]; check $? "... the previous release 0.3.0 is NOT pruned by it"
out_has 'current already points to 0.4.0' "... and it says current already points there"
# a release that fails verification does not change current, whatever --apply says
make_release "$SYSROOT/src/0.5.0" 0.5.0 full "$KEY_HEX"
echo tampered >> "$SYSROOT/src/0.5.0/pipeline/mcap/__init__.py"
runx /bin/bash "$PR" --release-dir "$RROOT/0.5.0" --src "$SYSROOT/src/0.5.0" --pubkey "$PUB_PEM" --apply
rc_not 0 "--apply of a tampered release fails"
out_has 'hash differs' "... for the hash"
[ "$(readlink "$RROOT/current")" = 0.4.0 ] && [ ! -e "$RROOT/0.5.0" ]; check $? "current still points to 0.4.0, the tampered copy was removed (no half-installed release)"
cp -R "$SYSROOT/src/0.3.0" "$RROOT/0.6.0" 2>/dev/null; sed -i '' 's/0.3.0/0.6.0/' "$RROOT/0.6.0/MANIFEST.json"
runx /bin/bash "$PR" --release-dir "$RROOT/0.6.0" --pubkey "$PUB_PEM" --apply
rc_not 0 "--apply in place of a release with a changed manifest fails"
[ "$(readlink "$RROOT/current")" = 0.4.0 ]; check $? "current did not move (the signature check failed first)"
runx /bin/bash "$PR" --release-dir "$RROOT/0.6.0" --pubkey "$PUB_PEM" --apply --keep 0
[ "$(readlink "$RROOT/current")" = 0.4.0 ]; check $? "(a failed run changes nothing even with --keep 0)"
stubs_clean; check $? "no forbidden program was used"
# "root": with id and stat stubbed to say root, --apply chowns the release, and the verifier must be code that root owns
mkdir -p "$WORK/rootpy" "$WORK/gw-python"
chmod 755 "$WORK/rootpy"; chmod 775 "$WORK/gw-python"
for d in rootpy gw-python; do printf '#!/bin/sh\nexec "%s" "$@"\n' "$PYTHON_FOR_TESTS" > "$WORK/$d/python3"; chmod 755 "$WORK/$d/python3"; done
fresh_env pkg root
SYSROOT="$WORK/env$N/sysroot"; mkdir -p "$SYSROOT"
RROOT="$SYSROOT/releases"
make_release "$SYSROOT/src/0.3.0" 0.3.0 full "$KEY_HEX"
runx /bin/bash "$PR" --release-dir "$RROOT/0.3.0" --src "$SYSROOT/src/0.3.0" --pubkey "$PUB_PEM" --apply --python "$WORK/rootpy/python3"
rc_is 0 "as root (id and stat stubbed): --apply --src with a verifier python that root owns"
grep -q "^chown -R root:wheel .*/releases/.incoming.0.3.0" "$LOGS/chown.log"; check $? "root runs chown -R root:wheel on the copy BEFORE it is verified and moved into place"
grep -q "^chown root:wheel .*/releases$" "$LOGS/chown.log"; check $? "... and on the releases folder"
runx /bin/bash "$PR" --release-dir "$RROOT/0.3.0" --pubkey "$PUB_PEM" --verify-only --python "$WORK/gw-python/python3"
rc_not 0 "as root a --python in a group-writable folder is refused (the code that decides must be root's)"
out_has 'is not root-owned' "... saying so"
stubs_clean; check $? "no forbidden program was used as root either"

# ---------------------------------------------------------------------------------------------------------------
section "provision_user_config.sh: SELF_NAME and ARCHIVE_DIR from a fake CloudStorage mount, no personal string, never overwrites"
# ---------------------------------------------------------------------------------------------------------------
tree_sum() {   # tree_sum <dir>: a checksum of every file (and link target) below it, with names: equal before and after means byte for byte unchanged
    ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
        if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"; fi
      done )
}
pkg_env
UC="scripts/provision_user_config.sh"
ucrun() { runx MCAP_POLICY_PATH="$WORK/no-policy.json" MCAP_DRIVE_DOMAIN=example.com "$@"; }   # the company domain is given; no installed policy is read
ME="$(id -un)"
CFG="$SUPPORT/config.env"
mkdir -p "$H/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings" "$H/Library/CloudStorage/GoogleDrive-someone@example.org/My Drive"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Hong Gildong"
rc_is 0 "provision_user_config.sh in a fake home with a company Drive mount"
[ -f "$CFG" ]; check $? "config.env was created in ~/Library/Application Support/MeetingCapture"
grep -q '^SELF_NAME=Hong Gildong$' "$CFG"; check $? "SELF_NAME is the name that was given"
grep -q '^ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings$' "$CFG"; check $? "ARCHIVE_DIR is the team shared drive folder of the company mount (not the other account's My Drive)"
grep -q '^CLAUDE_AUTH=subscription$' "$CFG"; check $? "CLAUDE_AUTH=subscription for a group whose llm lane is closed (never reads a Keychain item)"
grep -q '^PROJECT_DIR=/Library/Application Support/MeetingCapture/releases/current$' "$CFG" && grep -q '^PYTHON_BIN=/Library/Application Support/MeetingCapture/releases/current/venv/bin/python$' "$CFG"; check $? "the path keys are the root-owned release (current)"
! grep -E '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' "$CFG" | grep -v '^ARCHIVE_DIR=.*GoogleDrive-hong.gildong@example.com' | grep -q .; check $? "the file has no mail address except the company Drive mount that was found"
! grep -Eq '@[A-Z_]+@' "$CFG"; check $? "no placeholder is left in the file"
[ "$(stat -f %Lp "$CFG")" = 644 ]; check $? "config.env has mode 0644"
cat > "$WORK/cfg_load.py" <<'EOF'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from mcap.config import load_config
cfg = load_config(Path(sys.argv[2]))
print("self=%s archive=%s auth=%s explicit_archive=%s explicit_self=%s" % (cfg.self_name, cfg.archive_dir, cfg.claude_auth,
      "ARCHIVE_DIR" in cfg.explicit_keys, "SELF_NAME" in cfg.explicit_keys))
EOF
LOADED="$(HOME="$H" "$PYTHON_FOR_TESTS" "$WORK/cfg_load.py" "$ROOT/pipeline" "$CFG" 2>&1)"
HN="$(printf '%s' "$H" | sed 's#//*#/#g')"      # the temp folder name has a double slash (TMPDIR ends in /); the parser's Path does not
case "$LOADED" in "self=Hong Gildong archive=$HN/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings auth=subscription explicit_archive=True explicit_self=True") ok "the pipeline's own config parser reads the file: name, archive folder (~ expanded), auth, both keys explicit";; *) bad "the pipeline's config parser did not read the file as expected: $LOADED";; esac
[ -d "$SUPPORT/sessions" ] && [ -d "$SUPPORT/local-meetings" ]; check $? "sessions/ and local-meetings/ exist"
grep -q "tmutil addexclusion .*/sessions" "$LOGS/tmutil.log" && grep -q "tmutil addexclusion .*/local-meetings" "$LOGS/tmutil.log"; check $? "both are excluded from Time Machine (tmutil addexclusion, stubbed)"
SUM_BEFORE="$(shasum "$CFG" | awk '{print $1}')"
echo "SELF_NAME=Edited By Hand" >> "$CFG"
SUM_EDITED="$(shasum "$CFG" | awk '{print $1}')"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Somebody Else" --llm allow
rc_is 0 "run again on an existing config.env"
out_has 'config.env exists: kept as it is \(never overwritten\)' "it says the existing file is kept"
[ "$(shasum "$CFG" | awk '{print $1}')" = "$SUM_EDITED" ]; check $? "the existing (hand-edited) config.env is byte for byte unchanged"
# an empty file and a dangling link count as existing, and nothing is written through the link
: > "$CFG"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Somebody Else"
[ ! -s "$CFG" ]; check $? "an existing EMPTY config.env is kept empty"
rm -f "$CFG"; ln -s "$H/elsewhere.txt" "$CFG"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Somebody Else"
[ -L "$CFG" ] && [ ! -e "$H/elsewhere.txt" ]; check $? "a dangling symbolic link at config.env is left alone: nothing is created through it"
rm -f "$CFG"
# no Drive mount, an ambiguous one, a mount without the folder: ARCHIVE_DIR stays empty and says why (Korean guidance), the pipeline then treats the drive lane as not configured
for variant in none two nofolder; do
    pkg_env; CFG="$SUPPORT/config.env"
    case "$variant" in
        none) mkdir -p "$H/Library" ;;
        two) mkdir -p "$H/Library/CloudStorage/GoogleDrive-a@example.com/Shared drives/Meetings" "$H/Library/CloudStorage/GoogleDrive-b@example.com/Shared drives/Meetings" ;;
        nofolder) mkdir -p "$H/Library/CloudStorage/GoogleDrive-a@example.com/My Drive" ;;
    esac
    ucrun /bin/bash "$UC" --user "$ME" --self-name "Hong Gildong"
    rc_is 0 "provision_user_config.sh, Drive situation '$variant'"
    grep -q '^ARCHIVE_DIR=$' "$CFG"; check $? "'$variant': ARCHIVE_DIR is EMPTY (no guess, and never a personal Drive folder)"
    out_has 'Google Drive 폴더를 찾지 못했어요' "'$variant': the Korean guidance is printed"
    LOADED="$(HOME="$H" "$PYTHON_FOR_TESTS" "$WORK/cfg_load.py" "$ROOT/pipeline" "$CFG" 2>&1)"
    case "$LOADED" in *"explicit_archive=False explicit_self=True") ok "'$variant': ARCHIVE_DIR is not an explicit key for the pipeline (a company policy then keeps the Drive lane closed, the meeting stays local)";; *) bad "'$variant': unexpected parse: $LOADED";; esac
done
# no domain at all: no Drive folder is looked for, even though a mount exists; the domain the archive roots of the installed policy name is used instead
pkg_env; CFG="$SUPPORT/config.env"
mkdir -p "$H/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings"
runx MCAP_POLICY_PATH="$WORK/no-policy.json" /bin/bash "$UC" --user "$ME" --self-name "Hong Gildong"
rc_is 0 "provision_user_config.sh without a Drive domain"
grep -q '^ARCHIVE_DIR=$' "$CFG"; check $? "no domain given and no policy: ARCHIVE_DIR is EMPTY (nothing is guessed from a mount)"
out_has 'no Drive domain given' "... and the log says why"
rm -f "$CFG"
printf '{"archive":{"allowed_roots":["~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"]}}\n' > "$WORK/domain-policy.json"
runx MCAP_POLICY_PATH="$WORK/domain-policy.json" /bin/bash "$UC" --user "$ME" --self-name "Hong Gildong"
grep -q '^ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings$' "$CFG"; check $? "the one domain of the policy's archive roots finds the company mount"
# names: from the account database, else the account name; control characters and '#' are removed
pkg_env; CFG="$SUPPORT/config.env"
ucrun env STUB_REALNAME="Kim Minsu" /bin/bash "$UC" --user kim.minsu --home "$H"
grep -q '^SELF_NAME=Kim Minsu$' "$CFG"; check $? "no --self-name: SELF_NAME is the RealName of the directory service (dscl, stubbed)"
rm -f "$CFG"
ucrun /bin/bash "$UC" --user kim.minsu --home "$H"
grep -q '^SELF_NAME=kim.minsu$' "$CFG"; check $? "no RealName known: SELF_NAME falls back to the account name"
rm -f "$CFG"
ucrun /bin/bash "$UC" --user "$ME" --self-name "$(printf 'Kim\nMin #su')"
[ "$(grep -c '^SELF_NAME=' "$CFG")" = 1 ] && grep -q '^SELF_NAME=Kim Min su$' "$CFG"; check $? "a name with a newline and a '#' becomes one clean line (no injected key, no comment)"
rm -f "$CFG"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Hong" --llm allow
grep -q '^CLAUDE_AUTH=api$' "$CFG"; check $? "--llm allow: CLAUDE_AUTH=api (the pilot group with the llm lane)"
pkg_env; CFG="$SUPPORT/config.env"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Hong" --dry-run
[ ! -e "$CFG" ] && [ ! -e "$SUPPORT" ]; check $? "--dry-run creates nothing (no config.env, no folder)"
out_has 'would create .*config.env' "... and says what it would create"
printf 'SELF_NAME=@SELF_NAME@\nFOO=@FOO@\n' > "$WORK/bad.template"
ucrun /bin/bash "$UC" --user "$ME" --self-name "Hong" --template "$WORK/bad.template"
rc_not 0 "a template with a placeholder the script does not fill is refused"
[ ! -e "$CFG" ]; check $? "... and no file was written"
# as root: it never writes into the home itself, it starts again as that user
fresh_env pkg root
UCH="$H"
ucrun /bin/bash "$UC" --user kim.minsu --home "$UCH" --self-name "Kim Minsu"
rc_is 0 "as root (id stubbed): provision_user_config.sh --user NAME --home DIR"
out_has 'starting again as kim.minsu' "it says it starts again as the user"
grep -q 'sudo -u kim.minsu -H env MCAP_PROVISION_DROPPED=1 /bin/bash' "$LOGS/sudo.log"; check $? "it re-runs itself with sudo -u <user> -H (a root process must not write into a user's folder)"
[ -f "$UCH/Library/Application Support/MeetingCapture/config.env" ]; check $? "the file was written by the second, unprivileged run"
stubs_clean; check $? "no forbidden program (security, notarytool) was used"

# ---------------------------------------------------------------------------------------------------------------
section "migrate_owner_install.sh: detect, backup, rollback, finish, and the rehearsal in a temp home"
# ---------------------------------------------------------------------------------------------------------------
MG="scripts/migrate_owner_install.sh"
legacy_files() {   # a believable personal install inside the (current) fake home
    LA="$H/Library/LaunchAgents/$DEFAULT_ID.plist"; APPD="$H/Applications/$DEFAULT_SHORT.app"
    mkdir -p "$H/Library/LaunchAgents" "$APPD/Contents/MacOS" "$SUPPORT/sessions/2026-10-14_1000_zoom" "$SUPPORT/venv/bin" "$SUPPORT/models" "$APPLOGS"
    echo "agent plist" > "$LA"
    printf '#!/bin/sh\n' > "$APPD/Contents/MacOS/$DEFAULT_SHORT"
    printf 'ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Meetings\nSELF_NAME=Owner\n' > "$SUPPORT/config.env"
    echo "Acme" > "$SUPPORT/vocabulary.txt"
    echo '{"schema":1}' > "$SUPPORT/sessions/2026-10-14_1000_zoom/session.json"
    echo model > "$SUPPORT/models/silero_vad.onnx"
}
legacy_home() { pkg_env; legacy_files; }
legacy_home
BEFORE="$(tree_sum "$H")"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H"
rc_is 0 "migrate_owner_install.sh (default: --detect)"
out_has 'per-user LaunchAgent: .*LOADED' "detect: the per-user agent is reported as loaded (launchctl print, stubbed)"
out_has 'app: .*'"$DEFAULT_SHORT"'.app \(not running\)' "detect: the app copy is found"
out_has 'ARCHIVE_DIR points into a personal My Drive' "detect: a personal My Drive ARCHIVE_DIR is called out (the policy only lets meetings go to its allowed roots)"
out_has '1 recording\(s\) not published yet' "detect: unpublished recordings in staging are counted (they are kept)"
[ "$(tree_sum "$H")" = "$BEFORE" ]; check $? "detect changed nothing"
grep -q 'launchctl bootout' "$LOGS/launchctl.log" 2>/dev/null; [ $? -ne 0 ]; check $? "detect never boots anything out"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup --dry-run
[ "$(tree_sum "$H")" = "$BEFORE" ]; check $? "--backup --dry-run changed nothing"
out_has 'would run: mv' "... and printed what it would do"
: > "$LOGS/launchctl.log"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_is 0 "--backup"
[ ! -e "$LA" ] && [ -f "$LA.prev" ] && [ ! -e "$APPD" ] && [ -d "$APPD.prev" ]; check $? "the plist and the app are MOVED to .prev (nothing deleted)"
cmp -s "$SUPPORT/config.env" "$SUPPORT/config.env.bak"; check $? "config.env is copied to config.env.bak, byte for byte (the original stays in place)"
[ -f "$SUPPORT/vocabulary.txt" ] && [ -f "$SUPPORT/sessions/2026-10-14_1000_zoom/session.json" ] && [ -f "$SUPPORT/models/silero_vad.onnx" ] && [ -d "$SUPPORT/venv" ]; check $? "data, sessions, venv and models are untouched"
grep -q "^launchctl bootout gui/$(id -u)/$DEFAULT_ID\$" "$LOGS/launchctl.log"; check $? "the per-user agent was booted out (launchctl bootout gui/<uid>/<label>, stubbed)"
grep -q '^agent_was_loaded=1$' "$SUPPORT/migration.state"; check $? "migration.state records that the agent was loaded"
out_has '마이크와 시스템 오디오 녹음 권한을 다시 물어요' "the Korean note about the permission prompt after the signing change is printed"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_not 0 "a second --backup is refused (a migration is recorded)"
out_has 'a migration is already recorded' "... saying so"
: > "$LOGS/launchctl.log"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --rollback
rc_is 0 "--rollback"
[ "$(tree_sum "$H" | grep -v 'migration.state\|config.env.bak')" = "$(printf '%s\n' "$BEFORE")" ]; check $? "after the rollback every file of the personal install is back, byte for byte"
grep -q "^launchctl bootstrap gui/$(id -u) $LA\$" "$LOGS/launchctl.log"; check $? "the per-user agent is loaded again (it was loaded before)"
[ -f "$SUPPORT/migration.state.rolled-back" ] && [ ! -e "$SUPPORT/migration.state" ]; check $? "the state record is closed (migration.state.rolled-back)"
# rollback when config.env changed since: the backup is restored and the changed file is KEPT
rm -f "$SUPPORT/migration.state.rolled-back" "$SUPPORT/config.env.bak"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
echo "SELF_NAME=Changed After Migration" >> "$SUPPORT/config.env"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --rollback
grep -q 'Changed After Migration' "$SUPPORT/config.env.after-migration" && ! grep -q 'Changed After Migration' "$SUPPORT/config.env"; check $? "a config.env changed after the migration: the backup comes back, the changed file is kept as config.env.after-migration"
# finish
rm -f "$SUPPORT/migration.state.rolled-back" "$SUPPORT/config.env.after-migration" "$SUPPORT/config.env.bak"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
runx /bin/bash "$MG" --home "$H" --finish
rc_is 0 "--finish"
[ ! -e "$LA.prev" ] && [ ! -e "$APPD.prev" ] && [ ! -e "$SUPPORT/migration.state" ] && [ -f "$SUPPORT/config.env.bak" ]; check $? "--finish deletes the .prev copies and the state, keeps config.env.bak"
runx /bin/bash "$MG" --home "$H" --rollback
rc_not 0 "--rollback after --finish: nothing to roll back"
# the rehearsal: a copy in a temp home; the real home is only read, launchctl is never called
legacy_home
BEFORE="$(tree_sum "$H")"
: > "$LOGS/launchctl.log"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --rehearse
rc_is 0 "--rehearse"
out_has 'REHEARSAL PASS: backup and rollback gave back every file byte for byte' "the rehearsal passes: backup then rollback restore everything"
[ "$(tree_sum "$H")" = "$BEFORE" ]; check $? "the real home is byte for byte unchanged"
grep -Eq 'bootout|bootstrap' "$LOGS/launchctl.log"; [ $? -ne 0 ]; check $? "the rehearsal never boots out or loads an agent"
ls "$H/tmp" | grep -q 'mcap-migrate-rehearsal'; [ $? -ne 0 ]; check $? "the temp home of the rehearsal is deleted afterwards"
# a recording in progress, a link out of the home, a link as the plist: refused, nothing changed
legacy_home
touch "$SUPPORT/sessions/2026-10-14_1000_zoom/mic.wav"
BEFORE="$(tree_sum "$H")"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_is 3 "--backup while a recording is in progress: exit 3"
out_has 'a recording is in progress' "... with the reason"
[ "$(tree_sum "$H")" = "$BEFORE" ]; check $? "... and nothing was changed (the agent was not booted out either)"
grep -q bootout "$LOGS/launchctl.log" 2>/dev/null; [ $? -ne 0 ]; check $? "no launchctl bootout happened"
legacy_home
rm -rf "$H/Applications"; mkdir -p "$WORK/outside-apps/$DEFAULT_SHORT.app/Contents/MacOS"; ln -s "$WORK/outside-apps" "$H/Applications"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
rc_not 0 "~/Applications as a link to a folder outside the home is refused"
out_has 'outside the home directory' "... saying so"
[ -d "$WORK/outside-apps/$DEFAULT_SHORT.app" ]; check $? "the app outside the home was not moved"
legacy_home
rm -f "$LA"; ln -s "$H/Library/target.plist" "$LA"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
rc_not 0 "a symbolic link in place of the LaunchAgent plist is refused"
out_has 'is a symbolic link' "... saying so"
# --backup is all or nothing: what cannot be made without touching the install is made FIRST, and a move that fails puts the earlier steps back
# (a failure must not leave the user without an app and make every MDM retry of the package fail on a half-done migration)
legacy_home
BEFORE="$(tree_sum "$H")"
chmod 555 "$SUPPORT"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
chmod 755 "$SUPPORT"
rc_not 0 "--backup with a Support folder that cannot be written fails"
out_has 'cannot create .*config.env.bak: nothing was changed' "... saying that nothing was changed"
[ "$(tree_sum "$H")" = "$BEFORE" ] && [ ! -e "$LA.prev" ] && [ ! -e "$APPD.prev" ] && [ ! -e "$SUPPORT/migration.state" ]; check $? "... plist, app and config.env are where they were, no .prev copy and no state record"
grep -q bootout "$LOGS/launchctl.log" 2>/dev/null; [ $? -ne 0 ]; check $? "... and the agent was not booted out"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_is 0 "... the retry after the folder is fixed goes through (no 'a former migration was not closed')"
legacy_home
ln -s "$H/nowhere" "$SUPPORT/config.env.bak"
BEFORE="$(tree_sum "$H")"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_not 0 "--backup with a dangling link where config.env.bak goes fails"
[ "$(tree_sum "$H")" = "$BEFORE" ] && [ ! -e "$LA.prev" ] && [ ! -e "$APPD.prev" ] && [ ! -e "$SUPPORT/migration.state" ]; check $? "... nothing was moved (the link was not written through either)"
legacy_home
BEFORE="$(tree_sum "$H")"
chmod 555 "$H/Applications"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
chmod 755 "$H/Applications"
rc_not 0 "--backup whose app move fails after the plist was moved (~/Applications not writable) fails"
out_has 'cannot move .*'"$DEFAULT_SHORT"'.app to .*'"$DEFAULT_SHORT"'.app.prev' "... saying which move failed"
out_has 'putting back what it had moved' "... and that it puts back what it had moved"
[ "$(tree_sum "$H")" = "$BEFORE" ] && [ ! -e "$LA.prev" ] && [ ! -e "$SUPPORT/migration.state" ] && [ ! -e "$SUPPORT/config.env.bak" ]; check $? "... the plist is back and the .bak and the state record of this run are gone: the tree is byte for byte as before"
grep -q "^launchctl bootout gui/$(id -u)/$DEFAULT_ID\$" "$LOGS/launchctl.log" && grep -q "^launchctl bootstrap gui/$(id -u) $LA\$" "$LOGS/launchctl.log"; check $? "... the agent that was booted out is loaded again"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup
rc_is 0 "... the retry after the folder is fixed goes through"
[ -f "$LA.prev" ] && [ -d "$APPD.prev" ] && [ -f "$SUPPORT/migration.state" ]; check $? "... and does the whole backup"
# the order of a rollback: the company install goes FIRST (both agents have one label), then --rollback
legacy_home
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
mkdir -p "$SYSROOT/Applications/$DEFAULT_SHORT.app" "$SYSROOT/Library/LaunchAgents"; : > "$SYSROOT/Library/LaunchAgents/$DEFAULT_ID.plist"
runx env STUB_LAUNCHCTL_RC=3 MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$MG" --home "$H" --rollback
rc_is 0 "--rollback while the company install is still on the Mac restores the files"
[ -f "$LA" ] && [ -d "$APPD" ] && [ ! -e "$LA.prev" ]; check $? "... the personal app and plist are back"
out_has 'WARNING: the company install is still on this Mac and has the same LaunchAgent label' "... but it WARNS that the company install is still there and shares the label"
out_has 'remove it FIRST \(sudo scripts/uninstall.sh --company; it leaves this personal install alone\), then run --rollback' "... naming the order: uninstall --company first, then --rollback"
out_has 'The company install is STILL here' "the closing line says so"
out_has 'launchctl bootstrap gui/' "... and how to get the agent loaded afterwards"
legacy_home
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --home "$H" --backup
runx env STUB_LAUNCHCTL_RC=3 MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$MG" --home "$H" --rollback
rc_is 0 "--rollback after the company install was removed (the documented order)"
out_lacks 'company install is still on this Mac' "... no warning"
out_has 'The company install is not on this Mac \(removed first, as it has to be\): the personal install is back' "... and a closing line that says the personal install is back"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$MG" --help
out_has 'have to go FIRST:  sudo scripts/uninstall.sh --company  and then this --rollback' "the help of the script gives the same order"
# --no-launchctl: nothing is booted out even when the agent looks loaded
legacy_home
: > "$LOGS/launchctl.log"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --backup --no-launchctl
rc_is 0 "--backup --no-launchctl"
[ ! -s "$LOGS/launchctl.log" ] && grep -q '^agent_was_loaded=0$' "$SUPPORT/migration.state"; check $? "launchctl is not called at all and the agent is recorded as not loaded"
# as root the account has to be named, and every change inside the home is made with the user's own rights (sudo -u), only launchctl keeps root's
fresh_env pkg root
runx /bin/bash "$MG" --home "$H" --backup
rc_is 2 "as root (stubbed) --backup without --user is refused"
fresh_env pkg root
legacy_files
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --user "$ME" --backup
rc_is 0 "as root (stubbed) --backup --user NAME --home DIR"
[ -f "$LA.prev" ] && [ -d "$APPD.prev" ] && cmp -s "$SUPPORT/config.env" "$SUPPORT/config.env.bak"; check $? "... it put the personal install aside"
grep -q "^sudo -u $ME mv $LA $LA.prev\$" "$LOGS/sudo.log" && grep -q "^sudo -u $ME mv $APPD $APPD.prev\$" "$LOGS/sudo.log"; check $? "the moves inside the home ran as the user (sudo -u <user> mv), not with root's rights"
grep -q "^sudo -u $ME /bin/sh -c set -C; cat" "$LOGS/sudo.log"; check $? "the backup copy and the state record were written as the user, exclusively (noclobber)"
grep -q "^launchctl bootout gui/$(id -u "$ME")/$DEFAULT_ID\$" "$LOGS/launchctl.log"; check $? "... while launchctl bootout (root's right to the user's launchd domain) was called directly"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash "$MG" --home "$H" --user "$ME" --rollback
rc_is 0 "as root (stubbed) --rollback --user NAME"
[ -f "$LA" ] && [ -d "$APPD" ] && grep -q "^sudo -u $ME mv $LA.prev $LA\$" "$LOGS/sudo.log"; check $? "... the restore also ran as the user"
fresh_env pkg root
runx /bin/bash "$MG" --home "$H" --bogus
rc_is 2 "an unknown option is refused (exit 2)"
stubs_clean; check $? "no forbidden program was used"

# ---------------------------------------------------------------------------------------------------------------
section "build_pkg.sh --dry-run: unsigned is the default; identity and entitlements are arguments; notarization is only printed"
# ---------------------------------------------------------------------------------------------------------------
BP="scripts/build_pkg.sh"
pkg_env
runx /bin/bash "$BP" --dry-run --out-dir "$SYSROOT/out"
rc_is 0 "build_pkg.sh --dry-run (no identity, no release)"
out_has 'DRY RUN: nothing is built, written or signed' "it says it builds nothing"
out_has 'UNSIGNED \(no --installer-identity\)' "the package is UNSIGNED by default"
out_has 'NOT re-signed \(no --app-identity\)' "the app is NOT re-signed by default (it keeps the build's own signature)"
out_lacks 'would run: codesign' "no codesign command without an app identity"
out_lacks '(--sign|--timestamp)' "no --sign or --timestamp anywhere without an identity"
out_has 'would run: pkgbuild --root .*--identifier '"$DEFAULT_ID"'.pkg --version 0.2.0 --install-location / --ownership recommended --min-os-version 14.4 --scripts' "pkgbuild: root, identifier, version, install location /, recommended (root:wheel) ownership, minimum macOS, the package scripts"
out_has 'would run: productbuild --distribution .*distribution.xml --package-path' "productbuild takes the distribution file"
out_has 'hostArchitectures=arm64' "the plan names the arm64 guard of the distribution"
out_has "xcrun notarytool submit '.*$DEFAULT_SHORT-0.2.0.pkg' --keychain-profile <profile> --wait" "the notarytool command is PRINTED for the owner"
out_has 'xcrun stapler staple' "... and so is stapler"
out_has 'ADMIN ACTIONS' "... under the heading admin actions"
[ ! -e "$SYSROOT/out" ] && home_is_empty; check $? "the dry run wrote nothing"
[ ! -e "$LOGS/pkgbuild.log" ] && [ ! -e "$LOGS/productbuild.log" ] && [ ! -e "$LOGS/codesign.log" ]; check $? "... and called neither pkgbuild, productbuild nor codesign"
stubs_clean; check $? "... and no forbidden program (notarytool, stapler, security)"
APPID="Developer ID Application: Test Company (ABCDE12345)"; PKGID="Developer ID Installer: Test Company (ABCDE12345)"
cat > "$WORK/my-entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
EOF
runx /bin/bash "$BP" --dry-run --out-dir "$SYSROOT/out" --app-identity "$APPID" --installer-identity "$PKGID" --entitlements "$WORK/my-entitlements.plist"
rc_is 0 "build_pkg.sh --dry-run with an app identity, an installer identity and an entitlements file as arguments"
out_has_plain "would run: codesign --force --options runtime --timestamp --entitlements .*my-entitlements.plist --identifier $DEFAULT_ID --sign Developer ID Application: Test Company \(ABCDE12345\) .*payload/Applications/$DEFAULT_SHORT.app" "the app COPY is signed with the hardened runtime, a secure timestamp, the given entitlements, the fixed identifier and the given identity"
out_has 'would run: codesign --verify --strict --verbose=2' "... and verified"
out_has_plain 'would run: productbuild --distribution .* --sign Developer ID Installer: Test Company \(ABCDE12345\) --timestamp' "productbuild signs the package with the installer identity and a secure timestamp"
out_has 'would run: pkgutil --check-signature' "... and the signature of the package is checked"
out_lacks 'UNSIGNED' "no UNSIGNED notice when both identities are given"
[ ! -e "$LOGS/codesign.log" ] && [ ! -e "$LOGS/productbuild.log" ]; check $? "the dry run with identities still called nothing"
out_has 'xcrun notarytool submit' "notarization stays a printed owner action even with identities"
runx /bin/bash "$BP" --dry-run --out-dir "$SYSROOT/out" --app-identity "$APPID" --entitlements "$WORK/missing.plist"
rc_not 0 "--entitlements naming a missing file is refused"
printf 'not a plist' > "$WORK/bad-ent.plist"
runx /bin/bash "$BP" --dry-run --out-dir "$SYSROOT/out" --app-identity "$APPID" --entitlements "$WORK/bad-ent.plist"
rc_not 0 "--entitlements that is not a plist is refused"
runx /bin/bash "$BP" --dry-run --client-only --contact "IT 헬프데스크 #it-help" --out-dir "$SYSROOT/out"
out_has "$DEFAULT_SHORT"'-0.2.0-client.pkg' "--client-only gives the package another name (the two flavours cannot be confused)"
out_has 'make_policy.sh --out .*baseline-policy.json .* --client-only' "... and the baseline policy has no local model default"
out_has 'support.contact|--contact' "--contact reaches the baseline policy"
runx /bin/bash "$BP" --out-dir "$SYSROOT/out"
rc_is 2 "without --dry-run the release is required (exit 2)"
out_has '--release-dir is required' "... saying so"
stubs_clean; check $? "no forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "build_pkg.sh with stub pkgbuild/productbuild: payload, shim, LaunchAgent, scripts, baseline policy, distribution"
# ---------------------------------------------------------------------------------------------------------------
pkg_env
OUTD="$SYSROOT/out"
make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
APPF="$SYSROOT/$DEFAULT_SHORT.app"
mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --contact "IT 헬프데스크 #it-help"
rc_is 0 "build_pkg.sh (stub pkgbuild and productbuild) with a signed release"
[ "$(tail -n 1 "$OUT")" = "$OUTD/$DEFAULT_SHORT-0.2.0.pkg" ] && [ -f "$OUTD/$DEFAULT_SHORT-0.2.0.pkg" ]; check $? "the last line of output is the path of the package"
out_has 'signature OK, verified 4 files and 1 links' "the release was verified (signature and hashes) before anything was built"
grep -q '^pkgbuild --root .*/work/payload --component-plist .*/work/component.plist --identifier '"$DEFAULT_ID"'.pkg --version 0.2.0 --install-location / --ownership recommended --min-os-version 14.4 --scripts .*/work/scripts .*'"$DEFAULT_SHORT"'-0.2.0-component.pkg$' "$LOGS/pkgbuild.log"; check $? "pkgbuild was called with the documented arguments"
grep -q "^productbuild --distribution .*/work/distribution.xml --package-path .*/work $OUTD/$DEFAULT_SHORT-0.2.0.pkg\$" "$LOGS/productbuild.log"; check $? "productbuild was called without --sign (unsigned default)"
[ ! -e "$LOGS/codesign.log" ]; check $? "the unsigned build did not call codesign (the app is not re-signed)"
stubs_clean; check $? "no notarytool, stapler or security call"
W="$OUTD/work"; PAYLOAD="$W/payload"; PSCR="$W/scripts"; SYSP="$PAYLOAD/Library/Application Support/MeetingCapture"
[ -x "$PAYLOAD/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT" ]; check $? "payload: the app is in /Applications"
[ -d "$SYSP/releases/0.2.0/pipeline" ] && [ -f "$SYSP/releases/0.2.0/MANIFEST.json" ] && [ -f "$SYSP/releases/0.2.0/MANIFEST.sig" ]; check $? "payload: the release (with its manifest and signature) is under releases/<version>"
cmp -s "$SYSP/release-signing.pub.pem" "$PUB_PEM"; check $? "payload: the public key of the release signature is installed next to it"
[ ! -e "$SYSP/policy.json" ] && [ ! -e "$SYSP/releases/current" ]; check $? "payload: no policy.json and no current link (postinstall places them: it must not replace a policy of MDM)"
[ -z "$(find "$PAYLOAD" -not -type l -perm -022 2>/dev/null | head -n 1)" ]; check $? "payload: nothing is writable by group or others (root:wheel ownership is then safe)"
AGENTP="$PAYLOAD/Library/LaunchAgents/$DEFAULT_ID.plist"
plutil -lint "$AGENTP" >/dev/null 2>&1; check $? "payload: the LaunchAgent plist is valid"
[ "$(plutil -extract Label raw -o - "$AGENTP")" = $DEFAULT_ID ] && [ "$(plutil -extract ProgramArguments.0 raw -o - "$AGENTP")" = /Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT ] \
  && [ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$AGENTP")" = false ] && [ "$(plutil -extract RunAtLoad raw -o - "$AGENTP")" = true ] && [ "$(plutil -extract LimitLoadToSessionType raw -o - "$AGENTP")" = Aqua ]; check $? "LaunchAgent: the personal label, the app in /Applications, RunAtLoad, KeepAlive on crash only, Aqua sessions only"
[ "$(plutil -extract EnvironmentVariables.PATH raw -o - "$AGENTP")" = "/usr/bin:/bin:/usr/sbin:/sbin" ]; check $? "LaunchAgent: PATH has no user folder (no ~/.local/bin, no /opt/homebrew/bin)"
SHIMF="$PAYLOAD/usr/local/bin/mcap"
[ -x "$SHIMF" ] && [ "$(stat -f %Lp "$SHIMF")" = 755 ] && /bin/sh -n "$SHIMF"; check $? "the shim /usr/local/bin/mcap is an executable 0755 shell script"
# the shim, run against a fake release with a HOSTILE caller environment
mkdir -p "$WORK/shimroot/venv/bin" "$WORK/shimroot/pipeline"
printf '#!/bin/sh\nenv | sort\necho "ARGS: $*"\n' > "$WORK/shimroot/venv/bin/python"; chmod 755 "$WORK/shimroot/venv/bin/python"
sed "s|RELEASE=\"/Library/Application Support/MeetingCapture/releases/current\"|RELEASE=\"$WORK/shimroot\"|" "$SHIMF" > "$WORK/shim-under-test"; chmod 755 "$WORK/shim-under-test"
grep -q "RELEASE=\"$WORK/shimroot\"" "$WORK/shim-under-test"; check $? "(premise) the shim names the release path I replaced"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
env -i HOME=/Users/someone USER=someone PATH=/evil/bin:/opt/homebrew/bin MCAP_CONFIG=/evil/config.env MCAP_POLICY_PATH=/evil/policy.json MCAP_APP_NAME=Evil MCAP_APP_SHORT_NAME=Evil PYTHONPATH=/evil/py PYTHONHOME=/evil/home \
    PYTHONSTARTUP=/evil/start.py DYLD_INSERT_LIBRARIES=/evil/lib.dylib SSL_CERT_FILE=/evil/ca.pem HTTPS_PROXY=http://evil:8080 SOMETHING_ELSE=1 /bin/sh "$WORK/shim-under-test" status --json > "$OUT" 2>&1; RC=$?
rc_is 0 "the shim runs the release python"
out_has '^ARGS: -m mcap status --json$' "the shim runs  python -m mcap <the caller's arguments>"
out_has "^PYTHONPATH=$WORK/shimroot/pipeline$" "PYTHONPATH is the pipeline of the release, nothing of the caller's"
out_has '^PYTHONSAFEPATH=1$' "PYTHONSAFEPATH=1 keeps the working directory off sys.path"
out_has '^PYTHONNOUSERSITE=1$' "PYTHONNOUSERSITE=1 keeps the user's site-packages (and their .pth files) out"
out_has '^PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "PATH is the system's four folders"
out_has '^HOME=/Users/someone$' "HOME is kept (the pipeline's data lives in the user's home)"
out_has "^MCAP_APP_NAME=$DEFAULT_NAME\$" "the two names of the app are the package's own (the caller's MCAP_APP_NAME=Evil is dropped), so the pipeline names the app the way the app does"
out_has "^MCAP_APP_SHORT_NAME=$DEFAULT_SHORT\$" "... and the short name"
out_lacks 'Evil' "... nothing of the caller's names is left"
out_lacks 'MCAP_CONFIG|MCAP_POLICY_PATH|PYTHONHOME|PYTHONSTARTUP|DYLD_INSERT_LIBRARIES|SSL_CERT_FILE|HTTPS_PROXY|SOMETHING_ELSE|/evil' "every test hook, loader, proxy and CA variable of the caller is dropped"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
sed "s|RELEASE=\"/Library/Application Support/MeetingCapture/releases/current\"|RELEASE=\"$WORK/no-such-release\"|" "$SHIMF" > "$WORK/shim-missing"
/bin/sh "$WORK/shim-missing" status > "$OUT" 2>&1; RC=$?
rc_is 127 "without an active release the shim exits 127"
out_has 'no company release is active' "... with a plain message"
for f in preinstall postinstall provision_runtime.sh provision_user_config.sh migrate_owner_install.sh bundle_id.sh config.env.company.template baseline-policy.json RELEASE_VERSION RELEASE_FLAVOR RELEASE_BUNDLE_ID RELEASE_BASE_PYTHON; do
    [ -f "$PSCR/$f" ] || echo "      missing in the package scripts: $f"
done
[ -x "$PSCR/preinstall" ] && [ -x "$PSCR/postinstall" ] && [ -f "$PSCR/provision_runtime.sh" ] && [ -f "$PSCR/migrate_owner_install.sh" ] && [ -f "$PSCR/baseline-policy.json" ]; check $? "package scripts: preinstall and postinstall (executable), the helpers and the baseline policy"
[ "$(cat "$PSCR/RELEASE_VERSION")" = 0.2.0 ] && [ "$(cat "$PSCR/RELEASE_FLAVOR")" = full ]; check $? "package scripts: RELEASE_VERSION 0.2.0, RELEASE_FLAVOR full"
[ "$(cat "$PSCR/RELEASE_BUNDLE_ID")" = "$DEFAULT_ID" ] && cmp -s "$PSCR/bundle_id.sh" "$ROOT/scripts/bundle_id.sh"; check $? "package scripts: RELEASE_BUNDLE_ID is the bundle id of the packaged app (the default here) and bundle_id.sh travels with migrate_owner_install.sh"
ST="$(policy_state "$PSCR/baseline-policy.json")"
[ "$(json_get "$ST" 'd["state"]')" = valid ] && [ "$(json_get "$ST" 'all(v == "deny" for v in d["lanes"].values())')" = True ] && [ "$(json_get "$ST" 'd["local_only_default"]')" = True ]; check $? "the baseline policy in the package: the pipeline's loader accepts it, every external lane deny, local_only default true"
grep -q 'IT 헬프데스크 #it-help' "$PSCR/baseline-policy.json"; check $? "... with the support contact of --contact"
DIST="$W/distribution.xml"
xmllint --noout "$DIST" 2>/dev/null && grep -q 'hostArchitectures="arm64"' "$DIST" && [ "$(grep -c '<os-version min="14.4"/>' "$DIST")" = 2 ] && grep -q "$DEFAULT_SHORT"'-0.2.0-component.pkg</pkg-ref>' "$DIST" && grep -q 'version="0.2.0"' "$DIST"; check $? "distribution.xml of the build: well-formed, arm64 guard, OS 14.4 guard twice, the component package and its version"
plutil -lint "$W/component.plist" >/dev/null 2>&1 && [ "$(plutil -extract 0.BundleIsRelocatable raw -o - "$W/component.plist")" = false ]; check $? "component plist: the app is not relocatable (it installs into /Applications, wherever a copy is found on the build Mac)"
# the second build replaces the work folder, a third with --client-only has the other name
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --client-only
rc_not 0 "--client-only with a FULL release is refused (the manifest says full)"
out_has 'is a full release but --flavor client' "... naming the mismatch"
make_release "$SYSROOT/release-client/0.2.0" 0.2.0 client "$KEY_HEX"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release-client/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --client-only
rc_is 0 "--client-only with a client release"
[ -f "$OUTD/$DEFAULT_SHORT-0.2.0-client.pkg" ] && [ "$(cat "$OUTD/work/scripts/RELEASE_FLAVOR")" = client ]; check $? "the client package has its own name and RELEASE_FLAVOR client"
! grep -q 'ASR_MODEL' "$OUTD/work/scripts/baseline-policy.json"; check $? "the client baseline sets no ASR_MODEL (there is no local model)"
# signed build (identities are stubs): the COPY of the app is signed with the hardened runtime, the source app is not touched
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --app-identity "$APPID" --installer-identity "$PKGID" --entitlements "$WORK/my-entitlements.plist"
rc_is 0 "build_pkg.sh with identities (stub codesign, pkgbuild, productbuild)"
grep -q -- "--force --options runtime --timestamp --entitlements $WORK/my-entitlements.plist --identifier $DEFAULT_ID --sign $APPID $OUTD/work/payload/Applications/$DEFAULT_SHORT.app\$" "$LOGS/codesign.log"; check $? "codesign signed the app COPY inside the payload with runtime, timestamp, entitlements, identifier and identity"
[ ! -e "$APPF/.stubsig" ] && [ ! -e "$APPF.stubsig" ]; check $? "the source app (the personal build) was not re-signed"
grep -q -- "--sign $PKGID --timestamp $OUTD/$DEFAULT_SHORT-0.2.0.pkg\$" "$LOGS/productbuild.log"; check $? "productbuild signed the package with the installer identity and a secure timestamp"
grep -q "pkgutil --check-signature $OUTD/$DEFAULT_SHORT-0.2.0.pkg" "$LOGS/pkgutil.log"; check $? "the signature of the package was checked with pkgutil"
out_has 'app signed with the hardened runtime' "the hardened runtime flag of the signed app was verified, and the untested device item is named"
out_has "xcrun notarytool submit '.*$DEFAULT_SHORT-0.2.0.pkg'" "the signed run still only PRINTS the notarization step for the owner"
stubs_clean; check $? "no notarytool, stapler or security call in the signed build either"
# the release's own binaries: the notary service wants EVERY Mach-O file signed, and the release is hashed into the manifest, so they are signed BEFORE it
macho_release() {   # macho_release <variant>: a release (in $MREL) with a REAL Mach-O file (a copy of /usr/bin/true) in the venv, signed as the variant says, then manifest and signature
    pkg_env; OUTD="$SYSROOT/out"; MREL="$SYSROOT/release/0.2.0"
    make_release "$MREL" 0.2.0 full "$KEY_HEX"
    rm -f "$MREL/MANIFEST.json" "$MREL/MANIFEST.sig"
    cp /usr/bin/true "$MREL/venv/bin/helper-macho"; chmod 755 "$MREL/venv/bin/helper-macho"
    case "$1" in
        noruntime)   STUB_LOG="$LOGS" "$STUBS_PKG/codesign" --force --timestamp --sign "$APPID" "$MREL/venv/bin/helper-macho" ;;
        notimestamp) STUB_LOG="$LOGS" "$STUBS_PKG/codesign" --force --options runtime --sign "$APPID" "$MREL/venv/bin/helper-macho" ;;
        adhoc)       STUB_LOG="$LOGS" "$STUBS_PKG/codesign" --force --options runtime --timestamp --sign - "$MREL/venv/bin/helper-macho" ;;
    esac
    APPF="$SYSROOT/$DEFAULT_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
}
macho_manifest() {  # make the manifest of $MREL and sign it (after the binaries were signed)
    /bin/bash "$ROOT/scripts/provision_runtime.sh" --release-dir "$MREL" --make-manifest > "$WORK/make_release.out" 2>&1 || { echo "make-manifest failed"; cat "$WORK/make_release.out"; }
    $ED sign "$KEY_HEX" "$MREL/MANIFEST.json" "$MREL/MANIFEST.sig"
}
macho_release unsigned
macho_manifest
runx /bin/bash "$PR" --release-dir "$MREL" --sign-macho --identity "$APPID"
rc_not 0 "--sign-macho on a release that already has a MANIFEST.json is refused (signing changes the hashes it lists)"
out_has 'Sign FIRST, then --make-manifest' "... saying the order"
[ ! -s "$LOGS/codesign.log" ]; check $? "... and signed nothing"
rm -f "$MREL/MANIFEST.json" "$MREL/MANIFEST.sig"
runx /bin/bash "$PR" --release-dir "$MREL" --sign-macho
rc_is 2 "--sign-macho without --identity is refused"
runx /bin/bash "$PR" --release-dir "$MREL" --sign-macho --identity "$APPID" --entitlements "$WORK/no-such.plist"
rc_not 0 "--sign-macho with an entitlements file that is not there is refused"
runx /bin/bash "$PR" --release-dir "$MREL" --sign-macho --identity "$APPID"
rc_is 0 "--sign-macho --identity"
out_has 'signed 1 Mach-O file\(s\)' "it found the one real Mach-O file (found by content: the shell-script pythons of the fake release are left alone)"
[ "$(grep -c . "$LOGS/codesign.log")" = 1 ] && grep -q -- "^codesign --force --options runtime --timestamp --sign $APPID $MREL/venv/bin/helper-macho\$" "$LOGS/codesign.log"; check $? "codesign got the identity, the hardened runtime and a secure timestamp (one call, for that file)"
out_has 'next: --make-manifest' "... and it names the next step (manifest, then the offline signature)"
runx /bin/bash "$PR" --release-dir "$SYSROOT/no-macho/0.2.0" --sign-macho --identity "$APPID"
rc_not 0 "--sign-macho on a folder that is not there is refused"
mkdir -p "$SYSROOT/no-macho/0.2.0/pipeline"; echo x > "$SYSROOT/no-macho/0.2.0/pipeline/a.py"
runx /bin/bash "$PR" --release-dir "$SYSROOT/no-macho/0.2.0" --sign-macho --identity "$APPID"
rc_not 0 "--sign-macho on a folder without any Mach-O file is refused (the wrong folder)"
out_has 'no Mach-O file below' "... saying so"
macho_manifest
runx /bin/bash "$BP" --release-dir "$MREL" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --app-identity "$APPID" --installer-identity "$PKGID"
rc_is 0 "build_pkg.sh --app-identity on a release whose Mach-O file was signed first"
out_has '1 Mach-O file\(s\) of the payload: all signed with a Developer ID Application certificate, the hardened runtime and a secure timestamp' "... it checked every Mach-O file of the payload and says the owner-side test is still open"
grep -q "^codesign -dvv .*/helper-macho\$" "$LOGS/codesign.log"; check $? "... with codesign -dvv on that file"
for variant in unsigned noruntime notimestamp adhoc; do
    case "$variant" in
        unsigned) WHY='helper-macho: not signed' ;;
        noruntime) WHY='helper-macho: no hardened runtime' ;;
        notimestamp) WHY='helper-macho: no secure timestamp' ;;
        adhoc) WHY='helper-macho: no Developer ID Application signature' ;;
    esac
    macho_release "$variant"; macho_manifest
    runx /bin/bash "$BP" --release-dir "$MREL" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --app-identity "$APPID" --installer-identity "$PKGID"
    rc_not 0 "build_pkg.sh --app-identity refuses a payload with a Mach-O file that is $variant"
    out_has "$WHY" "... naming the file and the reason"
    out_has "sign the release's binaries BEFORE its manifest \(scripts/provision_runtime.sh --release-dir <dir> --sign-macho --identity" "... and the way out"
    [ ! -e "$LOGS/pkgbuild.log" ] && [ ! -e "$OUTD/$DEFAULT_SHORT-0.2.0.pkg" ]; check $? "... pkgbuild was never called, no package exists"
done
runx /bin/bash "$BP" --release-dir "$MREL" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD"
rc_is 0 "the unsigned rehearsal package is not held to it (no --app-identity: the same payload builds)"
stubs_clean; check $? "no forbidden program in the Mach-O signing tests either"
# refusals: nothing is built from a release that does not verify
for case_name in hash version nosig wrongkey; do
    pkg_env; OUTD="$SYSROOT/out"
    make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
    APPF="$SYSROOT/$DEFAULT_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
    KEYARG="$PUB_PEM"; EXTRA=""
    case "$case_name" in
        hash) echo tampered >> "$SYSROOT/release/0.2.0/models/whisper-large-v3-mlx/weights.npz" ;;
        version) EXTRA="--version 0.9.0" ;;
        nosig) rm -f "$SYSROOT/release/0.2.0/MANIFEST.sig" ;;
        wrongkey) KEYARG="$OTHER_PEM" ;;
    esac
    runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$KEYARG" --app "$APPF" --out-dir "$OUTD" $EXTRA
    rc_not 0 "build_pkg.sh refuses a release with a $case_name problem"
    [ ! -e "$LOGS/pkgbuild.log" ] && [ ! -e "$OUTD/$DEFAULT_SHORT-0.2.0.pkg" ]; check $? "... and pkgbuild was never called, no package exists"
done
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$SYSROOT/not-an-app" --out-dir "$OUTD"
rc_not 0 "--app that is not the app of this package is refused"
# without --app the app comes from scripts/build_app.sh (the one-line stub program, ad-hoc signed through the stub codesign)
pkg_env; OUTD="$SYSROOT/out"
make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
runx env MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$SYSROOT/build" /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --out-dir "$OUTD"
rc_is 0 "without --app, build_pkg.sh builds the app through scripts/build_app.sh"
[ -x "$OUTD/work/payload/Applications/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT" ] && grep -q 'signed ad-hoc' "$OUT"; check $? "... a copy of that build is what is in the payload (ad-hoc signed, as build_app.sh made it)"

# ---------------------------------------------------------------------------------------------------------------
section "pkg preinstall: arm64 and macOS 14.4 guards, legacy install put aside, a recording stops the installation (rehearsal on a staged tree)"
# ---------------------------------------------------------------------------------------------------------------
pre() {   # pre [VAR=value ...]: preinstall of the last build, a REHEARSAL on $SYSROOT (target volume != /), console user = the test user in the fake home
    runx env MCAP_PKG_CONSOLE_USER="$ME" MCAP_PKG_CONSOLE_HOME="$H" "$@" /bin/bash "$PSCRIPTS/preinstall" pkg / "$SYSROOT"
}
pkg_env; OUTD="$SYSROOT/out"
make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
APPF="$SYSROOT/$DEFAULT_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD"
PSCRIPTS="$OUTD/work/scripts"
[ -x "$PSCRIPTS/preinstall" ]; check $? "(premise) a package was built for the installer script tests"
out_has "base python: $FAKE_BASE/bin must be on every client Mac before this package" "the build says that the base python is a prerequisite of every Mac (the package does not carry it)"
[ "$(cat "$PSCRIPTS/RELEASE_BASE_PYTHON")" = "$FAKE_BASE/bin" ]; check $? "the package scripts carry where the base python must be (RELEASE_BASE_PYTHON)"
pre STUB_ARM64=0
rc_is 10 "preinstall on an Intel Mac (hw.optional.arm64 = 0): exit 10"
out_has 'needs an Apple silicon Mac' "... with a plain message that the MDM reports"
out_has 'Nothing was installed' "... and says nothing was installed"
pre STUB_MACOS=14.3.1
rc_is 11 "preinstall on macOS 14.3.1: exit 11"
out_has 'macOS 14.4 or newer \(this Mac has 14.3.1\)' "... naming the version it found"
pre STUB_MACOS=13.6
rc_is 11 "preinstall on macOS 13.6: exit 11"
for ver in 14.4 14.4.1 15.1 26.0 100.1; do
    pre STUB_MACOS="$ver"
    rc_is 0 "preinstall accepts macOS $ver"
done
# the base python of the release is checked FIRST: a Mac without it keeps its personal install (a failed postinstall would leave it without a working app)
legacy_home
BEFORE_BASE="$(tree_sum "$H")"
pre
rc_is 0 "preinstall with the base python in place"
out_has 'ok: the base python of the release is there' "... and it says it looked"
legacy_home
BEFORE_BASE="$(tree_sum "$H")"
chmod 775 "$FAKE_BASE/bin"
pre
rc_is 16 "preinstall on a Mac whose base python is group-writable (the python.org installer's default): exit 16"
out_has 'missing or not trustworthy' "... with the reason"
out_has 'a personal install is still where it was' "... and says that nothing was touched"
[ "$(tree_sum "$H")" = "$BEFORE_BASE" ] && [ -f "$LA" ] && [ -d "$APPD" ] && [ ! -e "$LA.prev" ]; check $? "the personal install was NOT put aside (nothing was changed)"
chmod 755 "$FAKE_BASE/bin"
mv "$FAKE_BASE" "$FAKE_BASE.away"
pre
rc_is 16 "preinstall on a Mac WITHOUT the base python: exit 16"
out_has 'base python is missing on this Mac' "... naming what is missing"
out_has 'same base python at the same path BEFORE the package' "... and the prerequisite"
[ "$(tree_sum "$H")" = "$BEFORE_BASE" ] && [ ! -e "$LA.prev" ]; check $? "... also without touching the personal install"
mv "$FAKE_BASE.away" "$FAKE_BASE"
pre
rc_is 0 "preinstall again with the base python back (a rehearsal on a staged tree)"
[ -f "$LA.prev" ]; check $? "... now the personal install is put aside as usual"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
rc_is 0 "(the rollback puts it back)"
# an older company app under another file name (same bundle id) next to the new /Applications/<short name>.app: refused before anything is put aside
legacy_home
BEFORE_OLD="$(tree_sum "$H")"
mkdir -p "$SYSROOT/Applications"
fake_app_with_names "$SYSROOT/Applications/Older.app" "$DEFAULT_ID" "Older" "Older"
pre
rc_is 17 "preinstall on a Mac with another app in /Applications that has the package's bundle id (an older package under another file name): exit 17"
out_has "Older\\.app has the bundle id of this package \\($DEFAULT_ID\\) under another file name than $DEFAULT_SHORT\\.app" "... naming the old app, the id and the new file name"
out_has 'Nothing was installed' "... and that nothing was installed"
out_has "MCAP_APP_SHORT_NAME=<the old file name without \\.app>" "... and the way out: build the package under the old file name"
[ "$(tree_sum "$H")" = "$BEFORE_OLD" ] && [ -f "$LA" ] && [ -d "$APPD" ] && [ ! -e "$LA.prev" ] && [ -d "$SYSROOT/Applications/Older.app" ]; check $? "... before anything was changed: the personal install was not put aside, the old app is untouched"
mv "$SYSROOT/Applications/Older.app" "$WORK/older-aside.app"
fake_app_with_names "$SYSROOT/Applications/Other.app" "com.example.other" "Other" "Other"
pre
rc_is 0 "an app in /Applications with ANOTHER bundle id is not in the way"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
mv "$SYSROOT/Applications/Other.app" "$WORK/other-aside.app"
fake_app_with_names "$SYSROOT/Applications/$DEFAULT_SHORT.app" "$DEFAULT_ID" "$DEFAULT_NAME" "$DEFAULT_SHORT"
pre
rc_is 0 "the app of the package's own file name with the same id is an upgrade, not a duplicate"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
mv "$SYSROOT/Applications/$DEFAULT_SHORT.app" "$WORK/upgrade-aside.app"
# a release whose python is inside the release has no prerequisite: RELEASE_BASE_PYTHON is empty and the check is skipped
make_release "$SYSROOT/release-inside/0.2.0" 0.2.0 full
printf 'home = %s/venv/bin\n' "$SYSROOT/release-inside/0.2.0" > "$SYSROOT/release-inside/0.2.0/venv/pyvenv.cfg"
runx /bin/bash "$PR" --release-dir "$SYSROOT/release-inside/0.2.0" --make-manifest --force
$ED sign "$KEY_HEX" "$SYSROOT/release-inside/0.2.0/MANIFEST.json" "$SYSROOT/release-inside/0.2.0/MANIFEST.sig"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release-inside/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$SYSROOT/out-inside"
[ -z "$(tr -d '\n' < "$SYSROOT/out-inside/work/scripts/RELEASE_BASE_PYTHON")" ]; check $? "a release with its python inside has an empty RELEASE_BASE_PYTHON"
mv "$FAKE_BASE" "$FAKE_BASE.away"
runx env MCAP_PKG_CONSOLE_USER="$ME" MCAP_PKG_CONSOLE_HOME="$H" /bin/bash "$SYSROOT/out-inside/work/scripts/preinstall" pkg / "$SYSROOT"
rc_is 0 "... and its preinstall does not look for any base python"
mv "$FAKE_BASE.away" "$FAKE_BASE"
legacy_home
pre
rc_is 0 "preinstall on a Mac with a personal install of the console user"
out_has 'a personal install of .* was found' "it finds the personal install"
[ -f "$LA.prev" ] && [ -d "$APPD.prev" ] && [ ! -e "$LA" ] && [ ! -e "$APPD" ] && cmp -s "$SUPPORT/config.env" "$SUPPORT/config.env.bak"; check $? "the LaunchAgent plist and the app are put aside (.prev), config.env is backed up (.bak): nothing deleted"
[ -f "$SUPPORT/vocabulary.txt" ] && [ -f "$SUPPORT/sessions/2026-10-14_1000_zoom/session.json" ]; check $? "data and sessions are untouched"
[ ! -s "$LOGS/launchctl.log" ]; check $? "a rehearsal never calls launchctl (the real agent of the Mac it runs on stays as it is)"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
rc_is 0 "the rollback after the preinstall (migrate_owner_install.sh --rollback)"
[ -f "$LA" ] && [ -d "$APPD" ] && [ ! -e "$LA.prev" ] && [ ! -e "$APPD.prev" ]; check $? "... restores the app and the plist"
legacy_home
touch "$SUPPORT/sessions/2026-10-14_1000_zoom/remote.wav"
BEFORE="$(tree_sum "$H")"
pre
rc_is 12 "preinstall while a recording is in progress: exit 12"
out_has 'a recording is in progress for' "... with the reason"
[ "$(tree_sum "$H")" = "$BEFORE" ]; check $? "... and nothing was changed"
pkg_env
pre
rc_is 0 "preinstall on a Mac without a personal install"
out_has 'no personal install of .* found' "... says so and does nothing"
runx env MCAP_PKG_CONSOLE_USER= /bin/bash "$PSCRIPTS/preinstall" pkg / "$SYSROOT"
rc_is 0 "preinstall with nobody at the console"
out_has 'nobody is logged in' "... says so (MDM runs the backup for users later)"
if [ "$AM_ROOT" = 0 ]; then
    runx /bin/bash "$PSCRIPTS/preinstall" pkg / /
    rc_is 13 "preinstall for the REAL system as a normal user: exit 13"
    out_has 'must run as root' "... and nothing is touched"
else
    echo "  skip the real-system refusal of preinstall (this test run is root)"
fi
stubs_clean; check $? "no forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "pkg postinstall: baseline policy.json and policy.required, release layout with an atomic current link, tools, user config (rehearsal)"
# ---------------------------------------------------------------------------------------------------------------
post() {   # post [VAR=value ...]: the payload of the last build is "installed" into $SYSROOT (copied, as the Installer would lay it down), then postinstall
    runx env MCAP_PKG_CONSOLE_USER="$ME" MCAP_PKG_CONSOLE_HOME="$H" MCAP_POLICY_PATH="$SYS/policy.json" "$@" /bin/bash "$PSCRIPTS/postinstall" pkg / "$SYSROOT"
}
install_payload() { cp -R "$OUTD/work/payload/." "$SYSROOT/"; }
build_for_install() {   # build_for_install <version> : a fresh environment, a signed release of that version, a package, the payload laid down
    pkg_env; OUTD="$SYSROOT/out"
    make_release "$SYSROOT/release/$1" "$1" full "$KEY_HEX"
    APPF="$SYSROOT/$DEFAULT_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
    runx /bin/bash "$BP" --release-dir "$SYSROOT/release/$1" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --version "$1" --contact "IT 헬프데스크 #it-help"
    PSCRIPTS="$OUTD/work/scripts"
    install_payload
    SYS="$SYSROOT/Library/Application Support/MeetingCapture"
}
build_for_install 0.2.0
mkdir -p "$H/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings"
post STUB_REALNAME="Test Person"
rc_is 0 "postinstall (rehearsal) of a fresh install"
[ -f "$SYS/policy.json" ] && [ "$(stat -f %Lp "$SYS/policy.json")" = 644 ]; check $? "policy.json is placed with mode 0644"
cmp -s "$SYS/policy.json" "$PSCRIPTS/baseline-policy.json"; check $? "... and it is the baseline of the package, byte for byte"
ST="$(policy_state "$SYS/policy.json")"
[ "$(json_get "$ST" 'd["state"]')" = valid ] && [ "$(json_get "$ST" 'all(v == "deny" for v in d["lanes"].values())')" = True ] && [ "$(json_get "$ST" 'd["local_only_default"]')" = True ] && [ "$(json_get "$ST" 'd["approvals"]')" = "{}" ]; check $? "the installed policy.json is accepted by the pipeline's loader: every external lane deny, local_only default true, no approval"
[ -f "$SYS/policy.required" ] && [ "$(stat -f %Lp "$SYS/policy.required")" = 644 ]; check $? "policy.required (the marker: a missing policy is a LOCK) is placed with mode 0644"
out_has 'would chown root:wheel .*policy.json' "policy.json is made root-owned (a rehearsal as a normal user says what it would chown)"
out_has 'would chown root:wheel .*policy.required' "policy.required is made root-owned"
out_has 'would chown -R root:wheel and chmod go-w on: .*'"$DEFAULT_SHORT"'.app' "the app, the LaunchAgent, the shim and the key are made root-owned"
[ "$(readlink "$SYS/releases/current")" = 0.2.0 ]; check $? "releases/current is a relative link to 0.2.0"
[ "$("$SYS/releases/current/venv/bin/python" x)" = "fake python of release 0.2.0: x" ]; check $? "... and the python of the release is reachable through it"
out_has 'signature OK, verified 4 files and 1 links' "the release was verified (signature and hashes) before it was switched on"
[ -x "$SYS/tools/provision_runtime.sh" ] && [ -x "$SYS/tools/provision_user_config.sh" ] && [ -x "$SYS/tools/migrate_owner_install.sh" ] && [ -f "$SYS/tools/bundle_id.sh" ] && [ -f "$SYS/tools/config.env.company.template" ]; check $? "the tools are installed under /Library/Application Support/MeetingCapture/tools"
[ "$(cat "$SYS/tools/RELEASE_BUNDLE_ID")" = "$DEFAULT_ID" ] && [ "$(cat "$SYS/tools/RELEASE_APP_SHORT_NAME")" = "$DEFAULT_SHORT" ] && [ "$(stat -f %Lp "$SYS/tools/RELEASE_APP_SHORT_NAME")" = 644 ]; check $? "the tools folder records what was installed (bundle id, app file name): scripts/uninstall.sh --company finds the agent and the app by them, whatever environment sudo gives it"
[ -z "$(ls -A "$SYS/tools" | grep '^\.')" ]; check $? "... and no temporary file is left in it"
[ -f "$SUPPORT/config.env" ] && grep -q '^SELF_NAME=Test Person$' "$SUPPORT/config.env" && grep -q '^ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-hong.gildong@example.com/Shared drives/Meetings$' "$SUPPORT/config.env"; check $? "the console user got a config.env: SELF_NAME from the directory service, ARCHIVE_DIR from the company Drive mount"
! grep -E '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' "$SUPPORT/config.env" | grep -v '^ARCHIVE_DIR=.*GoogleDrive-hong.gildong@example.com' | grep -q .; check $? "... without any other mail address"
out_has 'starts at the next login' "the app is NOT started by a fresh install (it starts at the next login, after the permission prompts)"
[ ! -s "$LOGS/launchctl.log" ]; check $? "launchd was not touched"
# an upgrade must not put the baseline over a policy that MDM delivered
sed 's/"revision": 1/"revision": 7/' "$SYS/policy.json" > "$WORK/policy-r7.json"; cp "$WORK/policy-r7.json" "$SYS/policy.json"
SUMP="$(shasum "$SYS/policy.json" | awk '{print $1}')"
post
rc_is 0 "postinstall again (the package is installed over itself)"
[ "$(shasum "$SYS/policy.json" | awk '{print $1}')" = "$SUMP" ]; check $? "an existing policy.json (revision 7) is NOT replaced by the baseline"
out_has 'policy.json exists already \(revision 7\): kept' "... and the output says which revision was kept"
rm -f "$SYS/policy.required"
post
[ -f "$SYS/policy.required" ]; check $? "a deleted marker is put back (a deleted policy.json with the marker is a lock, not freedom)"
rm -f "$SYS/policy.json"
post
cmp -s "$SYS/policy.json" "$PSCRIPTS/baseline-policy.json"; check $? "a Mac with no policy.json gets the baseline again"
# an existing config.env of the user is not touched
echo "SELF_NAME=Mine" > "$SUPPORT/config.env"
post
grep -q '^SELF_NAME=Mine$' "$SUPPORT/config.env" && [ "$(wc -l < "$SUPPORT/config.env" | tr -d ' ')" = 1 ]; check $? "an existing config.env of the user is never overwritten by the installer"
# agent that was loaded before: it is loaded again under the new plist (said, not done, in a rehearsal)
cat > "$SUPPORT/migration.state" <<'EOF'
migrated=2026-10-16T09:00:00+0900
agent_was_loaded=1
EOF
post
out_has 'rehearsal: would load the company LaunchAgent' "when the personal agent had been running, the company agent is loaded for the user (a rehearsal only says so)"
# upgrade to 0.2.1: current moves atomically, 0.2.0 is kept (N-1)
make_release "$SYSROOT/release/0.2.1" 0.2.1 full "$KEY_HEX"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.1" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$SYSROOT/out2" --version 0.2.1
cp -R "$SYSROOT/out2/work/payload/." "$SYSROOT/"
runx env MCAP_PKG_CONSOLE_USER="$ME" MCAP_PKG_CONSOLE_HOME="$H" /bin/bash "$SYSROOT/out2/work/scripts/postinstall" pkg / "$SYSROOT"
rc_is 0 "postinstall of the next version (0.2.1) over 0.2.0"
[ "$(readlink "$SYS/releases/current")" = 0.2.1 ] && [ -d "$SYS/releases/0.2.0" ]; check $? "current -> 0.2.1 and the previous release 0.2.0 is kept for the way back"
# as root (id and stat stubbed, chown only records what it was asked): everything the package brought is chowned root:wheel, before it is trusted
build_for_install 0.2.0
STUBS_SAVE="$STUBS"; STUBS="$STUBS_ROOT:$STUBS"
post STUB_REALNAME="Test Person" MCAP_PYTHON3="$WORK/rootpy/python3"
STUBS="$STUBS_SAVE"
rc_is 0 "postinstall as root (id and stat stubbed) on the staged tree"
grep -q "^chown -R root:wheel .*/Applications/$DEFAULT_SHORT.app .*/Library/LaunchAgents/$DEFAULT_ID.plist .*/usr/local/bin/mcap .*/release-signing.pub.pem\$" "$LOGS/chown.log"; check $? "as root: the app, the LaunchAgent, the shim and the public key are chowned root:wheel (chown -R root:wheel ...)"
grep -q "^chown root:wheel .*/\.policy\.json\.part\." "$LOGS/chown.log" && grep -q "^chown root:wheel .*/policy.required\$" "$LOGS/chown.log"; check $? "as root: policy.json (while it is still the temporary file, before the rename) and policy.required are chowned root:wheel"
grep -q "^chown -R root:wheel .*/releases/0.2.0\$" "$LOGS/chown.log"; check $? "as root: the release is chowned root:wheel by provision_runtime.sh before it is verified and switched on"
grep -q "^chown -R root:wheel .*/tools\$" "$LOGS/chown.log"; check $? "as root: the tools folder is chowned root:wheel"
out_lacks 'would chown' "as root nothing is only 'would'"
[ "$(readlink "$SYS/releases/current")" = 0.2.0 ] && [ "$(stat -f %Lp "$SYS/policy.json")" = 644 ]; check $? "... and the layout is the same as in the rehearsal: current -> 0.2.0, policy.json 0644"
# failures: a tampered release is not activated, a missing baseline stops before anything is touched, an incomplete payload stops
build_for_install 0.2.0
echo tampered >> "$SYS/releases/0.2.0/pipeline/mcap/__init__.py"
post
rc_is 20 "postinstall with a tampered release: exit 20"
out_has 'hash differs' "... naming the damage"
[ ! -e "$SYS/releases/current" ]; check $? "releases/current was NOT created for a release that does not verify"
[ -f "$SYS/policy.json" ] && [ -f "$SYS/policy.required" ]; check $? "(the policy is in place anyway: a Mac with a failed runtime still has its baseline lock)"
build_for_install 0.2.0
rm -f "$PSCRIPTS/baseline-policy.json"
post
rc_is 21 "postinstall without baseline-policy.json in the package: exit 21"
[ ! -e "$SYS/policy.json" ] && [ ! -e "$SYS/releases/current" ]; check $? "... before anything was touched (no policy, no current link)"
build_for_install 0.2.0
rm -rf "$SYSROOT/Applications/$DEFAULT_SHORT.app"
post
rc_is 15 "postinstall with an incomplete payload (no app): exit 15"
build_for_install 0.2.0
if [ "$AM_ROOT" = 0 ]; then
    runx /bin/bash "$PSCRIPTS/postinstall" pkg / /
    rc_is 13 "postinstall for the REAL system as a normal user: exit 13, nothing touched"
else
    echo "  skip the real-system refusal of postinstall (this test run is root)"
fi
stubs_clean; check $? "no forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "bundle identifier through the migration and the company package: a custom id names the agent, the package id and the installer organisation"
# ---------------------------------------------------------------------------------------------------------------
# migrate_owner_install.sh: the personal agent is the one named after the id of the personal app
pkg_env
fake_app_with_id "$H/Applications/$DEFAULT_SHORT.app" "$CUSTOM_ID"
mkdir -p "$H/Library/LaunchAgents" "$SUPPORT"
echo "agent plist" > "$H/Library/LaunchAgents/$CUSTOM_ID.plist"; echo "not ours" > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash scripts/migrate_owner_install.sh --home "$H"
out_has "per-user LaunchAgent: $H/Library/LaunchAgents/$CUSTOM_ID.plist \(LOADED" "migrate --detect looks for the agent named after the id of the personal app"
: > "$LOGS/launchctl.log"
runx env STUB_LAUNCHCTL_RC=0 /bin/bash scripts/migrate_owner_install.sh --home "$H" --backup
rc_is 0 "migrate --backup of a personal install with a custom id"
[ -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist.prev" ] && [ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "... it put THAT agent aside and left the other one alone"
grep -q "^launchctl bootout gui/$(id -u)/$CUSTOM_ID\$" "$LOGS/launchctl.log"; check $? "... and booted out gui/<uid>/<that id>"
grep -q "^label=$CUSTOM_ID\$" "$SUPPORT/migration.state"; check $? "... and recorded the label in migration.state (the app is gone by the time of the rollback)"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --rollback
[ -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ -d "$H/Applications/$DEFAULT_SHORT.app" ] && [ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist.prev" ]; check $? "... and --rollback (no app to read, no MCAP_BUNDLE_ID) puts that agent back with the recorded label"
# no app any more, only the agent: MCAP_BUNDLE_ID (the package passes its own id) says which one it is
rm -rf "$H/Applications/$DEFAULT_SHORT.app"; rm -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist" "$SUPPORT/migration.state.rolled-back" "$SUPPORT/config.env.bak"
runx env STUB_LAUNCHCTL_RC=3 MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/migrate_owner_install.sh --home "$H" --backup
[ -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist.prev" ]; check $? "without the app, MCAP_BUNDLE_ID names the agent to put aside"

# build_pkg.sh: the id of the packaged app names the LaunchAgent, the package and the installer organisation; the package scripts carry it
pkg_env; OUTD="$SYSROOT/out"
make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
APPF="$SYSROOT/$DEFAULT_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$DEFAULT_SHORT"; chmod 755 "$APPF/Contents/MacOS/$DEFAULT_SHORT"
runx MCAP_BUNDLE_ID='a.b;x' /bin/bash "$BP" --dry-run --out-dir "$OUTD"
rc_not 0 "build_pkg.sh refuses an invalid MCAP_BUNDLE_ID"
out_has 'not a valid bundle identifier' "... with the reason"
[ ! -e "$OUTD" ]; check $? "... and writes nothing"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash "$BP" --dry-run --out-dir "$OUTD"
out_has "bundle id: $CUSTOM_ID \(LaunchAgent label, package id $CUSTOM_ID.pkg, installer organisation com.example\)" "--dry-run says which id the package gets and what is derived from it"
out_has "--identifier $CUSTOM_ID.pkg " "... the pkgbuild identifier is <id>.pkg"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD"
rc_is 0 "build_pkg.sh with MCAP_BUNDLE_ID (the app given has no Info.plist)"
CUSTOM_AGENT="$OUTD/work/payload/Library/LaunchAgents/$CUSTOM_ID.plist"
[ "$(la_label "$CUSTOM_AGENT")" = "$CUSTOM_ID" ] && [ "$(plutil -extract AssociatedBundleIdentifiers.0 raw -o - "$CUSTOM_AGENT")" = "$CUSTOM_ID" ] && [ ! -e "$OUTD/work/payload/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "payload: the system LaunchAgent is named after the id and its Label equals it (no agent of the default id)"
grep -q "^pkgbuild .* --identifier $CUSTOM_ID.pkg " "$LOGS/pkgbuild.log"; check $? "pkgbuild --identifier <id>.pkg"
grep -q '<organization>com.example</organization>' "$OUTD/work/distribution.xml" && grep -q "id=\"$CUSTOM_ID.pkg\"" "$OUTD/work/distribution.xml" && ! grep -Eq '@[A-Z_]+@' "$OUTD/work/distribution.xml"; check $? "distribution.xml: the organisation is the id without its last label, the choice is <id>.pkg"
[ "$(cat "$OUTD/work/scripts/RELEASE_BUNDLE_ID")" = "$CUSTOM_ID" ]; check $? "package scripts: RELEASE_BUNDLE_ID is the id"
# the app that is packaged names itself: its own CFBundleIdentifier wins over MCAP_BUNDLE_ID
fake_app_with_id "$APPF" "com.example.from-app"
runx MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD" --app-identity "$APPID" --entitlements "$WORK/my-entitlements.plist"
rc_is 0 "build_pkg.sh with an app whose Info.plist says another id"
[ "$(la_label "$OUTD/work/payload/Library/LaunchAgents/com.example.from-app.plist")" = "com.example.from-app" ] && [ ! -e "$OUTD/work/payload/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ "$(cat "$OUTD/work/scripts/RELEASE_BUNDLE_ID")" = "com.example.from-app" ]; check $? "... the packaged app's id decides (agent, RELEASE_BUNDLE_ID)"
grep -q -- "--identifier com.example.from-app --sign $APPID " "$LOGS/codesign.log" && ! grep -q -- "--identifier $CUSTOM_ID " "$LOGS/codesign.log"; check $? "... and the signed copy carries it as the codesign --identifier"
stubs_clean; check $? "no forbidden program"

# preinstall and postinstall (rehearsal on a staged tree) of a package built with a custom id
export MCAP_BUNDLE_ID="$CUSTOM_ID"
build_for_install 0.2.0
unset MCAP_BUNDLE_ID
[ "$(cat "$PSCRIPTS/RELEASE_BUNDLE_ID")" = "$CUSTOM_ID" ] && [ -f "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ]; check $? "(premise) a package built with MCAP_BUNDLE_ID=$CUSTOM_ID, its payload laid down on the staged tree"
mkdir -p "$H/Library/LaunchAgents"; echo "agent plist" > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
pre
rc_is 0 "preinstall (custom id package) on a Mac with only a per-user agent of ANOTHER id"
out_has 'no personal install of .* found' "... that is not a personal install of this package's id: nothing is put aside"
[ -f "$H/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -e "$H/Library/LaunchAgents/$DEFAULT_ID.plist.prev" ]; check $? "... and the other agent stays where it is"
echo "agent plist" > "$H/Library/LaunchAgents/$CUSTOM_ID.plist"
pre
rc_is 0 "preinstall (custom id package) with a per-user agent named after the id of the package"
out_has 'a personal install of .* was found' "... it is found"
[ -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist.prev" ] && [ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ]; check $? "... and put aside (the app is gone: the id comes from the package)"
cp "$PSCRIPTS/RELEASE_BUNDLE_ID" "$WORK/RELEASE_BUNDLE_ID.keep"
for broken in missing invalid; do
    case "$broken" in missing) rm -f "$PSCRIPTS/RELEASE_BUNDLE_ID" ;; invalid) printf 'a.b;x\n' > "$PSCRIPTS/RELEASE_BUNDLE_ID" ;; esac
    pre
    rc_is 15 "preinstall with a $broken RELEASE_BUNDLE_ID: exit 15"
    out_has 'RELEASE_BUNDLE_ID' "... naming the file"
    post
    rc_is 15 "postinstall with a $broken RELEASE_BUNDLE_ID: exit 15"
done
cp "$WORK/RELEASE_BUNDLE_ID.keep" "$PSCRIPTS/RELEASE_BUNDLE_ID"
mv "$PSCRIPTS/bundle_id.sh" "$PSCRIPTS/bundle_id.sh.away"
pre
rc_is 15 "preinstall without bundle_id.sh in the package: exit 15"
post
rc_is 15 "postinstall without bundle_id.sh in the package: exit 15"
mv "$PSCRIPTS/bundle_id.sh.away" "$PSCRIPTS/bundle_id.sh"
post STUB_REALNAME="Test Person"
rc_is 0 "postinstall (custom id package): the payload's agent is the one named after the id"
out_has "LaunchAgents/$CUSTOM_ID.plist" "... it made THAT agent root-owned (the rehearsal says what it would chown)"
[ -f "$SYS/tools/bundle_id.sh" ] && [ -f "$SYS/tools/migrate_owner_install.sh" ]; check $? "... and the tools folder holds bundle_id.sh next to migrate_owner_install.sh"
# the tool in the tools folder (MDM runs it later) sources bundle_id.sh next to itself, and rolls back what preinstall put aside
runx env STUB_LAUNCHCTL_RC=3 /bin/bash "$SYS/tools/migrate_owner_install.sh" --home "$H" --rollback
rc_is 0 "the installed tool migrate_owner_install.sh finds bundle_id.sh next to itself"
[ -f "$H/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ ! -e "$H/Library/LaunchAgents/$CUSTOM_ID.plist.prev" ]; check $? "... and --rollback gives back the agent that preinstall put aside (the id is in migration.state)"
stubs_clean; check $? "no forbidden program"

# uninstall.sh --company: the system agent of the id of the company app
pkg_env
mkdir -p "$SYSROOT/Library/LaunchAgents"; fake_app_with_id "$SYSROOT/Applications/$DEFAULT_SHORT.app" "$CUSTOM_ID"; : > "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist"; : > "$SYSROOT/Library/LaunchAgents/$DEFAULT_ID.plist"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash scripts/uninstall.sh --company
rc_is 0 "uninstall.sh --company of a company app with a custom id (staged tree)"
[ ! -e "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ ! -d "$SYSROOT/Applications/$DEFAULT_SHORT.app" ] && [ -e "$SYSROOT/Library/LaunchAgents/$DEFAULT_ID.plist" ]; check $? "... it removed the agent named after the app's id and the app, and not another agent"
out_has "tccutil reset All $CUSTOM_ID" "... and the permission hint names that id"

# release.sh: the id it expects in the zip is the one build_app.sh will use (MCAP_BUNDLE_ID or the default), validated first
fresh_env base
runx MCAP_BUNDLE_ID='a.b;x' /bin/bash scripts/release.sh --scan-only
rc_not 0 "release.sh refuses an invalid MCAP_BUNDLE_ID before it scans or builds anything"
out_has 'not a valid bundle identifier' "... with the reason"
! grep -q 'BUNDLE_ID=' "$ROOT/scripts/release.sh" || ! grep -qE '^BUNDLE_ID="[^$]' "$ROOT/scripts/release.sh"; check $? "release.sh does not spell an id of its own"
grep -qF 'MCAP_BUNDLE_ID: ${{ vars.MCAP_BUNDLE_ID }}' "$ROOT/.github/workflows/release.yml"; check $? "release.yml hands the repository variable MCAP_BUNDLE_ID to scripts/release.sh (an unset variable is empty = the default id)"
grep -qF 'the repository variable `MCAP_BUNDLE_ID`' "$ROOT/docs/RELEASING.md"; check $? "docs/RELEASING.md tells a fork to set that repository variable (the workflow does not read anything else)"

# ---------------------------------------------------------------------------------------------------------------
section "app names through the company package and the migration: the app folder, the package files, the installer title, the personal app found by its id"
# ---------------------------------------------------------------------------------------------------------------
# the company package: the app folder, the package files, the installer title and the package scripts carry the names
pkg_env; OUTD="$SYSROOT/out"
make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
APPF="$SYSROOT/$CUSTOM_SHORT.app"; mkdir -p "$APPF/Contents/MacOS"; printf '#!/bin/sh\n' > "$APPF/Contents/MacOS/$CUSTOM_SHORT"; chmod 755 "$APPF/Contents/MacOS/$CUSTOM_SHORT"
runx env MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash "$BP" --dry-run --out-dir "$OUTD"
out_has "app names: $CUSTOM_NAME, /Applications/$CUSTOM_SHORT\\.app \\(installer title, app folder and program; package file $CUSTOM_SHORT-0\\.2\\.0\\.pkg\\)" "build_pkg.sh --dry-run names the app folder, the package file and the installer title"
runx env MCAP_APP_SHORT_NAME='a b' /bin/bash "$BP" --dry-run --out-dir "$OUTD"
rc_not 0 "build_pkg.sh refuses a bad MCAP_APP_SHORT_NAME"
out_has 'not a valid short app name' "... with the reason"
runx env MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD"
rc_is 0 "build_pkg.sh with the custom names (stub pkgbuild and productbuild)"
[ "$(tail -n 1 "$OUT")" = "$OUTD/$CUSTOM_SHORT-0.2.0.pkg" ] && [ -f "$OUTD/$CUSTOM_SHORT-0.2.0.pkg" ] && [ ! -e "$OUTD/$DEFAULT_SHORT-0.2.0.pkg" ]; check $? "... the package is <short name>-<version>.pkg"
[ -x "$OUTD/work/payload/Applications/$CUSTOM_SHORT.app/Contents/MacOS/$CUSTOM_SHORT" ] && [ ! -e "$OUTD/work/payload/Applications/$DEFAULT_SHORT.app" ]; check $? "... the payload holds /Applications/$CUSTOM_SHORT.app"
CUSTOM_AGENT="$OUTD/work/payload/Library/LaunchAgents/$DEFAULT_ID.plist"
[ "$(plutil -extract ProgramArguments.0 raw -o - "$CUSTOM_AGENT")" = "/Applications/$CUSTOM_SHORT.app/Contents/MacOS/$CUSTOM_SHORT" ]; check $? "... the system LaunchAgent starts that program"
[ "$(plutil -extract 0.RootRelativeBundlePath raw -o - "$OUTD/work/component.plist")" = "Applications/$CUSTOM_SHORT.app" ]; check $? "... and the component plist names that app"
grep -q "<title>$CUSTOM_NAME</title>" "$OUTD/work/distribution.xml" && ! grep -Eq '@[A-Z_]+@' "$OUTD/work/distribution.xml"; check $? "... the installer title is the human name"
[ "$(cat "$OUTD/work/scripts/RELEASE_APP_NAME")" = "$CUSTOM_NAME" ] && [ "$(cat "$OUTD/work/scripts/RELEASE_APP_SHORT_NAME")" = "$CUSTOM_SHORT" ]; check $? "... the package scripts carry RELEASE_APP_NAME and RELEASE_APP_SHORT_NAME"
runx env MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$DEFAULT_SHORT" /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$APPF" --out-dir "$OUTD"
rc_not 0 "build_pkg.sh with an --app that is not the app of the names given is refused (no program of that name inside)"
fake_app_with_names "$SYSROOT/FromPlist.app" "$CUSTOM_ID" "From Plist" "FromPlist"
runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$SYSROOT/FromPlist.app" --out-dir "$OUTD"
rc_is 0 "build_pkg.sh with an --app that tells its own names (no environment)"
[ "$(cat "$OUTD/work/scripts/RELEASE_APP_NAME")" = "From Plist" ] && [ -e "$OUTD/FromPlist-0.2.0.pkg" ] && [ -d "$OUTD/work/payload/Applications/FromPlist.app" ]; check $? "... the names come from its Info.plist: the package and the app folder follow"
grep -q '^    PATH=/usr/bin:/bin:/usr/sbin:/sbin MCAP_APP_NAME="From Plist" MCAP_APP_SHORT_NAME="FromPlist" \\$' "$OUTD/work/payload/usr/local/bin/mcap" && ! grep -Eq '@[A-Z_]+@' "$OUTD/work/payload/usr/local/bin/mcap" && /bin/sh -n "$OUTD/work/payload/usr/local/bin/mcap"; check $? "... and the shim of that package hands the pipeline those two names (no placeholder is left)"
stubs_clean; check $? "no forbidden program"

# a personal install under ANOTHER file name than the package's: found by its bundle id, put aside and rolled back (the state record names the app)
pkg_env
fake_app_with_names "$H/Applications/$CUSTOM_SHORT.app" "$DEFAULT_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
mkdir -p "$H/Library/LaunchAgents" "$SUPPORT"; echo "agent plist" > "$H/Library/LaunchAgents/$DEFAULT_ID.plist"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H"
out_has "app: $H/Applications/$CUSTOM_SHORT\\.app \\(not running\\)" "migrate --detect finds the personal app by its bundle id although its file name is not the package's ($DEFAULT_SHORT.app)"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --backup
rc_is 0 "migrate --backup puts that app aside"
[ -d "$H/Applications/$CUSTOM_SHORT.app.prev" ] && [ ! -e "$H/Applications/$CUSTOM_SHORT.app" ] && grep -q "^app=$CUSTOM_SHORT.app\$" "$SUPPORT/migration.state"; check $? "... as <name>.app.prev, and migration.state records the app's file name"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --rollback
[ -d "$H/Applications/$CUSTOM_SHORT.app" ] && [ ! -e "$H/Applications/$CUSTOM_SHORT.app.prev" ] && [ ! -e "$H/Applications/$DEFAULT_SHORT.app" ]; check $? "... and --rollback puts it back under the recorded name"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --backup
sed -i '' '/^app=/d' "$SUPPORT/migration.state"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --rollback
[ -d "$H/Applications/$CUSTOM_SHORT.app" ] && [ ! -e "$H/Applications/$CUSTOM_SHORT.app.prev" ]; check $? "... a state record of an older version (no app= line): the one .app.prev that is there is put back"
# the same old record with SEVERAL *.app.prev: nothing is guessed (--finish deletes the copy it picks), and the way out is the file name
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --backup
sed -i '' '/^app=/d' "$SUPPORT/migration.state"
mkdir -p "$H/Applications/Aaa.app.prev/Contents"
runx env STUB_LAUNCHCTL_RC=3 /bin/bash scripts/migrate_owner_install.sh --home "$H" --finish
rc_not 0 "--finish with a state record that names no app and two *.app.prev folders is refused"
out_has 'more than one \*\.app\.prev .*Aaa\.app\.prev '"$CUSTOM_SHORT"'\.app\.prev' "... naming both folders"
out_has 'MCAP_APP_SHORT_NAME' "... and the way out"
[ -d "$H/Applications/Aaa.app.prev" ] && [ -d "$H/Applications/$CUSTOM_SHORT.app.prev" ] && [ -f "$SUPPORT/migration.state" ]; check $? "... and nothing was deleted"
runx env STUB_LAUNCHCTL_RC=3 MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/migrate_owner_install.sh --home "$H" --finish
rc_is 0 "... with MCAP_APP_SHORT_NAME=$CUSTOM_SHORT the same --finish deletes that backup"
[ ! -e "$H/Applications/$CUSTOM_SHORT.app.prev" ] && [ -d "$H/Applications/Aaa.app.prev" ]; check $? "... and only that one: the other folder is not touched"

# ---------------------------------------------------------------------------------------------------------------
section "mdm/ea_status.sh: mcap status as the CONSOLE USER, one valid JSON line whatever happens"
# ---------------------------------------------------------------------------------------------------------------
EA="scripts/mdm/ea_status.sh"
make_fake_mcap() {   # make_fake_mcap <path> <mode: ok|fail|garbage|big|slow>   (the log folder is written into the script: env -i drops STUB_LOG)
    case "$2" in
        ok) cat > "$1" <<EOF
#!/bin/sh
# fake mcap: records who ran it and with what environment, then writes a status document to the --write path
[ "\$1" = status ] && [ "\$2" = "--write" ] || exit 2
{ echo "args: \$*"; echo "user: \$(id -un)"; echo "HOME=\$HOME"; env | grep -E '^(MCAP_|PYTHON|PATH=|LANG=)' | sort; } >> "$LOGS/mcap-ran.log"
printf '{\\n "schema": 1,\\n "pipeline_version": "0.2.0",\\n "profile": "company",\\n "sessions": {"staging": 0}\\n}\\n' > "\$3"
EOF
        ;;
        fail) printf '#!/bin/sh\nexit 1\n' > "$1" ;;
        garbage) printf '#!/bin/sh\necho "this is not json" > "$3"\n' > "$1" ;;
        big) printf '#!/bin/sh\nhead -c 30000 /dev/zero | tr "\\0" "x" | sed "s/^/{\\"a\\":\\"/; s/$/\\"}/" > "$3"\n' > "$1" ;;
        slow) printf '#!/bin/sh\nsleep 4\necho "{}" > "$3"\n' > "$1" ;;
    esac
    chmod 755 "$1"
}
pkg_env
make_fake_mcap "$WORK/fake-mcap-ok" ok
runx env MCAP_CONFIG=/evil/config.env MCAP_POLICY_PATH=/evil PYTHONPATH=/evil /bin/bash "$EA" --console-user "$ME" --home "$H" --mcap "$WORK/fake-mcap-ok"
rc_is 0 "ea_status.sh as the console user itself"
[ "$(wc -l < "$OUT" | tr -d ' ')" = 1 ] && [ "$(json_get "$(cat "$OUT")" 'd["schema"]')" = 1 ] && [ "$(json_get "$(cat "$OUT")" 'd["profile"]')" = company ]; check $? "stdout is exactly ONE line and it is the JSON of mcap status"
grep -q '^args: status --write ' "$LOGS/mcap-ran.log" && grep -q "^user: $ME\$" "$LOGS/mcap-ran.log"; check $? "mcap status --write ran as the console user"
grep -q "^HOME=$H\$" "$LOGS/mcap-ran.log" && grep -q '^PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$LOGS/mcap-ran.log"; check $? "... with the user's home and a clean PATH"
grep -Eq '^(MCAP_|PYTHON)' "$LOGS/mcap-ran.log"; [ $? -ne 0 ]; check $? "... and none of the caller's MCAP_* or PYTHON* variables"
ls "$H/tmp" | grep -q 'mcap-ea'; [ $? -ne 0 ]; check $? "the private work folder is removed afterwards"
runx /bin/bash "$EA" --console-user "$ME" --home "$H" --mcap "$WORK/fake-mcap-ok" --format jamf --out "$H/status-out.json"
head -c 8 "$OUT" | grep -q '^<result>' && tail -n 1 "$OUT" | grep -q '</result>$'; check $? "--format jamf wraps the line in <result>...</result>"
[ "$(json_get "$(cat "$H/status-out.json")" 'd["schema"]')" = 1 ] && [ "$(stat -f %Lp "$H/status-out.json")" = 644 ]; check $? "--out also writes the line to a file, mode 0644"
# as root (id stubbed): runs as the console user through sudo -u, in a folder that user owns
fresh_env pkg root
make_fake_mcap "$WORK/fake-mcap-ok" ok
runx /bin/bash "$EA" --console-user alice --home "$H" --mcap "$WORK/fake-mcap-ok"
rc_is 0 "ea_status.sh as root (id stubbed), console user alice"
grep -q "^sudo -u alice -H /usr/bin/env -i HOME=$H USER=alice LOGNAME=alice LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin $WORK/fake-mcap-ok status --write " "$LOGS/sudo.log"; check $? "root starts mcap status with sudo -u alice -H and a clean environment (env -i)"
grep -q '^chown 501 ' "$LOGS/chown.log"; check $? "the private work folder is handed to that user (chown <uid>) so only that user can write what root reads"
grep -q '^sudo -u alice -H /usr/bin/head -c 24577 ' "$LOGS/sudo.log"; check $? "root reads the file the user wrote WITH THE USER'S rights (sudo -u alice head -c <limit+1>): a link in that folder cannot make root read a root-only file"
[ "$(json_get "$(cat "$OUT")" 'd["schema"]')" = 1 ]; check $? "the status document comes back as one JSON line"
# an MDM agent that runs as root often has TMPDIR = root's own per-user temp folder: mode 0700, so the console user cannot get through it to a folder
# inside. The work folder must not be made there (every Mac would report status-failed).
mkdir -m 700 "$WORK/rootT-parent"; mkdir -m 700 "$WORK/rootT-parent/T"; mkdir -m 755 "$WORK/ea-tmp"
rm -f "$LOGS/mcap-ran.log"
runx env TMPDIR="$WORK/rootT-parent/T" MCAP_EA_TMPDIR="$WORK/ea-tmp" /bin/bash "$EA" --console-user alice --home "$H" --mcap "$WORK/fake-mcap-ok"
rc_is 0 "ea_status.sh as root with TMPDIR set to a folder below a 0700 parent"
[ "$(json_get "$(cat "$OUT")" 'd["schema"]')" = 1 ]; check $? "... still reports"
grep -q "^args: status --write $WORK/ea-tmp/mcap-ea\." "$LOGS/mcap-ran.log"; check $? "the work folder is made in the folder meant for it (/private/var/tmp, here MCAP_EA_TMPDIR), where the console user can get to it"
grep -q 'rootT-parent' "$LOGS/mcap-ran.log"; [ $? -ne 0 ]; check $? "... and NOT below TMPDIR (the 0700 per-user folder of the MDM agent)"
[ -z "$(ls -A "$WORK/ea-tmp")" ] && [ -z "$(ls -A "$WORK/rootT-parent/T")" ]; check $? "(the work folder is removed afterwards, nothing is left in either place)"
grep -Eq '^    WORK="\$\(mktemp -d "\$\{MCAP_EA_TMPDIR:-/private/var/tmp\}/mcap-ea\.XXXXXX"\)"' "$ROOT/scripts/mdm/ea_status.sh"; check $? "the default place as root is /private/var/tmp, whatever TMPDIR says (static check of the script)"
# every failure is still ONE valid JSON line with an error word, exit 0
fresh_env pkg
for variant in "fail:status-failed" "garbage:status-unreadable" "big:status-unreadable"; do
    make_fake_mcap "$WORK/fake-mcap-$variant" "${variant%%:*}"
    runx /bin/bash "$EA" --console-user "$ME" --home "$H" --mcap "$WORK/fake-mcap-$variant"
    rc_is 0 "ea_status.sh with a mcap that ${variant%%:*}s: exit 0"
    [ "$(cat "$OUT")" = "{\"schema\":1,\"error\":\"${variant##*:}\"}" ]; check $? "... prints the one-line error document ${variant##*:}"
done
make_fake_mcap "$WORK/fake-mcap-slow" slow
runx /bin/bash "$EA" --console-user "$ME" --home "$H" --mcap "$WORK/fake-mcap-slow" --timeout 1
[ "$(cat "$OUT")" = '{"schema":1,"error":"status-timeout"}' ]; check $? "a mcap that runs longer than the timeout is stopped: status-timeout"
runx /bin/bash "$EA" --console-user "$ME" --home "$H" --mcap /nonexistent/mcap
[ "$(cat "$OUT")" = '{"schema":1,"error":"mcap-missing"}' ]; check $? "no mcap (the package is not installed): mcap-missing"
runx /bin/bash "$EA" --console-user root --home "$H" --mcap "$WORK/fake-mcap-ok"
[ "$(cat "$OUT")" = '{"schema":1,"error":"no-console-user"}' ]; check $? "nobody at the console (root, loginwindow): no-console-user"
runx /bin/bash "$EA" --console-user nobody --home "$H" --mcap "$WORK/fake-mcap-ok"
rc_is 2 "as a normal user for ANOTHER user: refused (exit 2)"
out_has 'run this as root .* or as the console user' "... it cannot read another person's setup"
runx /bin/bash "$EA" --format xml
rc_is 2 "an unknown --format is refused"
stubs_clean; check $? "no forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "mdm/offboard_user.sh: a plan unless --apply; token revoke / token sync on the server; nothing deleted automatically"
# ---------------------------------------------------------------------------------------------------------------
OB="scripts/mdm/offboard_user.sh"
pkg_env
runx /bin/bash "$OB" --user alice@example.com
rc_is 0 "offboard_user.sh --user (plan)"
out_has 'PLAN for alice@example.com \(nothing is run' "the default is a plan"
out_has_plain 'revoke: sudo -u mcap-asr env PYTHONPATH=/Library/Application Support/MeetingCapture/releases/current/pipeline PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 /Library/Application Support/MeetingCapture/releases/current/venv/bin/python -m mcap.asr_server --config /Library/Application Support/MeetingCapture-asr/asr-server.json token revoke --user alice@example.com' "the revoke command: the admin CLI of the server, as the service user mcap-asr, with the fixed module path"
out_has_plain 'check: sudo -u mcap-asr .* token list' "... and the command to check it"
out_has 'Anthropic Console' "the hand steps: the Console key"
out_has 'Google Workspace' "... the Workspace account"
out_has 'NOTHING is deleted automatically' "... local data is NOT deleted automatically (the administrator's and legal's decision)"
out_has 'mcap forget <folder> --yes' "... mcap forget for one folder when that is decided"
out_has 'mcap asr-engines revoke --all --forget-secret --yes' "... and the consent and Keychain token of that Mac's user"
[ ! -s "$LOGS/sudo.log" ]; check $? "the plan ran nothing (no sudo call)"
printf 'bob\n# a comment\ncarol  # trailing comment\n' > "$WORK/active.txt"
runx /bin/bash "$OB" --allow-list "$WORK/active.txt"
rc_is 0 "offboard_user.sh --allow-list (plan)"
out_has_plain 'look first: sudo -u mcap-asr .* token sync --allow-list .*active.txt --dry-run' "the plan shows the server's own dry run first"
out_has_plain 'disable: sudo -u mcap-asr .* token sync --allow-list .*active.txt$' "... then the real sync"
runx /bin/bash "$OB"
rc_is 2 "neither --user nor --allow-list: refused"
runx /bin/bash "$OB" --user alice --allow-list "$WORK/active.txt"
rc_is 2 "both: refused"
runx /bin/bash "$OB" --user 'alice;rm -rf /'
rc_is 0 "a name with shell characters is only a NAME (the relay takes any printable label): the plan runs nothing"
grep -qF 'token revoke --user alice\;rm\ -rf\ /' "$OUT"; check $? "... and prints it as ONE quoted argument, never as shell text"
[ ! -s "$LOGS/sudo.log" ]; check $? "... without a single sudo call"
runx /bin/bash "$OB" --user '홍길동'
rc_is 0 "a Korean name can be offboarded (the runbook says --user <이름>)"
out_has 'PLAN for 홍길동' "... and the plan names the person"
runx /bin/bash "$OB" --user 'Hong Gildong'
rc_is 0 "a name with a space ('first last') can be offboarded"
for bad_name in $'a\tb' $'a\nb' $'a\001b' $'a\177b' '-foo' '--apply' '   ' $'\377\376' "$(printf 'x%.0s' $(seq 1 201))"; do
    runx /bin/bash "$OB" --user "$bad_name"
    rc_is 2 "a name that is not one printable line is refused: $(printf '%q' "$bad_name" | cut -c1-30)"
done
runx /bin/bash "$OB" --user ''
rc_is 2 "an empty name is refused"
: > "$WORK/empty-list.txt"; printf '# only a comment\n' > "$WORK/comment-list.txt"
runx /bin/bash "$OB" --allow-list "$WORK/empty-list.txt"
rc_is 2 "an EMPTY allow-list is refused (it would disable every user)"
runx /bin/bash "$OB" --allow-list "$WORK/comment-list.txt"
rc_is 2 "an allow-list with only comments is refused too"
runx /bin/bash "$OB" --allow-list "$WORK/missing-list.txt"
rc_is 2 "a missing allow-list is refused"
runx /bin/bash "$OB" --user alice --apply
rc_not 0 "--apply as a normal user is refused (it needs root or the service user)"
out_has 'needs root' "... saying so"
[ ! -s "$LOGS/sudo.log" ]; check $? "nothing was run"
# --apply as root (stubbed) with a fake server python that only logs
fresh_env pkg root
printf '#!/bin/sh\necho "server-cli $*" >> "%s/server-cli.log"\nexit 0\n' "$LOGS" > "$WORK/fake-server-python"; chmod 755 "$WORK/fake-server-python"
runx /bin/bash "$OB" --user alice --apply --server-python "$WORK/fake-server-python" --project "$WORK/fakeproject"
rc_is 0 "offboard_user.sh --user alice --apply as root (stubbed)"
grep -q "^sudo -u mcap-asr env PYTHONPATH=$WORK/fakeproject/pipeline PYTHONSAFEPATH=1 PYTHONNOUSERSITE=1 $WORK/fake-server-python -m mcap.asr_server --config /Library/Application Support/MeetingCapture-asr/asr-server.json token revoke --user alice\$" "$LOGS/sudo.log"; check $? "the revoke ran as the service user through sudo -u mcap-asr, with the fixed module path"
grep -q '^server-cli -m mcap.asr_server --config .* token revoke --user alice$' "$LOGS/server-cli.log"; check $? "the server admin CLI got token revoke --user alice"
[ "$(wc -l < "$LOGS/server-cli.log" | tr -d ' ')" = 1 ]; check $? "and nothing else (one command, no deletion)"
rm -f "$LOGS/server-cli.log" "$LOGS/sudo.log"
cat > "$WORK/fake-server-python-args" <<EOF
#!/bin/sh
for a in "\$@"; do printf 'arg:%s\n' "\$a" >> "$LOGS/server-args.log"; done
exit 0
EOF
chmod 755 "$WORK/fake-server-python-args"
runx /bin/bash "$OB" --user 'Hong Gildong; rm -rf /' --apply --server-python "$WORK/fake-server-python-args" --project "$WORK/fakeproject"
rc_is 0 "--apply for a name with spaces and shell characters"
grep -qx 'arg:--user' "$LOGS/server-args.log" && grep -qxF 'arg:Hong Gildong; rm -rf /' "$LOGS/server-args.log"; check $? "the server's admin CLI receives the whole name as ONE argument (nothing was split or interpreted)"
[ "$(grep -c '^arg:' "$LOGS/server-args.log")" = "$(grep -c . "$LOGS/server-args.log")" ] && [ "$(grep -cx 'arg:token' "$LOGS/server-args.log")" = 1 ]; check $? "... and it is one token revoke call"
rm -f "$LOGS/server-cli.log" "$LOGS/sudo.log"
runx /bin/bash "$OB" --allow-list "$WORK/active.txt" --apply --server-python "$WORK/fake-server-python" --project "$WORK/fakeproject"
rc_not 0 "--allow-list --apply without a terminal and without --yes is refused"
out_has 'needs a terminal to ask' "... saying so"
grep -c 'sync' "$LOGS/server-cli.log" | grep -q '^1$'; check $? "only the server's dry run had run (one call), not the real sync"
grep -q -- '--dry-run' "$LOGS/server-cli.log"; check $? "... and it was the --dry-run"
rm -f "$LOGS/server-cli.log"
runx /bin/bash "$OB" --allow-list "$WORK/active.txt" --apply --yes --server-python "$WORK/fake-server-python" --project "$WORK/fakeproject"
rc_is 0 "--allow-list --apply --yes"
[ "$(wc -l < "$LOGS/server-cli.log" | tr -d ' ')" = 2 ] && sed -n 1p "$LOGS/server-cli.log" | grep -q -- '--dry-run' && ! sed -n 2p "$LOGS/server-cli.log" | grep -q -- '--dry-run'; check $? "the server's dry run runs first, then the real token sync"
stubs_clean; check $? "no forbidden program"

# ---------------------------------------------------------------------------------------------------------------
section "uninstall.sh --company keeps data (and the policy); install.sh warns on a managed Mac and passes --client-only on"
# ---------------------------------------------------------------------------------------------------------------
UN="scripts/uninstall.sh"
build_for_install 0.2.0
post STUB_REALNAME="Test Person"
rc_is 0 "(premise) a staged company install"
mkdir -p "$SYSROOT/usr/local/bin" "$SUPPORT/local-meetings/2026-10/2026-10-14_1000_x" "$SUPPORT/sessions/2026-10-14_1100_zoom" "$APPLOGS"
echo "transcript" > "$SUPPORT/local-meetings/2026-10/2026-10-14_1000_x/transcript.md"
echo '{"schema":1}' > "$SUPPORT/sessions/2026-10-14_1100_zoom/session.json"
echo log > "$APPLOGS/app.log"
USERSUM="$(tree_sum "$H")"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company --dry-run
rc_is 0 "uninstall.sh --company --dry-run on the staged tree"
out_has 'would delete .*/Applications/'"$DEFAULT_SHORT"'.app' "the dry run lists the company app"
[ -d "$SYSROOT/Applications/$DEFAULT_SHORT.app" ] && [ -L "$SYS/releases/current" ]; check $? "... and deletes nothing"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "uninstall.sh --company on the staged tree"
[ ! -e "$SYSROOT/Applications/$DEFAULT_SHORT.app" ] && [ ! -e "$SYSROOT/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -e "$SYSROOT/usr/local/bin/mcap" ] \
  && [ ! -e "$SYS/releases" ] && [ ! -e "$SYS/tools" ] && [ ! -e "$SYS/release-signing.pub.pem" ]; check $? "the app, the system LaunchAgent, the shim, the releases, the tools and the release key are gone"
[ -f "$SYS/policy.json" ] && [ -f "$SYS/policy.required" ]; check $? "policy.json and policy.required are KEPT (MDM owns them)"
[ "$(tree_sum "$H")" = "$USERSUM" ]; check $? "every user's data is KEPT: config.env, sessions, local-meetings, logs, byte for byte"
[ -f "$SUPPORT/local-meetings/2026-10/2026-10-14_1000_x/transcript.md" ] && [ -f "$APPLOGS/app.log" ]; check $? "(the local archive and the logs are still there)"
out_has 'kept .*policy.json and policy.required' "the output says what was kept"
[ ! -s "$LOGS/launchctl.log" ]; check $? "a staged uninstall --company calls launchctl not at all (it has no personal per-user agent step any more, and a staged tree never touches launchd)"
# --company removes the COMPANY side only: the personal install that a rollback has just put back is not its business (sudo keeps HOME)
build_for_install 0.2.0
post STUB_REALNAME="Test Person"
legacy_files; mkdir -p "$SYSROOT/usr/local/bin"
echo "live" > "$SUPPORT/live-tested.confirmed"
PERSONAL_SUM="$(tree_sum "$H")"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company --dry-run
rc_is 0 "uninstall.sh --company --dry-run next to a personal install"
out_has 'left alone \(--company removes the company install only\)' "the dry run says that the personal install is left alone"
out_lacks "would delete $H/Applications/$DEFAULT_SHORT.app" "... and does not list it for deletion"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "uninstall.sh --company next to a restored personal install"
[ ! -e "$SYSROOT/Applications/$DEFAULT_SHORT.app" ] && [ ! -e "$SYSROOT/Library/LaunchAgents/$DEFAULT_ID.plist" ] && [ ! -e "$SYS/releases" ]; check $? "the company side is gone"
[ -f "$LA" ] && [ -d "$APPD" ] && [ -f "$SUPPORT/live-tested.confirmed" ]; check $? "the personal app, the per-user LaunchAgent plist and the live-test confirmation are STILL THERE"
[ "$(tree_sum "$H")" = "$PERSONAL_SUM" ]; check $? "... and nothing in the home changed, byte for byte"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --also-personal
rc_not 0 "--also-personal without --company is refused (without --company the personal install is removed anyway)"
[ -f "$LA" ] && [ -d "$APPD" ]; check $? "... and nothing was removed"
build_for_install 0.2.0
post STUB_REALNAME="Test Person"
legacy_files; echo "live" > "$SUPPORT/live-tested.confirmed"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company --also-personal
rc_is 0 "uninstall.sh --company --also-personal"
[ ! -e "$LA" ] && [ ! -e "$APPD" ] && [ ! -e "$SUPPORT/live-tested.confirmed" ] && [ ! -e "$SYSROOT/Applications/$DEFAULT_SHORT.app" ]; check $? "... removes the personal install as well (the old behaviour, now asked for)"
[ -f "$SUPPORT/config.env" ] && [ -f "$SUPPORT/sessions/2026-10-14_1000_zoom/session.json" ]; check $? "... and still keeps the data"
runx /bin/bash "$UN" --dry-run
rc_is 0 "uninstall.sh alone (the personal install) still plans to remove the personal LaunchAgent and app"
out_has 'LaunchAgent' "... as before"
# the documented rollback end to end (docs/MIGRATION.md 7): the package puts the personal install aside, the company install lands, then
# uninstall --company, then migrate --rollback: the personal install is back exactly as it was
build_for_install 0.2.0
legacy_files; echo "live" > "$SUPPORT/live-tested.confirmed"
SEQ_BEFORE="$(tree_sum "$H")"
pre
rc_is 0 "(rollback sequence) preinstall puts the personal install aside"
post STUB_REALNAME="Test Person"
rc_is 0 "(rollback sequence) postinstall installs the company side"
[ ! -e "$LA" ] && [ -e "$SYSROOT/Applications/$DEFAULT_SHORT.app" ]; check $? "(premise) the personal install is aside and the company install is on the Mac"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "(rollback sequence) uninstall.sh --company"
runx env STUB_LAUNCHCTL_RC=3 MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
rc_is 0 "(rollback sequence) migrate_owner_install.sh --rollback"
[ "$(tree_sum "$H" | grep -v 'migration.state\|config.env.bak')" = "$SEQ_BEFORE" ]; check $? "the personal install is back byte for byte: app, plist, config.env, live-test confirmation, data"
[ ! -e "$SYSROOT/Applications/$DEFAULT_SHORT.app" ] && [ -f "$SYS/policy.json" ]; check $? "... the company side is gone and the policy is kept"
# the WRONG order (rollback first, then uninstall --company) no longer destroys what the rollback restored
build_for_install 0.2.0
legacy_files; echo "live" > "$SUPPORT/live-tested.confirmed"
SEQ_BEFORE="$(tree_sum "$H")"
pre
post STUB_REALNAME="Test Person"
runx env STUB_LAUNCHCTL_RC=3 MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$ROOT/scripts/migrate_owner_install.sh" --home "$H" --rollback
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "(wrong order) uninstall.sh --company after the rollback"
[ "$(tree_sum "$H" | grep -v 'migration.state\|config.env.bak')" = "$SEQ_BEFORE" ]; check $? "... leaves the restored personal install exactly as the rollback made it"
# a foreign file at /usr/local/bin/mcap is not removed
build_for_install 0.2.0
post STUB_REALNAME="Test Person"
printf '#!/bin/sh\necho somebody elses mcap\n' > "$SYSROOT/usr/local/bin/mcap"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
grep -q 'somebody elses mcap' "$SYSROOT/usr/local/bin/mcap"; check $? "a /usr/local/bin/mcap that is not the shim of this install is left alone"
# a package built with another id and another app file name: --company finds the agent and the app by what the package recorded, with NO MCAP_* in the environment (sudo drops it)
custom_company_install() {   # a staged company install of a package built for $CUSTOM_ID and $CUSTOM_SHORT.app
    pkg_env; OUTD="$SYSROOT/out"
    make_release "$SYSROOT/release/0.2.0" 0.2.0 full "$KEY_HEX"
    fake_app_with_names "$SYSROOT/$CUSTOM_SHORT.app" "$CUSTOM_ID" "$CUSTOM_NAME" "$CUSTOM_SHORT"
    runx /bin/bash "$BP" --release-dir "$SYSROOT/release/0.2.0" --release-pubkey "$PUB_PEM" --app "$SYSROOT/$CUSTOM_SHORT.app" --out-dir "$OUTD"
    PSCRIPTS="$OUTD/work/scripts"; install_payload
    SYS="$SYSROOT/Library/Application Support/MeetingCapture"
    post STUB_REALNAME="Test Person"
    mkdir -p "$SYSROOT/usr/local/bin"
}
custom_company_install
rc_is 0 "(premise) a package built for $CUSTOM_ID and $CUSTOM_SHORT.app, installed on the staged tree"
[ "$(cat "$SYS/tools/RELEASE_BUNDLE_ID")" = "$CUSTOM_ID" ] && [ "$(cat "$SYS/tools/RELEASE_APP_SHORT_NAME")" = "$CUSTOM_SHORT" ] && [ -d "$SYSROOT/Applications/$CUSTOM_SHORT.app" ] && [ -f "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ]; check $? "(premise) the package recorded its id and its app file name, and put that app and that agent in place"
fake_app_with_names "$SYSROOT/Applications/Older.app" "$CUSTOM_ID" "Older" "Older"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company --dry-run
rc_is 0 "uninstall.sh --company --dry-run of that package, without MCAP_BUNDLE_ID and MCAP_APP_SHORT_NAME"
out_has "would delete $SYSROOT/Applications/$CUSTOM_SHORT\\.app" "... finds the app by the recorded file name"
out_has "would delete $SYSROOT/Library/LaunchAgents/$CUSTOM_ID\\.plist" "... and the agent by the recorded id"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "uninstall.sh --company of that package"
[ ! -e "$SYSROOT/Applications/$CUSTOM_SHORT.app" ] && [ ! -e "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ ! -e "$SYSROOT/usr/local/bin/mcap" ] && [ ! -e "$SYS/releases" ] && [ ! -e "$SYS/tools" ] && [ -f "$SYS/policy.json" ]; check $? "... the app, the agent, the shim, the releases and the tools are gone, the policy is kept"
out_has "NOTE: $SYSROOT/Applications/Older\\.app has the same bundle id" "... another app with the same id under another file name is named, not deleted by guess"
[ -d "$SYSROOT/Applications/Older.app" ]; check $? "... and it is still there"
out_has "tccutil reset All $CUSTOM_ID" "... and the permission hint names the recorded id"
# a package of an earlier version recorded nothing: with the wrong names the script must stop before it deletes the runtime, not print "done" about nothing
custom_company_install
rm -f "$SYS/tools/RELEASE_BUNDLE_ID" "$SYS/tools/RELEASE_APP_SHORT_NAME"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_not 0 "uninstall.sh --company with no record and neither the default app nor the default agent on the Mac: refused"
out_has 'no app at .*/Applications/'"$DEFAULT_SHORT"'\.app and no LaunchAgent at .*/'"$DEFAULT_ID"'\.plist' "... naming what it looked for"
out_has 'sudo env MCAP_BUNDLE_ID=<the id> MCAP_APP_SHORT_NAME=<the file name of the app, without \.app>' "... and how to give the names through sudo"
out_lacks 'done\.' "... and it does not say done"
[ -d "$SYSROOT/Applications/$CUSTOM_SHORT.app" ] && [ -f "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ -d "$SYS/releases" ] && [ -d "$SYS/tools" ] && [ -f "$SYSROOT/usr/local/bin/mcap" ]; check $? "... and nothing was deleted: the app, the agent, the releases, the tools and the shim are all still there"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company --dry-run
rc_not 0 "... the dry run refuses in the same way"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash "$UN" --company
rc_is 0 "with only MCAP_BUNDLE_ID=$CUSTOM_ID the one app in /Applications that has the id is the app"
[ ! -e "$SYSROOT/Applications/$CUSTOM_SHORT.app" ] && [ ! -e "$SYSROOT/Library/LaunchAgents/$CUSTOM_ID.plist" ] && [ ! -e "$SYS/releases" ] && [ ! -e "$SYS/tools" ]; check $? "... and it is removed with its agent, the releases and the tools"
runx env MCAP_SYSTEM_ROOT="$SYSROOT" /bin/bash "$UN" --company
rc_is 0 "a second run on a Mac with nothing left is a plain no-op, not a refusal"
if [ "$AM_ROOT" = 0 ]; then
    runx /bin/bash "$UN" --company
    rc_not 0 "uninstall.sh --company for the REAL system as a normal user: refused"
    out_has 'run it with sudo yourself. Nothing was changed' "... before anything is changed"
else
    echo "  skip the real-system refusal of uninstall.sh --company (this test run is root)"
fi
# install.sh on a managed Mac
fresh_env base
mkdir -p "$WORK/managed/Library/Application Support/MeetingCapture"; : > "$WORK/managed/Library/Application Support/MeetingCapture/policy.required"
runx env MCAP_SYSTEM_ROOT="$WORK/managed" /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
rc_is 0 "install.sh --dry-run on a Mac with policy.required still finishes (it only warns)"
out_has 'WARNING: this Mac is managed by an organisation policy' "install.sh warns that the Mac is policy-managed"
out_has 'root-owned company runtime \(docs/DEPLOY.md\)' "... and points at the company runtime and docs/DEPLOY.md"
runx env MCAP_SYSTEM_ROOT="$WORK/not-managed" /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent
out_lacks 'managed by an organisation policy' "no warning on a Mac without policy.json and policy.required"
runx /bin/bash scripts/install.sh --dry-run --no-build --no-launchagent --client-only --with-cloud
rc_is 0 "install.sh --client-only --with-cloud --dry-run"
out_has 'requirements.client.txt' "install.sh passes --client-only on to setup_python.sh (the client requirements are planned)"
out_has 'cloud +: truststore' "... and --with-cloud"
home_is_empty; check $? "none of these dry runs created anything"

# ---------------------------------------------------------------------------------------------------------------
section "scripts/asr_server/test_install_server.sh runs as part of this suite"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
runx /bin/bash scripts/asr_server/test_install_server.sh
rc_is 0 "scripts/asr_server/test_install_server.sh exits 0"
out_has 'install_server tests: [0-9]+ passed, 0 failed' "... with every one of its checks passed"
SRV_COUNT="$(sed -n 's/^install_server tests: \([0-9]*\) passed.*/\1/p' "$OUT" | tail -n 1)"
PASS=$((PASS + ${SRV_COUNT:-0}))        # its checks count in the total of this run
echo "  (its ${SRV_COUNT:-0} checks are included in the total below)"

# ---------------------------------------------------------------------------------------------------------------
section "docs of the company install: every command, flag, path and make target they name exists"
# ---------------------------------------------------------------------------------------------------------------
cat > "$WORK/doc_ops_check.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
docs = ["docs/DEPLOY.md", "docs/OPS_RUNBOOK.md", "docs/MIGRATION.md"]
cli = open(os.path.join(root, "pipeline/mcap/cli.py"), encoding="utf-8").read()
server = open(os.path.join(root, "pipeline/mcap/asr_server.py"), encoding="utf-8").read()
makefile = open(os.path.join(root, "Makefile"), encoding="utf-8").read()
problems = []
commands = ("process", "reprocess", "transcribe-file", "prune-audio", "usage", "doctor", "api-key", "asr-engines", "status", "sessions", "forget", "release")
for doc in docs:
    text = open(os.path.join(root, doc), encoding="utf-8").read()
    # 1. every file path under scripts/, config/, docs/, pipeline/ that the doc names exists (placeholders in <> or $ are skipped)
    for m in re.finditer(r"(?<![\w/.])((?:scripts|config|docs|pipeline)/[A-Za-z0-9_./-]*[A-Za-z0-9_])", text):
        path = m.group(1)
        if "<" in path or "$" in path or path.endswith("/"):
            continue
        if not os.path.exists(os.path.join(root, path)) and not any(path.startswith(p) for p in ("build/",)):
            problems.append("%s names %s, which does not exist" % (doc, path))
    # 2. every `mcap <command>` inside a code span or a fenced block is a real command of cli.py, with real flags
    spans = re.findall(r"`([^`\n]+)`", text) + re.findall(r"```[a-z]*\n(.*?)```", text, re.S)
    for span in spans:
        for line in span.splitlines():
            for m in re.finditer(r"(?:^|[\s$(])mcap ([a-z][a-z-]*)(.*)", line):
                cmd, rest = m.group(1), m.group(2)
                if cmd not in commands:
                    problems.append("%s: `mcap %s` is not a command of cli.py" % (doc, cmd))
                    continue
                for flag in re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", re.split(r"[`#;|]|&&", rest)[0]):
                    if '"%s"' % flag not in cli:
                        problems.append("%s: `mcap %s` has no option %s" % (doc, cmd, flag))
            for m in re.finditer(r"mcap\.asr_server .*?\b(token|enroll-code|audit|selfcheck)\b", line):
                if '"%s"' % m.group(1) not in server:
                    problems.append("%s: the server has no command %s" % (doc, m.group(1)))
    # 3. every `make <target>` exists
    for m in re.finditer(r"\bmake ([a-z][a-z-]*)", text):
        if not re.search(r"^%s:" % re.escape(m.group(1)), makefile, re.M):
            problems.append("%s: no make target %s" % (doc, m.group(1)))
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/doc_ops_check.py" "$ROOT" > "$WORK/doc_ops.out" 2>&1; check $? "DEPLOY.md, OPS_RUNBOOK.md and MIGRATION.md name only files, mcap commands and flags, server commands and make targets that exist"
[ -z "$(cat "$WORK/doc_ops.out")" ] || sed 's/^/        > /' "$WORK/doc_ops.out"
cat > "$WORK/doc_ops_topics.py" <<'EOF'
import os, re, sys
root = sys.argv[1]
def read(rel): return open(os.path.join(root, rel), encoding="utf-8").read()
deploy, ops, mig = read("docs/DEPLOY.md"), read("docs/OPS_RUNBOOK.md"), read("docs/MIGRATION.md")
problems = []
def need(cond, text):
    if not cond: problems.append(text)
for kw, why in (("build_pkg.sh", "the package script"), ("provision_runtime.sh", "the release activation"), ("make_hash_lock.sh", "the hash lock"), ("make_policy.sh", "the policy tool"),
                ("provision_user_config.sh", "the user config"), ("ea_status.sh", "the MDM extension attribute"), ("offboard_user.sh", "the offboarding"),
                ("--require-hashes", "pip --require-hashes"), ("--no-deps", "pip --no-deps"), ("hostArchitectures", "the arm64 guard"), ("14.4", "the macOS guard"),
                ("MANIFEST.json", "the manifest"), ("Ed25519", "the signature algorithm"), ("policy.required", "the marker"), ("releases/current", "the current link"),
                ("공증", "notarization is named"), ("관리자 작업", "and marked as an administrator action"), ("[미검증]", "unverified items are marked")):
    need(kw in deploy, "DEPLOY.md must mention %s (%r)" % (why, kw))
for kw, why in (("fdesetup authrestart", "the FileVault restart"), ("token revoke", "token revocation"), ("--daily", "the daily audit"), ("--allow-list", "the offboarding sync"),
                ("mcap forget", "forget"), ("--recording-off", "the recording kill switch"), ("min_pipeline_version", "the version order"), ("자동으로 지우지 않는다", "no automatic deletion"),
                ("STATUS_INCLUDE_USAGE", "the usage switch"), ("이전 리비전", "rollback by the previous revision")):
    need(kw in ops, "OPS_RUNBOOK.md must mention %s (%r)" % (why, kw))
for kw, why in (("--rehearse", "the rehearsal"), ("--backup", "the backup"), ("--rollback", "the rollback"), ("--finish", "the finish"), ("app.lock", "the single instance lock"),
                ("마이크와 시스템 오디오 녹음 권한을 다시 물어요", "the Korean permission note"), ("uninstall.sh --company", "removing the company side")):
    need(kw in mig, "MIGRATION.md must mention %s (%r)" % (why, kw))
for kw, why in (("--company", "uninstall --company"), ("--client-only", "the client-only venv"), ("make pkg", "the pkg target")):
    need(kw in deploy, "DEPLOY.md must mention %s (%r)" % (why, kw))
print("\n".join(problems)); sys.exit(1 if problems else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/doc_ops_topics.py" "$ROOT" > "$WORK/doc_ops_topics.out" 2>&1; check $? "the company docs cover the commands, guards, owner actions and unverified items they must"
[ -z "$(cat "$WORK/doc_ops_topics.out")" ] || sed 's/^/        > /' "$WORK/doc_ops_topics.out"
# the scripts never RUN signing-chain or network tools they only print (notarytool, stapler), never touch the Keychain, never open a connection
cat > "$WORK/no_forbidden_calls.py" <<'EOF'
import os, re, sys
root = sys.argv[1]
files = ["scripts/build_pkg.sh", "scripts/pkg/preinstall", "scripts/pkg/postinstall", "scripts/provision_runtime.sh", "scripts/provision_user_config.sh",
         "scripts/migrate_owner_install.sh", "scripts/bundle_id.sh", "scripts/make_policy.sh", "scripts/make_hash_lock.sh", "scripts/mdm/ea_status.sh", "scripts/mdm/offboard_user.sh"]
# a forbidden program as the first word of a command (after ; & | ( ` $( or at the start of a line), outside comments
word = re.compile(r"(?:^|[;&|(`]|\$\()\s*(?:sudo\s+(?:-\S+\s+\S+\s+)*)?(security|notarytool|stapler|spctl|curl|wget|ssh|scp|nc|telnet|xcrun\s+(?:notarytool|stapler|altool))\b")
problems = []
for rel in files:
    for no, line in enumerate(open(os.path.join(root, rel), encoding="utf-8"), 1):
        text = line.strip()
        if text.startswith("#"):
            continue
        if word.search(text):
            problems.append("%s:%d runs a forbidden program: %s" % (rel, no, text[:100]))
build = open(os.path.join(root, "scripts/build_pkg.sh"), encoding="utf-8").read()
if not re.search(r'echo "\[build_pkg\]\s+xcrun notarytool submit', build) or not re.search(r'echo "\[build_pkg\]\s+xcrun stapler staple', build):
    problems.append("build_pkg.sh no longer PRINTS the notarytool and stapler commands for the owner")
print("\n".join(problems)); sys.exit(1 if problems else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/no_forbidden_calls.py" "$ROOT" > "$WORK/no_forbidden.out" 2>&1; check $? "no new script RUNS security, notarytool, stapler, curl, wget, ssh, scp or nc (notarytool and stapler are only printed for the owner)"
[ -z "$(cat "$WORK/no_forbidden.out")" ] || sed 's/^/        > /' "$WORK/no_forbidden.out"
# the plan of make_hash_lock.sh needs no network: it finishes at once even when every connection would fail
fresh_env base
runx env HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 /bin/bash scripts/make_hash_lock.sh
rc_is 0 "make_hash_lock.sh (plan) with a dead proxy still finishes: it opens no connection"

# ---------------------------------------------------------------------------------------------------------------
section "Makefile: the new targets and a lint that covers the new scripts"
# ---------------------------------------------------------------------------------------------------------------
fresh_env base
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n pkg ARGS=--dry-run ) > "$OUT" 2>&1; RC=$?
out_has 'scripts/build_pkg.sh --dry-run' "make pkg ARGS=... runs scripts/build_pkg.sh with the arguments"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n policy ARGS="--revision 2" ) > "$OUT" 2>&1; RC=$?
out_has 'scripts/make_policy.sh --revision 2' "make policy ARGS=... runs scripts/make_policy.sh"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n hash-lock ) > "$OUT" 2>&1; RC=$?
out_has 'scripts/make_hash_lock.sh' "make hash-lock runs scripts/make_hash_lock.sh (a plan unless ARGS=--apply)"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make help ) > "$OUT" 2>&1; RC=$?
out_has 'make pkg ' "make help lists pkg"
out_has 'make policy ' "... policy"
out_has 'make hash-lock ' "... hash-lock"
out_has 'Company: +make hash-lock' "... and the company order line"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make lint ) > "$OUT" 2>&1; RC=$?
rc_is 0 "make lint (bash -n, shellcheck when installed) passes for every script"
out_has 'bash -n ok: scripts/pkg/preinstall' "make lint covers the package scripts (preinstall)"
out_has 'bash -n ok: scripts/mdm/ea_status.sh' "... the MDM scripts"
out_has 'bash -n ok: scripts/provision_runtime.sh' "... and the new top-level scripts"

# <<< W8b company packaging tests (end)

# <<< dmg installer tests (start): fetch_python_runtime.sh, build_dmg.sh, first_run_install.sh and the parity of the Swift side
# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: stubs and fixtures (a fake Python runtime archive, no network, no real dmg)"
# ---------------------------------------------------------------------------------------------------------------
# Never real here: curl (a stub that copies a fixture or answers a HEAD request), hdiutil (a stub that copies the folder it was given), codesign (the
# stub of the signing tests), the Python runtime (a shell script), setup_python.sh (a fake that records its arguments), the keychain (security is
# a stub that logs and is never expected to be called), open, defaults, sw_vers, sysctl, uname, df (answers by variable). The one real-hdiutil
# smoke test runs only with MCAP_TEST_REAL_HDIUTIL=1.
DMG_FIX="$WORK/dmg-fixtures"
mkdir -p "$DMG_FIX/rt-src/python/bin" "$DMG_FIX/rt-src/python/lib"
cat > "$DMG_FIX/rt-src/python/bin/python3" <<'EOF'
#!/bin/sh
# fake bundled python: the version check of the helper (-c ...) succeeds
case "$1" in
    --version) echo "Python 3.12.0" ;;
esac
exit 0
EOF
chmod 755 "$DMG_FIX/rt-src/python/bin/python3"
echo "not a real library" > "$DMG_FIX/rt-src/python/lib/libpython3.12.txt"
tar -czf "$DMG_FIX/python-runtime.tar.gz" -C "$DMG_FIX/rt-src" python
RT_SHA="$(shasum -a 256 "$DMG_FIX/python-runtime.tar.gz" | awk '{ print $1 }')"
write_lock() {   # write_lock FILE URL SHA256
    printf 'PYTHON_SERIES=3.12\nTARGET=aarch64-apple-darwin\nFLAVOR=install_only\nURL=%s\nSHA256=%s\n' "$2" "$3" > "$1"
}
# a runtime whose python does not run (or is older than 3.12): every -c call, the version probe of the helper, fails
mkdir -p "$DMG_FIX/old-src/python/bin"
printf '#!/bin/sh\ncase "$1" in -c) exit 1 ;; esac\nexit 0\n' > "$DMG_FIX/old-src/python/bin/python3"
chmod 755 "$DMG_FIX/old-src/python/bin/python3"
tar -czf "$DMG_FIX/python-old.tar.gz" -C "$DMG_FIX/old-src" python
OLD_RT_SHA="$(shasum -a 256 "$DMG_FIX/python-old.tar.gz" | awk '{ print $1 }')"
write_lock "$DMG_FIX/ok.lock" "https://example.invalid/cpython-install_only.tar.gz" "$RT_SHA"
write_lock "$DMG_FIX/wrong-sha.lock" "https://example.invalid/cpython-install_only.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000"
write_lock "$DMG_FIX/http.lock" "http://example.invalid/cpython-install_only.tar.gz" "$RT_SHA"
# an archive with a ".." member and one without python/bin/python3
"$PYTHON_FOR_TESTS" - "$DMG_FIX" <<'EOF'
import io, os, sys, tarfile
d = sys.argv[1]
def make(name, members):
    with tarfile.open(os.path.join(d, name), "w:gz") as t:
        for member, body in members:
            info = tarfile.TarInfo(member); info.size = len(body); info.mode = 0o755
            t.addfile(info, io.BytesIO(body))
make("evil.tar.gz", [("python/bin/python3", b"#!/bin/sh\n"), ("../evil", b"x")])
make("nopython.tar.gz", [("python/lib/readme", b"nothing\n")])
EOF
for a in evil nopython; do write_lock "$DMG_FIX/$a.lock" "https://example.invalid/$a.tar.gz" "$(shasum -a 256 "$DMG_FIX/$a.tar.gz" | awk '{ print $1 }')"; done
# a hash lock the way make_hash_lock.sh writes it: exactly the pins of pipeline/requirements.lock.txt (made-up hashes: nothing is installed here)
awk -v h="$RT_SHA" '/^[A-Za-z0-9][A-Za-z0-9._-]*==/ { printf "%s \\\n    --hash=sha256:%s\n", $1, h }' "$ROOT/pipeline/requirements.lock.txt" > "$DMG_FIX/hash-lock.txt"
printf 'numpy==2.5.3 \\\n    --hash=sha256:%s\n' "$RT_SHA" > "$DMG_FIX/hash-lock-partial.txt"                                   # one pin only: what the first fixture of these tests was
sed 's/^numpy==2.5.3 /numpy==2.5.4 /' "$DMG_FIX/hash-lock.txt" > "$DMG_FIX/hash-lock-bumped.txt"                                    # a version bump nobody re-locked
{ cat "$DMG_FIX/hash-lock.txt"; printf 'leftpad==1.0.0 \\\n    --hash=sha256:%s\n' "$RT_SHA"; } > "$DMG_FIX/hash-lock-extra.txt"      # a pin the requirements do not have
printf 'numpy==2.5.3\n' > "$DMG_FIX/not-a-hash-lock.txt"

STUBS_FETCH="$WORK/stubs-fetch"; mkdir -p "$STUBS_FETCH"; cp "$STUBS_BASE"/* "$STUBS_FETCH"/
cat > "$STUBS_FETCH/curl" <<'EOF'
#!/bin/sh
# fake curl for the download of the runtime: logs the command line and copies the fixture named by $STUB_CURL_BODY to the --output file
echo "curl $*" >> "${STUB_LOG:?}/curl.log"
out=""
while [ $# -gt 0 ]; do
    case "$1" in --output|-o) out="$2"; shift ;; esac
    shift
done
[ -z "${STUB_CURL_RC:-}" ] || exit "$STUB_CURL_RC"
[ -n "${STUB_CURL_BODY:-}" ] && [ -n "$out" ] || { echo "stub curl: nothing to copy" >&2; exit 22; }
cp "$STUB_CURL_BODY" "$out"
exit 0
EOF
chmod +x "$STUBS_FETCH/curl"

STUBS_DMG="$WORK/stubs-dmg"; mkdir -p "$STUBS_DMG"; cp "$STUBS_SIGN"/* "$STUBS_DMG"/
cat > "$STUBS_DMG/hdiutil" <<'EOF'
#!/bin/sh
# fake hdiutil: `create` copies the folder it was given to $STUB_STATE/dmg-root (so the test can look at the layout) and writes a small file at the output path
echo "hdiutil $*" >> "${STUB_LOG:?}/hdiutil.log"
case "$1" in
    create)
        src=""; vol=""; out=""
        for out; do :; done
        while [ $# -gt 0 ]; do
            case "$1" in -srcfolder) src="$2"; shift ;; -volname) vol="$2"; shift ;; esac
            shift
        done
        [ -z "${STUB_HDIUTIL_FAIL:-}" ] || { echo "stub hdiutil: create failed" >&2; exit 1; }
        rm -rf "${STUB_STATE:?}/dmg-root"
        /usr/bin/ditto "$src" "$STUB_STATE/dmg-root"
        printf 'stub disk image of %s\n' "$vol" > "$out"
        exit 0 ;;
    verify) exit 0 ;;
    *) echo "FORBIDDEN hdiutil $*" >> "${STUB_LOG:?}/forbidden.log"; exit 99 ;;
esac
EOF
chmod +x "$STUBS_DMG/hdiutil"
fresh_dmg_env() { fresh_env sign; STUBS="$STUBS_DMG"; }
dmgbuild() { runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" "$@"; }

# a small project root for the layout tests: bytecode, a tests folder and a file that looks like a Mach-O binary (it must be signed, the bytecode and the tests must not travel)
MINI="$WORK/dmg-mini"
mkdir -p "$MINI/pipeline/mcap/__pycache__" "$MINI/pipeline/mcap/tests" "$MINI/config" "$MINI/dmg"
printf 'x = 1\n' > "$MINI/pipeline/mcap/__init__.py"
printf 'junk' > "$MINI/pipeline/mcap/__pycache__/x.cpython-312.pyc"
printf 'def test(): pass\n' > "$MINI/pipeline/mcap/tests/test_x.py"
printf '\317\372\355\376\007\000\000\001fake mach-o body' > "$MINI/pipeline/mcap/native.so"
for f in requirements.lock.txt requirements-silero.txt requirements.client.txt; do cp "$ROOT/pipeline/$f" "$MINI/pipeline/$f"; done
for f in note_prompt.md cleanup_prompt.md verify_prompt.md vocabulary.txt config.env.example; do cp "$ROOT/config/$f" "$MINI/config/$f"; done
cp "$ROOT/dmg/README-install.txt" "$MINI/dmg/README-install.txt"
printf '9.9.9\n' > "$MINI/VERSION"
ok "fixtures: a runtime archive (sha256 ${RT_SHA:0:12}...), five lock files, a small project root"

# The app's OWN parser (FirstRun.parseBundleComponents / parseInstalled) reads what the scripts really wrote: `<short name> selftest-firstrun`. It needs the built app
# (make build; make test-swift builds it first): without it the check is skipped with a note, and the text checks of doc_dmg.py below are all that is left.
APP_BIN_REAL="${MCAP_TEST_BUILD_DIR:-$ROOT/build}/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT"          # MCAP_TEST_BUILD_DIR: where make test-swift BUILD_DIR=... built it
firstrun_contract() {   # firstrun_contract <name> <components.json> [<components-installed.json>]: sets OUT and RC (the caller saves and restores its own), or returns 1 when there is no built app
    if [ ! -x "$APP_BIN_REAL" ]; then echo "  (skipped: no built app at $APP_BIN_REAL, run make build first, or set MCAP_TEST_BUILD_DIR to the build dir of make test-swift: $1)"; return 1; fi
    N=$((N + 1)); OUT="$WORK/out.$N.txt"
    if [ -n "${3:-}" ]; then "$APP_BIN_REAL" selftest-firstrun --components "$2" --installed "$3" > "$OUT" 2>&1; RC=$?
    else "$APP_BIN_REAL" selftest-firstrun --components "$2" > "$OUT" 2>&1; RC=$?; fi
    return 0
}

# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: scripts/python-runtime.lock and fetch_python_runtime.sh"
# ---------------------------------------------------------------------------------------------------------------
grep -q '^URL=PENDING$' "$ROOT/scripts/python-runtime.lock" && grep -q '^SHA256=PENDING$' "$ROOT/scripts/python-runtime.lock"; check $? "the lock file in the repository has URL=PENDING and SHA256=PENDING (the owner fills them once)"
grep -q '^TARGET=aarch64-apple-darwin$' "$ROOT/scripts/python-runtime.lock" && grep -q '^FLAVOR=install_only$' "$ROOT/scripts/python-runtime.lock" && grep -q '^PYTHON_SERIES=3.12$' "$ROOT/scripts/python-runtime.lock"; check $? "... for CPython 3.12, aarch64-apple-darwin, install_only"
fresh_env base; STUBS="$STUBS_FETCH"
runx /bin/bash scripts/fetch_python_runtime.sh --out-dir "$H/rt"
rc_is 2 "fetch_python_runtime.sh refuses a PENDING lock file (exit 2)"
out_has 'PENDING' "... with a message that names PENDING"
out_has 'docs/DISTRIBUTE.md section 2' "... and where to read how to fill it"
[ ! -e "$H/rt" ] && [ ! -s "$LOGS/curl.log" ]; check $? "... before anything was written or downloaded"
runx /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock"
rc_is 2 "--out-dir is required"
runx /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/http.lock" --out-dir "$H/rt"
rc_is 2 "an http address is refused"
out_has 'https' "... and the message says why"
runx /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock" --out-dir "$H/rt" --dry-run
rc_is 0 "--dry-run exits 0"
out_has 'dry-run\] source +: https://example.invalid/cpython-install_only.tar.gz' "... prints the address"
out_has "dry-run\] sha256 +: $RT_SHA" "... and the checksum it will insist on"
[ ! -e "$H/rt" ] && [ ! -s "$LOGS/curl.log" ]; check $? "... and connects to nothing and writes nothing"
runx STUB_CURL_BODY="$DMG_FIX/python-runtime.tar.gz" /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock" --out-dir "$H/rt"
rc_is 0 "a download whose sha256 matches the lock is kept"
cmp -s "$H/rt/python-runtime.tar.gz" "$DMG_FIX/python-runtime.tar.gz"; check $? "... as DIR/python-runtime.tar.gz"
out_has "^$RT_SHA  $H/rt/python-runtime.tar.gz\$" "... and stdout is '<sha256>  <path>'"
grep -q -- "--proto =https" "$LOGS/curl.log" && grep -q -- "--tlsv1.2" "$LOGS/curl.log" && grep -q -- "--proto-redir =https" "$LOGS/curl.log"; check $? "curl runs with --proto =https --tlsv1.2 --proto-redir =https"
grep -q -- "https://example.invalid/cpython-install_only.tar.gz" "$LOGS/curl.log"; check $? "... against the address of the lock file"
[ "$(ls -A "$H/rt")" = "python-runtime.tar.gz" ]; check $? "no temporary file is left in the output folder"
[ -z "$(find "$H" -mindepth 1 -not -path "$H/tmp" -not -path "$H/rt" -not -path "$H/rt/*" 2>/dev/null)" ] && [ -z "$(ls -A "$H/tmp")" ]; check $? "nothing was written outside the output folder (not in HOME, not in the temp folder)"
runx STUB_CURL_BODY="$DMG_FIX/python-runtime.tar.gz" /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock" --out-dir "$H/rt"
rc_is 0 "a second run succeeds"
out_has 'already there with the right checksum' "... and downloads nothing"
[ "$(grep -c '^curl ' "$LOGS/curl.log")" = 1 ]; check $? "curl was called once in total"
fresh_env base; STUBS="$STUBS_FETCH"
runx STUB_CURL_BODY="$DMG_FIX/python-runtime.tar.gz" /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/wrong-sha.lock" --out-dir "$H/rt"
rc_is 1 "a sha256 mismatch is refused (exit 1)"
out_has 'MISMATCH' "... and says so"
[ -z "$(ls -A "$H/rt")" ]; check $? "... the download is deleted and nothing is kept"
fresh_env base; STUBS="$STUBS_FETCH"
runx STUB_CURL_BODY="$DMG_FIX/evil.tar.gz" /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/evil.lock" --out-dir "$H/rt"
rc_is 1 "an archive with a '..' member is refused even with the right checksum"
[ -z "$(ls -A "$H/rt")" ]; check $? "... and nothing is kept"
runx STUB_CURL_BODY="$DMG_FIX/nopython.tar.gz" /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/nopython.lock" --out-dir "$H/rt"
rc_is 1 "an archive without python/bin/python3 is refused"
runx STUB_CURL_RC=22 /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock" --out-dir "$H/rt"
rc_is 1 "a failed download is an error"
[ -z "$(ls -A "$H/rt")" ]; check $? "... that leaves nothing behind"
fresh_env base; STUBS="$STUBS_FETCH"
runx /bin/bash scripts/fetch_python_runtime.sh --lock "$DMG_FIX/ok.lock" --out-dir "$H/rt" --from-file "$DMG_FIX/python-runtime.tar.gz"
rc_is 0 "--from-file uses a local copy (same checks)"
[ ! -s "$LOGS/curl.log" ] && cmp -s "$H/rt/python-runtime.tar.gz" "$DMG_FIX/python-runtime.tar.gz"; check $? "... without any download"

# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: build_dmg.sh refusals and the plan"
# ---------------------------------------------------------------------------------------------------------------
fresh_dmg_env
dmgbuild /bin/bash scripts/build_dmg.sh
rc_is 2 "build_dmg.sh refuses the PENDING lock file of the repository (exit 2)"
out_has 'PENDING' "... with a message that names PENDING"
out_has 'fetch_python_runtime.sh' "... and the script that fetches the runtime"
[ ! -e "$H/build" ] && [ ! -s "$LOGS/codesign.log" ] && [ ! -s "$LOGS/hdiutil.log" ]; check $? "... before anything was built, signed or packed"
dmgbuild /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock"
rc_is 2 "a missing runtime archive is refused"
out_has 'runtime archive is missing' "... and the message says so"
dmgbuild /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/wrong-sha.lock" --runtime "$DMG_FIX/python-runtime.tar.gz"
rc_is 2 "a runtime whose sha256 is not the one of the lock file is refused"
out_has 'is not the one in' "... and the message says so"
[ ! -e "$H/build" ]; check $? "... before anything was built"
dmgbuild /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --hash-lock "$DMG_FIX/not-a-hash-lock.txt"
rc_is 2 "--hash-lock with a file that has no --hash=sha256: lines is refused"
# the comparison itself (build_dmg.sh calls it; the helper's step 3 makes the same one): no venv, no network, no Apple silicon Mac needed
runx /bin/bash scripts/setup_python.sh --check-hash-lock "$ROOT/pipeline/requirements.lock.txt" "$DMG_FIX/hash-lock.txt"
rc_is 0 "setup_python.sh --check-hash-lock accepts a lock with exactly the pins of the requirement file"
runx /bin/bash scripts/setup_python.sh --check-hash-lock "$ROOT/pipeline/requirements.lock.txt" "$DMG_FIX/hash-lock-bumped.txt"
rc_is 1 "... refuses a lock after a version bump nobody re-locked"
out_has 'numpy: the hash lock has 2\.5\.4, the requirement file 2\.5\.3' "... and names the pin with both versions"
runx /bin/bash scripts/setup_python.sh --check-hash-lock "$ROOT/pipeline/requirements.lock.txt" "$DMG_FIX/not-a-hash-lock.txt"
rc_is 1 "... refuses a file without --hash=sha256: lines"
runx /bin/bash scripts/setup_python.sh --check-hash-lock "$ROOT/pipeline/requirements.lock.txt" "$DMG_FIX/no-such-lock.txt"
rc_is 1 "... refuses a file that does not exist"
[ ! -e "$SUPPORT/venv" ] && [ ! -s "$LOGS/curl.log" ]; check $? "... and it created no venv and fetched nothing"
HL_ARGS="--lock $DMG_FIX/ok.lock --runtime $DMG_FIX/python-runtime.tar.gz"
for variant in partial bumped extra; do
    dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --hash-lock "$DMG_FIX/hash-lock-$variant.txt"
    rc_is 2 "--hash-lock that is not exactly the pins of requirements.lock.txt ($variant) is refused: every Mac would refuse it at step 3"
    out_has 'does not list exactly the pins of' "... and the message says so"
    [ ! -e "$H/build" ] && [ ! -s "$LOGS/codesign.log" ] && [ ! -s "$LOGS/hdiutil.log" ]; check $? "... before anything was built, signed or packed"
done
out_has 'leftpad==1.0.0 is in the hash lock but not in the requirement file' "... the extra pin is named"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --hash-lock "$DMG_FIX/hash-lock-bumped.txt"
out_has 'numpy: the hash lock has 2\.5\.4, the requirement file 2\.5\.3' "... a version bump nobody re-locked is named with both versions"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --hash-lock "$DMG_FIX/hash-lock-partial.txt" --dry-run
rc_is 0 "--dry-run with a lock that does not match is only a plan ..."
out_has 'A real run would stop here' "... that lists the problem"
out_has 'does not list exactly the pins of' "... the same one"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --hash-lock "$DMG_FIX/hash-lock.txt" --require-hash-lock --dry-run
rc_is 0 "--dry-run with a matching lock and --require-hash-lock"
out_lacks 'A real run would stop here' "... has no problem"
out_has 'hash lock +: .*hash-lock\.txt .compared with pipeline/requirements\.lock\.txt at build time' "... and the plan says that the lock was compared"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --dry-run
rc_is 0 "--dry-run without a hash lock ..."
out_has 'hash lock +: NONE: version pins only, nothing checks the hashes' "... says in the plan that nothing checks the hashes of the packages"
out_lacks 'A real run would stop here' "... but it is not a problem unless --require-hash-lock is given"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" /bin/bash scripts/build_dmg.sh $HL_ARGS --require-hash-lock
rc_is 2 "--require-hash-lock without --hash-lock is refused (exit 2)"
out_has 'no --hash-lock FILE was given' "... with the reason"
[ ! -e "$H/build" ]; check $? "... before anything was built"
dmgbuild /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --require-identity
rc_is 2 "--require-identity without a signing identity is refused before the build"
[ ! -e "$H/build" ]; check $? "... nothing was built"
dmgbuild /bin/bash scripts/build_dmg.sh --bogus
rc_is 2 "an unknown option is a usage error"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
rc_is 0 "--dry-run with a good lock and runtime exits 0"
out_has 'Plan' "... prints the plan"
out_has "$DEFAULT_SHORT-9\\.9\\.9\\.dmg \\(UDZO, volume .$DEFAULT_NAME., /Applications link, README-install\\.txt\\)" "... with the name of the disk image (<short name>-<version>.dmg), its volume (the human name) and its format"
out_has "app names +: $DEFAULT_NAME \\(MCAP_APP_NAME, default $DEFAULT_NAME\\), file name $DEFAULT_SHORT\\.app \\(MCAP_APP_SHORT_NAME, default $DEFAULT_SHORT\\)" "... and the two names with their defaults"
out_has "app +: .*/$DEFAULT_SHORT\\.app \\(scripts/build_app\\.sh\\), staged copy .*/dmg-stage/$DEFAULT_SHORT\\.app" "... and the app file"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_APP_NAME="$CUSTOM_NAME" MCAP_APP_SHORT_NAME="$CUSTOM_SHORT" /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
rc_is 0 "--dry-run with MCAP_APP_NAME and MCAP_APP_SHORT_NAME ($CUSTOM_NAME, $CUSTOM_SHORT)"
out_has "$CUSTOM_SHORT-9\\.9\\.9\\.dmg \\(UDZO, volume .$CUSTOM_NAME., /Applications link, README-install\\.txt\\)" "... the plan names the disk image and the volume after them"
out_has "app +: .*/$CUSTOM_SHORT\\.app \\(scripts/build_app\\.sh\\), staged copy .*/dmg-stage/$CUSTOM_SHORT\\.app" "... and the app file"
out_lacks "$DEFAULT_SHORT-9\\.9|volume .$DEFAULT_NAME" "... and the disk image and the volume have nothing of the default names"
for bad in 'a&b' 'a b' '1x' '../x' 'é' 'abcdefghijklmnopqrstuvwxyzabcdefg'; do
    dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_APP_SHORT_NAME="$bad" /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
    rc_is 2 "--dry-run refuses MCAP_APP_SHORT_NAME=$bad (exit 2, before the plan)"
    out_has 'not a valid short app name' "... with the reason"
done
for bad in 'a&b' '-lead' ' lead' 'trail ' 'a/b' 'a"b' 'é' 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopq'; do
    dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_APP_NAME="$bad" /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
    rc_is 2 "--dry-run refuses MCAP_APP_NAME='$bad' (exit 2, before the plan)"
    out_has 'not a valid app name' "... with the reason"
done
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
out_has 'signing +: ad-hoc' "... and the signing that would be used"
out_has 'mcap/\{pipeline/mcap' "... and the layout inside the app"
out_lacks 'A real run would stop here' "... and no problem"
[ ! -e "$H/build" ] && [ ! -s "$LOGS/hdiutil.log" ] && [ ! -s "$LOGS/codesign.log" ]; check $? "... builds, signs and writes nothing"
dmgbuild /bin/bash scripts/build_dmg.sh --dry-run
rc_is 0 "--dry-run with the PENDING lock file still exits 0 (it is only a plan)"
out_has 'A real run would stop here' "... and lists what would stop a real run"
out_has 'PENDING' "... including the PENDING values"

# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: build_dmg.sh builds the layout, signs and packs (stub codesign and hdiutil, the tiny Swift program)"
# ---------------------------------------------------------------------------------------------------------------
fresh_dmg_env
OUTD="$H/out"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_BUILT_BY="Example Team, example.org" /bin/bash scripts/build_dmg.sh \
    --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --hash-lock "$DMG_FIX/hash-lock.txt" --require-hash-lock --out-dir "$OUTD"
rc_is 0 "build_dmg.sh builds the disk image with the stubs (a matching hash lock, --require-hash-lock)"
out_lacks 'WARNING: no --hash-lock' "... and no warning about a missing hash lock"
DMG_FILE="$OUTD/$DEFAULT_SHORT-9.9.9.dmg"
[ -f "$DMG_FILE" ]; check $? "<short name>-<version>.dmg is in --out-dir"
DMG_SHA="$(shasum -a 256 "$DMG_FILE" | awk '{ print $1 }')"
out_has "^$DMG_SHA  $DMG_FILE\$" "stdout is '<sha256>  <path of the dmg>'"
[ "$(cat "$DMG_FILE.sha256")" = "$DMG_SHA  $DEFAULT_SHORT-9.9.9.dmg" ]; check $? "<dmg>.sha256 holds the same checksum in shasum format"
grep -q -- "-volname $DEFAULT_NAME " "$LOGS/hdiutil.log" && grep -q -- '-format UDZO' "$LOGS/hdiutil.log" && grep -q -- '-fs HFS+' "$LOGS/hdiutil.log"; check $? "hdiutil create: volume name '$DEFAULT_NAME', UDZO, HFS+"
R="$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Resources"
[ -L "$STATE/dmg-root/Applications" ] && [ "$(readlink "$STATE/dmg-root/Applications")" = "/Applications" ]; check $? "the disk image holds an /Applications link"
sed -e "s/@APP_NAME@/$DEFAULT_NAME/g" -e "s/@APP_SHORT_NAME@/$DEFAULT_SHORT/g" "$MINI/dmg/README-install.txt" | cmp -s - "$STATE/dmg-root/README-install.txt"; check $? "... and README-install.txt: the template with the two names filled in"
! grep -Eq '@[A-Z_]+@' "$STATE/dmg-root/README-install.txt"; check $? "... no placeholder is left in it"
[ "$(grep -c . "$STATE/dmg-root/README-install.txt")" -le 10 ] && grep -qF "$DEFAULT_NAME: install" "$STATE/dmg-root/README-install.txt" && grep -qF "Drag $DEFAULT_SHORT.app to the Applications folder" "$STATE/dmg-root/README-install.txt" && grep -qF "$DEFAULT_SHORT.app을 Applications 폴더로" "$STATE/dmg-root/README-install.txt"; check $? "... it names the app file that is in the image and the human name, in both languages, in at most 10 lines"
[ -f "$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Info.plist" ] && [ -x "$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/MacOS/$DEFAULT_SHORT" ]; check $? "... and the app"
[ "$(ls "$STATE/dmg-root" | sort | tr '\n' ' ')" = "Applications $DEFAULT_SHORT.app README-install.txt " ]; check $? "... and nothing else"
[ -f "$R/mcap/pipeline/mcap/__init__.py" ] && [ -f "$R/mcap/pipeline/mcap/native.so" ]; check $? "layout: mcap/pipeline/mcap holds the package"
[ -z "$(find "$STATE/dmg-root" \( -name '__pycache__' -o -name '*.pyc' -o -name '.DS_Store' -o -name 'tests' \) -not -path '*/dmg-root/$DEFAULT_SHORT.app/Contents/_CodeSignature*' | head -n 1)" ]; check $? "... without bytecode, Finder files or a tests folder"
for f in requirements.lock.txt requirements-silero.txt requirements.client.txt; do cmp -s "$R/mcap/pipeline/$f" "$MINI/pipeline/$f" || { echo "      $f differs"; false; }; done; check $? "... and the requirement files"
cmp -s "$R/mcap/pipeline/requirements.hash-lock.txt" "$DMG_FIX/hash-lock.txt"; check $? "... and the hash lock when --hash-lock was given"
cfg_ok=0; for f in note_prompt.md cleanup_prompt.md verify_prompt.md vocabulary.txt config.env.example; do cmp -s "$R/mcap/config/$f" "$MINI/config/$f" || { cfg_ok=1; echo "      config/$f differs"; }; done
check $cfg_ok "layout: mcap/config holds the prompts, the example vocabulary and config.env.example"
[ -z "$(ls "$R/mcap/config" | grep -v -E '^(note_prompt\.md|cleanup_prompt\.md|verify_prompt\.md|vocabulary\.txt|config\.env\.example)$')" ]; check $? "... and nothing else (no company template, no policy fixtures)"
sc_ok=0; for f in setup_python.sh first_run_install.sh legal_notice.sh bundle_id.sh; do { cmp -s "$R/mcap/scripts/$f" "$ROOT/scripts/$f" && [ -x "$R/mcap/scripts/$f" ]; } || { sc_ok=1; echo "      scripts/$f differs or is not executable"; }; done
check $sc_ok "layout: mcap/scripts holds setup_python.sh, first_run_install.sh, legal_notice.sh and bundle_id.sh (the helpers read the names of the app from it; executable, unchanged)"
[ "$(cat "$R/mcap/VERSION")" = "9.9.9" ]; check $? "layout: mcap/VERSION"
cmp -s "$R/runtime/python-runtime.tar.gz" "$DMG_FIX/python-runtime.tar.gz"; check $? "layout: runtime/python-runtime.tar.gz is the archive that matches the lock"
LOCK_REQ_SHA="$(shasum -a 256 "$R/mcap/pipeline/requirements.lock.txt" | awk '{ print $1 }')"
[ "$(cat "$R/mcap/components.json")" = "{\"python_runtime\":{\"file\":\"../runtime/python-runtime.tar.gz\",\"sha256\":\"$RT_SHA\"},\"requirements_lock_sha256\":\"$LOCK_REQ_SHA\"}" ]; check $? "layout: components.json is exactly the contract {python_runtime:{file,sha256}, requirements_lock_sha256}"
[ "$(plutil -extract python_runtime.sha256 raw -o - "$R/mcap/components.json")" = "$RT_SHA" ] && [ "$(plutil -extract python_runtime.file raw -o - "$R/mcap/components.json")" = "../runtime/python-runtime.tar.gz" ]; check $? "... and it parses as JSON"
SAVE_OUT="$OUT"; SAVE_RC="$RC"
if firstrun_contract "components.json of build_dmg.sh" "$R/mcap/components.json"; then
    rc_is 0 "the app's own parser (selftest-firstrun) understands the components.json that build_dmg.sh wrote"
    out_has "^components: ok runtime=$RT_SHA lock=$LOCK_REQ_SHA\$" "... and reads exactly the two hashes in it"
    printf '{"python_runtime":{"sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$RT_SHA" "$LOCK_REQ_SHA" > "$WORK/no-file-key.json"
    firstrun_contract "components.json without the file key" "$WORK/no-file-key.json"
    rc_is 0 "... the file key is not part of what the app needs (the helper reads it)"
    printf '{"python_runtime":{"file":"x","sha256":"%s"},"requirements_lock":"%s"}\n' "$RT_SHA" "$LOCK_REQ_SHA" > "$WORK/renamed-key.json"
    firstrun_contract "components.json with a renamed key" "$WORK/renamed-key.json"
    rc_not 0 "... a renamed key (requirements_lock) is not understood: the contract is the key names of the script"
fi
OUT="$SAVE_OUT"; RC="$SAVE_RC"
[ "$(plutil -extract MCBuiltBy raw -o - "$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Info.plist")" = "Example Team, example.org" ]; check $? "MCAP_BUILT_BY passes through to the app inside the disk image"
out_has 'nested Mach-O files to sign: 1' "build_dmg.sh finds the nested Mach-O file"
n_nested="$(grep -n -- "--force --sign - .*/mcap/pipeline/mcap/native.so" "$LOGS/codesign.log" | head -n 1 | cut -d: -f1)"
n_app="$(grep -n -- "--force --sign - --identifier $DEFAULT_ID .*/dmg-stage/$DEFAULT_SHORT.app" "$LOGS/codesign.log" | head -n 1 | cut -d: -f1)"
[ -n "$n_nested" ] && [ -n "$n_app" ] && [ "$n_nested" -lt "$n_app" ]; check $? "codesign: the nested Mach-O file is signed before the app, both ad-hoc like build_app.sh"
! grep -q -- '--options' "$LOGS/codesign.log"; check $? "no hardened runtime: no codesign call has --options"
[ ! -e "$H/build/$DEFAULT_SHORT.app/Contents/Resources/mcap" ]; check $? "the plain build/$DEFAULT_SHORT.app is untouched (the layout is added to a staged copy)"
[ ! -s "$LOGS/forbidden.log" ]; check $? "no forbidden stub was called (security, notarytool, hdiutil subcommands)"
fresh_dmg_env
# the bundle id is a build input of the disk image too: it reaches Info.plist and BOTH signatures, the plan names it, a bad one stops before anything is built
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --dry-run
out_has "bundle id +: $CUSTOM_ID " "build_dmg.sh --dry-run names the bundle id (MCAP_BUNDLE_ID)"
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_BUNDLE_ID='a.b;x' /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz"
rc_not 0 "build_dmg.sh refuses an invalid MCAP_BUNDLE_ID"
out_has 'not a valid bundle identifier' "... with the reason"
[ ! -e "$H/build" ] && [ ! -s "$LOGS/codesign.log" ] && [ ! -s "$LOGS/hdiutil.log" ]; check $? "... before building, signing or packing anything"
fresh_dmg_env
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 MCAP_BUNDLE_ID="$CUSTOM_ID" /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --out-dir "$H/out-id"
rc_is 0 "build_dmg.sh with MCAP_BUNDLE_ID=$CUSTOM_ID"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Info.plist")" = "$CUSTOM_ID" ]; check $? "... CFBundleIdentifier of the app in the disk image"
[ "$(grep -c -- "--identifier $CUSTOM_ID " "$LOGS/codesign.log")" = 2 ] && ! grep -q -- "--identifier $DEFAULT_ID" "$LOGS/codesign.log"; check $? "... both signatures (build_app.sh and the one after the layout was added) carry it, none carries the default"
fresh_dmg_env
# The REAL Python package in the layout that build_dmg.sh really produces (the small project root above holds a fake package): run the way the launcher runs it
# (cwd = mcap/pipeline, no PROJECT_DIR), the package that answers must be the one of the bundle and the prompts must come from mcap/config of the bundle.
fresh_dmg_env
REAL="$WORK/dmg-real"
mkdir -p "$REAL/pipeline" "$REAL/config" "$REAL/dmg"
( cd "$ROOT/pipeline" && COPYFILE_DISABLE=1 tar -cf - --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' mcap ) | tar -xf - -C "$REAL/pipeline"
for f in requirements.lock.txt requirements-silero.txt requirements.client.txt; do cp "$ROOT/pipeline/$f" "$REAL/pipeline/$f"; done
for f in note_prompt.md cleanup_prompt.md verify_prompt.md vocabulary.txt config.env.example; do cp "$ROOT/config/$f" "$REAL/config/$f"; done
cp "$ROOT/dmg/README-install.txt" "$REAL/dmg/README-install.txt"; printf '9.9.8\n' > "$REAL/VERSION"
dmgbuild env MCAP_DMG_SRC_ROOT="$REAL" MCAP_VERSION=9.9.8 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --out-dir "$H/out-real"
rc_is 0 "a build with the real Python package works"
R2="$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Resources/mcap"
cat > "$WORK/probe_bundle.py" <<'PROBEEOF'
import json, sys
from pathlib import Path
from mcap import note
from mcap.config import Config
cfg = Config()
cfg.support_dir = Path(sys.argv[1])
cfg.project_dir = Path(sys.argv[2])
print(json.dumps({"module": str(Path(note.__file__).resolve()),
                  "prompts": {n: str(note.resolve_prompt(cfg, n).resolve()) for n in ("note_prompt.md", "cleanup_prompt.md", "verify_prompt.md")}}))
PROBEEOF
mkdir -p "$H/probe-support"
( cd "$R2/pipeline" && env -i HOME="$H" PATH="/usr/bin:/bin" PYTHONPATH="$R2/pipeline" PYTHONDONTWRITEBYTECODE=1 "$PYTHON_FOR_TESTS" "$WORK/probe_bundle.py" "$H/probe-support" "$H/no-such-project" ) > "$WORK/probe_bundle.out" 2>&1
"$PYTHON_FOR_TESTS" - "$WORK/probe_bundle.out" "$R2" <<'CHECKEOF'
import json, sys
from pathlib import Path
got = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
bundle = Path(sys.argv[2]).resolve()
assert got["module"].startswith(str(bundle / "pipeline")), "the package that ran is not the bundle's: %s" % got["module"]
for name, path in got["prompts"].items():
    assert Path(path) == bundle / "config" / name, "%s resolved to %s, not mcap/config of the bundle" % (name, path)
CHECKEOF
check $? "the real mcap package inside the bundle layout of build_dmg.sh runs from mcap/pipeline and finds its prompts in mcap/config (no PROJECT_DIR)"
[ -z "$(find "$R2" \( -name '__pycache__' -o -name '*.pyc' \) | head -n 1)" ]; check $? "... and running it wrote no bytecode into the bundle (the signature stays valid)"

fresh_dmg_env
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --out-dir "$H/out-nolock"
rc_is 0 "a build without --hash-lock still works ..."
out_has 'WARNING: no --hash-lock: the packages are installed by version only' "... and says on stderr that nothing checks the hashes of the packages"
[ ! -e "$STATE/dmg-root/$DEFAULT_SHORT.app/Contents/Resources/mcap/pipeline/requirements.hash-lock.txt" ]; check $? "... no hash lock is put into the app"
fresh_dmg_env
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 STUB_HDIUTIL_FAIL=1 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz"
rc_is 1 "a failing hdiutil is an error"
out_has 'hdiutil create failed' "... named in the message"
[ ! -e "$H/build/$DEFAULT_SHORT-9.9.9.dmg" ]; check $? "... and no dmg is left"

fresh_dmg_env
add_identity "$HASH_A" ""
dmgbuild env MCAP_DMG_SRC_ROOT="$MINI" MCAP_VERSION=9.9.9 /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz" --require-identity
rc_is 0 "with the 'MeetingCapture Local Signing' identity the build works (--require-identity accepted)"
[ "$(grep -c -- "--force --sign $HASH_A --timestamp=none --identifier $DEFAULT_ID " "$LOGS/codesign.log")" = 2 ]; check $? "the app is signed with the SAME identity twice: by build_app.sh and again after the layout was added"
grep -q -- "--force --sign $HASH_A --timestamp=none .*/mcap/pipeline/mcap/native.so" "$LOGS/codesign.log"; check $? "the nested Mach-O file is signed with that identity too"
out_has 'designated requirement: identifier "'"$DEFAULT_ID"'" and certificate leaf = H"1111' "the designated requirement is the certificate's (permissions survive an update)"
out_has 'Always Allow' "the keychain dialog hint is printed"
[ ! -s "$LOGS/forbidden.log" ] && ! grep -qvE '^security (find-identity -p codesigning|login-keychain)$' "$LOGS/security.log"; check $? "only the read-only security call of build_app.sh (find-identity) was made"

if [ "${MCAP_TEST_REAL_HDIUTIL:-0}" = 1 ]; then
    fresh_env base
    runx MCAP_SOURCES_DIR="$WORK/swiftsrc" MCAP_BUILD_DIR="$H/build" MCAP_VERSION=9.9.9 MC_CODESIGN_IDENTITY=- /bin/bash scripts/build_dmg.sh --lock "$DMG_FIX/ok.lock" --runtime "$DMG_FIX/python-runtime.tar.gz"
    rc_is 0 "REAL hdiutil and codesign (MCAP_TEST_REAL_HDIUTIL=1): the disk image is built"
    mkdir -p "$H/mnt"
    if hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$H/mnt" "$H/build/$DEFAULT_SHORT-9.9.9.dmg" >/dev/null 2>&1; then
        [ -d "$H/mnt/$DEFAULT_SHORT.app/Contents/Resources/mcap/pipeline/mcap" ] && [ -L "$H/mnt/Applications" ] && [ -f "$H/mnt/README-install.txt" ]; check $? "... mounted: the app with its layout, the /Applications link and the readme are in it"
        codesign --verify --strict "$H/mnt/$DEFAULT_SHORT.app" >/dev/null 2>&1; check $? "... the signature of the app inside the mounted image verifies"
        hdiutil detach "$H/mnt" >/dev/null 2>&1 || hdiutil detach -force "$H/mnt" >/dev/null 2>&1
    else
        bad "... the real disk image could not be mounted"
    fi
else
    echo "  (skipped: one build with the real hdiutil and codesign runs only with MCAP_TEST_REAL_HDIUTIL=1; it needs a normal login session)"
fi

# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: first_run_install.sh (fake app, fake runtime, fake setup_python.sh, stubs for curl, sw_vers, uname, df, defaults, open)"
# ---------------------------------------------------------------------------------------------------------------
STUBS_FR="$WORK/stubs-fr"; mkdir -p "$STUBS_FR"; cp "$STUBS_BASE"/* "$STUBS_FR"/
cat > "$STUBS_FR/open" <<'EOF'
#!/bin/sh
# fake open: logs; `--args setup` writes a setup report like the app does ($STUB_SETUP_REPORT), $STUB_OPEN_RC makes it fail
echo "open $*" >> "${STUB_LOG:?}/open.log"
case "$*" in
    *"--args setup"*)
        [ -z "${STUB_OPEN_RC:-}" ] || exit "$STUB_OPEN_RC"
        mkdir -p "${MCAP_LOG_DIR:?}"
        printf '%s\n' "${STUB_SETUP_REPORT:-[ OK ] config.env: fine}" > "$MCAP_LOG_DIR/setup-report.txt"
        exit 0 ;;
esac
exit 0
EOF
cat > "$STUBS_FR/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-m" ]; then echo "${STUB_UNAME_M:-arm64}"; exit 0; fi
exec /usr/bin/uname "$@"
EOF
cat > "$STUBS_FR/sysctl" <<'EOF'
#!/bin/sh
if [ "$*" = "-n hw.optional.arm64" ]; then echo "${STUB_ARM64:-1}"; exit 0; fi
exec /usr/sbin/sysctl "$@"
EOF
cat > "$STUBS_FR/sw_vers" <<'EOF'
#!/bin/sh
if [ "$1" = "-productVersion" ]; then echo "${STUB_MACOS-15.1}"; exit 0; fi
exec /usr/bin/sw_vers "$@"
EOF
cat > "$STUBS_FR/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 976490576 1000 %s 1%% /\n' "${STUB_DF_KB:-50000000}"
EOF
cat > "$STUBS_FR/curl" <<'EOF'
#!/bin/sh
# fake curl for the HEAD requests of the helper: prints the http code; $STUB_CURL_DOWN names a host that does not answer
echo "curl $*" >> "${STUB_LOG:?}/curl.log"
for last; do :; done
case "$last" in *"${STUB_CURL_DOWN:-@@none@@}"*) printf '000'; exit 6 ;; esac
printf '%s' "${STUB_CURL_CODE:-200}"
exit 0
EOF
cat > "$STUBS_FR/defaults" <<'EOF'
#!/bin/sh
if [ "$1 $2 $3" = "read -g AppleLanguages" ]; then printf '(\n    "%s",\n    "en-US"\n)\n' "${STUB_LANG:-en-US}"; exit 0; fi
exit 1
EOF
cat > "$STUBS_FR/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-F" ]; then echo "${STUB_FULLNAME-Pat Example}"; exit 0; fi
exec /usr/bin/id "$@"
EOF
cat > "$STUBS_FR/ln" <<'EOF'
#!/bin/sh
for last; do :; done
case "$last" in */config.env) [ -z "${STUB_LN_FAIL:-}" ] || { echo "stub ln: refused" >&2; exit 1; } ;; esac
exec /bin/ln "$@"
EOF
cat > "$STUBS_FR/mv" <<'EOF'
#!/bin/sh
for last; do :; done
case "$last" in */config.env) [ -z "${STUB_MV_FAIL_CONFIG:-}" ] || { echo "stub mv: refused" >&2; exit 1; } ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$STUBS_FR"/*
STUBS_CLAUDE="$WORK/stubs-claude"; mkdir -p "$STUBS_CLAUDE"; printf '#!/bin/sh\nexit 0\n' > "$STUBS_CLAUDE/claude"; chmod +x "$STUBS_CLAUDE/claude"

make_fake_app() {   # the installer's app in the fake HOME: the real helper and legal notice, a fake setup_python.sh, the fixture runtime
    FAKE_APP="$H/Applications/$DEFAULT_SHORT.app"
    FAKE_RES="$FAKE_APP/Contents/Resources"
    FAKE_MC="$FAKE_RES/mcap"
    mkdir -p "$FAKE_APP/Contents/MacOS" "$FAKE_MC/scripts" "$FAKE_MC/config" "$FAKE_MC/pipeline/mcap" "$FAKE_RES/runtime"
    printf '#!/bin/sh\nexit 0\n' > "$FAKE_APP/Contents/MacOS/$DEFAULT_SHORT"; chmod +x "$FAKE_APP/Contents/MacOS/$DEFAULT_SHORT"
    cp "$ROOT/scripts/first_run_install.sh" "$ROOT/scripts/legal_notice.sh" "$ROOT/scripts/bundle_id.sh" "$FAKE_MC/scripts/"
    cp "$ROOT/config/config.env.example" "$ROOT/config/vocabulary.txt" "$FAKE_MC/config/"
    cp "$ROOT/pipeline/requirements.lock.txt" "$FAKE_MC/pipeline/"
    printf 'x = 1\n' > "$FAKE_MC/pipeline/mcap/__init__.py"
    printf '0.2.0\n' > "$FAKE_MC/VERSION"
    cp "$DMG_FIX/python-runtime.tar.gz" "$FAKE_RES/runtime/python-runtime.tar.gz"
    FAKE_LOCK_SHA="$(shasum -a 256 "$FAKE_MC/pipeline/requirements.lock.txt" | awk '{ print $1 }')"
    printf '{"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$RT_SHA" "$FAKE_LOCK_SHA" > "$FAKE_MC/components.json"
    cat > "$FAKE_MC/scripts/setup_python.sh" <<'EOF'
#!/bin/bash
# fake setup_python.sh: records its arguments and environment, makes a fake venv whose python records every call
echo "setup_python $*" >> "${STUB_LOG:?}/setup_python.log"
env | grep -E '^(MCAP_SUPPORT_DIR|PYTHONDONTWRITEBYTECODE)=' >> "$STUB_LOG/setup_python.env" || true
if [ -f "${STUB_STATE:?}/fail-setup-python" ]; then echo "[setup_python] ERROR: simulated failure" >&2; exit 1; fi
# a test can hold this run here (a second helper is started meanwhile): block-setup-python exists -> wait until it is removed
if [ -f "$STUB_STATE/block-setup-python" ]; then
    : > "$STUB_STATE/setup-python-started"
    n=0; while [ -f "$STUB_STATE/block-setup-python" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
fi
mkdir -p "$MCAP_SUPPORT_DIR/venv/bin" "$MCAP_SUPPORT_DIR/venv/lib/python3.12/site-packages"
cat > "$MCAP_SUPPORT_DIR/venv/bin/python" <<'PY'
#!/bin/sh
echo "python $*" >> "$STUB_LOG/venv-python.log"
env >> "$STUB_LOG/venv-python.env"
case "$*" in
    "-m mcap api-key status --exists")
        # STUB_REAL_MCAP=<repository>: the REAL `mcap api-key status --exists` runs (its security tool is the stub of MCAP_SECURITY_BIN)
        if [ -n "${STUB_REAL_MCAP:-}" ]; then cd "$STUB_REAL_MCAP/pipeline" && exec "${STUB_REAL_PY:?}" -m mcap api-key status --exists 2>> "$STUB_LOG/venv-python.err"; fi
        [ -f "$STUB_STATE/keychain" ] && exit 0; exit 1 ;;
    "-m mcap api-key status") echo "the helper must not read the key: api-key status without --exists" >> "$STUB_LOG/venv-python.violations"; exit 3 ;;
    "-m mcap api-key set")
        [ ! -f "$STUB_STATE/api-set-fails" ] || exit 1
        IFS= read -r key || key=""
        printf '%s\n' "$key" > "$STUB_STATE/keychain"
        exit 0 ;;
esac
exit 0
PY
chmod +x "$MCAP_SUPPORT_DIR/venv/bin/python"
exit 0
EOF
    chmod +x "$FAKE_MC/scripts/setup_python.sh"
    FAKE_APP_P="$(cd "$FAKE_APP" && pwd -P)"      # the helper resolves links (/var is /private/var): the log shows the resolved paths
    FAKE_MC_P="$(cd "$FAKE_MC" && pwd -P)"
}
FR_ARGS="--accept-legal-notice"
FR_SCRIPT=""
fr_run() {   # fr_run "<stdin text>" [VAR=value ...]: the helper from the fake app, a minimal PATH with the stubs first; sets OUT and RC
    local input="$1"; shift
    N=$((N + 1)); OUT="$WORK/out.$N.txt"
    ( cd "$H" && printf '%s' "$input" | env HOME="$H" PATH="$STUBS_FR${FR_PATH_EXTRA:+:$FR_PATH_EXTRA}:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$H/tmp" \
        MCAP_SUPPORT_DIR="$SUPPORT" MCAP_LOG_DIR="$APPLOGS" STUB_LOG="$LOGS" STUB_STATE="$STATE" MCAP_UI_LANGUAGE=en "$@" \
        /bin/bash "${FR_SCRIPT:-$FAKE_MC/scripts/first_run_install.sh}" $FR_ARGS ) > "$OUT" 2>&1
    RC=$?
}
fr_env() { fresh_env base; STUBS="$STUBS_FR"; make_fake_app; FR_ARGS="--accept-legal-notice"; FR_SCRIPT=""; FR_PATH_EXTRA=""; DRIVE="$H/Library/CloudStorage/GoogleDrive-pat@example.com"; }
no_leftovers() { [ -z "$(find "$SUPPORT" -name '.*' -not -name '.' -not -name '..' 2>/dev/null | head -n 1)" ]; }   # no temporary file of the helper is left
FR_PATH_EXTRA=""

# --- the legal notice -----------------------------------------------------------------------------------------
fr_env
FR_ARGS=""
fr_run ""
rc_not 0 "first_run_install.sh without a terminal and without --accept-legal-notice is refused"
out_has '\[1/7\]' "step 1 is numbered [1/7]"
out_has 'LEGAL NOTICE: '"$DEFAULT_NAME"' records other people' "the recording legal notice is shown first"
out_has 'no terminal to ask' "... and the refusal says why"
out_has 'Run this script again' "... and how to continue"
[ ! -d "$SUPPORT" ] && [ ! -s "$LOGS/setup_python.log" ] && [ ! -s "$LOGS/curl.log" ]; check $? "nothing was created, downloaded or installed before the notice was accepted"
fr_env
PTY_PROMPT="Type yes|Choose 1 or 2" pty "yes|2" /bin/bash "$FAKE_MC/scripts/first_run_install.sh"
rc_is 0 "typing yes at the terminal prompt (a pseudo terminal) accepts the notice and the run succeeds"
[ -f "$SUPPORT/components-installed.json" ]; check $? "... and components-installed.json was written"
grep -q -- "--stdout /dev/tty" "$LOGS/open.log"; check $? "... the permission step hands the app the terminal of this window (--stdout /dev/tty...)"
fr_env
PTY_PROMPT="Type yes" pty "no" /bin/bash "$FAKE_MC/scripts/first_run_install.sh"
rc_not 0 "typing no at the notice is refused"
[ ! -d "$SUPPORT" ]; check $? "... and nothing was created"

# --- a full run, English --------------------------------------------------------------------------------------
fr_env
fr_run "2
"
rc_is 0 "a full run on a good Mac succeeds"
for n in 1 2 3 4 5 6 7; do out_has "\[$n/7\]" "step [$n/7] is printed"; done
[ -x "$SUPPORT/runtime/python/bin/python3" ] && [ "$(cat "$SUPPORT/runtime/python-runtime.sha256")" = "$RT_SHA" ]; check $? "step 2: the runtime is unpacked to SUPPORT_DIR/runtime/python and its checksum is remembered"
[ "$(cat "$LOGS/setup_python.log")" = "setup_python --python $SUPPORT/runtime/python/bin/python3 --with-silero --pre-download-model" ]; check $? "step 3: setup_python.sh runs with the unpacked Python, --with-silero and --pre-download-model (no hash lock: the app has none)"
grep -q "^MCAP_SUPPORT_DIR=$SUPPORT\$" "$LOGS/setup_python.env" && grep -q '^PYTHONDONTWRITEBYTECODE=1$' "$LOGS/setup_python.env"; check $? "... with MCAP_SUPPORT_DIR set and no bytecode written into the app"
grep -q 'pycache_prefix' "$SUPPORT/venv/lib/python3.12/site-packages/mcap-bytecode.pth"; check $? "step 3: a .pth file in the venv sends Python bytecode to a cache folder (the signed app is never modified)"
[ -f "$SUPPORT/config.env" ] && [ "$(stat -f %Lp "$SUPPORT/config.env")" = 600 ]; check $? "step 5: config.env is created, mode 600"
grep -qx 'ARCHIVE_DIR=~/Meetings' "$SUPPORT/config.env" && grep -qx 'SELF_NAME=Pat' "$SUPPORT/config.env" && grep -qx 'UI_LANGUAGE=en' "$SUPPORT/config.env" && grep -qx 'CLAUDE_AUTH=api' "$SUPPORT/config.env"; check $? "... ARCHIVE_DIR ~/Meetings, SELF_NAME = the first word of the full name, UI_LANGUAGE from the language, CLAUDE_AUTH api"
! grep -q '^PROJECT_DIR=' "$SUPPORT/config.env" && grep -q '^# PROJECT_DIR is not set on purpose' "$SUPPORT/config.env"; check $? "... PROJECT_DIR is left out (the app finds its pipeline inside itself)"
[ "$(grep -E '^[A-Z_]+=' "$FAKE_MC/config/config.env.example" | grep -vE '^(ARCHIVE_DIR|PROJECT_DIR|SELF_NAME|UI_LANGUAGE|CLAUDE_AUTH)=' | sort)" = "$(grep -E '^[A-Z_]+=' "$SUPPORT/config.env" | grep -vE '^(ARCHIVE_DIR|PROJECT_DIR|SELF_NAME|UI_LANGUAGE|CLAUDE_AUTH)=' | sort)" ]; check $? "... every other key is exactly the example's"
cmp -s "$SUPPORT/vocabulary.txt" "$FAKE_MC/config/vocabulary.txt"; check $? "step 5: the example vocabulary is copied (the app's setup wants SUPPORT_DIR/vocabulary.txt)"
[ -d "$H/Meetings" ]; check $? "step 6: the meeting folder ~/Meetings exists"
[ "$(plutil -extract python_runtime.sha256 raw -o - "$SUPPORT/components-installed.json")" = "$RT_SHA" ] && [ "$(plutil -extract requirements_lock_sha256 raw -o - "$SUPPORT/components-installed.json")" = "$FAKE_LOCK_SHA" ]; check $? "step 7: components-installed.json carries the two hashes of components.json"
[ "$(plutil -extract app_version raw -o - "$SUPPORT/components-installed.json")" = "0.2.0" ]; check $? "... and the app version"
SAVE_OUT="$OUT"; SAVE_RC="$RC"
if firstrun_contract "components-installed.json of the helper" "$FAKE_MC/components.json" "$SUPPORT/components-installed.json"; then
    rc_is 0 "the app's own parser reads the components-installed.json that the helper wrote and finds it equal to components.json (no 'update needed' after a good install)"
    out_has '^match: yes$' "... match: yes"
fi
OUT="$SAVE_OUT"; RC="$SAVE_RC"
grep -qx "open -n -W -a $FAKE_APP_P --stdout /dev/null --stderr /dev/null --args setup" "$LOGS/open.log"; check $? "step 7: the app's own setup is started with  open -n -W -a <app> --stdout ... --args setup"
out_has 'Done\. '"$DEFAULT_NAME"' is installed' "the summary says it is done"
out_has 'menu bar icon > Quit' "... how to quit"
out_has 'drag it to the Trash' "... and how to uninstall"
out_has 'Settings\.\.\.' "... and where Settings is"
out_has 'Only Zoom calls have been verified' "... and what has been verified"
[ "$(grep -c '^curl ' "$LOGS/curl.log")" = 2 ] && grep -q -- '--head' "$LOGS/curl.log" && grep -q 'https://pypi.org/simple/' "$LOGS/curl.log" && grep -q 'https://huggingface.co/' "$LOGS/curl.log" && ! grep -qv -- '--proto =https --tlsv1.2' "$LOGS/curl.log"; check $? "step 1: two HEAD requests (the package index and the model host), https only, TLS 1.2 or newer, and nothing else uses curl"
[ ! -s "$LOGS/security.log" ] && [ ! -s "$LOGS/launchctl.log" ] && [ ! -s "$LOGS/forbidden.log" ]; check $? "the helper never calls security (the keychain) or launchctl"
no_leftovers; check $? "no temporary file is left in SUPPORT_DIR"
[ ! -e "$SUPPORT/.first-run.lock" ] && [ ! -L "$SUPPORT/.first-run.lock" ]; check $? "the lock of the run (.first-run.lock) is removed when it ends"
LC_ALL=C grep -q '[^[:print:][:space:]]' "$OUT"; [ "$?" != 0 ]; check $? "the English run prints no Korean (or any non-ASCII) text"
out_has 'does not install' "the missing Claude Code tool is mentioned (notes need it; the helper does not install it)"
out_has 'Skipped' "the key step: [2] later is a clear skip"
out_has 'no meeting notes' "... that says notes need the key (audio and transcripts still work)"

# --- the same run again: idempotent, nothing overwritten ----------------------------------------------------------
echo "# my own line" >> "$SUPPORT/config.env"
echo "my own term" > "$SUPPORT/vocabulary.txt"
CFG_SUM="$(cksum < "$SUPPORT/config.env")"; VOC_SUM="$(cksum < "$SUPPORT/vocabulary.txt")"
fr_run "2
"
rc_is 0 "running the helper again succeeds"
out_has 'already unpacked and matches this app' "step 2 is skipped the second time"
[ "$(cksum < "$SUPPORT/config.env")" = "$CFG_SUM" ] && [ "$(cksum < "$SUPPORT/vocabulary.txt")" = "$VOC_SUM" ]; check $? "config.env and vocabulary.txt are never overwritten by a second run"
out_has 'already exists: kept exactly as it is' "... and the helper says so"
[ "$(grep -c . "$LOGS/setup_python.log")" = 2 ]; check $? "setup_python.sh runs again (it is idempotent itself)"
grep -q '"python_runtime"' "$SUPPORT/components-installed.json"; check $? "components-installed.json is written again"

# --- Korean ----------------------------------------------------------------------------------------------------
fr_env
fr_run "2
" MCAP_UI_LANGUAGE=ko
rc_is 0 "a full run in Korean succeeds"
out_has '\[1/7\] 이 Mac과 앱 확인' "UI_LANGUAGE=ko: the step titles are Korean"
out_has '\[7/7\] 권한 요청과 마무리' "... all of them"
out_has '끝났어요' "... and the summary"
out_has '녹음 안내' "... and the notice has a Korean introduction"
out_has 'Only Zoom|Zoom 통화뿐' "... and says that only Zoom calls were verified"
fr_env
fr_run "2
" MCAP_UI_LANGUAGE= STUB_LANG=ko-KR
rc_is 0 "the macOS language (defaults AppleLanguages) decides when nothing else does"
out_has '\[1/7\] 이 Mac과 앱 확인' "... a Korean macOS gives a Korean window"
grep -qx 'UI_LANGUAGE=ko' "$SUPPORT/config.env"; check $? "... and UI_LANGUAGE=ko in the new config.env"
fr_env
mkdir -p "$SUPPORT"; printf 'UI_LANGUAGE=ko\nSELF_NAME=Custom\n' > "$SUPPORT/config.env"
fr_run "2
" MCAP_UI_LANGUAGE= STUB_LANG=en-US
rc_is 0 "an existing config.env with UI_LANGUAGE=ko decides over the macOS language"
out_has '\[1/7\] 이 Mac과 앱 확인' "... Korean window"
[ "$(cat "$SUPPORT/config.env")" = "UI_LANGUAGE=ko
SELF_NAME=Custom" ]; check $? "... and the existing config.env is untouched, byte for byte"
out_has 'config.env가 이미 있어서 그대로 두었어요' "... and the Korean note says so"
out_lacks 'Use Google Drive' "... and no question about the meeting folder is asked (it is not the helper's file)"
fr_env
FR_ARGS="--accept-legal-notice --lang en"
fr_run "2
" MCAP_UI_LANGUAGE=ko
out_has '\[1/7\] Checking this Mac and the app' "--lang en beats MCAP_UI_LANGUAGE=ko"

# --- the checks of step 1 -----------------------------------------------------------------------------------------
fr_env
fr_run "2
" STUB_UNAME_M=x86_64 STUB_ARM64=0
rc_not 0 "an Intel Mac is refused"
out_has 'ERROR in step \[1/7\] Checking this Mac and the app' "... in step 1"
out_has 'not an Apple silicon Mac' "... with the cause"
out_has 'Run this script again: it resumes' "... and the way on"
[ ! -d "$SUPPORT/runtime" ] && [ ! -e "$SUPPORT/config.env" ] && [ ! -s "$LOGS/setup_python.log" ]; check $? "... nothing was installed"
fr_env
fr_run "2
" STUB_UNAME_M=x86_64 STUB_ARM64=1
rc_is 0 "a shell that runs under Rosetta on an Apple silicon Mac passes the check (sysctl hw.optional.arm64)"
for v in 14.3 14.0 13.6.1 9.9; do
    fr_env
    fr_run "2
" STUB_MACOS=$v
    rc_not 0 "macOS $v is refused"
    out_has 'older than 14\.4' "... with the cause"
done
fr_env
fr_run "2
" STUB_MACOS=
rc_not 0 "an unreadable macOS version is refused"
for v in 14.4 14.4.1 15.0 26.0.1; do
    fr_env
    fr_run "2
" STUB_MACOS=$v
    rc_is 0 "macOS $v is accepted"
done
fr_env
fr_run "2
" STUB_DF_KB=11534336
rc_not 0 "11 GB of free disk is refused"
out_has 'Only 11\.0 GB of disk space is free, the installation needs 12 GB' "... with the numbers"
[ ! -d "$SUPPORT/runtime" ]; check $? "... nothing was installed"
fr_env
fr_run "2
" STUB_DF_KB=12582912
rc_is 0 "exactly 12 GB of free disk is accepted"
mkdir -p "$SUPPORT"; echo '{}' > "$SUPPORT/components-installed.json"
fr_run "2
" STUB_DF_KB=3145728
rc_is 0 "after an earlier installation a re-run only needs 2 GB (3 GB free is fine)"
fr_env
fr_run "2
" STUB_CURL_DOWN=huggingface.co
rc_not 0 "no connection to the model host is refused"
out_has 'Cannot reach https://huggingface.co/' "... naming the host"
out_has 'VPN, proxy or firewall' "... and the likely cause"
fr_env
fr_run "2
" STUB_CURL_DOWN=pypi.org
rc_not 0 "no connection to the package index is refused"
out_has 'Cannot reach https://pypi.org/simple/' "... naming the host"
fr_env
fr_run "2
" STUB_CURL_CODE=503
rc_not 0 "a server error (http 503) is not 'reachable'"
fr_env
fr_run "2
" STUB_CURL_CODE=404
rc_is 0 "any answer below 500 counts as reachable"
fr_env
fr_run "2
" STUB_UNAME_M=x86_64 STUB_ARM64=0 STUB_MACOS=13.0 STUB_DF_KB=1000 STUB_CURL_DOWN=pypi.org
rc_not 0 "several problems at once"
out_has 'not an Apple silicon' "... all of them are listed: the chip"
out_has 'older than 14\.4' "... the macOS version"
out_has 'GB of disk space is free' "... the disk"
out_has 'Cannot reach' "... the internet"
fr_env
FR_ARGS="--accept-legal-notice --bundle $H/nowhere"
fr_run "2
"
rc_not 0 "a --bundle that is not an app folder is refused"
out_has 'files of the app were not found' "... with the cause"

# --- the integrity of the runtime ------------------------------------------------------------------------------------
fr_env
printf 'tampered' >> "$FAKE_RES/runtime/python-runtime.tar.gz"
fr_run "2
"
rc_not 0 "a runtime archive that does not match components.json is refused"
out_has 'ERROR in step \[2/7\]' "... in step 2"
out_has 'does not match its checksum' "... with the cause"
[ ! -e "$SUPPORT/runtime/python" ] && [ ! -s "$LOGS/setup_python.log" ] && [ ! -e "$SUPPORT/components-installed.json" ]; check $? "... nothing was unpacked, nothing was installed, no record was written"
cp "$DMG_FIX/python-runtime.tar.gz" "$FAKE_RES/runtime/python-runtime.tar.gz"
fr_run "2
"
rc_is 0 "after the archive is restored the same script resumes and finishes"
fr_env
printf '{"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$(printf 'x' | shasum -a 256 | awk '{ print $1 }')" "$FAKE_LOCK_SHA" > "$FAKE_MC/components.json"
fr_run "2
"
rc_not 0 "a components.json that names another checksum than the archive is refused too"
[ ! -e "$SUPPORT/runtime/python" ]; check $? "... nothing was unpacked"
fr_env
printf '{"python_runtime":{"file":"../../../../../../../../../../../../../../../../../../../../../../../../../etc/hosts","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$RT_SHA" "$FAKE_LOCK_SHA" > "$FAKE_MC/components.json"
fr_run "2
"
rc_not 0 "a components.json that points outside the app is refused"
out_has 'outside the app' "... with the cause"
fr_env
printf 'not json' > "$FAKE_MC/components.json"
fr_run "2
"
rc_not 0 "a damaged components.json is refused"
out_has 'damaged or incomplete' "... with the cause"

# --- resume after a failure at each step ---------------------------------------------------------------------------
fr_env
fr_run "2
" STUB_CURL_DOWN=pypi.org
rc_not 0 "resume, step 1: the internet is down"
fr_run "2
"
rc_is 0 "... the next run finishes"
fr_env
touch "$STATE/fail-setup-python"
fr_run "2
"
rc_not 0 "resume, step 3: setup_python.sh fails"
out_has 'ERROR in step \[3/7\]' "... in step 3"
out_has 'setup_python.sh stopped' "... with the cause"
out_has 'Run this script again: it resumes' "... and the way on"
[ -f "$SUPPORT/runtime/python-runtime.sha256" ] && [ ! -e "$SUPPORT/config.env" ] && [ ! -e "$SUPPORT/components-installed.json" ]; check $? "... the unpacked runtime stays, no config.env and no record were written"
[ ! -L "$SUPPORT/.first-run.lock" ]; check $? "... and the lock is released (the next run is not refused)"
rm -f "$STATE/fail-setup-python"
fr_run "2
"
rc_is 0 "... the next run finishes"
out_has 'already unpacked and matches this app' "... without unpacking the runtime again"
[ "$(grep -c . "$LOGS/setup_python.log")" = 2 ]; check $? "... and setup_python.sh ran twice in total"
fr_env
touch "$STATE/api-set-fails"
fr_run "1
sk-ant-FAKE-NOT-USED
"
rc_is 0 "resume, step 4: a key that could not be stored does not stop the installation"
out_has 'the key was not stored' "... it is a warning that says where to enter it later"
fr_env
fr_run "2
" STUB_LN_FAIL=1
rc_not 0 "resume, step 5: config.env cannot be created"
out_has 'ERROR in step \[5/7\]' "... in step 5"
[ ! -e "$SUPPORT/config.env" ] && no_leftovers; check $? "... no config.env and no half-written file is left"
fr_run "2
"
rc_is 0 "... the next run finishes"
[ -f "$SUPPORT/config.env" ]; check $? "... and creates config.env"

# --- the hash lock of the app reaches setup_python.sh ----------------------------------------------------------------
fr_env
cp "$DMG_FIX/hash-lock.txt" "$FAKE_MC/pipeline/requirements.hash-lock.txt"
fr_run "2
"
rc_is 0 "an app that carries a hash lock: the run succeeds"
[ "$(cat "$LOGS/setup_python.log")" = "setup_python --python $SUPPORT/runtime/python/bin/python3 --with-silero --pre-download-model --hash-lock $FAKE_MC_P/pipeline/requirements.hash-lock.txt" ]; check $? "... --hash-lock <the app's requirements.hash-lock.txt> reaches setup_python.sh"
out_has 'carries a hash lock' "... and the helper says so"

# --- the bundled Python must run (step 2) -------------------------------------------------------------------------------
fr_env
cp "$DMG_FIX/python-old.tar.gz" "$FAKE_RES/runtime/python-runtime.tar.gz"
printf '{"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$OLD_RT_SHA" "$FAKE_LOCK_SHA" > "$FAKE_MC/components.json"
fr_run "2
"
rc_not 0 "a bundled Python that does not run (or is older than 3.12) stops the helper"
out_has 'ERROR in step \[2/7\]' "... in step 2"
out_has 'does not run on this Mac' "... with the cause"
[ ! -e "$SUPPORT/runtime/python" ] && [ ! -e "$SUPPORT/runtime/python-runtime.sha256" ] && [ ! -s "$LOGS/setup_python.log" ] && [ ! -e "$SUPPORT/components-installed.json" ]; check $? "... nothing was moved into place, nothing was installed, no record was written"
[ ! -L "$SUPPORT/.first-run.lock" ] && [ -z "$(find "$SUPPORT/runtime" -name '.python.*' 2>/dev/null | head -n 1)" ]; check $? "... the lock is released and the unpacked folder is removed"
fr_env
fr_run "2
"
rc_is 0 "a working runtime is installed first ..."
cp "$DMG_FIX/python-old.tar.gz" "$FAKE_RES/runtime/python-runtime.tar.gz"
printf '{"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"%s"},"requirements_lock_sha256":"%s"}\n' "$OLD_RT_SHA" "$FAKE_LOCK_SHA" > "$FAKE_MC/components.json"
fr_run "2
"
rc_not 0 "... then an app whose new runtime does not run is refused"
[ -x "$SUPPORT/runtime/python/bin/python3" ] && [ "$(cat "$SUPPORT/runtime/python-runtime.sha256")" = "$RT_SHA" ]; check $? "... and the runtime that works is still in place, with its own checksum"

# --- one helper at a time (the lock) ---------------------------------------------------------------------------------
fr_env
touch "$STATE/block-setup-python"
( cd "$H" && printf '2\n' | env HOME="$H" PATH="$STUBS_FR:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$H/tmp" MCAP_SUPPORT_DIR="$SUPPORT" MCAP_LOG_DIR="$APPLOGS" STUB_LOG="$LOGS" \
    STUB_STATE="$STATE" MCAP_UI_LANGUAGE=en /bin/bash "$FAKE_MC/scripts/first_run_install.sh" --accept-legal-notice ) > "$WORK/first-holder.$N.txt" 2>&1 &
HOLDER_PID=$!
waited=0; while [ ! -f "$STATE/setup-python-started" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited + 1)); done
[ -f "$STATE/setup-python-started" ]; check $? "the first helper is inside step 3 (held there by the fake setup_python.sh)"
LOCK_LINK="$SUPPORT/.first-run.lock"
[ -L "$LOCK_LINK" ] && kill -0 "$(readlink "$LOCK_LINK")" 2>/dev/null; check $? "... it holds the lock: a link whose target is the pid of a running process"
mkdir -p "$SUPPORT/runtime/.python.new.4242"          # what the first run could be unpacking: the second run's cleanup of such folders must NOT happen
HOLDER_TARGET="$(readlink "$LOCK_LINK")"
fr_run "2
"
rc_not 0 "a second helper started meanwhile is refused"
out_has 'ERROR in step \[2/7\]' "... at the start of step 2"
out_has 'Another installer window is already running \(process [0-9]+\)' "... with the reason and the process"
out_has 'close every Terminal window' "... and what to do if the other window cannot be found"
[ -d "$SUPPORT/runtime/.python.new.4242" ]; check $? "... it deleted nothing of the first run (the cleanup of .python.new.* comes after the lock)"
[ "$(grep -c . "$LOGS/setup_python.log")" = 1 ] && [ "$(readlink "$LOCK_LINK")" = "$HOLDER_TARGET" ]; check $? "... started no second setup_python.sh and left the lock of the first run in place"
fr_run "2
" MCAP_UI_LANGUAGE=ko
rc_not 0 "a second helper in Korean is refused too"
out_has '다른 설치 창이 이미 실행 중이에요' "... with the Korean message"
rm -rf "$SUPPORT/runtime/.python.new.4242"
rm -f "$STATE/block-setup-python"
wait "$HOLDER_PID"; HOLDER_RC=$?
[ "$HOLDER_RC" = 0 ] && [ -f "$SUPPORT/components-installed.json" ]; check $? "the first helper finishes (exit code $HOLDER_RC) and writes its record"
[ ! -L "$LOCK_LINK" ] && no_leftovers; check $? "... and the lock is gone: a third run is not refused"
fr_run "2
"
rc_is 0 "a helper started after the first one has ended runs"
# a lock that names a process that has ended (a crashed helper), a process that is not this script (a recycled pid) and garbage: all stale
for kind in dead recycled garbage; do
    fr_env
    mkdir -p "$SUPPORT"
    case "$kind" in
        dead) ( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null; ln -s "$DEAD_PID" "$SUPPORT/.first-run.lock" ;;
        recycled) ln -s "$$" "$SUPPORT/.first-run.lock" ;;                       # this test script: alive, but it is not a first_run_install
        garbage) ln -s "not-a-pid" "$SUPPORT/.first-run.lock" ;;
    esac
    fr_run "2
"
    rc_is 0 "a stale lock ($kind) is ignored and the helper runs"
    [ ! -L "$SUPPORT/.first-run.lock" ] && [ -f "$SUPPORT/components-installed.json" ]; check $? "... and is removed at the end"
done
fr_env
mkdir -p "$SUPPORT"
bash -c 'sleep 60; :' first_run_install.sh & LOOKALIKE_PID=$!
ln -s "$LOOKALIKE_PID" "$SUPPORT/.first-run.lock"
fr_run "2
"
RC_LOCK=$RC
kill "$LOOKALIKE_PID" 2>/dev/null; wait "$LOOKALIKE_PID" 2>/dev/null
[ "$RC_LOCK" != 0 ]; check $? "a lock that names a live process that looks like the helper refuses the run"
out_has 'Another installer window is already running' "... with the message"
[ ! -e "$SUPPORT/runtime/python" ] && [ ! -s "$LOGS/setup_python.log" ]; check $? "... and nothing was unpacked or installed"

# --- the meeting folder (step 6) -----------------------------------------------------------------------------------
fr_env
mkdir -p "$DRIVE/My Drive"
fr_run "2
y
"
rc_is 0 "one Google Drive account: the question is asked and y is accepted"
out_has 'Use Google Drive\?' "... the question names Google Drive"
out_has 'audio files are uploaded' "... and says that the audio goes to that Drive"
grep -qx 'ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-pat@example.com/My Drive/Meetings' "$SUPPORT/config.env"; check $? "... ARCHIVE_DIR becomes its My Drive/Meetings"
[ -d "$DRIVE/My Drive/Meetings" ]; check $? "... and the folder is created"
fr_env
mkdir -p "$DRIVE/My Drive"
fr_run "2
n
"
rc_is 0 "one Google Drive account and the answer n"
grep -qx 'ARCHIVE_DIR=~/Meetings' "$SUPPORT/config.env" && [ ! -d "$DRIVE/My Drive/Meetings" ]; check $? "... ARCHIVE_DIR stays ~/Meetings and nothing is created in Drive"
fr_env
mkdir -p "$DRIVE/My Drive"
fr_run "2

"
rc_is 0 "one Google Drive account and an empty answer"
grep -qx 'ARCHIVE_DIR=~/Meetings' "$SUPPORT/config.env"; check $? "... the default is no (meetings stay on this Mac)"
fr_env
mkdir -p "$DRIVE/My Drive" "$H/Library/CloudStorage/GoogleDrive-other@example.com/My Drive"
fr_run "2
"
rc_is 0 "two Google Drive accounts"
out_lacks 'Use Google Drive' "... no question (the helper does not guess which one)"
fr_env
fr_run "2
"
out_lacks 'Use Google Drive' "no Google Drive account: no question"
fr_env
mkdir -p "$DRIVE/My Drive"
fr_run "2
y
" STUB_MV_FAIL_CONFIG=1
rc_not 0 "resume, step 6: ARCHIVE_DIR cannot be written"
out_has 'ERROR in step \[6/7\]' "... in step 6"
grep -qx 'ARCHIVE_DIR=~/Meetings' "$SUPPORT/config.env" && ! grep -q 'archive_answered' "$SUPPORT/first-run.state" && no_leftovers; check $? "... config.env still has the old line, the answer is not remembered, no temporary file is left"
fr_run "2
y
"
rc_is 0 "... the next run asks again and finishes"
grep -qx 'ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-pat@example.com/My Drive/Meetings' "$SUPPORT/config.env"; check $? "... with the Drive folder"
fr_run "2
"
out_lacks 'Use Google Drive' "a third run does not ask again"

# --- the API key (step 4) --------------------------------------------------------------------------------------------
fr_env
fr_run "2
"
! grep -q 'api-key set' "$LOGS/venv-python.log"; check $? "[2] later: api-key set is not run"
grep -qx 'python -m mcap api-key status --exists' "$LOGS/venv-python.log" && ! grep -qx 'python -m mcap api-key status' "$LOGS/venv-python.log" && [ ! -s "$LOGS/venv-python.violations" ]; check $? "step 4 only asks  api-key status --exists  (is there an item?), never plain  api-key status  (which reads the value)"
fr_env
CANARY="sk-ant-api03-FAKE-CANARY-DO-NOT-USE-0123456789"
fr_run "1
$CANARY
"
rc_is 0 "[1] enter it now: the run succeeds"
grep -q '^python -m mcap api-key set$' "$LOGS/venv-python.log"; check $? "... through  python -m mcap api-key set  of the new venv"
[ "$(cat "$STATE/keychain")" = "$CANARY" ]; check $? "... the key reached the (fake) keychain tool through the terminal's standard input"
! grep -q "$CANARY" "$LOGS/venv-python.log" && ! grep -q "$CANARY" "$LOGS/venv-python.env"; check $? "... but never an argument or an environment variable of any call"
! grep -q "$CANARY" "$OUT" && ! grep -rq "$CANARY" "$SUPPORT" && ! grep -q "$CANARY" "$LOGS/setup_python.log" "$LOGS/setup_python.env" "$LOGS/open.log" "$LOGS/curl.log"; check $? "... and it is in no output, no file of SUPPORT_DIR and no other recorded call"
[ ! -s "$LOGS/security.log" ]; check $? "... the helper itself never ran the security tool"
# The real `python -m mcap api-key status --exists` behind the helper, with a stub security tool (MCAP_SECURITY_BIN) that logs its argv: the question is
# find-generic-password WITHOUT -w and -g, so the stored value is never read and no Keychain dialog can appear. Skipped on a policy-managed Mac, where the
# variable is ignored and the real tool would run.
if [ -e "/Library/Application Support/MeetingCapture/policy.json" ] || [ -e "/Library/Application Support/MeetingCapture/policy.required" ]; then
    echo "  (skipped: this Mac has an organisation policy, MCAP_SECURITY_BIN would be ignored and the real security tool would run)"
else
    SECSTUB="$WORK/security-stub"; mkdir -p "$SECSTUB"
    cat > "$SECSTUB/security" <<'SECEOF'
#!/bin/sh
# stub security tool (MCAP_SECURITY_BIN): logs its argument line next to itself (the tool gets a clean environment: no STUB_* variables) and answers
# found (0) or not found (44) as the file "rc" next to it says
here="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$here/argv.log"
exit "$(cat "$here/rc" 2>/dev/null || echo 0)"
SECEOF
    chmod +x "$SECSTUB/security"
    SEC_LOG="$SECSTUB/argv.log"
    fr_env
    rm -f "$SEC_LOG"; echo 0 > "$SECSTUB/rc"
    fr_run "" MCAP_SECURITY_BIN="$SECSTUB/security" STUB_REAL_MCAP="$ROOT" STUB_REAL_PY="$PYTHON_FOR_TESTS"
    rc_is 0 "real mcap behind the helper, an item exists: nothing is asked"
    out_has 'already stored in the macOS Keychain' "... the helper says the key is stored"
    [ "$(grep -c . "$SEC_LOG")" = 1 ] && grep -q '^find-generic-password -s MeetingCapture Anthropic API key -a ' "$SEC_LOG"; check $? "... the security tool was asked exactly once: find-generic-password for that service and account"
    ! grep -qE -- ' -w| -g' "$SEC_LOG"; check $? "... without -w and -g: the stored value is never read"
    [ ! -s "$LOGS/security.log" ]; check $? "... and the helper's own PATH still saw no security call"
    fr_env
    rm -f "$SEC_LOG"; echo 44 > "$SECSTUB/rc"
    fr_run "2
" MCAP_SECURITY_BIN="$SECSTUB/security" STUB_REAL_MCAP="$ROOT" STUB_REAL_PY="$PYTHON_FOR_TESTS"
    rc_is 0 "real mcap behind the helper, no item: the question is asked, [2] later is a skip"
    out_has 'Skipped' "... and says so"
    [ "$(grep -c . "$SEC_LOG")" = 1 ] && ! grep -qE -- ' -w| -g' "$SEC_LOG"; check $? "... still one question without -w (the value is never read)"
fi
fr_env
mkdir -p "$STATE"; echo stored > "$STATE/keychain"
fr_run ""
rc_is 0 "a key that is already stored: nothing is asked"
out_has 'already stored in the macOS Keychain' "... and the helper says so"
fr_env
fr_run "2
"
out_has 'does not install' "no Claude Code tool on the PATH: the note says notes need it (and that the helper does not install it)"
fr_env
FR_PATH_EXTRA="$STUBS_CLAUDE"
fr_run "2
"
out_has 'The Claude Code tool is installed' "the Claude Code tool on the PATH: no note"
FR_PATH_EXTRA=""

# --- step 7 -------------------------------------------------------------------------------------------------------
fr_env
fr_run "2
" STUB_OPEN_RC=1
rc_is 0 "step 7: an app permission check that cannot start is only a warning"
out_has 'could not be started' "... that says so"
[ -f "$SUPPORT/components-installed.json" ]; check $? "... and the record is written (the components are installed)"
fr_env
fr_run "2
" STUB_SETUP_REPORT="[FAIL] permission microphone: denied"
rc_is 0 "step 7: a setup report with a [FAIL] line is a warning"
out_has 'reported 1 problem' "... that counts the problems"
out_has 'setup-report.txt' "... and names the report"
fr_env
rm -rf "$FAKE_APP/Contents/MacOS"
fr_run "2
"
rc_is 0 "step 7: no app next to its files: the permission step is skipped with a note"
out_has 'permission step was skipped' "... that says so"

# --- the copy that the app keeps in SUPPORT_DIR ----------------------------------------------------------------------
fr_env
mkdir -p "$SUPPORT"
cp "$FAKE_MC/scripts/first_run_install.sh" "$SUPPORT/first-run-install.command"; chmod 755 "$SUPPORT/first-run-install.command"
printf 'MCAP_BUNDLE_DIR=%s\n' "$FAKE_MC" > "$SUPPORT/first-run.env"
FR_SCRIPT="$SUPPORT/first-run-install.command"
fr_run "2
"
rc_is 0 "the copy in SUPPORT_DIR finds the app through first-run.env (a moved or renamed install folder does not matter)"
out_has "App files: $FAKE_MC_P" "... and says which app files it uses"
FR_SCRIPT=""

# --- static properties of the helper -------------------------------------------------------------------------------------
H1="$ROOT/scripts/first_run_install.sh"
! grep -nE '^[[:space:]]*(sudo|launchctl|eval|exec)[[:space:]]' "$H1" >/dev/null && ! grep -nE '(^|[;&|(`])[[:space:]]*security[[:space:]]' "$H1" >/dev/null; check $? "first_run_install.sh never runs sudo, launchctl, eval or the security tool"
! grep -nE 'read[[:space:]]+(-[a-z]*s|-s)' "$H1" >/dev/null; check $? "... and has no hidden prompt of its own (the key is typed into the macOS security tool, never into this script)"
! grep -nE 'curl[^#]*\|[[:space:]]*(ba|z)?sh' "$H1" >/dev/null; check $? "... never pipes a download into a shell"
[ "$(grep -c 'open -n -W -a' "$H1")" -ge 1 ] && ! grep -nE 'open +(-W|-a)' "$H1" | grep -vE 'open +-n ' >/dev/null; check $? "... starts the app's setup with open -n -W -a"
[ "$(grep -cE '^[[:space:]]*curl ' "$H1")" = 0 ]; check $? "... downloads nothing itself (curl is only used for the two HEAD requests inside reachable())"
grep -q -- '--head' "$H1"; check $? "... and those are HEAD requests"
! grep -nE "[\$]\{[A-Za-z_]+:[-=+?][^}]*'" "$H1" "$ROOT/scripts/build_dmg.sh" "$ROOT/scripts/fetch_python_runtime.sh" >/dev/null; check $? "no script has an apostrophe inside a \${var:-word} expansion (bash 3.2 pairs it with a later quote and swallows the code in between)"

# ---------------------------------------------------------------------------------------------------------------
section "dmg installer: Swift side and scripts agree (names, hashes, pinned models), docs and Makefile"
# ---------------------------------------------------------------------------------------------------------------
cat > "$WORK/doc_dmg.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
def read(rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()
problems = []
def need(cond, text):
    if not cond:
        problems.append(text)
swift, setup, helper, build = read("app/Sources/FirstRun.swift"), read("scripts/setup_python.sh"), read("scripts/first_run_install.sh"), read("scripts/build_dmg.sh")
# 1. the pinned speech model and the Silero model are the numbers of setup_python.sh (the app checks them without a network)
m = re.search(r'whisper-large-v3\)\s*\n\s*M_REPO="([^"]+)"\s*\n\s*M_REV="([0-9a-f]{40})".*?M_FILE="([^"]+)"; M_FILE_BYTES=(\d+)', setup, re.S)
need(m is not None, "setup_python.sh: the whisper-large-v3 model entry was not found")
if m:
    repo, rev, file, size = m.group(1), m.group(2), m.group(3), int(m.group(4))
    need('modelRepoDir = "models--%s"' % repo.replace("/", "--") in swift, "FirstRun.swift: modelRepoDir is not models--%s" % repo.replace("/", "--"))
    need('modelRevision = "%s"' % rev in swift, "FirstRun.swift: modelRevision is not the pinned revision of setup_python.sh (%s)" % rev)
    need('modelFile = "%s"' % file in swift, "FirstRun.swift: modelFile is not %s" % file)
    need(re.search(r"modelBytes: Int64 = %s\b" % re.escape("{:,}".format(size).replace(",", "_")), swift) is not None, "FirstRun.swift: modelBytes is not %d (setup_python.sh)" % size)
sil = re.search(r"SILERO_ONNX_BYTES=(\d+)", setup)
need(sil is not None and re.search(r"sileroBytes: Int64 = %s\b" % "{:,}".format(int(sil.group(1))).replace(",", "_"), swift) is not None, "FirstRun.swift: sileroBytes is not SILERO_ONNX_BYTES of setup_python.sh")
need('sileroFile = "silero_vad.onnx"' in swift and "silero_vad.onnx" in setup, "the Silero file name differs between FirstRun.swift and setup_python.sh")
# 2. the names the app and the helper share
for name in ("components-installed.json", "first-run.env", "first-run-install.command", "components.json"):
    need(name in swift, "FirstRun.swift does not mention %s" % name)
need("components-installed.json" in helper and "first-run.env" in helper and "components.json" in helper, "first_run_install.sh does not use components-installed.json / first-run.env / components.json")
need("first-run-install.command" in helper or "first_run_install.sh" in helper, "the helper does not know its own copy name")
need('bundledScript = "scripts/first_run_install.sh"' in swift and os.path.exists(os.path.join(root, "scripts/first_run_install.sh")), "FirstRun.swift: the bundled script is not scripts/first_run_install.sh")
need("MCAP_BUNDLE_DIR=" in swift and "MCAP_BUNDLE_DIR" in helper, "the key MCAP_BUNDLE_DIR of first-run.env differs between FirstRun.swift and the helper")
# the exact subscripts of the Swift parser (the contract itself is checked by running the parser on the real output of both scripts: selftest-firstrun above)
for sub in ('object["python_runtime"]', 'runtime["sha256"]', 'object["requirements_lock_sha256"]'):
    need(sub in swift, "FirstRun.swift: parseBundleComponents no longer reads %s" % sub)
for key in ("python_runtime", "sha256", "requirements_lock_sha256"):
    need(key in build and key in helper, "%s of components.json is not used by both build_dmg.sh and first_run_install.sh" % key)
need('lockName = ".first-run.lock"' in swift and '.first-run.lock' in helper, "the lock name differs between FirstRun.swift and the helper (.first-run.lock)")
need("api-key status --exists" in helper and "item_exists" in read("pipeline/mcap/apikey.py"), "the helper must ask  api-key status --exists  (apikey.item_exists), not read the key")
need("never reads the keychain" not in helper and "never reads the keychain" not in read("SECURITY.md"), "the helper and SECURITY.md must not claim that nothing reads the keychain: its Python child asks the security tool")
need("without `-w`" in read("SECURITY.md") and "reads the item back once" in read("SECURITY.md"), "SECURITY.md must say what the helper's Python child asks the Keychain (an existence question without -w, one read-back after a set)")
need("first_run_install.sh" in build and "setup_python.sh" in build and "legal_notice.sh" in build and "bundle_id.sh" in build, "build_dmg.sh does not put the helper scripts (and bundle_id.sh, which they read the names of the app from) into the app")
need('case "setup"' in read("app/Sources/main.swift") and "--args setup" in helper, "the helper starts `--args setup` and main.swift must have that command")
# 3. the app finds its pipeline inside itself, the key PROJECT_DIR still wins (Config.swift) and the helper leaves it out of config.env
cfg = read("app/Sources/Config.swift")
need("bundledProjectDir" in cfg and "Contents/Resources/mcap" in cfg, "Config.swift: the project folder inside the app is not resolved")
need('if let u = path("PROJECT_DIR", isDir: true) { cfg.projectDir = u }' in cfg, "Config.swift: the config.env key PROJECT_DIR no longer overrides")
need("PROJECT_DIR" in helper and "not set on purpose" in helper, "the helper must leave PROJECT_DIR out of the new config.env")
# 4. the layout contract of build_dmg.sh: python-runtime.lock, hdiutil settings, no notarization
need("UDZO" in build and 'VOLUME_NAME="$APP_NAME"' in build and "/Applications" in build, "build_dmg.sh: UDZO, the volume name (the human name of the app) or the /Applications link is missing")
need(not re.search(r"^\s*(xcrun\s+)?(notarytool|stapler)\b", build, re.M), "build_dmg.sh must never RUN notarytool or stapler")
need("notariz" in build.lower() or "Developer ID" in build, "build_dmg.sh should say that it does not notarize")
# 5. the docs
dist, guide, guide_en, readme_txt = read("docs/DISTRIBUTE.md"), read("docs/USER_GUIDE.ko.md"), read("docs/USER_GUIDE.md"), read("dmg/README-install.txt")
for kw, why in (("fetch_python_runtime.sh", "the runtime download"), ("python-runtime.lock", "the lock file"), ("build_dmg.sh", "the dmg build"), ("make_signing_identity.sh", "the signing identity"),
                ("MCAP_BUILT_BY", "the builder line"), ("MCAP_BUNDLE_ID", "the bundle identifier of a distributor's own build"), ("Control-click", "Gatekeeper: Control-click"),
                ("Open Anyway", "Gatekeeper: Open Anyway"), ("Privacy & Security", "System Settings"), ("Developer ID", "what a Developer ID would change"), ("notariz", "notarization"),
                ("self-signed", "the self-signed identity"), ("second Mac", "the test on a second Mac"), ("file host", "sharing through a file host of your choice"),
                ("GitHub release", "a release on GitHub"), ("Publishing a release on GitHub", "the section on publishing a release"), (".dmg.sha256", "the checksum file to upload"),
                ("shasum -a 256", "the checksum for the people who download"), ("Only Zoom has been verified", "the Zoom-only status"), ("Not verified", "what was not verified"),
                ("this app records people", "the recorded-people warning"), ("consent", "the consent warning"), ("PRIVACY_AND_CONSENT.md", "the consent page"),
                ("components.json", "the layout contract"), ("first_run_install.sh", "the helper"), ("PENDING", "the lock placeholders"), ("VERSION", "versioning"),
                ("README-install.txt", "the readme in the image"), ("components-installed.json", "the record of the first run"), ("sha256", "the checks"),
                ("AppTranslocation", "running from the disk image")):
    need(kw in dist, "docs/DISTRIBUTE.md must mention %s (%r)" % (why, kw))
# the Korean guide and its English twin: the same things, in each language
for kw, why in (("Control", "Control-click"), ("열기", "Open"), ("그래도 열기", "Open Anyway"), ("Zoom", "what was verified"), ("터미널", "the Terminal window"), ("마이크", "the microphone prompt"),
                ("시스템 오디오", "the system audio prompt"), ("알림", "the notification prompt"), ("참가자", "the notice to participants"), ("Anthropic", "what leaves the Mac: Claude"),
                ("Google Drive", "where the meetings go"), ("확인되지 않았", "what is not verified"), ("문의", "who to ask"), ("일시", "how to pause"), ("종료", "how to quit"),
                ("~/Meetings", "where recordings and notes go"), ("API 키", "the key"), ("4 GB", "the download size"), ("Teams", "the platforms that are recorded"),
                ("개인 메신저", "that personal messengers are recorded"), ("Google Meet는 기본으로 꺼져", "that Meet is off by default"), ("Call Apps", "the menu to switch an app off"),
                ("자체 서명", "that the app is self-signed"), ("공증", "that it is not notarized"), ("shasum -a 256", "the checksum"), ("Local-Only", "the local-only meeting"),
                ("USER_GUIDE.md", "the link to the English guide")):
    need(kw in guide, "docs/USER_GUIDE.ko.md must mention %s (%r)" % (why, kw))
for kw, why in (("Control-click", "Control-click"), ("Open Anyway", "Open Anyway"), ("Zoom", "what was verified"), ("Terminal", "the Terminal window"), ("Microphone", "the microphone prompt"),
                ("System audio", "the system audio prompt"), ("Notifications", "the notification prompt"), ("participants", "the notice to participants"), ("Anthropic", "what leaves the Mac: Claude"),
                ("Google Drive", "where the meetings go"), ("Not verified", "what is not verified"), ("Ask the person who sent you this file", "who to ask"),
                ("Pause Auto Recording", "how to pause"), ("**Quit**", "how to quit"), ("~/Meetings", "where recordings and notes go"), ("API key", "the key"), ("4 GB", "the download size"),
                ("Teams", "the platforms that are recorded"), ("personal messengers", "that personal messengers are recorded"), ("Google Meet is off by default", "that Meet is off by default"),
                ("Call Apps", "the menu to switch an app off"), ("self-signed", "that the app is self-signed"), ("notarized", "that it is not notarized"), ("shasum -a 256", "the checksum"),
                ("Local-Only", "the local-only meeting"), ("USER_GUIDE.ko.md", "the link to the Korean guide")):
    need(kw in guide_en, "docs/USER_GUIDE.md must mention %s (%r)" % (why, kw))
def numbered_sections(text):
    return re.findall(r"^## (\d+)\. ", text, re.M)
def code_spans(text):
    # language-neutral code spans only: the file name placeholder and the folder pattern differ by language on purpose
    return {c for c in re.findall(r"`([^`]+)`", text) if not re.search(r"[가-힣]|<version>|<버전>|year-month|연-월", c)}
need(numbered_sections(guide) == numbered_sections(guide_en) == [str(n) for n in range(1, 13)], "the Korean and the English guide must have the same twelve numbered sections")
need(len([l for l in guide.splitlines() if l.startswith("|")]) == len([l for l in guide_en.splitlines() if l.startswith("|")]), "the two guides must have the same number of table rows")
need(len([l for l in guide.splitlines() if re.match(r"\s*(- |\d+\. )", l)]) == len([l for l in guide_en.splitlines() if re.match(r"\s*(- |\d+\. )", l)]), "the two guides must have the same number of list items")
need(len([l for l in guide.splitlines() if l.startswith(">")]) == len([l for l in guide_en.splitlines() if l.startswith(">")]), "the two guides must have the same sample notice to participants")
need(code_spans(guide) == code_spans(guide_en), "the two guides must name the same commands, paths and menu items: %s" % sorted(code_spans(guide) ^ code_spans(guide_en)))
need(len(guide_en) > 0.5 * len(guide), "docs/USER_GUIDE.md looks like a summary of the Korean guide, not the same guide")
need(len([l for l in readme_txt.splitlines() if l.strip()]) <= 10, "dmg/README-install.txt must stay at 10 lines")
need(re.search(r"[가-힣]", readme_txt) is not None and "Applications" in readme_txt and "Open Anyway" in readme_txt, "dmg/README-install.txt is bilingual and names Applications and Open Anyway")
need("self-signed" in readme_txt and "USER_GUIDE" in readme_txt and "consent" in readme_txt, "dmg/README-install.txt must say the app is self-signed, point to the user guide and mention consent")
need("only Zoom calls are verified" in readme_txt and "Zoom 통화뿐" in readme_txt, "dmg/README-install.txt must say, in both languages, that only Zoom calls are verified (it names the other call apps)")
need("USER_GUIDE" in helper, "the end of first_run_install.sh must point to the user guide")
# promises the documents must not make (review findings): notarization is not planned, the table rows are counted right, the roadmap lists only what is not done yet,
# and the Keychain is not tied to the bundle id (every Keychain access goes through /usr/bin/security, whose item ACL names that tool, not the app)
for rel in ("docs/USER_GUIDE.md", "docs/USER_GUIDE.ko.md", "docs/DISTRIBUTE.md", "scripts/build_dmg.sh", "dmg/README-install.txt"):
    need(re.search(r"planned for later|comes later|나중에 할 예정|notarized it yet|아직 Apple", read(rel)) is None, "%s promises notarization for later (there is no plan or date)" % rel)
need("There is no plan or date for notarization" in guide_en and "공증 계획이나 일정은 없어요" in guide, "the guides must say that there is no plan or date for notarization")
need("rows three to six" in guide_en and "셋째 줄부터 여섯째 줄" in guide, "the guides must name rows three to six of the table as what Local-Only blocks")
need("포크가 바꿀 수 있는 식별자" not in read("README.ko.md"), "README.ko.md still lists the identifiers a fork can change as roadmap (MCAP_BUNDLE_ID does that)")
for rel in ("CHANGELOG.md", "CONTRIBUTING.md", "docs/CONFIGURATION.md", "docs/DISTRIBUTE.md"):
    need(re.search(r"Keychain approvals", read(rel)) is None, "%s ties Keychain approvals to the bundle id (it is only the Microphone, System Audio Recording and Notifications permissions)" % rel)
# links: every guide and doc of the personal path links the other language and DISTRIBUTE.md, every README and INSTALL.md links both guides
need("(USER_GUIDE.md)" in guide and "(DISTRIBUTE.md)" in guide, "docs/USER_GUIDE.ko.md must link to USER_GUIDE.md and DISTRIBUTE.md")
need("(USER_GUIDE.ko.md)" in guide_en and "(DISTRIBUTE.md)" in guide_en, "docs/USER_GUIDE.md must link to USER_GUIDE.ko.md and DISTRIBUTE.md")
need("(USER_GUIDE.md)" in dist and "(USER_GUIDE.ko.md)" in dist, "docs/DISTRIBUTE.md must link to both user guides")
for rel in ("README.md", "README.ko.md"):
    need("DISTRIBUTE.md" in read(rel), "%s must link to docs/DISTRIBUTE.md" % rel)
    need("docs/USER_GUIDE.md" in read(rel) and "docs/USER_GUIDE.ko.md" in read(rel), "%s must link to both user guides" % rel)
need("DISTRIBUTE.md" in read("docs/INSTALL.md") and "USER_GUIDE.md" in read("docs/INSTALL.md") and "USER_GUIDE.ko.md" in read("docs/INSTALL.md"), "docs/INSTALL.md must link to DISTRIBUTE.md and both user guides")
def slug(heading):
    return re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", heading.strip().lower()))
for rel in ("docs/DISTRIBUTE.md", "docs/USER_GUIDE.ko.md", "docs/USER_GUIDE.md", "docs/INSTALL.md", "README.md", "README.ko.md"):
    for target, anchor in re.findall(r"\]\(([^)#\s:]+)(#[^)\s]*)?\)", read(rel)):
        path = os.path.normpath(os.path.join(os.path.dirname(os.path.join(root, rel)), target))
        if not os.path.exists(path):
            problems.append("%s links to %s, which does not exist" % (rel, target)); continue
        if anchor and path.endswith(".md"):
            slugs = {slug(h) for h in re.findall(r"^#+ (.+)$", open(path, encoding="utf-8").read(), re.M)}
            need(anchor[1:] in slugs, "%s links to %s%s, which has no such heading" % (rel, target, anchor))
need(not os.path.exists(os.path.join(root, "docs/EMPLOYEE_GUIDE.ko.md")), "docs/EMPLOYEE_GUIDE.ko.md was renamed to USER_GUIDE.ko.md and must not come back")
for path in glob.glob(os.path.join(root, "README*.md")) + glob.glob(os.path.join(root, "docs/*.md")) + glob.glob(os.path.join(root, "scripts/*.sh")) + [os.path.join(root, "Makefile")]:      # CHANGELOG.md names the old file once, on purpose: it records the rename
    if os.path.basename(path) != "test_scripts.sh":
        need("EMPLOYEE_GUIDE" not in open(path, encoding="utf-8").read(), "%s still names EMPLOYEE_GUIDE" % os.path.relpath(path, root))
# no owner-specific wording on the personal install path (the organisation documents DEPLOY.md, POLICY.md ... are a different path and are not listed)
for rel in ("docs/DISTRIBUTE.md", "docs/USER_GUIDE.ko.md", "docs/USER_GUIDE.md", "dmg/README-install.txt", "scripts/first_run_install.sh", "scripts/build_dmg.sh", "scripts/fetch_python_runtime.sh",
            "scripts/python-runtime.lock", "README.md", "README.ko.md", "docs/INSTALL.md"):
    found = re.findall(r"colleague|employee|company drive|직원|동료|사내|설치 담당|the owner", read(rel), re.I)
    need(not found, "%s has owner-specific wording: %s" % (rel, sorted(set(found))))
# nothing publishes by itself, and no README claims that a download exists
need("gh release" not in dist and "gh release" not in read("Makefile") and "gh release" not in build, "no command of DISTRIBUTE.md, the Makefile or build_dmg.sh may publish a release")
for rel in ("README.md", "README.ko.md", "docs/DISTRIBUTE.md", "docs/USER_GUIDE.ko.md", "docs/USER_GUIDE.md", "dmg/README-install.txt"):
    need(re.search(r"github\.com/[^\s)]+/releases", read(rel)) is None, "%s must not link to a release that may not exist" % rel)
need("app installer" in read("CHANGELOG.md").lower() and "disk image" in read("CHANGELOG.md").lower(), "CHANGELOG.md must have an entry for the app installer (disk image)")
need("USER_GUIDE.md" in read("CHANGELOG.md") and "Publishing a release on GitHub" in read("CHANGELOG.md"), "CHANGELOG.md must have an entry for the generalised guide and docs")
need("first_run_install.sh" in read("SECURITY.md") or "app installer" in read("SECURITY.md").lower(), "SECURITY.md must say what the app installer does and does not protect")
# 6. no personal data and no hard-coded owner in the new files
for rel in ("scripts/build_dmg.sh", "scripts/fetch_python_runtime.sh", "scripts/first_run_install.sh", "scripts/python-runtime.lock", "app/Sources/FirstRun.swift", "docs/DISTRIBUTE.md",
            "docs/USER_GUIDE.ko.md", "docs/USER_GUIDE.md", "dmg/README-install.txt"):
    text = read(rel)
    need(not re.search(r"/Users/(?!someone|pat|alice)[A-Za-z0-9._-]+", text), "%s contains a home folder path of a real person" % rel)
    need(not re.search(r"[A-Za-z0-9._%+-]+@(?!example\.(com|org|invalid))[A-Za-z0-9.-]+\.[a-z]{2,}", text), "%s contains an e-mail address that is not an example address" % rel)
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/doc_dmg.py" "$ROOT" > "$WORK/doc_dmg.out" 2>&1; check $? "FirstRun.swift and the scripts share names, hashes and the pinned models; the project folder rule, the layout contract and the docs say what they must; no personal data"
[ -z "$(cat "$WORK/doc_dmg.out")" ] || sed 's/^/        > /' "$WORK/doc_dmg.out"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n dmg ARGS="--dry-run" ) > "$OUT" 2>&1; RC=$?
out_has 'scripts/build_dmg.sh --dry-run' "make dmg ARGS=... runs scripts/build_dmg.sh with the arguments"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make -n fetch-runtime ARGS="--out-dir build/runtime" ) > "$OUT" 2>&1; RC=$?
out_has 'scripts/fetch_python_runtime.sh --out-dir build/runtime' "make fetch-runtime ARGS=... runs scripts/fetch_python_runtime.sh"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make help ) > "$OUT" 2>&1; RC=$?
out_has 'make dmg ' "make help lists dmg"
out_has 'make fetch-runtime ' "... and fetch-runtime"
out_has 'Installer:' "... and the order line of the app installer"
N=$((N + 1)); OUT="$WORK/out.$N.txt"
( cd "$ROOT" && make lint ) > "$OUT" 2>&1; RC=$?
rc_is 0 "make lint passes with the new scripts"
out_has 'bash -n ok: scripts/build_dmg.sh' "make lint covers build_dmg.sh"
out_has 'bash -n ok: scripts/fetch_python_runtime.sh' "... fetch_python_runtime.sh"
out_has 'bash -n ok: scripts/first_run_install.sh' "... and first_run_install.sh"
# >>> dmg installer tests (end)

# ---------------------------------------------------------------------------------------------------------------
section "docs: the product is Catch Everything (CATE), the three build inputs are documented, the old name is left only where it is an internal name"
# ---------------------------------------------------------------------------------------------------------------
cat > "$WORK/doc_names.py" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
problems = []
def read(rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()
def need(cond, msg):
    if not cond:
        problems.append(msg)
lib = read("scripts/bundle_id.sh")
default_name = re.search(r'^MCAP_DEFAULT_APP_NAME="([^"]+)"', lib, re.M).group(1)
default_short = re.search(r'^MCAP_DEFAULT_APP_SHORT_NAME="([^"]+)"', lib, re.M).group(1)
need((default_name, default_short) == ("Catch Everything", "CATE"), "scripts/bundle_id.sh: the defaults are %r and %r, the docs say Catch Everything and CATE" % (default_name, default_short))

# 1. the entry documents introduce the product and its short name, and the file names that the default build gives
for rel in ("README.md", "README.ko.md", "docs/USER_GUIDE.md", "docs/USER_GUIDE.ko.md", "docs/DISTRIBUTE.md"):
    text = read(rel)
    need(default_name in text, "%s does not name the product %r" % (rel, default_name))
    need(re.search(r"\bCATE\b", text) is not None, "%s does not name the short name %s" % (rel, default_short))
    need("%s.app" % default_short in text, "%s does not name the app file %s.app" % (rel, default_short))
    need(re.search(r"%s-<(version|버전)>\.dmg" % default_short, text) is not None, "%s does not name the disk image %s-<version>.dmg" % (rel, default_short))
for rel in ("README.md", "README.ko.md"):
    head = read(rel).split("\n\n")[:2]
    need(head[0] == "# %s (%s)" % (default_name, default_short), "%s: the title is not '# %s (%s)'" % (rel, default_name, default_short))
    need(default_name in head[1] and default_short in head[1], "%s: the first paragraph does not introduce %s and %s" % (rel, default_name, default_short))
need("MeetingCapture" in read("README.md") and "internal name" in read("README.md"), "README.md must say once that the data folder, the log folder and the Keychain items keep the internal name MeetingCapture")
need("MeetingCapture" in read("README.ko.md") and "내부 이름" in read("README.ko.md"), "README.ko.md must say once that the data folder, the log folder and the Keychain items keep the internal name MeetingCapture")
for rel, word in (("docs/USER_GUIDE.md", "internal name"), ("docs/USER_GUIDE.ko.md", "내부 이름")):
    need(word in read(rel), "%s must say that the data folder and the Keychain items keep the internal name MeetingCapture" % rel)
need("MeetingCapture" in read("docs/CONFIGURATION.md").split("**What does not follow the names.**", 1)[-1], "docs/CONFIGURATION.md must list what keeps the internal name MeetingCapture")

# 2. the three inputs and their rules are written down where a distributor looks: the table, the build commands, the release variables, the changelog
config = read("docs/CONFIGURATION.md")
need(re.search(r"(?m)^\| `MCAP_APP_NAME` \| `%s` \|" % re.escape(default_name), config) is not None, "docs/CONFIGURATION.md: no row for MCAP_APP_NAME with the default %r" % default_name)
need(re.search(r"(?m)^\| `MCAP_APP_SHORT_NAME` \| `%s` \|" % re.escape(default_short), config) is not None, "docs/CONFIGURATION.md: no row for MCAP_APP_SHORT_NAME with the default %r" % default_short)
need(re.search(r"(?m)^\| `MCAP_BUNDLE_ID` \| `org\.meetingcapture\.app` \|", config) is not None, "docs/CONFIGURATION.md: no row for MCAP_BUNDLE_ID with its default")
for needle, why in (("1 to 40 characters", "the length rule of the human name"), ("1 to 32 characters", "the length rule of the short name"), ("no trailing space", "the trailing space rule"),
                    ("An empty value counts as unset", "that an empty value is unset"), ("install guard", "the install guard"), ("CFBundleDisplayName", "CFBundleDisplayName"), ("CFBundleName", "CFBundleName")):
    need(needle in config, "docs/CONFIGURATION.md must mention %s (%r)" % (why, needle))
dist = read("docs/DISTRIBUTE.md")
need("MCAP_APP_NAME" in dist and "MCAP_APP_SHORT_NAME" in dist and re.search(r"MCAP_BUNDLE_ID=\S+ MCAP_APP_NAME=\"[^\"]+\" MCAP_APP_SHORT_NAME=\S+ \\\n\s+make dmg", dist) is not None,
     "docs/DISTRIBUTE.md: the build command must set MCAP_BUNDLE_ID, MCAP_APP_NAME and MCAP_APP_SHORT_NAME together")
need("shared by every copy built from this source" in dist and "sets their own" in dist, "docs/DISTRIBUTE.md must say that the defaults are shared by every copy and that a distributor sets their own names and id")
for needle in ("<short name>-<version>.dmg", ".dmg.sha256", "volume"):
    need(needle in dist, "docs/DISTRIBUTE.md must name the assets of a build: %r" % needle)
rel_doc = read("docs/RELEASING.md")
need("vars.MCAP_APP_NAME" in rel_doc and "vars.MCAP_APP_SHORT_NAME" in rel_doc and "the repository variable `MCAP_BUNDLE_ID`" in rel_doc, "docs/RELEASING.md must name the repository variables MCAP_BUNDLE_ID, vars.MCAP_APP_NAME and vars.MCAP_APP_SHORT_NAME")
need("CATE-<version>.dmg" in dist.split("### Publishing a release on GitHub", 1)[1].split("## 7.", 1)[0], "docs/DISTRIBUTE.md: 'Publishing a release on GitHub' must use CATE-<version>.dmg")
unreleased = read("CHANGELOG.md").split("## [Unreleased]", 1)[1].split("\n## [", 1)[0]
changed = unreleased.split("### Changed", 1)[1].split("\n### ", 1)[0]
for needle, why in (("Catch Everything", "the product name"), ("CATE", "the short name"), ("MCAP_APP_NAME", "the human name input"), ("MCAP_APP_SHORT_NAME", "the short name input"),
                    ("CATE.app", "the app file"), ("CATE-<version>.dmg", "the disk image"), ("volume", "the disk image volume"), ("did not change", "the internal names that did not change"),
                    ("keep its names", "how an existing build keeps its names"), ("install guard", "the refusal of an older app file with the same id"), ("Not verified", "what was not verified"),
                    ("self-signed and not notarized", "the honest signing status"), ("only Zoom calls have been verified", "the honest platform status")):
    need(needle in changed, "CHANGELOG [Unreleased] / Changed must mention %s (%r)" % (why, needle))

# 3. prose that still carries the old product name: only internal names (the data, log and cache folders, the Keychain services, the signing certificate, the ids and labels),
#    the copyright line (the same words as NOTICE, Info.plist.template and the About panel), the spoken test sentence of the device test and a few exact sentences
GLOBAL_OK = [
    r"(?:Application Support|Application\\ Support|Logs|Caches)/MeetingCapture(?:-asr)?",
    r"MeetingCapture (?:Anthropic API key|ASR|Local Signing|Google Calendar token)",
    r"MeetingCapture-Local-Signing",
    r"org\.meetingcapture\.\w+",
    r"Copyright 2026 Meeting Capture contributors",
    r"Meeting Capture Audio Test",
]
FILE_OK = {      # the sentences that name the internal name on purpose, exactly
    "README.md": [r"keep the internal name MeetingCapture"],
    "README.ko.md": [r"내부 이름 MeetingCapture"],
    "docs/BRANDING.md": [r"stay `MeetingCapture`"],
    "docs/DISTRIBUTE.md": [r"keep the internal name `MeetingCapture`"],
    "docs/INSTALL.md": [r"keeps its internal name `MeetingCapture`", r"have the app file `MeetingCapture\.app`"],
    "docs/USER_GUIDE.md": [r"The folder is called MeetingCapture, not Catch Everything"],
    "docs/USER_GUIDE.ko.md": [r"Catch Everything이 아니라 MeetingCapture"],
}
prose = []
for pattern in ("README*.md", "CONTRIBUTING.md", "SECURITY.md", "SPEC.md", "CHANGELOG.md", "CODE_OF_CONDUCT.md", "THIRD_PARTY_NOTICES.md", "NOTICE", "docs/*.md", "docs/research/*.md",
                "config/*.md", "scripts/bench_kit/README.md", "dmg/README-install.txt", ".github/*.md", ".github/ISSUE_TEMPLATE/*.yml"):
    prose += [os.path.relpath(f, root) for f in sorted(glob.glob(os.path.join(root, pattern)))]
need(len(prose) >= 40, "the prose file list is too short (%d files): the glob patterns no longer match" % len(prose))
for rel in ("README.md", "README.ko.md", "docs/INSTALL.md", "docs/CONFIGURATION.md", "docs/DISTRIBUTE.md", "docs/USER_GUIDE.md", "docs/USER_GUIDE.ko.md", "docs/DEPLOY.md", "docs/POLICY.md", "docs/OPS_RUNBOOK.md",
            "docs/ASR_PROTOCOL.md", "docs/RELEASING.md", "docs/BRANDING.md", "docs/SETTINGS.md", "docs/MIGRATION.md", "docs/DETECTION.md", "docs/LIVE_TEST.md", "docs/LIVE_TEST.en.md", "CONTRIBUTING.md",
            "SECURITY.md", "SPEC.md", "CHANGELOG.md", "NOTICE", "THIRD_PARTY_NOTICES.md"):
    need(rel in prose, "%s is not among the prose files that are checked for the old product name" % rel)
for rel in prose:
    allowed = [re.compile(x) for x in GLOBAL_OK + FILE_OK.get(rel, [])]
    for no, line in enumerate(read(rel).splitlines(), 1):
        rest = line
        for rx in allowed:
            rest = rx.sub("", rest)
        m = re.search(r"meeting ?capture", rest, re.I)
        if m:
            problems.append("%s:%d still uses the old product name: ...%s..." % (rel, no, rest[max(0, m.start() - 40):m.end() + 40].strip()))
for rel, sentences in FILE_OK.items():
    for sentence in sentences:
        need(re.search(sentence, read(rel)) is not None, "%s: the allowed sentence %r is gone from the file: remove it from FILE_OK" % (rel, sentence))

# 4. no particular build is written into the repository: every literal value given to one of the three build inputs in prose, the Makefile, the plist template, the workflows and the scripts
#    is a default, an example value or a placeholder (<...>, $... or @...@). A particular owner's id or names go into the private denylist of scripts/release.sh (docs/RELEASING.md), never in here.
#    Examples: com.example.mcap-test, "Example Recorder", ExampleRecorder.
SHARED_OK = {
    "MCAP_BUNDLE_ID": re.compile(r"org\.meetingcapture\.app|com\.example\.[A-Za-z0-9.-]+"),
    "MCAP_APP_NAME": re.compile(r"Catch Everything|Example Recorder"),
    "MCAP_APP_SHORT_NAME": re.compile(r"CATE|ExampleRecorder"),
}
assignment = re.compile(r"\b(MCAP_BUNDLE_ID|MCAP_APP_NAME|MCAP_APP_SHORT_NAME)=(\"[^\"]*\"|'[^']*'|[^\s\"'`)]*)")
for rel in prose + ["Makefile", "app/Info.plist.template", ".github/workflows/release.yml", ".github/workflows/ci.yml"] + sorted(os.path.relpath(f, root) for f in glob.glob(os.path.join(root, "scripts/*.sh")) if not f.endswith("test_scripts.sh")):
    for variable, value in assignment.findall(read(rel)):
        value = value.strip("\"'")
        if value == "" or value[0] in "<$@" or SHARED_OK[variable].fullmatch(value):
            continue
        problems.append("%s names a particular build: %s=%s (use a default, an example value or a placeholder)" % (rel, variable, value))

# 5. no personal data in any prose file (the check of the app installer files keeps its own list above; this one covers every document)
for rel in prose + ["scripts/bundle_id.sh", "app/Info.plist.template"]:
    text = read(rel).replace("wg-quick@wg0.service", "").replace("alice@", "")      # a systemd unit instance and the placeholder user of the bench kit page
    need(not re.search(r"/Users/(?!someone|pat|alice)[A-Za-z0-9._-]+", text), "%s contains a home folder path of a real person" % rel)
    need(not re.search(r"[A-Za-z0-9._%+-]+@(?!example\.(com|org|invalid))[A-Za-z0-9.-]+\.[a-z]{2,}", text), "%s contains an e-mail address that is not an example address" % rel)
print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
"$PYTHON_FOR_TESTS" "$WORK/doc_names.py" "$ROOT" > "$WORK/doc_names.out" 2>&1; check $? "the documents name the product Catch Everything (CATE), document the three build inputs and the assets, keep the old name only as an internal name (allow-list), name no owner, and hold no personal data"
[ -z "$(cat "$WORK/doc_names.out")" ] || sed 's/^/        > /' "$WORK/doc_names.out"

# ---------------------------------------------------------------------------------------------------------------
echo
echo "================================================================"
echo "script tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed checks:$FAILED_NAMES"
    exit 1
fi
exit 0
