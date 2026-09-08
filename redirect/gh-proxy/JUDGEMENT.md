# gh-proxy 当前判断（JUDGEMENT）

> 判断留档（2026-09-08）。配套：`redirect/SOURCE-REWRITE-ANALYSIS.md`（github.com 场景）、
> `redirect/MIRROR-CACHE-TOPIC.md`（换源框架）。本文聚焦 **gh-proxy 这一个组件**：
> 它是什么、当前如何被使用、已知行为特征、不可靠点、以及待验证的盲区。
> 所有结论均有 2026-09-07/08 实测证据支撑（见文末"证据清单"）。
>
> **2026-09-08 修订①**：根据 review 意见修正——①"多后端坏 IP"由"根因"降级为"候选成因之一"，
> 补充 domaintest 反证与 configmap helper-bug 留档的交叉辨析（3.3）；②一处未实测的表述修正（codeload/objects）；
> ③证据脚本从易失的 `/tmp` 归档进本目录。
>
> **2026-09-08 修订②（P1/P2/P5 实证定论）**：执行 TEST-WORKFLOW P1+P2+P5(复盘)——证书归属甄别
> **排除多后端假设**（gh-proxy 单后端 `202.170.93.254`，证书 `*.test.osinfra.cn`；`20.205.243.166`
> 证书是 `github.com` = GitHub 边缘）；根因定性为 **squid 对 gh-proxy 的 DNS 间歇性落到 .166**，
> helper 重写是翻倍死循环的放大器；301 **未被 squid 缓存**（TCP_HIT/301=0）。详见 3.3。
>
> **2026-09-08 修订③（P3/P4/P6 实证）**：执行 TEST-WORKFLOW P3(服务端缓存语义)+P4(大文件并发
> +Accept-Encoding)+P6(insteadOf 全链路回归)。**服务端缓存存在但无缓存标记头、不响应 304 条件请求、
> 404 也会被缓存（短 TTL）**；大文件并发靠 squid 本地副本吸收（15 并发全 TCP_REFRESH_UNMODIFIED，
> 1-4.6s）；**gzip 请求会因 `Vary: Accept-Encoding` 击穿 squid 缓存**（重新回源 17.9s vs plain 0.79s）。
> insteadOf→gh-proxy 全链路稳定（git clone 1.7s/1.6s、wget 缓存生效、codeload 直链 TCP_HIT 0.21s）。
> 详见 3.4/3.7。
>
> **2026-09-08 修订④（白名单边界实证，修正 3.5）**：gh-proxy 前缀 + 各 GitHub 子域逐测——
> **`raw.githubusercontent.com` 实测 200 放行**（bazel `--registry` 依赖它拉 BCR 元数据）；
> `codeload.github.com` / `objects.githubusercontent.com` / `release-assets.githubusercontent.com`
> 均 403 拒绝。白名单并非"只放行 github.com 主域"，而是**放行 github.com 主域 + raw 子域**。
> 详见 3.5。
>
> **2026-09-08 修订⑤（用户决定：简洁优先，重写策略翻盘）**：首选方案改为
> **统一重写 `github.com → gh-proxy` + pin DNS**（只认识 github.com 一个域 + 只解析 gh-proxy 一个
> IP，302 链由 gh-proxy 服务端消化，其余子域全不管）。根因（squid DNS 间歇落到 .166）通过
> **pin DNS（hosts_file + ConfigMap 挂载）根治**，重写进 gh-proxy 的 301 翻倍随之消除 →
> 3.2 的"不可用"结论在 pin DNS 后**翻盘为可用**。原 archive→codeload 1:1 降级为**备选**（仅
> gh-proxy 不可用时）。详见 SOLUTION.md。
>
> **2026-09-08 修订⑥（根因推翻修订②/⑤——ssl-bump CONNECT + url_rewrite 机制缺陷）**：
> 301 翻倍根因**不是** squid DNS 污染，而是 **ssl-bump 下 https 重写的结构性机制缺陷**：
> ① https 请求先 CONNECT 原域名（github.com:443）→ **正常**解析到 GitHub 边缘 IP `.166` 并建立
> TCP 连接；② bump 解密后 helper 把 URL 重写到 gh-proxy；③ squid **复用已建立的 `.166` 连接**，
> 不按新 host 重新建连/解析；④ 请求以 `Host: gh-proxy.test.osinfra.cn` 发到 GitHub 的 `.166` →
> 畸形 301（Location 翻倍）；⑤ 客户端跟随 → 又回 github.com → helper 再重写 → **死循环**。
> **pin DNS 治不了**——CONNECT 阶段解析的是 github.com（→.166 本来就对），重写后连接不重建。
> **普适性已验证**：所有 https 域重写全部失败（github→gh-proxy 301 翻倍；pypi→tuna 421——
> CONNECT pypi.org→151.101.0.223，重写后仍发 `.223`）；**http 明文重写正常**（archive.ubuntu.com
> →huaweicloud 200，无 CONNECT，重写发生在建连前）。→ 修订②"DNS 间歇落到 .166"是**误判**：
> .166 是 github.com 的正常解析，翻倍链走 .166 是连接复用的必然结果。**helper 重写 https 在
> ssl-bump 下结构性不可用（无论是否 pin DNS）**；可行路径 = **客户端 insteadOf 换源**（URL 直接
> 写 gh-proxy 前缀，如 02 用例 task3，验证全通）。首选从"统一重写"回到"客户端 insteadOf +
> squid 本地缓存"。详见 3.2/3.3 与 SOLUTION.md。

