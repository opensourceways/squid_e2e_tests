#!/bin/bash
# no-mirror-test 全量回归循环（v7.7.2 AKI 补丁版验证）
# 踩坑修正史：
# ① `get jobs` 看不见 Volcano Job → 必须用 `create -o name` 拿回名字
# ② `kubectl wait --for=condition=complete vcjob/...` 永不匹配（Volcano 条件
#    类型是 Completed 不是 Complete）→ 改为轮询 Pod phase
# ③ Pod 经 SNAT，access.log 源 IP 非 Pod IP（排查时勿按 Pod IP 过滤日志）
KC=${KC:-$HOME/.kube/gy-006.yaml}
LOG=${LOG:-/tmp/no-mirror-rerun.log}
K="kubectl --kubeconfig $KC -n squid"
cd "$(dirname "$0")"
: > "$LOG"
for f in tool-*.yaml; do
  echo ">>> create $f" | tee -a "$LOG"
  JOB=$($K create -f "$f" -o name 2>&1 | tail -1)
  NAME=${JOB##*/}
  if [ -z "$NAME" ] || [[ "$NAME" != test-squid-* ]]; then
    echo "!!! create 失败: $JOB" | tee -a "$LOG"
    continue
  fi
  # 轮询 Pod phase（Volcano 会把 vcjob 名编进 pod 名）
  POD=""
  PHASE=""
  for i in $(seq 1 240); do
    if [ -z "$POD" ]; then
      POD=$($K get pods -o name 2>/dev/null | grep "$NAME" | head -1 | cut -d/ -f2)
    fi
    if [ -n "$POD" ]; then
      PHASE=$($K get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
      case "$PHASE" in
        Succeeded|Failed|Evicted) break ;;
      esac
    fi
    sleep 10
  done
  echo ">>> $NAME pod=$POD phase=$PHASE" | tee -a "$LOG"
  if [ "$PHASE" = "Succeeded" ]; then
    $K logs "$POD" 2>/dev/null | grep -E '✅|DURATION' | tee -a "$LOG"
  else
    echo "!!! FAILED/TIMEOUT: $f ($NAME phase=$PHASE)" | tee -a "$LOG"
    [ -n "$POD" ] && $K logs "$POD" --tail=30 2>&1 | tee -a "$LOG"
  fi
done
echo "=== ALL DONE ===" | tee -a "$LOG"
