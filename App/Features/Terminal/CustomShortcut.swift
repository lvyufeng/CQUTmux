import Foundation
import Observation

/// One user-defined key in the terminal's accessory bar.
///
/// The raw text is what the user typed and the source of truth; the parsed
/// steps are derived. Keeping both means an editor can round-trip a shortcut
/// the current grammar no longer accepts without destroying it.
struct CustomShortcut: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// What the user typed, e.g. `C-b, T`.
    var text: String
    /// What the key shows in the bar. Empty means "use the parsed label".
    var displayName: String = ""

    /// The parsed form, or nil if it no longer parses (a rule tightened since
    /// it was saved, say). A shortcut that will not parse is kept and flagged
    /// rather than silently dropped.
    var parsed: ShortcutGrammar.Parsed? { try? ShortcutGrammar.parse(text) }

    var label: String {
        if !displayName.isEmpty { return displayName }
        return parsed?.label ?? text
    }

    /// The bytes to write into the session.
    var bytes: [UInt8]? { parsed?.bytes }

    var problem: String? {
        do {
            _ = try ShortcutGrammar.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The user's custom shortcuts, in the order they appear in the bar.
///
/// Free builds cap the count the way Moshi does. The cap is a product rule
/// rather than a technical one, so it lives here as a constant that an
/// entitlement check can consult later instead of being baked into the editing
/// UI.
@Observable
final class ShortcutStore {
    static let freeLimit = 3

    private(set) var shortcuts: [CustomShortcut] = []

    /// Whether another shortcut may be added. Passed in rather than computed
    /// here so this type does not need to know about purchases.
    func canAdd(pro: Bool) -> Bool {
        pro || shortcuts.count < Self.freeLimit
    }

    private let defaults: UserDefaults
    private static let key = "cqutmux.customShortcuts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ text: String, displayName: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shortcuts.append(CustomShortcut(text: trimmed, displayName: displayName))
        save()
    }

    func update(_ shortcut: CustomShortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        save()
    }

    func remove(_ shortcut: CustomShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        shortcuts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Drops every shortcut whose text no longer parses. Offered as an explicit
    /// action rather than done automatically, so a tightening of the grammar
    /// cannot quietly delete somebody's work.
    func removeUnparsable() {
        shortcuts.removeAll { $0.problem != nil }
        save()
    }

    /// Drops every custom key.
    ///
    /// The counterpart to `GestureStore.resetAll`, and it exists for the same
    /// reason: "reset all" that leaves one of the two stores populated is a
    /// button that lies about what it did.
    func resetAll() {
        shortcuts.removeAll()
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([CustomShortcut].self, from: data)
        else { return }
        shortcuts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        defaults.set(data, forKey: Self.key)
    }
}