#!/bin/bash
# Make hash-pinned requirements files for the company runtime (SPEC 18: "--require-hashes --no-deps"), from the version-pinned ones.
#
#   scripts/make_hash_lock.sh [options]
#
# Why: pipeline/requirements.lock.txt pins VERSIONS only, so pip trusts whatever the package index serves under that version (README, "the
# hash check is missing"). The company venv is built from a lock where every package carries the sha256 of the wheels that may be installed:
#
#   numpy==2.5.3 \
#       --hash=sha256:<wheel 1> \
#       --hash=sha256:<wheel 2>
#
# and is installed with  pip install --require-hashes --no-deps -r <file>  (scripts/setup_python.sh --hash-lock <file> does exactly that).
# --require-hashes makes pip refuse any file whose hash is not listed, and --no-deps keeps it from pulling anything that is not in the lock
# (what the lock names is what is installed: nothing else, no torch).
#
# Without --apply this is a PLAN: it lists the inputs, what would be asked of the package index and where the files would go, and fetches
# nothing. --apply needs the network and is run by the administrator on the build host, once per release (the resulting files are reviewed and
# kept with the release; until they exist the PyPI wheels are version-pinned only: SPEC 18, supply chain).
#
# Options:
#   --apply              fetch the hashes and write the files (NETWORK: https://pypi.org/pypi/<name>/<version>/json for every pin, no other host)
#   --input FILE         a version-pinned requirements file (repeatable; default pipeline/requirements.lock.txt and
#                        pipeline/requirements.client.txt). The output is <out-dir>/<name>.hashes.txt for <name>.txt
#   --out-dir DIR        default $MCAP_BUILD_DIR/hash-locks (build/hash-locks)
#   --python-tag TAG     interpreter of the venv, default cp313 (the lock was verified on 3.13); cp312 for a Python 3.12 venv
#   --macos-min N        the oldest macOS the venv must run on; wheels for a newer one are left out (default 14)
#   --index-dir DIR      read <name>-<version>.json (the answer of the index for that pin) from DIR instead of the network: for the script
#                        tests and for a review without network access
#   -h, --help           this text
#
# A pin takes the sha256 of EVERY wheel of that release that this venv could install: pure python wheels, wheels for the python tag (cp313, or
# abi3 up to it), platform macOS arm64 or universal2 at or below --macos-min. A source distribution is never accepted (pip --only-binary), a yanked
# file is skipped, and a pin without any acceptable wheel stops the run with its name: no file is written unless all pins are covered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${MCAP_BUILD_DIR:-$PROJECT_DIR/build}"
PYTHON="${MCAP_PYTHON3:-python3}"
INPUTS=()
OUT_DIR=""
PY_TAG="cp313"
MACOS_MIN="14"
INDEX_DIR=""
APPLY=0
DIED=0

