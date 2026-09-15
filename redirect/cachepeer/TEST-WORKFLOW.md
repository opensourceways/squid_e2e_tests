# cache_peer 选路测试（go / pip / apt）——TEST-WORKFLOW

> 目标与测试步骤留档（2026-09-08）。对应方案：squid `cache_peer`（parent）+ dst/domain ACL +
> `never_direct`，上游 = 集群内 `cache-service`（nginx-pypi-cache，按端口分片）。
> **本工作流不碰 github**（archive/releases/codeload/raw 维持官方直连 + refresh_pattern 长缓存）。
>
> 背景：url_rewrite 重写 https 在 ssl-bump 下结构性不可用（连接复用 → 301 翻倍/421，见
> `gh-proxy/JUDGEMENT.md` 修订⑥）。cache_peer 是**回源选路**：URL/缓存键原样不变，squid 按目标域
> 把明文请求转发给 peer，从机制上绕开连接复用缺陷。

---

## 一、目标（Goal）

1. **机制验证**：squid 经 `cache_peer` 把 apt/pip/go 流量转发到 `cache-service` 对应端口，
   URL 不变、缓存键不变、无重定向异常。
2. **双层缓存验证**：nginx 层（peer `X-Cache-Status`）+ squid 层（access.log TCP_HIT）都命中；
   第二次请求显著快于第一次。
3. **客户端零改动**：CI 任务只配 `http_proxy/https_proxy` 指向 squid，不感知换源
   （与 url_rewrite 方案的"客户端零改动"等价，但机制安全）。
4. **失败语义实测**：peer 挂掉时 `never_direct` fail-closed 的表现（预期：对应域 502/超时，
   **不会**静默回官方源），记录结论供架构决策（单点风险 vs 限流风险）。

### 被测链路

| 域 | peer 端口 | nginx upstream（已知/待验） | 客户端工具 |
|---|---|---|---|
| `archive.ubuntu.com` `ports.ubuntu.com` `.debian.org` | 8081 (deb) | `deb_mirror`（待验 host） | apt |
| `pypi.org`（`files.pythonhosted.org` 待验） | 8083（**待验归属**） | pypi（待验） | pip |
| `proxy.golang.org` | 8084 (go) | `goproxy.cn`（已见 conf） | go mod |

### 已知事实（2026-09-08 勘验）

- `cache-service.nginx-pypi-cache.svc`（10.247.137.157）：1 副本 Running，端口 80/8081-8085；
  conf 已证实 8081=deb、8082=rustup、8084=go（goproxy.cn）、8085=crates、80=默认页；**8083 未确认**。
- squid（gy-006，0.1.8 干净版）pod 内测试端口：**3129**（3128 是 registry-proxy 透传，不记 access.log）。
- squid 现有 `refresh_pattern` 已覆盖 ubuntu/debian/golang 域；catch-all 为 `0 0% 0 refresh-ims`。

---

## 二、测试步骤（Phase）

> 统一入口：`KC="kubectl --kubeconfig ~/.kube/gy-006.yaml -n <ns>"`；
> squid pod 内 curl 一律 `-x http://127.0.0.1:3129`。
> 判定原则：每 Phase 末尾的"判定"全绿才算过；失败记录现象后先修再继续。

### P0 前置勘验（cache-service 归属 + 连通性）

```bash
# 1. 各端口身份探测（在 squid-cache-0 内，走集群 DNS）
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  for p in 80 8081 8082 8083 8084 8085; do
    echo "--- port $p ---"
    # 8083 疑似 pypi：/simple/ 索引页特征
    curl -s --max-time 8 "http://cache-service.nginx-pypi-cache.svc.cluster.local:$p/simple/" -o /dev/null -w "simple code=%{http_code}\n"
    curl -s --max-time 8 "http://cache-service.nginx-pypi-cache.svc.cluster.local:$p/dists/jammy/Release" -o /dev/null -w "deb    code=%{http_code}\n"
    curl -s --max-time 8 "http://cache-service.nginx-pypi-cache.svc.cluster.local:$p/golang.org/x/net/@v/list" -o /dev/null -w "go     code=%{http_code}\n"
  done'
```

