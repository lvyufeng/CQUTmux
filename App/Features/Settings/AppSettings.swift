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
        static let contextLimit = "cqutmux.agents.contextLimit"
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

    /// The context-window size the Inbox ring measures against.
    ///
    /// Not discoverable from the agent's log, which records how many tokens each
    /// turn used but never how many fit. A wrong denominator shows the ring at
    /// the wrong fullness with nothing to indicate it, so the value is editable
    /// and the settings screen says outright that it is an assumption. Zero
    /// means "do not draw the ring", which is also how the row reads when the
    /// number is not wanted.
    var contextLimit: Int {
        didSet { store.set(contextLimit, forKey: Key.contextLimit) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        hidesCodeTab = store.bool(forKey: Key.hidesCodeTab)
        hidesFiles = store.bool(forKey: Key.hidesFiles)
        keepScreenOn = store.bool(forKey: Key.keepAwake)
        // Absent and zero must not collapse: absent means "never chosen" and
        // has to default to the assumed window, while an explicit zero means
        // the user turned the ring off. `integer(forKey:)` cannot tell them
        // apart, and reading a deliberate zero as unset would turn the ring
        // back on at every relaunch.
        contextLimit = store.object(forKey: Key.contextLimit) as? Int ?? ContextWindow.defaultLimit
    }
}