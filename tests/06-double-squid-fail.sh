#!/bin/bash
# 06: 两台 Squid 同时故障(仅剩 1/3),代理继续服务
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 06: 两台 Squid 同时故障 ==="

echo "停止 squid2 + squid3 (仅剩 squid1) ..."
docker stop squid2 squid3 && sleep 10

for i in 1 2 3; do
    assert_code "仅剩1台 请求$i" 200 "$(proxy_http_code "$HTTP_URL")"
done

echo "恢复 squid2 + squid3 ..."
docker compose restart squid2 squid3 2>/dev/null && sleep 12
assert_code "恢复后代理" 200 "$(proxy_http_code "$HTTP_URL")"

echo "PASS"
