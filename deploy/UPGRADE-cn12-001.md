# ascend-cn12-001 Squid 替换升级计划

> 状态：**已执行**（2026-08-31，replicas=2 双活；指纹已按实测修正为 73:71:2A:54）
> 目标：用新架构 StatefulSet 替换旧 squid（squid-openssl chart / squid 7.6），缓存扩到 200G，CA 换成 Vault 生产 CA（保留 ConfigMap `squid-ca-cert`，只更新其内容为新 CA）。
> 配套 values：`deploy/values-cn12-001.yaml`

---

## 1. 现状勘察（2026-08-29 实测）

### 1.1 旧 squid（将被替换）

| 项 | 值 |
|----|----|
| Helm release | `squid` / chart `squid-openssl-0.1.0` / squid 7.6，ns=`squid` |
| 工作负载 | Deployment `squid-cache`，单副本（alpine 容器跑 squid 7.6 + rpardini registry-proxy），Pod 在 node 192.168.0.74（已 cordon） |
| Service | `squid-cache` ClusterIP `10.247.108.105:3128` |
| PVC | `squid-cache-pvc` 200Gi RWX + `registry-cache-pvc` 400Gi RWX（`sfsturbo-subpath-sc`） |

### 1.2 旧 CA（ConfigMap，将被替换）

- 旧 CA：`CN=SquidCacheCA-hk001`，指纹 `38:49:77...`（非 Vault 生产 CA）
- **ConfigMap `squid-ca-cert`**（key：`squid-ca.pem`）存在于 7 个命名空间：

  `ascend-gha-runners` / `ascend-gha-runners-gy006` / `buildkitd` / `squid` / `triton-ascend` / `vllm-ascend` / `vllm-project`

- 这些 ConfigMap 为手工创建、非 helm 管理（无 owner/label）。

### 1.3 旧 ConfigMap `squid-ca-cert` 的消费者（关键）

- **正在挂载（运行中）**：
  - `buildkitd`：StatefulSet `buildkitd-amd64-deployment`、`buildkitd-arm64-deployment`（各 3 副本，共 6 pod）
  - `vllm-ascend`：runner workflow pod（模板由外部 runner 控制器生成）
- **仅存在 CM、暂无运行 pod 挂载**：`ascend-gha-runners`、`ascend-gha-runners-gy006`、`triton-ascend`、`vllm-project`、`squid`

### 1.4 已就位的基础设施 / Secret

- secrets-manager CRD 已存在（`secretdefinitions.secrets-manager.tuenti.io`）
- 已存在 Secret：`squid/squid-ca`、`ascend-gha-runners-gy006/squid-ca-cert`（说明该 ns 已部分迁移到 Secret 形态）
- ⚠️ **当前集群还没有任何 `SecretDefinition squid-ca*`**，将由新 chart 安装时创建

### 1.5 替换后架构（新 chart）

- StatefulSet `squid-cache`：squid 7.7.1（SSL-Bump）+ registry-proxy + squid-exporter
- CA 从 Vault（`secrets/data/ascend/ci` 生产 `_prod` key，指纹 `73:71:2A:54`）经 SecretDefinition 同步
  - `squid` 命名空间：Secret `squid-ca`（`squid-ca-bundle.pem` + `squid-ca.pem`）
  - 每个 caNamespaces：Secret `squid-ca-cert`（`squid-ca.pem` + `squid-bazel-trust.jks`）
- 缓存：squidCache 200Gi + registryCache 200Gi（新 PVC，volumeClaimTemplates 无历史约束，size 直接生效）
- Service 同名 `squid-cache:3128` → **客户端 HTTP_PROXY 地址不变**

---

## 2. 目标

1. 用新架构 StatefulSet 替换旧 Deployment，缓存扩到 200G。
2. CA 切换到 Vault 生产 CA。
3. **把旧 ConfigMap `squid-ca-cert` 里的 CA 换成新的 Vault 生产 CA**（保留 ConfigMap，客户端挂载方式不变）。

