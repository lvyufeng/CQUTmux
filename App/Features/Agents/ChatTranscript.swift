import Foundation

/// One agent session, read as a conversation.
///
/// The transcript is the source of truth, not the terminal pane: the agent
/// already writes a structured log, and reading it is what lets a tool call
/// show up as a card with its own input and output instead of as the
/// ANSI-coloured text a terminal happened to have on screen.
///
/// The wire is the gateway's; this is the app's half. Everything is optional
/// because the log format belongs to the agent and drifts — a field we have
/// never seen must not fail the decode and blank the whole view, which is the
/// same failure `AgentEvent`'s optional title/body already guards against.
struct AgentTranscript: Codable {
    var found: Bool
    var file: String?
    var total: Int?
    var messages: [AgentMessage]
    /// Set when the gateway could not read the log at all, which is different
    /// from there being no session yet.
    var error: String?

    static let empty = AgentTranscript(found: false, messages: [])
}

struct AgentMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
        /// Not the user speaking: a tool's output, which the agent's own log
        /// records as a `user` record because that is how the protocol carries
        /// results back. Kept distinct so the view can show it as what it is.
        case tool

        /// An unknown role from a newer agent is treated as the assistant's
        /// output rather than dropped: showing it in the wrong voice is better
        /// than losing a turn of the conversation.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .assistant
        }
    }

    var id: String
    var role: Role
    var at: String?
    var blocks: [AgentBlock]
    var model: String?

    var date: Date? { at.flatMap { ISO8601DateFormatter().date(from: $0) } }

    /// A user message with nothing in it is a blank row; the gateway drops most
    /// of these, but one that survives should not render as an empty bubble.
    var isEmpty: Bool { blocks.isEmpty }
}

struct AgentBlock: Codable, Hashable {
    enum Kind: String, Codable {
        case text
        case thinking
        case tool
        case result
        /// Anything the agent adds that this build does not know about. Kept as
        /// a case rather than dropped so the row still renders something and
        /// the gap is visible rather than silent.
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var kind: Kind
    /// Text content: the prose of a message, the body of a result, or the
    /// reasoning.
    var text: String?
    /// Tool call fields.
    var id: String?
    var name: String?
    var input: String?
    var isError: Bool?

    var displayText: String { text ?? "" }
    var toolName: String { name ?? "tool" }

    /// The tool call in one line, for the collapsed row: its name and the most
    /// telling argument. A card that only said "Edit" makes the reader open
    /// every one to find the one they want.
    var toolSummary: String {
        guard let input, let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return toolName }
        for key in ["file_path", "path", "command", "pattern", "url", "query", "description"] {
            if let value = object[key] as? String, !value.isEmpty {
                return "\(toolName) · \(value)"
            }
        }
        return toolName
    }
}