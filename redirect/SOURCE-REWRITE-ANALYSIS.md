# 全源 url_rewrite 处理流程分析（索引 × 对象 URL 生成机制 × 重写安全性）

> 分析留档（2026-09-07）。配套：`MIRROR-CACHE-TOPIC.md`、`gh-proxy/JUDGEMENT.md`、`gh-proxy/TEST-WORKFLOW.md`、`gh-proxy/SOLUTION.md`。
> 覆盖 `deploy/chart/templates/configmap.yaml` 的 mirror-rewrite.sh 中**所有**境外源，
> 逐源拆解：客户端如何发现对象 → 索引里对象链接的形态 → 镜像是否改写索引到自身（同源保障）
> → 重写规则该长什么样 → 索引泄漏时对象去哪（兜底安全吗）。
> 所有关键 URL 均经 2026-09-07 实测（curl 原始响应见文末"实测证据"）。
> **同日追加（gy-001 / 37 节点连通性实测）**：download.pytorch.org 可达且 squid 默认已缓存，
> 该源结论由"重写 SJTU"改为**不重写**（详见正文 + 文末"实测证据"新增段）。
>
> **2026-09-08 追加（GitHub 重写策略专题，取代正文类型三的 gh-proxy 视角）**：
> ① gh-proxy 白名单边界逐测（放行 github.com 主域 + raw 子域，拒绝 codeload/objects/release-assets）；
> ② **releases/download 签名 URL 不可缓存**（30s 轮换 → L82 长缓存规则命中的是 302 本身，无效）；
> ③ github 下载三形态分流策略（修订⑥：https 重写结构性不可用 → **客户端 insteadOf → gh-proxy
> 直连 + squid 本地缓存**；archive 走客户端直链 codeload）；
> ④ gy-001 生产流量统计（4.5 天：archive 179 / releases 18 / git clone 214 CONNECT）。
> 详见文末「GitHub 重写策略专题（2026-09-08）」，与上文旧"类型三"对照阅读。

---

## 统一分析框架（每个源都走这 5 步）

1. **发现机制** — 客户端怎么知道对象在哪（索引 URL 在哪）
2. **对象链接形态** — 索引 HTML 里的链接是相对 / 绝对同站 / 绝对跨站
3. **同源保障** — 镜像是否把索引链接改写到自身（真镜像）还是原样同步（纯同步/反代）
4. **重写规则形态** — host 交换 1:1？需要路径手术？只重写索引？
5. **泄漏兜底** — 索引没被重写时对象去哪，安全吗（还是混源了）

**核心判别量**：对象 URL 的"生成机制"决定重写规则——
索引里对象链接是**相对路径**的，host 交换就够（结构上同源）；
是**绝对 URL** 的，必须靠"真镜像自己改写索引链接"来保证同源，否则就是混源。

---

## 逐源分析总表

| 源 | 索引 URL 形态 | 索引内对象链接 | 镜像 | 重写规则 | 泄漏兜底 | 混源风险 |
|---|---|---|---|---|---|---|
| **pypi.org** | `simple/<pkg>/` | 绝对 URL → `files.pythonhosted.org/packages/...` | tuna（真镜像，改写链接到自身） | 只重写索引：`pypi.org/simple/` → tuna 同路径 | 索引泄漏 → 对象走 files.pythonhosted.org → 不在 ACL → 直连（官方×官方，仍同源） | 若重写 files 域 = 官方索引×镜像文件，**已删除** |
| **download.pytorch.org** | `whl/<variant>/<pkg>/` | **绝对 URL → `download-r2.pytorch.org`（跨 host!）** | SJTU pytorch-wheels（真镜像，改写链接到自身，sha256 逐字节一致） | **不重写**（gy-001 实测可达+默认 bump 已缓存）；仅"官方不可达集群"才启用 SJTU 路径手术备选 | 索引泄漏 → 对象走 download-r2 → 不在 ACL → 直连（官方×官方） | 若重写 download-r2 = 官方索引×SJTU 文件，**不应加** |
| **archive.ubuntu.com** | `ubuntu/dists/<codename>/...` | 全部相对 base | 华为云 `ubuntu/`（真镜像） | host 交换 1:1 | base+相对路径**结构上同源**，无中间态 | 无 |
| **ports.ubuntu.com** | `ubuntu-ports/dists/<codename>/...` | 全部相对 base | 华为云 `ubuntu-ports/` | host 交换 1:1 | 同上 | 无 |
| **repo.openeuler.org** | `openEuler/<ver>/<repo>/...`（repomd.xml 内相对路径） | 全部相对 base | 华为云 `openeuler/` | host 交换 1:1 | 同上 | 无 |
| **github.com** | `releases/download/<tag>/<file>` | 302 → `objects.githubusercontent.com`（签名 CDN） | gh-proxy（服务端抓取） | 路径白名单重写，helper 其余返 ERR（git Smart HTTP 直连） | gh-proxy 挂 → ERR → 直连官方，天然降级 | 无（gh-proxy 服务端吸收 302） |
| **codeload.github.com** | `tar.gz/refs/...` | 无 302，直下 | gh-proxy | 同上 | 同上 | 无 |

---

## 类型一：只重写索引（对象 URL 是绝对链接，同源靠镜像自己改写）

### pypi.org → tuna

**流程**：

