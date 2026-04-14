#!/usr/bin/env bash
set -euo pipefail

# Tomorrow hardware test:
# Reproduce/triage BOR behavior with readiness-gated MIDAS run and parity test output.

ROOT="/home/morenoma/BedrettoMuons_work"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="/tmp/wc_bor_repro_${STAMP}"
mkdir -p "$OUT"

echo "Output dir: $OUT"

echo "[1/6] Build frontend"
cd "$ROOT/midas_frontend"
if ! make >"$OUT/make.log" 2>&1; then
  echo "Build failed; continuing with existing binaries" | tee -a "$OUT/make.log"
fi

echo "[2/6] Start stack"
cd "$ROOT"
scripts/wc_start_midas_stack.sh >"$OUT/start_stack.log" 2>&1 || true

echo "[3/6] Check BOR health"
scripts/wc_check_bor_health.sh >"$OUT/bor_health_before.txt" 2>&1 || true

echo "[4/6] Run parity test (python-like vs bor-like in one process)"
scripts/wc_run_v288.sh python3 "$ROOT/scripts/wc_bor_python_parity_test.py" \
  --threshold 0.020 --edge pos --duration 3 --out "$OUT/parity.json" \
  >"$OUT/parity.log" 2>&1 || true

echo "[5/6] Try MIDAS run via readiness-gated CLI"
scripts/wc_run_midas_cli.sh \
  --duration 5 --triggermode normal --edge pos --threshold 0.020 --channels 0 --start-retries 3 \
  >"$OUT/midas_cli.log" 2>&1 || true

echo "[6/6] Capture post-run health + relevant logs"
scripts/wc_check_bor_health.sh >"$OUT/bor_health_after.txt" 2>&1 || true
tail -n 300 /home/morenoma/online_wc/midas.log >"$OUT/midas_tail.log" 2>/dev/null || true
tail -n 200 /home/morenoma/online_wc/wc_midas_frontend.log >"$OUT/frontend_tail.log" 2>/dev/null || true
echo "$OUT" > /tmp/wc_bor_last_outdir.txt

echo "Done. Collected artifacts in: $OUT"
echo "Key files:"
echo "  $OUT/parity.json"
echo "  $OUT/midas_cli.log"
echo "  $OUT/bor_health_before.txt"
echo "  $OUT/bor_health_after.txt"
echo "  $OUT/midas_tail.log"
