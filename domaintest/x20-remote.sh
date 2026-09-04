# 远程循环体: 在 squid pod 内运行 (由 kubectl exec sh -s -- ARGS ROUNDS < 本文件 调用)
# ARGS=$1: 空格分隔域名; R=$2: 轮数
# 端口说明: pod 内 squid 监听 3129 (http_port 3129 ssl-bump);
#   127.0.0.1:3128 是同 pod 的 registry-proxy nginx (cache_peer 上游), 测 squid 必须用 3129。
#   CI 客户端经 Service squid-cache:3128 会被 targetPort 转到 3129, 等价于本测试路径。
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
