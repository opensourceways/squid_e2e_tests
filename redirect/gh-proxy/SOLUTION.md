# gh-proxy 解决方案（SOLUTION）

> 基于 TEST-WORKFLOW P1-P6 全量实证（2026-09-08），结论出处见 [JUDGEMENT.md](JUDGEMENT.md)。
> 本文只给"怎么做"：每个方案带配置片段、适用场景、验证方法与回退路径。
>
> **2026-09-08 修订⑥（根因推翻修订②，重写方向回退）**：实测证明 ssl-bump 下 https 重写
> **结构性不可用**——CONNECT 阶段按原域名建连（github.com→.166 为正常解析），bump 后 helper
> 重写 URL，但 squid **复用已建连接、不按新 host 重建** → 请求发往错误 IP → 301 翻倍/421
> 死循环；**pin DNS 无效**。→ **统一重写 github.com→gh-proxy（原 A1）与 pin DNS（原 A2）废弃**；
> **首选改为客户端 insteadOf 换源（方案 D）**；helper 仅保留 http 明文重写（archive/ports/
> openeuler 的 http 形态实测 200）。
>
> 历史：修订②（用户决定：简洁优先）曾把首选定为统一重写 + pin DNS，原 archive→codeload 降为
> 备选；该决定基于"DNS 污染"误判，已被修订⑥推翻。
>
> 核心事实（一句话）：gh-proxy 单后端可用（20/20）；经 Squid 重写 https 进 gh-proxy 的 301 翻倍
> 死循环根因 = **ssl-bump 连接复用（非 DNS）**，结构性不可用 → 用**客户端 insteadOf 直连**；
> codeload/objects/release-assets 子域 gh-proxy 一律 403（存储层，签名 URL 不可缓存）。

---

## 问题全景

| # | 现象 | 根因（已实证） | 处置 |
|---|---|---|---|
| P1 | helper 重写 https（github→gh-proxy 等）→ 301 翻倍死循环 / 421 | **ssl-bump CONNECT + url_rewrite 连接复用**（修订⑥）：CONNECT 按原域名建连（github→.166 正常），bump 后重写、连接不重建 → 请求发往错误 IP | **结构性不可用**：弃用 https 重写，改用客户端 insteadOf（方案 D）|
| P2 | gzip 请求击穿 squid 缓存（17.9s vs plain 0.79s）| `Vary: Accept-Encoding` 导致缓存键分裂 | 统一客户端 Accept-Encoding（方案 E）|
| P3 | codeload 经 gh-proxy 换源 403 | gh-proxy 白名单拒绝存储层（签名 URL 不可缓存）| 设计如此：codeload 不换源，走官方直连 + 长缓存 |

---

## 解决方案矩阵

