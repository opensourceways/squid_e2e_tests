# gh-proxy 全面测试工作流（TEST-WORKFLOW）

> 目标：用证据把 gh-proxy 的**行为边界**完整测出来，回答 JUDGEMENT.md「六、待验证盲区」。
> 测试原则：每步都出**机器可读证据**（退出码 / HTTP 码 / Location / access.log 行），
> 复现现有缺陷（301 翻倍），并确认正确用法（insteadOf + squid 本地缓存）。
> 配套证据脚本：`gh-proxy/direct-ghproxy-only.yaml`、`gh-proxy/resolve-ip-test.yaml`
> （已跑，结果入 JUDGEMENT.md）。
>
> **2026-09-08 修订**（review 意见）：① P1 全部改集群内执行（内部域本机解析不到）；
> ② P2 增加"默认 DNS 自然命中率"采样 + 按 P1 结果分叉；③ P3 冷测换从未请求过的 URL；
> ④ P4 补 Accept-Encoding 对照、修注释；⑤ **P5 重写**——`--resolve` 会绕过 squid，
> 无法制造 squid 缓存条目，改为"先复盘已有日志 + 经 squid 发请求"；⑥ 补 P7（盲区 6）；
> ⑦ P6 修正二次 clone 的缓存归因。
>
> **执行状态（2026-09-08 全量跑完）**：P1 ✅（单后端定论，P2 走分支 B、P7 跳过）、
> P2 ✅、P3 ✅、P4 ✅、P5 ✅、P6 ✅、P7 ⏭（P1 证实单后端，条件不成立）。
> 结果已汇总入 JUDGEMENT.md 修订②/③ + 证据清单 #12-#17。

---

## 总览：测试矩阵

| Phase | 测什么 | 回答盲区 | 产物 |
|---|---|---|---|
| P1 | DNS/IP 全量枚举 + 证书归属甄别 | 盲区 1（.166 是谁的 IP）| `ip-list.txt` + 每 IP 证书 subject |
| P2 | 301 复现：强制 IP + 默认 DNS 自然命中率 | 盲区 2（恒定 vs 偶发）| 行为分布表 |
| P3 | 服务端缓存语义（冷测换 URL）| 盲区 3（TTL/304/大小/301 缓存）| 响应头证据 |
| P4 | 大文件并发 + Accept-Encoding | 盲区 4（压缩/带宽）| 耗时 + size 分布 |
| P5 | squid 侧 301 缓存污染（先复盘已有日志）| 盲区 5（坏 301 被缓存？）| access.log 行 |
| P6 | 客户端 insteadOf 全链路回归 | 综合（正确用法）| git/wget 结果 |
| P7 | 多后端是否共享服务端缓存（**条件执行**）| 盲区 6 | 交叉命中证据 |

---

## Phase 1：DNS / IP 全量枚举 + 证书归属（盲区 1）

**目的**：拿到 `gh-proxy.test.osinfra.cn` 的**全部**解析 IP，用 TLS 证书甄别 `.166` 到底是谁的 IP。

> ⚠️ 内部测试域，**本机（开发机）DNS 大概率解析不到**，全部步骤在集群内执行
> （临时 pod 或 squid pod；squid 自建镜像自带 curl）。本机解析仅作对照（可选）。

### 步骤（集群内）

```sh
# 1) 集群内多轮解析（DNS 轮询可能每次只回 1-2 个），推荐临时 pod 或 squid pod
kubectl exec -n squid <squid-pod> -c squid -- sh -c \
  'for i in $(seq 1 20); do getent ahosts gh-proxy.test.osinfra.cn; sleep 0.2; done' \
  | awk '{print $1}' | sort -u > ip-list.txt
cat ip-list.txt
```

```sh
# 2) 交叉验证：换一个 pod / 另一节点再跑一次，排除本地 DNS 缓存差异
kubectl run dns-check --rm -i --image=<probe-image> -n squid --restart=Never -- \
  sh -c 'for i in $(seq 1 10); do getent ahosts gh-proxy.test.osinfra.cn; sleep 0.3; done'
```

```sh
# 3) 每 IP 的 TLS 证书归属（判断 .166 是 gh-proxy 后端还是 GitHub 边缘）
for ip in $(cat ip-list.txt); do
  echo "== $ip =="
  timeout 5 bash -c "echo | openssl s_client -connect $ip:443 -servername gh-proxy.test.osinfra.cn 2>/dev/null | grep -E 'subject=|issuer='"
done
```

### 判定（决定性结论表）

