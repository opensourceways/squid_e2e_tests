# 域名连通性 ×20 轮压测报告 (gy-001 / wlcb-001 / gy-002)

> 修正版生成时间: 2026-09-03  |  每个域名 **20 轮**「DNS解析 + 经 squid 代理 curl」, 数据源: [ascend_ci_domains.json](ascend_ci_domains.json)  (共 92 条, 跳过 `*.` 通配)

## ⚠️ 测试方法修正说明 (重要)

**旧版报告的代理端口用错了, 本报告为修正后的真实数据。**

| 版本 | 代理端口 | 实际命中的组件 | 结论有效性 |
|---|---|---|---|
| **旧版 (作废)** | `127.0.0.1:3128` | 同 pod 的 **registry-proxy (rpardini nginx)**, 不是 squid | ❌ 无效 (测的是 nginx 出口) |
| **本版 (修正)** | `127.0.0.1:3129` | **squid** (`http_port 3129 ssl-bump`) | ✅ 真实 CI 路径 |

架构依据: Service `squid-cache:3128` → `targetPort 3129` → squid; 而 pod 内 `127.0.0.1:3128` 是 registry-proxy (也是 squid `cache_peer` 的上游, 见 squid.conf `cache_peer 127.0.0.1 parent 3128 name=registryproxy`)。CI 客户端经 Service 3128 会被 DNAT 到 3129, 与 pod 内直连 3129 **等价**。

**旧版结论被推翻**: 旧报告里的 `mirrors.ustc.edu.cn / 123.60.114.225 / data.pyg.org / github.com` 等"黑洞/0-20"其实是 **nginx 出口能力弱** 的假象, 换到 squid 真实路径后几乎全部可达(见下)。脚本已同步修正: [x20-remote.sh](x20-remote.sh) / [test-domains.sh](test-domains.sh) / [test-domains-x20.sh](test-domains-x20.sh)。

## 测试方法

- 在 **gy-001**(squid `172.16.0.37`) / **wlcb-001**(squid `192.168.1.49`) / **gy-002** 的 `squid-cache-0` pod 内, 每个域名连续 20 轮: `getent hosts` 解析 → `curl -sk --proxy http://127.0.0.1:3129 --max-time 6 https://<域名>/`。
- 每轮记录解析到的首个 IP; 20 轮 IP 序列可反映 DNS 轮询/多 IP。
- 判定: curl exit 0 = 成功; 28=TIMEOUT / 6=DNSFAIL / 7=CONNFAIL。本轮三集群均无 DNSFAIL/CONNFAIL, 失败全部是超时。
- 成功率为 **20 轮内成功次数**: **稳定**(20/20) / **间歇**(1-19) / **全失败**(0/20)。

## 汇总

| 集群 | 稳定(20/20) | 间歇(1-19) | 全失败(0/20) | 实测数 |
|---|---|---|---|---|
| gy-001 (.37) | 86 | 6 | **0** | 92 |
| wlcb-001 (.49) | 89 | 3 | **0** | 92 |
| gy-002 | 88 | 4 | **0** | 92 |

> **三集群均无完全不可达域名** (修正前旧版 gy-001/wlcb 各有 2~4 个 0/20, 均为 nginx 路径假象)。

## 间歇性域名 (任一集群 < 20/20, 共 9 个)

| 域名 | gy-001 | wlcb-001 | gy-002 | 说明 |
|---|---|---|---|---|
| data.pyg.org | 16/20 | 10/20 | 20/20 | CloudFront 多 IP (`13.225.x.x` 慢 / `18.66.x.x` 快), wlcb 最差 |
| github.com | 19/20 | 20/20 | 18/20 | 固定 `20.205.243.166`, 各集群偶发 1~2 次超时 |
| github-registry-files.githubusercontent.com | 19/20 | 20/20 | 20/20 | 偶发 1 次 |
| github-cloud.githubusercontent.com | 19/20 | 20/20 | 20/20 | 偶发 1 次 |
| release-assets.githubusercontent.com | 19/20 | 20/20 | 17/20 | gy-002 3 次超时 |
| results-receiver.actions.githubusercontent.com | 20/20 | 19/20 | 20/20 | 偶发 1 次 |
| files.pythonhosted.org | 19/20 | 20/20 | 20/20 | gy-001 偶发 1 次 (旧版 gy-001 仅 4~14/20) |
| pypi.org | 20/20 | 20/20 | 19/20 | gy-002 偶发 1 次 |
| 123.60.114.225 | 20/20 | 19/20 | 19/20 | 裸 IP 源站, 偶发超时 (旧版三集群 0/20) |

## 修正后关键结论 (对比旧版)

