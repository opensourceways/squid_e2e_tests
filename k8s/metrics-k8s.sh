#!/bin/bash
# 分层性能指标(K8s 版)—— 与 scripts/metrics.sh 同口径, 数据源换成 K8s:
#   1) 各 squid pod 的 access.log   (kubectl exec ... cat)   命中/字节/客户端/延迟/错误/bump-splice
#   2) cgroup v1 cpuacct.usage       (kubectl exec)          CPU 秒, 用于两项 CPU 成本
#   3) endpoints / ready pods                                取代 Compose 侧的 HAProxy stats
#
# 与 Compose 版的差异:
#   - 没有 HAProxy/VIP。负载均衡是 Service(sessionAffinity: ClientIP, 等价 balance source)。
#   - cgroup 是 v1(cpuacct.usage 纳秒), 不是 v2 的 cpu.stat usage_usec。
#   - K8s Service 不像 HAProxy TCP 模式那样隐藏源 IP, 归因层通常直接可用(显示真实客户端 pod IP)。
#
# 用法:
#   NS=test-husheng ./k8s/metrics-k8s.sh baseline [秒]
#   NS=test-husheng ./k8s/metrics-k8s.sh begin
#   <跑负载>
#   NS=test-husheng ./k8s/metrics-k8s.sh end
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
NS="${NS:-test-husheng}"
STATE="$ROOT/.metrics-k8s-state"
BASELINE_FILE="$ROOT/.metrics-k8s-baseline"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

squids() { kubectl -n "$NS" get pods -l app=squid-cache --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }
SQUIDS=$(squids)

# 与 scripts/metrics.sh 完全相同的口径(健康检查剔除 / CONNECT 隧道去重 / HIER 错误分类)
AWK_AGG='
$6 == "-" { next }
{ cli[$3] += $5; clir[$3]++ }
$6 == "CONNECT" {
    tunnel++; split($4, t, "/"); if (t[2]+0 >= 400) tunfail++
    if ($4 ~ /^TCP_TUNNEL/) { splice++; sbytes += $5 } else { bumped++ }
    next
}
{
    req++; bytes += $5
    if ($4 ~ /TCP_(MEM_)?HIT/)             { hit++;  hitb += $5 }
    else if ($4 ~ /TCP_(REFRESH|IMS)_HIT/) { rhit++; hitb += $5 }
    else                                    { miss++; missb += $5 }
    split($4, a, "/"); st = a[2] + 0
    if ($4 ~ /ABORTED/)         aborted++
    else if (st < 400)          ok++
    else if ($9 ~ /^HIER_NONE/) proxyerr++
    else if (st >= 500)         origin5++
    else                        origin4++
}
END {
    printf "req=%d hit=%d rhit=%d miss=%d bytes=%d hitb=%d missb=%d bumped=%d splice=%d sbytes=%d tunnel=%d tunfail=%d ok=%d origin4=%d origin5=%d proxyerr=%d aborted=%d\n",
           req,hit,rhit,miss,bytes,hitb,missb,bumped,splice,sbytes,tunnel,tunfail,ok,origin4,origin5,proxyerr,aborted
    for (c in cli) printf "CLIENT %s %d %d\n", c, clir[c], cli[c]
}'

# cgroup v1: cpuacct.usage 是纳秒累计
cpu_ns()    { kubectl -n "$NS" exec "$1" -- cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null || echo 0; }
log_lines() { kubectl -n "$NS" exec "$1" -- sh -c 'wc -l < /var/log/squid/access.log' 2>/dev/null | tr -d ' ' || echo 0; }

do_begin() {
    : > "$STATE"
    for s in $SQUIDS; do echo "$s $(log_lines "$s") $(cpu_ns "$s")" >> "$STATE"; done
    echo "TS $(date +%s)" >> "$STATE"
    echo "基线已记录 ($STATE)。跑完负载后: NS=$NS $0 end"
    [ -f "$BASELINE_FILE" ] || echo "提示: 尚未测空闲基线, CPU 归因会偏高。先跑一次 baseline"
}

