#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  wc_run_midas_cli.sh --duration SEC --triggermode normal|coincidence|software \
    --edge pos|neg --threshold VOLT --channels CH or CH0,CH1 [--sw-hz HZ] [--coinc-threshold VOLT] [--start-retries N]

Examples:
  wc_run_midas_cli.sh --duration 10 --triggermode normal --edge pos --threshold 0.050 --channels 0
  wc_run_midas_cli.sh --duration 10 --triggermode coincidence --edge pos --threshold 0.050 --channels 0,1
  wc_run_midas_cli.sh --duration 8 --triggermode software --edge pos --threshold 0.020 --channels 0 --sw-hz 20
EOF
}

DURATION=""
TRIGGER_MODE=""
EDGE=""
THRESHOLD=""
CHANNELS=""
SW_HZ="20"
COINC_THR=""
START_RETRIES="3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --triggermode) TRIGGER_MODE="$2"; shift 2 ;;
    --edge) EDGE="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --channels) CHANNELS="$2"; shift 2 ;;
    --sw-hz) SW_HZ="$2"; shift 2 ;;
    --coinc-threshold) COINC_THR="$2"; shift 2 ;;
    --start-retries) START_RETRIES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$DURATION" && -n "$TRIGGER_MODE" && -n "$EDGE" && -n "$THRESHOLD" && -n "$CHANNELS" ]] || {
  usage
  exit 2
}

case "$TRIGGER_MODE" in
  normal) MODE_INT=0 ;;
  software) MODE_INT=1 ;;
  coincidence) MODE_INT=2 ;;
  *) echo "Invalid --triggermode: $TRIGGER_MODE" >&2; exit 2 ;;
esac

case "$EDGE" in
  pos) EDGE_INT=0 ;;
  neg) EDGE_INT=1 ;;
  *) echo "Invalid --edge: $EDGE (use pos|neg)" >&2; exit 2 ;;
esac

IFS=',' read -r CH0 CH1 <<< "$CHANNELS"
[[ -n "${CH0:-}" ]] || { echo "Invalid --channels: $CHANNELS" >&2; exit 2; }
if [[ -z "${CH1:-}" ]]; then
  CH1="$CH0"
fi

if [[ -z "$COINC_THR" ]]; then
  COINC_THR="$THRESHOLD"
fi

export MIDASSYS=/home/morenoma/packages/midas
export MIDAS_EXPTAB=/home/morenoma/online_wc/exptab
export MIDAS_EXPT_NAME=wavecatcher
export MIDAS_DIR=/home/morenoma/online_wc
export PATH="$MIDASSYS/bin:$PATH"
WC_WD_RUNTIME_MS="${WC_WD_RUNTIME_MS:-120000}"
WC_TR_CONNECT_RUNTIME_MS="${WC_TR_CONNECT_RUNTIME_MS:-120000}"
WC_TR_TOTAL_RUNTIME_MS="${WC_TR_TOTAL_RUNTIME_MS:-180000}"
WC_CLI_RESTART_STACK="${WC_CLI_RESTART_STACK:-0}"
WC_CLI_PREFLIGHT="${WC_CLI_PREFLIGHT:-0}"
WC_CLI_OPEN_SETTLE_S="${WC_CLI_OPEN_SETTLE_S:-10}"

if [[ "${WC_CLI_RESTART_STACK}" == "1" ]] && [[ -x /home/morenoma/Documents/wc_start_midas_stack.sh ]]; then
  /home/morenoma/Documents/wc_start_midas_stack.sh >/dev/null
fi

OUT_BASE="/home/morenoma/Documents/wc_midas_phase1_v2/cli_runs"
mkdir -p "$OUT_BASE"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OUT_BASE/run_${STAMP}"
mkdir -p "$OUT_DIR"

ensure_frontend_running() {
  if pgrep -f "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend.*-e wavecatcher" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /home/morenoma/Documents/wc_start_midas_stack.sh ]]; then
    echo "WaveCatcher frontend not running; starting stack via wc_start_midas_stack.sh..."
    /home/morenoma/Documents/wc_start_midas_stack.sh >/dev/null
    sleep 2
  fi
  if ! pgrep -f "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend.*-e wavecatcher" >/dev/null 2>&1; then
    echo "ERROR: WaveCatcher frontend is not running." >&2
    echo "Check /home/morenoma/online_wc/wc_midas_frontend.log" >&2
    exit 1
  fi
}

clear_stale_transition_lock() {
  local tip
  tip="$(odbedit -e wavecatcher -c "ls '/Runinfo/Transition in progress'" 2>/dev/null | awk '/^Transition in progress/ {print $NF; exit}' || true)"
  if [[ ! "${tip:-}" =~ ^[0-9]+$ ]]; then
    tip=0
  fi
  if [[ "${tip:-0}" != "0" ]]; then
    echo "Clearing stale '/Runinfo/Transition in progress'=${tip} ..."
    odbedit -e wavecatcher -c "set '/Runinfo/Transition in progress' 0" >/dev/null 2>&1 || true
    sleep 1
  fi
}

