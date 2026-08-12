#!/usr/bin/env bash
# eval-logs.sh — fetch and print logs for all running/completed test-squid-* jobs
# Usage: ./eval-logs.sh [case-slug]  # if arg given, only that case
set -uo pipefail
cd "$(dirname "$0")"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
NS="squid"

filter_case="${1:-}"

echo "========================================"
echo "Fetching logs for test-squid-* jobs"
echo "========================================"

jobs=$(kc get jobs.batch.volcano.sh -n "$NS" --no-headers 2>/dev/null | awk '$1 ~ /^test-squid-/ {print $1}')
if [ -z "$jobs" ]; then
  echo "No jobs found"
  exit 0
fi

for job in $jobs; do
  slug=$(echo "$job" | sed -E 's/test-squid-([a-z0-9]+)-.*/\1/')
  if [ -n "$filter_case" ] && [ "$slug" != "$filter_case" ]; then
    continue
  fi
  
  pod=$(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    echo "[$job] NO POD"
    continue
  fi
  
  phase=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  reason=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")
  exitcode=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
  
  http_proxy=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.spec.containers[0].env[?(@.name=="HTTP_PROXY")].value}' 2>/dev/null || echo "")
  variant="direct"
  if [ -n "$http_proxy" ]; then variant="squid"; fi
  
  echo ""
  echo "========================================"
  echo "Job: $job"
  echo "Slug: $slug  Variant: $variant"
  echo "Pod: $pod  Phase: $phase  Reason: $reason  Exit: $exitcode"
  echo "========================================"
  
  if [ "$phase" == "Running" ]; then
    echo "[LOG TAIL — still running]"
    kc logs -n "$NS" "$pod" --tail=20 2>&1 || echo "Failed to fetch logs"
  else
    echo "[FULL LOG]"
    kc logs -n "$NS" "$pod" 2>&1 || echo "Failed to fetch logs"
  fi
  
  # Extract DURATION if present
  duration=$(kc logs -n "$NS" "$pod" 2>/dev/null | grep -o "DURATION: [0-9]*ms" || echo "")
  if [ -n "$duration" ]; then
    echo ""
    echo ">>> $duration <<<"
  fi
done

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
kc get jobs.batch.volcano.sh -n "$NS" --no-headers 2>/dev/null | awk '$1 ~ /^test-squid-/ {print $1, $2}' | column -t
