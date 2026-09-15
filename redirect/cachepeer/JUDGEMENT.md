# cache_peer 选路实测判定（JUDGEMENT）

> 实测留档（2026-09-15，gy-006，squid 0.1.12 + cache-service）。配套：`TEST-WORKFLOW.md`（计划）、
> `gh-proxy/JUDGEMENT.md` 修订⑥（url_rewrite 判死的背景）。
> 所有结论均有当日实测证据（access.log / nginx 日志 / vcjob 日志）支撑。

---

## 一、一句话结论

**cache_peer 选路机制验证成功且 apt 链路可上生产**：http 明文域（apt）经 squid → cache_peer
→ cache-service(8081) → repo.huaweicloud，URL/缓存键原样不变，squid `TCP_MISS FIRSTUP_PARENT`
→ `TCP_MEM_HIT`，端到端 `apt-get update` **4.3s vs 直连 21.6s（5 倍）**；`never_direct`
fail-closed 实测成立（peer 摘除 1.6ms 快速 503、零静默回源、恢复即 200）。
**go 链路结构性不可用**（双重死锁），**pip 无 peer 可用**（cache-service 无 pypi upstream）。

## 二、核心机制发现（本次实测新增）

### 2.1 ⚠️ CONNECT 在选路阶段就被转发给 peer（修复前后对比；⚠️ 修复版结论已被修订①推翻，见第八节）

| 配置 | https (CONNECT) 行为 | 证据 |
|---|---|---|
| 初版（CONNECT 未排除） | squid 在 CONNECT 阶段做 peer 选路，**把 CONNECT 原样转发给 peer**（期望 peer 是正向代理）；nginx origin 形态不支持 CONNECT → **400** | nginx access.log：`400 - "CONNECT proxy.golang.org:443 HTTP/1.1"` |
| 修复版（`cache_peer_access deny CONNECT` + `never_direct allow <dom> !CONNECT`） | ~~bump 后的明文 GET 重新评估选路 → 仍强制走 peer~~ **实为：bump 后 GET 被 PINNED，跳过全部 peer；never_direct 反而把它拦成必然 503** | 修订① debug 44 实锤 |

**修复落点**：`deploy/chart/templates/configmap.yaml` §4.4（chart 0.1.12）。

### 2.2 ⚠️ nginx peer 接受 absolute-form + 原 Host（http 链路可行性实证）

squid 转发给 peer 的请求行是 `GET http://archive.ubuntu.com/ubuntu/dists/jammy/Release HTTP/1.1`
（**absolute-form，不改 URL**），cache-service debcache 正常处理并回源
repo.huaweicloud.com（nginx 日志 `200 deb_mirror`，`cache_key=/ubuntu/dists/jammy/Release/-`）。
→ M3 方案的核心前提成立：**选路不改 URL，squid 缓存键=原始 URL，与 url_rewrite 的键分裂缺陷绝缘**。

### 2.3 ⚠️ squid pod egress 对 Google IP 阻断（go 死结的根因，存量问题）

| 目的地 | squid pod 直连 | 说明 |
|---|---|---|
| `proxy.golang.org`（142.251.x / 192.178.x，Google） | ✗ TCP 建连 30s 都不通（`connect=0.000000`） | egress 阻断，**部署 cache_peer 之前就存在**（第一轮 vcjob 即 503） |
| `goproxy.cn` | ✓ 200，建连 196ms | 国内可达 |
| `pypi.org` / `files.pythonhosted.org`（Fastly 151.101.x） | ✓ | 第一轮+本轮 vcjob 实证 |

**go 双重死锁**：CONNECT 目的地不可达 → bump/splice 都需要先与 origin 建连 → 必死；
peer 救不了（nginx 不支持 CONNECT）。且本轮 vcjob 里 **direct 组也 000**（上一轮直连 200）
→ 境外 Google IP 随机可达性，国内镜像才是稳定路径。

### 2.4 cache-service 端口归属定案（P0，nginx conf 定案）

