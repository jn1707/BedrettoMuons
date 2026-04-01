# Tomorrow hardware tests: MIDAS BOR vs Python parity

Run this after reconnecting WaveCatcher hardware.

## One-command run

```bash
cd /home/morenoma/BedrettoMuons_work
chmod +x scripts/wc_bor_midas_repro_tomorrow.sh scripts/wc_check_bor_health.sh
./scripts/wc_bor_midas_repro_tomorrow.sh
```

This produces `/tmp/wc_bor_repro_<timestamp>/` with:

- `parity.json` (per-call timing and rc for Python-like vs BOR-like sequence)
- `midas_cli.log` (readiness-gated START behavior)
- `bor_health_before.txt`, `bor_health_after.txt`
- `midas_tail.log`, `frontend_tail.log`

## What to compare

1. `parity.json`
   - Does `OpenDevice` succeed quickly in standalone process?
   - Any call that differs in rc/timing between python-like and bor-like sequence?

2. `midas_cli.log` and `bor_health_*.txt`
   - `device_open_state` progression (`in_progress -> ready` or `failed/timed_out`)
   - Whether START is skipped until ready (expected) vs transition-wedge behavior (unexpected)

3. `midas_tail.log`
   - Look for:
     - `previous transition did not finish yet`
     - `begin_of_run: device open ...`
     - `status 603`

## Expected outcomes

- If standalone parity succeeds but MIDAS remains not-ready/timed-out:
  context incompatibility with MIDAS runtime remains likely.
- If both fail similarly:
  likely transport/driver/hardware path issue independent of MIDAS.