---

## 一、一句话判断

**gh-proxy（`gh-proxy.test.osinfra.cn`）是一个"服务端抓取 + 服务端缓存"的 GitHub 加速反代：**
集群内直连稳定（直连 7/7 + domaintest 20/20 全 200）、小文件并发可用、服务端缓存有效（次发 0.95s）。
**"301 Location 翻倍 → 死循环"根因已定论（修订⑥）：ssl-bump 下 https 重写的结构性机制缺陷**——
CONNECT 阶段按原域名（github.com → `.166`，正常解析）建连，bump 解密后 helper 重写 URL，但 squid
**复用已建连接、不按新 host 重建** → 请求发往错误 IP → 畸形 301。**pin DNS 治不了，且所有 https
域重写全部中招（pypi→tuna 421）；仅 http 明文重写可用**（无 CONNECT，重写在建连前，archive/ports
→huaweicloud 200）。
正确用法（修订⑥，首选）：**客户端 insteadOf 直连 gh-proxy（URL 写 gh-proxy 前缀）+ squid 本地缓存**。

核心对比：**给客户端用（insteadOf 直连）✅（7/7 + 20/20 样本观测 + P6/02-task3 全链路）/ 给 Squid
helper 重写 https 用 ❌（ssl-bump 连接复用，结构性不可用，修订⑥定论）**。

---

## 二、gh-proxy 是什么

| 项 | 值 |
|---|---|
| 域名 | `gh-proxy.test.osinfra.cn`（内部测试域，集群内可达） |
| 形态 | URL 前缀反代：`https://gh-proxy.test.osinfra.cn/https://github.com/<原路径>` |
| 角色 | **服务端抓取**（server-side fetch）：替客户端跟随 GitHub 的 302，把内容回传 |
| 缓存 | **服务端缓存**：同一 URL 二次请求命中其内部缓存（实测次发 0.95s） |
| 白名单 | 放行 `github.com` 主域 + `raw.githubusercontent.com` 子域（**实测 200**）；codeload / objects / release-assets **403 拒绝**（修订④） |
| 网络位置 | 内网可达、境外出口（抓 GitHub 由它自己扛） |

### 典型用法（生产/现网已落地）

1. **git insteadOf**：`git config url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"` —— spdlog/googletest 等现网任务在用。
2. **wget/curl 手动换源**：URL 直接写 `https://gh-proxy.test.osinfra.cn/https://github.com/...`（tool/08-bazel.yaml 的 WORKSPACE 写法）。

### 设计本意（为什么存在）

