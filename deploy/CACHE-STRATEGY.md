# Squid 缓存策略完整分析（CI 场景）

> 场景：gy-006 集群开源 CI（vllm-ascend / ascend-ci），GitHub Actions + buildkit CPU runner，
> 全部流量经 squid（:3129，SSL-Bump）缓存代理。SFS Turbo PVC 实测带宽上限 ~400MB/s。
> 分析对象：`deploy/chart/templates/configmap.yaml` 当前 squid.conf（chart 0.1.4→0.1.6）。
> 所有 squid 语义均已对 squid 7.6 实测/文档查证。

---

## 1. 场景与目标

**负载构成**（16-tool 并发流量测试，10 并发，见 `traffic-test/TOOL-RESULTS.md`）：

| 流量 | 代表工具 | 占出站比例 |
|---|---|---|
| 包管理器依赖 | apt / yum / conda / pip / uv / npm / pnpm / cargo / go | 大头 |
| 源码/归档 | git clone、GitHub archive、cmake FetchContent、bazel http_archive | 中 |
| 模型权重 | wget / huggingface / git-lfs（.pth/.safetensors/bin） | 中 |
| 容器镜像 | docker.io / quay.io / ghcr.io（**splice 直通，squid 不缓存**） | 独立链路 |

**目标**：重复构建最大化命中率、最小化回源；缓存正确性（不拿脏数据）优先于命中率。

---

## 2. 架构：两层独立缓存

```
CI 工具 ──:3129 squid (SSL-Bump) ── 产物/索引/全部 HTTPS ──→ 源站
                └─ registry 域名 splice 直通 ──→ :3128 rpardini nginx (proxy_cache) ──→ registry API
```

| 层 | 引擎 | 策略机制 | 缓存键 | Authorization 响应 |
|---|---|---|---|---|
| squid | refresh_pattern | `lifetime=(Date−LM)×percent`，min 下限 max 上限 | MD5(方法+URI+Vary 变体) | **默认不缓存**（RFC 7234） |
| registry | nginx proxy_cache | 跟随源站 Cache-Control/Expires（镜像内置配置，chart 不托管） | `$scheme://$host$request_uri` | **默认缓存** |

要点：容器镜像流量在 squid 层完全不可见（splice 名单含 swr/docker.io/k8s.io/ghcr.io/gcr.io/quay.io），
squid 的 refresh_pattern 对镜像无效，`\.docker\.io` 规则是死代码。

---

## 3. 缓存机制基础（squid 7.6 实测语义）

### 3.1 refresh_pattern 生命周期

```
lifetime = (Date − Last-Modified) × percent     # 无 LM 时 lifetime = min
fresh    = age ≤ max(lifetime, min) 且 age ≤ max
STALE    = age > max                            # max 是硬上限（7.6 警告 cropped 到 365d）
```

- **LM 越老，lifetime 越长**（percent 老化红利）：一年前的静态文件 × 20% = 73 天缓存。
  这是 go/conda 高命中率的真实机制。
- 源站 Cache-Control/Expires 通常被 refresh_pattern 覆盖（除非 override 语义关闭）。
- min=10080 强制 7 天 fresh 下限 —— 对 mutable 内容（同 URL 可覆盖）即 7 天脏窗口。

### 3.2 选项语义（有效性以 squid 7.6 为准）

