#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
validator="$script_dir/validate-xcode-project.sh"
project="$repo_root/Holoscape.xcodeproj/project.pbxproj"
scheme="$repo_root/Holoscape.xcodeproj/xcshareddata/xcschemes/Holoscape.xcscheme"
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
elif mode.startswith("source-phase-membership-"):
    target = mode.removeprefix("source-phase-membership-")
    phases = {
        "app": "DBDABAE51D6625081EA3C33F",
        "unit": "588AC30E0A325E0EC23904A2",
        "property": "D667E382F8A6AB7B28F95FC5",
        "ui": "DF2F634F7655E0873CBF64BB",
    }
    source = source.replace(
        f"\t\t\t\t{phases[target]} /* Sources */,\n",
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

for mutation in missing stale moved target-config target-product target-membership \
    source-phase-membership-app source-phase-membership-unit \
    source-phase-membership-property source-phase-membership-ui \
    link-edge native-path proxy-target; do
    mutated_project="$work_dir/$mutation.pbxproj"
    mutate_project "$project" "$mutated_project" "$mutation"
    if "$validator" "$mutated_project" >"$work_dir/$mutation.out" 2>&1; then
        echo "error: Xcode validator accepted the $mutation project mutation" >&2
        exit 1
    fi
    if [[ "$mutation" == source-phase-membership-* ]] && \
       ! grep -q 'source phase' "$work_dir/$mutation.out"; then
        echo "error: $mutation failed without the expected source-phase diagnostic" >&2
        cat "$work_dir/$mutation.out" >&2
        exit 1
    fi
done
mutate_scheme() {
    local destination="$1"
    local mode="$2"

    python3 - "$scheme" "$destination" "$mode" <<'PY'
import sys
import xml.etree.ElementTree as ET

source, destination, mode = sys.argv[1:]
tree = ET.parse(source)
root = tree.getroot()
testables = root.find("./TestAction/Testables")
if testables is None:
    raise SystemExit("expected shared scheme test entries")
entries = {
    buildable.get("BlueprintName"): (testable, buildable)
    for testable in testables.findall("TestableReference")
    if (buildable := testable.find("BuildableReference")) is not None
}

if mode == "missing-property":
    testables.remove(entries["HoloscapePropertyTests"][0])
elif mode == "property-blueprint":
    entries["HoloscapePropertyTests"][1].set("BlueprintIdentifier", "FFFFFFFFFFFFFFFFFFFFFFFF")
elif mode == "property-skipped":
    entries["HoloscapePropertyTests"][0].set("skipped", "YES")
elif mode == "property-buildable":
    entries["HoloscapePropertyTests"][1].set("BuildableName", "HoloscapeTests.xctest")
elif mode == "property-container":
    entries["HoloscapePropertyTests"][1].set("ReferencedContainer", "container:Other.xcodeproj")
elif mode == "unit-blueprint":
    entries["HoloscapeTests"][1].set("BlueprintIdentifier", "FFFFFFFFFFFFFFFFFFFFFFFF")
elif mode == "unit-skipped":
    entries["HoloscapeTests"][0].set("skipped", "YES")
elif mode == "unit-buildable":
    entries["HoloscapeTests"][1].set("BuildableName", "HoloscapePropertyTests.xctest")
elif mode == "unit-container":
    entries["HoloscapeTests"][1].set("ReferencedContainer", "container:Other.xcodeproj")
elif mode == "unit-selected-tests":
    ET.SubElement(entries["HoloscapeTests"][0], "SelectedTests")
elif mode == "ui-blueprint":
    entries["HoloscapeUITests"][1].set("BlueprintIdentifier", "FFFFFFFFFFFFFFFFFFFFFFFF")
elif mode == "ui-skipped":
    entries["HoloscapeUITests"][0].set("skipped", "YES")
elif mode == "ui-buildable":
    entries["HoloscapeUITests"][1].set("BuildableName", "HoloscapeTests.xctest")
elif mode == "ui-container":
    entries["HoloscapeUITests"][1].set("ReferencedContainer", "container:Other.xcodeproj")
elif mode == "ui-skipped-tests":
    ET.SubElement(entries["HoloscapeUITests"][0], "SkippedTests")
elif mode == "ui-membership":
    testables.remove(entries["HoloscapeUITests"][0])
elif mode == "duplicate-unit":
    testables.append(ET.fromstring(ET.tostring(entries["HoloscapeTests"][0])))
elif mode == "extra-entry":
    extra = ET.fromstring(ET.tostring(entries["HoloscapeTests"][0]))
    extra.find("BuildableReference").set("BlueprintName", "UnexpectedTests")
    testables.append(extra)
else:
    raise SystemExit(f"unknown scheme mutation: {mode}")

tree.write(destination, encoding="UTF-8", xml_declaration=True)
PY
}

for mutation in missing-property property-blueprint property-skipped property-buildable property-container \
    unit-blueprint unit-skipped unit-buildable unit-container unit-selected-tests \
    ui-blueprint ui-skipped ui-buildable ui-container ui-skipped-tests ui-membership \
    duplicate-unit extra-entry; do
    mutated_scheme="$work_dir/$mutation.xcscheme"
    mutate_scheme "$mutated_scheme" "$mutation"
    if "$validator" "$project" "$mutated_scheme" >"$work_dir/$mutation.out" 2>&1; then
        echo "error: Xcode validator accepted the $mutation scheme mutation" >&2
        exit 1
    fi
    expected_diagnostic='must contain exactly'
    case "$mutation" in
        property-*) expected_diagnostic='invalid HoloscapePropertyTests test entry' ;;
        unit-*) expected_diagnostic='invalid HoloscapeTests test entry' ;;
        ui-blueprint|ui-skipped|ui-buildable|ui-container|ui-skipped-tests) expected_diagnostic='invalid HoloscapeUITests test entry' ;;
        duplicate-unit) expected_diagnostic='missing or duplicate test target name' ;;
    esac
    if ! grep -q "$expected_diagnostic" "$work_dir/$mutation.out"; then
        echo "error: the $mutation scheme mutation failed for the wrong reason" >&2
        cat "$work_dir/$mutation.out" >&2
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
if [[ -n "${FAKE_INVOCATION_LOG:-}" ]]; then
    printf 'invoked\n' >>"$FAKE_INVOCATION_LOG"
