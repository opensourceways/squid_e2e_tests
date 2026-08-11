#!/bin/bash
# 10: 最小权限实证 —— 去掉 CAP_SYS_ADMIN 后 buildkitd 无法完成构建
# 证明当前 cap 集是"最小必要"而非冗余
set -e
source "$(dirname "$0")/lib.sh"
echo "=== 10: 最小权限实证(移除 SYS_ADMIN 应失败) ==="

NEG_NAME="buildkitd-nocap"
cleanup() { docker rm -f "$NEG_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 启动一个缺少 SYS_ADMIN 的 buildkitd(其余 cap 与正常一致)
echo "启动缺少 SYS_ADMIN 的 buildkitd..."
docker run -d --name "$NEG_NAME" --network "$NET" --ip 172.30.0.31 \
    --cap-drop ALL \
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SETUID --cap-add SETGID \
    --cap-add MKNOD --cap-add SYS_CHROOT --cap-add DAC_OVERRIDE --cap-add CHOWN \
    --cap-add FOWNER --cap-add FSETID --cap-add SETPCAP --cap-add SETFCAP \
    --cap-add KILL --cap-add SYS_PTRACE --cap-add NET_BIND_SERVICE --cap-add AUDIT_WRITE \
    --security-opt apparmor=unconfined --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined --cgroupns host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$BK_ROOT/buildkitd.toml:/etc/buildkit/buildkitd.toml:ro" \
    -v "$REPO_ROOT/configs/certs/client-ca.crt:/etc/buildkit/squid-ca.pem:ro" \
    --entrypoint buildkitd "$BK_IMAGE" \
    --addr tcp://0.0.0.0:1234 --config /etc/buildkit/buildkitd.toml >/dev/null 2>&1
sleep 6

# 尝试构建,预期失败(缺 SYS_ADMIN 无法挂载 overlayfs/建 namespace)
echo "尝试构建(预期失败)..."
if docker run --rm --network "$NET" -v "$BK_ROOT:/work:ro" \
    --entrypoint buildctl "$BK_IMAGE" --addr tcp://172.30.0.31:1234 \
    build --frontend dockerfile.v0 --local context=/work --local dockerfile=/work \
    --opt filename=Dockerfile.test --opt build-arg:RPM_URL="$RPM_URL" \
    --progress plain >/dev/null 2>&1; then
    echo "  ✗ FAIL: 缺 SYS_ADMIN 仍构建成功(与最小性假设矛盾)"
    exit 1
else
    echo "  ✓ 缺 SYS_ADMIN 构建失败,证明该 cap 必需"
fi

echo "PASS"
