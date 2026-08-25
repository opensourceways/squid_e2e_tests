# 部署与监控验证记录（gy-006 集群）

> 记录 squid-rpardini 在 gy006 的部署状态与监控接线过程。最后更新：2026-08-11。

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
