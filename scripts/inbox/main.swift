import Foundation

// The Inbox board: which column a row lands in, when it archives, and what
// merges into what.
//
// Every rule here fails quietly. A row in the wrong column, or archived a
// minute early, is not a crash — it is an inbox that is missing the thing the
// user was waiting for, and the user finds out by not being told. That is the
// one failure a notification surface cannot have, so the rules are checked
// against constructed events rather than looked at on a screen.
//
// `InboxBoard.swift` and `AgentEvent.swift` are Foundation-only, so this needs
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
/// Building these with a bare formatter rather than reusing `ISODate` matters:
/// the parse side is the one under test, and a fixture produced by it could not
/// fail.
let wireDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// An event dated `age` seconds before "now", the way the gateway writes one.
func event(
    _ id: Int,
    age: TimeInterval,
    kind: AgentEvent.Kind = .notice,
    source: String = "claude-code",
    title: String = "Task finished",
    session: String? = "s1",
    cwd: String? = nil,
    decision: String? = nil,
    decisionAt: TimeInterval? = nil,
    options: [AgentEvent.Payload.Option] = [],
    resolves: Int? = nil,
    teammate: String? = nil
) -> AgentEvent {
    let at = base.addingTimeInterval(-age)
    var payload = AgentEvent.Payload(
        teammate: nil, session: nil, cwd: nil, for: nil, options: nil
    )
    payload.session = session
    payload.cwd = cwd
    payload.`for` = resolves
    payload.teammate = teammate
    if !options.isEmpty { payload.options = options }
    return AgentEvent(
        id: id,
        at: wireDate.string(from: decisionAt.map { base.addingTimeInterval(-$0) } ?? at),
        source: source,
        kind: kind,
        title: title,
        body: nil,
        decision: decision,
        answer: nil,
        data: payload
    )
}

func column(of events: [AgentEvent], manuallyArchived: Set<String> = []) -> InboxBoard {
    InboxBoard(events: events, now: base, manuallyArchived: manuallyArchived)
}

// MARK: - Which column

// The three columns are the whole point: something wants you, something is
// happening, something is finished.
let waiting = column(of: [event(1, age: 5, kind: .approval)])
check(waiting.rows(in: .needsYou).count == 1, "an unanswered approval is in Needs you")
check(waiting.rows(in: .working).isEmpty, "and not in Working")
check(waiting.rows.first?.pending != nil, "and the row keeps the event that is waiting")

let answered = column(of: [event(1, age: 5, kind: .approval, decision: "allow")])
check(answered.rows(in: .working).count == 1,
      "an answered approval is Working, not Done — the agent has started, not finished")
check(answered.rows(in: .needsYou).isEmpty, "and it has left Needs you")

let finished = column(of: [event(1, age: 5, title: "Task finished")])
check(finished.rows(in: .done).count == 1, "a completion notice is Done")

// The gateway's own notice that an approval was resolved must not itself decide
// the column. It is a completion-shaped notice, so a board that read it as one
// would move every row to Done the instant it was answered — the row would
// never be seen as Working at all.
//
// This is the shape the wire actually carries, and constructing it wrong would
// hide a real bug: `/approve/:id` returns the *mutated* record, the client
// replaces its copy with it, so the approval arrives carrying `decision`. The
// first version of this fixture left the decision off, which made the row read
// as still pending — and pass — for a reason that does not happen.
let resolvedByGateway = column(of: [
    event(1, age: 20, kind: .approval, decision: "allow", decisionAt: 10),
    event(2, age: 5, source: "app", title: "approval allow", resolves: 1),
])
check(resolvedByGateway.rows.count == 1, "the resolution notice does not start a second row")
check(resolvedByGateway.rows(in: .working).count == 1,
      "and it does not push the row to Done")
check(resolvedByGateway.rows.first?.pending == nil, "the row is no longer waiting")

// MARK: - One row per session

