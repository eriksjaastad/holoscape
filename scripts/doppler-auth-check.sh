#!/usr/bin/env bash
set -euo pipefail

PROJECT="${DOPPLER_PROJECT_NAME:-holoscape}"
CONFIG="${DOPPLER_CONFIG_NAME:-dev}"

if ! command -v doppler >/dev/null 2>&1; then
  echo "doppler-auth-check: doppler CLI is not installed or not on PATH" >&2
  exit 127
fi

doppler run --project "$PROJECT" --config "$CONFIG" -- sh -eu -c '
  : "${DOPPLER_PROJECT:?Doppler did not inject DOPPLER_PROJECT}"
  : "${DOPPLER_CONFIG:?Doppler did not inject DOPPLER_CONFIG}"
  : "${DOPPLER_ENVIRONMENT:?Doppler did not inject DOPPLER_ENVIRONMENT}"

  if [ "$DOPPLER_PROJECT" != "$1" ]; then
    echo "doppler-auth-check: expected project $1, got $DOPPLER_PROJECT" >&2
    exit 1
  fi
  if [ "$DOPPLER_CONFIG" != "$2" ]; then
    echo "doppler-auth-check: expected config $2, got $DOPPLER_CONFIG" >&2
    exit 1
  fi

  printf "Doppler auth OK: project=%s config=%s environment=%s\n" \
    "$DOPPLER_PROJECT" "$DOPPLER_CONFIG" "$DOPPLER_ENVIRONMENT"
' _ "$PROJECT" "$CONFIG"
