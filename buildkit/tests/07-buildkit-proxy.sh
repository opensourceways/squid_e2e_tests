#!/bin/bash
# 07: BuildKit RUN 内的 HTTPS 请求经 Squid 代理,构建成功
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 07: BuildKit RUN HTTPS 经 Squid 代理 ==="

OUT=$(bk_build)
echo "$OUT" | grep -E "proxy network requests:|DONE|ERROR" | tail -8

# 断言: 构建成功(下载到 RPM) 且 proxy 捕获了 HTTPS 请求
assert_true "构建成功(RUN 下载 RPM)" bash -c "echo '$OUT' | grep -q 'pkg.rpm'"
assert_true "proxy 捕获 HTTPS 请求" bash -c "echo '$OUT' | grep -q 'proxy network requests:'"
assert_true "openEuler HTTPS 请求返回 200" bash -c "echo '$OUT' | grep -q 'openeuler.*-> 200'"

echo "PASS"
