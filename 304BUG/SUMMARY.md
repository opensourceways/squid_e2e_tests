# Squid 304 Bug - Quick Summary

## What Was Done

✅ **Complete bug reproduction framework created** for gy-006 cluster:

### Files Created
1. **README.md** - Comprehensive bug documentation with:
   - Bug summary and root cause analysis
   - Affected versions and servers
   - Manual reproduction steps
   - Workaround options
   - References to upstream bug reports

2. **vcjob-reproduce.yaml** - Kubernetes VcJob that:
   - Downloads test file through squid
   - Detects 0-byte corruption
   - Shows user-visible tar/gzip errors

3. **reproduce.sh** - Automated test script that:
   - Purges cache
   - Populates fresh cache
   - Submits test job
   - Collects evidence (logs, configs)
   - Verifies origin behavior

4. **evidence/** - Directory for test artifacts
   - Access logs from both squid pods
   - Cache logs (if debug enabled)
   - Test job logs

### Test Run #1 Results

**Status**: ✅ No bug observed (expected)

**Why**: Cache was freshly populated, no revalidation occurred yet.

**Next Step**: Wait ~80 minutes for cache to go stale (freshness lifetime ≈ 80.8 min = 20% of Last-Modified age), then run `./reproduce.sh --no-purge` to trigger a 304 revalidation from OBS.

---

## Quick Reproduction

```bash
cd /home/chenqi252/code/gitcode-ci/workspace-squid/squid_e2e_tests/304BUG

# First run (populate cache)
./reproduce.sh

# Wait ~80 minutes (freshness lifetime ≈ 80.8 min)...

# Second run (no purge - trigger revalidation on stale entry)
./reproduce.sh --no-purge
```

---

## Key Findings from gy-001 Incident

✅ **Bug confirmed** - Same exact pattern as upstream Bugzilla #5359

**Evidence collected**:
- Squid debug logs showing `handleIMSReply` with `ioBuf(@0, len=0, 0)`
- OBS returning `304 Not Modified` with `Content-Length: 0`
- Client receiving `Content-Length: 0` in 200 response
- Pattern: `TCP_MISS → TCP_REFRESH_UNMODIFIED_ABORTED → TCP_MEM_HIT_ABORTED`

**Root cause per RFC 9111 Section 3.2**:
> Content-Length must NOT be updated when applying 304 to cached entry

Squid's `HttpHeader::update()` violates this, replacing cached `Content-Length: 202104` with `Content-Length: 0` from buggy 304 responses.

---

## Recommended Actions

### Immediate (gy-001, gy-006)
Apply workaround via config change:

```squid
# Add to squid.conf refresh_pattern section
refresh_pattern -i mindx-package\.obs\.cn-north-4\.myhuaweicloud\.com.*\.(tar\.gz|zip)$ \
  10080 100% 525600 ignore-reload override-expire ignore-no-store
```

This prevents revalidation for OBS CI artifacts, avoiding the bug entirely.

### Long-term
- Monitor Squid GitHub PR #2401 for upstream fix
- Consider upgrading after fix is merged and released
- Report华为云 OBS behavior to Huawei (though it's similar to Google/Microsoft CDNs)

---

## References

- **Upstream bug**: https://bugs.squid-cache.org/show_bug.cgi?id=5359 (2018-2022, unresolved)
- **Fix PR**: https://github.com/squid-cache/squid/pull/2401 (2026, pending)
- **RFC 9111 §3.2**: https://www.rfc-editor.org/rfc/rfc9111#section-3.2
- **This reproduction**: `/home/chenqi252/code/gitcode-ci/workspace-squid/squid_e2e_tests/304BUG/`
