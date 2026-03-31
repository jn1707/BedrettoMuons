#!/usr/bin/env python3
"""
Capture WaveCatcher events and save CH0 waveforms that pass a threshold cut.

Outputs (per accepted event) in output directory:
- waveform CSV
- waveform PNG
"""

import argparse
import ctypes
import os
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), ".")))
from wc_daq.backend import ADC_TO_VOLTS, FRONT, ON, SUCCESS, TRIG_NORMAL, ChannelDataStruct, EventStruct, pick_library
from wc_daq.pngplot import save_waveform_png

TRIG_SOFT = 0


def main():
    ap = argparse.ArgumentParser(description="Capture CH0 waveforms above threshold and save PNG/CSV")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--threshold", type=float, default=0.030, help="Trigger threshold in V (default 30 mV)")
    ap.add_argument("--edge", choices=["pos", "neg"], default="pos")
    ap.add_argument("--accept-mv", type=float, default=30.0, help="Save only events with peak >= this many mV")
    ap.add_argument("--max-save", type=int, default=50)
    ap.add_argument("--software-trigger-hz", type=float, default=0.0, help="Use software trigger mode at this rate (Hz)")
    ap.add_argument("--output-dir", default=os.path.expanduser("~/Documents/wc_waveforms_30mV"))
    ap.add_argument("--open-retries", type=int, default=6)
    ap.add_argument("--open-retry-delay", type=float, default=0.4)
    ap.add_argument("--lib", default=None)
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    lib_path = pick_library(args.lib)
    if not lib_path:
        sys.exit("ERROR: v2.8.8 library not found")
    lib = ctypes.CDLL(lib_path)
    print(f"lib={lib_path}")
    print(f"output_dir={args.output_dir}")

    h = ctypes.c_int(-1)
    e_open = -999
    for k in range(1, max(1, args.open_retries) + 1):
        h.value = -1
        e_open = lib.WAVECAT64CH_OpenDevice(ctypes.byref(h))
        print(f"OpenDevice attempt={k} err={e_open} handle={h.value}")
        if e_open == SUCCESS:
            break
        if k < args.open_retries:
            time.sleep(max(0.0, args.open_retry_delay))
    if e_open != SUCCESS:
        sys.exit(2)

    edge = 0 if args.edge == "pos" else 1
    trig_mode = TRIG_SOFT if args.software_trigger_hz > 0 else TRIG_NORMAL
    cfg = [
        ("ResetDevice", lib.WAVECAT64CH_ResetDevice()),
        ("SetDefaultParameters", lib.WAVECAT64CH_SetDefaultParameters()),
        ("SetChannelState", lib.WAVECAT64CH_SetChannelState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON))),
        ("SetTriggerSourceState", lib.WAVECAT64CH_SetTriggerSourceState(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(ON))),
        ("SetTriggerEdge", lib.WAVECAT64CH_SetTriggerEdge(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_int(edge))),
        ("SetTriggerThreshold", lib.WAVECAT64CH_SetTriggerThreshold(ctypes.c_int(FRONT), ctypes.c_int(0), ctypes.c_float(args.threshold))),
        ("SetTriggerMode", lib.WAVECAT64CH_SetTriggerMode(ctypes.c_int(trig_mode))),
        ("PrepareEvent", lib.WAVECAT64CH_PrepareEvent()),
    ]
    for n, e in cfg:
        print(f"{n}={e}")
    if any(e != SUCCESS for _, e in cfg):
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
    saved = 0
    t0 = time.time()
    deadline = t0 + args.seconds
    soft_period = (1.0 / args.software_trigger_hz) if args.software_trigger_hz > 0 else None
    next_soft = t0
    summary_csv = os.path.join(args.output_dir, "summary.csv")
    with open(summary_csv, "w") as sf:
        sf.write("event_id,tdc,waveform_samples,peak_adc,peak_mV,baseline_adc,out_csv,out_png\n")

        while time.time() < deadline and saved < args.max_save:
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
                    if e_ch == SUCCESS and ch0.WaveformDataSize > 0 and ch0.WaveformData:
                        decoded += 1
                        n = int(ch0.WaveformDataSize)
                        samples = [float(ch0.WaveformData[i]) for i in range(n)]
                        peak_adc = float(ch0.Peak)
                        peak_mv = peak_adc * ADC_TO_VOLTS * 1000.0
                        if peak_mv >= args.accept_mv:
                            stem = f"evt_{evt.EventID:06d}_pk_{peak_mv:.1f}mV"
                            out_csv = os.path.join(args.output_dir, stem + ".csv")
                            out_png = os.path.join(args.output_dir, stem + ".png")
                            with open(out_csv, "w") as wf:
                                wf.write("sample_idx,adc,mV\n")
                                for i, v in enumerate(samples):
                                    wf.write(f"{i},{v:.6f},{v*ADC_TO_VOLTS*1000.0:.6f}\n")
                            ttl = f"Event {evt.EventID} peak={peak_mv:.1f}mV thr={args.accept_mv:.1f}mV"
                            save_waveform_png(samples, out_png, ttl)
                            sf.write(
                                f"{evt.EventID},{evt.TDC},{n},{peak_adc:.6f},{peak_mv:.6f},{float(ch0.Baseline):.6f},"
                                f"{os.path.basename(out_csv)},{os.path.basename(out_png)}\n"
                            )
                            sf.flush()
                            saved += 1
                            print(f"saved {saved}: event={evt.EventID} peak_mV={peak_mv:.2f} -> {os.path.basename(out_png)}")
            elif e_read not in (-7, -8, -9):
                print(f"ReadEventBuffer={e_read}")
            time.sleep(0.001)

    e_stop = lib.WAVECAT64CH_StopRun()
    e_free = lib.WAVECAT64CH_FreeEventStructure(ctypes.byref(evt))
    e_close = lib.WAVECAT64CH_CloseDevice()
    elapsed = time.time() - t0
    print(f"StopRun={e_stop}, FreeEventStructure={e_free}, CloseDevice={e_close}")
    print(
        f"RESULT elapsed_s={elapsed:.3f} decoded={decoded} saved={saved} "
        f"accept_mV={args.accept_mv} output_dir={args.output_dir}"
    )


if __name__ == "__main__":
    main()
