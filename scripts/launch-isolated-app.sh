#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/Holoscape.app}"
CONFIG_ROOT="${HOLOSCAPE_VERIFICATION_CONFIG_DIR:-}"
OWNS_CONFIG_ROOT=0

if [[ ! -d "$APP_PATH" ]]; then
    echo "Packaged app not found: $APP_PATH" >&2
    exit 1
fi

if [[ -z "$CONFIG_ROOT" ]]; then
    mkdir -p "$ROOT/.scratch/app-verification"
    CONFIG_ROOT="$(mktemp -d "$ROOT/.scratch/app-verification/run.XXXXXX")"
    OWNS_CONFIG_ROOT=1
else
    mkdir -p "$CONFIG_ROOT"
fi

cleanup() {
    if [[ "$OWNS_CONFIG_ROOT" -eq 1 ]]; then
        rm -rf "$CONFIG_ROOT"
    fi
}
trap cleanup EXIT

echo "Launching isolated HoloScape verification with config: $CONFIG_ROOT"
open -W -n --env HOLOSCAPE_CONFIG_DIR="$CONFIG_ROOT" "$APP_PATH" \
    --args --app-hosted-verification --ephemeral-broker