---

## 3. 关键风险

- 新旧 CA 不同（`73:71:2A:54` vs `38:49:77`）：客户端信任库必须是**新 CA**，否则走代理的 TLS 握手会失败。
- ConfigMap 更新会同步到已挂载卷，但**运行中的进程不会自动刷新启动时读入的信任库** → 更新 CA 后需重启正在跑的消费者（buildkitd STS），短生命周期 job 新实例会自动读到新 CM。
- 新旧同名资源冲突（Deployment/STS `squid-cache`、Service `squid-cache`）：**先卸载旧 release**。
- 替换期间代理有短暂停机窗口（Service 重建），客户端需容忍重试。

---

## 4. 执行步骤

### Phase 0：准备

1. 确认 kubeconfig：`KC=~/.kube/ascend-cn12-001.yaml`。
2. **补齐 `values-cn12-001.yaml` 的 `secretDefinition.caNamespaces`** —— 把有旧 CM 但当前不在列表里的命名空间加进去：

   - 当前 caNamespaces：`squid, buildkitd, ascend-gha-runners, ascend-gha-runners-gy004, ascend-gha-runners-gy005, ascend-gha-runners-gy006, nv-action, ascend, ascend-pytorch`
   - **需新增：`triton-ascend`、`vllm-ascend`、`vllm-project`**
   - 目的：SecretDefinition 在这 3 个命名空间也同步出 Secret `squid-ca-cert`，供**挂载 Secret 的新注入负载**（新 vcjob / GHA runner）使用；挂 ConfigMap 的存量负载走 Phase 3 更新 CM 内容。两条路径都覆盖。
3. （可选）备份旧 CA 留档：

   ```bash
   kubectl --kubeconfig $KC -n buildkitd get cm squid-ca-cert -o yaml > /tmp/cn12-old-ca-backup.yaml
   ```

### Phase 1：停旧装新（切换代理服务）

```bash
# 1) 卸载旧 release（删除旧 Deployment squid-cache + 旧 Service + 旧 SecretDefinition）
helm uninstall squid -n squid --kubeconfig $KC

# 2) 删除旧 PVC（可选，保留可回滚；确认无需旧缓存后执行）
kubectl --kubeconfig $KC -n squid delete pvc squid-cache-pvc registry-cache-pvc

# 3) 安装新 chart（helm 直装，cn12-001 由 helm 管理、非 ArgoCD）
helm install squid ./chart -n squid -f values-cn12-001.yaml --kubeconfig $KC
```

预期产物：STS `squid-cache`、Service `squid-cache`(+headless)、SecretDefinition `squid-ca`（squid ns）+ 各 caNamespaces 的 `squid-ca-cert`。

验证：`kubectl --kubeconfig $KC -n squid get pods -l app=squid-cache` → Ready。

### Phase 2：验证新 CA 已从 Vault 同步（SecretDefinition → Secret）

```bash
# squid 命名空间的 bundle
kubectl --kubeconfig $KC -n squid get secret squid-ca
# 各 caNamespaces 的公钥 CA
kubectl --kubeconfig $KC -n buildkitd get secret squid-ca-cert
# 指纹校验（应为 Vault 生产 CA 73:71:2A:54...）
kubectl --kubeconfig $KC -n buildkitd get secret squid-ca-cert -o jsonpath='{.data.squid-ca\.pem}' | base64 -d | openssl x509 -noout -fingerprint
```

### Phase 3：把旧 ConfigMap `squid-ca-cert` 的 CA 换成新 CA（本计划重点步骤）★

> ConfigMap **保留不删**，只更新其 `data.squid-ca.pem` 为新 Vault 生产 CA；客户端挂载方式不变。
> 新 chart 安装后 `SecretDefinition` 会在 squid 命名空间同步出 Secret `squid-ca`（含 `squid-ca.pem` 公钥），新 CA 从这里取即可。

