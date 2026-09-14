# vllm-benchmarks 全量流量审计：不应经过 squid 的场景与实测计划

> 审计对象：`../vllm-benchmarks` 仓库（vllm-ascend 基准/ nightly e2e 测试框架）。
> 审计前提：runner/workflow pod 被注入 `HTTP_PROXY/HTTPS_PROXY=http://squid-cache.squid.svc.cluster.local:3128`
> （MITM/SSL-Bump 模式），Python HTTP 客户端（requests/openai）**均未设 `trust_env=False`**，
> 完全依赖 env 层 `no_proxy` 兜底。
> 审计日期：2026-09-14。审计方式：全库静态扫描（workflows / conftest / tools / examples / Dockerfile），
> 关键引用已抽查核实。

---

## 1. 确定不应走 squid 的场景

### 1.1 本机/集群内部流量（会被代理直接打断或降级）

| 场景 | 目标地址 | 代码位置 | no_proxy 现状 |
|---|---|---|---|
| vLLM server 启动/健康检查/压测 client | `0.0.0.0:{port}`、`localhost`、`127.0.0.1` | `tests/e2e/conftest.py:291,375,520,894`、`tools/aisbench.py:63,265`、`tools/vllm_bench.py:69`、`tools/send_request.py:10` | ✅ 已覆盖（`0.0.0.0,localhost,127.0.0.1` 已入注入配方，2026-09 修复） |
| RLHF 权重传输/IPC（本机大流量） | `http://127.0.0.1:8000` 类 | `examples/rl/rlhf_http_hccl.py`、`rlhf_http_lora.py`、`rlhf_http_npu_ipc.py` | ✅ 已覆盖 |
| 集群内 pypi/apt/yum 缓存服务 | `cache-service.nginx-pypi-cache.svc.cluster.local`（pip/uv/apt/yum 共 10+ 处） | `_e2e_nightly_single_node*.yaml:87-99`、`_build_csrc_cache.yaml:66-107`、`_selected_tests_upstream.yaml:81` | ✅ 已覆盖（`.svc.cluster.local` 后缀匹配） |
| DP master / mooncake 协调（单节点） | `VLLM_DP_MASTER_IP=127.0.0.1`、本机端口 | `conftest.py:894,220-243` | ✅ 已覆盖（多节点 pod IP 见 §2.4） |
| PD 分离多节点 server 间探活 | `{pod_ip}:{port}/healthcheck` | `conftest.py:385,520` | ⚠️ pod IP 未覆盖（§2.4 实测后定） |

### 1.2 GHA 控制面（凭据 + 动态响应，MITM 无收益）

| 场景 | 目标地址 | 代码位置 |
|---|---|---|
| artifact 上传/下载/merge | `*.actions.githubusercontent.com` + Azure 签名 URL（`productionresultssa*.blob.core.windows.net`） | `_e2e_nightly_single_node.yaml`、`main2main-e2e.yaml`、`_schedule_image_build.yaml` |
| OIDC 令牌签发 | `token.actions.githubusercontent.com` | 带 `id-token: write` 的 workflow |
| PR bot / gh CLI / 权限校验 | `api.github.com` | `pr_test.yaml:56`、`bot_pr_create.yaml:54`、各 `pr_*_command.yml` |
| runner 框架 metadata 访问 | `169.254.169.254` | runner 自身（仓库代码无调用，必须 no_proxy 兜底） |

### 1.3 当前注入 no_proxy 的缺口

现有值：`0.0.0.0,localhost,127.0.0.1,.buildkitd,.svc.cluster.local,.cluster.local`

**缺失**：`::1`、`169.254.169.254`、`api.github.com`、`.actions.githubusercontent.com`、（多节点时）pod 网段 CIDR。

---

## 2. 不确定场景：精确实测计划

### 2.1 SWR 镜像 push（`swr.cn-southwest-2.myhuaweicloud.com`）

- 出处：`_schedule_image_build.yaml:324` 附近、`schedule_image_build_and_push.yaml`（Dockerfile FROM + push，带长期凭据）。
- 判定问题：push 走 rpardini（pull-only 设计）是否兼容；集群有无内网直连通路。
- 步骤：
  1. 测试 pod 内 `getent hosts swr.cn-southwest-2.myhuaweicloud.com`——解析到 `172.x/10.x` 内网 IP → 有内网通路；
  2. 同一小镜像各做 `docker pull` + `docker push` 两遍：一遍 `NO_PROXY=swr.cn-southwest-2.myhuaweicloud.com`（直连），一遍走 squid，对比成败/耗时；
  3. squid access.log `grep swr.cn-southwest-2` 查 PUT 的状态码是否有异常。
