#!/bin/bash
# Tests of scripts/asr_server/install_server.sh and its files (the plist template, the example config).   Run: scripts/asr_server/test_install_server.sh
#
# HERMETIC (same rules as scripts/test_scripts.sh). The installer runs with HOME and TMPDIR inside one temp directory and with stub
# programs first on PATH, so it can never touch the real system:
#   launchctl, dscl, chown, sudo, security, open   stubs that only log (dscl keeps a tiny fake directory of users, security and sudo are
#                                                  logged as FORBIDDEN: the installer must never call them)
#   id, stat                                       stubs in the apply tests only: `id -u` says 0 and `stat -f %u` says 0, so the
#                                                  root checks of --apply can be walked through as an ordinary user, with every path
#                                                  pointed into the temp directory (--support-dir, --log-dir, --plist-path)
# No daemon is loaded, no user is created, no Keychain is read, nothing is downloaded. scripts/test_scripts.sh runs this file (wired in W8b).
#
# Needs: macOS /bin/bash 3.2 (the script is run with it on purpose), plutil, python3. The config check needs the production venv python
# (numpy) and is skipped with a note when it is missing. Exit code 0 only if every check passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT/scripts/asr_server/install_server.sh"
TEMPLATE="$ROOT/scripts/asr_server/org.meetingcapture.asr.plist.template"
EXAMPLE="$ROOT/scripts/asr_server/asr-server.example.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-install-server-tests.XXXXXX")"
trap 'rm -rf "${WORK:?}"' EXIT
PASS=0
FAIL=0
FAILED_NAMES=""
OUT="$WORK/out.txt"
RC=0

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    - $1"; echo "  FAIL $1"; }
check()   { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }          # check <status> <name>
section() { echo; echo "== $*"; }
show_tail() { tail -n 8 "$OUT" 2>/dev/null | cut -c1-200 | sed 's/^/        | /'; }
out_has()   { if grep -Eq -- "$1" "$OUT"; then ok "$2"; else bad "$2   (expected /$1/)"; show_tail; fi; }
rc_is()     { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2   (exit code $RC, expected $1)"; show_tail; fi; }
mode_of()   { stat -f %Lp "$1" 2>/dev/null; }
mode_is()   { if [ "$(mode_of "$1")" = "$2" ]; then ok "$3"; else bad "$3   (mode $(mode_of "$1"), expected $2)"; fi; }
plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }          # plist_get <plist> <key path>

unset MCAP_PYTHON3 MCAP_CONFIG MCAP_LOG_DIR MCAP_SUPPORT_DIR HF_HUB_OFFLINE

# ---- stubs -----------------------------------------------------------------------------------------------------------
STUBS="$WORK/stubs"; STUBS_ROOT="$WORK/stubs-root"; STUB_LOG="$WORK/stub-log"; STUB_STATE="$WORK/stub-state"
mkdir -p "$STUBS" "$STUBS_ROOT" "$STUB_LOG" "$STUB_STATE"
for name in launchctl chown open; do
    cat > "$STUBS/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "\${STUB_LOG:?}/$name.log"
exit 0
EOF
done
for name in sudo security; do
    cat > "$STUBS/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "\${STUB_LOG:?}/FORBIDDEN.log"