```
pip 请求 pypi.org/simple/<pkg>/  ──rewrite──▶ tuna .../pypi/web/simple/<pkg>/
tuna 页面里的链接已被 tuna 改写成自身:
    href="https://mirrors.tuna.tsinghua.edu.cn/pypi/web/packages/<hash>/..."
            ↑ 绝对 URL，同源 → 后续对象请求直接打 tuna，无需我们重写
```

- **同源保障 = 真镜像自己改写索引**，Squid 只负责把"索引发现"引过去。
- **索引泄漏兜底**（官方索引未被重写时）：对象天然回到 `files.pythonhosted.org` —— 官方索引 × 官方文件，**依然是同源**，只是未优化（境外直连）。
- **files.pythonhosted.org 为何删除重写**：若单独重写对象域 → 官方索引 × 镜像文件混源。pip 索引同步延迟约 5min，镜像可能还没有官方刚发布的文件 → 404；且 hash 锁定场景对缺失直接失败。**混源 = 高危险**，所以只保留"索引→镜像，对象同源跟随"。
- **重写规则**（helper）：
  ```
  https://pypi.org/simple/*)  →  mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/${url#*pypi.org/simple/}
  ```

### download.pytorch.org → 不重写（gy-001 实测可达+可缓存）；SJTU 仅作不可达集群的备选

**实测关键发现**：官方索引页里的对象链接是**绝对 URL 且跨 host**：

```
GET https://download.pytorch.org/whl/cpu/torch/      ← pip 用 --extra-index-url 拼的索引
页面内对象链接:
href="https://download-r2.pytorch.org/whl/cpu/torch-2.6.0%2Bcpu-cp39-cp39-linux_x86_64.whl#sha256=..."
        ↑ 对象 host（download-r2.pytorch.org，R2 CDN）与索引 host 不同！
```

**gy-001（37 节点）连通性实测（2026-09-07，exec 进 squid-cache-0 即 37 本机）**：

| 目标 | 经代理（squid 3129） | 缓存（access.log） | 直连对照 |
|---|---|---|---|
| `download.pytorch.org/whl/` | 200 8.6KB（0.66s→0.44s） | — | 200 但抖动 0.7~30s |
| `download.pytorch.org/whl/cpu/torch/` 索引 | 200 395KB（1.7s→1.0s） | **TCP_MISS → TCP_MEM_HIT(1ms)** | 200 但 3~30s 超时出现 |
| `download-r2.pytorch.org/whl/cpu/torch-2.6.0%2Bcpu-...whl` | 200 178MB | **MISS → MEM_HIT(0ms)**，回源 HIER_DIRECT/104.18.8.52 | — |

**结论：不重写 download.pytorch.org**。重写的价值是解决"不可达/太慢"，不是缓存——
本集群官方源可达、且默认 `ssl_bump bump all` 已把它缓存（bump 前提成立）。重写反而有害：
1. **缓存键变化** → 官方域已有缓存全作废（S6 教训），需重新预热
2. **新增依赖 SJTU 同步新鲜度** → 新版本 404 / hash 漂移（S3/S4 场景）
3. **官方索引本身就带 `+cpu` 变体**（`/whl/cpu/torch/` 实测列出 `torch-2.6.0+cpu`）；当初想切 SJTU
   的前提是"华为云没有索引页"——但官方源自己有，兜这一圈毫无必要

> 若某集群连不通官方（如 gy-006 连 docker.io 504 同类），才启用下方 SJTU 路径手术备选。

**SJTU 结构**（与官方同为 PEP 503 包目录式）：
- 索引：`https://mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/<pkg>/`（顶层即包名目录：torch/、torchvision/、vllm/...）
- 对象：`/pytorch-wheels/<variant>/<pkg>-<ver>%2B<variant>-*.whl`（cpu/、cuXX/ 变体子目录）

**若启用，重写规则 = 路径手术，不是 host 交换**：

| 请求 | 官方 URL | SJTU URL |
|---|---|---|
| 索引 | `download.pytorch.org/whl/cpu/torch/` | `mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/torch/` |
| 对象（由 SJTU 索引页提供） | —（无需重写，已同源） | `mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/cpu/torch-...%2Bcpu...whl` |

```
https://download.pytorch.org/whl/*)  →  mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/${去掉 /whl/<variant>/ 前缀后的包名路径}
```
即：`/whl/<variant>/<pkg>/` → `/pytorch-wheels/<pkg>/`（剥掉变体层）。
**索引一旦上了 SJTU，后续对象全在 SJTU**（SJTU 自己改写链接），一条规则覆盖整条链，无需为对象域单独配规则。

**华为云 pytorch/whl 不可用（实测）**：只同步了 whl 文件、**没有索引页**（访问返回落地/提示页），pip 无法从中发现 `+cpu` 变体 → 不能作为重写目标。

**download-r2.pytorch.org**：索引泄漏时的对象兜底域。
- 不在 ACL → 重写规则不碰它 → 直连官方（安全，官方索引×官方文件仍同源，只是慢）。
- **不要**把它加进 ACL 重写（= 官方索引 × SJTU 文件，与 files.pythonhosted.org 同理的混源风险：同步窗口内 404）。
- 即使不重写，download-r2 也在默认 bump 范围内 → 泄漏流量照样被 squid 缓存（实测 178MB wheel MEM_HIT）。

**变体发现语义**：pip 的 `--extra-index-url https://download.pytorch.org/whl/cpu/` 是 PEP 503 索引 base，pip 会固定请求 `{base}/<pkg>/`。若启用重写，目标是确定性的（同一变体 base 恒定），不破坏缓存键确定性（S6 教训）。

---

