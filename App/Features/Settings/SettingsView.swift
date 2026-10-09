import SwiftUI

struct SettingsView: View {
    /// Destinations reached by a link as well as by tapping, so the two paths
    /// cannot drift. A `cqutmux://theme` link sets `pendingRoute` on the store
    /// and the push below happens here, once, in the same place the tap does.
    enum Route: Hashable {
        case theme, font, cursor, icon, speech, sessions, security, notifications, sync
        case integrations
        case input
        case mux
    }

    @Environment(ThemeStore.self) private var themes
    @State private var path = NavigationPath()

    var body: some View {
        #if DEBUG
        if let tab = debugTab {
            return AnyView(debugDestination(tab))
        }
        #endif
        return AnyView(list)
    }

    private var list: some View {
        NavigationStack(path: $path) {
            List {
                Section("Security") {
                    NavigationLink(value: Route.security) {
                        Label("Security", systemImage: "lock.shield")
                    }
                }
                Section("Notifications") {
                    NavigationLink(value: Route.notifications) {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                }
                Section("Data") {
                    NavigationLink(value: Route.sync) {
                        Label("iCloud sync", systemImage: "icloud")
                    }
                }
                Section("Dictation") {
                    NavigationLink(value: Route.speech) {
                        Label("Speech engine", systemImage: "waveform")
                    }
                }
                Section("Appearance") {
                    NavigationLink(value: Route.theme) {
                        Label("Theme", systemImage: "paintpalette")
                    }
                    NavigationLink(value: Route.font) {
                        Label("Font", systemImage: "textformat.size")
                    }
                    NavigationLink(value: Route.cursor) {
                        Label("Cursor", systemImage: "cursorarrow.rays")
                    }
                    NavigationLink(value: Route.icon) {
                        Label("App Icon", systemImage: "app.badge")
                    }
                }
                Section("Terminal sessions") {
                    NavigationLink(value: Route.sessions) {
                        Label("Sessions layout", systemImage: "rectangle.grid.1x2")
                    }
                    NavigationLink(value: Route.mux) {
                        Label("Multiplexer", systemImage: "coloncurrencysign.circle")
                    }
                }
                Section("Input") {
                    NavigationLink(value: Route.input) {
                        Label("Keyboard & key bar", systemImage: "keyboard")
                    }
                }
                Section("Integrations") {
                    NavigationLink(value: Route.integrations) {
                        Label("Shell", systemImage: "terminal")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                    LabeledContent("Hook gateway", value: "127.0.0.1:24543")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .theme: ThemeSettingsView()
                case .font: FontSettingsView()
                case .cursor: CursorSettingsView()
                case .icon: AppIconSettingsView()
                case .sessions: SessionLayoutView()
                case .security: SecuritySettingsView()
                case .notifications: NotificationSettingsView()
                case .sync: SyncSettingsView()
                case .speech: SpeechSettingsView()
                case .integrations: IntegrationSettingsView()
                case .input: InputSettingsView()
                case .mux: MuxSettingsView()
                }
            }
        }
        .onAppear { followPendingRoute() }
        .onChange(of: themes.pendingRoute) { followPendingRoute() }
    }

    /// Pushes the theme screen when a link asked for it, and clears the request
    /// so returning to Settings later does not re-open it.
    private func followPendingRoute() {
        guard let route = themes.pendingRoute else { return }
        themes.pendingRoute = nil
        path = NavigationPath()
        path.append(route)
    }

    #if DEBUG
    private var debugTab: String? {
        guard let tab = ProcessInfo.processInfo.environment["CQUT_DEV_TAB"] else { return nil }
        switch tab {
        case "theme", "font", "speech", "cursor", "icon", "sessions", "security",
             "notifications", "sync", "integrations", "input", "mux":
            return tab
        default:
            return nil
        }
    }

    @ViewBuilder
    private func debugDestination(_ tab: String) -> some View {
        switch tab {
        case "theme": ThemeSettingsView()
        case "font": FontSettingsView()
        case "cursor": CursorSettingsView()
        case "icon": AppIconSettingsView()
        case "sessions": SessionLayoutView()
        case "security": SecuritySettingsView()
        case "notifications": NotificationSettingsView()
        case "sync": SyncSettingsView()
        case "integrations": IntegrationSettingsView()
        case "input": InputSettingsView()
        case "mux": MuxSettingsView()
        default: SpeechSettingsView()
        }
    }
    #endif
}

private extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(ThemeStore())
}