import SwiftUI

/// Top-level shell. On a phone it is a tab bar; on a regular-width screen
/// (iPad) the same surfaces become a sidebar, so the terminal keeps the large
/// half of the display the way Moshi does. Both share one selection model.
struct RootView: View {
    @Environment(HostStore.self) private var store
    @Environment(AgentConnection.self) private var connection
    @Environment(ThemeStore.self) private var themes
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Tab: String, CaseIterable, Hashable {
        case terminal, inbox, code, usages, settings

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .inbox: "Inbox"
            case .code: "Code"
            case .usages: "Usages"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .inbox: "tray.full"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .usages: "gauge.with.dots.needle.50percent"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Tab = Self.initialTab
    /// A link that arrived and could not be followed, shown once and cleared.
    /// Ignoring a bad link is worse than saying so: the user clicked something
    /// and needs to know whether the app acted on it.
    @State private var linkProblem: String?
    /// Handed down to whichever terminal opens next. A link that arrives
    /// before any session exists has to survive until there is one to send the
    /// attach command to.
    @State private var pendingLink: DeepLink?

    var body: some View {
        Group {
            if sizeClass == .regular {
                sidebar
            } else {
                tabs
            }
        }
        // One theme drives the whole app, not just the terminal pane: the tint
        // below reaches buttons, links and toggles, and `preferredColorScheme`
        // makes the system's own surfaces — lists, sheets, the tab bar — agree
        // with the palette instead of staying on whatever the device is set to.
        // A light theme that left the chrome dark would defeat picking it.
        .tint(themes.current.accentColor)
        .preferredColorScheme(themes.current.dark ? .dark : .light)
        .onOpenURL { handle($0) }
        .alert("Could not open the link", isPresented: .constant(linkProblem != nil)) {
            Button("OK") { linkProblem = nil }
        } message: {
            Text(linkProblem ?? "")
        }
        .task {
            #if DEBUG
            // iOS puts a "Open in CQUTmux?" confirmation in front of a custom
            // scheme launched from outside the app, and nothing in `simctl`
            // can tap it — there is no Simulator.app in this Xcode and no
            // input-injection tool. Announcing the URL through the environment
            // reaches the same `onOpenURL` handler with the same `URL`, so
            // everything after the OS's own delivery can still be tested.
            if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_OPEN_URL"],
               let url = URL(string: raw) {
                handle(url)
            }
            if connection.client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connection.connect(to: target)
            }
            #endif
        }
    }

    /// Opening a link is one action whether it arrives from the system or, in a
    /// debug run, from the environment.
    private func handle(_ url: URL) {
        switch DeepLink.parse(url) {
        case .success(let link):
            if handleTheme(link) { return }
            selection = .terminal
            pendingLink = link
        case .failure(let error):
            linkProblem = error.localizedDescription
        }
    }

    /// A theme link does not go through `handle` like the others: those name a
    /// host or a session and belong to the terminal, while this one has nothing
    /// to do with the terminal and only opens a screen.
    private func handleTheme(_ link: DeepLink) -> Bool {
        guard case .theme = link.target else { return false }
        selection = .settings
        themes.pendingRoute = .theme
        return true
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases, id: \.self) { tab in
                destination(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
    }

    private var sidebar: some View {
        NavigationSplitView {
            List {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .foregroundStyle(selection == tab ? themes.current.accentColor : .primary)
                    }
                }
            }
            .navigationTitle("CQUTmux")
        } detail: {
            destination(selection)
        }
    }

    @ViewBuilder
    private func destination(_ tab: Tab) -> some View {
        switch tab {
        case .terminal:
            HostsView(pendingLink: pendingLink)
        case .inbox:
            NavigationStack { InboxView() }
        case .code:
            NavigationStack { CodePanelView() }
        case .usages:
            NavigationStack { UsagesView() }
        case .settings:
            NavigationStack { SettingsView() }
        }
    }

    private static var initialTab: Tab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CQUT_DEV_TAB"] {
        case "inbox": return .inbox
        case "code": return .code
        case "usages": return .usages
        case "theme", "font", "speech", "settings", "cursor", "icon", "sessions",
             "security", "notifications", "sync", "integrations", "input", "mux",
             "toolbar", "support":
            return .settings
        default: break
        }
        #endif
        return .terminal
    }
}

#Preview {
    RootView().environment(HostStore())
}