# squid-aki 修复方案（2026-09-16）

> 前置证据：[../AKItest/RESULTS.md](../AKItest/RESULTS.md)——缺 AKI 实测只挡 Python 3.13+
> （OpenSSL `VERIFY_X509_STRICT`，conda 26 即此类）；node/go/rustls/旧版 python 全不查。

## 1. 「有没有开关」——没有（源码实锤）

线上 squid **7.7.1**（自编译，`/usr/local/squid`）。对照 master 源码 `src/ssl/gadgets.cc`
（7.7.1 与 master 该段一致），证书生成路径：

```
generateFakeSslCertificate → signServerCertificate
  └─ if (properties.mimicCert.get())          // ← 门
       └─ mimicExtensions(cert, mimicCert, signWithX509)
            └─ mimicAuthorityKeyId(cert, mimicCert, issuerCert)
                 └─ if (!mimicCert || !issuerCert) return false;   // ← 双重短路
```

- `mimicCert` = **origin 真证书**。server-first / peek 后 bump 时 squid 已连 origin、
  手里有真证书 → mimic 路径开启，AKI 会从真证书抄过来。
- **client-first bump：不连 origin、没有真证书** → `mimicCert` 为空 → 整条 mimic 门不进
  → 生成的证书只有 CN/SAN，永远无 AKI。
- `sslcrtd_program`/`security_file_certgen` 的参数、`http_port` 的
  `generate-host-certificates=` 等所有配置项，**没有一个能改变这个行为**。

结论：这是上游代码结构行为，**唯一彻底解是打补丁**。

## 1.1 上游/社区现状调研（2026-09-16 互联网检索）

- **squid 上游无修复**：检索 squid bugzilla/GitHub/security advisory，没有任何针对
  「client-first 生成证书缺 AKI」的 issue、PR 或配置项。上游对 AKI 的唯一处理路径
  就是 mimic（连 origin 抄真证书）——与我们源码实锤一致。**没有现成 patched 镜像**。
- **生态先例印证补丁方向正确**：
  - mitmproxy（同类 MITM 代理）默认 `upstream_cert=true` 连上游取真证书再 mimic；
    关闭后生成 generic 证书——与 client-first 同一 tradeoff，其证书生成层（pyOpenSSL）
    自带完整扩展（AKI/SKI），所以 strict 客户端不受影响。squid 的生成层没做到这一步。
