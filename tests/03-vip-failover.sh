#!/bin/bash
# 03: HAProxy 节点故障,VIP 双向漂移,代理不中断
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 03: VIP 漂移 ==="

vip_holder() {
    docker exec haproxy-node1 ip addr show eth0 2>/dev/null | grep -q 172.30.0.100 \
        && echo "haproxy-node1" || echo "haproxy-node2"
}

recover() {
    local node=$1
    docker compose restart "$node" 2>/dev/null
    sleep 15
    for i in 1 2 3 4 5; do
        docker exec "$node" ps aux 2>/dev/null | grep -q '[k]eepalived' && return 0
        sleep 3
    done
    echo "  ✗ FAIL: $node keepalived 未恢复"; exit 1
}

test_failover() {
    local label="$1"
    local H S
    H=$(vip_holder)
    S=$( [ "$H" = "haproxy-node1" ] && echo "haproxy-node2" || echo "haproxy-node1" )
    echo "$label: 停止 VIP 持有者 $H ..."
    docker stop "$H" && sleep 12
    assert_true "$label VIP 漂移到 $S" bash -c "docker exec '$S' ip addr show eth0 | grep -q 172.30.0.100"
    assert_code "$label 代理" 200 "$(proxy_http_code "$HTTP_URL")"
    recover "$H"
}

test_failover "A"   # 停 MASTER
test_failover "B"   # 停当前持有者(验证反向漂移)

echo "PASS"
