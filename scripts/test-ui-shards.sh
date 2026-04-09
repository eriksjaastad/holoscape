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

    xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        $args \
        2>&1 | tee "$outfile" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST"

    local passed=$(grep -c "passed" "$outfile" 2>/dev/null || echo 0)
    local failed=$(grep -c "failed" "$outfile" 2>/dev/null || echo 0)

    echo ""
    echo "  Shard $n: $passed passed, $failed failed"
    echo "  Results: $outfile"

    if [ "$failed" -gt 0 ]; then
        echo "$n" > "$RESUME_FILE"
        return 1
    fi
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
            local p=$(grep -c "passed" "$outfile" 2>/dev/null || echo 0)
            local f=$(grep -c "failed" "$outfile" 2>/dev/null || echo 0)
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
            local status="OK"
            [ "$f" -gt 0 ] && status="FAIL"
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
        for i in $(seq 1 10); do
            run_shard "$i" || true
        done
        print_summary
        ;;
    resume)
        if [ -f "$RESUME_FILE" ]; then
            start=$(cat "$RESUME_FILE")
            echo "Resuming from shard $start"
            for i in $(seq "$start" 10); do
                run_shard "$i" || true
            done
        else
            echo "No resume point found. Run all."
            for i in $(seq 1 10); do
                run_shard "$i" || true
            done
        fi
        print_summary
        ;;
    failing)
        echo "Running only currently-failing test classes..."
        FAILING_CLASSES=$(grep "Test Case.*failed" /tmp/test-results-full-2.txt 2>/dev/null | sed "s/.*-\[HoloscapeUITests\.\([^ ]*\) .*/\1/" | sort -u)
        args=""
        for class in $FAILING_CLASSES; do
            args="$args -only-testing:HoloscapeUITests/$class"
        done
        xcodebuild test -scheme "$SCHEME" -destination "$DEST" $args \
            2>&1 | tee "$RESULTS_DIR/failing-only.txt" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST"
        ;;
    *-*)
        # Range like 3-5
        start="${1%-*}"
        end="${1#*-}"
        for i in $(seq "$start" "$end"); do
            run_shard "$i" || true
        done
        print_summary
        ;;
    *)
        # Single shard number
        run_shard "$1"
        ;;
esac
