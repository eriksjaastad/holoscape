#!/bin/bash
set -euo pipefail

project_file="${1:-Holoscape.xcodeproj/project.pbxproj}"

if [[ ! -f "$project_file" ]]; then
    echo "error: Xcode project not found: $project_file" >&2
    exit 1
fi

require_count() {
    local pattern="$1"
    local minimum="$2"
    local description="$3"
    local count

    count=$(grep -Ec "$pattern" "$project_file" || true)
    if (( count < minimum )); then
        echo "error: Xcode project is missing $description (found $count, need $minimum)" >&2
        exit 1
    fi
}

require_count 'name = CNativePTY;' 1 'the CNativePTY native target'
require_count 'path = Sources/CNativePTY;' 1 'the CNativePTY source group'
require_count 'HoloscapeNativePTY\.c in Sources' 2 'the CNativePTY source build entry'
require_count 'Sources/CNativePTY/include/module\.modulemap' 2 'CNativePTY module-map build settings'
require_count 'libCNativePTY\.a in Frameworks' 4 'Holoscape and HoloscapeTests link entries'
require_count 'remoteInfo = CNativePTY;' 2 'Holoscape and HoloscapeTests dependency proxies'
require_count 'target = [A-F0-9]+ /\* CNativePTY \*/;' 2 'Holoscape and HoloscapeTests target dependencies'
require_count 'kind = exactVersion;' 1 'the exact SwiftTerm package requirement'
require_count 'version = 1\.20\.0;' 1 'the SwiftTerm version used by Package.swift'

source_phase() {
    local phase_id="$1"
    awk -v phase_id="$phase_id" '
        $0 ~ "^\\t\\t" phase_id " " { in_phase = 1 }
        in_phase { print }
        in_phase && /^\\t\\t};$/ { exit }
    ' "$project_file"
}

app_sources=$(source_phase DBDABAE51D6625081EA3C33F)
unit_sources=$(source_phase 588AC30E0A325E0EC23904A2)
property_sources=$(source_phase D667E382F8A6AB7B28F95FC5)
ui_sources=$(source_phase DF2F634F7655E0873CBF64BB)

while IFS= read -r source_file; do
    source_name=${source_file##*/}
    case "$source_file" in
        Sources/Holoscape/*) phase_sources=$app_sources ;;
        Tests/HoloscapeTests/*) phase_sources=$unit_sources ;;
        Tests/HoloscapePropertyTests/*) phase_sources=$property_sources ;;
        Tests/HoloscapeUITests/*) phase_sources=$ui_sources ;;
        *) continue ;;
    esac

    if ! grep -Fq "/* $source_name in Sources */" <<<"$phase_sources"; then
        echo "error: Xcode project source phase is missing $source_file" >&2
        exit 1
    fi
done < <(
    git ls-files \
        'Sources/Holoscape/**/*.swift' 'Sources/Holoscape/*.swift' \
        'Tests/HoloscapeTests/**/*.swift' 'Tests/HoloscapeTests/*.swift' \
        'Tests/HoloscapePropertyTests/**/*.swift' 'Tests/HoloscapePropertyTests/*.swift' \
        'Tests/HoloscapeUITests/**/*.swift' 'Tests/HoloscapeUITests/*.swift'
)

plutil -lint "$project_file" >/dev/null

echo "Xcode project source and CNativePTY integration is valid"