GitHub 官方 archive 端点有**单 IP 并发限流**（squid 单出口 IP 撞限流 → CONNECT 全超时 503）。
gh-proxy 把境外抓取放在**服务端 + 内网出口**，客户端只和内网域名说话 → 绕开 GitHub 对"客户端出口 IP"的限流。
同时它的**服务端缓存**让重复下载（CI 场景）变快。

---

## 三、当前判断（分场景）

### 3.1 ✅ 直连可用（7/7 全 200，无 404）

`direct-ghproxy-only.yaml` 实测：同一 URL 连打 5 次 + 3 个不同 repo URL，**全部 HTTP 200**。
- 直连 gh-proxy 本身**不产生 404**（澄清了早期"重写进 gh-proxy 可能 404"的错误猜测）。
- 默认 DNS 解析到的后端行为正常（见下）。
- ⚠️ 注意：7/7 + domaintest 20/20 均为**有限样本观测**，不是"机制上保证 100% 直连无故障"。

### 3.2 ❌ 经 Squid url_rewrite 重写进 gh-proxy —— 结构性不可用（修订⑥定论）

> 本节记录的是 **https 重写**的表现。根因已定论（修订⑥）：ssl-bump CONNECT + url_rewrite 连接复用，
> 与 DNS 无关，**pin DNS 无效**。

| 实测项 | 结果 |
|---|---|
| helper 重写后访问（首次） | `301`，Location=`https://github.com/https://github.com/...`（**URL 翻倍**）|
| 同一 URL 直连 gh-proxy | `200`（gh-proxy 自身没问题）|
| 重试同一 URL | `200`（gh-proxy 内部已缓存 zip）|
| `-L` 跟随 301 | `final=503`（翻倍 Location 链最终撞 GitHub 限流）|
| pin DNS（固定 `.254`）后重试 | **仍 301 翻倍**（修订⑥：pin 无效，机制问题）|

**结论（修订⑥）**：故障根因是 **ssl-bump CONNECT + url_rewrite 连接复用**（见 3.3），
**与 squid DNS 无关**。**helper 重写 https 在 ssl-bump 下结构性不可用，无论是否 pin DNS。**
该路径废弃；正确姿势 = 客户端 insteadOf 换源（3.7）。

### 3.3 ⚠️ 301 翻倍根因：ssl-bump CONNECT + url_rewrite 连接复用（修订⑥定论）

**修订⑥ 定论（推翻修订②/⑤ 的"DNS 污染"误判）**——机制链（用户实测，2026-09-08）：

1. https 请求先 CONNECT `github.com:443` → 解析到 `.166`（GitHub 边缘 IP，**正常解析**）并建立 TCP 连接
2. bump 解密后 helper 把 URL 重写成 `gh-proxy.test.osinfra.cn/...`
3. squid **复用已建立的 `.166` 连接**，不按新 host 重新建连/解析
4. 请求以 `Host: gh-proxy.test.osinfra.cn` 发到 GitHub 的 `.166` → GitHub 返回畸形 301（Location 翻倍）
5. 客户端跟随 → 又回 `github.com` → helper 又重写 → **死循环**

**为什么 pin DNS 治不了**：CONNECT 阶段解析的是 `github.com`（→.166 本来就对）；重写发生在 bump
解密后，连接不会因 URL 变化而重建——pin 住 gh-proxy 的 IP 与这条链无关。

**普适性（不只是 gh-proxy）**：

| 重写形态 | 实测 | 结论 |
|---|---|---|
| `https://github.com/*` → gh-proxy | **301 翻倍死循环** | 结构性不可用 |
| `https://pypi.org/simple/*` → tuna | **421**（CONNECT pypi.org→151.101.0.223，重写后仍发 `.223`）| 结构性不可用 |
| `http://archive.ubuntu.com/...` → huaweicloud | **200 正常** | 可用 |

**分界点**：**有 CONNECT/bump 的 https 重写全部失败；无 CONNECT 的 http 明文重写正常**
（重写发生在建连前，squid 按新 host 重新解析建连）。这同样否定 archive→codeload 1:1 的 https
重写形态——github.com 的 CONNECT 已定死在 `.166`，重写 codeload 也发往错误 IP。

