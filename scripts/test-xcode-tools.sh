#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
validator="$script_dir/validate-xcode-project.sh"
project="$repo_root/Holoscape.xcodeproj/project.pbxproj"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/holoscape-xcode-tools-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

"$validator" "$project" >/dev/null

mutate_source_phase() {
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
else:
    raise SystemExit(f"unknown mutation: {mode}")

destination.write_text(source[:start] + phase + source[end:])
PY
}

for mutation in missing stale moved; do
    mutated_project="$work_dir/$mutation.pbxproj"
    mutate_source_phase "$project" "$mutated_project" "$mutation"
    if "$validator" "$mutated_project" >"$work_dir/$mutation.out" 2>&1; then
        echo "error: Xcode validator accepted a $mutation unit-test source phase" >&2
        exit 1
    fi
done
if ! grep -q '^+Tests/HoloscapeTests/Unit/Legacy/AgentStatusNotificationRoutingTests.swift$' "$work_dir/moved.out"; then
    echo "error: moved-source regression did not compare the resolved stale path" >&2
    cat "$work_dir/moved.out" >&2
    exit 1
fi

mkdir -p "$work_dir/bin"
cat >"$work_dir/bin/xcodebuild" <<'EOF'
#!/bin/bash
if [[ -n "${FAKE_STATUS_PATH:-}" ]]; then
    mkdir -p "$FAKE_STATUS_PATH"
fi
echo "** TEST FAILED **"
exit 42
EOF
chmod +x "$work_dir/bin/xcodebuild"
cp "$script_dir/test-ui-shards.sh" "$work_dir/test-ui-shards.sh"
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

definitions="$work_dir/test-ui-shard-definitions.sh"
sed -n '20,/^# Parse arguments$/p' "$work_dir/test-ui-shards.sh" | sed '$d' >"$definitions"
if ! RESULTS_DIR="$work_dir/unreadable-results" bash -c '
    source "$1"
    mkdir -p "$RESULTS_DIR"
    printf "Test Case passed\n" >"$RESULTS_DIR/shard-1.txt"
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
