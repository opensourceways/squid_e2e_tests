# gitcode.com/Ascend org — Stack, Build Tools & HTTP Download Audit

Date: 2026-08-06. Method: shallow-cloned all 100 public repos (99 cloned, `.gitcode` empty),
scanned build files (Dockerfile, *.sh, *.py, CMakeLists, WORKSPACE/.bazelrc, go.mod,
Cargo.toml, package.json, requirements.txt, *.yml) for download patterns.

## 1. Stack overview

| Stack | Repos (representative) |
|---|---|
| **PyTorch / torch_npu ecosystem** (Python + C++) | pytorch, op-plugin, torchair, apex, MindSpeed, MindSpeed-LLM/MM/RL, MindSpeed-Bridge, MindSpeed-Ops, MegatronAdaptor, fbgemm-ascend, ops-rec, HierarchicalKV-ascend, TransferQueue, ATK, msboost |
| **LLM inference engines** (C++ heavy) | MindIE-LLM, MindIE-Motor(-CPP), MindIE-Turbo, MindIE-SD, MultimodalSDK, triton-ascend, text-embeddings-inference (Rust) |
| **MLIR / compiler** | AscendNPU-IR (MLIR/C++), torch-mlir, llvm-project (fork), msdebug (bazel/LLVM) |
| **MindStudio toolchain** (C++/Python) | msprof, msprof-analyze, msserviceprofiler, msinsight, msmemscope, msmonitor, msmodeling, msmodelslim, msopgen, mspti, mstx, mssanitizer, msopcom, mskpp, msoptuner, msopprof, mskl, msot, mockcpp |
| **SDKs / agents** | AgentSDK, VisionSDK, IndexSDK, RAGSDK, MindInferenceService, MindSpeed-Agent, model-agent, agent-skills, msagent, msit, mstt, msprobe |
| **Cloud-native / infra** | MEF (Go), mind-cluster (Go/Python), OMSDK (Go), ray-ascend, ascend-deployer, ascend-docker-image |
| **Model zoo** | ModelZoo-PyTorch, modelzoo, modelzoo-GPL, pytorch-ecosystem, mindsdk-referenceapps, FlashGen, DrivingSDK, RecSDK, MindCluster-AscendNPUBurn |

Language stats: Python ~60 repos, C++ ~30, Go 3, Rust 1, Shell a few.

## 2. Build tools and how they download (squid-proxy-relevant)

### 2.1 pip / PyPI — THE dominant mechanism (92/99 repos)
Every Python repo installs deps via `pip install`. Indexes seen in the wild:

| Index URL | Count |
|---|---|
| `https://pypi.ngc.nvidia.com` | 16 |
| `https://testpypi.python.org/pypi` | 13 |
| `https://pypi.tuna.tsinghua.edu.cn/simple` | 12 |
| `https://mirrors.aliyun.com/pypi/simple/` | 10 |
| `https://repo.huaweicloud.com/repository/pypi/simple` | 12 |
| `https://download.pytorch.org/whl/cpu` | 5 |
| `https://pypi.org/simple` | 3 |
| internal: `cmc.centralrepo.rnd.huawei.com/artifactory/pypi-central-repo/simple`, `pypi.cloudartifact.dgg.dragon.tools.huawei.com` | 8 |

Heaviest pip users: ModelZoo-PyTorch (2797 files), model-agent (368), msmodelslim (79),
MindSpeed-MM (76), DrivingSDK (103), agent-skills (107).

### 2.2 Direct wget/curl downloads
Hosts hit by raw `wget`/`curl` (from scripts, .md, model cards):

| Host | Count |
|---|---|
| `dl.fbaipublicfiles.com` | 1188 |
| `github.com` (releases, raw) | 222 |
| `images.cocodataset.org` | 148 |
| `statmt.org` / `data.statmt.org` | 212 |
| `s3.amazonaws.com` | 94 |
| `cdn-datasets.huggingface.co` | 93 |
| `www.openslr.org`, `kaldi-asr.org` | 142 |
| `storage.googleapis.com` | 69 |
| `gitcode.com` (self) | 60 |

### 2.3 git clone / submodules
Pervasive (pytorch, apex, MindSpeed-*, fbgemm-ascend, MindIE-*). Clones come from
`github.com`, `gitcode.com`, `gitee.com`, `codehub.devcloud.cn-north-4.huaweicloud.com`.
Repos with git submodules: pytorch (third_party), apex, text-embeddings-inference.
ModelZoo-PyTorch: 1237 files with git clone references.

### 2.4 CMake FetchContent / ExternalProject (C++ repos)
`FetchContent_Declare(GIT_REPOSITORY https://github.com/google/googletest.git ...)` —
AscendNPU-IR/bishengir/triton/unittest/googletest.cmake.
Also in: MindIE-LLM (ExternalProject_Add xN), msprof, mssanitizer, msopprof, msot,
msopgen, mspti, MindSpeed-Ops, memcache, faiss, memfabric_hybrid, msdebug,
Triton-distributed-ascend, msinsight, MindIE-SD.
NOTE: some use `URL file://${cache_dir}/...` (pre-cached tarballs → no network).

