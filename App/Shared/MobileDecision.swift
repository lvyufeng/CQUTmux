import Foundation

/// A decision the user made somewhere other than the app — the Lock Screen, the
/// Dynamic Island — on its way back to the host.
///
/// The widget extension and the app are separate processes with separate
/// containers, so a button pressed on the Lock Screen cannot call the app
/// directly: it writes here, into an App Group both can see, and the app drains
/// it the next time it is running. The watch has its own channel
/// (`WatchPayload`), and this is the phone-only equivalent.
///
/// The queue is where a wrong answer is invisible. A tap that never arrives
/// looks exactly like a tap the user did not make, and the approval simply sits
/// in "Needs you" — which is also what a working denial looks like. So the rules
/// that matter are here, apart from WidgetKit, and checked directly.
///
/// Note the honest boundary: the *button* is an AppIntent that runs wherever the
/// system decides to run it, and whether it fires at all depends on entitlements
/// this environment cannot sign. What is checked is what the queue does with a
/// decision once one exists.
public struct MobileDecision: Codable, Sendable, Identifiable, Hashable {
    /// The event being answered — the same id the gateway minted.
    public var id: Int
    public var allow: Bool
    /// For a question rather than an approval, the option value chosen. `nil`
    /// for a plain allow/deny, which is the majority.
    public var answer: String?
    /// When the tap happened, so the queue can be drained oldest-first and a
    /// decision that has been sitting for hours is distinguishable from one
    /// just made.
    public var at: Date

    public init(id: Int, allow: Bool, answer: String? = nil, at: Date) {
        self.id = id
        self.allow = allow
        self.answer = answer
        self.at = at
    }
}

/// The decisions waiting to be sent, held in the App Group.
/// `@unchecked` because the stored `UserDefaults` is not `Sendable`-conforming
/// but *is* safe to use from any thread, and the type otherwise holds only that
/// reference.
public struct MobileDecisionQueue: @unchecked Sendable {
    /// The suite the app and the widget share. The same identifier the watch
    /// complications use — one App Group for the whole product.
    public static let appGroup = "group.app.cqutmux.ios"
    /// The single key the queue is stored under, as a JSON array.
    public static let storageKey = "cqutmux.mobile.decisions"

    private let defaults: UserDefaults?

    /// Nil when the entitlement is missing. The queue then does nothing rather
    /// than crashing — a build without the App Group runs, its Lock Screen
    /// buttons just have nowhere to write.
    public init(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        self.defaults = defaults
    }

    /// Records a decision, replacing any earlier one for the same event.
    ///
    /// Last write wins, keyed by id, and that is the whole point: a user who taps
    /// Allow and then changes their mind and taps Deny must send one decision —
    /// the second — not two. A queue that appended would send a contradictory
    /// pair, and which of them the host applies would depend on the order the
    /// array happened to be read in.
    ///
    /// A non-positive id is refused: real event ids come from the gateway and
    /// are positive, the sample events the Settings button shows are negative on
    /// purpose, and writing one of those here would send a decision about an
    /// approval that does not exist.
    @discardableResult
    public func enqueue(_ decision: MobileDecision) -> Bool {
        guard decision.id > 0 else { return false }
        var items = read().filter { $0.id != decision.id }
        items.append(decision)
        return write(items)
    }

    /// The decisions waiting, oldest first.
    public func pending() -> [MobileDecision] {
        read().sorted { $0.at < $1.at }
    }

    /// Takes the decisions, leaving the queue empty.
    ///
    /// Clearing as it reads is what makes sending them once: the app drains on
    /// connect, and a decision left in the queue would be re-sent on every
    /// later connection — a host that received the same denial five times would
    /// record five decisions for one approval.
    public func drain() -> [MobileDecision] {
        let items = pending()
        _ = write([])
        return items
    }

    public func clear() {
        _ = write([])
    }

    // MARK: - Storage

    /// Reads tolerantly.
    ///
    /// A payload that no longer decodes — an older shape written by a previous
    /// version, a partial write — is treated as empty rather than carried
    /// forward, because the alternative is a queue that throws on every read and
    /// can never be emptied.
    private func read() -> [MobileDecision] {
        guard let data = defaults?.data(forKey: Self.storageKey), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MobileDecision].self, from: data)) ?? []
    }

    private func write(_ items: [MobileDecision]) -> Bool {
        guard let defaults else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }
}
