# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

WaveCatcher + MIDAS DAQ integration for the Bedretto muon detector. The native C++ MIDAS frontend is the production readout path; Python tooling and shell scripts support auxiliary workflows.

All runtime paths (`/home/morenoma/...`) refer to the DAQ host (Linux). Development on macOS is for editing only — build and run on the DAQ host.

## Build

```bash
cd midas_frontend && make
```

Requires `MIDAS_INC`, `MIDAS_LIB`, `WC_INC_DIR`, and `WC_LIB_DIR` (or the Makefile defaults which point to `~/packages/midas` and `~/.local/lib/wavecatcher/v288/lib`). To override:

```bash
make MIDAS_INC=/path/to/midas/include MIDAS_LIB=/path/to/midas/lib
```

Artifacts built: `wc_midas_frontend`, `wc_test_harness`, `wc_api_smoke_test`, `wc_device_server`, `wc_majority_test`.

## Start the DAQ stack

```bash
scripts/wc_start_midas_stack.sh
```

This kills any previous stack, then starts: `mserver` → `mhttpd` (local mode — **do not** use `-h localhost:1175`, it crashes `cm_get_path()`) → `mlogger` → hardware preflight → `wc_midas_frontend`. Optional workers enabled by env vars:

| Variable | Default | Effect |
|---|---|---|
| `WC_ENABLE_SCAN_WORKER` | `1` | threshold scan worker |
| `WC_ENABLE_ROOT_AUTOCONVERT` | `1` | auto-converts `.mid.lz4` to ROOT after each run |
| `WC_ENABLE_PY_BRIDGE` | `0` | Python DAQ bridge service |

MIDAS watchdog/transition timeouts are widened at startup to tolerate slow `OpenDevice` (USB warm-up).

## ROOT conversion

```bash
source scripts/wc_setup_root_env.sh
scripts/wc_convert_mid_to_root.sh --input /home/morenoma/online_wc/run02429.mid.lz4
```

The converter (`scripts/wc_mid_to_root.cxx`) is compiled on demand into `~/.cache/bedrettomuons/wc_mid_to_root.exe`. It requires `tools/rootana/midasio/` sources (rootana). Output TTree `wc_events` schema: see README.

## Architecture

### MIDAS frontend (`midas_frontend/wc_midas_frontend.cxx`)

MIDAS polled equipment (`EQ_POLLED`, event ID 1201, name `"WaveCatcher"`).

**Device lifecycle:** `OpenDevice` runs in `frontend_init` (not BOR), with a 10 s settle after `ResetDevice`. Device stays open between runs — only closed at `frontend_exit`. BOR calls `ResetDevice` + `SetDefaultParameters` again as a baseline reset before applying settings.

**ODB settings flow:** All run parameters live under `/Equipment/WaveCatcher/Variables/`. BOR calls `load_settings_from_odb()` → `wc_apply_run_configuration()` which issues `SetChannelState`, `SetTriggerSourceState`, `SetTriggerEdge`, `SetTriggerThreshold`, `SetTriggerMode`, `PrepareEvent` per active channel. Mode 2 uses `TRIGGER_COINCIDENCE` (primary+partner); mode 3 uses `TRIGGER_MAJORITY` on selected channels (≥3 required). Idle hardware reset is available via ODB `device_reset_request` from the control page.

**Readout loop:** `poll_event` calls `ReadEventBuffer`; on success sets `g_event_in_buffer`. `read_wavecatcher_event` calls `DecodeEvent` then `ReadChannelDataStruct` per channel, writing three MIDAS banks:
- `WCHD` (`DWORD[4]`): EventID, TDC\_low, TDC\_high, channel\_count
- `WCFE` (`float[]`): 6 floats per channel — channel\_id, trig\_count, time\_count, baseline, peak, charge
- `WCWF` (`float[]`): per-channel waveforms — channel\_id, n\_samples, sample[0..n-1]

**Thread safety:** `g_wc_api_mutex` (recursive) guards all WaveCatcher API calls. `TransitionGuard` (atomic bool) prevents overlapping BOR/EOR.

**Auto-stop:** `frontend_loop` calls `cm_transition(TR_STOP)` when duration (mode 1) or decoded-event count (mode 2) target is reached.

**Live/analysis ODB publishing:**
- `/Equipment/WaveCatcher/Live/`: waveform preview (up to 6 channels, 128 samples, 1 Hz)
- `/Analysis/Global/`: event rate, decoded count, run seconds
- `/Analysis/Channels/Ch%02d/`: per-channel rate, peak, charge, baseline
- `/Scan/Threshold/`: threshold scan state (driven by `wc_threshold_scan_worker.sh`)

### Custom web UI (`custom/`)

Three mhttpd custom pages (`wc_control.html`, `wc_monitoring.html`, `wc_summary.html`) talk to MIDAS via the mhttpd AJAX API (same origin). The control page reads/writes ODB keys, then `applyConfig()` pushes to `/Equipment/WaveCatcher/Variables/` before `startRunSafe()`. Channel selector buttons populate `enabled_channels_csv`. Apply buttons are cumulative — mode/edge/threshold/channels can be set independently before starting.

### Python DAQ core (`wc_daq_core.py`)

Thin `ctypes` wrapper around `libWaveCatcher64ch_v288.so`. Mirrors the C++ API sequence: `OpenDevice` → `ResetDevice` → `SetDefaultParameters` → channel/trigger config → `PrepareEvent` → `AllocateEventStructure` → `StartRun` → read/decode loop → `StopRun` / `FreeEventStructure` / `CloseDevice`. Library resolved via `WC_LIB_PATH` env var, then `~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so`. Entry point: `run_daq.py`.

### Key ODB paths

```
/Equipment/WaveCatcher/Variables/   — operator config (trigger mode/edge, channels CSV, thresholds, auto-stop)
/Equipment/WaveCatcher/RunSummary/  — persisted last-run metrics
/Equipment/WaveCatcher/Live/        — preview waveform payload for web UI
/Analysis/Global/                   — live event rate, decoded count
/Analysis/Channels/Ch%02d/          — per-channel live stats
/Scan/Threshold/                    — threshold scan request/state/progress
/UI/Dashboard/                      — web UI preferences
```

### Trigger mode encoding (ODB `trigger_mode`)

| Value | Mode |
|---|---|
| 0 | Normal (hardware threshold) |
| 1 | Software trigger at `sw_trigger_hz` |
| 2 | Coincidence (primary + `coincidence_channel`) |
| 3 | Majority (≥3 channels via `enabled_channels_csv`) |

Applied hardware mode is also published as `applied_trigger_mode` / `applied_trigger_mode_str` under `/Equipment/WaveCatcher/Variables/`.

### Auto-stop mode encoding (ODB `auto_stop_mode`)

| Value | Behaviour |
|---|---|
| 0 | None (manual stop only) |
| 1 | Stop after `run_duration_s` seconds |
| 2 | Stop after `target_event_count` decoded events |
