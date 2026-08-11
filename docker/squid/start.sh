#!/bin/bash
set -e
tail -F /var/log/squid/access.log 2>/dev/null &
tail -F /var/log/squid/cache.log 2>/dev/null &

# 初始化 SSL 证书数据库(proxy 用户,首次或重启均重建)
rm -rf /var/spool/squid/ssl_db
su -s /bin/sh proxy -c "/usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB"

# 初始化/校验 swap 目录。
# 注意: 重启时缓存已有内容,squid -z 可能返回非零(缓存重建警告),
#       必须 || true 兜底,否则 set -e 会在 exec squid 之前杀掉脚本。
squid -z -f /etc/squid/squid.conf 2>/dev/null || true
mkdir -p /var/spool/squid/0{0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F}
chown -R proxy:proxy /var/spool/squid/0* /var/spool/squid/ssl_db
rm -f /run/squid.pid

exec squid -f /etc/squid/squid.conf -Nd 1