fi
if [[ -n "${FAKE_PID_PATH:-}" ]]; then
    printf '%s\n' "$$" >"$FAKE_PID_PATH"
fi
if [[ -n "${FAKE_SIGNAL_PATH:-}" ]]; then
    trap 'printf TERM >"$FAKE_SIGNAL_PATH"; exit 143' TERM
fi
if [[ -n "${FAKE_SLEEP_SECONDS:-}" ]]; then
    sleep "$FAKE_SLEEP_SECONDS"
fi
if [[ -n "${FAKE_EXIT_STATUS:-}" ]]; then
    exit "$FAKE_EXIT_STATUS"
fi
if [[ -n "${FAKE_REQUIRE_ARGUMENT:-}" ]]; then
    found_argument=0
    for argument in "$@"; do
        if [[ "$argument" == "$FAKE_REQUIRE_ARGUMENT" ]]; then
            found_argument=1
            break
        fi
    done
    if [[ "$found_argument" -ne 1 ]]; then
        echo "missing required synthetic argument: $FAKE_REQUIRE_ARGUMENT" >&2
        exit 64
    fi
fi
if [[ -n "${FAKE_SUCCESS_NO_TESTS:-}" ]]; then
    echo "** TEST SUCCEEDED **"
    exit 0
fi
if [[ -n "${FAKE_SUCCESS_ONE_TEST:-}" ]]; then
    echo "Test Case '-[SyntheticUITests testExample]' passed (0.001 seconds)."
    echo "** TEST SUCCEEDED **"
    exit 0
fi
if [[ -n "${FAKE_SUCCESS_SKIPPED_TEST:-}" ]]; then
    echo "Test Case '-[SyntheticUITests testExample]' skipped (0.001 seconds)."
    echo "** TEST SUCCEEDED **"
    exit 0
fi
echo "** TEST FAILED **"
exit 42
EOF
chmod +x "$work_dir/bin/xcodebuild"
cp "$script_dir/test-ui-shards.sh" "$work_dir/test-ui-shards.sh"
cp "$script_dir/run-with-timeout.py" "$work_dir/run-with-timeout.py"
cp "$script_dir/validate-xcode-test-output.sh" "$work_dir/validate-xcode-test-output.sh"
chmod +x "$work_dir/run-with-timeout.py" "$work_dir/validate-xcode-test-output.sh"
python3 - "$script_dir/test-ui-shards.sh" "$repo_root/Tests/HoloscapeUITests" <<'PY'
from collections import Counter
from pathlib import Path
import re
import sys

shard_script = Path(sys.argv[1]).read_text()
ui_test_root = Path(sys.argv[2])
selected = []
for match in re.finditer(r'^SHARD_[0-9]+="([^"]*)"', shard_script, re.MULTILINE):
    selected.extend(match.group(1).split())

compiled = []
class_pattern = re.compile(r'final class ([A-Za-z0-9_]+): HoloscapeUITestCase')
for source in ui_test_root.glob("*.swift"):
    compiled.extend(class_pattern.findall(source.read_text()))

selected_counts = Counter(selected)
compiled_counts = Counter(compiled)
if selected_counts != compiled_counts:
    missing = sorted((compiled_counts - selected_counts).elements())
    stale = sorted((selected_counts - compiled_counts).elements())
    raise SystemExit(
        f"UI shard class inventory differs from compiled tests; missing={missing}, stale={stale}"
    )
PY
python3 - "$work_dir/test-ui-shards.sh" "$work_dir/unexpected-default-results" <<'PY'
from pathlib import Path
import sys

script = Path(sys.argv[1])
text = script.read_text()
needle = 'RESULTS_DIR="${HOLOSCAPE_UI_TEST_RESULTS_DIR:-/tmp/holoscape-test-shards}"'
replacement = f'RESULTS_DIR="${{HOLOSCAPE_UI_TEST_RESULTS_DIR:-{sys.argv[2]}}}"'
if text.count(needle) != 1:
    raise SystemExit("expected one default UI results assignment")
script.write_text(text.replace(needle, replacement, 1))
PY

mkdir -p "$work_dir/results"
cat >"$work_dir/results/shard-10.txt" <<'EOF'
Test Case '-[SyntheticUITests staleTest]' passed (0.001 seconds).
EOF
printf 'PASS\n' >"$work_dir/results/shard-10.status"

if HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/results" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1-2 >"$work_dir/shards.out" 2>&1; then
    echo "error: aggregate UI shards hid an xcodebuild failure" >&2
    exit 1
fi
if [[ $(grep -c '\[FAIL\]' "$work_dir/shards.out") -ne 2 ]] || grep -q '\[OK\]' "$work_dir/shards.out"; then
    echo "error: aggregate UI shard summary did not report both failed shards truthfully" >&2
    cat "$work_dir/shards.out" >&2
    exit 1
