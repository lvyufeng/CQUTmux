import SwiftUI

/// The chosen theme, built-in or imported, plus the imported ones themselves.
///
/// Imported themes are stored whole rather than referenced by id: there is no
/// gallery to re-fetch them from, and a theme the user pasted in should still be
/// there after a restart even if its source has moved or gone.
@Observable
final class ThemeStore {
    private static let key = "cqutmux.theme"
    private static let importedKey = "cqutmux.theme.imported"

    /// The selected theme. On first run this is Moshi, matching the app's own
    /// green rather than whichever palette happened to be first in the list.
    private(set) var current: TerminalTheme

    /// Themes the user imported, newest first.
    private(set) var imported: [TerminalTheme]

    /// A screen the app was asked to open by a link. The settings list watches
    /// this and pushes the route, which keeps the link from having to know how
    /// the settings navigation is arranged.
    var pendingRoute: SettingsView.Route?

    /// A theme id to select at launch, so a UI run can see a light palette
    /// without tapping through the list. Debug-only, like the other seeds.
    static var seedKey: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["CQUT_DEV_THEME"]
        #else
        nil
        #endif
    }

    init(defaults: UserDefaults = .standard) {
        let stored = Self.seedKey ?? defaults.string(forKey: Self.key)
        let saved = Self.readImported(from: defaults)
        imported = saved

        // The stored id may name an imported theme: `named` only knows the
        // built-ins, so the list has to be searched too or an imported
        // selection would reset to Moshi on every launch.
        if let stored, let match = saved.first(where: { $0.id == stored }) {
            current = match
        } else {
            current = TerminalTheme.named(stored)
        }
    }

    /// Every theme the picker should show: the built-ins, then anything
    /// imported.
    var all: [TerminalTheme] { TerminalTheme.builtIn + imported }

    func select(_ theme: TerminalTheme) {
        current = theme
        UserDefaults.standard.set(theme.id, forKey: Self.key)
    }

    /// Imports a theme, replacing one with the same id so re-importing a theme
    /// the user has tweaked updates it rather than leaving two entries that
    /// look identical.
    @discardableResult
    func importTheme(_ theme: TerminalTheme) -> Bool {
        let isNew = !imported.contains { $0.id == theme.id }
        imported.removeAll { $0.id == theme.id }
        imported.insert(theme, at: 0)
        writeImported()
        select(theme)
        return isNew
    }

    /// Adds a theme without selecting it or reordering the user's list.
    ///
    /// Separate from `importTheme` because sync applies a whole payload: calling
    /// `importTheme` per theme would select each one in turn, leaving whichever
    /// happened to be last as the active theme rather than the one the payload
    /// names.
    func adopt(_ theme: TerminalTheme) {
        var updated = imported
        updated.removeAll { $0.id == theme.id }
        updated.append(theme)
        imported = updated
        writeImported()
    }

    func delete(_ theme: TerminalTheme) {
        imported.removeAll { $0.id == theme.id }
        writeImported()
        // A deleted theme cannot stay selected: the terminal would keep
        // rendering colours that are no longer in the list, and the checkmark
        // would be nowhere.
        if current.id == theme.id { select(TerminalTheme.builtIn[0]) }
    }

    // MARK: - Persistence

    private func writeImported() {
        guard let data = try? JSONEncoder().encode(imported) else { return }
        UserDefaults.standard.set(data, forKey: Self.importedKey)
    }

    private static func readImported(from defaults: UserDefaults) -> [TerminalTheme] {
        guard let data = defaults.data(forKey: importedKey),
              let themes = try? JSONDecoder().decode([TerminalTheme].self, from: data)
        else { return [] }
        return themes
    }
}

struct ThemeSettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @State private var importing = false
    @State private var browsing = false
    /// A theme that replaced one with the same id. Worth saying, because the
    /// user's earlier version is gone and the screen looks unchanged otherwise.
    @State private var updated: String?

    var body: some View {
        List {
            Section("Dark") {
                ForEach(TerminalTheme.builtIn.filter(\.dark)) { row($0) }
            }
            Section("Light") {
                ForEach(TerminalTheme.builtIn.filter { !$0.dark }) { row($0) }
            }
            if !themes.imported.isEmpty {
                Section {
                    ForEach(themes.imported) { row($0) }
                } header: {
                    Text("Imported")
                } footer: {
                    Text("Swipe an imported theme to remove it.")
                }
            }
            Section {
                Button {
                    browsing = true
                } label: {
                    Label("Theme gallery", systemImage: "square.grid.2x2")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import theme…", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Browse the bundled gallery, or paste a theme copied from Moshi, "
                     + "open a `cqutmux://theme` link, or scan its QR code.")
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            // Opening the import sheet from a script would mean tapping a button
            // whose position a run would then depend on, so a debug run opens it
            // directly. The sheet, its parse and its error path are all real;
            // only the tap is stood in for.
            if ProcessInfo.processInfo.environment["CQUT_DEV_IMPORT"] == "1" { importing = true }
            if ProcessInfo.processInfo.environment["CQUT_DEV_GALLERY"] == "1" { browsing = true }
            #endif
        }
        .sheet(isPresented: $browsing) {
            ThemeGalleryView()
        }
        .sheet(isPresented: $importing) {
            ThemeImportView { theme in
                // `importTheme` reports whether it replaced an earlier import
                // of the same name, which is the only case worth saying
                // anything about — a new theme is visible as a new row.
                if !themes.importTheme(theme) { updated = theme.name }
            }
        }
        .alert("Replaced an earlier import", isPresented: .constant(updated != nil)) {
            Button("OK") { updated = nil }
        } message: {
            Text("“\(updated ?? "")” was already imported, so this version replaced it.")
        }
    }

    @ViewBuilder
    private func row(_ theme: TerminalTheme) -> some View {
        Button {
            themes.select(theme)
        } label: {
            HStack {
                Text(theme.name).foregroundStyle(.primary)
                Spacer()
                swatches(theme)
                if themes.current.id == theme.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(themes.current.accentColor)
                }
            }
        }
        .swipeActions {
            if theme.isImported {
                Button("Delete", role: .destructive) { themes.delete(theme) }
            }
        }
    }

    /// A tiny preview of the palette, like Moshi's theme list.
    private func swatches(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 3) {
            ForEach([0, 1, 2, 3, 4, 5], id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: theme.ansi[index]))
                    .frame(width: 10, height: 16)
            }
        }
        .padding(4)
        .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 4))
    }
}