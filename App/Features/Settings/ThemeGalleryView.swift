import SwiftUI

/// The built-in theme catalogue: browse it, search it, import one.
///
/// Moshi's gallery is served from `/themes` and can be re-fetched by slug. That
/// server is not ours to call, so this browses the catalogue that ships with the
/// app (`ThemeGallery`) — the same two operations, browsing and importing by
/// slug, over palettes that are real rather than invented to reach a count.
struct ThemeGalleryView: View {
    @Environment(ThemeStore.self) private var themes

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The entry whose document failed to import, if any. A gallery entry is
    /// checked to parse, so this is a should-not-happen the user should still
    /// see rather than a silent no-op.
    @State private var failure: String?

    private var results: [ThemeGallery.Entry] { ThemeGallery.search(query) }

    /// Which entries the user already has, by the id an import would carry.
    private var importedSlugs: Set<String> {
        Set(themes.imported.map(\.id).map { $0.replacingOccurrences(of: "imported-", with: "") })
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView {
                        Label("No themes", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing in the gallery matches “\(query)”.")
                    }
                } else {
                    ForEach(results) { entry in
                        row(entry)
                    }
                }
            }
            .navigationTitle("Theme gallery")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search themes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // The catalogue is bundled and its version is checked, so this
            // footer says what the gallery actually is rather than implying a
            // live feed: the count is honest and so is its origin.
            .safeAreaInset(edge: .bottom) {
                Text("\(ThemeGallery.entries.count) themes bundled with the app · catalogue v\(ThemeGallery.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .alert("Couldn't import", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ThemeGallery.Entry) -> some View {
        let already = importedSlugs.contains(entry.slug)
        Button {
            importEntry(entry)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    // "Re-import" rather than "Imported": the claim is that a
                    // slug is *re-fetchable*, so a theme the user already has
                    // is something they can pull again — to pick up a corrected
                    // palette — not something that is done with.
                    if already {
                        Text("Re-import").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                preview(entry)
                if already {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Six swatches over the theme's own background — the same preview the
    /// settings list draws, built from the entry's parsed palette.
    @ViewBuilder
    private func preview(_ entry: ThemeGallery.Entry) -> some View {
        if case .success(let theme) = ThemeImport.parse(entry.json) {
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

    private func importEntry(_ entry: ThemeGallery.Entry) {
        switch ThemeImport.parse(entry.json) {
        case .success(let theme):
            themes.importTheme(theme)
            dismiss()
        case .failure(let error):
            failure = error.errorDescription ?? "\(error)"
        }
    }
}