### 2.5 Bazel http_archive
- **msdebug**: `msdebug/utils/bazel/WORKSPACE`, `examples/http_archive/WORKSPACE`,
  `examples/submodule/WORKSPACE` (4 http_archive refs).
- **memfabric_hybrid**: 2 http_archive refs.
- **pytorch**: bazelrc present (bazel with git dep via `git_repository`), plus pip.

### 2.6 Go modules
- MEF: 27 go.mod refs across src/mef-edge, src/mef-center etc.
- mind-cluster: 16, OMSDK, memfabric_hybrid, mindsdk-referenceapps.
`go mod download` fetches from `proxy.golang.org` / `goproxy.cn`.

### 2.7 npm (frontend/UI components)
Registry: `https://registry.npmmirror.com/` (353), `registry.npmjs.org` (36).
Users: msinsight, AgentSDK, msmodeling, modelzoo-GPL, DrivingSDK, mskl, msopprof,
OMSDK, MindIE-LLM, msserviceprofiler, MindSpeed-RL, model-agent, agent-skills.

### 2.8 Cargo / crates.io
- **text-embeddings-inference**: Cargo.toml with 49 deps (anyhow, hf-hub, tokenizers,
  tokio, metrics...) + `[patch.crates-io]`.
- MindIE-Motor (6), msinsight (4), slime-ascend (2), msmonitor (1),
  mindsdk-referenceapps (1), ascend-docker-image (1).

### 2.9 conda
Channels: conda-forge, pytorch. Users: DrivingSDK (41), MindSpeed-MM (27), model-agent
(22), modelzoo-GPL (11), agent-skills (10), slime-ascend (5), faiss (4),
MindSpeed-Agent (4), MindSpeed-RL (2), MindSpeed-Core-MS (2), msopgen (2), docs.

### 2.10 apt/yum/dnf (base image layers)
Widespread (MindIE-Motor 33, DrivingSDK 32, msinsight 15, MindSpeed-MM 11,
modelzoo-GPL 23, agent-skills 12, mind-cluster 48). Runs inside buildkitd anyway.

### 2.11 obsutil (OBS object storage, Huawei-specific)
`obsutil cp obs://mindcluster-...` in mind-cluster (9), modelzoo-GPL, mstt, modelzoo,
triton-ascend. OBS upload/download — NOT plain HTTP; needs obsutil proxy verification.

### 2.12 Additional tools found in the extended scan (v2)

The first scan used a narrow regex set and missed these. Full list, verified against
the cloned repos:

| Tool | Files | Where used (representative) |
|---|---|---|
| **uv** (uv sync/uv pip) | 47 | msmodeling (build/bootstrap.py, deploy_env.py, scripts/lib/common.sh, CI) — heavy real usage |
| **huggingface-cli / huggingface_hub** (snapshot_download, hf download) | 328 | pytorch/benchmarks/llm/download_hf.py, MindSpeed-MM (modeling_qwen3_tts.py, state.py, sdxl examples), MindSpeed-RL (verl_examples scripts), DrivingSDK (Cosmos-Predict2 patch.py), modelzoo-GPL |
| **pnpm** | 12 | AgentSDK/openclaw (install_to_image.sh, install-sc-local.sh, READMEs) |
| **poetry** | 3 | MindSpeed-RL docs, AgentSDK skillhub README |
| **pipenv** | 6 | docs mentions (no verified heavy use) |
| **gradle** | 12 | ModelZoo-PyTorch Wenet android workflow, msmodeling skills — mostly docs/edge |
| **maven** | 6 | docs only (community third-party guide, msopgen golden outputs) — NOT a real build dependency |
| **git-lfs** (`git lfs install/pull/fetch`) | real use | mind-cluster docs, ascend-docker-image (tei start_tei.sh, start_clip.sh), DrivingSDK GR00T-N1.6 README — model files stored in LFS |
| **s3cmd / aws s3** | 21 | ModelZoo-PyTorch OpenFold download scripts, MT5 convert scripts |
| **azcopy** | 3 | ModelZoo-PyTorch ESPnet prepare_data.sh |
| **yarn** | 0 | — |
| **conan / vcpkg / CPM / Hunter / meson** | 0 | — |

Net: the real build-time download stack of the Ascend org is
**pip (+uv, +conda) → wget/curl → git → huggingface_hub → npm/pnpm → cargo →
go → bazel → cmake FetchContent → obsutil**, with huggingface_hub and uv being the
biggest misses of the first pass.

## 3. Which download paths go through squid?

All standard tools honor `HTTP(S)_PROXY` and can be routed through the squid SSL-bump:

