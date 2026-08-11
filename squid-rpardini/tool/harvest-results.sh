#!/usr/bin/env bash
# harvest-results.sh — fetch logs for all test-squid-* volcano jobs (mapped by
# pipeline/run-id label), write .res/<num>-<variant> files, then run
# run-tool-tests.sh --compare-only to print the comparison table.
set -uo pipefail
cd "$(dirname "$0")"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
NS="squid"; LOG_DIR="$PWD/logs"; RES_DIR="$LOG_DIR/.res"; mkdir -p "$RES_DIR"

# slug (from generateName) -> case file base
declare -A SLUG
for f in [0-9][0-9]-*.yaml; do
  g=$(grep -m1 generateName "$f" | sed -E 's/.*generateName: test-squid-([a-z0-9-]+)-.*/\1/')
  SLUG[$g]=$(basename "$f" .yaml)
done

# newest job per run-id slug (parallel run may duplicate serial leftovers)
declare -A NEWEST
for job in $(kc get jobs.batch.volcano.sh -n "$NS" --no-headers | awk '$1 ~ /^test-squid-/ {print $1}' | grep -vE "wget-ktzg8|wget-v7wvz"); do
  runid=$(kc get job "$job" -n "$NS" -o jsonpath='{.metadata.labels.pipeline/run-id}' 2>/dev/null || true)
  [ -n "$runid" ] || continue
  age=$(kc get job "$job" -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
  if [ -z "${NEWEST[$runid]:-}" ] || [ "$age" > "${NEWEST[$runid]%%|*}" ]; then
    NEWEST[$runid]="$age|$job"
  fi
done

COUNT=0
for runid in "${!NEWEST[@]}"; do
  job="${NEWEST[$runid]##*|}"
  slug="${runid#test-squid-}"
  variant="squid"
  if [[ "$slug" == *-direct ]]; then variant="direct"; slug="${slug%-direct}"; fi
  base="${SLUG[$slug]:-$slug}"
  num="${base:0:2}"
  pod=$(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  phase=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" != "Succeeded" ]; then
    echo "SKIP $runid ($job): pod phase=$phase"
    continue
  fi
  logfile="$LOG_DIR/$base-$variant.log"
  kc logs -n "$NS" "$pod" > "$logfile" 2>&1
  echo "$logfile|Succeeded" > "$RES_DIR/$num-$variant"
  echo "OK  $runid -> $base-$variant.log ($(grep -c 'DURATION:' "$logfile" || true) DURATION)"
  COUNT=$((COUNT+1))
done
echo "harvested $COUNT variants"
