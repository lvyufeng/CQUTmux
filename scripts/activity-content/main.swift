import Foundation

// What the Live Activity's buttons actually answer.
//
// The widget draws Allow/Deny only while an approval is waiting, and the id it
// puts on them has to name *that* approval — the one whose title is beside it.
// Both halves of a wrong answer are invisible: a button that carries 0 decides
// nothing (or, worse, the host reads it as a malformed id), and a button whose
// id belongs to a different event than the title shown makes the user answer a
// prompt they never read. `AgentActivityPreview` is Foundation-only and decides
// both, so the rule runs here without a device or ActivityKit.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

let base = Date(timeIntervalSince1970: 1_700_000_000)
func at(_ offset: TimeInterval) -> String { ISODate.string(from: base.addingTimeInterval(offset)) }

func event(
    _ id: Int,
    _ kind: AgentEvent.Kind,
    source: String = "claude-code",
    title: String? = nil,
    decision: String? = nil,
    seconds: TimeInterval = 0,
    category: String? = nil
) -> AgentEvent {
    AgentEvent(id: id, at: at(seconds), source: source, kind: kind, category: category,
               title: title, body: nil, decision: decision, answer: nil, data: nil)
}

// MARK: - A waiting approval names itself

let waiting = event(41, .approval, title: "Run rm -rf build/")
if let content = AgentActivityPreview.content(for: [waiting]) {
    check(content.phase == .approvalRequired, "a pending approval puts the activity in the asking phase")
    check(content.pending == 1, "and is counted")
    // The id the widget's buttons carry. Without it a tap cannot name what it
    // answered; with the wrong one it answers something else.
    check(content.eventID == 41, "and the id it carries is that approval's")
} else {
    check(false, "a pending approval produces content")
}

// Two waiting approvals: the count is both, the id is the one whose title is
// shown. Getting this wrong is the "decide what you did not read" bug.
let first = event(50, .approval, source: "claude-code", title: "First prompt", seconds: 1)
let second = event(51, .approval, source: "codex", title: "Second prompt", seconds: 2)
if let content = AgentActivityPreview.content(for: [second, first]) {
    check(content.pending == 2, "two waiting approvals are counted twice")
    // Which of the two is named is array order, not age — the check below is
    // the one that matters: whichever is picked, the id and the text are the
    // same event. Pinning 51 here records that the rule is "first listed".
    check(content.eventID == 51, "the id shown is the first pending approval listed")
    // The pairing the whole thing rests on: the id and the title must describe
    // one event. Pinned by identity, not by trusting the copy.
    let named = [second, first].first { $0.id == content.eventID }
    check(named?.displayTitle == content.title, "and that id names the event whose title is displayed")
    check(named?.sourceLabel == content.source, "and whose agent is displayed")
} else {
    check(false, "two pending approvals produce content")
}

// MARK: - A phase that asks nothing carries no id

// An approval that is already resolved is not pending, so it is `toolRunning`
// and nothing is being asked. A leftover id here would draw buttons for a
// question the user already answered.
let answered = event(60, .approval, title: "Already answered", decision: "allow", seconds: 3)
if let content = AgentActivityPreview.content(for: [answered]) {
    check(content.phase == .toolRunning, "a resolved approval is the working phase")
    check(content.pending == 0, "with nothing waiting")
    check(content.eventID == 0, "and no id for a button to carry")
} else {
    check(false, "a resolved approval still produces content")
}

// A finished turn: content, but nothing to answer.
if let content = AgentActivityPreview.content(for: [event(70, .notice, title: "Done", seconds: 4)]) {
    check(content.phase == .taskComplete, "a notice is the done phase")
    check(content.eventID == 0, "and carries no approval id")
} else {
    check(false, "a notice produces content")
}

// MARK: - The invariant the widget's guard depends on

