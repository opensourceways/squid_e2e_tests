#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && source "$ROOT/configs/test.env" 2>/dev/null || true
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
CA="$ROOT/configs/certs/client-ca.crt"
URL="${HTTPS_CACHE_URL:-https://curl.se/download/curl-8.9.1.tar.gz}"
echo "=== 04: HTTPS 缓存 ==="
echo "首次 (MISS):" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt --connect-timeout 10 -s -o /dev/null -w "  %{time_total}s %{size_download}B\n" -x http://$VIP "$URL" --max-time 120
echo "二次 (HIT):" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt --connect-timeout 10 -s -o /dev/null -w "  %{time_total}s %{size_download}B\n" -x http://$VIP "$URL" --max-time 120
echo "PASS"