**3.1 获取新 CA 公钥（从同步出的 Secret 提取）**

```bash
kubectl --kubeconfig $KC -n squid get secret squid-ca -o jsonpath='{.data.squid-ca\.pem}'
# 校验指纹 = 73:71:2A:54...
kubectl --kubeconfig $KC -n squid get secret squid-ca -o jsonpath='{.data.squid-ca\.pem}' \
  | base64 -d | openssl x509 -noout -fingerprint -sha1
```

**3.2 更新 7 个命名空间 ConfigMap `squid-ca-cert` 的 `data.squid-ca.pem`**

> ⚠️ 实测：`ascend-gha-runners-gy006` 的 CM 是 **Liqo offload** 资源（labels `offloading.liqo.io/origin: gy006`），
> 由 Liqo reflector 从 gy006 集群回写管理，本地改会被覆盖——**跳过该 ns**（其信任链归 gy006 集群管）。
> 实际更新 6 个 cn12 本地命名空间：

```bash
NEW_CA_B64=$(kubectl --kubeconfig $KC -n squid get secret squid-ca -o jsonpath='{.data.squid-ca\.pem}')
for ns in ascend-gha-runners buildkitd squid triton-ascend vllm-ascend vllm-project; do
  kubectl --kubeconfig $KC -n "$ns" patch cm squid-ca-cert \
    --type merge -p "{\"data\":{\"squid-ca.pem\":\"$NEW_CA_B64\"}}"
done
```

（2026-08-31 已执行：6 个 CM 均更新为 73:71:2A:54，gy006 保持 Liqo 托管值不动。）

**3.3 让正在跑的消费者重新加载 CA**
   ConfigMap 更新会同步到已挂载卷，但进程启动时读入的信任库不会自动刷新 → 重启：

```bash
kubectl --kubeconfig $KC -n buildkitd rollout restart sts \
  buildkitd-amd64-deployment buildkitd-arm64-deployment
# vllm-ascend 的 runner workflow pod 为短生命周期：新 pod 自动读到新 CM，正在跑的按需重启
```

**3.4 验证**
   - ConfigMap 内容指纹为 `73:71:2A:54`；
   - 走代理 `curl -x http://squid-cache.squid:3128 https://pypi.org/simple/` 成功；
   - 相关 pod 日志无 `x509: certificate signed by unknown authority`。

### Phase 4：验证与收尾

- 代理连通性：`curl -x http://squid-cache.squid:3128 https://pypi.org/simple/ -o /dev/null -w '%{http_code}\n'`
- 缓存命中：`kubectl -n squid exec squid-cache-0 -c squid -- tail -5 /var/log/squid/access.log`（二次请求 TCP_HIT）
- exporter 指标接入 Prometheus（`squid-cache.squid:9301/metrics`）
- 更新 `VERIFICATION.md` / `DEPENDENCIES.md`（CA 依赖已切换生产、cn12 部署形态变更留档）

---

## 5. 验收清单

- [x] 旧 release `squid`（squid-openssl）已卸载，集群无残留 Deployment `squid-cache`
- [x] 新 STS `squid-cache` 双副本 Ready（replicas=2），Service 3128 正常
- [x] SecretDefinition 已同步：`squid/squid-ca`（squid ns）公钥指纹 `73:71:2A:54`；各 caNamespaces（含新增的 triton-ascend/vllm-ascend/vllm-project）的 Secret `squid-ca-cert` 已生成
- [x] 6 个 cn12 本地命名空间的 ConfigMap `squid-ca-cert` 内容已更新为新 CA（指纹 `73:71:2A:54`），**ConfigMap 保留未删**（gy006 为 Liqo 托管，不动）
- [x] buildkitd amd64/arm64 STS 已滚动重启加载新 CA，全部 Running
- [x] 代理 HTTPS 返回 200、缓存命中（TCP_MEM_HIT）、exporter 168 项 squid 指标可见