| 端口 | upstream | 备注 |
|---|---|---|
| 8081 | **deb** → repo.huaweicloud.com | ✓ 本轮 peer 落地 |
| 8082 | rustup | |
| 8083 | **yum/openEuler**（不是 pypi！） | 此前"8083=pypi"为误判 |
| 8084 | **go** → Nexus goproxy + goproxy.cn fallback（仅 404 触发，502 直透） | P1 实测 `.mod/.info/.zip` 200 + `X-Go-Cache MISS→HIT` |
| 8085 | crates | |

⚠️ **cache-service 没有 pypi upstream**（deployment 名叫 pypi-cache-deployment 但没有 pypi 端口）
→ pip 无 peer 可用，保持 squid 本地缓存。

## 三、分链路判定

### 3.1 ✅ apt（cache_peer 8081）——全链路通过，可上生产

| 项 | 实测 |
|---|---|
| 选路 | access.log `TCP_MISS/200 ... FIRSTUP_PARENT/10.247.137.157`（=cache-service svc IP），**无 HIER_DIRECT 外网 IP** |
| 缓存 | 第 2 次 `TCP_MEM_HIT/200`（0.57ms）；`InRelease/Release/Packages` 元数据 BYPASS（debcache nocache map），deb 包文件走 nginx 3650d 缓存 |
| 端到端 | `apt-get update`：squid 4318ms vs 直连 21588ms（**5 倍**，peer 内网回源 + nginx 层吸收） |
| 重定向 | 全程 200，无 301/421（对照 url_rewrite 时代的失败形态） |
| 客户端 | 零改动（只配 http_proxy/https_proxy 指向 squid） |

### 3.2 ❌ go（cache_peer 8084）——结构性不可用（非配置问题）

- 客户端→squid：CONNECT `proxy.golang.org:443` → squid 直连 Google IP 超时（2.3 egress 阻断）→ 503
- peer 层自身健康（P1：8084 `.mod MISS→HIT`、`.zip` 1.8MB 200）——**peer 没坏，是流量到不了 peer**
- **出路**：① 客户端 `GOPROXY=https://goproxy.cn`（squid 可直连 + bump + refresh_pattern 本地缓存，键不变）；
  ② 运维修 squid pod egress 到 Google；③ 部署支持 CONNECT 的 parent proxy（重量级，不建议）。
  与"客户端保持官方默认"的既有约束冲突 → 需单独决策。

### 3.3 ⚠️ pip——无 peer 可用，squid 本地缓存足够

- pypi.org / files.pythonhosted.org 经 squid 可用：索引 `TCP_MISS → TCP_REFRESH_UNMODIFIED`（304 校验正常），
  wheel/metadata 对象 `TCP_MISS/200`（**wheel 域确认进 squid**，P0 判定③）
- 端到端：with-squid 11746ms → 1044ms（二次快主要来自 pip 自身 HTTP 缓存 + squid 304 校验）
- 若未来要 pypi peer：需给 cache-service 加 pypi upstream（跨团队改动）或新建 peer（单独立项）

### 3.4 ✅ P6 失败语义（never_direct fail-closed 实锤）

- scale cache-service → 0：apt 域请求 **1.6ms / 0.3ms 快速 503**（`TCP_MISS_ABORTED/503 FIRSTUP_PARENT`）
- **关键观察：无 HIER_DIRECT/外网 IP** → 不静默回官方源，fail-closed 语义成立
- 恢复 replicas=1：立即 200（0.99ms）
- 影响面：peer 单点挂 = apt 域全挂（快速失败）；go/pypi 不在 never_direct 范围内不受影响

## 四、端到端对照表（二b，vcjob 2026-09-15）

| task | direct | with-squid | 结论 |
|---|---|---|---|
| apt `update` | 21588ms | **4318ms** | squid+peer 5 倍收益（apt download 单包差异小：1582 vs 3181ms） |
| pip `download requests` | 3622 → 1055ms | 11746 → **1044ms** | squid 首发（回源+写缓存）比直连慢，二次靠 pip 自身缓存 + squid 304 |
| go（curl `.mod`） | **000 ×3**（本轮直连也断） | 503 ×3（CONNECT TIMEDOUT） | proxy.golang.org 双路皆死；goproxy.cn 直连 200 是唯一稳定路径 |

