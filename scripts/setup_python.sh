#!/bin/bash
# Create (or update) the Python venv used by the post-processing pipeline `mcap`.
#
#   scripts/setup_python.sh [options]
#
#   --with-silero         also install onnxruntime (+2 small deps) and put the Silero VAD model at
#                         SUPPORT_DIR/models/silero_vad.onnx (sha256 verified). ASR_VAD=auto then uses it.
#   --silero-file PATH    use a local copy of silero_vad.onnx instead of downloading it (sha256 is verified)
#   --with-qwen-bench     ALSO build a SEPARATE bench venv, SUPPORT_DIR/bench-venv, with the lock + (Silero if asked) +
#                         mlx-qwen3-asr (pinned; BENCHMARK ONLY). The production venv never gets mlx-qwen3-asr.
#   --bench-only          do not touch the production venv at all: only the bench venv (used by the bench kit on another
#                         Mac, see docs/BENCH_KIT.md). mlx-qwen3-asr is added to it only with --with-qwen-bench.
#   --pre-download-model  download the default ASR model now (whisper-large-v3 MLX fp16, pinned revision, 3.08 GB)
#   --download LIST       comma list of models to download now: whisper-large-v3, whisper-large-v3-turbo,
#                         qwen3-asr-1.7b   (exact sizes are printed first)
#   --python PATH         interpreter used to create the venvs (default: python3.13, then python3.12, looked up in /opt/homebrew/bin, the python.org
#                         framework, /usr/local/bin and on PATH; the pinned numpy and scipy need Python 3.12 or newer)
#                         Through `make install ARGS="--python"` the word --python is install.sh's own switch and takes no path: set the
#                         environment variable MCAP_PYTHON instead (MCAP_PYTHON=/path/to/python3.13 make install ARGS="--python")
#   --client-only         the CLIENT-ONLY production venv of the company install (remote ASR, no local speech model): pipeline/requirements.client.txt
#                         (numpy and truststore, the versions of the lock) instead of the lock. No model is downloaded, no benchmark venv is made.
#                         NOT verified on 8 GB Macs. A Mac with this venv cannot transcribe locally: pair it with a policy that allows
#                         the remote engine.
#   --with-cloud          the cloud engines (Azure) trust the operating system's certificate store through the package truststore: make sure it is in
#                         the venv (it already is in the lock and in --client-only) and import it after the install. Nothing else is added.
#   --hash-lock FILE      install the packages from FILE with  pip install --require-hashes --no-deps -r FILE  (every wheel's sha256 is checked;
#                         scripts/make_hash_lock.sh makes the file). The pins in FILE must be exactly those of the requirement file this run uses.
#                         The Silero runtime and the bench venv stay version-pinned only.
#   --check-hash-lock REQ LOCK   only compare: exit 0 when the hash lock LOCK lists exactly the pins of the requirement file REQ and has --hash=sha256: lines,
#                         else print the differences and exit 1. Installs nothing and needs no Apple silicon Mac. scripts/build_dmg.sh runs it at build
#                         time, so a lock that every Mac that installs the image would refuse (step 3 of the first-run helper) never ships.
#   --venv-dir DIR        build the production venv in DIR (a folder named venv; default SUPPORT_DIR/venv): for a company release, DIR is
#                         <release staging>/<version>/venv (docs/DEPLOY.md)
#   --copies              create the venv with  python -m venv --copies  (no symbolic link to the base python). A company venv needs it, and a base
#                         python that root owns (the python.org framework): the release check refuses a venv built on Homebrew's user-owned python
#   --recreate            delete the venv(s) this run is about first and build them again
#   --dry-run             print the plan with exact download sizes and every action; change nothing
#   -h, --help            this text
#
# Production venv (SUPPORT_DIR/venv) = the pinned lock file + optionally the Silero runtime. Nothing else.
# Idempotent: an existing venv whose packages already match the pins is left alone, an existing Silero model or
# model snapshot with the right size/checksum is not downloaded again. Nothing is downloaded unless it is listed
# in the plan printed at the start (with exact byte sizes). Packages are installed with `pip install --no-deps` from
# the lock file, NEVER with a plain `pip install mlx-whisper` (that pulls torch, +550 MB, not needed at runtime).
#
# Environment overrides (tests and the bench kit): MCAP_SUPPORT_DIR (default ~/Library/Application Support/MeetingCapture),
# MCAP_PYTHON (same as --python), HF_HOME (Hugging Face cache; the production pipeline uses the default
# ~/.cache/huggingface, so do not set it for a real install).
#
# The script only defines functions when it is sourced (used by the verification), and runs main when executed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_DIR="$PROJECT_DIR/pipeline"
SUPPORT_DIR="${MCAP_SUPPORT_DIR:-$HOME/Library/Application Support/MeetingCapture}"
VENV_DIR="$SUPPORT_DIR/venv"
VENV_PY="$VENV_DIR/bin/python"
BENCH_VENV_DIR="$SUPPORT_DIR/bench-venv"
BENCH_VENV_PY="$BENCH_VENV_DIR/bin/python"
MODELS_DIR="$SUPPORT_DIR/models"
LOCK_FILE="$PIPELINE_DIR/requirements.lock.txt"
SILERO_REQ="$PIPELINE_DIR/requirements-silero.txt"
QWEN_REQ="$PIPELINE_DIR/requirements-qwen-bench.txt"
CLIENT_REQ="$PIPELINE_DIR/requirements.client.txt"

