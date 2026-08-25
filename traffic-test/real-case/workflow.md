# Workflow: product-sample-test

连续采样 wlcb-001 集群上的真实 VCJob，自动去重，逐步注入 squid 代理验证，持续记录结果。

## 架构

```
                      ┌──────────────────────────┐
                      │   wlcb-001 集群 VCJob     │
                      └──────────┬───────────────┘
                                 │
                      ┌──────────▼───────────────┐
                      │  Queue 1: Collector       │
                      │  每 60s poll vj -A        │
                      │  捕获终态 job 的 YAML      │
                      │  输出: samples.tsv         │
                      │        vcjobs.json        │
                      │        yaml/*.yaml        │
                      └──────────┬───────────────┘
                                 │ 新终态 job
                      ┌──────────▼───────────────┐
                      │  Queue 2: Deduplicator    │
                      │  按流量模式 type_key 去重   │
                      │  新类型 → pending.json     │
                      │  输出: unique/*.yaml       │
                      │        dedup.json         │
                      │        pending.json       │
                      └──────────┬───────────────┘
                                 │ 取一个待测类型
                      ┌──────────▼───────────────┐
                      │  Queue 3: Reinjector      │
                      │  每 30min 提交一个         │
                      │  gen-reinject → apply     │
                      │  poll 直到终态             │
                      │  记录日志 + 结果           │
                      │  输出: done/<type_key>/   │
                      │        results.json       │
                      └──────────┬───────────────┘
                                 │
                      ┌──────────▼───────────────┐
                      │  Queue 4: Recorder        │
                      │  读取 results.json        │
                      │  生成 SUMMARY.md          │
                      │  生成 RESULTS.md          │
                      └──────────────────────────┘
```

## 队列说明

### Queue 1: Collector

- **文件**: `queue1-collect.py`
- **行为**: 无限循环，每 60s 调用 `kubectl get vj -A -o json`
- **终态捕获**: 当 job 第一次进入 `Completed/Failed/Aborted` 时，抓取其 YAML（去除 status、Karmada 注解、volatile metadata）
- **输出**: `samples.tsv`（采样流）、`vcjobs.json`（全量状态）、`yaml/<ns>-<name>.yaml`（干净的 YAML）
- **幂等**: 启动时自动加载已有的 `vcjobs.json`，断点续采
- **type_key 计算**: 每个 job 首次见到时（有 image 即算），生成 `type_key` 与 `type_desc` 存进 `vcjobs.json`（见 Queue 2 说明的粒度定义）。Queue 1 只负责**生成** type_key，**去重**发生在 Queue 2。

### Queue 2: Deduplicator

- **文件**: `queue2-dedup.py`
- **行为**: 轮询 `vcjobs.json` 中新增的终态 job，按 `type_key` **去重**（去重的唯一职责方）
- **type_key 粒度（流量模式）**: `sha1(镜像tag去日期 | 脚本类型 | 分支)`，把每条 PR 的噪声（MR 号 / run-id / 日期）折叠掉：
  - **镜像 tag 去日期**：去掉 `:YYYYMMDD` 后缀。例：`pytorch_2.7.1_a2_aarch64_builder:20260804` → `pytorch_2.7.1_a2_aarch64_builder`；非 builder 镜像（mindspeed 等）保留原 tag
  - **脚本类型**：从 args 里找 `UT/<script>.sh`（如 `pytorch_ut_general.sh` / `pytorch_ut_dist.sh` / `pytorch_ut_inductor.sh`），无则 `no-ut`
  - **分支**：从 args 里找 `merge.sh <branch>`（如 `master` / `v2.7.1` / `v2.11.0`），无则 `no-branch`
  - **效果**：pytorch 系列从「每 PR 唯一」折叠为 版本 × 脚本 × 分支 的约 16 个语义类（实测 13 类），mindspeed/argo 等各占 1-2 类