fi
if [[ ! -f "$work_dir/results/shard-1.status" || ! -f "$work_dir/results/shard-2.status" || \
      -e "$work_dir/unexpected-default-results" ]]; then
    echo "error: aggregate UI shards did not honor the results-directory override" >&2
    exit 1
fi
if ! grep -Eq 'Shard[[:space:]]+10: not run' "$work_dir/shards.out" || \
   grep -q 'staleTest' "$work_dir/shards.out" || \
   ! grep -Eq 'TOTAL:[[:space:]]+0 passed,[[:space:]]+0 failed' "$work_dir/shards.out"; then
    echo "error: aggregate UI shard summary included stale results from an earlier invocation" >&2
    cat "$work_dir/shards.out" >&2
    exit 1
fi
if [[ $(<"$work_dir/results/last-failed-shard") != "1" ]]; then
    echo "error: aggregate UI shards did not preserve the earliest failed shard for resume" >&2
    exit 1
fi

if ! FAKE_SUCCESS_ONE_TEST=1 HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/results" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1-2 >"$work_dir/shards-clean.out" 2>&1; then
    echo "error: clean aggregate UI shard run failed" >&2
    cat "$work_dir/shards-clean.out" >&2
    exit 1
fi
if [[ -e "$work_dir/results/last-failed-shard" ]]; then
    echo "error: clean aggregate UI shard run retained a stale resume point" >&2
    exit 1
fi

export HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/single-results"
if HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/single-results" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1 >"$work_dir/single.out" 2>&1; then
    echo "error: single UI shard hid an xcodebuild failure" >&2
    exit 1
fi
if [[ $(<"$work_dir/single-results/shard-1.status") != "FAIL" ]] || \
   [[ $(<"$work_dir/single-results/last-failed-shard") != "1" ]]; then
    echo "error: single UI shard did not record failure and resume state" >&2
    exit 1
fi

status_path="$work_dir/single-results/shard-1.status"
if HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/single-results" FAKE_STATUS_PATH="$status_path" PATH="$work_dir/bin:$PATH" \
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
printf '7\n' >"$work_dir/single-results/last-failed-shard"
if HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/single-results" FAKE_RM_FAIL_PATH="$bundle_path" PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1-1 >"$work_dir/cleanup.out" 2>&1; then
    echo "error: UI shard accepted result-bundle cleanup failure" >&2
    exit 1
fi
if ! grep -Eq 'Shard[[:space:]]+1:.*0 passed,.*0 failed.*\[FAIL\]' "$work_dir/cleanup.out" || \
   grep -Eq 'Shard[[:space:]]+1:.*\[PASS\]' "$work_dir/cleanup.out" || \
   [[ $(<"$work_dir/single-results/last-failed-shard") != "1" ]] || \
   [[ $(<"$status_path") != "FAIL" ]]; then
    echo "error: UI shard cleanup failure reused stale status or resume state" >&2
    cat "$work_dir/cleanup.out" >&2
    exit 1
fi

for invalid_timeout in nan inf -inf; do
    if "$script_dir/run-with-timeout.py" "$invalid_timeout" /usr/bin/true \
       >"$work_dir/timeout-$invalid_timeout.out" 2>&1; then
        echo "error: timeout runner accepted non-finite timeout: $invalid_timeout" >&2
        exit 1
    fi
    if ! grep -q 'timeout must be a finite value greater than zero' \
       "$work_dir/timeout-$invalid_timeout.out"; then
        echo "error: non-finite timeout lacked a diagnostic: $invalid_timeout" >&2
        cat "$work_dir/timeout-$invalid_timeout.out" >&2
        exit 1
    fi
done

python3 - "$script_dir/run-with-timeout.py" <<'PY'
import importlib.util
import signal
import sys

