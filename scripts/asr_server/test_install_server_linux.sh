#!/bin/bash
# Tests of scripts/asr_server/install_server_linux.sh and its files (the systemd unit template, requirements-server.txt, the example
# config).   Run: scripts/asr_server/test_install_server_linux.sh
#
# HERMETIC (same rules as scripts/test_scripts.sh). The installer runs with HOME and TMPDIR inside one temp directory and with stub
# programs first on PATH, so it can never touch the real system, whatever machine this runs on:
#   systemctl, systemd-analyze, useradd, groupadd, chown   stubs that only log (useradd and groupadd keep a tiny fake directory of users
#                                                          and groups; chown never changes an owner)
#   python (the --python of every run)                     a stub: logs every call, "creates" a venv for `-m venv`, accepts `-m pip`
#                                                          (so no venv is built and NOTHING IS DOWNLOADED), and hands everything else
#                                                          (address checks, the config renderer) to the real python3
#   sudo, security, launchctl, open, curl, wget            FORBIDDEN stubs: the installer must never call them (they log and fail)
#   id, stat, uname, getent                                stubs in the apply tests only: `id -u` says 0, `stat -c %u` and `stat -f %u` say 0,
#                                                          `uname -s` says Linux, so the root and Linux checks of --apply can be walked
#                                                          through as an ordinary user, with every path pointed into the temp directory
# No service is enabled or started, no user is created, no package is installed, no Keychain is read, no model is touched, no network is
# used. scripts/test_scripts.sh runs this file when it is wired in. It never ran on a real Linux host or a real GPU.
#
# Needs: /bin/bash (3.2 on macOS is used on purpose, any bash on Linux), python3, sed, awk, grep. The config checks need the production venv
# python (numpy) and are skipped with a note when it is missing. Exit code 0 only if every check passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT/scripts/asr_server/install_server_linux.sh"
TEMPLATE="$ROOT/scripts/asr_server/mcap-asr.service.template"
EXAMPLE="$ROOT/scripts/asr_server/asr-server.example.json"
REQS="$ROOT/pipeline/requirements-server.txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-install-linux-tests.XXXXXX")"
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
show_tail() { tail -n 8 "$OUT" 2>/dev/null | cut -c1-220 | sed 's/^/        | /'; }
out_has()   { if grep -Eq -- "$1" "$OUT"; then ok "$2"; else bad "$2   (expected /$1/)"; show_tail; fi; }
out_lacks() { if grep -Eq -- "$1" "$OUT"; then bad "$2   (found /$1/)"; else ok "$2"; fi; }
rc_is()     { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2   (exit code $RC, expected $1)"; show_tail; fi; }
mode_of()   { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
mode_is()   { if [ "$(mode_of "$1")" = "$2" ]; then ok "$3"; else bad "$3   (mode $(mode_of "$1"), expected $2)"; fi; }
has_line()  { grep -qxF -- "$1" "$2"; }                                    # has_line <exact line> <file>

unset MCAP_PYTHON3 MCAP_CONFIG MCAP_LOG_DIR MCAP_SUPPORT_DIR HF_HUB_OFFLINE HF_HOME
export PYTHONDONTWRITEBYTECODE=1        # the checks that import mcap must not leave __pycache__ directories in the checkout

# ---- stubs -----------------------------------------------------------------------------------------------------------
STUBS="$WORK/stubs"; STUBS_ROOT="$WORK/stubs-root"; STUBS_PY="$WORK/stubs-py"; STUB_LOG="$WORK/stub-log"; STUB_STATE="$WORK/stub-state"
mkdir -p "$STUBS" "$STUBS_ROOT" "$STUBS_PY" "$STUB_LOG" "$STUB_STATE"
for name in systemctl systemd-analyze chown; do
    cat > "$STUBS/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "\${STUB_LOG:?}/$name.log"
exit 0
EOF
done
for name in sudo security launchctl open curl wget; do
    cat > "$STUBS/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "\${STUB_LOG:?}/FORBIDDEN.log"
exit 99
EOF
done
cat > "$STUBS/useradd" <<'EOF'
#!/bin/sh
# Fake useradd: the last argument is the name; the user lives as a marker file in $STUB_STATE.
echo "useradd $*" >> "${STUB_LOG:?}/useradd.log"
for last; do :; done
: > "${STUB_STATE:?}/user.$last"
exit 0
EOF
cat > "$STUBS/groupadd" <<'EOF'
#!/bin/sh
echo "groupadd $*" >> "${STUB_LOG:?}/groupadd.log"
for last; do :; done
: > "${STUB_STATE:?}/group.$last"
exit 0
EOF
cat > "$STUBS/nvidia-smi.on" <<'EOF'
#!/bin/sh
echo "GPU 0: NVIDIA Stub 16GB (UUID: GPU-stub)"
exit 0
EOF
cat > "$STUBS_PY/python3" <<'EOF'
#!/bin/sh
# Stub interpreter. Logs every call. `-m venv DIR` makes a stub venv (DIR/bin/python is this stub), `-m pip ...` succeeds without doing
# anything, the version probe answers $STUB_PY_VERSION (default 3.12), everything else (`-` with a heredoc: the address checks and the
# config renderer) is the real python3 named by $REAL_PY3.
echo "python $*" >> "${STUB_LOG:?}/python.log"
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
    mkdir -p "$3/bin"
    cp "$0" "$3/bin/python"
    chmod +x "$3/bin/python"
    echo "home = stub" > "$3/pyvenv.cfg"
    exit 0
fi
if [ "$1" = "-m" ] && [ "$2" = "pip" ]; then exit 0; fi
case "$2" in *sys.version_info*) echo "${STUB_PY_VERSION:-3.12}"; exit 0 ;; esac
exec "${REAL_PY3:?}" "$@"
EOF
cat > "$STUBS_ROOT/id" <<'EOF'
#!/bin/sh
# `id -u` is root. Users the fake useradd made exist (their uid is 999, or the content of their marker file).
S="${STUB_STATE:?}"
if [ "$1" = "-u" ] && [ -z "$2" ]; then echo 0; exit 0; fi
if [ "$1" = "-u" ]; then
    [ -e "$S/user.$2" ] || { echo "id: $2: no such user" >&2; exit 1; }
    if [ -s "$S/user.$2" ]; then cat "$S/user.$2"; else echo 999; fi
    exit 0
fi
case "$1" in -*) exec /usr/bin/id "$@" ;; esac
[ -e "$S/user.$1" ] || { echo "id: $1: no such user" >&2; exit 1; }
echo "uid=999($1) gid=999($1) groups=999($1)"
EOF
cat > "$STUBS_ROOT/getent" <<'EOF'
#!/bin/sh
[ "$1" = group ] && [ -e "${STUB_STATE:?}/group.$2" ] && { echo "$2:x:999:"; exit 0; }
exit 2
EOF
cat > "$STUBS_ROOT/stat" <<'EOF'
#!/bin/sh
if { [ "$1" = "-c" ] || [ "$1" = "-f" ]; } && [ "$2" = "%u" ]; then echo 0; exit 0; fi
exec /usr/bin/stat "$@"
EOF
cat > "$STUBS_ROOT/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then echo Linux; exit 0; fi
exec /usr/bin/uname "$@"
EOF
chmod +x "$STUBS"/* "$STUBS_ROOT"/* "$STUBS_PY"/*
mv "$STUBS/nvidia-smi.on" "$WORK/nvidia-smi.on"                    # copied onto the stub path by the one test that wants a GPU

reset_stub_logs() { rm -f "${STUB_LOG:?}"/*.log; }
REAL_PY3="$(command -v python3 || echo /usr/bin/python3)"
STUB_PY="$STUBS_PY/python3"
# run_script <label> <path-prefix> <script args...>: HOME/TMPDIR inside WORK, stubs first on PATH; the output goes to $OUT, the code to $RC
run_script() {
    local tmp="$WORK/tmp-$1"
    shift
    local prefix="$1"
    shift
    mkdir -p "$tmp"
    env -i HOME="$WORK/home" TMPDIR="$tmp" PATH="$prefix:/usr/bin:/bin:/usr/sbin:/sbin" STUB_LOG="$STUB_LOG" STUB_STATE="$STUB_STATE" \
        REAL_PY3="$REAL_PY3" STUB_PY_VERSION="${STUB_PY_VERSION:-3.12}" /bin/bash "$SCRIPT" "$@" > "$OUT" 2>&1
    RC=$?
    LEFTOVER="$(ls -A "$tmp" 2>/dev/null)"
}
stub_calls() { if [ -f "$STUB_LOG/$1.log" ]; then wc -l < "$STUB_LOG/$1.log" | tr -d ' '; else echo 0; fi; }
no_system_calls() { [ "$(stub_calls useradd)" = 0 ] && [ "$(stub_calls groupadd)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ "$(stub_calls systemctl)" = 0 ]; }
mkdir -p "$WORK/home"
VENV_PY="$HOME/Library/Application Support/MeetingCapture/venv/bin/python"
[ -x "$VENV_PY" ] || VENV_PY=""

# ---------------------------------------------------------------------------------------------------------------
section "the files themselves"
/bin/bash -n "$SCRIPT"; check $? "install_server_linux.sh is valid bash syntax"
[ -x "$SCRIPT" ]; check $? "install_server_linux.sh is executable"
[ "$(grep -Eo '@[A-Z_]+@' "$TEMPLATE" | sort -u | tr '\n' ' ')" = "@CONFIG@ @HOME_DIR@ @IP_ALLOW_LINES@ @LOG_DIR@ @PROJECT_DIR@ @PYTHON@ @SERVICE_GROUP@ @SERVICE_USER@ @SUPPORT_DIR@ " ]
check $? "the template has exactly the placeholders the script replaces"
for needle in '^User=@SERVICE_USER@$' '^NoNewPrivileges=yes$' '^CapabilityBoundingSet=$' '^ProtectSystem=strict$' '^ProtectHome=yes$' '^IPAddressDeny=any$' \
              '^Environment=HF_HUB_OFFLINE=1$' '^Environment=PYTHONSAFEPATH=1$' '^Environment=PYTHONNOUSERSITE=1$' '^WorkingDirectory=/$' '^LimitCORE=0$' '^UMask=0077$' \
              '^RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6$' '^Restart=on-failure$'; do
    grep -q "$needle" "$TEMPLATE"; check $? "template: $needle"
done
if grep -Eq '^(User|Group)=root' "$TEMPLATE"; then bad "the template runs as root"; else ok "the template never names root"; fi
if grep -Eq '^(PrivateDevices|DevicePolicy|MemoryDenyWriteExecute)=' "$TEMPLATE"; then bad "the template sets a directive that blocks the GPU or CUDA"; else ok "the template keeps the GPU reachable (no PrivateDevices, DevicePolicy, MemoryDenyWriteExecute)"; fi
"$REAL_PY3" -c "import json,sys; json.load(open(sys.argv[1]))" "$EXAMPLE"; check $? "asr-server.example.json is valid JSON"
[ -f "$REQS" ] && [ "$(grep -Ec '^(faster-whisper|ctranslate2|numpy)==' "$REQS")" = 3 ]; check $? "requirements-server.txt pins faster-whisper, ctranslate2 and numpy"
if grep -rqE 'faster-whisper|ctranslate2|requirements-server' "$ROOT/pipeline/requirements.lock.txt" "$ROOT/scripts/setup_python.sh" 2>/dev/null; then
    bad "the client lock or setup_python.sh knows the server packages"
else ok "the client lock and setup_python.sh do not know the server packages"; fi

# ---------------------------------------------------------------------------------------------------------------
section "usage and refusals (nothing may reach useradd, groupadd, chown, systemctl, pip)"
reset_stub_logs
run_script help "$STUBS" --help; rc_is 0 "--help exits 0"; out_has "PLAN \(dry run\)" "--help documents the plan"; out_has "--allow-from CIDR" "--help documents --allow-from"
run_script bad1 "$STUBS" --nope; rc_is 2 "an unknown option exits 2"
run_script bad2 "$STUBS" --start --python "$STUB_PY"; rc_is 2 "--start without --apply exits 2"; out_has "needs --apply" "...and says why"
run_script bad3 "$STUBS" --apply --stage-dir "$WORK/x" --python "$STUB_PY"; rc_is 2 "--apply with --stage-dir exits 2"
run_script bad4 "$STUBS" --stage-dir relative/dir --python "$STUB_PY"; rc_is 2 "a relative --stage-dir exits 2"
run_script bad5 "$STUBS" --support-dir relative --python "$STUB_PY"; rc_is 2 "a relative --support-dir exits 2"
run_script bad6 "$STUBS" --support-dir "/var/lib/with space" --python "$STUB_PY"; rc_is 2 "a path with a space exits 2 (it goes into a unit)"
run_script bad6b "$STUBS" --log-dir '/var/log/100%x' --python "$STUB_PY"; rc_is 2 "a path with a systemd specifier character exits 2"
run_script bad6c "$STUBS" --support-dir /home/someone/state --python "$STUB_PY"; rc_is 2 "a support directory under /home exits 2"; out_has "sandbox hides" "...because the service's sandbox hides /home"
run_script bad6d "$STUBS" --venv /var/lib/../etc/venv --python "$STUB_PY"; rc_is 2 "a path with .. exits 2"
run_script bad7 "$STUBS" --service-user "Bad User" --python "$STUB_PY"; rc_is 2 "a bad --service-user exits 2"
run_script bad7b "$STUBS" --service-user root --python "$STUB_PY"; rc_is 2 "--service-user root exits 2"; out_has "must not be root" "...with the reason"
run_script bad8 "$STUBS" --device tpu --python "$STUB_PY"; rc_is 2 "an unknown --device exits 2"
run_script bad9 "$STUBS" --compute-type float32 --python "$STUB_PY"; rc_is 2 "an unknown --compute-type exits 2"
run_script bad10 "$STUBS" --python "$WORK/no-such-python"; rc_is 1 "a missing python exits 1"
STUB_PY_VERSION=3.9 run_script bad11 "$STUBS" --python "$STUB_PY"; rc_is 1 "Python 3.9 exits 1"; out_has "needs 3.11 or 3.12" "...with the version it needs"
run_script bad12 "$STUBS" --model "$(printf 'x\001y')" --python "$STUB_PY"; rc_is 2 "a --model with a control character exits 2"
run_script bad13 "$STUBS" --apply --python "$STUB_PY"
if [ "$(id -u)" = 0 ]; then echo "  skip --apply as an ordinary user (these tests run as root)"; else
    rc_is 1 "--apply as an ordinary user is refused"; out_has "needs root" "...with a message that says so"
fi
PUBKEY="$WORK/keys"; mkdir -p "$PUBKEY"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBstub\n-----END CERTIFICATE-----\n' > "$PUBKEY/cert.pem"
printf -- '-----BEGIN PRIVATE KEY-----\nMIIBstub\n-----END PRIVATE KEY-----\n' > "$PUBKEY/key.pem"; chmod 600 "$PUBKEY/key.pem"
printf -- '-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIBstub\n-----END ENCRYPTED PRIVATE KEY-----\n' > "$PUBKEY/key-enc.pem"
cat "$PUBKEY/cert.pem" "$PUBKEY/key.pem" > "$PUBKEY/cert-with-key.pem"
printf 'not a pem\n' > "$PUBKEY/junk.pem"
VPN=(--listen 10.8.0.1:8443 --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key.pem" --allow-from 10.8.0.0/24)

run_script l1 "$STUBS" --listen 0.0.0.0:8443 --python "$STUB_PY"; rc_is 2 "--listen 0.0.0.0 exits 2"; out_has "every interface" "...saying that it listens everywhere"
run_script l2 "$STUBS" --listen '[::]:8443' --python "$STUB_PY"; rc_is 2 "--listen [::] exits 2"
run_script l3 "$STUBS" --listen 8.8.8.8:8443 --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key.pem" --allow-from 10.8.0.0/24 --python "$STUB_PY"
rc_is 2 "a public bind address exits 2 even with TLS"; out_has "public address" "...saying so"
run_script l4 "$STUBS" --listen 127.0.0.1:443 --python "$STUB_PY"; rc_is 2 "a port below 1024 exits 2 (the service has no capabilities)"
run_script l5 "$STUBS" --listen asr.example.com:8443 --python "$STUB_PY"; rc_is 2 "a host name instead of an address exits 2"
run_script l6 "$STUBS" --listen 10.8.0.1:8443 --allow-from 10.8.0.0/24 --python "$STUB_PY"; rc_is 2 "a non-loopback address without TLS exits 2"; out_has "TLS is required" "...with the reason"
run_script l7 "$STUBS" --listen 10.8.0.1:8443 --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key.pem" --python "$STUB_PY"
rc_is 2 "a non-loopback address without --allow-from exits 2"; out_has "allow-from" "...naming the option"
run_script l8 "$STUBS" --allow-from 8.8.8.0/24 --python "$STUB_PY"; rc_is 2 "--allow-from a public network exits 2"; out_has "not inside a private range" "...with the reason"
run_script l9 "$STUBS" --allow-from 0.0.0.0/0 --python "$STUB_PY"; rc_is 2 "--allow-from 0.0.0.0/0 exits 2"
run_script l10 "$STUBS" --allow-from nonsense --python "$STUB_PY"; rc_is 2 "--allow-from garbage exits 2"
run_script l11 "$STUBS" --listen 127.0.0.1:8443 --tls-cert "$PUBKEY/cert.pem" --python "$STUB_PY"; rc_is 2 "--tls-cert without --tls-key exits 2"
run_script l12 "$STUBS" --tls-cert "$PUBKEY/key.pem" --tls-key "$PUBKEY/cert.pem" --python "$STUB_PY"; rc_is 2 "swapped certificate and key exit 2"
run_script l13 "$STUBS" --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key-enc.pem" --python "$STUB_PY"; rc_is 2 "an encrypted key exits 2"; out_has "can not ask for a passphrase" "...with the reason"
run_script l14 "$STUBS" --tls-cert "$PUBKEY/cert-with-key.pem" --tls-key "$PUBKEY/key.pem" --python "$STUB_PY"; rc_is 2 "a certificate file that holds the private key exits 2"
run_script l15 "$STUBS" --tls-cert "$PUBKEY/junk.pem" --tls-key "$PUBKEY/key.pem" --python "$STUB_PY"; rc_is 2 "a certificate that is not PEM exits 2"
run_script l16 "$STUBS" --listen 100.64.1.5:8443 --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key.pem" --allow-from 100.64.0.0/10 --python "$STUB_PY"
rc_is 0 "a CGNAT/Tailscale address with TLS and its network is accepted (plan)"
run_script l17 "$STUBS" --listen '[fd00::1]:8443' --tls-cert "$PUBKEY/cert.pem" --tls-key "$PUBKEY/key.pem" --allow-from fd00::/64 --python "$STUB_PY"
rc_is 0 "a ULA IPv6 address with TLS and its network is accepted (plan)"
no_system_calls && [ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "none of the refusals or accepted plans reached useradd, groupadd, chown, systemctl, sudo or security"
if grep -qE -- '-m (venv|pip)' "$STUB_LOG/python.log" 2>/dev/null; then bad "a refusal or a plan built a venv or ran pip"; else ok "...nor built a venv or ran pip"; fi

# ---------------------------------------------------------------------------------------------------------------
section "plan (the default): prints what it would do, changes nothing"
reset_stub_logs
run_script plan "$STUBS" --python "$STUB_PY" --venv "$WORK/plan-venv" --config-dir "$WORK/plan-etc" --support-dir "$WORK/plan-support" --log-dir "$WORK/plan-log" --unit-path "$WORK/plan.service"
rc_is 0 "a plan exits 0"
out_has "PLAN \(dry run\): nothing is changed" "it says it is a plan"
out_has "groupadd --system mcap-asr" "the plan shows the group"
out_has "useradd --system --gid mcap-asr .*--no-create-home --shell /usr/sbin/nologin" "the plan shows a system user without a shell and without a created home"
out_has "mkdir -p .*plan-support" "the plan lists the directories"
out_has "-m venv .*plan-venv" "the plan shows the venv"
out_has "-m pip install .*-r .*pipeline/requirements-server.txt" "the plan shows the pinned install"
out_has "pip contacts the package index" "the plan says when the network is used"
out_has "\"backend\": \"faster-whisper\"" "the plan prints the config with the faster-whisper backend"
out_has "\"device\": \"auto\"" "...and the device"
out_has "\"listen\": \"127.0.0.1:8443\"" "...and the loopback bind"
out_has "^User=mcap-asr$" "the plan prints the unit running as the service user"
out_has "^IPAddressDeny=any$" "...denying every network"
out_has "^IPAddressAllow=localhost$" "...except localhost"
out_has "mcap.asr_faster_whisper fetch --yes" "the next steps say how to fetch the model by hand"
out_has "check --load" "the next steps say how to test the GPU stack"
out_has "CUDA 12 runtime libraries \(cuBLAS 12\) and cuDNN 9" "the next steps name the CUDA prerequisites"
out_has "enroll-code issue" "the next steps cover the enrollment codes"
out_has "TLS terminator" "the loopback case says a TLS terminator is needed"
out_has "WARNING: nvidia-smi not found" "no nvidia-smi: the plan warns that the server would run on the CPU"
[ ! -e "$WORK/plan-venv" ] && [ ! -e "$WORK/plan-etc" ] && [ ! -e "$WORK/plan-support" ] && [ ! -e "$WORK/plan-log" ] && [ ! -e "$WORK/plan.service" ]; check $? "a plan created no venv, directory or unit"
[ -z "$LEFTOVER" ]; check $? "a plan left nothing in TMPDIR"
no_system_calls && [ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "a plan called no useradd, groupadd, chown, systemctl, sudo or security"
if grep -qE -- '-m (venv|pip)' "$STUB_LOG/python.log"; then bad "a plan built a venv or ran pip"; else ok "a plan built no venv and ran no pip"; fi

run_script plan2 "$STUBS" --python "$STUB_PY" --device cpu --model large-v3 --wheelhouse /srv/wheels
rc_is 0 "a cpu plan with a wheelhouse exits 0"
out_has "\"compute_type\": \"int8\"" "--device cpu defaults the compute type to int8"
out_has "device cpu: the GPU is not used" "...and says the CPU is slow"
out_has "pip install .*--no-index --find-links /srv/wheels" "--wheelhouse installs offline"
out_lacks "pip contacts the package index" "...and does not announce the network"
out_has "\"model\": \"large-v3\"" "--model reaches the config"

cp "$WORK/nvidia-smi.on" "$STUBS/nvidia-smi"; chmod +x "$STUBS/nvidia-smi"
run_script plan3 "$STUBS" --python "$STUB_PY"
out_has "GPU: GPU 0: NVIDIA Stub 16GB" "with nvidia-smi present the plan lists the GPU"
out_lacks "WARNING: nvidia-smi not found" "...and does not warn"
run_script plan4 "$STUBS" --python "$STUB_PY" --device cpu
out_has "device cpu: the GPU is not used" "--device cpu ignores a GPU that is there"
rm -f "$STUBS/nvidia-smi"

run_script plan5 "$STUBS" --python "$STUB_PY" "${VPN[@]}"
rc_is 0 "a VPN plan exits 0"
out_has "listen  10.8.0.1:8443 \(private\), TLS" "the VPN plan names the bind address and TLS"
out_has "^IPAddressAllow=10.8.0.0/24$" "the unit allows the VPN subnet"
out_has "\"tls_cert\": \".*/tls.crt\"" "the config names the TLS files in the support directory"
out_has "ufw allow from 10.8.0.0/24 to any port 8443 proto tcp" "the plan prints the firewall rule"
out_has "Never open port 8443 on a public interface" "...and the warning"
out_has "wg-quick@wg0.service" "...and how to order the unit after the VPN"
out_has "new file .*tls.key \(mode 600" "the plan shows the TLS key as 0600"
out_has "DNS NAME that is in the certificate" "the plan says clients use a DNS name, never an IP address"

