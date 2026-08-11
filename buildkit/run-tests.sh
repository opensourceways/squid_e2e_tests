#!/bin/bash
# BuildKit 扩展场景独立测试入口(默认不随主测试套件运行)
# 前置: 主 Squid HA 环境已启动(../scripts/setup.sh)
# 用法: ./run-tests.sh
set -e
BK_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$BK_ROOT")"
COMPOSE="$BK_ROOT/docker-compose.buildkit.yml"

echo "============================================"
echo "  BuildKit 经 Squid 代理+缓存 扩展测试"
echo "============================================"

# 前置检查: Squid VIP 可达
if ! docker run --rm --network haproxy_ha_squid_net alpine/curl:latest \
    curl -s -o /dev/null --max-time 5 -x http://172.30.0.100:3128 \
    http://repo.openeuler.org/ 2>/dev/null; then
    echo "✗ Squid HA 环境未就绪。请先运行 ../scripts/setup.sh"
    exit 1
fi
echo "✓ Squid HA 环境就绪"

# 启动 buildkitd
echo "启动 buildkitd(rootful, 精简 cap)..."
docker compose -f "$COMPOSE" up -d --force-recreate >/dev/null 2>&1
sleep 8
if ! docker ps --filter name=buildkitd --format '{{.Names}}' | grep -q buildkitd; then
    echo "✗ buildkitd 启动失败"; docker logs buildkitd 2>&1 | tail -10; exit 1
fi
echo "✓ buildkitd 就绪"
echo ""

# 运行测试
PASS=0; FAIL=0
for t in "$BK_ROOT"/tests/[0-9]*.sh; do
    tname=$(basename "$t")
    echo "--- $tname ---"
    if bash "$t"; then
        echo "  [$tname] PASS"; PASS=$((PASS+1))
    else
        echo "  [$tname] FAIL"; FAIL=$((FAIL+1))
    fi
    echo ""
done

# 清理 buildkitd
echo "清理 buildkitd..."
docker compose -f "$COMPOSE" down >/dev/null 2>&1

echo "============================================"
echo "  结果: $PASS 通过 / $FAIL 失败 / $((PASS+FAIL)) 总计"
echo "============================================"
[ "$FAIL" -eq 0 ]
