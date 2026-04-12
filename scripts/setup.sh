#!/bin/bash
# Holoscape Development Environment Setup
# Run this once on any machine to configure Claude Code integration.
# Usage: make setup (or ./scripts/setup.sh)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Holoscape Dev Setup ==="

# 1. Build the MCP server binary
echo "[1/4] Building HoloscapeMCP..."
cd "$REPO_DIR"
swift build --target HoloscapeMCP 2>&1 | tail -3
MCP_BIN="$(swift build --target HoloscapeMCP --show-bin-path)/HoloscapeMCP"
echo "  Binary: $MCP_BIN"

# 2. Install notification hook
echo "[2/4] Installing notification hook..."
mkdir -p ~/.holoscape
cp "$REPO_DIR/scripts/notify-hook.sh" ~/.holoscape/notify-hook.sh
chmod +x ~/.holoscape/notify-hook.sh
echo "  Installed: ~/.holoscape/notify-hook.sh"

# 3. Register MCP server with Claude Code
echo "[3/4] Registering Holoscape MCP server..."
if claude mcp list 2>&1 | grep -q "holoscape:"; then
    echo "  Already registered, updating..."
    claude mcp remove holoscape -s user 2>/dev/null || true
fi
claude mcp add holoscape -s user -- "$MCP_BIN"
echo "  Registered: holoscape MCP server (user scope)"

# 4. Add Notification + Stop hooks to Claude settings
echo "[4/4] Registering Notification + Stop hooks..."
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" <<'PYEOF'
import json, os, sys

settings_path = sys.argv[1]
hook_command = os.path.expanduser('~/.holoscape/notify-hook.sh')

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except Exception:
    settings = {}

hooks = settings.setdefault('hooks', {})
changed = False

for event in ('Notification', 'Stop'):
    existing = hooks.get(event, [])
    # Skip if our command is already registered (anywhere in any hook entry)
    already_registered = any(
        any(h.get('command') == hook_command for h in entry.get('hooks', []))
        for entry in existing
    )
    if already_registered:
        continue
    existing.append({
        'hooks': [{
            'type': 'command',
            'command': hook_command,
            'timeout': 3,
        }]
    })
    hooks[event] = existing
    changed = True
    print(f'  Added {event} hook')

if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
else:
    print('  Already configured')
PYEOF

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. make bundle && open build/Holoscape.app"
echo "  2. Start a Claude Code session in any tab"
echo "  3. Tab turns amber when Claude asks for permission,"
echo "     green the moment Claude finishes a turn."
