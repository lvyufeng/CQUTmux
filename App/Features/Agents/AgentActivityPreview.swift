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
        var title: String
        var source: String

        /// One sentence describing what the activity shows. Used for the
        /// Settings footer, so the screen says which event it is talking about
        /// rather than only that one exists.
        var summary: String {
            pending > 0
                ? "\(pending) approval\(pending == 1 ? "" : "s") waiting · \(source)"
                : "\(source) · \(title)"
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
    /// Nil in two cases, and the second is the one worth stating: no events at
    /// all, and events with nothing pending and no resolved approval to report.
    /// The activity exists for a *waiting* approval, and a notice — an agent's
    /// chatter — putting a hand-raised badge on the Lock Screen would be a claim
    /// that something needs the user when nothing does.
    static func content(for events: [AgentEvent]) -> Content? {
        let pending = events.filter(\.isPending)
        if let first = pending.first {
            return Content(
                pending: pending.count,
                title: label(first.displayTitle),
                source: label(first.sourceLabel)
            )
        }
        // Nothing pending, but a decision that just landed: showing "0 waiting"
        // briefly is better than the activity blinking out mid-answer, and it is
        // ended on the next update once the event falls out of the poll window.
        guard let resolved = events.first(where: { $0.kind == .approval && $0.decision != nil })
        else { return nil }
        return Content(
            pending: 0,
            title: label(resolved.displayTitle),
            source: label(resolved.sourceLabel)
        )
    }

    /// An empty string is not a title. The fallback is a word rather than
    /// nothing, because a blank line on the Lock Screen reads as a rendering
    /// bug instead of a missing field.
    private static func label(_ text: String) -> String {
        text.isEmpty ? "Agent" : text
    }
}