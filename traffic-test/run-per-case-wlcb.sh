#!/usr/bin/env bash
# run each case one by one on wlcb-001, with per-case traffic monitor
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/wlcb-001.yaml}"
DIR="/home/chenqi252/code/gitcode-ci/workspace-squid/squid_e2e_tests/traffic-test"
LOG_DIR="$DIR/logs/tool-wlcb"
MONITOR_PY="$DIR/monitor-traffic.sh"
MONITOR_DUR=1800

export KUBECONFIG
export LOG_DIR
mkdir -p "$LOG_DIR/per-case"

CASES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16)

for c in "${CASES[@]}"; do
  name=$(ls "$DIR/tool/$c"*.yaml 2>/dev/null | head -1 | xargs basename .yaml 2>/dev/null || echo "case-$c")
  echo ""
  echo "=============================================="
  echo "CASE $c ($name)"
  echo "=============================================="
  
  # Start monitor in background
  MONITOR_OUT="$LOG_DIR/per-case/$c-traffic.tsv"
  : > "$MONITOR_OUT"
  bash "$MONITOR_PY" "$MONITOR_DUR" "$MONITOR_OUT" > "$LOG_DIR/per-case/$c-monitor.log" 2>&1 &
  MON_PID=$!
  
  # Run the case
  bash "$DIR/run-tool-traffic.sh" "$c" 2>&1
  
  # Stop monitor
  sleep 5
  kill "$MON_PID" 2>/dev/null || true
  wait "$MON_PID" 2>/dev/null || true
  
  # Save logs
  mv "$LOG_DIR/timeline.tsv" "$LOG_DIR/per-case/$c-timeline.tsv" 2>/dev/null || true
  
  echo "CASE $c done. Traffic data: $MONITOR_OUT"
done

echo ""
echo "ALL CASES COMPLETE"