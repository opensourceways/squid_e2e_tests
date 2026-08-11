# 测试报告 — 2026-08-11

- 环境: Docker Compose 5 容器（3 Squid + 2 HAProxy/keepalived）
- HTTPS 缓存测试文件: bcc-debuginfo-0.26.0 (~15MB RPM)
- 所有测试为真断言(HTTP code 非 200 即 FAIL)

## 结果汇总

| 测试 | 结果 | 耗时 |
|------|------|------|
| 01 代理连通性 (HTTP+HTTPS) | ✅ PASS | ~1s |
| 02 单 Squid 故障切换 | ✅ PASS | 33s |
| 03 VIP 双向漂移 | ✅ PASS | 76s |
| 04 HTTPS SSL Bump 缓存 | ✅ PASS | 3s |
| 05 下载中断影响 | ✅ PASS | 32s |
| 06 两台 Squid 同时故障 | ✅ PASS | 33s |

**结果: 6 通过 / 0 失败 / 6 总计 (exit code 0)**

## 关键指标: HTTPS 缓存加速 (SSL Bump)

| 阶段 | 耗时 | 速度 |
|------|------|------|
| 首次 (MISS,回源) | 2.66s | 5.6 MB/s |
| 二次 (HIT,缓存) | 0.15s | 100 MB/s |

15MB RPM 二次下载耗时降至首次的 ~1/17。

## 完整日志

```
============================================
  Squid HA 验证测试 | Tue Aug 11 09:08:21 CST 2026
============================================
=== 01: 代理连通性 ===
  ✓ HTTP 代理: HTTP 200
  ✓ HTTPS 代理: HTTP 200
PASS
  [01-basic-proxy.sh] PASS (1s)
=== 02: Squid 故障切换 ===
停止 squid2 ...
squid2
  ✓ 故障后代理: HTTP 200
恢复 squid2 ...
  ✓ 恢复后代理: HTTP 200
PASS
  [02-squid-failover.sh] PASS (33s)
=== 03: VIP 漂移 ===
A: 停止 VIP 持有者 haproxy-node1 ...
haproxy-node1
  ✓ A VIP 漂移到 haproxy-node2
  ✓ A 代理: HTTP 200
B: 停止 VIP 持有者 haproxy-node1 ...
haproxy-node1
  ✓ B VIP 漂移到 haproxy-node2
  ✓ B 代理: HTTP 200
PASS
  [03-vip-failover.sh] PASS (76s)
=== 04: HTTPS SSL Bump 缓存 ===
URL: https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm
  ✓ 首次下载(MISS): HTTP 200
  首次(MISS): 2.658946s  14910497 bytes  5607684 B/s
  ✓ 二次下载(HIT): HTTP 200
  二次(HIT):  0.149128s  14910497 bytes  99986568 B/s
  耗时对比: 首次 2.658946s → 二次 0.149128s
PASS
  [04-https-cache.sh] PASS (3s)
=== 05: 下载中断影响 ===
启动后台下载 ...
1f65df3f7d20c59219ad427bd26a01d6b198bb56a7a7585862d86e4f0f5afbcd
中断 squid3 ...
squid3
  ✓ 中断期间代理: HTTP 200
恢复 squid3 ...
  ✓ 恢复后代理: HTTP 200
PASS
  [05-interrupt.sh] PASS (32s)
=== 06: 两台 Squid 同时故障 ===
停止 squid2 + squid3 (仅剩 squid1) ...
squid2
squid3
  ✓ 仅剩1台 请求1: HTTP 200
  ✓ 仅剩1台 请求2: HTTP 200
  ✓ 仅剩1台 请求3: HTTP 200
恢复 squid2 + squid3 ...
  ✓ 恢复后代理: HTTP 200
PASS
  [06-double-squid-fail.sh] PASS (33s)

============================================
  结果: 6 通过 / 0 失败 / 6 总计
============================================
```
