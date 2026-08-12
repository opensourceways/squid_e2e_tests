#!/usr/bin/env bash
# run-tool-tests.sh — same case, TWO runs: WITHOUT squid vs WITH squid
#
# For each case:
#   1. generate a "-direct" variant (no proxy env, script PROXY=)
#   2. submit direct variant to gy-006 → log records one DURATION (original speed)
#   3. submit squid variant to gy-006  → log records one DURATION (should be faster)
#   4. compare the two DURATIONs from the two pod logs
#
# Usage:
#   ./testcase/tool/run-tool-tests.sh                    # all cases
#   ./testcase/tool/run-tool-tests.sh 01 06 13           # subset
#   ./testcase/tool/run-tool-tests.sh --parallel         # run cases in parallel
#
# Kubeconfig: KUBECONFIG env or ~/.kube/gy-006.yaml
# Logs:       testcase/tool/logs/<case>-direct.log | <case>-squid.log

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
NS="squid"
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$TOOL_DIR"
LOG_DIR="$TOOL_DIR/logs"
GEN_PY="$TOOL_DIR/.gen-direct.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
log() { echo -e "${BOLD}[run-tool-tests]${RESET} $*"; }
ok()   { echo -e "  ${GREEN}✅ $*${RESET}"; }
fail() { echo -e "  ${RED}❌ $*${RESET}"; }
info() { echo -e "  ${CYAN}$*${RESET}"; }

# ── config ────────────────────────────────────────────────────────────────
ALL_CASES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16)
declare -A CASE_DESC=(
  [01]="pip"  [02]="apt" [03]="git clone" [04]="go mod" [05]="obsutil"
  [06]="wget/curl" [07]="cmake FetchContent" [08]="bazel" [09]="npm"
  [10]="cargo" [11]="conda" [12]="uv" [13]="huggingface_hub" [14]="git-lfs" [15]="pnpm"
  [16]="yum/dnf"
)

PARALLEL=0
COMPARE_ONLY=0
CASES=()
for a in "$@"; do
  if [[ "$a" == "--parallel" ]]; then PARALLEL=1
  elif [[ "$a" == "--compare-only" ]]; then COMPARE_ONLY=1
  elif [[ "$a" =~ ^[0-9]+$ ]]; then CASES+=("$a")
  else echo "unknown arg: $a" >&2; exit 1; fi
done
if [[ ${#CASES[@]} -eq 0 ]]; then CASES=("${ALL_CASES[@]}"); fi
for c in "${CASES[@]}"; do
  if ! ls "$CASE_DIR/$c"*.yaml >/dev/null 2>&1; then
    echo "case $c: no yaml found in $CASE_DIR" >&2; exit 1
  fi
done

# ── variant generator ─────────────────────────────────────────────────────
# Removes ALL proxy/CA env vars and blanks the in-script PROXY= so the job
# connects DIRECTLY (no squid). Keeps the squid-ca configmap mount (a file
# mount does NOT route traffic; only the proxy env vars do, and they're gone
# here — some scripts unguarded-read /etc/squid-ca, so removing the mount
# would abort them under `set -e`).
cat > "$GEN_PY" << 'PYEOF'
import re, sys, yaml

src, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))

doc.setdefault('metadata', {})
doc['metadata']['labels'].setdefault('pipeline/run-id', 'x')
doc['metadata']['labels']['pipeline/run-id'] += '-direct'

container = doc['spec']['tasks'][0]['template']['spec']['containers'][0]

# strip env vars that route to squid / trust squid CA
DROP_ENV = {
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO',
    'PIP_CERT', 'NODE_EXTRA_CA_CERTS', 'UV_CA_BUNDLE', 'CARGO_HTTP_CAINFO',
    'HF_HUB_ENABLE_HF_TRANSFER', 'UV_SSL_CERT_FILE',
}
if 'env' in container:
    container['env'] = [e for e in container['env'] if e.get('name') not in DROP_ENV]
    if not container['env']:
        del container['env']

# blank in-script proxy setup: PROXY=http://squid-cache... → PROXY=
# and comment out apt Acquire:: lines (empty proxy config = direct)
args = container.get('args', [''])
text = args[0]
text = text.replace(
    'PROXY=http://squid-cache.squid.svc.cluster.local:3128', 'PROXY=')
text = re.sub(r'echo "Acquire::\S*Proxy[^;]*;"[^\n]*', '# direct (no proxy)', text)
args[0] = text
container['args'] = args

# keep postStart hooks identical in both variants — the postStart script is
# the same everywhere (JVM trust store, OS CA injection, conditional apt proxy
# that only activates when HTTPS_PROXY is set, which direct runs don't have)
# container.pop('lifecycle', None)

with open(out, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=1000000)
PYEOF

mkdir -p "$LOG_DIR"

# ── helpers ────────────────────────────────────────────────────────────────

wait_pod() {  # label_value → pod name (polling status.phase)
  local label="$1" deadline="${2:-3600}" pod=""
  local end=$(( $(date +%s) + deadline ))
  while [[ $(date +%s) -lt $end ]]; do
    pod=$(kc get pod -n "$NS" -l "volcano.sh/job-name=$label" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      case "$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)" in
        Succeeded) echo "$pod"; return 0 ;;
        Failed)    echo "$pod"; return 1 ;;
      esac
    fi
    sleep 5
  done
  echo ""; return 1
}

