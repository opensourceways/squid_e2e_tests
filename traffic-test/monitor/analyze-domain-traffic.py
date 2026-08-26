#!/usr/bin/env python3
"""
analyze-domain-traffic.py - Analyze squid access.log and compute per-domain cache hit ratios

Usage:
    # Analyze all pods in a cluster
    ./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml --namespace squid
    
    # Analyze specific pods
    ./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-002.yaml --namespace squid --pods squid-cache-0,squid-cache-1
    
    # Save to file
    ./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid -o report.txt
    
    # Filter by minimum traffic (MB)
    ./analyze-domain-traffic.py --kubeconfig ~/.kube/gy-001.yaml -n squid --min-mb 5.0

Output format:
    Domain                                 MISS_Cnt   MISS_MB    HIT_Cnt    HIT_MB     Total_MB   Hit%
    ===================================================================================================
    pytorch-package.obs.cn-north-4...      10         1515.0     8          1298.7     2813.6     46.2%
"""

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from typing import Dict, List, Tuple


def get_pods(kubeconfig: str, namespace: str, pods: str = None) -> List[str]:
    """Get list of squid pods in the namespace"""
    if pods:
        return pods.split(',')
    
    cmd = [
        'kubectl', '--kubeconfig', kubeconfig,
        'get', 'pods', '-n', namespace,
        '-l', 'app=squid',
        '-o', 'jsonpath={.items[*].metadata.name}'
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    pod_list = result.stdout.strip().split()
    
    if not pod_list:
        # Fallback: try StatefulSet pattern
        cmd = [
            'kubectl', '--kubeconfig', kubeconfig,
            'get', 'pods', '-n', namespace,
            '-o', 'jsonpath={.items[*].metadata.name}'
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        all_pods = result.stdout.strip().split()
        pod_list = [p for p in all_pods if 'squid-cache' in p or 'squid' in p]
    
    return pod_list


def fetch_access_log(kubeconfig: str, namespace: str, pod: str, container: str = 'squid') -> str:
    """Fetch access.log from a squid pod"""
    cmd = [
        'kubectl', '--kubeconfig', kubeconfig,
        'exec', '-n', namespace, pod,
        '-c', container, '--',
        'cat', '/var/log/squid/access.log'
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return result.stdout


def parse_access_log(log_content: str) -> Tuple[Dict[str, int], Dict[str, int], Dict[str, int], Dict[str, int], Dict[str, int], Dict[str, int]]:
    """
    Parse squid access.log and extract per-domain statistics
    
    Returns:
        (miss_bytes, miss_count, hit_bytes, hit_count, revalidated_bytes, revalidated_count)
    """
    miss_bytes = defaultdict(int)
    miss_count = defaultdict(int)
    hit_bytes = defaultdict(int)
    hit_count = defaultdict(int)
    revalidated_bytes = defaultdict(int)
    revalidated_count = defaultdict(int)
    
    for line in log_content.splitlines():
        parts = line.split()
        if len(parts) < 7:
            continue
        
        status = parts[3]
        try:
            size = int(parts[4])
        except ValueError:
            continue
        url = parts[6]
        
        # Extract domain from URL
        match = re.match(r'https?://([^/:]+)', url)
        if match:
            domain = match.group(1)
        else:
            # Handle CONNECT or malformed URLs
            domain = url.split(':')[0] if ':' in url else url.split('/')[0]
        
        # Classify by status code
        # TCP_REFRESH_UNMODIFIED / TCP_REFRESH_HIT: revalidation hit (304 Not Modified)
        # - Origin returned 304, squid served cached content
        # - Only a few hundred bytes validation traffic, not full object transfer
        # TCP_HIT / TCP_MEM_HIT: direct cache hit (no origin contact)
        # TCP_MISS: cache miss (full object transfer from origin)
        # TCP_REFRESH_MISS / TCP_REFRESH_MODIFIED: revalidation miss (object changed, full transfer)
        
        if 'TCP_REFRESH_UNMODIFIED' in status or 'TCP_REFRESH_HIT' in status:
            # Revalidation hit - object served from cache after 304 response
            # Count the full object size (what client received) but mark as revalidated
            revalidated_bytes[domain] += size
            revalidated_count[domain] += 1
        elif 'HIT' in status:
            # Direct cache hit
            hit_bytes[domain] += size
            hit_count[domain] += 1
        elif 'MISS' in status or 'REFRESH' in status:
            # Cache miss or revalidation miss
            miss_bytes[domain] += size
            miss_count[domain] += 1
    
    return miss_bytes, miss_count, hit_bytes, hit_count, revalidated_bytes, revalidated_count


def merge_stats(all_stats: List[Tuple]) -> Tuple[Dict, Dict, Dict, Dict, Dict, Dict]:
    """Merge statistics from multiple pods"""
    merged_miss_bytes = defaultdict(int)
    merged_miss_count = defaultdict(int)
    merged_hit_bytes = defaultdict(int)
    merged_hit_count = defaultdict(int)
    merged_revalidated_bytes = defaultdict(int)
    merged_revalidated_count = defaultdict(int)
    
    for miss_bytes, miss_count, hit_bytes, hit_count, revalidated_bytes, revalidated_count in all_stats:
        for domain, value in miss_bytes.items():
            merged_miss_bytes[domain] += value
        for domain, value in miss_count.items():
            merged_miss_count[domain] += value
        for domain, value in hit_bytes.items():
            merged_hit_bytes[domain] += value
        for domain, value in hit_count.items():
            merged_hit_count[domain] += value
        for domain, value in revalidated_bytes.items():
            merged_revalidated_bytes[domain] += value
        for domain, value in revalidated_count.items():
            merged_revalidated_count[domain] += value
    
    return (merged_miss_bytes, merged_miss_count, merged_hit_bytes, merged_hit_count,
            merged_revalidated_bytes, merged_revalidated_count)


def format_report(miss_bytes: Dict, miss_count: Dict, hit_bytes: Dict, hit_count: Dict,
                  revalidated_bytes: Dict, revalidated_count: Dict,
                  min_mb: float = 0.0, max_rows: int = 50) -> str:
    """Format analysis results as a table"""
    results = []
    
    all_domains = set(list(miss_bytes.keys()) + list(hit_bytes.keys()) + list(revalidated_bytes.keys()))
    
    for domain in all_domains:
        miss_mb = miss_bytes[domain] / 1048576.0
        hit_mb = hit_bytes[domain] / 1048576.0
        reval_mb = revalidated_bytes[domain] / 1048576.0
        total_mb = miss_mb + hit_mb + reval_mb
        
        if total_mb < min_mb:
            continue
        
        # Effective hit ratio: (direct hits + revalidated) / total
        # Revalidated = saved bandwidth (only 304 validation overhead, not full object transfer)
        effective_hit_mb = hit_mb + reval_mb
        effective_hit_ratio = (effective_hit_mb * 100.0 / total_mb) if total_mb > 0 else 0
        
        results.append((total_mb, domain, miss_count[domain], miss_mb, 
                       hit_count[domain], hit_mb,
                       revalidated_count[domain], reval_mb,
                       effective_hit_ratio))
    
    results.sort(reverse=True)
    
    lines = []
    lines.append(f'{"Domain":<50} {"MISS":<12} {"HIT":<12} {"REVAL":<12} {"Total_MB":<10} {"EffHit%":<8}')
    lines.append(f'{"":50} {"Cnt":<6}{"MB":<6} {"Cnt":<6}{"MB":<6} {"Cnt":<6}{"MB":<6}')
    lines.append('=' * 130)
    
    for total_mb, domain, m_cnt, m_mb, h_cnt, h_mb, r_cnt, r_mb, eff_ratio in results[:max_rows]:
        lines.append(f'{domain:<50} {m_cnt:<6}{m_mb:<6.1f} {h_cnt:<6}{h_mb:<6.1f} '
                    f'{r_cnt:<6}{r_mb:<6.1f} {total_mb:<10.1f} {eff_ratio:<8.1f}')
    
    # Summary
    total_miss = sum(miss_bytes.values()) / 1048576.0
    total_hit = sum(hit_bytes.values()) / 1048576.0
    total_reval = sum(revalidated_bytes.values()) / 1048576.0
    total_all = total_miss + total_hit + total_reval
    
    # Effective hit ratio includes revalidated (saved bandwidth)
    effective_hit = total_hit + total_reval
    effective_hit_ratio = (effective_hit * 100.0 / total_all) if total_all > 0 else 0
    
    # Origin bandwidth saved (what didn't need to be transferred from origin)
    # Revalidation only costs a few hundred bytes (304 response), not the full object size
    origin_transferred = total_miss + (total_reval * 0.001)  # Assume 0.1% overhead for 304 responses
    origin_saved_ratio = ((total_all - origin_transferred) * 100.0 / total_all) if total_all > 0 else 0
    
    lines.append('')
    lines.append('--- Summary ---')
    lines.append(f'Total MISS:        {total_miss:.1f} MB ({sum(miss_count.values())} requests)')
    lines.append(f'Total HIT:         {total_hit:.1f} MB ({sum(hit_count.values())} requests)')
    lines.append(f'Total REVALIDATED: {total_reval:.1f} MB ({sum(revalidated_count.values())} requests, ~304 overhead)')
    lines.append(f'Total Traffic:     {total_all:.1f} MB')
    lines.append(f'')
    lines.append(f'Effective Hit Ratio (HIT + REVAL):  {effective_hit_ratio:.1f}%')
    lines.append(f'Origin Bandwidth Saved:             {origin_saved_ratio:.1f}%')
    lines.append(f'')
    lines.append(f'Note: REVALIDATED = TCP_REFRESH_UNMODIFIED (304 Not Modified from origin)')
    lines.append(f'      Client received full object from cache, origin only sent 304 header')
    
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(
        description='Analyze squid access.log per-domain cache hit ratios',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('--kubeconfig', required=True, help='Path to kubeconfig file')
    parser.add_argument('-n', '--namespace', default='squid', help='Kubernetes namespace (default: squid)')
    parser.add_argument('--pods', help='Comma-separated pod names (default: auto-discover)')
    parser.add_argument('-c', '--container', default='squid', help='Container name (default: squid)')
    parser.add_argument('-o', '--output', help='Output file (default: stdout)')
    parser.add_argument('--min-mb', type=float, default=0.5, help='Minimum traffic in MB to include (default: 0.5)')
    parser.add_argument('--max-rows', type=int, default=50, help='Maximum rows to display (default: 50)')
    
    args = parser.parse_args()
    
    try:
        # Get pod list
        pods = get_pods(args.kubeconfig, args.namespace, args.pods)
        if not pods:
            print(f"Error: No squid pods found in namespace {args.namespace}", file=sys.stderr)
            return 1
        
        print(f"Analyzing {len(pods)} pod(s): {', '.join(pods)}", file=sys.stderr)
        
        # Fetch and parse logs from all pods
        all_stats = []
        for pod in pods:
            print(f"Fetching access.log from {pod}...", file=sys.stderr)
            try:
                log_content = fetch_access_log(args.kubeconfig, args.namespace, pod, args.container)
                stats = parse_access_log(log_content)
                all_stats.append(stats)
            except subprocess.CalledProcessError as e:
                print(f"Warning: Failed to fetch log from {pod}: {e}", file=sys.stderr)
                continue
        
        if not all_stats:
            print("Error: No logs successfully fetched", file=sys.stderr)
            return 1
        
        # Merge stats
        miss_bytes, miss_count, hit_bytes, hit_count, revalidated_bytes, revalidated_count = merge_stats(all_stats)
        
        # Format report
        report = format_report(miss_bytes, miss_count, hit_bytes, hit_count, 
                              revalidated_bytes, revalidated_count, args.min_mb, args.max_rows)
        
        # Output
        if args.output:
            with open(args.output, 'w') as f:
                f.write(report)
            print(f"Report saved to {args.output}", file=sys.stderr)
        else:
            print(report)
        
        return 0
    
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
