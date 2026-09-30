# 监控指标采集设计（squid + registry-proxy）

> 结论先行：**架构上"一个全覆盖 exporter"是理想态，但正确路径是"成熟快照解析器 + 可热加载的日志解析器"，先并行后收敛；跳过中间态直接自研 all-in-one 等于在监控链路里引入一个需要频繁重新编译的单点。**

## 1. 现状：指标数据源全景

| 数据源 | 采集组件 | 端口 | 内容 | 迭代频率 |
|---|---|---|---|---|
| squid cachemgr 页面 | boynux/squid-exporter（上游维护） | :9301 | 可用性、fd、磁盘、命中快照 | 低（稳定） |
| squid access.log + cache.log | **待定**（mtail / Alloy / 自研） | :3901 | 按 domain 聚合、MISS/HIT/ABORT、错误行 | **高（规则常调）** |
| registry-proxy 日志 | registry-exporter（自研 sidecar） | :9302 | 镜像拉取聚合、nginx access/error.log 轮转控制 | 中 |
| 端到端拨测 | github_probe CronJob + Pushgateway | — | 黑盒连通性（外置，不在 Pod 内） | 低 |

Prometheus 侧：prometheus-agent 统一加 scrape job 抓 :9301/:9302/:3901。

## 2. 为什么不自研 all-in-one exporter

**打包问题 ≠ 解析逻辑放哪的问题。** 三个数据源处理方式完全不同：

| 数据源 | 处理方式 | 现成方案 | 自研 all-in-one 要写什么 |
|---|---|---|---|
| cachemgr 页面 | HTTP GET + 文本解析（低频轮询 30s） | boynux/squid-exporter（现成、上游维护、已在跑） | 重写现有功能，零新增价值 |
| access.log | **逐行 tail + 正则 + 聚合 counter**（高频，每秒几十~几百行） | mtail / Grafana Alloy | Go 里写 tail、RE2 匹配、counter 生命周期、**squid rotate 截断文件处理**、优雅退出 |
| cache.log | 逐行 tail + 正则（低频） | 同上 | 同上 |

后两行本质都是"**日志解析引擎**"——自研的不是 exporter，是一个嵌在 exporter 里的 mtail。而日志解析规则恰恰是**最常变的部分**（调告警正则、logformat 改字段、加统计维度）。mtail 规则是 ConfigMap 里的**热加载文本**，改完秒生效；自研 exporter 每次都是 build → push swr → 改 chart tag → ArgoCD 同步。迭代速度差一个数量级。

**故障隔离**：日志解析暴露在非受控输入下（恶意 URL 编码、超长行、怪异域名都可能触发解析 bug）。自研 all-in-one 因一条诡异 access.log 行 panic/OOM 时，cachemgr 指标一起死 → 可用性/磁盘告警全瞎；分离部署时 mtail 死了，exporter 告警照常工作，mtail 自己被 `up` 监控到。监控组件必须比被监控对象更稳——分离是刻意的防御设计。

## 3. registry-proxy 侧怎么归位

### 3.1 上游现状（2026-09-30 已核实）

registry-proxy（rpardini/docker-registry-proxy）**没有原生 Prometheus 支持**：

- GitHub 搜 `prometheus`：0 个 issue（open/closed 均无）——**连 feature request 都从未有人提过**
- 搜 `metrics`：仅 3 个不相关 issue（blob 拉取失败、重定向、containerd 配置）
- 项目低维护：最新 issue 集中在 2022 年，Docker Hub 镜像约 8 个月未更新

结论：**等上游补 metrics 不现实，指标只能自己动手**。其本体是 nginx + docker-registry 拼装，指标抓手就是 nginx 的两个面：stub_status 端点 + 日志。

### 3.2 纯日志解析不够——缺"进行中"视角

nginx access.log 里埋着缓存核心指标（`$upstream_cache_status`、`$status`、`$body_bytes_sent`、`$request_time`），日志解析擅长**命中率、按镜像/repo 聚合的拉取量、错误码分布**。但它给不了：

| 指标 | 为什么日志给不了 |
|---|---|
| active connections（当前并发 gauge） | 日志只有"已结束的请求"，没有"进行中的" |
| accepted / handled 连接计数 | 连接层（非请求层）计数 |
| reading / writing / waiting 分布 | 排队/背压观测 |

