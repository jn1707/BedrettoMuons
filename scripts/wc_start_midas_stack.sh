#!/usr/bin/env bash
set -euo pipefail
export MIDASSYS=/home/morenoma/packages/midas
export MIDAS_EXPTAB=/home/morenoma/online_wc/exptab
export MIDAS_EXPT_NAME=wavecatcher
export MIDAS_DIR=/home/morenoma/online_wc
export PATH=/home/morenoma/packages/midas/bin:$PATH
export LD_LIBRARY_PATH=/home/morenoma/.local/lib/wavecatcher/v288/lib:/usr/local/lib64
ENABLE_PY_BRIDGE="${WC_ENABLE_PY_BRIDGE:-0}"
ENABLE_SCAN_WORKER="${WC_ENABLE_SCAN_WORKER:-1}"
WC_DISABLE_CUSTOM_CONTROL="${WC_DISABLE_CUSTOM_CONTROL:-0}"
WC_WD_STARTUP_MS="${WC_WD_STARTUP_MS:-300000}"
WC_TR_CONNECT_STARTUP_MS="${WC_TR_CONNECT_STARTUP_MS:-300000}"
WC_TR_TOTAL_STARTUP_MS="${WC_TR_TOTAL_STARTUP_MS:-420000}"

set_timeout_profile() {
  local wd_ms="$1"
  local tr_connect_ms="$2"
  local tr_total_ms="$3"
  odbedit -e wavecatcher -c "set '/Programs/WaveCatcher Frontend/Watchdog timeout' ${wd_ms}" >/dev/null 2>&1 || true
  odbedit -e wavecatcher -c "set '/Experiment/Transition connect timeout' ${tr_connect_ms}" >/dev/null 2>&1 || true
  odbedit -e wavecatcher -c "set '/Experiment/Transition timeout' ${tr_total_ms}" >/dev/null 2>&1 || true
}

log_timeout_snapshot() {
  local tag="$1"
  {
    echo "=== ${tag} $(date -Iseconds) ==="
    odbedit -e wavecatcher -c "ls '/Programs/WaveCatcher Frontend/Watchdog timeout'" 2>/dev/null || true
    odbedit -e wavecatcher -c "ls '/Experiment/Transition connect timeout'" 2>/dev/null || true
    odbedit -e wavecatcher -c "ls '/Experiment/Transition timeout'" 2>/dev/null || true
  } >> /tmp/wc_timeout_profile.log
}

stop_pid_file() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      kill "${old_pid}" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pid_file"
  fi
}

stop_matching_cmd() {
  local pattern="$1"
  local pids
  pids="$(pgrep -f "$pattern" || true)"
  if [[ -n "${pids}" ]]; then
    while IFS= read -r pid; do
      if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
        sleep 1
        if kill -0 "${pid}" 2>/dev/null; then
          kill -9 "${pid}" 2>/dev/null || true
        fi
      fi
    done <<< "${pids}"
    sleep 1
  fi
}

# Clean previous stack started via this launcher to avoid duplicate processes/ports.
stop_pid_file /tmp/wc_midas_mserver.pid
stop_pid_file /tmp/wc_midas_mhttpd.pid
stop_pid_file /tmp/wc_midas_mlogger.pid
stop_pid_file /tmp/wc_midas_frontend.pid
# Python bridge/service are optional and disabled by default.
stop_pid_file /tmp/wc_midas_bridge.pid
stop_pid_file /tmp/wc_daq_service.pid
stop_pid_file /tmp/wc_threshold_scan_worker.pid
stop_matching_cmd "/home/morenoma/Documents/wc_midas_bridge.py --poll 1.0"
stop_matching_cmd "/home/morenoma/Documents/wc_daq/service.py"
stop_matching_cmd "/home/morenoma/online_wc/scripts/wc_threshold_scan_worker.sh"
stop_matching_cmd "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend"
stop_matching_cmd "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend -D -e wavecatcher"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher -h localhost:1175"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mserver -e wavecatcher"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mlogger -e wavecatcher"

# Start mserver.
/home/morenoma/packages/midas/bin/mserver -e wavecatcher > /home/morenoma/online_wc/mserver_live.log 2>&1 &
MSERVER_PID=$!
echo "${MSERVER_PID}" > /tmp/wc_midas_mserver.pid
sleep 1

# Startup/BOR profile: permissive to tolerate OpenDevice stalls.
set_timeout_profile "${WC_WD_STARTUP_MS}" "${WC_TR_CONNECT_STARTUP_MS}" "${WC_TR_TOTAL_STARTUP_MS}"
log_timeout_snapshot "startup-profile"

# Start mhttpd daemon.
# NOTE: On this MIDAS build, using "-h localhost:1175" makes mhttpd crash on first page request
# (cm_get_path() assertion). Running in local experiment mode is stable.
/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist > /home/morenoma/online_wc/mhttpd.log 2>&1
sleep 1
MHTTPD_PID="$(pgrep -f '/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist' | head -n 1 || true)"
if [[ -n "${MHTTPD_PID}" ]]; then
  echo "${MHTTPD_PID}" > /tmp/wc_midas_mhttpd.pid
fi

# Start mlogger so run files are written to disk.
setsid /home/morenoma/packages/midas/bin/mlogger -e wavecatcher > /home/morenoma/online_wc/mlogger_live.log 2>&1 < /dev/null &
MLOGGER_PID=$!
echo "${MLOGGER_PID}" > /tmp/wc_midas_mlogger.pid
sleep 1
if ! kill -0 "${MLOGGER_PID}" 2>/dev/null; then
  echo "WARNING: mlogger failed to stay alive."
  tail -n 80 /home/morenoma/online_wc/mlogger_live.log 2>/dev/null || true
