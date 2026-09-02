# 镜像换源 × Squid 缓存：git/wget 差异与换源方案分析

> 讨论留档（2026-09-02）。两个关联话题：
> ① Squid 做 url_rewrite 域名替换时 git clone 与 wget 的行为差异；
> ② CI 场景下"缓存 + 换境外源为国内源"的落地方式与缺点。

---

## 话题一：git clone 与 wget 在 Squid 域名替换下的本质差异

**核心区别：wget 下载的是"静态文件"，git clone 执行的是"动态协议交互"。**

### HTTP 请求差异

- **Wget**：单个 `GET /archive/v1.0.tar.gz`，返回二进制流，一次请求结束。
- **Git Clone (Smart HTTP)**：
  1. `GET /repo.git/info/refs?service=git-upload-pack` —— 协议协商
  2. `POST /repo.git/git-upload-pack` —— 对象传输（POST **永不缓存**）
  请求头携带 `Git-Protocol` 标识，依赖服务端支持智能 HTTP 协议。

### Squid url_rewrite 替换域名时会发生什么

Squid 本身不区分 git/wget，只当普通 HTTP 代理。若把 `github.com` 强制替换为包镜像站（清华/阿里类），镜像后端只分发静态文件（.deb/.rpm/源码压缩包），**不支持 Git Smart HTTP**：

- **Wget**：✅ 只要路径存在就能下载
- **Git Clone**：❌ `Repository not found` / `502` / 返回 HTML 错误页（镜像把 `/info/refs` 当普通路径处理）

### 本仓库的实证结论（重要）

| 事实 | 出处 |
|---|---|
| 本仓库 **没有任何 `url_rewrite` 配置**，Squid 是纯正向代理 + SSL Bump MITM | `configs/squid/squid.conf`（测试 `bump all`，生产域名白名单 splice） |
| git clone 不被缓存的根因是**协议级不可缓存**（POST /git-upload-pack、info/refs 带 no-cache），与是否重写域名无关，**命中率恒 0%** | `deploy/CACHE-STRATEGY.md` §3.4 |
| 客户端侧已用 `insteadOf` 走 gh-proxy + `--depth=1` | `traffic-test/tool/03-github.yaml#L38` |
| `hub.fastgit.xyz` 已停服（网上旧方案失效）；`gh-proxy.test.osinfra.cn` 为内部可用替代 | 实测 |
| "国内镜像不支持 Smart HTTP"以偏概全：gh-proxy 系、gitclone.com 本身就是 git 代理 | — |

### 替代方案对比

| 方案 | 做法 | 评价 |
|---|---|---|
| A（推荐，已落地） | 客户端 `git config url."<镜像>".insteadOf "<官方>"`，不走 Squid 重写 | ✅ 本仓库现行方案 |
| B | Squid 按路径区分：仅对 `urlpath_regex` 静态归档替换，`/info/refs`、`/git-upload-pack` 放行直连 | 可行但复杂，仅兜底用 |
| C | 自建 git 专用代理（gh-proxy / gitcache 类） | 注意：多数只是 URL 前缀代理，并非对象级缓存；CI 里真正的对象级缓存是共享 bare repo |

**一句话**：域名替换只适用于"无状态静态下载"，千万别用在"有状态协议交互（Git/API）"上。

---

## 话题二：CI 场景下缓存 + 换源的正确姿势

### 核心原则：缓存和换源解耦，换源放在客户端层

- **缓存**吃"重复拉取"（CI 同一依赖反复下）
- **换源**吃"首次/未命中时的回源可达性"（gy-006 连 docker.io 504 是典型）

### 实现位置对比

| 层 | 手段 | 优点 | 缺点 |
|---|---|---|---|
| **基镜像** | bake 进 sources.list / pip.conf / .gitconfig | 一次注入全员生效，零漂移 | 换源需重建镜像 |
| **Job 模板 / postStart** | sed 换源 + env 注入 | 灵活、可按 job 覆盖 | 侵入每个模板，易散落漂移 |
| **Squid url_rewrite** | 服务端透明替换 | 客户端零改动、集中管控 | 缺点最多（见下），风险最高 |
| **DNS/前置分流** | 域名劫持到自建反代 | 最透明 | 运维重，本质还是换源 |

