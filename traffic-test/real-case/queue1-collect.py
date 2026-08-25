#!/usr/bin/env python3
"""queue1-collect.py — continuous VCJob collector (Queue 1).

Polls wlcb-001 VCJobs every 60s, captures each job's YAML as it reaches a
terminal state, writes samples.tsv and vcjobs.json.  Runs forever — no
--duration limit.

Usage:
  ./queue1-collect.py [--interval 60] [--outdir .]

Outputs:
  samples.tsv    raw poll stream (ts ns name phase repo prid runid arch image)
  vcjobs.json    accumulated per-(ns,name) state
  yaml/<ns>-<name>.yaml   clean job YAML captured at terminal state
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KC = os.environ.get("KUBECONFIG", os.path.expanduser("~/.kube/wlcb-001.yaml"))
TERMINAL = {"Completed", "Failed", "Aborted"}

DROP_META = (
    "creationTimestamp:", "resourceVersion:", "uid:", "selfLink:",
    "generation:", "managedFields:",
)


def run(args):
    return subprocess.run(["kubectl", "--kubeconfig", KC] + args,
                          capture_output=True, text=True, timeout=90)


def list_vj():
    r = run(["get", "vj", "-A", "-o", "json"])
    if r.returncode != 0:
        print(f"  [warn] list vj failed: {r.stderr.strip()[:300]}", file=sys.stderr)
        return {}
    try:
        docs = json.loads(r.stdout).get("items", [])
    except json.JSONDecodeError:
        return {}
    out = {}
    for d in docs:
        key = (d["metadata"].get("namespace", ""), d["metadata"].get("name", ""))
        out[key] = extract(d)
    return out


def extract(d):
    m, st = d.get("metadata", {}), d.get("status", {})
    labels = {k: v for k, v in m.get("labels", {}).items()
              if k in ("jobPRID", "jobRepositoryName", "pipeline/run-id",
                       "kubernetes.io/arch")}
    phase = st.get("state", {}).get("phase", "")
    image = cmd = args = None
    for task in d.get("spec", {}).get("tasks", []):
        tpl = task.get("template", {}).get("spec", {})
        for c in tpl.get("containers", []):
            if image is None:
                image = c.get("image")
            if c.get("command") or c.get("args"):
                image = c.get("image")
                cmd, args = c.get("command"), c.get("args")
                break
        if cmd or args:
            break
    return dict(phase=phase, labels=labels, image=image, command=cmd, args=args)


def type_key(d):
    """Traffic-pattern type_key: sha1(image-tag-without-date | script-type | branch).

    按流量模式去重，折叠每条 PR 的噪声（MR 号 / run-id / 日期）：
      - 镜像 tag 去掉 :YYYYMMDD 日期后缀（如
        pytorch_2.7.1_a2_aarch64_builder:20260804 → pytorch_2.7.1_a2_aarch64_builder），
        非 builder 镜像保留原 tag
      - 脚本类型：从 args 里找 `UT/<script>.sh`（pytorch_ut_general/dist/inductor）
      - 分支：从 args 里找 `merge.sh <branch>`
    约 16-31 个语义类（pytorch UT 版本 x 脚本类型，加非 pytorch 各 1 类）。
    """
    import hashlib
    import re

    img_key = (d["image"] or "").split("/")[-1]
    img_key = re.sub(r":\d{8}$", "", img_key)  # 去掉日期后缀

    args = d.get("args") or []
    args_txt = "\n".join(str(a) for a in args) if isinstance(args, list) else str(args)

    m = re.search(r"UT/([a-z0-9_]+\.sh)", args_txt)
    script = m.group(1) if m else "no-ut"

    m = re.search(r"merge\.sh\s+(\S+)", args_txt)
    branch = m.group(1) if m else "no-branch"

    blob = "|".join([img_key, script, branch])
    return hashlib.sha1(blob.encode()).hexdigest()


def human_desc(d):
    """可读描述：image-tag | script-type | branch"""
    img = (d.get("image") or "?").split("/")[-1]
    import re
    args = d.get("args") or []
    args_txt = "\n".join(str(a) for a in args) if isinstance(args, list) else str(args)
    m = re.search(r"UT/([a-z0-9_]+\.sh)", args_txt)
    script = m.group(1) if m else "no-ut"
    m = re.search(r"merge\.sh\s+(\S+)", args_txt)
    branch = m.group(1) if m else "no-branch"
    return f"{img} | {script} | {branch}"


def drop_line(ln):
    s = ln.lstrip()
    return any(s == m or s.startswith(m) for m in DROP_META)


def fetch_yaml_text(ns, name):
    r = run(["get", "vj", name, "-n", ns, "-o", "yaml"])
    if r.returncode != 0:
        return None
    keep, skip = [], False
    for ln in r.stdout.splitlines():
        stripped = ln.lstrip()
        if ln == "status:" or stripped == "status:":
            skip = True
            continue
        if skip and ln and not ln[:1].isspace():
            skip = False
        if drop_line(ln):
            if "managedFields" in ln:
                skip = True
            continue
        if stripped.startswith("clusterpropagationpolicy.karmada.io/") or \
           stripped.startswith("resourcetemplate.karmada.io/") or \
           stripped.startswith("work.karmada.io/") or \
           stripped.startswith("resourcebinding.karmada.io/") or \
           stripped.startswith("kubectl.kubernetes.io/"):
            continue
        if not skip:
            keep.append(ln)
    return "\n".join(keep) + "\n"


def main():
    global KC
    ap = argparse.ArgumentParser(description="Queue 1: continuous VCJob collector")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--outdir", default=HERE)
    ap.add_argument("--kubeconfig", default=KC)
    args = ap.parse_args()
    KC = args.kubeconfig

    os.makedirs(os.path.join(args.outdir, "yaml"), exist_ok=True)
    spath = os.path.join(args.outdir, "samples.tsv")
    jpath = os.path.join(args.outdir, "vcjobs.json")

    state = {}
    if os.path.exists(jpath):
        try:
            raw = json.load(open(jpath))
            state = {(k.split("/", 1)[0], k.split("/", 1)[1]): v
                     for k, v in raw.items()}
        except Exception:
            state = {}

    while True:
        poll_ts = time.time()
        jobs = list_vj()
        print(f"  [queue1] {time.strftime('%H:%M:%S')} jobs={len(jobs)}", file=sys.stderr)
        for key, d in jobs.items():
            ns, name = key
            st = state.setdefault(key, dict(
                namespace=ns, name=name, first_seen=poll_ts, last_seen=poll_ts,
                phases=[], terminal=None, terminal_ts=None, yaml=None,
                type_key=None, type_desc=None, labels={},
            ))
            st["last_seen"] = poll_ts
            st["phase"] = d["phase"]
            st["labels"] = {**st["labels"], **d["labels"]}
            if st["type_key"] is None and d["image"]:
                st["type_key"] = type_key(d)
                st["type_desc"] = human_desc(d)
                st["image"] = d["image"]
            if d["phase"] and d["phase"] not in st["phases"]:
                st["phases"].append(d["phase"])
            if d["phase"] in TERMINAL and st["terminal"] is None:
                text = fetch_yaml_text(ns, name)
                fname = f"{ns}-{name}.yaml"
                if text is not None:
                    with open(os.path.join(args.outdir, "yaml", fname), "w") as f:
                        f.write(text)
                    st["yaml"] = fname
                st["terminal"] = d["phase"]
                st["terminal_ts"] = poll_ts
                print(f"  [queue1] {ns}/{name} -> {d['phase']} ({fname})", file=sys.stderr)

        with open(spath, "w") as f:
            f.write("# ts\tns\tname\tphase\trepo\tprid\trunid\tarch\timage\n")
            for (ns, name), st in sorted(state.items()):
                lab = st["labels"]
                f.write(f"{st['last_seen']}\t{ns}\t{name}\t{st.get('phase','')}\t"
                        f"{lab.get('jobRepositoryName','')}\t{lab.get('jobPRID','')}\t"
                        f"{lab.get('pipeline/run-id','')}\t{lab.get('kubernetes.io/arch','')}\t"
                        f"{st.get('image','')}\n")

        with open(jpath, "w") as f:
            json.dump({f"{k[0]}/{k[1]}": v for k, v in state.items()}, f,
                      indent=1, ensure_ascii=False, default=str)

        sleep_s = args.interval - (time.time() - poll_ts)
        if sleep_s > 0:
            time.sleep(sleep_s)


if __name__ == "__main__":
    main()