#!/usr/bin/env python3
"""gen-replicas.py — clone a tool yaml with tasks[0].replicas set to N.

Usage: gen-replicas.py <src.yaml> <out.yaml> [replicas]
"""
import sys
import yaml

src, out = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 10

doc = yaml.safe_load(open(src))
task = doc['spec']['tasks'][0]
task['replicas'] = n
doc['metadata']['labels'].setdefault('pipeline/run-id', 'x')
doc['metadata']['labels']['pipeline/run-id'] += f'-trafficx{n}'

with open(out, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=1000000)
print(f"wrote {out} (replicas={n})")
