# deploy — Squid 生产部署方法与 CI 注入指南

> **本目录（`deploy/`）是仓库里"实际部署形态"的一份留档**：架构、chart、values、验证记录。
> 修改前请对照 `DEPENDENCIES.md` 了解它当前对外部环境（CA/私有镜像/StorageClass/Vault/监控）的耦合。
> 生产 Helm release 名与 chart name 仍为 `squid-rpardini`（与 `ascend-ci-deployment` 保持一致），**不随目录改名**。

> **部署状态**：manifest 位于
> [`github.com/opensourceways/ascend-ci-deployment/manifests/squid-rpardini`](https://github.com/opensourceways/ascend-ci-deployment/tree/main/manifests/squid-rpardini)
> （ArgoCD 从此拉取），**已部署在 gy006 集群**（`~/.kube/gy-006.yaml`，namespace `squid`）。
> 本目录 `chart/` 是与之保持同步的副本，`tool/` 为 16 个 CI 工具 e2e 测试（提交到集群运行）。

```
deploy/
├── chart/                  # ⚠️ 与 ascend-ci-deployment/manifests/squid-rpardini/chart 同步的副本
├── values-006.yaml         # ⚠️ gy-006 集群的值文件（the value of gy-006）
├── tool/                   # 16 个 CI 工具 e2e 测试（pip/apt/github/goproxy/bazel/npm/cargo/...）
├── SQUID-OVERVIEW.md       # 架构、路由、缓存策略、HA 设计
├── VERIFICATION.md         # gy-006 部署状态 + 监控接线验证记录
├── DEPENDENCIES.md         # 独立部署依赖清单与 gap（当前非自包含，见此）
└── DEPLOY.md               # 本文件：部署 + 注入
```

> **values 文件说明**：`values-006.yaml` 是 **gy-006 集群**（openmerlin-guiyang-006）的 values
> （replicas=2 双活、amd64、PVC 50Gi+200Gi、Vault secretDefinition）。
> 其他集群：`ascend-ci-deployment/argocd/clusters/squid-rpardini/values-{cn12-001,hk-001}.yaml`。

## 1. 部署

### 1.1 架构

```
CI 任务 (vcjob / buildkitd runner)
  │ HTTP_PROXY/HTTPS_PROXY → squid-cache.squid.svc.cluster.local:3128
  ▼
StatefulSet squid-cache (replicas=2 双活, 独立 PVC)
  ├── squid (3129, SSL-Bump MITM, 缓存 HTTPS 内容)
  ├── registry-proxy (3128, rpardini, 镜像 blob 缓存: SWR/docker.io/quay.io/...)
  └── squid-exporter (9301, cachemgr → Prometheus)
```

### 1.2 前置资源

```bash
KUBECONFIG=~/.kube/gy-006.yaml

# namespace
kubectl create namespace squid --dry-run=client -o yaml | kubectl apply -f -

# 1) squid 运行所需的 CA（bundle=私钥+证书, 用于 SSL-Bump 签发）
#    SecretDefinition 会自动从 Vault 同步（见 chart values.secretDefinition），
#    手动方式：
kubectl -n squid create secret generic squid-ca \
  --from-file=squid-ca-bundle.pem=../squid-openssl/ca/006-ca-new/squid-ca-bundle.pem \
  --from-file=squid-ca.pem=../squid-openssl/ca/006-ca-new/squid-ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) CI 命名空间用的 CA 公钥（每个需要代理的命名空间各一份）
kubectl -n squid create secret generic squid-ca-cert \
  --from-file=squid-ca.pem=../squid-openssl/ca/006-ca-new/squid-ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Bazel JVM trust store（bazel 客户端专用, 见 §2.5）
kubectl -n squid create configmap squid-bazel-trust \
  --from-file=squid-bazel-trust.jks=../squid-openssl/ca/006-ca-new/squid-bazel-trust.jks \
  --dry-run=client -o yaml | kubectl apply -f -
```

> 若配置了 `secretDefinition.enabled: true`，`squid-ca` 与各命名空间的 `squid-ca-cert`
> 由 secrets-manager 从 Vault 自动同步，无需手动创建。

### 1.3 ArgoCD 部署

chart 位于 `ascend-ci-deployment` 仓库的 `manifests/squid-rpardini/chart`，ArgoCD Application 多源部署（`argocd/clusters/openmerlin-guiyang-006/squid-rpardini.yaml`）：

```yaml
sources:
  - repoURL: 'https://github.com/opensourceways/ascend-ci-deployment.git'  # ← 部署源
    targetRevision: HEAD
    path: manifests/squid-rpardini/chart
    helm:
      releaseName: squid-rpardini
      valueFiles:
        - $values/argocd/clusters/squid-rpardini/values-006.yaml
  - repoURL: 'https://github.com/opensourceways/ascend-ci-deployment.git'  # values 源
    targetRevision: HEAD
    ref: values
```

集群级 values（`ascend-ci-deployment/argocd/clusters/squid-rpardini/values-006.yaml`）：
`replicas: 2`（双活）、nodeSelector amd64、PVC 大小、`secretDefinition.caNamespaces`。

### 1.4 Helm 直接部署（无 ArgoCD）

```bash
# 在 ascend-ci-deployment 仓库目录下执行
cd ascend-ci-deployment
helm install squid ./manifests/squid-rpardini/chart \
  -f argocd/clusters/squid-rpardini/values-006.yaml \
  -n squid --kubeconfig ~/.kube/gy-006.yaml

# 升级
helm upgrade squid ./manifests/squid-rpardini/chart \
  -f argocd/clusters/squid-rpardini/values-006.yaml \
  -n squid --kubeconfig ~/.kube/gy-006.yaml
```

> gy-006 的 values 同步副本见本目录 `values-006.yaml`（ArgoCD `$values` 源指向
> `ascend-ci-deployment/argocd/clusters/squid-rpardini/values-006.yaml`）。

### 1.5 部署验证

```bash
kubectl -n squid get pods -l app=squid-cache -o wide   # 2 个 Ready（双活）

# 代理连通性（走 squid，SSL-Bump 生效）
curl -x http://squid-cache.squid:3128 https://pypi.org/simple/ -o /dev/null -w '%{http_code}\n'

# 缓存命中验证（二次请求应 TCP_HIT）
kubectl -n squid exec squid-cache-0 -c squid -- tail -5 /var/log/squid/access.log
# 或指标: curl http://squid-cache.squid:9301/metrics | grep squid_client_http_hit
```

## 2. CI 注入方式（vcjob / 任意 CI Pod）

参照 `tool/08-bazel.yaml` 的完整模板。以下为标准注入配方：

### 2.1 代理环境变量（容器 env）

```yaml
env:
- name: HTTP_PROXY
  value: "http://squid-cache.squid.svc.cluster.local:3128"
- name: HTTPS_PROXY
  value: "http://squid-cache.squid.svc.cluster.local:3128"
- name: http_proxy
  value: "http://squid-cache.squid.svc.cluster.local:3128"
- name: https_proxy
  value: "http://squid-cache.squid.svc.cluster.local:3128"
- name: NO_PROXY
  value: "localhost,127.0.0.1,.buildkitd,.svc.cluster.local,.cluster.local"
- name: no_proxy
  value: "localhost,127.0.0.1,.buildkitd,.svc.cluster.local,.cluster.local"
```

> ⚠️ **NO_PROXY 必须包含 `.buildkitd` 短名**：gRPC 的 delegating-resolver 不会把
> `buildkitd-service.buildkitd` 匹配到 `.svc.cluster.local` 后缀规则，漏掉它会导致
> buildkitd 的 mTLS gRPC 被 squid SSL-Bump 拦截 → `x509: certificate signed by unknown authority`。

### 2.2 CA 信任环境变量（容器 env，工具矩阵）

全部指向挂载的 CA 公钥 `/etc/squid-ca/squid-ca.pem`：

```yaml
- name: SSL_CERT_FILE
  value: /etc/squid-ca/squid-ca.pem
- name: CURL_CA_BUNDLE
  value: /etc/squid-ca/squid-ca.pem
- name: REQUESTS_CA_BUNDLE
  value: /etc/squid-ca/squid-ca.pem
- name: GIT_SSL_CAINFO
  value: /etc/squid-ca/squid-ca.pem
- name: PIP_CERT
  value: /etc/squid-ca/squid-ca.pem
- name: NODE_EXTRA_CA_CERTS
  value: /etc/squid-ca/squid-ca.pem
```

| 工具 | 信任机制 |
|------|----------|
| curl/wget | `CURL_CA_BUNDLE` |
| git | `GIT_SSL_CAINFO` |
| pip | `PIP_CERT`（不走系统 store） |
| requests/urllib (python) | `REQUESTS_CA_BUNDLE` |
| node/npm | `NODE_EXTRA_CA_CERTS`（不覆盖系统 CA，只追加） |
| go | 读系统 store（需 postStart 注入，见 §2.4） |
| bazel/JVM | 专用 jks trust store（见 §2.5） |
| cargo | 读系统 store（或 `CARGO_HTTP_CAINFO`，git 类操作走 `GIT_SSL_CAINFO`） |

### 2.3 卷挂载（volumes + volumeMounts）

```yaml
volumeMounts:
- name: squid-ca
  mountPath: /etc/squid-ca
  readOnly: true
- name: squid-bazel-trust          # 仅 bazel/Java 构建需要
  mountPath: /etc/squid-bazel-trust
  readOnly: true
volumes:
- name: squid-ca
  secret:
    secretName: squid-ca-cert      # 各命名空间自己的 squid-ca-cert（Vault 同步）
    items:
    - key: squid-ca.pem
      path: squid-ca.pem
    optional: true
- name: squid-bazel-trust
  configMap:
    name: squid-bazel-trust
    optional: true
```

### 2.4 postStart 钩子（把 CA 装进系统信任库 + 工具专项）

```yaml
lifecycle:
  postStart:
    exec:
      command: [/bin/bash, -c, |
        set +e
        P=/etc/squid-ca/squid-ca.pem
        if [ -f "$P" ]; then
          if [ -d /etc/pki/ca-trust/source/anchors ]; then      # RHEL/openEuler
            cp "$P" /etc/pki/ca-trust/source/anchors/squid-ca.pem >/dev/null 2>&1
            update-ca-trust extract >/dev/null 2>&1
          else                                                   # Debian/Ubuntu
            cp "$P" /usr/local/share/ca-certificates/squid-ca.crt >/dev/null 2>&1
            update-ca-certificates -f >/dev/null 2>&1
          fi
        fi
        if command -v apt-get >/dev/null 2>&1 && [ -n "$HTTPS_PROXY" ]; then
          mkdir -p /etc/apt/apt.conf.d
          printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' \
            "$HTTPS_PROXY" "$HTTPS_PROXY" > /etc/apt/apt.conf.d/99squid-proxy
        fi
        exit 0
      ]
```

要点：
- **分支处理**：RHEL 系 `update-ca-trust extract`，Debian 系 `update-ca-certificates`；两边都幂等、失败不致命（`set +e`）。
- apt 单独走 apt.conf（apt 不完全跟随 `HTTP_PROXY` 环境变量）。
- 依赖 `HTTPS_PROXY` 才写 apt 配置 → direct 对比测试自动跳过（见 tool 的 direct 变体生成）。

### 2.5 Bazel 专项（JVM trust store）

Bazel 启动 JVM 时**忽略 `JAVA_TOOL_OPTIONS`**，trust 参数只能通过 `.bazelrc`：

```yaml
# postStart 中：
cat > "$WORKSPACE/.bazelrc" << 'EOF'
startup --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/squid-bazel-trust/squid-bazel-trust.jks
startup --host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit
EOF
```

- jks 由 `squid-bazel-trust` ConfigMap 提供（生成方式：`keytool -importcert -alias squid-ca -file squid-ca.pem -keystore squid-bazel-trust.jks -storepass changeit -noprompt`）。
- github.com 下载超时场景：用 gh-proxy（`https://gh-proxy.test.osinfra.cn/https://github.com/...`）替换 URL，见 `tool/08-bazel.yaml` 的 WORKSPACE 写法。

### 2.6 完整模板

见 `tool/08-bazel.yaml`（最完整的 case：env + mounts + postStart + bazel 专项 + volcano job 结构）。
所有 16 个 case 共用同一注入配方；`run-tool-tests.sh` 会自动生成 "-direct" 变体
（去掉全部代理/CA env）做有无 squid 的耗时对比。

## 3. 监控

数据链路与已生效状态见 **`VERIFICATION.md`**（gy-006 实测）。要点：

```
squid-cache.squid:9301 (exporter)
  → prometheus-agent scrape (job: squid)
  → remote_write → 中央 http://113.44.182.82:9090
```

- ⚠️ 修改 agent ConfigMap 后必须 `POST /-/reload` 才生效（agent 参数已含 `--web.enable-lifecycle`）。
- 查询入口：squid 指标在中央 113.44.182.82；1.95.134.239 是 pull 型 NPU 监控，不含 squid。
- registry 镜像流量走 splice（TCP_TUNNEL），不计入 squid HTTP counter；缓存效果看 registry-proxy 日志。

## 4. 常见问题

| 症状 | 原因 | 解决 |
|------|------|------|
| `x509: certificate signed by unknown authority`（gRPC） | NO_PROXY 缺 `.buildkitd` 短名 | 补进 NO_PROXY（§2.1） |
| 已建立连接在故障切换时中断 | 双活切换是端点级，TCP 连接不迁移 | 客户端重试（buildkit/curl --retry） |
| bazel 拉取失败：SSLHandshakeException | 未配 JVM trust store | §2.5 `.bazelrc` |
| pip 提示证书错误 | pip 不看系统 store | `PIP_CERT`（§2.2） |
| 镜像 pull 慢 | 直连 registry | 走 squid（registry 域 splice → registry-proxy 缓存） |
