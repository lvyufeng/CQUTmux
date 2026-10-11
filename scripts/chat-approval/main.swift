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

if failures > 0 {
    print("\nCHAT_APPROVAL_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nCHAT_APPROVAL_PASS  (\(checks) checks)")