#!/bin/bash
# Claude Code Notification hook for Holoscape
# Reads JSON from stdin, forwards notification_type + cwd to Holoscape API
INPUT=$(cat)
TYPE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('notification_type','unknown'))" 2>/dev/null)
curl -s -X POST "http://127.0.0.1:7865/notify" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"$TYPE\",\"cwd\":\"$PWD\"}" \
  >/dev/null 2>&1
