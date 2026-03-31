#!/usr/bin/env python3
import argparse
import json
import urllib.request


def req(method, url, payload=None):
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description="WaveCatcher DAQ remote client")
    ap.add_argument("command", choices=["configure", "start", "stop", "status", "manifest", "mode"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--duration-s", type=float, default=10.0)
    ap.add_argument("--channel", type=int, default=0)
    ap.add_argument("--trigger-threshold-v", type=float, default=0.030)
    ap.add_argument("--trigger-edge", choices=["pos", "neg"], default="pos")
    ap.add_argument("--accept-peak-mv", type=float, default=30.0)
    ap.add_argument("--max-events", type=int, default=200)
    ap.add_argument("--software-trigger-hz", type=float, default=0.0)
    ap.add_argument("--output-dir", default="")
    ap.add_argument("--bias-voltage-user-input-v", type=float, default=None)
    ap.add_argument("--operating-voltage-user-input-v", type=float, default=None)
    ap.add_argument("--temperature-user-input-c", type=float, default=None)
    ap.add_argument("--comment", default="")
    ap.add_argument("--mock-mode", action="store_true")
    args = ap.parse_args()

    base = f"http://{args.host}:{args.port}"
    payload = {
        "run_id": args.run_id or None,
        "duration_s": args.duration_s,
        "channel": args.channel,
        "trigger_threshold_v": args.trigger_threshold_v,
        "trigger_edge": args.trigger_edge,
        "accept_peak_mv": args.accept_peak_mv,
        "max_events": args.max_events,
        "software_trigger_hz": args.software_trigger_hz,
        "output_dir": args.output_dir or None,
        "bias_voltage_user_input_v": args.bias_voltage_user_input_v,
        "operating_voltage_user_input_v": args.operating_voltage_user_input_v,
        "temperature_user_input_c": args.temperature_user_input_c,
        "comment": args.comment,
    }
    payload = {k: v for k, v in payload.items() if v is not None}

    if args.command == "configure":
        out = req("POST", f"{base}/configure", payload)
    elif args.command == "start":
        out = req("POST", f"{base}/start_run", payload)
    elif args.command == "stop":
        out = req("POST", f"{base}/stop_run", {})
    elif args.command == "status":
        out = req("GET", f"{base}/status")
    elif args.command == "manifest":
        out = req("GET", f"{base}/last_manifest")
    else:
        out = req("POST", f"{base}/set_mode", {"mock_mode": args.mock_mode})
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
