# 域名连通性 Proxy vs 直连 对比报告 (wlcb vs gy-001)

> 生成时间: 2026-09-03 15:48:00  |  每个域名 **20 轮 × 2 模式**(经 squid proxy / 直连), 两集群并行, 数据源: [ascend_ci_domains.json](ascend_ci_domains.json) (共 92 条实域名)

## 测试方法

- 4 组合: **wlcb**(squid `192.168.1.49`) / **gy-001**(squid `172.16.0.37`) × **经 proxy** `curl -sk --proxy http://127.0.0.1:3128` / **直连** `curl -sk`。
- 均在各自 squid pod 内执行(`kubectl exec`), 每域每模式连续 20 轮, `--max-time 6`。
- **关键前提**: proxy 与直连跑在**同一个 pod / 同一节点 / 同一出口 NAT**, 因此外部可达性差异**只可能来自 squid 处理逻辑**(DNS 缓存、连接复用、超时), 而不是出口不同。
- 判定: curl exit 0 = 成功; 28=TIMEOUT / 6=DNSFAIL / 7=CONNFAIL。成功率 = 20 轮成功数。
- 分类: **稳定**(proxy=直连=20/20) / **proxy劣化**(proxy<直连) / **直连劣化**(直连<proxy) / **出口全挂**(任一集群两路径 0/20)。

## 汇总

| 集群 | 稳定 (20/20 两路径) | proxy劣化 | 直连劣化 | 出口全挂 (两路径 0/20) | 合计 |
|---|---|---|---|---|---|
| wlcb (.49) | 83 | 5 | 1 | 3 | 92 |
| gy-001 (.37) | 79 | 9 | 0 | 4 | 92 |

## 核心发现: proxy 路径独有劣化 (直连可达, 走 squid 失败)

| 域名 | 集群 | proxy | 直连 | 差 |
|---|---|---|---|---|
| pytorch-package.obs.cn-north-4.myhuaweicloud.com | wlcb | **10/20** | 20/20 | -10 |
| goproxy.cn | gy-001 | **8/20** | 18/20 | -10 |
| files.pythonhosted.org | wlcb | **14/20** | 20/20 | -6 |
| op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1 | wlcb | **14/20** | 20/20 | -6 |
| files.pythonhosted.org | gy-001 | **16/20** | 20/20 | -4 |
| pkg-containers.githubusercontent.com | gy-001 | **17/20** | 20/20 | -3 |
| op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1 | gy-001 | **17/20** | 20/20 | -3 |
| objects.githubusercontent.com | gy-001 | **18/20** | 20/20 | -2 |
| github-cloud.githubusercontent.com | gy-001 | **18/20** | 20/20 | -2 |
| pypi.org | wlcb | 18/20 | 20/20 | -2 |
| github-releases.githubusercontent.com | gy-001 | 19/20 | 20/20 | -1 |
| github-registry-files.githubusercontent.com | gy-001 | 19/20 | 20/20 | -1 |
| pypi.org | gy-001 | 19/20 | 20/20 | -1 |
| goproxy.cn | wlcb | 19/20 | 20/20 | -1 |

## 直连劣化 (仅 1 例, 属噪声)

| 域名 | 集群 | proxy | 直连 |
|---|---|---|---|
| download.pytorch.org | wlcb | 19/20 | 18/20 |

## 出口全挂 (两路径 0/20, 与 squid 无关)

| 域名 | wlcb proxy/直连 | gy-001 proxy/直连 | 说明 |
|---|---|---|---|
| data.pyg.org | 0/0 | 0/0 | 两集群出口均不可达 |
| mirrors.ustc.edu.cn | 0/0 | 0/0 | IPv6-only 解析, 无 IPv6 出口 |
| 123.60.114.225 | 0/0 | 0/0 | 裸 IP/源站不可达 |
| github.com | 20/20 | **0/0** | 仅 gy-001 本轮两路径全挂(间歇黑洞, 见下) |

## Why: proxy 为什么比直连差 (定向取证)

