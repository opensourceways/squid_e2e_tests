#!/bin/bash
# 运行全部测试,生成人类可读报告 + 机器可读 result.json
# 整体 exit code: 0=全通过, 1=有失败
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPORT="$ROOT/test-report.txt"
JSON="$ROOT/result.json"
cd "$ROOT"

> "$REPORT"
{
    echo "============================================"
    echo "  Squid HA 验证测试 | $(date)"
    echo "============================================"
} | tee -a "$REPORT"

PASS=0; FAIL=0
JSON_ITEMS=()

for t in tests/[0-9]*.sh; do
    tname=$(basename "$t")

    # 每个测试前确保代理可达(上个测试可能残留停止的节点)
    if ! docker run --rm --network haproxy_ha_squid_net alpine/curl:latest \
        curl -s -o /dev/null --max-time 5 -x http://172.30.0.100:3128 \
        http://repo.openeuler.org/ 2>/dev/null; then
        echo "  代理不可达,尝试恢复环境..." | tee -a "$REPORT"
        docker start haproxy-node1 haproxy-node2 squid1 squid2 squid3 2>/dev/null
        sleep 15
    fi

    echo "--- $tname ---"
    start=$(date +%s)
    if bash "$t" >> "$REPORT" 2>&1; then
        dur=$(( $(date +%s) - start ))
        echo "  [$tname] PASS (${dur}s)" | tee -a "$REPORT"
        PASS=$((PASS+1))
        JSON_ITEMS+=("{\"test\":\"$tname\",\"result\":\"PASS\",\"duration_s\":$dur}")
    else
        code=$?
        dur=$(( $(date +%s) - start ))
        echo "  [$tname] FAIL (exit=$code, ${dur}s)" | tee -a "$REPORT"
        FAIL=$((FAIL+1))
        JSON_ITEMS+=("{\"test\":\"$tname\",\"result\":\"FAIL\",\"exit_code\":$code,\"duration_s\":$dur}")
    fi
done

TOTAL=$((PASS+FAIL))
{
    echo ""
    echo "============================================"
    echo "  结果: $PASS 通过 / $FAIL 失败 / $TOTAL 总计"
    echo "============================================"
} | tee -a "$REPORT"

# 生成 result.json
{
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"total\": $TOTAL, \"passed\": $PASS, \"failed\": $FAIL,"
    echo "  \"all_passed\": $( [ "$FAIL" -eq 0 ] && echo true || echo false ),"
    echo "  \"tests\": ["
    local_first=1
    for item in "${JSON_ITEMS[@]}"; do
        [ $local_first -eq 1 ] && local_first=0 || echo ","
        printf "    %s" "$item"
    done
    echo ""
    echo "  ]"
    echo "}"
} > "$JSON"

echo "报告: $REPORT"
echo "JSON: $JSON"

# 整体 exit code 反映成败
[ "$FAIL" -eq 0 ]
