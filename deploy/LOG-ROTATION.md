# 日志膨胀控制（Log Rotation）

> 本文件记录 squid-cache pod 内所有日志的**增长风险与处置方案**，是
> [`REGISTRY-EXPORTER-METRICS.md`](REGISTRY-EXPORTER-METRICS.md) §5.6 的独立展开。
> 相关实现：
> - `chart/templates/registry-exporter-configmap.yaml`（exporter 轮转）
> - `chart/templates/configmap.yaml`（squid `logfile_rotate`）
> - `chart/templates/statefulset.yaml`（emptyDir `sizeLimit`）
> - `chart/values.yaml`（`registryProxy.exporter.maxLogLines`）

## 1. 背景：日志为什么会无限膨胀

- nginx 容器（rpardini registry-proxy）**没有 logrotate / cron**，nginx 自身不轮转 access.log。
- emptyDir（`nginx-access-log`）**无自动清理**，默认落在节点本地磁盘。
- squid 容器 `/var/log/squid/*` 在**容器可写层（overlay）**，squid 默认不轮转日志。
- exporter 只增量解析日志，**从不主动删除**。

若不处理，日志会一路增长直到撑爆 emptyDir / 节点临时存储 → **pod 驱逐（eviction）**，
或撑大容器可写层、打满节点磁盘。

## 2. 日志全景盘点

| 日志 | 位置 | 增长 | 轮转机制 | 量级 |
|---|---|---|---|---|
| `/var/log/nginx/access.log` | emptyDir | ✅ 高（每请求一行 JSON ~300~400B） | **exporter 主动轮转**（主机制） | 数天触发一次 |
| `/var/log/nginx/error.log` | emptyDir | ✅ 低（仅错误时写） | exporter 轮转时顺带清空 | 可忽略 |
| `/var/log/squid/access.log` | 容器 rootfs | ✅ 高（每请求一行） | squid `logfile_rotate 10` | 实测 ~417KB/2h |
| `/var/log/squid/cache.log` | 容器 rootfs | ✅ 低 | 同上 | 实测 ~231KB/2h |
| stdout/stderr（`kubectl logs`） | CRI/kubelet | 有 CRI 管理 | CRI 日志轮转；随 pod 重建清空 | 跟随上述文件 |

> 注意：squid 的 access.log/cache.log 经 `tail -F` 引流到 stdout（`kubectl logs` 可见），
> 但**文件本身仍持续增长**（tail 只读不删），所以仍需 `logfile_rotate` 控制容器层大小。

## 3. 三层防护机制

### 3.1 exporter 主动轮转（主机制，防 access.log/error.log 膨胀）

`update_log` 每轮（默认 30s）检测：**文件行数超阈值** `REGISTRY_EXPORTER_MAX_LOG_LINES`
（默认 100000，约 30~40MB）时：

```bash
if [ "$n" -gt "$MAX_LOG_LINES" ]; then
  : > "$LOG_FILE"          # 清空 access.log
  : > "$ERROR_LOG" 2>/dev/null || true   # 顺带清空 error.log（错误日志可丢）
  echo 0 > "$OFFSET_FILE"  # 重置 offset，只重读 truncate 之后的新行
fi
```

**安全前提（三条缺一不可）：**

1. **不丢数据**：轮转前若未解析完，会先解析并追平 offset —— 清空的每一行都已计入计数；
2. **无空洞**：nginx 以 **O_APPEND** 打开 access.log，truncate 后从新文件末尾续写，不会产生前导 NUL/空洞；
3. **不重复计数**：offset 归 0 后，下次解析只重读 truncate **之后**新写入的行（这些行从未被解析），计数不重复。

### 3.2 emptyDir `sizeLimit` 兜底（防节点磁盘被打满）

```yaml
- name: nginx-access-log
  emptyDir:
    sizeLimit: 128Mi
```

若 exporter 轮转失效（脚本 bug / 容器异常），emptyDir 撑满 128Mi 即触发 **pod 驱逐**，
而不是无限增长打满节点磁盘。驱逐是比磁盘打满更可控、更可观测的失败模式。

### 3.3 squid `logfile_rotate`（防容器层膨胀）

```squid
# /var/log/squid/access.log 与 cache.log 各保留 10 份历史后轮转
logfile_rotate 10
```

- squid 启动时自动轮转（rename 旧日志为 `.0`/`.1`/... 并新建）；`tail -F` 会跟随新 inode，
  不影响 stdout 引流。
- 容器可写层随 pod 重建清空，10 份历史上限足够。

## 4. 配置项

| 项 | 位置 | 默认 | 说明 |
|---|---|---|---|
| `REGISTRY_EXPORTER_MAX_LOG_LINES` | `registryProxy.exporter.maxLogLines` | `100000` | access.log 轮转行数阈值 |
| `REGISTRY_EXPORTER_INTERVAL` | `registryProxy.exporter.interval` | `30` | 轮转检测频率（同解析频率） |
| emptyDir `sizeLimit` | `statefulset.yaml` 硬编码 | `128Mi` | 兜底上限 |
| `logfile_rotate` | `configmap.yaml` 硬编码 | `10` | squid 日志保留份数 |

## 5. 验证记录（2026-08-31, gy-006）

### 5.1 部署层生效

| 项 | 验证 | 结果 |
|---|---|---|
| squid.conf 含 `logfile_rotate 10` | `grep -c` 容器内 squid.conf | ✅ |
| emptyDir `sizeLimit: 128Mi` | `kubectl get sts -o jsonpath` | ✅ |
| env `REGISTRY_EXPORTER_MAX_LOG_LINES=100000` | sts env 注入 | ✅ |

### 5.2 轮转逻辑单元测试（debug pod，`MAX_LOG_LINES=3`）

| 步骤 | 期望 | 实测 |
|---|---|---|
| 注入 5 行（2 HIT + 3 MISS，含 1×404 + 1×500） | 计数 5/errors 2/hits 2/misses 3 | ✅ 完全一致 |
| 行数 5 > 阈值 3 → 轮转 | access.log 清空、offset 重置 | ✅ access.log = 0 行 |
| 再追加 2 行（1 HIT + 1 MISS 404） | 计数 7（不重复 5+7） | ✅ requests 5→7、hits 2→3、misses 3→4、errors 2→3；access.log=2 行、offset=2 |

轮转后**继续增量解析**且**不重复计数**，语义正确。

### 5.3 实测量级

squid 日志约 **650KB/2h**（access.log 417KB + cache.log 231KB）；nginx access.log 每请求一行
JSON 约 300~400B。轮转阈值 100000 行在正常 CI 流量下**数天触发一次**，成本可忽略。
