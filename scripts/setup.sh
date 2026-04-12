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
holoscape_dir = os.path.expanduser('~/.holoscape/')
hook_command = os.path.join(holoscape_dir, 'notify-hook.sh')
desired_entry = {
    'type': 'command',
    'command': hook_command,
    'timeout': 3,
}

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except Exception:
    settings = {}

hooks = settings.setdefault('hooks', {})

def owned_by_holoscape(h):
    cmd = h.get('command', '')
    return os.path.expanduser(cmd).startswith(holoscape_dir)

before = json.dumps(hooks, sort_keys=True)

for event in ('Notification', 'Stop'):
    existing = hooks.get(event, [])
    cleaned = []
    for entry in existing:
        kept = [h for h in entry.get('hooks', []) if not owned_by_holoscape(h)]
        if kept:
            new_entry = dict(entry)
            new_entry['hooks'] = kept
            cleaned.append(new_entry)
    cleaned.append({'hooks': [dict(desired_entry)]})
    hooks[event] = cleaned

# Drop any event keys that ended up empty (defensive; shouldn't happen here).
for event in list(hooks.keys()):
    if not hooks[event]:
        del hooks[event]

after = json.dumps(hooks, sort_keys=True)
if before != after:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print('  Reconciled Notification + Stop hooks')
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
