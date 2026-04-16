#!/usr/bin/env bash
set -euo pipefail

export MIDASSYS=/home/morenoma/packages/midas
export MIDAS_EXPTAB=/home/morenoma/online_wc/exptab
export MIDAS_EXPT_NAME=wavecatcher
export MIDAS_DIR=/home/morenoma/online_wc
export PATH="$MIDASSYS/bin:$PATH"

SCAN_OUT_DIR="${WC_SCAN_OUTPUT_DIR:-/home/morenoma/online_wc/scan_results}"
SCAN_LOG="${WC_SCAN_LOG:-/home/morenoma/online_wc/wc_threshold_scan_worker.log}"
SCAN_WEB_PLOT="${WC_SCAN_WEB_PLOT:-/home/morenoma/online_wc/custom/wc_threshold_scan_latest.svg}"
mkdir -p "${SCAN_OUT_DIR}"
if [[ ! -f "${SCAN_WEB_PLOT}" ]]; then
  cat > "${SCAN_WEB_PLOT}" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="900" height="320">
  <rect x="0" y="0" width="900" height="320" fill="white"/>
  <text x="450" y="160" text-anchor="middle" font-size="16" fill="#666">No threshold scan yet</text>
</svg>
SVG
fi

odb_get() {
  local path="$1"
  local key
  key="$(basename "$path")"
  odbedit -q -e wavecatcher -c "ls '$path'" 2>/dev/null | awk -v key="$key" '
    index($0, key) == 1 {
      line=$0
      sub("^" key "[[:space:]]+", "", line)
      print line
      exit
    }'
}

