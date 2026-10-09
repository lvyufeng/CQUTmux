import Foundation

/// A terminal palette: background, foreground, cursor, the 16 ANSI colours, and
/// the accent and selection colours the app paints for itself.
///
/// Mirrors Moshi's theme list (Dracula, Nord, Solarized, Gruvbox, Catppuccin,
/// Rosé Pine…). Built-ins and imported themes are the same type, so everything
/// downstream — the picker, the terminal, an exported `moshi-theme:` string —
/// treats them alike and an imported theme is not a second-class one.
///
/// Deliberately free of SwiftUI and SwiftTerm: the screen colours are in
/// `TerminalTheme+Terminal.swift`. That split is what lets the theme format and
/// its parser be checked without a simulator.
struct TerminalTheme: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let dark: Bool
    let background: String
    let foreground: String
    let cursor: String
    /// Marks selection and live state. The app's green in every built-in theme.
    let accent: String
    /// Behind a text selection. Optional: derived from background and accent
    /// when a theme does not name one.
    let selection: String?
    /// 16 ANSI colours, each `rrggbb`.
    let ansi: [String]

    /// A theme the user imported rather than one that ships. Computed from the
    /// id so an import survives a restart without another stored field.
    var isImported: Bool { id.hasPrefix("imported-") }
}

extension TerminalTheme {
    /// The colour Moshi's default theme and all our built-ins use for accents.
    static let defaultAccent = "33e673"

    static let builtIn: [TerminalTheme] = [
        .init(id: "moshi", name: "Moshi", dark: true,
              background: "0f1411", foreground: "e6f1ea", cursor: "33e673",
              accent: defaultAccent, selection: nil,
              ansi: ["1c2320", "ff6b6b", "33e673", "f5d76e", "6cb6ff", "c792ea", "5fd3c4", "d8e2dc",
                     "3a453f", "ff8787", "5dffa0", "ffe082", "8fcbff", "dcb6ff", "7fe6d8", "f2f7f4"]),
        .init(id: "dracula", name: "Dracula", dark: true,
              background: "282a36", foreground: "f8f8f2", cursor: "f8f8f2",
              accent: defaultAccent, selection: nil,
              ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
                     "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff"]),
        .init(id: "nord", name: "Nord", dark: true,
              background: "2e3440", foreground: "d8dee9", cursor: "d8dee9",
              accent: defaultAccent, selection: nil,
              ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                     "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"]),
        .init(id: "solarized-dark", name: "Solarized Dark", dark: true,
              background: "002b36", foreground: "839496", cursor: "93a1a1",
              accent: defaultAccent, selection: nil,
              ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                     "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        .init(id: "gruvbox", name: "Gruvbox", dark: true,
              background: "282828", foreground: "ebdbb2", cursor: "ebdbb2",
              accent: defaultAccent, selection: nil,
              ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                     "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]),
        .init(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true,
              background: "1e1e2e", foreground: "cdd6f4", cursor: "f5e0dc",
              accent: defaultAccent, selection: nil,
              ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
                     "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8"]),
        .init(id: "solarized-light", name: "Solarized Light", dark: false,
              background: "fdf6e3", foreground: "657b83", cursor: "586e75",
              accent: defaultAccent, selection: nil,
              ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                     "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        .init(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false,
              background: "eff1f5", foreground: "4c4f69", cursor: "dc8a78",
              accent: defaultAccent, selection: nil,
              ansi: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be",
                     "6c6f85", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "bcc0cc"]),
        .init(id: "github-light", name: "GitHub Light", dark: false,
              background: "ffffff", foreground: "24292f", cursor: "24292f",
              accent: defaultAccent, selection: nil,
              ansi: ["24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781",
                     "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"]),
        // Rosé Pine Dawn, the light half of the Rosé Pine pair. The palette is
        // the published one — the same sixteen colours the upstream project
        // ships for terminals — rather than an approximation from the
        // background and accent, because a theme is recognisable by its whole
        // ramp and a near-miss reads as the theme being wrong.
        .init(id: "rose-pine-dawn", name: "Rosé Pine Dawn", dark: false,
              background: "faf4ed", foreground: "575279", cursor: "575279",
              accent: defaultAccent, selection: nil,
              ansi: ["f2e9e1", "b4637a", "56949f", "ea9d34", "286983", "907aa9", "d7827e", "575279",
                     "9893a5", "b4637a", "56949f", "ea9d34", "286983", "907aa9", "d7827e", "575279"]),
    ]

    static func named(_ id: String?) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? builtIn[0]
    }

    /// Decoding tolerates a stored theme written before `accent` existed, since
    /// the user's imports are on disk and a decode failure would silently drop
    /// them all. Only the fields added over time need this.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dark = try container.decode(Bool.self, forKey: .dark)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        cursor = try container.decode(String.self, forKey: .cursor)
        accent = try container.decodeIfPresent(String.self, forKey: .accent) ?? Self.defaultAccent
        selection = try container.decodeIfPresent(String.self, forKey: .selection)
        ansi = try container.decode([String].self, forKey: .ansi)
    }
}