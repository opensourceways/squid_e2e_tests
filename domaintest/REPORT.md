# 域名可达性对比报告 (wlcb vs gy-001)

> 第 2 轮测试时间: 2026-09-02 14:23:04  |  数据源: [ascend_ci_domains.json](ascend_ci_domains.json) (gitcode.com/zhangdiago/ci-infra @ z00833806/WhiteList)

## 测试方法

- 分别在 **wlcb**(squid `192.168.1.49`) 与 **gy-001**(squid `172.16.0.37`) 集群的 squid pod 内, 经本地代理 `127.0.0.1:3128` 对每个域名执行 `curl -sk --proxy http://127.0.0.1:3128 --max-time 6 https://<域名>/`。
- 走 squid 代理 = 与 CI build 容器**完全相同的出网路径**; `-k` 忽略证书(只看连通性); 判定: `0=可达(显示HTTP码)` / `28=TIMEOUT` / `6=DNSFAIL` / `7=CONNFAIL`。
- IP 为 **wlcb 集群 DNS** 解析结果(`getent hosts`); 通配符条目(`*.`)无法直接测, 单列。
- 上游连通为**瞬时快照**且**双向波动**(见"两轮对比"), 结论以多轮为准。

## 汇总 (第 2 轮)

| 集群 | 可达 | TIMEOUT | DNS失败 | 连接拒绝 | 实测数 |
|---|---|---|---|---|---|
| wlcb (.49) | 86 | 2 | 0 | 0 | 88 |
| gy-001 (.37) | 83 | 5 | 0 | 0 | 88 |

## 两轮对比 (变化项)

| 域名 | 第1轮 wlcb/gy001 | 第2轮 wlcb/gy001 | 说明 |
|---|---|---|---|
| pytorch-package.obs.cn-north-4.myhuaweicloud.com | TIMEOUT / 200 | 200 / 200 | **wlcb 恢复** ✅ 今天 op-plugin 故障的 OBS 源, wlcb 现已可达 |
| files.pythonhosted.org | TIMEOUT / 200 | 200 / TIMEOUT | 反向波动: wlcb 恢复, gy001 转超时 |
| github-releases.githubusercontent.com | 403 / TIMEOUT | 403 / 403 | gy001 恢复(上轮超时) |

## 两集群差异 (第 2 轮)

| 域名 | wlcb(.49) | gy-001(.37) |
|---|---|---|
| github-cloud.githubusercontent.com | 403 | TIMEOUT |
| goproxy.cn | 200 | TIMEOUT |
| files.pythonhosted.org | 200 | TIMEOUT |

## 根因分析 (DNS/路由层面)

| 域名 | 现象 | 根因 |
|---|---|---|
| `pytorch-package.obs.cn-north-4.myhuaweicloud.com` | 第1轮 wlcb TIMEOUT / 第2轮恢复 | **wlcb DNS 曾解析出华为私网 IP `100.125.x.x`**(公网不可路由)导致挂起; gy-001 仅返回公网 `121.36.121.x`。已恢复但**随时可能再波动**。 |
| `mirrors.ustc.edu.cn` | 两轮、两集群都 TIMEOUT | 两集群 DNS 均只解析到 **IPv6** `2001:da8:d800:95::110`, 集群无 IPv6 出口 → **结构性不可达**。 |
| `goproxy.cn` | 两轮 gy001 都 TIMEOUT | 解析正常(腾讯云公网 IP), gy-001 egress 到该网段被路由/防火墙阻断 → **结构性阻断**。 |
| `123.60.114.225` | 两轮、两集群都 TIMEOUT | 白名单裸 IP, 443 未开放或不可达 → **结构性不可达**。 |
| `files.pythonhosted.org` / `github-cloud...` / `github-releases...` | 两集群**轮流**超时 | 解析正常, 属各集群 egress 的**间歇性波动**(Fastly/微软/华为云 CDN 链路不稳)。 |

## 全量明细 (第 2 轮, 92 条)

