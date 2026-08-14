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
import time
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

def pod_ips(job):
    """return set of pod IPs for a volcano job (from pod statuses)."""
    out = subprocess.run(
        ["kubectl", "--kubeconfig", KUBECONFIG, "get", "pods", "-n", "squid",
         "-l", f"volcano.sh/job-name={job}", "-o",
         "jsonpath={range .items[*]}{.status.podIP}{\" \"}{end}"],
        capture_output=True, text=True, timeout=90)
    return set(out.stdout.split()) if out.returncode == 0 else set()

def cluster_offset():
    """cluster epoch - local epoch; timeline.tsv timestamps are recorded on the
    local host while access.log uses the cluster clock (NTP skew observed:
    ~2min)."""
    for attempt in range(3):
        out = subprocess.run(
            ["kubectl", "--kubeconfig", KUBECONFIG, "exec", "-n", "squid",
             "squid-cache-0", "-c", "squid", "--", "date", "+%s"],
            capture_output=True, text=True, timeout=90)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip()) - int(time.time())
    return 0

ACCESS_LOGS = {
    "squid-cache-0": "/tmp/opencode/cache0-prev.log",
    "squid-cache-1": "/tmp/opencode/cache1-prev.log",
}

def accesslog(pod, s, e):
    """return {status: (reqs, bytes)} in window from the pod's PREVIOUS
    container access.log (saved locally): the current container's access.log
    was recreated at its last restart (~2min of data), while the previous
    container covers the whole test window. Lines are 'epoch.ms ... status
    size ...' (cache.log noise starts with a date string, not a bare epoch).
    pod IP filtering was tried but Volcano rebuilds pods between the traffic
    window and analysis time, so recorded client IPs do not match any
    current pod."""
    path = ACCESS_LOGS.get(pod)
    if not path:
        return {}
    res = {}
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) >= 5 and p[0].find(".") > 0 and p[0].replace(".", "", 1).isdigit():
                    ts = float(p[0])
                    if s <= ts <= e:
                        st = p[3].split("/")[0]
                        try:
                            n, b = res.get(st, (0, 0))
                            res[st] = (n + 1, b + int(p[4]))
                        except ValueError:
                            pass
    except FileNotFoundError:
        pass
    return res

def classify(stats):
    hit = miss = 0.0
    for k, (n, b) in stats.items():
        if k.startswith("TCP_HIT") or k.startswith("TCP_MEM_HIT") or k.startswith("TCP_REFRESH_UNMODIFIED") or k.startswith("TCP_REFRESH_HIT"):
            hit += b
        elif k.startswith("TCP_MISS") or k.startswith("TCP_REFRESH_MODIFIED"):
            miss += b
    return hit / 1048576, miss / 1048576

# timeline (job name rides on every action line)
tl = {}
jobs = {}
with open(f"{LOGDIR}/timeline.tsv") as f:
    for line in f:
        parts = line.strip().split("\t")
        if len(parts) != 4:
            continue
        ts, case, action, job = parts
        if action in ("SUBMIT", "DONE", "FAILED"):
            tl.setdefault(case, {})[action] = int(ts)
            jobs[case] = job

cases = sorted(tl.keys())
print(f"{'case':<22} {'out_MB':>9} {'origin_MB':>9} {'回源%':>7} {'HIT_MB':>8} {'MISS_MB':>8} {'HIT%':>6}")
results = {}
off = cluster_offset()  # cluster epoch − local epoch (add to local windows)
if off:
    print(f"    [cluster clock is {off:+d}s ahead of local]", file=sys.stderr)
for idx, c in enumerate(cases):
    t = tl[c]
    s = t["SUBMIT"]
    # DONE from wait_pods_done is already the true end of traffic (all pods
    # finished), so no tail buffer is needed — and cases run back-to-back, so
    # DONE+180 would swallow the NEXT case's traffic. Clamp e to the next
    # case's SUBMIT (and never before DONE).
    done = t.get("DONE", t.get("FAILED", s + 60))
    nxt = tl[cases[idx + 1]]["SUBMIT"] if idx + 1 < len(cases) else done + 60
    e = min(done, nxt) if done > s else s + 60
    if done > nxt:  # overlapping runs (next case submitted before this one
        e = done     # finished): keep this case's own tail anyway
    s, e = s + off, e + off  # access.log / prometheus use cluster time
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
