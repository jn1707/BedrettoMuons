#!/usr/bin/env bash
set -euo pipefail

export MIDASSYS="${MIDASSYS:-$HOME/packages/midas}"
export MIDAS_EXPTAB="${MIDAS_EXPTAB:-$HOME/online_wc/exptab}"
export MIDAS_EXPT_NAME="${MIDAS_EXPT_NAME:-wavecatcher}"
export MIDAS_DIR="${MIDAS_DIR:-$HOME/online_wc}"
export PATH="$MIDASSYS/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib/wavecatcher/v288/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HOME/online_wc}"
mkdir -p "$LOG_DIR"

cd "$SCRIPT_DIR"
make -s wc_midas_frontend

mserver -e "$MIDAS_EXPT_NAME" > "$LOG_DIR/mserver_live.log" 2>&1 &
MHTTPD_CMD=(mhttpd -D -e "$MIDAS_EXPT_NAME" --no-passwords --no-hostlist)
"${MHTTPD_CMD[@]}" > "$LOG_DIR/mhttpd.log" 2>&1

./wc_midas_frontend -D -e "$MIDAS_EXPT_NAME" > "$LOG_DIR/wc_midas_frontend.log" 2>&1 &
echo "Started minimal MIDAS stack for $MIDAS_EXPT_NAME"
