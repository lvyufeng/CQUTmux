import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity payload for pending agent approvals. Shared by the app (which
/// starts and updates it) and the widget extension (which renders it on the
/// Lock Screen and in the Dynamic Island).
public struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var pending: Int
        /// What the activity is currently about, so it can say "working" or
        /// "done" instead of only ever wearing the raised hand.
        public var phase: ActivityPhase
        public var latestTitle: String
        public var latestSource: String
        /// The id of the approval the Lock Screen buttons answer, or 0 when
        /// there is none.
        ///
        /// The buttons have to name the event they decide, and a widget cannot
        /// look it up when it is tapped — the activity may have been updated or
        /// ended by then. So the id travels *with* the state it is displayed
        /// alongside, and 0 is the honest value for a phase that asks nothing.
        public var latestEvent: Int

        public init(
            pending: Int,
            phase: ActivityPhase = .approvalRequired,
            latestTitle: String,
            latestSource: String,
            latestEvent: Int = 0
        ) {
            self.pending = pending
            self.phase = phase
            self.latestTitle = latestTitle
            self.latestSource = latestSource
            self.latestEvent = latestEvent
        }

        // `phase` was added after the first activities shipped. An activity
        // already on a device was encoded without it, and the system will hand
        // that old payload back to the widget on the next update — so decoding
        // has to fall back to the phase that existed before rather than throw,
        // which would leave a stale activity on the Lock Screen that can never
        // be updated again.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pending = try container.decode(Int.self, forKey: .pending)
            phase = try container.decodeIfPresent(ActivityPhase.self, forKey: .phase)
                ?? .approvalRequired
            latestTitle = try container.decode(String.self, forKey: .latestTitle)
            latestSource = try container.decode(String.self, forKey: .latestSource)
            // Same reasoning as `phase`: an activity encoded before this field
            // existed comes back without it, and throwing here would strand it
            // on the Lock Screen with no way to update it again. 0 means "no
            // approval to answer", which is the safe reading for a stale one.
            latestEvent = try container.decodeIfPresent(Int.self, forKey: .latestEvent) ?? 0
        }
    }

    public var hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}
#endif