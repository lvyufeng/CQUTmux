import Foundation

/// What the Live Activity should say, decided apart from ActivityKit.
///
/// The demo button in Settings drives this: a Test Live Activity that showed a
/// *different* shape from the real one would prove nothing about the real one,
/// so the test builds its state through the same function the inbox does and
/// only the events going in are made up.
///
/// Foundation-only on purpose, like `GatewayStatus`: this is where "is there
/// anything to show, and what does it say" is decided, and a mistake here is
/// invisible in the app — the activity simply never appears, with no error.
/// Written to be run by a check directly rather than only through a device.
enum AgentActivityPreview {
    /// The three strings the activity renders, and whether there is anything to
    /// render at all.
    struct Content: Equatable {
        var pending: Int
        /// What the activity is about. The pending count is one fact about that;
        /// this is the other, and the one that lets the activity say "working"
        /// or "done" instead of only ever wearing the raised hand.
        var phase: ActivityPhase
        var title: String
        var source: String

        /// One sentence describing what the activity shows. Used for the
        /// Settings footer, so the screen says which event it is talking about
        /// rather than only that one exists.
        var summary: String {
            if pending > 0 {
                return "\(pending) approval\(pending == 1 ? "" : "s") waiting · \(source)"
            }
            // Nothing is waiting, so the phase is the whole story — a summary
            // that read "claude · Working" would leave the user to guess
            // whether working meant the agent was busy or they were.
            return "\(phase.shortLabel) · \(source) · \(title)"
        }
    }

    /// The events the test button shows: two pending approvals, so the count on
    /// the activity is a number that can only be right if the plural and the
    /// count both work. A single fake approval would look identical to a
    /// hardcoded "1".
    static func sampleEvents(now: Date = Date()) -> [AgentEvent] {
        let at = ISODate.string(from: now)
        return [
            AgentEvent(id: -1, at: at, source: "claude", kind: .approval,
                       title: "Run rm -rf build/", body: nil, decision: nil, answer: nil,
                       data: nil),
            AgentEvent(id: -2, at: at, source: "codex", kind: .approval,
                       title: "Write to Sources/App.swift", body: nil, decision: nil,
                       answer: nil, data: nil),
        ]
    }

    /// Decides what the activity shows, or nil when it should not be up.
    ///
    /// An approval that is waiting is the one thing that outranks everything
    /// else: it is the only event that asks the user for something, and an
    /// activity that showed "working" while a decision sat unanswered would be
    /// hiding the very thing it exists to surface.
    ///
    /// With nothing waiting, the phase follows the newest event the user's
    /// agents produced. It is `nil` only when there is genuinely nothing to say:
    /// no events, or events with no timestamp at all — which cannot be ordered,
    /// so "the latest" would be whichever the poll happened to list first, and
    /// the activity would say a different thing on every update.
    static func content(for events: [AgentEvent]) -> Content? {
        let pending = events.filter(\.isPending)
        if let first = pending.first {
            return Content(
                pending: pending.count,
                phase: .approvalRequired,
                title: label(first.displayTitle),
                source: label(first.sourceLabel)
            )
        }

        // Newest by time, falling back to id — the gateway's ids are monotonic,
        // so they order what the clock cannot, and two events sharing a second
        // must not make the activity flicker between them.
        guard let newest = events.sorted(by: isOlder).last, newest.date != nil else { return nil }

        return Content(
            pending: 0,
            phase: phase(of: newest),
            title: label(newest.displayTitle),
            source: label(newest.sourceLabel)
        )
    }

    /// Which lifecycle phase one event puts the activity in.
    ///
    /// An answered approval is `toolRunning`, not `taskComplete`: allowing a
    /// tool lets it *run*, and the previous `Content` already lingered at zero
    /// rather than calling it done. `sessionEnded` is checked first because it
    /// is the only final phase — it must win over whatever the carrying event's
    /// category would otherwise say, or the linger would be skipped.
    static func phase(of event: AgentEvent) -> ActivityPhase {
        if event.endsSession { return .sessionEnded }
        switch event.eventCategory {
        case .approvalRequired: return .approvalRequired
        case .toolRunning: return .toolRunning
        case .taskComplete, .toolFinished: return .taskComplete
        // A session *starting* is not a state for the Lock Screen to hold: the
        // activity exists to report what a running agent is doing, and "a
        // session began" is the moment before there is anything to report.
        case .sessionStarted: return .taskComplete
        }
    }

    private static func isOlder(_ left: AgentEvent, _ right: AgentEvent) -> Bool {
        switch (left.date, right.date) {
        case let (left?, right?) where left != right: return left < right
        default: return left.id < right.id
        }
    }

    /// An empty string is not a title. The fallback is a word rather than
    /// nothing, because a blank line on the Lock Screen reads as a rendering
    /// bug instead of a missing field.
    private static func label(_ text: String) -> String {
        text.isEmpty ? "Agent" : text
    }
}