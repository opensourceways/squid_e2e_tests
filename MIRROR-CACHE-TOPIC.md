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