## 类型二：相对路径源（host 交换即可，结构上无混源可能）

apt / ports / openEuler 的索引和对象 URL **都由客户端从 base 拼相对路径生成**：

```
sources.list: deb http://archive.ubuntu.com/ubuntu jammy main
  ├─ http://archive.ubuntu.com/ubuntu/dists/jammy/InRelease      ← 索引（含 SHA256SUMS）
  └─ http://archive.ubuntu.com/ubuntu/pool/main/.../x.deb        ← 对象
```

- **对象链接形态**：索引（Packages.gz / repomd.xml）内的路径均为相对 base 的相对路径；客户端把所有请求都拼在**同一个 base** 上。
- **重写 = 纯 host 交换**（路径 1:1 保持），客户端从同一 base 生成所有 URL ⇒ "要么全走官方、要么全走镜像"，**结构上不存在中间态**，无混源可能。
- **安全校验**：apt 校验 InRelease 签名 + Release 的 SHA256SUMS、yum 校验 repomd.xml 签名；镜像字节一致则通过。华为云是真同步；若镜像重打包/重压缩，校验直接失败（S4 场景——失败即证明该缺点存在，也即安全兜底）。

### archive.ubuntu.com / ports.ubuntu.com → 华为云

```
archive.ubuntu.com/ubuntu/...        → repo.huaweicloud.com/ubuntu/...
ports.ubuntu.com/ubuntu-ports/...    → repo.huaweicloud.com/ubuntu-ports/...
```

### repo.openeuler.org → 华为云

```
repo.openeuler.org/openEuler/...     → repo.huaweicloud.com/openeuler/...
```

这是"删掉 Dockerfile 里 yum sed 后 Squid 兜底"成立的前提——yum baseurl 内的 dists/repodata/Packages 全部相对，host 交换即全链路生效。

---

## 类型三：git/archive 域（路径白名单 + ERR 兜底）

### github.com / codeload.github.com → gh-proxy

- **releases/download/<tag>/<file>**：官方返回 302 → `objects.githubusercontent.com`（签名 CDN）。**gh-proxy 是服务端抓取**：它替客户端跟随 302 并回传内容 ⇒ 302 后跳被吸收，大文件实际不回境外（解决"302 后跳绕过"缺点 3）。
- **codeload tar.gz/zip**：无 302 直接下载，gh-proxy 纯转发。
- **github.com/<repo>/archive/...**：官方 302 → codeload，同样被 gh-proxy 吸收。
- **git Smart HTTP**（`/info/refs`、POST `/git-upload-pack`）：helper 路径白名单不匹配 → 返回 `ERR` → **原样直连官方**，协议保真、POST 不缓存结论不变。
- **git clone with LFS**（模型/数据集仓库常见，如 onnx/models、ascend-docker-image、DrivingSDK GR00T）：在 clone 之外叠加两类新流量，都**天然不可缓存**：
  - LFS 对象发现：POST `github.com/<repo>/info/lfs/objects/batch`（batch API）→ helper ERR → 直连；POST 不可缓存。
  - LFS 对象下载：GET `github-cloud.githubusercontent.com/...?token=<签名>` → 该域后缀是 `.githubusercontent.com`，**不在 ACL `dstdomain .github.com` 里** → url_rewrite 根本不碰它 → 直连官方 CDN；且 URL 带一次性签名，每次 batch 返回的 URL 都不同 → 缓存键必然分裂，**LFS 对象即使想缓存也永远 MISS**。
- **ACL 说明**：`acl rewritable dstdomain .github.com` 会匹配 `api.github.com` 等子域，但这些请求进 helper 后不匹配路径白名单 → ERR 直连，只是多一跳 helper 开销，无行为变化。
- **兜底**：gh-proxy 不可达时，helper 对未匹配路径一律 ERR → 客户端直连官方，天然降级（helper 不是单点故障）。

### github 场景实测矩阵（gy-001，2026-09-07，vcjob 02/03/04）

测试脚本：`redirect/test/02-github-archive-git-vcjob.yaml`（wget）、`03-git-lfs-vcjob.yaml`（LFS）、`04-git-insteadof-vcjob.yaml`（insteadOf）。

GitHub 有 **3 个子场景**：git clone（Smart HTTP）、git clone with LFS、wget 静态文件（archive/codeload）。每个子场景各自跑同一组 **2×2 矩阵（客户端换源 × 代理）**：
- A 无换源 × 直连 / B 无换源 × squid / C insteadOf→gh-proxy × 直连 / D insteadOf→gh-proxy × squid

**场景 1：git clone（Smart HTTP）—— 2×2 换源 × 代理**

| case | 客户端换源 | 代理 | 结果 | 结论 |
|---|---|---|---|---|
| A | 无（官方 URL）| 直连 | **FAIL**：github.com:443 超时 ~160s / `Empty reply from server` ~90s（多次复现）| 境外不通，不可用 |
| B | 无（官方 URL）| squid | **OK 1.9s**：helper ERR → 直连官方；access.log 仅 `CONNECT` 隧道 + `TCP_MISS` GET/POST | 可用但 **0% 缓存**（POST 协议级不可缓存）；直连仍依赖境外可达性 |
| C | insteadOf → gh-proxy | 直连 | **OK 4.6s / 1.8s**（×2 均成功，直连版由 `.gen-direct.py` 生成、剥离代理注入）：gh-proxy 内网可达，无 squid 缓存 | 可用；无 squid 参与，二次 clone 仍 1.8s（无 /info/refs 缓存可复用） |
| D | insteadOf → gh-proxy | squid | **OK 4.2s / 2.2s**（×2 均成功）：`git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"` 生效，全流量走 gh-proxy URL（`CONNECT gh-proxy.test.osinfra.cn` + GET `/info/refs` + POST `/git-upload-pack` 均 TCP_MISS，`/info/refs` 二次为 `TCP_REFRESH_MODIFIED`）| **推荐**：链路稳定（内网抓取、境外抖动被吸收），仍 0% 缓存但 git 本体本就是动态协议 |

