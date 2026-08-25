#!/usr/bin/env python3
"""queue3-reinject.py — continuous reinjector (Queue 3).

Every N seconds (default 1800 = 30min), picks one type_key from pending.json,
transforms the YAML with squid proxy injection, submits to wlcb-001, monitors
until terminal, captures logs, and records results.

Restart-safe: on startup, checks results.json for any "running" items and
reconciles their actual cluster state.

Usage:
  ./queue3-reinject.py [--interval 1800] [--outdir .]
"""
import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
KC = os.environ.get("KUBECONFIG", os.path.expanduser("~/.kube/wlcb-001.yaml"))

# ── Proxy injection constants (mirrored from gen-reinject.py) ──────────

PROXY = "http://squid-cache.squid.svc.cluster.local:3128"
NO_PROXY = ",".join([
    "localhost", "127.0.0.1",
    "172.22.1.78",
    "triton-ascend.osinfra.cn",
    "hf-mirror.com",
    "git-cache-http-server.git-cache",
    "git-cache-http-server.git-cache.svc.cluster.local",
    "git-cache-github.git-cache",
    "git-cache-github.git-cache.svc.cluster.local",
    "git-cache-gitee.git-cache",
    "git-cache-gitee.git-cache.svc.cluster.local",
    "git-cache-atomgit.git-cache",
    "git-cache-atomgit.git-cache.svc.cluster.local",
    "git-cache-codehub.git-cache",
    "git-cache-codehub.git-cache.svc.cluster.local",
    ".svc.cluster.local", ".cluster.local",
])

PROXY_ENV = {
    "HTTP_PROXY": PROXY,
    "HTTPS_PROXY": PROXY,
    "http_proxy": PROXY,
    "https_proxy": PROXY,
    "NO_PROXY": NO_PROXY,
    "no_proxy": NO_PROXY,
    "SSL_CERT_FILE": "/etc/squid-ca/squid-ca.pem",
    "CURL_CA_BUNDLE": "/etc/squid-ca/squid-ca.pem",
    "REQUESTS_CA_BUNDLE": "/etc/squid-ca/squid-ca.pem",
    "PIP_CERT": "/etc/squid-ca/squid-ca.pem",
    "GIT_SSL_CAINFO": "/etc/squid-ca/squid-ca.pem",
    "NODE_EXTRA_CA_CERTS": "/etc/squid-ca/squid-ca.pem",
}

POSTSTART = """set +e
S=/etc/squid-ca/squid-bazel-trust.jks
J=/etc/squid-bazel-trust/squid-bazel-trust.jks
mkdir -p /etc/squid-bazel-trust
if [ -f "$S" ]; then
  if base64 -d "$S" > "$J" 2>/dev/null && [ -s "$J" ] && [ "$(od -An -tx1 -N4 "$J" | tr -d ' ')" = "feedfeed" ]; then
    echo "JKS decoded from base64 -> $J"
  else
    cp "$S" "$J" 2>/dev/null
    echo "JKS copied -> $J"
  fi
fi
mkdir -p /root
cat > /root/.bazelrc << 'EOF'
startup --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/squid-bazel-trust/squid-bazel-trust.jks
startup --host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit
common --registry=https://gh-proxy.test.osinfra.cn/https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/
EOF
chmod 644 /root/.bazelrc
P=/etc/squid-ca/squid-ca.pem
if [ -f "$P" ]; then
  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    cp "$P" /etc/pki/ca-trust/source/anchors/squid-ca.pem >/dev/null 2>&1
    update-ca-trust extract >/dev/null 2>&1
  else
    cp "$P" /usr/local/share/ca-certificates/squid-ca.crt >/dev/null 2>&1
    update-ca-certificates -f >/dev/null 2>&1
  fi
fi
if command -v apt-get >/dev/null 2>&1 && [ -n "$HTTPS_PROXY" ]; then
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::http::Proxy "http://squid-cache.squid.svc.cluster.local:3128";\\nAcquire::https::Proxy "http://squid-cache.squid.svc.cluster.local:3128";\\n' > /etc/apt/apt.conf.d/99squid-proxy
fi
exit 0
"""


# ── Result judgment ────────────────────────────────────────────────────
# Volcano phase "Aborted" is NOT a reliable pass/fail signal: the source
# YAML ships a policy `event: PodFailed -> action: AbortJob`, so ANY
# non-zero exit from the main container triggers AbortJob. Many of these
# are actually "successful runs" (clone/submodule/compile/UT completed,
# only a trailing artifact copy like `cp CODE/time_data.json` failed, or
# `no need exec UT` short-circuit). So we judge success by parsing the
# captured log instead of trusting the phase.