**对过往结论的纠偏**：

- 修订②"DNS 间歇落到 .166"是**误判**——.166 是 github.com 的正常解析；翻倍链走 `.166` 是连接复用
  的必然结果，不是 DNS 污染。
- 证据 #9"经代理 0/20"与 #3 `HIER_DIRECT/20.205.243.166` 现在读作：**helper 重写后的请求仍走
  原 CONNECT 建立的 GitHub 连接**——两条证据都支持连接复用读法，不再支持 DNS 污染。
- 候选成因 A（helper 尾部垃圾 bug）曾修复，是叠加因素不是根因；候选成因 B（多后端坏 IP）与
  domaintest 反证冲突，维持排除。

**结论**：**helper 重写 https 域在 ssl-bump 下结构性不可用（无论是否 pin DNS）**。
可行路径 = **客户端 insteadOf 换源**（URL 直接写 gh-proxy 前缀，见 3.7）。

### 3.4 ✅ gh-proxy 服务端缓存有效（小文件并发可用）

| 场景 | 结果 |
|---|---|
| pybind11 850KB，gh-proxy 直连 10 并发 ×3 | **30/30 成功**，1.0~8.3s（首发略慢、次发 ≤3s）|
| obs 139MB，gh-proxy 直连 10 并发 ×3 | 29/30 成功，8.6~266.8s（大文件并发时上游带宽被瓜分）|
| obs 139MB，gh-proxy + squid（缓存已热）| **30/30 成功，1.1~4.4s**（squid 本地磁盘副本 + 304 校验）|

**结论**：小文件 gh-proxy 直连完美；大文件并发必须**让 squid 把 gh-proxy 抓回的内容落本地磁盘**
（`TCP_REFRESH_UNMODIFIED`），否则 gh-proxy 上游出站带宽成为瓶颈。

### 3.4b ⚠️ 服务端缓存语义（P3 实证）

| 项 | 实测 | 结论 |
|---|---|---|
| 缓存是否有效 | 全新 URL：首 2.8s → 立即重试 1.15s → 延迟重试 0.87s（均 200 全量）| **存在服务端缓存** |
| 缓存标记头 | 无 `Age`/`X-Cache`/`Cache-Control`；ETag 稳定 | **缓存不可观测**（无标准头）|
| 304 条件请求 | `If-None-Match` 带 ETag → 仍返回 **200 全量**（非 304）| **不响应条件请求**，每次全量传 |
| 404 是否缓存 | 不存在 tag：首 1.28s → 连续 5 次 0.58s 稳定命中 | **404 也被缓存**（短 TTL）|
| 200 缓存 TTL | 60s 后仍 0.9s 命中 | TTL ≥ 60s |
| 响应头来源 | `X-GitHub-Request-Id`/`x-github-edge-region`（GitHub 边缘），`Server: elb`（gh-proxy LB）| 透传 GitHub 原始头 |
| 上游 302 | 官方 archive 端点仍 302 → codeload | gh-proxy 跟随的对象确认 |

**影响**：① gh-proxy 服务端缓存是"闷头缓存"——客户端无法感知命中，也没有 304 优化；
② 404 短缓存风险低但存在；③ 客户端请求 gh-proxy 时每次拿到全量 200（对重复大文件仍
有服务端缓存收益，但无带宽节省的验证机制）。

### 3.7 ✅ insteadOf → gh-proxy 全链路回归（P6 实证）

| case | 结果 |
|---|---|
| git clone ×2（insteadOf→gh-proxy 走 squid）| rc=0，1745ms / 1623ms |
| wget gh-proxy 换源走 squid ×3 | 1771ms → 741ms → 882ms（缓存生效）|
| codeload 经 gh-proxy 换源 | 403 ×3（白名单确认）|
| codeload 直链走 squid ×2 | 1.07s → 0.21s（TCP_HIT）|
| obs 139MB 经 gh-proxy + squid ×3 | 20135ms → 18599ms → 1528ms（第三发命中）|

