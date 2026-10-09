import Foundation

/// Recent dictation, so a long prompt can be sent again without saying it
/// again.
///
/// Moshi's reason, and it is the right one: a terminal prompt is often the same
/// instruction retyped into another session, and the fix for a misheard word is
/// to edit the entry rather than to dictate the whole thing over.
///
/// **This is dictation, not a keystroke log.** The history holds the final text
/// of what was dictated and nothing else — not what was typed by hand, not what
/// was pasted. That distinction is the whole reason the store is fed from
/// `Dictation.onUpdate`'s `.final` case rather than from the terminal's input
/// path: a hook on `send` would silently capture passwords typed at a `sudo`
/// prompt, and no user asking for "dictation history" expects that.
@Observable
final class TranscriptionHistory {
    /// How many entries are kept.
    ///
    /// A cap rather than a setting: the value of the tenth-oldest dictation is
    /// near zero, and an unbounded list of things the user said is a liability
    /// that grows on its own. Twenty is roughly a session's worth.
    static let limit = 20

    struct Entry: Identifiable, Equatable, Codable {
        var id: UUID = UUID()
        var text: String
        var at: Date = Date()
    }

    private(set) var entries: [Entry] = []

    private let store: UserDefaults
    private static let key = "cqutmux.transcriptionHistory"

    init(store: UserDefaults = .standard) {
        self.store = store
        load()
    }

    /// Records a finished dictation. Consecutive duplicates are collapsed: a
    /// dictation that just re-sent the previous line is noise, and it would
    /// otherwise push a distinct entry off the end of a 20-item list.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.first?.text != trimmed else { return }
        // Drop an earlier identical entry rather than keeping both, so
        // repeating a prompt a day later moves it to the top instead of
        // appearing twice.
        entries.removeAll { $0.text == trimmed }
        entries.insert(Entry(text: trimmed), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = store.data(forKey: Self.key) else { return }
        entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: Self.key)
    }
}