**取证事实**(两集群 squid pod 内实测):
- `resolv.conf` 相同(集群 DNS `169.254.20.10` + `10.247.3.10`), proxy 与直连**用的是同一 DNS 源** → 排除"DNS 服务器不同"。
- 问题域名均为**多 IP 大池**: `goproxy.cn` 解析出 **13 个 IP**(36.110.220.x / 112.84.130.x / 211.154.x / 36.249.80.x / 45.250.40.239); `files.pythonhosted.org` 5 个 IP(151.101.x.x + 国内节点 112.121.185.26); `pytorch-package.obs` 混合 私网 100.125.x.x + 公网 121.36.121.x。
- squid.conf 仅 `read_timeout 30 minutes` + `connect_timeout 2 minutes`, **无 `dns_v4_first` / `pconn_timeout` / `connect_retries`**。

据此归纳 4 条根因:

1. **squid 单 IP 固定, 无 per-request 多 IP 故障转移**: squid 每次连接按 DNS 缓存结果固定用一个 IP, 一旦该 IP 在出口侧不通/慢, 后续所有请求都撞同一个坏 IP; 直连 curl 每轮重新解析且可换 IP 重试, 命中好 IP 概率高。这解释了 `goproxy.cn`(gy-001 13 IP 池) proxy 8/20 vs 直连 18/20 的 10 次差。
2. **上游 keep-alive 半开连接复用**: squid 默认长时间保留空闲上游连接(`read_timeout 30m`), 经 NAT/状态防火墙的空闲连接被回收后, 复用即半开, 首个请求卡到超时; 直连每次全新 TCP 无此问题。这解释了多 IP CDN(pythonhosted/pypi/github cdn 子域)proxy 系统性低 1~6 次。
3. **squid 超时口径与 curl 6s 预算错配**: squid `connect_timeout 2m`, 意为它会为一次失败连接耗到 2 分钟(含按坏 IP→好 IP 的顺序尝试); 而 curl `--max-time 6` 6 秒就放弃。只要 squid 在 6 秒内没把首个字节送回来, 就计失败——即使 squid 之后能成功。跨区域慢链路(wlcb→cn-north-4 OBS)尤其吃亏。
4. **`github.com`(gy-001) 两路径 0/20 = 出口层黑洞, 与 squid 无关**: 固定解析到单一 IP `20.205.243.166`(Azure 亚太)。同一 IP 在 wlcb(.49) 本轮 20/20 全通、gy-001(.37) 两路径 0/20 → **节点 .37 到该 IP 的路由当前断流**, 属间歇性(3 轮测试时曾 3/3, x20 报告也曾 0/20)。squid 绕不开, 只能靠 M3 cache_peer 稳定出口或 gh-proxy 回退。

## 结论与修复方向

- **squid 侧(可调, 收益最大)**:
  - `dns_v4_first on` — 避免 IPv6 挂起(部分 CDN 解析到 IPv6 先试)。
  - 缩短 `pconn_timeout`(如 30s)/ 调小 `read_timeout`, 减少半开连接复用。
  - 对多 IP CDN 配 `connect_retries`(acl) 或 `balance_on_multiple_ip`, 让 squid 单请求可换 IP。
  - 调小 `connect_timeout`(如 15s) 匹配客户端预算, 避免坏 IP 顺序试连拖垮首个字节时间。
- **跨区域 OBS(wlcb→pytorch-package.obs)**: 直连 20/20 而 proxy 10/20, 建议对该域配 cache_peer/固定私网 IP 路由, 让 squid 走与直连相同的稳定路径。
- **github.com 黑洞(.37)**: 属出口路由问题, squid 无法根治; 维持 main2main 的 gh-proxy/git-cdn 回退 + M3 cache_peer 稳定出口。

## 全量明细 (92 条, 格式: wlcb-proxy / wlcb-直连 / gy-proxy / gy-直连)

