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