# ---- pinned sources (all verified 2026-10-07) ------------------------------------
# Silero VAD v6.2.3 (MIT, github.com/snakers4/silero-vad). The same file ships inside the PyPI wheel silero-vad 6.2.3.
SILERO_ONNX_BYTES=2327524
SILERO_ONNX_SHA256="1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
SILERO_URL="https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.3/src/silero_vad/data/silero_vad.onnx"
SILERO_WHEEL_BYTES=11317527
SILERO_WHEEL_SHA256="7b7f5436cfcb02fae583a05b512ea96467fd449fe54cb49a5e4f06c51a1e43b8"
SILERO_WHEEL_URL="https://files.pythonhosted.org/packages/84/ef/9099037ed6f180ea33220178df4107112c0ce2bf5fb4d6f6ab19db2844ed/silero_vad-6.2.3-py3-none-any.whl"
SILERO_WHEEL_MEMBER="silero_vad/data/silero_vad.onnx"
ONNXRUNTIME_APPROX_MB=22
PACKAGES_APPROX_MB=550            # venv size on disk for the lock file (measured 547 MB on Python 3.13, no torch)

DRY_RUN=0
WITH_SILERO=0
WITH_QWEN=0
BENCH_ONLY=0
RECREATE=0
CLIENT_ONLY=0
WITH_CLOUD=0
VENV_COPIES=0
HASH_LOCK=""
CHECK_REQ=""
CHECK_LOCK=""
VENV_DIR_OPT=""
DIED=0
MODEL_PY="$VENV_PY"        # the python that downloads models / checks Silero (production venv, or the bench venv with --bench-only)
SILERO_FILE=""
PYTHON_OVERRIDE="${MCAP_PYTHON:-}"
DOWNLOADS=""
WORK_DIR=""

log()  { echo "[setup_python] $*"; }
warn() { echo "[setup_python] WARNING: $*" >&2; }
die()  { DIED=1; echo "[setup_python] ERROR: $*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# Run a command, or only print it with --dry-run.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

commas() { echo "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }
gb()     { awk -v n="$1" 'BEGIN { printf "%.2f GB", n / 1e9 }'; }
mb()     { awk -v n="$1" 'BEGIN { printf "%.2f MB", n / 1e6 }'; }
sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
file_bytes() { stat -Lf %z "$1"; }

cleanup() { [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"; return 0; }
# No ERR trap (set -E + trap ERR runs inside $(...) on bash 3.2 and printed a bogus "FAILED" for harmless lookups).
on_exit() {
    local rc=$?
    cleanup
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[setup_python] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
make_work_dir() {
    [ -n "$WORK_DIR" ] || WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcap-setup.XXXXXX")"
}

# ---- model table ---------------------------------------------------------------------------------------------
# Sets M_REPO M_REV M_BYTES (all files of the snapshot) M_FILE M_FILE_BYTES M_FILE_SHA (the weights file that is
# size/sha256 checked afterwards) M_MAIN_REF, and M_ALLOW / M_IGNORE (comma lists for snapshot_download, empty here).
#
# The WHOLE repo snapshot is downloaded, not only config.json + weights.*: with huggingface_hub 2.1.1 a snapshot made
# with allow_patterns counts as "incomplete" for a later snapshot_download(local_files_only=True) WITHOUT the same
# patterns, which is how pipeline/mcap/asr_engines.py looks the model up (IncompleteSnapshotError, verified 2026-10-07).
# The extra files (README.md, .gitattributes, ...) are a few KB.
model_lookup() {
    M_ALLOW=""
    M_IGNORE=""
    M_MAIN_REF=1       # 1 = also make `main` resolve to the pinned revision (see ensure_main_ref)
    case "$1" in
        whisper-large-v3)
            M_REPO="mlx-community/whisper-large-v3-mlx"
            M_REV="49e6aa286ad60c14352c404340ded53710378a11"
            M_MAIN_REF=0                       # pipeline/mcap/asr_engines.py pins this revision itself
            M_BYTES=3083522487                 # weights.npz 3,083,520,416 + config.json 269 + README.md 283 + .gitattributes 1,519
            M_FILE="weights.npz"; M_FILE_BYTES=3083520416
            M_FILE_SHA="05ff791ce3630fae47e7c51004e9666204d786246ec07cac6110af768099b40d" ;;
        whisper-large-v3-turbo)
            M_REPO="mlx-community/whisper-large-v3-turbo"
            M_REV="a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
            M_BYTES=1613979758                 # weights.safetensors 1,613,977,612 + config.json 268 + README.md 359 + .gitattributes 1,519
            M_FILE="weights.safetensors"; M_FILE_BYTES=1613977612
            M_FILE_SHA="951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6" ;;
        qwen3-asr-1.7b)
            M_REPO="mlx-community/Qwen3-ASR-1.7B-bf16"
            M_REV="e1f6c266914abc5a46e8756e02580f834a6cf8a7"
            M_BYTES=4080710353                 # 11 files, model.safetensors 4,076,186,653
            M_FILE="model.safetensors"; M_FILE_BYTES=4076186653
            M_FILE_SHA="2f080a3b769ae469aeaaa2dcb9e13a94141e54c9e6d5a7aa63392e0dc5a51789" ;;
        *) return 1 ;;
    esac
    return 0
}

add_download() {
    model_lookup "$1" || die "unknown model '$1' (known: whisper-large-v3, whisper-large-v3-turbo, qwen3-asr-1.7b)"
    case " $DOWNLOADS " in
        *" $1 "*) ;;
        *) DOWNLOADS="$DOWNLOADS $1" ;;
    esac
}

