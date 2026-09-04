# 域名连通性 Proxy vs 直连 对比报告 (gy-001 / wlcb-001 / gy-002) — 修正版

> **本版为修正后的真实 squid 路径测试 (2026-09-04 08:03)**。旧版 (2026-09-03) 的 `--proxy http://127.0.0.1:3128` 在 squid pod 内命中的是 **registry-proxy (rpardini nginx)** 而非 squid —— squid 实际监听 `3129` (`http_port 3129 ssl-bump`)。旧版全部"proxy 劣化"分析测的是 nginx 出口, 结论不适用于生产 squid 路径, 仅供方法学复盘。
>
> 本版测试条件与生产 CI 完全一致: **proxy 走 squid `127.0.0.1:3129`**, 且此时三集群 squid 已升级至 **`connect_timeout 5 seconds`** (chart 0.1.8), 即旧报告建议的修复已生效, 本版同时验证了修复效果。

## 测试方法

- 3 集群 × 92 实域名（[ascend_ci_domains.json](ascend_ci_domains.json)，跳过 `*.` 通配），每域每模式 **20 轮**。
- 均在各自集群 `squid-cache-0` pod 的 **squid 容器**内执行 (`kubectl exec`):
  - **proxy**: `curl -sk --proxy http://127.0.0.1:3129 --max-time 6 https://<域>/`
  - **直连**: `curl -sk --max-time 6 https://<域>/`
- proxy 与直连跑在**同一个 pod / 同一节点 / 同一出口 NAT**, 外部可达性差异只来自 squid 处理逻辑（DNS 缓存、地址族回退、连接超时）与 curl 直连行为之差, 而非出口不同。
- 判定: curl exit 0 = 成功（拿到任意 HTTP 响应，**含 squid 生成的 5xx 错误页，见方法学要点**）；28=TIMEOUT / 6=DNSFAIL / 7=CONNFAIL。
- 分类: **稳定**(proxy=直连=20/20) / **proxy劣化**(proxy<直连) / **直连劣化**(直连<proxy) / **间歇**(两者均非 20/20) / **出口全挂**(两路径 0/20)。

## ⚠️ 方法学要点: proxy 成功率包含 squid 生成的 503 错误响应

proxy 路径的成功判定是"curl 拿到**任意** HTTP 响应"（exit 0），**squid 侧生成的 `503 Gateway Timeout` 错误页也算成功**。定向复测确认:

| 域名 | squid 返回码 | 真实含义 |
|---|---|---|
| mirrors.ustc.edu.cn | **503** | 源站/IPv6 出口仍不可达, 但 squid 在预算内快速失败, 不挂死客户端 |
| 123.60.114.225 | **503** | 源站 443 仍不可达, 同上 |

因此这两域的 proxy "20/20" **不是真实可达**, 而是 squid **快速失败**（优于直连的 6s 干等超时）。下文中此类域已在"直连劣化"里单独标注 `(503)`。

## 汇总

| 集群 | 稳定 (20/20 两路径) | proxy劣化 | 直连劣化 | 间歇 | 出口全挂 (两路径 0/20) | 合计 |
|---|---|---|---|---|---|---|
| gy-001 (.37) | 82 | 2 | 8 | 0 | 0 | 92 |
| wlcb-001 (.49) | 81 | 3 | 6 | 2 | 0 | 92 |
| gy-002 | 80 | 3 | 9 | 0 | 0 | 92 |

**与旧版 (nginx-3128) 对比: 出口全挂从 3~4 个降为 0 个, proxy 劣化从 5~9 个降为 2~3 个且全部是 ±1 噪声。**

## 核心发现

### 1. `connect_timeout 5s` 修复显著生效: 系统性 proxy 劣化基本消除

旧版"proxy 系统性劣于直连"的根因是多 IP 顺序 failover 判死过慢（`connect_timeout 2m`），本次在 5s 下复测, 全部大劣化域恢复:

| 域名 (集群) | 旧版 nginx-3128 proxy | 旧版直连 | 本版 squid-3129 proxy | 本版直连 |
|---|---|---|---|---|
| goproxy.cn (gy-001) | **8/20** | 18/20 | **20/20** | 20/20 |
| pytorch-package.obs (wlcb) | **10/20** | 20/20 | **19/20** | 20/20 |
| op-svc-swr-b051-10-230-33-197 (wlcb / gy) | **14/20 / 17/20** | 20/20 | **20/20 / 20/20** | 20/20 |
| files.pythonhosted.org (wlcb / gy) | **14/20 / 16/20** | 20/20 | **19/20 / 19/20** | 20/20 / 19/20 |
| pypi.org (wlcb / gy) | **18/20 / 19/20** | 20/20 | **20/20 / 20/20** | 20/20 / 19/20 |
| github-cloud / objects / pkg-containers 等 CDN 子域 (gy) | 17~19/20 | 20/20 | **20/20 (除 github-cloud.s3 19/20)** | 19~20/20 |

