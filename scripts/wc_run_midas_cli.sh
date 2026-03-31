#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  wc_run_midas_cli.sh --duration SEC --triggermode normal|coincidence|software \
    --edge pos|neg --threshold VOLT --channels CH or CH0,CH1 [--sw-hz HZ] [--coinc-threshold VOLT]

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --triggermode) TRIGGER_MODE="$2"; shift 2 ;;
    --edge) EDGE="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --channels) CHANNELS="$2"; shift 2 ;;
    --sw-hz) SW_HZ="$2"; shift 2 ;;
    --coinc-threshold) COINC_THR="$2"; shift 2 ;;
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

ensure_frontend_running

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
mtransition -e wavecatcher START | tee "$OUT_DIR/start.txt"
sleep $((DURATION + 1))
STATE="$(odbedit -e wavecatcher -c "ls '/Runinfo/State'" 2>/dev/null | awk 'NF{v=$NF} END{print v}')"
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
