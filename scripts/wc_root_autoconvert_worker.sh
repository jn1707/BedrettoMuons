#!/usr/bin/env bash
set -euo pipefail

WATCH_DIR="${WC_ROOT_AUTOCONVERT_WATCH_DIR:-/home/morenoma/online_wc}"
CONVERTER="${WC_ROOT_CONVERTER_SCRIPT:-/home/morenoma/online_wc/scripts/wc_convert_mid_to_root.sh}"
STATE_FILE="${WC_ROOT_AUTOCONVERT_STATE_FILE:-/tmp/wc_root_autoconvert_last_run.txt}"
LOG_FILE="${WC_ROOT_AUTOCONVERT_LOG:-/home/morenoma/online_wc/wc_root_autoconvert_worker.log}"
MAX_EVENTS="${WC_ROOT_CONVERT_MAX_EVENTS:-5000000}"
SLEEP_S="${WC_ROOT_AUTOCONVERT_POLL_S:-3}"
SETTLE_S="${WC_ROOT_AUTOCONVERT_SETTLE_S:-5}"

if [[ ! -x "${CONVERTER}" ]]; then
  echo "[$(date -Iseconds)] converter not executable: ${CONVERTER}" >> "${LOG_FILE}"
  exit 1
fi

last_run=""
if [[ -f "${STATE_FILE}" ]]; then
  last_run="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

echo "[$(date -Iseconds)] root autoconvert worker started" >> "${LOG_FILE}"

while true; do
  latest_mid="$(ls -1t "${WATCH_DIR}"/run*.mid.lz4 2>/dev/null | head -n 1 || true)"
  if [[ -n "${latest_mid}" ]]; then
    run_base="${latest_mid%.mid.lz4}"
    run_num="$(basename "${run_base}")"
    out_root="${run_base}.root"
    done_marker="${run_base}.root.done"
    running_state="$(odbedit -q -e wavecatcher -c "ls '/Runinfo/State'" 2>/dev/null | awk '/^State/ {print $NF; exit}' || true)"

    if [[ "${run_num}" != "${last_run}" && "${running_state:-}" != "3" ]]; then
      if [[ -f "${out_root}" && -f "${done_marker}" ]]; then
        last_run="${run_num}"
        echo "${last_run}" > "${STATE_FILE}"
      else
        sleep "${SETTLE_S}"
        tmp_log="/tmp/wc_root_convert_${run_num}_$$.log"
        if "${CONVERTER}" --input "${latest_mid}" --output "${out_root}" --max-events "${MAX_EVENTS}" > "${tmp_log}" 2>&1; then
          cat "${tmp_log}" >> "${LOG_FILE}"
          scanned="$(awk '/Converted MIDAS events:/ {print $7}' "${tmp_log}" | tail -n 1 || true)"
          if [[ "${scanned:-0}" == "0" ]]; then
            rm -f "${out_root}"
            echo "[$(date -Iseconds)] conversion deferred (scanned=0) for ${latest_mid}" >> "${LOG_FILE}"
            rm -f "${tmp_log}"
            sleep "${SLEEP_S}"
            continue
          fi
          date -Iseconds > "${done_marker}"
          last_run="${run_num}"
          echo "${last_run}" > "${STATE_FILE}"
          echo "[$(date -Iseconds)] converted ${latest_mid} -> ${out_root}" >> "${LOG_FILE}"
        else
          cat "${tmp_log}" >> "${LOG_FILE}" 2>/dev/null || true
          echo "[$(date -Iseconds)] conversion failed for ${latest_mid}" >> "${LOG_FILE}"
        fi
        rm -f "${tmp_log}"
      fi
    fi
  fi
  sleep "${SLEEP_S}"
done