| ip-list 结果 | 证书 subject | 结论 |
|---|---|---|
| 只有 `202.170.93.254` | gh-proxy 自家证书 | **单后端**，"多后端"假设排除；`access.log` 的 .166 行 = 重定向链第二跳（GitHub）|
| 含 `.166` | `*.github.com` | `.166` 是 GitHub 边缘；`--resolve` 测试 = 把 gh-proxy Host 发给 GitHub，301 翻倍是 GitHub 对垃圾路径的响应 |
| 含 `.166` | gh-proxy 自家证书 | **多后端属实**，`.166` 是坏后端，成因 B 成立 |

> 证书甄别是**本 Phase 的核心产出**——它决定 P2 走哪个分支、以及 JUDGEMENT 3.3 的最终定论。

---

## Phase 2：301 复现 + 频率（盲区 2）

**目的**：确定 301 翻倍是恒定还是偶发、默认 DNS 下的自然命中率。
**前置**：P1 的结论决定本 Phase 的分支。

### 分支 A（P1 证实 .166 ∈ gh-proxy 解析）：强制 IP 逐测

```sh
for ip in $(cat ip-list.txt); do
  echo "===== IP=$ip ====="
  for i in $(seq 1 10); do
    curl -s -o /dev/null -w "  #$i code=%{http_code} loc=%{redirect_url} time=%{time_total}s\n" \
      --max-redirs 0 -k --resolve gh-proxy.test.osinfra.cn:443:$ip \
      "https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
  done
done
```

### 分支 B（P1 证实 .166 ∉ gh-proxy，即单后端）：放弃强制 IP，改为复盘 + 自然采样

```sh
# 1) 复盘 access.log：把 301 翻倍那行的完整记录拿出来，
#    确认它是"gh-proxy 回源行"还是"跟随 Location 后的 github.com 行"（两行的 host 不同！）
kubectl exec -n squid <squid-pod> -c squid -- \
  grep -E "301|302" /var/log/squid/access.log | grep -iE "grpc|gh-proxy|github" | tail -20
```

```sh
# 2) 默认 DNS 自然采样 50 次（不强制 IP，模拟生产真实命中面）
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "#$i code=%{http_code} loc=%{redirect_url} time=%{time_total}s\n" \
    --max-redirs 0 -k "https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
  sleep 0.5
done
```

### 判定

- 分支 A：每 IP 10 次的 code/loc 分布 → 恒定 301 / 恒定 200 / 混合。
- 分支 B：
  - access.log 301 行的 **host 字段** → 判断 301 是 gh-proxy 发的还是 github.com 发的。
  - 50 次采样中 301 出现次数 / 50 → 自然命中率；并记录"首次 301 → 重试 200"序列是否稳定
    （服务端缓存吸收了首次抓取，还是坏条目被反复命中）。

---

## Phase 3：服务端缓存语义（盲区 3）

**目的**：gh-proxy 缓存是"URL → 内容"的简单 KV？TTL 多少？会缓存 301/404 吗？

> ⚠️ 冷测前提：grpc v1.60.0.zip 在上一轮**已被 gh-proxy 缓存**，不能当冷测样本。
> 换一个**从未请求过**的 repo/tag（越冷门越好，避免缓存污染判断）。

### 步骤

```sh
# 1) 冷测：从未请求过的 URL，首 GET vs 立即重试 vs 间隔重试，对比响应头
U="https://gh-proxy.test.osinfra.cn/https://github.com/<repo>/<repo>/archive/refs/tags/<从未用过的tag>.zip"
for i in 1 2 3; do
  echo "== pass$i =="
  curl -s -k --max-redirs 0 -o /dev/null -D - "$U" \
    | grep -iE "^(HTTP|content-length|age|x-|cache-control|etag|last-modified|date)"
  sleep 1
done
```

```sh
# 2) 是否存在类似 X-Cache / Age 的缓存标记头？
curl -sv -k --max-redirs 0 "$U" -o /dev/null 2>&1 | grep -iE "^< (age|x-cache|x-gh|via|server|date)"
```

```sh
# 3) 对照：GitHub 官方 archive 端点现在是否仍 302（确认 gh-proxy 跟随的对象）
curl -s -o /dev/null -w 'github archive: code=%{http_code} loc=%{redirect_url}\n' \
  --max-redirs 0 -k "https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
```

```sh
# 4) 大小上限粗测：850KB / 139MB / 中间值，各自"首发 vs 次发"耗时差
```

### 判定

- 二次请求是否出现 `Age`/`X-Cache` 头 → 缓存机制可观测性。
- `cache-control` 是否为 `public,max-age=...` → TTL 可推断。
- 冷 URL 首发 301/404 后**立即重试**是否 200 → 确认 3xx/4xx 是否被缓存（坏条目风险）。

---

## Phase 4：大文件并发 + Accept-Encoding（盲区 4）

**目的**：确认大文件并发在 gh-proxy 直连下的真实瓶颈形态、squid 本地缓存如何吸收、
以及 zip 是否被压缩透传。

