#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" && ROOT="$(dirname "$SCRIPT_DIR")"
REPORT="$ROOT/test-report.txt" && cd "$ROOT"
> "$REPORT"
echo "============================================" | tee -a "$REPORT"
echo "  Squid HA 验证测试 | $(date)" | tee -a "$REPORT"
echo "============================================" | tee -a "$REPORT"
PASS=0; FAIL=0
for t in tests/[0-9]*.sh; do
    tname=$(basename "$t")
    # 确保代理可达(关键:上一次测试可能停了节点)
    docker run --rm --network haproxy_ha_squid_net alpine/curl:latest \
      curl -s -o /dev/null --max-time 5 -x http://172.30.0.100:3128 http://repo.openeuler.org/ 2>/dev/null || {
        echo "  代理不可达,尝试恢复环境..."
        docker start haproxy-node1 haproxy-node2 squid1 squid2 squid3 2>/dev/null
        sleep 15
    }
    echo "--- $tname ---"
    if bash "$t" >> "$REPORT" 2>&1; then
        echo "  [$tname] PASS" | tee -a "$REPORT"; PASS=$((PASS+1))
    else
        echo "  [$tname] FAIL (exit=$?)" | tee -a "$REPORT"; FAIL=$((FAIL+1))
    fi
done
echo "" | tee -a "$REPORT"
echo "============================================" | tee -a "$REPORT"
echo "  结果: $PASS 通过 / $FAIL 失败 / $((PASS+FAIL)) 总计" | tee -a "$REPORT"
echo "  报告: $REPORT"
echo "============================================"