- **新类型**: 首次出现的 type_key → 写入 `pending.json`（待测队列），同时复制到 `unique/<ns>-<name>.yaml`
- **重复类型（replace 策略）**: 已存在的 type_key 再来新 job 时——**用新 job 的 YAML 替换旧代表**：
  - 覆盖 `unique/` 里该类型的 YAML（以新 job 为准，更新后的 PR 内容）
  - 更新 `dedup.json` 里的 entry（name/yaml/labels/terminal 等）
  - 若该类型**已在 pending.json 但未测试**，保持 pending 不变（类型已入队，只是代表换成最新的）
  - 若该类型**已在 results.json（测过）**，不重测，只更新 dedup/unique 记录
- **幂等**: 只处理 `vcjobs.json` 中新增的终态 job，不重复采集
- **输出**: `dedup.json`（全部唯一类型，重复时更新代表）、`pending.json`（待测队列）、`unique/*.yaml`（重复时被覆盖）

### Queue 3: Reinjector

- **文件**: `queue3-reinject.py`
- **行为**: 等待 `pending.json` 非空，然后每 30 分钟提交一个类型（FIFO），执行：
  1. 从 `pending.json` 出队该类型
  2. 写入 `results.json` 状态为 `running`
  3. **内置 YAML 转换**（不再依赖 `gen-reinject.py`）：
     - 去除 `generateName`，固定名称
     - 删除 `heartbeat` 容器
     - 主容器必须是 `name: ascend`（原始 VCJob 的约定，否则断言失败）
     - 注入 squid 代理环境变量 + `squid-ca` 卷挂载 + postStart 钩子
  4. `kubectl apply` 提交到 wlcb-001
  5. 每 30s 轮询 `{.status.state.phase}` 直到终态
  6. 抓取 pod 日志到 `done/<type_key>/`
  7. **判定 verdict**（见下），更新 `results.json` 记录终态、verdict、耗时、日志路径
- **关键**: 一次只提交一个，提交后等 30 分钟再取下一个。**重启安全**——启动时扫描 `results.json` 中状态为 `running` 的项，先检查它们是否已终态
- **等待 pending**: 每 60s 检查一次 `pending.json`，不空即开始处理（不阻塞 30 分钟）

#### Queue 3 判定逻辑（verdict）

**Volcano phase 不能直接当成功/失败信号**：源 YAML 自带 policy `event: PodFailed → action: AbortJob`（见 `unique/*.yaml`），主容器任何非零退出都会触发 AbortJob，把整个 job 标成 `Aborted`。很多 Aborted 其实是**成功跑完**（clone/submodule/编译/UT 全部通过，只差收尾 artifact 拷贝如 `cp CODE/time_data.json` 失败，或 `no need exec UT` 短路）。

因此 Queue 3 抓完日志后解析主容器日志得出 `verdict`：

| verdict | 含义 | 判定依据 |
|---|---|---|
| `passed` | 成功跑完，注入链路健康 | 日志无真实错误 且 命中成功标记（`no need exec UT` / `All tests passed` / `PASSED` / clone-submodule 输出） |
| `failed` | 真失败 | 日志命中致命标记（`Traceback` / `fatal:` / `Connection refused` / `proxy CONNECT failed` / `502/503/504` / `certificate verify failed` 等） |
| `unknown` | 无日志可判 | 日志缺失或为空 |

> 注意：`error:`、`squid`、`SSL` 等裸词**不算**失败标记——正常日志里会因环境变量（`SSL_CERT_FILE`）、挂载路径（`/etc/squid-ca`）、git 噪音出现，会误判。只认真正的 HTTP/网络/致命错误。
- **状态机**:

```
  pending.json         results.json
  ┌──────────┐        ┌──────────────┐
  │ type_key │──出队──→│ status:      │
  │ type_key │        │  "running"   │
  │ type_key │        ├──────────────┤
  └──────────┘        │ status:      │
                      │  "Completed" │
                      │  "Failed"    │
                      │  "Aborted"   │
                      ├──────────────┤
                      │ verdict:     │  ← 日志分析结果
                      │  passed      │    (true pass/fail signal)
                      │  failed      │
                      │  unknown     │
                      └──────────────┘
```

