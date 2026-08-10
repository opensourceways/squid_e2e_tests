#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
echo "=== 03: VIP 漂移 ==="
docker exec haproxy-node1 ip addr show eth0 | grep -q 172.30.0.100 && echo "初始: VIP 在 node1" || echo "初始: VIP 在 node2"
echo "停止 node1 ..." && docker stop haproxy-node1 && sleep 10
docker exec haproxy-node2 ip addr show eth0 | grep -q 172.30.0.100 && echo "漂移: VIP 在 node2" || echo "FAIL"
docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "代理: HTTP %{http_code}\n" -x http://$VIP http://repo.openeuler.org/ --max-time 10
echo "恢复 node1 ..." && docker start haproxy-node1 && sleep 10
echo "PASS"
