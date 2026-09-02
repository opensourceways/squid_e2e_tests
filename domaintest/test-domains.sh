#!/usr/bin/env bash
# 域名可达性对比测试: wlcb(.49) vs gy-001(.37)
# 方法: 在各自集群的 squid pod 内, 经本地 squid 代理(127.0.0.1:3128)逐个测试
#       ascend_ci_domains.json 白名单里的域名 (curl -sk 忽略证书, 只看连通性)
# 输出: domaintest/results-wlcb.tsv / results-gy001.tsv  + 终端对比表
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="$DIR/ascend_ci_domains.json"
OUT_W="$DIR/results-wlcb.tsv"
OUT_G="$DIR/results-gy001.tsv"

# 生成 pod 内执行的脚本: for d in <字面量域名列表>; do curl ...; done
gen_script() {
  local doms
  doms=$(python3 - "$LIST" <<'PY'
import json, sys
doms = [x.replace("https://", "").strip() for x in json.load(open(sys.argv[1]))]
# 跳过通配符条目(*.), 其余按单引号包好
print(" ".join("'%s'" % d for d in doms if not d.startswith("*")))
PY
)
  cat <<EOF
label="\$1"
for d in $doms; do
  r=\$(curl -sk -o /dev/null --proxy http://127.0.0.1:3128 --max-time 6 -w "%{http_code}|%{time_total}" "https://\$d/" 2>/dev/null)
  ec=\$?
  echo "\$label|\$d|\$ec|\$r"
done
EOF
}

# 跑一个集群: 参数 = kubeconfig, pod, ns, 标签, 输出文件
run_cluster() {
  local kc="$1" pod="$2" ns="$3" label="$4" out="$5"
  echo "[$label] 测试中 ($(python3 -c "import json,sys;print(len([x for x in json.load(open('$LIST')) if not x.startswith('*')]))") 个域名, 经 $pod ..."
  gen_script | kubectl --kubeconfig "$kc" exec -i -n "$ns" "$pod" -- sh -s -- "$label" > "$out" 2>/dev/null
  echo "[$label] 完成 -> $(wc -l < "$out") 条"
}

# 归类: 0=可达(code) / 28=超时 / 6=DNS / 7=连接拒绝 / 其他=ERR
classify() {
  local ec="$1" code="$2"
  if [ "$ec" = "0" ]; then echo "$code"; 
  elif [ "$ec" = "28" ]; then echo "TIMEOUT";
  elif [ "$ec" = "6" ]; then echo "DNSFAIL";
  elif [ "$ec" = "7" ]; then echo "CONNFAIL";
  else echo "ERR$ec"; fi
}

run_cluster ~/.kube/wlcb-001.yaml squid-cache-0 squid wlcb "$OUT_W"
run_cluster ~/.kube/gy-001.yaml  squid-cache-0 squid gy001 "$OUT_G"

# 对比表
python3 - "$OUT_W" "$OUT_G" <<'PY'
import sys
def load(p):
    m = {}
    for line in open(p):
        parts = line.rstrip("\n").split("|")
        if len(parts) < 4: continue
        lab, dom, ec, rest = parts[0], parts[1], parts[2], parts[3]
        code, tm = (rest.split("|") + ["", ""])[:2]
        m[dom] = (lab, ec, code, tm)
    return m

w = load(sys.argv[1]); g = load(sys.argv[2])
def cls(m, d):
    if d not in m: return "N/A"
    lab, ec, code, tm = m[d]
    if ec == "0": return code
    return {"28":"TIMEOUT","6":"DNSFAIL","7":"CONNFAIL"}.get(ec, "ERR"+ec)

doms = sorted(set(w) | set(g))
print(f"{'DOMAIN':<55} {'wlcb(.49)':<10} {'gy001(.37)':<10}")
print("-"*78)
for d in doms:
    print(f"{d:<55} {cls(w,d):<10} {cls(g,d):<10}")
# 汇总
def summary(m):
    ok = sum(1 for d in m if m[d][1] == "0")
    to = sum(1 for d in m if m[d][1] == "28")
    dns = sum(1 for d in m if m[d][1] == "6")
    cn = sum(1 for d in m if m[d][1] == "7")
    return ok, to, dns, cn
wo, wt, wd, wc = summary(w)
go, gt, gd, gc = summary(g)
print("-"*78)
print(f"wlcb : 可达{wo}  超时{wt}  DNS失败{wd}  连接拒绝{wc}")
print(f"gy001: 可达{go}  超时{gt}  DNS失败{gd}  连接拒绝{gc}")
PY
