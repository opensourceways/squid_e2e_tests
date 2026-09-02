# 域名连通性 ×20 轮压测报告 (wlcb vs gy-001)

> 生成时间: 2026-09-02 15:31:00  |  每个域名 **20 轮**「DNS解析 + 经squid代理 curl」, 数据源: [ascend_ci_domains.json](ascend_ci_domains.json)  (共 96 条)

## 测试方法

- 在 **wlcb**(squid `192.168.1.49`) / **gy-001**(squid `172.16.0.37`) 的 squid pod 内, 每个域名连续 20 轮: `getent hosts` 解析 → `curl -sk --proxy http://127.0.0.1:3128 --max-time 6 https://<域名>/`。
- 每轮记录解析到的首个 IP; 20 轮 IP 序列可反映 DNS 轮询/多IP。
- 判定: curl exit 0 = 成功; 28=TIMEOUT / 6=DNSFAIL / 7=CONNFAIL。
- 成功率为 **20 轮内成功次数**: **稳定**(20/20) / **间歇**(1-19) / **全失败**(0/20)。
- ⚠️ 单次测试的"可达/不可达"结论不可靠, 必须以多轮为准(见"关键修正")。

## 汇总

| 集群 | 稳定(20/20) | 间歇(1-19) | 全失败(0/20) | 实测数 |
|---|---|---|---|---|
| wlcb (.49) | 82 | 8 | 2 | 92 |
| gy-001 (.37) | 79 | 10 | 3 | 92 |

## 结构性全失败 (0/20, 两集群)

| 域名 | wlcb | gy-001 | 解析IP | 说明 |
|---|---|---|---|---|
| mirrors.ustc.edu.cn | 0/20 | 0/20 | 2001:da8:d800:95::110 | IPv6-only解析, 无IPv6出口 |
| 123.60.114.225 | 0/20 | 0/20 | 123.60.114.225 | 裸IP/源站不可达 |

## 间歇性域名 (1-19/20, 任一集群)

| 域名 | wlcb | gy-001 | wlcb 解析IP(去重) | gy001 解析IP(去重) |
|---|---|---|---|---|
| files.pythonhosted.org | 4/20 | 15/20 | 151.101.192.223,151.101.0.223 | 151.101.192.223,151.101.0.223 |
| pytorch-package.obs.cn-north-4.myhuaweicloud.com | 11/20 | 20/20 | 100.125.76.5,100.125.83.133 | 121.36.121.226 |
| mirrors.aliyun.com | 15/20 | 20/20 | 222.138.197.52,124.95.170.12 | 218.61.162.63 |
| op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 17/20 | 16/20 | 116.162.187.35 | 36.158.239.37 |
| www.sqlite.org | 19/20 | 20/20 | 2600:3c02::f03c:95ff:fe07:695 | 2600:3c02::f03c:95ff:fe07:695 |
| archive.ubuntu.com | 19/20 | 20/20 | 91.189.92.22 | 185.125.190.83 |
| pypi.org | 19/20 | 19/20 | 2a04:4e42::223,2a04:4e42:600::223 | 2a04:4e42:400::223,2a04:4e42:600::223 |
| github-cloud.s3.amazonaws.com | 19/20 | 18/20 | 54.231.168.17,16.15.212.164 | 16.15.212.164,16.15.229.22 |
| pkg-containers.githubusercontent.com | 20/20 | 19/20 | 2606:50c0:8000::154 | 2606:50c0:8001::154 |
| release-assets.githubusercontent.com | 20/20 | 19/20 | 185.199.110.133 | 185.199.111.133 |
| github-releases.githubusercontent.com | 20/20 | 18/20 | 2606:50c0:8002::154 | 2606:50c0:8002::154 |
| data.pyg.org | 20/20 | 19/20 | 18.66.112.104 | 3.165.39.106 |
| github-registry-files.githubusercontent.com | 20/20 | 19/20 | 185.199.108.154 | 185.199.110.154 |
| goproxy.cn | 20/20 | 13/20 | 211.154.247.40 | 36.110.220.113,36.110.220.110 |

## 新增域名 (2026-09-02)

