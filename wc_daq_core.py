#!/usr/bin/env python3
"""Minimal WaveCatcher PyDAQ core.

This module intentionally keeps the API flow close to the known-good sequence:
OpenDevice -> ResetDevice -> SetDefaultParameters -> channel/trigger config ->
PrepareEvent -> AllocateEventStructure -> StartRun -> Read/Decode loop.
"""

from __future__ import annotations

import ctypes
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

SUCCESS = 0
FRONT = 0
ON = 1
TRIG_SOFT = 0
TRIG_NORMAL = 1
ADC_TO_VOLTS = 0.00061


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


@dataclass
class DaqConfig:
    seconds: float = 10.0
    threshold_v: float = 0.030
    channel: int = 0
    edge: str = "pos"
    software_trigger_hz: float = 0.0
    output_dir: str = "/tmp/wc_pydaq_minimal"
    max_events: int = 0  # 0 means unlimited until time deadline
    open_retries: int = 6
    open_retry_delay_s: float = 0.4
    lib_path: Optional[str] = None


def pick_library(explicit: Optional[str]) -> str:
    if explicit and os.path.exists(explicit):
        return explicit
    env = os.environ.get("WC_LIB_PATH")
    if env and os.path.exists(env):
        return env
    default = os.path.expanduser("~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so")
    if os.path.exists(default):
        return default
    raise FileNotFoundError("WaveCatcher v2.8.8 library not found")


def _append_waveform_csv(path: Path, event: EventStruct, ch: ChannelDataStruct) -> None:
    n = int(ch.WaveformDataSize)
    with path.open("a", encoding="utf-8") as f:
        for i in range(n):
            adc = float(ch.WaveformData[i])
            mv = adc * ADC_TO_VOLTS * 1000.0
            f.write(f"{event.EventID},{i},{adc:.6f},{mv:.6f}\n")


def run_daq_session(cfg: DaqConfig) -> dict:
    lib_path = pick_library(cfg.lib_path)
    lib = ctypes.CDLL(lib_path)
    handle = ctypes.c_int(-1)

    open_rc = -1
    for attempt in range(1, max(1, cfg.open_retries) + 1):
        handle.value = -1
        open_rc = int(lib.WAVECAT64CH_OpenDevice(ctypes.byref(handle)))
        print(f"OpenDevice attempt={attempt} rc={open_rc} handle={handle.value}")
        if open_rc == SUCCESS:
            break
        if attempt < cfg.open_retries:
            time.sleep(max(0.0, cfg.open_retry_delay_s))
    if open_rc != SUCCESS:
        raise RuntimeError(f"OpenDevice failed after retries rc={open_rc}")

    edge = 0 if cfg.edge == "pos" else 1
    trigger_mode = TRIG_SOFT if cfg.software_trigger_hz > 0 else TRIG_NORMAL

    setup_calls = [
        ("ResetDevice", int(lib.WAVECAT64CH_ResetDevice())),
        ("SetDefaultParameters", int(lib.WAVECAT64CH_SetDefaultParameters())),
        ("SetChannelState", int(lib.WAVECAT64CH_SetChannelState(ctypes.c_int(FRONT), ctypes.c_int(cfg.channel), ctypes.c_int(ON)))),
        ("SetTriggerSourceState", int(lib.WAVECAT64CH_SetTriggerSourceState(ctypes.c_int(FRONT), ctypes.c_int(cfg.channel), ctypes.c_int(ON)))),
        ("SetTriggerEdge", int(lib.WAVECAT64CH_SetTriggerEdge(ctypes.c_int(FRONT), ctypes.c_int(cfg.channel), ctypes.c_int(edge)))),
        ("SetTriggerThreshold", int(lib.WAVECAT64CH_SetTriggerThreshold(ctypes.c_int(FRONT), ctypes.c_int(cfg.channel), ctypes.c_float(cfg.threshold_v)))),
        ("SetTriggerMode", int(lib.WAVECAT64CH_SetTriggerMode(ctypes.c_int(trigger_mode)))),
        ("PrepareEvent", int(lib.WAVECAT64CH_PrepareEvent())),
    ]
    for name, rc in setup_calls:
        print(f"{name} rc={rc}")
        if rc != SUCCESS:
            lib.WAVECAT64CH_CloseDevice()
            raise RuntimeError(f"{name} failed rc={rc}")

    event = EventStruct()
    alloc_rc = int(lib.WAVECAT64CH_AllocateEventStructure(ctypes.byref(event)))
    start_rc = int(lib.WAVECAT64CH_StartRun())
    print(f"AllocateEventStructure rc={alloc_rc}")
    print(f"StartRun rc={start_rc}")
    if alloc_rc != SUCCESS or start_rc != SUCCESS:
        lib.WAVECAT64CH_CloseDevice()
        raise RuntimeError(f"Run start failed alloc_rc={alloc_rc} start_rc={start_rc}")

    out_dir = Path(cfg.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    waveform_csv = out_dir / "waveforms.csv"
    with waveform_csv.open("w", encoding="utf-8") as f:
        f.write("event_id,sample_idx,adc,mV\n")

    decoded = 0
    reads = 0
    soft_period_s = (1.0 / cfg.software_trigger_hz) if cfg.software_trigger_hz > 0 else None
    next_soft = time.time()
    deadline = time.time() + cfg.seconds
    while time.time() < deadline:
        if cfg.max_events > 0 and decoded >= cfg.max_events:
            break
        now = time.time()
        if soft_period_s is not None and now >= next_soft:
            lib.WAVECAT64CH_SendSoftwareTrigger()
            next_soft = now + soft_period_s
        read_rc = int(lib.WAVECAT64CH_ReadEventBuffer())
        reads += 1
        if read_rc != SUCCESS:
            if read_rc not in (-7, -8, -9):
                print(f"ReadEventBuffer rc={read_rc}")
            time.sleep(0.001)
            continue
        decode_rc = int(lib.WAVECAT64CH_DecodeEvent(ctypes.byref(event)))
        if decode_rc != SUCCESS:
            time.sleep(0.001)
            continue
        ch = ChannelDataStruct()
        ch_rc = int(lib.WAVECAT64CH_ReadChannelDataStruct(ctypes.byref(event), ctypes.c_int(cfg.channel), ctypes.byref(ch)))
        if ch_rc != SUCCESS or ch.WaveformDataSize <= 0 or not ch.WaveformData:
            time.sleep(0.001)
            continue
        decoded += 1
        _append_waveform_csv(waveform_csv, event, ch)
        time.sleep(0.001)

    stop_rc = int(lib.WAVECAT64CH_StopRun())
    free_rc = int(lib.WAVECAT64CH_FreeEventStructure(ctypes.byref(event)))
    close_rc = int(lib.WAVECAT64CH_CloseDevice())
    elapsed_s = max(0.0, cfg.seconds - max(0.0, deadline - time.time()))
    return {
        "library": lib_path,
        "output_dir": str(out_dir),
        "waveform_csv": str(waveform_csv),
        "decoded_events": decoded,
        "read_calls": reads,
        "elapsed_s": elapsed_s,
        "stop_rc": stop_rc,
        "free_rc": free_rc,
        "close_rc": close_rc,
    }