- **关键洞察**：git 流量换源与否，**缓存收益都是 0**（POST /git-upload-pack 协议级不可缓存）。换源（insteadOf→gh-proxy）解决的**不是缓存而是可用性**——官方直连境外抖动（A 已证 FAIL），gh-proxy 服务端抓取把境外抖动吸收在内网（D 已证稳定）。
- 顺带观测：现网 spdlog/googletest 等任务已在用 insteadOf→gh-proxy 模式，其 GET `/info/refs` 出现 `TCP_REFRESH_MODIFIED`（304 校验，收益仅几百字节）。

**场景 2：git clone with LFS（onnx/models，2564 个对象 / 总量 721GB）—— 2×2 换源 × 代理**

| case | 客户端换源 | 代理 | clone | lfs pull（95MB 大对象） | access.log |
|---|---|---|---|---|---|
| A | 无（官方 URL）| 直连 | **OK 3.5s**（03 对照，`sh -n` 修复后重跑）| rc=0 **53ms**，文件仍 133B 指针 → **对象未实际下载** | —（无 squid 参与）|
| B | 无（官方 URL）| squid | **OK 4.4s**（CONNECT + TCP_MISS GET/POST，直连官方）| rc=0 **101ms**，文件仍 133B 指针 → **对象未实际下载** | **`info/lfs`、`github-cloud` 零记录 → git-lfs 请求未走 squid** |
| C | insteadOf → gh-proxy | 直连 | **OK 7.1s**（04E 对照）| rc=0 96ms（小对象），大对象未测 | —（无 squid 参与）|
| D | insteadOf → gh-proxy | squid | **OK 6.9s**（全流量 gh-proxy URL）| rc=0 85ms（小对象），大对象未测 | **零记录**；`git remote -v` 显示 gh-proxy URL，`git config --get remote.origin.url` 显示原始 github URL |
| （定论实验 03b：`GIT_TRACE`+`GIT_TRANSFER_TRACE`）| — | — | **FAIL**：`CONNECT github.com:443 NONE_NONE_TIMEDOUT` → `NONE_NONE/503 GET info/refs`（GitHub 对 onnx/models 限流，非 squid 问题）| — | — |

- **定论（2026-09-07 大对象实验）**：LFS 大对象（95MB）在 squid 版和直连版中 **pull 均未实际下载**（耗时 53–101ms、工作区文件保持 133B 指针）→ **不是 squid 的问题，是 git-lfs 客户端行为**（batch 请求未生效/被静默失败，或 `--include` 未匹配）。且 squid access.log 中 `info/lfs`、`github-cloud` **始终零记录**（包括 insteadOf 后 batch 端点应为 gh-proxy URL 的场景）→ **git-lfs 的 go HTTP 客户端在当前注入方式下完全绕开 squid**（`HTTP_PROXY` env + `git config http.proxy` 均设但未生效）。
- **结论**：LFS 对象流量不在 squid 管控内（客户端绕代理），insteadOf→gh-proxy 也只覆盖 git 本体（clone/upload-pack），**LFS 对象仍直连境外 CDN**；即便想缓存，签名 URL 每次不同 → 缓存键必然分裂 → **LFS 对象天然不可缓存**。batch API 是否被 insteadOf 带进 gh-proxy 待 GitHub 限流窗口过后用 GIT_TRACE 实测确认。

**场景 3：wget 静态文件（archive 302 + codeload 直下）—— 2×2 换源 × 代理**

> 注意：wget **没有** git 的 insteadOf 机制，"客户端换源"= 手动把 URL 改成 gh-proxy 前缀
> （`https://gh-proxy.test.osinfra.cn/https://github.com/...`），与 insteadOf 等价。

| case | 客户端换源 | 代理 | `github.com/.../archive/...zip` | `codeload.github.com/.../zip/refs/tags/...` | access.log |
|---|---|---|---|---|---|
| A | 无 | 直连 | pybind11 **35s / 33s / 65s**；obs 139MB **8.9s / 39.9s / 105s**（境外抖动极重）| ~1.5s / 1.4s / 2.3s | — |
| B | 无 | squid | 1.1s / 0.7s / 0.8s；obs 2.0s / 1.5s / 1.6s | 0.4s 恒定 | 302 **`TCP_MISS/302`**（不可缓存）→ 跟随到 codeload 后 **`TCP_HIT/200`**（长缓存 10080 100% 525600 生效，850KB 秒回 / 139MB 命中）|
| C | 手动 URL → gh-proxy | 直连 | **200** pybind11 2.3s / 0.99s / 0.95s；obs **19.5s / 18.7s / 12.1s**（gh-proxy 服务端缓存生效，次发 0.95s）| **403** ×3（gh-proxy 白名单只放行 github.com，拒绝 codeload 路径）| — |
| D | 手动 URL → gh-proxy | squid | **200** pybind11 1.2s / 2.1s / 0.7s；obs **8.1s / 8.1s / 2.4s** | **403** ×3（同 C）| archive：`TCP_MISS/200` → **`TCP_REFRESH_UNMODIFIED/200`**（本地副本 + 304 校验，默认 refresh_pattern 生效）；obs：MISS 7.9s → UNMODIFIED 2.2s |

