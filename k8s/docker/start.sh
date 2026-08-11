#!/bin/bash
# K8s 版启动脚本 —— 持久化缓存(StatefulSet PVC),不清空 swap 目录
set -e

CACHE_DIR=/var/spool/squid

# 日志目录(proxy 可写) + 转发到容器 stdout/stderr 供 K8s 采集
mkdir -p /var/log/squid
chown -R proxy:proxy /var/log/squid
touch /var/log/squid/access.log /var/log/squid/cache.log
chown proxy:proxy /var/log/squid/access.log /var/log/squid/cache.log
tail -F /var/log/squid/access.log 2>/dev/null &
tail -F /var/log/squid/cache.log  2>/dev/null &

# SSL 证书数据库: 每次重建(仅为动态证书 cache,可安全重建)
rm -rf "$CACHE_DIR/ssl_db"
su -s /bin/sh proxy -c "/usr/lib/squid/security_file_certgen -c -s $CACHE_DIR/ssl_db -M 4MB"

# swap 目录: 首次创建;已存在则保留(缓存跨重启持久)
# squid -z 幂等,已有缓存时重建索引(swap.state),大缓存可能耗时→startupProbe 覆盖
if [ ! -d "$CACHE_DIR/00" ]; then
    echo "首次启动: 初始化 swap 目录"
    squid -z -f /etc/squid/squid.conf 2>/dev/null || true
    mkdir -p "$CACHE_DIR"/0{0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F}
else
    echo "复用已有缓存: 重建 swap.state 索引"
    squid -z -f /etc/squid/squid.conf 2>/dev/null || true
fi
chown -R proxy:proxy "$CACHE_DIR"/0* "$CACHE_DIR/ssl_db" 2>/dev/null || true
rm -f /run/squid.pid

# 前台运行(日志已在 squid.conf 配到 stdout/stderr)
exec squid -f /etc/squid/squid.conf -Nd 1
