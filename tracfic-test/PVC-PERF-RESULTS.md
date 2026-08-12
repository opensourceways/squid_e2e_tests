# PVC Performance Saturation Results (gy-006)

Test: warmed pip traffic through squid (all TCP_HIT, hitrate=1.0) — aggregate
bandwidth == bytes read from the squid cache PVC (SFS Turbo, sfsturbo-subpath-sc).

Run: 2026-08-12 13:36 UTC, run-pvc-perf.sh --no-warm, ~158MB/pod (13 files,
torch 2.10.0 146MB wheel + deps).

| concurrency | total MB | wall s | agg BW MB/s | hitrate |
|---:|---:|---:|---:|---:|
| 1 | 158 | 4 | 42 | 1.0 |
| 2 | 317 | 4 | 82 | 1.0 |
| 4 | 634 | 6 | 113 | 1.0 |
| 8 | 1268 | 5 | 251 | 1.0 |
| 16 | 2537 | 6 | 390 | 1.0 |
| 24 | 3806 | 10 | 399 | 1.0 |

## Findings

- **Per-connection cap ~42 MB/s** (single pod, ~330 Mbps).
- **Aggregate scales linearly up to ~16 concurrent pods** (390 MB/s).
- **Saturation ("bottom") at 16-24 concurrent: ~400 MB/s** (3.2 Gbps) —
  the SFS Turbo instance-level bandwidth cap. Gain 16→24 was only +2.3%.
- hitrate=1.0 (origin≈0) throughout — pure PVC read path, no upstream fetch.

## Implication for CI

- A single CI job is limited to ~42 MB/s per squid connection; parallel jobs
  scale to the ~400 MB/s SFS Turbo cap at ~16-24 concurrent downloads.
- The 2x squid replicas share the same SFS Turbo instance — both replicas
  draw from the same 400 MB/s pool.