# ---- python / venv -----------------------------------------------------------------------------------------
pick_python() {
    local cand v dir
    if [ -n "$PYTHON_OVERRIDE" ]; then
        [ -x "$PYTHON_OVERRIDE" ] || die "the interpreter '$PYTHON_OVERRIDE' (from --python or MCAP_PYTHON) is not an executable file"
        echo "$PYTHON_OVERRIDE"
        return 0
    fi
    for v in 3.13 3.12; do   # the pinned numpy and scipy need 3.12 or newer
        for dir in /opt/homebrew/bin "/Library/Frameworks/Python.framework/Versions/$v/bin" /usr/local/bin; do
            cand="$dir/python$v"
            if [ -x "$cand" ]; then
                echo "$cand"
                return 0
            fi
        done
        cand="$(command -v "python$v" || true)"
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

python_version() { "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'; }

check_python_version() {  # $1 = interpreter; dies when older than 3.12 (numpy 2.5.3 and scipy 1.18.1 need it), warns when not 3.13
    local v
    v="$(python_version "$1")" || die "cannot run $1"
    "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' || die "$1 is Python $v, need 3.12 or newer (the pinned numpy and scipy do not install on older versions)"
    case "$v" in
        3.13.*) ;;
        *) warn "the lock file was verified on Python 3.13.2; Python $v is the fallback. If pip fails to find wheels, install python@3.13 with Homebrew yourself." ;;
    esac
}

# Prints the pins of the given requirement files that are NOT installed in the venv (nothing printed = all there).
pins_missing() {  # $1 = venv python, rest = requirement files
    local py="$1"
    shift
    "$py" - "$@" <<'PY'
import sys
from importlib import metadata

bad = []
for path in sys.argv[1:]:
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip().rstrip("\\").strip()      # a hash lock ends its pin lines with a backslash
        if not line or line.startswith("-") or "==" not in line:
            continue
        name, _, want = line.partition("==")
        name, want = name.strip(), want.strip()
        try:
            have = metadata.version(name)
        except metadata.PackageNotFoundError:
            have = None
        if have != want:
            bad.append("%s (want %s, have %s)" % (name, want, have))
if bad:
    print("\n".join(bad))
PY
}

ensure_venv() {  # $1 = interpreter used for creation, $2 = venv directory (SUPPORT_DIR/venv or SUPPORT_DIR/bench-venv)
    local dir="$2" vpy="$2/bin/python"
    if [ "$RECREATE" = 1 ] && [ -e "$dir" ]; then
        case "$dir" in
            */venv|*/bench-venv) ;;
            *) die "refusing to delete '$dir' (does not end in /venv or /bench-venv)" ;;
        esac
        log "removing existing venv $dir"
        run rm -rf "$dir"
    fi
    if [ -x "$vpy" ] && [ "$RECREATE" != 1 ]; then
        "$vpy" -c 'pass' 2>/dev/null || die "the venv at $dir is broken (its Python is gone). Re-run with --recreate"
        log "venv exists: $dir (Python $(python_version "$vpy"))"
        return 0
    fi
    log "creating venv $dir with $1$([ "$VENV_COPIES" = 1 ] && echo ' (--copies)')"
    run mkdir -p "$(dirname "$dir")"
    if [ "$VENV_COPIES" = 1 ]; then
        run "$1" -m venv --copies "$dir"
    else
        run "$1" -m venv "$dir"
    fi
}

# A hash lock must list exactly the pins of the requirement file this run uses: a lock made for another flavour would silently install the wrong set.
check_hash_lock() {  # $1 = version-pinned requirement file, $2 = hash lock; prints the differences
    "${PYTHON_OVERRIDE:-python3}" - "$1" "$2" <<'PY'
import re, sys

def pins(path):
    found = {}
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip().rstrip("\\").strip()
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9._+!-]+)$", line)
        if m:
            found[m.group(1).lower().replace("_", "-")] = m.group(2)
    return found

want, have = pins(sys.argv[1]), pins(sys.argv[2])
problems = ["%s==%s is not in the hash lock" % (n, v) for n, v in sorted(want.items()) if n not in have]
problems += ["%s: the hash lock has %s, the requirement file %s" % (n, have[n], want[n]) for n in sorted(want) if n in have and have[n] != want[n]]
problems += ["%s==%s is in the hash lock but not in the requirement file" % (n, v) for n, v in sorted(have.items()) if n not in want]
if "--hash=sha256:" not in open(sys.argv[2], encoding="utf-8").read():
    problems.append("the file has no --hash=sha256: line: it is not a hash lock (scripts/make_hash_lock.sh makes one)")
if problems:
    print("\n".join("  " + p for p in problems))
    sys.exit(1)
PY
}

install_pins() {  # $1 = requirement file, $2 = label, $3 = venv directory; with --hash-lock the main packages come from the hash lock
    local missing vpy="$3/bin/python" req="$1" hashed=0
    [ -f "$1" ] || die "requirement file not found: $1"
    if [ -n "$HASH_LOCK" ] && [ "$2" = "packages" ]; then
        [ -f "$HASH_LOCK" ] || die "--hash-lock: not a file: $HASH_LOCK"
        check_hash_lock "$1" "$HASH_LOCK" || die "--hash-lock $HASH_LOCK does not match $1 (see above)"
        req="$HASH_LOCK"
        hashed=1
    fi
    if [ -x "$vpy" ] && [ "$RECREATE" != 1 ]; then
        missing="$(pins_missing "$vpy" "$req")"
        if [ -z "$missing" ]; then
            log "$2: all pinned packages are already installed"
            return 0
        fi
        log "$2: will install/upgrade:"
        echo "$missing" | sed 's/^/        /'
    else
        log "$2: installing into the new venv"
    fi
    if [ "$hashed" = 1 ]; then
        PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 run "$vpy" -m pip install --require-hashes --no-deps -r "$req"
    else
        PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 run "$vpy" -m pip install --no-deps -r "$req"
    fi
}

