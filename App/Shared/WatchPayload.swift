import Foundation

/// The messages that cross between the phone and the watch.
///
/// Both directions encode their payload as JSON `Data` and carry it in a
/// property-list container, so the shape of an approval stays defined once —
/// by `AgentEvent` — instead of being re-declared as dictionaries on the watch
/// side and drifting from the phone's model.
enum WatchPayload {
    /// The app-group container the watch app and its complication extension
    /// share.
    ///
    /// An App Group rather than the WatchConnectivity application context the
    /// watch app reads: a WidgetKit extension is a separate process with its
    /// own container, and `WCSession.receivedApplicationContext` is not
    /// available there at all, so the complication would always render "no
    /// data" while the app beside it showed real rings. The watch app writes
    /// what it receives into this container; the extension reads it.
    ///
    /// Named with the `group.` prefix because that is what the entitlement
    /// requires; the identifier must match `application-groups` on both the
    /// watch app and its extension, and be registered on the developer account.
    static let appGroup = "group.app.cqutmux.ios"

    /// The `UserDefaults` suite the complication reads. Nil when the
    /// entitlement is missing — a build without the App Group still runs, its
    /// complication just has nothing to show, which is the honest result rather
    /// than a crash in a widget process.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// The key the latest usage is stored under, in the shared container.
    static let sharedUsageKey = "usage.latest"
    /// `applicationContext` key: the phone's list of pending approvals.
    static let pendingKey = "pending"
    /// `applicationContext` key: per-account rate-limit usage.
    ///
    /// Separate from `pendingKey` rather than one merged context, because the
    /// two update on different clocks — an approval can arrive at any moment,
    /// while usage is polled every few minutes — and collapsing them would
    /// either push approvals on a timer or blank the usage rings whenever an
    /// approval changed.
    static let usageKey = "usage"
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

    /// Per-account usage, flattened to what a watch ring shows.
    ///
    /// A copy of the phone's model rather than the model itself: `UsageBoard`
    /// is in `HookClient`, which pulls in the transport, and the watch target
    /// links neither. The shape is small enough that duplicating it is cheaper
    /// than adding a package to the watch for it — but that does mean the two
    /// can drift, so the phone builds this type from its own by field, and
    /// `scripts/watch-usage-check.sh` pins the encoding on both sides.
    struct Usage: Codable, Sendable {
        struct Window: Codable, Sendable, Hashable, Identifiable {
            var label: String
            var percent: Double
            /// Human-readable ("in 2h 10m"), kept as a string because the watch
            /// has no idea when the phone generated it and a countdown computed
            /// from a stale timestamp would tick down wrongly.
            var resetIn: String?
            var id: String { label }
        }

        struct Entry: Codable, Sendable, Identifiable {
            var source: String
            var label: String
            var pace: String?
            var windows: [Window]
            var id: String { source }

            /// The window that matters for a glance, and the same rule the
            /// complication uses: the one closest to its limit. A ring showing
            /// the average of a 5h and a 7d window would look reassuring in the
            /// exact state where the user needs to know they are about to be
            /// cut off.
            var tightest: Window? {
                windows.max { $0.percent < $1.percent }
            }
        }

        var entries: [Entry]
        /// When the phone took this reading, so the watch can say how stale it
        /// is rather than presenting minutes-old numbers as current.
        var generatedAt: Date?

        /// The single number a complication shows: the most-used window across
        /// every account. Nil when there is nothing to show, which the watch
        /// renders as "no data" rather than as 0% — an empty ring reads as a
        /// measured zero.
        var peakPercent: Double? {
            entries.compactMap { $0.tightest?.percent }.max()
        }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}