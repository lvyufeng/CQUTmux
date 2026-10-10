import Foundation

/// The two Hooks settings the Live Activity answers to.
///
/// Both default to on, which is the state a device that has never opened this
/// screen is in — so an absent key and an explicit `true` have to read the
/// same. That is why these go through `object(forKey:)` rather than
/// `bool(forKey:)`: the latter cannot tell "never set" from "set to false", and
/// a preference screen whose off switch appears already off on first launch is
/// one the user has to correct before it works.
///
/// Written as pure functions over an injectable `UserDefaults` so a check can
/// run the shipped logic against a scratch suite instead of the real one. The
/// defaults themselves are the interesting part: whether *not yet asked* means
/// on or off is exactly the kind of thing that is silently wrong.
enum AgentActivitySettings {
    /// Whether the app starts a Live Activity at all. Off, the activity is not
    /// merely not started — one already on the Lock Screen is ended, because a
    /// switch that stops the next one and leaves this one sitting there reads as
    /// broken.
    static let enabledKey = "cqutmux.activity.enabled"

    /// Whether tapping the Live Activity lands on the Inbox.
    ///
    /// The Live Activity is always *about* a pending approval, so the Inbox is
    /// the destination that makes sense; off, the tap just opens the app where
    /// it was. The decision is made in the app rather than in the widget
    /// because the widget extension has its own `UserDefaults` container and no
    /// app group to share one through — read there, the setting would always
    /// answer with the default and the toggle would change nothing.
    static let openInboxKey = "cqutmux.activity.openInbox"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    static func opensInboxOnTap(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: openInboxKey) as? Bool ?? true
    }

    static func setOpensInboxOnTap(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: openInboxKey)
    }

    /// What to do with the host's record of this device's activity.
    ///
    /// A Live Activity push cannot start an activity unless the host holds the
    /// per-activity token the system minted when one began. That token is worth
    /// registering only while the switch is on, so the two settings are read
    /// together here rather than at the call site: turning the switch off has
    /// to *unregister*, not merely stop registering, or the host keeps a token
    /// for an activity this device will not show and the next push tries to
    /// start one into nothing.
    enum ActivityTokenAction: Equatable {
        case register(String)
        case unregister(String)
        case none
    }

    static func activityTokenAction(
        token: String?,
        enabled: Bool = isEnabled(),
        registered: String?,
        in defaults: UserDefaults = .standard
    ) -> ActivityTokenAction {
        let turnedOff = !enabled
        if turnedOff {
            // Only the token the host was actually told about is unregistered.
            // Sending an unregister for one it never saw is a request whose
            // 200 means nothing happened, and it would also clear the app's
            // memory of what the host holds.
            guard let registered else { return .none }
            return .unregister(registered)
        }
        guard let token, !token.isEmpty else { return .none }
        // Already registered: re-sending the same token on every start is a
        // no-op the host sees as a duplicate, and a token that changed is a new
        // activity the host has to hear about.
        if token == registered { return .none }
        return .register(token)
    }

    /// Clears both, which is what the test reset needs: a suite with no keys
    /// has to behave exactly like a fresh install.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: openInboxKey)
    }
}