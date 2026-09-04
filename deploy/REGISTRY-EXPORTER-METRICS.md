# registry-proxy 指标设计（Registry Exporter Metrics）

> 本文描述 registry-proxy（rpardini/docker-registry-proxy，nginx 镜像缓存）监控指标的**设计**：
> 指标清单、语义、实现机制、采集方式与已知局限。
> 对应实现：`chart/templates/registry-exporter-configmap.yaml` + `chart/templates/statefulset.yaml`
> 端口：`9302`（Service 名 `regmetrics`）。
> 验证记录见 `VERIFICATION.md`；squid 主代理指标（9301，squid-exporter）不在本文范围。

## 1. 背景与目标

rpardini/docker-registry-proxy **没有原生 Prometheus /metrics**（实测 `/metrics` 只是 banner）。
镜像内 `access.log` 默认符号链接到 `/dev/stdout`，pod 内无法作为文件读取。

目标：为 registry-proxy 提供**与 squid-exporter 对齐的缓存指标**（请求计数 / 命中率 / 流量 /
错误 / 存储水位），让运维在中央 Prometheus 一处对比 squid 主代理与 registry 缓存两个链路的健康度。

## 2. 架构与数据流

```
docker / buildkit / vcjob 客户端
   │ CONNECT registry-1.docker.io:443（走 squid，registry 域 splice）
   ▼
squid :3129（TCP 隧道直通，不解密）
   ▼
registry-proxy :3128  ── proxy_director 层（access_log off，CONNECT 隧道不透传日志）
   │ 命中缓存 registry（docker.intercept.map）→ 内部转发 127.0.0.1:443
   ▼
caching layer :443  ── TLS 终止（rpardini CA）→ 按 $host 代理上游 + blob 缓存
   │ access_log /var/log/nginx/access.log  tweaked（JSON，含 HIT/MISS）
   ▼
emptyDir 共享卷 /var/log/nginx
   │
   ▼
registry-exporter 容器（alpine）
   ① 每 30s 增量解析 access.log → 计数器（requests/hits/misses/bytes/errors/状态码）
   ② 每 600s 慢采样 blob 文件数（find 大缓存慢）
   ③ 每次 scrape 时 df 取磁盘水位
   ▼
写 /metrics/metrics → busybox nc 一次性 HTTP 服务 :9302
   ▼
prometheus-agent scrape（新增 job）→ remote_write → 中央 Prometheus
```

关键点：**nginx 的 caching layer 才是记日志的地方**（`access_log tweaked`），
proxy_director 层（3128）对 CONNECT 隧道 `access_log off` —— 这就是为什么日志里
只有**被缓存处理的 registry 请求**，而透传的非缓存 registry（splice 到上游直连）不记录。
这也意味着指标口径 = **缓存层经手的请求**（HIT/MISS 全部来自 `upstream_cache_status`）。

## 3. 指标清单

命名空间：`registry_proxy_*`。全部为**单值无标签**（除 responses 带 `code` 标签）。
`counter` 类：只增不减（重启/轮转会归零重来）；`gauge` 类：瞬时值。

| 指标 | 类型 | 语义 | 数据来源 |
|---|---|---|---|
| `registry_proxy_http_requests_total` | counter | 缓存层收到并完成的 HTTP 请求总数 | access.log 行数 |
| `registry_proxy_http_kbytes_out_total` | counter | 出站响应体字节数（KB，`body_bytes_sent` 累加 /1024） | access.log `bytes_sent` |
| `registry_proxy_http_errors_total` | counter | status >= 400 的响应数 | access.log `status` |
| `registry_proxy_http_hits_total` | counter | 缓存命中数（`upstream_cache_status=HIT`） | access.log `upstream_cache_status` |
| `registry_proxy_http_misses_total` | counter | 回源/未命中数（`upstream_cache_status` 非空且非 HIT） | 同上 |
| `registry_proxy_http_responses_total{code="2xx/3xx/4xx/5xx"}` | counter | 按状态码分类的响应分布 | access.log `status` |
| `registry_proxy_cache_blobs_total` | gauge | 缓存 blob 文件数（低频采样） | `find $CACHE_DIR` |
| `registry_proxy_cache_tmp_files_total` | gauge | 下载中的 `.tmp` 文件数（低频采样） | `find $CACHE_DIR -name '*.tmp'` |
| `registry_proxy_cache_bytes_total` | gauge | 缓存目录磁盘用量（字节，瞬时 `df`） | `df $CACHE_DIR` |
| `registry_proxy_cache_max_bytes_total` | gauge | `proxy_cache_path max_size`（字节，由 `registryProxy.cacheMaxSize` 解析） | 环境变量 `REGISTRY_CACHE_MAX` |
| `registry_proxy_cache_usage_ratio` | gauge | 磁盘水位占比（`bytes / max_bytes`，0~N） | 上面两者相除 |

### 派生用法（Grafana/PromQL）