PASS_MARKERS = [
    "All tests passed",
    "PASSED",                   # pytest/unittest pass lines
    "1 passed",
    "Command executed successfully",
]

# Real failures = HTTP/network layer broke, or a hard tool error.
# We deliberately do NOT treat bare "error:" / "squid" / "SSL" as failures:
# those substrings appear in normal output (env vars, mount paths, git noise).
FAIL_MARKERS = [
    "Traceback (most recent call last):",
    "ERROR:",
    "fatal:",
    "BUILD FAILED",
    "Connection refused",
    "proxy CONNECT failed",
    "HTTP proxy returned",
    "502 Bad Gateway",
    "503 Service Unavailable",
    "504 Gateway Timeout",
    "certificate verify failed",
    "SSL handshake",
    "Temporary failure in name resolution",
    "Could not resolve host",
]

# markers that prove HTTP/squid traffic actually flowed through the proxy
HTTP_SUCCESS_MARKERS = [
    "Cloning into",
    "Receiving objects",
    "Submodule path",
    "checked out",
    "git config --global",
]


def judge_result(log_path, phase, exit_code=None):
    """Parse the main container log and return a verdict.

    verdicts:
      "passed"  — job reached terminal AND log shows no real failure
                  (UT skipped / tests passed / all steps OK)
      "failed"  — job reached terminal but log contains a real error
      "unknown" — no log available

    exit_code (int|None): the main container's exit code. When available it
    is authoritative: the source YAML ships `PodFailed -> AbortJob`, so the
    Volcano phase alone can't distinguish pass/fail, but the main container's
    own exit code can. exit 0 -> passed, non-zero -> failed.
    """
    if exit_code is not None:
        return "passed" if exit_code == 0 else "failed"

    try:
        text = open(log_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return "unknown"

    if not text.strip():
        return "unknown"

    # If the job is still running or was never terminal, we can't judge.
    if phase not in ("Completed", "Failed", "Aborted"):
        return "unknown"

    # Fatal markers win — something actually broke in the run.
    for m in FAIL_MARKERS:
        if m in text:
            return "failed"

    # Otherwise: if we see a clear success marker, call it passed.
    for m in PASS_MARKERS:
        if m in text:
            return "passed"

    # No explicit pass marker: treat terminal-without-error as passed only
    # if the log looks like a completed run (has clone/submodule output).
    if any(m in text for m in HTTP_SUCCESS_MARKERS):
        return "passed"

    return "unknown"


def load_json(path):
    try:
        return json.load(open(path))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False, default=str)


def kubectl(args):
    return subprocess.run(["kubectl", "--kubeconfig", KC] + args,
                          capture_output=True, text=True, timeout=120)


def strip_karmada(md):
    md["labels"] = {
        k: v for k, v in md.get("labels", {}).items()
        if "karmada" not in k and "work.karmada" not in k
    }
    md["annotations"] = {
        k: v for k, v in (md.get("annotations") or {}).items()
        if "karmada" not in k
    }
    if not md["annotations"]:
        md.pop("annotations", None)


def transform_yaml(doc, src_basename):
    """Transform a VCJob YAML for squid reinjection (mirrors gen-reinject.py)."""
    doc = copy.deepcopy(doc)
    md = doc["metadata"]
    md.pop("generateName", None)
    name = src_basename.replace(".yaml", "")
    md["name"] = name + "-ri"
    strip_karmada(md)
    md["labels"]["pipeline/run-id"] = "squid-reinject"
    md["labels"]["squid.ci/reinject"] = "true"

    spec = doc["spec"]
    spec["ttlSecondsAfterFinished"] = 3600

    ts = spec["tasks"][0]["template"]["spec"]
    # 移除 heartbeat 与 copy-artifact 侧边容器：
    # - heartbeat 是心跳占位，不需要
    # - copy-artifact 在 ascend 退出 0（成功）时设计为永远循环等待外部 TERM，
    #   reinject 后没有框架发 TERM，会导致 VCJob 永不进入终态而卡死。
    ts["containers"] = [c for c in ts["containers"]
                        if c.get("name") not in ("heartbeat", "copy-artifact")]
    main = ts["containers"][0]
    assert main["name"] == "ascend", f"expected 'ascend' container, got '{main.get('name')}'"

    for e in main.get("env", []):
        if e.get("name") in PROXY_ENV:
            PROXY_ENV.pop(e["name"])
    main.setdefault("env", []).extend(
        {"name": k, "value": v} for k, v in PROXY_ENV.items()
    )

    main.setdefault("volumeMounts", []).extend([
        {"name": "squid-ca", "mountPath": "/etc/squid-ca", "readOnly": True}
    ])
    main["lifecycle"] = {
        "postStart": {
            "exec": {
                "command": ["/bin/bash", "-c", POSTSTART]
            }
        }
    }
    ts["volumes"] = ts.get("volumes", []) + [
        {
            "name": "squid-ca",
            "secret": {"secretName": "squid-ca-cert", "optional": True},
        }
    ]
    return doc


