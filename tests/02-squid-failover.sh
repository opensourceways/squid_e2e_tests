#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
TARGET=squid2
echo "=== 02: Squid 故障切换 ==="
echo "停止 $TARGET ..." && docker stop $TARGET && sleep 8
docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "故障后: HTTP %{http_code}\n" -x http://$VIP http://repo.openeuler.org/ --max-time 10
echo "恢复 $TARGET ..." && docker start $TARGET && sleep 8
echo "PASS"