> `status` 是 Volcano 原始 phase；`verdict` 是 Queue 3 对日志的判定，才是真正的成功/失败信号。

### Queue 4: Recorder

- **文件**: `queue4-record.py`（可手动执行，也可常驻轮询）
- **行为**: 读取 `results.json` 和 `vcjobs.json`，生成：
  - `SUMMARY.md` — 全量采样统计 + 唯一类型统计
  - `RESULTS.md` — 已测类型的详细结果表（同 reinject/RESULTS.md 格式）
- **统计口径**: 成功/失败以 `verdict` 为准（`passed`=成功，`failed`=失败，`unknown`=待判），
  `phase` 仅作展示列。因为 Volcano 的 `PodFailed→AbortJob` policy 会把成功跑完的 job 也标成 Aborted。

## 启动方式

```bash
# 单进程启动（开发调试）
./queue1-collect.py --interval 60
./queue2-dedup.py --interval 30
./queue3-reinject.py --interval 1800  # 30min

# 一键启动所有队列（后台）
./run-pipeline.sh
```

## 文件结构

```
real-case/
├── workflow.md              # 本文件
├── run-pipeline.sh          # 一键启动脚本
├── queue1-collect.py        # 队列 1: 采集
├── queue2-dedup.py          # 队列 2: 去重
├── queue3-reinject.py       # 队列 3: 注入测试
├── queue4-record.py         # 队列 4: 记录
├── samples.tsv              # 采样流
├── vcjobs.json              # 全量 job 状态
├── dedup.json               # 去重结果
├── pending.json             # 待测队列（type_key 列表）
├── results.json             # 已测/正测结果（type_key → result）
├── SUMMARY.md               # 全量统计
├── RESULTS.md               # 测试结果表
├── yaml/                    # 采集的原始 YAML
├── unique/                  # 去重后的唯一 YAML
└── done/                    # 已测 job 的日志和结果
    └── <type_key>/
        ├── <name>-ri.yaml   # 注入后的 YAML
        ├── <name>.log       # 主容器日志
        ├── <name>-copy.log  # copy-artifact 日志
        └── result.json      # 结构化结果
```

## 依赖

- `kubectl` + `~/.kube/wlcb-001.yaml`（或 `KUBECONFIG` 环境变量）
- Python 3 + `pyyaml`
- 集群需有 `squid-ca-cert` secret（Queue 3 注入时需要）

## C 类（wget/GnuTLS 信任）修复验证记录

**案例**: `ff658798`（mindstudio-st-msprof:26.1.0-0708-test3，wget 下载 OBS 上的 .run 安装包）。

**现象**: 已走 squid 代理（日志 `Connecting to squid-cache.squid.svc.cluster.local:3128... connected`），
但 wget 底层 GnuTLS 报 `certificate is not trusted / doesn't have a known issuer`。
wget 不读 `SSL_CERT_FILE`/`CURL_CA_BUNDLE`（curl/openssl 变量），只认 GnuTLS 系统信任库。

**修复（C 类）**: 注入 `squid-ca` 卷（`squid-ca-cert` secret）+ postStart 将 squid CA 装入
系统信任库（`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract`）。

**验证结果（2026-08-21）**:

| 项 | 结果 |
|---|---|
| `/etc/squid-ca/squid-ca.pem` 挂载 | ✅（secret 存在时） |
| `update-ca-trust extract` | rc=0 |
| wget via squid 下载 10.7MB .run | ✅ 16.5 MB/s, `DONE rc=0` |

> ⚠️ 前置条件：`squid-ca-cert` secret 必须存在于目标命名空间。若缺失，
> `optional: true` 卷挂载为空 → `/etc/squid-ca/squid-ca.pem` 不存在 → 仍报信任错误。
> 重跑前先确认 secret 已注入（见任务 #19 helm upgrade）。