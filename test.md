# 测试策略

## 测试目标

| 编号 | 测试目标 | 对应需求 |
|------|---------|---------|
| T1 | HTTP + HTTPS 代理连通性 | 功能: 支持 HTTP/HTTPS 代理 |
| T2 | Squid 单实例故障不影响代理 | DFX: 单实例故障服务不中断 |
| T3 | HA 节点故障,VIP 漂移,代理继续 | DFX: 零宕机时间 |
| T4 | HTTPS SSL Bump 缓存生效,二次下载显著加速 | 功能: HTTPS 缓存,减少多次回源 |
| T5 | 下载中断影响可控 | DFX: 异常场景不影响用户 |

## 测试环境

- Docker Compose 5 容器
- VIP 172.30.0.100,客户端固定指向 VIP
- 测试文件: openEuler 50MB RPM 包

## 测试用例

### T1: 代理连通性 (`tests/01-basic-proxy.sh`)

```
操作: 通过 VIP 发起 HTTP 和 HTTPS 请求
期望: HTTP 200, HTTPS 200
```

### T2: Squid 故障切换 (`tests/02-squid-failover.sh`)

```
操作: 停止一台 Squid → 通过 VIP 代理请求 → 恢复 Squid
期望: 故障期间所有请求 HTTP 200
机制: HAProxy 健康检查 3s 内检测到故障,自动摘除
```

### T3: VIP 漂移 (`tests/03-vip-failover.sh`)

```
操作: 停止持有 VIP 的 node1 → 检查 VIP 漂移到 node2 → 代理请求 → 恢复
期望: VIP 漂移到 node2,代理请求 HTTP 200
机制: keepalived <3 秒检测 MASTER 离线,BACKUP 接管 VIP
```

### T4: HTTPS 缓存 (`tests/04-https-cache.sh`)

```
操作: 通过 HTTPS 代理下载 50MB RPM → 再次下载
期望: 首次 ~XXs(回源),二次 <1s(缓存命中)
机制: SSL Bump 解密 HTTPS → Squid 缓存明文内容
```

### T5: 下载中断 (`tests/05-interrupt.sh`)

```
操作: 后台下载中停止一台 Squid → 检查代理连通性 → 恢复
期望: 代理连通性正常(其他 Squid 接管),下载需重试但不影响服务可用性
```

## 执行

```bash
# 一键搭建
./scripts/setup.sh

# 一键测试并生成报告
./scripts/test-all.sh

# 清理
./scripts/cleanup.sh
```

测试报告自动输出到 `test-report.txt`。
