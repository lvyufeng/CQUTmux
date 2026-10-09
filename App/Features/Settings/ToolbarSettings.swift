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
        static let pinchAction = "cqutmux.toolbar.pinchAction"
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
        pinchAction = PinchAction(rawValue: store.string(forKey: Key.pinchAction) ?? "") ?? .fontSize
    }

    /// What a pinch on the terminal does.
    ///
    /// Moshi's own documentation is explicit that pinch zooms the focused
    /// multiplexer pane and back. That is *not* the reading this app defaults
    /// to: a pinch has been the font-size control here since before this
    /// setting existed, and it is the only way to resize the terminal's text
    /// without leaving a session. Silently moving it would make the app feel
    /// like it had lost a control. So both are offered, and the font is what a
    /// pinch does until the user says otherwise — the deliberate divergence is
    /// preserved as the default and the documented behaviour is a choice.
    enum PinchAction: String, CaseIterable, Identifiable, Codable {
        /// Resize the terminal text, and remember the size.
        case fontSize
        /// Send the multiplexer's own zoom binding.
        case zoomPane

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fontSize: "Terminal font size"
            case .zoomPane: "Zoom the focused pane"
            }
        }

        var detail: String {
            switch self {
            case .fontSize:
                "Pinching out enlarges the text and pinching back shrinks it, and the "
                + "size is kept for the next session. This is what a pinch does today, "
                + "and the only way to resize text without leaving the session."
            case .zoomPane:
                "Pinching out asks the host to full-screen the focused pane and pinching "
                + "back restores the layout. Needs a multiplexer on the host that has a "
                + "zoom binding, which tmux, herdr and zellij all do. Font size then has "
                + "to be changed here in Settings. On a host with no multiplexer a pinch "
                + "still resizes the text, so the gesture is never dead."
            }
        }
    }

    var pinchAction: PinchAction {
        didSet { store.set(pinchAction.rawValue, forKey: Key.pinchAction) }
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