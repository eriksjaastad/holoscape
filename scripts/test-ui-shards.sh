#!/bin/bash
# UI Test Shard Runner for Holoscape
# Splits 378 tests across 10 shards (~38 tests each, ~8 min per shard)
# Usage:
#   ./scripts/test-ui-shards.sh              # Run all shards sequentially
#   ./scripts/test-ui-shards.sh 3            # Run shard 3 only
#   ./scripts/test-ui-shards.sh 3-5          # Run shards 3 through 5
#   ./scripts/test-ui-shards.sh failing      # Run only currently-failing classes
#   ./scripts/test-ui-shards.sh resume       # Resume from last failed shard
# Results: /tmp/holoscape-test-shards/shard-{1..10}.{txt,xcresult}
# Override the one-hour xcodebuild limit with HOLOSCAPE_UI_TEST_TIMEOUT_SECONDS.
# Override the failing-mode source log with HOLOSCAPE_UI_FAILING_RESULTS_FILE.
# UI execution requires macOS Accessibility/Automation permission for the runner.

set -euo pipefail

SCHEME="Holoscape"
DEST="platform=macOS"
RESULTS_DIR="/tmp/holoscape-test-shards"
RESUME_FILE="$RESULTS_DIR/last-failed-shard"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_RUNNER="$SCRIPT_DIR/run-with-timeout.py"
TEST_OUTPUT_VALIDATOR="$SCRIPT_DIR/validate-xcode-test-output.sh"
UI_TEST_TIMEOUT_SECONDS="${HOLOSCAPE_UI_TEST_TIMEOUT_SECONDS:-3600}"
FAILING_RESULTS_FILE="${HOLOSCAPE_UI_FAILING_RESULTS_FILE:-/tmp/test-results-full-2.txt}"

mkdir -p "$RESULTS_DIR"
declare -a SHARD_RUN_STATUS=()
declare -a SHARD_RUN_PASSED=()
declare -a SHARD_RUN_FAILED=()

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