do_baseline() {
    local secs=${1:-30} a=0 b=0
    echo "测量空闲基线 ${secs}s (pods: $(echo $SQUIDS | tr '\n' ' ')) —— 请勿在此期间加负载 ..."
    for s in $SQUIDS; do a=$(awk -v x="$a" -v y="$(cpu_ns "$s")" 'BEGIN{print x+y}'); done
    sleep "$secs"
    for s in $SQUIDS; do b=$(awk -v x="$b" -v y="$(cpu_ns "$s")" 'BEGIN{print x+y}'); done
    awk -v a="$a" -v b="$b" -v t="$secs" 'BEGIN{printf "%.6f\n", (b-a)/1e9/t}' > "$BASELINE_FILE"
    echo "空闲基线: $(cat "$BASELINE_FILE") CPU秒/秒 (合计 $(echo $SQUIDS | wc -w | tr -d ' ') 副本) → $BASELINE_FILE"
}

fetch_window() {
    local mode="$1"; : > "$WORK/log"
    for s in $SQUIDS; do
        local from=0
        [ "$mode" = "delta" ] && from=$(awk -v s="$s" '$1==s{print $2}' "$STATE" 2>/dev/null)
        from=${from:-0}
        kubectl -n "$NS" exec "$s" -- sh -c "tail -n +$((from + 1)) /var/log/squid/access.log" 2>/dev/null >> "$WORK/log"
    done
}

pct() {
    local f="$1" p="$2" n; n=$(wc -l < "$f" 2>/dev/null || echo 0); n=${n:-0}
    [ "$n" -eq 0 ] && { echo "n/a"; return; }
    sort -n "$f" | awk -v p="$p" -v n="$n" 'BEGIN{i=int(p*n/100); if(i<1)i=1} NR==i{printf "%d",$1; exit}'
}