module_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("run_with_timeout", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FakeProcess:
    pid = 43210
    args = ["synthetic-command"]

    def wait(self, timeout=None):
        raise KeyboardInterrupt

module.subprocess.Popen = lambda *args, **kwargs: FakeProcess()
module.os.killpg = lambda pid, sig: (_ for _ in ()).throw(PermissionError("denied"))
module.sys.argv = [module_path, "1", "synthetic-command"]
status = module.main()
if status != module.TERMINATION_FAILURE_EXIT_STATUS:
    raise SystemExit(f"cleanup signaling failure returned {status}, expected 125")

class ExitedProcess:
    pid = 43211
    args = ["synthetic-command"]

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0

def fail_existence_probe(pid, sig):
    if sig == 0:
        raise OSError("inspection failed")

module.os.killpg = fail_existence_probe
if module.stop_and_reap_process_group(ExitedProcess(), signal.SIGTERM):
    raise SystemExit("cleanup existence-probe failure was reported as success")

class SuccessfulProcess:
    pid = 43212
    args = ["synthetic-command"]

    def wait(self, timeout=None):
        return 0

module.subprocess.Popen = lambda *args, **kwargs: SuccessfulProcess()
module.process_group_exists = lambda _pid: (_ for _ in ()).throw(OSError("inspection failed"))
module.sys.argv = [module_path, "1", "synthetic-command"]
status = module.main()
if status != module.TERMINATION_FAILURE_EXIT_STATUS:
    raise SystemExit(f"normal-exit inspection failure returned {status}, expected 125")

class EarlySignalProcess:
    pid = 43213
    args = ["synthetic-command"]

forwarded = []
def signal_during_spawn(*args, **kwargs):
    module.os.kill(module.os.getpid(), signal.SIGTERM)
    return EarlySignalProcess()

module.subprocess.Popen = signal_during_spawn
module.stop_and_reap_process_group = lambda process, sig: forwarded.append(sig) or True
module.sys.argv = [module_path, "1", "synthetic-command"]
status = module.main()
if status != 143 or forwarded != [signal.SIGTERM]:
    raise SystemExit(f"spawn-window SIGTERM returned {status} with forwarded={forwarded}")
PY

cat >"$work_dir/signal-child.py" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

ready = Path(sys.argv[1])
received = Path(sys.argv[2])
pid_file = Path(sys.argv[3])

def handle(signum, _frame):
    received.write_text(signal.Signals(signum).name)
    raise SystemExit(0)

signal.signal(signal.SIGHUP, handle)
signal.signal(signal.SIGINT, handle)
signal.signal(signal.SIGTERM, handle)
pid_file.write_text(str(os.getpid()))
ready.write_text("ready")
while True:
    time.sleep(1)
PY
for forwarded_signal in HUP INT TERM; do
    ready_path="$work_dir/signal-$forwarded_signal.ready"
    received_path="$work_dir/signal-$forwarded_signal.received"
    child_pid_path="$work_dir/signal-$forwarded_signal.pid"
    "$script_dir/run-with-timeout.py" 30 python3 "$work_dir/signal-child.py" \
        "$ready_path" "$received_path" "$child_pid_path" &
    wrapper_pid=$!
    ready_attempts=0
    while [[ ! -f "$ready_path" && "$ready_attempts" -lt 100 ]]; do
        sleep 0.02
        ready_attempts=$((ready_attempts + 1))
    done
    if [[ ! -f "$ready_path" ]]; then
        echo "error: timeout-runner signal fixture did not become ready" >&2
        kill -KILL "$wrapper_pid" 2>/dev/null || true
        wait "$wrapper_pid" 2>/dev/null || true
        exit 1
    fi
    kill -"$forwarded_signal" "$wrapper_pid"
    set +e
    wait "$wrapper_pid"
    wrapper_status=$?
    set -e
    expected_status=129
    if [[ "$forwarded_signal" == "INT" ]]; then
        expected_status=130
    elif [[ "$forwarded_signal" == "TERM" ]]; then
        expected_status=143
    fi
    child_pid=$(<"$child_pid_path")
    if [[ "$wrapper_status" -ne "$expected_status" ]] || \
       [[ $(<"$received_path") != "SIG$forwarded_signal" ]] || \
       kill -0 "$child_pid" 2>/dev/null; then
        echo "error: timeout runner did not forward and reap SIG$forwarded_signal" >&2
        exit 1
    fi
done

shard_signal_pid="$work_dir/shard-script-signal.pid"
shard_signal_received="$work_dir/shard-script-signal.received"
FAKE_SLEEP_SECONDS=30 FAKE_PID_PATH="$shard_signal_pid" FAKE_SIGNAL_PATH="$shard_signal_received" \
    HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/shard-script-signal-results" \
    PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" 1 \
    >"$work_dir/shard-script-signal.out" 2>&1 &
shard_script_pid=$!
signal_attempts=0
while [[ ! -f "$shard_signal_pid" && "$signal_attempts" -lt 100 ]]; do
    sleep 0.02
    signal_attempts=$((signal_attempts + 1))
done
if [[ ! -f "$shard_signal_pid" ]]; then
    echo "error: shard-script signal fixture did not become ready" >&2
    kill -KILL "$shard_script_pid" 2>/dev/null || true
    wait "$shard_script_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$shard_script_pid"
set +e
wait "$shard_script_pid"
shard_script_status=$?
set -e
fake_xcodebuild_pid=$(<"$shard_signal_pid")
if [[ "$shard_script_status" -ne 143 ]] || \
   [[ ! -f "$shard_signal_received" ]] || \
   kill -0 "$fake_xcodebuild_pid" 2>/dev/null; then
    echo "error: UI shard script did not forward SIGTERM and reap xcodebuild" >&2
    cat "$work_dir/shard-script-signal.out" >&2
    exit 1
fi

mkdir -p "$work_dir/int-cancel"
cp "$script_dir/test-ui-shards.sh" "$work_dir/int-cancel/test-ui-shards.sh"
cp "$script_dir/validate-xcode-test-output.sh" "$work_dir/int-cancel/validate-xcode-test-output.sh"
int_cancel_ready="$work_dir/int-cancel.ready"
int_cancel_received="$work_dir/int-cancel.received"
cat >"$work_dir/int-cancel/run-with-timeout.py" <<'EOF'
#!/bin/bash
sleep 30 &
child_pid=$!
trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; printf TERM >"$INT_CANCEL_RECEIVED"; exit 143' TERM
: >"$INT_CANCEL_READY"
sleep 0.1
: >"$RUN_WITH_TIMEOUT_READY_FILE"
wait "$child_pid"
EOF
chmod +x "$work_dir/int-cancel/run-with-timeout.py" \
    "$work_dir/int-cancel/validate-xcode-test-output.sh"
python3 - "$work_dir/int-cancel/test-ui-shards.sh" "$work_dir/int-cancel.out" \
    "$int_cancel_ready" "$int_cancel_received" "$work_dir/int-cancel-results" \
    "$work_dir/bin" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, output, ready, received, results, fake_bin = sys.argv[1:]
environment = os.environ.copy()
environment.update(
    {
        "INT_CANCEL_READY": ready,
        "INT_CANCEL_RECEIVED": received,
        "HOLOSCAPE_UI_TEST_RESULTS_DIR": results,
        "PATH": f"{fake_bin}:{environment['PATH']}",
    }
)
with open(output, "wb") as log:
    process = subprocess.Popen(
        ["bash", script, "1"],
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    for _ in range(100):
        if Path(ready).exists():
            break
        time.sleep(0.02)
    else:
        process.kill()
        process.wait()
        raise SystemExit("early-INT cancellation fixture did not become ready")
    process.send_signal(signal.SIGINT)
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit("UI shard script did not stop after SIGINT")
if status != 130 or not Path(received).exists():
    raise SystemExit(f"UI shard script lost or misreported SIGINT cancellation: {status}")
PY

mkdir -p "$work_dir/cleanup-failure"
cp "$script_dir/test-ui-shards.sh" "$work_dir/cleanup-failure/test-ui-shards.sh"
cp "$script_dir/validate-xcode-test-output.sh" "$work_dir/cleanup-failure/validate-xcode-test-output.sh"
cleanup_failure_ready="$work_dir/cleanup-failure.ready"
cat >"$work_dir/cleanup-failure/run-with-timeout.py" <<'EOF'
#!/bin/bash
sleep 30 &
child_pid=$!
trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; exit 125' TERM
: >"$RUN_WITH_TIMEOUT_READY_FILE"
: >"$CLEANUP_FAILURE_READY"
wait "$child_pid"
EOF
chmod +x "$work_dir/cleanup-failure/run-with-timeout.py" \
    "$work_dir/cleanup-failure/validate-xcode-test-output.sh"
python3 - "$work_dir/cleanup-failure/test-ui-shards.sh" \
    "$work_dir/cleanup-failure.out" "$cleanup_failure_ready" \
    "$work_dir/cleanup-failure-results" "$work_dir/bin" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, output, ready, results, fake_bin = sys.argv[1:]
environment = os.environ.copy()
environment.update(
    {
        "CLEANUP_FAILURE_READY": ready,
        "HOLOSCAPE_UI_TEST_RESULTS_DIR": results,
        "PATH": f"{fake_bin}:{environment['PATH']}",
    }
)
with open(output, "wb") as log:
    process = subprocess.Popen(
        ["bash", script, "1"],
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    for _ in range(100):
        if Path(ready).exists():
            break
        time.sleep(0.02)
    else:
        process.kill()
        process.wait()
        raise SystemExit("cleanup-failure cancellation fixture did not become ready")
    process.send_signal(signal.SIGTERM)
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit("cleanup-failure cancellation fixture did not stop")
if status != 125:
    raise SystemExit(f"UI shard script hid timeout-runner cleanup failure: {status}")
PY

make_signal_pid="$work_dir/make-signal.pid"
make_signal_received="$work_dir/make-signal.received"
cat >"$work_dir/make-signal-overrides.mk" <<'EOF'
bundle:
	@:
EOF
FAKE_SLEEP_SECONDS=30 FAKE_PID_PATH="$make_signal_pid" FAKE_SIGNAL_PATH="$make_signal_received" \
    HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/make-signal-results" \
    PATH="$work_dir/bin:$PATH" \
    make -s -C "$repo_root" -f Makefile -f "$work_dir/make-signal-overrides.mk" \
    test-ui-shard SHARD=1 >"$work_dir/make-signal.out" 2>&1 &
make_pid=$!
signal_attempts=0
while [[ ! -f "$make_signal_pid" && "$signal_attempts" -lt 100 ]]; do
    sleep 0.02
    signal_attempts=$((signal_attempts + 1))
done
if [[ ! -f "$make_signal_pid" ]]; then
    echo "error: make signal fixture did not become ready" >&2
    kill -KILL "$make_pid" 2>/dev/null || true
    wait "$make_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$make_pid"
set +e
wait "$make_pid"
make_signal_status=$?
set -e
fake_xcodebuild_pid=$(<"$make_signal_pid")
if [[ "$make_signal_status" -eq 0 ]] || \
   [[ ! -f "$make_signal_received" ]] || \
   kill -0 "$fake_xcodebuild_pid" 2>/dev/null; then
    echo "error: test-ui-shard make recipe did not terminate and reap xcodebuild" >&2
    cat "$work_dir/make-signal.out" >&2
    exit 1
fi

cat >"$work_dir/bin/grep" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-c" && -n "${FAKE_COUNT_READY:-}" ]]; then
    : >"$FAKE_COUNT_READY"
    sleep 1
fi
exec /usr/bin/grep "$@"
EOF
chmod +x "$work_dir/bin/grep"
between_shards_ready="$work_dir/between-shards.ready"
between_shards_invocations="$work_dir/between-shards.invocations"
FAKE_SUCCESS_ONE_TEST=1 FAKE_COUNT_READY="$between_shards_ready" \
    FAKE_INVOCATION_LOG="$between_shards_invocations" \
    HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/between-shards-results" \
    PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" 1-2 \
    >"$work_dir/between-shards.out" 2>&1 &
between_shards_pid=$!
signal_attempts=0
while [[ ! -f "$between_shards_ready" && "$signal_attempts" -lt 100 ]]; do
    sleep 0.02
    signal_attempts=$((signal_attempts + 1))
done
if [[ ! -f "$between_shards_ready" ]]; then
    echo "error: between-shards signal fixture did not reach result counting" >&2
    kill -KILL "$between_shards_pid" 2>/dev/null || true
    wait "$between_shards_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$between_shards_pid"
set +e
wait "$between_shards_pid"
between_shards_status=$?
set -e
if [[ "$between_shards_status" -ne 143 ]] || \
   [[ $(wc -l <"$between_shards_invocations") -ne 1 ]]; then
    echo "error: UI shard range launched another shard after cancellation during result counting" >&2
    cat "$work_dir/between-shards.out" >&2
    exit 1
fi

invalid_shard_index=0
for invalid_shards in "" 5-3 0-1 1-11 11 invalid-range 18446744073709551617 \
    18446744073709551617-18446744073709551617; do
    invalid_shard_index=$((invalid_shard_index + 1))
    invalid_marker="$work_dir/invalid-$invalid_shard_index-xcodebuild-invoked"
    if FAKE_STATUS_PATH="$invalid_marker" PATH="$work_dir/bin:$PATH" \
       bash "$work_dir/test-ui-shards.sh" "$invalid_shards" \
       >"$work_dir/invalid-$invalid_shard_index.out" 2>&1; then
        echo "error: UI shard runner accepted invalid selection: $invalid_shards" >&2
        exit 1
    fi
    if [[ -e "$invalid_marker" ]] || \
       ! grep -Eq 'shard (selection|range|number)' "$work_dir/invalid-$invalid_shard_index.out"; then
        echo "error: invalid shard selection did not fail before xcodebuild: $invalid_shards" >&2
        cat "$work_dir/invalid-$invalid_shard_index.out" >&2
        exit 1
    fi
done

resume_file="$work_dir/single-results/last-failed-shard"
invalid_resume_index=0
for invalid_resume in "" garbage 0 11 18446744073709551617; do
    invalid_resume_index=$((invalid_resume_index + 1))
    printf '%s\n' "$invalid_resume" >"$resume_file"
    resume_marker="$work_dir/invalid-resume-$invalid_resume_index-xcodebuild-invoked"
    if FAKE_STATUS_PATH="$resume_marker" PATH="$work_dir/bin:$PATH" \
       bash "$work_dir/test-ui-shards.sh" resume \
       >"$work_dir/invalid-resume-$invalid_resume_index.out" 2>&1; then
        echo "error: UI shard runner accepted invalid resume point: $invalid_resume" >&2
        exit 1
    fi
    if [[ -e "$resume_marker" ]] || \
       ! grep -q 'invalid shard resume point' "$work_dir/invalid-resume-$invalid_resume_index.out"; then
        echo "error: invalid resume point did not fail before xcodebuild: $invalid_resume" >&2
        cat "$work_dir/invalid-resume-$invalid_resume_index.out" >&2
        exit 1
    fi
done

signal_invocations="$work_dir/shard-signal-invocations"
set +e
FAKE_EXIT_STATUS=130 FAKE_INVOCATION_LOG="$signal_invocations" PATH="$work_dir/bin:$PATH" \
    bash "$work_dir/test-ui-shards.sh" 1-2 >"$work_dir/shard-signal.out" 2>&1
shard_signal_status=$?
set -e
if [[ "$shard_signal_status" -ne 130 ]] || \
   [[ $(wc -l <"$signal_invocations") -ne 1 ]]; then
    echo "error: UI shard range did not preserve cancellation status and stop" >&2
    cat "$work_dir/shard-signal.out" >&2
    exit 1
fi

/bin/rm -rf "$status_path"
signal_recording_invocations="$work_dir/shard-signal-recording-invocations"
set +e
FAKE_EXIT_STATUS=130 FAKE_STATUS_PATH="$status_path" \
    FAKE_INVOCATION_LOG="$signal_recording_invocations" PATH="$work_dir/bin:$PATH" \
    bash "$work_dir/test-ui-shards.sh" 1-2 >"$work_dir/shard-signal-recording.out" 2>&1
shard_signal_recording_status=$?
set -e
if [[ "$shard_signal_recording_status" -ne 130 ]] || \
   [[ $(wc -l <"$signal_recording_invocations") -ne 1 ]] || \
   ! grep -q 'cannot record failed shard status' "$work_dir/shard-signal-recording.out"; then
    echo "error: UI shard bookkeeping failure masked cancellation or continued the range" >&2
    cat "$work_dir/shard-signal-recording.out" >&2
    exit 1
fi

cat >"$work_dir/group-leader.py" <<'PY'
from pathlib import Path
import subprocess
import sys
import time

descendant_pid = Path(sys.argv[1])
descendant = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import os, signal, sys, time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
        "open(sys.argv[1], 'w').write(str(os.getpid())); "
        "time.sleep(30)",
        str(descendant_pid),
    ]
)
while not descendant_pid.exists():
    time.sleep(0.01)
time.sleep(30)
PY
descendant_pid_path="$work_dir/group-descendant.pid"
set +e
"$script_dir/run-with-timeout.py" 5 python3 "$work_dir/group-leader.py" \
    "$descendant_pid_path" >"$work_dir/group-timeout.out" 2>&1
group_timeout_status=$?
set -e
descendant_pid=$(<"$descendant_pid_path")
if [[ "$group_timeout_status" -ne 124 ]] || kill -0 "$descendant_pid" 2>/dev/null; then
    echo "error: timeout runner returned before its entire process group exited" >&2
    cat "$work_dir/group-timeout.out" >&2
    exit 1
fi

cat >"$work_dir/normal-exit-group-leader.py" <<'PY'
from pathlib import Path
import subprocess
import sys
import time

descendant_pid = Path(sys.argv[1])
subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import os, signal, sys, time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "open(sys.argv[1], 'w').write(str(os.getpid())); "
        "time.sleep(30)",
        str(descendant_pid),
    ]
)
while not descendant_pid.exists():
    time.sleep(0.01)
