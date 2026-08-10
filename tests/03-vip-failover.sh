#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && source "$ROOT/configs/test.env" 2>/dev/null || true
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
HTTP_URL="${HTTP_URL:-http://repo.openeuler.org/}"
check() { docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "%{http_code}" -x http://$VIP "$HTTP_URL" --max-time 10; }
recover() {
  local node=$1; docker compose restart "$node" 2>/dev/null; sleep 15
  for i in 1 2 3 4 5; do docker exec "$node" ps aux 2>/dev/null | grep -q '[k]eepalived' && break; sleep 3; done
  docker exec "$node" ps aux 2>/dev/null | grep -q '[k]eepalived' || { echo "FAIL: $node keepalived 未恢复"; exit 1; }
}
echo "=== 03: VIP 漂移 ==="
H=$(docker exec haproxy-node1 ip addr show eth0 | grep -q 172.30.0.100 && echo "haproxy-node1" || echo "haproxy-node2")
S=$( [ "$H" = "haproxy-node1" ] && echo "haproxy-node2" || echo "haproxy-node1" )
echo "A: 停 $H ..." && docker stop "$H" && sleep 12
docker exec "$S" ip addr show eth0 | grep -q 172.30.0.100 || { echo "FAIL"; exit 1; }
[ "$(check)" = "200" ] || { echo "FAIL: proxy down"; exit 1; }
echo "A: VIP→$S OK"; recover "$H"
H=$(docker exec haproxy-node1 ip addr show eth0 | grep -q 172.30.0.100 && echo "haproxy-node1" || echo "haproxy-node2")
S=$( [ "$H" = "haproxy-node1" ] && echo "haproxy-node2" || echo "haproxy-node1" )
echo "B: 停 $H ..." && docker stop "$H" && sleep 12
docker exec "$S" ip addr show eth0 | grep -q 172.30.0.100 || { echo "FAIL"; exit 1; }
[ "$(check)" = "200" ] || { echo "FAIL: proxy down"; exit 1; }
echo "B: VIP→$S OK"; recover "$H"
echo "PASS"