get_run_state() {
  odbedit -e wavecatcher -c "ls '/Runinfo/State'" 2>/dev/null | awk '/^State/ {print $NF; exit}'
}

get_device_open_state() {
  odbedit -e wavecatcher -c "ls '/Equipment/WaveCatcher/Variables/device_open_state'" 2>/dev/null | awk '/^device_open_state/ {print $NF; exit}'
}

wait_for_device_ready() {
  local wait_s="${1:-90}"
  local waited=0
  local st
  while [[ "$waited" -lt "$wait_s" ]]; do
    st="$(get_device_open_state || true)"
    if [[ "${st:-}" == "2" ]]; then
      echo "Device open state: ready"
      return 0
    fi
    if [[ "${st:-}" == "3" || "${st:-}" == "4" ]]; then
      echo "Device open state: failed/timed_out (${st:-})"
      return 1
    fi
    if (( waited % 10 == 0 )); then
      echo "Waiting for device readiness... state=${st:-unknown} waited=${waited}s"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "Timed out waiting for device readiness (last state=${st:-unknown})"
  return 1
}

set_runtime_timeout_profile() {
  odbedit -e wavecatcher -c "set '/Programs/WaveCatcher Frontend/Watchdog timeout' ${WC_WD_RUNTIME_MS}" >/dev/null 2>&1 || true
  odbedit -e wavecatcher -c "set '/Experiment/Transition connect timeout' ${WC_TR_CONNECT_RUNTIME_MS}" >/dev/null 2>&1 || true
  odbedit -e wavecatcher -c "set '/Experiment/Transition timeout' ${WC_TR_TOTAL_RUNTIME_MS}" >/dev/null 2>&1 || true
}

cooldown_before_retry() {
  local attempt="$1"
  echo "Cooldown before retry #${attempt}: STOP/clear/wait/probe..."
  timeout 25 mtransition -e wavecatcher STOP >/tmp/wc_cli_retry_stop_${STAMP}_${attempt}.log 2>&1 || true
  clear_stale_transition_lock
  sleep 3
  timeout 20 /home/morenoma/online_wc/midas_frontend/wc_test_harness >/tmp/wc_cli_retry_harness_${STAMP}_${attempt}.log 2>&1 || true
  sleep 2
}

restart_frontend_only() {
  local pid
  pid="$(pgrep -f '/home/morenoma/online_wc/midas_frontend/wc_midas_frontend.*-e wavecatcher' | head -n 1 || true)"
  if [[ -n "${pid}" ]]; then
    echo "Restarting frontend PID ${pid} to retry device open..."
    kill "${pid}" 2>/dev/null || true
    sleep 2
  fi
  setsid /home/morenoma/online_wc/midas_frontend/wc_midas_frontend -e wavecatcher > /home/morenoma/online_wc/wc_midas_frontend.log 2>&1 < /dev/null &
  sleep "${WC_CLI_OPEN_SETTLE_S}"
}

ensure_frontend_running

if [[ "${WC_CLI_PREFLIGHT}" == "1" ]]; then
  echo "Priming hardware path (direct v288 preflight, explicit opt-in)..."
  if ! timeout 20 /home/morenoma/Documents/wc_run_v288.sh python3 -u /home/morenoma/Documents/wc_capture_waveforms_png.py \
    --seconds 0.8 --threshold "$THRESHOLD" --edge "$EDGE" --accept-mv 5 --max-save 1 \
    --output-dir "/tmp/wc_cli_preflight_${STAMP}" >/tmp/wc_cli_preflight.log 2>&1; then
    echo "WARNING: preflight did not complete; MIDAS START may still timeout."
    echo "Check /tmp/wc_cli_preflight.log"
  fi
fi

echo "Configuring ODB..."
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/trigger_mode' $MODE_INT" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/trigger_edge' $EDGE_INT" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/trigger_threshold_v' $THRESHOLD" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/enabled_channel' $CH0" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/enabled_channels_csv' \"$CHANNELS\"" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/apply_threshold_to_selected' y" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/selected_threshold_v' $THRESHOLD" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/coincidence_channel' $CH1" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/coincidence_threshold_v' $COINC_THR" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/run_duration_s' $DURATION" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/auto_stop_mode' 1" >/dev/null
odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/target_event_count' 0" >/dev/null
if [[ "$MODE_INT" -eq 1 ]]; then
  odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/sw_trigger_hz' $SW_HZ" >/dev/null
else
  odbedit -e wavecatcher -c "set '/Equipment/WaveCatcher/Variables/sw_trigger_hz' 0" >/dev/null
fi