### 步骤

```sh
# 直连 gh-proxy（C）：obs 139MB × 15 并发一次性（同 SOURCE-REWRITE-ANALYSIS 并发方法）
U="https://gh-proxy.test.osinfra.cn/https://github.com/huaweicloud/huaweicloud-sdk-c-obs/archive/refs/tags/v3.23.9.zip"
for i in $(seq 1 15); do
  ( curl -s -o /dev/null -w "C#$i code=%{http_code} size=%{size_download} time=%{time_total}s\n" \
      --max-time 300 -k "$U" ) &
done; wait
```

```sh
# 走 squid（D，缓存热后）：同 URL 同样并发，对比 access.log 出现 TCP_REFRESH_UNMODIFIED
curl -s -o /dev/null -w "D#warm code=%{http_code} time=%{time_total}s\n" -x $PROXY "$U"
for i in $(seq 1 15); do
  ( curl -s -o /dev/null -w "D#$i code=%{http_code} time=%{time_total}s\n" \
      --max-time 300 -x $PROXY "$U" ) &
done; wait
```

```sh
# Accept-Encoding 对照：zip 是否被压缩/透传（size 一致 = 直接透传）
curl -s -o /dev/null -w 'gzip:   code=%{http_code} size=%{size_download} time=%{time_total}s\n' \
  -H "Accept-Encoding: gzip" -k "$U"
curl -s -o /dev/null -w 'plain:  code=%{http_code} size=%{size_download} time=%{time_total}s\n' \
  -H "Accept-Encoding: identity" -k "$U"
```

### 判定

- C 场景：`time` 分布是否长尾（首次 100s+，次发快）→ gh-proxy 服务端抓大文件受上游限速。
- D 场景：15 并发全部 `TCP_REFRESH_UNMODIFIED` 且 1-5s → squid 本地副本生效。
- D 首波出现 `TCP_MISS` 且耗时 = gh-proxy 抓取时长 → 大文件缓存**击穿**（首个请求拖慢所有人）。
- gzip vs plain 的 `size_download` 差异 → 压缩/透传行为；顺带核对是否带 `Content-Encoding: gzip`。

---

## Phase 5：squid 侧 301 缓存污染检查（盲区 5）

**目的**：301 翻倍响应会不会被 squid 缓存为坏条目，进而污染其它客户端。

> ⚠️ 上一轮事故中**已观察到 squid 缓存了 301**（曾用 squidclient 清除）——**证据可能已经存在**，
> 先复盘，再决定是否需要新实验。
> ⚠️ 关键修正：`curl --resolve ...:IP` 是**直连该 IP、完全绕过 squid**，squid 看不到这个请求，
> **不会产生任何 squid 缓存条目**——不能用来制造"squid 缓存 301"。

### 步骤（先复盘，后新实验）

```sh
# 1) 复盘上一轮日志：该 URL 在 squid 里的全部记录，看缓存状态
kubectl exec -n squid <squid-pod> -c squid -- \
  grep "gh-proxy" /var/log/squid/access.log | grep -iE "grpc|301|302" | tail -20
```

```sh
# 2) 新实验（必须经 squid）：用代理 env 请求，若命中坏 301，再查 squid 缓存状态
curl -s -o /dev/null --max-redirs 0 -x $PROXY \
  "https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
kubectl exec -n squid <squid-pod> -c squid -- \
  grep "gh-proxy" /var/log/squid/access.log | grep -iE "grpc|301" | tail -5
```

```sh
# 3) 正常路径再请求同一 URL，确认是否被坏 301 影响
curl -s -o /dev/null -w 'code=%{http_code} loc=%{redirect_url}\n' --max-redirs 0 -x $PROXY \
  "https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
```

### 判定

- access.log 是否出现 `TCP_MISS/301` 或 `TCP_HIT/301` → 301 是否被 squid 缓存。
- 步骤 3 是否仍 200 → 坏 301 是否污染了同 URL 的正常请求。
- 若被污染：`squidclient -h 127.0.0.1 -p 3128 purge <URL>` 清除 + 核对 `refresh_pattern`
  对 3xx 的处理（Squid 默认不缓存 3xx，需确认当前配置为何缓存了）。

---

## Phase 6：客户端 insteadOf 全链路（综合验证正确用法）

**目的**：确认**推荐用法**（insteadOf → gh-proxy 直连 + squid 本地缓存）在 git/wget 双场景稳定。

### 步骤

```sh
# git insteadOf（走 squid，等价 02 用例 D）
git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"
time git clone --depth=1 https://github.com/pybind/pybind11.git /tmp/pybind11
time git clone --depth=1 https://github.com/pybind/pybind11.git /tmp/pybind11-2
# 清理（避免污染后续 job）
git config --global --unset-all url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf
```