exit 99
EOF
done
cat > "$STUBS/dscl" <<'EOF'
#!/bin/sh
# Fake directory service: users created with -create live as marker files in $STUB_STATE.
echo "dscl $*" >> "${STUB_LOG:?}/dscl.log"
S="${STUB_STATE:?}"
case "$2" in
  -read) [ -e "$S/user.$(basename "$3")" ] && exit 0; exit 56 ;;
  -list) case "$3" in
           /Users) echo "root 0"; echo "_www 70"; echo "nobody -2" ;;
           /Groups) echo "wheel 0"; echo "staff 20" ;;
         esac; exit 0 ;;
  -create) case "$3" in /Users/*) : > "$S/user.$(basename "$3")" ;; esac; exit 0 ;;
esac
exit 0
EOF
cat > "$STUBS_ROOT/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
cat > "$STUBS_ROOT/stat" <<'EOF'
#!/bin/sh
if [ "$1" = "-f" ] && [ "$2" = "%u" ]; then echo 0; exit 0; fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$STUBS"/* "$STUBS_ROOT"/*

reset_stub_logs() { rm -f "${STUB_LOG:?}"/*.log; }
# run_script <label> <path-prefix> <script args...>: HOME/TMPDIR inside WORK, stubs first on PATH; the output goes to $OUT, the code to $RC
run_script() {
    local tmp="$WORK/tmp-$1"
    shift
    local prefix="$1"
    shift
    mkdir -p "$tmp"
    env -i HOME="$WORK/home" TMPDIR="$tmp" PATH="$prefix:/usr/bin:/bin:/usr/sbin:/sbin" STUB_LOG="$STUB_LOG" STUB_STATE="$STUB_STATE" \
        /bin/bash "$SCRIPT" "$@" > "$OUT" 2>&1
    RC=$?
    LEFTOVER="$(ls -A "$tmp" 2>/dev/null)"
}
stub_calls() { if [ -f "$STUB_LOG/$1.log" ]; then wc -l < "$STUB_LOG/$1.log" | tr -d ' '; else echo 0; fi; }
mkdir -p "$WORK/home"
PY3="$(command -v python3 || echo /usr/bin/python3)"
VENV_PY="$HOME/Library/Application Support/MeetingCapture/venv/bin/python"

# ---------------------------------------------------------------------------------------------------------------
section "the files themselves"
/bin/bash -n "$SCRIPT"; check $? "install_server.sh is valid bash 3.2 syntax"
[ -x "$SCRIPT" ]; check $? "install_server.sh is executable"
[ "$(grep -Eo '@[A-Z_]+@' "$TEMPLATE" | sort -u | tr '\n' ' ')" = "@CONFIG@ @HOME_DIR@ @LOG_DIR@ @PROJECT_DIR@ @PYTHON@ @SERVICE_GROUP@ @SERVICE_USER@ " ]
check $? "the template has exactly the placeholders the script replaces"
"$PY3" -c "import json,sys; json.load(open(sys.argv[1]))" "$EXAMPLE"; check $? "asr-server.example.json is valid JSON"
if [ -x "$VENV_PY" ]; then
    PYTHONPATH="$ROOT/pipeline" "$VENV_PY" -c "
import sys
from mcap import asr_server as S
cfg = S.load_server_config(sys.argv[1])
assert cfg.listen.startswith('127.0.0.1:') and cfg.backend == 'whisper' and not cfg.tls
" "$EXAMPLE"; check $? "asr-server.example.json is accepted by asr_server.load_server_config (strict loader, loopback, whisper)"
else
    echo "  skip the strict loader check (no production venv at $VENV_PY)"
fi

# ---------------------------------------------------------------------------------------------------------------
section "usage and refusals"
run_script help "$STUBS" --help; rc_is 0 "--help exits 0"; out_has "DRY RUN" "--help documents the dry run"
run_script bad1 "$STUBS" --nope; rc_is 2 "an unknown option exits 2"
run_script bad2 "$STUBS" --load; rc_is 2 "--load without --apply exits 2"; out_has "needs --apply" "...and says why"
run_script bad3 "$STUBS" --apply --stage-dir "$WORK/x" --python /usr/bin/python3; rc_is 2 "--apply with --stage-dir exits 2"
run_script bad4 "$STUBS" --stage-dir "$WORK/x"; rc_is 2 "--stage-dir without --python exits 2"
run_script bad5 "$STUBS" --stage-dir relative/dir --python /usr/bin/python3; rc_is 2 "a relative --stage-dir exits 2"
run_script bad6 "$STUBS" --support-dir relative; rc_is 2 "a relative --support-dir exits 2"
run_script bad7 "$STUBS" --service-user "Bad User"; rc_is 2 "a bad --service-user exits 2"
run_script bad8 "$STUBS" --python "$WORK/no-such-python"; rc_is 1 "a missing python exits 1"
run_script bad9 "$STUBS" --apply --python /usr/bin/python3
if [ "$(id -u)" = 0 ]; then echo "  skip --apply as an ordinary user (these tests run as root)"; else
    rc_is 1 "--apply as an ordinary user is refused"; out_has "needs root" "...with a message that says so"
fi
[ "$(stub_calls dscl)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ "$(stub_calls launchctl)" = 0 ]; check $? "none of the refusals reached dscl, chown or launchctl"

# ---------------------------------------------------------------------------------------------------------------
section "dry run (the default)"
run_script dry "$STUBS" --python /usr/bin/python3 --support-dir "$WORK/dry-support" --log-dir "$WORK/dry-log" --plist-path "$WORK/dry.plist"
rc_is 0 "a dry run exits 0"
out_has "DRY RUN: nothing is changed" "it says it is a dry run"
out_has "dscl \. -create /Users/mcap-asr UserShell /usr/bin/false" "the plan shows how the service user is made (no login shell)"
out_has "mkdir -p .*dry-support" "the plan lists the directories"
out_has "the rendered plist is valid" "the plist is rendered and linted even in a dry run"
out_has "<string>/usr/bin/python3</string>" "the plan prints the plist with the python"
out_has "<key>HF_HUB_OFFLINE</key>" "the plist keeps the server offline"
out_has "launchctl bootstrap system" "the plan tells how to load it"
out_has "fdesetup authrestart" "the plan mentions the FileVault restart procedure"
[ ! -e "$WORK/dry-support" ] && [ ! -e "$WORK/dry-log" ] && [ ! -e "$WORK/dry.plist" ]; check $? "a dry run created no directory and no plist"
[ -z "$LEFTOVER" ]; check $? "a dry run left nothing in TMPDIR"
[ "$(stub_calls dscl)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ "$(stub_calls launchctl)" = 0 ] && [ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "a dry run called no dscl, chown, launchctl, sudo or security"

# ---------------------------------------------------------------------------------------------------------------
section "stage tree (--stage-dir): the files --apply would create, without root"
STAGE="$WORK/stage"
run_script stage "$STUBS" --stage-dir "$STAGE" --python /usr/bin/python3 --support-dir "/srv/asr support" --log-dir /srv/asr-log --plist-path /srv/LaunchDaemons/x.plist
rc_is 0 "staging exits 0"
SS="$STAGE/srv/asr support"; SL="$STAGE/srv/asr-log"; SP="$STAGE/srv/LaunchDaemons/x.plist"
[ -d "$SS" ] && [ -d "$SS/home" ] && [ -d "$SL" ] && [ -f "$SP" ] && [ -f "$SS/asr-server.json" ] && [ -f "$SL/server.log" ]; check $? "the tree has the support, home and log directories, the config, the plist and the log file"
mode_is "$SS" 700 "the support directory is 0700"
mode_is "$SS/home" 700 "the service home is 0700"
mode_is "$SL" 700 "the log directory is 0700"
mode_is "$SL/server.log" 600 "server.log is 0600"
mode_is "$SS/asr-server.json" 644 "the config is 0644 (root-owned in the real install: the service cannot change it)"
mode_is "$SP" 644 "the plist is 0644"
plutil -lint "$SP" >/dev/null 2>&1; check $? "the staged plist passes plutil -lint"
if grep -Eq '@[A-Z_]+@' "$SP"; then bad "a placeholder is left in the plist"; else ok "no placeholder is left in the plist"; fi
[ "$(plist_get "$SP" Label)" = "org.meetingcapture.asr" ]; check $? "plist Label is org.meetingcapture.asr"
[ "$(plist_get "$SP" UserName)" = "mcap-asr" ]; check $? "plist runs as the service user"
[ "$(plist_get "$SP" ProgramArguments.0)" = "/usr/bin/python3" ] && [ "$(plist_get "$SP" ProgramArguments.2)" = "mcap.asr_server" ]; check $? "plist runs python -m mcap.asr_server"
[ "$(plist_get "$SP" ProgramArguments.4)" = "/srv/asr support/asr-server.json" ]; check $? "plist names the REAL config path, even for a staged tree (and survives a space)"
[ "$(plist_get "$SP" SoftResourceLimits.Core)" = "0" ] && [ "$(plist_get "$SP" HardResourceLimits.Core)" = "0" ]; check $? "plist switches core dumps off"
[ "$(plist_get "$SP" Umask)" = "63" ]; check $? "plist umask is 077"
[ "$(plist_get "$SP" EnvironmentVariables.HF_HUB_OFFLINE)" = "1" ] && [ "$(plist_get "$SP" EnvironmentVariables.PYTHONPATH)" = "$ROOT/pipeline" ]; check $? "plist: offline models and PYTHONPATH of the project"
[ "$(plist_get "$SP" StandardOutPath)" = "/srv/asr-log/server.log" ]; check $? "plist logs to server.log in the log directory"
[ "$(plist_get "$SP" KeepAlive.SuccessfulExit)" = "false" ]; check $? "plist restarts a crash but not a clean exit"
[ "$(plist_get "$SP" WorkingDirectory)" = "/" ]; check $? "plist working directory is / (only root writes there): never the service user's own home, which 'python -m' would put first on sys.path"
[ "$(plist_get "$SP" EnvironmentVariables.PYTHONSAFEPATH)" = "1" ]; check $? "plist: PYTHONSAFEPATH=1 keeps the working directory off sys.path"
[ "$(plist_get "$SP" EnvironmentVariables.PYTHONNOUSERSITE)" = "1" ]; check $? "plist: PYTHONNOUSERSITE=1 keeps the user's site-packages and its .pth files out"
[ "$(plist_get "$SP" EnvironmentVariables.HOME)" = "/srv/asr support/home" ]; check $? "plist: HOME is still the service home (data only: the model cache)"
[ -f "$SS/.mcap-asr-install" ] && [ -f "$SL/.mcap-asr-install" ]; check $? "the staged directories carry the installer's marker"
"$PY3" - "$SS/asr-server.json" <<'PYEOF'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["secrets_dir"] == "/srv/asr support" and obj["log_dir"] == "/srv/asr-log", obj
assert obj["listen"].startswith("127.0.0.1:") and obj["backend"] == "whisper"
PYEOF
check $? "the staged config carries the chosen directories and stays loopback with the whisper backend"
if [ -x "$VENV_PY" ]; then
    PYTHONPATH="$ROOT/pipeline" "$VENV_PY" -c "import sys; from mcap import asr_server as S; S.load_server_config(sys.argv[1])" "$SS/asr-server.json"
    check $? "the staged config is accepted by the strict loader"
fi
if grep -rqE 'mcap1_[0-9a-f]{8}_' "$STAGE"; then bad "a token is in a staged file"; else ok "no token is in any staged file"; fi
[ "$(stub_calls dscl)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ "$(stub_calls launchctl)" = 0 ]; check $? "staging called no dscl, chown or launchctl"
out_has "skipped in --stage-dir mode" "the output says what staging leaves out"

echo "# kept" >> "$SS/asr-server.json"
run_script stage2 "$STUBS" --stage-dir "$STAGE" --python /usr/bin/python3 --support-dir "/srv/asr support" --log-dir /srv/asr-log --plist-path /srv/LaunchDaemons/x.plist
rc_is 0 "staging twice exits 0"
tail -n 1 "$SS/asr-server.json" | grep -q '^# kept$'; check $? "an existing config is never overwritten"

# ---------------------------------------------------------------------------------------------------------------
section "--apply --load through stubs (an ordinary user pretends to be root; every path is inside the temp directory)"
AS="$WORK/apply-support"; AL="$WORK/apply-log"; AP="$WORK/apply-LaunchDaemons/org.meetingcapture.asr.plist"
reset_stub_logs
rm -f "${STUB_STATE:?}"/user.*
run_script apply "$STUBS_ROOT:$STUBS" --apply --load --python /usr/bin/python3 --service-user mcap-test --support-dir "$AS" --log-dir "$AL" --plist-path "$AP"
rc_is 0 "apply exits 0"
grep -q "dscl . -create /Users/mcap-test UniqueID 250" "$STUB_LOG/dscl.log"; check $? "the service user gets the first free id from 250 (ids in use are skipped)"
grep -q "dscl . -create /Users/mcap-test UserShell /usr/bin/false" "$STUB_LOG/dscl.log" && grep -q 'dscl . -create /Users/mcap-test Password \*' "$STUB_LOG/dscl.log"; check $? "the service user has no login shell and no password"
grep -q "chown -h mcap-test:mcap-test $AS" "$STUB_LOG/chown.log" && grep -q "chown -h mcap-test:mcap-test $AL" "$STUB_LOG/chown.log" && grep -q "chown -h mcap-test:mcap-test $AL/server.log" "$STUB_LOG/chown.log"; check $? "the directories and server.log are chowned to the service user (chown -h: never through a link)"
grep -q "chown -h root:wheel $AS/asr-server.json" "$STUB_LOG/chown.log" && grep -q "chown -h root:wheel $AP" "$STUB_LOG/chown.log"; check $? "the config and the plist are chowned to root:wheel (chown -h)"
if grep -E '^chown ' "$STUB_LOG/chown.log" | grep -vq '^chown -h '; then bad "a chown ran without -h"; else ok "every chown ran with -h"; fi
[ "$(grep -n "chown -h mcap-test:mcap-test $AS\$" "$STUB_LOG/chown.log" | cut -d: -f1)" -gt "$(grep -n "chown -h mcap-test:mcap-test $AS/home\$" "$STUB_LOG/chown.log" | cut -d: -f1)" ]
check $? "the support directory is handed to the service user AFTER the home directory inside it (it could swap what is inside for a link once it owns it)"
[ -f "$AS/.mcap-asr-install" ] && [ -f "$AL/.mcap-asr-install" ]; check $? "both directories carry the marker 'made by install_server.sh'"
mode_is "$AS" 700 "the support directory is 0700"
mode_is "$AL" 700 "the log directory is 0700"
mode_is "$AP" 644 "the plist is 0644"
plutil -lint "$AP" >/dev/null 2>&1 && [ "$(plist_get "$AP" UserName)" = "mcap-test" ]; check $? "the installed plist is valid and names the chosen user"
grep -q "launchctl bootstrap system $AP" "$STUB_LOG/launchctl.log" && grep -q "launchctl kickstart -k system/org.meetingcapture.asr" "$STUB_LOG/launchctl.log"; check $? "--load bootstraps the plist and starts the daemon"
grep -q "launchctl bootout system/org.meetingcapture.asr" "$STUB_LOG/launchctl.log"; check $? "--load boots out an already loaded copy first"
[ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "no sudo and no security call"
: > "$STUB_LOG/dscl.log"
run_script apply2 "$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$AS" --log-dir "$AL" --plist-path "$AP"
rc_is 0 "a second apply exits 0"
if grep -q -- "-create" "$STUB_LOG/dscl.log"; then bad "an existing service user was created again"; else ok "an existing service user is left alone"; fi
out_has "not loaded" "without --load nothing is loaded and the command is printed instead"

section "a daemon installed under another label is named, never touched"
OD="$WORK/old-LaunchDaemons"; mkdir -p "$OD"; : > "$OD/old.example.mcap-asr.plist"
reset_stub_logs
run_script oldd "$STUBS" --python /usr/bin/python3 --support-dir "$WORK/old-support" --log-dir "$WORK/old-log" --plist-path "$OD/org.meetingcapture.asr.plist"
rc_is 0 "a dry run beside an old-label plist exits 0"
out_has "WARNING: .*old.example.mcap-asr.plist is another speech-server LaunchDaemon.*bootout system/old.example.mcap-asr" "...and names the other daemon with the command that stops it"
[ -e "$OD/old.example.mcap-asr.plist" ] && [ "$(stub_calls launchctl)" = 0 ]; check $? "...it removed nothing and called no launchctl"
run_script oldn "$STUBS" --python /usr/bin/python3 --support-dir "$WORK/old-support" --log-dir "$WORK/old-log" --plist-path "$WORK/dry.plist"
if grep -q "another speech-server LaunchDaemon" "$OUT"; then bad "a folder without another plist was warned about"; else ok "...and a folder without one gets no warning"; fi

section "--apply refuses code the service user could change"
reset_stub_logs
mkdir -p "$WORK/stubs-id"
cp "$STUBS_ROOT/id" "$WORK/stubs-id/id"
run_script owner "$WORK/stubs-id:$STUBS" --apply --python /usr/bin/python3 --support-dir "$WORK/o-support" --log-dir "$WORK/o-log" --plist-path "$WORK/o.plist"
if [ "$(stat -f %u "$ROOT/pipeline")" = 0 ]; then echo "  skip (this checkout is owned by root)"; else
    rc_is 1 "a project that is not owned by root is refused"; out_has "must be owned by root" "...with the reason"
    [ "$(stub_calls dscl)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ ! -e "$WORK/o-support" ]; check $? "...before any user, directory or file was made"
fi

# ---------------------------------------------------------------------------------------------------------------
section "--apply again: what the service user could have turned into a link, and paths that are not ours, are refused"
# The support, home and log directories and what is in them belong to the service user. Re-running the installer as root must never
# chmod, chown or create a file through something that user put there, and must not take over a directory that is not ours.
SS2="$WORK/sym-support"; SL2="$WORK/sym-log"; SP2="$WORK/sym-LaunchDaemons/x.plist"; OUTSIDE="$WORK/outside"
mkdir -p "$OUTSIDE/victim-home" "$OUTSIDE/victim-log"; chmod 755 "$OUTSIDE/victim-home" "$OUTSIDE/victim-log"
apply_again() { run_script "$1" "$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$SS2" --log-dir "$SL2" --plist-path "$SP2"; }
reset_stub_logs
apply_again s1; rc_is 0 "a first apply for these cases exits 0"
apply_again s1b; rc_is 0 "and so does the second one (an upgrade of an installation made by this script)"

reset_stub_logs
rm -rf "$SS2/home"; ln -s "$OUTSIDE/victim-home" "$SS2/home"
apply_again s2; rc_is 1 "a service home that became a link to another directory is refused"
out_has "symbolic link" "...and the message names the link"
mode_is "$OUTSIDE/victim-home" 755 "the directory the link points to was not chmodded"
[ "$(stub_calls chown)" = 0 ]; check $? "...and nothing was chowned"
rm -f "$SS2/home"; mkdir "$SS2/home"

reset_stub_logs
rm -f "$SL2/server.log"; ln -s "$OUTSIDE/created-by-root.txt" "$SL2/server.log"
apply_again s3; rc_is 1 "a server.log that became a dangling link is refused"
[ ! -e "$OUTSIDE/created-by-root.txt" ]; check $? "...and no file was created at the other end of the link"
[ "$(stub_calls chown)" = 0 ]; check $? "...and nothing was chowned"
rm -f "$SL2/server.log"; : > "$SL2/server.log"

reset_stub_logs
rm -f "$SS2/asr-server.json"; ln -s "$OUTSIDE/config-by-root.json" "$SS2/asr-server.json"
apply_again s4; rc_is 1 "an asr-server.json that became a dangling link is refused"
[ ! -e "$OUTSIDE/config-by-root.json" ]; check $? "...and no config was written through it"
rm -f "$SS2/asr-server.json"
apply_again s4b; rc_is 0 "with the link gone the next apply makes the config again"
[ -f "$SS2/asr-server.json" ] && [ ! -L "$SS2/asr-server.json" ]; check $? "...as a plain file"

LINK_LOG="$WORK/link-log"; ln -s "$OUTSIDE/victim-log" "$LINK_LOG"
reset_stub_logs
run_script s5 "$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$WORK/s5-support" --log-dir "$LINK_LOG" --plist-path "$WORK/s5.plist"
rc_is 1 "a --log-dir that is a link is refused"
mode_is "$OUTSIDE/victim-log" 755 "the directory behind it was not chmodded"
[ ! -e "$WORK/s5-support" ] && [ "$(stub_calls chown)" = 0 ]; check $? "...and nothing else was made before the refusal"
run_script s5d "$STUBS" --python /usr/bin/python3 --support-dir "$WORK/s5d-support" --log-dir "$LINK_LOG" --plist-path "$WORK/s5d.plist"
rc_is 1 "a dry run refuses it too (it reports what --apply would refuse)"

mkdir -p "$WORK/stranger"; echo data > "$WORK/stranger/important"; chmod 755 "$WORK/stranger"
reset_stub_logs
run_script s6 "$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$WORK/stranger" --log-dir "$WORK/s6-log" --plist-path "$WORK/s6.plist"
rc_is 1 "a --support-dir that is not empty and was not made by this script is refused"
out_has "not empty and was not made by this script" "...with the reason"
mode_is "$WORK/stranger" 755 "...and it was not chmodded"
[ "$(stub_calls chown)" = 0 ] && [ ! -e "$WORK/s6-log" ]; check $? "...nor chowned, and the log directory was not made"

mkdir -p "$WORK/empty-support"
reset_stub_logs
run_script s7 "$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$WORK/empty-support" --log-dir "$WORK/s7-log" --plist-path "$WORK/s7.plist"
rc_is 0 "an existing EMPTY support directory is accepted"

rm -f "$SS2/.mcap-asr-install" "$SL2/.mcap-asr-install"
reset_stub_logs
apply_again s8; rc_is 0 "an installation from before the marker existed (it has asr-server.json and server.log) is accepted"
[ -f "$SS2/.mcap-asr-install" ] && [ -f "$SL2/.mcap-asr-install" ]; check $? "...and gets the marker"

mkdir -p "$STUBS_ROOT/other"
cat > "$STUBS_ROOT/other/stat" <<'EOF'
#!/bin/sh
# Like the root stub, except that anything with 'other-owner' in its path belongs to uid 501.
if [ "$1" = "-f" ] && [ "$2" = "%u" ]; then case "$3" in *other-owner*) echo 501 ;; *) echo 0 ;; esac; exit 0; fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$STUBS_ROOT/other/stat"
mkdir -p "$WORK/other-owner-support"
reset_stub_logs
run_script s9 "$STUBS_ROOT/other:$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$WORK/other-owner-support" --log-dir "$WORK/s9-log" --plist-path "$WORK/s9.plist"
rc_is 1 "an existing support directory owned by somebody else is refused"
out_has "owned by uid 501" "...with the owner named"
[ "$(stub_calls chown)" = 0 ]; check $? "...and nothing was chowned"
[ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "no sudo and no security call in any of these cases"

# A link that appears AFTER the checks (the service user wins a race between the check and the write) must not be written through either:
# the files are created exclusively. The chown stub plays the service user: when the support directory has been handed over (the last
# chown of step 3) it plants dangling links where the config and server.log are about to be created.
RS="$WORK/race-support"; RL="$WORK/race-log"
mkdir -p "$STUBS_ROOT/race"
cat > "$STUBS_ROOT/race/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "\${STUB_LOG:?}/chown.log"
if [ "\$3" = "$RS" ]; then
    ln -s "$OUTSIDE/raced-config.json" "$RS/asr-server.json"
    ln -s "$OUTSIDE/raced-log.txt" "$RL/server.log"
fi
exit 0
EOF
chmod +x "$STUBS_ROOT/race/chown"
reset_stub_logs
run_script race "$STUBS_ROOT/race:$STUBS_ROOT:$STUBS" --apply --python /usr/bin/python3 --service-user mcap-test --support-dir "$RS" --log-dir "$RL" --plist-path "$WORK/race.plist"
rc_is 1 "a link planted after the checks makes the installer stop"
out_has "something is there already" "...saying why"
[ ! -e "$OUTSIDE/raced-config.json" ] && [ ! -e "$OUTSIDE/raced-log.txt" ]; check $? "...and nothing was created through the planted links"

# ---------------------------------------------------------------------------------------------------------------
section "the plist's Python environment ignores a planted module (the reviewer's ssl.py in the working directory)"
if [ -x "$VENV_PY" ]; then
    PLANT="$WORK/plant"; mkdir -p "$PLANT"; printf 'print("PLANTED-MODULE-RAN")\n' > "$PLANT/ssl.py"
    SAFE="$(plist_get "$SP" EnvironmentVariables.PYTHONSAFEPATH)"; NOUSER="$(plist_get "$SP" EnvironmentVariables.PYTHONNOUSERSITE)"
    (cd "$PLANT" && env -i PATH=/usr/bin:/bin PYTHONPATH="$ROOT/pipeline" "$VENV_PY" -m mcap.asr_server --help > "$OUT" 2>&1)
    grep -q PLANTED-MODULE-RAN "$OUT"; check $? "(control) without the plist's variables a planted ssl.py in the working directory is imported first"
    (cd "$PLANT" && env -i PATH=/usr/bin:/bin PYTHONPATH="$ROOT/pipeline" PYTHONSAFEPATH="$SAFE" PYTHONNOUSERSITE="$NOUSER" \
        "$VENV_PY" -m mcap.asr_server --help > "$OUT" 2>&1)
    if grep -q PLANTED-MODULE-RAN "$OUT"; then bad "with the plist's variables the planted ssl.py still ran"; else ok "with the plist's variables the planted ssl.py is not imported"; fi
    out_has "usage: " "...and the real server code ran (--help)"
else
    echo "  skip the planted-module check (no production venv at $VENV_PY)"
fi

echo
echo "install_server tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo "failed:$FAILED_NAMES"; exit 1; fi
exit 0
