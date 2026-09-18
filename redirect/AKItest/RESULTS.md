# AKI 版本矩阵测试结果（2026-09-16，gy-006，最终轮 job test-aki-versions-56p2g）

## 一句话结论

**squid client-first bump 伪造证书缺 AKI，只挡「OpenSSL 系 + RFC 5280 strict 校验」的客户端——
实测唯一踩雷族是 Python 3.13+（`ssl` 默认开 `VERIFY_X509_STRICT`，conda 26 即此类）；
node / go / rustls / 旧版 Python / openssl 默认全部不报。**

## 版本矩阵（全部同证书：活体抓取的伪造叶子（AKI=0）+ SquidCacheCA）

| # | 栈（执行时实测确切版本） | 校验模式 | 结果 | 依据/说明 |
|---|---|---|---|---|
| 1 | openssl 3.0.13（noble 系统自带） | 默认 verify | ✅ PASS | 宽松：不查 AKI |
| 2 | openssl 3.0.13 同上 | `-x509_strict` | ❌ FAIL（error 85） | strict 把 RFC 5280 SHOULD 当 MUST |
| 3 | Python 3.10.21（uv/python-build-standalone） | `create_default_context()` | ✅ PASS | 3.13 前无 strict 默认 |
| 4 | Python 3.11.16（同上） | 同上 | ✅ PASS | 同上 |
| 5 | Python 3.12.14（同上） | 同上 | ✅ PASS | 同上 |
| 6 | **Python 3.13.x**（同上；conda 26 内置即此族） | 同上 | ❌ **FAIL：`Missing Authority Key Identifier`** | **3.13 默认开 VERIFY_X509_STRICT** |
| 7 | Python 3.14.x（同上，当前最新稳定系列 = 3.14.7 系） | 同上 | ❌ FAIL 同 3.13 | strict 默认延续 |
| 8 | Python 3.13 / 3.14 | 显式关 strict | ✅ PASS | **错因 = strict 标志本身，实证** |
| 9 | node v24.21.0 Krypton（最新 LTS，npm 的 TLS 栈） | `tls.connect` | ✅ PASS | node 默认不开 strict |
| 10 | go 1.24.4（apt） | `crypto/x509 Verify` | ✅ PASS | go 不要求叶子 AKI |
| 11 | go 1.27.1（最新 stable） | 同上 | ✅ PASS | 同上 |
| 12 | rustls 0.23.45（rustc 1.98.1，`WebPkiServerVerifier` 直校） | webpki verify | ✅ **PASS** | **webpki 不要求叶子 AKI** |

（#1–2、3–12 分别在第 3–6 轮多次复跑，结果一致。）

## 关键推论

1. **conda 26 踩雷边界锁定**：conda 内置 Python 3.13 → 严格校验 → 缺 AKI 拒签。
   任何内置 Python ≥3.13 的工具（新版 pip/uv 直连模式等）同理踩雷。
2. **rustls PASS 的意义**：
   - 矩阵 11 排除「Rust 系全线拒签」担忧——cargo（libcurl/openssl）、rustls 系工具均不受缺 AKI 影响；
   - **给第 2 轮 uv 失败定性**：uv（rustls + 内置 webpki-roots）当时失败是**信任库不含 squid CA**
     （UnknownIssuer），不是 AKI——补 `SSL_CERT_FILE` 后 uv 即恢复正常下载（第 3 轮起 python 组全跑通）。
3. **修复方向启示**（conda AKI 缺口）：
   - **squid 侧给伪造证书补 AKI 扩展**是最彻底解——一次修复覆盖未来所有 strict 化的客户端
     （Python ssl 只是第一个，其他栈后续 strict 化是趋势）；
   - 替代方案：conda 域 splice 放行（失去 bump 上的重写/缓存能力）或客户端关校验（不可接受）。

## 运行轮次（同日 6 轮，详见 TEST-WORKFLOW.md 运行记录）

| 轮次 | job | 结果 |
|---|---|---|
| 1 | test-aki-versions-xrqkp | openssl 1/2 实证；uv 下载抖动（github 302 直连跳 502），python 组作废 |
| 2 | test-aki-versions-dlh7d | 重试生效；暴露 uv 内置 webpki-roots 不读系统信任；node 步骤无超时卡死 |
| 3 | test-aki-versions-kx99z | 标准注入配方（tool-08 配方）生效，python 组完整落地：**3.13 边界确认**；go latest/rustls 缺数据 |
| 4 | test-aki-versions-jtqb8 | go1.27.1 PASS + python FAIL 原因串实锤；rustls 编译错（API 改名） |
| 5 | test-aki-versions-chrn5 | rustls 剩 2 个 E0599（pem_file 改名 / trait 未导入） |
| 6 | test-aki-versions-56p2g | **rustls 0.23.45 PASS，矩阵全绿，MATRIX CONFIRMED** |

## 工程沉淀（yaml 已内置，后续可复用）

- squid CA 注入必须用 pod 级标准配方（secret 挂载 + env 六件套 + postStart 系统信任），
  脚本中途手工注入会漏掉不读系统信任库的客户端（uv 实锤）；
- 所有 curl 下载「校验 + 重试 ≤5 次」：github 302 直连跳是套件唯一无重写覆盖的脆弱点；
- `go.dev/dl/?mode=json` 会被 go.dev/dl 重写规则命中返回 HTML——版本解析从（重写后的）
  目录页 grep；
- JS/网络脚本一律 `timeout` 包裹，防 squid 连接挂起导致 pod 空等到 activeDeadline。
