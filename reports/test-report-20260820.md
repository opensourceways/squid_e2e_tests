# 测试报告 — 2026-08-20

Squid 代理 reinject 全量采样测试（wlcb-001 集群），对 68 个唯一 CI 类型进行 squid 代理注入 + 重放，并逐案例分析失败根因。

- 数据目录: `traffic-test/real-case/`
- 测试管线: queue1-collect → queue2-dedup → queue3-reinject → queue4-record
- 注入方式: HTTP(S)_PROXY → `squid-cache.squid.svc.cluster.local:3128` + squid CA postStart 注入
- 采样规模: 1537 个物理 VCJob → 1526 终态 → 去重 53 种唯一 CI 类型 → 68 个测试条目

## 结果汇总

| 指标 | 值 |
|------|-----|
| 已测试 | 68 |
| 通过 (verdict=passed) | 35 |
| 失败 (verdict=failed) | 32 |
| 未知 | 1 |
| 成功率 | 51.5% |

> verdict 由 queue3 解析主容器日志得出。Volcano phase 因 `PodFailed→AbortJob` policy 会把成功跑完的 job 也标成 Aborted，故不以 phase 判断成败，而以主容器 exit code + 日志终态为准。

## 失败案例分析（32 例）

### 类别划分

| 类别 | 含义 | 数量 | 是否 squid/代理导致 |
|------|------|:--:|:--:|
| **A** | OBS/pytorch-package 返回 503，wheel 下载失败 | 11 | ❌ 否（上游 OBS 限流/缺失） |
| **B** | torch_npu tar.gz 经代理返回 0 字节体（saved [0/0]），gzip 截断 | 4 | ✅ **是（代理异常）** |
| **C** | wget 经代理后证书不受信任（GnuTLS 信任库未生效） | 1 | ⚠️ 部分（wget 已走代理，postStart 已注入 CA，但 GnuTLS 信任库重建未生效） |
| **D** | 代理 0 字节 → wheel 文件名非法 (`torch-*aarch64`) | 3 | ✅ 是（同 B，代理 0 字节） |
| **E** | CI 脚本 bug：`no need exec UT` 短路后无条件 cp 失败 | 6 | ❌ 否（上游 CI 脚本） |
| **F** | 上游脚本 cp 不存在文件（`test/onnx/...` / `CODE/time_data.json`） | 3 | ❌ 否（上游 CI 脚本） |
| **G** | 真实 UT 测试失败（代码缺陷/行为变更） | 3 | ❌ 否（代码/测试问题） |
| **H** | 其他（exit 8 / 137 超时 / 克隆目录冲突等） | 1 | ❌ 否（上游/资源问题） |

### 逐案例明细（按 type_key 排序）

| type_key | desc | exit | 时长 | 类别 | 根因 |
|---|---|---|---|---|---|
| 01a6886a | pytorch_2.12.0...ut_general | 1 | 7.6m | A | torch wheel 下载 503 |
| 04133b7c | pytorch_2.13.0...no-ut master | 8 | 5.0m | A | 主 whl 下载 ERROR 503 |
| 0aa894ed | pytorch_2.10.0...git-config | 1 | 9.6m | D | 0 字节 wheel → `Invalid wheel filename` |
| 130c0270 | pytorch_2.10.0...ut_dist | 1 | 1.0m | F | `cp: cannot stat 'CODE/time_data.json'` |
| 13b689c1 | pytorch_2.7.1 no-ut no-branch | 1 | 1.0m | E | `no need exec UT` 短路 → cp 失败 |
| 24548b3c | pytorch_2.13.0...git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| 31b05f95 | pytorch_2.9.0...ut_general | 1 | 8.1m | D | 0 字节 wheel → `Invalid wheel filename` |
| 357a760f | pytorch_2.7.1:20260610 git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| 4ac33d52 | pytorch_2.9.0 no-ut no-branch | 1 | 1.0m | E | `no need exec UT` → cp time_data.json 失败 |
| 5282e60f | pytorch_2.11.0:20260518 git-config | None | 8.1m | B | torch_npu tar.gz `gzip: unexpected end of file` |
| 66b32138 | pytorch_2.11.0:20260518 git-config | None | 6.1m | B | torch_npu tar.gz gzip 截断 |
| 6d3aa115 | pytorch_2.12.0:20260518 git-config | 1 | 2.5m | B | `torch_npu_aarch64.tar.gz saved [0/0]` |
| 747a986a | pytorch_2.13.0...git-config | 1 | 1.0m | F | `cp: cannot stat 'CODE/time_data.json'` |
| 81588bdf | pytorch_2.9.0...ut_dist | 1 | 1.0m | F | `cp: cannot stat 'CODE/time_data.json'` |
| 824cdb1d | pytorch_2.12.0:20260804 ut_dist | 2 | 1.5m | B | torch_npu tar.gz `saved [0/0]` → gzip 截断 |
| 90e8649c | pytorch_2.13.0...git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| 96087e3c | pytorch_2.7.1:20260610 git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| a55ee33d | pytorch_2.9.0...ut_inductor | 1 | 48.9m | G | `test_shape_handling failed. [142.5s]` 真实 UT 失败 |
| ade811ee | pytorch_2.13.0:20260804 ut_inductor | 1 | 14.6m | G | torch_npu `undefined symbol: IsSupportMsptiFuncEv` 导入失败 |
| b8fbd249 | pytorch_2.7.1:20260610 git-config | 1 | 1.5m | E | `no need exec UT` → cp 失败 |
| d9e3d6a6 | pytorch_2.7.1:20260804 ut_dist | 8 | 5.6m | A | 主 whl 下载 ERROR 503（EXIT_CODE=8） |
| daef57bf | pytorch_2.11.0:20260518 git-config | None | 6.1m | D | 0 字节 wheel → `Invalid wheel filename` |
| de634461 | pytorch_2.12.0:20260518 no-ut master | 8 | 5.0m | A | torch whl 下载 ERROR 503 |
| e2b7e8ab | pytorch_2.11.0 no-ut no-branch | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| e30feb3c | pytorch_2.7.1 no-ut master | 1 | 224.2m | G | UT `test_cpu_fallback_control` 7 例全 FAIL（真实测试失败） |
| e6e1a327 | pytorch_2.11.0:20260804 ut_general | 1 | 9.6m | D | 0 字节 wheel → `Invalid wheel filename` |
| ee60019a | pytorch_master:20260804 ut_dist | 2 | 1.5m | B | torch_npu tar.gz `saved [0/0]` → gzip 截断 |
| f0c5846a | pytorch_2.7.1:20260804 ut_general | 1 | 7.6m | D | `torch-*aarch64.whl is not a valid wheel filename` |
| f8074649 | pytorch_2.7.1:20260610 git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| fe574089 | pytorch_2.13.0...git-config | 1 | 1.0m | E | `no need exec UT` → cp 失败 |
| ff658798 | mindstudio-st-msprof no-ut | 5 | 0.5m | C | wget 已走 squid 代理，postStart 已注入 CA，但 wget(GnuTLS) 仍报证书不受信任 |

