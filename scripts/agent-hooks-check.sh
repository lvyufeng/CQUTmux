#!/usr/bin/env bash
#
# Checks that `cqutmux install` wires up each agent in that agent's own format,
# and that re-running and uninstalling are both safe.
#
# The failure this guards against is the one an installer is uniquely bad at
# hiding: writing a config file the agent silently ignores. A hook that is not
# read looks exactly like an agent that produced no events, and from the app
# you cannot tell the two apart. So each check reads the file back and asserts
# the *shape the agent documented* — event names, nesting, and for Codex the
# feature flag without which none of it is read at all.
#
# The `HOME` is a fake one: install writes to ~/.claude, ~/.codex and the rest,
# and running it against the real home would edit the machine this is run on.
#
# Usage: scripts/agent-hooks-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
FAKE_HOME="$OUT/home"
mkdir -p "$FAKE_HOME"

run() {
  HOME="$FAKE_HOME" node host/cqutmux-hook/index.mjs "$@" 2>&1
}

echo "==> installing"
run install > "$OUT/install.log" || { echo "FAIL: install exited non-zero"; cat "$OUT/install.log"; exit 1; }
cat "$OUT/install.log"

python3 - "$FAKE_HOME" <<'PY'
import json, os, sys

home = sys.argv[1]
problems = []


def fail(message):
    problems.append(message)


def read_json(path):
    try:
        return json.load(open(path))
    except Exception as error:
        fail(f"{path} is not readable JSON: {error}")
        return {}


def read_text(path):
    try:
        return open(path).read()
    except Exception as error:
        fail(f"{path} is not readable: {error}")
        return ""


# --- Claude Code -----------------------------------------------------------
claude = read_json(os.path.join(home, ".claude", "settings.json"))
hooks = claude.get("hooks", {})
if "PreToolUse" not in hooks:
    fail("Claude Code has no PreToolUse hook")
else:
    command = json.dumps(hooks["PreToolUse"])
    if "claude-code-hook" not in command or "approval" not in command:
        fail(f"Claude Code's PreToolUse does not call the approval bridge: {command}")
if "Stop" not in hooks:
    fail("Claude Code has no Stop hook")

# --- Codex -----------------------------------------------------------------
# The feature flag is the whole reason this agent gets its own check: hooks are
# ignored without it, so writing hooks.json alone would be a silent no-op.
codex_hooks = read_json(os.path.join(home, ".codex", "hooks.json"))
if "PreToolUse" not in codex_hooks.get("hooks", {}):
    fail("Codex has no PreToolUse hook in hooks.json")
codex_config = read_text(os.path.join(home, ".codex", "config.toml"))
if "hooks = true" not in codex_config:
    fail("Codex's features.hooks flag was not enabled, so its hooks are never read")
if "agent-hook.mjs" not in codex_config and "agent-hook.mjs" not in json.dumps(codex_hooks):
    fail("Codex's hook does not call the shared bridge")

# --- Cursor ----------------------------------------------------------------
cursor = read_json(os.path.join(home, ".cursor", "hooks.json"))
if cursor.get("version") != 1:
    fail(f"Cursor's hooks.json needs version 1, got {cursor.get('version')!r}")
# Cursor's event names are camelCase and different from Claude Code's. Using
# Claude's names here would produce a file Cursor loads and finds nothing in.
if "preToolUse" not in cursor.get("hooks", {}):
    fail("Cursor has no preToolUse hook (the name is camelCase, not PreToolUse)")
if "stop" not in cursor.get("hooks", {}):
    fail("Cursor has no stop hook")
if "PreToolUse" in cursor.get("hooks", {}) or "Stop" in cursor.get("hooks", {}):
    fail("Cursor got Claude Code's PascalCase event names, which it does not read")

# --- Kimi Code CLI ---------------------------------------------------------
kimi = read_text(os.path.join(home, ".kimi-code", "config.toml"))
if "[[hooks]]" not in kimi:
    fail("Kimi has no [[hooks]] table")
for field in ["event = ", "command = "]:
    if field not in kimi:
        fail(f"Kimi's hook block is missing {field.strip()}")
# The docs say an unknown field makes the whole file fail to load, so anything
# beyond the documented four is a bug rather than a harmless extra.
for line in kimi.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("["):
        continue
    key = stripped.split("=", 1)[0].strip()
    if key not in ("event", "command", "matcher", "timeout"):
        fail(f"Kimi's block has an undocumented field {key!r}, which makes the config fail to load")

# --- Antigravity -----------------------------------------------------------
anti = read_json(os.path.join(home, ".gemini", "config", "hooks.json"))
if "cqutmux" not in anti:
    fail("Antigravity's hooks are not under a named hook object")
else:
    if "PreToolUse" not in anti["cqutmux"]:
        fail("Antigravity has no PreToolUse hook")
    elif not anti["cqutmux"]["PreToolUse"][0].get("hooks"):
        fail("Antigravity's PreToolUse has no handler array")
    if "PostInvocation" not in anti["cqutmux"]:
        fail("Antigravity has no PostInvocation hook (its turn-complete event)")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: every agent's file matches the format that agent documents")
PY

echo "==> re-running install leaves nothing doubled"
run install > /dev/null
python3 - "$FAKE_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
problems = []
claude = json.load(open(os.path.join(home, ".claude", "settings.json")))
for event, groups in claude["hooks"].items():
    ours = [g for g in groups if "claude-code-hook" in json.dumps(g)]
    if len(ours) > 1:
        problems.append(f"Claude Code's {event} has {len(ours)} of our hooks after a re-run")
cursor = json.load(open(os.path.join(home, ".cursor", "hooks.json")))
for event, entries in cursor["hooks"].items():
    ours = [e for e in entries if "agent-hook.mjs" in json.dumps(e)]
    if len(ours) > 1:
        problems.append(f"Cursor's {event} has {len(ours)} of our hooks after a re-run")
