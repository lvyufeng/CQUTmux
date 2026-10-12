import Foundation

// The rules the Input settings screen is a shell around.
//
// Every one of these is a pure function, which is the point: the failure modes
// are all invisible in the app. A Meta translation that mangles ordinary typing
// looks like the keyboard being broken; a bar that hides itself because a
// notification arrived with the wrong height looks like a layout bug; a corner
// that resets to Nothing after a relaunch looks like the user mis-tapping. None
// of them raise anything a person could read.
//
// `InputSettings` imports SwiftUI (for `@Observable`), so this compiles against
// the same source the app does, without a simulator.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

func bytes(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func equal(_ data: Data, _ expected: [UInt8], _ label: String) {
    checks += 1
    if Array(data) == expected {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label): got \(bytes(data)), wanted \(bytes(Data(expected)))")
    }
}

// MARK: - Option as Meta

// The heart of it. Option+e on an iOS keyboard has already produced "é" by the
// time the bytes reach the terminal, so the ESC prefix has to be derived back
// out of the composed character rather than added to the keystroke.
equal(InputSettings.optionMeta(Data("é".utf8), enabled: true), [0x1B, 0x65],
      "Option+e, as the keyboard composes it, becomes ESC e")

equal(InputSettings.optionMeta(Data("ü".utf8), enabled: true), [0x1B, 0x75],
      "Option+u becomes ESC u (a different vowel, a different letter)")

// Two Meta presses in one send. A per-character rewrite, not a per-string one.
equal(InputSettings.optionMeta(Data("éü".utf8), enabled: true), [0x1B, 0x65, 0x1B, 0x75],
      "two composed characters become two ESC sequences")

// Off is the default and must be a true no-op, byte for byte.
let plain = Data("é".utf8)
equal(InputSettings.optionMeta(plain, enabled: false), [0xC3, 0xA9],
      "with the setting off the composed character passes through untouched")

// MARK: - What must NOT be rewritten

// The single most important case. Ordinary typing goes through the same funnel
// as Option presses, so a rule that rewrote everything would turn every "e"
// into an ESC e and make the terminal unusable with the setting on.
equal(InputSettings.optionMeta(Data("e".utf8), enabled: true), [0x65],
      "a plain ASCII letter is left alone, so ordinary typing still works")

equal(InputSettings.optionMeta(Data("hello world".utf8), enabled: true),
      Array("hello world".utf8),
      "an ordinary line is left alone")

// A control byte is not a composed character either; ESC, Ctrl-C and friends
// already mean exactly what they say.
equal(InputSettings.optionMeta(Data([0x03]), enabled: true), [0x03],
      "a control byte is left alone")

// Mixed ASCII and accents is not something an Option press produces — it is a
// paste. Guessing which half to rewrite would corrupt it.
equal(InputSettings.optionMeta(Data("éx".utf8), enabled: true), Array("éx".utf8),
      "a mixed ASCII/accent string is treated as a paste, not a keystroke")

// Decomposable-looking characters that do not actually decompose must not be
// guessed at: "ø" is its own letter, not "o" with a stroke.
equal(InputSettings.optionMeta(Data("ø".utf8), enabled: true), Array("ø".utf8),
      "a letter with no canonical decomposition is left alone")

// A symbol is not a modified letter.
equal(InputSettings.optionMeta(Data("€".utf8), enabled: true), Array("€".utf8),
      "a currency symbol is left alone")

equal(InputSettings.optionMeta(Data(), enabled: true), [],
      "empty input stays empty")

// Bytes that are not valid UTF-8 arrive from paste and from bracketed-paste
// sequences; they must pass through rather than be dropped.
equal(InputSettings.optionMeta(Data([0xFF, 0xFE]), enabled: true), [0xFF, 0xFE],
      "invalid UTF-8 passes through rather than vanishing")

// CJK input has no ASCII base — an IME composition must not be shredded into
// escape sequences.
equal(InputSettings.optionMeta(Data("中文".utf8), enabled: true), Array("中文".utf8),
      "multi-byte CJK input passes through")

