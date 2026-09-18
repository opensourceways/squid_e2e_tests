# AKI 版本矩阵测试流程（gy-006，2026-09-16）

## 目标

实证「**哪些 TLS 栈版本会对 squid 伪造证书（缺 AKI）报错，哪些不报**」，
定位 conda 26 踩雷的准确版本边界，而非停留在推断。

## 背景结论（待矩阵验证）

- squid（client-first bump，无 mimic 源）伪造的叶子证书**只有 SAN、无 SKI/AKI**
- 我们自签 CA（SquidCacheCA）本身 SKI/AKI 齐全，与问题无关
- RFC 5280 中 AKI 为 SHOULD：宽松校验（openssl 默认 / Python ≤3.12）不查 → 通过
- Python 3.13 起 `ssl` 默认启用 `VERIFY_X509_STRICT` → 缺 AKI = error 85 拒签
  （conda 26.7.1 内置 Python 3.13，报错 `Missing Authority Key Identifier`）

## 测试矩阵

| # | 栈 / 版本 | 校验模式 | 预期 | 依据 |
|---|---|---|---|---|
| 1 | openssl CLI 3.0.13（noble 系统自带） | 默认 verify | ✅ OK | 宽松：不查 AKI |
| 2 | openssl CLI 同上 | `-x509_strict` | ❌ error 85 | strict：AKI 必查（RFC 5280 MUST 化） |
| 3 | **Python 3.10**（uv / python-build-standalone） | `create_default_context()` | ✅ PASS | 无 strict 默认 |
| 4 | **Python 3.11**（同上） | 同上 | ✅ PASS | 同上 |
| 5 | **Python 3.12**（同上；ubuntu 24.04 系统 python 同版） | 同上 | ✅ PASS | 3.13 之前无 strict 默认 |
| 6 | **Python 3.13**（同上；conda 26 内置即此版） | 同上 | ❌ Missing AKI | 3.13 默认开 VERIFY_X509_STRICT |
| 7 | **Python 3.14**（同上；`uv python install 3.14` 运行时动态取该系列最新 patch，**不写死 patch 号**；3.14 为当前最新稳定系列，**2026-09-16 实测 = 3.14.7**） | 同上 | ❌ 同 3.13 | strict 默认延续 |
| 8 | Python 3.13/3.14 同上 | 显式关 strict | ✅ PASS | 证明错因 = strict 标志本身 |
| 9 | node **最新 LTS**（`nodejs.org/dist/index.json` 运行时动态取，**不写死版本号**；npm 的 TLS 栈，自带 openssl；**2026-09-16 实测 = v24.21.0 Krypton**） | `tls.connect` | ✅ PASS | node 默认不开 strict |
| 10 | go 1.24（apt）+ **最新 stable**（`go.dev/dl/?mode=json` 运行时动态取，**不写死版本号**；**2026-09-16 实测 = 1.27.1**） | `crypto/x509 Verify` | ✅ PASS | go 校验器不要求叶子 AKI |
| 11 | **rustls 最新**（rustup 装 stable，运行时动态取**不写死版本号**，**2026-09-16 实测 stable 通道 = 2026-09-03 快照**；`cargo add rustls` 不带版本号 = crates.io 最新，**2026-09-16 实测 = 0.23.45** + `WebPkiServerVerifier` 直校） | 离线 verify | ❓ 实测定 | ⚠️ tool-10 cargo ✅ 不算数：cargo 下载走 libcurl（系统 openssl），非 rustls |

> 每个用例都用**同一对证书**：squid 实际签发的伪造叶子（活体抓取）+ 自签 CA。
> - python 3.10–3.14 用 **uv python install** 装（github releases → squid 重写 gh-proxy，
>   tool-08 已实证），不用 conda 自举（conda 自身 TLS 正是待测问题）
> - node v24 / go 最新 / rustup 从官方分发点直下（bump 假证书 → 先把抓到的
>   squid CA 注入系统信任，`update-ca-certificates`）

## 执行步骤（aki-01-versions.yaml，单 vcjob，kubectl create——generateName 不能 apply）

1. 取证：pod 内 `openssl s_client -proxy squid-cache:3129` 活体抓取 bump 链
   （leaf=伪造证书，CA=SquidCacheCA），awk 按 BEGIN/END 切片落盘；确认 leaf AKI=0
2. squid CA 注入（**标准配方，对齐 tool-08**）：secret `squid-ca-cert` 挂载
   `/etc/squid-ca/squid-ca.pem` + pod 级 env 六件套（SSL_CERT_FILE 等）+ postStart
   `update-ca-certificates`；后续所有 https 下载（含 uv 的 rustls）均经 bump 假证书