verify_imports() {  # $1 = venv directory, $2 = "qwen" to check mlx_qwen3_asr as well; first import of mlx_whisper takes ~25 s
    local vpy="$1/bin/python"
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would verify in $1: import mlx_whisper${2:+ and mlx_qwen3_asr} (about 25 s on the first import, it warms the numba cache)"
        return 0
    fi
    log "verifying $1 (the first import of mlx_whisper takes about 25 s, it warms the numba cache) ..."
    HF_HUB_DISABLE_TELEMETRY=1 "$vpy" -c '
import importlib.metadata as md, sys, numpy, mlx.core, mlx_whisper
print("  mlx %s, mlx-whisper %s, numpy %s: import OK" % (md.version("mlx"), md.version("mlx-whisper"), numpy.__version__))
if len(sys.argv) > 1 and sys.argv[1] == "qwen":
    import mlx_qwen3_asr  # noqa: F401
    print("  mlx-qwen3-asr %s: import OK" % md.version("mlx-qwen3-asr"))
try:
    import torch  # noqa: F401
    print("  note: torch is installed in this venv (not needed; it was not installed by this script)")
except ImportError:
    print("  torch: absent (as intended)")
' ${2:+"$2"} || die "import check failed; try: scripts/setup_python.sh --recreate"
}

verify_client_imports() {  # $1 = venv directory: the client-only venv has numpy and truststore, nothing that needs a local model
    local vpy="$1/bin/python"
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would verify in $1: import numpy and truststore"
        return 0
    fi
    log "verifying $1 ..."
    "$vpy" -c '
import importlib.metadata as md, numpy, truststore
print("  numpy %s, truststore %s: import OK" % (numpy.__version__, md.version("truststore")))
' || die "import check failed; try: scripts/setup_python.sh --client-only --recreate"
}

verify_cloud_trust() {  # $1 = venv directory: --with-cloud, the OS trust store module that the cloud engines use
    local vpy="$1/bin/python"
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would verify in $1: import truststore (the certificate store the cloud engines use)"
        return 0
    fi
    "$vpy" -c 'import truststore; truststore.SSLContext' || die "--with-cloud: truststore cannot be imported in $1"
    log "cloud: truststore imports (the cloud engines trust the operating system's certificate store; the company relay does not need it: it has a pinned private CA)"
}

# A client-only requirement file must name the same versions as the lock (one source of truth for what a version is).
check_client_pins() {
    "${PYTHON_OVERRIDE:-python3}" - "$CLIENT_REQ" "$LOCK_FILE" <<'PY'
import re, sys

def pins(path):
    found = {}
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9._+!-]+)$", line)
        if m:
            found[m.group(1).lower().replace("_", "-")] = m.group(2)
    return found

client, lock = pins(sys.argv[1]), pins(sys.argv[2])
bad = ["%s==%s, but the lock has %s" % (n, v, lock.get(n, "no such pin")) for n, v in sorted(client.items()) if lock.get(n) != v]
if bad or not client:
    print("\n".join("  " + b for b in bad) or "  no pins found")
    sys.exit(1)
PY
}

# The production venv must not carry the benchmark-only Qwen package (older versions of this script installed it there).
warn_qwen_in_production() {
    [ -x "$VENV_PY" ] || return 0
    if "$VENV_PY" -c 'import importlib.metadata as m; m.version("mlx-qwen3-asr")' >/dev/null 2>&1; then
        warn "mlx-qwen3-asr is installed in the PRODUCTION venv $VENV_DIR (an older version of this script put it there). It is harmless but not wanted there; the benchmark venv is $BENCH_VENV_DIR. To clean up: scripts/setup_python.sh --recreate"
    fi
    return 0
}

# ---- Silero VAD model ----------------------------------------------------------------------------------------
silero_target() { echo "$MODELS_DIR/silero_vad.onnx"; }

silero_ok() {  # $1 = file; exit 0 when it has the pinned size and sha256
    [ -f "$1" ] || return 1
    [ "$(file_bytes "$1")" = "$SILERO_ONNX_BYTES" ] || return 1
    [ "$(sha256_of "$1")" = "$SILERO_ONNX_SHA256" ]
}

download() {  # $1 = url, $2 = output file
    curl -fSL --retry 2 --connect-timeout 15 --max-time 300 --progress-bar -o "$2" "$1"
}

# Extracts the onnx member from the PyPI wheel (a zip). Uses the python given as $3 (venv or system).
extract_from_wheel() {  # $1 = wheel, $2 = output file, $3 = python
    "$3" - "$1" "$SILERO_WHEEL_MEMBER" "$2" <<'PY'
import sys, zipfile
wheel, member, out = sys.argv[1:4]
with zipfile.ZipFile(wheel) as z, open(out, "wb") as f:
    f.write(z.read(member))
PY
}

