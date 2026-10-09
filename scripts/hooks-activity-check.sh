#!/usr/bin/env bash
#
# Checks the Live Activity settings and the decision behind the activity.
#
# Usage: scripts/hooks-activity-check.sh
#
# What is asserted
# ----------------
# 1. An absent preference reads as *on*. This is the one that matters: the
#    screen is a switch, and a switch that is off on a device that has never
#    opened it means the feature is off until the user goes and finds it.
#    `bool(forKey:)` cannot tell "never set" from "set to false", which is
#    exactly how a default becomes an off switch.
# 2. An explicit off survives, and both keys are independent.
# 3. `AgentActivityPreview.content` decides the activity: pending approvals
#    count (including plural), a resolved approval lingers with 0 rather than
#    blinking out, and a plain notice produces *nothing* — the activity is for
#    something waiting, and badging the Lock Screen for chatter is a false
#    claim that the user is needed.
# 4. The sample events the Settings test button shows parse with `ISODate`.
#    A locally built timestamp that parses to nil renders as a blank time, and
#    the test would then be demonstrating a broken activity.
# 5. Neither the app nor the widget swallows the one error this feature can
#    throw. `Activity.request` fails with "Target does not include
#    NSSupportsLiveActivities plist key" when the key is missing, and the
#    original `try?` means that failure produced no activity, no error, and no
#    log — a Live Activity that had never once worked and looked implemented.
#    The plist key is asserted here too, since that is what the throw is about.
#
# `AgentActivitySettings.swift` and `AgentActivityPreview.swift` import only
# Foundation, so they are run here directly through the Swift interpreter with
# the two pure files they depend on — the decision is checked, not a copy of it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PURE_FILES=(
  App/Shared/ISODate.swift
  App/Features/Agents/AgentEvent.swift
  App/Features/Agents/AgentActivityPreview.swift
  App/Features/Agents/AgentActivitySettings.swift
)

# The pure half must stay pure, or the check silently starts needing UIKit.
for file in "${PURE_FILES[@]}"; do
  if grep -qE '^import ' "$file" | grep -qv '^import Foundation$'; then
    echo "FAIL: $file imports something beyond Foundation:"
    grep -E '^import ' "$file" | grep -v '^import Foundation$'
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> checking the Live Activity settings and what the activity shows"
for file in "${PURE_FILES[@]}"; do
  cat "$file" >> "$WORK/main.swift"
  printf '\n' >> "$WORK/main.swift"
done
cat >> "$WORK/main.swift" <<'SWIFT'

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

// A scratch suite, so the check cannot pass because of what is on this Mac and
// cannot leave anything behind.
let suite = "cqutmux.check.activity"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

// 1. Never set means on. Both keys, because they are separate reads.
defaults.removePersistentDomain(forName: suite)
check(AgentActivitySettings.isEnabled(in: defaults), "an unset Live Activity preference was off")
check(AgentActivitySettings.opensInboxOnTap(in: defaults), "an unset open-inbox preference was off")

// 2. Explicit values stick, and the two do not move together.
AgentActivitySettings.setEnabled(false, in: defaults)
check(!AgentActivitySettings.isEnabled(in: defaults), "an explicit off did not stick")
check(AgentActivitySettings.opensInboxOnTap(in: defaults),
      "turning the activity off also changed the tap destination")
AgentActivitySettings.setOpensInboxOnTap(false, in: defaults)
check(!AgentActivitySettings.opensInboxOnTap(in: defaults), "an explicit off did not stick")
AgentActivitySettings.reset(in: defaults)
check(AgentActivitySettings.isEnabled(in: defaults), "reset did not return to the default")

// 3. What the activity shows.
let sample = AgentActivityPreview.sampleEvents()
let content = AgentActivityPreview.content(for: sample)
check(content != nil, "two pending approvals produced no activity content")
check(content?.pending == 2, "two pending approvals counted \(content?.pending ?? -1)")
check(content?.summary.contains("2 approvals waiting") == true,
      "the summary does not say two approvals: \(content?.summary ?? "nil")")

// One approval, singular. The plural and the count have to be derived, not
// hardcoded, or the test activity would look right for the wrong reason.
let one = [sample[0]]
check(AgentActivityPreview.content(for: one)?.summary.contains("1 approval waiting") == true,
      "a single approval did not read as singular")

// Nothing pending, nothing decided: no activity. This is the case an
// activity-per-event implementation gets wrong, badging the Lock Screen for an
// event that asks nothing of the user.
let chatter = AgentEvent(
    id: 5, at: ISODate.string(from: Date()), source: "claude", kind: .notice,
    title: "Read Sources/App.swift", body: nil, decision: nil, answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [chatter]) == nil,
      "a notice with nothing pending started an activity")
check(AgentActivityPreview.content(for: []) == nil, "no events started an activity")

// A resolved approval lingers at zero rather than vanishing: blinking out
// mid-answer looks like the app forgot what it was showing.
let resolved = AgentEvent(
    id: 6, at: ISODate.string(from: Date()), source: "claude", kind: .approval,
    title: "Run rm -rf build/", body: nil, decision: "allow", answer: nil, data: nil
)
let after = AgentActivityPreview.content(for: [resolved])
check(after != nil, "a resolved approval ended the activity instead of lingering")
check(after?.pending == 0, "a resolved approval still counted as pending")

// An empty title is a word, not a blank line: a blank on the Lock Screen reads
// as a rendering bug rather than a field the agent did not send.
let untitled = AgentEvent(
    id: 7, at: ISODate.string(from: Date()), source: "claude", kind: .approval,
    title: nil, body: nil, decision: nil, answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [untitled])?.title == "Agent",
      "an approval with no title left the activity blank")

// 4. The sample events the test button shows must survive the app's own parser.
// A Date description is not an ISO timestamp, and one that parses to nil shows
// a blank time — the test would be demonstrating a broken activity.
for event in sample {
    check(ISODate.parse(event.at) != nil,
          "a sample event's timestamp does not parse: \(event.at)")
}

// And the ids are negative on purpose: a real event id comes from the gateway
// and is positive, so a sample can never be mistaken for one the host sent.
check(sample.allSatisfy { $0.id < 0 }, "a sample event used a real event id")

print("PASS: defaults, both toggles, and what the activity shows")
SWIFT

swift "$WORK/main.swift"

echo "==> checking the plist key and that the request error is not swallowed"

# The key that makes `Activity.request` succeed. XcodeGen writes App/Info.plist
# from project.yml, so the assertion is against project.yml — the file a hand
# edit to the plist would not survive.
grep -q 'NSSupportsLiveActivities: true' project.yml || {
  echo "FAIL: project.yml is missing NSSupportsLiveActivities: true"
  echo "      Activity.request throws without it and no activity is ever started."
  exit 1
}

# A `try?` on the request is the exact shape of the bug: the error is discarded
# where it happens and nothing downstream can report it.
if grep -qE 'try\? *Activity\.request' App/Features/Agents/ActivityManager.swift; then
  echo "FAIL: Activity.request's error is discarded with try?"
  exit 1
fi
grep -q 'catch {' App/Features/Agents/ActivityManager.swift || {
  echo "FAIL: ActivityManager does not catch Activity.request's error"
  exit 1
}

echo "HOOKS_ACTIVITY_PASS"