PY
normal_exit_descendant_pid_path="$work_dir/normal-exit-group-descendant.pid"
if ! "$script_dir/run-with-timeout.py" 5 python3 "$work_dir/normal-exit-group-leader.py" \
    "$normal_exit_descendant_pid_path" >"$work_dir/normal-exit-group.out" 2>&1; then
    echo "error: timeout runner changed a successful leader exit while cleaning descendants" >&2
    cat "$work_dir/normal-exit-group.out" >&2
    exit 1
fi
normal_exit_descendant_pid=$(<"$normal_exit_descendant_pid_path")
if kill -0 "$normal_exit_descendant_pid" 2>/dev/null; then
    echo "error: timeout runner left a descendant after a successful leader exit" >&2
    exit 1
fi

cat >"$work_dir/signaled-group-leader.py" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import time

leader_pid = Path(sys.argv[1])
descendant_pid = Path(sys.argv[2])
subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import os, signal, sys, time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "open(sys.argv[1], 'w').write(str(os.getpid())); "
        "time.sleep(30)",
        str(descendant_pid),
    ]
)
leader_pid.write_text(str(os.getpid()))
while not descendant_pid.exists():
    time.sleep(0.01)
time.sleep(30)
PY
leader_pid_path="$work_dir/signaled-group-leader.pid"
signaled_descendant_pid_path="$work_dir/signaled-group-descendant.pid"
"$script_dir/run-with-timeout.py" 30 python3 "$work_dir/signaled-group-leader.py" \
    "$leader_pid_path" "$signaled_descendant_pid_path" &