// MARK: - Hiding the bar

// The heuristic is the keyboard's own height: with a hardware keyboard the
// software keyboard does not appear and only the shortcut bar is left.
check(InputSettings.isHardwareKeyboard(frameHeight: 0),
      "no keyboard at all reads as a hardware keyboard")
check(InputSettings.isHardwareKeyboard(frameHeight: 55),
      "the shortcut bar alone reads as a hardware keyboard")
check(InputSettings.isHardwareKeyboard(frameHeight: InputSettings.hardwareKeyboardHeightThreshold),
      "exactly at the threshold counts as hardware (<=, not <)")
check(!InputSettings.isHardwareKeyboard(frameHeight: 291),
      "a full software keyboard does not read as hardware")
check(!InputSettings.isHardwareKeyboard(frameHeight: 336),
      "a large software keyboard does not read as hardware")

check(InputSettings.showsBar(hideWithHardwareKeyboard: true, hardwareKeyboard: true) == false,
      "the bar hides when both the setting and a hardware keyboard are present")
check(InputSettings.showsBar(hideWithHardwareKeyboard: true, hardwareKeyboard: false),
      "the setting alone does not hide the bar")
check(InputSettings.showsBar(hideWithHardwareKeyboard: false, hardwareKeyboard: true),
      "a hardware keyboard alone does not hide the bar")
check(InputSettings.showsBar(hideWithHardwareKeyboard: false, hardwareKeyboard: false),
      "the bar shows by default")

// MARK: - The bar's items

// The order is Moshi's, and it is what a fresh install and "restore" both fall
// back to, so a reordering of this list is a product decision, not a refactor.
check(InputSettings.defaultItems.first == .control,
      "Ctrl leads the default bar")
check(InputSettings.defaultItems == [.control, .escape, .tab, .arrows, .clipboard,
                                     .pasteImage, .sessions, .dictation, .customKeys],
      "the default bar holds exactly Moshi's items, in Moshi's order")
check(Set(InputSettings.Item.allCases).count == InputSettings.Item.allCases.count,
      "no item is listed twice, which would make the ForEach show a duplicate id")

// A suite of this check's own, wiped first: a shared domain would make the
// results depend on what the last run stored — the check would corrupt the
// settings of whoever ran it, and a rerun would measure the corruption.
let suite = "cqutmux.input-check"
UserDefaults.standard.removePersistentDomain(forName: suite)
let defaults = UserDefaults(suiteName: suite)!

let settings = InputSettings(store: defaults)
let start = settings.items
check(!start.isEmpty, "the bar never loads empty — an empty bar looks like a bug")

settings.remove(.escape)
check(!settings.items.contains(.escape), "remove takes the item out of the bar")

settings.restore(.escape)
check(settings.items.contains(.escape), "restore puts a removed item back")
check(settings.items == start, "restore returns an item to its default position")

let beforeRestore = settings.items.count
settings.restore(.escape)
check(settings.items.count == beforeRestore, "restoring an item already in the bar is a no-op")

// Removing everything must not be resurrected as "unset" until the setting is
// read back from disk — inside one session, an emptied bar stays empty.
let emptied = InputSettings(store: defaults)
for item in emptied.items { emptied.remove(item) }
check(emptied.items.isEmpty, "a user can empty the bar if they want to")

settings.move(from: IndexSet(integer: 0), to: settings.items.count)
check(settings.items.last == start[0], "move sends the first item to the end")

// MARK: - The window row

// Off by default, and it must be off: the row only means anything to a tmux
// user, and a default that showed it to a zellij or herdr user would be a row
// of nine buttons that do nothing.
let fresh = InputSettings(store: UserDefaults(suiteName: "cqutmux.input-row-unused")!)
check(!fresh.hidesWindowRow, "the window row is shown by default")

