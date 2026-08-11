# Squid on Kubernetes（测试部署）

按 `../sizing/SQUID-SIZING-K8S.md` 驱动模型的**测试规格**部署 Squid 缓存集群。
采用 **StatefulSet + PVC** 持久化缓存（长时间 cache 需求）。

## 测试规格（N=20, R=1）

| 输入 | 值 | → 推算结果 |
|------|-----|-----------|
| N 峰值并发下载 | 20 | 入向 `N×v`=1Gbps；FD `N×2`=40→4096(余量) |
| R 缓存失效天数 | 1 | 磁盘 `d×R/0.8`≈25GB |
| 副本数 | 3（N=20 带宽 2 副本即够；保持 3 验证 HA+去重） | — |
| 单副本 PVC | 10Gi SSD | 总量/副本 + 余量 |
| 单副本 CPU | req 250m / limit 1 | B类 crypto-bound，非瓶颈 |
| 单副本内存 | req 512Mi / limit 1Gi | 索引+cache_mem+SSL 余量 |
| 部署形态 | **StatefulSet**（缓存持久） | 长时间 cache |

## 前置

1. `kubectl` 已配置指向测试集群：
   ```bash
   export KUBECONFIG=../.config/test-husheng-kubeconfig.yaml   # 或你的 kubeconfig
   ```
2. 集群节点能拉取 `tommylike/squid-sslbump:latest`（见下方镜像构建）

## 测试集群适配（已验证 2026-08-11）

本仓库 manifest 已按提供的测试集群适配并通过 **server-side dry-run** 验证：

| 项 | 适配值 | 说明 |
|----|--------|------|
| namespace | **`test-husheng`** | SA 权限绑定于此；无权限创建其他 ns |
| storageClass | **`csi-disk`** | 集群唯一可绑定的块存储（华为云 CSI，SSD）；已实测 PVC Bound |
| 权限范围 | statefulset/service/cm/secret/pvc/job 均可 | 集群级资源(node/sc/pv)不可见但不影响部署 |

> 在自有集群部署：改 manifest 的 `namespace` 与 `storageClassName` 为你的值，
> 并先 `kubectl apply -f manifests/00-namespace.yaml`。

## 镜像构建（首次）

manifest 引用 `tommylike/squid-sslbump:latest`（ubuntu/squid + squid-openssl + 持久化启动脚本）：

```bash
cd k8s/docker
docker build -t tommylike/squid-sslbump:latest .
docker push tommylike/squid-sslbump:latest
```

## 部署与测试

```bash
./deploy.sh                    # 生成 CA Secret + apply + 等待就绪
./test.sh                      # 功能验证(5 项)
./test-concurrent.sh 20 40     # 并发下载测试(N个client同时下载)
./cleanup.sh                   # 清理(--keep-pvc 保留缓存卷)
```

## 功能测试点（test.sh）

| # | 验证 |
|---|------|
| 01 | HTTP 代理经 Service 返回 200 |
| 02 | HTTPS SSL Bump 代理返回 200 |
| 03 | HTTPS 缓存：二次下载 Squid TCP_HIT |
| 04 | 删除 squid-1 后代理仍 200（Pod 故障切换） |
| 05 | **PVC 持久化**：删 squid-0 后缓存文件跨 Pod 重建仍在（StatefulSet 特性） |

## 并发测试（test-concurrent.sh）

驱动模型的核心输入是**并发数 N**，故用 **Job（parallelism=N）** 起多个 client Pod
**同时**经 Squid 下载，真实模拟并发下载流：

```bash
./test-concurrent.sh [并发数N] [总次数]
# 默认 20 40; 生产画像可 ./test-concurrent.sh 50 100
```

验证点：
- 全部 N 并发下载成功（成功率）
- 各 client 下载耗时分布
- Squid 缓存命中分布（首批 MISS 回源，其余 HIT，含 collapsed forwarding 效果）
- 通过 `sessionAffinity: ClientIP` 观察去重路由效果

## 关键设计点（对应 sizing 报告）

