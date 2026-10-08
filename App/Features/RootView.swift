import SwiftUI

/// Top-level shell. Mirrors Moshi's structure: a terminal-first surface,
/// an agent inbox, a usage board, and settings.
struct RootView: View {
    enum Tab: Hashable { case terminal, inbox, usages, settings }

    @State private var selection: Tab = .terminal

    var body: some View {
        TabView(selection: $selection) {
            HostsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)

            NavigationStack {
                PlaceholderView(
                    title: "Inbox",
                    systemImage: "tray.full",
                    message: "Agent replies, approvals and context land here once the host hook is installed."
                )
            }
            .tabItem { Label("Inbox", systemImage: "tray.full") }
            .tag(Tab.inbox)

            NavigationStack {
                PlaceholderView(
                    title: "Usages",
                    systemImage: "gauge.with.dots.needle.50percent",
                    message: "5h and 7d rate-limit burn pace for every agent."
                )
            }
            .tabItem { Label("Usages", systemImage: "gauge.with.dots.needle.50percent") }
            .tag(Tab.usages)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .tint(Theme.accent)
    }
}

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

#Preview {
    RootView().environment(HostStore())
}