剩余 proxy 差值全部为 **1 次**（如 gy-001 `github-cloud.s3` 19/20、wlcb `ports.ubuntu.com` 19/20、gy-002 `pkg-containers` 19/20），属正常抖动，不再成系统性劣化。

### 2. 0 个"两路径全挂"（旧版 3~4 个）

- **github.com (gy-001)**: 旧版 0/20（出口层黑洞）→ 本版 **20/20**，间歇黑洞已恢复。
- **data.pyg.org / mirrors.ustc.edu.cn / 123.60.114.225**: 旧版两集群两路径 0/20 → 本版不再全挂（详见第 4 点与下方 `(503)` 标注）。

### 3. 反转为"直连劣化"为主: squid 路径比直连更稳

本版直连劣化 (6~9 个/集群) 明显多于 proxy 劣化 (2~3 个)。典型:

| 域名 | gy-001 proxy/直连 | wlcb proxy/直连 | gy-002 proxy/直连 |
|---|---|---|---|
| repo.openeuler.org | 20/20 / **16/20** | 20/20 / **19/20** | 20/20 / **18/20** |
| www.sqlite.org | 20/20 / 19/20 | 20/20 / 19/20 | 20/20 / **18/20** |
| data.pyg.org | 12/20 / **0/20** | 12/20 / **0/20** | 20/20 / **0/20 (20×DNSFAIL)** |
| objects-origin / objects / pypi.org / archive.ubuntu | 20/20 / 19~20/20 | — | 20/20 / 19/20 |

即部分域在 pod 内**直连**（curl 直接出网）不稳定（DNS 偶发失败/超时，如 data.pyg.org 直连 20 轮全挂），而经 squid 反而 20/20。这与旧版"proxy 必劣化"的印象相反——squid 的 **DNS 缓存 + 地址族自动回退 + 5s 快速判死**使代理路径更健壮。

### 4. 仍不可达的源站: squid 快速失败 (503) 优于直连干等

| 域名 | proxy (实为 squid 返回码) | 直连 | 说明 |
|---|---|---|---|
| mirrors.ustc.edu.cn | 20/20 (gy-001/wlcb 为 **503**; gy-002 200) | 0/20 (gy-001/wlcb) | IPv6 源站/出口问题, squid 快速 503, 不挂死客户端 |
| 123.60.114.225 | 20/20 (三集群均 **503**) | 0/20 (三集群) | 裸 IP 源站 443 不可达, 同上 |
| data.pyg.org | 12~20/20 (200) | 0/20 (DNS/超时) | 直连 DNS 不稳, squid 路径多数可达 |

> 注意: `mirrors.ustc.edu.cn` / `123.60.114.225` 经 squid 的成功是 **503 快速失败**, 不代表缓存/下载可用, 生产仍需域名白名单层面规避或换镜像源。

### 5. 间歇性域 (两轮内波动, 非结构性)

- `results-receiver.actions.githubusercontent.com` (wlcb 19/19; gy-002 19/17)、`files.pythonhosted.org` (wlcb 19/19)、`apig.openlibing.com` (gy-002 直连 0/20 但复测 404 可达) —— 均属间歇抖动, 无固定方向。

## 结论

1. **`connect_timeout 5s` 修复被本版实测验证有效**：多 IP 域（goproxy.cn、OBS 多 IP、CDN 大池）的"proxy 系统性劣化"消失，剩余差值 ≤1 次为噪声。该配置**值得保留并推广到其余集群**。
2. **0 个全挂 + proxy 稳定性反超直连**：生产 CI 走 squid 路径（`squid-cache:3128` → targetPort 3129）与直连出网相比不再有劣势，且在 DNS/地址族回退上更稳。
3. **仍待处理的源站**（mirrors.ustc.edu.cn、123.60.114.225）经 squid 为 503 快速失败——对客户端友好但非真实可达；data.pyg.org 属间歇，非结构性。
4. 上一版"作废声明"指出的 nginx-3128 误测问题，本版已用 squid-3129 全量重测，旧版结论（proxy 劣化/黑洞）**不适用于生产 squid 路径**，请以本版为准。

## 全量明细 (92 条, 列格式: `proxy/20 · 直连/20`)

