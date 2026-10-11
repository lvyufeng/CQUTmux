import Foundation

// The Chat View's approval bar: which pending approval belongs to the session on
// screen, and that it is the Inbox's own event rather than a second copy.
//
// The selection fails quietly. Moshi puts the bar in the Chat View *in addition*
// to the Inbox — "Permission requests can appear in a floating approval bar with
// Approve and Deny" — and the buttons "act on the live session". So the one
// thing that must be right is *which* event the bar is about: show another
// session's approval and the user answers a decision they did not mean, which is
// the failure a second surface is one mistake away from and the reason this is
// checked here rather than looked at on a screen.
//
// `ChatApproval.swift` and `AgentEvent.swift` are Foundation-only, so this needs
// no simulator and no host.

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

/// The exact shape the gateway writes — `toISOString()`, milliseconds and all.
let wireDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func event(
    _ id: Int,
    kind: AgentEvent.Kind = .approval,
    source: String = "claude-code",
    title: String = "Bash",
    body: String? = #"{"command":"ls"}"#,
    session: String? = "s1",
    cwd: String? = nil,
    decision: String? = nil,
    options: [AgentEvent.Payload.Option] = []
) -> AgentEvent {
    var payload = AgentEvent.Payload(teammate: nil, session: nil, cwd: nil, for: nil, options: nil)
    payload.session = session
    payload.cwd = cwd
    if !options.isEmpty { payload.options = options }
    return AgentEvent(
        id: id,
        at: wireDate.string(from: base),
        source: source,
        kind: kind,
        title: title,
        body: body,
        decision: decision,
        answer: nil,
        data: payload
    )
}

// MARK: - A pending approval for the session on screen

// The join is the directory: the transcript is keyed by it and the event carries
// the agent's `cwd`, so an exact match is the session the user is reading.
let exact = ChatApproval.pending(
    in: [event(1, cwd: "/Users/me/work/api")], directory: "/Users/me/work/api"
)
check(exact?.id == 1, "the approval in the directory on screen is the one shown")

// A chat opened from a directory the user walked into is relative to "." — the
// Files browser's own base — while the event's cwd is absolute. Matching only on
// the exact string would leave the bar empty over a session that is plainly
// waiting, so the last path component is what the two agree on.
check(ChatApproval.pending(in: [event(1, cwd: "/Users/me/work/api")], directory: "api")?.id == 1,
      "a relative path matches the event's cwd by project name")
check(ChatApproval.pending(in: [event(1, cwd: "api")], directory: "/Users/me/work/api")?.id == 1,
      "and an absolute chat path matches a relative cwd the same way")

// The whole point of the join: an approval for a *different* session must not
// appear over this one. Showing it would let its decision be sent from a
// conversation it has nothing to do with.
check(ChatApproval.pending(in: [event(1, cwd: "/Users/me/work/web")], directory: "/Users/me/work/api") == nil,
      "another session's approval does not appear over this one")

// Two sessions can share a project name on different paths — two checkouts of
// the same repo — and the exact match has to win over the component match, or
// the bar could answer the wrong checkout's approval.
let twoCheckouts = [
    event(1, cwd: "/Users/me/one/api"),
    event(2, cwd: "/Users/me/two/api")
]
check(ChatApproval.pending(in: twoCheckouts, directory: "/Users/me/two/api")?.id == 2,
      "an exact path match beats a same-named project elsewhere")

// Newest wins, because a session can hold more than one pending event and the
// bar shows one: the latest is the one the user is looking at, the same rule the
// board's rows sort by.
let several = [
    event(1, cwd: "/w/api"),
    event(3, cwd: "/w/api"),
    event(2, cwd: "/w/api")
]
check(ChatApproval.pending(in: several, directory: "/w/api")?.id == 3,
      "the newest pending event for the session is shown")

// MARK: - Only what is still waiting

// An answered approval is not a request. `isPending` is the same test the Inbox
// draws its buttons on, so reading it here keeps the two surfaces from
// disagreeing about what still needs an answer.
check(ChatApproval.pending(in: [event(1, cwd: "/w/api", decision: "allow")], directory: "/w/api") == nil,
      "an approval that has been answered is not shown")

// A notice is not something to decide on, however recent.
check(ChatApproval.pending(in: [event(1, kind: .notice, cwd: "/w/api")], directory: "/w/api") == nil,
      "a notice is never an approval to show")

// MARK: - A question, not just an approval

// A question is pending the same way an approval is, and the bar has to carry
// it — its options are how it is answered, and dropping it would leave a
// question visible in the Inbox and invisible in the Chat View.
let question = event(1, title: "Which database?", body: "Pick one.", cwd: "/w/api",
                     options: [.init(label: "Postgres", value: "pg")])
let shown = ChatApproval.pending(in: [question], directory: "/w/api")
check(shown?.isQuestion == true, "a pending question is shown and stays a question")
check(shown?.options.first?.value == "pg", "and its options come through, so it can be answered")

// MARK: - The unknown directory

// The Terminal opens Chat with "." when it does not know the directory — the
// gateway's own cwd — and nothing in the event stream says which absolute path
// that is. A single pending is unambiguous, so it is shown; two are not, and the
// bar stays away rather than offering a coin flip between two sessions.
check(ChatApproval.pending(in: [event(7, cwd: "/w/whatever")], directory: ".")?.id == 7,
      "with an unknown directory a lone pending approval is shown")
