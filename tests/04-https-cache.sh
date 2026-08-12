#!/bin/bash
# 04: HTTPS SSL Bump 缓存 —— 分层指标(命中延迟分位 + CPU 两项成本 + 错误分类)
#
# 取代旧的"两次 wall-clock 采样": 两次采样看不见长尾、不分类错误、不测 CPU 成本。
# 依据 scripts/metrics.sh(PR #12)的口径, 用 begin/end 框定 MISS 窗口与 HIT 窗口。
set -e
source "$(dirname "$0")/lib.sh"
METRICS="$(dirname "$0")/../scripts/metrics.sh"
echo "=== 04: HTTPS SSL Bump 缓存(分层指标) ==="
echo "URL: $HTTPS_CACHE_URL"

# 固定客户端 IP: balance source 按源 IP 哈希 → 固定落到同一台 Squid。各 Squid 缓存独立、
# 无 peer, 所以 prime 与 HIT 负载必须同一 IP 才命中同一份缓存(否则 HIT 窗口会变 MISS)。
CLIENT_IP=172.30.0.50

# cache-busting: 附一个唯一 query 串, 让 Squid 视作从未见过的新对象。
# (strip_query_terms 只影响日志显示, 不影响缓存 key → 保证窗口1是真 MISS)
# 两个窗口用同一个 busted URL: 窗口1 冷取=MISS, 窗口2 复取=HIT。
BUSTED_URL="${HTTPS_CACHE_URL}?cb=$(date +%s)-$$-${RANDOM}"

# 用固定 IP 的一个容器连打 N 次(容器启动开销只付一次), 返回首个 http_code。
hammer() {
    docker run --rm --network "$NET" --ip "$CLIENT_IP" -v "$CA:/tmp/ca.crt:ro" \
        -e N="$1" -e VIP="$VIP" -e URL="$BUSTED_URL" \
        --entrypoint sh alpine/curl:latest -c '
        code=""; i=0
        while [ "$i" -lt "$N" ]; do
            c=$(curl --cacert /tmp/ca.crt -s -o /dev/null -w "%{http_code}" \
                -x "http://$VIP" "$URL" --max-time 300)
            [ -z "$code" ] && code=$c
            i=$((i+1))
        done
        echo "$code"' 2>/dev/null
}

# 0) 空闲 CPU 基线(此刻环境应无负载)—— end 会按窗口时长扣除, 避免把空闲 CPU 算进请求成本
echo ""
echo "--- 测空闲 CPU 基线(15s, 请勿在此期间加负载) ---"
"$METRICS" baseline 15 >/dev/null

# 1) MISS 窗口: 冷取一次(把对象灌进 CLIENT_IP 对应那台 Squid 的缓存)
echo ""
echo "--- MISS 窗口: 冷取 1 次 ---"
"$METRICS" begin >/dev/null
CM=$(hammer 1)
assert_code "冷取(MISS)" 200 "$CM"
"$METRICS" end

# 2) HIT 窗口: 同一 IP 命中同一份缓存, 连打 30 次看 HIT 延迟分布(p50/p95/p99)
echo ""
echo "--- HIT 窗口: 命中 30 次(同一缓存) ---"
"$METRICS" begin >/dev/null
CH=$(hammer 30)
assert_code "命中(HIT)" 200 "$CH"
"$METRICS" end

echo ""
echo "PASS"
