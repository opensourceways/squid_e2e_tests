# Squid 304 Revalidation Content-Length Bug Reproduction

## Bug Summary

When Squid receives a `304 Not Modified` response with `Content-Length: 0` from origin servers (common behavior from Akamai CDN, Google Cloud Storage, Azure Blob Storage, and Huawei Cloud OBS), it incorrectly serves zero-byte responses to clients even though the full cached object exists.

**Related upstream bugs:**
- https://bugs.squid-cache.org/show_bug.cgi?id=5359 (2018-2022, unresolved)
- Squid GitHub PR #2401 (2026-04, pending merge)

**Affected Squid versions:**
- Squid 3.5.27
- Squid 4.x series
- Squid 7.6 (confirmed in gy-006 and gy-001)

**Affected origin servers:**
- `q.qlogo.cn` (QQ/WeChat avatars)
- `storage.googleapis.com` (Google Cloud Storage)
- `*.blob.core.windows.net` (Azure Blob Storage)
- `mindx-package.obs.cn-north-4.myhuaweicloud.com` (Huawei Cloud OBS) ← **our case**

## Root Cause

According to RFC 9111 Section 3.2, `Content-Length` must NOT be updated when applying a 304 response to a cached entry:

> the cache MUST add each header field in the provided response to the stored response, replacing field values that are already present, with the following exceptions: [...] **Content-Length**

However, Squid's `HttpHeader::update()` does not skip `Content-Length`, so when a 304 contains `Content-Length: 0` (which many CDNs incorrectly send), Squid replaces the cached entry's correct `Content-Length` with 0.

## Symptom Progression

1. **Initial request**: Squid fetches file from origin, caches it correctly with proper `Content-Length`
2. **Revalidation**: After cache goes stale, Squid sends conditional GET with `If-None-Match` / `If-Modified-Since`
3. **Buggy 304**: Origin responds `304 Not Modified` with `Content-Length: 0`
4. **Squid updates cache**: `HttpHeader::update()` replaces stored `Content-Length: 202104` with `0`
5. **Subsequent requests**: All cache hits serve `Content-Length: 0` with empty body
6. **Client impact**: wget/curl save 0-byte files, `tar`/`gzip` fail with "unexpected end of file"

## Files in This Directory

- `README.md` - This file
- `reproduce.sh` - Automated reproduction script for gy-006
- `vcjob-reproduce.yaml` - Kubernetes VcJob to trigger the bug
- `evidence/` - Directory for collected logs and debug output

## Quick Reproduction (gy-006)

```bash
cd /home/chenqi252/code/gitcode-ci/workspace-squid/squid_e2e_tests/304BUG
./reproduce.sh
```

## Manual Reproduction Steps

### 1. Verify squid is running with debug enabled

```bash
kubectl get pods -n squid --kubeconfig ~/.kube/gy-006.yaml
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
  grep "debug_options" /etc/squid/squid.conf
```

### 2. Purge any existing cache entry

```bash
for pod in squid-cache-0 squid-cache-1; do
  kubectl exec -n squid $pod -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
    curl -s -X PURGE \
    "http://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz" \
    -H "Host: mindx-package.obs.cn-north-4.myhuaweicloud.com" \
    -x 127.0.0.1:3128
done
```

### 3. Trigger initial cache population

```bash
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
  curl -sI -x 127.0.0.1:3128 \
  "https://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz" | \
  grep -E "HTTP|Content-Length"
```

Expected: `Content-Length: 202104`

### 4. Wait for cache to go stale (~80 minutes with default refresh_pattern, 20% of Last-Modified age)

Or force revalidation by waiting and requesting again.

### 5. Trigger revalidation and observe bug

Submit a test job that downloads the file:

```bash
kubectl apply -f vcjob-reproduce.yaml --kubeconfig ~/.kube/gy-006.yaml
```

### 6. Collect evidence

**Check client-side failure:**
```bash
kubectl logs -n test-namespace <pod-name> --kubeconfig ~/.kube/gy-006.yaml
```

Expected output:
```
--2026-08-26 XX:XX:XX--  https://mindx-package.obs...148/master_ci.tar.gz
Proxy request sent, awaiting response... 200 OK
Length: 0 [application/gzip]
Saving to: 'master_ci.tar.gz'

2026-08-26 XX:XX:XX (0.00 B/s) - 'master_ci.tar.gz' saved [0/0]

gzip: stdin: unexpected end of file
tar: Child returned status 1
tar: Error is not recoverable: exiting now
```

