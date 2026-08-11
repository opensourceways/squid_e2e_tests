# BuildKit 经 Squid 的 HTTPS 代理+缓存验证 — 设计

## 目标

验证：BuildKit 构建镜像时，`RUN` 指令内的 HTTPS 请求经由 Squid HA 完成**代理 + 缓存**。
复用现有 Squid HA 环境，新增 BuildKit 层。

## 已确认的决策

| # | 决策 | 结论 |
|---|------|------|
| A | 缓存范围 | **仅 RUN 指令流量**（FROM 基础镜像层不测，不在两个 PR 能力内） |
| B | 权限路线 | **rootful + 精简 cap（含 CAP_SYS_ADMIN）**，显式列出所需 cap 并 drop 其余，不用 privileged |
| C | 测试 URL | openEuler RPM（沿用现有 test.env） |
| — | BuildKit 分支 | `feature/upstream-proxy-config`（TommyLike/buildkit） |
| — | 拓扑 | **1 buildkitd daemon + 1 buildctl client**（简化） |

## 两个功能如何组合

**官方 proxy.md**：`proxyNetwork=true` 时，buildkitd 启动内置 MITM 代理，给 RUN exec 注入
`HTTP(S)_PROXY`，并**自动把自身生成的 CA 注入 build 信任库**。仅覆盖 RUN exec，不覆盖 FROM/git。

**PR #1（`[proxy]` 段）**：把内置 MITM 代理的出向流量再链到上游 Squid：
```toml
[proxy]
upstreamURL   = "http://172.30.0.100:3128"   # Squid VIP
upstreamCACert = "/etc/buildkit/squid-ca.pem" # Squid SSL Bump CA
```
仅在 `proxyNetwork=true` 时生效；配置错误 daemon 拒绝启动（不静默降级）。

## 三段 CA 信任链（方案成立的核心）

源码 `util/network/proxyprovider/provider_linux.go` 印证：

```
RUN curl https://origin/pkg.rpm       (build 沙箱内)
  │ ① RUN 进程信任 BuildKit 内置 MITM CA(ProxyCACert 自动注入 build 信任库)
  ▼
BuildKit 内置 MITM proxy (handleConnect: 伪造 origin 证书,拿到明文请求)
  │ ② transport.Proxy = upstreamURL(Squid);对 origin 发起真实 TLS,经 Squid CONNECT 隧道
  │    Squid SSL Bump 伪造 origin 证书 → BuildKit 用 upstreamCACert(=Squid CA)验证通过
  │    (代码注释确认: upstreamCACert 被加入验证 target 连接的 RootCAs)
  ▼
Squid HA (VIP) SSL Bump 解密 → 缓存明文 → 回源
  │ ③ Squid 用自签 CA 动态签发(已在 squid_ha 验证)
  ▼
origin
```

三段证书信任各自闭环，HTTPS 全链路可解密可缓存。

## 架构

```
buildctl client ──gRPC(--addr tcp://buildkitd:1234)──> buildkitd (1 daemon, rootful 精简cap)
                                                              │ RUN exec
                                                              ▼
                                                   内置 MITM proxy(注入CA+proxy env)
                                                              │ upstreamURL=http://172.30.0.100:3128
                                                              ▼
                                              现有 Squid HA (VIP) ─SSL Bump 缓存─> origin
```
buildkitd 容器接入现有 `haproxy_ha_squid_net`，直连 Squid VIP。Squid HA 一层不改。

## 权限设计（最小原则，已实证）

rootful buildkitd 不用 `privileged`。经**逐个移除 cap 的实证测试**（脚本见验证记录），
确定最小必需集为 **17 个 capability + 3 个 security-opt + 可写 cgroup**，移除任何一个构建即失败。

### 必需 capabilities（17，移除任一均失败）

**A. daemon 自身需要（3）**
| capability | 用途 |
|-----------|------|
| `SYS_ADMIN` | 挂载 overlayfs、创建 mount/net/pid namespace |
| `NET_ADMIN` | 配置 RUN 沙箱与 proxy netns 的 veth/netlink |
| `SYS_PTRACE` | runc mount remapping 需 open 容器 init 的 `/proc/<pid>/ns/mnt` |

