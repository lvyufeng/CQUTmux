import SwiftUI
import SwiftTerm
import UIKit

/// The parts of a theme that only exist on screen: the colours resolved for
/// SwiftUI, and the palette handed to the terminal.
///
/// Kept apart from `TerminalTheme.swift` so the model and its parser — the
/// parts that decide whether an imported theme is even valid — can be compiled
/// and checked on their own, without a simulator. See
/// `scripts/theme-format/run.sh`.
extension TerminalTheme {
    var backgroundColor: SwiftUI.Color { SwiftUI.Color(hex: background) }
    var foregroundColor: SwiftUI.Color { SwiftUI.Color(hex: foreground) }

    /// The 16-entry palette SwiftTerm expects.
    func palette() -> [SwiftTerm.Color] {
        ansi.map(Self.termColor)
    }

    /// Builds a SwiftTerm color from `rrggbb`, scaling 8-bit channels to 16-bit.
    static func termColor(_ hex: String) -> SwiftTerm.Color {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return SwiftTerm.Color(
            red: UInt16((value >> 16) & 0xff) * 257,
            green: UInt16((value >> 8) & 0xff) * 257,
            blue: UInt16(value & 0xff) * 257
        )
    }

    /// Applies the palette and the background, foreground and selection
    /// colours to a terminal view.
    ///
    /// The cursor is deliberately not here. `caretColor` writes through to a
    /// caret subview that SwiftTerm only creates partway through its own setup,
    /// so a colour set in an initialiser is dropped — the setter stores it into
    /// a nil view and never sees it again. It is applied by
    /// `CQUTTerminalView.applyTheme` once that view exists.
    func apply(to view: TerminalView) {
        view.installColors(palette())
        view.selectedTextBackgroundColor = selectionBackground.uiColor
        view.nativeBackgroundColor = backgroundColor.uiColor
        view.nativeForegroundColor = foregroundColor.uiColor
    }
}

extension SwiftUI.Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    var uiColor: UIColor {
        UIColor(self)
    }
}

/// The colours a theme gives the parts of the app that are not terminal cells.
///
/// Split from the ANSI palette because the two come from different places. The
/// 16 ANSI colours are what a program running *inside* the terminal asks for by
/// number; `accent` and `selection` are what the app itself paints. Moshi
/// derives the second from the theme rather than offering it separately, and
/// the reason is visible as soon as you pick a light theme: chrome that stayed
/// on the dark palette would defeat the point of choosing one.
extension TerminalTheme {
    /// Marks selection, emphasis and live state. Every built-in theme leaves
    /// this at the app's green; an imported theme may name its own.
    ///
    /// This is the whole of the app's chrome treatment: it feeds `.tint` at the
    /// root, and the system paints the rest of the surfaces itself once
    /// `preferredColorScheme` matches the theme's mode. There is deliberately no
    /// `chromeBackground`: handing SwiftUI a background colour per surface is
    /// how a theme ends up fighting dark mode instead of agreeing with it.
    var accentColor: SwiftUI.Color { SwiftUI.Color(hex: accent) }

    /// The surface for a bar we draw ourselves when the glass is turned off.
    ///
    /// This is not the `chromeBackground` the note above rejects. That would be
    /// a colour painted on *every* surface, which is how a theme ends up
    /// disagreeing with the colour scheme it is in. This is one colour, for one
    /// narrow case — a bar that must stop being translucent — and it is the
    /// theme's own background, so an opaque bar is the terminal's colour rather
    /// than a second guess at what "dark" is. The bar and the terminal it sits
    /// over then share one surface, which is the whole point of the opaque
    /// option.
    var barSurface: SwiftUI.Color { backgroundColor }

    /// Behind a text selection. Derived when the theme names none: a blend of
    /// background and accent reads as "selected" in both dark and light themes
    /// without needing a constant per theme.
    var selectionBackground: SwiftUI.Color {
        if let selection { return SwiftUI.Color(hex: selection) }
        return backgroundColor.blended(with: accentColor, fraction: 0.35)
    }

    /// The cursor block. The field exists because a cursor that inherits the
    /// foreground disappears on themes where the two are close.
    var cursorColor: SwiftUI.Color { SwiftUI.Color(hex: cursor) }
}

extension SwiftUI.Color {
    /// Mixes two colours, used to derive a selection colour rather than making
    /// every theme author pick one.
    ///
    /// `fraction` is how much of `other` to take: 0 is the receiver, 1 is the
    /// other colour.
    func blended(with other: SwiftUI.Color, fraction: Double) -> SwiftUI.Color {
        let t = min(max(fraction, 0), 1)
        let a = UIColor(self).rgba
        let b = UIColor(other).rgba
        return SwiftUI.Color(
            red: a.r + (b.r - a.r) * t,
            green: a.g + (b.g - a.g) * t,
            blue: a.b + (b.b - a.b) * t
        )
    }
}

extension UIColor {
    /// The four sRGB components, or black when the colour cannot be converted —
    /// a named or pattern colour, which none of ours are.
    var rgba: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return (0, 0, 0, 1) }
        return (Double(r), Double(g), Double(b), Double(a))
    }
}