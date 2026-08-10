#!/bin/bash
set -e
echo "=== $(hostname) starting ==="
rm -f /run/keepalived.pid /run/vrrp.pid
keepalived --dont-fork --log-console --log-detail &
sleep 5
echo "Node ready, IPs:"; ip addr show eth0 | grep inet
exec haproxy -d -f /etc/haproxy/haproxy.cfg
