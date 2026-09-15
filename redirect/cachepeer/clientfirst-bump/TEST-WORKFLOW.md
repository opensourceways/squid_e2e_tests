# client-first bump 实验（方案A）——TEST-WORKFLOW

> 目标：把 ssl_bump 从 server-first（peek→bump，先连 origin 仿冒证书 → GET 被 PINNED →
> cache_peer 对 https 结构性不可用，见 `cachepeer/JUDGEMENT.md` 修订①）切换为
> **client-first（step1 直接 bump）**，解密 GET 走完整 peer_select，让 pypi/go 的
> cache_peer + never_direct 复活，nginx 层缓存真正介入。
> 前置结论：cachepeer/JUDGEMENT.md §8（PINNED 实锤）、§8.4（架构修订）。

---

## 一、机制对比

| | server-first（现状 0.1.13） | client-first（本实验） |
|---|---|---|
| CONNECT 阶段 | peek SNI → 连 origin 取证书仿冒 → 与客户端握手 | step1 即定 splice/bump，**不连 origin** |
| 假证书 | 仿冒 origin subject/SAN | sslcrtd 按 CONNECT 主机名签发（CN/SAN=主机名） |
| bump 后 GET | PINNED 到 origin 连接，跳过全部 peer | 普通代理请求，走完整 peer_select |
| registry 判定 | `ssl::server_name`（SNI，step2） | `dstdomain`（CONNECT authority，step1） |
| peer 转发形态 | （不可用） | 需 `originserver`：squid 默认发 absolute-form（`GET https://pypi.org/...`），nginx 不接受且 `$request_uri` 被污染 → 强制 origin-form（`GET /simple/...` + `Host: pypi.org`） |

## 二、改动清单（chart 0.1.14）

1. `configmap.yaml`：
   - SSL Bump 段：删 `acl step1`/`peek step1`，registry ACL 由 `ssl::server_name` 改 `dstdomain`，
     规则改为 `ssl_bump splice registry` + `ssl_bump bump all`（均在 step1 生效）
   - §4.4 cache_peer 模板：加 `originserver`；注释重写（PINNED 约束已被 client-first 化解）
2. `values-006.yaml`：恢复 `go-peer`(8084) / `pypi-peer`(8086)
3. `values.yaml`：cachePeer 注释更新
4. `Chart.yaml`：0.1.14

## 三、验证 Phase

> 统一入口：`KC="kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid"`；squid pod 内测试端口 3129。

### P0 部署 + 不 PINNED 确认
- helm template 人工审查 → helm upgrade → rollout restart
- 判定①：pypi GET 经 3129 access.log 出现 `FIRSTUP_PARENT/10.247.137.157`（= peer 被选中 → 不再 PINNED）
- 判定②：无 squid.conf 解析错误，pod Ready

### P1 证书快验（非仿冒证书接受度）
- `curl -vk -x 3129 https://pypi.org/...`：证书链 issuer=squid CA、subject CN=pypi.org（无 origin 仿冒字段），握手 + 200
- 注意：curl 需 `-k`（pod 内无 CA）或注入 CA；客户端侧接受度由 P7 vcjob 实证

### P2 pypi 链路（peer + nginx 双层缓存）
- 索引 `https://pypi.org/simple/requests/` ×2：200，`FIRSTUP_PARENT`；nginx 侧 `X-Pypi-Cache: MISS→HIT`
- 真实 wheel（从索引页取 URL）×2：200，第二次显著快

### P3 go 链路（顺带绕开 Google egress 阻断）
- `https://proxy.golang.org/golang.org/x/net/@v/list` ×2：200 走 go-peer:8084
- upstream=Nexus goproxy + goproxy.cn（cache-service pod 出网，与 squid egress 无关）
- 判定：Google IP 阻断期间仍 200（对照 server-first 时代 CONNECT TIMEDOUT 503）

### P4 registry splice 回归
- `curl -x 3129 https://registry.k8s.io/v2/`：401/302（splice 隧道通）
- access.log：registry 域 CONNECT 无 400/异常；观察真实 CI 流量（buildkitd）registry 拉取无回归
- 判定：dstdomain 在 step1 splice 与原 SNI 判定语义等价

### P5 apt 回归
- `http://archive.ubuntu.com/.../Release` ×2：`FIRSTUP_PARENT:8081` → HIT
- 注意：originserver 后 apt 转发形态从 absolute-form 变 origin-form，nginx 8081 两种都接受（cachepeer P1 已验）

### P6 never_direct fail-closed（https 域在 client-first 下语义验证）
- scale cache-service → 0：pypi 快速 503、无 HIER_DIRECT 静默回源；恢复即 200
- （对照修订①：server-first 下此场景表现为"必然 503"，client-first 下才是可控 fail-closed）

### P7 端到端 vcjob 子集（pip + go + pnpm）
- 复用 `cachepeer/apt-pip-go-compare-vcjob.yaml`（squid ns，代理指向 squid-cache:3128）+ `traffic-test/tool/15-pnpm.yaml`
- 判定：任务内官方源（pypi.org / proxy.golang.org / registry.npmjs.org）下载成功 + 二次显著快 + access.log 留痕 peer/缓存命中
- pnpm 注意：registry.npmjs.org 不在 cachePeer 域内 → 走 bump 直连 + squid 本地缓存（catch-all revalidate），
  验证的是"非 peer https 域在 client-first 下无回归"

### P8 判定与留档
- 结果写 `cachepeer/JUDGEMENT.md` 修订②
- 全绿：0.1.14 定稿；任一环节失败：回滚 chart 模板至 server-first（git revert），方案A判死留档

## 四、风险

| 风险 | 缓解 |
|---|---|
| 非仿冒证书被某 CI 工具拒绝（证书固定/严格 SAN 检查） | P7 子集实证；gy-006 为测试环境，失败影响可控 |
| dstdomain step1 splice 与 SNI 判定不等价（多 SNI/泛域名） | P4 回归测试；registry 列表均为明确域名 |
| absolute-form https 打到 nginx 8086 污染 $request_uri | 模板加 `originserver` 强制 origin-form（P2 的 X-Pypi-Cache 即证据） |
| cache-service 单点影响面扩大（pypi/go 纳入 never_direct） | P6 fail-closed 实测；与 apt 同一风险面，已有认知 |
