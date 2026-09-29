# 计划：移除测试流水线中的内部缓存（internal cache）

> 分支：`feat/remove-internal-cache-v2`（基于 `upstream/main`，commit dc5917094）
> 背景：镜像构建侧的内部缓存清理已由 PR #17100 覆盖；本分支只处理**测试类 workflow**，两者互补、互不冲突。

---

## 1. 目标

测试流水线（PR 测试 / 每日 & 每周夜测 / csrc 缓存构建）不再访问集群内部缓存服务
`cache-service.nginx-pypi-cache.svc.cluster.local`，改用公共源（官方 PyPI + 华为云 Ascend 仓 +
PyTorch CPU + triton-ascend.osinfra.cn），公共源加速由集群内 squid 代理缓存承担。

## 2. Runner ↔ Internal Cache 一对一映射（已解析为真实标签）

### 2.1 runner 标签命名规则

`linux-<架构>-<芯片/型号>-<NPU 数量>`

- 架构：全部测试机为 `aarch64`（CPU 类为 `amd64` / `arm64`）
- 芯片：`a2b3` = Atlas A2 (910B)；`a3-800i` = A3 800I 推理型；`a3-800t` = A3 800T 训练型；
  `a5` = Atlas A5 (950)；`310p` = Ascend 310P；`cpu` = 无 NPU
- 权威清单：`.github/workflows/scripts/runner_label.json`
- 夜测/周测实际用哪台机器：`.github/workflows/configs/nightly_config.yaml` 中每个测试用例的 `os:` 字段

### 2.2 动态表达式解析

| workflow 里的写法 | 实际来源 |
|---|---|
| `runs-on: ${{ matrix.group.runner }}` | 调用方传入的 `test_groups` JSON（如 pr_test.yaml#L259） |
| `runs-on: ${{ inputs.runner }}` | 调用方传 `matrix.test_config.os` ← `nightly_config.yaml` 的 `os:` 字段 |
| `runs-on: ${{ fromJSON(inputs.target).runner }}` | `csrc_cache_targets.json`，所有 target 均为 `linux-arm64-cpu-16` |

### 2.3 一对一映射表

| # | Runner（完整标签） | 用途 | Workflow | 内部缓存用法 |
|---|---|---|---|---|
| 1 | `linux-amd64-cpu-8-hk` | 代码检查/静态分析 | pr_test.yaml：pre-commit、recommend-tests、select-tests | `UV_INDEX_URL`（pypi 缓存） |
| 2 | `linux-amd64-cpu-8-hk` | 单元测试（cpu-ut 组） | _selected_tests.yaml `selected-tests` | UV 三件套 + APT sed `:8081` + pip config |
| 3 | `linux-aarch64-a2b3-1` | 上游 e2e（a2 单卡） | _selected_tests_upstream.yaml | 同 #2 全套 |
| 4 | `linux-aarch64-a3-16-sh-001` | main2main 合入前测试（a3 16 卡） | schedule_main2main.yaml | 同 #2 全套 |
| 5 | `linux-amd64-cpu-4-hk` | 解析 vLLM release tag | schedule_main2main / schedule_e2e_upstream_test 的 resolve-tag | `UV_INDEX_URL` |
| 6 | `linux-aarch64-a2b3-1` | 上游 e2e（3 个 job） | schedule_e2e_upstream_test.yaml | 同 #2 全套 |
| 7 | 夜测/周测 NPU 机器：<br>`linux-aarch64-a2b3-1/2/4/8`<br>`linux-aarch64-a3-800i-2/4/8/16`<br>`linux-aarch64-a5-8`<br>`linux-aarch64-310p-2/4`<br>setup 准备机：<br>`linux-aarch64-a2b3-0`<br>`linux-aarch64-a3-800t-0`<br>`linux-aarch64-a5-0` | 夜测 Nightly-A2/A3/A5/310p、周测 Weekly | _e2e_nightly_single_node.yaml<br>_e2e_nightly_single_node_560t.yaml<br>_e2e_nightly_single_node_models.yaml | UV_INDEX_URL + APT sed `:8081` + pip config |
| 8 | `linux-arm64-cpu-16`（纯 CPU） | csrc 编译缓存构建 | _build_csrc_cache.yaml | UV 三件套（含 `whl/cpu`）+ APT/YUM sed `:8081` + pip config |

## 3. 统一删除模式（5 种）

| 模式 | 内容 | 处理 |
|---|---|---|
| P1 | `UV_INDEX_URL: http://cache-service.../pypi/simple` | 整行删除（uv 回落官方 PyPI） |
| P2 | `UV_EXTRA_INDEX_URL: "... http://cache-service.../whl/cpu/"` | 剥离内部条目，仅保留公共源 |
| P3 | `UV_INSECURE_HOST: cache-service...` | 整行删除 |
| P4 | APT/YUM 源 sed 改写（`:8081`）+ `pip config set`（index-url / trusted-host） | 整行删除；步骤名 "Config mirrors" 改为 "Install packages" |
| P5 | e2e nightly 的 `PIP_EXTRA_INDEX_URL` | **不动**——三项均为公共源（华为云 Ascend 仓、triton-ascend.osinfra.cn、PyTorch CPU），triton-ascend wheel 只在 osinfra 公共索引有 |

## 4. 文件清单与进度

| 文件 | 模式 | 状态 |
|---|---|---|
| `.github/workflows/pr_test.yaml` | P1 | ✅ |
| `.github/workflows/_selected_tests.yaml` | P1–P4 | ✅ |
| `.github/workflows/_selected_tests_upstream.yaml` | P1–P4 | ✅ |
| `.github/workflows/schedule_main2main.yaml` | P1–P4 | ✅ |
| `.github/workflows/schedule_e2e_upstream_test.yaml` | P1–P4 ×3 处 | ✅ |
| `.github/workflows/_e2e_nightly_single_node.yaml` | P1–P4 | ⬜ |
| `.github/workflows/_e2e_nightly_single_node_560t.yaml` | P1–P4 | ⬜ |
| `.github/workflows/_e2e_nightly_single_node_models.yaml` | P1–P4 | ⬜ |
| `.github/workflows/_build_csrc_cache.yaml` | P1–P4（含 YUM） | ⬜ |

## 5. 明确不动的范围

- 镜像构建文件（8 个根 Dockerfile、4 个 nightly Dockerfile、`_schedule_image_build.yaml`、
  `_nightly_image_build.yaml`、`restore_public_sources.sh`）——PR #17100 已覆盖
- runner 标签本身——机器照用，只是不再访问内部缓存
- 公共源配置：华为云 Ascend pypi（`repo.huaweicloud.com/ascend/repos/pypi`）、
  `download.pytorch.org/whl/cpu`、`triton-ascend.osinfra.cn/pypi/simple`、
  Go 代理 `repo.huaweicloud.com/repository/goproxy/`
- SWR 容器镜像仓库（`swr.cn-*.myhuaweicloud.com`，公共镜像仓库，非内部缓存）

## 6. 验证

1. `git grep` 校验：测试类 workflow 中无 `cache-service` 残留
2. 9 个修改文件全部通过 YAML 语法校验（`python3 -c "import yaml; yaml.safe_load(...)"`）

## 7. 提交

- Commit：`fix(ci): remove internal cache-service references from test workflows`（含 sign-off）
- Push 到 fork 的 `feat/remove-internal-cache-v2` 分支
- 新建 PR → `vllm-project/vllm-ascend` 的 `main` 分支（与 #17100 互补，无文件交集）
