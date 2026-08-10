#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && source "$ROOT/configs/test.env" 2>/dev/null || true
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
CA="$ROOT/configs/certs/client-ca.crt"
HTTP_URL="${HTTP_URL:-http://repo.openeuler.org/}"
HTTPS_URL="${HTTPS_URL:-https://curl.se/}"
echo "=== 01: 代理连通性 ==="
echo "HTTP:" && docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "  %{http_code} %{time_total}s\n" -x http://$VIP "$HTTP_URL" --max-time 10
echo "HTTPS:" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt -s -o /dev/null -w "  %{http_code} %{time_total}s\n" -x http://$VIP "$HTTPS_URL" --max-time 10
echo "PASS"
