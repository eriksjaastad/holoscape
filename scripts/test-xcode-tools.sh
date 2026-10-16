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
else:
    raise SystemExit(f"unknown mutation: {mode}")

destination.write_text(source[:start] + phase + source[end:])
PY
}

for mutation in missing stale; do
    mutated_project="$work_dir/$mutation.pbxproj"
    mutate_source_phase "$project" "$mutated_project" "$mutation"
    if "$validator" "$mutated_project" >"$work_dir/$mutation.out" 2>&1; then
        echo "error: Xcode validator accepted a $mutation unit-test source phase" >&2
        exit 1
    fi
done

mkdir -p "$work_dir/bin"
cat >"$work_dir/bin/xcodebuild" <<'EOF'
#!/bin/bash
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

echo "validated Xcode project drift detection and UI shard failure propagation"
