# tracfic-test — 模拟 CI 并发流量的 Squid 流量模式测试

在 gy-006 集群（namespace `squid`）用 **10 个并行 Volcano 任务**模拟真实 CI 并发，
通过 squid SSL-Bump 代理访问 `gitcode.com/Ascend` 真实仓库，观察 squid 的流量模式
（回源 vs 缓存命中、并发带宽）。

## 场景

| 场景 | 任务数 | 流量形态 | 期望模式 |
|---|---|---|---|
| `pip-traffic.yaml` | 10 | clone pytorch (67MB) + pip 下载 12 个真实包（含 torch 2.10.0 aarch64 wheel 146MB） | **wheel 可缓存**：第 1 个任务回源 146MB，后 9 个任务 squid HIT（`.whl` refresh_pattern 100% 缓存）→ 回源流量 ≈ 1× wheel，出站流量 ≈ 10× wheel |
| `git-clone-traffic.yaml` | 10 | `git clone --depth 1 gitcode.com/Ascend/pytorch`（~67MB pack/任务） | **git pack 不可缓存**（默认 `refresh_pattern . 0 20% 4320`，smart-HTTP pack 无 Last-Modified）→ 10 个任务全部回源，回源 ≈ 10×67MB，无缓存增益 |

每个 pod 打印：clone/pip 耗时、下载字节、聚合带宽、`DURATION`。

## 真实负载来源

- 仓库：`gitcode.com/Ascend/pytorch`（华为 Ascend PyTorch fork，审计见 `deploy/tool/ascend-org-build-tools-report.md`）
- pip 包：pytorch 真实 `requirements.txt`（pyyaml/setuptools/auditwheel）+ Ascend CI 常用依赖
  （numpy/psutil/requests/tqdm/regex/pygments/flask/fastapi/pydantic）+ `torch==2.10.0`
  （cp311-aarch64 wheel 146MB，镜像已验证）
- pip 索引：`repo.huaweicloud.com/repository/pypi/simple`（Ascend CI 实际使用的镜像）

## 用法

```bash
# 提交 git clone 流量测试（10 任务）+ 后台监控中央 Prometheus 900s
./run.sh git --monitor=900

# 提交 pip 流量测试
./run.sh pip

# 两个场景顺序执行
./run.sh both --monitor=1800
```

Kubeconfig 默认 `~/.kube/gy-006.yaml`（`KUBECONFIG` 可覆盖）。
日志落盘 `logs/<yaml>-<job>-<i>.log`（每 pod 一份），流量采样 `logs/traffic.tsv`。

## 监控

`monitor-traffic.sh` 从中央 Prometheus（`113.44.182.82:9090`）采样 squid 每副本指标：

| 指标 | 含义 |
|---|---|
| `squid_client_http_kbytes_out_kbytes_total` | squid → 客户端字节（所有响应，含 HIT） |
| `squid_server_http_kbytes_in_kbytes_total` | 回源字节（仅 MISS/未缓存时产生） |

输出 TSV：`ts  out_total_KB/s  in_total_KB/s  instance-1... instance-N`。

## 流量模式解读

- **pip 场景**：`in`（回源）峰值 ≈ 1×146MB wheel + 小包；`out` ≈ 10×（10 个任务并行拉包）。
  若 `in/out` 比值 ≪ 1 → wheel 缓存命中，squid 缓存生效。
- **git 场景**：`in` ≈ 10×67MB（10 个任务几乎同时回源），`in/out` ≈ 1 → git 不缓存，
  印证 `refresh_pattern` 对 git smart-HTTP pack 无效（这正是 CI 里 git clone 无缓存加速的原因）。
- 每副本聚合：`sum by (instance) (rate(...[1m]))` 查看负载是否均衡分发到两个 squid 副本。