fetch_silero_model() {  # installs the verified model at $(silero_target); needs a python for the wheel fallback
    local target tmp py
    target="$(silero_target)"
    py="${1:-python3}"
    if silero_ok "$target"; then
        log "silero: model already present and verified: $target"
        return 0
    fi
    make_work_dir
    tmp="$WORK_DIR/silero_vad.onnx"
    if [ -n "$SILERO_FILE" ]; then
        [ -f "$SILERO_FILE" ] || die "--silero-file: not a file: $SILERO_FILE"
        cp "$SILERO_FILE" "$tmp"
        silero_ok "$tmp" || die "$SILERO_FILE is not the expected silero_vad.onnx (want $SILERO_ONNX_BYTES bytes, sha256 $SILERO_ONNX_SHA256)"
    else
        log "silero: downloading $(commas "$SILERO_ONNX_BYTES") bytes from $SILERO_URL"
        if ! { download "$SILERO_URL" "$tmp" && silero_ok "$tmp"; }; then
            warn "direct download failed or did not match the checksum; trying the PyPI wheel ($(commas "$SILERO_WHEEL_BYTES") bytes)"
            download "$SILERO_WHEEL_URL" "$WORK_DIR/silero.whl"
            [ "$(sha256_of "$WORK_DIR/silero.whl")" = "$SILERO_WHEEL_SHA256" ] || die "silero wheel checksum mismatch (want $SILERO_WHEEL_SHA256)"
            extract_from_wheel "$WORK_DIR/silero.whl" "$tmp" "$py"
            silero_ok "$tmp" || die "model extracted from the wheel does not match the pinned sha256"
        fi
    fi
    mkdir -p "$MODELS_DIR"
    cp "$tmp" "$target.part"
    mv "$target.part" "$target"      # atomic: a half-copied model is never visible under the final name
    log "silero: installed $target (sha256 verified)"
}

check_silero_runs() {  # $1 = venv python: load the model with onnxruntime and run one 32 ms window
    ORT_DISABLE_TELEMETRY=1 "$1" - "$(silero_target)" <<'PY'
import sys
import numpy as np
import onnxruntime as ort

try:
    ort.disable_telemetry_events()       # SPEC 14.4: before any session is created
except Exception:
    pass
o = ort.SessionOptions()
o.log_severity_level = 4
sess = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"], sess_options=o)
x = np.zeros((1, 576), np.float32)           # 64 samples of context + one 512-sample window
state = np.zeros((2, 1, 128), np.float32)
p, _ = sess.run(None, {"input": x, "state": state, "sr": np.array(16000, np.int64)})
assert 0.0 <= float(p[0, 0]) <= 1.0
print("  silero: onnxruntime %s loads the model, silence probability %.3f" % (ort.__version__, float(p[0, 0])))
PY
}

# ---- model snapshots ------------------------------------------------------------------------------------------
# Prints the local snapshot directory. Progress bars go to stderr.
snapshot() {  # $1 = python, $2 = repo, $3 = revision, $4 = allow (comma), $5 = ignore (comma), $6 = local_files_only (0/1)
    MCAP_DL_REPO="$2" MCAP_DL_REV="$3" MCAP_DL_ALLOW="$4" MCAP_DL_IGNORE="$5" MCAP_DL_LOCAL="$6" \
        HF_HUB_DISABLE_TELEMETRY=1 "$1" - <<'PY'
import os
from huggingface_hub import snapshot_download

def split(value):
    return [p for p in value.split(",") if p] or None

path = snapshot_download(
    os.environ["MCAP_DL_REPO"],
    revision=os.environ["MCAP_DL_REV"],
    allow_patterns=split(os.environ.get("MCAP_DL_ALLOW", "")),
    ignore_patterns=split(os.environ.get("MCAP_DL_IGNORE", "")),
    local_files_only=os.environ.get("MCAP_DL_LOCAL") == "1",
)
print(path)
PY
}

weights_ok() {  # $1 = snapshot dir; checks size always and sha256 when $2 = 1 (slow for 3 GB: about 10 s)
    local f="$1/$M_FILE"
    [ -f "$f" ] || return 1
    [ "$(file_bytes "$f")" = "$M_FILE_BYTES" ] || return 1
    [ "${2:-0}" != 1 ] || [ "$(sha256_of "$f")" = "$M_FILE_SHA" ]
}

# The pipeline looks up repos it has no revision pin for (turbo, Qwen) with snapshot_download(revision=None,
# local_files_only=True), which reads refs/main of the cache. A download by commit hash does not write that file, so
# without it the pipeline would not see the model and would download it a second time. Only written when absent.
ensure_main_ref() {  # $1 = python, $2 = repo, $3 = revision
    MCAP_DL_REPO="$2" MCAP_DL_REV="$3" "$1" - <<'PY'
import os
from pathlib import Path
from huggingface_hub import constants

repo, rev = os.environ["MCAP_DL_REPO"], os.environ["MCAP_DL_REV"]
ref = Path(constants.HF_HUB_CACHE) / ("models--" + repo.replace("/", "--")) / "refs" / "main"
if not ref.exists() and (ref.parent.parent / "snapshots" / rev).is_dir():
    ref.parent.mkdir(parents=True, exist_ok=True)
    ref.write_text(rev)
PY
}

free_kb() { df -Pk "$1" | awk 'NR == 2 { print $4 }'; }

