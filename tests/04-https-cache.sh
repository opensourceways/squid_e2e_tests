#!/bin/bash
# 04: HTTPS SSL Bump 缓存 —— 显示首次(MISS)与二次(HIT)耗时对比
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 04: HTTPS SSL Bump 缓存 ==="
echo "URL: $HTTPS_CACHE_URL"

# 返回 "http_code time_total size_download speed_download"
https_dl() {
    docker run --rm --network "$NET" -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest \
        curl --cacert /tmp/ca.crt --connect-timeout 10 -s -o /dev/null \
        -w "%{http_code} %{time_total} %{size_download} %{speed_download}" \
        -x "http://$VIP" "$HTTPS_CACHE_URL" --max-time 300 2>/dev/null
}

read -r C1 T1 S1 SP1 <<< "$(https_dl)"
assert_code "首次下载(MISS)" 200 "$C1"
printf "  首次(MISS): %ss  %s bytes  %.0f B/s\n" "$T1" "$S1" "$SP1"

read -r C2 T2 S2 SP2 <<< "$(https_dl)"
assert_code "二次下载(HIT)" 200 "$C2"
printf "  二次(HIT):  %ss  %s bytes  %.0f B/s\n" "$T2" "$S2" "$SP2"

echo "  耗时对比: 首次 ${T1}s → 二次 ${T2}s"

echo "PASS"