3. openssl：默认 verify / `-x509_strict` verify 各跑一次（矩阵 1/2）
4. uv 最新版 → `uv python install 3.10 3.11 3.12 3.13 3.14` → 逐个跑 `aki_check.py`：
   CONNECT 隧道过 squid 真实 bump 路径，`create_default_context()` 握手（矩阵 3–7）；
   3.13/3.14 再以 `verify_flags &= ~VERIFY_X509_STRICT` 复跑（矩阵 8）。
   **下载必须带重试**（见「运行记录」首轮失败教训）：uv tarball 用
   「下载→`tar tzf` 校验→失败删档重试」循环（≤5 次），`uv python install` 失败整条重试一次
5. node 最新 LTS 官方 tarball（index.json 动态取）→ `aki_node.js`（矩阵 9）
6. go apt 1.24 与 go.dev/dl 最新版各跑 `aki_go.go`（矩阵 10）
7. rustup 装 stable → cargo 建 rustls 0.23 工程 → `WebPkiServerVerifier.
   verify_server_cert()` 直校伪造叶子（矩阵 11）
8. 汇总打表 + 断言：预期全命中输出 `MATRIX CONFIRMED`，否则
   `MATRIX MISMATCH` 且 exit 1

## 判定标准

- **矩阵成立**（预期全命中）→ conda 踩雷边界锁定为「Python 3.13 默认 strict」，
  所有 ≤3.12 TLS 栈 + openssl 默认 + go 均不报
- **矩阵不成立**（如 3.12 也报 / 3.13 不报）→ 修正归因，重新定位版本边界

## 运行记录

### 2026-09-16 第 1 轮（job test-aki-versions-xrqkp）——矩阵 1/2 实证，python 组因下载抖动作废

- **矩阵 1/2 已实证**：openssl 默认 verify `PASS`、`-x509_strict` `FAIL`（叶子 AKI=0 前提确认），
  与预期一致。
- **python 3.10–3.14 组作废**：uv tarball 下载抖动。access.log 实锤：
  1. `github.com/.../releases/latest/download/...` 302（直连 github）→ 重定向目标被 squid
     规则 2/3 重写到 gh-proxy，`200 18MB octet-stream`（第 1 次尝试实际拿到真包）；
  2. Volcano `maxRetry` 触发整体重跑后，302 这一直连跳变 `TCP_MISS_ABORTED/502`（squid→github
     直连抖动），curl 把 squid 502 HTML 错误页存成 `uv.tgz` → `tar: not in gzip format` →
     `uv: command not found` → python 组全跳过。
- **教训**：github 直连跳（302/api）不经 gh-proxy，是套件里唯一无重写覆盖的脆弱点，
  所有 curl 必须自带「校验+重试」；不能依赖 Volcano maxRetry（整体重跑反而放大抖动暴露面）。
- **修复**：yaml 中 uv 下载改为「`curl` → `tar tzf` 校验 → 失败删档重试 ≤5 次」，
  `uv python install` 失败整条重试一次；其余步骤不变。

### 2026-09-16 第 2 轮（job test-aki-versions-dlh7d）——uv 本体修复生效，python 安装需 SSL_CERT_FILE

- ✅ 重试生效：uv tarball 下载成功（uv 0.12.15），openssl 矩阵 1/2 再次实证
  （default PASS / strict FAIL）。
- ❌ `uv python install` 全线失败：`error sending request for url
  （github.com/astral-sh/python-build-standalone/releases/...）`。
- **根因**：uv 的 TLS 栈是 **rustls + 内置 webpki-roots（Mozilla 根）**，默认**不读系统信任库**
  ——第 1b 步注入的系统 CA 对 curl/apt 生效，对 uv 无效；bump 假证书不在其内置根里 → 拒签。
- **修复（终版，对齐 tool-08 标准注入配方）**：不再在脚本中途手工注入，改为 pod 级标准配方——
  ① secret `squid-ca-cert` 挂载 `/etc/squid-ca/squid-ca.pem`；② pod 级 env 六件套
  （`SSL_CERT_FILE`/`CURL_CA_BUNDLE`/`REQUESTS_CA_BUNDLE`/`GIT_SSL_CAINFO`/`PIP_CERT`/
  `NODE_EXTRA_CA_CERTS` 全指 `/etc/squid-ca/squid-ca.pem`，**uv 依赖其中的 SSL_CERT_FILE**）；
  ③ postStart `update-ca-certificates` 注入系统信任。CA 自容器启动即就位，对任何客户端零窗口期。
- **矩阵意义**：node/go/rustls 各步不受影响，照常采集；python 组待第 3 轮。
- **另发现卡死点**：node 步骤打印版本号后 15 分钟无输出——node tarball 的 curl 无重试、
  `aki_node.js` 的 TLS 连接无超时，squid 连接挂起即永久等待（直至 activeDeadline 2400s）。
