# 16-tool 并发流量测试结果（2026-08-12, gy-006）

`run-tool-traffic.sh --all`：对 `squid-openssl/testcase/tool/` 全部 16 个工具 case
跑 **10 任务并发**流量测试（volcano replicas=10），时间线 `logs/tool/timeline.tsv`，
窗口流量用 access.log（逐请求，精确）+ 中央 Prometheus counter delta（参考）双口径。

## 汇总表

| case | 工具/流量特征 | 出站 | HIT/MISS(access.log) | HIT% | 说明 |
|---|---|---|---|---|---|
| 02 | apt | 5,543MB | 46 / 0.1MB | **99.8%** | .deb 强制缓存，10 并发几乎零回源 |
| 03 | git clone (github→gh-proxy) | 12MB | 0 / 0.1MB | **0.0%** | git pack 不缓存（结构性），vllm-ascend 浅克隆小 |
| 04 | go mod download | 1,577MB | 2,472 / 283MB | **89.7%** | proxy.golang.org 命中 |
| 05 | obsutil | 短窗口 | 243 / 3.3MB | **98.6%** | OBS 对象缓存命中 |
| 06 | wget 模型权重(.pth) | 855MB | 739 / 487MB | **60.3%** | .pth 无强制缓存规则，靠 20% LM 启发式 |
| 07 | cmake FetchContent | 1,118MB | 451 / 276MB | **62.1%** | 部分 URL 带缓存标记 |
| 08 | bazel http_archive | 848MB | 1,545 / 90MB | **94.5%** | 命中好 |
| 09 | npm install | 2,754MB | 3,246 / 157MB | **95.4%** | registry tarball 命中 |
| 10 | cargo build | 2,422MB | 19 / 157MB | **11.0%** | **crates.io .crate 不缓存**（默认 refresh_pattern 0/20%/4320）⚠ |
| 11 | conda | 2,002MB | 2,002 / 4.6MB | **99.8%** | 命中完美 |
| 12 | uv pip | 916MB | 2,638 / 134MB | **95.2%** | wheel 缓存 |
| 13 | huggingface | — | 463 / 41MB | **91.9%** | job FAILED（hf hub 网络，与历史一致），失败前命中良好 |
| 14 | git-lfs | 1,225MB | 1,469 / 5.1MB | **99.7%** | LFS 对象大文件命中 |
| 15 | pnpm | 2,364MB | 2,204 / 59MB | **97.4%** | 命中好 |
| 16 | yum/dnf | 2,625MB | 2,438 / 2.2MB | **99.9%** | 命中完美 |

（注：HIT = TCP_HIT + TCP_MEM_HIT + TCP_REFRESH_UNMODIFIED；MISS = TCP_MISS + TCP_REFRESH_MODIFIED。
出站为 Prometheus client_out counter delta——短窗口 case（05 等）因 60s scrape 对齐会低估，access.log 口径为准。）

## 结论与洞察

1. **多数工具 89-100% 命中**：apt/yum/conda/git-lfs/obs/npm/pnpm/bazel/uv——包管理器静态文件被
   squid 缓存，10 并发 CI 只有 1 份回源。
2. **git 系 0%**（03-github + 上次 git-clone 测试）：smart-HTTP pack 永不缓存，结构性限制。
3. **⚠ cargo（11%）最低可优化项**：crates.io 的 `.crate` 静态文件无强制缓存规则。建议 squid 增加：
   ```
   refresh_pattern -i \.crate$ 10080 100% 525960 ignore-reload override-expire ignore-no-cache
   ```
   预计可提升到 ~90%+（cargo 是 Rust 构建的重负载工具）。
4. **wget/cmake（60-62%）**：模型权重（.pth/.pt）和无扩展名大文件靠 20% LM 启发式命中率一般。
   可选：为模型权重域名加 min-age 缓存规则（需按实际域名配置）。
5. **13-huggingface** 本次 job 失败（hf hub 连接，与历史测试一致）——但失败前已观察到 463MB
   命中，缓存机制本身正常。

## chart 0.1.4 缓存规则优化 + 重测（2026-08-12）

针对上述洞察，`deploy/chart/templates/configmap.yaml` 新增 3 条强制缓存规则
（`deploy/chart/Chart.yaml` 0.1.3 → 0.1.4）：

