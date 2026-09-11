# 开源仓库部署与贡献记录（OSS Deploy & Contribute Record）

> 记录日期：2026-09-10
> 用途：留档「主导开源（部署/镜像 Ascend 仓库）」与「参与开源（向 vllm/verl/sglang 等上游提交）」两条线
> 的现状、问题与待确认事项，重点是 **squid 缓存代理在这两条线中的接入情况**。

***

## 0. 可走 squid 的工具汇总

以下 18 个工具场景均已验证可走 squid（`traffic-test/tool/`，案例见 `traffic-test/TOOL-RESULTS.md`、
`traffic-test/tool/FINAL-REPORT.md`）。10 并发流量测试命中率来自 2026-08-12 gy-006 实测。

| case   | 工具/场景       | 流量特征                              | HIT%     | 备注                               |
| ------ | ----------- | --------------------------------- | -------- | -------------------------------- |
| 01     | pip         | PyPI wheel（→ huaweicloud 镜像）      | \~高      | wheel 强制缓存                       |
| 02     | apt         | .deb 包（→ huaweicloud 镜像）          | 99.8%    | .deb 强制缓存，10 并发几乎零回源             |
| 03     | github      | git clone（→ gh-proxy 换源）          | 0.0%     | git pack 结构性不缓存                  |
| 04     | goproxy     | go mod download（proxy.golang.org） | 89.7%    | <br />                           |
| 05     | obs         | obsutil 下载 OBS 对象                 | 98.6%    | <br />                           |
| 06     | wget        | 模型权重大文件（.pth/.pt/.safetensors）    | 60%→100% | 加强制缓存规则后 100%                    |
| 07     | cmake       | FetchContent                      | 62.1%    | 部分 URL 带缓存标记                     |
| 08     | bazel       | http\_archive                     | 94.5%    | 需 JKS 信任库（squid-bazel-trust）     |
| 09     | npm         | registry tarball（→ npmmirror）     | 95.4%    | <br />                           |
| 10     | cargo       | crates.io .crate（→ rsproxy.cn）    | 11%→95%  | 加 `\.crate$` 强制缓存规则后 \~95%       |
| 11     | conda       | 包安装（→ nju.edu.cn）                 | 99.8%    | <br />                           |
| 12     | uv          | uv pip wheel 缓存                   | 95.2%    | <br />                           |
| 13     | huggingface | huggingface\_hub 下载               | 91.9%    | 本次 job FAILED（hf hub 网络，失败前命中良好） |
| 14     | gitlfs      | git-lfs 对象                        | 99.7%    | <br />                           |
| 15     | pnpm        | pnpm install（→ npmmirror）         | 97.4%    | <br />                           |
| 16     | yum/dnf     | RPM 包（openEuler）                  | 99.9%    | <br />                           |
| 17     | docker-pull | docker pull 镜像层（registry-proxy）   | —        | registry-proxy 侧缓存               |
| 18     | gitaction   | gitaction 工具本身（python + node.js 自研） | —      | <br /> |

**小结**：除 git 系（结构性 0%）外，绝大多数包管理/大文件工具命中率 90%+；
`squid` 收益与「下载体积 + 重复频率」正相关。

***

## 1. 主导开源（Lead Open-source）

> 数据来源：`report.html`（Pod 时间统计报告，2026-09-04 00:00 \~ 2026-09-10 07:30，
> CPU/NPU 项目分布）。从中收集到 **63 个唯一仓库名**（已剔除 runner pod 名，另有 `unknown` 68 次为噪声）。
> 命名以报告为准（如 `faiss`=ascend-faiss、`ci`=ascend-ci）。

### 1.1 维护仓库总表

> 状态说明：✅ 已部署 = 源码拉取/构建产物经 squid 或镜像链路可达；⚠ = 有问题待处理；⏳ = 未部署，留给 squid 部署。
> 备注 = report.html 中的对应写法（大小写/连字符差异）。

