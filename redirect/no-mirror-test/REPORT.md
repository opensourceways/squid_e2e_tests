# no-mirror-test 全量报告（2026-09-15，gy-006）

**目标**：验证「客户端零镜像配置 + squid url_rewrite 透明重写」端到端成立。
14 个 CI 工具 e2e 用例全部剥掉客户端镜像配置、改回官方默认源，由 squid（client-first bump + url_rewrite helper）在服务端透明重写加速。

**本轮结果：11 通过 / 2 失败（根因均已定位，与重写链路无关）/ 1 移除（不在重写范围）**

> 本轮跑在 chart 0.1.11 helper 上；下文"修复"一节含 0.1.12 已改待部署内容。

## 总览

| # | 用例 | 官方源 → 重写目标 | 结果 | 耗时 | 说明 |
|---|---|---|---|---|---|
| 01 | pip | pypi.org → huaweicloud pypi | ✅ | 82.4s | 含 torch 146MB 对象 + vllm requirements 批量下载 |
| 02 | apt | ports.ubuntu.com → huaweicloud | ✅ | 8.2s | apt-get update 2s |
| 03 | git clone | github.com（CONNECT 隧道，不重写） | ✅ | 4.7s | clone 直连官方 |
| 04 | go mod | proxy.golang.org → goproxy.cn | ❌ | — | go1.22 工具链解析缺陷（见下） |
| 05 | obs | —（已移除） | ➖ | — | obs-community 不在重写范围，测的是 AK/SK 凭证（403 InvalidAccessKeyId），与套件目标无关，用户拍板移除 |
| 06 | wget | download.openmmlab.com（官方直连） | ✅ | 0.6s | 白名单外原样放行不误伤 |
| 07 | cmake | github clone（不重写） | ✅ | 26.1s | googletest FetchContent 拉取+构建+测试通过 |
| 08 | bazel | github archive → gh-proxy | ✅ | 27.8s | WORKSPACE 全官方 URL，重写透明生效 |
| 09 | npm | registry.npmjs.org → npmmirror | ✅ | 5.7s | host 交换同构 |
| 10 | cargo | index.crates.io/static.crates.io → rsproxy | ✅ | 11.2s | sparse index + tarball 两端点 |
| 11 | conda | conda.anaconda.org/repo.anaconda.com → tuna | ❌ | — | squid 伪造证书缺 AKI，conda 26 严格 TLS 拒签（见下） |
| 12 | uv | pypi.org → huaweicloud | ✅ | 5.2s | |
| 14 | git-lfs | github releases → gh-proxy | ✅ | 4.1s | release 二进制 + LFS 对象 |
| 15 | pnpm | registry.npmjs.org → npmmirror | ✅ | 6.4s | |
| 16 | yum | repo.openeuler.org → huaweicloud | ✅ | 56.3s | 官方 repo + metalink |

（13-huggingface、17-docker-pull 按需求排除，见 TEST-WORKFLOW.md）

## 两个失败的确证根因（均非重写链路问题）

### ① tool-04 goproxy：go 1.22 的 GOTOOLCHAIN 解析缺陷

- 链路本身已实测通：access.log 实锤 `CONNECT proxy.golang.org` → bump → 重写 `goproxy.cn/golang.org/toolchain/...`，重写正确。
- 失败点：mind-cluster go.mod 要求 `go 1.26`，apt 的 golang-go **1.22.2** 对其请求**字面版本** `v0.0.1-go1.26.linux-arm64` → goproxy.cn 404。
- 探测实锤（goproxy.cn）：`v0.0.1-go1.26.linux-arm64` = **404（该 tag 上游不存在）**；`v0.0.1-go1.26.0.linux-arm64` = **200**；list 中 go1.26.0 全平台齐全。
- 结论：1.21 起 Go 发布版均为 X.Y.0，老 go 请求不存在的 `go1.26` 字面版本是老版 go 已知缺陷，任何 GOPROXY 都过不了这一步。
- **修复（已完成，待重跑）**：tool-04 改用官方 `https://go.dev/dl/go1.26.0.linux-arm64.tar.gz` 安装工具链；chart 0.1.12 helper 新增规则：`go.dev/dl/*`、`dl.google.com/go/*` → `mirrors.aliyun.com/golang/<file>`（路径同构、文件名唯一），配 immutable refresh_pattern。

### ② tool-11 conda：squid 伪造证书缺 Authority Key Identifier

- 链路本身已实测通：miniconda installer 196MB 经 repo.anaconda.com 重写 tuna，17.4s 下载完成。
- 失败点：conda 26.7.1（Python 3.13 严格 RFC 5280 校验）对 squid sslcrtd 签发的伪造证书报 `Missing Authority Key Identifier`，拒签。
- openssl 取证实锤：squid 签发的 `CN=conda.anaconda.org` 证书扩展区**只有 SAN，无 AKI/SKI**。
- 影响面：所有走严格 TLS 校验的客户端（新版 python ssl / conda / 可能的 go 1.26 工具链自身等）都会在 bump 后拒签——是 squid 层真实缺口，不只 conda。
- **状态：按用户要求暂不修**，留档待定方案（候选：squid 生成证书补 AKI 扩展 / conda 域 splice 放行 / 客户端 ssl_verify 关闭）。

## 修复状态

| 项 | 状态 |
|---|---|
| tool-04 改官方 go.dev/dl 安装 | ✅ 文件已改 |
| chart 0.1.12：helper 规则 5b（go.dev/dl、dl.google.com/go → aliyun golang）+ refresh_pattern | ✅ 已改，helm template 校验通过，**待 helm upgrade + rollout restart** |
| tool-05-obs 移除 + TEST-WORKFLOW 同步（15→14） | ✅ |
| conda AKI 证书缺口 | ⏸ 按用户要求暂不修，已留档 |
| 全量重跑（部署 0.1.12 后，重点 tool-04 / tool-11） | ⏳ 待部署后执行 |

## 方法论留档

- 运行方法：TEST-WORKFLOW.md §4.1（一键循环，逐 job 等待 + 摘要）
- 失败取证三板斧：pod 日志 → squid access.log（HIER_DIRECT 落点/状态码）→ 探针直测上游（goproxy.cn 版本探测、openssl 证书检查）
- 每个用例的剥离清单见 TEST-WORKFLOW.md §3