## 五、给架构的结论

1. **apt cache_peer 落地**（chart 0.1.12，values-006 `squid.cachePeer`）：机制安全（URL/键不变）、
   收益实测（5x update）、失败语义可控（fail-closed 快速失败）。
2. **cache_peer 适用边界**：**只适合 http 明文域 + origin 形态 peer**。https 域要享受 peer 必须：
   peer 支持 CONNECT（正向代理形态），或 egress 可达让 bump 后走 peer（但 bump 后 GET 的 peer
   转发已被证明可行——只要 CONNECT 能活下来）。
3. **go**：短期 GOPROXY=goproxy.cn + squid 本地缓存；peer 对 go 的价值只在 egress 修复后成立。
4. **pip**：不纳入 peer，squid 本地缓存即可；pypi peer 需 cache-service 侧加 upstream（另行立项）。
5. **cache-service 是集群级共享单点**：纳入 never_direct 的域越多，故障影响面越大——建议后续给
   cache-service 加副本/多 upstream，或对非关键域用软策略（prefer_direct）替代硬强制。

## 六、证据清单（2026-09-15 实测）

| # | 证据 | 出处 |
|---|---|---|
| 1 | P0 端口归属：nginx conf 8081=deb/8082=rustup/8083=yum/8084=go/8085=crates，无 pypi | `pypi-cache-deployment-86b684b789-8tpg2` conf.d |
| 2 | P1 wire-form：origin-form+原 Host → 8081 deb 200、8084 go `.mod` 200 `X-Go-Cache MISS→HIT`、`.zip` 1.8MB 200 | squid-cache-0 curl 实测 |
| 3 | CONNECT 转发 peer → nginx 400 | nginx log：`400 - "CONNECT proxy.golang.org:443 HTTP/1.1"` |
| 4 | 修复后 apt 走 peer：`TCP_MISS FIRSTUP_PARENT/10.247.137.157` → `TCP_MEM_HIT` 0.57ms | squid-cache-0 access.log |
| 5 | squid pod → proxy.golang.org TCP 不通（30s connect=0.000000）；→ goproxy.cn 200（196ms） | squid-cache-0 curl 实测 |
| 6 | P6 fail-closed：peer 摘除 1.6ms/0.3ms 503（`FIRSTUP_PARENT`，无 HIER_DIRECT），恢复即 200 | access.log + scale 实测 |
| 7 | 端到端：apt update 4318ms(squid) vs 21588ms(direct)；pip 11746→1044ms；go 双路皆死 | 二b vcjob 日志（cachepeer-apt-pip-go-compare[-direct]） |
| 8 | wheel 域进 squid：`files.pythonhosted.org ... TCP_MISS/200`；索引二次 `TCP_REFRESH_UNMODIFIED` | squid-cache-1 access.log |

## 七、遗留 / 待办

1. chart 改动（0.1.12：cachePeer 开关 + CONNECT 排除）未 commit —— 待确认后提交 `cache-peer-sources` 分支
2. go 出路决策（客户端 GOPROXY 换源 vs egress 修复）—— 与"客户端零改动"约束冲突，需拍板
3. cache-service 单点风险 —— 若 apt peer 上生产，建议推动 cache-service 高可用
4. 二b 的 direct 组 apt `update` 21588ms 里含 apt 自身索引重建噪声，单包 download 对比更干净（已在判定表中拆分）

---

## 八、修订①（2026-09-15 晚）：PINNED 实锤——cache_peer 对 https(bump) 流量结构性不可用

> 背景：pypi 透明 peer（8086）落地尝试——cache-service 注入 8086 origin-form server 块
> （/simple→huaweicloud /repository/pypi/simple，404 fallback pypi.org；/packages→pythonhosted；
> `X-Pypi-Cache: MISS/HIT`），svc 暴露 8086，values-006 加 `pypi-peer`（.pypi.org
> .files.pythonhosted.org）。nginx 侧直打 8086 全通（索引/whl 均 MISS→HIT 200），但经 squid 的
> https GET 全部 503 `HIER_NONE`"may not allow direct" → 本轮排查定案。