**结论**：推荐用法（insteadOf → gh-proxy 直连 + squid 本地缓存）稳定可复现；codeload 不可
换源、只能直连 + squid 长缓存。**注意**：squid 对 gh-proxy 域返回的 `Vary: Accept-Encoding`
头敏感——`gzip` 请求与 `identity` 请求是不同缓存键，**gzip 会击穿缓存**（重新回源 17.9s vs
plain 0.79s），实际链路中应统一客户端 Accept-Encoding 以避免缓存分裂。

### 3.5 ⚠️ 白名单边界（修订④实证：放行 github.com 主域 + raw 子域）

gh-proxy 前缀 + 各 GitHub 子域逐测（squid-cache-0 内，2026-09-08）：

| gh-proxy 前缀 + 目标 | 实测 | 结论 |
|---|---|---|
| `github.com/.../archive/refs/tags/<tag>.zip` | **200** | 放行（服务端抓取+缓存）|
| `github.com/.../releases/download/...` | **200** | 放行（生产 L82 长缓存依赖它）|
| `raw.githubusercontent.com/...`（如 BCR 元数据）| **200**（0.4s）| **放行**——bazel `--registry` 可经 gh-proxy 拉 BCR |
| `codeload.github.com/...` | **403**（×30）| 拒绝（存储域）|
| `objects.githubusercontent.com/...` | **403** | 拒绝（Release 资产存储域）|
| `release-assets.githubusercontent.com/...` | **403** | 拒绝（Release 资产存储域）|
| 裸 `github.com/` | **403** | 拒绝（无有效路径）|

**修正**：此前"白名单只放行 `github.com`"的表述**不准确**——`raw.githubusercontent.com`
**实测放行**（`--registry=https://gh-proxy.test.osinfra.cn/https://raw.githubusercontent.com/...`
可用，08-bazel.yaml 即此用法）。被拒的是 **Release 资产存储域**（objects / release-assets / codeload）。

**影响**：
- codeload 直链**无法换源**，只能官方直连 + squid 长缓存（实测 `TCP_HIT` 0.21s 最优）。
- bazel bzlmod `--registry` 指向 BCR（raw 子域）→ **经 gh-proxy 可用**；但 source.json 里实际
  归档 URL 多为 `github.com/.../archive|releases/download`，也在放行域内 → 全链路可行。

### 3.6 ✅ git Smart HTTP 协议兼容（insteadOf 模式）

| case | 结果 |
|---|---|
| insteadOf → gh-proxy，直连 | OK 4.6s / 1.8s（×2 均成功）|
| insteadOf → gh-proxy，走 squid | OK 4.2s / 2.2s（×2 均成功）|

git 的 `/info/refs` GET + `/git-upload-pack` POST 经 gh-proxy 均正常 → **gh-proxy 兼容 git Smart HTTP**
（与"国内包镜像不支持 Smart HTTP"不同，gh-proxy 系就是 git 代理）。注意：二次 clone 的 `/info/refs`
加速来自 **squid 侧 `TCP_REFRESH_MODIFIED`（304 校验）**，不是 gh-proxy 服务端缓存（POST 协议级不可缓存）。

---

## 四、给架构的结论

1. **首选（修订⑥）：客户端 insteadOf → gh-proxy 直连 + squid 本地缓存**——git/wget 换源
   的正确姿势，URL 直接写 `https://gh-proxy.test.osinfra.cn/https://github.com/...`（如 02 用例
   task3 / P6 实证：git clone 1.7s/1.6s、wget 缓存生效、codeload 直链 TCP_HIT 0.21s）。
2. **helper 重写 https 域结构性不可用**（ssl-bump 连接复用，修订⑥定论）：github→gh-proxy
   （301 翻倍）、pypi→tuna（421）、archive/ports/openeuler 的 https 形态——一律不依赖 helper
   重写 https，mirror-rewrite.sh 的 https 分支应停用。
3. **helper http 明文重写可用**：`http://archive.ubuntu.com` / `http://ports.ubuntu.com` /
   `http://repo.openeuler.org` → 华为云实测 200（无 CONNECT，重写在建连前）。
