#!/usr/bin/env python3
"""registry-exporter.py — Prometheus metrics from the docker-registry-proxy access log.

Tails the nginx access log (tweaked JSON format, one object per line) and
exposes counters that mirror the squid-exporter metric naming, so the same
PromQL (client_out / origin_in / hitrate) works for both proxies.

Upstream fetch semantics (mirrors squid):
  - server_in counts bytes of MISS/BYPASS/EXPIRED responses (body came from
    the upstream registry)
  - HIT/REVALIDATED/STALE/UPDATING are served from the local disk cache
  - empty cache_status (non-registry proxy traffic) counts as requests only

Usage: registry-exporter.py <access.log> [listen_port]
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "/var/log/nginx/access.log"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9302

UPSTREAM_STATUSES = {"MISS", "BYPASS", "EXPIRED"}
HIT_STATUSES = {"HIT", "REVALIDATED", "STALE", "UPDATING"}


class Stats(object):
    def __init__(self):
        self.lock = threading.Lock()
        self.requests = 0
        self.by_status = {}
        self.hits = 0
        self.misses = 0
        self.client_out_kb = 0.0
        self.server_in_kb = 0.0

    def line(self, obj):
        try:
            status = (obj.get("upstream_cache_status") or "").upper()
        except AttributeError:
            status = ""
        try:
            sent = int(obj.get("bytes_sent") or 0) / 1024.0
        except ValueError:
            sent = 0.0
        with self.lock:
            self.requests += 1
            self.by_status[status] = self.by_status.get(status, 0) + 1
            self.client_out_kb += sent
            if status in UPSTREAM_STATUSES:
                self.misses += 1
                self.server_in_kb += sent
            elif status in HIT_STATUSES:
                self.hits += 1


def tail_loop():
    ino = None
    pos = 0
    while True:
        try:
            with open(LOG, "r", errors="replace") as f:
                st = os.fstat(f.fileno())
                if ino is None or st.st_ino != ino:
                    ino = st.st_ino
                    f.seek(0, 2)
                else:
                    f.seek(pos)
                while True:
                    line = f.readline()
                    if not line:
                        pos = f.tell()
                        break
                    line = line.strip()
                    if line:
                        try:
                            stats.line(json.loads(line))
                        except ValueError:
                            pass
        except FileNotFoundError:
            pass
        time.sleep(0.5)


def render():
    with stats.lock:
        requests = stats.requests
        hits = stats.hits
        misses = stats.misses
        client_out = stats.client_out_kb
        server_in = stats.server_in_kb
        by_status = dict(stats.by_status)
    lines = []
    add = lines.append
    add("# HELP registry_requests_total Total requests seen by the registry proxy.")
    add("# TYPE registry_requests_total counter")
    add("registry_requests_total %d" % requests)
    add("# HELP registry_cache_hits_total Requests served from the local cache.")
    add("# TYPE registry_cache_hits_total counter")
    add("registry_cache_hits_total %d" % hits)
    add("# HELP registry_cache_misses_total Requests fetched from the upstream registry.")
    add("# TYPE registry_cache_misses_total counter")
    add("registry_cache_misses_total %d" % misses)
    add("# HELP registry_cache_status_total Requests by upstream_cache_status.")
    add("# TYPE registry_cache_status_total counter")
    for status in sorted(by_status):
        add("registry_cache_status_total{status=%s} %d" % (json.dumps(status), by_status[status]))
    add("# HELP registry_client_http_kbytes_out_kbytes_total kbytes sent to clients (mirrors squid exporter).")
    add("# TYPE registry_client_http_kbytes_out_kbytes_total counter")
    add("registry_client_http_kbytes_out_kbytes_total %.3f" % client_out)
    add("# HELP registry_server_http_kbytes_in_kbytes_total kbytes fetched from upstream (MISS/BYPASS/EXPIRED, mirrors squid exporter).")
    add("# TYPE registry_server_http_kbytes_in_kbytes_total counter")
    add("registry_server_http_kbytes_in_kbytes_total %.3f" % server_in)
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


stats = Stats()
if __name__ == "__main__":
    t = threading.Thread(target=tail_loop, daemon=True)
    t.start()
    print("registry-exporter: tailing %s, listening on :%d" % (LOG, PORT), flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
