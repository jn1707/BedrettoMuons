# MIDAS BOR Debugging (WaveCatcher)

This note documents the START/BOR failure mode where MIDAS reports:

- `previous transition did not finish yet`
- `cm_transition() status 603`

## Root cause

`WAVECAT64CH_OpenDevice()` can block unpredictably in FTDI/libusb internals.
If called inside BOR transition callback, MIDAS transition RPC can stall.

## Current mitigation design

- Device open moved **out of BOR** into async worker at frontend startup.
- BOR fails fast if hardware not yet ready (no transition wedge).
- Readiness is published to ODB:
  - `/Equipment/WaveCatcher/Variables/device_open_state`
  - `/Equipment/WaveCatcher/Variables/device_open_state_str`
  - values: `idle|in_progress|ready|failed|timed_out`

## Quick triage

1. Start stack:
   - `scripts/wc_start_midas_stack.sh`
2. Check readiness/state:
   - `scripts/wc_check_bor_health.sh`
3. Attempt run with retries:
   - `scripts/wc_run_midas_cli.sh --duration 10 --triggermode normal --edge pos --threshold 0.020 --channels 0 --start-retries 3`

## Interpretation

- `device_open_state=2` (`ready`): START should proceed.
- `in_progress`: wait and retry, do not hammer transitions.
- `failed/timed_out`: restart frontend (or stack) and re-attempt.

## Useful logs

- MIDAS log: `~/online_wc/midas.log`
- Frontend log: `~/online_wc/wc_midas_frontend.log`

Filter examples:

```bash
tail -n 200 ~/online_wc/midas.log | grep -E "WaveCatcher Frontend|begin_of_run|transition|status 603|previous transition"
```

