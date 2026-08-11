# AGENTS.md — 给 AI Agent 的仓库指南

本仓库验证 **Squid HA 缓存代理方案**（keepalived + HAProxy + Squid + SSL Bump）。
若你是 agent，按下面信息操作即可，无需重新推理架构。

## 这是什么

- **目的**：端到端验证 Squid HTTP/HTTPS 缓存代理的高可用性与缓存正确性。
- **形态**：Docker Compose 起 5 个容器（3 Squid + 2 HAProxy/keepalived 节点），一组带断言的 bash 测试。
- **不是什么**：不是生产部署包；`ssl_bump bump all` 仅测试用途。

## 一键操作

```bash
./scripts/setup.sh      # 生成 CA + 构建 + 启动,约 40s
./scripts/test-all.sh   # 运行 6 项测试
./scripts/cleanup.sh    # docker compose down -v
```

## 如何判断成败（机器可读）

- `test-all.sh` 的**退出码**：`0`=全通过，`1`=有失败。优先用它。
- `result.json`：结构化结果，字段 `all_passed`（bool）、`passed`/`failed`/`total`、`tests[]`。
- `test-report.txt`：人类可读详情，含每步 `✓`/`✗`。

判断示例：
```bash
./scripts/test-all.sh && echo "ALL PASS" || echo "SOME FAIL"
# 或
jq -e '.all_passed' result.json
```

## 关键常量

| 项 | 值 |
|----|----|
| VIP（客户端入口） | `172.30.0.100:3128` |
| Docker 网络 | `haproxy_ha_squid_net`（子网 172.30.0.0/24） |
| Squid 容器 | squid1/2/3 → .11/.12/.13 |
| HAProxy 节点 | haproxy-node1(.21, MASTER) / haproxy-node2(.22, BACKUP) |
| 测试 URL 配置 | `configs/test.env` |

## 如何扩展测试

1. 在 `tests/` 新建 `NN-xxx.sh`（NN 为两位数字，决定执行顺序）。
2. 首行 `source "$(dirname "$0")/lib.sh"` 引入断言库。
3. 用 `assert_code "标签" 200 "$(proxy_http_code "$URL")"` 做断言——非期望值会 `exit 1`。
4. `test-all.sh` 自动发现 `tests/[0-9]*.sh`，无需注册。

`lib.sh` 提供：`proxy_http_code URL`、`proxy_https_code URL`、`assert_code 标签 期望 实际`、`assert_true 标签 命令...`。

## 修改测试目标

只改 `configs/test.env`，不要改脚本。大文件测缓存效果更明显。

## 常见故障排查

见 `TROUBLESHOOTING.md`。最常见：容器重启后 keepalived 因 PID 残留起不来——用 `docker compose restart <node>` 而非 `docker start`。

## 不要做

- 不要 `git add configs/certs/*`（私钥，已被 .gitignore 忽略）。
- 不要把 `ssl_bump bump all` 当生产配置引用。
- 不要在测试脚本末尾无条件 `echo PASS`——必须用 `assert_*` 让失败真正 exit 1。
