# traffic-test 实测结果（2026-08-12, gy-006）

10 个并行 Volcano 任务模拟 CI 并发，全部走 squid SSL-Bump（`squid-cache.squid:3128`）。
数据来源：中央 Prometheus（`113.44.182.82:9090`，headless 每副本 scrape）+ 双副本 access.log。

## 指标语义（对比口径）

| 指标 | 方向 | 用途 |
|---|---|---|
| `squid_client_http_kbytes_out_kbytes_total` | squid → 客户端（全部响应） | **出站** |
| `squid_server_http_kbytes_in_kbytes_total` | 源站 → squid（仅 MISS 回源） | **回源** |

缓存命中率 = `1 - server_in / client_out`（同方向响应流量之比）。

## 场景 1：pip 并发安装（10 任务）

每任务：clone `gitcode.com/Ascend/pytorch`（63MB）+ `pip download` 13 个真实包
（pytorch requirements + numpy/psutil/flask/fastapi 等 + `torch==2.10.0` aarch64 wheel 146MB）。

### 冷缓存（首轮）

| 指标 | 数值 |
|---|---|
| pip download 耗时 | 3.9–10.9s（多数 ~4s） |
| 场景出站（client_out） | 1,617 MB |
| 场景回源（origin_in） | 112 MB（≈ 1× wheel + 小包） |
| 回源率 / 缓存命中率 | **6.9% / 93.1%** |
| access.log HIT | cache-0: 84%，cache-1: 80%（MEM_HIT+HIT+REFRESH_UNMODIFIED） |

### 热缓存（重测）

| 指标 | 数值 |
|---|---|
| pip download 耗时 | 3.8–5.3s（分布均匀，无慢任务） |
| 下载阶段命中率曲线 | **1.00**（origin 仅 0.2–0.5 KB/s，wheel 全 HIT） |
| 峰值出站 | 18.1 MB/s，回源 1.05 MB/s（hitrate 0.94） |

**结论**：`.whl` 强制缓存（`refresh_pattern 10080 100% 525960`）生效。10 个并发 CI 任务中
仅第 1 个回源 146MB wheel；热缓存后**回源几乎为零**。

## 场景 2：git 并发 clone（10 任务）

`git clone --depth 1 https://gitcode.com/Ascend/pytorch.git`（63MB pack）。

| 轮次 | clone 耗时 | access.log |
|---|---|---|
| 首轮 | 2.9–4.7s（avg 3.7s） | **100% TCP_MISS** |
| 重测 | 2.7–3.6s | **100% TCP_MISS** |

重测窗口 access.log 中 `git-upload-pack` 共 **40 个请求全部 TCP_MISS**（两副本各 14+26）。
**结论**：git smart-HTTP pack（`application/x-git-upload-pack-result`）不缓存，10 并发全部回源。

## 混合窗口总账（重测，07:48:00-07:52:00 UTC，两副本）

| 状态 | 请求数 | 字节 | 说明 |
|---|---|---|---|
| TCP_HIT | 607 | 2,690 MB | 磁盘命中（pip wheel 主体） |
| TCP_MEM_HIT | 1,984 | 201 MB | 内存命中（pip 索引页） |
| TCP_REFRESH_UNMODIFIED | 806 | 1,108 MB | 重新验证未变（命中） |
| **TCP_MISS** | **61** | **245 MB** | 回源（**其中 40 个 upload-pack = 全部 git clone pack**） |
| TCP_REFRESH_MODIFIED | 12 | 1.4 MB | 重新验证有更新 |

- Prometheus 同窗口：client_out 4,247 MB / origin_in 246 MB → **回源率 5.8%，缓存命中率 94.2%**（与 access.log MISS 字节 245MB 完全吻合）
- 回源 ≈ 全部为 git pack（245MB ≈ 40× pack 段）；pip 热缓存阶段回源≈0

## 双副本负载

| 副本 | 命中字节 | MISS 字节 | git upload-pack |
|---|---|---|---|
| squid-cache-0 | 1,869 MB | 86 MB | 14 |
| squid-cache-1 | 2,130 MB | 159 MB | 26 |

负载基本均衡（10 任务按节点 5/5 分流，比例 ~47:53）。

## 方法说明

- 窗口流量：Prometheus `sum(...{job="squid"})` counter delta（headless 每副本 series）
- HIT/MISS：access.log `$4` 列（TCP_HIT/TCP_MISS/TCP_MEM_HIT/TCP_REFRESH_*），`$5`=字节
- 时间戳：Prometheus/access.log 为 UTC epoch；本机日志显示为 UTC+8
- `kubectl cp` 抓 access.log 可能截断（EOF 错误），须在容器内 `grep | awk`
- `rate[5m]` 摊平峰值（瞬时速率 ≈ rate 值 × 300s / 峰值持续时间）
- Prometheus 的 `client_http.kbytes_in`（客户端→squid 请求字节）恒小，**勿用作出站对比**；
  对比必须用 `client_http.kbytes_out` vs `server_http.kbytes_in`
