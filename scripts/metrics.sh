#!/bin/bash
# 分层性能指标采集 —— 只依赖两个已有数据源,不引入任何新组件:
#   1) 各 Squid 的 access.log      (命中/字节/客户端/bump-splice)
#   2) HAProxy stats CSV (:8404)   (后端分发/健康状态)
#   3) cgroup cpu.stat             (CPU 秒,用于算每 GB 的 CPU 成本)
#
# 用法:
#   ./scripts/metrics.sh begin     # 打基线
#   <跑你的负载>
#   ./scripts/metrics.sh end       # 输出这段区间的分层指标
#   ./scripts/metrics.sh now       # 不打基线,直接看累计值
#
# 为什么要按区间而不是看累计: 累计值会把预热、健康检查、历史负载混在一起,
# 得出的命中率和 CPU/GB 都没有意义。必须框定一个已知负载的窗口。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"
STATE="$ROOT/.metrics-state"
SQUIDS="squid1 squid2 squid3"

# access.log 字段(squid 格式):
#   $1 时间戳  $2 耗时ms  $3 客户端  $4 结果码/状态  $5 字节
#   $6 方法    $7 URL     $8 ident   $9 层级/对端    $10 类型
#
# $6 == "-" 的是 HAProxy 健康检查(NONE_NONE/400),必须剔除:
# 每 3 秒 × 3 后端 × 2 节点,不滤掉会把请求数和命中率彻底冲淡。
AWK_AGG='
$6 == "-" { next }          # HAProxy 健康检查
{ cli[$3] += $5; clir[$3]++ }

# CONNECT 行是隧道记录,不是可缓存对象,必须单独统计:
#   bump  : NONE_NONE/200 bytes=0 —— 只是建隧道,真正的负载会作为解密后的
#           GET https://... 再记一行。混进 req 会凭空翻倍请求数并稀释命中率。
#   splice: TCP_TUNNEL/... 带真实字节 —— 未解密直通,Squid 看不到内容,不可能命中。
$6 == "CONNECT" {
    tunnel++
    if ($4 ~ /^TCP_TUNNEL/) { splice++; sbytes += $5 }
    else                     { bumped++ }
    next
}

# 以下只统计可缓存的对象请求
{
    req++; bytes += $5
    if ($4 ~ /TCP_(MEM_)?HIT/)             { hit++;  hitb += $5 }
    else if ($4 ~ /TCP_(REFRESH|IMS)_HIT/) { rhit++; hitb += $5 }
    else                                    { miss++; missb += $5 }
}
END {
    printf "req=%d hit=%d rhit=%d miss=%d bytes=%d hitb=%d missb=%d bumped=%d splice=%d sbytes=%d tunnel=%d\n",
           req, hit, rhit, miss, bytes, hitb, missb, bumped, splice, sbytes, tunnel
    for (c in cli) printf "CLIENT %s %d %d\n", c, clir[c], cli[c]
}'

