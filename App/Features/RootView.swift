import SwiftUI

/// Top-level shell. Mirrors Moshi's structure: a terminal-first surface,
/// an agent inbox, a usage board, and settings.
struct RootView: View {
    @Environment(HostStore.self) private var store
    @Environment(AgentConnection.self) private var connection

    enum Tab: Hashable { case terminal, inbox, code, usages, settings }

    @State private var selection: Tab = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CQUT_DEV_TAB"] {
        case "inbox": return .inbox
        case "code": return .code
        case "theme", "settings": return .settings
        default: break
        }
        #endif
        return .terminal
    }()

    var body: some View {
        TabView(selection: $selection) {
            HostsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)

            NavigationStack {
                InboxView()
            }
            .tabItem { Label("Inbox", systemImage: "tray.full") }
            .tag(Tab.inbox)

            NavigationStack {
                CodePanelView()
            }
            .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            .tag(Tab.code)

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
        .task {
            #if DEBUG
            if connection.client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connection.connect(to: target)
            }
            #endif
        }
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