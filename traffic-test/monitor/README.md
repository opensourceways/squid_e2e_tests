# Squid Traffic Monitoring Tools

监控和分析生产环境 Squid 缓存代理的流量和缓存效率工具集。

## 工具列表

### 1. analyze-domain-traffic.py

分析 squid access.log，生成按域名统计的缓存命中率报告。

**功能**：
- 自动发现集群中的 squid pods
- 从所有 pod 拉取 access.log 并合并分析
- 按域名统计 MISS/HIT 流量和请求数
- 计算每个域名的缓存命中率
- 生成总体统计摘要

**使用方法**：

```bash
# 分析 gy-001 集群的所有 squid pods
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml --namespace squid

# 分析 gy-002 集群，指定特定 pods
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-002.yaml -n squid --pods squid-cache-0,squid-cache-1

# 保存报告到文件
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid -o gy001-traffic-report.txt

# 只显示流量 >5MB 的域名
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid --min-mb 5.0

# 限制输出前 20 行
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid --max-rows 20
```

**输出示例**：

```
Analyzing 2 pod(s): squid-cache-0, squid-cache-1
Fetching access.log from squid-cache-0...
Fetching access.log from squid-cache-1...

Domain                                                       MISS_Cnt   MISS_MB    HIT_Cnt    HIT_MB     Total_MB   Hit%    
==================================================================================================================================
pytorch-package.obs.cn-north-4.myhuaweicloud.com             10         1515.0     8          1298.7     2813.6     46.2    
cn-north-4-octopus-gitcode-runner.obs.cn-north-4.myhuaweicloud.com 2   89.5       42         1881.5     1971.0     95.5    
ports.ubuntu.com                                             121        273.3      5          1.6        274.9      0.6     
mirrors.aliyun.com                                           77         137.1      0          0.0        137.1      0.0     
lfs-cdn.gitcode.com                                          494        31.9       0          0.0        31.9       0.0     

--- Summary ---
Total MISS: 2047.8 MB (704 requests)
Total HIT: 3181.8 MB (55 requests)
Total Traffic: 5229.6 MB
Overall Hit Ratio: 60.8%
```

**输出字段说明**：
- `MISS_Cnt`: 缓存未命中的请求数（需要从源服务器拉取）
- `MISS_MB`: 缓存未命中的流量（MB）
- `HIT_Cnt`: 缓存命中的请求数（直接从缓存返回）
- `HIT_MB`: 缓存命中的流量（MB）
- `Total_MB`: 总流量（MISS + HIT）
- `Hit%`: 缓存命中率（HIT_MB / Total_MB * 100）

---

### 2. ../monitor-traffic.sh

实时监控 Squid 流量和缓存命中率（从中心 Prometheus 采样）。

**功能**：
- 从中心 Prometheus（113.44.182.82:9090）实时查询 squid metrics
- 每 10 秒采样一次，输出 client 流出速率、origin 流入速率、缓存命中率
- 支持输出到文件（TSV 格式）

**使用方法**：

```bash
# 监控 600 秒（默认），输出到终端
../monitor-traffic.sh

# 监控 300 秒，保存到文件
../monitor-traffic.sh 300 traffic.tsv

# 使用自定义 Prometheus 地址
PROM=http://my-prom:9090 ../monitor-traffic.sh 120
```

**输出示例**：

```
# squid traffic monitor: 600s, step 10s, prom=http://113.44.182.82:9090
# ts client_kb/s origin_kb/s hitrate(1-origin/client) per-instance(client)
1787554276	1250.5	320.8	0.743	squid-cache-0:10.0.7.106:9301 625.2 squid-cache-1:10.0.7.107:9301 625.3
1787554286	980.3	150.2	0.847	squid-cache-0:10.0.7.106:9301 490.1 squid-cache-1:10.0.7.107:9301 490.2
...
# done
```

**字段说明**：
- `ts`: Unix 时间戳
- `client_kb/s`: 客户端流出速率（KB/s，包含 MISS+HIT）
- `origin_kb/s`: 源服务器流入速率（KB/s，只包含 MISS）
- `hitrate`: 缓存命中率（1 - origin/client）
- `per-instance`: 每个 squid pod 的流出速率

---

## 典型使用场景

### 场景 1：检查某个集群的缓存效率

```bash
# 快速查看 gy-001 的缓存情况
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid --min-mb 1.0

# 关注点：
# - Hit% 高的域名（如 >80%）说明缓存工作良好
# - Hit% 低或 0% 的域名需要调查原因（如 LFS 带查询参数）
```

### 场景 2：对比两个集群的流量模式

```bash
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid -o gy001.txt
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-002.yaml -n squid -o gy002.txt
diff gy001.txt gy002.txt
```

### 场景 3：监控流量测试期间的缓存表现

```bash
# 终端 1：启动流量测试
kubectl --kubeconfig ~/.kube/gy-001.yaml apply -f traffic-test.yaml

# 终端 2：实时监控
../monitor-traffic.sh 600 test-traffic.tsv

# 测试结束后分析
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid -o post-test.txt
```

### 场景 4：诊断缓存未生效的域名