odb_get_num() {
  local v
  v="$(odb_get "$1" || true)"
  if [[ ! "${v:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "0"
  else
    echo "$v"
  fi
}

odb_set() {
  local path="$1"
  local value="$2"
  odbedit -q -e wavecatcher -c "set '$path' $value" >/dev/null 2>&1
}

odb_set_str() {
  local path="$1"
  local value="$2"
  odbedit -q -e wavecatcher -c "set '$path' \"$value\"" >/dev/null 2>&1
}

get_run_state() {
  odb_get_num "/Runinfo/State"
}

get_transition_in_progress() {
  odb_get_num "/Runinfo/Transition in progress"
}

clear_transition_if_stale() {
  local tip
  tip="$(get_transition_in_progress)"
  if [[ "${tip}" != "0" ]]; then
    odb_set "/Runinfo/Transition in progress" "0"
  fi
}

wait_for_ready_to_start() {
  local waited=0
  while [[ $waited -lt 120 ]]; do
    local run_state tip open_state
    run_state="$(get_run_state)"
    tip="$(get_transition_in_progress)"
    open_state="$(odb_get "/Equipment/WaveCatcher/Variables/device_open_state_str" || true)"
    if [[ "${run_state}" == "1" && "${tip}" == "0" && "${open_state}" == "ready" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_for_running() {
  local waited=0
  while [[ $waited -lt 45 ]]; do
    if [[ "$(get_run_state)" == "3" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

generate_plot_svg() {
  local csv="$1"
  local svg="$2"
  python3 - "$csv" "$svg" <<'PY'
import csv
import sys

csv_path, svg_path = sys.argv[1], sys.argv[2]
rows = []
with open(csv_path, newline="", encoding="utf-8") as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            x = float(row["threshold_v"])
            y = float(row["rate_hz"])
        except Exception:
            continue
        rows.append((x, y))

if not rows:
    open(svg_path, "w", encoding="utf-8").write('<svg xmlns="http://www.w3.org/2000/svg" width="900" height="320"></svg>\n')
    raise SystemExit(0)

min_x = min(x for x, _ in rows)
max_x = max(x for x, _ in rows)
min_y = 0.0
max_y = max(y for _, y in rows)
if max_x <= min_x:
    max_x = min_x + 1.0
if max_y <= min_y:
    max_y = min_y + 1.0

W, H = 900, 320
L, R, T, B = 70, 20, 20, 40
iw, ih = W - L - R, H - T - B

def sx(x):
    return L + (x - min_x) / (max_x - min_x) * iw

def sy(y):
    return T + (max_y - y) / (max_y - min_y) * ih

pts = " ".join(f"{sx(x):.2f},{sy(y):.2f}" for x, y in rows)
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  <rect x="0" y="0" width="{W}" height="{H}" fill="white"/>
  <line x1="{L}" y1="{H-B}" x2="{W-R}" y2="{H-B}" stroke="#333"/>
  <line x1="{L}" y1="{T}" x2="{L}" y2="{H-B}" stroke="#333"/>
  {''.join(f'<line x1="{sx(min_x + (max_x-min_x)*i/5):.2f}" y1="{H-B}" x2="{sx(min_x + (max_x-min_x)*i/5):.2f}" y2="{H-B+6}" stroke="#333"/>' for i in range(6))}
  {''.join(f'<text x="{sx(min_x + (max_x-min_x)*i/5):.2f}" y="{H-B+20}" font-size="11" text-anchor="middle">{(min_x + (max_x-min_x)*i/5):.3f}</text>' for i in range(6))}
  {''.join(f'<line x1="{L-6}" y1="{sy(min_y + (max_y-min_y)*i/5):.2f}" x2="{L}" y2="{sy(min_y + (max_y-min_y)*i/5):.2f}" stroke="#333"/>' for i in range(6))}
  {''.join(f'<text x="{L-10}" y="{sy(min_y + (max_y-min_y)*i/5)+4:.2f}" font-size="11" text-anchor="end">{(min_y + (max_y-min_y)*i/5):.2f}</text>' for i in range(6))}
  <polyline fill="none" stroke="#1f77b4" stroke-width="2" points="{pts}"/>
  <text x="{W/2:.0f}" y="{H-8}" font-size="12" text-anchor="middle">Threshold [V]</text>
  <text x="16" y="{H/2:.0f}" font-size="12" transform="rotate(-90 16,{H/2:.0f})" text-anchor="middle">Rate [Hz]</text>
</svg>
'''
with open(svg_path, "w", encoding="utf-8") as f:
    f.write(svg)
PY
}

run_one_threshold() {
  local thr="$1"
  local dwell_s="$2"
  local channels_csv="$3"
  local scan_mode="$4"
  local stamp="$5"
  local idx="$6"
  local csv_file="$7"
  local primary_ch coincidence_ch

  primary_ch="$(python3 - "$channels_csv" <<'PY'
import sys
vals=[v.strip() for v in sys.argv[1].split(",") if v.strip()]
print(vals[0] if vals else "0")
PY
)"
  coincidence_ch="$(python3 - "$channels_csv" <<'PY'
import sys
vals=[v.strip() for v in sys.argv[1].split(",") if v.strip()]
print(vals[1] if len(vals) > 1 else (vals[0] if vals else "0"))
PY
)"

  if [[ "${scan_mode}" != "2" ]]; then
    scan_mode="0"
  fi
  odb_set "/Equipment/WaveCatcher/Variables/trigger_mode" "${scan_mode}"
  odb_set "/Equipment/WaveCatcher/Variables/enabled_channel" "${primary_ch}"
  odb_set "/Equipment/WaveCatcher/Variables/coincidence_channel" "${coincidence_ch}"
  odb_set "/Equipment/WaveCatcher/Variables/trigger_threshold_v" "${thr}"
  odb_set "/Equipment/WaveCatcher/Variables/selected_threshold_v" "${thr}"
  odb_set "/Equipment/WaveCatcher/Variables/coincidence_threshold_v" "${thr}"
  odb_set "/Equipment/WaveCatcher/Variables/apply_threshold_to_selected" "y"
  odb_set_str "/Equipment/WaveCatcher/Variables/enabled_channels_csv" "${channels_csv}"
  odb_set "/Equipment/WaveCatcher/Variables/auto_stop_mode" "1"
  odb_set "/Equipment/WaveCatcher/Variables/run_duration_s" "${dwell_s}"
  odb_set "/Equipment/WaveCatcher/Variables/target_event_count" "0"

  clear_transition_if_stale
  if ! wait_for_ready_to_start; then
    odb_set_str "/Scan/Threshold/LastError" "device not ready for scan START"
    return 1
  fi

  if ! mtransition -e wavecatcher START >/tmp/wc_scan_start_${stamp}_${idx}.log 2>&1; then
    odb_set_str "/Scan/Threshold/LastError" "mtransition START failed at threshold ${thr}"
    return 1
  fi
  if ! wait_for_running; then
    odb_set_str "/Scan/Threshold/LastError" "run did not enter RUNNING at threshold ${thr}"
    return 1
  fi

  sleep $((dwell_s + 1))
  if [[ "$(get_run_state)" == "3" ]]; then
    mtransition -e wavecatcher STOP >/tmp/wc_scan_stop_${stamp}_${idx}.log 2>&1 || true
  fi
  clear_transition_if_stale

  sleep 1
  local events run_number rate_hz ts
  events="$(odb_get_num "/Equipment/WaveCatcher/RunSummary/events_sent")"
  run_number="$(odb_get_num "/Equipment/WaveCatcher/RunSummary/run_number")"
  rate_hz="$(python3 - "$events" "$dwell_s" <<'PY'
import sys
ev = float(sys.argv[1])
dt = float(sys.argv[2])
print(f"{(ev/dt if dt > 0 else 0.0):.6f}")
PY
)"
  ts="$(date -Iseconds)"
  printf "%s,%s,%s,%s,%s\n" "$thr" "$events" "$rate_hz" "$run_number" "$ts" >>"${csv_file}"
  return 0
}

echo "[$(date -Iseconds)] threshold scan worker started" >>"${SCAN_LOG}"

while true; do
  request="$(odb_get_num "/Scan/Threshold/Request")"
  if [[ "${request}" != "1" ]]; then
    sleep 1
    continue
  fi

  if [[ "$(get_run_state)" != "1" || "$(get_transition_in_progress)" != "0" ]]; then
    odb_set_str "/Scan/Threshold/State" "deferred_run_active"
    sleep 1
    continue
  fi

  start_v="$(odb_get_num "/Scan/Threshold/StartV")"
  stop_v="$(odb_get_num "/Scan/Threshold/StopV")"
  step_v="$(odb_get_num "/Scan/Threshold/StepV")"
  dwell_s="$(odb_get_num "/Scan/Threshold/DwellS")"
  channels_csv="$(odb_get "/Scan/Threshold/ChannelsCsv" || true)"
  scan_mode="$(odb_get_num "/Scan/Threshold/TriggerMode")"
  if [[ -z "${channels_csv:-}" ]]; then
    channels_csv="$(odb_get "/Equipment/WaveCatcher/Variables/enabled_channels_csv" || true)"
  fi
  if [[ -z "${channels_csv:-}" ]]; then
    channels_csv="0"
  fi
  if [[ "${dwell_s}" -lt 1 ]]; then
    dwell_s=1
  fi
  if ! python3 - "$step_v" <<'PY' >/dev/null; then
import sys
step = float(sys.argv[1])
raise SystemExit(0 if step > 0.0 else 1)
PY
    odb_set_str "/Scan/Threshold/LastError" "invalid StepV (must be >0)"
    odb_set_str "/Scan/Threshold/State" "failed"
    odb_set "/Scan/Threshold/Request" "0"
    continue
  fi

  if [[ "${scan_mode}" != "2" ]]; then
    scan_mode="0"
  fi

  stamp="$(date +%Y%m%d_%H%M%S)"
  csv_file="${SCAN_OUT_DIR}/threshold_scan_${stamp}.csv"
  svg_file="${SCAN_OUT_DIR}/threshold_scan_${stamp}.svg"
  printf "threshold_v,events_sent,rate_hz,run_number,timestamp\n" >"${csv_file}"

  odb_set_str "/Scan/Threshold/State" "running"
  odb_set "/Scan/Threshold/ProgressPct" "0"
  odb_set_str "/Scan/Threshold/LastError" ""
  odb_set_str "/Scan/Threshold/ResultCsvPath" "${csv_file}"
  odb_set_str "/Scan/Threshold/ResultPlotPath" ""
  odb_set "/Scan/Threshold/Request" "0"

  mapfile -t thresholds < <(python3 - "$start_v" "$stop_v" "$step_v" <<'PY'
import sys
start, stop, step = map(float, sys.argv[1:4])
vals = []
if start <= stop:
    x = start
    while x <= stop + 1e-12:
        vals.append(x)
        x += step
else:
    x = start
    while x >= stop - 1e-12:
        vals.append(x)
        x -= step
for v in vals:
    print(f"{v:.6f}")
PY
  )
  total="${#thresholds[@]}"
  if [[ "${total}" -eq 0 ]]; then
    odb_set_str "/Scan/Threshold/State" "failed"
    odb_set_str "/Scan/Threshold/LastError" "no threshold points generated"
    continue
  fi

  ok=1
  idx=0
  for thr in "${thresholds[@]}"; do
    idx=$((idx + 1))
    pct=$(( (idx - 1) * 100 / total ))
    odb_set "/Scan/Threshold/ProgressPct" "${pct}"
    if ! run_one_threshold "$thr" "$dwell_s" "$channels_csv" "$scan_mode" "$stamp" "$idx" "$csv_file"; then
      ok=0
      break
    fi
  done

  if [[ "${ok}" == "1" ]]; then
    generate_plot_svg "${csv_file}" "${svg_file}" || true
    cp -f "${svg_file}" "${SCAN_WEB_PLOT}" || true
    odb_set_str "/Scan/Threshold/ResultPlotPath" "/custom/wc_threshold_scan_latest.svg"
    odb_set "/Scan/Threshold/ProgressPct" "100"
    odb_set_str "/Scan/Threshold/State" "done"
  else
    odb_set_str "/Scan/Threshold/State" "failed"
  fi
done