# ── Queue 3 core logic ─────────────────────────────────────────────────

def reconcile_running(results):
    """On startup, check all 'running' items to see if they've finished."""
    changed = False
    for tk, entry in list(results.items()):
        if entry.get("status") != "running":
            continue
        ns = entry.get("ns", "")
        name = entry.get("name", "")
        # running items created by run_one store the reinjected name (with -ri suffix).
        # Older entries may store the original job name — append -ri in that case.
        ri_name = name if name.endswith("-ri") else name + "-ri"
        print(f"  [queue3] reconciling running: {ns}/{ri_name} ({tk[:8]})", file=sys.stderr)
        r = kubectl(["get", "vj", ri_name, "-n", ns,
                      "-o", "jsonpath={.status.state.phase}"])
        phase = r.stdout.strip() if r.returncode == 0 else ""
        if phase in ("Completed", "Failed", "Aborted"):
            entry["status"] = phase
            entry["end_ts"] = time.time()
            changed = True
            print(f"  [queue3] reconciled {ns}/{ri_name} -> {phase}", file=sys.stderr)
        elif phase == "":
            # Job no longer exists — likely GC'd. Mark as unknown.
            entry["status"] = "unknown"
            entry["end_ts"] = time.time()
            changed = True
            print(f"  [queue3] reconciled {ns}/{ri_name} -> GC'd (unknown)", file=sys.stderr)
    if changed:
        write_json(os.path.join(HERE, "results.json"), results)


def run_one(entry, outdir):
    """Process one type_key: transform, apply, monitor, record."""
    tk = entry["type_key"]
    src_yaml = os.path.join(outdir, "unique", f"{entry['ns']}-{entry['name']}.yaml")
    if not os.path.exists(src_yaml):
        print(f"  [queue3] SKIP {tk[:8]}: {src_yaml} not found", file=sys.stderr)
        return None

    # 1. Transform YAML with squid proxy injection
    doc = yaml.safe_load(open(src_yaml))
    doc = transform_yaml(doc, os.path.basename(src_yaml))
    ri_name = doc["metadata"]["name"]

    # 2. Write transformed YAML
    done_dir = os.path.join(outdir, "done", tk[:16])
    os.makedirs(done_dir, exist_ok=True)
    ri_yaml = os.path.join(done_dir, f"{ri_name}.yaml")
    yaml.safe_dump(doc, open(ri_yaml, "w"), sort_keys=False, default_flow_style=False, width=200)
    ns = doc["metadata"]["namespace"]

    # 3. Apply
    print(f"  [queue3] apply {ri_name} (ns={ns})", file=sys.stderr)
    r = kubectl(["apply", "-f", ri_yaml])
    if r.returncode != 0:
        print(f"  [queue3] APPLY FAILED: {r.stderr.strip()[:200]}", file=sys.stderr)
        return {"status": "apply_failed", "error": r.stderr.strip()[:300]}

    # 4. Poll until terminal
    t0 = time.time()
    phase = "Pending"
    while True:
        r = kubectl(["get", "vj", ri_name, "-n", ns,
                      "-o", "jsonpath={.status.state.phase}"])
        phase = r.stdout.strip() if r.returncode == 0 else "Pending"
        if phase in ("Completed", "Failed", "Aborted"):
            break
        time.sleep(30)

    t1 = time.time()
    dur_min = (t1 - t0) / 60

    # 5. Capture pod logs
    pod_r = kubectl(["get", "pods", "-n", ns,
                      "-l", f"volcano.sh/job-name={ri_name}",
                      "-o", "name"])
    pod_name = ""
    if pod_r.returncode == 0 and pod_r.stdout.strip():
        pod_name = pod_r.stdout.strip().split("/", 1)[-1].strip()
        log_main = os.path.join(done_dir, f"{ri_name}.log")
        log_copy = os.path.join(done_dir, f"{ri_name}-copy.log")
        with open(log_main, "w") as f:
            subprocess.run(["kubectl", "--kubeconfig", KC, "logs", pod_name, "-n", ns],
                           stdout=f, stderr=subprocess.STDOUT, timeout=60)
        with open(log_copy, "w") as f:
            subprocess.run(["kubectl", "--kubeconfig", KC, "logs", pod_name, "-n", ns, "-c", "copy-artifact", "--tail=100"],
                           stdout=f, stderr=subprocess.STDOUT, timeout=30)

    # 6. Judge pass/fail. The main container's exit code is authoritative:
    #    source YAML has `PodFailed -> AbortJob`, so the Volcano phase alone
    #    can't tell pass from fail (successful runs also surface as Aborted
    #    when the main container exits non-zero, or when the trailing
    #    artifact-copy step fails). exit 0 = passed, non-zero = failed.
    verdict = "unknown"
    exit_code = None
    if pod_name:
        c_r = kubectl(["get", "pod", pod_name, "-n", ns,
                       "-o", "jsonpath={.status.containerStatuses[0].state.terminated.exitCode}"])
        if c_r.returncode == 0 and c_r.stdout.strip():
            try:
                exit_code = int(c_r.stdout.strip())
            except ValueError:
                exit_code = None
    if log_main and os.path.exists(log_main):
        verdict = judge_result(log_main, phase, exit_code=exit_code)
    print(f"  [queue3] {ri_name} -> {phase} / exit={exit_code} / verdict={verdict} in {dur_min:.1f}m", file=sys.stderr)

    result = {
        "status": phase,
        "verdict": verdict,
        "exit_code": exit_code,
        "ns": ns,
        "name": ri_name,
        "image": entry.get("desc", "").split(" | ")[0],
        "start_ts": t0,
        "end_ts": t1,
        "dur_min": round(dur_min, 1),
        "pod": pod_name,
        "done_dir": done_dir,
        "type_key": tk,
        "type_desc": entry.get("desc", ""),
    }
    write_json(os.path.join(done_dir, "result.json"), result)
    print(f"  [queue3] {ri_name} -> {phase} in {dur_min:.1f}m", file=sys.stderr)
    return result


