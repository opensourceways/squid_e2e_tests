# wlcb-001 VCJob 采样汇总
生成时间: 2026-08-25 10:49:25
- 观测到 job 数（物理）: **3602**
- 进入终态 job 数: **3598**
- 去重后唯一 CI 类型: **57**
- 终态分布: Aborted=397, Completed=3201

## 唯一 CI 类型

| type_key | desc | terminal | phases | job |
|---|---|---|---|---|
| c37d028a | alpine:3.23.3 | no-ut | no-branch | Aborted | Aborted | argo/testorg-testrepo-test9-59258 |
| 82066243 | pr-mindspeed-bridge:master-910b-openeuler24.03-cann9.1.0-beta.3-torchnpu2.9.0-py3.12-aarch64 | no-ut | master | Aborted | Aborted | mindspeed-bridge/mindspeed-bridge-ascend-mindspeed-bridge-7pxkj |
| 31b05f95 | pytorch_2.9.0_a2_aarch64_builder | pytorch_ut_general.sh | v2.9.0 | Completed | Completed | op-plugin/ascend-pytorch-5tlgj |
| 639503f5 | pytorch_2.10.0_a2_aarch64_builder | pytorch_ut_inductor.sh | v2.10.0 | Completed | Completed | op-plugin/ascend-pytorch-8slt4 |
| 04133b7c | pytorch_2.13.0_a2_aarch64_builder | no-ut | master | Aborted | Aborted | op-plugin/op-plugin-ascend-op-plugin-5q56s |
| 7c08b453 | pytorch_2.10.0_a2_aarch64_builder | no-ut | master | Aborted | Aborted | op-plugin/op-plugin-ascend-op-plugin-cf87j |
| f0c5846a | pytorch_2.7.1_a2_aarch64_builder | pytorch_ut_general.sh | v2.7.1 | Completed | Running>Completed | op-plugin/ascend-pytorch-7bbr2 |
| d9e3d6a6 | pytorch_2.7.1_a2_aarch64_builder | pytorch_ut_dist.sh | v2.7.1 | Completed | Running>Completed | op-plugin/ascend-pytorch-lwtw6 |
| df2d2044 | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.11-aarch64-ci | no-ut | no-branch | Completed | Running>Completed | mindspeed-mm/ascend-mindspeed-mm-8sp8t |
| f645209f | pytorch_2.13.0_a2_aarch64_builder | pytorch_ut_general.sh | master | Completed | Running>Completed | op-plugin/ascend-pytorch-6qw5g |
| 01a6886a | pytorch_2.12.0_a2_aarch64_builder | pytorch_ut_general.sh | v2.12.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-d4wcc |
| 26202f4f | pytorch_2.10.0_a2_aarch64_builder | pytorch_ut_general.sh | v2.10.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-r5t9b |
| b19a391a | pytorch_2.13.0_a2_aarch64_builder | pytorch_ut_dist.sh | master | Completed | Running>Completed | op-plugin/ascend-pytorch-zc5nn |
| e6e1a327 | pytorch_2.11.0_a2_aarch64_builder | pytorch_ut_general.sh | v2.11.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-vf8xq |
| fe2c1abb | pytorch_2.9.0_a2_aarch64_builder | no-ut | master | Completed | Running>Completed | op-plugin/ascend-op-plugin-4btfd |
| be2ecefc | pytorch_2.7.1_a2_aarch64_builder | pytorch_ut_inductor.sh | v2.7.1 | Aborted | Running>Aborted | op-plugin/ascend-pytorch-5xz7j |
| 33b4eae2 | pytorch_2.11.0_a2_aarch64_builder | no-ut | master | Completed | Running>Completed | op-plugin/ascend-op-plugin-8gm75 |
| 81588bdf | pytorch_2.9.0_a2_aarch64_builder | pytorch_ut_dist.sh | v2.9.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-6x4qt |
| ff658798 | mindstudio-st-msprof:26.1.0-0708-test3 | no-ut | no-branch | Aborted | Pending>Running>Aborted | argo/job-script-s4sl4 |
| 130c0270 | pytorch_2.10.0_a2_aarch64_builder | pytorch_ut_dist.sh | v2.10.0 | Completed | Pending>Running>Completed | op-plugin/ascend-pytorch-c2mm6 |
| a55ee33d | pytorch_2.9.0_a2_aarch64_builder | pytorch_ut_inductor.sh | v2.9.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-k6vnt |
| 36d92f95 | pytorch_2.11.0_a2_aarch64_builder | pytorch_ut_dist.sh | v2.11.0 | Completed | Pending>Running>Completed | op-plugin/ascend-pytorch-db6ct |
| 50525377 | pytorch_2.12.0_a2_aarch64_builder | pytorch_ut_dist.sh | v2.12.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-9xjnv |
| 7e1a544d | 1 | pytorch_ut_dist.sh | master | Aborted | Pending>Aborted | op-plugin/ascend-pytorch-mhnwp |
| ce900cb9 | pytorch_master_a2_aarch64_builder | pytorch_ut_inductor.sh | master | Aborted | Running>Aborted | op-plugin/ascend-pytorch-9cf9m |
| 3e939d14 | pytorch_master_a2_aarch64_builder | pytorch_ut_general.sh | master | Completed | Running>Completed | op-plugin/ascend-pytorch-2gf9v |
| bd637fca | drivingsdk_arm:cann8.5.0 | no-ut | no-branch | Completed | Pending>Running>Completed | mindspeed-bridge/ascend-mindspeed-bridge-5685l |
| ee60019a | pytorch_master_a2_aarch64_builder | pytorch_ut_dist.sh | master | Aborted | Running>Aborted | op-plugin/ascend-pytorch-765k5 |
| ade811ee | pytorch_2.13.0_a2_aarch64_builder | pytorch_ut_inductor.sh | master | Completed | Running>Completed | op-plugin/ascend-pytorch-hpmx9 |
| de634461 | pytorch_2.12.0_a2_aarch64_builder | no-ut | master | Aborted | Running>Aborted | op-plugin/ascend-op-plugin-xqq8f |
| e30feb3c | pytorch_2.7.1_a2_aarch64_builder | no-ut | master | Completed | Running>Completed | op-plugin/ascend-op-plugin-d65qg |
| 5551dc15 | pytorch_2.11.0_a2_aarch64_builder | pytorch_ut_inductor.sh | v2.11.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-7gmlv |
| d0f57803 | pytorch_master_a2_aarch64_builder | no-ut | no-branch | Completed | Running>Completed | op-plugin/ascend-pytorch-jtqsx |
| c260a2d8 | pytorch_2.13.0_a2_aarch64_builder | no-ut | no-branch | Completed | Running>Completed | op-plugin/ascend-pytorch-h2vzt |
| 6e83bb01 | pytorch_2.10.0_a2_aarch64_builder | no-ut | no-branch | Completed | Running>Completed | op-plugin/ascend-pytorch-kkrlb |
| e2b7e8ab | pytorch_2.11.0_a2_aarch64_builder | no-ut | no-branch | Completed | Running>Completed | op-plugin/ascend-pytorch-vlznz |
| 13b689c1 | pytorch_2.7.1_a2_aarch64_builder | no-ut | no-branch | Completed | Pending>Running>Completed | op-plugin/ascend-pytorch-2r52c |
| 4ac33d52 | pytorch_2.9.0_a2_aarch64_builder | no-ut | no-branch | Completed | Running>Completed | op-plugin/ascend-pytorch-2ppkj |
| 089d2e4d | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.10.0-26.0.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-55c72 |
| 40aef589 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.11.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-rpk74 |
| fe1e619c | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.10.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-f6wtj |
| cb2b69db | rclone:sha-adc7f2e | no-ut | no-branch | Aborted | Aborted>Running>Pending | ascend-data-sync/syncpvc-gy2wlcb |
| c242c4c1 | pytorch_2.12.0_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.12.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-flqtq |
| d65b7cb9 | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.7.1-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-h8z8c |
| b2e6581a | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.7.1-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-n6x6q |
| a38d4455 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.11.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-gxdnv |
| 824cdb1d | pytorch_2.12.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.12.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-tzc4x |
| 09087754 | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.10.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-99mmm |
| 7894ca3b | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_inductor.sh | v2.9.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-trs94 |
| 660d5e2a | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.7.1-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-jl95t |
| 8cba161f | pytorch_2.10.0_a2_aarch64_builder:20260804 | pytorch_ut_dist.sh | v2.10.0-26.1.0 | Aborted | Running>Aborted | op-plugin/ascend-pytorch-zgqfn |
| 1645c555 | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_general.sh | v2.9.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-4rpgh |
| b29694e4 | pytorch_2.11.0_a2_aarch64_builder:20260804 | pytorch_ut_inductor.sh | v2.11.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-r89h8 |
| 8f2ab07e | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_dist.sh | v2.9.0-26.1.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-fvnhx |
| af3ffd28 | pytorch_2.7.1_a2_aarch64_builder:20260804 | pytorch_ut_general.sh | v2.7.1-26.0.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-8tqdj |
| 53a251b2 | pytorch_2.9.0_a2_aarch64_builder:20260518 | pytorch_ut_general.sh | v2.9.0-26.0.0 | Completed | Running>Completed | op-plugin/ascend-pytorch-55xrv |
| 3ea9f77c | pr-mindspeed-mm:v26.1.0-cann9.0.0-torch_npu2.7.1.post6-910b-openeuler24.03-py3.11-aarch64-ci-0824 | no-ut | no-branch | Aborted | Pending>Running>Aborted | mindspeed-mm/ascend-mindspeed-mm-bnvwv |