cpu_usec() { docker exec "$1" sh -c 'awk "/^usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null || echo 0; }
log_lines() { docker exec "$1" sh -c 'wc -l < /var/log/squid/access.log' 2>/dev/null | tr -d ' ' || echo 0; }

vip_holder() {
    for n in haproxy-node1 haproxy-node2; do
        docker exec "$n" ip -4 addr show eth0 2>/dev/null | grep -q 172.30.0.100 && { echo "$n"; return; }
    done
    echo haproxy-node1
}

do_begin() {
    : > "$STATE"
    for s in $SQUIDS; do echo "$s $(log_lines "$s") $(cpu_usec "$s")" >> "$STATE"; done
    echo "TS $(date +%s)" >> "$STATE"
    echo "基线已记录 ($STATE)。跑完负载后执行: ./scripts/metrics.sh end"
}

# 汇总区间内的 access.log。$1=起始行(0 表示全部)
collect() {
    local mode="$1"
    for s in $SQUIDS; do
        local from=0
        [ "$mode" = "delta" ] && from=$(awk -v s="$s" '$1==s{print $2}' "$STATE" 2>/dev/null)
        from=${from:-0}
        docker exec "$s" sh -c "tail -n +$((from + 1)) /var/log/squid/access.log" 2>/dev/null
    done | awk "$AWK_AGG"
}

report() {
    local mode="$1" out
    out=$(collect "$mode")
    local agg; agg=$(echo "$out" | grep -v '^CLIENT ')
    eval "$(echo "$agg" | tr ' ' '\n' | sed 's/^/M_/')" 2>/dev/null

    local cpu_s=0 elapsed=0
    for s in $SQUIDS; do
        local now_us base_us=0
        now_us=$(cpu_usec "$s")
        [ "$mode" = "delta" ] && base_us=$(awk -v s="$s" '$1==s{print $3}' "$STATE" 2>/dev/null)
        cpu_s=$(awk -v a="$cpu_s" -v n="${now_us:-0}" -v b="${base_us:-0}" 'BEGIN{printf "%.3f", a+(n-b)/1000000}')
    done
    if [ "$mode" = "delta" ]; then
        local t0; t0=$(awk '$1=="TS"{print $2}' "$STATE")
        elapsed=$(( $(date +%s) - ${t0:-0} ))
    fi

    local req=${M_req:-0} hit=${M_hit:-0} rhit=${M_rhit:-0} miss=${M_miss:-0}
    local bytes=${M_bytes:-0} hitb=${M_hitb:-0} missb=${M_missb:-0}
    local bumped=${M_bumped:-0} splice=${M_splice:-0} sbytes=${M_sbytes:-0} tunnel=${M_tunnel:-0}

    echo "============================================"
    echo "  分层性能指标  ($([ "$mode" = delta ] && echo "区间 ${elapsed}s" || echo "累计"))"
    echo "============================================"

    echo ""
    echo "── Squid 层: 缓存效果 (只统计可缓存对象请求) ──"
    if [ "$req" -eq 0 ]; then
        echo "  (区间内没有对象请求; 健康检查与 CONNECT 隧道已剔除)"
    else
        awk -v r="$req" -v h="$hit" -v rh="$rhit" -v m="$miss" -v b="$bytes" -v hb="$hitb" -v mb="$missb" 'BEGIN{
            printf "  请求数        %d  (HIT %d / REFRESH_HIT %d / MISS %d)\n", r, h, rh, m
            printf "  请求命中率    %.1f%%\n", (h+rh)*100/r
            printf "  字节命中率    %.1f%%   ← 省下的出向带宽看这个\n", (b>0? hb*100/b : 0)
            printf "  服务字节      %.2f GB\n", b/1073741824
            printf "  回源字节      %.2f GB\n", mb/1073741824
            printf "  省下回源      %.2f GB\n", hb/1073741824
        }'
    fi

    echo ""
    echo "── SSL Bump 层: CPU 成本 ──"
    awk -v b="$bumped" -v sp="$splice" -v sb="$sbytes" -v t="$tunnel" 'BEGIN{
        printf "  隧道 %d 条: 解密(bump) %d / 直通(splice) %d", t, b, sp
        if (sp > 0) printf "  直通字节 %.2f GB(不可能命中)", sb/1073741824
        printf "\n"
    }'
    awk -v c="$cpu_s" -v b="$bytes" 'BEGIN{
        printf "  CPU 合计      %.2f 秒 (三副本)\n", c
        if (b > 0) printf "  每 GB CPU     %.2f 秒/GB   ← 容量推导的关键系数\n", c/(b/1073741824)
        else       printf "  每 GB CPU     n/a (无流量)\n"
    }'
    echo "  注意: 纯 HIT 场景 CPU 高于纯 MISS(命中要重新做 TLS 加密,回源只是等 I/O)。"
    echo "        要拿到可用的系数,请分别跑「纯 HIT」与「纯 MISS」两个窗口再比较。"

    echo ""
    echo "── HAProxy 层: 分发与健康 ──"
    local node; node=$(vip_holder)
    echo "  VIP 持有者: $node"
    docker exec "$node" curl -s 'http://127.0.0.1:8404/stats;csv' 2>/dev/null \
        | awk -F, '$1=="squid_pool" && $2 ~ /^s[0-9]+$/ {
              printf "  %-4s 状态=%-5s 累计会话=%-8s 检查失败=%-4s 不可用秒=%s\n", $2, $18, $8, $22, $24 }'

    echo ""
    echo "── 归因层: 客户端分布 (需要 PROXY protocol) ──"
    echo "$out" | grep '^CLIENT ' | sort -k4 -rn | head -8 | awk '{
        printf "  %-16s 请求 %-6s 字节 %.2f MB\n", $2, $3, $4/1048576 }'
    echo "$out" | grep -q '^CLIENT 172\.30\.0\.2[12] ' && \
        echo "  ⚠ 客户端仍显示为 HAProxy 节点 —— PROXY protocol 未生效,归因不可用"
    echo ""
}

case "${1:-now}" in
    begin) do_begin ;;
    end)   [ -f "$STATE" ] || { echo "没有基线,先跑 ./scripts/metrics.sh begin"; exit 1; }; report delta ;;
    now)   report full ;;
    *)     echo "用法: $0 {begin|end|now}"; exit 1 ;;
esac
