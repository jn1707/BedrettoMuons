#!/usr/bin/env bash
set -euo pipefail
TAG="v288"
LIBDIR="$HOME/.local/lib/wavecatcher/${TAG}/lib"
LIB="$LIBDIR/libWaveCatcher64ch_${TAG}.so"
echo "Hola, starting up..." > hola_test.txt
if [[ ! -f "$LIB" ]]; then
  echo "Missing library: $LIB" >> hola_test.txt
  exit 1
fi
echo "Found library" >> hola_test.txt
if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <command> [args...]" >> hola_test.txt
  echo "Example: $(basename "$0") python3 $HOME/Documents/rate_monitor.py --verbose" >> hola_test.txt
  exit 2
fi
TS="$(date +%Y%m%d_%H%M%S)"
LOG="/tmp/wc_runtime_${TAG}_${TS}.log"
export WC_LIB_VERSION="$TAG"
export WC_LIB_PATH="$LIB"
export LD_LIBRARY_PATH="$LIBDIR:/usr/local/lib64"
# ensure the picked filename is always libWaveCatcher64ch.so for scripts that use default names
ln -sfn "libWaveCatcher64ch_${TAG}.so" "$LIBDIR/libWaveCatcher64ch.so"
{
  echo "timestamp=$(date -Iseconds)"
  echo "WC_LIB_VERSION=$WC_LIB_VERSION"
  echo "WC_LIB_PATH=$WC_LIB_PATH"
  echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  echo "--- ldd WC_LIB ---"
  ldd "$WC_LIB_PATH"
  echo "--- command ---"
  printf '%q ' "$@"; echo
} > "$LOG"
echo "[wc_run_${TAG}] runtime log: $LOG"
exec "$@"