**本仓库现状 = 前两层**：apt sed 华为云镜像 + git insteadOf gh-proxy（03-github.yaml）、docker 用 m.daocloud.io 前缀（17-docker-pull.yaml）。**建议继续，并把散落注入收敛成统一配方**（deploy/DEPLOY.md 注入配方或基镜像），Squid 保持中立纯缓存。

### 若必须在 Squid 做：只对静态路径白名单替换

```squid
# 只重写"静态文件扩展名 + 目标域名"交集,其余一律不进 helper
acl static_archives urlpath_regex -i \.(deb|rpm|whl|tar\.gz|tgz|zip|gem|jar)$
acl foreign_src dstdomain .codeload.github.com .github.com
url_rewrite_access allow static_archives foreign_src
url_rewrite_access deny all
url_rewrite_program /usr/local/bin/mirror-rewrite.sh
url_rewrite_children 10 startup=2 idle=1
```

```sh
#!/bin/sh
# 镜像重写 helper(简单串行版):stdin 收 URL,stdout 回结果
while read -r url; do
  case "$url" in
    https://codeload.github.com/*|https://github.com/*/archive/*)
      echo "OK rewrite-url=\"https://gh-proxy.test.osinfra.cn/$url\""
      ;;
    *) echo "ERR" ;;
  esac
done
```

⚠️ 老 `storeurl_rewrite_program`（只改缓存键不改取回源）在 **Squid 4+ 已移除**；现代 Squid 重写就是真的换源。

### 换源的缺点（无论哪层实现）

1. **内容漂移与可复现性**
   - 镜像同步延迟（pip 索引约 5min，deb 可达小时级）→ 新版本 404
   - 镜像会删旧档 → 昨天能装的版本今天 404，构建从"慢"变"挂"
   - hash 锁定（`pip --require-hashes`、`go.sum`、apt Release 签名）对重打包零容忍

2. **协议级不兼容（绝不能替换的流量）**
   - git Smart HTTP（`/info/refs`、`/git-upload-pack`）
   - 带签名 URL（HF resolve、S3 签名，签名与 host 绑定）
   - docker registry v2 token auth（realm 按 host 签发）
   - 一切 POST / API endpoint

3. **302 后跳绕过**：官方源 302 的 `Location` 指向官方 CDN（GitHub release → objects.githubusercontent.com），Squid 原生不改响应头，要改需 ICAP/eCAP——大文件实际仍走境外，替换形同虚设

4. **缓存键 = 缓存清零（CI 特有坑）**：Squid 缓存键是完整 URL，换源后旧缓存条目全作废，命中率瞬间归零需重新预热；URL 混用（部分 job 换部分不换）→ 同一包缓存两份，统计分裂

5. **集中故障点**：镜像挂掉/限流 → 所有 job 回源同时失败（wlcb 跨区 OBS 间歇 503 前车之鉴）；客户端换源可单 job 切回官方救急，Squid 侧 url_rewrite 多一跳排查 + helper 本身是新故障点

6. **与现有架构联动成本**：换源后须同步更新生产 `ssl_bump bump` 域名白名单（ascend_ci_domains.json 同类清单）——否则新镜像域名被 splice 直通，**Squid 直接不缓存它，换源反而丢了缓存**；流量报表域名归因表也要加新域名

### 分场景落地建议

| 场景 | 方案 | 缓存预期 |
|---|---|---|
| 包管理器（apt/yum/pip/npm/conda/cargo/go） | 客户端/基镜像换国内镜像，Squid 缓存镜像站流量（A 类源，长缓存零风险） | 90-100% |
| git clone | insteadOf gh-proxy + `--depth=1`，只吃带宽加速 | 0%（POST 协议限制） |
| docker | 双轨：m.daocloud.io 前缀 + registry-proxy 按 digest 缓存 | blob 级命中 |
| Squid url_rewrite | **只作兜底**：仅对改不了的第三方 CI 脚本按静态路径白名单局部启用，绝不全局开 | — |

