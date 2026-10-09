#!/usr/bin/env bash
# Package or validate the bundled HoloscapeClassic-live skin.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: tools/package_holoscape_classic_live.sh [--check]

Package the in-tree HoloscapeClassic-live directory as
HoloscapeClassic-live.wamp. --check validates the existing archive without
modifying it.
EOF
    exit 0
fi

exec "${SCRIPT_DIR}/package_skin.sh" HoloscapeClassic-live "$@"
