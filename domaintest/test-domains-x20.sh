#!/usr/bin/env bash
# 对白名单每个域名做 N 轮「DNS 解析 + 经 squid 连通」测试, 采集每轮解析 IP 与连通结果
# 用法: bash test-domains-x20.sh
# 输出: results-x20-<cluster>.tsv   每行: 域名|成功数|超时数|DNS失败|连接拒绝|逐轮IP(逗号分隔,N个)
set -u
cd "$(dirname "$0")"

ROUNDS="${ROUNDS:-20}"
KUBECTL_OPTS="${KUBECTL_OPTS:-}"

# 从白名单 json 提取实域名(跳过 *. 通配), 拼成空格分隔串(域名无空格/glob 字符, 直接分词安全)
ARGS=$(python3 - <<'PY'
import json
doms = [x.replace("https://","").strip() for x in json.load(open("ascend_ci_domains.json")) if not x.startswith("*")]
print(" ".join(d for d in doms))
PY
)

# 在指定集群的 squid pod 内执行 N 轮测试
run_cluster() {
  local kube="$1" pod="$2" out="$3"
  echo ">>> [$kube] $pod  开始 ${ROUNDS} 轮 × $(echo "$ARGS" | wc -w) 域名"
  kubectl --kubeconfig "$kube" exec -i -n squid "$pod" -c squid -- sh -s -- "$ARGS" "$ROUNDS" <<'REMOTE' > "$out"
set -u
ARGS="$1"; R="$2"
for d in $ARGS; do
  ok=0; to=0; dn=0; cn=0; ips=""
  i=1
  while [ "$i" -le "$R" ]; do
    ip=$(getent hosts "$d" | awk '{print $1}' | head -1)
    [ -n "$ip" ] && ips="$ips,$ip"
    code=$(curl -sk -o /dev/null --proxy http://127.0.0.1:3129 --max-time 6 -w "%{http_code}" "https://$d/" 2>/dev/null)
    ec=$?
    if [ "$ec" -eq 0 ]; then ok=$((ok+1)); else
      case "$ec" in
        28) to=$((to+1));; 6) dn=$((dn+1));; 7) cn=$((cn+1));; *) to=$((to+1));;
      esac
    fi
    i=$((i+1))
  done
  ips=${ips#,}
  echo "$d|$ok|$to|$dn|$cn|$ips"
done
REMOTE
  echo ">>> [$kube] 完成: $out"
}

# 两个集群并行
run_cluster "$HOME/.kube/wlcb-001.yaml"  squid-cache-0 results-x20-wlcb.tsv &
run_cluster "$HOME/.kube/gy-001.yaml"    squid-cache-0 results-x20-gy001.tsv &
wait
echo "全部完成"
