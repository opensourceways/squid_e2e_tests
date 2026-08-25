#!/usr/bin/env python3
"""queue2-dedup.py — continuous VCJob deduplicator (Queue 2).

Watches vcjobs.json for new terminal jobs, deduplicates by type_key
(sha1 of image+command+args), writes new unique types to:
  - unique/<ns>-<name>.yaml  (representative YAML)
  - pending.json             (queue of type_keys to test)
  - dedup.json               (full dedup index)

Usage:
  ./queue2-dedup.py [--interval 30] [--outdir .]
"""
import argparse
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_json(path):
    try:
        return json.load(open(path))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False, default=str)


def is_real_ci_job(yaml_path):
    """Check if the YAML has an 'ascend' container (real CI job)."""
    if not os.path.exists(yaml_path):
        return False
    import yaml
    try:
        doc = yaml.safe_load(open(yaml_path))
        for task in doc.get("spec", {}).get("tasks", []):
            for c in task.get("template", {}).get("spec", {}).get("containers", []):
                if c.get("name") == "ascend":
                    return True
    except Exception:
        pass
    return False


def main():
    ap = argparse.ArgumentParser(description="Queue 2: continuous deduplicator")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--outdir", default=HERE)
    args = ap.parse_args()

    jpath = os.path.join(args.outdir, "vcjobs.json")
    dedup_path = os.path.join(args.outdir, "dedup.json")
    pending_path = os.path.join(args.outdir, "pending.json")
    uniq_dir = os.path.join(args.outdir, "unique")
    yaml_dir = os.path.join(args.outdir, "yaml")
    os.makedirs(uniq_dir, exist_ok=True)

    # Load existing dedup index (type_key → entry)
    dedup = {e["type_key"]: e for e in load_json(dedup_path)}
    # Load pending queue (list of type_keys)
    pending = load_json(pending_path)
    if not isinstance(pending, list):
        pending = []

    last_seen_count = 0  # track new terminal jobs

    while True:
        vj = load_json(jpath)
        terminal = [st for st in vj.values() if st.get("terminal") and st.get("yaml")]
        new_count = 0

        for st in terminal:
            tk = st.get("type_key")
            if not tk:
                continue
            src = os.path.join(yaml_dir, st["yaml"])
            dst = os.path.join(uniq_dir, f"{st['namespace']}-{st['name']}.yaml")

            if tk in dedup:
                # 重复类型（replace 策略）：用新 job 的 YAML 替换旧代表。
                # 先删除旧代表文件（旧 entry 里记录的 yaml 名），再写新的，
                # 避免 unique/ 里每个重复 job 都留一个文件。
                old = dedup[tk].get("yaml")
                if old and old != st["yaml"]:
                    old_dst = os.path.join(uniq_dir, old)
                    if os.path.exists(old_dst):
                        os.remove(old_dst)
                if os.path.exists(src):
                    shutil.copy2(src, dst)
                dedup[tk] = dict(
                    type_key=tk, desc=st["type_desc"], ns=st["namespace"],
                    name=st["name"], phases=st["phases"], terminal=st["terminal"],
                    terminal_ts=st["terminal_ts"], yaml=st["yaml"], labels=st["labels"],
                )
                print(f"  [queue2] replace: {tk[:8]} {st['type_desc'][:80]}", file=sys.stderr)
                new_count += 1
                continue

            # Skip non-real-CI jobs (no 'ascend' container)
            if not is_real_ci_job(src):
                # Still track in dedup to avoid re-processing, but don't add to pending
                dedup[tk] = dict(
                    type_key=tk, desc=st["type_desc"], ns=st["namespace"],
                    name=st["name"], phases=st["phases"], terminal=st["terminal"],
                    terminal_ts=st["terminal_ts"], yaml=st["yaml"], labels=st["labels"],
                )
                new_count += 1
                continue
            # New unique type discovered
            if os.path.exists(src):
                shutil.copy2(src, dst)
                print(f"  [queue2] new unique: {tk[:8]} {st['type_desc'][:80]}", file=sys.stderr)

            entry = dict(
                type_key=tk, desc=st["type_desc"], ns=st["namespace"],
                name=st["name"], phases=st["phases"], terminal=st["terminal"],
                terminal_ts=st["terminal_ts"], yaml=st["yaml"], labels=st["labels"],
            )
            dedup[tk] = entry
            pending.append(tk)
            new_count += 1

        if new_count:
            # Dedup pending list (shouldn't have dupes, but be safe)
            seen = set()
            unique_pending = []
            for tk in pending:
                if tk not in seen:
                    seen.add(tk)
                    unique_pending.append(tk)
            pending = unique_pending

            write_json(dedup_path, sorted(dedup.values(), key=lambda e: e["type_key"]))
            write_json(pending_path, pending)
            print(f"  [queue2] +{new_count} new types, pending={len(pending)} total={len(dedup)}", file=sys.stderr)

        if len(terminal) != last_seen_count:
            last_seen_count = len(terminal)

        time.sleep(args.interval)


if __name__ == "__main__":
    main()