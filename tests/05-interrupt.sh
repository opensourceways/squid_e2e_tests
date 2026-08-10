#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && source "$ROOT/configs/test.env" 2>/dev/null || true
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
HTTP_URL="${HTTP_URL:-http://repo.openeuler.org/}"
echo "=== 05: 下载中断 ==="
TARGET=squid3
echo "启动后台下载 ..." && docker run --rm -d --name dl-test --network $NET alpine/curl:latest sh -c 'curl -s -o /dev/null -x http://172.30.0.100:3128 '"$HTTP_URL"' --max-time 60' 2>/dev/null
sleep 3
echo "中断 $TARGET ..." && docker stop $TARGET && sleep 8
docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "  代理: HTTP %{http_code}\n" -x http://$VIP "$HTTP_URL" --max-time 10
echo "恢复 $TARGET ..." && docker compose restart $TARGET 2>/dev/null && sleep 10
docker rm -f dl-test 2>/dev/null
echo "PASS"