**一句话总结**：换源的正确位置是"发起请求的那一端"，Squid 的价值是"不管源在哪都缓存住"。让 Squid 做缓存的事、让客户端做选源的事，别让 Squid 既当裁判又当运动员。

---

## 场景验证清单（Review 本文档用）

以下场景用于逐条验证上文的结论。每个场景标注了它验证的论点、操作步骤与机器可判定标准。
测试集群参考现有 16-tool e2e 套件的写法（Volcano Job + squid CA secret + 代理 env 注入）。

### S1. git clone 经 Squid 命中率恒 0%（验证：POST 协议级不可缓存）

- **验证论点**：话题一"根因是 POST /git-upload-pack 不可缓存，与是否换源无关"
- **步骤**：复用 `traffic-test/tool/03-github.yaml`（insteadOf gh-proxy + depth=1），连跑 2 次 job；第二次拉同一仓库
- **判定**：两次 access.log 中 `github.com`/gh-proxy 域名均为 `TCP_MISS`/直接回源，`registry_proxy_http_hits_total` 不增长；但第二次 DURATION 明显更快（带宽差异而非缓存）
- **反例对照**：同 job 内 wget 一个 codeload tarball 两次 → 第二次应 HIT（证明 Squid 本身工作正常，差异确实来自协议）

### S2. url_rewrite 白名单原型：静态路径重写、git 路径放行（验证：方案 B 可行性）

- **验证论点**：话题一方案 B + 话题二"只对静态路径白名单替换"
- **步骤**：测试环境 Squid 配置上文 helper + `url_rewrite_access` 白名单（仅 `\.tar\.gz$` 等归档 + codeload/github 域名）
  1. `wget https://github.com/<repo>/archive/v1.0.tar.gz` → 应被重写到 gh-proxy 且成功
  2. `git clone https://github.com/<repo>.git`（不设 insteadOf，直走 Squid）→ `/info/refs`、`/git-upload-pack` 不进 helper，原样直连 GitHub 成功
- **判定**：cache.log 中重写只出现在归档 URL；git clone 全程无重写记录；两个操作都 exit 0
- **注意**：helper 处理需在超时预算内（Squid 默认对 rewrite helper 有超时），并发拉取时观察 `url_rewrite_children` 是否打满

### S3. 镜像同步延迟导致的新版本 404（验证：内容漂移缺点 1）

- **验证论点**：话题二"镜像同步有延迟 → 刚发布的版本 404"
- **步骤**：挑一个高频更新的包索引（如 pypi 某刚发版的小包），分别在官方源与国内镜像上查询同版本
- **判定**：官方源 200 而镜像 404（窗口期内），记录延迟时长；超窗口后镜像侧变 200。此场景难以在 CI 内自动化定时复现，可手动抽测并记录
- **变体**：`pip download <pkg> --no-deps -d /tmp` 分别走官方/镜像，对比版本可用性

### S4. hash 锁定在镜像上的兼容性（验证：缺点 1 的零容忍面）

- **验证论点**：话题二"pip --require-hashes / go.sum 对重打包零容忍"
- **步骤**：在 gy-006 用 `pip install --require-hashes -r <锁定文件>`（走 Squid → 镜像）；同法跑 `go mod download`（go.sum 校验）
- **判定**：exit 0 且下载全走镜像域名。若镜像重打包/重压缩过，hash 校验会直接失败——失败即证明该缺点存在
- **预填缓存对照**：第二次跑同 job，验证镜像流量被 Squid 正常缓存（HIT），即"客户端换源 + Squid 缓存镜像站"组合成立

### S5. GitHub release 302 后跳绕过镜像（验证：缺点 3）

