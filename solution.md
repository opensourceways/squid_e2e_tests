# 方案设计

## 设计目标

| 维度 | 目标 |
|------|------|
| **功能** | HTTP + HTTPS 代理,HTTPS 启用 SSL Bump 解密缓存 |
| **可用性** | 单实例/Squid/Node 故障不影响代理服务,零客户端配置变更 |
| **缓存效率** | 客户端 IP 亲和,自然减少缓存对象重复,避免多次回源 |
| **工程易用** | 声明式配置,不修改 Squid 源码。物理机: 2 个标准组件(HAProxy+keepalived); K8s: 0 额外组件(Service 内建 HA) |

## 方案对比

### 候选方案

| 方案 | HA 机制 | 组件数 | 优缺点 |
|------|---------|--------|--------|
| **纯 cache_peer** | Squid peer first-up 故障切换 | 0 | 客户端入口是单点,无法满足零中断 |
| **WPAD/PAC** | 浏览器侧故障切换 | 0 | 只覆盖浏览器,`curl`/`git` 等不走 PAC |
| **DNS 轮询** | DNS 多 IP | 0 | DNS TTL 导致分钟级切换延迟 |
| **keepalived + Squid** | VIP 漂移,主备 | 1 | 备机冷缓存,切换后性能退化 |
| **keepalived + HAProxy + Squid** ✅(物理机/VM) | VIP + Load Balancer + 健康检查 | 2 | AA 多活,自动故障隔离,零性能退化 |
| **K8s 原生 Service + Deployment** ✅(云原生) | Service + kube-proxy + readinessProbe | 0(编排层内建) | AA 多活,入口零单点,配置最省;但依赖 K8s 平台 |

### 决策（按部署环境二选一）

**两个方案都满足可用性目标，按环境选：**

- **物理机 / VM / 无 K8s** → **keepalived + HAProxy + Squid**
- **Kubernetes 集群** → **K8s 原生 Service + Deployment**（编排层内建 HA，最省）

选 keepalived+HAProxy 的理由（物理机场景）：
1. 三个 Squid 同时服务(AA 多活),备机不闲置
2. keepalived 管入口 VIP(<3 秒漂移),HAProxy 管分发+健康检查
3. 客户端永远指向 VIP,不用改配置
4. 纯 cache_peer 方案虽然零额外组件,但客户端入口单点是结构性缺陷,不满足可用性目标

### K8s 原生方案（云原生场景）

在 Kubernetes 里，**keepalived + HAProxy 的两个职责被平台原生能力完全替代**，无需再引入它们：

| keepalived+HAProxy 职责 | K8s 原生等价 |
|------------------------|-------------|
| keepalived：VIP 高可用 | **Service ClusterIP**（虚拟 IP，集群基础设施保证，永不宕，无"漂移"概念） |
| HAProxy：负载均衡 + 健康检查摘除 | **Service + kube-proxy + readinessProbe**（label selector 自动发现，秒级摘除死 Pod） |
| HAProxy `balance source` 去重 | **Service `sessionAffinity: ClientIP`** |
| `docker stop` 故障注入 | `kubectl delete pod` |

部署形态：**Deployment（或 StatefulSet）+ Service**。故障 HA 用 Deployment+emptyDir（副本自由调度、
反亲和到多节点）；需持久缓存用 StatefulSet+PVC。实测见 `k8s/ha-test.sh`（6 场景 kill-pod 验证，8 断言全通过）。

#### 优点

1. **入口零单点、零额外组件**：Service ClusterIP 是集群基础设施，不存在"VIP 在哪个节点"的问题；
   不用部署/维护 keepalived、HAProxy，配置最省（PR #2 的 `02-service.yaml` 一个 Service 即替代整套）。
2. **自动服务发现**：Service 靠 label selector 自动纳管 Pod，**扩缩容零配置**（HAProxy 要手动维护后端 IP 列表）。
3. **故障切换更快更稳**：readinessProbe（可用 HTTP cachemgr 探测，抓"listening 但卡死"）+ kube-proxy
   秒级更新 endpoint；实测逐个删除所有副本，Service 端点始终 ≥1，**无中断窗口**。
4. **声明式 + 自愈**：Pod 挂了自动重建，滚动更新 `maxUnavailable=0` 保证容量不降。
5. **规避了物理机方案的坑**：无 VRRP 组播问题（Docker/K8s overlay 网络下组播不通，我们测试时踩过单播坑）。

