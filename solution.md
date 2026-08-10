# 方案设计

## 设计目标

| 维度 | 目标 |
|------|------|
| **功能** | HTTP + HTTPS 代理,HTTPS 启用 SSL Bump 解密缓存 |
| **可用性** | 单实例/Squid/Node 故障不影响代理服务,零客户端配置变更 |
| **缓存效率** | 客户端 IP 亲和,自然减少缓存对象重复,避免多次回源 |
| **工程易用** | 仅 2 个标准组件(HAProxy + keepalived),声明式配置,不修改 Squid 源码 |

## 方案对比

### 候选方案

| 方案 | HA 机制 | 组件数 | 优缺点 |
|------|---------|--------|--------|
| **纯 cache_peer** | Squid peer first-up 故障切换 | 0 | 客户端入口是单点,无法满足零中断 |
| **WPAD/PAC** | 浏览器侧故障切换 | 0 | 只覆盖浏览器,`curl`/`git` 等不走 PAC |
| **DNS 轮询** | DNS 多 IP | 0 | DNS TTL 导致分钟级切换延迟 |
| **keepalived + Squid** | VIP 漂移,主备 | 1 | 备机冷缓存,切换后性能退化 |
| **keepalived + HAProxy + Squid** ✅ | VIP + Load Balancer + 健康检查 | 2 | AA 多活,自动故障隔离,零性能退化 |

### 决策

选 **keepalived + HAProxy + Squid**。理由：

1. 三个 Squid 同时服务(AA 多活),备机不闲置
2. keepalived 管入口 VIP(<3 秒漂移),HAProxy 管分发+健康检查
3. 客户端永远指向 VIP,不用改配置
4. 纯 cache_peer 方案虽然零额外组件,但客户端入口单点是结构性缺陷,不满足可用性目标

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
