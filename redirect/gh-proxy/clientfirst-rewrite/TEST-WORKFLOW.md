# client-first + url_rewrite_program 实验计划（TEST-WORKFLOW）

> 2026-09-15 起草。前置：chart 0.1.14（client-first bump）已部署 gy-006。
> 目的：验证「client-first 下 https 域 url_rewrite 复活」假设——若成立，https 镜像重写
> 无需 nginx peer TLS 化，且顺带解决 go egress 对 Google IP 阻断。
> 关联：`../JUDGEMENT.md`（修订⑥：server-first 下 https 重写判死）、
> `../cachepeer/clientfirst-bump/TEST-WORKFLOW.md`（TLS-peer 竞争路线）、
> `../../SOURCE-REWRITE-ANALYSIS.md`。

---

## 一、假设与机制依据

### 1.1 修订⑥ 的判死根因——只在 server-first 下成立

| | server-first（0.1.12 时代实测） | client-first（0.1.14 现状） |
|---|---|---|
| CONNECT 阶段 | 先连 origin 取证书链仿冒 → 连接 **PINNED** | 不连 origin，step1 直接 bump |
| bump 后 GET | 强制复用 pinned 连接（目的地=原始 IP） | 无绑定，按重写后目的地**新建上游连接** |
| 重写后果 | 重写 Host 打到旧连接 → **301/421**（pypi→tuna 421 实锤） | TLS 连到新主机（FwdState `needsBump`），Host 与连接一致 |

### 1.2 源码依据

- `FwdState.cc`：`clientFirstBump = request->flags.sslBumped`；`needsBump = sslPeek || clientFirstBump`
  → client-first bumped 请求的上游连接无条件 TLS，按 `request->url`（重写后）选目的地。
- HTTP 明文重写（archive.ubuntu.com→mirrors.huaweicloud.com）实测 200 已证明 squid 重写后
  **重建 Host 头**；https 路径同理（重写结果重新解析进 `request->url`）。

### 1.3 推论（待实验证实）

1. 重写 `https://pypi.org/simple/* → https://pypi.tuna.../simple/*`：期望 200、无 301/421。
2. 重写后请求不再命中 pypi-peer/go-peer 的 dstdomain ACL → 走直连（TLS），
   **实验期无需回退 values 的 peer 配置**，但注意 peer 配置从此对被重写域失效（见 §5）。
3. 缓存键 = 重写后 URL；确定性重写 → 键稳定，本地缓存 HIT 可复现。

---

## 二、实验改动（全部 CM/临时挂载，不动 chart 模板；测完回滚）

### 2.1 重写 helper（最小实现，shell 循环即可）

squid.conf 增配：

```
# 实验：client-first 下 https 重写复活验证（gy-006 临时，勿上生产）
url_rewrite_program /etc/squid/rewrite-helper.sh
url_rewrite_children 8 startup=1 idle=1
url_rewrite_access deny registry        # registry 域 splice，不进重写（双保险）
```

helper 规则（白名单外一律输出空行 = 原样放行；只匹配 GET/HEAD 的 https URL）：

| 原始 URL | 重写为 | 目的 |
|---|---|---|
| `https://pypi.org/simple/*` | `https://pypi.tuna.tsinghua.edu.cn/simple/*` | 重跑当年 421 用例 |
| `https://files.pythonhosted.org/packages/*` | `https://pypi.tuna.tsinghua.edu.cn/packages/*` | wheel 域同构映射 |
| `https://proxy.golang.org/*` | `https://goproxy.cn/*` | go egress 阻断绕行 |
| 其余（含 CONNECT、http） | 空 | 零改动 |

### 2.2 脚本注入方式（按优先级）

1. **临时 CM + kubectl patch StatefulSet** 挂载 `/etc/squid/rewrite-helper.sh`（纯实验，最快）；
2. 若验证通过转正，再走 chart：values 加 `squid.rewrite`（脚本内联 CM + extraVolume），bump 0.1.15。

### 2.3 回滚

