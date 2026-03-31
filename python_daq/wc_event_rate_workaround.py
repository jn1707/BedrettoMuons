#!/usr/bin/env python3
"""
Event-based CH0 rate workaround for WaveCatcher v2.8.8 on Linux.

This avoids WAVECAT64CH_ReadRateCounters and derives rate from decoded events:
rate_hz = accepted_events / elapsed_time.
"""

import argparse
import ctypes
import os
import sys
import time

SUCCESS = 0
FRONT = 0
ON = 1
TRIG_NORMAL = 1
TRIG_SOFT = 0


class ChannelDataStruct(ctypes.Structure):
    _fields_ = [
        ("ChannelType", ctypes.c_int),
        ("Channel", ctypes.c_int),
        ("TrigCount", ctypes.c_int),
        ("TimeCount", ctypes.c_int),
        ("WaveformDataSize", ctypes.c_int),
        ("WaveformData", ctypes.POINTER(ctypes.c_float)),
        ("Baseline", ctypes.c_float),
        ("Peak", ctypes.c_float),
        ("PeakCell", ctypes.c_int),
        ("Charge", ctypes.c_float),
        ("ChargeMeasureOverflow", ctypes.c_int),
        ("CFDRisingEdgeTime", ctypes.c_float),
        ("CFDFallingEdgeTime", ctypes.c_float),
        ("FCR", ctypes.c_int),
    ]


class EventStruct(ctypes.Structure):
    _fields_ = [
        ("EventID", ctypes.c_int),
        ("TDC", ctypes.c_ulonglong),
        ("ChannelData", ctypes.POINTER(ChannelDataStruct)),
        ("NbOfSAMBlocksInEvent", ctypes.c_int),
    ]


def pick_library(explicit=None):
    if explicit and os.path.exists(explicit):
        return explicit
    env = os.environ.get("WC_LIB_PATH")
    if env and os.path.exists(env):
        return env
    p = os.path.expanduser("~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so")
    return p if os.path.exists(p) else None


def main():
    ap = argparse.ArgumentParser(description="Event-based CH0 rate workaround")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--threshold", type=float, default=0.020, help="V")
    ap.add_argument("--edge", choices=["pos", "neg"], default="pos")
    ap.add_argument("--min-peak", type=float, default=0.0, help="ADC counts")
    ap.add_argument("--soft-trigger-hz", type=float, default=0.0, help="0=normal mode, >0 use software trigger mode")
    ap.add_argument("--open-retries", type=int, default=5, help="Retries for OpenDevice on transient -3")
    ap.add_argument("--open-retry-delay", type=float, default=0.5, help="Seconds between open retries")
    ap.add_argument("--lib", default=None)
    args = ap.parse_args()

    lib_path = pick_library(args.lib)
    if not lib_path:
        sys.exit("ERROR: v2.8.8 lib not found")
    lib = ctypes.CDLL(lib_path)
    print(f"lib={lib_path}")
    print(f"WC_LIB_VERSION={os.environ.get('WC_LIB_VERSION','(unset)')}")

    h = ctypes.c_int(-1)
    e_open = -999
    for attempt in range(1, max(1, args.open_retries) + 1):
        h.value = -1
        e_open = lib.WAVECAT64CH_OpenDevice(ctypes.byref(h))
        print(f"OpenDevice attempt={attempt} err={e_open}, handle={h.value}")
        if e_open == SUCCESS:
            break
        if attempt < args.open_retries:
            time.sleep(max(0.0, args.open_retry_delay))
    if e_open != SUCCESS:
        sys.exit(2)

    edge = 0 if args.edge == "pos" else 1
    mode = TRIG_SOFT if args.soft_trigger_hz > 0 else TRIG_NORMAL

    e_cfg = [
        ("ResetDevice", lib.WAVECAT64CH_ResetDevice()),
        ("SetDefaultParameters", lib.WAVECAT64CH_SetDefaultParameters()),
        ("SetChannelState", lib.WAVECAT64CH_SetChannelState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON))),
        ("SetTriggerSourceState", lib.WAVECAT64CH_SetTriggerSourceState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON))),
        ("SetTriggerEdge", lib.WAVECAT64CH_SetTriggerEdge(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(edge))),
        ("SetTriggerThreshold", lib.WAVECAT64CH_SetTriggerThreshold(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_float(args.threshold))),
        ("SetTriggerMode", lib.WAVECAT64CH_SetTriggerMode(ctypes.c_int(mode))),
        ("PrepareEvent", lib.WAVECAT64CH_PrepareEvent()),
    ]
    for n, e in e_cfg:
        print(f"{n}={e}")
    if any(e != SUCCESS for _, e in e_cfg):
        lib.WAVECAT64CH_CloseDevice()
        sys.exit(3)

    evt = EventStruct()
    e_alloc = lib.WAVECAT64CH_AllocateEventStructure(ctypes.byref(evt))
    e_start = lib.WAVECAT64CH_StartRun()
    print(f"AllocateEventStructure={e_alloc}, StartRun={e_start}")
    if e_alloc != SUCCESS or e_start != SUCCESS:
        lib.WAVECAT64CH_CloseDevice()
        sys.exit(4)

    decoded = 0
    accepted = 0
    peaks = []
    t0 = time.time()
    deadline = t0 + args.seconds
    next_soft = t0
    soft_period = (1.0 / args.soft_trigger_hz) if args.soft_trigger_hz > 0 else None

    while time.time() < deadline:
        now = time.time()
        if soft_period is not None and now >= next_soft:
            lib.WAVECAT64CH_SendSoftwareTrigger()
            next_soft = now + soft_period

        e_read = lib.WAVECAT64CH_ReadEventBuffer()
        if e_read == SUCCESS:
            e_dec = lib.WAVECAT64CH_DecodeEvent(ctypes.byref(evt))
            if e_dec == SUCCESS:
                ch0 = ChannelDataStruct()
                e_ch = lib.WAVECAT64CH_ReadChannelDataStruct(ctypes.byref(evt), ctypes.c_int(0), ctypes.byref(ch0))
                if e_ch == SUCCESS:
                    decoded += 1
                    pk = float(ch0.Peak)
                    peaks.append(pk)
                    if pk >= args.min_peak:
                        accepted += 1
        elif e_read not in (-7, -8, -9):
            print(f"ReadEventBuffer={e_read}")
        time.sleep(0.001)

    elapsed = max(time.time() - t0, 1e-9)
    raw_rate = decoded / elapsed
    acc_rate = accepted / elapsed
    mean_peak = (sum(peaks) / len(peaks)) if peaks else 0.0

    e_stop = lib.WAVECAT64CH_StopRun()
    e_free = lib.WAVECAT64CH_FreeEventStructure(ctypes.byref(evt))
    e_close = lib.WAVECAT64CH_CloseDevice()
    print(f"StopRun={e_stop}, FreeEventStructure={e_free}, CloseDevice={e_close}")
    print(
        f"RESULT elapsed_s={elapsed:.3f} decoded={decoded} accepted={accepted} "
        f"rate_raw_hz={raw_rate:.3f} rate_accepted_hz={acc_rate:.3f} mean_peak={mean_peak:.3f} "
        f"threshold_V={args.threshold} edge={args.edge} min_peak={args.min_peak}"
    )


if __name__ == "__main__":
    main()