signaled_wrapper_pid=$!
ready_attempts=0
while [[ (! -f "$leader_pid_path" || ! -f "$signaled_descendant_pid_path") && "$ready_attempts" -lt 100 ]]; do
    sleep 0.02
    ready_attempts=$((ready_attempts + 1))
done
if [[ ! -f "$leader_pid_path" || ! -f "$signaled_descendant_pid_path" ]]; then
    echo "error: signaled process-group fixture did not become ready" >&2
    kill -KILL "$signaled_wrapper_pid" 2>/dev/null || true
    wait "$signaled_wrapper_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$(<"$leader_pid_path")"
set +e
wait "$signaled_wrapper_pid"
signaled_wrapper_status=$?
set -e
signaled_descendant_pid=$(<"$signaled_descendant_pid_path")
if [[ "$signaled_wrapper_status" -ne 143 ]] || kill -0 "$signaled_descendant_pid" 2>/dev/null; then
    echo "error: timeout runner did not normalize a signaled leader and reap its descendants" >&2
    exit 1
fi

/bin/rm -rf "$bundle_path" "$status_path"
if FAKE_SLEEP_SECONDS=2 UI_TEST_TIMEOUT_SECONDS=0.1 PATH="$work_dir/bin:$PATH" \
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

/bin/rm -rf "$status_path"
if FAKE_SUCCESS_NO_TESTS=1 PATH="$work_dir/bin:$PATH" \
   bash "$work_dir/test-ui-shards.sh" 1 >"$work_dir/zero-tests.out" 2>&1; then
    echo "error: UI shard accepted a successful xcodebuild that executed no tests" >&2
    exit 1