- **结论**：
  1. **换源（gh-proxy）在 wget 场景可行**（C/D 均 200），直接解决 A 的境外抖动（35–105s → ≤19s）；gh-proxy 有服务端缓存，直连版次发即快（0.95s）。
  2. **codeload 路径 gh-proxy 一律 403**（白名单只放行 `github.com` 域）→ 换源只覆盖 `github.com/archive/`，**codeload 直链无法换源**，只能靠官方直连（A/B）。
  3. D 同样有 squid 缓存收益（`TCP_REFRESH_UNMODIFIED` = 本地有副本、每次 304 校验），但**没有 codeload 长缓存规则**（gh-proxy URL 的 host 是 `gh-proxy.test.osinfra.cn`，不匹配 `codeload.github.com/.*/refs/tags/`），故是"过期后 304 校验"而非直接 `TCP_HIT`。
  4. **推荐仍是 B（官方+squid）**：codeload `TCP_HIT` 秒回、无换源依赖、缓存键不变。换源（C/D）仅在官方直连完全不可达（A）时作兜底——github archive 可换 gh-proxy，codeload 兜底不了。

**并发专项（10 job，2026-09-07，B 场景 10 并发）**：

| 请求目标 | B（无换源 + squid）10 并发 × 3 = 30 次 | access.log 证据 |
|---|---|---|
| `github.com/pybind/pybind11/archive/refs/tags/...zip` | **5/30 成功**（16.7%），其余 503 | **33 次 `CONNECT github.com:443` 全部 `NONE_NONE_TIMEDOUT/200`**（每次 ~5s 隧道超时，`HIER_DIRECT/20.205.243.166`），wget 收到 503 |
| `github.com/huaweicloud-sdk-c-obs/archive/...zip` | **0/30 成功**（0%），全 503 | 同上：CONNECT 隧道全部 TIMEDOUT |
| `codeload.github.com/pybind/pybind11/zip/refs/tags/...` | **30/30 成功**，~400ms 恒定 | **`TCP_HIT/200` ×39 + `TCP_REFRESH_UNMODIFIED/200` ×17**；窗口内样本全部 `TCP_HIT/200`，耗时 **3–4ms**、`HIER_NONE/-`（纯本地缓存，零回源）|

**并发专项（10 job，2026-09-07，A 场景 10 并发，直连官方无 squid）**：

| 请求目标 | A（无换源 + 直连）10 并发 × 3 = 30 次 | 说明 |
|---|---|---|
| `github.com/pybind/pybind11/archive/refs/tags/...zip` | **30/30 成功**，1.7s ~ **111s**（长尾严重）| 直连多出口 IP → **未触发限流**，但速度灾难 |
| `codeload.github.com/pybind/pybind11/zip/refs/tags/...` | **30/30 成功**，1.2s ~ 19s | 无缓存，每发都打境外 |
| `github.com/huaweicloud-sdk-c-obs/archive/...zip`（139MB）| **29/30 成功 + 1 失败**，8.5s ~ 148.5s；最差 1 次 **597s 后 rc=4 失败**（A-08 pass2，单操作超时上限）| 直连 139MB 并发灾难 |

**并发专项（10 job，2026-09-07，C 场景 10 并发，URL 手动改 gh-proxy + 直连无 squid）**：

| 请求目标 | C（gh-proxy 直连）10 并发 × 3 = 30 次 | 说明 |
|---|---|---|
| `gh-proxy/.../github.com/pybind/pybind11/archive/...zip` | **30/30 成功**，1.0s ~ 8.3s（首发略慢，次发 ≤3s）| 完全规避 B 的 503 限流；gh-proxy 服务端缓存生效 |
| `gh-proxy/.../codeload.github.com/...` | 403 ×30 | 白名单只放行 `github.com`，已知 |
| `gh-proxy/.../github.com/huaweicloud-sdk-c-obs/archive/...zip`（139MB）| **29/30 成功**，**8.6s ~ 266.8s**（C-08 pass1=266.8s、C-10 pass1=185.8s、C-07 pass2=205s）| 10 并发时 gh-proxy 上游同时抓多个 139MB 被限速 |

- **C 并发定论**：① 小文件（850KB）gh-proxy 直连并发完美（30/30、≤3s）——**换源解决 B 的 github archive 503 限流**；② **大文件（139MB）gh-proxy 直连并发灾难**（8–267s）——直连版没有本地缓存，10 并发打 gh-proxy 时其上游出站带宽被瓜分；③ 对比 **D（gh-proxy + squid）并发 8/8 全 200（obs ≤4.2s）**——squid 把 gh-proxy 抓回的 139MB 落本地磁盘，后续并发全从本地出，绕开 gh-proxy 上游带宽瓶颈。
- **四场景并发总排名（github archive / obs 139MB 路径）**：**D（gh-proxy+squid）≻ B（官方+squid，obs 503 失败）≈ C（gh-proxy 直连，obs 8-267s 慢）≻ A（官方直连，obs 597s 失败）**。唯一全场景稳定的是 D。

**并发专项（10 job，2026-09-07，D 场景 10 并发，URL 改 gh-proxy + squid，缓存已热）**：

