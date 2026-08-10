#!/bin/bash
# 测试: HTTP/HTTPS 代理连通性
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA="$ROOT/configs/certs/client-ca.crt"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
echo "=== 01: 代理连通性 ==="
echo "HTTP:" && docker run --rm --network $NET alpine/curl:latest curl -s -o /dev/null -w "  %{http_code} %{time_total}s\n" -x http://$VIP http://repo.openeuler.org/ --max-time 10
echo "HTTPS:" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt -s -o /dev/null -w "  %{http_code} %{time_total}s\n" -x http://$VIP https://repo.openeuler.org/ --max-time 10
echo "PASS"
