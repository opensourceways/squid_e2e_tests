# 工具缓存 e2e 测试 · 纯 rewrite 验证版（no-mirror-test）

> 基准对照版（客户端显式配镜像）：`traffic-test/tool/`
> 本目录版本：脚本**零镜像配置**，全部官方 URL，加速完全依赖 squid `url_rewrite` 透明重写。

## 1. 目的

验证 **「客户端零镜像配置 + squid url_rewrite 透明重写」端到端成立**：

- 15 个 CI 工具 e2e 测试脚本全部改回**官方默认源**（pypi.org / ports.ubuntu.com / github.com /
  proxy.golang.org / registry.npmjs.org / crates.io / repo.anaconda.com / repo.openeuler.org …）；
- gy-006 集群 squid（chart 0.1.11，client-first bump + url_rewrite helper）在**服务端**把**全部
  可加速域**（§2 规则 1–13）透明重写到镜像站，客户端不感知、不配置任何镜像；
  **不留"直连基线"缺口**——凡基准版里配了镜像的工具，本套件必须由重写覆盖并实测通过；
- 与 `traffic-test/tool/`（客户端显式配镜像的基准版）形成 **A/B 对照**：同场景各跑一遍，
  对比时延/吞吐，量化「透明重写 vs 客户端配镜像」的收益差。

## 2. squid 透明重写规则（gy-006 线上生效）

| # | 客户端请求（官方 URL） | squid 重写为 | 语义 |
|---|---|---|---|
| 1 | `pypi.org/simple/*` | `repo.huaweicloud.com/repository/pypi/simple/*` | 索引重写；索引页内对象为同域相对路径，无混源 |
| 2 | `github.com/*/archive/*` | `gh-proxy.test.osinfra.cn/<原URL>` | 前缀重写 |
| 3 | `github.com/*/releases/download/*` | `gh-proxy.test.osinfra.cn/<原URL>` | 前缀重写 |
| 4 | `proxy.golang.org/*` | `goproxy.cn/*` | go 模块下载与 sumdb 校验（默认走 GOPROXY 路径）一并重写，无需配 GOSUMDB |
| 5 | `archive.ubuntu.com/*`、`ports.ubuntu.com/*` | `repo.huaweicloud.com/*` | host 交换，路径不变 |
| 6 | `registry.npmjs.org/*` | `registry.npmmirror.com/*` | host 交换（路径完全同构；tarball immutable 长缓存） |
| 7 | `index.crates.io/*` | `rsproxy.cn/index/*` | cargo sparse index 交换；其 config.json dl 指回 rsproxy，tarball 下载随之透明 |
| 8 | `static.crates.io/crates/*` | `rsproxy.cn/crates/*` | crate 对象交换（`.crate$` 长缓存规则已覆盖） |
| 9 | `conda.anaconda.org/*` | `mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/*` | conda channel host 交换（结构同构） |
| 10 | `repo.anaconda.com/pkgs/*`、`repo.anaconda.com/miniconda/*` | `mirrors.tuna.tsinghua.edu.cn/anaconda/*` | installer / pkgs host 交换 |
| 11 | `repo.openeuler.org/*` | `mirrors.huaweicloud.com/openeuler/*` | yum 源 host 交换（路径同构；`.rpm$` 长缓存） |
| 12 | `files.pythonhosted.org/packages/*` | `repo.huaweicloud.com/repository/pypi/packages/*` | pypi 对象域兜底（客户端硬编码 files.pythonhosted 时，路径同构） |
| 13 | `raw.githubusercontent.com/*` | `gh-proxy.test.osinfra.cn/<原URL>` | gh-proxy 白名单支持 raw 形态 |
| — | **其余域**（git clone、api.github.com、download.openmmlab.com、obs-community、pytorch 官方等） | **不重写** | splice/bump 原样放行（官方源本身可达或无同构镜像） |

## 3. 相对基准版剥离的镜像配置清单（本文档核心）

通用剥离（01–12、14、15、16 几乎全部命中）：

