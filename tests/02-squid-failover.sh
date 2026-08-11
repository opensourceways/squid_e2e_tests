#!/bin/bash
# 02: 单台 Squid 故障,代理不中断
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 02: Squid 故障切换 ==="

echo "停止 squid2 ..."
docker stop squid2 && sleep 10
assert_code "故障后代理" 200 "$(proxy_http_code "$HTTP_URL")"

echo "恢复 squid2 ..."
docker compose restart squid2 2>/dev/null && sleep 12
assert_code "恢复后代理" 200 "$(proxy_http_code "$HTTP_URL")"

echo "PASS"
