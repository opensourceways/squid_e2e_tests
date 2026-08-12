# Squid CI 缓存代理：调研 · 验证 · 部署

持续调研、验证并留档 **Squid + BuildKit + metrics + docker cache** 这一整套 CI 缓存代理的部署逻辑、架构与组件——涵盖 HA 验证、benchmark、以及最终生产部署形态。

## 仓库定位：两部分

| | 内容 | 位置 | 修改约束 |
|---|---|---|---|
| **① 调研 / 方案 / 测试验证** | 方案设计、HA 验证、sizing、benchmark、BuildKit 扩展 | 根目录各文档 + `configs/ docker/ scripts/ tests/`（Compose HA）、`k8s/`（K8s HA）、`sizing/`、`buildkit/` | 大家可**按需修改补充** |
| **② 实际部署 yaml** | gy-006 在跑的**真实生产部署**（Helm chart + CI 工具缓存测试） | **`deploy/`** | **最终部署形态，架构需仔细审视**；改前读 `deploy/DEPENDENCIES.md` |

下文快速开始针对 **① 的 Docker Compose HA 验证套件**（clone 即 `./scripts/setup.sh && ./scripts/test-all.sh` 复现）。
生产部署见 **`deploy/DEPLOY.md`**；给 agent 的总览见 **`AGENTS.md`**。

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
├── PRODUCTION.md                ← 生产部署指南(测试↔生产配置差异)
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
| 04 | HTTPS SSL Bump 缓存,**分层指标**: HIT/MISS 延迟分位(p50/p95/p99)+ CPU 两项成本 + 错误分类(用 `scripts/metrics.sh`) |
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
--- 04-https-cache.sh ---   (分层指标, 用 metrics.sh 框定 MISS/HIT 两个窗口)
  ✓ 冷取(MISS): HTTP 200
    MISS  n=1   p50=3638ms   请求命中率 0%    每请求CPU 0.247s  每GB 17.8s
  ✓ 命中(HIT): HTTP 200
    HIT   n=30  p50=130 p95=148 p99=149 ms   请求命中率 100%  每请求CPU 0.085s  每GB 6.1s
    → 缓存价值 = 延迟 28× 提速(3638→130ms); 两次采样看不到 p95/p99 分布与 CPU 成本
  [04-https-cache.sh] PASS
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

## 扩展场景：BuildKit 经 Squid 代理+缓存（可选）

验证容器镜像构建时 `RUN` 指令内的 HTTPS 请求经 BuildKit 内置代理链到 Squid，完成代理+缓存。
**默认不随主套件运行**，通过独立入口触发：

```bash
./scripts/setup.sh          # 先起主 Squid HA 环境
cd buildkit && ./run-tests.sh   # 运行 BuildKit 扩展测试(自动起停 buildkitd)
```