| 请求目标 | D（gh-proxy + squid）10 并发 × 3 = 30 次 | access.log 证据 |
|---|---|---|
| `gh-proxy/.../github.com/pybind/pybind11/archive/...zip` | **30/30 成功**，1.0s ~ 2.7s | `TCP_REFRESH_UNMODIFIED`（本地副本 + 304 校验）|
| `gh-proxy/.../codeload.github.com/...` | 403 ×30 | 白名单只放行 `github.com`，已知 |
| `gh-proxy/.../github.com/huaweicloud-sdk-c-obs/archive/...zip`（139MB）| **30/30 成功**，**1.1s ~ 4.4s** | `TCP_REFRESH_UNMODIFIED` ×38 + 首波 `TCP_MISS` ×13（gh-proxy 抓回后落本地磁盘）|

- **D 并发定论**：**四场景中唯一全 URL、全并发稳定的路径**。obs 139MB 并发 **1.1–4.4s**（vs C 直连 8–267s、B 503 失败、A 597s 失败）——squid 把 gh-proxy 抓回的归档落本地磁盘，之后所有并发请求走本地副本 + 304 校验（`TCP_REFRESH_UNMODIFIED`），完全绕开 GitHub 限流和 gh-proxy 上游带宽瓶颈。pybind11 小文件 30/30 ≤2.7s。
- **并发结论（A/B/C/D 汇总）**：① GitHub archive（大/小文件）并发可用性 = **D ≻ C ≻ A ≻ B**（B 单 IP 撞限流最差）；② codeload 只能走官方（gh-proxy 白名单 403），**squid 长缓存并发 30/30、3–4ms**；③ 生产形态 = `insteadOf → gh-proxy`（换源防限流）+ squid（本地缓存扛并发大文件）+ codeload 长缓存规则。

- **为什么 github 失败（B）——access.log 铁证**：B 并发窗口 33 次 `CONNECT github.com:443` **全部 `NONE_NONE_TIMEDOUT/200`**（squid 与 GitHub 建隧道每次超时 ~5s，`HIER_DIRECT/20.205.243.166`）。根因：**squid 是 StatefulSet 单出口 IP**，10 并发 × 3 = 30 次全从同一 IP 打 `github.com:443`，GitHub 对该 IP 并发隧道拒绝/限流 → 隧道建不起来 → wget 收到 503。archive 302 端点本就是 GitHub 重点限流目标（单跑也偶发 503，见文件头注释）。**直连 A 为何不触发**：10 个 pod 分布在多节点、多出口 IP，压力被分散 → 无单点限流，代价是每发都走境外（111s/148s/597s 长尾）。
- **`connect_timeout 5s` 的直接作用（本机复现定论，2026-09-07）**：GitHub 对单 IP 并发 archive 的限流形态是 **TCP 连接挂起排队**（非 RST 拒绝）——本机 30 并发实测 `time_connect`：26/30 正常 0.13s、**3/30 被挂 19.5s 后才 accept**。squid `connect_timeout 5 seconds`（deploy/chart/templates/configmap.yaml L112）把"5s 内没 accept"的连接全部判死 → B 场景 access.log 的 duration 4.8–5.8s 恰好等于该阈值。精确复现：本机 `--connect-timeout 5` 打 30 并发 = **27×302 + 3×000**（挂起>5s 被放弃），与 B 场景 0–16.7% 失败同机制；`--connect-timeout 30` 对照 = 30/30 全 302（延迟放行）。**但调大超时不是解药**：configmap 注释记录"原 2 分钟判死过慢导致 proxy 路径系统性劣于直连"（domaintest/REPORT-connect-timeout-ab.md），放宽超时会把坏 IP 判死变慢、劣化所有 proxy 流量，且 squid 云 IP 挂起率更高（obs 0/30）放宽也只是"等很久后成功"。**唯一稳妥解是换源 gh-proxy（D）：请求不打 GitHub，无挂起无超时。**
- **为什么 codeload 完美（B）——access.log 铁证**：窗口内 GET codeload 全部 `TCP_HIT/200`，耗时 **3–4ms**、`HIER_NONE/-`——完全命中 squid 磁盘缓存，**squid 根本没建立到 codeload 的连接**，自然不受境外/限流影响。长缓存 `refresh_pattern codeload.github.com/.*/refs/tags/`（10080 100% 525600）在并发下零击穿、无 stampede（无 TH_ 部分命中，因为单个 squid 实例串行化 fetch 且已有缓存）。
- **对 CI 的含义**：凡是走 `github.com/.../archive/` 的下载（如 pip sdist 间接 302、GitHub 源码归档），并发场景必须换源 gh-proxy（D 并发 8/8 全 200，0.8–4.2s，内网抓取不受 GitHub 限流）；直接打 `codeload.github.com` 的归档靠 squid 长缓存即可（并发 30/30、3–4ms）。

---

## 结论与对 helper 的影响

1. **pytorch 规则：删掉重写**（gy-001 实测官方可达且默认 bump 已缓存，重写只会作废缓存键 + 新增镜像依赖）。SJTU 路径手术仅保留为"官方不可达集群"的备选方案。
2. **download-r2.pytorch.org 不加入 ACL**（混源，与 files 域同决策）。
3. apt/ports/openEuler 三条规则现状正确（host 交换）。
4. pypi/github 现状正确（只重索引 / 路径白名单 + ERR 兜底）。

