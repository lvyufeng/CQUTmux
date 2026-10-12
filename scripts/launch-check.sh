#!/usr/bin/env bash
#
# Checks what a launch and a notification response do, without a simulator.
#
# Three failures live here, and none of them looks like a failure from the
# outside. A tap on a notification that carries no routing opens the app on
# whatever tab it was last left on — indistinguishable from a tap the user
# never made, while the approval the notification was about waits behind a tab
# nobody opened. A cold launch that reconnects nothing is indistinguishable
# from a feature that was never built. A "pause notifications" switch that
# silences pushes and leaves local banners arriving reads as a broken switch,
# because both paths cover the same approvals.
#
# The decisions are in `LaunchRouting.swift` — Foundation plus the two
# `UserNotifications` action constants, no SwiftUI and no UIKit — so this
# compiles them straight from the app target under `swiftc` and drives every
# rule with constructed hosts and payloads. `scripts/launch/main.swift` is the
# harness; it also fails to compile if a SwiftUI type ever creeps into those
# decisions, which is the honest outcome: they could no longer be checked apart
# from the view.
#
# The remaining lines check the *call sites*, because a correct rule nobody
# calls is exactly the state this check was written to catch: the reconnect
# decision existed as a function before anything in the shell used one, and the
# pause rule was read by the remote path alone.
#
# Usage: scripts/launch-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Hosts/Host.swift" \
  "$ROOT/App/Features/Terminal/DeepLink.swift" \
  "$ROOT/App/Shared/ISODate.swift" \
  "$ROOT/App/Features/Agents/AgentEvent.swift" \
  "$ROOT/App/Features/Agents/LaunchRouting.swift" \
  "$ROOT/scripts/launch/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "LAUNCH_BUILD_FAIL"; exit 1; }
"$OUT/check"

# Each of these is a wire between a pure decision and the code that acts on it,
# and every one of them is silent when it breaks: the app runs, nothing throws,
# and the tap or the launch simply does what it did before.
pass=0
fail=0
check() {
  if [[ "$2" == "1" ]]; then
    echo "PASS  $1"
    pass=$((pass + 1))
  else
    echo "FAIL  $1"
    fail=$((fail + 1))
  fi
}
has() { grep -q "$1" "$ROOT/$2" && echo 1 || echo 0; }

APP="$ROOT/App/CQUTmuxApp.swift"
DELEGATE="$ROOT/App/Features/Agents/AppDelegate.swift"
MANAGER="$ROOT/App/Features/Agents/NotificationManager.swift"
ROOTVIEW="$ROOT/App/Features/RootView.swift"

check "the launch decides the reconnect through LaunchConnect.action" \
  "$(has 'LaunchConnect.action' App/CQUTmuxApp.swift)"
check "the host connect records the last host" \
  "$(has 'LastHost.record(host)' App/Features/Agents/AgentConnection.swift)"
# The launch hands the link over *as a link*, not as a nil test. An earlier
# call site passed `hasLink: launchLink != nil`, which is the same answer for
# every URL and so cannot distinguish a session link from a notification tap —
# the two cases that need opposite handling. Both halves are asserted, because
# the call site compiling is what makes the routing above reachable.
check "the launch hands the link itself to the reconnect decision" \
  "$(has 'launching: launchLink' App/CQUTmuxApp.swift)"
check "the destination test lives on the target, not at the call site" \
  "$(has 'var namesDestination: Bool' App/Features/Terminal/DeepLink.swift)"

check "a response is routed through NotificationRouting.route" \
  "$(has 'NotificationRouting.route' App/Features/Agents/AppDelegate.swift)"
check "a tap hands over its link for the views to open" \
  "$(has 'OpenLink.shared.deliver' App/Features/Agents/AppDelegate.swift)"
check "the app takes that link before the views exist" \
  "$(has 'OpenLink.shared.take()' App/CQUTmuxApp.swift)"
