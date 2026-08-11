#!/bin/bash
# 部署 Squid 到 Kubernetes(测试规格 N=20, R=1, StatefulSet 持久缓存)
# 前置: kubectl 已配置 kubeconfig 指向目标测试集群
set -e
K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$K8S_DIR")"
CERT_DIR="$REPO_ROOT/configs/certs"
NS=test-husheng

echo "=== 1. 准备 SSL Bump CA 证书 ==="
if [ ! -f "$CERT_DIR/squid-ca.pem" ]; then
    echo "生成 CA..."
    mkdir -p "$CERT_DIR"
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout "$CERT_DIR/squid-ca-key.pem" \
        -out "$CERT_DIR/squid-ca-cert.pem" \
        -subj "/CN=Squid-K8s-Test-CA" 2>/dev/null
    cat "$CERT_DIR/squid-ca-cert.pem" "$CERT_DIR/squid-ca-key.pem" > "$CERT_DIR/squid-ca.pem"
    cp "$CERT_DIR/squid-ca-cert.pem" "$CERT_DIR/client-ca.crt"
fi

# namespace test-husheng 已存在(由集群管理员创建, SA 权限绑定于此)
echo "=== 2. 确认 namespace test-husheng 可用 ==="
kubectl get ns "$NS" >/dev/null 2>&1 && echo "  ns $NS OK" || { echo "  ns $NS 不可用"; exit 1; }

echo "=== 3. 创建 CA Secret(squid-ca.pem 供 SSL Bump) ==="
kubectl -n "$NS" create secret generic squid-ca \
    --from-file=squid-ca.pem="$CERT_DIR/squid-ca.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "=== 4. 应用 ConfigMap / Service / StatefulSet ==="
kubectl apply -f "$K8S_DIR/manifests/01-configmap.yaml"
kubectl apply -f "$K8S_DIR/manifests/02-service.yaml"
kubectl apply -f "$K8S_DIR/manifests/03-statefulset.yaml"

echo "=== 5. 等待就绪 ==="
kubectl -n "$NS" rollout status statefulset/squid --timeout=300s

echo ""
echo "=== 状态 ==="
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get pvc
echo ""
echo "部署完成。运行 ./test.sh 验证。"
