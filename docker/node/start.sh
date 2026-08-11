#!/bin/bash
set -e
echo "=== $(hostname) starting ==="
rm -f /run/keepalived.pid /run/vrrp.pid

# 顺序: 先 HAProxy,再 keepalived。原先反过来(keepalived 先起 + sleep 5),有两个问题:
#   1. keepalived 的 track_script 在 haproxy 存在之前就跑,首次必然失败并降优先级
#      (实测日志: VRRP_Script(chk_haproxy) failed → Changing effective priority 90 to 80)
#   2. VIP 可能落到一个还没监听 3128 的节点上,客户端此时连 VIP 直接被拒
# -db = 前台运行且不 daemonize。原先的 -d 是 *debug* 模式,会逐连接刷日志。
haproxy -db -f /etc/haproxy/haproxy.cfg &
HAPROXY_PID=$!

# 轮询就绪,而不是固定 sleep
for _ in $(seq 1 60); do
    ss -ltn 2>/dev/null | grep -q ':3128 ' && break
    kill -0 "$HAPROXY_PID" 2>/dev/null || { echo "FATAL: haproxy 启动过程中退出"; exit 1; }
    sleep 0.5
done
ss -ltn 2>/dev/null | grep -q ':3128 ' || { echo "FATAL: haproxy 30s 内未监听 3128"; exit 1; }
echo "haproxy 已监听 :3128"

echo "Node ready, IPs:"; ip addr show eth0 | grep inet

# keepalived 作为 PID 1: haproxy 挂掉时容器不退出,由 track_script 降优先级触发 VIP 漂移
# —— 这正是 chk_haproxy 存在的意义。(原先 haproxy 是 PID 1,它一死容器就没了,
#    track_script 永远没有用武之地。)
exec keepalived --dont-fork --log-console --log-detail
