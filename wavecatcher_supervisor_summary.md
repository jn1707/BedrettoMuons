# WaveCatcher Linux Bring-up Summary (for Supervisor)

## Context
This report summarizes the Linux-side WaveCatcher check runs performed on the laptop, compared against a known-working Windows setup. The goal was to identify why Linux scripts establish communication but measure zero rates/events.

## Hardware and Firmware Information (from Windows working logs)
- System type: 64-channel WaveCatcher (`CONTROLLER_4FE A`)
- Control board serial (USB): `1.4` / `1.4A` (seen in Linux and Windows logs)
- Firmware versions observed in Windows run log:
  - **System FPGA:** `V1-1.11`
  - **FE boards / FE blocks:** `V2-7.3` (`SAMLONG_B`)
- Calibration status in Windows run:
  - EEPROM reads successful
  - Trigger DAC offsets loaded
  - SAM DAC offsets loaded
  - Pedestal and INL calibration loaded
  - Runs started/stopped successfully

Reference file:
- `~/Documents/WaveCatcherFilesFromWindowsPC/WaveCatcher64_ch/logfile.txt`

## What Was Done on Linux

### 1) Built and organized multiple Linux library versions side-by-side
Built and installed:
- `v2.8.8` → `~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so`
- `v2.12.8` (from `Lib_for_Linux_2.13.8.zip`) → `~/.local/lib/wavecatcher/v2128/lib/libWaveCatcher64ch_v2128.so`
- `v2.14.4` → `~/.local/lib/wavecatcher/v2144/lib/libWaveCatcher64ch_v2144.so`

Per-version wrappers created:
- `~/Documents/wc_run_v288.sh`
- `~/Documents/wc_run_v2128.sh`
- `~/Documents/wc_run_v2144.sh`

These wrappers force deterministic runtime library selection and produce per-run logs.

### 2) Added dedicated diagnostics
Created/updated scripts:
- `~/Documents/wc_firmware_probe.py` (firmware/library probe + counter sanity test)
- `~/Documents/rate_monitor.py` (verbose mode + debug CSV)
- `~/Documents/threshold_sweep_coincidence.py` (verbose mode + debug CSV)
- `~/Documents/wc_ch0_rate_test.py` (single-channel CH0 rate test)
- `~/Documents/wc_internal_pulser_test.py` (internal pulser sanity test)
- `~/Documents/wc_run_compat_matrix.sh` (matrix automation)

### 3) Ran cross-version matrix tests
#### A. Initial compatibility matrix (probe/rate/sweep)
- Summary: `~/Documents/wc_matrix_results/matrix_summary_20260318_105625.csv`
- Earlier run state included `OpenDevice err=-3` across versions.

#### B. Live USB matrix with device connected (single CH0 rate)
- Summary: `~/Documents/wc_matrix_results/ch0_rate_matrix_20260318_123607.csv`
- Test points:
  - `threshold = +0.020 V`, positive edge
  - `threshold = -0.020 V`, negative edge
- Result:
  - Device opened successfully on all tested versions
  - `hits_ch0 = 0`, `rate_ch0_hz = 0.0` in all tested cases

#### C. Internal pulser sanity matrix
- Summary: `~/Documents/wc_matrix_results/pulser_matrix_20260318_123957.csv`
- Result:
  - `v2.8.8` and `v2.12.8`: `ReadRateCounters = -1`, vendor message includes **"Error : Bad target path"**
  - `v2.14.4`: pulser path hung in this specific test case (timeout logged)

## Additional Evidence from Windows-Copied Package Tree
In `~/Documents/WaveCatcherFilesFromWindowsPC/WaveCatcher_Systems/Firmware/64-channel system/`:
- `Controller_4FE_V1/CrateControl_64ch_1.10.rpd`
- `Controller_4FE_V1/CrateControl_64ch_V1-11.rpd`
- `Controller_4FE_V2/CrateControl_V2.1.5.rpd`

From software evolution notes (`Software_Evolutions_Readme.rtf`):
- Later library versions explicitly mention handling for controller-board generation updates (crate controller version 2 era), suggesting controller-generation-specific software behavior.

## Interpretation
- Data does **not** support a simple “pick an older Linux library version and it will work” conclusion.
- A pure library-version mismatch is unlikely to be the only root cause.
- Most likely issue class:
  1. **Controller/firmware-generation handling differences** between Linux stack and current hardware generation details.
  2. **Linux runtime path/transport behavior** (USB/D2XX interaction, low-level target path addressing, and possibly command path assumptions in legacy libs).

## Recommended Next Steps

### A) Recommended primary fix path (controller/firmware handling + Linux runtime transport)
1. **Freeze one Linux baseline for focused debugging:** `v2.14.4` (latest supported source available in this environment).
2. **Add low-level transaction tracing around failing calls** (`SetPulsePattern`, `StartRun`, `ReadRateCounters`) to identify where "Bad target path" originates (board target / FE path / subaddress mismatch).
3. **Cross-check runtime-selected USB stack and library dependencies per run** (confirm exact `libftd2xx`, `liblalusbmlx64`, `libudpx64` loaded in each wrapper log).
4. **Validate controller generation mapping in Linux code path** against observed hardware (`Controller_4FE`, system FPGA `V1-1.11`, FE `V2-7.3`) and ensure target routing logic matches this combination.

### B) Practical validation sequence for next session
1. Run firmware probe per version and archive logs.
2. Run CH0-only rate test at `+0.020 V` with positive edge.
3. Run CH0 threshold scan (single-channel mode) and compare time counters vs hit counters.
4. If still zero hits with nonzero time counters, perform low-level register read/write verification for trigger and rate counter paths.

### C) Firmware policy
- **No firmware update was performed.**
- Firmware upgrade/downgrade should remain a supervised decision only after software-path diagnostics above are exhausted.

## Key Artifacts
- Main report: `~/Documents/wavecatcher_compatibility_report.txt`
- This supervisor summary: `~/Documents/wavecatcher_supervisor_summary.md`
- Matrix outputs: `~/Documents/wc_matrix_results/`

