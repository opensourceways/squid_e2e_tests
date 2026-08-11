# 测试策略

## 测试目标

| 编号 | 测试目标 | 对应需求 |
|------|---------|---------|
| T1 | HTTP + HTTPS 代理连通性 | 功能: 支持 HTTP/HTTPS 代理 |
| T2 | Squid 单实例故障不影响代理 | DFX: 单实例故障服务不中断 |
| T3 | HAProxy 节点故障,VIP 双向漂移,代理继续 | DFX: 节点级故障零中断 |
| T4 | HTTPS SSL Bump 缓存生效(首次/二次耗时对比) | 功能: HTTPS 缓存,减少多次回源 |
| T5 | 下载中断影响可控 | DFX: 异常场景不影响用户 |
| T6 | 两台 Squid 同时故障,仅剩 1/3 继续服务 | DFX: 多实例故障容错 |

## 测试环境

- Docker Compose 5 容器（3 Squid + 2 HAProxy/keepalived 节点）
- VIP `172.30.0.100:3128`,客户端固定指向 VIP
- 缓存测试文件由 `configs/test.env` 的 `HTTPS_CACHE_URL` 指定

## 断言原则

所有测试均为**真断言**:每步校验 HTTP code 或 VIP 归属,不符合期望立即 `exit 1`。
公共断言库 `tests/lib.sh` 提供 `proxy_http_code` / `proxy_https_code` / `assert_code` / `assert_true`。
`test-all.sh` 整体退出码反映成败(0=全通过, 1=有失败),并输出 `result.json`。

## 测试用例

### T1: 代理连通性 (`tests/01-basic-proxy.sh`)
```
操作: 通过 VIP 发起 HTTP 与 HTTPS 请求
断言: HTTP 200 且 HTTPS 200
```

### T2: Squid 故障切换 (`tests/02-squid-failover.sh`)
```
操作: 停止一台 Squid → 代理请求 → 恢复
断言: 故障期间代理返回 200,恢复后返回 200
机制: HAProxy 健康检查(inter 3s)检测故障并自动摘除
```

### T3: VIP 双向漂移 (`tests/03-vip-failover.sh`)
```
操作: 停止持有 VIP 的节点 → 验证 VIP 漂移到另一节点 → 代理请求 → 恢复
      重复一次(验证反向漂移)
断言: VIP 成功漂移 且 代理返回 200
机制: keepalived VRRP 单播,MASTER 离线后 BACKUP 接管 VIP
```

### T4: HTTPS 缓存 (`tests/04-https-cache.sh`)
```
操作: 通过 HTTPS 代理下载文件 → 再次下载
断言: 两次均 HTTP 200
展示: 首次(MISS,回源)与二次(HIT,缓存)的耗时/速度对比
机制: SSL Bump 解密 HTTPS → Squid 缓存明文内容
```

### T5: 下载中断 (`tests/05-interrupt.sh`)
```
操作: 后台下载进行中停止一台 Squid → 检查代理连通性 → 恢复
断言: 中断期间代理返回 200,恢复后返回 200
```

### T6: 两台 Squid 同时故障 (`tests/06-double-squid-fail.sh`)
```
操作: 同时停止两台 Squid(仅剩 1/3) → 连续 3 次代理请求 → 恢复
断言: 所有请求返回 200(HAProxy 仅向存活 Squid 分发)
```

## 容器状态管理

- 每个测试**成功路径**会主动恢复它停止的容器(`docker compose restart`)。
- 若测试**中途失败**,`test-all.sh` 会在该测试后调用 `restore_env` 重启全部容器,隔离后续测试。
- 每个测试**开始前**再次检查代理可达,不可达则恢复环境。
- 全部结束后可用 `./scripts/cleanup.sh`(`docker compose down -v`)彻底清理。

## 自定义测试 URL

编辑 `configs/test.env`(无需改脚本):
```bash
HTTP_URL="http://repo.openeuler.org/"
HTTPS_URL="https://curl.se/"
HTTPS_CACHE_URL="https://repo.openeuler.org/.../bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm"
```

## 执行

```bash
./scripts/setup.sh      # 搭建
./scripts/test-all.sh   # 测试 + test-report.txt + result.json
./scripts/cleanup.sh    # 清理
```
