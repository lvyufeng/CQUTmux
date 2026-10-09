import SwiftUI

/// The watch app's two surfaces: what needs an answer, and how much budget is
/// left. Split the way Moshi splits them — the inbox is acted on, the usage
/// screen is looked at, and a single scrolling list would put the one thing
/// that needs a tap below a wall of rings.
struct WatchRootView: View {
    @State private var tab: Tab = Self.initialTab

    /// Which tab a run should start on. DEBUG-only.
    ///
    /// Read from the environment rather than tapped, so a run that wants the
    /// Usage screen gets a stated reason if it fails rather than a tap that
    /// depended on where the toolbar drew the button. It is also where the
    /// complication's link and this variable converge: both end in the same
    /// `tab` assignment below.
    private static var initialTab: Tab {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_WATCH_TAB"],
           let tab = Tab(rawValue: raw) {
            return tab
        }
        #endif
        return .inbox
    }

    enum Tab: String, CaseIterable, Identifiable {
        case inbox, usage
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .inbox: "tray.full"
            case .usage: "gauge.with.dots.needle.50percent"
            }
        }

        var label: String {
            switch self {
            case .inbox: "Inbox"
            case .usage: "Usage"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .inbox: ApprovalListView()
                case .usage: WatchUsageView()
                }
            }
            .toolbar {
                // Two small buttons rather than a TabView: on watchOS the
                // bottom bar is reserved for the system, and a segmented picker
                // costs a row of a very short screen.
                //
                // Written as two explicit buttons, not a `ForEach` inside the
                // item: a `ToolbarItem` takes a single view, so the loop
                // rendered only the first one and the usage screen was
                // unreachable.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tab = tab == .inbox ? .usage : .inbox
                    } label: {
                        Image(systemName: tab == .inbox ? Tab.usage.icon : Tab.inbox.icon)
                    }
                    .accessibilityLabel(tab == .inbox ? Tab.usage.label : Tab.inbox.label)
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Doubles as the tab indicator: the filled tray means the
                    // inbox is showing, so the wearer can tell where they are
                    // without a title taking a row.
                    Image(systemName: tab.icon)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            // The complication's tap lands here. A `cqutmux://usage` link is
            // the only one the watch understands: the face shows one rate-limit
            // number, so the wearer pressed it to see the screen that number
            // came from, and opening the inbox instead would be opening the
            // wrong tab on a 45mm screen.
            .onOpenURL { url in
                if url.host?.lowercased() == "usage" { tab = .usage }
            }
            .task {
                #if DEBUG
                // The widget's `widgetURL` cannot be fired from a script, so a
                // run hands the same URL to the same handler.
                if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_WATCH_URL"],
                   let url = URL(string: raw) {
                    if url.host?.lowercased() == "usage" { tab = .usage }
                }
                #endif
            }
        }
    }
}