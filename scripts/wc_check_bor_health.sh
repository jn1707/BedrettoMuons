#!/usr/bin/env bash
set -euo pipefail

export MIDASSYS=/home/morenoma/packages/midas
export MIDAS_EXPTAB=/home/morenoma/online_wc/exptab
export MIDAS_EXPT_NAME=wavecatcher
export MIDAS_DIR=/home/morenoma/online_wc
export PATH="$MIDASSYS/bin:$PATH"

echo "== MIDAS BOR Health =="
echo

echo "-- Run state --"
odbedit -e wavecatcher -c "ls '/Runinfo/State'" 2>/dev/null || true
odbedit -e wavecatcher -c "ls '/Runinfo/Transition in progress'" 2>/dev/null || true
echo

echo "-- Device readiness --"
odbedit -e wavecatcher -c "ls '/Equipment/WaveCatcher/Variables/device_open_state'" 2>/dev/null || true
odbedit -e wavecatcher -c "ls '/Equipment/WaveCatcher/Variables/device_open_state_str'" 2>/dev/null || true
echo

echo "-- Recent transition/frontend log lines --"
tail -n 120 /home/morenoma/online_wc/midas.log 2>/dev/null | \
  grep -E "WaveCatcher Frontend|begin_of_run|transition|status 603|previous transition|OpenDevice attempt|device open" || true
echo

echo "-- Process status --"
ps aux | grep -E "mserver.*wavecatcher|mhttpd.*wavecatcher|wc_midas_frontend" | grep -v grep || true
echo

echo "Done."