submit_and_wait() {  # yaml suffix(direct|squid) → logfile
  local yaml="$1" suffix="$2" out jname pod logfile phase
  out=$(kc create -f "$yaml" 2>&1)
  jname=$(echo "$out" | grep -oE 'test-squid-[a-z]+(-[a-z0-9]+)*-([a-z0-9]+)' | head -1 \
          || echo "$out" | grep -oE 'job\.batch\.volcano\.sh/[a-z0-9-]+' | tail -1 | cut -d/ -f2)
  if [[ -z "$jname" ]]; then
    fail "submit failed: $out" >&2; return 1
  fi
  info "job: $jname" >&2
  pod=$(wait_pod "$jname")
  logfile="$LOG_DIR/$(basename "${yaml%.yaml}")-$suffix.log"
  if [[ -n "$pod" ]]; then
    kc logs -n "$NS" "$pod" > "$logfile" 2>&1 || true
    phase=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "$logfile|$phase"
  else
    echo "|TIMEOUT"
  fi
}

# extract the single DURATION line from a pod log: "DURATION: NNNNms"
duration_of() {
  local logfile="$1"
  [[ -z "$logfile" || ! -f "$logfile" ]] && { echo ""; return; }
  grep -oE 'DURATION: [0-9.]+(ms|s)' "$logfile" | head -1 | sed 's/DURATION: //' || true
}

# ── main ──────────────────────────────────────────────────────────────────

log "Squid proxy:  http://squid-cache.squid.svc.cluster.local:3128"
log "Kubeconfig:   $KUBECONFIG"
log "Cases:        ${CASES[*]}"
log "Log dir:      $LOG_DIR"
echo ""

# --- Phase 1: submit everything (parallel) or one-by-one (serial) ---------
RES_DIR="$LOG_DIR/.res"; mkdir -p "$RES_DIR"

submit_case() {  # case-num (writes result files; safe from subshells in --parallel)
  local num="$1" yaml base
  yaml=$(ls "$CASE_DIR/$num"*.yaml | head -1)
  base=$(basename "${yaml%.yaml}")
  local diryaml="$LOG_DIR/$base-direct.yaml"

  python3 "$GEN_PY" "$yaml" "$diryaml"
  info "case $num ($base): submitting DIRECT variant..."
  res=$(submit_and_wait "$diryaml" "direct"); echo "$res" > "$RES_DIR/$num-direct"
  info "case $num: submitting SQUID variant..."
  res=$(submit_and_wait "$yaml" "squid"); echo "$res" > "$RES_DIR/$num-squid"
}

if [[ $PARALLEL -eq 1 ]]; then
  for num in "${CASES[@]}"; do submit_case "$num" & done
  wait || true
elif [[ $COMPARE_ONLY -ne 1 ]]; then
  for num in "${CASES[@]}"; do submit_case "$num"; done
fi

# --- Phase 2: compare -----------------------------------------------------
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}COMPARISON: same case, WITHOUT squid vs WITH squid${RESET}"
echo -e "${BOLD}(each log records one DURATION; squid should be faster)${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${RESET}"
printf "%-22s %-16s %-16s %-10s %s\n" "CASE" "DIRECT (no squid)" "SQUID" "SPEEDUP" ""
TOTAL=0; PASS=0; FAILED=0

for num in "${CASES[@]}"; do
  (( TOTAL++ )) || true
  yaml=$(ls "$CASE_DIR/$num"*.yaml | head -1)
  desc="${CASE_DESC[$num]:-$num}"

  resd=$(cat "$RES_DIR/$num-direct" 2>/dev/null || true)
  ress=$(cat "$RES_DIR/$num-squid" 2>/dev/null || true)
  dlog="${resd%%|*}"; dphase="${resd##*|}"
  slog="${ress%%|*}"; sphase="${ress##*|}"

  d=$(duration_of "$dlog")
  s=$(duration_of "$slog")

  speedup=""; verdict=""
  if [[ "$d" =~ ^[0-9.]+(ms|s)$ && "$s" =~ ^[0-9.]+(ms|s)$ ]]; then
    unit="${d#*[0-9.]}"
    dn=${d%ms}; sn=${s%ms}
    [[ "$d" == *s ]] && dn=$(awk "BEGIN{print ${d%s}*1000}")
    [[ "$s" == *s ]] && sn=$(awk "BEGIN{print ${s%s}*1000}")
    speedup=$(awk -v a=$dn -v b=$sn 'BEGIN{printf "%.1fx", a/b}')
    if [[ $sn -lt $dn ]]; then verdict="${GREEN}FASTER${RESET}"; (( PASS++ )) || true
    else verdict="${RED}slower${RESET}"; (( FAILED++ )) || true; fi
  else
    speedup="n/a"; verdict="n/a"; (( FAILED++ )) || true
  fi

  dphase="${dphase:-}"; sphase="${sphase:-}"
  printf "%-22s %-16s %-16s %-10s %b\n" \
    "$num-$desc" "${d:-?} (${dphase:-?})" "${s:-?} (${sphase:-?})" "$speedup" "$verdict"
done

echo ""
echo -e "  Total: $TOTAL   ${GREEN}FASTER: $PASS${RESET}   ${RED}slower/n-a: $FAILED${RESET}"
echo ""
[[ $FAILED -eq 0 ]]
