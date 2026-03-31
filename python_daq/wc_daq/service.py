#!/usr/bin/env python3
import json
import os
import sys
import threading
import time
import hashlib
import subprocess
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from wc_daq.backend import MockWaveCatcherBackend, RunConfig, WaveCatcherBackend, ensure_dir, write_waveform_csv
from wc_daq.pngplot import save_waveform_png


class DAQState:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = "idle"
        self.current_run: Optional[RunConfig] = None
        self.last_error = ""
        self.started_at = 0.0
        self.decoded = 0
        self.saved = 0
        self.last_manifest: Optional[Dict[str, Any]] = None
        self.stop_requested = False
        self.worker: Optional[threading.Thread] = None
        self.worker_proc: Optional[subprocess.Popen] = None
        self.runs_dir = str(Path.home() / "Documents" / "wc_daq_runs")
        self.mock_mode = False


STATE = DAQState()


def _json(handler: BaseHTTPRequestHandler, code: int, payload: Dict[str, Any]) -> None:
    body = json.dumps(payload, indent=2).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_json(handler: BaseHTTPRequestHandler) -> Dict[str, Any]:
    n = int(handler.headers.get("Content-Length", "0"))
    if n <= 0:
        return {}
    raw = handler.rfile.read(n)
    return json.loads(raw.decode("utf-8"))