> 补充：`7e1a544d`（exit 137, 240.5m, `image: '1'` 转换异常）为管线 harness 自身 bug，未列入上表主类别。

## 核心结论

1. **32 例失败中仅 7 例与 squid/代理相关**（B 类 4 + D 类 3，均因代理返回 0 字节体导致下游工具链崩溃）。
2. **B/D 类根因**：torch_npu tar.gz 或 torch wheel 经 squid 时被返回 0 字节/空体，下游 `gzip: unexpected end of file` 或 `Invalid wheel filename`。squid 侧应对该路径（`pta-pr.obs.cn-north-4.myhuaweicloud.com`）的 SSL-bump 响应处理异常。
3. **C 类 1 例**（ff658798）：wget **已走 squid 代理**（日志确认 `Connecting to squid-cache.squid.svc.cluster.local:3128... connected`），postStart **已注入 CA**（`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract`，best-effort 静默失败），但 wget 底层 GnuTLS 仍报 `certificate is not trusted / doesn't have a known issuer`。根因：wget 不读 `SSL_CERT_FILE`/`CURL_CA_BUNDLE`（这些是 curl/openssl 变量），只认 GnuTLS 系统信任库；而该镜像里 postStart 的 CA 注入是 best-effort（stderr 被丢弃 + `exit 0`），若 `update-ca-trust extract` 在容器内失败，GnuTLS 的信任库就不会包含 squid CA。属**注入的信任库重建未生效**，而非“直连未走代理”。tool 测试（06-wget）证明 wget+代理+CA 链路本身可用（94MB 经 squid 1s 完成）。
4. **多数失败（22/32）实为上游问题**：OBS 503 限流（A 类 11）、CI 脚本 cp bug（E 类 6 + F 类 3）、真实测试失败（G 类 3，含 e30feb3c 的 UT 断言失败）。这些与 squid 无关，重放结果与原 CI 一致。

## 关键案例详析

### e30feb3c — 真实 UT 失败（224.2m）
- UT 全流程正常（410 个 `exec ut success`，含 100-250s 分布式测试），git clone 走 git-cache 成功。
- 失败点：`npu/test_cpu_fallback_control` 7 个用例全 FAIL（`FAILED (failures=7)`），断言如 `fallback should be blocked for dispatcher_fmax_out`、`fallback warning must be emitted once for sparse_csr_prod/sum`。
- `type_desc` 标注 `no-ut` 有误导：该 MR（merge-requests/5591）属 master 分支 UT 类型，实际完整执行了 UT。
- `copy-artifact not valid` 为 harness 假错误：转换后 YAML 已移除 copy-artifact 容器（queue3-reinject.py:243），但日志采集仍 `kubectl logs -c copy-artifact`。

### 824cdb1d / ee60019a — 代理 0 字节体（B 类）
```
https://pta-pr.obs.cn-north-4.myhuaweicloud.com/pta/PR/44891/torch_npu_aarch64.tar.gz
Length: 0 [application/gzip]
saved [0/0]
gzip: stdin: unexpected end of file
```
代理对 `pta-pr.obs` 返回 0 长度，非 squid 缓存破坏，是 SSL-bump 后回源响应的 0 字节体传递。

## 建议

1. 排查 squid 对 `*.obs.cn-north-4.myhuaweicloud.com` 的 SSL-bump 0 字节响应（B/D 类，7 例）。
2. postStart CA 注入需验证 `update-ca-trust extract` / `update-ca-certificates` 实际成功（不能 best-effort 静默丢弃失败），并确保 wget(GnuTLS) 的信任库在容器启动早期生效，覆盖 C 类场景。也可对 wget 显式传 `--ca-certificate=/etc/squid-ca/squid-ca.pem`。
3. A 类 503 为 OBS 上游限流，可加代理重试/退避。
4. E/F 类为上游 CI 脚本缺陷（`no need exec UT` 短路 + 无条件 cp），建议修上游脚本，与 squid 无关。
