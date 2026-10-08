import SwiftUI

@Observable
final class ThemeStore {
    private static let key = "cqutmux.theme"

    var current: TerminalTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: Self.key) }
    }

    init() {
        current = TerminalTheme.named(UserDefaults.standard.string(forKey: Self.key))
    }
}

struct ThemeSettingsView: View {
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        List {
            Section("Dark") {
                ForEach(TerminalTheme.builtIn.filter(\.dark)) { row($0) }
            }
            Section("Light") {
                ForEach(TerminalTheme.builtIn.filter { !$0.dark }) { row($0) }
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ theme: TerminalTheme) -> some View {
        Button {
            themes.current = theme
        } label: {
            HStack {
                Text(theme.name).foregroundStyle(.primary)
                Spacer()
                swatches(theme)
                if themes.current.id == theme.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
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