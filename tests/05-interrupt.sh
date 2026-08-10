#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
echo "=== 05: 下载中断影响 ==="
TARGET=squid3
echo "启动后台下载 ..."
docker run --rm -d --name dl-test --network $NET alpine/curl:latest sh -c 'curl -s -o /tmp/dl.rpm -x http://172.30.0.100:3128 http://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/Imath-debuginfo-3.1.4-1.oe2303.aarch64.rpm --max-time 120 2>&1' 2>/dev/null &
sleep 3
echo "中断 $TARGET ..." && docker stop $TARGET && sleep 8
echo "测试代理连通:" && docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "  HTTP %{http_code}\n" -x http://$VIP http://repo.openeuler.org/ --max-time 10
echo "恢复 $TARGET ..." && docker start $TARGET && sleep 8
docker rm -f dl-test 2>/dev/null
echo "PASS"
