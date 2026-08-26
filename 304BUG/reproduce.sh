#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR="$SCRIPT_DIR/evidence"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gy-006.yaml}"
NAMESPACE="squid"
TEST_URL="https://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz"

# Parse arguments
SKIP_PURGE=false
if [ "$1" = "--no-purge" ]; then
    SKIP_PURGE=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Squid 304 Bug Reproduction Script"
echo "Cluster: gy-006"
if [ "$SKIP_PURGE" = "true" ]; then
    echo "Mode: NO PURGE (revalidation test)"
else
    echo "Mode: Fresh cache setup"
fi
echo "=========================================="
echo ""

# Function to collect logs
collect_logs() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_dir="$EVIDENCE_DIR/$timestamp"
    mkdir -p "$log_dir"
    
    echo "Collecting evidence to $log_dir..."
    
    # Squid access logs
    for pod in squid-cache-0 squid-cache-1; do
        echo "  - $pod access.log"
        kubectl logs -n squid "$pod" -c squid --tail=10000 --kubeconfig "$KUBECONFIG" \
            > "$log_dir/${pod}_access.log" 2>&1 || true
        
        # Extract only MultimodalSDK/148 entries
        grep "MultimodalSDK/148" "$log_dir/${pod}_access.log" \
            > "$log_dir/${pod}_148_entries.log" 2>/dev/null || true
    done
    
    # Squid cache.log (if debug enabled)
    echo "  - squid-cache-0 cache.log"
    kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
        cat /var/log/squid/cache.log > "$log_dir/squid-cache-0_cache.log" 2>&1 || \
        echo "cache.log not accessible or empty" > "$log_dir/squid-cache-0_cache.log"
    
    # Squid config
    echo "  - squid.conf"
    kubectl get configmap squid-config -n squid --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.data.squid\.conf}' > "$log_dir/squid.conf" 2>&1 || true
    
    # Test job logs (if exists)
    if [ -n "$JOB_NAME" ]; then
        local pod_name=$(kubectl get pods -n squid -l volcano.sh/job-name="$JOB_NAME" \
            --kubeconfig "$KUBECONFIG" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod_name" ]; then
            echo "  - Test job pod: $pod_name"
            kubectl logs -n squid "$pod_name" --kubeconfig "$KUBECONFIG" \
                > "$log_dir/test_job.log" 2>&1 || true
        fi
    fi
    
    echo "Evidence collected in: $log_dir"
    echo ""
}

if [ "$SKIP_PURGE" = "true" ]; then
    echo "Step 1-2: SKIPPED (--no-purge mode: testing existing cache staleness)"
    echo ""
    echo "NOTE: checking origin headers DIRECTLY (NOT via squid) so we don't"
    echo "accidentally refresh the cached entry before the test job runs."
    echo ""
    echo "Origin Last-Modified (freshness lifetime = 20% of object age, ≈ 80.8 min):"
    response=$(kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
        curl -sI "$TEST_URL" 2>&1)
    echo "$response" | grep -E "HTTP|Content-Length|Last-Modified|ETag" | sed 's/^/  /'
    echo ""
    echo "Ensure the cache was populated more than ~80 min ago (first run),"
    echo "otherwise the entry is still FRESH and the job will be a HIT, not a revalidation."
    echo ""
else
    # Step 1: Purge cache to start fresh
    echo "Step 1: Purging cache for MultimodalSDK/148..."
    for pod in squid-cache-0 squid-cache-1; do
        result=$(kubectl exec -n squid "$pod" -c squid --kubeconfig "$KUBECONFIG" -- \
            curl -s -o /dev/null -w "%{http_code}" -X PURGE \
            "http://mindx-package.obs.cn-north-4.myhuaweicloud.com/Private_Repository/MultimodalSDK/148/master_ci.tar.gz" \
            -H "Host: mindx-package.obs.cn-north-4.myhuaweicloud.com" \
            -x 127.0.0.1:3128 2>&1)
        echo "  $pod: HTTP $result"
    done
    echo ""

    # Step 2: Initial cache population
    echo "Step 2: Populating cache (initial TCP_MISS expected)..."
    response=$(kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
        curl -sI -x 127.0.0.1:3128 "$TEST_URL" 2>&1)
    content_length=$(echo "$response" | grep -i "^Content-Length:" | awk '{print $2}' | tr -d '\r')

    if [ "$content_length" = "202104" ]; then
        echo -e "  ${GREEN}✓${NC} Cache populated correctly: $content_length bytes"
    else
        echo -e "  ${RED}✗${NC} Unexpected Content-Length: $content_length (expected 202104)"
    fi
    echo ""
    echo -e "${YELLOW}NOTE: Cache freshness lifetime for this object is ~80-97 minutes"
    echo "(calculated as 20% of the Last-Modified-to-fetch time gap, per"
    echo "refresh_pattern . 0 20% 4320). To trigger revalidation, wait that"
    echo "long, then run: ./reproduce.sh --no-purge${NC}"
    echo ""
fi

# Step 3: Submit test job
echo "Step 3: Submitting test job..."
# Use kubectl create instead of apply for generateName
kubectl create -f "$SCRIPT_DIR/vcjob-reproduce.yaml" --kubeconfig "$KUBECONFIG"
sleep 2

