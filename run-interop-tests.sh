#!/bin/bash
# run-interop-tests.sh - Run MoQT interop tests with client×relay version matching
#
# Implements the version-matching algorithm:
# 1. Phase 1: Test all (client, relay) pairs at current target version
# 2. Phase 2: Fallback for "behind" implementations (max version < target)
# 3. Phase 3: Forward tests for "ahead" implementations (have newer versions)
#
# Each (client, relay) pair is only tested once, at the newest common version.
#
# Exit codes:
#   0 - All tests passed (or no tests run)
#   1 - One or more test failures occurred

set -euo pipefail

# NOTE: This script intentionally avoids mapfile/readarray for macOS compatibility.
# macOS ships with Bash 3.2 (due to GPLv3 licensing) which lacks these builtins.
# While users can install newer Bash via Homebrew, we prefer zero-friction setup.
# See: https://apple.stackexchange.com/questions/193411/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/implementations.json"
RESULTS_DIR="$SCRIPT_DIR/results/$(date +%Y-%m-%d_%H%M%S)"

# Colors for output (only if stdout is a TTY)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# Parse arguments
DOCKER_ONLY=false
REMOTE_ONLY=false
LIST_ONLY=false
TRANSPORT_FILTER=""
TARGET_VERSION=""  # Will be read from config if not specified
RELAY_FILTER=""    # Filter to specific relay implementation

while [[ $# -gt 0 ]]; do
    case $1 in
        --docker-only) DOCKER_ONLY=true; shift ;;
        --remote-only) REMOTE_ONLY=true; shift ;;
        --list) LIST_ONLY=true; shift ;;
        --transport)
            [[ -n "${2:-}" ]] || { echo "Error: --transport requires a value"; exit 1; }
            TRANSPORT_FILTER="$2"; shift 2
            ;;
        --quic-only) TRANSPORT_FILTER="quic"; shift ;;
        --webtransport-only) TRANSPORT_FILTER="webtransport"; shift ;;
        --target-version)
            [[ -n "${2:-}" ]] || { echo "Error: --target-version requires a value"; exit 1; }
            TARGET_VERSION="$2"; shift 2
            ;;
        --relay)
            [[ -n "${2:-}" ]] || { echo "Error: --relay requires a value"; exit 1; }
            RELAY_FILTER="$2"; shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --docker-only        Only test Docker images"
            echo "  --remote-only        Only test remote endpoints"
            echo "  --transport TYPE     Filter by transport: quic or webtransport"
            echo "  --quic-only          Only test raw QUIC endpoints (moqt://)"
            echo "  --webtransport-only  Only test WebTransport endpoints (https://)"
            echo "  --target-version VER Target draft version (default: from config)"
            echo "  --relay NAME         Only test specific relay implementation"
            echo "  --list               List available implementations and exit"
            echo "  --help               Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
fi

# Read target version from config if not specified via CLI
if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(jq -r '.current_target // "draft-14"' "$CONFIG_FILE")
fi

# List implementations with version info
list_implementations() {
    echo -e "${BLUE}Available MoQT Implementations:${NC}"
    echo ""
    jq -r '.implementations | to_entries[] |
        "  \(.key):\n    Name: \(.value.name)\n    Versions: \(.value.draft_versions | join(", "))\n    Roles: \(.value.roles | keys | join(", "))\n"' \
        "$CONFIG_FILE"
}

if [ "$LIST_ONLY" = true ]; then
    list_implementations
    exit 0
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

#############################################################################
# Helper Functions
#############################################################################

# Get all implementations with a specific role
get_impls_with_role() {
    local role="$1"
    jq -r --arg role "$role" '.implementations | to_entries[] | select(.value.roles[$role] != null) | .key' "$CONFIG_FILE"
}

# Check if implementation supports a version
supports_version() {
    local impl="$1"
    local version="$2"
    jq -e --arg impl "$impl" --arg ver "$version" '.implementations[$impl].draft_versions | index($ver)' "$CONFIG_FILE" > /dev/null 2>&1
}

# Get newest version for an implementation
get_newest_version() {
    local impl="$1"
    # Sort versions and get the first (newest) - assumes draft-NN format
    jq -r --arg impl "$impl" '.implementations[$impl].draft_versions | sort_by(. | ltrimstr("draft-") | tonumber) | reverse | .[0]' "$CONFIG_FILE"
}

# Compare versions: returns "gt" if v1 > v2, "lt" if v1 < v2, "eq" if equal
# NOTE: Currently unused - retained for potential future version negotiation logic
compare_versions() {
    local v1="$1"
    local v2="$2"
    local n1=$(echo "$v1" | sed 's/draft-//')
    local n2=$(echo "$v2" | sed 's/draft-//')
    if [ "$n1" -gt "$n2" ]; then echo "gt"
    elif [ "$n1" -lt "$n2" ]; then echo "lt"
    else echo "eq"
    fi
}

# Track tested pairs (file-based for simplicity)
TESTED_PAIRS_FILE="$RESULTS_DIR/.tested_pairs"
touch "$TESTED_PAIRS_FILE"

