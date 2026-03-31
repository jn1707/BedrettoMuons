# Project Overview

## Purpose

This repository packages a production-oriented WaveCatcher DAQ setup around MIDAS, with:

- native C/C++ frontend integration for stable in-process hardware readout,
- guided web control via mhttpd custom page,
- optional Python DAQ/bridge tooling for compatibility and transfer workflows.

## Architecture

- **MIDAS runtime**: provides experiment state, ODB, transitions, logging, and data files.
- **Native frontend (`midas_frontend/wc_midas_frontend.cxx`)**:
  - opens/configures WaveCatcher hardware at BOR,
  - polls/decodes events and writes MIDAS banks (`WCHD`, `WCFE`, `WCWF`),
  - supports auto-stop on duration or target decoded event count,
  - publishes run summary and live waveform preview metadata to ODB.
- **Custom page (`custom/wc_control.html`)**:
  - applies guided ODB settings,
  - controls run transitions,
  - shows live/last-run status,
  - renders live waveform preview (multi-channel overlay + legend).
- **Python tooling (`python_daq/`)**:
  - DAQ service/client/bridge scripts for alternate workflows and compatibility checks.

## Key ODB surfaces

- `/Equipment/WaveCatcher/Variables/*`: operator configuration values.
- `/Equipment/WaveCatcher/Statistics/*`: live counters.
- `/Equipment/WaveCatcher/RunSummary/*`: persisted last-run metrics + applied config.
- `/Equipment/WaveCatcher/Live/*`: preview waveform payload/metadata for web UI.

## Operational workflow

1. Configure channels/trigger/stop mode from custom page.
2. Apply to ODB.
3. Start run.
4. Monitor live status and waveform overlay.
5. Stop manually anytime (always interruptible) or let auto-stop trigger.
6. Use summary + transfer helper for post-run handling.
