#!/usr/bin/env python3
"""queue4-record.py — result recorder (Queue 4).

Reads results.json and vcjobs.json, generates SUMMARY.md (sampling stats)
and RESULTS.md (reinjection test results table).

Usage:
  ./queue4-record.py              # one-shot
  ./queue4-record.py --watch 60   # poll every 60s
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_json(path):
    try:
        return json.load(open(path))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def gen_summary(vj, outdir):
    """Generate SUMMARY.md from vcjobs.json."""
    all_jobs = list(vj.values())
    terminal = [st for st in all_jobs if st.get("terminal")]
    unique = {}
    for st in terminal:
        tk = st.get("type_key")
        if tk:
            unique.setdefault(tk, st)

    by_term = {}
    for st in terminal:
        t = st["terminal"]
        by_term[t] = by_term.get(t, 0) + 1

    lines = []
    lines.append("# wlcb-001 VCJob 采样汇总\n")
    lines.append(f"生成时间: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    lines.append(f"- 观测到 job 数（物理）: **{len(all_jobs)}**\n")
    lines.append(f"- 进入终态 job 数: **{len(terminal)}**\n")
    lines.append(f"- 去重后唯一 CI 类型: **{len(unique)}**\n")
    lines.append(f"- 终态分布: "
                 + ", ".join(f"{k}={v}" for k, v in sorted(by_term.items()))
                 + "\n\n")

    # Unique types table
    lines.append("## 唯一 CI 类型\n\n")
    lines.append("| type_key | desc | terminal | phases | job |\n")
    lines.append("|---|---|---|---|---|\n")
    for tk, st in sorted(unique.items(), key=lambda kv: kv[1].get("terminal_ts", 0)):
        lines.append(f"| {tk[:8]} | {st.get('type_desc','')} | {st['terminal']} | "
                     f"{'>'.join(st['phases'])} | {st['namespace']}/{st['name']} |\n")

    write(os.path.join(outdir, "SUMMARY.md"), "".join(lines))
    return len(unique)


def gen_results(results, outdir):
    """Generate RESULTS.md from results.json (queue 3 output)."""
    if not results:
        write(os.path.join(outdir, "RESULTS.md"), "_(no results yet)_\n")
        return 0

    tested = sorted(results.items(), key=lambda kv: kv[1].get("end_ts", 0))
    # 判定优先级: verdict（日志分析）> phase（Volcano 状态）。
    # 源 YAML 带 `PodFailed -> AbortJob` policy，很多 Aborted 其实是成功跑完
    # （无 HTTP 错误、UT skip/通过），只有收尾 artifact 拷贝失败。所以统计
    # 成功/失败以 verdict 为准。
    def _verdict(r):
        return r.get("verdict") or ("passed" if r.get("status") == "Completed" else "unknown")

    pass_count = sum(1 for _, r in tested if _verdict(r) == "passed")
    fail_count = sum(1 for _, r in tested if _verdict(r) == "failed")
    unk_count = sum(1 for _, r in tested if _verdict(r) == "unknown")
    total = len(tested)

    lines = []
    lines.append("# Squid 代理注入测试结果\n\n")
    lines.append(f"生成时间: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    lines.append(f"- 已测试: **{total}**\n")
    lines.append(f"- 通过(verdict=passed): **{pass_count}**\n")
    lines.append(f"- 失败(verdict=failed): **{fail_count}**\n")
    lines.append(f"- 未知: **{unk_count}**\n")
    if total:
        lines.append(f"- 成功率: **{pass_count/total*100:.1f}%**\n")
    lines.append("\n> verdict 由 queue3 解析主容器日志得出（Volcano phase 因\n"
                 "> `PodFailed→AbortJob` policy 会把成功跑完的 job 也标成 Aborted，\n"
                 "> 故不能直接当成功/失败信号）。\n\n")
    lines.append("| # | type_key | desc | namespace | phase | verdict | duration | image |\n")
    lines.append("|---|---|---|---|---|---|---|---|\n")

    for i, (tk, r) in enumerate(tested, 1):
        img = r.get("type_desc", "").split(" | ")[0] if r.get("type_desc") else (r.get("image", "").split("/")[-1] if r.get("image") else "")
        dur = f"{r.get('dur_min', '?')}m"
        status = r.get("status", "?")
        v = _verdict(r)
        # Emoji-free status markers
        if v == "passed":
            status_mark = "✅ OK"
        elif v == "failed":
            status_mark = f"❌ {status}"
        elif status == "running":
            status_mark = "🔄 running"
        else:
            status_mark = f"⚠ {status}/{v}"
        lines.append(f"| {i} | {tk[:8]} | {r.get('type_desc','')[:80]} | "
                     f"{r.get('ns','')} | {status} | {status_mark} | {dur} | {img} |\n")

    write(os.path.join(outdir, "RESULTS.md"), "".join(lines))
    return total


def main():
    ap = argparse.ArgumentParser(description="Queue 4: result recorder")
    ap.add_argument("--outdir", default=HERE)
    ap.add_argument("--watch", type=int, default=0, help="watch interval in seconds (0 = one-shot)")
    args = ap.parse_args()

    vj_path = os.path.join(args.outdir, "vcjobs.json")
    results_path = os.path.join(args.outdir, "results.json")

    while True:
        vj = load_json(vj_path)
        results = load_json(results_path)

        n_uniq = gen_summary(vj, args.outdir)
        n_tested = gen_results(results, args.outdir)

        print(f"  [queue4] summary: {n_uniq} unique types, {n_tested} tested", file=sys.stderr)

        if not args.watch:
            break
        time.sleep(args.watch)


if __name__ == "__main__":
    main()