import Foundation
import Observation

/// Settings → Agents: things that apply to the app rather than to one session.
///
/// Small enough that a store of its own would be ceremony, but it is one
/// because these are the two settings Moshi puts under Agents and both have to
/// survive a relaunch.
@Observable
final class AppSettings {
    private enum Key {
        static let hidesCodeTab = "cqutmux.home.hidesCodeTab"
        static let keepAwake = "cqutmux.agents.keepScreenOn"
    }

    private let store: UserDefaults

    /// Whether the Code tab is kept out of the home screen.
    ///
    /// Named for hiding rather than showing because that is the state that
    /// differs from the default: on is off, and a key whose absence means
    /// "visible" is what keeps every existing install unchanged the first time
    /// this store is built.
    var hidesCodeTab: Bool {
        didSet { store.set(hidesCodeTab, forKey: Key.hidesCodeTab) }
    }

    /// Whether the screen is held awake while the Agents screen is in front.
    ///
    /// Off by default. A session left open on a desk is the reason to want it,
    /// and a phone that will not sleep is the reason not to have it always on —
    /// neither is right for everyone, so it is a switch rather than a decision.
    var keepScreenOn: Bool {
        didSet { store.set(keepScreenOn, forKey: Key.keepAwake) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        hidesCodeTab = store.bool(forKey: Key.hidesCodeTab)
        keepScreenOn = store.bool(forKey: Key.keepAwake)
    }
}