| 原配置（基准版） | 改为（本目录） |
|---|---|
| apt 换源 sed 两行：`sed -i 's\|http://ports.ubuntu.com/ubuntu-ports\|http://mirrors.huaweicloud.com/ubuntu-ports\|g' /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list` | **删除**，保留官方 `ports.ubuntu.com`，由 squid 规则 5 做 host 交换 |
| postStart `.bazelrc` heredoc 中的 `common --registry=https://gh-proxy.test.osinfra.cn/https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/` | **只删这一行**；保留 `--noenable_bzlmod` / `--cxxopt` / trustStore 三类行 |

逐文件清单：

| 文件 | 剥掉什么 → 改成什么官方默认 |
|---|---|
| **tool-01-pip** | ① pip 三处 index：`-i https://mirrors.huaweicloud.com/repository/pypi/simple`（requests）、`--index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple`（pyyaml）、`--index-url https://repo.huaweicloud.com/repository/pypi/simple`（pytest）→ 全部删掉，用默认官方 index（pypi.org，squid 重写）；三个 echo 标签 `(pypi.org)/(tsinghua)/(huaweicloud)` 统一为 `(official index)`。② vllm requirements.txt 的 curl：`https://gh-proxy.test.osinfra.cn/https://raw.githubusercontent.com/...` → `https://raw.githubusercontent.com/vllm-project/vllm-ascend/main/requirements.txt`（raw 域不重写、直连放行）。③ TORCH_URL：`https://repo.huaweicloud.com/repository/pypi/packages/...` → `https://files.pythonhosted.org/packages/78/89/f5554b13ebd71e05c0b002f95148033e730d3f7067f67423026cc9c69410/torch-2.10.0-cp311-cp311-manylinux_2_28_aarch64.whl`（官方对象域，由 squid 规则 12 重写回华为云 packages）。④ 删 `BULK_INDEX` 变量与 `--index-url "$BULK_INDEX"`（pip download 用默认官方 index） |
| **tool-02-apt** | 删 apt 换源 sed；`grep -h "mirrors.huaweicloud" ...` → `grep -h "URIs: http://ports.ubuntu.com" /etc/apt/sources.list.d/ubuntu.sources \| head -1`（确认官方源在用，重写交给 squid） |
| **tool-03-github** | 删 `git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com".insteadOf "https://github.com"` 及其后 `git config --global --get-regexp 'url\.'` 两行；clone 直连官方 `github.com`（git 协议 CONNECT 隧道走 squid，不重写） |
| **tool-04-goproxy** | ① 删 `go env -w GOPROXY=https://goproxy.cn,direct`、`go env -w GOSUMDB=sum.golang.google.cn` 两行及 `echo "GOPROXY = ..."` → 默认 `proxy.golang.org`（squid 重写到 goproxy.cn；sumdb 校验走 GOPROXY 路径一并重写，无需 GOSUMDB）。② Go 工具链：删 aliyun tarball 下载+解压 4 行（`GO_TARBALL`/`curl mirrors.aliyun.com`/`tar`/`export PATH`）→ 官方 `https://go.dev/dl/go1.26.0.linux-arm64.tar.gz`（chart 0.1.12 规则 5b 重写 go.dev/dl、dl.google.com/go → mirrors.aliyun.com/golang；apt 的 golang-go 1.22 的 GOTOOLCHAIN 解析有缺陷，请求不存在的 v0.0.1-go1.26 字面版本，不能用） |
| **tool-06-wget** | 只删 apt 换源 sed（`download.openmmlab.com` 是官方源，保留） |
| **tool-07-cmake-fetchcontent** | CMakeLists 内 `GIT_REPOSITORY https://gh-proxy.test.osinfra.cn/https://github.com/google/googletest.git` → `https://github.com/google/googletest.git`（git clone 不重写；archive 包才重写） |
| **tool-08-bazel** | ① 主脚本 `.bazelrc` heredoc 删 `common --registry=...` 行。② WORKSPACE 里 4 个 `http_archive` 的 urls 全部去掉 `https://gh-proxy.test.osinfra.cn/` 前缀：googletest、bazel-skylib、rules_cc、rules_python（rules_python 保持 `bazel-contrib` org 不变，只去前缀），相关 gh-proxy 注释同步改写为「官方 github URL，archive/releases 由 squid 重写到 gh-proxy」 |
| **tool-09-npm** | 删 `npm config set registry https://registry.npmmirror.com/` → 默认 `registry.npmjs.org`，由 squid 规则 6 重写到 npmmirror；scenario echo 注释同步改 |
| **tool-10-cargo** | 删整段 `mkdir -p ~/.cargo` + `config.toml` rsproxy heredoc（`replace-with = "rsproxy-sparse"` / `sparse+https://rsproxy.cn/index/`）→ 默认 crates.io（`index.crates.io` + `static.crates.io`），由 squid 规则 7/8 重写到 rsproxy；注释同步改 |
| **tool-11-conda** | ① miniconda 下载：`https://mirror.nju.edu.cn/anaconda/miniconda/...` → `https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh`（规则 10 重写到 tuna）。② `conda create ... --override-channels -c https://mirror.nju.edu.cn/anaconda/cloud/conda-forge/ ...` → `conda create -y -n testenv -c conda-forge python=3.11 numpy`（conda.anaconda.org 由规则 9 重写） |
| **tool-12-uv** | 删 `export UV_DEFAULT_INDEX=https://mirrors.tuna.tsinghua.edu.cn/pypi/simple`；`pip install uv` 去掉 `-i https://mirrors.huaweicloud.com/repository/pypi/simple` |
| **tool-14-gitlfs** | ① git-lfs release 下载 URL 去 `https://gh-proxy.test.osinfra.cn/` 前缀 → 官方 `github.com/git-lfs/git-lfs/releases/download/...`（releases/download 会被 squid 重写，正好验证）。② `git clone https://gh-proxy.test.osinfra.cn/https://github.com/git-lfs/git-lfs` → `https://github.com/git-lfs/git-lfs`（clone 不重写、直连，注释标注观测点） |
| **tool-15-pnpm** | 删 `npm config set registry https://registry.npmmirror.com/` 与 `pnpm config set registry https://registry.npmmirror.com/` 两行 → 默认 npmjs；echo 标签 `(cold, via npmmirror)` → `(cold, default registry.npmjs.org)` |
| **tool-16-yum** | 删 huaweicloud 换源整段：`sed -i 's\|https://repo.openeuler.org\|https://mirrors.huaweicloud.com/openeuler\|g; /^metalink=/d' /etc/yum.repos.d/*.repo` 及其后 `grep -h "baseurl"` 行 → 保留官方 `repo.openeuler.org` + metalink |

