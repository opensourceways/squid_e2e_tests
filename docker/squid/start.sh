#!/bin/bash
set -e
tail -F /var/log/squid/access.log 2>/dev/null &
tail -F /var/log/squid/cache.log 2>/dev/null &
rm -rf /var/spool/squid/ssl_db
su -s /bin/sh proxy -c "/usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB"
squid -z -f /etc/squid/squid.conf 2>/dev/null
mkdir -p /var/spool/squid/0{0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F}
chown -R proxy:proxy /var/spool/squid/0*
rm -f /run/squid.pid
exec squid -f /etc/squid/squid.conf -Nd 1
