#!/usr/bin/env bash
# run-pipeline.sh — launch all 4 queues in the background.
#   ./run-pipeline.sh [--interval-q1 60] [--interval-q2 30] [--interval-q3 1800] [--interval-q4 60]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse optional overrides
Q1_INT=60
Q2_INT=30
Q3_INT=1800
Q4_INT=60
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval-q1) Q1_INT="$2"; shift 2 ;;
    --interval-q2) Q2_INT="$2"; shift 2 ;;
    --interval-q3) Q3_INT="$2"; shift 2 ;;
    --interval-q4) Q4_INT="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

echo "Starting queues:"
echo "  Q1 (collect)  interval=${Q1_INT}s"
echo "  Q2 (dedup)    interval=${Q2_INT}s"
echo "  Q3 (reinject) interval=${Q3_INT}s"
echo "  Q4 (record)   interval=${Q4_INT}s"

nohup python3 "$DIR/queue1-collect.py" --interval "$Q1_INT" --outdir "$DIR" \
  > "$DIR/queue1.log" 2>&1 &
echo "  Q1 pid=$!"

nohup python3 "$DIR/queue2-dedup.py" --interval "$Q2_INT" --outdir "$DIR" \
  > "$DIR/queue2.log" 2>&1 &
echo "  Q2 pid=$!"

nohup python3 "$DIR/queue3-reinject.py" --interval "$Q3_INT" --outdir "$DIR" \
  > "$DIR/queue3.log" 2>&1 &
echo "  Q3 pid=$!"

nohup python3 "$DIR/queue4-record.py" --watch "$Q4_INT" --outdir "$DIR" \
  > "$DIR/queue4.log" 2>&1 &
echo "  Q4 pid=$!"

echo "All queues started. Logs: queue{1,2,3,4}.log"
echo "Stop with: kill $(jobs -p)"