// A log of events is not a board of sessions. Twenty events from one session is
// one row, and the row shows the newest first.
let chatty = column(of: (1...20).map { event($0, age: TimeInterval(21 - $0)) })
check(chatty.rows.count == 1, "twenty events from one session are one row")
check(chatty.rows.first?.events.count == 20, "and the row keeps them all")
check(chatty.rows.first?.events.first?.id == 20, "newest event first")

let twoSessions = column(of: [
    event(1, age: 30, session: "a"),
    event(2, age: 20, session: "b"),
    event(3, age: 10, session: "a"),
])
check(twoSessions.rows.count == 2, "two sessions are two rows")

// An agent that reports no session must still not produce one row per event.
let sessionless = column(of: [event(1, age: 30, session: nil), event(2, age: 10, session: nil)])
check(sessionless.rows.count == 1, "events with no session fall back to one row per source")
check(sessionless.rows.first?.id == "source:claude-code", "and the fallback key says so")

// MARK: - Sorting

let recency = column(of: [
    event(1, age: 300, session: "old"),
    event(2, age: 10, session: "new"),
    event(3, age: 600, session: "older"),
])
check(recency.active.map(\.id) == ["new", "old", "older"], "rows are newest activity first")

// A broken timestamp must not lead the board. Putting the one row nobody can
// explain at the top is worse than putting it last.
var broken = event(9, age: 0, session: "broken")
broken.at = "not a date"
let withBroken = column(of: [broken, event(1, age: 10, session: "fine")])
check(withBroken.active.first?.id == "fine", "an unparseable timestamp sorts last, not first")

// MARK: - Archiving

// A finished turn is worth 10 minutes and then it is not.
let justDone = column(of: [event(1, age: 9 * 60, title: "Task finished")])
check(justDone.active.count == 1, "a completion is still on the board at 9 minutes")
let staleDone = column(of: [event(1, age: 11 * 60, title: "Task finished")])
check(staleDone.active.isEmpty, "and archived at 11")
check(staleDone.archived.count == 1, "archived rather than dropped")

// The long backstop catches what never completes: an approval the host timed
// out, or a session that went quiet mid-turn.
let staleWorking = column(of: [event(1, age: 7 * 3600, kind: .approval, decision: "allow")])
check(staleWorking.active.isEmpty, "anything older than six hours auto-archives")

// A row still waiting on an answer does not archive at ten minutes — it is
// waiting on the user, and the spec keeps it Active until answered or the host
// times it out. Six hours is the stand-in for the host giving up.
let oldWaiting = column(of: [event(1, age: 30 * 60, kind: .approval)])
check(oldWaiting.rows(in: .needsYou).count == 1,
      "a pending approval is still Needs you at 30 minutes")
let timedOut = column(of: [event(1, age: 7 * 3600, kind: .approval)])
check(timedOut.active.isEmpty, "but not after six hours")

// Swiping archives a row immediately, whatever its age.
let swiped = column(of: [event(1, age: 5, session: "s1")], manuallyArchived: ["s1"])
check(swiped.active.isEmpty, "a swiped row leaves the active board")
check(swiped.archived.count == 1, "and is in the archive")

// MARK: - Questions

// A question with options is waiting on the user in exactly the way an approval
// is, so it belongs in the same column. Filing it as Working while it sits
// there blocks the agent would hide the one thing to act on.
let question = column(of: [event(
    1, age: 5, kind: .approval,
    options: [.init(label: "Use Postgres", value: "pg"),
              .init(label: "Use SQLite", value: "sqlite")]
)])
check(question.rows(in: .needsYou).count == 1, "an unanswered question is Needs you")
check(question.rows.first?.pending?.isQuestion == true, "and the row knows to render options")

// MARK: - Project grouping

let grouped = column(of: [
    event(1, age: 30, session: "a", cwd: "/Users/x/work/api"),
    event(2, age: 20, session: "b", cwd: "/Users/x/work/web"),
    event(3, age: 10, session: "c", cwd: "/Users/x/work/api"),
])
let groups = grouped.groups(in: .done)
check(groups.count == 2, "two projects are two groups")
check(groups.contains { $0.project == "api" && $0.rows.count == 2 },
      "the group header is the repository name, not the path")
