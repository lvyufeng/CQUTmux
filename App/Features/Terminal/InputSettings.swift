import Foundation
import SwiftUI

/// Settings → Input: how the on-screen keyboard and its bar behave.
///
/// The bar's own item order is here too, because "reorder" and "hide" are the
/// same problem — what the bar shows — and splitting them across two stores
/// would let one change leave the other stale.
@Observable
final class InputSettings {
    private enum Key {
        static let optionIsMeta = "input.optionIsMeta"
        static let hideBarWithHardwareKeyboard = "input.hideBarWithHardwareKeyboard"
        static let barItems = "input.barItems"
        static let corners = "input.dpadCorners"
        static let cornerShortcuts = "input.dpadCornerShortcuts"
        static let hidesWindowRow = "input.hidesWindowRow"
        static let muxGestures = "input.muxGestures"
        static let chatMode = "input.chatMode"
    }

    /// The D-pad corner actions, as raw strings keyed by corner.
    private var corners: [String: String] = [:]

    /// The shortcut text for any corner set to `.custom`, keyed by corner.
    /// Stored separately from `corners` so switching a corner to something else
    /// and back does not lose what was typed — and so the raw text survives a
    /// grammar change to be shown and explained rather than dropped, exactly as
    /// `ShortcutStore` and `GestureStore` keep theirs.
    private var cornerShortcuts: [String: String] = [:]

    /// Where the settings live. Injectable so a check can use its own suite:
    /// a check that writes to `standard` both depends on whatever a previous
    /// run left behind and silently changes the settings of anyone running it.
    private let store: UserDefaults

