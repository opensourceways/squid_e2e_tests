#!/bin/bash
# 测试: 两台 Squid 同时故障 (仅剩 1/3),代理继续
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
echo "=== 06: 两台 Squid 同时故障 ==="
echo "停止 squid2 + squid3 (仅剩 squid1) ..."
docker stop squid2 squid3 2>/dev/null
sleep 10
for i in 1 2 3; do
  docker run --rm --network $NET alpine/curl:latest \
    curl -s -o /dev/null -w "  req$i: HTTP %{http_code}\n" \
    -x http://$VIP http://repo.openeuler.org/ --max-time 10
done
echo "恢复 ..."
docker start squid2 squid3 2>/dev/null
sleep 10
echo "PASS"
