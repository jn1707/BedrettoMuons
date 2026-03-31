# Python DAQ Workflow

This branch includes the Python-oriented DAQ service, client, transfer helper, and MIDAS bridge helpers.

## Components

- `python_daq/wc_daq/service.py`: DAQ service entrypoint.
- `python_daq/wc_daq/backend.py`: hardware/mock backend logic.
- `python_daq/wc_daq/pngplot.py`: waveform PNG rendering helpers.
- `python_daq/wc_daq_client.py`: client-side control utility.
- `python_daq/wc_daq_transfer.py`: run transfer and checksum utility.
- `python_daq/wc_midas_bridge.py`: MIDAS transition bridge utility.
- `python_daq/wc_capture_waveforms_png.py`: direct capture utility.

## Typical flow

1. Start DAQ service.
2. Configure and start run through client or bridge.
3. Monitor status and collect generated artifacts.
4. Transfer run outputs with checksum verification.

## Notes

- This branch complements native frontend development; keep production runtime decisions explicit in site docs.
- Runtime data outputs should remain untracked.