注意：`$upstream_cache_status` 的取值即命中判定——`HIT`（直接回缓存）/`MISS`（回源）/`EXPIRED`（过期重校验）；`$body_bytes_sent` 按 status 分组求和即缓存节省带宽与回源流量；`$request_time` 按 cache status 分组出 p95 即"缓存快了多少"的量化证据。

### 3.3 社区通用做法与备选

1. **nginx stub_status + nginx-prometheus-exporter**（最主流、成本最低）：registry-proxy 的 nginx 模板加一个 `location /stub_status` 即可，补齐上表全部缺口
2. **日志解析**：mtail / promtail+Loki，与 squid 侧同一套引擎
3. **换组件**（仅记录，不建议现在动）：
   - docker 官方 distribution v3.0 起内置 `/metrics`，但它只是 origin registry，无缓存逻辑，不能直接替代
   - etkecc/docker-registry-proxy（Go 重写版，内置 Prometheus metrics + basic auth）——迁移成本大于给现有 nginx 加一个 stub_status location
   - Harbor / zot 自带 exporter，但部署重量级完全不同

## 4. 指标清单（要什么指标，为什么）

### 4.A registry.mtail —— registry nginx access.log 解析（4 条）

| 指标 | 类型 | labels | 来源字段 | **为什么** |
|---|---|---|---|---|
| `registry_cache_requests_total` | counter | `cache_status`(HIT/MISS/EXPIRED/BYPASS/STALE)、`code_class`(2xx/4xx/5xx) | `$upstream_cache_status` + `$status` | **命中率主指标**：`rate(HIT)/rate(all)`；同时覆盖过期率与 5xx 错误率——一条指标喂三个告警 |
| `registry_cache_bytes_total` | counter | `cache_status` | `$body_bytes_sent` | **缓存收益量化**：HIT 字节和 = 省掉的回源下载量，MISS = 真实出口带宽压力；是对上汇报的核心数据 |
| `registry_request_duration_seconds` | histogram | `cache_status` | `$request_time` | **缓存价值证明**：HIT p95 vs MISS p95 对比，量化"缓存快了多少" |
| `registry_image_pulls_total` | counter | `repo`（URL path 提取） | `$request` | **按镜像聚合拉取热度**（替代 registry-exporter 的拉取聚合），容量规划 + 冷热分层依据 |

### 4.B registry stub_status —— nginx-prometheus-exporter 官方命名（6 条，零自研）

| 指标 | 类型 | **为什么** |
|---|---|---|
| `nginx_connections_active` | gauge | 当前并发——**日志给不了的核心缺口** |
| `nginx_connections_accepted` | counter | 累计接受连接 |
| `nginx_connections_handled` | counter | accepted−handled 长期差值 = 积压异常 |
| `nginx_connections_reading` | gauge | 正在读请求头；堆积 = 客户端/上游卡顿 |
| `nginx_connections_writing` | gauge | 正在回响应；长期高位 = 大对象传输拥塞 |
| `nginx_connections_waiting` | gauge | 空闲 keepalive 长连接，容量水位参考 |

### 4.C squid.mtail —— squid access.log/cache.log（沿用 cn12001 报表口径）

| 指标 | 类型 | labels | 来源 | **为什么** |
|---|---|---|---|---|
| `squid_requests_total` | counter | `result`(MISS/HIT/REVAL/ABORT/TIMEDOUT)、`domain` | access.log 判定字段 | 正好映射报表的 MISS_Cnt/HIT_Cnt/ABORT_Cnt 列；TIMEDOUT 直接对应 gy-001 黑洞事故的取证口径 |
| `squid_bytes_total` | counter | `result`、`domain` | access.log | 报表 *_MB 列，命中收益与回源压力 |
| `squid_cache_errors_total` | counter | `type` | cache.log 行 | ERROR/WARNING 行计数，供 §7 口径检查 |
| `squid_diskio_overloaded_total` | counter | — | cache.log 警告行，正则锚定稳定前缀 `/squidaio_queue_request: WARNING/`（措辞随版本变体，见 §7.1） | **磁盘 I/O 过载唯一信号**（aufs 无队列页面，见 §7.1）；MISS 风暴 → 并发写盘 → 延迟 → 客户端重试雪崩的先兆指标 |

**scheme 依赖**：`squid_aio_queue_depth`（cron-dump `mgr:aio`）**仅对 diskd 成立**；aufs 下没有队列 manager 页面，用上表 WARNING 行计数替代。S1-C3 实施前先确认 scheme。

### 4.D 已有保留 —— boynux squid-exporter :9301（不动）

