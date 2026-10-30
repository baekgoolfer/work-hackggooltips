#!/bin/bash
# Prepare ANOTHER Apple Silicon Mac (e.g. a Mac mini) to run scripts/bench_asr.py on a copied audio slice, without the
# rest of the project. Run it from the unpacked bench kit (see docs/BENCH_KIT.md or scripts/bench_kit/README.md).
# It REFUSES to run from the full repository: only `make bench-kit` adds the marker file BENCH_KIT to the kit, and a
# directory that has app/ or SPEC.md is the repository, never a kit.
#
#   scripts/bench_kit/setup_bench_env.sh [options]
#
#   --with-qwen        install mlx-qwen3-asr, pinned (needed to benchmark the Qwen3-ASR models)
#   --with-silero      install onnxruntime and the Silero VAD model (recommended: the production pipeline uses it)
#   --silero-file PATH use a local copy of silero_vad.onnx instead of downloading it (implies --with-silero)
#   --download LIST    models to download now, comma separated, exact sizes are printed first:
#                        whisper-large-v3        3.08 GB   baseline (mlx-community/whisper-large-v3-mlx)
#                        qwen3-asr-1.7b          4.08 GB   challenger (mlx-community/Qwen3-ASR-1.7B-bf16)
#                        whisper-large-v3-turbo  1.61 GB   speed control
#   --python PATH      Python to build the venv with (default: python3.13, then python3.12; see scripts/setup_python.sh)
#   --dry-run          print the plan with exact sizes and what would be done; change nothing
#   -h, --help         this text
#
# Everything lives INSIDE the kit directory, so `rm -rf` of that directory removes it all:
#   support/bench-venv  bench Python venv (about 550 MB)  support/models/silero_vad.onnx   (2.3 MB, optional)
#   hf/                 Hugging Face model cache          bench.env                        (written at the end)
# (the kit has no production venv; it is the "bench venv" of scripts/setup_python.sh --bench-only)
# Nothing is installed system-wide, nothing is written outside the kit directory except pip's own cache
# (~/Library/Caches/pip). The audio you benchmark never leaves this Mac: after setup, bench.env switches Hugging Face
# to offline mode (HF_HUB_OFFLINE=1) so a benchmark run cannot download or upload anything.
#
# This is a thin wrapper around scripts/setup_python.sh (same pinned requirements, same checksums), re-run it any time.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUPPORT_DIR="$KIT_DIR/support"
HF_DIR="$KIT_DIR/hf"
ENV_FILE="$KIT_DIR/bench.env"

DRY_RUN=0
WITH_SILERO=0
PASS=()

DIED=0
log() { echo "[bench-setup] $*"; }
die() { DIED=1; echo "[bench-setup] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[bench-setup] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --with-qwen) PASS+=(--with-qwen-bench) ;;
        --with-silero) WITH_SILERO=1; PASS+=(--with-silero) ;;
        --silero-file) [ $# -ge 2 ] || die "--silero-file needs a path"; WITH_SILERO=1; PASS+=(--silero-file "$2"); shift ;;
        --download) [ $# -ge 2 ] || die "--download needs a comma separated list"; PASS+=(--download "$2"); shift ;;
        --python) [ $# -ge 2 ] || die "--python needs a path"; PASS+=(--python "$2"); shift ;;
        --dry-run) DRY_RUN=1; PASS+=(--dry-run) ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---- is this really the bench kit, on the right kind of Mac? -------------------------------------------------------
# The full repository has all the files below too, so they prove nothing. The marker BENCH_KIT is written only by
# `make bench-kit`; app/ and SPEC.md exist only in the repository. Without this check a stray run from the repository
# would build a 550 MB venv and a model cache inside it.
if [ -d "$KIT_DIR/app" ] || [ -e "$KIT_DIR/SPEC.md" ] || [ -d "$KIT_DIR/.git" ]; then
    die "$KIT_DIR is the full meeting-capture repository, not a bench kit. Nothing was done. Build the kit with 'make bench-kit' and unpack build/bench-kit.tar.gz on the OTHER Mac (docs/BENCH_KIT.md)"
fi
[ -f "$KIT_DIR/BENCH_KIT" ] || die "$KIT_DIR/BENCH_KIT (the marker file written by 'make bench-kit') is missing, so this is not an unpacked bench kit. Nothing was done. See docs/BENCH_KIT.md"
for f in pipeline/mcap/asr.py pipeline/requirements.lock.txt scripts/bench_asr.py scripts/setup_python.sh config/vocabulary.txt; do
    [ -e "$KIT_DIR/$f" ] || die "$KIT_DIR/$f is missing: unpack the whole bench kit (make bench-kit on the main Mac) and run this script from there"
done
[ "$(uname -s)" = "Darwin" ] || die "this needs macOS"
if [ "$(uname -m)" != "arm64" ]; then
    if [ "$DRY_RUN" = 1 ]; then log "WARNING: not an Apple Silicon Mac ($(uname -m)); mlx would not install"
    else die "mlx needs an Apple Silicon Mac (this one reports $(uname -m); a terminal running under Rosetta also reports x86_64)"; fi
fi
command -v afconvert >/dev/null 2>&1 || log "WARNING: afconvert not found (it ships with macOS): m4a/mp3 input will not work, use WAV"

log "kit directory: $KIT_DIR"
log "the environment will be created inside it (support/, hf/, bench.env)"
echo

# --bench-only: the kit has no production venv, only the bench venv (support/bench-venv); mlx-qwen3-asr goes in with --with-qwen.
# env -u: a shell that already sourced bench.env has HF_HUB_OFFLINE=1, which would block the model downloads below.
env -u HF_HUB_OFFLINE MCAP_SUPPORT_DIR="$SUPPORT_DIR" HF_HOME="$HF_DIR" "$KIT_DIR/scripts/setup_python.sh" --bench-only ${PASS[@]+"${PASS[@]}"}

if [ "$DRY_RUN" = 1 ]; then
    log "dry run finished; $ENV_FILE was not written"
    exit 0
fi

# ---- bench.env: what to `source` before running bench_asr.py ----------------------------------------------------------
{
    echo "# Written by scripts/bench_kit/setup_bench_env.sh. Use:  source ./bench.env"
    echo "export BENCH_PY=\"$SUPPORT_DIR/bench-venv/bin/python\""
    echo "export HF_HOME=\"$HF_DIR\""
    echo "export HF_HUB_DISABLE_TELEMETRY=1"
    echo "export HF_HUB_OFFLINE=1        # models are already downloaded; a benchmark run must not touch the network"
    if [ "$WITH_SILERO" = 1 ] || [ -f "$SUPPORT_DIR/models/silero_vad.onnx" ]; then
        echo "export MCAP_SILERO_MODEL=\"$SUPPORT_DIR/models/silero_vad.onnx\""
    fi
} > "$ENV_FILE"
log "wrote $ENV_FILE"
echo
echo "Next:"
echo "  cd \"$KIT_DIR\" && source ./bench.env"
echo "  \"\$BENCH_PY\" scripts/bench_asr.py --help"
echo "See docs/BENCH_KIT.md (or scripts/bench_kit/README.md) for the exact benchmark commands."
