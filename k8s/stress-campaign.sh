#!/bin/bash
# 一体化压测: A(N扫描) → B(副本扩展) → C(资源拐点) → D(冷启动)
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
NS=test-husheng
echo "stage,N,replicas,cpu_lim,mem_lim,success,failed,peak_cpu_m,peak_mem_mi,restarts,throughput" > "$DIR/stress-result.csv"

# 复用 stress.sh 的 run, 但记录 stage/replicas/资源上下文
STAGE=""; REPS=1; CPU=200m; MEM=128Mi
runrec() {
  local N="$1"
  export RUN_ID="s$(date +%s)$RANDOM" PARALLELISM="$N" COMPLETIONS="$N"
  export RPM_URL="https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm"
  envsubst '${RUN_ID} ${PARALLELISM} ${COMPLETIONS} ${RPM_URL}' < "$DIR/manifests/stress-client-job.yaml" | kubectl apply -f - >/dev/null
  local JOB="stress-client-$RUN_ID" pc=0 pm=0 i=0
  while [ $i -lt 90 ]; do
    local s=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null); s=${s:-0}
    local f=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null); f=${f:-0}
    local t=$(kubectl -n $NS top pods -l app=squid-stress --no-headers 2>/dev/null | awk '{c=$2;sub(/m$/,"",c);m=$3;sub(/Mi$/,"",m);cs+=c;ms+=m}END{print cs+0" "ms+0}')
    local cc=$(echo $t|cut -d' ' -f1); local mm=$(echo $t|cut -d' ' -f2)
    [ "${cc:-0}" -gt "$pc" ] 2>/dev/null && pc=$cc
    [ "${mm:-0}" -gt "$pm" ] 2>/dev/null && pm=$mm
    [ $((s+f)) -ge "$N" ] && break; sleep 2; i=$((i+1))
  done
  local SU=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null); SU=${SU:-0}
  local FA=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null); FA=${FA:-0}
  local TH=$(kubectl -n $NS logs -l job-name="$JOB" --tail=-1 2>/dev/null | grep "^OK" | awk -F'[= ]' '{t=$5;sub(/s$/,"",t);sp=$7;sum+=t;n++;if(n==1||t<mn)mn=t;if(t>mx)mx=t;spsum+=sp}END{if(n>0)printf "min%.2f/avg%.2f/max%.2fs_%.0fMBps",mn,sum/n,mx,spsum/n/1048576}')
  local RS=$(kubectl -n $NS get pods -l app=squid-stress -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"+"}{end}' 2>/dev/null)
  echo "[$STAGE N=$N reps=$REPS $CPU/$MEM] 成功=$SU/$N 失败=$FA peakCPU=${pc}m peakMEM=${pm}Mi restart=$RS 吞吐=$TH"
  echo "$STAGE,$N,$REPS,$CPU,$MEM,$SU,$FA,$pc,$pm,$RS,$TH" >> "$DIR/stress-result.csv"
  kubectl -n $NS delete job "$JOB" >/dev/null 2>&1
}
deploy() { REPS=$1; CPU=$2; MEM=$3
  export REPLICAS=$REPS CPU_LIMIT=$CPU MEM_LIMIT=$MEM
  envsubst '${REPLICAS} ${CPU_LIMIT} ${MEM_LIMIT}' < "$DIR/manifests/stress-deployment.yaml" | kubectl apply -f - >/dev/null
  kubectl -n $NS rollout status deploy/squid-stress --timeout=120s >/dev/null 2>&1
  sleep 3
}
warm() { runrec "${REPS}" >/dev/null 2>&1; runrec "$((REPS*4))" >/dev/null 2>&1; }  # 填充各副本缓存

echo "######## A: 单副本 N 扫描 (1副本 200m/128Mi) ########"
STAGE=A; deploy 1 200m 128Mi; warm
for n in 10 20 40 80; do runrec $n; sleep 2; done

echo "######## B: 副本扩展 (N=40 固定, 1→2副本) ########"
STAGE=B; deploy 1 200m 128Mi; warm; runrec 40
deploy 2 200m 128Mi; warm; runrec 40

echo "######## C: 资源拐点 (1副本 N=40, 调 CPU/内存) ########"
STAGE=C
deploy 1 100m 64Mi;  warm; runrec 40
deploy 1 200m 128Mi; warm; runrec 40
deploy 1 500m 256Mi; warm; runrec 40

echo "######## D: 冷启动 (1副本 500m/256Mi, 清缓存后 N=40) ########"
STAGE=D; deploy 1 500m 256Mi
# 清缓存: 重启 deployment
kubectl -n $NS rollout restart deploy/squid-stress >/dev/null 2>&1
kubectl -n $NS rollout status deploy/squid-stress --timeout=120s >/dev/null 2>&1; sleep 5
runrec 40   # 冷启动直接压, 不预热

echo "######## 完成 ########"
cat "$DIR/stress-result.csv"