fd 数、cache 磁盘使用率、cachemgr 命中快照、CPU/内存——上游维护零自研，快照层继续由它覆盖。

### 4.E 衍生告警（S2-P2 迁移目标形态）

```yaml
registry 命中率塌陷: rate(registry_cache_requests_total{cache_status="HIT"}) / rate(registry_cache_requests_total) < 0.3
registry 错误率:      rate(registry_cache_requests_total{code_class="5xx"}) / rate(registry_cache_requests_total) > 0.05
回源拥塞:            nginx_connections_writing > 500 (持续 5m)
squid 上游失败:      rate(squid_requests_total{result="TIMEDOUT"}) > 阈值
squid 磁盘 I/O 过载: rate(squid_diskio_overloaded_total) > 0 (持续 10m)
```

**cardinality 纪律**：`repo`/`domain` 在 CI 场景是有限集合（几十个），安全；禁止加 `image_digest`/`url` 等高基数 label——mtail 规则里就过滤掉。

## 5. 终态 sidecar 布局（registry-exporter 直接移除，2026-09-30 决策）

| 容器 | 终态 | 来源 |
|---|---|---|
| squid | 主体 | — |
| registry-proxy | 主体 + stub_status location | — |
| squid-exporter :9301 | squid cachemgr 快照 | boynux（上游） |
| mtail :3901 | 全部日志解析 + 轮转（squid + registry nginx）| 上游镜像 + 我们的热加载规则 |
| nginx-prometheus-exporter :9113 | registry nginx stub_status 快照 | `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/nginx/nginx-prometheus-exporter:1.5.3`（官方镜像已同步） |

- **5 容器**，自研采集代码 = 0，自研面仅剩 mtail 规则配置
- **为什么不把 nginx-prometheus-exporter 并进 mtail 容器**：容器内双进程使 restart 语义模糊，且需定制 mtail 镜像——违背"不为打包牺牲隔离与上游通道"，与 §2 单点论证自相矛盾

## 6. 实施计划（2026-09-30 制定）

目标：一个 release 内直接切到 §5 终态，registry-exporter **直接移除**，无过渡态。

```text
S0 镜像准备（先行，可并行）
  - nginx-prometheus-exporter 已就绪：swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/nginx/nginx-prometheus-exporter:1.5.3 ✅
  - 同步 mtail 上游镜像 → swr（版本锁定）

S1 chart 改动（单次 MR，chart 版本 +1）
  C0 store I/O scheme：**ufs → aufs（2026-09-30 决策，详见 §7.1）**
     - 改 chart squid.conf：`cache_dir ufs ...` → `cache_dir aufs ...`（其余参数不变，磁盘数据布局 ufs/aufs 完全相同，**切换不丢缓存**，无需清盘重建）
     - 动机：ufs 是主进程同步 I/O，MISS 风暴时磁盘读写直接阻塞 squid 事件循环（503 同级隐患）；aufs 线程池受益于 6u/12Gi 多核
     - 否决 diskd：需 SysV IPC/共享内存配额，容器内运维面大；SFS Turbo（网络文件系统）上其进程隔离优势体现不出来；aufs 对当前负载足够
     - 切换后抓一次真实 cache.log 的 WARNING 措辞，回填 4.C mtail 正则（先切 scheme 再定规则，不用猜）
  C1 registry-proxy：nginx 配置加 location /stub_status（bind 127.0.0.1，不走 Service 暴露）
  C2 新增 nginx-prometheus-exporter sidecar :9113（--nginx.scrape-uri 指向 localhost stub_status）
  C3 新增 mtail sidecar :3901，规则文件 ConfigMap 热加载：
       - squid.mtail：access.log + cache.log（cn12001 报表口径 + §4.C 磁盘 I/O 指标）
       - registry.mtail：nginx access.log（§4.A 四条指标）
       - 轮转接管：mtail 容器内跑 logrotate/crond 接管 emptyDir 日志轮转 ← 关键，涨盘防线不能断
  C4 删除 registry-exporter 容器及 :9302（与 C2/C3 同 release）
  C5 ports 声明清理

S2 Prometheus 侧（prometheus-agent values）
  P1 scrape jobs：+ :9113、+ :3901；- :9302
  P2 告警规则迁移：引用 registry-exporter 指标的规则 → §4.E 目标形态，逐条对账不允许静默失效
  P3 dashboard 变量/表达式同步

S3 发布与验证（values-driven，逐集群）
  V1 helm upgrade 单集群试点（gy-006）
  V2 对账检查：
       - targets 全 up（9301/9113/3901）
       - 指标对账：旧 :9302 拉取 counter vs mtail 同口径 counter（误差 <1%）
       - 轮转验证：access.log/error.log 正常 rotate、emptyDir 用量稳定
       - stub_status sanity check（Active connections ≈ 实际 ESTABLISHED 数）

风险点
  R1 轮转接管断档 → 涨盘（历史上踩过）：C3 轮转必须在 C4 删除前同 release 生效，V2 显式验证
  R2 mtail 规则口径漂移 → 告警误报/漏报：S3-V2 指标对账兜底
  R3 stub_status 暴露面：仅 localhost，不走 Service
  R4 磁盘 I/O 告警正则与真实措辞不匹配 → C0 切 aufs 后抓实测措辞回填 + 稳定前缀/宽匹配双保险
```

