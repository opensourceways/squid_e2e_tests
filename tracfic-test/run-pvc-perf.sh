#!/usr/bin/env bash
# run-pvc-perf.sh — find the saturation point of the squid cache PVC.
#
# Loads the squid cache with the fixed pip package set (torch 2.10.0 146MB
# wheel + deps, ~350MB total per pod), then runs the SAME set at increasing
# concurrency. All pods hit the warm cache (TCP_HIT), so the aggregate
# bandwidth = bytes read from the squid cache PVC — this is the real
# bottleneck test for SFS Turbo (sfsturbo-subpath-sc).
#
# The "bottom" (saturation) is the first concurrency level where aggregate
# bandwidth stops growing (<5% gain over the previous level).
#
# Usage:
#   ./run-pvc-perf.sh                      # warm + ramp 1 2 4 8 16 24 32
#   ./run-pvc-perf.sh --conc="2 4 8 16 32"
#   ./run-pvc-perf.sh --no-warm            # skip explicit warm-up level
#
# Output: stdout table + logs/pvc-perf/<ts>.tsv
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
NS="squid"
DIR="$(cd "$(dirname "$0")" && pwd)"
GEN="$DIR/../../squid_e2e_tests/tracfic-test/gen-replicas.py"
[ -f "$GEN" ] || GEN="$DIR/gen-replicas.py"
YAML="$DIR/pvc-perf.yaml"
LOG_DIR="$DIR/logs/pvc-perf"
PROM="${PROM:-http://113.44.182.82:9090}"
CONC="1 2 4 8 16 24 32"
WARM=1

kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
q() { curl -s --max-time 8 -G "$PROM/api/v1/query" --data-urlencode "query=$1"; }

for a in "$@"; do
  case "$a" in
    --conc=*) CONC="${a#*=}" ;;
    --no-warm) WARM=0 ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$LOG_DIR/$TS.tsv"
[ -f "$GEN" ] || { echo "gen-replicas.py not found at $GEN" >&2; exit 1; }

echo "# pvc-perf $(date -u +%FT%TZ) conc=[$CONC] warm=$WARM prom=$PROM" | tee "$OUT"
echo -e "conc\tpods_done\tper_pod_MB\ttotal_MB\twall_s\tagg_BW_MB_s\torigin_kb_s\thitrate" | tee -a "$OUT"

submit_ramp() {
  local n="$1" run_id="pvc-perf-$n"
  kc delete vj -l pipeline/run-id=$run_id -n $NS --ignore-not-found >/dev/null 2>&1
  python3 "$GEN" "$YAML" /tmp/pvc-perf-$n.yaml "$n" >/dev/null
  sed -i "s|pipeline/run-id: pvc-perf.*|pipeline/run-id: $run_id|" /tmp/pvc-perf-$n.yaml
  kc create -f /tmp/pvc-perf-$n.yaml >/dev/null 2>&1
  sleep 4
  kc get vj -l pipeline/run-id=$run_id -n $NS -o jsonpath='{.items[0].metadata.name}'
}

wait_ramp() { # job → rc
  local job="$1" pod done=0 seen=0 end=$(( $(date +%s) + 1800 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    done=1; seen=0
    for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
      seen=1
      case "$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)" in
        Succeeded) ;;
        Failed) echo "  pod FAILED: $pod" >&2; return 1 ;;
        *) done=0 ;;
      esac
    done
    [ "$done" = "1" ] && [ "$seen" = "1" ] && return 0
    sleep 5
  done
  echo "  TIMEOUT" >&2
  return 1
}