let rowStore = UserDefaults(suiteName: "cqutmux.input.check.row")!
rowStore.removePersistentDomain(forName: "cqutmux.input.check.row")
let row = InputSettings(store: rowStore)
row.hidesWindowRow = true
check(InputSettings(store: rowStore).hidesWindowRow,
      "hiding the window row survives a relaunch")
row.hidesWindowRow = false
check(!InputSettings(store: rowStore).hidesWindowRow,
      "showing it again survives a relaunch too")

// MARK: - The mux-gesture switch

// Default on, and that default is load-bearing: every install that predates
// this setting has no stored value, and those are exactly the installs whose
// two-finger swipes did nothing. Reading them as "off" would ship the feature
// switched off for everyone who upgraded.
check(InputSettings(store: UserDefaults(suiteName: "cqutmux.input.check.mux-fresh")!)
        .muxGestures,
      "a fresh install has the multiplexer gestures on")
row.muxGestures = false
check(!InputSettings(store: rowStore).muxGestures,
      "turning them off survives a relaunch")
row.muxGestures = true

// MARK: - Corner bindings

check(InputSettings.defaultCorner(.topLeading) == .escape,
      "the top-left corner defaults to Esc")
check(InputSettings.defaultCorner(.topTrailing) == .delete,
      "the top-right corner defaults to Delete")
check(InputSettings.defaultCorner(.bottomLeading) == .none,
      "the bottom-left corner defaults to nothing")
check(InputSettings.defaultCorner(.bottomTrailing) == .none,
      "the bottom-right corner defaults to nothing")

// Every corner must be bindable to every action, including the ones the
// defaults leave empty — otherwise the picker would offer a choice that
// silently does not stick.
for slot in InputSettings.Corner.allCases {
    for action in InputSettings.CornerAction.allCases {
        let store = InputSettings(store: defaults)
        store.setCorner(slot, to: action)
        if store.corner(slot) != action {
            check(false, "\(slot.label) does not hold \(action.label)")
        }
    }
}
check(true, "every corner holds every action it is set to (16 bindings)")

// MARK: - Labels

// A blank label is a blank button in the bar, which reads as a broken item.
for item in InputSettings.Item.allCases {
    check(!item.label.isEmpty, "\(item.rawValue) has a label")
}
for action in InputSettings.CornerAction.allCases {
    check(!action.label.isEmpty, "corner action \(action.rawValue) has a label")
    check(!action.cornerLabel.isEmpty, "corner action \(action.rawValue) has a short label")
}
// The corner slots are ~30pt wide; a label longer than this is clipped.
for action in InputSettings.CornerAction.allCases {
    check(action.cornerLabel.count <= 3,
          "\(action.cornerLabel) fits a 30pt corner slot")
}

// MARK: - Settings survive a relaunch

// The store is UserDefaults, so the round trip is the real one: write through
// the object, construct a fresh one, read. A @Observable whose `didSet` writes
// to the wrong key fails here and nowhere else.
let writer = InputSettings(store: defaults)
writer.optionIsMeta = true
check(InputSettings(store: defaults).optionIsMeta, "Option-as-Meta survives a relaunch")

writer.optionIsMeta = false
check(!InputSettings(store: defaults).optionIsMeta,
      "turning Option-as-Meta off survives a relaunch")

writer.hideBarWithHardwareKeyboard = false
check(!InputSettings(store: defaults).hideBarWithHardwareKeyboard,
      "turning the auto-hide off survives a relaunch")

writer.hideBarWithHardwareKeyboard = true
writer.setCorner(.bottomTrailing, to: .interrupt)
check(InputSettings(store: defaults).corner(.bottomTrailing) == .interrupt,
      "a corner binding survives a relaunch")

// MARK: - Custom corners

// The custom action turns typed text into bytes. A corner set to `.custom`
// with nothing typed is blank, which is what keeps the button disabled rather
// than sending nothing at all.
writer.setCorner(.bottomLeading, to: .custom)
check(writer.cornerBytes(.bottomLeading) == nil,
      "a custom corner with no shortcut sends nothing")

