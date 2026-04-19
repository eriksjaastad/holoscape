#!/usr/bin/env bash
# Amplify Task 19.2 — package the bundled HoloscapeClassic skin as
# a .wamp ZIP archive. Ships alongside the directory-layout form;
# SkinEngine.resolveSkinDir prefers the directory when both exist
# (Requirement 1.7), but both are available so the .wamp path stays
# exercised in production.
#
# Run from the repo root. Safe to re-run.
#
#   $ Tools/package_holoscape_classic.sh

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SKIN_DIR="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/HoloscapeClassic"
OUTPUT="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/HoloscapeClassic.wamp"

if [ ! -d "${SKIN_DIR}" ]; then
    echo "error: directory-layout skin not found at ${SKIN_DIR}" >&2
    exit 1
fi

rm -f "${OUTPUT}"

cd "${SKIN_DIR}"
zip -rX "${OUTPUT}" . >/dev/null

echo "packaged: ${OUTPUT}"
ls -lh "${OUTPUT}"
