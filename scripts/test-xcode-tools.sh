#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
validator="$script_dir/validate-xcode-project.sh"
project="$repo_root/Holoscape.xcodeproj/project.pbxproj"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/holoscape-xcode-tools-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

"$validator" "$project" >/dev/null

mutate_project() {
    local source="$1"
    local destination="$2"
    local mode="$3"

    python3 - "$source" "$destination" "$mode" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
destination = Path(sys.argv[2])
mode = sys.argv[3]
phase_id = "588AC30E0A325E0EC23904A2"
start = source.index(f"\t\t{phase_id} /* Sources */ = {{")
end = source.index("\t\t};", start)
phase = source[start:end]

if mode == "missing":
    needle = next(line for line in phase.splitlines(True) if "AgentStatusNotificationRoutingTests.swift in Sources" in line)
    phase = phase.replace(needle, "", 1)
elif mode == "stale":
    marker = "\t\t\t);\n"
    phase = phase.replace(marker, "\t\t\t\tFFFFFFFFFFFFFFFFFFFFFFFF /* StaleSource.swift in Sources */,\n" + marker, 1)
elif mode == "moved":
    source = source.replace(
        "path = AgentStatusNotificationRoutingTests.swift;",
        "path = Legacy/AgentStatusNotificationRoutingTests.swift;",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "target-config":
    source = source.replace(
        "buildConfigurationList = 95F26503BABD4AD324729427 /* Build configuration list for PBXNativeTarget \"CNativePTY\" */;",
        "buildConfigurationList = FFFFFFFFFFFFFFFFFFFFFFFF /* stale CNativePTY configuration list */;",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "target-product":
    source = source.replace(
        "productReference = C8599FAC0805093E678DF085 /* libCNativePTY.a */;",
        "productReference = 212041D5FDF1C8CE4CA3DEA1 /* libCglslang.a */;",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "target-membership":
    source = source.replace(
        "\t\t\t\t6C329224BFDF298222AD54F2 /* CNativePTY */,\n",
        "",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "link-edge":
    source = source.replace(
        "33BBD496CD920CD4B74477AF /* libCNativePTY.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C8599FAC0805093E678DF085 /* libCNativePTY.a */; };",
        "33BBD496CD920CD4B74477AF /* libCNativePTY.a in Frameworks */ = {isa = PBXBuildFile; fileRef = 212041D5FDF1C8CE4CA3DEA1 /* libCglslang.a */; };",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "native-path":
    source = source.replace(
        "path = HoloscapeNativePTY.c;",
        "path = Legacy/HoloscapeNativePTY.c;",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
elif mode == "proxy-target":
    source = source.replace(
        "remoteGlobalIDString = 6C329224BFDF298222AD54F2;",
        "remoteGlobalIDString = 86341C541EA4BEB72A8EABF5;",
        1,
    )
    destination.write_text(source)
    raise SystemExit(0)
else:
    raise SystemExit(f"unknown mutation: {mode}")

destination.write_text(source[:start] + phase + source[end:])
PY
}

for mutation in missing stale moved target-config target-product target-membership link-edge native-path proxy-target; do
    mutated_project="$work_dir/$mutation.pbxproj"
    mutate_project "$project" "$mutated_project" "$mutation"
    if "$validator" "$mutated_project" >"$work_dir/$mutation.out" 2>&1; then
        echo "error: Xcode validator accepted the $mutation project mutation" >&2
        exit 1
    fi
done
if ! grep -q '^+Tests/HoloscapeTests/Unit/Legacy/AgentStatusNotificationRoutingTests.swift$' "$work_dir/moved.out"; then
    echo "error: moved-source regression did not compare the resolved stale path" >&2
    cat "$work_dir/moved.out" >&2
    exit 1
fi
if make -n -C "$repo_root" clean | grep -q 'Holoscape\.xcodeproj'; then
    echo "error: make clean still removes the checked-in Xcode project" >&2
    exit 1
fi
if make -n -C "$repo_root" xcode | grep -q 'generate-xcodeproj'; then
    echo "error: make xcode still regenerates the authoritative checked-in project" >&2
    exit 1
fi

mkdir -p "$work_dir/bin"
cat >"$work_dir/bin/xcodebuild" <<'EOF'
#!/bin/bash
if [[ -n "${FAKE_STATUS_PATH:-}" ]]; then
    mkdir -p "$FAKE_STATUS_PATH"
fi
if [[ -n "${FAKE_SLEEP_SECONDS:-}" ]]; then
    sleep "$FAKE_SLEEP_SECONDS"
fi
echo "** TEST FAILED **"
exit 42
EOF
chmod +x "$work_dir/bin/xcodebuild"
cp "$script_dir/test-ui-shards.sh" "$work_dir/test-ui-shards.sh"
cp "$script_dir/run-with-timeout.py" "$work_dir/run-with-timeout.py"
chmod +x "$work_dir/run-with-timeout.py"
python3 - "$work_dir/test-ui-shards.sh" "$work_dir/results" <<'PY'
from pathlib import Path
import sys

script = Path(sys.argv[1])
text = script.read_text()
text = text.replace('RESULTS_DIR="/tmp/holoscape-test-shards"', f'RESULTS_DIR="{sys.argv[2]}"')
script.write_text(text)
PY

if PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" 1-2 >"$work_dir/shards.out" 2>&1; then
    echo "error: aggregate UI shards hid an xcodebuild failure" >&2
    exit 1
fi
if [[ $(grep -c '\[FAIL\]' "$work_dir/shards.out") -ne 2 ]] || grep -q '\[OK\]' "$work_dir/shards.out"; then
    echo "error: aggregate UI shard summary did not report both failed shards truthfully" >&2
    cat "$work_dir/shards.out" >&2
    exit 1
fi

python3 - "$work_dir/test-ui-shards.sh" "$work_dir/single-results" <<'PY'
from pathlib import Path
import re
import sys

script = Path(sys.argv[1])
text = script.read_text()
text, count = re.subn(
    r'^RESULTS_DIR="[^"]*"$',
    f'RESULTS_DIR="{sys.argv[2]}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("failed to redirect single-shard results")
script.write_text(text)
PY
if PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" 1 >"$work_dir/single.out" 2>&1; then
    echo "error: single UI shard hid an xcodebuild failure" >&2
    exit 1
fi
if [[ $(<"$work_dir/single-results/shard-1.status") != "FAIL" ]] || \
   [[ $(<"$work_dir/single-results/last-failed-shard") != "1" ]]; then
    echo "error: single UI shard did not record failure and resume state" >&2
    exit 1
fi

status_path="$work_dir/single-results/shard-1.status"
if FAKE_STATUS_PATH="$status_path" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1 >"$work_dir/status-write.out" 2>&1; then
    echo "error: UI shard accepted a failed status write" >&2
    exit 1
fi
if ! grep -q 'cannot record failed shard status' "$work_dir/status-write.out"; then
    echo "error: failed UI shard status write lacked a diagnostic" >&2
    cat "$work_dir/status-write.out" >&2
    exit 1
fi

/bin/rm -rf "$status_path"
printf 'PASS\n' >"$status_path"
cat >"$work_dir/single-results/shard-1.txt" <<'EOF'
Test Case '-[SyntheticUITests testExample]' passed (0.001 seconds).
Test Suite 'SyntheticUITests' passed at 2026-10-16 00:00:00.000.
Test Suite 'Selected tests' passed at 2026-10-16 00:00:00.000.
Test Suite 'All tests' passed at 2026-10-16 00:00:00.000.
EOF
bundle_path="$work_dir/single-results/shard-1.xcresult"
mkdir -p "$bundle_path"
cat >"$work_dir/bin/rm" <<'EOF'
#!/bin/bash
for argument in "$@"; do
    if [[ -n "${FAKE_RM_FAIL_PATH:-}" && "$argument" == "$FAKE_RM_FAIL_PATH" ]]; then
        echo "synthetic rm failure: $argument" >&2
        exit 73
    fi
done
exec /bin/rm "$@"
EOF
chmod +x "$work_dir/bin/rm"
if FAKE_RM_FAIL_PATH="$bundle_path" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1-1 >"$work_dir/cleanup.out" 2>&1; then
    echo "error: UI shard accepted result-bundle cleanup failure" >&2
    exit 1
fi
if ! grep -Eq 'Shard[[:space:]]+1:.*0 passed,.*0 failed.*\[FAIL\]' "$work_dir/cleanup.out" || \
   grep -Eq 'Shard[[:space:]]+1:.*\[PASS\]' "$work_dir/cleanup.out"; then
    echo "error: UI shard cleanup failure reused a stale PASS status" >&2
    cat "$work_dir/cleanup.out" >&2
    exit 1
fi

/bin/rm -rf "$bundle_path" "$status_path"
if FAKE_SLEEP_SECONDS=2 HOLOSCAPE_UI_TEST_TIMEOUT_SECONDS=0.1 PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1 >"$work_dir/timeout.out" 2>&1; then
    echo "error: UI shard accepted a timed-out xcodebuild" >&2
    exit 1
fi
if ! grep -q 'command timed out after 0.1 seconds: xcodebuild' "$work_dir/timeout.out" || \
   [[ $(<"$status_path") != "FAIL" ]]; then
    echo "error: UI shard timeout was not reported and recorded as failure" >&2
    cat "$work_dir/timeout.out" >&2
    exit 1
fi

definitions="$work_dir/test-ui-shard-definitions.sh"
sed -n '/^count_matches() {$/,/^# Parse arguments$/p' "$work_dir/test-ui-shards.sh" | sed '$d' >"$definitions"
if ! RESULTS_DIR="$work_dir/count-results" bash -c '
    source "$1"
    mkdir -p "$RESULTS_DIR"
    cat >"$RESULTS_DIR/shard-1.txt" <<EOF
Test Case SyntheticUITests.testPass passed (0.001 seconds).
Test Case SyntheticUITests.testFail failed (0.001 seconds).
Test Suite SyntheticUITests passed at 2026-10-16 00:00:00.000.
Test Suite Selected tests failed at 2026-10-16 00:00:00.000.
EOF
    printf "FAIL\n" >"$RESULTS_DIR/shard-1.status"
    print_summary
' _ "$definitions" >"$work_dir/count.out" 2>&1; then
    echo "error: aggregate UI shard summary failed for XCTest-style output" >&2
    cat "$work_dir/count.out" >&2
    exit 1
fi
if ! grep -Eq 'Shard[[:space:]]+1:.*1 passed,.*1 failed.*\[FAIL\]' "$work_dir/count.out"; then
    echo "error: aggregate UI shard summary counted XCTest suite lines as test cases" >&2
    cat "$work_dir/count.out" >&2
    exit 1
fi
if ! RESULTS_DIR="$work_dir/unreadable-results" bash -c '
    source "$1"
    mkdir -p "$RESULTS_DIR"
    printf "Test Case SyntheticUITests.testExample passed (0.001 seconds).\n" >"$RESULTS_DIR/shard-1.txt"
    chmod 000 "$RESULTS_DIR/shard-1.txt"
    print_summary
' _ "$definitions" >"$work_dir/unreadable.out" 2>&1; then
    if ! grep -q 'cannot read test output' "$work_dir/unreadable.out"; then
        echo "error: unreadable UI shard output failed without a diagnostic" >&2
        cat "$work_dir/unreadable.out" >&2
        exit 1
    fi
else
    echo "error: aggregate UI shard summary accepted unreadable output" >&2
    exit 1
fi

echo "validated Xcode project drift detection and UI shard failure propagation"