- 判定标准：内网解析成功 → no_proxy 直连；仅公网 → pull 走 squid（rpardini 缓存收益），push 直连。

### 2.2 OBS 端点（`vllm-ascend.obs.cn-north-4.myhuaweicloud.com` 与 runs-on/cache 后端 `obs.ap-southeast-1.myhuaweicloud.com`）

- 出处：`pr_test.yaml:262`（OBS 下载配置）、`pr_test.yaml`（`runs-on/cache@v5` S3 后端）。
- 判定问题：是否 VPC 内网可达；签名 URL 过 squid 是否被缓存污染。
- 步骤：
  1. 测试 pod 内 `getent hosts` 两个域名——IP 属内网网段 → 直连；
  2. 同一对象 `curl -x squid` 与 `NO_PROXY` 直连各下载一遍测耗时；
  3. 用 `runs-on/cache` 跑一次真实 job，access.log `grep obs.ap-southeast-1` 看有无 4xx/签名失败。
- 判定标准：内网可达 → no_proxy；签名 URL 出现 403 且 access.log 显示缓存命中 → squid 侧对该域加 `cache deny`。

### 2.3 `apig.openlibing.com`（测试结果上报，带凭据）

- 出处：`tools/upload_to_openlibing.py:22,90,100-102`（`X-Apig-AppCode/AppKey/AppSecret` 凭据头）。
- 判定问题：凭据 POST 过 MITM 的功能正确性；是否直连属安全策略。
- 步骤：走 squid 上报一条测试元数据确认 200；access.log 确认 POST 未被缓存/未 4xx。
- 判定标准：功能必通；建议默认 no_proxy 直连（凭据暴露面收敛）。

### 2.4 多节点 pod 间流量（PD 分离 / mooncake master 绑定地址）

- 判定问题：多节点时这些服务绑 pod IP 还是 127.0.0.1；pod IP 流量是否真的经 squid。
- 步骤：
  1. 核对 `conftest.py:220-243` mooncake master/metrics bind 参数来源；
  2. 跑一次 multi-node job，squid access.log `grep -E '(POST|GET).*(10\.|172\.|192\.168\.)'` 看是否出现 pod IP 请求；
  3. 若出现 → 测 SSE 长流式响应过 squid 是否被 `read_timeout 30min` 掐断。
- 判定标准：access.log 有 pod IP 流量 → pod CIDR 入 no_proxy（先实测各客户端 CIDR 支持：curl ≥7.86 / Go ≥1.16 / Python 部分版本）或改 `trust_env=False`。

### 2.5 ModelScope 大模型（`modelscope.cn`，数十 GB）

- 出处：`tests/e2e/conftest.py:46,1899-1934`、`tools/aisbench.py:30,337`、`tools/send_mm_request.py:10,39`。
- 判定问题：缓存收益 vs squid 磁盘容量。
- 步骤：单模型 `snapshot_download` 两遍看第二遍 HIT%；观察 exporter 的 cache_dir 水位。
- 判定标准：HIT 高但磁盘吃满 → 对模型域设 `maximum_object_size`/`cache deny` 或接受 eviction。

---

## 3. 汇总

- **A 类（确定不走 squid）**：本机回环/集群 Service（已覆盖）+ GHA 控制面三域 + metadata（**待补 no_proxy**）。
- **B 类（待实测）**：SWR push、OBS 内网可达性、openlibing、多节点 pod IP、ModelScope 磁盘压力（§2 各有精确测试步骤与判定标准）。
- **架构事实**：仓库内无任何 `no_proxy`/`trust_env=False`/`--noproxy` 写法 → 所有绕代理诉求只能落在注入侧 env。
- 建议动作：先补 A 类 no_proxy 缺口（零风险），B1/B4 各约 10 分钟实测后定夺。

## 4. 实测证据

- 全库静态扫描：8 类流量来源逐项核实（workflows / conftest / tools / examples / benchmarks / Dockerfile / .gitmodules）。
- 关键引用抽查：`cache-service.nginx-pypi-cache.svc.cluster.local` 在 `_e2e_nightly_single_node_models.yaml:87-99`、
  `_build_csrc_cache.yaml:66-107`、`_selected_tests_upstream.yaml:81-82` 等 10+ 处确认；`tools/aisbench.py:63,265`
  localhost 压测确认；workflows 文件清单确认。
- 关联文档：`deploy/CACHE-STRATEGY.md` §9（不应过缓存的流量四维盘点 + PUT 语义）、`deploy/DEPLOY.md`（注入配方）。
