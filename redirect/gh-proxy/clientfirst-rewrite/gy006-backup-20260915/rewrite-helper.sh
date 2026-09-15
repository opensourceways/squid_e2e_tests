#!/bin/sh
# ── 实验：client-first 下 https 重写（gy-006 2026-09-15，测完即删）──
# 协议（squid 5+，url_rewrite_children 未配 concurrency → 无 channel-ID）：
#   输入：<URL> [extras]
#   输出：OK rewrite-url="新URL"（改写）/ OK（不改写）/ ERR（不改写）
#
# 规则边界（对齐 SOURCE-REWRITE-ANALYSIS.md 既定结论，2026-09-15 修订）：
#   1. 对象域绝不单独重写（混源禁令）：files.pythonhosted / download-r2 / codeload 一律放行
#   2. pypi 只重写索引 → tuna/simple/（现行路径，/pypi/web 已 404）。tuna /simple 页面 href
#      为相对路径（无 tuna 域）→ pip 按其认知页面 URL 解析成 pypi.org/packages/* 官方对象域
#      → 放行直连 = 官方索引×官方对象仍同源，squid 本地缓存照吃；对象域绝不重写（混源禁令：
#      同步窗口 404 / hash 漂移）
#   3. codeload 不重写：官方直连 + squid 长缓存为最优（并发 30/30、TCP_HIT 3-4ms 实测；
#      gh-proxy 白名单本就拒绝 codeload）
#   4. archive（github.com/<o>/<r>/archive/）→ helper 1:1 → codeload 确定性 URL
#      （302 不可缓存；codeload 无签名、命中长缓存。修订⑥废弃的是 server-first，
#      client-first 无 pinned 连接，该形态复活）
#   5. releases/download → gh-proxy 前缀（签名 URL 30s 轮换不可缓存，由 gh-proxy
#      服务端消化 302；唯一解）
#   6. pytorch 不重写（官方可达 + 默认 bump 已缓存；重写只作废缓存键 + 新增镜像依赖。
#      SJTU 路径手术仅保留为官方不可达集群的备选，见 SOURCE-REWRITE-ANALYSIS.md）
while read -r url _rest; do
  case "$url" in
    https://pypi.org/simple/*)
      echo "OK rewrite-url=\"https://pypi.tuna.tsinghua.edu.cn/simple/${url#https://pypi.org/simple/}\"" ;;
    # github artifact → gh-proxy 前缀（用户拍板 2026-09-15，取代 codeload 路径手术）：
    #   - gh-proxy 直接认 github.com/archive 与 releases/download 形态（实测 200），无需手术
    #   - 键=gh-proxy URL，配合 squid.conf 新增 refresh_pattern（archive/refs/tags）实现 TCP_HIT
    #   - gh-proxy 服务端吸收 302，请求不打 github.com:443（绕开限流）；内网可达无 egress 依赖
    #   - git clone / API / raw 不重写（git 本体动态协议 0 缓存收益，走 insteadOf 客户端方案）
    https://github.com/*/archive/*|https://github.com/*/releases/download/*)
      echo "OK rewrite-url=\"https://gh-proxy.test.osinfra.cn/${url}\"" ;;
    https://proxy.golang.org/*)
      echo "OK rewrite-url=\"https://goproxy.cn/${url#https://proxy.golang.org/}\"" ;;
    # apt → 华为云 host 交换（SOURCE-REWRITE-ANALYSIS 类型二：相对路径源，索引/对象全由
    # 客户端从 base 拼相对路径生成，host 交换结构上无混源；apt 校验 InRelease/SHA256SUMS 兜底）。
    # 注意：archive.ubuntu.com/ubuntu/... 与 repo.huaweicloud.com/ubuntu/... 路径结构完全
    # 同构（ports 同理）→ 纯换 host、路径原样；2026-09-15 用户拍板"架构收纯 rewrite"
    *://archive.ubuntu.com/*)
      echo "OK rewrite-url=\"${url%%://*}://repo.huaweicloud.com/${url#*archive.ubuntu.com/}\"" ;;
    *://ports.ubuntu.com/*)
      echo "OK rewrite-url=\"${url%%://*}://repo.huaweicloud.com/${url#*ports.ubuntu.com/}\"" ;;
    *)
      echo "OK" ;;
  esac
done
