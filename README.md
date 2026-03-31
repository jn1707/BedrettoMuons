# BedrettoMuons

Custom MIDAS + WaveCatcher integration for Bedretto Muons DAQ, including:

- Native C/C++ MIDAS frontend (`midas_frontend/`) linked to WaveCatcher Linux library.
- Guided mhttpd custom page (`custom/wc_control.html`) for run control and live monitoring.
- Python DAQ/bridge tooling (`python_daq/`) for compatibility workflows and transfer utilities.
- Operator scripts (`scripts/`) for stack startup and CLI-driven runs.

## Repository layout

- `midas_frontend/`: native frontend, test harness, build rules.
- `custom/`: custom mhttpd control page.
- `scripts/`: practical run/start scripts used on the DAQ host.
- `python_daq/`: Python DAQ service/client/bridge components.
- `docs/`: compatibility report and technical notes.

## Native MIDAS + WaveCatcher quick start

1. Build frontend:
   - `cd midas_frontend && make`
2. Ensure MIDAS and WaveCatcher libs are visible in environment (`MIDASSYS`, `LD_LIBRARY_PATH`, etc.).
3. Start MIDAS services and frontend (or use `scripts/wc_start_midas_stack.sh`).
4. Open mhttpd and use `WaveCatcher Control` custom page to configure/start/stop runs.

## Web control capabilities (current)

- Trigger mode selection (normal/software/coincidence).
- Per-run channel selection (CSV + primary channel fallback).
- Single-threshold apply workflow for iterative channel tuning.
- Auto-stop mode selection (duration XOR target decoded event count).
- Live status panel, last-run summary, transfer command helper, and live waveform preview with multi-channel overlay legend.

## Python DAQ branch

A dedicated branch `python-daq` is used to emphasize Python-based DAQ/bridge workflow.  
Core files are under `python_daq/` and can be used independently of native frontend development.

## Notes

- Runtime data/log artifacts are intentionally excluded via `.gitignore`.
- This repository is structured for outsiders to reproduce setup and understand system components without local legacy clutter.