download_model() {  # $1 = model name (see model_lookup), uses $MODEL_PY (needs huggingface_hub from the lock)
    local dir free_needed_kb path
    model_lookup "$1" || die "unknown model $1"
    if path="$(snapshot "$MODEL_PY" "$M_REPO" "$M_REV" "$M_ALLOW" "$M_IGNORE" 1 2>/dev/null)" && weights_ok "$path"; then
        [ "$M_MAIN_REF" = 0 ] || ensure_main_ref "$MODEL_PY" "$M_REPO" "$M_REV"
        log "model $M_REPO: already in the Hugging Face cache ($path)"
        return 0
    fi
    dir="${HF_HOME:-$HOME/.cache/huggingface}"
    mkdir -p "$dir"
    free_needed_kb=$(( (M_BYTES / 1024) * 11 / 10 ))
    if [ "$(free_kb "$dir")" -lt "$free_needed_kb" ]; then
        die "not enough free disk space in $dir for $M_REPO (need about $(gb "$M_BYTES"), have $(awk -v k="$(free_kb "$dir")" 'BEGIN { printf "%.2f GB", k * 1024 / 1e9 }'))"
    fi
    log "downloading $M_REPO @ ${M_REV:0:8} ($(commas "$M_BYTES") bytes = $(gb "$M_BYTES")) into $dir ..."
    path="$(snapshot "$MODEL_PY" "$M_REPO" "$M_REV" "$M_ALLOW" "$M_IGNORE" 0)"
    weights_ok "$path" || die "download finished but $path/$M_FILE has the wrong size (want $(commas "$M_FILE_BYTES") bytes); delete it and retry"
    log "verifying sha256 of $M_FILE (takes a few seconds) ..."
    weights_ok "$path" 1 || die "sha256 mismatch for $path/$M_FILE (want $M_FILE_SHA); delete the snapshot and retry"
    [ "$M_MAIN_REF" = 0 ] || ensure_main_ref "$MODEL_PY" "$M_REPO" "$M_REV"
    log "model $M_REPO: ready ($path)"
}

# ---- plan ----------------------------------------------------------------------------------------------------
print_plan() {  # $1 = chosen interpreter or ""
    local pins name
    pins="$(grep -vc -e '^#' -e '^[[:space:]]*$' "$LOCK_FILE" 2>/dev/null || echo "?")"
    echo "Plan (SUPPORT_DIR: $SUPPORT_DIR)"
    if [ "$BENCH_ONLY" != 1 ]; then
        if [ -x "$VENV_PY" ] && [ "$RECREATE" != 1 ]; then
            echo "  venv      : production venv exists, $VENV_DIR (Python $(python_version "$VENV_PY"))"
        else
            echo "  venv      : create the production venv $VENV_DIR with ${1:-<no suitable Python found>}$([ "$VENV_COPIES" = 1 ] && echo ', --copies (no link to the base python)')"
        fi
        if [ "$CLIENT_ONLY" = 1 ]; then
            echo "  packages  : $(grep -vc -e '^#' -e '^[[:space:]]*$' "$CLIENT_REQ" 2>/dev/null || echo "?") pinned packages from pipeline/requirements.client.txt (numpy, truststore), same versions as the lock, pip --no-deps."
            echo "              CLIENT-ONLY: no local speech engine in this venv, no model download; transcription goes to the company relay (not verified on 8 GB Macs)"
        else
            echo "  packages  : $pins pinned packages from pipeline/requirements.lock.txt, pip --no-deps (no torch), about $PACKAGES_APPROX_MB MB on disk"
        fi
        if [ -n "$HASH_LOCK" ]; then
            echo "  hash lock : $HASH_LOCK: pip install --require-hashes --no-deps -r (every wheel's sha256 is checked; the pins must be exactly those above)"
        elif [ "$CLIENT_ONLY" = 1 ] || [ -n "$VENV_DIR_OPT" ]; then
            echo "  hash lock : none (version pins only: scripts/make_hash_lock.sh makes one; a company release should use it: --hash-lock FILE)"
        fi
    fi
    if [ "$WITH_CLOUD" = 1 ]; then
        if [ "$CLIENT_ONLY" = 1 ] || [ "$BENCH_ONLY" != 1 ]; then
            echo "  cloud     : truststore (the operating system's certificate store for cloud engine hosts such as *.api.cognitive.microsoft.com) is $([ "$CLIENT_ONLY" = 1 ] && echo 'part of --client-only' || echo 'part of the lock'); it is imported after the install. The company relay needs no package for TLS (pinned private CA)."
        fi
    fi
    if [ "$WITH_SILERO" = 1 ]; then
        echo "  silero    : onnxruntime 1.30.0 + flatbuffers + protobuf (about $ONNXRUNTIME_APPROX_MB MB) and the model silero_vad.onnx, $(commas "$SILERO_ONNX_BYTES") bytes ($(mb "$SILERO_ONNX_BYTES")), sha256 ${SILERO_ONNX_SHA256:0:12}..., -> $(silero_target)"
        if [ -n "$SILERO_FILE" ]; then
            echo "              (from the local file $SILERO_FILE, nothing is downloaded for the model)"
        else
            echo "              (from github.com/snakers4/silero-vad tag v6.2.3; fallback: PyPI wheel, $(commas "$SILERO_WHEEL_BYTES") bytes)"
        fi
    fi
    if [ "$WITH_QWEN" = 1 ] || [ "$BENCH_ONLY" = 1 ]; then
        if [ -x "$BENCH_VENV_PY" ] && [ "$RECREATE" != 1 ]; then
            echo "  bench venv: exists, $BENCH_VENV_DIR (BENCHMARK ONLY, separate from the production venv)"
        else
            echo "  bench venv: create $BENCH_VENV_DIR with ${1:-<no suitable Python found>} (BENCHMARK ONLY, separate from the production venv), the same $pins pinned packages, about $PACKAGES_APPROX_MB MB more on disk"
        fi
        if [ "$WITH_QWEN" = 1 ]; then
            echo "  qwen bench: mlx-qwen3-asr 0.4.4, pinned (small, pure Python on top of the packages above), installed ONLY into the bench venv"
        fi
    fi
    for name in $DOWNLOADS; do
        model_lookup "$name"
        echo "  model     : $M_REPO @ ${M_REV:0:8}  $(commas "$M_BYTES") bytes = $(gb "$M_BYTES")  (into ${HF_HOME:-$HOME/.cache/huggingface})"
    done
    if [ -z "$DOWNLOADS" ]; then
        if [ "$CLIENT_ONLY" = 1 ]; then
            echo "  models    : none (the client-only venv has no local model)"
        else
            echo "  models    : none (the first transcription downloads whisper-large-v3, 3.08 GB; or add --pre-download-model)"
        fi
    fi
    echo
}

