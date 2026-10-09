import SwiftUI

/// Settings → Toolbar: the material behind the toolbar controls.
struct ToolbarSettingsView: View {
    /// The store the terminal also holds, rather than one of this screen's own.
    ///
    /// A fresh instance would persist the same value and still leave the bar
    /// on the terminal screen reading its old state until something rebuilt
    /// it — the setting would look like it needed a relaunch to take effect.
    ///
    /// Not named `toolbar`: that is already a `View` modifier in this module's
    /// scope, and `@Bindable var toolbar = toolbar` would bind to the modifier
    /// rather than to this property.
    @Environment(ToolbarSettings.self) private var store
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Toggle("Glass effect", isOn: $store.glassEffect)
                    .disabled(!ToolbarSettings.canTurnOffGlass)
            } header: {
                Label("Display", systemImage: "square.on.square")
            } footer: {
                Text(footer)
            }

            Section {
                Preview(glass: store.glassEffect, theme: themes.current)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("The key bar above the keyboard is ours, so this changes it "
                     + "on every version. The navigation bars belong to the system.")
            }
        }
        .navigationTitle("Toolbar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        if ToolbarSettings.canTurnOffGlass {
            return "On, the bars use the system's translucent material and the "
                + "terminal shows through. Off, they use an opaque surface in "
                + "the theme's own colour, which is easier to read over a busy "
                + "screen."
        }
        return "This device's iOS draws the bar material itself and offers no way "
            + "to turn it off, so this switch only affects the key bar — see below. "
            + "On iOS 26 and later it turns the glass off everywhere."
    }
}

/// A miniature key bar drawn in whichever treatment is selected, so the setting
/// shows its own effect rather than describing it.
private struct Preview: View {
    let glass: Bool
    let theme: TerminalTheme

    var body: some View {
        ZStack {
            // The thing the bar sits over, so translucency has something to
            // show through: an opaque preview would make the two states
            // identical and the setting look broken.
            LinearGradient(colors: [theme.accentColor.opacity(0.45), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(spacing: 6) {
                ForEach(["Ctrl", "Esc", "Tab", "↑", "↓"], id: \.self) { key in
                    Text(key)
                        .font(.caption)
                        .frame(minWidth: 40, minHeight: 30)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(surface)
        }
        .frame(height: 74)
    }

    @ViewBuilder
    private var surface: some View {
        if glass {
            Rectangle().fill(.bar)
        } else {
            theme.backgroundColor
        }
    }
}

#Preview {
    NavigationStack { ToolbarSettingsView() }
        .environment(ThemeStore())
        .environment(ToolbarSettings())
}