未纳入本套件的基准版用例：`05-obs.yaml`（obs-community 域不在重写范围，测的是 AK/SK 凭证与重写无关，2026-09-15 用户拍板移除）、`13-huggingface.yaml`（按需求排除）、`17-docker-pull.yaml`（走 registry-proxy sidecar，机制不同）。

## 4. 运行方法

### 4.1 一键循环（全部 14 个，按文件名顺序）

```bash
cd /home/chenqi252/code/gitcode-ci/workspace-squid/squid_e2e_tests/.worktrees/docs-mirror-cache-topic/redirect/no-mirror-test

K="kubectl --kubeconfig $HOME/.kube/gy-006.yaml -n squid"
for f in tool-*.yaml; do
  echo ">>> apply $f"
  $K apply -f "$f"
  sleep 2   # generateName 异步生成 Job，稍等再取
  JOB=$($K get jobs -o name --field-selector=status.successful=0 2>/dev/null | grep test-squid- | tail -1)
  echo ">>> waiting for $JOB"
  if $K wait --for=condition=complete "$JOB" --timeout=2400s; then
    $K logs "$JOB" | grep -E '✅|DURATION'
  else
    echo "!!! FAILED/TIMEOUT: $f ($JOB)"
    $K logs "$JOB" --tail=50 || true
  fi
done
```

