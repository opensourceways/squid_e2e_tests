#!/bin/sh
# download.pytorch.org/whl/ 连通性探测（经 Squid 代理 + 直连对照）
#
# 背景：gy-001 集群的 172.16.0.37 是缓存节点（taint cache:true），无法直接调度普通镜像；
#       Squid 两个副本就运行在 37 上，且自建 squid 镜像自带 /usr/bin/curl，
#       因此直接在 squid Pod（即 37 的网络）里注入代理做连通性测试。
#
# 用法：
#   方式 A（推荐，即测即得）：
#     kubectl exec -i -n squid <squid-pod> -c squid -- sh -s < run-probe.sh
#   （其中 <squid-pod> 是 172.16.0.37 上的 squid-cache-0/1）
#
#   方式 B（可重复 Job）：见同目录 01-download-pytorch-connectivity.yaml，
#     容器入口直接执行本脚本（通过 ConfigMap/CM 挂载或 inline 复制）。

# 注入约定：与 traffic-test/tool（08-bazel.yaml 等）及 redirect 其它 vcjob 一致，用标准环境变量
#   HTTPS_PROXY / SSL_CERT_FILE（容器级注入）→ 本脚本无 env 时回落 Pod 内直连。
# 注意端口：squid 本体 ssl-bump 监听 3129；同 Pod 的 registry-proxy 监听 3128（隧道透传，不可见内容）。
#           集群内客户端统一走 Service：squid-cache.squid.svc.cluster.local:3128 → 3129(squid)。
P="${HTTPS_PROXY:-http://127.0.0.1:3129}"      # Pod 内直连 squid；集群内客户端注入 Service 3128
CA="${SSL_CERT_FILE:-/etc/squid/ssl_cert/squid-ca-bundle.pem}"   # 方式 A(squid Pod 内)默认；方式 B 由 env 覆盖
BASE=https://download.pytorch.org/whl

# 单次 GET 探测：标签 URL [额外 curl 参数]
probe() {
  tag="$1"; url="$2"; shift 2
  curl -sS --cacert "$CA" -x "$P" "$@" -o /dev/null \
    -w "$tag: HTTP %{http_code} | %{content_type} | %{size_download}B | %{time_total}s\n" \
    --max-time 60 "$url" || echo "$tag: FAILED"
}

# 带响应头（含 X-Cache / Via，判断缓存命中）的探测
hdr() {
  tag="$1"; url="$2"
  echo "--- $tag (headers) ---"
  curl -sSI --cacert "$CA" -x "$P" --max-time 60 "$url" \
    | grep -iE "^(HTTP|content-type|content-length|x-cache|x-squid-error|via|location)" | head -12
  echo "---"
}

echo "node=$(hostname)  pod=$HOSTNAME  date=$(date -u +%FT%TZ)"
echo "proxy=$P  ca=$CA"
echo

echo "===== [经代理] GET /whl/（连测两次看缓存 MISS→HIT） ====="
probe "root#1 " "$BASE/"
probe "root#2 " "$BASE/"
echo

echo "===== [经代理] GET /whl/cpu/torch/ 索引页（PEP 503，发现 +cpu 变体的入口） ====="
probe "index#1" "$BASE/cpu/torch/"
probe "index#2" "$BASE/cpu/torch/"
echo "--- index#2 响应头（确认 X-Cache MISS→HIT） ---"
curl -sSI --cacert "$CA" -x "$P" --max-time 60 "$BASE/cpu/torch/" \
  | grep -iE "^(HTTP|content-type|content-length|x-cache|via)" | head -8
echo "---"
echo

echo "===== [经代理] 取最新 2.x wheel 做 HEAD（看 content-length / X-Cache） ====="
# 索引页里 wheel 链接是绝对 URL 且跨 host：https://download-r2.pytorch.org/whl/cpu/torch-...whl#sha256=...
# （实证：download.pytorch.org 上不存在对象路径，直接 GET/HEAD 会 403 from cloudfront）
# 取最后一个 2.x wheel 的完整 href，去掉 #sha256 fragment 再 HEAD。
WHEEL_URL=$(curl -sS --cacert "$CA" -x "$P" --max-time 60 "$BASE/cpu/torch/" 2>/dev/null \
        | grep -oE 'href="https://download-r2\.pytorch\.org/whl/cpu/torch-2\.[0-9]+\.[0-9]+[^"<]*linux_x86_64\.whl' \
        | sed 's/^href="//' | tail -1)
echo "wheel_url=$WHEEL_URL"
if [ -n "$WHEEL_URL" ]; then
  hdr "wheel#1" "$WHEEL_URL"
  hdr "wheel#2" "$WHEEL_URL"
fi
echo

echo "===== [直连，不走代理] 对照（判断 37 是否本来就能到境外） ====="
for u in "$BASE/" "$BASE/cpu/torch/"; do
  curl -sS --noproxy '*' -o /dev/null -w "direct $u -> HTTP %{http_code} | %{content_type} | %{time_total}s\n" \
       --max-time 30 "$u" 2>/dev/null || echo "direct $u -> FAILED(直连不可达)"
done
echo

echo "DONE"