- **验证论点**：话题二"首跳换了，Location 指向官方 CDN，大文件实际仍走境外"
- **步骤**：在测试 job 中 `curl -sIL` 一个 GitHub release asset，观察重定向链；再通过启用了 url_rewrite 的 Squid 实际下载该 asset
- **判定**：重定向链含 `objects.githubusercontent.com`；url_rewrite 对 302 的 Location 无能为力（access.log 显示后续请求仍是官方 CDN 域名），境外带宽未被省下
- **对照**：改用 codeload 归档（无 302）→ 重写生效，走 gh-proxy。印证"url_rewrite 只适用于无 302 的静态路径"

### S6. 换源导致缓存键分裂与命中率清零（验证：CI 特有缺点 4）

- **验证论点**：话题二"换源 = 旧缓存条目全作废；URL 混用则同一包缓存两份"
- **步骤**：
  1. 在 gy-006 先用官方源 wget 一个包两次（第 2 次 HIT，记录命中）
  2. 客户端 sed 换成镜像源后再拉同一包两次（内容等价的 URL）
- **判定**：换成镜像域名后第 1 次是 MISS（旧官方 URL 缓存作废），第 2 次才 HIT——证明缓存键 = 完整 URL；分析 access.log 确认同一内容在缓存中存了两份（两个 URL 键）
- **引申**：统计新旧两种 URL 的请求比例，评估"注入收敛"的必要性

### S7. 新镜像域名未进 ssl_bump 白名单 → 丢失缓存（验证：联动成本缺点 6）

- **验证论点**：话题二"不更新白名单则新域名被 splice 直通，换源反而丢缓存"
- **步骤**：在**生产配置形态**（域名白名单 splice，参考 PR#3 chart 写法）下，用白名单之外的镜像域名下载归档两次
- **判定**：access.log 中该域名状态为 `TCP_TUNNEL`（splice 直通，不进 HTTP 缓存层），`registry_proxy_http_hits_total` 无增长——Squid 对它完全无感。随后把域名加入白名单，重复实验变 HIT
- **注意**：需临时使用 `bump all` 的测试套件，或在 staging 集群验证，避免影响生产

### S8. 镜像站故障的爆炸半径（验证：集中故障点缺点 5）

- **验证论点**：话题二"镜像挂掉 → 所有 job 同时失败；客户端层可单 job 救急"
- **步骤**：用 iptables/网络策略模拟镜像域名不可达（或挑镜像站维护窗口），同时跑两类 job：a) 换源 job，b) 未换源走官方源 job
- **判定**：a 失败、b 成功——证明换源引入了新的可用性依赖；演示客户端层可临时删掉 sed/insteadOf 切回官方源救急，而 url_rewrite 方案需要登 Squid 改配置 + reload，救急路径更长

### S9. docker 双轨回归（验证：落地建议第 3 条）

- **验证论点**：话题二"docker 维持 m.daocloud.io 前缀 + registry-proxy 缓存"
- **步骤**：复用 `traffic-test/tool/17-docker-pull.yaml` 三段式（冷拉 MISS → rmi → pull#2 HIT → pull#3 HIT）
- **判定**：PULL2/PULL3 时长显著小于 PULL1；`registry_proxy_http_hits_total` 增长且回源下载次数不增加；全程无 401（SWR 凭据挂载正常）

### S10. 汇总回归：统一注入配方 vs 散落注入（验证：收敛建议）

- **验证论点**：话题二"把散落换源收敛为统一注入模板"
- **步骤**：将 03/06/08/01 等工具用例中的换源注入抽成统一配方（基镜像或 postStart 公共脚本），全量重跑 `scripts/test-all.sh`（Compose 套件）或 16-tool 集群套件
- **判定**：`jq -e '.all_passed' result.json` 为 true；流量报表域名归因表中新增镜像域名全部出现在 bump 白名单内（无 TCP_TUNNEL 漏网）

### Review 优先级建议

| 优先级 | 场景 | 理由 |
|---|---|---|
| P0 | S1、S9 | 已有现成用例，低成本复验核心结论 |
| P1 | S2、S6、S7 | url_rewrite 兜底落地 + 缓存键/白名单两个最隐蔽的坑 |
| P2 | S4、S5、S8 | 换源缺点的实证，可手动抽测 |
| P3 | S3、S10 | 依赖外部时机/全量回归，按需安排 |
