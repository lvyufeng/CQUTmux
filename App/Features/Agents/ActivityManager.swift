import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Keeps a Live Activity in sync with the agent inbox: pending approvals show
/// on the Lock Screen and in the Dynamic Island while the app is backgrounded.
@MainActor
final class ActivityManager {
    /// What happened, so a caller that needs to say so — the Settings test
    /// button — can. `Activity.request` is the one call in this feature that
    /// can fail quietly: the system budget for activities, an activity already
    /// on screen, or Live Activities switched off for the app all end in a
    /// throw, and swallowing it left the button looking broken with nothing to
    /// read. The poll ignores this; the button does not.
    enum Outcome: Equatable {
        case started
        case updated
        case ended
        case nothingToShow
        /// The app's own switch is off. Distinct from `.unavailable`, which is
        /// the system's: the fixes are in different places.
        case disabledInApp
        case unavailable
        case failed(String)
    }

    private var activity: Activity<AgentActivityAttributes>?

    @discardableResult
    func update(hostName: String, events: [AgentEvent]) -> Outcome {
        // The preference gates the whole feature, and reading it here rather
        // than at the call site means every path into the activity — the poll,
        // the test button, a push — answers to the same switch.
        guard AgentActivitySettings.isEnabled() else {
            end()
            return .disabledInApp
        }

        // What to show is decided in `AgentActivityPreview`, not here, so the
        // Settings test button drives the same logic the inbox does. A preview
        // built its own way would prove nothing about the real one.
        guard let content = AgentActivityPreview.content(for: events) else {
            end()
            return .nothingToShow
        }

        let state = AgentActivityAttributes.ContentState(
            pending: content.pending,
            latestTitle: content.title,
            latestSource: content.source
        )

        if let activity {
            Task { await activity.update(.init(state: state, staleDate: nil)) }
            return .updated
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .unavailable }
        do {
            activity = try Activity.request(
                attributes: AgentActivityAttributes(hostName: hostName),
                content: .init(state: state, staleDate: nil)
            )
            return .started
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func end() -> Outcome {
        guard let activity else { return .ended }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        return .ended
    }
}
#endif