check(ChatApproval.pending(in: [event(7, cwd: "/w/a")], directory: "")?.id == 7,
      "an empty directory is the same unknown, and shows the lone pending")
check(ChatApproval.pending(in: [event(1, cwd: "/w/a"), event(2, cwd: "/w/b")], directory: ".") == nil,
      "but with two pending and no directory, no bar — the choice cannot be made")
check(ChatApproval.pending(in: [event(1, cwd: nil), event(2, cwd: nil)], directory: "/w/a") == nil,
      "an event that reports no cwd cannot be matched to a known directory")

// Nothing pending at all is the common case, and it must be silent: the bar is
// an overlay, and an empty bar over a quiet conversation is a thing on screen
// that does nothing.
check(ChatApproval.pending(in: [], directory: "/w/a") == nil, "no events means no bar")
check(ChatApproval.pending(in: [event(1, kind: .notice, cwd: "/w/a")], directory: "/w/a") == nil,
      "no pending events means no bar")

// MARK: - The share: the Working indicator reads the same session

// The approval bar and the Working indicator both ask "what is this session's",
// and if they answered differently the screen would contradict itself — a
// spinner driven by one session's events while the bar offers another's request.
// `forSession` is the one selection; these pin that it agrees with the join the
// bar uses.
check(ChatApproval.forSession(in: [event(1, cwd: "/w/api")], directory: "/w/api").map(\.id) == [1],
      "forSession selects the events whose cwd is the chat's directory")
check(ChatApproval.forSession(in: [event(1, cwd: "/w/api"), event(2, cwd: "/w/web")],
                              directory: "/w/api").map(\.id) == [1],
      "and leaves another session's out")
check(ChatApproval.forSession(in: [event(1, cwd: "/w/api")], directory: ".").count == 1,
      "with no known directory every event is handed back")

// MARK: - The Working indicator

// "A Working indicator follows the active turn." Whether a turn is live is read
// off the newest event's category, and the three that mean "mid-turn" must not
// be confused with the three that mean "over" — a spinner that lingers over a
// finished session, or clears while the agent is still thinking, both read as
// the app disagreeing with the agent.
func classified(_ id: Int, _ category: AgentEvent.Category, cwd: String = "/w/api") -> AgentEvent {
    var e = event(id, kind: .notice, cwd: cwd)
    e.category = category.rawValue
    return e
}

check(ChatWorking.isWorking(in: [classified(1, .approvalRequired)], directory: "/w/api"),
      "a pending approval is the session working")
check(ChatWorking.isWorking(in: [classified(1, .toolRunning)], directory: "/w/api"),
      "so is a tool mid-flight")
check(ChatWorking.isWorking(in: [classified(1, .toolFinished)], directory: "/w/api"),
      "and a tool that returned but whose turn has not ended")
check(!ChatWorking.isWorking(in: [classified(1, .taskComplete)], directory: "/w/api"),
      "a finished turn is not working")
check(!ChatWorking.isWorking(in: [classified(1, .error)], directory: "/w/api"),
      "nor is a failed turn")
check(!ChatWorking.isWorking(in: [classified(1, .sessionStarted)], directory: "/w/api"),
      "nor has a session that only just started begun a turn")
check(!ChatWorking.isWorking(in: [], directory: "/w/api"),
      "no events at all is not working")

// Newest wins: a session that finished a turn after a tool ran is done, however
// recently the tool event arrived — reading any-but-newest would leave the
// spinner up over a finished session forever.
check(!ChatWorking.isWorking(in: [classified(1, .toolRunning), classified(2, .taskComplete)],
                             directory: "/w/api"),
      "the newest event decides — a later completion clears the spinner")
check(ChatWorking.isWorking(in: [classified(1, .taskComplete), classified(2, .toolRunning)],
                            directory: "/w/api"),
      "and a later tool start turns it back on")

// The same session join as the bar: another directory's activity must not light
// this session's spinner.
check(!ChatWorking.isWorking(in: [classified(1, .toolRunning, cwd: "/w/other")], directory: "/w/api"),
      "another session's activity does not show as this one working")

// MARK: - The jump-to-bottom trigger

// "If you scroll up, a jump-to-bottom control appears." The threshold is the
// rule that fails quietly: too eager and the control is up while the reader is
// at the bottom waiting for the answer; too lazy and they are stranded mid-log
// with no way back. Pinned as a function of the distance below the fold.
check(ChatScroll.follows(afterScrollDistance: 0), "at the bottom the view follows the newest turn")
check(ChatScroll.follows(afterScrollDistance: 10), "a small nudge still follows")
check(!ChatScroll.follows(afterScrollDistance: ChatScroll.followThreshold),
      "scrolling a full screen up stops following")
check(!ChatScroll.follows(afterScrollDistance: 500), "and far up certainly does")
check(ChatScroll.follows(afterScrollDistance: -20),
      "an overscroll past the end (negative distance) still follows")
// The boundary is exclusive on the threshold: exactly at it is no longer
// following, which is what makes the "appears" edge land in one place.
check(!ChatScroll.follows(afterScrollDistance: ChatScroll.followThreshold),
      "the threshold itself is the edge, not inside it")
check(ChatScroll.follows(afterScrollDistance: ChatScroll.followThreshold - 0.5),
      "and a hair inside it still follows")

if failures > 0 {
    print("\nCHAT_APPROVAL_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nCHAT_APPROVAL_PASS  (\(checks) checks)")