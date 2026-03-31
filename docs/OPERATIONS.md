# Operations Guide

## Prerequisites

- MIDAS installed and usable (`mserver`, `mlogger`, `mhttpd`, `odbedit`, `mtransition`).
- WaveCatcher shared libraries installed and resolvable by dynamic linker.
- Experiment directory/environment configured on DAQ host.

## Build native frontend

```bash
cd midas_frontend
make
```

## Start stack

Use your local startup method, or adapt:

```bash
scripts/wc_start_midas_stack.sh
```

## Configure and run from web UI

1. Open mhttpd custom page: `WaveCatcher Control`.
2. Set:
   - trigger mode/edge,
   - primary + selected channels CSV,
   - threshold,
   - auto-stop mode.
3. Click **Apply to ODB**.
4. Click **Start**.
5. Observe:
   - run live status,
   - waveform overlay preview with channel legend.
6. Click **Stop** any time if needed.

## Auto-stop semantics

- Mode `None`: no automatic stop.
- Mode `Duration`: stop after configured seconds.
- Mode `Event count`: stop after decoded event target.
- UI enforces duration XOR event count.

## Data transfer helper

The custom page provides an `scp` command generator for the last run file.  
Run the generated command on the DAQ host terminal.

## Troubleshooting

- If custom page is unavailable, verify mhttpd/custom page path and MIDAS process health.
- If no events arrive, check trigger mode/threshold/channel configuration and hardware connectivity.
- If preview is empty, verify run is active and frontend is publishing `/Equipment/WaveCatcher/Live/*`.
