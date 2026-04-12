#!/bin/bash
# Claude Code hook → Holoscape tab notifications.
#
# Installed as both a `Notification` and a `Stop` hook in Claude Code:
#   - Notification → translate `notification_type` (permission_prompt, idle_prompt, …)
#                    and POST to Holoscape's /notify so the matching tab lights up
#                    amber (needs-approval) or green (ready).
#   - Stop        → Claude finished a turn; POST idle_prompt so the tab goes green
#                    immediately without waiting for an idle timeout.
#
# The hook JSON arrives on stdin. The script is a no-op if Holoscape isn't
# running (curl failure is swallowed) so it never blocks Claude Code.

python3 -c "
import json, sys, urllib.request

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

event = data.get('hook_event_name', '')

if event == 'Stop':
    # Stop fires the instant Claude finishes generating a turn. We map it to
    # idle_prompt so Holoscape renders the tab as 'ready' (green).
    notif_type = 'idle_prompt'
elif event == 'Notification':
    notif_type = data.get('notification_type', '')
else:
    sys.exit(0)

# Holoscape's /notify handler only renders tab state for these types.
# Anything else is a no-op, so bail out early to save the round-trip.
if notif_type not in ('permission_prompt', 'idle_prompt', 'auth_success', 'elicitation_dialog'):
    sys.exit(0)

# Prefer the explicit cwd field from Claude Code; fall back to \$PWD.
import os
cwd = data.get('cwd') or os.environ.get('PWD') or ''
if not cwd:
    sys.exit(0)

payload = json.dumps({'type': notif_type, 'cwd': cwd}).encode()
req = urllib.request.Request(
    'http://127.0.0.1:7865/notify',
    data=payload,
    headers={'Content-Type': 'application/json'},
    method='POST',
)
try:
    urllib.request.urlopen(req, timeout=2)
except Exception:
    # Holoscape may not be running, or /notify may be on a different port during
    # UI tests. Either way, we don't want to block the Claude Code event loop.
    pass
"
