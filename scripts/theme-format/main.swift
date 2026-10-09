import Foundation

// Exercises ThemeImport against Moshi's documented format, plus the rejections
// its rules imply. The format is what a user pastes in, so a case this gets
// wrong is a theme that silently imports as something else.
//
// Run with scripts/theme-format/run.sh.

var failures = 0

func pass(_ note: String) {
    print("PASS  \(note)")
}

func fail(_ note: String) {
    failures += 1
    print("FAIL  \(note)")
}

func expect(_ condition: Bool, _ note: String) {
    condition ? pass(note) : fail(note)
}

func parse(_ text: String) -> Result<TerminalTheme, ThemeImport.Failure> {
    ThemeImport.parse(text)
}

func expectFailure(_ text: String, _ kind: ThemeImport.Failure, _ note: String) {
    switch parse(text) {
    case .success(let theme):
        fail("\(note) — parsed as “\(theme.name)” instead")
    case .failure(let got):
        got == kind ? pass(note) : fail("\(note) — got \(got) instead of \(kind)")
    }
}

print("— the documented v1 example —")
let documented = """
{
  "v": 1,
  "name": "My Theme",
  "mode": "dark",
  "colors": {
    "background": "#1a1b26",
    "foreground": "#c0caf5",
    "cursor": "#c0caf5",
    "black": "#15161e",
    "red": "#f7768e",
    "green": "#9ece6a",
    "yellow": "#e0af68",
    "blue": "#7aa2f7",
    "magenta": "#bb9af7",
    "cyan": "#7dcfff",
    "white": "#a9b1d6",
    "brightBlack": "#414868",
    "brightRed": "#f7768e",
    "brightGreen": "#9ece6a",
    "brightYellow": "#e0af68",
    "brightBlue": "#7aa2f7",
    "brightMagenta": "#bb9af7",
    "brightCyan": "#7dcfff",
    "brightWhite": "#c0caf5",
    "selectionBackground": "#33467c"
  }
}
"""
switch parse(documented) {
case .success(let theme):
    expect(theme.name == "My Theme", "the name is read")
    expect(theme.dark, "mode dark is read")
    expect(theme.background == "1a1b26", "background loses its # and lowercases")
    expect(theme.foreground == "c0caf5", "foreground is read")
    expect(theme.cursor == "c0caf5", "cursor is read")
    expect(theme.selection == "33467c", "selectionBackground is read")
    expect(theme.ansi.count == 16, "there are 16 ANSI colours")
    expect(theme.ansi[0] == "15161e", "black is the first")
    expect(theme.ansi[8] == "414868", "brightBlack is the ninth")
    expect(theme.ansi[15] == "c0caf5", "brightWhite is the sixteenth")
    // The accent is not a field in the format, so it comes from the theme's
    // own green — which is what an imported theme has instead of our default.
    expect(theme.accent == "9ece6a", "accent comes from the palette's green")
    expect(theme.id == "imported-my-theme", "the id is a slug of the name")
    expect(theme.isImported, "it is marked imported")
case .failure(let error):
    fail("the documented example did not parse: \(error)")
}

print("\n— the fallbacks the format promises —")
let minimal = """
{"v":1,"name":"Sparse","mode":"light","colors":{"background":"#fff","foreground":"#000"}}
"""
switch parse(minimal) {
case .success(let theme):
    // Three-digit hex is documented, and the two required colours are enough.
    expect(theme.background == "ffffff", "#fff expands to ffffff")
    expect(theme.ansi.count == 16, "a theme with no palette still has 16 colours")
    expect(theme.ansi[1] == "000000", "a missing base colour falls back to the foreground")
    expect(theme.ansi[9] == "000000", "a missing bright colour falls back to its base")
    expect(theme.cursor == "000000", "a missing cursor falls back to the foreground")
    expect(theme.selection == nil, "a missing selection stays absent, to be derived")
    expect(!theme.dark, "mode light is read")
case .failure(let error):
    fail("the minimal theme did not parse: \(error)")
}

print("\n— a partial palette keeps the stated colours —")
let partial = """
{"v":1,"name":"Partial","mode":"dark","colors":{
  "background":"#000","foreground":"#fff","red":"#ff0000","brightRed":"#ff9999",
  "green":"#0f0"}}
"""
switch parse(partial) {
case .success(let theme):
    expect(theme.ansi[1] == "ff0000", "the stated red is kept")
    expect(theme.ansi[9] == "ff9999", "the stated brightRed is kept, not derived")
    expect(theme.ansi[0] == "ffffff", "the unstated black still falls back")
    expect(theme.ansi[15] == "ffffff", "and so does an unstated brightWhite")
case .failure(let error):
    fail("a partial palette did not parse: \(error)")
}

