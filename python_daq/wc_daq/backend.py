#!/usr/bin/env python3
import ctypes
import math
import os
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

SUCCESS = 0
FRONT = 0
ON = 1
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
class RunConfig:
    run_id: str
    duration_s: float
    channel: int
    trigger_threshold_v: float
    trigger_edge: str  # pos|neg
    accept_peak_mv: float
    max_events: int
    output_dir: str
    software_trigger_hz: float = 0.0
    bias_voltage_user_input_v: Optional[float] = None
    operating_voltage_user_input_v: Optional[float] = None
    temperature_user_input_c: Optional[float] = None
    comment: str = ""


def pick_library(explicit: Optional[str] = None) -> Optional[str]:
    if explicit and os.path.exists(explicit):
        return explicit
    env = os.environ.get("WC_LIB_PATH")
    if env and os.path.exists(env):
        return env
    p = os.path.expanduser("~/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so")
    return p if os.path.exists(p) else None


class WaveCatcherBackend:
    def __init__(self, lib_path: Optional[str] = None):
        p = pick_library(lib_path)
        if not p:
            raise RuntimeError("WaveCatcher library not found")
        self.lib_path = p
        self.lib = ctypes.CDLL(p)
        self.handle = ctypes.c_int(-1)
        self.event = EventStruct()
        self._connected = False
        self._event_alloc = False

    def open(self, retries: int = 6, retry_delay: float = 0.4) -> None:
        for k in range(1, max(1, retries) + 1):
            self.handle.value = -1
            e = self.lib.WAVECAT64CH_OpenDevice(ctypes.byref(self.handle))
            if e == SUCCESS:
                self._connected = True
                return
            if k < retries:
                time.sleep(max(0.0, retry_delay))
        raise RuntimeError("OpenDevice failed after retries")

    def close(self) -> None:
        if self._event_alloc:
            self.lib.WAVECAT64CH_FreeEventStructure(ctypes.byref(self.event))
            self._event_alloc = False
        if self._connected:
            self.lib.WAVECAT64CH_CloseDevice()
            self._connected = False

    def configure(self, channel: int, threshold_v: float, edge: str, software_trigger_hz: float = 0.0) -> None:
        edge_v = 0 if edge == "pos" else 1
        trig_mode = 0 if software_trigger_hz > 0 else TRIG_NORMAL
        calls = [
            self.lib.WAVECAT64CH_ResetDevice(),
            self.lib.WAVECAT64CH_SetDefaultParameters(),
            self.lib.WAVECAT64CH_SetChannelState(ctypes.c_int(FRONT), ctypes.c_int(channel), ctypes.c_int(ON)),
            self.lib.WAVECAT64CH_SetTriggerSourceState(ctypes.c_int(FRONT), ctypes.c_int(channel), ctypes.c_int(ON)),
            self.lib.WAVECAT64CH_SetTriggerEdge(ctypes.c_int(FRONT), ctypes.c_int(channel), ctypes.c_int(edge_v)),
            self.lib.WAVECAT64CH_SetTriggerThreshold(ctypes.c_int(FRONT), ctypes.c_int(channel), ctypes.c_float(threshold_v)),
            self.lib.WAVECAT64CH_SetTriggerMode(ctypes.c_int(trig_mode)),
            self.lib.WAVECAT64CH_SetReadoutLatency(ctypes.c_int(1)),
            self.lib.WAVECAT64CH_PrepareEvent(),
        ]
        if any(x != SUCCESS for x in calls):
            raise RuntimeError(f"Configuration failed: {calls}")

    def start_run(self) -> None:
        if not self._event_alloc:
            e_alloc = self.lib.WAVECAT64CH_AllocateEventStructure(ctypes.byref(self.event))
            if e_alloc != SUCCESS:
                raise RuntimeError(f"AllocateEventStructure failed: {e_alloc}")
            self._event_alloc = True
        e_start = self.lib.WAVECAT64CH_StartRun()
        if e_start != SUCCESS:
            raise RuntimeError(f"StartRun failed: {e_start}")

    def stop_run(self) -> None:
        self.lib.WAVECAT64CH_StopRun()

    def read_one_channel_event(self, channel: int, software_trigger_hz: float = 0.0) -> Optional[Dict]:
        e_prep = self.lib.WAVECAT64CH_PrepareEvent()
        if e_prep != SUCCESS:
            raise RuntimeError(f"PrepareEvent failed: {e_prep}")
        e_read = self.lib.WAVECAT64CH_ReadEventBuffer()
        if e_read != SUCCESS:
            # v2.8.8 sample keeps going to DecodeEvent() even on ReadoutError (-9).
            if e_read in (-7, -8, -15):
                return None
            if e_read != -9:
                raise RuntimeError(f"ReadEventBuffer failed: {e_read}")
        e_dec = self.lib.WAVECAT64CH_DecodeEvent(ctypes.byref(self.event))
        if e_dec != SUCCESS:
            if e_dec in (-18, -8):
                return None
            raise RuntimeError(f"DecodeEvent failed: {e_dec}")
        ch = ChannelDataStruct()
        e_ch = self.lib.WAVECAT64CH_ReadChannelDataStruct(
            ctypes.byref(self.event), ctypes.c_int(channel), ctypes.byref(ch)
        )
        if e_ch != SUCCESS:
            return None
        if ch.WaveformDataSize <= 0 or not ch.WaveformData:
            return None
        n = int(ch.WaveformDataSize)
        samples = [float(ch.WaveformData[i]) for i in range(n)]
        peak_adc = float(ch.Peak)
        return {
            "event_id": int(self.event.EventID),
            "tdc": int(self.event.TDC),
            "waveform_samples": n,
            "peak_adc": peak_adc,
            "peak_mV": peak_adc * ADC_TO_VOLTS * 1000.0,
            "baseline_adc": float(ch.Baseline),
            "samples_adc": samples,
        }