| 仓库                               | 状态             | 备注                                              | 问题描述                                                                                                                                                              |
| -------------------------------- | -------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ascend-faiss                     | ✅ 已部署          | faiss                                           | <br />                                                                                                                                                            |
| ascend-mindie-motor              | ✅ 已部署          | MindIE-Motor                                    | <br />                                                                                                                                                            |
| ascend-multimodalsdk             | ✅ 已部署          | MultimodalSDK                                   | <br />                                                                                                                                                            |
| ascend-msprof                    | ✅ 已部署          | msprof                                          | <br />                                                                                                                                                            |
| ascend-mindcluster-ascendnpuburn | ✅ 已部署          | MindCluster-AscendNPUBurn                       | <br />                                                                                                                                                            |
| ascend-mssanitzer                | ✅ 已部署          | mssanitizer                                     | <br />                                                                                                                                                            |
| ascend-agentsdk                  | ✅ 已部署          | AgentSDK                                        | <br />                                                                                                                                                            |
| ascend-memfabric\_hybrid         | ✅ 已部署          | memfabric\_hybrid                               | <br />                                                                                                                                                            |
| ascend-msmodelslim               | ✅ 已部署          | msmodelslim                                     | <br />                                                                                                                                                            |
| ascend-torchair                  | ✅ 已部署          | torchair                                        | <br />                                                                                                                                                            |
| ascend-visionsdk                 | ✅ 已部署          | VisionSDK                                       | <br />                                                                                                                                                            |
| ascend-msinsight                 | ✅ 已部署          | msinsight                                       | <br />                                                                                                                                                            |
| ascend-memcache                  | ✅ 已部署          | memcache                                        | <br />                                                                                                                                                            |
| ascend-drivingsdk                | ✅ 已部署          | DrivingSDK                                      | <br />                                                                                                                                                            |
| ascend-mind-cluster              | ✅ 已部署          | mind-cluster                                    | <br />                                                                                                                                                            |
| ascend-ci-gitcode                | ✅ 已部署          | ci\_gitcode                                     | <br />                                                                                                                                                            |
| ascend-indexsdk                  | ✅ 已部署          | IndexSDK                                        | <br />                                                                                                                                                            |
| ascend-mindie-sd                 | ✅ 已部署          | MindIE-SD                                       | <br />                                                                                                                                                            |
| ascend-ci                        | ✅ 已部署          | ci                                              | <br />                                                                                                                                                            |
| ascend-ops-rec                   | ✅ 已部署          | ops-rec                                         | <br />                                                                                                                                                            |
| ascend-mindx-pipline             | ✅ 已部署          | mindx\_pipline                                  | <br />                                                                                                                                                            |
| ascend-msmodeling                | ✅ 已部署          | msmodeling                                      | <br />                                                                                                                                                            |
| ascend-op-plugin                 | ✅ 已部署          | op-plugin                                       | <br />                                                                                                                                                            |
| ascend-fbgemm-ascend             | ✅ 已部署          | fbgemm-ascend                                   | <br />                                                                                                                                                            |
| ascend-pytorch                   | ⚠ 待定位          | pytorch                                         | 有问题，根因尚未找到（yet to find）                                                                                                                                           |
| ascnd-recsdk                     | ⚠ 并发下载问题       | RecSDK（RecSDK\_for\_lingqu 归此）                  | 并发下载场景失败；secret 部署挂载显示连接 github 错误——关联测试 [redirect/test/02-github-archive-git-gy001-x10-delay10.yaml](redirect/test/02-github-archive-git-gy001-x10-delay10.yaml) |
| MindSpeed-MM                     | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| pytorch\_for\_lingqu             | ✅ 已部署 | pytorch 变体                                      | <br />                                                                                                                                                            |
| msmemscope                       | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msagent                          | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindSpeed                        | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| Triton-distributed-ascend        | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindSpeed-LLM                    | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| mspti                            | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindSpeed-Ops                    | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindSpeed-Bridge                 | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msopprof                         | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| AgentBox-Manager                 | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| TransformerEngineNPU             | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msopcom                          | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msdebug                          | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| FSDPTurbo                        | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msmonitor                        | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msprobe                          | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msserviceprofiler                | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| RAGSDK                           | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| msmodelslim\_for\_lingqu         | ✅ 已部署 | msmodelslim 变体                                  | <br />                                                                                                                                                            |
| MindIE-LLM                       | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MegatronAdaptor                  | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| triton-ascend-kernels            | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| op-plugin\_for\_lingqu           | ✅ 已部署 | op-plugin 变体                                    | <br />                                                                                                                                                            |
| msopgen                          | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindIE-Motor-CPP                 | ✅ 已部署 | MindIE-Motor 变体                                 | <br />                                                                                                                                                            |
| msprof-analyze                   | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| torchao\_npu                     | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| MindIE-SD\_for\_lingqu           | ✅ 已部署 | MindIE-SD 变体                                    | <br />                                                                                                                                                            |
| slime-ascend                     | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| ATK                              | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| HierarchicalKV-ascend            | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| ascend-deployer                  | ✅ 已部署 | <br />                                          | <br />                                                                                                                                                            |
| CANN                             | ⚠ 待确认（OBS 方案）  | cann（report 中 3975 次，均为镜像标签/字段上下文，非 repo\_name） | 能否用 OBS 传输构建产物？需 OBS 对象零过期 + 强制校验，见 §1.2                                                                                                                          |