4. **archive→codeload 1:1（原备选）的 https 重写形态同样不可用**（github.com CONNECT 已定死
   `.166`，重写 codeload 也发往错误 IP）；codeload 正确姿势 = 客户端直连 + squid `refresh_pattern`
   长缓存（TCP_HIT 0.21s）。
5. **pin DNS（hosts_file + static-hosts）不再需要**——它不是 301 翻倍的解药；如保留仅作 gh-proxy
   单 IP 固定的加固，与重写链路无关。
6. **大文件并发下载**：让 squid 缓存 gh-proxy 回源内容（本地副本 + 304 校验）抗并发（维持）。
7. **统一客户端 Accept-Encoding**：squid 对 gh-proxy 域 `Vary: Accept-Encoding` 键分裂，
   gzip 请求击穿缓存（17.9s vs 0.79s）；CI 配方统一避免双缓存键（维持）。
8. **301 翻倍处置**：结构性限制（连接复用），非故障、非 DNS 问题——无需 pin DNS，也无需向
   gh-proxy 维护方反馈；用 insteadOf 换源即绕开。

---

## 五、证据清单（2026-09-07/08 实测）

| # | 证据 | 出处 |
|---|---|---|
| 1 | 直连 gh-proxy 7/7 全 200（无 404）| `gh-proxy/direct-ghproxy-only.yaml` 实测 |
| 2 | 强制 .166 → 301 翻倍 / 强制 .254 → 200 | `gh-proxy/resolve-ip-test.yaml` 实测 |
| 3 | access.log：成功走 202.170.93.254、翻倍行走 20.205.243.166 | squid access.log 抓取 |
| 4 | 翻倍 Location=`https://github.com/https://github.com/...`、-L 跟随 final=503 | 前述测试 |
| 5 | 白名单 codeload 403（×30）| 并发专项 C 场景 |
| 6 | gh-proxy 服务端缓存：次发 0.95s | 场景 3 直连版 |
| 7 | 大文件并发：gh-proxy 直连 8-267s vs +squid 1.1-4.4s | 并发专项 C/D |
| 8 | git insteadOf 直连/走 squid 均 OK | 场景 1 C/D |
| 9 | domaintest：gh-proxy **20/20 稳定**（直连+代理路径均 20/20）；github.com **直连 20/20 但经代理 0/20**（解析 IP 正是 .166）| `domaintest/REPORT-x20.md` |
| 10 | gh-proxy 20/20 全解析到单一 IP `202.170.93.254`；**`20.205.243.166` = github.com 解析 IP** | `domaintest/REPORT-x20.md` |
| 11 | helper 尾部垃圾导致"301 循环叠加"的修复留档（`while read -r url _`）| `deploy/chart/templates/configmap.yaml#L146-148` |
| 12 | 服务端缓存存在（首 2.8s→次 1.15s→0.87s）；无 Age/X-Cache；If-None-Match 仍 200 全量 | P3 冷测 boost-1.81.0/1.83.0（squid pod 直连）|
| 13 | 404 也被 gh-proxy 缓存（连续 5 次 0.58s）；200 缓存 60s 后仍命中 | P3 冷测 boost-9.99.0（不存在 tag）|
| 14 | GitHub 官方 archive 仍 302→codeload | P3.5 |
| 15 | 大文件并发靠 squid 吸收：15 并发全 `TCP_REFRESH_UNMODIFIED/200`，0.99-4.6s；warm 单发 18.5s | P4 obs 139MB 经 squid |
| 16 | **gzip 请求击穿 squid 缓存**（`Vary: Accept-Encoding` → 缓存键分裂）：gzip 17.9s vs plain 0.79s；zip 内容不被二次压缩（size 相同）| P4.4 |
| 17 | insteadOf 全链路回归：git clone 1745/1623ms rc=0；wget 1771→741ms；codeload 直链 1.07→0.21s TCP_HIT；obs 20135→1528ms | P6（gy-006 squid ns）|
| 18 | **白名单边界（修订④）**：`raw.githubusercontent.com` 经 gh-proxy **200 放行**；`codeload.github.com` / `objects.githubusercontent.com` / `release-assets.githubusercontent.com` 均 403；裸 `github.com/` 403 | 3.5 逐测（squid-cache-0）|
| 19 | **gy-001 生产流量统计（4.5 天）**：archive GET 179（~59%）/ git clone（CONNECT 214 + info 41 + upload-pack 82，~31%）/ releases 18（6%）/ raw 0；CONNECT 211/214 撞 `.166`（78 次 NONE_NONE/200）；gh-proxy 前缀 406 次（内 archive 83、upload-pack 82、info 41、codeload 38）| gy-001 squid-cache-0 access.log（Sep 3 16:57 → Sep 8 06:09 UTC）|
| 20 | **根因定论（修订⑥）**：https github.com→gh-proxy 301 翻倍 = ssl-bump 连接复用——CONNECT github.com:443→.166（**正常解析**）建连，helper 重写后 squid 复用 `.166` 连接、不按新 host 重建；请求以 gh-proxy 的 Host 打到 GitHub 边缘 → 畸形 301 翻倍；**pin DNS（固定 .254）后仍复现** | squid-cache-0 pod 内 curl -x 127.0.0.1:3129 + access.log（2026-09-08）|
| 21 | **普适性**：https pypi→tuna 重写同样失败——CONNECT pypi.org:443→151.101.0.223，重写后仍发 `.223` → **421**；证明所有 https 域重写在 ssl-bump 下均结构性失败 | squid-cache-0 pod 内实测（2026-09-08）|
| 22 | **分界点**：http 明文重写正常——`http://archive.ubuntu.com/dists/jammy/Release` → huaweicloud **200**（无 CONNECT，重写发生在建连前，squid 按新 host 重新解析建连）| squid-cache-0 pod 内实测（2026-09-08）|

