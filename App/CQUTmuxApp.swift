import SwiftUI

@main
struct CQUTmuxApp: App {
    @State private var hostStore = HostStore()
    @State private var connection = AgentConnection()
    @State private var themes = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .environment(connection)
                .environment(themes)
                .task {
                    #if DEBUG
                    DebugSeed.apply(to: hostStore)
                    // UI runs can skip the permission prompt, which otherwise
                    // covers every screenshot taken in the first seconds.
                    if ProcessInfo.processInfo.environment["CQUT_DEV_NO_NOTIFS"] == "1" { return }
                    #endif
                    _ = await ApprovalNotifier.requestAuthorization()
                }
        }
    }
}