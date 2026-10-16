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
scheme_file="$repo_root/Holoscape.xcodeproj/xcshareddata/xcschemes/Holoscape.xcscheme"

if [[ ! -f "$project_file" ]]; then
    echo "error: Xcode project not found: $project_file" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/holoscape-xcode-validation.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

object_block() {
    local object_id="$1"
    awk -v object_id="$object_id" '
        $0 ~ "^\\t\\t" object_id " .* = \\{$" { in_object = 1 }
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
        basename "$source_file"
    done <"$paths" | sort >"$expected"

    if [[ -n $(uniq -d "$expected") ]]; then
        echo "error: duplicate Swift basenames make $description validation ambiguous" >&2
        uniq -d "$expected" >&2
        exit 1
    fi

    phase=$(object_block "$phase_id")
    if [[ -z "$phase" ]]; then
        echo "error: Xcode project is missing the $description source phase" >&2
        exit 1
    fi
    sed -nE 's/.*\/\* (.*\.swift) in Sources \*\/.*/\1/p' <<<"$phase" | sort >"$actual"

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
native_sources=$(object_block 29DF915F0B0E35021A07F00C)
native_headers=$(object_block 01340CE64B6CB3BB8355E6E3)
native_debug=$(object_block E4CDB2C39667C59F185B7CAE)
native_release=$(object_block C3DC0F1EF6A90CEF16955202)

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
require_in_block "$native_sources" '7FF4689172A66A84831BE365 /\* HoloscapeNativePTY\.c in Sources \*/' 'the native PTY C source'
require_in_block "$native_headers" '674AF628153281874D3C6D2C /\* HoloscapeNativePTY\.h in CopyFiles \*/' 'the native PTY public header'
require_in_block "$native_headers" '4165D103000290B221C35508 /\* module\.modulemap in CopyFiles \*/' 'the native PTY module map'
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
if [[ $(grep -c 'BlueprintName = "HoloscapeTests"' "$scheme_file") -ne 1 ]]; then
    echo "error: the shared Holoscape scheme must include HoloscapeTests exactly once" >&2
    exit 1
fi

echo "Xcode project source and CNativePTY integration is valid"
