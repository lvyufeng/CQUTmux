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
        }
        var items: [Item]
    }

    struct Decision: Codable, Sendable {
        var id: Int
        var allow: Bool
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}