| 方案 | 解决什么 | 改动面 | 优先级 |
|---|---|---|---|
| [A1](#方案-a已废弃统一重写-githubcom--gh-proxy--pin-dns) | 全部 github.com 流量（archive/releases/clone/raw）统一走 gh-proxy | Squid configmap helper（1 行）| **废弃（修订⑥：ssl-bump 下 https 重写结构性不可用）** |
| [A2](#方案-a2必须配套-pin-gh-proxy-dns-解析) | P1 原根因（DNS 污染 → 301 翻倍）| Squid configmap + ConfigMap 挂载 | **废弃（修订⑥：非 DNS 问题，pin 无效）** |
| [B](#方案-b备选archive--codeload-确定性映射) | archive 走 codeload（gh-proxy 不可用时）| Squid configmap helper | 备选（⚠️ https 形态同受连接复用限制，仅 http 语义可用）|
| [C](#方案-c大文件并发靠-squid-本地缓存) | 大文件并发下载抗瓜分 | Squid 已有能力，确认配置即可 | 维持 |
| [D](#方案-d首选客户端-insteadof--gh-proxy-直连) | 客户端直连 gh-proxy 换源（不经 squid 重写）| CI 配方（客户端侧）| **首选（修订⑥）** |
| [E](#方案-e统一客户端-accept-encoding) | P2（缓存键分裂）| CI 配方（客户端侧）| 建议 |

---

## 方案 A（已废弃）：统一重写 github.com → gh-proxy + pin DNS

> ⚠️ **修订⑥ 废弃**：实测证明 ssl-bump 下该 https 重写**结构性不可用**（连接复用，301 翻倍，
> pin DNS 无效，见 JUDGEMENT 3.3）——本方案**不再采用**，保留仅为历史留档。改用
> **方案 D（客户端 insteadOf）**；helper 只保留 http 明文重写分支。

**思路**（历史留档）：helper 只写**一行**规则——所有 `https://github.com/*` 重写到 gh-proxy 前缀。
gh-proxy 白名单放行 github.com 主域，**302 链（archive→codeload、releases→release-assets）由
gh-proxy 服务端消化**，客户端拿到的永远是 `gh-proxy/.../github.com/...` 确定性 URL →
squid 可长缓存。**squid 侧只解析 gh-proxy 一个域名，其余子域全不用管。**

架构等价于"客户端 insteadOf 的全局服务端版"——所有客户端（wget/curl/git/bazel）自动生效，
无需逐台配置。

### A1. helper 修改（deploy/chart/templates/configmap.yaml mirror-rewrite.sh）

```sh
# GitHub 全部流量统一 → gh-proxy（白名单放行 github.com 主域；302 链由 gh-proxy 服务端消化）。
# 参考 JUDGEMENT.md 3.5：raw 子域也放行；codeload/objects/release-assets 被拒（存储层签名 URL）。
https://github.com/*)
  echo "OK rewrite-url=\"https://gh-proxy.test.osinfra.cn/$url\""
  ;;
```

- **只匹配 `github.com` 一个 host**——`raw.githubusercontent.com`（bazel `--registry`）、
  `codeload.github.com` 等子域**不匹配**，走 `ERR` 原样回源，行为不变。
- **必须配套 A2（pin DNS）**，否则 squid DNS 间歇落到 `.166` 时仍会 301 翻倍死循环。

### A2. 必须配套：pin gh-proxy DNS 解析

> ⚠️ **修订⑥ 废弃**：pin DNS 不是 301 翻倍的解药（根因是 ssl-bump 连接复用，非 DNS）——
> A2 随 A1 一并废弃。以下保留仅为历史留档。

**必要性**（原论断，已失效）：A1 把全部 github 流量压到 gh-proxy 一个域 → 它的解析稳定性就是全部流量的稳定性。
P1 根因（squid DNS 间歇解析 gh-proxy 落到 GitHub 边缘 `.166`）**必须根治**——不是可选加固，是 A1 的前置。

**实施（ConfigMap 挂载 + hosts_file，不改容器 /etc/hosts）**：

```yaml
# 1) squid-static-hosts ConfigMap 增加：
apiVersion: v1
kind: ConfigMap
metadata:
  name: squid-static-hosts
data:
  static-hosts: |
    202.170.93.254 gh-proxy.test.osinfra.cn
```

```yaml
# 2) StatefulSet 挂载（deploy/chart/templates/statefulset.yaml 相应位置）
volumeMounts:
- name: squid-static-hosts
  mountPath: /etc/squid/static-hosts
  subPath: static-hosts
  readOnly: true
volumes:
- name: squid-static-hosts
  configMap:
    name: squid-static-hosts
```

```conf
# 3) squid.conf 增加（ConfigMap data.squid.conf）
hosts_file /etc/squid/static-hosts
```

**为什么这么写（实证/文档依据）**：
- squid `hosts_file` 默认就是 `/etc/hosts`，显式指定后**只读该文件**（Squid 官方文档）；
  但 `/etc/hosts` 里的条目全是 kubelet 注入的 localhost/Pod 记录，**squid 一个都用不到**
  （生产 cache_peer 是 `127.0.0.1` IP、ACL 全 IP、无域名 localhost 引用）→ 替换零损失。
- 容器内 `/etc/hosts` 由 kubelet 管理，手动加行会在 Pod 重建时被覆盖 → 必须 ConfigMap 挂载。
- hosts_file 条目**优先级高于 DNS**（ipcache 静态条目不过期）→ 根治 DNS 污染窗口。
- cache_peer 解析与普通请求共用 ipcache → 同一 static-hosts 同时生效，行为一致。

### 验证（A1+A2 合一）

```sh
# 1) helper 逻辑单测（喂一行，看输出）
echo 'https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip 1.2.3.4/- -' | /usr/local/bin/mirror-rewrite.sh
# 期望: OK rewrite-url="https://gh-proxy.test.osinfra.cn/https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"

# 2) 走 squid 后：重写进 gh-proxy + 命中静态解析（无 301 翻倍）
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' --max-redirs 0 -x $PROXY \
  "https://github.com/grpc/grpc/archive/refs/tags/v1.60.0.zip"
kubectl exec -n squid <pod> -c squid -- \
  grep gh-proxy /var/log/squid/access.log | tail -3
# 期望: 全部 HIER_DIRECT/202.170.93.254（pin 生效），不再出现 .166；无 301 翻倍链

# 3) 回归：clone 与 releases（统一兜底后全走 gh-proxy）
git clone --depth=1 https://github.com/pybind/pybind11.git /tmp/pybind11
```

### 风险与回退

- **风险 1（单点）**：gh-proxy 是 `test` 域且单后端——挂了则全部 github 流量不可达。
  → 监控 gh-proxy（domaintest 已有 20/20 观察手段）；不可用时切换方案 B（archive→codeload）。
- **风险 2（IP 变更）**：pin 后若 `202.170.93.254` 变更（换后端/LB），squid 仍连旧 IP → 全断。
  → 文档标注"变更时必须同步更新 static-hosts"。
- **回退**：删除 `hosts_file` 行 + 卸载挂载，回到 DNS 解析；helper 改回方案 B 或原配置。

---

## 方案 B（备选）：archive → codeload 确定性映射

> ⚠️ **修订⑥**：本方案重写的是 `https://github.com/.../archive/...` → codeload **https** URL，
> 同样受 ssl-bump 连接复用限制（github.com CONNECT 已定死 `.166`，重写无效）——**https 形态不可用**；
> archive 正确姿势 = **客户端直接写 codeload URL**（确定性、无 302、命中长缓存，不依赖 gh-proxy）。

**启用条件**：gh-proxy 不可用 / 需 archive 走最优缓存路径时。
**思路**：helper 对 `github.com/*/archive/*` 重写到 codeload 最终 URL——跳 302 + 命中 codeload 长缓存
（`refresh_pattern` 已配 `10080 100% 525600`，实测 TCP_HIT 0.21s）；其余 github.com 仍走 gh-proxy 兜底。

```sh
https://github.com/*/archive/*)
  url="${url#https://github.com/}"            # <owner>/<repo>/archive/refs/<ref>.zip
  owner_repo="${url%%/archive/*}"             # <owner>/<repo>
  ref="${url#*archive/}"                      # refs/<type>/<name>.zip
  echo "OK rewrite-url=\"https://codeload.github.com/${owner_repo}/zip/${ref}\""
  ;;
https://github.com/*)
  echo "OK rewrite-url=\"https://gh-proxy.test.osinfra.cn/$url\""
  ;;
```

**修订⑥ 结论**：A 与 B 的 https 重写形态均已废弃；archive 走 **客户端直接 codeload URL**
（`https://codeload.github.com/<owner>/<repo>/zip/refs/<type>/<name>`）——确定性、无 302、
命中 `refresh_pattern` 长缓存（实测 TCP_HIT 0.21s），不依赖 gh-proxy。

> ⚠️ 实现要点（若启用）：
> 1. **确定性**：同一 URL 永远映射同一 codeload URL（勿轮询/多目标），否则缓存键分裂（S6 教训）。
> 2. `acl rewritable` 已含 `.codeload.github.com` 与 `.github.com`，无需改 ACL。
> 3. helper 输入是整行 `URL client_ip/fqdn method ...`，必须 `while read -r url _`（已修，见 JUDGEMENT 候选成因 A）。

---

## 方案 C：大文件并发靠 squid 本地缓存

**场景**：obs 139MB 这类大文件，多个 CI 任务同时下载。

**结论（P4 实证）**：gh-proxy 直连 15 并发 8-267s（上游带宽被瓜分）；走 squid（缓存热后）15 并发
全 `TCP_REFRESH_UNMODIFIED/200`，0.99-4.6s。

**配置**：现有 refresh_pattern 已覆盖（codeload/archive 长缓存），无需改动。唯一要求：
**让缓存先热**（第一个请求先经 squid 完成一次全量拉取，后续并发命中）。

**验证**：
```sh
kubectl exec -n squid <pod> -c squid -- \
  grep -E "TCP_HIT|TCP_REFRESH_UNMODIFIED" /var/log/squid/access.log | tail
```

---

## 方案 D（首选）：客户端 insteadOf → gh-proxy 直连

**场景**：客户端级换源（git/wget 手动拼 gh-proxy 前缀，不经 squid 重写）。**修订⑥ 后为唯一首选**
（https 重写结构性不可用，A/B 均废弃）。

### git（CI 配方注入）

```sh
git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com/".insteadOf "https://github.com/"
```

实证：git clone ×2 rc=0，1745ms / 1623ms（JUDGEMENT 3.7）。

### wget / curl（URL 手动拼前缀）

```
https://gh-proxy.test.osinfra.cn/https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.zip
```

### 边界

- **只用于 github.com 域**；codeload 经 gh-proxy 一律 403，不要拼。
- 大文件（>100MB）首次拉取很慢（gh-proxy 上游限速），务必让 squid 缓存热后再并发（方案 C）。
- **与方案 A/B 的关系（修订⑥）**：A/B 的 https 重写形态已废弃（结构性不可用）——**D 是首选**，
  不再是"备用通道"；helper 仅保留 http 明文重写分支，与 D 不冲突。

---

## 方案 E：统一客户端 Accept-Encoding

**场景**：P2 实证——squid 对 gh-proxy 域返回 `Vary: Accept-Encoding`，gzip 与 identity 是不同
缓存键，gzip 请求击穿缓存（重新回源 17.9s vs plain 0.79s）。

**处置**：CI 配方统一 curl/wget 的 Accept-Encoding（如统一 `-H "Accept-Encoding: identity"`，
zip/whl 等已压缩内容不受影响），避免同一 URL 双缓存键。

**替代**：squid 侧 `reply_header_replace Vary Accept-Encoding`（现有 configmap 已对全局生效，
见 L94）——该行只消除 `Vary: Origin`，不消除 `Vary: Accept-Encoding` 的键分裂，**不能替代**方案 E。

---

## 执行顺序建议

```
1. 方案 D（客户端 insteadOf → gh-proxy）注入 CI 配方      [首选，修订⑥]
2. 方案 E（CI 配方统一 Accept-Encoding）                  [规范客户端用法]
3. 方案 C 确认（大文件缓存预热流程）                      [维持现状]
4. helper 清理：移除 https 重写分支，仅保留 http 明文重写 [修订⑥]
5. archive 备选：客户端直接写 codeload URL（无重写）       [备选]
```

## 遗留跟踪

- [ ] 方案 D 落地：insteadOf 配方注入各 CI 任务（git/wget），验证全链路（参考 redirect/test/02 task3）
- [ ] helper 清理：移除 https 重写分支（github/pypi/archive-https/ports-https/openeuler-https），仅留 http 明文
- [ ] archive 客户端直链 codeload 回归（确定性 URL，无 302，命中长缓存）
- [ ] 监控 gh-proxy 可用性（domaintest 20/20 手段），故障时评估 fallback
