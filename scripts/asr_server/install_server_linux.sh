#!/bin/bash
# Install the mcap-asr/1 server (pipeline/mcap/asr_server.py) with the faster-whisper backend as a systemd service on a Linux host, with an
# NVIDIA GPU (CUDA 12, cuDNN 9) or, slowly, on the CPU (docs/ASR_SERVER_LINUX.md). The macOS twin is install_server.sh.
#
#   scripts/asr_server/install_server_linux.sh [options]
#
#   (no mode option)     PLAN (dry run): prints what it would do and the rendered config and unit, changes nothing, starts nothing.
#   --apply              do it (needs root: run it with sudo yourself; the script never calls sudo): create the service user and group,
#                        the directories with strict modes, the venv with the pinned packages, the config (only when there is none), the
#                        TLS files you name, and the systemd unit. The service is NOT enabled or started: the commands are printed.
#   --start              with --apply: also  systemctl enable  and  restart  the service (do this after the model is in place).
#   --stage-dir DIR      write the file tree that --apply would create under DIR instead of the system (no root, no user, no chown, no venv,
#                        no systemctl): for a rehearsal or a package payload. The unit inside names the REAL target paths.
#   --python PATH        python that creates the venv (3.11 or 3.12; default: python3 on PATH)
#   --project DIR        the checkout or release that holds pipeline/mcap (default: this checkout). With --apply it must be owned by root,
#                        not writable by group or others, and not under /home or /root (the unit hides those): the service user must not
#                        be able to change the code it runs. Copy a release to /opt/mcap-asr/app and name it here.
#   --venv DIR           default /opt/mcap-asr/venv (root-owned: the service user can not change what it imports)
#   --service-user NAME  default mcap-asr (a group of the same name is created). Never root.
#   --config-dir DIR     asr-server.json (root-owned, read-only for the service)     default /etc/mcap-asr
#   --support-dir DIR    tokens, enrollment codes, TLS files, service home with the model cache (0700, owned by the service user)
#                        default /var/lib/mcap-asr
#   --log-dir DIR        content-free metadata log (0700, owned by the service user)  default /var/log/mcap-asr
#   --unit-path PATH     default /etc/systemd/system/mcap-asr.service
#   --listen HOST:PORT   default 127.0.0.1:8443. Loopback (behind your own TLS terminator) or ONE private/VPN address (10.x, 172.16-31.x,
#                        192.168.x, 100.64/10, fc00::/7, fe80::/10); never 0.0.0.0, [::] or a public address. The port is 1024 or higher.
#                        A non-loopback address needs --tls-cert, --tls-key and --allow-from.
#   --tls-cert FILE      PEM certificate chain (the name in it must be the DNS name clients use: they never connect to an IP literal)
#   --tls-key FILE       its private key. Both are copied to <support-dir>/tls.crt and tls.key (key 0600, owned by the service user).
#   --allow-from CIDR    a source network allowed to reach the service (repeatable, or comma separated): the VPN subnet. It must lie
#                        inside a private range. Written into the unit (IPAddressDeny=any plus IPAddressAllow=); loopback is always allowed.
#   --device D           auto (default) | cuda | cpu            backend_options.device in asr-server.json
#   --compute-type T     float16 (default; int8 for --device cpu) | int8_float16 | int8
#   --model NAME         asr-server.json model: a name (large-v3), a Hugging Face repo id or a directory (default: empty = large-v3)
#   --wheelhouse DIR     install the pinned packages from DIR only (pip --no-index --find-links), for a host without internet access
#   -h, --help           this text
#
# Re-running (an upgrade, a changed unit) is safe against the service user: the support, home and log directories and the files in them belong
# to that user, so it could have put a symbolic link where the installer chmods, chowns or writes as root. The script therefore refuses any of
# these paths that is a link, creates every new file exclusively (never through a link, never over a file), uses chown -h, checks for a link
# right before every chmod (GNU chmod has no -h), and refuses an existing support or log directory that is not owned by root or the service
# user, or that is not empty and was not made by this script (a mistaken --support-dir /var/log or --log-dir /var/log must not be chmod 700
# and chowned). "Made by this script" is the marker file .mcap-asr-install, or tokens.json (support) / a meta-*.jsonl file (log) of an
# installation from before the marker existed.
#
# What is NOT done here (the end of the output lists the commands): the NVIDIA driver and the CUDA 12 / cuDNN 9 libraries, the model (fetched
# once, by hand, as the service user: the server never downloads), the certificate, the firewall and the VPN, the first token. Nothing here
# touches a Keychain, contacts the network (except pip, with --apply and without --wheelhouse) or opens a port.
#
# [미검증] never run on a real server and never with a real GPU: the --apply path has been exercised with stubbed useradd, groupadd,
# systemctl, chown and python only (scripts/asr_server/test_install_server_linux.sh). Do the first install by reading the plan (run it without
# options first), then check with: python -m mcap.asr_faster_whisper check --load

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$HERE/../.." && pwd -P)"
SERVICE_NAME="mcap-asr"
SERVICE_USER="mcap-asr"
VENV="/opt/mcap-asr/venv"
CONFIG_DIR="/etc/mcap-asr"
SUPPORT_DIR="/var/lib/mcap-asr"
LOG_DIR="/var/log/mcap-asr"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
TEMPLATE="$HERE/mcap-asr.service.template"
EXAMPLE="$HERE/asr-server.example.json"
PYTHON=""
LISTEN="127.0.0.1:8443"
TLS_CERT=""
TLS_KEY=""
ALLOW_FROM=""        # normalised CIDRs, separated by spaces
DEVICE="auto"
COMPUTE_TYPE=""
MODEL=""
WHEELHOUSE=""
MODE="dry"           # dry | apply | stage
START=0
STAGE=""
TMP_FILES=()
MIN_PYTHON_MINOR=11  # Python 3.11: PYTHONSAFEPATH of the unit, and what the pinned packages were chosen for
MARKER=".mcap-asr-install"          # written into the support and the log directory: 'this directory was made by install_server_linux.sh'

DIED=0
say() { echo "[install_server_linux] $*"; }
die() { DIED=1; echo "[install_server_linux] ERROR: $*" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
on_exit() {
    local rc=$?
    local f
    for f in "${TMP_FILES[@]:-}"; do [ -z "$f" ] || rm -f "$f"; done
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[install_server_linux] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# ---- options ---------------------------------------------------------------------------------------------------------------
need_arg() { [ "$2" -ge 2 ] || die "$1 needs a value" 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) [ "$MODE" != stage ] || die "--apply and --stage-dir exclude each other" 2; MODE=apply ;;
        --start) START=1 ;;
        --stage-dir) need_arg "$1" $#; [ "$MODE" != apply ] || die "--apply and --stage-dir exclude each other" 2; MODE=stage; STAGE="$2"; shift ;;
        --python) need_arg "$1" $#; PYTHON="$2"; shift ;;
        --project) need_arg "$1" $#; PROJECT_DIR="$2"; shift ;;
        --venv) need_arg "$1" $#; VENV="$2"; shift ;;
        --service-user) need_arg "$1" $#; SERVICE_USER="$2"; shift ;;
        --config-dir) need_arg "$1" $#; CONFIG_DIR="$2"; shift ;;
        --support-dir) need_arg "$1" $#; SUPPORT_DIR="$2"; shift ;;
        --log-dir) need_arg "$1" $#; LOG_DIR="$2"; shift ;;
        --unit-path) need_arg "$1" $#; UNIT_PATH="$2"; shift ;;
        --listen) need_arg "$1" $#; LISTEN="$2"; shift ;;
        --tls-cert) need_arg "$1" $#; TLS_CERT="$2"; shift ;;
        --tls-key) need_arg "$1" $#; TLS_KEY="$2"; shift ;;
        --allow-from) need_arg "$1" $#; ALLOW_FROM="$ALLOW_FROM $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
        --device) need_arg "$1" $#; DEVICE="$2"; shift ;;
        --compute-type) need_arg "$1" $#; COMPUTE_TYPE="$2"; shift ;;
        --model) need_arg "$1" $#; MODEL="$2"; shift ;;
        --wheelhouse) need_arg "$1" $#; WHEELHOUSE="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

[ "$START" != 1 ] || [ "$MODE" = apply ] || die "--start needs --apply" 2
case "$SERVICE_USER" in
    [a-z_]*) case "$SERVICE_USER" in *[!a-z0-9_-]*) die "--service-user must be lower-case letters, digits, - and _" 2 ;; esac ;;
    *) die "--service-user must start with a lower-case letter or _" 2 ;;
esac
[ "$SERVICE_USER" != root ] || die "--service-user must not be root: the service runs without privileges" 2
case "$DEVICE" in auto|cuda|cpu) ;; *) die "--device must be auto, cuda or cpu" 2 ;; esac
if [ -z "$COMPUTE_TYPE" ]; then if [ "$DEVICE" = cpu ]; then COMPUTE_TYPE=int8; else COMPUTE_TYPE=float16; fi; fi
case "$COMPUTE_TYPE" in float16|int8_float16|int8) ;; *) die "--compute-type must be float16, int8_float16 or int8" 2 ;; esac
case "$MODEL" in *[[:cntrl:]]*) die "--model must not contain control characters" 2 ;; esac
[ "${#MODEL}" -le 300 ] || die "--model is too long" 2