def ensure_dir(path: str) -> None:
    Path(path).mkdir(parents=True, exist_ok=True)


def write_waveform_csv(path: str, samples: List[float]) -> None:
    with open(path, "w") as f:
        f.write("sample_idx,adc,mV\n")
        for i, v in enumerate(samples):
            f.write(f"{i},{v:.6f},{v*ADC_TO_VOLTS*1000.0:.6f}\n")


class MockWaveCatcherBackend:
    def __init__(self):
        self._connected = False
        self._running = False
        self._event_id = 0
        self._t0 = time.time()
        self._threshold_v = 0.03
        self._edge = "pos"
        self._channel = 0
        self._period_s = 0.02
        self._next_t = time.time()

    def open(self, retries: int = 1, retry_delay: float = 0.0) -> None:
        self._connected = True

    def close(self) -> None:
        self._running = False
        self._connected = False

    def configure(self, channel: int, threshold_v: float, edge: str, software_trigger_hz: float = 0.0) -> None:
        self._channel = channel
        self._threshold_v = threshold_v
        self._edge = edge
        if software_trigger_hz > 0:
            self._period_s = max(0.005, 1.0 / software_trigger_hz)

    def start_run(self) -> None:
        if not self._connected:
            raise RuntimeError("mock backend not connected")
        self._running = True
        self._next_t = time.time()

    def stop_run(self) -> None:
        self._running = False

    def read_one_channel_event(self, channel: int, software_trigger_hz: float = 0.0) -> Optional[Dict]:
        if not self._running:
            return None
        now = time.time()
        if now < self._next_t:
            return None
        self._next_t = now + self._period_s
        self._event_id += 1
        n = 1024
        baseline = random.uniform(-2.0, 2.0)
        center = random.uniform(300, 700)
        width = random.uniform(12, 35)
        amp_mv = random.uniform(25, 120)
        amp_adc = amp_mv / (ADC_TO_VOLTS * 1000.0)
        samples: List[float] = []
        for i in range(n):
            pulse = amp_adc * math.exp(-0.5 * ((i - center) / width) ** 2)
            noise = random.uniform(-1.5, 1.5)
            v = baseline + pulse + noise
            samples.append(v)
        peak_adc = max(samples)
        return {
            "event_id": self._event_id,
            "tdc": int((now - self._t0) * 1e9),
            "waveform_samples": n,
            "peak_adc": peak_adc,
            "peak_mV": peak_adc * ADC_TO_VOLTS * 1000.0,
            "baseline_adc": baseline,
            "samples_adc": samples,
        }
