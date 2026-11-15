# RFC：华为云高可用、低时延海外出口代理

- 状态：Proposed（待架构评审）
- 日期：2026-11-15
- 范围：Ascend CI 国内集群访问 GitHub API、GitHub 下载源、Docker Hub、Quay 等海外服务
- 交付：出口代理架构与验收契约；本 RFC 不修改现网部署

## 1. 背景与问题

国内 CI 节点直连 api.github.com 存在连接超时、Connection reset、TLS 握手失败；GitHub Clone、Release 和 Registry 回源也受跨境链路质量影响。现有平台已部署 Squid + rpardini 缓存，具备 CI 显式代理入口与缓存能力，不能因为增加海外代理而重复建设缓存。

已核对 [ascend-ci-deployment 的注入脚本](https://github.com/opensourceways/ascend-ci-deployment/blob/main/scripts/squid-injection.py)：默认 NO_PROXY 包含 api.github.com，因此部分 Runner 请求会绕过本地 Squid。现有 [Squid Chart](https://github.com/opensourceways/ascend-ci-deployment/blob/main/manifests/squid-rpardini/chart/templates/configmap.yaml) 对非 Registry HTTPS 默认 SSL Bump。GitHub API 是带身份凭据的动态请求，不应解密或缓存。

核心矛盾：**国内到海外的网络质量不稳定；单个代理 ECS 只能转移故障位置，不能提供端到端高可用。**

## 2. 目标与非目标

| 优先级 | 目标 | 可验证的判据 |
| --- | --- | --- |
| P0 | 提升连接可靠性 | 按集群、运营商、目标域统计 TCP 连接超时、RST、TLS 失败和完整请求成功率；与国内直连对照 |
| P0 | 消除单 ECS、单 AZ 故障 | 任一代理节点或 AZ 故障后，新连接自动转至健康实例；故障注入验证 |
| P0 | 保护凭据与访问边界 | GitHub API 使用端到端 TLS；代理间链路加密、身份认证、目标白名单；无开放代理 |
| P1 | 降低尾延时 | 关注 TCP+TLS 建连 P50/P95/P99、成功请求 TTFB 与下载吞吐；按运营商和时段对比 |
| P1 | 降低维护成本 | 国内 CI 仍使用现有 Squid 地址；路由、健康状态与配置集中管理，支持灰度和回滚 |
| P2 | 提升 Region 级韧性 | 香港区域级故障时，后续可以切换至独立 Region 的备用出口 |

**建议验收门槛（待 7 天基线确认）：**
- 代理自身可归因可用性目标 ≥99.95%/30 天；GitHub 源站 4xx/5xx、上游自身故障单独统计。
- 测试窗口内，GitHub API 网络类失败率相对直连降低 ≥50%；不能以仅增加重试次数替代改善。
- 单代理或单 AZ 故障后，新连接恢复 P95 ≤30 秒；不承诺已建立 TCP 流无损迁移。
- P95 TCP+TLS 建连时间不高于相同采样窗口内直连 P95；若未达标，不能直接认定低延时目标完成。
- 所有判据须提供样本量、观测窗口、客户端集群/运营商、目标域与失败分类。

**非目标：** 替代现有国内软件包/Registry 缓存；缓存 GitHub API 响应；通过更换出口绕过 GitHub 认证或限流；默认代理全部 CI 控制面流量；在本 RFC 中确定最终 ECS 规格或带宽价格。

## 3. 推荐架构

采用 **国内 Squid 域名分流 + 香港多 AZ 无状态代理 + 可观测的跨 Region 备用出口**。

![海外出口代理目标架构：国内 CI 经 Squid 分流至香港精品 BGP 和跨 AZ 代理，新加坡作为备用 Region](assets/0001-huawei-cloud-egress-proxy.svg)

**图 3-1 · 海外出口代理目标架构。** 主路径为国内 Squid → 香港精品 BGP EIP / ELB → 双 AZ 代理 → 海外官方源站。国内缓存链保持不变；新加坡为第二阶段的独立区域级备用出口。

注：精品 BGP EIP 与独享型 ELB 的产品组合、香港公网出站故障域尚待华为云账号级验证；图示为目标方案，不代表已部署。

### 3.1 核心组件职责

| 组件 | 职责 | 与相邻组件的接口 |
| --- | --- | --- |
| 国内 Squid | 域名分类、GitHub API 透传、选择健康上游；维持现有缓存路径 | Runner 显式 HTTP(S) proxy；向香港代理发 CONNECT |
| 香港精品动态 BGP EIP | 优化国内至香港的公网接入与返回路径 | 绑定接入层公网入口；**不保证香港至 GitHub 的出站路径质量** |
| 独享型 ELB | TCP 负载分发、后端健康检查、跨 AZ 摘除 | 接收已认证/加密代理链路；转发到代理实例 |
| 香港 Squid A/B | 只允许授权来源和白名单域名的 CONNECT；不做 SSL Bump、不缓存 API | CONNECT 至官方源站，保留端到端 TLS |
| 公网出站路径 | 香港到 GitHub / Registry 的实际互联网回源 | ECS EIP 或 NAT SNAT；必须验证出口带宽、IP 与故障域 |
| 健康与路由控制 | 从国内客户端视角检测链路质量、记录出口状态、执行受控切换 | 采集分段指标；改变国内 Squid 上游选择 |

**重要边界：** ELB 的 TCP 健康检查只能检测代理端口，不能证明其到 GitHub 可达。必须另建从国内 CI 视角发起的端到端探测，避免把出站链路故障误判为代理健康。

### 3.2 三段链路分别优化

1. **国内 CI → 香港入口：** 香港精品动态 BGP 作为首选；按电信、联通、移动及不同集群实测。精品 BGP 是 EIP 线路属性，不是 VPC 属性。
2. **香港入口 → 代理：** ELB + 2 AZ 独立 ECS，配置无状态；首版不必引入 CCE。ELB 只承担会话建立时的负载分发，不保证已有长连接迁移。
3. **香港代理 → 海外源站：** 比较 ECS 独立 EIP 与 NAT SNAT；避免所有实例共享未经验证的单个 NAT/出站 IP 故障域。出站 IP、DNS 解析、IPv4/IPv6 和源站限流独立测量。

### 3.3 协议与安全

- 国内 Squid 对 api.github.com 采用 CONNECT 透传（splice），不终结 GitHub TLS，不缓存认证 API 内容；保留现有非 API 缓存策略。
- 国内到香港的 **代理间连接须加密并认证**（例如 mTLS 保护的上游代理，或经合规审批的加密私网连接）；不能仅凭公网源 IP 信任。
- 香港代理仅允许明确的客户端身份、CONNECT 方法、端口 443 与审批过的域名白名单；禁止通用公网代理、开放转发和任意内网/元数据地址访问。
- GitHub Token 只在客户端与 GitHub 之间的 TLS 中传输；日志仅保留必要的域名、状态、时延与字节数，不记录 Authorization、Cookie 或完整带凭据 URL。
- 对 GitHub API 的 401/403/429 使用认证与限流机制处理；自动出口切换仅针对经判定的网络/代理故障。非幂等请求不作无条件重放。

### 3.4 故障切换

| 故障范围 | 检测与响应 | 边界 |
| --- | --- | --- |
| 单 ECS/代理进程 | ELB 摘除不健康后端；实例由部署系统恢复 | 已建立 TCP 连接可能断开 |
| 单 AZ | ELB 转发至另一 AZ；健康副本保留容量 | 验证 AZ 故障时是否仍有出站路径 |
| 单 EIP、精品 BGP 入口异常 | 国内端到端探针发现链路退化，切换到独立入口 | 单个 ELB/EIP 不应被写成区域级容灾 |
| 香港到 GitHub 的公网故障 | 监测 CONNECT 之后的 TLS/HTTP 探测；切换出站路径或地区 | ELB 后端 TCP 仍可能显示健康 |
| 香港 Region 故障 | 第二阶段启用独立 Region（建议新加坡） | 异地延时可能增加；恢复策略要优先可用性 |
| GitHub HTTP 403/429 | 保持身份与限流处置，不视为出口故障 | 不用代理轮换规避限流 |

跨 Region 切换由**国内路由层**发起；只改变后续新请求的上游选择。需要熔断、滞回与恢复探测，避免两个出口反复抖动。

## 4. 选型与关键取舍

| 方案 | 优点 | 主要不足 | 决策 |
| --- | --- | --- | --- |
| 1 ECS + 精品 BGP EIP | 最简单、成本低 | ECS/AZ 单点 | 仅用于早期网络基线 |
| **双 AZ ECS + 独享型 ELB + 精品 BGP** | 托管接入、健康分发、无状态扩展 | 仍有香港 Region、入口 EIP、出口 NAT 故障域 | **首选目标方案** |
| 香港 CCE + ELB | Pod 自愈与扩缩容便利 | 新增 CCE 控制面、CNI、节点维护 | 已有可复用 CCE 或规模扩大时再评估 |
| GA 全球加速 + 香港/新加坡出口 | 全球接入、跨区域调度能力 | 费用、跨境资质、端到端效果需验证 | 对照测试后决定 |
| 仅 DNS 多 IP / 单 Squid cache_peer | 成本低 | 不保证及时发现端到端故障 | 不单独承担 HA 目标 |

**云产品前置核验：** 中国香港当前账号是否可将精品动态 BGP EIP 绑定所选独享型 ELB、双 AZ 和配额是否可用；如不支持，则采用两个独立精品 BGP EIP + 代理实例/独立入口，国内侧完成多上游健康选择。此兼容性在验证前**不得标记为已确认**。

**GA 使用约束：** 涉及中国大陆接入与境外终端的 GA 跨境通信需要相应资质审核；只有性能或区域故障收益覆盖成本、复杂度后才引入。

## 5. 与现网 Squid 的集成

当前事实：
- [生产 Squid 设计](https://github.com/opensourceways/ascend-ci-deployment/blob/main/manifests/squid-rpardini/SQUID-DESIGN.md) 已区分下载缓存、git-cdn 与 Registry Blob 缓存。
- [Squid 模板](https://github.com/opensourceways/ascend-ci-deployment/blob/main/manifests/squid-rpardini/chart/templates/configmap.yaml) 默认对非 Registry HTTPS bump，必须为 GitHub API 增加优先的 splice 分流，并验证 CONNECT 到上游 peer 的实际路由。
- [Runner 注入脚本](https://github.com/opensourceways/ascend-ci-deployment/blob/main/scripts/squid-injection.py) 的 NO_PROXY 含 api.github.com，迁移时须同步修改注入常量、校验逻辑、实际 Job 模板和文档。**GitHub Actions Listener/Runner 控制面流量单独灰度，不和普通 Job API 调用一起切换。**

边界：本 RFC 只规定接口与策略，不直接修改 ascend-ci-deployment 的 Helm Chart；具体 Squid peer 规则需在目标镜像版本完成配置解析与端到端验证。

## 6. 必要验证与验收

**评审状态：方案待验证。** 本 RFC 提出目标架构，不代表云产品组合、真实跨境网络质量、Squid 链式转发或故障切换已被验证。所有验证项初始状态均为**待测试（本 RFC 未附测试证据）**。**执行和状态统一跟踪：[Issue #24 — RFC 验证总追踪](https://github.com/opensourceways/squid_e2e_tests/issues/24)**，各 V-ID 均有独立 PDCA Issue（Plan 目标和方案 / Do 执行记录 / Check 量化验收 / Act 改进及复测）。**架构方向可先评审，生产可行性与上线结论必须由以下测试结果支持。**

### 6.1 方案可行性的验证清单

| ID / 阶段门槛 | 必须验证的架构假设与测试方法 | 通过标准及未通过时的调整 |
| --- | --- | --- |
| [**V01**](https://github.com/opensourceways/squid_e2e_tests/issues/25) / 可行性** | **云产品组合**：在目标华为云香港账号实际创建精品动态 BGP EIP、独享型 ELB、跨两个 AZ 的 ECS 后端；核对绑定方式、配额、计费与健康检查 | 可购买、可绑定、两 AZ 后端可用；否则改用**两个独立 EIP + 入口选择**，不将 ELB 作为既定方案 |
| [**V02**](https://github.com/opensourceways/squid_e2e_tests/issues/26) / 可行性** | **代理间安全链路**：验证国内 Squid 到香港代理的加密/身份认证方式，及跨境网络接入的资质和合规边界 | 无公网明文代理凭据链路；仅授权客户端可用；审批/网络条件不满足则不得接入生产 |
| [**V03**](https://github.com/opensourceways/squid_e2e_tests/issues/27) / 可行性** | **Squid 协议兼容**：在现网所用 Squid 版本验证 `NO_PROXY` 移除、`ssl_bump splice`、`cache_peer` CONNECT 转发、peer 故障行为；核对 Runner/Job 与 GitHub 控制面流量边界 | `squid -k parse` 通过；API 请求实际经香港上游；GitHub 官方证书链端到端有效；无缓存/解密 Token；不影响现有缓存；不满足则调整代理链路或客户端接入设计 |
| [**V04**](https://github.com/opensourceways/squid_e2e_tests/issues/28) / 可行性** | **真实链路收益**：同一国内集群、同一时段对照直连/本地 Squid/香港出口，覆盖有代表性的电信、联通、移动及 GitHub API、Registry，至少连续 7 天 | 网络类失败率相对直连下降目标 ≥50%（拟议）；TCP+TLS 建连 P95 不高于直连基线（拟议）；报告样本量与统计区间；无显著收益则重评精品 BGP、GA 或出口地区 |
| [**V05**](https://github.com/opensourceways/squid_e2e_tests/issues/29) / 生产** | **AZ/节点与出站故障域**：停止任一代理、隔离一个 AZ、阻断单个 EIP/NAT 出站；验证仍有实际可用出口，并在 N-1 容量下压测 | 新连接恢复 P95 ≤30 秒（拟议）；不存在未经识别的共享单出口故障点；若共享 NAT 单点无法消除，需独立出站路径或缩小 HA 承诺 |
| [**V06**](https://github.com/opensourceways/squid_e2e_tests/issues/30) / 生产** | **端到端故障判定**：保持香港代理 TCP 端口存活，仅阻断香港→GitHub；测试健康判定、熔断、路由切换与恢复，同时注入 HTTP 401/403/429 | 网络故障被识别并切换后续新请求；业务 HTTP 错误不触发绕过限流的出口切换；无持续路由振荡 |
| [**V07**](https://github.com/opensourceways/squid_e2e_tests/issues/31) / 生产** | **安全隔离**：测试未授权源、非法 CONNECT 目标/端口、私网和元数据地址、伪造域名/IP、TLS 证书验证、敏感日志及凭据轮换 | 全部未授权路径被拒绝；不记录 Token/Authorization；客户端验证源站证书；安全前置条件失败则不上线 |
| [**V08**](https://github.com/opensourceways/squid_e2e_tests/issues/32) / 生产** | **容量与成本**：按 CI 峰值并发验证 ECS/ELB/NAT 连接数、SNAT 端口、CPU、内存、带宽与流量费用；混合小 API 与大文件负载 | N-1 状态下满足实测流量与延时要求；得到可复核的规格与月成本，未达标先扩容或调整出口模型 |
| [**V09**](https://github.com/opensourceways/squid_e2e_tests/issues/33) / 二期** | **区域容灾与加速选型**：实测香港整区不可达→新加坡备用出口；将 GA 与精品 BGP 在相同样本下对照 | 区域故障新连接恢复、成本/延时收益有证据；仅影响二期立项，不阻塞香港双 AZ 首期 |

**当前结果登记：V01–V09 均为「待测试（未附证据）」；不得将本表的目标值视为测试结论。** 各 Issue 初始均未勾选 Check 项；测试执行后将证据、量化结果和 Act 决策记录在对应 Issue，并同步更新 [总追踪 #24](https://github.com/opensourceways/squid_e2e_tests/issues/24)。V01–V04 是技术可行性门槛；V05–V08 是生产上线门槛；V09 是二期门槛。**关闭 Issue 不等于验证通过。**

### 6.2 测试设计与证据

本仓库现有 Compose/K8s HA 套件可复用进程、节点故障测试；**不能替代**真实云产品、跨境网络、认证与 API 语义验证。

| 测试场景 | 对应验证项 | 主要证据 |
| --- | --- | --- |
| A. 基线与多网络 | V04 | 同客户端/同时段对照；按集群、运营商、目标域、IPv4/IPv6 分层的失败率、TCP/CONNECT/TLS/HTTP、TTFB P50/P95/P99 |
| B. 云产品装配 | V01、V02 | 目标账号购买与绑定结果、网络拓扑、两 AZ 后端、配额、加密传输与授权验证 |
| C. Squid 与 CI 集成 | V03 | `squid -k parse`、请求路径与 `NO_PROXY` 对照、抓包/证书校验、Runner/Job 日志、缓存功能回归 |
| D. 节点/AZ/出口故障 | V05 | 停止代理、AZ 隔离、EIP/NAT 故障注入时刻；探测时间线、新旧连接影响、N-1 容量 |
| E. 上游故障但代理存活 | V06 | 阻断香港→GitHub、401/403/429 对照、熔断/切换/恢复事件、路由稳定性 |
| F. 安全 | V02、V07 | ACL 拒绝结果、代理间身份认证、TLS 证书链、日志脱敏、非法目的地址访问验证 |
| G. 容量与成本 | V08 | 并发/持续吞吐/长连接测试；ECS/ELB/NAT 限额、性能曲线和成本明细 |
| H. 整区容灾与 GA 对照（二期） | V09 | 香港整区不可达演练、新加坡恢复时延、GA/精品 BGP 对照和跨境资质 |

测试记录最少包含：**验证项 ID、环境/版本、操作步骤、样本窗口与数量、原始日志/指标、结论（通过/未通过）、负责人、日期及证据 URL**。每项测试必须完整执行 **Plan → Do → Check → Act**：不通过时记录根因、整改方案和复测结果；通过时提交对架构决策的影响。具体任务与验收复选项见各 V-ID Issue，总表见 [#24](https://github.com/opensourceways/squid_e2e_tests/issues/24)。GitHub API 必须控制请求频率；高并发/大流量使用受控测试目标，避免压测触发源站限流。

### 6.3 架构决策门槛

| 决策时点 | 必须具备的证据 | 允许的结论 |
| --- | --- | --- |
| RFC 架构评审 | 目标、候选方案、V01–V09 测试计划和失败时替代方案 | **有条件批准设计方向**，不得宣布技术可行性或可上线 |
| 确认首期技术可行 | **V01–V04 全部通过**，有可复核测试记录 | 锁定香港入口/代理/传输选型；若任何阻塞项失败，调整架构后重评 |
| 生产灰度/上线 | **V01–V08 全部通过**，完成安全和容量审查 | 分集群灰度与回滚；不能以节点健康检查替代端到端可用性 |
| 区域级容灾交付 | **V09 通过** | 才能对外宣称具备跨 Region 自动恢复能力 |

## 7. 实施阶段与回滚

1. **P0：可行性验证（V01–V04）。** 核实云产品、认证传输、Squid CONNECT 路径，完成 7 天链路对照；未通过则修改目标架构。
2. **P1：最小出口联调。** 香港受限代理、加密认证、GitHub API CONNECT；仅非关键 Job 测试环境联调，禁止直接作为生产上线结论。
3. **P2：生产门槛验证（V05–V08）。** 香港双 AZ、独立出站故障域、E2E 探针、安全与容量测试；全部通过后按集群灰度。
4. **P3：二期区域容灾（V09）。** 新加坡独立出口、国内路由层熔断和恢复，经整区故障演练后交付。
5. **P4：基于测试优化。** 若香港入口或出站延时/成本不达标，再对 GA、其他线路/出口及 CCE 进行对照。

回滚：按集群、项目与目标域控制；关闭 GitHub API 香港路由时恢复原 NO_PROXY/直连策略；缓存/Registry 路径不随新出口回滚。控制面变更必须独立回滚。

## 8. 请求评审的关键决策

1. 是否接受 **国内 Squid → 香港双 AZ 出口 → GitHub** 作为主方案，而非为每个 CI 工具单独设置代理？
2. GitHub API 的 Runner 控制面请求是否纳入首期？建议首期仅普通 Job，控制面单独验证。
3. 是否接受「香港双 AZ 首期、独立 Region 第二期」的容灾边界及拟议验收门槛？
4. 香港接入层是否可以购买并绑定精品 BGP EIP？香港出站 NAT 的独立故障域如何保证？需要云平台实测/配额确认。
5. 是否已有可用的经批准跨境私网连接；如无，采用何种 mTLS 代理间传输与凭据轮换方案？

## 9. 产品与参考资料

以下均为**产品能力说明或现有工程事实**，不是本方案实测证明。可行性和上线结论必须以第 6 章各 V-ID 的实际记录为准；文档覆盖的产品能力不等于目标账号、Region、规格和带宽已满足部署要求。

### 9.1 华为云官方产品文档

| 产品/能力 | 官方参考 | 支持的设计判断 | 关联验证 |
| --- | --- | --- | --- |
| 弹性公网 IP（EIP）/ 精品动态 BGP | [静态、全动态及精品动态 BGP 区别](https://support.huaweicloud.com/eip_faq/faq_bandwidth_0013.html) | 精品动态 BGP 优化中国内地与中国香港的跨境网络路径；**不证明**其与目标 ELB 组合可用，也不保证香港至 GitHub 的出口质量 | V01、V04 |
| 独享型 ELB | [独享型 ELB 健康检查](https://support.huaweicloud.com/usermanual-elb/elb_ug_hc_0001.html) | 健康检查与不健康后端摘除；TCP/HTTP 健康不能替代到 GitHub API 的业务探针 | V01、V05、V06 |
| ELB 多可用区规划 | [独享型 ELB 子网和多 AZ IP 占用](https://support.huaweicloud.com/intl/zh-cn/elb_faq/elb_faq_210307.html) | 多 AZ 后端子网的网络规划依据；实际双 AZ、配额及路由仍须目标账号验证 | V01、V05 |
| 公网 NAT 网关 | [购买公网 NAT 与约束](https://support.huaweicloud.com/usermanual-natgateway/zh-cn_topic_0150270259.html)、[添加 SNAT 规则](https://support.huaweicloud.com/usermanual-natgateway/zh-cn_topic_0127489529.html) | 多 ECS 共享 EIP 出站的可选实现；NAT 网关、SNAT 端口、EIP 和子网路由必须核验；共享 NAT 不等于独立故障域 | V01、V05、V08 |
| 全球加速（GA） | [终端节点支持类型与区域](https://support.huaweicloud.com/usermanual-ga/ga_03_4001.html) | GA 可选 EIP/ECS/ELB 等终端节点；是否优于精品 BGP 需要相同测试窗口对照 | V09 |
| GA 跨境通信 | [跨境资质申请](https://support.huaweicloud.com/usermanual-ga/ga_03_8001.html) | 中国大陆接入、境外后端的 GA 场景需要跨境资质审核；其他公网/专网跨境方案的合规要求仍需单独确认 | V02、V09 |

### 9.2 代理协议、GitHub 官方文档

| 技术/接口 | 官方参考 | 支持的设计判断 | 关联验证 |
| --- | --- | --- | --- |
| Squid 父级代理 | [cache_peer](https://www.squid-cache.org/Doc/config/cache_peer/)、[never_direct](https://www.squid-cache.org/Doc/config/never_direct/) | 上游 peer、强制转发配置依据；**不能由文档推断**现网版本对 CONNECT + splice + peer 的组合已验证 | V03、V06 |
| Squid TLS 处理 | [ssl_bump 指令](https://www.squid-cache.org/Doc/config/ssl_bump/)、[Peek and Splice](https://wiki.squid-cache.org/Features/SslPeekAndSplice) | GitHub API TLS 透传策略依据；客户端对 GitHub 官方证书链的验证仍须实测 | V03、V07 |
| GitHub REST API 限流 | [Rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)、[Best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api) | 403/429 按认证、限流及 Retry-After 处置，不能作为跨境出口故障或代理轮换触发条件 | V06、V07 |

**版本边界：** Squid 官方的 `cache_peer`、`ssl_bump` 文档列出对应支持版本；目标镜像版本及配置解析是 V03 的一部分，不能默认未来大版本兼容。

### 9.3 已有部署与测试工程

| 工程事实/可复用资产 | 资料 | 关联验证 |
| --- | --- | --- |
| 现网 Squid 缓存和 Registry 回源职责 | [Ascend CI Squid 设计](https://github.com/opensourceways/ascend-ci-deployment/blob/main/manifests/squid-rpardini/SQUID-DESIGN.md) | V03、V04 |
| Squid SSL Bump / peer / URL 重写实际模板 | [现网 chart/configmap.yaml](https://github.com/opensourceways/ascend-ci-deployment/blob/main/manifests/squid-rpardini/chart/templates/configmap.yaml) | V03 |
| Runner 环境变量注入，`NO_PROXY` 含 `api.github.com` | [scripts/squid-injection.py](https://github.com/opensourceways/ascend-ci-deployment/blob/main/scripts/squid-injection.py) | V03 |
| 可复用的代理 HA、故障注入与测试约定 | [本仓库方案](../solution.md)、[测试策略](../test.md)、[生产约束](../PRODUCTION.md) | V03、V05、V06、V08 |

**尚缺证据：** 精品 BGP EIP 与独享型 ELB 绑定兼容性、完整加密代理链路、实际国内三网性能、香港双 AZ 出口独立性、端到端故障切换均**没有**通过上述文档得到实测确认，对应 V01–V08 仍为待验证。
