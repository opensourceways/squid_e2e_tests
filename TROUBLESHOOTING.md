# 故障排查 / 已知问题

搭建过程中踩过的坑与解法，供复现者参考。

## 1. keepalived 容器重启后起不来

**现象**：`docker stop && docker start haproxy-nodeX` 后，keepalived 进程消失，VIP 无法漂移。日志：`daemon is already running`。

**根因**：容器停止时 `/run/keepalived.pid` / `/run/vrrp.pid` 残留，重启后 keepalived 误判已有实例在跑。

**解法**：
- 已在 `docker/node/start.sh` 启动前 `rm -f /run/keepalived.pid /run/vrrp.pid`。
- 测试中恢复节点用 `docker compose restart`（会重跑 start.sh）而非 `docker start`。

## 2. keepalived VRRP 在 Docker bridge 不通

**现象**：两个节点都进入 MASTER，或 VIP 不漂移。

**根因**：Docker bridge 网络默认不支持组播，VRRP 默认走组播。

**解法**：`configs/keepalived/*.conf` 使用**单播**：`unicast_src_ip` + `unicast_peer`。

## 3. HAProxy 容器启动即退出

**现象**：haproxy 节点 `Exited (0)`，容器不保持运行。

**根因**：HAProxy 配置含 `daemon` 关键字或默认 fork 到后台，主进程退出→容器结束。

**解法**：`configs/haproxy/haproxy.cfg` **不写 `daemon`**，`start.sh` 用 `haproxy -d` 前台运行。

## 4. Squid 解析域名得到内网 IP（503）

**现象**：Squid 回源全部 503，access.log 目标 IP 是 `198.18.x.x` 等内网段。

**根因**：Docker 内置 DNS(127.0.0.11)在某些环境返回劫持地址。

**解法**：
- `configs/squid/squid.conf` 设 `dns_nameservers 8.8.8.8 1.1.1.1`。
- `docker-compose.yml` 给 squid 服务加 `dns: [8.8.8.8, 1.1.1.1]`。

## 5. ubuntu/squid 镜像 entrypoint 覆盖自定义启动

**现象**：自定义 `CMD` 不生效，SSL DB 未初始化。

**根因**：`ubuntu/squid` 自带 `/usr/local/bin/entrypoint.sh`，会把 CMD 当 squid 参数，且先跑 `squid -Nz`。

**解法**：`docker/squid/Dockerfile` 用 `ENTRYPOINT ["/start.sh"]` + `CMD []` 显式覆盖。

## 6. HTTPS 缓存需要 OpenSSL 版 Squid

**现象**：`ssl_bump` 报错，找不到 `security_file_certgen`。

**根因**：`ubuntu/squid` 默认是 **GnuTLS** 编译版，不含 SSL Bump 证书生成助手。

**解法**：`docker/squid/Dockerfile` 安装 `squid-openssl` 包（OpenSSL 版，含 `--enable-ssl-crtd`）。

## 7. Squid swap 目录/SSL DB 权限

**现象**：`security_file_certgen` 报 `Cannot create ssl_db`；或 swap 目录 `No such file or directory`。

**根因**：Squid 以 `proxy` 用户运行，但目录属 root；匿名卷可能残留旧状态。

**解法**：`docker/squid/start.sh` 中以 `proxy` 用户初始化 ssl_db，并 `mkdir -p` 强制创建 swap 目录后 `chown proxy`。清理用 `docker compose down -v` 删除匿名卷。

## 8. HTTPS 缓存测试超时

**现象**：04 测试 FAIL，`--max-time` 超时。

**根因**：测试文件太大 + 源站带宽慢（如 openEuler CDN 某些时段 ~90KB/s，50MB 需 >8 分钟）。

**解法**：`configs/test.env` 换用较小文件（当前用 ~15MB 的 bcc-debuginfo RPM），或调大脚本 `--max-time`。

## 9. HTTPS 客户端证书验证失败

**现象**：`curl` 报证书错误。

**根因**：SSL Bump 用自签 CA 动态签发证书，客户端需信任该 CA。

**解法**：测试脚本用 `--cacert configs/certs/client-ca.crt`（setup.sh 自动生成）。真实客户端需把该 CA 导入信任库。