---

## 六、待验证盲区（→ 见 TEST-WORKFLOW.md）

1. ~~gh-proxy 域名完整解析 IP 清单 + 证书归属甄别~~ —— **已解决（P1）**：单后端 `202.170.93.254`，
   `.166` = GitHub 边缘
2. ~~坏 301 恒定 vs 偶发、默认 DNS 自然命中率~~ —— **已推翻（修订⑥）**：不是 DNS 问题——
   `.166` 是 github.com 正常解析，翻倍链走 `.166` 是 ssl-bump 连接复用的必然结果
   （P2 的"间歇/偶发"是连接复用与客户端行为差异的误读）
3. ~~gh-proxy 服务端缓存语义（TTL/304/大小/301 缓存）~~ —— **已解决（P3）**：有缓存但无标记头、
   不响应 304、404 短缓存、TTL≥60s；冷 URL 首/次/延迟三连已实测
4. ~~大文件并发 + Accept-Encoding~~ —— **已解决（P4）**：squid 本地副本吸收并发；gzip 因
   `Vary: Accept-Encoding` 击穿缓存（缓存键分裂）
5. ~~301 翻倍后 squid 是否缓存成坏条目~~ —— **已解决（P5 复盘）**：`TCP_HIT/301=0`，301 未被 squid 缓存
6. ~~多后端是否共享服务端缓存~~ —— **跳过（P1 证实单后端，条件不成立）**
7. ~~白名单边界（哪些 GitHub 子域放行）~~ —— **已解决（修订④）**：放行 github.com 主域 +
   raw.githubusercontent.com 子域；codeload / objects / release-assets 拒绝
8. ~~archive / releases / clone 在生产中的实际占比~~ —— **已解决（修订⑤，证据 #19）**：
   gy-001 4.5 天生产日志——archive 59%（最高频 GET）、git clone ~31%、releases 6%、raw 0
9. ~~统一重写 github.com → gh-proxy + pin DNS 是否可用~~ —— **已解决（修订⑥）**：结构性
   不可用（ssl-bump 连接复用，pin DNS 无效）；首选改为**客户端 insteadOf 换源**