| Tool | Via squid? | Notes |
|---|---|---|
| pip | yes | wheel/metadata caching works (`.whl` refresh_pattern 100% 7d-365d) |
| **uv** | yes | uv is curl-based → honors HTTPS_PROXY; also has `UV_CA_BUNDLE`/`UV_SSL_CERT_FILE` |
| wget/curl | yes | big model tarballs = prime cache candidates |
| git clone/submodule | yes | smart HTTP; github.com 302s now fixed |
| **git-lfs** | yes | LFS objects download over HTTPS; `git config http.sslCAInfo` inherited |
| **huggingface_hub** | yes | requests-based → REQUESTS_CA_BUNDLE; download via cdn.huggingface.co (huge cache win) |
| CMake FetchContent | yes | curl-based; uses `GIT_REPOSITORY` or `URL` |
| bazel http_archive | yes | honors http_proxy |
| go mod | yes | proxy.golang.org / goproxy.cn |
| npm / pnpm | yes | registry.npmmirror.com tarballs; pnpm adds its own store layout but same HTTPS |
| cargo | yes | crates.io static.crates.io |
| conda | yes | conda.anaconda.org |
| apt/yum/dnf | yes | but usually cached in base image |
| s3cmd / aws s3 / azcopy | partial | S3-style signed requests — cachable per-URL but often range requests |
| **obsutil** | **verify** | OBS SDK; custom endpoint handling, likely bypasses or needs explicit proxy |

## 3.1 Why the first pass missed tools

The initial scan grepped a fixed set of patterns (`pip install`, `curl|wget`,
`git clone`, `FetchContent`, `http_archive`, `go mod`, `npm install`, `cargo`,
`conda`, `apt`, `obsutil`). It missed tools invoked differently:

- **uv** — `uv sync` / `uv pip` (not `pip install`)
- **huggingface_hub** — `snapshot_download(...)` / `hf download` (Python API, no CLI verb match)
- **pnpm** — `pnpm install`, not `npm`
- **git-lfs** — `git lfs pull`, not a `git clone` pattern
- **s3cmd/azcopy** — distinct CLIs

The v2 scan used ~30 tool signatures across 9 file types and found 8 additional
tools (detailed in §2.12). `yarn`, `conan`, `vcpkg`, `CPM`, `Hunter`, `meson`,
`rustup`, `pipx` are NOT used anywhere in the org.

## 4. Test case coverage (testcase/tool/)

| Audit tool | Real usage in org | Test case | Covered? |
|---|---|---|---|
| pip | 92/99 repos | `01-pip.yaml` | ✅ |
| apt | 401 files | `02-apt.yaml` | ✅ |
| git clone/submodule | all C++ repos | `03-github.yaml` | ✅ |
| go mod | MEF, mind-cluster | `04-goproxy.yaml` | ✅ |
| obsutil | 15 files | `05-obs.yaml` | ✅ |
| wget/curl | 741+ files | `13-wget.yaml` | ✅ |
| CMake FetchContent | ~15 C++ repos | `14-cmake-fetchcontent.yaml` | ✅ |
| bazel http_archive | msdebug, memfabric_hybrid, pytorch | `15-bazel.yaml` | ✅ |
| npm | many | `16-npm.yaml` | ✅ |
| cargo | text-embeddings-inference et al. | `17-cargo.yaml` | ✅ |
| conda | 406 files | `18-conda.yaml` | ✅ |
| uv | 47 files (msmodeling) | `19-uv.yaml` | ✅ |
| huggingface_hub | 328 files | `20-huggingface.yaml` | ✅ |
| git-lfs | mind-cluster, ascend-docker-image, DrivingSDK | `21-gitlfs.yaml` | ✅ |
| pnpm | 12 files (AgentSDK/openclaw) | `22-pnpm.yaml` | ✅ |

**Not covered (justified):**
- **s3cmd / aws s3 / azcopy** — need credentials (signed requests), cannot test without them
- **yarn, conan, vcpkg, CPM, Hunter, meson, rustup, pipx** — **zero usage** in the org (verified)
- **poetry (3), pipenv (6), gradle (12), maven (6)** — docs mentions only, not real build deps; gradle/maven are android/edge only

Result: **15/15 real download tools covered**; the only gaps are credential-bound
(s3/azcopy) or non-existent in the org.

## 5. Best repos for squid cache testing (by traffic shape)

1. **modelzoo-GPL / ModelZoo-PyTorch** — thousands of wget/pip/conda downloads
   (datasets, .pt checkpoints, torch wheels) → tests big-object caching + LRU eviction.
2. **text-embeddings-inference** — Rust cargo build (crates.io), pip, git submodules.
3. **msdebug** — bazel http_archive + cmake FetchContent + 59 git_clone.
4. **pytorch / op-plugin / torchair** — pip wheels + git merge-request clones
   (already exercised in gy-001 vcjobs).
5. **MEF / mind-cluster** — Go modules + obsutil.
6. **AscendNPU-IR** — cmake FetchContent googletest from github (small, fast test).