# ---------------------------------------------------------------------------------------------------------------
section "stage tree (--stage-dir): the files --apply would create, without root"
reset_stub_logs
STAGE="$WORK/stage"
S_ARGS=(--stage-dir "$STAGE" --python "$STUB_PY" --venv /srv/venv --config-dir /srv/asr-etc --support-dir /srv/asr-state --log-dir /srv/asr-log --unit-path /srv/units/asr.service)
run_script stage "$STUBS" "${S_ARGS[@]}"
rc_is 0 "staging exits 0"
SS="$STAGE/srv/asr-state"; SL="$STAGE/srv/asr-log"; SE="$STAGE/srv/asr-etc"; SU="$STAGE/srv/units/asr.service"
[ -d "$SS" ] && [ -d "$SS/home" ] && [ -d "$SL" ] && [ -d "$SE" ] && [ -f "$SE/asr-server.json" ] && [ -f "$SU" ]; check $? "the tree has the support, home, log and config directories, the config and the unit"
[ ! -e "$STAGE/srv/venv" ]; check $? "staging builds no venv"
mode_is "$SS" 700 "the support directory is 0700"
mode_is "$SS/home" 700 "the service home is 0700"
mode_is "$SL" 700 "the log directory is 0700"
mode_is "$SE" 755 "the config directory is 0755 (root-owned in the real install)"
mode_is "$SE/asr-server.json" 644 "the config is 0644 (root-owned: the service cannot change its own limits)"
mode_is "$SU" 644 "the unit is 0644"
[ -f "$SS/.mcap-asr-install" ] && [ -f "$SL/.mcap-asr-install" ]; check $? "the staged directories carry the installer's marker"
if grep -Eq '@[A-Z_]+@' "$SU"; then bad "a placeholder is left in the unit"; else ok "no placeholder is left in the unit"; fi
has_line "User=mcap-asr" "$SU" && has_line "Group=mcap-asr" "$SU"; check $? "the unit runs as the service user and group"
has_line "ExecStart=/srv/venv/bin/python -m mcap.asr_server --config /srv/asr-etc/asr-server.json serve" "$SU"; check $? "the unit names the REAL venv python and config path, even for a staged tree"
has_line "ReadWritePaths=/srv/asr-state /srv/asr-log" "$SU"; check $? "the only writable paths are the support and log directories"
has_line "Environment=HOME=/srv/asr-state/home" "$SU"; check $? "HOME is the service home (data only: the model cache)"
has_line "Environment=PYTHONPATH=$ROOT/pipeline" "$SU"; check $? "PYTHONPATH is the pipeline of the project"
has_line "Environment=MCAP_ASR_SERVER_CONFIG=/srv/asr-etc/asr-server.json" "$SU"; check $? "the config path is also in the environment"
[ "$(grep -c '^User=' "$SU")" = 1 ] && ! grep -q '^User=root' "$SU"; check $? "exactly one User= line and it is not root"
has_line "IPAddressDeny=any" "$SU" && has_line "IPAddressAllow=localhost" "$SU" && [ "$(grep -c '^IPAddressAllow=' "$SU")" = 1 ]; check $? "a loopback install allows localhost only"
[ "$(grep -n '^IPAddressDeny=any' "$SU" | cut -d: -f1)" -lt "$(grep -n '^IPAddressAllow=localhost' "$SU" | cut -d: -f1)" ]; check $? "the deny line comes before the allow lines"
"$REAL_PY3" - "$SE/asr-server.json" <<'PYEOF'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["secrets_dir"] == "/srv/asr-state" and obj["log_dir"] == "/srv/asr-log", obj
assert obj["listen"] == "127.0.0.1:8443" and obj["backend"] == "faster-whisper" and obj["model"] == "", obj
assert obj["backend_options"] == {"device": "auto", "compute_type": "float16"}, obj["backend_options"]
assert obj["tls_cert"] == "" and obj["tls_key"] == ""
PYEOF
check $? "the staged config carries the chosen directories, stays loopback and names the faster-whisper backend"
if [ -n "$VENV_PY" ]; then
    PYTHONPATH="$ROOT/pipeline" "$VENV_PY" - "$SE/asr-server.json" <<'PYEOF'
