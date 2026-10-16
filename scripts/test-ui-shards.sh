#!/bin/bash
# UI Test Shard Runner for Holoscape
# Splits 378 tests across 10 shards (~38 tests each, ~8 min per shard)
# Usage:
#   ./scripts/test-ui-shards.sh              # Run all shards sequentially
#   ./scripts/test-ui-shards.sh 3            # Run shard 3 only
#   ./scripts/test-ui-shards.sh 3-5          # Run shards 3 through 5
#   ./scripts/test-ui-shards.sh failing      # Run only currently-failing classes
#   ./scripts/test-ui-shards.sh resume       # Resume from last failed shard

set -euo pipefail

SCHEME="Holoscape"
DEST="platform=macOS"
RESULTS_DIR="/tmp/holoscape-test-shards"
RESUME_FILE="$RESULTS_DIR/last-failed-shard"

mkdir -p "$RESULTS_DIR"

count_matches() {
    local pattern="$1"
    local file="$2"
    local count
    local grep_status

    if [[ ! -r "$file" ]]; then
        echo "error: cannot read test output: $file" >&2
        return 1
    fi

    set +e
    count=$(grep -c "$pattern" "$file")
    grep_status=$?
    set -e
    if [[ "$grep_status" -gt 1 ]]; then
        echo "error: failed to count '$pattern' in $file" >&2
        return "$grep_status"
    fi
    printf '%s\n' "$count"
}

# Balanced shards — ~38 tests each, heavy classes spread across shards
SHARD_1="IntegrityUITests"                                                    # 41
SHARD_2="KeyboardShortcutsUITests WindowManagementUITests"                    # 34
SHARD_3="StressUITests ThemeSwitchingUITests"                                 # 31
SHARD_4="SearchAdvancedUITests SettingsUITests SessionLauncherUITests"         # 41
SHARD_5="FontSettingsUITests EditMenuUITests ContextMenuUITests"              # 39
SHARD_6="BugReportUITests HTTPAPIUITests TransparencyColorWellUITests"        # 33
SHARD_7="HoloscapeUITests TabBarUITests SplitPaneAdvancedUITests InputBoxUITests" # 37
SHARD_8="ChannelOrderingUITests AgentChannelUITests SplitPaneUITests CloseConfirmationUITests" # 32
SHARD_9="BridgeChannelUITests TerminalInputUITests TabBehaviorUITests SidebarUITests SearchBarUITests" # 32
SHARD_10="URLSchemeUITests TerminalDisplayUITests SSHChannelUITests NotificationSystemUITests TimestampToggleUITests SkinEngineUITests ConfigPersistenceUITests ChannelStateIndicatorUITests ChannelRestorationUITests NotificationUITests DirectoryPersistenceUITests" # 44

get_shard() {
    local n=$1
    local var="SHARD_${n}"
    echo "${!var}"
}

run_shard() {
    local n=$1
    local classes=$(get_shard "$n")
    local args=""

    for class in $classes; do
        args="$args -only-testing:HoloscapeUITests/$class"
    done

    echo ""
    echo "=========================================="
    echo "  SHARD $n: $classes"
    echo "=========================================="
    echo ""

    local outfile="$RESULTS_DIR/shard-${n}.txt"
    local bundle="$RESULTS_DIR/shard-${n}.xcresult"
    local status_file="$RESULTS_DIR/shard-${n}.status"

    # xcodebuild refuses to write to an existing .xcresult bundle.
    # Remove any prior bundle for this shard before the run.
    rm -rf "$bundle"
    rm -f "$status_file"

    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -skipPackagePluginValidation \
        -resultBundlePath "$bundle" \
        $args \
        2>&1 | tee "$outfile" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST"
    local pipeline_status=("${PIPESTATUS[@]}")

    local passed
    local failed
    passed=$(count_matches "passed" "$outfile") || return 1
    failed=$(count_matches "failed" "$outfile") || return 1

    echo ""
    echo "  Shard $n: $passed passed, $failed failed"
    echo "  Results: $outfile"
    echo "  Bundle:  $bundle"

    if [ "${pipeline_status[0]}" -ne 0 ] || [ "${pipeline_status[1]}" -ne 0 ] || [ "${pipeline_status[2]}" -gt 1 ] || [ "$failed" -gt 0 ]; then
        echo "FAIL" > "$status_file"
        echo "$n" > "$RESUME_FILE"
        return 1
    fi
    echo "PASS" > "$status_file"
    return 0
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "  FULL SUITE SUMMARY"
    echo "=========================================="

    local total_passed=0
    local total_failed=0

    for i in $(seq 1 10); do
        local outfile="$RESULTS_DIR/shard-${i}.txt"
        if [ -f "$outfile" ]; then
            local status_file="$RESULTS_DIR/shard-${i}.status"
            local p
            local f
            p=$(count_matches "passed" "$outfile") || return 1
            f=$(count_matches "failed" "$outfile") || return 1
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
            local status="UNKNOWN"
            if [[ -r "$status_file" ]]; then
                status=$(<"$status_file")
                if [[ "$status" != "PASS" && "$status" != "FAIL" ]]; then
                    echo "error: invalid shard status in $status_file: $status" >&2
                    return 1
                fi
            elif [[ "$f" -gt 0 ]]; then
                status="FAIL"
            fi
            printf "  Shard %2d: %3d passed, %3d failed  [%s]\n" "$i" "$p" "$f" "$status"
        else
            printf "  Shard %2d: not run\n" "$i"
        fi
    done

    echo "  ------------------------------------------"
    printf "  TOTAL:    %3d passed, %3d failed\n" "$total_passed" "$total_failed"
    echo ""
}

# Parse arguments
case "${1:-all}" in
    all)
        overall_status=0
        for i in $(seq 1 10); do
            run_shard "$i" || overall_status=1
        done
        print_summary
        exit "$overall_status"
        ;;
    resume)
        overall_status=0
        if [ -f "$RESUME_FILE" ]; then
            start=$(cat "$RESUME_FILE")
            echo "Resuming from shard $start"
            for i in $(seq "$start" 10); do
                run_shard "$i" || overall_status=1
            done
        else
            echo "No resume point found. Run all."
            for i in $(seq 1 10); do
                run_shard "$i" || overall_status=1
            done
        fi
        print_summary
        exit "$overall_status"
        ;;
    failing)
        echo "Running only currently-failing test classes..."
        FAILING_CLASSES=$(grep "Test Case.*failed" /tmp/test-results-full-2.txt 2>/dev/null | sed "s/.*-\[HoloscapeUITests\.\([^ ]*\) .*/\1/" | sort -u)
        args=""
        for class in $FAILING_CLASSES; do
            args="$args -only-testing:HoloscapeUITests/$class"
        done
        failing_bundle="$RESULTS_DIR/failing.xcresult"
        rm -rf "$failing_bundle"
        xcodebuild test \
            -scheme "$SCHEME" \
            -destination "$DEST" \
            -skipPackagePluginValidation \
            -resultBundlePath "$failing_bundle" \
            $args \
            2>&1 | tee "$RESULTS_DIR/failing-only.txt" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST"
        echo "  Bundle:  $failing_bundle"
        ;;
    *-*)
        # Range like 3-5
        start="${1%-*}"
        end="${1#*-}"
        overall_status=0
        for i in $(seq "$start" "$end"); do
            run_shard "$i" || overall_status=1
        done
        print_summary
        exit "$overall_status"
        ;;
    *)
        # Single shard number
        run_shard "$1"
        ;;
esac