```bash
# 1. 找出 Hit% = 0 的域名
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-002.yaml -n squid | grep "0.0$"

# 输出示例：
# lfs-cdn.gitcode.com   494   31.9   0   0.0   31.9   0.0

# 2. 检查该域名的实际 access.log 条目
kubectl --kubeconfig ~/.kube/gy-002.yaml exec -n squid squid-cache-0 -c squid -- \
  grep 'lfs-cdn.gitcode.com' /var/log/squid/access.log | head -5

# 3. 分析 URL 模式（如是否带查询参数）
# 4. 调整 squid.conf 的 refresh_pattern 或 store_id 规则
```

---

## 已知问题与解决方案

### 问题 1：LFS (lfs-cdn.gitcode.com) 缓存命中率 0%

**原因**：LFS URL 带动态查询参数（`?token=xxx` 或 `?expires=xxx`），每次请求的 URL 不同，导致 squid 无法命中缓存。

**解决方案**：
1. 配置 squid `store_id` helper，去掉查询参数进行缓存 key 计算
2. 或使用 `refresh_pattern` 强制缓存（需忽略 `Cache-Control: no-store`）

参考配置：
```squid
# squid.conf
acl lfs_urls url_regex -i ^https://lfs-cdn\.gitcode\.com/lfs-objects/
refresh_pattern -i lfs-cdn\.gitcode\.com/lfs-objects/ 10080 100% 525600 \
    ignore-reload override-expire ignore-no-store
```

### 问题 2：ports.ubuntu.com 缓存命中率极低（<5%）

**原因**：
- APT 包索引文件（Packages.gz）频繁更新，带 `Cache-Control: max-age=0`
- Squid 默认尊重源服务器的缓存控制头

**解决方案**：
```squid
refresh_pattern -i ports\.ubuntu\.com/ubuntu-ports/.*/Packages 0 20% 4320
refresh_pattern -i \.deb$ 10080 100% 525600 ignore-reload override-expire ignore-no-store
```

### 问题 3：analyze-domain-traffic.py 报错 "No squid pods found"

**原因**：
- Pod label 选择器不匹配
- 或 namespace 不正确

**解决方案**：
```bash
# 手动指定 pod 名称
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid \
  --pods squid-cache-0,squid-cache-1

# 或检查实际的 pod 名称
kubectl --kubeconfig ~/.kube/gy-001.yaml get pods -n squid
```

---

## 开发与扩展

### 添加新的分析维度

编辑 `analyze-domain-traffic.py`，在 `parse_access_log()` 中添加额外的统计维度：

```python
# 示例：按响应大小范围分类
size_buckets = defaultdict(int)  # <1MB, 1-10MB, 10-100MB, >100MB

if size < 1048576:
    size_buckets['<1MB'] += 1
elif size < 10485760:
    size_buckets['1-10MB'] += 1
...
```

### 集成到 CI/CD

```yaml
# .gitlab-ci.yml 或 GitHub Actions
analyze-traffic:
  script:
    - python3 monitor/analyze-domain-traffic.py --kubeconfig $KUBECONFIG -n squid -o report.txt
    - cat report.txt
    - |
      HIT_RATIO=$(grep 'Overall Hit Ratio' report.txt | awk '{print $4}' | tr -d '%')
      if (( $(echo "$HIT_RATIO < 50" | bc -l) )); then
        echo "WARNING: Cache hit ratio too low: $HIT_RATIO%"
        exit 1
      fi
```

---

## 参考资料

- [Squid Access Log Format](http://www.squid-cache.org/Doc/config/logformat/)
- [Squid Refresh Patterns](http://www.squid-cache.org/Doc/config/refresh_pattern/)
- [Prometheus Query API](https://prometheus.io/docs/prometheus/latest/querying/api/)

---

## 常见问题 FAQ

**Q: 为什么总流量包含内部健康检查（squid-cache:3129）？**

A: 这些是 squid 容器之间的内部健康检查流量，可以在脚本中过滤掉。在 `parse_access_log()` 中添加：
```python
if 'squid-cache' in domain or domain.startswith('10.'):
    continue  # 跳过内部流量
```

**Q: 如何定期生成报告并发送到 Slack/Email？**

A: 使用 cron job + webhook：
```bash
#!/bin/bash
# /etc/cron.daily/squid-traffic-report.sh
cd /path/to/monitor
./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid -o /tmp/report.txt
curl -X POST -H 'Content-Type: application/json' \
  -d "{\"text\": \"$(cat /tmp/report.txt)\"}" \
  https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

**Q: 支持分析历史日志吗（如 access.log.1.gz）？**

A: 当前版本只分析当前 access.log。要分析历史日志，需要扩展脚本：
```bash
kubectl exec squid-cache-0 -c squid -- \
  sh -c 'zcat /var/log/squid/access.log.*.gz; cat /var/log/squid/access.log' \
  > full-history.log
# 然后本地分析
```

---

## Changelog

- **2026-08-25**: 初始版本，支持 gy-001/gy-002 集群的域名级流量分析
- **TBD**: 添加时间序列分析（按小时/天统计）
- **TBD**: 支持导出 JSON/CSV 格式