- **Python 3.13 strict 化的普遍影响 + 社区标准修法（证据链）**：
  - 官方依据：Python 3.13 起 `ssl.create_default_context()` 默认启用
    `VERIFY_X509_PARTIAL_CHAIN + VERIFY_X509_STRICT`（[What's New in 3.13](https://docs.python.org/tr/3.14/whatsnew/3.13.html)）；
  - 普遍现象实例①：VCR.py 项目在 3.13 下 CI 全线挂
    `Missing Authority Key Identifier`，根因是 pytest-httpbin 的硬编码自签名证书
    缺 AKI；**上游修复 = pytest-httpbin 2.1.0 改用 trustme 动态生成带完整扩展
    （含 AKI）的证书**——「签发方补 AKI」的真实项目级先例
    （[VCR.py 3.13 问题解析](https://blog.gitcode.com/41df868dd99b02cf08c50780a1944e89.html)）；
  - 普遍现象实例②：自签名 CA 链 3.13 升级后报同错，社区修法 = 按 v3_ca 规范
    重新生成 CA（补全 keyUsage/AKI/SKI 扩展），`openssl verify -x509_strict` 转 OK
    （[you9you 笔记 2025-01](https://you9you.github.io/20250106/python3.13_x509_strict/)）；
  - 普遍现象实例③：Zscaler（企业级 MITM 代理）的证书同样过不了 3.13 strict
    （`Basic Constraints of CA cert not marked critical`），官方论坛归因于
    strict 化对拦截代理证书的合规要求收紧
    （[discuss.python.org](https://discuss.python.org/t/python-3-13-x-ssl-security-changes/91266/1)）；
  - 结论：社区共识修法是**给签发链（CA/签发方）补全扩展**，而非客户端关校验——
    方案 A「squid 签发伪造证书时补 AKI」与之同一思路。
- 互联网上对 squid 该问题的"解"只有三类：换 server-first（我们实测 pin 判死）、
  客户端关校验（否决）、自建 patch（即方案 A，未见公开实现）。

### 3.2 mimic 依赖矩阵（无真证书时各字段下场，逐行带证据）

前提：mimicCert = origin 叶子证书（公开可取，非 CA/私钥），唯一来源 = 连 origin 做
TLS 握手（peek step2 / server-first）。没有它，`generateFakeSslCertificate` 的
buildCertificate 全部 mimic 分支被跳过，各字段下场如下：

| 字段 | mimic 时来源（证据） | 无真证书下场 | 实测证据 |
|---|---|---|---|
| AKI 扩展 | origin AKI 决定形状（有 keyid→写 keyid），**值**取 issuerCert=signWithX509 的 SKI/名字/序列号（[gadgets.cc:363-411](https://github.com/squid-cache/squid/blob/master/src/ssl/gadgets.cc)，本地 self-squid 同版） | **不写**（:360-361 `!mimicCert→return false`，走不到写 AKI 段） | Python 3.13/3.14 default 报错原文 `Missing Authority Key Identifier`（AKItest RESULTS.md 矩阵 #6/#7）；openssl 抓取的伪造证书扩展区仅 SAN，无 AKI/SKI（no-mirror REPORT.md ②） |
| keyUsage / EKU / basicConstraints | origin 证书逐字抄（mimicExtensions 静态表 NID_key_usage/ext_key_usage/basic_constraints，gadgets.cc:440-506） | **全没有**（同被 :360-361 与 :658-680 的 `if (mimicCert)` 门挡住） | openssl 取证：扩展区无 keyUsage/EKU（同上）；但 node/go/rustls/openssl-default 对此**不校验**，全 PASS（RESULTS.md #9/#10/rustls）→ 非阻断项 |
| Subject CN / SAN | SAN 从 origin 抄（:668-677），仅当未配置 setCommonName | CN 取自 CONNECT/SNI（:620-625 `replaceCommonName(cert, properties.commonName)`），SAN=CN（:682-683 `addAltNameWithSubjectCn`） | 全矩阵客户端 hostname 校验均过 → SNI+CN 路径「凑合能过」实证 |
| 有效期 notBefore/notAfter | origin 优先（:633-634,:645-646），无 origin 用 CA 窗口（:635-636,:647-648），再退默认 -2d/+3y（:641,:652） | 落到 CA 窗口或默认值 | 无客户端校验此差异（矩阵全绿佐证） |
| 签发者 DN / 签名 | 固定 signWithX509（:715-716,:725-728），与 mimicCert 无关 | 不变（本来就是 SquidCacheCA） | openssl 取证 issuer=CN=SquidCacheCA |

结论行：mimic 缺失造成的**唯一阻断项是 AKI**（其余缺口实测无客户端拦），
而 AKI 值构造段（gadgets.cc:374-430）只依赖 issuerCert（自家 CA，手里就有）——
这就是方案 A「解锁 AKI 段给 client-first」的完整证据闭环。

**「openssl strict 对缺 KU/EKU/BC/SKI 怎么办」——A/B 仿真实锤（2026-09-16，本地 OpenSSL 3.6.4）**：
- 真链 strict 验证：`openssl verify -x509_strict` 对线上伪造叶子只报一刀
  `error 85 at 0 depth lookup: Missing Authority Key Identifier`（depth 0=叶子）；
  **SquidCacheCA 自身 strict 全绿**（BC critical/KU critical/SKI/AKI 齐，单独验证 OK）。
- A/B 仿真（python cryptography 精确控扩展，复刻叶子=仅 SAN）：
  ① 仅 SAN 叶子 → strict 报 error 85（与真链完全一致，交叉验证成立）；
  ② **同一叶子只补 AKI → strict OK** ⇒ 叶子缺 KU/EKU/BC/SKI 不会被 strict 拦
  （RFC 5280 的 BC-critical/SKI 强制项只针对 CA 证书；叶子上的 SHOULD 项
  strict 不查 presence，只在存在时查一致性）。
- ⇒ **补丁只需加 AKI 一个扩展，整条链即过 openssl strict = Python 3.13
  VERIFY_X509_STRICT（同一引擎）**，KU/EKU/BC 缺失无需补。
- **Python 3.14.7 端到端复核**（/tmp/aki-sim/pyssl_test.py，真 ssl 栈 TLS 握手）：
  ① 仅 SAN 叶子 → `SSLCertVerificationError: Missing Authority Key Identifier`；
  ② 同叶子 +AKI → **TLS 握手成功**（TLS_AES_256_GCM_SHA384）。
  Python 3.13/3.14 的 create_default_context 默认 verify_flags 含
  VERIFY_X509_PARTIAL_CHAIN|VERIFY_X509_STRICT——与 openssl strict 同引擎，
  补丁效果在真 Python 栈上闭环。
- ⚠️ 仿真陷阱：`openssl x509 -req`（3.2+）会**自动补 SKI/AKI**，污染对照组；
  必须用 python cryptography 精确控扩展（/tmp/aki-sim/gen.py 留档）。



### 3.3 AKI/SKI 语义与 patch 影响分析

**AKI/SKI 配对语义**：SKI = 证书自身公钥的哈希指纹（装在 CA 上，「我是谁」）；
AKI = 装在被签证书上，`keyid` = 签发者证书的 SKI（「谁签的我」）。链验证用途：
叶子按 subject 名可捞出多个候选签发者，用 `叶子AKI.keyid == 候选CA的SKI` 精确选路
（OpenSSL key identifier 法）。AKI 是选路提示不是信任来源；RFC 5280 要求 conforming CA
应当写 AKI，Python 3.13 VERIFY_X509_STRICT 把该 SHOULD 提到 MUST 强制。
现状：SquidCacheCA 有 SKI（78:AE:69:...），其伪造叶子无 AKI → strict 拒签；
patch 即给叶子补 `AKI: keyid 78:AE:69:...`。

**patch 影响面**：
- mimic 路径零改动（入口分流见下，mimic 存在时的分支逻辑不动）；
- client-first 伪造证书新增 AKI(keyid=CA SKI)：老客户端无感（本就不查），
  strict 客户端翻转 PASS；
- ⚠️ 勘误（源码 gadgets.cc:357-430 + 调用点 :679 实锤）：mimic 模式**不抄** origin AKI
  的内容——origin AKI 仅作形状模板（决定写哪些字段），字段值一律取自
  `properties.signWithX509`（= 实际签发者 SquidCacheCA）。mimic 与补丁版输出的 AKI
  都指向 SquidCacheCA，同等 RFC 正确。若真抄 origin keyid，OpenSSL 链构建会报
  AKID_SKID_MISMATCH，server-first 早就全球不可用——反证成立；
- client-first 的问题只有一个入口：gadgets.cc:360-361 `!mimicCert → return false`，
  压根走不到写 AKI 的代码（非写错）；
- 补丁设计据此收紧：值构造段(374-430)100% 由 issuerCert 驱动、与 mimicCert 无关，
  补丁只需入口处 `!mimicCert` 时置 addKeyId=true 落到同段代码，374 行以后零改动，
  mimic 路径输出逐字节不变；
- 无客户端动作：信任模型不变（仍靠 SquidCacheCA 在信任库），无需 CA 轮换、
  无需任何机器更新信任配置；
- 无持久状态：伪造证书按连接即时签发不落盘，上线/回滚均秒级生效，无旧证书残留；
- 性能≈0（每证书 +~20B，sslcrtd 生成量级无感）；
- CA 无 SKI 时走现成 issuerName+serial fallback（我们 CA 有 SKI，走 keyid 路径）；
- 主要风险在构建链而非 patch：需重建镜像 tag `7.7.1-aki1`，控制最小 diff 留档，
  建议上游化 PR（全网无公开实现）；
- 回归验证三道闸外必须加跑 tool-04（go）：实证 bump 后 GET 仍走完整 peer_select，
  重写链路未被碰坏。

## 2. 方案对比

| 方案 | 内容 | 影响面 | 结论 |
|---|---|---|---|
| **A. patch squid（推荐）** | `mimicAuthorityKeyId` 允许 mimicCert 缺失时，直接用签发 CA 的 SKI 构造 AKI | 一处小改；所有 strict 客户端一次性解掉；未来 strict 化客户端免疫 | ✅ 采纳 |
| B. strict 域 splice 白名单 | conda/python3.13 域 `ssl_bump splice`，不 bump 就无伪造证书 | 失去这些域的 url_rewrite 重写与缓存能力（与纯 rewrite 架构冲突） | ❌ 仅作应急 |
| C. 客户端关校验 | conda `ssl_verify: false` / `PYTHONHTTPSVERIFY=0` | 违背零配置目标，安全性归零 | ❌ 否决 |

## 3. 方案 A 实施步骤

### 3.1 补丁内容（~20 行，语义对 mimic 路径零改动）

**改 `mimicAuthorityKeyId`**：删掉 `!mimicCert → false` 的短路，mimicCert 存在时逻辑不变；
缺失时视为"需要 keyid 路径"：

```cpp
static bool
mimicAuthorityKeyId(Security::CertPointer &cert, Security::CertPointer const &mimicCert, Security::CertPointer const &issuerCert)
{
    if (!issuerCert.get())
        return false;

    bool addKeyId = false, addIssuer = false;
    if (mimicCert.get()) {
        // 服务器侧已知 origin 证书：保持原语义，只有 origin 真带 AKI 才抄
        Ssl::AUTHORITY_KEYID_Pointer akid(...X509_get_ext_d2i(mimicCert, NID_authority_key_identifier,...));
        addKeyId = (akid.get() && akid.get()->keyid != nullptr);
        addIssuer = (akid.get() && akid.get()->issuer && akid.get()->serial);
        if (!addKeyId && !addIssuer)
            return false;
    } else {
        // client-first bump：无 origin 证书可 mimic。RFC 5280 4.2.1.1 要求叶子带 AKI，
        // Python 3.13+（VERIFY_X509_STRICT）强制校验。签发 CA 在手，直接构造 keyid 路径。
        addKeyId = true;
    }
    // ……以下不动：从 issuerCert 取 SKI 填 keyid；CA 无 SKI 时回落 issuerName+serial（现有代码已处理）
}
```

**改调用点**（`signServerCertificate`，line ~680 门后补 else）：

```cpp
        addedExtensions += mimicExtensions(cert, properties.mimicCert, properties.signWithX509);
+   } else {
+       // client-first: 无 mimicCert，仍必须给叶子补 AKI（issuer SKI 路径）
+       if (mimicAuthorityKeyId(cert, properties.mimicCert, properties.signWithX509))
+           ++addedExtensions;
    }
```

可行性前提已实锤：线上 CA（`CN=SquidCacheCA`）**带 SKI**
（`78:AE:69:27:3E:D9:2A:67:DB:58:16:08:64:98:18:C9:97:EB:76:2F`），
走 keyid 路径；即使 CA 无 SKI，现有 fallback（issuerName+serial）也能凑出合法 AKI。

### 3.2 镜像与发布

1. 在现有 squid 镜像构建工程（编译 7.7.1 的那个 Dockerfile）里加 patch 文件重建，
   新 tag 如 `squid:7.7.1-aki1`；
2. chart：`values-006` 换 image tag → STS pod template 变化，`helm upgrade` 自动滚动
   （CM 未动，无需手动 rollout restart）；chart version bump（镜像行为修复属结构性变更）；
3. **不动** release 名 / chart 名（线上 ArgoCD 对应关系）。

### 3.3 验证（三道闸）

1. **openssl 取证**：pod 起来后经代理触发一次 bump，抓叶子证书
   `openssl x509 -noout -ext authorityKeyIdentifier` → 应出现
   `keyid:78:AE:69:27:...`（= CA SKI）；
2. **AKItest 套件复跑**：`aki-01-versions.yaml` 重跑——
   预期反转：python 3.13/3.14 default 从 FAIL 变 **PASS**，其余 10 项维持 PASS，全绿；
3. **业务用例**：no-mirror-test `tool-11-conda` 重跑通过（原 ❌ 的唯一业务失败项）。

### 3.4 风险与回滚

- 风险①：client-first 伪造证书带 AKI 后，若有客户端把 AKI 当"真 CA 链"校验依据——不会：
  AKI 只是提示性扩展，校验锚仍是信任库里的 CA，rustls/node/go 实测本来就不查；
- 风险②：mimic（server-first）路径语义未动，线上已工作的 bump/缓存行为零影响；
- 回滚：helm values 换回旧镜像 tag 即可，秒级。

## 4. 变体 B：peek2 采证（零代码）——**已实测判死（修订⑧，2026-09-16）**

> 实测结论先行：**pin 复现 + 采证连接本身不通，双重致命，此路不通。方案 A 是唯一解。**

### 4.1 原理

squid 有现成机制「拿真证书但不用这条连接」：`peek step2` 主动连 origin 收
server hello + 真证书链，bump 决策后该连接废弃、不承载业务流量。真证书在手
→ `mimicCert` 非空 → mimic 路径全开（AKI/SAN/EKU 全从真证书抄），零补丁。

```conf
acl step1 at_step SslBump1
acl step2 at_step SslBump2
ssl_bump peek step1     # 只看 client hello（拿 SNI）
ssl_bump peek step2     # 连 origin 采真证书
ssl_bump bump all       # 采完 bump，采证连接废弃
```

### 4.2 风险：正是 JUDGEMENT 修订⑥判死的 server-first 语义

peek1+peek2+bump ≡ server-first（新版语法等价形式）。修订⑥ debug-44 实锤：
bump 阶段建过 origin 连接 → 后续 GET 被 PINNED 到那条连接 → peer_select 跳过
全部 peer → url_rewrite/cache_peer 全死。但当年实测走的是 server-first 老语法，
**7.7.1 的 peek2→bump 是否仍 pin 未经直接实测**——本实验回答这一问。

### 4.3 实测记录（2026-09-16，gy-006，chart 0.1.16 线上）

执行：CM squid-config 临时 patch 为 peek/peek/bump（备份回滚留档
`cm-backup-1041.yaml`）→ rollout restart 2/2 Ready → 跑 no-mirror-test tool-04。

**结果：FAIL（双重致命）**

① **PINNED 复现**（tool-04 go1.26.0 toolchain 下载 503），access.log 铁证
（squid-cache-0）：

```
NONE_NONE_TIMEDOUT/200 0  CONNECT proxy.golang.org:443  - HIER_DIRECT/173.194.202.141 -
NONE_NONE/503 1635      GET https://proxy.golang.org/golang.org/toolchain/@v/
                        v0.0.1-go1.26.0.linux-arm64.zip - HIER_NONE/- text/html
```

- GET 的 **`HIER_NONE/-`** = 没有任何上游选择，peer_select 被整段跳过——GET 被
  pin 死在 peek 采证连接上（与修订⑥ debug-44 同一签名，7.7.1 行为坐实）；
- 该 URL 在 client-first 下重写到 goproxy.cn 实测 200（REPORT.md 探针），503 =
  重写未发生，判定组①不通过。

② **采证连接本身不通**：peek2 强制每条 CONNECT 先对 origin 做一次 TLS 握手，
而 `proxy.golang.org`（Google IP）从集群直连被墙 → 上行
`CONNECT ... TIMEDOUT`。被墙域恰恰是代理存在的理由——变体 B 在最需要它的
域上连采证都完不成。

tool-11（conda）未跑——pin 已单独致命，判定组②无意义。

**回滚**：CM 恢复备份 + restart 2/2 Ready；sanity check 确认重写链路正常
（`ports.ubuntu.com → repo.huaweicloud.com/ubuntu-ports/...` 200）。
回滚教训：backup yaml 含旧 `resourceVersion`/annotations，直接 `kubectl apply`
冲突（"object has been modified"）——恢复前必须剥掉这两个字段。

### 4.4 已知语义瑕疵（未到它，pin 已先判死）

抄来的 AKI 指向 origin 真 CA，而伪造证书实际签发者是 SquidCacheCA——strict
客户端只查「存在且合法格式」，能过；但 RFC 5280 意义上 AKI 应指向真签发者，
抄写 AKI 是错的。方案 A 补丁（AKI = SquidCacheCA SKI）才是 RFC 正确写法。

### 4.5 对比与决策（终版）

| 路径 | 采证书连接 | PINNED | AKI 语义 | 代码改动 | 结论 |
|---|---|---|---|---|---|
| B. peek2 采证 | 每条 CONNECT 强制连 origin（含被墙域） | ✅ 实测复现（HIER_NONE） | 抄真 CA，RFC 错 | 零 | ❌ 判死（修订⑧） |
| **A. 补丁（§3）** | 完全不连 origin | 无（数据路径不变） | RFC 正确（指向 SquidCacheCA） | ~20 行 | ✅ **唯一解，下一步实施** |

## 5. 上游化（可选后续）

同一补丁可提 squid-cache 上游 PR：client-first 生成证书补 AKI 符合 RFC 5280
（4.2.1.1 SHOULD），且不改变 mimic 路径语义。附 AKItest 矩阵数据作为动机证据。

## 6. 目录内待建（实施时）

- `gadgets.cc-aki.patch`（对 v7.7.1 的 diff）
- `Dockerfile` 或指向现有构建工程的说明
- `VERIFY.md`（三道闸验证记录，跑完回填）