> 合计：已部署 24 个；有问题 2 个；待确认 1 个（CANN）；未部署（留 squid）34 项，去重变体后约 29 个新仓库
> （MindSpeed 系列、ms\* 系列、RAGSDK、ATK 等）。

### 1.2 待确认方案：OBS 传输构建产物（针对 CANN）

- **问题**：能否用 OBS 来传输 **CANN** 构建产物？
- **建议的特殊规则**：将该 OBS 桶内的所有对象设为 **零过期（zero expiration）**，并 **强制校验（force verify）**。
- 目的：构建产物长期可复用，避免因过期/校验失败导致重复回源或下载失败。

***

## 2. 参与开源（Contribute Open-source）

### 2.1 总览：squid 接入状态

- **当前结论：参与开源列表中的仓库全部暂未走 squid（均为「否」）。**
- 未接入原因：
  1. **runner pod / workflow pod 的注入测试尚未完成**（注入方式待验证）；
  2. **buildkit 场景被卡住**：buildkitd 的 dockerfile 代理与镜像重定向问题未解决。
- 待这两项打通后，vllm/verl/sglang 等仓库的构建依赖下载即可整体落到 squid 缓存。

### 2.2 仓库状态表（2026-09-10）

> squid 使用状态见 2.1（当前全部未接入）。

| 仓库                              | 状态             | 备注     | 问题描述   |
| ------------------------------- | -------------- | ------ | ------ |
| alibaba/ROLL                    | ⏳ 未部署          | <br /> | <br /> |
| areal-project/AReaL             | ⏳ 未部署          | <br /> | <br /> |
| Ascend/pytorch                  | ⏳ 未部署          | <br /> | <br /> |
| Ascend/sglang                   | ⏳ 未部署          | <br /> | <br /> |
| fla-org/flash-linear-attention  | ⏳ 未部署          | <br /> | <br /> |
| hiyouga/LlamaFactory            | ⏳ 未部署          | <br /> | <br /> |
| modelscope/ms-swift             | ⏳ 未部署          | <br /> | <br /> |
| sgl-project/sgl-kernel-npu      | ⏳ 未部署          | <br /> | <br /> |
| sgl-project/sglang              | ⏳ 未部署          | <br /> | <br /> |
| tile-ai/tilelang-mlir-ascend    | ⏳ 未部署          | <br /> | <br /> |
| triton-lang/triton-ascend       | ⏳ 未部署          | <br /> | <br /> |
| verl-project/verl               | ⏳ 未部署          | <br /> | <br /> |
| verl-project/verl-omni          | ⏳ 未部署          | <br /> | <br /> |
| verl-project/verl-SpeCo         | ⏳ 未部署          | <br /> | <br /> |
| vllm-ascend/vllm-ascend-recipes | ⏳ 未部署          | <br /> | <br /> |
| vllm-project/vllm-ascend        | ⏳ 未部署（9.14 部署） | <br /> | <br /> |
| vllm-project/vllm-omni          | ⏳ 未部署          | <br /> | <br /> |

