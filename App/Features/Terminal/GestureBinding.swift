import Foundation
import Observation

/// A gesture on the terminal surface that can be bound to a shortcut.
///
/// The set is Moshi's: it leaves tap, double tap, triple tap and the two
/// horizontal swipes open to be bound, and that is exactly the set that has a
/// recogniser today. Pinch is deliberately not here — it is the font-size
/// control, and a binding that could take it away would cost more than it gave.
enum TerminalGesture: String, CaseIterable, Codable, Identifiable, Sendable {
    case doubleTap
    case tripleTap
    case swipeLeft
    case swipeRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doubleTap: "Double tap"
        case .tripleTap: "Triple tap"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        }
    }

    var symbol: String {
        switch self {
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

    /// Why single tap is not in the list above: SwiftTerm's own tap handling
    /// drives mouse reporting and its long-press selection, and a recogniser of
    /// ours would have to fail first to let those through — a tap would then
    /// stop doing what it does today. The four here are ones the terminal does
    /// not already use. Documented rather than silently missing for the same
    /// reason a binding that stops parsing is flagged: the absence should be
    /// deliberate and visible.
    static let unsupported = "Single tap belongs to text selection and mouse reporting."
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