print("\n— rejections —")
expectFailure("hello, not a theme", .notJSON, "plain text is refused")
expectFailure("", .notJSON, "an empty string is refused")
expectFailure("{}", .unsupportedVersion(nil), "no version is refused as a version problem")
expectFailure(##"{"v":2,"name":"x","mode":"dark","colors":{}}"##, .unsupportedVersion(2),
              "a future version is refused by number")
expectFailure(##"{"v":1,"name":"","mode":"dark","colors":{}}"##, .missing("name"),
              "an empty name is refused")
expectFailure(##"{"v":1,"name":"x","colors":{"background":"#000","foreground":"#fff"}}"##,
              .missing("mode"), "a missing mode is refused rather than guessed")
expectFailure(##"{"v":1,"name":"x","mode":"auto","colors":{}}"##, .missing("mode"),
              "an unrecognised mode is refused")
expectFailure(##"{"v":1,"name":"x","mode":"dark","colors":{"foreground":"#fff"}}"##,
              .missing("background"), "a missing background is refused")
expectFailure(##"{"v":1,"name":"x","mode":"dark","colors":{"background":"#0","foreground":"#fff"}}"##,
              .missing("background"), "a one-digit colour is refused")
expectFailure(##"{"v":1,"name":"x","mode":"dark","colors":{"background":"#000","foreground":"#fff","red":"chartreuse"}}"##,
              .badColor("chartreuse"), "a named colour is refused with its own name")

print("\n— the moshi-theme: string —")
// Round trip: what we write must parse back to what we wrote, because the
// whole point of the string is that it can leave the app and return.
let source = TerminalTheme.builtIn[1]
let encoded = ThemeImport.string(for: source)
expect(encoded.hasPrefix("moshi-theme:"), "the string carries Moshi's prefix")
switch parse(encoded) {
case .success(let theme):
    expect(theme.background == source.background, "a round trip keeps the background")
    expect(theme.ansi == source.ansi, "a round trip keeps the whole palette")
    expect(theme.dark == source.dark, "a round trip keeps the mode")
    // The name, not the id: the id is derived from the name on the way back in,
    // which is what makes re-importing replace rather than duplicate.
    expect(theme.name == source.name, "a round trip keeps the name")
    expect(theme.id == "imported-" + source.id, "the imported id is the slug of the name")
case .failure(let error):
    fail("a string we wrote did not parse back: \(error)")
}

// A bare payload with no prefix, which is what a QR code holding only the
// base64 would carry.
let bare = String(encoded.dropFirst(ThemeImport.prefix.count))
switch parse(bare) {
case .success: pass("a bare base64 payload parses without the prefix")
case .failure(let error): fail("the bare payload did not parse: \(error)")
}

// Surrounding whitespace is what a copy from a chat client looks like.
switch parse("\n  \(encoded)  \n") {
case .success: pass("surrounding whitespace is ignored")
case .failure(let error): fail("a padded string did not parse: \(error)")
}

print("\n— every built-in round trips —")
for theme in TerminalTheme.builtIn {
    switch parse(ThemeImport.string(for: theme)) {
    case .success(let back):
        expect(back.background == theme.background && back.ansi == theme.ansi
               && back.name == theme.name,
               "\(theme.name) survives a round trip")
    case .failure(let error):
        fail("\(theme.name) did not survive a round trip: \(error)")
    }
}

print("\n— the built-in list itself —")
expect(TerminalTheme.builtIn.count == 9, "there are nine built-ins")
expect(TerminalTheme.builtIn.filter(\.dark).count == 6, "six dark")
expect(TerminalTheme.builtIn.filter { !$0.dark }.count == 3, "three light")
expect(TerminalTheme.named(nil).id == "moshi", "the default is Moshi")
expect(TerminalTheme.builtIn.allSatisfy { $0.ansi.count == 16 },
       "every built-in has 16 ANSI colours")
expect(TerminalTheme.builtIn.allSatisfy { theme in
    // A palette entry that is not 6 hex digits would render as black without
    // saying so, in the terminal and in the picker's swatches alike.
    (theme.ansi + [theme.background, theme.foreground, theme.cursor, theme.accent])
        .allSatisfy { $0.count == 6 && $0.allSatisfy(\.isHexDigit) }
}, "every built-in colour is a plain 6-digit hex")
expect(TerminalTheme.builtIn.allSatisfy { theme in
    // Every built-in leaves accent at the default because a theme's own green
    // is not necessarily legible as a UI accent on its background.
    theme.accent == TerminalTheme.defaultAccent
}, "every built-in uses the app accent")

print(failures == 0 ? "\nTHEME_FORMAT_PASS" : "\nTHEME_FORMAT_FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)