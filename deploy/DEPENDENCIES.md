# deploy 独立部署依赖清单与 gap

> 本文回答一个问题：**把 `deploy/` 这套 yaml 直接 clone 到一个全新集群，能独立跑起来吗？**
> 结论：**目前不能**。当前 chart 是 gy-006 生产环境（经 `ascend-ci-deployment` + ArgoCD + Vault）
> 的同步副本，带了一批对内部环境的硬耦合。本文只做**依赖梳理与 gap 记录**，暂不改造 yaml；
> 后续若要做到"clone 即独立部署"，按下面 §2 的 gap 清单补齐即可。

真正的部署入口与 CI 注入方式见 `DEPLOY.md`；架构见 `SQUID-OVERVIEW.md`；线上验证记录见 `VERIFICATION.md`。

---

## 1. 当前依赖矩阵

| 依赖 | 是什么 / 出现位置 | 阻塞独立部署? | 说明 |
|------|------------------|:---:|------|
| **CA Secret** | `squid-ca`（key `squid-ca-bundle.pem`=私钥+证书，SSL-Bump 签发）+ 各 ns 的 `squid-ca-cert`（`squid-ca.pem`=公钥） | 🟠 外部提供 | **出于安全，CA 不在仓库生成/提交**：由 Vault 经 secrets-manager `SecretDefinition` 自动同步到 Secret，使用方只需引用正确的 secret name（约定见 `DEPLOY.md §1.2`）。无 Vault 的测试集群手动注入 secret 作回退 |
| **私有镜像** | `chart/values.yaml` 的 `images.*` 全部来自 `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/...`（alpine / rpardini-docker-registry-proxy / boynux-squid-exporter / initContainer） | 🔴 硬阻塞 | 外网集群拉不到。公有等价物：`docker.io/library/alpine`、`ghcr.io/rpardini/docker-registry-proxy`、`docker.io/boynux/squid-exporter` |
| **StorageClass** | `chart/values.yaml` `persistence.*.storageClass: sfsturbo-subpath-sc`（华为 SFS Turbo） | 🟠 集群相关 | 新集群没有该 SC → PVC Pending。需换集群 default SC 或留空 |
| **Vault / secrets-manager** | `chart/templates/secret-definition.yaml` 用 `secrets-manager.tuenti.io/v1alpha1` `SecretDefinition` 从 Vault 同步 CA。`values-006.yaml` 里 `secretDefinition.enabled: true` | 🟠 可关 | chart 默认 `enabled: false`；独立部署走手动 `kubectl create secret`（见 `DEPLOY.md §1.2`） |
| **nodeSelector** | `values-006.yaml` `nodeSelector.kubernetes.io/arch: amd64` | 🟠 集群相关 | 单架构/异构集群需去掉或改 |
| **中央监控** | `DEPLOY.md §3`：exporter → prometheus-agent → remote_write 到 `113.44.182.82:9090` | 🟢 可选 | 独立部署可不接；exporter（:9301）本身仍工作，本地 Prometheus 直接 scrape 即可 |
| **gh-proxy** | `tool/08-bazel.yaml` 等用 `gh-proxy.test.osinfra.cn` 加速 github 下载 | 🟢 仅测试 | 只影响 tool/ 测试用例，不影响 chart 部署 |
| **alpineMirror** | `chart/values.yaml` `alpineMirror: mirrors.ustc.edu.cn/...` | 🟢 公有 | USTC 公有镜像源，可用；可按需改 |

图例：🔴 不补齐无法独立部署 · 🟠 集群相关、需按环境调整 · 🟢 可选/仅影响测试

---

## 2. "clone 即独立部署" 还差什么（gap 清单）

按优先级，把上表 🔴/🟠 补齐即可让本目录脱离 gy-006 独立部署（本次**仅记录，不实施**）：

1. **CA Secret 就位**（🟠，非仓库改造）：生产由 Vault + `SecretDefinition` 自动同步 `squid-ca` / `squid-ca-cert`，
   部署方只需引用正确的 secret name（约定见 `DEPLOY.md §1.2`）。无 Vault 的独立/测试集群手动
   `kubectl create secret` 注入即可作回退。**不在仓库内生成或提交 CA 私钥——这是安全约定，不是缺失。**
2. **公有镜像 values**（🔴）：新增 `values-standalone.yaml`，把 `images.*` 覆盖为公有 registry 等价物、
   `registryProxy.registries` 换成通用值（docker.io / ghcr.io / quay.io / gcr.io …）。
3. **通用 StorageClass / 去 nodeSelector**（🟠）：`values-standalone.yaml` 里 `persistence.*.storageClass`
   留空（用集群 default）或参数化，`nodeSelector: {}`。
4. **Vault 关闭**（🟠，已可行）：`values-standalone.yaml` 保持 `secretDefinition.enabled: false`，
   CA 走第 1 步的手动 secret。
5. **可选：kind/minikube 冒烟**：给一份最小 values 让本地单节点也能起（replicas=1、缩小 PVC），
   便于任何人本地验证 chart 正确性。

> 完成 1–4 后，一条 `helm install ... -f values-standalone.yaml` 即可在任意通用 K8s 集群独立部署，
> 而 `values-006.yaml` / ArgoCD / Vault 那套生产路径**保持不变**。

---

## 3. 不变量（改造时不要动的东西）

- **Helm chart `name` 与 release name = `squid-rpardini`**（`chart/Chart.yaml`、`DEPLOY.md` 的 ArgoCD 片段）：
  与 `ascend-ci-deployment` 生产源保持一致，**不随目录改名**，否则线上 ArgoCD 对不上。
- **`values-006.yaml`**：gy-006 线上真实值，只作同步留档，独立部署改动一律走新的 `values-standalone.yaml`。
- **`ascend-ci-deployment/...` 路径引用**：外部仓库的真实路径，非本地目录，保持原样。
