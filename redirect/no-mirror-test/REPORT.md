# no-mirror-test 全量回归报告（squid v7.7.2 AKI 补丁版）

- **日期**：2026-09-16
- **集群**：gy-006（openmerlin-guiyang-006），namespace `squid`
- **被测版本**：
  - chart `version: 0.1.11`（产品定版；注释中"chart 0.1.13/0.1.14/0.1.15"为测试期配置状态叙事代号，2026-09-16 回归 Chart.yaml 到产品版本，未落入 Chart.yaml）
  - squid 镜像 `v7.7.2`（自建，含 gadgets.cc AKI 补丁，见 `redirect/squid-aki-test/PLAN.md`）
  - CM（squid-config）在本 chart 模板之上叠加当日内容微调（2026-09-16，按"配置微调不 bump"约定 chart 版本未动）：conda 重写目标 tuna→nju、github release/archive refresh_pattern 合并为原始 host 规则
- **执行方式**：`./run-all.sh`（Volcano Job 串行下发，轮询 Pod phase，日志落 `/tmp/no-mirror-rerun.log`）
- **结论**：**14/14 全部 Succeeded**，零客户端配置（zero client config）下重写链路 + 缓存 + AKI 补丁全部验证通过

## 一、总体结果

| 用例 | Job | 结果 | 耗时 | 关键证据 |
|---|---|---|---|---|
| tool-01 pip | test-squid-pip-cnj2v | ✅ | 75.5s | 官方 index 安装 requests/pyyaml/pytest 全过；torch wheel 146MB HTTP=200 |
| tool-02 apt | test-squid-apt-drwjf | ✅ | 12.0s | `apt-get update` 4s，官方 ports.ubuntu.com URI 经重写生效 |
| tool-03 github | test-squid-github-npch6 | ✅ | 9.7s | git clone 完成（raw/archive→gh-proxy） |
| tool-04 goproxy | test-squid-goproxy-ndtzh | ✅ | 34.5s | go module 经 proxy.golang.org→goproxy.cn |
| tool-06 wget | test-squid-wget-sd6rh | ✅ | 1.4s | wget 大文件下载 |
| tool-07 cmake fetchcontent | test-squid-cmake-pq4ll | ✅ | 75.1s | googletest 拉取+构建+测试通过 |
| tool-08 bazel | test-squid-bazel-9785k | ✅ | 27.3s | http_archive 拉取+构建通过（JVM truststore 注入） |
| tool-09 npm | test-squid-npm-542d5 | ✅ | 4.9s | express 装载成功（registry.npmjs.org→npmmirror） |
| tool-10 cargo | test-squid-cargo-gtrct | ✅ | 11.3s | crate 拉取+构建成功（→rsproxy） |
| tool-11 conda | test-squid-conda-rwtsf | ✅ | 808.1s* | **numpy 2.4.6 works through squid**（AKI 补丁核心验证项） |
| tool-12 uv | test-squid-uv-7cqfx | ✅ | 9.0s | uv 安装 Python 成功 |
| tool-14 git-lfs | test-squid-gitlfs-j7krc | ✅ | 3.2s | LFS 对象经代理下载 |
| tool-15 pnpm | test-squid-pnpm-t7b8f | ✅ | 14.4s | pnpm 安装 express 成功 |
| tool-16 yum | test-squid-yum-xrshk | ✅ | 41.7s | openEuler RPM 经 host 交换→华为云 |

\* tool-11 本次 808s 中含约 725s 的 Miniconda 安装包回源慢速事件（见第三节），换源后复测仅 78s。

## 二、AKI 补丁验证（本轮核心目标）

- client-first bump 伪造证书缺 AKI 导致 Python 3.13+/conda 26 strict 校验拒签的问题已由 v7.7.2 补丁解决；
- tool-11-conda（conda 26 装numpy，Python 3.13+ 客户端）由 FAIL 翻绿；
- 客户端版本矩阵（openssl strict / Python 3.10–3.14 / node 24 / go / rustls）另见 `redirect/AKItest/RESULTS.md`，14/14 全 PASS。

## 三、过程中的两个事件与处置

### 事件 1：tool-01-pip 首跑偶发失败（非 squid 问题）

- 现象：`test-squid-pip-wcbwv` 存活 65s，exit 1，日志在 bulk pip download 处戛然而止。
- 根因：首次 `pip download` 碰到**瞬时网络错误**（非包解析类），诊断分支 `BAD=$(grep -oE "requirement ..." | ... )` 因 `set -e`+`pipefail` 在 grep 无匹配时被静默杀死，真实报错随容器销毁丢失。
- 处置：[tool-01-pip.yaml](.) 诊断分支补 `|| true`；同 yaml 重跑（cnj2v）75s 全绿，实锤偶发。

### 事件 2：tool-11 Miniconda 安装包回源慢（tuna 链路拥堵）→ 换源 nju

access.log 实测同一 URL（经重写落 tuna）三次下载：

