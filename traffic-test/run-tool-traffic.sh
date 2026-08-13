#!/usr/bin/env bash
# run-tool-traffic.sh — 10-parallel-task traffic test for the tool cases
# in squid-openssl/testcase/tool (cases 01..16), with per-case timestamps
# recorded for access.log window alignment.
#
# Usage:
#   ./run-tool-traffic.sh 01 02 03 ... 16        # run selected cases (serial)
#   ./run-tool-traffic.sh --all                  # run all 16 cases
#   ./run-tool-traffic.sh --monitor 7200         # also sample squid traffic
#
# Logs:       traffic-test/logs/tool/<case>-<job>/<pod>.log
# Timeline:   traffic-test/logs/tool/timeline.tsv  (ts  case  action  job)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
NS="squid"
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="${TOOL_DIR:-$DIR/../../squid-openssl/testcase/tool}"
GEN="$DIR/gen-replicas.py"
GEN_DIR="$DIR/traffic-gen"
LOG_DIR="$DIR/logs/tool"
MONITOR=0
MONITOR_DUR=7200

kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
tl() { echo -e "$(date +%s)\t$1\t$2\t$3" >> "$LOG_DIR/timeline.tsv"; }

CASES=()
for a in "$@"; do
  case "$a" in
    --all) CASES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16) ;;
    --monitor) MONITOR=1 ;;
    --monitor=*) MONITOR=1; MONITOR_DUR="${a#*=}" ;;
    [0-9][0-9]) CASES+=("$a") ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done
[ ${#CASES[@]} -eq 0 ] && { echo "usage: $0 01 02 ... | --all [--monitor[=S]]" >&2; exit 1; }
for c in "${CASES[@]}"; do
  ls "$TOOL_DIR/$c"*.yaml >/dev/null 2>&1 || { echo "case $c: yaml not found" >&2; exit 1; }
done

mkdir -p "$GEN_DIR" "$LOG_DIR"
: > "$LOG_DIR/timeline.tsv"

[ "$MONITOR" = "1" ] && {
  echo "starting traffic monitor (${MONITOR_DUR}s)..."
  "$DIR/monitor-traffic.sh" "$MONITOR_DUR" "$LOG_DIR/traffic.tsv" > "$LOG_DIR/traffic-monitor.log" 2>&1 &
  MON_PID=$!
}

submit_case() { # case-num → job
  local num="$1" src gen
  src=$(ls "$TOOL_DIR/$num"*.yaml | head -1)
  gen="$GEN_DIR/$num-traffic.yaml"
  python3 "$GEN" "$src" "$gen" 10 > /dev/null
  local out jname
  out=$(kc create -f "$gen" 2>&1)
  jname=$(echo "$out" | grep -oE 'job\.batch\.volcano\.sh/[a-z0-9-]+' | tail -1 | cut -d/ -f2)
  if [ -z "$jname" ]; then
    echo "case $num: submit failed: $out" >&2
    tl "$num" SUBMIT_FAIL "$out"
    return 1
  fi
  echo "$jname"
}

wait_case() { # job → rc
  local job="$1" done=0 pod
  local end=$(( $(date +%s) + 3600 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    done=1
    for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
      case "$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)" in
        Succeeded) ;;
        Failed) echo "  pod FAILED: $pod"; done=2 ;;
        *) done=0 ;;
      esac
    done
    [ "$done" = "1" ] && return 0
    [ "$done" = "2" ] && return 1
    sleep 10
  done
  echo "  TIMEOUT" >&2
  return 1
}

for c in "${CASES[@]}"; do
  name=$(basename "$(ls "$TOOL_DIR/$c"*.yaml | head -1)" .yaml)
  echo "== case $c ($name): submitting replicas=10 =="
  job=$(submit_case "$c") || { tl "$c" FAILED "-"; continue; }
  tl "$c" SUBMIT "$job"
  sleep 5
  if wait_case "$job"; then
    sleep 5
    mkdir -p "$LOG_DIR/$c-$name"
    i=0
    for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
      kc logs -n "$NS" "$pod" > "$LOG_DIR/$c-$name/pod-$i.log" 2>&1 || true
      i=$((i+1))
    done
    tl "$c" DONE "$job"
    echo "  done: $i pods → $LOG_DIR/$c-$name/"
  else
    tl "$c" FAILED "$job"
  fi
done

[ "$MONITOR" = "1" ] && { wait "$MON_PID" 2>/dev/null || true; }

echo ""
echo "== timeline =="
cat "$LOG_DIR/timeline.tsv"
echo "done"
