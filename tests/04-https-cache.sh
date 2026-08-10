#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA="$ROOT/configs/certs/client-ca.crt"
NET="haproxy_ha_squid_net"
VIP="172.30.0.100:3128"
URL="https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/Imath-debuginfo-3.1.4-1.oe2303.aarch64.rpm"
echo "=== 04: HTTPS SSL Bump 缓存 ==="
echo "首次 (MISS):" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt -s -o /dev/null -w "  %{time_total}s %{speed_download} B/s\n" -x http://$VIP "$URL" --max-time 300
echo "二次 (HIT):" && docker run --rm --network $NET -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest curl --cacert /tmp/ca.crt -s -o /dev/null -w "  %{time_total}s %{speed_download} B/s\n" -x http://$VIP "$URL" --max-time 300
echo "PASS"