- 判定①：8081 deb 200、8084 go 200；**8083 对 /simple/ 返回 200（且响应头带 X-Cache 类标记）→ 确认 pypi 归属**
- 判定②：若 8083 不是 pypi，从 conf.d 全量 conf 里找 pypi 的 listen 端口，更新本表后再继续

```bash
# 2. pypi upstream 形态：索引页里的 wheel 链接指向谁？（决定 files.pythonhosted.org 是否需路由）
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  curl -s --max-time 8 "http://cache-service.nginx-pypi-cache.svc.cluster.local:<PYPI_PORT>/simple/requests/" | grep -oE "https://[^\"]+requests-[^\"]+whl[^\"]*" | head -3'
```

- 判定③：链接指向 `cache-service`/集群内域名 → 只路由 `.pypi.org`；指向 `files.pythonhosted.org`
  → ACL 必须加 `.files.pythonhosted.org`（否则下载流量绕过 peer 直连官方）

### P1 wire-form 线级验证（squid 实际发什么、peer 收什么）

```bash
# 模拟 cache_peer 转发形态：origin-form 请求 + 原 Host 头，直接打 peer 各端口
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  H=cache-service.nginx-pypi-cache.svc.cluster.local
  echo "--- deb: origin-form, Host: archive.ubuntu.com ---"
  curl -s --max-time 10 -H "Host: archive.ubuntu.com" "http://$H:8081/dists/jammy/Release" -o /dev/null -w "code=%{http_code}\n"
  echo "--- pypi: origin-form, Host: pypi.org ---"
  curl -s --max-time 10 -H "Host: pypi.org" "http://$H:<PYPI_PORT>/simple/requests/" -o /dev/null -w "code=%{http_code}\n"
  echo "--- go: origin-form, Host: proxy.golang.org ---"
  curl -s --max-time 10 -H "Host: proxy.golang.org" "http://$H:8084/golang.org/x/net/@v/list" -o /dev/null -w "code=%{http_code}\n"'
```

- 判定①：三端口都 200 → nginx 接受 origin-form + 任意 Host（upstream 由端口静态决定，与 Host 无关）
- 判定②：若某端口 404/421 → 抓 nginx conf 的 server_name 匹配规则，调整 ACL/端口映射

### P2 部署 squid cache_peer 配置（chart 改动）

```bash
# chart：values 加 cachePeer.enabled 开关；configmap 模板渲染（P0/P1 结论填入端口）
cd deploy
helm template squid ./chart -f values-006.yaml --set squid.cachePeer.enabled=true | less   # 人工审查
helm upgrade squid ./chart -f values-006.yaml -n squid --kubeconfig ~/.kube/gy-006.yaml --timeout 10m --wait
# 注意：configmap 变化不触发滚动（statefulset 无 checksum 注解）→ 手动滚动
kubectl --kubeconfig ~/.kube/gy-006.yaml rollout restart statefulset/squid-cache -n squid
kubectl --kubeconfig ~/.kube/gy-006.yaml rollout status statefulset/squid-cache -n squid
```

```bash
# 部署后确认 squid.conf 生效 + peer 状态
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  grep -E "cache_peer|never_direct|cache_peer_access" /etc/squid/squid.conf
  squidclient -h 127.0.0.1 -p 3129 cache_object://localhost/peers 2>/dev/null | head -20'
```

- 判定：peers 输出三个 peer 状态非 DEAD；`never_direct` 规则在位

### P3 apt 链路（MISS→HIT + 双层缓存）

```bash
# squid pod 内直接经 3129 拉 deb 元数据 + 一个小 deb 包，各两次
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "http://archive.ubuntu.com/ubuntu/dists/jammy/Release" -o /dev/null -w "apt pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done'
# access.log 判据：目标 archive.ubuntu.com，HIER 为 <peer 名>/DIRECT（走 peer），非 HIER_DIRECT/外网 IP
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- \
  grep "archive.ubuntu.com" /var/log/squid/access.log | tail -5
```

