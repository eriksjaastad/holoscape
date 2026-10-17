#!/bin/bash
# UI Test Shard Runner for Holoscape
# Splits the UI test classes across 10 balanced shards.
# Usage:
#   ./scripts/test-ui-shards.sh              # Run all shards sequentially
#   ./scripts/test-ui-shards.sh 3            # Run shard 3 only
#   ./scripts/test-ui-shards.sh 3-5          # Run shards 3 through 5
#   ./scripts/test-ui-shards.sh fast         # Run core UI smoke tests
#   ./scripts/test-ui-shards.sh notifications # Run notification UI tests
#   HOLOSCAPE_UI_FAILING_RESULTS_FILE=path ./scripts/test-ui-shards.sh failing
#                                           # Run classes failed in that log
#   ./scripts/test-ui-shards.sh resume       # Resume from last failed shard
# Results default to /tmp/holoscape-test-shards/shard-{1..10}.{txt,xcresult}.
# Override the results directory with HOLOSCAPE_UI_TEST_RESULTS_DIR.
# Override the one-hour xcodebuild limit with UI_TEST_TIMEOUT_SECONDS.
# Failing mode requires HOLOSCAPE_UI_FAILING_RESULTS_FILE to name its source log.
# UI execution requires macOS Accessibility/Automation permission for the runner.
# Each build-for-testing re-signs the runner and can require TCC re-approval.

set -euo pipefail

SCHEME="Holoscape"
DEST="platform=macOS"
RESULTS_DIR="${HOLOSCAPE_UI_TEST_RESULTS_DIR:-/tmp/holoscape-test-shards}"
RESUME_FILE="$RESULTS_DIR/last-failed-shard"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_RUNNER="$SCRIPT_DIR/run-with-timeout.py"
TEST_OUTPUT_VALIDATOR="$SCRIPT_DIR/validate-xcode-test-output.sh"
UI_TEST_TIMEOUT_SECONDS="${UI_TEST_TIMEOUT_SECONDS:-3600}"
FAILING_RESULTS_FILE="${HOLOSCAPE_UI_FAILING_RESULTS_FILE:-}"

mkdir -p "$RESULTS_DIR"
declare -a SHARD_RUN_STATUS=()
declare -a SHARD_RUN_PASSED=()
declare -a SHARD_RUN_FAILED=()
ACTIVE_TIMEOUT_PID=""
INTERRUPTED_STATUS=0

forward_active_signal() {
    local signal_name="$1"
    local status="$2"
    INTERRUPTED_STATUS="$status"
    if [[ -n "$ACTIVE_TIMEOUT_PID" ]] && kill -0 "$ACTIVE_TIMEOUT_PID" 2>/dev/null; then
        kill -"$signal_name" "$ACTIVE_TIMEOUT_PID" 2>/dev/null || true
    fi
}

trap 'forward_active_signal HUP 129' HUP
trap 'forward_active_signal INT 130' INT
trap 'forward_active_signal TERM 143' TERM

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
    if [[ ! -e "$RESUME_FILE" ]]; then
        if ! printf '%s\n' "$n" > "$RESUME_FILE"; then
            echo "error: cannot record failed shard resume point: $RESUME_FILE" >&2
            recording_failed=1
        fi
    fi
    return "$recording_failed"
}

reset_resume_state() {
    if ! rm -f "$RESUME_FILE"; then
        echo "error: cannot clear prior shard resume point: $RESUME_FILE" >&2
        return 1
    fi
}

# Balanced shards with heavy classes spread across shards.
SHARD_1="IntegrityUITests"
SHARD_2="KeyboardShortcutsUITests WindowManagementUITests"
SHARD_3="StressUITests ThemeSwitchingUITests"
SHARD_4="GroupChatChannelUITests SettingsUITests SessionLauncherUITests"
SHARD_5="FontSettingsUITests EditMenuUITests ContextMenuUITests"
SHARD_6="BugReportUITests HTTPAPIUITests TransparencyColorWellUITests"
SHARD_7="HoloscapeUITests TabBarUITests SplitPaneAdvancedUITests InputBoxUITests"
SHARD_8="ChannelOrderingUITests AgentChannelUITests SplitPaneUITests CloseConfirmationUITests"
SHARD_9="BridgeChannelUITests TerminalInputUITests TabBehaviorUITests SidebarUITests ShaderVisualTests"
SHARD_10="URLSchemeUITests TerminalDisplayUITests SSHChannelUITests NotificationSystemUITests TimestampToggleUITests SkinEngineUITests ConfigPersistenceUITests ChannelStateIndicatorUITests ChannelRestorationUITests NotificationUITests DirectoryPersistenceUITests"