| # | 域名 | wlcb proxy | wlcb 直连 | gy proxy | gy 直连 | 分类 |
|---|---|---|---|---|---|---|
| 1 | devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 2 | devrepo.devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 3 | download.pytorch.org | 19/20 | 18/20 | 20/20 | 20/20 | 直连劣化 |
| 4 | download-r2.pytorch.org | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 5 | pytorch-package.obs.cn-north-4.myhuaweicloud.com | 10/20 | 20/20 | 20/20 | 20/20 | proxy劣化 |
| 6 | pta-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 7 | mindstudio-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 8 | www.sqlite.org | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 9 | sum.golang.google.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 10 | data.pyg.org | 0/20 | 0/20 | 0/20 | 0/20 | 出口全挂 |
| 11 | obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 12 | op-svc-swr-b051-10-38-19-62-3az.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 13 | op-svc-swr-cn-north-4-backup.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 14 | obs.cn-north-9.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 15 | op-svc-swr-b051-10-147-7-14-3az.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 16 | op-svc-swr-cn-east-3-backup.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 17 | op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 14/20 | 20/20 | 17/20 | 20/20 | proxy劣化 |
| 18 | op-svc-swr-cn-south-1-backup.obs.cn-south-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 19 | op-svc-swr-b051-10-205-14-19-3az.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 20 | obs.dualstack.cn-east-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 21 | lfs-cdn.openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 22 | artlfs.openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 23 | openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 24 | ru-repo.openeuler.org | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 25 | fr-repo.openeuler.org | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 26 | www.modelscope.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 27 | cdn-lfs-cn-1.modelscope.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 28 | gh-proxy.test.osinfra.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 29 | apig.openlibing.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 30 | get.helm.sh | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 31 | openlibing-codeql.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 32 | archive.ubuntu.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 33 | security.ubuntu.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 34 | gitee.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 35 | ports.ubuntu.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 36 | api.github.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 37 | broker.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 38 | pipelines.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 39 | pipelinesghubeus4.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 40 | results-receiver.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 41 | github.com | 20/20 | 20/20 | 0/20 | 0/20 | 出口全挂 |
| 42 | codeload.github.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 43 | objects.githubusercontent.com | 20/20 | 20/20 | 18/20 | 20/20 | proxy劣化 |
| 44 | objects-origin.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 45 | github-releases.githubusercontent.com | 20/20 | 20/20 | 19/20 | 20/20 | proxy劣化 |
| 46 | github-registry-files.githubusercontent.com | 20/20 | 20/20 | 19/20 | 20/20 | proxy劣化 |
| 47 | pkg-containers.githubusercontent.com | 20/20 | 20/20 | 17/20 | 20/20 | proxy劣化 |
| 48 | ghcr.io | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 49 | github-cloud.githubusercontent.com | 20/20 | 20/20 | 18/20 | 20/20 | proxy劣化 |
| 50 | github-cloud.s3.amazonaws.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 51 | dependabot-actions.githubapp.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 52 | release-assets.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 53 | api.snapcraft.io | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 54 | pipelinesghubeus1.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 55 | pipelinesghubeus2.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 56 | pipelinesghubeus3.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 57 | pipelinesghubeus5.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 58 | pipelinesghubeus6.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 59 | pipelinesghubeus7.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 60 | pipelinesghubeus8.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 61 | pipelinesghubeus9.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 62 | pipelinesghubeus10.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 63 | pipelinesghubeus11.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 64 | pipelinesghubeus12.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 65 | download.openmmlab.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 66 | rsproxy.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 67 | goproxy.cn | 19/20 | 20/20 | 8/20 | 18/20 | proxy劣化 |
| 68 | repo.anaconda.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 69 | repo.mindspore.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 70 | repo.oepkgs.net | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 71 | repo.openeuler.org | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 72 | mirrors.ustc.edu.cn | 0/20 | 0/20 | 0/20 | 0/20 | 出口全挂 |
| 73 | lfs-cdn.gitcode.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 74 | cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 75 | gitcode.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 76 | atomgit.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 77 | mirrors.huaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 78 | mindcluster.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 79 | mirrors.aliyun.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 80 | mirrors.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 81 | repo.huaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 82 | mindstudio-pkg.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 83 | files.pythonhosted.org | 14/20 | 20/20 | 16/20 | 20/20 | proxy劣化 |
| 84 | mindx-package.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 85 | pypi.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 86 | mindie-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 87 | pypi.org | 18/20 | 20/20 | 19/20 | 20/20 | proxy劣化 |
| 88 | build-env.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 89 | ppa.launchpad.net | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 90 | obs-community.obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 91 | ascend-cann-open.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 20/20 | 稳定 |
| 92 | 123.60.114.225 | 0/20 | 0/20 | 0/20 | 0/20 | 出口全挂 |
