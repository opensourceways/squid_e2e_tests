# cache_peer × client-first bump（TLS 化 peer）——TEST-WORKFLOW

> **实验版本标签：v0.1.11-ccf**（cache_peer with client-first bump）——0.1.11 基线 +
> per-peer `tls` 渲染支持 + 实验叠加 values；Chart.yaml 实验期临时改为 `0.1.11-ccf`
> （semver 预发布号），机群其余集群保持 0.1.11 不动，gy-006 单集群实验。
>
> 目标：client-first bump 下让 pypi/go 的 `cache_peer` + `never_direct` **真正可用**
> （nginx 分片缓存介入 https 域），作为纯 rewrite 之外的第二条缓存路径。
> 前置结论链：
> - `cachepeer/JUDGEMENT.md` 修订①：server-first 下 https GET 被 PINNED，peer 结构性不可用
> - `gh-proxy/clientfirst-rewrite/TEST-WORKFLOW.md` §1.2：client-first 无 PINNED，bump 后
>   GET 走完整 peer_select——但上游连接被 squid 无条件 TLS 化
> - **源码实锤**：squid 7.x `src/FwdState.cc::secureConnectionToPeerIfNeeded()` L977-984，
>   `needsBump = sslPeek || sslBumped`，peer/origin 同路径、无配置开关；非 originserver
>   的代理型 peer 才有 `establishTunnelThruProxy()` 例外（L896-901），对本项目不适用
> - 0.1.14 实验（`cachepeer/clientfirst-bump/`）：明文 nginx peer 撞强制 TLS → 必然
>   wrong version number 503（gy006 备份 `squid.conf.exp` 摘除注释）——**本实验 = 用
>   TLS 化 peer 化解这一步**

---

## 一、与 0.1.14 实验的本质区别

| | 0.1.14（已判死） | 本实验 0.1.11-ccf |
|---|---|---|
| bump 模式 | client-first（同） | client-first（同） |
| peer 传输 | 明文 http → **撞 needsBump 强制 TLS，必 503** | `cache_peer tls sslflags=DONT_VERIFY_PEER` → TLS terminator → 明文 http → cache-service |
| urlRewrite | 无（0.1.14 时代未转正） | **关闭**（0.1.11 helper 在 peer_select 之前重写 pypi/go，键变 huaweicloud/goproxy.cn，peer 永不命中） |
| apt | 明文 peer 8081 | 保留明文 peer 作 **TLS 边界对照组**（http 请求不经 bump，验证强制 TLS 只作用于 bumped 请求） |

## 二、组件与改动清单

| 件 | 位置 | 作用 |
|---|---|---|
| 实验叠加 values | 本目录 `values-006-ccf.yaml` | `urlRewrite.enabled=false` + cachePeer 三 peer（apt 8081 明文 / pypi 8443 tls / go 8444 tls），helm 双 `-f` 叠加不污染基线 |
| TLS terminator | 本目录 `tls-terminator.yaml` | squid ns 内 nginx（自签证书）：8443→cache-service 8086(pypi)、8444→8084(go)；不动共享 cache-service conf |
| chart 模板 | `deploy/chart/templates/configmap.yaml` §4.4 | per-peer `tls: true` → 渲染 `cache_peer ... originserver tls sslflags=DONT_VERIFY_PEER` |
| chart 版本 | `deploy/chart/Chart.yaml` | `0.1.11-ccf`（实验预发布号，实验结束按 P8 处置） |

## 三、测试步骤（Phase）

> 统一入口：`KC="kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid"`；
> squid pod 内 curl 一律 `-x http://127.0.0.1:3129`（3129 = ssl-bump 入口，记 access.log）。
> 判定原则：每 Phase 末尾"判定"全绿才继续；失败记录现象先修再走。

### P0 前置勘验

```bash
# 1. 基线确认：0.1.11 纯 rewrite + client-first 在位
$KC exec squid-cache-0 -c squid -- sh -c '
  grep -E "ssl_bump|url_rewrite_program" /etc/squid/squid.conf | head -5
  curl -sk -o /dev/null -w "pypi-rewrite=%{http_code}\n" -x 127.0.0.1:3129 https://pypi.org/simple/pip/'
# access.log 应见 GET https://repo.huaweicloud.com/... （重写生效 = 基线正常）

# 2. cache-service 端口归属复测 + 8086 是否镜像 /packages/ 路径
$KC exec squid-cache-0 -c squid -- sh -c '
  H=cache-service.nginx-pypi-cache.svc.cluster.local
  for p in 8081 8084 8086; do
    echo "--- port $p ---"
    curl -s --max-time 8 "http://$H:$p/simple/requests/" -o /dev/null -w "pypi  code=%{http_code}\n"
    curl -s --max-time 8 "http://$H:$p/golang.org/x/net/@v/list" -o /dev/null -w "go    code=%{http_code}\n"
    curl -s --max-time 8 "http://$H:$p/ubuntu/dists/jammy/Release" -o /dev/null -w "deb   code=%{http_code}\n"
  done
  echo "--- 8086 packages 路径（wheel 链接是否同构可路由）---"
  curl -s --max-time 8 "http://$H:8086/simple/requests/" | grep -oE "href=\"[^\"]+\"" | head -3'
```

