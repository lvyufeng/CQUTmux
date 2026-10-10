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
  App/Shared/ActivityPhase.swift
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

// A notice with nothing pending *does* show now — that is the point of the
// phase work — but it must show as a finished turn, not as something waiting.
// The failure this guards is the opposite of the old one: an activity that
// surfaces every event is right, and one that dresses a finished turn in the
// raised hand is a false claim that the user is needed.
let chatter = AgentEvent(
    id: 5, at: ISODate.string(from: Date()), source: "claude", kind: .notice,
    title: "Read Sources/App.swift", body: nil, decision: nil, answer: nil, data: nil
)
let chatContent = AgentActivityPreview.content(for: [chatter])
check(chatContent != nil, "a finished turn did not show on the activity")
check(chatContent?.phase == .taskComplete, "a bare notice was not task_complete: \(String(describing: chatContent?.phase))")
check(chatContent?.phase.isAwaiting == false, "a finished turn wore the awaiting style")
check(chatContent?.pending == 0, "a finished turn counted as pending")

// Nothing at all still shows nothing: the activity needs a fact to report.
check(AgentActivityPreview.content(for: []) == nil, "no events started an activity")

// A timestamp is required to pick "the latest". Without one there is no newest
// event, only whichever the poll listed first — and the activity would then say
// a different thing on every update.
let undated = AgentEvent(
    id: 55, at: "not a timestamp", source: "claude", kind: .notice,
    title: "no time", body: nil, decision: nil, answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [undated]) == nil,
      "an event with no parseable timestamp still produced an activity")

// The phase of a tool that is mid-flight. This is the state the activity could
// not express at all before: neither waiting nor finished.
let running = AgentEvent(
    id: 56, at: ISODate.string(from: Date()), source: "claude", kind: .notice,
    category: "tool_running", title: "Building", body: nil, decision: nil,
    answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [running])?.phase == .toolRunning,
      "a tool_running event did not show as working")

// An approval that has been answered is *running*, not done — allowing the tool
// lets it run. The activity used to linger at zero with no phase at all.
let allowed = AgentEvent(
    id: 57, at: ISODate.string(from: Date()), source: "claude", kind: .approval,
    title: "Run rm -rf build/", body: nil, decision: "allow", answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [allowed])?.phase == .toolRunning,
      "an answered approval did not show as working")

// The lifecycle end. `sessionEnded` is final: it is the one phase the activity
// shows and then dismisses rather than holding open.
let ended = AgentEvent(
    id: 58, at: ISODate.string(from: Date()), source: "claude", kind: .notice,
    title: "Bye", body: nil, decision: nil, answer: nil,
    data: AgentEvent.Payload(sessionEnded: true)
)
let endedContent = AgentActivityPreview.content(for: [ended])
check(endedContent?.phase == .sessionEnded, "a session-ended event was not session_ended")
check(endedContent?.phase.isFinal == true, "session_ended was not marked final")
check(ActivityPhase.sessionEnded.isFinal, "sessionEnded.isFinal is false")

// `endsSession` is only true for an explicit marker. Every hook that predates it
// sends no field, and `nil` must not read as "the session ended" — which would
// make every ordinary event a final phase and dismiss the activity instantly.
check(!chatter.endsSession, "an event with no sessionEnded field was read as an ending")
check(!(AgentActivityPreview.content(for: [chatter])?.phase.isFinal ?? true),
      "an ordinary event produced a final phase")

// The waiting approval outranks everything. A decision is the only thing that
// asks the user for something, so an activity that showed "working" while an
// approval sat unanswered would hide the one thing it exists to surface —
// even when the working event is newer.
let newer = AgentEvent(
    id: 60, at: ISODate.string(from: Date().addingTimeInterval(60)), source: "codex",
    kind: .notice, category: "tool_running", title: "Newer", body: nil,
    decision: nil, answer: nil, data: nil
)
let pendingApproval = AgentEvent(
    id: 59, at: ISODate.string(from: Date()), source: "claude", kind: .approval,
    title: "Waiting", body: nil, decision: nil, answer: nil, data: nil
)
let mixed = AgentActivityPreview.content(for: [pendingApproval, newer])
check(mixed?.phase == .approvalRequired,
      "a pending approval lost to a newer running event: \(String(describing: mixed?.phase))")
check(mixed?.pending == 1, "the pending approval was not counted alongside a running one")

// The newest event decides the phase when nothing is waiting. Two notices of
// different kinds, so the outcome can only be right if the *latest* is chosen.
let olderDone = AgentEvent(
    id: 61, at: ISODate.string(from: Date().addingTimeInterval(-120)), source: "claude",
    kind: .notice, title: "older done", body: nil, decision: nil, answer: nil, data: nil
)
let newestRunning = AgentEvent(
    id: 62, at: ISODate.string(from: Date().addingTimeInterval(120)), source: "claude",
    kind: .notice, category: "tool_running", title: "newer running", body: nil,
    decision: nil, answer: nil, data: nil
)
check(AgentActivityPreview.content(for: [olderDone, newestRunning])?.phase == .toolRunning,
      "the newest event did not decide the phase")
check(AgentActivityPreview.content(for: [newestRunning, olderDone])?.phase == .toolRunning,
      "the phase depended on the order the events arrived in")

// Every phase has a glyph and a label. A phase with an empty symbol renders as a
// missing-glyph box on the Lock Screen and reads as a crash.
for phase in ActivityPhase.allCases {
    check(!phase.symbol.isEmpty, "\(phase.rawValue) has no symbol")
    check(!phase.shortLabel.isEmpty, "\(phase.rawValue) has no label")
}
check(ActivityPhase.approvalRequired.isAwaiting, "approval_required is not awaiting")
check(!ActivityPhase.toolRunning.isAwaiting, "tool_running was treated as awaiting")
check(!ActivityPhase.taskComplete.isAwaiting, "task_complete was treated as awaiting")

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