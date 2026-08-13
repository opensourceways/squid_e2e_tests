#!/bin/bash
# K8s 版"用例 04": 分层指标(HIT/MISS 延迟分位 + CPU 两项成本 + 错误分类)。
# 等价于 tests/04-https-cache.sh, 但跑在 K8s 的 squid StatefulSet + Service 上,
# 采集用 k8s/metrics-k8s.sh(同口径, 数据源换成 kubectl exec + endpoints)。
#
# 用法: NS=test-husheng ./k8s/latency-test.sh [RPM_URL]
#   前置: squid StatefulSet + Service(squid:3128, ssl-bump)已部署、squid-ca secret 存在。
set -e
NS="${NS:-test-husheng}"
K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS="$K8S_DIR/metrics-k8s.sh"
PROXY="http://squid.${NS}.svc.cluster.local:3128"
BASE_URL="${1:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"
# cache-busting: 唯一 query 串 → 保证窗口1是真 MISS(strip_query_terms 只影响日志, 不影响缓存 key)
URL="${BASE_URL}?cb=$(date +%s)-${RANDOM}"
POD=metrics-client

cleanup() { kubectl -n "$NS" delete pod "$POD" --grace-period=0 --force >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "=== K8s 分层指标测试  ns=$NS ==="
echo "URL: $BASE_URL"

# 固定身份的 client pod: Service sessionAffinity=ClientIP → 固定落到同一台 squid,
# prime 与 HIT 命中同一份缓存(各副本 PVC 独立)。挂 squid-ca 做 SSL-Bump 信任。
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $POD, labels: { app: metrics-client } }
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: alpine/curl:latest
    command: ["sleep","3600"]
    volumeMounts: [ { name: ca, mountPath: /etc/ca, readOnly: true } ]
  volumes:
  - name: ca
    secret: { secretName: squid-ca }
YAML
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null

# 在 client pod 内连打 N 次, 打印首个 http_code
hammer() {
  kubectl -n "$NS" exec "$POD" -- sh -c '
    code=""; i=0
    while [ $i -lt '"$1"' ]; do
      c=$(curl --cacert /etc/ca/squid-ca.pem -s -o /dev/null -w "%{http_code}" -x "'"$PROXY"'" "'"$URL"'" --max-time 300)
      [ -z "$code" ] && code=$c; i=$((i+1))
    done; echo "$code"'
}

echo ""; echo "--- 空闲 CPU 基线 15s ---"
NS="$NS" "$METRICS" baseline 15

echo ""; echo "--- MISS 窗口: 冷取 1 次 ---"
NS="$NS" "$METRICS" begin >/dev/null
CM=$(hammer 1)
[ "$CM" = 200 ] || { echo "✗ FAIL 冷取 http_code=$CM"; exit 1; }
echo "✓ 冷取(MISS): HTTP $CM"
NS="$NS" "$METRICS" end

echo ""; echo "--- HIT 窗口: 命中 30 次 ---"
NS="$NS" "$METRICS" begin >/dev/null
CH=$(hammer 30)
[ "$CH" = 200 ] || { echo "✗ FAIL 命中 http_code=$CH"; exit 1; }
echo "✓ 命中(HIT): HTTP $CH"
NS="$NS" "$METRICS" end

echo ""; echo "PASS"
