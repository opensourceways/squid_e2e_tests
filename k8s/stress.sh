#!/bin/bash
# Squid 上限压测 —— 部署小规格 Deployment, 预热, N 扫描, 采集资源/吞吐/成功率
# 用法:
#   ./stress.sh deploy [replicas] [cpu_limit] [mem_limit]   # 部署/更新压测实例
#   ./stress.sh warm                                        # 预热缓存(纯 HIT 前置)
#   ./stress.sh run <N> <completions>                       # 跑一轮并发, 输出指标
#   ./stress.sh sweep                                       # A阶段: N=10,20,40,80 扫描
#   ./stress.sh clean                                       # 清理压测资源
set -e
K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
NS=test-husheng
SVC="http://squid-stress.test-husheng.svc.cluster.local:3128"
RPM_URL="${HTTPS_CACHE_URL:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"

deploy() {
    export REPLICAS="${1:-1}" CPU_LIMIT="${2:-200m}" MEM_LIMIT="${3:-128Mi}"
    echo "部署 squid-stress: replicas=$REPLICAS cpu=$CPU_LIMIT mem=$MEM_LIMIT"
    kubectl apply -f "$K8S_DIR/manifests/stress-configmap.yaml" >/dev/null
    # CA secret 复用主部署的; 若无则报错提示
    kubectl -n $NS get secret squid-ca >/dev/null 2>&1 || { echo "缺 squid-ca secret, 先跑 ./deploy.sh"; exit 1; }
    envsubst '${REPLICAS} ${CPU_LIMIT} ${MEM_LIMIT}' < "$K8S_DIR/manifests/stress-deployment.yaml" | kubectl apply -f - >/dev/null
    kubectl -n $NS rollout status deploy/squid-stress --timeout=180s
    kubectl -n $NS get pods -l app=squid-stress -o wide
}

warm() {
    echo "预热缓存(填充 RPM 到各副本)..."
    # 跑 2×副本数 次串行下载, 确保每个副本都缓存了
    local reps=$(kubectl -n $NS get deploy squid-stress -o jsonpath='{.spec.replicas}')
    envsubst '${RUN_ID} ${PARALLELISM} ${COMPLETIONS} ${RPM_URL}' \
        <<< "$(RUN_ID=warm$(date +%s) PARALLELISM=$((reps*2)) COMPLETIONS=$((reps*4)) RPM_URL=$RPM_URL envsubst < "$K8S_DIR/manifests/stress-client-job.yaml")" \
        2>/dev/null | kubectl apply -f - >/dev/null || true
    sleep 3
    kubectl -n $NS wait --for=condition=complete job -l app=stress-client --timeout=300s >/dev/null 2>&1 || true
    kubectl -n $NS delete job -l app=stress-client >/dev/null 2>&1 || true
    echo "预热完成"
}

run() {
    # N=总并发; 用少量 pod × 每 pod 并发 打出 N (避免一次性 N 个 pod)
    local N="$1"
    local PODS="${PODS_OVERRIDE:-4}"                      # 默认 4 个 client pod
    [ "$N" -lt "$PODS" ] && PODS="$N"
    local PER_POD=$(( (N + PODS - 1) / PODS ))            # 每 pod 并发(向上取整)
    local ACTUAL=$((PODS * PER_POD))
    export RUN_ID="s$(date +%s)" PODS PER_POD
    export RPM_URL="${RPM_URL}"
    echo "----- 并发 N=$N ($PODS pod × $PER_POD/pod = $ACTUAL 实际) -----"
    envsubst '${RUN_ID} ${PODS} ${PER_POD} ${RPM_URL}' \
        < "$K8S_DIR/manifests/stress-client-job.yaml" | kubectl apply -f - >/dev/null
    local JOB="stress-client-$RUN_ID" C="$PODS"

    # 轮询等待完成, 期间采集 Squid 峰值 CPU/内存
    local peak_cpu=0 peak_mem=0 i=0
    while [ $i -lt 120 ]; do
        local s=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null); s=${s:-0}
        local f=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null); f=${f:-0}
        local t=$(kubectl -n $NS top pods -l app=squid-stress --no-headers 2>/dev/null | \
            awk '{c=$2; sub(/m$/,"",c); m=$3; sub(/Mi$/,"",m); cs+=c; ms+=m} END{print cs" "ms}')
        local cc=$(echo $t | cut -d' ' -f1); cc=${cc:-0}; [ -z "$cc" ] && cc=0
        local mm=$(echo $t | cut -d' ' -f2); mm=${mm:-0}; [ -z "$mm" ] && mm=0
        [ "$cc" -gt "$peak_cpu" ] 2>/dev/null && peak_cpu=$cc
        [ "$mm" -gt "$peak_mem" ] 2>/dev/null && peak_mem=$mm
        [ $((s + f)) -ge "$C" ] && break
        sleep 2; i=$((i+1))
    done

    local SUCC=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null); SUCC=${SUCC:-0}
    local FAILED=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null); FAILED=${FAILED:-0}
    # 从 pod 日志统计下载成功数(OK 行)与吞吐
    local oklog=$(kubectl -n $NS logs -l job-name="$JOB" --tail=-1 2>/dev/null)
    local ok_cnt=$(echo "$oklog" | grep -c "^OK")
    local fail_cnt=$(echo "$oklog" | grep -c "^FAIL")
    local stats=$(echo "$oklog" | grep "^OK" | \
        awk -F'[= ]' '{t=$3; sub(/s$/,"",t); sp=$5; sum+=t; n++; if(n==1||t<mn)mn=t; if(t>mx)mx=t; spsum+=sp} \
        END{if(n>0)printf "下载OK=%d min=%.2fs max=%.2fs avg=%.2fs 平均单流=%.0fMB/s", n, mn, mx, sum/n, spsum/n/1048576; else printf "无OK日志"}')
    local restarts=$(kubectl -n $NS get pods -l app=squid-stress -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}' 2>/dev/null)
    echo "  下载成功: $ok_cnt/$N  失败: $fail_cnt  (pod: $SUCC/$C)"
    echo "  吞吐: $stats"
    echo "  Squid 峰值: CPU=${peak_cpu}m  内存=${peak_mem}Mi"
    echo "  副本重启: $restarts (非0 疑似 OOM)"
    echo "$N,$ok_cnt,$fail_cnt,$peak_cpu,$peak_mem,$restarts,$stats" >> "$K8S_DIR/stress-result.csv"
    kubectl -n $NS delete job "$JOB" >/dev/null 2>&1 || true
}

sweep() {
    echo "===== A 阶段: N 扫描 (10 → 20 → 40 → 80) ====="
    for n in 10 20 40 80; do run "$n" "$n"; sleep 3; done
}

clean() {
    kubectl -n $NS delete job -l app=stress-client 2>/dev/null || true
    kubectl -n $NS delete deploy squid-stress 2>/dev/null || true
    kubectl -n $NS delete svc squid-stress 2>/dev/null || true
    kubectl -n $NS delete configmap squid-stress-config 2>/dev/null || true
    echo "压测资源已清理"
}

case "${1:-}" in
    deploy) deploy "$2" "$3" "$4" ;;
    warm)   warm ;;
    run)    run "$2" "$3" ;;
    sweep)  sweep ;;
    clean)  clean ;;
    *) echo "用法: $0 {deploy [reps] [cpu] [mem] | warm | run <N> [C] | sweep | clean}"; exit 1 ;;
esac