// `CQUTMuxWidgets` draws the buttons only while `phase.isAwaiting` *and*
// `latestEvent > 0`. If content could ever say "awaiting" with a zero id, the
// buttons would silently never appear; if it could carry a positive id while
// not awaiting, every tap would answer a stale approval. So the two must be the
// same fact, and this is the check that keeps them one.
let fixtures: [[AgentEvent]] = [
    [waiting],
    [second, first],
    [answered],
    [event(70, .notice, title: "Done", seconds: 4)],
    [answered, second],
    AgentActivityPreview.sampleEvents(now: base),
]
for (index, events) in fixtures.enumerated() {
    guard let content = AgentActivityPreview.content(for: events) else {
        check(false, "fixture \(index) produces content")
        continue
    }
    let asks = content.phase.isAwaiting
    check((content.eventID != 0) == asks,
          "fixture \(index): a non-zero id appears exactly when the phase asks")
    if asks {
        check(content.pending > 0, "fixture \(index): an asking phase has something waiting")
    }
    // The widget's guard is `> 0`, not `!= 0`, and this is the difference it
    // buys: the demo's fake negative ids draw no buttons, so a tap on the
    // Settings preview can never answer a real approval on the host.
    if content.eventID < 0 {
        check(index == fixtures.count - 1, "fixture \(index): only the demo carries a fake id")
    }
}

// MARK: - The newest event decides when nothing is waiting

// Two finished events, out of order: the phase and the text come from the newer
// one. Picking by array position would show whatever the poll happened to list
// first, so the activity would say something different on every update.
let older = event(80, .notice, title: "Older", seconds: 1)
let newer = event(81, .notice, title: "Newer", seconds: 9)
if let content = AgentActivityPreview.content(for: [newer, older]) {
    check(content.title == "Newer", "the newest event supplies the title")
} else {
    check(false, "two notices produce content")
}

// MARK: - When there is nothing to say

check(AgentActivityPreview.content(for: []) == nil, "no events means no activity")

// An event with no parseable timestamp cannot be ordered, so "the newest" would
// be arbitrary. Better to show nothing than to flicker between two claims.
let undated = AgentEvent(id: 90, at: "not-a-date", source: "claude-code", kind: .notice,
                         category: nil, title: "Undated", body: nil, decision: nil,
                         answer: nil, data: nil)
check(AgentActivityPreview.content(for: [undated]) == nil,
      "an event that cannot be placed in time produces nothing")

// But a *waiting* approval is shown regardless of its clock: it asks for an
// answer, and dropping it because its timestamp is unreadable would hide the
// one thing the activity exists for.
let undatedApproval = AgentEvent(id: 91, at: "not-a-date", source: "claude-code",
                                 kind: .approval, category: nil, title: "Unreadable clock",
                                 body: nil, decision: nil, answer: nil, data: nil)
if let content = AgentActivityPreview.content(for: [undatedApproval]) {
    check(content.phase == .approvalRequired, "an undated approval is still raised")
    check(content.eventID == 91, "and still names itself")
} else {
    check(false, "an undated approval is not dropped")
}

// MARK: - The test button

// The Settings "Test Live Activity" button builds its state through this same
// function, so the demo cannot show a shape the real one would not. Its events
// are fake and carry negative ids, which is deliberate: a positive id would
// name a *real* approval on the host, and a tap on the demo would answer it.
// The consequence — the demo has no buttons — falls out of the two rules
// meeting, and is pinned here so it stays a decision rather than an accident.
let sample = AgentActivityPreview.content(for: AgentActivityPreview.sampleEvents(now: base))
if let sample {
    check(sample.pending == 2, "the demo shows two waiting approvals")
    check(sample.eventID < 0, "and its approval id is a fake, not a real one")
    check(!(sample.eventID > 0), "so the demo draws no buttons a tap could send")
    check(sample.phase.isAwaiting, "even though it is an asking phase")
} else {
    check(false, "the demo produces content")
}

if failures > 0 {
    print("\nACTIVITY_CONTENT_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nACTIVITY_CONTENT_PASS  (\(checks) checks)")
