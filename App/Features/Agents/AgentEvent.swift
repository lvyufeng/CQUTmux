import Foundation

/// One item from the host gateway: either something to decide on (`approval`)
/// or something to know about (`notice`).
struct AgentEvent: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case approval
        case notice
    }

    var id: Int
    var at: String
    var source: String
    var kind: Kind
    // Optional to match the wire. The gateway omits both on its own notices —
    // `POST /events` accepts an event with neither — and a non-optional field
    // here made `JSONDecoder` throw on the *whole page*, so a single
    // bodyless event (the gateway emits one every time an approval is
    // resolved) silently blanked the entire Inbox.
    var title: String?
    var body: String?
    var decision: String?

    var date: Date? { ISO8601DateFormatter().date(from: at) }

    var isPending: Bool { kind == .approval && decision == nil }

    /// Empty when the gateway sent no title or body, so views can test one
    /// thing instead of unwrapping in each of them.
    var displayTitle: String { title ?? "" }
    var displayBody: String { body ?? "" }

    /// Short label for the agent that produced it, e.g. "Claude Code".
    var sourceLabel: String {
        switch source {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case "app": "CQUTmux"
        default: source.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

struct AgentEventPage: Codable {
    var events: [AgentEvent]
    var lastId: Int
}