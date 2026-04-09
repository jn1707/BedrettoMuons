#!/usr/bin/env python3
"""Minimal CLI entry point for WaveCatcher PyDAQ."""

import argparse
import json
from pathlib import Path

from wc_daq_core import DaqConfig, run_daq_session


def main() -> None:
    parser = argparse.ArgumentParser(description="Run minimal WaveCatcher DAQ session")
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--threshold", type=float, default=0.030, help="Trigger threshold [V]")
    parser.add_argument("--channel", type=int, default=0, help="WaveCatcher channel index")
    parser.add_argument("--edge", choices=["pos", "neg"], default="pos")
    parser.add_argument("--software-trigger-hz", type=float, default=0.0)
    parser.add_argument("--max-events", type=int, default=0, help="0 means run until time limit")
    parser.add_argument("--output-dir", default="/tmp/wc_pydaq_minimal")
    parser.add_argument("--lib", default=None, help="Optional explicit path to libWaveCatcher64ch_v288.so")
    args = parser.parse_args()

    cfg = DaqConfig(
        seconds=args.seconds,
        threshold_v=args.threshold,
        channel=args.channel,
        edge=args.edge,
        software_trigger_hz=args.software_trigger_hz,
        output_dir=args.output_dir,
        max_events=args.max_events,
        lib_path=args.lib,
    )
    result = run_daq_session(cfg)
    Path(args.output_dir).mkdir(parents=True, exist_ok=True)
    out_json = Path(args.output_dir) / "run_summary.json"
    out_json.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"summary_json={out_json}")


if __name__ == "__main__":
    main()