- 判定①：基线重写 200（否则先修基线再实验）
- 判定②：8086 pypi 200 / 8084 go 200 / 8081 deb 200（端口归属确认）
- 判定③：8086 索引页 wheel 链接指向 → 若相对路径（packages/…）则 `.files.pythonhosted.org`
  可纳入 pypi-peer domains（改 values-006-ccf 后重渲染）；若指向官方绝对 URL 则不纳入，
  wheel 对象走直连（记录结论，P3 按此验证）

### P1 TLS terminator 部署 + 线级验证

```bash
$KC apply -f redirect/cachepeer-client-first/tls-terminator.yaml
$KC rollout status deploy/tls-terminator --timeout=5m
# origin-form + 原 Host 打 TLS 端口（模拟 squid cache_peer 转发形态）
$KC exec squid-cache-0 -c squid -- sh -c '
  H=tls-terminator.squid.svc.cluster.local
  curl -sk --max-time 10 -H "Host: pypi.org" "https://$H:8443/simple/requests/" -o /dev/null -w "pypi  code=%{http_code}\n"
  curl -sk --max-time 10 -H "Host: proxy.golang.org" "https://$H:8444/golang.org/x/net/@v/list" -o /dev/null -w "go    code=%{http_code}\n"'
```

- 判定①：terminator Ready；两端口 200（TLS 层通 + 明文 upstream 通）
- 判定②：若 502/404 → 查 cache-service 端口归属（P0 判定②）与 Host 透传

### P2 部署 0.1.11-ccf

```bash
cd deploy
helm template squid ./chart -f values-006.yaml -f ../redirect/cachepeer-client-first/values-006-ccf.yaml -n squid | grep -E "cache_peer|url_rewrite_program"   # 人工审查：3 peer，无 url_rewrite_program
helm upgrade squid ./chart -f values-006.yaml -f ../redirect/cachepeer-client-first/values-006-ccf.yaml \
  -n squid --kubeconfig ~/.kube/gy-006.yaml --wait --timeout 8m --force-conflicts
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid rollout restart statefulset/squid-cache
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid rollout status statefulset/squid-cache --timeout=8m
# 部署后确认
$KC exec squid-cache-0 -c squid -- sh -c '
  grep -E "cache_peer|never_direct" /etc/squid/squid.conf
  squidclient -h 127.0.0.1 -p 3129 cache_object://localhost/peers 2>/dev/null | head -20'
```

- 判定①：squid.conf 含 3 条 cache_peer（pypi/go 带 `tls sslflags=DONT_VERIFY_PEER`）、
  4 条 never_direct（registry+3 peer）、**无** url_rewrite_program
- 判定②：peers 输出三个 peer 状态非 DEAD

### P3 pypi 链路（TLS peer + 双层缓存）

```bash
$KC exec squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "https://pypi.org/simple/requests/" -o /dev/null -w "pypi pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done'
$KC exec squid-cache-0 -c squid -- grep "pypi.org" /var/log/squid/access.log | tail -5
```

- 判定①：两次 200，第二次 `TCP_HIT`（或显著快）；HIER = `FIRSTUP_PARENT/…`（peer 被选中）
- 判定②：**无** wrong version number 503（对照 0.1.14）、无 421/301（对照 server-first 重写时代）
- 判定③：按 P0 判定③结论验证 wheel 对象 URL（纳入 files 域 → 走 peer；否则直连官方并确认 squid 本地缓存）

### P4 go 链路

```bash
$KC exec squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "https://proxy.golang.org/golang.org/x/net/@v/list" -o /dev/null -w "go pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done'
$KC exec squid-cache-0 -c squid -- grep "proxy.golang.org" /var/log/squid/access.log | tail -5
```

- 判定：两次 200、第二次 HIT、HIER 走 go-peer；Google egress 阻断期间仍 200
  （Nexus goproxy upstream 出网与 squid egress 无关——对照 server-first 时代 503）

### P5 TLS 边界对照（apt 明文 peer）

```bash
$KC exec squid-cache-0 -c squid -- sh -c '
  for i in 1 2; do
    curl -s -x http://127.0.0.1:3129 "http://archive.ubuntu.com/ubuntu/dists/jammy/Release" -o /dev/null -w "apt pass$i code=%{http_code} ms=%{time_total}\n" --max-time 20
  done'
$KC exec squid-cache-0 -c squid -- grep "archive.ubuntu.com" /var/log/squid/access.log | tail -4
```