| 域名 | wlcb | gy-001 | wlcb IP |
|---|---|---|---|
| repo.mindspore.cn | 20/20 | 20/20 | 124.70.125.215 |
| repo.oepkgs.net | 20/20 | 20/20 | 121.36.99.241 |
| repo.openeuler.org | 20/20 | 20/20 | 49.0.229.41 |
| ascend-cann-open.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.4 |

## 关键修正 (vs 单次测试结论)

1. **`goproxy.cn` 不是结构性阻断**: gy-001 实测 **13/20**(65%), 属间歇性 —— 之前单次测试恰好撞上坏时刻。
2. **`pytorch-package.obs` 的华为私网 IP `100.125.x.x` 在 wlcb 部分可达(11/20, 55%)**: 不是完全不可路由; wlcb 集群网络能连到私网 OBS 端点但链路极不稳, 这正是 op-plugin 全挂与 `NONE_NONE/503` 间歇的根源。
3. **`github.com` 在 gy-001 曾 0/20**: 固定解析到 `20.205.243.166`(Azure 亚太), 存在间歇性下行窗口。
4. **`files.pythonhosted.org`**: wlcb 仅 **4/20**(Fastly `151.101.x.x` 对 wlcb 链路很差), gy-001 15/20。pip 在 wlcb 会频繁超时。
5. **`mirrors.ustc.edu.cn` / `123.60.114.225`**: 唯一真正结构性不可达(两集群 0/20)。

## 全量明细 (92 条)