1. **`goproxy.cn` 三集群全部 20/20** (旧版 gy-001 仅 8~11/20)。旧版劣化实为 squid 路径 `connect_timeout 5s` 顺序 failover 与 curl 6s 预算错配 —— 但那是 nginx 路径测不出来的; 真实 squid 路径下 goproxy 完全稳定。
2. **`mirrors.ustc.edu.cn` / `123.60.114.225` 不再是黑洞**: 修正后 wlcb/gy-002 各有 1 次偶发超时, gy-001 全通。旧版"结构性不可达"结论作废 (nginx 出口无法到达, 与 squid 无关)。
3. **`github.com` 主域整体健康**: gy-001 19/20、wlcb 20/20、gy-002 18/20, 仅偶发 1~2 次超时。旧版 gy-001 曾 0/20 属 nginx 路径 + 间歇窗口叠加, 不代表 squid 出口阻断。
4. **`pytorch-package.obs.cn-north-4` 三集群 20/20** (旧版 wlcb 仅 11/20): squid 路径下跨区域 OBS 稳定。
5. **`data.pyg.org` 是唯一仍有实质抖动** 的域名: wlcb 10/20、gy-001 16/20, 与 squid 无关, 属 CloudFront 部分边缘节点 (wlcb 出口 `13.225.134.125` 慢) 问题。
6. **结论**: 生产 squid (3129) 出口对 ascend CI 白名单 92 域全部可达, 无结构性阻断; 剩余间歇均为 CDN 多 IP 轮询 + 出口偶发抖动的正常噪声量级。

## 全量明细 (92 条, 分类按三集群最差)

| # | 域名 | gy-001 | wlcb-001 | gy-002 | 分类 |
|---|---|---|---|---|---|
| 1 | devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 2 | devrepo.devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 3 | download.pytorch.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 4 | download-r2.pytorch.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 5 | pytorch-package.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 6 | pta-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 7 | mindstudio-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 8 | www.sqlite.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 9 | sum.golang.google.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 10 | data.pyg.org | 16/20 | 10/20 | 20/20 | 间歇 |
| 11 | obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 12 | op-svc-swr-b051-10-38-19-62-3az.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 13 | op-svc-swr-cn-north-4-backup.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 14 | obs.cn-north-9.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 15 | op-svc-swr-b051-10-147-7-14-3az.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 16 | op-svc-swr-cn-east-3-backup.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 17 | op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 18 | op-svc-swr-cn-south-1-backup.obs.cn-south-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 19 | op-svc-swr-b051-10-205-14-19-3az.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 20 | obs.dualstack.cn-east-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 21 | lfs-cdn.openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 22 | artlfs.openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 23 | openeuler.openatom.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 24 | ru-repo.openeuler.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 25 | fr-repo.openeuler.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 26 | www.modelscope.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 27 | cdn-lfs-cn-1.modelscope.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 28 | gh-proxy.test.osinfra.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 29 | apig.openlibing.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 30 | get.helm.sh | 20/20 | 20/20 | 20/20 | 稳定 |
| 31 | openlibing-codeql.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 32 | archive.ubuntu.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 33 | security.ubuntu.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 34 | gitee.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 35 | ports.ubuntu.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 36 | api.github.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 37 | broker.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 38 | pipelines.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 39 | pipelinesghubeus4.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 40 | results-receiver.actions.githubusercontent.com | 20/20 | 19/20 | 20/20 | 间歇 |
| 41 | github.com | 19/20 | 20/20 | 18/20 | 间歇 |
| 42 | codeload.github.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 43 | objects.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 44 | objects-origin.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 45 | github-releases.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 46 | github-registry-files.githubusercontent.com | 19/20 | 20/20 | 20/20 | 间歇 |
| 47 | pkg-containers.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 48 | ghcr.io | 20/20 | 20/20 | 20/20 | 稳定 |
| 49 | github-cloud.githubusercontent.com | 19/20 | 20/20 | 20/20 | 间歇 |
| 50 | github-cloud.s3.amazonaws.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 51 | dependabot-actions.githubapp.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 52 | release-assets.githubusercontent.com | 19/20 | 20/20 | 17/20 | 间歇 |
| 53 | api.snapcraft.io | 20/20 | 20/20 | 20/20 | 稳定 |
| 54 | pipelinesghubeus1.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 55 | pipelinesghubeus2.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 56 | pipelinesghubeus3.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 57 | pipelinesghubeus5.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 58 | pipelinesghubeus6.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 59 | pipelinesghubeus7.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 60 | pipelinesghubeus8.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 61 | pipelinesghubeus9.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 62 | pipelinesghubeus10.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 63 | pipelinesghubeus11.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 64 | pipelinesghubeus12.actions.githubusercontent.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 65 | download.openmmlab.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 66 | rsproxy.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 67 | goproxy.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 68 | repo.anaconda.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 69 | repo.mindspore.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 70 | repo.oepkgs.net | 20/20 | 20/20 | 20/20 | 稳定 |
| 71 | repo.openeuler.org | 20/20 | 20/20 | 20/20 | 稳定 |
| 72 | mirrors.ustc.edu.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 73 | lfs-cdn.gitcode.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 74 | cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 75 | gitcode.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 76 | atomgit.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 77 | mirrors.huaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 78 | mindcluster.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 79 | mirrors.aliyun.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 80 | mirrors.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 81 | repo.huaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 82 | mindstudio-pkg.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 83 | files.pythonhosted.org | 19/20 | 20/20 | 20/20 | 间歇 |
| 84 | mindx-package.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 85 | pypi.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 20/20 | 稳定 |
| 86 | mindie-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 87 | pypi.org | 20/20 | 20/20 | 19/20 | 间歇 |
| 88 | build-env.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 89 | ppa.launchpad.net | 20/20 | 20/20 | 20/20 | 稳定 |
| 90 | obs-community.obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 91 | ascend-cann-open.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 20/20 | 稳定 |
| 92 | 123.60.114.225 | 20/20 | 19/20 | 19/20 | 间歇 |