**一句话**：对象 URL 是相对路径的源，host 交换安全；对象 URL 是绝对链接的源，只能重写索引、靠真镜像改写链接保同源，对象域绝不单独重写。**且重写的前提是"官方不可达/太慢"——官方可达又能缓存时，不重写才是最优解。**

---

## 实测证据（2026-09-07）

### 官方 pytorch 索引页（对象链接 = 绝对 URL，跨 host 到 download-r2）

```html
# GET https://download.pytorch.org/whl/cpu/torch/
<a href="https://download-r2.pytorch.org/whl/cpu/torch-2.10.0%2Bcpu-cp310-cp310-linux_x86_64.whl#sha256=a280ffaea7b9c828e0c1b9b3bd502d9b6a649dc9416997b69b84544bd469f215">
```

### SJTU 同文件（链接改写为自身，sha256 一致 → 字节一致的真镜像）

```html
# GET https://mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/torch/
<a href="/pytorch-wheels/cpu/torch-2.10.0%2Bcpu-cp310-cp310-linux_x86_64.whl#sha256=a280ffaea7b9c828e0c1b9b3bd502d9b6a649dc9416997b69b84544bd469f215">
```

### SJTU 顶层 = PEP 503 包目录（torch/、torchvision/、vllm/、xformers/...）

```
# GET https://mirrors.sjtug.sjtu.edu.cn/pytorch-wheels/
[torch/]  [torchvision/]  [vllm/]  [xformers/]  [nvidia-cudnn-cu12/] ...
```

### 华为云 pytorch/whl 无索引页（不可作重写目标）

```
# GET https://repo.huaweicloud.com/pytorch/whl/  → 仅返回落地/提示页，无 PEP 503 索引结构
```

### gy-001 / 37 节点连通性实测（2026-09-07，exec 进 squid-cache-0 即 37 本机）

```
# 端口坑：同 Pod 内 3128 是 registry-proxy（隧道透传，看不到内容）；
#         squid 本体 ssl-bump 在 3129；Service squid-cache:3128 → targetPort 3129(squid)。
#         代理路径响应头出现 "Via: ... 1.1 squid-cache (squid/7.7.1)" = bump 生效。

node=squid-cache-0   proxy=http://127.0.0.1:3129

[经代理] GET /whl/                     → HTTP 200 text/html 8643B   (0.66s → 0.44s)
[经代理] GET /whl/cpu/torch/           → HTTP 200 text/html 395221B (1.7s → 1.0s)
[经代理] HEAD download-r2 .../torch-2.6.0%2Bcpu-cp39-...whl → HTTP 200 binary/octet-stream 178631197B

# access.log 缓存判定（MISS → MEM_HIT，秒级→毫秒级）
1788749065  TCP_MISS/200   395899 GET https://download.pytorch.org/whl/cpu/torch/   HIER_DIRECT/65.8.76.30
1788749067  TCP_MEM_HIT/200 395900 GET https://download.pytorch.org/whl/cpu/torch/   HIER_NONE/-      (1ms)
1788749072  TCP_MISS/200      728 HEAD https://download-r2.pytorch.org/whl/cpu/torch-2.6.0%2Bcpu-cp39-cp39-linux_x86_64.whl  HIER_DIRECT/104.18.8.52
1788749072  TCP_MEM_HIT/200    416 HEAD https://download-r2.pytorch.org/whl/cpu/torch-2.6.0%2Bcpu-cp39-cp39-linux_x86_64.whl  HIER_NONE/-       (0ms)

# 直连对照：可达但抖动大（0.7~28s，/whl/cpu/torch/ 曾 30s 超时）；经代理稳定 ~1s 且带缓存

结论：官方索引 + 对象在 gy-001 均可达、且默认 bump 已被 squid 缓存 → download.pytorch.org 不重写。
```

---

## GitHub 重写策略专题（2026-09-08）

> 本节取代上文「类型三」的旧 gh-proxy 视角，基于 gh-proxy P1-P6 实证 + gy-001 生产流量统计。
> 完整证据链见 `gh-proxy/JUDGEMENT.md`、`gh-proxy/TEST-WORKFLOW.md`；落地方案见 `gh-proxy/SOLUTION.md`。

### 1. gh-proxy 白名单边界（实测，修正"只放行 github.com"）

gh-proxy 前缀 + 各 GitHub 子域逐测（squid-cache-0，2026-09-08）：

| gh-proxy 前缀 + 目标 | 实测 | 结论 |
|---|---|---|
| `github.com/.../archive/*.zip` | 200 | 放行（服务端抓取+缓存）|
| `github.com/.../releases/download/...` | 200 | 放行（签名 URL 链由 gh-proxy 服务端消化）|
| `raw.githubusercontent.com/...` | 200（0.4s）| **放行**——bazel `--registry` 可经 gh-proxy 拉 BCR 元数据 |
| `codeload.github.com/...` | 403（×30）| 拒绝（存储域）|
| `objects.githubusercontent.com/...` | 403 | 拒绝（Release 资产存储域）|
| `release-assets.githubusercontent.com/...` | 403 | 拒绝（Release 资产存储域）|
| 裸 `github.com/` | 403 | 拒绝（无有效路径）|

**规律**：gh-proxy 白名单 = "应用层 github.com 主域 + 静态层 raw 子域"；**拒绝存储层
（`*.githubusercontent.com` 的签名 URL 域）**。因为存储层用 Azure Blob 签名 URL（SAS，30s 轮换），
gh-proxy 服务端缓存键每次不同存不住——所以故意不做存储层反代。

