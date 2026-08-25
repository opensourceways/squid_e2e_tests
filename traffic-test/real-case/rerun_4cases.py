#!/usr/bin/env python3
"""rerun_4cases.py — rerun the 4 torch-missing cases with squid injection.

Loads queue3-reinject.py's run_one/transform_yaml via importlib and runs
them sequentially against a dedicated outdir so the queue3 daemon's
pending.json/results.json are left untouched.
"""
import importlib.util
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Load queue3-reinject.py as a module despite the '-' in its filename
spec = importlib.util.spec_from_file_location(
    "q3", os.path.join(HERE, "queue3-reinject.py"))
q3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q3)

OUTDIR = os.path.join(HERE, "rerun_4cases")
os.makedirs(os.path.join(OUTDIR, "unique"), exist_ok=True)

# The 4 torch-missing cases (from dedup.json)
# 5282e60f and 66b32138 already rerun PASSED (exit=0); remaining 2:
CASES = [
    {"type_key": "6d3aa1155360192d1512cb7cbb8231bd4787191e",
     "ns": "op-plugin", "name": "ascend-pytorch-d4wcc"},
    {"type_key": "0aa894edd446d3370a147199303fe66684f50628",
     "ns": "op-plugin", "name": "ascend-pytorch-r5t9b"},
]

# Load type_desc from dedup.json
dedup = {e["type_key"]: e for e in json.load(open(os.path.join(HERE, "dedup.json")))}


def main():
    results = {}
    for c in CASES:
        tk = c["type_key"]
        entry = dedup.get(tk)
        if not entry:
            print(f"  [rerun] WARN: {tk[:8]} not in dedup.json, skipping", file=sys.stderr)
            continue
        # Ensure the unique yaml is present in OUTDIR/unique
        src = os.path.join(HERE, "unique", f"{c['ns']}-{c['name']}.yaml")
        dst = os.path.join(OUTDIR, "unique", f"{c['ns']}-{c['name']}.yaml")
        if not os.path.exists(dst) and os.path.exists(src):
            shutil.copy2(src, dst)

        print(f"\n  [rerun] === {tk[:8]} ({c['name']}) ===", file=sys.stderr)
        try:
            result = q3.run_one(entry, OUTDIR)
        except Exception as e:
            import traceback
            print(f"  [rerun] {tk[:8]} EXCEPTION: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            result = None
        if result:
            results[tk] = result
            print(f"  [rerun] {tk[:8]} -> {result.get('verdict')} / exit={result.get('exit_code')} "
                  f"in {result.get('dur_min')}m", file=sys.stderr)
        else:
            print(f"  [rerun] {tk[:8]} -> ERROR (no result)", file=sys.stderr)

    # Summarize
    print("\n=== RERUN SUMMARY ===")
    for tk, r in results.items():
        print(f"{tk[:8]} {r.get('name','')} verdict={r.get('verdict')} exit={r.get('exit_code')} dur={r.get('dur_min')}m")
    with open(os.path.join(OUTDIR, "rerun_results.json"), "w") as f:
        json.dump(results, f, indent=1, ensure_ascii=False, default=str)
    print(f"results written to {os.path.join(OUTDIR, 'rerun_results.json')}")


if __name__ == "__main__":
    main()
