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
    /// Which option was chosen, for a question rather than an approval.
    var answer: String?
    /// Whatever the agent attached. Free-form on the wire, so it is typed here
    /// as the few keys already in use rather than as a dictionary.
    var data: Payload?

    /// The keys agents send that this app reads. Decoding is lenient: an event
    /// with keys not named here decodes to `nil` rather than failing, because a
    /// newer agent hook must not be able to blank the Inbox.
    struct Payload: Codable, Hashable {
        /// Set by a teammate reporting its own message, rather than by the
        /// agent the user is watching. See `isTeammateMessage`.
        var teammate: String?
        /// The agent's session, as the hook reports it. This is what the Inbox
        /// merges on: one row per session, rather than one per event.
        var session: String?
        /// The directory the agent is working in, for grouping the board by
        /// project. Absent on events from older hooks.
        var cwd: String?
        /// The id of the event our own notice resolves. Set by the gateway on
        /// the "approval allow/deny" notice it emits, and what lets the board
        /// file that notice under the session it belongs to instead of opening
        /// a second row for it.
        var `for`: Int?
        /// The decision that notice reports. Carried on the notice because
        /// nothing else does: the poll asks for `id > lastId`, so an approval
        /// this device already holds is never re-sent, and an approval answered
        /// somewhere else — the watch, another phone, or the host timing it
        /// out — would stay in "Needs you" here forever. `answer` rides along
        /// for the same reason, for a question answered elsewhere.
        var decision: String?
        var answer: String?

        // Spelled out because `for` is a keyword, and every field has to be listed
    // once the list exists — an omitted one decodes as nil with no error. Doing
    // exactly that to `options` is how a question came to render as Allow/Deny
    // while every unit check still passed: they build the payload directly
    // instead of decoding it, so a mistake in this list is invisible to them.
    private enum CodingKeys: String, CodingKey {
        case teammate, session, cwd, options, decision, answer
        case `for` = "for"
    }
        /// The choices an agent's question offers.
        var options: [Option]?

        /// One choice. `label` is what the button says; `value` is what goes
        /// back to the agent, and the two differ often — a label is prose and
        /// a value is a token.
        struct Option: Codable, Hashable, Identifiable {
            var id: String { value.isEmpty ? label : value }
            var label: String
            var value: String
        }
    }

    /// An agent asking a question with choices, rather than requesting
    /// permission. The distinction decides how it is answered: allow/deny would
    /// throw away the choice the question was asked to make.
    var isQuestion: Bool { !(data?.options ?? []).isEmpty }

    var options: [Payload.Option] { data?.options ?? [] }

    /// The option already chosen, if any, so a resolved question shows which
    /// way it went instead of reverting to buttons.
    var chosenOption: Payload.Option? {
        guard let answer else { return nil }
        return options.first { $0.value == answer || $0.label == answer }
    }

    /// A message from an agent-team teammate rather than from the agent the
    /// user is driving. Moshi surfaces these as their own cards in Chat View;
    /// the difference matters because a teammate's message is not an approval
    /// and not the main agent's output, and folding it into either is wrong.
    var isTeammateMessage: Bool { data?.teammate?.isEmpty == false }

    /// The teammate's name, for the card's label.
    var teammateName: String? {
        guard let name = data?.teammate, !name.isEmpty else { return nil }
        return name
    }

    var date: Date? { ISODate.parse(at) }

    var isPending: Bool { kind == .approval && decision == nil }

    /// The session the Inbox files this event under.
    ///
    /// The hook reports one, and merging on it is what turns a log of events
    /// into a board of sessions. Without it — an older hook, or an agent that
    /// does not report one — the fallback is the source, so those events still
    /// form one row per agent instead of one row per event.
    var sessionKey: String {
        if let session = data?.session, !session.isEmpty { return session }
        return "source:\(source)"
    }

    /// The directory the agent is working in, for the board's project grouping.
    /// Only the last component: a header reading `/Users/someone/work/api` is a
    /// path, and the point of the header is to say *which repository*.
    var projectName: String? {
        guard let cwd = data?.cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The event this one resolves, when it is our own notice that an approval
    /// was answered. The gateway sends no session on those, so this is the only
    /// thing that ties the notice to the row it belongs to.
    var resolvesEventID: Int? { data?.for }

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