fi
if ! grep -q 'no test cases executed' "$work_dir/zero-tests.out" || \
   [[ $(<"$status_path") != "FAIL" ]]; then
    echo "error: zero-test UI shard failure was not diagnosed and recorded" >&2
    cat "$work_dir/zero-tests.out" >&2
    exit 1
fi

cat >"$work_dir/one-test.txt" <<'EOF'
Test Case '-[SyntheticUITests testExample]' passed (0.001 seconds).
Test Suite 'SyntheticUITests' passed at 2026-10-16 00:00:00.000.
EOF
"$script_dir/validate-xcode-test-output.sh" "$work_dir/one-test.txt"
cat >"$work_dir/skipped-test.txt" <<'EOF'
Test Case '-[SyntheticUITests testExample]' skipped (0.001 seconds).
Test Suite 'SyntheticUITests' passed at 2026-10-16 00:00:00.000.
EOF
"$script_dir/validate-xcode-test-output.sh" "$work_dir/skipped-test.txt"
printf '** TEST SUCCEEDED **\n' >"$work_dir/no-tests.txt"
if "$script_dir/validate-xcode-test-output.sh" "$work_dir/no-tests.txt" >"$work_dir/no-tests-validator.out" 2>&1; then
    echo "error: Xcode test-output validator accepted output with no test cases" >&2
    exit 1
fi
if ! grep -q 'no test cases executed' "$work_dir/no-tests-validator.out"; then
    echo "error: Xcode test-output validator lacked a zero-test diagnostic" >&2
    cat "$work_dir/no-tests-validator.out" >&2
    exit 1
fi

cat >"$work_dir/make-overrides.mk" <<'EOF'
bundle:
	@:
EOF
for target in test-ui-shard test-ui-range; do
    missing_marker="$work_dir/$target-missing-xcodebuild-invoked"
    if FAKE_STATUS_PATH="$missing_marker" PATH="$work_dir/bin:$PATH" \
       make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" "$target" \
       >"$work_dir/$target-missing.out" 2>&1; then
        echo "error: $target accepted a missing shard selection" >&2
        exit 1
    fi
    if [[ -e "$missing_marker" ]] || \
       ! grep -q 'shard selection must not be empty' "$work_dir/$target-missing.out"; then
        echo "error: $target did not reject its missing selection before xcodebuild" >&2
        cat "$work_dir/$target-missing.out" >&2
        exit 1
    fi
done
for target in test-ui-fast test-ui-notifications; do
    set +e
    FAKE_EXIT_STATUS=130 HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/make-results" \
        PATH="$work_dir/bin:$PATH" \
        make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" \
        "$target" >"$work_dir/$target-signal.out" 2>&1
    make_signal_status=$?
    set -e
    if [[ "$make_signal_status" -eq 0 ]] || \
       ! grep -q 'Error 130' "$work_dir/$target-signal.out"; then
        echo "error: $target did not preserve cancellation status 130 in its recipe" >&2
        cat "$work_dir/$target-signal.out" >&2
        exit 1
    fi
