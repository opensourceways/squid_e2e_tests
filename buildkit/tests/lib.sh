#!/bin/bash
# BuildKit 扩展测试公共库
BK_ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
REPO_ROOT="$(dirname "$BK_ROOT")"
source "$REPO_ROOT/configs/test.env" 2>/dev/null || true

NET="haproxy_ha_squid_net"
BUILDKITD_ADDR="tcp://172.30.0.30:1234"
BK_IMAGE="tommylike/buildkit-upstream-proxy:latest"
RPM_URL="${HTTPS_CACHE_URL:-https://repo.openeuler.org/openEuler-23.03/debuginfo/aarch64/Packages/bcc-debuginfo-0.26.0-1.oe2303.aarch64.rpm}"

# 通过 buildctl 构建测试镜像(RUN 内 HTTPS 下载),输出构建日志
bk_build() {
    docker run --rm --network "$NET" -v "$BK_ROOT:/work:ro" \
        --entrypoint buildctl "$BK_IMAGE" \
        --addr "$BUILDKITD_ADDR" \
        build --frontend dockerfile.v0 \
        --local context=/work --local dockerfile=/work \
        --opt filename=Dockerfile.test \
        --opt build-arg:RPM_URL="$RPM_URL" \
        --no-cache \
        --progress plain 2>&1
}

# Squid 三节点 access.log 里匹配 pattern 的行数合计
squid_log_count() {
    local pattern="$1" total=0 n
    for s in squid1 squid2 squid3; do
        n=$(docker exec "$s" grep -c "$pattern" /var/log/squid/access.log 2>/dev/null | head -1)
        n=${n:-0}
        total=$((total + n))
    done
    echo "$total"
}

assert_true() {
    local label="$1"; shift
    if "$@"; then echo "  ✓ $label"; else echo "  ✗ FAIL $label"; exit 1; fi
}