log() { echo "[make_hash_lock] $*"; }
die() { DIED=1; echo "[make_hash_lock] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[make_hash_lock] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --input) [ $# -ge 2 ] || die "--input needs a file" 2; INPUTS+=("$2"); shift ;;
        --out-dir) [ $# -ge 2 ] || die "--out-dir needs a directory" 2; OUT_DIR="$2"; shift ;;
        --python-tag) [ $# -ge 2 ] || die "--python-tag needs a tag like cp313" 2; PY_TAG="$2"; shift ;;
        --macos-min) [ $# -ge 2 ] || die "--macos-min needs a number" 2; MACOS_MIN="$2"; shift ;;
        --index-dir) [ $# -ge 2 ] || die "--index-dir needs a directory" 2; INDEX_DIR="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

printf '%s' "$PY_TAG" | grep -Eq '^cp3[0-9]{1,2}$' || die "--python-tag must look like cp313" 2
printf '%s' "$MACOS_MIN" | grep -Eq '^[0-9]{2}$' || die "--macos-min must be a major version like 14" 2
[ -n "$OUT_DIR" ] || OUT_DIR="$BUILD_DIR/hash-locks"
if [ "${#INPUTS[@]}" -eq 0 ]; then
    INPUTS=("$PROJECT_DIR/pipeline/requirements.lock.txt" "$PROJECT_DIR/pipeline/requirements.client.txt")
fi
for f in "${INPUTS[@]}"; do
    [ -f "$f" ] || die "input not found: $f"
done
[ -z "$INDEX_DIR" ] || [ -d "$INDEX_DIR" ] || die "--index-dir is not a directory: $INDEX_DIR"
command -v "$PYTHON" >/dev/null 2>&1 || die "$PYTHON not found (python 3.9 or newer; MCAP_PYTHON3 names another)"

out_of() {  # $1 = input file -> output path
    local base
    base="$(basename "$1")"
    echo "$OUT_DIR/${base%.txt}.hashes.txt"
}

count_pins() {  # the NAME==VERSION lines of a requirements file
    { grep -E '^[[:space:]]*[A-Za-z0-9._-]+==' "$1" || true; } | grep -vc '^[[:space:]]*#' || true
}

if [ "$APPLY" != 1 ]; then
    log "PLAN (nothing is fetched, nothing is written). Add --apply to do it."
    for f in "${INPUTS[@]}"; do
        log "  input   : $f ($(count_pins "$f") pins) -> $(out_of "$f")"
    done
    if [ -n "$INDEX_DIR" ]; then
        log "  source  : the files <name>-<version>.json in $INDEX_DIR (no network)"
    else
        log "  source  : https://pypi.org/pypi/<name>/<version>/json for every pin, over https, no other host (NETWORK: run --apply on the build host)"
    fi
    log "  accepts : wheels only (a source distribution is never installed: --only-binary), python tag $PY_TAG, macOS arm64 or universal2 up to $MACOS_MIN, yanked files skipped"
    log "  output  : one 'name==version \\' block per pin with a --hash=sha256:<hex> line for every acceptable wheel; no file is written unless every pin is covered"
    log "  install : pip install --require-hashes --no-deps -r <output file>      (scripts/setup_python.sh --hash-lock <output file> does this)"
    log "            --require-hashes: pip refuses any file whose hash is not listed;  --no-deps: nothing outside the lock is pulled in"
    log "PLAN finished: nothing was changed."
    exit 0
fi

[ -n "$INDEX_DIR" ] || log "NETWORK: asking https://pypi.org for the files of every pin (no other host is contacted)"
mkdir -p "$OUT_DIR"
for f in "${INPUTS[@]}"; do
    out="$(out_of "$f")"
    MCAP_HL_INDEX_DIR="$INDEX_DIR" "$PYTHON" -I - "$f" "$out" "$PY_TAG" "$MACOS_MIN" <<'PYEOF' || die "no hash lock was written for $f"
import json, os, re, sys, urllib.error, urllib.request
from datetime import datetime, timezone

src, out, py_tag, macos_min = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
index_dir = os.environ.get("MCAP_HL_INDEX_DIR", "")
target = int(py_tag[2:])                                   # cp313 -> 313
PIN = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9._+!-]+)\s*(?:#.*)?$")
WHEEL = re.compile(r"^(?P<dist>[^-]+)-(?P<ver>[^-]+)(?:-(?P<build>\d[^-]*))?-(?P<py>[^-]+)-(?P<abi>[^-]+)-(?P<plat>[^-]+)\.whl$")
HOST = "pypi.org"


def pins(path):
    found = []
    for raw in open(path, encoding="utf-8"):
        m = PIN.match(raw.rstrip("\\ \n"))
        if m and not raw.lstrip().startswith(("#", "-")):
            found.append((m.group(1), m.group(2)))
    return found


class SameHostOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://%s/" % HOST):
            raise urllib.error.URLError("redirect to another host refused: %s" % newurl.split("/")[2])
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(name, version):
    if index_dir:
        path = os.path.join(index_dir, "%s-%s.json" % (name, version))
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    url = "https://%s/pypi/%s/%s/json" % (HOST, name, version)
    opener = urllib.request.build_opener(SameHostOnly)
    with opener.open(urllib.request.Request(url, headers={"User-Agent": "meeting-capture-make-hash-lock"}), timeout=30) as resp:
        return json.load(resp)


def python_ok(tags):
    """True when one of the (dot-separated) python tags fits the target interpreter: py3, py3N (N up to the target), cp3NN up to it."""
    for tag in tags.split("."):
        if tag == "py3":
            return True
        m = re.fullmatch(r"py(3\d{1,2})", tag)
        if m and int(m.group(1)) <= target:
            return True
        m = re.fullmatch(r"cp(3\d{1,2})", tag)
        if m and int(m.group(1)) <= target:
            return True
    return False


def platform_ok(plat):
    for tag in plat.split("."):
        if tag == "any":
            return True
        m = re.fullmatch(r"macosx_(\d+)_(\d+)_(arm64|universal2)", tag)
        if m and (int(m.group(1)), int(m.group(2))) <= (macos_min, 0):
            return True
    return False


def acceptable(filename):
    m = WHEEL.match(filename)
    if not m:
        return False
    py, abi, plat = m.group("py"), m.group("abi"), m.group("plat")
    if not platform_ok(plat):
        return False
    if abi == "none":
        return python_ok(py)                                # pure python (py3-none-any)
    if abi == "abi3":
        return python_ok(py)                                # stable ABI wheel built for this python or an older one
    return abi == py_tag and py_tag in py.split(".")        # a wheel for exactly this interpreter


lines = ["# Hash lock of %s: made by scripts/make_hash_lock.sh on %s (python tag %s, macOS arm64 or universal2 up to %d)." % (
             os.path.basename(src), datetime.now(timezone.utc).strftime("%Y-%m-%d"), py_tag, macos_min),
         "# Install with:  pip install --require-hashes --no-deps -r %s" % os.path.basename(out),
         "# Every line names the sha256 of the wheels pip may install for that pin; pip refuses everything else. Regenerate it for every release."]
missing = []
for name, version in pins(src):
    try:
        data = fetch(name, version)
    except (OSError, ValueError) as exc:
        missing.append("%s==%s: the index answer could not be read (%s)" % (name, version, type(exc).__name__))
        continue
    hashes = set()
    for item in data.get("urls", []):
        digest = str(item.get("digests", {}).get("sha256", "")).lower()
        if item.get("yanked") or item.get("packagetype") != "bdist_wheel" or not re.fullmatch(r"[0-9a-f]{64}", digest):
            continue
        if acceptable(str(item.get("filename", ""))):
            hashes.add(digest)
    if not hashes:
        missing.append("%s==%s: no wheel this venv could install (a source distribution is never accepted)" % (name, version))
        continue
    lines.append("%s==%s \\" % (name, version))
    ordered = sorted(hashes)
    for i, digest in enumerate(ordered):
        lines.append("    --hash=sha256:%s%s" % (digest, " \\" if i + 1 < len(ordered) else ""))
if missing:
    print("\n".join("[make_hash_lock] " + text for text in missing), file=sys.stderr)
    sys.exit(1)
tmp = out + ".part"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(tmp, out)
print("[make_hash_lock] wrote %s (%d pins)" % (out, len(pins(src))))
PYEOF
done
log "done. Review the files, keep them with the release, and build the venv with  scripts/setup_python.sh --client-only --hash-lock <file>"
