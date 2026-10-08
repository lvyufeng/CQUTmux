import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Keeps a Live Activity in sync with the agent inbox: pending approvals show
/// on the Lock Screen and in the Dynamic Island while the app is backgrounded.
@MainActor
final class ActivityManager {
    private var activity: Activity<AgentActivityAttributes>?

    func update(hostName: String, events: [AgentEvent]) {
        let pending = events.filter(\.isPending)
        let latest = pending.first ?? events.first

        guard !pending.isEmpty || latest?.kind == .approval else {
            end()
            return
        }

        let state = AgentActivityAttributes.ContentState(
            pending: pending.count,
            latestTitle: latest.map(\.displayTitle).flatMap { $0.isEmpty ? nil : $0 } ?? "Agent",
            latestSource: latest?.sourceLabel ?? "agent"
        )

        if let activity {
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: AgentActivityAttributes(hostName: hostName),
                content: .init(state: state, staleDate: nil)
            )
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif