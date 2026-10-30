#!/bin/bash
# Download the Python runtime that goes into the app installer (the dmg), and keep it only when its sha256 is the one in the lock file.
#
#   scripts/fetch_python_runtime.sh --out-dir DIR [options]
#
#   --out-dir DIR      the ONLY place this script writes to (created when missing): DIR/python-runtime.tar.gz. Required.
#   --lock FILE        the lock file with URL and SHA256 (default: scripts/python-runtime.lock next to this script)
#   --from-file FILE   do not download: use a copy you already have (it must have the sha256 of the lock file, the same checks apply)
#   --dry-run          print the plan (address, checksum, target file), connect to nothing, write nothing
#   -h, --help         this text
#
# Exit codes: 0 done (the archive is in DIR and matches the lock), 1 a download or check failed (nothing is kept), 2 refused before anything was
# done: a usage error, or a PENDING value in the lock file (docs/DISTRIBUTE.md section 2 says how to fill it once).
#
# What it checks and refuses:
#   - URL and SHA256 of the lock file must be filled in (not PENDING); the address must be https; the checksum 64 hex digits.
#   - The download uses  curl --proto =https --tlsv1.2 --proto-redir =https  (no plain http, not even through a redirect).
#   - The sha256 of the downloaded file must equal SHA256 of the lock file. A mismatch deletes the download and stops: a runtime whose
#     checksum you did not pin is never put into an installer.
#   - The archive must be a gzip tar that holds python/bin/python3 and no absolute path and no ".." member.
#   - An archive that is already in DIR with the right checksum is kept and nothing is downloaded.
# Nothing else is touched: no installation, no keychain, no other folder (the temporary file lives in DIR and is removed on every exit).
# The tool that connects to the network is /usr/bin/curl; this script is the only one of the project that downloads the runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$SCRIPT_DIR/python-runtime.lock"
OUT_DIR=""
FROM_FILE=""
DRY_RUN=0
ARCHIVE_NAME="python-runtime.tar.gz"
PART=""
LIST=""
DIED=0

log()  { echo "[fetch_python_runtime] $*" >&2; }
die()  { DIED=1; echo "[fetch_python_runtime] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); a leftover temporary file is removed here, and an unexpected failure is reported.
on_exit() {
    local rc=$?
    [ -z "$PART" ] || rm -f "$PART"
    [ -z "$LIST" ] || rm -f "$LIST"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[fetch_python_runtime] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) [ $# -ge 2 ] || die "--out-dir needs a directory" 2; OUT_DIR="$2"; shift ;;
        --lock) [ $# -ge 2 ] || die "--lock needs a file" 2; LOCK="$2"; shift ;;
        --from-file) [ $# -ge 2 ] || die "--from-file needs a file" 2; FROM_FILE="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

[ -n "$OUT_DIR" ] || die "--out-dir DIR is required: it is the only folder this script writes to (try --help)" 2
[ -f "$LOCK" ] || die "lock file not found: $LOCK" 2
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
OUT_DIR="${OUT_DIR%/}"

lock_value() {  # $1 = key: the value of the last KEY=value line of the lock file (blanks at the end removed); empty when missing
    { grep -E "^$1=" "$LOCK" || true; } | tail -n 1 | sed -e "s/^$1=//" -e 's/[[:space:]]*$//'
}
URL="$(lock_value URL)"
SHA256="$(lock_value SHA256 | tr 'A-F' 'a-f')"
TARGET="$(lock_value TARGET)"
FLAVOR="$(lock_value FLAVOR)"

PENDING_KEYS=""
[ "$URL" != "PENDING" ] || PENDING_KEYS="URL"
[ "$SHA256" != "PENDING" ] || PENDING_KEYS="${PENDING_KEYS:+$PENDING_KEYS and }SHA256"
if [ -n "$PENDING_KEYS" ]; then
    die "$LOCK still has $PENDING_KEYS=PENDING. Fill it in once (docs/DISTRIBUTE.md section 2: the address of the python-build-standalone archive and the sha256 that you trust), then run this again. Nothing was downloaded or written." 2
fi
[ -n "$URL" ] || die "$LOCK has no URL line" 2
[ -n "$SHA256" ] || die "$LOCK has no SHA256 line" 2
printf '%s' "$URL" | grep -Eq '^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$' || die "URL in $LOCK must be an https address without blanks (got: $URL)" 2
printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "SHA256 in $LOCK must be 64 hexadecimal digits (got: $SHA256)" 2
[ "$TARGET" = "aarch64-apple-darwin" ] || die "TARGET in $LOCK must be aarch64-apple-darwin (the app needs Apple silicon), got '$TARGET'" 2
[ "$FLAVOR" = "install_only" ] || die "FLAVOR in $LOCK must be install_only (got '$FLAVOR')" 2
if [ -n "$FROM_FILE" ]; then
    [ -f "$FROM_FILE" ] || die "--from-file: not a file: $FROM_FILE" 2
fi

FINAL="$OUT_DIR/$ARCHIVE_NAME"
sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] lock file : $LOCK"
    log "[dry-run] source    : ${FROM_FILE:-$URL}"
    log "[dry-run] sha256    : $SHA256 (the file is kept only when it has this checksum)"
    log "[dry-run] target    : $FINAL (the only file written; a temporary file lives next to it and is removed)"
    if [ -f "$FINAL" ] && [ "$(sha256_of "$FINAL")" = "$SHA256" ]; then
        log "[dry-run] $FINAL is already there with the right checksum: nothing would be downloaded"
    elif [ -z "$FROM_FILE" ]; then
        log "[dry-run] it would run: curl --proto =https --tlsv1.2 --proto-redir =https --fail --location ... $URL"
    fi
    log "dry run: nothing was downloaded or written"
    exit 0
fi

mkdir -p "$OUT_DIR"
if [ -f "$FINAL" ] && [ "$(sha256_of "$FINAL")" = "$SHA256" ]; then
    log "already there with the right checksum, nothing to download: $FINAL"
    echo "$SHA256  $FINAL"
    exit 0
fi

PART="$OUT_DIR/.$ARCHIVE_NAME.part.$$"
LIST="$OUT_DIR/.$ARCHIVE_NAME.list.$$"
if [ -n "$FROM_FILE" ]; then
    log "using $FROM_FILE (no download)"
    cp "$FROM_FILE" "$PART"
else
    command -v curl >/dev/null 2>&1 || die "the 'curl' tool is missing (it ships with macOS)"
    log "downloading $URL"
    curl --proto '=https' --tlsv1.2 --proto-redir '=https' --fail --location --show-error --progress-bar \
        --retry 2 --connect-timeout 20 --max-time 1800 --output "$PART" "$URL" \
        || die "the download failed (see the curl message above). Nothing was kept; check the address in $LOCK and your connection, then run this again."
fi
[ -s "$PART" ] || die "the downloaded file is empty. Nothing was kept."

GOT="$(sha256_of "$PART")"
if [ "$GOT" != "$SHA256" ]; then
    die "sha256 MISMATCH: $LOCK says $SHA256, the file has $GOT. The file was deleted and nothing was kept. Either the address points at another file or the file was tampered with: do not put this runtime into an installer."
fi
log "sha256 verified: $GOT"

tar -tzf "$PART" > "$LIST" 2>/dev/null || die "the file is not a gzip tar archive. Nothing was kept."
if grep -Eq '^/|(^|/)\.\.(/|$)' "$LIST"; then
    die "the archive has an absolute path or a '..' member, which is never accepted. Nothing was kept."
fi
grep -Eq '^(\./)?python/bin/python3$' "$LIST" || die "the archive has no python/bin/python3: this is not an install_only archive of python-build-standalone. Nothing was kept."

mv "$PART" "$FINAL"
PART=""
log "wrote $FINAL ($(wc -c < "$FINAL" | tr -d ' ') bytes)"
echo "$GOT  $FINAL"
