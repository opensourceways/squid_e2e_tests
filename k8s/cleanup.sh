#!/bin/bash
# 清理 K8s Squid 部署
NS=test-husheng
KEEP_PVC="${1:-}"   # 传 --keep-pvc 保留缓存卷

kubectl -n "$NS" delete job -l app=squid-client 2>/dev/null
kubectl delete -f "$(dirname "$0")/manifests/03-statefulset.yaml" 2>/dev/null
kubectl delete -f "$(dirname "$0")/manifests/02-service.yaml" 2>/dev/null
kubectl delete -f "$(dirname "$0")/manifests/01-configmap.yaml" 2>/dev/null
kubectl -n "$NS" delete secret squid-ca 2>/dev/null

# StatefulSet 的 PVC 不随 delete 自动回收, 需显式删
if [ "$KEEP_PVC" = "--keep-pvc" ]; then
    echo "保留 PVC(缓存卷)"
else
    kubectl -n "$NS" delete pvc -l app=squid-cache 2>/dev/null
    # 共享 namespace(test-husheng), 不删 ns
fi
echo "清理完成"
