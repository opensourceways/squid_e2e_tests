# Squid HA 方案验证

基于 **keepalived + HAProxy + Squid** 的 HTTP/HTTPS 缓存代理高可用方案的**端到端验证仓库**。

包含完整的方案设计、可复现的 Docker 环境、以及带真实断言的自动化测试。目标：任何人 clone 下来 `./scripts/setup.sh && ./scripts/test-all.sh` 即可复现全部结果。

## 能力

- **HTTP 代理缓存**
- **HTTPS SSL Bump 解密缓存**（RPM 包二次下载显著加速，见测试 04）
- **单/多 Squid 实例故障自动切换**（HAProxy 健康检查摘除，服务不中断）
- **HA 节点故障 VIP 自动漂移**（keepalived VRRP，客户端无感知）
- **零编码**，仅标准组件（HAProxy + keepalived + Squid）配置

> ⚠️ **生产环境警告**：本仓库配置 `ssl_bump bump all` 无差别解密全部 HTTPS，**仅用于测试**。
> 生产环境无差别 TLS 解密存在隐私/合规风险（部分国家/行业属违法），必须改为域名白名单模式，
> 见 `configs/squid/squid.conf` 内注释与 `solution.md`。

## 快速开始

```bash
# 前置: Docker 24+ 与 docker compose v2
docker compose version

git clone https://github.com/opensourceways/squid_e2e_tests.git && cd squid_e2e_tests

./scripts/setup.sh      # 生成 CA → 构建镜像 → 启动 5 容器
./scripts/test-all.sh   # 运行 6 项测试,生成 test-report.txt + result.json
./scripts/cleanup.sh    # 清理环境
```

`test-all.sh` 整体 **exit code 反映成败**（0=全通过，1=有失败），并输出机器可读的 `result.json`——方便 CI 与 agent 判断。

## 目录结构

```
├── README.md                    ← 本文件
├── AGENTS.md                    ← 给其他 agent 的入口说明
├── solution.md                  ← 方案选型与架构设计
├── test.md                      ← 测试策略与用例
├── TROUBLESHOOTING.md           ← 已知问题与踩坑记录
├── docker-compose.yml           ← 5 容器基础设施定义
├── scripts/
│   ├── setup.sh                 ← 生成 CA + 构建 + 启动
│   ├── test-all.sh              ← 运行全部测试 + 报告 + result.json
│   └── cleanup.sh               ← 清理环境
├── tests/
│   ├── lib.sh                   ← 公共断言库(proxy_http_code/assert_code)
│   ├── 01-basic-proxy.sh        ← HTTP/HTTPS 连通性
│   ├── 02-squid-failover.sh     ← 单 Squid 故障切换
│   ├── 03-vip-failover.sh       ← VIP 双向漂移
│   ├── 04-https-cache.sh        ← HTTPS SSL Bump 缓存(首次/二次耗时对比)
│   ├── 05-interrupt.sh          ← 下载中断影响
│   └── 06-double-squid-fail.sh  ← 两台 Squid 同时故障
├── configs/
│   ├── test.env                 ← 测试 URL 配置(可自定义)
│   ├── squid/squid.conf         ← SSL Bump + 缓存策略
│   ├── haproxy/haproxy.cfg      ← TCP mode + balance source
│   ├── keepalived/              ← node1(MASTER) + node2(BACKUP)
│   └── certs/                   ← setup.sh 自动生成(git 忽略)
└── docker/
    ├── squid/                   ← ubuntu/squid + squid-openssl
    └── node/                    ← debian + haproxy + keepalived
```

## 测试点

| 测试 | 验证目标 |
|------|---------|
| 01 | HTTP + HTTPS 代理连通(HTTP 200 断言) |
| 02 | 单 Squid 故障,代理仍返回 200 |
| 03 | HAProxy 节点故障,VIP 双向漂移,代理仍返回 200 |
| 04 | HTTPS SSL Bump 缓存,展示首次(MISS)与二次(HIT)耗时对比 |
| 05 | 下载中 Squid 中断,代理仍返回 200 |
| 06 | 两台 Squid 同时故障(仅剩 1/3),代理仍返回 200 |

所有测试均为**真断言**：HTTP code 非 200 或 VIP 未漂移即判定 FAIL 并以非零 exit code 退出。

## 预期输出

```
============================================
  Squid HA 验证测试 | ...
============================================
--- 01-basic-proxy.sh ---
  ✓ HTTP 代理: HTTP 200
  ✓ HTTPS 代理: HTTP 200
  [01-basic-proxy.sh] PASS (3s)
--- 02-squid-failover.sh ---
  ✓ 故障后代理: HTTP 200
  ✓ 恢复后代理: HTTP 200
  [02-squid-failover.sh] PASS (24s)
...
--- 04-https-cache.sh ---
  ✓ 首次下载(MISS): HTTP 200
  首次(MISS): 2.6s  15000000 bytes  5700000 B/s
  ✓ 二次下载(HIT): HTTP 200
  二次(HIT):  0.16s  15000000 bytes  95000000 B/s
  耗时对比: 首次 2.6s → 二次 0.16s
  [04-https-cache.sh] PASS (5s)
...
============================================
  结果: 6 通过 / 0 失败 / 6 总计
============================================
```

## 自定义测试 URL

编辑 `configs/test.env`：

```bash
HTTP_URL="http://repo.openeuler.org/"
HTTPS_URL="https://curl.se/"
HTTPS_CACHE_URL="https://repo.openeuler.org/.../bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm"
```

## 依赖

| 工具 | 用途 | 最小版本 |
|------|------|---------|
| Docker | 容器运行时 | 24+ |
| docker compose | 编排 | v2 |
| openssl | CA 证书生成 | 任意 |
| bash | 脚本 | 4+ |

仅需 Docker 命令行，无需 Kubernetes、云服务或特权网络。遇到问题见 `TROUBLESHOOTING.md`。