```squid
refresh_pattern -i \.crate$  10080 100% 525960 ignore-reload override-expire ignore-no-cache
refresh_pattern -i \.zip$  10080 100% 525960 ignore-reload override-expire ignore-no-cache
refresh_pattern -i \.(pth|pt|safetensors)$  10080 100% 525960 ignore-reload override-expire ignore-no-cache
```

升级：`helm upgrade squid . -f values-006.yaml -n squid`（REVISION 14, squid-rpardini-0.1.4）。
排坑：集群资源此前由 ArgoCD 管理（managedFields 残留 argocd-controller ownership + 远程
controller 每 ~3min 回滚 configmap），需 `kubectl apply --server-side --field-manager=helm
--force-conflicts` 抢回字段所有权后再 helm upgrade；ConfigMap 卷更新有 kubelet 同步延迟
（>3min），须等同步完成后再 rollout restart 才能让 squid 加载新规则。

### 重测对比（新规则生效后，10 并发）

| 场景 | 优化前命中率 | 优化后 | 证据（access.log） |
|---|---|---|---|
| **cargo**（rsproxy crate 下载） | **11.0%** | **~95%** | cache-0: HIT 11.2MB / MISS 0.3MB；cache-1: HIT 7.7MB / MISS 1.1MB（TCP_HIT + TCP_MEM_HIT + REFRESH_UNMODIFIED） |
| **wget**（94MB resnet50.pth） | 60.3% | **100%** | `TCP_HIT/200 94285753 GET .../resnet50_msra-5891d200.pth`（HIER_NONE，零回源，1.2s / 78MB/s） |

- cargo crate 文件（`.crate`）从 11% → ~95%：10 并发 CI 中 9 份下载命中缓存
- 模型权重（.pth）现在强制缓存：94MB 文件零回源

## 复现

```bash
./run-tool-traffic.sh --all --monitor=7200   # 16 case × 10 并发 + 流量监控（约 40-60min）
python3 analyze-tool-traffic.py              # 汇总表 → logs/tool/analysis.json
```

- timeline：`logs/tool/timeline.tsv`（SUBMIT/DONE epoch，用于窗口对齐）
- 日志：`logs/tool/<case>-<name>/pod-N.log`（每 case 10 份）
- 流量采样：`logs/tool/traffic.tsv`（client/origin/hitrate 曲线，rate[5m]）

## 追加：gitcode 流量测试（2026-08-14）

测试 job `test-squid-gitcode-2rslh`（2× clone + ls-remote，7.2s）：

| 请求 | 结果 | 说明 |
|---|---|---|
| GET `gitcode.com/Ascend/mind-cluster.git/info/refs` ×2 | TCP_MISS | ~1KB，元数据 |
| POST `git-upload-pack`（31.8MB + 2.8MB） | TCP_MISS | **git smart-HTTP pack 为 POST，结构性不可缓存** |

**结论：gitcode clone = 0% HIT，与 github 相同，无需新增缓存规则。**

### gitcode 非 git 路径探测（全部被 WAF 阻断）

| 路径 | 结果 |
|---|---|
| `/-/archive/<ref>.zip` / `/archive/...zip` | WAF 验证页（206 text/html 3.5KB） |
| `/api/v4/.../releases` | **HTTP 418** |
| `/-/releases/download/...` | **HTTP 403** |

release/archive 流量被 WAF 拦截，从未到达 squid → 无 release/archive 可缓存。

### 追加：冷缓存崩溃重测记录（2026-08-14，r5）

清空缓存后重跑 16-tool 回归时 squid 崩溃（详见 `deploy/CACHE-STRATEGY.md` §10.2），
r5 数据无效。随后单 case 02（apt）冷缓存小规模验证**有效**：

| 指标 | 值 |
|---|---|
| HIT（TCP_HIT+MEM_HIT+REFRESH_UNMODIFIED） | 357.8MB |
| MISS | 189.3MB |
| **HIT%** | **65.4%** |
| SWAPFAIL / 崩溃 | 0 / 无 |

首个 pod 回源（MISS），后 9 个 pod 全部命中（HIT）——冷缓存下 apt 行为符合预期，
且单 case 不触发 SWAPFAIL/竞态崩溃。
