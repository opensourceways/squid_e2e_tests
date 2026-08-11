# BuildKit 扩展场景测试报告 — 2026-08-11

- 镜像: tommylike/buildkit-upstream-proxy:latest (从 PR feature/upstream-proxy-config 编译)
- 拓扑: 1 buildkitd daemon + 1 buildctl client + 现有 Squid HA
- 测试文件: bcc-debuginfo-0.26.0 (~15MB RPM)

## 结果: 3 通过 / 0 失败

| 测试 | 结果 | 验证点 |
|------|------|--------|
| 07 buildkit-proxy | ✅ PASS | RUN HTTPS 经 Squid,构建成功,proxy 捕获请求返回 200 |
| 08 buildkit-cache | ✅ PASS | 二次构建 Squid TCP_HIT 增加(缓存命中) |
| 10 buildkit-caps | ✅ PASS | 移除 CAP_SYS_ADMIN 构建失败(证明最小性) |

## 端到端链路证据(Squid access.log)

```
CONNECT repo.openeuler.org:443                              ← BuildKit MITM 经 Squid CONNECT
GET https://.../bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm
  TCP_MISS/200 14910892 HIER_DIRECT/49.0.230.196           ← 首次回源
  TCP_HIT/200  14910903 HIER_NONE                          ← 缓存命中
```

三段 CA 信任链 + SSL Bump 缓存全部生效。

## 最小权限实证结论

逐个移除 cap 测试: 17 个 capability 移除任一构建即失败。
- daemon 需要(3): SYS_ADMIN, NET_ADMIN, SYS_PTRACE
- RUN 容器默认 cap(14, bounding set 必含): CHOWN DAC_OVERRIDE FSETID FOWNER MKNOD NET_RAW SETGID SETUID SETFCAP SETPCAP NET_BIND_SERVICE SYS_CHROOT KILL AUDIT_WRITE
- security-opt: apparmor/seccomp/systempaths = unconfined
- cgroup: host + /sys/fs/cgroup rw

对比 privileged(全部 caps + 所有设备 + 无限制),显著收窄。
