import SwiftUI

/// Top-level shell. On a phone it is a tab bar; on a regular-width screen
/// (iPad) the same surfaces become a sidebar, so the terminal keeps the large
/// half of the display the way Moshi does. Both share one selection model.
struct RootView: View {
    @Environment(HostStore.self) private var store
    @Environment(AgentConnection.self) private var connection
    @Environment(ThemeStore.self) private var themes
    @Environment(AppSettings.self) private var app
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
            // Seeding a host and connecting to it are separate things: the host
            // list is where a saved host's own state shows (its gateway status
            // dot), and an auto-connect makes the app unreachable at the moment
            // it launches.
            if ProcessInfo.processInfo.environment["CQUT_DEV_NO_CONNECT"] != "1",
               connection.client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connection.connect(to: target)
            }
            // The Settings test button starts an activity the same way, but a
            // tap is the one thing `simctl` cannot do — so the button's own
            // code path is reachable from launch instead. What this proves is
            // the part the check script cannot: that `Activity.request`
            // actually succeeds and the widget renders it, which is the half
            // that lives in ActivityKit and the widget extension.
            if ProcessInfo.processInfo.environment["CQUT_DEV_TEST_ACTIVITY"] == "1" {
                let outcome = ActivityManager().update(
                    hostName: "Test host", events: AgentActivityPreview.sampleEvents()
                )
                // Printed, not just acted on: `Activity.request` failing is
                // invisible from here — no exception reaches the UI, and the
                // activity simply is not there — so a run that cannot tap the
                // button needs the outcome in the log to tell the two apart.
                print("CQUT_TEST_ACTIVITY: \(outcome)")
            }
            #endif
        }
    }

    /// Opening a link is one action whether it arrives from the system or, in a
    /// debug run, from the environment.
    private func handle(_ url: URL) {
        switch DeepLink.parse(url) {
        case .success(let link):
            // Screens a link opens rather than a session it attaches to. Both
            // are handled here, before `pendingLink`, because neither has
            // anything for the terminal to do.
            if handleTheme(link) { return }
            if handleInbox(link) { return }
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

    /// `cqutmux://inbox`, which is where a Live Activity's tap lands.
    ///
    /// Routed like the theme link rather than through `pendingLink`: the Inbox
    /// is a tab, not a session, so there is nothing for the terminal to attach
    /// to and nothing to keep pending.
    private func handleInbox(_ link: DeepLink) -> Bool {
        guard case .inbox = link.target else { return false }
        // The switch is read here rather than in the widget because the widget
        // extension has its own `UserDefaults` container and no app group to
        // share one through — read there it would always answer with the
        // default and the toggle would change nothing. A tap with it off still
        // opens the app; it just leaves the tab where it was.
        guard AgentActivitySettings.opensInboxOnTap() else { return true }
        selection = .inbox
        return true
    }

    /// The tabs to show, in `Tab.allCases` order.
    ///
    /// The Code panel is the one that can be hidden, and hiding is what
    /// `AppSettings.hidesCodeTab` means. If the selected tab is the one being
    /// hidden the selection is moved off it, or the app would show a tab it no
    /// longer lists.
    private var visibleTabs: [Tab] {
        let all = Tab.allCases.filter { $0 != .code || !app.hidesCodeTab }
        if !all.contains(selection), let first = all.first {
            DispatchQueue.main.async { self.selection = first }
        }
        return all
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(visibleTabs, id: \.self) { tab in
                destination(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
    }

    private var sidebar: some View {
        NavigationSplitView {
            List {
                ForEach(visibleTabs, id: \.self) { tab in
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
             "toolbar", "support", "agents", "hooks":
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