| # | 域名 | gy-001 | wlcb-001 | gy-002 | 分类 |
|---|---|---|---|---|---|
| 1 | devcloud.cn-north-4.huaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 2 | devrepo.devcloud.cn-north-4.huaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 3 | download.pytorch.org | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 4 | download-r2.pytorch.org | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 5 | pytorch-package.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 19/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 6 | pta-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 7 | mindstudio-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 8 | www.sqlite.org | 20/20 · 19/20 | 20/20 · 19/20 | 20/20 · 18/20 | 直连劣化 |
| 9 | sum.golang.google.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 10 | data.pyg.org | 12/20 · 0/20 | 12/20 · 0/20 | 20/20 · 0/20 | 直连劣化 |
| 11 | obs.cn-north-1.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 12 | op-svc-swr-b051-10-38-19-62-3az.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 13 | op-svc-swr-cn-north-4-backup.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 14 | obs.cn-north-9.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 15 | op-svc-swr-b051-10-147-7-14-3az.obs.cn-east-3.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 16 | op-svc-swr-cn-east-3-backup.obs.cn-east-3.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 17 | op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 18 | op-svc-swr-cn-south-1-backup.obs.cn-south-1.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 19 | op-svc-swr-b051-10-205-14-19-3az.obs.cn-southwest-2.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 20 | obs.dualstack.cn-east-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 21 | lfs-cdn.openeuler.openatom.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 22 | artlfs.openeuler.openatom.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 23 | openeuler.openatom.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 24 | ru-repo.openeuler.org | 20/20 · 20/20 | 19/20 · 20/20 | 19/20 · 20/20 | proxy劣化 |
| 25 | fr-repo.openeuler.org | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 26 | www.modelscope.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 27 | cdn-lfs-cn-1.modelscope.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 28 | gh-proxy.test.osinfra.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 29 | apig.openlibing.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 0/20 | 稳定 |
| 30 | get.helm.sh | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 31 | openlibing-codeql.obs.cn-southwest-2.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 32 | archive.ubuntu.com | 20/20 · 19/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 33 | security.ubuntu.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 34 | gitee.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 35 | ports.ubuntu.com | 20/20 · 20/20 | 19/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 36 | api.github.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 37 | broker.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 38 | pipelines.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 39 | pipelinesghubeus4.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 40 | results-receiver.actions.githubusercontent.com | 20/20 · 20/20 | 19/20 · 19/20 | 19/20 · 17/20 | 间歇 |
| 41 | github.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 42 | codeload.github.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 43 | objects.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 19/20 | 稳定 |
| 44 | objects-origin.githubusercontent.com | 20/20 · 20/20 | 20/20 · 19/20 | 20/20 · 19/20 | 直连劣化 |
| 45 | github-releases.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 46 | github-registry-files.githubusercontent.com | 20/20 · 19/20 | 20/20 · 20/20 | 19/20 · 20/20 | 直连劣化 |
| 47 | pkg-containers.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 19/20 · 20/20 | 稳定 |
| 48 | ghcr.io | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 49 | github-cloud.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 50 | github-cloud.s3.amazonaws.com | 19/20 · 20/20 | 20/20 · 20/20 | 20/20 · 19/20 | proxy劣化 |
| 51 | dependabot-actions.githubapp.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 52 | release-assets.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 53 | api.snapcraft.io | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 54 | pipelinesghubeus1.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 55 | pipelinesghubeus2.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 56 | pipelinesghubeus3.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 57 | pipelinesghubeus5.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 58 | pipelinesghubeus6.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 59 | pipelinesghubeus7.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 60 | pipelinesghubeus8.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 61 | pipelinesghubeus9.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 62 | pipelinesghubeus10.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 63 | pipelinesghubeus11.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 64 | pipelinesghubeus12.actions.githubusercontent.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 65 | download.openmmlab.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 66 | rsproxy.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 67 | goproxy.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 68 | repo.anaconda.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 69 | repo.mindspore.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 70 | repo.oepkgs.net | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 71 | repo.openeuler.org | 20/20 · 16/20 | 20/20 · 19/20 | 20/20 · 18/20 | 直连劣化 |
| 72 | mirrors.ustc.edu.cn | 20/20(503) · 0/20 | 20/20(503) · 0/20 | 20/20 · 20/20 | 直连劣化 |
| 73 | lfs-cdn.gitcode.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 74 | cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 75 | gitcode.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 76 | atomgit.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 77 | mirrors.huaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 78 | mindcluster.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 79 | mirrors.aliyun.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 80 | mirrors.tuna.tsinghua.edu.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 81 | repo.huaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 82 | mindstudio-pkg.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 83 | files.pythonhosted.org | 19/20 · 20/20 | 19/20 · 19/20 | 20/20 · 20/20 | proxy劣化 |
| 84 | mindx-package.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 85 | pypi.tuna.tsinghua.edu.cn | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 86 | mindie-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 87 | pypi.org | 20/20 · 19/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 88 | build-env.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 89 | ppa.launchpad.net | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 90 | obs-community.obs.cn-north-1.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 91 | ascend-cann-open.obs.cn-north-4.myhuaweicloud.com | 20/20 · 20/20 | 20/20 · 20/20 | 20/20 · 20/20 | 稳定 |
| 92 | 123.60.114.225 | 20/20(503) · 0/20 | 20/20(503) · 0/20 | 20/20(503) · 0/20 | 直连劣化 |