- 判定①：两次均 200；第二次 access.log 出现 `TCP_HIT`（或 `TCP_MEM_HIT`）
- 判定②：HIER 列显示 peer 名（如 `HIER/apt-peer` 或 `DEFAULT_PARENT/APT_PEER`），**无** 301/421 异常码
- 判定③（可选端到端）：起临时 pod 跑 `apt update`，配 squid 代理，核对 access.log 的 peer 命中

### P4 pip 链路（索引 + 对象双验证）

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "https://pypi.org/simple/requests/" -o /dev/null -w "pypi pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done
  # 对象 URL：按 P0 判定③ 的结论决定是否测 files.pythonhosted.org
  curl -s -x http://127.0.0.1:3129 "<对象URL按P0结论>" -o /dev/null -w "wheel code=%{http_code} ms=%{time_total}\n" --max-time 30'
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- \
  grep -E "pypi.org|pythonhosted" /var/log/squid/access.log | tail -5
```

- 判定①：pypi 索引两次 200，第二次 HIT；**无 421/301**（对照 url_rewrite 时代的失败形态）
- 判定②：wheel 对象 URL 走 peer（或按 P0 结论确认天然同源）；下载耗时第二次 < 第一次

### P5 go 链路

```bash
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "https://proxy.golang.org/golang.org/x/net/@v/list" -o /dev/null -w "go pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done'
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- \
  grep "proxy.golang.org" /var/log/squid/access.log | tail -5
```

- 判定：两次 200、第二次 HIT、HIER 走 go-peer

### P6 失败语义（never_direct fail-closed 实测）

```bash
# 1. 摘掉 peer：scale cache-service 到 0（测完立刻恢复）
kubectl --kubeconfig ~/.kube/gy-006.yaml scale deploy/pypi-cache-deployment -n nginx-pypi-cache --replicas=0
sleep 15
kubectl --kubeconfig ~/.kube/gy-006.yaml exec -n squid squid-cache-0 -c squid -- sh -c '
  curl -s -x http://127.0.0.1:3129 "http://archive.ubuntu.com/ubuntu/dists/jammy/Release" -o /dev/null -w "peer-down code=%{http_code} ms=%{time_total}\n" --max-time 20'
# 2. 恢复
kubectl --kubeconfig ~/.kube/gy-006.yaml scale deploy/pypi-cache-deployment -n nginx-pypi-cache --replicas=1
```

- 判定①：peer 下线后请求**快速失败**（502/504 或连接拒绝），access.log 记 `ERR_CONNECT_FAIL` 类；
  **关键观察：是否静默 fallback 直连官方源**——never_direct 语义下不应出现（HIER_DIRECT/外网 IP）
- 判定②：恢复后请求重新 200；记录 squid 标记 peer DEAD → 复活的探测周期
- 判定③：把"单点故障影响面"结论写回本文件与 SOLUTION，供是否引入第二个 peer/软策略决策

---

## 二b、端到端对照 vcjob：apt / pip / go —— with-squid vs direct（两变体并行部署）

> 用例：本目录 `apt-pip-go-compare-vcjob.yaml`（with-squid 变体）+ `.gen-direct.py` 生成的
> `apt-pip-go-compare-vcjob-direct.yaml`（direct 变体：剥离全部代理 env，走 pod 默认路由）。
> **两个变体同时 apply、并行跑，一轮出对照结果**——与 P2/cache_peer 部署节奏无关，
> 测的是"当前 squid 配置下"的直连 vs 代理差异。
> 镜像 = cann amd64（squid ns 已验证）；CA 由 postStart 注入系统信任库，pip 另带 `PIP_CERT`/`SSL_CERT_FILE`。

### 跑法

```bash
KC="kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid"
$KC apply -f redirect/cachepeer/apt-pip-go-compare-vcjob.yaml
$KC get pods -n squid -l pipeline/run-id=cachepeer-compare -w
for p in $($KC get pods -n squid -l pipeline/run-id=cachepeer-compare -o name); do
  echo "===== $p ====="; $KC logs "${p#pod/}"