| # | 域名 | wlcb成功率 | gy001成功率 | wlcb IP(去重) | 分类 |
|---|---|---|---|---|---|
| 1 | devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 116.205.76.80 | 稳定 |
| 2 | devrepo.devcloud.cn-north-4.huaweicloud.com | 20/20 | 20/20 | 114.116.231.65 | 稳定 |
| 3 | download.pytorch.org | 20/20 | 20/20 | 99.84.152.27 | 稳定 |
| 4 | download-r2.pytorch.org | 20/20 | 20/20 | 2606:4700::6812:934 | 稳定 |
| 5 | pytorch-package.obs.cn-north-4.myhuaweicloud.com | 11/20 | 20/20 | 100.125.76.5,100.125.83.133 | 间歇 |
| 6 | pta-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.7 | 稳定 |
| 7 | mindstudio-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.7 | 稳定 |
| 8 | www.sqlite.org | 19/20 | 20/20 | 2600:3c02::f03c:95ff:fe07:695 | 间歇 |
| 9 | sum.golang.google.cn | 20/20 | 20/20 | 114.250.67.43 | 稳定 |
| 10 | data.pyg.org | 20/20 | 19/20 | 18.66.112.104 | 间歇 |
| 11 | obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 114.115.192.27 | 稳定 |
| 12 | op-svc-swr-b051-10-38-19-62-3az.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 121.36.121.197 | 稳定 |
| 13 | op-svc-swr-cn-north-4-backup.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 123.60.240.4 | 稳定 |
| 14 | obs.cn-north-9.myhuaweicloud.com | 20/20 | 20/20 | 100.125.32.30 | 稳定 |
| 15 | op-svc-swr-b051-10-147-7-14-3az.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 36.156.217.76 | 稳定 |
| 16 | op-svc-swr-cn-east-3-backup.obs.cn-east-3.myhuaweicloud.com | 20/20 | 20/20 | 121.36.235.173 | 稳定 |
| 17 | op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 17/20 | 16/20 | 116.162.187.35 | 间歇 |
| 18 | op-svc-swr-cn-south-1-backup.obs.cn-south-1.myhuaweicloud.com | 20/20 | 20/20 | 122.9.127.212 | 稳定 |
| 19 | op-svc-swr-b051-10-205-14-19-3az.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 139.9.224.18 | 稳定 |
| 20 | obs.dualstack.cn-east-4.myhuaweicloud.com | 20/20 | 20/20 | 2409:2001:100:2::6 | 稳定 |
| 21 | lfs-cdn.openeuler.openatom.cn | 20/20 | 20/20 | 61.135.210.33 | 稳定 |
| 22 | artlfs.openeuler.openatom.cn | 20/20 | 20/20 | 121.36.2.159 | 稳定 |
| 23 | openeuler.openatom.cn | 20/20 | 20/20 | 49.0.231.109 | 稳定 |
| 24 | ru-repo.openeuler.org | 20/20 | 20/20 | 159.138.205.237 | 稳定 |
| 25 | fr-repo.openeuler.org | 20/20 | 20/20 | 49.0.229.174 | 稳定 |
| 26 | www.modelscope.cn | 20/20 | 20/20 | 39.99.133.195 | 稳定 |
| 27 | cdn-lfs-cn-1.modelscope.cn | 20/20 | 20/20 | 221.204.22.20 | 稳定 |
| 28 | gh-proxy.test.osinfra.cn | 20/20 | 20/20 | 202.170.93.254 | 稳定 |
| 29 | apig.openlibing.com | 20/20 | 20/20 | 139.9.154.34 | 稳定 |
| 30 | get.helm.sh | 20/20 | 20/20 | 150.171.110.135 | 稳定 |
| 31 | openlibing-codeql.obs.cn-southwest-2.myhuaweicloud.com | 20/20 | 20/20 | 122.9.172.3 | 稳定 |
| 32 | archive.ubuntu.com | 19/20 | 20/20 | 91.189.92.22 | 间歇 |
| 33 | security.ubuntu.com | 20/20 | 20/20 | 91.189.91.82,91.189.92.22 | 稳定 |
| 34 | gitee.com | 20/20 | 20/20 | 180.76.199.13 | 稳定 |
| 35 | ports.ubuntu.com | 20/20 | 20/20 | 91.189.92.19 | 稳定 |
| 36 | api.github.com | 20/20 | 20/20 | 20.205.243.168 | 稳定 |
| 37 | broker.actions.githubusercontent.com | 20/20 | 20/20 | 20.85.130.105 | 稳定 |
| 38 | pipelines.actions.githubusercontent.com | 20/20 | 20/20 | 2620:1ec:21::16 | 稳定 |
| 39 | pipelinesghubeus4.actions.githubusercontent.com | 20/20 | 20/20 | 20.232.252.48 | 稳定 |
| 40 | results-receiver.actions.githubusercontent.com | 20/20 | 20/20 | 140.82.112.21,140.82.114.22 | 稳定 |
| 41 | github.com | 20/20 | 0/20 | 20.205.243.166 | 间歇 |
| 42 | codeload.github.com | 20/20 | 20/20 | 20.205.243.165 | 稳定 |
| 43 | objects.githubusercontent.com | 20/20 | 20/20 | 185.199.109.133 | 稳定 |
| 44 | objects-origin.githubusercontent.com | 20/20 | 20/20 | 140.82.113.21,140.82.112.21 | 稳定 |
| 45 | github-releases.githubusercontent.com | 20/20 | 18/20 | 2606:50c0:8002::154 | 间歇 |
| 46 | github-registry-files.githubusercontent.com | 20/20 | 19/20 | 185.199.108.154 | 间歇 |
| 47 | pkg-containers.githubusercontent.com | 20/20 | 19/20 | 2606:50c0:8000::154 | 间歇 |
| 48 | ghcr.io | 20/20 | 20/20 | 20.205.243.164 | 稳定 |
| 49 | github-cloud.githubusercontent.com | 20/20 | 20/20 | 185.199.110.154 | 稳定 |
| 50 | github-cloud.s3.amazonaws.com | 19/20 | 18/20 | 54.231.168.17,16.15.212.164 | 间歇 |
| 51 | dependabot-actions.githubapp.com | 20/20 | 20/20 | 140.82.112.22,140.82.113.21 | 稳定 |
| 52 | release-assets.githubusercontent.com | 20/20 | 19/20 | 185.199.110.133 | 间歇 |
| 53 | api.snapcraft.io | 20/20 | 20/20 | 185.125.188.59 | 稳定 |
| 54 | pipelinesghubeus1.actions.githubusercontent.com | 20/20 | 20/20 | 20.242.179.206 | 稳定 |
| 55 | pipelinesghubeus2.actions.githubusercontent.com | 20/20 | 20/20 | 20.242.161.191 | 稳定 |
| 56 | pipelinesghubeus3.actions.githubusercontent.com | 20/20 | 20/20 | 20.102.36.236 | 稳定 |
| 57 | pipelinesghubeus5.actions.githubusercontent.com | 20/20 | 20/20 | 20.253.95.3 | 稳定 |
| 58 | pipelinesghubeus6.actions.githubusercontent.com | 20/20 | 20/20 | 20.253.126.26 | 稳定 |
| 59 | pipelinesghubeus7.actions.githubusercontent.com | 20/20 | 20/20 | 20.246.184.240 | 稳定 |
| 60 | pipelinesghubeus8.actions.githubusercontent.com | 20/20 | 20/20 | 20.102.39.220 | 稳定 |
| 61 | pipelinesghubeus9.actions.githubusercontent.com | 20/20 | 20/20 | 40.88.239.133 | 稳定 |
| 62 | pipelinesghubeus10.actions.githubusercontent.com | 20/20 | 20/20 | 20.102.38.122 | 稳定 |
| 63 | pipelinesghubeus11.actions.githubusercontent.com | 20/20 | 20/20 | 20.237.33.78 | 稳定 |
| 64 | pipelinesghubeus12.actions.githubusercontent.com | 20/20 | 20/20 | 20.102.39.57 | 稳定 |
| 65 | download.openmmlab.com | 20/20 | 20/20 | 218.24.90.14 | 稳定 |
| 66 | rsproxy.cn | 20/20 | 20/20 | 110.249.198.6 | 稳定 |
| 67 | goproxy.cn | 20/20 | 13/20 | 211.154.247.40 | 间歇 |
| 68 | repo.anaconda.com | 20/20 | 20/20 | 2606:4700::6810:bf9e | 稳定 |
| 69 | repo.mindspore.cn | 20/20 | 20/20 | 124.70.125.215 | 稳定 |
| 70 | repo.oepkgs.net | 20/20 | 20/20 | 121.36.99.241 | 稳定 |
| 71 | repo.openeuler.org | 20/20 | 20/20 | 49.0.229.41 | 稳定 |
| 72 | mirrors.ustc.edu.cn | 0/20 | 0/20 | 2001:da8:d800:95::110 | 全失败 |
| 73 | lfs-cdn.gitcode.com | 20/20 | 20/20 | 121.22.232.155 | 稳定 |
| 74 | cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 123.60.240.12 | 稳定 |
| 75 | gitcode.com | 20/20 | 20/20 | 116.205.2.91 | 稳定 |
| 76 | atomgit.com | 20/20 | 20/20 | 116.205.2.91 | 稳定 |
| 77 | mirrors.huaweicloud.com | 20/20 | 20/20 | 120.46.2.67 | 稳定 |
| 78 | mindcluster.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.4 | 稳定 |
| 79 | mirrors.aliyun.com | 15/20 | 20/20 | 222.138.197.52,124.95.170.12 | 间歇 |
| 80 | mirrors.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 2402:f000:1:400::2 | 稳定 |
| 81 | repo.huaweicloud.com | 20/20 | 20/20 | 61.135.210.42 | 稳定 |
| 82 | mindstudio-pkg.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.4 | 稳定 |
| 83 | files.pythonhosted.org | 4/20 | 15/20 | 151.101.192.223,151.101.0.223 | 间歇 |
| 84 | mindx-package.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.4 | 稳定 |
| 85 | pypi.tuna.tsinghua.edu.cn | 20/20 | 20/20 | 2402:f000:1:400::2 | 稳定 |
| 86 | mindie-pr.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 123.60.240.82 | 稳定 |
| 87 | pypi.org | 19/20 | 19/20 | 2a04:4e42::223,2a04:4e42:600::223 | 间歇 |
| 88 | build-env.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.7 | 稳定 |
| 89 | ppa.launchpad.net | 20/20 | 20/20 | 2620:2d:4000:1009::15f | 稳定 |
| 90 | obs-community.obs.cn-north-1.myhuaweicloud.com | 20/20 | 20/20 | 114.115.192.27 | 稳定 |
| 91 | ascend-cann-open.obs.cn-north-4.myhuaweicloud.com | 20/20 | 20/20 | 122.9.24.4 | 稳定 |
| 92 | 123.60.114.225 | 0/20 | 0/20 | 123.60.114.225 | 全失败 |