| 选项 | 状态 | 语义 | 适用 |
|---|---|---|---|
| `ignore-reload` | ✅ 有效（legacy WARNING） | 忽略客户端 `Cache-Control: no-cache/max-age=0/Pragma`，直接给缓存 | 内容不可变源站 |
| `override-expire` | ✅ 有效（legacy WARNING） | 覆盖源站 Expires/max-age | 内容不可变源站 |
| `ignore-no-store` | ✅ 有效（legacy WARNING） | 忽略源站 `no-store`，强制缓存 | 内容不可变源站 |
| `ignore-no-cache` | ❌ **squid 4+ 已移除** | 无法忽略源站 `no-cache`——强制 must-revalidate（每请求 304 验证） | 不可用 |
| `override-vary` | ❌ **7.6 未知选项**（日志 ERROR） | 忽略 Vary 变体 | 不可用 |
| `ignore-private` | ✅ 有效（legacy WARNING） | 忽略 `Cache-Control: private` | 索引/元数据 |
| `max-stale=NN` / `store-stale` | ✅ 有效 | stale 时仍可服务（stale-while-error） | 未启用 |
| `reload-into-ims` | ✅ 有效 | 客户端 reload → 转 If-Modified-Since | 未启用 |

**关键约束**：源站 `Cache-Control: no-cache` 的响应**每个请求都回源 304 验证**，配置无法关闭。

### 3.3 匹配顺序与"截胡"效应（域名规则 = 元数据兜底）

refresh_pattern 是**顺序优先**（第一个匹配的规则生效，无最长匹配）。当前 15 条规则的排列
刻意把**扩展名 immutable 规则放在域名规则之前**，产生截胡效应：

| 域名规则 | 扩展名规则截胡后，实际覆盖范围 | 分类 |
|---|---|---|
| `\.pypi\.org/.*` | 纯 `simple/` 索引页（制品在 files.pythonhosted.org，pypi.org 无制品） | ✅ 纯元数据 |
| `\.golang\.org` + `proxy\.golang\.org` | `@v/list`/`.info`/`.mod` 元数据 + 内容寻址 `.zip`（未截胡，go zip 无扩展名规则） | ⚠️ 混合 |
| `\.debian\.org` + `\.ubuntu\.com` | `dists/.../InRelease`/`Packages.gz`/`Release` 索引；`pool/*.deb` 已被 `\.deb$` 截胡 | ⚠️ 元数据为主 |
| catch-all `.` | 未分类：git 对象、conda、yum、npm 等 | 兜底 |

**推论**：
- `0 20% 4320` 对纯元数据=正确（易变，靠 LM/短窗口）；对混合域名=保守兜底（制品若源站带
  缓存头仍可靠 LM 命中，go .zip 内容寻址受益于此）
- **顺序敏感**：若把域名规则移到扩展名规则之前（或误删扩展名规则），`.deb`/`.whl` 会落入
  域名规则 → 从 immutable 跌为 `0 20% 4320`，重负载 apt/pip 命中率回落
- §5 的"死规则"判定（pythonhosted 等）同样基于此机制
命中率天花板 = 源站发 no-cache 的对象比例（实测 16 工具大多 89-100%，说明 CI 对象大多不带 no-cache）。

### 3.3 Vary 与缓存键

- cache key = MD5(方法 + 归一化 URI + Vary 变体值)
- `reply_header_replace Vary Accept-Encoding` 把所有 Vary 拍平 → 消灭变体分裂，代价是
  **串版风险**：不同 Accept-Encoding 的客户端会拿到同一变体字节（CI 工具统一 identity 时无害）。
- 签名 URL（带 Expires/Policy/Signature query）每次不同 → key 不同 → **永不可复用**（HF 实测）。

### 3.4 结构限制（协议级，配置不可修复）

| # | 限制 | 影响 |
|---|---|---|
| 1 | **POST 不缓存**（git-upload-pack） | git clone/fetch 每次全量回源，命中率恒 0% |
| 2 | **302 不缓存 + 签名 URL** | HF resolve 权重实际无法命中缓存 |
| 3 | `maximum_object_size 8192 MB` | >8GB 单对象从不缓存，全量回源 |
| 4 | Authorization 响应默认不缓存（squid） | 与 nginx 层行为不同（nginx 缓存） |

---

## 4. CI 流量逐项分析（实测 + 归因）

