#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  wc_convert_mid_to_root.sh --input /path/to/runNNNNN.mid.lz4 [--output /path/to/out.root] [--max-events N]

Notes:
  - Requires ROOT (root-config) and local rootana midasio sources.
  - Produces a ROOT file with tree "wc_events" and basic peak/charge histograms.
EOF
}

INPUT=""
OUTPUT=""
MAX_EVENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --max-events) MAX_EVENTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${INPUT}" ]] || { usage; exit 2; }
[[ -f "${INPUT}" ]] || { echo "Input file not found: ${INPUT}" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIDASIO_DIR="${REPO_ROOT}/tools/rootana/midasio"
if [[ ! -f "${MIDASIO_DIR}/midasio.cxx" ]]; then
  MIDASIO_DIR="/home/morenoma/BedrettoMuons_work/tools/rootana/midasio"
fi
SRC="${SCRIPT_DIR}/wc_mid_to_root.cxx"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bedrettomuons"
BIN="${CACHE_DIR}/wc_mid_to_root.exe"
mkdir -p "${CACHE_DIR}"

if ! command -v root-config >/dev/null 2>&1; then
  echo "root-config not found. Source ROOT setup first, e.g.:" >&2
  echo "  export ROOTSYS=/home/morenoma/.local/tools/root" >&2
  echo "  export PATH=\$ROOTSYS/bin:\$PATH" >&2
  echo "  export LD_LIBRARY_PATH=\$ROOTSYS/lib:\$LD_LIBRARY_PATH" >&2
  exit 2
fi

if [[ ! -f "${MIDASIO_DIR}/midasio.cxx" ]]; then
  echo "Missing midasio sources at ${MIDASIO_DIR}" >&2
  exit 2
fi

if [[ ! -x "${BIN}" || "${SRC}" -nt "${BIN}" ]]; then
  g++ -O2 -std=c++17 \
    -I"${MIDASIO_DIR}" \
    "${SRC}" \
    "${MIDASIO_DIR}/midasio.cxx" \
    "${MIDASIO_DIR}/lz4.cxx" \
    "${MIDASIO_DIR}/lz4frame.cxx" \
    "${MIDASIO_DIR}/lz4hc.cxx" \
    "${MIDASIO_DIR}/xxhash.cxx" \
    $(root-config --cflags --libs) \
    -L/home/morenoma/.local/lib -lxxhash \
    -lz \
    -o "${BIN}"
fi

CMD=("${BIN}" "--input" "${INPUT}")
if [[ -n "${OUTPUT}" ]]; then
  CMD+=("--output" "${OUTPUT}")
fi
if [[ -n "${MAX_EVENTS}" ]]; then
  CMD+=("--max-events" "${MAX_EVENTS}")
fi

"${CMD[@]}"