详见 `buildkit/README.md` 与 `buildkit/DESIGN.md`。依赖 BuildKit
[PR #1](https://github.com/TommyLike/buildkit/pull/1)（`feature/upstream-proxy-config` 分支）。

## 分层性能指标

`scripts/metrics.sh` 按区间采集分层指标,只依赖已有数据源(各 Squid 的 `access.log`、
HAProxy stats CSV、cgroup `cpu.stat`),不引入任何新组件:

```bash
./scripts/metrics.sh baseline  # 零负载时跑一次,测空闲 CPU 基线(可复用)
./scripts/metrics.sh begin     # 打基线
<跑你的负载>
./scripts/metrics.sh end       # 输出这段区间的分层指标
```

输出四层:**Squid**(请求/字节命中率、省下的回源字节)、**SSL Bump**(bump/splice 隧道数、
CPU 两项成本)、**HAProxy**(后端分发、健康、检查失败)、**归因**(按客户端的请求数与字节数)。

三个采集上的坑,脚本里已经处理:

- **必须框定区间**。累计值会把预热、健康检查、历史负载混在一起,命中率和 CPU/GB 都没有意义。
- **健康检查要剔除**。每 3 秒 × 3 后端 × 2 节点,不滤掉会把请求数和命中率彻底冲淡
  (日志里是 `NONE_NONE/400`、方法为 `-`)。
- **CONNECT 隧道不是对象请求**。`bump` 的 CONNECT 记录是 `NONE_NONE/200 bytes=0`,
  只是建隧道,真正的负载会作为解密后的 `GET https://...` 再记一行;混进去会凭空翻倍
  请求数并稀释命中率。`splice` 则相反,是 `TCP_TUNNEL` 带真实字节且不可能命中。

> **归因层需要 PROXY protocol**。HAProxy 是 TCP 模式转发,默认情况下 Squid 看到的客户端
> 永远是 HAProxy 节点,按 worker/job 的归因做不出来。脚本会在检测到这种情况时给出提示。

### 关于「命中率」不是唯一指标

合并进来的 K8s 压测数据(`reports/stress-benchmark-20260811.md`)显示:N=120 时
**纯 HIT 比纯 MISS 更吃 CPU**(199m vs 88m),HIT 反而更慢(104s vs 67s)——
因为命中要对内容重新做 TLS 加密,而回源只是在等被限速的源站。
所以只看命中率会得出错误的扩容结论,还必须看 CPU 成本。

### CPU 成本是两项,不是一个「每 GB」常数

CPU 消耗 = **每请求固定成本**(TLS 握手、证书生成、缓存查找)+ **每字节边际成本**(加密、I/O)。
只报「每 GB CPU」会把固定成本摊进字节里,于是同一套环境下这个数会随对象大小漂移 ——
实测 14MB 对象约 28 秒/GB,而 58KB–6MB 混合约 37–44 秒/GB,相差 1.6 倍。

容量估算要用两项模型:

```
核数 ≈ 请求速率 × 每请求CPU + 吞吐(GB/s) × 每GB CPU
```

要拟合这两项,需要在**不同对象大小/并发**下各跑一个窗口再比较,单个窗口拟合不出来。

另外必须先跑 `metrics.sh baseline`:Squid 零流量时也在烧 CPU(健康检查每 3 秒 × 3 后端 × 2 节点、
日志写入、缓存索引维护)。窗口越稀疏——比如里面有大量 `docker run` 启动等待——这部分占比越高,
实测能占到测量值的三分之一。不扣掉会显著高估 CPU 成本,也会让两个窗口之间的比较失去意义。

### K8s 上的同款采集

`k8s/metrics-k8s.sh` 是 metrics.sh 的 K8s 版——**口径完全相同**(健康检查过滤、CONNECT 去重、
HIER 错误分类、HIT/MISS 延迟分位、CPU 两项成本),只把数据源从 docker+HAProxy 换成
`kubectl exec`(access.log、cgroup **v1** `cpuacct.usage`)+ `kubectl get endpoints`。
一键跑 MISS/HIT 两窗口:

```bash
NS=test-husheng ./k8s/latency-test.sh   # 起 client pod → baseline → MISS 窗口 → HIT 窗口 → 清理
```

两点与 Compose 侧不同:① 没有 HAProxy/VIP,负载均衡是 Service `sessionAffinity: ClientIP`;
② **K8s Service 保留客户端源 IP,归因层无需 PROXY protocol 即可用**(Compose 侧 Squid 只看得到
HAProxy 节点 IP)。实测 HIT p50≈167ms、MISS p50≈1000ms,HIT 每请求 CPU 略高于 MISS
——与"HIT 需重新加密更吃 CPU"方向一致。

## 其他部分

| 部分 | 位置 | 说明 |
|------|------|------|
| **K8s HA 套件** | `k8s/` | 多副本 Deployment + Service，`kubectl` kill/stop pod 验证故障切换 |
| **Sizing 推演** | `sizing/` | 按并发 N + 缓存天数 R 推 CPU/内存/带宽/磁盘，含实测校准 |
| **BuildKit 扩展** | `buildkit/` | RUN 内 HTTPS 经内建代理链到 Squid 做代理+缓存（默认不随主套件跑，见上节） |
| **实际生产部署** ② | **`deploy/`** | gy-006 在跑的 Helm chart；入口 `deploy/DEPLOY.md`，依赖与独立部署 gap 见 `deploy/DEPENDENCIES.md` |

## 测试↔生产差异

上面 ① 的 Compose 套件是**测试验证环境**，部分配置为测试专用（如 `ssl_bump bump all`、单播 VRRP、DNS 硬编码），
**不可直接搬到生产**。生产部署的关键配置、测试↔生产差异、必改项清单见 **`PRODUCTION.md`**；
云原生实际部署形态见 **`deploy/`**。
