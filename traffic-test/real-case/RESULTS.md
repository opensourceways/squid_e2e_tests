# Squid 代理注入测试结果

生成时间: 2026-08-25 10:49:25
- 已测试: **75**
- 通过(verdict=passed): **39**
- 失败(verdict=failed): **36**
- 未知: **0**
- 成功率: **52.0%**

> verdict 由 queue3 解析主容器日志得出（Volcano phase 因
> `PodFailed→AbortJob` policy 会把成功跑完的 job 也标成 Aborted，
> 故不能直接当成功/失败信号）。

| # | type_key | desc | namespace | phase | verdict | duration | image |
|---|---|---|---|---|---|---|---|
| 1 | 5282e60f | pytorch_2.11.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 8.1m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 2 | daef57bf | pytorch_2.11.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 6.1m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 3 | af9d5ba8 | pytorch_2.7.1_a2_aarch64_builder:20260610 | git config --global url."http://git- | op-plugin | Aborted | ✅ OK | 1.5m | pytorch_2.7.1_a2_aarch64_builder:20260610 |
| 4 | 66b32138 | pytorch_2.11.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 6.1m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 5 | 3b185be1 | pytorch_2.12.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ✅ OK | 20.0m | pytorch_2.12.0_a2_aarch64_builder:20260518 |
| 6 | fe574089 | pytorch_2.13.0_a2_aarch64_builder:20260709 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.13.0_a2_aarch64_builder:20260709 |
| 7 | 24548b3c | pytorch_2.13.0_a2_aarch64_builder:20260709 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.13.0_a2_aarch64_builder:20260709 |
| 8 | f8074649 | pytorch_2.7.1_a2_aarch64_builder:20260610 | git config --global url."http://git- | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.7.1_a2_aarch64_builder:20260610 |
| 9 | 357a760f | pytorch_2.7.1_a2_aarch64_builder:20260610 | git config --global url."http://git- | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.7.1_a2_aarch64_builder:20260610 |
| 10 | b8fbd249 | pytorch_2.7.1_a2_aarch64_builder:20260610 | git config --global url."http://git- | op-plugin | Aborted | ❌ Aborted | 1.5m | pytorch_2.7.1_a2_aarch64_builder:20260610 |
| 11 | 96087e3c | pytorch_2.7.1_a2_aarch64_builder:20260610 | git config --global url."http://git- | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.7.1_a2_aarch64_builder:20260610 |
| 12 | 90e8649c | pytorch_2.13.0_a2_aarch64_builder:20260709 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.13.0_a2_aarch64_builder:20260709 |
| 13 | 6d3aa115 | pytorch_2.12.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 2.5m | pytorch_2.12.0_a2_aarch64_builder:20260518 |
| 14 | 63a01256 | pytorch_2.11.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Completed | ✅ OK | 4.6m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 15 | 0aa894ed | pytorch_2.10.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 9.6m | pytorch_2.10.0_a2_aarch64_builder:20260518 |
| 16 | 129601b2 | pytorch_2.10.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Completed | ✅ OK | 20.7m | pytorch_2.10.0_a2_aarch64_builder:20260518 |
| 17 | 2664560c | pytorch_2.10.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Completed | ✅ OK | 2.5m | pytorch_2.10.0_a2_aarch64_builder:20260518 |
| 18 | 747a986a | pytorch_2.13.0_a2_aarch64_builder:20260709 | git config --global url."http://git | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.13.0_a2_aarch64_builder:20260709 |
| 19 | 478e1a41 | pytorch_2.12.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Completed | ✅ OK | 2.5m | pytorch_2.12.0_a2_aarch64_builder:20260518 |
| 20 | 509ee9b9 | pytorch_2.11.0_a2_aarch64_builder:20260518 | git config --global url."http://git | op-plugin | Completed | ✅ OK | 2.6m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 21 | 82066243 | pr-mindspeed-bridge:master-910b-openeuler24.03-cann9.1.0-beta.3-torchnpu2.9.0-py | mindspeed-bridge | Completed | ✅ OK | 11.1m | pr-mindspeed-bridge:master-910b-openeuler24.03-cann9.1.0-beta.3-torchnpu2.9.0-py3.12-aarch64 |
| 22 | df2d2044 | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.1 | mindspeed-mm | Completed | ✅ OK | 2.0m | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.11-aarch64-ci |
| 23 | 31b05f95 | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_general.sh | v2.9.0 | op-plugin | Aborted | ❌ Aborted | 8.1m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 24 | be2ecefc | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.7.1 | op-plugin | Completed | ✅ OK | 39.3m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 25 | f645209f | pytorch_2.13.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | master | op-plugin | Completed | ✅ OK | 4.5m | pytorch_2.13.0_a2_aarch64_builder:20260804 |
| 26 | f0c5846a | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.7.1 | op-plugin | Aborted | ❌ Aborted | 7.6m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 27 | 639503f5 | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.10.0 | op-plugin | Completed | ✅ OK | 54.0m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 28 | ce900cb9 | pytorch_master_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | master | op-plugin | Completed | ✅ OK | 2.0m | pytorch_master_a2_aarch64_builder:20260804 |
| 29 | 7e1a544d | 1 | pytorch_ut_dist.sh | master | op-plugin | Aborted | ❌ Aborted | 240.5m | 1 |
| 30 | 26202f4f | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.10.0 | op-plugin | Completed | ✅ OK | 2.5m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 31 | e6e1a327 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.11.0 | op-plugin | Aborted | ❌ Aborted | 9.6m | pytorch_2.11.0_a2_aarch64_builder:20260804 |
| 32 | b19a391a | pytorch_2.13.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | master | op-plugin | Completed | ✅ OK | 56.5m | pytorch_2.13.0_a2_aarch64_builder:20260804 |
| 33 | 04133b7c | pytorch_2.13.0_a2_aarch64_builder:20260709 | no-ut | master | op-plugin | Aborted | ❌ Aborted | 5.0m | pytorch_2.13.0_a2_aarch64_builder:20260709 |
| 34 | 7c08b453 | pytorch_2.10.0_a2_aarch64_builder:20260518 | no-ut | master | op-plugin | Completed | ✅ OK | 14.1m | pytorch_2.10.0_a2_aarch64_builder:20260518 |
| 35 | d9e3d6a6 | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.7.1 | op-plugin | Aborted | ❌ Aborted | 5.6m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 36 | ff658798 | mindstudio-st-msprof:26.1.0-0708-test3 | no-ut | no-branch | argo | Aborted | ❌ Aborted | 0.5m | mindstudio-st-msprof:26.1.0-0708-test3 |
| 37 | 01a6886a | pytorch_2.12.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.12.0 | op-plugin | Aborted | ❌ Aborted | 7.6m | pytorch_2.12.0_a2_aarch64_builder:20260804 |
| 38 | 130c0270 | pytorch_2.10.0_a2_aarch64_builder:20260518 | pytorch_ut_dist.sh | v2.10.0 | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.10.0_a2_aarch64_builder:20260518 |
| 39 | 50525377 | pytorch_2.12.0_a2_aarch64_builder:20260518 | pytorch_ut_dist.sh | v2.12.0 | op-plugin | Completed | ✅ OK | 8.1m | pytorch_2.12.0_a2_aarch64_builder:20260518 |
| 40 | 33b4eae2 | pytorch_2.11.0_a2_aarch64_builder:20260518 | no-ut | master | op-plugin | Completed | ✅ OK | 0.5m | pytorch_2.11.0_a2_aarch64_builder:20260518 |
| 41 | fe2c1abb | pytorch_2.9.0_a2_aarch64_builder:20260518 | no-ut | master | op-plugin | Completed | ✅ OK | 0.5m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 42 | 81588bdf | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_dist.sh | v2.9.0 | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 43 | a55ee33d | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_inductor.sh | v2.9.0 | op-plugin | Aborted | ❌ Aborted | 48.9m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 44 | 36d92f95 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.11.0 | op-plugin | Completed | ✅ OK | 4.0m | pytorch_2.11.0_a2_aarch64_builder:20260804 |
| 45 | bd637fca | drivingsdk_arm:cann8.5.0 | no-ut | no-branch | mindspeed-bridge | Completed | ✅ OK | 0.5m | drivingsdk_arm:cann8.5.0 |
| 46 | 3e939d14 | pytorch_master_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | master | op-plugin | Completed | ✅ OK | 8.6m | pytorch_master_a2_aarch64_builder:20260804 |
| 47 | ee60019a | pytorch_master_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | master | op-plugin | Aborted | ❌ Aborted | 1.5m | pytorch_master_a2_aarch64_builder:20260804 |
| 48 | e30feb3c | pytorch_2.7.1_a2_aarch64_builder | no-ut | master | op-plugin | Aborted | ❌ Aborted | 224.2m | pytorch_2.7.1_a2_aarch64_builder |
| 49 | de634461 | pytorch_2.12.0_a2_aarch64_builder:20260518 | no-ut | master | op-plugin | Aborted | ❌ Aborted | 5.0m | pytorch_2.12.0_a2_aarch64_builder:20260518 |
| 50 | ade811ee | pytorch_2.13.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | master | op-plugin | Aborted | ❌ Aborted | 14.6m | pytorch_2.13.0_a2_aarch64_builder:20260804 |
| 51 | 5551dc15 | pytorch_2.11.0_a2_aarch64_builder | pytorch_ut_inductor.sh | v2.11.0 | op-plugin | Completed | ✅ OK | 49.1m | pytorch_2.11.0_a2_aarch64_builder |
| 52 | d0f57803 | pytorch_master_a2_aarch64_builder | no-ut | no-branch | op-plugin | Completed | ✅ OK | 8.6m | pytorch_master_a2_aarch64_builder |
| 53 | 6e83bb01 | pytorch_2.10.0_a2_aarch64_builder | no-ut | no-branch | op-plugin | Completed | ✅ OK | 59.0m | pytorch_2.10.0_a2_aarch64_builder |
| 54 | c260a2d8 | pytorch_2.13.0_a2_aarch64_builder | no-ut | no-branch | op-plugin | Completed | ✅ OK | 2.5m | pytorch_2.13.0_a2_aarch64_builder |
| 55 | 4ac33d52 | pytorch_2.9.0_a2_aarch64_builder | no-ut | no-branch | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.9.0_a2_aarch64_builder |
| 56 | e2b7e8ab | pytorch_2.11.0_a2_aarch64_builder | no-ut | no-branch | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.11.0_a2_aarch64_builder |
| 57 | 13b689c1 | pytorch_2.7.1_a2_aarch64_builder | no-ut | no-branch | op-plugin | Aborted | ❌ Aborted | 1.0m | pytorch_2.7.1_a2_aarch64_builder |
| 58 | 089d2e4d | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.10.0-26. | op-plugin | Completed | ✅ OK | 2.5m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 59 | 40aef589 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.11.0-26. | op-plugin | Completed | ✅ OK | 40.4m | pytorch_2.11.0_a2_aarch64_builder:20260804 |
| 60 | fe1e619c | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.10.0-26. | op-plugin | Completed | ✅ OK | 38.9m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 61 | c242c4c1 | pytorch_2.12.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.12.0-26. | op-plugin | Completed | ✅ OK | 19.2m | pytorch_2.12.0_a2_aarch64_builder:20260804 |
| 62 | d65b7cb9 | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.7.1-26.1. | op-plugin | Completed | ✅ OK | 28.3m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 63 | b2e6581a | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.7.1-26.1 | op-plugin | Completed | ✅ OK | 43.0m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 64 | a38d4455 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.11.0-26.1.0 | op-plugin | Completed | ✅ OK | 41.5m | pytorch_2.11.0_a2_aarch64_builder:20260804 |
| 65 | 824cdb1d | pytorch_2.12.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.12.0-26.1.0 | op-plugin | Aborted | ❌ Aborted | 1.5m | pytorch_2.12.0_a2_aarch64_builder:20260804 |
| 66 | 09087754 | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.10.0-26 | op-plugin | Completed | ✅ OK | 48.5m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 67 | 7894ca3b | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_inductor.sh | v2.9.0-26.1 | op-plugin | Completed | ✅ OK | 33.7m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 68 | 660d5e2a | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.7.1-26.1.0 | op-plugin | Aborted | ❌ Aborted | 72.8m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 69 | 8cba161f | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.10.0-26.1.0 | op-plugin | Aborted | ❌ Aborted | 3.5m | pytorch_2.10.0_a2_aarch64_builder:20260804 |
| 70 | 1645c555 | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_general.sh | v2.9.0-26.1. | op-plugin | Completed | ✅ OK | 9.6m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 71 | b29694e4 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.11.0-26 | op-plugin | Completed | ✅ OK | 37.7m | pytorch_2.11.0_a2_aarch64_builder:20260804 |
| 72 | 8f2ab07e | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_dist.sh | v2.9.0-26.1.0 | op-plugin | Aborted | ❌ Aborted | 5.6m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 73 | af3ffd28 | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.7.1-26.0. | op-plugin | Completed | ✅ OK | 6.6m | pytorch_2.7.1_a2_aarch64_builder:20260804 |
| 74 | 53a251b2 | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_general.sh | v2.9.0-26.0. | op-plugin | Completed | ✅ OK | 4.5m | pytorch_2.9.0_a2_aarch64_builder:20260518 |
| 75 | 3ea9f77c | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.1 | mindspeed-mm | Aborted | ❌ Aborted | 8.6m | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.11-aarch64-ci-0824 |