def main():
    global KC
    ap = argparse.ArgumentParser(description="Queue 3: continuous reinjector")
    ap.add_argument("--interval", type=int, default=1800, help="seconds between submits (default 1800 = 30min)")
    ap.add_argument("--outdir", default=HERE)
    ap.add_argument("--kubeconfig", default=KC)
    args = ap.parse_args()

    KC = args.kubeconfig

    pending_path = os.path.join(args.outdir, "pending.json")
    results_path = os.path.join(args.outdir, "results.json")
    dedup_path = os.path.join(args.outdir, "dedup.json")

    # Load existing results
    results = load_json(results_path)
    # Reconcile any "running" items from previous runs
    reconcile_running(results)

    while True:
        # Wait for pending items (checks every 60s, doesn't block the full interval)
        while True:
            pending = load_json(pending_path)
            if isinstance(pending, list) and pending:
                break
            print(f"  [queue3] nothing pending, check again in 60s", file=sys.stderr)
            time.sleep(60)

        dedup = {e["type_key"]: e for e in load_json(dedup_path)}

        # FIFO: pick the first pending item
        tk = pending[0]
        entry = dedup.get(tk)
        if not entry:
            print(f"  [queue3] WARN: {tk[:8]} not found in dedup.json, removing", file=sys.stderr)
            pending = pending[1:]
            write_json(pending_path, pending)
            continue

        # Skip if already in results (running or completed)
        if tk in results:
            print(f"  [queue3] SKIP {tk[:8]}: already in results ({results[tk]['status']})", file=sys.stderr)
            pending = [p for p in pending if p != tk]
            write_json(pending_path, pending)
            continue

        # Mark as running in results (atomic: write before actual apply).
        # name must match what transform_yaml produces ({ns}-{name}-ri) so that
        # crash recovery reconcile_running can find the job on the cluster.
        ri_name = f"{entry['ns']}-{entry['name']}-ri"
        results[tk] = {"status": "running", "ns": entry["ns"], "name": ri_name,
                        "type_key": tk, "type_desc": entry.get("desc", "")}
        write_json(results_path, results)

        # Remove from pending
        pending = [p for p in pending if p != tk]
        write_json(pending_path, pending)

        # Run the reinjection test
        result = run_one(entry, args.outdir)
        if result:
            results[tk] = result
        else:
            results[tk]["status"] = "error"

        write_json(results_path, results)
        print(f"  [queue3] done. pending={len(pending)}, results={len(results)}", file=sys.stderr)

        # Wait for next interval
        time.sleep(args.interval)


if __name__ == "__main__":
    main()