writer.setCornerShortcut("C-c", for: .bottomLeading)
check(writer.cornerBytes(.bottomLeading) == [0x03],
      "a custom corner parses its shortcut to the same bytes the grammar gives")

// The whole point of choosing the custom action is that it survives a restart;
// storing it apart from the action means one file write has to carry both.
let reopened = InputSettings(store: defaults)
check(reopened.corner(.bottomLeading) == .custom
      && reopened.cornerBytes(.bottomLeading) == [0x03],
      "a custom corner and its shortcut both survive a relaunch")

// Clearing the text leaves the action in place rather than silently reverting
// to whatever the corner used to be.
writer.setCornerShortcut(nil, for: .bottomLeading)
check(InputSettings(store: defaults).corner(.bottomLeading) == .custom
      && InputSettings(store: defaults).cornerBytes(.bottomLeading) == nil,
      "clearing a custom shortcut keeps the action and blanks the key")

// An unparsable shortcut is treated as unset, not as half of something. It has
// to fall back the same way every other binding does.
writer.setCornerShortcut("C-", for: .bottomLeading)
check(writer.cornerBytes(.bottomLeading) == nil,
      "an unparsable custom shortcut does not send a partial sequence")

writer.setCorner(.bottomLeading, to: InputSettings.defaultCorner(.bottomLeading))
writer.setCornerShortcut(nil, for: .bottomLeading)

// MARK: - Items the bar can add

// Enter, Backspace and the keyboard toggle are off by default, and every one
// of them is unreachable unless the settings screen can offer it — an item in
// `Item.allCases` but missing from `allItems` is a switch nobody can turn on.
check(InputSettings.allItems.contains(.enter), "Enter can be added to the bar")
check(InputSettings.allItems.contains(.backspace), "Backspace can be added to the bar")
check(InputSettings.allItems.contains(.keyboard), "the keyboard toggle can be added")
check(InputSettings.allItems.contains(.showKeyboard), "the show-keyboard key can be added")
check(!InputSettings.defaultItems.contains(.showKeyboard),
      "show-keyboard is off by default, as Moshi ships it")
// The bar sits above the keyboard, so hiding the keyboard hides the bar. The
// hide key without the show key is the trap this pair exists to close: once
// the keyboard is away there is nothing left on screen to ask for it back, and
// the only way out is to leave the session. So they ship together, both off by
// default, and adding one offers the other on the same screen.
check(!InputSettings.defaultItems.contains(.keyboard),
      "the hide key is off by default too, so the two move together")
check(!InputSettings.defaultItems.contains(.enter),
      "Enter is off by default, as Moshi ships it")

// Every item a user can end up with is restorable: the settings screen adds
// from `allItems` and removes from `items`, so a case missing from either list
// is a key that can be lost for good.
let allCases = Set(InputSettings.Item.allCases)
check(Set(InputSettings.allItems) == allCases,
      "every bar item appears in allItems exactly once")
check(InputSettings.allItems.count == allCases.count,
      "allItems lists no item twice")

// MARK: - The Alt key and the new rows are opt-in, not default

// Alt, the navigation row and the symbol row are all real items a user can add,
// and none of them is on the default bar. Moshi's published keyboard page
// (getmoshi.app/docs/keyboard, read 2026-10-12) enumerates the toolbar as
// Enter/Backspace, Paste, Keyboard show/hide, Shortcut panel, history and the
// D-pad — no Alt key, no navigation row, no symbol row. So the default list
// above must stay exactly that documented set, and these three can only be
// opted in. A check here is what keeps a later "let's add Alt by default" from
// quietly making the default list a claim it cannot support.
check(InputSettings.allItems.contains(.alt), "Alt can be added to the bar")
check(InputSettings.allItems.contains(.navigation), "the navigation row can be added")
check(InputSettings.allItems.contains(.symbols), "the symbol row can be added")
check(!InputSettings.defaultItems.contains(.alt),
      "Alt is off by default — Moshi documents no Alt key on the bar")
