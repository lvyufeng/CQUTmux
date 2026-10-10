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

    /// Reports a new or dead activity token to whoever holds the gateway
    /// client.
    ///
    /// The manager does not talk to the host itself — it has no client — but
    /// the host has to hold this token or a background push cannot start or
    /// update the activity at all: an activity push is addressed to the token
    /// the system minted with the activity, not to the device. `remove` is
    /// passed so the same channel carries both ends of a token's life.
    var onActivityToken: ((String, Bool) -> Void)?

    /// The *other* token APNs needs, and the one the claim is named for.
    ///
    /// A per-activity token can only update or end an activity that already
    /// exists. Starting one on a phone whose app is suspended needs a token
    /// that belongs to the app rather than to any activity, which the system
    /// hands over on its own stream. Registering the per-activity token and
    /// calling that "push-to-start" would leave the actual cold start with
    /// nothing to address — the very case the feature exists for.
    var onPushToStartToken: ((String, Bool) -> Void)?

    /// Cancelled on deinit; the stream never ends on its own.
    private var pushToStartObserver: Task<Void, Never>?

    /// Watches the push-to-start stream.
    ///
    /// `pushToStartTokenUpdates` yields the current token immediately when one
    /// exists and again whenever it rotates, so this is both the initial
    /// registration and the renewal in one — there is no separate "get the
    /// token" call to keep in step with it.
    private static let pushToStartKey = "cqutmux.activity.pushToStartToken"

    func observePushToStart() {
        guard pushToStartObserver == nil else { return }
        pushToStartObserver = Task { [weak self] in
            for await token in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                // Hex, like every other token on this wire: the gateway's
                // checks are on hex and the same bytes in another shape are
                // refused as malformed.
                let hex = token.map { String(format: "%02x", $0) }.joined()
                self.reportPushToStart(hex)
            }
        }
    }

    /// Registers or removes the app-level token through the same switch the
    /// per-activity one answers to.
    ///
    /// A push-to-start token left registered while the switch is off is the
    /// same bug as a stale activity token, one level up: the host can begin an
    /// activity on a device whose user turned them off.
    private func reportPushToStart(_ hex: String) {
        let defaults = UserDefaults.standard
        let registered = defaults.string(forKey: Self.pushToStartKey)
        switch AgentActivitySettings.activityTokenAction(token: hex, registered: registered) {
        case .register(let token):
            onPushToStartToken?(token, false)
            defaults.set(token, forKey: Self.pushToStartKey)
        case .unregister(let token):
            onPushToStartToken?(token, true)
            defaults.removeObject(forKey: Self.pushToStartKey)
        case .none:
            break
        }
    }

    deinit { pushToStartObserver?.cancel() }

    /// What the host was last told this device holds, so a re-registration of
    /// the same token is skipped and the switch-off path knows what to remove.
    /// Persisted rather than held in memory: the app is relaunched between the
    /// activity that registered it and the one that ends it.
    private static let registeredTokenKey = "cqutmux.activity.registeredToken"

    /// Reports a new or dead activity token to whoever holds the gateway
    /// client.
    ///
    /// The manager does not talk to the host itself — it has no client — but
    /// the host has to hold this token or a background push cannot start or
    /// update the activity at all: an activity push is addressed to the token
    /// the system minted with the activity, not to the device.
    ///
    /// The decision lives in `AgentActivitySettings.activityTokenAction` so it
    /// can be checked without ActivityKit: registering while the switch is off,
    /// or leaving a token registered after it is turned off, are both quiet —
    /// the host holds something this device will not show and the next push
    /// starts an activity into nothing.
    private func report(_ activity: Activity<AgentActivityAttributes>, ended: Bool = false) {
        guard let data = activity.pushToken else { return }
        // The token's hex is the only form the wire takes: the gateway's check
        // is on hex, and the same bytes in any other shape are refused as
        // malformed.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        let registered = defaults.string(forKey: Self.registeredTokenKey)

        if ended {
            guard registered == hex else { return }
            onActivityToken?(hex, true)
            defaults.removeObject(forKey: Self.registeredTokenKey)
            return
        }

        let action = AgentActivitySettings.activityTokenAction(
            token: hex,
            registered: registered
        )
        switch action {
        case .register(let token):
            onActivityToken?(token, false)
            defaults.set(token, forKey: Self.registeredTokenKey)
        case .unregister(let token):
            onActivityToken?(token, true)
            defaults.removeObject(forKey: Self.registeredTokenKey)
        case .none:
            break
        }
    }

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
            latestSource: content.source,
            latestEvent: content.eventID
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
            let activity = try Activity.request(
                attributes: AgentActivityAttributes(hostName: hostName),
                content: .init(state: state, staleDate: staleDate())
            )
            self.activity = activity
            report(activity)
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
        // Reported before the activity goes: once it has ended the token is
        // dead and can no longer be read off it, so the host would keep a
        // token for an activity that no longer exists — and the next push
        // would try to update nothing.
        report(activity, ended: true)
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        return .ended
    }
}
#endif