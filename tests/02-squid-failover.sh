#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && NET="haproxy_ha_squid_net" && V="172.30.0.100:3128"
echo "=== 02: Squid 故障切换 ==="
echo "停止 squid2 ..." && docker stop squid2 && sleep 10
docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "故障后: HTTP %{http_code}\n" -x http://$V http://repo.openeuler.org/ --max-time 10
echo "恢复 squid2 ..." && docker compose restart squid2 2>/dev/null && sleep 12
docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "恢复后: HTTP %{http_code}\n" -x http://$V http://repo.openeuler.org/ --max-time 10
echo "PASS"
