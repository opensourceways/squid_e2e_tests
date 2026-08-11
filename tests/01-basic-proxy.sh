#!/bin/bash
# 01: HTTP + HTTPS 代理连通性
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 01: 代理连通性 ==="

assert_code "HTTP 代理"  200 "$(proxy_http_code "$HTTP_URL")"
assert_code "HTTPS 代理" 200 "$(proxy_https_code "$HTTPS_URL")"

echo "PASS"
