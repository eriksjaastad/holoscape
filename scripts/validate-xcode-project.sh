#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/.." rev-parse --show-toplevel) || {
    echo "error: cannot locate the repository for Xcode project validation" >&2
    exit 1
}
project_file="${1:-$repo_root/Holoscape.xcodeproj/project.pbxproj}"
if [[ "$project_file" != /* ]]; then
    project_file="$repo_root/$project_file"
fi
package_file="$repo_root/Package.swift"
scheme_file="${2:-$repo_root/Holoscape.xcodeproj/xcshareddata/xcschemes/Holoscape.xcscheme}"
if [[ "$scheme_file" != /* ]]; then
    scheme_file="$repo_root/$scheme_file"
fi

if [[ ! -f "$project_file" ]]; then
    echo "error: Xcode project not found: $project_file" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/holoscape-xcode-validation.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

object_block() {
    local object_id="$1"
    awk -v object_id="$object_id" '
        $0 ~ "^\\t\\t" object_id " .* = \\{" {
            in_object = 1
            print
            if ($0 ~ /};$/) exit
            next
        }
        in_object { print }
        in_object && $0 == "\t\t};" { exit }
    ' "$project_file"
}

require_exact_count() {
    local pattern="$1"
    local expected="$2"
    local description="$3"
    local count

    count=$(grep -Ec "$pattern" "$project_file" || true)
    if (( count != expected )); then
        echo "error: Xcode project has the wrong count for $description (found $count, need $expected)" >&2
        exit 1
    fi
}

require_in_block() {
    local block="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -Eq "$pattern" <<<"$block"; then
        echo "error: Xcode project is missing $description" >&2
        exit 1
    fi
}

is_swiftpm_only_unit_test() {
    case "$1" in
        Tests/HoloscapeTests/Unit/AppleScriptToolTests.swift|\
        Tests/HoloscapeTests/Unit/FileSystemToolTests.swift|\
        Tests/HoloscapeTests/Unit/HoloscapeClientTests.swift|\
        Tests/HoloscapeTests/Unit/ProcessToolTests.swift)
            # These import HoloscapeMCP/MCP, which are SwiftPM-only targets.
            return 0
            ;;
        *) return 1 ;;
    esac
}

validate_source_phase() {
    local phase_id="$1"
    local root="$2"
    local description="$3"
    local expected="$work_dir/$phase_id.expected"
    local actual="$work_dir/$phase_id.actual"
    local paths="$work_dir/$phase_id.paths"
    local phase

    if ! git -C "$repo_root" ls-files "$root/**/*.swift" "$root/*.swift" >"$paths"; then
        echo "error: failed to enumerate tracked Swift sources for $description" >&2
        exit 1
    fi

    : >"$expected"
    while IFS= read -r source_file; do
        if [[ "$root" == "Tests/HoloscapeTests" ]] && is_swiftpm_only_unit_test "$source_file"; then
            continue
        fi
        printf '%s\n' "$source_file"
    done <"$paths" | sort >"$expected"

    phase=$(object_block "$phase_id")
    if [[ -z "$phase" ]]; then
        echo "error: Xcode project is missing the $description source phase" >&2
        exit 1
    fi
    python3 - "$project_file" "$phase_id" >"$actual" <<'PY'
from pathlib import PurePosixPath
import re
import sys

project_file, phase_id = sys.argv[1:]
lines = open(project_file).read().splitlines()
header = re.compile(r"^\t\t([A-F0-9]{24})(?: /\*.*\*/)? = \{$")
inline_header = re.compile(r"^\t\t([A-F0-9]{24})(?: /\*.*\*/)? = \{.*\};$")
objects = {}

index = 0
while index < len(lines):
    inline_match = inline_header.match(lines[index])
    if inline_match:
        objects[inline_match.group(1)] = lines[index]
        index += 1
        continue
    match = header.match(lines[index])
    if not match:
        index += 1
        continue
    end = index + 1
    while end < len(lines) and lines[end] != "\t\t};":
        end += 1
    objects[match.group(1)] = "\n".join(lines[index:end + 1])
    index = end + 1

def value(block, key):
    match = re.search(rf"(?:^|[;{{])\s*{key} = ([^;]*);", block, re.MULTILINE)
    if not match:
        return None
    result = match.group(1)
    if result.startswith('"') and result.endswith('"'):
        result = result[1:-1].replace(r'\"', '"').replace(r'\\', '\\')
    return result

def references(block, key):
    match = re.search(
        rf"^\t\t\t{key} = \(\n(.*?)^\t\t\t\);$",
        block,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        return []
    return re.findall(r"^\t\t\t\t([A-F0-9]{24})", match.group(1), re.MULTILINE)

parents = {}
for object_id, block in objects.items():
    if value(block, "isa") == "PBXGroup":
        for child_id in references(block, "children"):
            parents[child_id] = object_id

def source_path(file_id):
    file_block = objects.get(file_id, "")
    path = value(file_block, "path")
    if path is None:
        raise SystemExit(f"error: PBX file reference {file_id} has no path")
    components = [path]
    current = file_id
    seen = set()
    while current in parents:
        if current in seen:
            raise SystemExit(f"error: PBX group cycle while resolving {file_id}")
        seen.add(current)
        current = parents[current]
        group_path = value(objects[current], "path")
        if group_path:
            components.insert(0, group_path)
    return str(PurePosixPath(*components))

phase = objects.get(phase_id)
if phase is None:
    raise SystemExit(f"error: Xcode project is missing source phase {phase_id}")

paths = []
for build_id in references(phase, "files"):
    build_file = objects.get(build_id, "")
    match = re.search(r"fileRef = ([A-F0-9]{24})", build_file)
    if not match:
        raise SystemExit(f"error: PBX build file {build_id} has no file reference")
    resolved = source_path(match.group(1))
    if resolved.endswith(".swift"):
        paths.append(resolved)

print("\n".join(sorted(paths)))
PY

    if ! diff -u "$expected" "$actual" >"$work_dir/$phase_id.diff"; then
        echo "error: Xcode project $description source phase differs from tracked sources" >&2
        cat "$work_dir/$phase_id.diff" >&2
        exit 1
    fi
}

app_target=$(object_block 5C59BAAE8FD8795F26EC429E)
unit_target=$(object_block 6D1C4365B7B34EC1185722E9)
app_frameworks=$(object_block 17800BD5018258B2F8301A01)
unit_frameworks=$(object_block 982D1B0759F34671CF2E01A8)
native_target=$(object_block 6C329224BFDF298222AD54F2)
project_object=$(object_block A8536900B627C2D00527ABA0)
products_group=$(object_block BC2B4CEB52F4413B92874773)
native_sources=$(object_block 29DF915F0B0E35021A07F00C)
native_headers=$(object_block 01340CE64B6CB3BB8355E6E3)
native_debug=$(object_block E4CDB2C39667C59F185B7CAE)
native_release=$(object_block C3DC0F1EF6A90CEF16955202)
native_configurations=$(object_block 95F26503BABD4AD324729427)
app_native_link=$(object_block 33BBD496CD920CD4B74477AF)
unit_native_link=$(object_block 440A44BB465227FF25586C6C)
native_source_build=$(object_block 7FF4689172A66A84831BE365)
native_header_build=$(object_block 674AF628153281874D3C6D2C)
native_module_build=$(object_block 4165D103000290B221C35508)
native_product=$(object_block C8599FAC0805093E678DF085)
native_source_ref=$(object_block 42DEDE3141991410446F206A)
native_header_ref=$(object_block AF97B2AFE4D21485034B278A)
native_module_ref=$(object_block F8BD4621F6772CF38A9DE45B)
native_group=$(object_block 3ED4E029EC99572AF65368CA)
native_include_group=$(object_block D88E88EECB894BC217A19A93)
app_native_dependency=$(object_block DAC48B5DA795A81287A82366)
unit_native_dependency=$(object_block 580BFB81F52809995A063812)
app_native_proxy=$(object_block 20095555BFCC93C30B1A015B)
unit_native_proxy=$(object_block 95E0086FA1877F094D42DB97)

require_exact_count 'name = CNativePTY;' 2 'the CNativePTY target and source group names'
require_exact_count 'path = Sources/CNativePTY;' 1 'the CNativePTY source group'
require_exact_count 'HoloscapeNativePTY\.c in Sources' 2 'the CNativePTY source build entry'
require_exact_count 'libCNativePTY\.a in Frameworks' 4 'the app and unit-test CNativePTY links'
require_exact_count 'remoteInfo = CNativePTY;' 2 'the app and unit-test CNativePTY dependency proxies'
require_exact_count 'target = [A-F0-9]+ /\* CNativePTY \*/;' 2 'the app and unit-test CNativePTY target dependencies'
require_exact_count '"-lc\+\+",' 4 'the Debug and Release C++ runtime links for the app and unit tests'

require_in_block "$app_target" 'DAC48B5DA795A81287A82366 /\* PBXTargetDependency \*/' 'the app CNativePTY dependency'
require_in_block "$unit_target" '580BFB81F52809995A063812 /\* PBXTargetDependency \*/' 'the unit-test CNativePTY dependency'
require_in_block "$unit_target" 'BCB539B94D0F4E55A8FD76D3 /\* SwiftTerm \*/' 'the unit-test SwiftTerm package dependency'
require_in_block "$app_frameworks" '33BBD496CD920CD4B74477AF /\* libCNativePTY\.a in Frameworks \*/' 'the app CNativePTY link'
require_in_block "$unit_frameworks" '440A44BB465227FF25586C6C /\* libCNativePTY\.a in Frameworks \*/' 'the unit-test CNativePTY link'
require_in_block "$unit_frameworks" '18A4681DF2204A32A91C6E67 /\* SwiftTerm in Frameworks \*/' 'the unit-test SwiftTerm link'
require_in_block "$native_target" '01340CE64B6CB3BB8355E6E3 /\* CopyFiles \*/' 'the CNativePTY header phase'
require_in_block "$native_target" '29DF915F0B0E35021A07F00C /\* Sources \*/' 'the CNativePTY source phase'
require_in_block "$native_target" 'buildConfigurationList = 95F26503BABD4AD324729427 ' 'the CNativePTY configuration list'
require_in_block "$native_target" 'productReference = C8599FAC0805093E678DF085 ' 'the CNativePTY product reference'
require_in_block "$native_target" 'productType = "com\.apple\.product-type\.library\.static";' 'the CNativePTY static-library product type'
require_in_block "$project_object" '6C329224BFDF298222AD54F2 /\* CNativePTY \*/' 'CNativePTY in the project target list'
require_in_block "$products_group" 'C8599FAC0805093E678DF085 /\* libCNativePTY\.a \*/' 'the CNativePTY product in the Products group'
require_in_block "$native_configurations" 'E4CDB2C39667C59F185B7CAE /\* Debug \*/' 'the CNativePTY Debug configuration'
require_in_block "$native_configurations" 'C3DC0F1EF6A90CEF16955202 /\* Release \*/' 'the CNativePTY Release configuration'
require_in_block "$native_sources" '7FF4689172A66A84831BE365 /\* HoloscapeNativePTY\.c in Sources \*/' 'the native PTY C source'
require_in_block "$native_headers" '674AF628153281874D3C6D2C /\* HoloscapeNativePTY\.h in CopyFiles \*/' 'the native PTY public header'
require_in_block "$native_headers" '4165D103000290B221C35508 /\* module\.modulemap in CopyFiles \*/' 'the native PTY module map'
require_in_block "$app_native_link" 'fileRef = C8599FAC0805093E678DF085 ' 'the app CNativePTY product edge'
require_in_block "$unit_native_link" 'fileRef = C8599FAC0805093E678DF085 ' 'the unit-test CNativePTY product edge'
require_in_block "$native_source_build" 'fileRef = 42DEDE3141991410446F206A ' 'the native PTY source edge'
require_in_block "$native_header_build" 'fileRef = AF97B2AFE4D21485034B278A ' 'the native PTY header edge'
require_in_block "$native_module_build" 'fileRef = F8BD4621F6772CF38A9DE45B ' 'the native PTY module-map edge'
require_in_block "$native_product" 'explicitFileType = archive\.ar;' 'the CNativePTY archive product type'
require_in_block "$native_product" 'path = libCNativePTY\.a;' 'the CNativePTY archive product path'
require_in_block "$native_product" 'sourceTree = BUILT_PRODUCTS_DIR;' 'the CNativePTY archive product source tree'
require_in_block "$native_source_ref" 'path = HoloscapeNativePTY\.c;' 'the native PTY C file path'
require_in_block "$native_header_ref" 'path = HoloscapeNativePTY\.h;' 'the native PTY header path'
require_in_block "$native_module_ref" 'path = module\.modulemap;' 'the native PTY module-map path'
require_in_block "$native_group" '42DEDE3141991410446F206A /\* HoloscapeNativePTY\.c \*/' 'the native PTY C file in its source group'
require_in_block "$native_group" 'D88E88EECB894BC217A19A93 /\* include \*/' 'the native PTY include group'
require_in_block "$native_group" 'path = Sources/CNativePTY;' 'the native PTY source-group path'
require_in_block "$native_include_group" 'AF97B2AFE4D21485034B278A /\* HoloscapeNativePTY\.h \*/' 'the native PTY header in its include group'
require_in_block "$native_include_group" 'F8BD4621F6772CF38A9DE45B /\* module\.modulemap \*/' 'the native PTY module map in its include group'
require_in_block "$native_include_group" 'path = include;' 'the native PTY include-group path'
require_in_block "$app_native_dependency" 'target = 6C329224BFDF298222AD54F2 ' 'the app dependency target edge to CNativePTY'
require_in_block "$app_native_dependency" 'targetProxy = 20095555BFCC93C30B1A015B ' 'the app dependency proxy edge to CNativePTY'
require_in_block "$unit_native_dependency" 'target = 6C329224BFDF298222AD54F2 ' 'the unit-test dependency target edge to CNativePTY'
require_in_block "$unit_native_dependency" 'targetProxy = 95E0086FA1877F094D42DB97 ' 'the unit-test dependency proxy edge to CNativePTY'
for proxy in "$app_native_proxy" "$unit_native_proxy"; do
    require_in_block "$proxy" 'containerPortal = A8536900B627C2D00527ABA0 ' 'the CNativePTY dependency project portal'
    require_in_block "$proxy" 'remoteGlobalIDString = 6C329224BFDF298222AD54F2;' 'the CNativePTY dependency proxy target'
    require_in_block "$proxy" 'remoteInfo = CNativePTY;' 'the CNativePTY dependency proxy identity'
done
for configuration in "$native_debug" "$native_release"; do
    require_in_block "$configuration" 'DEFINES_MODULE = YES;' 'CNativePTY module generation in Debug and Release'
    require_in_block "$configuration" 'HEADER_SEARCH_PATHS = "\$\(SRCROOT\)/Sources/CNativePTY/include";' 'CNativePTY header search path in Debug and Release'
    require_in_block "$configuration" 'MODULEMAP_FILE = Sources/CNativePTY/include/module\.modulemap;' 'CNativePTY module map in Debug and Release'
done

swiftterm_version=$(sed -nE 's/.*SwiftTerm\.git", exact: "([^"]+)".*/\1/p' "$package_file")
if [[ -z "$swiftterm_version" ]] || [[ $(wc -l <<<"$swiftterm_version" | tr -d ' ') -ne 1 ]]; then
    echo "error: Package.swift must contain one exact SwiftTerm requirement" >&2
    exit 1
fi
swiftterm_package=$(object_block 6D12D0AC4D71CD43C7949ECA)
require_in_block "$swiftterm_package" 'kind = exactVersion;' 'the exact SwiftTerm Xcode requirement'
require_in_block "$swiftterm_package" "version = ${swiftterm_version//./\\.};" "SwiftTerm $swiftterm_version in the Xcode project"

validate_source_phase DBDABAE51D6625081EA3C33F Sources/Holoscape 'app'
validate_source_phase 588AC30E0A325E0EC23904A2 Tests/HoloscapeTests 'unit-test'
validate_source_phase D667E382F8A6AB7B28F95FC5 Tests/HoloscapePropertyTests 'property-test'
validate_source_phase DF2F634F7655E0873CBF64BB Tests/HoloscapeUITests 'UI-test'

plutil -lint "$project_file" >/dev/null
xmllint --noout "$scheme_file"
python3 - "$scheme_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

scheme_file = sys.argv[1]
root = ET.parse(scheme_file).getroot()
testables = root.find("./TestAction/Testables")
if testables is None:
    raise SystemExit("error: the shared Holoscape scheme is missing TestAction/Testables")

expected = {
    "HoloscapeTests": ("6D1C4365B7B34EC1185722E9", "HoloscapeTests.xctest"),
    "HoloscapePropertyTests": ("EC16900C71D87D4A20A1DE69", "HoloscapePropertyTests.xctest"),
    "HoloscapeUITests": ("70CD47CBC5D1B1774DFA63D9", "HoloscapeUITests.xctest"),
}
found = {}
for testable in testables.findall("TestableReference"):
    buildable = testable.find("BuildableReference")
    if buildable is None:
        raise SystemExit("error: a shared Holoscape scheme test entry has no buildable reference")
    name = buildable.get("BlueprintName")
    if not name or name in found:
        raise SystemExit("error: the shared Holoscape scheme has a missing or duplicate test target name")
    found[name] = (testable, buildable)

if set(found) != set(expected):
    raise SystemExit(
        "error: the shared Holoscape scheme must contain exactly "
        "HoloscapeTests, HoloscapePropertyTests, and HoloscapeUITests"
    )
for name, (blueprint_id, buildable_name) in expected.items():
    testable, buildable = found[name]
    if (
        testable.get("skipped") != "NO"
        or testable.find("SkippedTests") is not None
        or testable.find("SelectedTests") is not None
        or buildable.get("BuildableIdentifier") != "primary"
        or buildable.get("BlueprintIdentifier") != blueprint_id
        or buildable.get("BuildableName") != buildable_name
        or buildable.get("ReferencedContainer") != "container:Holoscape.xcodeproj"
    ):
        raise SystemExit(f"error: the shared Holoscape scheme has an invalid {name} test entry")
PY

echo "Xcode project source and CNativePTY integration is valid"
