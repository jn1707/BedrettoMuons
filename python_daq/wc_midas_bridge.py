#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
import urllib.request
from pathlib import Path


def req(method, url, payload=None):
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def sh(cmd, env):
    return subprocess.check_output(cmd, env=env, text=True, stderr=subprocess.STDOUT).strip()


def odb_get(path, env):
    out = sh(["/home/morenoma/packages/midas/bin/odbedit", "-c", f"ls {path}"], env)
    return out


def parse_run_state(ls_output):
    for line in ls_output.splitlines():
        s = line.strip()
        if s.startswith("State"):
            parts = s.split()
            if parts:
                try:
                    return int(parts[-1])
                except Exception:
                    pass
    return 1


def parse_run_number(ls_output):
    for line in ls_output.splitlines():
        s = line.strip()
        if s.startswith("Run number"):
            parts = s.split()
            if parts:
                try:
                    return int(parts[-1])
                except Exception:
                    pass
    return int(time.time())


def main():
    ap = argparse.ArgumentParser(description="Bridge MIDAS transitions to WaveCatcher DAQ service")
    ap.add_argument("--daq-url", default="http://127.0.0.1:8765")
    ap.add_argument("--poll", type=float, default=1.0)
    ap.add_argument("--duration-s", type=float, default=20.0)
    ap.add_argument("--channel", type=int, default=0)
    ap.add_argument("--trigger-threshold-v", type=float, default=0.030)
    ap.add_argument("--trigger-edge", choices=["pos", "neg"], default="pos")
    ap.add_argument("--accept-peak-mv", type=float, default=30.0)
    ap.add_argument("--max-events", type=int, default=200)
    ap.add_argument("--software-trigger-hz", type=float, default=0.0)
    ap.add_argument("--runs-root", default=str(Path.home() / "Documents" / "wc_daq_runs"))
    ap.add_argument("--mock-mode", action="store_true")
    args = ap.parse_args()

    env = {
        **dict(**__import__("os").environ),
        "MIDASSYS": "/home/morenoma/packages/midas",
        "MIDAS_EXPTAB": str(Path.home() / "online_wc" / "exptab"),
        "MIDAS_EXPT_NAME": "wavecatcher",
        "MIDAS_DIR": str(Path.home() / "online_wc"),
        "PATH": f"/home/morenoma/packages/midas/bin:{__import__('os').environ.get('PATH','')}",
    }

    req("POST", f"{args.daq_url}/set_mode", {"mock_mode": bool(args.mock_mode)})
    print(f"bridge: mode set mock={bool(args.mock_mode)}")

    last_state = None
    print("bridge: monitoring MIDAS /Runinfo/State")
    while True:
        ls = odb_get("/Runinfo", env)
        state = parse_run_state(ls)
        run_number = parse_run_number(ls)
        if state != last_state:
            print(f"bridge: state change {last_state} -> {state}")
            # MIDAS state conventions: running=3, stopped=1, paused=2
            if state == 3:
                run_id = f"midas_run_{run_number}"
                payload = {
                    "run_id": run_id,
                    "duration_s": args.duration_s,
                    "channel": args.channel,
                    "trigger_threshold_v": args.trigger_threshold_v,
                    "trigger_edge": args.trigger_edge,
                    "accept_peak_mv": args.accept_peak_mv,
                    "max_events": args.max_events,
                    "software_trigger_hz": args.software_trigger_hz,
                    "output_dir": str(Path(args.runs_root) / run_id),
                    "comment": "started by MIDAS bridge",
                }
                req("POST", f"{args.daq_url}/configure", payload)
                req("POST", f"{args.daq_url}/start_run", {})
                print(f"bridge: started DAQ run {run_id}")
            elif state in (1, 2):
                try:
                    st = req("GET", f"{args.daq_url}/status")
                    if st.get("state") == "running":
                        cur = st.get("current_run") or {}
                        elapsed = float(st.get("elapsed_s", 0.0))
                        dur = float(cur.get("duration_s", args.duration_s))
                        if elapsed + 0.5 < dur:
                            req("POST", f"{args.daq_url}/stop_run", {})
                            print("bridge: stop requested on DAQ service")
                        else:
                            print("bridge: run near/after planned duration, not forcing stop")
                except Exception:
                    pass
            last_state = state
        time.sleep(max(0.2, args.poll))


if __name__ == "__main__":
    main()
