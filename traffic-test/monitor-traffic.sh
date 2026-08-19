#!/usr/bin/env bash
# monitor-traffic.sh — sample squid traffic from the central Prometheus
# while a traffic test job runs.
#
# Usage:
#   ./monitor-traffic.sh [duration_s] [out.tsv]
#     default: 600s, stdout
#
# Metrics (central Prometheus 113.44.182.82:9090, headless per-replica scrape):
#   squid_server_http_kbytes_in_kbytes_total   = origin-server bytes (MISS only, upstream fetch)
#   squid_client_http_kbytes_out_kbytes_total  = bytes sent to clients (all responses)
#
# Rows: ts  t  <pod>-out(KB/s)  <pod>-in(KB/s) ...  out_total  in_total
set -euo pipefail

PROM="${PROM:-http://113.44.182.82:9090}"
DUR="${1:-600}"
OUT="${2:-}"
STEP=10

q() { # promql → values
  local expr="$1"
  curl -s --max-time 8 -G "$PROM/api/v1/query" --data-urlencode "query=$expr" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('data',{}).get('result',[]):
    inst=r['metric'].get('instance','?')
    print(inst, r['value'][1])
"
}

CLIENT_EXPR='sum(rate(squid_client_http_kbytes_out_kbytes_total{job="squid"}[5m]))'
ORIGIN_EXPR='sum(rate(squid_server_http_kbytes_in_kbytes_total{job="squid"}[5m]))'
HITRATE_EXPR='1 - sum(rate(squid_server_http_kbytes_in_kbytes_total{job="squid"}[5m])) / sum(rate(squid_client_http_kbytes_out_kbytes_total{job="squid"}[5m]))'
PER_EXPR='sum by (instance) (rate(squid_client_http_kbytes_out_kbytes_total{job="squid"}[5m]))'

echo "# squid traffic monitor: ${DUR}s, step ${STEP}s, prom=${PROM}"
echo "# ts client_kb/s origin_kb/s hitrate(1-origin/client) per-instance(client)"
t0=$(date +%s)
end=$((t0 + DUR))
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date +%s)
  c=$(q "$CLIENT_EXPR" | awk '{print $2}')
  o=$(q "$ORIGIN_EXPR" | awk '{print $2}')
  h=$(q "$HITRATE_EXPR" | awk '{print $2}')
  per=$(q "$PER_EXPR" | tr '\n' ' ')
  [ -z "$c" ] && c=0
  [ -z "$o" ] && o=0
  [ -z "$h" ] && h=0
  line="$now	${c}	${o}	${h}	$per"
  echo "$line"
  if [ -n "$OUT" ]; then echo "$line" >> "$OUT"; fi
  sleep $STEP
done

echo "# done"