echo "Starting run..."
start_ok=0
for attempt in $(seq 1 "$START_RETRIES"); do
  clear_stale_transition_lock
  if ! wait_for_device_ready 120; then
    echo "Skipping START attempt ${attempt}: device not ready."
    if [[ "$attempt" -lt "$START_RETRIES" ]]; then
      restart_frontend_only
      cooldown_before_retry "$attempt"
      continue
    fi
    break
  fi
  clear_stale_transition_lock
  echo "START attempt ${attempt}/${START_RETRIES}..."
  PRE_STATE="$(get_run_state || true)"
  if [[ "${PRE_STATE:-}" == "3" ]]; then
    echo "Run already in RUNNING state before START; treating as started."
    start_ok=1
    break
  fi
  mtransition -e wavecatcher START | tee "$OUT_DIR/start_attempt_${attempt}.txt" || true
  START_STATE="$(get_run_state || true)"
  if [[ "${START_STATE:-}" == "3" ]]; then
    cat "$OUT_DIR/start_attempt_${attempt}.txt" > "$OUT_DIR/start.txt"
    set_runtime_timeout_profile
    start_ok=1
    break
  fi
  echo "START attempt ${attempt} failed (state=${START_STATE:-unknown})."
  if [[ "$attempt" -lt "$START_RETRIES" ]]; then
    if [[ "${WC_CLI_PREFLIGHT}" == "1" ]]; then
      echo "Re-priming hardware path before retry (explicit opt-in)..."
      timeout 20 /home/morenoma/Documents/wc_run_v288.sh python3 -u /home/morenoma/Documents/wc_capture_waveforms_png.py \
        --seconds 0.8 --threshold "$THRESHOLD" --edge "$EDGE" --accept-mv 5 --max-save 1 \
        --output-dir "/tmp/wc_cli_retry_preflight_${STAMP}_${attempt}" >/tmp/wc_cli_retry_preflight.log 2>&1 || true
    fi
    cooldown_before_retry "$attempt"
  fi
done

if [[ "$start_ok" -ne 1 ]]; then
  echo "ERROR: Could not START MIDAS run after ${START_RETRIES} attempts." >&2
  echo "Most likely cause: WaveCatcher open timeout in BOR context." >&2
  echo "Check logs: /home/morenoma/online_wc/wc_midas_frontend.log and /home/morenoma/online_wc/midas.log" >&2
  echo "Immediate fallback to still record data (direct path):" >&2
  echo "  /home/morenoma/Documents/wc_run_v288.sh python3 -u /home/morenoma/Documents/wc_capture_waveforms_png.py --seconds ${DURATION} --threshold ${THRESHOLD} --edge ${EDGE} --accept-mv 20 --max-save 200 --output-dir /home/morenoma/Documents/wc_direct_runs/run_${STAMP}" >&2
  exit 1
fi

sleep $((DURATION + 1))
STATE="$(get_run_state || true)"
if [[ "${STATE:-}" == "3" ]]; then
  echo "Stopping run..."
  mtransition -e wavecatcher STOP | tee "$OUT_DIR/stop.txt"
else
  echo "Run already stopped (likely auto-stop)."
  odbedit -e wavecatcher -c "ls '/Runinfo'" > "$OUT_DIR/stop.txt" 2>&1 || true
fi

echo "Collecting stats..."
odbedit -e wavecatcher -c "ls '/Equipment/WaveCatcher/Statistics'" | tee "$OUT_DIR/stats.txt"
EVENTS="$(awk '/Events sent/{print $NF}' "$OUT_DIR/stats.txt" | tail -n 1)"
if [[ -z "${EVENTS:-}" ]]; then
  EVENTS=0
fi
python3 - "$EVENTS" "$DURATION" > "$OUT_DIR/rate.txt" <<'PY'
import sys
events=float(sys.argv[1]); dur=float(sys.argv[2])
print(f"events={int(events)}")
print(f"duration_s={dur:.3f}")
print(f"rate_hz={(events/dur if dur>0 else 0.0):.3f}")
PY

RUNFILE="$(ls -1t /home/morenoma/online_wc/run*.mid.lz4 | head -n 1)"
echo "$RUNFILE" > "$OUT_DIR/runfile.txt"
echo "Latest run file: $RUNFILE"

echo "Extracting first WCWF bank..."
if mdump "$RUNFILE" -b WCWF -l 1 > "$OUT_DIR/wcwf_dump.txt" 2>"$OUT_DIR/mdump_err.txt"; then
  if grep -q "Bank:WCWF" "$OUT_DIR/wcwf_dump.txt"; then
    python3 /home/morenoma/Documents/wc_midas_phase1_v2/render_midas_waveform_axes.py \
      --wcwf-hex "$OUT_DIR/wcwf_dump.txt" \
      --out-png "$OUT_DIR/waveform_ch${CH0}.png" \
      --sample-ps 312 --time-window-ns 15 --vertical-mv-div 500 --vertical-pos-div 1.42 --offset-v 0 \
      > "$OUT_DIR/render.log" 2>&1 || true
  else
    echo "No WCWF bank found in first dumped event." | tee "$OUT_DIR/waveform_note.txt"
  fi
else
  echo "mdump failed; see $OUT_DIR/mdump_err.txt" | tee "$OUT_DIR/waveform_note.txt"
fi

echo "Done."
echo "Output directory: $OUT_DIR"
echo "Key files:"
echo "  - $OUT_DIR/stats.txt"
echo "  - $OUT_DIR/rate.txt"
echo "  - $OUT_DIR/runfile.txt"
echo "  - $OUT_DIR/wcwf_dump.txt (if present)"
echo "  - $OUT_DIR/waveform_ch${CH0}.png (if rendered)"