done
for target in test-ui-fast test-ui-notifications; do
    if FAKE_SUCCESS_NO_TESTS=1 HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/make-results" \
       PATH="$work_dir/bin:$PATH" \
       make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" \
       "$target" >"$work_dir/$target-zero.out" 2>&1; then
        echo "error: $target accepted a successful xcodebuild that executed no tests" >&2
        exit 1
    fi
    if ! grep -q 'no test cases executed' "$work_dir/$target-zero.out"; then
        echo "error: $target lacked a zero-test diagnostic" >&2
        cat "$work_dir/$target-zero.out" >&2
        exit 1
    fi
done
if ! FAKE_SUCCESS_ONE_TEST=1 HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/make-results" \
   PATH="$work_dir/bin:$PATH" \
   make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" \
   test-ui-fast >"$work_dir/test-ui-fast-one.out" 2>&1; then
    echo "error: test-ui-fast rejected a successful xcodebuild that executed a test" >&2
    cat "$work_dir/test-ui-fast-one.out" >&2
    exit 1
fi
if ! FAKE_SUCCESS_SKIPPED_TEST=1 HOLOSCAPE_UI_TEST_RESULTS_DIR="$work_dir/make-results" \
   PATH="$work_dir/bin:$PATH" \
   make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" \
   test-ui-fast >"$work_dir/test-ui-fast-skipped.out" 2>&1; then
    echo "error: test-ui-fast rejected a successful skipped-only XCTest run" >&2
    cat "$work_dir/test-ui-fast-skipped.out" >&2
    exit 1
fi

failing_invocation_marker="$work_dir/failing-xcodebuild-invoked"
if FAKE_STATUS_PATH="$failing_invocation_marker" FAKE_SUCCESS_ONE_TEST=1 \
   PATH="$work_dir/bin:$PATH" \
   make -s -C "$repo_root" -f Makefile -f "$work_dir/make-overrides.mk" \
   test-ui-failing \
   >"$work_dir/failing-unset.out" 2>&1; then
    echo "error: test-ui-failing accepted an implicit machine-specific results input" >&2
    exit 1
fi
if [[ -e "$failing_invocation_marker" ]] || \
   ! grep -q 'HOLOSCAPE_UI_FAILING_RESULTS_FILE must name' "$work_dir/failing-unset.out"; then
    echo "error: unset failing-test results did not fail before xcodebuild with guidance" >&2
    cat "$work_dir/failing-unset.out" >&2
    exit 1
fi

if FAKE_STATUS_PATH="$failing_invocation_marker" FAKE_SUCCESS_ONE_TEST=1 \
   HOLOSCAPE_UI_FAILING_RESULTS_FILE="$work_dir/missing-failing-results.txt" \
   PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" failing \
   >"$work_dir/failing-missing.out" 2>&1; then
    echo "error: failing UI mode accepted a missing results input" >&2
    exit 1
fi
if [[ -e "$failing_invocation_marker" ]] || \
   ! grep -q 'cannot read failing-test results' "$work_dir/failing-missing.out"; then
    echo "error: missing failing-test results did not fail before xcodebuild" >&2
    cat "$work_dir/failing-missing.out" >&2
    exit 1
fi

printf '** TEST SUCCEEDED **\n' >"$work_dir/empty-failing-results.txt"
if FAKE_SUCCESS_ONE_TEST=1 HOLOSCAPE_UI_FAILING_RESULTS_FILE="$work_dir/empty-failing-results.txt" \
   PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" failing \
   >"$work_dir/failing-empty.out" 2>&1; then
    echo "error: failing UI mode accepted results with no failing classes" >&2
    exit 1
fi
if ! grep -q 'no failing Holoscape UI test classes found' "$work_dir/failing-empty.out"; then
    echo "error: empty failing-test results lacked a diagnostic" >&2
    cat "$work_dir/failing-empty.out" >&2
    exit 1
fi

cat >"$work_dir/one-failing-result.txt" <<'EOF'
Test Case '-[HoloscapeUITests.NotificationSystemUITests testExample]' failed (0.001 seconds).
EOF
if ! FAKE_SUCCESS_ONE_TEST=1 \
   FAKE_REQUIRE_ARGUMENT='-only-testing:HoloscapeUITests/NotificationSystemUITests' \
   HOLOSCAPE_UI_FAILING_RESULTS_FILE="$work_dir/one-failing-result.txt" \
   PATH="$work_dir/bin:$PATH" bash "$work_dir/test-ui-shards.sh" failing \
   >"$work_dir/failing-one.out" 2>&1; then
    echo "error: failing UI mode rejected a valid failing-class input" >&2
    cat "$work_dir/failing-one.out" >&2
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
    SHARD_RUN_STATUS[1]="FAIL"
    SHARD_RUN_PASSED[1]=$(count_matches "^Test Case .* passed" "$RESULTS_DIR/shard-1.txt")
    SHARD_RUN_FAILED[1]=$(count_matches "^Test Case .* failed" "$RESULTS_DIR/shard-1.txt")
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
    count_matches "^Test Case .* passed" "$RESULTS_DIR/shard-1.txt"
' _ "$definitions" >"$work_dir/unreadable.out" 2>&1; then
    if ! grep -q 'cannot read test output' "$work_dir/unreadable.out"; then
        echo "error: unreadable UI shard output failed without a diagnostic" >&2
        cat "$work_dir/unreadable.out" >&2
        exit 1
    fi
else
    echo "error: UI shard result counting accepted unreadable output" >&2
    exit 1
fi

echo "validated Xcode project drift detection and UI shard failure propagation"
