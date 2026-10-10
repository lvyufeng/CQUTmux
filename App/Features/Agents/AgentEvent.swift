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

    /// The body as it is drawn on the row: the tool input takes apart into the
    /// lines it was written as, and a question's prose is left alone.
    ///
    /// A tool input arrives as JSON — `{"command": "set -e\na\nb", "description":
    /// …}` when a hook stringifies it, or a raw diff — so rendered verbatim the
    /// row shows braces and escaped `\n` instead of the command being approved.
    /// `toolSummary` in `AgentBlock` already answers exactly this for the Chat
    /// view; this is the same reading for the Inbox.
    var promptText: String {
        guard !isQuestion else { return displayBody }
        guard let data = displayBody.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return displayBody }
        // A tool's meaningful argument, in the order the Chat view already
        // prefers them — so both surfaces name the same call the same way.
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        if let content = object["content"] as? String, !content.isEmpty { return content }
        // A tool whose only input is the text to write (Write/Edit): the field
        // is named by the tool, so fall back to the longest string in it rather
        // than showing a JSON blob.
        let strings = object.values.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return strings.max { $0.count < $1.count } ?? displayBody
    }

    /// The logical lines of `promptText`, which is the unit the clamp counts.
    ///
    /// Split out because it is the *one* thing the clamp and the button both
    /// read. Counting characters for the button and lines for the clamp is how
    /// a body could be folded away with no way to open it — the failure this
    /// feature exists to prevent. One count, two readers, so they cannot differ.
    var promptLineCount: Int { promptText.components(separatedBy: .newlines).count }

    /// How many lines of the prompt the row shows before it needs expanding.
    ///
    /// A question is short — its body *is* the question — so it is shown whole.
    /// A tool input is clamped so a large one cannot push the Allow button off
    /// the screen. A `Text`'s own limit cannot be read off a screenshot in the
    /// direction that matters — a body clamped where it should be whole and a
    /// body whole where it should be clamped both render as text — so the rule
    /// lives here and is checked in `scripts/inbox-check.sh`.
    static let promptClampLines = 4
    var promptClampLines: Int { isQuestion ? .max : Self.promptClampLines }

    /// Whether the row should offer the expand affordance.
    ///
    /// Exactly when the clamp is folding something away: more lines than it
    /// shows. Not a character count — that is a different unit and a body of
    /// five short lines hides two of them while being nowhere near any length
    /// threshold. On a short body the button would sit there revealing nothing,
    /// and on a question there is nothing hidden to reveal.
    var promptOffersReading: Bool {
        !isQuestion && promptLineCount > Self.promptClampLines
    }

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