#### 缺点 / 约束

1. **强依赖 K8s 平台**：没有 K8s 就用不了；纯物理机/VM 环境仍需 keepalived+HAProxy 那套。
2. **裸金属集群的外部入口**：`type: LoadBalancer` 需云厂商 LB 或 MetalLB；集群外客户端固定入口要额外处理
   （集群内客户端用 ClusterIP 无此问题）。
3. **持久缓存受存储拓扑约束**：StatefulSet+PVC 在多 AZ 块存储（如华为云 csi-disk，`Immediate` 绑定）下，
   副本可能因 AZ 冲突调度失败——需 `WaitForFirstConsumer` 的 StorageClass，或用 Deployment+emptyDir（放弃持久缓存）。
4. **去重能力与物理机方案持平**：`sessionAffinity: ClientIP` 等价 `balance source`，
   都无 URL 级一致性哈希；要更强去重需额外上 Envoy/Ingress + consistent hash（两套都一样）。
5. **SSL Bump CA / 配置管理换形态**：CA 用 Secret、squid.conf 用 ConfigMap（单一来源，天然防漂移），
   但改配置要滚动重启，注意冷缓存冲击。

> **核心资产两套通用**：squid.conf、SSL Bump、缓存策略与编排层无关，物理机与 K8s 两套完全复用。
> 差异只在编排层（keepalived+HAProxy ↔ Service），上 K8s 后前者可视为被"完全替代"。

## 架构

```
                        客户端
                          │
                    VIP: 172.30.0.100
                          │
              ┌───────────┴───────────┐
              │     keepalived         │
              │  node1(MASTER 100)     │  ← 单播 VRRP,<3 秒漂移
              │  node2(BACKUP 90)      │
              └───────────┬───────────┘
                          │
              ┌───────────────────────┐
              │       HAProxy          │  ← TCP mode, balance source
              │  bind 0.0.0.0:3128     │     健康检查 3s,rise 2/fall 3
              └──┬────────┬─────────┬──┘
                 │        │         │
                 ▼        ▼         ▼
           ┌────────┐┌────────┐┌────────┐
           │ Squid1 ││ Squid2 ││ Squid3 │   ← 独立缓存,SSL Bump
           │  .11   ││  .12   ││  .13   │      无 peer 关系
           └────────┘└────────┘└────────┘
```

## 组件职责

| 组件 | 管什么 | 不管什么 |
|------|--------|---------|
| **keepalived** | VIP 归属:哪个节点活着,IP 在谁身上 | 不碰流量分发,不管后端健康 |
| **HAProxy** | 流量分发 + 后端健康检查 + 故障摘除 | 不碰 IP 漂移 |
| **Squid** | HTTP/HTTPS 代理 + SSL Bump 解密 + 缓存 | 不感知对等节点 |

## 关键设计决策

| 决策 | 选型 | 原因 |
|------|------|------|
| HAProxy 模式 | TCP mode | HTTP 和 HTTPS CONNECT 透明转发,不解包 |
| HAProxy 分发算法 | `balance source` | 同客户端 IP → 同 Squid,自然减少缓存重复 |
| keepalived 通信 | 单播 VRRP | Docker bridge 不支持组播 |
| Squid 关系 | 无 cache_peer | HAProxy 做了故障切换,再加 peer 只增复杂度 |
| Squid 存储 | 各自独立 `cache_dir` | 缓存 TTL 过期自然恢复,共享存储引入新单点 |
| HTTPS 缓存 | SSL Bump(OpenSSL build) | 唯一方案,GnuTLS build 无 `security_file_certgen` |

## 参考

- [Squid cache_peer 官方文档](http://www.squid-cache.org/Doc/config/cache_peer/)
- [Squid SSL Bump 官方文档](https://wiki.squid-cache.org/Features/SslBump)
- [HAProxy TCP mode 文档](https://docs.haproxy.org/2.8/configuration.html#4.2-mode)
- [keepalived 单播配置](https://keepalived.readthedocs.io/en/latest/case_study_keepalived_unicast.html)
- [Alpine Linux HA Web Cache(参考架构)](https://wiki.alpinelinux.org/wiki/High_Availability_High_Performance_Web_Cache)