main() {
    trap on_exit EXIT

    while [ $# -gt 0 ]; do
        case "$1" in
            --with-silero) WITH_SILERO=1 ;;
            --silero-file) [ $# -ge 2 ] || die "--silero-file needs a path"; SILERO_FILE="$2"; WITH_SILERO=1; shift ;;
            --with-qwen-bench) WITH_QWEN=1 ;;
            --bench-only) BENCH_ONLY=1 ;;
            --pre-download-model) add_download whisper-large-v3 ;;
            --download)
                [ $# -ge 2 ] || die "--download needs a comma separated list"
                for name in $(echo "$2" | tr ',' ' '); do add_download "$name"; done
                shift ;;
            --python) [ $# -ge 2 ] || die "--python needs a path"; PYTHON_OVERRIDE="$2"; shift ;;
            --recreate) RECREATE=1 ;;
            --client-only) CLIENT_ONLY=1 ;;
            --with-cloud) WITH_CLOUD=1 ;;
            --hash-lock) [ $# -ge 2 ] || die "--hash-lock needs a file"; HASH_LOCK="$2"; shift ;;
            --check-hash-lock) [ $# -ge 3 ] || die "--check-hash-lock needs the requirement file and the hash lock"; CHECK_REQ="$2"; CHECK_LOCK="$3"; shift 2 ;;
            --venv-dir) [ $# -ge 2 ] || die "--venv-dir needs a directory"; VENV_DIR_OPT="$2"; shift ;;
            --copies) VENV_COPIES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    if [ -n "$CHECK_LOCK" ]; then       # a comparison only: nothing below this block runs
        [ -f "$CHECK_REQ" ] || die "--check-hash-lock: not a file: $CHECK_REQ"
        [ -f "$CHECK_LOCK" ] || die "--check-hash-lock: not a file: $CHECK_LOCK"
        if check_hash_lock "$CHECK_REQ" "$CHECK_LOCK"; then
            log "the hash lock $CHECK_LOCK lists exactly the pins of $CHECK_REQ"
            exit 0
        fi
        DIED=1
        echo "[setup_python] the hash lock $CHECK_LOCK does not match $CHECK_REQ (see above)" >&2
        exit 1
    fi
    [ -f "$LOCK_FILE" ] || die "lock file not found: $LOCK_FILE"
    if [ "$CLIENT_ONLY" = 1 ]; then
        [ -f "$CLIENT_REQ" ] || die "requirement file not found: $CLIENT_REQ"
        [ -z "$DOWNLOADS" ] || die "--client-only has no local speech engine: no model is downloaded (drop --pre-download-model / --download; the relay transcribes)"
        [ "$WITH_QWEN" != 1 ] && [ "$BENCH_ONLY" != 1 ] || die "--client-only cannot be combined with --with-qwen-bench or --bench-only (the benchmark venv is a full venv)"
        check_client_pins || die "pipeline/requirements.client.txt and pipeline/requirements.lock.txt disagree (see above): keep the versions in step"
    fi
    if [ -n "$HASH_LOCK" ] && [ "$BENCH_ONLY" = 1 ]; then die "--hash-lock applies to the production venv: not with --bench-only"; fi
    if [ -n "$VENV_DIR_OPT" ]; then
        [ "$BENCH_ONLY" != 1 ] || die "--venv-dir is the production venv: not with --bench-only"
        case "$VENV_DIR_OPT" in
            /*) ;;
            *) die "--venv-dir must be an absolute path (got '$VENV_DIR_OPT')" ;;
        esac
        case "$VENV_DIR_OPT" in
            */venv) ;;
            *) die "--venv-dir must end in /venv (got '$VENV_DIR_OPT'): the folder is deleted by --recreate, and only a folder with that name is ever deleted" ;;
        esac
        VENV_DIR="${VENV_DIR_OPT%/}"
        VENV_PY="$VENV_DIR/bin/python"
        MODEL_PY="$VENV_PY"
    fi
    if [ "$(uname -sm)" != "Darwin arm64" ]; then
        if [ "$DRY_RUN" = 1 ]; then warn "this is not an Apple Silicon Mac ($(uname -sm)): mlx would not install"
        else die "mlx needs an Apple Silicon Mac running macOS (this is: $(uname -sm))"; fi
    fi

    local py="" name want_bench=0 need_python=0
    if [ "$WITH_QWEN" = 1 ] || [ "$BENCH_ONLY" = 1 ]; then want_bench=1; fi
    # which venvs does this run create? (an existing one needs no interpreter, unless --recreate)
    if [ "$BENCH_ONLY" != 1 ] && { [ ! -x "$VENV_PY" ] || [ "$RECREATE" = 1 ]; }; then need_python=1; fi
    if [ "$want_bench" = 1 ] && { [ ! -x "$BENCH_VENV_PY" ] || [ "$RECREATE" = 1 ]; }; then need_python=1; fi
    [ "$BENCH_ONLY" != 1 ] || MODEL_PY="$BENCH_VENV_PY"

    if [ "$need_python" = 0 ]; then
        :
    elif py="$(pick_python)"; then
        check_python_version "$py"
        if [ "$VENV_COPIES" = 1 ] || [ -n "$VENV_DIR_OPT" ]; then
            case "$py" in
                /opt/homebrew/*|/usr/local/*|"$HOME"/*)
                    warn "$py is not a python that root owns: a company release needs a venv built on a root-owned base python that nobody else can write (the python.org framework in /Library/Frameworks after chown -R root:wheel and chmod -R go-w, docs/DEPLOY.md 3.1): scripts/provision_runtime.sh refuses a venv whose base python is missing, writable by group or others, or (as root) not root-owned" ;;
            esac
        fi
    elif [ "$DRY_RUN" = 1 ]; then
        warn "no Python found (looked for python3.13 and python3.12 in /opt/homebrew/bin, the python.org framework, /usr/local/bin and on PATH); a real run would stop here"
    else
        die "no usable Python 3.12 or newer: install it yourself (brew install python@3.13, or the installer from python.org) and name it with MCAP_PYTHON=/path/to/python3.13 (in front of make install ARGS=\"--python\", or of this script), or run this script directly with --python /path/to/python3.13. This script never installs Homebrew packages."
    fi

    print_plan "$py"
    [ "$DRY_RUN" != 1 ] || log "dry run: nothing below is executed"

    if [ "$BENCH_ONLY" != 1 ]; then
        ensure_venv "$py" "$VENV_DIR"
        if [ "$CLIENT_ONLY" = 1 ]; then
            install_pins "$CLIENT_REQ" "packages" "$VENV_DIR"
        else
            install_pins "$LOCK_FILE" "packages" "$VENV_DIR"
        fi
        if [ "$WITH_SILERO" = 1 ]; then
            install_pins "$SILERO_REQ" "silero runtime" "$VENV_DIR"
        fi
        warn_qwen_in_production
    fi
    if [ "$WITH_SILERO" = 1 ]; then
        if [ "$DRY_RUN" = 1 ]; then
            if [ -n "$SILERO_FILE" ]; then
                echo "[dry-run] would copy $SILERO_FILE to $(silero_target) after checking its sha256"
            else
                echo "[dry-run] would download $SILERO_URL ($(commas "$SILERO_ONNX_BYTES") bytes), check its sha256 and install it as $(silero_target)"
            fi
        fi
    fi
    if [ "$want_bench" = 1 ]; then
        ensure_venv "$py" "$BENCH_VENV_DIR"
        install_pins "$LOCK_FILE" "bench venv: packages" "$BENCH_VENV_DIR"
        if [ "$WITH_SILERO" = 1 ]; then
            install_pins "$SILERO_REQ" "bench venv: silero runtime" "$BENCH_VENV_DIR"
        fi
        if [ "$WITH_QWEN" = 1 ]; then
            install_pins "$QWEN_REQ" "bench venv: mlx-qwen3-asr" "$BENCH_VENV_DIR"
        fi
    fi
    if [ "$WITH_SILERO" = 1 ] && [ "$DRY_RUN" != 1 ]; then
        fetch_silero_model "$MODEL_PY"
        check_silero_runs "$MODEL_PY" || die "the Silero model does not run with the installed onnxruntime"
    fi
    if [ "$BENCH_ONLY" != 1 ]; then
        if [ "$CLIENT_ONLY" = 1 ]; then
            verify_client_imports "$VENV_DIR"
        else
            verify_imports "$VENV_DIR"
        fi
        if [ "$WITH_CLOUD" = 1 ]; then verify_cloud_trust "$VENV_DIR"; fi
    fi
    if [ "$want_bench" = 1 ]; then
        verify_imports "$BENCH_VENV_DIR" "$([ "$WITH_QWEN" = 1 ] && echo qwen || true)"
    fi

    for name in $DOWNLOADS; do
        if [ "$DRY_RUN" = 1 ]; then
            model_lookup "$name"
            echo "[dry-run] would download $M_REPO @ ${M_REV:0:8} ($(commas "$M_BYTES") bytes), then verify $M_FILE size and sha256"
        else
            download_model "$name"
        fi
    done

    echo
    if [ "$DRY_RUN" = 1 ]; then
        log "dry run finished; nothing was changed"
    else
        if [ "$BENCH_ONLY" != 1 ] && [ -n "$VENV_DIR_OPT" ]; then
            log "done. Venv of a company release: $VENV_PY"
            log "next (docs/DEPLOY.md): put pipeline/ and the model next to it, then  scripts/provision_runtime.sh --release-dir <release> --make-manifest , sign the manifest offline,"
            log "      and  scripts/build_pkg.sh --release-dir <release> --release-pubkey <key>"
        elif [ "$BENCH_ONLY" != 1 ]; then
            log "done. Production Python: $VENV_PY"
            log "next: make doctor   (or: cd pipeline && '$VENV_PY' -m mcap doctor)"
            log "then, in this order (docs/LIVE_TEST.md; scripts/install.sh prints the exact commands): permissions (setup), device test"
            log "      (selftest-capture --live), solo Zoom call, solo Teams call. The LaunchAgent comes last (make confirm-live-tested)."
        fi
        if [ "$want_bench" = 1 ]; then
            log "bench Python (benchmarks only): $BENCH_VENV_PY"
        fi
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
