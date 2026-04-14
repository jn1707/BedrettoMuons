#!/usr/bin/env python3
"""
Hardware test for tomorrow: compare "Python DAQ sequence" with "MIDAS-BOR-like sequence"
inside one standalone process, with per-call timing.

Goal:
- Detect subtle API ordering/parameter differences.
- Measure where latency appears (especially OpenDevice).
- Produce machine-readable output for side-by-side comparison.
"""

import argparse
import ctypes
import json
import os
import time
from dataclasses import dataclass, asdict
from typing import Optional


SUCCESS = 0
FRONT = 0
ON = 1
TRIG_NORMAL = 1
TRIG_SOFT = 0


@dataclass
class CallResult:
    name: str
    rc: int
    dt_ms: float


def pick_library(explicit: Optional[str]) -> str:
    if explicit and os.path.exists(explicit):
        return explicit
    env = os.environ.get("WC_LIB_PATH")
    if env and os.path.exists(env):
        return env
    default = os.path.expanduser("~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so")
    if os.path.exists(default):
        return default
    raise FileNotFoundError("WaveCatcher v288 library not found")


def timed_call(name, fn):
    t0 = time.perf_counter()
    rc = int(fn())
    dt = (time.perf_counter() - t0) * 1000.0
    return CallResult(name=name, rc=rc, dt_ms=dt)


def run_sequence(lib, mode: str, threshold: float, edge: str, sw_hz: float, duration_s: float):
    results = []
    handle = ctypes.c_int(-1)

    # 1) Open + baseline init
    results.append(
        timed_call("OpenDevice", lambda: lib.WAVECAT64CH_OpenDevice(ctypes.byref(handle)))
    )
    if results[-1].rc != SUCCESS:
        return results

    results.append(timed_call("ResetDevice", lib.WAVECAT64CH_ResetDevice))
    results.append(timed_call("SetDefaultParameters", lib.WAVECAT64CH_SetDefaultParameters))

    # 2) Configure (Python-like vs BOR-like only differs in how we structure flow)
    trig_edge = 0 if edge == "pos" else 1
    trig_mode = TRIG_SOFT if (mode == "soft" or sw_hz > 0) else TRIG_NORMAL

    results.append(
        timed_call(
            "SetChannelState(ch0)",
            lambda: lib.WAVECAT64CH_SetChannelState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON)),
        )
    )
    results.append(
        timed_call(
            "SetTriggerSourceState(ch0)",
            lambda: lib.WAVECAT64CH_SetTriggerSourceState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON)),
        )
    )
    results.append(
        timed_call(
            "SetTriggerEdge(ch0)",
            lambda: lib.WAVECAT64CH_SetTriggerEdge(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(trig_edge)),
        )
    )
    results.append(
        timed_call(
            "SetTriggerThreshold(ch0)",
            lambda: lib.WAVECAT64CH_SetTriggerThreshold(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_float(threshold)),
        )
    )
    results.append(
        timed_call("SetTriggerMode", lambda: lib.WAVECAT64CH_SetTriggerMode(ctypes.c_int(trig_mode)))
    )
    results.append(timed_call("PrepareEvent", lib.WAVECAT64CH_PrepareEvent))

    # 3) Allocate/start/read/stop
    class EventStruct(ctypes.Structure):
        _fields_ = [
            ("EventID", ctypes.c_int),
            ("TDC", ctypes.c_ulonglong),
            ("ChannelData", ctypes.c_void_p),
            ("NbOfSAMBlocksInEvent", ctypes.c_int),
        ]

    evt = EventStruct()
    results.append(timed_call("AllocateEventStructure", lambda: lib.WAVECAT64CH_AllocateEventStructure(ctypes.byref(evt))))
    results.append(timed_call("StartRun", lib.WAVECAT64CH_StartRun))

    t_end = time.time() + duration_s
    decoded = 0
    next_soft = time.time()
    soft_period = (1.0 / sw_hz) if sw_hz > 0 else None
    while time.time() < t_end:
        now = time.time()
        if soft_period is not None and now >= next_soft:
            lib.WAVECAT64CH_SendSoftwareTrigger()
            next_soft = now + soft_period
        rc = int(lib.WAVECAT64CH_ReadEventBuffer())
        if rc == SUCCESS:
            if int(lib.WAVECAT64CH_DecodeEvent(ctypes.byref(evt))) == SUCCESS:
                decoded += 1
        time.sleep(0.001)

    results.append(timed_call("StopRun", lib.WAVECAT64CH_StopRun))
    results.append(timed_call("FreeEventStructure", lambda: lib.WAVECAT64CH_FreeEventStructure(ctypes.byref(evt))))
    results.append(timed_call("CloseDevice", lib.WAVECAT64CH_CloseDevice))
    results.append(CallResult(name="DecodedEvents", rc=decoded, dt_ms=0.0))
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default=None)
    ap.add_argument("--threshold", type=float, default=0.020)
    ap.add_argument("--edge", choices=["pos", "neg"], default="pos")
    ap.add_argument("--sw-hz", type=float, default=0.0)
    ap.add_argument("--duration", type=float, default=3.0)
    ap.add_argument("--out", default="/tmp/wc_bor_python_parity_test.json")
    args = ap.parse_args()

    lib_path = pick_library(args.lib)
    lib = ctypes.CDLL(lib_path)

    # Same API surface, two "modes" for reporting intent/context parity
    py_results = run_sequence(lib, mode="python", threshold=args.threshold, edge=args.edge, sw_hz=args.sw_hz, duration_s=args.duration)
    bor_results = run_sequence(lib, mode="bor_like", threshold=args.threshold, edge=args.edge, sw_hz=args.sw_hz, duration_s=args.duration)

    payload = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "library": lib_path,
        "params": {
            "threshold": args.threshold,
            "edge": args.edge,
            "sw_hz": args.sw_hz,
            "duration_s": args.duration,
        },
        "python_like": [asdict(x) for x in py_results],
        "bor_like": [asdict(x) for x in bor_results],
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    print(f"wrote: {args.out}")


if __name__ == "__main__":
    main()
