#!/bin/bash
# 05: 下载进行中 Squid 中断,代理服务不受影响
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 05: 下载中断影响 ==="
TARGET=squid3

echo "启动后台下载 ..."
docker run --rm -d --name dl-test --network "$NET" alpine/curl:latest \
    sh -c "curl -s -o /dev/null -x http://$VIP '$HTTP_URL' --max-time 60" 2>/dev/null
sleep 3

echo "中断 $TARGET ..."
docker stop "$TARGET" && sleep 8
assert_code "中断期间代理" 200 "$(proxy_http_code "$HTTP_URL")"

echo "恢复 $TARGET ..."
docker compose restart "$TARGET" 2>/dev/null && sleep 10
docker rm -f dl-test 2>/dev/null || true
assert_code "恢复后代理" 200 "$(proxy_http_code "$HTTP_URL")"

echo "PASS"