# Every path goes into a systemd unit (no quoting, no specifiers) and the service sandbox hides /home, /root and /run/user.
check_path() {      # check_path <option> <value> [allow-home]
    case "$2" in
        /*) ;;
        *) die "$1 must be an absolute path (got '$2')" 2 ;;
    esac
    case "$2" in
        *[!A-Za-z0-9._/+-]*) die "$1 may only contain letters, digits and . _ / + - (it goes into a systemd unit; got '$2')" 2 ;;
    esac
    case "$2" in
        */../*|*/..|*/./*|*/.) die "$1 must not contain . or .. components (got '$2')" 2 ;;
    esac
}
hidden_by_unit() { case "$1" in /home|/home/*|/root|/root/*|/run/user|/run/user/*) return 0 ;; esac; return 1; }
for pair in "--project:$PROJECT_DIR" "--venv:$VENV" "--config-dir:$CONFIG_DIR" "--support-dir:$SUPPORT_DIR" "--log-dir:$LOG_DIR" "--unit-path:$UNIT_PATH"; do
    check_path "${pair%%:*}" "${pair#*:}"
done
[ -z "$PYTHON" ] || check_path "--python" "$PYTHON"
[ -z "$WHEELHOUSE" ] || check_path "--wheelhouse" "$WHEELHOUSE"
for pair in "--venv:$VENV" "--config-dir:$CONFIG_DIR" "--support-dir:$SUPPORT_DIR" "--log-dir:$LOG_DIR"; do
    if hidden_by_unit "${pair#*:}"; then die "${pair%%:*} ${pair#*:} is under /home, /root or /run/user, which the service's sandbox hides: use /opt, /etc or /var" 2; fi
done
if [ -n "$STAGE" ]; then case "$STAGE" in /*) ;; *) die "--stage-dir must be an absolute path" 2 ;; esac; fi

[ -f "$TEMPLATE" ] || die "unit template not found: $TEMPLATE"
[ -f "$EXAMPLE" ] || die "example config not found: $EXAMPLE"
REQUIREMENTS="$PROJECT_DIR/pipeline/requirements-server.txt"
SERVICE_GROUP="$SERVICE_USER"
HOME_DIR="$SUPPORT_DIR/home"
CONFIG="$CONFIG_DIR/asr-server.json"

# ---- python (the venv is built from it; the same interpreter checks addresses and renders the config) ---------------------------
if [ -z "$PYTHON" ]; then PYTHON="$(command -v python3 || true)"; fi
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
    die "no python to work with: install python3.11 or 3.12, or name one with --python (checked: ${PYTHON:-python3 on PATH})"
fi
PY_VERSION="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')" || die "cannot run $PYTHON"
PY_MAJOR="${PY_VERSION%%.*}"; PY_MINOR="${PY_VERSION##*.}"
if [ "$PY_MAJOR" != 3 ] || [ "$PY_MINOR" -lt "$MIN_PYTHON_MINOR" ] 2>/dev/null; then
    die "$PYTHON is Python $PY_VERSION: the server needs 3.11 or 3.12 (requirements-server.txt)"
fi

# classify_listen <host:port>: prints "<loopback|private> <host> <port>" or exits non-zero with the reason.
classify_listen() {
    "$PYTHON" - "$1" <<'PYEOF'
import ipaddress, sys
text = sys.argv[1]
host, sep, port_text = text.rpartition(":")
if not sep or not port_text.isascii() or not port_text.isdigit():
    sys.exit("--listen must be HOST:PORT (an IP address and a port)")
port = int(port_text)
if not 1024 <= port <= 65535:
    sys.exit("--listen: the port must be 1024 to 65535 (the service has no capabilities, so no port below 1024)")
host = host[1:-1] if host.startswith("[") and host.endswith("]") else host
if host == "localhost":
    print("loopback", host, port)
    sys.exit(0)
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    sys.exit("--listen: the host must be an IP address (or localhost), not a name")
if getattr(ip, "ipv4_mapped", None):
    ip = ip.ipv4_mapped
if ip.is_unspecified:
    sys.exit("--listen: 0.0.0.0 and :: listen on every interface: name the loopback address or the ONE VPN/private address to bind")
if ip.is_loopback:
    print("loopback", host, port)
    sys.exit(0)
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "fc00::/7", "fe80::/10")]
if any(ip.version == n.version and ip in n for n in PRIVATE):
    print("private", host, port)
    sys.exit(0)
sys.exit("--listen: %s is a public address: bind loopback (behind a TLS terminator) or a VPN/private address, never a public one" % host)
PYEOF
}

# normalise_cidr <cidr>: prints the network, or exits non-zero: only networks inside a private range may reach the service.
normalise_cidr() {
    "$PYTHON" - "$1" <<'PYEOF'
import ipaddress, sys
text = sys.argv[1]
try:
    net = ipaddress.ip_network(text, strict=False)
except ValueError:
    sys.exit("--allow-from: %r is not a network such as 10.8.0.0/24" % text)
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "fc00::/7", "fe80::/10")]
if not any(net.version == p.version and net.subnet_of(p) for p in PRIVATE):
    sys.exit("--allow-from: %s is not inside a private range (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7, fe80::/10): the service must not be reachable from the internet" % net)
print(net)
PYEOF
}

LISTEN_INFO="$(classify_listen "$LISTEN" 2>&1)" || die "$LISTEN_INFO" 2
set -- $LISTEN_INFO
LISTEN_KIND="$1"; LISTEN_HOST="$2"; LISTEN_PORT="$3"
NORMALISED=""
for cidr in $ALLOW_FROM; do
    net="$(normalise_cidr "$cidr" 2>&1)" || die "$net" 2
    case " $NORMALISED " in *" $net "*) ;; *) NORMALISED="$NORMALISED $net" ;; esac
done
ALLOW_FROM="${NORMALISED# }"
if [ -n "$TLS_CERT$TLS_KEY" ]; then
    [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] || die "--tls-cert and --tls-key go together" 2
    for pair in "--tls-cert:$TLS_CERT" "--tls-key:$TLS_KEY"; do
        case "${pair#*:}" in /*) ;; *) die "${pair%%:*} must be an absolute path" 2 ;; esac
        [ -f "${pair#*:}" ] && [ ! -L "${pair#*:}" ] || die "${pair%%:*} is not a regular file: ${pair#*:}" 2
    done
    grep -q 'BEGIN CERTIFICATE' "$TLS_CERT" || die "--tls-cert is not a PEM certificate (no BEGIN CERTIFICATE line): are cert and key swapped?" 2
    grep -q 'PRIVATE KEY' "$TLS_KEY" || die "--tls-key is not a PEM private key (no PRIVATE KEY line): are cert and key swapped?" 2
    if grep -q 'PRIVATE KEY' "$TLS_CERT"; then die "--tls-cert contains a private key: pass the certificate chain only" 2; fi
    if grep -q 'ENCRYPTED' "$TLS_KEY"; then die "--tls-key is encrypted: the service can not ask for a passphrase (decrypt a copy: openssl pkey -in key.pem -out key-plain.pem)" 2; fi
fi
if [ "$LISTEN_KIND" != loopback ]; then
    [ -n "$TLS_CERT" ] || die "$LISTEN is not a loopback address: TLS is required (--tls-cert and --tls-key), the server refuses to start without it" 2
    [ -n "$ALLOW_FROM" ] || die "$LISTEN is not a loopback address: name the VPN subnet that may connect with --allow-from (for example 10.8.0.0/24)" 2
fi

# ---- where files really go: the system, or a staging tree --------------------------------------------------------------------------------
if [ "$MODE" = stage ]; then
    DEST_SUPPORT="$STAGE$SUPPORT_DIR"; DEST_LOG="$STAGE$LOG_DIR"; DEST_CONFIG_DIR="$STAGE$CONFIG_DIR"; DEST_UNIT="$STAGE$UNIT_PATH"
else
    DEST_SUPPORT="$SUPPORT_DIR"; DEST_LOG="$LOG_DIR"; DEST_CONFIG_DIR="$CONFIG_DIR"; DEST_UNIT="$UNIT_PATH"
fi
DEST_HOME="$DEST_SUPPORT/home"
DEST_CONFIG="$DEST_CONFIG_DIR/asr-server.json"

# run <cmd...>: show the command; execute it unless this is a dry run.
run() {
    printf '[install_server_linux]   +'; printf ' %q' "$@"; printf '\n'
    if [ "$MODE" != dry ]; then "$@"; fi
}
# priv <cmd...>: like run, but only on the real system (a staging tree has no users, owners or daemons).
priv() {
    case "$MODE" in
        apply) run "$@" ;;
        stage) printf '[install_server_linux]   - (skipped in --stage-dir mode):'; printf ' %q' "$@"; printf '\n' ;;
        *) run "$@" ;;
    esac
}
step() { echo; say "== $*"; }

# GNU stat first, BSD stat second (the tests run on macOS with a stub that answers both)
file_uid()  { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

render_unit() {
    local line allow
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "@IP_ALLOW_LINES@" ]; then
            printf 'IPAddressAllow=localhost\n'
            for allow in $ALLOW_FROM; do printf 'IPAddressAllow=%s\n' "$allow"; done
        else
            printf '%s\n' "$line"
        fi
    done < "$TEMPLATE" | sed -e "s|@PYTHON@|$(sed_escape "$VENV/bin/python")|g" \
        -e "s|@PROJECT_DIR@|$(sed_escape "$PROJECT_DIR")|g" \
        -e "s|@CONFIG@|$(sed_escape "$CONFIG")|g" \
        -e "s|@SERVICE_USER@|$(sed_escape "$SERVICE_USER")|g" \
        -e "s|@SERVICE_GROUP@|$(sed_escape "$SERVICE_GROUP")|g" \
        -e "s|@HOME_DIR@|$(sed_escape "$HOME_DIR")|g" \
        -e "s|@SUPPORT_DIR@|$(sed_escape "$SUPPORT_DIR")|g" \
        -e "s|@LOG_DIR@|$(sed_escape "$LOG_DIR")|g"
}

render_config() {
    local cert="" key=""
    if [ -n "$TLS_CERT" ]; then cert="$SUPPORT_DIR/tls.crt"; key="$SUPPORT_DIR/tls.key"; fi
    "$PYTHON" - "$EXAMPLE" "$SUPPORT_DIR" "$LOG_DIR" "$LISTEN" "$cert" "$key" "$MODEL" "$DEVICE" "$COMPUTE_TYPE" <<'PYEOF'
import json, sys
src, support, logs, listen, cert, key, model, device, compute_type = sys.argv[1:10]
with open(src, encoding="utf-8") as fh:
    obj = json.load(fh)
obj["secrets_dir"], obj["log_dir"], obj["listen"] = support, logs, listen
obj["tls_cert"], obj["tls_key"] = cert, key
obj["backend"], obj["model"] = "faster-whisper", model
obj["backend_options"] = {"device": device, "compute_type": compute_type}
obj.setdefault("ext", {})["notes"] = (
    "Rendered by scripts/asr_server/install_server_linux.sh. Owned by root and read-only for the service (it cannot change its own limits). "
    "backend faster-whisper: backend_options are device (auto | cuda | cpu), compute_type (float16 | int8_float16 | int8), beam_size (1-10, "
    "default 5), device_index, cpu_threads, num_workers, warmup; an unknown key refuses to start. model empty = large-v3, a CTranslate2 model "
    "that the server never downloads: fetch it once as the service user with python -m mcap.asr_faster_whisper fetch --yes. A non-loopback "
    "listen address needs tls_cert and tls_key (0600, owned by the service user) and is refused without them. Keys must stay in this file's "
    "set: an unknown key refuses to start.")
json.dump(obj, sys.stdout, indent=2, ensure_ascii=False)
print()
PYEOF
}

# check_root_owned <path> <what>: the code the service runs must belong to root and not be writable by anybody else.
check_root_owned() {
    local path="$1" what="$2" owner mode
    [ -e "$path" ] || die "$what does not exist: $path"
    owner="$(file_uid "$path")" || die "cannot read the owner of $what ($path)"
    mode="$(file_mode "$path")" || die "cannot read the mode of $what ($path)"
    [ "$owner" = 0 ] || die "$what ($path) must be owned by root (it is owned by uid $owner): the service user must not be able to change the code it runs"
    [ $((8#$mode & 8#022)) -eq 0 ] || die "$what ($path) must not be writable by group or others (mode $mode)"
}

# no_symlink <path> <what>: root writes into directories that the service user owns, so what is found there may have been put there by it.
no_symlink() {
    if [ -L "$1" ]; then die "$2 ($1) is a symbolic link: refusing to chmod, chown or write through it (remove it, then run again)"; fi
}

# has_entry <dir> <pattern>: true when the directory holds an entry whose name matches the shell pattern (a plain name matches only itself).
has_entry() {
    local entry
    while IFS= read -r entry; do
        case "$entry" in $2) return 0 ;; esac
    done < <(ls -A "$1" 2>/dev/null)
    return 1
}

# check_existing_dir <path> <what> [<an entry name or pattern that proves it is ours>]: a directory that is already there must be a real
# directory (never a link), owned by root or by the service user (a staging tree is owned by whoever stages it), and, when an entry is given,
# empty or made by an earlier run of this script (the marker file, or an entry of that name).
check_existing_dir() {
    local path="$1" what="$2" proof="${3:-}" owner service_uid=""
    no_symlink "$path" "$what"
    [ -e "$path" ] || return 0
    [ -d "$path" ] || die "$what ($path) exists and is not a directory"
    if [ "$MODE" != stage ]; then
        owner="$(file_uid "$path")" || die "cannot read the owner of $what ($path)"
        service_uid="$(id -u "$SERVICE_USER" 2>/dev/null || true)"
        if [ "$owner" != 0 ] && [ "$owner" != "$service_uid" ]; then
            die "$what ($path) is owned by uid $owner: it must belong to root or to $SERVICE_USER (is --support-dir or --log-dir a mistake?)"
        fi
    fi
    if [ -n "$proof" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ] && [ ! -e "$path/$MARKER" ] && ! has_entry "$path" "$proof"; then
        die "$what ($path) is not empty and was not made by this script (no $MARKER, no $proof): refusing to chmod and chown it. Is --support-dir or --log-dir a mistake?"
    fi
}

# make_file <path> <mode> <owner:group or -> [<source file>]: create a NEW file with the content of <source> (default: empty). The shell's
# noclobber makes the open exclusive: it fails when anything is there, a file or a link (a dangling one too), so nothing is written through a
# link. The mode (644 or 600) is set by the umask of that one open, so no chmod can follow a link that was swapped in later; the owner is set
# with chown -h (never through a link) and the mode is read back.
make_file() {
    local path="$1" mode="$2" owner="$3" src="${4:-/dev/null}" um
    printf '[install_server_linux]   + new file %q (mode %s%s)\n' "$path" "$mode" "$([ "$owner" = - ] || printf ', owner %s' "$owner")"
    if [ "$MODE" = dry ]; then return 0; fi
    um="$(printf '%03o' $(( 0777 & ~8#$mode )))"
    ( umask "$um"; set -C; cat "$src" > "$path" ) 2>/dev/null || die "cannot create $path: something is there already (a file or a link)"
    if [ "$owner" != - ]; then priv chown -h "$owner" "$path"; fi
    [ "$(file_mode "$path")" = "$mode" ] || die "$path has mode $(file_mode "$path") instead of $mode"
}

# safe_chmod <mode> <path>: GNU chmod has no -h (it would follow a link), so the link check comes immediately before it.
safe_chmod() {
    no_symlink "$2" "$2"
    run chmod "$1" "$2"
}

# ---- 0. plan header ------------------------------------------------------------------------------------------------------------------
case "$MODE" in
    dry) say "PLAN (dry run): nothing is changed or started. Add --apply (as root) to do it, or --stage-dir DIR to write the tree somewhere else." ;;
    apply) say "APPLY: installing the mcap-asr/1 server (faster-whisper) as $SERVICE_NAME.service (user $SERVICE_USER)" ;;
    stage) say "STAGE: writing the tree under $STAGE (no root, no user, no venv, no systemd)" ;;
esac
say "project $PROJECT_DIR    python $PYTHON ($PY_VERSION)    venv $VENV"
say "config  $CONFIG    support $SUPPORT_DIR    log $LOG_DIR    unit $UNIT_PATH"
say "listen  $LISTEN ($LISTEN_KIND)$([ -n "$TLS_CERT" ] && echo ', TLS' || echo ', plaintext: only behind your own TLS terminator')    allowed sources: localhost${ALLOW_FROM:+ $ALLOW_FROM}"
say "backend faster-whisper: device $DEVICE, compute type $COMPUTE_TYPE, model ${MODEL:-<empty: large-v3>}"

# ---- 1. preconditions ----------------------------------------------------------------------------------------------------------------
step "1. preconditions"
if hidden_by_unit "$PROJECT_DIR"; then
    if [ "$MODE" = dry ]; then
        say "WARNING: --project $PROJECT_DIR is under /home, /root or /run/user, which the service's sandbox hides: copy a release to /opt/mcap-asr/app and pass --project (--apply refuses this)"
    else
        die "--project $PROJECT_DIR is under /home, /root or /run/user, which the service's sandbox hides: copy a release to /opt/mcap-asr/app and pass --project"
    fi
fi
[ -f "$PROJECT_DIR/pipeline/mcap/asr_server.py" ] || die "no pipeline/mcap/asr_server.py under $PROJECT_DIR"
[ -f "$PROJECT_DIR/pipeline/mcap/asr_faster_whisper.py" ] || die "no pipeline/mcap/asr_faster_whisper.py under $PROJECT_DIR"
[ -f "$REQUIREMENTS" ] || die "no pipeline/requirements-server.txt under $PROJECT_DIR"
if [ "$PY_MINOR" -ge 13 ]; then say "WARNING: Python $PY_VERSION: the pinned numpy 1.26.4 has no wheel for 3.13 or later; pip will say so. Use 3.11 or 3.12"; fi
if [ "$MODE" = apply ]; then
    [ "$(id -u)" = 0 ] || die "--apply needs root: run it with sudo (this script never calls sudo itself)"
    [ "$(uname -s)" = Linux ] || die "this installer is for Linux with systemd (this is $(uname -s)); on an Apple silicon Mac use install_server.sh"
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found: this installer needs systemd"
    command -v useradd >/dev/null 2>&1 && command -v groupadd >/dev/null 2>&1 || die "useradd and groupadd are needed to create the service user"
    check_root_owned "$PROJECT_DIR/pipeline" "the pipeline directory"
    check_root_owned "$PROJECT_DIR/pipeline/mcap" "the mcap package"
    say "ok: root-owned code, Linux with systemd, running as root"
else
    say "would check: running as root (id -u), Linux with systemd, useradd and groupadd, root-owned $PROJECT_DIR/pipeline and $PROJECT_DIR/pipeline/mcap"
    if [ "$MODE" = dry ] && [ "$(uname -s)" != Linux ]; then say "WARNING (plan): this machine is $(uname -s): the real run needs Linux with systemd"; fi
fi
if [ "$DEVICE" = cpu ]; then
    say "device cpu: the GPU is not used; decoding runs on the CPU, much slower than real time with a large model"
elif command -v nvidia-smi >/dev/null 2>&1; then
    say "GPU: $(nvidia-smi -L 2>/dev/null | head -n 4 | tr '\n' ';')"
else
    say "WARNING: nvidia-smi not found: without the NVIDIA driver the server runs on the CPU (device auto) or refuses to start (device cuda)"
fi
# What is already there (an upgrade, or a mistaken path): refused BEFORE anything is changed, in a plan too.
check_existing_dir "$DEST_SUPPORT" "the support directory" "tokens.json"
check_existing_dir "$DEST_LOG" "the log directory" "meta-*.jsonl"
check_existing_dir "$DEST_HOME" "the service home"
check_existing_dir "$DEST_CONFIG_DIR" "the config directory"
no_symlink "$DEST_CONFIG" "the config file"
no_symlink "$DEST_UNIT" "the systemd unit"
if [ "$MODE" != stage ]; then no_symlink "$VENV" "the venv directory"; fi
say "ok: the existing support, home, log and config paths, the config and the unit are not links (and the directories are ours or empty)"

# ---- 2. the service user ---------------------------------------------------------------------------------------------------------------
step "2. service user $SERVICE_USER (system account: no login, no password, no shell, not root)"
if [ "$MODE" = apply ] && id "$SERVICE_USER" >/dev/null 2>&1; then
    [ "$(id -u "$SERVICE_USER")" != 0 ] || die "$SERVICE_USER has uid 0: the service must not run as root"
    say "user $SERVICE_USER exists already: left as it is"
elif [ "$MODE" = stage ]; then
    say "(skipped in --stage-dir mode) would create group and user $SERVICE_USER with groupadd and useradd unless they exist"
else
    if [ "$MODE" = apply ] && getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        say "group $SERVICE_GROUP exists already: left as it is"
    else
        run groupadd --system "$SERVICE_GROUP"
    fi
    run useradd --system --gid "$SERVICE_GROUP" --home-dir "$HOME_DIR" --no-create-home --shell /usr/sbin/nologin --comment "MeetingCapture ASR server" "$SERVICE_USER"
fi

# ---- 3. directories (and the TLS files) -------------------------------------------------------------------------------------------------------
step "3. private directories (0700, owned by $SERVICE_USER) and the root-owned config directory"
# Everything is made and set while root still owns it; the support directory is handed over last (it holds the home directory, and once the
# service user owns it the user could swap what is inside for a link).
( umask 022; run mkdir -p "$DEST_CONFIG_DIR" )
safe_chmod 755 "$DEST_CONFIG_DIR"
priv chown -h root:root "$DEST_CONFIG_DIR"
for d in "$DEST_SUPPORT" "$DEST_LOG"; do
    ( umask 022; run mkdir -p "$(dirname "$d")" )         # a missing parent must stay traversable for the service user, only the leaf is private
    ( umask 077; run mkdir -p "$d" )
done
( umask 077; run mkdir -p "$DEST_HOME" )
for d in "$DEST_SUPPORT" "$DEST_LOG"; do
    if [ ! -e "$d/$MARKER" ]; then make_file "$d/$MARKER" 644 root:root; fi
done
if [ -n "$TLS_CERT" ]; then
    if [ "$MODE" != dry ] && [ -e "$DEST_SUPPORT/tls.crt" ]; then say "tls.crt exists: left as it is (a renewal is a copy by hand)"; else make_file "$DEST_SUPPORT/tls.crt" 644 "$SERVICE_USER:$SERVICE_GROUP" "$TLS_CERT"; fi
    if [ "$MODE" != dry ] && [ -e "$DEST_SUPPORT/tls.key" ]; then say "tls.key exists: left as it is"; else make_file "$DEST_SUPPORT/tls.key" 600 "$SERVICE_USER:$SERVICE_GROUP" "$TLS_KEY"; fi
    if [ "$(file_mode "$TLS_KEY")" != 600 ] && [ "$(file_mode "$TLS_KEY")" != 400 ]; then
        say "WARNING: $TLS_KEY is readable by others (mode $(file_mode "$TLS_KEY")): the copy in the support directory is 0600, delete or tighten the original"
    fi
fi
for d in "$DEST_HOME" "$DEST_LOG" "$DEST_SUPPORT"; do
    safe_chmod 700 "$d"
    priv chown -h "$SERVICE_USER:$SERVICE_GROUP" "$d"
done

# ---- 4. the venv ----------------------------------------------------------------------------------------------------------------------
step "4. venv $VENV (root-owned) with the pinned packages of pipeline/requirements-server.txt"
if [ "$MODE" = stage ]; then
    say "(skipped in --stage-dir mode) would create the venv and pip install -r $REQUIREMENTS"
else
    if [ "$MODE" = apply ] && [ -e "$VENV" ]; then check_root_owned "$VENV" "the venv directory"; fi
    ( umask 022; run mkdir -p "$(dirname "$VENV")" )
    if [ "$MODE" = apply ] && [ -x "$VENV/bin/python" ]; then
        say "the venv exists: only the packages are installed again (an upgrade of the pins)"
    else
        ( umask 022; run "$PYTHON" -m venv "$VENV" )
    fi
    if [ -n "$WHEELHOUSE" ]; then
        ( umask 022; run "$VENV/bin/python" -m pip install --disable-pip-version-check --no-input --no-index --find-links "$WHEELHOUSE" -r "$REQUIREMENTS" )
    else
        say "pip contacts the package index now (use --wheelhouse DIR for a host without internet access)"
        ( umask 022; run "$VENV/bin/python" -m pip install --disable-pip-version-check --no-input -r "$REQUIREMENTS" )
    fi
    run "$VENV/bin/python" -m pip check || say "WARNING: pip check found conflicting requirements: read the messages above"
    run chmod -R go-w "$VENV"
fi

# ---- 5. config -------------------------------------------------------------------------------------------------------------------------
step "5. $CONFIG (root-owned and read-only for the service: it cannot change its own limits)"
TMP_CFG="$(mktemp "${TMPDIR:-/tmp}/mcap-asr-config.XXXXXX")"; TMP_FILES+=("$TMP_CFG")
render_config > "$TMP_CFG" || die "cannot render the config"
if [ "$MODE" != dry ] && [ -e "$DEST_CONFIG" ]; then
    say "$CONFIG exists: left as it is (compare with $EXAMPLE and the rendered config of a plan yourself)"
else
    if [ "$MODE" = dry ]; then
        say "would write $CONFIG from $EXAMPLE (root:root 0644). It reads:"
        echo "-----"; cat "$TMP_CFG"; echo "-----"
    else
        make_file "$DEST_CONFIG" 644 root:root "$TMP_CFG"
    fi
fi

# ---- 6. the systemd unit ----------------------------------------------------------------------------------------------------------------
step "6. $UNIT_PATH"
TMP_UNIT="$(mktemp "${TMPDIR:-/tmp}/mcap-asr-unit.XXXXXX")"; TMP_FILES+=("$TMP_UNIT")
render_unit > "$TMP_UNIT"
if grep -Eq '@[A-Z_]+@' "$TMP_UNIT"; then
    die "unreplaced placeholder left in the unit: $(grep -Eo '@[A-Z_]+@' "$TMP_UNIT" | sort -u | tr '\n' ' ')"
fi
for key in User ExecStart ReadWritePaths; do grep -q "^$key=" "$TMP_UNIT" || die "the rendered unit has no $key= line"; done
if [ "$(grep -c '^User=' "$TMP_UNIT")" != 1 ] || grep -q '^User=root$' "$TMP_UNIT"; then die "the rendered unit must run as exactly one non-root user"; fi
say "the rendered unit is complete (a user other than root, no placeholder left)"
if [ "$MODE" = dry ]; then
    say "would write it to $UNIT_PATH (root:root 0644). It reads:"
    echo "-----"
    cat "$TMP_UNIT"
    echo "-----"
else
    ( umask 022; run mkdir -p "$(dirname "$DEST_UNIT")" )
    no_symlink "$DEST_UNIT" "the systemd unit"
    run cp "$TMP_UNIT" "$DEST_UNIT"
    safe_chmod 644 "$DEST_UNIT"
    priv chown -h root:root "$DEST_UNIT"
fi
if [ "$MODE" = apply ]; then
    if command -v systemd-analyze >/dev/null 2>&1; then
        run systemd-analyze verify "$UNIT_PATH" || say "WARNING: systemd-analyze verify complained about the unit: read the messages above"
    fi
    run systemctl daemon-reload
fi

# ---- 7. enable and start -----------------------------------------------------------------------------------------------------------------
step "7. starting"
if [ "$START" = 1 ]; then
    run systemctl enable "$SERVICE_NAME.service"
    run systemctl restart "$SERVICE_NAME.service"
    say "started: watch it with  journalctl -u $SERVICE_NAME -f   (a missing model or CUDA library shows there, and the service retries every 30 s, at most 5 times in 10 minutes)"
else
    say "not started. After the model is in place (next steps, 1):  systemctl enable --now $SERVICE_NAME.service     stop: systemctl stop $SERVICE_NAME.service"
fi

# ---- 8. what is left for you ---------------------------------------------------------------------------------------------------------------
step "8. next steps (by hand)"
PY_AS_SERVICE="sudo -u $SERVICE_USER env HOME='$HOME_DIR' PYTHONPATH='$PROJECT_DIR/pipeline' '$VENV/bin/python'"
FW_MODEL_ARG=""
if [ -n "$MODEL" ]; then FW_MODEL_ARG=" --model '$MODEL'"; fi
FIRST_NET="${ALLOW_FROM%% *}"
cat <<EOS
[install_server_linux]   1. GPU: the NVIDIA driver, CUDA 12 runtime libraries (cuBLAS 12) and cuDNN 9 must be installed, and /dev/nvidia-uvm must exist at boot
[install_server_linux]      (nvidia-persistenced). Nothing here installs them (docs/ASR_SERVER_LINUX.md). Check, as the service user:
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_faster_whisper check$FW_MODEL_ARG --device $DEVICE
[install_server_linux]   2. The model (about 3 GB), once, by hand, with the network allowed for this one command (the service itself stays offline):
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_faster_whisper fetch --yes$FW_MODEL_ARG
[install_server_linux]      then the real test of the GPU stack (starts the model, decodes one second of silence):
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_faster_whisper check --load$FW_MODEL_ARG --device $DEVICE
[install_server_linux]   3. Self-check of the server, as the service user (its build_sha256 line is the value for attest_build_sha256 in the organisation policy):
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_server --config '$CONFIG' selfcheck
[install_server_linux]   4. Enrollment codes (the client exchanges a code for a token; the code never goes into chat):
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_server --config '$CONFIG' enroll-code issue --user NAME
[install_server_linux]   5. Start:  systemctl enable --now $SERVICE_NAME.service       Logs: journalctl -u $SERVICE_NAME      Quarterly and daily audit:
[install_server_linux]        $PY_AS_SERVICE -m mcap.asr_server --config '$CONFIG' audit --home '$HOME_DIR'      ... audit --daily
EOS
if [ "$LISTEN_KIND" = loopback ]; then
    cat <<EOS
[install_server_linux]   6. The service listens on $LISTEN only (loopback). Clients can not reach it until a TLS terminator on this host (nginx, caddy)
[install_server_linux]      forwards a VPN or LAN address to it; the terminator holds the certificate. Never forward it to a public address.
EOS
else
    cat <<EOS
[install_server_linux]   6. Firewall and VPN. The unit already refuses every source except localhost and: $ALLOW_FROM. Add the same rule to the host firewall
[install_server_linux]      (default deny incoming), for example with ufw:
[install_server_linux]        ufw default deny incoming && ufw allow from $FIRST_NET to any port $LISTEN_PORT proto tcp && ufw enable
[install_server_linux]      Never open port $LISTEN_PORT on a public interface or forward it on a router. The address $LISTEN_HOST must exist when the service
[install_server_linux]      starts: if it is a VPN interface, order the unit after it (systemctl edit $SERVICE_NAME, then [Unit] After=wg-quick@wg0.service).
[install_server_linux]      Clients reach the server by a DNS NAME that is in the certificate (never an IP address); the CA that signed it goes into the
[install_server_linux]      organisation policy as org_consents.ca_sha256:  sha256sum ca.pem
EOS
fi
if [ "$MODE" = dry ]; then
    echo
    say "PLAN finished: nothing was changed."
fi