| # | 域名 | IP (wlcb DNS) | wlcb(.49) | gy-001(.37) | 备注 |
|---|---|---|---|---|---|
| 1 | devcloud.cn-north-4.huaweicloud.com | 116.205.76.80 | 200 | 200 |  |
| 2 | devrepo.devcloud.cn-north-4.huaweicloud.com | 114.116.231.65 | 404 | 404 |  |
| 3 | download.pytorch.org | 65.8.76.30,65.8.76.80,13.33.151.127,65.8.76.66,99.84.152.27 | 403 | 403 |  |
| 4 | download-r2.pytorch.org | 2606:4700::6812:934,2606:4700::6812:834 | 404 | 404 |  |
| 5 | pytorch-package.obs.cn-north-4.myhuaweicloud.com | 100.125.83.133,100.125.76.5,100.125.83.5,121.36.121.227,121.36.121.226 | 200 | 200 |  |
| 6 | pta-pr.obs.cn-north-4.myhuaweicloud.com | 122.9.24.7,122.9.24.4 | 403 | 403 |  |
| 7 | mindstudio-pr.obs.cn-north-4.myhuaweicloud.com | 122.9.24.7,122.9.24.4 | 200 | 200 |  |
| 8 | www.sqlite.org | 2600:3c02::f03c:95ff:fe07:695 | 200 | 200 |  |
| 9 | sum.golang.google.cn | 114.250.65.43,114.250.67.43,120.253.253.107,114.250.70.43,114.250.64.43 | 200 | 200 |  |
| 10 | data.pyg.org | 3.165.39.92,3.165.39.39,3.165.39.106,3.165.39.19,18.66.112.104 | 200 | 200 |  |
| 11 | obs.cn-north-1.myhuaweicloud.com | 114.115.192.98,114.115.192.27,114.115.192.163 | 403 | 403 |  |
| 12 | op-svc-swr-b051-10-38-19-62-3az.obs.cn-north-4.myhuaweicloud.com | 121.36.121.197 | 403 | 403 |  |
| 13 | op-svc-swr-cn-north-4-backup.obs.cn-north-4.myhuaweicloud.com | 123.60.240.4 | 403 | 403 |  |
| 14 | obs.cn-north-9.myhuaweicloud.com | 100.125.32.30,100.125.32.62 | 403 | 403 |  |
| 15 | op-svc-swr-b051-10-147-7-14-3az.obs.cn-east-3.myhuaweicloud.com | 153.99.246.122,120.72.57.218,140.206.236.180,36.156.217.76,36.150.19.220 | 403 | 403 |  |
| 16 | op-svc-swr-cn-east-3-backup.obs.cn-east-3.myhuaweicloud.com | 121.36.235.173 | 403 | 403 |  |
| 17 | op-svc-swr-b051-10-230-33-197-3az.obs.cn-south-1.myhuaweicloud.com | 157.255.136.19,121.14.196.132,116.162.187.35,36.158.239.37,116.162.11.130 | 403 | 403 |  |
| 18 | op-svc-swr-cn-south-1-backup.obs.cn-south-1.myhuaweicloud.com | 122.9.127.212,122.9.127.211 | 403 | 403 |  |
| 19 | op-svc-swr-b051-10-205-14-19-3az.obs.cn-southwest-2.myhuaweicloud.com | 139.9.224.18 | 403 | 403 |  |
| 20 | obs.dualstack.cn-east-4.myhuaweicloud.com | 2409:2001:100:2::6 | 403 | 403 |  |
| 21 | lfs-cdn.openeuler.openatom.cn | 61.135.210.39,61.135.210.33,61.135.210.30,61.135.210.35,61.135.210.37 | 403 | 403 |  |
| 22 | artlfs.openeuler.openatom.cn | 121.36.2.159 | 200 | 200 |  |
| 23 | openeuler.openatom.cn | 49.0.231.109 | 302 | 302 |  |
| 24 | ru-repo.openeuler.org | 159.138.205.237 | 200 | 200 |  |
| 25 | fr-repo.openeuler.org | 49.0.229.174 | 301 | 301 |  |
| 26 | www.modelscope.cn | 47.92.141.220,39.99.133.195 | 302 | 302 |  |
| 27 | cdn-lfs-cn-1.modelscope.cn | 221.204.22.21,119.249.48.42,221.204.22.24,221.204.22.23,119.249.48.40 | 403 | 403 |  |
| 28 | gh-proxy.test.osinfra.cn | 202.170.93.254 | 200 | 200 |  |
| 29 | apig.openlibing.com | 139.9.154.34 | 404 | 404 |  |
| 30 | get.helm.sh | 150.171.110.133 | 404 | 404 |  |
| 31 | openlibing-codeql.obs.cn-southwest-2.myhuaweicloud.com | 122.9.172.2,122.9.172.3 | 403 | 403 |  |
| 32 | archive.ubuntu.com | 91.189.92.24,91.189.91.82,91.189.92.22,185.125.190.81,91.189.91.81 | 200 | 200 |  |
| 33 | security.ubuntu.com | 91.189.91.83,91.189.91.82,185.125.190.82,91.189.92.23,91.189.91.81 | 301 | 301 |  |
| 34 | gitee.com | 180.76.199.13 | 200 | 200 |  |
| 35 | ports.ubuntu.com | 91.189.92.20,91.189.91.103,91.189.91.104,91.189.92.19,91.189.91.102 | 200 | 200 |  |
| 36 | api.github.com | 20.205.243.168 | 200 | 200 |  |
| 37 | broker.actions.githubusercontent.com | 20.85.130.105 | 404 | 404 |  |
| 38 | pipelines.actions.githubusercontent.com | 2620:1ec:21::16 | 404 | 404 |  |
| 39 | *.blob.core.windows.net | 通配符 | — | — | 白名单通配条目(*.) |
| 40 | pipelinesghubeus4.actions.githubusercontent.com | 20.232.252.48 | 404 | 404 |  |
| 41 | results-receiver.actions.githubusercontent.com | 140.82.112.22,140.82.112.21,140.82.113.21,140.82.113.22,140.82.114.22 | 404 | 404 |  |
| 42 | github.com | 20.205.243.166 | 200 | 200 |  |
| 43 | *.actions.githubusercontent.com | 通配符 | — | — | 白名单通配条目(*.) |
| 44 | codeload.github.com | 20.205.243.165 | 301 | 301 |  |
| 45 | objects.githubusercontent.com | 185.199.109.133,185.199.108.133,185.199.110.133,185.199.111.133 | 404 | 404 |  |
| 46 | objects-origin.githubusercontent.com | 140.82.114.22,140.82.112.21,140.82.112.22,140.82.113.21,140.82.113.22 | 405 | 405 |  |
| 47 | github-releases.githubusercontent.com | 2606:50c0:8003::154,2606:50c0:8000::154,2606:50c0:8001::154,2606:50c0:8002::154 | 403 | 403 |  |
| 48 | github-registry-files.githubusercontent.com | 185.199.108.154,185.199.109.154,185.199.111.154,185.199.110.154 | 403 | 403 |  |
| 49 | *.pkg.github.com | 通配符 | — | — | 白名单通配条目(*.) |
| 50 | pkg-containers.githubusercontent.com | 2606:50c0:8003::154,2606:50c0:8000::154,2606:50c0:8001::154,2606:50c0:8002::154 | 400 | 400 |  |
| 51 | ghcr.io | 20.205.243.164 | 301 | 301 |  |
| 52 | github-cloud.githubusercontent.com | 185.199.108.154,185.199.109.154,185.199.110.154,185.199.111.154 | 403 | TIMEOUT |  |
| 53 | github-cloud.s3.amazonaws.com | 16.182.105.33,52.217.117.217,54.231.193.113,52.217.73.204,16.15.252.6 | 403 | 403 |  |
| 54 | dependabot-actions.githubapp.com | 140.82.113.21,140.82.112.21,140.82.112.22,140.82.114.21,140.82.114.22 | 404 | 404 |  |
| 55 | release-assets.githubusercontent.com | 185.199.109.133,185.199.110.133,185.199.108.133,185.199.111.133 | 404 | 404 |  |
| 56 | api.snapcraft.io | 185.125.188.60,185.125.188.54,185.125.188.57,185.125.188.55,185.125.188.58 | 200 | 200 |  |
| 57 | *.core.windows.net | 通配符 | — | — | 白名单通配条目(*.) |
| 58 | pipelinesghubeus1.actions.githubusercontent.com | 20.242.179.206 | 404 | 404 |  |
| 59 | pipelinesghubeus2.actions.githubusercontent.com | 20.242.161.191 | 404 | 404 |  |
| 60 | pipelinesghubeus3.actions.githubusercontent.com | 20.102.36.236 | 404 | 404 |  |
| 61 | pipelinesghubeus5.actions.githubusercontent.com | 20.253.95.3 | 404 | 404 |  |
| 62 | pipelinesghubeus6.actions.githubusercontent.com | 20.253.126.26 | 404 | 404 |  |
| 63 | pipelinesghubeus7.actions.githubusercontent.com | 20.246.184.240 | 404 | 404 |  |
| 64 | pipelinesghubeus8.actions.githubusercontent.com | 20.102.39.220 | 404 | 404 |  |
| 65 | pipelinesghubeus9.actions.githubusercontent.com | 40.88.239.133 | 404 | 404 |  |
| 66 | pipelinesghubeus10.actions.githubusercontent.com | 20.102.38.122 | 404 | 404 |  |
| 67 | pipelinesghubeus11.actions.githubusercontent.com | 20.237.33.78 | 404 | 404 |  |
| 68 | pipelinesghubeus12.actions.githubusercontent.com | 20.102.39.57 | 404 | 404 |  |
| 69 | download.openmmlab.com | 124.95.157.82,36.163.116.58,124.95.157.86,124.95.157.84,124.95.157.83 | 403 | 403 |  |
| 70 | rsproxy.cn | 101.126.58.175,101.126.58.176,122.14.229.103,101.126.58.177,110.249.198.6 | 200 | 200 |  |
| 71 | goproxy.cn | 211.154.247.40,36.156.9.206,36.110.220.112,36.156.9.207,36.110.220.110,36.110.220.113,36.110.220.114,36.110.220.111,211.154.244.168 | 200 | TIMEOUT |  |
| 72 | repo.anaconda.com | 2606:4700::6810:bf9e,2606:4700::6810:20f1 | 200 | 200 |  |
| 73 | mirrors.ustc.edu.cn | 2001:da8:d800:95::110 | TIMEOUT | TIMEOUT |  |
| 74 | lfs-cdn.gitcode.com | 121.22.232.157,121.22.232.156,121.22.232.155,121.22.232.153,223.68.255.156 | 403 | 403 |  |
| 75 | cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com | 123.60.240.12,123.60.240.13 | 403 | 403 |  |
| 76 | gitcode.com | 116.205.2.91 | 200 | 200 |  |
| 77 | atomgit.com | 116.205.2.91 | 200 | 200 |  |
| 78 | mirrors.huaweicloud.com | 120.46.2.67,1.92.76.132,123.249.118.101,124.70.61.162,120.46.63.139 | 200 | 200 |  |
| 79 | mindcluster.obs.cn-north-4.myhuaweicloud.com | 122.9.24.7,122.9.24.4 | 403 | 403 |  |
| 80 | mirrors.aliyun.com | 27.221.122.13,218.61.62.112,218.24.82.120,116.196.142.20,218.61.162.30 | 301 | 301 |  |
| 81 | mirrors.tuna.tsinghua.edu.cn | 2402:f000:1:400::2 | 200 | 200 |  |
| 82 | repo.huaweicloud.com | 61.135.210.34,61.135.210.41,61.135.210.30,61.135.210.44,61.135.210.43 | 301 | 301 |  |
| 83 | mindstudio-pkg.obs.cn-north-4.myhuaweicloud.com | 122.9.24.7,122.9.24.4 | 200 | 200 |  |
| 84 | files.pythonhosted.org | 151.101.192.223,151.101.128.223,112.121.185.26,151.101.0.223,151.101.64.223 | 200 | TIMEOUT |  |
| 85 | mindx-package.obs.cn-north-4.myhuaweicloud.com | 122.9.24.7,122.9.24.4 | 200 | 200 |  |
| 86 | pypi.tuna.tsinghua.edu.cn | 2402:f000:1:400::2 | 302 | 302 |  |
| 87 | mindie-pr.obs.cn-north-4.myhuaweicloud.com | 123.60.240.83 | 403 | 403 |  |
| 88 | pypi.org | 2a04:4e42:400::223,2a04:4e42::223,2a04:4e42:600::223,2a04:4e42:200::223 | 200 | 200 |  |
| 89 | build-env.obs.cn-north-4.myhuaweicloud.com | 122.9.24.4,122.9.24.7 | 403 | 403 |  |
| 90 | ppa.launchpad.net | 2620:2d:4000:1009::1ed,2620:2d:4000:1009::12c,2620:2d:4000:1009::15f | 302 | 302 |  |
| 91 | obs-community.obs.cn-north-1.myhuaweicloud.com | 114.115.192.27,114.115.192.98,114.115.192.163 | 403 | 403 |  |
| 92 | 123.60.114.225 | 123.60.114.225 | TIMEOUT | TIMEOUT |  |
