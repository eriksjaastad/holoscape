#!/usr/bin/env bash
# Package or validate the bundled HoloscapeSynthwave skin.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: tools/package_synthwave.sh [--check]

Package the in-tree HoloscapeSynthwave directory as HoloscapeSynthwave.wamp.
--check validates the existing archive without modifying it.
EOF
    exit 0
fi

exec "${SCRIPT_DIR}/package_skin.sh" HoloscapeSynthwave "$@"
