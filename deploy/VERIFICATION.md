# 部署与监控验证记录（gy-006 集群）

> 记录 squid-rpardini 在 gy006 的部署状态与监控接线过程。最后更新：2026-08-31。

## 1. 部署状态（已上线）

| 项 | 状态 |
|---|---|
| workload | StatefulSet `squid-cache`，replicas=2（双活）|
| Pods | `squid-cache-0` / `squid-cache-1`，3/3 Running（squid + registry-proxy + squid-exporter）|
| 独立 PVC | 每副本自带 cache(50Gi) + registry-cache(200Gi)，RWO |
| 入口 | Service `squid-cache:3128`（ClusterIP 负载均衡），`squid-cache-headless`（StatefulSet 身份）|
| 探针 | readiness HTTP cachemgr `/squid-internal-mgr/info:3129`（5s×2）|
| 版本 | chart 0.1.3（详见 chart/Chart.yaml）|

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid get pods -l app=squid-cache -o wide
```

## 2. 监控接线（已生效）

### 2.1 数据链路

```
squid-cache.squid:9301 (squid-exporter, 双活各一个)
        │ prometheus-agent scrape（job: squid, 60s）
squid-cache.squid:9302 (registry-exporter, 双活各一个)
        │ prometheus-agent scrape（job: registry-proxy, 60s）
        ▼
中央 Prometheus http://113.44.182.82:9090  ← remote_write（basic_auth: agent）
```

### 2.2 关键教训：ConfigMap 更新 ≠ 自动生效

agent 运行配置**不会**随 ConfigMap 自动加载。修改
`monitoring/config-for-guiyang-006/prometheus-agent-configmap-patch.yaml` 并 apply 后，
必须热加载：

```bash
kubectl -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- --post-data="" "http://127.0.0.1:9090/-/reload"

# 验证运行配置已含 squid job（应为 1）
kubectl -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- "http://127.0.0.1:9090/api/v1/status/config" | grep -c "job_name: squid"
```

agent 参数已带 `--web.enable-lifecycle`，`/-/reload` 直接可用。

### 2.3 实测指标（2026-08-11，squid-cache-0 部署约 1h）

| 指标 | 值 | 说明 |
|---|---|---|
| `squid_client_http_requests_total` | 1020 | 请求总数（中央可查）|
| `squid_client_http_kbytes_out_kbytes_total` | 785 | 出站响应 KB |
| `squid_client_http_kbytes_in_kbytes_total` | 277 | 入站请求 KB |
| `squid_client_http_errors_total` | 152 | 错误数 |
| `squid_client_http_hits_total` | 0 | 新部署/流量少，缓存冷启动中 |
| `squid_server_http_*` | 0 | 注意：registry 镜像流量走 TCP_TUNNEL（splice），不计入 |

### 2.4 查询入口

- **squid 指标**：中央 `http://113.44.182.82:9090/query`（g0.expr=PromQL）


常用 PromQL：

```promql
# 缓存命中率（5m）
rate(squid_client_http_hits_total{job="squid"}[5m])
/ rate(squid_client_http_requests_total{job="squid"}[5m])

# 代理出站带宽 KB/s
rate(squid_client_http_kbytes_out_kbytes_total{job="squid"}[5m])

# 回源带宽 KB/s（缓存节省量）
rate(squid_server_http_kbytes_in_kbytes_total{job="squid"}[5m])
/ rate(squid_client_http_kbytes_out_kbytes_total{job="squid"}[5m])
# 双副本请求分布
sum by (instance) (squid_client_http_requests_total{job="squid"})
```

### 2.5 registry-proxy 指标采集（9302，待接线）

rpardini 无原生 /metrics，chart 内已部署 **registry-exporter** sidecar（端口 9302，
指标前缀 `registry_proxy_*`，设计见 `REGISTRY-EXPORTER-METRICS.md`，日志膨胀控制见
`LOG-ROTATION.md`）。已实测 `/metrics` 正常（增量解析 nginx access.log 出
requests/errors/hits/misses/bytes_out/状态码分布 + 缓存 blob 数/磁盘水位）。

**① 修改 agent ConfigMap**，在 `scrape_configs` 里 `squid` job 后加（headless DNS，双活
两副本独立计数、`rate()` 不串实例）：

```yaml
      - job_name: registry-proxy
        static_configs:
          - targets:
              # headless DNS: 与 squid 同款, 每副本独立 exporter (counter 独立, rate 不串实例)
              - squid-cache-0.squid-cache-headless.squid:9302
              - squid-cache-1.squid-cache-headless.squid:9302
            labels:
              cluster: guiyang-006
```

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml -n monitoring edit cm prometheus-agent-config
```

**② 热加载 + 验证**（ConfigMap 更新不自动生效，见 §2.2）：

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- --post-data="" "http://127.0.0.1:9090/-/reload"

# 运行配置已含 registry-proxy（应为 1）
kubectl --kubeconfig ~/.kube/gy-006.yaml -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- "http://127.0.0.1:9090/api/v1/status/config" | grep -c "job_name: registry-proxy"

# 两个 target 均 UP
kubectl --kubeconfig ~/.kube/gy-006.yaml -n monitoring exec <prometheus-agent-pod> -- \
  wget -qO- "http://127.0.0.1:9090/api/v1/targets" | grep -A2 "registry-proxy"
```

**③ 常用 PromQL**（中央 `http://113.44.182.82:9090/query`）：

```promql
# 镜像缓存命中率（5m）
sum(rate(registry_proxy_http_hits_total{job="registry-proxy"}[5m]))
  / sum(rate(registry_proxy_http_requests_total{job="registry-proxy"}[5m]))

# 回源（未命中）压力
sum(rate(registry_proxy_http_misses_total{job="registry-proxy"}[5m]))

# 磁盘水位告警（>0.9 告警；sfsturbo 共享盘见 REGISTRY-EXPORTER-METRICS.md §7-4 口径）
registry_proxy_cache_usage_ratio > 0.9

# 双副本请求分布（对比 0/1 负载）
sum by (instance) (registry_proxy_http_requests_total{job="registry-proxy"})
```

> ⚠️ 口径差异：squid 主代理的 registry 流量走 splice（TCP_TUNNEL），**不计入**
> `squid_client_http_*`；镜像缓存效果**只能**看 `registry_proxy_*` 这组指标。

## 3. 集群出口带宽（可选，无需新组件）

node-exporter 已被 agent 抓取（`172.22.6.177/211/52:9100`），在中央实例查物理网卡：

```promql
sum(rate(node_network_transmit_bytes_total{cluster="guiyang-006", device=~"enp.*|eth.*"}[5m]))
# 物理卡名示例: enp67s0f5（排除 veth_*/br_plc_*/lo/vxlan_sys_4789）
```

## 4. 故障切换演练（待做）

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid delete pod squid-cache-0
# 预期：squid-cache-1 全程 Ready，请求零中断（双活）
# 检查：kubectl -n squid get pods -l app=squid-cache
```
