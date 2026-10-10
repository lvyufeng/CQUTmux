import Foundation

/// The catalogue of themes the app can import from, without a network.
///
/// Moshi serves a gallery of several hundred themes from `/themes` and lets you
/// re-fetch one by slug. That server is not ours to call, so the gallery here is
/// a catalogue that *ships with the app*: same shape — a name, a slug, a mode,
/// and a v1 theme document — and the same two operations the claim names,
/// browsing and re-importing by slug. What it does not have is Moshi's server's
/// count; inventing several hundred palettes to reach a number would be a worse
/// answer than shipping the ones that are real and saying so.
///
/// Foundation-only and separate from the view because the rules are quiet when
/// wrong: a slug that does not match what `ThemeImport` derives means a
/// re-import creates a *second* copy instead of updating the first, and a
/// catalogue whose documents do not parse is a gallery whose every entry fails
/// on tap with nothing to explain why.
enum ThemeGallery {
    /// One entry: enough to draw a row, and the document to import.
    struct Entry: Identifiable, Hashable {
        /// The stable id, and the thing "re-fetch by slug" names. Matches what
        /// `ThemeImport` derives from the theme's own name, so importing a
        /// gallery entry and importing its JSON by hand produce the same id —
        /// which is what makes the second import an update rather than a
        /// duplicate.
        var slug: String
        var name: String
        var dark: Bool
        /// The theme as a v1 document, the same text the paste box takes. Kept
        /// as the document rather than as parsed colours so the gallery and a
        /// hand-pasted theme go through one parser, and a document that does not
        /// parse fails the same way in both.
        var json: String

        var id: String { slug }
    }

    /// Bumped whenever the bundled catalogue changes, so an app that shipped an
    /// older one can tell that a slug it holds has a newer document. This is the
    /// local stand-in for the server's version, and it is what "re-fetchable"
    /// means without a server: the entry can be re-read and re-imported.
    static let version = 1

