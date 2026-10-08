#!/usr/bin/env bash
# Claude Code hook → cqutmux-hook bridge.
#
# Wire it into ~/.claude/settings.json so tool calls show up in the CQUTmux
# inbox. Claude Code passes the hook payload as JSON on stdin.
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         { "matcher": "*", "hooks": [
#           { "type": "command", "command": "/path/to/claude-code-hook.sh approval" }
#         ] }
#       ],
#       "Stop": [
#         { "hooks": [
#           { "type": "command", "command": "/path/to/claude-code-hook.sh notice" }
#         ] }
#       ]
#     }
#   }
#
# The first argument selects the kind: "approval" or "notice".

set -euo pipefail

KIND="${1:-notice}"
PORT="${CQUTMUX_PORT:-24543}"
URL="http://127.0.0.1:${PORT}/events"

payload="$(cat)"

# Pull nested fields without requiring jq: json_string tool_input file_path
# The payload travels in $CQUT_PAYLOAD because the heredoc below already owns
# stdin, so a `python3 -` reading sys.stdin would see the script, not the data.
json_string() {
  CQUT_PAYLOAD="$payload" python3 - "$@" <<'PY'
import json, os, sys
path = sys.argv[1:]
try:
    d = json.loads(os.environ.get("CQUT_PAYLOAD") or "{}")
except Exception:
    print(""); sys.exit()
for key in path:
    if isinstance(d, dict) and key in d:
        d = d[key]
    else:
        print(""); sys.exit()
print(d if isinstance(d, str) else json.dumps(d))
PY
}

tool="$(printf '%s' "$payload" | json_string tool_name)"
session="$(printf '%s' "$payload" | json_string session_id)"

if [ "$KIND" = "approval" ]; then
  title="${tool:-tool call}"
  body="$(printf '%s' "$payload" | json_string tool_input)"
else
  title="Task finished"
  body="$(printf '%s' "$payload" | json_string last_assistant_message)"
fi

[ -n "$title" ] || title="agent event"

# Best-effort: never block the agent if the hook daemon isn't running.
curl -s -m 2 -X POST "$URL" \
  -H 'content-type: application/json' \
  -d "$(python3 -c '
import json, sys
print(json.dumps({
    "source": "claude-code",
    "kind": sys.argv[1],
    "title": sys.argv[2][:200],
    "body": sys.argv[3][:1000],
    "data": {"session": sys.argv[4]},
}))
' "$KIND" "$title" "$body" "$session")" >/dev/null 2>&1 || true

exit 0