- **StatefulSet + volumeClaimTemplates**：每副本独立 PVC，缓存跨 Pod 重启持久（§6.1）
- **startupProbe failureThreshold=30**：覆盖缓存 `swap.state` 重建时间，避免被 liveness 误杀（§6.3）
- **sessionAffinity: ClientIP**：缓存去重，同客户端固定路由到同副本（§5，等价 HAProxy `balance source`）
- **podAntiAffinity**：副本打散到不同 node（§6.2）
- **日志到 stdout**：不写 PVC 撑爆缓存盘（§6.7）
- **memory limit 留 SSL 余量**：防 SSL Bump OOMKilled（§6.5）
- **磁盘 LFUDA / 内存 GDSF + maximum_object_size 4GB**：大文件省字节带宽（§2.3）

## 多副本 HA 测试（ha-test.sh）

把根目录 **Docker Compose 的 6 个 HA 场景移植到 K8s**：多副本 + Service 访问 + `kubectl delete pod` 故障注入。
编排层从 keepalived+HAProxy 换成 K8s 原生 Service（见根 `solution.md` / sizing 报告选型讨论）。

```bash
export KUBECONFIG=../.config/test-husheng-kubeconfig.yaml
./ha-test.sh test     # 部署 3 副本 Deployment + 跑 6 场景
./ha-test.sh clean    # 清理
```

用 **Deployment + emptyDir**（非 StatefulSet+PVC）：3 副本可自由调度到不同节点，
避开 csi-disk 的 AZ 绑定限制；HA 故障切换不依赖持久缓存。

### 场景映射（Docker HA → K8s HA）

| # | 原 Docker 场景 (`tests/`) | K8s 等价 (`ha-test.sh`) |
|---|---------------------------|-------------------------|
| 01 | 基础代理 | HTTP/HTTPS 经 **Service** |
| 02 | 单 Squid 故障 | `kubectl delete pod` → Service 继续 |
| 03 | VIP 漂移(keepalived) | **逐个删全部 Pod → Service 端点始终 ≥1**(无 VIP 概念) |
| 04 | HTTPS 缓存 | MISS→HIT 经 Service |
| 05 | 下载中断 | 下载中删 Pod → Service 继续 |
| 06 | 双 Squid 故障 | 删 2 Pod 仅剩 1 → 连续请求 200 |

| Docker(keepalived+HAProxy) | K8s(原生) |
|---------------------------|-----------|
| VIP(keepalived) | Service ClusterIP(永不宕) |
| HAProxy 健康检查摘除 | readinessProbe → kube-proxy 更新 endpoint |
| `docker stop` | `kubectl delete pod --force` |
| `balance source` | Service `sessionAffinity: ClientIP` |

> **两套并存**：物理机/VM 用根目录 Docker Compose 那套(`tests/`)；云原生用本目录 K8s 这套。
> 核心资产(squid.conf / SSL Bump / 缓存策略)两套复用。实测 8 断言全通过(2026-08-11)。

## 目录

```
k8s/
├── README.md
├── deploy.sh / test.sh / test-concurrent.sh / cleanup.sh
├── ha-test.sh                    ← 多副本 HA 测试(6 场景, kill pod)
├── stress.sh / stress-campaign.sh ← 上限压测
├── docker/                       ← squid-sslbump 镜像(Dockerfile + start.sh)
└── manifests/
    ├── 00-namespace.yaml
    ├── 01-configmap.yaml         ← squid.conf(测试规格)
    ├── 02-service.yaml           ← headless + ClientIP 亲和
    ├── 03-statefulset.yaml       ← 3 副本 + PVC + 三探针 + 反亲和(持久缓存)
    ├── ha-deployment.yaml        ← 3 副本 Deployment + Service(emptyDir, HA 测试)
    └── stress-*.yaml             ← 压测用(deployment/client/random)
```

## 从测试规格到生产

改 `configs`/manifest 的这些量即可放大到生产（见 sizing 报告 §7-§8）：
副本数 `K`、PVC 容量（由 `R` 决定）、资源 requests/limits、`cache_dir` 容量、storageClass。
生产务必把 `ssl_bump bump all` 改为域名白名单。