get_shard() {
    local n=$1
    local var="SHARD_${n}"
    echo "${!var}"
}

is_terminal_status() {
    case "$1" in
        125|129|130|143) return 0 ;;
        *) return 1 ;;
    esac
}

run_selected_tests() {
    local label="$1"
    local output="$2"
    local bundle="$3"
    shift 3

    if ! rm -rf "$bundle"; then
        echo "error: cannot remove prior result bundle: $bundle" >&2
        return 1
    fi
    local pipeline_fifo="$RESULTS_DIR/.xcodebuild-output.$$.$RANDOM"
    local pipeline_status="$RESULTS_DIR/.xcodebuild-status.$$.$RANDOM"
    if ! mkfifo "$pipeline_fifo"; then
        echo "error: cannot create xcodebuild output pipe: $pipeline_fifo" >&2
        return 1
    fi
    set +e
    (
        set +e
        tee "$output" <"$pipeline_fifo" | grep -E "Test Case.*(passed|failed|skipped)|Executed|TEST|error: command timed out"
        local_status=("${PIPESTATUS[@]}")
        printf '%s %s\n' "${local_status[0]}" "${local_status[1]}" >"$pipeline_status"
    ) &
    local filter_pid=$!
    "$TIMEOUT_RUNNER" "$UI_TEST_TIMEOUT_SECONDS" xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DEST" \
        -skipPackagePluginValidation \
        -resultBundlePath "$bundle" \
        "$@" \
        >"$pipeline_fifo" 2>&1 &
    ACTIVE_TIMEOUT_PID=$!
    wait "$ACTIVE_TIMEOUT_PID"
    local command_status=$?
    wait "$filter_pid"
    local filter_status=$?
    ACTIVE_TIMEOUT_PID=""
    set -e
    local tee_status=1
    local grep_status=1
    if [[ -r "$pipeline_status" ]]; then
        read -r tee_status grep_status <"$pipeline_status"
    fi
    local cleanup_status=0
    rm -f "$pipeline_fifo" "$pipeline_status" || cleanup_status=$?
    if [[ "$cleanup_status" -ne 0 ]]; then
        echo "error: cannot remove xcodebuild pipeline artifacts" >&2
        return "$cleanup_status"
    fi
    local output_status=0
    "$TEST_OUTPUT_VALIDATOR" "$output" || output_status=$?
    echo "  $label bundle: $bundle"
    if [[ "$command_status" -eq 125 ]]; then
        INTERRUPTED_STATUS=0
        return 125
    fi
    if [[ "$INTERRUPTED_STATUS" -ne 0 ]]; then
        local interrupted_status="$INTERRUPTED_STATUS"
        INTERRUPTED_STATUS=0
        return "$interrupted_status"
    fi
    if [[ "$command_status" -ne 0 ]]; then
        return "$command_status"
    fi
    if [[ "$filter_status" -ne 0 ]] || [[ "$tee_status" -ne 0 ]] || [[ "$grep_status" -gt 1 ]] || [[ "$output_status" -ne 0 ]]; then
        return 1
    fi
}

run_shard() {
    local n=$1
    local classes=$(get_shard "$n")
    local args=()

    for class in $classes; do
        args+=("-only-testing:HoloscapeUITests/$class")
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

    local command_status=0
    run_selected_tests "Shard $n" "$outfile" "$bundle" "${args[@]}" || command_status=$?

    local passed=0
    local failed=0
    local count_status=0
    passed=$(count_matches "^Test Case .* passed" "$outfile") || count_status=$?
    if [[ "$count_status" -eq 0 ]]; then
        failed=$(count_matches "^Test Case .* failed" "$outfile") || count_status=$?
    fi
    SHARD_RUN_PASSED[$n]="$passed"
    SHARD_RUN_FAILED[$n]="$failed"

    echo ""
    echo "  Shard $n: $passed passed, $failed failed"
    echo "  Results: $outfile"

    if [ "$command_status" -ne 0 ] || [ "$count_status" -ne 0 ] || [ "$failed" -gt 0 ]; then
        record_failed_shard "$n" "$status_file" || true
        if is_terminal_status "$command_status"; then
            return "$command_status"
        fi
        if [ "$count_status" -ne 0 ]; then
            return "$count_status"
        fi
        if [ "$command_status" -ne 0 ]; then
            return "$command_status"
        fi
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
        if [[ -n "${SHARD_RUN_STATUS[$i]+set}" ]]; then
            local p
            local f
            p="${SHARD_RUN_PASSED[$i]}"
            f="${SHARD_RUN_FAILED[$i]}"
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
            local status="${SHARD_RUN_STATUS[$i]}"
            printf "  Shard %2d: %3d passed, %3d failed  [%s]\n" "$i" "$p" "$f" "$status"
        else
            printf "  Shard %2d: not run\n" "$i"
        fi
    done

    echo "  ------------------------------------------"
    printf "  TOTAL:    %3d passed, %3d failed\n" "$total_passed" "$total_failed"
    echo ""
}

