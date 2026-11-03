#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/Holoscape.app}"
CONFIG_ROOT="${HOLOSCAPE_VERIFICATION_CONFIG_DIR:-}"
OWNS_CONFIG_ROOT=0
LAUNCH_COMPLETED=0

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
CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd -P)"

cleanup() {
    if [[ "$OWNS_CONFIG_ROOT" -eq 1 && "$LAUNCH_COMPLETED" -eq 1 ]]; then
        rm -rf "$CONFIG_ROOT"
    elif [[ "$OWNS_CONFIG_ROOT" -eq 1 ]]; then
        echo "Preserving isolated config after interrupted or failed launch: $CONFIG_ROOT" >&2
    fi
}
trap cleanup EXIT

echo "Launching isolated HoloScape verification with config: $CONFIG_ROOT"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
SOCKET_DIGEST="$(printf '%s\0%s' "$BUNDLE_ID" "$CONFIG_ROOT" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
SOCKET_PATH="${TMPDIR%/}/hs-broker-$(id -u)-${SOCKET_DIGEST}.sock"
PID_RECORD="$CONFIG_ROOT/.broker-owned-pids"

collect_descendants() {
    local parent="$1"
    local child
    local children
    local status
    if children="$(pgrep -P "$parent" 2>"$CONFIG_ROOT/.pgrep-error")"; then
        :
    else
        status=$?
        if [[ "$status" -eq 1 && ! -s "$CONFIG_ROOT/.pgrep-error" ]]; then
            rm -f "$CONFIG_ROOT/.pgrep-error"
            return
        fi
        echo "Could not inspect broker-owned processes for PID $parent" >&2
        cat "$CONFIG_ROOT/.pgrep-error" >&2
        rm -f "$CONFIG_ROOT/.pgrep-error"
        return "$status"
    fi
    rm -f "$CONFIG_ROOT/.pgrep-error"
    for child in $children; do
        printf '%s\n' "$child" >> "$PID_RECORD"
        collect_descendants "$child"
    done
}

process_is_live() {
    local pid="$1"
    local output
    local status
    if output="$(ps -p "$pid" -o pid= 2>"$CONFIG_ROOT/.ps-error")"; then
        rm -f "$CONFIG_ROOT/.ps-error"
        if [[ -n "$output" ]]; then
            return 0
        fi
        echo "Process inspection returned no PID for live broker-owned process $pid" >&2
        return 2
    else
        status=$?
    fi
    if [[ "$status" -eq 1 && ! -s "$CONFIG_ROOT/.ps-error" ]]; then
        rm -f "$CONFIG_ROOT/.ps-error"
        return 1
    fi
    echo "Could not inspect broker-owned PID $pid" >&2
    cat "$CONFIG_ROOT/.ps-error" >&2
    rm -f "$CONFIG_ROOT/.ps-error"
    return 2
}

open -W -n --env HOLOSCAPE_CONFIG_DIR="$CONFIG_ROOT" "$APP_PATH" \
    --args --app-hosted-verification --ephemeral-broker &
OPEN_PID=$!
while kill -0 "$OPEN_PID" 2>/dev/null; do
    if [[ -s "$SOCKET_PATH.lock" ]]; then
        BROKER_PID="$(cat "$SOCKET_PATH.lock")"
        if [[ "$BROKER_PID" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$BROKER_PID" >> "$PID_RECORD"
            collect_descendants "$BROKER_PID"
            sort -u -o "$PID_RECORD" "$PID_RECORD"
        fi
    fi
    sleep 0.1
done
wait "$OPEN_PID"

if [[ -e "$SOCKET_PATH" || -e "$SOCKET_PATH.lock" ]]; then
    echo "Preserving isolated config because broker namespace remains: $SOCKET_PATH" >&2
    exit 1
fi
if [[ -f "$PID_RECORD" ]]; then
    while IFS= read -r PID; do
        if process_is_live "$PID"; then
            echo "Preserving isolated config because broker-owned PID remains: $PID" >&2
            exit 1
        else
            STATUS=$?
            if [[ "$STATUS" -ne 1 ]]; then
                echo "Preserving isolated config because broker-owned PID state is unknown: $PID" >&2
                exit 1
            fi
        fi
    done < "$PID_RECORD"
fi
LAUNCH_COMPLETED=1