    /// What the accessory bar can show, in the user's order.
    enum Item: String, CaseIterable, Codable, Identifiable {
        case control, escape, tab
        case enter, backspace, keyboard
        case arrows
        case dpad
        case clipboard, pasteImage
        case sessions
        case history
        case dictation
        case customKeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .control: "Ctrl"
            case .escape: "Esc"
            case .tab: "Tab"
            case .enter: "Enter"
            case .backspace: "Backspace"
            case .keyboard: "Keyboard"
            case .arrows: "Arrows"
            case .dpad: "D-pad"
            case .clipboard: "Paste"
            case .pasteImage: "Image"
            case .sessions: "Sessions"
            case .history: "History"
            case .dictation: "Dictation"
            case .customKeys: "Custom keys"
            }
        }
    }

    /// Moshi's defaults, in Moshi's order.
    static let defaultItems: [Item] = [
        .control, .escape, .tab, .arrows, .clipboard, .pasteImage, .sessions, .dictation, .customKeys,
    ]

    /// Items that exist but are not on a fresh bar.
    ///
    /// Kept separate from `defaultItems` so the default list stays exactly
    /// Moshi's: the toolbar has one documented default, and adding a key to it
    /// on a guess would make "Moshi's order" a claim this list no longer
    /// supports. History is reachable from the bar's own settings and the
    /// More menu, which is enough for a key not everyone needs.
    static let optInItems: [Item] = [.history]

    /// Every item the bar can show, whether or not it is on by default.
    ///
    /// Kept in one place so the settings screen and `defaultItems` cannot drift:
    /// an item that exists but is missing from `defaultItems` is off for a new
    /// install and on for nobody, which is a switch nobody can turn on.
    static var allItems: [Item] {
        var seen: [Item] = defaultItems + optInItems
        for item in Item.allCases where !seen.contains(item) { seen.append(item) }
        return seen
    }

    /// Whether the accessory bar should be on screen.
    ///
    /// iOS does not offer a clean "is a hardware keyboard attached" answer, so
    /// this reads the keyboard's own reported height. With a hardware keyboard
    /// the software keyboard does not appear and what is left is the shortcut
    /// bar alone — the short frame. That is a heuristic, and it is the honest
    /// one: it answers the question the setting is really asking, which is
    /// whether the on-screen keys are duplicating a keyboard already in front
    /// of the user.
    ///
    /// `hardwareKeyboard` starts false, so a session that has seen no keyboard
    /// notification yet shows the bar. Defaulting to hidden would make the bar
    /// disappear for someone who has never attached a keyboard.
    static func showsBar(hideWithHardwareKeyboard: Bool, hardwareKeyboard: Bool) -> Bool {
        !(hideWithHardwareKeyboard && hardwareKeyboard)
    }

    /// A keyboard frame no taller than this is the shortcut bar alone.
    static let hardwareKeyboardHeightThreshold: CGFloat = 100

    static func isHardwareKeyboard(frameHeight: CGFloat) -> Bool {
        frameHeight <= hardwareKeyboardHeightThreshold
    }

    /// A corner of the D-pad, and what pressing it does.
    enum Corner: String, CaseIterable, Codable, Identifiable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .topLeading: "Top left"
            case .topTrailing: "Top right"
            case .bottomLeading: "Bottom left"
            case .bottomTrailing: "Bottom right"
            }
        }
    }

    /// What a corner sends. `none` leaves a blank slot, which is the default
    /// for the bottom two: a four-way pad where every corner does something
    /// surprising is worse than one where the extra slots are visibly empty.
    enum CornerAction: String, CaseIterable, Codable, Identifiable {
        case none, escape, delete, interrupt, hideKeyboard, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "Nothing"
            case .escape: "Esc"
            case .delete: "Delete"
            case .interrupt: "Interrupt (Ctrl-C)"
            case .hideKeyboard: "Hide keyboard"
            case .custom: "Custom shortcut"
            }
        }

        /// What the 30pt button shows. Short, because the slot is small.
        var cornerLabel: String {
            switch self {
            case .none: "·"
            case .escape: "Esc"
            case .delete: "Del"
            case .interrupt: "^C"
            case .hideKeyboard: "⌄"
            case .custom: "⇥"
            }
        }
    }

    /// The action in one corner.
    func corner(_ slot: Corner) -> CornerAction {
        corners[slot.rawValue].flatMap(CornerAction.init(rawValue:)) ?? Self.defaultCorner(slot)
    }

    func setCorner(_ slot: Corner, to action: CornerAction) {
        corners[slot.rawValue] = action.rawValue
        store.set(corners, forKey: Key.corners)
    }

    /// The shortcut text typed for a corner, or nil if that corner is not a
    /// custom binding.
    func cornerShortcut(_ slot: Corner) -> String? { cornerShortcuts[slot.rawValue] }

    func setCornerShortcut(_ text: String?, for slot: Corner) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            cornerShortcuts.removeValue(forKey: slot.rawValue)
        } else {
            cornerShortcuts[slot.rawValue] = trimmed
        }
        store.set(cornerShortcuts, forKey: Key.cornerShortcuts)
    }

    /// The bytes a custom corner sends, or nil when it has not been filled in.
    ///
    /// A corner left on `.custom` with nothing typed is a blank slot, not an
    /// error: it behaves like `.none` until a shortcut is entered, which is what
    /// the picker implies the moment the option is chosen.
    func cornerBytes(_ slot: Corner) -> [UInt8]? {
        guard let text = cornerShortcuts[slot.rawValue] else { return nil }
        return (try? ShortcutGrammar.parse(text))?.bytes
    }

    /// Esc top-left and Delete top-right: the two a TUI needs most often, in
    /// the two slots a thumb reaches first.
    static func defaultCorner(_ slot: Corner) -> CornerAction {
        switch slot {
        case .topLeading: .escape
        case .topTrailing: .delete
        case .bottomLeading, .bottomTrailing: .none
        }
    }

    /// Send Option+key as an ESC prefix rather than as an accented character.
    ///
    /// Off by default. On, Option is Meta, which is what a terminal emulator on
    /// a desktop does and what readline and emacs expect for word motions; off,
    /// Option produces the accented letters the iOS keyboard was configured for.
    /// Neither is right for everyone, which is why it is a switch rather than a
    /// decision.
    var optionIsMeta: Bool {
        didSet { store.set(optionIsMeta, forKey: Key.optionIsMeta) }
    }

    /// Hide the accessory bar while a hardware keyboard is attached, on the
    /// theory that someone with a real keyboard does not need Ctrl and Esc as
    /// glass buttons.
    var hideBarWithHardwareKeyboard: Bool {
        didSet { store.set(hideBarWithHardwareKeyboard, forKey: Key.hideBarWithHardwareKeyboard) }
    }

    /// Whether the tmux window row is hidden. Off by default: nine small
    /// buttons cost one row of height and save a tap through the session
    /// picker every time, which is the trade Moshi ships.
    var hidesWindowRow: Bool {
        didSet { store.set(hidesWindowRow, forKey: Key.hidesWindowRow) }
    }

    /// Whether the two-finger swipes drive the host's multiplexer.
    ///
    /// On by default, because that is the gesture Moshi ships and the one a
    /// user arriving from it will reach for. Off, the two-finger pans are left
    /// entirely to the terminal: horizontal does nothing and vertical reaches
    /// the scrollback, which is what the gestures meant before this existed.
    ///
    /// It is a switch rather than an unconditional mapping because the
    /// multiplexer bindings are read from the *host's* configuration, and a
    /// host whose tmux has no `select-pane -t :.+` is a host where a two-finger
    /// sideways swipe would do nothing at all — a setting lets that be the
    /// user's answer rather than ours.
    var muxGestures: Bool {
        didSet { store.set(muxGestures, forKey: Key.muxGestures) }
    }

    /// Chat mode: the key bar becomes a native message field that composes a
    /// whole line and sends it in one piece, rather than a row of keys that
    /// types into the session.
    ///
    /// Off by default. It changes what the bar *is* — every key on it is
    /// replaced — so turning it on for someone who wanted the keys would be
    /// taking the keyboard away to offer a text field they did not ask for.
    /// The mode exists for the two cases the terminal cannot serve: an agent
    /// whose TUI mangles iOS keyboard composition as it repaints (CJK, most of
    /// all), and a prompt that should arrive as one message rather than as
    /// keystrokes.
    var chatMode: Bool {
        didSet { store.set(chatMode, forKey: Key.chatMode) }
    }

    /// The bar's items, in order. Stored as raw values so a build that adds an
    /// item does not lose a user's arrangement, and one that removes an item
    /// does not resurrect it.
    var items: [Item] {
        didSet { store.set(items.map(\.rawValue), forKey: Key.barItems) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        optionIsMeta = store.bool(forKey: Key.optionIsMeta)
        // Default on: a hardware keyboard already has every one of these keys,
        // so the bar is duplicating them at the cost of screen height.
        hideBarWithHardwareKeyboard =
            store.object(forKey: Key.hideBarWithHardwareKeyboard) as? Bool ?? true
        hidesWindowRow = store.bool(forKey: Key.hidesWindowRow)
        // Default on: the value is absent on every install that predates the
        // setting, and those installs are exactly the ones that had the
        // two-finger swipes do nothing — so "absent" has to mean the new
        // behaviour or the feature would ship switched off for everyone.
        muxGestures = store.object(forKey: Key.muxGestures) as? Bool ?? true
        chatMode = store.bool(forKey: Key.chatMode)

        let stored = store.stringArray(forKey: Key.barItems) ?? []
        let restored = stored.compactMap(Item.init(rawValue:))
        // An empty or wholly unrecognised list means unset, not "the user wants
        // no buttons": an empty bar is not a state anyone chose, and coming back
        // to a terminal with no keys on it would look like a bug.
        items = restored.isEmpty ? Self.defaultItems : restored
        corners = store.dictionary(forKey: Key.corners) as? [String: String] ?? [:]
        cornerShortcuts =
            store.dictionary(forKey: Key.cornerShortcuts) as? [String: String] ?? [:]
    }

    /// Adds an item the user removed, or does nothing if it is already there.
    func restore(_ item: Item) {
        guard !items.contains(item) else { return }
        let index = Self.defaultItems.firstIndex(of: item) ?? items.count
        items.insert(item, at: min(index, items.count))
    }

    func remove(_ item: Item) {
        items.removeAll { $0 == item }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Rewrites Option+key as ESC followed by the key, which is what a terminal
    /// means by Meta.
    ///
    /// The bytes arrive here already composed: by the time `send` is called the
    /// keyboard has already turned Option+e into "é", so the ESC prefix has to
    /// be *derived* from the composed character rather than added to the
    /// keystroke. That is what the round trip through NFD is for — "é" is
    /// "e" plus a combining accent, so dropping the accent yields the letter the
    /// user held Option to modify. A character with no such decomposition is
    /// left alone, because guessing would send something arbitrary.
    ///
    /// Pure and static so it can be checked without a simulator; the settings
    /// object supplies `enabled` and the view calls it on every send.
    static func optionMeta(_ data: Data, enabled: Bool) -> Data {
        guard enabled else { return data }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return data }

        var out = Data()
        for character in text {
            // Anything already ASCII was not an Option press that produced a
            // symbol, so this is not a Meta keystroke and must not be rewritten.
            if character.isASCII { return data }
            let base = String(character).decomposedStringWithCanonicalMapping
                .unicodeScalars.first { $0.properties.generalCategory != .nonspacingMark }
            guard let base, base.isASCII else { return data }
            out.append(0x1B)
            out.append(UInt8(base.value))
        }
        // Nothing convertible means this was not a Meta press at all — a paste
        // of accented text, say. Passing it through is the honest answer.
        return out.isEmpty ? data : out
    }
}