# BuildKit 经 Squid 代理+缓存（扩展场景）

**这是可选扩展场景，默认不随主测试套件运行。**

验证：BuildKit 构建镜像时，`RUN` 指令内的 HTTPS 请求经 BuildKit 内置 MITM 代理链到上游
Squid HA，完成**代理 + SSL Bump 缓存**。

## 依赖的 BuildKit 功能

结合两个功能（缺一不可）：

1. **官方内置代理**（`proxyNetwork=true`）：给 RUN exec 注入 `HTTP(S)_PROXY` 并自动注入 CA。
   文档：BuildKit `docs/proxy.md`
2. **上游代理配置**（本 PR 新增 `[proxy]` 段）：把内置 MITM 代理链到 Squid。
   - PR：https://github.com/TommyLike/buildkit/pull/1
   - 分支：https://github.com/TommyLike/buildkit/tree/feature/upstream-proxy-config

预构建镜像已推送，无需自行编译：`tommylike/buildkit-upstream-proxy:latest`
（自行构建见 `image/README.md`）

## 快速开始

```bash
# 1. 先启动主 Squid HA 环境(在上级目录)
cd .. && ./scripts/setup.sh && cd buildkit

# 2. 运行 BuildKit 扩展测试(自动起停 buildkitd)
./run-tests.sh
```

## 三段 CA 信任链（方案核心）

```
RUN curl https://origin (build 内)
  │ ① 信任 BuildKit 内置 MITM CA(自动注入 build 信任库)
  ▼
BuildKit 内置 MITM proxy
  │ ② 经 upstreamURL 链到 Squid;信任 Squid CA(upstreamCACert)
  ▼
Squid HA (VIP) SSL Bump 解密 → 缓存 → 回源
```

关键：`buildkitd.toml` 的 `upstreamCACert` 必须是 Squid 的自签 CA（`../configs/certs/client-ca.crt`）。

## 权限（rootful，非 privileged，已实证最小）

17 个 capability（移除任一构建即失败）+ 3 个 unconfined security-opt + 可写 cgroup。
详见 `DESIGN.md` 权限设计章节。测试 `10-buildkit-caps.sh` 实证：去掉 `SYS_ADMIN` 构建失败。

## 测试用例

| 编号 | 验证点 |
|------|--------|
| 07 | RUN HTTPS 经 Squid 代理，构建成功，proxy 捕获请求 |
| 08 | 二次构建 Squid 缓存命中（TCP_HIT 增加） |
| 10 | 最小权限实证（移除 SYS_ADMIN 构建失败） |

## 目录

```
buildkit/
├── README.md                    ← 本文件
├── DESIGN.md                    ← 设计与信任链、权限实证
├── buildkitd.toml               ← proxyNetwork + [proxy] upstreamURL/CACert
├── docker-compose.buildkit.yml  ← buildkitd(精简 cap)
├── Dockerfile.test              ← 测试镜像(RUN curl https)
├── run-tests.sh                 ← 扩展测试入口(起停 buildkitd + 跑用例)
├── image/README.md              ← 如何自行编译镜像
├── src/                         ← clone 的 PR 源码(git 忽略)
└── tests/
    ├── 07-buildkit-proxy.sh
    ├── 08-buildkit-cache.sh
    └── 10-buildkit-caps.sh
```