```promql
# 缓存命中率（近 5 分钟）
sum(rate(registry_proxy_http_hits_total[5m]))
  / sum(rate(registry_proxy_http_requests_total[5m]))

# 未命中率（回源压力）
sum(rate(registry_proxy_http_misses_total[5m]))
  / sum(rate(registry_proxy_http_requests_total[5m]))

# 错误率
sum(rate(registry_proxy_http_errors_total[5m]))
  / sum(rate(registry_proxy_http_requests_total[5m]))

# 出站流量速率
sum(rate(registry_proxy_http_kbytes_out_total[5m])) * 8 * 1024  # bps

# 磁盘水位告警
registry_proxy_cache_usage_ratio > 0.9
```

## 4. 与 squid-exporter 指标映射

squid-exporter（9301）与 registry-exporter（9302）的对比，便于同一面板对齐：

| squid-exporter（主代理） | registry-exporter（镜像缓存） | 说明 |
|---|---|---|
| `squid_client_http_requests_total` | `registry_proxy_http_requests_total` | 请求总数 ✅ |
| `squid_client_http_kbytes_out_kbytes_total` | `registry_proxy_http_kbytes_out_total` | 出流量 ✅ |
| `squid_client_http_kbytes_in_kbytes_total` | ❌ 无 | nginx `tweaked` 日志**未记录** `request_length`，拿不到入流量 |
| `squid_client_http_errors_total` | `registry_proxy_http_errors_total` | 错误数 ✅ |
| `squid_client_http_hits_total` | `registry_proxy_http_hits_total`（+ `_misses_total`） | 命中/未命中 ✅ |
| `squid_server_http_*` | `registry_proxy_http_responses_total{code=...}` + `registry_proxy_cache_*` | 状态码分布 + 缓存存储水位（部分对齐） |

> ⚠️ 口径差异：squid 主代理的 registry 镜像流量走 splice（TCP_TUNNEL），**不计入**
> `squid_client_http_*`；镜像缓存效果**只能**看 registry-proxy 这组指标。

## 5. 实现机制

### 5.1 日志来源（ConfigMap 与 emptyDir 挂载）

- chart 在 StatefulSet 里加 `nginx-access-log` 共享 emptyDir，**同时挂到 registry-proxy 和
  registry-exporter 两个容器**的 `/var/log/nginx`，遮住镜像里 `access.log → /dev/stdout` 的符号链接。
- nginx caching layer 的 `access_log /var/log/nginx/access.log tweaked`（JSON，`escape=json`）
  因此落到真实文件，exporter 可读。
- 日志字段（`log_format tweaked`）：`access_time / upstream_cache_status / method / uri /
  request_type / status / bytes_sent / upstream_response_time / host / proxy_host / upstream`。

### 5.2 增量解析（防丢防重）

- 维护 offset 文件 `.exporter.offset` 记录已解析行号；每次用 `tail -n +$((offset+1))` 只读新行。
- 日志轮转/截断时（`offset > 当前行数`）自动归零重扫，避免死循环。
- 解析用 `awk` 正则提取 `"status"`、`"bytes_sent"`、`"upstream_cache_status"` 三个字段
  （均为无转义引号的简单值，正则足够）。
- 计数语义：`cs=="HIT"` → hit；`cs!=""`（如 `MISS`/`EXPIRED`）→ miss；`cs==""`（空，非缓存响应）
  → 只计请求，不计 hit/miss。

### 5.3 状态持久化与重启语义

- 计数 `.exporter.counters` 与 offset 存于**共享 emptyDir**（`/var/log/nginx/.exporter.*`）：
  - exporter 容器崩溃重启 → 状态不丢（emptyDir 在 pod 生命周期内保留）；
  - pod 重建（滚动升级/重启）→ emptyDir 清空，计数器归零（预期行为，同 squid-exporter）。
- `load_state` 在计数文件首次不存在时必须返回 0（脚本 `set -e`，否则静默 exit 1）。

### 5.4 采样策略（性能）

- **快循环（30s，可配 `REGISTRY_EXPORTER_INTERVAL`）**：增量解析日志 + `df` 磁盘水位。
- **慢循环（600s，可配 `REGISTRY_EXPORTER_BLOB_INTERVAL`）**：`find` 大缓存（100Gi+）很慢，
  只低频后台采样 blob/.tmp 文件数并落盘，避免阻塞主循环。
- **存储水位**：`df` 瞬时读取（快）；**blob 数**用慢采样缓存值（避免每次 scrape 全目录扫）。

### 5.5 HTTP 服务（busybox nc）

- alpine 的 busybox **没有 `httpd` applet**（实测 `httpd: applet not found`），故用 `nc`：
  每次连接吐出 `/metrics/metrics` 文件（`HTTP/1.1 200 OK` + `Connection: close`），
  连接关闭后 nc 退出并重新监听，循环服务。
- 不能加 `-w`（会让 nc 空等超时每秒关闭，产生拒连窗口）；不能加 `-q`（该 busybox 不支持，报错刷屏）。

### 5.6 日志膨胀控制（轮转）

