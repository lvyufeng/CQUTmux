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

    /// How long a finished session's activity stays up before it dismisses
    /// itself.
    ///
    /// A session ending is the one thing the activity reports that is *over*:
    /// ending it the instant the event arrives is a flash the user will not
    /// see, and leaving it forever is a Lock Screen that never clears. The
    /// linger is what makes "session ended" a thing you can actually read.
    static let lingerDuration: TimeInterval = 5 * 60

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
            phase: content.phase,
            latestTitle: content.title,
            latestSource: content.source
        )

        // A final phase is shown and *then* dismissed, not held open. The end
        // is scheduled rather than immediate so the user sees that the session
        // finished; `.immediate` here would make the whole phase invisible.
        if content.phase.isFinal {
            return showFinal(state: state, hostName: hostName)
        }

        if let activity {
            Task { await activity.update(.init(state: state, staleDate: staleDate())) }
            return .updated
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .unavailable }
        do {
            activity = try Activity.request(
                attributes: AgentActivityAttributes(hostName: hostName),
                content: .init(state: state, staleDate: staleDate())
            )
            return .started
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Shows a finished session and schedules it away.
    ///
    /// The activity is *updated* to the final state first — otherwise the Lock
    /// Screen would keep showing "Working" while the dismissal counted down —
    /// and only then handed a dismissal date. `dismissalPolicy: .after` leaves
    /// it on screen until then and removes it after, which is the linger.
    private func showFinal(
        state: AgentActivityAttributes.ContentState,
        hostName: String
    ) -> Outcome {
        let until = Date().addingTimeInterval(Self.lingerDuration)
        let content = ActivityContent(state: state, staleDate: until)

        // Nothing on screen: requesting it *with* a dismissal date is correct
        // too, and skips showing an intermediate state the device never needs.
        guard let activity else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .unavailable }
            do {
                self.activity = try Activity.request(
                    attributes: AgentActivityAttributes(hostName: hostName),
                    content: content,
                    pushType: nil
                )
                Task { await self.activity?.end(content, dismissalPolicy: .after(until)) }
                return .started
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        Task {
            await activity.update(content)
            await activity.end(content, dismissalPolicy: .after(until))
        }
        self.activity = nil
        return .ended
    }

    /// When the content should be considered out of date.
    ///
    /// Not nil: an activity whose updates stop — the app was suspended, the
    /// connection dropped — would otherwise sit there presenting stale counts as
    /// current. A stale date lets the system dim it, which is the honest
    /// reading of "this was true when it was written".
    private func staleDate() -> Date {
        Date().addingTimeInterval(15 * 60)
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