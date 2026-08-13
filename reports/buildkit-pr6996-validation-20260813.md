# BuildKit 上游 PR #6996(env 变量式上游代理)端到端验证报告

**日期**:2026-08-13 · **验证人**:TommyLike + Claude
**结论先行**:功能正确、与我们的 Squid SSL-Bump 缓存场景完全兼容;无 cert 配置的设计下,
CA 信任经 `SSL_CERT_FILE` 走系统信任库,实测成立。PULL 与 RUN 共用一套 env 配置是
BuildKit 既有标准行为(非本 PR 引入),且与 `deploy/` 的 splice + registry-proxy 架构互补。

---

## 1. 背景

本仓库此前的 BuildKit 扩展(`buildkit/`)基于我们自己 fork 的实现
(`TommyLike/buildkit` `feature/upstream-proxy-config`,PR #1):在 `buildkitd.toml` 里用
`[proxy] upstreamURL + upstreamCACert` 把内置 exec 代理链到 Squid。

上游社区后来由 gmarmstrong 提了 **moby/buildkit#6996**
([network: chain proxy requests via upstream proxy](https://github.com/moby/buildkit/pull/6996)),
走**完全不同的路线**:

| | 本仓库 fork 方案 | 上游 #6996 |
|---|---|---|
| 配置载体 | `buildkitd.toml` 的 `[proxy]` 段 | buildkitd 进程**环境变量**(`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) |
| CA 信任 | `upstreamCACert` 显式指定文件 | **无 cert 配置**,信任下沉**系统信任库** |
| 覆盖范围 | 仅内置 exec 代理出站 | 同一 env 同时覆盖 exec 链 + 镜像拉取(后者为 BuildKit 既有行为) |

本报告用上游实现**重新编译镜像并做端到端验证**,判断它是否可替代我们的 fork。

## 2. 被测代码与镜像

- 代码:`gmarmstrong/buildkit` 分支 `proxy-chaining`(sha `e9606c76e0`,2 commits:实现 + docs 展开)
- 镜像:`tommylike/buildkit-6996:test`(241MB,`--target buildkit` 编译,含 buildkitd/buildctl/runc/cni)
- 依赖状态:#6996 依赖的 #6995(`FilterProxyEnv`)当时未合并;`ReplaceEnv` 等 helper 在本分支自包含,功能不受影响

编译命令:

```bash
git clone --depth 1 --branch proxy-chaining https://github.com/gmarmstrong/buildkit.git
cd buildkit
docker buildx build --target buildkit -t tommylike/buildkit-6996:test --load .
```

## 3. 测试配置(关键差异)

与 fork 版 `docker-compose.buildkit.yml` 的差异:上游代理从 `buildkitd.toml [proxy]` 段
→ **buildkitd 进程环境变量**;CA 信任从 `upstreamCACert` 显式配置 → **系统信任库**。

```yaml
environment:
  HTTP_PROXY:  "http://172.30.0.100:3128"   # Squid HA VIP
  HTTPS_PROXY: "http://172.30.0.100:3128"
  NO_PROXY:    "localhost,127.0.0.1,172.30.0.0/24"
  SSL_CERT_FILE: "/etc/buildkit/squid-ca.pem"  # ← 唯一的 CA 接入点(系统信任库)
```

- `buildkit/buildkitd-6996.toml`:只保留 `proxyNetwork = true`,**无 `[proxy]` 段**
- `buildkit/docker-compose.6996.yml`:完整部署定义(含精简 capabilities,与 fork 版同套)

代码正确性关键点:`newProxyTransport()` 的 `TLSClientConfig == nil` → Go 回退**系统证书池**
→ `SSL_CERT_FILE` 生效。这是"无 cert 配置"路线成立的代码依据(实测也确认,见 §4)。

## 4. 测试矩阵与结果

| 场景 | 配置 | 预期 | 实测 |
|---|---|---|---|
| **正对照** | `SSL_CERT_FILE` = Squid CA | 构建成功 | ✅ RUN 内 HTTPS 下载 200,RPM 14.9MB,proxy 捕获 `openeuler.org -> 200` |
| **缓存** | 同上,二次构建 | Squid `TCP_HIT` 增加 | ✅ 75 → 76 |
| **负对照** | 无 `SSL_CERT_FILE`(其余同) | RUN 步骤证书校验失败 | ✅ exec 代理对 Squid 重签证书校验失败 → 返回 **502**,apk 构建失败 |

负对照演进过程(记录以便复现):

1. **v1(全流量走代理)**:失败点在**镜像拉取**——`registry-1.docker.io` x509 失败。
   证明 env 方案下 daemon 自身 registry 流量也走上游 Squid,同样需要 CA 信任。
2. **v3(隔离 RUN 路径)**:`NO_PROXY` 加入 `docker.io,docker.com` 摘除镜像拉取
   (含 blob 重定向的 `production.cloudfront.docker.com`),失败点精确落在
   `RUN apk add` 步骤——exec 代理对 bump 证书校验失败返回 502。
   Squid 侧日志:CONNECT 隧道建立(`NONE_NONE/200`)但隧道内无 GET 记录(握手被拒)。

## 5. 关键结论

1. **功能正确**。env 变量生效、大小写优先级(`http.ProxyFromEnvironment` 标准行为)、
   `NO_PROXY` 语义、非法 URL fail-closed、凭证脱敏,均符合文档与设计。
2. **无 cert 配置 → 系统信任库,实测成立**。`SSL_CERT_FILE` 一路贯通:
   exec 信任内建代理(自动注入)→ 内建代理信任 Squid bump CA(系统池)→ Squid 回源。
3. **"PULL 也走代理"是收益不是问题**。buildkitd 尊重 proxy env 做镜像拉取是
   BuildKit **既有标准行为**,#6996 只是把同一约定延伸到 exec 链,一次配置同时解决
   PULL + RUN 两个场景。且与 `deploy/` 架构天然互补:
   - PULL → squid 对 registry 域 splice → cache_peer → registry-proxy 缓存镜像 blob(无需 CA)
   - RUN → squid bump → 缓存 apk/rpm/pip(需要 CA 进系统信任库)
4. **可替代我们的 fork**。env 方式更符合社区惯例、无定制配置面;fork 的
   `upstreamCACert` 旋钮在不可变镜像场景仍有便利性,但非必需。

## 6. 遗留建议(对上游 PR,不影响本结论)

1. `docs/proxy.md` 的 "Upstream proxies" 节**缺 CA 信任说明**:经 SSL-bump/私有 CA 上游
   做 HTTPS 缓存时,必须把代理 CA 预置进 buildkitd 系统信任库(`SSL_CERT_FILE` 或
   `update-ca-certificates`)。不写,用户照文档配置 HTTPS 缓存必踩 502(已在上游 PR 评论)。
2. 合并顺序:#6995(`FilterProxyEnv`)先合,再 de-dup 两边重复的 `ReplaceEnv` helper。
3. fail-closed 偏硬:上游 Squid 挂掉时所有 proxy-network exec 全部失败,无 soft-fail 选项,
   对"缓存可无、构建要能跑"的场景值得后续讨论。

## 7. 复现方法

```bash
# 1. 起主 Squid HA 环境
cd .. && ./scripts/setup.sh && cd buildkit

# 2. 编译镜像(或直接用 tommylike/buildkit-6996:test)
#    见 §2 编译命令

# 3. 启动 env 版 buildkitd
docker compose -f docker-compose.6996.yml up -d

# 4. 跑一次构建(正对照)
docker run --rm --network haproxy_ha_squid_net -v "$PWD:/work:ro" --entrypoint buildctl \
  tommylike/buildkit-6996:test --addr tcp://172.30.0.30:1234 build \
  --frontend dockerfile.v0 --local context=/work --local dockerfile=/work \
  --opt filename=Dockerfile.test \
  --opt build-arg:RPM_URL=https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm \
  --no-cache --progress plain

# 5. 验证 Squid 缓存命中(TCP_HIT 增加)与负对照(去掉 SSL_CERT_FILE 重建容器)
```
