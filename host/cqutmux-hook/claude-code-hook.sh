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
# The first argument selects the kind: "approval", "notice", "session-start" or
# "tool-finish". The first two are the two shapes the wire has always carried;
# the extra two exist so the Inbox can reach all five of its categories from a
# real install rather than only when an agent volunteers an event name.

set -euo pipefail

KIND="${1:-notice}"
PORT="${CQUTMUX_PORT:-24543}"
URL="http://127.0.0.1:${PORT}/events"

# The gateway's token, which it publishes while it runs. Claude Code spawns this
# hook with none of our environment, so without this a gateway started with
# `--token` refuses every event with a 401 that nothing reports — the hooks look
# installed and the inbox stays empty.
TOKEN="${CQUTMUX_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -r "$HOME/.cqutmux/token" ]; then
  TOKEN="$(cat "$HOME/.cqutmux/token")"
fi

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

# The kind is the *shape* on the wire (`approval`/`notice`), and the category is
# the finer thing the Inbox draws — one of Moshi's five. Claude's SessionStart
# hook is a separate invocation, so it is a third kind here rather than a
# category on an existing one.
case "$KIND" in
  session-start)
    title="Session started"
    body=""
    wire_kind="notice"
    category="session_started"
    ;;
  approval)
    title="${tool:-tool call}"
    body="$(printf '%s' "$payload" | json_string tool_input)"
    wire_kind="approval"
    category="approval_required"
    ;;
  tool-finish)
    title="${tool:-tool call}"
    body="$(printf '%s' "$payload" | json_string tool_input)"
    wire_kind="notice"
    category="tool_finished"
    ;;
  notice|*)
    title="Task finished"
    body="$(printf '%s' "$payload" | json_string last_assistant_message)"
    wire_kind="notice"
    category="task_complete"
    ;;
esac

[ -n "$title" ] || title="agent event"

# Best-effort: never block the agent if the hook daemon isn't running.
curl -s -m 2 -X POST "$URL" \
  -H 'content-type: application/json' \
  ${TOKEN:+-H "authorization: Bearer $TOKEN"} \
  -d "$(python3 -c '
import json, sys
print(json.dumps({
    "source": "claude-code",
    "kind": sys.argv[1],
    "category": sys.argv[2],
    "title": sys.argv[3][:200],
    "body": sys.argv[4][:1000],
    "data": {"session": sys.argv[5]},
}))
' "$wire_kind" "$category" "$title" "$body" "$session")" >/dev/null 2>&1 || true

exit 0