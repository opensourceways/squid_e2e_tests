#!/bin/bash
# pipefail: 没有它时 `docker compose build | tail -3` 的失败会被 tail 的成功掩盖,
# set -e 看到的是 0,脚本继续往下走 up -d,最后以一堆无关报错收场。
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

echo "=== Squid HA 环境初始化 ==="

# 生成 CA 证书
if [ ! -f configs/certs/squid-ca.pem ]; then
    echo "生成 SSL Bump CA 证书..."
    # 目录必须先建: certs/ 内容全被 .gitignore 忽略,git 不跟踪空目录,
    # 所以新 clone 下来根本没有 configs/certs/,openssl 会直接失败。
    mkdir -p configs/certs
    # 不要 2>/dev/null: 之前 openssl 的报错被吞掉,set -e 让脚本静默退出,毫无线索
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -keyout configs/certs/squid-ca-key.pem \
      -out configs/certs/squid-ca-cert.pem \
      -subj "/CN=Squid-HA-Test-CA"
    cat configs/certs/squid-ca-cert.pem configs/certs/squid-ca-key.pem > configs/certs/squid-ca.pem
    cp configs/certs/squid-ca-cert.pem configs/certs/client-ca.crt
    chmod 600 configs/certs/squid-ca-key.pem configs/certs/squid-ca.pem
    echo "CA 证书已生成: configs/certs/"
fi

echo "构建镜像..."
docker compose build 2>&1 | tail -3

echo "启动容器..."
docker compose down -v --timeout 3 2>/dev/null
docker compose up -d

echo "等待服务就绪..."
sleep 18

echo ""
echo "=== 状态 ==="
docker compose ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "验证 VIP:"
docker exec haproxy-node1 ip addr show eth0 | grep 172.30.0.100 && echo "  VIP 在 node1" || echo "  VIP 不在 node1 (可能在 node2)"
echo ""
echo "环境就绪。运行 './scripts/test-all.sh' 开始测试。"
