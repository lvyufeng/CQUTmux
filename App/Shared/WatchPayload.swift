import Foundation

/// The messages that cross between the phone and the watch.
///
/// Both directions encode their payload as JSON `Data` and carry it in a
/// property-list container, so the shape of an approval stays defined once —
/// by `AgentEvent` — instead of being re-declared as dictionaries on the watch
/// side and drifting from the phone's model.
enum WatchPayload {
    /// `applicationContext` key: the phone's list of pending approvals.
    static let pendingKey = "pending"
    /// Message key: the watch's decision on one approval.
    static let decisionKey = "decision"

    /// An approval awaiting a decision, flattened to what a watch row shows.
    struct Snapshot: Codable, Sendable {
        struct Item: Codable, Sendable, Identifiable, Hashable {
            var id: Int
            var source: String
            var title: String
            var body: String
            /// A question's choices, empty for an approval. The watch renders
            /// them as buttons: an agent waiting on a choice is waiting just as
            /// much as one waiting on permission, and it is the case where
            /// reaching for the phone is most annoying.
            var options: [Option] = []

            struct Option: Codable, Sendable, Hashable, Identifiable {
                var id: String { value.isEmpty ? label : value }
                var label: String
                var value: String
            }

            var isQuestion: Bool { !options.isEmpty }
        }
        var items: [Item]
    }

    struct Decision: Codable, Sendable {
        var id: Int
        var allow: Bool
        /// Which option was chosen, for a question. Additive: a watch running an
        /// older build sends no answer, and the phone reads that as allow/deny.
        var answer: String?
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}