done
# access.log 判据
$KC exec squid-cache-0 -c squid -- grep -E "archive.ubuntu.com|pypi.org|pythonhosted|proxy.golang.org" /var/log/squid/access.log | tail -40
```

### 每个任务测什么

| task | A 直连组 | B squid 组 | 判定 |
|---|---|---|---|
| apt-compare | `apt-get update` + `apt-get download xz-utils` ×2 | 同 A | B pass2 应显著快于 pass1（HIT）；B 与 A 对比 = squid/peer 链路开销与收益 |
| pip-compare | `pip download requests==2.31.0 --no-deps` ×2 | 同 A | 同上；同时确认 wheel 对象域是否进 squid（P0 判定③验证） |
| go-compare | `GOPROXY=https://proxy.golang.org,direct go mod download` ×2（无 go 则 curl `.mod` 线级对照） | 同 A + 代理 env | 同上；direct 组在 squid access.log 应**无记录**（证明真直连） |

### 变体生成与对照逻辑（单轮出结果）

1. **with-squid 变体**：env 指向 `squid-cache:3128`，access.log 全程留痕（MISS/HIT/HIER）。
2. **direct 变体**：`python3 .gen-direct.py apt-pip-go-compare-vcjob.yaml \
   apt-pip-go-compare-vcjob-direct.yaml` 生成——剥离全部代理 env（同 traffic-test/tool/.gen-direct.py
   的 DROP_ENV 机制）、job/task 名加 `-direct` 后缀避免 vcjob 同名冲突。
3. **两个变体同时 apply、并行跑，一轮出对照结果**——与 P2/cache_peer 部署节奏无关，
   测的是"当前 squid 配置下"直连 vs 代理的差异。
4. **结论输出**：direct vs with-squid 对照表（首发/次发耗时 + access.log MISS/HIT + HIER），
   写入本目录 `JUDGEMENT.md`；direct 组在 squid access.log 应**无记录**（证明真直连）。

### 注意

- go-compare 在 cann 镜像缺 go 时自动降级为 curl 打 `proxy.golang.org` 的 `.mod` API——
  wire 路径与 go 客户端等价（同域同 URL 形态），仅少一层 GOPROXY 协议封装。
- pip 的 `--no-deps` 固定单 wheel，避免依赖解析引入多域噪声；requests==2.31.0 wheel ~110KB，
  缓存收益可见且不占时长。
- apt 的 `apt-get update` 含多域（archive/security/ports），耗时受上游影响大，**只作参考**；
  判定以 `apt-get download`（单域单包）为准。

---

## 三、机器可读判定汇总

| Phase | 判定 | 通过条件 |
|---|---|---|
| P0 | 8083=pypi 归属、wheel 链接同源 | 端口探测 200 + 链接指向结论明确 |
| P1 | origin-form 全 200 | 3 端口 code=200 |
| P2 | squid.conf 含 cache_peer×3 + never_direct，peers 非 DEAD | grep 命中 + peers 输出 |
| P3 | apt 双层缓存 | 2×200，第 2 次 TCP_HIT，HIER=peer，无 301/421 |
| P4 | pypi 双层缓存 | 同 P3（+对象 URL 按结论路由） |
| P5 | go 双层缓存 | 同 P3 |
| P6 | fail-closed 无静默回源 | peer 挂 → 快速失败且无 HIER_DIRECT 外网；恢复后 200 |

## 四、产物

- 实测记录 → 本目录 `JUDGEMENT.md`（2026-09-15 已写）
- chart 改动 → `deploy/chart`（values `squid.cachePeer.enabled` + configmap §4.4 + **CONNECT 排除修复**，
  chart 0.1.12），commit 到 `cache-peer-sources` 分支
- ~~若 P4 证实需路由 `files.pythonhosted.org`~~ → 已实测：wheel 域流量进 squid（squid 本地缓存即可，
  无 pypi peer 可用）
