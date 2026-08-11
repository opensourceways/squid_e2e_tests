#!/bin/bash
# 测试公共库: 断言 + 代理请求封装
# 用法: source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
source "$ROOT/configs/test.env" 2>/dev/null || true

NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
CA="$ROOT/configs/certs/client-ca.crt"
HTTP_URL="${HTTP_URL:-http://repo.openeuler.org/}"
HTTPS_URL="${HTTPS_URL:-https://curl.se/}"
HTTPS_CACHE_URL="${HTTPS_CACHE_URL:-https://curl.se/download/curl-8.9.1.tar.gz}"

# 通过 VIP 发 HTTP 请求,返回 http_code
# 注意: curl 即使传输中途失败(--max-time 截断、连接被切断),-w "%{http_code}" 仍会
# 打印已收到的 200。所以必须检查 curl 自身的退出码,否则一个被截断的响应会被当成成功。
# 失败时返回 "000(curl exit N)",assert_code 会因为不等于 200 而正常 FAIL 并显示原因。
proxy_http_code() {
    local out rc
    out=$(docker run --rm --network "$NET" alpine/curl:latest \
        curl -s -o /dev/null --connect-timeout 10 -w "%{http_code}" \
        -x "http://$VIP" "$1" --max-time "${2:-15}" 2>/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] && { echo "000(curl exit $rc)"; return 0; }
    echo "$out"
}

# 通过 VIP 发 HTTPS 请求(带 CA 信任),返回 http_code
proxy_https_code() {
    local out rc
    out=$(docker run --rm --network "$NET" -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest \
        curl --cacert /tmp/ca.crt -s -o /dev/null --connect-timeout 10 -w "%{http_code}" \
        -x "http://$VIP" "$1" --max-time "${2:-30}" 2>/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] && { echo "000(curl exit $rc)"; return 0; }
    echo "$out"
}

# 断言: HTTP code 必须等于期望值,否则退出 1
assert_code() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label: HTTP $actual"
    else
        echo "  ✗ FAIL $label: 期望 HTTP $expected, 实际 HTTP $actual"
        exit 1
    fi
}

# 断言: 命令返回真,否则退出 1
assert_true() {
    local label="$1"; shift
    if "$@"; then
        echo "  ✓ $label"
    else
        echo "  ✗ FAIL $label"
        exit 1
    fi
}
