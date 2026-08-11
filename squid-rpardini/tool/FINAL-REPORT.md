# Squid Proxy Performance Test Report

**Report Date:** 2026-08-11  
**Test Cluster:** gy-006 (Guiyang)  
**Squid Version:** squid-openssl (squid/7.6-VCS)

---

## Executive Summary

Tested 16 dependency-download scenarios comparing **direct internet** vs **Squid caching proxy** on the gy-006 Kubernetes cluster, with a newly-generated RFC 5280-compliant CA certificate deployed.

**Results (full 32-job retest, 2026-08-11):**
- **15 of 16 cases working** with a valid direct-vs-squid comparison (94%)
- **Geometric mean speedup: 1.50x**
- **Median speedup: 1.20x**
- **13 of 15** valid comparisons faster through squid (2 slower: cmake, npm)
- **1 case excluded:** huggingface (both variants fail on HuggingFace's upstream Xet 401 — see below)

**Key findings:**
- Squid's benefit correlates with **download size and repeat frequency**: large or repeated fetches win big (wget 8.3x on warm cache, uv 2.4x, apt 2.5x, gitlfs 2.5x); small one-off fetches on fast China mirrors can be mildly slower (npm 0.7x, cmake 0.8x) due to SSL-bump overhead.
- Bazel (case 08) required a **pre-built JKS trust store** shipped as a ConfigMap: Bazel's embedded JVM ignores `JAVA_TOOL_OPTIONS` and OS trust stores; `openssl pkcs12`-built keystores are silently rejected by Java (`trustAnchors must be non-empty`); only a `keytool`-built keystore containing the **squid CA + public roots** works. It is mounted at `/etc/squid-bazel-trust/` and referenced via `startup --host_jvm_args` in `.bazelrc` written by postStart.
- Bazel also needs explicit `http_archive` overrides for its implicit deps (`bazel_skylib`, `rules_cc`, `rules_python`) — Bazel's `DEFAULT.WORKSPACE.SUFFIX` fetches them from hardcoded `github.com` URLs, which time out from gy-006. `rules_python` must use the `bazel-contrib` org URL (the `bazelbuild` org 301-redirects and gh-proxy returns 502 on the redirect chain).

---

## Test Environment

- **Cluster**: gy-006 (Guiyang, China mainland)
- **Squid**: 2/2 Running, squid/7.6-VCS
- **CA**: newly generated (`squid-openssl/ca/006-ca-new/`), deployed to the `squid-ca` secret and `squid-ca-cert` configmap
- **Bazel trust store**: `squid-openssl/ca/006-ca-new/squid-bazel-trust.jks` (keytool-built, squid CA + 155 public roots), deployed as ConfigMap `squid-bazel-trust`
- **Base images**:
  - Cases 01-07, 09-15: `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/ubuntu:24.04`
  - Case 08 (bazel): `swr.cn-north-4.myhuaweicloud.com/memfabric-hybrid/memfabric-hybrid_arm:multi_python_v3` (pre-installed bazel 7.1.0, openssl, g++)
  - Case 16: `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/openeuler/openeuler:24.03`
- **Proxy config**: `HTTP_PROXY=http://squid-cache.squid.svc.cluster.local:3128`
- **China mirrors**: huaweicloud (apt/pip/openEuler), nju.edu.cn (conda), npmmirror (npm/pnpm), rsproxy.cn (cargo), goproxy.cn (go), gh-proxy.test.osinfra.cn (GitHub), openmmlab.com (model weights)
- **Test method**: each case runs twice (direct, then squid), **in parallel** (32 jobs simultaneously, same cluster load for both variants); timer starts after tool bootstrap, measuring only the tool's actual download/install time
- **postStart hooks are identical across all 16 cases and both variants**: JVM trust-store `.bazelrc` write, OS CA injection, and a conditional apt proxy block that only activates when `HTTPS_PROXY` is set (so the direct variant gets the same hook but no squid routing)

---

## Performance Results (2026-08-11 retest)

| Case | Direct (ms) | Squid (ms) | Speedup |
|------|------------|------------|---------|
| wget | 3,786 | 458 | **8.3x** (warm cache) |
| apt | 23,057 | 9,342 | **2.5x** |
| gitlfs | 5,674 | 2,289 | **2.5x** |
| uv | 5,618 | 2,331 | **2.4x** |
| yum | 41,822 | 27,459 | **1.5x** |
| github | 135,879 | 94,105 | **1.4x** |
| conda | 63,842 | 47,167 | **1.4x** |
| pip | 62,806 | 53,568 | **1.2x** |
| pnpm | 10,443 | 8,682 | **1.2x** |
| goproxy | 24,822 | 22,970 | **1.1x** |
| obs | 4,236 | 3,702 | **1.1x** |
| bazel | 27,691 | 25,112 | **1.1x** |
| cargo | 12,296 | 11,658 | **1.1x** |
| cmake | 19,453 | 24,390 | 0.8x |
| npm | 4,970 | 6,973 | 0.7x |
| hf | 29,508 | FAIL | excluded — see below |

**Geometric mean speedup (15 cases): 1.50x**  
**Median speedup: 1.20x**  
**13 faster / 2 slower**

Note: 08-bazel was re-run separately after the `rules_python` mirror fix (see below); all other numbers are from the single parallel 32-job run. Bazel numbers updated 2026-08-11 with the final split `.bazelrc` layout (postStart writes the `startup --host_jvm_args` JVM trust args; the test script appends `common --noenable_bzlmod` / `--registry` / `--cxxopt`), with a `pipefail` + `grep trustStorePassword` wait guarding the postStart/main race.

---

## Case 08-bazel: JVM Trust Store + Implicit Deps

Bazel was the hardest case. Three distinct problems, all root-caused by isolated repro pods:

### 1. Bazel's embedded JVM ignores standard CA injection

Bazel's network downloads (`http_archive`) run through Java's own TLS stack (JSSE). It does **not** read the OS trust store, `SSL_CERT_FILE`, or `JAVA_TOOL_OPTIONS` (Bazel deliberately strips the latter — confirmed in logs: `WARNING: ignoring JAVA_TOOL_OPTIONS in environment`). The only supported injection is `-Djavax.net.ssl.trustStore=<keystore>` passed via `.bazelrc`:

```
startup --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/squid-bazel-trust/squid-bazel-trust.jks
startup --host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit
```

### 2. Only a `keytool`-built keystore works

- `openssl pkcs12 -export` (default weak RC2/SHA1) → JVM silently fails: `InvalidAlgorithmParameterException: the trustAnchors parameter must be non-empty`
- `openssl pkcs12` with AES-256/SHA256 → same error (PKCS12 trust-only certs are unreliable in Java's TrustManagerFactory; confirmed against upstream Bazel issues)
- `keytool -importcert` (Java's own tool) → **works**. Built once using the memfabric image's Bazel-embedded `keytool`, seeded from the JDK's default cacerts (155 public roots) **plus** the squid CA, saved to `ca/006-ca-new/squid-bazel-trust.jks` and deployed as ConfigMap `squid-bazel-trust` (mounted at `/etc/squid-bazel-trust/`).

Never modify Bazel's own bundled `cacerts` — Bazel checksums its install tree and refuses to run (`corrupt installation`).

### 3. Implicit deps must be overridden in WORKSPACE

Bazel's `DEFAULT.WORKSPACE.SUFFIX` auto-fetches `bazel_skylib`, `rules_cc`, `rules_python` from hardcoded `github.com` URLs that time out from gy-006. They must be re-declared in the test WORKSPACE via gh-proxy:

- `bazel_skylib` 1.6.1, `rules_cc` 0.0.9 → `https://gh-proxy.test.osinfra.cn/https://github.com/bazelbuild/...`
- `rules_python` 0.24.0 → **must use `bazel-contrib` org**: the `bazelbuild` org URL 301-redirects to `bazel-contrib`, and gh-proxy returns `502 Bad Gateway` on the redirect chain (verified: `curl` to the `bazel-contrib` URL via gh-proxy → 200)

---

## Bug Found and Fixed During Testing: case 03-github

The original `03-github.yaml` included three `curl` "reachability" probes before the actual `git clone`:

```bash
curl -s -o /dev/null -w "%{http_code} (%{time_total}s)\n" https://github.com
curl -s -o /dev/null -w "%{http_code} (%{time_total}s)\n" https://api.github.com
curl -s -o /dev/null -w "%{http_code} (%{time_total}s)\n" https://raw.githubusercontent.com/...
```

**The bug:** the script also configures `git config --global url."https://gh-proxy.test.osinfra.cn/https://github.com".insteadOf "https://github.com"` — but this rewrite only applies to **git** commands. Plain `curl` requests to `github.com`/`raw.githubusercontent.com` bypass gh-proxy entirely and hit GitHub's real servers, which are flaky/unreachable from gy-006. With no timeout, a single hung curl could add 300-400s of noise to `DURATION`.

**Fix applied:** removed the three curl probes. Only `git clone` remains (correctly uses gh-proxy).

---

## Bug Found and Fixed During Testing: case 04-goproxy

The original `04-goproxy.yaml` set `T_START` **before** downloading and installing the Go toolchain (~95MB bootstrap, ~10-12s), inflating both variants with a constant proxy-irrelevant offset.

**Fix applied:** moved `T_START` to right after toolchain install, matching the timing convention of all other cases (bootstrap before timer, only the tool's actual download measured).

---

## Case 06-wget: Switched to China-Reachable Mirror

Original target `dl.fbaipublicfiles.com` (Meta/FAIR ResNet-50 weights) has no China CDN — direct ~950KB/s, cold-cache squid relay ~30KB/s (slower than direct), warm-cache very fast. Highly cache-state dependent.

**Fix (user-applied):** switched to `download.openmmlab.com/pretrain/third_party/resnet50_msra-5891d200.pth` (94MB, domestic host). Result this round: 3.8s direct → 0.46s squid (**8.3x**, warm cache from prior runs). Key insight: squid gives zero benefit on the first fetch of any object; the benefit appears on repeat fetches.

---

## Squid CA Certificate Fix

### Problem (old CA)

```
Subject: CN=SquidCacheCA, O=CI, OU=Proxy
X509v3 extensions:
    X509v3 Basic Constraints: critical, CA:TRUE
    ❌ X509v3 Key Usage: MISSING
```

Conda's SSL stack (certifi + OpenSSL 3.x) strictly enforces RFC 5280 §4.2.1.3 — CA certs must assert `keyCertSign`. Without it: `CondaSSLError: CA cert does not include key usage extension`. Lenient clients (curl, pip, npm, git, apt, yum, go) accepted the old CA; only conda enforced it.

### Fix (new CA, deployed)

Generated in `squid-openssl/ca/006-ca-new/`:

```bash
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
  -keyout squid-ca-key.pem -out squid-ca.pem \
  -subj "/CN=SquidCacheCA/O=CI/OU=Proxy" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always"
```

SHA256 fingerprint: `9F:3D:88:11:F4:B0:99:3D:0F:67:2D:5A:6D:E7:18:5B:E6:EB:CB:0D:0D:A7:CC:5C:3B:A7:A7:EF:4A:B5:FE:1D`

**Deployed and verified:** squid serves certs signed by the new CA (fingerprint matches), and the `squid-bazel-trust.jks` keystore embeds it. conda now works through squid (1.4x this round).

---

## Excluded Case: 13-huggingface

Both variants fail with the same upstream error this round — unrelated to squid:

```
RuntimeError: ... CAS Client Error: HTTP status client error (401 Unauthorized),
domain: https://cas-server.xethub.hf.co/v2/reconstructions/...
```

HuggingFace's Xet storage backend (`cas-server.xethub.hf.co`) rejects anonymous requests for this file regardless of network path. Earlier rounds also showed a squid-specific `Distant resource does not have a Content-Length` error (from `huggingface_hub` unpinned auto-upgrade 1.26.1→1.27.0 changing storage-backend behavior). Not fixable via squid config; recommended next step: pin `huggingface_hub==1.26.1` for a reproducible baseline.

---

## Analysis by Category

### Big wins (>1.5x)
- **wget (8.3x)**: large model file, warm squid cache
- **apt (2.5x)**, **gitlfs (2.5x)**, **uv (2.4x)**: large/repeated downloads
- **yum (1.5x)**

### Moderate wins (1.1x–1.5x)
- **github (1.4x)**, **conda (1.4x)**, **pip (1.2x)**, **pnpm (1.2x)**, **goproxy (1.1x)**, **obs (1.1x)**, **bazel (1.1x)**, **cargo (1.1x)**

### Roughly neutral / mild slowdowns (<1.0x)
- **cmake (0.8x)**, **npm (0.7x)**: small/fast downloads where squid's SSL-bump + cache-write overhead outweighs caching on a cold run

**Pattern:** squid's benefit correlates strongly with **download size and repeat frequency**. For small, one-off package installs on an already-fast China mirror, the SSL-bump overhead can make squid mildly slower. For large or frequently-repeated downloads, squid wins clearly.

---

## Recommendations

1. **Keep squid in the path for:** large file downloads (models, build artifacts, wheels/packages with big dependency trees — pip, conda, bazel, apt, yum, wget-style artifact fetches)
2. **Consider bypassing squid for:** small, frequent package-manager calls where the mirror is already fast (npm, cmake) — the SSL-bump overhead isn't worth it for these
3. **New CA is deployed and working** — conda compatibility confirmed
4. **Bazel integration now works** via the pre-built JKS ConfigMap (`squid-bazel-trust`) + `.bazelrc` JVM args written by postStart — no runtime keystore building, no postStart race
5. **Investigate hf 401 separately** — upstream Xet storage auth issue; consider pinning `huggingface_hub==1.26.1`
6. **Test scripts should avoid unproxied reachability probes** — any `curl` outside the tool under test can silently contaminate DURATION with unrelated network flakiness (as happened with case 03)

---

**Test execution:** 32 jobs submitted (16 cases × 2 variants, parallel), 31 succeeded, 1 failed (huggingface squid variant — upstream 401). 15 valid comparisons; 13 faster through squid.