nginx 容器内无 logrotate、emptyDir 无自动清理，日志若不处理会无限增长触发 pod 驱逐。
三层防护（exporter 主动轮转 + emptyDir `sizeLimit` + squid `logfile_rotate`）：
详见 **[LOG-ROTATION.md](LOG-ROTATION.md)**（含日志全景盘点、安全前提、配置项与验证记录）。

## 6. 采集配置（Prometheus）

### 6.1 数据链路

```
squid-cache.squid:9302 (regmetrics, 双活各一个)
   │ prometheus-agent scrape（新增 job: registry-proxy, 60s）
   ▼
中央 Prometheus http://113.44.182.82:9090  ← remote_write
```

### 6.2 scrape job（追加到 agent ConfigMap）

```yaml
- job_name: registry-proxy
  metrics_path: /metrics
  static_configs:
  - targets: ['squid-cache.squid.svc.cluster.local:9302']
    labels:
      service: registry-proxy
```

双活说明：`squid-cache.squid:9302` 是 ClusterIP Service，会负载均衡到两个 pod；
若需要按 pod 区分（squid-cache-0/1），改用 headless 端点逐个加 target，
或依赖指标自带 `instance`/`pod` 标签（本 exporter 未加，需在 scrape 层 `relabel` 补充）。

### 6.3 生效方式（重要教训）

修改 agent ConfigMap 后**不会自动生效**，需热加载（agent 已带 `--web.enable-lifecycle`）：

```bash
kubectl -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- --post-data="" "http://127.0.0.1:9090/-/reload"

# 验证运行配置已含 registry-proxy job
kubectl -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- "http://127.0.0.1:9090/api/v1/status/config" | grep -c "job_name: registry-proxy"
```

## 7. 局限与已知问题

| # | 局限 | 影响 | 备注 |
|---|---|---|---|
| 1 | 无 `kbytes_in`（日志无 `request_length`） | 入流量无法统计 | 与 squid 比少一项 |
| 2 | 只统计**缓存层**经手请求（CONNECT 隧道本身 `access_log off`） | 非缓存 registry（直连透传）不计入 | 与 squid `TCP_TUNNEL` 不计入同理 |
| 3 | 上游超时（如 006 直连 registry-1.docker.io 504）会记为 `miss` + `5xx` | 未命中率/错误率虚高 | 反映真实回源失败，属正确信号 |
| 4 | `df` 在 sfsturbo 共享存储上读到的是**整盘用量**（非单 PVC 配额） | `cache_bytes_total` 可能远超 `max_bytes`，`usage_ratio` 可能 >1 | 共享存储场景下该指标仅作趋势参考 |
| 5 | 计数器随 pod 重建归零 | 跨重启的累计值丢失 | 用 `rate()`/`increase()` 而非绝对值 |
| 6 | blob 采样 10 分钟一次 | blob 数指标有最多 10 分钟延迟 | 避免大目录 `find` 阻塞 |
| 7 | 日志无限膨胀风险 | 打满 emptyDir/节点磁盘 | 已解决：exporter 轮转 + emptyDir `sizeLimit` + squid `logfile_rotate`（见 §5.6） |

## 8. 验证记录（2026-08-31, gy-006）

实测数据（squid-cache-0 重启后，经 squid 走代理发 3 条真实请求，均为上游 504）：

| 指标 | 实测值 | 期望 |
|---|---|---|
| `registry_proxy_http_requests_total` | 3 | 3 ✅ |
| `registry_proxy_http_errors_total` | 3 | 3（3×504）✅ |
| `registry_proxy_http_misses_total` | 2 | 2（MISS + MISS；空 `cs` 不计）✅ |
| `registry_proxy_http_responses_total{code="5xx"}` | 3 | 3 ✅ |
| `registry_proxy_http_hits_total` | 0 | 0（均未命中）✅ |
| `registry_proxy_cache_max_bytes_total` | 107374182400 | 100Gi ✅ |
| 9302 HTTP 端点 | 返回完整指标 | ✅ |
| Service `squid-cache.squid:9302` | 可达（轮询到另一 pod 时为 0，符合预期） | ✅ |

HIT 路径另经 debug pod 注入 1 HIT + 1 MISS 测试日志验证解析正确（`hits=1, misses=1, 2xx=2`）。

### 8.1 日志轮转验证（2026-08-31，debug pod，`MAX_LOG_LINES=3`）

| 步骤 | 期望 | 实测 |
|---|---|---|
| 注入 5 行（2 HIT + 3 MISS，含 1×404 + 1×500） | 计数 5/errors 2/hits 2/misses 3 | ✅ 完全一致 |
| 行数 5 > 阈值 3 → 轮转 | access.log 清空、offset 重置 | ✅ access.log = 0 行 |
| 再追加 2 行（1 HIT + 1 MISS 404） | 计数 7（不重复 5+7），errors 3 | ✅ requests 5→7、hits 2→3、misses 3→4、errors 2→3，access.log=2 行、offset=2 |

轮转后**继续增量解析**且**不重复计数**，语义正确。