| 工具 | 流量对象 | 寻址方式 | 源站类型 | 当前规则路径 | 实测 HIT% | 风险 | 结论 |
|---|---|---|---|---|---|---|---|
| apt | pool/*.deb | 内容寻址（名含版本） | A 只读 | `\.deb$` immutable | 99.8% | 无（GPG 自愈） | ✅ |
| yum/dnf | rpm | 内容寻址 | A | catch-all（LM 老化） | 99.9% | 无 | ✅ |
| conda | repodata + .conda/tar.bz2 | 内容寻址 | A | catch-all（老 LM） | 99.8% | 无 | ✅ |
| uv/pip | *.whl + simple/ 索引 | wheel 内容寻址 | A | `\.whl$` + 索引行 | 95.2% | 无 | ✅ |
| npm/pnpm | tarball + registry 索引 | 内容寻址 | A | catch-all + 索引行 | 95.4/97.4% | 无 | ✅ |
| cargo | crates.io .crate | 内容寻址 | A | `\.crate$` immutable（0.1.4 起） | 11%→95% | 无 | ✅ |
| go mod | proxy.golang.org .zip/.mod/.info | module@version 内容寻址 | A | `\.zip$` + golang 行 | 89.7% | 无 | ✅ |
| bazel | http_archive 归档 | 内容寻址为主 | A | `\.zip$`/`\.tar\.gz$` | 94.5% | 低 | ✅ |
| cmake | FetchContent 归档 | 混合（部分 ref 寻址） | A/B | 同上 | 62.1% | 中 | ⚠️ |
| wget .pth | 模型权重静态 URL | **同 URL 可覆盖** | **B 可变** | `\.(pth\|pt\|safetensors)$` immutable | 60.3%→100% | **7d 脏窗口** | ⚠️ 需降级 |
| huggingface | resolve/ → 302 + 签名 CDN | ref 寻址 + 签名 | B | 同上（**实际不生效**） | 91.9% | 无（已失效） | ❌ 无效 |
| git-lfs | LFS 大对象 | 内容寻址 | A | catch-all | 99.7% | 无 | ✅ |
| git clone | smart HTTP pack | **POST** | A | **不可缓存** | 0% | 结构限制 | ⛔ |
| obsutil | OBS 对象 | 内容寻址 | A | catch-all | 98.6% | 无 | ✅ |
| pip 索引 | simple/ 页面 | 5min 同步镜像 | A（近实时） | 索引行 0/20%/4320 | — | 低 | ✅ |

**源站类型定义**：
- **A 只读**：协议/签名保证"同 URL 内容不变"（pypi.org/crates.io/debian pool/镜像站/GH release asset）→ 长缓存零风险
- **B 可变**：同 URL 内容可覆盖（权重静态 URL、内部制品库、分支寻址归档）→ 长缓存=脏数据

---

## 5. 逐条规则审计（13 条 refresh_pattern）

| # | 规则 | 裁决 |
|---|---|---|
| 1 | `\.whl$ 10080 100% 525960 ignore-reload override-expire ignore-no-store` | ✅ 保留（A 类，内容寻址） |
| 2 | `\.crate$ 同上` | ✅ 保留 |
| 3 | `\.deb$ 同上` | ✅ 保留 |
| 4 | `\.zip$ 同上` | ⚠️ **降级**：分支寻址 mutable（codeload 实测无 Cache-Control+ETag，7d~1y stale） |
| 5 | `\.tar\.gz$ 同上` | ⚠️ **降级**（同 .zip） |
| 6 | `\.(pth\|pt\|safetensors)$ 同上` | ⚠️ **降级**：B 类可覆盖源站，7d 强制 fresh=脏窗口；HF 场景因 302+签名已无效 |
| 7-8 | `repo.huaweicloud.com / mirrors.tuna .../simple/ 0 20% 4320 ignore-private ignore-reload` | ✅ 保留（20% 老化匹配 5min 同步频率） |
| 9 | `.pypi.org/.* 0 20% 4320 ignore-private` | ✅ 保留，**转义修正** `\.pypi\.org` |
| 10 | `.pythonhosted.org/.* 同上` | ❌ 死规则（wheel 被 #1 先匹配），删或留档 |
| 11 | `.golang.org/.* 同上` | ✅ 保留，**转义修正** `\.golang\.org` |
| 12 | `proxy.golang.org/.* 同上` | ✅ 保留 |
| 13 | `.docker.io/.* 同上` | ❌ **删除**：splice 名单内，squid 永不缓存 |
| 14 | `.debian.org/.* / .ubuntu.com/.* 同上` | ✅ 保留 |
| 15 | `.` catch-all 0 20% 4320 | ✅ 保留（git 对象、conda、yum 等走此） |

**其他配置项**：
- `reply_header_replace Vary Accept-Encoding`：✅ 保留（串版风险已在 3.3 说明，CI 工具统一 identity 无害）
- `maximum_object_size 8192 MB`：✅ 保留（>8GB 权重不缓存，避免磁盘 20GB 驱逐抖动）
- `max=525960`：⚠️ 改 `525600`（消除 cropped WARNING，意图诚实）

---

## 6. 选项语义裁决（CI 场景）

| 选项 | 裁决 | 理由 |
|---|---|---|
| `ignore-reload`（产物行） | ✅ **保留** | 成本不对称：A 类源站上客户端验证请求（hf force_download、curl -H no-cache、HTTP 库硬刷新）结果必为 304，拦截=省往返，误伤=0 |
| `ignore-reload`（索引行） | ❌ 不加 | 索引会变，客户端"要最新"是合理意图 |
| `override-expire` | ✅ 保留（产物行） | 同上 |
| `ignore-no-store` | ✅ 保留（产物行） | A 类源站 no-store 无业务含义；B 类源站（权重）随降级移除 |
| `ignore-no-cache` | ❌ 移除（已无效） | squid 4+ 移除，配置中 6 处是 no-op，删除以免误导 |
| `override-vary` | ❌ 移除（报错） | 7.6 未知选项，日志 ERROR |
| `ignore-private` | ✅ 保留（索引行） | 索引/元数据可公开缓存 |
| `max-stale/store-stale` | 可选 | 未来对源站抖动做 stale-while-error，未启用 |

---

## 7. 最终推荐配置形态（chart 0.1.6）

```squid
# A 类不可变产物（内容寻址，源站不可覆盖）
refresh_pattern -i \.whl$  10080 100% 525600 ignore-reload override-expire ignore-no-store
refresh_pattern -i \.crate$ 10080 100% 525600 ignore-reload override-expire ignore-no-store
refresh_pattern -i \.deb$  10080 100% 525600 ignore-reload override-expire ignore-no-store

# B 类可变内容（权重/分支归档）：尊重 LM 老化，不强制 fresh
refresh_pattern -i \.(pth|pt|safetensors)$ 0 20% 4320
# .zip/.tar.gz 移除 immutable，落回以下域名规则 / catch-all：
refresh_pattern -i proxy\.golang\.org/.* 0 20% 4320 ignore-private
refresh_pattern -i codeload\.github\.com/.*/refs/heads/ 0 20% 4320
refresh_pattern -i codeload\.github\.com/.*/refs/tags/ 0 20% 525600 ignore-reload override-expire ignore-no-store
refresh_pattern -i github\.com/.*/releases/download/ 0 20% 525600 ignore-reload override-expire ignore-no-store

