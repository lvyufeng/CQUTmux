import SwiftUI

/// Settings → Toolbar: the material the toolbar controls sit on.
///
/// Moshi has exactly one setting here ("Settings > Toolbar > Display > Glass
/// Effect"), and it is what this models. On iOS 26 the system's own toolbar
/// material is Liquid Glass; turning it off asks for opaque surfaces instead,
/// which is what Moshi offers for people who find the translucent bar hard to
/// read over a busy terminal, and what Android's always-opaque surfaces give.
///
/// On iOS 26 this is the system's decision and the setting is honest — the
/// glass is real. Below 26 the system draws the bar itself and offers no way to
/// turn its material off, so the setting cannot do what iOS 26 does; what this
/// does instead is state that plainly rather than pretend. The one place a
/// *specific* surface can be honoured at any version is our own key bar, which
/// is a view of ours and is switched in `TerminalViewRepresentable`.
@Observable
final class ToolbarSettings {
    private enum Key {
        static let glassEffect = "cqutmux.toolbar.glassEffect"
    }

    /// Where the setting lives. Injectable so a check can use its own suite
    /// rather than editing the settings of whoever runs it.
    private let store: UserDefaults

    /// Whether the system's glass material is wanted behind the bars.
    ///
    /// On by default: it is the iOS default and the only answer that keeps the
    /// app looking like the platform it is on. Off is for someone who has
    /// decided the translucency is in the way.
    var glassEffect: Bool {
        didSet { store.set(glassEffect, forKey: Key.glassEffect) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        // `object(forKey:)` rather than `bool(forKey:)`: a `Bool` read returns
        // false for an unset key, which would make the default "off" and reset
        // every existing install the first time this store is built.
        glassEffect = store.object(forKey: Key.glassEffect) as? Bool ?? true
    }

    /// Whether the system can actually be asked to drop its glass.
    ///
    /// The setting exists on every version — hiding it below iOS 26 would mean
    /// a user who syncs their settings sees a switch that is on one device and
    /// missing on another — but below 26 the answer is no, and the screen says
    /// so instead of offering a toggle that changes nothing.
    static var canTurnOffGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}