check(!InputSettings.defaultItems.contains(.navigation),
      "the navigation row is off by default")
check(!InputSettings.defaultItems.contains(.symbols),
      "the symbol row is off by default")

// MARK: - The navigation row

// The bytes are not invented here: they are the grammar's own named keys, so a
// button and a custom shortcut spelling `home` are the same binding. Read back
// through the grammar rather than restated, which is what makes this a check
// that the two cannot drift.
equal(Data(InputSettings.NavKey.home.bytes ?? []), [0x1B, 0x5B, 0x48],
      "Home sends CSI H, the grammar's own home token")
equal(Data(InputSettings.NavKey.end.bytes ?? []), [0x1B, 0x5B, 0x46],
      "End sends CSI F")
equal(Data(InputSettings.NavKey.pageUp.bytes ?? []), [0x1B, 0x5B, 0x35, 0x7E],
      "PageUp sends CSI 5 ~")
equal(Data(InputSettings.NavKey.pageDown.bytes ?? []), [0x1B, 0x5B, 0x36, 0x7E],
      "PageDown sends CSI 6 ~")

// The button's bytes and the grammar's token must be byte-identical, or the two
// ways to send Home would disagree — the exact drift the grammar table exists
// to prevent.
for key in InputSettings.NavKey.allCases {
    let fromGrammar = (try? ShortcutGrammar.parse(key.grammarToken))?.bytes ?? []
    check(key.bytes == fromGrammar,
          "\(key.label)'s button sends what the grammar's \(key.grammarToken) token sends")
}

// A blank label is a blank button on the bar.
for key in InputSettings.NavKey.allCases {
    check(!key.label.isEmpty, "navigation key \(key.rawValue) has a label")
}

// MARK: - The symbol row

// One ASCII byte each, no modifier and no escape: these are typed as text, so a
// stray ESC prefix would turn `~` into Meta-~ on the wire.
equal(Data([InputSettings.SymbolKey.pipe.byte]), [0x7C], "the pipe key sends |")
equal(Data([InputSettings.SymbolKey.tilde.byte]), [0x7E], "the tilde key sends ~")
equal(Data([InputSettings.SymbolKey.dash.byte]), [0x2D], "the dash key sends -")
equal(Data([InputSettings.SymbolKey.underscore.byte]), [0x5F], "the underscore key sends _")
equal(Data([InputSettings.SymbolKey.backslash.byte]), [0x5C], "the backslash key sends \\")
equal(Data([InputSettings.SymbolKey.slash.byte]), [0x2F], "the slash key sends /")
equal(Data([InputSettings.SymbolKey.singleQuote.byte]), [0x27], "the quote key sends '")
equal(Data([InputSettings.SymbolKey.doubleQuote.byte]), [0x22], "the double-quote key sends \"")

// Every symbol is printable ASCII and nothing else. A symbol that composed to a
// multi-byte character would need the Option-as-Meta translator to stay out of
// its way, which is a dependency this row deliberately does not have.
for key in InputSettings.SymbolKey.allCases {
    check((0x20...0x7E).contains(key.byte),
          "symbol \(key.rawValue) is a single printable ASCII byte")
    check(!key.label.isEmpty, "symbol \(key.rawValue) has a label")
}

// The symbol row must not overlap the grammar's own named keys: a `dash` or
// `plus` token exists because the bare characters are separators, and the row
// sending a bare `-` is the literal character, which is what the grammar's
// `dash` produces too — the same byte, arrived at two ways.
check(InputSettings.SymbolKey.dash.byte == (try? ShortcutGrammar.parse("dash").bytes.first),
      "the dash key sends the same byte the grammar's dash token does")

// Put the store back, so running this check twice does not change what a
// second run measures.
writer.setCorner(.bottomTrailing, to: InputSettings.defaultCorner(.bottomTrailing))
writer.optionIsMeta = false
writer.hideBarWithHardwareKeyboard = true

if failures > 0 {
    print("\nINPUT_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nINPUT_PASS  (\(checks) checks)")