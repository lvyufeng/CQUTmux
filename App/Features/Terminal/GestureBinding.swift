import Foundation
import Observation

/// A gesture on the terminal surface that can be bound to a shortcut.
///
/// The set is Moshi's: it leaves tap, double tap, triple tap and the two
/// horizontal swipes open to be bound, and that is exactly the set that has a
/// recogniser today. Pinch is deliberately not here — it is the font-size
/// control, and a binding that could take it away would cost more than it gave.
enum TerminalGesture: String, CaseIterable, Codable, Identifiable, Sendable {
    case singleTap
    case doubleTap
    case tripleTap
    case swipeLeft
    case swipeRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleTap: "Single tap"
        case .doubleTap: "Double tap"
        case .tripleTap: "Triple tap"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        }
    }

    var symbol: String {
        switch self {
        case .singleTap: "hand.tap"
        case .doubleTap: "hand.tap.fill"
        case .tripleTap: "hand.point.up.left.fill"
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        }
    }

    /// What the gesture does when the user has not bound it, or has bound it to
    /// something that no longer parses.
    ///
    /// Restoring the old behaviour rather than doing nothing matters: an
    /// unparsable binding is one the user is already being warned about, and
    /// silently swallowing a double tap on top of that would read as the app
    /// having broken.
    var fallback: ShortcutGrammar.Parsed? {
        switch self {
        case .singleTap:
            // Moshi's default, verbatim: "No-op by default." An unbound single
            // tap changes nothing — SwiftTerm's own tap keeps doing link-open,
            // selection-clear and mouse reporting, exactly as before this case
            // existed. The binding is opt-in.
            return nil
        case .doubleTap:
            // Tab completion, which is what double tap has always sent.
            return try? ShortcutGrammar.parse("Tab")
        case .swipeLeft:
            // Ctrl-b n — next tmux window.
            return try? ShortcutGrammar.parse("C-b n")
        case .swipeRight:
            // Ctrl-b p — previous tmux window.
            return try? ShortcutGrammar.parse("C-b p")
        case .tripleTap:
            // Nothing was bound here before, and inventing a default would
            // change behaviour nobody asked to change.
            return nil
        }
    }

    /// How our single-tap recogniser coexists with SwiftTerm's own.
    ///
    /// Moshi offers single tap as bindable — "No-op by default. Bind to show
    /// keyboard, send Escape/Tab, or run a custom shortcut" — but SwiftTerm
    /// already installs a single-tap recogniser of its own (`singleTap(_:)`),
    /// and it is what drives link-open, selection-clear and mouse reporting.
    ///
    /// Our recogniser is not a replacement for it and does not wait on it, so a
    /// tap still reaches SwiftTerm exactly as before. It is added with
    /// `cancelsTouchesInView = false` and made to recognise simultaneously with
    /// every other recogniser on the view, so it neither consumes a touch
    /// SwiftTerm needs nor is suppressed by SwiftTerm's own recognisers. When
    /// nothing is bound it still runs, finds no bytes, and does nothing.
    ///
    /// Limitation, recorded rather than hidden: a single tap has one action, so
    /// a bound shortcut and the terminal's own tap effect fire together — a
    /// mouse-reporting click the program was going to receive is still sent, and
    /// a link under the finger is still opened. Moshi's own default is a no-op
    /// for exactly this reason; binding a shortcut adds a behaviour, it does not
    /// replace the tap. Unbinding restores the no-op and nothing else changes.
    static let unsupported = "Single tap fires alongside the terminal's own tap (link-open, mouse reporting); binding adds an action rather than replacing it."
}

/// The user's gesture bindings.
///
/// Stores the raw text for the same reason `ShortcutStore` does: the grammar
/// can tighten, and a binding that no longer parses should be shown and
/// explained rather than deleted.
@Observable
final class GestureStore {
    private(set) var bindings: [TerminalGesture: String] = [:]

    private let defaults: UserDefaults
    private static let key = "cqutmux.gestureBindings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The text the user typed for a gesture, or nil if they have not bound it.
    func text(for gesture: TerminalGesture) -> String? { bindings[gesture] }

    /// Puts every gesture back to its built-in behaviour.
    ///
    /// Removing the key rather than writing an empty dictionary: a launch that
    /// finds no stored bindings and one that finds an empty set mean the same
    /// thing here, and removing is what a fresh install looks like — which is
    /// the state this is meant to reproduce.
    func resetAll() {
        bindings.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    func set(_ text: String?, for gesture: TerminalGesture) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            bindings.removeValue(forKey: gesture)
        } else {
            bindings[gesture] = trimmed
        }
        save()
    }

    /// The bytes a gesture should send, preferring the user's binding and
    /// falling back to the built-in behaviour.
    func bytes(for gesture: TerminalGesture) -> [UInt8]? {
        if let text = bindings[gesture] {
            // A binding that no longer parses falls back rather than sending
            // half of what was meant.
            return (try? ShortcutGrammar.parse(text))?.bytes ?? gesture.fallback?.bytes
        }
        return gesture.fallback?.bytes
    }

    /// Why the user's binding for this gesture is not being used, if it isn't.
    func problem(for gesture: TerminalGesture) -> String? {
        guard let text = bindings[gesture] else { return nil }
        do {
            _ = try ShortcutGrammar.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        bindings = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            TerminalGesture(rawValue: key).map { ($0, value) }
        })
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: Self.key)
    }
}