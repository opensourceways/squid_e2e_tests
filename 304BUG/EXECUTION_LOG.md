# Squid 304 Bug Reproduction - Execution Log

## Test Environment
- **Cluster**: gy-006
- **Squid version**: 7.6-VCS
- **Squid pods**: squid-cache-0, squid-cache-1
- **Test URL**: https://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz
- **Expected file size**: 202104 bytes

## Test Run #1 - 2026-08-26 17:37:30

### Setup
- Purged cache on both squid pods
- Populated cache with fresh copy (TCP_MISS/200)

### Result
✅ **No bug observed** (expected - cache was fresh)

### Squid Access Log
```
1787737174.648 618 10.0.0.113 TCP_MISS/200 519 HEAD https://.../148/master_ci.tar.gz
```

### Client Behavior
- wget downloaded 202104 bytes successfully
- File extracted correctly

### Analysis
The bug did not trigger because:
1. Cache was just populated (very fresh)
2. No revalidation occurred (no 304 from origin)
3. Squid served the cached object directly

### Next Steps
Need to wait for cache to go stale (estimated ~80.8 minutes: 20% of the Last-Modified age, per `refresh_pattern . 0 20% 4320`) and re-run the test to trigger a revalidation.

## Expected Bug Manifestation

When the bug triggers, we expect to see:

### Squid Access Log Pattern
```
TCP_MISS/200 202631 GET https://.../148/master_ci.tar.gz    # Initial cache
TCP_REFRESH_UNMODIFIED_ABORTED/200 53779 GET https://...    # Bug trigger
TCP_MEM_HIT_ABORTED/200 53781 GET https://...               # Subsequent hits serve 0 bytes
```

### Client wget Output
```
--2026-08-26 XX:XX:XX--  https://mindx-package.obs...148/master_ci.tar.gz
Proxy request sent, awaiting response... 200 OK
Length: 0 [application/gzip]          <--- BUG: Should be 202104
Saving to: 'master_ci.tar.gz'

2026-08-26 XX:XX:XX (0.00 B/s) - 'master_ci.tar.gz' saved [0/0]

gzip: stdin: unexpected end of file
tar: Child returned status 1
```

### Squid Debug Log (if enabled)
```
handleIMSReply: https://.../148/master_ci.tar.gz got ioBuf(@0, len=0, 0)
handleIMSReply: origin replied 304, revalidated existing entry and sending 200 to client
HTTP Client REPLY:
HTTP/1.1 200 OK
Content-Length: 0                     <--- BUG: Should be 202104
ETag: "907daec16191877d45d1728dc835f6d8"
Last-Modified: Wed, 26 Aug 2026 03:05:23 GMT
```

### OBS Origin 304 Response
```
HTTP/1.1 304 Not Modified
Content-Length: 0                     <--- Origin's buggy behavior
ETag: "907daec16191877d45d1728dc835f6d8"
Last-Modified: Wed, 26 Aug 2026 03:05:23 GMT
```

## Test Run #2 - TBD (waiting for cache to go stale)

To be executed after waiting period...

---

## Files Generated
- `evidence/20260826_173730/squid-cache-0_access.log`
- `evidence/20260826_173730/squid-cache-1_access.log`
- `evidence/20260826_173730/squid-cache-0_148_entries.log`
- `evidence/20260826_173730/squid-cache-1_148_entries.log`
- `evidence/20260826_173730/squid-cache-0_cache.log`
- `evidence/20260826_173730/squid.conf`