| 时间 | 副本 | 缓存状态 | 耗时 | 吞吐 |
|---|---|---|---|---|
| 14:41 | squid-cache-1 | TCP_MISS | 20.7s | 9.5 MB/s |
| 15:54 | squid-cache-1 | TCP_REFRESH_UNMODIFIED | 6s | 读盘级 |
| 16:37 | squid-cache-0 | TCP_MISS | **725s** | **271 KB/s** |

- 双副本独立缓存 + Service 轮询导致本次落在无缓存的 squid-cache-0 → 必然 MISS，而 tuna 回源链路正处拥堵窗口。
- **A/B 实测**（20MB 分段、随机 query 绕缓存、走 squid 回源，各 2 轮）：
  - tuna：2.5 / 4.8 MB/s
  - **nju（mirror.nju.edu.cn）：25.9 / 22.6 MB/s（6~7 倍）**
- nju 与 tuna 目录完全同构（`/anaconda/cloud/<ch>`、`/anaconda/pkgs/`、`/anaconda/miniconda/`），helper 两条 conda 规则仅换 host。
- **处置**：chart configmap 模板 conda 重写目标 tuna→nju（含注释留档）；`helm template + kubectl apply` squid-config CM；`rollout restart sts/squid-cache`（2/2 ready）。
- **复测**（test-squid-conda-fhd8n）：安装包下载 **9.8s（196MB，≈20 MB/s）**，场景总耗时 78s，numpy 2.4.6 安装成功；access.log 落点实锤：
  `TCP_MISS/200 196163320 GET https://mirror.nju.edu.cn/anaconda/miniconda/... - HIER_DIRECT/210.28.130.3`

## 四、gy-005 部署与全量回归（2026-09-16 同日）

- **部署**：`helm upgrade squid ./chart -f values-gy-005.yaml --kubeconfig ~/.kube/gy-005.yaml`（REVISION 5）。
  values 更新：镜像 `v7.7.2`（AKI 补丁版，`imagePullPolicy: Always`）+ `urlRewrite.enabled: true`（纯 rewrite 架构对齐 gy-006）。
  gy-005 原跑 v7.7.1、无重写（首建 2026-09-12，values 文件头部"全新部署"注释已过时并修正）。
- **端口分工注意**：squid 监听 **3129**（ssl-bump），rpardini nginx 占 3128（仅作 squid 的 registry cache_peer）；
  Service 3128→targetPort 3129，外部客户端走 Service 无感。Pod 内 sanity check 必须打 3129，打 3128 会绕过 squid。
- **结果：14/14 全部 Succeeded，总耗时约 10 分钟**（`KC=~/.kube/gy-005.yaml LOG=/tmp/no-mirror-rerun-005.log ./run-all.sh`）：

| 用例 | Job | 耗时 | 要点 |
|---|---|---|---|
| tool-01 pip | test-squid-pip-8gdr6 | 87.9s | 194MB torch whl 下载+安装 |
| tool-02 apt | test-squid-apt-gwdnn | 10.0s | update 2s |
| tool-03 github | test-squid-github-4tq7b | 9.0s | git clone |
| tool-04 goproxy | test-squid-goproxy-9sxzp | 15.1s | go 模块 |
| tool-06 wget | test-squid-wget-hgjw4 | 4.0s | github 包下载 |
| tool-07 cmake | test-squid-cmake-6m77m | 22.5s | googletest fetch+build |
| tool-08 bazel | test-squid-bazel-8vk4z | 20.1s | http_archive + test |
| tool-09 npm | test-squid-npm-h5brv | 10.1s | express |
| tool-10 cargo | test-squid-cargo-22d9k | 8.7s | fetch+build |
| tool-11 conda | test-squid-conda-svlg2 | **43.9s** | **nju 重写直接生效**（对比 006 tuna 时代分钟级），numpy 2.4.6 |
| tool-12 uv | test-squid-uv-jf9ds | 5.0s | uv |
| tool-14 git-lfs | test-squid-gitlfs-lb8xk | 5.2s | lfs objects |
| tool-15 pnpm | test-squid-pnpm-fgm57 | 8.2s | pnpm express |
| tool-16 yum | test-squid-yum-zdtj8 | 35.7s | yum 全套 |

- 结论：纯 rewrite 架构 + AKI 补丁版在 gy-005 一次部署即全绿，零客户端配置。

## 五、复现方式

```bash
cd redirect/no-mirror-test
./run-all.sh          # 默认 gy-006；退出码 0=全过；明细日志 /tmp/no-mirror-rerun.log
# 其他集群用 KC/LOG 覆写：
KC=~/.kube/gy-005.yaml LOG=/tmp/no-mirror-rerun-005.log ./run-all.sh
```

- 单用例：`kubectl --kubeconfig ~/.kube/gy-006.yaml create -f tool-11-conda.yaml -o name` 后轮询 Pod phase。
- 注意：Volcano Job `get jobs` 不可见、condition 名为 `Completed`，勿用 `kubectl wait --for=condition=complete`（run-all.sh 已规避，踩坑史见脚本头注释）。
