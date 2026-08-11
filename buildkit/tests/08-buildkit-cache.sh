#!/bin/bash
# 08: 二次构建时 Squid 命中缓存(证明 SSL Bump 缓存对 BuildKit 生效)
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 08: BuildKit 经 Squid 的 HTTPS 缓存命中 ==="

# 第一次构建: 让 Squid 缓存该 RPM(可能 MISS)
echo "首次构建(填充 Squid 缓存)..."
bk_build >/dev/null 2>&1

HIT_BEFORE=$(squid_log_count "TCP_HIT.*bcc-debuginfo")

# 第二次构建: --no-cache 强制 BuildKit 重新下载 → 应命中 Squid 缓存
echo "二次构建(--no-cache,应命中 Squid)..."
bk_build >/dev/null 2>&1

HIT_AFTER=$(squid_log_count "TCP_HIT.*bcc-debuginfo")
echo "  Squid RPM 缓存命中数: $HIT_BEFORE → $HIT_AFTER"

assert_true "二次构建 Squid 命中缓存(TCP_HIT 增加)" test "$HIT_AFTER" -gt "$HIT_BEFORE"

echo "PASS"