# Parse arguments. No argument means all shards; an explicitly empty selection is invalid.
if (( $# > 1 )); then
    echo "error: expected at most one shard selection" >&2
    exit 2
fi
selection="${1-all}"
if [[ -z "$selection" ]]; then
    echo "error: shard selection must not be empty" >&2
    exit 2
fi

case "$selection" in
    all)
        overall_status=0
        reset_resume_state || exit $?
        for (( i=1; i<=10; i++ )); do
            if run_shard "$i"; then
                :
            else
                shard_status=$?
                if is_terminal_status "$shard_status"; then
                    exit "$shard_status"
                fi
                overall_status=1
            fi
        done
        print_summary
        exit "$overall_status"
        ;;
    resume)
        overall_status=0
        if [ -f "$RESUME_FILE" ]; then
            start=$(<"$RESUME_FILE")
            if ! [[ "$start" =~ ^([1-9]|10)$ ]]; then
                echo "error: invalid shard resume point in $RESUME_FILE: $start" >&2
                exit 2
            fi
            reset_resume_state || exit $?
            echo "Resuming from shard $start"
            for (( i=start; i<=10; i++ )); do
                if run_shard "$i"; then
                    :
                else
                    shard_status=$?
                    if is_terminal_status "$shard_status"; then
                        exit "$shard_status"
                    fi
                    overall_status=1
                fi
            done
        else
            reset_resume_state || exit $?
            echo "No resume point found. Run all."
            for (( i=1; i<=10; i++ )); do
                if run_shard "$i"; then
                    :
                else
                    shard_status=$?
                    if is_terminal_status "$shard_status"; then
                        exit "$shard_status"
                    fi
                    overall_status=1
                fi
            done
        fi
        print_summary
        exit "$overall_status"
        ;;
    failing)
        echo "Running only currently-failing test classes..."
        if [[ -z "$FAILING_RESULTS_FILE" ]]; then
            echo "error: HOLOSCAPE_UI_FAILING_RESULTS_FILE must name the xcodebuild log to inspect" >&2
            exit 2
        fi
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
        args=()
        for class in $FAILING_CLASSES; do
            args+=("-only-testing:HoloscapeUITests/$class")
        done
        failing_bundle="$RESULTS_DIR/failing.xcresult"
        failing_output="$RESULTS_DIR/failing-only.txt"
        run_selected_tests "Failing tests" "$failing_output" "$failing_bundle" "${args[@]}"
        ;;
    fast)
        run_selected_tests "Fast UI tests" \
            "$RESULTS_DIR/fast.txt" "$RESULTS_DIR/fast.xcresult" \
            -only-testing:HoloscapeUITests/HoloscapeUITests \
            -only-testing:HoloscapeUITests/SettingsUITests \
            -only-testing:HoloscapeUITests/TerminalDisplayUITests \
            -only-testing:HoloscapeUITests/SidebarUITests \
            -only-testing:HoloscapeUITests/KeyboardShortcutsUITests
        ;;
    notifications)
        run_selected_tests "Notification UI tests" \
            "$RESULTS_DIR/notifications.txt" "$RESULTS_DIR/notifications.xcresult" \
            -only-testing:HoloscapeUITests/NotificationSystemUITests
        ;;
    *-*)
        # Range like 3-5
        if ! [[ "$selection" =~ ^([1-9]|10)-([1-9]|10)$ ]]; then
            echo "error: shard range bounds must each be from 1 through 10: $1" >&2
            exit 2
        fi
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        if (( start > end )); then
            echo "error: shard range must be ascending and within 1 through 10: $1" >&2
            exit 2
        fi
        overall_status=0
        reset_resume_state || exit $?
        for (( i=start; i<=end; i++ )); do
            if run_shard "$i"; then
                :
            else
                shard_status=$?
                if is_terminal_status "$shard_status"; then
                    exit "$shard_status"
                fi
                overall_status=1
            fi
        done
        print_summary
        exit "$overall_status"
        ;;
    *)
        # Single shard number
        if ! [[ "$selection" =~ ^([1-9]|10)$ ]]; then
            echo "error: shard number must be from 1 through 10: $1" >&2
            exit 2
        fi
        reset_resume_state || exit $?
        run_shard "$selection"
        ;;
esac