import sys
from mcap import asr_server as S
from mcap.asr_faster_whisper import FasterWhisperEngine
cfg = S.load_server_config(sys.argv[1])
engine = S.default_backend_factory(cfg)
assert isinstance(engine, FasterWhisperEngine), engine
assert (engine.model, engine.device, engine.compute_type, engine.allow_download) == ("large-v3", "auto", "float16", False)
assert "faster_whisper" not in sys.modules and "ctranslate2" not in sys.modules
PYEOF
    check $? "the staged config is accepted by the strict loader and builds the faster-whisper engine without importing the packages"
else
    echo "  skip the strict loader check (no production venv at $HOME/Library/Application Support/MeetingCapture/venv)"
fi
if grep -rqE 'mcap1_[0-9a-f]{8}_' "$STAGE"; then bad "a token is in a staged file"; else ok "no token is in any staged file"; fi
no_system_calls && [ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "staging called no useradd, groupadd, chown, systemctl, sudo or security"
if grep -qE -- '-m (venv|pip)' "$STUB_LOG/python.log"; then bad "staging built a venv or ran pip"; else ok "staging built no venv and ran no pip"; fi
out_has "skipped in --stage-dir mode" "the output says what staging leaves out"

echo "# kept" >> "$SE/asr-server.json"
run_script stage2 "$STUBS" "${S_ARGS[@]}"
rc_is 0 "staging twice exits 0"
tail -n 1 "$SE/asr-server.json" | grep -q '^# kept$'; check $? "an existing config is never overwritten"

STAGE2="$WORK/stage2"
run_script stage3 "$STUBS" --stage-dir "$STAGE2" --python "$STUB_PY" --venv /srv/venv --config-dir /srv/asr-etc --support-dir /srv/asr-state --log-dir /srv/asr-log \
    --unit-path /srv/units/asr.service --device cuda --compute-type int8_float16 --model /srv/models/large-v3-ct2 "${VPN[@]}" --allow-from 192.168.50.0/24
rc_is 0 "a staged VPN install exits 0"
SS2="$STAGE2/srv/asr-state"; SU2="$STAGE2/srv/units/asr.service"; SE2="$STAGE2/srv/asr-etc"
mode_is "$SS2/tls.crt" 644 "tls.crt is 0644"
mode_is "$SS2/tls.key" 600 "tls.key is 0600"
cmp -s "$SS2/tls.crt" "$PUBKEY/cert.pem" && cmp -s "$SS2/tls.key" "$PUBKEY/key.pem"; check $? "the TLS files are copies of the ones named"
has_line "IPAddressAllow=10.8.0.0/24" "$SU2" && has_line "IPAddressAllow=192.168.50.0/24" "$SU2" && has_line "IPAddressAllow=localhost" "$SU2"; check $? "the unit allows localhost and each --allow-from network"
"$REAL_PY3" - "$SE2/asr-server.json" <<'PYEOF'
import json, sys
obj = json.load(open(sys.argv[1]))
assert obj["listen"] == "10.8.0.1:8443", obj["listen"]
assert obj["tls_cert"] == "/srv/asr-state/tls.crt" and obj["tls_key"] == "/srv/asr-state/tls.key", obj
assert obj["model"] == "/srv/models/large-v3-ct2" and obj["backend_options"] == {"device": "cuda", "compute_type": "int8_float16"}, obj
PYEOF
check $? "the config carries the bind address, the TLS paths of the support directory, the model and the options"
if [ -n "$VENV_PY" ]; then
    PYTHONPATH="$ROOT/pipeline" "$VENV_PY" -c "
import sys
from mcap import asr_server as S
cfg = S.load_server_config(sys.argv[1])
assert cfg.tls and S.check_bind(cfg).ok
e = S.default_backend_factory(cfg)
assert (e.model, e.device, e.compute_type) == ('/srv/models/large-v3-ct2', 'cuda', 'int8_float16')
" "$SE2/asr-server.json"
    check $? "...and the strict loader accepts it, with TLS (the bind check passes)"
fi
run_script deep "$STUBS" --stage-dir "$WORK/stage-deep" --python "$STUB_PY" --venv /srv/venv --config-dir /srv/deep/etc/mcap --support-dir /srv/deep/a/b/state --log-dir /srv/deep/a/log --unit-path /srv/u.service
rc_is 0 "a staged install into nested directories exits 0"
mode_is "$WORK/stage-deep/srv/deep/a/b" 755 "a missing parent directory is traversable (0755): only the leaf is private"
mode_is "$WORK/stage-deep/srv/deep/a/b/state" 700 "...and the support directory itself is 0700"
mode_is "$WORK/stage-deep/srv/deep/etc" 755 "a missing parent of the config directory is 0755"
run_script stage4 "$STUBS" --stage-dir "$WORK/stage4" --python "$STUB_PY" --venv /srv/venv --config-dir /srv/e --support-dir /srv/s --log-dir /srv/l --unit-path /srv/u.service --device cpu
"$REAL_PY3" -c "import json,sys; o=json.load(open(sys.argv[1])); assert o['backend_options']=={'device':'cpu','compute_type':'int8'}, o" "$WORK/stage4/srv/e/asr-server.json"
check $? "--device cpu stages compute type int8"

# ---------------------------------------------------------------------------------------------------------------
section "--apply --start through stubs (an ordinary user pretends to be root on Linux; every path is inside the temp directory)"
AV="$WORK/apply-venv/venv"; AE="$WORK/apply-etc"; AS="$WORK/apply-state"; AL="$WORK/apply-log"; AU="$WORK/apply-units/mcap-asr.service"
A_ARGS=(--apply --python "$STUB_PY" --service-user mcap-test --venv "$AV" --config-dir "$AE" --support-dir "$AS" --log-dir "$AL" --unit-path "$AU")
reset_stub_logs
rm -f "${STUB_STATE:?}"/user.* "${STUB_STATE:?}"/group.*
run_script apply "$STUBS_ROOT:$STUBS" "${A_ARGS[@]}" --start
rc_is 0 "apply exits 0"
grep -q "groupadd --system mcap-test" "$STUB_LOG/groupadd.log"; check $? "the group is a system group"
grep -q "useradd --system --gid mcap-test --home-dir $AS/home --no-create-home --shell /usr/sbin/nologin" "$STUB_LOG/useradd.log"; check $? "the user is a system user with no login shell and the service home as its (uncreated) home"
grep -q "chown -h mcap-test:mcap-test $AS\$" "$STUB_LOG/chown.log" && grep -q "chown -h mcap-test:mcap-test $AL\$" "$STUB_LOG/chown.log" && grep -q "chown -h mcap-test:mcap-test $AS/home\$" "$STUB_LOG/chown.log"
check $? "the support, home and log directories are chowned to the service user (chown -h: never through a link)"
grep -q "chown -h root:root $AE\$" "$STUB_LOG/chown.log" && grep -q "chown -h root:root $AE/asr-server.json\$" "$STUB_LOG/chown.log" && grep -q "chown -h root:root $AU\$" "$STUB_LOG/chown.log"
check $? "the config directory, the config and the unit are chowned to root:root"
if grep -E '^chown ' "$STUB_LOG/chown.log" | grep -vq '^chown -h '; then bad "a chown ran without -h"; else ok "every chown ran with -h"; fi
[ "$(grep -n "chown -h mcap-test:mcap-test $AS\$" "$STUB_LOG/chown.log" | cut -d: -f1)" -gt "$(grep -n "chown -h mcap-test:mcap-test $AS/home\$" "$STUB_LOG/chown.log" | cut -d: -f1)" ]
check $? "the support directory is handed to the service user AFTER the home directory inside it (it could swap what is inside for a link once it owns it)"
[ -f "$AS/.mcap-asr-install" ] && [ -f "$AL/.mcap-asr-install" ]; check $? "both directories carry the marker 'made by install_server_linux.sh'"
mode_is "$AS" 700 "the support directory is 0700"
mode_is "$AS/home" 700 "the service home is 0700"
mode_is "$AL" 700 "the log directory is 0700"
mode_is "$AE" 755 "the config directory is 0755"
mode_is "$AE/asr-server.json" 644 "the config is 0644"
mode_is "$AU" 644 "the unit is 0644"
has_line "User=mcap-test" "$AU" && has_line "ExecStart=$AV/bin/python -m mcap.asr_server --config $AE/asr-server.json serve" "$AU"; check $? "the installed unit names the chosen user, venv and config"
grep -q -- "-m venv $AV" "$STUB_LOG/python.log"; check $? "the venv is created at the chosen place"
grep -q -- "-m pip install --disable-pip-version-check --no-input -r $ROOT/pipeline/requirements-server.txt" "$STUB_LOG/python.log"; check $? "the pinned requirements are installed into the venv (not the system python)"
if grep -q -- "--no-index" "$STUB_LOG/python.log"; then bad "pip was told --no-index without a wheelhouse"; else ok "without --wheelhouse pip uses the index"; fi
grep -q -- "-m pip check" "$STUB_LOG/python.log"; check $? "pip check runs after the install"
grep -q "^systemctl daemon-reload" "$STUB_LOG/systemctl.log"; check $? "systemd is told to reload its units"
grep -q "^systemctl enable mcap-asr.service" "$STUB_LOG/systemctl.log" && grep -q "^systemctl restart mcap-asr.service" "$STUB_LOG/systemctl.log"; check $? "--start enables and restarts the service"
grep -q "^systemd-analyze verify $AU" "$STUB_LOG/systemd-analyze.log"; check $? "the unit is verified with systemd-analyze"
out_has "journalctl -u mcap-asr" "--start says where to watch the service"
[ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "no sudo, security, launchctl, open, curl or wget call"
: > "$STUB_LOG/useradd.log"; : > "$STUB_LOG/groupadd.log"; : > "$STUB_LOG/systemctl.log"
run_script apply2 "$STUBS_ROOT:$STUBS" "${A_ARGS[@]}"
rc_is 0 "a second apply exits 0"
[ "$(stub_calls useradd)" = 0 ] && [ "$(stub_calls groupadd)" = 0 ]; check $? "an existing service user is left alone"
out_has "exists already: left as it is" "...and the output says so"
if grep -q "^systemctl enable\|^systemctl restart" "$STUB_LOG/systemctl.log"; then bad "a second apply without --start enabled or restarted the service"; else ok "without --start nothing is enabled or restarted"; fi
out_has "not started" "...and the commands are printed instead"
out_has "exists: left as it is" "an existing config is left as it is"

reset_stub_logs
run_script apply3 "$STUBS_ROOT:$STUBS" "${A_ARGS[@]}" --wheelhouse "$WORK/wheels"
grep -q -- "--no-index --find-links $WORK/wheels" "$STUB_LOG/python.log"; check $? "--wheelhouse installs from the directory only"

section "--apply with TLS keeps the key private"
BS="$WORK/b-state"
reset_stub_logs
run_script applytls "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/b-venv" --config-dir "$WORK/b-etc" --support-dir "$BS" --log-dir "$WORK/b-log" --unit-path "$WORK/b.service" "${VPN[@]}"
rc_is 0 "an apply with TLS exits 0"
mode_is "$BS/tls.key" 600 "tls.key is 0600"
mode_is "$BS/tls.crt" 644 "tls.crt is 0644"
grep -q "chown -h mcap-test:mcap-test $BS/tls.key\$" "$STUB_LOG/chown.log"; check $? "tls.key is chowned to the service user"
[ "$(grep -n "chown -h mcap-test:mcap-test $BS/tls.key\$" "$STUB_LOG/chown.log" | cut -d: -f1)" -lt "$(grep -n "chown -h mcap-test:mcap-test $BS\$" "$STUB_LOG/chown.log" | cut -d: -f1)" ]
check $? "the TLS files are made while root still owns the directory (before it is handed over)"
chmod 644 "$PUBKEY/key.pem"
run_script tlswarn "$STUBS" --python "$STUB_PY" "${VPN[@]}"
out_has "WARNING: .*key.pem is readable by others" "a world-readable original key is warned about"
chmod 600 "$PUBKEY/key.pem"

section "--apply refuses code the service user could change, a Python it cannot use, a uid-0 service user, and a non-Linux system"
reset_stub_logs
mkdir -p "$STUBS_ROOT/proj501" "$STUBS_ROOT/dir501"
cat > "$STUBS_ROOT/proj501/stat" <<'EOF'
#!/bin/sh
# Like the root stub, except that the project (anything with 'pipeline' in its path) belongs to uid 501.
if { [ "$1" = "-c" ] || [ "$1" = "-f" ]; } && [ "$2" = "%u" ]; then case "$3" in *pipeline*) echo 501 ;; *) echo 0 ;; esac; exit 0; fi
exec /usr/bin/stat "$@"
EOF
cat > "$STUBS_ROOT/dir501/stat" <<'EOF'
#!/bin/sh
# Like the root stub, except that anything with 'other-owner' in its path belongs to uid 501.
if { [ "$1" = "-c" ] || [ "$1" = "-f" ]; } && [ "$2" = "%u" ]; then case "$3" in *other-owner*) echo 501 ;; *) echo 0 ;; esac; exit 0; fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$STUBS_ROOT/proj501/stat" "$STUBS_ROOT/dir501/stat"
run_script owner "$STUBS_ROOT/proj501:$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/o-venv" --config-dir "$WORK/o-etc" --support-dir "$WORK/o-support" --log-dir "$WORK/o-log" --unit-path "$WORK/o.service"
rc_is 1 "a project that is not owned by root is refused"; out_has "must be owned by root" "...with the reason"
[ "$(stub_calls useradd)" = 0 ] && [ "$(stub_calls chown)" = 0 ] && [ ! -e "$WORK/o-support" ] && [ ! -e "$WORK/o-venv" ]; check $? "...before any user, directory, venv or file was made"
run_script home "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --project /home/someone/mcap --service-user mcap-test --venv "$WORK/h-venv" --config-dir "$WORK/h-etc" --support-dir "$WORK/h-support" --log-dir "$WORK/h-log" --unit-path "$WORK/h.service"
rc_is 1 "a --project under /home is refused (the sandbox hides it)"; out_has "sandbox hides" "...with the reason"
[ "$(stub_calls useradd)" = 0 ] && [ ! -e "$WORK/h-support" ]; check $? "...before anything was made"
echo 0 > "$STUB_STATE/user.mcap-zero"
run_script zero "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-zero --venv "$WORK/z-venv" --config-dir "$WORK/z-etc" --support-dir "$WORK/z-support" --log-dir "$WORK/z-log" --unit-path "$WORK/z.service"
rc_is 1 "an existing service user with uid 0 is refused"; out_has "uid 0" "...saying why"
mkdir -p "$STUBS_ROOT/darwin"
cat > "$STUBS_ROOT/darwin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ] && [ -z "$2" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod +x "$STUBS_ROOT/darwin/id"
if [ "$(uname -s)" = Linux ]; then echo "  skip the non-Linux refusal (this is Linux)"; else
    run_script darwin "$STUBS_ROOT/darwin:$STUBS" --apply --python "$STUB_PY" --venv "$WORK/d-venv" --config-dir "$WORK/d-etc" --support-dir "$WORK/d-support" --log-dir "$WORK/d-log" --unit-path "$WORK/d.service"
    rc_is 1 "--apply on a system that is not Linux is refused"; out_has "for Linux with systemd" "...pointing to install_server.sh for the Mac"
