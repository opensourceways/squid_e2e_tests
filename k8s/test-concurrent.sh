#!/bin/bash
# 并发下载测试 —— 起 N 个 client Pod 同时经 Squid 下载, 验证并发代理+缓存
# 用法: ./test-concurrent.sh [并发数N] [总次数]
#   默认 N=20 completions=40 (测试集群友好; 生产画像更大 N 见 sizing 报告)
set -e
K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
NS=test-husheng
export PARALLELISM="${1:-20}"
export COMPLETIONS="${2:-40}"
export RUN_ID="$(date +%s)"
export RPM_URL="${HTTPS_CACHE_URL:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"

echo "============================================"
echo "  K8s 并发下载测试  N=$PARALLELISM  次数=$COMPLETIONS"
echo "============================================"

# 记录 Squid 日志基线
BASE_HIT=$(kubectl -n "$NS" logs -l app=squid-cache --tail=-1 2>/dev/null | grep -c "TCP_HIT.*bcc-debuginfo" || echo 0)
BASE_MISS=$(kubectl -n "$NS" logs -l app=squid-cache --tail=-1 2>/dev/null | grep -c "TCP_MISS.*bcc-debuginfo" || echo 0)

echo "启动并发 Job (parallelism=$PARALLELISM)..."
# 限定 envsubst 只替换这 4 个变量, 避免误吞容器脚本里的 ${SIZE}/$(date) 等
envsubst '${PARALLELISM} ${COMPLETIONS} ${RUN_ID} ${RPM_URL}' \
    < "$K8S_DIR/manifests/04-client-job.yaml" | kubectl apply -f -

JOB="squid-client-$RUN_ID"
echo "等待完成..."
kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=600s 2>/dev/null || {
    echo "Job 未在超时内完成, 当前状态:"
    kubectl -n "$NS" get job "$JOB"
}

echo ""
echo "=== 并发结果统计 ==="
SUCCEEDED=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
FAILED=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)
echo "成功: ${SUCCEEDED:-0} / $COMPLETIONS   失败: ${FAILED:-0}"

echo ""
echo "=== 各 client 下载耗时(前20条) ==="
kubectl -n "$NS" logs -l job-name="$JOB" --tail=-1 2>/dev/null | grep "^OK" | head -20

echo ""
echo "=== Squid 缓存命中分布(逐副本累加) ==="
HIT=0; MISS=0
for p in $(kubectl -n "$NS" get pods -l app=squid-cache -o name 2>/dev/null); do
    h=$(kubectl -n "$NS" logs "$p" --tail=-1 2>/dev/null | grep -c "TCP_HIT.*bcc-debuginfo"); h=${h:-0}
    m=$(kubectl -n "$NS" logs "$p" --tail=-1 2>/dev/null | grep -c "TCP_MISS.*bcc-debuginfo"); m=${m:-0}
    HIT=$((HIT + h)); MISS=$((MISS + m))
done
TOTAL=$((HIT + MISS))
echo "  HIT=$HIT  MISS=$MISS  命中率=$([ $TOTAL -gt 0 ] && awk "BEGIN{printf \"%.0f%%\", $HIT/$TOTAL*100}" || echo N/A)"
echo "  (冷启动+高并发命中率偏低是正常的: 首波并发同时 MISS 回源; 热缓存后趋近 95%+)"

echo ""
echo "=== 判定 ==="
if [ "${SUCCEEDED:-0}" = "$COMPLETIONS" ]; then
    echo "  ✓ 全部 $COMPLETIONS 次并发下载成功"
    [ "$HIT" -gt 0 ] && echo "  ✓ 并发下缓存命中生效" || echo "  ⚠ 未观察到 HIT"
else
    echo "  ✗ 有失败: 成功 ${SUCCEEDED:-0}/$COMPLETIONS"
    exit 1
fi
