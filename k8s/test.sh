#!/bin/bash
# K8s Squid 验证 —— 代理连通 / HTTPS缓存 / Pod故障 / PVC持久化
# 前置: ./deploy.sh 已完成
set -e
NS=test-husheng
PROXY="http://squid.test-husheng.svc.cluster.local:3128"
CA_SECRET_PATH="/etc/ca/squid-ca.pem"
RPM="${HTTPS_CACHE_URL:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"

# 在集群内起一个带 CA 的临时 client, 执行传入命令
krun() {
    kubectl -n "$NS" run bk-client-$RANDOM --rm -i --restart=Never \
        --image=alpine/curl:latest \
        --overrides='{"spec":{"volumes":[{"name":"ca","secret":{"secretName":"squid-ca"}}],"containers":[{"name":"c","image":"alpine/curl:latest","stdin":true,"volumeMounts":[{"name":"ca","mountPath":"/etc/ca"}],"command":["sh","-c","'"$1"'"]}]}}' 2>/dev/null
}

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  ✓ $3"; PASS=$((PASS+1)); else echo "  ✗ FAIL $3 (期望 $1 实际 $2)"; FAIL=$((FAIL+1)); fi; }

echo "============================================"
echo "  K8s Squid 验证 (StatefulSet 持久缓存)"
echo "============================================"

echo "--- 01: HTTP 代理 ---"
CODE=$(krun "curl -s -o /dev/null -w '%{http_code}' -x $PROXY http://repo.openeuler.org/ --max-time 15")
check 200 "$CODE" "HTTP 代理返回 200"

echo "--- 02: HTTPS SSL Bump 代理 ---"
CODE=$(krun "curl --cacert $CA_SECRET_PATH -s -o /dev/null -w '%{http_code}' -x $PROXY https://repo.openeuler.org/ --max-time 15")
check 200 "$CODE" "HTTPS 代理返回 200"

echo "--- 03: HTTPS 缓存(首次 MISS→二次) ---"
krun "curl --cacert $CA_SECRET_PATH -s -o /dev/null -x $PROXY $RPM --max-time 120" >/dev/null
T2=$(krun "curl --cacert $CA_SECRET_PATH -s -o /dev/null -w '%{time_total}' -x $PROXY $RPM --max-time 120")
echo "  二次下载耗时: ${T2}s"
HITS=$(kubectl -n "$NS" logs -l app=squid-cache --tail=200 2>/dev/null | grep -c "TCP_HIT.*bcc-debuginfo" || echo 0)
check_gt() { if [ "$1" -gt 0 ]; then echo "  ✓ $2 (命中 $1 次)"; PASS=$((PASS+1)); else echo "  ✗ FAIL $2"; FAIL=$((FAIL+1)); fi; }
check_gt "$HITS" "Squid 日志出现 TCP_HIT"

echo "--- 04: Pod 故障切换 ---"
kubectl -n "$NS" delete pod squid-1 >/dev/null 2>&1
sleep 5
CODE=$(krun "curl -s -o /dev/null -w '%{http_code}' -x $PROXY http://repo.openeuler.org/ --max-time 15")
check 200 "$CODE" "删除 squid-1 后代理仍 200"
kubectl -n "$NS" rollout status statefulset/squid --timeout=180s >/dev/null 2>&1

echo "--- 05: PVC 持久化(StatefulSet 特性) ---"
# squid-0 删前记录缓存文件数, 删 Pod(PVC 保留), 重建后应仍有缓存
BEFORE=$(kubectl -n "$NS" exec squid-0 -- sh -c 'find /var/spool/squid/0* -type f 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
kubectl -n "$NS" delete pod squid-0 >/dev/null 2>&1
kubectl -n "$NS" wait --for=condition=ready pod/squid-0 --timeout=180s >/dev/null 2>&1
AFTER=$(kubectl -n "$NS" exec squid-0 -- sh -c 'find /var/spool/squid/0* -type f 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
echo "  缓存文件数: 删Pod前 $BEFORE → 重建后 $AFTER"
if [ "${AFTER:-0}" -gt 0 ]; then echo "  ✓ PVC 缓存跨 Pod 重建持久"; PASS=$((PASS+1)); else echo "  ✗ FAIL PVC 未持久"; FAIL=$((FAIL+1)); fi

echo ""
echo "============================================"
echo "  结果: $PASS 通过 / $FAIL 失败"
echo "============================================"
[ "$FAIL" -eq 0 ]