check "the link reaches the same handler a pasted link does" \
  "$(has 'handle(launchLink)' App/Features/RootView.swift)"
# The second reader. `init` runs once per process, so a stash only it reads is
# one that silently drops every tap on an app that is already running — which
# is the common case for a banner tapped from the Lock Screen. The shell has to
# listen for the announcement, or the delegate hands the URL to nobody.
check "a running app is told when a link is handed over" \
  "$(has 'publisher(for: OpenLink.delivered)' App/Features/RootView.swift)"

# The pause, read by both paths. The remote half is the presentation decision;
# the local half is the filter in `notify`, which is where the gap was — it
# posted regardless of the switch.
check "the remote path presents through NotificationRouting.mayPresent" \
  "$(has 'NotificationRouting.mayPresent' App/Features/Agents/AppDelegate.swift)"
check "the local banner path reads the same pause rule" \
  "$(has 'NotificationRouting.localNotifications' App/Features/Agents/NotificationManager.swift)"

# The category identifier is a wire between the host and the app, and it is the
# one where a rename is invisible: the banner still arrives, it just has no
# Allow/Deny buttons, and nothing reports that. Both sides are read here rather
# than trusted to have been kept in step.
HOST_PUSH="$ROOT/host/cqutmux-hook/push.mjs"
SWIFT_CATEGORY="$(grep -oE 'category = "[A-Z_]+"' "$ROOT/App/Features/Agents/LaunchRouting.swift" | head -1 | grep -oE '"[A-Z_]+"' | tr -d '"')"
HOST_CATEGORY="$(grep -oE "category: '[A-Z_]+'" "$HOST_PUSH" | head -1 | grep -oE "'[A-Z_]+'" | tr -d "'")"
if [[ -n "$SWIFT_CATEGORY" && "$SWIFT_CATEGORY" == "$HOST_CATEGORY" ]]; then
  echo "PASS  the approval category is the one the gateway sends ($HOST_CATEGORY)"
  pass=$((pass + 1))
else
  echo "FAIL  the approval category is the one the gateway sends ('$SWIFT_CATEGORY' vs '$HOST_CATEGORY')"
  fail=$((fail + 1))
fi

# No reply action is registered, deliberately, and this is the evidence it rests
# on: nothing on the host reads a free-text answer. `POST /approve/:id` accepts
# any string for `answer` (index.mjs:1349) but no agent process ever reads it
# back — the agent-side hooks (`claude-code-hook.sh`, `agent-hook.mjs`) post
# once and exit, so a typed reply would be stored and displayed and never
# delivered. Offering the button would take the user's text and drop it.
#
# What the guard looks for is the mechanism, not a name: iOS builds a reply
# from `UNTextInputNotificationAction`, and the only actions registered are the
# two plain `UNNotificationAction`s above. That is checkable and a rename cannot
# dodge it — an earlier version of this check grepped the gateway for a
# `CQUT_REPLY` token that file has no reason to contain, which passed for the
# wrong reason and would not have caught a real reply action at all.
check "no reply action is registered (the host could not deliver one)" \
  "$([[ "$(grep -c 'UNTextInputNotificationAction' "$ROOT/App/Features/Agents/PushRegistration.swift" || true)" == "0" ]] && echo 1 || echo 0)"
# And the two actions that *are* registered are the plain ones, so the guard
# above cannot be satisfied by deleting the category and nothing else.
check "the registered actions are the plain Allow/Deny pair" \
  "$([[ "$(grep -c 'UNNotificationAction(' "$ROOT/App/Features/Agents/PushRegistration.swift" || true)" == "2" ]] && echo 1 || echo 0)"

echo
if (( fail > 0 )); then
  echo "LAUNCH_CALLSITE_FAIL  ($fail of $((pass + fail)) call-site checks failed)"
  exit 1
fi
echo "LAUNCH_CALLSITE_PASS  ($pass call-site checks)"
