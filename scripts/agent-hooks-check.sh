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

# Three more events exist only to carry a category. Without them the Inbox can
# never show `tool_finished` or `session_started` for Claude at all — two of
# Moshi's five row states would be unreachable from a real install, and the
# board would look complete while missing them. Asserted by the argument the
# bridge is invoked with, because a hook that calls the bridge with the wrong
# kind is installed and produces the wrong category forever.
for event, argument in [("PostToolUse", "tool-finish"), ("SessionStart", "session-start")]:
    if event not in hooks:
        fail(f"Claude Code has no {event} hook, so its category can never be shown")
    elif argument not in json.dumps(hooks[event]):
        fail(f"Claude Code's {event} does not call the bridge with `{argument}`:"
             f" {json.dumps(hooks[event])}")

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

# Each agent's documented payload, with the event name the agent really fires:
# the bridge reads the category off that name where it is present, so a payload
# without one is the fallback path and is what the Kimi case below covers.
bridge_case "Claude Code" claude-code approval \
  '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}'
bridge_case "Codex" codex notice \
  '{"hook_event_name":"Stop","session_id":"s2","last_assistant_message":"all done"}'
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

# The three ways a tool's *end* reaches us, because they are three different
# programs reading three different payloads and any one of them being wrong
# shows a finished tool call as a finished task: the node bridge told the kind
# with no event name to read, the node bridge given the agent's own event name,
# and the shell bridge's own kind.
printf '%s' '{"session_id":"s7","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    node host/cqutmux-hook/agent-hook.mjs codex tool-finish
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s8","tool_name":"Bash"}' \
  | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    node host/cqutmux-hook/agent-hook.mjs codex notice
printf '%s' '{"session_id":"s9","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    bash host/cqutmux-hook/claude-code-hook.sh tool-finish

# And the one category nothing else can produce: a session beginning.
printf '%s' '{"session_id":"s10"}' \
  | HOME="$FAKE_HOME" CQUTMUX_PORT=24999 \
    bash host/cqutmux-hook/claude-code-hook.sh session-start

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
    # The newest event *with a body*: the `session-start` kind is deliberately
    # bodyless (there is nothing to say yet), and it is the newest claude-code
    # event by the time the shell cases run.
    with_body = [e for e in found if e.get("body")]
    if not with_body:
        problems.append(f"{source} produced no event with a body")
        continue
    event = with_body[-1]
    if not event.get("data", {}).get("session"):
        problems.append(f"{source}'s event lost the session id — the bridge did not find"
                        f" the field name for this agent (data: {event.get('data')})")
    if not event.get("body"):
        problems.append(f"{source}'s event has an empty body")

count = sum(len(v) for v in by_source.values())
if count < 10:
    problems.append(f"expected 10 events (five node bridges plus five shell/kind ones), got {count}")

# Every category, on the session that was sent to produce it. Checked by session
# rather than by source: several of these come from the same agent, and the
# point is which event produced which category, not who sent it.
expected_category = {
    "s1": "approval_required",   # PreToolUse, named by the agent's payload
    "s2": "task_complete",       # Stop, named by the agent's payload
    "s3": "approval_required",   # approval kind, no event name to read
    "s4": "approval_required",
    "s5": "task_complete",       # notice kind, no event name to read
    "s6": "approval_required",   # the shell bridge's `approval`
    "s7": "tool_finished",       # the node bridge's `tool-finish`, no event name
    "s8": "tool_finished",       # PostToolUse, named by the agent's payload
    "s9": "tool_finished",       # the shell bridge's `tool-finish`
    "s10": "session_started",    # the shell bridge's `session-start`
}
seen = {}
for event in events:
    session = (event.get("data") or {}).get("session")
    if session in expected_category:
        seen[session] = event.get("category")
for session, want in sorted(expected_category.items()):
    got = seen.get(session)
    if got != want:
        problems.append(f"session {session} produced category {got!r}, expected {want!r}")

covered = set(seen.values())

# `tool_running` is the one no bridge kind produces: it is what the *gateway*
# says when an approval is answered, meaning "the tool it was guarding is now
# let through". Resolving one here proves that half of the mapping too, and it
# is the half the phone cannot derive for an approval answered on the watch or
# by a timeout — there the only thing that arrives is this notice.
approval_id = None
for event in events:
    if (event.get("data") or {}).get("session") == "s1":
        approval_id = event.get("id")
if approval_id is None:
    problems.append("no approval to resolve, so tool_running could not be checked")
else:
    resolve = urllib.request.Request(
        f"http://127.0.0.1:24999/approve/{approval_id}",
        data=json.dumps({"decision": "allow"}).encode(),
        headers={"Authorization": "Bearer t", "content-type": "application/json"},
    )
    urllib.request.urlopen(resolve).read()
    after = json.load(urllib.request.urlopen(request))
    if isinstance(after, dict):
        after = after.get("events", [])
    notices = [e for e in after if (e.get("data") or {}).get("for") == approval_id]
    if not notices:
        problems.append("resolving an approval produced no notice")
    elif notices[-1].get("category") != "tool_running":
        problems.append("the resolution notice is not tool_running:"
                        f" {notices[-1].get('category')!r}, so answering an approval"
                        " files the row as finished instead of in progress")
    else:
        covered.add("tool_running")

# All five reachable, as a set. The per-session checks above can each pass while
# the set is short — one wrong mapping and one missing kind would cancel out.
missing = {"approval_required", "task_complete", "session_started",
           "tool_running", "tool_finished"} - covered
if missing:
    problems.append(f"these categories are unreachable from a real bridge: {sorted(missing)}")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}")
    raise SystemExit(1)
print("PASS: all five agents' payloads reach the gateway with a session and a body")
PY

echo ""
echo "AGENT_HOOKS_PASS  (formats, re-install, uninstall, and the shared bridge)"