```sh
# wget 手动换源（走 squid）
time wget -q -O /dev/null "https://gh-proxy.test.osinfra.cn/https://github.com/pybind/pybind11/archive/refs/tags/v2.10.3.zip"
time wget -q -O /dev/null "https://gh-proxy.test.osinfra.cn/https://github.com/pybind/pybind11/archive/refs/tags/v2.10.3.zip"
```

```sh
# 对照：codeload 直链走 squid（不应换源；缓存预热后应 TCP_HIT 秒回）
time wget -q -O /dev/null "https://codeload.github.com/pybind/pybind11/zip/refs/tags/v2.10.3"
time wget -q -O /dev/null "https://codeload.github.com/pybind/pybind11/zip/refs/tags/v2.10.3"
```

### 判定

- git clone ×2、wget ×2 全部 exit 0。
- access.log：gh-proxy URL `TCP_MISS/200 → TCP_REFRESH_UNMODIFIED/200`；codeload **预热后** `TCP_HIT/200`。
- 归因注意：git 二次 clone 变快的 `/info/refs` 来自 **squid 侧 `TCP_REFRESH_MODIFIED`（304 校验）**，
  POST `/git-upload-pack` 协议级不可缓存——**不是 gh-proxy 服务端缓存**。
- codeload 判定需**先预热**（首发必 MISS），预热后第二发才是 HIT。

---

## Phase 7：多后端是否共享服务端缓存（盲区 6，条件执行）

**前置**：**仅当 P1 证实 gh-proxy 有 >1 个后端 IP** 才执行；若单后端，盲区 6 不成立，直接标记跳过。

**目的**：坏后端翻倍后重试 200，到底是谁提供的内容——各后端共享一份缓存，还是各自独立？

### 步骤

```sh
# 用 P1 的 ip-list：URL 经后端 A 首发（记录耗时/内容），再经后端 B 请求同一 URL
U="https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
for ip in $(cat ip-list.txt); do
  echo "== 后端 $ip =="
  curl -s -o /dev/null -w '  #1 code=%{http_code} size=%{size_download} time=%{time_total}s\n' \
    --max-redirs 0 -k --resolve gh-proxy.test.osinfra.cn:443:$ip "$U"
  curl -s -o /dev/null -w '  #2 code=%{http_code} size=%{size_download} time=%{time_total}s\n' \
    --max-redirs 0 -k --resolve gh-proxy.test.osinfra.cn:443:$ip "$U"
done
```

### 判定

- 后端 B 首次请求秒回（等于后端 A 的次发耗时）→ **共享缓存**。
- 后端 B 首次请求慢（= 重新抓取）→ **缓存各自独立**，坏后端翻倍后的"重试 200"只存在于它自己那份缓存。
- ⚠️ 本 Phase 测的是 **gh-proxy 自身后端间**的缓存共享，`--resolve` 绕过 squid 是**正确用法**
  （squid 只在客户端层，与后端共享无关）。

---

## 执行顺序与依赖

```
P1（IP 清单 + 证书归属）
 ├─> 分支 A（多后端属实）→ P2 强制 IP ─> P5
 ├─> 分支 B（单后端）   → P2 复盘+自然采样 ─> P5
 └─> P7（条件：仅分支 A）
P3（缓存语义，独立）
P4（并发，依赖 P3 的响应头知识做观测）
P6（正确用法回归，最后跑）
```

**建议载体**：每个 Phase 一个 Volcano Job（参考 `redirect/test/02-github-archive-git-vcjob.yaml`
的 vcjob 写法），日志落 `squid` 命名空间；access.log 用 `kubectl exec -n squid <pod> -c squid -- grep` 抓取。
规模小的 Phase（1/3）也可直接 exec 进 squid pod 跑（同 `redirect/test/run-probe.sh` 方式）。

---

## 输出模板（汇总到 JUDGEMENT.md「证据清单」）

| Phase | 关键证据 | 结论/对盲区 |
|---|---|---|
| P1 | IP 清单 + 每 IP 证书 subject | 盲区 1（决定性）✅ 单后端 |
| P2 | 每 IP code/loc 分布 / 自然采样 50 次 | 盲区 2 ✅ 偶发 DNS 异常 |
| P3 | 冷 URL 的缓存头/TTL/301 是否缓存 | 盲区 3 ✅ 无标记头/不响应304/404短缓存 |
| P4 | 并发耗时 + gzip/plain size | 盲区 4 ✅ gzip 击穿缓存 |
| P5 | access.log 301 缓存行（复盘 + 新实验）| 盲区 5 ✅ TCP_HIT/301=0 |
| P6 | git/wget 全链路结果 | 正确用法确认 ✅ |
| P7 | 后端交叉命中耗时（条件执行）| 盲区 6 ⏭ 单后端跳过 |