record_failed_shard() {
    local n="$1"
    local status_file="$2"
    local recording_failed=0

    if ! printf 'FAIL\n' > "$status_file"; then
        echo "error: cannot record failed shard status: $status_file" >&2
        recording_failed=1
    fi
    if ! printf '%s\n' "$n" > "$RESUME_FILE"; then
        echo "error: cannot record failed shard resume point: $RESUME_FILE" >&2
        recording_failed=1
    fi
    return "$recording_failed"
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
    SHARD_RUN_STATUS[$n]="FAIL"
    SHARD_RUN_PASSED[$n]=0
    SHARD_RUN_FAILED[$n]=0

    # xcodebuild refuses to write to an existing .xcresult bundle.
    # Remove prior outputs so the current invocation cannot report stale data.
    if ! rm -rf "$bundle"; then
        echo "error: cannot remove prior result bundle: $bundle" >&2
        record_failed_shard "$n" "$status_file" || true
        return 1
    fi
    if ! rm -f "$outfile"; then
        echo "error: cannot remove prior shard output: $outfile" >&2
        record_failed_shard "$n" "$status_file" || true
        return 1
    fi
    if ! rm -f "$status_file"; then
        echo "error: cannot remove prior shard status: $status_file" >&2
        record_failed_shard "$n" "$status_file" || true
        return 1
    fi

    set +e
    "$TIMEOUT_RUNNER" "$UI_TEST_TIMEOUT_SECONDS" xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -skipPackagePluginValidation \
        -resultBundlePath "$bundle" \
        $args \
        2>&1 | tee "$outfile" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST|error: command timed out"
    local pipeline_status=("${PIPESTATUS[@]}")
    set -e

    local passed
    local failed
    passed=$(count_matches "^Test Case .* passed" "$outfile") || return 1
    failed=$(count_matches "^Test Case .* failed" "$outfile") || return 1
    SHARD_RUN_PASSED[$n]="$passed"
    SHARD_RUN_FAILED[$n]="$failed"
    local output_status=0
    "$TEST_OUTPUT_VALIDATOR" "$outfile" || output_status=$?

    echo ""
    echo "  Shard $n: $passed passed, $failed failed"
    echo "  Results: $outfile"
    echo "  Bundle:  $bundle"

    if [ "${pipeline_status[0]}" -ne 0 ] || [ "${pipeline_status[1]}" -ne 0 ] || [ "${pipeline_status[2]}" -gt 1 ] || [ "$output_status" -ne 0 ] || [ "$failed" -gt 0 ]; then
        record_failed_shard "$n" "$status_file" || return 1
        return 1
    fi
    if ! printf 'PASS\n' > "$status_file"; then
        echo "error: cannot record passed shard status: $status_file" >&2
        return 1
    fi
    SHARD_RUN_STATUS[$n]="PASS"
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
        if [[ -n "${SHARD_RUN_STATUS[$i]+set}" || -f "$outfile" ]]; then
            local status_file="$RESULTS_DIR/shard-${i}.status"
            local p
            local f
            if [[ -n "${SHARD_RUN_STATUS[$i]+set}" ]]; then
                p="${SHARD_RUN_PASSED[$i]}"
                f="${SHARD_RUN_FAILED[$i]}"
            else
                p=$(count_matches "^Test Case .* passed" "$outfile") || return 1
                f=$(count_matches "^Test Case .* failed" "$outfile") || return 1
            fi
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
            local status="UNKNOWN"
            if [[ -n "${SHARD_RUN_STATUS[$i]+set}" ]]; then
                status="${SHARD_RUN_STATUS[$i]}"
            elif [[ -r "$status_file" ]]; then
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
        if [[ ! -r "$FAILING_RESULTS_FILE" ]]; then
            echo "error: cannot read failing-test results: $FAILING_RESULTS_FILE" >&2
            exit 1
        fi
        if ! FAILING_CLASSES=$(sed -n "s/.*-\[HoloscapeUITests\.\([^ ]*\) .*\]' failed.*/\1/p" "$FAILING_RESULTS_FILE" | sort -u); then
            echo "error: failed to parse failing-test results: $FAILING_RESULTS_FILE" >&2
            exit 1
        fi
        if [[ -z "$FAILING_CLASSES" ]]; then
            echo "error: no failing Holoscape UI test classes found in $FAILING_RESULTS_FILE" >&2
            exit 1
        fi
        args=""
        for class in $FAILING_CLASSES; do
            args="$args -only-testing:HoloscapeUITests/$class"
        done
        failing_bundle="$RESULTS_DIR/failing.xcresult"
        rm -rf "$failing_bundle"
        failing_output="$RESULTS_DIR/failing-only.txt"
        set +e
        "$TIMEOUT_RUNNER" "$UI_TEST_TIMEOUT_SECONDS" xcodebuild test \
            -scheme "$SCHEME" \
            -destination "$DEST" \
            -skipPackagePluginValidation \
            -resultBundlePath "$failing_bundle" \
            $args \
            2>&1 | tee "$failing_output" | grep -E "Test Case.*passed|Test Case.*failed|Executed|TEST|error: command timed out"
        failing_pipeline_status=("${PIPESTATUS[@]}")
        set -e
        failing_output_status=0
        "$TEST_OUTPUT_VALIDATOR" "$failing_output" || failing_output_status=$?
        echo "  Bundle:  $failing_bundle"
        if [ "${failing_pipeline_status[0]}" -ne 0 ] || [ "${failing_pipeline_status[1]}" -ne 0 ] || [ "${failing_pipeline_status[2]}" -gt 1 ] || [ "$failing_output_status" -ne 0 ]; then
            exit 1
        fi
        ;;
    *-*)
        # Range like 3-5
        if ! [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]; then
            echo "error: shard range must contain two numeric bounds: $1" >&2
            exit 2
        fi
        start=$((10#${1%-*}))
        end=$((10#${1#*-}))
        if (( start < 1 || start > 10 || end < 1 || end > 10 || start > end )); then
            echo "error: shard range must be ascending and within 1 through 10: $1" >&2
            exit 2
        fi
        overall_status=0
        for i in $(seq "$start" "$end"); do
            run_shard "$i" || overall_status=1
        done
        print_summary
        exit "$overall_status"
        ;;
    *)
        # Single shard number
        if ! [[ "$1" =~ ^[0-9]+$ ]]; then
            echo "error: shard number must be numeric: $1" >&2
            exit 2
        fi
        shard_number=$((10#$1))
        if (( shard_number < 1 || shard_number > 10 )); then
            echo "error: shard number must be from 1 through 10: $1" >&2
            exit 2
        fi
        run_shard "$shard_number"
        ;;
esac