# Cleanup handler to remove temporary files on exit
cleanup() {
    rm -f "$TESTED_PAIRS_FILE"
}
trap cleanup EXIT INT TERM

is_pair_tested() {
    local client="$1"
    local relay="$2"
    grep -q "^${client}:${relay}$" "$TESTED_PAIRS_FILE" 2>/dev/null
}

mark_pair_tested() {
    local client="$1"
    local relay="$2"
    echo "${client}:${relay}" >> "$TESTED_PAIRS_FILE"
}

#############################################################################
# Test Execution
#############################################################################

TOTAL=0
PASSED=0
FAILED=0

# Initialize summary JSON
SUMMARY_FILE="$RESULTS_DIR/summary.json"
jq -n --arg version "$TARGET_VERSION" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{runs: [], target_version: $version, timestamp: $ts}' > "$SUMMARY_FILE"

run_test() {
    local client="$1"
    local relay="$2"
    local version="$3"
    local mode="$4"      # "docker" or "remote-quic" or "remote-webtransport"
    local target="$5"    # image name or URL
    local tls_disable="${6:-false}"

    TOTAL=$((TOTAL + 1))

    local test_id="${client}_to_${relay}_${mode}"
    local result_file="$RESULTS_DIR/${test_id}.log"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Test: $client → $relay${NC}"
    echo -e "Version: $version | Mode: $mode"
    echo -e "Target: $target"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local status="unknown"
    local exit_code=0

    if [[ "$mode" == "docker" ]]; then
        if make test RELAY_IMAGE="$target" > "$result_file" 2>&1; then
            status="pass"
            PASSED=$((PASSED + 1))
            echo -e "${GREEN}✓ PASSED${NC}"
        else
            exit_code=$?
            status="fail"
            FAILED=$((FAILED + 1))
            echo -e "${RED}✗ FAILED (exit code: $exit_code)${NC}"
        fi
    else
        # Build make arguments as array to avoid word splitting issues
        local -a make_args=("test-external" "RELAY_URL=$target")
        [ "$tls_disable" = "true" ] && make_args+=("TLS_DISABLE_VERIFY=1")

        if make "${make_args[@]}" > "$result_file" 2>&1; then
            status="pass"
            PASSED=$((PASSED + 1))
            echo -e "${GREEN}✓ PASSED${NC}"
        else
            exit_code=$?
            status="fail"
            FAILED=$((FAILED + 1))
            echo -e "${RED}✗ FAILED (exit code: $exit_code)${NC}"
        fi
    fi

    # Append to summary (using mktemp for safe atomic update)
    local tmp_file
    tmp_file=$(mktemp "${SUMMARY_FILE}.XXXXXX")
    if jq --arg client "$client" \
          --arg relay "$relay" \
          --arg version "$version" \
          --arg mode "$mode" \
          --arg target "$target" \
          --arg status "$status" \
          --argjson exit_code "$exit_code" \
          '.runs += [{"client": $client, "relay": $relay, "version": $version, "mode": $mode, "target": $target, "status": $status, "exit_code": $exit_code}]' \
          "$SUMMARY_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$SUMMARY_FILE"
    else
        rm -f "$tmp_file"
        return 1
    fi

    echo ""
}

# Test a client-relay pair at a specific version
test_pair() {
    local client="$1"
    local relay="$2"
    local version="$3"

    # Skip if already tested
    if is_pair_tested "$client" "$relay"; then
        echo -e "${YELLOW}  Skipping $client → $relay (already tested)${NC}"
        return
    fi

    mark_pair_tested "$client" "$relay"

    # Get relay endpoints
    # Docker test
    if [ "$REMOTE_ONLY" != true ]; then
        local docker_image=$(jq -r --arg relay "$relay" '.implementations[$relay].roles.relay.docker.image // empty' "$CONFIG_FILE")
        if [ -n "$docker_image" ]; then
            run_test "$client" "$relay" "$version" "docker" "$docker_image"
        fi
    fi

    # Remote tests
    if [ "$DOCKER_ONLY" != true ]; then
        local remote_count=$(jq -r --arg relay "$relay" '.implementations[$relay].roles.relay.remote | length // 0' "$CONFIG_FILE")
        for i in $(seq 0 $((remote_count - 1))); do
            local url=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].url' "$CONFIG_FILE")
            local transport=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].transport // "unknown"' "$CONFIG_FILE")
            local tls_disable=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].tls_disable_verify // false' "$CONFIG_FILE")
            local endpoint_status=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].status // "active"' "$CONFIG_FILE")

            # Skip inactive endpoints
            [ "$endpoint_status" = "inactive" ] && continue

            # Apply transport filter
            if [ -n "$TRANSPORT_FILTER" ] && [ "$transport" != "$TRANSPORT_FILTER" ]; then
                continue
            fi

            run_test "$client" "$relay" "$version" "remote-$transport" "$url" "$tls_disable"
        done
    fi
}