说明：Job 用 `generateName: test-squid-*`，名字随机，所以 apply 后用
`kubectl get jobs --field-selector=status.successful=0`（未完成 Job）+ `grep test-squid-` 取最新一个。

### 4.2 单文件运行示例（以 tool-01-pip 为例）

```bash
K="kubectl --kubeconfig $HOME/.kube/gy-006.yaml -n squid"
$K apply -f tool-01-pip.yaml
sleep 2
JOB=$($K get jobs -o name --field-selector=status.successful=0 | grep test-squid-pip | tail -1)
$K wait --for=condition=complete "$JOB" --timeout=2400s
$K logs "$JOB"
```

### 4.3 一键清理

```bash
K="kubectl --kubeconfig $HOME/.kube/gy-006.yaml -n squid"
$K delete jobs -l 'pipeline/run-id' --field-selector=status.successful=1   # 或按 name 前缀删除
```

## 5. 取结果与成功判定

- 取日志：`kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid logs job/<name>`；
- **成功标准**：对应工具的步骤命令全部 rc=0（Volcano Job 的 Pod 正常 Complete），且日志内出现：
  - 每个场景的 `✅ ... completed.`（如 `✅ Scenario 1 completed.`）；
  - `DURATION: <n>ms` 总耗时行；
  - 各文件自身的成功 echo（如 `✅ express loads, npm works through squid`、
    `✅ googletest fetched + built, tests pass` 等）；
- 任何一步失败会因 `set -e`（个别为 `set -o pipefail`）使脚本非零退出，Pod 状态 Failed；
  循环跑批时用 `kubectl get pods -n squid | grep -v Completed` 快速定位失败 Pod。

## 6. squid 侧观察（重写生效证据）

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid exec squid-cache-0 -c squid -- tail -f /var/log/squid/access.log
```

**重写生效的证据**（access.log 中目标域已变）：

| 看到什么 | 说明哪条规则生效 |
|---|---|
| `repo.huaweicloud.com/repository/pypi/simple/...` | pip/uv 官方 index 被 squid 规则 1 重写 |
| `repo.huaweicloud.com/repository/pypi/packages/...` | 规则 12：files.pythonhosted 硬编码对象（tool-01 torch wheel） |
| `gh-proxy.test.osinfra.cn/https://github.com/.../archive/...`、`.../releases/download/...` | 规则 2/3：bazel http_archive、git-lfs release、wget 的 github 包 |
| `gh-proxy.test.osinfra.cn/https://raw.githubusercontent.com/...` | 规则 13：tool-01 的 requirements.txt curl |
| `goproxy.cn/...`（含 `@v/list`、`sumdb/` 路径） | 规则 4：go mod / GOTOOLCHAIN / sumdb 校验 |
| `repo.huaweicloud.com/ubuntu-ports/...` | 规则 5：apt 官方 ports 源 host 交换（access.log 里只见 repo.huaweicloud.com，客户端仍配 ports.ubuntu.com） |
| `registry.npmmirror.com/...` | 规则 6：npm/pnpm 官方 registry host 交换（tool-09/15） |
| `rsproxy.cn/index/...`、`rsproxy.cn/crates/...` | 规则 7/8：cargo sparse index + crate 下载（tool-10） |
| `mirrors.tuna.tsinghua.edu.cn/anaconda/...` | 规则 9/10：conda channel 与 miniconda installer（tool-11） |
| `mirrors.huaweicloud.com/openeuler/...` | 规则 11：yum 官方源 host 交换（tool-16） |

**本地缓存验证（MISS→HIT 二连发）**：

1. 在客户端 Pod 内对同一 URL 连续下载两次（或重跑同一场景，GOMODCACHE/pip cache 清掉后重跑）；
2. access.log 第一次应为 `TCP_MISS/200`（回源），第二次应为 `TCP_MEM_HIT` / `TCP_HIT` / `TUNNEL` 复用（视 bump 与对象而定）；
3. 时间对比：HIT 那次时延应显著下降（大文件尤其明显）。