# 索引/元数据
refresh_pattern -i repo\.huaweicloud\.com/.*/simple/ 0 20% 4320 ignore-private ignore-reload
refresh_pattern -i mirrors\.tuna\.tsinghua\.edu\.cn/.*/simple/ 0 20% 4320 ignore-private ignore-reload
refresh_pattern -i \.pypi\.org/.* 0 20% 4320 ignore-private
refresh_pattern -i \.golang\.org/.* 0 20% 4320 ignore-private
refresh_pattern -i .debian.org/.* 0 20% 4320 ignore-private
refresh_pattern -i .ubuntu.com/.* 0 20% 4320 ignore-private
refresh_pattern . 0 20% 4320
```

设计原则：**immutable 属性必须来自"寻址方式"（内容寻址 + 源站不可覆盖），而不是扩展名**。
扩展名只决定"可能是哪种产物"，寻址方式决定"能不能长缓存"。

---

## 8. 命中率与正确性的边界（预期）

| 场景 | 命中率预期 | 说明 |
|---|---|---|
| 依赖下载（apt/yum/conda/pip/npm/cargo/go） | 90-100% | 内容寻址 + A 类源站，规则已覆盖 |
| 权重/模型（.pth/.safetensors） | 60-70%（LM 老化） | B 类源站，正确性优先；HF 因 302+签名实际不缓存 |
| git clone | 0% | POST 协议限制，只能靠带宽/gh-proxy |
| 容器镜像 | 依赖 nginx 层 | squid 不可见，registry-exporter 监控 |

---

## 9. 行动清单

| 优先级 | 动作 | 状态 |
|---|---|---|
| P0 | zip/tar.gz/pth 从 immutable 降级（图 7 形态） | 待落地 |
| P1 | 删除 `\.docker\.io` 死规则 + 域名转义统一 | 待落地 |
| P1 | 移除无效 `ignore-no-cache`×6 / `override-vary`×2 | 已改（traffic-test 分支，未提交） |
| P2 | max=525960→525600；注释自文档化 | 已改 |
| P2 | Chart.yaml bump 0.1.6 | 待定（0.1.5 被 pvc-perf-bench 占用） |
| P3 | 集群回滚风险：ArgoCD 已把 0.1.4 规则回滚，重新部署需 force-conflicts | 待决策 |

---

## 10. 实测证据附录

- 16-tool 并发测试：`traffic-test/TOOL-RESULTS.md`（含 cargo 11%→95%、wget 60%→100% 前后对比）
- 0.1.6 策略复测（2026-08-14，r3/r4 窗口修正后）：01 pip=99.9%、08 bazel=99.9%（7.4GB HIT）、09 npm=99.9%
- PVC 触底：`traffic-test/PVC-PERF-RESULTS.md`（单连接 42MB/s，聚合上限 ~400MB/s）
- 响应头实测：codeload branch zip（无 Cache-Control+ETag）、HF resolve（302+no-store+签名 URL）、
  GitHub release（no-cache）、git smart HTTP（POST/GET 确认）
- squid 7.6 选项有效性：`squid.conf.documented` 对照 + cache.log 报错采集

### 10.1 测试基建已知坑（r3/r4 实测）

- **Volcano 分批调度**：`minAvailable=1` 时 job pods 分批创建/运行，vj 状态 `Completed`
  可能早于最后一批 pods 的流量结束（实测差 1-3 分钟）→ analyze 窗口必须加尾部缓冲
  （`DONE+180s`），否则 case 窗口内只剩背景流量，HIT% 假性为 0（case 01 曾误报 0%）。
- **背景 TLS 噪音**：集群内存在未知客户端（源 IP 不在任何 pod/Service 列表，疑似跨 VPC
  或已删 pod 残留连接）每 1-5s 对 `api.github.com:443` 发 CONNECT + TLS 握手失败
  （`Cannot accept a TLS connection`，detail `A000412` = SSL alert `bad certificate`），
  每分钟 ~10-20 条，持续 24/7。与 case 流量无关；analyze 需过滤 `NONE_NONE` 状态。
- **access.log 时间戳**：第 1 列为 epoch 秒（毫秒小数），grep HH:MM 匹配不到，须用
  epoch 窗口过滤。
