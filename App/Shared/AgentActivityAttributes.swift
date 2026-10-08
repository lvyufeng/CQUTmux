import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity payload for pending agent approvals. Shared by the app (which
/// starts and updates it) and the widget extension (which renders it on the
/// Lock Screen and in the Dynamic Island).
public struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var pending: Int
        public var latestTitle: String
        public var latestSource: String

        public init(pending: Int, latestTitle: String, latestSource: String) {
            self.pending = pending
            self.latestTitle = latestTitle
            self.latestSource = latestSource
        }
    }

    public var hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}
#endif