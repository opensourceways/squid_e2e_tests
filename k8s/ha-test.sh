#!/bin/bash
# K8s 多副本 HA 测试 —— 移植原 Docker Compose 的 6 个场景
# HA 由 Service 提供(替代 keepalived+HAProxy), 故障注入用 kubectl delete pod
# 用法: ./ha-test.sh [deploy|test|clean]
# 注: 不用 set -e —— 故障注入/grep 常返回非0, 靠断言函数记录成败
DIR="$(cd "$(dirname "$0")" && pwd)"
NS=test-husheng
APP=squid-ha
SVC="http://squid-ha.test-husheng.svc.cluster.local:3128"
RPM="${HTTPS_CACHE_URL:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"
CLIENT=ha-client   # 常驻 client pod(带 CA)

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
ng(){ echo "  ✗ FAIL $1"; FAIL=$((FAIL+1)); }

# 在常驻 client pod 内执行 curl, 返回 http_code
cget(){ kubectl -n $NS exec $CLIENT -- curl --cacert /etc/ca/squid-ca.pem -s -o /dev/null \
        -w "%{http_code}" -x "$SVC" "$1" --max-time "${2:-20}" 2>/dev/null; }

deploy(){
  echo "=== 部署 3 副本 HA(Deployment+emptyDir) ==="
  kubectl -n $NS get secret squid-ca >/dev/null 2>&1 || { echo "缺 squid-ca, 先跑 ./deploy.sh"; exit 1; }
  kubectl -n $NS get cm squid-config >/dev/null 2>&1 || kubectl apply -f "$DIR/manifests/01-configmap.yaml"
  kubectl apply -f "$DIR/manifests/ha-deployment.yaml"
  kubectl -n $NS rollout status deploy/$APP --timeout=180s
  # 常驻 client pod
  kubectl -n $NS delete pod $CLIENT --ignore-not-found >/dev/null 2>&1
  kubectl -n $NS run $CLIENT --image=alpine/curl:latest --restart=Never \
    --overrides='{"spec":{"volumes":[{"name":"ca","secret":{"secretName":"squid-ca"}}],"containers":[{"name":"c","image":"alpine/curl:latest","command":["sleep","36000"],"volumeMounts":[{"name":"ca","mountPath":"/etc/ca"}]}]}}' >/dev/null 2>&1
  kubectl -n $NS wait --for=condition=ready pod/$CLIENT --timeout=60s >/dev/null 2>&1
  kubectl -n $NS get pods -l app=$APP -o wide
}