JOB_NAME=$(kubectl get vcjob -n squid -l test-type=squid-304-bug --kubeconfig "$KUBECONFIG" \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

echo "  Job name: $JOB_NAME"
echo ""

# Step 4: Wait for pod to start
echo "Step 4: Waiting for test pod to start..."
for i in {1..60}; do
    pod_name=$(kubectl get pods -n squid -l volcano.sh/job-name="$JOB_NAME" \
        --kubeconfig "$KUBECONFIG" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$pod_name" ]; then
        echo "  Pod started: $pod_name"
        break
    fi
    sleep 2
done

if [ -z "$pod_name" ]; then
    echo -e "  ${RED}✗${NC} Pod failed to start within 120 seconds"
    collect_logs
    exit 1
fi
echo ""

# Step 5: Wait for completion and stream logs
echo "Step 5: Monitoring test execution..."
echo "----------------------------------------"
kubectl wait --for=condition=ready pod/"$pod_name" -n squid --timeout=60s --kubeconfig "$KUBECONFIG" 2>&1 || true
kubectl logs -f "$pod_name" -n squid --kubeconfig "$KUBECONFIG" 2>&1 &
LOG_PID=$!

# Wait for job completion
for i in {1..120}; do
    status=$(kubectl get vcjob "$JOB_NAME" -n squid --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.state.phase}' 2>/dev/null)
    if [ "$status" = "Completed" ] || [ "$status" = "Failed" ] || [ "$status" = "Aborted" ]; then
        break
    fi
    sleep 2
done

kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true
echo "----------------------------------------"
echo ""

# Step 6: Check result
echo "Step 6: Checking result..."
pod_exit_code=$(kubectl get pod "$pod_name" -n squid --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "unknown")

echo "  Pod exit code: $pod_exit_code"
echo ""

if [ "$pod_exit_code" = "1" ]; then
    echo -e "${RED}=========================================="
    echo "❌ BUG REPRODUCED!"
    echo -e "==========================================${NC}"
    echo ""
    echo "The test job received a 0-byte file from squid,"
    echo "confirming the Squid 304 Content-Length bug."
    echo ""
    BUG_REPRODUCED=true
elif [ "$pod_exit_code" = "0" ]; then
    echo -e "${GREEN}=========================================="
    echo "✓ No bug observed in this run"
    echo -e "==========================================${NC}"
    echo ""
    echo "The file downloaded successfully. This means either:"
    echo "  1. Cache entry has not gone stale yet (no revalidation triggered)"
    echo "  2. Bug has been fixed"
    echo "  3. This specific file/origin doesn't trigger the bug"
    echo ""
    echo "To increase chances of reproduction:"
    echo "  - Wait ~80 minutes (freshness lifetime ≈ 80.8 min), then run:"
    echo "      ./reproduce.sh --no-purge"
    echo "  - Run multiple times in succession"
    echo "  - Check if OBS is returning 304 with Content-Length: 0"
    echo ""
    BUG_REPRODUCED=false
else
    echo -e "${YELLOW}=========================================="
    echo "⚠ Test inconclusive"
    echo -e "==========================================${NC}"
    echo ""
    echo "Pod exit code: $pod_exit_code"
    echo "Unable to determine if bug was reproduced."
    echo ""
    BUG_REPRODUCED=unknown
fi

# Step 7: Collect all evidence
echo "Step 7: Collecting evidence..."
collect_logs

# Step 8: Verify origin behavior
echo "Step 8: Verifying origin server behavior (OBS)..."
echo ""
echo "Direct unconditional request:"
kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
    curl -sI "$TEST_URL" 2>&1 | grep -E "HTTP|Content-Length|ETag|Last-Modified" || true

echo ""
echo "Conditional request (simulating squid revalidation):"
etag=$(kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
    curl -sI "$TEST_URL" 2>&1 | grep -i "^ETag:" | cut -d' ' -f2 | tr -d '\r"')
last_modified=$(kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
    curl -sI "$TEST_URL" 2>&1 | grep -i "^Last-Modified:" | cut -d' ' -f2- | tr -d '\r')

if [ -n "$etag" ] && [ -n "$last_modified" ]; then
    kubectl exec -n squid squid-cache-0 -c squid --kubeconfig "$KUBECONFIG" -- \
        curl -sI -H "If-None-Match: \"$etag\"" -H "If-Modified-Since: $last_modified" \
        "$TEST_URL" 2>&1 | grep -E "HTTP|Content-Length|ETag" || true
    echo ""
    echo "If the 304 response shows 'Content-Length: 0', this is the trigger."
fi

echo ""
echo "=========================================="
echo "Reproduction attempt complete"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Test job: $JOB_NAME"
echo "  Test pod: $pod_name"
echo "  Exit code: $pod_exit_code"
if [ "$BUG_REPRODUCED" = "true" ]; then
    echo -e "  Result: ${RED}BUG REPRODUCED ❌${NC}"
    exit 1
elif [ "$BUG_REPRODUCED" = "false" ]; then
    echo -e "  Result: ${GREEN}No bug observed ✓${NC}"
    exit 0
else
    echo -e "  Result: ${YELLOW}Inconclusive ⚠${NC}"
    exit 2
fi
