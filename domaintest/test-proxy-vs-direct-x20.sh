#!/usr/bin/env bash
# 域名连通性 Proxy vs 直连 对比测试 (修正版: proxy 走 squid 3129, 非 nginx 3128)
# 方法: 在各自集群的 squid pod 内 (同一 pod/节点/出口 NAT),
#       对每个白名单实域名做 R 轮「经 squid 代理 (127.0.0.1:3129)」+ R 轮「直连」,
#       curl -sk --max-time 6, 只看连通性。
# 用法: bash test-proxy-vs-direct-x20.sh
# 输出: results-pvd-<cluster>.tsv  每行: 域名|proxy成功|proxy超时|proxyDNS|proxy连拒|直连成功|直连超时|直连DNS|直连连拒
set -u
cd "$(dirname "$0")"

ROUNDS="${ROUNDS:-20}"
KUBECTL_OPTS="${KUBECTL_OPTS:-}"

# 从白名单 json 提取实域名(跳过 *. 通配), 拼成空格分隔串
ARGS=$(python3 - <<'PY'
import json
doms = [x.replace("https://","").strip() for x in json.load(open("ascend_ci_domains.json")) if not x.startswith("*")]
print(" ".join(d for d in doms))
PY
)

# 远程循环体: proxy(3129) 与 直连 各 R 轮, 结果写一行
REMOTE='set -u
ARGS="$1"; R="$2"
for d in $ARGS; do
  pok=0; pto=0; pdn=0; pcn=0
  dok=0; dto=0; ddn=0; dcn=0
  i=1
  while [ "$i" -le "$R" ]; do
    curl -sk -o /dev/null --proxy http://127.0.0.1:3129 --max-time 6 "https://$d/" 2>/dev/null
    ec=$?
    if [ "$ec" -eq 0 ]; then pok=$((pok+1)); else
      case "$ec" in
        28) pto=$((pto+1));; 6) pdn=$((pdn+1));; 7) pcn=$((pcn+1));; *) pto=$((pto+1));;
      esac
    fi
    curl -sk -o /dev/null --max-time 6 "https://$d/" 2>/dev/null
    ec=$?
    if [ "$ec" -eq 0 ]; then dok=$((dok+1)); else
      case "$ec" in
        28) dto=$((dto+1));; 6) ddn=$((ddn+1));; 7) dcn=$((dcn+1));; *) dto=$((dto+1));;
      esac
    fi
    i=$((i+1))
  done
  echo "$d|$pok|$pto|$pdn|$pcn|$dok|$dto|$ddn|$dcn"
done'

run_cluster() {
  local kube="$1" out="$2"
  echo ">>> [$kube] squid-cache-0  开始 ${ROUNDS} 轮 proxy + ${ROUNDS} 轮 直连 × $(echo "$ARGS" | wc -w) 域名"
  kubectl --kubeconfig "$kube" exec -i -n squid squid-cache-0 -c squid -- sh -s -- "$ARGS" "$ROUNDS" <<< "$REMOTE" > "$out"
  echo ">>> [$kube] 完成: $(wc -l < "$out") 条 -> $out"
}

# 三集群并行
run_cluster "$HOME/.kube/gy-001.yaml"  results-pvd-gy001.tsv &
run_cluster "$HOME/.kube/wlcb-001.yaml" results-pvd-wlcb.tsv &
run_cluster "$HOME/.kube/gy-002.yaml"  results-pvd-gy002.tsv &
wait
echo "全部完成"