fi
[ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "no sudo and no security call in any of these cases"

# ---------------------------------------------------------------------------------------------------------------
section "--apply again: what the service user could have turned into a link, and paths that are not ours, are refused"
SS3="$WORK/sym-state"; SL3="$WORK/sym-log"; SE3="$WORK/sym-etc"; SU3="$WORK/sym-units/x.service"; OUTSIDE="$WORK/outside"
mkdir -p "$OUTSIDE/victim-home" "$OUTSIDE/victim-log"; chmod 755 "$OUTSIDE/victim-home" "$OUTSIDE/victim-log"
apply_again() { run_script "$1" "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/sym-venv" --config-dir "$SE3" --support-dir "$SS3" --log-dir "$SL3" --unit-path "$SU3"; }
reset_stub_logs
apply_again s1; rc_is 0 "a first apply for these cases exits 0"
apply_again s1b; rc_is 0 "and so does the second one (an upgrade of an installation made by this script)"

reset_stub_logs
rm -rf "$SS3/home"; ln -s "$OUTSIDE/victim-home" "$SS3/home"
apply_again s2; rc_is 1 "a service home that became a link to another directory is refused"
out_has "symbolic link" "...and the message names the link"
mode_is "$OUTSIDE/victim-home" 755 "the directory the link points to was not chmodded"
[ "$(stub_calls chown)" = 0 ]; check $? "...and nothing was chowned"
rm -f "$SS3/home"; mkdir "$SS3/home"

reset_stub_logs
LINK_LOG="$WORK/link-log"; ln -s "$OUTSIDE/victim-log" "$LINK_LOG"
run_script s3 "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s3-venv" --config-dir "$WORK/s3-etc" --support-dir "$WORK/s3-support" --log-dir "$LINK_LOG" --unit-path "$WORK/s3.service"
rc_is 1 "a --log-dir that is a link is refused"
mode_is "$OUTSIDE/victim-log" 755 "the directory behind it was not chmodded"
[ ! -e "$WORK/s3-support" ] && [ "$(stub_calls chown)" = 0 ]; check $? "...and nothing else was made before the refusal"
run_script s3d "$STUBS" --python "$STUB_PY" --support-dir "$WORK/s3d-support" --log-dir "$LINK_LOG"
rc_is 1 "a plan refuses it too (it reports what --apply would refuse)"

reset_stub_logs
rm -f "$SE3/asr-server.json"; ln -s "$OUTSIDE/config-by-root.json" "$SE3/asr-server.json"
apply_again s4; rc_is 1 "an asr-server.json that became a dangling link is refused"
[ ! -e "$OUTSIDE/config-by-root.json" ]; check $? "...and no config was written through it"
rm -f "$SE3/asr-server.json"
apply_again s4b; rc_is 0 "with the link gone the next apply makes the config again"
[ -f "$SE3/asr-server.json" ] && [ ! -L "$SE3/asr-server.json" ]; check $? "...as a plain file"

reset_stub_logs
rm -f "$SU3"; ln -s "$OUTSIDE/unit-by-root.service" "$SU3"
apply_again s5; rc_is 1 "a unit path that became a link is refused"
[ ! -e "$OUTSIDE/unit-by-root.service" ]; check $? "...and no unit was written through it"
rm -f "$SU3"

mkdir -p "$WORK/stranger"; echo data > "$WORK/stranger/important"; chmod 755 "$WORK/stranger"
reset_stub_logs
run_script s6 "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s6-venv" --config-dir "$WORK/s6-etc" --support-dir "$WORK/stranger" --log-dir "$WORK/s6-log" --unit-path "$WORK/s6.service"
rc_is 1 "a --support-dir that is not empty and was not made by this script is refused"
out_has "not empty and was not made by this script" "...with the reason"
mode_is "$WORK/stranger" 755 "...and it was not chmodded"
[ "$(stub_calls chown)" = 0 ] && [ ! -e "$WORK/s6-log" ]; check $? "...nor chowned, and the log directory was not made"

# The same guard for the LOG directory (a mistaken --log-dir /var/log must not be chmod 700 and chowned either).
mkdir -p "$WORK/stranger-log"; echo data > "$WORK/stranger-log/syslog"; chmod 755 "$WORK/stranger-log"
reset_stub_logs
run_script s6b "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s6b-venv" --config-dir "$WORK/s6b-etc" --support-dir "$WORK/s6b-support" --log-dir "$WORK/stranger-log" --unit-path "$WORK/s6b.service"
rc_is 1 "a --log-dir that is not empty and was not made by this script is refused"
out_has "the log directory .* is not empty and was not made by this script" "...naming the log directory and the reason"
mode_is "$WORK/stranger-log" 755 "...and it was not chmodded"
[ "$(stub_calls chown)" = 0 ] && [ "$(stub_calls useradd)" = 0 ]; check $? "...nor chowned, and no user was made"
[ ! -e "$WORK/s6b-support" ] && [ ! -e "$WORK/s6b-etc" ] && [ ! -e "$WORK/s6b.service" ] && [ ! -e "$WORK/stranger-log/.mcap-asr-install" ]; check $? "...nothing else was created, no marker was dropped into it"
[ "$(cat "$WORK/stranger-log/syslog")" = data ]; check $? "...and what was in it is untouched"
run_script s6c "$STUBS" --python "$STUB_PY" --support-dir "$WORK/s6c-support" --log-dir "$WORK/stranger-log"
rc_is 1 "a plan refuses it too (it reports what --apply would refuse)"
mkdir -p "$WORK/s6d-stage/var/log"; echo data > "$WORK/s6d-stage/var/log/syslog"; chmod 755 "$WORK/s6d-stage/var/log"
run_script s6d "$STUBS" --stage-dir "$WORK/s6d-stage" --python "$STUB_PY" --log-dir /var/log
rc_is 1 "a --stage-dir tree whose log directory holds foreign files is refused too"
mode_is "$WORK/s6d-stage/var/log" 755 "...and it was not chmodded"
[ ! -e "$WORK/s6d-stage/var/log/.mcap-asr-install" ]; check $? "...and got no marker"

mkdir -p "$WORK/meta-log"; : > "$WORK/meta-log/meta-2026-10-01.jsonl"
reset_stub_logs
run_script s6e "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s6e-venv" --config-dir "$WORK/s6e-etc" --support-dir "$WORK/s6e-support" --log-dir "$WORK/meta-log" --unit-path "$WORK/s6e.service"
rc_is 0 "a log directory with a meta-*.jsonl file (an installation from before the marker) is accepted"
[ -f "$WORK/meta-log/.mcap-asr-install" ] && [ -f "$WORK/meta-log/meta-2026-10-01.jsonl" ]; check $? "...gets the marker and keeps its log"
mode_is "$WORK/meta-log" 700 "...and is 0700 afterwards"

mkdir -p "$WORK/empty-support"
reset_stub_logs
run_script s7 "$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s7-venv" --config-dir "$WORK/s7-etc" --support-dir "$WORK/empty-support" --log-dir "$WORK/s7-log" --unit-path "$WORK/s7.service"
rc_is 0 "an existing EMPTY support directory is accepted"

rm -f "$SS3/.mcap-asr-install" "$SL3/.mcap-asr-install"
echo '{}' > "$SS3/tokens.json"
reset_stub_logs
apply_again s8; rc_is 0 "an installation from before the marker existed (it has tokens.json) is accepted"
[ -f "$SS3/.mcap-asr-install" ] && [ -f "$SL3/.mcap-asr-install" ]; check $? "...and gets the marker"

mkdir -p "$WORK/other-owner-support"
reset_stub_logs
run_script s9 "$STUBS_ROOT/dir501:$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/s9-venv" --config-dir "$WORK/s9-etc" --support-dir "$WORK/other-owner-support" --log-dir "$WORK/s9-log" --unit-path "$WORK/s9.service"
rc_is 1 "an existing support directory owned by somebody else is refused"
out_has "owned by uid 501" "...with the owner named"
[ "$(stub_calls chown)" = 0 ]; check $? "...and nothing was chowned"

# A link that appears AFTER the checks (somebody wins a race between the check and the write) must not be written through either: the files
# are created exclusively. The chown stub plays the service user: when the support directory has been handed over (the last chown of step 3)
# it plants a dangling link where the config is about to be created.
RS="$WORK/race-state"; RE="$WORK/race-etc"
mkdir -p "$STUBS_ROOT/race"
cat > "$STUBS_ROOT/race/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "\${STUB_LOG:?}/chown.log"
if [ "\$3" = "$RS" ]; then
    ln -s "$OUTSIDE/raced-config.json" "$RE/asr-server.json"
fi
exit 0
EOF
chmod +x "$STUBS_ROOT/race/chown"
reset_stub_logs
run_script race "$STUBS_ROOT/race:$STUBS_ROOT:$STUBS" --apply --python "$STUB_PY" --service-user mcap-test --venv "$WORK/race-venv" --config-dir "$RE" --support-dir "$RS" --log-dir "$WORK/race-log" --unit-path "$WORK/race.service"
rc_is 1 "a link planted after the checks makes the installer stop"
out_has "something is there already" "...saying why"
[ ! -e "$OUTSIDE/raced-config.json" ]; check $? "...and nothing was created through the planted link"
[ ! -e "$STUB_LOG/FORBIDDEN.log" ]; check $? "no sudo and no security call in any of these cases"

# ---------------------------------------------------------------------------------------------------------------
section "the unit's Python environment ignores a planted module (a reviewer's ssl.py in the working directory)"
if [ -n "$VENV_PY" ]; then
    PLANT="$WORK/plant"; mkdir -p "$PLANT"; printf 'print("PLANTED-MODULE-RAN")\n' > "$PLANT/ssl.py"
    SAFE="$(sed -n 's/^Environment=PYTHONSAFEPATH=//p' "$AU")"; NOUSER="$(sed -n 's/^Environment=PYTHONNOUSERSITE=//p' "$AU")"
    (cd "$PLANT" && env -i PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/pipeline" "$VENV_PY" -m mcap.asr_server --help > "$OUT" 2>&1)
    grep -q PLANTED-MODULE-RAN "$OUT"; check $? "(control) without the unit's variables a planted ssl.py in the working directory is imported first"
    (cd "$PLANT" && env -i PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/pipeline" PYTHONSAFEPATH="$SAFE" PYTHONNOUSERSITE="$NOUSER" \
        "$VENV_PY" -m mcap.asr_server --help > "$OUT" 2>&1)
    if grep -q PLANTED-MODULE-RAN "$OUT"; then bad "with the unit's variables the planted ssl.py still ran"; else ok "with the unit's variables the planted ssl.py is not imported"; fi
    out_has "usage: " "...and the real server code ran (--help)"
else
    echo "  skip the planted-module check (no production venv)"
fi

echo
echo "install_server_linux tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo "failed:$FAILED_NAMES"; exit 1; fi
exit 0