report() {
    local mode="$1"; fetch_window "$mode"
    local out; out=$(awk "$AWK_AGG" "$WORK/log")
    eval "$(echo "$out" | grep -v '^CLIENT ' | tr ' ' '\n' | sed 's/^/M_/')" 2>/dev/null
    awk '$6 != "-" && $6 != "CONNECT" && $4 ~ /TCP_(MEM_)?HIT/ {print $2}' "$WORK/log" > "$WORK/lat_hit"
    awk '$6 != "-" && $6 != "CONNECT" && $4 !~ /TCP_(MEM_|REFRESH_|IMS_)?HIT/ {print $2}' "$WORK/log" > "$WORK/lat_miss"

    local cpu_s=0 elapsed=0
    for s in $SQUIDS; do
        local now b=0; now=$(cpu_ns "$s")
        [ "$mode" = "delta" ] && b=$(awk -v s="$s" '$1==s{print $3}' "$STATE" 2>/dev/null)
        cpu_s=$(awk -v a="$cpu_s" -v n="${now:-0}" -v bb="${b:-0}" 'BEGIN{printf "%.3f", a+(n-bb)/1e9}')
    done
    [ "$mode" = "delta" ] && { local t0; t0=$(awk '$1=="TS"{print $2}' "$STATE"); elapsed=$(( $(date +%s) - ${t0:-0} )); }

    local req=${M_req:-0} hit=${M_hit:-0} rhit=${M_rhit:-0} miss=${M_miss:-0}
    local bytes=${M_bytes:-0} hitb=${M_hitb:-0} missb=${M_missb:-0}
    local bumped=${M_bumped:-0} splice=${M_splice:-0} sbytes=${M_sbytes:-0}
    local tunnel=${M_tunnel:-0} tunfail=${M_tunfail:-0}
    local ok=${M_ok:-0} origin4=${M_origin4:-0} origin5=${M_origin5:-0} proxyerr=${M_proxyerr:-0} aborted=${M_aborted:-0}

    echo "============================================"
    echo "  分层性能指标 · K8s ($([ "$mode" = delta ] && echo "区间 ${elapsed}s" || echo 累计)) ns=$NS"
    echo "============================================"
    echo ""
    echo "── Squid 层: 缓存效果 (只统计可缓存对象请求) ──"
    if [ "$req" -eq 0 ]; then echo "  (区间内没有对象请求; 健康检查与 CONNECT 隧道已剔除)"; else
        awk -v r="$req" -v h="$hit" -v rh="$rhit" -v m="$miss" -v b="$bytes" -v hb="$hitb" -v mb="$missb" 'BEGIN{
            printf "  请求数        %d  (HIT %d / REFRESH_HIT %d / MISS %d)\n", r,h,rh,m
            printf "  请求命中率    %.1f%%\n", (h+rh)*100/r
            printf "  字节命中率    %.1f%%   ← 省下的出向带宽看这个\n", (b>0? hb*100/b:0)
            printf "  服务字节      %.2f GB   回源 %.2f GB   省下 %.2f GB\n", b/1073741824, mb/1073741824, hb/1073741824 }'
    fi
    echo ""
    echo "── 延迟层: 按命中结果分位 (毫秒) ──"
    printf "  %-6s n=%-6s p50=%-8s p95=%-8s p99=%s\n" HIT \
        "$(wc -l < "$WORK/lat_hit" | tr -d ' ')" "$(pct "$WORK/lat_hit" 50)" "$(pct "$WORK/lat_hit" 95)" "$(pct "$WORK/lat_hit" 99)"
    printf "  %-6s n=%-6s p50=%-8s p95=%-8s p99=%s\n" MISS \
        "$(wc -l < "$WORK/lat_miss" | tr -d ' ')" "$(pct "$WORK/lat_miss" 50)" "$(pct "$WORK/lat_miss" 95)" "$(pct "$WORK/lat_miss" 99)"
    echo "  看均值会被长尾骗过去 —— 对在线业务 p99 才是用户实际感受。"
    echo ""
    echo "── 错误层: 代理故障 vs 源站故障 ──"
    printf "  成功(2xx/3xx) %-6s 源站4xx %-6s 源站5xx %-6s 代理故障 %-6s 客户端中断 %s\n" "$ok" "$origin4" "$origin5" "$proxyerr" "$aborted"
    [ "$tunfail" -gt 0 ] && echo "  隧道失败      $tunfail"
    echo "  「代理故障」才是要告警的(HIER_NONE 且 >=400: DNS/连接失败/ACL 拒绝); 源站4xx多为正常。"
    echo ""
    echo "── SSL Bump 层: CPU 成本 (两项模型) ──"
    awk -v b="$bumped" -v sp="$splice" -v sb="$sbytes" -v t="$tunnel" 'BEGIN{
        printf "  隧道 %d 条: 解密(bump) %d / 直通(splice) %d", t,b,sp
        if (sp>0) printf "  直通字节 %.2f GB", sb/1073741824; printf "\n" }'
    local br=0; [ -f "$BASELINE_FILE" ] && br=$(cat "$BASELINE_FILE" 2>/dev/null || echo 0)
    awk -v c="$cpu_s" -v br="${br:-0}" -v e="$elapsed" -v b="$bytes" -v r="$req" -v hasb="$([ -f "$BASELINE_FILE" ] && echo 1 || echo 0)" 'BEGIN{
        idle=br*e; attr=c-idle; if(attr<0)attr=0
        if(hasb) printf "  CPU 原始 %.2f 秒 − 空闲基线 %.2f 秒 = 归因 %.2f 秒\n", c, idle, attr
        else     printf "  CPU 原始 %.2f 秒 (未扣空闲基线, 偏高)\n", c
        if(r>0){ printf "  平均对象      %.2f MB\n", (b/r)/1048576
                 printf "  每请求 CPU    %.4f 秒/请求   ← 固定成本: TLS握手+证书生成+查找\n", attr/r }
        if(b>0)  printf "  每 GB CPU     %.2f 秒/GB      ← 边际成本: 加密+I/O\n", attr/(b/1073741824) }'
    echo "  ⚠ 每GB CPU 非常数(随对象大小漂移); 低并发测不出「HIT比MISS更吃CPU」(见 reports/stress-benchmark-20260811.md)。"
    echo ""
    echo "── 后端层: 就绪副本 (取代 Compose 的 HAProxy stats) ──"
    kubectl -n "$NS" get endpoints squid -o jsonpath='{range .subsets[*].addresses[*]}  就绪端点 {.ip}{"\n"}{end}' 2>/dev/null
    kubectl -n "$NS" get pods -l app=squid-cache -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase --no-headers 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "── 归因层: 客户端分布 (K8s Service 保留源 IP, 无需 PROXY protocol) ──"
    echo "$out" | grep '^CLIENT ' | sort -k4 -rn | head -8 | awk '{printf "  %-16s 请求 %-6s 字节 %.2f MB\n", $2,$3,$4/1048576}'
    echo ""
}

case "${1:-now}" in
    baseline) do_baseline "${2:-30}" ;;
    begin)    do_begin ;;
    end)      [ -f "$STATE" ] || { echo "先跑 begin"; exit 1; }; report delta ;;
    now)      report full ;;
    *)        echo "用法: NS=$NS $0 {baseline [秒]|begin|end|now}"; exit 1 ;;
esac
