#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def load_manifest(run_dir: Path):
    p = run_dir / "manifest.json"
    if not p.exists():
        raise RuntimeError(f"manifest missing: {p}")
    with open(p) as f:
        return json.load(f)


def verify_run_dir(run_dir: Path) -> None:
    m = load_manifest(run_dir)
    missing = []
    bad = []
    for ent in m.get("files", []):
        p = run_dir / ent["name"]
        if not p.exists():
            missing.append(ent["name"])
            continue
        got = sha256(p)
        if got != ent["sha256"]:
            bad.append((ent["name"], ent["sha256"], got))
    if missing or bad:
        raise RuntimeError(f"verify failed missing={missing} bad={bad}")
    print(f"VERIFY_OK run_id={m.get('run_id')} files={len(m.get('files', []))}")


def copy_run(src: Path, dst_root: Path) -> Path:
    dst = dst_root / src.name
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return dst


def main():
    ap = argparse.ArgumentParser(description="WaveCatcher DAQ transfer and verification utility")
    ap.add_argument("run_dir", help="Source run directory containing manifest.json")
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--dest-root", default="", help="Destination root directory for transferred runs")
    args = ap.parse_args()

    src = Path(os.path.expanduser(args.run_dir)).resolve()
    verify_run_dir(src)
    if args.verify_only:
        return

    if not args.dest_root:
        raise SystemExit("ERROR: --dest-root required unless --verify-only")
    dst_root = Path(os.path.expanduser(args.dest_root)).resolve()
    dst_root.mkdir(parents=True, exist_ok=True)
    dst = copy_run(src, dst_root)
    verify_run_dir(dst)
    print(f"TRANSFER_OK src={src} dst={dst}")


if __name__ == "__main__":
    main()

