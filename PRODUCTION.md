# 生产部署指南

本仓库是**测试验证环境**,部分配置为测试专用,直接搬到生产会有坑。
本文列出从测试到生产必须调整的关键配置。

> 阅读顺序: 先读 `solution.md`(架构决策) → 本文(生产参数) → `TROUBLESHOOTING.md`(踩坑)。

## 一、测试 vs 生产 配置差异总表

| 配置项 | 测试环境(本仓库) | 生产环境(必改) | 原因 |
|--------|----------------|--------------|------|
| **SSL Bump 范围** | `ssl_bump bump all` | 域名白名单 peek/splice/bump | 无差别解密违反隐私/合规,部分国家违法 |
| **VRRP 通信** | 单播 `unicast_peer` | 组播(物理网络支持时) | Docker bridge 无组播,物理网可用组播 |
| **VIP 网段** | 172.30.0.100/24(Docker 子网) | 真实业务网段的空闲 IP | — |
| **DNS** | 硬编码 8.8.8.8/1.1.1.1 | 内网 DNS 或就近解析 | 测试图方便,生产应用内部 DNS |
| **Squid CA** | setup.sh 自签,CN=Squid-HA-Test-CA | 企业内部 CA 签发,导入所有客户端信任库 | 自签 CA 客户端不信任 |
| **cache_dir** | `aufs 10000`(10GB,单容器) | 每物理盘一个 cache_dir,JBOD | 磁盘 I/O 是 Squid 首要瓶颈 |
| **HAProxy 后端** | 3 个固定 IP | 按实际 Squid 数量,配服务发现 | — |
| **stats 页面** | `0.0.0.0:8404` 无认证 | 绑内网 + 加认证或关闭 | 暴露拓扑信息 |
| **镜像 tag** | `latest`/浮动 tag | 钉死具体版本 | 可复现 |
| **容器** | Docker Compose 单机 | 独立物理机/VM/K8s | 生产隔离与规模 |

## 二、关键配置模板(生产版)

### 2.1 keepalived(生产:组播 VRRP + 更快检测)

```
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"   # 建议用完整路径
    interval 2
    weight -20                             # HAProxy 挂掉时降优先级触发漂移
    fall 2
    rise 2
}

vrrp_instance VI_SQUID {
    state MASTER                           # BACKUP 节点设 BACKUP
    interface eth0                         # 改成真实网卡名
    virtual_router_id 51                   # 同一广播域内唯一
    priority 100                           # BACKUP 设 90
    advert_int 1                           # 1 秒心跳,3 秒判离线
    authentication {                       # 生产必加认证
        auth_type PASS
        auth_pass <改成强密码>
    }
    virtual_ipaddress {
        <业务网段VIP>/24 dev eth0
    }
    track_script { chk_haproxy }
    # 物理网支持组播时删掉 unicast_* 即可;不支持则保留单播:
    # unicast_src_ip <本机IP>
    # unicast_peer { <对端IP> }
}
```

### 2.2 HAProxy(生产:加认证 + 合理超时)

```
global
    log /dev/log local0
    maxconn 20000                          # 按并发调整

defaults
    mode tcp
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    retries 2

listen squid_pool
    bind <VIP>:3128
    balance source                         # 客户端IP亲和,减少缓存重复(见 solution.md)
    hash-type consistent                   # 一致性哈希,节点增减时缓存扰动最小
    option tcp-check
    server s1 <squid1-ip>:3128 check inter 3s rise 2 fall 3
    server s2 <squid2-ip>:3128 check inter 3s rise 2 fall 3
    server s3 <squid3-ip>:3128 check inter 3s rise 2 fall 3
    # 按需扩容更多 server 行

listen stats
    bind 127.0.0.1:8404                    # 只绑内网/本机
    mode http
    stats enable
    stats uri /stats
    stats auth admin:<强密码>              # 生产必加认证
```

### 2.3 Squid(生产:域名白名单 SSL Bump + JBOD 磁盘)

```
http_port 3128 ssl-bump \
  cert=/etc/squid/certs/<企业CA>.pem \
  generate-host-certificates=on \
  dynamic_cert_mem_cache_size=20MB

sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/spool/squid/ssl_db -M 20MB

# 生产: 只解密需要缓存的域名,其余 splice(直通,不解密)
acl cacheable_sites ssl::server_name .repo.openeuler.org .example.com
ssl_bump peek step1
ssl_bump bump cacheable_sites
ssl_bump splice all

dns_nameservers <内网DNS1> <内网DNS2>

acl localnet src <业务网段>/16            # 收紧来源,不要 all
http_access allow localnet
http_access deny all

# JBOD: 每物理盘一个 cache_dir,不做 RAID(见 solution.md)
cache_dir aufs /data/disk1/squid 100000 16 256
cache_dir aufs /data/disk2/squid 100000 16 256
cache_mem 4096 MB                          # 按内存调整
maximum_object_size 4 GB

refresh_pattern -i \.(rpm|deb|tar\.gz|iso)$ 10080 90% 43200
refresh_pattern . 0 20% 4320
```

## 三、容量规划参考

| 资源 | 经验值 |
|------|--------|
| CPU | 1 核(2GHz) ≈ 32 Mbps 流量 |
| 内存 | 每 GB 磁盘缓存配 10-20 MB RAM(用于索引) |
| 磁盘 | 机械盘 100-400 随机 IOPS;每 8 Mbps 可缓存流量配 1 个盘 |
| SMP worker | 每非超线程物理核 1 个 worker,64 核最多约 28-30 |
| 缓存命中率 | 静态内容优化后 85-92%,动态 30-50% |

## 四、生产部署检查清单

上线前逐项确认:

- [ ] SSL Bump 改为**域名白名单**,不用 `bump all`
- [ ] 企业内部 CA 签发证书,并**导入所有客户端信任库**(否则 HTTPS 报错)
- [ ] SSL Bump 的**法律/合规审查**通过(告知用户、排除敏感域名)
- [ ] keepalived 加 `authentication`,VIP 用业务网段空闲 IP
- [ ] HAProxy stats 页面加认证或绑内网
- [ ] `http_access` 收紧来源网段,不用 `allow all`
- [ ] cache_dir 按 JBOD 布局,每盘一个,不做 RAID
- [ ] 镜像/软件版本**钉死**,不用 latest
- [ ] 监控接入(Squid SNMP/cachemgr、HAProxy stats、keepalived 状态)
- [ ] 日志轮转配置(access.log 高流量下增长极快)
- [ ] 在预发环境跑本仓库的 6 项测试验证 HA 生效

## 五、本仓库可直接复用的部分

以下配置**测试与生产一致**,可直接借鉴:

- HAProxy `mode tcp` + `balance source` 的负载均衡思路
- keepalived MASTER/BACKUP + `track_script chk_haproxy` 的漂移触发逻辑
- Squid `security_file_certgen` + `generate-host-certificates` 的动态证书机制
- 三层职责划分(keepalived 管 IP / HAProxy 管分发 / Squid 管缓存,见 solution.md)
- 6 项 HA 测试用例(改 `configs/test.env` 的 URL 即可对生产验证)