## 7. 已知边界 / 风险

- **git clone / api.github.com 不重写**，bump 直连或 splice 放行（clone 透明重写实验见 §8）；
- **go sumdb 校验走 GOPROXY 路径**（`proxy.golang.org/sumdb/...`），会被规则 4 一并重写到
  goproxy.cn，因此**无需**配 GOSUMDB/GONOSUMDB，删除客户端配置不影响校验；
- **双副本 squid-cache-0/1 缓存相互独立**：Service 轮询下二连发可能落到另一副本，
  第二次仍 MISS。判定 TCP_HIT 时要结合 **本 Pod 的 access.log** 看（exec 到同一只 squid 里 tail），
  必要时多连发几次覆盖两个副本；
- **13-huggingface 与 17-docker-pull 未纳入**：前者按需求排除；后者走 registry-proxy sidecar
  机制，与 url_rewrite 无关；
- **cargo host-swap 的两层语义**（规则 7/8）：index.crates.io → rsproxy.cn/index 使 sparse index
  可达；其返回的 config.json 里 dl 字段指回 rsproxy.cn/crates → cargo 后续 tarball 下载直接请求
  rsproxy.cn（客户端视角仍是"官方流程"，无感知）；规则 8 兜底覆盖显式 static.crates.io 请求；
- **conda repodata 较大**：tuna 的 repodata.json 未配专属 refresh_pattern，走 catch-all
  `0 0% 0 refresh-ims`（每次带 LM 校验回源，可用但慢）；若观测到瓶颈再补 `0 20% 4320` 规则；
- **镜像站行为差异**：npmmirror/rsproxy/tuna 对 origin 的元数据新鲜度有同步延迟（分钟级），
  CI 场景（发版后立刻拉取）可能撞上 404——当前按"可接受"处理，撞上即重试。

## 8. TODO：git clone 透明重写实验（待做）

**动机**：当前 git clone 不重写（见 §7），CI runner 想走 gh-proxy 必须逐台配客户端
`insteadOf`。若 squid 层能接管 clone，则 runner 零配置。

**为什么现在没做**：clone 是 smart HTTP **会话**（`GET /info/refs?service=git-upload-pack`
+ `POST /git-upload-pack` 流式对象包），不是单文件 URL——重写成功也只有纯转发、0 缓存收益；
且 gh-proxy（hunshcn 系）白名单只认文件形态，对 chunked POST 的兼容性未验证。

**实验方案**（比全量 `https://github.com/*` 稳：不碰 API/raw/对象域）：helper 加两条窄规则，
只命中 git 协议端点（POST 请求同样会过 url_rewrite）：

```sh
# 试点规则（放 case *) 之前）：
https://github.com/*/info/refs*|https://github.com/*/git-upload-pack)
  echo "OK rewrite-url=\"https://gh-proxy.test.osinfra.cn/${url}\"" ;;
```

**验证步骤**：
1. 改 chart helper（configmap.yaml 内嵌 rewrite-helper.sh，版本仍归 0.1.11）；
2. `helm upgrade` + **`kubectl rollout restart sts/squid-cache`**（CM 内容变更不滚动 pod，
   subPath 挂载不热更新——必做）；
3. 跑 tool-03（clone vllm-ascend）与 tool-14（clone git-lfs + lfs pull），对照
   access.log：clone 会话的 `info/refs` / `git-upload-pack` 应出现在
   `gh-proxy.test.osinfra.cn` 前缀下；
4. 对照基准：不重写时的 clone 时延（本目录 tool-03/14 首轮结果即直连基线）；
5. 风险观测：upload-pack chunked POST 经 gh-proxy/nginx 是否被拒（411/502）、大仓
   clone 吞吐劣化程度、git 凭据/进度语义是否破坏。

**收尾**：成功 → helper 规则转正并回填本节与 `redirect/gh-proxy/JUDGEMENT.md`；
失败 → 撤规则，结论留档（"clone 会话不可服务端重写"实锤），客户端 insteadOf 维持现状。
