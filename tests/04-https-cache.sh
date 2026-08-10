#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)" && CA="$ROOT/configs/certs/client-ca.crt"
NET="haproxy_ha_squid_net" && VIP="172.30.0.100:3128"
# 用 ~5MB 测试文件（curl 官网,支持 HTTPS+200 OK+内容不常变）
URL="https://curl.se/download/curl-8.9.1.tar.gz"
echo "=== 04: HTTPS SSL Bump 缓存 ==="
echo "首次 (MISS):"
docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest \
  curl --cacert /tmp/ca.crt --connect-timeout 10 -s -o /dev/null \
  -w "  %{time_total}s %{size_download}B\n" -x http://$VIP "$URL" --max-time 120
echo "二次 (HIT):"
docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest \
  curl --cacert /tmp/ca.crt --connect-timeout 10 -s -o /dev/null \
  -w "  %{time_total}s %{size_download}B\n" -x http://$VIP "$URL" --max-time 120
echo "PASS"