- 判定①：apt 两次 200、HIER 走 apt-peer:8081 **明文**——证明 needsBump 强制 TLS 只作用于
  bumped（https）请求，http 域 peer 行为与 0.1.12 时代一致（cachepeer P3 已验）
- 判定②：此为 TLS 边界结论的对照锚点，写留档必带

### P6 失败语义（never_direct fail-closed，TLS peer 场景）

```bash
# 摘 cache-service（terminator 还在 → TLS 握手成功但 upstream 挂，观察 squid 表现）
kubectl --kubeconfig ~/.kube/gy-006.yaml scale deploy/pypi-cache-deployment -n nginx-pypi-cache --replicas=0
sleep 15
$KC exec squid-cache-0 -c squid -- sh -c '
  curl -s -x http://127.0.0.1:3129 "https://pypi.org/simple/requests/" -o /dev/null -w "peer-down code=%{http_code} ms=%{time_total}\n" --max-time 20'
# 恢复
kubectl --kubeconfig ~/.kube/gy-006.yaml scale deploy/pypi-cache-deployment -n nginx-pypi-cache --replicas=1
```

- 判定①：peer 下线后**快速失败**（502/504），**无**静默回官方源（无 `HIER_DIRECT/外网IP`）
- 判定②：恢复后 200；记录 peer DEAD→复活探测周期
- 注意：本次摘的是 cache-service 而 terminator 存活，与 0.1.14 时代"摘 peer"语义不同
  （TLS 层还通），若需同语义可再 scale terminator 0 复测一轮

### P7 端到端 vcjob 子集（pip + go）

```bash
KC="kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid"
$KC apply -f redirect/cachepeer/apt-pip-go-compare-vcjob.yaml
$KC get pods -n squid -l pipeline/run-id=cachepeer-compare -w
# 判据：任务内官方源下载成功 + 二次显著快；access.log 留痕 FIRSTUP_PARENT + MISS/HIT
```

- 判定：pip（pypi.org）与 go（proxy.golang.org）任务经 TLS peer 成功且二次快；
  **风险聚焦点**：非仿冒 sslcrtd 证书 + CA 信任注入在真实客户端的接受度
  （0.1.14 时代 P7 已过一轮，client-first 证书形态未变，预期无回归）

### P8 判定与留档

- 结果写本目录 `JUDGEMENT.md`（新修订，引用 FwdState.cc L977-984 源码结论）
- 全绿 → 决策：ccf 转正（values-006 换缓存路径）或与纯 rewrite 并存（分域分工）
- 任一失败 → git revert Chart.yaml 回 0.1.11，values-006 恢复纯 rewrite，
  0.1.11-ccf 判死留档；**回切命令**：

```bash
cd deploy
helm upgrade squid ./chart -f values-006.yaml -n squid --kubeconfig ~/.kube/gy-006.yaml --wait --force-conflicts
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid rollout restart statefulset/squid-cache
kubectl --kubeconfig ~/.kube/gy-006.yaml -n squid delete -f ../redirect/cachepeer-client-first/tls-terminator.yaml
```

## 四、机器可读判定汇总

| Phase | 判定 | 通过条件 |
|---|---|---|
| P0 | 基线 + 端口归属 + wheel 链接结论 | 重写 200；8081/8084/8086 各 200；files 域纳入与否结论明确 |
| P1 | terminator TLS 链路 | Ready + 8443/8444 origin-form 200 |
| P2 | 3 peer 在位无 rewrite | grep 命中 + peers 非 DEAD + 无 url_rewrite_program |
| P3 | pypi TLS peer 双层缓存 | 2×200，第 2 次 TCP_HIT，HIER=FIRSTUP_PARENT，无 503/421/301 |
| P4 | go TLS peer 双层缓存 | 同 P3 |
| P5 | TLS 边界对照 | apt 明文 peer 200 + HIT |
| P6 | fail-closed 无静默回源 | 快速失败且无 HIER_DIRECT 外网；恢复 200 |
| P7 | 端到端 | pip/go 任务成功 + 二次快 |

## 五、风险

| 风险 | 缓解 |
|---|---|
| needsBump 强制 TLS 的结论只验过 master 源码，7.7.2 具体行为可能有差异 | P1/P3 即验证：TLS peer 200 则结论成立；明文 503 复现则反向坐实 |
| terminator 单点（1 副本） | 实验期影响可控；转正前需 2 副本 + 反亲和（P8 决策项） |
| urlRewrite 全关 = apt/github 重写收益暂停 | 仅 gy-006 实验窗口；P8 按结果回切或分域分工（rewrite 管 github，peer 管 pypi/go） |
| `tls sslflags=DONT_VERIFY_PEER` 面向 terminator（自签），非出网信任边界 | terminator 在同 ns 内网，不出集群；不出网流量安全语义不变 |
| squid 7.7.2 对 cache_peer `tls` + originserver 组合的 SNI/证书校验细节 | P1 线级先行；DONT_VERIFY_PEER 规避校验失败类问题 |