check(!groups.contains { $0.project.contains("/") }, "and never the whole path")

// One project alone must not produce a header: a heading over every row is
// noise, and the board would look different for no reason.
let oneProject = column(of: [
    event(1, age: 30, session: "a", cwd: "/Users/x/work/api"),
    event(2, age: 10, session: "b", cwd: "/Users/x/work/api"),
])
check(oneProject.groups(in: .done).count == 1, "one project yields one group")
check(oneProject.groups(in: .done).first?.project == "",
      "and it is unnamed, so no header is drawn for it")

// Events with no cwd at all still render — as one unnamed group.
let noProjects = column(of: [event(1, age: 30, session: "a"), event(2, age: 10, session: "b")])
check(noProjects.groups(in: .done).count == 1, "sessions with no project render together")
check(noProjects.groups(in: .done).first?.rows.count == 2, "and none are dropped")

// A group containing something that wants you bubbles above the rest.
let mixed = column(of: [
    event(1, age: 10, session: "a", cwd: "/Users/x/work/quiet"),
    event(2, age: 60, kind: .approval, session: "b", cwd: "/Users/x/work/loud"),
    event(3, age: 5, session: "b", cwd: "/Users/x/work/loud"),
])
let activeGroups = mixed.groups(in: .needsYou)
check(activeGroups.count == 1, "only the project with something waiting is in Needs you")
// The group is unnamed — a lone group gets no header — so the project is on the
// row, which is where the view reads it from.
check(activeGroups.first?.rows.first?.project == "loud", "and it is the one with the approval")

// MARK: - Titles

let titled = column(of: [event(1, age: 5, session: "a", cwd: "/Users/x/work/api")])
check(titled.rows.first?.title == "api", "a row is named for its project")

let untitled = column(of: [event(1, age: 5, session: "a")])
check(untitled.rows.first?.title == "Claude Code", "a row with no project is named for its agent")

// A teammate's message is not the main agent's output, so a row that has one
// must not present it as such.
let teammate = column(of: [
    event(1, age: 30, session: "a", cwd: "/Users/x/work/api"),
    event(2, age: 5, session: "a", cwd: "/Users/x/work/api", teammate: "scout"),
])
check(teammate.rows.first?.title == "api", "a teammate message does not rename the row")

// MARK: - Answers that arrived somewhere else

// The case the first version of this board got wrong, and only a live run could
// show it: the poll asks for `id > lastId`, so an approval this device already
// holds is never re-sent with its decision on it. Backgrounding the app,
// approving from the watch, and coming back left the row in "Needs you" forever.
// The only thing that arrives is the gateway's notice, so the decision has to
// ride on it and be folded back in.

/// The mutation `/approve/:id` returns, plus the notice the gateway emits
/// beside it — neither of which the client ever asked for again.
func elsewhereResolved(_ id: Int, session: String, decision: String, asked: TimeInterval) -> [AgentEvent] {
    var notice = event(900 + id, age: 5, source: "app", title: "approval \(decision)")
    notice.data?.`for` = id
    notice.data?.session = session
    notice.data?.decision = decision
    // The approval itself is as the client already had it: no decision, since
    // the update never reaches this device as a new event.
    return [event(id, age: asked, kind: .approval, session: session), notice]
}

let answeredElsewhere = column(of: elsewhereResolved(1, session: "s1", decision: "allow", asked: 60))
check(answeredElsewhere.rows.first?.pending == nil,
      "an approval answered on another device stops waiting here")
check(answeredElsewhere.rows(in: .needsYou).isEmpty,
      "and leaves Needs you rather than sitting there for good")
check(answeredElsewhere.rows(in: .working).count == 1,
      "and shows as work in progress, which is what an approval means")

let deniedElsewhere = column(of: elsewhereResolved(2, session: "s2", decision: "deny", asked: 60))
check(deniedElsewhere.rows.first?.pending == nil, "a denial elsewhere also clears the row")
check(deniedElsewhere.rows(in: .working).count == 1, "and lands in Working, not Done")