def _make_run_config(payload: Dict[str, Any]) -> RunConfig:
    rid = payload.get("run_id") or time.strftime("run_%Y%m%d_%H%M%S")
    outdir = payload.get("output_dir") or str(Path.home() / "Documents" / "wc_daq_runs" / rid)
    return RunConfig(
        run_id=rid,
        duration_s=float(payload.get("duration_s", 10.0)),
        channel=int(payload.get("channel", 0)),
        trigger_threshold_v=float(payload.get("trigger_threshold_v", 0.03)),
        trigger_edge=str(payload.get("trigger_edge", "pos")),
        accept_peak_mv=float(payload.get("accept_peak_mv", 30.0)),
        max_events=int(payload.get("max_events", 200)),
        output_dir=outdir,
        software_trigger_hz=float(payload.get("software_trigger_hz", 0.0)),
        bias_voltage_user_input_v=payload.get("bias_voltage_user_input_v", payload.get("bias_voltage_v")),
        operating_voltage_user_input_v=payload.get("operating_voltage_user_input_v", payload.get("operating_voltage_v")),
        temperature_user_input_c=payload.get("temperature_user_input_c", payload.get("temperature_c")),
        comment=str(payload.get("comment", "")),
    )


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _run_worker(cfg: RunConfig) -> None:
    with STATE.lock:
        mock = STATE.mock_mode
    manifest: Dict[str, Any] = {
        "run_id": cfg.run_id,
        "config": asdict(cfg),
        "mode": "mock" if mock else "hardware",
        "started_at_epoch": time.time(),
        "events": [],
        "summary": {},
        "files": [],
    }
    try:
        ensure_dir(cfg.output_dir)
        t0 = time.time()
        if mock:
            backend = MockWaveCatcherBackend()
            backend.open()
            backend.configure(cfg.channel, cfg.trigger_threshold_v, cfg.trigger_edge, cfg.software_trigger_hz)
            backend.start_run()
            summary_path = Path(cfg.output_dir) / "summary.csv"
            with open(summary_path, "w") as sf:
                sf.write("event_id,tdc,waveform_samples,peak_adc,peak_mV,baseline_adc,out_csv,out_png\n")
                while time.time() - t0 < cfg.duration_s:
                    with STATE.lock:
                        if STATE.stop_requested:
                            break
                    ev = backend.read_one_channel_event(cfg.channel, cfg.software_trigger_hz)
                    if ev is None:
                        time.sleep(0.001)
                        continue
                    with STATE.lock:
                        STATE.decoded += 1
                    if ev["peak_mV"] < cfg.accept_peak_mv:
                        continue
                    stem = f"evt_{ev['event_id']:06d}_pk_{ev['peak_mV']:.1f}mV"
                    out_csv = Path(cfg.output_dir) / f"{stem}.csv"
                    out_png = Path(cfg.output_dir) / f"{stem}.png"
                    write_waveform_csv(str(out_csv), ev["samples_adc"])
                    save_waveform_png(ev["samples_adc"], str(out_png), f"Event {ev['event_id']} peak={ev['peak_mV']:.1f}mV")
                    row = (
                        f"{ev['event_id']},{ev['tdc']},{ev['waveform_samples']},{ev['peak_adc']:.6f},"
                        f"{ev['peak_mV']:.6f},{ev['baseline_adc']:.6f},{out_csv.name},{out_png.name}\n"
                    )
                    sf.write(row)
                    sf.flush()
                    with STATE.lock:
                        STATE.saved += 1
                    if STATE.saved >= cfg.max_events:
                        break
            backend.stop_run()
            backend.close()
        else:
            run_log = Path(cfg.output_dir) / "acquisition.log"
            cmd = [
                str(Path(__file__).resolve().parent.parent / "wc_run_v288.sh"),
                "python3",
                "-u",
                str(Path(__file__).resolve().parent.parent / "wc_capture_waveforms_png.py"),
                "--seconds",
                str(cfg.duration_s),
                "--threshold",
                str(cfg.trigger_threshold_v),
                "--edge",
                cfg.trigger_edge,
                "--accept-mv",
                str(cfg.accept_peak_mv),
                "--max-save",
                str(cfg.max_events),
                "--output-dir",
                cfg.output_dir,
                "--software-trigger-hz",
                str(cfg.software_trigger_hz),
            ]
            attempt = 0
            terminated_by_stop = False
            terminated_by_deadline = False
            exit_code = None
            while attempt < 2:
                attempt += 1
                with open(run_log, "a") as logf:
                    logf.write(f"\n=== acquisition attempt {attempt} ===\n")
                    logf.flush()
                    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, text=True, bufsize=1)
                    with STATE.lock:
                        STATE.worker_proc = proc
                    hard_deadline = time.time() + cfg.duration_s + 30.0
                    attempt_terminated_by_deadline = False
                    while True:
                        with STATE.lock:
                            stop_requested = STATE.stop_requested
                        if stop_requested and proc.poll() is None:
                            terminated_by_stop = True
                        if time.time() >= hard_deadline and proc.poll() is None:
                            proc.terminate()
                            attempt_terminated_by_deadline = True
                            time.sleep(0.5)
                        if proc.poll() is not None:
                            break
                        time.sleep(0.1)
                    if proc.poll() is None:
                        proc.kill()
                    exit_code = proc.poll()
                    terminated_by_deadline = terminated_by_deadline or attempt_terminated_by_deadline
                    with STATE.lock:
                        STATE.worker_proc = None

                summary_path = Path(cfg.output_dir) / "summary.csv"
                if summary_path.exists():
                    lines = summary_path.read_text().strip().splitlines()
                    if len(lines) > 1:
                        break
                if terminated_by_stop:
                    break

            manifest["summary"]["acquisition_attempts"] = attempt
            manifest["summary"]["acquisition_exit_code"] = exit_code
            manifest["summary"]["terminated_by_stop"] = terminated_by_stop
            manifest["summary"]["terminated_by_deadline"] = terminated_by_deadline

        summary_path = Path(cfg.output_dir) / "summary.csv"
        if summary_path.exists():
            rows = summary_path.read_text().strip().splitlines()
            for line in rows[1:]:
                if not line.strip():
                    continue
                cols = line.split(",")
                if len(cols) < 8:
                    continue
                manifest["events"].append(
                    {
                        "event_id": int(cols[0]),
                        "tdc": int(cols[1]),
                        "waveform_samples": int(cols[2]),
                        "peak_mV": float(cols[4]),
                        "baseline_adc": float(cols[5]),
                        "csv": cols[6],
                        "png": cols[7],
                    }
                )
            with STATE.lock:
                STATE.saved = len(manifest["events"])
                STATE.decoded = len(manifest["events"])

        for p in sorted(Path(cfg.output_dir).glob("*")):
            if p.is_file() and p.name != "manifest.json":
                manifest["files"].append({"name": p.name, "sha256": _sha256(p), "bytes": p.stat().st_size})

        elapsed = time.time() - t0
        manifest["summary"] = {
            "elapsed_s": elapsed,
            "decoded_events": STATE.decoded,
            "saved_events": STATE.saved,
            **manifest["summary"],
        }
        if not mock:
            manifest["summary"]["wavecatcher_setup_via"] = "wc_run_v288.sh"
        manifest["finished_at_epoch"] = time.time()
        done_marker = Path(cfg.output_dir) / "RUN_COMPLETE"
        done_marker.write_text("ok\n")
        manifest["files"] = [x for x in manifest["files"] if x["name"] != done_marker.name]
        manifest["files"].append({"name": done_marker.name, "sha256": _sha256(done_marker), "bytes": done_marker.stat().st_size})
        with open(Path(cfg.output_dir) / "manifest.json", "w") as mf:
            json.dump(manifest, mf, indent=2)
        with STATE.lock:
            STATE.state = "idle"
            STATE.last_error = ""
            STATE.last_manifest = manifest
            STATE.current_run = None
            STATE.stop_requested = False
    except Exception as e:
        with STATE.lock:
            STATE.state = "error"
            STATE.last_error = str(e)
            STATE.current_run = None
            STATE.stop_requested = False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            with STATE.lock:
                elapsed = (time.time() - STATE.started_at) if STATE.started_at > 0 else 0.0
                payload = {
                    "state": STATE.state,
                    "midas_state": "RUNNING" if STATE.state == "running" else ("ERROR" if STATE.state == "error" else "STOPPED"),
                    "elapsed_s": elapsed,
                    "decoded_events": STATE.decoded,
                    "saved_events": STATE.saved,
                    "last_error": STATE.last_error,
                    "current_run": asdict(STATE.current_run) if STATE.current_run else None,
                    "mock_mode": STATE.mock_mode,
                }
            return _json(self, 200, payload)
        if self.path == "/last_manifest":
            with STATE.lock:
                m = STATE.last_manifest
            if m is None:
                return _json(self, 404, {"error": "no manifest"})
            return _json(self, 200, m)
        return _json(self, 404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/set_mode":
            payload = _read_json(self)
            with STATE.lock:
                if STATE.state == "running":
                    return _json(self, 409, {"error": "cannot change mode while running"})
                STATE.mock_mode = bool(payload.get("mock_mode", False))
            return _json(self, 200, {"ok": True, "mock_mode": STATE.mock_mode})

        if self.path == "/configure":
            payload = _read_json(self)
            cfg = _make_run_config(payload)
            with STATE.lock:
                if STATE.state == "running":
                    return _json(self, 409, {"error": "run already active"})
                STATE.current_run = cfg
                STATE.state = "configured"
                STATE.last_error = ""
            return _json(self, 200, {"ok": True, "configured": asdict(cfg)})

        if self.path == "/start_run":
            payload = _read_json(self)
            with STATE.lock:
                if STATE.state == "running":
                    return _json(self, 409, {"error": "run already active"})
                if STATE.current_run is None:
                    cfg = _make_run_config(payload)
                    STATE.current_run = cfg
                cfg = STATE.current_run
                STATE.state = "running"
                STATE.started_at = time.time()
                STATE.decoded = 0
                STATE.saved = 0
                STATE.stop_requested = False
                worker = threading.Thread(target=_run_worker, args=(cfg,), daemon=True)
                STATE.worker = worker
                worker.start()
            return _json(self, 200, {"ok": True, "run_id": cfg.run_id})

        if self.path == "/stop_run":
            with STATE.lock:
                if STATE.state != "running":
                    return _json(self, 409, {"error": "no active run"})
                STATE.stop_requested = True
            return _json(self, 200, {"ok": True})

        return _json(self, 404, {"error": "not found"})

    def log_message(self, fmt, *args):
        return


def main():
    ensure_dir(STATE.runs_dir)
    srv = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print("wc_daq service listening on 127.0.0.1:8765")
    srv.serve_forever()


if __name__ == "__main__":
    main()