**推论**：客户端拼 gh-proxy 前缀后，**302 链由 gh-proxy 服务端消化**，客户端拿到的永远是
`gh-proxy/.../github.com/...` 确定性 URL → **squid 只解析 gh-proxy 一个域名，其余子域全不用管**。

### 2. GitHub 下载三形态（决定重写策略的分流依据）

| 形态 | 示例 | 官方行为 | 可缓存性 | 正确路径 |
|---|---|---|---|---|
| **archive**（源码快照）| `github.com/<o>/<r>/archive/refs/tags/<tag>.zip` | 302 → codeload | 302 不可缓存；**目标 codeload 无签名、永久 URL → 可长缓存** | helper 1:1 → codeload |
| **releases/download**（发布资产）| `github.com/<o>/<r>/releases/download/<tag>/<file>` | 302 → `release-assets...?sig=...` | **签名 URL 30s 轮换 → 缓存键永远不同 → 永远不可缓存** | gh-proxy 前缀（服务端消化 302）|
| **raw**（BCR 元数据等）| `raw.githubusercontent.com/<o>/<r>/<branch>/<path>` | 直下，无 302 | 确定性 URL → 可缓存 | 客户端拼 gh-proxy 前缀（白名单放行）|

**关键新发现（实测揭穿旧结论）**：`releases/download` 官方直连 = 每次 302 到**签名 URL**，
`se/skt/sig` 时间戳每 30s 轮换 → 每次重新回源 → **内容永远长缓存不了**。
configmap L82 的 `refresh_pattern github\.com/.*/releases/download/` 命中的是 **302 本身**——死规则。
08-bazel.yaml 里所有 http_archive 拼 gh-proxy 前缀**不是巧合**：gh-proxy 服务端跟随后返回确定性 URL，
squid 才能缓存。实测：gh-proxy 前缀 200 38KB 0.59s vs 官方直连 302 + 跟随 1.08s。

### 3. 重写策略（修订⑥：https 重写废弃 → 客户端 insteadOf）

> **修订⑥（推翻上文"两段式 helper + pin DNS"）**：实测证明 **ssl-bump 下 https 重写结构性
> 不可用**——CONNECT 阶段按原域名建连（github.com→.166 为**正常解析**），bump 后 helper 重写
> URL，但 squid **复用已建连接不按新 host 重建** → 请求发往错误 IP → 301 翻倍/421 死循环；
> **pin DNS 无效**（JUDGEMENT 3.3）。**两段式 helper 的 https 重写形态（archive→codeload、
> github→gh-proxy）全部废弃**。

正确姿势（客户端侧，不依赖 helper）：

```sh
# git：insteadOf 全局换源（02 用例 task3 / P6 全链路验证通过）
git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"
# archive：客户端直接写 codeload 确定性 URL（无 302、命中 refresh_pattern 长缓存）
https://codeload.github.com/<owner>/<repo>/zip/refs/<type>/<name>
# releases：客户端拼 gh-proxy 前缀（签名 URL 不可缓存，由 gh-proxy 服务端消化 302）
https://gh-proxy.test.osinfra.cn/https://github.com/<owner>/<repo>/releases/download/...
```

helper 仅保留 **http 明文重写**（archive.ubuntu.com / ports.ubuntu.com / repo.openeuler.org 的
http 形态，实测 200——无 CONNECT，重写发生在建连前）。

### 4. gy-001 生产流量统计（4.5 天窗口，Sep 3 16:57 → Sep 8 06:09 UTC）

squid-cache-0，github.com 相关形态分布：

| 形态 | 次数 | 占比 | 备注 |
|---|---|---|---|
| `archive`（GET）| **179** | ~59% | 最高频 GET 形态 |
| git clone（CONNECT + info/refs + upload-pack）| 214 + 41 + 82 | ~31% | CONNECT 211/214 到 `.166`，78 次 NONE_NONE/200（限流 IP）|
| `releases`（GET）| 18 | ~6% | 低频 |
| codeload 直连 | 276 | — | 大量为 302 跟随后 |
| raw.githubusercontent | 0 | — | bazel `--registry` 是客户端拼前缀，不产生 raw 直连 |
| gh-proxy 前缀 | 406 | — | 内 archive 83、upload-pack 82、info 41、codeload 38 |

**结论**：① archive = 最高频（179 vs 18，10:1）→ "archive 走最优路径"有生产数据支撑；
② git clone 是第二大头（~31%），生产已大量走 gh-proxy insteadOf（upload-pack 82 + info 41）；
③ releases 低频且官方直连不可缓存 → 交给 gh-proxy 是唯一解。

### 5. 与旧"类型三"的差异对照

| 项 | 旧（09-07）| 新（09-08）|
|---|---|---|
| gh-proxy 白名单 | "只放行 github.com，codeload 403" | 放行 github.com 主域 + **raw 子域**；拒绝存储域 |
| releases/download | "官方直连 + L82 长缓存" | **L82 无效**（302 目标签名 URL 30s 轮换）；应走 gh-proxy |
| archive | 重写进 gh-proxy | **客户端直链 codeload**（修订⑥：https 重写不可用；确定性 URL、无 302、命中长缓存）|
| git clone | helper ERR 直连官方（B 场景 FAIL）| **客户端 insteadOf → gh-proxy**（修订⑥：https 重写不可用；生产已在用）|
| 301 翻倍 | 多后端假设 | 修订⑥：**ssl-bump 连接复用**（非 DNS）→ https 重写废弃，改用客户端 insteadOf |