`helm upgrade squid-rpardini`（以 chart 渲染覆盖 CM）+ rollout，helper/补丁全部消失；
StatefulSet patch 记录原始 yaml 备份。

---

## 三、验证 Phase（顺序执行，机器可判定）

| Phase | 内容 | 通过标准 |
|---|---|---|
| P0 | helper 就绪：`squid -k parse` 无错；debug 85,2 见重写结果 | 0 error；pypi URL 被改写日志 |
| P1 | **pypi→tuna（当年 421 用例）**：squid pod `curl -x 127.0.0.1:3129 https://pypi.org/simple/pip/`（`--cacert` squid CA） | **200，无 301/421**；access.log `TCP_MISS DIRECT/goproxy…tuna IP`；二次 `TCP_MEM_HIT` |
| P2 | wheel：同法取一个 `.whl`（files.pythonhosted.org） | 200 MISS→HIT；pip hash 校验通过 |
| P3 | go：`curl .mod/.zip`（proxy.golang.org，egress Google 断也无妨） | 200；goproxy.cn 响应头可见 |
| P4 | apt 回归：不重写域走 apt-peer 8081 | `TCP_MISS FIRSTUP_PARENT` 无回归 |
| P5 | 失败语义：杀 helper 进程/填满 helper | 请求**原样放行**（squid helper 失败兜底=不重写），不 5xx |
| P6 | 端到端 vcjob：pip download / go mod download（对比 direct） | 端到端可用 + 二次提速 |

P1 是决定性实验：200 → 假设成立；仍 301/421 → 机制理解有误，抓 debug 85+44 复盘。

---

## 四、风险与边界

1. **helper 热路径**：8 children 应付 CI 并发足够；P5 验证挂掉兜底为直连（pypi/goproxy 境外可达性依 2.3 egress 现状）。
2. **缓存键改变**：重写域的既有缓存条目（原始 URL 键）全部失效重建——实验期可接受。
3. **镜像同构性**：tuna `/simple`、`/packages` 与 pypi 同构（已由 8086 nginx 层验证路径形态）；
   goproxy.cn 与 proxy.golang.org 同构（GPROXY 协议）。
4. **peer 配置失效**：重写发生在 peer_select 之前，被重写域的 pypi-peer/go-peer 永不命中
   （不是错误，但要知道）。若 P1 通过，转正时应把 pypi-peer/go-peer 从 values 摘除，避免误导。
5. **registry splice 不受影响**：splice 流量不解密、不进重写。
6. **不要上生产**：修订⑥ 结论的限定修订与转正决策，待 P1-P6 全绿 + 与 TLS-peer 路线对比后拍板。

---

## 五、与 TLS-peer 路线（cachepeer/clientfirst-bump）的决策对比

| 维度 | url_rewrite→公网镜像 | TLS 化 nginx peer |
|---|---|---|
| 改动面 | squid CM（+helper 脚本） | cache-service 证书/挂载/svc + chart per-peer tls |
| go egress | **顺带解决**（→goproxy.cn） | 不解决（peer 回源仍打 Google） |
| 缓存层级 | squid 本地（2 副本各自一份） | + 集群共享 nginx 层 |
| 上游依赖 | 公网镜像站可用性/带宽 | 集群内 cache-service（单点，已有 P6 fail-closed） |
| URL/键 | 变（确定性→键稳定） | 不变（origin-form） |

两条线不互斥：go 走 rewrite（egress 死结无解），pypi 二选一。

---

## 六、留档出口

- 结论写入 `../JUDGEMENT.md` **修订⑦**；修订⑥ 标注限定（server-first 下成立，client-first 复活/证伪）。
- `project_memory.md` 硬约束条目同步更新。

---

## 七、执行记录（2026-09-15 gy-006 实测）

### 7.1 实验落地形态（与计划 §2 的偏差）

