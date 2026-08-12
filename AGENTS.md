# AGENTS.md — 给 AI Agent 的仓库指南

本仓库用于**持续调研、验证并留档 Squid + BuildKit + metrics + docker cache 这一整套 CI 缓存代理的部署逻辑、架构、组件**，
涵盖 HA 验证、benchmark、以及最终生产部署形态。若你是 agent，按下面信息操作即可，无需重新推理架构。

## 仓库定位：两部分

| | 内容 | 目录 | 修改约束 |
|---|---|---|---|
| **① 调研 / 方案 / 测试验证** | 大家可**按需修改补充** | 见下 | 自由改，改完保证测试通过 |
| **② 实际部署 yaml** | **最终部署形态**，架构需**仔细审视** | `deploy/` | 慎改；先读 `deploy/DEPENDENCIES.md` |

### ① 调研 / 方案 / 测试验证

- `solution.md` — 方案选型与架构（keepalived+HAProxy+Squid HA、K8s 原生 HA）
- `PRODUCTION.md` — 生产部署指南（测试↔生产配置差异）
- `sizing/` — 规格推演模型 + 实测校准（CPU/内存/带宽/磁盘）
- `reports/` — benchmark 报告
- **Docker Compose HA 套件**：`docker-compose.yml` + `configs/` + `docker/` + `scripts/` + `tests/`
- **K8s HA 套件**：`k8s/`（多副本 + Service + kill/stop pod 验证）
- **BuildKit 扩展**：`buildkit/`（RUN 内 HTTPS 经内建代理链到 Squid 做代理+缓存，默认不随主套件跑）

### ② 实际部署（`deploy/`）

gy-006 集群在跑的**真实生产部署**：Helm chart（StatefulSet，每 Pod = squid[SSL-Bump] + registry-proxy[rpardini] + squid-exporter）+ 16 个 CI 工具缓存 e2e 测试。
- 入口：`deploy/DEPLOY.md`（部署 + CI 注入配方）
- 架构：`deploy/SQUID-OVERVIEW.md`
- **依赖与独立部署 gap：`deploy/DEPENDENCIES.md`**（当前非自包含，依赖内部 CA/私有镜像/StorageClass/Vault）
- 线上验证记录：`deploy/VERIFICATION.md`
- ⚠️ chart/release 名 `squid-rpardini` 与 `ascend-ci-deployment` 生产源一致，**不随目录改名**。

---

## Docker Compose HA 套件：一键操作

```bash
./scripts/setup.sh      # 生成 CA + 构建 + 启动,约 40s
./scripts/test-all.sh   # 运行 6 项测试
./scripts/cleanup.sh    # docker compose down -v
```

### 如何判断成败（机器可读）

- `test-all.sh` 的**退出码**：`0`=全通过，`1`=有失败。优先用它。
- `result.json`：结构化结果，字段 `all_passed`（bool）、`passed`/`failed`/`total`、`tests[]`。
- `test-report.txt`：人类可读详情，含每步 `✓`/`✗`。

```bash
./scripts/test-all.sh && echo "ALL PASS" || echo "SOME FAIL"
jq -e '.all_passed' result.json
```

### 关键常量（Compose 套件）

| 项 | 值 |
|----|----|
| VIP（客户端入口） | `172.30.0.100:3128` |
| Docker 网络 | `haproxy_ha_squid_net`（子网 172.30.0.0/24） |
| Squid 容器 | squid1/2/3 → .11/.12/.13 |
| HAProxy 节点 | haproxy-node1(.21, MASTER) / haproxy-node2(.22, BACKUP) |
| 测试 URL 配置 | `configs/test.env` |

### 如何扩展测试

1. 在 `tests/` 新建 `NN-xxx.sh`（NN 为两位数字，决定执行顺序）。
2. 首行 `source "$(dirname "$0")/lib.sh"` 引入断言库。
3. 用 `assert_code "标签" 200 "$(proxy_http_code "$URL")"` 做断言——非期望值会 `exit 1`。
4. `test-all.sh` 自动发现 `tests/[0-9]*.sh`，无需注册。

`lib.sh` 提供：`proxy_http_code URL`、`proxy_https_code URL`、`assert_code 标签 期望 实际`、`assert_true 标签 命令...`。
改测试目标只改 `configs/test.env`，不要改脚本。大文件测缓存效果更明显。

## 常见故障排查

见 `TROUBLESHOOTING.md`。最常见：容器重启后 keepalived 因 PID 残留起不来——用 `docker compose restart <node>` 而非 `docker start`。

## 不要做

- 不要 `git add configs/certs/*`（私钥，已被 .gitignore 忽略）。
- 不要把 Compose 套件里的 `ssl_bump bump all` 当生产配置引用（生产走域名白名单）。
- 不要在测试脚本末尾无条件 `echo PASS`——必须用 `assert_*` 让失败真正 exit 1。
- 不要为了给目录改名而改 `deploy/` 里的 chart/release 名 `squid-rpardini`（会破坏线上 ArgoCD 对应关系）。
