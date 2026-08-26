#!/usr/bin/env bash
# run.sh — submit traffic test jobs to gy-006 (namespace squid) and wait.
#
# Usage:
#   ./run.sh pip                      # pip traffic, 10 parallel tasks
#   ./run.sh git                      # git clone traffic, 10 parallel tasks
#   ./run.sh both                     # both, sequentially
#   ./run.sh git --monitor 900        # also sample squid traffic from central Prometheus
#
# Kubeconfig: KUBECONFIG env or ~/.kube/gy-006.yaml
# Logs:       traffic-test/logs/<yaml>-<job>.log (one per pod)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
NS="squid"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$DIR/logs"
MONITOR=0
MONITOR_DUR=600

kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }

SUB=""
for a in "$@"; do
  case "$a" in
    pip|git|both) SUB="$a" ;;
    --monitor) MONITOR=1 ;;
    --monitor=*) MONITOR=1; MONITOR_DUR="${a#*=}" ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done
[ -z "$SUB" ] && { echo "usage: $0 pip|git|both [--monitor[=SECONDS]]" >&2; exit 1; }

mkdir -p "$LOG_DIR"

submit_wait() { # yaml → 0/1 (collects all pod logs)
  local yaml="$1" name job pod
  name=$(basename "${yaml%.yaml}")
  echo "== submitting $name =="
  out=$(kc create -f "$yaml" 2>&1)
  job=$(echo "$out" | grep -oE 'job\.batch\.volcano\.sh/[a-z0-9-]+' | tail -1 | cut -d/ -f2)
  [ -z "$job" ] && { echo "submit failed: $out" >&2; return 1; }
  echo "   job: $job"

  local end=$(( $(date +%s) + 3600 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    local done=1
    for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
      case "$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)" in
        Succeeded) ;;
        Failed) echo "   POD FAILED: $pod"; done=2 ;;
        *) done=0 ;;
      esac
    done
    if [ "$done" = "1" ]; then
      echo "   all succeeded, collecting logs..."
      sleep 5
      local i=0
      for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
        kc logs -n "$NS" "$pod" > "$LOG_DIR/$name-$job-$i.log" 2>&1 || true
        i=$((i+1))
      done
      echo "   logs → $LOG_DIR/$name-$job-*.log"
      return 0
    elif [ "$done" = "2" ]; then
      kc logs -n "$NS" "$pod" > "$LOG_DIR/$name-$job-FAILED.log" 2>&1 || true
      return 1
    fi
    sleep 10
  done
  echo "   TIMEOUT waiting for $job" >&2
  return 1
}

[ "$MONITOR" = "1" ] && {
  echo "starting traffic monitor (${MONITOR_DUR}s) in background..."
  "$DIR/monitor-traffic.sh" "$MONITOR_DUR" "$LOG_DIR/traffic.tsv" > "$LOG_DIR/traffic-monitor.log" 2>&1 &
  MON_PID=$!
}

rc=0
case "$SUB" in
  pip)  submit_wait "$DIR/pip-traffic.yaml" || rc=1 ;;
  git)  submit_wait "$DIR/git-clone-traffic.yaml" || rc=1 ;;
  both) submit_wait "$DIR/pip-traffic.yaml" || rc=1
        submit_wait "$DIR/git-clone-traffic.yaml" || rc=1 ;;
esac

[ "$MONITOR" = "1" ] && { wait "$MON_PID" 2>/dev/null || true; echo "traffic samples: $LOG_DIR/traffic.tsv"; }

echo ""
echo "== summary (per-pod DURATION) =="
for f in "$LOG_DIR"/"$name"*.log; do
  [ -f "$f" ] || continue
  d=$(grep -oE 'DURATION: [0-9]+ms' "$f" | head -1 | sed 's/DURATION: //')
  t=$(basename "$f")
  echo "  $t → ${d:-n/a}"
done

exit $rc