// A question answered elsewhere carries the chosen option, so the row shows
// which way it went instead of re-offering the buttons.
let madechoice = column(of: [
    event(3, age: 60, kind: .approval, session: "s3",
          options: [.init(label: "Use Postgres", value: "pg"),
                    .init(label: "Use SQLite", value: "sqlite")]),
    { var n = event(903, age: 5, source: "app", title: "approval allow")
      n.data?.`for` = 3; n.data?.session = "s3"; n.data?.decision = "allow"; n.data?.answer = "sqlite"
      return n }(),
])
check(madechoice.rows.first?.pending == nil, "a question answered elsewhere is no longer waiting")
check(madechoice.rows.first?.events.first?.chosenOption?.label == "Use SQLite",
      "and the row shows which option was chosen")
// The chosen option has to be readable off the row the view actually renders,
// which reads `pending` — nil once answered — and otherwise the newest event.
check(madechoice.rows.first?.events.first?.answer == "sqlite",
      "and the answer is on the row's newest event, which is what the view shows")

// Our own bookkeeping is not something that happened in the user's session. Left
// in the row it becomes the summary — "CQUTmux · approval allow" was the newest
// line of every row the user had just answered.
let foldedAway = column(of: elsewhereResolved(5, session: "s5", decision: "allow", asked: 60))
check(foldedAway.rows.first?.events.contains { $0.source == "app" } == false,
      "our resolution notices are folded away rather than left in the row")
check(foldedAway.rows.first?.events.first?.sourceLabel == "Claude Code",
      "so the row's summary is the agent's work, not ours")

// A notice with nothing to resolve — our own event with no `for` — must not be
// mistaken for a resolution and applied to whatever is nearby.
let stray = column(of: [
    event(4, age: 60, kind: .approval, session: "s4"),
    event(5, age: 5, source: "app", title: "something else"),
])
// Look the row up by id: the unrelated notice forms a row of its own, and it
// is newer, so `rows.first` is that row rather than the approval's.
check(stray.rows.first { $0.id == "s4" }?.pending != nil,
      "an unrelated app notice does not clear an approval")

// MARK: - It survives the wire

// The board's own checks build `Payload` directly, so they cannot see a mistake
// in its `CodingKeys` — and one was there: adding the session and cwd keys meant
// listing every field, `options` was left out, and every question rendered as
// Allow/Deny. It looked exactly like an agent that had sent no options, which is
// why it took a screenshot to notice. This decodes what the gateway and the
// hooks actually write, so the list has to stay complete.
let wire = """
{"id":1,"at":"2023-11-14T22:13:20.123Z","source":"claude-code","kind":"approval",
 "title":"Which database?","body":"Pick one.",
 "data":{"session":"sess-a","cwd":"/Users/x/work/api",
         "options":[{"label":"Use Postgres","value":"pg"},{"label":"Use SQLite","value":"sqlite"}]}}
"""
let decoded = try? JSONDecoder().decode(AgentEvent.self, from: Data(wire.utf8))
check(decoded != nil, "an event the gateway would send decodes")
check(decoded?.data?.session == "sess-a", "and keeps its session, which is what rows merge on")
check(decoded?.data?.cwd == "/Users/x/work/api", "and its working directory")
check(decoded?.projectName == "api", "which yields the project name for grouping")
check(decoded?.isQuestion == true, "and a question is still a question after decoding")
check(decoded?.options.count == 2, "with its options intact — not silently dropped")

// The resolution notice the gateway emits resolves an approval and names no
// session of its own.
let notice = """
{"id":2,"at":"2023-11-14T22:13:20.123Z","source":"app","kind":"notice",
 "title":"approval allow","body":"","data":{"for":1,"session":"sess-a"}}
"""
let resolved = try? JSONDecoder().decode(AgentEvent.self, from: Data(notice.utf8))
check(resolved?.resolvesEventID == 1, "the resolution notice names the event it resolves")
check(resolved?.sessionKey == "sess-a", "and lands on that event's row")

if failures > 0 {
    print("\nINBOX_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nINBOX_PASS  (\(checks) checks)")