    /// The catalogue, in the order the gallery lists it.
    static let entries: [Entry] = [
        entry("Dracula", dark: true, bg: "282a36", fg: "f8f8f2", cursor: "f8f8f2", colors: [
            "black": "21222c", "red": "ff5555", "green": "50fa7b", "yellow": "f1fa8c",
            "blue": "bd93f9", "magenta": "ff79c6", "cyan": "8be9fd", "white": "f8f8f2",
            "brightBlack": "6272a4", "brightRed": "ff6e6e", "brightGreen": "69ff94",
            "brightYellow": "ffffa5", "brightBlue": "d6acff", "brightMagenta": "ff92df",
            "brightCyan": "a4ffff", "brightWhite": "ffffff",
        ]),
        entry("Nord", dark: true, bg: "2e3440", fg: "d8dee9", cursor: "d8dee9", colors: [
            "black": "3b4252", "red": "bf616a", "green": "a3be8c", "yellow": "ebcb8b",
            "blue": "81a1c1", "magenta": "b48ead", "cyan": "88c0d0", "white": "e5e9f0",
            "brightBlack": "4c566a", "brightRed": "bf616a", "brightGreen": "a3be8c",
            "brightYellow": "ebcb8b", "brightBlue": "81a1c1", "brightMagenta": "b48ead",
            "brightCyan": "8fbcbb", "brightWhite": "eceff4",
        ]),
        entry("Solarized Dark", dark: true, bg: "002b36", fg: "839496", cursor: "93a1a1", colors: [
            "black": "073642", "red": "dc322f", "green": "859900", "yellow": "b58900",
            "blue": "268bd2", "magenta": "d33682", "cyan": "2aa198", "white": "eee8d5",
            "brightBlack": "002b36", "brightRed": "cb4b16", "brightGreen": "586e75",
            "brightYellow": "657b83", "brightBlue": "839496", "brightMagenta": "6c71c4",
            "brightCyan": "93a1a1", "brightWhite": "fdf6e3",
        ]),
        entry("Solarized Light", dark: false, bg: "fdf6e3", fg: "657b83", cursor: "586e75", colors: [
            "black": "073642", "red": "dc322f", "green": "859900", "yellow": "b58900",
            "blue": "268bd2", "magenta": "d33682", "cyan": "2aa198", "white": "eee8d5",
            "brightBlack": "002b36", "brightRed": "cb4b16", "brightGreen": "586e75",
            "brightYellow": "657b83", "brightBlue": "839496", "brightMagenta": "6c71c4",
            "brightCyan": "93a1a1", "brightWhite": "fdf6e3",
        ]),
        entry("Gruvbox Dark", dark: true, bg: "282828", fg: "ebdbb2", cursor: "ebdbb2", colors: [
            "black": "282828", "red": "cc241d", "green": "98971a", "yellow": "d79921",
            "blue": "458588", "magenta": "b16286", "cyan": "689d6a", "white": "a89984",
            "brightBlack": "928374", "brightRed": "fb4934", "brightGreen": "b8bb26",
            "brightYellow": "fabd2f", "brightBlue": "83a598", "brightMagenta": "d3869b",
            "brightCyan": "8ec07c", "brightWhite": "ebdbb2",
        ]),
        entry("Gruvbox Light", dark: false, bg: "fbf1c7", fg: "3c3836", cursor: "3c3836", colors: [
            "black": "fbf1c7", "red": "9d0006", "green": "79740e", "yellow": "b57614",
            "blue": "076678", "magenta": "8f3f71", "cyan": "427b58", "white": "3c3836",
            "brightBlack": "928374", "brightRed": "9d0006", "brightGreen": "79740e",
            "brightYellow": "b57614", "brightBlue": "076678", "brightMagenta": "8f3f71",
            "brightCyan": "427b58", "brightWhite": "282828",
        ]),
        entry("Catppuccin Mocha", dark: true, bg: "1e1e2e", fg: "cdd6f4", cursor: "f5e0dc", colors: [
            "black": "45475a", "red": "f38ba8", "green": "a6e3a1", "yellow": "f9e2af",
            "blue": "89b4fa", "magenta": "f5c2e7", "cyan": "94e2d5", "white": "bac2de",
            "brightBlack": "585b70", "brightRed": "f38ba8", "brightGreen": "a6e3a1",
            "brightYellow": "f9e2af", "brightBlue": "89b4fa", "brightMagenta": "f5c2e7",
            "brightCyan": "94e2d5", "brightWhite": "a6adc8",
        ]),
        entry("Catppuccin Latte", dark: false, bg: "eff1f5", fg: "4c4f69", cursor: "dc8a78", colors: [
            "black": "5c5f77", "red": "d20f39", "green": "40a02b", "yellow": "df8e1d",
            "blue": "1e66f5", "magenta": "ea76cb", "cyan": "179299", "white": "acb0be",
            "brightBlack": "6c6f85", "brightRed": "d20f39", "brightGreen": "40a02b",
            "brightYellow": "df8e1d", "brightBlue": "1e66f5", "brightMagenta": "ea76cb",
            "brightCyan": "179299", "brightWhite": "bcc0cc",
        ]),
        entry("Rosé Pine", dark: true, bg: "191724", fg: "e0def4", cursor: "524f67", colors: [
            "black": "26233a", "red": "eb6f92", "green": "31748f", "yellow": "f6c177",
            "blue": "9ccfd8", "magenta": "c4a7e7", "cyan": "ebbcba", "white": "e0def4",
            "brightBlack": "6e6a86", "brightRed": "eb6f92", "brightGreen": "31748f",
            "brightYellow": "f6c177", "brightBlue": "9ccfd8", "brightMagenta": "c4a7e7",
            "brightCyan": "ebbcba", "brightWhite": "e0def4",
        ]),
        entry("Rosé Pine Dawn", dark: false, bg: "faf4ed", fg: "575279", cursor: "575279", colors: [
            "black": "f2e9e1", "red": "b4637a", "green": "56949f", "yellow": "ea9d34",
            "blue": "286983", "magenta": "907aa9", "cyan": "d7827e", "white": "575279",
            "brightBlack": "9893a5", "brightRed": "b4637a", "brightGreen": "56949f",
            "brightYellow": "ea9d34", "brightBlue": "286983", "brightMagenta": "907aa9",
            "brightCyan": "d7827e", "brightWhite": "575279",
        ]),
        entry("Rosé Pine Moon", dark: true, bg: "232136", fg: "e0def4", cursor: "56526e", colors: [
            "black": "393552", "red": "eb6f92", "green": "3e8fb0", "yellow": "f6c177",
            "blue": "9ccfd8", "magenta": "c4a7e7", "cyan": "ea9a97", "white": "e0def4",
            "brightBlack": "6e6a86", "brightRed": "eb6f92", "brightGreen": "3e8fb0",
            "brightYellow": "f6c177", "brightBlue": "9ccfd8", "brightMagenta": "c4a7e7",
            "brightCyan": "ea9a97", "brightWhite": "e0def4",
        ]),
        entry("Tokyo Night", dark: true, bg: "1a1b26", fg: "c0caf5", cursor: "c0caf5", colors: [
            "black": "15161e", "red": "f7768e", "green": "9ece6a", "yellow": "e0af68",
            "blue": "7aa2f7", "magenta": "bb9af7", "cyan": "7dcfff", "white": "a9b1d6",
            "brightBlack": "414868", "brightRed": "f7768e", "brightGreen": "9ece6a",
            "brightYellow": "e0af68", "brightBlue": "7aa2f7", "brightMagenta": "bb9af7",
            "brightCyan": "7dcfff", "brightWhite": "c0caf5",
        ]),
        entry("Tokyo Night Storm", dark: true, bg: "24283b", fg: "c0caf5", cursor: "c0caf5", colors: [
            "black": "1d202f", "red": "f7768e", "green": "9ece6a", "yellow": "e0af68",
            "blue": "7aa2f7", "magenta": "bb9af7", "cyan": "7dcfff", "white": "a9b1d6",
            "brightBlack": "414868", "brightRed": "f7768e", "brightGreen": "9ece6a",
            "brightYellow": "e0af68", "brightBlue": "7aa2f7", "brightMagenta": "bb9af7",
            "brightCyan": "7dcfff", "brightWhite": "c0caf5",
        ]),
        entry("One Dark", dark: true, bg: "282c34", fg: "abb2bf", cursor: "528bff", colors: [
            "black": "282c34", "red": "e06c75", "green": "98c379", "yellow": "e5c07b",
            "blue": "61afef", "magenta": "c678dd", "cyan": "56b6c2", "white": "abb2bf",
            "brightBlack": "5c6370", "brightRed": "e06c75", "brightGreen": "98c379",
            "brightYellow": "e5c07b", "brightBlue": "61afef", "brightMagenta": "c678dd",
            "brightCyan": "56b6c2", "brightWhite": "ffffff",
        ]),
        entry("One Light", dark: false, bg: "fafafa", fg: "383a42", cursor: "526fff", colors: [
            "black": "383a42", "red": "e45649", "green": "50a14f", "yellow": "c18401",
            "blue": "4078f2", "magenta": "a626a4", "cyan": "0184bc", "white": "a0a1a7",
            "brightBlack": "696c77", "brightRed": "e45649", "brightGreen": "50a14f",
            "brightYellow": "c18401", "brightBlue": "4078f2", "brightMagenta": "a626a4",
            "brightCyan": "0184bc", "brightWhite": "202227",
        ]),
        entry("Ayu Dark", dark: true, bg: "0b0e14", fg: "bfbdb6", cursor: "e6b450", colors: [
            "black": "11151c", "red": "ea6c73", "green": "7fd962", "yellow": "f9af4f",
            "blue": "53bdfa", "magenta": "cda1fa", "cyan": "90e1c6", "white": "c7c7c7",
            "brightBlack": "686868", "brightRed": "f07178", "brightGreen": "aad94c",
            "brightYellow": "ffb454", "brightBlue": "59c2ff", "brightMagenta": "d2a6ff",
            "brightCyan": "95e6cb", "brightWhite": "ffffff",
        ]),
        entry("Ayu Mirage", dark: true, bg: "1f2430", fg: "cbccc6", cursor: "ffcc66", colors: [
            "black": "191e2a", "red": "ed8274", "green": "a6cc70", "yellow": "fad07b",
            "blue": "6dcbfa", "magenta": "cfbafa", "cyan": "90e1c6", "white": "c7c7c7",
            "brightBlack": "686868", "brightRed": "f28779", "brightGreen": "bae67e",
            "brightYellow": "ffd580", "brightBlue": "73d0ff", "brightMagenta": "d4bfff",
            "brightCyan": "95e6cb", "brightWhite": "ffffff",
        ]),
        entry("Ayu Light", dark: false, bg: "fafafa", fg: "5c6166", cursor: "ff9940", colors: [
            "black": "000000", "red": "ff3333", "green": "86b300", "yellow": "f2ae49",
            "blue": "22a4e6", "magenta": "a37acc", "cyan": "4cbf99", "white": "ffffff",
            "brightBlack": "323232", "brightRed": "ff6565", "brightGreen": "a6cc70",
            "brightYellow": "ffd580", "brightBlue": "59c2ff", "brightMagenta": "cda1fa",
            "brightCyan": "95e6cb", "brightWhite": "ffffff",
        ]),
        entry("GitHub Dark", dark: true, bg: "0d1117", fg: "c9d1d9", cursor: "c9d1d9", colors: [
            "black": "484f58", "red": "ff7b72", "green": "3fb950", "yellow": "d29922",
            "blue": "58a6ff", "magenta": "bc8cff", "cyan": "39c5cf", "white": "b1bac4",
            "brightBlack": "6e7681", "brightRed": "ffa198", "brightGreen": "56d364",
            "brightYellow": "e3b341", "brightBlue": "79c0ff", "brightMagenta": "d2a8ff",
            "brightCyan": "56d4dd", "brightWhite": "f0f6fc",
        ]),
        entry("GitHub Light", dark: false, bg: "ffffff", fg: "24292f", cursor: "24292f", colors: [
            "black": "24292f", "red": "cf222e", "green": "116329", "yellow": "4d2d00",
            "blue": "0969da", "magenta": "8250df", "cyan": "1b7c83", "white": "6e7781",
            "brightBlack": "57606a", "brightRed": "a40e26", "brightGreen": "1a7f37",
            "brightYellow": "633c01", "brightBlue": "218bff", "brightMagenta": "a475f9",
            "brightCyan": "3192aa", "brightWhite": "8c959f",
        ]),
        entry("Material", dark: true, bg: "263238", fg: "eeffff", cursor: "ffcc00", colors: [
            "black": "000000", "red": "ff5370", "green": "c3e88d", "yellow": "ffcb6b",
            "blue": "82aaff", "magenta": "c792ea", "cyan": "89ddff", "white": "ffffff",
            "brightBlack": "546e7a", "brightRed": "ff5370", "brightGreen": "c3e88d",
            "brightYellow": "ffcb6b", "brightBlue": "82aaff", "brightMagenta": "c792ea",
            "brightCyan": "89ddff", "brightWhite": "ffffff",
        ]),
        entry("Material Palenight", dark: true, bg: "292d3e", fg: "a6accd", cursor: "ffcc00", colors: [
            "black": "292d3e", "red": "f07178", "green": "c3e88d", "yellow": "ffcb6b",
            "blue": "82aaff", "magenta": "c792ea", "cyan": "89ddff", "white": "d0d0d0",
            "brightBlack": "676e95", "brightRed": "f07178", "brightGreen": "c3e88d",
            "brightYellow": "ffcb6b", "brightBlue": "82aaff", "brightMagenta": "c792ea",
            "brightCyan": "89ddff", "brightWhite": "ffffff",
        ]),
        entry("Everforest Dark", dark: true, bg: "2d353b", fg: "d3c6aa", cursor: "d3c6aa", colors: [
            "black": "475258", "red": "e67e80", "green": "a7c080", "yellow": "dbbc7f",
            "blue": "7fbbb3", "magenta": "d699b6", "cyan": "83c092", "white": "d3c6aa",
            "brightBlack": "7a8478", "brightRed": "e67e80", "brightGreen": "a7c080",
            "brightYellow": "dbbc7f", "brightBlue": "7fbbb3", "brightMagenta": "d699b6",
            "brightCyan": "83c092", "brightWhite": "d3c6aa",
        ]),
        entry("Kanagawa", dark: true, bg: "1f1f28", fg: "dcd7ba", cursor: "c8c093", colors: [
            "black": "16161d", "red": "c34043", "green": "76946a", "yellow": "c0a36e",
            "blue": "7e9cd8", "magenta": "957fb8", "cyan": "6a9589", "white": "c8c093",
            "brightBlack": "727169", "brightRed": "e82424", "brightGreen": "98bb6c",
            "brightYellow": "e6c384", "brightBlue": "7fb4ca", "brightMagenta": "938aa9",
            "brightCyan": "7aa89f", "brightWhite": "dcd7ba",
        ]),
        entry("Night Owl", dark: true, bg: "011627", fg: "d6deeb", cursor: "80a4c2", colors: [
            "black": "011627", "red": "ef5350", "green": "22da6e", "yellow": "addb67",
            "blue": "82aaff", "magenta": "c792ea", "cyan": "21c7a8", "white": "ffffff",
            "brightBlack": "575656", "brightRed": "ef5350", "brightGreen": "22da6e",
            "brightYellow": "ffeb95", "brightBlue": "82aaff", "brightMagenta": "c792ea",
            "brightCyan": "7fdbca", "brightWhite": "ffffff",
        ]),
        entry("Palenight", dark: true, bg: "292d3e", fg: "bfc7d5", cursor: "ffcc00", colors: [
            "black": "292d3e", "red": "f07178", "green": "c3e88d", "yellow": "ffcb6b",
            "blue": "82aaff", "magenta": "c792ea", "cyan": "89ddff", "white": "d0d0d0",
            "brightBlack": "676e95", "brightRed": "f07178", "brightGreen": "c3e88d",
            "brightYellow": "ffcb6b", "brightBlue": "82aaff", "brightMagenta": "c792ea",
            "brightCyan": "89ddff", "brightWhite": "ffffff",
        ]),
        entry("Horizon", dark: true, bg: "1c1e26", fg: "d5d8da", cursor: "d5d8da", colors: [
            "black": "16161c", "red": "e95678", "green": "29d398", "yellow": "fab795",
            "blue": "26bbd9", "magenta": "ee64ac", "cyan": "59e3e3", "white": "d5d8da",
            "brightBlack": "6c6f93", "brightRed": "ec6a88", "brightGreen": "3fdaa4",
            "brightYellow": "fbc3a7", "brightBlue": "3fc6de", "brightMagenta": "f075b7",
            "brightCyan": "6be6e6", "brightWhite": "d5d8da",
        ]),
        entry("Iceberg Dark", dark: true, bg: "161821", fg: "c6c8d1", cursor: "c6c8d1", colors: [
            "black": "1e2132", "red": "e27878", "green": "b4be82", "yellow": "e2a478",
            "blue": "84a0c6", "magenta": "a093c7", "cyan": "89b8c2", "white": "c6c8d1",
            "brightBlack": "6b7089", "brightRed": "e98989", "brightGreen": "c0ca8e",
            "brightYellow": "e9b189", "brightBlue": "91acd1", "brightMagenta": "ada0d3",
            "brightCyan": "95c4ce", "brightWhite": "d2d4de",
        ]),
        entry("Iceberg Light", dark: false, bg: "e8e9ec", fg: "33374c", cursor: "33374c", colors: [
            "black": "dcdfe7", "red": "cc517a", "green": "668e3d", "yellow": "c57339",
            "blue": "2d539e", "magenta": "7759b4", "cyan": "3f83a6", "white": "33374c",
            "brightBlack": "8389a3", "brightRed": "cc3768", "brightGreen": "598030",
            "brightYellow": "b6662d", "brightBlue": "22478e", "brightMagenta": "6845ad",
            "brightCyan": "327698", "brightWhite": "262a3f",
        ]),
        entry("Vesper", dark: true, bg: "101010", fg: "ffffff", cursor: "ffc799", colors: [
            "black": "101010", "red": "ff8080", "green": "99ffe4", "yellow": "ffc799",
            "blue": "a0a0a0", "magenta": "ff8080", "cyan": "99ffe4", "white": "e0e0e0",
            "brightBlack": "7e7e7e", "brightRed": "ff8080", "brightGreen": "99ffe4",
            "brightYellow": "ffc799", "brightBlue": "a0a0a0", "brightMagenta": "ff8080",
            "brightCyan": "99ffe4", "brightWhite": "ffffff",
        ]),
        entry("Zenburn", dark: true, bg: "3f3f3f", fg: "dcdccc", cursor: "73635a", colors: [
            "black": "4d4d4d", "red": "705050", "green": "60b48a", "yellow": "f0dfaf",
            "blue": "506070", "magenta": "dc8cc3", "cyan": "8cd0d3", "white": "dcdccc",
            "brightBlack": "709080", "brightRed": "dca3a3", "brightGreen": "c3bf9f",
            "brightYellow": "e0cf9f", "brightBlue": "94bff3", "brightMagenta": "ec93d3",
            "brightCyan": "93e0e3", "brightWhite": "ffffff",
        ]),
        entry("Apprentice", dark: true, bg: "262626", fg: "bcbcbc", cursor: "bcbcbc", colors: [
            "black": "1c1c1c", "red": "af5f5f", "green": "5f875f", "yellow": "87875f",
            "blue": "5f87af", "magenta": "5f5f87", "cyan": "5f8787", "white": "6c6c6c",
            "brightBlack": "444444", "brightRed": "ff8700", "brightGreen": "87af87",
            "brightYellow": "ffffaf", "brightBlue": "87afd7", "brightMagenta": "8787af",
            "brightCyan": "5fafaf", "brightWhite": "bcbcbc",
        ]),
        entry("Melange Dark", dark: true, bg: "1f1f1f", fg: "ece1d7", cursor: "ece1d7", colors: [
            "black": "34302c", "red": "bd8183", "green": "78997a", "yellow": "e49b5d",
            "blue": "7f91b2", "magenta": "b380b0", "cyan": "7b9695", "white": "c1a78e",
            "brightBlack": "867462", "brightRed": "d47766", "brightGreen": "85b695",
            "brightYellow": "ebc06d", "brightBlue": "a3a9ce", "brightMagenta": "cf9bc2",
            "brightCyan": "89b3b6", "brightWhite": "ece1d7",
        ]),
        entry("Selenized Dark", dark: true, bg: "103c48", fg: "adbcbc", cursor: "adbcbc", colors: [
            "black": "184956", "red": "fa5750", "green": "75b938", "yellow": "dbb32d",
            "blue": "4695f7", "magenta": "f275be", "cyan": "41c7b9", "white": "cad8d9",
            "brightBlack": "2d5b69", "brightRed": "ff665c", "brightGreen": "84c747",
            "brightYellow": "ebc13d", "brightBlue": "58a3ff", "brightMagenta": "ff84cd",
            "brightCyan": "53d6c7", "brightWhite": "d5dcdc",
        ]),
        entry("Selenized Light", dark: false, bg: "fbf3db", fg: "53676d", cursor: "53676d", colors: [
            "black": "ece3cc", "red": "d2212d", "green": "489100", "yellow": "ad8900",
            "blue": "0072d4", "magenta": "ca4898", "cyan": "009c8f", "white": "909995",
            "brightBlack": "d5cdb6", "brightRed": "cc1729", "brightGreen": "428b00",
            "brightYellow": "a78300", "brightBlue": "006dce", "brightMagenta": "c44392",
            "brightCyan": "00978a", "brightWhite": "3a4d53",
        ]),
        entry("PaperColor Light", dark: false, bg: "eeeeee", fg: "444444", cursor: "444444", colors: [
            "black": "eeeeee", "red": "af0000", "green": "008700", "yellow": "5f8700",
            "blue": "0087af", "magenta": "878787", "cyan": "005f87", "white": "444444",
            "brightBlack": "bcbcbc", "brightRed": "d70000", "brightGreen": "d70087",
            "brightYellow": "8700af", "brightBlue": "d75f00", "brightMagenta": "d75f00",
            "brightCyan": "005faf", "brightWhite": "005f87",
        ]),
        entry("PaperColor Dark", dark: true, bg: "1c1c1c", fg: "d0d0d0", cursor: "d0d0d0", colors: [
            "black": "1c1c1c", "red": "af005f", "green": "5faf00", "yellow": "d7af5f",
            "blue": "5fafd7", "magenta": "808080", "cyan": "d7875f", "white": "d0d0d0",
            "brightBlack": "585858", "brightRed": "5faf5f", "brightGreen": "afd700",
            "brightYellow": "af87d7", "brightBlue": "ffaf00", "brightMagenta": "ff5faf",
            "brightCyan": "00afaf", "brightWhite": "5f8787",
        ]),
        entry("Cobalt2", dark: true, bg: "193549", fg: "ffffff", cursor: "ffc600", colors: [
            "black": "000000", "red": "ff628c", "green": "3ad900", "yellow": "ffc600",
            "blue": "0088ff", "magenta": "fb94ff", "cyan": "80fcff", "white": "ffffff",
            "brightBlack": "0050a4", "brightRed": "ff628c", "brightGreen": "3ad900",
            "brightYellow": "ffc600", "brightBlue": "0088ff", "brightMagenta": "fb94ff",
            "brightCyan": "80fcff", "brightWhite": "ffffff",
        ]),
        entry("Monokai Vivid", dark: true, bg: "121212", fg: "f9f9f9", cursor: "fb0007", colors: [
            "black": "121212", "red": "fa2934", "green": "98e123", "yellow": "fff30a",
            "blue": "0443ff", "magenta": "f800f8", "cyan": "01b6ed", "white": "ffffff",
            "brightBlack": "838383", "brightRed": "f6669d", "brightGreen": "b1e05f",
            "brightYellow": "fff26d", "brightBlue": "0443ff", "brightMagenta": "f200f6",
            "brightCyan": "51ceff", "brightWhite": "ffffff",
        ]),
        entry("Argonaut", dark: true, bg: "0e1013", fg: "fffbff", cursor: "ff0018", colors: [
            "black": "232323", "red": "ff000f", "green": "8ce10b", "yellow": "ffb900",
            "blue": "008df8", "magenta": "6d43a6", "cyan": "00d8eb", "white": "ffffff",
            "brightBlack": "444444", "brightRed": "ff2740", "brightGreen": "abe15b",
            "brightYellow": "ffd242", "brightBlue": "0092ff", "brightMagenta": "9a5feb",
            "brightCyan": "67fff0", "brightWhite": "ffffff",
        ]),
        entry("Bluloco Dark", dark: true, bg: "282c34", fg: "abb2bf", cursor: "ffcc00", colors: [
            "black": "282c34", "red": "ff6480", "green": "3fc56b", "yellow": "f9c859",
            "blue": "10b1fe", "magenta": "ff78f8", "cyan": "5fb9bc", "white": "ffffff",
            "brightBlack": "828997", "brightRed": "ff6480", "brightGreen": "3fc56b",
            "brightYellow": "ffd16f", "brightBlue": "3fbbff", "brightMagenta": "ff78f8",
            "brightCyan": "5fb9bc", "brightWhite": "ffffff",
        ]),
    ]

