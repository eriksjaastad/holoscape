#!/bin/bash
# Holoscape Development Environment Setup
# Run this once on any machine to configure Claude Code integration.
# Usage: make setup (or ./scripts/setup.sh)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Holoscape Dev Setup ==="

# 1. Build the MCP server binary
echo "[1/5] Building HoloscapeMCP..."
cd "$REPO_DIR"
swift build --target HoloscapeMCP 2>&1 | tail -3
MCP_BIN="$(swift build --target HoloscapeMCP --show-bin-path)/HoloscapeMCP"
echo "  Binary: $MCP_BIN"

# 2. Install notification hook
echo "[2/5] Installing notification hook..."
mkdir -p ~/.holoscape
cp "$REPO_DIR/scripts/notify-hook.sh" ~/.holoscape/notify-hook.sh
chmod +x ~/.holoscape/notify-hook.sh
echo "  Installed: ~/.holoscape/notify-hook.sh"

# 3. Register MCP server with Claude Code
echo "[3/5] Registering Holoscape MCP server..."
if claude mcp list 2>&1 | grep -q "holoscape:"; then
    echo "  Already registered, updating..."
    claude mcp remove holoscape -s user 2>/dev/null || true
fi
claude mcp add holoscape -s user -- "$MCP_BIN"
echo "  Registered: holoscape MCP server (user scope)"

# 4. Set notification channel preference
echo "[4/5] Setting notification preferences..."
if ! grep -q '"preferredNotifChannel"' ~/.claude.json 2>/dev/null; then
    # Insert at top of JSON object
    python3 -c "
import json
with open('$HOME/.claude.json', 'r') as f:
    config = json.load(f)
config['preferredNotifChannel'] = 'ghostty'
with open('$HOME/.claude.json', 'w') as f:
    json.dump(config, f, indent=2)
"
    echo "  Set preferredNotifChannel=ghostty"
else
    echo "  Already configured"
fi

# 5. Add Notification hook to Claude settings if not present
echo "[5/5] Adding Notification hook to Claude settings..."
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && ! grep -q "Notification" "$SETTINGS"; then
    python3 -c "
import json
with open('$SETTINGS', 'r') as f:
    settings = json.load(f)
hooks = settings.setdefault('hooks', {})
if 'Notification' not in hooks:
    hooks['Notification'] = [{
        'hooks': [{
            'type': 'command',
            'command': '\$HOME/.holoscape/notify-hook.sh',
            'timeout': 3
        }]
    }]
    with open('$SETTINGS', 'w') as f:
        json.dump(settings, f, indent=2)
    print('  Added Notification hook')
else:
    print('  Already configured')
" 2>/dev/null || echo "  Skipped (settings.json not found or parse error)"
else
    echo "  Already configured"
fi

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. make bundle && open build/Holoscape.app"
echo "  2. Start a Claude session in any tab"
echo "  3. Tab lights up green when Claude finishes a task"