**B. RUN 容器默认 cap 集（14，daemon 的 bounding set 必须包含，否则 runc 无法授予 RUN，报 `operation not permitted`）**
`CHOWN`、`DAC_OVERRIDE`、`FSETID`、`FOWNER`、`MKNOD`、`NET_RAW`、`SETGID`、`SETUID`、
`SETFCAP`、`SETPCAP`、`NET_BIND_SERVICE`、`SYS_CHROOT`、`KILL`、`AUDIT_WRITE`

### 必需 security-opt（相对 privileged 的等价补充）
| security-opt | 原因 |
|--------------|------|
| `apparmor=unconfined` | overlayfs/namespace 操作 |
| `seccomp=unconfined` | runc mount remapping / setns 被默认 seccomp 拦截 |
| `systempaths=unconfined` | 解除 `/proc` 屏蔽路径,runc 需访问 `/proc/<pid>/ns` |

### 必需挂载
- `cgroup: host` + `-v /sys/fs/cgroup:/sys/fs/cgroup:rw`：BuildKit RUN 需写 cgroup 子树，
  非 privileged 容器默认 `/sys/fs/cgroup` 只读。

### 与 privileged 的对比
`privileged` = 全部 40+ caps + 所有设备 + 无 seccomp/apparmor/systempaths 限制。
本方案 = 17 caps + 3 unconfined + cgroup rw，**显著收窄**（但 rootful buildkit 无法去掉 `SYS_ADMIN`）。

### 网络
sandbox 网络用 `net = "host"`（buildkitd.toml），确保 RUN 沙箱/代理出向能路由到 Squid VIP。

## 新增测试用例

| 编号 | 验证点 |
|------|--------|
| **07** buildkit-proxy | buildctl 构建含 `RUN curl https://<rpm>` 的镜像，构建成功（证明 RUN HTTPS 经 Squid 通） |
| **08** buildkit-cache | 清 buildkit 构建缓存(`--no-cache`)保留 Squid 缓存 → 二次构建 Squid access.log 出现 TCP_HIT |
| **10** buildkit-caps | 精简 cap 集能构建成功；移除 CAP_SYS_ADMIN 后构建失败（证明最小性） |

（09 多 daemon 已按简化决策取消。）

## 目录结构

```
buildkit/
├── DESIGN.md                    ← 本文件
├── src/                         ← clone 的 PR 分支(git 忽略,不入库)
├── image/                       ← 构建 buildkitd 镜像的说明/脚本
├── buildkitd.toml               ← proxyNetwork + [proxy] 配置
├── docker-compose.buildkit.yml  ← buildkitd 服务(精简 cap)
├── Dockerfile.test              ← 测试镜像(RUN curl https)
└── tests/
    ├── 07-buildkit-proxy.sh
    ├── 08-buildkit-cache.sh
    └── 10-buildkit-caps.sh
```

## 可行性验证结论（已全部通过）

| 风险点 | 结果 |
|--------|------|
| 从 PR 构建镜像 | ✅ 构建成功,推送至 `tommylike/buildkit-upstream-proxy:latest` |
| RUN HTTPS 经 Squid | ✅ Squid access.log 出现 `CONNECT origin:443` + `GET https://... TCP_MISS/HIT` |
| SSL Bump 缓存对 BuildKit 生效 | ✅ 二次构建 `TCP_HIT`,证明缓存命中 |
| 最小权限(非 privileged) | ✅ 17 caps 实证最小,去 SYS_ADMIN 即失败 |

端到端链路(RUN → BuildKit MITM → Squid SSL Bump → 缓存)完整跑通,3 项扩展测试全部通过。

## 运行方式（扩展场景,默认不随主套件）

```bash
# 前置: 主 Squid HA 已启动
../scripts/setup.sh

# 运行 BuildKit 扩展测试(自动起停 buildkitd)
./run-tests.sh
```

## 参考

- 官方 proxy 文档: buildkit/docs/proxy.md（PR 分支内）
- PR 实现: `util/network/proxyprovider/provider_linux.go`、`cmd/buildkitd/config/config.go`
- 现有 Squid HA: 见上级 `../solution.md`、`../PRODUCTION.md`