#############################################################################
# Main Algorithm
#############################################################################

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         MoQT Interop Tests - Version Matching                 ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Target version: ${CYAN}$TARGET_VERSION${NC}"
echo -e "Results: $RESULTS_DIR"
echo ""

# Get all clients and relays as arrays (avoids word-splitting issues)
# Uses while-read instead of mapfile for Bash 3.2 (macOS) compatibility
CLIENTS_ARR=()
while IFS= read -r line; do
    [ -n "$line" ] && CLIENTS_ARR+=("$line")
done < <(get_impls_with_role "client")

if [ -n "$RELAY_FILTER" ]; then
    RELAYS_ARR=("$RELAY_FILTER")
else
    RELAYS_ARR=()
    while IFS= read -r line; do
        [ -n "$line" ] && RELAYS_ARR+=("$line")
    done < <(get_impls_with_role "relay")
fi

echo -e "${BLUE}Clients:${NC} ${CLIENTS_ARR[*]}"
echo -e "${BLUE}Relays:${NC} ${RELAYS_ARR[*]}"
echo ""

#############################################################################
# Phase 1: Primary tests at target version
#############################################################################

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Phase 1: Primary tests at $TARGET_VERSION${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""

for client in "${CLIENTS_ARR[@]}"; do
    if ! supports_version "$client" "$TARGET_VERSION"; then
        continue
    fi

    for relay in "${RELAYS_ARR[@]}"; do
        if ! supports_version "$relay" "$TARGET_VERSION"; then
            continue
        fi

        echo -e "${YELLOW}Testing: $client → $relay (at $TARGET_VERSION)${NC}"
        test_pair "$client" "$relay" "$TARGET_VERSION"
    done
done

#############################################################################
# Phase 2: Fallback for "behind" implementations
#############################################################################

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Phase 2: Fallback for implementations behind $TARGET_VERSION${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""

target_num=$(echo "$TARGET_VERSION" | sed 's/draft-//')

# Find relays that are behind
for relay in "${RELAYS_ARR[@]}"; do
    relay_newest=$(get_newest_version "$relay")
    relay_num=$(echo "$relay_newest" | sed 's/draft-//')

    if [ "$relay_num" -lt "$target_num" ]; then
        echo -e "${YELLOW}Relay $relay is behind (newest: $relay_newest)${NC}"

        # Find clients that support this relay's newest version
        for client in "${CLIENTS_ARR[@]}"; do
            if supports_version "$client" "$relay_newest"; then
                echo -e "  Found compatible client: $client"
                test_pair "$client" "$relay" "$relay_newest"
            fi
        done
    fi
done

# Find clients that are behind
for client in "${CLIENTS_ARR[@]}"; do
    client_newest=$(get_newest_version "$client")
    client_num=$(echo "$client_newest" | sed 's/draft-//')

    if [ "$client_num" -lt "$target_num" ]; then
        echo -e "${YELLOW}Client $client is behind (newest: $client_newest)${NC}"

        # Find relays that support this client's newest version
        for relay in "${RELAYS_ARR[@]}"; do
            if supports_version "$relay" "$client_newest"; then
                echo -e "  Found compatible relay: $relay"
                test_pair "$client" "$relay" "$client_newest"
            fi
        done
    fi
done

#############################################################################
# Phase 3: Forward tests for "ahead" implementations
#############################################################################

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Phase 3: Forward tests for implementations ahead of $TARGET_VERSION${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Collect all versions newer than target
AHEAD_VERSIONS_ARR=()
while IFS= read -r line; do
    [ -n "$line" ] && AHEAD_VERSIONS_ARR+=("$line")
done < <(jq -r "[.implementations[].draft_versions[]] | unique | .[] | select((. | ltrimstr(\"draft-\") | tonumber) > $target_num)" "$CONFIG_FILE" | sort -t'-' -k2 -rn)

# Guard against empty array with set -u
if [ ${#AHEAD_VERSIONS_ARR[@]} -gt 0 ]; then
    for version in "${AHEAD_VERSIONS_ARR[@]}"; do
        echo -e "${YELLOW}Testing at $version (ahead of target)${NC}"

        for client in "${CLIENTS_ARR[@]}"; do
            if ! supports_version "$client" "$version"; then
                continue
            fi

            for relay in "${RELAYS_ARR[@]}"; do
                if ! supports_version "$relay" "$version"; then
                    continue
                fi

                test_pair "$client" "$relay" "$version"
            done
        done
    done
fi

#############################################################################
# Summary
#############################################################################

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                        TEST SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Total:   $TOTAL"
echo -e "${GREEN}Passed:  $PASSED${NC}"
echo -e "${RED}Failed:  $FAILED${NC}"
echo ""
echo -e "Results saved to: $RESULTS_DIR"
echo -e "Summary JSON: $SUMMARY_FILE"

# Note: TESTED_PAIRS_FILE cleanup is handled by trap

# Exit with failure if any tests failed
[ $FAILED -gt 0 ] && exit 1
exit 0