run_level() {
  local n="$1" tag="$2" attempt=0 run_id="pvc-perf-$n"
  while :; do
    attempt=$((attempt+1))
    echo "" | tee -a "$OUT"
    echo "== concurrency=$n ($tag, attempt $attempt) $(date -u +%T)Z ==" | tee -a "$OUT"
    local job
    job=$(submit_ramp "$n") || { echo "  submit failed" | tee -a "$OUT"; break; }
    if wait_ramp "$job"; then
      break
    fi
    echo "  attempt $attempt failed" | tee -a "$OUT"
    kc delete vj -l pipeline/run-id=$run_id -n $NS --ignore-not-found >/dev/null 2>&1 || true
    [ "$attempt" -ge 2 ] && { echo "  giving up on level $n" >&2; return 1; }
    sleep 30
  done
  sleep 5
  local nbytes=0 bytes ms bw_sum=0 pod byte_wall=0 pod_bytes=0 bps=0
  local i=0 cnt=0
  for pod in $(kc get pods -n "$NS" -l "volcano.sh/job-name=$job" -o name 2>/dev/null | cut -d/ -f2); do
    i=$((i+1))
    pod_bytes=$(kc logs -n "$NS" "$pod" 2>/dev/null | sed -n 's/^PERF_BYTES=//p' | head -1)
    ms=$(kc logs -n "$NS" "$pod" 2>/dev/null | sed -n 's/^PERF_MS=//p' | head -1)
    bps=$(kc logs -n "$NS" "$pod" 2>/dev/null | sed -n 's/^PERF_BW_BPS=//p' | head -1)
    [ -n "$pod_bytes" ] && [ -n "$ms" ] && cnt=$((cnt+1))
    nbytes=$(( nbytes + ${pod_bytes:-0} ))
    [ -n "$ms" ] && [ "$ms" -gt "$byte_wall" ] && byte_wall=$ms
  done
  if [ "$cnt" -eq 0 ] || [ "$byte_wall" -eq 0 ]; then
    echo "  no PERF data collected (cnt=$cnt)" | tee -a "$OUT"
    return 1
  fi
  local wall_s=$(( (byte_wall + 500) / 1000 ))
  local agg_mb=$(( nbytes / 1048576 ))
  local agg_mbps=$(( agg_mb * 1000 / byte_wall ))
  local origin=0 hit=0
  origin=$(q "sum(increase(squid_server_http_kbytes_in_kbytes_total{job=\"squid\"}[120s]))" 2>/dev/null | grep -oE '"value":\[[0-9.]+,"[0-9.eE+-]+"\]' | grep -oE '"[0-9.eE+-]+"$' | tr -d '"' || echo 0)
  local hitrate
  hitrate=$(awk -v o="$origin" -v c="$agg_mb" 'BEGIN{ if (c>0 && o>0) printf "%.4f", 1-o/c; else if (o>0) printf "0"; else printf "1" }')
  echo -e "$n\t$cnt\t$(( agg_mb / (n>0?n:1) ))\t$agg_mb\t$wall_s\t$agg_mbps\t$origin\t$hitrate" | tee -a "$OUT"
}

PREV_BW=0
declare -A BWAT
LEVELS=0
for n in $CONC; do
  if [ "$WARM" = "1" ] && [ "$n" = "1" ]; then
    echo "== warm-up: cold fill (concurrency=1, discarded) =="
    run_level 1 warm || echo "  warm failed, continuing"
    WARM=0
    continue
  fi
  run_level "$n" ramp || { echo "  level $n failed, aborting" >&2; break; }
  BWAT[$n]=$(awk -v l="$n" '$1==l{print $6}' "$OUT" | head -1)
  LEVELS=$((LEVELS+1))
  if [ "$LEVELS" -ge 2 ]; then
    cur=${BWAT[$n]:-0}
    prev=$PREV_BW
    if [ "$prev" -gt 0 ] && [ "$cur" -gt 0 ]; then
      gain=$(awk "BEGIN{printf \"%.1f\", ($cur-$prev)*100/$prev}")
      echo "  BW $prev -> $cur MB/s (gain ${gain}%)" | tee -a "$OUT"
      if awk "BEGIN{exit !($gain < 5)}"; then
        echo "" | tee -a "$OUT"
        echo ">> BOTTOM (saturation) reached at concurrency=$n: BW=$cur MB/s" | tee -a "$OUT"
        break
      fi
    fi
  fi
  PREV_BW=${BWAT[$n]:-0}
done

echo "" | tee -a "$OUT"
echo "== summary: logs/pvc-perf/$TS.tsv ==" | tee -a "$OUT"
awk -F'\t' '$1 ~ /^[0-9]+$/{print "  conc=" $1 "  agg_BW=" $6 " MB/s  hitrate=" $8}' "$OUT" | tee -a "$OUT"
