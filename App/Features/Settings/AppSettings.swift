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
        static let hidesFiles = "cqutmux.code.hidesFiles"
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

    /// Whether the Files browser is kept out of the Code panel's modes.
    ///
    /// Separate from hiding the whole Code tab because they answer different
    /// questions: that one is "I do not use this tab", this one is "I use the
    /// diff and the transcript but browse files elsewhere". Named `hides…` for
    /// the same reason as the other, so an existing install keeps every mode it
    /// had until someone turns one off.
    var hidesFiles: Bool {
        didSet { store.set(hidesFiles, forKey: Key.hidesFiles) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        hidesCodeTab = store.bool(forKey: Key.hidesCodeTab)
        hidesFiles = store.bool(forKey: Key.hidesFiles)
        keepScreenOn = store.bool(forKey: Key.keepAwake)
    }
}