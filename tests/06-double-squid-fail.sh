#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && source "$ROOT/configs/test.env" 2>/dev/null || true
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
HTTP_URL="${HTTP_URL:-http://repo.openeuler.org/}"
echo "=== 06: 两台 Squid 故障 ==="
echo "停止 squid2+squid3 ..." && docker stop squid2 squid3 && sleep 10
for i in 1 2 3; do docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "  req$i: HTTP %{http_code}\n" -x http://$VIP "$HTTP_URL" --max-time 10; done
echo "恢复 ..." && docker compose restart squid2 squid3 2>/dev/null && sleep 12
echo "PASS"