fi

# Hardware preflight first: warm up USB/library path before frontend transition callbacks.
if [[ -x /home/morenoma/Documents/wc_run_v288.sh ]] && [[ -f /home/morenoma/Documents/wc_capture_waveforms_png.py ]]; then
  PREFLIGHT_DIR="/tmp/wc_preflight_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${PREFLIGHT_DIR}"
  if timeout 25 /home/morenoma/Documents/wc_run_v288.sh python3 -u /home/morenoma/Documents/wc_capture_waveforms_png.py \
      --seconds 0.8 --threshold 0.05 --edge pos --accept-mv 5 --max-save 1 --output-dir "${PREFLIGHT_DIR}" \
      >/tmp/wc_preflight.log 2>&1; then
    echo "Preflight OK (WaveCatcher library/open path responsive)."
  else
    echo "WARNING: Preflight did not complete successfully."
    echo "  Check: /tmp/wc_preflight.log"
    echo "  START may fail if hardware open is still blocked."
  fi
fi

# Manage custom wc_control page availability.
if [[ "${WC_DISABLE_CUSTOM_CONTROL}" == "1" ]]; then
  if [[ -f /home/morenoma/online_wc/custom/wc_control.html ]] && [[ ! -f /home/morenoma/online_wc/custom/wc_control.html.disabled ]]; then
    mv /home/morenoma/online_wc/custom/wc_control.html /home/morenoma/online_wc/custom/wc_control.html.disabled
    echo "Custom wc_control page disabled (CLI-only mode)."
  fi
else
  if [[ -f /home/morenoma/online_wc/custom/wc_control.html.disabled ]] && [[ ! -f /home/morenoma/online_wc/custom/wc_control.html ]]; then
    mv /home/morenoma/online_wc/custom/wc_control.html.disabled /home/morenoma/online_wc/custom/wc_control.html
    echo "Custom wc_control page enabled."
  fi
fi

# Start WaveCatcher MIDAS frontend (direct hardware readout path).
# Use setsid to keep non-daemon frontend alive after launcher exits.
setsid /home/morenoma/online_wc/midas_frontend/wc_midas_frontend -e wavecatcher > /home/morenoma/online_wc/wc_midas_frontend.log 2>&1 < /dev/null &
FRONTEND_PID=$!
sleep 1
if ! kill -0 "${FRONTEND_PID}" 2>/dev/null; then
  echo "ERROR: wc_midas_frontend failed to stay alive"
  echo "Last frontend log lines:"
  tail -n 120 /home/morenoma/online_wc/wc_midas_frontend.log 2>/dev/null || true
  exit 1
fi
echo "${FRONTEND_PID}" > /tmp/wc_midas_frontend.pid

# Clear stale transition lock if any before first run request.
TRANSITION_IN_PROGRESS="$(odbedit -e wavecatcher -c \"ls '/Runinfo/Transition in progress'\" 2>/dev/null | awk '/Transition in progress/ {print $NF}' || true)"
if [[ "${TRANSITION_IN_PROGRESS:-0}" != "0" ]]; then
  odbedit -e wavecatcher -c "set '/Runinfo/Transition in progress' 0" >/dev/null 2>&1 || true
fi

# If previous session left run in RUNNING state, force STOP once so next START is deterministic.
RUN_STATE="$(odbedit -e wavecatcher -c \"ls '/Runinfo/State'\" 2>/dev/null | awk '/^State/ {print $NF; exit}' || true)"
if [[ "${RUN_STATE:-}" == "3" ]]; then
  timeout 25 mtransition -e wavecatcher STOP >/tmp/wc_stack_forced_stop.log 2>&1 || true
fi

if [[ "${ENABLE_PY_BRIDGE}" == "1" ]]; then
  python3 /home/morenoma/Documents/wc_daq/service.py > /home/morenoma/online_wc/wc_daq_service.log 2>&1 &
  DAQ_PID=$!
  echo "${DAQ_PID}" > /tmp/wc_daq_service.pid
  python3 /home/morenoma/Documents/wc_midas_bridge.py --poll 1.0 > /home/morenoma/online_wc/wc_midas_bridge.log 2>&1 &
  BRIDGE_PID=$!
  echo "${BRIDGE_PID}" > /tmp/wc_midas_bridge.pid
  echo "Started: mserver=${MSERVER_PID} mhttpd=${MHTTPD_PID:-unknown} frontend=${FRONTEND_PID} daq=${DAQ_PID} bridge=${BRIDGE_PID}"
else
  echo "Started: mserver=${MSERVER_PID} mhttpd=${MHTTPD_PID:-unknown} mlogger=${MLOGGER_PID} frontend=${FRONTEND_PID} (python bridge/service disabled)"
fi

if [[ "${ENABLE_SCAN_WORKER}" == "1" ]]; then
  setsid /home/morenoma/online_wc/scripts/wc_threshold_scan_worker.sh > /home/morenoma/online_wc/wc_threshold_scan_worker.log 2>&1 < /dev/null &
  SCAN_WORKER_PID=$!
  echo "${SCAN_WORKER_PID}" > /tmp/wc_threshold_scan_worker.pid
  echo "Threshold scan worker started: pid=${SCAN_WORKER_PID}"
fi

if curl -sS -o /dev/null http://127.0.0.1:8080; then
  echo "Web OK: http://127.0.0.1:8080"
else
  echo "Web NOT reachable on http://127.0.0.1:8080"
  echo "Check log: /home/morenoma/online_wc/mhttpd.log"
fi
