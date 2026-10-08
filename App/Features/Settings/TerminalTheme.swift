import SwiftUI
import SwiftTerm

/// A terminal palette: background, foreground, cursor and the 16 ANSI colours.
/// Mirrors Moshi's theme list (Dracula, Nord, Solarized, Gruvbox, Catppuccin…).
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let dark: Bool
    let background: String
    let foreground: String
    let cursor: String
    /// 16 ANSI colours, each `rrggbb`.
    let ansi: [String]

    var isBuiltInFavourite: Bool { ["dracula", "nord", "gruvbox"].contains(id) }

    var backgroundColor: SwiftUI.Color { SwiftUI.Color(hex: background) }
    var foregroundColor: SwiftUI.Color { SwiftUI.Color(hex: foreground) }

    /// The 16-entry palette SwiftTerm expects.
    func palette() -> [SwiftTerm.Color] {
        ansi.map(Self.termColor)
    }

    /// Builds a SwiftTerm color from `rrggbb`, scaling 8-bit channels to 16-bit.
    private static func termColor(_ hex: String) -> SwiftTerm.Color {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return SwiftTerm.Color(
            red: UInt16((value >> 16) & 0xff) * 257,
            green: UInt16((value >> 8) & 0xff) * 257,
            blue: UInt16(value & 0xff) * 257
        )
    }

    /// Applies the theme to a live terminal view.
    func apply(to view: TerminalView) {
        view.installColors(palette())
        view.nativeBackgroundColor = backgroundColor.uiColor
        view.nativeForegroundColor = foregroundColor.uiColor
    }
}

extension TerminalTheme {
    static let builtIn: [TerminalTheme] = [
        .init(id: "dracula", name: "Dracula", dark: true,
              background: "282a36", foreground: "f8f8f2", cursor: "f8f8f2",
              ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
                     "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff"]),
        .init(id: "nord", name: "Nord", dark: true,
              background: "2e3440", foreground: "d8dee9", cursor: "d8dee9",
              ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                     "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"]),
        .init(id: "solarized-dark", name: "Solarized Dark", dark: true,
              background: "002b36", foreground: "839496", cursor: "93a1a1",
              ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                     "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        .init(id: "gruvbox", name: "Gruvbox", dark: true,
              background: "282828", foreground: "ebdbb2", cursor: "ebdbb2",
              ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                     "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]),
        .init(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true,
              background: "1e1e2e", foreground: "cdd6f4", cursor: "f5e0dc",
              ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
                     "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8"]),
        .init(id: "solarized-light", name: "Solarized Light", dark: false,
              background: "fdf6e3", foreground: "657b83", cursor: "586e75",
              ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                     "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        .init(id: "github-light", name: "GitHub Light", dark: false,
              background: "ffffff", foreground: "24292f", cursor: "24292f",
              ansi: ["24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781",
                     "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"]),
    ]

    static func named(_ id: String?) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? builtIn[0]
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