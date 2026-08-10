#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPORT="$ROOT/test-report.txt"
cd "$ROOT"

echo "============================================" | tee "$REPORT"
echo "  Squid HA 方案验证测试报告" | tee -a "$REPORT"
echo "  $(date)" | tee -a "$REPORT"
echo "============================================" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

PASS=0; FAIL=0
for t in tests/[0-9]*.sh; do
    tname=$(basename "$t")
    echo "--- $tname ---"
    if bash "$t" >> "$REPORT" 2>&1; then
        echo "  [$tname] PASS" | tee -a "$REPORT"
        PASS=$((PASS+1))
    else
        echo "  [$tname] FAIL (exit=$?)" | tee -a "$REPORT"
        FAIL=$((FAIL+1))
    fi
done

echo "" | tee -a "$REPORT"
echo "============================================" | tee -a "$REPORT"
echo "  结果: $PASS 通过 / $FAIL 失败 / $((PASS+FAIL)) 总计" | tee -a "$REPORT"
echo "  报告: $REPORT" | tee -a "$REPORT"
echo "============================================"