| 项 | 计划 | 实际 |
|---|---|---|
| helper 注入 | CM + STS patch | ✓ `squid-config` CM 加 `rewrite-helper.sh` key + STS patch（volume items + subPath volumeMount）；回滚=helm upgrade 覆盖 CM + STS 由 helm 还原 |
| helper 协议 | shell 循环（未定协议细节） | **squid 5+ 协议**：输入 `<URL> [extras]`（未配 concurrency 无 channel-ID），输出 `OK rewrite-url="..."` / `OK`；初版误用 2.x 裸 URL 回显协议 → 永远原样回显（第一轮 503 根因，非机制问题） |
| 重写规则 | 3 条 | **4 条**：新增 `pypi.org/packages/* → tuna/packages/*`（tuna 索引页 href 为相对路径，pip 按客户端视角解析成 pypi.org/packages/*，缺此规则真实 pip 必 404——P2 附带发现） |
| debug 取证 | 85 | 85,3 + 44,3（`debug_options` 随实验块回滚） |

### 7.2 Phase 结果

| Phase | 结果 | 证据（access.log / 实测值） |
|---|---|---|
| P0 helper 就绪 | ✅ | rollout 完成；2 个 `(sh) /etc/squid/rewrite-helper.sh` 进程；`helperOpenServers: Starting 1/8 'sh'` |
| P1 pypi→tuna（当年 421 用例） | ✅ **决定性通过** | `GET https://pypi.tuna.../simple/pip/ HIER_DIRECT/101.6.15.130` **200**（0.70s）；二次 200（0.056s）；**无 301/421、无 503**；客户端 CONNECT 仍 pypi.org:443（URL/证书零感知） |
| P2 wheel→tuna/packages | ✅ | 2.1MB whl `TCP_MISS/200`（2.28s）→ **`TCP_HIT/200`（33ms）**（.whl 10080min 规则 100% 命中）；`pypi.org/packages/*` 新规则亦 200 |
| P3 go→goproxy.cn | ✅ **egress 阻断绕行成功** | `GET https://goproxy.cn/.../@v/v0.9.1.mod HIER_DIRECT/113.125.253.28` 200（0.12s）——proxy.golang.org 对 Google 的 egress 死结不经过 |
| P4 非白名单原样放行 | ✅ | example.com 200 直连，未重写 |
| P5 apt peer 回归 | ✅ | `http://archive.ubuntu.com/...Release FIRSTUP_PARENT/10.247.137.157` 200，无回归 |
| P5 helper 失败语义 | ✅ | `kill -9` 全部 helper → **1s 内自动重生**（`ps` 计数立即恢复 2）；死亡窗口 3 连发全 200（80/163/167ms），**零 5xx、零挂起**；重生后 debug 44 实锤重写恢复（`?after=1` 被改写为 tuna）。生产化无 helper 单点顾虑 |
| P6 vcjob 端到端（pip/go） | ✅ | **pip**：真实 `pip download requests==2.31.0` pass1 **5383ms → pass2 860ms**，wheel 落盘（pip 26.1.1，走 PEP 691 JSON 索引 `application/vnd.pypi.simple.v1+json`，tuna 兼容；hash 校验内置通过）；access.log：客户端 pod 10.0.0.209 的请求全部重写为 `pypi.tuna... HIER_DIRECT/101.6.15.130`。**go**：cann 镜像无 go 二进制，curl 线级对照三件套全 200——`.info`(142ms)/`.mod`(20ms)/`.zip`(61ms, 1.8MB) 全部经 `goproxy.cn HIER_DIRECT/113.125.253.29`（proxy.golang.org 的 Google egress 死结不经过）；wire 路径与 go mod download 等价（GPROXY 协议同构） |

### 7.3 中间结论

1. **假设成立：client-first 下 https 域 url_rewrite 复活**。修订⑥的 301/421 判死根因
   （PINNED 连接复用）只在 server-first 存在；client-first 重写后按新目的地新建 TLS 连接。
2. 缓存键为重写后 URL（tuna），确定性重写 → 键稳定可 HIT（P2 33ms 实证）。
3. 被重写域的 pypi-peer/go-peer（cache_peer originserver）在重写生效后**永不命中**
   （peer_select 先于重写？否——重写在 doCallouts，先于 peer_select；重写后 host=tuna 不匹配
   peer ACL）→ 转正时应从 values 摘除，避免双机制并存。