    /// One entry's document, built the way `ThemeImport` writes one, so a
    /// gallery entry and a copied theme are the same bytes to the parser.
    private static func entry(
        _ name: String, dark: Bool, bg: String, fg: String, cursor: String,
        colors: [String: String]
    ) -> Entry {
        var colors: [String: Any] = colors
        colors["background"] = "#" + bg
        colors["foreground"] = "#" + fg
        colors["cursor"] = "#" + cursor
        let document: [String: Any] = ["v": 1, "name": name, "mode": dark ? "dark" : "light", "colors": colors]
        // Serialised once here so the entry holds the document the parser will
        // read, not a structure that has to be re-encoded at import time — which
        // is where the two could quietly differ.
        let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return Entry(
            slug: slug(name),
            name: name,
            dark: dark,
            json: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }

    /// The id a gallery entry imports under, and the thing a re-fetch names.
    ///
    /// The same rule `ThemeImport` derives from a theme's own `name`, spelled
    /// once here as well because the two have to agree: if the gallery's slug
    /// differed from what the parser computes, importing an entry and then
    /// re-fetching it by slug would add a second copy rather than update the
    /// first, and the list would grow a duplicate every time.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    /// The catalogue entry for a slug, or nil.
    static func entry(slug: String) -> Entry? {
        entries.first { $0.slug == slug }
    }

    /// Entries matching a search string.
    ///
    /// Empty query returns everything, because the gallery's first screen is
    /// the whole catalogue. Matching is on the name and the slug, case- and
    /// separator-insensitively, so "solarizeddark" finds "Solarized Dark" —
    /// a user typing a slug they saw elsewhere should land on the theme.
    static func search(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        let squashed = needle.replacingOccurrences(of: " ", with: "")
        return entries.filter { entry in
            let name = entry.name.lowercased()
            return name.contains(needle)
                || entry.slug.contains(needle)
                || name.replacingOccurrences(of: " ", with: "").contains(squashed)
        }
    }
}
