# BedrettoMuons (midas-minimal branch)

This branch tracks only files currently used to operate the live WaveCatcher MIDAS DAQ.

## Tracked operational components

- `midas_frontend/`
  - `wc_midas_frontend.cxx`
  - `Makefile`
- `custom/`
  - `wc_control.html`
  - `wc_monitoring.html`
  - `wc_summary.html`
  - `messages.js`
  - `spinning-wheel.gif`
- `scripts/`
  - `wc_start_midas_stack.sh`
  - `wc_threshold_scan_worker.sh`
  - `wc_root_autoconvert_worker.sh`
  - `wc_convert_mid_to_root.sh`
  - `wc_mid_to_root.cxx`
  - `wc_setup_root_env.sh`
  - `wc_run_midas_cli.sh`

## Quick run path

1. Build frontend: `cd midas_frontend && make`
2. Start stack: `scripts/wc_start_midas_stack.sh`
3. Open mhttpd: `/custom/wc_control.html`