- **第 3 轮修复**：yaml 全面稳健化——所有 curl（node/go/rustup/uv）统一「校验+重试 ≤5 次」；
  `aki_node.js` 加 30s 超时；CA 注入改 pod 级标准配方（见上）。

### 2026-09-16 第 3 轮（job test-aki-versions-kx99z，Succeeded）——矩阵核心确认

标准注入配方生效，python 组首次完整落地：

| 矩阵项 | 结果 | 与预期 |
|---|---|---|
| openssl default / strict | PASS / FAIL（error 85） | ✅ 一致 |
| python 3.10 / 3.11 / 3.12 default | 全 PASS（nostrict 也 PASS） | ✅ 一致 |
| **python 3.13 default** | **FAIL**（nostrict PASS → 错因=strict 标志实证） | ✅ **边界锁定 3.13** |
| **python 3.14 default** | **FAIL**（nostrict PASS） | ✅ strict 延续 |
| node v24.21.0 | PASS | ✅ 一致 |
| go 1.24(apt) | PASS | ✅ 一致 |
| go latest | ❌ 数据缺口 | 见下 |
| rustls latest | ❌ 数据缺口（输出为空） | 见下 |

- **go latest 缺口根因**：`go.dev/dl/?mode=json` 被 chart 0.1.12 的 `go.dev/dl/*` 重写规则命中
  → 落到 mirrors.aliyun.com 返回 **HTML 目录页** → node JSON.parse 炸 → GOF 空 → 下载/安装全空。
- **修复**：不依赖 JSON API，改从（重写后的）`go.dev/dl/` 目录页
  `grep -oE 'go1[0-9.]+\.linux-arm64\.tar\.gz' | sort -V | tail -1` 解析最新版。
- **rustls 缺口根因**：`cargo run --quiet 2>/dev/null` 把编译/运行错误一并丢弃，RSOUT 空——
  无法区分 PASS/FAIL。
- **修复**：保留 cargo 全部输出（`CARGOLOG=$(cargo run 2>&1)`），先 `tail -5` 打印再 grep RESULT；
  `cargo add` 的输出也不再静默。
- **python FAIL 原因串顺手增强**：default FAIL 时取 stderr 最后一行入档（第 3 轮括号里为空
  是因为 grep 模式没对上实际错误文本；边界结论不受影响，nostrict-PASS 对比已实证错因）。

### 2026-09-16 第 4 轮（job test-aki-versions-jtqb8，Succeeded）——go latest 补齐，仅剩 rustls 编译错误

- ✅ **go latest = go1.27.1 PASS**（目录页 grep 解析生效）。
- ✅ **python FAIL 原因串实锤**：`ssl.SSLCertVerificationError: [SSL:
  CERTIFICATE_VERIFY_FAILED] certificate verify failed: Missing Authority Key Identifier`
  （3.13/3.14 完全一致；nostrict 全 PASS）。
- ❌ rustls 编译失败（E0277×n + E0599）：`UnixTime` 在最新 rustls-pki-types 不再实现
  `TryFrom<SystemTime>`；且 ubuntu:24.04 无 gcc，rustls 默认 provider aws-lc-rs 可能编不过。
- **第 5 轮修复**：① `UnixTime::since_unix_epoch(dur)` 替代 TryFrom；② apt 补
  `build-essential cmake`（aws-lc-rs 依赖）；③ cargo 日志 tail 提到 30 行防再盲。

### 2026-09-16 第 5 轮（job test-aki-versions-chrn5，Succeeded）——rustls 编译错剩 2 个，API 改名

- 其余全部复现一致（python 边界/node/go 均稳定）。
- rustls 剩 2 个 E0599，rustls-pki-types 1.15.1 实锤：
  ① `CertificateDer::pem_file` 已改名 `from_pem_file`；
  ② `verify_server_cert` 来自 `ServerCertVerifier` trait，必须 `use rustls::client::danger::ServerCertVerifier`。
- **第 6 轮修复**：main.rs 改名 + 加 trait import，其余不动。

### 2026-09-16 第 6 轮（job test-aki-versions-56p2g，Succeeded）——矩阵全绿

- `CertificateDer::from_pem_file` + `ServerCertVerifier` import 修复后编译通过，
  **rustls 0.23.45 PASS** → 矩阵 12 项全部落地，`MATRIX CONFIRMED`。
- 最终判定见 RESULTS.md：**conda 踩雷边界 = Python 3.13 默认 strict**；
  rustls/node/go 均不查叶子 AKI；uv 失败定性为信任库问题而非 AKI。

## 结果

已回填：见本目录 **RESULTS.md**（2026-09-16 矩阵全绿，MATRIX CONFIRMED）。