**Check squid access.log:**
```bash
kubectl logs -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml | \
  grep "MultimodalSDK/148"
```

Expected pattern:
```
TCP_MISS/200 202631 GET https://.../148/master_ci.tar.gz
TCP_REFRESH_UNMODIFIED_ABORTED/200 53779 GET https://.../148/master_ci.tar.gz
TCP_MEM_HIT_ABORTED/200 53781 GET https://.../148/master_ci.tar.gz
```

**Check squid debug log (if debug_options enabled):**
```bash
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
  tail -1000 /var/log/squid/cache.log | grep -A10 "handleIMSReply"
```

Expected to find:
```
handleIMSReply: https://.../148/master_ci.tar.gz got ioBuf(@0, len=0, 0)
handleIMSReply: origin replied 304, revalidated existing entry and sending 200 to client
```

And in the HTTP Client REPLY section:
```
HTTP/1.1 200 OK
Content-Length: 0
...
```

### 7. Verify origin behavior

```bash
# Direct request (bypass squid)
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
  curl -sI "https://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz"

# Conditional request (simulate squid revalidation)
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig ~/.kube/gy-006.yaml -- \
  curl -sI \
  -H 'If-None-Match: "907daec16191877d45d1728dc835f6d8"' \
  -H 'If-Modified-Since: Wed, 26 Aug 2026 03:05:23 GMT' \
  "https://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz"
```

Expected 304 response:
```
HTTP/1.1 304 Not Modified
Content-Length: 0
ETag: "907daec16191877d45d1728dc835f6d8"
Last-Modified: Wed, 26 Aug 2026 03:05:23 GMT
```

This confirms the origin (OBS) sends `Content-Length: 0` in 304 responses, which is technically correct per HTTP spec (304 has no body), but triggers Squid's bug.

## Workarounds

### Option A: Disable revalidation for these files (recommended)

Add to squid.conf:
```squid
refresh_pattern -i mindx-package\.obs\.cn-north-4\.myhuaweicloud\.com.*\.(tar\.gz|zip)$ \
  10080 100% 525600 ignore-reload override-expire ignore-no-store
```

This prevents Squid from ever revalidating these files, avoiding the bug entirely.

### Option B: Disable caching for affected domains

```squid
acl obs_buggy_304 dstdom_regex ^mindx-package\.obs\.cn-north-4\.myhuaweicloud\.com$
cache deny obs_buggy_304
```

Not ideal (loses caching benefit), but guarantees correct behavior.

### Option C: Apply upstream fix

Wait for Squid GitHub PR #2401 to merge, or cherry-pick the fix:

In `src/HttpHeader.cc`, modify `HttpHeader::skipUpdateHeader()`:

```cpp
bool HttpHeader::skipUpdateHeader(const Http::HdrType id) const
{
    return
        (id == Http::HdrType::VARY) ||
        // RFC 9111 Section 3.2 explicitly excludes Content-Length
        // from the "MUST add ..., replacing already present" list.
        (id == Http::HdrType::CONTENT_LENGTH);
}
```

## Timeline (gy-001 cluster incident)

- **2026-08-26 11:05** - OBS uploads `MultimodalSDK/148/master_ci.tar.gz` (202104 bytes)
- **2026-08-26 11:09** - Squid fetches and caches file (TCP_MISS/200 202631)
- **2026-08-26 15:01** - First revalidation, receives buggy 304 (TCP_REFRESH_UNMODIFIED_ABORTED/200 53779)
- **2026-08-26 15:16** - CI job downloads 0 bytes, tar fails
- **2026-08-26 15:29** - After manual PURGE, bug recurs within 5 minutes (TCP_REFRESH_UNMODIFIED_ABORTED/200 111123)
- **2026-08-26 16:40** - After second PURGE, bug recurs again (TCP_REFRESH_UNMODIFIED_ABORTED/200 123411)

Pattern: Bug recurs reliably on every revalidation attempt (once the ~80-minute freshness window has passed).

## References

- Squid Bugzilla #5359: https://bugs.squid-cache.org/show_bug.cgi?id=5359
- Squid GitHub PR #2401: https://github.com/squid-cache/squid/pull/2401
- RFC 9111 Section 3.2: https://www.rfc-editor.org/rfc/rfc9111#section-3.2
- RFC 9110 Section 15.4.5 (304 semantics): https://www.rfc-editor.org/rfc/rfc9110#section-15.4.5
