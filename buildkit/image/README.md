# BuildKit 镜像（含上游代理支持）

测试默认使用预构建镜像，**无需自行编译**：

```
tommylike/buildkit-upstream-proxy:latest
```

该镜像从下面的 BuildKit fork/PR 编译，新增 `[proxy]` 上游转发代理配置：

- 分支: https://github.com/TommyLike/buildkit/tree/feature/upstream-proxy-config
- PR: https://github.com/TommyLike/buildkit/pull/1
- 官方内置代理文档: `docs/proxy.md`（PR 分支内）

## 如需自行构建

```bash
git clone --depth 1 --branch feature/upstream-proxy-config \
  https://github.com/TommyLike/buildkit.git src
cd src
docker buildx build --target buildkit -t buildkit-upstream-proxy:local --load .
```

构建产物包含 `buildkitd` + `buildctl` + `runc` + cni 插件。默认 `buildkit` target 为 rootful 变体。

验证:
```bash
docker run --rm --entrypoint buildkitd buildkit-upstream-proxy:local --help | grep proxy-network
docker run --rm --entrypoint buildctl  buildkit-upstream-proxy:local --version
```
