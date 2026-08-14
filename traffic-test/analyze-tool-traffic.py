#!/usr/bin/env python3
"""analyze-tool-traffic.py — per-case traffic analysis for the 16-tool test.

For each case (window = SUBMIT..DONE from timeline.tsv):
  - Prometheus counter delta: client_out / origin_in → 回源率
  - access.log (both replicas): HIT/MISS bytes by status class
Output: summary table + per-case JSON.
"""
import json
import subprocess
import sys
import urllib.request
import urllib.parse

PROM = "http://113.44.182.82:9090"
KUBECONFIG = "/home/chenqi252/.kube/gy-006.yaml"
LOGDIR = sys.argv[1] if len(sys.argv) > 1 else "logs/tool"

def range_q(expr, start, end, step=30):
    q = {"query": expr, "start": start, "end": end, "step": step}
    d = json.load(urllib.request.urlopen(PROM + "/api/v1/query_range?" + urllib.parse.urlencode(q), timeout=20))
    return d["data"]["result"]

def delta(met, s, e):
    r = range_q(f'sum({met}{{job="squid"}})', s, e)
    if not r:
        return 0
    vals = [float(x[1]) for x in r[0]["values"] if x[1] != ""]
    return (vals[-1] - vals[0]) / 1024 if len(vals) >= 2 else 0

def accesslog(pod, s, e):
    """return {status: (reqs, bytes)} in window from pod access.log"""
    out = subprocess.run(
        ["kubectl", "--kubeconfig", KUBECONFIG, "exec", "-n", "squid", pod, "-c", "squid", "--",
         "sh", "-c", f'awk \'{{if ($1>={s} && $1<={e}) {{x=$4; sub(/\\/.*/,"",x); c[x]++; b[x]+=$5}}}} END{{for (k in c) printf "%s %d %.0f\\n", k, c[k], b[k]}}\' /var/log/squid/access.log'],
        capture_output=True, text=True, timeout=60)
    res = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3:
            res[parts[0]] = (int(parts[1]), int(parts[2]))
    return res

def classify(stats):
    hit = miss = 0.0
    for k, (n, b) in stats.items():
        if k.startswith("TCP_HIT") or k.startswith("TCP_MEM_HIT") or k.startswith("TCP_REFRESH_UNMODIFIED") or k.startswith("TCP_REFRESH_HIT"):
            hit += b
        elif k.startswith("TCP_MISS") or k.startswith("TCP_REFRESH_MODIFIED"):
            miss += b
    return hit / 1048576, miss / 1048576

# timeline
tl = {}
with open(f"{LOGDIR}/timeline.tsv") as f:
    for line in f:
        parts = line.strip().split("\t")
        if len(parts) != 4:
            continue
        ts, case, action, job = parts
        if action in ("SUBMIT", "DONE", "FAILED"):
            tl.setdefault(case, {})[action] = int(ts)

cases = sorted(tl.keys())
print(f"{'case':<22} {'out_MB':>9} {'origin_MB':>9} {'回源%':>7} {'HIT_MB':>8} {'MISS_MB':>8} {'HIT%':>6}")
results = {}
for c in cases:
    t = tl[c]
    s, e = t["SUBMIT"], t.get("DONE", t.get("FAILED", t["SUBMIT"] + 60))
    co = delta("squid_client_http_kbytes_out_kbytes_total", s, e)
    oi = delta("squid_server_http_kbytes_in_kbytes_total", s, e)
    hit_t = miss_t = 0.0
    for pod in ("squid-cache-0", "squid-cache-1"):
        st = accesslog(pod, s, e)
        h, m = classify(st)
        hit_t += h
        miss_t += m
    ratio = 100 * oi / co if co > 0 else 0
    hitpct = 100 * hit_t / (hit_t + miss_t) if (hit_t + miss_t) > 0 else 0
    results[c] = dict(out_mb=round(co, 1), origin_mb=round(oi, 1), ratio=round(ratio, 1),
                      hit_mb=round(hit_t, 1), miss_mb=round(miss_t, 1), hit_pct=round(hitpct, 1))
    print(f"{c:<22} {co:>9.1f} {oi:>9.1f} {ratio:>6.1f}% {hit_t:>8.1f} {miss_t:>8.1f} {hitpct:>5.1f}%")

with open(f"{LOGDIR}/analysis.json", "w") as f:
    json.dump(results, f, indent=1)
print(f"\n→ {LOGDIR}/analysis.json")