ready_pods(){ kubectl -n $NS get pods -l app=$APP --field-selector status.phase=Running -o name 2>/dev/null; }
endpoint_cnt(){ kubectl -n $NS get endpoints squid-ha -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '; }

test_all(){
  echo "============================================"
  echo "  K8s 多副本 HA 测试 (Service + kill pod)"
  echo "============================================"

  # --- 01: 基础代理(经 Service) ---
  echo "--- 01 基础代理(经 Service) ---"
  [ "$(cget http://repo.openeuler.org/)" = "200" ] && ok "HTTP 经 Service 200" || ng "HTTP"
  [ "$(cget https://repo.openeuler.org/)" = "200" ] && ok "HTTPS SSL Bump 经 Service 200" || ng "HTTPS"

  # --- 02: 单 Pod 故障(删1个, Service 继续) ---
  echo "--- 02 单 Pod 故障切换(kubectl delete pod) ---"
  P=$(ready_pods | head -1); echo "  删除 $P"
  kubectl -n $NS delete $P --grace-period=0 --force >/dev/null 2>&1
  sleep 3
  [ "$(cget http://repo.openeuler.org/)" = "200" ] && ok "删1 Pod 后 Service 仍 200" || ng "单Pod故障"
  kubectl -n $NS rollout status deploy/$APP --timeout=120s >/dev/null 2>&1

  # --- 03: Service 层 HA(滚动删除全部, 端点始终>0) ---
  echo "--- 03 Service 层 HA(逐个删Pod, 端点不空) ---"
  local minep=99
  for p in $(ready_pods); do
    kubectl -n $NS delete $p --grace-period=0 --force >/dev/null 2>&1
    sleep 2
    ep=$(endpoint_cnt); [ "$ep" -lt "$minep" ] && minep=$ep
    sleep 4
  done
  kubectl -n $NS rollout status deploy/$APP --timeout=120s >/dev/null 2>&1
  [ "$minep" -ge 1 ] && ok "滚动删除全程 Service 端点≥1(最低$minep)" || ng "Service 端点空过(最低$minep)"
  [ "$(cget http://repo.openeuler.org/)" = "200" ] && ok "全部重建后 Service 200" || ng "重建后"

  # --- 04: HTTPS 缓存(经 Service MISS→HIT) ---
  echo "--- 04 HTTPS 缓存(经 Service) ---"
  cget "$RPM" 120 >/dev/null   # 首次填充
  local t2=$(kubectl -n $NS exec $CLIENT -- curl --cacert /etc/ca/squid-ca.pem -s -o /dev/null \
    -w "%{time_total}" -x "$SVC" "$RPM" --max-time 120 2>/dev/null)
  echo "  二次下载耗时: ${t2}s"
  # 命中率: 任一 pod 日志出现 TCP_HIT
  local hit=0
  for p in $(kubectl -n $NS get pods -l app=$APP -o name 2>/dev/null); do
    n=$(kubectl -n $NS logs "$p" --tail=-1 2>/dev/null | grep -c "TCP_HIT\|TCP_MEM_HIT"); hit=$((hit+n))
  done
  [ "$hit" -gt 0 ] && ok "二次下载 Squid TCP_HIT(命中 $hit)" || ng "未命中缓存"

  # --- 05: 下载中断(下载时删 pod, Service 继续) ---
  echo "--- 05 下载中 Pod 故障 ---"
  kubectl -n $NS exec $CLIENT -- sh -c "curl --cacert /etc/ca/squid-ca.pem -s -o /dev/null -x $SVC $RPM --max-time 120 &" >/dev/null 2>&1 || true
  sleep 2
  P=$(ready_pods | head -1); kubectl -n $NS delete $P --grace-period=0 --force >/dev/null 2>&1
  sleep 3
  [ "$(cget http://repo.openeuler.org/)" = "200" ] && ok "下载中删 Pod, Service 仍 200" || ng "中断影响"
  kubectl -n $NS rollout status deploy/$APP --timeout=120s >/dev/null 2>&1

  # --- 06: 多 Pod 同时故障(删2个, 剩1个服务) ---
  echo "--- 06 两 Pod 同时故障(仅剩1副本) ---"
  for p in $(ready_pods | head -2); do kubectl -n $NS delete $p --grace-period=0 --force >/dev/null 2>&1 & done
  wait; sleep 5
  local okc=0; for i in 1 2 3; do [ "$(cget http://repo.openeuler.org/)" = "200" ] && okc=$((okc+1)); done
  [ "$okc" -eq 3 ] && ok "删2 Pod 后 3/3 请求 200" || ng "多Pod故障(仅 $okc/3)"
  kubectl -n $NS rollout status deploy/$APP --timeout=120s >/dev/null 2>&1

  echo ""
  echo "============================================"
  echo "  结果: $PASS 通过 / $FAIL 失败"
  echo "============================================"
  [ "$FAIL" -eq 0 ]
}

clean(){
  kubectl -n $NS delete pod $CLIENT --ignore-not-found >/dev/null 2>&1
  kubectl delete -f "$DIR/manifests/ha-deployment.yaml" >/dev/null 2>&1
  echo "HA 测试资源已清理"
}

case "${1:-test}" in
  deploy) deploy ;;
  test)   deploy; test_all ;;
  clean)  clean ;;
  *) echo "用法: $0 {deploy|test|clean}"; exit 1 ;;
esac
