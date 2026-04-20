#!/usr/bin/env bash
# Amplify Task 19.1 — repackage the bundled HoloscapeSynthwave skin
# as a .wamp ZIP archive. The .wamp ships alongside the directory-
# layout form; SkinEngine.resolveSkinDir prefers the directory when
# both exist (Requirement 1.7), but having both available proves the
# pipeline works on a known-good skin before authoring HoloscapeClassic.
#
# Run from the repo root. Safe to re-run — overwrites the existing
# .wamp with a fresh zip.
#
#   $ Tools/package_synthwave.sh

set -euo pipefail

# Resolve paths relative to the script's own location so this works
# from any cwd (makes it wire-into-a-build-step-able).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SKIN_DIR="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/HoloscapeSynthwave"
OUTPUT="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/HoloscapeSynthwave.wamp"

if [ ! -d "${SKIN_DIR}" ]; then
    echo "error: directory-layout skin not found at ${SKIN_DIR}" >&2
    exit 1
fi

# Remove any previous bundle so the zip is a clean rebuild, not an
# update of an existing archive (avoids accumulating stale entries
# when a file is deleted between packagings).
rm -f "${OUTPUT}"

# `cd` into the skin dir so zip stores entries with the expected
# relative paths (skin.json, assets/…) — NOT prefixed with the
# full absolute path. `-X` strips extra file metadata that would
# make bundles non-reproducible across machines.
cd "${SKIN_DIR}"
zip -rX "${OUTPUT}" . >/dev/null

echo "packaged: ${OUTPUT}"
ls -lh "${OUTPUT}"