kimi = open(os.path.join(home, ".kimi-code", "config.toml")).read()
if kimi.count("[[hooks]]") != 2:
    problems.append(f"Kimi has {kimi.count('[[hooks]]')} hook blocks after a re-run, expected 2")
if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: a second install updates in place rather than stacking duplicates")
PY

echo "==> a user's own hook survives"
python3 - "$FAKE_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
path = os.path.join(home, ".claude", "settings.json")
settings = json.load(open(path))
settings["hooks"]["PreToolUse"].insert(0, {
    "matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-own-linter"}],
})
settings["hooks"]["SessionStart"] = [{"hooks": [{"type": "command", "command": "/usr/local/bin/hello"}]}]
json.dump(settings, open(path, "w"), indent=2)
PY
run install > /dev/null
python3 - "$FAKE_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
settings = json.load(open(os.path.join(home, ".claude", "settings.json")))
problems = []
if not any("my-own-linter" in json.dumps(g) for g in settings["hooks"]["PreToolUse"]):
    problems.append("the user's own PreToolUse hook was dropped by a re-install")
if "SessionStart" not in settings["hooks"]:
    problems.append("an event we do not touch was removed")
if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: hooks that are not ours are left exactly where they were")
PY

echo "==> uninstall removes only ours"
run uninstall > "$OUT/uninstall.log" || { echo "FAIL: uninstall exited non-zero"; cat "$OUT/uninstall.log"; exit 1; }
python3 - "$FAKE_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
problems = []


def text(path):
    try:
        return open(path).read()
    except Exception:
        return ""


for name, path in [
    ("Claude Code", ".claude/settings.json"),
    ("Codex", ".codex/hooks.json"),
    ("Cursor", ".cursor/hooks.json"),
    ("Antigravity", ".gemini/config/hooks.json"),
]:
    body = text(os.path.join(home, path))
    if "agent-hook.mjs" in body or "claude-code-hook" in body:
        problems.append(f"{name}'s bridge is still referenced in {path} after uninstall")
    if not body:
        problems.append(f"{name}'s {path} disappeared entirely — the user's file should remain")

kimi = text(os.path.join(home, ".kimi-code", "config.toml"))
if "[[hooks]]" in kimi:
    problems.append("Kimi still has a hook block after uninstall")

settings = json.load(open(os.path.join(home, ".claude", "settings.json")))
if not any("my-own-linter" in json.dumps(g) for g in settings.get("hooks", {}).get("PreToolUse", [])):
    problems.append("uninstall removed the user's own hook along with ours")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: uninstall removes every hook we wrote and nothing else")
PY

echo "==> the shared bridge turns five payload shapes into one event"
# The field names are the whole reason the Node bridge exists. Each of these is
# a documented payload from a different agent, and all five must produce the
# same kind of event.
start_gateway() {
  HOME="$FAKE_HOME" node host/cqutmux-hook/index.mjs --port 24999 --token t \
    >"$OUT/gw.log" 2>&1 &
  GW=$!
  sleep 2
}
start_gateway
trap 'kill ${GW:-0} 2>/dev/null || true; rm -rf "$OUT"' EXIT

bridge_case() {
  local name="$1" source="$2" kind="$3" payload="$4"
  # HOME must match the gateway's, because that is where the token is published.
  # Running these without it is how the token hole was found: the gateway had a
  # token, the bridge did not send one, and the event was refused with a 401
  # nothing surfaced.
  printf '%s' "$payload" | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    node host/cqutmux-hook/agent-hook.mjs "$source" "$kind"
}

bridge_case "Claude Code" claude-code approval \
  '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}'
bridge_case "Codex" codex notice \
  '{"session_id":"s2","last_assistant_message":"all done"}'
bridge_case "Cursor" cursor approval \
  '{"conversation_id":"s3","toolName":"Shell","toolInput":{"command":"ls"}}'
bridge_case "Kimi" kimi approval \
  '{"session_id":"s4","tool_name":"Bash","tool_input":"echo hi"}'
bridge_case "Antigravity" antigravity notice \
  '{"conversationId":"s5","lastAssistantMessage":"finished"}'

# The shell bridge takes the same path, and it is the one every existing Claude
# Code install already has wired up. Checked here rather than trusted because it
# is a separate program with its own curl invocation, and it is the one that
# would have kept the hole open if only the Node bridge had been fixed.
printf '%s' '{"session_id":"s6","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    bash host/cqutmux-hook/claude-code-hook.sh approval

python3 - <<'PY'
import json, urllib.request

request = urllib.request.Request(
    "http://127.0.0.1:24999/events", headers={"Authorization": "Bearer t"})
events = json.load(urllib.request.urlopen(request))
if isinstance(events, dict):
    events = events.get("events", [])

by_source = {}
for event in events:
    by_source.setdefault(event.get("source"), []).append(event)

problems = []
for source in ["claude-code", "codex", "cursor", "kimi", "antigravity"]:
    found = by_source.get(source)
    if not found:
        problems.append(f"{source} produced no event at all")
        continue
    event = found[-1]
    if not event.get("data", {}).get("session"):
        problems.append(f"{source}'s event lost the session id — the bridge did not find"
                        f" the field name for this agent (data: {event.get('data')})")
    if not event.get("body"):
        problems.append(f"{source}'s event has an empty body")

count = sum(len(v) for v in by_source.values())
if count < 6:
    problems.append(f"expected 6 events (five node bridges plus the shell one), got {count}")
if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: all five agents' payloads reach the gateway with a session and a body")
PY

echo ""
echo "AGENT_HOOKS_PASS  (formats, re-install, uninstall, and the shared bridge)"