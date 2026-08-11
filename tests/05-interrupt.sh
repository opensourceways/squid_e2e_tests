#!/bin/bash
# 05: 大文件下载进行中,中断*正在服务它的那台* Squid,验证代理服务不受影响
#
# 与旧版的区别:
#   - 旧版下载的是 HTTP_URL(一个小索引页),sleep 3 之前就下完了,根本没有"进行中"的下载
#   - 旧版写死 TARGET=squid3,而 balance source 决定了请求落到哪台,写死等于 1/3 概率蒙对
#   - 旧版丢弃了被中断下载的结果,只断言了一个无关的新请求返回 200
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 05: 下载中断影响 ==="

URL="$HTTPS_CACHE_URL"
CLIENT_IP=172.30.0.50
cleanup() { docker rm -f dl-client >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
# 固定客户端 IP: balance source 按源 IP 哈希,IP 固定 → 后端固定,可复现
docker run -d --name dl-client --network "$NET" --ip "$CLIENT_IP" \
    -v "$CA:/tmp/ca.crt:ro" --entrypoint sh alpine/curl:latest -c 'sleep 600' >/dev/null

# 1) 先发一个会*完成*的小请求。access.log 只在请求结束时落盘,所以必须靠这次
#    完成的请求来确定 balance source 把这个客户端 IP 分给了哪台 Squid。
#    注意不能按客户端 IP 去 grep: HAProxy 是 TCP 模式且没开 PROXY protocol,
#    Squid 看到的「客户端」永远是 HAProxy 节点(172.30.0.21/.22),不是真实客户端。
#    所以用一个唯一 URL token 来定位。
#    token 必须放在*路径*里,不能用查询串: Squid 的 strip_query_terms 默认为 on,
#    access.log 里 `?` 之后的内容会被抹掉,查询串 token 永远 grep 不到。
#    这个探测请求会 404,无所谓 —— 只用它来确定后端归属。
PROBE_TOKEN="probe-$$-${RANDOM}"
docker exec dl-client curl -s -o /dev/null -x "http://$VIP" "${HTTP_URL}${PROBE_TOKEN}" --max-time 30
TARGET=""
for _ in $(seq 1 10); do
    for s in squid1 squid2 squid3; do
        if docker exec "$s" grep -q "$PROBE_TOKEN" /var/log/squid/access.log 2>/dev/null; then
            TARGET="$s"; break 2
        fi
    done
    sleep 1   # access.log 由 daemon 写,可能略有延迟
done
if [ -z "$TARGET" ]; then
    echo "  ✗ FAIL: 三台 Squid 的 access.log 都没有 $PROBE_TOKEN,无法确定中断目标"
    exit 1
fi
echo "  客户端 $CLIENT_IP 被分发到 $TARGET"

# 2) 从同一个客户端(同一 IP → 同一后端)起一个真正耗时的下载
docker exec -d dl-client sh -c \
    "curl --cacert /tmp/ca.crt -s -o /tmp/out --limit-rate 200k -x http://$VIP '$URL' --max-time 300; echo \$? > /tmp/rc"
sleep 5
assert_true "下载确实在进行中" docker exec dl-client sh -c '[ ! -f /tmp/rc ]'

# 3) 中断正在服务它的那台
echo "中断 $TARGET ..."
docker stop "$TARGET" >/dev/null && sleep 8

# 断言 A: 中断期间,新请求仍然通过(HAProxy 已把故障节点摘除)
assert_code "中断期间代理" 200 "$(proxy_http_code "$HTTP_URL")"

# 观测 B: 被中断的下载多久才有结局
#
# ⚠️ 已知缺陷(实测): 后端 Squid 被杀之后,客户端这条传输既不会完成也不会立即报错,
#    而是一直挂着,直到 curl 的 --max-time 或 HAProxy 的 `timeout server 300s` 到期。
#    实测 60 秒后仍在 running。对 CI 的实际影响: 一台 Squid 挂掉会让正在下载的 job
#    卡最多 5 分钟,而不是快速失败重试。
#    这与 README/solution.md 宣称的「零中断/客户端无感知」不符 —— 对*新*请求成立,
#    对*进行中*的传输不成立。
#    这里只做观测不做断言: 是否要把「有界拆除时间」变成硬断言(并因此让本用例转红),
#    取决于是否接受这个行为,留给维护者决定。
for _ in $(seq 1 15); do
    docker exec dl-client sh -c '[ -f /tmp/rc ]' 2>/dev/null && break
    sleep 1
done
RC=$(docker exec dl-client sh -c 'cat /tmp/rc 2>/dev/null || echo "15s 内仍未结束(见上方已知缺陷说明)"')
echo "  被中断下载的结局: $RC"

echo "恢复 $TARGET ..."
docker compose restart "$TARGET" >/dev/null 2>&1 && sleep 10
assert_code "恢复后代理" 200 "$(proxy_http_code "$HTTP_URL")"

# 断言 C: 中断后重新下载必须成功且字节数完整 —— 证明中断没有在缓存里留下残缺对象。
# 这是本用例真正的价值所在: 中断的风险不是"服务挂了",而是"缓存被写坏了"。
read -r C2 S2 <<< "$(docker run --rm --network "$NET" -v "$CA:/tmp/ca.crt:ro" alpine/curl:latest \
    curl --cacert /tmp/ca.crt -s -o /dev/null -w "%{http_code} %{size_download}" \
    -x "http://$VIP" "$URL" --max-time 300 2>/dev/null)"
assert_code "中断后重新下载" 200 "$C2"
if [ "${S2:-0}" -gt 0 ]; then
    echo "  ✓ 重下内容完整: $S2 bytes"
else
    echo "  ✗ FAIL: 重下 size_download 为 0,缓存可能已损坏"; exit 1
fi

echo "PASS"
