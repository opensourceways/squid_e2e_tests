# Squid HA 方案验证

## 概述

基于 **keepalived + HAProxy + Squid** 的 HTTP/HTTPS 缓存代理高可用方案,支持：

- HTTP 代理缓存
- HTTPS SSL Bump 解密缓存（50MB RPM 包加速比 **>100x**）
- 单 Squid 实例故障自动切换（<10 秒,服务不中断）
- HA 节点故障 VIP 自动漂移（<3 秒,客户端无感知）
- 零编码,仅标准组件配置

## 快速开始

```bash
# 前置: Docker + docker compose plugin
docker compose version

# 克隆
git clone <repo> squid-ha && cd squid-ha

# 一键搭建
./scripts/setup.sh

# 一键测试（生成 test-report.txt）
./scripts/test-all.sh

# 清理
./scripts/cleanup.sh
```

## 目录结构

```
├── README.md                    ← 本文件
├── solution.md                  ← 方案选型与架构设计
├── test.md                      ← 测试策略与用例
├── docker-compose.yml           ← 基础设施定义
├── scripts/
│   ├── setup.sh                 ← 生成 CA + 构建 + 启动
│   ├── test-all.sh              ← 运行全部测试 + 生成报告
│   └── cleanup.sh               ← 清理环境
├── tests/
│   ├── 01-basic-proxy.sh        ← HTTP/HTTPS 连通性
│   ├── 02-squid-failover.sh     ← Squid 故障切换
│   ├── 03-vip-failover.sh       ← VIP 漂移
│   ├── 04-https-cache.sh        ← HTTPS SSL Bump 缓存
│   └── 05-interrupt.sh          ← 下载中断影响
├── configs/
│   ├── squid/squid.conf         ← SSL Bump + 缓存策略
│   ├── haproxy/haproxy.cfg      ← TCP mode + balance source
│   ├── keepalived/              ← node1(MASTER) + node2(BACKUP)
│   └── certs/                   ← setup.sh 自动生成
└── docker/
    ├── squid/                   ← ubuntu/squid + squid-openssl
    └── node/                    ← debian + haproxy + keepalived
```

## 测试结果示例

```
============================================
  Squid HA 方案验证测试报告
============================================
--- 01-basic-proxy.sh ---
HTTP:  200 0.001s
HTTPS: 200 1.762s

--- 02-squid-failover.sh ---
故障后: HTTP 200

--- 03-vip-failover.sh ---
初始: VIP 在 node1
漂移: VIP 在 node2
代理: HTTP 200

--- 04-https-cache.sh ---
首次 (MISS): 75.5s 671818 B/s
二次 (HIT):  0.52s 96781383 B/s  ← 加速 145x

--- 05-interrupt.sh ---
中断 squid3: 代理 HTTP 200,服务正常
============================================
  结果: 5 通过 / 0 失败 / 5 总计
============================================
```

## 依赖

| 工具 | 用途 | 最小版本 |
|------|------|---------|
| Docker | 容器运行时 | 24+ |
| docker compose | 编排 | v2 |
| openssl | CA 证书生成 | 任意 |
| bash | 脚本 | 4+ |

仅需 Docker 环境的命令行,无需 Kubernetes、云服务或特权网络。