### 8.1 根因（peer_select debug 44,3 实锤）

squid `ssl_bump bump` 在 CONNECT 阶段必须先连 origin 取真实证书链做仿冒 → 该 server 连接被
**PINNED**；bump 后解密出的 GET 强制复用 pinned 连接，**`selectSomeParent` 虽执行但跳过全部
cache_peer**：

```
44,3| peer_select.cc(609) selectMore: GET pypi.org
44,3| peer_select.cc(1097) addSelection: adding PINNED#pypi.org   ← pinned 直连，peer 无缘
44,3| peer_select.cc(828) selectSomeParent: GET pypi.org          ← 执行了但一个 peer 都没加
44,2| peer_select.cc(1170) handlePath: found pinned, destination #1
```

pinned 连接是 HIER_DIRECT → 被 `never_direct` 拦截 → 无路可走 → 必然 503。
**隔离实验**：同域 HTTP 明文 GET → `FIRSTUP_PARENT` 走 peer 200；同域 https bump GET → 503
（同 ACL、同 peer、同主机）。去除 go/pypi 的 never_direct 后 https 立即恢复 200。

### 8.2 附带发现：`deny CONNECT` 死代码（ACL 首匹配）

`cache_peer_access` 首匹配：`allow <dom>` 写在 `deny CONNECT` 之前 → 域内 CONNECT 仍被允许
发给 peer（debug：CONNECT 候选 #1 = FIRSTUP_PARENT:8086，nginx 400 后才回退直连）。
chart 0.1.13 已改为 `deny CONNECT` 在前。

### 8.3 修复与回退

| 项 | 内容 |
|---|---|
| values-006 | 移除 `go-peer`（https-only，peer 结构性无用）与 `pypi-peer`；仅保留 `apt-peer`（HTTP，peer 有效） |
| chart 0.1.13 | configmap §4.4：`deny CONNECT` 提前 + 注释改为 PINNED 结构性结论；Chart.yaml bump |
| gy-006 部署 | helm upgrade 0.1.13 + rollout，验证：pypi 索引 MISS(1.18s)→MEM_HIT(0.35s)；真实 wheel MISS(0.76s)→HIT(0.35s) 200；apt `TCP_MISS FIRSTUP_PARENT`（peer 存活，ACL 顺序修复无回归） |
| 排查期临时手段 | 线上 CM 曾直改（nonhierarchical_direct off 实验 + 删 never_direct + debug 44,3），已随 0.1.13 部署被 helm 覆盖，无残留（grep 计 0） |

### 8.4 修订后的架构结论

1. **cache_peer 适用边界收紧为：明文 HTTP 域 + origin 形态 peer**（第五节第 2 条中
   "bump 后 GET 的 peer 转发已被证明可行"**作废**）。https 域要过 peer，唯一形态是
   CONNECT-capable 的正向代理 peer（peer 自己 bump 才能缓存，如 rpardini 模式）。
2. **never_direct 只许配给明文 HTTP 域**：配给 https-only 域 = 必然 503（拦掉 pinned 直连）。
3. **pypi/nginx 层缓存的可行路径**：客户端 `PIP_INDEX_URL` 指向 cache-service 80 端口
   `/pypi/simple` 前缀（gy-001 模式，需客户端改动）；或未来二级 bump 代理（重量级）。
   8086 origin-form 端口保留（配置无损，留作 CONNECT-capable 前置接入点）。
4. 本轮 go 503 为 **egress 对 Google IP 间歇性阻断**（2.3 存量问题，直连同样 000），
   与 peer/503 修复无关；egress 恢复后 go 走 bump + squid 本地缓存（20% TTL）。
5. 教训：P3/P5 的"go/pip peer 可行"判定当时只由 HTTP/降级路径支撑，https bump 路径未经
   peer_select debug 验证——**结构性结论必须拿 debug 44 级证据**。
