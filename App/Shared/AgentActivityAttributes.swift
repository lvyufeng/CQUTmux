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

        public init(
            pending: Int,
            phase: ActivityPhase = .approvalRequired,
            latestTitle: String,
            latestSource: String
        ) {
            self.pending = pending
            self.phase = phase
            self.latestTitle = latestTitle
            self.latestSource = latestSource
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
        }
    }

    public var hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}
#endif