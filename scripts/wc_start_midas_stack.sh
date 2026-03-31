#!/usr/bin/env bash
set -euo pipefail
export MIDASSYS=/home/morenoma/packages/midas
export MIDAS_EXPTAB=/home/morenoma/online_wc/exptab
export MIDAS_EXPT_NAME=wavecatcher
export MIDAS_DIR=/home/morenoma/online_wc
export PATH=/home/morenoma/packages/midas/bin:$PATH

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
      fi
    done <<< "${pids}"
    sleep 1
  fi
}

# Clean previous stack started via this launcher to avoid duplicate processes/ports.
stop_pid_file /tmp/wc_midas_bridge.pid
stop_pid_file /tmp/wc_daq_service.pid
stop_pid_file /tmp/wc_midas_mserver.pid
stop_pid_file /tmp/wc_midas_mhttpd.pid
stop_pid_file /tmp/wc_midas_frontend.pid
stop_matching_cmd "/home/morenoma/Documents/wc_midas_bridge.py --poll 1.0"
stop_matching_cmd "/home/morenoma/Documents/wc_daq/service.py"
stop_matching_cmd "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher -h localhost:1175"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist"
stop_matching_cmd "/home/morenoma/packages/midas/bin/mserver -e wavecatcher"

# Start mserver.
/home/morenoma/packages/midas/bin/mserver -e wavecatcher > /home/morenoma/online_wc/mserver_live.log 2>&1 &
MSERVER_PID=$!
echo "${MSERVER_PID}" > /tmp/wc_midas_mserver.pid
sleep 1

# Start mhttpd daemon.
# NOTE: On this MIDAS build, using "-h localhost:1175" makes mhttpd crash on first page request
# (cm_get_path() assertion). Running in local experiment mode is stable.
/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist > /home/morenoma/online_wc/mhttpd.log 2>&1
sleep 1
MHTTPD_PID="$(pgrep -f '/home/morenoma/packages/midas/bin/mhttpd -D -e wavecatcher --no-passwords --no-hostlist' | head -n 1 || true)"
if [[ -n "${MHTTPD_PID}" ]]; then
  echo "${MHTTPD_PID}" > /tmp/wc_midas_mhttpd.pid
fi

# Start WaveCatcher MIDAS frontend (direct hardware readout path)
if pgrep -f "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend.*-e wavecatcher" >/dev/null 2>&1; then
  FRONTEND_PID="$(pgrep -f "/home/morenoma/online_wc/midas_frontend/wc_midas_frontend.*-e wavecatcher" | head -n 1)"
else
  /home/morenoma/online_wc/midas_frontend/wc_midas_frontend -D -e wavecatcher > /home/morenoma/online_wc/wc_midas_frontend.log 2>&1 &
  FRONTEND_PID=$!
fi
echo "${FRONTEND_PID}" > /tmp/wc_midas_frontend.pid

# Start DAQ service
python3 /home/morenoma/Documents/wc_daq/service.py > /home/morenoma/online_wc/wc_daq_service.log 2>&1 &
DAQ_PID=$!
echo "${DAQ_PID}" > /tmp/wc_daq_service.pid

# Start MIDAS bridge (hardware by default; add --mock-mode if desired)
python3 /home/morenoma/Documents/wc_midas_bridge.py --poll 1.0 > /home/morenoma/online_wc/wc_midas_bridge.log 2>&1 &
BRIDGE_PID=$!
echo "${BRIDGE_PID}" > /tmp/wc_midas_bridge.pid

echo "Started: mserver=${MSERVER_PID} mhttpd=${MHTTPD_PID:-unknown} frontend=${FRONTEND_PID} daq=${DAQ_PID} bridge=${BRIDGE_PID}"
if curl -sS -o /dev/null http://127.0.0.1:8080; then
  echo "Web OK: http://127.0.0.1:8080"
else
  echo "Web NOT reachable on http://127.0.0.1:8080"
  echo "Check log: /home/morenoma/online_wc/mhttpd.log"
fi