收敛的边界：squid 日志与 registry nginx 日志都在 Pod 内共享卷（emptyDir），tail 进程必须与写日志进程同 Pod——mtail 是此形态的下限（除非改走 stdout + 节点级 DaemonSet 采集）。

## 7. 指标口径与已知坑

### 7.1 AIO 队列：先查 store I/O scheme，再定指标来源

**scheme 决策（2026-09-30）：ufs → aufs，否决 diskd。**

| 候选 | 结论 | 理由 |
|---|---|---|
| ufs（现状） | ❌ 必须离开 | 主进程**同步** I/O，MISS 风暴时磁盘读写直接阻塞 squid 事件循环——503 同级隐患，流量小未暴露而已 |
| **aufs（选定）** | ✅ | pthread 线程池异步 I/O，受益于 6u/12Gi 多核；容器内无特殊要求；官方长期推荐的默认升级路径；**磁盘数据布局与 ufs 完全相同**（O'Reilly Squid Guide §8.4），切换无需清盘重建缓存 |
| diskd | ❌ 否决 | 每个 cache_dir 一个独立进程 + SysV IPC/共享内存队列，容器内要调 IPC 配额，运维面大；SFS Turbo（网络文件系统）上进程隔离优势体现不出来；对当前负载属于过度设计 |

**aufs 下的队列可观测性**（这正是否决 diskd 唯一的代价）：

| scheme | 队列统计 | 信号来源 | 指标方案 |
|---|---|---|---|
| **aufs** | **没有 manager 队列页面**——纯粹没人贡献这个页面，不是技术障碍 | cache.log 内部过载判定 WARNING 行 | squid.mtail 抓警告行 → `squid_diskio_overloaded_total`，按增长率告警 |
| diskd（仅对照） | `mgr:storedir` 页面给出队列统计 | 快照页 | cron-dump + squid.mtail |

WARNING 行**措辞随 squid 版本变体**，正则不能锚完整句：

```text
经典版：squidaio_queue_request: WARNING - Disk I/O overloading   （O'Reilly Squid Guide §8.4 收录）
变体：  squidaio_queue_request: WARNING - Queue congestion
远古版：aio_queue_request: WARNING - Running out of I/O theads   （squid 2.2.5 aiops.c）
```

→ mtail 规则锚定稳定前缀 `/squidaio_queue_request: WARNING/`，叠加宽匹配兜底（如 `/aio.*queue.*(overload|congestion)/i`）；C0 切完 aufs 后抓一次真实措辞回填。

- aufs 的 WARNING 是 squid 开发者内置的过载判定——他们假设"磁盘配好了队列不会长期堆积"，打条日志够用。对 SRE 来说这就是 aufs 下唯一可用的 I/O 过载信号，**必须**进 mtail 规则
- `squid_client_http_errors_total` 的烂口径同理：squid 把"客户端中途断开"也计成 error（统计**事务完整性**而非 HTTP 状态码）——语义不同不算 bug，但与现代 SRE 直觉相悖

### 7.2 client_http_errors_total 的口径陷阱

- ❌ 不要拿它当 5xx 错误率告警——CI 里构建脚本超时 kill 下载天然频繁，会天天误报
- ✅ HTTP 层错误用 access.log `$status`（`squid_requests_total{code_class="5xx"}`）；abort 单独列 `result="ABORT"`，只做容量/超时分析

## 8. 一句话总结

**"应该有一个全覆盖的 exporter"在架构上是对的，但正确路径是"成熟快照解析器 + 可热加载的日志解析器"，先并行后收敛；跳过中间态直接自研 all-in-one，等于在监控链路里引入一个需要频繁重新编译的单点。**
